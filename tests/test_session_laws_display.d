// Slice M6 of the tool session model (doc/tool_session_model_plan_2026-09-24.md
// R2.5 M6, R4.8, R4.11): the target highlight (H7) and the handle pose (H8) as
// policy data read by one viewport path.
//
// H7 — PIXELS, because a draw-call census cannot see a highlight: the absolute
// difference of two frames (pointer off the mesh / pointer on the target),
// counted over a square box around the target — not a colour classifier (the
// trap of task 6207). Captured (toolcards/tool_session_model/, gap 309/312):
//   C-H7       Slice, Edge Extend, Polygon Bevel armed: 0; Edge Slice > 0;
//              no tool > 0 (edge mode 286 px, polygon mode 2606 px).
//   C-H7-vert  vertex mode: Move and vertex Bevel 0; no tool > 0 (36 px).
//   C-H7-elem  Element Move highlights only the hovered VERTEX, in every
//              selection mode: vertex mode on v 36 = no tool; edge mode on the
//              edge 0; polygon mode on the edge 0; edge mode on v the vertex
//              dot (36) where no tool draws edges (475; ours lights one edge).
//   Magnet     flags table: no rollover flag (a named flip of M6 — HEAD drew
//              its hovered vertex).
//   Tack       no counterpart: its hovered face stays drawn (carried).
// Every zero cell sits beside its no-tool control in the SAME rig (the "> 0"
// is the floor that makes the zero mean something), and every cell first
// proves the pointer is on the element it names (`/api/toolpipe/eval` hover).
//
// H8 — C-H8-ctl: after Ctrl+Z pops the second haul of one Edge Extend
// operation the handle stands on the OPERATION's base plus the restored
// offset, (1.121, 0.376) captured, not on the current selection (1.25, 0.25).
//
// Rig: the default cube, perspective camera, real pointer motion through
// /api/play-events; H8 on the file-6 Edge Extend rig of
// tests/test_session_laws_extend.d.

import http_client : getJson, postJson, testBaseUrl, quiesce;
import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow, playAndWait,
                      DHVec3 = Vec3;
static import edge_extend_gesture_helpers;
import std.format : format;
import std.json;
import std.math : abs, round, sqrt;
import std.stdio : writefln;

void main() {}

// ---------------------------------------------------------------------------
// H7 rig
// ---------------------------------------------------------------------------

private void run(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "command `" ~ line ~ "` failed: " ~ r.toString);
}

private void settleFrames() { quiesce(); }

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int) c["vpX"].integer, cast(int) c["vpY"].integer,
                cast(int) c["width"].integer, cast(int) c["height"].integer);
}

/// World point -> WINDOW pixel through the live camera.
private int[2] windowPx(DHVec3 w) {
    auto cam = fetchCamera(testBaseUrl);
    auto vp = viewportFromCamera(cam);
    float x, y;
    assert(projectToWindow(w, vp, x, y), format("rig: (%s) is behind the camera", w));
    return [cast(int) round(x), cast(int) round(y)];
}

/// Real pointer motion (no button) to a window pixel, then the frames settle.
private void pointerAt(int[2] p) {
    auto c = cell();
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
                        ~ `"fovY":0.785398}` ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
                      ~ `"state":0,"mod":0}` ~ "\n", 50.0 + i * 20.0, p[0], p[1]);
    playAndWait(log, testBaseUrl);
    settleFrames();
}

/// A pixel of the cell far from the cube: the "pointer off" frame.
private int[2] offMesh() {
    auto c = cell();
    return [c.vx + 12, c.vy + c.vh - 12];
}

private enum int kHalf = 15;   // the box is 31 x 31 cell pixels

/// The box around a window pixel, read back from the cell's FBO.
private int[3][] box(int[2] w) {
    auto c = cell();
    immutable int cx = w[0] - c.vx, cy = w[1] - c.vy;
    int[2][] pts;
    foreach (dy; -kHalf .. kHalf + 1)
        foreach (dx; -kHalf .. kHalf + 1)
            pts ~= [cx + dx, cy + dy];
    int[3][] outp;
    for (size_t i = 0; i < pts.length; i += 50) {
        auto slice = pts[i .. (i + 50 > pts.length ? pts.length : i + 50)];
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        assert(j["renders"].type == JSONType.true_,
               "the probed cell is not rendered; every count below would be void");
        foreach (e; j["points"].array) {
            assert("error" !in e, "probe point outside the cell: " ~ e.toString);
            outp ~= [cast(int) e["r"].integer, cast(int) e["g"].integer,
                     cast(int) e["b"].integer];
        }
    }
    assert(outp.length == (2 * kHalf + 1) ^^ 2, "probe box population");
    return outp;
}

/// Changed pixels in the box around `target` between the pointer off the
/// mesh and the pointer on `target` — the absolute frame difference.
private size_t changedPx(int[2] target) {
    pointerAt(offMesh());
    auto a = box(target);
    pointerAt(target);
    auto b = box(target);
    size_t n;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i]) ++n;
    return n;
}

/// The hovered element the frame resolved (`/api/toolpipe/eval`), -1 if none.
private long hovered(string kind) {
    return getJson("/api/toolpipe/eval")["hover"][kind].integer;
}

private string toolNow() {
    auto s = getJson("/api/tool/state");
    return "tool" in s.object ? s["tool"].str : "";
}

/// Reset to the cube, set the selection type, arm `tool` (or none).
private void rig(string type, string tool) {
    run("scene.reset");
    run("select.typeFrom " ~ type);
    if (tool.length) {
        auto r = postJson("/api/script", "tool.set " ~ tool ~ " on");
        assert(r["status"].str == "ok", "arm " ~ tool ~ " failed: " ~ r.toString);
    }
    settleFrames();
}

private enum DHVec3 kV = DHVec3(0.5f, 0.5f, 0.5f);      // a cube corner facing the camera
private enum DHVec3 kE = DHVec3(0.0f, 0.5f, 0.5f);      // the mid of the top-front edge

private long vertexIndexAt(DHVec3 w) {
    foreach (i, v; getJson("/api/model")["vertices"].array)
        if (abs(v[0].floating - w.x) < 1e-4 && abs(v[1].floating - w.y) < 1e-4
            && abs(v[2].floating - w.z) < 1e-4)
            return cast(long) i;
    assert(false, format("rig: no cube vertex at %s", w));
}

/// One cell: arm, point at `at`, check the pointer resolved `kind`, count.
private size_t cellPx(string type, string tool, DHVec3 at, string kind) {
    rig(type, tool);
    immutable int[2] p = windowPx(at);
    immutable size_t n = changedPx(p);
    immutable long h = hovered(kind);
    assert(h >= 0, format("rig (%s mode, tool '%s'): the pointer on %s resolved no hovered %s "
                          ~ "(eval %s) — a zero below would say nothing", type, tool, at, kind,
                          getJson("/api/toolpipe/eval")["hover"].toString));
    if (kind == "vertex")
        assert(h == vertexIndexAt(kV), format("rig: hovered vertex %s, not the corner", h));
    writefln("[display] %s mode, tool '%s' (%s), on %s: %s changed px", type, tool,
             toolNow(), kind, n);
    return n;
}

/// The no-tool control of the same point: selection type decides.
private size_t noToolPx(string type, DHVec3 at, string kind) {
    return cellPx(type, "", at, kind);
}

// ---------------------------------------------------------------------------
// H7 cells. Ordered: every control (must be > 0) above the zero it frames.
// ---------------------------------------------------------------------------

unittest { // C-H7: Slice, Edge Extend, Polygon Bevel 0; Edge Slice > 0; no tool > 0
    immutable size_t noToolEdge = noToolPx("edge", kE, "edge");
    assert(noToolEdge > 0, "C-H7 control: no tool, edge mode, the hovered edge draws nothing");
    immutable size_t es = cellPx("edge", "mesh.edgeSliceTool", kE, "edge");
    assert(es > 0, "C-H7: Edge Slice (rollover target) does not draw its hovered target edge");
    foreach (tool; ["mesh.sliceTool", "edge.extend"]) {
        rig("edge", tool);
        immutable size_t n = changedPx(windowPx(kE));
        assert(n == 0, format("C-H7: %s (no rollover flag) drew %s px of hover at the edge",
                              tool, n));
    }
    immutable size_t noToolPoly = noToolPx("polygon", kE, "face");
    assert(noToolPoly > 0, "C-H7 control: no tool, polygon mode, the hovered face draws nothing");
    rig("polygon", "poly.bevel");
    immutable size_t bev = changedPx(windowPx(kE));
    assert(bev == 0, format("C-H7: Polygon Bevel (no rollover flag) drew %s px of hover", bev));
}

unittest { // C-H7-vert: vertex mode, Move and vertex Bevel 0; no tool > 0
    immutable size_t noTool = noToolPx("vertex", kV, "vertex");
    assert(noTool > 0, "C-H7-vert control: no tool, vertex mode, the hovered vertex draws nothing");
    foreach (tool; ["TransformMove", "mesh.vertexBevel"]) {
        rig("vertex", tool);
        immutable size_t n = changedPx(windowPx(kV));
        assert(n == 0, format("C-H7-vert: %s drew %s px of hover at the vertex", tool, n));
    }
}

unittest { // C-H7-elem: Element Move highlights only the hovered VERTEX, in every mode
    // Vertex mode, on the vertex: the element falloff's flag draws it, as much
    // as no tool does (36 = 36 captured).
    immutable size_t vNo = noToolPx("vertex", kV, "vertex");
    immutable size_t vEm = cellPx("vertex", "ElementMove", kV, "vertex");
    assert(vNo > 0 && vEm == vNo,
           format("C-H7-elem (vertex mode, on v): Element Move %s px, no tool %s px — "
                  ~ "captured equal and > 0", vEm, vNo));
    // Edge mode, on v: the vertex dot, where no tool draws edges.
    immutable size_t evNo = noToolPx("edge", kV, "edge");
    immutable size_t evEm = cellPx("edge", "ElementMove", kV, "vertex");
    // (Our no-tool edge mode lights ONE edge there, the capture two — that
    // control is a floor, not a relation to pin.)
    assert(evNo > 0 && evEm == vEm,
           format("C-H7-elem (edge mode, on v): Element Move %s px, captured the vertex dot "
                  ~ "(= the vertex-mode %s px); no tool %s px", evEm, vEm, evNo));
    // Edge mode, on the edge; polygon mode, on the edge: nothing.
    immutable size_t eNo = noToolPx("edge", kE, "edge");
    immutable size_t pNo = noToolPx("polygon", kE, "face");
    assert(eNo > 0 && pNo > 0, "C-H7-elem controls: no tool draws nothing on the edge");
    immutable size_t eEm = cellPx("edge", "ElementMove", kE, "edge");
    assert(eEm == 0, format("C-H7-elem (edge mode, on the edge): Element Move drew %s px of "
                            ~ "hover, captured 0 (no tool %s)", eEm, eNo));
    immutable size_t pEm = cellPx("polygon", "ElementMove", kE, "edge");
    assert(pEm == 0, format("C-H7-elem (polygon mode, on the edge): Element Move drew %s px of "
                            ~ "hover, captured 0 (no tool %s)", pEm, pNo));
}

unittest { // Magnet: no rollover flag in the table — its hovered vertex is not drawn
    immutable size_t noTool = noToolPx("vertex", kV, "vertex");
    assert(noTool > 0, "magnet control: no tool, vertex mode, the hovered vertex draws nothing");
    // The magnet still PICKS the vertex (its gesture reads it): the pick need
    // and the rollover are two data.
    immutable size_t n = cellPx("vertex", "xfrm.magnet", kV, "vertex");
    assert(n == 0, format("magnet (no rollover flag, M6 flip): drew %s px of hover at the vertex",
                          n));
}

unittest { // Tack: no counterpart — the face it aims at stays drawn (carried)
    immutable size_t n = cellPx("polygon", "mesh.tack", kE, "face");
    assert(n > 0, "tack (target, carried: no counterpart): the hovered face is no longer drawn");
}

// ---------------------------------------------------------------------------
// H8 — C-H8-ctl
// ---------------------------------------------------------------------------

unittest { // C-H8-ctl: the handle after a step undo stands on the operation's base
    alias H = edge_extend_gesture_helpers;
    enum double PX = 0.5, PY = 1.35;
    H.rigNoArm([[7, 8]], true, 0.3, 0.55, false);
    H.keyArm();
    H.frontHaul(PX, PY, H.kIncrementPx, H.kIncrementPx, 10);
    immutable H.Offset o1 = H.offset();
    immutable double[3] g1 = H.gizmoCentre();
    // Captured h1: (1.1211, 0.3758) — the base (1, 0.5) of edge (7,8) + o1.
    assert(abs(g1[0] - 1.1211) <= 0.03 && abs(g1[1] - 0.3758) <= 0.03,
           format("rig (C-H8-ctl): the handle after h1 is %s, captured (1.121, 0.376)", g1));
    H.frontHaul(PX, PY, H.kIncrementPx, H.kIncrementPx, 10);
    immutable double[3] g2 = H.gizmoCentre();
    assert(sqrt((g2[0] - g1[0]) ^^ 2 + (g2[1] - g1[1]) ^^ 2) > 0.05,
           format("rig (C-H8-ctl): h2 did not move the handle (%s -> %s)", g1, g2));
    // The rival HB-sel reads the CURRENT selection; the cell separates the two
    // only if that selection's centre is not the operation's base.
    auto m = H.model();
    double sx = 0, sy = 0;
    size_t n;
    foreach (ei; H.selectedEdgeList()) {
        foreach (vi; m["edges"][ei].array) {
            auto p = H.vtx(m, cast(size_t) vi.integer);
            sx += p[0]; sy += p[1]; ++n;
        }
    }
    assert(n > 0, "rig (C-H8-ctl): nothing is selected after the hauls");
    immutable double selX = sx / n + o1.x, selY = sy / n + o1.y;
    assert(abs(selX - g1[0]) > 0.05 || abs(selY - g1[1]) > 0.05,
           format("rig (C-H8-ctl): HB-sel (%s, %s) coincides with HB-op %s — the cell cannot "
                  ~ "tell the base from the selection", selX, selY, g1));
    H.ctrlZ();
    assert(H.toolId() == "edgeExtend", "rig (C-H8-ctl): Ctrl+Z #1 ended the tool");
    immutable H.Offset oz = H.offset();
    assert(abs(oz.x - o1.x) <= 1e-6 && abs(oz.y - o1.y) <= 1e-6,
           format("rig (C-H8-ctl): Ctrl+Z #1 did not restore h1's offset (%s, h1 %s)", oz, o1));
    H.assertHandleAt(g1[0], g1[1], 0.02,
        format("C-H8-ctl: after Ctrl+Z #1 the handle is not on the operation's base + the "
               ~ "restored offset (HB-op, captured (1.121, 0.376); HB-sel would be (%s, %s))",
               selX, selY));
}
