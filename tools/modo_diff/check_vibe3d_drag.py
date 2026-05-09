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


def test_scale_asymmetric_local_x_arrow(base):
    """ACEN.Local + asymmetric + Scale + drag X arrow.

    Top cluster scales along its `right` axis (+Z) → top's Z bbox
    extent changes from 1.0; X stays 0.5. Bottom cluster scales along
    its `right` (+X) → bottom's X changes from 0.5; Z stays 0.5."""
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
    post(f"{base}/api/command", "tool.set scale")

    cam = get(f"{base}/api/camera")
    view_M, proj_M, vw, vh = camera_matrices(cam)
    eval_state = get(f"{base}/api/toolpipe/eval")
    cen   = eval_state["actionCenter"]["center"]
    right = eval_state["axis"]["right"]
    arrow_len = 0.5
    tip_world  = [cen[i] + right[i] * arrow_len for i in range(3)]
    tip_screen = project(tip_world, view_M, proj_M, vw, vh)
    cen_screen = project(cen,       view_M, proj_M, vw, vh)
    far_world  = [cen[i] + right[i] * (arrow_len + 0.4) for i in range(3)]
    far_screen = project(far_world, view_M, proj_M, vw, vh)
    if not (tip_screen and cen_screen and far_screen):
        return "FAIL", "could not project X arrow"
    sx = (cen_screen[0] + tip_screen[0]) * 0.5
    sy = (cen_screen[1] + tip_screen[1]) * 0.5
    ex = sx + (far_screen[0] - tip_screen[0])
    ey = sy + (far_screen[1] - tip_screen[1])

    pre = [tuple(v) for v in model["vertices"]]
    log = build_drag_log(vw, vh, sx, sy, ex, ey, steps=20)
    post(f"{base}/api/play-events", log)
    if not wait_playback_done(base):
        return "FAIL", "playback did not finish"
    post_verts = [tuple(v) for v in get(f"{base}/api/model")["vertices"]]

    # Cluster verts (same lookup as the move test).
    sel_top    = [i for i, p in enumerate(pre)
                  if p[1] > 0.4 and p[1] < 0.6 and
                     -0.51 <= p[0] <= 0.01 and -0.51 <= p[2] <= 0.51]
    sel_bottom = [i for i, p in enumerate(pre)
                  if p[1] < -0.4 and p[1] > -0.6 and
                     -0.01 <= p[0] <= 0.51 and -0.01 <= p[2] <= 0.51]
    if len(sel_top) != 6 or len(sel_bottom) != 4:
        return "FAIL", "selection mismatch"

    def bbox_extents(rows):
        mn = [min(rows[k][i] for k in range(len(rows))) for i in range(3)]
        mx = [max(rows[k][i] for k in range(len(rows))) for i in range(3)]
        return [mx[i] - mn[i] for i in range(3)]

    pre_top_ext  = bbox_extents([pre[i] for i in sel_top])
    post_top_ext = bbox_extents([post_verts[i] for i in sel_top])
    pre_bot_ext  = bbox_extents([pre[i] for i in sel_bottom])
    post_bot_ext = bbox_extents([post_verts[i] for i in sel_bottom])

    # Top cluster scales along Z; X (and Y, untouched on Y arrow) stay.
    top_z_changed = abs(post_top_ext[2] - pre_top_ext[2]) > 0.05
    top_x_kept    = abs(post_top_ext[0] - pre_top_ext[0]) < 0.02
    # Bottom cluster scales along X; Z stays.
    bot_x_changed = abs(post_bot_ext[0] - pre_bot_ext[0]) > 0.05
    bot_z_kept    = abs(post_bot_ext[2] - pre_bot_ext[2]) < 0.02

    summary = (f"top Δext=({post_top_ext[0]-pre_top_ext[0]:+.2f},"
               f"{post_top_ext[1]-pre_top_ext[1]:+.2f},"
               f"{post_top_ext[2]-pre_top_ext[2]:+.2f}) "
               f"bot Δext=({post_bot_ext[0]-pre_bot_ext[0]:+.2f},"
               f"{post_bot_ext[1]-pre_bot_ext[1]:+.2f},"
               f"{post_bot_ext[2]-pre_bot_ext[2]:+.2f})")
    if not (top_z_changed and top_x_kept):
        return "FAIL", "top didn't scale on Z; " + summary
    if not (bot_x_changed and bot_z_kept):
        return "FAIL", "bottom didn't scale on X; " + summary
    return "PASS", "per-cluster axes verified — " + summary


def test_rotate_asymmetric_local_x_ring(base):
    """ACEN.Local + asymmetric + Rotate + drag X ring.

    Each cluster rotates around its `right` axis. Verify per-cluster:
      - all verts' distance to cluster pivot is preserved (rigid);
      - all verts' component along the cluster's `right` axis (relative
        to pivot) is preserved (so rotation is purely around `right`)."""
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
    post(f"{base}/api/command", "tool.set rotate")

    cam = get(f"{base}/api/camera")
    view_M, proj_M, vw, vh = camera_matrices(cam)
    eval_state = get(f"{base}/api/toolpipe/eval")
    cen   = eval_state["actionCenter"]["center"]
    up    = eval_state["axis"]["up"]
    fwd   = eval_state["axis"]["fwd"]
    cluster_centers = [tuple(c) for c in
                       eval_state["actionCenter"]["clusterCenters"]]
    cluster_right = [tuple(v) for v in eval_state["axis"]["clusterRight"]]
    # X arc lies in the plane perpendicular to right (= YZ plane). A
    # point on the arc at angle PI/2: cen + up * radius. The radius is
    # computed dynamically (gizmoSize in handler.d) — reproduce here:
    # radius = 2 * px * depth / (proj[5] * vp.height), where depth is
    # the view-space Z of the gizmo center and px is the target pixel
    # length of the gizmo arm (90 px default, matches MODO).
    g_gizmo_pixels = 90.0
    cen_view = mat_mul_vec4(view_M, [cen[0], cen[1], cen[2], 1.0])
    depth = max(1e-4, -cen_view[2])
    radius = 2.0 * g_gizmo_pixels * depth / (proj_M[5] * vh)
    pt_on_arc_world = [cen[i] + up[i] * radius for i in range(3)]
    drag_end_world  = [cen[i] + up[i] * radius * 0.7
                              + fwd[i] * radius * 0.7 for i in range(3)]
    pt_screen  = project(pt_on_arc_world, view_M, proj_M, vw, vh)
    end_screen = project(drag_end_world,   view_M, proj_M, vw, vh)
    if not (pt_screen and end_screen):
        return "FAIL", "could not project arc point"
    sx, sy = pt_screen[0], pt_screen[1]
    ex, ey = end_screen[0], end_screen[1]

    pre = [tuple(v) for v in model["vertices"]]
    log = build_drag_log(vw, vh, sx, sy, ex, ey, steps=30)
    post(f"{base}/api/play-events", log)
    if not wait_playback_done(base):
        return "FAIL", "playback did not finish"
    post_verts = [tuple(v) for v in get(f"{base}/api/model")["vertices"]]

    sel_top    = [i for i, p in enumerate(pre)
                  if p[1] > 0.4 and p[1] < 0.6 and
                     -0.51 <= p[0] <= 0.01 and -0.51 <= p[2] <= 0.51]
    sel_bottom = [i for i, p in enumerate(pre)
                  if p[1] < -0.4 and p[1] > -0.6 and
                     -0.01 <= p[0] <= 0.51 and -0.01 <= p[2] <= 0.51]

    # Identify which vibe3d cluster index corresponds to top vs bottom
    # by pivot proximity.
    def nearest_cluster(target_y):
        best = None; best_d = float("inf")
        for ci, c in enumerate(cluster_centers):
            d = abs(c[1] - target_y)
            if d < best_d: best_d, best = d, ci
        return best
    top_cid    = nearest_cluster(+0.5)
    bottom_cid = nearest_cluster(-0.5)
    top_pivot    = cluster_centers[top_cid]
    top_axis     = cluster_right[top_cid]
    bottom_pivot = cluster_centers[bottom_cid]
    bottom_axis  = cluster_right[bottom_cid]

    def check_cluster(rows, pivot, axis):
        any_moved = False
        for i in rows:
            d_pre  = tuple(pre[i][k]       - pivot[k] for k in range(3))
            d_post = tuple(post_verts[i][k] - pivot[k] for k in range(3))
            len_pre  = math.sqrt(sum(c*c for c in d_pre))
            len_post = math.sqrt(sum(c*c for c in d_post))
            # Distance to pivot preserved (rigid).
            if abs(len_pre - len_post) > 0.02:
                return False, f"vert {i} dist {len_pre:.3f}→{len_post:.3f}"
            # Component along axis preserved (rotation around axis only).
            ax_pre  = sum(d_pre[k]  * axis[k] for k in range(3))
            ax_post = sum(d_post[k] * axis[k] for k in range(3))
            if abs(ax_pre - ax_post) > 0.02:
                return False, (f"vert {i} ax-component "
                               f"{ax_pre:.3f}→{ax_post:.3f}")
            if any(abs(post_verts[i][k] - pre[i][k]) > 1e-3 for k in range(3)):
                any_moved = True
        if not any_moved:
            return False, "no rotation observed"
        return True, "rigid rotation around cluster axis"

    ok_top, msg_top       = check_cluster(sel_top,    top_pivot,    top_axis)
    ok_bottom, msg_bottom = check_cluster(sel_bottom, bottom_pivot, bottom_axis)
    if not ok_top:
        return "FAIL", "top: " + msg_top
    if not ok_bottom:
        return "FAIL", "bottom: " + msg_bottom
    return "PASS", "per-cluster rotation axis verified"


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
        ("scale_asymmetric_local_x",    test_scale_asymmetric_local_x_arrow),
        ("rotate_asymmetric_local_x",   test_rotate_asymmetric_local_x_ring),
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
