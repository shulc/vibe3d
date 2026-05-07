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


# State source-of-truth: we read `selected_verts` and `clusters` from
# /tmp/modo_drag_state.json directly, populated by modo_drag_setup.py
# at MODO-side test setup. This means the verifier no longer depends
# on PATTERN_POLYS for runtime-selection patterns (e.g. sphere_top
# whose vertex positions vary with `prim.sphere`'s segment count).
def selected_unique_verts_from_state(state):
    """Return the list of (x, y, z) tuples for selected verts, prefer-
    ring state['selected_verts'] (set by setup script). Falls back to
    PATTERN_POLYS for older state files that pre-date the field."""
    if "selected_verts" in state:
        return [tuple(v) for v in state["selected_verts"]]
    pattern = state.get("pattern", "single_top")
    seen = set(); out = []
    for poly in PATTERN_POLYS.get(pattern, []):
        for v in poly:
            t = tuple(v)
            if t not in seen:
                seen.add(t); out.append(t)
    return out


def selected_clusters_from_state(state):
    """Cluster groupings of selected verts. Source order:
    1. state['clusters'] (setup-script computed)
    2. PATTERN_POLYS-based reconstruction (legacy fallback)
    3. single cluster of all selected verts (last resort)."""
    if "clusters" in state:
        return [[tuple(v) for v in c] for c in state["clusters"]]
    pattern = state.get("pattern", "single_top")
    if pattern in PATTERN_POLYS:
        polys = [list(map(tuple, p)) for p in PATTERN_POLYS[pattern]]
        n = len(polys)
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
    # Last resort: treat the whole selection as one cluster.
    return [list(state.get("selected_verts", []))]


def predict_pivot(mode, sel, clusters, border=None):
    """Return predicted pivot, list of acceptable pivots, or None
    (drag-position-dependent → skip exact check)."""
    if mode in ("select", "selectauto"):
        # MODO 9 empirically uses BBOX CENTER for both — see
        # doc/acen_modo_parity_plan.md Phase 2. Docs claim "average
        # vertex position" for select but the artifact disagrees; we
        # follow the artifact.
        return [bbox_center(sel)]
    if mode == "border":
        # ACEN.Border uses the bbox center of the SELECTION BORDER —
        # verts on edges that bound the selection (one selected, one
        # unselected adjacent face). For a cube's top face the border
        # is the perimeter (4 verts, same center as the face); for a
        # sphere's top hemisphere the border is the equator ring.
        return [bbox_center(border)] if border else [bbox_center(sel)]
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


def verify_local(clusters_pre, verts_before, verts_after, sel_set):
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


def verify_move(mode, sel, clusters_pre, verts_before, verts_after,
                sel_set, tool_amount):
    """xfrm.move translates selected verts. ACEN pivot is irrelevant
    (translate is pivot-invariant). For ACEN.Local each cluster can
    have its own AXIS basis → per-cluster world deltas can differ.

    Verification: each cluster must be RIGIDLY translated — every vert
    in the cluster shifts by the same world delta. We pair each pre
    vert in cluster `c` with the nearest unused post vert; if all
    pairings within `c` give the same delta, the cluster is OK.

    `tool_amount` (xfrm.move's X/Y/Z) is NOT used here — those values
    are in the tool's local frame (AXIS basis), and we don't have the
    basis published by AXIS stage.  The geometric pairing gives world
    deltas directly.
    """
    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")
    print(f"  moved verts after drag:    {len(moved_after)}")
    if not moved_after:
        print("\033[31m  FAIL\033[0m: no verts moved.")
        return 1

    # Per-cluster rigid-translation check by searching for the post-vert
    # SUBSET that is exactly the cluster's pre-verts translated by some
    # delta T. Concretely: for a candidate T, all cluster pre-verts +T
    # must have a unique matching post-vert (within TOL). T candidates
    # come from "what delta would map pre-vert 0 to some post-vert" — n
    # × m candidates total (n = cluster size, m = moved_after count).
    # Avoids global Hungarian's cross-cluster confusion when clusters
    # land in similar regions (ACEN.Local: each cluster moves along its
    # own world-space axis).
    used_post = set()
    cluster_ok_by_idx = {}
    # Process clusters in decreasing size — a small cluster's translated
    # bbox can sit inside a larger cluster's translated bbox (asymmetric
    # pattern: 4-vert subface ⊂ 6-vert supface). Matching the big one
    # first removes its posts from the pool before the small one tries.
    order = sorted(range(len(clusters_pre)),
                   key=lambda i: -len(clusters_pre[i]))
    for ci in order:
        cluster = clusters_pre[ci]
        n = len(cluster)
        avail = [j for j in range(len(moved_after)) if j not in used_post]
        if len(avail) < n:
            print(f"  cluster {ci}: not enough free post verts"); cluster_ok_by_idx[ci] = False; continue

        best_T = None
        best_subset = None
        # Try candidate T = post[j] - cluster[0] for each j; verify the
        # whole cluster is translated by that T into available posts.
        anchor = cluster[0]
        for j in avail:
            T = tuple(moved_after[j][k] - anchor[k] for k in range(3))
            subset = [j]
            ok = True
            for v in cluster[1:]:
                tgt = tuple(v[k] + T[k] for k in range(3))
                hit = None
                for jj in avail:
                    if jj in subset: continue
                    p = moved_after[jj]
                    if all(at(p[k], tgt[k]) for k in range(3)):
                        hit = jj; break
                if hit is None:
                    ok = False; break
                subset.append(hit)
            if ok:
                best_T = T
                best_subset = subset
                break

        if best_T is None:
            print(f"  cluster {ci}: no consistent translation found")
            cluster_ok_by_idx[ci] = False; continue
        used_post.update(best_subset)
        print(f"  cluster {ci}: delta ≈ "
              f"({best_T[0]:+.4f}, {best_T[1]:+.4f}, {best_T[2]:+.4f})  [OK]")
        cluster_ok_by_idx[ci] = True

    all_ok = untouched_ok and all(cluster_ok_by_idx.values())
    if all_ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode} (move) "
              f"each cluster translated rigidly.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode} (move) "
          f"clusters not rigidly translated.")
    return 1


def verify_rotate(mode, sel, clusters_pre, verts_before, verts_after, sel_set):
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
            print(f"\033[32m  PASS\033[0m: actr.{mode} (rotate) "
                  f"rigid (pairwise distances preserved).")
            return 0
        print(f"\033[31m  FAIL\033[0m: actr.{mode} (rotate) "
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
        # RMS per-vert distance error vs MODO's drag-evaluate jitter (TOL).
        # Absolute sum-of-squares scales with cluster size — sphere_top
        # (~145 verts) trips a fixed threshold even at sub-pixel jitter.
        rms = (best_err / max(1, n)) ** 0.5
        ok = rms < TOL
        mark = "OK" if ok else "FAIL"
        print(f"  cluster {ci}: distance-preservation rms = {rms:.5f}  [{mark}]")
        all_ok = all_ok and ok

    if untouched_ok and all_ok:
        print(f"\033[32m  PASS\033[0m: actr.{mode} (rotate) "
              f"rigid rotation around predicted pivot.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode} (rotate) "
          f"distances not preserved.")
    return 1


def main():
    result_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/modo_drag_result.json"
    state_path  = "/tmp/modo_drag_state.json"

    with open(result_path) as f:
        result = json.load(f)
    verts_after = result["verts"]
    tool_amount = result.get("tool_amount")
    with open(state_path) as f:
        state = json.load(f)

    mode    = os.environ.get("MODE", state.get("acen_mode", "select"))
    pattern = state.get("pattern", "single_top")
    tool    = state.get("tool",    "scale")
    verts_before = state.get("before", [])

    # Selection now comes from the state JSON (setup script computes
    # it). Same code path for hardcoded patterns and runtime ones —
    # the smoke-only sphere_top branch is gone.
    sel      = selected_unique_verts_from_state(state)
    clusters = selected_clusters_from_state(state)
    border   = [tuple(v) for v in state.get("border_verts", [])] or None
    sel_set  = {(round(v[0], 4), round(v[1], 4), round(v[2], 4)) for v in sel}

    print(f"mode: {mode}   pattern: {pattern}   tool: {tool}")
    print(f"  selection: {len(sel)} unique verts in {len(clusters)} cluster(s)")

    if tool == "rotate":
        return verify_rotate(mode, sel, clusters,
                             verts_before, verts_after, sel_set)
    if tool == "move":
        return verify_move(mode, sel, clusters,
                           verts_before, verts_after, sel_set, tool_amount)

    # Local mode is special — per-cluster transforms can't be decomposed
    # into a single (k, P), so use a dedicated verifier.
    if mode == "local" and len(clusters) >= 2:
        return verify_local(clusters, verts_before, verts_after, sel_set)

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

    pred = predict_pivot(mode, sel, clusters, border)
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
        print(f"\033[32m  PASS\033[0m: actr.{mode} pivot matches prediction.")
        return 0
    print(f"\033[31m  FAIL\033[0m: actr.{mode} pivot does NOT match.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
