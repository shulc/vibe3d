/// OpenSubdiv evaluator integration for vibe3d's SubpatchPreview.
///
/// Two roles:
///   1. `benchOsdJson` — HTTP-exposed benchmark that times OSD's
///      stencil eval against vibe3d's own catmullClark recursion.
///   2. `OsdAccel` — the production back-end SubpatchPreview uses for
///      every uniform-CC subdivision (all cage faces marked
///      `isSubpatch`). Builds OSD topology + stencil table once per
///      cage-topology change, emits the limit Mesh + SubpatchTrace
///      directly, then refresh()es per-frame in one SpMV.
///
/// Selective subpatch (some faces marked, others not) stays on the
/// recursive vibe3d path — OpenSubdiv subdivides every face, so the
/// stitching of refined-vs-unrefined subsets falls to vibe3d's
/// catmullClarkSelected.
module subpatch_osd;

import std.datetime.stopwatch : StopWatch;
import std.format             : format;
import math                   : Vec3;
import mesh                   : Mesh, SubpatchTrace, catmullClark, makeCube, edgeKey;
import osd.c;

/// Build a synthetic cage by Catmull-Clark-refining a unit cube `pre`
/// times. preLevel=0 → 8 verts / 6 faces, =1 → 26 / 24, =2 → 98 / 96,
/// =3 → 386 / 384, =4 → 1538 / 1536. Useful as a deterministic
/// benchmark input so numbers are reproducible across runs.
Mesh syntheticCage(int preLevel) {
    Mesh m = makeCube();
    foreach (_; 0 .. preLevel) m = catmullClark(m);
    return m;
}

/// Bench OSD stencil eval against vibe3d's catmullClark recursion for
/// the same cage and the same target depth. Both produce limit
/// positions; OSD's path is "build stencils once, SpMV per frame", and
/// vibe3d's is "recurse depth times per frame". Returns JSON suitable
/// for HTTP responses.
///
/// `iters` controls how many OSD eval iterations to time (averaged).
/// One warm-up call is run before the timed loop so the first eval's
/// cold-cache cost doesn't pollute the average.
string benchOsdJson(ref const Mesh cage, int level, int iters)
{
    immutable int nv = cast(int)cage.vertices.length;
    immutable int nf = cast(int)cage.faces.length;

    // Flatten cage topology into the contiguous int arrays OSD wants.
    int[] faceVertCounts = new int[](nf);
    int[] faceVertIndices;
    foreach (fi, face; cage.faces) {
        faceVertCounts[fi] = cast(int)face.length;
        foreach (vi; face) faceVertIndices ~= cast(int)vi;
    }
    float[] cageXyz = new float[](3 * nv);
    foreach (vi, v; cage.vertices) {
        cageXyz[3*vi + 0] = v.x;
        cageXyz[3*vi + 1] = v.y;
        cageXyz[3*vi + 2] = v.z;
    }

    StopWatch sw;

    // ---- OSD: topology + stencil-table build ---------------------------
    sw.start();
    auto topo = osdc_topology_create(
        nv, nf,
        faceVertCounts.ptr, faceVertIndices.ptr,
        level);
    sw.stop();
    double osdBuildMs = sw.peek.total!"nsecs" / 1e6;
    if (topo is null) {
        return `{"error":"osdc_topology_create returned null","cage":` ~
               format(`{"verts":%d,"faces":%d}}`, nv, nf);
    }
    scope (exit) osdc_topology_destroy(topo);

    immutable int osdLimitVerts = osdc_topology_limit_vert_count(topo);
    immutable int osdLimitFaces = osdc_topology_limit_face_count(topo);

    // ---- OSD: average eval cost ----------------------------------------
    auto limitXyz = new float[](3 * osdLimitVerts);
    osdc_evaluate(topo, cageXyz.ptr, limitXyz.ptr);   // warm-up
    sw.reset();
    sw.start();
    foreach (_; 0 .. iters)
        osdc_evaluate(topo, cageXyz.ptr, limitXyz.ptr);
    sw.stop();
    double osdEvalAvgMs = sw.peek.total!"nsecs" / 1e6 / iters;

    // ---- vibe3d: recursive catmullClark for the same depth -------------
    // First refinement seeds `refined` from `cage` (Mesh holds slices,
    // so `Mesh refined = cage;` would alias and fail the const cast —
    // catmullClark returns a fresh value-mesh, side-stepping that).
    sw.reset();
    sw.start();
    Mesh refined = catmullClark(cage);
    foreach (_; 1 .. level)
        refined = catmullClark(refined);
    sw.stop();
    double vibe3dRefineMs = sw.peek.total!"nsecs" / 1e6;
    immutable int vibe3dLimitVerts = cast(int)refined.vertices.length;
    immutable int vibe3dLimitFaces = cast(int)refined.faces.length;

    immutable double speedup =
        osdEvalAvgMs > 0 ? vibe3dRefineMs / osdEvalAvgMs : 0.0;

    return format(
        `{"level":%d,"iters":%d,`
        ~ `"cage":{"verts":%d,"faces":%d},`
        ~ `"osd":{"buildMs":%.3f,"evalAvgMs":%.3f,"limitVerts":%d,"limitFaces":%d},`
        ~ `"vibe3d":{"refineMs":%.3f,"limitVerts":%d,"limitFaces":%d},`
        ~ `"speedupVsVibe3d":%.2f}`,
        level, iters,
        nv, nf,
        osdBuildMs, osdEvalAvgMs, osdLimitVerts, osdLimitFaces,
        vibe3dRefineMs, vibe3dLimitVerts, vibe3dLimitFaces,
        speedup);
}

// ---------------------------------------------------------------------------
// OsdAccel — SubpatchPreview back-end built on OpenSubdiv.
//
// Drives both subpatch cases:
//
//   Uniform   — every cage face marked `isSubpatch`. OSD subdivides the
//               whole cage; the preview is the limit surface.
//
//   Selective — only some cage faces marked. We extract the marked
//               subset (faces + their incident verts) as a standalone
//               sub-cage, feed THAT to OSD, and the preview contains
//               only the subdivided subset. Non-subpatch faces don't
//               appear in the preview at all — this is the explicit
//               trade-off the user requested ("subdiv выделенных
//               полигонов, как будто других и не существует") to keep
//               the back-end uniform: OSD has no per-face skip mode,
//               and stitching refined / unrefined surfaces is what
//               vibe3d's old catmullClarkSelected did on CPU. Behaviour
//               will differ from that path.
//
// `buildPreview` owns the topology generation; `refresh` is the per-
// drag-frame call that only restamps positions. The OSD handle and
// the sub-cage → cage index map stay cached across drag events. Cage-
// topology change → SubpatchPreview drops the OsdAccel and re-runs
// `buildPreview` on the new mask.
// ---------------------------------------------------------------------------
struct OsdAccel {
    private osdc_topology_t* osd;
    private float[]  cageScratchXyz;    // tightly-packed sub-cage positions
    private uint[]   subToCage;          // sub-cage vi → cage vi
    bool valid;

    /// Free the OSD handle and reset state. Idempotent.
    void clear() {
        if (osd !is null) {
            osdc_topology_destroy(osd);
            osd = null;
        }
        cageScratchXyz.length = 0;
        subToCage.length      = 0;
        valid                 = false;
    }

    /// Free OSD resources at scope exit. The struct is owned by
    /// SubpatchPreview, which lives for the program's duration, so this
    /// fires once — but it keeps `dub test` (and any future short-lived
    /// SubpatchPreview instances) leak-clean.
    ~this() { clear(); }

    /// Build OSD topology + stencil table from the subpatch-marked
    /// subset of `cage` at `level`, then emit the limit Mesh
    /// (verts/edges/faces/loops) and SubpatchTrace directly from OSD's
    /// output. Caches the OSD handle and sub-cage → cage map so
    /// subsequent `refresh` calls run a single SpMV against the cage's
    /// new positions.
    ///
    /// Returns false (and clears state) when no cage face is subpatch-
    /// marked or OSD topology creation fails on the resulting sub-cage.
    bool buildPreview(ref const Mesh cage, int level,
                       out Mesh outMesh, out SubpatchTrace outTrace)
    {
        clear();

        immutable int nv = cast(int)cage.vertices.length;
        immutable int nf = cast(int)cage.faces.length;
        if (nv == 0 || nf == 0 || level < 1) return false;

        // ---- Identify the subpatch-marked subset ---------------------
        // Build sub-cage verts (subToCage[] / cageToSub[]) and faces
        // (sub-cage vert space). cage.isSubpatch may be shorter than
        // cage.faces if a Mesh hasn't normalised its mask — treat
        // missing entries as `false`.
        int[] cageToSub = new int[](nv);
        cageToSub[] = -1;
        int subNumVerts = 0;
        int subNumFaces = 0;
        int subTotalIndices = 0;
        foreach (fi; 0 .. nf) {
            immutable bool marked =
                (fi < cage.isSubpatch.length) && cage.isSubpatch[fi];
            if (!marked) continue;
            ++subNumFaces;
            subTotalIndices += cast(int)cage.faces[fi].length;
            foreach (cvi; cage.faces[fi]) {
                if (cageToSub[cvi] == -1) {
                    cageToSub[cvi] = subNumVerts;
                    subToCage ~= cvi;
                    ++subNumVerts;
                }
            }
        }
        if (subNumFaces == 0 || subNumVerts == 0) { clear(); return false; }

        // Per-cage-face index of each sub-face — feeds trace.faceOrigin.
        int[] subToCageFace = new int[](subNumFaces);
        int[] subFaceVertCounts  = new int[](subNumFaces);
        int[] subFaceVertIndices = new int[](subTotalIndices);
        {
            int faceCursor = 0;
            int idxCursor  = 0;
            foreach (fi; 0 .. nf) {
                immutable bool marked =
                    (fi < cage.isSubpatch.length) && cage.isSubpatch[fi];
                if (!marked) continue;
                subToCageFace[faceCursor] = cast(int)fi;
                subFaceVertCounts[faceCursor] = cast(int)cage.faces[fi].length;
                foreach (cvi; cage.faces[fi])
                    subFaceVertIndices[idxCursor++] = cageToSub[cvi];
                ++faceCursor;
            }
        }

        // ---- Sub-cage positions in OSD's contiguous float[] format ---
        cageScratchXyz.length = 3 * subNumVerts;
        foreach (svi, cvi; subToCage) {
            Vec3 v = cage.vertices[cvi];
            cageScratchXyz[3*svi + 0] = v.x;
            cageScratchXyz[3*svi + 1] = v.y;
            cageScratchXyz[3*svi + 2] = v.z;
        }

        // ---- Build OSD topology + stencil table on the sub-cage -----
        osd = osdc_topology_create(
            subNumVerts, subNumFaces,
            subFaceVertCounts.ptr, subFaceVertIndices.ptr,
            level);
        if (osd is null) { clear(); return false; }

        immutable int limitVerts   = osdc_topology_limit_vert_count(osd);
        immutable int limitFaces   = osdc_topology_limit_face_count(osd);
        immutable int limitIndices = osdc_topology_limit_index_count(osd);
        immutable int limitEdges   = osdc_topology_limit_edge_count(osd);

        // ---- Read OSD limit topology + origin / input-edge arrays ----
        int[] faceCounts     = new int[](limitFaces);
        int[] faceIndices    = new int[](limitIndices);
        int[] edgeVertsRaw   = new int[](2 * limitEdges);
        osdc_topology_limit_topology(osd, faceCounts.ptr, faceIndices.ptr);
        osdc_topology_limit_edges   (osd, edgeVertsRaw.ptr);

        int[] faceOriginsRaw = new int[](limitFaces);
        int[] vertOriginsRaw = new int[](limitVerts);
        int[] edgeOriginsRaw = new int[](limitEdges);
        osdc_topology_face_origins(osd, faceOriginsRaw.ptr);
        osdc_topology_vert_origins(osd, vertOriginsRaw.ptr);
        osdc_topology_edge_origins(osd, edgeOriginsRaw.ptr);

        // OSD's `edge_origins[i]` is a sub-cage edge index. To map it
        // to a cage edge index we walk OSD's input-edge endpoint list,
        // translate sub-cage verts → cage verts via subToCage, then
        // look up the cage edge through cage's edgeIndexMap. Cage edge
        // lookup needs `buildLoops()` to have been run on `cage`
        // beforehand (which vibe3d does after every cage mutation).
        immutable int inputEdgeCount = osdc_topology_input_edge_count(osd);
        int[] inputEdgeVerts = new int[](2 * inputEdgeCount);
        osdc_topology_input_edges(osd, inputEdgeVerts.ptr);

        uint[] subEdgeToCageEdge = new uint[](inputEdgeCount);
        foreach (se; 0 .. inputEdgeCount) {
            uint sv0 = cast(uint)inputEdgeVerts[2*se + 0];
            uint sv1 = cast(uint)inputEdgeVerts[2*se + 1];
            uint cv0 = subToCage[sv0];
            uint cv1 = subToCage[sv1];
            if (auto p = edgeKey(cv0, cv1) in cage.edgeIndexMap)
                subEdgeToCageEdge[se] = *p;
            else
                subEdgeToCageEdge[se] = uint.max;
        }

        // ---- Build preview Mesh.vertices via direct stencil eval -----
        // Vec3 is { float x, y, z; } — 12 bytes tightly packed, so the
        // backing array can be reinterpreted as a tightly-packed float
        // stream. Eval writes straight into preview.vertices' backing
        // memory: no copy, no permutation, no intermediate buffer.
        outMesh.vertices = new Vec3[](limitVerts);
        osdc_evaluate(osd, cageScratchXyz.ptr,
                      cast(float*)outMesh.vertices.ptr);

        // ---- Build preview Mesh.edges --------------------------------
        outMesh.edges.length = limitEdges;
        foreach (i; 0 .. limitEdges) {
            outMesh.edges[i] = [
                cast(uint)edgeVertsRaw[2*i + 0],
                cast(uint)edgeVertsRaw[2*i + 1],
            ];
        }

        // ---- Build preview Mesh.faces (n-gon arrays per face) --------
        outMesh.faces.length = limitFaces;
        int cursor = 0;
        foreach (fi; 0 .. limitFaces) {
            int cnt = faceCounts[fi];
            outMesh.faces[fi].length = cnt;
            foreach (k; 0 .. cnt)
                outMesh.faces[fi][k] = cast(uint)faceIndices[cursor++];
        }

        // Fresh value-mesh: bump versions so downstream caches treat it
        // as a new mesh state, not the default `Mesh.init` (= 0).
        outMesh.mutationVersion = 1;
        outMesh.topologyVersion = 1;
        outMesh.buildLoops();

        // ---- Build SubpatchTrace, mapping sub-cage indices → cage ----
        outTrace.vertOrigin = new uint[](limitVerts);
        outTrace.edgeOrigin = new uint[](limitEdges);
        outTrace.faceOrigin = new uint[](limitFaces);
        foreach (i, o; vertOriginsRaw)
            outTrace.vertOrigin[i] =
                (o < 0) ? uint.max : subToCage[o];
        foreach (i, o; edgeOriginsRaw)
            outTrace.edgeOrigin[i] =
                (o < 0) ? uint.max : subEdgeToCageEdge[o];
        foreach (i, o; faceOriginsRaw)
            outTrace.faceOrigin[i] = cast(uint)subToCageFace[o];

        // Every limit face descends from a subpatch-marked sub-cage
        // face — keep that flag on the preview so any downstream code
        // that re-checks `isSubpatch` sees a consistent fully-marked
        // preview.
        outTrace.subpatch = new bool[](limitFaces);
        outTrace.subpatch[] = true;

        // Resize selection masks to match the new vert/edge/face counts
        // so callers can drive selection without a trip through
        // resetSelection.
        outMesh.selectedVertices.length = limitVerts;
        outMesh.selectedEdges.length    = limitEdges;
        outMesh.selectedFaces.length    = limitFaces;
        outMesh.isSubpatch.length       = limitFaces;
        outMesh.isSubpatch[]            = true;

        valid = true;
        return true;
    }

    /// Hot per-frame call: re-eval OSD's stencils against the current
    /// cage positions and write straight into `preview.vertices`. Only
    /// the sub-cage subset is sampled — `subToCage[]` filters out
    /// cage verts that don't participate in the subpatch input.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(subToCage.length * 3 == cageScratchXyz.length,
               "sub-cage layout changed without buildPreview");

        foreach (svi, cvi; subToCage) {
            Vec3 v = cage.vertices[cvi];
            cageScratchXyz[3*svi + 0] = v.x;
            cageScratchXyz[3*svi + 1] = v.y;
            cageScratchXyz[3*svi + 2] = v.z;
        }
        osdc_evaluate(osd, cageScratchXyz.ptr,
                      cast(float*)preview.vertices.ptr);
    }
}

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
    cage.isSubpatch.length = cage.faces.length;
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
// Selective path: only the marked subset is fed to OSD, so the preview
// contains the OSD-subdivided subset and nothing else. Trace.faceOrigin
// must still point at CAGE face indices (the original 6 cube faces),
// not sub-cage indices.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    // buildLoops populates cage.edgeIndexMap, which OsdAccel uses to
    // map sub-cage edges back to cage edges. makeCube already calls
    // buildLoops, but call it explicitly so the unittest documents the
    // invariant.
    cage.buildLoops();
    cage.isSubpatch.length = cage.faces.length;

    // Mark a single face (cage face 0).
    cage.setSubpatch(0, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 2, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed on selective cube");

    // Single cage face at depth 2 → 4 quads at L1, 16 quads at L2.
    // Vert count via Euler: cage face is a 4-vert quad.
    // L1: 4 face-children + 4 edge-children + 4 vert-children = 12.
    // L2: 16 face-children + 16+8=24 edge-children (interior + bdry)
    //     + 12 vert-children = 52.
    // (Boundary edge subdivision adds one edge per boundary edge per
    // level alongside the interior subdivision; exact number depends
    // on OSD's boundary handling — assert via counts we just compute
    // dynamically rather than hard-code, and verify trace shapes.)
    assert(preview.faces.length == 16,
           "selective L2 cube face → 16 quads");

    // Every preview face traces back to the one marked cage face.
    foreach (o; trace.faceOrigin)
        assert(o == 0, "selective face origin must point at cage face 0");

    // trace.vertOrigin entries that aren't uint.max must reference
    // verts of the marked cage face (cage face 0). makeCube's first
    // face uses verts {0, 1, 3, 2}.
    immutable uint[4] expected = [0, 1, 3, 2];
    foreach (o; trace.vertOrigin) {
        if (o == uint.max) continue;
        bool inSet = false;
        foreach (e; expected) if (o == e) { inSet = true; break; }
        assert(inSet, "vertOrigin must reference a vert of cage face 0");
    }

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
