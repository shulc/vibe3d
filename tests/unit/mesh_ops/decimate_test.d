// Module unittests for `mesh_ops.decimate`, moved verbatim out of source/mesh_ops/decimate.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.decimate_test;

import mesh;
import math;
import mesh_ops.decimate;

unittest { // reduceToTarget no-op: target >= current face count
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask); // 12 tris
    assert(m.faces.length == 12);
    size_t n = m.reduceToTarget(12, true);
    assert(n == 0, "target==current must return 0, got " ~ n.to!string);
    assert(m.faces.length == 12, "mesh must be unchanged");
}

unittest { // reduceToTarget: tri cube → ~50% faces, manifold, no degenerate
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask);
    assert(m.faces.length == 12);

    size_t f0 = 12;
    size_t target = 6;
    size_t n = m.reduceToTarget(target, false);
    assert(n > 0, "expected at least 1 collapse");
    assert(m.faces.length <= f0, "face count must not increase");
    assert(m.vertices.length < 8, "vertex count must decrease");

    // No degenerate face: every face must have >= 3 distinct corners,
    // and Newell area > 0.
    import std.math : sqrt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        assert(f.length >= 3, "face " ~ fi.to!string ~ " has fewer than 3 corners");
        bool[uint] seen;
        foreach (vi; f) {
            assert(!(vi in seen), "face " ~ fi.to!string ~ " has duplicate corner");
            seen[vi] = true;
        }
        // Newell area.
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i+1)%f.length]];
            nx += (a.y-b.y)*(a.z+b.z);
            ny += (a.z-b.z)*(a.x+b.x);
            nz += (a.x-b.x)*(a.y+b.y);
        }
        assert(sqrt(nx*nx+ny*ny+nz*nz) > 1e-6f,
               "face " ~ fi.to!string ~ " has near-zero area");
    }

    // Manifold check: every edge appears on at most 2 faces.
    int[ulong] edgeFaceCnt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        foreach (i; 0 .. f.length) {
            uint a = f[i], b = f[(i+1)%f.length];
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            edgeFaceCnt[key]++;
        }
    }
    foreach (key, cnt; edgeFaceCnt)
        assert(cnt <= 2, "edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");
}

unittest { // reduceToTarget preserveBoundary=true: boundary positions kept, interior collapses happen
    import std.conv : to;
    import std.math : sqrt;

    // Build a denser open mesh so interior (non-boundary) edges are available for
    // collapse.  facetedSubdivide turns 6 quads → 24 quads (26 verts); triangulate
    // → 48 tris; removing the last tri opens a 3-edge boundary → 47 tris, 3 boundary
    // verts, 23 interior verts with many collapsible interior edges between them.
    Mesh m = makeCube();
    {
        bool[] allF; allF.length = m.faces.length; allF[] = true;
        m = facetedSubdivide(m, allF);   // 26 verts, 24 quads; buildLoops already called
    }
    {
        auto triMask = new bool[](m.faces.length); triMask[] = true;
        m.triangulateFacesByMask(triMask);   // 48 tris
    }
    // Remove the last triangle to open the mesh.
    {
        uint[][] newFaces;
        foreach (fi; 0 .. m.faces.length - 1) newFaces ~= m.faces[fi].dup;
        m.faces = FaceList.init;
        foreach (f; newFaces) m.addFace(f);
        m.buildLoops();
    }
    assert(m.faces.length == 47, "expected 47 tris after removing one from 48");

    // Capture boundary vertex positions before reduce.
    Vec3[] bpos;
    {
        bool[] isBV; isBV.length = m.vertices.length;
        foreach (uint ei; 0 .. cast(uint)m.edges.length) {
            uint va = m.edges[ei][0], vb = m.edges[ei][1];
            // Task 0447: EdgeFaceRange's constructor now needs the fan-order
            // state + CSR — go through the public accessor instead of building
            // the range by hand (its private members aren't reachable here).
            int cnt = 0; foreach (_; m.facesAroundEdge(ei)) ++cnt;
            if (cnt < 2) { isBV[va] = true; isBV[vb] = true; }
        }
        foreach (vi, b; isBV) if (b) bpos ~= m.vertices[vi];
    }
    assert(bpos.length > 0, "open mesh must have boundary verts");

    // Reduce; the dense interior gives plenty of collapsible non-boundary edges.
    size_t n = m.reduceToTarget(40, true);
    assert(n > 0, "expected >0 interior collapses on denser mesh; got 0 -- "
                ~ "preserveBoundary guard may be over-rejecting or fixture is degenerate");

    // Every original boundary position must still exist in the post-reduce mesh.
    foreach (bp; bpos) {
        bool found = false;
        foreach (vp; m.vertices) {
            float dx = vp.x - bp.x, dy = vp.y - bp.y, dz = vp.z - bp.z;
            if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-5f) { found = true; break; }
        }
        assert(found, "boundary position (" ~ bp.x.to!string ~ ","
                    ~ bp.y.to!string ~ "," ~ bp.z.to!string ~ ") lost after reduce");
    }

    // Structural sanity.
    assert(m.faces.length <= 47, "face count must not increase");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length >= 3, "degenerate face after reduce");
}
