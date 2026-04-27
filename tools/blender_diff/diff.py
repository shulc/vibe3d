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
    ok = (fail_ab == 0 and fail_ba == 0 and same_topo)
    print(f"\n  RESULT: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
