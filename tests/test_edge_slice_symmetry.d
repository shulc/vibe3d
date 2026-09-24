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

// A point on a MIRROR-made sub-edge, followed by a point with no mirror edge.
// Split OFF: P0/P1 on +X, P2 on the -X column edge, P3 on the sub-edge the
// mirror of P0's split made, then P4 on an edge with an on-plane endpoint
// (no mirror edge). P3 is a base EDGE point and must stay where it was
// clicked, with its image on +X. Under the former two-chain bake the mirror
// chain dropped at P4 and P3's raw mirror-made indices named a primary-made
// sub-edge: a stray vertex on the x = -2 column, P3 lost.
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
    // edges (mirrored) once the chain has two points; 9 new vertices in all
    // (P0, P1, P2 and P3 mirrored, P4 alone: its edge has no mirror edge).
    assert(first && firstImage && born.length == 9,
           format("the non-cutting steps' edge splits are wrong (P0 %s, its image %s, 9 in all): "
                  ~ "new vertices %s",
                  first, firstImage, p3s(born)));
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
