// Task 1530, Ф-1 — the live SCALE drain evaluates the tool pipe against the run
// BASELINE, not against the geometry it wrote on the previous frame.
//
// Rotate always passed `samplePipeFromBaseline=true`; scale was the only live
// bank that did not, so any action centre DERIVED FROM GEOMETRY was recomputed
// each frame from the vertices the scale had just moved. That is a first-order
// affine recurrence in the PIVOT — `p_{n+1} = S·C0 + (I−S)·p_n` — divergent
// once |1−s| > 1. The geometry itself never compounds (`applyTRS` restores the
// baseline every frame and `run.s` is run-absolute), so the pivot was the whole
// accumulator.
//
// THE ORACLE IS SUBDIVISION-INDEPENDENCE, and it needs no golden. The scale
// magnitude is POSITIONAL: `dragScaleScalarDelta += (dxRel·sdx + dyRel·sdy)/slen2`
// with `sdx/sdy/slen2` frozen at drag start, so the sum over a drag telescopes
// and the same pixel distance gives the same factor whether it arrives in 4
// events or 40. The geometry therefore MUST match. Any difference between the
// two is per-frame accumulation, and after Ф-1 the only per-frame accumulator
// left in this path was the pivot.
//
// WHY THE FALLOFF IS NOT DECORATION. With uniform weights a scale about its own
// centre leaves that centre a fixed point, so the live and the frozen pivot
// predict the SAME constant and the cell is inert — this is the trap the task
// card names, and it is not hypothetical: the sibling golden row
// `scale_autoNoFalloff` in tests/test_acen_pin_characterization.d stayed green
// through Ф-1 for exactly this reason while `scale_autoFalloff` moved by 0.0111.
// A radial linear falloff makes the per-vertex factors differ, the weighted
// centroid stops being a fixed point, and the loop engages.
//
// MUTATION: drop `/*samplePipeFromBaseline=*/true` from the scale drain's
// `applyTRS(dragBaseline, …)` in source/tools/transform/xfrm_transform.d
// (the `activeDrag is scaleSub && scaleDragActive` branch). Measured divergence
// under that mutation is recorded at the bottom of this file.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.format : format;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
JSONValue pj(string p, string b) { return parseJSON(cast(string) post(BASE ~ p, b)); }
JSONValue gj(string p)           { return parseJSON(cast(string) get(BASE ~ p)); }
void settle() { import core.thread : Thread; import core.time : msecs; Thread.sleep(150.msecs); }
void cmd(string c) { pj("/api/command", c); }

Vec3 evalPivot() {
    auto c = gj("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float) c[0].floating, cast(float) c[1].floating,
                cast(float) c[2].floating);
}

double[][] modelVerts() {
    double[][] o;
    foreach (v; gj("/api/model")["vertices"].array) {
        auto a = v.array;
        o ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return o;
}

// One +X scale-handle drag of `mag` pixels, delivered in `steps` motion events.
// Same grab recipe as tests/test_acen_pin_characterization.d's scenario E.
double[][] scaleDragWithSteps(int steps, double mag = 80.0) {
    pj("/api/reset", "");
    settle();
    cmd("tool.set TransformScale");
    cmd("tool.pipe.attr actionCenter mode auto");
    // Non-uniform weights — see the header. Centre the falloff at a cube corner
    // so the gradient runs ACROSS the mesh along the dragged axis.
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
    cmd(`tool.pipe.attr falloff size "2,2,2"`);
    settle();

    auto before = modelVerts();
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    int gx, gy; double ux, uy;
    axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy,
                             gx + cast(int)(mag * ux), gy + cast(int)(mag * uy),
                             steps));
    settle();
    auto after = modelVerts();

    // Positive control, per drag: a missed handle grab leaves the mesh untouched
    // and would make the two runs agree TRIVIALLY — the failure mode that turns
    // this whole cell green for the wrong reason.
    bool moved = false;
    foreach (i; 0 .. after.length)
        foreach (k; 0 .. 3)
            if (fabs(after[i][k] - before[i][k]) > 1e-4) moved = true;
    assert(moved, format("steps=%d: the +X scale handle drag moved nothing — "
                       ~ "the grab missed, so this run carries no signal", steps));
    cmd("tool.set TransformScale off");
    settle();
    return after;
}

unittest {
    auto coarse = scaleDragWithSteps(4);
    auto fine   = scaleDragWithSteps(40);

    assert(coarse.length == fine.length && coarse.length > 0,
        "both runs must return the same mesh");

    double worst = 0;
    size_t wi = 0, wk = 0;
    foreach (i; 0 .. coarse.length)
        foreach (k; 0 .. 3) {
            double d = fabs(coarse[i][k] - fine[i][k]);
            if (d > worst) { worst = d; wi = i; wk = k; }
        }

    assert(worst <= 1e-5,
        format("the same %g-pixel scale drag delivered in 4 events and in 40 "
             ~ "must produce the SAME geometry — the magnitude is positional "
             ~ "and telescopes. Worst difference %.9g at vertex %d component "
             ~ "%d (4-step %.9g, 40-step %.9g). A difference here is per-frame "
             ~ "accumulation in the PIVOT: the scale drain is sampling the tool "
             ~ "pipe from its own previous output instead of from the run "
             ~ "baseline.", 80.0, worst, wi, wk, coarse[wi][wk], fine[wi][wk]));
}

// ---------------------------------------------------------------------------
// MEASURED under the named mutation (drop `samplePipeFromBaseline=true` from
// the scale drain), so the tolerance above is not a guess:
//
//   Total: 1  Passed: 0  Failed: 1
//   test_acen_run_pivot_freeze.d(121): the same 80-pixel scale drag delivered
//   in 4 events and in 40 must produce the SAME geometry ... Worst difference
//   0.001889 at vertex 0 component 0 (4-step -0.663109, 40-step -0.66122).
//
// 0.001889 is 189x this cell's 1e-5 tolerance, so the signal is not marginal.
// It is also the same order as the independent evidence from the sibling
// golden row `scale_autoFalloff_afterDrag`, which Ф-1 moved by 0.0111 over a
// longer drag — two instruments, one purpose-built and one pre-existing,
// agreeing that the drift is real and O(1e-3..1e-2) on an 80-pixel gesture.
// ---------------------------------------------------------------------------
