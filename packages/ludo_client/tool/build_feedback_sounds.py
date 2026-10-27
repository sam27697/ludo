#!/usr/bin/env python3
"""Builds the feedback service's eleven cue clips from three pinned packs.

C-468 D1-D3: every clip is cut from the Kenney Casino Audio, Impact Sounds
and Music Jingles archives (CC0), downloaded once into a cache outside the
repository and checked against a pinned sha256. Each source is decoded to
mono 16-bit 44.1 kHz with ffmpeg, stripped of leading silence, cut, faded,
mixed, loudness-normalised (D3 step 4, as amended in run 112) and written
to android/app/src/main/res/raw/fb_<id>.wav.

Nothing is random and every step is plain arithmetic on the decoded
samples, so two runs on one machine write byte-identical files.

Standard library plus the ffmpeg binary on PATH. The cache directory is
$LUDO_SOUND_CACHE, default ~/.cache/ludo-sounds.
"""

from __future__ import annotations

import array
import hashlib
import io
import math
import os
import subprocess
import sys
import tempfile
import urllib.request
import wave
import zipfile

SAMPLE_RATE = 44100

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(
    os.path.dirname(_HERE), "android", "app", "src", "main", "res", "raw"
)

# C-468 D1: pack key -> (zip file name, url, bytes, sha256).
PACKS = {
    "casino": (
        "kenney_casino-audio.zip",
        "https://kenney.nl/media/pages/assets/casino-audio/"
        "2472606a04-1721639069/kenney_casino-audio.zip",
        876839,
        "f36250766ac5bc378c13708ddf12a23a8e54a3251f8d482c7536e51b5dbafa18",
    ),
    "impact": (
        "kenney_impact-sounds.zip",
        "https://kenney.nl/media/pages/assets/impact-sounds/"
        "87b4ddecda-1677589768/kenney_impact-sounds.zip",
        800850,
        "029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8",
    ),
    "jingles": (
        "kenney_music-jingles.zip",
        "https://kenney.nl/media/pages/assets/music-jingles/"
        "f37e530b9e-1677590399/kenney_music-jingles.zip",
        1239525,
        "b729ba57959bd58793d2c5cafa348aaf2655d354f3da35ec4729e03ec77197b8",
    ),
}

# C-468 D3 step 3 and 4.
ONSET_DBFS = -40.0
ONSET_LEAD_MS = 2
# C-468 D3 step 4 as amended (runs 112, amendments 1 to 3): loudness is the
# largest RMS over any 50 ms window, set to REFERENCE_DBFS plus the clip's
# trim, with the peak held at -1.0 dBFS by a limiter that never takes more
# than 9 dB. REFERENCE_DBFS is the one level for the whole set: -19.0, or
# the first 0.5 dB step below it at which all eleven clips reach target.
REFERENCE_DBFS = -19.0
CEILING_DBFS = -1.0
WINDOW = 2205
WINDOW_STEP = 551
LIMIT_LOOKAHEAD_MS = 2
LIMIT_RELEASE_MS = 50
LIMIT_MAX_REDUCTION_DB = 9.0
# How far the final loudness may sit from the target (amendment 3), the
# step of the pre-limiter gain search and how far it may go.
LOUDNESS_TOLERANCE_DB = 0.5
SEARCH_STEP_DB = 0.1
SEARCH_STEPS = 200
# D3 asks for at least 10 ms; 15 ms keeps the last 2 ms well under 0.2 of
# the peak (D3 acceptance) with margin for the window rounding.
TAIL_FADE_MS = 15


class Source:
    """One source file: pack key and path inside the zip."""

    def __init__(self, pack: str, path: str) -> None:
        self.pack = pack
        self.path = path


class Clip:
    """One D2 row: a source, an optional cut and closing fade, a trim and
    a duration ceiling. no_move is the only mixed clip."""

    def __init__(
        self,
        cue_id: str,
        source: Source,
        trim_db: float,
        max_s: float,
        cut_ms: int | None = None,
        fade_ms: int | None = None,
    ) -> None:
        self.cue_id = cue_id
        self.source = source
        self.trim_db = trim_db
        self.max_s = max_s
        self.cut_ms = cut_ms
        self.fade_ms = fade_ms


# C-468 D2, in table order. no_move is built by _build_no_move.
CLIPS = [
    Clip("your_turn", Source("casino", "Audio/dice-grab-1.ogg"), -4.0, 0.80),
    Clip("can_move", Source("casino", "Audio/die-throw-2.ogg"), 0.0, 0.80),
    Clip("no_move", Source("casino", "Audio/die-throw-4.ogg"), 0.0, 1.00),
    Clip(
        "step",
        Source("impact", "Audio/impactWood_light_002.ogg"),
        -8.0,
        0.16,
        cut_ms=150,
        fade_ms=20,
    ),
    Clip(
        "captured_other",
        Source("impact", "Audio/impactWood_heavy_000.ogg"),
        0.0,
        0.60,
    ),
    Clip(
        "captured_me",
        Source("impact", "Audio/impactPlank_medium_000.ogg"),
        -2.0,
        0.70,
        cut_ms=650,
        fade_ms=60,
    ),
    Clip("home", Source("casino", "Audio/chips-stack-1.ogg"), 0.0, 0.60),
    Clip(
        "win",
        Source("jingles", "Audio/Pizzicato jingles/jingles_PIZZI02.ogg"),
        0.0,
        1.50,
    ),
    Clip(
        "game_over",
        Source("jingles", "Audio/Pizzicato jingles/jingles_PIZZI13.ogg"),
        -3.0,
        1.20,
    ),
    Clip("die_land", Source("casino", "Audio/die-throw-1.ogg"), -6.0, 0.80),
    Clip(
        "gloat",
        Source("jingles", "Audio/Sax jingles/jingles_SAX11.ogg"),
        -3.0,
        1.00,
    ),
]

# C-468 D2 no_move: the throw, 40 ms of silence, then this impact.
NO_MOVE_IMPACT = Source("impact", "Audio/impactSoft_heavy_000.ogg")
NO_MOVE_GAP_MS = 40
NO_MOVE_IMPACT_CUT_MS = 350
NO_MOVE_IMPACT_FADE_MS = 30
NO_MOVE_IMPACT_DB = -6.0


class BuildError(Exception):
    pass


class LoudnessShortfall(BuildError):
    """A clip cannot reach its loudness target (amendment 3: lower
    REFERENCE_DBFS for the whole set, in 0.5 dB steps)."""


def _ms(ms: float) -> int:
    return int(round(ms * SAMPLE_RATE / 1000.0))


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def cache_dir() -> str:
    return os.environ.get("LUDO_SOUND_CACHE") or os.path.join(
        os.path.expanduser("~"), ".cache", "ludo-sounds"
    )


def fetch_pack(key: str) -> str:
    """Path of the pinned zip in the cache, downloading it when absent or
    when the cached file does not carry the pinned hash (D3 step 1)."""
    name, url, size, want = PACKS[key]
    directory = cache_dir()
    os.makedirs(directory, exist_ok=True)
    dest = os.path.join(directory, name)
    if os.path.isfile(dest) and _sha256(dest) == want:
        return dest
    print(f"downloading {name}")
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=name + ".part-")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(
            url, timeout=120
        ) as resp:
            while True:
                block = resp.read(1 << 20)
                if not block:
                    break
                out.write(block)
        got = _sha256(tmp)
        if got != want:
            raise BuildError(
                f"sha256 mismatch for {name}: expected {want}, got {got}"
            )
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return dest


def decode(zip_path: str, member: str) -> list[float]:
    """The member decoded to mono 16-bit 44.1 kHz samples (D3 step 2)."""
    with zipfile.ZipFile(zip_path) as z:
        data = z.read(member)
    proc = subprocess.run(
        [
            "ffmpeg", "-nostdin", "-v", "error", "-i", "pipe:0",
            "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1",
        ],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        raise BuildError(
            f"ffmpeg failed on {member}: {proc.stderr.decode(errors='replace')}"
        )
    pcm = array.array("h")
    pcm.frombytes(proc.stdout)
    if sys.byteorder == "big":
        pcm.byteswap()
    return [float(v) for v in pcm]


def strip_leading_silence(x: list[float]) -> list[float]:
    """Drop samples before the first one at -40 dBFS or louder, keeping
    2 ms before it (D3 step 3)."""
    threshold = 32768.0 * 10.0 ** (ONSET_DBFS / 20.0)
    for i, v in enumerate(x):
        if abs(v) >= threshold:
            return x[max(0, i - _ms(ONSET_LEAD_MS)):]
    raise BuildError("source is silent")


def cut(x: list[float], ms: int) -> list[float]:
    return x[: _ms(ms)]


def fade_out(x: list[float], ms: float) -> list[float]:
    """Linear fade over the last `ms`, the final sample exactly 0."""
    n = min(_ms(ms), len(x))
    if n < 2:
        return x
    out = list(x)
    start = len(x) - n
    for k in range(n):
        out[start + k] = x[start + k] * (n - 1 - k) / (n - 1)
    return out


def gain(x: list[float], db: float) -> list[float]:
    g = 10.0 ** (db / 20.0)
    return [v * g for v in x]


def peak(x: list[float]) -> float:
    return max(abs(v) for v in x)


def loudness_db(x: list[float]) -> float:
    """The largest RMS over any 50 ms window, in dBFS. Windows step by 551
    samples and the last partial window is ignored (D3 step 4)."""
    best = 0.0
    for start in range(0, len(x) - WINDOW + 1, WINDOW_STEP):
        energy = math.fsum(v * v for v in x[start:start + WINDOW]) / WINDOW
        best = max(best, energy)
    if best == 0.0:
        raise BuildError("clip is silent")
    return 10.0 * math.log10(best / (32768.0 * 32768.0))


def _ceiling() -> float:
    # Whole sample units, rounded down, so int16 rounding cannot pass
    # -1.0 dBFS.
    return float(int(32768.0 * 10.0 ** (CEILING_DBFS / 20.0)))


def _under_ceiling(x: list[float]) -> bool:
    """True when the int16 rounding of every sample is within the ceiling
    (float noise of a few ulps above it is not an overshoot)."""
    return peak(x) < _ceiling() + 0.5


def limit(x: list[float]) -> tuple[list[float], float]:
    """Peak limiter at the ceiling: 2 ms look-ahead, instant attack, 50 ms
    exponential release, gain floor -9 dB. Returns the limited samples and
    the largest gain reduction in dB (a positive number). The caller checks
    the peak: a sample the floor leaves above the ceiling stays there."""
    ceiling = _ceiling()
    look = _ms(LIMIT_LOOKAHEAD_MS)
    keep = math.exp(-1.0 / (LIMIT_RELEASE_MS / 1000.0 * SAMPLE_RATE))
    floor = 10.0 ** (-LIMIT_MAX_REDUCTION_DB / 20.0)
    need = [min(1.0, ceiling / abs(v)) if v else 1.0 for v in x]
    out = []
    state = 1.0
    lowest = 1.0
    for i, v in enumerate(x):
        want = min(need[i:i + look + 1])
        state = min(want, 1.0 - (1.0 - state) * keep)
        state = max(state, floor)
        lowest = min(lowest, state)
        out.append(v * state)
    return out, -20.0 * math.log10(lowest)


def normalise_loudness(
    x: list[float], cue_id: str, target_db: float
) -> tuple[list[float], dict]:
    """Scale to `target_db` loudness under the peak ceiling. The pre-limiter
    gain starts at the target scaling and rises in 0.1 dB steps; the first
    step whose limited output has its peak under the ceiling, no more than
    9 dB of limiting and a loudness within 0.5 dB of the target wins
    (amendment 3). Returns the samples and a stats dict."""
    base = gain(x, target_db - loudness_db(x))
    best_seen = None
    for step in range(SEARCH_STEPS + 1):
        extra = step * SEARCH_STEP_DB
        # An attenuated source's -40 dBFS point moves later once scaled, so
        # step 3 is applied again at the output level (D3 acceptance: onset
        # within 15 ms of the written file).
        scaled = strip_leading_silence(gain(base, extra))
        if _under_ceiling(scaled):
            out, reduction = scaled, 0.0
        else:
            out, reduction = limit(scaled)
            if not _under_ceiling(out):
                break
        # Measure what will be written: the int16 rounding of the output.
        out = [float(max(-32768, min(32767, round(v)))) for v in out]
        got = loudness_db(out)
        if best_seen is None or got > best_seen:
            best_seen = got
        if abs(got - target_db) <= LOUDNESS_TOLERANCE_DB:
            return out, {
                "loudness": got,
                "target": target_db,
                "reduction": reduction,
                "pregain": extra,
            }
    raise LoudnessShortfall(
        f"{cue_id}: target {target_db:.2f} dBFS cannot be met under "
        f"{CEILING_DBFS} dBFS with at most {LIMIT_MAX_REDUCTION_DB:.0f} dB "
        f"of limiting; best is {best_seen:.2f} dBFS, short by "
        f"{target_db - best_seen:.2f} dB"
    )


def to_pcm16(x: list[float]) -> bytes:
    out = array.array("h")
    for v in x:
        out.append(max(-32768, min(32767, int(round(v)))))
    if sys.byteorder == "big":
        out.byteswap()
    return out.tobytes()


def wav_bytes(pcm: bytes) -> bytes:
    """RIFF/WAVE PCM mono 16-bit, a 44-byte header and no extra chunks."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def _build_no_move(clip: Clip, zips: dict[str, str]) -> list[float]:
    """The throw, 40 ms of silence, then the impact mixed 6 dB under the
    throw's own peak (C-468 D2)."""
    throw = strip_leading_silence(decode(zips[clip.source.pack], clip.source.path))
    impact = strip_leading_silence(
        decode(zips[NO_MOVE_IMPACT.pack], NO_MOVE_IMPACT.path)
    )
    impact = fade_out(cut(impact, NO_MOVE_IMPACT_CUT_MS), NO_MOVE_IMPACT_FADE_MS)
    impact = gain(impact, NO_MOVE_IMPACT_DB - 20.0 * math.log10(peak(impact) / peak(throw)))
    offset = len(throw) + _ms(NO_MOVE_GAP_MS)
    mix = list(throw) + [0.0] * (offset + len(impact) - len(throw))
    for i, v in enumerate(impact):
        mix[offset + i] += v
    return mix


def build_clip(clip: Clip, zips: dict[str, str]) -> tuple[bytes, dict]:
    """The WAV bytes and a stats dict (loudness, target, limiter)."""
    if clip.cue_id == "no_move":
        x = _build_no_move(clip, zips)
        named_fade_ends = True
    else:
        x = strip_leading_silence(decode(zips[clip.source.pack], clip.source.path))
        named_fade_ends = False
        if clip.cut_ms is not None:
            x = cut(x, clip.cut_ms)
        if clip.fade_ms is not None:
            x = fade_out(x, clip.fade_ms)
            named_fade_ends = True
    if not named_fade_ends:
        x = fade_out(x, TAIL_FADE_MS)
    seconds = len(x) / SAMPLE_RATE
    if seconds > clip.max_s:
        raise BuildError(
            f"{clip.cue_id}: {seconds:.3f} s exceeds its {clip.max_s:.2f} s maximum"
        )
    target = REFERENCE_DBFS + clip.trim_db
    x, stats = normalise_loudness(x, clip.cue_id, target)
    return wav_bytes(to_pcm16(x)), stats


def write_atomic(path: str, data: bytes) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".fb-", suffix=".part")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main() -> int:
    try:
        zips = {key: fetch_pack(key) for key in PACKS}
    except (BuildError, OSError) as e:
        print(f"build_feedback_sounds: {e}", file=sys.stderr)
        return 1
    # Build every clip before writing any (D3 step 6), and report every
    # clip that fails, not just the first.
    built = []
    failures = []
    for c in CLIPS:
        try:
            built.append((c.cue_id, *build_clip(c, zips)))
        except BuildError as e:
            failures.append(str(e))
    if failures:
        for f in failures:
            print(f"build_feedback_sounds: {f}", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"reference level {REFERENCE_DBFS:.1f} dBFS")
    for cue_id, data, st in built:
        write_atomic(os.path.join(OUT_DIR, f"fb_{cue_id}.wav"), data)
        print(
            f"fb_{cue_id}.wav  {len(data)} bytes  loudness "
            f"{st['loudness']:.2f} dBFS (target {st['target']:.2f}), "
            f"pre-gain +{st['pregain']:.1f} dB, "
            f"limiter {st['reduction']:.2f} dB"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
