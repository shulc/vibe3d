#!/usr/bin/env python3
"""Take side-by-side screenshots of vibe3d and MODO with the SAME camera
and selection for each transform tool (move/rotate/scale), so we can
visually measure gizmo arrow/handle pixel sizes.

In both engines the keyboard shortcuts W (move), E (rotate), R (scale)
activate the corresponding tool — the script uses xdotool key events.

Output:
  /tmp/gizmo_vibe3d_move.png   /tmp/gizmo_modo_move.png
  /tmp/gizmo_vibe3d_rotate.png /tmp/gizmo_modo_rotate.png
  /tmp/gizmo_vibe3d_scale.png  /tmp/gizmo_modo_scale.png
"""
import importlib.util
import json
import math
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent.parent

VIBE_DISPLAY = ":100"
VIBE_PORT    = 8101
VP_W, VP_H   = 1426, 966

TOOLS = ("move", "rotate", "scale")
TOOL_KEY = {"move": "w", "rotate": "e", "scale": "r"}


def post(port, path, body=""):
    if isinstance(body, str):
        data = body.encode(); ctype = "text/plain"
    else:
        data = json.dumps(body).encode(); ctype = "application/json"
    req = urllib.request.Request(f"http://localhost:{port}{path}",
                                 method="POST", data=data,
                                 headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()


def get(port, path):
    with urllib.request.urlopen(f"http://localhost:{port}{path}",
                                timeout=10) as r:
        return json.loads(r.read())


def wait_http(port, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(f"http://localhost:{port}/api/model",
                                   timeout=1).read()
            return True
        except Exception:
            time.sleep(0.3)
    return False


def cleanup_x(display):
    n = display.lstrip(":")
    for f in [f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"]:
        try: os.remove(f)
        except OSError: pass


def shoot_vibe3d():
    """Boot Xvfb + vibe3d, set scene, screenshot move/rotate/scale.
    Returns the camera state (eye, focus, az, el, dist)."""
    cleanup_x(VIBE_DISPLAY)
    print(f"=== Xvfb {VIBE_DISPLAY} ===")
    xvfb = subprocess.Popen(
        ["Xvfb", VIBE_DISPLAY, "-screen", "0", "1920x1080x24",
         "-nolisten", "tcp"],
        stdout=open("/tmp/gizmo_xvfb_vibe.log", "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True)
    time.sleep(1)

    env = os.environ.copy()
    env["DISPLAY"] = VIBE_DISPLAY

    print("=== launching vibe3d ===")
    venv = env.copy()
    venv["LIBGL_ALWAYS_SOFTWARE"] = "1"
    venv["SDL_VIDEODRIVER"] = "x11"
    vproc = subprocess.Popen(
        ["./vibe3d", "--test",
         "--viewport", f"{VP_W}x{VP_H}",
         "--http-port", str(VIBE_PORT)],
        cwd=str(ROOT),
        env=venv,
        stdout=open("/tmp/gizmo_vibe3d.log", "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True)
    if not wait_http(VIBE_PORT, timeout=30):
        vproc.kill(); xvfb.kill()
        raise RuntimeError("vibe3d didn't come up on Xvfb")
    print("  vibe3d up")

    try:
        post(VIBE_PORT, "/api/reset?type=cube")
        model = get(VIBE_PORT, "/api/model")
        verts = model["vertices"]
        faces = model.get("polygons") or model.get("faces") or []
        top_idx = None
        for fi, f in enumerate(faces):
            if all(verts[i][1] > 0.4 for i in f):
                top_idx = fi; break
        if top_idx is None:
            raise RuntimeError("no top face found in cube")
        post(VIBE_PORT, "/api/select",
             {"mode": "polygons", "indices": [top_idx]})
        post(VIBE_PORT, "/api/command", "actr.auto")

        eye = (-1.92, 3.30, 11.97)
        focus = (0.0, 0.5, 0.0)
        off = (eye[0]-focus[0], eye[1]-focus[1], eye[2]-focus[2])
        d = math.sqrt(sum(c*c for c in off))
        el = math.asin(off[1] / d)
        az = math.atan2(off[0], off[2])
        post(VIBE_PORT, "/api/camera", {
            "azimuth": az, "elevation": el, "distance": d,
            "focus": {"x": focus[0], "y": focus[1], "z": focus[2]},
            "width": VP_W, "height": VP_H,
        })
        time.sleep(1)

        wlist = subprocess.run(["xdotool", "search", "--pid", str(vproc.pid)],
                               env=env, capture_output=True, text=True)
        wid = wlist.stdout.strip().split("\n")[0] if wlist.stdout.strip() else None
        print(f"  vibe3d window id: {wid or 'NONE'}")

        for tool in TOOLS:
            post(VIBE_PORT, "/api/command", f"tool.set {tool}")
            time.sleep(1.5)
            out = f"/tmp/gizmo_vibe3d_{tool}.png"
            target = wid if wid else "root"
            subprocess.run(["import", "-window", target, out], env=env)
            print(f"  {tool}: → {out} ({os.path.getsize(out)}b)")

        return {"eye": eye, "focus": focus, "az": az, "el": el, "dist": d}
    finally:
        try: vproc.kill(); vproc.wait(timeout=2)
        except Exception: pass
        try: xvfb.kill()
        except Exception: pass


def shoot_modo(cam):
    """Boot MODO + cube + selection + actr.auto. Then for each tool:
    press W/E/R to activate, hover over cube, screenshot."""
    spec = importlib.util.spec_from_file_location(
        'rad', str(SCRIPT_DIR / "run_acen_drag.py"))
    rad = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rad)
    rad.cleanup_all_displays()
    rad.copy_scripts()

    w = rad.Worker(0)
    try:
        w.boot()
        try: os.remove(w.state_path)
        except OSError: pass
        # modo_drag_setup.py creates cube + selects top + activates
        # actr.auto + xfrm.move. The keyboard shortcuts will switch
        # tools after.
        w.cmd_bar(
            f"@modo_drag_setup.py {w.tmpdir} auto single_top move 1020 560",
            wait_for=str(w.state_path), timeout=12)
        time.sleep(1)

        env = w.env()

        # Find MODO's main window so we can give it focus before keys.
        wlist = subprocess.run(["xdotool", "search", "--name", "modo"],
                               env=env, capture_output=True, text=True)
        modo_wid = wlist.stdout.strip().split("\n")[0] \
                   if wlist.stdout.strip() else None
        print(f"  MODO window id: {modo_wid or 'NONE'}")

        for tool in TOOLS:
            # Activate MODO main window + click on empty viewport area
            # to make sure key bindings target the viewport.
            if modo_wid:
                w.xdo("windowactivate", modo_wid); time.sleep(0.3)
            # Click in empty viewport space (top-right of cube area, away
            # from the polygon so we don't change selection).
            w.xdo("mousemove", "1300", "200"); time.sleep(0.2)
            w.xdo("click", "1"); time.sleep(0.3)
            # Now press the W/E/R shortcut.
            w.xdo("key", TOOL_KEY[tool].lower()); time.sleep(0.8)
            # Hover over cube to wake gizmo render.
            w.xdo("mousemove", "1020", "560"); time.sleep(0.3)
            w.xdo("mousemove", "1100", "560"); time.sleep(0.3)
            w.xdo("mousemove", "1020", "560"); time.sleep(0.5)
            out = f"/tmp/gizmo_modo_{tool}.png"
            w.screenshot(out)
            print(f"  {tool}: → {out} ({os.path.getsize(out)}b)")
            subprocess.run(
                ["convert", out, "-crop", "1100x800+500+150",
                 f"/tmp/gizmo_modo_{tool}_crop.png"],
                check=False)

        # Probe MODO's PixelSize for the FOV / drag-scale analysis.
        out_json = w.tmpdir / "cam_probe.json"
        probe = (
            "#python\n"
            "import lx, json\n"
            "_vp  = lx.service.View3Dport()\n"
            "_v3d = lx.object.View3D(_vp.View(_vp.Current()))\n"
            "ev   = list(_v3d.EyeVector())\n"
            "bnd  = list(_v3d.Bounds())\n"
            "px   = _v3d.PixelSize()\n"
            "d = {'pixel_size': float(px), "
            "     'bounds': [float(x) for x in bnd], "
            "     'distance': float(ev[0])}\n"
            f"open('{out_json}','w').write(json.dumps(d))\n"
        )
        sp = w.tmpdir / "probe_camera_fov.py"
        sp.write_text(probe)
        try: os.remove(out_json)
        except OSError: pass
        w.cmd_bar(f"@{sp}", wait_for=str(out_json), timeout=8)
        try:
            cam_data = json.loads(out_json.read_text())
            px = cam_data['pixel_size']
            d  = cam_data['distance']
            bnd = cam_data['bounds']
            print(f"  MODO PixelSize       = {px:.6f} world/px @ workplane")
            print(f"  MODO bounds          = {bnd}")
            print(f"  MODO distance        = {d:.4f}")
            world_h = px * bnd[3]
            fovY    = 2 * math.atan(world_h / (2 * d)) * 180.0 / math.pi
            print(f"  MODO equiv. FOV-Y    = {fovY:.2f} deg "
                  f"(vibe3d uses 45.00 deg)")
            vibe_px = 2 * math.tan(math.radians(22.5)) * d / bnd[3]
            print(f"  vibe3d expected px   = {vibe_px:.6f}")
            print(f"  ratio MODO / vibe3d  = {px/vibe_px:.4f}x")
        except Exception as e:
            print(f"  probe failed: {e}")
    finally:
        try: w.shutdown()
        except Exception: pass


def main():
    cam = shoot_vibe3d()
    print(f"camera: {cam}")
    shoot_modo(cam)
    print("done")


if __name__ == "__main__":
    sys.exit(main() or 0)
