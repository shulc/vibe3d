#!/usr/bin/env python3
"""Visual test proxy — watch any HTTP-driven vibe3d test on screen.

Sits between a test client (run_test.d, the demo driver, manual curl) and a
VISIBLE `vibe3d --test --visible` instance. Every request is forwarded
verbatim, so the test sees an ordinary vibe3d on its usual port. The one
transform is on `POST /api/play-events`: the recorded gesture's motion stream
is densified (extra MOUSEMOTION events interpolated at a few px spacing) and
re-timed within a bounded wall-clock budget, so drags play back smoothly on
screen instead of jumping in coarse 20-step hops.

Because `--test --visible` honors event timestamps (no fast-forward) and now
actually presents frames, the human watches the gesture unfold in real time.

Typical use:
    # one command: launch the visible instance + proxy
    python3 tools/visual_test_proxy.py --launch
    # then, in another shell, run any test through it:
    ./run_test.d --attach 8080 test_primitive_box_snap

Forwarding uses curl (vibe3d's minimal HTTP/1.1 server rejects urllib's
request shape — see the RemoteDisconnected note in the dev log).
"""

import argparse, json, math, os, signal, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
VIBE_PROC = None

# --------------------------------------------------------------------------- #
# play-events smoothing
# --------------------------------------------------------------------------- #
POINTER = ("SDL_MOUSEBUTTONDOWN", "SDL_MOUSEMOTION", "SDL_MOUSEBUTTONUP")

def smooth_log(body: str) -> str:
    """Densify + re-time a JSON-Lines event log for smooth on-screen playback.

    Endpoints (every original down / motion / up / key) are preserved exactly,
    so snap targets and final positions are untouched; we only add in-between
    MOUSEMOTION samples and rewrite the `t` timestamps.
    """
    evs = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            evs.append(json.loads(line))
        except json.JSONDecodeError:
            return body  # not our format — forward untouched

    out, prev, btn = [], None, 0
    for ev in evs:
        ty = ev.get("type")
        if ty in POINTER and "x" in ev and "y" in ev:
            x, y = ev["x"], ev["y"]
            if prev is not None and ARGS.smooth:
                px, py = prev
                dist = math.hypot(x - px, y - py)
                k = int(dist // ARGS.step_px)
                for s in range(1, k):
                    out.append({"type": "SDL_MOUSEMOTION",
                                "x": int(px + (x - px) * s / k),
                                "y": int(py + (y - py) * s / k),
                                "xrel": 0, "yrel": 0,
                                "state": btn, "mod": ev.get("mod", 0)})
            out.append(ev)
            if ty == "SDL_MOUSEBUTTONDOWN":
                btn = 1
            elif ty == "SDL_MOUSEBUTTONUP":
                btn = 0
            prev = (x, y)
        else:
            out.append(ev)  # VIEWPORT, KEY*, etc. — keep in place

    # Re-time: VIEWPORT stays at t=0; the rest are spaced by a uniform dt that
    # stays >= one frame (so SDL doesn't coalesce them) while keeping the whole
    # playback under the wall-clock budget (so the test's poll loop won't time
    # out).
    n = max(1, sum(1 for e in out if e.get("type") != "VIEWPORT"))
    dt = min(40.0, max(ARGS.min_ms, ARGS.max_seconds * 1000.0 / n))
    t = 50.0
    for ev in out:
        if ev.get("type") == "VIEWPORT":
            ev["t"] = 0.0
        else:
            ev["t"] = round(t, 3)
            t += dt
    return "\n".join(json.dumps(e) for e in out) + "\n"

# --------------------------------------------------------------------------- #
# forwarding (via curl — proven against vibe3d's minimal server)
# --------------------------------------------------------------------------- #
MARK = "\n__VTPROXY_HTTP_CODE__"

def forward(method: str, path: str, body: bytes):
    url = f"http://127.0.0.1:{ARGS.target}{path}"
    cmd = ["curl", "-s", "-m", "30", "-X", method, url,
           "-w", MARK + "%{http_code}"]
    if method != "GET":
        cmd += ["--data-binary", "@-"]
    r = subprocess.run(cmd, input=body if method != "GET" else None,
                       capture_output=True)
    raw = r.stdout
    i = raw.rfind(MARK.encode())
    if i < 0:
        return 502, raw
    code = int(raw[i + len(MARK.encode()):] or b"502")
    return code, raw[:i]

# POST endpoints that mutate tool / pipeline parameters. After forwarding (the
# change has applied and the visible instance has rendered it) we hold the
# response for --cmd-delay ms so a human can actually see each step land instead
# of the whole test flashing past.
DELAY_POST_PATHS = ("/api/command", "/api/script", "/api/select", "/api/camera")

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _relay(self, method):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if method == "POST" and self.path == "/api/play-events":
            body = smooth_log(body.decode("utf-8", "replace")).encode()
            if ARGS.verbose:
                n = body.count(b'"type"')
                print(f"  play-events: smoothed to {n} events", flush=True)
        code, resp = forward(method, self.path, body)
        if (method == "POST" and ARGS.cmd_delay > 0
                and self.path in DELAY_POST_PATHS):
            time.sleep(ARGS.cmd_delay / 1000.0)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def do_GET(self):
        self._relay("GET")

    def do_POST(self):
        self._relay("POST")

# --------------------------------------------------------------------------- #
# optional: manage the visible vibe3d instance
# --------------------------------------------------------------------------- #
def launch_vibe():
    global VIBE_PROC
    subprocess.run(["pkill", "-f", f"vibe3d --test .*--http-port {ARGS.target}"],
                   capture_output=True)
    time.sleep(0.4)
    env = dict(os.environ)
    if ARGS.x11:
        env["SDL_VIDEODRIVER"] = "x11"
    argv = [ARGS.vibe3d, "--test", "--visible", "--http-port", str(ARGS.target)]
    print(f"launching visible instance: {' '.join(argv)}"
          f"{'  (SDL_VIDEODRIVER=x11)' if ARGS.x11 else ''}", flush=True)
    VIBE_PROC = subprocess.Popen(argv, env=env,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    for _ in range(60):
        r = subprocess.run(["curl", "-s", "-m", "1", "-o", "/dev/null",
                            "-w", "%{http_code}",
                            f"http://127.0.0.1:{ARGS.target}/api/camera"],
                           capture_output=True, text=True)
        if r.stdout.strip() == "200":
            print(f"visible vibe3d ready on :{ARGS.target}", flush=True)
            return True
        time.sleep(0.5)
    print("ERROR: visible vibe3d did not come up", file=sys.stderr)
    return False

def cleanup(*_):
    if VIBE_PROC and VIBE_PROC.poll() is None:
        VIBE_PROC.terminate()
    sys.exit(0)

def main():
    global ARGS
    ap = argparse.ArgumentParser(description="Visual test proxy for vibe3d")
    ap.add_argument("--listen", type=int, default=8080,
                    help="port the test client hits (default 8080)")
    ap.add_argument("--target", type=int, default=8090,
                    help="port of the visible vibe3d (default 8090)")
    ap.add_argument("--launch", action="store_true",
                    help="spawn (and on exit kill) the visible vibe3d on --target")
    ap.add_argument("--vibe3d", default="./vibe3d", help="vibe3d binary path")
    ap.add_argument("--x11", action="store_true", default=True,
                    help="force SDL_VIDEODRIVER=x11 for the launched instance")
    ap.add_argument("--no-x11", dest="x11", action="store_false")
    ap.add_argument("--smooth", action="store_true", default=True,
                    help="densify play-events motion for smooth playback (default on)")
    ap.add_argument("--no-smooth", dest="smooth", action="store_false")
    ap.add_argument("--step-px", type=float, default=6.0,
                    help="max px between interpolated motion samples")
    ap.add_argument("--min-ms", type=float, default=16.0,
                    help="min ms between events (>= one frame so SDL won't coalesce)")
    ap.add_argument("--max-seconds", type=float, default=6.0,
                    help="cap total playback wall-clock (keep under the test timeout)")
    ap.add_argument("--cmd-delay", type=float, default=200.0,
                    help="ms to pause after each param-changing POST "
                         "(command/script/select/camera) so steps are watchable; 0 = off")
    ap.add_argument("-v", "--verbose", action="store_true")
    ARGS = ap.parse_args()

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    if ARGS.launch and not launch_vibe():
        sys.exit(1)

    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.listen), Handler)
    print(f"proxy listening on :{ARGS.listen}  ->  vibe3d :{ARGS.target}"
          f"  (smooth={'on' if ARGS.smooth else 'off'}, "
          f"cmd-delay={ARGS.cmd_delay:.0f}ms)", flush=True)
    try:
        srv.serve_forever()
    finally:
        cleanup()

if __name__ == "__main__":
    main()
