// Drag Weld (`mesh.dragWeld`, a topology-pen preset: Move, Inner Snap on, no
// background constraint) and its command door (`mesh.weldVertexPair`).
//
// The law (tasks 9437, 9525; captures K-W2, K-P P6, K-DW, fixture rigs below):
//   * the TARGET survives at its own index and position; the dragged vertex
//     is deleted and later indices shift down in order (W2c both orders);
//   * the press is the pen's element pick over the edited mesh: a covered
//     vertex press grabs the covering polygon (W2g), and the selection mode
//     does not gate it (DW_POLY / DW_POLYv);
//   * the grab MOVES with the drag; with no target it stays at the raw end
//     (W2e, W2f, DW_M), and every drag is one undo row (DW_M, DW_Mz1);
//   * the target excludes occluded, hidden and background vertices (W2e,
//     W2f, BG); its reach is the snap acceptance (24 px), only with snapping
//     ON (P6: 10 and 18 px weld, 30 misses, snapping off never welds);
//   * same-polygon corners weld: adjacent ones collapse the edge (KW2_I), a
//     diagonal leaves the self-touching [a,T,b,T] (KW2_J).
// Rigs are in the capture's frame: front ortho, 100 px per metre.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : fabs, tan, PI;
import std.format : format;

import drag_helpers;
import pen_rig_helpers : penCameraAt;

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

/// Front ortho view (`back`: the Back view) at 100 px per metre, as captured.
Viewport frontView(float fx, float fy, bool back = false) {
    ok("viewport.view " ~ (back ? "Back" : "Front"));   // a load leaves the view perspective
    penCameraAt(Vec3(fx, fy, 0), 100);
    assert(getJSON("/api/camera")["projKind"].str == "Ortho", "rig: the view must be orthographic");
    return viewportFromCameraMatrices(baseUrl);
}

JSONValue getJSON(string path) { return parseJSON(cast(string)get(baseUrl ~ path)); }

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
/// Returns the model after it; a drag that grabs is one history row (K-DW).
JSONValue dragWeld(Rig r, int src, float[3] endWorld, int offX = 0, int offY = 0,
                   bool snap = true, int[] hide = null, int pressOffY = 0, bool sym = false,
                   bool grabs = true) {
    loadRig(r);
    if (hide.length) hideVerts(hide);
    auto vp = frontView(0.25f, 0.15f);
    snapState(true);
    ok("tool.pipe.attr symmetry axis x");
    ok("tool.pipe.attr symmetry enabled " ~ (sym ? "true" : "false"));
    ok("tool.set mesh.dragWeld on");                 // arms snapping, as the pen does
    if (!snap) ok("tool.pipe.attr snap enabled false");
    immutable before = modelDepth();
    drag(vp, r.pts[src], endWorld, offX, offY, pressOffY);
    immutable rows = modelDepth() - before;
    ok("tool.set mesh.dragWeld off");
    snapState(false);
    if (grabs)
        assert(rows == 1, format("press %s%+d, release %s%+d%+d, snap=%s: history grew by %d, "
               ~ "expected one row per drag", r.pts[src], pressOffY, endWorld, offX, offY, snap, rows));
    return getModel();
}

void drag(Viewport vp, float[3] from, float[3] to, int offX = 0, int offY = 0, int pressOffY = 0) {
    auto cam = fetchCamera(baseUrl);
    auto a = px(vp, from), b = px(vp, to);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             a[0], a[1] + pressOffY, b[0] + offX, b[1] + offY, 10), baseUrl);
}

void assertAt(JSONValue m, size_t i, float[3] p, string cell) {
    foreach (k; 0 .. 3)
        assert(fabs(m["vertices"].array[i].array[k].floating - p[k]) < 1e-4,
            format("%s: vertex %d is %s, expected %s", cell, i, m["vertices"].array[i], p));
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
// The tool: survivor (W2c), masks (W2e/f/g), reach (P6), same polygon (I/J),
// the move (DW_M), its undo (DW_Mz1), the selection mode (DW_POLY).
// ---------------------------------------------------------------------------
unittest { // W2c: the dragged LOWER index dies, the target keeps its slot
    if (!cell("W2c")) return;
    assertMesh(dragWeld(cast(Rig)kC, 1, kEndC),
        [[-0.5f, 0f, 0f], [0f, 0.3f, 0f], [-0.5f, 0.3f, 0f], [0.5f, 0.06f, 0f],
         [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f]],
        [[0u, 3, 1, 2], [3u, 4, 5, 6]], "W2c");
}

unittest { // W2c reversed: the dragged HIGHER index onto vertex 0
    if (!cell("W2c-r")) return;
    Rig r = Rig(cast(float[3][])kC.pts[4 .. 8] ~ cast(float[3][])kC.pts[0 .. 4],
                [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    assertMesh(dragWeld(r, 5, kEndC),
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

unittest { // W2e: a target covered by a box in front is no target; the source stays at the end
    if (!cell("W2e")) return;
    assert(nv(dragWeld(withBox(cast(Rig)kC, -0.6f), 1, kEndC)) == 15, "W2e-c must weld");
    auto m = dragWeld(withBox(cast(Rig)kC, 0.2f), 1, kEndC);
    assert(nv(m) == 16, "W2e: an occluded target must not weld");
    assertAt(m, 1, kEndC, "KW2_E: the source stays at the drag end");
}

unittest { // W2f: a hidden target is no target; a hidden bystander changes nothing
    if (!cell("W2f")) return;
    float[3][] far = [[1.3f, -0.5f, 0f], [1.6f, -0.5f, 0f], [1.6f, -0.2f, 0f], [1.3f, -0.2f, 0f]];
    Rig r = Rig(cast(float[3][])kC.pts ~ far, cast(uint[][])kC.faces ~ [[8u, 9, 10, 11]]);
    assert(nv(dragWeld(r, 1, kEndC, 0, 0, true, [8])) == 11, "W2f-c must weld");
    auto m = dragWeld(r, 1, kEndC, 0, 0, true, [4]);
    assert(nv(m) == 12, "W2f: a hidden target must not weld");
    assertAt(m, 1, kEndC, "KW2_F: the source stays at the drag end");
}

unittest { // W2g: a press on a covered vertex grabs the covering polygon; uncovered, it welds
    if (!cell("W2g")) return;
    Rig g(float z) {
        return Rig([[-0.7f, -0.7f, 0f], [0f, -0.7f, 0f], [0f, 0f, 0f], [-0.7f, 0f, 0f],
                    [0.5f, 0.06f, 0f], [1.2f, 0.06f, 0f], [1.2f, 0.7f, 0f], [0.5f, 0.7f, 0f],
                    [-0.35f, -0.35f, z], [0.35f, -0.35f, z], [0.35f, 0.35f, z], [-0.35f, 0.35f, z]],
                   [[0u, 1, 2, 3], [4u, 5, 6, 7], [8u, 9, 10, 11]]);
    }
    assert(nv(dragWeld(g(-0.4f), 2, kEndC)) == 11, "W2g-c must weld");
    auto m = dragWeld(g(0.4f), 2, kEndC);
    assert(nv(m) == 12, "W2g: nothing welds");
    assertAt(m, 2, [0f, 0f, 0f], "KW2_G: the covered vertex stays");
    immutable float[3][4] quad = [[0.15f, -0.35f, 0.4f], [0.85f, -0.35f, 0.4f],
                                  [0.85f, 0.35f, 0.4f], [0.15f, 0.35f, 0.4f]];
    foreach (i, p; quad)
        assertAt(m, 8 + i, p, "KW2_G: the covering quad moves +0.5 in x");
}

unittest { // P6: the reach is the snap acceptance, only with snapping on; the press is 8
    if (!cell("P6")) return;
    enum float[3] t = [0.5f, 0.06f, 0f];
    assert(nv(dragWeld(cast(Rig)kC, 1, t, 0, 10)) == 7, "W2d: 10 px must weld");
    assert(nv(dragWeld(cast(Rig)kC, 1, t, 0, 18)) == 7, "W2h: 18 px must weld");
    assert(nv(dragWeld(cast(Rig)kC, 1, t, 0, 30)) == 8, "30 px must miss");
    assert(nv(dragWeld(cast(Rig)kC, 1, kEndC, 0, 0, false)) == 8, "snapping off: no weld at 6 px");
    auto m = dragWeld(cast(Rig)kC, 1, kEndC, 0, 0, true, null, 12, false, false);
    assert(nv(m) == 8, "a press 12 px from the vertex must weld nothing");
    assertMesh(m, cast(float[3][])kC.pts, cast(uint[][])kC.faces,
               "a press 12 px from the vertex must grab nothing (press reach 8)");
}

unittest { // Inner Snap on: an INTERIOR target welds at 12 px, not at 40 (snappreset s6 V-NEAR /
    // V-FAR); the bare pen (Inner Snap off, s7) takes border targets only
    if (!cell("inner")) return;
    float[3][] g;
    uint[][] f;
    foreach (j; 0 .. 4) foreach (i; 0 .. 4) g ~= [0.5f * i, 0.5f * j, 0f];
    foreach (j; 0 .. 3) foreach (i; 0 .. 3)
        f ~= [cast(uint)(4 * j + i), 4 * j + i + 1, 4 * (j + 1) + i + 1, 4 * (j + 1) + i];
    Rig grid = Rig(g, f);
    enum float[3] v6 = [1f, 0.5f, 0f];
    assert(nv(dragWeld(grid, 5, v6, -12)) == 15, "V-NEAR: interior v5 must weld into interior v6");
    assert(nv(dragWeld(grid, 5, v6, -40)) == 16, "V-FAR: 40 px short must not weld");
    loadRig(grid);
    auto vp = frontView(0.25f, 0.15f);
    snapState(true);
    ok("tool.set mesh.topoPen on");
    ok("tool.attr mesh.topoPen mode move");
    drag(vp, g[5], v6, -12);
    ok("tool.set mesh.topoPen off");
    snapState(false);
    assert(nv(getModel()) == 16, "control: the bare pen must not weld into an interior vertex");
}

unittest { // the source is no target: a release nearer the source than the target still welds
    if (!cell("self")) return;
    // Target 4 is 20 px right of source 1; the release is 8 px from the source and
    // 12 px from the target, inside the 24 px reach of both.
    float[3][] b = [[0.2f, 0f, 0f], [0.7f, 0f, 0f], [0.7f, 0.3f, 0f], [0.2f, 0.3f, 0f]];
    Rig r = Rig(cast(float[3][])kC.pts[0 .. 4] ~ b, [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    auto m = dragWeld(r, 1, [0.08f, 0f, 0f]);
    assert(nv(m) == 7 && fabs(m["vertices"].array[3].array[0].floating - 0.2) < 1e-4,
        "self: the target 4 must survive at slot 3: " ~ m["vertices"].toString);
}

unittest { // same polygon: adjacent corners collapse (KW2_I), diagonal ones touch (KW2_J)
    if (!cell("IJ")) return;
    assertMesh(dragWeld(Rig([[-0.5f, 0f, 0f], [0f, 0f, 0f], [0f, 0.36f, 0f], [-0.5f, 0.36f, 0f]],
                            [[0u, 1, 2, 3]]), 1, [0f, 0.3f, 0f]),
        [[-0.5f, 0f, 0f], [0f, 0.36f, 0f], [-0.5f, 0.36f, 0f]], [[0u, 1, 2]], "KW2_I");
    assertMesh(dragWeld(Rig([[-0.3f, 0f, 0f], [0f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]],
                            [[0u, 1, 2, 3]]), 1, [-0.3f, 0.3f, 0f]),
        [[-0.3f, 0f, 0f], [0f, 0.36f, 0f], [-0.3f, 0.36f, 0f]], [[0u, 2, 1, 2]], "KW2_J");
}

/// The edited quad far left in layer 0, the unit cube as a background layer,
/// the Back view (the cube's vertices 0..3 face the eye).
Viewport backgroundRig() {
    loadRig(Rig([[-3f, 0f, 0f], [-2.5f, 0f, 0f], [-2.5f, 0.3f, 0f], [-3f, 0.3f, 0f]], [[0u, 1, 2, 3]]));
    ok("layer.add name:B");
    ok("prim.cube");                               // B: the unit cube at the origin
    ok("layer.select index:0");
    ok("layer.select index:1 mode:remove");        // B visible + deselected = background
    return frontView(-1.5f, 0, true);
}

string snapEnabled() {
    foreach (st; getJSON("/api/toolpipe")["stages"].array)
        if (st["task"].str == "SNAP") return st["attrs"]["enabled"].str;
    assert(false, "no SNAP stage");
}

unittest { // the preset's activation arms the snap state, the drop restores it (preset_arms_snapstate J/K/L/M)
    if (!cell("arm")) return;
    loadRig(cast(Rig)kC);
    auto vp = frontView(0.25f, 0.15f);
    ok("tool.pipe.attr snap enabled false");
    ok(`tool.pipe.attr snap types ""`);
    ok("tool.pipe.attr snap innerRange 24");
    assert(snapEnabled() == "false", "rig: snapping must start off");
    ok("tool.set mesh.dragWeld on");
    assert(snapEnabled() == "true", "J/K: arming Drag Weld must turn snapping on: " ~ snapEnabled());
    drag(vp, kC.pts[1], [0.5f, 0.06f, 0f], 0, 10);
    ok("tool.set mesh.dragWeld off");
    assert(snapEnabled() == "false", "L/M: dropping Drag Weld must restore snapping off: " ~ snapEnabled());
    assert(nv(getModel()) == 7, "a 10 px release must weld under the armed state (P6 W2d)");
}

string consState() {
    foreach (st; getJSON("/api/toolpipe")["stages"].array)
        if (st["task"].str == "CONS")
            return st["attrs"]["enabled"].str ~ " " ~ st["attrs"]["geometry"].str;
    assert(false, "no CONS stage");
}

unittest { // a background layer's vertex is never a target (edited mesh only)
    if (!cell("BG")) return;
    auto vp = backgroundRig();
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
    drag(vp, [-2.5f, 0f, 0f], [-0.5f, -0.5f, -0.5f], 6);
    ok("tool.set mesh.dragWeld off");
    snapState(false);
    assert(nv(getModel()) == 4, "a background vertex must not be a weld target");
}

unittest { // the preset composes no background constraint (snappreset s6), the pen does
    if (!cell("noCons")) return;
    backgroundRig();
    ok("tool.set mesh.topoPen on");
    immutable pen = consState();
    ok("tool.set mesh.topoPen off");
    ok("tool.set mesh.dragWeld on");
    immutable weld = consState();
    ok("tool.set mesh.dragWeld off");
    assert(pen == "true point", "control: the pen must compose the Point constraint: " ~ pen);
    assert(weld == "true off", "Drag Weld must leave the constraint at its reset geometry: " ~ weld);
}

unittest { // KW2_ADW: under symmetry X the mirror partner welds into the mirror target too
    if (!cell("ADW")) return;
    Rig r = Rig([[0.1f, 0f, 0f], [0.3f, 0f, 0f], [0.3f, 0.3f, 0f], [0.1f, 0.3f, 0f],
        [0.5f, 0.06f, 0f], [1f, 0.06f, 0f], [1f, 0.36f, 0f], [0.5f, 0.36f, 0f],
        [-0.1f, 0.3f, 0f], [-0.3f, 0.3f, 0f], [-0.3f, 0f, 0f], [-0.1f, 0f, 0f],
        [-0.5f, 0.36f, 0f], [-1f, 0.36f, 0f], [-1f, 0.06f, 0f], [-0.5f, 0.06f, 0f]],
        [[0u, 1, 2, 3], [4u, 5, 6, 7], [8u, 9, 10, 11], [12u, 13, 14, 15]]);
    assert(nv(dragWeld(r, 1, kEndC)) == 15, "KW2_B control: one weld without symmetry");
    assertMesh(dragWeld(r, 1, kEndC, 0, 0, true, null, 0, true),
        [[0.1f, 0f, 0f], [0.3f, 0.3f, 0f], [0.1f, 0.3f, 0f], [0.5f, 0.06f, 0f], [1f, 0.06f, 0f],
         [1f, 0.36f, 0f], [0.5f, 0.36f, 0f], [-0.1f, 0.3f, 0f], [-0.3f, 0.3f, 0f], [-0.1f, 0f, 0f],
         [-0.5f, 0.36f, 0f], [-1f, 0.36f, 0f], [-1f, 0.06f, 0f], [-0.5f, 0.06f, 0f]],
        [[0u, 3, 1, 2], [3u, 4, 5, 6], [7u, 8, 13, 9], [10u, 11, 12, 13]], "KW2_ADW");
    // W2f: a hidden vertex is never a weld target, the mirror pair's included.
    foreach (h; [15, 10]) {
        auto m = dragWeld(r, 1, kEndC, 0, 0, true, [h], 0, true);
        assert(nv(m) == 15, format("KW2_ADW hidden v%d: the mirror pair is skipped, V=%d", h, nv(m)));
    }
}

unittest { // KW2_MDW (K-W2b): released on its own mirror, the source fuses with it on the plane
    if (!cell("MDW")) return;
    Rig m = Rig([[0.1f, 0f, 0f], [0.4f, 0f, 0f], [0.4f, 0.4f, 0f], [0.1f, 0.4f, 0f],
        [-0.1f, 0.4f, 0f], [-0.4f, 0.4f, 0f], [-0.4f, 0f, 0f], [-0.1f, 0f, 0f]],
        [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    assertMesh(dragWeld(m, 0, [-0.1f, 0f, 0f]),   // control, symmetry off: KEEP-TARGET
        [[0.4f, 0f, 0f], [0.4f, 0.4f, 0f], [0.1f, 0.4f, 0f], [-0.1f, 0.4f, 0f], [-0.4f, 0.4f, 0f],
         [-0.4f, 0f, 0f], [-0.1f, 0f, 0f]], [[6u, 0, 1, 2], [3u, 4, 5, 6]], "KW2_Mc");
    assertMesh(dragWeld(m, 0, [-0.1f, 0f, 0f], 0, 0, true, null, 0, true),
        [[0f, 0f, 0f], [0.4f, 0f, 0f], [0.4f, 0.4f, 0f], [0.1f, 0.4f, 0f], [-0.1f, 0.4f, 0f],
         [-0.4f, 0.4f, 0f], [-0.4f, 0f, 0f]], [[0u, 1, 2, 3], [4u, 5, 6, 0]], "KW2_MDW");
}

unittest { // DW_M / DW_Mz1: two missing drags are two rows; undo with the tool active reverts one
    if (!cell("DW_M")) return;
    loadRig(cast(Rig)kC);
    auto vp = frontView(0.25f, 0.15f);
    snapState(true);
    ok("tool.set mesh.dragWeld on");
    immutable before = modelDepth();
    drag(vp, [0f, 0f, 0f], [0f, -0.5f, 0f]);
    assertAt(getModel(), 1, [0f, -0.5f, 0f], "DW_M drag 1: the source stays at the raw end");
    drag(vp, [0f, -0.5f, 0f], [-0.3f, -0.5f, 0f]);
    assertAt(getModel(), 1, [-0.3f, -0.5f, 0f], "DW_M drag 2");
    assert(nv(getModel()) == 8 && modelDepth() - before == 2,
        format("DW_M: two missing drags must be two rows, got %d", modelDepth() - before));
    ok(commandBody("history.undo"));
    assertAt(getModel(), 1, [0f, -0.5f, 0f], "DW_Mz1: undo with the tool active reverts the newest drag");
    assert(getJSON("/api/tool/state")["tool"].str == "mesh.topoPen",
        "DW_Mz1: the tool stays active: " ~ getJSON("/api/tool/state").toString);
    ok("tool.set mesh.dragWeld off");
    snapState(false);
}

unittest { // DW_POLY / DW_POLYv: the selection mode does not gate the press
    if (!cell("DW_POLY")) return;
    immutable Rig ab = Rig([[-0.9f, -0.3f, 0f], [-0.1f, -0.3f, 0f], [-0.1f, 0.3f, 0f], [-0.9f, 0.3f, 0f],
                            [0.5f, -0.3f, 0f], [1.1f, -0.3f, 0f], [1.1f, 0.3f, 0f], [0.5f, 0.3f, 0f]],
                           [[0u, 1, 2, 3], [4u, 5, 6, 7]]);
    foreach (corner; [false, true]) {
        loadRig(cast(Rig)ab);
        auto vp = frontView(0.1f, 0f);
        ok("select.typeFrom polygon");
        snapState(true);
        ok("tool.set mesh.dragWeld on");
        if (corner) drag(vp, [-0.9f, 0.3f, 0f], [-1.4f, 0.3f, 0f]);
        else        drag(vp, [-0.5f, 0f, 0f], [-0.5f, -0.5f, 0f]);
        ok("tool.set mesh.dragWeld off");
        snapState(false);
        auto m = getModel();
        foreach (i; 0 .. 8) {
            float[3] p = ab.pts[i];
            if (corner ? i == 3 : i < 4) { if (corner) p[0] -= 0.5f; else p[1] -= 0.5f; }
            assertAt(m, i, p, corner ? "DW_POLYv: the corner press moves only that vertex"
                                     : "DW_POLY: an interior press grabs the polygon");
        }
        assert(getJSON("/api/selection")["selType"].str == "polygon", "DW_POLY: the mode stays polygon");
    }
}
