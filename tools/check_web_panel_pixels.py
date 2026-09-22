#!/usr/bin/env python3
"""Require non-flat rendered pixels in the production panel button crop."""
import sys
from PIL import Image

if len(sys.argv) != 3:
    raise SystemExit("usage: check_web_panel_pixels.py PNG x0,y0,x1,y1")

image = Image.open(sys.argv[1]).convert("RGB")
x0, y0, x1, y1 = map(int, sys.argv[2].split(","))
if not (0 <= x0 < x1 <= image.width and 0 <= y0 < y1 <= image.height):
    raise SystemExit(f"panel crop outside screenshot: {(x0, y0, x1, y1)} vs {image.size}")

crop = image.crop((x0, y0, x1, y1))
colors = crop.getcolors(maxcolors=crop.width * crop.height)
if colors is None or len(colors) < 6:
    raise SystemExit(f"panel crop lacks visible content: distinct={None if colors is None else len(colors)}")

dark = sum(n for n, rgb in colors if max(rgb) < 90)
light = sum(n for n, rgb in colors if min(rgb) > 120)
if dark == 0 or light == 0:
    raise SystemExit(f"panel crop lacks chrome/text contrast: dark={dark} light={light}")
print(f"WEB-PANEL-PIXELS crop={x0},{y0},{x1},{y1} distinct={len(colors)} dark={dark} light={light}")
