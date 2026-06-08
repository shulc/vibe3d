// P-F Phase 0 — invariant pin (NO behavior change).
//
// Locks the CURRENT Move semantics numerically BEFORE the run-absolute flip, so
// every later Phase-2 flip is provable:
//
//   (a) BARE-WRITE ABSOLUTE contract (mirrors test_reevaluate Test 1b-absolute):
//       a live `tool.attr move TX v` write lands at exactly baseline+v, and a
//       SECOND write is absolute (baseline+v2, never v1+v2). This is the apply
//       field the panel binds; P-F (single-field mechanism (c)) keeps it intact,
//       so this assert STAYS GREEN through every phase.
//
//   (b) CURRENT per-gesture panel display: two same-bank Move gizmo gestures ->
//       the published TX (/api/toolpipe/eval transform.translate.x) reads the
//       SECOND gesture's increment, NOT the run total. This is the BUG P-F fixes;
//       Phase 2 FLIPS this assert to the run-absolute total (timeline comment
//       below marks the flip).
//
// Discipline: selectV6 (no select-undo drain), drainHistory BEFORE reset, gizmo
// gestures via drag_helpers.buildDragLog + /api/play-events with the mandatory
// ~120ms settle, vec3 attrs double-quoted, published values read off
// /api/toolpipe/eval (never the raw panel struct).

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.string : format;

import drag_helpers;

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
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}
long undoCount() { return getJson("/api/history")["undo"].array.length; }

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}
void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

bool replayIdle() {
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;
}

double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}
void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vert(idx);
    assert(fabs(v[0]-x) < 1e-3 && fabs(v[1]-y) < 1e-3 && fabs(v[2]-z) < 1e-3,
        label ~ ": v" ~ idx.to!string ~ " expected (" ~ x.to!string ~ ","
        ~ y.to!string ~ "," ~ z.to!string ~ "), got (" ~ v[0].to!string ~ ","
        ~ v[1].to!string ~ "," ~ v[2].to!string ~ ")");
}

void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();            // BEFORE the reset (/api/reset is undoable)
        postJson("/api/reset", "");
        drainHistory();            // AFTER the reset
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

void selectV6() {
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    settle();
    auto s = getJson("/api/selection");
    assert(s["mode"].str == "vertices"
        && s["selectedVertices"].array.length == 1
        && s["selectedVertices"].array[0].integer == 6,
        "v6 selection did not take: " ~ s.toString);
}

// Authoritative gizmo pivot from the evaluated ActionCenterPacket.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Published run-absolute TX off /api/toolpipe/eval's P-F transform block.
double publishedTX() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block (no transform tool active?): "
        ~ j.toString);
    return (*t)["translate"].array[0].floating;
}

void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
}
void arrowDirPx(Vec3 pivot, ref Viewport vp, out double ux, out double uy) {
    import std.math : sqrt;
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// One ON-handle +X Move gesture against the CURRENT pivot, verify-and-retry on
// the UNDO COUNT (a missed grab records nothing -> retry; a hit records one
// in-session entry -> stop). Returns v6's post-gesture position.
double[3] moveGestureOnHandle(long wantCount, double dir = 1.0, double mag = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        arrowDirPx(evalPivot(), vp, ux, uy);
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya);
        int xb = xa + cast(int)(dir * mag * ux);
        int yb = ya + cast(int)(dir * mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) break;
    }
    return vert(6);
}

// ---------------------------------------------------------------------------
// (a) BARE-WRITE ABSOLUTE — STAYS GREEN through every P-F phase.
//
// The live-session `tool.attr move TX v` write lands on headlessTranslate.x (the
// Param pointee), reEvaluate() replays from the run baseline reading it
// ABSOLUTELY. P-F mechanism (c) keeps write field == apply field, and at IDLE the
// derived in-gesture delta equals the written absolute (gestureStartSnapshot ==
// identity), so this contract is unchanged.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();                       // v6 = (0.5, 0.5, 0.5)
    cmd("tool.set move");

    long undoBefore = undoCount();

    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "beginSession opens session, moves nothing");

    cmd("tool.attr move TX 0.05");
    assertVertex(6, 0.55, 0.5, 0.5, "first live attr write lands at +0.05");

    cmd("tool.attr move TX 0.10");
    assertVertex(6, 0.60, 0.5, 0.5,
        "second live attr write is ABSOLUTE (+0.10, not 0.15)");

    cmd("tool.set move off");
    assert(undoCount() == undoBefore + 1,
        "live-session attr edits coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores the original");
    cmd("tool.set move off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (b) CURRENT per-gesture panel display — the BUG P-F fixes.
//
// Two same-bank Move gizmo gestures (drag +X, mouse-up, drag +X again). TODAY
// beginRunGesture(Move) case A re-bakes the prior move into dragBaseline and
// zeroes headlessTranslate at the SECOND gesture's mouse-down, so after gesture 2
// the published TX holds ONLY gesture-2's increment — NOT the run total of both
// gestures. We pin that buggy relationship:
//
//   * after gesture 1: published TX == g1Tx (> 0).
//   * after gesture 2: published TX is roughly g2's increment, and is STRICTLY
//     LESS than g1Tx + g2's increment (it does NOT accumulate the run total).
//
// >>> Phase 2 FLIPS this: the field stops being zeroed per gesture, so the
// >>> published TX becomes the run-absolute SUM (g1Tx + g2Tx). The Phase-2 test
// >>> (test_run_absolute_move) asserts the flipped value; this assert is removed
// >>> / inverted there. <<<
//
// The GEOMETRY (v6) accumulates correctly in BOTH worlds (the run-end mesh is the
// same); only the DISPLAYED scalar differs. So we read TX off the published eval
// block, not geometry.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
    cmd("tool.set move");             // default ACEN = None
    long floor = undoCount();

    // Gesture 1: +X haul. Published TX = this gesture's basis-local translate.
    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records ONE in-session entry");
    double g1Tx = publishedTX();
    assert(g1Tx > 1e-3,
        "gesture 1 produced a positive published TX; got " ~ g1Tx.to!string);
    auto v6AfterG1 = vert(6);

    // Gesture 2: re-grab the moved handle and haul +X again. With the CURRENT
    // per-gesture re-baseline-and-zero, the published TX after gesture 2 holds
    // ONLY gesture-2's increment.
    moveGestureOnHandle(floor + 2, +1.0);
    assert(undoCount() == floor + 2,
        "gesture 2 records a SECOND in-session entry in the same run");
    double g2Tx = publishedTX();
    auto v6AfterG2 = vert(6);

    // GEOMETRY accumulated (v6 moved further along +X across the two gestures).
    assert(v6AfterG2[0] > v6AfterG1[0] + 1e-3,
        "geometry accumulates across the two gestures: v6.x after g2 ("
        ~ v6AfterG2[0].to!string ~ ") must exceed after g1 ("
        ~ v6AfterG1[0].to!string ~ ")");

    // CURRENT BUG (Phase 2 flips this to g1Tx + g2increment): the published TX
    // after gesture 2 is NOT the run total. It is strictly less than g1Tx + g2's
    // own increment, because the field was zeroed at gesture-2 start. We assert
    // the per-gesture (non-accumulating) display: TX after g2 is well below the
    // run total it WOULD hold if it accumulated.
    //
    // Run-total lower bound: if the field accumulated, TX would be >= g1Tx
    // (gesture 1 alone) PLUS gesture 2's positive increment, i.e. clearly > g1Tx.
    // The current per-gesture value is just gesture-2's increment, which (same
    // re-grabbed handle, same +X mag) is on the order of g1Tx, NOT g1Tx + more.
    assert(g2Tx < g1Tx + g1Tx - 1e-3,
        "Phase 2 flips this to run-absolute: TODAY the published TX after gesture "
        ~ "2 holds only gesture-2's increment (per-gesture display), NOT the run "
        ~ "total g1Tx+g2Tx. g1Tx=" ~ g1Tx.to!string ~ " g2Tx(published)="
        ~ g2Tx.to!string ~ " — expected < ~2*g1Tx (well below the accumulated "
        ~ "run total).");

    cmd("tool.set move off");
    drainHistory();
}
