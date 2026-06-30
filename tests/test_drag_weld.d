// Tests for mesh.weldVertexPair command and mesh.dragWeld tool.
//
// Three categories:
//   1. Command golden (analytic, projection-free): POST /api/load-mesh with
//      two separate quads sharing no vertices; /api/command mesh.weldVertexPair
//      source A target B → count −1, survivor at target position; undo restores.
//   2. Command no-op: same source and target index → status:error, count unchanged.
//   3. Tool drag (integration): calibrated camera + seeded geometry; drag source
//      vertex pixels to target vertex pixels; assert count −1, survivor at target
//      pos; release over empty space → no-op.
//
// Mesh design for command tests:
//   Two separate quads (no shared verts) so the cross-quad weld is NOT blocked
//   by the shared-face guard:
//     quad A: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)  face [0,1,2,3]
//     quad B: v4=(3,0,0) v5=(4,0,0) v6=(4,0,1) v7=(3,0,1)  face [4,5,6,7]
//   Weld source=5 target=1: source v5=(4,0,0) merges into target v1=(1,0,0).
//   Result: 7 vertices, survivor at (1,0,0).
//
// Pixel calibration for drag test:
//   drag_helpers.d projectToWindow computes exact screen pixels for each vertex
//   given the live camera state — no hardcoded pixels, no fragile approximations.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : fabs, sqrt;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

// Re-use the drag_helpers.d module for camera fetch + pixel projection
// + event-log builder.  The module file is compiled alongside this test
// by run_test.d (same -I flag as the other drag tests).
import drag_helpers;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

string baseUrl = "http://localhost:8080";

void postReset(bool empty = false) {
    string path = empty ? "/api/reset?empty=true" : "/api/reset";
    auto r = parseJSON(cast(string)post(baseUrl ~ path, ""));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}

void postLoadMesh(string body_) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/load-mesh", body_));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

/// Post command with JSON params object.  Asserts status == "ok".
void postCommandParams(string id, string paramsJson) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`));
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

/// Post command with JSON params object.  Returns raw JSON (no assertion).
JSONValue postCommandParamsRaw(string id, string paramsJson) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`));
}

/// Post command without params.  Returns raw JSON (no assertion).
JSONValue postCommandRaw(string id) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command",
        `{"id":"` ~ id ~ `"}`));
}

JSONValue postUndo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
}

JSONValue getModel() {
    return parseJSON(cast(string)get(baseUrl ~ "/api/model"));
}

void setCamera(double azimuth, double elevation, double distance,
               double fx = 0.0, double fy = 0.0, double fz = 0.0)
{
    string body_ = format(
        `{"azimuth":%g,"elevation":%g,"distance":%g,"focus":{"x":%g,"y":%g,"z":%g}}`,
        azimuth, elevation, distance, fx, fy, fz);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/camera", body_));
    assert(r["status"].str == "ok", "setCamera failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// Mesh geometry helpers
// ---------------------------------------------------------------------------

// True if any vertex in the model is within `tol` world units of (x,y,z).
bool hasVertexNear(JSONValue model, double x, double y, double z,
                   double tol = 1e-5)
{
    foreach (v; model["vertices"].array) {
        double dx = v.array[0].floating - x;
        double dy = v.array[1].floating - y;
        double dz = v.array[2].floating - z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < tol) return true;
    }
    return false;
}

// Standard two-separate-quads test mesh (8 verts, 2 faces, no shared verts).
//   quad A: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) face [0,1,2,3]
//   quad B: v4=(3,0,0) v5=(4,0,0) v6=(4,0,1) v7=(3,0,1) face [4,5,6,7]
enum string TWO_QUAD_MESH = `{
    "vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1],
                [3,0,0],[4,0,0],[4,0,1],[3,0,1]],
    "faces":[[0,1,2,3],[4,5,6,7]]
}`;

// ---------------------------------------------------------------------------
// 1. Command golden: weld source=5 into target=1 → 7 verts, survivor at (1,0,0)
// ---------------------------------------------------------------------------
unittest { // command golden: cross-quad weld → count −1, survivor at target pos
    postReset();
    postLoadMesh(TWO_QUAD_MESH);

    auto before = getModel();
    assert(before["vertices"].array.length == 8, "setup: expected 8 verts");

    postCommandParams("mesh.weldVertexPair", `{"source":5,"target":1}`);

    auto after = getModel();
    assert(after["vertices"].array.length == 7,
        "weld: expected 7 vertices, got " ~ after["vertices"].array.length.to!string);
    assert(hasVertexNear(after, 1, 0, 0),
        "weld: no vertex at target position (1,0,0)");
    // Source position (4,0,0) must be gone — it merged into target (1,0,0).
    assert(!hasVertexNear(after, 4, 0, 0, 0.1),
        "weld: original source position (4,0,0) must be absent after weld");
}

// ---------------------------------------------------------------------------
// 2. Undo restores the original 8 vertices and positions.
// ---------------------------------------------------------------------------
unittest { // undo: restores original count and all vertex positions
    postReset();
    postLoadMesh(TWO_QUAD_MESH);

    postCommandParams("mesh.weldVertexPair", `{"source":5,"target":1}`);
    auto after = getModel();
    assert(after["vertices"].array.length == 7, "undo-setup: expected 7 verts after weld");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto restored = getModel();
    assert(restored["vertices"].array.length == 8,
        "undo: expected 8 verts after undo, got "
        ~ restored["vertices"].array.length.to!string);
    // Both original positions must be back.
    assert(hasVertexNear(restored, 1, 0, 0), "undo: target vertex (1,0,0) missing");
    assert(hasVertexNear(restored, 4, 0, 0), "undo: source vertex (4,0,0) missing");
}

// ---------------------------------------------------------------------------
// 3. No-op: same source and target index → status:error, count unchanged.
// ---------------------------------------------------------------------------
unittest { // no-op: same index → status:error
    postReset();
    postLoadMesh(TWO_QUAD_MESH);

    auto r = postCommandParamsRaw("mesh.weldVertexPair", `{"source":3,"target":3}`);
    assert(r["status"].str != "ok",
        "same-index: expected status != ok, got: " ~ r.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 8,
        "same-index: vertex count must be unchanged at 8, got "
        ~ m["vertices"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// 4. No-op: shared-face guard — welding two vertices of the same face
//    (opposite quad corners) must return status:error.
// ---------------------------------------------------------------------------
unittest { // shared-face guard via command: same quad v0 and v2 → status:error
    postReset();
    // Single quad: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1]],"faces":[[0,1,2,3]]}`);

    // v0 and v2 are opposite corners (non-adjacent) → shared-face guard rejects.
    auto r = postCommandParamsRaw("mesh.weldVertexPair", `{"source":2,"target":0}`);
    assert(r["status"].str != "ok",
        "shared-face guard: expected status != ok, got: " ~ r.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 4,
        "shared-face guard: vertex count must be unchanged at 4");
}

// ---------------------------------------------------------------------------
// 5. Tool drag: calibrated camera + seeded geometry.
//
// Mesh: two small separate triangles so that the source vertex (tri B, v3) and
// target vertex (tri A, v0) do NOT share a face and the weld is valid.
//   tri A: v0=(−0.5, 0, 0) v1=(0, 0, 1) v2=(0.5, 0, 0)  face [0,1,2]
//   tri B: v3=(−0.5, 0, 2) v4=(0, 0, 3) v5=(0.5, 0, 2)  face [3,4,5]
//
// Camera: az=0, el=0.6, dist=6, focus=(0,0,1). Oblique front view; the two
// triangles appear in upper and lower halves of the viewport. The drag_helpers
// module projects each vertex to exact screen pixels for the drag event log.
//
// Weld: drag v3=(−0.5,0,2) onto v0=(−0.5,0,0). After weld: 5 vertices,
// survivor at v0's position (−0.5,0,0).
// ---------------------------------------------------------------------------
unittest { // tool drag: weld source onto target → count −1, survivor at target pos
    import std.math : PI;

    postReset();
    // Two separate triangles: tri A at z=0..1, tri B at z=2..3.
    enum string TWO_TRI_MESH = `{
        "vertices":[[-0.5,0,0],[0,0,1],[0.5,0,0],
                    [-0.5,0,2],[0,0,3],[0.5,0,2]],
        "faces":[[0,1,2],[3,4,5]]
    }`;
    postLoadMesh(TWO_TRI_MESH);

    // Camera: oblique front view, triangles visible top and bottom.
    setCamera(0.0, 0.6, 6.0, 0.0, 0.0, 1.0);

    // Activate the drag-weld tool.
    auto toolResp = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        "tool.set mesh.dragWeld on"));
    assert(toolResp["status"].str == "ok",
        "tool.set mesh.dragWeld failed: " ~ toolResp.toString);

    // Fetch the live camera state and build the Viewport for projection.
    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);

    // Project source vertex v3=(−0.5,0,2) and target vertex v0=(−0.5,0,0)
    // to screen pixels. drag_helpers.projectToWindow matches the same math
    // as source/math.d:projectToWindowFull that DragWeldTool uses internally.
    float srcPx, srcPy, tgtPx, tgtPy;
    bool srcOk = projectToWindow(Vec3(-0.5f, 0, 2), vp, srcPx, srcPy);
    bool tgtOk = projectToWindow(Vec3(-0.5f, 0, 0), vp, tgtPx, tgtPy);
    assert(srcOk, "tool-drag: source vertex v3 projects off-screen; adjust camera");
    assert(tgtOk, "tool-drag: target vertex v0 projects off-screen; adjust camera");

    // Build the drag event log: down at source, motion to target, up at target.
    string log = buildDragLog(
        cam.vpX, cam.vpY, cam.width, cam.height,
        cast(int)srcPx, cast(int)srcPy,
        cast(int)tgtPx, cast(int)tgtPy,
        20);   // 20 motion steps

    playAndWait(log, baseUrl);

    // Deactivate tool to ensure caches flush before reading model.
    post(baseUrl ~ "/api/command", "tool.set mesh.dragWeld off");

    auto m = getModel();
    assert(m["vertices"].array.length == 5,
        "tool-drag: expected 5 vertices after weld, got "
        ~ m["vertices"].array.length.to!string);
    // Survivor at target position v0=(−0.5,0,0).
    assert(hasVertexNear(m, -0.5, 0, 0),
        "tool-drag: no vertex at target position (-0.5,0,0)");
    // Source position v3=(−0.5,0,2) must be absent.
    assert(!hasVertexNear(m, -0.5, 0, 2, 0.05),
        "tool-drag: source position (-0.5,0,2) must be absent after weld");
}

// ---------------------------------------------------------------------------
// 6. Tool drag undo: after the weld gesture, Ctrl+Z restores 6 vertices.
// ---------------------------------------------------------------------------
unittest { // tool drag undo: one gesture → one undo entry
    import std.math : PI;

    postReset();
    enum string TWO_TRI_MESH = `{
        "vertices":[[-0.5,0,0],[0,0,1],[0.5,0,0],
                    [-0.5,0,2],[0,0,3],[0.5,0,2]],
        "faces":[[0,1,2],[3,4,5]]
    }`;
    postLoadMesh(TWO_TRI_MESH);
    setCamera(0.0, 0.6, 6.0, 0.0, 0.0, 1.0);

    auto toolResp = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        "tool.set mesh.dragWeld on"));
    assert(toolResp["status"].str == "ok", "tool.set failed: " ~ toolResp.toString);

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);

    float srcPx, srcPy, tgtPx, tgtPy;
    projectToWindow(Vec3(-0.5f, 0, 2), vp, srcPx, srcPy);
    projectToWindow(Vec3(-0.5f, 0, 0), vp, tgtPx, tgtPy);

    string log = buildDragLog(
        cam.vpX, cam.vpY, cam.width, cam.height,
        cast(int)srcPx, cast(int)srcPy,
        cast(int)tgtPx, cast(int)tgtPy,
        20);
    playAndWait(log, baseUrl);

    post(baseUrl ~ "/api/command", "tool.set mesh.dragWeld off");

    auto afterWeld = getModel();
    assert(afterWeld["vertices"].array.length == 5,
        "drag-undo setup: expected 5 verts after weld, got "
        ~ afterWeld["vertices"].array.length.to!string);

    // Undo the gesture.
    auto u = postUndo();
    assert(u["status"].str == "ok", "drag-undo: undo failed: " ~ u.toString);

    auto restored = getModel();
    assert(restored["vertices"].array.length == 6,
        "drag-undo: expected 6 verts after undo, got "
        ~ restored["vertices"].array.length.to!string);
    assert(hasVertexNear(restored, -0.5, 0, 0),
        "drag-undo: target vertex (-0.5,0,0) missing after undo");
    assert(hasVertexNear(restored, -0.5, 0, 2),
        "drag-undo: source vertex (-0.5,0,2) missing after undo");
}

// ---------------------------------------------------------------------------
// 7. Tool no-op: release over empty space → count unchanged, no undo entry.
// ---------------------------------------------------------------------------
unittest { // tool no-op: release far from any vertex → no weld, undo stack clean
    postReset();
    enum string TWO_TRI_MESH = `{
        "vertices":[[-0.5,0,0],[0,0,1],[0.5,0,0],
                    [-0.5,0,2],[0,0,3],[0.5,0,2]],
        "faces":[[0,1,2],[3,4,5]]
    }`;
    postLoadMesh(TWO_TRI_MESH);
    setCamera(0.0, 0.6, 6.0, 0.0, 0.0, 1.0);

    // Capture model-undo depth before the gesture so we can prove the
    // no-op drag adds no entry (postUndo would undo loadMesh, not the
    // gesture, so vertex-count-after-undo is not the right witness).
    auto statusBefore = parseJSON(cast(string)get(baseUrl ~ "/api/undo/status"));

    auto toolResp = parseJSON(cast(string)post(baseUrl ~ "/api/command",
        "tool.set mesh.dragWeld on"));
    assert(toolResp["status"].str == "ok", "tool.set failed: " ~ toolResp.toString);

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);

    // Down on v3=(−0.5,0,2); release at the top-left corner of the viewport
    // which is hundreds of pixels from any vertex (the mesh projects to a
    // small band near the centre; centre itself is the focus point (0,0,1) =
    // v1, so "halfway" would snap to v1 within PICK_RADIUS_PX=12).
    float srcPx, srcPy;
    projectToWindow(Vec3(-0.5f, 0, 2), vp, srcPx, srcPy);
    // Release 5px inside the top-left corner — guaranteed empty space.
    int relX = cam.vpX + 5;
    int relY = cam.vpY + 5;

    string log = buildDragLog(
        cam.vpX, cam.vpY, cam.width, cam.height,
        cast(int)srcPx, cast(int)srcPy,
        relX, relY,
        20);
    playAndWait(log, baseUrl);

    post(baseUrl ~ "/api/command", "tool.set mesh.dragWeld off");

    auto m = getModel();
    assert(m["vertices"].array.length == 6,
        "no-op: expected 6 vertices unchanged, got "
        ~ m["vertices"].array.length.to!string);

    // Verify the gesture added NO model undo entry: modelDepth must match
    // the depth captured before the tool was activated.  We do NOT call
    // postUndo() here because that would undo the preceding mesh.load
    // (a legitimate entry), not the drag gesture — the vertex-count-after-
    // undo witness is misleading in a multi-test session.
    auto statusAfter = parseJSON(cast(string)get(baseUrl ~ "/api/undo/status"));
    assert(statusAfter["modelDepth"].integer == statusBefore["modelDepth"].integer,
        "no-op: gesture must not add a model undo entry; modelDepth was "
        ~ statusBefore["modelDepth"].integer.to!string
        ~ " before gesture, "
        ~ statusAfter["modelDepth"].integer.to!string ~ " after");
}
