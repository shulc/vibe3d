// The pure half of the retopology base-dot cull (`retopology_dot_cull`): which
// vertex-VBO slots `visibleDots` keeps, and when its cache key goes stale.
//
// The pixels are the suite test `tests/test_retopology_lines_dots.d`; these
// cells name what pixels cannot: the exact SLOT values (the compacted index
// space), the facing rule under non-uniform scale / mirror / perspective, the
// normal it must share with the face buffer, and each key term.
module tests.unit.retopology_dot_cull_test;

import std.format : format;
import std.math : cos, sin, PI, sqrt;

import math : Vec3;
import mesh : Mesh;
import retopology_dot_cull : CullEye, cullEyeOf, DotCullKey, DotList, visibleDots;

private enum float kS10 = cast(float) sin(10.0 * PI / 180.0);
private enum float kC10 = cast(float) cos(10.0 * PI / 180.0);

// The rig, vertex by vertex (index: role):
//   0      isolated, visible         — kept (no voting polygon)
//   1      isolated, HIDDEN          — no VBO slot: every later slot is index-1
//   2..5   A, a +Z quad              — front
//   6..8   F, a reversed quad sharing vertex 3 with A — back; 3 stays (any
//          front polygon keeps a vertex), 6..8 are culled
//   9..12  Q, oblique, normal (cos10, 0, -sin10) — back for the +Z orthographic
//          eye, front for a perspective eye at (0,0,10)
//   13..16 N, non-planar: its first-three-corner normal faces +Z, its Newell
//          normal faces -Z — kept only under the face buffer's normal
//   17..20 H, a reversed quad, HIDDEN — does not vote, so its corners stay
//   21..24 D, a reversed quad whose first three corners are collinear —
//          degenerate, does not vote, so its corners stay
private Mesh rig() {
    Mesh m;
    Vec3[] v = [Vec3(9, 9, 0), Vec3(9, 8, 0),
                Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                Vec3(2, 0, 0), Vec3(2, -1, 0), Vec3(1, -1, 0)];
    // Q: in-plane axes u = (s10, 0, c10), w = (0, 1, 0), centred at (-3,0,0).
    immutable float h = 0.5f;
    immutable float[2][4] uv = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
    foreach (k; 0 .. 4)
        v ~= Vec3(-3.0f + uv[k][0] * h * kS10, uv[k][1] * h, uv[k][0] * h * kC10);
    v ~= [Vec3(0, 3, 0), Vec3(1, 3, 0), Vec3(1, 4, 0), Vec3(3, 3.5f, 0.3f)];
    v ~= [Vec3(5, 5, 0), Vec3(6, 5, 0), Vec3(6, 6, 0), Vec3(5, 6, 0)];
    v ~= [Vec3(5, 0, 0), Vec3(6, 0, 0), Vec3(7, 0, 0), Vec3(6, -1, 0)];
    m.vertices = v;
    m.addFace([2u, 3u, 4u, 5u]);        // A  (face 0)
    m.addFace([3u, 6u, 7u, 8u]);        // F  (face 1), clockwise from +Z
    m.addFace([12u, 11u, 10u, 9u]);     // Q  (face 2), reversed
    m.addFace([13u, 14u, 15u, 16u]);    // N  (face 3)
    m.addFace([20u, 19u, 18u, 17u]);    // H  (face 4), reversed, hidden below
    m.addFace([21u, 22u, 23u, 24u]);    // D  (face 5): 21, 22, 23 collinear
    m.vertexMarks.length = m.vertices.length;
    m.faceMarks.length = m.faces.length;
    m.vertexMarks[1] |= Mesh.Marks.Hide;
    m.faceMarks[4]   |= Mesh.Marks.Hide;
    assert(m.vertices.length == 25 && m.faces.length == 6, "rig population");
    return m;
}

private float[16] diag(float x, float y, float z) {
    return [x, 0, 0, 0,  0, y, 0, 0,  0, 0, z, 0,  0, 0, 0, 1];
}

private CullEye orthoEye(Vec3 toViewer) {
    return CullEye(true, toViewer, Vec3(0, 0, 0));
}

// Slot of vertex `vi` (>= 2): one hidden vertex below it.
private uint slotOf(uint vi) { return vi == 0 ? 0 : vi - 1; }

private uint[] slots(uint[] verts) {
    uint[] o;
    foreach (vi; verts) o ~= slotOf(vi);
    return o;
}

// Kept under the +Z orthographic eye: 0, A, N, H, D — not F's 6..8, not Q.
private immutable uint[] kOrthoKept =
    [0, 2, 3, 4, 5, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24];

private void expect(DotList got, const uint[] keptVerts, string cell) {
    auto want = slots(keptVerts.dup);
    assert(got.slotCount == 24, format("%s: slotCount %s, expected 24 "
        ~ "(25 vertices, one hidden)", cell, got.slotCount));
    assert(got.slots == want, format("%s: slots %s, expected %s", cell,
                                     got.slots, want));
}

unittest { // 1. orthographic +Z: exact slot values, population floor
    auto m = rig();
    auto M = diag(1, 1, 1);
    auto d = visibleDots(m, m.vertices, M, orthoEye(Vec3(0, 0, 1)));
    assert(d.slots.length == 17, format("1 floor: %s kept", d.slots.length));
    expect(d, kOrthoKept, "1 ortho");
}

unittest { // 2. perspective eye at (0,0,10): Q turns to face the eye
    auto m = rig();
    auto M = diag(1, 1, 1);
    auto d = visibleDots(m, m.vertices, M,
                         CullEye(false, Vec3(0, 0, 0), Vec3(0, 0, 10)));
    expect(d, [0, 2, 3, 4, 5, 9, 10, 11, 12, 13, 14, 15, 16,
               17, 18, 19, 20, 21, 22, 23, 24], "2 perspective");
}

unittest { // 3. mirrored item (scl.x = -1): the same polygons face away
    // The fill flips its GL front face for a mirrored model (`FacePass.
    // mirrored`), so it culls the same polygons as unmirrored; the dots agree.
    auto m = rig();
    auto M = diag(-1, 1, 1);
    expect(visibleDots(m, m.vertices, M, orthoEye(Vec3(0, 0, 1))),
           kOrthoKept, "3 mirrored");
}

unittest { // 4. non-uniform scale, oblique eye: the TRANSFORMED corners decide
    // M = diag(10, 1, 1), eye toward (1, 0, 1)/sqrt2. Q's true normal
    // M^-T n = (c10/10, 0, -s10) faces away (0.098 - 0.174 < 0); a local
    // normal carried by M, (10 c10, 0, -s10), would face the eye.
    auto m = rig();
    auto M = diag(10, 1, 1);
    immutable float r = cast(float)(1.0 / sqrt(2.0));
    expect(visibleDots(m, m.vertices, M, orthoEye(Vec3(r, 0, r))),
           kOrthoKept, "4 non-uniform scale");
}

unittest { // 5. a tiny uniform scale: degeneracy is judged on LOCAL corners
    // At 1e-4 every transformed cross product is ~1e-8, under the 1e-6
    // threshold; judged there, no polygon would vote and F would stay.
    auto m = rig();
    auto M = diag(1e-4f, 1e-4f, 1e-4f);
    expect(visibleDots(m, m.vertices, M, orthoEye(Vec3(0, 0, 1))),
           kOrthoKept, "5 tiny scale");
}

unittest { // 6. the drawn positions are the ones given, not mesh.vertices
    // Swap A's first two corners and move F's second, in `vpos` only; the
    // mesh's own positions would give cell 1's answer.
    auto m = rig();
    auto M = diag(1, 1, 1);
    Vec3[] vpos = m.vertices.dup;
    vpos[3] = Vec3(0, 0, 0); vpos[2] = Vec3(1, 0, 0);   // swap A's first two
    vpos[6] = Vec3(0, -1, 0);                           // keep F non-degenerate
    auto d = visibleDots(m, vpos, M, orthoEye(Vec3(0, 0, 1)));
    // A = [2,3,4,5] at (1,0),(0,0),(1,1),(0,1): first three (1,0),(0,0),(1,1)
    // wind clockwise from +Z -> back. F = [3,6,7,8] at (0,0),(0,-1),(2,-1),
    // (1,-1): first three (0,0),(0,-1),(2,-1) wind counter-clockwise -> front.
    expect(d, [0, 3, 6, 7, 8, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24],
           "6 drawn positions");
}

unittest { // 7. cullEyeOf reads the view's +Z row and the projection kind
    float[16] view = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, -5, 1];
    float[16] ortho = diag(1, 1, 1);
    auto e = cullEyeOf(view, ortho, Vec3(0, 0, 5));
    assert(e.ortho && e.toViewer == Vec3(0, 0, 1), format("7 ortho: %s", e));
    // A camera on +X looking down -X: eye-space +Z is world +X.
    float[16] side = [0, 0, 1, 0,  0, 1, 0, 0,  -1, 0, 0, 0,  0, 0, -5, 1];
    float[16] persp = diag(1, 1, 1);
    persp[15] = 0; persp[11] = -1;
    auto p = cullEyeOf(side, persp, Vec3(5, 0, 0));
    assert(!p.ortho && p.toViewer == Vec3(1, 0, 0) && p.eye == Vec3(5, 0, 0),
        format("7 perspective: %s", p));
}

unittest { // 8. the key: each term moves it, and only when it changes
    auto m = rig();
    m.buildLoops();
    float[16] view = diag(1, 1, 1), proj = diag(1, 1, 1), M = diag(1, 1, 1);
    DotCullKey k;
    assert(!k.matches(m, 7, view, proj, M), "8: a fresh key matches nothing");
    k.stamp(m, 7, view, proj, M);
    assert(k.matches(m, 7, view, proj, M), "8: a stamped key must match");
    assert(!k.matches(m, 8, view, proj, M), "8: the display epoch is a term");
    float[16] view2 = view; view2[12] = 1;
    assert(!k.matches(m, 7, view2, proj, M), "8: the camera is a term");
    float[16] M2 = M; M2[0] = -1;
    assert(!k.matches(m, 7, view, proj, M2), "8: the model matrix is a term");
    Mesh other = rig();
    assert(!k.matches(other, 7, view, proj, M), "8: the mesh address is a term");

    // A face delete that keeps the edge list: the FACE-set counter moves, the
    // edge-set counter does not (mesh.d's `MeshTopoKey` cell).
    immutable ulong sv = m.structVersion, tv = m.topologyVersion;
    bool[] mask = new bool[](m.faces.length);
    mask[1] = true;
    assert(m.deleteFacesByMask(mask, true, true) == 1, "8: F was not deleted");
    assert(m.structVersion == sv && m.topologyVersion != tv,
        format("8 premise: structVersion %s -> %s, topologyVersion %s -> %s",
               sv, m.structVersion, tv, m.topologyVersion));
    assert(!k.matches(m, 7, view, proj, M),
        "8: a face delete that keeps every edge must invalidate the list");
}
