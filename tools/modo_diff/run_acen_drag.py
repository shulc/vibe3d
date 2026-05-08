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


# ---- ANSI ------------------------------------------------------------
def red(s):   return f"\033[31m{s}\033[0m"
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
              "verify_acen_drag.py"):
        if not (SCRIPT_DIR / f).is_file():
            print(red(f"ERROR: missing {SCRIPT_DIR / f}"))
            sys.exit(2)


def copy_scripts():
    """Scripts are shared (same content for every worker); the worker
    distinguishes itself via the tmpdir argument it passes."""
    print(blue("=== copying MODO scripts ==="))
    for name in ("modo_drag_setup.py", "modo_dump_verts.py"):
        for dst in (USER_SCRIPTS, SYSTEM_SCRIPTS):
            shutil.copy(SCRIPT_DIR / name, dst / name)


# ---- Worker: one MODO instance on its own Xvfb display -------------
class Worker:
    """One MODO instance, isolated by Xvfb display + tmpdir.

    Workers do NOT share scripts directory (MODO uses a global one),
    but writes to /tmp are partitioned by `self.tmpdir`. Setup and
    dump scripts both accept tmpdir as their first argument.
    """

    def __init__(self, worker_id):
        self.id      = worker_id
        self.display = f":{99 + worker_id}"
        self.tmpdir  = Path(f"/tmp/modo_drag_worker_{worker_id}")
        self.tmpdir.mkdir(exist_ok=True)
        self.state_path  = self.tmpdir / "modo_drag_state.json"
        self.result_path = self.tmpdir / "modo_drag_result.json"
        self.modo_proc = None

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

    def click(self, x, y, settle=0.15):
        self.xdo("mousemove", str(x), str(y))
        time.sleep(settle)
        self.xdo("click", "1")

    def cmd_bar(self, cmd, wait_for=None, timeout=8.0):
        self.click(CMD_BAR_X, CMD_BAR_Y)
        time.sleep(0.15)
        self.xdo("type", "--delay", "20", cmd)
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
        self.click(FILE_MENU_X,  FILE_MENU_Y);  time.sleep(1)
        self.click(RESET_ITEM_X, RESET_ITEM_Y); time.sleep(2)
        self.click(POPUP_OK_X,   POPUP_OK_Y);   time.sleep(3)

    def mouse_drag(self, x, y, dx, dy, step_px=20):
        """Drag from (x, y) by (dx, dy) generating one xdotool mousemove
        every `step_px` pixels (default 20). Exposed so the drag-formula
        experiment can probe how MODO's per-event accumulation behaves
        when N (event count) varies with the same total pixel offset."""
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
        self.start_xvfb()
        self.start_matchbox()
        self.launch_modo()
        safe_print(blue(f"=== [w{self.id}] File → Reset → OK ==="))
        self.file_reset()

    def shutdown(self):
        # Kill anything bound to this worker's display. Other workers'
        # MODO/Xvfb on different displays survive — only ours die.
        if self.modo_proc:
            try: self.modo_proc.kill()
            except Exception: pass
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
        drag      = spec.get("drag", DEFAULT_DRAG)
        step_px   = step_px_override if step_px_override is not None \
                    else spec.get("step_px", 20)
        if len(drag) != 4:
            return "ERROR", f"drag must be [x, y, dx, dy] not {drag}"

        for f in (self.state_path, self.result_path):
            try: os.remove(f)
            except OSError: pass

        # Pass drag start coords to setup so it can dump To3D(start)
        # — the expected ACEN.Auto pivot for the next click.
        if not self.cmd_bar(
                f"@modo_drag_setup.py {self.tmpdir} {acen_mode} {pattern} "
                f"{tool} {drag[0]} {drag[1]}",
                wait_for=str(self.state_path), timeout=8):
            return "ERROR", "setup did not produce state.json"

        self.mouse_drag(*drag, step_px=step_px)
        time.sleep(0.5)

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
def run_with_workers(cases, j, keep):
    workers = [Worker(i) for i in range(j)]

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
    args = ap.parse_args()

    if args.j < 1:
        print(red("ERROR: -j must be >= 1"))
        sys.exit(2)

    check_prereqs()
    cases = discover_cases(args.filters)
    print(blue(f"=== {len(cases)} case(s) selected, j={args.j} ==="))
    cleanup_all_displays()

    try:
        copy_scripts()
        results = run_with_workers(cases, args.j, args.keep)

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
