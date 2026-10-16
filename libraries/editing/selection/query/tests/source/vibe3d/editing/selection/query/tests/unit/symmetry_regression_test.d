module vibe3d.editing.selection.query.tests.unit.symmetry_regression_test;

import vibe3d.editing.selection.query.symmetry;
import std.math : abs;
import vibe3d.util.math.math : Vec3;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SymmetryPacket;


// ---------------------------------------------------------------------------
// Unittests — run only under `dub test --config=tests`, NOT `run_test.d`
// (the HTTP suite static-lib path never compiles this module standalone).
// ---------------------------------------------------------------------------

version (unittest) {
    import std.conv : to;

    // Build a minimal two-quad mesh sharing a seam edge on X=0.
    // Vertex layout (matches the plan's Phase 0.G worked example):
    //   0: c0 = (0, 0, 0)      — seam
    //   1: c1 = (0, 1, 0)      — seam
    //   2: A  = (2.0, 0.5, 0)  — +X driver (deformed off its spatial-mirror position)
    //   3: B  = (1.5, 1.2, 0)  — +X top
    //   4: D  = (-0.8,-0.3,0)  — -X partner of A (independently deformed)
    //   5: C  = (-1.1, 1.3,0)  — -X partner of B
    // Face 0 (+X quad): [c0, A, B, c1] = [0, 2, 3, 1]
    // Face 1 (-X quad): [c0, c1, C, D] = [0, 1, 5, 4]
    // Spatial mirror of A=(2.0,0.5,0) is (-2.0,0.5,0) — no vertex within any
    // reasonable epsilon of that point, so the spatial builder leaves A unpaired.
    private Mesh makeDeformedTwoQuadMesh() {
        Mesh m;
        m.addVertex(Vec3( 0.0f,  0.0f, 0.0f));   // 0: c0
        m.addVertex(Vec3( 0.0f,  1.0f, 0.0f));   // 1: c1
        m.addVertex(Vec3( 2.0f,  0.5f, 0.0f));   // 2: A (+X)
        m.addVertex(Vec3( 1.5f,  1.2f, 0.0f));   // 3: B (+X)
        m.addVertex(Vec3(-0.8f, -0.3f, 0.0f));   // 4: D (-X)
        m.addVertex(Vec3(-1.1f,  1.3f, 0.0f));   // 5: C (-X)
        m.addFace([0u, 2u, 3u, 1u]);              // +X quad: c0, A, B, c1
        m.addFace([0u, 1u, 5u, 4u]);              // -X quad: c0, c1, C, D
        m.buildLoops();
        return m;
    }

    // Helper: build an X-axis SymmetryPacket (plane X=0).
    private SymmetryPacket xPlanePacket(float eps = 1e-4f) {
        SymmetryPacket sp;
        sp.enabled      = true;
        sp.topology     = true;
        sp.axisIndex    = 0;
        sp.planeNormal  = Vec3(1, 0, 0);
        sp.planePoint   = Vec3(0, 0, 0);
        sp.epsilonWorld = eps;
        sp.baseSide     = +1;
        return sp;
    }
}


unittest { // mirrorDirection: X-plane negates only X component of dir
    import std.math : isClose;
    auto sp = xPlanePacket();
    auto d  = Vec3(3.0f, 4.0f, 5.0f);
    auto r  = mirrorDirection(sp, d);
    assert(isClose(r.x, -3.0f, 1e-6f), "mirrorDirection X expected -3, got " ~ r.x.to!string);
    assert(isClose(r.y,  4.0f, 1e-6f), "mirrorDirection Y unchanged, got "   ~ r.y.to!string);
    assert(isClose(r.z,  5.0f, 1e-6f), "mirrorDirection Z unchanged, got "   ~ r.z.to!string);

    // Non-axis-aligned direction: Z-plane (normal +Z).
    SymmetryPacket spZ;
    spZ.planeNormal = Vec3(0, 0, 1);
    spZ.planePoint  = Vec3(0, 0, 0);
    auto d2 = Vec3(1.0f, 2.0f, 3.0f);
    auto r2 = mirrorDirection(spZ, d2);
    assert(isClose(r2.x,  1.0f, 1e-6f));
    assert(isClose(r2.y,  2.0f, 1e-6f));
    assert(isClose(r2.z, -3.0f, 1e-6f));
}


unittest { // rebuildPairingTopological: pairs connectivity partners regardless of deformed positions
    import std.conv : to;
    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);

    assert(pairOf.length == 6);
    // Seam vertices: on-plane, pairOf = -1.
    assert(onPlane[0] && pairOf[0] == -1, "c0 should be on-plane/unpaired");
    assert(onPlane[1] && pairOf[1] == -1, "c1 should be on-plane/unpaired");
    // Connectivity pairs: A(2)↔D(4), B(3)↔C(5).
    assert(pairOf[2] == 4, "A should pair with D; got " ~ pairOf[2].to!string);
    assert(pairOf[4] == 2, "D should pair with A; got " ~ pairOf[4].to!string);
    assert(pairOf[3] == 5, "B should pair with C; got " ~ pairOf[3].to!string);
    assert(pairOf[5] == 3, "C should pair with B; got " ~ pairOf[5].to!string);
    // vertSign
    assert(vertSign[2] == +1 && vertSign[3] == +1, "+X verts should have vertSign +1");
    assert(vertSign[4] == -1 && vertSign[5] == -1, "-X verts should have vertSign -1");
}


unittest { // rebuildPairingTopological (task 0447): a face wound the SAME
           // direction across the seam edge leaves the seam endpoints NOT
           // vertexFanOrdered. Their fans have no meaningful slot order, so the
           // slot-position pairing must ABANDON (leave pairOf = -1) rather than
           // silently write a WRONG mirror pair (§3.1 — the silent corruptor).
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3( 0.0f,  0.0f, 0.0f));   // 0: c0 (seam)
    m.addVertex(Vec3( 0.0f,  1.0f, 0.0f));   // 1: c1 (seam)
    m.addVertex(Vec3( 2.0f,  0.5f, 0.0f));   // 2: A (+X)
    m.addVertex(Vec3( 1.5f,  1.2f, 0.0f));   // 3: B (+X)
    m.addVertex(Vec3(-0.8f, -0.3f, 0.0f));   // 4: D (-X)
    m.addVertex(Vec3(-1.1f,  1.3f, 0.0f));   // 5: C (-X)
    m.addFace([0u, 2u, 3u, 1u]);              // +X quad: seam (0,1) as 1->0
    m.addFace([0u, 4u, 5u, 1u]);              // -X quad: seam (0,1) ALSO 1->0 => inconsistent
    m.buildLoops();

    assert(!m.vertexFanOrdered(0) && !m.vertexFanOrdered(1),
        "setup: seam endpoints must be unordered on the inconsistently-wound mesh");

    auto sp = xPlanePacket();
    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);

    assert(pairOf.length == 6);
    // No off-plane vertex is paired: the expansion was abandoned at the
    // unordered seam. Crucially, NOT ONE wrong pair was written.
    foreach (vi; [2, 3, 4, 5])
        assert(pairOf[vi] == -1,
            "off-plane v" ~ vi.to!string ~ " must stay unpaired (abandoned), got "
            ~ pairOf[vi].to!string);
}


unittest { // rebuildPairing (spatial) fails to pair the deformed mesh — the discriminator
    import std.conv : to;
    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);

    // No off-plane vertex has a spatial mirror within epsilon (deformed positions).
    assert(pairOf[2] == -1, "spatial should NOT pair A on deformed mesh");
    assert(pairOf[3] == -1, "spatial should NOT pair B");
    assert(pairOf[4] == -1, "spatial should NOT pair D");
    assert(pairOf[5] == -1, "spatial should NOT pair C");
}


unittest { // applySymmetryMirrorDelta: deformed base — partner gets delta, not absolute mirror
    import std.math : isClose, fabs;
    import std.conv : to;

    auto m  = makeDeformedTwoQuadMesh();
    auto sp = xPlanePacket();

    // Build topological pair table.
    rebuildPairingTopological(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);

    // Baseline = pre-transform positions.
    auto baseline = m.vertices.dup;

    // Simulate translating A (vertex 2) by delta = (0.5, 0.3, 0.1).
    Vec3 delta = Vec3(0.5f, 0.3f, 0.1f);
    m.vertices[2] = baseline[2] + delta;

    // Drive mirror with A and its partner D in the operand (task 7144).
    bool[] sel = new bool[](6);
    sel[2] = true;
    sel[4] = true;   // the partner is written only when it is in the operand
    bool[] touched = new bool[](6);

    applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);

    // D (vertex 4) should move by mirrorDirection(delta) from its own base.
    Vec3 expectedD = baseline[4] + mirrorDirection(sp, delta);
    assert(isClose(m.vertices[4].x, expectedD.x, 1e-5f),
        "D.x expected " ~ expectedD.x.to!string ~ " got " ~ m.vertices[4].x.to!string);
    assert(isClose(m.vertices[4].y, expectedD.y, 1e-5f),
        "D.y expected " ~ expectedD.y.to!string ~ " got " ~ m.vertices[4].y.to!string);
    assert(isClose(m.vertices[4].z, expectedD.z, 1e-5f),
        "D.z expected " ~ expectedD.z.to!string ~ " got " ~ m.vertices[4].z.to!string);

    // Discriminator: NOT the absolute mirror of the driver's final position.
    Vec3 absWrong = mirrorPosition(sp, m.vertices[2]);
    assert(fabs(m.vertices[4].x - absWrong.x) > 0.1f ||
           fabs(m.vertices[4].y - absWrong.y) > 0.1f ||
           fabs(m.vertices[4].z - absWrong.z) > 0.1f,
        "delta-mirror must differ from absolute-mirror on deformed base");
    assert(touched[4], "D should be in outAlsoTouched");
}


unittest { // equivalence: on symmetric base, delta-mirror == absolute-mirror (float-exact for axis-aligned)
    import std.math : isClose;
    import std.conv : to;

    // Symmetric mesh: A at (+0.5, 0.7, 0.3) and D at (-0.5, 0.7, 0.3) = spatial mirror of A.
    Mesh m;
    m.addVertex(Vec3(0.0f,  0.0f, 0.0f));   // 0: c0
    m.addVertex(Vec3(0.0f,  1.0f, 0.0f));   // 1: c1
    m.addVertex(Vec3(0.5f,  0.7f, 0.3f));   // 2: A  (+X)
    m.addVertex(Vec3(0.5f,  1.5f, 0.3f));   // 3: B  (+X)
    m.addVertex(Vec3(-0.5f, 0.7f, 0.3f));   // 4: D  (-X, exact spatial mirror of A)
    m.addVertex(Vec3(-0.5f, 1.5f, 0.3f));   // 5: C  (-X, exact spatial mirror of B)
    m.addFace([0u, 2u, 3u, 1u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.buildLoops();

    auto sp = xPlanePacket(1e-3f);  // wider eps to pair the symmetric verts
    rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
    // Spatial should pair A(2)↔D(4) and B(3)↔C(5) on the symmetric mesh.
    assert(sp.pairOf[2] == 4, "symmetric mesh spatial pair A↔D expected");

    auto baseline = m.vertices.dup;
    Vec3 delta = Vec3(0.2f, 0.15f, 0.05f);
    m.vertices[2] = baseline[2] + delta;

    bool[] sel = new bool[](6); sel[2] = true; sel[4] = true;   // both in the operand
    bool[] touched = new bool[](6);

    applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);
    Vec3 deltaResult = m.vertices[4];
    {
        const Vec3 dv = deltaResult - baseline[4];
        assert(abs(dv.x) + abs(dv.y) + abs(dv.z) > 0.1f, "equivalence: D did not move by |δ|");
    }

    // Reset D and apply absolute-mirror.
    m.vertices[4] = baseline[4];
    bool[] touched2 = new bool[](6);
    bool[] sel2 = sel.dup;
    applySymmetryMirror(&m, sp, sel2, touched2);
    Vec3 absResult = m.vertices[4];

    assert(isClose(deltaResult.x, absResult.x, 1e-5f),
        "equivalence X: delta=" ~ deltaResult.x.to!string ~ " abs=" ~ absResult.x.to!string);
    assert(isClose(deltaResult.y, absResult.y, 1e-5f),
        "equivalence Y: delta=" ~ deltaResult.y.to!string ~ " abs=" ~ absResult.y.to!string);
    assert(isClose(deltaResult.z, absResult.z, 1e-5f),
        "equivalence Z: delta=" ~ deltaResult.z.to!string ~ " abs=" ~ absResult.z.to!string);
}





unittest { // disconnected precondition: topological yields no pairs, spatial does pair
    import std.conv : to;

    // Two separate quad islands at X=±0.5, no shared seam vertex.
    Mesh m;
    m.addVertex(Vec3(-0.5f, -0.5f, 0.0f));  // 0
    m.addVertex(Vec3(-0.5f,  0.5f, 0.0f));  // 1
    m.addVertex(Vec3(-0.5f, -0.5f, 1.0f));  // 2
    m.addVertex(Vec3(-0.5f,  0.5f, 1.0f));  // 3
    m.addVertex(Vec3( 0.5f, -0.5f, 0.0f));  // 4
    m.addVertex(Vec3( 0.5f,  0.5f, 0.0f));  // 5
    m.addVertex(Vec3( 0.5f, -0.5f, 1.0f));  // 6
    m.addVertex(Vec3( 0.5f,  0.5f, 1.0f));  // 7
    m.addFace([0u, 1u, 3u, 2u]);  // -X quad
    m.addFace([4u, 6u, 7u, 5u]);  // +X quad
    m.buildLoops();

    auto sp = xPlanePacket(0.6f);  // eps wide enough to reach ±0.5 for spatial

    int[] tPairOf; bool[] tOnPlane; int[] tVertSign;
    rebuildPairingTopological(m, sp, tPairOf, tOnPlane, tVertSign);
    // No seam vertices → all pairOf = -1.
    foreach (i; 0 .. 8)
        assert(tPairOf[i] == -1,
            "topological: disconnected mesh should have no pairs; pairOf["
            ~ i.to!string ~ "]=" ~ tPairOf[i].to!string);

    // Spatial with a tighter eps (0.1f) so the ±0.5 verts are NOT swallowed
    // into the plane and CAN be paired across it (mirrored distance = 0).
    auto spSpatial = xPlanePacket(0.1f);
    int[] sPairOf; bool[] sOnPlane; int[] sVertSign;
    rebuildPairing(m, spSpatial, sPairOf, sOnPlane, sVertSign);
    // Spatial should pair the two islands by position.
    bool anyPaired = false;
    foreach (i; 0 .. 8) if (sPairOf[i] >= 0) { anyPaired = true; break; }
    assert(anyPaired, "spatial: disconnected mirrored mesh should have pairs");
}



// ---------------------------------------------------------------------------
// R3 — the symmetry mirror partner (task 0613 S5, doc/hide_geometry_plan.md
// §3.4). `pairOf` selects the partner from POSITIONS, by no mark at all, so a
// hidden partner enters the operand set without ever being selected (R1 cannot
// see it) and without ever being in a mask (R2's funnel cannot see it). These
// two tests pin the guard that closes that route, one per function.
//
// Fixture note (the trap Stage 4 hit and this deliberately avoids): the hidden
// vertex's NEIGHBOURS stay visible. Hiding face 1 (the -X quad) derives D(4)
// and C(5) hidden — each touches only face 1 — while the seam verts c0(0) and
// c1(1) stay visible, because they still touch the visible +X quad. So nothing
// upstream can "accidentally" skip the write; only the new guard can.
// ---------------------------------------------------------------------------

version (unittest) {
    // Symmetric two-quad mesh straddling X=0, paired spatially. Same layout as
    // the equivalence test above, factored out so both R3 rows share it.
    private Mesh makeSymmetricTwoQuadMesh() {
        Mesh m;
        m.addVertex(Vec3( 0.0f, 0.0f, 0.0f));   // 0: c0 (seam)
        m.addVertex(Vec3( 0.0f, 1.0f, 0.0f));   // 1: c1 (seam)
        m.addVertex(Vec3( 0.5f, 0.7f, 0.3f));   // 2: A  (+X driver)
        m.addVertex(Vec3( 0.5f, 1.5f, 0.3f));   // 3: B  (+X)
        m.addVertex(Vec3(-0.5f, 0.7f, 0.3f));   // 4: D  (-X partner of A)
        m.addVertex(Vec3(-0.5f, 1.5f, 0.3f));   // 5: C  (-X partner of B)
        m.addFace([0u, 2u, 3u, 1u]);            // face 0: +X quad
        m.addFace([0u, 1u, 5u, 4u]);            // face 1: -X quad
        m.buildLoops();
        m.syncSelection();                      // size the marks arrays
        return m;
    }
}


unittest { // T-R3 row 1 — applySymmetryMirror refuses a hidden partner
    import std.math : isClose, fabs;
    import std.conv : to;

    // The drag: +0.4 along Y. Y lies IN the mirror plane, so the mirrored
    // write moves the partner in the SAME direction as the driver — which is
    // exactly what makes "unchanged" and "mirrored" numerically distinct here
    // (0.7 vs 1.1 on the partner's Y). A drag that left the partner where it
    // already was could not tell a fired guard from a lucky no-op.
    enum float DRAG_Y     = 0.4f;
    enum float PARTNER_Y0 = 0.7f;          // D's original Y
    enum float MIRRORED_Y = 1.1f;          // what an UNGUARDED mirror writes

    // --- CONTROL ROW: nothing hidden ⇒ the mirror really does fire here. ---
    // Without this row, row 2's "D did not move" would also pass on a build
    // where the pairing simply failed, or symmetry was off.
    {
        auto m  = makeSymmetricTwoQuadMesh();
        auto sp = xPlanePacket(1e-3f);
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
        assert(sp.pairOf[2] == 4, "fixture: A(2) must pair with D(4)");

        m.vertices[2].y += DRAG_Y;
        bool[] sel = new bool[](6); sel[2] = true; sel[4] = true;   // both in the operand
        bool[] touched = new bool[](6);
        applySymmetryMirror(&m, sp, sel, touched);

        assert(isClose(m.vertices[4].y, MIRRORED_Y, 1e-5f),
            "CONTROL: with nothing hidden the partner must mirror to y="
            ~ MIRRORED_Y.to!string ~ ", got " ~ m.vertices[4].y.to!string);
        assert(touched[4], "CONTROL: the partner must be reported as touched");
    }

    // --- THE ASSERTION: D hidden ⇒ the mirror write is dropped. ---
    {
        auto m  = makeSymmetricTwoQuadMesh();
        auto sp = xPlanePacket(1e-3f);
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);

        m.setFaceHidden(1, true);          // -X quad ⇒ D(4) and C(5) derive hidden
        assert(m.isVertexHidden(4), "fixture: D(4) must derive hidden");
        assert(!m.isVertexHidden(0), "fixture: the seam vertex must stay VISIBLE "
            ~ "(it still touches the visible +X quad) — a fixture where the "
            ~ "hidden face owns all its corners lets an unrelated check pass this");

        m.vertices[2].y += DRAG_Y;
        bool[] sel = new bool[](6); sel[2] = true; sel[4] = true;   // both in the operand
        bool[] touched = new bool[](6);
        applySymmetryMirror(&m, sp, sel, touched);

        assert(isClose(m.vertices[4].y, PARTNER_Y0, 1e-6f),
            "hidden partner must be bit-identical at y=" ~ PARTNER_Y0.to!string
            ~ "; got " ~ m.vertices[4].y.to!string
            ~ " (an unguarded mirror writes " ~ MIRRORED_Y.to!string ~ ")");
        assert(isClose(m.vertices[4].x, -0.5f, 1e-6f), "hidden partner X moved");
        assert(!touched[4],
            "a dropped mirror write must not claim the partner was touched");
        // The DRIVER still moved: the guard drops the partner write only.
        assert(isClose(m.vertices[2].y, PARTNER_Y0 + DRAG_Y, 1e-6f),
            "the visible driver must still move");
    }
}


unittest { // T-R3 row 2 — applySymmetryMirrorDelta has the identical hole
    import std.math : isClose;
    import std.conv : to;

    enum float DRAG_Y     = 0.4f;
    enum float PARTNER_Y0 = 0.7f;
    enum float MIRRORED_Y = 1.1f;   // delta-mirror on a symmetric base == absolute

    // Control: the delta twin fires on this fixture with nothing hidden.
    {
        auto m  = makeSymmetricTwoQuadMesh();
        auto sp = xPlanePacket(1e-3f);
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
        auto baseline = m.vertices.dup;
        m.vertices[2].y += DRAG_Y;
        bool[] sel = new bool[](6); sel[2] = true; sel[4] = true;   // both in the operand
        bool[] touched = new bool[](6);
        applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);
        assert(isClose(m.vertices[4].y, MIRRORED_Y, 1e-5f),
            "CONTROL (delta): partner must mirror to y=" ~ MIRRORED_Y.to!string
            ~ ", got " ~ m.vertices[4].y.to!string);
    }

    {
        auto m  = makeSymmetricTwoQuadMesh();
        auto sp = xPlanePacket(1e-3f);
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
        m.setFaceHidden(1, true);
        assert(m.isVertexHidden(4), "fixture: D(4) must derive hidden");

        auto baseline = m.vertices.dup;
        m.vertices[2].y += DRAG_Y;
        bool[] sel = new bool[](6); sel[2] = true; sel[4] = true;   // both in the operand
        bool[] touched = new bool[](6);
        applySymmetryMirrorDelta(&m, sp, baseline, sel, touched);

        assert(isClose(m.vertices[4].y, PARTNER_Y0, 1e-6f),
            "delta-mirror: hidden partner must be bit-identical at y="
            ~ PARTNER_Y0.to!string ~ "; got " ~ m.vertices[4].y.to!string
            ~ " (unguarded writes " ~ MIRRORED_Y.to!string ~ ")");
        assert(!touched[4],
            "delta-mirror: a dropped write must not claim the partner was touched");
    }
}
