#!/usr/bin/env python3
"""Generates the feedback service's short cue sounds.

work/ludo/orders/C-225-feedback.md: nine 16-bit mono 44.1 kHz WAV clips,
one per FeedbackCue except invalid_tap (doctrine section 3's table: no
sound for an invalid tap), written to
android/app/src/main/res/raw/fb_<id>.wav.

Every clip is a synthesised tone with a fast attack and a slower decay:
a chime for your_turn, a click for can_move, a low tone for no_move, a
tick for step, a hit for captured_other, a thud for captured_me, a rising
bright tone for home, a short rising fanfare for win, and a soft falling
close for game_over. Nothing is downloaded and nothing is random: every
sample is a fixed function of its position, so running this script twice
produces byte-identical files.

Standard library only: wave, math, struct.
"""

from __future__ import annotations

import math
import os
import struct
import wave

SAMPLE_RATE = 44100

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(
    os.path.dirname(_HERE), "android", "app", "src", "main", "res", "raw"
)


def _envelope(index: int, total: int, attack: int, release: int) -> float:
    """The 0..1 gain at sample `index` of `total`: a linear ramp up over
    the first `attack` samples, a linear ramp down over the last `release`
    samples, and 1.0 in between. A fast attack and a slower release is
    what keeps a synthesised tone from clicking at its edges while still
    landing instantly."""
    if attack > 0 and index < attack:
        return index / attack
    remaining = total - index
    if release > 0 and remaining < release:
        return max(0.0, remaining / release)
    return 1.0


def _tone(
    duration_s: float,
    freq_start: float,
    freq_end: float | None = None,
    amplitude: float = 0.5,
    attack_s: float = 0.004,
    release_s: float = 0.05,
    harmonic: tuple[float, float] | None = None,
) -> list[float]:
    """One sweep from `freq_start` to `freq_end` (a fixed tone when
    `freq_end` is None) over `duration_s`, shaped by `_envelope`.
    `harmonic`, an optional `(ratio, weight)`, adds a second partial on
    top of the fundamental so a hit or a thud reads as more than a plain
    sine."""
    if freq_end is None:
        freq_end = freq_start
    total = max(1, int(SAMPLE_RATE * duration_s))
    attack = max(1, int(SAMPLE_RATE * attack_s))
    release = max(1, int(SAMPLE_RATE * release_s))
    samples: list[float] = []
    phase = 0.0
    for i in range(total):
        freq = freq_start + (freq_end - freq_start) * (i / total)
        phase += 2 * math.pi * freq / SAMPLE_RATE
        value = math.sin(phase)
        if harmonic is not None:
            ratio, weight = harmonic
            value = (value + weight * math.sin(phase * ratio)) / (1 + weight)
        gain = _envelope(i, total, attack, release) * amplitude
        samples.append(value * gain)
    return samples


def _silence(duration_s: float) -> list[float]:
    return [0.0] * max(0, int(SAMPLE_RATE * duration_s))


def _chain(*parts: list[float]) -> list[float]:
    joined: list[float] = []
    for part in parts:
        joined.extend(part)
    return joined


def _clip(samples: list[float]) -> bytes:
    frames = bytearray()
    for value in samples:
        bounded = max(-1.0, min(1.0, value))
        frames += struct.pack("<h", int(round(bounded * 32767)))
    return bytes(frames)


# One clip per FeedbackCue id except invalid_tap (doctrine: no sound).
_CLIPS: dict[str, list[float]] = {
    # A short, bright chime: one soft tick.
    "your_turn": _tone(0.22, 1046.5, amplitude=0.5, attack_s=0.003, release_s=0.12),
    # A positive click: quick, higher, snaps off fast.
    "can_move": _tone(0.05, 1800.0, amplitude=0.55, attack_s=0.001, release_s=0.03),
    # A low, short tone: firm, unmistakably a "no".
    "no_move": _tone(0.24, 200.0, amplitude=0.5, attack_s=0.005, release_s=0.15),
    # A very short tick, quiet enough to repeat without fatigue.
    "step": _tone(0.02, 2600.0, amplitude=0.4, attack_s=0.001, release_s=0.012),
    # A hit: a fast downward snap with a second partial for body.
    "captured_other": _tone(
        0.12, 700.0, 280.0, amplitude=0.6, attack_s=0.001, release_s=0.08,
        harmonic=(2.0, 0.3),
    ),
    # A thud: low and short, the opposite of a chime.
    "captured_me": _tone(0.18, 95.0, 55.0, amplitude=0.6, attack_s=0.002, release_s=0.15),
    # A rising, bright tone: low to high over under half a second.
    "home": _tone(0.45, 500.0, 1400.0, amplitude=0.5, attack_s=0.01, release_s=0.15),
    # A short rising fanfare: four ascending notes with small gaps.
    "win": _chain(
        _tone(0.16, 523.25, amplitude=0.55, attack_s=0.004, release_s=0.06),
        _silence(0.02),
        _tone(0.16, 659.25, amplitude=0.55, attack_s=0.004, release_s=0.06),
        _silence(0.02),
        _tone(0.16, 784.0, amplitude=0.55, attack_s=0.004, release_s=0.06),
        _silence(0.02),
        _tone(0.28, 1046.5, amplitude=0.6, attack_s=0.004, release_s=0.2),
    ),
    # A soft falling close: high to low, quiet, unhurried.
    "game_over": _tone(0.4, 500.0, 250.0, amplitude=0.35, attack_s=0.015, release_s=0.25),
}


def write_all() -> list[str]:
    """Writes every clip in `_CLIPS`, returns the paths written."""
    os.makedirs(OUT_DIR, exist_ok=True)
    written = []
    for cue_id, samples in _CLIPS.items():
        path = os.path.join(OUT_DIR, "fb_{0}.wav".format(cue_id))
        with wave.open(path, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(SAMPLE_RATE)
            wav_file.writeframes(_clip(samples))
        written.append(path)
    return written


if __name__ == "__main__":
    for written_path in write_all():
        print(written_path)
