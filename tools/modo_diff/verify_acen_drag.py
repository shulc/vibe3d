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


def verify_local(pattern, verts_before, verts_after, sel_set):
    """Local mode does per-cluster transforms — each cluster scales
    around its OWN centroid. Verify per-cluster: the bbox center of
    each cluster's verts must equal the cluster's centroid both before
    and after the drag (uniform scale is centroid-invariant)."""
    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)

    print(f"  untouched verts preserved: {untouched_ok}")
    print(f"  moved verts after drag:    {len(moved_after)}")
    if not moved_after:
        print("\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    # For each cluster compute its expected centroid from PATTERN_POLYS.
    clusters_pre = selected_clusters(pattern)
    cluster_centroids = [bbox_center(c) for c in clusters_pre]
    print(f"  expected per-cluster centroids:")
    for c in cluster_centroids:
        print(f"    ({c[0]:+.4f}, {c[1]:+.4f}, {c[2]:+.4f})")

    # Pair moved verts back to clusters by membership of pre-drag verts.
    pre_set_per_cluster = [
        {tuple(v) for v in c} for c in clusters_pre
    ]

    # Heuristic: a moved post-drag vertex `a` belongs to cluster c iff
    # the closest pre-drag vert belongs to c. For uniform scale around
    # the cluster centroid, post-drag positions interpolate between
    # pre-drag and centroid (factor k can be > 1 for outward), so the
    # pre-drag position of each moved vert is uniquely identifiable as
    # the one that gives a consistent k for the whole cluster.
    # Simpler approach: for each pre-drag vert, find the post-drag vert
    # that lies on the line from cluster centroid through pre-drag vert.
    matches = []  # list of (pre, post, cluster_idx)
    for ci, cluster in enumerate(clusters_pre):
        cen = cluster_centroids[ci]
        for pre in cluster:
            best = None
            best_err = float("inf")
            for post in moved_after:
                # Skip ones already matched.
                if any(post is m[1] for m in matches):
                    continue
                # Vector from centroid to pre and post should be
                # collinear (same direction). Compute via cross product.
                vp = tuple(pre[i] - cen[i] for i in range(3))
                vq = tuple(post[i] - cen[i] for i in range(3))
                # Collinearity: |vp x vq| ≈ 0 (need parallel).
                cx = vp[1]*vq[2] - vp[2]*vq[1]
                cy = vp[2]*vq[0] - vp[0]*vq[2]
                cz = vp[0]*vq[1] - vp[1]*vq[0]
                err = (cx*cx + cy*cy + cz*cz) ** 0.5
                if err < best_err:
                    best = post
                    best_err = err
            if best is not None and best_err < 0.05:
                matches.append((pre, best, ci))

    # For each cluster, verify recovered scale factor is consistent and
    # bbox center stays at the cluster centroid.
    per_cluster_ok = True
    for ci, cluster in enumerate(clusters_pre):
        cluster_post = [m[1] for m in matches if m[2] == ci]
        if len(cluster_post) != len(cluster):
            print(f"  cluster {ci}: matched {len(cluster_post)}/{len(cluster)} verts — FAIL")
            per_cluster_ok = False
            continue
        post_center = bbox_center(cluster_post)
        cen = cluster_centroids[ci]
        ok = all(at(post_center[i], cen[i]) for i in range(3))
        mark = "OK" if ok else "FAIL"
        print(f"  cluster {ci}: bbox-center after = "
              f"({post_center[0]:+.4f}, {post_center[1]:+.4f}, {post_center[2]:+.4f})  [{mark}]")
        per_cluster_ok = per_cluster_ok and ok

    if untouched_ok and per_cluster_ok:
        print(f"\033[32m  PASS\033[0m: per-cluster pivots verified.")
        return 0
    print(f"\033[31m  FAIL\033[0m: per-cluster pivots not preserved.")
    return 1


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

    print(f"mode: {mode}   pattern: {pattern}")
    print(f"  selection: {len(sel)} unique verts in "
          f"{len(PATTERN_POLYS[pattern])} polygons, "
          f"{len(selected_clusters(pattern))} cluster(s)")

    # Local mode is special — per-cluster transforms can't be decomposed
    # into a single (k, P), so use a dedicated verifier.
    if mode == "local" and len(selected_clusters(pattern)) >= 2:
        return verify_local(pattern, verts_before, verts_after, sel_set)

    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)

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
