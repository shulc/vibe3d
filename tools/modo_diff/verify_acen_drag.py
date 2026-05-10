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
        # MODO's actr.auto pivots at the click projected onto the work
        # plane — but recovering that pivot from a single drag's mesh
        # delta isn't possible: when xfrm.scale operates on a single
        # face (zero Y-extent) and along an axis (not center disk),
        # the geometric `decompose()` fit confounds pivot with drag
        # delta direction. To verify auto numerically we'd need to
        # drive vibe3d through the same pixel-drag with the same
        # camera and compare meshes (cross-engine). state.json's
        # `camera` dump is the input for that test.
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


def apply_falloff_shape(t, shape, in_, out_):
    """Map normalised distance t∈[0,1] (0=full influence, 1=no influence)
    to weight w∈[0,1] per the shape preset. Mirror of source/falloff.d's
    `applyShape` (line 180+)."""
    if t <= 0.0: return 1.0
    if t >= 1.0: return 0.0
    if shape == "linear":
        return 1.0 - t
    if shape == "easeIn":
        return 1.0 - t * t
    if shape == "easeOut":
        u = 1.0 - t
        return u * u
    if shape == "smooth":
        # smoothstep(t) = 3t² - 2t³; falling complement → 1 - smoothstep(t)
        s = t * t * (3.0 - 2.0 * t)
        return 1.0 - s
    if shape == "custom":
        # Cubic Bezier from (0,1) to (1,0) with control point y-coords
        # (2-out_)/3 (P1) and (1+in_)/3 (P2). Matches MODO 9's
        # falloff.linear Custom shape — at in_=out_=0 both control
        # points lie on the linear baseline y=1-t, so the curve
        # collapses to plain linear (verified empirically by probing
        # MODO with (in,out) ∈ {0,1}²; matches source/falloff.d's new
        # Custom branch added after that probe).
        u = 1.0 - t
        w = u + in_ * t * t * u - out_ * t * u * u
        if w < 0.0: w = 0.0
        if w > 1.0: w = 1.0
        return w
    # Unknown shape — fall back to linear (already-defensive behaviour).
    return 1.0 - t


def evaluate_linear_falloff(pos, start, end, shape="linear",
                            in_=0.0, out_=0.0):
    """MODO-style linear falloff weight. Project (pos - start) onto the
    axis (end - start), clamp t = dot/|axis|² to [0,1], pass through
    the shape attenuation. Off-axis distance is ignored — Linear in
    MODO is band-shaped, not cone-shaped. Matches source/falloff.d:55."""
    ax = tuple(end[i] - start[i] for i in range(3))
    ax_sq = sum(a * a for a in ax)
    if ax_sq < 1e-12:
        return 1.0
    rel = tuple(pos[i] - start[i] for i in range(3))
    t = sum(rel[i] * ax[i] for i in range(3)) / ax_sq
    return apply_falloff_shape(t, shape, in_, out_)


def evaluate_radial_falloff(pos, center, size, shape="linear",
                            in_=0.0, out_=0.0):
    """MODO-style radial (ellipsoid) falloff. Computes the normalised
    ellipsoid distance d = sqrt(sum((pos[i]-center[i])/size[i])²) over
    nonzero-size axes, clamps to [0,1], passes through shape. Axes
    with size ≤ 0 are dropped from the distance. Matches
    source/falloff.d:78."""
    s = 0.0
    any_axis = False
    for i in range(3):
        if size[i] > 1e-9:
            u = (pos[i] - center[i]) / size[i]
            s += u * u
            any_axis = True
    if not any_axis:
        return 1.0
    import math
    t = math.sqrt(s)
    return apply_falloff_shape(t, shape, in_, out_)


def evaluate_falloff_weight(pos, falloff):
    """Dispatch by falloff.type. Reads type/shape/in/out + per-type
    geometry attrs from the falloff dict (as published in state.json
    by modo_falloff_setup.py)."""
    ftype = falloff.get("type", "linear")
    shape = falloff.get("shape", "linear")
    in_   = float(falloff.get("in",  0.0))
    out_  = float(falloff.get("out", 0.0))
    if ftype == "linear":
        start = falloff.get("start", [0.0, 0.0, 0.0])
        end   = falloff.get("end",   [0.0, 1.0, 0.0])
        return evaluate_linear_falloff(pos, start, end, shape, in_, out_)
    if ftype == "radial":
        center = falloff.get("center", [0.0, 0.0, 0.0])
        size   = falloff.get("size",   [1.0, 1.0, 1.0])
        return evaluate_radial_falloff(pos, center, size, shape, in_, out_)
    return 1.0


def verify_move_falloff(falloff, sel, verts_before, verts_after, sel_set):
    """Per-vertex weighted-translation check. xfrm.move with falloff
    applies `Δ_ref * weight(v)` per selected vert; we recover Δ_ref
    from the highest-weight pre-vert (which received the full delta)
    and verify every other selected vert hit the predicted weighted
    position. Verts with weight=0 stay put.

    Pairing is delta-direction-aware so the gradient of partial
    movements doesn't confuse it: anchor on max-weight pre-vert,
    accept the candidate Δ_ref that produces a valid post-vert match
    for ALL pre-verts under the falloff weighting."""
    ftype = falloff.get("type", "linear")
    shape = falloff.get("shape", "linear")
    in_   = float(falloff.get("in",  0.0))
    out_  = float(falloff.get("out", 0.0))
    if ftype not in ("linear", "radial"):
        print(f"\033[31m  FAIL\033[0m: unsupported falloff type '{ftype}'")
        return 1

    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")

    # weight for each selected pre-vert
    weights = [evaluate_falloff_weight(v, falloff) for v in sel]
    w_min = min(weights)
    w_max = max(weights)
    extra = ""
    if shape == "custom":
        extra = f"  in={in_:g} out={out_:g}"
    if ftype == "linear":
        start = tuple(falloff.get("start", [0.0, 0.0, 0.0]))
        end   = tuple(falloff.get("end",   [0.0, 1.0, 0.0]))
        print(f"  falloff: linear  shape={shape}{extra}  "
              f"start={start}  end={end}")
    else:  # radial
        center = tuple(falloff.get("center", [0.0, 0.0, 0.0]))
        size   = tuple(falloff.get("size",   [1.0, 1.0, 1.0]))
        print(f"  falloff: radial  shape={shape}{extra}  "
              f"center={center}  size={size}")
    print(f"  per-vert weights: {len(sel)} verts, "
          f"range [{w_min:.3f} .. {w_max:.3f}]")

    if w_max < 0.5:
        print(f"\033[31m  FAIL\033[0m: no vert has weight ≥ 0.5; can't "
              f"recover Δ_ref. Check falloff start/end vs selection.")
        return 1

    # Anchor: pre-vert with max weight (likely == 1.0).
    anchor_i = max(range(len(sel)), key=lambda i: weights[i])
    anchor   = sel[anchor_i]
    w_anchor = weights[anchor_i]

    # Try each available post-vert as the anchor's match. The right
    # Δ_ref is the one that lets EVERY pre-vert (including weight=0
    # ones, which must match a post equal to the pre) find a unique
    # post-vert at `pre + weight * Δ_ref`.
    n_sel = len(sel)
    n_post = len(moved_after)
    if n_post < n_sel:
        # weight=0 verts stayed at pre-positions; they may match
        # untouched_pre but split_moved_unmoved already filtered those
        # out (sel verts aren't in untouched_pre). So all n_sel verts
        # MUST appear in moved_after.
        print(f"\033[31m  FAIL\033[0m: moved_after has {n_post} verts but "
              f"selection has {n_sel}. Some selected verts vanished.")
        return 1

    best_delta = None
    best_match = None
    best_err   = float("inf")
    for cand_j in range(n_post):
        cand_post = moved_after[cand_j]
        cand_delta = tuple((cand_post[k] - anchor[k]) / w_anchor
                           for k in range(3))
        # Try to match every pre-vert against moved_after using this Δ.
        used = set()
        ok = True
        total_err = 0.0
        match = [None] * n_sel
        for i, v in enumerate(sel):
            w = weights[i]
            tgt = tuple(v[k] + w * cand_delta[k] for k in range(3))
            best_j = None
            best_d = float("inf")
            for j in range(n_post):
                if j in used: continue
                p = moved_after[j]
                d = sum((p[k] - tgt[k]) ** 2 for k in range(3))
                if d < best_d:
                    best_d = d; best_j = j
            if best_j is None or best_d > TOL * TOL:
                ok = False; break
            used.add(best_j)
            match[i] = best_j
            total_err += best_d
        if ok and total_err < best_err:
            best_err = total_err
            best_delta = cand_delta
            best_match = match

    if best_delta is None:
        print(f"\033[31m  FAIL\033[0m: no Δ_ref candidate produced a "
              f"consistent per-vert weighted-move match.")
        return 1

    rms = (best_err / n_sel) ** 0.5
    print(f"  recovered Δ_ref ≈ "
          f"({best_delta[0]:+.4f}, {best_delta[1]:+.4f}, {best_delta[2]:+.4f})")
    print(f"  per-vert match rms = {rms:.5f}  (TOL={TOL})")
    # Sanity: a "no movement" drag matches trivially (Δ_ref = 0 with
    # any weights). For our cases that means MODO didn't pick up the
    # drag — usually because the falloff stage stole the drag handler.
    # Reject sub-TOL Δ_ref as a false positive.
    delta_mag = sum(d * d for d in best_delta) ** 0.5
    if delta_mag < TOL:
        print(f"\033[31m  FAIL\033[0m: |Δ_ref| = {delta_mag:.5f} < TOL "
              f"— drag did not move any verts (engine may have ignored "
              f"the drag, e.g. because the falloff tool stole the drag "
              f"handler).")
        return 1

    if untouched_ok and rms < TOL:
        print(f"\033[32m  PASS\033[0m: linear-falloff move — every vert "
              f"moved by weight × Δ_ref.")
        return 0
    print(f"\033[31m  FAIL\033[0m: linear-falloff move — per-vert "
          f"weighted match failed.")
    return 1


def verify_scale_falloff(falloff, mode, sel, verts_before, verts_after,
                         sel_set):
    """Per-vertex weighted-scale check. xfrm.scale with falloff applies
    `post = (pre - pivot) · (1 + (k - 1)·weight(v)) + pivot` per vert,
    where k is the (per-axis) scale factor recovered from the drag.
    For uniform-scale drags k is the same on all 3 axes; per-axis-scale
    drags expose three independent k values.

    Strategy:
      1. Pick pivot from `mode` (single-global-pivot modes only).
      2. weight=0 verts pin to themselves (post = pre).
      3. Recover per-axis k from weight≈1 anchor verts: k_axis =
         (post.axis - pivot.axis) / (pre.axis - pivot.axis), averaged.
      4. Predict post per vert and 1-to-1 pair with moved_after, then
         report rms.
    """
    if mode in ("select", "selectauto", "border"):
        pivot = bbox_center(sel)
    elif mode == "origin":
        pivot = (0.0, 0.0, 0.0)
    else:
        print(f"  SKIP: scale-falloff verification unsupported for "
              f"mode='{mode}' (no single global pivot).")
        return 0

    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")
    print(f"  pivot: ({pivot[0]:+.4f}, {pivot[1]:+.4f}, {pivot[2]:+.4f})")

    weights = [evaluate_falloff_weight(v, falloff) for v in sel]
    w_max = max(weights)
    print(f"  per-vert weights: {len(sel)} verts, "
          f"range [{min(weights):.3f} .. {w_max:.3f}]")
    if w_max < 0.99:
        print(f"\033[31m  FAIL\033[0m: no weight=1 anchor verts; can't "
              f"recover full-scale factor reference.")
        return 1

    # weight=0 verts pin to themselves so they don't get poached.
    used = set()
    pair_idx = [None] * len(sel)
    for i, v in enumerate(sel):
        if weights[i] >= 1e-3: continue
        for j in range(len(moved_after)):
            if j in used: continue
            p = moved_after[j]
            if all(abs(p[k] - v[k]) < TOL for k in range(3)):
                used.add(j); pair_idx[i] = j; break

    # Brute-force the (uniform) scale factor k. For each candidate k,
    # predict every vert's post under `1 + (k-1)·weight` per axis and
    # 1-to-1 greedy pair with moved_after; pick the k with smallest
    # total residual. (Greedy anchor-by-closest matching mismatches
    # weight=1 verts when partial-weight verts land geometrically
    # closer to the pre position — same hazard as rotate's anchor row
    # collinearity.) Default test camera + drag produces uniform scale,
    # so a single k suffices; per-axis variants would extend this loop
    # over a 3D grid.
    best = (None, float("inf"), None)   # k, err, pair_map
    # Sweep k ∈ [-3, 3] in 0.02 steps (avoids k=1 collapse to identity).
    n_steps = 301
    for step in range(n_steps):
        k_try = -3.0 + step * (6.0 / (n_steps - 1))
        if abs(k_try - 1.0) < 0.001: continue
        preds = []
        for i in range(len(sel)):
            rel = tuple(sel[i][a] - pivot[a] for a in range(3))
            f = 1.0 + (k_try - 1.0) * weights[i]
            preds.append(tuple(rel[a] * f + pivot[a] for a in range(3)))
        used2 = set(); err = 0.0; ok = True
        pmap = [None] * len(sel)
        for i, p in enumerate(preds):
            bj = None; bd = float("inf")
            for j in range(len(moved_after)):
                if j in used2: continue
                d2 = sum((p[a] - moved_after[j][a])**2 for a in range(3))
                if d2 < bd: bd, bj = d2, j
            if bj is None: ok = False; break
            used2.add(bj); pmap[i] = bj; err += bd
            if err >= best[1]: ok = False; break
        if ok and err < best[1]:
            best = (k_try, err, pmap)
    k, _, pair_idx = best
    if k is None:
        print(f"\033[31m  FAIL\033[0m: no k candidate produced a valid "
              f"1-to-1 pairing.")
        return 1
    print(f"  recovered uniform scale factor k = {k:.4f}")

    err = 0.0; n = 0
    for i in range(len(sel)):
        rel = tuple(sel[i][a] - pivot[a] for a in range(3))
        f = 1.0 + (k - 1.0) * weights[i]
        pred = tuple(rel[a] * f + pivot[a] for a in range(3))
        p = moved_after[pair_idx[i]]
        err += sum((p[a] - pred[a]) ** 2 for a in range(3)); n += 1
    rms = (err / max(1, n)) ** 0.5
    print(f"  per-vert weighted-scale rms = {rms:.5f}  (TOL={TOL})")

    if untouched_ok and rms < TOL:
        print(f"\033[32m  PASS\033[0m: linear-falloff scale — every "
              f"vert scaled by 1 + (k-1)·weight around pivot.")
        return 0
    print(f"\033[31m  FAIL\033[0m: linear-falloff scale — weighted "
          f"prediction doesn't match observed posts.")
    return 1


def verify_rotate_falloff(falloff, mode, sel, verts_before, verts_after,
                          sel_set):
    """Per-vertex weighted-rotation check. MODO's xfrm.rotate with
    falloff applies post = pre + weight·(R(pre) - pre) — a CHORD-lerp
    between identity and the full rotation, NOT an arc-rotation by
    base_angle·weight. (Empirically observed: at weight<1 the chord
    interpolation pulls the vert inside the rotation circle, shrinking
    its distance from the pivot.) The rigid full-rotation R is shared
    across all selected verts; we recover it from the highest-weight
    pre/post pair via Kabsch fit over the weight≈1 verts.

    Strategy:
      1. Pick pivot from `mode` (single-global-pivot modes only).
      2. Identify weight≈1 verts; recover R (3×3 rotation) by Kabsch
         on (pre, post) pairs — these verts have post = R(pre) since
         lerp coefficient is 1.
      3. For each remaining pre-vert v, predict
         post_pred = pre + weight·(R(pre - pivot) + pivot - pre).
         Match every actual post-vert to its predicted target by
         minimum-distance assignment.

    Modes without a single global pivot (auto, local, none) get a
    SKIP — the test infrastructure can't disambiguate them here.
    """
    import math
    if mode in ("select", "selectauto", "border"):
        pivot = bbox_center(sel)
    elif mode == "origin":
        pivot = (0.0, 0.0, 0.0)
    else:
        print(f"  SKIP: rotate-falloff verification unsupported for "
              f"mode='{mode}' (no single global pivot).")
        return 0

    untouched_ok, untouched_pre, moved_after = split_moved_unmoved(
        verts_before, verts_after, sel_set)
    print(f"  untouched verts preserved: {untouched_ok}  "
          f"({len(untouched_pre)} verts)")
    print(f"  pivot: ({pivot[0]:+.4f}, {pivot[1]:+.4f}, {pivot[2]:+.4f})")

    weights = [evaluate_falloff_weight(v, falloff) for v in sel]
    w_max = max(weights)
    print(f"  per-vert weights: {len(sel)} verts, "
          f"range [{min(weights):.3f} .. {w_max:.3f}]")
    if w_max < 0.99:
        print(f"\033[31m  FAIL\033[0m: no weight=1 verts; Kabsch fit "
              f"needs the full-rotation reference verts.")
        return 1

    # Step 1: pin weight≈0 verts (post == pre) so they don't get
    # poached by partial-weight matching.
    used = set()
    pair_idx = [None] * len(sel)
    for i, v in enumerate(sel):
        if weights[i] >= 1e-3: continue
        for j in range(len(moved_after)):
            if j in used: continue
            p = moved_after[j]
            if all(abs(p[k] - v[k]) < TOL for k in range(3)):
                used.add(j); pair_idx[i] = j; break

    # Step 2: identify weight≈1 anchor verts; pair each with its
    # rigid-rotation post-image (radius preserved exactly). Greedy
    # by smallest Δr to break ties between the 6 corner-row verts.
    def rsq(p):
        return sum((p[i] - pivot[i]) ** 2 for i in range(3))
    anchors = [i for i in range(len(sel)) if weights[i] >= 0.99]
    for i in anchors:
        pre_r = rsq(sel[i]) ** 0.5
        best_j, best_d = None, float("inf")
        for j in range(len(moved_after)):
            if j in used: continue
            dr = abs(rsq(moved_after[j]) ** 0.5 - pre_r)
            if dr < best_d: best_d, best_j = dr, j
        if best_j is None or best_d > TOL:
            print(f"\033[31m  FAIL\033[0m: anchor vert #{i} (w=1) could "
                  f"not be paired by radius (best Δr={best_d:.4f})")
            return 1
        used.add(best_j); pair_idx[i] = best_j

    # Step 3: brute-force the (axis, base_angle) pair. We try a small
    # set of canonical world axes — for our default-camera test cases,
    # the dragged-rotation axis MODO picks always lies along world Y
    # (horizontal screen drag → camera-up rotation → ≈ +Y for the
    # default test view). For each candidate axis, sweep base_angle
    # in 1° steps over [0, 360°] and pick the (axis, angle) that
    # minimises total per-vert prediction residual under the
    # arc-rotation model — `rotateVec(pre - pivot, axis, angle·w) +
    # pivot` per vert, matching vibe3d's `source/tools/rotate.d:568`.
    # A full Kabsch fit would be cleaner but degenerates on the
    # weight=1 anchor row of `top_face_seg5` (all 6 anchors lie on
    # one line in the y=0.5/z=-0.5 plane — Kabsch needs non-coplanar
    # pairs to recover the axis unambiguously).
    def vsub(a, b): return tuple(a[i] - b[i] for i in range(3))
    def axis_angle_rot(v, ax, ang):
        c = math.cos(ang); s = math.sin(ang); k = 1.0 - c
        x, y, z = ax
        return (
            v[0]*(c + x*x*k)     + v[1]*(x*y*k - z*s) + v[2]*(x*z*k + y*s),
            v[0]*(x*y*k + z*s)   + v[1]*(c + y*y*k)   + v[2]*(y*z*k - x*s),
            v[0]*(x*z*k - y*s)   + v[1]*(y*z*k + x*s) + v[2]*(c + z*z*k),
        )
    candidate_axes = [
        ( 0.0,  1.0,  0.0),  # +Y (camera-up for default test view)
        ( 0.0, -1.0,  0.0),  # -Y
        ( 1.0,  0.0,  0.0),  # +X
        ( 0.0,  0.0,  1.0),  # +Z
    ]
    best = (None, None, float("inf"), None)   # axis, angle, err, pair_map
    for ax in candidate_axes:
        for deg in range(0, 360):
            ang = math.radians(deg)
            preds = []
            for i in range(len(sel)):
                rel = vsub(sel[i], pivot)
                p = axis_angle_rot(rel, ax, ang * weights[i])
                preds.append((p[0]+pivot[0], p[1]+pivot[1], p[2]+pivot[2]))
            # 1-to-1 greedy pair pred → moved_after.
            used2 = set(); err = 0.0; ok = True
            pmap = [None] * len(sel)
            for i, p in enumerate(preds):
                bj = None; bd = float("inf")
                for j in range(len(moved_after)):
                    if j in used2: continue
                    d2 = sum((p[k]-moved_after[j][k])**2 for k in range(3))
                    if d2 < bd: bd, bj = d2, j
                if bj is None: ok = False; break
                used2.add(bj); pmap[i] = bj; err += bd
                if err >= best[2]: ok = False; break
            if ok and err < best[2]:
                best = (ax, ang, err, pmap)
    axis, angle, _, best_map = best
    print(f"  recovered base rotation = {math.degrees(angle):+.3f}°  "
          f"axis ≈ ({axis[0]:+.3f}, {axis[1]:+.3f}, {axis[2]:+.3f})")

    # Step 4: use the matching from the best brute-force candidate.
    # The earlier weight=0/weight=1 pin-pairings were heuristics; the
    # brute-force matching is tied directly to the recovered (axis,
    # angle) and is internally consistent.
    pair_idx = best_map
    pred = [None] * len(sel)
    for i in range(len(sel)):
        rel = vsub(sel[i], pivot)
        rotated = axis_angle_rot(rel, axis, angle * weights[i])
        pred[i] = tuple(rotated[k] + pivot[k] for k in range(3))

    # Match unpaired pre-verts to nearest-pred unused posts.
    err = 0.0
    n = 0
    for i in range(len(sel)):
        if pair_idx[i] is not None:
            p = moved_after[pair_idx[i]]
            d2 = sum((p[k] - pred[i][k]) ** 2 for k in range(3))
            err += d2; n += 1
            continue
        best_j, best_d = None, float("inf")
        for j in range(len(moved_after)):
            if j in used: continue
            d2 = sum((moved_after[j][k] - pred[i][k]) ** 2 for k in range(3))
            if d2 < best_d: best_d, best_j = d2, j
        if best_j is None:
            print(f"\033[31m  FAIL\033[0m: vert #{i} (w={weights[i]:.3f}) "
                  f"has no available post-pair candidate.")
            return 1
        used.add(best_j); pair_idx[i] = best_j
        err += best_d; n += 1
    rms = (err / max(1, n)) ** 0.5
    print(f"  per-vert arc-rotation rms = {rms:.5f}  (TOL={TOL})")

    if untouched_ok and rms < TOL:
        print(f"\033[32m  PASS\033[0m: linear-falloff rotate — every "
              f"vert rotated by base_angle × weight around pivot.")
        return 0
    print(f"\033[31m  FAIL\033[0m: linear-falloff rotate — arc-rotation "
          f"prediction doesn't match observed posts.")
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
    # argv: [result_path] [state_path] — defaults are the legacy shared
    # paths. Per-worker callers pass /tmp/worker_<i>/{result,state}.json.
    result_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/modo_drag_result.json"
    state_path  = sys.argv[2] if len(sys.argv) > 2 else "/tmp/modo_drag_state.json"

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

    falloff = state.get("falloff")

    print(f"mode: {mode}   pattern: {pattern}   tool: {tool}"
          f"{'   falloff: ' + falloff['type'] if falloff else ''}")
    print(f"  selection: {len(sel)} unique verts in {len(clusters)} cluster(s)")

    # Falloff dispatch: per-vertex weighted transforms break the
    # rigid-cluster assumptions in verify_move/verify_rotate, so when
    # a Falloff stage is present we route to a falloff-aware verifier.
    if falloff is not None and tool == "move":
        return verify_move_falloff(falloff, sel,
                                   verts_before, verts_after, sel_set)
    if falloff is not None and tool == "rotate":
        return verify_rotate_falloff(falloff, mode, sel,
                                     verts_before, verts_after, sel_set)
    if falloff is not None and tool == "scale":
        return verify_scale_falloff(falloff, mode, sel,
                                    verts_before, verts_after, sel_set)

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
