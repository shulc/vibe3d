// Module unittests for `mesh_ops.revolve`, moved verbatim out of source/mesh_ops/revolve.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.revolve_test;

import mesh;
import math;
import mesh_ops.revolve;

    unittest { // extrudeAlongPath (a): cube top face, straight vertical path, 16
               // spans — pins the KERNEL's topology for the captured span count
               // (task 0323 toolcard behavior_law_measured: cube top face,
               // default attrs, straight 180px screen drag → +64v/+64f, 16
               // bands). This test feeds the kernel a caller-resolved 16-point
               // WORLD-space path directly — it does NOT reproduce the
               // reference's screen-pixel→world camera-raycast mapping (that
               // lives at the tool layer — see StrokeExtrudeTool's doc comment)
               // nor the measured non-uniform per-band world spacing (a camera-
               // perspective effect, finding_1 — NOT a kernel-level law). The
               // exact screen-Precision→span-count formula is the toolcard's
               // own open follow-up (finding_3) and is intentionally NOT
               // guessed here or anywhere else in this port.
        import std.conv : to;
        import std.math : abs;

        auto m = makeCube();
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi])
                if (abs(m.vertices[vid].y - 0.5f) > 1e-4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        assert(topFi >= 0, "extrudeAlongPath: top face not found on test cube");

        bool[] mask;
        mask.length = m.faces.length;
        mask[]       = false;
        mask[topFi]  = true;

        Vec3[] path;
        path ~= Vec3(0, 0.5f, 0);   // anchor -- top face's own height
        foreach (k; 1 .. 17) path ~= Vec3(0, 0.5f + 0.1f * cast(float)k, 0);

        size_t added = m.extrudeAlongPath(mask, path, /*alignToPath*/true);
        assert(added == 64,
            "extrudeAlongPath: expected +64 net faces for the captured 16-span case, got "
            ~ added.to!string);
        assert(m.faces.length == 6 + 64,
            "extrudeAlongPath: expected 70 total faces (6 orig + 64 new), got "
            ~ m.faces.length.to!string);
        assert(m.vertices.length == 8 + 64,
            "extrudeAlongPath: expected 72 total verts (8 orig + 64 new), got "
            ~ m.vertices.length.to!string);

        // Manifold (task 0363 discipline): every undirected edge used by at
        // most 2 faces.
        int[ulong] edgeUse;
        foreach (ref face; m.faces) {
            size_t n = face.length;
            foreach (i; 0 .. n) {
                uint a = face[i], b = face[(i + 1) % n];
                ulong key = a < b ? ((cast(ulong)a << 32) | b) : ((cast(ulong)b << 32) | a);
                edgeUse[key] = edgeUse.get(key, 0) + 1;
            }
        }
        foreach (key, count; edgeUse)
            assert(count <= 2,
                "extrudeAlongPath: edge used by " ~ count.to!string ~ " faces -- non-manifold");
    }

    unittest { // extrudeAlongPath (b): guard rejections -- all must return 0,
               // mesh unchanged.
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
        Vec3[] path2 = [Vec3(0, 0, 0), Vec3(0, 1, 0)];

        // Mask length mismatch.
        bool[] badMask = [true, false];
        assert(m.extrudeAlongPath(badMask, path2) == 0,
            "extrudeAlongPath: mask-length mismatch must return 0");

        // No face selected.
        bool[] emptyMask; emptyMask.length = m.faces.length;
        assert(m.extrudeAlongPath(emptyMask, path2) == 0,
            "extrudeAlongPath: empty mask must return 0");

        // Fewer than 2 path points.
        assert(m.extrudeAlongPath(mask, [Vec3(0, 0, 0)]) == 0,
            "extrudeAlongPath: single-point path must return 0");
        assert(m.extrudeAlongPath(mask, cast(Vec3[])[]) == 0,
            "extrudeAlongPath: empty path must return 0");

        // Span-count DoS backstop: 4098 points => 4097 spans, one past the
        // internal 4096 cap => hard rejection. NOTE: deliberately NOT
        // testing the "exactly at the cap succeeds" boundary end-to-end
        // here — actually running 4096 real bands is O(bands × faces) and
        // would make `dub test` pathologically slow; the cap's ALLOW side
        // is already exercised cheaply by the 16-span case in test (a)
        // above, so this test only needs to prove the REJECT side, which
        // returns before any band runs (O(1), no mutation).
        Vec3[] overCap;
        overCap.length = 4098;
        foreach (k, ref p; overCap) p = Vec3(0, 0.5f + 0.001f * cast(float)k, 0);
        size_t facesBefore = m.faces.length;
        size_t vertsBefore = m.vertices.length;
        assert(m.extrudeAlongPath(mask, overCap) == 0,
            "extrudeAlongPath: over-cap span count must return 0 (DoS backstop)");
        assert(m.faces.length == facesBefore && m.vertices.length == vertsBefore,
            "extrudeAlongPath: over-cap rejection must leave the mesh unchanged");
    }

unittest { // revolveProfile (a): closed ring 360° — 16 quads, 16 verts, manifold, 0 boundary loops
    import std.math : PI;
    import std.conv : to;

    // Square closed cross-section at x=2 from the Y axis.
    // Closing edges complete the ring (needed for bridgeLoopsPaired topology but
    // not structurally required — revolveProfile only reads vertex positions via
    // the vertex index array, not edge topology).
    Mesh m;
    m.addVertex(Vec3(2, 0, 0));  // v0
    m.addVertex(Vec3(2, 1, 0));  // v1
    m.addVertex(Vec3(2, 1, 1));  // v2
    m.addVertex(Vec3(2, 0, 1));  // v3
    m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3); m.addEdge(3, 0);
    m.buildLoops();

    // Revolve 360°, 4 steps.
    // Closed sweep: 4 rings × 4 bridge steps × 4 quads/step = 16 faces.
    // Vertex count: ring[0]=4 original + rings[1..3]=3×4 = 4+12 = 16 (no seam dup).
    size_t added = m.revolveProfile([0u, 1u, 2u, 3u], /*profileClosed*/true,
                                    /*count*/4, 'Y', Vec3(0, 0, 0),
                                    cast(float)(2 * PI));
    assert(added == 16,
        "closed 360°: revolveProfile returned " ~ added.to!string ~ ", expected 16");
    assert(m.faces.length == 16,
        "closed 360°: faces.length == " ~ m.faces.length.to!string ~ ", expected 16");
    assert(m.vertices.length == 16,
        "closed 360°: vertices.length == " ~ m.vertices.length.to!string
        ~ " (expected 16, no seam dup)");

    // Manifold: every face-edge must appear exactly twice across all faces.
    int[ulong] edgeInc;
    foreach (fi; 0 .. m.faces.length) {
        const f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            ulong key = a < b ? (cast(ulong)a << 32) | b
                              : (cast(ulong)b << 32) | a;
            edgeInc[key]++;
        }
    }
    foreach (key, cnt; edgeInc)
        assert(cnt == 2,
            "closed 360°: edge " ~ key.to!string ~ " has incidence " ~ cnt.to!string
            ~ " (expected exactly 2 — surface must be manifold)");

    // Watertight: zero boundary loops.
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 0,
        "closed 360°: expected 0 boundary loops, got " ~ bLoops.length.to!string);
}

unittest { // revolveProfile (b): open strip, partial arc — 4 quads, 9 verts, 1 boundary loop
    import std.math : PI;
    import std.conv : to;

    // 3-vert polyline along the X axis; open-strip profile (profileClosed=false).
    // Verts in the y=0 plane: all rotated verts also remain in y=0 (Y-axis rotation
    // preserves y).  Face normals all point in +Y (verified analytically).
    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.buildLoops();

    // Open 90° arc, 3 copies.
    // stepAngle = (π/2)/(3-1) = π/4.
    // Bridges: (0→1), (1→2).  Each step: M-1 = 2 quads.  Total = 4 quads.
    // Vertex count: 3 original + 2 new rings × 3 = 9.
    size_t added = m.revolveProfile([0u, 1u, 2u], /*profileClosed*/false,
                                    /*count*/3, 'Y', Vec3(0, 0, 0),
                                    cast(float)(PI * 0.5));
    assert(added == 4,
        "open arc 90°: revolveProfile returned " ~ added.to!string ~ ", expected 4");
    assert(m.faces.length == 4,
        "open arc 90°: faces.length == " ~ m.faces.length.to!string ~ ", expected 4");
    assert(m.vertices.length == 9,
        "open arc 90°: vertices.length == " ~ m.vertices.length.to!string
        ~ ", expected 9");

    // All new faces must be quads with globally consistent winding.
    Vec3 refN = m.faceNormal(0);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4,
            "open arc 90°: face " ~ fi.to!string ~ " is not a quad");
        Vec3 fn = m.faceNormal(cast(uint)fi);
        float dt = fn.x * refN.x + fn.y * refN.y + fn.z * refN.z;
        assert(dt > 0.0f,
            "open arc 90°: face " ~ fi.to!string ~ " has inconsistent winding");
    }

    // Open partial arc: one boundary loop (the rectangular perimeter).
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 1,
        "open arc 90°: expected 1 boundary loop (perimeter), got "
        ~ bLoops.length.to!string);
}

unittest { // revolveProfile (c): guard rejections — all must return 0, mesh unchanged
    import std.math : PI;
    import std.conv : to;

    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2

    immutable float tau = cast(float)(2 * PI);
    uint[] p3 = [0u, 1u, 2u];

    // count < 2
    assert(m.revolveProfile(p3, false, 1, 'Y', Vec3(0,0,0), tau) == 0,
        "guard count<2: expected 0");
    assert(m.faces.length == 0, "guard count<2: mesh must be unchanged");

    // bad axis character
    assert(m.revolveProfile(p3, false, 4, 'W', Vec3(0,0,0), tau) == 0,
        "guard bad axis: expected 0");
    assert(m.faces.length == 0, "guard bad axis: mesh must be unchanged");

    // zero angle
    assert(m.revolveProfile(p3, false, 4, 'Y', Vec3(0,0,0), 0.0f) == 0,
        "guard zero angle: expected 0");
    assert(m.faces.length == 0, "guard zero angle: mesh must be unchanged");

    // profile.length < 2
    assert(m.revolveProfile([0u], false, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard profile<2: expected 0");
    assert(m.faces.length == 0, "guard profile<2: mesh must be unchanged");

    // closed profile with < 3 verts
    assert(m.revolveProfile([0u, 1u], true, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard closed<3: expected 0");
    assert(m.faces.length == 0, "guard closed<3: mesh must be unchanged");

    // Vertex count must also be untouched: only the 3 verts we added.
    assert(m.vertices.length == 3,
        "guards: vertices.length must remain 3, got " ~ m.vertices.length.to!string);
}

unittest { // revolveProfileEx (d): spiral offset at a >=360deg angle span
           // must NOT wrap the last ring onto ring 0 (task 0326 review S1)
    import std.math : PI, abs;
    import std.conv : to;

    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1

    immutable float tau = cast(float)(2 * PI);

    Mesh.RevolveParams p;
    p.count  = 5;
    p.axis   = Vec3(0, 1, 0);
    p.center = Vec3(0, 0, 0);
    p.angle  = tau;      // angle-closed span on its own...
    p.offset = 0.5f;     // ...but a nonzero spiral offset must force OPEN.

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;
    size_t inserted = m.revolveProfileEx([0u, 1u], false, p);

    // OPEN topology: count-1 bridges (4), NOT count (5) — a wrap bridge
    // would connect ring[4] (height 4*offset=2.0) back onto ring[0]
    // (height 0), a spurious self-intersecting closing band.
    assert(inserted == 4,
        "spiral offset at >=360deg: expected 4 faces (no wrap band), got "
        ~ inserted.to!string);
    assert(m.faces.length - facesBefore == 4,
        "spiral offset at >=360deg: expected +4 faces, got +"
        ~ (m.faces.length - facesBefore).to!string);
    // ring0 (reused, 0 new) + 4 new rings x 2 verts = 8 new verts.
    assert(m.vertices.length - vertsBefore == 8,
        "spiral offset at >=360deg: expected +8 verts, got +"
        ~ (m.vertices.length - vertsBefore).to!string);

    // Last ring (k=4) landed a full turn around (XZ back near the start)
    // but risen 4*offset=2.0 along Y — proves the sweep kept climbing
    // instead of folding back onto ring 0's height.
    Vec3 lastRingV0 = m.vertices[$ - 2];
    assert(abs(lastRingV0.y - 2.0f) < 1e-3f,
        "spiral offset: last ring expected y~2.0, got " ~ lastRingV0.y.to!string);
    assert(abs(lastRingV0.x - 1.0f) < 1e-2f && abs(lastRingV0.z) < 1e-2f,
        "spiral offset: last ring expected XZ~(1,0) after a full turn, got ("
        ~ lastRingV0.x.to!string ~ "," ~ lastRingV0.z.to!string ~ ")");
}

// Site 19 (task 1902 Stage E) — extrudePathStep_'s single rebuild pass:
// [non-selected originals] (identity oldOfNew) + [cap clones] (source `fi`)
// + [wall quads] (source `be.selFi`). No existing test in this file asserts
// material/part by value. TWO non-adjacent faces are selected (a 3x3 grid's
// opposite corners, faces 0 and 8 — no shared edge, so they form two
// SEPARATE islands) with distinct materials, so per-wall attribution is
// testable: a bug that let one island's walls read the OTHER island's
// source face would not show on a single-face selection.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);   // 3x3 grid, 9 quads, row-major fi = row*3+col
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }
    // Non-zero order stamps on BOTH source faces, so a bug that inherits a
    // created face's order from its source (instead of zeroing it) is
    // observable on either island.
    m.faceSelectionOrder[0] = 71;
    m.faceSelectionOrder[8] = 79;

    bool[] mask = new bool[](m.faces.length);
    mask[0] = true;   // top-left corner
    mask[8] = true;   // bottom-right corner — no edge shared with face 0

    size_t added = m.extrudeAlongPath(mask, [Vec3(0,0,0), Vec3(0,0,1)], true);
    assert(added > 0, "extrudePathStep_: expected the single-span band to add faces");

    // 7 non-selected originals + 2 cap clones (one per island) + 8 wall
    // quads (a corner face has 4 boundary edges in its own single-face
    // island — none shared with another SELECTED face — so 4 walls per
    // island x 2 islands).
    assert(m.faces.length == 7 + 2 + 8,
        "extrudePathStep_: expected 7 survivors + 2 caps + 8 walls, got "
        ~ m.faces.length.to!string);

    // Survivors (old faces 1..7, in order) land at compacted positions 0..6,
    // each keeping its OWN material/part.
    foreach (i; 0 .. 7) {
        immutable uint oldFi = cast(uint)(i + 1);
        assert(m.faceMaterial[i] == 1000 + oldFi,
            "extrudePathStep_: survivor at position " ~ i.to!string
            ~ " must keep its OWN material");
        assert(m.facePart[i] == 2000 + oldFi,
            "extrudePathStep_: survivor at position " ~ i.to!string
            ~ " must keep its OWN part");
    }

    // Cap range (positions 7,8): toCloneFace walks selected faces in
    // increasing `fi` order, so position 7 is face 0's cap, position 8 is
    // face 8's cap — deterministic.
    assert(m.faceMaterial[7] == 1000 && m.facePart[7] == 2000,
        "extrudePathStep_: face 0's cap must inherit its material/part");
    assert(m.faceMaterial[8] == 1008 && m.facePart[8] == 2008,
        "extrudePathStep_: face 8's cap must inherit its material/part");

    // Wall range (positions 9..16): `bEdges` is built by iterating an
    // associative array (`edgeFaces`), so the ORDER within the wall range
    // is not guaranteed — attribute by VALUE instead: exactly 4 walls must
    // read face 0's material/part, exactly 4 must read face 8's, and every
    // wall's faceSelectionOrder must be 0 (never inheriting its source's
    // own stamp of 71 or 79 — plan §2.7a, and unlike the cap range this
    // portion is NOT re-selected by the tail loop below, so it is the one
    // that actually discriminates the override).
    size_t from0 = 0, from8 = 0;
    foreach (i; 9 .. 17) {
        immutable uint mat = m.faceMaterial[i], part = m.facePart[i];
        if (mat == 1000 && part == 2000) ++from0;
        else if (mat == 1008 && part == 2008) ++from8;
        else assert(false, "extrudePathStep_: wall at position " ~ i.to!string
            ~ " must inherit material/part from ONE of the two source faces "
            ~ "(got mat=" ~ mat.to!string ~ " part=" ~ part.to!string ~ ")");
        assert(m.faceSelectionOrder[i] == 0,
            "extrudePathStep_: wall at position " ~ i.to!string
            ~ " must start UNSELECTED (order 0), never inheriting its "
            ~ "source face's own order stamp (71 or 79)");
    }
    assert(from0 == 4, "extrudePathStep_: expected 4 walls from face 0's island, got " ~ from0.to!string);
    assert(from8 == 4, "extrudePathStep_: expected 4 walls from face 8's island, got " ~ from8.to!string);
}
