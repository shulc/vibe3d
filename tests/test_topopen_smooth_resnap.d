// Topology Pen P8 — smooth_resnap (T1/T2, doc/topopen_p8_smooth_plan.md
// "Testing Strategy").
//
// T1 (the CONFIRMED crux): one Shift+Ctrl+LMB click relaxes the whole
// primary mesh AND re-snaps every relaxed vertex onto the background
// surface — a per-vertex NEAREST-POINT re-snap, not a camera-ray query.
// Rig: a sphere background + a 3-vertex triangle patch [A,B,C] in the
// primary layer, engineered so the middle vertex B is EQUIDISTANT from its
// two neighbors A/C (both placed ON the sphere) — this makes the
// inverse-edge-length-weighted relax target and the plain (uniform)
// neighbor mean IDENTICAL, so this test's expected value is
// weight-law-independent (T4, elsewhere, isolates the weight-law question
// on its own irregular rig).
//
// T2: primary AND background topology (vertex/edge/face counts) stay
// exactly unchanged — Smooth is Position-only, zero delta.
//
// Run via: ./run_test.d topopen_smooth_resnap

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs;
import std.format : format;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.thread : Thread;
import core.time   : dur;

void main() {}

/// Poll `/api/play-events/status` until `finished`, WITHOUT the fixed
/// ~120ms settle `waitPlayerIdle()` adds afterward (CLAUDE.md flake note
/// #3 — that settle exists to avoid a 1-2-frame-stale READ immediately
/// after "finished", an unrelated concern to what the perf DoD below is
/// bounding). Used ONLY to scope the StopWatch to the gesture's own
/// server-side latency; every data read in this file still goes through
/// the real `waitPlayerIdle()` afterward for correctness.
void waitFinishedNoSettle() {
    for (int i = 0; i < 500; ++i) {
        auto s = getJson("/api/play-events/status");
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.false_) return;   // done — mirrors waitPlayerIdle's own check
        Thread.sleep(dur!"msecs"(2));
    }
    assert(false, "play-events did not finish within ~1s");
}

enum uint SHIFT_CTRL = 0x0001 | 0x0040;   // KMOD_LSHIFT | KMOD_LCTRL — the Smooth gesture's own chord
enum float R   = 2.0f;
// Deliberately COARSER than the ray-based place tests' LON=96/LAT=72
// (topopen_place_helpers.d) — this test's re-snap goes through
// `closestPointOnMeshes` (a brute-force NEAREST-POINT search, not a
// ray-triangle hit), whose facet-sagitta error is smaller at a given
// resolution than the ray tests' discretization concern, and REV1 FIX-3's
// perf DoD pins the background at "≤ ~5k faces" — LON=48/LAT=36 keeps
// `facetTol` below comfortably valid (see the assertion below) while
// keeping this file's own perf measurement inside the pinned-rig envelope.
enum int   LON = 48, LAT = 36;            // faces = 1728, vertices = 1682 (bg)

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }

string trianglePatchBody(Vec3 a, Vec3 b, Vec3 c) {
    return format(
        `{"vertices":[[%.6f,%.6f,%.6f],[%.6f,%.6f,%.6f],[%.6f,%.6f,%.6f]],"faces":[[0,1,2]]}`,
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
}

unittest {
    setupSphereBg(R, LON, LAT);

    // A/C on the sphere; B equidistant from both (sqrt(1+1+25)=sqrt(27) to
    // EACH), so inverse-edge-length weighting and the uniform mean agree —
    // this rig isolates the re-snap crux from the weight-law question.
    Vec3 A = Vec3(R, 0, 0);
    Vec3 C = Vec3(0, R, 0);
    Vec3 B = Vec3(1.0f, 1.0f, 5.0f);

    auto lr = postJson("/api/command", commandBody("scene.loadMesh", trianglePatchBody(A, B, C)));
    assert(lr["status"].str == "ok", "load-mesh (triangle patch) failed: " ~ lr.toString);
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1,
        "setup: primary layer must be the untouched 1-triangle patch");

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");

    // ONE click (down+up at the same pixel) -> exactly 1 pass. Smooth has
    // NO source pick (whole-primary-mesh scope), so the pixel itself is
    // arbitrary — the gesture never rays-casts to find a starting element.
    //
    // REV1 FIX-3 perf DoD instrumentation: the StopWatch spans ONLY the
    // dispatch + server-side processing of the gesture itself
    // (`waitFinishedNoSettle`, no fixed sleep) — NOT the extra ~120ms
    // settle `waitPlayerIdle()` adds afterward purely to dodge a
    // 1-2-frame-stale READ (CLAUDE.md flake note #3), an orthogonal
    // test-harness concern unrelated to the gesture's own cost. The
    // correctness reads below still go through the real `waitPlayerIdle()`.
    auto sw = StopWatch(AutoStart.yes);
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, cx, cy, 0, SHIFT_CTRL, 1));
    waitFinishedNoSettle();
    sw.stop();
    auto elapsedMs = sw.peek.total!"msecs";
    import std.stdio : writefln;
    writefln("[perf] topoPen Smooth (1 pass, 3v primary / %d v bg) took %d ms",
        vertexCountLayer(0), elapsedMs);
    assert(elapsedMs < 250, format("Smooth DoD: one gesture on the pinned rig must finish "
        ~ "within ~250ms (REV1 FIX-3); took %d ms", elapsedMs));

    waitPlayerIdle();   // the harness's own settle, for the correctness reads below

    // T2: topology delta = 0 (both layers).
    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT), "bg vertex count must be unchanged");
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1,
        "Smooth must never change PRIMARY topology (zero delta)");

    auto post = readVerticesLayer(1);
    Vec3 bAfter = toVec3(post[1]);

    Vec3 chordMean = (A + C) * 0.5f;
    double chordNorm = sqrt(cast(double)dot(chordMean, chordMean));
    assert(chordNorm < cast(double)R - 0.3,
        format("setup: the raw relax target must be strictly INSIDE the sphere; |mean|=%f", chordNorm));

    double bAfterNorm = sqrt(cast(double)dot(bAfter, bAfter));
    enum double facetTol = R * 0.04;   // sphere-facet-sagitta tolerance, topopen_place_helpers.d convention
    assert(abs(bAfterNorm - cast(double)R) < facetTol,
        format("the smoothed vertex must land ON the bg surface (|B_after|~=R=%f); got |B_after|=%f",
               cast(double)R, bAfterNorm));

    Vec3 moveDir = bAfter - B;
    assert(dot(moveDir, moveDir) > 0.01f, "the smoothed vertex must have actually moved");

    Vec3 towardMean = chordMean - B;
    assert(dot(moveDir, towardMean) > 0,
        "the smoothed vertex must move TOWARD the raw relax target's lateral direction (proves it is "
      ~ "the re-snapped point, not an unrelated displacement)");
}
