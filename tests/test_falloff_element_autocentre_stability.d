// test_falloff_element_autocentre_stability.d — task 0724 / audit-4 P9.
//
// P9 put `FalloffPacket.pickedCenter` into the refire trigger
// (`falloffPacketsEqual`, Element-gated) so that relocating the element
// sphere's centre re-grades a live preview. That fix carries a hazard the
// other trigger inputs do not have, and this file exists to pin the hazard
// shut rather than to argue it away.
//
// Every OTHER input to that trigger is config the user typed and left alone.
// `pickedCenter` is ACEN's centre, and in a centroid mode with NO pin that
// centre is DERIVED FROM THE GEOMETRY the tool is deforming. So the trigger
// owns an input its own re-grade can move:
//
//     centre C_n  ->  re-grade weights the mesh around C_n  ->  the deformed
//     mesh has centroid C_n+1  ->  trigger sees C_n+1 != C_n  ->  re-grade...
//
// The GESTURE half of this is handled at the commit chokepoint
// (`buildGestureHooks` re-baselines the snapshot to the settled centre, which
// is what keeps test_relocate_boundary_element and friends green). The PANEL
// half — ARM 1, `editIsOpen()` true, driven by `tool.attr` with no gizmo
// gesture and therefore no commit — has no such chokepoint, so it is the arm
// where a feedback loop would actually show up.
//
// The setup below is deliberately the worst case for that: element falloff
// with NO `userPlacedCenter`, so ACEN falls back to the selection centroid and
// the sphere centre is free to chase the deformation. A stable preview must
// reach a fixed point and STAY there; a creeping one is the loop.
//
// If this ever goes red, the fix is not to widen the tolerance: it is to
// re-baseline `dragFalloff.pickedCenter` after the ARM-1 re-grade the same way
// the gesture path re-baselines at commit.

import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}
void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}
double[3][] dumpVerts() {
    double[3][] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return vs;
}

// Largest per-component difference between two vertex dumps.
double maxDelta(double[3][] a, double[3][] b) {
    assert(a.length == b.length, "vertex count changed mid-observation");
    double worst = 0;
    foreach (i; 0 .. a.length)
        foreach (k; 0 .. 3) {
            double d = fabs(a[i][k] - b[i][k]);
            if (d > worst) worst = d;
        }
    return worst;
}

// ===========================================================================
// A live panel session with element falloff and an UNPINNED action centre
// must settle. Observed over several frame-times, the preview may not creep.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("tool.set Transform");   // the attr id below must name the ACTIVE tool
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.pipe.attr falloff dist 1.2");
    // Deliberately NO `actionCenter userPlacedCenter`: with no pin, ACEN
    // resolves the centre from the selection, i.e. from the geometry this
    // very falloff is about to deform. That is the configuration in which a
    // trigger that compares the centre could feed on its own output.
    cmd("tool.beginSession Transform");
    cmd("tool.attr Transform TX 0.5");
    settle();

    auto first = dumpVerts();
    // Several more frame-times with NOTHING driving the app. Any difference
    // here is the preview moving on its own.
    settle(); settle(); settle();
    auto later = dumpVerts();

    double drift = maxDelta(first, later);
    assert(drift < 1e-6,
        format("element falloff on an UNPINNED action centre must reach a "
             ~ "fixed point: the preview moved by %.9f over ~450ms of idle "
             ~ "with no input. That is the P9 feedback shape -- the refire "
             ~ "trigger comparing a centre that its own re-grade relocates. "
             ~ "See this file's header for the fix.", drift));

    // ---- Two liveness checks, because "nothing moved" is exactly what a
    // ---- vacuous version of this test would also report.

    // (1) The weighting is real: a TX of 0.5 through a 1.2 sphere must have
    //     displaced at least one vertex off the cube's rest x.
    auto rest = [-0.5, 0.5];
    bool anyMoved = false;
    foreach (v; later)
        if (fabs(v[0] - rest[0]) > 1e-4 && fabs(v[0] - rest[1]) > 1e-4)
            anyMoved = true;
    assert(anyMoved,
        "liveness: the panel TX must have moved at least one vertex off the "
        ~ "cube's rest x, or the stability assertion above is asserted over "
        ~ "an undeformed mesh and means nothing");

    // (2) The ARM-1 re-grade path is LIVE in this exact configuration --
    //     otherwise "the preview did not creep" would just be saying the
    //     preview is not being recomputed at all, which is a different fact
    //     and not the one this file claims. An idle `dist` edit is a config
    //     change, so the trigger must see it and re-grade.
    auto beforeDist = dumpVerts();
    cmd("tool.pipe.attr falloff dist 3.0");
    settle();
    auto afterDist = dumpVerts();
    assert(maxDelta(beforeDist, afterDist) > 1e-4,
        "liveness: widening `dist` at idle must re-grade the preview. If it "
        ~ "does not, the ARM-1 trigger never runs here and the stability "
        ~ "assertion above is inert -- it would pass on a frozen preview.");

    cmd("tool.set Transform off");
    postJson("/api/reset", "");
}
