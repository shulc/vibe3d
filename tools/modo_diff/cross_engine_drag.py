#!/usr/bin/env python3
"""Cross-engine numerical parity: drive vibe3d through the SAME drag
MODO ran (same camera, same screen pixels), compare resulting meshes
per-vertex.

This is the only way to validate ACEN.Auto numerically — actr.auto's
pivot is drag-position-dependent and can't be cleanly recovered from
mesh deltas alone (xfrm.scale on a flat face conflates pivot recovery
with drag direction in `decompose()`). Driving both engines through
the identical input bypasses that.

Pipeline per case:
  1. Run MODO via run_acen_drag.py's Worker — produces state.json
     (camera + selection + before-verts) and result.json (after-verts).
  2. Convert MODO camera → vibe3d (azimuth/elevation/distance/focus).
  3. POST /api/camera, reset+select+actr+tool.set in vibe3d.
  4. Synthesise the same drag through /api/play-events.
  5. GET /api/model; compare to MODO's after-verts vertex by vertex.

Usage:
  ./vibe3d --test --viewport 1426x966 &       # vibe3d running on 8080
                                              # with viewport pinned to MODO's
                                              # actual viewport size (1426x966
                                              # in our default test setup) so
                                              # the projection aspect matches.
  ./cross_engine_drag.py                      # all cases
  ./cross_engine_drag.py 'move_single_top_auto'

The --viewport pin is independent of the SDL window size — even when
window-manager chrome (titlebar, side panel, status bar) eats pixels,
the camera's projection matrix uses the explicitly-pinned dimensions.

Requires: a vibe3d --test instance running, MODO+Xvfb available.
"""
import argparse
import fnmatch
import importlib.util
import json
import math
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CASES_DIR  = SCRIPT_DIR / "drag_cases"
TOL        = 0.10   # per-vertex tolerance in world units


def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"


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


def wait_playback(base, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = get(f"{base}/api/play-events/status")
        if s.get("finished"):
            return True
        time.sleep(0.05)
    return False


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


# ---- handle pick math --------------------------------------------------
def _normalize(v):
    n = math.sqrt(sum(c*c for c in v))
    return tuple(c/n for c in v) if n > 1e-9 else v


def _cross(a, b):
    return (a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0])


def _dot(a, b):
    return sum(a[i]*b[i] for i in range(3))


def handle_click_offset(cam, handle):
    """Pixel offset (dx, dy) from gizmo screen-center to a click point
    that lands inside `handle`'s hitbox. `cam` is MODO's camera dict
    from state.json (eye, fwd, pixel_size, etc.). Handle ∈
    {"x","y","z","center"}. The offset uses 30 px along the handle's
    world-axis projection, which is comfortably inside both engines'
    arrow hitboxes regardless of which gizmo length each engine uses
    (vibe3d 0.18 fraction ≈ 95 px arrow at our test camera, MODO ≈ 90
    px — both safely larger than 30 px)."""
    if handle == "center":
        return (0.0, 0.0)
    fwd = cam["fwd"]
    cam_right = _normalize(_cross(fwd, (0.0, 1.0, 0.0)))
    cam_up    = _normalize(_cross(cam_right, fwd))
    axis = {"x": (1.0, 0.0, 0.0),
            "y": (0.0, 1.0, 0.0),
            "z": (0.0, 0.0, 1.0)}[handle]
    # Projection of world axis onto screen-pixel basis. Screen Y is
    # inverted (down=positive) hence the unary minus on cam_up.
    sx =  _dot(cam_right, axis)
    sy = -_dot(cam_up,    axis)
    mag = math.sqrt(sx*sx + sy*sy)
    if mag < 1e-3:
        # Axis is nearly along view direction — no meaningful screen
        # projection. Use a default (+30, 0) to at least be off-center.
        return (30.0, 0.0)
    return (30.0 * sx / mag, 30.0 * sy / mag)


def screen_center_from_state(cam):
    """Approximate screen-center pixel of the gizmo. Without a full
    projection matrix here we approximate by the centre of the
    viewport bounds — fine for our cases where ACEN.center ≈ camera
    focus and the gizmo lands near the screen centre."""
    bx, by, bw, bh = cam["bounds"]
    return (bx + bw * 0.5, by + bh * 0.5)


# ---- camera conversion: MODO → vibe3d spherical ----------------------
def modo_to_vibe3d_camera(cam):
    """MODO publishes (focus, eye, distance). vibe3d wants az/el/dist
    around focus. sphericalToCartesian (math.d:199):
      offset = (d*cos(el)*sin(az), d*sin(el), d*cos(el)*cos(az))
    so reverse: el = asin(off.y/d), az = atan2(off.x, off.z)."""
    fx, fy, fz = cam["center"]
    ex, ey, ez = cam["eye"]
    off = (ex - fx, ey - fy, ez - fz)
    d = math.sqrt(sum(c*c for c in off))
    if d < 1e-9:
        return None
    el = math.asin(max(-1, min(1, off[1] / d)))
    az = math.atan2(off[0], off[2])
    return {"azimuth": az, "elevation": el, "distance": d,
            "focus": {"x": fx, "y": fy, "z": fz},
            "width":  cam["bounds"][2],
            "height": cam["bounds"][3]}


# ---- selection helpers (mirror check_vibe3d_parity.py) ---------------
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
    "sphere_top": "centroidY>0",
}


def setup_primitive(base, pattern):
    post(f"{base}/api/reset?empty=true", "")
    if pattern == "single_top":
        post(f"{base}/api/reset?type=cube", "")
    elif pattern == "asymmetric":
        post(f"{base}/api/command",
             "prim.cube segmentsX:2 segmentsY:2 segmentsZ:2 "
             "sizeX:1 sizeY:1 sizeZ:1 sharp:true radius:0")
    elif pattern == "sphere_top":
        # Pin sides+segments to MODO defaults (24/12 = 266 verts) so
        # mesh-vert-count matches between engines for cross-engine
        # comparison. vibe3d's default is 24/24 (554 verts).
        post(f"{base}/api/command",
             "prim.sphere sides:24 segments:12")
    else:
        raise ValueError(f"unknown pattern {pattern}")


def find_face_indices(model, pattern):
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


# ---- event log builder -----------------------------------------------
def build_drag_log(vp_x, vp_y, vp_w, vp_h, x0, y0, x1, y1, steps=20):
    """Synthesise a drag's SDL events. Motion events are spaced 50ms
    apart so each lands in its own frame — SDL coalesces consecutive
    motion events queued in the same frame, so close timestamps result
    in only the LAST motion reaching the tool."""
    lines = []
    lines.append(json.dumps({
        "t": 0.0, "type": "VIEWPORT",
        "vpX": vp_x, "vpY": vp_y, "vpW": vp_w, "vpH": vp_h,
        "fovY": 0.785398
    }))
    t_down = 50.0
    lines.append(json.dumps({
        "t": t_down, "type": "SDL_MOUSEBUTTONDOWN",
        "btn": 1, "x": int(x0), "y": int(y0), "clicks": 1, "mod": 0
    }))
    step_ms = 50.0
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i / steps
        y = y0 + (y1 - y0) * i / steps
        lines.append(json.dumps({
            "t": t_down + i * step_ms, "type": "SDL_MOUSEMOTION",
            "x": int(x), "y": int(y),
            "xrel": int((x1 - x0) / steps),
            "yrel": int((y1 - y0) / steps),
            "state": 1, "mod": 0
        }))
    lines.append(json.dumps({
        "t": t_down + (steps + 1) * step_ms, "type": "SDL_MOUSEBUTTONUP",
        "btn": 1, "x": int(x1), "y": int(y1), "clicks": 1, "mod": 0
    }))
    return "\n".join(lines)


# ---- comparison -----------------------------------------------------
def pair_and_compare(modo_verts, vibe_verts, tol=TOL):
    """Hungarian-like nearest-pair matching, then return max distance.
    No external scipy dep — for 8-145 verts, brute-force is fine."""
    if len(modo_verts) != len(vibe_verts):
        return False, (f"vert count mismatch: modo={len(modo_verts)} "
                       f"vibe3d={len(vibe_verts)}"), None
    n = len(modo_verts)
    used = set()
    pairs = []
    max_dist = 0.0
    for m in modo_verts:
        best_j, best_d = None, float("inf")
        for j, v in enumerate(vibe_verts):
            if j in used: continue
            d2 = sum((m[k] - v[k])**2 for k in range(3))
            if d2 < best_d:
                best_d, best_j = d2, j
        if best_j is None:
            return False, "pairing failed", None
        used.add(best_j); pairs.append((m, vibe_verts[best_j]))
        d = math.sqrt(best_d)
        if d > max_dist: max_dist = d
    ok = max_dist < tol
    return ok, f"max_dist={max_dist:.4f}", pairs


# ---- per-case orchestration -----------------------------------------
def run_case(case_path, worker, base, args_step_px=None):
    spec = json.loads(case_path.read_text())
    pattern   = spec["pattern"]
    acen_mode = spec["acen_mode"]
    tool      = spec["tool"]
    handle    = spec.get("handle")        # x|y|z|center, optional
    step_px   = args_step_px if args_step_px is not None \
                else spec.get("step_px", 20)
    # When `handle` is set, the actual drag pixels are computed inside
    # run_acen_drag.Worker.run_case (after MODO's camera state is
    # available) and persisted to state.json's `resolved_drag`. We pull
    # them back from state.json after MODO has run, then drive vibe3d
    # with the SAME pixel coords so cross-engine numerics line up.
    if handle is None:
        drag = spec.get("drag", [1020, 560, 100, 0])
    else:
        drag = None  # patched after MODO returns

    # 1) Run MODO via the orchestrator Worker — produces state+result.
    status, why = worker.run_case(case_path, step_px_override=args_step_px)
    if status != "PASS":
        return "ERROR", f"MODO did not PASS ({status}: {why})"

    # 2) Read MODO state/result from worker's tmpdir.
    state  = json.loads((worker.tmpdir / "modo_drag_state.json").read_text())
    result = json.loads((worker.tmpdir / "modo_drag_result.json").read_text())
    cam_modo = state.get("camera")
    if not cam_modo or "error" in cam_modo:
        return "ERROR", "no camera in MODO state.json"
    modo_post = [tuple(v) for v in result["verts"]]

    # When the case is handle-driven, run_acen_drag.Worker.run_case
    # resolved the actual click pixels against MODO's camera and
    # persisted them under state["resolved_drag"]. Pull them back so
    # we drive vibe3d through the SAME pixels MODO saw.
    if drag is None:
        rd = state.get("resolved_drag")
        if rd is None:
            return "ERROR", "handle-driven case missing resolved_drag in state"
        drag = [float(rd[0]), float(rd[1]), float(rd[2]), float(rd[3])]
    x0, y0, dx, dy = drag

    # 3) Build same scene + selection + ACEN + tool, THEN set camera.
    #    /api/reset resets the View; setting the camera last keeps our
    #    MODO-aligned camera in place for the drag.
    setup_primitive(base, pattern)
    model = get(f"{base}/api/model")
    indices = find_face_indices(model, pattern)
    if not indices:
        return "FAIL", f"no faces matched {pattern}"
    post(f"{base}/api/select", {"mode": "polygons", "indices": indices})
    post(f"{base}/api/command", f"actr.{acen_mode}")
    if tool == "rotate":
        # MODO uses TransformRotate (xfrm.transform with R-only); vibe3d
        # has plain `rotate` tool that does the equivalent.
        post(f"{base}/api/command", "tool.set rotate")
    elif tool == "scale":
        post(f"{base}/api/command", "tool.set scale")
    else:  # move
        post(f"{base}/api/command", "tool.set move")

    # 4) Set vibe3d's camera to MODO's (after reset, before drag).
    cam_vibe = modo_to_vibe3d_camera(cam_modo)
    if cam_vibe is None:
        return "ERROR", "could not convert camera"
    post(f"{base}/api/camera", cam_vibe)

    # 5) Replay the drag. vibe3d's actual SDL window may be smaller than
    #    MODO's (650x544 vs 1426x966 in our default test setup). We can't
    #    resize the SDL window from the test, so we PROJECT MODO's drag
    #    pixels into vibe3d's viewport proportionally. Send VIEWPORT meta
    #    matching vibe3d's actual viewport to suppress EventPlayer's
    #    auto-remap (which would do the same thing but using its own
    #    convention).
    bx, by, bw, bh = cam_modo["bounds"]
    cam_vibe_now = get(f"{base}/api/camera")
    vw = cam_vibe_now["width"]
    vh = cam_vibe_now["height"]
    def remap(x, y):
        return ((x - bx) * vw / float(bw),
                (y - by) * vh / float(bh))
    sx, sy = remap(x0,         y0)
    ex, ey = remap(x0 + dx,    y0 + dy)
    # Use the same per-event step granularity vibe3d-side as MODO-side.
    # MODO's mouse_drag computed N = max(|dx|,|dy|) // step_px or 1.
    # Mirror that here so both engines see the same number of motion
    # events. Important for testing the cumulative-impulse hypothesis.
    n_events = max(abs(dx), abs(dy)) // step_px or 1
    log = build_drag_log(0, 0, vw, vh, sx, sy, ex, ey, steps=n_events)
    post(f"{base}/api/play-events", log)
    if not wait_playback(base):
        return "FAIL", "vibe3d playback didn't finish"

    # 6) Compare meshes.
    vibe_post = [tuple(v) for v in get(f"{base}/api/model")["vertices"]]
    ok, msg, pairs = pair_and_compare(modo_post, vibe_post)
    if not ok and pairs:
        # Diagnostic: print up to 4 worst-mismatched pairs.
        sortable = []
        for m, v in pairs:
            d = math.sqrt(sum((m[i] - v[i])**2 for i in range(3)))
            sortable.append((d, m, v))
        sortable.sort(reverse=True)
        diag_lines = []
        for d, m, v in sortable[:4]:
            diag_lines.append(
                f"      modo=({m[0]:+.3f},{m[1]:+.3f},{m[2]:+.3f}) "
                f"vibe=({v[0]:+.3f},{v[1]:+.3f},{v[2]:+.3f}) d={d:.3f}")
        msg = msg + "\n" + "\n".join(diag_lines)
    return ("PASS" if ok else "FAIL"), msg


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


def _spawn_vibe3d(port):
    """Launch a vibe3d --test subprocess pinned to viewport 1426x966
    on the given HTTP port. Returns the Popen handle."""
    import subprocess as sp
    sp.run(["pkill", "-9", "-f", f"vibe3d --test --http-port {port}"],
           stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    time.sleep(0.3)
    v_log = open(f"/tmp/cross_engine_vibe3d_{port}.log", "w")
    proc = sp.Popen(
        ["./vibe3d", "--test", "--viewport", "1426x966",
         "--http-port", str(port)],
        cwd=str(SCRIPT_DIR.parent.parent),
        stdout=v_log, stderr=sp.STDOUT,
        start_new_session=True)
    return proc


def _run_case_safely(case_path, worker, base, step_px):
    """Single-case wrapper used by both serial and parallel main."""
    try:
        return run_case(case_path, worker, base, args_step_px=step_px)
    except Exception as e:
        return "FAIL", repr(e)


def main():
    import subprocess as sp
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("filters", nargs="*",
                    help="case filename stems / globs; default = run all")
    ap.add_argument("--port", type=int, default=8080,
                    help="base HTTP port for vibe3d. Worker N gets "
                         "port = base + N.")
    ap.add_argument("-j", type=int, default=1,
                    help="parallel workers — each gets its own Xvfb "
                         "(:99+i), MODO instance, and vibe3d subprocess "
                         "on port (--port + i). Defaults to 1 (serial).")
    ap.add_argument("--keep", action="store_true",
                    help="leave Xvfb/MODO/vibe3d running after")
    ap.add_argument("--step-px", type=int, default=None,
                    help="override per-event xrel step (default: per-case "
                         "spec, fallback 20). Set to a large value to force "
                         "single-event drag (N=1) — useful for isolating "
                         "MODO's quadratic-by-N drag accumulation effect.")
    ap.add_argument("--launch-vibe3d", action="store_true",
                    help="spawn vibe3d as a subprocess for the duration "
                         "of the test. Required for -j > 1 (each worker "
                         "needs its own port). For -j 1 you can also "
                         "start `./vibe3d --test --viewport 1426x966` "
                         "yourself first.")
    args = ap.parse_args()

    if args.j > 1 and not args.launch_vibe3d:
        print(red("-j > 1 requires --launch-vibe3d (each worker needs "
                  "its own vibe3d on a unique port)"))
        return 2

    return _main_serial(args) if args.j <= 1 else _main_parallel(args)


def _main_serial(args):
    """Single-worker path — preserves the previous CLI semantics."""
    import subprocess as sp
    vibe_proc = None
    if args.launch_vibe3d:
        vibe_proc = _spawn_vibe3d(args.port)
        print(blue(f"=== launched vibe3d pid={vibe_proc.pid} on :{args.port} ==="))
        time.sleep(0.5)

    try:
        if not wait_ready(args.port, timeout=20):
            print(red(f"vibe3d not running on :{args.port} "
                      f"(start it with `./vibe3d --test --viewport 1426x966`)"))
            if vibe_proc: vibe_proc.kill()
            return 2

        cases = discover_cases(args.filters)
        if not cases:
            print(red("no cases match")); return 2

        base = f"http://localhost:{args.port}"

        spec = importlib.util.spec_from_file_location(
            'rad', str(SCRIPT_DIR / "run_acen_drag.py"))
        rad = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rad)
        rad.cleanup_all_displays()
        rad.copy_scripts()
        w = rad.Worker(0)
        try:
            w.boot()
            passed, failed = [], []
            for c in cases:
                status, msg = _run_case_safely(
                    c, w, base, args.step_px)
                tag = green if status == "PASS" else red
                print(f"  {tag(status):20s} {c.stem:40s} {msg}")
                (passed if status == "PASS" else failed).append(c.stem)
            print()
            print(f"{len(passed)} pass, {len(failed)} fail "
                  f"(of {len(cases)})")
            return 0 if not failed else 1
        finally:
            if not args.keep:
                try: w.shutdown()
                except Exception: pass
    finally:
        if vibe_proc and not args.keep:
            try: vibe_proc.kill(); vibe_proc.wait(timeout=2)
            except Exception: pass


def _main_parallel(args):
    """Multi-worker path: N MODO Workers + N vibe3d subprocesses, each
    pair on a disjoint Xvfb display + HTTP port. Cases are pulled from
    a shared queue."""
    import concurrent.futures
    import queue
    import threading

    cases = discover_cases(args.filters)
    if not cases:
        print(red("no cases match")); return 2

    spec = importlib.util.spec_from_file_location(
        'rad', str(SCRIPT_DIR / "run_acen_drag.py"))
    rad = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rad)
    rad.cleanup_all_displays()
    rad.copy_scripts()

    j = args.j
    workers     = [rad.Worker(i) for i in range(j)]
    vibe_procs  = [_spawn_vibe3d(args.port + i) for i in range(j)]
    bases       = [f"http://localhost:{args.port + i}" for i in range(j)]
    print(blue(f"=== launched {j} vibe3d (ports "
               f"{args.port}..{args.port + j - 1}) ==="))

    # Boot Xvfb + MODO + vibe3d in parallel — single-worker boot is ~3s,
    # serial = 3s × N. Parallel keeps overall boot near single-worker.
    with concurrent.futures.ThreadPoolExecutor(max_workers=j) as ex:
        list(ex.map(lambda w: w.boot(), workers))
        for i, b in enumerate(bases):
            if not wait_ready(args.port + i, timeout=30):
                print(red(f"vibe3d on :{args.port + i} did not come up"))
                # Best-effort cleanup
                for vp in vibe_procs:
                    try: vp.kill()
                    except Exception: pass
                for w in workers:
                    try: w.shutdown()
                    except Exception: pass
                return 2

    q = queue.Queue()
    for c in cases: q.put(c)
    sentinel = object()
    for _ in range(j): q.put(sentinel)

    results = []
    results_lock = threading.Lock()

    def loop(worker_id):
        w    = workers[worker_id]
        base = bases[worker_id]
        while True:
            item = q.get()
            if item is sentinel: return
            status, msg = _run_case_safely(item, w, base, args.step_px)
            with results_lock:
                results.append((item.stem, status, msg))

    threads = [threading.Thread(target=loop, args=(i,)) for i in range(j)]
    for t in threads: t.start()
    for t in threads: t.join()

    if not args.keep:
        with concurrent.futures.ThreadPoolExecutor(max_workers=j) as ex:
            list(ex.map(lambda w: w.shutdown(), workers))
        for vp in vibe_procs:
            try: vp.kill(); vp.wait(timeout=2)
            except Exception: pass

    # Deterministic summary — workers finish in arbitrary order.
    results.sort(key=lambda r: r[0])
    passed, failed = [], []
    for name, status, msg in results:
        tag = green if status == "PASS" else red
        print(f"  {tag(status):20s} {name:40s} {msg}")
        (passed if status == "PASS" else failed).append(name)
    print()
    print(f"{len(passed)} pass, {len(failed)} fail (of {len(results)})")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
