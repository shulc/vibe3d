#!/usr/bin/env python3
"""End-to-end drag test: synthesize SDL mouse events, replay them via
`/api/play-events`, and verify the resulting mesh transformation.

Unlike `check_vibe3d_parity.py` (which probes pipeline state), this
script drives the ACTUAL tool through synthetic SDL events — same code
path the user hits when dragging a gizmo. Catches regressions that
live BELOW the pipeline output: arrow-handle picking, screen→world
delta projection, per-cluster delta application.

Phase 1 scope: a single proof-of-concept case. cube + top face select
+ ACEN.Select + Move tool + drag the Y arrow → verify all 4 top verts
moved by the same +Y world delta.

Requires vibe3d running with `--test` (event playback is gated by
test mode). Default port 8080.
"""
import argparse
import json
import math
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path


# ---- ANSI ------------------------------------------------------------
def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"


# ---- HTTP ------------------------------------------------------------
def post(url, body):
    if isinstance(body, str):
        data = body.encode(); ctype = "text/plain"
    else:
        data = json.dumps(body).encode(); ctype = "application/json"
    req = urllib.request.Request(url, method="POST", data=data,
                                 headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()


def get(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read())


# ---- math: lookAt + perspective + project (mirrors view.d / math.d) --
def normalize(v):
    n = math.sqrt(sum(c*c for c in v))
    return [c / n for c in v] if n > 0 else v


def cross(a, b):
    return [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]]


def look_at(eye, target, up):
    """Right-handed lookAt — column-major 4x4 (vibe3d's convention)."""
    f = normalize([target[i] - eye[i] for i in range(3)])
    s = normalize(cross(f, up))
    u = cross(s, f)
    M = [0.0]*16
    M[0]  =  s[0]; M[4]  =  s[1]; M[8]  =  s[2];  M[12] = -sum(s[i]*eye[i] for i in range(3))
    M[1]  =  u[0]; M[5]  =  u[1]; M[9]  =  u[2];  M[13] = -sum(u[i]*eye[i] for i in range(3))
    M[2]  = -f[0]; M[6]  = -f[1]; M[10] = -f[2];  M[14] =  sum(f[i]*eye[i] for i in range(3))
    M[3]  = 0;     M[7]  = 0;     M[11] = 0;      M[15] = 1
    return M


def perspective(fov_y_rad, aspect, near, far):
    """Right-handed perspective — matches math.d::perspectiveMatrix."""
    f = 1.0 / math.tan(fov_y_rad * 0.5)
    M = [0.0]*16
    M[0]  = f / aspect
    M[5]  = f
    M[10] = (far + near) / (near - far)
    M[11] = -1
    M[14] = (2 * far * near) / (near - far)
    return M


def mat_mul_vec4(M, v):
    """Column-major matrix-vector multiply."""
    out = [0.0]*4
    for r in range(4):
        out[r] = sum(M[r + c*4] * v[c] for c in range(4))
    return out


def project(world_pt, view_M, proj_M, vp_w, vp_h):
    """world → screen (vp_x, vp_y) in pixels, with Y flipped."""
    v = [world_pt[0], world_pt[1], world_pt[2], 1.0]
    eye = mat_mul_vec4(view_M, v)
    clip = mat_mul_vec4(proj_M, eye)
    if abs(clip[3]) < 1e-9:
        return None
    ndc = [clip[i] / clip[3] for i in range(3)]
    sx = (ndc[0] * 0.5 + 0.5) * vp_w
    sy = (1.0 - (ndc[1] * 0.5 + 0.5)) * vp_h
    return (sx, sy, ndc[2])


def spherical_to_cartesian(az, el, dist):
    """Mirrors view.d::sphericalToCartesian. az/el in radians."""
    return [dist * math.cos(el) * math.sin(az),
            dist * math.sin(el),
            dist * math.cos(el) * math.cos(az)]


def camera_matrices(cam):
    """Reconstruct view+proj from /api/camera response."""
    eye    = [cam["eye"]["x"], cam["eye"]["y"], cam["eye"]["z"]]
    focus  = [cam["focus"]["x"], cam["focus"]["y"], cam["focus"]["z"]]
    width  = cam["width"]
    height = cam["height"]
    view_M = look_at(eye, focus, [0, 1, 0])
    proj_M = perspective(45 * math.pi / 180, width / height, 0.001, 100)
    return view_M, proj_M, width, height


# ---- event log builder -----------------------------------------------
def build_drag_log(vp_w, vp_h, x0, y0, x1, y1, steps=10):
    """Construct a JSON Lines event log for a single LMB drag from
    (x0, y0) to (x1, y1). Includes a VIEWPORT meta line so EventPlayer
    doesn't remap pixels."""
    lines = []
    lines.append(json.dumps({
        "t": 0.0, "type": "VIEWPORT",
        "vpX": 0, "vpY": 0, "vpW": vp_w, "vpH": vp_h,
        "fovY": 0.785398
    }))
    lines.append(json.dumps({
        "t": 10.0, "type": "SDL_MOUSEBUTTONDOWN",
        "btn": 1, "x": int(x0), "y": int(y0), "clicks": 1, "mod": 0
    }))
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i / steps
        y = y0 + (y1 - y0) * i / steps
        lines.append(json.dumps({
            "t": 10.0 + i * 5.0, "type": "SDL_MOUSEMOTION",
            "x": int(x), "y": int(y),
            "xrel": int((x1 - x0) / steps),
            "yrel": int((y1 - y0) / steps),
            "state": 1, "mod": 0
        }))
    lines.append(json.dumps({
        "t": 10.0 + (steps + 1) * 5.0, "type": "SDL_MOUSEBUTTONUP",
        "btn": 1, "x": int(x1), "y": int(y1), "clicks": 1, "mod": 0
    }))
    return "\n".join(lines)


def wait_playback_done(base, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = get(f"{base}/api/play-events/status")
        if s.get("finished"):
            return True
        time.sleep(0.05)
    return False


# ---- one test case ---------------------------------------------------
def test_move_top_face(base):
    # 1) Reset to cube, switch to polygon mode and select top face (idx 4).
    post(f"{base}/api/reset?type=cube", "")
    post(f"{base}/api/select", {"mode": "polygons", "indices": [4]})
    post(f"{base}/api/command", "actr.select")
    post(f"{base}/api/command", "tool.set move")

    # 2) Compute screen coord of the Y arrow tip — gizmo at (0, 0.5, 0),
    #    Y arrow extends ~0.5 world units along +Y.
    cam = get(f"{base}/api/camera")
    view_M, proj_M, vw, vh = camera_matrices(cam)
    eval_state = get(f"{base}/api/toolpipe/eval")
    cen = eval_state["actionCenter"]["center"]
    up  = eval_state["axis"]["up"]
    arrow_len = 0.5
    tip_world  = [cen[i] + up[i] * arrow_len for i in range(3)]
    tip_screen = project(tip_world, view_M, proj_M, vw, vh)
    cen_screen = project(cen,       view_M, proj_M, vw, vh)
    if tip_screen is None or cen_screen is None:
        return "FAIL", "could not project Y arrow"

    # Start drag on the arrow shaft (mid-point between center and tip).
    sx = (cen_screen[0] + tip_screen[0]) * 0.5
    sy = (cen_screen[1] + tip_screen[1]) * 0.5

    # 3) Compute end screen pos: arrow tip moved 0.4 world units further
    #    along +Y. Drag delta on screen = end_screen - start_screen.
    far_world  = [cen[i] + up[i] * (arrow_len + 0.8) for i in range(3)]
    far_screen = project(far_world, view_M, proj_M, vw, vh)
    if far_screen is None:
        return "FAIL", "could not project end position"
    ex = sx + (far_screen[0] - tip_screen[0])
    ey = sy + (far_screen[1] - tip_screen[1])

    # Capture pre-drag verts.
    pre = get(f"{base}/api/model")["vertices"]
    pre = [tuple(v) for v in pre]

    # 4) Build + post the event log.
    log = build_drag_log(vw, vh, sx, sy, ex, ey, steps=20)
    post(f"{base}/api/play-events", log)
    if not wait_playback_done(base):
        return "FAIL", "playback did not finish"

    # 5) Read post-drag verts.
    post_verts = get(f"{base}/api/model")["vertices"]
    post_verts = [tuple(v) for v in post_verts]

    # 6) Verify: the four top-face verts (originally y=+0.5) should ALL
    #    move by the same Y-only delta (up axis = world +Y); the four
    #    bottom verts (y=-0.5) stay put.
    def near(a, b, tol=1e-3):
        return all(abs(a[i] - b[i]) < tol for i in range(3))

    deltas = []
    untouched_ok = True
    for i, p in enumerate(pre):
        post_v = post_verts[i]
        d = tuple(post_v[k] - p[k] for k in range(3))
        if p[1] > 0.0:    # top vert
            deltas.append(d)
        elif d[0]**2 + d[1]**2 + d[2]**2 > 1e-6:
            untouched_ok = False

    if not deltas:
        return "FAIL", "no top verts found"
    d0 = deltas[0]
    rigid = all(near(d, d0) for d in deltas)
    if not (rigid and untouched_ok):
        return "FAIL", (f"non-rigid or bottom moved; deltas={deltas}, "
                        f"untouched_ok={untouched_ok}")
    # Direction sanity: the world delta must be roughly along +Y.
    dy_norm = d0[1] / math.sqrt(sum(c*c for c in d0))
    if abs(dy_norm) < 0.9:
        return "FAIL", (f"delta direction off Y: {d0} "
                        f"(|dy|={abs(dy_norm):.3f})")
    return "PASS", (f"delta=({d0[0]:+.3f},{d0[1]:+.3f},{d0[2]:+.3f}) "
                    f"on 4 top verts; bottom unchanged")


# Asymmetric pattern: 3 polys on a 2x2x2 cube. Top cluster has 6
# unique verts at y=+0.5 (two adjacent faces); bottom cluster has 4
# unique verts at y=-0.5 (one face). Mirrors PATTERN_POLYS in
# check_vibe3d_parity.py and modo_drag_setup.py.
ASYM_POLY_VSETS = [
    frozenset([(-0.5, 0.5, -0.5), (0.0, 0.5, -0.5),
               (0.0, 0.5,  0.0), (-0.5, 0.5,  0.0)]),
    frozenset([(-0.5, 0.5,  0.0), (0.0, 0.5,  0.0),
               (0.0, 0.5,  0.5), (-0.5, 0.5,  0.5)]),
    frozenset([( 0.0, -0.5,  0.0), (0.5, -0.5,  0.0),
               (0.5, -0.5,  0.5), (0.0, -0.5,  0.5)]),
]


def find_asymmetric_face_indices(model):
    verts = [tuple(v) for v in model["vertices"]]
    faces = model.get("polygons") or model.get("faces") or []
    out = []
    for fi, f in enumerate(faces):
        vset = frozenset(
            (round(verts[i][0], 4), round(verts[i][1], 4),
             round(verts[i][2], 4)) for i in f)
        if vset in ASYM_POLY_VSETS:
            out.append(fi)
    return out


def test_move_asymmetric_local_x_arrow(base):
    """ACEN.Local + asymmetric selection + Move tool + drag X arrow.

    Per-cluster `right` differs in WORLD direction here:
      bottom cluster (face y=-0.5, X-Z extents tied 0.5×0.5): right=+X
      top    cluster (faces y=+0.5, X-Z extents 0.5×1.0):     right=+Z
    Same screen drag on the global X arrow → top cluster shifts along
    +Z world (its `right`), bottom along +X world. Validates that
    MoveTool.applyPerClusterDelta actually consumes per-cluster axes
    from AxisStage. For Y-arrow the test would be useless: cluster
    `up` differs only in sign (+Y vs -Y), which screenAxisDelta
    cancels out (same line ⇒ same world delta)."""
    # 1) Setup: empty → 2x2x2 cube → select 3 polys → actr.local → move.
    post(f"{base}/api/reset?empty=true", "")
    post(f"{base}/api/command",
         "prim.cube segmentsX:2 segmentsY:2 segmentsZ:2 "
         "sizeX:1 sizeY:1 sizeZ:1 sharp:true radius:0")
    model = get(f"{base}/api/model")
    indices = find_asymmetric_face_indices(model)
    if len(indices) != 3:
        return "FAIL", f"expected 3 polys, found {len(indices)}"
    post(f"{base}/api/select", {"mode": "polygons", "indices": indices})
    post(f"{base}/api/command", "actr.local")
    post(f"{base}/api/command", "tool.set move")

    # 2) Drag the GLOBAL X arrow. Gizmo basis = state.axis.right (world
    #    +X by default for asymmetric_local). Per-cluster `right` differs
    #    per cluster (top=+Z, bottom=+X) — the per-cluster path picks
    #    each cluster's own value independently of the global axis.
    cam = get(f"{base}/api/camera")
    view_M, proj_M, vw, vh = camera_matrices(cam)
    eval_state = get(f"{base}/api/toolpipe/eval")
    cen   = eval_state["actionCenter"]["center"]
    right = eval_state["axis"]["right"]
    arrow_len = 0.5
    tip_world  = [cen[i] + right[i] * arrow_len for i in range(3)]
    tip_screen = project(tip_world, view_M, proj_M, vw, vh)
    cen_screen = project(cen,       view_M, proj_M, vw, vh)
    far_world  = [cen[i] + right[i] * (arrow_len + 0.8) for i in range(3)]
    far_screen = project(far_world, view_M, proj_M, vw, vh)
    if not (tip_screen and cen_screen and far_screen):
        return "FAIL", "could not project X arrow"
    sx = (cen_screen[0] + tip_screen[0]) * 0.5
    sy = (cen_screen[1] + tip_screen[1]) * 0.5
    ex = sx + (far_screen[0] - tip_screen[0])
    ey = sy + (far_screen[1] - tip_screen[1])

    pre = [tuple(v) for v in model["vertices"]]

    # 3) Replay drag.
    log = build_drag_log(vw, vh, sx, sy, ex, ey, steps=20)
    post(f"{base}/api/play-events", log)
    if not wait_playback_done(base):
        return "FAIL", "playback did not finish"
    post_verts = [tuple(v) for v in get(f"{base}/api/model")["vertices"]]

    # 4) Group verts by cluster — top has y=+0.5, bottom has y=-0.5,
    #    interior verts (y=0) belong to whichever cluster claimed them
    #    via union-find. Selected verts have the y values above.
    sel_top    = [(i, p) for i, p in enumerate(pre)
                  if p[1] > 0.4 and p[1] < 0.6 and
                     p[0] >= -0.51 and p[0] <= 0.01 and
                     p[2] >= -0.51 and p[2] <= 0.51]
    sel_bottom = [(i, p) for i, p in enumerate(pre)
                  if p[1] < -0.4 and p[1] > -0.6 and
                     p[0] >= -0.01 and p[0] <= 0.51 and
                     p[2] >= -0.01 and p[2] <= 0.51]
    if len(sel_top) != 6 or len(sel_bottom) != 4:
        return "FAIL", (f"selection mismatch: top={len(sel_top)} "
                        f"bottom={len(sel_bottom)}")

    def cluster_delta(rows, label):
        deltas = [tuple(post_verts[i][k] - p[k] for k in range(3))
                  for i, p in rows]
        d0 = deltas[0]
        rigid = all(all(abs(d[k] - d0[k]) < 1e-3 for k in range(3))
                    for d in deltas)
        return d0, rigid

    d_top, rigid_top       = cluster_delta(sel_top,    "top")
    d_bottom, rigid_bottom = cluster_delta(sel_bottom, "bottom")
    if not (rigid_top and rigid_bottom):
        return "FAIL", "non-rigid per-cluster"

    # 5) Untouched verts: every non-selected vert must stay put.
    sel_ids = set(i for i, _ in sel_top) | set(i for i, _ in sel_bottom)
    untouched_ok = True
    for i, p in enumerate(pre):
        if i in sel_ids: continue
        if any(abs(post_verts[i][k] - p[k]) > 1e-3 for k in range(3)):
            untouched_ok = False; break

    # 6) Direction sanity: top cluster moves along +Z (its `right`),
    #    bottom moves along +X (its `right`). Same-axis Y-arrow drag
    #    would just give parallel +Y moves — useless for distinguishing
    #    per-cluster from global. Z and X are world-orthogonal here.
    top_dir_ok    = abs(d_top[2])    > 0.05 and abs(d_top[0])    < 0.02
    bottom_dir_ok = abs(d_bottom[0]) > 0.05 and abs(d_bottom[2]) < 0.02

    summary = (f"top=({d_top[0]:+.3f},{d_top[1]:+.3f},{d_top[2]:+.3f}) "
               f"bottom=({d_bottom[0]:+.3f},{d_bottom[1]:+.3f},"
               f"{d_bottom[2]:+.3f})")
    if not untouched_ok:
        return "FAIL", "untouched verts moved; " + summary
    if not (top_dir_ok and bottom_dir_ok):
        return "FAIL", "per-cluster direction wrong; " + summary
    return "PASS", "per-cluster axes verified — " + summary


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
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    if not wait_ready(args.port):
        print(red(f"vibe3d not responding on :{args.port}"))
        return 2

    base = f"http://localhost:{args.port}"
    cases = [
        ("move_top_y_arrow",            test_move_top_face),
        ("move_asymmetric_local_x",     test_move_asymmetric_local_x_arrow),
    ]
    fail = 0
    for name, fn in cases:
        status, msg = fn(base)
        tag = green if status == "PASS" else red
        print(f"  {tag(status):20s} {name:30s} {msg}")
        if status != "PASS": fail += 1
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
