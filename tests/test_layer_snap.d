// Snap-to-background-layer test (layers Stage 5).
//
// Builds a two-layer document, makes the second layer a VISIBLE BACKGROUND
// layer with one vertex parked at an isolated world position, then drags a
// vertex on the ACTIVE layer with vertex-snap enabled and asserts the dragged
// vertex snaps to the BACKGROUND layer's vertex — i.e. background layers are
// snap targets.
//
// This is the test_snap_during_drag.d recipe with a second layer:
//   • positive case — background=true layer's vertex IS a snap target.
//   • negative case — the same layer with background=false (visible only,
//     non-active) is NOT a snap target; the drag instead snaps to the active
//     layer's own nearest vertex.
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
// flagged visible + background per `bg`. Returns the snap-target world pos.
//
// `bg` selects whether B is a background layer (positive case) or merely a
// visible non-active layer (negative case).
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

    cmd("layer.select index:0");       // Layer A active again
    cmd("layer.setVisible index:1 value:true");
    cmd(bg ? "layer.setBackground index:1 value:true"
           : "layer.setBackground index:1 value:false");

    return Vec3(3.0f, -0.5f, -0.5f);
}

// Drag active-layer v0 along its X-arrow toward `targetPixel` with vertex-snap
// enabled (huge range). Returns the post-drag position of active v0.
double[3] dragV0Toward(Vec3 worldTarget, string baseUrl = "http://localhost:8080") {
    selectVerts([0]);

    string script =
        "tool.set move\n" ~
        "tool.pipe.attr snap enabled true\n" ~
        "tool.pipe.attr snap types vertex\n" ~
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

    return vertexPos(0);   // active layer = layer A
}

unittest { // POSITIVE: background-layer vertex IS a snap target
    Vec3 target = buildTwoLayers(true);     // B is visible + background
    auto p0 = dragV0Toward(target);

    // Axis-X drag: v0.x snaps to the background vertex's X (3.0); Y / Z stay.
    assert(approx(p0[0], 3.0),
        "v0.x should snap to background vertex X=3.0, got " ~ p0[0].to!string);
    assert(approx(p0[1], -0.5),
        "v0.y should stay at -0.5 (axis-X drag), got " ~ p0[1].to!string);
    assert(approx(p0[2], -0.5),
        "v0.z should stay at -0.5 (axis-X drag), got " ~ p0[2].to!string);
}

unittest { // NEGATIVE: a non-background (visible-only) layer does NOT snap
    Vec3 target = buildTwoLayers(false);    // B is visible but background=false
    auto p0 = dragV0Toward(target);

    // B is not a snap source, so v0 cannot reach X=3.0. With huge range it
    // snaps to the active layer's own nearest vertex in +X (v1 at X=0.5).
    assert(!approx(p0[0], 3.0),
        "v0.x must NOT snap to non-background layer (got 3.0)");
    assert(approx(p0[0], 0.5),
        "v0.x should snap to active layer's own v1 X=0.5, got " ~ p0[0].to!string);
}
