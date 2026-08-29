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
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "assets" / "store"

# packages/ludo_client/lib/src/board.dart:181-184, alpha byte dropped (opaque).
SEAT_RED = (0xD3, 0x2F, 0x2F)  # seat 0, left arm and top-left yard
SEAT_GREEN = (0x38, 0x8E, 0x3C)  # seat 1, top arm and top-right yard
SEAT_YELLOW = (0xFB, 0xC0, 0x2D)  # seat 2, right arm and bottom-right yard
SEAT_BLUE = (0x19, 0x76, 0xD2)  # seat 3, bottom arm and bottom-left yard
SEAT_COLORS = [SEAT_RED, SEAT_GREEN, SEAT_YELLOW, SEAT_BLUE]

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
# ahead of each are the starred safe squares.
SAFE_TRACK_INDICES = [0, 8, 13, 21, 26, 34, 39, 47]

# Seat 0's home column, progress 52..56, running inward from the left arm
# toward the centre. board_geometry.dart's _homeColumn, unchanged.
_HOME_SEAT0 = [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7)]
HOME_COLUMNS = [[_rotate_by(c, s) for c in _HOME_SEAT0] for s in range(4)]


def _grid(x0: float, y0: float, size: float) -> list[float]:
    """Sixteen pixel boundaries for a 15-unit grid inside a size x size box."""
    unit = size / BOARD_UNITS
    return [x0 + round(unit * i) for i in range(BOARD_UNITS + 1)]


def draw_board(draw: ImageDraw.ImageDraw, x0: float, y0: float, size: float) -> None:
    """Draws the board motif: the four yards, the coloured home column of
    each arm reaching into the centre, the eight starred safe squares, and
    the centre split four ways to match the arm that feeds it. Caller is
    responsible for the ground fill under this box.
    """
    xs = _grid(x0, y0, size)
    ys = _grid(y0, y0, size)  # same units, board is square
    unit = size / BOARD_UNITS

    def cell_box(col: int, row: int, width: int = 1, height: int = 1) -> list[float]:
        return [
            xs[col], ys[row],
            xs[col + width] - 1, ys[row + height] - 1,
        ]

    line_width = max(1, round(unit * 0.09))

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
    # edge to the centre, the middle third of that seat's arm of the track,
    # each outlined so the lane reads as its own bordered strip rather than
    # a shape that bleeds straight into the centre triangle beside it.
    for seat in range(4):
        cols = [c for c, _ in HOME_COLUMNS[seat]]
        rows = [r for _, r in HOME_COLUMNS[seat]]
        lane_box = cell_box(
            min(cols), min(rows),
            max(cols) - min(cols) + 1, max(rows) - min(rows) + 1,
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
    draw.polygon([(cx0, cy0), (cx1, cy0), mid], fill=SEAT_GREEN)   # top: seat 1
    draw.polygon([(cx1, cy0), (cx1, cy1), mid], fill=SEAT_YELLOW)  # right: seat 2
    draw.polygon([(cx1, cy1), (cx0, cy1), mid], fill=SEAT_BLUE)    # bottom: seat 3
    draw.polygon([(cx0, cy1), (cx0, cy0), mid], fill=SEAT_RED)     # left: seat 0
    draw.line([(cx0, cy0), (cx1, cy1)], fill=BOARD_OUTLINE, width=line_width)
    draw.line([(cx1, cy0), (cx0, cy1)], fill=BOARD_OUTLINE, width=line_width)
    draw.rectangle([cx0, cy0, cx1 - 1, cy1 - 1], outline=BOARD_OUTLINE, width=line_width)

    # The eight starred safe squares of the shared track, docs/RULES.md 1.3.
    star_radius = unit * 0.24
    star_width = max(1, round(unit * 0.09))
    for idx in SAFE_TRACK_INDICES:
        col, row = TRACK[idx]
        ccx = xs[col] + (xs[col + 1] - xs[col]) / 2
        ccy = ys[row] + (ys[row + 1] - ys[row]) / 2
        draw.ellipse(
            [ccx - star_radius, ccy - star_radius, ccx + star_radius, ccy + star_radius],
            outline=BOARD_OUTLINE,
            width=star_width,
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
