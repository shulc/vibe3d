#!/usr/bin/env python3
"""Validate scene pixels inside the reported canvas viewport, excluding chrome."""
from PIL import Image, ImageStat
import sys

image = Image.open(sys.argv[1]).convert("RGB")
x, y, width, height = map(int, sys.argv[2].split(","))
if width < 200 or height < 150 or x < 0 or y < 0:
    raise SystemExit(f"WEB-PIXELS invalid viewport={x},{y},{width},{height}")
right, bottom = x + width, y + height
if right > image.width or bottom > image.height:
    raise SystemExit(f"WEB-PIXELS viewport outside canvas: {right}x{bottom} > {image.size}")

scene = image.crop((x, y, right, bottom))
pixels = list(scene.getdata())
colors = len(set(pixels))
spread = sum(ImageStat.Stat(scene).stddev)
# Baseline profile (1280x720 Chromium/SwiftShader): the real scene is hundreds
# of colours with strong channel variation. Floors intentionally retain >4x
# headroom while rejecting a fully erased/flat viewport (1 colour, spread 0).
if colors < 96 or spread < 18.0:
    raise SystemExit(
        f"WEB-PIXELS scene oracle failed colors={colors} spread={spread:.2f} "
        f"viewport={x},{y},{width},{height}")
print(f"WEB-PIXELS sceneColors={colors} spread={spread:.2f} "
      f"viewport={x},{y},{width},{height}")
