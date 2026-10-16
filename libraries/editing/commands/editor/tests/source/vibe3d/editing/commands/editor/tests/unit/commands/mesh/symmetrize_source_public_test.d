module vibe3d.editing.commands.editor.tests.unit.commands.mesh.symmetrize_source_public_test;

import vibe3d.editing.commands.editor.commands.mesh.symmetrize;

import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.util.math.math   : Vec3;
import vibe3d.editing.params.params : Param;
import vibe3d.mesh.change.change_bus : MeshEditScope;
import vibe3d.editing.commands.editor.commands.mesh.position_undo : PositionUndo;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SymmetryPacket, SubjectPacket;
import vibe3d.editing.selection.query.symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;

// ---------------------------------------------------------------------------
// Module unittest — exercises the apply-mask reasoning (plan Risk 1) without
// an HTTP server.  Runs under `dub test --config=tests`.
// ---------------------------------------------------------------------------

// Two-quad mesh sharing a seam edge on X=0 — the same topology as the
// proven fixture in symmetry.d's unittests.  This is the minimal structure
// that gives rebuildPairingTopological enough connectivity to seed and expand.
//
// Vertex layout:
//   0: seam (0, 0, 0)
//   1: seam (0, 1, 0)
//   2: +X driver  (1 + driftX, 0.5, 0)
//   3: +X second  (1.5, 1.2, 0)
//   4: -X partner of v2 at exact spatial mirror (-1, 0.5, 0) or drifted far
//   5: -X partner of v3 (-1.5, 1.2, 0)
// Faces: [0,2,3,1] (+X quad), [0,1,5,4] (-X quad)
//
// With small drift (driftX ≤ epsilon): spatial pairing finds v4↔v2.
// With large drift (driftX >> epsilon): only topological pairing finds v4↔v2.

version(unittest) {
    import vibe3d.util.math.math : Vec3;
    import vibe3d.mesh.core.mesh : Mesh;
    import vibe3d.editing.selection.query.symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : SymmetryPacket;

    // Build the two-quad mesh with v2 drifted by driftX.  v4 stays at
    // its base position (-1, 0.5, 0) — the spatial mirror of undrifted v2.
    // When driftX is large, the spatial mirror of the DRIFTED v2 is far from
    // v4, so spatial pairing fails; topological succeeds via connectivity.
    private Mesh makeTwoQuadMesh(float driftX) {
        Mesh m;
        m.addVertex(Vec3( 0.0f,  0.0f, 0.0f));          // 0: seam
        m.addVertex(Vec3( 0.0f,  1.0f, 0.0f));          // 1: seam
        m.addVertex(Vec3( 1.0f + driftX, 0.5f, 0.0f));  // 2: +X driver
        m.addVertex(Vec3( 1.5f,  1.2f, 0.0f));          // 3: +X second
        m.addVertex(Vec3(-1.0f,  0.5f, 0.0f));          // 4: -X partner of v2
        m.addVertex(Vec3(-1.5f,  1.2f, 0.0f));          // 5: -X partner of v3
        m.addFace([0u, 2u, 3u, 1u]);    // +X quad
        m.addFace([0u, 1u, 5u, 4u]);    // -X quad
        m.buildLoops();
        return m;
    }

    private SymmetryPacket makeXPacket(float eps, int baseSide) {
        SymmetryPacket sp;
        sp.enabled      = true;
        sp.axisIndex    = 0;
        sp.offset       = 0.0f;
        sp.epsilonWorld = eps;
        sp.baseSide     = baseSide;
        sp.planeNormal  = Vec3(1, 0, 0);
        sp.planePoint   = Vec3(0, 0, 0);
        return sp;
    }
}

unittest {
    import std.math : abs;
    // Spatial pairing — driver side +1, small drift within epsilon.
    // Mirror of drifted v2=(1.05,0.5,0) = (-1.05,0.5,0).
    // v4 is at (-1.0,0.5,0), distance = 0.05 < eps=0.1 → paired.
    auto m  = makeTwoQuadMesh(0.05f);
    auto sp = makeXPacket(0.1f, +1);

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    assert(pairOf[2] == 4, "spatial: v2 should pair with v4");

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    // Driver (v2, +X side) must be unchanged.
    assert(m.vertices[2].x == pre[2].x && m.vertices[2].y == pre[2].y,
        "spatial: driver vert must be unchanged");

    // Partner (v4) must snap to mirror of drifted driver: (-1.05, 0.5, 0).
    assert(abs(m.vertices[4].x - (-1.05f)) < 1e-5f,
        "spatial: partner.x should be -1.05 (mirror of 1.05)");
    assert(abs(m.vertices[4].y - 0.5f) < 1e-5f,
        "spatial: partner.y should match driver.y = 0.5");
}

unittest {
    import std.math : abs;
    // Topological pairing — driver side +1, large drift (spatial would miss).
    // Mirror of drifted v2=(1.3,0.5,0) = (-1.3,0.5,0).
    // v4 is at (-1.0,0.5,0), distance=0.3 > eps=0.05 → spatial misses.
    auto m  = makeTwoQuadMesh(0.3f);
    auto sp = makeXPacket(0.05f, +1);

    // Confirm spatial does NOT pair v2.
    {
        int[] pOf; bool[] oP; int[] vS;
        rebuildPairing(m, sp, pOf, oP, vS);
        assert(pOf[2] == -1, "spatial should leave large-drift v2 unpaired");
    }

    // Topological pairing DOES pair v2↔v4 via connectivity.
    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    assert(pairOf[2] == 4 || pairOf[4] == 2,
        "topological: v2 and v4 must be paired");

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    // Driver (v2) unchanged.
    assert(m.vertices[2].x == pre[2].x,
        "topological: driver vert must be unchanged");

    // Partner (v4) snapped to mirror of drifted v2: (-1.3, 0.5, 0).
    assert(abs(m.vertices[4].x - (-1.3f)) < 1e-5f,
        "topological: partner.x should be -1.3 (mirror of 1.3)");
    assert(abs(m.vertices[4].y - 0.5f) < 1e-5f,
        "topological: partner.y should match driver.y = 0.5");
}


unittest {
    // No-op gate: already-symmetric mesh → no positions change.
    // Using a symmetric two-quad mesh (exact mirrors; drift = 0).
    auto m  = makeTwoQuadMesh(0.0f);   // v2=(1,0.5,0), v4=(-1,0.5,0) — symmetric
    auto sp = makeXPacket(1e-4f, +1);

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    bool moved = false;
    foreach (i; 0 .. pre.length)
        if (m.vertices[i] != pre[i]) { moved = true; break; }
    assert(!moved, "already-symmetric mesh: no positions should change");
}
