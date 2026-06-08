// P-F Move pilot — run-absolute panel display (single-field mechanism (c)).
//
// Pinned at Phase 0 (invariant pin), FLIPPED at Phase 2 (the Move run-absolute
// change). The cases:
//
//   (a) BARE-WRITE ABSOLUTE contract (mirrors test_reevaluate Test 1b-absolute):
//       a live `tool.attr move TX v` write lands at exactly baseline+v, and a
//       SECOND write is absolute (baseline+v2, never v1+v2). The write field IS
//       the apply field; at IDLE the derived in-gesture delta equals the written
//       absolute, so this STAYS GREEN through every phase.
//
//   (b) RUN-ABSOLUTE panel display (Phase-2 FLIP): two same-bank Move gizmo
//       gestures -> the published TX (/api/toolpipe/eval transform.translate.x)
//       accumulates the RUN TOTAL across gestures (NOT just the 2nd gesture's
//       increment), and the geometry matches base+TX (no double-apply).
//
//   (c) IN-SESSION Ctrl+Z steps the run-absolute TX back ONE gesture (the per-
//       gesture headlessTranslate undo hook); redo restores it.
//
//   (d) CROSS-BANK: a held Move TX survives a panel RZ edit on the Transform
//       preset (held banks compose through one fold from one frozen baseline).
//
//   (e) RELOCATE -> TX resets to 0 (G8 relocate->0, via resetRun()).
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

// SDL Ctrl+Z keystroke -> handleKeyDown -> navHistory(true). 122='z', mod 64 =
// KMOD_LCTRL. Drives the in-session keyboard chokepoint (NOT /api/undo).
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}
// SDL Ctrl+Shift+Z keystroke -> navHistory(false) (redo). mod 65 = LCTRL|LSHIFT.
string ctrlShiftZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n",
        t, t + 10.0);
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
// (b) RUN-ABSOLUTE panel display — the P-F Phase-2 FLIP (the user's bug fixed).
//
// >>> PHASE-2 TIMELINE FLIP. The Phase-0 version of this case pinned the BUGGY
// >>> per-gesture display (the published TX after gesture 2 held ONLY gesture-2's
// >>> increment, because beginRunGesture(Move) re-baked + zeroed the field). With
// >>> Phase 2 the field stops being zeroed per gesture (single-field run-absolute
// >>> mechanism (c)), so the published TX now accumulates the RUN TOTAL. <<<
//
// Two same-bank Move gizmo gestures (drag +X, mouse-up, drag +X again):
//   * after gesture 1 the published TX == g1Tx (> 0);
//   * after gesture 2 the published TX == g1Tx + g2Tx (the run total) — NOT just
//     gesture-2's increment.
// AND the geometry is correct (v6 at base + run-total, never double-applied: the
// frozen run-start baseline + the full run-absolute field compose to exactly the
// run total).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
    cmd("tool.set move");             // default ACEN = None
    long floor = undoCount();

    // Gesture 1: +X haul. Published TX = this gesture's run-absolute translate.
    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records ONE in-session entry");
    double g1Tx = publishedTX();
    assert(g1Tx > 1e-3,
        "gesture 1 produced a positive published TX; got " ~ g1Tx.to!string);
    auto v6AfterG1 = vert(6);

    // Gesture 2: re-grab the moved handle and haul +X again. Run-absolute: the
    // field is NOT zeroed at gesture-2 start, so the published TX accumulates.
    moveGestureOnHandle(floor + 2, +1.0);
    assert(undoCount() == floor + 2,
        "gesture 2 records a SECOND in-session entry in the same run");
    double txAfterG2 = publishedTX();
    auto v6AfterG2 = vert(6);

    // GEOMETRY accumulated (v6 moved further along +X across the two gestures).
    assert(v6AfterG2[0] > v6AfterG1[0] + 1e-3,
        "geometry accumulates across the two gestures: v6.x after g2 ("
        ~ v6AfterG2[0].to!string ~ ") must exceed after g1 ("
        ~ v6AfterG1[0].to!string ~ ")");

    // RUN-ABSOLUTE display: TX after gesture 2 is the RUN TOTAL, strictly GREATER
    // than gesture-1's value alone (it added gesture-2's positive increment on
    // top). Pre-Phase-2 this was < ~g1Tx (per-gesture). The published TX must now
    // exceed g1Tx by a clear margin.
    assert(txAfterG2 > g1Tx + 1e-3,
        "P-F Phase 2: the published TX after gesture 2 is the RUN TOTAL "
        ~ "(accumulates across gestures), strictly greater than gesture 1's TX. "
        ~ "g1Tx=" ~ g1Tx.to!string ~ " txAfterG2=" ~ txAfterG2.to!string);

    // GEOMETRY = base + the published run-absolute TX (acen=None world +X axis:
    // v6.x = 0.5 + TX). Proves the run-absolute field is NOT double-applied
    // against the frozen run baseline.
    assert(fabs(v6AfterG2[0] - (0.5 + txAfterG2)) < 1e-2,
        "geometry matches the published run-absolute TX (no double-apply): v6.x="
        ~ v6AfterG2[0].to!string ~ " expected 0.5 + TX = "
        ~ (0.5 + txAfterG2).to!string);

    cmd("tool.set move off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (c) IN-SESSION Ctrl+Z steps ONE Move gesture back; the run-absolute field hook
//     drives the GEOMETRY revert; redo restores it.
//
// Two same-bank Move gestures -> published TX == run total. An in-session Ctrl+Z
// (keyboard chokepoint, tool LIVE) pops gesture 2 and the GEOMETRY reverts to
// post-gesture-1 — driven by the per-gesture headlessTranslate undo hook (the
// revert closure sets the field to the gesture-START run-absolute, which applyTRS
// re-applies). Redo restores the run-end geometry. This mirrors the GEOMETRY
// proof of test_run_consolidation case (E) (scale accumulator stepping); the
// published-accumulator value after the pop is NOT asserted because the in-session
// Ctrl+Z re-baselines the tool (closes the open run -> the field publishes
// relative to the new geometry baseline, the documented run-close behaviour).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
    cmd("tool.set move");
    long floor = undoCount();

    auto v6G1 = moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    double g1Tx = publishedTX();

    moveGestureOnHandle(floor + 2, +1.0);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    double txBoth = publishedTX();
    auto v6Both = vert(6);
    assert(txBoth > g1Tx + 1e-3, "run total exceeds gesture 1 alone");

    // In-session Ctrl+Z pops gesture 2 -> GEOMETRY reverts to post-gesture-1 (the
    // run-absolute headlessTranslate undo hook fed applyTRS the gesture-START
    // field). This is the (c)-specific proof: without the hook the field would
    // hold the run total and applyTRS would re-apply the both-drags transform.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(fabs(vert(6)[0] - v6G1[0]) < 1e-2,
        "in-session Ctrl+Z reverts the geometry to post-gesture-1 (run-absolute "
        ~ "field hook drove applyTRS); v6.x expected " ~ v6G1[0].to!string
        ~ " got " ~ vert(6)[0].to!string);

    // Redo re-applies gesture 2 -> back to the both-drags geometry (the apply
    // hook restores the gesture-END run-absolute field).
    playAndWait(ctrlShiftZ(60.0));
    settle();
    assert(fabs(vert(6)[0] - v6Both[0]) < 1e-2,
        "redo restores the run-end (both-drags) geometry; v6.x expected "
        ~ v6Both[0].to!string ~ " got " ~ vert(6)[0].to!string);

    cmd("tool.set move off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (d) CROSS-BANK: a held Move TX survives a panel RZ edit (Transform preset).
//
// On the bare Transform preset (T=R=S), a Move gizmo gesture leaves a run-
// absolute TX held; a subsequent panel RZ edit must NOT clear it — the published
// TX stays at the Move run total (held banks compose through one fold from one
// frozen run baseline).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set, pivot at the origin so the Move and
    // the rotate both move geometry.
    cmd("tool.set Transform");
    long floor = undoCount();

    // A Move arrow gesture in the same wrapper session (records one in-session
    // entry). moveGestureOnHandle re-grabs the +X arrow at the current pivot.
    moveGestureOnHandle(floor + 1, +1.0);
    double txHeld = publishedTX();
    assert(txHeld > 1e-3,
        "Move gesture left a positive held run-absolute TX; got "
        ~ txHeld.to!string);

    // Panel RZ edit (a value edit through the live seam — does not touch the
    // Move bank). The held TX must survive.
    cmd("tool.attr Transform RZ 30");
    settle();
    double txAfterRz = publishedTX();
    assert(fabs(txAfterRz - txHeld) < 1e-2,
        "a panel RZ edit must NOT clear the held Move run-absolute TX (cross-bank "
        ~ "hold): held=" ~ txHeld.to!string ~ " after RZ=" ~ txAfterRz.to!string);

    cmd("tool.set Transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (e) RELOCATE -> TX resets to 0 (G8).
//
// In None mode an off-gizmo click is an allowed relocate = a geometry-run
// boundary. After a Move gesture (TX > 0), the relocate boundary calls resetRun()
// which resets the run-absolute field, so the published TX returns to 0 (display
// follows the geometry re-baseline). The committed gesture's geometry stays put.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
    cmd("tool.set move");             // default ACEN = None (relocate allowed)
    long floor = undoCount();

    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture records one in-session entry");
    assert(publishedTX() > 1e-3, "the gesture left a positive run-absolute TX");
    auto v6AfterGesture = vert(6);

    // Off-gizmo relocate click (well off every handle): a hard run boundary.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xoff = cast(int)(xa + 220.0 * uy);
    int yoff = cast(int)(ya - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    assert(fabs(publishedTX()) < 1e-2,
        "the relocate boundary resets the run-absolute TX to 0 (G8 relocate->0); "
        ~ "got " ~ publishedTX().to!string);
    // The committed gesture's geometry is untouched by the relocate.
    assert(fabs(vert(6)[0] - v6AfterGesture[0]) < 1e-2,
        "the relocate does not move the committed gesture's geometry; v6.x="
        ~ vert(6)[0].to!string ~ " expected " ~ v6AfterGesture[0].to!string);

    cmd("tool.set move off");
    drainHistory();
}
