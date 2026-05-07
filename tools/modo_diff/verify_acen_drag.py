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


def verify_move(mode, pattern, verts_before, verts_after, sel_set):
    """xfrm.move translates selected verts by a single delta vector.
    The ACEN pivot does NOT affect the resulting geometry (translate is
    pivot-invariant); it only changes where the gizmo is drawn. So the
    pass criteria are weaker than for Scale.

    For ACEN.Local with multiple clusters, each cluster's AXIS may
    differ (axis.local), so per-cluster deltas can differ. Within one
    cluster all verts share a delta — pure translation preserves the
    cluster's bbox dimensions and shifts its centre by exactly delta.

    We pair clusters via bbox shape: the SET of post-drag verts that
    forms a bbox with the same dimensions as the cluster's pre-drag
    bbox is the cluster, and its centroid shift is the delta.
    """
    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")
    print(f"  moved verts after drag:    {len(moved_after)}")
    if not moved_after:
        print("\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    clusters_pre = selected_clusters(pattern)

    # For each cluster find the n-subset of `moved_after` whose bbox
    # dimensions match the cluster's pre-drag bbox. Pure translate
    # preserves bbox dims exactly. Combinatorial search is cheap for our
    # cluster sizes (n ≤ 10).
    from itertools import combinations

    def bbox_dims(pts):
        mn = [min(p[i] for p in pts) for i in range(3)]
        mx = [max(p[i] for p in pts) for i in range(3)]
        return [mx[i] - mn[i] for i in range(3)], \
               [(mn[i] + mx[i]) / 2 for i in range(3)]

    used_indices = set()
    deltas_per_cluster = []
    for ci, cluster in enumerate(clusters_pre):
        n = len(cluster)
        dim0, cen0 = bbox_dims(cluster)
        avail = [j for j in range(len(moved_after)) if j not in used_indices]

        best_subset = None
        best_err = float("inf")
        for combo in combinations(avail, n):
            pts = [moved_after[j] for j in combo]
            dim1, cen1 = bbox_dims(pts)
            err = sum((dim1[i] - dim0[i]) ** 2 for i in range(3))
            if err < best_err:
                best_err = err
                best_subset = combo

        if best_subset is None:
            print(f"  cluster {ci}: no candidate subset")
            deltas_per_cluster.append((False, (0, 0, 0)))
            continue

        used_indices.update(best_subset)
        pts = [moved_after[j] for j in best_subset]
        dim1, cen1 = bbox_dims(pts)
        dim_match = all(at(dim0[i], dim1[i]) for i in range(3))
        delta = tuple(cen1[i] - cen0[i] for i in range(3))
        mark = "OK" if dim_match else "FAIL (dim mismatch)"
        print(f"  cluster {ci}: delta ≈ "
              f"({delta[0]:+.4f}, {delta[1]:+.4f}, {delta[2]:+.4f})  "
              f"[shape {mark}]")
        if not dim_match:
            print(f"    pre  dims:  {dim0}")
            print(f"    post dims:  {dim1}")
        deltas_per_cluster.append((dim_match, delta))

    all_ok = untouched_ok and all(m for m, _ in deltas_per_cluster)
    if all_ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode}/{pattern} (move) "
              f"each cluster translated rigidly.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode}/{pattern} (move) "
          f"clusters not rigidly translated.")
    return 1


def verify_rotate(mode, pattern, verts_before, verts_after, sel_set):
    """xfrm.rotate (TransformRotate) is a rigid rotation around the ACEN
    pivot. Vertex distances from the pivot are preserved. The pivot
    depends on the mode (NOT always the cluster centroid):
      select/selectauto/border/local → cluster centroid (per-cluster)
      origin                          → world origin
      auto                            → drag-projected on Work Plane
                                        (single global pivot, not
                                        per-cluster — auto isn't local)
    """
    from itertools import combinations
    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}")
    print(f"  moved verts after drag:    {len(moved_after)}")
    if not moved_after:
        print("\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    clusters_pre = selected_clusters(pattern)

    # Decide the pivot we'll measure distances against. Per-cluster
    # centroid for selection-derived modes; single global pivot for
    # origin / border (bbox-of-all-selection); drag-position-dependent
    # for auto — we don't know the exact world pivot from screen coords
    # alone, so use the recovered "rotation centre" for the cluster.
    sel = selected_unique_verts(pattern)
    # actr.select / .selectauto / .border / .origin all give a SINGLE
    # global pivot (Phase 2 + 3 finding: bbox center of selection;
    # origin = world origin). Only actr.local gives per-cluster pivots.
    if mode == "origin":
        pivots_per_cluster = [(0.0, 0.0, 0.0)] * len(clusters_pre)
    elif mode in ("select", "selectauto", "border"):
        gp = bbox_center(sel)
        pivots_per_cluster = [gp] * len(clusters_pre)
    elif mode == "auto":
        # Auto: pivot is drag-projected onto Work Plane Y=0. We don't
        # have screen coords here, but we DO know it's a global single
        # pivot (not per-cluster), and its Y is 0 (Work Plane). For the
        # verifier we accept any pivot whose distances-from-it across
        # the moved verts are preserved — try several candidates.
        pivots_per_cluster = None
    else:  # local
        pivots_per_cluster = [bbox_center(c) for c in clusters_pre]

    if pivots_per_cluster is None:
        # auto: brute-force a single pivot whose distances are preserved
        # across all moved verts. Search over the drag-projected line
        # (Y=0 plane) at coarse spacing.
        all_pre = [tuple(v) for v in sel]
        all_post = list(moved_after)
        if len(all_pre) != len(all_post):
            print(f"  count mismatch sel={len(all_pre)} moved={len(all_post)}")
        # Try the drag start: world (CUBE_DRAG_X, CUBE_DRAG_Y) projected
        # — too complex without camera. Heuristic: rigid rotation
        # preserves vertex pairwise distances. Check that.
        pre_pairs = sorted(
            ((all_pre[i][0]-all_pre[j][0])**2
             + (all_pre[i][1]-all_pre[j][1])**2
             + (all_pre[i][2]-all_pre[j][2])**2) ** 0.5
            for i in range(len(all_pre)) for j in range(i+1, len(all_pre)))
        post_pairs = sorted(
            ((all_post[i][0]-all_post[j][0])**2
             + (all_post[i][1]-all_post[j][1])**2
             + (all_post[i][2]-all_post[j][2])**2) ** 0.5
            for i in range(len(all_post)) for j in range(i+1, len(all_post)))
        n = min(len(pre_pairs), len(post_pairs))
        err = sum((pre_pairs[k] - post_pairs[k])**2 for k in range(n))
        ok = err < 0.001
        mark = "OK" if ok else "FAIL"
        print(f"  pairwise-distance err = {err:.5f}  [{mark}]")
        if untouched_ok and ok:
            print(f"\033[32m  PASS\033[0m: actr.{mode}/{pattern} (rotate) "
                  f"rigid (pairwise distances preserved).")
            return 0
        print(f"\033[31m  FAIL\033[0m: actr.{mode}/{pattern} (rotate) "
              f"not a rigid rotation.")
        return 1

    print(f"  per-cluster pivots:")
    for p in pivots_per_cluster:
        print(f"    ({p[0]:+.4f}, {p[1]:+.4f}, {p[2]:+.4f})")

    used_indices = set()
    all_ok = True
    for ci, cluster in enumerate(clusters_pre):
        n = len(cluster)
        cen = pivots_per_cluster[ci]
        pre_dists = sorted(
            ((v[0]-cen[0])**2 + (v[1]-cen[1])**2 + (v[2]-cen[2])**2)**0.5
            for v in cluster)
        avail = [j for j in range(len(moved_after)) if j not in used_indices]
        best = None
        best_err = float("inf")
        for combo in combinations(avail, n):
            pts = [moved_after[j] for j in combo]
            post_dists = sorted(
                ((p[0]-cen[0])**2 + (p[1]-cen[1])**2 + (p[2]-cen[2])**2)**0.5
                for p in pts)
            err = sum((post_dists[i] - pre_dists[i])**2 for i in range(n))
            if err < best_err:
                best_err = err; best = combo
        if best is None:
            print(f"  cluster {ci}: no candidate subset"); all_ok = False; continue
        used_indices.update(best)
        ok = best_err < 0.001
        mark = "OK" if ok else "FAIL"
        print(f"  cluster {ci}: distance-preservation err = {best_err:.5f}  [{mark}]")
        all_ok = all_ok and ok

    if untouched_ok and all_ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode}/{pattern} (rotate) "
              f"rigid rotation around predicted pivot.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode}/{pattern} (rotate) "
          f"distances not preserved.")
    return 1


def selected_unique_verts_runtime(pattern, verts_before):
    """For runtime-selection patterns (e.g. sphere_top) PATTERN_POLYS
    has no entries. Read selection from /tmp/modo_drag_state.json's
    `before` plus `selected_indices` if available, otherwise infer
    from before/after diff post-test (used by main path only)."""
    return None


def main():
    result_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/modo_drag_result.json"
    state_path  = "/tmp/modo_drag_state.json"

    with open(result_path) as f:
        verts_after = json.load(f)["verts"]
    with open(state_path) as f:
        state = json.load(f)

    mode    = os.environ.get("MODE", state.get("acen_mode", "select"))
    pattern = state.get("pattern", "single_top")
    tool    = state.get("tool",    "scale")
    verts_before = state.get("before", [])

    # Runtime patterns (sphere_top etc) — selection is computed in MODO.
    # We infer it post-hoc from which verts moved in the result.
    if pattern not in PATTERN_POLYS:
        print(f"mode: {mode}   pattern: {pattern}   tool: {tool}")
        # Determine which verts moved (selected) vs stayed.
        moved = []
        stayed = []
        for a in verts_after:
            matched = False
            for b in verts_before:
                if all(at(a[i], b[i]) for i in range(3)): matched = True; break
            if matched: stayed.append(tuple(a))
            else:       moved.append(tuple(a))
        print(f"  moved verts: {len(moved)}, stayed: {len(stayed)}")
        # Sphere top half: just verify SOMETHING moved (smoke test).
        if moved:
            print(f"\033[32m  PASS\033[0m (smoke): {len(moved)} verts moved on {pattern}/{tool}/{mode}.")
            return 0
        print(f"\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    sel = selected_unique_verts(pattern)
    sel_set = {(round(v[0], 4), round(v[1], 4), round(v[2], 4)) for v in sel}

    print(f"mode: {mode}   pattern: {pattern}   tool: {tool}")
    print(f"  selection: {len(sel)} unique verts in "
          f"{len(PATTERN_POLYS[pattern])} polygons, "
          f"{len(selected_clusters(pattern))} cluster(s)")

    # xfrm.rotate preserves distances from cluster centroid.
    if tool == "rotate":
        return verify_rotate(mode, pattern, verts_before, verts_after, sel_set)

    # xfrm.move is pivot-invariant: weaker pass criteria.
    if tool == "move":
        return verify_move(mode, pattern, verts_before, verts_after, sel_set)

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
