#!/usr/bin/env python3
"""Cross-check vibe3d ACEN modes against MODO via real mouse-drag.

Architecture: launches Xvfb + matchbox + MODO ONCE; iterates the JSON
cases under `drag_cases/` (mirrors `tools/modo_diff/cases/`'s pattern
for the modo_cl harness). Each case is one (tool, pattern, acen_mode)
combination plus optional overrides (drag start / direction, etc.);
default drag is +100 px right from (1020, 560) which lands on a
gizmo handle for both small sphere and larger cube primitives.

Usage:
  ./run_acen_drag.py                       # run every case in drag_cases/
  ./run_acen_drag.py scale_single_top_select  # one case (filename stem)
  ./run_acen_drag.py 'rotate_*'            # glob
  ./run_acen_drag.py --keep                # leave Xvfb/MODO running after

Requires: Xvfb, matchbox-window-manager, xdotool, ImageMagick (`import`),
python3. Override via env: MODO_BIN, MODO_LD, MODO_CONTENT.

Per-case status:
  PASS — verifier returned 0
  FAIL — verifier returned non-zero
  ERROR — setup/dump didn't produce its JSON within the timeout
"""
import argparse
import fnmatch
import json
import os
import shutil
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
CASES_DIR      = SCRIPT_DIR / "drag_cases"
USER_SCRIPTS   = Path.home() / ".luxology" / "Scripts"
SYSTEM_SCRIPTS = MODO_BIN.parent / "extra" / "Scripts"
LOG_DIR        = Path("/tmp")

# UI coords for matchbox-fullscreen MODO at 1920x1080.
FILE_MENU_X,  FILE_MENU_Y  = 17,   10
RESET_ITEM_X, RESET_ITEM_Y = 40,   778
POPUP_OK_X,   POPUP_OK_Y   = 1175, 538
CMD_BAR_X,    CMD_BAR_Y    = 1750, 1063
DEFAULT_DRAG = (1020, 560, 100, 0)   # (start_x, start_y, dx, dy)


# ---- ANSI ------------------------------------------------------------
def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"


# ---- shell helpers ---------------------------------------------------
def display_env(extra=None):
    e = os.environ.copy()
    e["DISPLAY"] = DISPLAY
    if extra: e.update(extra)
    return e


def xdo(*args):
    subprocess.run(["xdotool", *args], env=display_env(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def screenshot(path):
    subprocess.run(["import", "-window", "root", path], env=display_env(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def click(x, y, settle=0.15):
    xdo("mousemove", str(x), str(y))
    time.sleep(settle)
    xdo("click", "1")


def cmd_bar(cmd, wait_for=None, timeout=8.0):
    click(CMD_BAR_X, CMD_BAR_Y)
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
    click(FILE_MENU_X,  FILE_MENU_Y);  time.sleep(1)
    click(RESET_ITEM_X, RESET_ITEM_Y); time.sleep(2)
    click(POPUP_OK_X,   POPUP_OK_Y);   time.sleep(3)


def mouse_drag(x, y, dx, dy):
    xdo("mousemove", str(x), str(y))
    time.sleep(0.2)
    xdo("mousedown", "1")
    time.sleep(0.15)
    steps = max(abs(dx), abs(dy)) // 20 or 1
    for i in range(1, steps + 1):
        xdo("mousemove", str(x + dx * i // steps),
                          str(y + dy * i // steps))
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
    for d in (USER_SCRIPTS, SYSTEM_SCRIPTS, CASES_DIR):
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
    if subprocess.run(["xdpyinfo"], env=display_env(),
                      stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
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


# ---- case discovery -------------------------------------------------
def discover_cases(filters):
    """Walk drag_cases/*.json. If `filters` is non-empty, keep only
    cases whose stem matches ANY filter (glob-style)."""
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


# ---- per-case orchestration -----------------------------------------
def run_case(path):
    """Run setup → drag → dump → verify for one case file. Returns
    ('PASS'|'FAIL'|'ERROR', detail)."""
    spec = json.loads(path.read_text())
    tool      = spec["tool"]
    pattern   = spec["pattern"]
    acen_mode = spec["acen_mode"]
    drag      = spec.get("drag", DEFAULT_DRAG)
    if len(drag) != 4:
        return "ERROR", f"drag must be [x, y, dx, dy] not {drag}"

    for f in ("/tmp/modo_drag_state.json", "/tmp/modo_drag_result.json"):
        try: os.remove(f)
        except OSError: pass

    if not cmd_bar(f"@modo_drag_setup.py {acen_mode} {pattern} {tool}",
                   wait_for="/tmp/modo_drag_state.json", timeout=8):
        return "ERROR", "setup did not produce state.json"

    mouse_drag(*drag)
    time.sleep(0.5)

    if not cmd_bar(f"@modo_dump_verts.py {tool}",
                   wait_for="/tmp/modo_drag_result.json", timeout=6):
        return "ERROR", "dump did not produce result.json"

    env = {**os.environ, "MODE": acen_mode}
    r = subprocess.run(
        ["python3", str(SCRIPT_DIR / "verify_acen_drag.py"),
         "/tmp/modo_drag_result.json"], env=env)
    return ("PASS", None) if r.returncode == 0 else ("FAIL", "verifier")


# ---- main -----------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__)
    ap.add_argument("filters", nargs="*",
                    help="case filename stems / glob patterns; "
                         "default = run every case")
    ap.add_argument("--keep", action="store_true",
                    help="leave Xvfb/MODO running after the matrix completes")
    args = ap.parse_args()

    check_prereqs()
    cases = discover_cases(args.filters)
    print(blue(f"=== {len(cases)} case(s) selected ==="))
    cleanup()

    try:
        start_xvfb()
        start_matchbox()
        copy_scripts()
        launch_modo()

        print(blue("=== File → Reset → OK (one-time) ==="))
        file_reset()

        passed, failed, errored = [], [], []
        for path in cases:
            print()
            print(blue("="*60))
            print(blue(f"=== {path.stem}"))
            print(blue("="*60))
            status, why = run_case(path)
            if   status == "PASS":  passed.append(path.stem)
            elif status == "FAIL":  failed.append((path.stem, why))
            else:                   errored.append((path.stem, why))

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
        total = len(passed) + len(failed) + len(errored)
        if not failed and not errored:
            print(green(f"All {total} cases PASS."))
            return 0
        print(red(f"{len(failed) + len(errored)} of {total} cases failed."))
        return 1
    finally:
        if not args.keep:
            cleanup()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        cleanup()
        sys.exit(130)
