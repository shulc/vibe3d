#!/usr/bin/env python3
"""Cross-check vibe3d ACEN modes against MODO via real mouse-drag.

Architecture: launches Xvfb + matchbox + MODO ONCE; between tests uses
File→Reset and a fresh setup-script run (NOT a MODO restart).

Why not bash like the previous run_acen_drag.sh: this is fundamentally
state-driven shell-out + JSON parsing + waits + retry — Python's
subprocess + pathlib + json keep the orchestration readable. Each test
case is a function call instead of an inlined bash block.

Requires: Xvfb, matchbox-window-manager, xdotool, ImageMagick (`import`),
python3. Override via env: MODO_BIN, MODO_LD, MODO_CONTENT.

Usage:
  ./run_acen_drag.py                   # full default matrix
  ./run_acen_drag.py select origin     # subset of modes
  PATTERNS=sphere_top TOOLS=rotate ./run_acen_drag.py local
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# ---- config -----------------------------------------------------------
DISPLAY        = ":99"
MODO_BIN       = Path(os.environ.get(
    "MODO_BIN", "/home/ashagarov/Program/Modo902/modo"))
MODO_LD        = os.environ.get("MODO_LD", "/home/ashagarov/.local/lib")
MODO_CONTENT   = os.environ.get(
    "MODO_CONTENT", "/home/ashagarov/.luxology/Content")
SCRIPT_DIR     = Path(__file__).resolve().parent
USER_SCRIPTS   = Path.home() / ".luxology" / "Scripts"
SYSTEM_SCRIPTS = MODO_BIN.parent / "extra" / "Scripts"
LOG_DIR        = Path("/tmp")

# UI coords for matchbox-fullscreen MODO at 1920x1080.
FILE_MENU_X,  FILE_MENU_Y  = 17,   10
RESET_ITEM_X, RESET_ITEM_Y = 40,   778
POPUP_OK_X,   POPUP_OK_Y   = 1175, 538
CMD_BAR_X,    CMD_BAR_Y    = 1750, 1063
DRAG_START_X, DRAG_START_Y = 1020, 560

# Default matrix (overridable via env or argv).
DEFAULT_MODES    = ["select", "selectauto", "auto", "border", "origin", "local"]
DEFAULT_TOOLS    = ["scale", "move", "rotate"]
DEFAULT_PATTERNS = ["single_top", "asymmetric", "sphere_top"]


# ---- ANSI ------------------------------------------------------------
def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"


# ---- shell helpers ---------------------------------------------------
def display_env(extra=None):
    e = os.environ.copy()
    e["DISPLAY"] = DISPLAY
    if extra:
        e.update(extra)
    return e


def xdo(*args):
    """Run xdotool with DISPLAY set, ignore errors (xdotool returns
    non-zero for benign no-window-focus warnings under matchbox)."""
    subprocess.run(["xdotool", *args], env=display_env(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def screenshot(path):
    subprocess.run(["import", "-window", "root", path], env=display_env(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def click(x, y, settle=0.3):
    xdo("mousemove", str(x), str(y))
    time.sleep(settle)
    xdo("click", "1")


def cmd_bar(cmd, wait_for=None, timeout=8.0):
    """Type a command into MODO's bottom-right command bar and Enter.
    If `wait_for` is a path, poll for it (100ms granularity) up to
    `timeout` seconds — much faster than a fixed `time.sleep` since
    MODO usually finishes the command in <1s but we used to wait 3-4s.
    Returns True if the path appeared (or wait_for is None)."""
    click(CMD_BAR_X, CMD_BAR_Y, settle=0.15)
    time.sleep(0.15)
    xdo("type", "--delay", "20", cmd)
    time.sleep(0.15)
    xdo("key", "Return")
    if wait_for is None:
        time.sleep(0.5)
        return True
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if Path(wait_for).exists():
            return True
        time.sleep(0.1)
    return False


def file_reset():
    """Layout → File → Reset → OK. Resets gizmo state between tests so
    each iteration starts from the same camera + viewport configuration."""
    click(FILE_MENU_X,  FILE_MENU_Y);  time.sleep(1)
    click(RESET_ITEM_X, RESET_ITEM_Y); time.sleep(2)
    click(POPUP_OK_X,   POPUP_OK_Y);   time.sleep(3)


def mouse_drag(x, y, dx=100):
    """Drag from (x,y) to (x+dx, y) in five 20-px steps."""
    xdo("mousemove", str(x), str(y))
    time.sleep(0.2)
    xdo("mousedown", "1")
    time.sleep(0.15)
    for step in range(20, dx + 1, 20):
        xdo("mousemove", str(x + step), str(y))
        time.sleep(0.03)
    time.sleep(0.15)
    xdo("mouseup", "1")


# ---- prereq + lifecycle ---------------------------------------------
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
    for d in (USER_SCRIPTS, SYSTEM_SCRIPTS):
        if not d.is_dir():
            print(red(f"ERROR: {d} missing"))
            sys.exit(2)
    for f in ("modo_drag_setup.py", "modo_dump_verts.py",
              "verify_acen_drag.py"):
        if not (SCRIPT_DIR / f).is_file():
            print(red(f"ERROR: missing {SCRIPT_DIR / f}"))
            sys.exit(2)


def cleanup():
    for pat in ("Modo902", "foundrycrashhandler",
                "matchbox-window-manager"):
        subprocess.run(["pkill", "-9", "-f", pat],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pids = subprocess.run(["pgrep", "-f", f"Xvfb {DISPLAY}"],
                          capture_output=True, text=True).stdout.split()
    for pid in pids:
        subprocess.run(["kill", "-9", pid],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    for p in ("/tmp/.X99-lock", "/tmp/.X11-unix/X99"):
        try: os.remove(p)
        except OSError: pass


def start_xvfb():
    print(blue(f"=== Xvfb on {DISPLAY} ==="))
    subprocess.Popen(
        ["Xvfb", DISPLAY, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
        stdout=open(LOG_DIR / "modo_acen_xvfb.log", "w"),
        stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(2)
    r = subprocess.run(["xdpyinfo"], env=display_env(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        print(red("ERROR: Xvfb failed to come up"))
        sys.exit(3)


def start_matchbox():
    print(blue("=== matchbox WM ==="))
    subprocess.Popen(
        ["matchbox-window-manager", "-use_titlebar", "no"],
        env=display_env(),
        stdout=open(LOG_DIR / "modo_acen_matchbox.log", "w"),
        stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(2)
    r = subprocess.run(["xprop", "-root"], env=display_env(),
                       capture_output=True, text=True)
    if "_NET_SUPPORTING_WM_CHECK" not in r.stdout:
        print(red("ERROR: matchbox didn't register"))
        sys.exit(3)


def copy_scripts():
    print(blue("=== copying MODO scripts ==="))
    for name in ("modo_drag_setup.py", "modo_dump_verts.py"):
        for dst in (USER_SCRIPTS, SYSTEM_SCRIPTS):
            shutil.copy(SCRIPT_DIR / name, dst / name)


def launch_modo():
    print(blue("=== launching MODO ==="))
    env = display_env({
        "LIBGL_ALWAYS_SOFTWARE": "1",
        "LD_LIBRARY_PATH":       MODO_LD,
        "NEXUS_CONTENT":         MODO_CONTENT,
    })
    proc = subprocess.Popen(
        [str(MODO_BIN)],
        env=env,
        stdout=open(LOG_DIR / "modo_acen_log.txt", "w"),
        stderr=subprocess.STDOUT, start_new_session=True)

    print(blue("=== waiting for viewport render ==="))
    for i in range(60):
        if proc.poll() is not None:
            print(red(f"ERROR: MODO died at {i}s"))
            sys.exit(4)
        screenshot(str(LOG_DIR / "modo_acen_poll.png"))
        size = os.path.getsize(LOG_DIR / "modo_acen_poll.png")
        if size > 50_000:
            print(f"  rendered in {i+1}s ({size}b)")
            return proc
        time.sleep(1)
    print(red("ERROR: MODO didn't render within 60s"))
    sys.exit(4)


# ---- per-test orchestration -----------------------------------------
def run_one(tool, pattern, mode):
    """Run setup → drag → dump → verify for one (tool, pattern, mode).
    Returns ("PASS", None) or ("FAIL", "reason").

    NOTE: relies on the setup script's `scene.new` to clear scene state
    between tests, NOT File→Reset. File→Reset between every iteration
    (instead of once at MODO startup) tends to leave the layout in a
    state where the cmd bar / popups don't respond reliably — empirically
    only the first test passes when File→Reset runs per-iteration.
    `scene.new` is enough to reset mesh + selection + tool state."""
    for f in ("/tmp/modo_drag_state.json", "/tmp/modo_drag_result.json"):
        try: os.remove(f)
        except OSError: pass

    if not cmd_bar(f"@modo_drag_setup.py {mode} {pattern} {tool}",
                   wait_for="/tmp/modo_drag_state.json", timeout=8):
        return "FAIL", "setup did not produce state.json"

    mouse_drag(DRAG_START_X, DRAG_START_Y)
    time.sleep(0.5)   # let MODO process the drag before dumping

    if not cmd_bar("@modo_dump_verts.py",
                   wait_for="/tmp/modo_drag_result.json", timeout=6):
        return "FAIL", "dump did not produce result.json"

    env = {**os.environ, "MODE": mode}
    r = subprocess.run(
        ["python3", str(SCRIPT_DIR / "verify_acen_drag.py"),
         "/tmp/modo_drag_result.json"], env=env)
    return ("PASS", None) if r.returncode == 0 else ("FAIL", "verify")


# ---- main -----------------------------------------------------------
def main():
    modes    = sys.argv[1:] if len(sys.argv) > 1 else DEFAULT_MODES
    tools    = os.environ.get("TOOLS",    " ".join(DEFAULT_TOOLS)).split()
    patterns = os.environ.get("PATTERNS", " ".join(DEFAULT_PATTERNS)).split()

    check_prereqs()
    cleanup()

    try:
        start_xvfb()
        start_matchbox()
        copy_scripts()
        launch_modo()

        # ONE-TIME File → Reset → OK so subsequent runs start from the
        # default layout. Per-test reset breaks the cmd bar — see
        # run_one's docstring.
        print(blue("=== File → Reset → OK ==="))
        file_reset()

        passed, failed = [], []
        for tool in tools:
            for pattern in patterns:
                for mode in modes:
                    label = f"{tool}/{pattern}/{mode}"
                    print()
                    print(blue("="*60))
                    print(blue(f"=== {label}"))
                    print(blue("="*60))
                    status, why = run_one(tool, pattern, mode)
                    if status == "PASS":
                        passed.append(label)
                    else:
                        failed.append((label, why))

        print()
        print(blue("="*60))
        print(blue("=== summary"))
        print(blue("="*60))
        for p in passed: print(green(f"  PASS: {p}"))
        for label, why in failed:
            tag = f" ({why})" if why else ""
            print(red(f"  FAIL: {label}{tag}"))

        print()
        if not failed:
            print(green(f"All {len(passed)} cells PASS."))
            return 0
        print(red(f"{len(failed)} of {len(passed) + len(failed)} cells FAILED."))
        return 1
    finally:
        cleanup()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        cleanup()
        sys.exit(130)
