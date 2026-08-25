/// OpenSubdiv integration for vibe3d's Catmull-Clark needs.
///
///   * `OsdAccel` is the production back-end for SubpatchPreview's
///     subdivision-surface preview — builds an OSD topology + stencil
///     table once per cage-topology change and refresh()es per drag
///     frame in one SpMV.
///
///   * `catmullClarkOsd` is the OSD-driven replacement for the
///     formerly-CPU `catmullClark` / `catmullClarkSelected` functions,
///     used by the permanent `mesh.subdivide` command. Single CC pass
///     over the cage (or its `faceMask` subset). For partial subsets
///     it preserves the standard "widened polygon" handling on the
///     boundary so the result stays manifold (no T-junctions across
///     refined/un-refined faces).
module subpatch_osd;

import std.math : sqrt;
import math : Vec3;
import mesh : Mesh, SubpatchTrace, edgeKey, makeCube, Surface;
import osd.c;
import perf_probe : g_perf, Cat, g_fc, DrawPass;

/// Global gate for the GPU stencil evaluator. App.d flips this to true
/// after SDL+OpenGL are loaded and the smoke test passes; it stays
/// false in headless contexts (`dub test`, future CLI tools) so
/// OsdAccel.buildPreview doesn't try to call GL functions without a
/// context and segfault.
__gshared bool g_osdGpuEnabled = false;

// ---------------------------------------------------------------------------
// Subpatch depth policy (task 1374, phase 1).
//
// Extracted VERBATIM IN ROLE from the inline block that used to sit inside
// `OsdAccel.buildPreview`, with ONE deliberate behaviour change (below), so
// that the policy can be exercised on a cage size that would take ~2 s and
// ~200 MB to actually refine — the unit lane cannot afford to build a
// 1.5-million-face limit surface just to ask which level the policy picks.
// ---------------------------------------------------------------------------

/// Ceiling on the limit-face count the refiner is allowed to project to.
///
/// This constant defends MEMORY, and only memory: OSD's stencil-table build
/// allocates proportionally to the refined face count, and the cap exists so a
/// large cage cannot make it die there. It has never bounded TIME, which is
/// the complaint task 1374 was opened for — see the task file. Renamed from
/// `MAX_LIMIT_FACES` (task 1374 phase 1) so the thing it protects is in its
/// name.
///
/// THE VALUE IS AN OWNER DECISION, taken 2026-08-19 (task 1374 phase 2):
/// 1 500 000 → 800 000. What it buys is a bound on the WORST cold Tab, and
/// what it costs is refinement depth. At this task's measured 4.45–4.96 µs and
/// ~225 B per limit face (doc/tasks/work/1374-tab-cold-path.md, «Измерение»,
/// points C and D) the worst cold Tab this ceiling admits drops from ~7.5 s /
/// ~345 MB to ~4.0 s / ~180 MB. The cages that PAY are exactly those whose
/// projection at their old level fell in `(800 000, 1 500 000]` — they lose
/// one level. On an all-quad cage at the shipped depth of 3 that is TWO
/// disjoint ranges, not one: `nf ∈ [12 501, 23 437]` (L3 → L2) and
/// `nf ∈ [50 001, 93 750]` (L2 → L1). One range per level transition, the
/// same `R-1` the band rule below gives; the owner-decision table in the task
/// file names only the second, and that gap is recorded there.
///
/// THE TRADE IS DELIBERATELY ASYMMETRIC, in our favour. A coarse cage keeps
/// full depth under any of these budgets — a 500-face quad cage projects
/// 2 000·4^2 = 32 000 limit faces at the shipped depth of 3, inside even a
/// 200 000 ceiling — so the cages that lose a level are the DENSE ones, where
/// an extra subdivision level buys the least visible difference.
///
/// WHAT LOWERING IT DOES NOT DO, and the reason no smaller number is the
/// "right" one either: it does NOT remove the 4× cliff task 1374 was opened
/// for. Levels are integers, so the admitted cost always lies in `(B/4, B]`,
/// and lowering `B` MOVES the cliff rather than removing it — the band tables
/// below are the same shape at 800 000 as at 1 500 000, just shifted down by
/// the ratio. No single-budget policy can remove it; see the task file
/// («Фаза 2 — решение владельца») for why, and «Два решения, записанных
/// вместо реализации» for why the two policies that COULD — view-dependent
/// depth, and a budget adapted to the host — are rejected on CORRECTNESS
/// (camera-dependent selection; two machines disagreeing about one document)
/// rather than on cost. A build constant is the only shape this may take.
enum long MEM_LIMIT_FACES = 800_000;

/// Hard ceiling on the requested refinement level, applied before the
/// projection loop.
///
/// `requested` reaches here from app-level state (`subpatchDepth`, prefs) and
/// from `/api/command`, i.e. it is not a compile-time constant, and
/// `chooseSubpatchLevel`'s loop below walks DOWN one level per iteration —
/// so an absurd request would spin `requested` times before the memory
/// ceiling caught it. 16 is far above anything the memory ceiling can ever
/// admit (the smallest possible non-degenerate cage, a single triangle, already
/// projects 3·4^15 = 3.2e9 limit faces at level 16), so this clamp changes no
/// reachable answer — it only bounds the loop.
enum int MAX_SUBPATCH_LEVEL = 16;

/// EXACT Catmull-Clark limit face count for a cage with `cornerCount` corners
/// (`Σ_f |f|`, summed over cage faces) refined to `level`.
///
/// THE FORMULA CHANGED HERE, AND IT IS A BEHAVIOUR CHANGE — not a refactor.
/// The old inline code projected `nf · 4^level` from the cage FACE count. The
/// first CC pass replaces every n-gon with n quads and every pass after that
/// quadruples, so the true count is `(Σ|f|) · 4^(level-1)`. Those agree
/// EXACTLY — and only — when `Σ|f| == 4·nf`, i.e. on an all-quad cage.
///
/// THE GENERAL RULE, stated rather than exemplified, because the blast radius
/// is wider than any one enumerated case and an enumeration alone invites the
/// reader to believe it is complete. Write `r = Σ|f| / nf` — the cage's mean
/// corners per face; 3 for triangles, 4 for quads, 6 for hexagons — and
/// `C = MEM_LIMIT_FACES`. The new policy admits level L iff
/// `nf·r·4^(L-1) ≤ C`, i.e. iff `nf·4^L ≤ 4C/r`. So the change is EXACTLY
/// "the old rule under a rescaled ceiling" `C' = 4C/r` — above C for r < 4,
/// below C for r > 4, equal at r = 4. Two rules of that shape disagree in
/// **one band per LEVEL TRANSITION**, so a requested depth R gives `R-1` bands
/// (transitions L ∈ [2, R]; below 2 the floor of 1 makes both agree). The band
/// at transition L is, in cage faces,
///
///     nf ∈ ( min(C, C') / 4^L ,  max(C, C') / 4^L ]
///
/// and inside it the new policy picks L where the old picked L-1 (when r < 4)
/// or L-1 where the old picked L (when r > 4).
///
/// AT THE SHIPPED DEPTH — `app.d`'s `subpatchDepth = 3` — that is TWO bands
/// per cage class, not one. Enumerated with NO STRIDE over the whole band
/// range (the enumeration is reproduced as assertions in
/// `tests/unit/subpatch_level_policy_test.d`), for the shipped
/// `C = MEM_LIMIT_FACES = 800 000`:
///
///     triangles (r=3, C' = 1 066 666)
///       nf ∈ [ 12 501,  16 666]   L2 → L3    4× the refinement work
///       nf ∈ [ 50 001,  66 666]   L1 → L2    4× the refinement work
///     hexagons  (r=6, C' =   533 333)
///       nf ∈ [  8 334,  12 500]   L3 → L2    ¼ the work; the ceiling this
///       nf ∈ [ 33 334,  50 000]   L2 → L1    constant exists for was being
///                                            BREACHED before the fix
///     quads     (r=4, C' = C)     no band, at any depth — identical always
///
/// (At R=4 a third band appears per class, e.g. triangles nf ∈ [3 126, 4 166]
/// L3 → L4; at R=2 only the lowest one survives. R-1, as above.)
///
/// `C'` NEED NOT BE AN INTEGER — 4·800 000/3 = 1 066 666.67 — and at the
/// previous ceiling it always was (3 and 6 both divide 1 500 000; neither
/// divides 800 000 = 2^8·5^5). Truncating it first is nonetheless exact:
/// `⌊⌊x⌋/n⌋ = ⌊x/n⌋` for integer n > 0, so every band edge above is the same
/// whether `C'` is carried as a rational or floored. What DID move with it is
/// where the ceiling is met EXACTLY — the cell that makes the strict `>` in
/// `chooseSubpatchLevel` load-bearing rather than decorative. At 1 500 000
/// that cell existed for triangles and hexagons; at 800 000 it exists only
/// where `4^L | C`, i.e. on QUAD cages (nf = 50 000 at L2, 12 500 at L3) and
/// on the face-count reading. The band edges here are therefore the largest
/// nf that still FITS (3·16 666·16 = 799 968), not one that meets the ceiling.
///
/// THE EXPENSIVE BAND IS `nf ∈ [50 001, 66 666]` TRIANGLES, and it is the
/// ORDINARY case rather than a corner: a ~50 000-triangle cage is what an
/// OBJ / glTF / FBX import routinely lands on. Inside it the first Tab goes
/// from 150 003…199 998 limit faces (L1) to 600 012…799 992 (L2). At this
/// task's measured 4.45–4.96 µs and ~225 B per limit face
/// (doc/tasks/work/1374-tab-cold-path.md, «Измерение», points C and D) that
/// is ~0.7–1.0 s → ~2.7–4.0 s and ~34–45 MB → ~135–180 MB. So on an ordinary
/// triangulated import the corner projection INTRODUCES exactly the 4× cliff
/// task 1374 was opened to remove — correctly, in the sense that the memory
/// ceiling is what it always claimed to enforce and 800 000 limit faces is
/// inside it, but the time cost is real. It is written down here, in the tests
/// and in the task file rather than left latent.
///
/// The [12 501, 16 666] band costs the SAME, not less: both bands are pressed
/// against the same ceiling, so both run 600 000…800 000 limit faces at their
/// new level and 150 000…200 000 at their old one. They differ in cage size
/// only. (The phase-1 text here claimed the lower band was "the same 4× on a
/// smaller base, ~0.4 s → ~1.7 s"; that was wrong by a factor of four in both
/// endpoints and is corrected rather than rescaled.)
///
/// Saturates instead of overflowing: `long.max` is returned for any projection
/// that would wrap, which the caller reads as "over the ceiling" — the same
/// answer an exact bignum would give.
long projectedLimitFaces(long cornerCount, int level) pure nothrow @safe @nogc
{
    if (cornerCount <= 0 || level < 1) return 0;
    long p = cornerCount;
    foreach (_; 1 .. level) {
        if (p > long.max / 4) return long.max;
        p *= 4;
    }
    return p;
}

/// The depth the refiner will actually run at: the largest level ≤ `requested`
/// whose EXACT projected limit-face count fits under `memLimitFaces`, floored
/// at 1 (a cage that cannot fit even one refinement level is refined once
/// anyway — dropping to level 0 would mean "no preview at all", which is not
/// what the cap is for and never was).
///
/// `cornerCount` is `Σ_f |f|`, NOT the face count. That is the whole point of
/// the signature: the caller already sums it while flattening the cage for OSD,
/// and passing it (rather than `nf`) is what makes the policy correct on
/// non-quad cages AND testable on one — `chooseSubpatchLevel(6 * nf, 2)` asks
/// the hexagon question without anyone building a hexagonal mesh.
///
/// `memLimitFaces` is a parameter with a default rather than a hard-wired
/// constant so a test can drive the ceiling instead of the cage: asserting the
/// ceiling is still ENFORCED costs a two-face fixture this way, and a
/// 1.5-million-face refinement the other way.
int chooseSubpatchLevel(long cornerCount, int requested,
                        long memLimitFaces = MEM_LIMIT_FACES) pure nothrow @safe @nogc
{
    if (requested < 1) return requested;
    int lvl = requested < MAX_SUBPATCH_LEVEL ? requested : MAX_SUBPATCH_LEVEL;
    while (lvl > 1 && projectedLimitFaces(cornerCount, lvl) > memLimitFaces)
        --lvl;
    return lvl;
}

/// Flatten `cage`'s face table into the (per-face vertex count, concatenated
/// vertex index) pair `osdc_topology_create_sharp` takes, reusing whatever
/// capacity the two caller-owned buffers already hold. Returns `Σ_f |f|` —
/// the corner count `chooseSubpatchLevel` wants.
///
/// Split out of `buildPreview` for two reasons, only one of them cosmetic:
///
///  1. The index buffer used to be a FRESH LOCAL grown with `~=`, one append
///     per corner — ~400 000 of them on the n=316 fixture, and a fresh 1.6 MB
///     block on every rebuild however many times the same cage is rebuilt.
///     Sizing it once and filling by index costs one `.length` assignment, and
///     when the caller passes a persistent buffer (`OsdAccel`'s scratch fields)
///     a repeat build at the same cage size allocates NOTHING.
///  2. It is the only shape of this fix a test can hold still: see
///     `tests/unit/subpatch_level_policy_test.d` for the measurement showing
///     that the OBVIOUS witnesses for "does this reallocate" — GC alloc bytes
///     and `.capacity` — are both INERT here, because druntime grows a
///     page-backed array in place via `GC.extend` and ends at the SAME capacity
///     the exact sizing produces. The property that is actually observable, and
///     the one the old code could not have, is buffer REUSE: called twice with
///     the same buffers, this never moves them.
long flattenCageTopology(ref const Mesh cage, ref int[] outCounts, ref int[] outIndices)
{
    long cornerCount = 0;
    foreach (face; cage.faces) cornerCount += face.length;

    outCounts .length = cage.faces.length;
    outIndices.length = cast(size_t)cornerCount;

    size_t k = 0;
    foreach (fi, face; cage.faces) {
        outCounts[fi] = cast(int)face.length;
        foreach (vi; face) outIndices[k++] = cast(int)vi;
    }
    assert(k == cast(size_t)cornerCount);
    return cornerCount;
}

/// Phase 3c — caller bundle of GPU VBO targets the GPU fan-out can
/// write to. Each (vbo, count) pair gates the corresponding fan-out
/// dispatch; passing 0 for any vbo opts out of that one. The caller
/// (app.d main loop) constructs this from gpu.{face,edge,vert}Vbo +
/// the matching counts before calling SubpatchPreview.rebuildIfStale.
struct GpuFanOutTargets {
    import bindbc.opengl : GLuint;
    GLuint faceVbo;       int faceVertCount;
    GLuint edgeVbo;       int edgeSegCount;
    GLuint vertVbo;       int vertCount;
}

// ---------------------------------------------------------------------------
// CageSnapshot — the cage, in buffers the BUILD owns (task 1500).
// ---------------------------------------------------------------------------
//
// `buildFromSnapshot` runs on a worker thread and MUST NOT read the live
// `Mesh`: the main thread keeps editing it (a gizmo drag rewrites
// `vertices` every frame without bumping `mutationVersion` — see the
// comment above `SubpatchPreview.deactivate`). Everything the build reads is
// copied here first, on the main thread, at dispatch.
//
// EVERY ARRAY IS OWNED, and that is the point of the struct rather than a
// bundle of `const` slices. The flatten buffers in particular used to be
// `OsdAccel` fields reused between builds (`scratchCageFaceCounts` /
// `scratchCageFaceVertIndices`) — a worker reading them while the next
// snapshot overwrote them is precisely the race this replaces. Resized with
// `.length =` rather than reallocated, so a snapshot held in a front/back
// pool keeps its capacity and costs nothing after the first build.
struct CageSnapshot {
    int     nv;
    int     nf;
    long    cornerCount;
    int     level;
    long    memLimitFaces = MEM_LIMIT_FACES;

    float[]   xyz;              // 3*nv — cage positions AS OF DISPATCH
    int[]     faceVertCounts;   // nf
    int[]     faceVertIndices;  // cornerCount
    uint[]    edgeVerts;        // 2*ne, cage.edges flattened
    bool[]    faceSubpatch;     // nf
    bool[]    faceHidden;       // nf
    uint[]    faceMaterial;     // nf (0 where the cage carries no entry)
    Surface[] surfaces;
    float[]   creaseWeights;    // the reserved crease map's data, or empty

    // Decided at snapshot time so the dispatcher can refuse a build that
    // would immediately return false, and so the worker never has to ask the
    // live mesh anything.
    bool anyMarked;
    bool anyUnmarked;
    bool creaseMapLive;

    @property size_t edgeCount() const { return edgeVerts.length / 2; }
}

/// Fill `snap` from `cage`. MAIN THREAD, at dispatch.
///
/// `assertEdgeMapValid()` is called HERE rather than inside the build, and
/// under the same condition it used to guard (task 0833's witness in
/// tests/unit/subpatch_osd_test.d still sees it): it is a precondition on the
/// LIVE mesh's derived state, so it has to be asked while the live mesh is
/// still in reach.
void takeCageSnapshot(ref const Mesh cage, int level, ref CageSnapshot snap,
                       long memLimitFaces = MEM_LIMIT_FACES)
{
    snap.nv            = cast(int)cage.vertices.length;
    snap.nf            = cast(int)cage.faces.length;
    snap.level         = level;
    snap.memLimitFaces = memLimitFaces;

    snap.cornerCount = flattenCageTopology(cage, snap.faceVertCounts,
                                                 snap.faceVertIndices);

    snap.xyz.length = 3 * cage.vertices.length;
    foreach (vi, v; cage.vertices) {
        snap.xyz[3*vi + 0] = v.x;
        snap.xyz[3*vi + 1] = v.y;
        snap.xyz[3*vi + 2] = v.z;
    }

    snap.edgeVerts.length = 2 * cage.edges.length;
    foreach (ei, e; cage.edges) {
        snap.edgeVerts[2*ei + 0] = e[0];
        snap.edgeVerts[2*ei + 1] = e[1];
    }

    snap.faceSubpatch.length = cage.faces.length;
    snap.faceHidden  .length = cage.faces.length;
    snap.faceMaterial.length = cage.faces.length;
    bool anyMarked = false, anyUnmarked = false;
    foreach (fi; 0 .. cage.faces.length) {
        immutable bool marked = cage.isFaceSubpatch(fi);
        snap.faceSubpatch[fi] = marked;
        if (marked) anyMarked = true; else anyUnmarked = true;
        snap.faceHidden  [fi] = cage.isFaceHidden(fi);
        snap.faceMaterial[fi] = fi < cage.faceMaterial.length
                              ? cage.faceMaterial[fi] : 0u;
    }
    snap.anyMarked   = anyMarked;
    snap.anyUnmarked = anyUnmarked;

    snap.surfaces = cage.surfaces.dup;

    auto creaseMap = cage.creaseWeightMap();
    // "Live" means at least one entry produces a nonzero sharpness — see the
    // long-form reasoning at the (now worker-side) use site.
    import std.algorithm : any;
    snap.creaseMapLive = creaseMap !is null
        && creaseMap.data.any!(w => creaseSharpnessFromWeight(w) > 0);
    if (creaseMap !is null) {
        snap.creaseWeights.length = creaseMap.data.length;
        snap.creaseWeights[]      = creaseMap.data[];
    } else {
        snap.creaseWeights.length = 0;
    }

    if (snap.anyUnmarked || snap.creaseMapLive)
        cage.assertEdgeMapValid();
}

/// One finished CPU build, handed from the worker thread to the main thread
/// by value (task 1500).
///
/// OWNERSHIP OF `topo` IS THE FIELD THAT MATTERS. `topoOwned` is true iff the
/// build MISSED the LRU cache and created the topology itself; the main
/// thread must then either install it (`installInCache`) or destroy it
/// (`osdc_topology_destroy`) — never neither, which is the leak M-LEAK
/// witnesses. On a cache HIT the pointer is BORROWED from the cache slot and
/// the receiver must not free it.
struct PreviewBuildResult {
    ulong  generation;      // dispatch counter, echoed back
    ulong  key;             // stencil-space key this build was dispatched for
    bool   ok;

    Mesh          mesh;
    SubpatchTrace trace;

    osdc_topology_t* topo;
    bool   topoOwned;
    bool   cacheHit;
    ulong  topoKey;
    int    limitVertCount;
    int    limitFaces;
    int    limitEdges;
    int    numCageVerts;

    int    requestedLevel;
    int    chosenLevel;
    long   cageCornerCount;
    long   memLimitFaces;

    long   workerNs;         // wall time inside buildFromSnapshot
    long   workerAllocBytes; // GC bytes allocated by the building thread
}

/// One-shot startup verification of the OSD GL evaluator. Builds a
/// tiny cube cage, evaluates limit positions both on CPU and on GPU
/// via transform feedback, returns the max per-component delta.
/// Requires an active GL 3.3+ context on the calling thread.
///
/// Logs the result to stderr. Used during boot to fail fast if the
/// GPU evaluator is broken on the host's driver; production code
/// paths still drive subpatch through the CPU evaluator until the
/// Phase 3 VBO refactor lands (see doc/osd_gpu_evaluator_phase3.md).
float runGlEvaluatorSmokeTest() {
    import bindbc.opengl;
    import log : logWarn;

    void warn(string s) {
        try logWarn("subpatch", "gl_smoke: " ~ s);
        catch (Exception) {}
    }

    // 8 cage verts / 6 quad faces (unit cube).
    immutable int[6]  faceCounts  = [4, 4, 4, 4, 4, 4];
    immutable int[24] faceIndices = [
        0, 1, 3, 2,   4, 6, 7, 5,
        0, 2, 6, 4,   1, 5, 7, 3,
        0, 4, 5, 1,   2, 3, 7, 6,
    ];
    immutable float[24] cageXyz = [
        -1, -1, -1,   1, -1, -1,
        -1, -1,  1,   1, -1,  1,
        -1,  1, -1,   1,  1, -1,
        -1,  1,  1,   1,  1,  1,
    ];

    auto topo = osdc_topology_create(
        8, 6, faceCounts.ptr, faceIndices.ptr, 1);
    if (topo is null) { warn("topology create failed"); return -1.0f; }
    scope (exit) osdc_topology_destroy(topo);

    immutable int limitVerts = osdc_topology_limit_vert_count(topo);

    // CPU baseline
    float[] cpuOut = new float[](3 * limitVerts);
    osdc_evaluate(topo, cageXyz.ptr, cpuOut.ptr);

    // GPU eval — needs OSD's bundled glLoader to be initialised
    // (osdc_gl_create handles that lazily).
    auto glEval = osdc_gl_create(topo);
    if (glEval is null) { warn("GL evaluator create failed"); return -1.0f; }
    scope (exit) osdc_gl_destroy(glEval);

    GLuint srcVbo, dstVbo;
    glGenBuffers(1, &srcVbo);
    glGenBuffers(1, &dstVbo);
    scope (exit) {
        glDeleteBuffers(1, &srcVbo);
        glDeleteBuffers(1, &dstVbo);
    }

    glBindBuffer(GL_ARRAY_BUFFER, srcVbo);
    glBufferData(GL_ARRAY_BUFFER, cageXyz.length * float.sizeof,
                 cast(const void*)cageXyz.ptr, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, dstVbo);
    glBufferData(GL_ARRAY_BUFFER, 3 * limitVerts * float.sizeof,
                 null, GL_DYNAMIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    int ok = osdc_gl_evaluate(glEval, srcVbo, dstVbo);
    if (!ok) { warn("osdc_gl_evaluate returned 0"); return -1.0f; }

    float[] gpuOut = new float[](3 * limitVerts);
    glBindBuffer(GL_ARRAY_BUFFER, dstVbo);
    glGetBufferSubData(GL_ARRAY_BUFFER, 0,
                       3 * limitVerts * float.sizeof, gpuOut.ptr);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    float maxDelta = 0.0f;
    foreach (i; 0 .. cpuOut.length) {
        import std.math : abs;
        float d = abs(cpuOut[i] - gpuOut[i]);
        if (d > maxDelta) maxDelta = d;
    }
    try {
        import log : logInfo;
        import std.format : format;
        logInfo("subpatch", format("gl_smoke: OK: %d limit verts, max "
                        ~ "|CPU - GPU| = %.6g", limitVerts, maxDelta));
    } catch (Exception) {}
    return maxDelta;
}

/// One Catmull-Clark refinement of `cage` via OpenSubdiv. When
/// `faceMask` is empty (or all-true) every face is refined and the
/// result is OSD's level-1 limit mesh verbatim. When `faceMask` is
/// partial, only marked faces are refined; un-marked faces are
/// passed through with boundary-edge "widening" — any boundary edge
/// the marked subset bisects gets its OSD edge-point inserted into
/// the adjacent un-marked face's vert list so the result is still
/// manifold (no T-junction across the refinement boundary).
///
/// `faceOriginOut`, when non-null, receives one entry per output face:
/// the cage face index that produced it. Lets callers (e.g. the
/// `mesh.subdivide` command) carry per-face state — selection in
/// particular — across the refinement.
///
/// True if cage face `fi` is degenerate for CC-subdivide purposes: fewer
/// than 3 corners, fewer than 3 distinct vertex indices after collapsing
/// consecutive duplicates (including the last-to-first wrap), or a
/// near-zero Newell normal (collinear / zero-area). Mirrors the idiom in
/// `Mesh.makePolygonFromVerts` (`mesh.d`) so both call sites agree on
/// what counts as degenerate.
private bool isDegenerateSubdivFace_(ref const Mesh cage, size_t fi) {
    const face = cage.faces[fi];
    if (face.length < 3) return true;

    uint[] deduped;
    deduped.reserve(face.length);
    foreach (i; 0 .. face.length) {
        uint prev = face[(i + face.length - 1) % face.length];
        if (face[i] != prev) deduped ~= face[i];
    }
    while (deduped.length >= 2 && deduped[$ - 1] == deduped[0])
        deduped = deduped[0 .. $ - 1];
    if (deduped.length < 3) return true;

    float nx = 0, ny = 0, nz = 0;
    foreach (i; 0 .. deduped.length) {
        Vec3 a = cage.vertices[deduped[i]];
        Vec3 b = cage.vertices[deduped[(i + 1) % deduped.length]];
        nx += (a.y - b.y) * (a.z + b.z);
        ny += (a.z - b.z) * (a.x + b.x);
        nz += (a.x - b.x) * (a.y + b.y);
    }
    immutable float len = sqrt(nx*nx + ny*ny + nz*nz);
    return len < 1e-6f;
}

/// Returns `Mesh.init` when OSD can't build a topology (degenerate
/// input or empty subset), or when any marked face is itself degenerate
/// (zero-area / collinear / <3 distinct corners) — reject-whole rather
/// than risk emitting coincident verts from a bad face.
///
/// Corner-provenance (task 0901, `CornerDrop.SubpatchCage` / `SubdivideNoLaw`):
/// verified NOT APPLICABLE. `cage` is `ref const` — the language forbids
/// mutating it — and the returned `Mesh` is a fresh value with no PolyVertex
/// map of its own. Every caller that bakes this into an existing document
/// mesh (`commands/mesh/subdivide.d`) does `*mesh = catmullClarkOsd(...)`, a
/// whole-mesh replace: the old mesh's map disappears with the old mesh, it is
/// not zeroed by anything in THIS function. Nothing here rewrites `faces` on
/// a mesh that still owns a live map, so there is no declaration to make.
Mesh catmullClarkOsd(ref const Mesh cage, const bool[] faceMask = null,
                     uint[]* faceOriginOut = null) {
    immutable int nv = cast(int)cage.vertices.length;
    immutable int nf = cast(int)cage.faces.length;
    if (nv == 0 || nf == 0) return Mesh.init;

    // Detect selection mode: are ALL faces (effectively) marked?
    bool anyUnmarked = false;
    foreach (fi; 0 .. nf) {
        immutable bool marked =
            (faceMask.length == 0)
            || ((fi < faceMask.length) && faceMask[fi]);
        if (!marked) { anyUnmarked = true; break; }
    }

    // ---- Build sub-cage from the marked subset (whole cage when
    // ----  faceMask is empty / all-true).
    int[] cageToSub = new int[](nv);
    cageToSub[] = -1;
    int[] subToCage;
    int[] markedFaceIndices;     // cage face idx of each sub-cage face
    int   subNumVerts    = 0;
    int   subTotalIndices = 0;
    foreach (fi; 0 .. nf) {
        immutable bool marked =
            (faceMask.length == 0)
            || ((fi < faceMask.length) && faceMask[fi]);
        if (!marked) continue;
        // Reject-whole: a degenerate marked face refuses the entire
        // subdivide rather than emit coincident verts from a bad input
        // (out of scope: partial skip-face refine — see mesh-robustness
        // plan). The caller (`commands.mesh.subdivide`) treats an empty
        // result as a clean no-op.
        if (isDegenerateSubdivFace_(cage, fi)) return Mesh.init;
        markedFaceIndices ~= cast(int)fi;
        subTotalIndices  += cast(int)cage.faces[fi].length;
        foreach (cvi; cage.faces[fi]) {
            if (cageToSub[cvi] == -1) {
                cageToSub[cvi] = subNumVerts++;
                subToCage ~= cvi;
            }
        }
    }
    immutable int subNumFaces = cast(int)markedFaceIndices.length;
    if (subNumFaces == 0) return Mesh.init;

    int[] sfvc = new int[](subNumFaces);
    int[] sfvi = new int[](subTotalIndices);
    {
        int faceCursor = 0, idxCursor = 0;
        foreach (fi; markedFaceIndices) {
            sfvc[faceCursor] = cast(int)cage.faces[fi].length;
            foreach (cvi; cage.faces[fi])
                sfvi[idxCursor++] = cageToSub[cvi];
            ++faceCursor;
        }
    }

    float[] cageXyz = new float[](3 * subNumVerts);
    foreach (svi, cvi; subToCage) {
        Vec3 v = cage.vertices[cvi];
        cageXyz[3*svi + 0] = v.x;
        cageXyz[3*svi + 1] = v.y;
        cageXyz[3*svi + 2] = v.z;
    }

    // ---- OSD topology at depth 1 + read back limit topology.
    auto osd = osdc_topology_create(
        subNumVerts, subNumFaces, sfvc.ptr, sfvi.ptr, 1);
    if (osd is null) return Mesh.init;
    scope (exit) osdc_topology_destroy(osd);

    immutable int limitV   = osdc_topology_limit_vert_count(osd);
    immutable int limitF   = osdc_topology_limit_face_count(osd);
    immutable int limitIdx = osdc_topology_limit_index_count(osd);

    int[] limitFC = new int[](limitF);
    int[] limitFI = new int[](limitIdx);
    int[] faceOriginsRaw = new int[](limitF);
    int[] vertOriginsRaw = new int[](limitV);
    osdc_topology_limit_topology(osd, limitFC.ptr, limitFI.ptr);
    osdc_topology_face_origins(osd, faceOriginsRaw.ptr);
    osdc_topology_vert_origins(osd, vertOriginsRaw.ptr);

    Vec3[] osdVerts = new Vec3[](limitV);
    osdc_evaluate(osd, cageXyz.ptr, cast(float*)osdVerts.ptr);

    Mesh result;

    if (!anyUnmarked) {
        // Full refinement — OSD's output IS the result mesh.
        result.vertices = osdVerts;
        // Stage B of doc/mesh_faces_flat_refactor_plan.md: build a
        // fresh `uint[]` per face and assign it via faces[k] = …
        // instead of mutating an already-installed slice's contents
        // in-place. This is the "replace whole face" pattern that the
        // CSR storage in Stage C / D supports natively.
        result.faces.length = limitF;
        int cursor = 0;
        foreach (k; 0 .. limitF) {
            uint[] verts = new uint[](limitFC[k]);
            foreach (j; 0 .. limitFC[k])
                verts[j] = cast(uint)limitFI[cursor++];
            result.faces[k] = verts;
        }
        if (faceOriginOut !is null) {
            (*faceOriginOut).length = limitF;
            foreach (k; 0 .. limitF)
                (*faceOriginOut)[k] =
                    cast(uint)markedFaceIndices[faceOriginsRaw[k]];
        }
        // Edges direct from OSD.
        immutable int limitE = osdc_topology_limit_edge_count(osd);
        int[] limitEV = new int[](2 * limitE);
        osdc_topology_limit_edges(osd, limitEV.ptr);
        result.edges.length = limitE;
        foreach (k; 0 .. limitE) {
            result.edges[k] = [
                cast(uint)limitEV[2*k + 0],
                cast(uint)limitEV[2*k + 1],
            ];
        }
        // Per-face subpatch flag inherits from the parent cage face.
        result.resizeSubpatch();
        // Material Groups (MG3): each refined face inherits the same
        // surface index as its source cage face.
        result.faceMaterial = new uint[](limitF);
        foreach (k; 0 .. limitF) {
            int parent = faceOriginsRaw[k];
            int cageFi = markedFaceIndices[parent];
            if (cageFi >= 0) {
                result.setFaceSubpatch(k, cage.isFaceSubpatch(cageFi));
                // Hide (task 0613 S3): a refined face inherits its parent's
                // hidden state, exactly like Subpatch. This is the OSD OUTPUT
                // — the input above never saw a Hide bit (R5), so the limit
                // surface is bit-identical whether or not anything is hidden.
                result.setFaceHiddenBit(k, cage.isFaceHidden(cageFi));
            }
            if (cageFi >= 0 && cageFi < cast(int)cage.faceMaterial.length)
                result.faceMaterial[k] = cage.faceMaterial[cageFi];
        }
    } else {
        // ---- Selective: stitch OSD output with un-marked cage faces.
        //
        // Settled-cage precondition (debug-only, stripped from release builds
        // — task 0724 / audit-4 M6). Placed HERE and not at the function's
        // first line on purpose: the full-refinement arm above never touches
        // `cage.edgeIndexMap`, so an entry-wide assert would refuse a
        // perfectly legal whole-cage call on a mesh whose map was never
        // built. This arm cannot proceed without it — a stale map mis-keys
        // the cage-edge → OSD-edge-point table below, and the stitched
        // boundary silently loses its edge points (visible as a crack
        // between the refined subset and the un-marked cage faces), which is
        // exactly the class of failure an exception would have surfaced and
        // a wrong lookup does not.
        // TASK 0833 — demonstrated live, INCLUDING the branch-local placement:
        // tests/unit/subpatch_osd_test.d refines an importer-shaped cage
        // (`addFaceFast`, no terminal buildLoops) with a MIXED mask and
        // requires the throw, then refines the SAME unsettled cage whole and
        // requires that to succeed. Deleting this line turns that block red;
        // hoisting it to the function entry turns the whole-cage half red.
        cage.assertEdgeMapValid();
        // 1. Build cage-vert → result-vert idx map:
        //      In-subset cage verts map to their OSD vert-point idx
        //      (corner-pinned, sitting at the original cage position
        //      because the shim configures EDGE_AND_CORNER boundary).
        //      Out-of-subset cage verts get appended after the OSD
        //      verts.
        int[] cageToNew = new int[](nv);
        cageToNew[] = -1;
        foreach (osdIdx, origin; vertOriginsRaw) {
            if (origin < 0) continue;
            int cageVi = subToCage[origin];
            if (cageToNew[cageVi] == -1)
                cageToNew[cageVi] = cast(int)osdIdx;
        }
        result.vertices = osdVerts.dup;
        foreach (cageVi; 0 .. nv) {
            if (cageToNew[cageVi] != -1) continue;
            cageToNew[cageVi] = cast(int)result.vertices.length;
            result.vertices ~= cage.vertices[cageVi];
        }

        // 2. Map each cage edge to its OSD edge-point (limit-vert
        //    idx) if it lies on the refined subset's boundary. We
        //    don't get this from OSD directly in cage-edge space —
        //    walk OSD's input-edge list (sub-cage edges), pair the
        //    endpoint cage verts via subToCage, look up the cage
        //    edge through cage.edgeIndexMap.
        immutable int inEdges = osdc_topology_input_edge_count(osd);
        int[] inEdgeVerts    = new int[](2 * inEdges);
        int[] inEdgeChildren = new int[](inEdges);
        osdc_topology_input_edges          (osd, inEdgeVerts.ptr);
        osdc_topology_input_edge_children  (osd, inEdgeChildren.ptr);

        uint[uint] cageEdgeToOsdEdgePt;   // cage edge idx → OSD limit vert
        foreach (se; 0 .. inEdges) {
            uint cv0 = subToCage[inEdgeVerts[2*se + 0]];
            uint cv1 = subToCage[inEdgeVerts[2*se + 1]];
            if (auto p = edgeKey(cv0, cv1) in cage.edgeIndexMap) {
                cageEdgeToOsdEdgePt[*p] = cast(uint)inEdgeChildren[se];
            }
        }

        // 3. Marked faces: OSD output, indices already in result-vert
        //    space (OSD limit-vert idx == result-vert idx for the
        //    leading limitV slots).
        // Same "replace whole face" pattern as the !anyUnmarked
        // branch above (Stage B of the Mesh.faces flat-refactor).
        result.faces.length = limitF;
        result.resizeSubpatch();
        result.faceMaterial.length = limitF;
        int cursor = 0;
        foreach (k; 0 .. limitF) {
            uint[] verts = new uint[](limitFC[k]);
            foreach (j; 0 .. limitFC[k])
                verts[j] = cast(uint)limitFI[cursor++];
            result.faces[k] = verts;
            int parent = faceOriginsRaw[k];
            int cageFi = markedFaceIndices[parent];
            if (cageFi >= 0) {
                result.setFaceSubpatch(k, cage.isFaceSubpatch(cageFi));
                // Hide (task 0613 S3) — same inheritance as Subpatch, stamped
                // on the OSD OUTPUT only (R5).
                result.setFaceHiddenBit(k, cage.isFaceHidden(cageFi));
            }
            // Material Groups (MG3): refined faces from the OSD subset
            // inherit their source cage face's surface index.
            if (cageFi >= 0 && cageFi < cast(int)cage.faceMaterial.length)
                result.faceMaterial[k] = cage.faceMaterial[cageFi];
        }

        // 4. Un-marked faces: walk each cage edge, insert the OSD
        //    edge-point if the adjacent marked face subdivided this
        //    edge (T-junction widening — keeps the mesh manifold).
        if (faceOriginOut !is null) {
            (*faceOriginOut).length = limitF;
            foreach (k; 0 .. limitF)
                (*faceOriginOut)[k] =
                    cast(uint)markedFaceIndices[faceOriginsRaw[k]];
        }
        foreach (fi; 0 .. nf) {
            immutable bool marked =
                (fi < faceMask.length) && faceMask[fi];
            if (marked) continue;
            const(uint)[] face = cage.faces[fi];
            uint[] widened;
            foreach (i; 0 .. face.length) {
                uint v0 = face[i];
                uint v1 = face[(i + 1) % face.length];
                widened ~= cast(uint)cageToNew[v0];
                if (auto cei = edgeKey(v0, v1) in cage.edgeIndexMap) {
                    if (auto ep = *cei in cageEdgeToOsdEdgePt)
                        widened ~= *ep;
                }
            }
            result.faces ~= widened;
            // Grow the per-face marks array in lock-step with `faces` and set
            // the Subpatch bit for the just-appended face (isSubpatch is now a
            // read-only @property backed by faceMarks).
            result.faceMarks.length = result.faces.length;
            immutable bool sub = (fi < cage.faceMarks.length)
                && (cage.faceMarks[fi] & Mesh.Marks.Subpatch) != 0;
            result.setFaceSubpatch(result.faces.length - 1, sub);
            // Hide (task 0613 S3): an un-marked cage face is carried across
            // whole (only widened at T-junctions), so it carries its hidden
            // state with it — this is the ONE stamp site where the preview
            // face IS a cage face, not a refined child of one.
            result.setFaceHiddenBit(result.faces.length - 1,
                                     cage.isFaceHidden(fi));
            // Material Groups (MG3): widened-but-unmarked cage faces
            // keep their original surface assignment.
            result.faceMaterial ~= (fi < cage.faceMaterial.length)
                ? cage.faceMaterial[fi] : 0u;
            if (faceOriginOut !is null)
                (*faceOriginOut) ~= cast(uint)fi;
        }

        // 5. Rebuild edges via dedup'd face-edge walk (vibe3d's
        //    addFace pattern). OSD's limit-edges array only covers
        //    the refined subset; widened un-marked faces add edges
        //    that aren't in OSD's view.
        uint[ulong] edgeLookup;
        foreach (face; result.faces) {
            foreach (i; 0 .. face.length) {
                uint a = face[i];
                uint b = face[(i + 1) % face.length];
                ulong key = edgeKey(a, b);
                if (key !in edgeLookup) {
                    result.edges ~= [a, b];
                    edgeLookup[key] = cast(uint)(result.edges.length - 1);
                }
            }
        }
    }

    // Selection masks sized to the new mesh; rebuild loops; bump
    // versions so downstream caches treat this as a fresh state
    // distinct from Mesh.init.
    result.resizeVertexSelection();
    result.resizeEdgeSelection();
    result.resizeFaceSelection();
    // Hide (task 0613 S3): the face plane was stamped from the cage above;
    // the vertex + edge planes are DERIVED (plan §1.2), and the derivation runs
    // on the OUTPUT topology — a preview vertex is hidden iff every incident
    // preview face is, which agrees with the cage's answer on the verts that
    // have a cage origin and is the only defined answer for the ones that do
    // not (edge points, face centroids). Must come AFTER the three resizes:
    // refreshHiddenDerived writes vertexMarks/edgeMarks in place and they are
    // sized here. Early-outs to three word-OR scans when nothing is hidden.
    result.refreshHiddenDerived();
    // Material Groups (MG3): per-mesh surface table travels through
    // subdivision unchanged — only `faceMaterial` indices change shape.
    // Surfaces dup so a later mutation of either side doesn't alias.
    result.surfaces = cage.surfaces.dup;
    result.mutationVersion = 1;
    result.topologyVersion = 1;
    result.buildLoops();
    return result;
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

// Fan-out shader — Phase 3b. Pulls OSD's per-limit-vert position
// output and emits the (xyz, xyz)-interleaved face-corner stream
// vibe3d's gpu.faceVbo expects, with flat normals computed on GPU.
// One transform-feedback dispatch (GL_POINTS, one shader invocation
// per face-corner) replaces the CPU readback that Phase 3a kept.
//
//   gl_VertexID                  → face-corner index (0..faceVertCount)
//   u_cornerToLimit[corner]      → limit-vert index for that corner
//   u_cornerToFaceId[corner]     → face id this corner belongs to
//   u_faceFirstVerts[3*fid+k]    → limit-vert indices of the face's
//                                  triangle-0 verts (drives flat normal)
//   u_limitPositions[limit]      → xyz from OSD GPU eval
//
// Output captured via GL_INTERLEAVED_ATTRIBS — sequential (vPos, vNorm)
// matches gpu.faceVbo's stride-6 layout exactly.
private immutable string FAN_OUT_VERT_SRC = q{
    #version 330 core
    uniform  isamplerBuffer u_cornerToLimit;
    uniform usamplerBuffer  u_cornerToFaceId;
    uniform  isamplerBuffer u_faceFirstVerts;
    uniform  samplerBuffer  u_limitPositions; // R32F: 3 floats per vert
    out vec3 vPos;
    out vec3 vNorm;
    vec3 fetchPos(int vi) {
        int   o = vi * 3;
        float x = texelFetch(u_limitPositions, o    ).r;
        float y = texelFetch(u_limitPositions, o + 1).r;
        float z = texelFetch(u_limitPositions, o + 2).r;
        return vec3(x, y, z);
    }
    void main() {
        int corner   = gl_VertexID;
        int limitIdx = texelFetch(u_cornerToLimit, corner).r;
        vPos         = fetchPos(limitIdx);

        int fid = int(texelFetch(u_cornerToFaceId, corner).r);
        int a   = texelFetch(u_faceFirstVerts, fid * 3 + 0).r;
        int b   = texelFetch(u_faceFirstVerts, fid * 3 + 1).r;
        int c   = texelFetch(u_faceFirstVerts, fid * 3 + 2).r;
        vec3 p0 = fetchPos(a);
        vec3 p1 = fetchPos(b);
        vec3 p2 = fetchPos(c);
        vec3 n  = cross(p1 - p0, p2 - p0);
        float l = length(n);
        vNorm   = l > 1e-6 ? n / l : vec3(0, 1, 0);
    }
};
// Empty fragment — rasterisation is disabled via GL_RASTERIZER_DISCARD;
// fragment shader exists only so the program links.
private immutable string FAN_OUT_FRAG_SRC = q{
    #version 330 core
    in vec3 vPos;
    in vec3 vNorm;
    void main() {}
};

// Single-output fan-out — Phase 3c. Used to fill edge / vert VBOs
// from OSD's per-limit-vert output. Same shape as the face fan-out
// but emits one vec3 per dispatch (per edge endpoint or per kept
// vert) instead of an interleaved pair. `u_indexLookup[gl_VertexID]`
// indirects through the caller-supplied TBO into `u_limitPositions`.
private immutable string POS_FAN_OUT_VERT_SRC = q{
    #version 330 core
    uniform isamplerBuffer u_indexLookup;
    uniform  samplerBuffer u_limitPositions; // R32F: 3 floats per vert
    out vec3 vPos;
    void main() {
        int   idx = texelFetch(u_indexLookup, gl_VertexID).r;
        int   o   = idx * 3;
        float x   = texelFetch(u_limitPositions, o    ).r;
        float y   = texelFetch(u_limitPositions, o + 1).r;
        float z   = texelFetch(u_limitPositions, o + 2).r;
        vPos      = vec3(x, y, z);
    }
};
private immutable string POS_FAN_OUT_FRAG_SRC = q{
    #version 330 core
    in vec3 vPos;
    void main() {}
};

private import bindbc.opengl;

/// Generic GLSL compile helper — returns 0 on failure, logging the
/// compile error to stderr.
private GLuint compileShaderStage(GLenum stage, string src) {
    import log        : logWarn;
    import std.string : toStringz;
    import std.conv   : to;
    GLuint sh = glCreateShader(stage);
    const(char)* p = src.toStringz;
    GLint        len = cast(GLint)src.length;
    glShaderSource(sh, 1, &p, &len);
    glCompileShader(sh);
    GLint ok;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[1024] log;
        glGetShaderInfoLog(sh, 1024, null, log.ptr);
        try logWarn("subpatch", "fan-out shader compile: " ~ log[].to!string);
        catch (Exception) {}
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

/// Link a vertex + fragment shader as a transform-feedback program
/// with the named varyings captured by the given buffer mode.
/// Returns 0 on failure.
private GLuint linkTfProgram(string vertSrc, string fragSrc,
                              const(char*)[] varyings,
                              GLenum bufferMode)
{
    import log       : logWarn;
    import std.conv  : to;
    GLuint vs = compileShaderStage(GL_VERTEX_SHADER,   vertSrc);
    if (!vs) return 0;
    GLuint fs = compileShaderStage(GL_FRAGMENT_SHADER, fragSrc);
    if (!fs) { glDeleteShader(vs); return 0; }
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glTransformFeedbackVaryings(prog, cast(GLsizei)varyings.length,
                                 varyings.ptr, bufferMode);
    glLinkProgram(prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[1024] log;
        glGetProgramInfoLog(prog, 1024, null, log.ptr);
        try logWarn("subpatch", "fan-out program link: " ~ log[].to!string);
        catch (Exception) {}
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

/// Face-corner fan-out program — emits (vPos, vNorm) interleaved
/// matching gpu.faceVbo's stride-6 layout.
private GLuint compileFanOutProgram() {
    import std.string : toStringz;
    const(char)*[2] varyings = [ "vPos".toStringz, "vNorm".toStringz ];
    return linkTfProgram(FAN_OUT_VERT_SRC, FAN_OUT_FRAG_SRC,
                          varyings[], GL_INTERLEAVED_ATTRIBS);
}

/// Single-vec3 fan-out program — used for edge endpoint and kept-vert
/// position writes (Phase 3c). One output (vPos) captured per
/// dispatch.
private GLuint compilePosFanOutProgram() {
    import std.string : toStringz;
    const(char)*[1] varyings = [ "vPos".toStringz ];
    return linkTfProgram(POS_FAN_OUT_VERT_SRC, POS_FAN_OUT_FRAG_SRC,
                          varyings[], GL_INTERLEAVED_ATTRIBS);
}

/// Map a stored edge-crease weight (1.0 == the editor UI's 100%) to
/// OpenSubdiv sharpness (task 1062). Measured off `toolcards/edge_weight/`
/// against the pinned shim: dead linear, `sharpness = 10 * weight`,
/// saturating at weight 1.0 — which lands exactly on OSD's own
/// SHARPNESS_INFINITE threshold (`sdc/crease.h`, 10.0f), so no separate
/// clamp constant is needed at the top end. Negative weights are inert
/// (clamped to 0, not honoured with the opposite sign); the map itself
/// still STORES whatever was written, verbatim — this function is the one
/// and only place the clamp happens (source/mesh.d's setCreaseWeight does
/// not clamp; neither does the `.v3d` codec).
///
/// NaN-safe by construction, and this is load bearing, not incidental: the
/// test is `w > 0`, so NaN (which compares false against every relational
/// operator) and any `w <= 0` both fall through to the `0` return. A
/// `Param`'s `.enforceBounds()` clamp is UI-only and does not reject NaN on
/// the headless/HTTP write path (source/params.d), so this is the one place
/// that does — a NaN sharpness would otherwise reach OSD's IsSmooth/
/// IsInfinite tests (both false on NaN, `sdc/crease.h`) and hand the
/// renderer a NaN mesh.
///
/// NOTE for the next reader, and this note is load-bearing too: the
/// reference editor's OTHER subdivision surface type (not Catmull-Clark)
/// shares the SAME per-edge map but responds QUADRATICALLY to weight and
/// HONOURS negative weights — its shipped help text describes THAT law, not
/// this one. vibe3d has no such surface type; this function ports the
/// Catmull-Clark law only, pinned bit-for-bit by
/// `tests/fixtures/edge_crease_weight.json`. Do not "fix" this toward the
/// help text — see doc/behavior_gap_registry.md's divergence-deliberate row
/// for task 1062.
float creaseSharpnessFromWeight(float w) pure nothrow @nogc @safe {
    if (!(w > 0)) return 0.0f;
    return w >= 1.0f ? 10.0f : 10.0f * w;
}

struct OsdAccel {
    private osdc_topology_t*     osd;
    private osdc_gl_evaluator_t* glEval;        // null when no GL context

    // Phase 3a — readback path. cageGlVbo / limitGlVbo are also reused
    // by the Phase 3b fan-out path below (limitGlVbo is the source the
    // fan-out shader reads through limitTex).
    private GLuint               cageGlVbo;
    private GLuint               limitGlVbo;
    private float[]              cageScratchXyz;
    private float[]              limitScratchXyz;    // Phase 3a readback

    // Phase 3b — fan-out infrastructure. Built once at buildPreview;
    // refreshIntoFaceVbo dispatches a single TF draw per drag frame.
    private GLuint  cornerToLimitVbo;      // R32I  storage buffer
    private GLuint  cornerToLimitTex;      // TBO   view
    private GLuint  cornerToFaceIdVbo;     // R32UI storage
    private GLuint  cornerToFaceIdTex;
    private GLuint  faceFirstVertsVbo;     // R32I  storage (3 ints / face)
    private GLuint  faceFirstVertsTex;
    private GLuint  limitTex;              // R32F TBO over limitGlVbo (3 floats/vert)
    private GLuint  fanOutProgram;
    private GLint   locCornerToLimit;
    private GLint   locCornerToFaceId;
    private GLint   locFaceFirstVerts;
    private GLint   locLimitPositions;
    private int     faceVertCount;         // glDrawArrays count for TF

    // Phase 3c — edge VBO + vert VBO fan-out (single-vec3 capture).
    private GLuint  posFanOutProgram;
    private GLint   locPosIndexLookup;
    private GLint   locPosLimitPositions;
    private GLuint  edgeSegToLimitVbo;     // R32I storage
    private GLuint  edgeSegToLimitTex;     // TBO view
    private int     edgeSegCount;          // dispatch count for refreshEdgeVbo
    private GLuint  vertToLimitVbo;        // R32I storage
    private GLuint  vertToLimitTex;        // TBO view
    private int     keptVertCount;         // dispatch count for refreshVertVbo

    private int     limitVertCount;
    // Dedicated empty VAO for fan-out TF dispatches. We cannot reuse
    // the caller's VAO: that VAO typically has vertex attribs enabled
    // pointing AT gpu.faceVbo (for the normal rasterising draw), and
    // glDrawArrays during transform feedback raises GL_INVALID_OPERATION
    // when any enabled vertex-attrib buffer is also the TF write target
    // ("feedback loop"). A fresh VAO with no enabled attribs sidesteps
    // the loop check.
    private GLuint  tfVao;

    // ---- Scratch buffers re-used across rebuilds. ------------------
    // P0 of doc/subpatch_tab_perf_plan.md — every fresh `new T[]` in
    // buildPreview hit the global GC spinlock at 24K cage polys (top
    // sample at 10.5%). These slices keep their capacity across
    // clear() so a second rebuild at the same N does no allocation.
    // outMesh.faces[fi] is slice-aliased into scratchFaceIndices so the
    // per-face uint[] allocations disappear too.
    //
    // NOTE — outMesh.faces[fi] dangles if `scratchFaceIndices.length`
    // is set to 0 between buildPreview and the consumer's read. Don't
    // clear it in clear(); buildPreview is the only writer, and it
    // re-populates every fi before returning.
    // Task 1500 — FRONT/BACK POOL, and it is PERMANENT rather than
    // per-build. These three are the limit-proportional buffers the emitted
    // preview either slice-ALIASES (`faces[fi]` into `faceIndicesI`) or is
    // read beside, so a background build writing them while the live preview
    // aliases them is a read of half-overwritten geometry. Two sets, swapped
    // at INSTALL, remove that by construction.
    //
    // PERMANENT is the answer to "does this give back P0/P5's win": the
    // second set is allocated once, at the first build, and keeps its
    // capacity for the process's life exactly like the first — so the
    // GC-spinlock contention P0 removed comes back for the FIRST Tab only,
    // not for every one. The cost is named in the task's risk 2: peak memory
    // grows by one limit-proportional set.
    private struct LimitScratch {
        int[] faceCounts;
        int[] faceIndicesI;   // OSD writes int; Mesh.faces views as uint
        int[] edgeVerts;
    }
    private LimitScratch[2] limitPool;
    private size_t          limitBack = 1;   // the slot a build WRITES
    private int[]  scratchFaceOrigins;
    private int[]  scratchVertOrigins;
    private int[]  scratchEdgeOrigins;
    private int[]  scratchOsdCageEdgeVerts;
    private uint[] scratchOsdToVibe3dCageEdge;
    private int[]  scratchCornerToLimit;
    private uint[] scratchCornerToFaceId;
    private int[]  scratchFaceFirstVerts;
    private int[]  scratchEdgeSegToLimit;
    private int[]  scratchVertToLimit;
    // Cage-side flatten buffers (task 1374). CAGE-proportional, unlike every
    // scratch buffer above, which is LIMIT-proportional — on the n=316 fixture
    // at level 1 those two are within 0.4 % of each other, but at level 2 the
    // limit buffers are 4× larger, so do not reason about one from the other.
    // Reused across rebuilds by `flattenCageTopology`; NOT cleared by clear()
    // for the same reason the others are not (capacity is the point).
    // (Task 1500: the cage-side flatten buffers that used to live here are
    // gone — they are `CageSnapshot.faceVertCounts` /
    // `.faceVertIndices` now, OWNED by the snapshot, because a worker
    // reading them while the next snapshot overwrote them is a race that no
    // amount of call-site discipline removes.)

    // P1: sorted (key, value) array replacing the uint[ulong]
    // vibe3dEdgeByVerts AA. With ~50K cage edges on a 24K-poly cage
    // the AA was 13% of CPU after P0 (top sample); a sorted-array +
    // binary search is ~3-5× faster per lookup and allocation-bounded.
    private struct EdgeKv { ulong key; uint value; }
    private EdgeKv[] scratchVibe3dEdgeKv;

    // Direction A (doc/subpatch_tab_next_directions.md): LRU(2) cache
    // of the heavy OSD-side state, keyed by a hash over the
    // (face-vert topology, level, creases, corners) tuple. OSD's
    // `Far::TopologyRefiner` is immutable post-construction —
    // sharpness markers are baked in at refinement time — so the
    // cache key MUST include the sharpness vector. Back-and-forth Tab
    // toggling on a 24K cage flips between two distinct sharpness
    // vectors; LRU(2) gives a 100 % hit rate after one full cycle and
    // skips the StencilBuilder / QuadRefinement / topology-create
    // work that dominates ~28 % of Tab CPU after the P0-P5 wins.
    private struct CachedTopology {
        ulong                 keyHash;          // 0 = slot empty
        osdc_topology_t*      osd;
        osdc_gl_evaluator_t*  glEval;
        GLuint                cageGlVbo;
        GLuint                limitGlVbo;
        int                   numCageVerts;
        int                   limitVerts;
        size_t                lastUseEpoch;     // monotonic; LRU = smaller
    }
    private CachedTopology[2] topologyCache;
    private size_t            cacheEpoch;       // incremented on every hit/miss

    bool valid;

    // ---- Async build bookkeeping (task 1500) -----------------------------

    /// Called FIRST, inside `clear()` and `destroyCache()`, before either
    /// touches state a background build might still be reading.
    ///
    /// WHERE IT IS LOAD-BEARING, stated precisely rather than generally.
    /// `destroyCache()` FREES `osdc_topology_t*`s — and a build that HIT the
    /// LRU is reading exactly one of them, borrowed. Without the join that is
    /// a use-after-free inside OpenSubdiv, on a thread whose stack names
    /// nothing about the reset that caused it.
    ///
    /// `clear()`'s copy is a CONSTRUCTION guarantee, not a live fix, and it
    /// is worth saying so: after task 1500's split, `clear()` frees only
    /// fan-out GL objects and nulls aliases the worker no longer reads (it
    /// builds from a `CageSnapshot` and its own local topology pointer), so
    /// no CURRENT call site depends on it. It stays because `clear()` is the
    /// destructive primitive every future reset path will reach for, and a
    /// list of call sites loses its fourth entry within a month — the Tab-OFF
    /// path (`SubpatchPreview.rebuild(source, d <= 0)`) was the one the
    /// design's first draft had already missed.
    ///
    /// INSIDE, not at the call sites: a new call site is then safe by
    /// construction rather than by its author having heard of the worker.
    /// M-RESET witnesses the ordering property on both.
    void delegate() joinInFlightHook;

    /// Topologies this accel created, and gave back. The pair is the leak
    /// witness: under "last dispatch wins" a discarded result owns an
    /// `osdc_topology_t` that nothing else will ever free, and
    /// `created - retired` is what grows when `retireResult` is skipped.
    /// Reported through GET /api/subpatch/preview. M-LEAK.
    ulong topologiesCreated;
    ulong topologiesRetired;

    /// Reset per-rebuild state. The OSD-side handles (osd, glEval,
    /// cageGlVbo, limitGlVbo) are OWNED BY `topologyCache` and live
    /// across clear()s. This call just zeroes our local references
    /// to whichever cache slot was last active and frees the
    /// per-build fan-out infrastructure that we always rebuild from
    /// scratch (TBOs, programs, the empty TF VAO).
    void clear() {
        // Task 1500 — FIRST STATEMENT. Everything below nulls a handle or
        // frees a GL object a background build may still be reading; the
        // hook is what makes a NEW call site to this function safe without
        // its author having heard of the worker thread. M-RESET.
        if (joinInFlightHook !is null) joinInFlightHook();
        // OSD-side handles: cache owns; just null the local refs.
        osd       = null;
        glEval    = null;
        cageGlVbo = 0;
        limitGlVbo = 0;

        if (cornerToLimitVbo != 0)       { glDeleteBuffers (1, &cornerToLimitVbo); cornerToLimitVbo = 0; }
        if (cornerToFaceIdVbo != 0)      { glDeleteBuffers (1, &cornerToFaceIdVbo); cornerToFaceIdVbo = 0; }
        if (faceFirstVertsVbo != 0)      { glDeleteBuffers (1, &faceFirstVertsVbo); faceFirstVertsVbo = 0; }
        if (cornerToLimitTex != 0)       { glDeleteTextures(1, &cornerToLimitTex); cornerToLimitTex = 0; }
        if (cornerToFaceIdTex != 0)      { glDeleteTextures(1, &cornerToFaceIdTex); cornerToFaceIdTex = 0; }
        if (faceFirstVertsTex != 0)      { glDeleteTextures(1, &faceFirstVertsTex); faceFirstVertsTex = 0; }
        if (limitTex != 0)               { glDeleteTextures(1, &limitTex); limitTex = 0; }
        if (tfVao != 0)                  { glDeleteVertexArrays(1, &tfVao); tfVao = 0; }
        if (fanOutProgram != 0)          { glDeleteProgram (fanOutProgram); fanOutProgram = 0; }
        if (posFanOutProgram != 0)       { glDeleteProgram (posFanOutProgram); posFanOutProgram = 0; }
        if (edgeSegToLimitVbo != 0)      { glDeleteBuffers (1, &edgeSegToLimitVbo); edgeSegToLimitVbo = 0; }
        if (edgeSegToLimitTex != 0)      { glDeleteTextures(1, &edgeSegToLimitTex); edgeSegToLimitTex = 0; }
        if (vertToLimitVbo != 0)         { glDeleteBuffers (1, &vertToLimitVbo); vertToLimitVbo = 0; }
        if (vertToLimitTex != 0)         { glDeleteTextures(1, &vertToLimitTex); vertToLimitTex = 0; }
        // Note: `osd` is NOT destroyed here — see field-level
        // comment. The cache owns it; clear() just zeroed our ref.
        cageScratchXyz.length  = 0;
        limitScratchXyz.length = 0;
        limitVertCount         = 0;
        faceVertCount          = 0;
        edgeSegCount           = 0;
        keptVertCount          = 0;
        valid                  = false;
    }

    /// Free every cached OSD handle and GL resource — the LRU(2) topology
    /// cache, and nothing else — and leave this `OsdAccel` in a state that is
    /// safe to touch afterwards.
    ///
    /// SAFE BY CONSTRUCTION, not by call order. The slots own `osd` / `glEval`
    /// / `cageGlVbo` / `limitGlVbo`, and `OsdAccel`'s OWN fields of those names
    /// are borrowed aliases into whichever slot was last active — so freeing
    /// the storage without dropping the aliases would leave them pointing at
    /// destroyed OSD objects while `valid` still said yes, and the next
    /// `refresh()` (which checks only `valid`) would dereference freed memory.
    /// This used to be an ordering CONTRACT on the caller — `clear()` first,
    /// then this — with two call sites each getting it right by hand. It is now
    /// discharged here: the aliases are nulled and `valid` is cleared below, so
    /// the function is correct called on its own. `clear()` remains the right
    /// companion at the reset hooks because it ALSO frees the per-build fan-out
    /// GL infrastructure (TBOs, programs, the TF VAO), which this does not
    /// touch — but that is a completeness reason, no longer a safety one.
    ///
    /// Does NOT touch the `scratch*` buffers, by design — they are pure
    /// capacity, hold no handle, and keeping them is what makes a second build
    /// cheap. Read that the other way round when measuring: an in-process
    /// forced miss after this call is a COLD-TOPOLOGY / WARM-BUFFER build, not
    /// the virgin one a freshly launched process performs. See
    /// `tools/perf/run.d`'s `runTabCold` for how that regime is pinned rather
    /// than left to whatever ran before.
    ///
    /// WHY THE SCENE-RESET HOOKS CALL IT (source/registration.d, `scene.reset`
    /// and `file.new`) — and NOT for the reason a first reading suggests. The
    /// topology key hashes `(nv, nf, effectiveLevel, faceVertCounts,
    /// faceVertIndices, creases, corners)` and NOT vertex positions, correctly,
    /// since an OSD stencil table is position-independent. So a slot surviving
    /// a reset to the same primitive and being reused is CORRECT — it is not a
    /// discarded scene leaking into a fresh one, and anyone "fixing" that is
    /// fixing a bug that is not there. The two real reasons are:
    ///   * MEMORY — File→New / scene reset should not keep two stencil tables
    ///     for a 100k cage alive across a document the user threw away; and
    ///   * MEASUREMENT — it is the only in-process lever that makes the next
    ///     Tab a genuine topology MISS, which is what `tab-cold` needs and what
    ///     F-I8 refuses to report without (tools/perf/run.d).
    ///
    /// Also the unittest-hygiene call: a fixture `OsdAccel` that built a
    /// preview owns an `osdc_topology_t*` that `~this()` (which calls only
    /// `clear()`) does not free.
    void destroyCache() {
        // Task 1500 — same reason as clear()'s first statement, and a
        // stronger one: this FREES the topology a worker could be reading.
        if (joinInFlightHook !is null) joinInFlightHook();
        foreach (ref e; topologyCache) {
            if (e.glEval    !is null) osdc_gl_destroy(e.glEval);
            if (e.cageGlVbo != 0)     glDeleteBuffers(1, &e.cageGlVbo);
            if (e.limitGlVbo != 0)    glDeleteBuffers(1, &e.limitGlVbo);
            if (e.osd       !is null) { osdc_topology_destroy(e.osd);
                                        ++topologiesRetired; }
            e = CachedTopology.init;
        }
        // The borrowed aliases into whatever slot was last active. Dropping
        // them here is what makes the function safe standalone; `valid` is the
        // one of the five that is observable from outside the module, and it is
        // the one `refresh()` gates on, so it is also the witness — see
        // tests/unit/subpatch_level_policy_test.d.
        osd        = null;
        glEval     = null;
        cageGlVbo  = 0;
        limitGlVbo = 0;
        valid      = false;
    }

    /// Look up a cached OSD topology by hash. A PURE QUERY (task 1500).
    ///
    /// It used to write `this.osd / glEval / cageGlVbo / limitGlVbo /
    /// limitVertCount` on a hit. It cannot any more, because the lookup now
    /// runs on the BUILDING thread while the LIVE preview is still on
    /// screen — and the live preview's per-drag-frame `refresh()` evaluates
    /// against exactly `this.osd`. Adoption happens in `installGl`, on the
    /// main thread, at the moment the result is published.
    struct TopoLookup {
        bool                 hit;
        osdc_topology_t*     osd;
        osdc_gl_evaluator_t* glEval;
        GLuint               cageGlVbo;
        GLuint               limitGlVbo;
        int                  limitVerts;
    }
    TopoLookup lookupCachedTopology(ulong keyHash) const {
        TopoLookup r;
        foreach (ref const e; topologyCache) {
            if (e.keyHash != 0 && e.keyHash == keyHash) {
                r.hit        = true;
                r.osd        = cast(osdc_topology_t*)e.osd;
                r.glEval     = cast(osdc_gl_evaluator_t*)e.glEval;
                r.cageGlVbo  = e.cageGlVbo;
                r.limitGlVbo = e.limitGlVbo;
                r.limitVerts = e.limitVerts;
                return r;
            }
        }
        return r;
    }

    /// Mark a slot most-recently-used. Split out of the lookup because the
    /// lookup is now a const query that a non-main thread performs; the LRU
    /// epoch is main-thread state and moves at INSTALL.
    private void touchCacheSlot(ulong keyHash) {
        ++cacheEpoch;
        foreach (ref e; topologyCache)
            if (e.keyHash != 0 && e.keyHash == keyHash) e.lastUseEpoch = cacheEpoch;
    }

    /// Install a freshly-built OSD topology (and its derived GL
    /// state) into the cache. Evicts the LRU slot if both are full.
    /// The handles are passed EXPLICITLY rather than read off `this`: the
    /// caller is the receiver of a build that may have run elsewhere, and
    /// reading `this.osd` here would silently install whatever the previous
    /// preview left behind.
    private void installInCache(ulong keyHash, int numCageVerts,
                                 osdc_topology_t* topo,
                                 osdc_gl_evaluator_t* ev,
                                 GLuint cageVbo, GLuint limitVbo,
                                 int limitVerts) {
        ++cacheEpoch;
        // Pick the slot to write into: prefer an empty slot, else
        // the entry with the smaller lastUseEpoch (= LRU).
        size_t slot = 0;
        if (topologyCache[0].keyHash == 0) {
            slot = 0;
        } else if (topologyCache[1].keyHash == 0) {
            slot = 1;
        } else {
            slot = (topologyCache[0].lastUseEpoch
                    <= topologyCache[1].lastUseEpoch) ? 0 : 1;
            // Evict the chosen slot's resources.
            auto e = &topologyCache[slot];
            if (e.glEval    !is null) osdc_gl_destroy(e.glEval);
            if (e.cageGlVbo != 0)     glDeleteBuffers(1, &e.cageGlVbo);
            if (e.limitGlVbo != 0)    glDeleteBuffers(1, &e.limitGlVbo);
            if (e.osd       !is null) { osdc_topology_destroy(e.osd);
                                        ++topologiesRetired; }
            *e = CachedTopology.init;
        }
        topologyCache[slot] = CachedTopology(
            keyHash, topo, ev, cageVbo, limitVbo,
            numCageVerts, limitVerts, cacheEpoch);
    }

    /// Phase 3b only: true iff the fan-out path is set up and can be
    /// invoked via refreshIntoFaceVbo.
    @property bool canFanOut() const {
        return fanOutProgram != 0 && limitGlVbo != 0
            && cornerToLimitVbo != 0 && cornerToFaceIdVbo != 0
            && faceFirstVertsVbo != 0 && limitTex != 0;
    }

    /// Phase 3c: GPU fan-out for the edge / vert VBOs is available.
    /// Each independently gated — selective subpatch may produce an
    /// empty kept-edge or kept-vert set, in which case the dispatch
    /// count is 0 and the property reports false.
    @property bool canFanOutEdges() const {
        return posFanOutProgram != 0 && limitTex != 0
            && edgeSegToLimitTex != 0 && edgeSegCount > 0;
    }
    @property bool canFanOutVerts() const {
        return posFanOutProgram != 0 && limitTex != 0
            && vertToLimitTex != 0 && keptVertCount > 0;
    }

    /// Free OSD resources at scope exit. The struct is owned by
    /// SubpatchPreview, which lives for the program's duration, so this
    /// fires once — but it keeps `dub test` (and any future short-lived
    /// SubpatchPreview instances) leak-clean.
    ~this() { clear(); }

    /// Build OSD topology + stencil table for `cage` at `level`, emit
    /// the limit Mesh (verts/edges/faces/loops) and SubpatchTrace.
    /// Selective subpatch (mixed isSubpatch flags) tags every edge /
    /// vert that touches an un-marked face with infinite sharpness —
    /// OSD then smooths the marked-region interior and keeps the
    /// un-marked region flat, with a sharp crease at the boundary.
    /// A subdivision-surface crease-weight visual model.
    ///
    /// Returns false (and clears state) on degenerate input or OSD
    /// topology-creation failure.
    ///
    /// Corner-provenance (task 0901): verified NOT APPLICABLE, same
    /// reasoning as `catmullClarkOsd` above — `cage` is `const`, `outMesh` is
    /// an `out` parameter (always freshly `.init`'d), and no caller ever
    /// registers a PolyVertex map on a preview mesh. The hot per-frame
    /// `refresh()` below only ever writes `preview.vertices`, never
    /// `preview.faces`, so even a live map on a preview mesh would never
    /// reach a face rewrite through this class.
    /// `memLimitFaces` is the ceiling `chooseSubpatchLevel` applies, exposed
    /// as a parameter for ONE reason: without it, asserting anything about the
    /// depth policy through this function costs a cage big enough to trip the
    /// production ceiling — 12 501 triangles at minimum, i.e. a 600 000-face
    /// refinement per assertion. Driving the ceiling instead of the cage
    /// asks the same question on a single hexagon. Production callers never
    /// pass it (see SubpatchPreview.rebuild); it is the test escape that keeps
    /// the level-choice assertions out of a synthetic re-implementation of the
    /// policy, which would be inert.
    // ======================================================================
    // THE BUILD, CUT IN THREE (task 1500)
    // ======================================================================
    //
    // `buildFromSnapshot` is the whole cost and contains NOT ONE GL CALL.
    // `installGl` is every GL call the build ever made, and is what the main
    // thread pays on the frame the result lands. `buildPreview` is the two of
    // them back to back and is what every SYNCHRONOUS caller still calls
    // (module unittests, and the IPR preview in source/render/render_mvp.d) —
    // so the cut costs those callers nothing and adds no second
    // implementation of the build.
    //
    // WHY `clear()` MOVED, and it is an observable change of ORDER rather
    // than a tidy-up. It used to be the second statement of the build. It is
    // now the first statement of the INSTALL, because the old preview has to
    // stay alive and drawable for the whole time the new one is being built —
    // that is the entire point of the async path. On the synchronous path the
    // two orders are indistinguishable: nothing runs in between.
    //
    // WHAT STAYS ON THE MAIN THREAD, and it is not a list to be remembered —
    // `installGl`'s first statement is `glThreadGuard`, so a call that drifts
    // the other way names itself. See M-GL.

    /// Pure-CPU half of the build: cage flatten is already done (it is the
    /// snapshot), sharpness arrays, level choice, topology key, the LRU
    /// lookup, `osdc_topology_create_sharp` on a miss, the limit-topology and
    /// origin reads, `osdc_evaluate`, and the whole of `outMesh` /
    /// `SubpatchTrace` / materials / hide planes.
    ///
    /// NO GL CALL MAY APPEAR IN THIS FUNCTION. That is not a convention: the
    /// witness is `tests/unit/subpatch_osd_test.d`, which runs it on a
    /// non-GL thread with the thread guard armed and requires it not to throw.
    ///
    /// Writes its limit-proportional scratch into the BACK slot of the
    /// front/back pool, so `outMesh.faces[fi]`'s slice-alias into
    /// `faceIndicesI` cannot land on the buffer the LIVE preview is aliasing.
    /// The swap happens in `installResult`, never here.
    bool buildFromSnapshot(ref const CageSnapshot snap,
                            ref PreviewBuildResult res)
    {
        import core.time   : MonoTime;
        import core.memory : GC;
        immutable MonoTime tStart      = MonoTime.currTime;
        immutable ulong    allocBefore = GC.allocatedInCurrentThread;
        scope(exit) {
            res.workerNs = (MonoTime.currTime - tStart).total!"nsecs";
            res.workerAllocBytes =
                cast(long)(GC.allocatedInCurrentThread - allocBefore);
        }

        res.ok             = false;
        res.topo           = null;
        res.topoOwned      = false;
        res.cacheHit       = false;
        res.mesh           = Mesh.init;
        res.trace          = SubpatchTrace.init;
        res.requestedLevel = snap.level;
        res.chosenLevel    = snap.level;
        res.cageCornerCount = snap.cornerCount;
        res.memLimitFaces  = snap.memLimitFaces;
        res.numCageVerts   = snap.nv;

        immutable int nv = snap.nv;
        immutable int nf = snap.nf;
        if (nv == 0 || nf == 0 || snap.level < 1) return false;
        // `!anyMarked` — the snapshot already answered it (same early-out the
        // pre-1500 build made after its own scan of the cage).
        if (!snap.anyMarked) return false;

        const(int)[] faceVertCounts  = snap.faceVertCounts;
        const(int)[] faceVertIndices = snap.faceVertIndices;

        // ---- Cage edge (min,max)-key -> cage edge index ---------------
        // Was `cage.edgeIndexMap` (an AA on the live Mesh) for the sharpness
        // pass and a sorted array built later for the OSD-edge translation.
        // One sorted array now serves both: the snapshot cannot carry the AA
        // without paying ~ne GC inserts per dispatch, and the two lookups ask
        // the same question with the same key scheme (`mesh.edgeKey`).
        immutable size_t cageEdgeCount = snap.edgeCount;
        scratchVibe3dEdgeKv.length = cageEdgeCount;
        foreach (ei; 0 .. cageEdgeCount) {
            uint a = snap.edgeVerts[2*ei + 0], b = snap.edgeVerts[2*ei + 1];
            scratchVibe3dEdgeKv[ei] = EdgeKv(edgeKey(a, b), cast(uint)ei);
        }
        {
            import std.algorithm.sorting : sort;
            sort!"a.key < b.key"(scratchVibe3dEdgeKv);
        }

        // ---- Selective-subpatch + crease-weight sharpness arrays -----
        // Two independent contributors write into the SAME per-edge sharp[]
        // array, combined by MAX (task 1062 §2a): selective subpatch writes
        // SHARP_INF on any edge touching an un-marked face; the reserved
        // crease-weight MeshMap (source/mesh.d, MapKind.creaseWeight) writes
        // creaseSharpnessFromWeight(w). The max is not defensive tidiness —
        // it is required: Far's assignComponentTags
        // (far/topologyDescriptor.cpp) applies crease entries by
        // ASSIGNMENT, so a plain append-and-hope would let a later, lower
        // entry for the SAME edge pair overwrite an earlier higher one
        // (e.g. a stray 0.02 crease-map weight silencing a selective-
        // subpatch SHARP_INF on the same edge).
        //
        // For each cage vert that has at least one un-marked incident face:
        // corner-sharpen so the vert stays at the cage position (selective
        // subpatch only — crease weights are an edge-only law; the crease-
        // map's own vertex-rule response comes from two sharp EDGES meeting
        // at a corner, not from a corner tag — see the "creased loop"
        // fixture cases).
        //
        // Uniform-subpatch cage with no crease map → both contributors
        // empty → standard smooth CC, unchanged from before this task.
        int[]   creasePairs;
        float[] creaseWeights;
        int[]   cornerVerts;
        float[] cornerWeights;
        enum float SHARP_INF = 10.0f;     // OSD treats >= 10 as infinity

        if (snap.anyUnmarked || snap.creaseMapLive) {
            // The settled-cage precondition that used to open this block
            // (`cage.assertEdgeMapValid()`, task 0724 / 0833) now fires at
            // SNAPSHOT time, under this same condition — see
            // `takeCageSnapshot`. It asks about the live mesh's derived
            // state, so it has to be asked while the live mesh is in reach.
            //
            // Tag verts that ANY un-marked face touches.
            bool[] vertHasUnmarked = new bool[](nv);
            // Per-edge: count marked vs un-marked adjacency (selective
            // subpatch) AND total incident-face count (the boundary guard
            // below, task 1062 §2b). The guard is keyed on the EDGE's own
            // incident-face count, NEVER on its endpoints: fixture boundary
            // case 10 is an INTERIOR edge one of whose endpoints sits on the
            // boundary rim, and the reference DOES crease it — an
            // endpoint-keyed guard ("skip if either endpoint is a boundary
            // vertex") would wrongly skip this edge. This is the mutation
            // for that assertion.
            int[2][] edgeFaces;
            int[]    edgeFaceTotal;
            edgeFaces.length     = cageEdgeCount;
            edgeFaceTotal.length = cageEdgeCount;
            {
                size_t cursor = 0;
                foreach (fi; 0 .. cast(size_t)nf) {
                    immutable int    fl     = faceVertCounts[fi];
                    immutable bool   marked = snap.faceSubpatch[fi];
                    foreach (i; 0 .. fl) {
                        uint a = cast(uint)faceVertIndices[cursor + i];
                        uint b = cast(uint)faceVertIndices[cursor + (i + 1) % fl];
                        if (!marked) {
                            vertHasUnmarked[a] = true;
                            vertHasUnmarked[b] = true;
                        }
                        immutable uint ei = findCageEdgeByKey(edgeKey(a, b));
                        if (ei != uint.max) {
                            if (marked) ++edgeFaces[ei][0];
                            else        ++edgeFaces[ei][1];
                            ++edgeFaceTotal[ei];
                        }
                    }
                    cursor += fl;
                }
            }

            // Combine both contributors per edge into one sharpness value,
            // then emit a single (pair, weight) entry per creased edge.
            // `float.init` is NaN in D, so an explicit zero-fill is
            // required — `new float[]` alone left every entry NaN, which
            // made `sharp[ei] <= 0` false for EVERY edge (NaN compares
            // false against everything) and emitted all 12 cube edges with
            // a NaN crease weight instead of skipping the un-creased ones.
            // Caught 2026-08-17 by Stage6's fixture comparison going red on
            // the very first nonzero-weight case.
            float[] sharp = new float[](cageEdgeCount);
            sharp[] = 0.0f;
            foreach (ei; 0 .. cageEdgeCount) {
                if (edgeFaces[ei][1] > 0) sharp[ei] = SHARP_INF;
            }
            if (snap.creaseMapLive) {
                // Boundary guard: a weight must NEVER be able to lower a
                // boundary edge (task 1062 card requirement — an assertion,
                // not a comment). An edge with < 2 incident faces is left
                // OUT of the crease map's contribution entirely, so this
                // guard can only ever be REDUNDANT with what OpenSubdiv does
                // structurally (far/topologyRefinerFactory.cpp sets every
                // boundary edge's sharpness to SHARPNESS_INFINITE
                // unconditionally, AFTER the descriptor's crease weights are
                // applied) — never in tension with it, and never able to
                // raise a boundary edge's sharpness above infinite either.
                foreach (ei; 0 .. cageEdgeCount) {
                    if (edgeFaceTotal[ei] < 2) continue;   // boundary edge
                    immutable float w = ei < snap.creaseWeights.length
                        ? snap.creaseWeights[ei] : 0.0f;
                    immutable float s = creaseSharpnessFromWeight(w);
                    if (s > sharp[ei]) sharp[ei] = s;
                }
            }
            foreach (ei; 0 .. cageEdgeCount) {
                if (sharp[ei] <= 0) continue;
                creasePairs   ~= cast(int)snap.edgeVerts[2*ei + 0];
                creasePairs   ~= cast(int)snap.edgeVerts[2*ei + 1];
                creaseWeights ~= sharp[ei];
            }

            // Corner: any cage vert touching an un-marked face.
            foreach (vi; 0 .. nv) {
                if (!vertHasUnmarked[vi]) continue;
                cornerVerts   ~= cast(int)vi;
                cornerWeights ~= SHARP_INF;
            }
        }

        // ---- Depth cap so OSD's stencil build stays in memory --------
        // The policy itself is `chooseSubpatchLevel` (module scope) — see it
        // for why the projection is in CORNERS, not faces, and which cages
        // that moves.
        immutable int effectiveLevel =
            chooseSubpatchLevel(snap.cornerCount, snap.level, snap.memLimitFaces);
        res.chosenLevel = effectiveLevel;
        // The counters and the cap warning are PUBLISHED BY THE MAIN THREAD
        // on reception (`publishBuildCounters`), not written here: `g_perf`
        // is `__gshared` and the perf lane's F-I8 reads exactly these keys,
        // so a worker writing them straight would make that invariant racy.

        // ---- Compute topology-cache key -------------------------------
        // Hashes the full (face-vert topology, level, creases,
        // corners) tuple. A Tab toggle that flips the cage's
        // isSubpatch flags produces a DIFFERENT key (different
        // creases / corners) — so back-and-forth toggling oscillates
        // between two distinct keys. LRU(2) holds both after one
        // full cycle and never re-builds the OSD topology again.
        ulong topoKey;
        {
            import core.internal.hash : hashOf;
            topoKey = hashOf(nv);
            topoKey = hashOf(nf, topoKey);
            topoKey = hashOf(effectiveLevel, topoKey);
            topoKey = hashOf(faceVertCounts,  topoKey);
            topoKey = hashOf(faceVertIndices, topoKey);
            topoKey = hashOf(creasePairs,   topoKey);
            topoKey = hashOf(creaseWeights, topoKey);
            topoKey = hashOf(cornerVerts,   topoKey);
            topoKey = hashOf(cornerWeights, topoKey);
            // Guard against the sentinel "empty slot" hash colliding
            // with a real key. 1-in-2^64 chance, but mapping zero to
            // a fixed non-zero value costs nothing.
            if (topoKey == 0) topoKey = 1;
        }
        res.topoKey = topoKey;

        // ---- LRU(2) topology lookup ------------------------------------
        // A PURE QUERY (task 1500): it must not write `this.osd` the way the
        // old `tryReuseCachedTopology` did, because the LIVE preview's
        // per-drag-frame `refresh()` evaluates against exactly that pointer
        // and this function runs while the live preview is still on screen.
        // The receiver adopts the pointer, on the main thread, in
        // `installResult`.
        // recorded remainder (1906 §3.6): this key is a CONTENT HASH and no
        // counter or bus class can replace it. It is SLOT ADDRESSING in a
        // shared LRU whose entries are reused across meshes and depths, not a
        // freshness check: "something changed" cannot pick a slot, only "which
        // content" can. Owned by nothing on `Mesh` — the hash above is the
        // whole key. See plan §3.4 row 11 for the provenance split.
        auto look = lookupCachedTopology(topoKey);
        osdc_topology_t* osdLocal;
        if (look.hit) {
            osdLocal        = look.osd;
            res.cacheHit    = true;
            res.topoOwned   = false;
            res.limitVertCount = look.limitVerts;
        } else {
            osdLocal = osdc_topology_create_sharp(
                nv, nf,
                faceVertCounts.ptr, faceVertIndices.ptr,
                effectiveLevel,
                cast(int)(creasePairs.length / 2),
                creasePairs.length   ? creasePairs.ptr   : null,
                creaseWeights.length ? creaseWeights.ptr : null,
                cast(int)cornerVerts.length,
                cornerVerts.length    ? cornerVerts.ptr    : null,
                cornerWeights.length  ? cornerWeights.ptr  : null);
            if (osdLocal is null) return false;
            ++topologiesCreated;
            res.cacheHit  = false;
            res.topoOwned = true;
            res.limitVertCount = osdc_topology_limit_vert_count(osdLocal);
        }
        res.topo = osdLocal;

        immutable int limitVerts   = res.limitVertCount;
        immutable int limitFaces   = osdc_topology_limit_face_count(osdLocal);
        immutable int limitIndices = osdc_topology_limit_index_count(osdLocal);
        immutable int limitEdges   = osdc_topology_limit_edge_count(osdLocal);
        res.limitFaces = limitFaces;
        res.limitEdges = limitEdges;

        // ---- Read OSD limit topology + origin arrays -----------------
        // P0: scratch buffers live on OsdAccel; `.length = N` reuses
        // the underlying GC block when N <= historical max — eliminates
        // the per-rebuild `new int[]` allocations that dominated the
        // GC spinlock at 24K cage polys. Task 1500: the three that the
        // emitted Mesh either aliases or is read beside live in a PERMANENT
        // front/back pool, and this writes the BACK slot.
        auto back = &limitPool[limitBack];
        back.faceCounts  .length = limitFaces;
        back.faceIndicesI.length = limitIndices;
        back.edgeVerts   .length = 2 * limitEdges;
        osdc_topology_limit_topology(osdLocal,
            back.faceCounts   .ptr,
            back.faceIndicesI .ptr);
        osdc_topology_limit_edges   (osdLocal, back.edgeVerts.ptr);

        scratchFaceOrigins  .length = limitFaces;
        scratchVertOrigins  .length = limitVerts;
        scratchEdgeOrigins  .length = limitEdges;
        osdc_topology_face_origins(osdLocal, scratchFaceOrigins.ptr);
        osdc_topology_vert_origins(osdLocal, scratchVertOrigins.ptr);
        osdc_topology_edge_origins(osdLocal, scratchEdgeOrigins.ptr);

        Mesh          outMesh;
        SubpatchTrace outTrace;

        // ---- Build preview Mesh.vertices via direct stencil eval -----
        // Preview Mesh.vertices is allocated fresh because it's
        // consumed by consumers outside OsdAccel (CPU readback into
        // preview.vertices via readLimitIntoPreview); aliasing into a
        // scratch buffer would surprise them.
        //
        // From the SNAPSHOT's positions, not the live cage's — and the
        // receiver re-runs this same evaluate against the LIVE cage before
        // publishing (see `SubpatchPreview`), so a version-silent drag during
        // the build cannot leave a stale surface. M-GEN-POS.
        outMesh.vertices = new Vec3[](limitVerts);
        osdc_evaluate(osdLocal, snap.xyz.ptr,
                      cast(float*)outMesh.vertices.ptr);

        // ---- Build preview Mesh.edges --------------------------------
        outMesh.edges.length = limitEdges;
        foreach (i; 0 .. limitEdges) {
            outMesh.edges[i] = [
                cast(uint)back.edgeVerts[2*i + 0],
                cast(uint)back.edgeVerts[2*i + 1],
            ];
        }

        // ---- Build preview Mesh.faces --------------------------------
        // P0: outMesh.faces[fi] slice-aliases into faceIndicesI.
        // Same bit layout (int vs uint, OSD always emits non-negative
        // vertex indices), zero per-face allocation. Readers of
        // outMesh.faces[fi] must not mutate via `[k] = ...` (would
        // overwrite scratch) — `~= x` is safe (it reallocates behind
        // the slice).
        outMesh.faces.length = limitFaces;
        auto scratchFacesAsUint = cast(uint[]) back.faceIndicesI;
        int cursor = 0;
        foreach (fi; 0 .. limitFaces) {
            int cnt = back.faceCounts[fi];
            outMesh.faces[fi] = scratchFacesAsUint[cursor .. cursor + cnt];
            cursor += cnt;
        }

        outMesh.mutationVersion = 1;
        outMesh.topologyVersion = 1;
        // P4: skip buildLoops entirely on the preview mesh. All
        // consumers (gpu.upload, drawEdges, gpu_select, lasso,
        // pv.faceNormal, pv.visibleVertices) read only
        // mesh.vertices / mesh.edges / mesh.faces — none touch
        // loops / faceLoop / vertLoop / loopEdge / edgeIndexMap.
        // At 393K preview faces buildLoops was ~13% of CPU even
        // after the P2 CSR rewrite (fillOneFace + fillLoopEdge +
        // fillTwin combined). Wipe stale fields from any previous
        // rebuild so a stray accidental reader gets empty arrays
        // instead of dangling data from an older preview.
        outMesh.loops       .length = 0;
        outMesh.faceLoop    .length = 0;
        outMesh.vertLoop    .length = 0;
        outMesh.loopEdge    .length = 0;
        outMesh.edgeIndexMap = null;
        // This mesh's edges[] were written directly above (back.edgeVerts),
        // bypassing addEdge/rebuildEdges, so structVersion never bumped —
        // outMesh could otherwise carry a stale (loopsStamp == structVersion)
        // coincidence from a prior reuse of this same buffer and read as
        // falsely valid. Mark both DeliberatelyEmpty explicitly instead.
        outMesh.markDerivedEmpty();

        // ---- SubpatchTrace ------------------------------------------
        // OSD's `*_origins[i]` index INTO OSD's own cage enumeration,
        // not the caller's. For verts + faces the enumerations match
        // (we hand OSD vertex indices and face indices directly), but
        // OSD derives its edge list from the face-vertex topology and
        // assigns its own edge indices — those don't line up with
        // vibe3d's `cage.edges` (which is `addFace`-ordered). To make
        // edgeOrigin usable by the rest of vibe3d (drawEdges,
        // edgeOriginGpu lookup, the polygon-edge highlight cache) we
        // translate it via OSD's own input-edge vertex-pair table
        // plus a (min,max) vertex-pair → vibe3d-cage-edge map.
        outTrace.vertOrigin.length = limitVerts;
        outTrace.edgeOrigin.length = limitEdges;
        outTrace.faceOrigin.length = limitFaces;
        foreach (i; 0 .. limitVerts) {
            immutable int o = scratchVertOrigins[i];
            outTrace.vertOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        }
        foreach (i; 0 .. limitFaces)
            outTrace.faceOrigin[i] = cast(uint)scratchFaceOrigins[i];

        // Material Groups (MG3): propagate per-face material indices
        // through the subdivision so preview faces look up the same
        // surface as their source cage face. Without this, every
        // subpatch preview face would read mat slot 0 and the whole
        // model would render as a single default-grey blob (observed
        // on a fully subpatch-tagged import).
        outMesh.surfaces = snap.surfaces.dup;
        outMesh.faceMaterial.length = limitFaces;
        foreach (i; 0 .. limitFaces) {
            immutable uint cf = outTrace.faceOrigin[i];
            outMesh.faceMaterial[i] = (cf < snap.faceMaterial.length)
                ? snap.faceMaterial[cf] : 0u;
        }

        // Build OSD cage edge index → vibe3d cage edge index map.
        // Same key scheme as Mesh.edgeKey (min,max) → uint; the sorted
        // (key,value) array was built at the top of this function.
        //   build: O(n log n) sort over the snapshot's cage edges (≈50K
        //          entries on a 24K-poly cage), one contiguous allocation.
        //   lookup: 16-comparison binary search vs the old AA's hash +
        //          pointer-chase + open-addressing probe.
        immutable int osdCageEdges = osdc_topology_input_edge_count(osdLocal);
        scratchOsdCageEdgeVerts.length = 2 * osdCageEdges;
        if (osdCageEdges > 0)
            osdc_topology_input_edges(osdLocal, scratchOsdCageEdgeVerts.ptr);

        scratchOsdToVibe3dCageEdge.length = osdCageEdges;
        scratchOsdToVibe3dCageEdge[0 .. osdCageEdges] = uint.max;
        foreach (oi; 0 .. osdCageEdges) {
            int a = scratchOsdCageEdgeVerts[2*oi + 0];
            int b = scratchOsdCageEdgeVerts[2*oi + 1];
            if (a < 0 || b < 0) continue;
            scratchOsdToVibe3dCageEdge[oi] =
                findCageEdgeByKey(edgeKey(cast(uint)a, cast(uint)b));
        }
        foreach (i; 0 .. limitEdges) {
            immutable int o = scratchEdgeOrigins[i];
            if (o < 0 || o >= osdCageEdges) {
                outTrace.edgeOrigin[i] = uint.max;
            } else {
                outTrace.edgeOrigin[i] = scratchOsdToVibe3dCageEdge[o];
            }
        }
        // Per-preview-face subpatch flag inherits from its cage parent.
        outTrace.subpatch         .length = limitFaces;
        outMesh.resizeSubpatch();
        foreach (i; 0 .. limitFaces) {
            immutable int o = scratchFaceOrigins[i];
            bool parentMarked = (o >= 0) && (o < nf) && snap.faceSubpatch[o];
            outTrace.subpatch [i] = parentMarked;
            outMesh.setFaceSubpatch(i, parentMarked);
            // Hide (task 0613 S3): the preview face inherits its cage parent's
            // hidden state. THIS is the stamp the viewport actually reads —
            // SubpatchPreview.rebuild drives the build, and GpuMesh.upload
            // then reads the Hide plane off whichever mesh it was handed
            // (cage or preview) with no new parameter. Both branches are
            // written (a face that stops being hidden must stop carrying the
            // bit) — `outMesh` was `Mesh.init` at the top of this function,
            // but `resizeSubpatch` / `setFaceHiddenBit` are the same writers
            // as before and the reasoning is unchanged.
            outMesh.setFaceHiddenBit(i, (o >= 0) && (o < nf) && snap.faceHidden[o]);
        }

        outMesh.resizeVertexSelection();
        outMesh.resizeEdgeSelection();
        outMesh.resizeFaceSelection();
        // Derived vertex + edge planes, on the preview's OWN topology — see
        // the twin call at the end of catmullClarkOsd for why that is the
        // right space. AFTER the resizes: this writes vertexMarks/edgeMarks
        // in place.
        outMesh.refreshHiddenDerived();

        res.mesh  = outMesh;
        res.trace = outTrace;
        res.ok    = true;
        return true;
    }

    /// Binary search into `scratchVibe3dEdgeKv` (built at the top of
    /// `buildFromSnapshot`). `uint.max` when the key is absent — the same
    /// answer `key in cage.edgeIndexMap` gave by being null.
    private uint findCageEdgeByKey(ulong key) const {
        size_t lo = 0, hi = scratchVibe3dEdgeKv.length;
        while (lo < hi) {
            size_t mid = (lo + hi) >> 1;
            if (scratchVibe3dEdgeKv[mid].key < key) lo = mid + 1;
            else                                    hi = mid;
        }
        if (lo < scratchVibe3dEdgeKv.length
            && scratchVibe3dEdgeKv[lo].key == key)
            return scratchVibe3dEdgeKv[lo].value;
        return uint.max;
    }


    /// Main/GL thread. Adopt `res`'s topology as this accel's live one,
    /// creating the GL evaluator + its two VBOs when the build MISSED the
    /// cache, and install the topology into the LRU. Ownership of a
    /// miss-built topology transfers to the cache here — see
    /// `retireResult` for the other exit.
    ///
    /// `glThreadGuard` is the first statement, and it is the whole reason
    /// this is a separate function: `gl_thread_guard.d`'s header used to list
    /// `OsdAccel.buildPreview` among the funnels it deliberately did NOT
    /// cover, on the grounds that no crash had ever come from there. Task
    /// 1500 makes a non-GL thread run the build, so the guard moves from
    /// "not worth it" to "the instrument that names the drift". M-GL.
    void installGl(ref PreviewBuildResult res, ref Mesh pmesh,
                    ref const SubpatchTrace ptrace)
    {
        import gl_thread_guard : glThreadGuard;
        glThreadGuard("OsdAccel.installGl");
        import bindbc.opengl;

        immutable int nv         = res.numCageVerts;
        immutable int limitVerts = res.limitVertCount;
        immutable int limitFaces = res.limitFaces;

        if (res.cacheHit) {
            // Borrowed from a cache slot: pick its GL companions back up.
            auto look = lookupCachedTopology(res.topoKey);
            assert(look.hit && look.osd is res.topo,
                   "cache slot moved under an in-flight build");
            osd            = look.osd;
            glEval         = look.glEval;
            cageGlVbo      = look.cageGlVbo;
            limitGlVbo     = look.limitGlVbo;
            limitVertCount = look.limitVerts;
            touchCacheSlot(res.topoKey);
        } else {
            osd            = res.topo;
            limitVertCount = res.limitVertCount;
            glEval         = g_osdGpuEnabled ? osdc_gl_create(osd) : null;
            cageGlVbo      = 0;
            limitGlVbo     = 0;
            if (glEval !is null) {
                glGenBuffers(1, &cageGlVbo);
                glGenBuffers(1, &limitGlVbo);
                glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
                glBufferData(GL_ARRAY_BUFFER,
                    cast(GLsizeiptr)(3 * nv * float.sizeof),
                    null, GL_DYNAMIC_DRAW);
                glBindBuffer(GL_ARRAY_BUFFER, limitGlVbo);
                glBufferData(GL_ARRAY_BUFFER,
                    cast(GLsizeiptr)(3 * limitVertCount * float.sizeof),
                    null, GL_DYNAMIC_DRAW);
                glBindBuffer(GL_ARRAY_BUFFER, 0);
            }
            installInCache(res.topoKey, nv, osd, glEval,
                           cageGlVbo, limitGlVbo, limitVertCount);
            // The cache owns it now; nothing downstream may free it.
            res.topoOwned = false;
        }

        if (glEval !is null) {
            limitScratchXyz.length = 3 * limitVerts;
        }

        // ---- Phase 3b: fan-out infrastructure -----------------------
        // Built only when the GL eval is alive (Phase 3a's glEval).
        // Three TBO storage buffers + one TBO view over limitGlVbo +
        // the compiled fan-out program. Iteration order MUST match
        // GpuMesh.upload's face-corner loop (face[0], face[i],
        // face[i+1] for i in 1..N-1) — that's what fanOut writes into.
        if (glEval !is null) {
            // P0: pre-compute total face-corner count so the corner
            // arrays are setLength()'d once instead of `~=`'d 3·N times
            // per face (393K faces × 3 corners × 2 arrays ≈ 2.4M
            // appends each rebuild).
            size_t cornerCount = 0;
            foreach (fi; 0 .. limitFaces) {
                immutable size_t fl = pmesh.faces[fi].length;
                if (fl >= 3) cornerCount += (fl - 2) * 3;
            }

            scratchCornerToLimit  .length =     cornerCount;
            scratchCornerToFaceId .length =     cornerCount;
            scratchFaceFirstVerts .length = 3 * limitFaces;

            size_t cw = 0;
            foreach (fi; 0 .. limitFaces) {
                const(uint)[] face = pmesh.faces[fi];
                scratchFaceFirstVerts[3*fi + 0] =
                    face.length >= 1 ? cast(int)face[0] : 0;
                scratchFaceFirstVerts[3*fi + 1] =
                    face.length >= 2 ? cast(int)face[1] : 0;
                scratchFaceFirstVerts[3*fi + 2] =
                    face.length >= 3 ? cast(int)face[2] : 0;
                if (face.length < 3) continue;
                for (uint i = 1; i + 1 < face.length; i++) {
                    scratchCornerToLimit [cw + 0] = cast(int)face[0];
                    scratchCornerToLimit [cw + 1] = cast(int)face[i];
                    scratchCornerToLimit [cw + 2] = cast(int)face[i + 1];
                    scratchCornerToFaceId[cw + 0] = cast(uint)fi;
                    scratchCornerToFaceId[cw + 1] = cast(uint)fi;
                    scratchCornerToFaceId[cw + 2] = cast(uint)fi;
                    cw += 3;
                }
            }
            faceVertCount = cast(int)cw;

            if (faceVertCount > 0) {
                // Allocate storage buffers + bind TBO views (one
                // texture-buffer texture per uniform sampler in the
                // fan-out shader).
                void uploadTbo(R, F)(ref GLuint vbo, ref GLuint tex,
                                      R[] data, F fmt)
                {
                    glGenBuffers(1, &vbo);
                    glBindBuffer(GL_TEXTURE_BUFFER, vbo);
                    glBufferData(GL_TEXTURE_BUFFER,
                        cast(GLsizeiptr)(data.length * R.sizeof),
                        data.ptr, GL_STATIC_DRAW);
                    glGenTextures(1, &tex);
                    glBindTexture(GL_TEXTURE_BUFFER, tex);
                    glTexBuffer(GL_TEXTURE_BUFFER, fmt, vbo);
                }

                uploadTbo(cornerToLimitVbo,   cornerToLimitTex,
                          scratchCornerToLimit[0 .. faceVertCount],
                                                           GL_R32I);
                uploadTbo(cornerToFaceIdVbo,  cornerToFaceIdTex,
                          scratchCornerToFaceId[0 .. faceVertCount],
                                                           GL_R32UI);
                uploadTbo(faceFirstVertsVbo,  faceFirstVertsTex,
                          scratchFaceFirstVerts[0 .. 3 * limitFaces],
                                                           GL_R32I);

                // limitGlVbo already exists (Phase 3a allocation).
                // Wrap it in a TBO view so the shader can texelFetch.
                glGenTextures(1, &limitTex);
                glBindTexture(GL_TEXTURE_BUFFER, limitTex);
                // R32F (not RGB32F) so the limit position buffer
                // works on any GL 3.3 driver — RGB32F texture-buffer
                // format requires ARB_texture_buffer_object_rgb32 and
                // wasn't reliably present on older Mesa stacks.
                // Shader does three texelFetch calls per position
                // (index*3 + 0/1/2) instead of one rgb fetch.
                glTexBuffer(GL_TEXTURE_BUFFER, GL_R32F, limitGlVbo);

                glBindBuffer (GL_TEXTURE_BUFFER, 0);
                glBindTexture(GL_TEXTURE_BUFFER, 0);

                // Empty VAO for the fan-out TF dispatch — see tfVao
                // field comment for why the caller's VAO can't be
                // reused.
                glGenVertexArrays(1, &tfVao);

                fanOutProgram = compileFanOutProgram();
                if (fanOutProgram != 0) {
                    locCornerToLimit   = glGetUniformLocation(
                        fanOutProgram, "u_cornerToLimit");
                    locCornerToFaceId  = glGetUniformLocation(
                        fanOutProgram, "u_cornerToFaceId");
                    locFaceFirstVerts  = glGetUniformLocation(
                        fanOutProgram, "u_faceFirstVerts");
                    locLimitPositions  = glGetUniformLocation(
                        fanOutProgram, "u_limitPositions");
                }
            }

            // ---- Phase 3c — edge + vert VBO fan-out lookups ----------
            // Two more TBOs and a one-output shader. Iteration order
            // MUST match GpuMesh.upload's edge / vert walks (kept-
            // entry sequence, filtered by trace.{edge,vert}Origin).
            {
                // P0: pre-count kept edges + kept verts so the lookup
                // arrays are setLength()'d once instead of `~=`'d
                // through 800K+ edges / 400K+ verts per rebuild.
                size_t keptEdges = 0;
                foreach (ei; 0 .. pmesh.edges.length) {
                    immutable uint eo = ei < ptrace.edgeOrigin.length
                                        ? ptrace.edgeOrigin[ei] : uint.max;
                    if (eo != uint.max) ++keptEdges;
                }
                size_t keptVerts = 0;
                foreach (pi; 0 .. limitVerts) {
                    immutable uint vo = pi < ptrace.vertOrigin.length
                                        ? ptrace.vertOrigin[pi] : uint.max;
                    if (vo != uint.max) ++keptVerts;
                }
                scratchEdgeSegToLimit.length = 2 * keptEdges;
                scratchVertToLimit   .length =     keptVerts;

                size_t ew = 0;
                foreach (ei, e; pmesh.edges) {
                    immutable uint eo = ei < ptrace.edgeOrigin.length
                                        ? ptrace.edgeOrigin[ei] : uint.max;
                    if (eo == uint.max) continue;
                    scratchEdgeSegToLimit[ew + 0] = cast(int)e[0];
                    scratchEdgeSegToLimit[ew + 1] = cast(int)e[1];
                    ew += 2;
                }
                size_t vw = 0;
                foreach (pi; 0 .. limitVerts) {
                    immutable uint vo = pi < ptrace.vertOrigin.length
                                        ? ptrace.vertOrigin[pi] : uint.max;
                    if (vo == uint.max) continue;
                    scratchVertToLimit[vw++] = cast(int)pi;
                }
                edgeSegCount  = cast(int)ew;
                keptVertCount = cast(int)vw;

                void uploadIntTbo(ref GLuint vbo, ref GLuint tex,
                                   int[] data)
                {
                    if (data.length == 0) return;
                    glGenBuffers(1, &vbo);
                    glBindBuffer(GL_TEXTURE_BUFFER, vbo);
                    glBufferData(GL_TEXTURE_BUFFER,
                        cast(GLsizeiptr)(data.length * int.sizeof),
                        data.ptr, GL_STATIC_DRAW);
                    glGenTextures(1, &tex);
                    glBindTexture(GL_TEXTURE_BUFFER, tex);
                    glTexBuffer(GL_TEXTURE_BUFFER, GL_R32I, vbo);
                }
                uploadIntTbo(edgeSegToLimitVbo, edgeSegToLimitTex,
                              scratchEdgeSegToLimit[0 .. edgeSegCount]);
                uploadIntTbo(vertToLimitVbo,    vertToLimitTex,
                              scratchVertToLimit[0 .. keptVertCount]);
                glBindBuffer (GL_TEXTURE_BUFFER, 0);
                glBindTexture(GL_TEXTURE_BUFFER, 0);

                posFanOutProgram = compilePosFanOutProgram();
                if (posFanOutProgram != 0) {
                    locPosIndexLookup    = glGetUniformLocation(
                        posFanOutProgram, "u_indexLookup");
                    locPosLimitPositions = glGetUniformLocation(
                        posFanOutProgram, "u_limitPositions");
                }
            }
        }

        valid = true;
    }


    /// Give back whatever `res` owns. Called on EVERY exit that does not
    /// install: a failed build, and — the one that leaks if it is forgotten —
    /// a result thrown away because the cage moved on while it was being
    /// built. Without this, "last dispatch wins" leaks one
    /// `osdc_topology_t` (the single most expensive object in the system)
    /// per discarded Tab. M-LEAK.
    void retireResult(ref PreviewBuildResult res) {
        if (res.topoOwned && res.topo !is null) {
            osdc_topology_destroy(res.topo);
            ++topologiesRetired;
        }
        res.topo      = null;
        res.topoOwned = false;
        res.mesh      = Mesh.init;
        res.trace     = SubpatchTrace.init;
    }

    /// Make the slot the build wrote the FRONT one. Called by the receiver
    /// after it has taken `res.mesh` (whose `faces[fi]` slice-alias into that
    /// slot's `faceIndicesI`), and never by the builder.
    void swapLimitPool() { limitBack = 1 - limitBack; }

    /// Publish the build's counters into `g_perf` — MAIN THREAD ONLY.
    ///
    /// These four keys are what the perf lane's F-I5/F-I8 read
    /// (`subpatchPreview`, `subpatchTopoHit`, `subpatchTopoMiss`,
    /// `subpatchLevelChosen`), and `g_perf` is `__gshared` with no lock, so
    /// letting the worker write them straight would make the lane's own
    /// invariants racy. The worker measures; the receiver publishes.
    ///
    /// `extraNs` is the install's own wall time, so `subpatchPreview`'s timer
    /// still sums the WHOLE build the way it did when it was one function.
    void publishBuildCounters(ref const PreviewBuildResult res, long extraNs) {
        g_perf.recordNs(Cat.subpatchPreview, res.workerNs + extraNs);
        g_perf.count(res.cacheHit ? Cat.subpatchTopoHit : Cat.subpatchTopoMiss, 1);
        g_perf.count(Cat.subpatchLevelChosen, res.chosenLevel);
        if (res.chosenLevel != res.requestedLevel) {
            import log        : logWarn;
            import std.format : format;
            try {
                logWarn("subpatch", format(
                    "capping subpatch depth %d -> %d "
                    ~ "(cage %d corners, projected %d limit faces "
                    ~ "exceeds memory ceiling %d)",
                    res.requestedLevel, res.chosenLevel,
                    res.cageCornerCount,
                    projectedLimitFaces(res.cageCornerCount, res.requestedLevel),
                    res.memLimitFaces));
            } catch (Exception) {}
        }
    }

    /// Load the LIVE cage's positions into `cageScratchXyz` — the buffer
    /// `refresh()` / `refreshIntoFaceVbo()` assert the size of on every drag
    /// frame. MAIN THREAD: the worker uses the snapshot's own copy and never
    /// touches this one.
    void syncCageXyz(ref const Mesh cage) {
        cageScratchXyz.length = 3 * cage.vertices.length;
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }
    }

    /// Re-run the stencil evaluate against the LIVE cage, straight into
    /// `preview.vertices`. The receiver's answer to a version-silent drag
    /// that happened WHILE the build was running: positions are never taken
    /// from the snapshot at publish time, only topology is. M-GEN-POS.
    ///
    /// Cheap by construction — the stencil TABLE is the expensive object and
    /// it already exists; this is the one pass over it that the
    /// position-only fast path already runs every drag frame.
    void evaluateFromCage(ref const Mesh cage, osdc_topology_t* topo,
                           ref Mesh preview) {
        if (topo is null || preview.vertices.length == 0) return;
        syncCageXyz(cage);
        osdc_evaluate(topo, cageScratchXyz.ptr,
                      cast(float*)preview.vertices.ptr);
    }

    /// SYNCHRONOUS build — snapshot, build, clear, install, all on this
    /// thread. Unchanged signature and unchanged observable behaviour; it is
    /// what `dub test`'s unittests and the IPR preview
    /// (source/render/render_mvp.d) call, and what `SubpatchPreview` falls
    /// back to when its async path is not enabled.
    bool buildPreview(ref const Mesh cage, int level,
                       out Mesh outMesh, out SubpatchTrace outTrace,
                       long memLimitFaces = MEM_LIMIT_FACES)
    {
        import core.time : MonoTime;
        CageSnapshot snap;
        takeCageSnapshot(cage, level, snap, memLimitFaces);

        PreviewBuildResult res;
        immutable bool built = buildFromSnapshot(snap, res);

        immutable MonoTime tInstall = MonoTime.currTime;
        clear();
        if (!built) {
            retireResult(res);
            publishBuildCounters(res, (MonoTime.currTime - tInstall).total!"nsecs");
            return false;
        }
        installGl(res, res.mesh, res.trace);
        // Positions already came from this same cage a few statements ago, so
        // no re-evaluate here — but `cageScratchXyz` still has to hold them
        // for the per-drag-frame `refresh()` that follows.
        syncCageXyz(cage);
        swapLimitPool();
        publishBuildCounters(res, (MonoTime.currTime - tInstall).total!"nsecs");
        outMesh  = res.mesh;
        outTrace = res.trace;
        return true;
    }


    /// Phase 3b — replace gpu.faceVbo's positions+normals via GPU eval
    /// + transform-feedback fan-out. Single shader dispatch per drag
    /// frame; no CPU readback. `preview.vertices` is NOT updated.
    ///
    /// Caller passes vibe3d's gpu.faceVbo. The fan-out writes exactly
    /// `faceVertCount` interleaved (xyz pos + xyz normal) vertices
    /// starting at offset 0 — same layout the regular gpu.upload
    /// produces, so subsequent draws don't need anything else.
    ///
    /// `expectedFaceVertCount` MUST match the caller's gpu.faceVertCount
    /// — i.e. the same preview-topology pass that built this OsdAccel
    /// also produced the caller's face VBO. If they diverge we bail to
    /// the false return so the caller falls back to CPU + gpu.upload.
    ///
    /// Returns true iff the fan-out actually ran. false → caller MUST
    /// fall back (e.g. call refresh + the standard gpu.upload path).
    bool refreshIntoFaceVbo(ref const Mesh cage,
                             GLuint targetFaceVbo,
                             int expectedFaceVertCount)
    {
        if (!canFanOut) return false;
        if (targetFaceVbo == 0) return false;
        if (expectedFaceVertCount != faceVertCount) return false;
        if (cage.vertices.length * 3 != cageScratchXyz.length) return false;

        // Pack + upload current cage positions.
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }
        glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(cageScratchXyz.length * float.sizeof),
            cageScratchXyz.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, 0);

        if (!osdc_gl_evaluate(glEval, cageGlVbo, limitGlVbo))
            return false;

        // Save GL state we touch. The TEXTURE_BUFFER target itself is
        // not queried — vibe3d's renderer doesn't bind it, so leakage
        // is benign and the query symbol isn't exposed in bindbc-
        // opengl's GL_33 surface anyway.
        GLint prevProgram, prevVao, prevArrayBuf;
        GLint prevActiveTex;
        GLint prevTex0, prevTex1, prevTex2, prevTex3;
        glGetIntegerv(GL_CURRENT_PROGRAM,             &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING,        &prevVao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,        &prevArrayBuf);
        glGetIntegerv(GL_ACTIVE_TEXTURE,              &prevActiveTex);

        glUseProgram(fanOutProgram);

        // Bind the four TBO views to texture units 0..3 and set the
        // sampler uniforms.
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex0);
        glBindTexture(GL_TEXTURE_BUFFER, cornerToLimitTex);
        glUniform1i(locCornerToLimit, 0);

        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex1);
        glBindTexture(GL_TEXTURE_BUFFER, cornerToFaceIdTex);
        glUniform1i(locCornerToFaceId, 1);

        glActiveTexture(GL_TEXTURE2);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex2);
        glBindTexture(GL_TEXTURE_BUFFER, faceFirstVertsTex);
        glUniform1i(locFaceFirstVerts, 2);

        glActiveTexture(GL_TEXTURE3);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex3);
        glBindTexture(GL_TEXTURE_BUFFER, limitTex);
        glUniform1i(locLimitPositions, 3);

        // No vertex attributes are read — TF dispatch is driven by
        // gl_VertexID. Bind a dedicated empty VAO: the caller's VAO
        // usually has attribs enabled pointing at gpu.faceVbo (for
        // the normal raster draw of the surface), but gpu.faceVbo is
        // also our TF write target on this dispatch — and GL raises
        // GL_INVALID_OPERATION on glDrawArrays under transform
        // feedback when any enabled attribute references the TF
        // output buffer (feedback loop). tfVao has no enabled
        // attribs, so the loop check passes.
        glBindVertexArray(tfVao);

        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetFaceVbo);
        glEnable(GL_RASTERIZER_DISCARD);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, faceVertCount);
        g_fc.draw(DrawPass.subpatch, faceVertCount);
        glEndTransformFeedback();
        glDisable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);

        // Restore GL state.
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex3);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex2);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex0);
        glActiveTexture(cast(GLuint)prevActiveTex);
        glBindBuffer(GL_ARRAY_BUFFER,   cast(GLuint)prevArrayBuf);
        glUseProgram(cast(GLuint)prevProgram);
        glBindVertexArray(cast(GLuint)prevVao);
        return true;
    }

    /// Phase 3c — shared single-vec3 TF dispatch. Used by
    /// refreshEdgeVbo and refreshVertVbo. Reads `indexLookupTex`'s
    /// per-output entry → fetches from limitTex → writes one vec3
    /// into `targetVbo` at offset 0. Assumes refreshIntoFaceVbo
    /// already ran in this frame (limitGlVbo populated).
    private bool runPosFanOut(GLuint indexLookupTex,
                               GLuint targetVbo,
                               int dispatchCount)
    {
        if (posFanOutProgram == 0 || limitTex == 0
            || indexLookupTex == 0 || targetVbo == 0
            || dispatchCount <= 0)
            return false;

        GLint prevProgram, prevVao, prevArrayBuf;
        GLint prevActiveTex, prevTex0, prevTex1;
        glGetIntegerv(GL_CURRENT_PROGRAM,       &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING,  &prevVao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,  &prevArrayBuf);
        glGetIntegerv(GL_ACTIVE_TEXTURE,        &prevActiveTex);

        glUseProgram(posFanOutProgram);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex0);
        glBindTexture(GL_TEXTURE_BUFFER, indexLookupTex);
        glUniform1i(locPosIndexLookup, 0);
        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex1);
        glBindTexture(GL_TEXTURE_BUFFER, limitTex);
        glUniform1i(locPosLimitPositions, 1);

        // Empty VAO — same feedback-loop concern as refreshIntoFaceVbo;
        // gpu.edgeVao / gpu.vertVao both have attribs pointing at the
        // VBOs we'd be writing.
        glBindVertexArray(tfVao);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetVbo);
        glEnable(GL_RASTERIZER_DISCARD);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, dispatchCount);
        g_fc.draw(DrawPass.subpatch, dispatchCount);
        glEndTransformFeedback();
        glDisable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex0);
        glActiveTexture(cast(GLuint)prevActiveTex);
        glBindBuffer(GL_ARRAY_BUFFER, cast(GLuint)prevArrayBuf);
        glUseProgram(cast(GLuint)prevProgram);
        glBindVertexArray(cast(GLuint)prevVao);
        return true;
    }

    /// Phase 3c — fill caller's edge VBO directly from limitGlVbo.
    /// Requires refreshIntoFaceVbo (or any path that ran the GPU
    /// stencil eval) to have populated limitGlVbo this frame.
    /// `expectedSegmentCount` must match the kept-edge segment count
    /// (= 2 × num-kept-edges) recorded at buildPreview.
    bool refreshEdgeVbo(GLuint targetEdgeVbo, int expectedSegmentCount) {
        if (!canFanOutEdges) return false;
        if (expectedSegmentCount != edgeSegCount) return false;
        return runPosFanOut(edgeSegToLimitTex,
                             targetEdgeVbo, edgeSegCount);
    }

    /// Phase 3c — fill caller's vert VBO directly from limitGlVbo.
    /// `expectedVertCount` must match kept-vert count from buildPreview.
    bool refreshVertVbo(GLuint targetVertVbo, int expectedVertCount) {
        if (!canFanOutVerts) return false;
        if (expectedVertCount != keptVertCount) return false;
        return runPosFanOut(vertToLimitTex,
                             targetVertVbo, keptVertCount);
    }

    /// Hot per-frame call: re-eval OSD's stencils against the current
    /// cage positions and write the limit positions into
    /// `preview.vertices`. Routes through the GPU evaluator when one
    /// was built at `buildPreview` time; falls back to CPU otherwise.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(cage.vertices.length * 3 == cageScratchXyz.length,
               "cage vert count changed without buildPreview");

        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }

        if (glEval !is null && cageGlVbo != 0 && limitGlVbo != 0) {
            refreshViaGpu(preview);
        } else {
            osdc_evaluate(osd, cageScratchXyz.ptr,
                          cast(float*)preview.vertices.ptr);
        }
    }

    /// GPU eval path. Pumps cage positions into the cage VBO, runs
    /// OSD's transform-feedback stencil kernel into the limit VBO,
    /// then reads the limit positions back into preview.vertices so
    /// existing consumers (gpu.upload, picking, drawing) see the
    /// new positions unchanged.
    private void refreshViaGpu(ref Mesh preview) {
        import bindbc.opengl;
        glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(cageScratchXyz.length * float.sizeof),
            cageScratchXyz.ptr);

        int ok = osdc_gl_evaluate(glEval, cageGlVbo, limitGlVbo);
        if (!ok) {
            // GPU eval failed at runtime (shader compile lost between
            // create and now?). One-time fall back to CPU eval —
            // dropping the GL state so subsequent calls take the CPU
            // path until buildPreview re-runs.
            osdc_gl_destroy(glEval);
            glEval = null;
            osdc_evaluate(osd, cageScratchXyz.ptr,
                          cast(float*)preview.vertices.ptr);
            return;
        }

        readLimitIntoPreview(preview);
    }

    /// Phase 3b — readback limitGlVbo into preview.vertices WITHOUT
    /// re-running the GPU eval. Used after refreshIntoFaceVbo (which
    /// already populated limitGlVbo via osdc_gl_evaluate) to keep
    /// preview.vertices fresh for CPU-side consumers (edge / vert
    /// VBO refresh inside refreshNonFacePositions, lasso-vis test,
    /// debug overlays) — avoids the redundant second eval that
    /// `refresh(cage, preview)` would do.
    void readLimitIntoPreview(ref Mesh preview) {
        import bindbc.opengl;
        if (limitGlVbo == 0) return;
        if (preview.vertices.length != limitVertCount) return;
        glBindBuffer(GL_ARRAY_BUFFER, limitGlVbo);
        glGetBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(preview.vertices.length * Vec3.sizeof),
            preview.vertices.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }
}
