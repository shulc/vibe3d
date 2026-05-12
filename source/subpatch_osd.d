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
import math                   : Vec3;
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

// ---------------------------------------------------------------------------
// OsdAccel — OpenSubdiv-accelerated fast path for SubpatchPreview.
//
// Strategy: after each full vibe3d-side `rebuild`, build an OSD topology +
// stencil table from the same cage at the same depth, evaluate it with the
// cage's current positions, and match OSD's output verts to vibe3d's
// preview verts by quantised position. The result is a permutation
// `permOsdToPreview[osdIdx] = previewVertIdx` that lets us run one
// `osdc_evaluate` per drag frame and scatter the result into
// `preview.vertices[]` — ~50× faster than vibe3d's recursive
// refreshSubdivPositions on a 1.5 K-vert cage (see benchOsdJson).
//
// Active only when every cage face is subpatch-marked (uniform CC). Mixed
// cases stay on the recursive path because OSD subdivides the whole mesh.
// Any mismatch in vert count or position-match coverage trips `valid =
// false` so the caller falls back to the existing path.
// ---------------------------------------------------------------------------
struct OsdAccel {
    private osdc_topology_t* osd;
    private uint[]  permOsdToPreview;   // perm[osdIdx] = previewVertIdx
    private float[] cageScratchXyz;     // pre-allocated, tightly packed
    private float[] limitScratchXyz;
    bool valid;

    /// Free the OSD handle and reset state. Idempotent.
    void clear() {
        if (osd !is null) {
            osdc_topology_destroy(osd);
            osd = null;
        }
        permOsdToPreview.length = 0;
        cageScratchXyz.length   = 0;
        limitScratchXyz.length  = 0;
        valid                   = false;
    }

    /// Build OSD topology + stencil table from `cage` at `level`, then
    /// match OSD's output verts to `preview.vertices` by quantised
    /// position. Sets `valid = true` on success.
    ///
    /// Returns false (and clears state) when:
    ///   * OSD topology creation fails (degenerate cage),
    ///   * OSD's limit-vert count diverges from `preview.vertices.length`
    ///     (e.g. boundary/corner-sharpness semantics differ between OSD
    ///     and vibe3d's CC),
    ///   * any OSD limit vert can't be position-matched against a preview
    ///     vert within the quantisation tolerance.
    /// In all failure modes the caller MUST fall back to the recursive
    /// refreshSubdivPositions path.
    bool rebuild(ref const Mesh cage, int level, ref const Mesh preview)
    {
        clear();

        // ---- Flatten cage into OSD's contiguous-int input format -----
        immutable int nv = cast(int)cage.vertices.length;
        immutable int nf = cast(int)cage.faces.length;

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

        // ---- Build OSD topology --------------------------------------
        osd = osdc_topology_create(
            nv, nf,
            faceVertCounts.ptr, faceVertIndices.ptr,
            level);
        if (osd is null) { clear(); return false; }

        immutable int osdLimitVerts = osdc_topology_limit_vert_count(osd);
        if (osdLimitVerts != cast(int)preview.vertices.length) {
            clear();
            return false;
        }

        // ---- Eval OSD at current cage positions ----------------------
        limitScratchXyz.length = 3 * osdLimitVerts;
        osdc_evaluate(osd, cageScratchXyz.ptr, limitScratchXyz.ptr);

        // ---- Match OSD output → preview vert by quantised position ---
        // Round-to-nearest (NOT floor) avoids the ±0 cliff: with floor,
        // -1e-7 / 1e-3 = -1e-4 → floor = -1, while +0.0 / 1e-3 = 0 →
        // floor = 0. Two positions identical to float precision get put
        // in different buckets when they straddle zero, which is
        // exactly the case for cage verts on the X/Y/Z planes of a
        // closed centred mesh (the cube). `round` collapses ±0 to the
        // same bucket and gives nearest-bucket semantics consistent
        // with the "two positions within Q/2 of each other are the
        // same point" intent.
        //
        // Q = 1e-4 is well above float ULPs for any reasonably-scaled
        // mesh (positions in [-100, 100]) and well below the spacing
        // between distinct verts on any sane subdivision output (~1e-2
        // at minimum after CC).
        enum float Q = 1e-4f;
        long[3] quantise(float x, float y, float z) {
            import std.math : round;
            return [
                cast(long)round(x / Q),
                cast(long)round(y / Q),
                cast(long)round(z / Q),
            ];
        }

        uint[long[3]] posToPreviewIdx;
        foreach (i, v; preview.vertices) {
            auto k = quantise(v.x, v.y, v.z);
            // First wins — keeps the perm deterministic when two
            // preview verts happen to sit at the same quantised cell.
            if (k !in posToPreviewIdx)
                posToPreviewIdx[k] = cast(uint)i;
        }

        permOsdToPreview = new uint[](osdLimitVerts);
        permOsdToPreview[] = uint.max;

        int unmatched = 0;
        foreach (osdIdx; 0 .. osdLimitVerts) {
            auto k = quantise(
                limitScratchXyz[3*osdIdx + 0],
                limitScratchXyz[3*osdIdx + 1],
                limitScratchXyz[3*osdIdx + 2]);
            if (auto p = k in posToPreviewIdx) {
                permOsdToPreview[osdIdx] = *p;
            } else {
                ++unmatched;
            }
        }

        if (unmatched > 0) { clear(); return false; }

        valid = true;
        return true;
    }

    /// Free OSD resources at scope exit. The struct is owned by
    /// SubpatchPreview, which lives for the program's duration, so this
    /// fires once — but it keeps `dub test` (and any future short-lived
    /// SubpatchPreview instances) leak-clean.
    ~this() { clear(); }
    /// Hot per-frame call: re-eval OSD's stencils against the current
    /// cage positions and scatter the result into `preview.vertices[]`
    /// via the cached permutation. No allocations after `rebuild`.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(cage.vertices.length * 3 == cageScratchXyz.length,
               "cage vertex count changed without rebuild");

        // Re-pack cage positions into the contiguous scratch buffer the
        // C shim expects. Vec3 in vibe3d is already tightly packed so
        // this is a memcpy in disguise — D's GC doesn't relocate, so
        // taking `cage.vertices.ptr` would work too, but the explicit
        // copy keeps the eval contract independent of mesh.d's struct
        // layout decisions.
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }
        osdc_evaluate(osd, cageScratchXyz.ptr, limitScratchXyz.ptr);

        foreach (osdIdx; 0 .. permOsdToPreview.length) {
            immutable uint pi = permOsdToPreview[osdIdx];
            preview.vertices[pi] = Vec3(
                limitScratchXyz[3*osdIdx + 0],
                limitScratchXyz[3*osdIdx + 1],
                limitScratchXyz[3*osdIdx + 2]);
        }
    }
}

// ---------------------------------------------------------------------------
// Round-trip correctness: build an OsdAccel against a known cube cage,
// shift one cage vert, refresh, and verify the result matches a direct
// catmullClark recursion on the same shifted cage. Catches regressions
// in either the perm-build (position match) or the per-frame scatter.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.math : abs;
}

unittest {
    Mesh cage = makeCube();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    // Run vibe3d's reference path to depth 2 — that's the preview mesh
    // we'll match against. Build it explicitly (no SubpatchPreview
    // here, just the bare math) so the unit test stays scoped to
    // OsdAccel's contract.
    Mesh preview = catmullClark(cage);
    preview      = catmullClark(preview);

    // Diagnostic: OSD's CC and vibe3d's CC must agree on vert count
    // first, otherwise the perm-build can't even start. The bench
    // output (benchOsdJson) already confirms count agreement for the
    // same pre-refinement levels, so this is mostly a regression
    // sentinel.
    immutable int cageV    = cast(int)cage.vertices.length;
    immutable int cageF    = cast(int)cage.faces.length;
    immutable int previewV = cast(int)preview.vertices.length;

    OsdAccel accel;
    bool built = accel.rebuild(cage, 2, preview);
    import std.format : format;
    assert(built,
        format("OsdAccel.rebuild failed on uniform-subpatch cage "
             ~ "(cage=%dv/%df preview=%dv)",
             cageV, cageF, previewV));
    assert(accel.valid);

    // Shift one cage vert; refresh; compare against vibe3d's own
    // refinement of the same shifted cage. Positions should agree
    // tightly — both implementations run the same Catmull-Clark math.
    cage.vertices[0] = cage.vertices[0] + Vec3(0.5f, 0, 0);

    accel.refresh(cage, preview);

    Mesh reference = catmullClark(cage);
    reference      = catmullClark(reference);
    assert(preview.vertices.length == reference.vertices.length,
           "vert count divergence between OSD and vibe3d on identical cage");

    // The accel-refreshed `preview.vertices[i]` is in vibe3d's
    // preview ordering by construction (the permutation matched it
    // back), so we compare slot-for-slot against the freshly-refined
    // reference.
    enum float TOL = 1e-3f;
    foreach (i; 0 .. preview.vertices.length) {
        immutable Vec3 a = preview.vertices[i];
        immutable Vec3 b = reference.vertices[i];
        assert(abs(a.x - b.x) < TOL && abs(a.y - b.y) < TOL
            && abs(a.z - b.z) < TOL,
               "preview vert " ~ i.stringof
             ~ " diverged from vibe3d CC after OSD refresh");
    }
}
