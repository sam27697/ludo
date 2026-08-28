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

## Palette

Copied from `packages/ludo_client/lib/src/board.dart:181-184` (the four seat
colours) and `:200` (the board's off-white ground). If the board's own
colours change, this script has to be edited by hand to match; it does not
import the Dart source.

    seat 0  #D32F2F  red
    seat 1  #388E3C  green
    seat 2  #FBC02D  yellow
    seat 3  #1976D2  blue
    ground  #F7F3E9  off-white

## Font

`feature-1024x500.png` carries the only text in either image, the wordmark
"Ludo RNG". It is set in DejaVu Sans Bold, found on this machine at
`/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf`, a real vector font,
not PIL's bitmap default.

## The motif, and why it changed (order 059)

The first version of these images (order 054) was four flat colour squares
in a 2x2 grid separated by a thin cross -- the exact layout and exact
positional colour assignment of a very well known corporate mark. The
colours were honest, taken straight from the board, but a 2x2 grid of flat
colour is generic enough that it reads as that mark before it reads as
anything else. Neither asset from that version was ever uploaded anywhere.

This version draws the board itself rather than an abstraction of it, using
the same construction `packages/ludo_client/lib/src/board_geometry.dart`
uses: one seat's shape, rotated three times about the board centre. Nothing
here is imported from the Dart source, so if that file's geometry ever
changes, the coordinates in `store_graphics.py` need updating by hand to
match, the same as the palette above. What's on screen, structurally:

- the four 6x6 yards, full bleed, one per seat
- each seat's home column: a bordered lane in that seat's colour, running
  from its yard to the centre, the same cells
  `board_geometry.dart`'s `_homeColumn` returns for that seat
- the centre 3x3 block, outlined, split by two drawn diagonals into four
  triangles, each coloured to match the arm that arrives at that side of it
- the eight starred safe squares of the shared track (`docs/RULES.md`
  section 1.3: the four entry squares and the square eight ahead of each),
  marked as small ringed circles
- an outlined border around the cross itself, so the shape reads as a
  bordered plus rather than colour bleeding straight into colour at the
  yard edge

Everything is drawn flat, at 4x the output size, then downsampled with
Lanczos resampling so diagonal edges (the centre split, the star rings)
anti-alias instead of stair-stepping. The resampling is deterministic --
same input pixels every run -- so it does not break the byte-for-byte
reproducibility the generator is for.

## Judgement call for the reviewer

**What the icon is not, checked deliberately:**

- It is not the four-flat-squares mark order 054 accidentally produced. That
  mark has no internal structure at all beyond the four fields and a plain
  gap between them; this one has a bordered cross, four bordered home lanes
  reaching inward, eight marked safe squares, and a bordered, diagonally
  split centre block. None of that exists in a flat four-square mark.
- It is not a generic four-colour pinwheel or flower mark (the kind of
  rotationally-symmetric four-petal shape a few other apps use in this same
  red/green/yellow/blue palette). Every coloured region here is a straight
  rectangle or a straight-edged triangle bounded by a visible outline, laid
  out on a labelled grid, not a smooth curved petal converging on a point;
  the outlines and the grid are what keep it reading as a diagram of a board
  rather than as an abstract mark.
- It is not a dartboard or target mark. The concentric-rings resemblance a
  plain diamond-in-a-square centre could invite is broken up by the visible
  cross arms running to all four edges of the icon, which no target mark has.

At 48x48 (`icon-48-check.png`) the fine detail does not survive: the star
rings and the thin lane outlines shrink past the point of being distinct
brush strokes. What does survive is the silhouette the order asked to be
kept if the rest does not fit: four colour quadrants, a cross of the
board's own ground colour connecting them, coloured lanes running along
that cross into the centre, and a small multicoloured patch at the middle
where the lanes meet. That silhouette is still a cross with structure in
it, not a plain 2x2 grid, which is the property this round exists to
guarantee.

## What this order did not touch

The app's launcher icon (the icon inside the AAB itself) is a separate asset
and this order does not produce or change it.
