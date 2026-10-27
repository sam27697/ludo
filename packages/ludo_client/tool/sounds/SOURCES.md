# Feedback sound sources

Every clip in `android/app/src/main/res/raw/fb_*.wav` is cut from three
Kenney packs by `tool/build_feedback_sounds.py` (C-468 D1-D3). The packs
are downloaded into `$LUDO_SOUND_CACHE` (default `~/.cache/ludo-sounds`),
never committed, and checked against a pinned sha256:

| Pack | Archive | sha256 |
|---|---|---|
| Casino Audio 1.1 | `kenney_casino-audio.zip` | `f36250766ac5bc378c13708ddf12a23a8e54a3251f8d482c7536e51b5dbafa18` |
| Impact Sounds | `kenney_impact-sounds.zip` | `029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8` |
| Music Jingles | `kenney_music-jingles.zip` | `b729ba57959bd58793d2c5cafa348aaf2655d354f3da35ec4729e03ec77197b8` |

Licence of every pack: CC0 1.0,
`https://creativecommons.org/publicdomain/zero/1.0/`. The packs' own
`License.txt` files are in `LICENSE-kenney.txt`.

## Operations common to every clip

1. Decode to mono, 16-bit, 44100 Hz PCM.
2. Drop the samples before the first one at or above -40 dBFS, keeping
   2 ms before it.
3. The cuts, fades and mixes in the table.
4. A clip with no named closing fade gets a 15 ms linear fade-out to zero.
5. Normalise by loudness, not peak (C-468 D3 step 4, amendments 1 to 3).
   Loudness is the largest RMS over any 50 ms window (2205 samples,
   windows stepped by 551, the last partial window ignored). The target is
   the reference level R plus the clip's trim, with R = -19.0 dBFS (the
   `REFERENCE_DBFS` constant in the script, printed on every run). The
   pre-limiter gain starts at the target scaling and rises in 0.1 dB
   steps until the output is within 0.5 dB of the target. Where the peak
   would pass -1.0 dBFS, a deterministic limiter holds it there: 2 ms
   look-ahead, instant attack, 50 ms exponential release, at most 9 dB of
   gain reduction. Step 2 is applied again at the output level so the
   written file starts within 15 ms of its first sound.

## Clips

| Cue id | Pack | File in the zip | Operations | Trim (on R) | Licence |
|---|---|---|---|---|---|
| `your_turn` | Casino Audio | `Audio/dice-grab-1.ogg` | none beyond the common steps | -4 dB | CC0 1.0 |
| `can_move` | Casino Audio | `Audio/die-throw-2.ogg` | none beyond the common steps | 0 dB | CC0 1.0 |
| `no_move` | Casino Audio, Impact Sounds | `Audio/die-throw-4.ogg`, then `Audio/impactSoft_heavy_000.ogg` | the throw, 40 ms of silence, then the impact cut to its first 350 ms with a 30 ms fade-out, its peak 6 dB under the throw's peak, mixed in | 0 dB | CC0 1.0 |
| `step` | Impact Sounds | `Audio/impactWood_light_002.ogg` | first 150 ms, 20 ms fade-out | -8 dB | CC0 1.0 |
| `captured_other` | Impact Sounds | `Audio/impactWood_heavy_000.ogg` | none beyond the common steps | 0 dB | CC0 1.0 |
| `captured_me` | Impact Sounds | `Audio/impactPlank_medium_000.ogg` | first 650 ms, 60 ms fade-out | -2 dB | CC0 1.0 |
| `home` | Casino Audio | `Audio/chips-stack-1.ogg` | none beyond the common steps | 0 dB | CC0 1.0 |
| `win` | Music Jingles | `Audio/Pizzicato jingles/jingles_PIZZI02.ogg` | none beyond the common steps | 0 dB | CC0 1.0 |
| `game_over` | Music Jingles | `Audio/Pizzicato jingles/jingles_PIZZI13.ogg` | none beyond the common steps | -3 dB | CC0 1.0 |
| `die_land` | Casino Audio | `Audio/die-throw-1.ogg` | none beyond the common steps | -6 dB | CC0 1.0 |
| `gloat` | Music Jingles | `Audio/Sax jingles/jingles_SAX11.ogg` | none beyond the common steps | -3 dB | CC0 1.0 |

`invalid_tap` and `tap` have no clip. The 8-bit (`NES`) jingles are not
used.
