// A TOOL-LESS SELECT-DRAG, and the two channels it is the first witness for
// (task 0781 step 2d).
//
// Two gaps that doc/input_state_cluster_plan.md RECORDED rather than assumed
// green close here:
//
//   1. THE MOTION-PATH PICK. `InputRouter.handleMouseMotion` ends with a
//      `doSelectPickAt(mot.x, mot.y)` for the three Select drag modes, so a
//      drag picks on EVERY motion event instead of once per render frame.
//      Step 2c MEASURED that disabling that call left the whole hover/drag
//      family green: the hover-freeze and fresh-hover tests do emit motion
//      with the button held, but under an active haul tool the handler returns
//      at the tool's `onMouseMotion` ABOVE the pick branch, and their
//      assertions are satisfied by the mouse-DOWN handler's own pick. The
//      fixture that was missing — named in §6.3 — is exactly this one: NO
//      tool, a drag sweeping elements in one event batch, asserting an element
//      the sweep only passed THROUGH.
//
//   2. `pendingSelBefore`, the interactive-selection session's before-image
//      (step 2d moved it, with `beginInteractiveSelEdit` /
//      `commitInteractiveSelEdit`, into InputRouter). Its ONLY observable is
//      what an undo restores — and every pre-existing interactive-select
//      fixture builds its selection up from an EMPTY one of that type, so an
//      unwritten before-image and the true one restore the same thing and no
//      assertion can tell them apart. Undoing a click that REPLACED a
//      non-empty swept set is the case that separates them, and this file is
//      the only place in the suite that runs it.
//
// WHAT MAKES THE POSITIVE ASSERTION MEAN SOMETHING — two structural choices,
// both MEASURED here (2026-08-25), neither of them decoration.
//
// (a) THE TWO NEGATIVE CONTROLS. The sweep is built so that its two ENDPOINT
//     pixels select NOTHING (asserted, by clicking each of them) while its
//     MIDPOINT pixel selects one vertex (asserted, by clicking it). So a picker
//     that only ran at the press and at a hold-frame ends the gesture EMPTY:
//     the press pixel is empty space, and `EventPlayer` leaves the mouse
//     override at the LAST event it delivered, so a frame that renders during
//     the drag picks near the sweep's END — also empty space.
//
// (b) ONE EVENT BATCH — and this is the part `buildDragLog` cannot give. That
//     helper stamps its motions 50 ms apart precisely so each lands in its own
//     frame; `EventPlayer.tick` then delivers one event per frame and the
//     PER-FRAME picker walks the whole path on its own, covering for the
//     motion-path pick completely. Measured, both ways, on this very rig:
//     with 50 ms spacing the sweep selects [6, 11] whether or not
//     `handleMouseMotion`'s pick runs; with every event stamped at ONE
//     timestamp — `tick`'s `while (entries[idx].timeMs <= nowMs)` drains them
//     all into a single frame — it selects [6, 11] with the pick and NOTHING
//     without it. So the fixture builds its own log (`buildBatchLog` below)
//     rather than calling `buildDragLog`, and swapping back to the helper
//     would make this file green against the defect it exists to catch.
//
// The mesh is a ONCE-SUBDIVIDED cube, not the bare cube: on 8 corners every
// straight screen path touches at most its two endpoints, so the bare cube
// cannot exhibit the phenomenon at all.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : canFind, sort;
import std.array : array;

import drag_helpers; // fetchCamera / viewportFromCamera / projectToWindow /
                     // playAndWait / Vec3 (NOT buildDragLog — see (b) above)

void main() {}

void cmd(string body_) {
    auto resp = post(testBaseUrl() ~ "/api/command", body_);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "command failed: " ~ body_ ~ " -> " ~ resp);
}

int[] selectedVerts() {
    auto sel = parseJSON(cast(string)get(testBaseUrl() ~ "/api/selection"));
    int[] ids;
    foreach (v; sel["selectedVertices"].array) ids ~= cast(int)v.integer;
    ids.sort();
    return ids;
}

void resetSubdividedCube() {
    auto resp = post(testBaseUrl() ~ "/api/reset", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"mesh.subdivide"}`);
    cmd(`{"id":"history.clear"}`);
}

// DOWN + `steps` motions + UP, EVERY event stamped at the same millisecond so
// `EventPlayer.tick` drains the whole gesture in ONE frame. Deliberately not
// `drag_helpers.buildDragLog` — see (b) in the header for the measurement that
// makes the difference load-bearing. Same VIEWPORT header line, same event
// shapes, same linear interpolation; only the timestamps differ.
string buildBatchLog(int vpX, int vpY, int vpW, int vpH,
                     int x0, int y0, int x1, int y1, int steps) {
    import std.format : format;
    enum double kT = 1.0;   // one timestamp for the whole gesture
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        kT, x0, y0);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            kT, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        kT, x1, y1);
    return log;
}

// steps==1 is a click (one zero-delta motion), anything larger is a drag.
void gesture(int x0, int y0, int x1, int y1, int steps) {
    auto cam = fetchCamera();
    playAndWait(buildBatchLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, steps));
}

// The pixel the fixture pivots on: a point near the middle of the viewport
// that the PICKER can actually reach. Found by projecting every vertex and
// then CONFIRMING with a click, because a projected pixel is not evidence —
// the nearest-to-centre vertex on this mesh is a BACK-face one and its click
// selects nothing (measured, 2026-08-25). Returns the pixel and the vertex id
// the click there produced.
struct Pivot { int px, py, vid; }

Pivot findPivot() {
    auto cam  = fetchCamera();
    auto vp   = viewportFromCamera(cam);
    auto j    = parseJSON(cast(string)get(testBaseUrl() ~ "/api/model"));
    immutable int cx = cam.vpX + cam.width  / 2;
    immutable int cy = cam.vpY + cam.height / 2;

    struct Cand { int x, y; float d; }
    Cand[] cands;
    foreach (v; j["vertices"].array) {
        auto p = v.array;
        float px, py;
        if (!projectToWindow(Vec3(cast(float)p[0].floating,
                                  cast(float)p[1].floating,
                                  cast(float)p[2].floating), vp, px, py))
            continue;
        cands ~= Cand(cast(int)px, cast(int)py,
                      (px - cx) * (px - cx) + (py - cy) * (py - cy));
    }
    assert(cands.length > 8,
        "expected the subdivided cube's vertices to project; got "
        ~ cands.length.to!string);
    cands.sort!((a, b) => a.d < b.d);

    foreach (c; cands[0 .. cands.length < 12 ? cands.length : 12]) {
        resetSubdividedCube();
        gesture(c.x, c.y, c.x, c.y, 1);
        auto s = selectedVerts();
        if (s.length == 1) return Pivot(c.x, c.y, s[0]);
    }
    assert(false, "no pickable vertex among the 12 nearest the viewport centre "
                ~ "— the fixture cannot aim, so nothing below would mean anything");
}

unittest { // THE SWEEP: a select-drag collects what it passes THROUGH, and
           // neither of its endpoints can account for a single vertex of it.
    resetSubdividedCube();
    auto pivot = findPivot();
    auto cam   = fetchCamera();
    // Half-extents measured on this fixture (2026-08-25): a sweep of
    // ±(width/8, height/10) about the pivot runs from empty space, over the
    // pivot vertex, into empty space, collecting two vertices on the way.
    immutable int dx = cam.width  / 8;
    immutable int dy = cam.height / 10;
    immutable int x0 = pivot.px - dx, y0 = pivot.py - dy;
    immutable int x1 = pivot.px + dx, y1 = pivot.py + dy;

    // ---- NEGATIVE CONTROL 1: the sweep's START pixel is empty space.
    resetSubdividedCube();
    gesture(x0, y0, x0, y0, 1);
    auto atStart = selectedVerts();
    assert(atStart.length == 0,
        "control: a click at the sweep's START pixel (" ~ x0.to!string ~ ","
        ~ y0.to!string ~ ") must select nothing, got " ~ atStart.to!string
        ~ " — with a vertex there the sweep's result could come from the "
        ~ "mouse-DOWN pick alone and would prove nothing");

    // ---- NEGATIVE CONTROL 2: so is its END pixel, which is where the event
    // player parks the mouse override, i.e. where any hold-frame pick lands.
    resetSubdividedCube();
    gesture(x1, y1, x1, y1, 1);
    auto atEnd = selectedVerts();
    assert(atEnd.length == 0,
        "control: a click at the sweep's END pixel (" ~ x1.to!string ~ ","
        ~ y1.to!string ~ ") must select nothing, got " ~ atEnd.to!string
        ~ " — with a vertex there a hold-frame pick could account for the "
        ~ "sweep's result");

    // ---- THE SWEEP.
    resetSubdividedCube();
    gesture(x0, y0, x1, y1, 60);
    auto swept = selectedVerts();

    assert(swept.length > 0,
        "the 60-step select-drag selected NOTHING. Both endpoints are empty "
        ~ "space (asserted above) and the whole gesture arrives in ONE frame, "
        ~ "so the only picker that could have selected anything is the "
        ~ "per-motion one at the bottom of handleMouseMotion — this is exactly "
        ~ "what its absence looks like");
    assert(swept.canFind(pivot.vid),
        "the sweep passed straight over vertex " ~ pivot.vid.to!string
        ~ " at its MIDPOINT (a click on that pixel selects exactly that vertex)"
        ~ " but the selection is " ~ swept.to!string
        ~ " — the motion-path pick did not run over the middle of the drag");
}

unittest { // THE BEFORE-IMAGE: undoing a click restores the SWEPT SET.
           // The only assertion in the suite that reads `pendingSelBefore` by
           // value: everywhere else the before-image is empty, and an
           // unwritten one restores exactly the same thing.
    resetSubdividedCube();
    auto pivot = findPivot();
    auto cam   = fetchCamera();
    immutable int dx = cam.width  / 8;
    immutable int dy = cam.height / 10;

    resetSubdividedCube();
    gesture(pivot.px - dx, pivot.py - dy, pivot.px + dx, pivot.py + dy, 60);
    auto swept = selectedVerts();
    // TWO or more, and this is a SETUP requirement, not a claim about the
    // product: the click below re-selects the pivot vertex, so with a swept
    // set of exactly {pivot} the click would change nothing,
    // `commitInteractiveSelEdit` would record NO entry, and the undo below
    // would silently undo the SWEEP instead — passing for the wrong reason.
    assert(swept.length >= 2,
        "setup: the sweep must leave a multi-vertex selection for the click to "
        ~ "shrink; got " ~ swept.to!string);
    assert(swept.canFind(pivot.vid),
        "setup: the swept set must contain the pivot vertex; got "
        ~ swept.to!string);

    // BREAK THE COALESCING RUN, and this line is the reason the channel was
    // invisible for so long. P5 coalesces CONSECUTIVE interactive selects into
    // ONE undo entry, so the sweep and the click below would fold together and
    // the surviving entry's before-image would be the SWEEP's — empty. Undoing
    // it then restores nothing, whether or not the click's own before-image was
    // ever written. Clearing the history here (it touches no selection) makes
    // the click record a FRESH MeshSelectionEdit whose before-image is the
    // swept set, which is the only state in which this channel is observable.
    cmd(`{"id":"history.clear"}`);

    // A bare click REPLACES that set with one vertex (mouse-DOWN clears the
    // current mode's selection, then picks).
    gesture(pivot.px, pivot.py, pivot.px, pivot.py, 1);
    auto afterClick = selectedVerts();
    assert(afterClick == [pivot.vid],
        "the click must collapse the swept set to the pivot vertex alone; got "
        ~ afterClick.to!string);

    // Undo the click's MeshSelectionEdit. Its before-image is the SWEPT set,
    // not an empty selection — that is the whole discriminator.
    auto u = parseJSON(post(testBaseUrl() ~ "/api/undo", ""));
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto restored = selectedVerts();
    assert(restored == swept,
        "undo of the click must restore the SWEPT set " ~ swept.to!string
        ~ ", got " ~ restored.to!string
        ~ " — a before-image that was never written restores an EMPTY "
        ~ "selection and lands here with []");
}
