#!/usr/bin/env python3
"""Builds the feedback service's eleven cue clips from three pinned packs.

C-468 D1-D3: every clip is cut from the Kenney Casino Audio, Impact Sounds
and Music Jingles archives (CC0), downloaded once into a cache outside the
repository and checked against a pinned sha256. Each source is decoded to
mono 16-bit 44.1 kHz with ffmpeg, stripped of leading silence, cut, faded,
mixed, peak-normalised to -1.0 dBFS, trimmed and written to
android/app/src/main/res/raw/fb_<id>.wav.

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
PEAK_DBFS = -1.0
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


def normalise(x: list[float], target_db: float) -> list[float]:
    p = peak(x)
    if p == 0:
        raise BuildError("clip is silent")
    return gain(x, target_db - 20.0 * math.log10(p / 32768.0))


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


def build_clip(clip: Clip, zips: dict[str, str]) -> bytes:
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
    x = gain(normalise(x, PEAK_DBFS), clip.trim_db)
    return wav_bytes(to_pcm16(x))


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
        # Build every clip before writing any (D3 step 6).
        built = [(c.cue_id, build_clip(c, zips)) for c in CLIPS]
    except (BuildError, OSError) as e:
        print(f"build_feedback_sounds: {e}", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    for cue_id, data in built:
        write_atomic(os.path.join(OUT_DIR, f"fb_{cue_id}.wav"), data)
        print(f"fb_{cue_id}.wav  {len(data)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
