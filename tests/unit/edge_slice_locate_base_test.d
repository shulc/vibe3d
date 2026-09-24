// edge_slice_locate_base_test — Edge Slice's base-mesh location
// (`locateBase` / `pointInPolygon`, source/tools/slice/edge_slice_tool.d):
// which BASE polygons a chain point lies in (measured ownership law,
// C1-sym-own / C1-own-off, gap rows 290/314). Cells: the tolerances are
// relative to size (scale 1e-3 and 1e3), and a point ON an interior vertex
// takes all four of its polygons, including the diagonal one that shares no
// edge with the edge the point was found on.
module tests.unit.edge_slice_locate_base_test;

import math : Vec3;
import tools.slice.edge_slice_tool : locateBase, pointInPolygon;

// A 2x2 quad grid in y = 0 with spacing `h`, origin at `o`: vertices
// v(i, j) = o + (i*h, 0, j*h), i, j in 0..2; faces 0..3 in (i, j) cell order.
private struct Grid {
    Vec3[] vs;
    uint[2][] es;
    uint[][] fs;
}

private Grid grid(float h, Vec3 o = Vec3(0, 0, 0)) {
    Grid g;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3) g.vs ~= Vec3(o.x + i * h, o.y, o.z + j * h);
    uint v(uint i, uint j) { return j * 3 + i; }
    foreach (j; 0u .. 2u)
        foreach (i; 0u .. 2u) g.fs ~= [v(i, j), v(i + 1, j), v(i + 1, j + 1), v(i, j + 1)];
    bool[ulong] seen;
    foreach (f; g.fs)
        foreach (k; 0 .. 4) {
            uint a = f[k], b = f[(k + 1) % 4];
            if (a > b) { const t = a; a = b; b = t; }
            const key = (cast(ulong)a << 32) | b;
            if (key in seen) continue;
            seen[key] = true;
            g.es ~= [a, b];
        }
    return g;
}

// Scale 1e-3: a point 2e-5 inside a cell, off its bottom edge, is a FACE point
// of that cell. An absolute 1e-4 edge tolerance calls it an edge point.
unittest {
    const g = grid(1e-3f);
    const q = Vec3(0.5e-3f, 0, 2e-5f);           // cell 0, 2e-5 above edge (0,0)-(1,0)
    bool face;
    const fs = locateBase(g.vs, g.es, g.fs, q, face);
    assert(face && fs == [0u],
           "scale 1e-3: a point 2e-5 off a 1e-3 edge was not a face point of cell 0");
}

// Scale 1e3: a point computed ON an oblique edge far from the origin carries
// float error far above 1e-4; it is still an EDGE point (of that edge's cells).
unittest {
    import std.math : sqrt;
    // Oblique base edge: move v(1,1) so the edge v(0,1)-v(1,1) is not axis-aligned.
    auto g = grid(1e3f, Vec3(4000, 0, 4000));
    g.vs[4] = Vec3(g.vs[4].x + 137.0f, 0, g.vs[4].z + 311.0f);
    const a = g.vs[3], b = g.vs[4];
    // A parameter whose float lerp lands measurably off the exact line.
    Vec3 q;
    double off = 0;
    foreach (k; 1 .. 1000) {
        const t = k / 1000.0f;
        const c = a + (b - a) * t;
        // exact distance of c from the line a-b, in double
        const dx = cast(double)b.x - a.x, dz = cast(double)b.z - a.z;
        const d = ((cast(double)c.x - a.x) * dz - (cast(double)c.z - a.z) * dx) / sqrt(dx * dx + dz * dz);
        if ((d < 0 ? -d : d) > off) { off = d < 0 ? -d : d; q = c; }
    }
    assert(off > 1e-4, "scale 1e3 rig: no float lerp landed more than 1e-4 off the edge");
    bool face;
    const fs = locateBase(g.vs, g.es, g.fs, q, face);
    assert(!face && fs.length == 2,
           "scale 1e3: a point on a 1e3 edge (float error > 1e-4) was not an edge point");
}

// An interior vertex: the point sits ON v(1,1), found on whichever of its four
// edges comes first; its polygons are ALL FOUR cells, including the diagonal
// one that does not contain that edge — so a next point in the diagonal cell
// shares a polygon with it (the snap-onto-a-vertex case).
unittest {
    const g = grid(1.0f);
    bool face;
    const fs = locateBase(g.vs, g.es, g.fs, g.vs[4], face);
    bool[uint] got;
    foreach (f; fs) got[f] = true;
    assert(!face && fs.length == 4 && (0 in got) && (1 in got) && (2 in got) && (3 in got),
           "interior vertex: its four polygons were not all taken");
}

// pointInPolygon on a WARPED quad: a point on the chord between two edge
// midpoints is inside, although it lies on neither fan triangle.
unittest {
    const Vec3[] vs = [Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(2, 0.6f, 1), Vec3(1, 0, 1)];
    const uint[] f = [0, 1, 2, 3];
    float d;
    assert(pointInPolygon(Vec3(1.5f, 0.15f, 0.5f), vs, f, d),
           "warped quad: a chord point is not inside");
    assert(!pointInPolygon(Vec3(2.5f, 0.15f, 0.5f), vs, f, d),
           "warped quad: a point outside the outline is inside");
}
