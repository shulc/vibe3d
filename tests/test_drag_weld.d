// Drag Weld (`mesh.dragWeld`) and its command door (`mesh.weldVertexPair`).
//
// The law (task 9437; captures K-W2 and K-P P6, fixture rigs copied below):
//   * the TARGET survives at its own index and position; the dragged vertex
//     is deleted and later indices shift down in order (W2c both orders);
//   * press and target come from ONE vertex finder over the edited mesh with
//     the occlusion and hidden masks (W2e, W2f, W2g; a background layer is
//     never a target);
//   * the target reach is the snap acceptance (24 px), and only with snapping
//     ON (P6: 10 and 18 px weld, 30 misses, snapping off never welds);
//   * same-polygon corners weld: adjacent ones collapse the edge (KW2_I), a
//     diagonal leaves the self-touching [a,T,b,T] (KW2_J).
// Rigs are in the capture's frame: front view, 100 px per metre at z = 0.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : fabs, tan, PI;
import std.format : format;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;

JSONValue command(string body_) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
}

void ok(string body_) {
    auto r = command(body_);
    assert(r["status"].str == "ok", body_ ~ " failed: " ~ r.toString);
}

JSONValue getModel() { return parseJSON(cast(string)get(baseUrl ~ "/api/model")); }

long modelDepth() {
    return parseJSON(cast(string)get(baseUrl ~ "/api/undo/status"))["modelDepth"].integer;
}

struct Rig { float[3][] pts; uint[][] faces; }

void loadRig(Rig r) {
    ok(commandBody("scene.reset"));
    ok(commandBody("scene.loadMesh",
        format(`{"vertices":%s,"faces":%s}`, r.pts.to!string, r.faces.to!string)));
}

/// Front view (eye on +Z; `back` puts it on -Z) at 100 px per metre on the
/// z = 0 plane, as captured.
Viewport frontView(float fx, float fy, bool back = false) {
    immutable h = fetchCamera(baseUrl).height;
    immutable double dist = h / (2.0 * tan(PI / 8.0) * 100.0);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/camera", format(
        `{"azimuth":%g,"elevation":0,"distance":%g,"focus":{"x":%g,"y":%g,"z":0}}`,
        back ? PI : 0.0, dist, fx, fy)));
    assert(r["status"].str == "ok", "camera: " ~ r.toString);
    auto cam = fetchCamera(baseUrl);
    assert((cam.eye.z - cam.focus.z) * (back ? -1 : 1) > 1.0f, "rig: the eye must sit on the asked side");
    return viewportFromCamera(cam);
}

/// Snapping on with every global snap type OFF, as captured (the weld search
/// is the tool's own vertex query); off restores the shipped types.
void snapState(bool on) {
    ok("tool.pipe.attr snap enabled " ~ (on ? "true" : "false"));
    ok(on ? `tool.pipe.attr snap types ""` : "tool.pipe.attr snap types vertex");
    ok("tool.pipe.attr snap innerRange 24");
}

int[2] px(Viewport vp, float[3] w) {
    float x, y;
    assert(projectToWindow(Vec3(w[0], w[1], w[2]), vp, x, y), "rig point off-screen");
    return [cast(int)(x + 0.5f), cast(int)(y + 0.5f)];
}

void hideVerts(int[] idx) {
    ok("select.typeFrom vertex");
    ok(commandBody("mesh.select", format(`{"mode":"vertices","indices":%s}`, idx)));
    ok(`{"id":"mesh.hide"}`);
}

/// One gesture: press on `src`, release at `endWorld` + (offX, offY) pixels.
/// Returns the model after it and asserts the history grew by `welded`.
JSONValue dragWeld(Rig r, int src, float[3] endWorld, bool welded,
                   int offX = 0, int offY = 0, bool snap = true, int[] hide = null,
                   int pressOffY = 0) {
    loadRig(r);
    if (hide.length) hideVerts(hide);
    auto vp = frontView(0.25f, 0.15f);
    snapState(snap);
    ok("tool.set mesh.dragWeld on");
    immutable before = modelDepth();
    auto cam = fetchCamera(baseUrl);
    auto a = px(vp, r.pts[src]), b = px(vp, endWorld);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             a[0], a[1] + pressOffY, b[0] + offX, b[1] + offY, 10), baseUrl);
    ok("tool.set mesh.dragWeld off");
    snapState(false);
    assert(modelDepth() - before == (welded ? 1 : 0),
        format("press %s%+d, release %s%+d%+d, snap=%s: history grew by %d, expected %d",
               r.pts[src], pressOffY, endWorld, offX, offY, snap, modelDepth() - before,
               welded ? 1 : 0));
    return getModel();
}

/// `VIBE3D_CELL=<id>` runs one cell alone (druntime stops a module at its first red).
bool cell(string id) {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL");
    return only is null || only == id;
}

size_t nv(JSONValue m) { return m["vertices"].array.length; }

void assertMesh(JSONValue m, float[3][] pos, uint[][] faces, string cell) {
    assert(nv(m) == pos.length, format("%s: V=%d, expected %d", cell, nv(m), pos.length));
    foreach (i, p; pos) foreach (k; 0 .. 3)
        assert(fabs(m["vertices"].array[i].array[k].floating - p[k]) < 1e-4,
            format("%s: vertex %d is %s, expected %s", cell, i, m["vertices"].array[i], p));
    assert(m["faces"].toString == faces.to!string.toJSON,
        format("%s: faces %s, expected %s", cell, m["faces"], faces));
}

string toJSON(string dlist) { return parseJSON(dlist).toString; }

// KW2_C: quad A [0..3], quad B [4..7]; vertex 1 ends 6 px from vertex 4.
immutable Rig kC = Rig(
    [[-0.5f, 0f, 0f], [0f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f],
     [0.5f, 0.06f, 0f], [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f]],
    [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
enum float[3] kEndC = [0.5f, 0f, 0f];

// ---------------------------------------------------------------------------
// Command door: the same pair weld, by index.
// ---------------------------------------------------------------------------
unittest { // command: target 4 survives at its own index-1 slot, undo restores
    if (!cell("cmd-W2c")) return;
    loadRig(cast(Rig)kC);
    ok(`{"id":"mesh.weldVertexPair","params":{"source":1,"target":4}}`);
    assertMesh(getModel(),
        [[-0.5f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f], [0.5f, 0.06f, 0f],
         [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f]],
        [[0u, 3, 1, 2], [3u, 4, 5, 6]], "command W2c");
    ok(commandBody("history.undo"));
    assertMesh(getModel(), cast(float[3][])kC.pts, cast(uint[][])kC.faces, "command undo");
    ok(commandBody("history.redo"));
    assertMesh(getModel(),
        [[-0.5f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f], [0.5f, 0.06f, 0f],
         [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f]],
        [[0u, 3, 1, 2], [3u, 4, 5, 6]], "command redo");
}

unittest { // command: the same index, or a hidden one, is a refusal (nothing recorded)
    if (!cell("cmd-refuse")) return;
    foreach (hidden; [false, true]) {
        loadRig(cast(Rig)kC);
        if (hidden) hideVerts([4]);
        immutable before = modelDepth();
        auto r = command(hidden ? `{"id":"mesh.weldVertexPair","params":{"source":1,"target":4}}`
                                : `{"id":"mesh.weldVertexPair","params":{"source":3,"target":3}}`);
        assert(r["status"].str != "ok", format("hidden=%s must refuse: %s", hidden, r));
        assert(nv(getModel()) == 8 && modelDepth() == before,
            format("hidden=%s: mesh or history moved", hidden));
    }
}

unittest { // command: diagonal corners of one quad weld into [a,T,b,T] (KW2_J)
    if (!cell("cmd-J")) return;
    loadRig(Rig([[-0.3f, 0f, 0f], [0f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]], [[0u, 1, 2, 3]]));
    ok(`{"id":"mesh.weldVertexPair","params":{"source":1,"target":3}}`);
    assertMesh(getModel(), [[-0.3f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]],
               [[0u, 2, 1, 2]], "command KW2_J");
}

// ---------------------------------------------------------------------------
// The tool: survivor (W2c), masks (W2e/f/g), reach (P6), same polygon (I/J).
// ---------------------------------------------------------------------------
unittest { // W2c: the dragged LOWER index dies, the target keeps its slot
    if (!cell("W2c")) return;
    assertMesh(dragWeld(cast(Rig)kC, 1, kEndC, true),
        [[-0.5f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f], [0.5f, 0.06f, 0f],
         [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f]],
        [[0u, 3, 1, 2], [3u, 4, 5, 6]], "W2c");
}

unittest { // W2c reversed: the dragged HIGHER index onto vertex 0
    if (!cell("W2c-r")) return;
    Rig r = Rig(cast(float[3][])kC.pts[4 .. 8] ~ cast(float[3][])kC.pts[0 .. 4],
                [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    assertMesh(dragWeld(r, 5, kEndC, true),
        [[0.5f, 0.06f, 0f], [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f],
         [-0.5f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f]],
        [[0u, 1, 2, 3], [4u, 0, 5, 6]], "W2c-r");
}

// A closed box x 0.15..0.85, y -0.3..0.4 at depth z0..z0+0.4 (KW2_E geometry).
Rig withBox(Rig r, float z0) {
    Rig o = Rig(r.pts.dup, r.faces.dup);
    o.pts ~= [[0.15f, -0.3f, z0], [0.15f, -0.3f, z0 + 0.4f], [0.15f, 0.4f, z0], [0.15f, 0.4f, z0 + 0.4f],
              [0.85f, -0.3f, z0], [0.85f, -0.3f, z0 + 0.4f], [0.85f, 0.4f, z0], [0.85f, 0.4f, z0 + 0.4f]];
    o.faces ~= [[9u, 13, 15, 11], [8u, 10, 14, 12], [12u, 14, 15, 13],
                [8u, 9, 11, 10], [10u, 11, 15, 14], [8u, 12, 13, 9]];
    return o;
}

unittest { // W2e: a target covered by a box in front is no target; behind, it is
    if (!cell("W2e")) return;
    assert(nv(dragWeld(withBox(cast(Rig)kC, -0.6f), 1, kEndC, true)) == 15, "W2e-c must weld");
    assert(nv(dragWeld(withBox(cast(Rig)kC, 0.2f), 1, kEndC, false)) == 16,
        "W2e: an occluded target must not weld");
}

unittest { // W2f: a hidden target is no target; a hidden bystander changes nothing
    if (!cell("W2f")) return;
    float[3][] far = [[1.3f, -0.5f, 0f], [1.6f, -0.5f, 0f], [1.6f, -0.2f, 0f], [1.3f, -0.2f, 0f]];
    Rig r = Rig(cast(float[3][])kC.pts ~ far, cast(uint[][])kC.faces ~ [[8u, 9, 10, 11]]);
    assert(nv(dragWeld(r, 1, kEndC, true, 0, 0, true, [8])) == 11, "W2f-c must weld");
    assert(nv(dragWeld(r, 1, kEndC, false, 0, 0, true, [4])) == 12,
        "W2f: a hidden target must not weld");
}

unittest { // W2g: a press on a covered vertex drags nothing; uncovered, it welds
    if (!cell("W2g")) return;
    Rig g(float z) {
        return Rig([[-0.7f, -0.7f, 0f], [0f, -0.7f, 0f], [0f, 0f, 0f], [-0.7f, 0f, 0f],
                    [0.5f, 0.06f, 0f], [1.2f, 0.06f, 0f], [1.2f, 0.7f, 0f], [0.5f, 0.7f, 0f],
                    [-0.35f, -0.35f, z], [0.35f, -0.35f, z], [0.35f, 0.35f, z], [-0.35f, 0.35f, z]],
                   [[0u, 1, 2, 3], [4u, 5, 6, 7], [8u, 9, 10, 11]]);
    }
    assert(nv(dragWeld(g(-0.4f), 2, kEndC, true)) == 11, "W2g-c must weld");
    auto m = dragWeld(g(0.4f), 2, kEndC, false);
    assert(nv(m) == 12 && m["vertices"].array[2].array[0].floating == 0,
        "W2g: the covered vertex must be neither dragged nor welded: " ~ m["vertices"].toString);
}

unittest { // P6: the reach is the snap acceptance, only with snapping on; the press is 8
    if (!cell("P6")) return;
    enum float[3] t = [0.5f, 0.06f, 0f];
    assert(nv(dragWeld(cast(Rig)kC, 1, t, true, 0, 10)) == 7, "W2d: 10 px must weld");
    assert(nv(dragWeld(cast(Rig)kC, 1, t, true, 0, 18)) == 7, "W2h: 18 px must weld");
    assert(nv(dragWeld(cast(Rig)kC, 1, t, false, 0, 30)) == 8, "30 px must miss");
    assert(nv(dragWeld(cast(Rig)kC, 1, kEndC, false, 0, 0, false)) == 8,
        "snapping off: no weld at 6 px");
    assert(nv(dragWeld(cast(Rig)kC, 1, kEndC, false, 0, 0, true, null, 12)) == 8,
        "a press 12 px from the vertex must grab nothing (press reach 8)");
}

unittest { // same polygon: adjacent corners collapse (KW2_I), diagonal ones touch (KW2_J)
    if (!cell("IJ")) return;
    assertMesh(dragWeld(Rig([[-0.5f, 0f, 0f], [0f, 0f, 0f], [0f, 0.36f, 0f], [-0.5f, 0.36f, 0f]],
                            [[0u, 1, 2, 3]]), 1, [0f, 0.3f, 0f], true),
        [[-0.5f, 0f, 0f], [0f, 0.36f, 0f], [-0.5f, 0.36f, 0f]], [[0u, 1, 2]], "KW2_I");
    assertMesh(dragWeld(Rig([[-0.3f, 0f, 0f], [0f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]],
                            [[0u, 1, 2, 3]]), 1, [-0.3f, 0.3f, 0f], true),
        [[-0.3f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]], [[0u, 2, 1, 2]], "KW2_J");
}

unittest { // a background layer's vertex is never a target (edited mesh only)
    if (!cell("BG")) return;
    loadRig(Rig([[-3f, 0f, 0f], [-2.5f, 0f, 0f], [-2.5f, 0.3f, 0f], [-3f, 0.3f, 0f]], [[0u, 1, 2, 3]]));
    ok("layer.add name:B");
    ok("prim.cube");                               // B: the unit cube at the origin
    ok("layer.select index:0");
    ok("layer.select index:1 mode:remove");        // B visible + deselected = background
    auto vp = frontView(-1.5f, 0, true);   // from -Z the cube's vertices 0..3 face the eye
    // Positive control: the cube's vertex 0 IS a snap candidate from slot 1, and
    // its index (0 < 4, not the source 1) would weld the edited quad if leaked.
    auto b = px(vp, [-0.5f, -0.5f, -0.5f]);
    ok("tool.pipe.attr snap enabled true");
    ok("tool.pipe.attr snap types vertex");
    auto sp = parseJSON(cast(string)post(baseUrl ~ "/api/snap", format(
        `{"cursor":[0,0,0],"sx":%d,"sy":%d,"excludeVerts":[]}`, b[0] + 6, b[1])));
    assert(sp["snapped"].type == JSONType.true_ && sp["targetSource"].integer == 1
           && sp["targetIndex"].integer == 0,
        "rig: the background vertex 0 must be a snap candidate: " ~ sp.toString);
    snapState(true);
    ok("tool.set mesh.dragWeld on");
    auto cam = fetchCamera(baseUrl);
    auto a = px(vp, [-2.5f, 0f, 0f]);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             a[0], a[1], b[0] + 6, b[1], 10), baseUrl);
    ok("tool.set mesh.dragWeld off");
    snapState(false);
    assert(nv(getModel()) == 4, "a background vertex must not be a weld target");
}

unittest { // tool undo: one gesture is one entry that restores the rig
    if (!cell("undo")) return;
    dragWeld(cast(Rig)kC, 1, kEndC, true);
    ok(commandBody("history.undo"));
    assertMesh(getModel(), cast(float[3][])kC.pts, cast(uint[][])kC.faces, "tool undo");
}
