// Module unittests for `deform_magnet`, moved verbatim out of source/deform_magnet.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.deform_magnet_test;

import mesh : Mesh;
import math : Vec3, Viewport, AimViewport, aimSpace, ModelSpace;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket;
import deform_magnet;

// ---------------------------------------------------------------------------
// Module unittest — validates the convergent field property and the
// anchorRing / sphere-distance logic against the makeCube geometry.
//
// Setup: anchor = vertex 6 (0.5, 0.5, 0.5), dist = 1.2, strength = 1.0,
//        target = (0.5, 0.5, 1.5) — directly above v6 in Z.
//
// Distances from v6:
//   v0: √3 ≈ 1.73 (outside sphere, unmoved)
//   v1: √2 ≈ 1.41 (outside sphere, unmoved)
//   v2:  1.0      (inside: t=5/6, Smooth weight=2/27≈0.074, moved in Z only)
//   v3: √2 ≈ 1.41 (outside sphere, unmoved)
//   v4: √2 ≈ 1.41 (outside sphere, unmoved)
//   v5:  1.0      (inside: t=5/6, Smooth weight=2/27, moved in Y AND Z)
//   v6:  0        (anchorRing → weight=1, lands exactly on target)
//   v7:  1.0      (inside: t=5/6, Smooth weight=2/27, moved in X AND Z)
//
// Convergent-field proof:
//   v6 moved along direction (0, 0, 1)
//   v5 moved along direction (0, 1, 1) — differs ↑ proves convergent not parallel
//   v7 moved along direction (1, 0, 1) — differs ↑ proves convergent not parallel
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import toolpipe.packets : FalloffType, FalloffShape, ElementConnect;
    import std.math : abs;

    Mesh m = makeCube();

    const Vec3  anchorPos = Vec3(0.5f, 0.5f, 0.5f);  // v6
    const Vec3  target    = Vec3(0.5f, 0.5f, 1.5f);
    const float dist      = 1.2f;

    FalloffPacket fp;
    fp.type         = FalloffType.Element;
    fp.enabled      = true;
    fp.pickedCenter = anchorPos;
    fp.pickedRadius = dist;
    fp.connect      = ElementConnect.Ignore;
    fp.shape        = FalloffShape.Smooth;
    fp.anchorPos    = [anchorPos];   // distance measured from here
    fp.anchorRing   = [6u];          // vertex 6 → weight=1 (anchorRing short-circuit)

    int[] allIdx;
    foreach (i; 0 .. cast(int)m.vertices.length)
        allIdx ~= i;

    uint[] tidx;
    Vec3[] tprev;
    // Element falloff never projects; identity is the honest aim here, and
    // `ModelSpace.world()` is only reachable from a unittest.
    Viewport vpW;
    auto aim = aimSpace(vpW, ModelSpace.world());
    bool changed = applyMagnet(&m, allIdx, target, 1.0f, fp, aim, tidx, tprev);

    assert(changed, "applyMagnet should displace at least one vertex");

    // v6 has weight=1 via anchorRing → lands exactly on target.
    assert(abs(m.vertices[6].x - 0.5f) < 1e-4f, "v6.x unchanged");
    assert(abs(m.vertices[6].y - 0.5f) < 1e-4f, "v6.y unchanged");
    assert(abs(m.vertices[6].z - 1.5f) < 1e-4f, "v6 should land on target.z=1.5");

    // v5 = (0.5, -0.5, 0.5): pulled toward (0.5, 0.5, 1.5).
    // Convergent proof: y increases (target.y=0.5 > v5.y=-0.5)
    //                   z increases (target.z=1.5 > v5.z=0.5)
    //                   x UNCHANGED (target.x=v5.x=0.5 → delta_x=0)
    // This direction (0,+,+) differs from v6's direction (0,0,+) → proves convergent.
    assert(m.vertices[5].y > -0.5f + 1e-3f,
           "v5 y must increase toward target.y (convergent y-component)");
    assert(m.vertices[5].z > 0.5f  + 1e-3f,
           "v5 z must increase toward target.z (convergent z-component)");
    assert(abs(m.vertices[5].x - 0.5f) < 1e-4f,
           "v5 x unchanged (delta_x=0 since target.x=v5.x)");

    // v7 = (-0.5, 0.5, 0.5): pulled toward (0.5, 0.5, 1.5).
    // Convergent proof: x increases (target.x=0.5 > v7.x=-0.5)
    //                   z increases (target.z=1.5 > v7.z=0.5)
    //                   y UNCHANGED (target.y=v7.y=0.5)
    // Direction (+,0,+) differs from v6's (0,0,+) → proves convergent.
    assert(m.vertices[7].x > -0.5f + 1e-3f,
           "v7 x must increase toward target.x (convergent x-component)");
    assert(m.vertices[7].z > 0.5f  + 1e-3f,
           "v7 z must increase toward target.z");
    assert(abs(m.vertices[7].y - 0.5f) < 1e-4f,
           "v7 y unchanged");

    // v2 = (0.5, 0.5, -0.5): pulled toward (0.5, 0.5, 1.5) — only z changes.
    assert(m.vertices[2].z > -0.5f + 1e-3f,
           "v2 z must increase toward target.z");
    assert(abs(m.vertices[2].x - 0.5f) < 1e-4f, "v2 x unchanged");
    assert(abs(m.vertices[2].y - 0.5f) < 1e-4f, "v2 y unchanged");

    // Out-of-sphere verts (d ≥ √2 > 1.2): unmoved.
    // v0=(-0.5,-0.5,-0.5)d=√3, v1=(0.5,-0.5,-0.5)d=√2,
    // v3=(-0.5,0.5,-0.5)d=√2,  v4=(-0.5,-0.5,0.5)d=√2.
    static immutable float[3][4] origOut = [
        [-0.5f, -0.5f, -0.5f],  // v0
        [ 0.5f, -0.5f, -0.5f],  // v1
        [-0.5f,  0.5f, -0.5f],  // v3
        [-0.5f, -0.5f,  0.5f],  // v4
    ];
    static immutable int[4] outIdx = [0, 1, 3, 4];
    foreach (k; 0 .. 4) {
        int vi = outIdx[k];
        assert(abs(m.vertices[vi].x - origOut[k][0]) < 1e-5f,
               "out-of-sphere vert x unmoved");
        assert(abs(m.vertices[vi].y - origOut[k][1]) < 1e-5f,
               "out-of-sphere vert y unmoved");
        assert(abs(m.vertices[vi].z - origOut[k][2]) < 1e-5f,
               "out-of-sphere vert z unmoved");
    }

    // Undo arrays are consistent.
    assert(tidx.length  > 0,
           "touchedIdx should be non-empty");
    assert(tprev.length == tidx.length,
           "touchedPrev.length matches touchedIdx.length");
}
