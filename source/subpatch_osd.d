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
import mesh                   : Mesh, SubpatchTrace, catmullClark, makeCube;
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
// OsdAccel — full SubpatchPreview back-end built on OpenSubdiv.
//
// Replaces vibe3d's catmullClarkTracked recursion entirely for the uniform-
// subpatch case (every cage face marked `isSubpatch`). One call to
// `buildPreview` constructs the limit Mesh (verts/edges/faces/loops) plus
// the SubpatchTrace from OSD's TopologyRefiner output; subsequent drag
// frames just call `refresh` which runs one stencil-table SpMV directly
// into `preview.vertices` (Vec3 is 3 floats tightly packed, so we write
// through `preview.vertices.ptr` without a permutation step).
//
// The OSD handle stays cached across drag events. Cage-topology change →
// SubpatchPreview drops the OsdAccel and re-runs `buildPreview` on the
// new cage.
//
// Selective subpatch (mixed marked / unmarked faces) is out of scope:
// OpenSubdiv subdivides every face, and stitching refined/un-refined
// subsets back together is what vibe3d's `catmullClarkSelected` does on
// the CPU. SubpatchPreview's `allSubpatch()` gate keeps that path
// untouched.
// ---------------------------------------------------------------------------
struct OsdAccel {
    private osdc_topology_t* osd;
    private float[] cageScratchXyz;     // tightly-packed cage positions
    bool valid;

    /// Free the OSD handle and reset state. Idempotent.
    void clear() {
        if (osd !is null) {
            osdc_topology_destroy(osd);
            osd = null;
        }
        cageScratchXyz.length = 0;
        valid                 = false;
    }

    /// Free OSD resources at scope exit. The struct is owned by
    /// SubpatchPreview, which lives for the program's duration, so this
    /// fires once — but it keeps `dub test` (and any future short-lived
    /// SubpatchPreview instances) leak-clean.
    ~this() { clear(); }

    /// Build OSD topology + stencil table from `cage` at `level`, then
    /// emit the limit Mesh (verts/edges/faces/loops) and SubpatchTrace
    /// directly from OSD's output. Caches the OSD handle so subsequent
    /// `refresh` calls run a single SpMV against the cage's new
    /// positions.
    ///
    /// Vertex ordering follows OpenSubdiv's deepest-level layout:
    /// face-points first, edge-points next, vert-points last. The
    /// trailing vert-points trace back to cage verts via
    /// `outTrace.vertOrigin`; face/edge points have `uint.max` there.
    ///
    /// Returns false (and clears state) when OSD topology creation
    /// fails (degenerate input). Callers fall back to vibe3d's
    /// catmullClarkTracked path.
    bool buildPreview(ref const Mesh cage, int level,
                       out Mesh outMesh, out SubpatchTrace outTrace)
    {
        clear();

        immutable int nv = cast(int)cage.vertices.length;
        immutable int nf = cast(int)cage.faces.length;
        if (nv == 0 || nf == 0 || level < 1) return false;

        // ---- Flatten cage into OSD's contiguous-int input format -----
        int[] faceVertCounts = new int[](nf);
        int[] faceVertIndices;
        foreach (fi, face; cage.faces) {
            faceVertCounts[fi] = cast(int)face.length;
            foreach (vi; face) faceVertIndices ~= cast(int)vi;
        }

        cageScratchXyz.length = 3 * nv;
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }

        // ---- Build OSD topology + stencil table ----------------------
        osd = osdc_topology_create(
            nv, nf,
            faceVertCounts.ptr, faceVertIndices.ptr,
            level);
        if (osd is null) { clear(); return false; }

        immutable int limitVerts   = osdc_topology_limit_vert_count(osd);
        immutable int limitFaces   = osdc_topology_limit_face_count(osd);
        immutable int limitIndices = osdc_topology_limit_index_count(osd);
        immutable int limitEdges   = osdc_topology_limit_edge_count(osd);

        // ---- Read OSD limit topology ---------------------------------
        int[] faceCounts   = new int[](limitFaces);
        int[] faceIndices  = new int[](limitIndices);
        int[] edgeVertsRaw = new int[](2 * limitEdges);
        osdc_topology_limit_topology(osd, faceCounts.ptr, faceIndices.ptr);
        osdc_topology_limit_edges   (osd, edgeVertsRaw.ptr);

        int[] faceOriginsRaw = new int[](limitFaces);
        int[] vertOriginsRaw = new int[](limitVerts);
        int[] edgeOriginsRaw = new int[](limitEdges);
        osdc_topology_face_origins(osd, faceOriginsRaw.ptr);
        osdc_topology_vert_origins(osd, vertOriginsRaw.ptr);
        osdc_topology_edge_origins(osd, edgeOriginsRaw.ptr);

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

        // ---- Build SubpatchTrace from OSD origin arrays --------------
        outTrace.vertOrigin = new uint[](limitVerts);
        outTrace.edgeOrigin = new uint[](limitEdges);
        outTrace.faceOrigin = new uint[](limitFaces);
        foreach (i, o; vertOriginsRaw)
            outTrace.vertOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        foreach (i, o; edgeOriginsRaw)
            outTrace.edgeOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        foreach (i, o; faceOriginsRaw)
            outTrace.faceOrigin[i] = cast(uint)o;     // never -1 in CC
        // Every limit face inherits the "subpatch" flag — this is the
        // uniform-CC path, every cage face was marked, so every refined
        // descendant stays marked.
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
    /// cage positions and write straight into `preview.vertices`. No
    /// allocations after `buildPreview`.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(cage.vertices.length * 3 == cageScratchXyz.length,
               "cage vertex count changed without buildPreview");

        // Re-pack cage positions into the scratch buffer the C shim
        // expects. The eval call below dumps the result directly into
        // preview.vertices' backing memory (Vec3 is 3 floats packed).
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
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
