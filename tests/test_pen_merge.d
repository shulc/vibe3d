// Polygon pen merge: links decided at the gesture (wave plan S5), against the
// captured cells of tests/fixtures/pen_merge.json. A click, a drag end or a
// hover resolves its point once (quantum, then the user's snap, then ONE merge
// search from the PLACED point); a hit within the merge radius makes the point
// take an edited-mesh vertex's position and share its index, a scene edge
// receives the point as its own vertex, and a press near a live stroke edge
// takes the ring slot between its ends. Radii are screen pixels: 24 px after no
// snap or a placement snap; after an edge snap 17.5 px to the snapped edge's
// own ends and 2.85 px to any other vertex. Typed points never link.
//
// Rig: top ortho at the cell's px/m (ours 440 vs the capture's 439.52), points
// on y = 1, scene geometry loaded as the edited mesh before the pen is armed
// (TYPED coordinates, so a cell's pixel offset is exact), every snap type bit
// written explicitly. Counts and rings are exact; positions are compared to
// 1e-4 (in ortho every placed point is a lattice value, a linked vertex or an
// edge point). All cells run and report together; the must-stay-green block
// runs first, a floor pins the population.
//
// Ours-only cells, constructions stated:
//  - constraint-edge-highlight: a constraint (box face plane) places the point
//    while an edited-mesh edge 30 px away is only highlighted (inside the outer
//    range, outside the inner one); every vertex > 30 px away. The constraint's
//    point stands (0 px from the pointer), own vertex: a constraint win is not
//    an element placement. (The plan named the world-axis constraint; the pen
//    removes that bit from its snap query, so it cannot win there.)
//  - bg-edge-snap-no-reproject: edge snap, the nearest edge is a BACKGROUND
//    layer's; the point is that edge's snapped point, own vertex, the edited
//    mesh unchanged (a background winner's index is not an edited-mesh edge).
//  - vertex-beats-stroke-edge: a press on a stroke point's marker that is also
//    within a stroke edge's radius selects the point and adds nothing.
//  - half-pixel: the edge-snapped point projects to x.5 px; a vertex lying on
//    the edge 2.6 px from it on the side away from the rounded pixel links
//    (float distance 2.6 <= 2.85; from the rounded pixel it is 3.1).
//  - F2 / F2-undo-restore / F2-bump-then-link: links are edited-mesh indices,
//    valid only on the mesh they were made on (a script history.undo removes
//    the linked vertex; an in-stroke Ctrl+Z restores links with their key; a
//    Hide bumps the topology counter with counts unchanged).
//  - link-undo: an in-stroke Ctrl+Z after dragging a linked point away restores
//    the point AND its link.
// A background slot can never link (the merge admits slot 0 only): no captured
// rig has a background vertex inside the radius, so that is a construction
// argument, not a cell.

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, fetchSnapLast,
    kPaceLine, playAndWait, projectToWindow, viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.algorithm : canFind, startsWith;
import std.string : indexOf;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, round, sqrt;

void main() {}

private enum double kTol = 1e-4;
private enum int kSymZ = 122, kSymReturn = 13, kModCtrl = 64;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 v3(JSONValue a) {
    return Vec3(cast(float)num(a.array[0]), cast(float)num(a.array[1]),
                cast(float)num(a.array[2]));
}
private Vec3 p(double x, double z, double y = 1) {
    return Vec3(cast(float)x, cast(float)y, cast(float)z);
}

// ---- rig ------------------------------------------------------------------

/// The edited mesh as a scene.loadMesh body.
private string meshJson(Vec3[] v, long[][] f) {
    string[] vs, fs;
    foreach (w; v) vs ~= format("[%.9g,%.9g,%.9g]", w.x, w.y, w.z);
    foreach (r; f) fs ~= format("%s", r);
    return format(`{"vertices":[%-(%s,%)],"faces":[%-(%s,%)]}`, vs, fs);
}

/// Empty top view, `mesh` loaded as the edited mesh, camera focus `focus` at
/// `ppm`, snapping off (`snapTypes` null) or on with exactly these types, the
/// pen armed with `merge`.
private void rig(Vec3 focus, double ppm, string mesh = null,
                 string snapTypes = null, bool merge = true) {
    penSceneEmpty("Top");
    if (mesh.length) {
        auto r = postJson("/api/command", commandBody("scene.loadMesh", mesh));
        assert(r["status"].str == "ok", "scene load failed: " ~ r.toString);
    }
    penCommand("history.clear");
    penCommand("viewport.view Top");     // a scene load leaves another view
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig premise: the top view must be orthographic");
    penCameraAt(focus, ppm);
    snap(snapTypes);
    penCommand("tool.set pen on");
    if (merge) postJson("/api/command", "tool.attr pen merge true");
    else penCommand("tool.attr pen merge false");
}
private void snap(string types) {
    penCommand("tool.pipe.attr snap enabled " ~ (types is null ? "false" : "true"));
    penCommand(`tool.pipe.attr snap types "` ~ types ~ `"`);
    penCommand("tool.pipe.attr snap snapMode global");
    penCommand("tool.pipe.attr snap innerRange 24");
    penCommand("tool.pipe.attr snap outerRange 40");
}

/// Float window pixel of a world point under the live camera.
private float[2] fpx(Vec3 w) {
    Viewport vp = viewportFromCameraMatrices();
    float x, y;
    assert(projectToWindow(w, vp, x, y), "rig point behind the camera");
    return [x, y];
}
/// One click `dx`, `dy` pixels from the pixel of world point `w`.
private void clickNear(Vec3 w, int dx, int dy) {
    auto q = worldPixel(w);
    clickPixels([q[0] + dx, q[1] + dy]);
}

private void key(int sym, int mod) {
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, sym, mod, sym, mod));
}
private void enter() { key(kSymReturn, 0); }
private void ctrlZ() { key(kSymZ, kModCtrl); }

/// A typed panel field (the interactive door).
private void typed(string name, string value) {
    auto r = postJson("/api/script?interactive=true", "tool.attr pen " ~ name ~ " " ~ value);
    assert(r["status"].str == "ok", "typed " ~ name ~ " failed: " ~ r.toString);
}
private void drop() { penCommand("tool.set pen off"); }

// ---- reads ----------------------------------------------------------------

private struct Model { Vec3[] v; long[][] f; }
private Model model() {
    Model m;
    auto j = getJson("/api/model");
    foreach (v; j["vertices"].array) m.v ~= v3(v);
    foreach (f; j["faces"].array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        m.f ~= ring;
    }
    return m;
}
private long[][] rings(JSONValue a) {
    long[][] r;
    foreach (f; a.array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        r ~= ring;
    }
    return r;
}
private Vec3[] verts(JSONValue a) {
    Vec3[] r;
    foreach (v; a.array) r ~= v3(v);
    return r;
}
private JSONValue faces(JSONValue exp) {
    return "polygons" in exp.object ? exp["polygons"] : exp["faces"];
}

/// The committed mesh against `want` / `wantF`: counts and rings exactly,
/// positions to `tol` (`skip` = indices whose position is not scored).
private string[] compare(string cell, Vec3[] want, long[][] wantF,
                         double tol = kTol, int[] skip = null) {
    auto m = model();
    if (m.v.length != want.length || m.f != wantF)
        return [format("%s: %s vertices, faces %s; expected %s, faces %s", cell,
                       m.v.length, m.f, want.length, wantF)];
    string[] bad;
    foreach (i, w; want) {
        bool skipped;
        foreach (s; skip) skipped |= s == i;
        const g = m.v[i];
        if (!skipped && !(abs(g.x - w.x) <= tol && abs(g.y - w.y) <= tol &&
                          abs(g.z - w.z) <= tol))
            bad ~= format("v%s (%.6f, %.6f, %.6f) vs (%.6f, %.6f, %.6f)", i,
                          g.x, g.y, g.z, w.x, w.y, w.z);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
private string[] fixture(string cell, JSONValue exp, double tol = kTol, int[] skip = null) {
    return compare(cell, verts(exp["vertices"]), rings(faces(exp)), tol, skip);
}
private string[] current(string cell, double want) {
    const c = penAttrValue("currentPoint");
    return c == want ? null
        : [format("%s: current point %s, expected %s", cell, c, want)];
}

// The K-C scene triangle: V and the two far corners (fixture `cells`).
private Vec3[] tri(Vec3 v) { return [v, p(0.6, 0.7), p(0.3, 0.8)]; }
private enum long[][] kTri = [[0, 1, 2]];
// The same triangle wound to face the top view (the ours-only constructions:
// their subject is not facing, so their geometry faces the camera).
private enum long[][] kTriUp = [[0, 2, 1]];
private enum Vec3[2] kFar = [Vec3(-0.4f, 1, 0.6f), Vec3(-0.6f, 1, 0.1f)];

unittest {
    auto fx = parseJSON(import("fixtures/pen_merge.json"));
    auto c = fx["cells"], b3 = fx["cells_k_b3"], ep = fx["edge_press"];
    string[] fails;
    int ran;
    const f0 = p(0, 0.2);           // the K-C rig's focus and V
    const fE = p(0.07, 0);          // the K-B3 rig's focus (edge-press cells)

    // ===== must stay green ==================================================
    // Merge off: a click exactly on V makes its own vertex.
    {
        rig(f0, 440);
        clickWorld(p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
        enter();
        penCommand("tool.attr pen merge false");
        clickWorld(p(0, 0.2), kFar[0], kFar[1]);
        drop(); ++ran;
        fails ~= fixture("scene_click_exact_merge_off", c["scene_click_exact_merge_off"]["expected"]);
    }
    // A typed position never links, near or coincident.
    foreach (cell, x; ["scene_typed_near": 0.0034, "scene_typed_coincident": 0.0]) {
        rig(f0, 440, meshJson(tri(p(0, 0.2)), kTri));
        clickWorld(kFar[0], kFar[1], p(0.5, 0.2));
        typed("posX", format("%.6f", x));
        drop(); ++ran;
        fails ~= fixture(cell, c[cell]["expected"]);
    }
    // A second click on a stroke point selects it and adds nothing.
    {
        rig(f0, 440);
        clickWorld(p(0, 0.2), p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
        fails ~= current("stroke_double_click", 2);
        drop(); ++ran;
        fails ~= fixture("stroke_double_click", c["stroke_double_click"]["expected"]);
    }
    // 28 px from V (both zooms): no link.
    foreach (cell; ["scene_radius_440_d0.063636", "scene_radius_110_d0.254545"])
        fails ~= radiusCell(cell, c[cell], ran);
    // V 15 px away only AFTER the click (zoomed out): the decision is latched.
    // (The far points are ours: the captured pair spans 651 px, our viewport
    // 650; same side, same ring.)
    {
        rig(f0, 440, meshJson(tri(p(0.136364, 0.2)), kTri));
        clickWorld(p(0, 0.2));
        penCameraAt(p(0.09, 1.77), 110);
        clickWorld(p(-2.4, 3.33), p(2.6, 3.33));
        drop(); ++ran;
        auto want = verts(c["scene_latched_zoom_out"]["expected"]["vertices"]);
        want[4] = p(-2.4, 3.33); want[5] = p(2.6, 3.33);
        fails ~= compare("scene_latched_zoom_out", want,
                         rings(c["scene_latched_zoom_out"]["expected"]["polygons"]));
    }
    // A linked point dragged 40 px away unlinks: own vertex at the drag end,
    // V unmoved; one undo after the drop removes the stroke, T intact.
    {
        linkedStroke();
        dragWorld(p(0, 0.2), 40);
        drop(); ++ran;
        fails ~= fixture("scene_drag_linked_away", c["scene_drag_linked_away"]["expected"]);
        postJson("/api/command", "history.undo");
        auto u = c["scene_drag_linked_away_undo"]["expected_after_undo"];
        fails ~= compare("scene_drag_linked_away_undo", verts(u["vertices"]), rings(u["polygons"]));
    }
    // A linked point's typed edit unlinks it: own vertex at the typed value.
    {
        linkedStroke();
        typed("currentPoint", "0");
        typed("posX", "0.2");
        drop(); ++ran;
        fails ~= fixture("scene_typed_linked", c["scene_typed_linked"]["expected"]);
    }
    // F2: a link made AFTER a structure-silent topology bump (a Hide of an
    // unrelated face: counts unchanged; a subpatch toggle would drop the tool)
    // is kept, at each door that writes a link; the bump drops only older links.
    foreach (door; ["append", "insert", "drag"])
        fails ~= bumpThenLink(door, ran);
    // F2: the session image carries the links' mesh key. p0 linked to T; a
    // script undo removes T; a click re-keys the stroke; an in-stroke Ctrl+Z
    // restores the image before that click (p0's link AND its old key), so
    // Enter makes 3 own vertices.
    {
        rig(f0, 440);
        clickWorld(p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
        enter();
        clickWorld(p(0, 0.2), kFar[0], kFar[1]);
        auto r = postJson("/api/command", "history.undo");
        assert(r["status"].str == "ok", "F2-undo-restore: history.undo failed: " ~ r.toString);
        clickWorld(p(0.5, 0.2));
        const four = penAttrValue("points");
        ctrlZ();
        const three = penAttrValue("points");
        if (four != 4 || three != 3 || model().v.length != 0)
            fails ~= format("F2-undo-restore: rig premise, %s points after the click, %s "
                ~ "after Ctrl+Z, mesh %s vertices; expected 4, 3, 0", four, three,
                model().v.length);
        enter(); ++ran;
        fails ~= ownTriangle("F2-undo-restore");
    }
    // Edge snap: V 3.5 / 4.7 px from the snapped point (not an end of the
    // snapped edge) at three zooms, and the merge-off controls: no link.
    foreach (cell; ["Msmall_440_d3p5", "Msmall_440_d4p7", "Msmall_110_d3p5",
                    "Msmall_110_d4p7", "Msmall_880_d3p5", "Msmall_880_d4p7",
                    "Msmall_440_ctrl_merge0", "Msmall_110_ctrl_merge0",
                    "Msmall_880_ctrl_merge0"])
        fails ~= smallCell(cell, b3[cell], ran);
    // The snapped edge's own end 29.9 px away at 880: no link.
    fails ~= endCell("MsE_880_k30", b3["MsE_880_k30"], 0.104, ran);
    // Edge snap 19.8 px along from the end V: no link (V is past 17.5 px).
    fails ~= edgeE5Cell("snap_edge_e5_v20", c["snap_edge_e5_v20"], 0.045, ran);
    // Edge snap; an isolated V 5.0 / 5.5 px from the snapped point: no link.
    foreach (cell; ["snap_edge_isolated_ev5.0", "snap_edge_isolated_ev5.5"])
        fails ~= isolatedCell(cell, c[cell], "edge", -10, ran);
    // Grid snap 16 px from the pointer, V 13 px past the pointer (29 px from
    // the grid point): the grid point stands, no link.
    fails ~= gridCell("merge_grid_far", c["snap_grid_g15_v13"], 16, 29, false, ran);
    // A press 9 px from a stroke edge with merge off appends; 28 px off with
    // merge on appends; 28 px off a scene edge is an ordinary plane point.
    fails ~= edgePress("E2_edge_press_9px_merge0", ep["E2_edge_press_9px_merge0"], p(0.1, -0.02), false, ran);
    fails ~= edgePress("E3_edge_press_28px", ep["E3_edge_press_28px"], p(0.1, -0.065), true, ran);
    fails ~= sceneEdge("scene-edge-28px", ep["E4r_scene_edge_28px"], p(0.62, 0.235), ran);
    // Ours-only constructions (header).
    fails ~= constraintEdgeHighlight(ran);
    fails ~= bgEdgeNoReproject(ran);
    fails ~= vertexBeatsStrokeEdge(ran);

    // ===== must turn (no merge before this slice) ===========================
    // F2: a script-door history undo under a live linked stroke removes T; the
    // link does not outlive it (the next commit is 3 own vertices).
    {
        rig(f0, 440);
        clickWorld(p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
        enter();
        clickWorld(p(0, 0.2));
        auto r = postJson("/api/command", "history.undo");
        assert(r["status"].str == "ok", "F2: history.undo failed: " ~ r.toString);
        const live = penAttrValue("points"), left = model().v.length;
        if (live != 1 || left != 0)
            fails ~= format("F2: rig premise, after the undo the stroke has %s "
                ~ "points and the mesh %s vertices; expected 1 and 0", live, left);
        clickWorld(kFar[0], kFar[1]);
        enter(); ++ran;
        fails ~= ownTriangle("F2");
    }
    // A click exactly on a committed vertex shares its index.
    {
        rig(f0, 440);
        clickWorld(p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
        enter();
        clickWorld(p(0, 0.2), kFar[0], kFar[1]);
        drop(); ++ran;
        fails ~= fixture("scene_click_exact", c["scene_click_exact"]["expected"]);
    }
    // 20 px from V links at both zooms (a screen radius); V off the 0.01
    // lattice at 110 px/m keeps its own position.
    foreach (cell; ["scene_radius_440_d0.045455", "scene_radius_110_d0.181818",
                    "scene_radius_110_d0.010200"])
        fails ~= radiusCell(cell, c[cell], ran);
    // V 0.5 m above the click, 0 px on screen: linked, p0 takes V's height and
    // the next clicks land on its plane.
    {
        rig(f0, 440, meshJson(tri(p(0, 0.2, 1.5)), kTri));
        clickWorld(p(0, 0.2), kFar[0], kFar[1]);
        drop(); ++ran;
        fails ~= fixture("scene_screen_not_world", c["scene_screen_not_world"]["expected"]);
    }
    // V 15 px away at the click, 52.5 px after zooming in x3.5 (the captured
    // x4 spans 651 px, our viewport 650): still linked.
    {
        rig(f0, 440, meshJson(tri(p(0.034091, 0.2)), kTri));
        clickWorld(p(0, 0.2));
        penCameraAt(p(0.062, 0.2), 1540);
        clickWorld(p(-0.123, 0.199), p(0.247, 0.199));
        drop(); ++ran;
        fails ~= fixture("scene_latched_zoom_in", c["scene_latched_zoom_in"]["expected"]);
    }
    // A later click links as the first one does.
    {
        rig(f0, 440, meshJson(tri(p(0.034091, 0.2)), kTri));
        clickWorld(kFar[0], p(0, 0.2), kFar[1]);
        drop(); ++ran;
        fails ~= fixture("scene_later_click", c["scene_later_click"]["expected"]);
    }
    // A drag END ~7 px from V links (the drag end x is not scored: it is V).
    {
        rig(f0, 440, meshJson(tri(p(0.03, 0.2)), kTri));
        clickWorld(kFar[0], kFar[1], p(0.5, 0.2));
        dragWorld(p(0.5, 0.2), -200);
        drop(); ++ran;
        fails ~= fixture("scene_drag_end", c["scene_drag_end"]["expected"]);
    }
    // A linked point dragged 10 px stays linked.
    {
        linkedStroke();
        dragWorld(p(0, 0.2), 10);
        drop(); ++ran;
        fails ~= fixture("scene_drag_linked_short", c["scene_drag_linked_short"]["expected"]);
    }
    // In-stroke Ctrl+Z after dragging a linked point away restores the link.
    {
        linkedStroke();
        dragWorld(p(0, 0.2), 40);
        ctrlZ();
        drop(); ++ran;
        fails ~= fixture("link_undo", c["scene_linked_click_control"]["expected"]);
    }
    // Grid snap places the point, the merge searches from it: V 3 px past a
    // pointer 4 px from the grid point (7 px from it) links; a pointer on the
    // grid point with V 20.5 px from it links.
    fails ~= gridCell("merge_grid_near", c["snap_grid_g4_v3"], 4, 7, true, ran);
    fails ~= gridCell("merge_grid_from_placed", c["snap_grid_g0_v20"], 0, 20.5, true, ran);
    // Snapping on with no type: the merge acts (V 22 px).
    {
        rig(p(0.1, 0.2), 440, meshJson(tri(p(0.1 + 22 / 440.0, 0.2)), kTri), "");
        clickWorld(p(0.1, 0.2), kFar[0], kFar[1]);
        drop(); ++ran;
        fails ~= compare("merge_no_snap_type", tri(p(0.1 + 22 / 440.0, 0.2)) ~ kFar[],
                         [[0, 1, 2], [0, 4, 3]]);
    }
    // Edge snap 4.4 px along from the end V of the snapped edge: linked.
    fails ~= edgeE5Cell("merge_edge_then_vertex", c["snap_edge_e5_v6"], 0.01, ran);
    // Snapping off: an isolated V 10 px away links although an edge is nearer.
    fails ~= isolatedCell("snap_off_isolated_v10", c["snap_off_isolated_v10"], null, 6, ran);
    // The snapped edge's own end within 17.5 px links, at three zooms.
    foreach (cell, ex; ["MsE_440_k2": 0.075, "MsE_440_k3": 0.075, "MsE_440_k12": 0.095,
                        "MsE_440_k16": 0.105, "MsE_110_k4": 0.11, "MsE_110_k12": 0.18,
                        "MsE_880_k7": 0.078])
        fails ~= endCell(cell, b3[cell], ex, ran);
    // Any other vertex within 2.85 px links (along the edge, across it).
    foreach (cell; ["MsA_440_along2", "MsP_440_perp2"])
        fails ~= smallCell(cell, b3[cell], ran);
    fails ~= halfPixel(ran);
    // Vertex snap places p0 on V; the small search finds V at 0 px.
    {
        auto e = b3["Mvtx"]["expected"];
        rig(fE, 440, meshJson(verts(e["vertices"])[0 .. 3], kTri), "vertex");
        clickNear(p(0.3, 0.3), -10, 0);
        clickWorld(p(-0.56, -0.54), p(-0.56, 0.6));
        drop(); ++ran;
        fails ~= fixture("Mvtx", e);
    }
    // Edge snap: the QUANTISED pointer's foot on the edge, not re-rounded.
    {
        auto e = ep["Qedge_edge_snap"]["expected"];
        rig(fE, 440, meshJson(verts(e["vertices"])[0 .. 3], kTri), "edge");
        clickWorld(p(0.035, 0.38), p(-0.56, -0.54), p(-0.56, 0.6));
        drop(); ++ran;
        fails ~= fixture("Qedge_edge_snap", e);
    }
    // A press near a stroke edge (merge on) inserts between its ends at the
    // ordinary placed point; 20 px in; the closing edge's slot is the append.
    fails ~= edgePress("E1_edge_press_9px", ep["E1_edge_press_9px"], p(0.1, -0.02), true, ran, 1);
    fails ~= edgePress("E3_edge_press_20px", ep["E3_edge_press_20px"], p(0.1, -0.045), true, ran);
    {
        rig(fE, 440);
        clickWorld(p(-0.4, 0), p(0.4, 0), p(0, 0.5));
        typed("currentPoint", "0");
        clickWorld(p(-0.215, 0.265));
        fails ~= current("closing-edge-press", 3);
        drop(); ++ran;
        fails ~= fixture("closing-edge-press", ep["E5_closing_edge"]["expected"]);
    }
    fails ~= edgePressPerspective(ep["E1_psp_unpinned"]["expected"], ran);
    // A press 9 / 20 px from a SCENE edge lands on it, own vertex, T unsplit.
    fails ~= sceneEdge("E4_scene_edge_press", ep["E4_scene_edge_press"], p(0.62, 0.28), ran);
    fails ~= sceneEdge("scene-edge-20px", ep["E4r_scene_edge_20px"], p(0.62, 0.255), ran);

    snap(null);
    assert(ran == 67, format("pen merge population: %s cells ran, pinned 67", ran));

    // Blocked cells (kBlocked) must still fail; one that passes retires its mark.
    assert(kBlocked.length == 4, format("blocked marks: %s, pinned 4", kBlocked.length));
    string[] open, retired;
    foreach (f; fails)
        if (!(f[0 .. f.indexOf(':')] in kBlocked)) open ~= f;
    foreach (cell, why; kBlocked)
        if (!fails.canFind!(f => f.startsWith(cell ~ ":")))
            retired ~= cell ~ " (" ~ why ~ ")";
    assert(retired.length == 0, format("blocked cells now pass, retire their marks: %-(%s, %)",
                                       retired));
    assert(open.length == 0, format("pen merge, %s failing: %-(%s\n%)", open.length, open));
}

// Blocked cells (task 9362 card): they run and must still differ.
//   F3 the grid snap does not yet place the pen's point on the view's grid
//      node (each grid cell first asserts the click snapped to G);
//   F5 the merge search inherits the snap election's vertex veto: T's edge
//      midpoint 6.0 px from the placed point removes V at 12.0 px, so the
//      edge wins where the capture links V.
private immutable string[string] kBlocked = [
    "merge_grid_far": "F3", "merge_grid_near": "F3", "merge_grid_from_placed": "F3",
    "snap_off_isolated_v10": "F5",
];

// ---- cell bodies ----------------------------------------------------------

/// T (vertex 0 at V) and U committed by the pen, U selected in polygon mode;
/// a stroke starts, U is hidden (the topology counter moves, counts do not),
/// then a link to V is written through `door`: an appended click 6 px from V,
/// a click 6 px from V inserted after p0 (current point 0), or p1 dragged
/// from 28 px left of V onto it. Enter: 8 vertices, the third face shares V.
private string[] bumpThenLink(string door, ref int ran) {
    const cell = "F2-bump-then-" ~ door;
    rig(p(0, 0.2), 440);
    clickWorld(p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3));
    enter();
    clickWorld(p(0.4, -0.2), p(0.65, -0.2), p(0.55, -0.38));
    enter();
    penCommand("select.typeFrom polygon");      // drops the tool: re-armed
    penCommand("select.element polygon set 1");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge true");
    const Vec3 left = p(-28 / 440.0, 0.2);
    clickWorld(kFar[0]);
    if (door != "append") clickWorld(door == "drag" ? left : kFar[1]);
    const before = penAttrValue("points");
    auto r = postJson("/api/command", "mesh.hide");
    assert(r["status"].str == "ok", cell ~ ": hide failed: " ~ r.toString);
    const after = penAttrValue("points");
    string[] f;
    if (before != after || model().v.length != 6)
        f ~= format("%s: rig premise, the stroke has %s points before the hide and %s "
            ~ "after, the mesh %s vertices; expected equal, 6", cell, before, after,
            model().v.length);
    if (door == "append") { clickNear(p(0, 0.2), 6, 0); clickWorld(kFar[1]); }
    if (door == "insert") { typed("currentPoint", "0"); clickNear(p(0, 0.2), 6, 0); }
    if (door == "drag") { dragWorld(left, 28); clickWorld(kFar[1]); }
    enter(); ++ran;
    auto m = model();
    if (!(m.v.length == 8 && m.f.length == 3 && m.f[2].length == 3 &&
          m.f[2].canFind(0L) && m.f[2].canFind(6L) && m.f[2].canFind(7L)))
        f ~= format("%s: %s vertices, faces %s; expected 8, the third face sharing T's "
            ~ "vertex 0 with own vertices 6 and 7; vertices %s", cell, m.v.length, m.f, m.v);
    return f;
}

/// The committed mesh is exactly one stroke of 3 own vertices: one face, every
/// index in range.
private string[] ownTriangle(string cell) {
    auto m = model();
    bool inRange = m.f.length == 1;
    foreach (f; m.f) foreach (i; f) inRange &= i >= 0 && i < m.v.length;
    return m.v.length == 3 && inRange ? null
        : [format("%s: %s vertices, faces %s; expected 3 own vertices in one face",
                  cell, m.v.length, m.f)];
}

/// T with V on the K-C rig; the stroke clicks exactly on V, then two far
/// points (fixture `scene_linked_click_control`). Leaves the stroke live.
private void linkedStroke() {
    rig(p(0, 0.2), 440, meshJson(tri(p(0, 0.2)), kTri));
    clickWorld(p(0, 0.2), kFar[0], kFar[1]);
}

/// `scene_radius_*`: V typed at the cell's offset from the click.
private string[] radiusCell(string cell, JSONValue c, ref int ran) {
    auto e = c["expected"];
    const at110 = cell[13 .. 16] == "110";
    const click = at110 ? p(-1.86, -0.09) : p(0, 0.2);
    const far = at110 ? [p(-2.41, -1.8), p(1.47, 1.93)] : kFar[];
    auto t = verts(e["vertices"])[0 .. 3];
    rig(at110 ? p(-0.5, 0) : p(0, 0.2), at110 ? 110 : 440, meshJson(t, kTri));
    clickWorld(click, far[0], far[1]);
    drop(); ++ran;
    return fixture(cell, e);
}

/// M-small family (fixture `cells_k_b3`): edge snap only; the edited mesh is
/// [V, A, B, C] with the snapped edge A-B on z 0; the press is 8 px above the
/// edge at x 0.07 (E = (0.07, 1, 0) on every zoom's lattice).
private string[] smallCell(string cell, JSONValue c, ref int ran) {
    auto e = c["expected"];
    auto w = verts(e["vertices"]);
    const ppm = num(c["zoom_px_per_m"]);
    rig(p(0.07, 0), ppm, meshJson(w[0 .. 4], [[1, 2, 3]]), "edge",
        cell[$ - 6 .. $] != "merge0");
    clickNear(p(0.07, 0), 0, -8);
    clickWorld(w[$ - 2], w[$ - 1]);
    drop(); ++ran;
    return fixture(cell, e);
}

/// MsE family: the snapped edge's own end V at (0.07, 1, 0); the press is 8 px
/// above the edge at the cell's snapped x `ex` (on the zoom's lattice).
private string[] endCell(string cell, JSONValue c, double ex, ref int ran) {
    auto e = c["expected"];
    auto w = verts(e["vertices"]);
    const ppm = num(c["zoom_px_per_m"]);
    rig(p(0.07, 0), ppm, meshJson(w[0 .. 3], kTri), "edge");
    clickNear(p(ex, 0), 0, -8);
    clickWorld(w[$ - 2], w[$ - 1]);
    drop(); ++ran;
    return fixture(cell, e);
}

/// K-C2 edge cells on T = V (0, 0.2), (0.5, 0.2), (0.25, -0.3): the pointer 5 px
/// below the edge V-(0.5, 0.2) at the quantised x `qx`.
private string[] edgeE5Cell(string cell, JSONValue c, double qx, ref int ran) {
    auto e = c["expected"];
    rig(p(0, 0.2), 440, meshJson([p(0, 0.2), p(0.5, 0.2), p(0.25, -0.3)], kTri), "edge");
    clickWorld(p(qx, 0.19), kFar[0], kFar[1]);
    drop(); ++ran;
    return fixture(cell, e);
}

/// K-C2 isolated-vertex cells: the edited mesh is [V, A, B, C] (fixture
/// order), the pointer at x 0.35, `dz` px from A-B (z 0.279545) in z: on V's
/// side (-10: V 5 px from the edge point) or across the edge (6: the edge
/// 6 px, V 12 px away).
private string[] isolatedCell(string cell, JSONValue c, string types, int dz, ref int ran) {
    auto e = c["expected"];
    auto w = verts(e["vertices"]);
    rig(p(0, 0.35), 440, meshJson(w[0 .. 4], [[1, 2, 3]]), types);
    clickWorld(p(0.35, 0.279545 + dz / 440.0));
    clickWorld(kFar[0], kFar[1]);
    drop(); ++ran;
    return fixture(cell, e);
}

/// Grid snap (grid 0.1 at 440 px/m): the grid point G (0.1, 1, 0.2) at the
/// view centre, the pointer `dg` px right of it, V typed `dv` px right of G.
private string[] gridCell(string cell, JSONValue c, int dg, double dv, bool linked,
                          ref int ran) {
    const g = p(0.1, 0.2);
    const v = p(0.1 + dv / 440, 0.2);
    rig(g, 440, meshJson(tri(v), kTri), "grid");
    clickWorld(p(0.1 + dg / 440.0, 0.2));
    // Must-stay-green premise above the link assert: the click snapped to G
    // (without it a pointer this close links V by the merge alone).
    auto s = fetchSnapLast();
    const w = s["worldPos"].array;
    const bool onG = s["snapped"].type == JSONType.true_ && abs(w[0].floating - g.x) < 1e-4
        && abs(w[1].floating - g.y) < 1e-4 && abs(w[2].floating - g.z) < 1e-4;
    clickWorld(kFar[0], kFar[1]);
    drop(); ++ran;
    if (!onG)
        return [format("%s: grid premise, the click %s px from G did not snap to it: %s",
                       cell, dg, s.toString)];
    auto want = linked ? tri(v) ~ kFar[] : tri(v) ~ g ~ kFar[];
    auto e = c["expected"];
    if (linked != (verts(e["vertices"]).length == 5))
        return [cell ~ ": fixture premise (linked) does not hold"];
    return compare(cell, want, rings(faces(e)));
}

/// E1-E3 rig: the triangle stroke p0 (-0.4, 0), p1 (0.4, 0), p2 (0, 0.5),
/// current 2; one press at the quantised point `at`.
private string[] edgePress(string cell, JSONValue c, Vec3 at, bool merge, ref int ran,
                           double wantCurrent = double.nan) {
    rig(p(0.07, 0), 440, null, null, merge);
    clickWorld(p(-0.4, 0), p(0.4, 0), p(0, 0.5), at);
    string[] f;
    if (wantCurrent == wantCurrent) f ~= current(cell, wantCurrent);
    drop(); ++ran;
    return f ~ fixture(cell, c["expected"]);
}

/// E4 rig: scene T (0.3, 0.3), (0.9, 0.3), (0.6, 0.8); stroke p0 (-0.8, -0.6),
/// p1 (-0.2, -0.8); a press at the quantised point `at` below T's edge z 0.3.
private string[] sceneEdge(string cell, JSONValue c, Vec3 at, ref int ran) {
    rig(p(-0.09, -0.26), 440, meshJson([p(0.3, 0.3), p(0.9, 0.3), p(0.6, 0.8)], kTri));
    clickWorld(p(-0.8, -0.6), p(-0.2, -0.8), at);
    drop(); ++ran;
    return fixture(cell, c["expected"]);
}

/// E1 under the unpinned perspective view (plane y 1.0): a press 9 px off the
/// screen segment p0-p1, outside the triangle; index 1, ring [1, 0, 3, 2].
private string[] edgePressPerspective(JSONValue e, ref int ran) {
    penSceneEmpty("Perspective");
    penCameraAt(p(0.07, 0), 440);
    snap(null);
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge true");
    auto w = verts(e["vertices"]);
    clickWorld(w[0], w[2], w[3]);
    const a = fpx(w[0]), b = fpx(w[2]), cc = fpx(w[3]);
    float mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2;
    float nx = -(b[1] - a[1]), ny = b[0] - a[0];
    const len = sqrt(nx * nx + ny * ny);
    nx /= len; ny /= len;
    if (nx * (cc[0] - mx) + ny * (cc[1] - my) > 0) { nx = -nx; ny = -ny; }
    clickPixels([cast(int)round(mx + 9 * nx), cast(int)round(my + 9 * ny)]);
    string[] f = current("edge-press-persp-unpinned", 1);
    drop(); ++ran;
    auto m = model();
    if (m.v.length != 4 || m.f != [[1L, 0, 3, 2]])
        return f ~ format("edge-press-persp-unpinned: %s vertices, faces %s; expected 4, "
            ~ "[[1, 0, 3, 2]]", m.v.length, m.f);
    const q = num(getJson("/api/viewport/display")["cells"].array[0]["grid"]["subStep"]);
    bool lattice(float v) { return abs(v / q - round(v / q)) < 1e-3; }
    if (!(abs(m.v[1].y - 1) <= 1e-5 && lattice(m.v[1].x) && lattice(m.v[1].z)))
        f ~= format("edge-press-persp-unpinned: the inserted point %s is not on the "
            ~ "plane y 1 / our q %s lattice", m.v[1], q);
    return f;
}

private string[] constraintEdgeHighlight(ref int ran) {
    // T's edge A-B on z 0.3; the pointer 30 px below it at x 0.6 (> 30 px from
    // every vertex and from the box corners).
    rig(p(0.6, 0.2), 440, meshJson([p(0.3, 0.3), p(0.9, 0.3), p(0.6, 0.8)], kTriUp),
        "edge,box");
    const at = p(0.6, 0.3 - 30 / 440.0);
    clickNear(p(0.6, 0.3), 0, -30);
    const s = fetchSnapLast();
    clickWorld(p(0.3, -0.1), p(0.8, -0.1));
    drop(); ++ran;
    auto m = model();
    string[] f;
    // A snapped result whose position is off the highlighted edge is a
    // constraint win (a discrete edge win sits on the edge).
    if (s["snapped"].type != JSONType.true_ || s["targetType"].integer != 2 ||
        !(abs(num(s["worldPos"].array[2]) - 0.3) >= 0.02))
        f ~= "constraint-edge-highlight: rig premise, the click was not a constraint "
            ~ "win with an edge highlight: " ~ s.toString;
    if (m.v.length != 6 || !(abs(m.v[3].x - 0.6) <= 0.003 && abs(m.v[3].z - at.z) <= 0.003 &&
                             abs(m.v[3].z - 0.3) >= 0.02))
        f ~= format("constraint-edge-highlight: %s vertices, p0 %s; expected 6, p0 at the "
            ~ "pointer (0.6, %.4f), >= 0.02 m off the edge", m.v.length,
            m.v.length > 3 ? m.v[3] : Vec3(0, 0, 0), at.z);
    return f;
}

private string[] bgEdgeNoReproject(ref int ran) {
    // Background layer: a triangle with an edge on z 0.3; the edited layer: a
    // triangle far away (its edge indices exist but lie elsewhere).
    penSceneEmpty("Top");
    auto r = postJson("/api/command", commandBody("scene.loadMesh",
        meshJson([p(0.3, 0.3), p(0.9, 0.3), p(0.6, 0.8)], kTriUp)));
    assert(r["status"].str == "ok", "bg load failed: " ~ r.toString);
    penCommand("layer.add name:Edit");
    r = postJson("/api/command", commandBody("scene.loadMesh",
        meshJson([p(-0.9, -0.9), p(-0.5, -0.9), p(-0.7, -0.5)], kTriUp)));
    assert(r["status"].str == "ok", "fg load failed: " ~ r.toString);
    penCommand("history.clear");
    penCommand("viewport.view Top");
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "bg rig premise: the top view must be orthographic");
    penCameraAt(p(0.07, 0), 440);
    snap("edge");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge true");
    clickWorld(p(0.62, 0.28));
    const s = fetchSnapLast();
    clickWorld(p(-0.2, -0.3), p(0.2, -0.3));
    drop(); ++ran;
    auto m = model();
    string[] f;
    if (s["snapped"].type != JSONType.true_ || s["targetSource"].integer == 0)
        f ~= "bg-edge-snap-no-reproject: rig premise, the click did not snap to the "
            ~ "background edge: " ~ s.toString;
    if (m.v.length != 6 || m.f.length != 2 || m.f[0] != [0L, 2, 1] ||
        !(abs(m.v[3].x - 0.62) <= 0.003 && abs(m.v[3].z - 0.3) <= 1e-4))
        f ~= format("bg-edge-snap-no-reproject: %s vertices, faces %s, p0 %s; expected 6, "
            ~ "the edited triangle intact, p0 on the background edge (0.62, 0.3)",
            m.v.length, m.f, m.v.length > 3 ? m.v[3] : Vec3(0, 0, 0));
    return f;
}

private string[] vertexBeatsStrokeEdge(ref int ran) {
    rig(p(0.07, 0), 440);
    clickWorld(p(-0.4, 0), p(0.4, 0), p(0, 0.5));
    clickNear(p(0.4, 0), -2, 0);        // on p1's marker, on edge p0-p1
    string[] f = current("vertex-beats-stroke-edge", 1);
    const n = penAttrValue("points");
    drop(); ++ran;
    if (n != 3) f ~= format("vertex-beats-stroke-edge: %s stroke points, expected 3", n);
    return f;
}

private string[] halfPixel(ref int ran) {
    // MsP's edge A-B on z 0, E = (0.07, 1, 0) projected to x.5 px (the focus
    // half a pixel left of E); V on the edge 2.6 px LEFT of E, the rounded pixel
    // is the one to E's right.
    const ppm = 440.0, e = 0.07;
    const v = p(e - 2.6 / ppm, 0);
    rig(p(e, 0), ppm, meshJson([v, p(-0.384545, 0), p(0.524545, 0),
        p(0.297273, 0.340909)], [[1, 2, 3]]), "edge");
    const e0 = fpx(p(e, 0))[0];
    penCameraAt(p(e - (round(e0) + 0.5 - e0) / ppm, 0), ppm);
    const ex = fpx(p(e, 0))[0];
    assert(abs(ex - round(ex)) > 0.45 && fpx(v)[0] < ex, format("half-pixel rig: E "
        ~ "projects to x %s, V to %s", ex, fpx(v)[0]));
    clickNear(p(e, 0), 0, -8);
    clickWorld(p(-0.555, -0.54), p(-0.555, 0.6));
    drop(); ++ran;
    return compare("half-pixel", [v, p(-0.384545, 0), p(0.524545, 0), p(0.297273, 0.340909),
                   p(-0.555, -0.54), p(-0.555, 0.6)], [[1, 2, 3], [0, 4, 5]]);
}
