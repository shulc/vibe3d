#!/usr/bin/env python3
"""Cross-check vibe3d's pipeline-evaluated center against MODO's
predicted pivot for each `drag_cases/*.json` case.

For each case:
  1. Build the same primitive in vibe3d (cube segments=1 / cube
     segments=2 / sphere segments=1) to match MODO's setup.
  2. Locate the polygons whose vertex positions match the case's
     pattern (single_top / asymmetric / sphere_top), select them.
  3. Activate the case's `actr.<mode>` preset.
  4. Read `/api/toolpipe/eval` — vibe3d's published center.
  5. Compare to the same predicted pivot the MODO-side verifier
     (`verify_acen_drag.py`) checks. Same prediction ⇒ same MODO
     pivot ⇒ vibe3d ≡ MODO.

Skipped cases: `auto` (drag-position-dependent pivot, not modelled).

Usage:
  ./check_vibe3d_parity.py                      # iterate every case
  ./check_vibe3d_parity.py 'rotate_*'           # glob filter
  ./check_vibe3d_parity.py --port 8080

Requires vibe3d running with HTTP enabled (default port 8080).
"""
import argparse
import fnmatch
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CASES_DIR  = SCRIPT_DIR / "drag_cases"
TOL        = 0.05    # same TOL the MODO verifier uses

# ---- ANSI ------------------------------------------------------------
def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"


# ---- HTTP ------------------------------------------------------------
def post(url, body):
    """`body` is dict (JSON) or str (argstring) or None (no body)."""
    if body is None:
        data = b""; ctype = "application/json"
    elif isinstance(body, str):
        data = body.encode(); ctype = "text/plain"
    else:
        data = json.dumps(body).encode(); ctype = "application/json"
    req = urllib.request.Request(url, method="POST", data=data,
                                 headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read())


# ---- pattern selection -----------------------------------------------
# vert-sets identifying the polygons each pattern selects, mirrors
# `modo_drag_setup.py` PATTERNS table.
def _v(*pts):
    return frozenset((round(p[0], 4), round(p[1], 4), round(p[2], 4))
                     for p in pts)


PATTERN_POLYS = {
    "single_top": [
        _v((-0.5, 0.5, -0.5), (0.5, 0.5, -0.5),
           (0.5, 0.5,  0.5), (-0.5, 0.5,  0.5)),
    ],
    "asymmetric": [
        _v((-0.5, 0.5, -0.5), (0.0, 0.5, -0.5),
           (0.0, 0.5,  0.0), (-0.5, 0.5,  0.0)),
        _v((-0.5, 0.5,  0.0), (0.0, 0.5,  0.0),
           (0.0, 0.5,  0.5), (-0.5, 0.5,  0.5)),
        _v(( 0.0, -0.5,  0.0), (0.5, -0.5,  0.0),
           (0.5, -0.5,  0.5), (0.0, -0.5,  0.5)),
    ],
    # sphere_top: every poly with centroid Y > 0 (a runtime predicate;
    # we evaluate against the live mesh data below).
    "sphere_top": "centroidY>0",
}


def setup_primitive(base, pattern):
    """Reset + build the right primitive in vibe3d for `pattern`."""
    # Empty reset first so subsequent prim.* tools don't append.
    post(f"{base}/api/reset?empty=true", None)
    if pattern == "single_top":
        # Default cube via /api/reset is segments=1; restart with cube
        # primitive (faster than running prim.cube tool).
        post(f"{base}/api/reset?type=cube", None)
    elif pattern == "asymmetric":
        # 2x2x2 cube with sharp corners (matches MODO prim.cube
        # segmentsX/Y/Z=2 default). sharp=false would round corners.
        post(f"{base}/api/command",
             "prim.cube segmentsX:2 segmentsY:2 segmentsZ:2 "
             "sizeX:1 sizeY:1 sizeZ:1 sharp:true radius:0")
    elif pattern == "sphere_top":
        # MODO default sphere has radius 0.5 and 32 segments. vibe3d's
        # SphereTool has its own params — map to closest equivalent.
        post(f"{base}/api/command", "prim.sphere")
    else:
        raise ValueError(f"unknown pattern {pattern}")


def find_face_indices(model, pattern):
    """Map vibe3d's faces to indices that match `pattern`."""
    verts = [tuple(v) for v in model["vertices"]]
    faces = model.get("polygons") or model.get("faces") or []
    indices = []
    if pattern == "sphere_top":
        for fi, f in enumerate(faces):
            ys = [verts[i][1] for i in f]
            if sum(ys) / max(1, len(ys)) > 0.001:
                indices.append(fi)
        return indices
    targets = PATTERN_POLYS[pattern]
    for fi, f in enumerate(faces):
        vset = frozenset(
            (round(verts[i][0], 4), round(verts[i][1], 4),
             round(verts[i][2], 4)) for i in f)
        if vset in targets:
            indices.append(fi)
    return indices


# ---- selection structures --------------------------------------------
def union_find_clusters(face_vsets):
    """Cluster polygons that share an edge (== two consecutive verts).
    Mirrors `modo_drag_setup.py` clustering. Returns list of vert-sets,
    one per cluster."""
    n = len(face_vsets)
    polys = [list(vs) for vs in face_vsets]   # ordered for edge walk
    parent = list(range(n))
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    def share_edge(a, b):
        sa = polys[a]; sb = polys[b]
        for i in range(len(sa)):
            ea = (sa[i], sa[(i+1) % len(sa)])
            for j in range(len(sb)):
                eb = (sb[j], sb[(j+1) % len(sb)])
                if (ea == eb) or (ea[0] == eb[1] and ea[1] == eb[0]):
                    return True
        return False
    for i in range(n):
        for j in range(i + 1, n):
            if share_edge(i, j):
                a, b = find(i), find(j)
                if a != b: parent[a] = b
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    clusters = []
    for members in groups.values():
        verts = set()
        for k in members: verts.update(polys[k])
        clusters.append(sorted(verts))
    return clusters


def border_verts_of(model, sel_face_indices):
    """Verts on edges with exactly one selected adjacent face. Mirrors
    `modo_drag_setup.py`."""
    verts = [tuple(v) for v in model["vertices"]]
    faces = model.get("polygons") or model.get("faces") or []
    sel = set(sel_face_indices)
    edge_sel_count = {}
    for fi, f in enumerate(faces):
        if fi not in sel: continue
        for i in range(len(f)):
            a = tuple(round(c, 4) for c in verts[f[i]])
            b = tuple(round(c, 4) for c in verts[f[(i+1) % len(f)]])
            e = (a, b) if a < b else (b, a)
            edge_sel_count[e] = edge_sel_count.get(e, 0) + 1
    edge_total_count = {}
    for fi, f in enumerate(faces):
        for i in range(len(f)):
            a = tuple(round(c, 4) for c in verts[f[i]])
            b = tuple(round(c, 4) for c in verts[f[(i+1) % len(f)]])
            e = (a, b) if a < b else (b, a)
            edge_total_count[e] = edge_total_count.get(e, 0) + 1
    out = set()
    for e, sel_n in edge_sel_count.items():
        tot = edge_total_count[e]
        if sel_n == 1 and tot - sel_n >= 1:
            out.add(e[0]); out.add(e[1])
    return sorted(out)


def selected_unique_verts(model, sel_face_indices):
    verts = [tuple(v) for v in model["vertices"]]
    faces = model.get("polygons") or model.get("faces") or []
    s = set()
    for fi in sel_face_indices:
        for vi in faces[fi]:
            s.add(tuple(round(c, 4) for c in verts[vi]))
    return sorted(s)


# ---- pivot prediction (mirrors verify_acen_drag.py predict_pivot) ----
def bbox_center(verts):
    if not verts:
        return (0.0, 0.0, 0.0)
    mn = [min(v[i] for v in verts) for i in range(3)]
    mx = [max(v[i] for v in verts) for i in range(3)]
    return tuple((mn[i] + mx[i]) / 2 for i in range(3))


def avg(verts):
    n = len(verts)
    return tuple(sum(v[i] for v in verts) / n for i in range(3))


def predict_pivots(mode, sel, clusters, border):
    """Returns list of acceptable pivots, or None for drag-dependent."""
    if mode in ("select", "selectauto"):
        return [bbox_center(sel)]
    if mode == "border":
        return [bbox_center(border)] if border else [bbox_center(sel)]
    if mode == "local":
        # vibe3d publishes per-cluster centers; the API also publishes
        # the FIRST cluster's centroid as `center` for backward compat.
        return [avg(c) for c in clusters] + [bbox_center(sel)]
    if mode == "origin":
        return [(0.0, 0.0, 0.0)]
    if mode == "auto":
        return None
    return None


def near(a, b, tol=TOL):
    return all(abs(a[i] - b[i]) < tol for i in range(3))


# ---- per-case run ----------------------------------------------------
def run_case(path, port):
    spec = json.loads(path.read_text())
    pattern   = spec["pattern"]
    acen_mode = spec["acen_mode"]
    base = f"http://localhost:{port}"

    setup_primitive(base, pattern)

    model = get(f"{base}/api/model")
    sel_face_indices = find_face_indices(model, pattern)
    if not sel_face_indices:
        return "FAIL", f"no faces matched pattern '{pattern}'"

    sel    = selected_unique_verts(model, sel_face_indices)
    border = border_verts_of(model, sel_face_indices)

    # Cluster reconstruction needs the actual vert positions per face
    # (in face order) — match modo_drag_setup.py.
    verts_world = [tuple(v) for v in model["vertices"]]
    faces       = model.get("polygons") or model.get("faces") or []
    face_vsets  = [
        [tuple(round(c, 4) for c in verts_world[vi])
         for vi in faces[fi]]
        for fi in sel_face_indices]
    clusters = union_find_clusters(face_vsets)

    # Select polys + activate preset.
    post(f"{base}/api/select", {"mode": "polygons",
                                "indices": sel_face_indices})
    post(f"{base}/api/command", f"actr.{acen_mode}")

    eval_state = get(f"{base}/api/toolpipe/eval")
    vibe_center = tuple(eval_state["actionCenter"]["center"])
    vibe_clusters_n     = len(eval_state["actionCenter"]["clusterCenters"])
    vibe_axes_clusters  = len(eval_state["axis"]["clusterRight"])

    pred = predict_pivots(acen_mode, sel, clusters, border)
    if pred is None:
        return "SKIP", f"{acen_mode} pivot is drag-position-dependent"

    # Cluster-count invariant for ACEN.Local with multi-cluster
    # selection: vibe3d must publish per-cluster pivots AND per-cluster
    # axes (both with the same cluster count). Phase 4 of
    # acen_modo_parity_plan.md — Move/Scale/Rotate consume both.
    if acen_mode == "local" and len(clusters) >= 2:
        if vibe_clusters_n != len(clusters):
            return "FAIL", (
                f"local: expected {len(clusters)} clusterCenters, got "
                f"{vibe_clusters_n}")
        if vibe_axes_clusters != len(clusters):
            return "FAIL", (
                f"local: expected {len(clusters)} clusterRight, got "
                f"{vibe_axes_clusters}")

    if any(near(vibe_center, p) for p in pred):
        labels = ", ".join(
            f"({p[0]:+.3f},{p[1]:+.3f},{p[2]:+.3f})" for p in pred)
        extra = ""
        if acen_mode == "local" and len(clusters) >= 2:
            extra = f"  [{vibe_clusters_n}c/axes]"
        return "PASS", (
            f"vibe3d=({vibe_center[0]:+.3f},{vibe_center[1]:+.3f},"
            f"{vibe_center[2]:+.3f}) ≈ MODO pred={labels}{extra}")
    labels = ", ".join(
        f"({p[0]:+.3f},{p[1]:+.3f},{p[2]:+.3f})" for p in pred)
    return "FAIL", (
        f"vibe3d=({vibe_center[0]:+.3f},{vibe_center[1]:+.3f},"
        f"{vibe_center[2]:+.3f}) != MODO pred={labels}")


# ---- main ------------------------------------------------------------
def discover_cases(filters):
    cases = sorted(CASES_DIR.glob("*.json"))
    if not filters:
        return cases
    keep = []
    for c in cases:
        if any(fnmatch.fnmatch(c.stem, pat) for pat in filters):
            keep.append(c)
    return keep


def wait_ready(port, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(f"http://localhost:{port}/api/model",
                                   timeout=1).read()
            return True
        except (urllib.error.URLError, ConnectionResetError, OSError):
            time.sleep(0.2)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("filters", nargs="*")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    if not wait_ready(args.port):
        print(red(f"vibe3d not responding on :{args.port} (start it with "
                  "`./vibe3d --test`)"))
        return 2

    cases = discover_cases(args.filters)
    if not cases:
        print(red("no cases match filter"))
        return 2

    passed, failed, skipped = [], [], []
    for c in cases:
        try:
            status, msg = run_case(c, args.port)
        except Exception as e:
            status, msg = "FAIL", repr(e)
        tag = {"PASS": green, "FAIL": red, "SKIP": blue}[status]
        print(f"  {tag(status):20s} {c.stem:40s} {msg}")
        {"PASS": passed, "FAIL": failed, "SKIP": skipped}[status].append(c.stem)

    print()
    print(f"{len(passed)} pass, {len(failed)} fail, {len(skipped)} skip "
          f"(of {len(cases)})")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
