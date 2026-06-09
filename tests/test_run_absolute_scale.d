// P-F Phase 3a — Scale run-absolute panel value (single-field mechanism (c)).
//
// Scale is the clean increment: per-axis factors multiply and COMMUTE, so this
// mirrors the landed Move pilot (test_pf_move_pin.d) verbatim. The cases:
//
//   (a) BARE-WRITE ABSOLUTE contract (mirrors test_reevaluate scale value-edit):
//       a live `tool.attr scale SX v` write lands at exactly base*v (Scale
//       1-anchor), and a SECOND write is ABSOLUTE (base*v2, never v1*v2). The
//       write field IS the apply field; at IDLE the derived factor equals the
//       written absolute. STAYS GREEN through every phase.
//
//   (b) RUN-ABSOLUTE panel display (the Phase-3a FLIP): two same-bank Scale gizmo
//       gestures (+X, mouse-up, +X again) -> the published SX
//       (/api/toolpipe/eval transform.scale[0]) accumulates the RUN TOTAL factor
//       across gestures (g1*g2, NOT just gesture-2's factor), and the geometry
//       matches base*SX (no double-apply / no half).
//
//   (c) IN-SESSION Ctrl+Z steps the run-absolute scale back ONE gesture (the
//       per-gesture headlessScale undo hook drives the reverted GEOMETRY); redo
//       restores it.
//
//   (d) CROSS-BANK: a held Scale survives a Move drag, AND the cross-bank GPU
//       assert — after a committed Scale gesture, a Move drag's GEOMETRY is
//       correct (the Scale own-bank fast-path drops out; Move drops to CPU when a
//       held scale is non-identity), never double-applied.
//
//   (e) RELOCATE -> SX resets to 1.0 (G8 relocate->1, via resetRun()).
//
// Discipline: selectV6 (no select-undo drain), hermetic baseline via reset +
// history.clear (never drainHistory after /api/reset, which is undoable), gizmo
// gestures via drag_helpers.buildDragLog + /api/play-events with the mandatory
// ~120ms settle, vec3 attrs double-quoted, published values read off
// /api/toolpipe/eval (never the raw panel struct), geometry off /api/model with
// count-keyed settle.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, PI, cos, sin;
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
bool vertNear(double[3] a, double[3] b, double tol = 1e-2) {
    return fabs(a[0]-b[0]) < tol && fabs(a[1]-b[1]) < tol && fabs(a[2]-b[2]) < tol;
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
        postJson("/api/script", "tool.set scale off");
        postJson("/api/script", "tool.set TransformScale off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Do NOT drainHistory() after /api/reset: SceneReset is itself undoable
        // and its revert() restores the PRE-reset (prior test's dirty) mesh, so
        // a drain-after-reset can leave a standing entry that reverts geometry
        // to a stale state (the -j1 cross-test-bleed flake). history.clear is a
        // SideEffect command: it wipes BOTH stacks WITHOUT touching the mesh, so
        // the cube stays pristine AND undo=0.
        postJson("/api/reset", "");                 // cube
        postJson("/api/command", "history.clear");  // wipe stacks, keep the cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
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

// Published run-absolute SX off /api/toolpipe/eval's P-F transform block.
double publishedSX() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block (no transform tool active?): "
        ~ j.toString);
    return (*t)["scale"].array[0].floating;
}
double publishedTX() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    return (*t)["translate"].array[0].floating;
}

// +X single-axis scale handle grab pixel + screen-space +X direction (shares the
// +X projection with the move arrow; verbatim from test_run_consolidation.d).
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}
// +X move arrow grab pixel + screen-space +X direction (verbatim shape).
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                 out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// One ON-handle +X Scale gesture against the CURRENT pivot, verify-and-retry on
// the UNDO COUNT (a missed grab records nothing -> retry; a hit records one
// in-session entry -> stop). Returns v6's post-gesture position.
double[3] scaleGestureOnHandle(long wantCount, double mag = 70.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int x1, y1; double ux, uy;
        axisGrabPx(evalPivot(), vp, x1, y1, ux, uy);
        int xb = x1 + cast(int)(mag * ux);
        int yb = y1 + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, xb, yb, 12));
        settle();
        if (undoCount() == wantCount) break;
    }
    return vert(6);
}

// One +X Scale gesture via the AXIS-BOX HEAD on the COMPOSED (compact) Transform
// preset. In compact presentation the wrapper resolves a click on the +X axis
// BOX (at size*AXIS_BOX_DISTANCE, the axis END) to the Scale bank via
// hitTestAxisHeads (xfrm_transform.d:904-908), even though the move arrow SHAFT
// (mid-axis) on the same axis belongs to Move. So grabbing the axis-END box
// routes to Scale, the move shaft to Move — the clean cross-bank separation.
// Drag outward (+X) to grow the axis factor. Verify-and-retry on the UNDO COUNT
// AND a positive SX (so a stray Move steal does not satisfy the gate).
// AXIS_BOX_DISTANCE = 1.18 (handler.d).
double[3] scaleGestureViaAxisBox(long wantCount, double mag = 80.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        Vec3 piv = evalPivot();
        float size = gizmoSize(piv, vp);
        float bx, by;          // the +X axis box (head) screen position
        projectToWindow(Vec3(piv.x + size * 1.18f, piv.y, piv.z), vp, bx, by);
        // screen-space +X direction for the drag.
        float s0x, s0y, s1x, s1y;
        projectToWindow(Vec3(piv.x + size / 6.0f, piv.y, piv.z), vp, s0x, s0y);
        projectToWindow(Vec3(piv.x + size,         piv.y, piv.z), vp, s1x, s1y);
        double dx = s1x - s0x, dy = s1y - s0y;
        double len = sqrt(dx*dx + dy*dy);
        double ux = dx / len, uy = dy / len;
        int x1 = cast(int)bx, y1 = cast(int)by;
        int xb = x1 + cast(int)(mag * ux), yb = y1 + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, xb, yb, 12));
        settle();
        if (undoCount() == wantCount && publishedSX() > 1.0 + 1e-3) break;
    }
    return vert(6);
}

// ---------------------------------------------------------------------------
// (a) BARE-WRITE ABSOLUTE — STAYS GREEN through every P-F phase.
//
// A live `tool.attr scale SX v` write lands on headlessScale.x (the Param
// pointee); reEvaluate replays from the run baseline reading it ABSOLUTELY (Scale
// 1-anchor). At IDLE the derived factor equals the written absolute, so a second
// write is absolute (base*v2, not v1*v2). Unchanged under Phase 3a.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set, scale pivot at the origin (selecting
    // only v6 would put the pivot AT v6, so an axis scale would not move it —
    // mirrors test_reevaluate's scale value-edit setup).
    cmd("tool.set TransformScale");

    long undoBefore = undoCount();

    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "beginSession opens session, scales nothing");

    cmd("tool.attr TransformScale SX 2");
    assertVertex(6, 1.0, 0.5, 0.5, "first live attr write scales x by 2 -> 0.5*2");

    cmd("tool.attr TransformScale SX 3");
    assertVertex(6, 1.5, 0.5, 0.5,
        "second live attr write is ABSOLUTE (x3, not x6): 0.5*3");

    cmd("tool.set TransformScale off");
    assert(undoCount() == undoBefore + 1,
        "live-session attr edits coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores the original");
    cmd("tool.set TransformScale off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (b) RUN-ABSOLUTE panel display — the P-F Phase-3a FLIP.
//
// Two same-bank Scale gizmo gestures (+X, mouse-up, +X again): the published SX
// accumulates the RUN TOTAL factor (g1*g2), NOT just gesture-2's factor (the
// pre-3a behaviour, where beginRunGesture(Scale) re-baked + zeroed the field).
// AND the geometry matches base*SX (the frozen run baseline + full run-absolute
// factor compose to exactly the run total — no double-scale, no half).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set, scale pivot at the origin centroid so
    // a +X axis scale grows v6.x from 0.5 (selecting v6 alone would pin the pivot
    // AT v6 and the axis scale would not move it).
    cmd("tool.set scale");            // default ACEN = None
    long floor = undoCount();

    scaleGestureOnHandle(floor + 1);
    assert(undoCount() == floor + 1, "gesture 1 records ONE in-session entry");
    double g1Sx = publishedSX();
    assert(g1Sx > 1.0 + 1e-3,
        "gesture 1 produced a published SX > 1; got " ~ g1Sx.to!string);
    auto v6AfterG1 = vert(6);

    scaleGestureOnHandle(floor + 2);
    assert(undoCount() == floor + 2,
        "gesture 2 records a SECOND in-session entry in the same run");
    double sxAfterG2 = publishedSX();
    auto v6AfterG2 = vert(6);

    // GEOMETRY accumulated (v6 grew further along +X across the two gestures).
    assert(v6AfterG2[0] > v6AfterG1[0] + 1e-3,
        "geometry accumulates across the two gestures: v6.x after g2 ("
        ~ v6AfterG2[0].to!string ~ ") must exceed after g1 ("
        ~ v6AfterG1[0].to!string ~ ")");

    // RUN-ABSOLUTE display: SX after gesture 2 is the RUN TOTAL factor, strictly
    // GREATER than gesture-1's factor alone (gesture 2 multiplied a > 1 factor on
    // top). Pre-3a this published only gesture-2's factor.
    assert(sxAfterG2 > g1Sx + 1e-3,
        "P-F Phase 3a: the published SX after gesture 2 is the RUN TOTAL factor "
        ~ "(g1*g2), strictly greater than gesture 1's SX. g1Sx=" ~ g1Sx.to!string
        ~ " sxAfterG2=" ~ sxAfterG2.to!string);

    // GEOMETRY = base * the published run-absolute SX (acen=None, +X axis scale
    // about the origin pivot: v6.x = 0.5 * SX). Proves no double-apply against the
    // frozen run baseline. (Pivot is None-mode selection centroid; for the single
    // v6 selection the +X axis scale grows v6.x from 0.5 by the run factor.)
    assert(fabs(v6AfterG2[0] - (0.5 * sxAfterG2)) < 2e-2,
        "geometry matches the published run-absolute SX (no double-apply): v6.x="
        ~ v6AfterG2[0].to!string ~ " expected 0.5 * SX = "
        ~ (0.5 * sxAfterG2).to!string);

    cmd("tool.set scale off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (c) IN-SESSION Ctrl+Z steps ONE Scale gesture back; the run-absolute field hook
//     drives the GEOMETRY revert; redo restores it.
//
// Two same-bank Scale gestures -> published SX = run total. An in-session Ctrl+Z
// (keyboard chokepoint, tool LIVE) pops gesture 2 and the GEOMETRY reverts to
// post-gesture-1 — driven by the per-gesture headlessScale undo hook. Per the
// Move case-c lesson the GEOMETRY (not the re-baselined accumulator) is asserted.
// Redo restores the run-end geometry.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set, pivot at the origin centroid.
    cmd("tool.set scale");
    long floor = undoCount();

    auto v6G1 = scaleGestureOnHandle(floor + 1);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    double g1Sx = publishedSX();

    scaleGestureOnHandle(floor + 2);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    double sxBoth = publishedSX();
    auto v6Both = vert(6);
    assert(sxBoth > g1Sx + 1e-3, "run total exceeds gesture 1 alone");

    // In-session Ctrl+Z pops gesture 2 -> GEOMETRY reverts to post-gesture-1 (the
    // run-absolute headlessScale undo hook fed applyTRS the gesture-START field).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(6), v6G1),
        "in-session Ctrl+Z reverts the geometry to post-gesture-1 (run-absolute "
        ~ "field hook drove applyTRS); v6 expected (" ~ v6G1[0].to!string ~ ","
        ~ v6G1[1].to!string ~ "," ~ v6G1[2].to!string ~ ") got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");

    // Redo re-applies gesture 2 -> back to the both-drags geometry.
    playAndWait(ctrlShiftZ(60.0));
    settle();
    assert(vertNear(vert(6), v6Both),
        "redo restores the run-end (both-drags) geometry; v6 expected ("
        ~ v6Both[0].to!string ~ "," ~ v6Both[1].to!string ~ ","
        ~ v6Both[2].to!string ~ ") got (" ~ vert(6)[0].to!string ~ ","
        ~ vert(6)[1].to!string ~ "," ~ vert(6)[2].to!string ~ ")");

    cmd("tool.set scale off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (d) CROSS-BANK: a held Scale survives a Move drag, AND the cross-bank GPU
//     assert (the (c)-specific double-apply guard).
//
// On the bare Transform preset (T=R=S), a Scale gizmo gesture leaves a run-
// absolute SX held. A subsequent MOVE arrow drag in the same wrapper session:
//   * must NOT clear the held SX (the published SX survives the Move gesture);
//   * GEOMETRY must be correct — the Move drag moves the (already-scaled) mesh by
//     the move delta, NOT double-applying the held scale. After a committed Scale
//     gesture the GPU buffer != the frozen run baseline (runGpuBufferDirty), so
//     the Move fast-path drops to CPU (heldScale non-identity) and the Scale
//     own-bank fast-path would drop too. We verify the post-Move geometry equals
//     the post-Scale geometry shifted by the +X move delta (read via /api/model).
//
// NO selection ⇒ whole-mesh moving set, pivot at the origin so both move geometry.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set Transform");        // T=R=S
    long floor = undoCount();

    // Scale gesture via the +X axis-BOX head: on the compact composed preset the
    // axis-END box routes to the Scale bank (hitTestAxisHeads), while the move
    // arrow SHAFT on the same axis routes to Move — clean cross-bank separation.
    // Records one in-session entry. Whole-mesh +X axis scale about the origin.
    scaleGestureViaAxisBox(floor + 1);
    assert(undoCount() == floor + 1, "scale gesture records one in-session entry");
    double sxHeld = publishedSX();
    assert(sxHeld > 1.0 + 1e-3,
        "scale gesture left a held run-absolute SX > 1; got " ~ sxHeld.to!string);
    auto v6AfterScale = vert(6);

    // Now a MOVE +X arrow drag in the SAME wrapper session. The cross-bank GPU
    // path: held scale non-identity -> Move drops to CPU, geometry correct.
    settle();
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    int xa, ya; double ux, uy;
    arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();

    // The held SX SURVIVES the Move gesture (cross-bank hold through one fold).
    double sxAfterMove = publishedSX();
    assert(fabs(sxAfterMove - sxHeld) < 2e-2,
        "a Move gesture must NOT clear the held Scale run-absolute SX (cross-bank "
        ~ "hold): held=" ~ sxHeld.to!string ~ " after Move=" ~ sxAfterMove.to!string);

    // CROSS-BANK GPU geometry assert: the Move moved v6 by exactly the published
    // run-absolute TX along +X (the held scale is NOT re-applied a second time).
    // The Y/Z stay at their post-scale values (the move was pure +X). This is the
    // double-apply guard: a buffer != baseline fast-path would re-scale here.
    double txMove = publishedTX();
    assert(txMove > 1e-3, "the Move gesture produced a positive TX; got "
        ~ txMove.to!string);
    auto v6AfterMove = vert(6);
    assert(fabs(v6AfterMove[0] - (v6AfterScale[0] + txMove)) < 3e-2,
        "cross-bank GPU: v6.x after the Move == post-scale x + TX (no re-scale); "
        ~ "post-scale x=" ~ v6AfterScale[0].to!string ~ " TX=" ~ txMove.to!string
        ~ " got " ~ v6AfterMove[0].to!string);
    assert(fabs(v6AfterMove[1] - v6AfterScale[1]) < 3e-2
        && fabs(v6AfterMove[2] - v6AfterScale[2]) < 3e-2,
        "cross-bank GPU: the +X Move leaves v6.y/z at their post-scale values "
        ~ "(no spurious re-scale); post-scale yz=(" ~ v6AfterScale[1].to!string
        ~ "," ~ v6AfterScale[2].to!string ~ ") got (" ~ v6AfterMove[1].to!string
        ~ "," ~ v6AfterMove[2].to!string ~ ")");

    cmd("tool.set Transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (e) RELOCATE -> SX resets to 1.0 (G8).
//
// In None mode an off-gizmo click is an allowed relocate = a geometry-run
// boundary. After a Scale gesture (SX > 1), the relocate boundary calls
// resetRun() which resets the run-absolute scale field, so the published SX
// returns to 1.0 (display follows the geometry re-baseline). The committed
// gesture's geometry stays put.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set, pivot at the origin centroid.
    cmd("tool.set scale");            // default ACEN = None (relocate allowed)
    long floor = undoCount();

    scaleGestureOnHandle(floor + 1);
    assert(undoCount() == floor + 1, "gesture records one in-session entry");
    assert(publishedSX() > 1.0 + 1e-3, "the gesture left a run-absolute SX > 1");
    auto v6AfterGesture = vert(6);

    // Off-gizmo relocate click (well off every handle): a hard run boundary.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    int xa, ya; double ux, uy;
    axisGrabPx(evalPivot(), vp, xa, ya, ux, uy);
    int xoff = cast(int)(xa + 220.0 * uy);
    int yoff = cast(int)(ya - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    assert(fabs(publishedSX() - 1.0) < 2e-2,
        "the relocate boundary resets the run-absolute SX to 1.0 (G8 relocate->1); "
        ~ "got " ~ publishedSX().to!string);
    // The committed gesture's geometry is untouched by the relocate.
    assert(vertNear(vert(6), v6AfterGesture),
        "the relocate does not move the committed gesture's geometry; v6=("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ") expected (" ~ v6AfterGesture[0].to!string
        ~ "," ~ v6AfterGesture[1].to!string ~ "," ~ v6AfterGesture[2].to!string ~ ")");

    cmd("tool.set scale off");
    drainHistory();
}
