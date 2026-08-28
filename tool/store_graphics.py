#!/usr/bin/env python3
"""Generates the two Play Store listing images from the board's own palette
and the board's own geometry.

Run with:

    python3 tool/store_graphics.py

Regenerates, from scratch and deterministically, every time:

    assets/store/icon-512.png
    assets/store/icon-48-check.png
    assets/store/feature-1024x500.png

The palette here is copied from packages/ludo_client/lib/src/board.dart
(_seatColors, lines 181-184, and the board ground fill at line 200). If the
board's colours ever change, change them here to match -- this script does
not read the Dart source, so the two are kept in sync by a human, not by
import.

Round 2 (order 059): round 1's motif was four flat colour squares in a 2x2
grid, which is the Microsoft logo's exact layout and colour assignment. This
version draws the actual Ludo board -- the same board that
packages/ludo_client/lib/src/board_geometry.dart computes -- rather than an
abstraction of it: the four yards, the three-wide track, the coloured home
column reaching from each yard into the centre, the eight starred safe
squares (docs/RULES.md section 1.3), and the four-way split centre triangle.
Nothing here is imported from the Dart source; the coordinates below are the
same rotation construction board_geometry.dart uses (one seat-0 template,
rotated three times about the board centre), reimplemented in Python because
this script has no Dart runtime to import from. If board_geometry.dart's
layout ever changes, this has to change by hand to match, same as the
palette below.

Round 3 (order 064): round 2 fixed the structure but left the quadrant
colour assignment exactly where round 1 (and the un-reviewed run 18 build)
put it -- red top-left, green top-right, blue bottom-left, yellow
bottom-right, the Microsoft logo's own arrangement, position for position.
Real Ludo boards have no canonical colour-to-corner mapping, so this round
rotates the assignment (SEAT_COLORS below) by one seat. It also stopped
drawing the home column as a one-cell-wide pinstripe down the centre of each
arm: at 512px that line is already thin, and at 48px -- the size Play's own
list view actually shows most often -- it and the star rings vanish and
what is left is four flat squares, the exact failure this round exists to
fix. The home lane now fills the arm's full three-cell width, so each arm
reads as a solid coloured spoke running from its yard to the centre
pinwheel even after a 48px downscale, and the safe squares are drawn as
four solid dots (one per entry square) rather than eight thin outlined
rings, for the same reason: a filled dot survives Lanczos downsampling to
48px, a one-pixel ring does not.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "assets" / "store"

# packages/ludo_client/lib/src/board.dart:181-184, alpha byte dropped (opaque).
# These four RGB values are the board's real seat colours and are not
# touched by order 064 -- only which corner each one lands in changes,
# below.
SEAT_RED = (0xD3, 0x2F, 0x2F)
SEAT_GREEN = (0x38, 0x8E, 0x3C)
SEAT_YELLOW = (0xFB, 0xC0, 0x2D)
SEAT_BLUE = (0x19, 0x76, 0xD2)

# Which colour sits in which seat slot (seat slot 0 is the top-left yard and
# the arm reaching left, slot 1 is top-right and the arm reaching up, slot 2
# is bottom-right and the arm reaching right, slot 3 is bottom-left and the
# arm reaching down -- see YARD_CORNERS and _TRACK_QUARTER below). A real
# Ludo board has no fixed colour-to-corner mapping, so this ordering is
# free. Round 1 and round 2 both left it red/green/yellow/blue clockwise
# from the top-left, which is the Microsoft logo's own layout and colour
# assignment, corner for corner. Order 064: rotate the list by one seat so
# every corner's colour changes. Still the same four colours, still a
# clockwise cycle red -> green -> yellow -> blue -> red, just entered one
# seat later.
SEAT_COLORS = [SEAT_GREEN, SEAT_YELLOW, SEAT_BLUE, SEAT_RED]

# packages/ludo_client/lib/src/board.dart:200
BOARD_GROUND = (0xF7, 0xF3, 0xE9)

# packages/ludo_client/lib/src/board.dart:270, the board's own outline stroke.
BOARD_OUTLINE = (0x42, 0x42, 0x42)

FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
WORDMARK = "Ludo RNG"

# Supersample factor: the board is drawn this many times larger than the
# final output and downscaled with Lanczos resampling, so the centre
# triangle's diagonal edges and the star markers anti-alias instead of
# stair-stepping. Deterministic: no randomness, no clock, same input pixels
# every run.
SUPERSAMPLE = 4

# --- Board geometry, reimplemented from board_geometry.dart -----------------
#
# The board is a 15 by 15 grid. Four 6x6 yards fill the corners. Everything
# else is the cross: three cells wide along each arm, out to the edge.
# board_geometry.dart builds seats 1, 2 and 3 by rotating seat 0's cells 90,
# 180 and 270 degrees about the board centre (7, 7); this mirrors that
# construction so the two files can never drift apart in the shape of the
# board, only in which pixels get painted.

BOARD_UNITS = 15
YARD_SPAN = 6


def _rotate(cell: tuple[int, int]) -> tuple[int, int]:
    """90 degree clockwise rotation about (7, 7). Same transform as
    board_geometry.dart's _rotate: (col, row) -> (14 - row, col)."""
    col, row = cell
    return (14 - row, col)


def _rotate_by(cell: tuple[int, int], quarters: int) -> tuple[int, int]:
    for _ in range(quarters):
        cell = _rotate(cell)
    return cell


# The top-left corner (col, row) of each seat's 6x6 yard block. This is a
# block corner, not a cell, so it is not run through _rotate_by -- rotating
# a single point 90 degrees about (7, 7) does not land on the corner of the
# rotated block. Taken as-is from board.dart's yardCorners: (0,0) seat0,
# (9,0) seat1, (9,9) seat2, (0,9) seat3.
YARD_CORNERS = [(0, 0), (9, 0), (9, 9), (0, 9)]

# Seat 0's thirteenth of the 52-square track: out along the top row of the
# left arm, around the corner, up the left side of the top arm, onto the tip.
# board_geometry.dart's _trackQuarter, unchanged.
_TRACK_QUARTER = [
    (0, 6), (1, 6), (2, 6), (3, 6), (4, 6), (5, 6),
    (6, 5), (6, 4), (6, 3), (6, 2), (6, 1), (6, 0),
    (7, 0),
]

# The 52 track cells in absolute travel order, index 0 is seat 0's entry.
TRACK = [
    _rotate_by(cell, quarter)
    for quarter in range(4)
    for cell in _TRACK_QUARTER
]

# docs/RULES.md section 1.3: the four entry squares plus the square eight
# ahead of each are the starred safe squares -- eight in total, the true
# rule.
SAFE_TRACK_INDICES = [0, 8, 13, 21, 26, 34, 39, 47]

# Order 064: the icon draws only the four entry squares (one per seat) as
# large filled dots, not all eight as thin rings. Eight thin rings do not
# survive a Lanczos downscale to 48px -- they were already gone in the
# icon-48-check.png that prompted this order -- and a dot that has shrunk
# to nothing is worse than not drawing it, because it is one more shape
# competing for space at full size for no payoff at the size that matters.
# This does not change what a real board's safe squares are; it changes
# what this one small bitmap has room to show.
ICON_STAR_INDICES = [0, 13, 26, 39]

# Seat 0's home column, progress 52..56, running inward from the left arm
# toward the centre. board_geometry.dart's _homeColumn, unchanged.
_HOME_SEAT0 = [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7)]
HOME_COLUMNS = [[_rotate_by(c, s) for c in _HOME_SEAT0] for s in range(4)]


def _grid(x0: float, y0: float, size: float) -> list[float]:
    """Sixteen pixel boundaries for a 15-unit grid inside a size x size box."""
    unit = size / BOARD_UNITS
    return [x0 + round(unit * i) for i in range(BOARD_UNITS + 1)]


def draw_board(draw: ImageDraw.ImageDraw, x0: float, y0: float, size: float) -> None:
    """Draws the board motif: the four yards, each arm's home lane reaching
    into the centre, four of the eight starred safe squares, and the centre
    split four ways to match the arm that feeds it. Caller is responsible
    for the ground fill under this box.
    """
    xs = _grid(x0, y0, size)
    ys = _grid(y0, y0, size)  # same units, board is square
    unit = size / BOARD_UNITS

    def cell_box(col: int, row: int, width: int = 1, height: int = 1) -> list[float]:
        return [
            xs[col], ys[row],
            xs[col + width] - 1, ys[row + height] - 1,
        ]

    # Order 064: thicker than round 2's 0.09 so the border between a
    # coloured region and its neighbour stays visible after a 48px
    # downscale instead of anti-aliasing away to nothing.
    line_width = max(1, round(unit * 0.16))

    # Four yards, full bleed at the corners.
    for seat, (col, row) in enumerate(YARD_CORNERS):
        draw.rectangle(
            cell_box(col, row, YARD_SPAN, YARD_SPAN),
            fill=SEAT_COLORS[seat],
        )

    # The cross itself, outlined where it meets the yards, so the shape
    # reads as a bordered plus rather than colour bleeding into colour. The
    # vertical arm and the horizontal arm overlap at the centre block; that
    # is fine, the centre gets its own outline afterward.
    draw.rectangle(
        [xs[6], y0, xs[9] - 1, y0 + size - 1],
        outline=BOARD_OUTLINE,
        width=line_width,
    )
    draw.rectangle(
        [x0, ys[6], x0 + size - 1, ys[9] - 1],
        outline=BOARD_OUTLINE,
        width=line_width,
    )

    # Each seat's home column: the coloured lane running from its yard's
    # edge to the centre, each outlined so the lane reads as its own
    # bordered strip rather than a shape that bleeds straight into the
    # centre triangle beside it.
    #
    # HOME_COLUMNS gives the true board's home column, which is one cell
    # wide -- the middle third of the three-cell arm. Drawn at one cell
    # wide it is a pinstripe: visible at 512px, gone at 48px, which was
    # exactly round 2's failure (order 064's opening measurement: "a pale
    # cross" with "the home columns gone"). The icon draws the lane at the
    # arm's full three-cell width instead, so each arm becomes one solid
    # coloured spoke reaching from its yard into the centre pinwheel. This
    # departs from the literal board -- a real lane is one cell wide, not
    # three -- which is the simplification order 064 permits explicitly:
    # simplify toward the board's silhouette, not back toward flat squares.
    for seat in range(4):
        cols = [c for c, _ in HOME_COLUMNS[seat]]
        rows = [r for _, r in HOME_COLUMNS[seat]]
        if min(rows) == max(rows):
            # Horizontal arm (east/west): keep the lane's length (its
            # column span) and widen it to the arm's full row band.
            col_lo, col_hi = min(cols), max(cols)
            row_lo, row_hi = 6, 8
        else:
            # Vertical arm (north/south): keep the lane's length (its row
            # span) and widen it to the arm's full column band.
            row_lo, row_hi = min(rows), max(rows)
            col_lo, col_hi = 6, 8
        lane_box = cell_box(
            col_lo, row_lo,
            col_hi - col_lo + 1, row_hi - row_lo + 1,
        )
        draw.rectangle(lane_box, fill=SEAT_COLORS[seat])
        draw.rectangle(lane_box, outline=BOARD_OUTLINE, width=line_width)

    # The centre 3x3 block, split into four triangles that meet at its
    # middle point, each coloured to match the arm that arrives at that
    # side of the block. The two diagonals are drawn as visible lines, and
    # the block carries its own outline, so the centre reads as a bordered
    # diamond sitting inside the cross rather than merging with the lanes
    # either side of it into a single arrow shape.
    cx0, cy0 = xs[6], ys[6]
    cx1, cy1 = xs[9], ys[9]
    mid = ((cx0 + cx1) / 2, (cy0 + cy1) / 2)
    # Each triangle takes the colour of the seat whose arm arrives at that
    # side, by geometry, not by seat number: seat 1's arm always arrives at
    # the top, seat 2's at the right, seat 3's at the bottom, seat 0's at
    # the left, regardless of which colour SEAT_COLORS assigns that seat.
    # Reading off SEAT_COLORS[seat] here, instead of naming a colour
    # directly, is what makes the round-064 colour rotation apply to the
    # centre automatically instead of leaving it one rotation behind the
    # yards and lanes.
    draw.polygon([(cx0, cy0), (cx1, cy0), mid], fill=SEAT_COLORS[1])  # top: seat 1
    draw.polygon([(cx1, cy0), (cx1, cy1), mid], fill=SEAT_COLORS[2])  # right: seat 2
    draw.polygon([(cx1, cy1), (cx0, cy1), mid], fill=SEAT_COLORS[3])  # bottom: seat 3
    draw.polygon([(cx0, cy1), (cx0, cy0), mid], fill=SEAT_COLORS[0])  # left: seat 0
    draw.line([(cx0, cy0), (cx1, cy1)], fill=BOARD_OUTLINE, width=line_width)
    draw.line([(cx1, cy0), (cx0, cy1)], fill=BOARD_OUTLINE, width=line_width)
    draw.rectangle([cx0, cy0, cx1 - 1, cy1 - 1], outline=BOARD_OUTLINE, width=line_width)

    # The four entry safe squares (ICON_STAR_INDICES, see above), drawn as
    # solid dots rather than the true board's thin outlined rings, so they
    # still read as marks at 48px instead of anti-aliasing into the ground.
    star_radius = unit * 0.32
    for idx in ICON_STAR_INDICES:
        col, row = TRACK[idx]
        ccx = xs[col] + (xs[col + 1] - xs[col]) / 2
        ccy = ys[row] + (ys[row + 1] - ys[row]) / 2
        draw.ellipse(
            [ccx - star_radius, ccy - star_radius, ccx + star_radius, ccy + star_radius],
            fill=BOARD_OUTLINE,
        )

    outline_width = max(2, round(size * 0.008))
    draw.rectangle(
        [x0, y0, x0 + size - 1, y0 + size - 1],
        outline=BOARD_OUTLINE,
        width=outline_width,
    )


def make_icon() -> Image.Image:
    size = 512
    hi_size = size * SUPERSAMPLE
    im = Image.new("RGB", (hi_size, hi_size), BOARD_GROUND)
    draw = ImageDraw.Draw(im)
    draw_board(draw, 0, 0, hi_size)
    return im.resize((size, size), Image.LANCZOS)


def _fit_font(draw: ImageDraw.ImageDraw, text: str, max_width: int, max_height: int) -> ImageFont.FreeTypeFont:
    """Largest integer point size of FONT_PATH whose rendered bbox for text
    fits inside max_width x max_height.
    """
    lo, hi = 8, 1600
    best = ImageFont.truetype(FONT_PATH, lo)
    while lo <= hi:
        mid = (lo + hi) // 2
        font = ImageFont.truetype(FONT_PATH, mid)
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        if w <= max_width and h <= max_height:
            best = font
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def make_feature() -> Image.Image:
    width, height = 1024, 500
    hi_width, hi_height = width * SUPERSAMPLE, height * SUPERSAMPLE
    im = Image.new("RGB", (hi_width, hi_height), BOARD_GROUND)
    draw = ImageDraw.Draw(im)

    # Safe area: centred ~924x400 (scaled by SUPERSAMPLE here), so content
    # stays clear of Play's own edge overlays.
    safe_left, safe_top = 50 * SUPERSAMPLE, 50 * SUPERSAMPLE
    safe_right = hi_width - 50 * SUPERSAMPLE
    safe_bottom = hi_height - 50 * SUPERSAMPLE

    # Board motif on the left half of the safe area.
    board_size = 380 * SUPERSAMPLE
    board_x0 = safe_left + 22 * SUPERSAMPLE
    board_y0 = (hi_height - board_size) // 2
    draw_board(draw, board_x0, board_y0, board_size)

    # Wordmark on the right half of the safe area, vertically centred.
    text_zone_left = board_x0 + board_size + 40 * SUPERSAMPLE
    text_zone_right = safe_right
    text_max_w = text_zone_right - text_zone_left
    text_max_h = 170 * SUPERSAMPLE

    font = _fit_font(draw, WORDMARK, text_max_w, text_max_h)
    bbox = draw.textbbox((0, 0), WORDMARK, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = text_zone_left + (text_max_w - text_w) // 2 - bbox[0]
    text_y = (hi_height - text_h) // 2 - bbox[1]
    draw.text((text_x, text_y), WORDMARK, font=font, fill=SEAT_BLUE)

    assert safe_top <= board_y0 and board_y0 + board_size <= safe_bottom
    return im.resize((width, height), Image.LANCZOS)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    icon = make_icon()
    icon.save(OUT_DIR / "icon-512.png", format="PNG")

    check = icon.resize((48, 48), Image.LANCZOS)
    check.save(OUT_DIR / "icon-48-check.png", format="PNG")

    feature = make_feature()
    feature.save(OUT_DIR / "feature-1024x500.png", format="PNG")


if __name__ == "__main__":
    main()
