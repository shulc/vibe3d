// test_edge_slice_symmetry.d — item 6 witness: with X symmetry on, an Edge
// Slice cut is mirrored, from EITHER side.
//
// Measured law (reference capture, the flat 4x4 grid, symmetry X): taps on
// the edges through (1.5,0,0) and (1.5,0,1) give 29 v / 18 f with the new
// vertices at (+-1.5, 0, 0) and (+-1.5, 0, 1); taps on the -X side at -1.3
// and -1.605 give +X copies at +1.3 and +1.605 exactly. There is no leading
// side. The reference puts the -X copy first in index order; that order is
// NOT asserted here (the new vertices are compared as a set).
//
// Our clicks do not land on the reference's parameter, so the expected set
// is built from OUR latched points (read back from /api/tool/state) and
// their mirror images; each copy is an independent vertex, so the compare is
// not self-referential.
//
// Rig: tests/slice_grid_helpers.d (grid, top-down camera, real input).
// Block order: the symmetry-OFF control, then +X (the red line on the
// unfixed tree), then -X (the no-leading-side discriminator).

import slice_leak_helpers;
import slice_grid_helpers;
import http_client : getJson;
import std.json : JSONType;
import std.format : format;
import std.stdio : writeln;

void main() {}

void symmetryX(bool on) {
    slLine("tool.pipe.attr symmetry enabled " ~ (on ? "true" : "false"));
    if (!on) return;
    slLine("tool.pipe.attr symmetry axis x");
    slLine("tool.pipe.attr symmetry offset 0");
    // Positive control: the pair table is live on this grid (5 on-plane
    // vertices, (1,0,0) paired with (-1,0,0)).
    auto s = getJson("/api/toolpipe/eval")["symmetry"];
    auto m = getJson("/api/model");
    size_t onPlane;
    foreach (b; s["onPlane"].array) if (b.type == JSONType.true_) ++onPlane;
    assert(s["enabled"].type == JSONType.true_ && s["pairOf"].array.length == GRID_VERTS
           && onPlane == 5
           && s["pairOf"].array[gridVert(m, 1, 0)].integer == gridVert(m, -1, 0),
           "symmetry floor: X symmetry is not live on the grid: " ~ s.toString);
}

/// Two clicks (press + release, no drag) on the grid edges through
/// (x0, 0, 0) and (x1, 0, 1). Returns our latched point positions.
double[3][] twoClicks(double x0, double x1) {
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    const double[2] xs = [x0, x1];
    foreach (k; 0 .. 2) {
        const double z = k;
        const lo = xs[k] < 0 ? (xs[k] < -1 ? -2.0 : -1.0) : (xs[k] > 1 ? 1.0 : 0.0);
        const pr = gridPair(lo, z, lo + 1, z);
        const p = pixelOf(xs[k], 0, z);
        hoverFloor(p, pr[0], pr[1], format("click %d", k + 1));
        slClickDown(p[0], p[1], format("click %d", k + 1));
        slPlay(slButton(20, false, 1, p[0], p[1]), format("release %d", k + 1));
    }
    const pts = latchedPositions();
    assert(pts.length == 2, format("slice chain input: %d latched point(s)", pts.length));
    foreach (p; pts)
        assert((x0 > 0) == (p[0] > 0) && p[0] != 0,
               "slice chain input: a latched point is on the wrong side: " ~ p3s(pts));
    return pts.dup;
}

/// The new vertices equal `want` as a set (+-1e-5), and there are as many.
bool sameSet(const double[3][] got, const double[3][] want) {
    if (got.length != want.length) return false;
    foreach (w; want) {
        bool hit;
        foreach (g; got) if (dist3(g, w) <= 1e-5) hit = true;
        if (!hit) return false;
    }
    return true;
}

double[3] mirrorX(double[3] p) { return [-p[0], p[1], p[2]]; }

// Control — symmetry OFF: the cut stays on its own side.
unittest {
    gridRig(false);
    symmetryX(false);
    const pts = twoClicks(1.5, 1.5);
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    writeln("control (symmetry off): ", mesh, " points ", p3s(pts), " new ", p3s(born));
    assert(mesh.verts == 27 && mesh.faces == 17 && sameSet(born, pts),
           "symmetry control: the unmirrored cut is not 27v/17f on our own points: "
           ~ mesh.toString ~ " " ~ p3s(born));
    slLine("tool.set mesh.edgeSliceTool off");
}

// +X, symmetry ON — the red line on the unfixed tree.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    const pts = twoClicks(1.5, 1.5);
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    const want = pts ~ [mirrorX(pts[0]), mirrorX(pts[1])];
    writeln("+X (symmetry on): ", mesh, " points ", p3s(pts), " new ", p3s(born),
            " expected ", p3s(want));
    assert(mesh.verts == 29 && mesh.faces == 18 && sameSet(born, want),
           format("mirrored cut missing: mesh %s, new vertices %s, expected %s",
                  mesh.toString, p3s(born), p3s(want)));
    slLine("tool.set mesh.edgeSliceTool off");
}

// -X, symmetry ON — the cut made on the negative side is mirrored too.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    const pts = twoClicks(-1.3, -1.6);
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    const want = pts ~ [mirrorX(pts[0]), mirrorX(pts[1])];
    writeln("-X (symmetry on): ", mesh, " points ", p3s(pts), " new ", p3s(born),
            " expected ", p3s(want));
    assert(mesh.verts == 29 && mesh.faces == 18 && sameSet(born, want),
           format("cut not mirrored from the negative side: mesh %s, new vertices %s, "
                  ~ "expected %s", mesh.toString, p3s(born), p3s(want)));
    slLine("tool.set mesh.edgeSliceTool off");
}

// Z-direction edges, symmetry ON — the other orientation branch. The grid's
// edges through (1,0,0.3) and (2,0,0.3) are stored in the opposite order to
// their mirror images', so the mirror point sits at `1 - t` along the stored
// mirror edge; reading `t` there unflipped lands it at z = 1 - 0.3.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    const double[2] xs = [1.0, 2.0];
    foreach (k; 0 .. 2) {
        const pr = gridPair(xs[k], 0, xs[k], 1);
        const p = pixelOf(xs[k], 0, 0.3);
        hoverFloor(p, pr[0], pr[1], format("z click %d", k + 1));
        slClickDown(p[0], p[1], format("z click %d", k + 1));
        slPlay(slButton(20, false, 1, p[0], p[1]), format("z release %d", k + 1));
    }
    const pts = latchedPositions();
    assert(pts.length == 2 && pts[0][2] > 0.2 && pts[0][2] < 0.4,
           "z-edge chain input: " ~ p3s(pts));
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    const want = pts ~ [mirrorX(pts[0]), mirrorX(pts[1])];
    writeln("z edges (symmetry on): ", mesh, " points ", p3s(pts), " new ", p3s(born),
            " expected ", p3s(want));
    assert(mesh.verts == 29 && sameSet(born, want),
           format("z-edge mirror not at the mirror of the point: mesh %s, new vertices %s, "
                  ~ "expected %s", mesh.toString, p3s(born), p3s(want)));
    slLine("tool.set mesh.edgeSliceTool off");
}

/// Every vertex in `vs` has its X mirror in `vs` (+-1e-5).
bool mirrorClosed(const double[3][] vs) {
    foreach (v; vs) {
        bool hit;
        foreach (w; vs) if (dist3(w, mirrorX(v)) <= 1e-5) hit = true;
        if (!hit) return false;
    }
    return true;
}

/// A third click on a CUT-MADE edge (accepted: captured rule C1-3b) — the
/// primary cut's new chord (`side` 0) or its mirror image's (`side` 1). A
/// chord click is a FACE point of the base polygon on either side (captured
/// law C1-sym-own). Side 0 is the reference's cell b step 3 (31 v / 18 f,
/// both chords get the point); side 1 is cell a's step 3, where the point
/// shares no base polygon with the previous one and makes nothing (29 v).
void thirdOnCutEdge(int side) {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    const pts = twoClicks(1.5, 1.5);
    const born2 = verticesFrom(GRID_VERTS);
    assert(born2.length == 4 && born2[0][0] > 0 && born2[2][0] < 0,
           "cut-edge rig: the two-point preview is not primary-then-mirror: " ~ p3s(born2));
    const a = GRID_VERTS + 2 * side, b = a + 1;
    const mid = pixelOf((born2[2 * side][0] + born2[2 * side + 1][0]) / 2, 0,
                        (born2[2 * side][2] + born2[2 * side + 1][2]) / 2);
    hoverFloor(mid, a, b, format("side %d cut chord", side));
    slClickDown(mid[0], mid[1], "press 3");
    slPlay(slButton(20, false, 1, mid[0], mid[1]), "release 3");
    auto st = getJson("/api/tool/state");
    const segs = st["bakedSegments"].integer, msegs = st["mirrorBakedSegments"].integer;
    const facePt = st["latchedFacePoint"].toString;
    assert(facePt == "[false,false,true]",
           format("side %d: a chord click is not a base face point: latchedFacePoint %s",
                  side, facePt));
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    writeln("third on cut edge, side ", side, ": ", mesh, " segments ", segs, "/", msegs,
            " new ", p3s(born));
    const wantV = side ? 29 : 31, wantSeg = side ? 1 : 2;
    assert(segs == wantSeg && msegs == wantSeg && mesh.verts == wantV && mesh.faces == 18
           && born.length == wantV - GRID_VERTS && mirrorClosed(born),
           format("third point on a cut-made edge (side %d) is not mirrored: segments %d/%d, "
                  ~ "mesh %s, new vertices %s", side, segs, msegs, mesh.toString, p3s(born)));
}

unittest { thirdOnCutEdge(0); }
unittest { thirdOnCutEdge(1); }

/// Index of the model vertex at `p` (+-1e-3), or -1.
long vertexAt(double[3] p) {
    foreach (i, v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        if (dist3([a[0].floating, a[1].floating, a[2].floating], p) <= 1e-3) return cast(long)i;
    }
    return -1;
}

// Base terms belong to ONE session. Apply a mirrored cut with Shift+click (its
// -X chord is now base geometry of the re-armed session), then click that
// chord second: it is a base EDGE point, not a face point. Base terms read
// against the dropped session's baseline would call it a chord (face point).
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    twoClicks(1.5, 1.5);
    // Shift+click on a far face: apply and re-arm the SAME tool instance (a
    // tool switch would build a fresh one and could not see stale state).
    const pf = pixelOf(-1.5, 0, -0.5);
    slPlay(format(`{"t":20.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}`
                  ~ "\n" ~ `{"t":40.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`
                  ~ "\n" ~ `{"t":60.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  pf[0], pf[1], SL_KMOD_LSHIFT, pf[0], pf[1], SL_KMOD_LSHIFT,
                  pf[0], pf[1], SL_KMOD_LSHIFT), "session 1 shift+click apply");
    const committed = verticesFrom(GRID_VERTS);
    assert(slMesh().verts == 29 && committed.length == 4 && committed[2][0] < 0
           && slTool() == "edgeSlice" && latchedPositions().length == 0,
           "session-1 apply: expected the mirrored 29 v cut, the tool re-armed: "
           ~ slMesh().toString ~ " " ~ p3s(committed) ~ " tool " ~ slTool());
    const p1 = pixelOf(1.5, 0, 2);
    const pr1 = gridPair(1, 2, 2, 2);
    hoverFloor(p1, pr1[0], pr1[1], "session 2 click 1");
    slClickDown(p1[0], p1[1], "session 2 click 1");
    slPlay(slButton(20, false, 1, p1[0], p1[1]), "session 2 release 1");
    const a = GRID_VERTS + 2, b = GRID_VERTS + 3;
    const p2 = pixelOf((committed[2][0] + committed[3][0]) / 2, 0,
                       (committed[2][2] + committed[3][2]) / 2);
    hoverFloor(p2, a, b, "session 2 click 2 (committed -X chord)");
    slClickDown(p2[0], p2[1], "session 2 click 2");
    slPlay(slButton(20, false, 1, p2[0], p2[1]), "session 2 release 2");
    const facePt = getJson("/api/tool/state")["latchedFacePoint"].toString;
    writeln("session 2 on a committed mirror chord: latchedFacePoint ", facePt);
    assert(facePt == "[false,false]",
           "a new session read a committed chord as a face point: latchedFacePoint " ~ facePt);
    slLine("tool.set mesh.edgeSliceTool off");
}

// A point on a MIRROR-made sub-edge, then a point on an edge with an on-plane
// endpoint. Split OFF: P0/P1 on +X, P2 on the -X column edge, P3 on the
// sub-edge the mirror of P0's split made, then P4 on (0..1, z1). P3 is a base
// EDGE point and must stay where it was clicked, with its image on +X. Under
// the former two-chain bake P4 had no mirror edge, the mirror chain dropped
// there and P3's raw mirror-made indices named a primary-made sub-edge: a
// stray vertex on the x = -2 column, P3 lost. An on-plane endpoint is its own
// image, so P4 is mirrored too and the result is mirror-closed.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    slLine("tool.attr mesh.edgeSliceTool split false");
    void click(double x, double z, long a, long b, string what) {
        const p = pixelOf(x, 0, z);
        hoverFloor(p, a, b, what);
        slClickDown(p[0], p[1], what);
        slPlay(slButton(20, false, 1, p[0], p[1]), what ~ " release");
    }
    click(1.5, 0, vertexAt([1, 0, 0]), vertexAt([2, 0, 0]), "P0");
    click(1.5, 2, vertexAt([1, 0, 2]), vertexAt([2, 0, 2]), "P1");
    click(-2, 0.5, vertexAt([-2, 0, 0]), vertexAt([-2, 0, 1]), "P2");
    // The mirror of P0 splits the (-2..-1, z 0) edge; click its outer piece.
    const m0 = vertexAt([-2, 0, 0]);
    long sub = -1;
    foreach (v; verticesFrom(GRID_VERTS))
        if (v[0] < -1.4 && v[0] > -1.6 && v[2] < 1e-3 && v[2] > -1e-3) sub = vertexAt(v);
    assert(m0 >= 0 && sub >= GRID_VERTS, "alias rig: the mirror sub-edge is not there");
    click(-1.75, 0, m0, sub, "P3 mirror sub-edge");
    auto st3 = getJson("/api/tool/state");
    assert(st3["latchedFacePoint"].toString == "[false,false,false,false]",
           "alias rig: a sub-edge click is not a base edge point: "
           ~ st3["latchedFacePoint"].toString);
    const lp = latchedPositions();
    const p3 = lp[3];
    click(0.5, 1, vertexAt([0, 0, 1]), vertexAt([1, 0, 1]), "P4 on-plane edge");
    slLine("tool.set mesh.edgeSliceTool off");
    const born = verticesFrom(GRID_VERTS);
    bool image, stray, first, firstImage;
    foreach (v; born) {
        if (dist3(v, mirrorX(p3)) <= 1e-3) image = true;
        if (dist3(v, lp[0]) <= 1e-3) first = true;
        if (dist3(v, mirrorX(lp[0])) <= 1e-3) firstImage = true;
        if (v[0] < -1.99 && v[2] > 0.1 && v[2] < 0.4) stray = true;
    }
    writeln("mirror point after the mirror chain drops: ", slMesh(), " P3 ", p3s([p3]),
            " new ", p3s(born));
    // P0 -> P1 share no base polygon: no cut, but both points split their
    // edges (mirrored) once the chain has two points; 10 new vertices in all
    // (P0..P4, each mirrored), closed under the mirror.
    assert(first && firstImage && born.length == 10 && mirrorClosed(born),
           format("the non-cutting steps' edge splits are wrong (P0 %s, its image %s, 10 in "
                  ~ "all, mirror-closed %s): new vertices %s",
                  first, firstImage, mirrorClosed(born), p3s(born)));
    assert(image && !stray,
           format("a mirror-made sub-edge point is not at its click and image: image %s, "
                  ~ "stray on x = -2 %s, new vertices %s", image, stray, p3s(born)));
}

/// Unique undirected edges over the face loops, and how many join a vertex
/// with x > 0 to one with x < 0 (a cut ACROSS the symmetry plane).
long[2] edgeCounts() {
    auto m = getJson("/api/model");
    auto vs = m["vertices"].array;
    bool[ulong] seen;
    long cross;
    foreach (f; m["faces"].array) {
        auto a = f.array;
        foreach (i; 0 .. a.length) {
            const u = cast(ulong)a[i].integer, w = cast(ulong)a[(i + 1) % a.length].integer;
            const k = u < w ? (u << 32) | w : (w << 32) | u;
            if (k in seen) continue;
            seen[k] = true;
            const xu = vs[u].array[0].floating, xw = vs[w].array[0].floating;
            if ((xu > 1e-4 && xw < -1e-4) || (xu < -1e-4 && xw > 1e-4)) ++cross;
        }
    }
    return [cast(long)seen.length, cross];
}

/// Index of the model vertex within 0.02 of `p` (the prologue's cut points
/// land 0.005 off the grid parameter), or -1.
long vertexNear(double[3] p) {
    foreach (i, v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        if (dist3([a[0].floating, a[1].floating, a[2].floating], p) <= 2e-2) return cast(long)i;
    }
    return -1;
}

void clickXZ(double x, double z, double[3] a, double[3] b, string what) {
    const va = vertexNear(a), vb = vertexNear(b);
    assert(va >= 0 && vb >= 0, what ~ ": the edge's ends are not in the mesh");
    const p = pixelOf(x, 0, z);
    hoverFloor(p, va, vb, what);
    slClickDown(p[0], p[1], what);
    slPlay(slButton(20, false, 1, p[0], p[1]), what ~ " release");
}

/// Chain ownership under symmetry (captured law C1-sym-own, gap row 290;
/// raw `toolcards/bugfix_w17_slice_tools/raw/C1-sym-own-<cell>/` in the
/// private tree). Prologue P1 (+1.5, z0), P2 (+1.5, z1), then the cell's taps;
/// a point is owned where clicked, in BASE-mesh terms, and a segment cuts only
/// inside a base polygon both of its points share, so a chain that crosses
/// the plane makes no cut across it. `want`: the reference's final new
/// vertices (ours land 0.005 off on the prologue edges: matched to 0.02).
/// Measured before the law (ours): a 42/29, b 35/22, c 38/27, d 33/20 v/f.
void symOwnCell(string cell, void delegate() taps, long wantV, long wantE,
                const double[3][] want, long wantF = 18) {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    clickXZ(1.5, 0, [1, 0, 0], [2, 0, 0], cell ~ " P1");
    clickXZ(1.5, 1, [1, 0, 1], [2, 0, 1], cell ~ " P2");
    assert(slMesh().verts == 29, cell ~ ": the prologue is not the 29 v mirrored chord");
    const missed0 = getJson("/api/changes")["missedPublishers"].integer;
    taps();
    slLine("tool.set mesh.edgeSliceTool off");
    // A split-only step writes through its own publisher (the bus contract).
    const missed = getJson("/api/changes")["missedPublishers"].integer - missed0;
    const mesh = slMesh();
    const ec = edgeCounts();
    const born = verticesFrom(GRID_VERTS);
    bool setOk = born.length == want.length;
    foreach (w; want) {
        bool hit;
        foreach (g; born) if (dist3(g, w) <= 2e-2) hit = true;
        setOk = setOk && hit;
    }
    writeln("sym-own ", cell, ": ", mesh, " edges ", ec[0], " crossing ", ec[1],
            " new ", p3s(born));
    assert(missed == 0, format("sym-own %s: %d unpublished mesh write(s)", cell, missed));
    assert(mesh.verts == wantV && mesh.faces == wantF && ec[1] == 0 && setOk
           && (wantE < 0 || ec[0] == wantE),
           format("sym-own %s: expected %d v / %d f / %s e, no crossing edge, new %s; got %s, "
                  ~ "%d e, %d crossing, new %s", cell, wantV, wantF, wantE, p3s(want),
                  mesh.toString, ec[0], ec[1], p3s(born)));
}

// Cell c: tap 3 on the -X baseline edge (-1.5, z2). P2 -> P3 crosses the plane:
// NO cut; P3 splits its edge, mirrored. Reference 31 v / 18 f / 48 e.
unittest {
    symOwnCell("c", () {
        clickXZ(-1.5, 2, [-2, 0, 2], [-1, 0, 2], "c P3");
    }, 31, 48, [[1.5, 0, 0], [1.5, 0, 1], [1.5, 0, 2], [-1.5, 0, 0], [-1.5, 0, 1], [-1.5, 0, 2]]);
}

// Cell d: tap 3 on the MIRROR chord (-1.5, z0.5) — a face point of the -X base
// polygon, no vertex; tap 4 on the +X boundary (2, z0.5): no cut from the face
// point, and none from P2 either though P2 and it share a base polygon (not
// consecutive). Reference 31 v / 18 f / 48 e.
unittest {
    symOwnCell("d", () {
        clickXZ(-1.5, 0.5, [-1.5, 0, 0], [-1.5, 0, 1], "d Q");
        clickXZ(2, 0.5, [2, 0, 0], [2, 0, 1], "d R");
    }, 31, 48, [[1.5, 0, 0], [1.5, 0, 1], [-1.5, 0, 0], [-1.5, 0, 1], [2, 0, 0.5], [-2, 0, 0.5]]);
}

// Cell a: the mirror chord again, then (-1.5, z2). Reference 31 v / 18 f / 48 e.
unittest {
    symOwnCell("a", () {
        clickXZ(-1.5, 0.5, [-1.5, 0, 0], [-1.5, 0, 1], "a Q");
        clickXZ(-1.5, 2, [-2, 0, 2], [-1, 0, 2], "a P4");
    }, 31, 48, [[1.5, 0, 0], [1.5, 0, 1], [1.5, 0, 2], [-1.5, 0, 0], [-1.5, 0, 1], [-1.5, 0, 2]]);
}

// Cell b (same-side control): the PRIMARY chord (+1.5, z0.5), then (+1.5, z2).
// Reference 33 v / 18 f; its edge count (48) is NOT pinned: there the two chord
// points are vertices in no polygon, where ours splice them into the chords
// (50 e) — a recorded divergence, not this law.
unittest {
    symOwnCell("b", () {
        clickXZ(1.5, 0.5, [1.5, 0, 0], [1.5, 0, 1], "b Q");
        clickXZ(1.5, 2, [1, 0, 2], [2, 0, 2], "b P4");
    }, 33, -1, [[1.5, 0, 0], [1.5, 0, 1], [1.5, 0, 0.5], [1.5, 0, 2],
                [-1.5, 0, 0], [-1.5, 0, 1], [-1.5, 0, 0.5], [-1.5, 0, 2]]);
}

// NOT a captured cell — the law applied where no step materialised the start:
// cell d's face point Q (unmaterialised, its step crossed the plane), then a
// point on Q's own base polygon's boundary (-2, z0.5). The step shares that
// polygon, so it cuts from Q itself (no seed vertex to continue from), on both
// sides: 33 v / 20 f, no crossing edge. Before the no-seed arm this step
// indexed the missing seed.
unittest {
    symOwnCell("d-shared", () {
        clickXZ(-1.5, 0.5, [-1.5, 0, 0], [-1.5, 0, 1], "d-shared Q");
        clickXZ(-2, 0.5, [-2, 0, 0], [-2, 0, 1], "d-shared R");
    }, 33, -1, [[1.5, 0, 0], [1.5, 0, 1], [-1.5, 0, 0], [-1.5, 0, 1], [1.5, 0, 0.5],
                [-1.5, 0, 0.5], [2, 0, 0.5], [-2, 0, 0.5]], 20);
}

// Ownership with symmetry OFF (captured law C1-own-off, gap row 314; raw
// `toolcards/bugfix_w17_slice_tools/raw/C1-own-off{,-ctl}/` in the private
// tree): the law is one mechanism, not a symmetry feature. Taps (1.5, z0),
// (1.5, z2) share no base polygon: both edges split, NO chord and no vertex at
// (1.5, 0, 1) — 27 v / 16 f / 42 e (a strip cut would give 28/18). Tap 3 at
// (2, z1.5) shares the (1..2, 1..2) cell with the LATEST point: 28 / 17 / 44.
// The control's first two taps share the (1..2, 0..1) cell: 27/17/43, then
// 28/18/45.
void ownOffCell(string cell, double z2, long[3] want2, long[3] want3,
                const double[3][] born3) {
    gridRig(false);
    symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    void check(string step, long[3] want) {
        const m = slMesh();
        const ec = edgeCounts();
        writeln("own-off ", cell, " ", step, ": ", m, " edges ", ec[0], " new ",
                p3s(verticesFrom(GRID_VERTS)));
        assert(m.verts == want[0] && m.faces == want[1] && ec[0] == want[2],
               format("own-off %s %s: expected %s v/f/e, got %s, %d e, new %s", cell, step,
                      want, m.toString, ec[0], p3s(verticesFrom(GRID_VERTS))));
    }
    clickXZ(1.5, 0, [1, 0, 0], [2, 0, 0], cell ~ " t1");
    clickXZ(1.5, z2, [1, 0, z2], [2, 0, z2], cell ~ " t2");
    check("t2", want2);
    clickXZ(2, 1.5, [2, 0, 1], [2, 0, 2], cell ~ " t3");
    check("t3", want3);
    slLine("tool.set mesh.edgeSliceTool off");
    check("committed", want3);
    const born = verticesFrom(GRID_VERTS);
    bool setOk = born.length == born3.length;
    foreach (w; born3) {
        bool hit;
        foreach (g; born) if (dist3(g, w) <= 2e-2) hit = true;
        setOk = setOk && hit;
    }
    assert(setOk, format("own-off %s: new vertices %s, expected %s", cell, p3s(born), p3s(born3)));
}

unittest {
    ownOffCell("main", 2, [27, 16, 42], [28, 17, 44], [[1.5, 0, 0], [1.5, 0, 2], [2, 0, 1.5]]);
}

unittest {
    ownOffCell("ctl", 1, [27, 17, 43], [28, 18, 45], [[1.5, 0, 0], [1.5, 0, 1], [2, 0, 1.5]]);
}

// A PARAMETER re-bake keeps the law: cell c, then Split Polygons off and on
// again (each `tool.attr` re-bakes the live chain from the baseline). Still
// 31 v / 18 f / 48 e, mirror-closed, no crossing edge.
unittest {
    symOwnCell("c-rebake", () {
        clickXZ(-1.5, 2, [-2, 0, 2], [-1, 0, 2], "c-rebake P3");
        slLine("tool.attr mesh.edgeSliceTool split false");
        slLine("tool.attr mesh.edgeSliceTool split true");
    }, 31, 48, [[1.5, 0, 0], [1.5, 0, 1], [1.5, 0, 2], [-1.5, 0, 0], [-1.5, 0, 1], [-1.5, 0, 2]]);
}

// Base polygons follow the EFFECTIVE position. P1 at x = 1.1 on (1..2, z0) and
// P2 at x = 0.5 on (0..1, z1) share no base polygon (29 v / 16 f: four splits).
// Snap 50 % then rounds P1 onto the base vertex (1, 0, 0), a corner of the
// (0..1, 0..1) cell P2 is on: the step now cuts, mirrored — 27 v / 18 f with
// only (+-0.5, 0, 1) new. Polygons frozen at the latch keep 16 faces.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    clickXZ(1.1, 0, [1, 0, 0], [2, 0, 0], "snap P1");
    clickXZ(0.5, 1, [0, 0, 1], [1, 0, 1], "snap P2");
    const before = slMesh();
    assert(before.verts == 29 && before.faces == 16,
           "snap rig: the unsnapped chain is not four edge splits: " ~ before.toString);
    slLine("tool.attr mesh.edgeSliceTool snap 50");
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    const ec = edgeCounts();
    // The snap is a sticky panel value: put the default back for later cells.
    slLine("tool.set mesh.edgeSliceTool on");
    slLine("tool.attr mesh.edgeSliceTool snap 0.5");
    slLine("tool.set mesh.edgeSliceTool off");
    writeln("snap onto a base vertex: ", mesh, " crossing ", ec[1], " new ", p3s(born));
    assert(mesh.verts == 27 && mesh.faces == 18 && ec[1] == 0 && mirrorClosed(born),
           format("a point snapped onto a base vertex did not take that vertex's polygons: "
                  ~ "mesh %s, new vertices %s", mesh.toString, p3s(born)));
}

// A WARPED base polygon: (2, 0, 1) and its mirror raised to y = 0.6, so the
// (1..2, 0..1) cell is not planar. A click on the prologue's chord lands
// inside that cell's Newell outline but on neither of its fan triangles; it
// must still be a face point of the cell, sharing it with P2 (cell b's step 3:
// 31 v / 18 f, the chord point on both chords).
unittest {
    gridRig(false);
    foreach (x; [2.0, -2.0])
        slCmd("mesh.move_vertex", format(`{"from":[%s,0,1],"to":[%s,0.6,1]}`, x, x));
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    void click3(double[3] at, double[3] a, double[3] b, string what) {
        const va = vertexNear(a), vb = vertexNear(b);
        assert(va >= 0 && vb >= 0, what ~ ": the edge's ends are not in the mesh");
        const p = pixelOf(at[0], at[1], at[2]);
        hoverFloor(p, va, vb, what);
        slClickDown(p[0], p[1], what);
        slPlay(slButton(20, false, 1, p[0], p[1]), what ~ " release");
    }
    click3([1.5, 0, 0], [1, 0, 0], [2, 0, 0], "warp P1");
    click3([1.5, 0.3, 1], [1, 0, 1], [2, 0.6, 1], "warp P2");
    const lp = latchedPositions();
    assert(lp.length == 2 && slMesh().verts == 29, "warp rig: the prologue chord is not there");
    const double[3] mid = [(lp[0][0] + lp[1][0]) / 2, (lp[0][1] + lp[1][1]) / 2,
                           (lp[0][2] + lp[1][2]) / 2];
    click3(mid, lp[0], lp[1], "warp Q on the chord");
    const facePt = getJson("/api/tool/state")["latchedFacePoint"].toString;
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    writeln("chord point in a warped polygon: ", mesh, " face ", facePt, " new ", p3s(born));
    assert(facePt == "[false,false,true]" && mesh.verts == 31 && mesh.faces == 18
           && mirrorClosed(born),
           format("a chord point in a warped base polygon is not a face point of it: face %s, "
                  ~ "mesh %s, new vertices %s", facePt, mesh.toString, p3s(born)));
}

// A point PARKED by a parameter re-bake. P0 x = 1.1 on (1..2, z0) and P1
// x = 0.5 on (0..1, z1) share no base polygon (four splits, mirrored); P2
// lands on the MIRROR sub-edge (-2..-1.1, z0), whose vertices only that split
// made. Snap 50 % then puts P0 on the base vertex (1, 0, 0): the step cuts
// instead, (-1.1, 0, 0) is never made, and P2's rail is gone. It must be
// parked — owns nothing, drawn nowhere, no handle — and the next frame must
// not read its vanished vertex (before: `ArrayIndexError … [27] … length 27`,
// the app died). Retroactive parameters re-baking earlier points are OUR
// behaviour, not captured.
void parkCell(bool sym, double p0x, double p2x, double[3] a2, double[3] b2, string tag) {
    gridRig(false);
    symmetryX(sym);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    clickXZ(p0x, 0, [1, 0, 0], [2, 0, 0], tag ~ " P0");
    clickXZ(0.5, 1, [0, 0, 1], [1, 0, 1], tag ~ " P1");
    clickXZ(p2x, 0, a2, b2, tag ~ " P2");
    slLine("tool.attr mesh.edgeSliceTool snap 50");
    // Several frames under the re-baked preview (draw, handles, HUD).
    foreach (k; 0 .. 3) slHover(pixelOf(0, 0, -1.5)[0], pixelOf(0, 0, -1.5)[1]);
    auto st = getJson("/api/tool/state");
    const parked = st["latchedParked"].toString;
    const handles = getJson("/api/tool/handles");
    long[] parts;
    foreach (h; handles["handles"]["parts"].array) parts ~= h["part"].integer;
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    slLine("tool.set mesh.edgeSliceTool on");
    slLine("tool.attr mesh.edgeSliceTool snap 0.5");
    slLine("tool.set mesh.edgeSliceTool off");
    writeln("parked ", tag, ": parked ", parked, " handles ", handles.toString, " committed ",
            mesh, " new ", p3s(born));
    if (sym)
        assert(parked == "[false,false,true]" && parts == [0L, 1L] && mesh.verts == 27
               && mesh.faces == 18 && mirrorClosed(born),
               format("parked %s: expected P2 parked (no handle) and the 27 v / 18 f mirrored cut; "
                      ~ "parked %s, handle parts %s, mesh %s, new %s", tag, parked, parts,
                      mesh.toString, p3s(born)));
    else
        assert(parked == "[false,false,true]" && parts == [0L, 1L] && mesh.verts == 26
               && mesh.faces == 17,
               format("parked %s: P2's indices re-used for the new chord must park it (26 v / "
                      ~ "17 f, P1's cut only); parked %s, handle parts %s, mesh %s, new %s", tag,
                      parked, parts, mesh.toString, p3s(born)));
}

unittest { parkCell(true, 1.1, -1.5, [-2, 0, 0], [-1.1, 0, 0], "sym"); }

// The same sequence with symmetry OFF, P0 at x = 1.2 and P2 on the sub-edge
// (1..1.2, z0) P0's split made: after the re-bake vertex 25 is P1's cut, so
// P2's indices name the new chord (1,0,0)-(0.5,0,1) — a LIVE edge in another
// base polygon than the click's. Parked as well (before: it rode the chord and
// split it at (0.75, 0, 0.5), 27 v / 17 f). Ours, not captured.
unittest { parkCell(false, 1.2, 1.07, [1, 0, 0], [1.2, 0, 0], "off"); }

// And a rail that is simply GONE at in-range indices: P2 on the sub-edge
// (1.2..2, z0); after the re-bake vertex 25 is P1's cut and (25, (2,0,0)) is
// no edge. Parked by the bake (an index-range check alone would draw it
// between two unrelated vertices).
unittest { parkCell(false, 1.2, 1.6, [1.2, 0, 0], [2, 0, 0], "off-gone"); }
