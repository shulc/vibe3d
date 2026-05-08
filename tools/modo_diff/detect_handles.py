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
        [--hint x,y]          # prefer the connected-component blob
                              # closest to (x, y) — used to pick the
                              # actual gizmo center cube over the
                              # tiny "Z" axis-indicator badge in the
                              # viewport corner that uses the same
                              # cyan-ish RGB triplet

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


def detect(arr, core, tol, sat_min, hint=None):
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

    # Connected-component label. Picking the LARGEST blob is wrong
    # when MODO renders the small per-axis indicator widget (the "Z"
    # badge in the corner) in the same RGB family — that text can be
    # bigger than the gizmo center cube and dominate. With a hint
    # (typically the analytical projection of the gizmo's screen
    # position) we instead pick the blob whose centroid is CLOSEST
    # to the hint, breaking ties on size. Without a hint we still
    # fall back to "largest blob" for backward compatibility.
    labels, n = ndi.label(mask, structure=np.ones((3, 3), dtype=int))
    if n == 0:
        return None
    sizes = ndi.sum(mask, labels, index=range(1, n + 1))
    centers = ndi.center_of_mass(mask, labels, range(1, n + 1))
    if hint is None:
        biggest = int(np.argmax(sizes))
        if sizes[biggest] < 5:
            return None
        cy, cx = centers[biggest]
        return (float(cx), float(cy))
    # With a hint we use a much looser size threshold: the gizmo's
    # center cube is anti-aliased into many tiny (2-4 px) blobs so
    # `>= 5` excludes the actual handle. Distance-from-hint then
    # picks the cluster nearest the analytical projection regardless
    # of size; the corner Z-indicator badge — a much larger blob in a
    # very different screen region — gets correctly skipped.
    hx, hy = hint
    best = None
    best_d = float("inf")
    for i in range(n):
        if sizes[i] < 2:
            continue
        cy, cx = centers[i]
        d = (cx - hx) ** 2 + (cy - hy) ** 2
        if d < best_d:
            best_d = d
            best = (float(cx), float(cy))
    return best


def main():
    args = sys.argv[1:]
    region = None
    hint = None
    if "--region" in args:
        idx = args.index("--region")
        region = tuple(int(v) for v in args[idx + 1].split(","))
        del args[idx:idx + 2]
    if "--hint" in args:
        idx = args.index("--hint")
        hint = tuple(float(v) for v in args[idx + 1].split(","))
        del args[idx:idx + 2]
    if len(args) != 2:
        print("usage: detect_handles.py <png> <out_json> "
              "[--region x,y,w,h] [--hint x,y]", file=sys.stderr)
        return 2
    png, out = args

    img = Image.open(png).convert("RGB")
    arr = np.asarray(img)

    if region is not None:
        rx, ry, rw, rh = region
        sub = arr[ry:ry + rh, rx:rx + rw]
        offset = (rx, ry)
    else:
        sub = arr
        offset = (0, 0)

    # Translate the hint into sub-image coordinates if we have one.
    sub_hint = None
    if hint is not None:
        sub_hint = (hint[0] - offset[0], hint[1] - offset[1])

    found = {}
    for name, spec in HANDLES.items():
        r = detect(sub, spec["core"], spec["tol"], spec["sat_min"],
                   sub_hint)
        if r is not None:
            found[name] = [r[0] + offset[0], r[1] + offset[1]]

    Path(out).write_text(json.dumps(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
