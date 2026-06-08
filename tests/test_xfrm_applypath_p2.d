// Apply-path unification Phase 2 — behavior-change tests.
//
// Phase 2 routes the LIVE multi-bank Transform drag through the composed
// MS-4 fold (applyFold) instead of the deleted single-bank applyTRSForBank
// shim, from ONE run baseline. These tests pin the two behaviour changes
// that ship with that rewire:
//
//   (1) LIVE gizmo move-then-rotate (and rotate-then-move) in ONE session
//       produce ORDER-INDEPENDENT composed geometry — the held bank flows
//       into the fold from the original baseline, not via a per-gesture mesh
//       re-baseline. Pre-Phase-2 the live path was order-DEPENDENT (a rotate
//       gesture re-dup'd its baseline off the already-translated mesh).
//
//   (2) PANEL multi-bank (tool.attr TX then RZ, both non-identity, session
//       open) followed by a MID-SESSION falloff change re-grades the COMPOSED
//       op (full-fold T·R), not translate-only. This is the ARM-1 re-grade
//       site (xfrm_transform.d, "ARM 1 — panel session"), which has NO
//       currentRunBank gate, so it was the one ungated behaviour change. The
//       full-fold value is the reference-faithful re-grade.
//
// Both run against unchanged production assumptions otherwise; the contract
// test test_xfrm_fold_multibank.d (headless S·R·T) stays green alongside.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3] vAt(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

bool replayIdle() {
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;
}

// Deactivate any stray tool, drain in-flight replay + undo, reset the cube,
// re-drain, verify the pristine cube. Mirrors the drainAndReset discipline
// used by the sibling transform tests (cross-test bleed guard: the runner
// reuses ONE vibe3d per worker across its whole slice).
void drainAndReset() {
    foreach (attempt; 0 .. 8) {
        postJson("/api/command", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        foreach (_; 0 .. 100) {
            if (undoCount() == 0) break;
            postJson("/api/undo", "");
        }
        postJson("/api/reset", "");
        foreach (_; 0 .. 100) {
            if (undoCount() == 0) break;
            postJson("/api/undo", "");
        }
        auto v = vAt(6);
        if (approxEq(v[0], 0.5) && approxEq(v[1], 0.5) && approxEq(v[2], 0.5))
            return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
}

void selectAll8() {
    auto r = postJson("/api/select",
        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

// Bare Transform preset, no falloff / no symmetry, pivot pinned at the WORLD
// ORIGIN (ACEN.Origin). Origin removes the per-frame pivot-drift confound of
// ACEN.Auto (whose bbox centre moves as the mesh deforms), so a move-then-
// rotate and a rotate-then-move sequence fold S·R·T about the SAME fixed point
// and the order-independence assertion is exact, not approximate.
void setupTransformOriginAll() {
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr actionCenter mode origin");
    cmd("tool.pipe.attr axis mode auto");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.pipe.attr symmetry enabled false");
    selectAll8();
}

// ---------------------------------------------------------------------------
// (1) LIVE gizmo multi-bank order independence (the first test exercising the
//     live multi-bank fold). Drive a MOVE arrow/centre drag then a ROTATE ring
//     drag in ONE session; record the result. Reset, drive the SAME two pixel
//     drags in the OPPOSITE order in ONE session. Under the composed fold the
//     held bank flows in from the run baseline (NOT a per-gesture re-baseline),
//     so the two orderings must produce IDENTICAL geometry (composeFor folds a
//     fixed S·R·T regardless of gesture order). Pre-Phase-2 these diverged.
// ---------------------------------------------------------------------------
double[3][8] runMoveThenRotate() {
    drainAndReset();
    setupTransformOriginAll();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    // Pivot is the world origin (ACEN.Origin); project it for the screen grabs.
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(0, 0, 0);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy));

    // Leg A: centre-grab MOVE (screen-plane translate).
    string moveLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  cast(int)cx, cast(int)cy,
                                  cast(int)cx + 80, cast(int)cy, 20);
    playAndWait(moveLog);

    // Leg B: ring-grab ROTATE (offset from centre to land on a ring).
    string rotLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 cast(int)cx + 95, cast(int)cy,
                                 cast(int)cx + 95, cast(int)cy - 70, 20);
    playAndWait(rotLog);

    double[3][8] outv;
    foreach (i; 0 .. 8) outv[i] = vAt(i);
    cmd("tool.set Transform off");
    return outv;
}

double[3][8] runRotateThenMove() {
    drainAndReset();
    setupTransformOriginAll();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    drag_helpers.Vec3 pivot = drag_helpers.Vec3(0, 0, 0);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy));

    // Leg B first: ring-grab ROTATE.
    string rotLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 cast(int)cx + 95, cast(int)cy,
                                 cast(int)cx + 95, cast(int)cy - 70, 20);
    playAndWait(rotLog);

    // Leg A second: centre-grab MOVE.
    string moveLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  cast(int)cx, cast(int)cy,
                                  cast(int)cx + 80, cast(int)cy, 20);
    playAndWait(moveLog);

    double[3][8] outv;
    foreach (i; 0 .. 8) outv[i] = vAt(i);
    cmd("tool.set Transform off");
    return outv;
}

unittest {
    auto mr = runMoveThenRotate();
    auto rm = runRotateThenMove();

    // Sanity: the composed op actually moved the mesh (both legs non-trivial),
    // so the order-independence assert is not vacuously comparing two pristine
    // cubes. At least one vertex must differ from pristine.
    bool moved = false;
    immutable double[3][8] CUBE = [
        [-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
        [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]];
    foreach (i; 0 .. 8)
        foreach (k; 0 .. 3)
            if (!approxEq(mr[i][k], CUBE[i][k], 1e-3)) moved = true;
    assert(moved, "move-then-rotate produced a pristine cube — drags did not "
        ~ "land on the gizmo; cannot assert order independence vacuously");

    // The reference-faithful result: gesture ORDER does not change the final
    // composed geometry. The held bank flows into the fold from the run
    // baseline, so move-then-rotate == rotate-then-move to float tolerance.
    foreach (i; 0 .. 8)
        foreach (k; 0 .. 3)
            assert(approxEq(mr[i][k], rm[i][k], 2e-3),
                "live multi-bank order independence: v" ~ i.to!string
                ~ " component " ~ k.to!string
                ~ " move-then-rotate=" ~ mr[i][k].to!string
                ~ " rotate-then-move=" ~ rm[i][k].to!string);

    drainAndReset();
}

// ---------------------------------------------------------------------------
// (2) PANEL multi-bank + mid-session falloff = full-fold ARM-1 re-grade.
//
// Open a Transform session via tool.beginSession, write TX then RZ (both
// non-identity, no falloff). With all 8 verts selected about the ORIGIN, the
// composed T·R fold has a known closed form. Then change the falloff
// mid-session: with falloff type=none → linear (or any setting whose weight is
// still 1.0 for every selected vertex inside the support), the ARM-1 re-grade
// re-runs the FULL fold (T·R) — under Phase 2 it must NOT collapse to a
// translate-only re-grade (which would drop the held RZ). We verify the held
// rotate SURVIVES the falloff re-grade by checking the post-falloff geometry
// still matches the composed T·R (not T-only).
//
// A radial falloff centred at the origin with a LARGE size keeps every selected
// vertex at near-unit weight, so the re-grade is dominated by the composed op
// and the test reads the SHAPE of the re-grade (T·R vs T-only) rather than an
// exact magnitude. The assertion is "the rotated components survived" — the
// post-falloff geometry is far closer to the composed T·R than to a
// translate-only re-grade (which would drop the held RZ entirely).
// ---------------------------------------------------------------------------

// Expected composed T·R of a cube vertex about the origin for TX=0.5, RZ=90°.
//   T: +X by 0.5         (x+0.5, y, z)
//   R: RZ=90 about origin (x,y)->(-y,x)
double[3] expectedTR(double[3] v) {
    double tx = v[0] + 0.5, ty = v[1], tz = v[2];
    double rx = -ty, ry = tx, rz = tz;
    return [rx, ry, rz];
}
// Expected TRANSLATE-ONLY (the pre-Phase-2 ARM-1 re-grade that DROPPED the
// held rotate). Used only to prove the new result is NOT this.
double[3] expectedTOnly(double[3] v) {
    return [v[0] + 0.5, v[1], v[2]];
}

immutable double[3][8] CUBE2 = [
    [-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
    [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]];

unittest {
    drainAndReset();
    setupTransformOriginAll();

    // Open a live session so the subsequent tool.attr hits the already-live
    // reEvaluate() branch (panel-session, editIsOpen() true → ARM-1 path).
    cmd("tool.beginSession Transform");

    // Panel multi-bank: TX then RZ, both non-identity. editIsOpen() stays true
    // (the panel/attr path never zeroes the held translate).
    cmd("tool.attr Transform TX 0.5");
    cmd("tool.attr Transform RZ 90");

    // Pre-falloff: the composed T·R must already hold (the headless multi-bank
    // contract; here via the live panel path).
    foreach (vi; 0 .. 8) {
        auto got = vAt(vi);
        auto want = expectedTR(CUBE2[vi]);
        foreach (k; 0 .. 3)
            assert(approxEq(got[k], want[k]),
                "pre-falloff panel T·R: v" ~ vi.to!string ~ " comp "
                ~ k.to!string ~ " got " ~ got[k].to!string
                ~ " want " ~ want[k].to!string);
    }

    // MID-SESSION falloff change → fires the ARM-1 re-grade. Radial falloff
    // centred at the origin with a large size keeps every selected vertex at
    // near-unit weight, so the re-grade is dominated by the composed op. The
    // change vs the prior `none` packet is what triggers ARM-1.
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0,0,0"`);
    cmd(`tool.pipe.attr falloff size "40,40,40"`);

    // Settle the re-grade (it runs on the next update tick).
    foreach (_; 0 .. 20) {
        if (replayIdle()) break;
        Thread.sleep(10.msecs);
    }
    Thread.sleep(60.msecs);

    // Post-falloff: under Phase 2 full-fold the held RZ SURVIVED. For each
    // vertex whose composed T·R differs from a translate-only re-grade (the
    // rotated components), the post-falloff geometry must be FAR closer to T·R
    // than to T-only — i.e. the rotate was re-weighted, not dropped. Pre-Phase-2
    // the ARM-1 re-grade was translate-only and would land on T-only.
    double distTR = 0, distTOnly = 0, sepTotal = 0;
    foreach (vi; 0 .. 8) {
        auto got = vAt(vi);
        auto wantTR    = expectedTR(CUBE2[vi]);
        auto wantTOnly = expectedTOnly(CUBE2[vi]);
        double dTR = 0, dTOnly = 0, sep = 0;
        foreach (k; 0 .. 3) {
            dTR    += (got[k] - wantTR[k])    * (got[k] - wantTR[k]);
            dTOnly += (got[k] - wantTOnly[k]) * (got[k] - wantTOnly[k]);
            sep    += (wantTR[k] - wantTOnly[k]) * (wantTR[k] - wantTOnly[k]);
        }
        distTR += dTR; distTOnly += dTOnly; sepTotal += sep;
    }
    // The T·R vs T-only separation must be non-trivial (rotate is real).
    assert(sepTotal > 0.1,
        "test setup: T·R and T-only must differ materially; sep^2="
        ~ sepTotal.to!string);
    // Post-falloff geometry sits on the composed T·R, NOT translate-only.
    assert(distTR < distTOnly * 0.1,
        "ARM-1 re-grade dropped the held rotate (translate-only): dist^2 to "
        ~ "T·R=" ~ distTR.to!string ~ " dist^2 to T-only=" ~ distTOnly.to!string
        ~ " — Phase 2 full-fold must keep the rotate");

    cmd("tool.set Transform off");
    drainAndReset();
}
