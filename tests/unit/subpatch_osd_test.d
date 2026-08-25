// Module unittests for `subpatch_osd`, moved verbatim out of source/subpatch_osd.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.subpatch_osd_test;
import std.conv : to;

import std.math : sqrt;
import math : Vec3;
import mesh : Mesh, SubpatchTrace, edgeKey, makeCube, MapKind;
import osd.c;
import perf_probe : g_perf, Cat, g_fc, DrawPass;
import subpatch_osd;

// ---------------------------------------------------------------------------
// Round-trip correctness: build a preview from a cube cage at depth 2,
// verify OSD-emitted topology counts match Catmull-Clark expectations,
// then edit a cage vert and ensure refresh() actually moves preview
// verts. Catches regressions in topology emission, trace derivation,
// and the per-frame scatter.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    // makeCube leaves isSubpatch empty; grow it before setSubpatch can
    // actually flip bits (setSubpatch returns early on out-of-range idx).
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 2, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed on uniform cube");

    // Cube → uniform CC depth 2 → 98 verts, 96 quads. Each quad has
    // 4 edges, but every interior edge is shared by 2 quads, so
    // num_edges = (4 * num_faces) / 2 = 192.
    assert(preview.vertices.length == 98);
    assert(preview.faces.length    == 96);
    assert(preview.edges.length    == 192);

    // Vert-origin layout: face/edge points carry uint.max, vert-points
    // (descendants of cage corners) carry their cage vert index. After
    // two CC passes the count of vert-points equals the cage vert
    // count = 8 (each cage vert produces exactly one vert-child per
    // level, recursively).
    int withOrigin = 0;
    foreach (o; trace.vertOrigin)
        if (o != uint.max) ++withOrigin;
    assert(withOrigin == 8,
           "expected 8 vert-points tracing back to cage corners");

    // Face origins are always in [0, num_cage_faces) — every refined
    // face descends from exactly one cage face.
    foreach (o; trace.faceOrigin) assert(o < 6, "face origin out of cage range");

    // Edit a cage vert and refresh — preview should mutate.
    Vec3[] before = preview.vertices.dup;
    cage.vertices[0] = cage.vertices[0] + Vec3(0.5f, 0, 0);
    accel.refresh(cage, preview);

    int moved = 0;
    foreach (i; 0 .. preview.vertices.length) {
        if (preview.vertices[i].x != before[i].x ||
            preview.vertices[i].y != before[i].y ||
            preview.vertices[i].z != before[i].z) ++moved;
    }
    assert(moved > 0, "refresh did not move any preview vert");
}

// ---------------------------------------------------------------------------
// trace.edgeOrigin must index INTO THE CALLER'S cage edge table, not
// OSD's internal edge enumeration. The two can differ — OSD derives
// its edge list from the face-vertex topology and assigns its own
// indices, while vibe3d's cage.edges is `addFace`-ordered.
//
// drawEdges' polygon-edge highlight looks up
//   selectedEdges[edgeOriginGpu[segIdx]]
// where `selectedEdges` is indexed by vibe3d cage edge. If the
// origin chain hands OSD's index through, the wrong cage edges get
// highlighted. Verified topologically at depth 1, where each cage
// edge subdivides into exactly two preview edges that BOTH have
// the same edgeOrigin and BOTH share an endpoint with vertOrigin
// matching one of the cage edge's two cage vertices.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 1, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed");

    // Each cage edge X = (u, v) should produce exactly two preview
    // edges with edgeOrigin == X. Topology after one CC pass: the
    // edge splits at its midpoint M, giving (u, M) and (M, v).
    //   • Both halves have edgeOrigin = X.
    //   • One half's endpoint set contains u (in vertOrigin); the
    //     other half's contains v. M itself has vertOrigin = uint.max
    //     (newly introduced edge-point).
    int[uint] cagePreviewEdgeCount;
    bool[uint] sawCageVertU;   // saw an endpoint with vertOrigin == u
    bool[uint] sawCageVertV;   // saw an endpoint with vertOrigin == v

    foreach (pei, pe; preview.edges) {
        uint origin = pei < trace.edgeOrigin.length
                       ? trace.edgeOrigin[pei] : uint.max;
        if (origin == uint.max) continue;
        assert(origin < cage.edges.length,
               "trace.edgeOrigin out of range for the cage edge table");
        cagePreviewEdgeCount[origin] =
            cagePreviewEdgeCount.get(origin, 0) + 1;

        uint cu = cage.edges[origin][0];
        uint cv = cage.edges[origin][1];
        foreach (vpi; [pe[0], pe[1]]) {
            uint vo = vpi < trace.vertOrigin.length
                       ? trace.vertOrigin[vpi] : uint.max;
            if (vo == cu) sawCageVertU[origin] = true;
            if (vo == cv) sawCageVertV[origin] = true;
        }
    }

    assert(cagePreviewEdgeCount.length == cage.edges.length,
        "expected every cage edge to appear in some preview edge's "
        ~ "edgeOrigin");
    foreach (cei; 0 .. cage.edges.length) {
        uint k = cast(uint)cei;
        assert(cagePreviewEdgeCount[k] == 2,
            "cage edge with vibe3d index in [0..12) should have "
            ~ "exactly 2 preview halves at depth 1");
        assert(sawCageVertU.get(k, false) && sawCageVertV.get(k, false),
            "the two preview halves of a cage edge must between "
            ~ "them touch both of the cage edge's endpoints");
    }
}

// ---------------------------------------------------------------------------
// Selective path: only the marked subset is fed to OSD, so the preview
// contains the OSD-subdivided subset and nothing else. Trace.faceOrigin
// must still point at CAGE face indices (the original 6 cube faces),
// not sub-cage indices.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    cage.buildLoops();
    cage.resizeSubpatch();

    // Mark a single face (cage face 0). The other 5 cage faces stay
    // un-marked and should keep their flat polygonal shape via OSD's
    // crease/corner sharpness.
    cage.setSubpatch(0, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 2, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed on selective cube");

    // Full cube fed to OSD at depth 2 → 6 cage faces × 4² = 96 limit
    // faces. Sharpness flag prevents the un-marked regions from
    // smoothing, but they DO get refined topologically.
    assert(preview.faces.length == 96,
           "selective L2 cube preview should keep all 6 cage faces, "
           ~ "subdivided into 16 quads each = 96 total");

    // trace.subpatch should be true for the 16 quads tracing back to
    // cage face 0, false for the other 80.
    int markedChildren = 0, unmarkedChildren = 0;
    foreach (i, b; trace.subpatch) {
        if (b) ++markedChildren; else ++unmarkedChildren;
    }
    assert(markedChildren   == 16);
    assert(unmarkedChildren == 80);

    // Refresh after a cage edit moves the preview.
    Vec3[] before = preview.vertices.dup;
    cage.vertices[0] = cage.vertices[0] + Vec3(0.5f, 0, 0);
    accel.refresh(cage, preview);
    int moved = 0;
    foreach (i; 0 .. preview.vertices.length) {
        if (preview.vertices[i] != before[i]) ++moved;
    }
    assert(moved > 0, "selective refresh did not move any preview vert");
}

// ---------------------------------------------------------------------------
// catmullClarkOsd — full pass.  One CC on the whole cube cage.
// 8 cage verts / 6 quads → 26 verts / 24 quads / 48 edges, no
// unmarked faces, no widening.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    Mesh refined = catmullClarkOsd(cage);
    assert(refined.vertices.length == 26, "L1 cube → 26 verts");
    assert(refined.faces.length    == 24, "L1 cube → 24 quads");
    assert(refined.edges.length    == 48, "L1 cube → 48 edges");
    foreach (face; refined.faces) assert(face.length == 4, "all quads");
}

// ---------------------------------------------------------------------------
// catmullClarkOsd — selective.  Mark one cube face, refine.  Marked
// face splits into 4 quads (4 face-pt, 4 edge-pt, 4 vert-pt). The 4
// adjacent un-marked side faces each get one OSD edge-point inserted
// into their vert list (T-junction widening) → quads become pentagons.
// The 1 opposite un-marked face stays a quad.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    bool[] mask = new bool[](cage.faces.length);
    mask[0] = true;   // mark cube face 0 only

    Mesh refined = catmullClarkOsd(cage, mask);

    // Faces: 4 sub-quads from face 0 + 4 widened pentagons + 1 unchanged quad
    assert(refined.faces.length == 9,
           "selective L1 cube → 4 sub + 4 widened + 1 unchanged");

    // Count face-vert counts: expect 4 quads + 4 pentagons + 1 quad
    int quads = 0, pentas = 0;
    foreach (face; refined.faces) {
        if (face.length == 4) ++quads;
        else if (face.length == 5) ++pentas;
    }
    assert(quads == 5, "expected 5 quads (4 sub + 1 opposite-face), got "
                       ~ quads.stringof);
    assert(pentas == 4, "expected 4 widened pentagons (one per side face)");
}

// ---------------------------------------------------------------------------
// Task 0401 — SubpatchPreview.rebuildIfStale must not serve a stale
// (pre-edit) preview after a VERSION-SILENT position edit. An interactive
// gizmo Move/Rotate/Scale updates cage vertices via `mesh.noteChange(Position)`
// WITHOUT ever bumping `mutationVersion` — both on drag AND on commit (see
// the warning above `SubpatchPreview.deactivate()` in mesh.d for why that is
// deliberate). Reproduces that exact version-silent path directly (no
// `commitChange`/`++mutationVersion` anywhere) rather than the scripted
// `/api/transform` path, which DOES bump mutationVersion and so cannot see
// this bug (that's why `tests/test_subpatch_move.d` stayed green while the
// interactive gizmo path was broken).
// ---------------------------------------------------------------------------
unittest {
    import mesh : SubpatchPreview;
    import change_bus : MeshEditScope;

    import mesh_dirty : noteMeshChange;

    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    SubpatchPreview preview;
    // TASK 1906 STAGE 2d — the bus feed by hand. `rebuildIfStale` keys on the
    // change bus's per-mesh epoch now, and no `app.d` hub is registered in a
    // unittest binary, so the listener BODY is called directly — the
    // arrangement `mesh_dirty`'s header documents for a headless test. (The
    // subject filter does NOT stop a scratch cage: `g_isDocumentMesh` is
    // UNINSTALLED here and delivery is fail-OPEN, so this cage's own
    // publishers do deliver — they just deliver to nobody. What that costs is
    // the accumulator: a delivery take-and-zeroes it, which is why the two
    // feeds below name a CLASS instead of reading `undeliveredChanges_`.)
    // The address is a stack local, which is safe HERE (unlike the two-cage
    // block further down, which needs two addresses to COLLIDE): this block
    // only needs one address's epoch to hold still across a call and then
    // move, and nothing else runs in between.
    //
    // The seed word is deliberately not asserted non-empty: the FIRST
    // `rebuildIfStale` builds unconditionally (`active` starts false), so this
    // line is a seed, not the signal under test. The signal is the named
    // `MeshEditScope.Position` feed further down.
    noteMeshChange(cast(size_t)&cage, cage.undeliveredChanges_);
    preview.rebuildIfStale(cage, 1);
    assert(preview.active, "preview should activate on a fully-subpatched cube");
    Vec3[] before = preview.mesh.vertices.dup;
    ulong topoVerBefore = cage.topologyVersion;
    ulong mutVerBefore  = cage.mutationVersion;

    // Version-silent edit: exactly what an interactive gizmo drag/commit
    // does — mutate a vertex, note the Position change class, never bump
    // mutationVersion.
    cage.vertices[0] = cage.vertices[0] + Vec3(0.75f, 0, 0);
    cage.noteChange(MeshEditScope.Position);
    assert(cage.mutationVersion == mutVerBefore,
        "test setup must stay version-silent to mirror the gizmo path");

    bool previewMoved() {
        foreach (i; 0 .. preview.mesh.vertices.length)
            if (preview.mesh.vertices[i] != before[i]) return true;
        return false;
    }

    // OLD behaviour — the edit happened but NOBODY WAS TOLD. `noteChange`
    // accumulates and never delivers, and nothing has fed the epoch, so the
    // staleness key is unchanged and the preview stays frozen at the pre-edit
    // shape. Asserting this first proves the repro is real (guards against
    // the test accidentally becoming a no-op if the cube/depth stop
    // triggering the fast path). Under the pre-2d code this arm read
    // `positionsDirty=false`; the sentence it makes is the same one — a
    // signal the consumer never receives cannot invalidate anything, and
    // `mutationVersion` is version-silent on this path.
    preview.rebuildIfStale(cage, 1);
    assert(!previewMoved(),
        "sanity: an unannounced version-silent position edit must reproduce "
        ~ "the historical stale-preview bug (mutationVersion alone cannot see "
        ~ "a version-silent position edit, and no epoch has moved)");

    // NEW behaviour — the SAME edit, delivered. This is what the editor does
    // on every frame of a gizmo drag: the change bus carries `Position` to the
    // hub, the hub advances this mesh's epoch, and the preview re-derives from
    // the moved cage.
    noteMeshChange(cast(size_t)&cage, MeshEditScope.Position);
    preview.rebuildIfStale(cage, 1);
    assert(previewMoved(),
        "task 0401 / task 1906 row 10: a DELIVERED Position change must "
        ~ "re-derive the preview from the moved cage instead of returning the "
        ~ "frozen pre-edit shape");

    // Topology must be untouched by a pure position edit or by the fix:
    // topologyVersion only advances on a Geometry-class change, and the
    // CAGE's own mutationVersion must stay exactly as version-silent as
    // the interactive-gizmo contract requires — the fix must not "solve"
    // staleness by quietly bumping the very counter it was designed
    // around (that would re-trip the transform tool's mutation-boundary
    // poll and cancel an in-session falloff re-grade — see the
    // mutation-boundary note on `Mesh.mutationVersion`'s consumers).
    assert(cage.topologyVersion == topoVerBefore,
        "position-only edit must not bump the cage's topologyVersion "
        ~ "(would spuriously invalidate topology-keyed caches: adjacency "
        ~ "CSR, actcenter clusters, falloff selWeights)");
    assert(cage.mutationVersion == mutVerBefore,
        "rebuildIfStale must not mutate the CAGE's mutationVersion — only "
        ~ "the preview's own internal mesh may bump its own version");
}

// ---------------------------------------------------------------------------
// Task 0833 — the settled-cage precondition inside `catmullClarkOsd`'s
// SELECTIVE arm is LIVE, i.e. it CAN fail, and it stays branch-local.
//
// 0724 placed this assert on the branch rather than at the function entry,
// because the full-refinement arm never touches `cage.edgeIndexMap` and an
// entry-wide assert would refuse a legal whole-cage call on a never-built
// map. That placement is a claim about two different call shapes, so this
// block exercises BOTH against the same stale cage: the mixed call throws,
// the whole-cage call does not.
//
// Legal sequence for the stale cage: `addFaceFast` is the importers' append
// primitive — it fills `edges` from the CALLER's scratch lookup and defers the
// canonical map to a terminal `buildLoops()`. Nothing here writes a private
// field.
//
// What the assert stands in for is silent, not loud: a stale map mis-keys the
// cage-edge → OSD-edge-point table, and the stitched boundary loses its edge
// points — a crack in the limit surface, never an error.
//
// `debug`-wrapped: `assertEdgeMapValid` is a `debug assert`, so this shows the
// guard is live in the builds that CARRY it (dub test / dub build). It is
// stripped from `-release`; the shipped binary has no such guard.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        // Two-quad strip sharing edge (1,2), assembled the way an importer
        // assembles one.
        Mesh cage;
        uint[ulong] scratch;
        cage.vertices = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
            Vec3(2, 0, 0), Vec3(2, 0, 1),
        ];
        cage.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        cage.addFaceFast(scratch, [1u, 4u, 5u, 2u]);
        assert(cage.edges.length == 7,
            "setup: the shared edge must dedup to 7 edges across the strip");
        assert(!cage.edgeMapUsable(),
            "setup: addFaceFast defers the canonical map, so it must read unusable");

        // MIXED cage (face 0 marked, face 1 not) — the arm that stitches OSD
        // output against un-marked cage faces THROUGH the map.
        bool[] mixed = [true, false];
        assertThrown!AssertError(catmullClarkOsd(cage, mixed),
            "the selective arm must refuse a cage whose edgeIndexMap was never "
            ~ "rebuilt -- if this stops throwing, the precondition has become "
            ~ "decoration");

        // ...and the WHOLE-cage call on that same unsettled cage must still
        // work: this is what an entry-wide assert would have wrongly refused,
        // and it is why the check sits on the branch.
        Mesh whole = catmullClarkOsd(cage);
        assert(whole.faces.length > 0,
            "the full-refinement arm reads no edgeIndexMap, so it must accept "
            ~ "an unsettled cage");

        // The mixed call is fine once the caller settles the cage, so the
        // assert discriminates between two states rather than refusing the arm.
        cage.buildLoops();
        assert(cage.edgeMapUsable(), "setup: buildLoops must restore the map");
        Mesh refined = catmullClarkOsd(cage, mixed);
        assert(refined.faces.length > 0,
            "the selective arm must produce a stitched result on a settled cage");
    }
}

// ---------------------------------------------------------------------------
// Task 0833 — the twin precondition inside `OsdAccel.buildPreview`'s
// mixed-cage arm is LIVE too, and is reached through a DIFFERENT door: the
// per-face Subpatch bits rather than a caller-supplied face mask.
//
// Same silent-failure shape as its `catmullClarkOsd` twin: a stale map
// mis-attributes the marked/un-marked adjacency counts, so the INF-crease set
// comes out wrong and the preview smooths across a boundary it was supposed to
// hold sharp. A wrong limit surface, never an error.
//
// `debug`-wrapped for the same reason as every block in this family — the
// guard exists only in builds that keep `debug assert`.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        Mesh cage;
        uint[ulong] scratch;
        cage.vertices = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
            Vec3(2, 0, 0), Vec3(2, 0, 1),
        ];
        cage.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        cage.addFaceFast(scratch, [1u, 4u, 5u, 2u]);
        cage.resizeSubpatch();
        cage.setFaceSubpatch(0, true);    // MIXED: face 1 stays un-marked
        assert(cage.isFaceSubpatch(0) && !cage.isFaceSubpatch(1),
            "setup: the cage must be mixed for the crease arm to run");
        assert(!cage.edgeMapUsable(),
            "setup: the Subpatch write must not have settled the map");

        OsdAccel      accel;
        Mesh          preview;
        SubpatchTrace trace;
        assertThrown!AssertError(accel.buildPreview(cage, 2, preview, trace),
            "buildPreview's mixed-cage arm must refuse a cage whose "
            ~ "edgeIndexMap was never rebuilt -- if this stops throwing, the "
            ~ "precondition has become decoration");

        cage.buildLoops();
        assert(cage.edgeMapUsable(), "setup: buildLoops must restore the map");
        Mesh          preview2;
        SubpatchTrace trace2;
        assert(accel.buildPreview(cage, 2, preview2, trace2),
            "the same mixed-cage preview must build once the cage is settled");
        assert(preview2.faces.length > 0,
            "a settled mixed cage must yield a non-empty preview");
    }
}

// ---------------------------------------------------------------------------
// Task 1062 review (NIT 8) — a UNIFORM (fully-marked) importer-shaped cage
// that merely HAS the reserved crease map registered, every entry at 0.0,
// must NOT hit the settled-cage precondition above at all.
//
// Before the fix, `creaseMapLive` was `creaseMap !is null` — true the
// instant the map OBJECT exists, regardless of its contents — so
// `anyUnmarked || creaseMapLive` widened to catch a cage that pre-1062
// never ran this precondition at all (a fully-marked cage with no crease
// map skips the guarded block entirely). An all-zero map contributes
// nothing to the sharpness vector either way, so this was a NEW failure
// mode for an input class that behaves identically to "no crease at all".
//
// `debug`-wrapped for the same reason as the block above.
// ---------------------------------------------------------------------------
unittest {
    debug {
        Mesh cage;
        uint[ulong] scratch;
        cage.vertices = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
            Vec3(2, 0, 0), Vec3(2, 0, 1),
        ];
        cage.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        cage.addFaceFast(scratch, [1u, 4u, 5u, 2u]);
        cage.resizeSubpatch();
        cage.setFaceSubpatch(0, true);
        cage.setFaceSubpatch(1, true);   // UNIFORM: every face marked
        assert(!cage.edgeMapUsable(),
            "setup: the Subpatch write must not have settled the map");

        // Register the reserved crease map WITHOUT settling the cage first
        // -- addMeshMapOfKind only needs edges.length, which addFaceFast
        // already grew.
        auto crease = cage.addMeshMapOfKind(MapKind.creaseWeight);
        assert(crease !is null);
        assert(crease.data.length == cage.edges.length);
        foreach (w; crease.data) assert(w == 0.0f, "setup: map is all-zero");

        OsdAccel      accel;
        Mesh          preview;
        SubpatchTrace trace;
        assert(accel.buildPreview(cage, 2, preview, trace),
            "a uniform cage with an all-zero crease map must build WITHOUT "
          ~ "the settled-cage precondition running at all -- an all-zero "
          ~ "map contributes nothing, identically to having no crease map");
        assert(preview.faces.length > 0);
    }
}

// ---------------------------------------------------------------------------
// Task 0833, cache half — `SubpatchPreview.rebuildIfStale`'s
// (sourceMeshAddr, geometry epoch, mutationVersion, depth) key must not let
// two DIFFERENT cages at an equal (epoch, version) pair alias.
//
// This is the class that has already produced a live bug in this tree: two
// same-version layers aliased in the version-keyed caches until a per-mesh-
// address term went into the key. So unlike the `assert*Valid` guards above,
// the stale read here is not hypothetical — it is what the address term was
// added to stop, and this constructs it.
//
// The production sequence is a layer switch: `Layer` holds its own `Mesh`, so
// the primary's address changes when the primary changes, while both meshes
// can trivially sit at the same `mutationVersion` (two cubes; or an undo that
// walks a background layer back onto a version another layer also holds).
// Nothing but the address separates them here — same topology, same depth,
// same version, same vertex count — which is exactly what makes the term's
// removal observable.
//
// NOT `debug`-wrapped, unlike the guard blocks: this is a live cache key, not
// a `debug assert`. It holds in every build, release included.
// ---------------------------------------------------------------------------
unittest {
    import mesh : SubpatchPreview;
    import std.conv : to;
    import std.math : fabs;

    import mesh_dirty : g_geomEpochs;

    static Mesh* subpatchedCube(float dx) {
        // HEAP, not a stack local, and that is stage 2c's lesson rather than
        // style: the epoch table is process-global and keyed by RAW ADDRESS,
        // and neighbouring unit blocks in this same binary write it. A stack
        // local can reuse an address a neighbour already noted, which would
        // give the two cages DIFFERENT epochs — the epoch term would then
        // refuse first and the address term, the entire subject of this block,
        // would go untested.
        Mesh* c = new Mesh;
        *c = makeCube();
        c.resizeSubpatch();
        foreach (fi; 0 .. c.faces.length) c.setSubpatch(fi, true);
        // Direct position write — no commitChange, so the two cages stay at
        // the SAME mutationVersion. (A gizmo drag is version-silent in exactly
        // this way; see the task-0401 block above.)
        foreach (ref v; c.vertices) v = v + Vec3(dx, 0, 0);
        return c;
    }

    Mesh* cageA = subpatchedCube(0.0f);
    Mesh* cageB = subpatchedCube(10.0f);
    // BOTH freshness terms must collide, or the one that does not would refuse
    // first and the address term — the entire subject of this block — would go
    // untested. They collide for two different reasons and both are asserted:
    // the epoch because neither cage is Document-owned (so neither is in the
    // table and both read its `evicted_` floor), the version because
    // `subpatchedCube` runs the identical sequence of committing calls on each
    // and then writes positions directly, without a commit.
    assert(g_geomEpochs.epochFor(cast(size_t)cageA)
        == g_geomEpochs.epochFor(cast(size_t)cageB),
        "setup: the two cages must collide on the bus geometry epoch");
    assert(cageA.mutationVersion == cageB.mutationVersion,
        "setup: the two cages must collide on mutationVersion too — that pair "
        ~ "of collisions IS the hazard, and with one layer it was invisible");
    assert(cageA.vertices.length == cageB.vertices.length,
        "setup: equal vertex counts, so no other key term separates them");

    static float centroidX(const ref Mesh m) {
        float sx = 0;
        foreach (v; m.vertices) sx += v.x;
        return m.vertices.length ? sx / m.vertices.length : 0;
    }

    SubpatchPreview preview;
    preview.rebuildIfStale(*cageA, 1);
    assert(preview.active, "setup: a fully-subpatched cube must activate");
    assert(fabs(centroidX(preview.mesh)) < 0.5f,
        "setup: cage A's preview must sit at the origin, got "
        ~ centroidX(preview.mesh).to!string);

    // The switch. Only the SOURCE ADDRESS differs from the previous call.
    preview.rebuildIfStale(*cageB, 1);
    assert(fabs(centroidX(preview.mesh) - 10.0f) < 0.5f,
        "a second cage at the SAME bus epoch, the SAME mutationVersion and the "
        ~ "same depth must re-derive the preview, not serve the first cage's — "
        ~ "got centroid x " ~ centroidX(preview.mesh).to!string
        ~ "; the (address, epoch, version, depth) key has lost its address "
        ~ "term and two same-stamp layers are aliasing again");
}

// ---------------------------------------------------------------------------
// TASK 1906 STAGE 2d — A SELECTION CLICK MUST COST THE SUBPATCH PREVIEW
// NOTHING, and this is the block that says so.
//
// The stage first keyed the preview's freshness half on an ANY-CLASS bus
// watcher, on the reading that `commitChange` bumps `mutationVersion` for
// every class, so "any class" reproduced the invalidation set the counter
// already had. It does not. `Mesh.noteSelectionChange` — the funnel under
// every marks setter, and therefore under every pick — ORs in `Marks` and
// deliberately bumps NO version, and the setter's own DELIVERY hands that
// `Marks` word straight to the epoch table. So an any-class epoch
// moves on a plain selection click and the preview re-evaluates: with a live
// preview that is the OSD stencil evaluate plus the VBO fan-out, per picking
// frame, where the cost had been exactly zero.
//
// THE MUTATION THIS BLOCK REDDENS: re-key `SubpatchPreview.stampSourceEpoch`
// and `rebuildIfStale` onto a `forClasses(uint.max)` watcher (or drop
// `sourceVersion` and widen `g_geomEpochs`'s mask to `uint.max`). Measured on
// this fixture before the split key: work delta 6 over 6 clicks.
//
// The work counter is the PREVIEW mesh's own `mutationVersion`: every path
// out of `rebuildIfStale` that does work bumps it — the position-only fast
// path, the reusable-preview resurrection and the full rebuild alike — so a
// delta of 0 means no path ran, not merely that no full rebuild did.
//
// ANTI-VACUITY, because "nothing happened" is what a broken rig also reports:
// the second half publishes a version-silent `Position` exactly as a gizmo
// drag frame does and requires the work counter to MOVE. Without it this
// block would pass over a preview that had gone inert, a cage that never
// activated, or a `noteMeshChange` nobody wired up.
// ---------------------------------------------------------------------------
unittest {
    import mesh       : Mesh, SubpatchPreview, makeCube;
    import mesh_dirty : noteMeshChange;
    import change_bus : MeshEditScope, changeBus;
    import std.conv   : to;

    // HEAP, for the reason the block above states: the epoch table is keyed by
    // raw address and neighbouring unit blocks in this binary write it.
    Mesh* cage = new Mesh;
    *cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    cage.resetSelection();

    SubpatchPreview sp;
    noteMeshChange(cast(size_t)cage, MeshEditScope.Geometry);
    sp.rebuildIfStale(*cage, 1);
    assert(sp.active, "setup: a fully-subpatched cube must activate");

    const ulong work0 = sp.mesh.mutationVersion;
    const ulong mv0   = cage.mutationVersion;

    // Six picking frames. `selectVertex` is a marks setter: it goes through
    // `noteSelectionChange`, which ORs in `Marks` and bumps no version, and
    // since stage 3 the setter itself DELIVERS that word.
    //
    // THE FEED NAMES THE CLASS, AND THAT IS A CORRECTION (review of stage 3,
    // M2). It used to read `cage.undeliveredChanges_` — "byte-for-byte what
    // app.d's per-layer feed hands the listener". Both halves of that sentence
    // died at stage 3: the per-layer feed is gone, and the accumulator it read
    // is TAKEN AND ZEROED by the setter's own delivery one line earlier. So
    // the rig was handing the epoch table a ZERO on all six iterations and
    // the assertion below was free. Verified: an
    // `assert(cage.undeliveredChanges_ != 0)` inserted at the old feed reddens
    // on iteration 1.
    //
    // `Marks` is not a guess about what the setter publishes — the assert
    // inside the loop reads it off the DELIVERY the bus was actually handed,
    // so a setter that changed its class desyncs loudly instead of silently.
    foreach (i; 0 .. 6) {
        const ulong deliveriesBefore = changeBus.deliveryCount;
        cage.selectVertex(cast(uint)i);
        assert(changeBus.deliveryCount == deliveriesBefore + 1
            && changeBus.lastDeliverySubject == cast(size_t)cage
            && changeBus.lastDeliveryFlags == MeshEditScope.Marks,
            "RIG: `selectVertex` must be a delivering publisher of exactly "
            ~ "`Marks` for THIS cage — the feed below hands the epoch table "
            ~ "that class by name, and this is what keeps the name honest");
        noteMeshChange(cast(size_t)cage, MeshEditScope.Marks);
        sp.rebuildIfStale(*cage, 1);
    }
    assert(cage.mutationVersion == mv0,
        "setup: the clicks must stay VERSION-SILENT, or the `mutationVersion` "
        ~ "term would legitimately invalidate and this block would be testing "
        ~ "nothing about the epoch's mask");
    assert(sp.mesh.mutationVersion == work0,
        "task 1906 stage 2d: six version-silent SELECTION clicks must cost the "
        ~ "subpatch preview ZERO work — `Marks` is not in `g_geomEpochs`'s mask "
        ~ "and no version moved. Got a work delta of "
        ~ (sp.mesh.mutationVersion - work0).to!string
        ~ ": the freshness key has been widened to an any-class watcher and "
        ~ "every pick now runs the OSD stencil evaluate plus the VBO fan-out");

    // ANTI-VACUITY: the same rig, the same call, a class that IS in the mask.
    foreach (ref v; cage.vertices) v = v + Vec3(0.01f, 0, 0);
    noteMeshChange(cast(size_t)cage, MeshEditScope.Position);
    sp.rebuildIfStale(*cage, 1);
    assert(sp.mesh.mutationVersion != work0,
        "anti-vacuity: a version-silent POSITION publish — one gizmo drag "
        ~ "frame — MUST make the preview work. If this does not move, the "
        ~ "zero above is satisfied by a preview that went inert, and task "
        ~ "0401's whole fix is gone with it");
}

// ---------------------------------------------------------------------------
// M-GL (task 1500) — the seam between the pure build and the GL install is
// INSTRUMENTED, not merely documented.
//
// TWO HALVES, and both are needed. The first is the one that reddens under
// the mutation the task names ("move `installGl` into the body of
// `buildFromSnapshot`"): the pure half has to run clean on a thread with no
// GL context. The second pins that the guard is ARMED at all — without it the
// first half would stay green even if GL calls did migrate, because an
// off-thread GL call is a driver-dispatch SIGSEGV or a silent no-op, not a
// catchable failure. Together they say: the pure half throws nothing, the GL
// half throws GL-OFF-MAIN-THREAD by name.
//
// `g_osdGpuEnabled` is false under `dub test` (no context was ever probed),
// so `installGl`'s body would be nearly inert anyway — which is exactly why
// the assertion is on the GUARD's throw and not on a GL side effect.
unittest {
    import core.thread : Thread;
    import gl_thread_guard : markMainThread, clearMainThreadForTest,
                             muteGlThreadGuardForTest, GlThreadError;
    import std.algorithm : canFind;

    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    // Heap-allocated so the worker closure captures a pointer rather than a
    // stack frame holding a struct with a destructor.
    auto accel = new OsdAccel;
    scope(exit) { accel.clear(); accel.destroyCache(); }

    auto snap = new CageSnapshot;
    takeCageSnapshot(cage, 1, *snap);

    markMainThread();
    scope(exit) clearMainThreadForTest();

    // ---- half 1: the PURE build runs clean off the GL thread -------------
    string buildErr;
    bool   buildOk;
    auto res = new PreviewBuildResult;
    {
        auto t = new Thread({
            try { buildOk = accel.buildFromSnapshot(*snap, *res); }
            catch (Throwable e) { buildErr = e.msg; }
        });
        t.start();
        t.join();
    }
    assert(buildErr.length == 0,
        "buildFromSnapshot must contain no GL call — it runs on the worker "
        ~ "thread: " ~ buildErr);
    assert(buildOk, "the off-thread cube build must succeed");
    assert(res.mesh.faces.length == 24,
        "cube at level 1 gives 24 limit quads, got "
        ~ res.mesh.faces.length.to!string);

    // ---- half 2: the GL install is guarded, by name ----------------------
    string glErr;
    muteGlThreadGuardForTest(true);
    {
        auto t = new Thread({
            try { accel.installGl(*res, res.mesh, res.trace); }
            catch (GlThreadError e) { glErr = e.msg; }
            catch (Throwable e)     { glErr = "WRONG-ERROR:" ~ e.msg; }
        });
        t.start();
        t.join();
    }
    muteGlThreadGuardForTest(false);
    assert(glErr.canFind("funnel=OsdAccel.installGl"),
        "installGl off the GL thread must name its funnel; got: " ~ glErr);

    // The build owns a topology nobody installed — give it back, or this
    // unittest is itself the leak M-LEAK is about.
    accel.retireResult(*res);
}

// ---------------------------------------------------------------------------
// M-RESET (task 1500) — BOTH destructive primitives wait for the builder.
//
// `destroyCache()` is the load-bearing one: it calls `osdc_topology_destroy`
// on the LRU's slots, and a build that HIT the cache is reading exactly one of
// them, borrowed. Without the join that is a use-after-free inside
// OpenSubdiv, on a thread whose stack names nothing about the reset that
// caused it. `clear()` is the construction guarantee — after the 1500 split it
// frees nothing the worker still reads, and it carries the hook so that the
// NEXT reset path added to this class is safe without its author having heard
// of the worker thread.
//
// THE ASSERTION IS AN ORDERING ONE, not a counter one: a counter incremented
// at the only site that writes it proves nothing. A stand-in builder takes
// 200 ms; the primitive must not return before it has finished. Delete either
// hook call and the matching half returns in microseconds and fails.
unittest {
    import core.thread : Thread;
    import core.time   : msecs;
    import core.atomic : atomicLoad, atomicStore;

    void requireJoin(string which, void delegate(OsdAccel*) call) {
        auto accel = new OsdAccel;
        shared bool builderFinished = false;
        auto builder = new Thread({
            Thread.sleep(200.msecs);
            atomicStore(builderFinished, true);
        });
        accel.joinInFlightHook = () { builder.join(); };
        builder.start();

        call(accel);

        assert(atomicLoad(builderFinished),
            "OsdAccel." ~ which ~ " returned while a build was still running "
            ~ "— everything it frees or nulls is something the builder may "
            ~ "still be reading");
        accel.joinInFlightHook = null;
    }

    requireJoin("clear()",        (OsdAccel* a) { a.clear(); });
    requireJoin("destroyCache()", (OsdAccel* a) { a.destroyCache(); });
}

// ---------------------------------------------------------------------------
// M-DET-SHAPE (task 1500) — the input barrier reads STATE, and it is BOUNDED.
//
// The end-to-end rows in tests/test_subpatch_async_preview.d exercise this
// through the whole app; this one pins its shape directly, which is the half
// that would otherwise be provable only by reading the source: the gate is a
// function of `buildPending` and elapsed wall time, not a constant, and past
// `ceilingMs` it OPENS rather than holding forever.
//
// A gate that could not open is the failure this is aimed at: a build wedged
// inside OpenSubdiv's stencil builder would take the recorded-input lane with
// it, and the correct degraded answer (the cage) is already available.
unittest {
    import mesh      : SubpatchPreview;
    import core.time : MonoTime, dur;

    SubpatchPreview sp;
    assert(!sp.scriptedInputHeld(),
        "with no build in flight the barrier must never hold");

    sp.buildPending = true;
    sp.ceilingMs    = 10_000;
    sp.buildStarted = MonoTime.currTime;
    assert(sp.scriptedInputHeld(),
        "a build in flight inside the ceiling must hold recorded input");

    // Same state, one field moved: the barrier opens. This is what makes it
    // bounded rather than a promise that it is.
    sp.ceilingMs = 1;
    sp.buildStarted = MonoTime.currTime - dur!"msecs"(50);
    assert(!sp.scriptedInputHeld(),
        "past its ceiling the barrier must deliver the input anyway");

    sp.buildPending = false;
    assert(!sp.scriptedInputHeld());
}
