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

## Judgement call for the reviewer

The icon has no ornamentation beyond the four coloured yards, the cross left
in the board's own ground colour, and the board's own outline stroke
(`#424242`, also taken from `board.dart`). At 48x48 the four colours and the
cross both survive clearly: the corner blocks stay large solid fields and
the cross stays a clean unbroken band, because nothing in the icon is
thinner than a corner block or the outline stroke, and downscaling a flat
rectangle does not turn it to mud the way downscaling text or a fine line
does.
