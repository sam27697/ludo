#!/usr/bin/env python3
"""Generates the two Play Store listing images from the board's own palette.

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
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "assets" / "store"

# packages/ludo_client/lib/src/board.dart:181-184, alpha byte dropped (opaque).
SEAT_RED = (0xD3, 0x2F, 0x2F)
SEAT_GREEN = (0x38, 0x8E, 0x3C)
SEAT_YELLOW = (0xFB, 0xC0, 0x2D)
SEAT_BLUE = (0x19, 0x76, 0xD2)

# packages/ludo_client/lib/src/board.dart:200
BOARD_GROUND = (0xF7, 0xF3, 0xE9)

# packages/ludo_client/lib/src/board.dart:270, the board's own outline stroke.
BOARD_OUTLINE = (0x42, 0x42, 0x42)

FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
WORDMARK = "Ludo RNG"

# Corner yards occupy a 6-unit block of a 15-unit board, same as the app's
# own 15x15 grid (packages/ludo_client/lib/src/board.dart: cellSize = width /
# 15, yard blocks are 6x6). The 3-unit gap left in the middle, on all four
# sides, is the cross.
BOARD_UNITS = 15
YARD_SPAN = 6


def _grid(x0: float, y0: float, size: float) -> list[float]:
    """Sixteen pixel boundaries for a 15-unit grid inside a size x size box."""
    unit = size / BOARD_UNITS
    return [x0 + round(unit * i) for i in range(BOARD_UNITS + 1)]


def draw_board(draw: ImageDraw.ImageDraw, x0: float, y0: float, size: float) -> None:
    """Draws the board motif: four coloured corner yards and the cross left
    as the ground colour between them, framed by the board's own outline
    stroke. Caller is responsible for the ground fill under this box.
    """
    xs = _grid(x0, y0, size)
    ys = _grid(y0, y0, size)  # same units, board is square

    corners = [
        (SEAT_RED, 0, 0),  # seat 0, top-left
        (SEAT_GREEN, BOARD_UNITS - YARD_SPAN, 0),  # seat 1, top-right
        (SEAT_YELLOW, BOARD_UNITS - YARD_SPAN, BOARD_UNITS - YARD_SPAN),  # seat 2, bottom-right
        (SEAT_BLUE, 0, BOARD_UNITS - YARD_SPAN),  # seat 3, bottom-left
    ]
    for color, col, row in corners:
        draw.rectangle(
            [xs[col], ys[row], xs[col + YARD_SPAN] - 1, ys[row + YARD_SPAN] - 1],
            fill=color,
        )

    outline_width = max(2, round(size * 0.008))
    draw.rectangle(
        [x0, y0, x0 + size - 1, y0 + size - 1],
        outline=BOARD_OUTLINE,
        width=outline_width,
    )


def make_icon() -> Image.Image:
    size = 512
    im = Image.new("RGB", (size, size), BOARD_GROUND)
    draw = ImageDraw.Draw(im)
    draw_board(draw, 0, 0, size)
    return im


def _fit_font(draw: ImageDraw.ImageDraw, text: str, max_width: int, max_height: int) -> ImageFont.FreeTypeFont:
    """Largest integer point size of FONT_PATH whose rendered bbox for text
    fits inside max_width x max_height.
    """
    lo, hi = 8, 400
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
    im = Image.new("RGB", (width, height), BOARD_GROUND)
    draw = ImageDraw.Draw(im)

    # Safe area: centred ~924x400, so content stays clear of Play's own
    # edge overlays.
    safe_left, safe_top = 50, 50
    safe_right, safe_bottom = width - 50, height - 50

    # Board motif on the left half of the safe area.
    board_size = 380
    board_x0 = safe_left + 22
    board_y0 = (height - board_size) // 2
    draw_board(draw, board_x0, board_y0, board_size)

    # Wordmark on the right half of the safe area, vertically centred.
    text_zone_left = board_x0 + board_size + 40
    text_zone_right = safe_right
    text_max_w = text_zone_right - text_zone_left
    text_max_h = 170

    font = _fit_font(draw, WORDMARK, text_max_w, text_max_h)
    bbox = draw.textbbox((0, 0), WORDMARK, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = text_zone_left + (text_max_w - text_w) // 2 - bbox[0]
    text_y = (height - text_h) // 2 - bbox[1]
    draw.text((text_x, text_y), WORDMARK, font=font, fill=SEAT_BLUE)

    assert safe_top <= board_y0 and board_y0 + board_size <= safe_bottom
    return im


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
