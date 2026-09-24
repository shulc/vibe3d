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
