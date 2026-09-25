// test_edge_slice_subpatch_pending_draw.d — item 10 witness (Edge Slice draws
// nothing for a point that has not been clicked yet).
//
// Measured law (captured on a subpatch mesh and, separately, on a polygonal
// one): before the press, the only thing drawn for the next point is the
// highlight of the hovered target edge — no pending point, no segment from
// the last point to the cursor. The cut is baked at the PRESS and shown
// through the smoothed surface. On a subpatch mesh the edge picker resolves
// the DISPLAYED (smoothed) edge, not the cage edge.
//
// Rig: the slice-tool prologue with subpatch ON (tests/slice_leak_helpers.d):
// the open box, 8 v / 4 f. Every pixel is a projection through the live
// camera; every click is sent only at a pixel that hovered the named edge.
//
// Block order (green blocks first, the red line last):
//   P — the edge pick sits on the displayed smoothed edge, well off the cage
//       edge's projection;
//   B — the press alone bakes the cut (8 -> 10 vertices);
//   D — after one click, hovering the next edge draws no pending chord (the
//       red line) and no pending handle (its own red run: the task card).
//       Around it: H0 (before the click, a probe on the displayed target edge
//       sees the hover highlight — the capability) and H (the same probe
//       with the chain live: the highlight is still drawn).

import slice_leak_helpers;
import http_client : getJson, quiesce;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.format : format;
import std.stdio : writeln;
import std.math : abs, sqrt, round;
import std.json;
import core.thread : Thread;
import core.time : msecs;

void main() {}

// The colours the draw calls hand to GL (source/viewport_scheme.d): the
// pending chord is `toolPathLine`, a hovered handle is `handleActive`.
private enum float[3] kChordRgb = [0.90f, 0.92f, 0.98f];
private enum float[3] kHandleActRgb = [1.00f, 0.90f, 0.40f];
// The hovered edge's highlight, `preHighlight`.
private enum float[3] kPreHiRgb = [0.549f, 0.710f, 0.780f];

private struct Px {
    int r, g, b;
    bool valid;
    string toString() const {
        return valid ? format("(%d, %d, %d)", r, g, b) : "<unreadable>";
    }
}

private Px asPx(const float[3] c) {
    return Px(cast(int)round(c[0] * 255.0), cast(int)round(c[1] * 255.0),
              cast(int)round(c[2] * 255.0), true);
}

/// Same slack as tests/test_selection_occluded_pass.d (1 per channel).
private bool near(Px a, Px b, int slack = 1) {
    return a.valid && abs(a.r - b.r) <= slack && abs(a.g - b.g) <= slack
        && abs(a.b - b.b) <= slack;
}

/// A probe reads the last COMPLETED frame, so a state change needs two.
// Card test-sleep-removal: quiesce (frame fence + no pending preview build) replaces the fixed sleep (450.msecs).
private void settle() { quiesce(); }

/// Probe WINDOW pixels of cell 0 (converted to FBO coordinates here).
private Px[] probeWin(const int[2][] pts) {
    auto c = fetchCamera();
    string q = "/api/viewport/probe?cell=0&points=";
    foreach (k, p; pts) {
        if (k) q ~= ";";
        q ~= format("%d,%d", p[0] - c.vpX, p[1] - c.vpY);
    }
    auto j = getJson(q);
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_,
           "the probed cell is not rendered under --test; every reading below is void");
    Px[] r;
    foreach (e; j["points"].array) {
        if ("error" in e) { r ~= Px(); continue; }
        r ~= Px(cast(int)e["r"].integer, cast(int)e["g"].integer,
                cast(int)e["b"].integer, true);
    }
    assert(r.length == pts.length, "probe returned a different pixel count");
    return r;
}

/// The 3x3 block centred on `p`, row-major.
private int[2][] block3(int[2] p) {
    int[2][] r;
    foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) r ~= [p[0] + dx, p[1] + dy];
    return r;
}

private string blockStr(const int[2][] pts, const Px[] px) {
    string s;
    foreach (i, p; pts) s ~= format(" (%d,%d)=%s", p[0], p[1], px[i].toString);
    return s;
}

/// Screen projection of a model point through the live camera.
private float[2] screenOf(double[3] w) {
    auto vp = viewportFromCamera(fetchCamera());
    float x, y;
    assert(projectToWindow(Vec3(w[0], w[1], w[2]), vp, x, y),
           "rig: a projected point is behind the camera");
    return [x, y];
}

private double[3] vertexPos(JSONValue m, long v) {
    auto a = m["vertices"].array[cast(size_t)v].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

/// One cage edge on screen: start point, direction, length and unit normal.
private struct ScreenEdge { float ax, ay, dx, dy, len, nx, ny; }

private ScreenEdge screenEdge(long a, long b) {
    auto m = getJson("/api/model");
    const A = screenOf(vertexPos(m, a)), B = screenOf(vertexPos(m, b));
    ScreenEdge e;
    e.ax = A[0]; e.ay = A[1];
    e.dx = B[0] - A[0]; e.dy = B[1] - A[1];
    e.len = sqrt(e.dx * e.dx + e.dy * e.dy);
    e.nx = -e.dy / e.len; e.ny = e.dx / e.len;
    return e;
}

private int[2] along(const ScreenEdge e, double t, double d) {
    return [cast(int)round(e.ax + e.dx * t + e.nx * d),
            cast(int)round(e.ay + e.dy * t + e.ny * d)];
}

private long hoverId(int[2] p) {
    slHover(p[0], p[1]);
    return getJson("/api/tool/state")["hoveredEdge"].integer;
}

/// Prologue (subpatch ON) and Edge Slice armed, no point yet. Returns the
/// chain edges.
private long[2][] armNoPoint() {
    slPrologue(true, "polygons", &slBackAndLeft, true);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    return slFrontRightChain().dup;
}

/// Prologue (subpatch ON), Edge Slice armed, point 1 latched on edge
/// `P[first]` with a click (press + release, no drag). Returns the chain edges.
private long[2][] armWithFirstPoint(size_t first, int[2] hint) {
    const P = armNoPoint();
    clickFirst(P, first, hint);
    return P.dup;
}

/// Latch point 1 on edge `P[first]` with a click (press + release, no drag).
private void clickFirst(const long[2][] P, size_t first, int[2] hint) {
    const p1 = slEdgePixel(P[first][0], P[first][1], hint, "point 1");
    slClickDown(p1[0], p1[1], "click 1");
    slPlay(slButton(20, false, 1, p1[0], p1[1]), "release 1");
    const c = slChain();
    assert(slNorm(c.pairs) == slNorm([P[first]]) && slMesh().verts == 8,
           format("slice floor: point 1 did not latch alone: pairs %s, mesh %s",
                  slPairsStr(c.pairs), slMesh().toString));
}

// Blocks P and B — green on HEAD (the pick and the press-bake are already ours).
unittest {
    const P = armWithFirstPoint(0, [323, 302]);
    const e2 = slEdgeOf(getJson("/api/model"), P[1][0], P[1][1]);
    assert(e2 >= 0, "slice rig: point 2's edge is missing");

    // Block P. Walk the cage edge's screen normal; a pixel that hovers P2 more
    // than the edge pick radius (6 px) + 1 off the cage projection can only
    // have been resolved against the displayed (smoothed) edge.
    const se = screenEdge(P[1][0], P[1][1]);
    int[2] best;
    double bestT = 0, bestD = 0;
    int[] band;
    bool found;
    foreach (t; [0.5, 0.6, 0.4]) {
        band = null;
        foreach (d; -40 .. 41)
            if (hoverId(along(se, t, d)) == e2) band ~= d;
        if (band.length == 0) continue;
        const mid = band[band.length / 2];
        if (abs(mid) <= 7) continue;
        best = along(se, t, mid); bestT = t; bestD = mid; found = true;
        writeln(format("block P: t=%.1f hover band d=%d..%d px off the cage edge "
                       ~ "projection, chosen d=%d at (%d,%d)",
                       t, band[0], band[$ - 1], mid, best[0], best[1]));
        break;
    }
    assert(found && abs(bestD) > 7, "edge pick is not on the displayed smoothed edge");

    // Block B. The press alone (no motion) bakes the cut: 8 -> 10 vertices.
    slClickDown(best[0], best[1], "press 2");
    const afterPress = slMesh();
    writeln("block B: after the press of point 2: ", afterPress,
            " pairs ", slPairsStr(slChain().pairs));
    assert(afterPress.verts == 10, "cut not baked at press");
    slPlay(slButton(20, false, 1, best[0], best[1]), "release 2");
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block D — the needle. Point 1 on the front-right vertical (P[1]); hover the
// front-left vertical (P[0]) at a pixel within 3 px of its cage projection.
// H0 runs before the click of point 1, H after the two lines of D.
unittest {
    const P = armNoPoint();
    const eT = slEdgeOf(getJson("/api/model"), P[0][0], P[0][1]);
    const se = screenEdge(P[0][0], P[0][1]);
    int[2] cur;
    double curD = 0;
    bool found;
    foreach (t; [0.5, 0.6, 0.4]) {
        foreach (d; [0, 1, -1, 2, -2, 3, -3])
            if (hoverId(along(se, t, d)) == eT) { cur = along(se, t, d); curD = d; found = true; break; }
        if (found) break;
    }
    assert(found, "block D rig: no pixel within 3 px of the target edge's cage "
                  ~ "projection hovers it");

    // H0 — X on the DISPLAYED (smoothed) curve of the target edge: the middle
    // of the pixel band that hovers it, walked along the cage edge's screen
    // normal 16 px along the edge from the cursor's foot (the pick radius is
    // symmetric, so the band's middle is the curve). A 3x3 block around X.
    const tCur = ((cur[0] - se.ax) * se.dx + (cur[1] - se.ay) * se.dy) / (se.len * se.len);
    const tX = tCur + 16.0 / se.len;
    int[] band;
    foreach (d; -40 .. 41)
        if (hoverId(along(se, tX, d)) == eT) band ~= d;
    assert(band.length > 0, format("block H0 rig: no pixel at t = %.3f hovers the target edge", tX));
    const int[2] X = along(se, tX, band[band.length / 2]);
    const dX = sqrt(cast(double)((X[0] - cur[0]) * (X[0] - cur[0]) + (X[1] - cur[1]) * (X[1] - cur[1])));
    assert(dX >= 8, format("block H0 rig: X (%d,%d) is %.1f px from the cursor", X[0], X[1], dX));
    const hiPts = block3(X);
    bool seesHi(const Px[] px) {
        foreach (p; px) if (near(p, asPx(kPreHiRgb), 2)) return true;
        return false;
    }
    slHover(cur[0], cur[1]);
    settle();
    assert(slChain().pairs.length == 0
           && getJson("/api/tool/state")["hoveredEdge"].integer == eT,
           "block H0 floor: a point is latched or the cursor lost the target edge");
    auto hi0 = probeWin(hiPts);
    writeln(format("block H0: edge %.1f px on screen, cursor foot t=%.3f, band d=%d..%d at "
                   ~ "t=%.3f, X (%d,%d), %.1f px from the cursor;", se.len, tCur,
                   band[0], band[$ - 1], tX, X[0], X[1], dX), blockStr(hiPts, hi0));
    assert(seesHi(hi0), "hover highlight probe cannot see the target edge (no chain)");

    clickFirst(P, 1, [507, 326]);
    // Hover only (motion, no button) and let two frames render.
    slHover(cur[0], cur[1]);
    settle();
    const hov = slMesh();
    assert(hov.verts == 8 && hov.faces == 4 && slChain().pairs.length == 1
           && getJson("/api/tool/state")["hoveredEdge"].integer == eT,
           format("block D floor: hovering changed the mesh or the chain, or lost the "
                  ~ "hover: mesh %s pairs %s", hov.toString, slPairsStr(slChain().pairs)));

    // Point 1 as drawn: the latched pair and t on the current mesh.
    auto m = getJson("/api/model");
    auto st = getJson("/api/tool/state");
    const pa = vertexPos(m, st["latchedPairs"].array[0].array[0].integer);
    const pb = vertexPos(m, st["latchedPairs"].array[0].array[1].integer);
    const t1 = st["latchedT"].array[0].floating;
    const s1 = screenOf([pa[0] + (pb[0] - pa[0]) * t1, pa[1] + (pb[1] - pa[1]) * t1,
                         pa[2] + (pb[2] - pa[2]) * t1]);
    // Where HEAD ends the chord: the cursor's foot on the cage edge projection.
    const u = ((cur[0] - se.ax) * se.dx + (cur[1] - se.ay) * se.dy) / (se.len * se.len);
    const fx = se.ax + se.dx * u, fy = se.ay + se.dy * u;
    const int[2] mid = [cast(int)round((s1[0] + fx) / 2), cast(int)round((s1[1] + fy) / 2)];
    const chordPts = block3(mid);
    auto chordPx = probeWin(chordPts);
    writeln(format("block D: point 1 at (%.1f,%.1f), cursor (%d,%d) %s px off the cage "
                   ~ "projection, foot (%.1f,%.1f), chord midpoint (%d,%d);",
                   s1[0], s1[1], cur[0], cur[1], curD, fx, fy, mid[0], mid[1]),
            blockStr(chordPts, chordPx));
    bool chord;
    foreach (p; chordPx) if (near(p, asPx(kChordRgb))) chord = true;
    assert(!chord, "pending segment drawn before the click");

    // Second surface: the pending point's handle. The pending point sits on
    // the cage edge under the cursor, so the handle is the hovered one and is
    // painted `handleActive` (BoxHandler.draw -> drawColor); comparing with
    // the idle `toolPath` would be green on HEAD and after the fix alike.
    // 3 px from the cursor along the edge's screen normal, on the side away
    // from the displayed edge: inside the handle square, off the highlight.
    const int[2] hp = [cast(int)round(cur[0] - se.nx * 3), cast(int)round(cur[1] - se.ny * 3)];
    const handlePts = block3(hp);
    auto handlePx = probeWin(handlePts);
    writeln(format("block D: handle probe (%d,%d);", hp[0], hp[1]), blockStr(handlePts, handlePx));
    assert(!near(handlePx[4], asPx(kHandleActRgb)), "pending point handle drawn before the click");

    // H — the same X with the chain live (the cursor is still on the target).
    auto hi1 = probeWin(hiPts);
    writeln("block H: live chain;", blockStr(hiPts, hi1));
    assert(seesHi(hi1), "target edge highlight missing during a live chain");

    // G — DURING a drag the single-edge hover stays suppressed (the picker is
    // frozen while the press re-bakes the edge array, so the held index can
    // alias another edge). Press point 2 on the target and hold it 2 px along
    // the edge; the edge submissions then must equal those with the chain
    // released and the cursor off the mesh (same mesh, nothing hovered).
    slClickDown(cur[0], cur[1], "press 2 (held)");
    slPlay(slMotion(20, cur[0] + cast(int)round(se.dx / se.len * 2),
                    cur[1] + cast(int)round(se.dy / se.len * 2), 1), "hold 2");
    settle();
    const st2 = getJson("/api/tool/state");
    assert(st2["scrubbing"].type == JSONType.true_ && st2["latchedPairs"].array.length == 2,
           "block G floor: point 2 is not latched and held: " ~ st2.toString);
    const dragCalls = edgeCalls();
    auto cam = fetchCamera();
    slPlay(slButton(20, false, 1, cur[0], cur[1]) ~ "\n" ~ slMotion(40, cam.vpX + 8, cam.vpY + 8, 0),
           "release 2, cursor off the mesh");
    settle();
    assert(getJson("/api/tool/state")["hoveredEdge"].integer == -1,
           "block G floor: the off-mesh pixel hovers an edge");
    const offCalls = edgeCalls();
    writeln(format("block G: edge submissions during the held drag %d, released off the mesh %d",
                   dragCalls, offCalls));
    assert(dragCalls == offCalls, "target edge highlight drawn during a drag");
}

private long edgeCalls() {
    return getJson("/api/frames/counts")["lastScene"]["pass"]["edges"]["calls"].integer;
}
