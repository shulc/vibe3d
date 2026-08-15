// The snap ELECTION corpus (task 0721, audit №4 item P3).
//
// P3's own gate is "bitwise identity of the election", and this module is what
// makes that sentence checkable. `snapCursor` elects ONE candidate out of many
// and the thing a refactor can quietly change is WHICH one — a result that
// "looks the same" (same type, same neighbourhood) is not the same election.
// So the corpus dumps the winner's RAW BITS, not its printed value: every float
// goes out as the `uint` of its IEEE-754 pattern, so a last-bit difference in a
// re-projection is a diff and not a rounding coincidence.
//
// WHAT IS DUMPED is the whole of `SnapResult` — `worldPos`, `highlightPos`,
// `snapped`, `highlighted`, `targetType`, `targetIndex`, `targetSource`,
// `constraintType`. All eight, because the election has three separately
// reachable outcomes (discrete snap / constraint snap with a discrete
// highlight / highlight only) and a subset of the fields cannot tell them
// apart: the constraint tier writes `worldPos` while leaving `targetType` to
// the discrete highlight, so a dump without `constraintType` would read a
// constraint win and a plain miss identically.
//
// HOW IT IS USED. The dump is written to the path in `VIBE3D_SNAP_CORPUS_OUT`
// when that variable is set, and only then — the ordinary gate run computes
// the same bytes, hashes them, and asserts the corpus is NON-VACUOUS, without
// touching the filesystem. Capture the file before a refactor, capture it
// after, `cmp` the two. That comparison is the deliverable; this file is the
// instrument.
//
// WHY THE VACUITY COUNTERS ARE ASSERTED AND THE DIGEST IS NOT. A frozen digest
// would be a cross-compiler hazard, not a regression test: the election's
// arithmetic is float, and dmd / ldc / a different `-O` can legitimately differ
// in the last bit of a projection. What CAN be asserted on every machine is
// that the corpus actually reaches the branches it claims to cover — a corpus
// that silently stopped electing polygons, or stopped firing the vertex veto,
// would keep passing a byte-comparison against its own equally empty self.
// That is the inert-measurement trap (task 0635) applied to a corpus: a zero
// that no mutation can make non-zero is not a measurement, so every branch this
// module claims to exercise gets its own counter and its own assertion.
module tests.unit.snap_election_corpus_test;

import std.math : PI, sqrt, round, isNaN;
import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
              orthographicMatrix, projectToWindowFull;
import mesh : Mesh, makeCube;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
import toolpipe.guide   : SnapGuide, GuideDrawState, kGuidePrioritySeed;
import snap;

// ---------------------------------------------------------------------------
// The dump format.
//
// One line per case: the case key, then the eight result fields, floats as raw
// IEEE-754 bit patterns in hex. Text rather than binary so a diff names the
// case that moved instead of a byte offset; raw bits inside it so the text
// cannot round two different elections onto one string.
// ---------------------------------------------------------------------------
private uint bits(float f) {
    union U { float f; uint u; }
    U u; u.f = f;
    return u.u;
}

private string vecBits(Vec3 v) {
    import std.format : format;
    return format("%08x,%08x,%08x", bits(v.x), bits(v.y), bits(v.z));
}

private string resultLine(string key, const ref SnapResult r) {
    import std.format : format;
    return format("%s|%s|%s|%d|%d|%u|%d|%d|%u\n",
                  key,
                  vecBits(r.worldPos), vecBits(r.highlightPos),
                  r.snapped ? 1 : 0, r.highlighted ? 1 : 0,
                  cast(uint)r.targetType, r.targetIndex, r.targetSource,
                  cast(uint)r.constraintType);
}

// ---------------------------------------------------------------------------
// The fixtures. Four meshes, chosen so the four legs of the walk are each
// reachable on at least one of them and so no single one can hide a leg:
//
//  * `pointCloud` has NO faces, so `needVis` is false and nothing can be
//    occluded — the vertex leg with the visibility gate switched off.
//  * `cube` is the closed solid: every back face is also occluded, which is
//    exactly why it cannot prove anything about FACING on its own (the
//    picking-strategy note in CLAUDE.md, and task 0576/0577's reading of it).
//  * `openQuad` is the counter-fixture: one face wound AWAY from the eye with
//    nothing in front of it, so the facing term and the occlusion term
//    disagree there and only there.
//  * `concave` is a single L-shaped face whose notch the ear-clip
//    triangulation must respect — the polygon-surface leg's own hazard
//    (`closestOnPolygonSurface`, difference D1).
//  * `crossStrips` is the ONLY fixture on which the Intersection leg can fire
//    at all, and it is here because the first version of this corpus did not
//    have it and the vacuity assertion below caught that: the leg needs two
//    edges that share NO vertex and cross in SCREEN space, and on a cube every
//    such pair either shares a corner or has an endpoint the visibility gate
//    drops. Two thin quads laid across each other at slightly different depths
//    are the smallest thing that produces the pair.
// ---------------------------------------------------------------------------
private Mesh pointCloudMesh() {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f, -0.5f,  0.0f), Vec3(-0.25f, 0.3f,  0.4f),
        Vec3( 0.15f,  0.1f, -0.3f), Vec3( 0.6f, -0.4f,  0.2f),
        Vec3( 1.1f,   0.7f,  0.9f), Vec3(-0.8f,  0.9f, -0.6f),
    ];
    return m;
}

private Mesh openQuadMesh() {
    Mesh m;
    m.vertices = [
        Vec3(-0.8f, -0.8f, 0.0f), Vec3(0.8f, -0.8f, 0.0f),
        Vec3( 0.8f,  0.8f, 0.0f), Vec3(-0.8f, 0.8f, 0.0f),
    ];
    // Wound clockwise as seen from +Z, i.e. AWAY from an eye on +Z.
    m.addFace([0u, 3u, 2u, 1u]);
    return m;
}

private Mesh concaveMesh() {
    Mesh m;
    // An L, in the z = 0 plane, wound counter-clockwise from +Z.
    m.vertices = [
        Vec3(-0.9f, -0.9f, 0.0f), Vec3( 0.9f, -0.9f, 0.0f),
        Vec3( 0.9f, -0.2f, 0.0f), Vec3(-0.1f, -0.2f, 0.0f),
        Vec3(-0.1f,  0.9f, 0.0f), Vec3(-0.9f,  0.9f, 0.0f),
    ];
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    return m;
}

private Mesh crossStripsMesh() {
    Mesh m;
    m.vertices = [
        // horizontal strip, z = 0
        Vec3(-1.2f, -0.08f, 0.0f),  Vec3( 1.2f, -0.08f, 0.0f),
        Vec3( 1.2f,  0.08f, 0.0f),  Vec3(-1.2f,  0.08f, 0.0f),
        // vertical strip, z = 0.12 (in FRONT of the other, so neither
        // strip's own corners sit behind the other one)
        Vec3(-0.08f, -1.2f, 0.12f), Vec3( 0.08f, -1.2f, 0.12f),
        Vec3( 0.08f,  1.2f, 0.12f), Vec3(-0.08f,  1.2f, 0.12f),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    return m;
}

// ---------------------------------------------------------------------------
// The guides. Two of them, and the second is the reason the first is not
// enough.
//
// `MirrorGuide` answers the candidate's own screen distance at one priority —
// the neutrality guide, the one whose agreement with the empty registry is a
// statement about the arbitration and not about a fixture.
//
// `SplitGuide` answers DIFFERENT priorities for different cascade classes,
// which is the state the priority-then-cascade nesting in `foldCascadeChampion`
// exists for and the only state in which the ordering of the priority mask,
// the vertex veto and the cascade is observable at all. Without it the corpus
// would be blind to the whole of that block.
// ---------------------------------------------------------------------------
private final class MirrorGuide : SnapGuide {
    private Viewport vp_;
    private int sx_, sy_;
    this(Viewport vp, int sx, int sy) { vp_ = vp; sx_ = sx; sy_ = sy; }
    void limits(float innerPx, float outerPx) {}
    bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                   out float distPx, ref int priority)
    {
        float px, py, ndcZ;
        if (!projectToWindowFull(candWorld, vp_, px, py, ndcZ)) return false;
        immutable float dx = px - cast(float)sx_;
        immutable float dy = py - cast(float)sy_;
        distPx = sqrt(dx * dx + dy * dy);
        // Leaves `priority` at the caller's seed deliberately: the seed IS the
        // guide's answer when it does not assign one (`kGuidePrioritySeed`).
        return true;
    }
    void setDrawState(GuideDrawState s) {}
    uint flags() const { return 0; }
}

private final class SplitGuide : SnapGuide {
    private Viewport vp_;
    private int sx_, sy_;
    private SnapType favoured_;
    this(Viewport vp, int sx, int sy, SnapType favoured) {
        vp_ = vp; sx_ = sx; sy_ = sy; favoured_ = favoured;
    }
    void limits(float innerPx, float outerPx) {}
    bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                   out float distPx, ref int priority)
    {
        float px, py, ndcZ;
        if (!projectToWindowFull(candWorld, vp_, px, py, ndcZ)) return false;
        immutable float dx = px - cast(float)sx_;
        immutable float dy = py - cast(float)sy_;
        distPx  = sqrt(dx * dx + dy * dy);
        priority = (type == favoured_) ? 7 : 2;
        return true;
    }
    void setDrawState(GuideDrawState s) {}
    uint flags() const { return 0; }
}

/// A guide that answers a FIXED priority and a scaled distance, optionally
/// rejecting a subset of candidates.
///
/// THIS CLASS EXISTS BECAUSE THE CORPUS FAILED A SENSITIVITY CHECK WITHOUT IT,
/// and that is worth writing down rather than quietly fixing. `arbitrate`'s
/// rule for several guides is that at EQUAL priority the first-registered one
/// is heard (a strict `>`), and the first version of this corpus registered at
/// most ONE guide — so weakening that `>` to `>=` left the whole 63 480-case
/// digest bit-identical. A corpus that cannot see a rule cannot freeze it.
/// Registering two of these at the same priority with different distance
/// scales makes the registration order decide the ranking, and the mutation
/// moves the digest.
private final class ConstGuide : SnapGuide {
    private Viewport vp_;
    private int   sx_, sy_;
    private int   prio_;
    private float scale_;
    private bool  rejectEven_;
    this(Viewport vp, int sx, int sy, int prio, float scale, bool rejectEven) {
        vp_ = vp; sx_ = sx; sy_ = sy;
        prio_ = prio; scale_ = scale; rejectEven_ = rejectEven;
    }
    void limits(float innerPx, float outerPx) {}
    bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                   out float distPx, ref int priority)
    {
        if (rejectEven_ && idx >= 0 && (idx & 1) == 0) return false;
        float px, py, ndcZ;
        if (!projectToWindowFull(candWorld, vp_, px, py, ndcZ)) return false;
        immutable float dx = px - cast(float)sx_;
        immutable float dy = py - cast(float)sy_;
        distPx   = scale_ * sqrt(dx * dx + dy * dy);
        priority = prio_;
        return true;
    }
    void setDrawState(GuideDrawState s) {}
    uint flags() const { return 0; }
}

// ---------------------------------------------------------------------------
// The sweep.
// ---------------------------------------------------------------------------
unittest {
    import std.array   : appender;
    import std.format  : format;
    import std.process : environment;

    // The grids are `__gshared` and keyed on (slot, kind, viewport, mesh); a
    // fresh local `Mesh` can land on a recycled stack address carrying another
    // module's mutationVersion, so drop them rather than trust the key —
    // `snap_test.d`'s own blocks open with the same line for the same reason.
    invalidateSnapGrids();

    // Heap-owned so the addresses the grid keys on stay distinct and stable for
    // the whole sweep.
    Mesh* cube  = new Mesh; *cube  = makeCube();
    Mesh* cloud = new Mesh; *cloud = pointCloudMesh();
    Mesh* quad  = new Mesh; *quad  = openQuadMesh();
    Mesh* conc  = new Mesh; *conc  = concaveMesh();
    Mesh* cross = new Mesh; *cross = crossStripsMesh();
    Mesh*[5] fixtures = [cube, cloud, quad, conc, cross];
    static immutable string[5] fixtureNames =
        ["cube", "cloud", "openquad", "concave", "crossstrips"];

    // A second mesh for the background-source slots, offset so its candidates
    // are near the cursor without coinciding with the active mesh's.
    Mesh* bgMesh = new Mesh; *bgMesh = makeCube();
    foreach (ref v; bgMesh.vertices) v = v + Vec3(0.35f, 0.2f, 0.1f);

    // --- the viewports -----------------------------------------------------
    Viewport[3] vps;
    static immutable string[3] vpNames = ["persp-front", "persp-oblique", "ortho"];
    {
        Viewport vp;
        vp.eye    = Vec3(0, 0, 4.0f);
        vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(PI / 3, 4.0f / 3.0f, 0.1f, 100.0f);
        vp.width  = 640; vp.height = 480;
        vps[0] = vp;
    }
    {
        Viewport vp;
        vp.eye    = Vec3(2.3f, 1.7f, 3.1f);
        vp.view   = lookAt(vp.eye, Vec3(0.1f, -0.05f, 0), Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(PI / 4, 1.0f, 0.05f, 200.0f);
        vp.width  = 512; vp.height = 512;
        vps[1] = vp;
    }
    {
        Viewport vp;
        vp.eye    = Vec3(0, 0, 6.0f);
        vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj   = orthographicMatrix(1.5f, 4.0f / 3.0f, 0.1f, 100.0f);
        vp.width  = 640; vp.height = 480;
        vps[2] = vp;
    }

    // --- the enabled-type sets ---------------------------------------------
    //
    // Chosen so every leg of the walk and every cross-leg contest appears:
    // one class alone (no cascade); two and three classes together (the
    // cascade's only reachable state); a centre alone (the leg opens for a
    // type that is not itself a candidate); a centre WITH its element (the
    // both-on contest inside `refineElectedLeg`); vertex+edge, which is the
    // veto's precondition; and the non-mesh types, discrete and constraint.
    static struct TypeSet { string name; uint mask; }
    static immutable TypeSet[] typeSets = [
        TypeSet("V",        SnapType.Vertex),
        TypeSet("E",        SnapType.Edge),
        TypeSet("P",        SnapType.Polygon),
        TypeSet("VE",       SnapType.Vertex | SnapType.Edge),
        TypeSet("VP",       SnapType.Vertex | SnapType.Polygon),
        TypeSet("EP",       SnapType.Edge   | SnapType.Polygon),
        TypeSet("VEP",      SnapType.Vertex | SnapType.Edge | SnapType.Polygon),
        TypeSet("EC",       SnapType.EdgeCenter),
        TypeSet("E+EC",     SnapType.Edge   | SnapType.EdgeCenter),
        TypeSet("PC",       SnapType.PolyCenter),
        TypeSet("P+PC",     SnapType.Polygon | SnapType.PolyCenter),
        TypeSet("V+E+EC",   SnapType.Vertex | SnapType.Edge | SnapType.EdgeCenter),
        TypeSet("all-geo",  SnapType.Vertex | SnapType.Edge | SnapType.EdgeCenter
                          | SnapType.Polygon | SnapType.PolyCenter),
        TypeSet("X",        SnapType.Intersection),
        TypeSet("G",        SnapType.Grid),
        TypeSet("W",        SnapType.Workplane),
        TypeSet("Pv",       SnapType.Pivot),
        TypeSet("Bx",       SnapType.Box),
        TypeSet("WA",       SnapType.WorldAxis),
        TypeSet("V+WA",     SnapType.Vertex | SnapType.WorldAxis),
        TypeSet("V+Bx",     SnapType.Vertex | SnapType.Box),
        TypeSet("V+G+W",    SnapType.Vertex | SnapType.Grid | SnapType.Workplane),
        TypeSet("everything", SnapType.Vertex | SnapType.Edge | SnapType.EdgeCenter
                            | SnapType.Polygon | SnapType.PolyCenter
                            | SnapType.Grid | SnapType.Workplane | SnapType.Pivot
                            | SnapType.Intersection | SnapType.WorldAxis
                            | SnapType.Box),
    ];

    // --- the range pairs ---------------------------------------------------
    //
    // The narrow pair is the one that makes "highlighted but not snapped"
    // reachable at all; the wide pair reaches the tolerance base's OTHER arm
    // (`innerRangePx < kCandidateToleranceBasePx` is false there, so `base`
    // becomes the constant and not the range).
    static struct Ranges { string name; float inner, outer; }
    static immutable Ranges[] rangeSets = [
        Ranges("narrow",  6.0f, 40.0f),
        Ranges("wide",   24.0f, 60.0f),
    ];

    // --- the item frames (Pivot + Box legs) --------------------------------
    ItemSnapFrame[2] frames;
    frames[0].pivot   = Vec3(0.2f, 0.15f, 0.0f);
    frames[0].bboxMin = Vec3(-0.6f, -0.6f, -0.6f);
    frames[0].bboxMax = Vec3( 0.7f,  0.5f,  0.65f);
    frames[0].hasBBox = true;
    frames[1].pivot   = Vec3(-0.45f, 0.35f, 0.2f);
    frames[1].bboxMin = Vec3(-1.1f, -0.2f, -0.3f);
    frames[1].bboxMax = Vec3(-0.1f,  0.9f,  0.8f);
    frames[1].hasBBox = true;
    setItemSnapFrames(frames[]);

    // --- the accumulating dump + the vacuity counters -----------------------
    auto dump = appender!string();
    size_t cases       = 0;
    size_t snapCount   = 0;
    size_t hiOnlyCount = 0;
    size_t missCount   = 0;
    size_t constrCount = 0;
    size_t bgWinCount  = 0;      // a background slot won
    size_t bgCentreWins = 0;     // ...and won with a CENTRE type, which is the
                                 // only route by which `sourceModelSpace` is
                                 // observable at all
    size_t[13] typeWins;         // indexed by cascade-ish bit position
    size_t admitRejectedDiff = 0;   // an `admit` changed the answer
    size_t excludeDiff       = 0;   // an exclusion changed the answer
    size_t guideDiff         = 0;   // a SplitGuide changed the answer
    size_t pairDiff          = 0;   // a two-guide registry changed the answer
    size_t mirrorAgreed      = 0;   // a MirrorGuide agreed with no guide

    void note(string key, const ref SnapResult r) {
        dump.put(resultLine(key, r));
        ++cases;
        if (r.snapped && r.constraintType != SnapType.None) ++constrCount;
        else if (r.snapped) ++snapCount;
        else if (r.highlighted) ++hiOnlyCount;
        else ++missCount;
        if (r.targetSource != 0) {
            ++bgWinCount;
            if (r.targetType == SnapType.EdgeCenter
             || r.targetType == SnapType.PolyCenter) ++bgCentreWins;
        }
        foreach (b; 0 .. 13)
            if (cast(uint)r.targetType == (1u << b)) ++typeWins[b];
    }

    // The cursor grid: 5x5 across the middle 3/4 of each viewport, so the
    // sweep sees the mesh from on-element pixels, near-miss pixels and pixels
    // with nothing under them at all.
    int[5] cursorFrac = [12, 31, 50, 69, 88];   // per cent of width / height

    // -----------------------------------------------------------------------
    // Sweep A — the geometric core. Every fixture x viewport x type set x
    // range pair x cursor cell, with no background, no exclusion, no admit and
    // no guide. This is the bulk of the corpus and the part a change to the
    // accumulator, the cascade or the refinement moves.
    // -----------------------------------------------------------------------
    foreach (fi, m; fixtures) {
        foreach (vi, ref vp; vps) {
            foreach (ts; typeSets) {
                foreach (rs; rangeSets) {
                    foreach (cxi, cxf; cursorFrac) {
                        foreach (cyi, cyf; cursorFrac) {
                            immutable int sx = cast(int)(vp.width  * cxf / 100);
                            immutable int sy = cast(int)(vp.height * cyf / 100);
                            SnapPacket cfg;
                            cfg.enabled      = true;
                            cfg.enabledTypes = ts.mask;
                            cfg.snapScope    = SnapMode.Global;
                            cfg.innerRangePx = rs.inner;
                            cfg.outerRangePx = rs.outer;
                            immutable Vec3 cursorWorld = Vec3(3.5f, -1.25f, 0.75f);
                            auto r = snapCursor(cursorWorld, sx, sy, vp, *m,
                                                ModelSpace.world(), cfg);
                            note(format("A/%s/%s/%s/%s/%d%d", fixtureNames[fi],
                                        vpNames[vi], ts.name, rs.name, cxi, cyi), r);
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sweep B — the scope filter. Only the sets whose membership straddles the
    // Component / Item buckets can move here, but every set is swept anyway:
    // `typeEligible` is a TOTAL predicate and a change to it must show on the
    // sets it is supposed to leave alone as well.
    // -----------------------------------------------------------------------
    foreach (sc; [SnapMode.Component, SnapMode.Item]) {
        foreach (fi, m; fixtures) {
            foreach (ts; typeSets) {
                foreach (cxi, cxf; cursorFrac) {
                    auto vp = vps[0];
                    immutable int sx = cast(int)(vp.width  * cxf / 100);
                    immutable int sy = cast(int)(vp.height * 50    / 100);
                    SnapPacket cfg;
                    cfg.enabled      = true;
                    cfg.enabledTypes = ts.mask;
                    cfg.snapScope    = sc;
                    cfg.innerRangePx = 24.0f;
                    cfg.outerRangePx = 60.0f;
                    auto r = snapCursor(Vec3(3.5f, -1.25f, 0.75f), sx, sy, vp, *m,
                                        ModelSpace.world(), cfg);
                    note(format("B/%s/%s/%s/%d", sc == SnapMode.Component ? "cmp" : "itm",
                                fixtureNames[fi], ts.name, cxi), r);
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sweep C — the ACTIVE mesh under a non-identity `ModelSpace`, including a
    // MIRRORED one. This is the leg where the walk's two spaces part company:
    // the broad phase folds the space into the viewport, the fine phase folds
    // points into world, and the facing sign test stays local. A refactor that
    // moved a `toWorld` would show here and nowhere in sweep A.
    // -----------------------------------------------------------------------
    {
        import document : ItemXform;
        ItemXform[3] xs;
        xs[0].pos = Vec3(0.4f, -0.3f, 0.2f);
        xs[1].rot = Vec3(15.0f, 40.0f, -10.0f);
        xs[1].scl = Vec3(1.4f, 0.7f, 1.1f);
        xs[2].scl = Vec3(-1.0f, 1.0f, 1.0f);      // mirrored
        xs[2].rot = Vec3(0.0f, 25.0f, 0.0f);
        static immutable string[3] xNames = ["translated", "rotscaled", "mirrored"];
        foreach (xi, ref x; xs) {
            immutable ModelSpace ms = x.modelSpace();
            foreach (fi, m; fixtures) {
                foreach (ts; typeSets) {
                    foreach (cxi, cxf; cursorFrac) {
                        foreach (cyi, cyf; cursorFrac) {
                            auto vp = vps[1];
                            immutable int sx = cast(int)(vp.width  * cxf / 100);
                            immutable int sy = cast(int)(vp.height * cyf / 100);
                            SnapPacket cfg;
                            cfg.enabled      = true;
                            cfg.enabledTypes = ts.mask;
                            cfg.snapScope    = SnapMode.Global;
                            cfg.innerRangePx = 24.0f;
                            cfg.outerRangePx = 60.0f;
                            auto r = snapCursor(Vec3(3.5f, -1.25f, 0.75f), sx, sy, vp,
                                                *m, ms, cfg);
                            note(format("C/%s/%s/%s/%d%d", xNames[xi], fixtureNames[fi],
                                        ts.name, cxi, cyi), r);
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sweep D — background sources. Two slots, the second under a scaled
    // space, so `sourceMesh` / `sourceModelSpace` are resolved for a NON-zero
    // slot and the centre refinement has to fold through the right one.
    // -----------------------------------------------------------------------
    {
        import document : ItemXform;
        ItemXform bgX;
        bgX.pos = Vec3(-0.5f, 0.25f, -0.15f);
        bgX.scl = Vec3(0.8f, 1.3f, 0.9f);
        // The NON-IDENTITY space goes on the CUBE, not on the point cloud, and
        // that ordering is the whole value of this sweep. With it the other way
        // round the corpus was blind to `sourceModelSpace`: a point cloud has
        // no edges and no faces, so no background winner could ever reach the
        // centre refinement that folds through a slot's own space, and
        // neutering `sourceModelSpace` left the 72 105-case digest identical.
        // Measured, not reasoned — see the task log's mutation M11.
        const(Mesh)*[2] srcs   = [cast(const(Mesh)*)bgMesh, cast(const(Mesh)*)cloud];
        ModelSpace[2]   spaces = [bgX.modelSpace(), ModelSpace.world()];
        setBackgroundSnapSources(srcs[], spaces[]);
        scope (exit) setBackgroundSnapSources(null, null);

        foreach (vi, ref vp; vps) {
            foreach (ts; typeSets) {
                foreach (cxi, cxf; cursorFrac) {
                    foreach (cyi, cyf; cursorFrac) {
                        immutable int sx = cast(int)(vp.width  * cxf / 100);
                        immutable int sy = cast(int)(vp.height * cyf / 100);
                        SnapPacket cfg;
                        cfg.enabled      = true;
                        cfg.enabledTypes = ts.mask;
                        cfg.snapScope    = SnapMode.Global;
                        cfg.innerRangePx = 24.0f;
                        cfg.outerRangePx = 60.0f;
                        auto r = snapCursor(Vec3(3.5f, -1.25f, 0.75f), sx, sy, vp,
                                            *cube, ModelSpace.world(), cfg);
                        note(format("D/%s/%s/%d%d", vpNames[vi], ts.name, cxi, cyi), r);
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sweep E — the two client seams (`excludeVerts` and `admit`) and the two
    // guides. Each case is run twice, once bare and once with the seam, and
    // the pair is dumped: what is being frozen is not only the answer but the
    // DIFFERENCE the seam makes, which is the property `consider`'s ordering
    // (admit before the projection and before the compare) is about.
    // -----------------------------------------------------------------------
    {
        uint[4] exclude = [0u, 1u, 2u, 3u];
        foreach (fi, m; fixtures) {
            foreach (vi, ref vp; vps) {
                foreach (ts; typeSets) {
                    foreach (cxi, cxf; cursorFrac) {
                        foreach (cyi, cyf; cursorFrac) {
                            immutable int sx = cast(int)(vp.width  * cxf / 100);
                            immutable int sy = cast(int)(vp.height * cyf / 100);
                            SnapPacket cfg;
                            cfg.enabled      = true;
                            cfg.enabledTypes = ts.mask;
                            cfg.snapScope    = SnapMode.Global;
                            cfg.innerRangePx = 24.0f;
                            cfg.outerRangePx = 60.0f;
                            immutable Vec3 cw = Vec3(3.5f, -1.25f, 0.75f);
                            immutable string k = format("%s/%s/%s/%d%d",
                                fixtureNames[fi], vpNames[vi], ts.name, cxi, cyi);

                            auto bare = snapCursor(cw, sx, sy, vp, *m,
                                                   ModelSpace.world(), cfg);

                            auto rx = snapCursor(cw, sx, sy, vp, *m,
                                                 ModelSpace.world(), cfg, exclude[]);
                            note("E-excl/" ~ k, rx);
                            if (resultLine("", rx) != resultLine("", bare)) ++excludeDiff;

                            // Reject every ODD element index. Not "reject
                            // everything": a predicate that admits nothing
                            // only proves the pass-through, while this one
                            // has to PROMOTE a runner-up, which is the
                            // ordering property.
                            bool oddRejects(SnapType t, int idx, int slot) nothrow {
                                return !(idx >= 0 && (idx & 1) != 0);
                            }
                            auto ra = snapCursor(cw, sx, sy, vp, *m,
                                                 ModelSpace.world(), cfg, null,
                                                 &oddRejects);
                            note("E-admit/" ~ k, ra);
                            if (resultLine("", ra) != resultLine("", bare))
                                ++admitRejectedDiff;

                            SnapGuide[1] mirror = [new MirrorGuide(vp, sx, sy)];
                            auto rm = snapCursor(cw, sx, sy, vp, *m,
                                                 ModelSpace.world(), cfg, null, null,
                                                 mirror[]);
                            note("E-mirror/" ~ k, rm);
                            if (resultLine("", rm) == resultLine("", bare))
                                ++mirrorAgreed;

                            SnapGuide[1] split =
                                [new SplitGuide(vp, sx, sy, SnapType.Polygon)];
                            auto rg = snapCursor(cw, sx, sy, vp, *m,
                                                 ModelSpace.world(), cfg, null, null,
                                                 split[]);
                            note("E-split/" ~ k, rg);
                            if (resultLine("", rg) != resultLine("", bare)) ++guideDiff;

                            // TWO guides at the SAME priority, answering
                            // different distances, the second rejecting the
                            // even indices. Only this pairing can observe
                            // `arbitrate`'s registration-order rule; see
                            // `ConstGuide`.
                            SnapGuide[2] pair = [
                                new ConstGuide(vp, sx, sy, 3, 1.00f, false),
                                new ConstGuide(vp, sx, sy, 3, 0.25f, true),
                            ];
                            auto rp = snapCursor(cw, sx, sy, vp, *m,
                                                 ModelSpace.world(), cfg, null, null,
                                                 pair[]);
                            note("E-pair/" ~ k, rp);
                            if (resultLine("", rp) != resultLine("", bare)) ++pairDiff;
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sweep F — snap DISABLED, and the degenerate ranges. The pass-through is
    // part of the election's contract (`SnapResult` carries the input, not a
    // zero) and a degenerate `outerRangePx` takes the candidate grid's
    // unfiltered branch, where the edge leg's endpoint guard is the only one
    // there is.
    // -----------------------------------------------------------------------
    foreach (fi, m; fixtures) {
        foreach (ts; typeSets) {
            auto vp = vps[0];
            SnapPacket off;
            off.enabled      = false;
            off.enabledTypes = ts.mask;
            auto r0 = snapCursor(Vec3(1.5f, 2.5f, -3.5f), 100, 100, vp, *m,
                                 ModelSpace.world(), off);
            note(format("F-off/%s/%s", fixtureNames[fi], ts.name), r0);

            SnapPacket deg;
            deg.enabled      = true;
            deg.enabledTypes = ts.mask;
            deg.snapScope    = SnapMode.Global;
            deg.innerRangePx = 0.0f;
            deg.outerRangePx = 0.0f;
            auto r1 = snapCursor(Vec3(1.5f, 2.5f, -3.5f), 320, 240, vp, *m,
                                 ModelSpace.world(), deg);
            note(format("F-deg/%s/%s", fixtureNames[fi], ts.name), r1);
        }
    }

    setItemSnapFrames(null);
    invalidateSnapGrids();

    // -----------------------------------------------------------------------
    // The vacuity assertions. Every one of these is a branch this module's
    // header claims the corpus reaches; a corpus that stopped reaching one
    // would otherwise keep comparing byte-identical against its own silence.
    // -----------------------------------------------------------------------
    assert(cases > 20_000,
        format("corpus too small to be a corpus: %d cases", cases));
    assert(snapCount   > 0, "no case ever SNAPPED — the corpus is not electing");
    assert(hiOnlyCount > 0, "no case ever highlighted-without-snapping");
    assert(missCount   > 0, "no case ever missed — every cursor is on geometry");
    assert(constrCount > 0, "the CONSTRAINT tier never won a case");
    assert(bgWinCount  > 0, "a background slot never won — sweep D is inert");
    assert(bgCentreWins > 0,
        "no background winner ever carried a CENTRE type — `sourceModelSpace` "
        ~ "is unobservable and sweep D cannot see a slot-space mistake");

    // Per-type: the six mesh-element / centre types plus the five non-mesh
    // ones the sweep enables. Named individually so a zero says WHICH leg went
    // quiet rather than "something".
    static struct Expect { uint bit; string name; }
    immutable Expect[] expects = [
        Expect(0,  "Vertex"), Expect(1, "Edge"),      Expect(2, "EdgeCenter"),
        Expect(3,  "Polygon"), Expect(4, "PolyCenter"), Expect(5, "Grid"),
        Expect(6,  "Workplane"), Expect(7, "Pivot"),  Expect(8, "Intersection"),
        Expect(12, "Box"),
    ];
    foreach (e; expects)
        assert(typeWins[e.bit] > 0,
            format("no case was ever won by %s — that leg is not exercised", e.name));

    assert(excludeDiff       > 0, "excludeVerts never changed an answer");
    assert(admitRejectedDiff > 0, "the admit predicate never changed an answer");
    assert(guideDiff         > 0, "the priority-splitting guide never changed an answer");
    assert(mirrorAgreed      > 0, "the neutral guide never agreed with no guide");
    assert(pairDiff          > 0, "the two-guide registry never changed an answer");

    // -----------------------------------------------------------------------
    // The digest, and the file when asked for one.
    //
    // FNV-1a rather than a Phobos digest: it is four lines, it has no import
    // that a `tests` build has to acquire, and what is needed here is a stable
    // fingerprint for a human to compare between two runs, not a cryptographic
    // property.
    // -----------------------------------------------------------------------
    immutable string text = dump.data;
    ulong h = 0xcbf29ce484222325UL;
    foreach (ubyte b; cast(const(ubyte)[])text) {
        h ^= b;
        h *= 0x100000001b3UL;
    }

    immutable string outPath = environment.get("VIBE3D_SNAP_CORPUS_OUT", "");
    if (outPath.length) {
        import std.file  : write;
        import std.stdio : stderr;
        write(outPath, text);
        stderr.writefln("snap election corpus: %d cases, fnv1a=%016x -> %s",
                        cases, h, outPath);
    }
}
