// Edge Extend under a PINNED work plane with work-plane symmetry, a scripted
// apply under symmetry, and a second press on a rotate ring (task 9520;
// capture K-EX, fits to 1e-5).
//
// (1) Two planes per press. A selected vertex is sorted by the symmetry plane
//     mapped by the work plane TWICE (through W(W(0)), normal R²·eₓ — task
//     9452); the PRESS is sorted by the WORLD axis plane, ignoring the pin. A
//     vertex on the press's side takes the offset unchanged (U), one on the
//     other side takes it reflected about R²·eₓ (R). Our pixels are not the
//     capture's, so each cell presses at the captured WORLD point and pins
//     the captured U/R word against our own offset. EX_PP0a / EX_PP50c are
//     the cells where the work-plane press plane and the world one disagree;
//     EX_P0v puts vertex B (x 0.45) between W(0) (x 0.3) and W(W(0)) (x 0.6).
// (2) A scripted apply mirrors with the press side −X (no press); an
//     unselected partner is not extended (EX_S, EX_S1; control EX_Sc).
// (3) With Move and Rotate on, a second press on the X ring ROTATES (EX_R);
//     the controls press the same pixel with one bank (EX_Rr, EX_Rm).

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import drag_helpers : viewportFromCameraMatrices, projectToWindow, gizmoSize,
    cross, normalize, DV = Vec3;
import std.format : format;
import std.json;
import std.math : abs, cos, sin, PI;

void main() {}

alias V3 = double[3];
V3 add(V3 a, V3 b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
double dot(V3 a, V3 b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
V3 reflect(V3 d, V3 n) { immutable k = 2 * dot(d, n); return [d[0] - k * n[0], d[1] - k * n[1], d[2] - k * n[2]]; }
double apart(V3 a, V3 b) {
    double m = 0;
    foreach (k; 0 .. 3) if (abs(a[k] - b[k]) > m) m = abs(a[k] - b[k]);
    return m;
}

// The rot-0 rig: four quads A (x 0.8..0.9), B (0.35..0.45), D (0.05..0.15),
// C (-0.3..-0.2); the outer edge of each selected.
enum string kVerts0 = "[[0.8,0,0.3],[0.8,0,0.4],[0.9,0,0.4],[0.9,0,0.3],[0.35,0,-0.05],[0.35,0,0.05],"
    ~ "[0.45,0,0.05],[0.45,0,-0.05],[0.05,0,-0.4],[0.05,0,-0.3],[0.15,0,-0.3],[0.15,0,-0.4],"
    ~ "[-0.3,0,0.55],[-0.3,0,0.65],[-0.2,0,0.65],[-0.2,0,0.55]]";
enum string kFaces0 = "[[0,1,2,3],[4,5,6,7],[8,9,10,11],[12,13,14,15]]";
enum int[2][] kSel0 = [[2, 3], [6, 7], [10, 11], [14, 15]];

// The rot-50 rig: seven quads, the outer edge of each selected.
enum string kVerts50 = "[[0.349372,0,-0.373023],[0.425977,0,-0.308744],[0.490255,0,-0.385348],"
    ~ "[0.413651,0,-0.449627],[0.770697,0,-0.019489],[0.847301,0,0.044789],[0.91158,0,-0.031815],"
    ~ "[0.834975,0,-0.096094],[-0.180696,0,-0.752532],[-0.104092,0,-0.688254],[-0.039813,0,-0.764858],"
    ~ "[-0.116417,0,-0.829137],[1.118067,0,-0.511255],[1.194671,0,-0.446977],[1.25895,0,-0.523581],"
    ~ "[1.182346,0,-0.58786],[0.48628,0,0.786182],[0.562884,0,0.850461],[0.627163,0,0.773857],"
    ~ "[0.550559,0,0.709578],[0.518882,0,-1.275113],[0.595487,0,-1.210834],[0.659765,0,-1.287438],"
    ~ "[0.583161,0,-1.351717],[-0.50474,0,0.41151],[-0.428136,0,0.475789],[-0.363857,0,0.399185],"
    ~ "[-0.440462,0,0.334906]]";
enum string kFaces50 = "[[0,1,2,3],[4,5,6,7],[8,9,10,11],[12,13,14,15],[16,17,18,19],[20,21,22,23],[24,25,26,27]]";
enum int[2][] kSel50 = [[2, 3], [6, 7], [10, 11], [14, 15], [18, 19], [22, 23], [26, 27]];

/// One pinned-plane haul: load the rig, pin W (centre `cen`, rotY `rotY`),
/// symmetry X through the work plane, top view, press at the WORLD point
/// (px, 0, pz), haul two (10, 5) px steps. Returns the U/R word over the
/// selected source vertices in edge order (two letters per edge).
string pinnedHaul(string cell, string verts, string faces, int[2][] sel, V3 cen, double rotY,
                  double px, double pz, bool pinned = true) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmdId("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`);
    immutable size_t nv = vertexCount();
    assert(nv == sel.length * 4, format("%s: rig did not load (%d v)", cell, nv));
    setSymmetryX(false);
    selectEdges(edgesOf(sel));
    if (pinned)
        cmd(format("workplane.edit cenX:%s cenY:%s cenZ:%s rotX:0 rotY:%s rotZ:0", cen[0], cen[1], cen[2], rotY));
    cmd("tool.pipe.attr symmetry useWorkplane " ~ (pinned ? "true" : "false"));
    setSymmetryX(true);
    cmd("viewport.view Top");
    r = postJson("/api/camera", format(`{"focus":{"x":%s,"y":0,"z":%s},"distance":4.0}`, cen[0], cen[2]));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set edge.extend on");
    cmd("history.clear");
    settle(250);

    auto vp = viewportFromCameraMatrices();
    float sx, sy;
    assert(projectToWindow(DV(cast(float) px, 0.0f, cast(float) pz), vp, sx, sy), cell ~ ": press point off camera");
    immutable Px p = Px(cast(int) sx, cast(int) sy);
    press(p);
    assert(moveOffGizmo() && toolState()["dragBank"].str == "move",
        cell ~ ": the press did not begin an off-handle haul: " ~ toolState().toString);
    Px end;
    increments(p, 10, 5, 2, end);
    release(end);
    immutable Offset o = offset();
    // Read the COMMITTED mesh: idle frames, then the drop commits the run
    // from the tool's mirror as it stands then, not the preview's.
    settle(250);
    cmd("tool.set edge.extend off");

    auto m = model();
    assert(m["vertices"].array.length == nv + sel.length * 2,
        format("%s: expected %d vertices, got %d", cell, nv + sel.length * 2, m["vertices"].array.length));
    immutable V3 off = [o.x, o.y, o.z];
    immutable double a = rotY * PI / 180.0;
    immutable V3 refl = reflect(off, [cos(2 * a), 0, -sin(2 * a)]);
    assert(apart(off, refl) > 0.01, format("%s: rig cannot discriminate U from R: offset %s", cell, off));
    string word;
    foreach (e; sel) foreach (s; e) {
        immutable V3 src = vtx(m, s);
        int u, rr;
        foreach (i; nv .. m["vertices"].array.length) {
            if (apart(vtx(m, i), add(src, off)) <= 1e-4) ++u;
            if (apart(vtx(m, i), add(src, refl)) <= 1e-4) ++rr;
        }
        assert(u + rr == 1, format("%s: source %d has %d unchanged and %d reflected ring vertices", cell, s, u, rr));
        word ~= u ? 'U' : 'R';
    }
    return word;
}

void pinCell(string cell, string got, string want) {
    assert(got == want, format("%s: U/R word %s, captured %s", cell, got, want));
}

// --- (1) rot 0, W centre (0.3, 0, 0) --------------------------------------

unittest { // EX_Pc (control): no pin, symmetry X — both planes are world x = 0
    pinCell("EX_Pc", pinnedHaul("EX_Pc", kVerts0, kFaces0, kSel0, [0, 0, 0], 0, 1.10065, 0.0, false),
            "UUUUUURR");
}

unittest { // EX_P0v: the vertex plane is W(W(0)) (x 0.6): B at 0.45 is reflected
    pinCell("EX_P0v", pinnedHaul("EX_P0v", kVerts0, kFaces0, kSel0, [0.3, 0, 0], 0, 1.10033, 0.0),
            "UURRRRRR");
}

unittest { // EX_PP0b (control: both press planes say −): the press at world x −0.15
    pinCell("EX_PP0b", pinnedHaul("EX_PP0b", kVerts0, kFaces0, kSel0, [0.3, 0, 0], 0, -0.15101, -0.75081),
            "RRUUUUUU");
}

unittest { // EX_PP0a: the press at world x +0.15, left of W(0) (x 0.3) — world x decides
    pinCell("EX_PP0a", pinnedHaul("EX_PP0a", kVerts0, kFaces0, kSel0, [0.3, 0, 0], 0, 0.14931, -0.75081),
            "UURRRRRR");
}

// --- (1) rot 50, W centre (0.4, 0, −0.2) ----------------------------------

unittest { // EX_P50: seven ridges, the vertex plane through O + R·O, normal R²·eₓ
    pinCell("EX_P50", pinnedHaul("EX_P50", kVerts50, kFaces50, kSel50, [0.4, 0, -0.2], 50, 1.18417, -0.9788),
            "RRRRUURRRRUURR");
}

unittest { // EX_PP50
    pinCell("EX_PP50", pinnedHaul("EX_PP50", kVerts50, kFaces50, kSel50, [0.4, 0, -0.2], 50, 1.16785, 0.05296),
            "RRRRUURRRRUURR");
}

unittest { // EX_PP50b: the press on world −X
    pinCell("EX_PP50b", pinnedHaul("EX_PP50b", kVerts50, kFaces50, kSel50, [0.4, 0, -0.2], 50, -0.27201, -0.56717),
            "UUUURRUUUURRUU");
}

unittest { // EX_PP50c: world x + while the press is behind R·eₓ through W(0)
    pinCell("EX_PP50c", pinnedHaul("EX_PP50c", kVerts50, kFaces50, kSel50, [0.4, 0, -0.2], 50, 0.43549, 1.00363),
            "RRRRUURRRRUURR");
}

// --- (2) the scripted apply under symmetry --------------------------------

enum string kVertsS = "[[0.1,0,-0.2],[0.1,0,0.2],[0.5,0,0.2],[0.5,0,-0.2],"
    ~ "[-0.1,0,-0.2],[-0.1,0,0.2],[-0.5,0,0.2],[-0.5,0,-0.2]]";

/// Reset, the two-quad rig, symmetry X (world) on or off, `sel` selected, a
/// scripted apply of offset (0.1, 0.05, 0.03). Returns the new vertices.
V3[] scriptedApply(string cell, bool symmetry, int[2][] sel) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmdId("scene.loadMesh", `{"vertices":` ~ kVertsS ~ `,"faces":[[0,1,2,3],[4,7,6,5]]}`);
    assert(vertexCount() == 8 && faceCount() == 2, cell ~ ": rig did not load as 8 v / 2 f");
    setSymmetryX(false);
    cmd("tool.pipe.attr symmetry useWorkplane false");
    selectEdges(edgesOf(sel));
    setSymmetryX(symmetry);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend offsetX 0.1");
    cmd("tool.attr edge.extend offsetY 0.05");
    cmd("tool.attr edge.extend offsetZ 0.03");
    cmd("tool.doApply");
    cmd("tool.set edge.extend off");
    auto m = model();
    V3[] got;
    foreach (i; 8 .. m["vertices"].array.length) got ~= vtx(m, i);
    return got;
}

void assertSet(string cell, V3[] got, V3[] want) {
    assert(got.length == want.length, format("%s: %d new vertices %s, captured %d %s",
        cell, got.length, got, want.length, want));
    foreach (w; want) {
        int n;
        foreach (g; got) if (apart(g, w) <= 1e-5) ++n;
        assert(n == 1, format("%s: captured vertex %s is matched %d times in %s", cell, w, n, got));
    }
}

unittest { // EX_Sc (control): symmetry off — every selected edge takes the offset
    assertSet("EX_Sc", scriptedApply("EX_Sc", false, [[2, 3], [6, 7]]),
        [[0.6, 0.05, 0.23], [0.6, 0.05, -0.17], [-0.4, 0.05, -0.17], [-0.4, 0.05, 0.23]]);
}

unittest { // EX_S: symmetry X, both edges — the −X side unchanged, the +X side reflected
    assertSet("EX_S", scriptedApply("EX_S", true, [[2, 3], [6, 7]]),
        [[0.4, 0.05, 0.23], [0.4, 0.05, -0.17], [-0.4, 0.05, -0.17], [-0.4, 0.05, 0.23]]);
}

unittest { // EX_S1: only the +X edge — reflected, and the partner is not extended
    assertSet("EX_S1", scriptedApply("EX_S1", true, [[2, 3]]),
        [[0.4, 0.05, 0.23], [0.4, 0.05, -0.17]]);
}

// --- (3) the second press on the rotate X ring ----------------------------

/// The plane rig's +X ridge edge (7, 8), a perspective camera looking along
/// −back with back (0.45, 0.55, 0.70), the banks as given. The first press
/// hauls (20, 10) px off the handle; the second press lands on the X ring
/// where it meets the view plane and drags 8 × (0, −5) px. Returns the
/// bank the second press took, the offset before and after it and rotate X.
struct RingRun { string bank; bool offGizmo; Offset before, after; double rotX; }

RingRun ringRun(string cell, bool moveOn, bool rotateOn) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    selectEdges(edgesOf([[7, 8]]));
    // back (0.45, 0.55, 0.70): azimuth atan2(x, z), elevation asin(y / |back|).
    r = postJson("/api/camera", `{"azimuth":0.571,"elevation":0.584,"distance":5.0,"focus":{"x":0.5,"y":0.3,"z":0},"roll":0}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str != "Ortho", cell ~ ": the view must be perspective");
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend moveHandle " ~ (moveOn ? "true" : "false"));
    cmd("tool.attr edge.extend rotateHandle " ~ (rotateOn ? "true" : "false"));
    cmd("history.clear");
    settle(250);
    auto c = viewCentre();
    immutable Px h0 = Px(c.x - 300, c.y + 250);
    press(h0);
    Px e0;
    increments(h0, 20, 10, 1, e0);
    release(e0);
    RingRun run;
    run.before = offset();
    assert(abs(run.before.x) + abs(run.before.y) + abs(run.before.z) > 1e-3,
        cell ~ ": the first haul moved nothing: " ~ toolState().toString);

    // The X ring's point where it meets the view plane, about the handle
    // (the edge mid (1, 0.5, 0) plus the offset).
    auto vp = viewportFromCameraMatrices();
    immutable DV hc = DV(cast(float)(1.0 + run.before.x), cast(float)(0.5 + run.before.y), cast(float) run.before.z);
    immutable DV f = DV(-vp.view[2], -vp.view[6], -vp.view[10]);
    immutable DV back = normalize(DV(0.45f, 0.55f, 0.70f));
    assert(abs(f.x + back.x) + abs(f.y + back.y) + abs(f.z + back.z) < 0.02,
        format("%s: the camera does not look along -back: forward %s", cell, f));
    immutable DV end = hc + normalize(cross(DV(1, 0, 0), f)) * gizmoSize(hc, vp);
    float x, y;
    assert(projectToWindow(end, vp, x, y), cell ~ ": the ring point is behind the camera");
    immutable Px p = Px(cast(int) x, cast(int) y);
    press(p);
    auto s = toolState();
    run.bank = s["dragBank"].str;
    run.offGizmo = moveOffGizmo();
    Px e1;
    increments(p, 0, -5, 8, e1);
    release(e1);
    run.after = offset();
    run.rotX = num(toolState()["rotateX"]);
    cmd("tool.set edge.extend off");
    return run;
}

unittest { // EX_Rr (control): Rotate alone — the ring press rotates, the offset stays
    auto run = ringRun("EX_Rr", false, true);
    assert(run.bank == "rotate" && abs(run.rotX) > 0.1 && run.after == run.before,
        format("EX_Rr: bank %s, rotate X %s, offset %s -> %s", run.bank, run.rotX, run.before, run.after));
}

unittest { // EX_Rm (control): Move alone — the same pixel hauls, no rotation
    auto run = ringRun("EX_Rm", true, false);
    assert(run.bank == "move" && run.offGizmo && run.rotX == 0 && !(run.after == run.before),
        format("EX_Rm: bank %s (off-handle %s), rotate X %s, offset %s -> %s", run.bank, run.offGizmo, run.rotX, run.before, run.after));
}

unittest { // EX_R: Move and Rotate on — the ring press ROTATES; Move's haul does not take it
    auto run = ringRun("EX_R", true, true);
    assert(run.bank == "rotate" && abs(run.rotX) > 0.1 && run.after == run.before,
        format("EX_R: bank %s, rotate X %s, offset %s -> %s", run.bank, run.rotX, run.before, run.after));
}

unittest { // a MISS is offered to every enabled bank: with Scale alone, an off-handle second press
           // arms the bank's plane scale (part 7) — ours, kept as it was (no capture of this press)
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    selectEdges(edgesOf([[7, 8]]));
    r = postJson("/api/camera", `{"azimuth":0.571,"elevation":0.584,"distance":5.0,"focus":{"x":0.5,"y":0.3,"z":0},"roll":0}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend moveHandle false");
    cmd("tool.attr edge.extend scaleHandle true");
    cmd("history.clear");
    settle(250);
    auto c = viewCentre();
    click(Px(c.x - 300, c.y + 250));   // opens the operation
    assert(runStarted(), "scale-miss: the opening click did not open an operation");
    immutable Px p = Px(c.x - 300, c.y - 250);
    press(p);
    auto s = toolState();
    assert(s["dragBank"].str == "scale" && s["dragAxis"].integer == 7,
        "scale-miss: an off-handle press with Scale alone did not reach the scale bank's plane scale: " ~ s.toString);
    release(p);
    cmd("tool.set edge.extend off");
}
