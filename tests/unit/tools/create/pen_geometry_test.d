// Literal expected meshes for the pen's one stroke builder
// (`tools.create.pen_geometry.appendPenGeometry`). Wave plan S1 (task 9356):
// each case names its stroke, purpose and the exact vertices / faces / edges
// the builder must append. DRUNTIME STOPS A MODULE AT ITS FIRST FAILING
// ASSERT — score mutations one at a time.
module tests.unit.tools.create.pen_geometry_test;

import std.format : format;

import math : Vec3, Viewport, cross, dot, eyeVectorAt;
import mesh : Mesh;
import prepared_tool_effect : PreparedPenParamKind;
import tools.create.pen_geometry;

// Composition pins: a field added to the stroke or a kind added to the
// prepared param enum must be added here, with its cases.
static assert([__traits(allMembers, PenStroke)] ==
    ["points", "links", "toWorld", "flip", "quads", "of"]);
static assert([__traits(allMembers, PenBuildPurpose)] == ["Preview", "Commit"]);
static assert([__traits(allMembers, PreparedPenParamKind)] ==
    ["None", "Noop", "CurrentPoint", "Position", "Preview"]);
static assert([__traits(allMembers, PenParams)] ==
    ["type", "currentPoint", "posX", "posY", "posZ", "flip", "makeQuads", "merge"]);
static assert(PenParams.sizeof == 24);

private enum float[16] kIdentity = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
// Column-major translation by (10, 20, 30) — transformPoint's layout.
private enum float[16] kShift = [1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1];

private immutable Vec3[] kTri  = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
private immutable Vec3[] kPent = [Vec3(0,0,0), Vec3(2,0,0), Vec3(3,1,0),
                                  Vec3(1,2,0), Vec3(-1,1,0)];
private immutable Vec3[] kStrip6 = [Vec3(0,0,0), Vec3(0,1,0), Vec3(1,0,0),
                                    Vec3(1,1,0), Vec3(2,0,0), Vec3(2,1,0)];

unittest // Make Quads facing: under the decided flip every quad faces the eye
{
    // FIRST block of the module: druntime stops at the first failed assert,
    // so the facing law reddens here before the literal table below. A
    // clockwise and a counter-clockwise (seen from the top) 6-point strip
    // on y = 1: two quads each. Both purposes must face the top view's eye
    // (normal . eye ray < 0), as the reference's strips always do (K-C2).
    auto top = orthoLooking(-1);
    auto ccw = onY1([-0.5f, -0.25f], [-0.5f, 0.25f], [0f, -0.25f], [0f, 0.25f],
                    [0.5f, -0.25f], [0.5f, 0.25f]);
    Vec3[] cw;
    foreach (p; ccw) cw ~= Vec3(p.x, p.y, -p.z);
    size_t quads;
    foreach (name, pts; ["ccw": ccw, "cw": cw]) {
        PenParams p; p.makeQuads = true;
        p.flip = penFacingFlip(pts[0], pts[1], pts[2], top);
        assert(p.flip == (name == "cw"), name ~ ": premise, flip decision");
        foreach (purpose; [PenBuildPurpose.Preview, PenBuildPurpose.Commit]) {
            Mesh m;
            appendPenGeometry(m, PenStroke.of(pts, kIdentity, p), purpose);
            assert(m.faces.length == 2, format("%s %s: %s faces", name, purpose,
                m.faces.length));
            foreach (f; m.faces) {
                Vec3 n = Vec3(0, 0, 0), c = Vec3(0, 0, 0);
                foreach (i; 0 .. f.length) {
                    n = n + cross(m.vertices[f[i]], m.vertices[f[(i + 1) % $]]);
                    c = c + m.vertices[f[i]];
                }
                c = c * (1.0f / f.length);
                assert(dot(n, eyeVectorAt(top, c)) < 0, format("%s %s: quad %s "
                    ~ "faces away (normal %s)", name, purpose, f, n));
                ++quads;
            }
        }
    }
    assert(quads == 8, format("checked %s quads, pinned 8", quads));
}

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
            kTri.dup, [[0u, 2, 1]], []),
        Case("pentagon Commit", kPent, kIdentity, false, false, Commit, 0,
            kPent.dup, [[1u, 2, 3, 4, 0]], []),
        Case("pentagon Commit flip", kPent, kIdentity, true, false, Commit, 0,
            kPent.dup, [[1u, 0, 4, 3, 2]], []),
        Case("triangle Preview flip", kTri, kIdentity, true, false, Preview, 0,
            kTri.dup, [[0u, 2, 1]], []),
        Case("pentagon Preview flip", kPent, kIdentity, true, false, Preview, 0,
            kPent.dup, [[1u, 0, 4, 3, 2]], []),
        Case("2-point Commit", kTri[0 .. 2], kIdentity, false, false, Commit, 0,
            kTri[0 .. 2].dup, [[0u, 1]], []),
        Case("2-point Preview", kTri[0 .. 2], kIdentity, false, false, Preview,
            0, kTri[0 .. 2].dup, [], [[0u, 1]]),
        Case("3-point Preview polyline", kTri, kIdentity, false, true, Preview,
            0, kTri.dup, [], [[0u, 1], [1u, 2]]),
        Case("1-point Preview", kTri[0 .. 1], kIdentity, false, false, Preview,
            0, kTri[0 .. 1].dup, [], []),
        Case("quads 4 Commit", kStrip6[0 .. 4], kIdentity, false, true, Commit,
            0, kStrip6[0 .. 4].dup, [[1u, 3, 2, 0]], []),
        Case("quads 6 Commit flip", kStrip6, kIdentity, true, true, Commit, 0,
            kStrip6.dup, [[0u, 2, 3, 1], [2u, 4, 5, 3]], []),
        Case("quads 6 Preview flip", kStrip6, kIdentity, true, true, Preview, 0,
            kStrip6.dup, [[0u, 2, 3, 1], [2u, 4, 5, 3]], []),
        Case("quads 5 Commit", kStrip6[0 .. 5], kIdentity, false, true, Commit,
            0, kStrip6[0 .. 5].dup, [[1u, 3, 2, 0]], []),
        Case("triangle Commit translated", kTri, kShift, false, false, Commit, 0,
            [Vec3(10,20,30), Vec3(11,20,30), Vec3(10,21,30)], [[0u, 1, 2]], []),
        Case("triangle Commit onto 2 vertices", kTri, kIdentity, true, false,
            Commit, 2, kTri.dup, [[2u, 4, 3]], []),
    ];
}

unittest // every case appends exactly its literal mesh
{
    const all = cases();
    // FLOOR: the case table. Plan §9.1 said 9; measured 15 (the plan's own
    // list enumerates more than 9, plus a 1-point and a non-empty-dst cell);
    // S4 adds the flipped quads Preview (16).
    assert(all.length == 16, format("case table has %s rows, pinned 16", all.length));
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
    assert(ran == 16, "not every case ran");
}

private bool edgeIsWire(ref Mesh m, uint a, uint b) {
    foreach (f; m.faces)
        foreach (i; 0 .. f.length)
            if ((f[i] == a && f[(i + 1) % f.length] == b) ||
                (f[i] == b && f[(i + 1) % f.length] == a)) return false;
    return true;
}

// --- Ring order and facing (wave plan S4, task 9361) -----------------------
// Positions are the stored vertices of tests/fixtures/pen_facing.json (top
// view, plane y = 1); expected rings are the captured ones where the cell has
// one, else the plan's rule (§9.4) evaluated by the offline checker.

private Vec3[] onY1(float[2][] xz...) {
    Vec3[] r;
    foreach (p; xz) r ~= Vec3(p[0], 1, p[1]);
    return r;
}

private struct RingCase { string name; Vec3[] pts; bool reverse; uint[] ring; }

private RingCase[] ringCases() {
    auto n3  = onY1([0.74f, 0.105f], [-0.235f, 0.46f], [-0.055f, -0.565f]);
    auto n4  = onY1([0.74f, 0.105f], [0.045f, 0.59f], [-0.44f, -0.105f],
                    [0.255f, -0.59f]);
    auto n5  = onY1([0.74f, 0.105f], [0.235f, 0.595f], [-0.39f, 0.265f],
                    [-0.265f, -0.43f], [0.43f, -0.53f]);
    auto n6  = onY1([0.74f, 0.105f], [0.355f, 0.565f], [-0.235f, 0.46f],
                    [-0.44f, -0.105f], [-0.055f, -0.565f], [0.535f, -0.46f]);
    auto c4  = onY1([0.74f, 0.105f], [0.255f, -0.59f], [-0.44f, -0.105f],
                    [0.045f, 0.59f]);
    auto c5  = onY1([0.74f, 0.105f], [0.43f, -0.53f], [-0.265f, -0.43f],
                    [-0.39f, 0.265f], [0.235f, 0.595f]);
    auto rfx = onY1([-0.5f, 0.4f], [0.0f, 0.1f], [0.5f, 0.4f], [0.4f, -0.4f],
                    [-0.4f, -0.4f]);
    auto col = onY1([-0.3f, 0.2f], [0.0f, 0.2f], [0.3f, 0.2f], [0.0f, -0.4f]);
    auto dart = onY1([0.0f, -0.2f], [0.5f, -0.6f], [0.0f, 0.6f], [-0.5f, -0.6f]);
    // Corner 0 itself degenerate (v3, v0, v1 collinear).
    auto deg0 = onY1([0f, 0f], [1f, 0f], [1f, 1f], [-1f, 0f]);
    // Corners 1 and 0 degenerate: the left rotation lands on 1, backs off to
    // 0, then to 4 (two right steps).
    auto deg2 = onY1([0f, 0f], [1f, 0f], [2f, 0f], [1f, 1f], [-1f, 0f]);
    // Corners 1 and 2 disagree with corner 0, corner 3 (= n - 2, outside
    // [2, n - 3]) agrees: no rotation.
    auto lone3 = onY1([-1f, 0f], [0f, -2f], [2f, 2f], [0f, -1f], [-1f, -1f]);
    return [
        RingCase("n3 cw flip (A1-n3-cw)", n3, true, [0u, 2, 1]),
        RingCase("n3 unflipped", n3, false, [0u, 1, 2]),
        RingCase("n4 cw flip (A1-n4-cw)", n4, true, [1u, 0, 3, 2]),
        RingCase("n5 cw flip (A1-n5-cw)", n5, true, [1u, 0, 4, 3, 2]),
        RingCase("n6 cw flip (A1-n6-cw)", n6, true, [1u, 0, 5, 4, 3, 2]),
        RingCase("n4 ccw (A1-n4-ccw)", c4, false, [1u, 2, 3, 0]),
        RingCase("n5 ccw (A1-n5-ccw)", c5, false, [1u, 2, 3, 4, 0]),
        RingCase("n5 reflex at 1, flip (A1x-n5-reflex1)", rfx, true,
            [2u, 3, 4, 0, 1]),
        RingCase("n5 reflex at 1, unflipped", rfx, false, [2u, 1, 0, 4, 3]),
        RingCase("concave n4 flip (A2-dart)", dart, true, [0u, 1, 2, 3]),
        RingCase("concave n4 unflipped", dart, false, [0u, 3, 2, 1]),
        RingCase("degenerate corner reached by the rotation (A1x-n4-collinear)",
            col, false, [0u, 1, 2, 3]),
        RingCase("degenerate first corner", deg0, false, [1u, 2, 3, 0]),
        RingCase("two degenerate corners", deg2, false, [4u, 0, 1, 2, 3]),
        RingCase("two points", n3[0 .. 2], true, [0u, 1]),
        RingCase("n5 disagreeing, only corner 3 agrees: unrotated", lone3, false,
            [0u, 4, 3, 2, 1]),
    ];
}

unittest // penRingOrder: every case gives its literal ring
{
    const all = ringCases();
    assert(all.length == 16, format("ring table has %s rows, pinned 16", all.length));
    size_t ran;
    foreach (c; all) {
        const got = penRingOrder(c.pts, c.reverse);
        assert(got == c.ring, format("%s: ring %s, expected %s", c.name, got,
            c.ring));
        ++ran;
    }
    assert(ran == 16, "not every ring case ran");
}

// Ortho view whose forward vector (-view[2,6,10]) is (0, fy, 0).
private Viewport orthoLooking(float fy) {
    Viewport vp;
    vp.view = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    vp.view[2] = 0; vp.view[6] = -fy; vp.view[10] = 0;
    vp.proj = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];   // proj[15] != 0: ortho
    return vp;
}

unittest // penFacingFlip: the decision's triangle, eye ray and degeneracy
{
    auto top = orthoLooking(-1);          // the rig's top view: forward -Y
    // Must stay: an unflipped counter-clockwise first three (A1-n4-ccw).
    auto c4 = onY1([0.74f, 0.105f], [0.255f, -0.59f], [-0.44f, -0.105f]);
    assert(!penFacingFlip(c4[0], c4[1], c4[2], top), "ccw first three flipped");
    auto n3 = onY1([0.74f, 0.105f], [-0.235f, 0.46f], [-0.055f, -0.565f]);
    assert(penFacingFlip(n3[0], n3[1], n3[2], top), "A1-n3-cw: cw from the "
        ~ "top view must flip");
    auto dart = onY1([0.0f, -0.2f], [0.5f, -0.6f], [0.0f, 0.6f]);
    assert(penFacingFlip(dart[0], dart[1], dart[2], top), "A2-dart's first "
        ~ "three face away from the top view and must flip");

    // A3c: perspective, the eye straight above the focus; the triangle's
    // normal points along the camera forward (-Y) but TOWARD the eye ray at
    // p2. The eye ray decides (no flip); the forward axis would flip.
    Viewport persp = orthoLooking(-1);
    persp.proj[15] = 0;                   // perspective
    persp.eye = Vec3(0.07f, 3.857487f, 0);
    const Vec3 a0 = Vec3(-0.819475f, 1.567701f, 0.0f);
    const Vec3 a1 = Vec3(-0.844009f, 1.454287f, 0.273152f);
    const Vec3 a2 = Vec3(-0.852154f, 1.436215f, -0.27715f);
    assert(!penFacingFlip(a0, a1, a2, persp), "A3c: the per-point eye ray "
        ~ "must decide (no flip), not the camera forward axis");
    assert(penFacingFlip(a0, a2, a1, persp), "A3c-rev: the reversed triple "
        ~ "must flip");

    // Collinear first three never flip. Seen from BELOW (forward +Y) the
    // degenerate default normal (0,1,0) would read "away", so only this view
    // shows a dropped degeneracy guard (the top view masks it).
    auto col = onY1([-0.3f, 0.2f], [0.0f, 0.2f], [0.3f, 0.2f]);
    assert(!penFacingFlip(col[0], col[1], col[2], top), "collinear, top view");
    auto up = orthoLooking(1);
    assert(!penFacingFlip(col[0], col[1], col[2], up),
        "collinear first three flipped in a view looking up (+Y)");
}

unittest // Preview and Commit emit the same ring for a flipped pentagon
{
    PenParams p; p.flip = true;
    const s = PenStroke.of(kPent, kIdentity, p);
    Mesh preview, commit;
    appendPenGeometry(preview, s, PenBuildPurpose.Preview);
    appendPenGeometry(commit, s, PenBuildPurpose.Commit);
    assert(preview.faces.length == 1 && preview.faces == commit.faces,
        format("preview %s vs commit %s", preview.faces, commit.faces));
    assert(commit.faces == [[1u, 0, 4, 3, 2]], format("flipped pentagon ring %s",
        commit.faces));
}


unittest // a linked point (S5 merge) emits the shared index and appends no vertex
{
    PenParams p;
    const int[] link = [-1, 1, -1];
    Mesh m;
    foreach (i; 0 .. 2) m.addVertex(Vec3(-5, -5, cast(float)i));
    const first = appendPenGeometry(m, PenStroke.of(kTri, kIdentity, p, link),
        PenBuildPurpose.Commit);
    assert(first == 2 && m.vertices.length == 4, format("linked triangle: first %s, "
        ~ "%s vertices; expected 2, 4 (one shared)", first, m.vertices.length));
    assert(m.vertices[2 .. $] == [kTri[0], kTri[2]], format("linked triangle: "
        ~ "appended %s", m.vertices[2 .. $]));
    assert(m.faces == [[2u, 1, 3]], format("linked triangle: faces %s, expected "
        ~ "[[2, 1, 3]]", m.faces));

    // A 2-point commit with a link keeps its 2-vertex face.
    Mesh two;
    two.addVertex(Vec3(9, 9, 9));
    appendPenGeometry(two, PenStroke.of(kTri[0 .. 2], kIdentity, p, [0, -1]),
        PenBuildPurpose.Commit);
    assert(two.vertices.length == 2 && two.faces == [[0u, 1]], format("linked "
        ~ "2-point commit: %s vertices, faces %s", two.vertices.length, two.faces));

    // A strip quad uses the shared index at its corner.
    PenParams q; q.makeQuads = true;
    Mesh strip;
    strip.addVertex(Vec3(9, 9, 9));
    appendPenGeometry(strip, PenStroke.of(kStrip6[0 .. 4], kIdentity, q,
        [-1, -1, 0, -1]), PenBuildPurpose.Commit);
    assert(strip.vertices.length == 4 && strip.faces == [[2u, 3, 0, 1]], format(
        "linked strip: %s vertices, faces %s", strip.vertices.length, strip.faces));

    // Every point linking one vertex leaves fewer than 2 corners after the
    // repeat collapse: no face (ours; not captured — gap row).
    Mesh lone;
    lone.addVertex(Vec3(9, 9, 9));
    appendPenGeometry(lone, PenStroke.of(kTri[0 .. 2], kIdentity, p, [0, 0]),
        PenBuildPurpose.Commit);
    assert(lone.vertices.length == 1 && lone.faces.length == 0, format("all-repeat "
        ~ "commit: %s vertices, faces %s; expected 1, none", lone.vertices.length,
        lone.faces));

    // A stroke without links (the preview) appends every point.
    Mesh preview;
    appendPenGeometry(preview, PenStroke.of(kTri, kIdentity, p), PenBuildPurpose.Preview);
    assert(preview.vertices.length == 3, "a link-free stroke shared a vertex");
}
