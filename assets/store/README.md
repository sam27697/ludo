# Store graphics

Both images here are generated, not hand-drawn and not checked in as
unexplained binaries. The generator is `tool/store_graphics.py`; it is the
source of truth. To regenerate everything from scratch:

    python3 tool/store_graphics.py

The script fills these Play Console main-store-listing fields:

- `icon-512.png` -- **App icon**. 512x512 PNG, full bleed, no rounding or
  masking applied here (Play does that itself on upload).
- `feature-1024x500.png` -- **Feature graphic**. 1024x500 PNG.

`icon-48-check.png` is not uploaded anywhere. It is the icon downscaled to
48x48, the size that actually decides whether anyone taps it, kept next to
the full-size icon so a reviewer can look at the thing that matters.

## Why this is version 2

Versions 1 (orders 054 and 059) both drew the board itself: four flat colour
quadrants -- red, green, blue, yellow -- separated by a cross, with home lanes
and safe squares picked out inside it. Order 059's README argued at length that
this was not the well known four-square corporate mark, on the grounds that it
carries internal structure a flat 2x2 grid does not.

**Looking at the rendered pixels, that argument does not hold.** At full size
the resemblance is immediate, and at 48x48 -- the size the argument itself
named as the one that matters -- the lane outlines and safe-square rings
disappear and what is left is exactly a 2x2 grid of flat colour in that exact
palette. An icon that reads as another company's mark is a trademark question
before it is a design question, and it was never worth the risk for a board
diagram nobody can read at launcher size anyway.

Version 2 draws **the die**, which is what this product is actually about: the
dice are the feature, verifiable per roll, and the app is named for them. The
four seat colours survive as the four pips, so the Ludo palette is still
present without the layout that caused the resemblance. What is on screen:

- a vertical gradient ground in the app's own Material 3 purple
- a white, heavily rounded die, rotated slightly off-square so it reads as an
  object rather than a UI card
- four pips on the diagonals, one per seat colour, each outlined in the same
  near-black as the die's edge

At 48x48 the silhouette survives intact: a light rounded square on a dark
ground with four coloured dots. Nothing in it depends on detail that vanishes
when the icon is small.

## Palette

Seat colours copied from `packages/ludo_client/lib/src/board.dart:181-184`. If
the board's own colours change, this script has to be edited by hand to match;
it does not import the Dart source.

    seat 0  #D32F2F  red
    seat 1  #388E3C  green
    seat 2  #FBC02D  yellow
    seat 3  #1976D2  blue
    ground  #4A398C -> #2A1F54  (vertical gradient)
    die     #FAF7F0 on #1B1438 edge

## Font

`feature-1024x500.png` carries the only text in either image: the wordmark
"Ludo RNG" and two lines of subtitle. Set in Poppins (Bold for the wordmark,
Medium for the subtitle), real vector fonts, not PIL's bitmap default.

**The generator asserts that every line of that text ends inside the right
margin and fails loudly if it does not.** The first run of this version
produced a banner whose subtitle ran off the edge of the image; a store banner
is not the place to find that out by eye, so the check is now part of the
build.

## Rendering

Everything is drawn at 4x the output size and downsampled with Lanczos
resampling, so the die's rounded corners and the pip circles anti-alias
instead of stair-stepping. The resampling is deterministic -- same input
pixels every run -- so byte-for-byte reproducibility holds.

## What this does not touch

The app's launcher icon (the icon inside the AAB itself) is a separate asset
and this script does not produce or change it. It is generated instead by
`tool/launcher_icons.py`, which imports `draw_die` and `vertical_gradient`
from this module so the launcher icon and this store icon stay the same mark.
That script writes the adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml` plus
a background and foreground PNG per density, for API 26 and up) and the
legacy full-bleed `ic_launcher.png` at each of the five existing mipmap
densities (for API 24 and 25). Regenerate it with:

    python3 tool/launcher_icons.py
