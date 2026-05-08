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
# Each entry: (label, start_x, start_y, dx, dy, step_px)
EXPERIMENTS = [
    # baseline (default step_px=20)
    ("step20_100r",      1020, 560,  100,    0,  20),
    # step-size sweep at fixed total drag — the formula
    # `world = c × 10 × N × (N+1)` predicts:
    #   step=10 (N=10) → world ≈ 14.49  (4× more than step=20)
    #   step=20 (N=5)  → world ≈ 3.95
    #   step=40 (N=2)  → world ≈ 0.79   (5× less)
    #   step=50 (N=2)  → world ≈ 0.79   (same N)
    #   step=100(N=1)  → world ≈ 0.26   (single event)
    # If the theory holds, we'll see this scaling. If MODO scales by
    # total pixels (not event-count), all four would give same world.
    ("step10_100r",      1020, 560,  100,    0,  10),
    ("step40_100r",      1020, 560,  100,    0,  40),
    ("step50_100r",      1020, 560,  100,    0,  50),
    ("step100_100r",     1020, 560,  100,    0, 100),
    # also: same N=10 different drag length to disentangle px from N
    ("step5_50r",        1020, 560,   50,    0,   5),    # N=10, total=50px
    ("step20_200r",      1020, 560,  200,    0,  20),    # N=10, total=200px
]


def case_json(label, start_x, start_y, dx, dy, step_px,
              tool="move", pattern="single_top"):
    return {
        "tool":      tool,
        "pattern":   pattern,
        "acen_mode": "auto",
        "drag":      [start_x, start_y, dx, dy],
        "step_px":   step_px,
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
            label, sx, sy, dx, dy, step = ex
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
                    "step":   step,
                    "N":      max(abs(dx), abs(dy)) // step or 1,
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
    print(f"{'label':<18} {'drag':<14} {'step':>5} {'N':>4} "
          f"{'world':<28} {'|w|':>8} {'predict':>8}")
    print("-" * 100)
    for r in rows:
        if "status" in r and r["status"] != "PASS":
            print(f"{r['label']:<18} ERROR: {r.get('msg', '?')}")
            continue
        sx, sy, dx, dy = r["px"]
        d  = r["delta"]
        N  = r["N"]
        # Theory: world ≈ c × 10 × N × (N+1), c ≈ 0.01317.
        pred = 0.01317 * 10 * N * (N + 1)
        print(f"{r['label']:<18} +({dx:4d},{dy:4d})  {r['step']:>5} {N:>4} "
              f"({d[0]:+7.2f},{d[1]:+7.2f},{d[2]:+7.2f}) "
              f"{r['w_len']:>8.3f} {pred:>8.3f}")

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
