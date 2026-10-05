// Edge Extend's off-handle haul plane (task 9450; capture K-D cell D2, the
// verdict WORK-PLANE/FOCUS linearised at the PRESS hit, residual 0.0006 under
// a 0.001 quantum): the haul runs on the auto work plane — the most-facing
// axis plane through the focus — and its pixel map is linearised at the
// press point on that plane, not at the handle.
//
// Our camera is not the capture's, so the cells pin the LAW, not its numbers:
// the offset a pure screen-up haul writes is the plane map's Jacobian at the
// press hit P applied to the pixel travel (LIN@P), computed here from the
// cell's own matrices. The candidate it replaces — the same plane through the
// handle, linearised at the handle (LIN@G, ours before 9450) — is computed
// too, and each cell first pins that the two stand apart by more than the
// tolerance (a cell that cannot tell them apart is void).
//
// Three press routes, one per term of the haul predicate:
//   (a) the first press, Move bank on: the bank's own off-handle press;
//   (b) a later press off the drawn handle: the same route, an open operation;
//   (c) the first press, Move bank off: no bank asked — the total miss.
// (d) keeps the snap's reference: with press and first motion in one frame,
// a vertex snap still lands the HANDLE on the target (as before 9450).

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import drag_helpers : viewportFromCameraMatrices, pixelRay, projectToWindow,
    DV = Vec3, DViewport = Viewport;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

enum double kTol = 0.0055;  // one view quantum (0.005 at this zoom: the haul rounds its travel) + slack
enum double kApart = 0.02;  // LIN@P and LIN@G must differ by more than this

/// The quad of the capture rig: -0.3..0.3 in x and z at height 0.4; edge
/// (0, 1) is the operand.
void quadRig(bool moveBank) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmdId("scene.loadMesh", `{"vertices":[[-0.3,0.4,-0.3],[0.3,0.4,-0.3],[0.3,0.4,0.3],[-0.3,0.4,0.3]],"faces":[[0,3,2,1]]}`);
    assert(vertexCount() == 4 && faceCount() == 1, "quad rig did not load");
    setSymmetryX(false);
    selectEdges(edgesOf([[0, 1]]));
    r = postJson("/api/camera", `{"azimuth":0.6,"elevation":1.0,"distance":2.4,"focus":{"x":0,"y":0,"z":0},"roll":0}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str != "Ortho", "rig premise: the view must be perspective");
    cmd("tool.set edge.extend on");
    if (!moveBank) cmd("tool.attr edge.extend moveHandle false");
    cmd("history.clear");
    settle(250);
    assert(undoLen() == 0, "history.clear left entries");
}

DV hitY(const ref DViewport vp, double sx, double sy, double y) {
    DV o, d;
    pixelRay(cast(float) sx, cast(float) sy, vp, o, d);
    assert(abs(d.y) > 1e-3, "rig: the ray runs along the plane");
    immutable float t = cast(float)((y - o.y) / d.y);
    return o + d * t;
}

/// The plane map y = anchor.y linearised at `anchor`'s own pixel, applied to
/// the pixel travel (dx, dy).
double[3] lin(const ref DViewport vp, DV anchor, int dx, int dy) {
    float mx, my;
    assert(projectToWindow(anchor, vp, mx, my), "rig: anchor behind the camera");
    immutable DV hx = hitY(vp, mx + 0.5, my, anchor.y) - hitY(vp, mx - 0.5, my, anchor.y);
    immutable DV hy = hitY(vp, mx, my + 0.5, anchor.y) - hitY(vp, mx, my - 0.5, anchor.y);
    immutable DV v = hx * cast(float) dx + hy * cast(float) dy;
    return [v.x, v.y, v.z];
}

double apart(double[3] a, double[3] b) {
    double m = 0;
    foreach (k; 0 .. 3) if (abs(a[k] - b[k]) > m) m = abs(a[k] - b[k]);
    return m;
}

/// One screen-up haul of 3 x 20 px from `p`; returns the offset it ADDED and
/// the two predictions (LIN@P, LIN@G) for it.
void haulAt(Px p, string what, Offset base) {
    auto vp = viewportFromCameraMatrices();
    immutable DV back = DV(vp.view[2], vp.view[6], vp.view[10]);
    assert(abs(back.y) > 1.3 * abs(back.x) && abs(back.y) > 1.3 * abs(back.z),
        what ~ ": rig premise, Y must be the most-facing axis: " ~ format("%s", back));
    press(p);
    auto s = toolState();
    assert(s["dragBank"].str == "move" && grabbedAxis() == 3,
        what ~ ": the press did not begin the haul: " ~ s.toString);
    // The handle: the operand edge's mid plus the offset so far (Q-pose).
    immutable double[3] g = [base.x, 0.4 + base.y, -0.3 + base.z];
    immutable DV P = hitY(vp, p.x, p.y, 0.0);   // the auto work plane: y = focus.y
    immutable double[3] linP = lin(vp, P, 0, -60);
    immutable double[3] linG = lin(vp, DV(g[0], g[1], g[2]), 0, -60);
    assert(apart(linP, linG) > kApart, format("%s: rig cannot discriminate, LIN@P %s vs LIN@G %s",
        what, linP, linG));
    Px end;
    increments(p, 0, -20, 3, end);
    release(end);
    immutable Offset o = offset();
    immutable double[3] got = [o.x - base.x, o.y - base.y, o.z - base.z];
    assert(apart(got, linP) <= kTol, format("%s: the haul is not linearised at the press point on the "
        ~ "work plane: offset %s, LIN@P %s, LIN@G (the handle) %s", what, got, linP, linG));
}

unittest { // (a) first press, Move bank on
    quadRig(true);
    auto c = viewCentre();
    haulAt(Px(c.x - 260, c.y + 230), "(a) first press", Offset(0, 0, 0));
    assert(undoLen() == 0, format("(a) a haul is a live session step, no history row: %d", undoLen()));
}

unittest { // (b) a later press, off the drawn handle
    quadRig(true);
    auto c = viewCentre();
    haulAt(Px(c.x - 260, c.y + 230), "(b) opening haul", Offset(0, 0, 0));
    immutable Offset base = offset();
    float gx, gy;
    auto vp = viewportFromCameraMatrices();
    immutable double[3] g = gizmoCentre();
    assert(abs(g[0] - base.x) + abs(g[1] - 0.4 - base.y) + abs(g[2] + 0.3 - base.z) < 1e-4,
        format("(b) rig: the handle %s is not the edge mid plus the offset %s", g, base));
    assert(projectToWindow(DV(g[0], g[1], g[2]), vp, gx, gy), "(b) handle behind the camera");
    immutable Px p = Px(c.x + 280, c.y + 200);
    assert(abs(p.x - gx) + abs(p.y - gy) > 200, "(b) rig: the press is near the handle");
    haulAt(p, "(b) second press", base);
    assert(undoLen() == 0, format("(b) a haul is a live session step, no history row: %d", undoLen()));
}

unittest { // (c) first press, Move bank off: the total miss
    quadRig(false);
    auto c = viewCentre();
    haulAt(Px(c.x - 260, c.y + 230), "(c) total miss", Offset(0, 0, 0));
    assert(undoLen() == 0, format("(c) a haul is a live session step, no history row: %d", undoLen()));
}

unittest { // (d) a vertex snap on the haul's first motion, in the press's own frame
    // The snap moves the HANDLE onto the target: its delta is measured from
    // where the handle is drawn, so the press must leave the Move bank posed
    // there even before the frame re-poses it (the haul's grab sits at the
    // press point). Press and first motion share one frame.
    quadRig(true);
    cmd("tool.pipe.attr snap types vertex");
    cmd("tool.pipe.attr snap enabled true");
    auto vp = viewportFromCameraMatrices();
    float tx, ty;
    assert(projectToWindow(DV(0.3f, 0.4f, 0.3f), vp, tx, ty), "(d) rig: the target vertex is off camera");
    auto c = viewCentre();
    immutable Px p = Px(c.x - 260, c.y + 230), q = Px(cast(int) tx, cast(int) ty);
    play(format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
              ~ `{"t":200.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
              ~ `{"t":200.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                p.x, p.y, p.x, p.y, q.x, q.y, q.x - p.x, q.y - p.y));
    immutable Offset o = offset();
    release(q);
    cmd("tool.pipe.attr snap enabled false");
    assert(apart([o.x, o.y, o.z], [0.3, 0.0, 0.6]) <= 1e-4,
        format("(d) the snapped haul did not land the handle (0, 0.4, -0.3) on the vertex (0.3, 0.4, 0.3): "
            ~ "offset %s", o));
}
