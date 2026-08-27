// Module unittests for `mesh_ops.revolve`, moved verbatim out of source/mesh_ops/revolve.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.revolve_test;

import mesh;
import math;
import mesh_ops.revolve;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, MeshOpEntry;
import std.conv : to;

// TASK 1903 Stage E2 — `revolveProfile`, `revolveProfileEx` and
// `extrudeAlongPath` are free functions over `ref MeshEditBatch` now, so a test
// cannot call one on a bare `Mesh` any more: that is the point of the receiver,
// and it is why every call site in this file goes through the helper below. One
// helper for all three kernels, so there is ONE place that says why the batch is
// `unrecorded` — nothing in these blocks reads an op-log, and track 1 is the
// conversion axis only (the production callers — `commands/mesh/sweep.d`,
// `commands/mesh/stroke_extrude.d`, `RadialSweepTool`'s three sites and
// `StrokeExtrudeTool`'s drag frame — open theirs the same way; see
// mesh_ops/revolve.d's header). The RECORDING block at the bottom of this file
// is the one deliberate exception.
private size_t revolveOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kRevolveEditScope);
    const n = kernel(ed, args);
    ed.close();
    return n;
}

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

        size_t added = revolveOnce!extrudeAlongPath(m, mask, path, /*alignToPath*/true);
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
        assert(revolveOnce!extrudeAlongPath(m, badMask, path2) == 0,
            "extrudeAlongPath: mask-length mismatch must return 0");

        // No face selected.
        bool[] emptyMask; emptyMask.length = m.faces.length;
        assert(revolveOnce!extrudeAlongPath(m, emptyMask, path2) == 0,
            "extrudeAlongPath: empty mask must return 0");

        // Fewer than 2 path points.
        assert(revolveOnce!extrudeAlongPath(m, mask, [Vec3(0, 0, 0)]) == 0,
            "extrudeAlongPath: single-point path must return 0");
        assert(revolveOnce!extrudeAlongPath(m, mask, cast(Vec3[])[]) == 0,
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
        assert(revolveOnce!extrudeAlongPath(m, mask, overCap) == 0,
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
    size_t added = revolveOnce!revolveProfile(m, [0u, 1u, 2u, 3u], /*profileClosed*/true,
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
    size_t added = revolveOnce!revolveProfile(m, [0u, 1u, 2u], /*profileClosed*/false,
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
    assert(revolveOnce!revolveProfile(m, p3, false, 1, 'Y', Vec3(0,0,0), tau) == 0,
        "guard count<2: expected 0");
    assert(m.faces.length == 0, "guard count<2: mesh must be unchanged");

    // bad axis character
    assert(revolveOnce!revolveProfile(m, p3, false, 4, 'W', Vec3(0,0,0), tau) == 0,
        "guard bad axis: expected 0");
    assert(m.faces.length == 0, "guard bad axis: mesh must be unchanged");

    // zero angle
    assert(revolveOnce!revolveProfile(m, p3, false, 4, 'Y', Vec3(0,0,0), 0.0f) == 0,
        "guard zero angle: expected 0");
    assert(m.faces.length == 0, "guard zero angle: mesh must be unchanged");

    // profile.length < 2
    assert(revolveOnce!revolveProfile(m, [0u], false, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard profile<2: expected 0");
    assert(m.faces.length == 0, "guard profile<2: mesh must be unchanged");

    // closed profile with < 3 verts
    assert(revolveOnce!revolveProfile(m, [0u, 1u], true, 4, 'Y', Vec3(0,0,0), tau) == 0,
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

    RevolveParams p;
    p.count  = 5;
    p.axis   = Vec3(0, 1, 0);
    p.center = Vec3(0, 0, 0);
    p.angle  = tau;      // angle-closed span on its own...
    p.offset = 0.5f;     // ...but a nonzero spiral offset must force OPEN.

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;
    size_t inserted = revolveOnce!revolveProfileEx(m, [0u, 1u], false, p);

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

    size_t added = revolveOnce!extrudeAlongPath(m, mask, [Vec3(0,0,0), Vec3(0,0,1)], true);
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

// ===========================================================================
// THE RECORDING BATCH (task 1903 Stage E2, plan §2.2 / §5.3 / §5.5).
//
// Everything above runs under an UNRECORDED batch, because that is what all
// four production callers open: `mesh.sweep`, `mesh.strokeExtrude`,
// `RadialSweepTool` and `StrokeExtrudeTool` all undo through a whole-mesh
// `MeshSnapshot` today, and track 1 is the CONVERSION axis only. The blocks
// below open a RECORDING one instead, and they are the only place in the tree
// that has ever looked at what this family's op-log actually contains.
//
// WHY THAT IS WORTH A TEST BEFORE THE UNDO MIGRATION. §5.5's L-table is keyed
// by COMMAND, and this file's two kernels sit in DIFFERENT rows —
// `mesh.sweep` is **L10** (topo-misc, reindexing half) and `mesh.strokeExtrude`
// belongs with the extrude family at **L8** (after Stage J). Measuring the
// delta now says which of them can already be flipped and which is carrying a
// gap, instead of discovering it inside the stage that has to ship it.
// ===========================================================================

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

/// The scope both kernels declare, written out from the enum INDEPENDENTLY of
/// `kRevolveEditScope`.
///
/// `d.scope_` IS `kRevolveEditScope` fed through `MeshEditTracker.declare`, so
/// `d.scope_ == kRevolveEditScope` is the measurement judging itself: set the
/// constant to 0 and that equality stays true. Measured at Stage D2 on the
/// reduce family, where exactly that draft stayed green under
/// `enum uint kReduceEditScope = 0;`. So the expectation here is written from
/// what the kernels DO — they append rings and clones (Points), bridge them
/// into faces and rewrite the face array (Polygons), and rewrite the selection
/// to the new faces (Marks) — and the equality against the constant is
/// asserted separately, AFTER it, where it can only see a broken
/// `declare`/`close` path.
private enum uint kExpectedRevolveScope = MeshEditScope.Points
                                        | MeshEditScope.Polygons
                                        | MeshEditScope.Marks;

private void assertDeclaredScope(string what, ref MeshEditDelta d) {
    import std.format : format;
    assert(cast(uint)d.scope_ == kExpectedRevolveScope,
        format("%s: a recording sweep declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks). Missing: 0x%x. Unexpected: 0x%x. "
             ~ "`MeshEditDelta.finalize` reads scope_ back on a revert to "
             ~ "decide what to bump and rebuild, so a wrong constant is a "
             ~ "wrong invalidation, not a cosmetic mismatch "
             ~ "(task 1903 Stage E2)",
               what, cast(uint)d.scope_, kExpectedRevolveScope,
               kExpectedRevolveScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedRevolveScope));
    assert(cast(uint)d.scope_ == kRevolveEditScope,
        format("%s: the delta's scope_ (0x%x) is not the kRevolveEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               what, cast(uint)d.scope_, kRevolveEditScope));
}

/// NO POSITION WRITE, EVER — the behavioural twin of `kRevolveEditScope`'s
/// "NOT Position" doc comment and of this family's §5.7 census count being 0
/// rather than a retired allow-entry. Neither kernel moves an EXISTING vertex:
/// every coordinate they produce belongs to a vertex created in the same call.
private void assertNoPositionWrite(string what, ref MeshEditDelta d) {
    import std.format : format;
    immutable size_t setPos = countKind(d, MeshOpEntry.Kind.SetPos);
    assert(setPos == 0,
        format("%s: the op-log carries %d Kind.SetPos entries, expected 0 — a "
             ~ "revolve kernel now moves an EXISTING vertex. That is a real "
             ~ "behaviour change: add MeshEditScope.Position to "
             ~ "kRevolveEditScope and rewrite its doc comment, or take the "
             ~ "write back out (task 1903 §5.7)", what, setPos));
}

/// The GEOMETRY half of the mesh state: counts, vertex coordinates, face
/// windings and the derived edge list. This is the half the revert below puts
/// back EXACTLY, which is why it is dumped on its own.
private string dumpGeometry(ref Mesh m) {
    import std.format : format;
    string s = format("V=%d F=%d E=%d",
                      m.vertices.length, m.faces.length, m.edges.length);
    // `%a` — the HEX float form, so this compares BITS. `%g` would let a
    // `-0.0`/`+0.0` pair read as equal (task 1903 Stage D2's signed-zero cell).
    foreach (i, v; m.vertices) s ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
    foreach (i, f; m.faces)    s ~= format(" f%d%s", i, f.to!string);
    foreach (i; 0 .. m.edges.length)
        s ~= format(" e%d[%d,%d]", i, m.edges[i][0], m.edges[i][1]);
    return s;
}

/// Everything `dumpGeometry` leaves out: all five mark planes and all three
/// order counters. SEPARATE from the geometry dump on purpose — the revert law
/// measured below is DIFFERENT on the two halves, and one dump spanning both
/// could only ever assert the weaker of them.
///
/// Until Stage E2's review this file dumped `faceMarks` ALONE, on a stand that
/// selected nothing (`recProfileStand`'s note). So "the revert is complete"
/// compared an empty/zero plane with an empty/zero plane on every mark channel
/// and was satisfied by a revert that restores none of them — which, measured,
/// is what this one does.
private string dumpMarkPlanes(ref Mesh m) {
    import std.format : format;
    return format("vm=%s em=%s fm=%s vo=%s eo=%s fo=%s vc=%d ec=%d fc=%d",
                  m.vertexMarks, m.edgeMarks, m.faceMarks,
                  m.vertexSelectionOrder, m.edgeSelectionOrder,
                  m.faceSelectionOrder,
                  m.vertexSelectionOrderCounter, m.edgeSelectionOrderCounter,
                  m.faceSelectionOrderCounter);
}

/// A profile of `n` points, optionally capped into a face so the
/// closed-profile arm has real geometry to inherit its marks from.
///
/// IT SELECTS, and that is load-bearing, not decoration. A real `mesh.sweep`
/// starts FROM a selection — polygon mode requires exactly one selected face
/// and edge mode reads the selected edge chain (`commands/mesh/sweep.d`'s
/// `evaluate`) — and the delta below declares `MeshEditScope.Marks`. On a stand
/// with every mark plane empty or zero, "the revert restored the marks" and
/// "there were no marks" are the same measurement, and a revert that restores
/// none of them answers yes. Measured: take the three lines below out and the
/// marks half of the law in the RECORDING block compares zero with zero on
/// every channel.
private Mesh recProfileStand(size_t n, bool asFace) {
    import std.math : cos, sin, PI;
    Mesh m;
    foreach (k; 0 .. n) {
        float a = 0.4f * PI * cast(float)k / cast(float)(n > 1 ? n - 1 : 1);
        m.addVertex(Vec3(1.0f + 0.5f * cos(a), 0.8f * sin(a), 0.0f));
    }
    if (asFace) {
        uint[] f; foreach (k; 0 .. n) f ~= cast(uint)k;
        m.addFace(f);
        m.resizeSubpatch();
        m.setFaceSubpatch(0, false);
    }
    m.buildLoops();
    // `syncSelection` SIZES the mark planes — they are lazily grown and stay
    // `[]` until something asks for them (tests/unit/mark_view_test.d's own
    // note on exactly this), so without it `selectVertex` has nothing to write
    // into and the dump reads `[]` on both sides of the revert.
    m.syncSelection();
    if (asFace) m.selectFace(0);
    m.selectVertex(1);
    return m;
}

unittest { // revolveProfileEx: BOTH arms record a complete, fully-revertible delta
    import std.format : format;
    foreach (profileClosed; [false, true]) {
        RevolveParams p;
        p.count = 6; p.axis = Vec3(0, 1, 0); p.angle = 6.2831853f;

        Mesh m = recProfileStand(4, profileClosed);
        // STAND CANARY. The marks half of the law at the bottom of this block
        // compares this stand's OWN selection against what survives the revert;
        // with nothing selected it is zero against zero and green whatever the
        // delta records. This asserts the stand, not the code under test, so it
        // can only fire when `recProfileStand` is edited.
        assert(m.isVertexSelected(1) && (!profileClosed || m.isFaceSelected(0)),
            format("closed=%s: recProfileStand selected nothing — the marks "
                 ~ "half of the revert law below would be zero compared with "
                 ~ "zero (task 1903 Stage E2 review, BLOCKER B1)",
                   profileClosed));
        immutable string preGeo    = dumpGeometry(m);
        immutable string prePlanes = dumpMarkPlanes(m);
        immutable size_t preV = m.vertices.length, preF = m.faces.length,
                         preE = m.edges.length;

        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kRevolveEditScope);   // RECORDING
            n = ed.revolveProfileEx([0u, 1u, 2u, 3u], profileClosed, p);
            d = ed.close();
        }

        // Anti-vacuity: this kernel refuses on five separate guards, and a
        // refusal satisfies every assertion below for free.
        immutable size_t want = profileClosed ? 24 : 18;
        assert(n == want,
            format("closed=%s: the stand swept %d faces, expected %d — every "
                 ~ "assertion below would be vacuous on a refusal",
                   profileClosed, n, want));

        assertDeclaredScope(format("revolveProfileEx closed=%s", profileClosed), d);
        assertNoPositionWrite(format("revolveProfileEx closed=%s", profileClosed), d);

        // THE APPEND HOOKS COALESCE, measured — 20 `addVertex` calls become
        // ONE `AddVerts` entry and every `addFace` in the ring loop becomes
        // ONE `AddFaces`. A kernel that appended to `ed.vertices` / `ed.faces`
        // directly (which compiles, through `alias mesh this`) would leave the
        // log empty and these at 0.
        //
        // The count of OTHER entries is deliberately NOT asserted here. "The
        // log is exactly these two" is a statement about what is MISSING — the
        // Marks record — and it belongs with the revert law below, where it
        // carries that message. Asserting it here as well put an unnamed guard
        // in front of that law: a Marks publisher reddened this line first,
        // with a message about `ed.vertices ~= …`, and the marks assertions it
        // exists to protect were never reached (Stage E2 review, BLOCKER B1).
        immutable size_t addV = countKind(d, MeshOpEntry.Kind.AddVerts);
        immutable size_t addF = countKind(d, MeshOpEntry.Kind.AddFaces);
        assert(addV == 1 && addF == 1,
            format("closed=%s: the op-log carries %d AddVerts and %d AddFaces "
                 ~ "entr(ies), expected exactly one of each. The rings must "
                 ~ "arrive through Mesh.addVertex and the bridge/strip quads "
                 ~ "through Mesh.addFace, which are the hooked appenders; a "
                 ~ "bare `ed.vertices ~= …` compiles inside a recording batch "
                 ~ "and records nothing (task 1903 Stage E2).",
                   profileClosed, addV, addF));

        // THE REVERT LAW, MEASURED PLANE BY PLANE — and it is NOT "complete".
        // It used to say complete, on a stand that selected nothing and a dump
        // that carried `faceMarks` alone; both halves of that are fixed above.
        //
        // GEOMETRY comes back bit for bit. This family only APPENDS: it
        // reshapes no surviving face and moves no existing vertex, so
        // AddVerts^-1 + AddFaces^-1 restore the vertex coordinates, the face
        // windings AND the edge list `finalize` re-derives from them.
        //
        // THE MARK PLANES DO NOT COME BACK, and that is the finding. The delta
        // DECLARES `MeshEditScope.Marks` (asserted by `assertDeclaredScope`
        // above) and records NO Marks entry — the op-log is the two append
        // entries and nothing else, zero `SelectionDelta`. So the pre-sweep
        // Select bit on vertex 1 (and on face 0 in the closed arm) is gone
        // after the revert, every plane reads all-zero, `vertexSelectionOrder`
        // and `faceSelectionOrder` with it, and `faceSelectionOrderCounter` is
        // left at `n` — the number of faces the sweep added — instead of its
        // pre-sweep value. A declared class with no record is a REAL gap: it
        // is exactly what `finalize` reads back to decide what to rebuild.
        //
        // Written as EQUALITY against that incomplete state, not as an
        // inequality: a Marks publisher added anywhere on this path restores
        // one of these channels and reddens the line, which is the whole point
        // of pinning a gap. The `SelectionDelta == 0` assertion says the same
        // thing from the op-log side, so a record that is written but does not
        // reach the planes still shows up.
        //
        // STAGE L10 FLIPS THIS. `mesh.sweep` undoes through a whole-mesh
        // `MeshSnapshot` today (plan §5.1), which restores every plane, so the
        // gap is invisible to the user and costs nothing yet. L10 (plan §5.5,
        // the reindexing half of topo-misc) is the stage that makes this delta
        // the undo record, and it cannot ship until the kernel records the
        // Marks it declares. When it does: change `wantPlanes` to `prePlanes`,
        // change the `SelectionDelta == 0` expectation, and delete this note.
        const bool reverted = d.revert(m);
        assert(reverted, format("closed=%s: revert() refused the delta outright",
                                profileClosed));
        assert(m.vertices.length == preV && m.faces.length == preF,
            format("closed=%s: revert restored V=%d F=%d, expected V=%d F=%d",
                   profileClosed, m.vertices.length, m.faces.length, preV, preF));
        assert(dumpGeometry(m) == preGeo,
            format("closed=%s: the GEOMETRY half of the revert is not exact.\n"
                 ~ "  pre : %s\n  post: %s",
                   profileClosed, preGeo, dumpGeometry(m)));

        // The measured post-revert planes, spelled from the PRE-sweep lengths
        // (not re-read off the post state, which would make this compare the
        // measurement with itself) and the added-face count.
        immutable string wantPlanes =
            format("vm=%s em=%s fm=%s vo=%s eo=%s fo=%s vc=0 ec=0 fc=%d",
                   new uint[](preV), new uint[](preE), new uint[](preF),
                   new int[](preV),  new int[](preE),  new int[](preF), n);
        assert(dumpMarkPlanes(m) == wantPlanes,
            format("closed=%s: the MARKS half of the revert changed. It is "
                 ~ "MEASURED as ABSENT — the delta declares Marks and records "
                 ~ "no Marks entry, so every plane comes back all-zero and "
                 ~ "faceSelectionOrderCounter is left at the added-face count "
                 ~ "(%d). If a Marks record was just added, this is the line "
                 ~ "that says so: set the expectation to `prePlanes` and "
                 ~ "delete the gap note above (task 1903 Stage L10).\n"
                 ~ "  pre  : %s\n  want : %s\n  got  : %s",
                   profileClosed, n, prePlanes, wantPlanes, dumpMarkPlanes(m)));
        immutable size_t selDeltas = countKind(d, MeshOpEntry.Kind.SelectionDelta);
        assert(selDeltas == 0 && d.log.length == 2,
            format("closed=%s: the op-log carries %d entr(ies) of which %d are "
                 ~ "SelectionDelta, expected 2 (AddVerts + AddFaces) and 0. "
                 ~ "This is the same gap as the plane comparison above, read "
                 ~ "off the LOG instead of off the mesh, and the two are not "
                 ~ "redundant: a record that is written but not applied on "
                 ~ "revert moves this one and not that one (task 1903 Stage "
                 ~ "L10).",
                   profileClosed, d.log.length, selDeltas));
    }
}

unittest { // extrudeAlongPath: ARMED at Stage K — its revert no longer faults
    import std.format : format;
    import std.conv : to;

    Mesh m = makeCube();
    bool[] mask = new bool[](m.faces.length);
    mask[0] = true;
    Vec3[] path = [Vec3(0, 0, 0), Vec3(0, 0, 0.2f), Vec3(0, 0, 0.4f), Vec3(0, 0, 0.6f)];
    immutable size_t preF = m.faces.length;
    immutable string preGeom  = dumpGeometry(m);
    immutable string preMarks = dumpMarkPlanes(m);

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kRevolveEditScope);   // RECORDING
        n = ed.extrudeAlongPath(mask, path, /*alignToPath*/true);
        d = ed.close();
    }

    assert(n == 12 && m.faces.length == preF + 12,
        format("the stand added %d faces (F %d -> %d), expected 12 — every "
             ~ "assertion below would be vacuous on a refusal",
               n, preF, m.faces.length));

    assertDeclaredScope("extrudeAlongPath", d);
    assertNoPositionWrite("extrudeAlongPath", d);

    // WHAT STAGE K CHANGED HERE, MEASURED 2026-08-27.
    //
    // Until Stage K this block asserted that the op-log carried NO face entry
    // at all: three path spans, 12 vertices cloned and 12 faces created, and
    // the log read `[AddVerts]`. `extrudePathStep_` does not `addFace` — it
    // builds a whole new face array and hands it to
    // `mesh_planes.rewriteFaces`, whose publisher was DISARMED. `revert()` was
    // deliberately NOT called, because it had been measured to un-add the 12
    // cloned vertices while the cap and wall faces still referenced them and
    // to walk straight off the end inside `MeshEditDelta.finalize`'s
    // `buildLoops()`:
    //
    //     core.exception.ArrayIndexError@source/mesh.d(13841):
    //     index [8] is out of bounds for array of length 8
    //
    // That was plan §5.5's L8 BLOCKING PREREQUISITE, and Stage K discharged
    // it: `extrudePathStep_`'s rewrite is now inside its own
    // `faceReindexScope()`, so `mesh.strokeExtrude` can write a delta that
    // survives its own undo. The block now CALLS `revert()`, which is the
    // whole point of the flip.
    //
    // ONE PAIR PER SPAN, and the pairing is what matters rather than the
    // count. `extrudeAlongPath` calls `extrudePathStep_` once per path span,
    // and each call opens its OWN scope, so each face entry gets its own
    // corner payload recorded immediately before it. A `FaceReindex` without
    // an adjacent `MeshMapDelta` makes `CornerCarry` decline on reverse and
    // zero the whole per-corner map — measured on `edge_bevel.bevelEdgesByMask`,
    // which is why that family is NOT armed (plan §5.3).
    immutable size_t faceEntries = countKind(d, MeshOpEntry.Kind.FaceReindex);
    assert(faceEntries == 3,
        format("extrudeAlongPath's op-log carries %d FaceReindex entr(ies), "
             ~ "expected 3 — one per path span. ZERO means "
             ~ "`extrudePathStep_`'s rewrite lost its `faceReindexScope()` and "
             ~ "this family's recorded revert is back to FAULTING out of "
             ~ "buildLoops (task 1903 Stage K, plan §5.5 L8).", faceEntries));
    assert(countKind(d, MeshOpEntry.Kind.AddFaces)     == 0
        && countKind(d, MeshOpEntry.Kind.RemoveFaces)  == 0
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0,
        "extrudeAlongPath's op-log now describes its face change a SECOND "
      ~ "time, beside the FaceReindex entries. Two descriptions of one change "
      ~ "make the LIFO revert overshoot — the double revert the per-rewrite "
      ~ "scope exists to prevent (plan §5.3)");

    immutable size_t addV = countKind(d, MeshOpEntry.Kind.AddVerts);
    assert(addV == 3 && d.log.length == 6,
        format("extrudeAlongPath's op-log carries %d entr(ies), %d of them "
             ~ "AddVerts — expected 6 and 3, i.e. one "
             ~ "[AddVerts, FaceReindex] pair per span. The clone loop must "
             ~ "reach Mesh.addVertex (the hooked appender); a bare "
             ~ "`ed.vertices ~= …` would leave AddVerts at 0. Note the spans "
             ~ "no longer COALESCE into one AddVerts entry, and that is the "
             ~ "arming's doing rather than a change in the clone loop: a "
             ~ "FaceReindex entry now sits between consecutive appends, so "
             ~ "`recordAddVert`'s contiguity test no longer sees the previous "
             ~ "range as the last entry (task 1903 Stage K).",
               d.log.length, addV));

    // THE REVERT. Geometry comes back whole — that is what the arming buys.
    // The marks do NOT, and the dump is deliberately SPLIT so that the weaker
    // half cannot be asserted by the stronger one's comparison (this file's
    // `dumpMarkPlanes` doc comment carries the history of exactly that bug).
    assert(d.revert(m),
        format("revert() refused the armed sweep delta outright — that is a "
             ~ "third state, neither the pre-K fault nor the clean geometry "
             ~ "revert Stage K measured. Log: %d entries", d.log.length));
    assert(dumpGeometry(m) == preGeom,
        format("the armed sweep's revert did not restore the geometry.\n"
             ~ "  pre : %s\n  post: %s", preGeom, dumpGeometry(m)));

    // THE RESIDUAL, asserted as a residual. `extrudeAlongPath` re-selects the
    // cap faces on the way out and clears the vertex selection, both AFTER the
    // rewrite, so no FaceReindex entry could carry them back. This line going
    // red because the marks DID come back is good news and means plan §5.5's
    // L0 Marks publisher has landed — rewrite this block and that row
    // together rather than deleting the line.
    assert(dumpMarkPlanes(m) != preMarks,
        "the armed sweep's revert restored the MARK planes too. Stage K "
      ~ "measured them as still lost (the tail re-selection and "
      ~ "clearVertexSelection run after the rewrite); if L0's Marks publisher "
      ~ "has landed, this assertion becomes `==` and plan §5.5's L8 row moves "
      ~ "with it");
}
