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

The four colours are copied from `packages/ludo_client/lib/src/board.dart:181-184`
(the seat colours) and `:200` (the board's off-white ground). If the board's
own colours change, this script has to be edited by hand to match; it does
not import the Dart source.

    #D32F2F  red
    #388E3C  green
    #FBC02D  yellow
    #1976D2  blue
    #F7F3E9  off-white ground

Which colour sits in which corner of the icon is a separate decision (see
"the quadrant arrangement" below) -- a real Ludo board has no fixed
colour-to-corner rule, so nothing pins these four values to particular seat
numbers or particular corners.

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

Order 059 drew the board itself rather than an abstraction of it, using the
same construction `packages/ludo_client/lib/src/board_geometry.dart` uses:
one seat's shape, rotated three times about the board centre. Nothing here
is imported from the Dart source, so if that file's geometry ever changes,
the coordinates in `store_graphics.py` need updating by hand to match, the
same as the palette above. That fixed the icon's structure at 512x512. It
did not fix the icon at 48x48, and it did not fix the colour arrangement --
both are order 064's subject, below.

## The quadrant arrangement (order 064)

Order 059's board still put red in the top-left yard, green top-right, blue
bottom-left, yellow bottom-right -- the same corner-for-corner arrangement
as a very well known corporate mark, carried over unexamined from order 054
because a real Ludo board has no fixed colour-to-corner rule, so nobody had
reason to look at it twice. `icon-512.png` at 512x512 has enough other
structure that the resemblance is arguable; at 48x48, before order 064, the
detail that argues against it disappears and only the four flat quadrants
and their positions are left, which made the resemblance the icon's whole
content at the one size Play's own list view shows most often.

`SEAT_COLORS` in `store_graphics.py` now reads `[green, yellow, blue, red]`
instead of `[red, green, yellow, blue]` -- the same four colours, the same
clockwise cycle, rotated by one seat. Every one of the four quadrants
changed colour:

    corner        before order 064      after order 064
    top-left      red                   green
    top-right     green                 yellow
    bottom-right  yellow                blue
    bottom-left   blue                  red

## What the icon looks like now, structurally

- the four 6x6 yards, full bleed, one per seat, in the rotated colour order
  above
- each seat's home lane, reaching from its yard to the centre -- drawn at
  the arm's full three-cell width rather than the true board's one-cell
  lane (see "Why the lane got wider" below)
- the centre 3x3 block, outlined, split by two drawn diagonals into four
  triangles, each coloured to match the arm that arrives at that side of it
- four of the track's eight starred safe squares (`docs/RULES.md` section
  1.3), the four entry squares, one per seat, drawn as solid dots rather
  than the true board's thin outlined rings
- an outlined border around the cross itself, so the shape reads as a
  bordered plus rather than colour bleeding straight into colour at the
  yard edge

Everything is drawn flat, at 4x the output size, then downsampled with
Lanczos resampling so diagonal edges (the centre split) anti-alias instead
of stair-stepping. The resampling is deterministic -- same input pixels
every run -- so it does not break the byte-for-byte reproducibility the
generator is for.

### Why the lane got wider, and the star count got smaller

Order 059's home lane was one cell wide, matching the true board. Drawn one
cell wide inside a three-cell arm, it renders as a thin coloured pinstripe
down the middle of an otherwise ground-coloured arm. That pinstripe
anti-aliases into the ground colour well before 48x48; so do the star
rings. What is left once both are gone is four flat quadrants and a faint
cross -- order 054's shape again, honest colours or not.

Order 064 widens the lane to the arm's full three-cell width, so each arm
becomes one solid coloured spoke reaching from its yard to the centre
pinwheel, and cuts the drawn safe squares from eight thin rings to four
solid dots (the entry square of each seat). Both changes trade literal
fidelity to `board_geometry.dart`'s exact cell widths for a shape that
survives the downscale, which is the trade order 064 asks for explicitly:
simplify toward the board's silhouette, not back toward flat squares.

## Judgement call for the reviewer

**What the icon is not, checked deliberately:**

- It is not the four-flat-squares mark order 054 accidentally produced, and
  it is not that mark's colour arrangement either, after order 064's
  rotation. The icon has a bordered cross, four bordered home lanes filling
  each arm, four marked safe squares, and a bordered, diagonally split
  centre block, in a colour order that puts no colour back in the corner it
  started in. None of that exists in a flat four-square mark.
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

**What `icon-48-check.png` actually looks like, at native size:** four
colour quadrants (green top-left, yellow top-right, red bottom-left, blue
bottom-right), separated by a dark-bordered off-white cross that is wide
enough to read as its own shape rather than a hairline. Each arm of that
cross carries a thick spoke in its yard's own colour running from the edge
in toward the middle, so the cross itself is not empty -- it is four
colour-matched spokes meeting at a small four-way pinwheel patch dead
centre, outlined and visibly split on the diagonal into the four arriving
colours. At each of the four points where a spoke reaches the icon's outer
edge, a small dark dot sits in the pale gap next to it -- the one surviving
safe-square mark per arm. Nothing in that description is "four coloured
squares with a cross"; the cross itself carries the same four colours as
the quadrants, arranged as spokes into a visible centre, which is
structure a flat 2x2 grid does not have at any size.

## What this order did not touch

The app's launcher icon (the icon inside the AAB itself) is a separate asset
and this order does not produce or change it.
