// Module unittests for `subpatch_osd`, moved verbatim out of source/subpatch_osd.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.subpatch_osd_test;

import std.math : sqrt;
import math : Vec3;
import mesh : Mesh, SubpatchTrace, edgeKey, makeCube;
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

    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    SubpatchPreview preview;
    preview.rebuildIfStale(cage, 1, null, false);
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

    // OLD behaviour (positionsDirty=false, the pre-fix default): the
    // (address, mutationVersion, depth) key is unchanged, so the preview
    // stays frozen at the pre-edit shape. Asserting this first proves the
    // repro is real (guards against the test accidentally becoming a
    // no-op if the cube/depth stop triggering the fast path).
    preview.rebuildIfStale(cage, 1, null, false);
    assert(!previewMoved(),
        "sanity: positionsDirty=false must reproduce the historical "
        ~ "stale-preview bug (mutationVersion alone cannot see a "
        ~ "version-silent position edit)");

    // NEW behaviour (positionsDirty=true — what app.d's bus flush now
    // passes whenever meshChangedFlags carries Position this frame):
    // preview must re-derive from the moved cage.
    preview.rebuildIfStale(cage, 1, null, true);
    assert(previewMoved(),
        "task 0401: positionsDirty=true must re-derive the preview from "
        ~ "the moved cage instead of returning the frozen pre-edit shape");

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
