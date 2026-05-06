#!/usr/bin/env python3
"""Verify ACEN.<mode> + xfrm.scale drag result against the pivot the
mode should have produced.

Reads /tmp/modo_drag_result.json (verts after drag) and
/tmp/modo_drag_state.json (mode, pattern, verts before). Decomposes the
drag into (scale factor, pivot) per axis, compares against the
predicted pivot for the (mode, pattern) combination.

Exit 0 = PASS, 1 = FAIL.
"""
import json
import os
import sys

# Tolerance for matching a vertex to a pre-drag position, AND for
# matching the recovered pivot to the prediction. MODO's mouse-driven
# evaluate adds a small drag-position-dependent jitter — keep loose.
TOL = 0.05


def at(c, target, tol=TOL):
    return abs(c - target) < tol


def avg(verts):
    n = len(verts)
    return tuple(sum(v[i] for v in verts) / n for i in range(3))


def bbox_center(verts):
    if not verts:
        return (0.0, 0.0, 0.0)
    mn = [min(v[i] for v in verts) for i in range(3)]
    mx = [max(v[i] for v in verts) for i in range(3)]
    return tuple((mn[i] + mx[i]) / 2 for i in range(3))


# Selection patterns mirror modo_drag_setup.py.
PATTERN_POLYS = {
    "single_top": [
        [(-0.5, 0.5, -0.5), (0.5, 0.5, -0.5),
         (0.5, 0.5,  0.5), (-0.5, 0.5,  0.5)],
    ],
    "asymmetric": [
        [(-0.5, 0.5, -0.5), (0.0, 0.5, -0.5),
         (0.0, 0.5,  0.0), (-0.5, 0.5,  0.0)],
        [(-0.5, 0.5,  0.0), (0.0, 0.5,  0.0),
         (0.0, 0.5,  0.5), (-0.5, 0.5,  0.5)],
        [(0.0, -0.5,  0.0), (0.5, -0.5,  0.0),
         (0.5, -0.5,  0.5), (0.0, -0.5,  0.5)],
    ],
}


def selected_unique_verts(pattern):
    seen = set()
    out  = []
    for poly in PATTERN_POLYS[pattern]:
        for v in poly:
            t = tuple(v)
            if t not in seen:
                seen.add(t)
                out.append(t)
    return out


def selected_clusters(pattern):
    polys = [list(map(tuple, p)) for p in PATTERN_POLYS[pattern]]
    n     = len(polys)
    poly_verts = [set(p) for p in polys]
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            if poly_verts[i] & poly_verts[j]:
                a, b = find(i), find(j)
                if a != b: parent[a] = b

    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)

    clusters = []
    for members in groups.values():
        verts = set()
        for k in members:
            verts.update(polys[k])
        clusters.append(sorted(verts))
    return clusters


def predict_pivot(mode, pattern):
    """Return predicted pivot, or list of acceptable pivots, or None
    (drag-position-dependent, skip exact check)."""
    sel = selected_unique_verts(pattern)
    clusters = selected_clusters(pattern)

    if mode in ("select", "selectauto", "border"):
        # MODO 9 empirically uses BBOX CENTER for all three of these
        # in component selection mode — see doc/acen_modo_parity_plan.md
        # Phase 2. Docs claim "average vertex position" for select but
        # the artifact disagrees; we follow the artifact.
        return [bbox_center(sel)]
    if mode == "local":
        # Combined OR per-cluster centroid is acceptable. vibe3d's
        # current implementation publishes only the first cluster's
        # centroid; MODO's drag may use the combined centroid.
        return [avg(c) for c in clusters] + [avg(sel)]
    if mode == "origin":
        return [(0.0, 0.0, 0.0)]
    if mode == "auto":
        return None
    return None


def decompose(top_old, top_new):
    """Recover (k, P) from old/new vertex bounds assuming uniform
    scale by k around pivot P (per-axis)."""
    k = 1.0
    for ax in range(3):
        old_min = min(v[ax] for v in top_old)
        old_max = max(v[ax] for v in top_old)
        new_min = min(v[ax] for v in top_new)
        new_max = max(v[ax] for v in top_new)
        if abs(old_max - old_min) > 1e-6:
            k = (new_max - new_min) / (old_max - old_min)
            break

    P = []
    for ax in range(3):
        mid_old = (min(v[ax] for v in top_old)
                   + max(v[ax] for v in top_old)) / 2
        mid_new = (min(v[ax] for v in top_new)
                   + max(v[ax] for v in top_new)) / 2
        P.append(mid_old if abs(1 - k) < 1e-6
                 else (mid_new - mid_old * k) / (1 - k))
    return k, tuple(P)


def split_moved_unmoved(verts_before, verts_after, sel_set):
    """Pair pre/post drag verts. Untouched (= not in selection) verts
    should appear unchanged in verts_after; selected verts move."""
    untouched_pre = [tuple(v) for v in verts_before
                     if (round(v[0], 4), round(v[1], 4),
                         round(v[2], 4)) not in sel_set]

    moved_after = []
    untouched_remaining = list(untouched_pre)
    untouched_after_count = 0
    for a in verts_after:
        idx = None
        for j, u in enumerate(untouched_remaining):
            if all(at(a[i], u[i]) for i in range(3)):
                idx = j; break
        if idx is not None:
            untouched_remaining.pop(idx)
            untouched_after_count += 1
        else:
            moved_after.append(a)

    untouched_ok = (untouched_after_count == len(untouched_pre))
    return untouched_ok, untouched_pre, moved_after


def main():
    result_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/modo_drag_result.json"
    state_path  = "/tmp/modo_drag_state.json"

    with open(result_path) as f:
        verts_after = json.load(f)["verts"]
    with open(state_path) as f:
        state = json.load(f)

    mode    = os.environ.get("MODE", state.get("acen_mode", "select"))
    pattern = state.get("pattern", "single_top")
    verts_before = state.get("before", [])

    sel = selected_unique_verts(pattern)
    sel_set = {(round(v[0], 4), round(v[1], 4), round(v[2], 4)) for v in sel}

    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)

    print(f"mode: {mode}   pattern: {pattern}")
    print(f"  selection: {len(sel)} unique verts in "
          f"{len(PATTERN_POLYS[pattern])} polygons, "
          f"{len(selected_clusters(pattern))} cluster(s)")
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")
    print(f"  moved verts after drag:    {len(moved_after)} / {len(sel)} expected")

    if not moved_after:
        print("\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    if len(moved_after) != len(sel):
        print(f"  (warning: moved count != selection count — verts may "
              f"have collapsed onto each other)")

    k, P = decompose(sel, moved_after)
    print(f"  observed: k = {k:+.4f}, "
          f"P = ({P[0]:+.4f}, {P[1]:+.4f}, {P[2]:+.4f})")

    pred = predict_pivot(mode, pattern)
    if pred is None:
        print(f"  predicted pivot: drag-position-dependent (skip exact)")
        ok = untouched_ok
    else:
        labels = ", ".join(
            f"({p[0]:+.4f}, {p[1]:+.4f}, {p[2]:+.4f})" for p in pred)
        print(f"  predicted pivot: {labels}")
        match = any(all(at(P[i], p[i]) for i in range(3)) for p in pred)
        ok = untouched_ok and match

    print()
    if ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode}/{pattern} pivot matches prediction.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode}/{pattern} pivot does NOT match.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
