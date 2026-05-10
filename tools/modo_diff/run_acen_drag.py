#!/usr/bin/env python3
"""Cross-check vibe3d ACEN modes against MODO via real mouse-drag.

Architecture: launches Xvfb + matchbox + MODO ONCE per worker; iterates
the JSON cases under `drag_cases/` (mirrors `tools/modo_diff/cases/`'s
pattern for the modo_cl harness). Each case is one (tool, pattern,
acen_mode) combination plus optional overrides (drag start/direction,
etc.); default drag is +100 px right from (1020, 560) which lands on a
gizmo handle for both small sphere and larger cube primitives.

Usage:
  ./run_acen_drag.py                       # run every case in drag_cases/
  ./run_acen_drag.py scale_single_top_select  # one case (filename stem)
  ./run_acen_drag.py 'rotate_*'            # glob
  ./run_acen_drag.py --keep                # leave Xvfb/MODO running after
  ./run_acen_drag.py -j 4                  # 4 parallel MODO workers
                                           # (each on its own Xvfb display
                                           # and tmpdir)

Requires: Xvfb, matchbox-window-manager, xdotool, ImageMagick (`import`),
python3. Override via env: MODO_BIN, MODO_LD, MODO_CONTENT.

Per-case status:
  PASS — verifier returned 0
  FAIL — verifier returned non-zero
  ERROR — setup/dump didn't produce its JSON within the timeout
"""
import argparse
import concurrent.futures
import fnmatch
import json
import math
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

# ---- config -----------------------------------------------------------
MODO_BIN       = Path(os.environ.get(
    "MODO_BIN", "/home/ashagarov/Program/Modo902/modo"))
MODO_LD        = os.environ.get("MODO_LD", "/home/ashagarov/.local/lib")
MODO_CONTENT   = os.environ.get(
    "MODO_CONTENT", "/home/ashagarov/.luxology/Content")
SCRIPT_DIR     = Path(__file__).resolve().parent
CASES_DIR      = SCRIPT_DIR / "drag_cases"
USER_SCRIPTS   = Path.home() / ".luxology" / "Scripts"
SYSTEM_SCRIPTS = MODO_BIN.parent / "extra" / "Scripts"
LOG_DIR        = Path("/tmp")

# UI coords for matchbox-fullscreen MODO at 1920x1080. Same on every
# Xvfb display since each worker gets its own X server with identical
# screen geometry.
FILE_MENU_X,  FILE_MENU_Y  = 17,   10
RESET_ITEM_X, RESET_ITEM_Y = 40,   778
POPUP_OK_X,   POPUP_OK_Y   = 1175, 538
CMD_BAR_X,    CMD_BAR_Y    = 1750, 1063
DEFAULT_DRAG = (1020, 560, 100, 0)   # (start_x, start_y, dx, dy)


# ---- handle-pick screen math ----------------------------------------
def _normalize_v(v):
    n = math.sqrt(sum(c*c for c in v))
    return tuple(c/n for c in v) if n > 1e-9 else v


def _cross_v(a, b):
    return (a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0])


def _dot_v(a, b):
    return sum(a[i]*b[i] for i in range(3))


def _camera_basis(cam):
    """Returns (cam_right, cam_up, fwd) — orthonormal world-space basis
    of the MODO viewport camera. fwd is the view direction (eye→focus)."""
    fwd = cam["fwd"]
    cam_right = _normalize_v(_cross_v(fwd, (0.0, 1.0, 0.0)))
    cam_up    = _normalize_v(_cross_v(cam_right, fwd))
    return (cam_right, cam_up, fwd)


def _project_axis_to_screen(cam, axis):
    """World axis (unit vec) → unit (sx, sy) in screen-pixel space."""
    cam_right, cam_up, _ = _camera_basis(cam)
    sx =  _dot_v(cam_right, axis)
    sy = -_dot_v(cam_up,    axis)   # screen Y inverted
    mag = math.sqrt(sx*sx + sy*sy)
    if mag < 1e-3:
        return (1.0, 0.0)           # axis along view → fallback right
    return (sx / mag, sy / mag)


def _world_to_screen(cam, world_point):
    """Project a world-space point onto the viewport in pixels.
    Returns (sx, sy) in MODO viewport coordinates (top-left origin).

    Uses the camera basis (cam_right, cam_up, fwd) plus PixelSize() —
    PixelSize is world units per pixel @ the workplane (depth =
    `cam.distance` from eye); pixel size scales linearly with depth, so
    at the point's view-distance we use
    `pixel_size_at_point = pixel_size × (view_dist / workplane_depth)`.
    """
    cam_right, cam_up, fwd = _camera_basis(cam)
    eye = cam["eye"]
    bx, by, bw, bh = cam["bounds"]
    pixel_size_wp = cam["pixel_size"]
    workplane_dist = cam["distance"]

    view_vec = (world_point[0] - eye[0],
                world_point[1] - eye[1],
                world_point[2] - eye[2])
    view_right = _dot_v(view_vec, cam_right)
    view_up    = _dot_v(view_vec, cam_up)
    view_dist  = _dot_v(view_vec, fwd)
    if view_dist < 1e-3 or pixel_size_wp <= 0 or workplane_dist <= 0:
        return (bx + bw * 0.5, by + bh * 0.5)

    pixel_size_at_pt = pixel_size_wp * view_dist / workplane_dist
    px_offset_x = view_right / pixel_size_at_pt
    px_offset_y = -view_up   / pixel_size_at_pt
    return (bx + bw * 0.5 + px_offset_x,
            by + bh * 0.5 + px_offset_y)


def _selection_bbox_center(state):
    """Bounding-box center of the selected vertices recorded in
    state.json. Used as the gizmo's world-space center for handle-pick
    cases — close enough to MODO's ACEN.center across the modes we
    actually test (auto/select/selectauto/border/element/local all
    centre on or near the selection bbox; origin/none are different
    but for those the gizmo position doesn't matter for cross-engine
    parity since both engines also fall back to origin)."""
    sel = state.get("selected_verts") or []
    if not sel:
        return (0.0, 0.0, 0.0)
    mn = [min(v[i] for v in sel) for i in range(3)]
    mx = [max(v[i] for v in sel) for i in range(3)]
    return ((mn[0]+mx[0])*0.5, (mn[1]+mx[1])*0.5, (mn[2]+mx[2])*0.5)


def _resolve_handle_drag(state, handle, drag_len, detected=None):
    """For handle ∈ {x,y,z,center}, return (start_x, start_y, dx, dy)
    in MODO viewport pixels.

    `detected` (optional) is a {handle_name: (px, py)} dict produced
    by detect_handles.py — the precise on-screen handle pixel
    positions extracted from a viewport screenshot. When the requested
    handle is in `detected`, that pixel becomes the click point;
    otherwise we fall back to the analytical
    selection-bbox-center + axis-projection path (works but doesn't
    account for MODO's actual gizmo screen offset).

    Drag delta in either path follows the screen projection of the
    handle's natural drag axis (X arrow → world +X, etc.), so
    direction sign + magnitude line up cross-engine."""
    cam = state["camera"]
    if handle == "center":
        if detected and "center" in detected:
            cx, cy = detected["center"]
        else:
            cx, cy = _world_to_screen(cam, _selection_bbox_center(state))
        return (cx, cy, drag_len, 0)
    if handle not in ("x", "y", "z"):
        raise ValueError(f"unknown handle: {handle}")
    axis = {"x": (1.0, 0.0, 0.0),
            "y": (0.0, 1.0, 0.0),
            "z": (0.0, 0.0, 1.0)}[handle]
    sx, sy = _project_axis_to_screen(cam, axis)
    if detected and handle in detected:
        start_x, start_y = detected[handle]
    else:
        gx, gy = _world_to_screen(cam, _selection_bbox_center(state))
        start_x = gx + 30.0 * sx
        start_y = gy + 30.0 * sy
    return (start_x, start_y, drag_len * sx, drag_len * sy)


# ---- ANSI ------------------------------------------------------------
def red(s):    return f"\033[31m{s}\033[0m"
def yellow(s): return f"\033[33m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"

# Stdout serialization across worker threads — without it the per-case
# log messages from N workers interleave mid-line.
_print_lock = threading.Lock()
def safe_print(*a, **kw):
    with _print_lock:
        print(*a, **kw)


# ---- prereq check (single-process, no per-worker state) -------------
def check_prereqs():
    missing = [c for c in
               ("xdotool", "matchbox-window-manager", "Xvfb",
                "import", "python3")
               if shutil.which(c) is None]
    if missing:
        print(red(f"ERROR: missing on PATH: {', '.join(missing)}"))
        sys.exit(2)
    if not MODO_BIN.exists() or not os.access(MODO_BIN, os.X_OK):
        print(red(f"ERROR: {MODO_BIN} not executable"))
        sys.exit(2)
    for d in (USER_SCRIPTS, SYSTEM_SCRIPTS, CASES_DIR):
        if not d.is_dir():
            print(red(f"ERROR: {d} missing"))
            sys.exit(2)
    for f in ("modo_drag_setup.py", "modo_dump_verts.py",
              "modo_falloff_setup.py", "verify_acen_drag.py"):
        if not (SCRIPT_DIR / f).is_file():
            print(red(f"ERROR: missing {SCRIPT_DIR / f}"))
            sys.exit(2)


def copy_scripts():
    """Scripts are shared (same content for every worker); the worker
    distinguishes itself via the tmpdir argument it passes."""
    print(blue("=== copying MODO scripts ==="))
    for name in ("modo_drag_setup.py", "modo_dump_verts.py",
                 "modo_falloff_setup.py"):
        for dst in (USER_SCRIPTS, SYSTEM_SCRIPTS):
            shutil.copy(SCRIPT_DIR / name, dst / name)


# ---- Worker: one MODO instance on its own Xvfb display -------------
class Worker:
    """One MODO instance, isolated by Xvfb display + tmpdir.

    Workers do NOT share scripts directory (MODO uses a global one),
    but writes to /tmp are partitioned by `self.tmpdir`. Setup and
    dump scripts both accept tmpdir as their first argument.
    """

    def __init__(self, worker_id, visible=False):
        self.id      = worker_id
        # `visible` mode: skip Xvfb + matchbox and run MODO on the
        # caller's real X display. Useful for debugging — you can
        # SEE what MODO is doing while xdotool drives it. Forces
        # j=1 (multiple visible MODO instances would compete for
        # the same display + window manager and not produce
        # reproducible automation).
        self.visible = visible
        if visible:
            self.display = os.environ.get("DISPLAY", ":0")
        else:
            self.display = f":{99 + worker_id}"
        self.tmpdir  = Path(f"/tmp/modo_drag_worker_{worker_id}")
        self.tmpdir.mkdir(exist_ok=True)
        self.state_path  = self.tmpdir / "modo_drag_state.json"
        self.result_path = self.tmpdir / "modo_drag_result.json"
        self.modo_proc = None
        # Screen-coordinate offset of MODO's content area. Hardcoded
        # UI coords (CMD_BAR_X / FILE_MENU_X / etc.) are relative to
        # MODO's content origin which under matchbox-fullscreen is
        # (0, 0) but on a real WM is shifted by the titlebar height.
        # _ui_xy() applies this offset.
        self.win_x = 0
        self.win_y = 0

    # ----- shell helpers -----
    def env(self, extra=None):
        e = os.environ.copy()
        e["DISPLAY"] = self.display
        if extra: e.update(extra)
        return e

    def xdo(self, *args):
        subprocess.run(["xdotool", *args], env=self.env(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def screenshot(self, path):
        subprocess.run(["import", "-window", "root", str(path)],
                       env=self.env(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _annotate_handle_debug(self, click_x, click_y, detected, handle):
        """Save <tmpdir>/handles_debug.png — a copy of the detection
        screenshot with the planned click position marked by a red
        cross + each detected handle marked by a yellow dot. Helps
        the test author eyeball whether the click is going to land
        on the right gizmo handle without re-running the case."""
        src = self.tmpdir / "handles.png"
        if not src.exists():
            return
        try:
            import subprocess as sp
            args = ["convert", str(src),
                    "-strokewidth", "2",
                    "-stroke", "yellow", "-fill", "yellow"]
            for name, (x, y) in detected.items():
                args += ["-draw", f"circle {int(x)},{int(y)} {int(x)+5},{int(y)+5}"]
                args += ["-fill", "yellow", "-draw",
                         f"text {int(x)+8},{int(y)-2} '{name}'"]
            # Click target on top: red cross + handle name
            cx, cy = int(click_x), int(click_y)
            args += ["-stroke", "red", "-fill", "red"]
            args += ["-draw", f"line {cx-12},{cy} {cx+12},{cy}"]
            args += ["-draw", f"line {cx},{cy-12} {cx},{cy+12}"]
            args += ["-draw",
                     f"text {cx+14},{cy+5} 'click({handle})'"]
            args += [str(self.tmpdir / "handles_debug.png")]
            sp.run(args, capture_output=True)
        except Exception:
            pass

    def _detect_handles(self, state):
        """Take a viewport screenshot and run detect_handles.py on it
        to locate each colour-coded gizmo handle (X red, Y green, Z
        blue, center cyan) by their saturated pixel clusters.

        Each handle gets its own per-handle hint pointing at where
        that handle's SHAFT should be on screen — the arrows are
        small enough at our test camera that several other tiny
        red/green/blue blobs (the Y-ring, Z-circle, axis indicators)
        are nearby; without the per-handle hint the cyan detector
        picks the corner Z-indicator badge and the red detector
        picks the Y-axis red ring instead of the X arrow shaft.

        Returns {handle_name: (px, py)} in screen coords; missing
        handles are omitted. Returns {} on failure."""
        png_path = self.tmpdir / "handles.png"
        try: os.remove(png_path)
        except OSError: pass
        cam = state.get("camera", {})
        bnd = cam.get("bounds", [0, 0, 1426, 966])
        self.screenshot(png_path)
        if not png_path.exists() or os.path.getsize(png_path) < 1000:
            return {}
        bx, by, bw, bh = bnd
        # Step 1: detect the cyan center cube using an analytical
        # gizmo-position hint. This is the only handle for which we
        # need analytical input — once we have the actual on-screen
        # gizmo center, the per-axis arrow hints below are computed
        # relative to THAT pixel, so any inaccuracy in
        # _world_to_screen doesn't propagate (it just biases the
        # cyan match toward the right ballpark).
        try:
            gizmo_world = _selection_bbox_center(state)
            anal_cx, anal_cy = _world_to_screen(cam, gizmo_world)
        except Exception:
            return {}

        out = {}
        c_path = self.tmpdir / "handle_center.json"
        try: os.remove(c_path)
        except OSError: pass
        subprocess.run(
            ["python3", str(SCRIPT_DIR / "detect_handles.py"),
             str(png_path), str(c_path),
             "--region", f"{bx},{by},{bw},{bh}",
             "--hint", f"{anal_cx},{anal_cy}"],
            capture_output=True, text=True)
        try:
            pos = json.loads(c_path.read_text()).get("center")
            if pos is not None:
                out["center"] = tuple(pos)
        except Exception:
            pass

        # Step 2: per-axis arrow hints anchored on the DETECTED
        # center (or the analytical fallback). 70 px along the
        # projected axis biases detection toward the arrow SHAFT and
        # away from the plane handles (red XY-circle, green YZ-
        # ellipse, blue XZ-circle) that sit near the base of each
        # arrow and use the same RGB family.
        if "center" in out:
            cx, cy = out["center"]
        else:
            cx, cy = anal_cx, anal_cy

        for name, axis in (("x", (1.0, 0.0, 0.0)),
                           ("y", (0.0, 1.0, 0.0)),
                           ("z", (0.0, 0.0, 1.0))):
            sx, sy = _project_axis_to_screen(cam, axis)
            hx = cx + 70.0 * sx
            hy = cy + 70.0 * sy
            json_path = self.tmpdir / f"handle_{name}.json"
            try: os.remove(json_path)
            except OSError: pass
            r = subprocess.run(
                ["python3", str(SCRIPT_DIR / "detect_handles.py"),
                 str(png_path), str(json_path),
                 "--region", f"{bx},{by},{bw},{bh}",
                 "--hint", f"{hx},{hy}"],
                capture_output=True, text=True)
            if r.returncode != 0 or not json_path.exists():
                continue
            try:
                pos = json.loads(json_path.read_text()).get(name)
                if pos is not None:
                    out[name] = tuple(pos)
            except Exception:
                pass
        return out

    def click(self, x, y, settle=0.15):
        self.xdo("mousemove", str(x), str(y))
        time.sleep(settle)
        self.xdo("click", "1")

    def _ui_xy(self, x, y):
        """Translate hardcoded UI coords (relative to MODO content
        origin) to absolute screen coords. In matchbox-fullscreen
        win_x/y are (0,0) so this is a no-op; under a normal WM with
        a titlebar (visible mode) win_y > 0 and we shift everything
        down so the click hits the same logical UI element."""
        return x + self.win_x, y + self.win_y

    def click_ui(self, rel_x, rel_y, settle=0.15):
        ax, ay = self._ui_xy(rel_x, rel_y)
        self.click(ax, ay, settle)

    def _activate_modo_window(self):
        """Bring MODO to the foreground — required under most Wayland
        compositors before xdotool's keystrokes get delivered to MODO
        (otherwise they go to whatever window the compositor thinks
        is focused). Cached lookup of the window id avoids the
        re-search cost."""
        if not getattr(self, "_modo_wid", None):
            r = subprocess.run(
                ["xdotool", "search", "--name", "modo"],
                env=self.env(), capture_output=True, text=True)
            wid = r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""
            if not wid:
                return
            self._modo_wid = wid
        subprocess.run(
            ["xdotool", "windowactivate", self._modo_wid],
            env=self.env(), capture_output=True)
        time.sleep(0.05)

    def _type_text(self, text):
        """Type `text` via xdotool. Avoids `xdotool type` because that
        sends Unicode that gets re-mapped through the active keyboard
        layout — under Wayland with a Russian/Ukrainian/etc. layout
        active, ASCII input becomes Cyrillic and MODO's command bar
        rejects it. `xdotool key` with explicit keysyms bypasses the
        layout: each US-ASCII char is mapped to its named keysym
        (slash / period / at / underscore / etc.) and sent
        unambiguously."""
        symmap = {
            " ": "space", "/": "slash", ".": "period", "_": "underscore",
            "@": "at", "-": "minus", "+": "plus", "=": "equal",
            ":": "colon", ";": "semicolon", ",": "comma",
            "(": "parenleft", ")": "parenright",
            "[": "bracketleft", "]": "bracketright",
            "{": "braceleft", "}": "braceright",
            '"': "quotedbl", "'": "apostrophe",
            "*": "asterisk", "?": "question", "!": "exclam",
            "<": "less", ">": "greater",
            "\\": "backslash", "|": "bar", "&": "ampersand",
            "#": "numbersign", "$": "dollar", "%": "percent",
            "^": "asciicircum", "~": "asciitilde", "`": "grave",
            "\n": "Return", "\t": "Tab",
        }
        keys = []
        for ch in text:
            if ch in symmap:
                keys.append(symmap[ch])
            else:
                keys.append(ch)
        if not keys:
            return
        self.xdo("key", "--delay", "20", *keys)

    def cmd_bar(self, cmd, wait_for=None, timeout=8.0):
        # In visible mode the MODO window may not have keyboard
        # focus from the WM (focus follows compositor focus, not
        # mouse). Pre-activate it so xdotool's keystrokes land in
        # MODO. No-op-ish under matchbox-fullscreen but cheap.
        if self.visible:
            self._activate_modo_window()
        self.click_ui(CMD_BAR_X, CMD_BAR_Y)
        time.sleep(0.2)
        self._type_text(cmd)
        time.sleep(0.15)
        self.xdo("key", "Return")
        if wait_for is None:
            time.sleep(0.5)
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if Path(wait_for).exists():
                return True
            time.sleep(0.1)
        return False

    def file_reset(self):
        self.click_ui(FILE_MENU_X,  FILE_MENU_Y);  time.sleep(1)
        self.click_ui(RESET_ITEM_X, RESET_ITEM_Y); time.sleep(2)
        # The popup dialog is centred on the MODO window — under a
        # WM with frame decoration its absolute screen coords would
        # also need shifting, so route through _ui_xy via click_ui.
        self.click_ui(POPUP_OK_X,   POPUP_OK_Y);   time.sleep(3)

    def mouse_drag(self, x, y, dx, dy, step_px=20):
        """Drag from (x, y) by (dx, dy) generating one xdotool mousemove
        every `step_px` pixels (default 20). Exposed so the drag-formula
        experiment can probe how MODO's per-event accumulation behaves
        when N (event count) varies with the same total pixel offset.

        Handle-driven cases (`_resolve_handle_drag`) deliver float drag
        tuples; mouse_drag coerces every coord/step to int internally
        because xdotool only accepts integer pixels and Python 3.14's
        `range()` rejects float endpoints."""
        x, y, dx, dy = int(x), int(y), int(dx), int(dy)
        self.xdo("mousemove", str(x), str(y))
        time.sleep(0.2)
        self.xdo("mousedown", "1")
        time.sleep(0.15)
        steps = max(abs(dx), abs(dy)) // step_px or 1
        for i in range(1, steps + 1):
            self.xdo("mousemove", str(x + dx * i // steps),
                                  str(y + dy * i // steps))
            time.sleep(0.03)
        time.sleep(0.15)
        self.xdo("mouseup", "1")

    # ----- lifecycle -----
    def start_xvfb(self):
        safe_print(blue(f"=== [w{self.id}] Xvfb on {self.display} ==="))
        subprocess.Popen(
            ["Xvfb", self.display, "-screen", "0", "1920x1080x24",
             "-nolisten", "tcp"],
            stdout=open(LOG_DIR / f"modo_acen_xvfb_{self.id}.log", "w"),
            stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(2)
        if subprocess.run(["xdpyinfo"], env=self.env(),
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode != 0:
            raise RuntimeError(f"Xvfb {self.display} failed to come up")

    def start_matchbox(self):
        safe_print(blue(f"=== [w{self.id}] matchbox WM ==="))
        subprocess.Popen(
            ["matchbox-window-manager", "-use_titlebar", "no"],
            env=self.env(),
            stdout=open(LOG_DIR / f"modo_acen_matchbox_{self.id}.log", "w"),
            stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(2)
        r = subprocess.run(["xprop", "-root"], env=self.env(),
                           capture_output=True, text=True)
        if "_NET_SUPPORTING_WM_CHECK" not in r.stdout:
            raise RuntimeError(f"matchbox didn't register on {self.display}")

    def launch_modo(self):
        safe_print(blue(f"=== [w{self.id}] launching MODO ==="))
        env = self.env({
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "LD_LIBRARY_PATH":       MODO_LD,
            "NEXUS_CONTENT":         MODO_CONTENT,
        })
        self.modo_proc = subprocess.Popen(
            [str(MODO_BIN)],
            env=env,
            stdout=open(LOG_DIR / f"modo_acen_log_{self.id}.txt", "w"),
            stderr=subprocess.STDOUT, start_new_session=True)
        safe_print(blue(f"=== [w{self.id}] waiting for viewport render ==="))
        poll_png = LOG_DIR / f"modo_acen_poll_{self.id}.png"
        for i in range(60):
            if self.modo_proc.poll() is not None:
                raise RuntimeError(f"MODO {self.display} died at {i}s")
            self.screenshot(poll_png)
            size = os.path.getsize(poll_png)
            if size > 50_000:
                safe_print(f"  [w{self.id}] rendered in {i+1}s ({size}b)")
                return
            time.sleep(1)
        raise RuntimeError(f"MODO {self.display} didn't render within 60s")

    def boot(self):
        if not self.visible:
            self.start_xvfb()
            self.start_matchbox()
        self.launch_modo()
        if self.visible:
            self._visible_resize_modo()
        safe_print(blue(f"=== [w{self.id}] File → Reset → OK ==="))
        self.file_reset()

    def _visible_resize_modo(self):
        """In visible mode, MODO opens at the window manager's
        default size with WM frame decoration (titlebar). Hardcoded
        UI coordinates (CMD_BAR_X, FILE_MENU_X, etc.) are relative
        to MODO's content origin — under matchbox-fullscreen content
        starts at (0, 0), but under a normal WM it's offset by the
        titlebar height. After resizing MODO to (0, 0) 1920×1080 we
        record the actual content origin into self.win_x / win_y so
        click_ui() can shift each click into screen coords.
        """
        env = self.env()
        for _ in range(20):
            r = subprocess.run(
                ["xdotool", "search", "--name", "modo"],
                env=env, capture_output=True, text=True)
            wid = r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""
            if wid:
                break
            time.sleep(0.3)
        if not wid:
            safe_print(red(f"=== [w{self.id}] visible: MODO window not found ==="))
            return
        safe_print(blue(f"=== [w{self.id}] visible: resize MODO {wid} → 1920x1080 @ (0,0) ==="))
        subprocess.run(["xdotool", "windowmove", wid, "0", "0"],
                       env=env, capture_output=True)
        subprocess.run(["xdotool", "windowsize", wid, "1920", "1080"],
                       env=env, capture_output=True)
        time.sleep(0.5)
        subprocess.run(["xdotool", "windowactivate", wid],
                       env=env, capture_output=True)
        time.sleep(0.3)

        # xdotool getwindowgeometry returns the window's CONTENT
        # position+size (frame excluded under most WMs — confirmed
        # KDE/Plasma + GNOME/Mutter). Use it directly as the content
        # origin offset.
        r = subprocess.run(
            ["xdotool", "getwindowgeometry", "--shell", wid],
            env=env, capture_output=True, text=True)
        for line in r.stdout.splitlines():
            if line.startswith("X="):
                self.win_x = int(line.split("=", 1)[1])
            elif line.startswith("Y="):
                self.win_y = int(line.split("=", 1)[1])
        safe_print(blue(f"=== [w{self.id}] visible: content origin = "
                        f"({self.win_x}, {self.win_y}) ==="))

    def shutdown(self):
        # Kill anything bound to this worker's display. Other workers'
        # MODO/Xvfb on different displays survive — only ours die.
        if self.modo_proc:
            try: self.modo_proc.kill()
            except Exception: pass
        if self.visible:
            # Caller's display + WM stays — we only manage MODO.
            return
        # We can't grep by display name reliably for MODO (`modo` is the
        # process name, no DISPLAY in argv), so killing modo_proc PID
        # above is the only safe per-worker kill. Xvfb + matchbox we can
        # match by display.
        for pat in (f"Xvfb {self.display}",
                    f"matchbox-window-manager"):
            pids = subprocess.run(["pgrep", "-f", pat],
                                  capture_output=True, text=True).stdout.split()
            for pid in pids:
                # Cross-check: only kill matchbox if it's bound to OUR
                # display. matchbox doesn't expose DISPLAY in argv;
                # /proc/$pid/environ is the reliable test.
                if "matchbox" in pat:
                    try:
                        with open(f"/proc/{pid}/environ", "rb") as f:
                            env = f.read().decode(errors="ignore")
                        if f"DISPLAY={self.display}\0" not in env:
                            continue
                    except (OSError, FileNotFoundError):
                        continue
                subprocess.run(["kill", "-9", pid],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
        n = self.display.lstrip(":")
        for p in (f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"):
            try: os.remove(p)
            except OSError: pass

    # ----- per-case orchestration -----
    def run_case(self, path, step_px_override=None):
        spec = json.loads(path.read_text())
        tool      = spec["tool"]
        pattern   = spec["pattern"]
        acen_mode = spec["acen_mode"]
        handle    = spec.get("handle")             # x|y|z|center, optional
        drag_len  = spec.get("drag_pixels", 100)
        falloff   = spec.get("falloff")            # {type, start, end}, optional
        # When `handle` is set, we resolve the drag start/length from
        # camera + axis after the setup script has dumped state.json
        # (camera info is unknown until then). Fall back to the raw
        # `drag` field for cases without a handle.
        drag      = spec.get("drag", DEFAULT_DRAG) if handle is None else None
        view_pre  = spec.get("view_pre", [])
        step_px   = step_px_override if step_px_override is not None \
                    else spec.get("step_px", 20)
        if drag is not None and len(drag) != 4:
            return "ERROR", f"drag must be [x, y, dx, dy] not {drag}"

        for f in (self.state_path, self.result_path):
            try: os.remove(f)
            except OSError: pass

        # When handle-driven, defer the screen-pixel drag start until
        # after we've read state.json's camera. For now feed setup with
        # a placeholder click point — actual drag pixel is computed
        # from the camera + axis projection below.
        setup_drag_x = drag[0] if drag else 1020
        setup_drag_y = drag[1] if drag else 560
        if not self.cmd_bar(
                f"@modo_drag_setup.py {self.tmpdir} {acen_mode} {pattern} "
                f"{tool} {setup_drag_x} {setup_drag_y}",
                wait_for=str(self.state_path), timeout=8):
            return "ERROR", "setup did not produce state.json"

        # Optional Falloff stage: pushed into the toolpipe AFTER setup
        # (which already activated ACEN + xfrm.<tool>). MODO's slot
        # system places `falloff.<type>` in WGHT independent of
        # activation order, so per-vertex weights apply at drag time.
        # The helper script also patches state.json with the falloff
        # config so verify_acen_drag.py can recompute weights and check
        # per-vertex deltas.
        if falloff is not None:
            ftype = falloff.get("type", "linear")
            shape = falloff.get("shape", "linear")
            p0    = float(falloff.get("in",  0.0))
            p1    = float(falloff.get("out", 0.0))
            if ftype not in ("linear", "radial"):
                return "ERROR", f"unsupported falloff type: {ftype}"
            if shape not in ("linear", "easeIn", "easeOut", "smooth", "custom"):
                return "ERROR", f"unsupported falloff shape: {shape}"
            # Per-type position attrs feed into the helper as args 2..7
            # (helper interprets per ftype).
            if ftype == "linear":
                a = falloff.get("start", [0.0, 0.0, 0.0])
                b = falloff.get("end",   [0.0, 1.0, 0.0])
                if len(a) != 3 or len(b) != 3:
                    return "ERROR", f"falloff start/end must be [x,y,z]"
            else:  # radial
                a = falloff.get("center", [0.0, 0.0, 0.0])
                b = falloff.get("size",   [1.0, 1.0, 1.0])
                if len(a) != 3 or len(b) != 3:
                    return "ERROR", f"falloff center/size must be [x,y,z]"
            sentinel = self.tmpdir / "modo_falloff.done"
            try: os.remove(sentinel)
            except OSError: pass
            if not self.cmd_bar(
                    f"@modo_falloff_setup.py {self.tmpdir} {ftype} "
                    f"{a[0]} {a[1]} {a[2]} "
                    f"{b[0]} {b[1]} {b[2]} "
                    f"{shape} {p0} {p1}",
                    wait_for=str(sentinel), timeout=8):
                return "ERROR", "falloff setup did not complete"

        # Wake up viewport gizmo render so detect_handles.py finds
        # the handle pixels in the screenshot. Sequence:
        #   1. mousemove cursor into viewport
        #   2. click — MODO interprets this as click-away with
        #      xfrm.move active and starts a "drag pending" state
        #   3. key W — re-activates xfrm.move via the real input
        #      path, which DOES flag the viewport for redraw
        #   4. key Space — MODO's "commit tool" shortcut. Closes the
        #      drag-pending state from step 2 so subsequent cmd_bar
        #      commands (like @modo_dump_verts.py) actually execute.
        if handle is not None:
            try:
                cam_pre = json.loads(self.state_path.read_text()).get("camera", {})
                bnd = cam_pre.get("bounds", [0, 0, 1426, 966])
                vx = bnd[0] + bnd[2] // 2
                vy = bnd[1] + bnd[3] // 2
            except Exception:
                vx, vy = 700, 500
            self.xdo("mousemove", str(vx), str(vy))
            time.sleep(0.15)
            self.xdo("click", "1")
            time.sleep(0.2)
            tool_key = {"move": "w", "rotate": "e", "scale": "r"}.get(tool, "w")
            self.xdo("key", tool_key)
            time.sleep(0.3)
            self.xdo("key", "space")
            time.sleep(0.3)

        # Optional `view_pre`: list of MODO eval commands run AFTER the
        # setup script (which creates the cube + selection) but BEFORE
        # the mouse drag. Used by drag_cases/* with non-default cameras
        # to orbit / zoom / fit the viewport. The setup script captured
        # camera state for state.json BEFORE these run, so we re-capture
        # it via a tiny probe script after.
        if view_pre:
            for cmd in view_pre:
                self.cmd_bar(cmd)
                time.sleep(0.2)
            # Re-capture camera state into state.json (overwrites the
            # camera block setup wrote — selection etc. are unchanged).
            probe_script = self.tmpdir / "recap_camera.py"
            probe_script.write_text(
                "#python\n"
                "import lx, json\n"
                f"sp = '{self.state_path}'\n"
                "with open(sp) as f: state = json.load(f)\n"
                "_vp  = lx.service.View3Dport()\n"
                "_v3d = lx.object.View3D(_vp.View(_vp.Current()))\n"
                "bnd  = _v3d.Bounds()\n"
                "cen  = _v3d.Center()\n"
                "ev   = _v3d.EyeVector()\n"
                "dist = float(ev[0]); fpos = ev[1]; fwd = ev[2]\n"
                "eye  = (fpos[0]-fwd[0]*dist, fpos[1]-fwd[1]*dist,\n"
                "        fpos[2]-fwd[2]*dist)\n"
                "state['camera']['bounds'] = "
                "[int(bnd[0]),int(bnd[1]),int(bnd[2]),int(bnd[3])]\n"
                "state['camera']['center'] = "
                "[float(cen[0]),float(cen[1]),float(cen[2])]\n"
                "state['camera']['eye']    = "
                "[eye[0],eye[1],eye[2]]\n"
                "state['camera']['fwd']    = "
                "[float(fwd[0]),float(fwd[1]),float(fwd[2])]\n"
                "state['camera']['distance'] = dist\n"
                "with open(sp,'w') as f: json.dump(state, f)\n"
            )
            self.cmd_bar(f"@{probe_script}")
            time.sleep(0.3)

        # Handle-driven path: wake gizmo via W keystroke, detect
        # actual handle pixels from a screenshot, drive the test
        # drag at the detected handle, and save handles_debug.png
        # with overlay markers for visual verification.
        if handle is not None:
            try:
                state_now = json.loads(self.state_path.read_text())
                cam = state_now.get("camera", {})
                bnd = cam.get("bounds", [0, 0, 1426, 966])
                vx = bnd[0] + bnd[2] // 2
                vy = bnd[1] + bnd[3] // 2
            except Exception:
                state_now, vx, vy = {"camera": {}}, 700, 500

            # Cursor over viewport + W key (no click — that would
            # relocate ACEN under actr.auto). Activates the tool
            # via the input pipeline so the gizmo's coloured handles
            # are flagged for redraw and visible in screenshots.
            # vx, vy are in MODO content coords; _ui_xy() shifts them
            # to screen coords under a real WM (visible mode).
            ax, ay = self._ui_xy(vx, vy)
            self.xdo("mousemove", str(ax), str(ay))
            time.sleep(0.2)
            tool_key = {"move": "w", "rotate": "e", "scale": "r"}.get(tool, "w")
            self.xdo("key", tool_key)
            time.sleep(0.5)

            detected = self._detect_handles(state_now)
            try:
                drag = _resolve_handle_drag(
                    state_now, handle, drag_len, detected)
            except Exception as e:
                return "ERROR", f"could not resolve handle drag: {e}"
            self._annotate_handle_debug(drag[0], drag[1], detected, handle)
            state_now["camera"]["drag"] = [float(drag[0]), float(drag[1])]
            state_now["resolved_drag"]  = list(drag)
            if detected:
                state_now["detected_handles"] = {
                    k: [float(v[0]), float(v[1])]
                    for k, v in detected.items()
                }
            self.state_path.write_text(json.dumps(state_now))

        self.mouse_drag(*drag, step_px=step_px)
        time.sleep(0.3)

        if not self.cmd_bar(
                f"@modo_dump_verts.py {self.tmpdir} {tool}",
                wait_for=str(self.result_path), timeout=6):
            return "ERROR", "dump did not produce result.json"

        env = {**os.environ, "MODE": acen_mode}
        r = subprocess.run(
            ["python3", str(SCRIPT_DIR / "verify_acen_drag.py"),
             str(self.result_path), str(self.state_path)],
            env=env, capture_output=True, text=True)
        # Buffer the verifier's per-case output so multi-worker output
        # doesn't interleave; emit it as a single block.
        with _print_lock:
            print()
            print(blue("="*60))
            print(blue(f"=== [w{self.id}] {path.stem}"))
            print(blue("="*60))
            print(r.stdout, end="")
            if r.stderr:
                print(r.stderr, end="", file=sys.stderr)
        return ("PASS", None) if r.returncode == 0 else ("FAIL", "verifier")


# ---- case discovery -------------------------------------------------
def discover_cases(filters):
    cases = sorted(CASES_DIR.glob("*.json"))
    if not cases:
        print(red(f"ERROR: no cases in {CASES_DIR}"))
        sys.exit(2)
    if not filters:
        return cases
    keep = []
    for c in cases:
        if any(fnmatch.fnmatch(c.stem, pat) for pat in filters):
            keep.append(c)
    if not keep:
        print(red(f"ERROR: no case matches: {' '.join(filters)}"))
        sys.exit(2)
    return keep


def cleanup_all_displays(max_id=64):
    """Used by --keep=False at exit and by --kill-stale at start. Walks
    likely worker IDs and kills any MODO/Xvfb/matchbox left over from a
    previous run. matchbox global pkill is fine — we don't run it
    standalone elsewhere."""
    for pat in ("Modo902", "foundrycrashhandler",
                "matchbox-window-manager"):
        subprocess.run(["pkill", "-9", "-f", pat],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for i in range(max_id):
        d = f":{99 + i}"
        pids = subprocess.run(["pgrep", "-f", f"Xvfb {d}"],
                              capture_output=True, text=True).stdout.split()
        for pid in pids:
            subprocess.run(["kill", "-9", pid],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
    time.sleep(1)
    for i in range(max_id):
        n = str(99 + i)
        for p in (f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"):
            try: os.remove(p)
            except OSError: pass


# ---- main -----------------------------------------------------------
def run_with_workers(cases, j, keep, visible=False):
    workers = [Worker(i, visible=visible) for i in range(j)]

    # Boot workers in parallel — Xvfb + MODO load is ~3 s per worker,
    # serial that's 3 s × N. Parallel keeps it close to single-worker
    # boot time.
    with concurrent.futures.ThreadPoolExecutor(max_workers=j) as ex:
        list(ex.map(lambda w: w.boot(), workers))

    # Case queue: workers pull from it concurrently.
    import queue
    q = queue.Queue()
    for c in cases:
        q.put(c)
    sentinel = object()
    for _ in workers:
        q.put(sentinel)

    results = []
    results_lock = threading.Lock()

    def worker_loop(w):
        while True:
            item = q.get()
            if item is sentinel:
                return
            try:
                status, why = w.run_case(item)
            except Exception as e:
                status, why = "ERROR", repr(e)
            with results_lock:
                results.append((item.stem, status, why))

    threads = [threading.Thread(target=worker_loop, args=(w,))
               for w in workers]
    for t in threads: t.start()
    for t in threads: t.join()

    if not keep:
        with concurrent.futures.ThreadPoolExecutor(max_workers=j) as ex:
            list(ex.map(lambda w: w.shutdown(), workers))

    # Deterministic summary: workers finish in arbitrary order, so sort
    # by case stem before printing.
    results.sort(key=lambda r: r[0])
    return results


def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__)
    ap.add_argument("filters", nargs="*",
                    help="case filename stems / glob patterns; "
                         "default = run every case")
    ap.add_argument("--keep", action="store_true",
                    help="leave Xvfb/MODO running after the matrix completes")
    ap.add_argument("-j", type=int, default=1,
                    help="parallel MODO workers (default 1)")
    ap.add_argument("--visible", action="store_true",
                    help="run MODO on the caller's real X display "
                         "(skips Xvfb + matchbox). Useful for "
                         "debugging — you can SEE what MODO is doing "
                         "while xdotool drives it. Forces -j 1.")
    args = ap.parse_args()

    if args.j < 1:
        print(red("ERROR: -j must be >= 1"))
        sys.exit(2)
    if args.visible and args.j > 1:
        print(yellow("--visible: forcing -j 1 (only one visible MODO at a time)"))
        args.j = 1

    check_prereqs()
    cases = discover_cases(args.filters)
    print(blue(f"=== {len(cases)} case(s) selected, j={args.j} ==="))
    cleanup_all_displays()

    try:
        copy_scripts()
        results = run_with_workers(cases, args.j, args.keep,
                                    visible=args.visible)

        passed  = [n for n, s, _ in results if s == "PASS"]
        failed  = [(n, w) for n, s, w in results if s == "FAIL"]
        errored = [(n, w) for n, s, w in results if s == "ERROR"]

        print()
        print(blue("="*60))
        print(blue("=== summary"))
        print(blue("="*60))
        for name in passed:
            print(green(f"  PASS:  {name}"))
        for name, why in failed:
            print(red(f"  FAIL:  {name}{(' (' + why + ')') if why else ''}"))
        for name, why in errored:
            print(red(f"  ERROR: {name} ({why})"))

        print()
        total = len(results)
        if not failed and not errored:
            print(green(f"All {total} cases PASS."))
            return 0
        print(red(f"{len(failed) + len(errored)} of {total} cases failed."))
        return 1
    finally:
        if not args.keep:
            cleanup_all_displays()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        cleanup_all_displays()
        sys.exit(130)
