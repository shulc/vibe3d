// Module unittests for `tools.alignment.align_kernels`, moved verbatim out of source/tools/alignment/align_kernels.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.alignment.align_kernels_test;

import mesh     : Mesh;
import editmode : EditMode;
import math     : Vec3, dot, cross;
import std.math : sqrt, cos, sin, PI, abs;
import std.algorithm : sort;
import tools.alignment.align_kernels;
import falloff  : weightedLerp;

unittest { // Linear Align — chain interpolation law, BIT-EXACT verified
           // against the "la_nonuniform" / "la_uniform" capture cases.
           // 4-vertex open chain on a unit cube (corners
           // A=(-.5,-.5,-.5), B=(.5,-.5,-.5) pre-displaced by
           // (-0.3,+0.35,+0.4), C=(.5,-.5,.5), D=(.5,.5,.5)); endpoints
           // A/D never move.
    Vec3[] source = [
        Vec3(-0.5f, -0.5f, -0.5f),   // A (endpoint)
        Vec3( 0.2f, -0.15f, -0.1f),  // B (interior, displaced)
        Vec3( 0.5f, -0.5f,  0.5f),   // C (interior)
        Vec3( 0.5f,  0.5f,  0.5f),   // D (endpoint)
    ];

    auto nonUniform = linearAlignTargets(source, false);
    assert(nonUniform.length == 4);
    assert(abs(nonUniform[0].x - (-0.5f)) < 1e-5f && abs(nonUniform[0].y - (-0.5f)) < 1e-5f
        && abs(nonUniform[0].z - (-0.5f)) < 1e-5f, "endpoint A must not move");
    assert(abs(nonUniform[3].x - 0.5f) < 1e-5f && abs(nonUniform[3].y - 0.5f) < 1e-5f
        && abs(nonUniform[3].z - 0.5f) < 1e-5f, "endpoint D must not move");
    // t = dot(B-A, D-A)/|D-A|^2 = 1.45/3 = 0.483333...
    enum float nb = -0.0166667f;
    assert(abs(nonUniform[1].x - nb) < 1e-4f && abs(nonUniform[1].y - nb) < 1e-4f
        && abs(nonUniform[1].z - nb) < 1e-4f, "nonuniform B mismatch");
    // t = dot(C-A, D-A)/|D-A|^2 = 2.0/3 = 0.666667... (C wasn't displaced,
    // so its natural index-spacing t and its own-projection t coincide —
    // captured note: a stock cube can't discriminate uniform vs
    // nonuniform for an un-displaced orthogonal-step vertex).
    enum float nc = 0.1666667f;
    assert(abs(nonUniform[2].x - nc) < 1e-4f && abs(nonUniform[2].y - nc) < 1e-4f
        && abs(nonUniform[2].z - nc) < 1e-4f, "nonuniform C mismatch");

    auto uniform = linearAlignTargets(source, true);
    // t = index/(n-1): B at 1/3, C at 2/3.
    enum float ub = -0.1666667f;
    assert(abs(uniform[1].x - ub) < 1e-4f && abs(uniform[1].y - ub) < 1e-4f
        && abs(uniform[1].z - ub) < 1e-4f, "uniform B mismatch");
    assert(abs(uniform[2].x - nc) < 1e-4f && abs(uniform[2].y - nc) < 1e-4f
        && abs(uniform[2].z - nc) < 1e-4f, "uniform C mismatch (matches nonuniform for undisplaced C)");
    assert(abs(uniform[0].x - (-0.5f)) < 1e-5f, "uniform endpoint A must not move");
    assert(abs(uniform[3].x - 0.5f) < 1e-5f, "uniform endpoint D must not move");
}

unittest { // Linear Align — weight blend, BIT-EXACT verified against
           // the "la_weight05" capture case (nonuniform + weight=0.5).
    Vec3[] source = [
        Vec3(-0.5f, -0.5f, -0.5f),
        Vec3( 0.2f, -0.15f, -0.1f),
        Vec3( 0.5f, -0.5f,  0.5f),
        Vec3( 0.5f,  0.5f,  0.5f),
    ];
    auto aligned = linearAlignTargets(source, false);
    Vec3 b05 = weightedLerp(source[1], aligned[1], 0.5f);
    Vec3 c05 = weightedLerp(source[2], aligned[2], 0.5f);
    assert(abs(b05.x - 0.0916667f) < 1e-4f && abs(b05.y - (-0.0833333f)) < 1e-4f
        && abs(b05.z - (-0.0583333f)) < 1e-4f, "weight=0.5 B mismatch");
    assert(abs(c05.x - 0.3333333f) < 1e-4f && abs(c05.y - (-0.1666667f)) < 1e-4f
        && abs(c05.z - 0.3333333f) < 1e-4f, "weight=0.5 C mismatch");
}

unittest { // Linear Align — degenerate 2-vertex chain is a no-op (both
           // verts are endpoints; t=0/1 exactly regardless of mode).
    Vec3[] source = [Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f)];
    foreach (uniform; [false, true]) {
        auto r = linearAlignTargets(source, uniform);
        assert(abs(r[0].x - source[0].x) < 1e-6f && abs(r[0].y - source[0].y) < 1e-6f);
        assert(abs(r[1].x - source[1].x) < 1e-6f && abs(r[1].y - source[1].y) < 1e-6f);
    }
}

unittest { // Radial Align — center/radius auto-compute law, BIT-EXACT
           // verified against the "ra_circle" capture case (measured
           // center=(0.051777,-0.5,0.125), radius=0.688103). Closed
           // 4-vertex loop on the y=-0.5 cube
           // face (A=(-.5,-.5,-.5), B=(.5,-.5,-.5) pre-displaced within
           // the same plane by (0.2071,0,0.5), C=(.5,-.5,.5),
           // E=(-.5,-.5,.5)).
           //
           // The BASE ANCHOR (which point sits at angle 0) is NOT
           // verified against the reference — see radialAlignTargets's
           // doc comment — so beyond center/radius this only checks the
           // anchor-INDEPENDENT structural properties: equal slot
           // spacing and the additive-angle cyclic-permutation law (also
           // measured bit-exact in ra_circle_angle90.json).
    Vec3[] source = [
        Vec3(-0.5f,     -0.5f, -0.5f),
        Vec3( 0.7071f,  -0.5f,  0.0f),
        Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f),
    ];

    Vec3 center = Vec3(0, 0, 0);
    foreach (p; source) center = center + p;
    center = center * 0.25f;
    assert(abs(center.x - 0.051777f) < 2e-3f, "center.x mismatch");
    assert(abs(center.y - (-0.5f))   < 1e-6f, "center.y mismatch");
    assert(abs(center.z - 0.125f)    < 1e-6f, "center.z mismatch");

    auto result = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    assert(result.length == 4);
    foreach (p; result) {
        Vec3 d = p - center;
        float r = sqrt(dot(d, d));
        assert(abs(r - 0.688103f) < 2e-3f, "radius mismatch");
    }
    // Equal 90-degree slot spacing (measured: all 4 consecutive edge
    // lengths equal R*sqrt(2), a regular inscribed square).
    immutable float expectedEdge = 0.688103f * sqrt(2.0f);
    foreach (i; 0 .. 4) {
        Vec3 a = result[i], b = result[(i + 1) % 4];
        Vec3 d = b - a;
        float edgeLen = sqrt(dot(d, d));
        assert(abs(edgeLen - expectedEdge) < 2e-3f, "slot spacing mismatch");
    }

    // angle=90 (== 360/4, exactly one slot step) is a pure additive
    // rotation — measured bit-exact as a cyclic permutation of the
    // angle=0 result. Verified here against OUR OWN angle=0 result (the
    // absolute base-anchor value is unverified, but this additive
    // property is guaranteed by construction for any anchor choice).
    auto result90 = radialAlignTargets(source, false, 4, 90.0f, 0.0f);
    foreach (i; 0 .. 4) {
        Vec3 a = result90[i], b = result[(i + 1) % 4];
        assert(abs(a.x - b.x) < 1e-3f && abs(a.y - b.y) < 1e-3f && abs(a.z - b.z) < 1e-3f,
               "angle=90 should cyclically permute the angle=0 result");
    }
}

unittest { // Radial Align — N-Sided(4) uses the SAME center + radius as
           // Circle mode for an identical input (bit-exact match measured
           // in ra_nside4.json vs ra_circle.json) — anchor-independent
           // structural fact.
    Vec3[] source = [
        Vec3(-0.5f,     -0.5f, -0.5f),
        Vec3( 0.7071f,  -0.5f,  0.0f),
        Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f),
    ];
    auto circle = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    auto nside4 = radialAlignTargets(source, true, 4, 0.0f, 0.0f);
    assert(circle.length == nside4.length);
    // Same radius from the same (shared) center for every point.
    Vec3 center = Vec3(0, 0, 0);
    foreach (p; source) center = center + p;
    center = center * 0.25f;
    foreach (i; 0 .. circle.length) {
        float rc = sqrt(dot(circle[i] - center, circle[i] - center));
        float rn = sqrt(dot(nside4[i] - center, nside4[i] - center));
        assert(abs(rc - rn) < 1e-5f, "circle vs nside4 radius should match");
    }
}

unittest { // Radial Align — weight blend uses the same lerp law as
           // Linear Align (measured bit-exact in ra_circle_weight05.json
           // against ra_circle.json).
    Vec3 source = Vec3(0.7071f, -0.5f, 0.0f);
    Vec3 aligned = Vec3(1.0f, -0.5f, 1.0f);
    Vec3 h = weightedLerp(source, aligned, 0.5f);
    assert(abs(h.x - 0.85355f) < 1e-4f);
    assert(abs(h.y - (-0.5f))  < 1e-6f);
    assert(abs(h.z - 0.5f)     < 1e-6f);
}

unittest { // Radial Align — degenerate single-vertex "chain" is a no-op
           // (no circle can be defined from one point).
    Vec3[] source = [Vec3(1, 2, 3)];
    auto r = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    assert(r.length == 1);
    assert(abs(r[0].x - 1.0f) < 1e-6f && abs(r[0].y - 2.0f) < 1e-6f && abs(r[0].z - 3.0f) < 1e-6f);
}

unittest { // Radial Align — `side`/effSides DoS clamp: an absurd `sides`
           // value must not divide-by-zero or hang, and clamps to
           // MAX_ALIGN_SIDES rather than propagating unbounded.
    Vec3[] source = [
        Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(-1, 0, 0), Vec3(0, -1, 0),
    ];
    auto r1 = radialAlignTargets(source, true, 2_000_000_000, 0.0f, 0.0f);
    assert(r1.length == 4);
    foreach (p; r1) {
        assert(p.x == p.x && p.y == p.y && p.z == p.z, "NaN in clamped-sides result"); // NaN check
    }
    auto r2 = radialAlignTargets(source, true, -5, 0.0f, 0.0f);
    assert(r2.length == 4);
    foreach (p; r2) {
        assert(p.x == p.x && p.y == p.y && p.z == p.z, "NaN in negative-sides result");
    }
}

// Task 9490 — the ring PHASE against three captured cells (private
// toolcards: shared_layer2 K-F `KF_F2cal`; xfrm.radialAlign `ra_circle`,
// `ra_nside4`). Chains are in selection order, the order the reference
// walked them in both rigs. Values are the captured float positions.
private void assertCell(const(Vec3)[] got, const(float[3])[] want, string cell) {
    import std.format : format;
    assert(got.length == want.length && want.length == 4, cell ~ ": population");
    foreach (i, w; want)
        assert(abs(got[i].x - w[0]) < 2e-6f && abs(got[i].y - w[1]) < 2e-6f
               && abs(got[i].z - w[2]) < 2e-6f,
            format("%s v%s: got (%.7f, %.7f, %.7f), captured (%.7f, %.7f, %.7f)",
                   cell, i, got[i].x, got[i].y, got[i].z, w[0], w[1], w[2]));
}

private Vec3[] raRig() {
    import std.math : SQRT1_2;
    return [Vec3(-0.5f, -0.5f, -0.5f), Vec3(cast(float)SQRT1_2, -0.5f, 0.0f),
            Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, -0.5f, 0.5f)];
}

// The cube's top corner above each chain vertex: its one outside neighbour.
private Vec3[][] raOutside() {
    return [[Vec3(-0.5f, 0.5f, -0.5f)], [Vec3(0.5f, 0.5f, -0.5f)],
            [Vec3(0.5f, 0.5f, 0.5f)], [Vec3(-0.5f, 0.5f, 0.5f)]];
}

unittest { // no outside neighbour: the start vertex keeps its own angle
    Vec3[] source = [Vec3(-0.5f, -0.5f, 0), Vec3(0.5f, -0.5f, 0),
                     Vec3(0.6f, 0.5f, 0), Vec3(-0.3f, 0.4f, 0)];
    Vec3[][] none = [[], [], [], []];
    assertCell(radialAlignTargets(source, false, 4, 0, 0, none),
        [[-0.429725f, -0.470346f, 0], [0.520346f, -0.529725f, 0],
         [0.579725f, 0.420346f, 0], [-0.370346f, 0.479725f, 0]], "KF_F2cal");
}

unittest { // circle: start vertex + the turn search against the outside neighbours
    assertCell(radialAlignTargets(raRig(), false, 4, 0, 0, raOutside()),
        [[-0.4420957f, -0.5f, -0.3541404f], [0.5309171f, -0.5f, -0.3688723f],
         [0.5456491f, -0.5f, 0.6041404f], [-0.4273637f, -0.5f, 0.6188723f]], "ra_circle");
}

unittest { // N-Sided: the same start vertex at its own angle, no search
    assertCell(radialAlignTargets(raRig(), true, 4, 0, 0, raOutside()),
        [[-0.3350036f, -0.5f, -0.4441102f], [0.6208869f, -0.5f, -0.2617803f],
         [0.438557f, -0.5f, 0.6941102f], [-0.5173336f, -0.5f, 0.5117803f]], "ra_nside4");
}

unittest { // control that must flip: without the outside neighbours the circle
           // ring stays where N-Sided put it — the search is what moves it
    auto still = radialAlignTargets(raRig(), false, 4, 0, 0);
    auto nside = radialAlignTargets(raRig(), true, 4, 0, 0);
    auto turned = radialAlignTargets(raRig(), false, 4, 0, 0, raOutside());
    foreach (i; 0 .. 4) assert(abs(still[i].x - nside[i].x) < 1e-6f && abs(still[i].z - nside[i].z) < 1e-6f);
    assert(abs(turned[0].x - still[0].x) > 0.05f, "the search must turn the ring");
}
