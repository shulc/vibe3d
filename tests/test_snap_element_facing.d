// SNAP: facing is a POLYGON term; the grid step is the view's grid; the grid
// node is the CLIENT's point with its in-plane channels rounded, it has no
// pixel range, and it ranks below an element in range and above a constraint
// (task 9387, wave plan §24.2 / §28.2 S5v; law `doc/measured_laws.md` §3).
//
// Rig: top orthographic view at 440 px/m, one snap type bit per cell, the
// pointer 6 px from its target (inside the 5–8 px the captured edge snaps
// used). T = (0.3,1,0.3), (0.9,1,0.3), (0.6,1,0.8): ring [0,1,2] has the
// corner normal −Y, i.e. it is BACK-facing from the top; ring [0,2,1] faces
// the eye. Queries go through `/api/snap`, which answers from the snap stage's
// own packet (types, ranges AND the grid step it publishes).
//
// Captured rows (fixture `pen_merge.json` `cells_k_b6` in the capture tree,
// cell ids neutral): `vtx-back` = V1, `loose-vtx` = V2, `grid-second-rung` =
// G2 (label 0.5 at 110 px/m), `move-grid-step` = G3; `edge-back` = the edge
// leg (pen, merge off) and X2 (Move). `poly-back` / `poly-front` match P1.
// Cells 15–22 lift `cells_k_b7` (G4, G5, G6, G6b, G8, G9, G4c, G8b2, G8b3)
// and `cells_k_b9` (K9a, K9d).

import drag_helpers : Vec3, Viewport, buildDragDownLog, buildDragLog, buildDragMotionLog,
    buildDragUpLog, fetchCamera, playAndWait,
    projectToWindow, viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers : penAttr, penCameraAt, penCommand, penSceneEmpty, readVerts,
    worldPixel, clickPixels;
import std.algorithm : canFind;
import std.format : format;
import std.string : indexOf;
import std.json : JSONType, JSONValue;
import std.math : abs;

void main() {}

private enum double kPpm = 440.0;
private enum double kPx = 1.0 / kPpm;          // one pixel of world at the rig zoom
private enum double kTol = 1e-4;               // exact channels
private enum double kHalfPx = 0.5 * kPx;       // a channel read off a pixel

private int ran;
private string[] fails;   // every cell runs; the reds are reported together

private void check(bool ok, lazy string msg) { if (!ok) fails ~= msg; }

/// A JSON number; anything else (a NaN is published as null) reads as NaN,
/// so a cell's tolerance test fails on it instead of the read throwing.
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.float_ ? v.floating : double.nan;
}

/// Vertex `i` of the primary mesh (NaN channels read as NaN).
private double[3] vpos(int i) {
    auto a = getJson("/api/model")["vertices"].array[i].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

private void loadMesh(string json) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", json));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
}

/// Empty scene, then `mesh`, then the top ortho view at `ppm` with the focus
/// at `focus` (loading resets the camera, so the camera comes last).
private void rig(string mesh, Vec3 focus, double ppm = kPpm) {
    penSceneEmpty("Top");
    if (mesh.length) loadMesh(mesh);
    penCommand("viewport.view Top");
    penCameraAt(focus, ppm);
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig premise: the top view must be orthographic");
}

/// The type bits (a comma list), the shipped ranges, the view's grid.
private void snapTypes(string types) {
    penCommand("tool.pipe.attr snap enabled true");
    penCommand(`tool.pipe.attr snap types "` ~ types ~ `"`);
    penCommand("tool.pipe.attr snap fixedGrid false");
    penCommand("tool.pipe.attr snap innerRange 24");
    penCommand("tool.pipe.attr snap outerRange 40");
}

/// `/api/snap` at the pixel of `w`, with `w` as the client point.
private JSONValue snapAt(Vec3 w) {
    const px = worldPixel(w);
    return postJson("/api/snap", format(
        `{"cursor":[%.9f,%.9f,%.9f],"sx":%d,"sy":%d,"excludeVerts":[]}`,
        w.x, w.y, w.z, px[0], px[1]));
}

private bool snapped(JSONValue sr) { return sr["snapped"].type == JSONType.true_; }

private double[3] pos(JSONValue sr) {
    auto a = sr["worldPos"].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

private string tri(bool front, string extra = "", string extraFaces = "") {
    return `{"vertices":[[0.3,1,0.3],[0.9,1,0.3],[0.6,1,0.8]` ~ extra
        ~ `],"faces":[` ~ (front ? "[0,2,1]" : "[0,1,2]") ~ extraFaces ~ `]}`;
}

/// The world point 6 px to the LEFT (−x) of `w` (top view: +x is right).
private Vec3 leftOf(Vec3 w) {
    return Vec3(cast(float)(w.x - 6 * kPx), w.y, w.z);
}

private void expectAt(JSONValue sr, double[3] want, double tolXZ, string cell) {
    if (!snapped(sr)) { fails ~= cell ~ ": expected a snap, got " ~ sr.toString; return; }
    const g = pos(sr);
    check(abs(g[0] - want[0]) <= tolXZ && abs(g[2] - want[2]) <= tolXZ
        && abs(g[1] - want[1]) <= kTol,
        format("%s: snapped to (%.6f, %.6f, %.6f), expected (%.4f, %.4f, %.4f)",
               cell, g[0], g[1], g[2], want[0], want[1], want[2]));
}


/// The pen armed with merge off: every K-B7 pen cell was captured so, and
/// cell 23's subject is the placement, not the merge.
private void penMerge0() {
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge false");
}

/// One Move drag of the selection from the pixel of `from` to the pixel of
/// `to` in `steps` motion events (the tool must be armed).
private void moveDrag(Vec3 from, Vec3 to, int steps) {
    auto cam = fetchCamera();
    const a = worldPixel(from), b = worldPixel(to);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             a[0], a[1], b[0], b[1], steps));
}

/// G3's quad (ring [0,3,2,1]) at height `y`, `extra` vertices appended; vertex
/// 0 selected, the Move tool armed with the snap types `types`.
private void moveRig(double y, string types, string extra = "") {
    rig(format(`{"vertices":[[0.03,%s,0.07],[0.53,%s,0.07],[0.53,%s,0.57],`
        ~ `[0.03,%s,0.57]%s],"faces":[[0,3,2,1]]}`, y, y, y, y, extra),
        Vec3(0.28f, 1, 0.32f));
    penCommand("select.typeFrom vertex");
    auto r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":[0]}`));
    assert(r["status"].str == "ok", "select q failed: " ~ r.toString);
    penCommand("tool.set move");
    snapTypes(types);
}

private string vstr(double[3] q) { return format("(%.6f, %.6f, %.6f)", q[0], q[1], q[2]); }
private bool at(double[3] q, double[3] w, double tol = kTol) {
    return abs(q[0] - w[0]) <= tol && abs(q[1] - w[1]) <= tol && abs(q[2] - w[2]) <= tol;
}
private bool at(Vec3 v, double[3] w, double tol = kTol) { return at([v.x, v.y, v.z], w, tol); }

/// OUR drawn grid step in the active view.
private double viewStep() {
    return num(getJson("/api/viewport/display")["cells"].array[0]["grid"]["size"]);
}

/// Pixel distance between the projections of two world points.
private double pxDist(Vec3 a, Vec3 b) {
    auto vp = viewportFromCameraMatrices();
    float ax, ay, bx, by;
    assert(projectToWindow(a, vp, ax, ay) && projectToWindow(b, vp, bx, by),
        "rig point behind the camera");
    return ((ax - bx) ^^ 2 + (ay - by) ^^ 2) ^^ 0.5;
}

/// Cells 11–13, the grid step from the view.
private void gridCells() {
    // 11 grid-view-step — K-C2's geometry: pointer 15.5 px from (0.1, 0.2) at
    // 440 px/m ⇒ the 0.1 node, in the client point's own plane (y 1).
    rig("", Vec3(0.1f, 1, 0.2f)); snapTypes("grid");
    {
        const step = viewStep();
        assert(abs(step - 0.1) < 1e-6, format("grid-view-step rig: OUR drawn "
            ~ "step at 440 px/m must be 0.1, got %s", step));
        auto sr = snapAt(Vec3(cast(float)(0.1 + 15.5 * kPx), 1, 0.2f));
        check(snapped(sr) && abs(pos(sr)[0] - 0.1) <= kTol && abs(pos(sr)[2] - 0.2) <= kTol,
            "grid-view-step: the pointer lands on the visible grid's (0.1, 0.2) "
            ~ "node, got " ~ sr.toString);
        ++ran;
    }

    // 12 grid-second-rung (G2): at 110 px/m the drawn grid is 0.5 (the
    // captured label), and the captured pointer lands on its (0, 0.5) node —
    // a constant 0.1 step would give (0, 0.3). The node is 25 px away, past
    // the 24 px element acceptance: the grid has no pixel range.
    {
        enum double kG2Ppm = 110.0, kG2Step = 0.5;
        rig("", Vec3(0.2f, 1, 0.3f), kG2Ppm); snapTypes("grid");
        const step = viewStep();
        assert(abs(step - kG2Step) < 1e-6,
            format("grid-second-rung rig: OUR step at %s px/m must equal the "
                ~ "captured %s, got %s", kG2Ppm, kG2Step, step));
        auto sr = snapAt(Vec3(0.006364f, 1, 0.272727f));
        const double wx = 0, wz = 0.5;
        check(snapped(sr) && abs(pos(sr)[0] - wx) <= kTol && abs(pos(sr)[2] - wz) <= kTol,
            format("grid-second-rung: expected the (%s, %s) node of the %s step, got %s",
                   wx, wz, kG2Step, sr.toString));
        ++ran;
    }

    // 13 move-grid-step (G3): the Move tool, vertex mode, grid bit only; press
    // on q's pixel, drag to the pixel of (0.1252, 1, 0.1952) — the moved
    // vertex's ABSOLUTE position lands on the 0.1 node (a delta snap would
    // give (0.13, 1, 0.17)), at its own height y 1.
    {
        moveRig(1, "grid");
        moveDrag(Vec3(0.03f, 1, 0.07f), Vec3(0.1252f, 1, 0.1952f), 20);
        const q = vpos(0);
        penCommand("tool.set move off");
        check(at(q, [0.1, 1, 0.2]), "move-grid-step: q expected on the (0.1, 1, 0.2) "
            ~ "node, got " ~ vstr(q));
        ++ran;
    }
}

/// Cells 15–22 (+ 17b), `cells_k_b7`, and 23 (ours). Rig as K-B7's: top
/// ortho, 440 px/m unless stated, all values captured; slow drags are ≤ 4 px
/// per event.
private void gridLawCells() {
    // 15 move-grid-low (G4): the quad at y 0.4; q's free drag to the pixel of
    // (0.1252, ·, 0.1952) in 35 events of ≤ 4 px (as captured) lands on the
    // node of press + travel, at q's own height 0.4. A client fed its own
    // snapped position back stays on the press node (0, 0.1).
    {
        moveRig(0.4, "grid");
        moveDrag(Vec3(0.03f, 0.4f, 0.07f), Vec3(0.1252f, 0.4f, 0.1952f), 35);
        const q = vpos(0);
        penCommand("tool.set move off");
        check(at(q, [0.1, 0.4, 0.2]), "move-grid-low: q expected (0.1, 0.4, 0.2), got "
            ~ vstr(q));
        ++ran;
    }

    // 16 pen-grid-current-plane (G5): vertex + grid; loose S (0.805, 0.5, 0.8).
    // p0 on S's pixel = S (must stay green, asserted first); p1 at the pixel of
    // (0.1252, ·, 0.1952) = the node in the plane through the current point,
    // y 0.5; the two far clicks land at y 0.5 too.
    {
        rig(`{"vertices":[[0.805,0.5,0.8]],"faces":[]}`, Vec3(0.25f, 1, 0.45f));
        penMerge0();
        snapTypes("vertex,grid");
        clickPixels(worldPixel(Vec3(0.805f, 0.5f, 0.8f)),
                    worldPixel(Vec3(0.1252f, 0.5f, 0.1952f)),
                    worldPixel(Vec3(-0.2f, 0.5f, 0.6f)),
                    worldPixel(Vec3(-0.3f, 0.5f, 0.2f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        if (vs.length != 5) {
            fails ~= format("pen-grid-current-plane: 1 scene + 4 stroke vertices, got %s", vs);
        } else if (!at(vs[1], [0.805, 0.5, 0.8])) {
            fails ~= format("pen-grid-current-plane: p0 must be S (0.805, 0.5, 0.8), got %s",
                            vs[1]);
        } else {
            check(at(vs[2], [0.1, 0.5, 0.2]), format("pen-grid-current-plane: p1 "
                ~ "expected the node (0.1, 0.5, 0.2), got %s", vs[2]));
            check(abs(vs[3].y - 0.5) <= kTol && abs(vs[4].y - 0.5) <= kTol,
                format("pen-grid-current-plane: far clicks expected at y 0.5, got %s %s",
                       vs[3], vs[4]));
        }
        ++ran;
    }

    // 17 pen-grid-far (G6): grid only, 123 px/m (step 0.5); the click at the
    // pixel of (0.24, ·, 0.26) lands on the (0, 0.5) node 41.75 px away — past
    // our 40 px outer range: the grid has none.
    {
        enum double kPpm6 = 123.0;
        rig("", Vec3(0.07f, 1, 0), kPpm6);
        penMerge0();
        snapTypes("grid");
        const step = viewStep();
        const Vec3 ptr = Vec3(0.24f, 1, 0.26f), node = Vec3(0, 1, 0.5f);
        const dn = pxDist(ptr, node);
        assert(abs(step - 0.5) < 1e-6 && dn > 40,
            format("pen-grid-far rig: OUR step at %s px/m must be 0.5 (got %s) "
                ~ "and the node beyond 40 px (got %.2f)", kPpm6, step, dn));
        clickPixels(worldPixel(ptr), worldPixel(Vec3(-1, 1, -1)),
                    worldPixel(Vec3(-1, 1, 1)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 3 && at(vs[0], [0, 1, 0.5]),
            format("pen-grid-far: p0 expected the (0, 1, 0.5) node, got %s", vs));
        ++ran;
    }

    // 17b pen-grid-far-ladder (G6b): ladder {1, 10} (mask 0), 120 px/m (step
    // 1); the click at the pixel of (0.45, ·, 0.55) lands on (0, 1, 1), 76 px
    // away. The ladder is restored after.
    {
        const mask = cast(long)num(getJson("/api/viewport/display")["cells"]
            .array[0]["grid"]["mask"]);
        penCommand(`{"id":"viewport.gridSteps","params":"0"}`);
        scope (exit) penCommand(format(`{"id":"viewport.gridSteps","params":"%d"}`, mask));
        rig("", Vec3(0.07f, 1, 0), 120);
        penMerge0();
        snapTypes("grid");
        const step = viewStep();
        const Vec3 ptr = Vec3(0.45f, 1, 0.55f);
        const dn = pxDist(ptr, Vec3(0, 1, 1));
        assert(abs(step - 1) < 1e-6 && dn > 70,
            format("pen-grid-far-ladder rig: OUR step on {1, 10} at 120 px/m must "
                ~ "be 1 (got %s) and the node ~76 px away (got %.2f)", step, dn));
        clickPixels(worldPixel(ptr), worldPixel(Vec3(-1, 1, -1)),
                    worldPixel(Vec3(-1, 1, 1)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 3 && at(vs[0], [0, 1, 1]),
            format("pen-grid-far-ladder: p0 expected the (0, 1, 1) node, got %s", vs));
        ++ran;
    }

    // 18 pen-grid-vs-vertex (G8): vertex + grid; loose S8 (0.2323, 0.5, 0.3);
    // the click at the pixel of (0.205, ·, 0.3) — node 2.2 px, S8 12 px — lands
    // on S8: an element in range beats the nearer node.
    {
        rig(`{"vertices":[[0.2323,0.5,0.3]],"faces":[]}`, Vec3(0.07f, 1, 0));
        penMerge0();
        snapTypes("vertex,grid");
        clickPixels(worldPixel(Vec3(0.205f, 1, 0.3f)), worldPixel(Vec3(-0.4f, 1, -0.3f)),
                    worldPixel(Vec3(-0.5f, 1, 0.1f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 4 && at(vs[1], [0.2323, 0.5, 0.3]),
            format("pen-grid-vs-vertex: p0 expected S8 (0.2323, 0.5, 0.3), got %s", vs));
        ++ran;
    }

    // 19 move-axis-grid (G9; K9a: the same drag as 20 separate slow events,
    // `cells_k_b9`). q (0.03, 1, 0.07); press on OUR +X shaft 66 px right of
    // the gizmo centre (the shaft spans 24..120 px); +40 px in 20 events of
    // 2 px. The node rounds q + travel (0.1209 → 0.1) and is held on the axis
    // (z 0.07); the pointer's own node is 0.3, a fed-back client stays at 0.0.
    {
        moveRig(1, "grid");
        auto cam = fetchCamera();
        const c = worldPixel(Vec3(0.03f, 1, 0.07f));
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 c[0] + 66, c[1], c[0] + 106, c[1], 20));
        const q = vpos(0);
        penCommand("tool.set move off");
        check(at(q, [0.1, 1, 0.07]), "move-axis-grid: q expected (0.1, 1, 0.07), got "
            ~ vstr(q));
        ++ran;
    }

    // 19b move-grid-second-drag (ours): after G3's drag (q on the (0.1, 0.2)
    // node, its client 0.0252 m right of it), a second drag in the same
    // session, +60 px in 2 px events, starts its client at ITS press: q.x
    // 0.1 + 0.136 → 0.2 (a client kept from the first drag gives 0.3).
    {
        moveRig(1, "grid");
        moveDrag(Vec3(0.03f, 1, 0.07f), Vec3(0.1252f, 1, 0.1952f), 20);
        const q1 = vpos(0);
        auto cam = fetchCamera();
        const g = worldPixel(Vec3(0.1f, 1, 0.2f));
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 g[0], g[1], g[0] + 60, g[1], 30));
        const q = vpos(0);
        penCommand("tool.set move off");
        if (!at(q1, [0.1, 1, 0.2]))
            fails ~= "move-grid-second-drag: the first drag expected q on (0.1, 1, 0.2), got "
                ~ vstr(q1);
        else
            check(at(q, [0.2, 1, 0.2]), "move-grid-second-drag: q expected (0.2, 1, 0.2), got "
                ~ vstr(q));
        ++ran;
    }

    // 20 move-vertex-offplane (G4c; a guard of ours): vertex bit only, the
    // quad at y 0.4, loose T (0.13, 1, 0.23); q dragged onto T's pixel takes
    // T's whole 3-D position (the free drag keeps the full snap delta).
    {
        moveRig(0.4, "vertex", ",[0.13,1,0.23]");
        moveDrag(Vec3(0.03f, 0.4f, 0.07f), Vec3(0.13f, 1, 0.23f), 35);
        const q = vpos(0);
        penCommand("tool.set move off");
        check(at(q, [0.13, 1, 0.23]), "move-vertex-offplane: q expected T "
            ~ "(0.13, 1, 0.23), got " ~ vstr(q));
        ++ran;
    }

    // 20b move-vertex-release (K9d, `cells_k_b9`): vertex bit only, the quad
    // at y 1, loose T (0.13, 1, 0.07) 44 px right of q; q's free drag in 52
    // events of +2 px. Mid-drag (24 events, 48 px) q sits ON T; after the
    // pointer leaves the range it rejoins the pointer: q ends at the raw
    // q + 104 px (± half a pixel; the captured 0.265 carries the reference's
    // 0.005 free-drag quantum, ours has none), not raw minus a retained
    // offset (≤ 0.212) nor on T (0.13).
    {
        moveRig(1, "vertex", ",[0.13,1,0.07]");
        auto cam = fetchCamera();
        const a = worldPixel(Vec3(0.03f, 1, 0.07f));
        playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1]));
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       a[0], a[1], a[0] + 48, a[1], 24));
        const mid = vpos(0);
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       a[0] + 48, a[1], a[0] + 104, a[1], 28));
        playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                   a[0] + 104, a[1]));
        const q = vpos(0);
        penCommand("tool.set move off");
        const double raw = 0.03 + 104 * kPx;
        if (!at(mid, [0.13, 1, 0.07]))
            fails ~= "move-vertex-release: mid-drag q expected ON T (0.13, 1, 0.07), got "
                ~ vstr(mid);
        else
            check(abs(q[0] - raw) <= kHalfPx && abs(q[1] - 1) <= kTol && abs(q[2] - 0.07) <= kTol,
                format("move-vertex-release: q expected back on the pointer (%.6f, 1, 0.07), "
                    ~ "got %s", raw, vstr(q)));
        ++ran;
    }

    // 20c move-snap-held (ours; the K9d law at the gesture's edges): vertex
    // bit only, the quad at y 1, loose T (0.13, 1, 0.07). (A) q dragged 24 px
    // right (20 px short of T) snaps onto T and is released there — the drag
    // ends holding T 20 px off its pointer. (B) A new drag from the gizmo,
    // 40 px down in 2 px events (on T for the first 24 px), ends on its own
    // pointer: no offset held by the previous gesture survives. (C) A drag
    // 18 px back up (22 px from T: on T) then, with snap switched off
    // mid-drag, 2 px more: the unsnapped event rejoins the pointer (20 px
    // below T), not T moved 2 px up.
    {
        moveRig(1, "vertex", ",[0.13,1,0.07]");
        auto cam = fetchCamera();
        void drag(int[2] from, int dx, int dy, int steps) {
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, from[0],
                                     from[1], from[0] + dx, from[1] + dy, steps));
        }
        drag(worldPixel(Vec3(0.03f, 1, 0.07f)), 24, 0, 12);
        const qa = vpos(0);
        drag(worldPixel(Vec3(0.13f, 1, 0.07f)), 0, 40, 20);
        const qb = vpos(0);
        const b = worldPixel(Vec3(0.13f, 1, cast(float)(0.07 + 40 * kPx)));
        playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, b[0], b[1]));
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       b[0], b[1], b[0], b[1] - 18, 1));
        const qc1 = vpos(0);
        penCommand("tool.pipe.attr snap enabled false");
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       b[0], b[1] - 18, b[0], b[1] - 20, 1));
        playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, b[0], b[1] - 20));
        const qc = vpos(0);
        penCommand("tool.set move off");
        if (!at(qa, [0.13, 1, 0.07]))
            fails ~= "move-snap-held: (A) q expected on T, got " ~ vstr(qa);
        else if (!at(qb, [0.13, 1, 0.07 + 40 * kPx], kHalfPx))
            fails ~= format("move-snap-held: (B) q expected at its own pointer "
                ~ "(0.13, 1, %.6f), got %s", 0.07 + 40 * kPx, vstr(qb));
        else if (!at(qc1, [0.13, 1, 0.07]))
            fails ~= "move-snap-held: (C) q expected back on T, got " ~ vstr(qc1);
        else
            check(at(qc, [0.13, 1, 0.07 + 20 * kPx], kHalfPx),
                format("move-snap-held: (C) snap off mid-drag: q expected at its pointer "
                    ~ "(0.13, 1, %.6f), got %s", 0.07 + 20 * kPx, vstr(qc)));
        ++ran;
    }

    // 21 pen-grid-vs-guide (G8b2): grid + worldAxis. Our pen's world-axis
    // guide runs through the PRIOR vertex, so the captured guide line z −0.58
    // through p1 is built as the stroke's first point (a node click typed to
    // z −0.58); the next click 3.9 px off that line, 13.6 px from the
    // (0, −0.6) node, lands on the node: GRID, not AXIS (0.01, 1, −0.58) nor
    // AXIS-THEN-GRID (0, 1, −0.58).
    {
        rig("", Vec3(0.1f, 1, -0.4f));
        penMerge0();
        snapTypes("grid,worldAxis");
        clickPixels(worldPixel(Vec3(0.2f, 1, -0.6f)));
        penAttr("posZ", -0.58);
        clickPixels(worldPixel(Vec3(0.010846f, 1, -0.571068f)),
                    worldPixel(Vec3(0.3f, 1, -0.2f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 3 && at(vs[0], [0.2, 1, -0.58]) && at(vs[1], [0, 1, -0.6]),
            format("pen-grid-vs-guide: the guide anchor (0.2, 1, -0.58) then the "
                ~ "node (0, 1, -0.6) expected, got %s", vs));
        ++ran;
    }

    // 22 pen-grid-far-vs-guide (G8b3): 123 px/m (step 0.5); the guide line
    // z −1.25 through the first point (a node click typed to z −1.25); the
    // next click 1.8 px off the line, its node (0.5, −1) beyond 40 px, lands
    // on the node, not on the line (AXIS (0.26, 1, −1.25)).
    {
        enum double kPpm8 = 123.0;
        rig("", Vec3(0.3f, 1, -1.0f), kPpm8);
        penMerge0();
        snapTypes("grid,worldAxis");
        const step = viewStep();
        const Vec3 ptr = Vec3(0.262f, 1, -1.235f), node = Vec3(0.5f, 1, -1.0f);
        const dn = pxDist(ptr, node);
        assert(abs(step - 0.5) < 1e-6 && dn > 40,
            format("pen-grid-far-vs-guide rig: OUR step must be 0.5 (got %s) and "
                ~ "the node beyond 40 px (got %.2f)", step, dn));
        clickPixels(worldPixel(Vec3(0.5f, 1, -1.5f)));
        penAttr("posZ", -1.25);
        clickPixels(worldPixel(ptr), worldPixel(Vec3(1.0f, 1, -0.5f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 3 && at(vs[0], [0.5, 1, -1.25]) && at(vs[1], [0.5, 1, -1.0]),
            format("pen-grid-far-vs-guide: the guide anchor (0.5, 1, -1.25) then "
                ~ "the node (0.5, 1, -1) expected, got %s", vs));
        ++ran;
    }

    // 23 pen-grid-band-edge (ours): edge + grid; an edited-mesh edge x = E
    // 30 px right of the pointer (the 24..40 px highlight band), 34 px from
    // the (0.1, 0.2) node 4 px left of it. The grid places p0 on the node and
    // reports itself as the target, so the pen does not re-project p0 onto
    // the band edge (a band edge's target fields would select that path).
    {
        enum double kE = 0.1 + 34 * kPx;
        rig(format(`{"vertices":[[%.9f,1,-0.3],[%.9f,1,0.7],[0.6,1,0.2]],`
            ~ `"faces":[[0,1,2]]}`, kE, kE), Vec3(0.15f, 1, 0.2f));
        penMerge0();
        snapTypes("edge,grid");
        const Vec3 ptr = Vec3(cast(float)(0.1 + 4 * kPx), 1, 0.2f);
        const step = viewStep();
        const de = pxDist(ptr, Vec3(cast(float)kE, 1, 0.2f));
        assert(abs(step - 0.1) < 1e-6 && de > 24 && de < 40,
            format("pen-grid-band-edge rig: OUR step must be 0.1 (got %s) and the "
                ~ "edge in the 24..40 px band (got %.2f)", step, de));
        clickPixels(worldPixel(ptr), worldPixel(Vec3(-0.3f, 1, -0.2f)),
                    worldPixel(Vec3(-0.3f, 1, 0.5f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        check(vs.length == 6 && at(vs[3], [0.1, 1, 0.2]),
            format("pen-grid-band-edge: p0 expected the (0.1, 1, 0.2) node, not the "
                ~ "band edge x %.6f, got %s", kE, vs));
        ++ran;
    }
}

unittest {
    // --- facing-premise: the corner rule's sign for both rings (population 2)
    {
        int facing;
        foreach (front; [false, true]) {
            const Vec3 a = Vec3(0.3f, 1, 0.3f), b = front ? Vec3(0.6f, 1, 0.8f)
                                                           : Vec3(0.9f, 1, 0.3f);
            const Vec3 l = front ? Vec3(0.9f, 1, 0.3f) : Vec3(0.6f, 1, 0.8f);
            // N.y of cross(b - a, l - a); the eye is above (+Y).
            const double ny = (b.z - a.z) * (l.x - a.x) - (b.x - a.x) * (l.z - a.z);
            assert(front ? ny > 0 : ny < 0, format("rig: ring %s must be %s-facing "
                ~ "from the top, N.y = %s", front ? "[0,2,1]" : "[0,1,2]",
                front ? "front" : "back", ny));
            ++facing;
        }
        assert(facing == 2, "facing-premise population");
    }

    const Vec3 v0 = Vec3(0.3f, 1, 0.3f);
    const Vec3 focus = Vec3(0.45f, 1, 0.45f);

    // 2 vtx-front — control, above its must-redden twin.
    rig(tri(true), focus); snapTypes("vertex");
    expectAt(snapAt(leftOf(v0)), [0.3, 1, 0.3], kTol, "vtx-front"); ++ran;
    // 1 vtx-back (V1: snapped to the vertex, no facing term).
    rig(tri(false), focus); snapTypes("vertex");
    expectAt(snapAt(leftOf(v0)), [0.3, 1, 0.3], kTol, "vtx-back"); ++ran;

    // 4 edge-front — control. The pointer 6 px off the edge's midpoint, on the
    // side away from the triangle.
    const Vec3 offEdge = Vec3(0.6f, 1, cast(float)(0.3 - 6 * kPx));
    rig(tri(true), focus); snapTypes("edge");
    expectAt(snapAt(offEdge), [0.6, 1, 0.3], kHalfPx, "edge-front"); ++ran;
    // 3 edge-back — captured (edge leg, pen client, merge off).
    rig(tri(false), focus); snapTypes("edge");
    expectAt(snapAt(offEdge), [0.6, 1, 0.3], kHalfPx, "edge-back"); ++ran;

    // 7 poly-front — control; 6 poly-back stays culled (the polygon leg keeps
    // its facing term).
    const Vec3 centroid = Vec3(0.6f, 1, cast(float)(1.4 / 3));
    rig(tri(true), focus); snapTypes("polygon");
    {
        auto sr = snapAt(centroid);
        check(snapped(sr) && abs(pos(sr)[1] - 1) <= kTol,
            "poly-front: the front triangle takes a polygon snap, got " ~ sr.toString);
        ++ran;
    }
    rig(tri(false), focus); snapTypes("polygon");
    {
        auto sr = snapAt(centroid);
        check(!snapped(sr), "poly-back: a back-facing polygon takes no polygon "
            ~ "snap, got " ~ sr.toString);
        ++ran;
    }

    // 5 loose-vtx (V2: a loose vertex is a candidate).
    const Vec3 loose = Vec3(0, 1, 0.5f);
    const string withLoose = tri(true, `,[0,1,0.5]`);
    rig(withLoose, Vec3(0.3f, 1, 0.45f)); snapTypes("vertex");
    expectAt(snapAt(leftOf(loose)), [0, 1, 0.5], kTol, "loose-vtx"); ++ran;

    // 9 hidden-loose — the same L hidden: no snap. A loose point carries its
    // own Hide bit; the vertex-mode invert is the command that writes it.
    rig(withLoose, Vec3(0.3f, 1, 0.45f));
    penCommand("select.typeFrom vertex");
    penCommand(`{"id":"mesh.hideInvert"}`);
    assert(getJson("/api/model")["vertexHidden"].array[3].type == JSONType.true_,
        "hidden-loose rig: L must be hidden");
    snapTypes("vertex");
    {
        auto sr = snapAt(leftOf(loose));
        check(!snapped(sr), "hidden-loose: a hidden vertex is never a candidate, got "
            ~ sr.toString);
        ++ran;
    }

    // 8 occluded-vtx — a loose vertex 0.2 m under a FRONT-facing open quad
    // (ring [0,1,2,3] below: corner normal +Y) stays hidden: the depth gate.
    // 10 behind-back-quad — the same with the quad wound away: a back face
    // occludes nothing, so the vertex snaps.
    const Vec3 under = Vec3(0.5f, 0.8f, 0.5f);
    enum string quadVerts = `[0.1,1,0.1],[0.1,1,0.9],[0.9,1,0.9],[0.9,1,0.1],[0.5,0.8,0.5]`;
    rig(`{"vertices":[` ~ quadVerts ~ `],"faces":[[0,1,2,3]]}`, Vec3(0.5f, 1, 0.5f));
    snapTypes("vertex");
    {
        auto sr = snapAt(leftOf(under));
        check(!snapped(sr), "occluded-vtx: a vertex under a front face is "
            ~ "occluded, got " ~ sr.toString);
        ++ran;
    }
    rig(`{"vertices":[` ~ quadVerts ~ `],"faces":[[3,2,1,0]]}`, Vec3(0.5f, 1, 0.5f));
    snapTypes("vertex");
    expectAt(snapAt(leftOf(under)), [0.5, 0.8, 0.5], kTol, "behind-back-quad"); ++ran;

    gridCells();
    gridLawCells();

    // 14 Mpoly_ctrl replica (must stay green): back-facing T at y 1.3, polygon
    // snap only, the pen's first click inside T's interior lands on the click
    // plane y 1.0, not on T. Far clicks are ours (inside this rig's viewport).
    {
        rig(`{"vertices":[[0.3,1.3,0.3],[0.9,1.3,0.3],[0.6,1.3,0.8]],"faces":[[0,1,2]]}`,
            Vec3(0.45f, 1, 0.4f));
        penCommand("tool.set pen on");
        snapTypes("polygon");
        clickPixels(worldPixel(Vec3(0.6f, 1, 0.45f)), worldPixel(Vec3(0, 1, 0)),
                    worldPixel(Vec3(0, 1, 0.8f)));
        penCommand("tool.set pen off");
        auto vs = readVerts();
        assert(vs.length == 6, format("Mpoly_ctrl: 3 scene + 3 stroke vertices, got %d",
                                      vs.length));
        check(abs(vs[3].y - 1.0) <= kTol && abs(vs[3].x - 0.6) <= kHalfPx
            && abs(vs[3].z - 0.45) <= kHalfPx,
            format("Mpoly_ctrl: p0 must stay on the click plane at (0.6, 1, 0.45), "
                ~ "got %s", vs[3]));
        ++ran;
    }

    assert(ran == 27, format("population: %d cells ran, expected 27", ran));
    string[] names;   // the red cells by name first: the runner shows 8 lines
    foreach (f; fails) {
        const n = f[0 .. f.indexOf(':') < 0 ? f.length : f.indexOf(':')];
        if (!names.canFind(n)) names ~= n;
    }
    assert(fails.length == 0, format("%d of 27 cells red (%-(%s, %)):\n  %-(%s\n  %)",
                                     names.length, names, fails));
}
