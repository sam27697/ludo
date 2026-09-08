"""Android launcher icon generator, built on top of tool/store_graphics.py.

Why this exists: the app ships the stock Flutter template launcher icon.
tool/store_graphics.py already draws the mark the app should use instead --
a white die on a purple vertical gradient -- for the Play Store listing. This
script reuses that exact drawing code (draw_die, vertical_gradient) so the
launcher icon and the store icon are guaranteed to be the same mark, rather
than two PNGs somebody has to keep looking alike by eye.

It writes two kinds of resource:

- An adaptive icon (mipmap-anydpi-v26/ic_launcher.xml plus a background and
  foreground PNG per density) for API 26 and up. Android composes the two
  layers at 108dp square and only guarantees the centre 66dp is visible, so
  the foreground die is drawn well inside that 66dp safe zone rather than
  filling the layer.
- Legacy full-bleed raster icons at the five existing mipmap-<density>
  densities, for API 24 and 25, which do not support adaptive icons and are
  not masked.

Run with no arguments from anywhere; it locates the repository root from its
own file path, not from the current working directory:

    /usr/bin/python3 tool/launcher_icons.py

Running it twice writes the same bytes both times.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

sys.path.insert(0, HERE)
from store_graphics import S, DIE_EDGE, draw_die, vertical_gradient  # noqa: E402

from PIL import Image

RES_DIR = os.path.join(
    REPO_ROOT, "packages", "ludo_client", "android", "app", "src", "main", "res"
)

# API 24/25 fallback: full-bleed raster icon at each existing mipmap density,
# same composition as store_graphics.make_icon() -- gradient ground plus die
# -- generated at each density's own size rather than downscaled once from a
# single large image, so small sizes anti-alias instead of stair-stepping.
LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# API 26+ adaptive icon layers, 108dp square at each density's scale factor
# (mdpi 1x, hdpi 1.5x, xhdpi 2x, xxhdpi 3x, xxxhdpi 4x).
ADAPTIVE_SIZES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

# Fraction of the adaptive layer's edge length passed as draw_die()'s `size`
# argument for the foreground. Only the centre 66dp of a 108dp layer is
# guaranteed visible (61 percent of the layer width), and launchers also
# parallax the two layers against each other, so the die's rotated bounding
# box is kept well inside that limit rather than against it. Measured at
# xxxhdpi (432px): this fraction puts the bounding box at 49.5 percent of the
# layer width, against a 61.1 percent limit -- see the acceptance check.
FOREGROUND_DIE_FRACTION = 0.45

# Same die-to-canvas ratio store_graphics.make_icon() uses for the full-bleed
# store icon; the legacy launcher icon is the same full-bleed composition so
# it reuses the same ratio.
LEGACY_DIE_FRACTION = 0.62


def _mipmap_dir(density):
    d = os.path.join(RES_DIR, f"mipmap-{density}")
    os.makedirs(d, exist_ok=True)
    return d


def make_legacy_icon(density, out):
    w = h = out * S
    img = vertical_gradient(w, h)
    draw_die(img, w // 2, h // 2, int(w * LEGACY_DIE_FRACTION))
    path = os.path.join(_mipmap_dir(density), "ic_launcher.png")
    img.resize((out, out), Image.LANCZOS).save(path)
    return path


def make_background(density, out):
    # A plain vertical gradient is already smooth at any size -- each row is
    # a single flat colour -- so it is generated directly at the target size
    # rather than supersampled.
    img = vertical_gradient(out, out)
    path = os.path.join(_mipmap_dir(density), "ic_launcher_background.png")
    img.save(path)
    return path


def make_foreground(density, out):
    w = h = out * S
    # The base canvas is filled with the die's own edge colour at zero alpha,
    # not black at zero alpha. draw_die's outermost antialiased edge is a
    # blend between that edge colour (opaque) and whatever the canvas holds
    # underneath it (transparent); matching the colour means the Lanczos
    # downsample below blends colour-with-itself at that boundary and only
    # the alpha ramps, so the transparent edge does not pick up a dark fringe
    # the way it would against a plain (0, 0, 0, 0) canvas.
    base = Image.new("RGBA", (w, h), DIE_EDGE + (0,))
    draw_die(base, w // 2, h // 2, int(w * FOREGROUND_DIE_FRACTION))
    path = os.path.join(_mipmap_dir(density), "ic_launcher_foreground.png")
    base.resize((out, out), Image.LANCZOS).save(path)
    return path


ADAPTIVE_ICON_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""


def make_adaptive_icon_xml():
    d = os.path.join(RES_DIR, "mipmap-anydpi-v26")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "ic_launcher.xml")
    with open(path, "w") as f:
        f.write(ADAPTIVE_ICON_XML)
    return path


def main():
    written = []
    for density, out in LEGACY_SIZES.items():
        written.append(make_legacy_icon(density, out))
    for density, out in ADAPTIVE_SIZES.items():
        written.append(make_background(density, out))
        written.append(make_foreground(density, out))
    written.append(make_adaptive_icon_xml())
    for path in written:
        print(path)


if __name__ == "__main__":
    main()
