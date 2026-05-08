#!/usr/bin/env python3
"""Probe MODO's xfrm.move drag-to-world formula via controlled
experiments. For each (drag_start, drag_offset) combination:

  1. Boot MODO with a fixed camera (tests/event_logs aren't used —
     MODO's default startup camera is reproducible).
  2. Build cube + select top face + actr.auto + xfrm.move.
  3. Mouse-drag the specified pixels.
  4. Read post-drag verts; compute world delta of the moved face.
  5. Tabulate (drag pixels, world delta, |world_delta| / |pixel_delta|).

The goal is to find what the world/px ratio depends on:
  - drag start pixel (workplane intersection depth changes per click) ?
  - drag direction (horizontal vs vertical, off-axis) ?
  - drag length (linear in pixels, or sublinear) ?

If the ratio is constant in `drag_length`, we have a calibration knob.
If it varies with drag_start, MODO uses a depth-dependent formula.

Usage:
  ./drag_formula_experiment.py
"""
import importlib.util
import json
import math
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

# Experimental drag matrix.  Each entry: (label, start_x, start_y, dx, dy)
# Click start varied across screen quadrants; drag varied in length and
# direction.  Camera stays at MODO default startup camera throughout.
EXPERIMENTS = [
    # base case for sanity (matches our existing 100-px right drag)
    ("baseline_100r",    1020, 560,  100,    0),
    # length sweep at same start
    ("len_50r",          1020, 560,   50,    0),
    ("len_200r",         1020, 560,  200,    0),
    ("len_400r",         1020, 560,  400,    0),
    # direction sweep at same start
    ("dir_down_100",     1020, 560,    0,  100),
    ("dir_diag_100",     1020, 560,   71,   71),  # ≈ 100 px
    ("dir_left_100",     1020, 560, -100,    0),
    # start position sweep (workplane intersection depth varies)
    ("start_top_100r",    700, 200,  100,    0),  # high in screen → far ws hit
    ("start_bot_100r",    700, 800,  100,    0),  # low in screen → near ws hit
    ("start_center_100r", 713, 487,  100,    0),  # viewport center
]


def case_json(label, start_x, start_y, dx, dy, tool="move", pattern="single_top"):
    return {
        "tool":      tool,
        "pattern":   pattern,
        "acen_mode": "auto",
        "drag":      [start_x, start_y, dx, dy],
        "_experiment": label,
    }


# Pre-drag top-face verts (cube radius 0.5).
TOP_PRE = [
    (-0.5, 0.5, -0.5),
    (-0.5, 0.5,  0.5),
    ( 0.5, 0.5, -0.5),
    ( 0.5, 0.5,  0.5),
]


def world_delta(state, result):
    """Find the rigid translation MODO applied to the cube top face.
    State is the pre-drag state.json (has `before` and
    `selected_verts`); result is post-drag result.json (`verts`).
    Pair-by-position breaks down when two faces overlap after a drag
    (e.g. top moved down to bottom plane), so instead we identify the
    four post-verts whose positions match `before \\ selected_verts`
    (the UNMOVED bottom face) — the remaining four post-verts are the
    moved top face. Their average position − selected_verts average
    is the rigid-translation delta."""
    before = [tuple(v) for v in state["before"]]
    sel    = set((round(v[0], 4), round(v[1], 4), round(v[2], 4))
                  for v in state["selected_verts"])
    untouched_pre = [v for v in before
                     if (round(v[0], 4), round(v[1], 4), round(v[2], 4))
                            not in sel]
    posts = [tuple(v) for v in result["verts"]]

    # Mark which post verts match an untouched pre (within TOL).
    TOL = 0.01
    untouched_post = set()
    for u in untouched_pre:
        for j, p in enumerate(posts):
            if j in untouched_post: continue
            if all(abs(p[i] - u[i]) < TOL for i in range(3)):
                untouched_post.add(j); break
    moved = [posts[j] for j in range(len(posts))
             if j not in untouched_post]
    if not moved:
        return None
    pre_avg  = tuple(sum(v[i] for v in state["selected_verts"]) /
                     len(state["selected_verts"]) for i in range(3))
    post_avg = tuple(sum(v[i] for v in moved) / len(moved) for i in range(3))
    return tuple(post_avg[i] - pre_avg[i] for i in range(3))


def main():
    spec = importlib.util.spec_from_file_location(
        'rad', str(SCRIPT_DIR / "run_acen_drag.py"))
    rad = importlib.util.module_from_spec(spec); spec.loader.exec_module(rad)

    rad.cleanup_all_displays()
    rad.copy_scripts()
    w = rad.Worker(0)
    rows = []
    try:
        w.boot()
        # Persist case JSONs in a scratch dir so worker.run_case can read them.
        scratch = Path("/tmp/drag_formula_cases")
        scratch.mkdir(exist_ok=True)
        for ex in EXPERIMENTS:
            label, sx, sy, dx, dy = ex
            spec_d = case_json(*ex)
            case_path = scratch / f"{label}.json"
            case_path.write_text(json.dumps(spec_d, indent=2))
            try:
                status, msg = w.run_case(case_path)
            except Exception as e:
                status, msg = "ERROR", repr(e)
            if status == "PASS":
                # Read MODO post-drag verts.
                state  = json.loads(
                    (w.tmpdir / "modo_drag_state.json").read_text())
                result = json.loads(
                    (w.tmpdir / "modo_drag_result.json").read_text())
                d = world_delta(state, result)
                if d is None:
                    print(f"  {label}: no top verts found")
                    continue
                px_len = math.sqrt(dx*dx + dy*dy)
                w_len  = math.sqrt(sum(c*c for c in d))
                ratio  = w_len / px_len if px_len > 0 else 0
                cam = state.get("camera", {})
                rows.append({
                    "label":  label,
                    "px":     (sx, sy, dx, dy),
                    "delta":  d,
                    "px_len": px_len,
                    "w_len":  w_len,
                    "ratio":  ratio,
                    "cam":    cam,
                })
            else:
                rows.append({"label": label, "status": status, "msg": msg})
    finally:
        try: w.shutdown()
        except: pass

    # Print results.
    print()
    print("=== drag formula experiment results ===")
    print()
    print(f"{'label':<22} {'pixel drag':<22} {'world delta':<32} "
          f"{'|d|':>8} {'|w|':>8} {'w/px':>10}")
    print("-" * 110)
    for r in rows:
        if "status" in r and r["status"] != "PASS":
            print(f"{r['label']:<22} ERROR: {r.get('msg', '?')}")
            continue
        sx, sy, dx, dy = r["px"]
        d = r["delta"]
        print(f"{r['label']:<22} ({sx:4d},{sy:4d}) +({dx:4d},{dy:4d})  "
              f"({d[0]:+8.3f},{d[1]:+8.3f},{d[2]:+8.3f})  "
              f"{r['px_len']:>8.1f} {r['w_len']:>8.3f} {r['ratio']:>10.5f}")

    # Print camera if available (from any successful row).
    for r in rows:
        if "cam" in r and r["cam"].get("eye"):
            cam = r["cam"]
            print()
            print(f"camera: eye={cam['eye']} fwd={cam['fwd']} "
                  f"focus={cam['center']} d={cam['distance']:.3f} "
                  f"bounds={cam['bounds']}")
            break


if __name__ == "__main__":
    sys.exit(main() or 0)
