#!/usr/bin/env python3
"""Builds the two icons the app ships from the one drawing it has.

    scripts/make-icons.py

Reads Resources/parrot.svg and writes:

    Resources/AppIcon.icns        the colour bird on a dark tile
    Resources/MenuBarParrot.png   the same bird as a flat silhouette, @1x/@2x/@3x

Both outputs are committed. This runs when the drawing changes, not on every
build, so nothing here can stop the app from compiling.

One source rather than three: the tile and the silhouette are the same five
paths. Maintained separately, they drift — and the drift shows up as a bird
whose wing is one shape in the Dock and another in the menu bar.

Rasterising is done by scripts/rasterize.swift, which draws the SVG through
AppKit onto a background of nothing. No Homebrew: everything here ships with
macOS.
"""

from __future__ import annotations

import math
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "parrot.svg"
RASTERIZE = ROOT / "scripts" / "rasterize.swift"
ICNS = ROOT / "Resources" / "AppIcon.icns"
# Three birds for the menu bar, because a status button cannot be tinted.
#
# `contentTintColor` looks like the way to colour a menu bar glyph and is not:
# set it on an NSStatusBarButton and AppKit stops applying the template
# treatment altogether and draws the image's own pixels, which for a template is
# solid black. Measured, not assumed — see the captures in scripts/make-icons
# history. So each colour the menu bar needs is baked into its own file.
#
# The "Template" suffix on the first is what tells AppKit to throw the black
# away and paint the menu bar's own colour through the alpha. The other two are
# ordinary images that keep the colour they were drawn in, which is the only
# mechanism that gets colour up there at all.
MENU_BAR_VARIANTS = {
    "MenuBarParrotTemplate": "#000000",  # idle, released build — follows the bar
    "MenuBarParrotDev": "#0099FF",  # idle, dev build — Parrot.sky
    # Microphone open. Two thirds of the way from Parrot.scarlet to Parrot.amber
    # — a point on the plumage wheel rather than a fifth colour.
    #
    # Not scarlet itself, which is what this was first: the menu bar washes and
    # lifts whatever it is given, and scarlet came out of it at 7° of hue, which
    # is a red. This lands at 32°, which is the orange it was meant to be.
    "MenuBarParrotRecording": "#FF8F0C",
}

# The tile. Dark because every surface this app puts on screen is dark glass —
# an icon lit the other way is the same app introducing itself twice.
TILE_TOP = "#262B34"
TILE_BOTTOM = "#101218"

# Apple's icon grid: a 1024 canvas with the tile inset to 824, leaving the
# margin the system's shadow and the neighbouring icons expect.
CANVAS = 1024
TILE = 824

# How much of the tile's height the bird stands in. Higher and the feet crowd
# the corner radius; lower and it reads as a sticker on a large black square.
BIRD_ON_TILE = 0.72

# The menu bar draws into an 18pt square. The bird takes most of that height and
# the rest is the breathing room every other glyph up there has.
MENU_BAR_POINTS = 18
MENU_BAR_SCALES = (1, 2, 3)
BIRD_IN_MENU_BAR = 0.88

# What an .icns has to contain. macOS picks by size, and a missing rung is a
# blurry icon in whichever view happens to ask for it.
ICONSET = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def read_source() -> tuple[str, tuple[float, float, float, float], list[str]]:
    """The source's inner markup, its viewBox, and its path data on its own."""
    svg = SOURCE.read_text()

    view_box = re.search(r'viewBox="([^"]+)"', svg)
    if not view_box:
        sys.exit(f"error: {SOURCE} has no viewBox")
    box = tuple(float(number) for number in view_box.group(1).split())
    if len(box) != 4:
        sys.exit(f"error: {SOURCE} has a malformed viewBox")

    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S)
    if not inner:
        sys.exit(f"error: {SOURCE} is not a single <svg> element")

    paths = re.findall(r'\sd="([^"]+)"', svg)
    if not paths:
        sys.exit(f"error: {SOURCE} has no paths")

    return inner.group(1), box, paths  # type: ignore[return-value]


def render(svg: Path, sizes: dict[int, Path]) -> None:
    """Rasterise one drawing to several square PNGs, transparent behind.

    Every size in one call: the cost here is starting Swift, not drawing, and
    ten separate invocations spend ten times that for nothing.
    """
    result = subprocess.run(
        ["swift", str(RASTERIZE), str(svg)]
        + [f"{size}:{out}" for size, out in sorted(sizes.items())],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"error: rasterising {svg.name} failed\n{result.stderr.strip()}")


# MARK: The tile


def squircle(centre: float, half: float, exponent: float = 5.0, steps: int = 720) -> str:
    """macOS's rounded square, which is a superellipse and not a rounded rect.

    Drawn as a dense polygon rather than four bezier corners: at 1024px the
    segments are a third of a pixel, and the curve is the real
    |x|^n + |y|^n = 1 rather than an approximation of it.
    """
    points = []
    for step in range(steps):
        angle = 2 * math.pi * step / steps
        cos, sin = math.cos(angle), math.sin(angle)
        points.append(
            (
                centre + math.copysign(abs(cos) ** (2 / exponent), cos) * half,
                centre + math.copysign(abs(sin) ** (2 / exponent), sin) * half,
            )
        )
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in points) + " Z"


def build_icns(inner: str, box: tuple[float, float, float, float]) -> None:
    box_x, box_y, box_width, box_height = box

    height = TILE * BIRD_ON_TILE
    scale = height / box_height
    width = box_width * scale
    offset_x = (CANVAS - width) / 2 - box_x * scale
    offset_y = (CANVAS - height) / 2 - box_y * scale

    tile = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" \
width="{CANVAS}" height="{CANVAS}">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{TILE_TOP}"/>
      <stop offset="1" stop-color="{TILE_BOTTOM}"/>
    </linearGradient>
  </defs>
  <path fill="url(#tile)" d="{squircle(CANVAS / 2, TILE / 2)}"/>
  <g transform="translate({offset_x:.2f} {offset_y:.2f}) scale({scale:.4f})">
{inner}
  </g>
</svg>
"""

    with tempfile.TemporaryDirectory() as scratch:
        scratch_dir = Path(scratch)
        source = scratch_dir / "AppIcon.svg"
        source.write_text(tile)

        iconset = scratch_dir / "AppIcon.iconset"
        iconset.mkdir()

        # Each distinct size drawn once from the vector, then hard-linked to
        # every name that wants it — icon_32x32.png and icon_16x16@2x.png are
        # the same 32 pixels under two names, and rendering twice would only
        # risk them differing.
        render(source, {size: scratch_dir / f"{size}.png" for _, size in ICONSET})
        for name, size in ICONSET:
            shutil.copyfile(scratch_dir / f"{size}.png", iconset / name)

        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)],
            check=True,
            capture_output=True,
        )


# MARK: The silhouette


def menu_bar_path(name: str, scale: int) -> Path:
    suffix = "" if scale == 1 else f"@{scale}x"
    return ROOT / "Resources" / f"{name}{suffix}.png"


def build_menu_bar(paths: list[str], box: tuple[float, float, float, float]) -> None:
    """The same paths as a flat silhouette, once per colour the menu bar needs.

    Square because the menu bar hands out a square and centres whatever it is
    given; a drawing the shape of the bird would be centred by the system
    anyway, and then the padding would be the system's guess rather than ours.

    The shape lives in the alpha either way. For the template that is all AppKit
    reads; for the two coloured ones the fill is what you see.
    """
    box_x, box_y, box_width, box_height = box

    side = box_height / BIRD_IN_MENU_BAR
    origin_x = box_x + box_width / 2 - side / 2
    origin_y = box_y + box_height / 2 - side / 2

    drawing = "\n".join(f'  <path d="{path}"/>' for path in paths)

    with tempfile.TemporaryDirectory() as scratch:
        for name, fill in MENU_BAR_VARIANTS.items():
            source = Path(scratch) / f"{name}.svg"
            source.write_text(
                f"""<svg xmlns="http://www.w3.org/2000/svg" \
viewBox="{origin_x:.4f} {origin_y:.4f} {side:.4f} {side:.4f}">
 <g fill="{fill}">
{drawing}
 </g>
</svg>
"""
            )
            render(
                source,
                {MENU_BAR_POINTS * scale: menu_bar_path(name, scale) for scale in MENU_BAR_SCALES},
            )


def main() -> None:
    inner, box, paths = read_source()
    build_icns(inner, box)
    build_menu_bar(paths, box)
    print(f"==> {ICNS.relative_to(ROOT)}")
    for name in MENU_BAR_VARIANTS:
        for scale in MENU_BAR_SCALES:
            print(f"==> {menu_bar_path(name, scale).relative_to(ROOT)}")


if __name__ == "__main__":
    main()
