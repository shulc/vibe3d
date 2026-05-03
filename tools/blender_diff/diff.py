#!/usr/bin/env python3
"""Compare two mesh JSON dumps by position-matching vertices.

Usage: diff.py <reference.json> <candidate.json> [--tolerance N]
       diff.py <reference.json> <candidate.json> --case <case.json>

Exit code: 0 on agreement (worst per-vertex distance < tolerance),
           1 on disagreement, 2 on usage error.
"""
import argparse, json, math, sys

def dist(a, b):
    return math.sqrt(sum((a[i] - b[i])**2 for i in range(3)))

def fvdist(faces):
    h = {}
    for f in faces: h[len(f)] = h.get(len(f), 0) + 1
    return h

def nearest_match(srcs, dsts):
    """For each src vertex, return (dst_idx, distance) of the nearest dst."""
    out = []
    for s in srcs:
        best, bestd = -1, float('inf')
        for di, d in enumerate(dsts):
            dd = dist(s, d)
            if dd < bestd: bestd = dd; best = di
        out.append((best, bestd))
    return out

def face_centroid(face, verts):
    cx = cy = cz = 0.0
    for vi in face:
        v = verts[vi]; cx += v[0]; cy += v[1]; cz += v[2]
    n = len(face)
    return (cx / n, cy / n, cz / n)

def face_normal(face, verts):
    """Newell's method — stable polygon normal regardless of convexity."""
    nx = ny = nz = 0.0
    n = len(face)
    for i in range(n):
        a = verts[face[i]]; b = verts[face[(i + 1) % n]]
        nx += (a[1] - b[1]) * (a[2] + b[2])
        ny += (a[2] - b[2]) * (a[0] + b[0])
        nz += (a[0] - b[0]) * (a[1] + b[1])
    L = math.sqrt(nx * nx + ny * ny + nz * nz)
    if L < 1e-12: return (0.0, 0.0, 0.0)
    return (nx / L, ny / L, nz / L)

def check_winding(A, B, matches_ab):
    """Translate each A face's vertex indices through matches_ab into B's
    index space, look up the matching B face by sorted-vertex-set, and
    compare cyclic order. If A's index sequence appears reversed (rather
    than rotated) in B, that face's winding is flipped.

    Centroid-nearest matching is unreliable when faces are close together
    (e.g. tight bevel rings), so we lean on the position-based vertex
    mapping that diff.py has already computed."""
    b_lookup = {}
    for bi, f in enumerate(B['faces']):
        b_lookup.setdefault(tuple(sorted(f)), []).append((bi, f))

    flipped = []
    for ai, af in enumerate(A['faces']):
        b_indices = [matches_ab[v][0] for v in af]
        if len(set(b_indices)) != len(b_indices):
            continue  # ambiguous — multiple A verts mapped to same B vert
        key = tuple(sorted(b_indices))
        if key not in b_lookup:
            continue  # topology divergence — vertex-count diff already caught it

        for bi, bf in b_lookup[key]:
            try:
                start = bf.index(b_indices[0])
            except ValueError:
                continue
            n = len(bf)
            fwd = all(bf[(start + i) % n] == b_indices[i] for i in range(n))
            rev = all(bf[(start - i) % n] == b_indices[i] for i in range(n))
            if rev and not fwd:
                ca = face_centroid(af, A['vertices'])
                flipped.append((ai, bi, ca))
            break
    return flipped

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("candidate")
    ap.add_argument("--tolerance", type=float, default=0.01,
                    help="max acceptable per-vertex distance (default 0.01)")
    ap.add_argument("--case", help="case.json — read tolerance from there")
    args = ap.parse_args()

    with open(args.reference) as f: A = json.load(f)
    with open(args.candidate) as f: B = json.load(f)
    tol = args.tolerance
    if args.case:
        with open(args.case) as f:
            tol = json.load(f).get("tolerance", tol)

    print(f"  {A.get('source','reference'):8s}: {A['vertexCount']:3d} verts, "
          f"{A['faceCount']:3d} faces, fv-dist {fvdist(A['faces'])}")
    print(f"  {B.get('source','candidate'):8s}: {B['vertexCount']:3d} verts, "
          f"{B['faceCount']:3d} faces, fv-dist {fvdist(B['faces'])}")

    matches_ab = nearest_match(A['vertices'], B['vertices'])
    matches_ba = nearest_match(B['vertices'], A['vertices'])

    exact_ab = sum(1 for _, d in matches_ab if d < 1e-4)
    close_ab = sum(1 for _, d in matches_ab if 1e-4 <= d < tol)
    fail_ab  = sum(1 for _, d in matches_ab if d >= tol)
    mean_ab  = sum(d for _, d in matches_ab) / len(matches_ab)
    worst_ab = max(d for _, d in matches_ab)

    print(f"\n  A→B: {exact_ab} exact, {close_ab} close (<{tol}), "
          f"{fail_ab} fail; mean {mean_ab:.6f}, worst {worst_ab:.6f}")

    if fail_ab > 0:
        print(f"\n  Worst {min(5, fail_ab)} mismatches:")
        worst = sorted(enumerate(matches_ab), key=lambda t: -t[1][1])[:5]
        for ai, (bi, d) in worst:
            if d < tol: continue
            av = A['vertices'][ai]; bv = B['vertices'][bi]
            print(f"    A[{ai:2d}]=({av[0]:+.4f},{av[1]:+.4f},{av[2]:+.4f}) → "
                  f"B[{bi:2d}]=({bv[0]:+.4f},{bv[1]:+.4f},{bv[2]:+.4f})  d={d:.5f}")

    fail_ba = sum(1 for _, d in matches_ba if d >= tol)
    if fail_ba > 0:
        worst_ba = max(d for _, d in matches_ba)
        print(f"\n  B→A: {fail_ba} fail (worst {worst_ba:.6f})")

    same_topo = (A['vertexCount'] == B['vertexCount']
                 and A['faceCount'] == B['faceCount']
                 and fvdist(A['faces']) == fvdist(B['faces']))

    flipped = check_winding(A, B, matches_ab) if same_topo else []
    if flipped:
        print(f"\n  Winding: {len(flipped)} face(s) with reversed vertex order")
        for ai, bi, c in flipped[:5]:
            print(f"    A face {ai} ↔ B face {bi}  centroid=({c[0]:+.3f},"
                  f"{c[1]:+.3f},{c[2]:+.3f})")

    ok = (fail_ab == 0 and fail_ba == 0 and same_topo and not flipped)
    print(f"\n  RESULT: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
