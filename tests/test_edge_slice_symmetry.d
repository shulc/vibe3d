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
/// primary cut's new chord (`side` 0) or its mirror image's (`side` 1). Both
/// sides must get the third point: six new vertices closed under the mirror,
/// two segments on each chain, 31 v / 18 f (measured; a click on either
/// chord gives the same mesh). Before the fix: side 0 left the mirror without
/// its third point, side 1 committed a stray cut (33 v / 22 f).
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
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    writeln("third on cut edge, side ", side, ": ", mesh, " segments ", segs, "/", msegs,
            " new ", p3s(born));
    assert(segs == 2 && msegs == 2 && mesh.verts == 31 && mesh.faces == 18
           && born.length == 6 && mirrorClosed(born),
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

// The mirror chain's vertex ranges follow a PARAMETER re-bake, not only a
// click. Split OFF, two clicks two rows apart (2 new vertices per side); Split
// ON re-bakes through the parameter path and adds each side's crossing vertex
// at z = 1, so the mirror chain's range moves. A third click on the mirror
// chord's upper piece (z 1..2, ending at the second point's image) must still
// join the mirror chain: the result is closed under the mirror. (The lower
// piece is not used: a segment from the second point across the z = 1 row
// takes a face path that is not mirror-equivariant, a separate limit.) Reading the range from before the parameter change takes the
// chord's crossing vertex for a primary one and bakes a plane-crossing chain.
unittest {
    gridRig(false);
    symmetryX(true);
    scope (exit) symmetryX(false);
    slLine("tool.set mesh.edgeSliceTool on");
    slLine("tool.attr mesh.edgeSliceTool split false");
    foreach (k; 0 .. 2) {
        const double z = 2 * k;
        const pr = gridPair(1, z, 2, z);
        const p = pixelOf(1.5, 0, z);
        hoverFloor(p, pr[0], pr[1], format("split-off click %d", k + 1));
        slClickDown(p[0], p[1], format("split-off click %d", k + 1));
        slPlay(slButton(20, false, 1, p[0], p[1]), format("split-off release %d", k + 1));
    }
    const off = verticesFrom(GRID_VERTS);
    assert(off.length == 4, "split-off chain: expected 2 points per side: " ~ p3s(off));
    slLine("tool.attr mesh.edgeSliceTool split true");
    const on = verticesFrom(GRID_VERTS);
    assert(on.length == 6 && mirrorClosed(on),
           "split-on re-bake: expected 3 vertices per side, mirrored: " ~ p3s(on));
    double[3] lo = [0, 0, 0], mid = [0, 0, 0];
    foreach (v; on) if (v[0] < 0 && v[2] > 1.5) lo = v; else if (v[0] < 0 && v[2] > 0.5 && v[2] < 1.5) mid = v;
    const a = vertexAt(lo), b = vertexAt(mid);
    assert(lo[0] < 0 && mid[0] < 0 && a >= GRID_VERTS && b >= GRID_VERTS,
           "mirror chord ends not found: " ~ p3s(on));
    const px = pixelOf((lo[0] + mid[0]) / 2, 0, (lo[2] + mid[2]) / 2);
    hoverFloor(px, a, b, "mirror chord after the split re-bake");
    slClickDown(px[0], px[1], "press 3");
    slPlay(slButton(20, false, 1, px[0], px[1]), "release 3");
    auto st = getJson("/api/tool/state");
    const segs = st["bakedSegments"].integer, msegs = st["mirrorBakedSegments"].integer;
    slLine("tool.set mesh.edgeSliceTool off");
    const mesh = slMesh();
    const born = verticesFrom(GRID_VERTS);
    writeln("third on mirror chord after a split re-bake: ", mesh, " segments ", segs, "/",
            msegs, " new ", p3s(born));
    assert(segs == 2 && msegs == 2 && mesh.verts == 33 && mesh.faces == 20
           && born.length == 8 && mirrorClosed(born),
           format("mirror chord click after a parameter re-bake is not mirrored: segments "
                  ~ "%d/%d, mesh %s, new vertices %s", segs, msegs, mesh.toString, p3s(born)));
}
