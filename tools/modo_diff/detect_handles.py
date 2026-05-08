#!/usr/bin/env python3
"""Detect MODO move-tool gizmo handle pixel positions on a screenshot.

The analytical world→screen path in run_acen_drag.py uses the camera
basis + PixelSize, but MODO's gizmo handle screen positions don't
exactly match that projection (gizmo is anchored at the ACEN center,
not the selection bbox we use as a proxy; the cube/arrow geometry
also has its own rendering offsets). Instead, take a screenshot of
the MODO viewport AFTER the tool is active and locate each handle by
its distinctive saturated colour:

    X arrow → red    (high R, low G+B)
    Y arrow → green  (high G, low R+B)
    Z arrow → blue   (high B, low R+G)
    center cube → cyan (high G+B, low R)

The "tip" of each axis arrow is identified by the matching pixel
farthest from the cluster centroid in the projected screen direction
(or just the centroid for the cube). Picking a click point inside
the arrow shaft is enough for hit-testing.

Usage (called by run_acen_drag.Worker as a subprocess):
    python3 detect_handles.py <png_path> <out_json> \
        [--region x,y,w,h]    # restrict search to a sub-rect (viewport)

Output JSON shape:
    {
        "x":      [px, py],   # red arrow centroid
        "y":      [px, py],   # green
        "z":      [px, py],   # blue
        "center": [px, py]    # cyan cube
    }
Any handle that couldn't be confidently located is omitted from the
output (caller falls back to analytical projection).
"""
import json
import sys
from pathlib import Path

import numpy as np
import scipy.ndimage as ndi
from PIL import Image


# Saturated-colour matchers. `core` is the canonical RGB; tolerance is
# component-wise. The saturation filter (max-min > sat_min) excludes
# desaturated pixels — empirically MODO's gradient sky has cyan-ish
# greys around RGB(109, 172, 196) (sat ≈ 87) that need to be excluded
# without false-positive on the (much more saturated) handle pixels.
HANDLES = {
    "x":      {"core": (215,  60,  60), "tol": 50, "sat_min": 130},
    "y":      {"core": ( 60, 215,  60), "tol": 50, "sat_min": 130},
    "z":      {"core": ( 60,  80, 230), "tol": 50, "sat_min": 130},
    "center": {"core": ( 80, 230, 230), "tol": 40, "sat_min": 130},
}


def detect(arr, core, tol, sat_min):
    r, g, b = core
    rch = arr[:, :, 0].astype(int)
    gch = arr[:, :, 1].astype(int)
    bch = arr[:, :, 2].astype(int)
    mx = np.maximum(np.maximum(rch, gch), bch)
    mn = np.minimum(np.minimum(rch, gch), bch)

    mask = (
        (np.abs(rch - r) < tol) &
        (np.abs(gch - g) < tol) &
        (np.abs(bch - b) < tol) &
        ((mx - mn) > sat_min)
    )
    if not mask.any():
        return None

    # Connected-component label so we can isolate the LARGEST blob of
    # matching colour — MODO renders a small per-axis indicator widget
    # in the viewport corner that uses the same RGB triplet as the
    # main gizmo handles, and the centroid of all matching pixels
    # would split the difference between the two and miss both. The
    # largest connected component is reliably the gizmo handle.
    labels, n = ndi.label(mask, structure=np.ones((3, 3), dtype=int))
    if n == 0:
        return None
    sizes = ndi.sum(mask, labels, index=range(1, n + 1))
    biggest = int(np.argmax(sizes)) + 1
    if sizes[biggest - 1] < 5:
        return None
    cy, cx = ndi.center_of_mass(mask, labels, biggest)
    return (float(cx), float(cy))


def main():
    args = sys.argv[1:]
    region = None
    if "--region" in args:
        idx = args.index("--region")
        region = tuple(int(v) for v in args[idx + 1].split(","))
        del args[idx:idx + 2]
    if len(args) != 2:
        print("usage: detect_handles.py <png> <out_json> "
              "[--region x,y,w,h]", file=sys.stderr)
        return 2
    png, out = args

    img = Image.open(png).convert("RGB")
    arr = np.asarray(img)

    # Restrict search to the viewport — menu chrome + icons in MODO's
    # surrounding panels often have saturated colours that fool the
    # detector when run on the full screenshot.
    if region is not None:
        rx, ry, rw, rh = region
        sub = arr[ry:ry + rh, rx:rx + rw]
        offset = (rx, ry)
    else:
        sub = arr
        offset = (0, 0)

    found = {}
    for name, spec in HANDLES.items():
        r = detect(sub, spec["core"], spec["tol"], spec["sat_min"])
        if r is not None:
            found[name] = [r[0] + offset[0], r[1] + offset[1]]

    Path(out).write_text(json.dumps(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
