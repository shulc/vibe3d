// THE FACING PREDICATE — the test that SEPARATES the rule we adopted from the
// two we rejected (task 0832).
//
// `math.frontFacingLocal` is the one home of "is this face turned away from the
// eye". Before it there were three implementations of three DIFFERENT rules
// (audit 4 §P1), and the rule that won is the reference editor's, read under a
// debugger at its own compute site (task 0726) and adopted for parity:
//
//     N = cross(v1 - v0, v[n-1] - v0)      corner triangle at the FIRST ring
//                                          vertex, third point is the LAST
//     cull  iff  dot(N, v0 - eye) > 0      strictly, against a literal 0
//
// The two rules it replaced are computed here too, in this file's own
// arithmetic, and every fixture below asserts BOTH the answer and the fact
// that at least one rejected rule would answer differently. A facing test that
// stays green when you substitute another normal has separated nothing.
//
// WHY NOT A CUBE. On a closed solid every back-facing face is also occluded, so
// all three rules agree on every face and a fixture built on one proves
// nothing — CLAUDE.md says so, and `cubeProvesNothing` below asserts it rather
// than leaving it as prose. The fixtures that DO separate the rules are open
// faces: the shape an edge split leaves (a quad whose bottom edge gained a
// midpoint), a concave pentagon, and a folded quad — each viewed from a stated
// side, and in the split case from BOTH sides, because "visible from both
// sides" is the visible consequence of the zero normal this rule produces.
module tests.unit.facing_predicate_test;

import std.format : format;
import std.math : PI;

import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
              frontFacingLocal;
import mesh : Mesh, makeCube, visibleVertices;

// ---------------------------------------------------------------------------
// The three candidate rules, spelled out here so the assertions can name them.
// All three share the ADOPTED comparison (`> 0` culls) so that what a fixture
// separates is the NORMAL and nothing else. (The comparison itself moved from
// `>= 0` to `> 0` with the rule; `zeroNormalIsKeptFromBothSides` below is where
// that boundary is pinned.)
// ---------------------------------------------------------------------------

private double[3] cross3(Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
    const double ux = cast(double)b.x - a.x, uy = cast(double)b.y - a.y,
                 uz = cast(double)b.z - a.z;
    const double wx = cast(double)d.x - c.x, wy = cast(double)d.y - c.y,
                 wz = cast(double)d.z - c.z;
    return [uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx];
}

/// The ADOPTED normal: the corner triangle at ring[0], closed with the LAST
/// ring entry.
private double[3] cornerNormal(const(Vec3)[] vs, const(uint)[] ring) {
    return cross3(vs[ring[0]], vs[ring[1]], vs[ring[0]], vs[ring[$ - 1]]);
}

/// REJECTED rule 1 — the first triangle of the vertex list (what
/// `Mesh.visibleVertices` and `snap.d`'s `faceVisible` each used to build).
private double[3] firstTriNormal(const(Vec3)[] vs, const(uint)[] ring) {
    return cross3(vs[ring[0]], vs[ring[1]], vs[ring[0]], vs[ring[2]]);
}

/// REJECTED rule 2 — Newell over the whole ring (`Mesh.faceNormal`, what the
/// lasso used to pass in). Area-weighted, order-independent, strictly more
/// robust than the rule we adopted — and not what the reference does.
private double[3] newellNormal(const(Vec3)[] vs, const(uint)[] ring) {
    double nx = 0, ny = 0, nz = 0;
    foreach (i; 0 .. ring.length) {
        const Vec3 a = vs[ring[i]];
        const Vec3 b = vs[ring[(i + 1) % ring.length]];
        nx += (cast(double)a.y - b.y) * (cast(double)a.z + b.z);
        ny += (cast(double)a.z - b.z) * (cast(double)a.x + b.x);
        nz += (cast(double)a.x - b.x) * (cast(double)a.y + b.y);
    }
    return [nx, ny, nz];
}

private bool frontBy(double[3] n, const(Vec3)[] vs, const(uint)[] ring, Vec3 eye) {
    const Vec3 v0 = vs[ring[0]];
    const double d = n[0] * (cast(double)v0.x - eye.x)
                   + n[1] * (cast(double)v0.y - eye.y)
                   + n[2] * (cast(double)v0.z - eye.z);
    return !(d > 0.0);
}

private bool frontByFirstTri(const(Vec3)[] vs, const(uint)[] ring, Vec3 eye) {
    return frontBy(firstTriNormal(vs, ring), vs, ring, eye);
}

private bool frontByNewell(const(Vec3)[] vs, const(uint)[] ring, Vec3 eye) {
    return frontBy(newellNormal(vs, ring), vs, ring, eye);
}

private string why(const(Vec3)[] vs, const(uint)[] ring, Vec3 eye) {
    auto c = cornerNormal(vs, ring), t = firstTriNormal(vs, ring),
         n = newellNormal(vs, ring);
    return format("\n    ring=%s eye=(%g,%g,%g)"
        ~ "\n    corner  N=(%.6g,%.6g,%.6g) front=%s   <- the adopted rule"
        ~ "\n    firsttri N=(%.6g,%.6g,%.6g) front=%s"
        ~ "\n    newell   N=(%.6g,%.6g,%.6g) front=%s",
        ring, eye.x, eye.y, eye.z,
        c[0], c[1], c[2], frontBy(c, vs, ring, eye),
        t[0], t[1], t[2], frontByFirstTri(vs, ring, eye),
        n[0], n[1], n[2], frontByNewell(vs, ring, eye));
}

private enum Vec3 EYE_FRONT = Vec3(0, 0, 10);    // on +Z, looking down -Z
private enum Vec3 EYE_BACK  = Vec3(0, 0, -10);   // on -Z, looking down +Z

// The shape an edge split leaves: the unit quad's bottom edge gained a
// midpoint (vertex 1), so that midpoint is collinear with its two ring
// neighbours. Wound CCW seen from +Z. `midAt` ROTATES the ring without
// changing the polygon at all — it only says at which ring index the inserted
// midpoint lands, which is the whole of what this rule is sensitive to:
//   midAt == 0 -> the corner triangle at ring[0] spans the two collinear
//                 neighbours, so the ADOPTED normal is exactly zero;
//   midAt == 1 -> v0,v1,v2 are collinear, so the FIRST-TRIANGLE normal is
//                 exactly zero instead.
private void splitQuad(size_t midAt, out Vec3[] verts, out uint[] ring) {
    verts = [Vec3(-1, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0),
             Vec3(1, 1, 0), Vec3(-1, 1, 0)];
    const size_t start = (1 + 5 - midAt) % 5;   // vertex 1 is the midpoint
    ring = new uint[](5);
    foreach (i; 0 .. 5) ring[i] = cast(uint)((i + start) % 5);
}

// A PLANAR concave pentagon. Its true surface normal is unambiguously +Z; the
// reflex corner is the vertex at (0.5, 0.4, 0). `start` rotates the ring.
private void reflexPentagon(size_t start, out Vec3[] verts, out uint[] ring) {
    verts = [Vec3(0, 0, 0), Vec3(0.5f, 0.4f, 0), Vec3(1, 0, 0),
             Vec3(1, 1, 0), Vec3(0, 1, 0)];
    ring = new uint[](5);
    foreach (i; 0 .. 5) ring[i] = cast(uint)((i + start) % 5);
}

unittest { // control: a flat square, where all three rules agree by construction
    Vec3[] vs = [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)];
    uint[] ccw = [0, 1, 2, 3];
    uint[] cw  = [3, 2, 1, 0];

    assert(frontFacingLocal(vs, ccw, EYE_FRONT), "CCW square faces an eye on +Z"
        ~ why(vs, ccw, EYE_FRONT));
    assert(!frontFacingLocal(vs, ccw, EYE_BACK), "...and is culled from behind"
        ~ why(vs, ccw, EYE_BACK));
    assert(!frontFacingLocal(vs, cw, EYE_FRONT), "reversed winding is culled"
        ~ why(vs, cw, EYE_FRONT));

    // This fixture is a CONTROL precisely because it cannot separate anything:
    // all three rules agree on it, from both sides.
    foreach (ring; [ccw, cw])
        foreach (eye; [EYE_FRONT, EYE_BACK]) {
            const bool got = frontFacingLocal(vs, ring, eye);
            assert(got == frontByFirstTri(vs, ring, eye)
                && got == frontByNewell(vs, ring, eye),
                "a convex, uniformly-wound quad must NOT separate the rules —"
                ~ " if it does, this fixture drifted" ~ why(vs, ring, eye));
        }
}

unittest { // cubeProvesNothing — why every existing facing fixture is inert
    // On a closed solid a back-facing face is also occluded, so all three
    // candidate rules agree on every face from any eye. This is asserted, not
    // assumed: it is the reason `tests/test_toolpipe_snap.d`'s `occludedSnap`
    // cases pass with the facing term deleted outright, and the reason the
    // fixtures below had to be OPEN faces.
    auto cube = makeCube();
    foreach (eye; [EYE_FRONT, EYE_BACK, Vec3(7, 5, 3), Vec3(-4, -9, 2)])
        foreach (fi, ref face; cube.faces) {
            const bool got = frontFacingLocal(cube.vertices, face, eye);
            assert(got == frontByFirstTri(cube.vertices, face, eye)
                && got == frontByNewell(cube.vertices, face, eye),
                format("cube face %d: on a closed solid the three rules agree,"
                    ~ " which is why a cube fixture separates nothing", fi)
                ~ why(cube.vertices, face, eye));
        }
}

unittest { // zeroNormalIsKeptFromBothSides — THE consequence of the adopted rule
    // Midpoint at ring index 0: its two ring neighbours are the two ends of the
    // split edge, collinear with it, so the corner normal is EXACTLY the zero
    // vector. `dot(0, anything) > 0` is false, so the polygon is never culled —
    // it is front-facing from BOTH sides. That is the bill task 0832 accepted,
    // and it is visible behaviour: this polygon can be lassoed from behind.
    Vec3[] vs; uint[] ring;
    splitQuad(/*midAt=*/0, vs, ring);

    auto n = cornerNormal(vs, ring);
    assert(n[0] == 0.0 && n[1] == 0.0 && n[2] == 0.0,
        "fixture: the corner normal must be EXACTLY zero here (the arithmetic"
        ~ " is carried in double so a truly collinear corner cancels exactly)"
        ~ why(vs, ring, EYE_FRONT));

    assert(frontFacingLocal(vs, ring, EYE_FRONT),
        "a zero-normal polygon is never culled" ~ why(vs, ring, EYE_FRONT));
    assert(frontFacingLocal(vs, ring, EYE_BACK),
        "...from EITHER side — this is the strict `> 0` comparison, and it is"
        ~ " the whole of the `N == 0 is never culled` clause"
        ~ why(vs, ring, EYE_BACK));

    // SEPARATION. From behind, both rejected rules cull this face. If either
    // of these ever equals the adopted answer, the normal was substituted.
    assert(!frontByFirstTri(vs, ring, EYE_BACK),
        "fixture drifted: the first-triangle rule must CULL here"
        ~ why(vs, ring, EYE_BACK));
    assert(!frontByNewell(vs, ring, EYE_BACK),
        "fixture drifted: Newell must CULL here" ~ why(vs, ring, EYE_BACK));
    assert(frontFacingLocal(vs, ring, EYE_BACK) != frontByFirstTri(vs, ring, EYE_BACK)
        && frontFacingLocal(vs, ring, EYE_BACK) != frontByNewell(vs, ring, EYE_BACK),
        "the adopted rule must DISAGREE with both rejected rules here —"
        ~ " if it agrees, `frontFacingLocal` is no longer building the corner"
        ~ " triangle at ring[0] with the LAST ring entry"
        ~ why(vs, ring, EYE_BACK));
}

unittest { // the SAME polygon, rotated: the split shape with the midpoint at 1
    // This is the rotation the capture called out: v0,v1,v2 are collinear, so
    // the FIRST-TRIANGLE rule degenerates to the zero vector and keeps the face
    // from both sides, while the adopted rule and Newell both cull it from
    // behind. It separates the rejected first-triangle rule in the opposite
    // direction from the case above — one fixture cannot catch both.
    Vec3[] vs; uint[] ring;
    splitQuad(/*midAt=*/1, vs, ring);

    auto t = firstTriNormal(vs, ring);
    assert(t[0] == 0.0 && t[1] == 0.0 && t[2] == 0.0,
        "fixture: v0,v1,v2 must be collinear for this rotation"
        ~ why(vs, ring, EYE_FRONT));

    assert(frontFacingLocal(vs, ring, EYE_FRONT),
        "the adopted rule sees a real +Z corner here" ~ why(vs, ring, EYE_FRONT));
    assert(!frontFacingLocal(vs, ring, EYE_BACK),
        "...and culls it from behind" ~ why(vs, ring, EYE_BACK));
    assert(frontByFirstTri(vs, ring, EYE_BACK),
        "fixture drifted: the first-triangle rule must KEEP it from behind"
        ~ why(vs, ring, EYE_BACK));
    assert(frontFacingLocal(vs, ring, EYE_BACK) != frontByFirstTri(vs, ring, EYE_BACK),
        "substituting the first triangle for the corner triangle must change"
        ~ " this answer" ~ why(vs, ring, EYE_BACK));

    // Rotating a ring is not supposed to move a polygon. Under this rule it
    // moves the ANSWER: at start=0 the same five vertices are front-facing from
    // behind, at start=1 they are not.
    Vec3[] vs0; uint[] ring0;
    splitQuad(/*midAt=*/0, vs0, ring0);
    assert(frontFacingLocal(vs0, ring0, EYE_BACK)
        != frontFacingLocal(vs, ring, EYE_BACK),
        "ring order changes the answer for one and the same polygon — that is"
        ~ " the accepted bill, pinned so nobody reads it as a bug");
}

unittest { // reflexIsAnsweredBackwards — the 180° item on the bill
    // A PLANAR concave pentagon: its surface truth is unambiguously +Z, and
    // Newell says +Z. Start the ring at the REFLEX corner and the corner
    // triangle is wound the other way, so the adopted rule reports the polygon
    // as facing -Z: culled from the front, selectable from behind.
    Vec3[] vs; uint[] ring;
    reflexPentagon(/*start=*/1, vs, ring);   // ring[0] == the reflex vertex

    assert(!frontFacingLocal(vs, ring, EYE_FRONT),
        "a planar polygon whose ring starts at a reflex corner is culled from"
        ~ " the side it actually faces — the accepted 180° error"
        ~ why(vs, ring, EYE_FRONT));
    assert(frontFacingLocal(vs, ring, EYE_BACK),
        "...and kept from the side it does not face" ~ why(vs, ring, EYE_BACK));

    // SEPARATION, in the opposite direction from the zero-normal case: here the
    // adopted rule CULLS what both rejected rules keep.
    assert(frontByFirstTri(vs, ring, EYE_FRONT) && frontByNewell(vs, ring, EYE_FRONT),
        "fixture drifted: both rejected rules must KEEP this face from the front"
        ~ why(vs, ring, EYE_FRONT));

    // Start the same polygon one vertex earlier and the reflex corner is no
    // longer ring[0]; the adopted rule then agrees with the surface again.
    Vec3[] vs2; uint[] ring2;
    reflexPentagon(/*start=*/0, vs2, ring2);
    assert(frontFacingLocal(vs2, ring2, EYE_FRONT),
        "with the reflex corner off ring[0] the same polygon faces +Z again"
        ~ why(vs2, ring2, EYE_FRONT));
}

unittest { // a non-planar quad: four rotations, and they do not agree
    // The folded quad from the capture's case table. Four rotations of ONE
    // polygon, one eye: the adopted rule answers differently depending only on
    // where the ring starts. Newell (area-weighted over the whole ring) is the
    // same for all four by construction — that is exactly the robustness the
    // owner traded away for parity.
    Vec3[] vs = [Vec3(0, 0, 0), Vec3(0.5f, -0.2f, 0), Vec3(1, 0, 0),
                 Vec3(0.5f, -1.0f, 0.9f)];
    bool[4] got;
    foreach (start; 0 .. 4) {
        uint[] ring = new uint[](4);
        foreach (i; 0 .. 4) ring[i] = cast(uint)((i + start) % 4);
        got[start] = frontFacingLocal(vs, ring, EYE_FRONT);
        assert(frontByNewell(vs, ring, EYE_FRONT) == frontByNewell(vs, [0u,1u,2u,3u], EYE_FRONT),
            "fixture: Newell is order-independent, so it cannot be what makes"
            ~ " the answers below differ" ~ why(vs, ring, EYE_FRONT));
    }
    assert(got[0] != got[1],
        format("rotating the ring of one polygon changes the adopted rule's"
            ~ " answer (start=0 -> %s, start=1 -> %s). Pinned as accepted"
            ~ " behaviour, not as a bug.", got[0], got[1]));
}

unittest { // a ring shorter than three vertices is not a face
    // Live, not defensive: `snap.d`'s `faceVisible` deleted its own
    // `face.length < 3` guard and relies on this answer.
    Vec3[] vs = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)];
    assert(!frontFacingLocal(vs, [0u, 1u], EYE_FRONT),
        "a two-vertex ring has no facing and must answer false");
    assert(!frontFacingLocal(vs, [], EYE_FRONT),
        "an empty ring has no facing and must answer false");
}

// ---------------------------------------------------------------------------
// SITE LEVEL — the predicate is not only correct in isolation, it is what
// `Mesh.visibleVertices` (snap's vertex/edge mask, and its only consumer) now
// asks. These two cases are the same two fixtures as above, and they flip in
// opposite directions, so a substituted normal cannot satisfy both.
// ---------------------------------------------------------------------------

private Viewport viewportAt(Vec3 eye) {
    Viewport vp;
    vp.eye    = eye;
    vp.focus  = Vec3(0, 0, 0);
    vp.view   = lookAt(vp.eye, vp.focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f, 0.1f, 5000.0f);
    vp.width  = 800;
    vp.height = 600;
    return vp;
}

unittest { // visibleVertices keeps a zero-normal face from BEHIND
    Vec3[] vs; uint[] ring;
    splitQuad(/*midAt=*/0, vs, ring);
    Mesh m;
    m.vertices = vs;
    m.addFace(ring);
    m.buildLoops();

    auto vp = viewportAt(EYE_BACK);
    auto vis = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. vs.length)
        assert(vis[vi],
            format("v%d: a zero-normal polygon is not culled from either side,"
                ~ " so snap still offers its vertices from behind. Under either"
                ~ " rejected normal this face is back-facing here and every"
                ~ " vertex would be false.", vi) ~ why(vs, ring, EYE_BACK));
}

unittest { // visibleVertices culls a reflex-first face from the FRONT
    Vec3[] vs; uint[] ring;
    reflexPentagon(/*start=*/1, vs, ring);
    Mesh m;
    m.vertices = vs;
    m.addFace(ring);
    m.buildLoops();

    auto vp = viewportAt(EYE_FRONT);
    auto vis = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    foreach (vi; 0 .. vs.length)
        assert(!vis[vi],
            format("v%d: the ring starts at the reflex corner, so the adopted"
                ~ " rule reports this planar polygon as turned away and snap"
                ~ " offers nothing. Both rejected normals would keep it.", vi)
            ~ why(vs, ring, EYE_FRONT));
}
