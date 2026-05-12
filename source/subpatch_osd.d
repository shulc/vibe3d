/// OpenSubdiv evaluator integration — bench-first scaffolding.
///
/// This module exists to (a) verify the D-OpenSubdiv binding links and
/// runs inside vibe3d's address space, and (b) measure the per-frame
/// eval cost of OpenSubdiv's stencil evaluator against vibe3d's own
/// `catmullClark` recursion on the same cage. Once we have real numbers
/// the integration with `SubpatchPreview` can be planned around them
/// (full replace vs fast-path only, what to do about `SubpatchTrace`).
///
/// No public API touches `SubpatchPreview` yet — that's the next phase.
module subpatch_osd;

import std.datetime.stopwatch : StopWatch;
import std.format             : format;
import mesh                   : Mesh, catmullClark, makeCube;
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
