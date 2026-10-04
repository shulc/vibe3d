// Literal expected meshes for the pen's one stroke builder
// (`tools.create.pen_geometry.appendPenGeometry`). Wave plan S1 (task 9356):
// each case names its stroke, purpose and the exact vertices / faces / edges
// the builder must append. DRUNTIME STOPS A MODULE AT ITS FIRST FAILING
// ASSERT — score mutations one at a time.
module tests.unit.tools.create.pen_geometry_test;

import std.format : format;

import math : Vec3;
import mesh : Mesh;
import prepared_tool_effect : PreparedPenParamKind;
import tools.create.pen_geometry;

// Composition pins: a field added to the stroke or a kind added to the
// prepared param enum must be added here, with its cases.
static assert([__traits(allMembers, PenStroke)] ==
    ["points", "toWorld", "flip", "quads", "of"]);
static assert([__traits(allMembers, PenBuildPurpose)] == ["Preview", "Commit"]);
static assert([__traits(allMembers, PreparedPenParamKind)] ==
    ["None", "Noop", "CurrentPoint", "Position", "Preview"]);
static assert([__traits(allMembers, PenParams)] ==
    ["type", "currentPoint", "posX", "posY", "posZ", "flip", "makeQuads"]);
static assert(PenParams.sizeof == 24);

private enum float[16] kIdentity = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
// Column-major translation by (10, 20, 30) — transformPoint's layout.
private enum float[16] kShift = [1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1];

private immutable Vec3[] kTri  = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
private immutable Vec3[] kPent = [Vec3(0,0,0), Vec3(2,0,0), Vec3(3,1,0),
                                  Vec3(1,2,0), Vec3(-1,1,0)];
private immutable Vec3[] kStrip6 = [Vec3(0,0,0), Vec3(0,1,0), Vec3(1,0,0),
                                    Vec3(1,1,0), Vec3(2,0,0), Vec3(2,1,0)];

private struct Case {
    string         name;
    const(Vec3)[]  points;
    float[16]      toWorld;
    bool           flip, quads;
    PenBuildPurpose purpose;
    size_t         baseVerts;      // vertices already in dst
    Vec3[]         expectVerts;    // appended, world
    uint[][]       expectFaces;
    uint[2][]      expectEdges;    // wire edges, as pairs
}

private Case[] cases() {
    with (PenBuildPurpose) return [
        Case("triangle Commit", kTri, kIdentity, false, false, Commit, 0,
            kTri.dup, [[0u, 1, 2]], []),
        Case("triangle Commit flip", kTri, kIdentity, true, false, Commit, 0,
            kTri.dup, [[2u, 1, 0]], []),
        Case("pentagon Commit", kPent, kIdentity, false, false, Commit, 0,
            kPent.dup, [[0u, 1, 2, 3, 4]], []),
        Case("pentagon Commit flip", kPent, kIdentity, true, false, Commit, 0,
            kPent.dup, [[4u, 3, 2, 1, 0]], []),
        Case("triangle Preview flip", kTri, kIdentity, true, false, Preview, 0,
            kTri.dup, [[0u, 1, 2]], []),
        Case("pentagon Preview flip", kPent, kIdentity, true, false, Preview, 0,
            kPent.dup, [[0u, 1, 2, 3, 4]], []),
        Case("2-point Commit", kTri[0 .. 2], kIdentity, false, false, Commit, 0,
            kTri[0 .. 2].dup, [[0u, 1]], []),
        Case("2-point Preview", kTri[0 .. 2], kIdentity, false, false, Preview,
            0, kTri[0 .. 2].dup, [], [[0u, 1]]),
        Case("3-point Preview polyline", kTri, kIdentity, false, true, Preview,
            0, kTri.dup, [], [[0u, 1], [1u, 2]]),
        Case("1-point Preview", kTri[0 .. 1], kIdentity, false, false, Preview,
            0, kTri[0 .. 1].dup, [], []),
        Case("quads 4 Commit", kStrip6[0 .. 4], kIdentity, false, true, Commit,
            0, kStrip6[0 .. 4].dup, [[0u, 2, 3, 1]], []),
        Case("quads 6 Commit flip", kStrip6, kIdentity, true, true, Commit, 0,
            kStrip6.dup, [[1u, 3, 2, 0], [3u, 5, 4, 2]], []),
        Case("quads 5 Commit", kStrip6[0 .. 5], kIdentity, false, true, Commit,
            0, kStrip6[0 .. 5].dup, [[0u, 2, 3, 1]], []),
        Case("triangle Commit translated", kTri, kShift, false, false, Commit, 0,
            [Vec3(10,20,30), Vec3(11,20,30), Vec3(10,21,30)], [[0u, 1, 2]], []),
        Case("triangle Commit onto 2 vertices", kTri, kIdentity, true, false,
            Commit, 2, kTri.dup, [[4u, 3, 2]], []),
    ];
}

unittest // every case appends exactly its literal mesh
{
    const all = cases();
    // FLOOR: the case table. Plan §9.1 said 9; measured 15 (the plan's own
    // list enumerates more than 9, plus a 1-point and a non-empty-dst cell).
    assert(all.length == 15, format("case table has %s rows, pinned 15", all.length));
    size_t ran;
    foreach (c; all) {
        Mesh m;
        foreach (i; 0 .. c.baseVerts) m.addVertex(Vec3(-5, -5, cast(float)i));
        PenParams p; p.flip = c.flip; p.makeQuads = c.quads;
        const first = appendPenGeometry(m, PenStroke.of(c.points, c.toWorld, p),
            c.purpose);
        assert(first == c.baseVerts, format("%s: first new vertex %s, expected %s",
            c.name, first, c.baseVerts));
        assert(m.vertices[c.baseVerts .. $] == c.expectVerts,
            format("%s: vertices %s, expected %s", c.name,
                m.vertices[c.baseVerts .. $], c.expectVerts));
        assert(m.faces == c.expectFaces, format("%s: faces %s, expected %s",
            c.name, m.faces, c.expectFaces));
        uint[2][] wires;
        foreach (e; m.edges)
            if (edgeIsWire(m, e[0], e[1])) wires ~= [e[0], e[1]];
        assert(wires == c.expectEdges, format("%s: wire edges %s, expected %s",
            c.name, wires, c.expectEdges));
        ++ran;
    }
    assert(ran == 15, "not every case ran");
}

private bool edgeIsWire(ref Mesh m, uint a, uint b) {
    foreach (f; m.faces)
        foreach (i; 0 .. f.length)
            if ((f[i] == a && f[(i + 1) % f.length] == b) ||
                (f[i] == b && f[(i + 1) % f.length] == a)) return false;
    return true;
}
