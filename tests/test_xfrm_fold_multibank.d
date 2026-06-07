// Headless multi-bank fold contract — Phase 0 + Phase 1 of the transform
// apply-path unification prerequisite plan.
//
// PURPOSE
// -------
// PIN the all-three-banks-simultaneous composed-fold contract HEADLESS: drive a
// `Transform`-preset op with Translate, Rotate, AND Scale all non-identity in
// ONE evaluate (via `tool.attr` + `tool.doApply`, NOT gizmo drags) and assert
// the resulting geometry equals the composed S·R·T fold computed from the known
// cube verts. This locks WHAT a later live-path rewire must preserve when it
// routes the live drag through the same fold. The test passes on UNCHANGED
// production code (it pins existing behavior — the panel / headless apply path
// ALREADY folds multi-bank today).
//
// =====================================================================
// PHASE 0 AUDIT FINDINGS (recorded here; the audit produced only this header)
// =====================================================================
//
// Step 1 — sequenced gizmo-then-gizmo multi-bank drags (two drag legs on
// DIFFERENT banks in one session, no `tool.set … off` between):
//   * FOUND ONE: tests/test_xfrm_transform.d (the "Bare Transform: rotate then
//     move must not re-apply the rotation" unittest). Under the bare `Transform`
//     preset it drives a ROTATE ring drag leg (start pixel `cx+95`) then a MOVE
//     centre-grab drag leg, both via buildDragLog/gizmo in one session. Its
//     asserts are RELATIVE, not absolute-composed: it checks the MOVE leg moved
//     v0 by >0.05 from its post-rotate position and translated v1/v2 by the SAME
//     delta (rigid translation of the post-rotate set). It does NOT pin a
//     progressive-mutation absolute value or a gesture ORDER. Classification: a
//     POTENTIAL flipper for a future live-path rewire (it is the only live
//     gizmo-then-gizmo multi-bank case), to be re-derived under the fold when
//     that rewire lands. It pins no value that a later phase must hold fixed
//     verbatim — its invariant (rigid translation of the moving set) is
//     preserved by an additive translate factor in the composed matrix. No
//     action this phase; flagged for the rewire phase.
//   * NO OTHER gizmo-then-gizmo multi-bank test exists. All other multi-leg
//     drag tests use SINGLE-mode presets (move / xfrm.elementMove /
//     TransformRotate / TransformScale) — each leg folds exactly one factor, so
//     no cross-bank composition exists within any run.
//
//   Pre-classified named tests (verified by reading the asserts):
//   * tests/test_relocate_boundary_crossslot.d — NO flip. Move leg = arrow
//     gizmo drag (single-bank translate, relative assert `v6.x>0.6`). Rotate leg
//     = `tool.attr Transform RZ 30` via `tool.beginSession` — the PANEL path
//     (already folds T·R today), assert is a DELTA (rotate moved v6 off
//     v6BeforeRot). Ctrl+Z asserts compare against RECORDED v6AfterRot / pristine
//     corner, never a computed S·R·T. No assert pins progressive-mutation order.
//   * tests/test_relocate_boundary_rs.d — NO flip. SINGLE-mode only
//     (TransformScale S-only, TransformRotate R-only). No cross-bank composition
//     within any run; each relocate-boundary second gesture is a fresh undo run
//     at the relocated pivot. Asserts compare against RECORDED v6Run1 / pristine.
//
// Step 1b — panel-multi-bank + mid-session falloff (the ungated re-grade path):
//   * NO current test pins a `Transform`-preset panel write of TWO non-identity
//     banks (e.g. TX then RZ) followed by a mid-session falloff change.
//     - tests/test_reevaluate.d (the combined T+R+S panel unittest) writes
//       TX/RZ/SX but has NO falloff change, and its asserts are relative
//       ("moved away from original"), not composed-absolute.
//     - tests/test_reevaluate.d (Test 4) has the only mid-session falloff change
//       but on a MOVE-ONLY preset (single bank).
//     - tests/test_rs_insession_cancel.d writes TX + RZ (panel multi-bank) but no
//       falloff change; its asserts are relative deltas / pristine restore.
//   * This panel-then-falloff combination is therefore a documented FUTURE test
//     target for the rewire phase (the ungated re-grade path), recorded here. No
//     action this phase.
//
// Step 2 — reference apply ORDER (S·R·T vs T·R·S): UNVERIFIED-pending-capture.
//   A live reference capture is DEFERRED. The composed matrix is S·R·T (T applied
//   first / rightmost, then R, then S, all about the pivot). The fold-invariant
//   fallback this phase relies on is gesture-ORDER independence: writing the
//   three bank attrs in any order produces the IDENTICAL composed geometry
//   (asserted below). That proves order-INDEPENDENCE, NOT that S·R·T is the
//   reference engine's chosen order. If a future capture contradicts S·R·T, that
//   correction belongs to the fold-math layer downstream, not to a routing
//   change — this fixture pins the CURRENT composed contract, whatever order it
//   embodies.
//
// =====================================================================
// PHASE 1 — headless multi-bank fold fixture
// =====================================================================
// Drive Translate + Rotate + Scale all non-identity simultaneously through the
// headless apply path (`tool.attr Transform TX/RZ/SX` + `tool.doApply`, which
// runs applyHeadless → applyTRS with the preset flags all true) and assert the
// composed result equals the manual S·R·T of the known cube verts.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import core.thread : Thread;
import core.time   : msecs;

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

double[3] vertexAt(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// True when no event-log replay is in flight (cross-test bleed guard; the
// runner reuses ONE vibe3d per worker across its whole slice).
bool replayIdle() {
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;
}

// Deactivate any stray tool, wait for in-flight replay, drain the undo stack,
// reset the cube, re-drain, and verify v6 = (0.5, 0.5, 0.5). Mirrors the
// drainAndReset discipline from test_reevaluate.d.
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
        auto v = vertexAt(6);
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

// Set up the bare Transform preset with no falloff / no symmetry / ACEN.Auto.
// With ALL 8 cube verts selected, the ACEN.Auto bbox centre is the ORIGIN, so
// the composed fold acts about (0,0,0) and the math is pivot = 0.
void setupTransformAllSelected() {
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr actionCenter mode auto");
    cmd("tool.pipe.attr axis mode auto");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.pipe.attr symmetry enabled false");
    selectAll8();
}

// Expected S·R·T of a cube vertex about the ORIGIN pivot, for the fixed
// fixture values TX=0.5, RZ=90°, SX=2.0 (R/S/T defaults elsewhere = identity).
//   T:  +X by 0.5            (v - 0) + (0.5,0,0)
//   R:  RZ=90° about origin  (x,y) -> (-y, x)   (z unchanged)
//   S:  SX=2 about origin    x *= 2
// Applied in the order T (rightmost), then R, then S — i.e. M = S·R·T, so the
// vertex flows T -> R -> S.
double[3] expectedSRT(double[3] v) {
    // T
    double tx = v[0] + 0.5, ty = v[1], tz = v[2];
    // R (RZ=90: x,y -> -y, x)
    double rx = -ty, ry = tx, rz = tz;
    // S (SX=2)
    double sx = rx * 2.0, sy = ry, sz = rz;
    return [sx, sy, sz];
}

// Pristine cube vertex positions (mesh.makeCube order).
immutable double[3][8] CUBE = [
    [-0.5, -0.5, -0.5], // 0
    [ 0.5, -0.5, -0.5], // 1
    [ 0.5,  0.5, -0.5], // 2
    [-0.5,  0.5, -0.5], // 3
    [-0.5, -0.5,  0.5], // 4
    [ 0.5, -0.5,  0.5], // 5
    [ 0.5,  0.5,  0.5], // 6
    [-0.5,  0.5,  0.5], // 7
];

// ---------------------------------------------------------------------------
// (1) Multi-bank composed-fold contract: T+R+S all non-identity in one evaluate
//     equals the manual S·R·T of every cube vertex.
//
//     This is the existing-behavior contract a later live-path rewire must
//     preserve: applyHeadless -> applyTRS composes one S·R·T matrix from the
//     three headless* fields gated by the preset flags (all true under
//     `Transform`). PASSES on unchanged production code.
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    setupTransformAllSelected();

    cmd("tool.attr Transform TX 0.5");
    cmd("tool.attr Transform RZ 90");
    cmd("tool.attr Transform SX 2.0");
    cmd("tool.doApply");

    foreach (vi; 0 .. 8) {
        auto got = vertexAt(vi);
        auto want = expectedSRT(CUBE[vi]);
        foreach (k; 0 .. 3)
            assert(approxEq(got[k], want[k]),
                "multi-bank S·R·T contract: v" ~ vi.to!string ~ " component "
                ~ k.to!string ~ " got " ~ got[k].to!string ~ " want "
                ~ want[k].to!string);
    }

    // Spot-pin v6 explicitly so a regression reads clearly:
    //   v6 = (0.5,0.5,0.5) -> T (1.0,0.5,0.5) -> R (-0.5,1.0,0.5) -> S (-1.0,1.0,0.5)
    auto v6 = vertexAt(6);
    assert(approxEq(v6[0], -1.0) && approxEq(v6[1], 1.0) && approxEq(v6[2], 0.5),
        "multi-bank S·R·T contract: v6 expected (-1.0, 1.0, 0.5); got ("
        ~ v6[0].to!string ~ "," ~ v6[1].to!string ~ "," ~ v6[2].to!string ~ ")");

    cmd("tool.set Transform off");
    drainAndReset();
}

// ---------------------------------------------------------------------------
// (2) Order independence (the fold-invariant fallback for the UNVERIFIED apply
//     order, Phase 0 step 2): writing the three bank attrs in the REVERSE order
//     (S, then R, then T) yields the IDENTICAL composed geometry. composeFor
//     composes a fixed S·R·T regardless of attr-write order, so attr ordering
//     must not change the result.
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    setupTransformAllSelected();

    // Reverse attr-write order vs. test (1).
    cmd("tool.attr Transform SX 2.0");
    cmd("tool.attr Transform RZ 90");
    cmd("tool.attr Transform TX 0.5");
    cmd("tool.doApply");

    foreach (vi; 0 .. 8) {
        auto got = vertexAt(vi);
        auto want = expectedSRT(CUBE[vi]);
        foreach (k; 0 .. 3)
            assert(approxEq(got[k], want[k]),
                "order-independence: reverse attr-write order must produce the "
                ~ "SAME composed geometry; v" ~ vi.to!string ~ " component "
                ~ k.to!string ~ " got " ~ got[k].to!string ~ " want "
                ~ want[k].to!string);
    }

    cmd("tool.set Transform off");
    drainAndReset();
}
