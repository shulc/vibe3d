module vibe3d.mesh.ops.tests.unit.mesh_ops.face_merge_test;
import vibe3d.mesh.ops.mesh_ops.triangulate : triangulateFacesByMask;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math;
import vibe3d.mesh.contracts.mesh_scope : MeshEditScope;
import vibe3d.mesh.ops.mesh_ops.face_merge;

// Public legacy cells moved from tests/unit/mesh_test.d (task 20262350).
// The caller batch replaces the original core chooser receiver; its scope
// matches the operation and closes before any existing assertion reads state.
private auto faceOpOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry | MeshEditScope.Marks);
    const result = kernel(ed, args);
    ed.close();
    return result;
}

unittest { // quadrupleFacesByMask: triple → quadruple round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    triangulateFacesByMask(m, allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = faceOpOnce!quadrupleFacesByMask(m, allF2);
    assert(dissolved == 6,
        "quadruple: expected 6 edges dissolved (one diagonal per cube face), got "
        ~ dissolved.to!string);
    assert(m.faces.length == 6,  "quadruple: expected 6 faces");
    assert(m.vertices.length == 8, "quadruple: expected 8 verts");
    assert(m.edges.length == 12,   "quadruple: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "quadruple: face " ~ fi.to!string ~ " is not a quad");
}

unittest { // quadrupleFacesByMask: planarity — every result quad is flat
    import std.conv : to;
    import vibe3d.util.math.math : dot;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    triangulateFacesByMask(m, allF);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    faceOpOnce!quadrupleFacesByMask(m, allF2);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4);
        // Split quad [a,b,c,d] into tris (a,b,c) and (a,c,d).
        auto f  = m.faces[fi];
        Vec3 pa = m.vertices[f[0]], pb = m.vertices[f[1]],
             pc = m.vertices[f[2]], pd = m.vertices[f[3]];
        import vibe3d.util.math.math : cross, normalize;
        import std.math : sqrt;
        Vec3 n1 = normalize(cross(pb - pa, pc - pa));
        Vec3 n2 = normalize(cross(pc - pa, pd - pa));
        float d = dot(n1, n2);
        assert(d > 0.999f,
            "quadruple planarity: face " ~ fi.to!string
            ~ " bent-quad dot=" ~ d.to!string);
    }
}

unittest { // detriangulateFacesByMask: triple → detriangulate round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    triangulateFacesByMask(m, allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = faceOpOnce!detriangulateFacesByMask(m, allF2);
    assert(dissolved == 6,
        "detriangulate: expected 6 edges dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 6,   "detriangulate: expected 6 faces");
    assert(m.vertices.length == 8,"detriangulate: expected 8 verts");
    assert(m.edges.length == 12,  "detriangulate: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "detriangulate: face " ~ fi.to!string ~ " not a quad");
}

unittest { // detriangulateFacesByMask: partial mask — only masked faces merge
    // Mask only 2 tris (children of cube face 0) → 1 merge; other tris untouched.
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    uint[] faceOrigin;
    triangulateFacesByMask(m, allF, &faceOrigin);  // 12 tris
    // Find the 2 children of original face 0.
    bool[] partMask = new bool[](m.faces.length);
    foreach (fi; 0 .. faceOrigin.length)
        if (faceOrigin[fi] == 0) partMask[fi] = true;
    faceOpOnce!detriangulateFacesByMask(m, partMask);
    // 1 merge: 12 - 2 + 1 = 11 faces.
    assert(m.faces.length == 11,
        "detriangulate partial: expected 11 faces, got " ~ m.faces.length.to!string);
}

unittest { // mergeFacesByMask: 2-quad strip → 1 six-corner n-gon; non-adjacent → no-op
    import std.algorithm : sort;
    import std.conv      : to;

    // Build a flat 2×1 quad grid:
    //   verts: 0=(0,0,0) 1=(1,0,0) 2=(2,0,0)
    //          3=(0,0,1) 4=(1,0,1) 5=(2,0,1)
    //   face 0 = [0,1,4,3], face 1 = [1,2,5,4]  (shared edge 1–4)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(2,0,1));
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.buildLoops();

    // Merge both faces — 1 interior edge (1–4) dissolved.
    bool[] mask = [true, true];
    size_t dissolved = faceOpOnce!mergeFacesByMask(m, mask);
    assert(dissolved == 1, "expected 1 edge dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 1, "expected 1 merged face");

    // The combined boundary has 6 corners (collinear midpoints 1 and 4 survive
    // — v1 restriction: removeEdgesByMask does not dissolve 2-valent verts).
    uint[] corners = m.faces[0].dup;
    assert(corners.length == 6,
           "merged face must have 6 corners (incl. collinear midpoints)");

    // Corner index SET must equal {0,1,2,3,4,5} — all verts lie on the boundary.
    sort(corners);
    assert(corners == [0u,1u,2u,3u,4u,5u],
           "merged face must reference all 6 verts");

    // Non-adjacent mask (only face 0): no shared interior edges → 0 dissolved.
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0)); m2.addVertex(Vec3(2,0,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1)); m2.addVertex(Vec3(2,0,1));
    m2.addFace([0u,1u,4u,3u]);
    m2.addFace([1u,2u,5u,4u]);
    m2.buildLoops();
    assert(faceOpOnce!mergeFacesByMask(m2, [true, false]) == 0,
           "single-face mask must dissolve nothing");
    assert(m2.faces.length == 2, "face count unchanged on no-op");
}
