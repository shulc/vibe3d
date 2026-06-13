// Snap-to-background-layer test (layers Stage 5).
//
// Builds a two-layer document, makes the second layer a VISIBLE BACKGROUND
// layer with one vertex parked at an isolated world position, then drags a
// vertex on the ACTIVE layer with vertex-snap enabled and asserts the dragged
// vertex snaps to the BACKGROUND layer's vertex — i.e. background layers are
// snap targets.
//
// This is the test_snap_during_drag.d recipe with a second layer.
//
// Stage 2b SEMANTICS FLIP: "background" is now DERIVED — a layer is a background
// snap source iff it is `visible && !selected`. The stored `bool background` /
// `layer.setBackground` third state is GONE; the snap state is produced by the
// item-selection mutator (`layer.select mode:{add,remove}`). The test's INTENT
// is unchanged ("only visible+DESELECTED layers snap"); only the command that
// produces the snappable state flips:
//   • positive case — B is visible and DESELECTED (derived background) → IS a
//     snap target. Produced by `layer.select index:1 mode:remove` after A is
//     primary.
//   • negative case — B is visible and SELECTED non-primary (foreground) → is
//     NOT a snap target; the drag instead snaps to the active layer's own
//     nearest vertex. Produced by `layer.select index:1 mode:add` then
//     `layer.select index:0 mode:add` (A primary, B stays selected — NOT
//     `mode:set`, which would deselect B).
//
// The full /api/play-events -> MoveTool.onMouseMotion -> applySnapToDelta ->
// snapCursor path runs on every motion event; the only Stage-5 addition under
// test is the extra background snap source that snapCursor walks after the
// active mesh.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// POST /api/command with an argstring body; assert ok.
void cmd(string argstring, string baseUrl = "http://localhost:8080") {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

// POST /api/command with a JSON body; assert ok.
void cmdJson(string body_, string baseUrl = "http://localhost:8080") {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
}

void selectVerts(int[] idx, string baseUrl = "http://localhost:8080") {
    string list = "[";
    foreach (i, v; idx) { if (i) list ~= ","; list ~= v.to!string; }
    list ~= "]";
    auto r = post(baseUrl ~ "/api/select",
                  `{"mode":"vertices","indices":` ~ list ~ `}`);
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "select failed: " ~ cast(string)r);
}

void moveVertexActive(double[3] from, double[3] to,
                      string baseUrl = "http://localhost:8080") {
    string v3(double[3] p) {
        return "[" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ "]";
    }
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":` ~ v3(from)
            ~ `,"to":` ~ v3(to) ~ `}}`);
}

// Build a two-layer document. Layer A (index 0) = standard cube, active. Layer
// B (index 1) = a cube with one vertex parked far out in +X at the snap target,
// left VISIBLE; `bg` selects whether B ends up DESELECTED (derived background ⇒
// a snap source) or SELECTED non-primary (foreground ⇒ NOT a snap source).
// Returns the snap-target world pos.
//
// Stage 2b: the snap source is the DERIVED `visible && !selected` set, so the
// state is produced via `layer.select mode:{add,remove}` (the retired
// `layer.setBackground` would only be a thin alias now).
Vec3 buildTwoLayers(bool bg, string baseUrl = "http://localhost:8080") {
    post(baseUrl ~ "/api/reset", "");

    // Layer B — created via layer.add (becomes active + empty), filled with a
    // cube, then one corner is parked at the isolated snap target.
    cmd("layer.add name:B");           // index 1 active, empty
    cmd("prim.cube");                  // B = standard cube
    // Park B's (-0.5,-0.5,-0.5) corner far out in +X so it is the unique
    // nearest snap candidate at the drag endpoint pixel, well clear of every
    // active-layer vertex.
    moveVertexActive([-0.5, -0.5, -0.5], [3.0, -0.5, -0.5]);

    cmd("layer.setVisible index:1 value:true");   // B stays visible either way

    if (bg) {
        // POSITIVE: B visible + DESELECTED ⇒ derived background ⇒ snap source.
        // Make A primary (exclusive), then mode:remove B (it's already
        // deselected by the set on A — a guarded no-op that leaves B
        // visible+deselected, the snappable state).
        cmd("layer.select index:0");                  // A primary, B deselected
        cmd("layer.select index:1 mode:remove");      // B left visible+deselected
    } else {
        // NEGATIVE: B visible + SELECTED non-primary (foreground) ⇒ NOT a snap
        // source. Add B to the selection, then add A so A becomes primary while
        // B STAYS selected (mode:add, NOT mode:set — set would deselect B).
        cmd("layer.select index:1 mode:add");         // B selected + primary
        cmd("layer.select index:0 mode:add");         // A primary, B still selected
    }

    return Vec3(3.0f, -0.5f, -0.5f);
}

// POST /api/snap — a direct, deterministic probe of the multi-source snap walk
// at an explicit cursor world-pos + screen pixel, with v0 excluded (mirroring
// the live drag's self-exclusion). It runs the SAME snapCursor over the active
// mesh + installed background sources the interactive drag does, and returns
// the SnapResult JSON (now carrying targetSource). Used to assert the source
// IDENTITY of the winner — /api/snap/last is cleared at mouse-up by the tool,
// so it cannot be read post-drag.
JSONValue probeSnap(Vec3 worldTarget, int sx, int sy,
                    string baseUrl = "http://localhost:8080") {
    string v3(Vec3 p) {
        return format("[%.6f,%.6f,%.6f]", p.x, p.y, p.z);
    }
    string body_ = format(
        `{"cursor":%s,"sx":%d,"sy":%d,"excludeVerts":[0]}`,
        v3(worldTarget), sx, sy);
    return parseJSON(cast(string)post(baseUrl ~ "/api/snap", body_));
}

// Result of a v0 drag: the post-drag active-v0 position + the SnapResult JSON
// that the /api/snap probe reports at the same drag-target pixel.
struct DragOutcome { double[3] pos; JSONValue snap; }

// Drag active-layer v0 along its X-arrow toward `worldTarget` with snap
// enabled (huge range), for the given snap candidate type(s). After the drag
// it probes /api/snap at the drag-target pixel and returns both the post-drag
// v0 position and that SnapResult (for source-identity assertions).
DragOutcome dragV0Toward(Vec3 worldTarget, string snapTypes = "vertex",
                         string baseUrl = "http://localhost:8080") {
    selectVerts([0]);

    string script =
        "tool.set move\n" ~
        "tool.pipe.attr snap enabled true\n" ~
        "tool.pipe.attr snap types " ~ snapTypes ~ "\n" ~
        "tool.pipe.attr snap innerRange 999999\n" ~
        "tool.pipe.attr snap outerRange 999999\n";
    auto setResp = post(baseUrl ~ "/api/script", script);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set + snap config failed: " ~ cast(string)setResp);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto pivot for single-vertex selection = v0 = (-0.5,-0.5,-0.5).
    Vec3 pivot = Vec3(-0.5f, -0.5f, -0.5f);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "arrowStart off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "arrowEnd off-camera");

    int x0 = cast(int)(sx1 + 0.5f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.5f * (sy2 - sy1));

    // Drag the cursor to the snap target's screen pixel.
    float tx, ty;
    assert(projectToWindow(worldTarget, vp, tx, ty), "snap target off-camera");
    int x1 = cast(int)tx;
    int y1 = cast(int)ty;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    DragOutcome o;
    o.pos  = vertexPos(0);                       // active layer = layer A
    o.snap = probeSnap(worldTarget, x1, y1);     // source-identity probe
    return o;
}

unittest { // POSITIVE: background-layer vertex IS a snap target
    Vec3 target = buildTwoLayers(true);     // B is visible + background
    auto o = dragV0Toward(target);

    // Axis-X drag: v0.x snaps to the background vertex's X (3.0); Y / Z stay.
    assert(approx(o.pos[0], 3.0),
        "v0.x should snap to background vertex X=3.0, got " ~ o.pos[0].to!string);
    assert(approx(o.pos[1], -0.5),
        "v0.y should stay at -0.5 (axis-X drag), got " ~ o.pos[1].to!string);
    assert(approx(o.pos[2], -0.5),
        "v0.z should stay at -0.5 (axis-X drag), got " ~ o.pos[2].to!string);

    // SOURCE IDENTITY (the highlight-fix data thread): the winning candidate
    // came from a BACKGROUND source, so the SnapResult must name it
    // (targetSource >= 1) — NOT report it as the active mesh (slot 0). Without
    // the fix targetSource is always 0 and the cyan highlight is drawn against
    // the wrong (active) mesh.
    auto sr = o.snap;
    assert(sr["highlighted"].type == JSONType.TRUE,
        "expected a snap highlight, got " ~ sr.toString);
    assert(sr["targetSource"].integer >= 1,
        "background snap must report targetSource >= 1, got "
        ~ sr["targetSource"].integer.to!string);
    assert(sr["targetType"].integer == 1,   // SnapType.Vertex
        "expected a Vertex snap (targetType=1), got "
        ~ sr["targetType"].integer.to!string);
}

unittest { // NEGATIVE: a selected-non-primary (foreground) layer does NOT snap
    Vec3 target = buildTwoLayers(false);    // B is visible + SELECTED non-primary
    auto o = dragV0Toward(target);

    // B is not a snap source, so v0 cannot reach X=3.0. With huge range it
    // snaps to the active layer's own nearest vertex in +X (v1 at X=0.5).
    assert(!approx(o.pos[0], 3.0),
        "v0.x must NOT snap to non-background layer (got 3.0)");
    assert(approx(o.pos[0], 0.5),
        "v0.x should snap to active layer's own v1 X=0.5, got " ~ o.pos[0].to!string);

    // The snap came from the ACTIVE mesh — slot 0. This is the byte-identical
    // common path: targetSource must stay 0.
    auto sr = o.snap;
    if (sr["highlighted"].type == JSONType.TRUE)
        assert(sr["targetSource"].integer == 0,
            "active-mesh snap must report targetSource == 0, got "
            ~ sr["targetSource"].integer.to!string);
}

unittest { // EDGE variant: a background EDGE snap also names its source
    Vec3 target = buildTwoLayers(true);     // B is visible + background
    // Snap to edges only. The drag endpoint pixel is at the background
    // layer's parked corner, so the nearest edge candidate is a background
    // edge — the source identity must point at the background slot, locking
    // the edge branch of drawTargetElementHighlight.
    auto o = dragV0Toward(target, "edge");

    auto sr = o.snap;
    assert(sr["highlighted"].type == JSONType.TRUE,
        "expected an edge highlight, got " ~ sr.toString);
    assert(sr["targetSource"].integer >= 1,
        "background edge snap must report targetSource >= 1, got "
        ~ sr["targetSource"].integer.to!string);
    assert(sr["targetType"].integer == 2,   // SnapType.Edge
        "expected an Edge snap (targetType=2), got "
        ~ sr["targetType"].integer.to!string);
}
