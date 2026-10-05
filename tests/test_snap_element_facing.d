// SNAP: facing is a POLYGON term; the grid step is the view's grid (task 9387,
// wave plan §24.2 S5v; law `doc/measured_laws.md` §3).
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

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, playAndWait,
    projectToWindow, viewportFromCameraMatrices, vertexPos;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers : penCameraAt, penCommand, penSceneEmpty, readVerts,
    worldPixel, clickPixels;
import std.format : format;
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

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
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

private void snapTypes(string types) {
    penCommand("tool.pipe.attr snap enabled true");
    penCommand("tool.pipe.attr snap types " ~ types);
    penCommand("tool.pipe.attr snap fixedGrid false");
    penCommand("tool.pipe.attr snap innerRange 24");
    penCommand("tool.pipe.attr snap outerRange 40");
}

private JSONValue snapAt(int[2] px) {
    return postJson("/api/snap", format(
        `{"cursor":[0,0,0],"sx":%d,"sy":%d,"excludeVerts":[]}`, px[0], px[1]));
}

private bool snapped(JSONValue sr) { return sr["snapped"].type == JSONType.true_; }

private double[3] pos(JSONValue sr) {
    auto a = sr["worldPos"].array;
    double n(JSONValue v) {
        return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
    }
    return [n(a[0]), n(a[1]), n(a[2])];
}

private string tri(bool front, string extra = "", string extraFaces = "") {
    return `{"vertices":[[0.3,1,0.3],[0.9,1,0.3],[0.6,1,0.8]` ~ extra
        ~ `],"faces":[` ~ (front ? "[0,2,1]" : "[0,1,2]") ~ extraFaces ~ `]}`;
}

/// The pixel 6 px to the LEFT (−x) of world point `w` (top view: +x is right).
private int[2] leftOf(Vec3 w) {
    return worldPixel(Vec3(cast(float)(w.x - 6 * kPx), w.y, w.z));
}

private void expectAt(JSONValue sr, double[3] want, double tolXZ, string cell) {
    if (!snapped(sr)) { fails ~= cell ~ ": expected a snap, got " ~ sr.toString; return; }
    const g = pos(sr);
    check(abs(g[0] - want[0]) <= tolXZ && abs(g[2] - want[2]) <= tolXZ
        && abs(g[1] - want[1]) <= kTol,
        format("%s: snapped to (%.6f, %.6f, %.6f), expected (%.4f, %.4f, %.4f)",
               cell, g[0], g[1], g[2], want[0], want[1], want[2]));
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
    expectAt(snapAt(worldPixel(offEdge)), [0.6, 1, 0.3], kHalfPx, "edge-front"); ++ran;
    // 3 edge-back — captured (edge leg, pen client, merge off).
    rig(tri(false), focus); snapTypes("edge");
    expectAt(snapAt(worldPixel(offEdge)), [0.6, 1, 0.3], kHalfPx, "edge-back"); ++ran;

    // 7 poly-front — control; 6 poly-back stays culled (the polygon leg keeps
    // its facing term).
    const Vec3 centroid = Vec3(0.6f, 1, cast(float)(1.4 / 3));
    rig(tri(true), focus); snapTypes("polygon");
    {
        auto sr = snapAt(worldPixel(centroid));
        check(snapped(sr) && abs(pos(sr)[1] - 1) <= kTol,
            "poly-front: the front triangle takes a polygon snap, got " ~ sr.toString);
        ++ran;
    }
    rig(tri(false), focus); snapTypes("polygon");
    {
        auto sr = snapAt(worldPixel(centroid));
        check(!snapped(sr), "poly-back: a back-facing polygon takes no polygon "
            ~ "snap, got " ~ sr.toString);
        ++ran;
    }

    // 5 loose-vtx (V2: a loose vertex is a candidate).
    const Vec3 loose = Vec3(0, 1, 0.5f);
    const string withLoose = tri(true, `,[0,1,0.5]`);
    rig(withLoose, Vec3(0.3f, 1, 0.45f)); snapTypes("vertex");
    expectAt(snapAt(leftOf(loose)), [0, 1, 0.5], kTol, "loose-vtx"); ++ran;

    // 9 hidden-loose — the same L hidden: no snap.
    rig(withLoose, Vec3(0.3f, 1, 0.45f));
    penCommand("select.typeFrom vertex");
    {
        auto r = postJson("/api/command", commandBody("mesh.select",
            `{"mode":"vertices","indices":[3]}`));
        assert(r["status"].str == "ok", "select L failed: " ~ r.toString);
    }
    penCommand(`{"id":"mesh.hide"}`);
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

    // 11 grid-view-step — K-C2's geometry: pointer 15.5 px from (0.1, 0.2) at
    // 440 px/m ⇒ the 0.1 node. The node lies on the work plane (y 0 here);
    // the in-plane channels are the law.
    rig("", Vec3(0.1f, 1, 0.2f)); snapTypes("grid");
    {
        const g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
        assert(abs(num(g["size"]) - 0.1) < 1e-6,
            format("grid-view-step rig: OUR drawn step at 440 px/m must be 0.1, got %s",
                   g["size"].toString));
        auto sr = snapAt(worldPixel(Vec3(cast(float)(0.1 + 15.5 * kPx), 1, 0.2f)));
        check(snapped(sr) && abs(pos(sr)[0] - 0.1) <= kTol && abs(pos(sr)[2] - 0.2) <= kTol,
            "grid-view-step: the pointer lands on the visible grid's (0.1, 0.2) "
            ~ "node, got " ~ sr.toString);
        ++ran;
    }

    // 12 grid-second-rung (G2): at 110 px/m the drawn grid is 0.5 (the
    // captured label), and the captured pointer lands on its (0, 0.5) node —
    // a constant 0.1 step would give (0, 0.3).
    {
        enum double kG2Ppm = 110.0, kG2Step = 0.5;
        rig("", Vec3(0.2f, 1, 0.3f), kG2Ppm); snapTypes("grid");
        const g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
        assert(abs(num(g["size"]) - kG2Step) < 1e-6,
            format("grid-second-rung rig: OUR step at %s px/m must equal the "
                ~ "captured %s, got %s", kG2Ppm, kG2Step, g["size"].toString));
        auto sr = snapAt(worldPixel(Vec3(0.006364f, 1, 0.272727f)));
        const double wx = 0, wz = 0.5;
        check(snapped(sr) && abs(pos(sr)[0] - wx) <= kTol && abs(pos(sr)[2] - wz) <= kTol,
            format("grid-second-rung: expected the (%s, %s) node of the %s step, got %s",
                   wx, wz, kG2Step, sr.toString));
        ++ran;
    }

    // 13 move-grid-step (G3): the Move tool, vertex mode, grid bit only; press
    // on q's pixel, drag to the pixel of (0.1252, 1, 0.1952) — the moved
    // vertex's ABSOLUTE position lands on the 0.1 node (a delta snap would
    // give (0.13, 1, 0.17)).
    {
        rig(`{"vertices":[[0.03,1,0.07],[0.53,1,0.07],[0.53,1,0.57],[0.03,1,0.57]],`
            ~ `"faces":[[0,3,2,1]]}`, Vec3(0.28f, 1, 0.32f));
        penCommand("select.typeFrom vertex");
        auto r = postJson("/api/command", commandBody("mesh.select",
            `{"mode":"vertices","indices":[0]}`));
        assert(r["status"].str == "ok", "select q failed: " ~ r.toString);
        penCommand("tool.set move");
        snapTypes("grid");
        auto cam = fetchCamera();
        const a = worldPixel(Vec3(0.03f, 1, 0.07f));
        const b = worldPixel(Vec3(0.1252f, 1, 0.1952f));
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 a[0], a[1], b[0], b[1]));
        const q = vertexPos(0);
        penCommand("tool.set move off");
        check(abs(q[0] - 0.1) <= kTol && abs(q[1] - 1) <= kTol && abs(q[2] - 0.2) <= kTol,
            format("move-grid-step: q expected on the (0.1, 1, 0.2) node, got "
                ~ "(%.6f, %.6f, %.6f)", q[0], q[1], q[2]));
        ++ran;
    }

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

    assert(ran == 14, format("population: %d cells ran, expected 14", ran));
    assert(fails.length == 0, format("%d of 14 cells red:\n  %-(%s\n  %)",
                                     fails.length, fails));
}
