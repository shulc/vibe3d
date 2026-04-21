#!/usr/bin/env python3
"""
Transforms mouse coordinates in selection event logs after the layout change
that added a tab panel (statusH=38px) above the viewport.

Old viewport: vpX=150, vpY=0,  vpW=650, vpH=562  (800x600 - status bar)
New viewport: vpX=150, vpY=38, vpW=650, vpH=524  (800x600 - tab + status)

Y transform: new_y = round(old_y * (524/562) + 38)
X transform: new_x = round((old_x - 475) * (524/562) + 475)
  where 475 = vpX + vpW/2 = 150 + 325 (viewport center X)
  X changes because the perspective matrix aspect ratio changed (650/562 → 650/524),
  which compresses projected geometry toward the horizontal center.

Camera event logs are NOT transformed — orbit/pan/zoom compute movement from
dx/dy between consecutive positions, which are unchanged. Only test_camera.d
needs its expected height updated: 562 → 524.
"""

import json
import sys
import os

VPH_OLD = 562.0
VPH_NEW = 524.0
VPY_NEW = 38
VP_CENTER_X = 475  # vpX + vpW/2 = 150 + 325
SCALE = VPH_NEW / VPH_OLD

SELECTION_LOGS = [
    "tests/events/edge_bevel.log",
    "tests/events/select_between_polygons.log",
    "tests/events/selection_add.log",
    "tests/events/selection_deselect.log",
    "tests/events/selection_edges_add.log",
    "tests/events/selection_edges_deselect.log",
    "tests/events/selection_edges.log",
    "tests/events/selection_edges_remove.log",
    "tests/events/selection_points.log",
    "tests/events/selection_polygons_add.log",
    "tests/events/selection_polygons_deselect.log",
    "tests/events/selection_polygons.log",
    "tests/events/selection_polygons_remove.log",
    "tests/events/selection_remove.log",
]

MOUSE_TYPES = {"SDL_MOUSEMOTION", "SDL_MOUSEBUTTONDOWN", "SDL_MOUSEBUTTONUP"}


def transform_x(x):
    return round((x - VP_CENTER_X) * SCALE + VP_CENTER_X)


def transform_y(y):
    return round(y * SCALE + VPY_NEW)


def fix_log(path):
    if not os.path.exists(path):
        print(f"  SKIP (not found): {path}")
        return

    lines = open(path).readlines()
    out = []
    changed = 0

    for line in lines:
        ev = json.loads(line)
        if ev.get("type") in MOUSE_TYPES:
            ev["x"] = transform_x(ev["x"])
            ev["y"] = transform_y(ev["y"])
            changed += 1
        out.append(json.dumps(ev, separators=(",", ":")) + "\n")

    open(path, "w").writelines(out)
    print(f"  {path}: {changed} events updated")


if __name__ == "__main__":
    print(f"Scale factor: {SCALE:.6f} ({VPH_NEW}/{VPH_OLD})")
    print(f"Y offset: +{VPY_NEW}px")
    print()

    print("Transforming selection event logs...")
    for path in SELECTION_LOGS:
        fix_log(path)

    print()
    print("Camera event logs left unchanged (orbit/pan/zoom use dx/dy, not absolute coords).")
    print()
    print("ACTION REQUIRED: update tests/test_camera.d — change expected height 562 → 524 in all assertCameraState calls.")
