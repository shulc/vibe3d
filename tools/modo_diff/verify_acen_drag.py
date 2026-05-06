#!/usr/bin/env python3
"""Verify ACEN.<mode> + xfrm.scale drag result against the pivot the mode
should have produced.

Reads /tmp/modo_drag_result.json (or arg 1) which contains a "verts"
list of 8 cube vertices. The mode is read from $MODE env var.

For each mode we know the predicted pivot. Then we check:
  - selected vertices (the top face, y=+0.5) scaled around pivot
  - unselected vertices (bottom face, y=-0.5) untouched

Exits 0 on PASS, 1 on FAIL.
"""
import json
import os
import sys

TOL = 0.005


def at(c, target):
    return abs(c - target) < TOL


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/modo_drag_result.json"
    mode = os.environ.get("MODE", "select")

    with open(path) as f:
        verts = json.load(f)["verts"]

    top = sorted([v for v in verts if v[1] > 0])
    bot = sorted([v for v in verts if v[1] < 0])

    print()
    print("  bottom face (4 verts, expected unchanged at y=-0.5):")
    for v in bot:
        print(f"    {v}")
    print("  top face (4 verts, scaled around pivot):")
    for v in top:
        print(f"    {v}")
    print()

    # Bottom face must be untouched: xfrm.scale + actr.<any> applies the
    # transform only to the *selected* geometry (top face). So all four
    # bottom verts should stay at their original ±0.5 corners.
    bot_unchanged = all(
        at(abs(v[0]), 0.5) and at(v[1], -0.5) and at(abs(v[2]), 0.5)
        for v in bot
    )

    # Predict pivot Y for each mode. Top face vertices have original
    # y=0.5; after scaling around pivot, new_y = (0.5 - pivot.y) * k +
    # pivot.y. We don't know k (depends on drag distance), but we DO
    # know which axis stays unchanged: if pivot.y == 0.5, top.y stays
    # 0.5 regardless of k. If pivot.y != 0.5, top.y will move (unless
    # drag was zero).
    # Predictions calibrated against MODO 9 reference (polygon-component
    # selection, top face of unit cube, drag in viewport):
    #   actr.select / selectauto / border  → selection centroid (0, 0.5, 0)
    #   actr.local                         → ALSO selection centroid
    #     (despite the name; in component mode `local` uses the
    #     selection's local position, not the item's local origin —
    #     verified empirically against MODO 9.0v2)
    #   actr.origin                        → world (0, 0, 0)
    #   actr.auto                          → element-under-cursor
    #     dependent — pivot is computed from where the drag started, NOT
    #     the selection. We can't easily predict the exact pivot without
    #     replicating MODO's element-pick logic. Skip exact y check;
    #     just verify drag was applied and bottom untouched.
    #   actr.element                       → element-under-cursor too;
    #     same skip rationale.
    centroid_y = 0.5
    if mode in ("select", "selectauto", "border", "local"):
        pivot_y = centroid_y
        pivot_desc = "selection centroid (0, 0.5, 0)"
    elif mode == "origin":
        pivot_y = 0.0
        pivot_desc = "world origin (0, 0, 0)"
    elif mode in ("auto", "element"):
        pivot_y = None  # don't check
        pivot_desc = "element-under-cursor (drag-position dependent)"
    else:
        print(f"  SKIP: don't know predicted pivot for actr.{mode}")
        return 0

    if pivot_y is None:
        # element/auto modes — don't check top.y against a specific pivot;
        # just confirm the drag applied something.
        top_y_match = True
        top_y_label = "top.y check skipped (pivot is drag-position dependent)"
    elif pivot_y == centroid_y:
        # top.y should stay at 0.5
        top_y_match = all(at(v[1], 0.5) for v in top)
        top_y_label = "top.y stays at 0.5 (pivot.y == 0.5)"
    else:
        # top.y must have moved away from 0.5
        top_y_match = any(not at(v[1], 0.5) for v in top)
        top_y_label = f"top.y changed away from 0.5 (pivot.y == {pivot_y})"

    drag_applied = any(abs(v[0]) > 0.51 or abs(v[2]) > 0.51
                       or not at(v[1], 0.5)
                       for v in top)

    def row(label, ok):
        mark = "\033[32mOK\033[0m" if ok else "\033[31mFAIL\033[0m"
        print(f"  [{mark}] {label}")

    print(f"  predicted pivot: {pivot_desc}")
    row("bottom face untouched (xfrm.scale operates on selection)", bot_unchanged)
    row(top_y_label, top_y_match)
    row("drag actually applied (top verts moved)", drag_applied)
    print()

    ok = bot_unchanged and top_y_match and drag_applied
    if ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode} pivot matches prediction.")
        return 0
    else:
        print(f"\033[31m  FAIL\033[0m: actr.{mode} pivot does not match prediction.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
