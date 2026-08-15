module snap_election;

import std.math : sqrt, isNaN;
import math : Vec3, Viewport, ModelSpace, projectToWindowFull;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
import toolpipe.guide   : SnapGuide, kGuidePrioritySeed;
import constraint : BackgroundSource;
import snap : SnapResult, SnapAdmit, typeEligible,
              cascadeClass, cascadeClassWins, kAbsentClassDist,
              kCascadeVertex, kCascadeEdge, kCascadePolygon,
              kCandidateToleranceBasePx, kVertexToleranceScale;

// ---------------------------------------------------------------------------
// THE SNAP ELECTION (task 0721, audit №4 item P3).
//
// `snapCursor` does two separable things: it ENUMERATES candidates (which
// grids to query, which legs a type set opens, how a face or an edge yields a
// point) and it ELECTS one of them (what beats what, and where the elected
// point finally sits). This module is the second half. `snap.d` keeps the
// first, and the seam between them is three calls — `consider`,
// `considerConstraint`, `resolve`.
//
// THE MOVE IS VERBATIM. Every body below was lifted line-for-line out of
// `snapCursor`'s eleven nested closures; the prose came with it, because the
// prose is the measured law and not decoration. Four edits were needed and
// they are all mechanical:
//
//   1. `bestWorld` / `cBestWorld` lost their `= cursorWorld` initialisers — a
//      field initialiser must be a compile-time constant — and are set from
//      `cursorWorld` in the constructor instead, which is the same value at
//      the same moment.
//   2. `sourceMesh`'s `return &mesh;` became `return mesh;`: the active mesh
//      arrives as a pointer here rather than as `snapCursor`'s `const ref`.
//   3. the closures became methods, and the ones `snapCursor` never called
//      became `private` — a NARROWING, not a widening. `snap.d` can reach
//      exactly three of them.
//   4. the result merge at the bottom of `snapCursor` became `resolve()`, and
//      the pass-through it starts from became `passThrough` so the disabled
//      query and the missed query state it once between them instead of twice.
//
// WHY A STRUCT AND NOT ELEVEN CLOSURES. The eleven shared thirteen mutable
// locals by capture, so every one of them could write any of the accumulator
// and nothing said which did. Naming the state makes the answer greppable and
// makes the read-only half (`sourceMesh`, `screenDistPx`, `legCenterPoint`)
// visibly read-only.
//
// THE GATE THIS MOVE WAS HELD TO is bitwise identity of the election over
// `tests/unit/snap_election_corpus_test.d` — 72 105 cases, every float
// compared as its raw IEEE-754 pattern. See that module's header, and the task
// log for the eleven mutations that prove the corpus can see the rules below.
//
// LIFETIME. The environment fields are borrowed, not owned: `SnapElection` is
// built as a local inside `snapCursor` and dies with the call, so the delegate
// and the slices it keeps never outlive the frames they point into. The
// `scope` on `snapCursor`'s own parameters says so at that end; there is no
// `scope` here because a struct field cannot carry one, which is why this
// paragraph exists.
// ---------------------------------------------------------------------------
struct SnapElection {

    // -----------------------------------------------------------------------
    // The environment — everything the election READS and never writes.
    // `vp` / `cfg` / `ms` are held by value: they are small, they are copied
    // once per query, and holding them by value is what lets every moved body
    // below keep its original spelling.
    // -----------------------------------------------------------------------
    private Vec3         cursorWorld;
    private int          sx, sy;
    private Viewport     vp;
    private const(Mesh)* mesh;      ///< the ACTIVE mesh (source slot 0)
    private ModelSpace   ms;        ///< …and its space
    private SnapPacket   cfg;
    private SnapAdmit    admit;
    private SnapGuide[]  guides;
    private const(BackgroundSource)[] bgFull;

    // Discrete tier accumulator.
    float    bestDist   = float.infinity;
    Vec3     bestWorld;         // = cursorWorld, in the constructor
    int      bestIdx    = -1;
    int      bestSource = 0;
    SnapType bestType   = SnapType.None;

    // -----------------------------------------------------------------------
    // Task 0551: the discrete tier's accumulator is SPLIT, not replaced.
    //
    //   * `best*` above now collects only the types the cascade does not model
    //     (`cascadeClass(t) < 0`) — every centre type, Grid, Workplane, Pivot,
    //     Box, Intersection. Its rule is untouched.
    //   * `clsBest[0..2]` collect the vertex / edge / polygon classes, one
    //     nearest per class, under the SAME rule.
    //
    // After the walk the three class winners are merged by the measured
    // cascade into one champion, and that champion is folded back into
    // `best*` — so the final answer is still one accumulator's worth of state
    // and the merge rule below is unchanged.
    //
    // NEUTRALITY, and it is an argument about the partition rather than about
    // a fixture. The old accumulator is `argmin` over all candidates of
    // `(-prio, dist, seq)` — the strict `<` means the earliest enumerated wins
    // a tie, which is exactly a third key. `seq` below makes that key
    // explicit, so splitting the candidates into disjoint sets, taking the
    // argmin of each, and then the argmin of those, is the SAME element. When
    // fewer than two cascade classes have a candidate the cascade returns its
    // sole class's argmin (clause 2 of `cascadeClassWins`), so the whole
    // construction collapses to the old one. The behaviour can only differ
    // when at least two of vertex / edge / polygon are enabled AND both
    // produced a candidate — which is precisely the contested case, and the
    // only case anything was measured about.
    // -----------------------------------------------------------------------
    struct ClassBest {
        bool     has;
        float    dist  = kAbsentClassDist;
        int      prio  = int.min;
        long     seq   = long.max;
        Vec3     world;
        int      idx   = -1;
        int      slot;
        SnapType type  = SnapType.None;
    }
    ClassBest[3] clsBest;
    long bestSeq  = long.max;   // enumeration order of `best*`'s current holder
    long seqNext  = 0;          // monotonic per accepted candidate

    // Constraint tier accumulator (Stage 2).
    float    cBestDist  = float.infinity;
    Vec3     cBestWorld;        // = cursorWorld, in the constructor
    SnapType cBestType  = SnapType.None;

    // ------------------------------------------------------------------
    // S4(a): the guide arbitration's half of the accumulator.
    //
    // `int.min` is the "nothing accumulated yet" sentinel, and it is chosen so
    // that the generalised comparison below REDUCES to the historical one when
    // no guide is registered, rather than merely agreeing with it:
    //
    //   with `guides` empty every candidate carries `prio == 0`, so
    //     first candidate : 0 > int.min                 -> accept
    //                       (old: d < float.infinity    -> accept)
    //     later candidates: 0 == 0 && d < bestDist      -> compare distance
    //                       (old: d < bestDist          -> compare distance)
    //
    // Those are the same two decisions, not two decisions that happen to
    // coincide on this fixture. A `bestPrio` initialised to 0 instead would
    // have silently dropped the first candidate whenever a guide returned a
    // negative priority, which is exactly the class of bug an "empty registry"
    // stage cannot catch by running.
    // ------------------------------------------------------------------
    int bestPrio  = int.min;
    int cBestPrio = int.min;

    /// Bind the election to one query. Nothing is copied that the query does
    /// not already own, and nothing here can fail: a `SnapElection` with no
    /// candidate offered to it resolves to the pass-through.
    this(Vec3 cursorWorld, int sx, int sy, const ref Viewport vp,
         const(Mesh)* mesh, const ModelSpace ms, const ref SnapPacket cfg,
         SnapAdmit admit, SnapGuide[] guides,
         const(BackgroundSource)[] bgFull)
    {
        this.cursorWorld = cursorWorld;
        this.sx = sx; this.sy = sy;
        this.vp = vp;
        this.mesh = mesh;
        this.ms = ms;
        this.cfg = cfg;
        this.admit = admit;
        this.guides = guides;
        this.bgFull = bgFull;
        // The two accumulator positions the caller's own point seeds. Neither
        // is observable unless a candidate was accepted (both are gated on a
        // distance that starts at infinity), but seeding them keeps the
        // struct's state the state `snapCursor`'s locals had.
        this.bestWorld  = cursorWorld;
        this.cBestWorld = cursorWorld;
    }

    /// The result a query with NO accepted candidate reports: the caller's own
    /// position passed through, every target field at its absent value. Stated
    /// once, for the two callers that need it — a query with snapping switched
    /// off, and `resolve` before it looks at the accumulators.
    static SnapResult passThrough(Vec3 cursorWorld) {
        SnapResult res;
        res.worldPos     = cursorWorld;
        res.highlightPos = cursorWorld;
        res.targetType   = SnapType.None;
        res.targetIndex  = -1;
        res.targetSource = 0;
        return res;
    }


    // ---- the read-only half: resolving a candidate's provenance -----------
private:

    /// Resolve a candidate's source slot to the mesh it was enumerated from:
    /// slot 0 is the `mesh` argument (the active layer), 1..N index
    /// `bgFull`. Returns null for a slot with no mesh — a candidate whose
    /// source vanished cannot be refined, and the caller leaves it alone
    /// rather than guessing.
    const(Mesh)* sourceMesh(int slot) {
        if (slot == 0) return mesh;   // a pointer here, a `ref` in snapCursor
        immutable size_t i = cast(size_t)(slot - 1);
        return i < bgFull.length ? bgFull[i].mesh : null;
    }

    /// Resolve a candidate's source slot to ITS OWN ModelSpace — the
    /// primary's `ms` for slot 0, the owning background layer's for slots
    /// 1..N (task 0617 Stage 4: `legCenterPoint` below used to read
    /// `sourceMesh(slot)`'s vertices raw, which is LOCAL for a background
    /// layer, while every OTHER point this function hands to `consider` is
    /// WORLD — see `walkSource`'s own `toWorld`). Falls back to identity on
    /// a bounds miss (source list shrank between snapshot and use — cannot
    /// happen today, `bgFull` is `.dup`'d once and read without the lock
    /// afterward, but is fail-soft anyway).
    ModelSpace sourceModelSpace(int slot) {
        if (slot == 0) return ms;
        immutable size_t i = cast(size_t)(slot - 1);
        return i < bgFull.length ? bgFull[i].space : ModelSpace.world();
    }

    /// Screen distance in pixels from the cursor to a world point, or -1 when
    /// the point does not project (behind camera). Same projection and same
    /// metric `consider` ranks with, so a distance produced here is directly
    /// comparable with a `ClassBest.dist`.
    float screenDistPx(Vec3 w) {
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(w, vp, pxs, pys, ndcZ)) return -1.0f;
        immutable float dx = pxs - cast(float)sx;
        immutable float dy = pys - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    /// The CENTRE point of an elected leg, in WORLD space: an edge's
    /// midpoint (parameter 0.5 exactly, which is what the reference
    /// evaluates) or a face's centroid. False when the leg cannot be
    /// resolved (missing source, stale index, empty face) — the caller then
    /// leaves the elected point alone.
    ///
    /// Task 0617 Stage 4 review fix: folds the result through the slot's OWN
    /// ModelSpace before returning. Both this function's callers
    /// (`refineElectedLeg`, which publishes the result as the snap
    /// result's world position, and `vertexSlotVetoed`, which projects it
    /// with the WORLD viewport) treat the return value as world — an edge
    /// midpoint / face centroid is an AFFINE COMBINATION of the source's
    /// vertices, and an affine map preserves affine combinations regardless
    /// of scale/rotation/mirror, so transforming the already-computed local
    /// centre is exactly equal to averaging already-world vertices; no
    /// per-vertex fold is needed here the way `walkSource`'s fine phase
    /// needs one for a NON-affine metric (nearest-point, triangle rank).
    bool legCenterPoint(int cls, int idx, int slot, out Vec3 p) {
        if (idx < 0) return false;
        const(Mesh)* m = sourceMesh(slot);
        if (m is null) return false;
        const ModelSpace lms = sourceModelSpace(slot);
        Vec3 toWorld(Vec3 vLocal) { return lms.isIdentity ? vLocal : lms.toWorldPoint(vLocal); }
        if (cls == kCascadeEdge) {
            if (cast(size_t)idx >= m.edges.length) return false;
            auto e = m.edges[idx];
            if (e[0] >= m.vertices.length || e[1] >= m.vertices.length) return false;
            p = toWorld((m.vertices[e[0]] + m.vertices[e[1]]) * 0.5f);
            return true;
        }
        if (cls != kCascadePolygon) return false;
        if (cast(size_t)idx >= m.faces.length) return false;
        if (m.faces[idx].length == 0) return false;
        p = toWorld(m.faceCentroid(cast(uint)idx));
        return true;
    }

    // Ask the registered guides about one enumerated candidate. Returns false
    // when NO guide admits it, in which case the candidate is dropped as if it
    // had never been enumerated (the same contract `admit` has). When several
    // guides admit it, the HIGHEST-priority answer supplies both the ranking
    // distance and the priority; equal priorities are settled by registration
    // order (strict `>`), which is the only tie-break the registry can offer.
    //
    // The rule is now READ rather than header-derived: priority strictly
    // dominates, distance breaks ties only WITHIN one priority, and the
    // environment PRE-SEEDS the priority slot before every call — see
    // `kGuidePrioritySeed`, which is why `gp` below is seeded and not left to
    // the zero an `out` parameter would have supplied.
    //
    // The guide re-RANKS a candidate; it never introduces one. `candWorld`,
    // `type`, `idx` and `slot` are the enumeration's, and the winner's world
    // position is still the candidate's own — a guide that answers with a
    // different distance changes WHICH candidate wins, never WHERE it is.
    // This is also the one arbitration detail we know about and have NOT
    // adopted: the reference's proximity answer is a per-axis write mask,
    // naming which of x/y/z the winning guide may overwrite. A mask needs a
    // guide that supplies a POSITION to mask, and ours supplies only a
    // ranking — so there is nothing here for the bits to select. If a guide
    // ever answers with a point of its own, that is when the mask becomes a
    // thing we are missing rather than a thing we have no use for.
    bool arbitrate(Vec3 candWorld, SnapType type, int idx, int slot,
                   ref float distPx, ref int prio)
    {
        bool admitted = false;
        foreach (g; guides) {
            float gd;
            int   gp = kGuidePrioritySeed;
            if (!g.proximity(candWorld, type, idx, slot, gd, gp)) continue;
            if (!admitted || gp > prio) {
                admitted = true;
                distPx   = gd;
                prio     = gp;
            }
        }
        return admitted;
    }

    // ---- the seam snap.d uses: offer one enumerated candidate -------------
public:

    // `slot` identifies which snap SOURCE this candidate came from (0 = active
    // mesh, 1..N = background source). It is recorded on the winner so the
    // highlight renderer can resolve the element against the right mesh — a
    // source-local index alone is ambiguous across layers (layers Stage 5).
    //
    // `rankPx` — A LEG THAT COMPUTES ITS OWN RANK HANDS IT IN HERE (task 0588).
    // NaN, the default, means "rank this candidate by the re-projected screen
    // distance of its world point", which is what every leg but the polygon
    // one does and what this function has always done. The polygon-SURFACE leg
    // is the single exception: its reference law ranks a ray HIT at an exact
    // zero and a miss at a world distance divided by ONE world-per-pixel, so
    // its rank is not a re-projection and cannot be recovered from the elected
    // point. See `closestOnPolygonSurface`.
    //
    // A supplied rank REPLACES the screen distance everywhere downstream — the
    // range reject just below, the guide arbitration's input, the cascade
    // slot's `dist`, the acceptance test at the merge. That is the whole point:
    // a rank that only ranked and did not gate would be a third metric nobody
    // measured. What it does NOT replace is the projection above it, which
    // stays as the behind-the-camera validity guard it already was.
    void consider(Vec3 candWorld, int idx, SnapType type, int slot,
                  float rankPx = float.nan) {
        // The client's admission rule runs FIRST — before the projection and
        // before the distance compare. Order is load-bearing, not stylistic:
        // rejecting after the compare would let an inadmissible candidate
        // lower `bestDist` and so silently veto an admissible one further
        // away. A rejected candidate must be as if it were never enumerated.
        if (admit !is null && !admit(type, idx, slot)) return;
        float pxs, pys, ndcZ;
        // projectToWindowFull rejects behind-camera (w<=0) but does NOT
        // clip to the screen rectangle, which is exactly what we want
        // — a snap target a few pixels off-screen should still snap if
        // the cursor is also off-screen near it (e.g. dragging out
        // beyond a viewport edge).
        if (!projectToWindowFull(candWorld, vp, pxs, pys, ndcZ)) return;
        float dx = pxs - cast(float)sx;
        float dy = pys - cast(float)sy;
        float d  = sqrt(dx * dx + dy * dy);
        if (!isNaN(rankPx)) d = rankPx;
        if (d > cfg.outerRangePx) return;
        // S4(a): the guide arbitration. The gather cutoff above stays ahead of
        // it deliberately — the candidate GRID is queried with `outerRangePx`
        // in the first place, so a candidate outside the gather range is one
        // no guide could have been offered anyway, and applying the cutoff to
        // a guide-supplied distance would let the ranking value masquerade as
        // a range test.
        //
        // KNOWN DIFFERENCE, deliberate. The reference's guide loop drops a
        // candidate at the INNER range, not the outer one — it is a
        // position-snapping loop with no notion of "highlighted but not
        // snapped", so for it inner IS the only range that can reject. We
        // gather at outer so a candidate can highlight without winning, and
        // then apply inner at the merge, which is the same acceptance with an
        // extra state in front of it. A guide sees candidates ours would only
        // highlight; none of them can snap.
        //
        // UNREACHABLE in phase (a): `guides` is empty at every call site, so
        // `prio` stays 0 and the comparison below is the historical one.
        int prio = 0;
        if (guides.length != 0 && !arbitrate(candWorld, type, idx, slot, d, prio))
            return;
        immutable long seq = seqNext++;

        // Task 0551: a cascade class goes to its own slot, everything else to
        // the shared one. Both use the identical (prio, dist, seq) rule.
        immutable int cls = cascadeClass(type);
        if (cls >= 0) {
            auto cb = &clsBest[cls];
            if (prio > cb.prio || (prio == cb.prio && d < cb.dist)) {
                cb.has   = true;
                cb.dist  = d;
                cb.prio  = prio;
                cb.seq   = seq;
                cb.world = candWorld;
                cb.idx   = idx;
                cb.slot  = slot;
                cb.type  = type;
            }
            return;
        }

        if (prio > bestPrio || (prio == bestPrio && d < bestDist)) {
            bestDist   = d;
            bestPrio   = prio;
            bestSeq    = seq;
            bestWorld  = candWorld;
            bestIdx    = idx;
            bestSource = slot;
            bestType   = type;
        }
    }

    // Constraint-tier consider — same screen-distance check but into a
    // separate accumulator. Constraints own POSITION only; targetType/
    // targetIndex/highlightPos stay the discrete tier's (Stage 2 merge rule).
    void considerConstraint(Vec3 candWorld, SnapType type) {
        // Same admission seam, same order (see `consider`). A constraint
        // candidate is a line/plane hit, not a mesh element, so it carries no
        // element index and no source: the predicate sees (type, -1, 0), the
        // same pair `SnapResult` would report for it.
        if (admit !is null && !admit(type, -1, 0)) return;
        float pxs, pys, ndcZ;
        if (!projectToWindowFull(candWorld, vp, pxs, pys, ndcZ)) return;
        float dx = pxs - cast(float)sx;
        float dy = pys - cast(float)sy;
        float d  = sqrt(dx * dx + dy * dy);
        if (d > cfg.outerRangePx) return;
        // Same guide arbitration, same order (see `consider`). Extending it to
        // the constraint tier is OURS and unmeasured — the two-tier split is
        // ours, the reference has no analogue of it — but the alternative is
        // worse in a nameable way: a guide whose whole job is an admission
        // rule would reject every discrete candidate and then watch a
        // constraint hit sail past it. Uniform beats surprising.
        int prio = 0;
        if (guides.length != 0 && !arbitrate(candWorld, type, -1, 0, d, prio))
            return;
        if (prio > cBestPrio || (prio == cBestPrio && d < cBestDist)) {
            cBestDist  = d;
            cBestPrio  = prio;
            cBestWorld = candWorld;
            cBestType  = type;
        }
    }

    // ---- the post-walk half: refine, veto, cascade ------------------------
private:

    // ------------------------------------------------------------------
    // THE CENTRE TYPES REFINE AN ELECTED LEG (task 0560, measured static).
    //
    // `EdgeCenter` / `PolyCenter` are NOT candidates. The reference queries
    // them only INSIDE the branch that already holds a hit edge / hit polygon,
    // and it queries them after the cascade has run; there is no centre entry
    // in the element enumerator's vocabulary at all, so a centre can never be
    // an element and can never compete across legs. What it does is move the
    // elected leg's POINT:
    //
    //   * centre type off              -> the on-element point stands;
    //   * centre on, element type off  -> the centre REPLACES it, no contest;
    //   * both on                      -> a bare screen-distance contest
    //                                     between the on-element point and the
    //                                     centre, no tolerance, no cascade
    //                                     clause, TIES TO THE CENTRE (the
    //                                     element keeps the point only when it
    //                                     is STRICTLY nearer).
    //
    // The leg's RANK is untouched by all of this — the centre inherits it.
    // That is why acceptance (`bestDist <= innerRangePx`, below) still reads
    // the ON-ELEMENT distance after a replacement: the element is what was
    // elected and what was found to be in range, and the centre is where that
    // election points. A centre far outside the range can therefore be
    // snapped to, on the strength of its edge being inside it — which is the
    // reference's behaviour and is the half of this model our old one had
    // backwards (ours could snap to a centre whose own element lost).
    //
    // KNOWN SEAM, ours: with a guide registered, `cb.dist` is the guide's
    // ranking answer rather than a screen distance, so the both-on contest
    // compares a guide distance against a raw one. Every call site registers
    // an empty registry, where the two are the same number; a guide that
    // wanted to rank the centre would need to be offered the centre, and the
    // enumeration has no centre to offer it.
    void refineElectedLeg(int cls, ref ClassBest cb) {
        SnapType centreT, elemT;
        if      (cls == kCascadeEdge)    { centreT = SnapType.EdgeCenter;
                                           elemT   = SnapType.Edge; }
        else if (cls == kCascadePolygon) { centreT = SnapType.PolyCenter;
                                           elemT   = SnapType.Polygon; }
        else return;                     // the vertex leg has no centre twin

        if (!(cfg.enabledTypes & centreT)) return;
        if (!typeEligible(centreT, cfg.snapScope)) return;

        Vec3 c;
        if (!legCenterPoint(cls, cb.idx, cb.slot, c)) return;

        immutable bool elemOn = (cfg.enabledTypes & elemT) != 0
                             && typeEligible(elemT, cfg.snapScope);
        if (!elemOn) {                   // replaces outright
            cb.world = c;
            cb.type  = centreT;
            return;
        }
        immutable float dC = screenDistPx(c);
        if (dC < 0) return;              // centre behind the camera: element stands
        if (cb.dist < dC) return;        // element STRICTLY nearer: it keeps the point
        cb.world = c;                    // ties included
        cb.type  = centreT;
    }

    // ------------------------------------------------------------------
    // THE VERTEX VETO (task 0560, measured static) — a SEPARATE mechanism
    // that happens to be built from the same number.
    //
    // Same quantity as the refinement above (the winning edge's midpoint) at a
    // different site, with different gating and a different effect. It lives
    // in the element enumerator, not the snap arbitration: it is
    // UNCONDITIONAL — no snap type, no mode and no mask is consulted anywhere
    // above it — it runs BEFORE the cascade rather than after, it REMOVES the
    // vertex candidate rather than moving a point, and it has no polygon twin.
    //
    // Modelling it as "EdgeCenter snapping" would be wrong in a user-visible
    // way: it would then switch off with the EdgeCenter preference, and in the
    // reference it does not. It is not gated here either.
    //
    // The rule: the vertex slot is CLEARED whenever the cursor is nearer to
    // the winning edge's midpoint than to the best vertex, provided that
    // midpoint is inside the caller's acceptance range. The reference's two
    // null tests — a vertex candidate and an edge candidate must both exist —
    // are the CALLER's precondition here, because after the priority mask
    // "exists" and "is in the election" are different questions (see the call
    // site for which one this gets asked about, and why).
    //
    // OURS, and the one place our shape forces a narrower rule than the
    // reference's: the reference's enumerator produces an edge hit whether or
    // not any edge-ish snap type is on, because its element classes come from
    // the pick mode. Our walk enumerates a leg only when a type asks for it,
    // so the veto can only fire when the Edge or the EdgeCenter type is also
    // on. With the shipped default (Vertex alone) it never fires. That is a
    // limit of where the enumeration lives, not a gate we added: the veto
    // itself asks no type anything.
    //
    // NARROWER IN A SECOND WAY, and it is named here rather than left to be
    // found: the reference's site is the ELEMENT ENUMERATOR, so its veto also
    // runs for press-picking. Ours is in the snap arbitration only. Our
    // press-pick path does not come through here at all (it is the screen-space
    // pick in `viewcache.d` / the BVH surface pick), so nothing about clicking
    // changed with this port. Putting the veto there too would change what a
    // click selects, which is a selection change with its own evidence bar and
    // its own task — not a rider on a snap port.
    //
    // Returns true when the vertex slot must be treated as EMPTY.
    bool vertexSlotVetoed() {
        Vec3 mid;
        if (!legCenterPoint(kCascadeEdge, clsBest[kCascadeEdge].idx,
                            clsBest[kCascadeEdge].slot, mid))
            return false;
        immutable float dMid = screenDistPx(mid);
        if (dMid < 0) return false;                          // does not project
        if (dMid >= cfg.innerRangePx) return false;          // outside caller range
        return dMid < clsBest[kCascadeVertex].dist;
    }

    // Merge the three class winners by the measured cascade and fold the
    // champion back into `best*`. Called ONCE, after every candidate has been
    // enumerated; the `(prio, dist, seq)` fold is order-independent, so it
    // does not matter that the champion arrives after Grid / Workplane / Pivot
    // / Box have already been considered.
    void foldCascadeChampion() {
        // PRIORITY FIRST, CASCADE SECOND — and the nesting is the whole of the
        // registry's contract surviving this block.
        //
        // The registry's rule is that priority strictly DOMINATES: a candidate
        // at a higher priority wins outright, at any distance. The cascade
        // below ranks by distance and tolerance and reads no priority at all,
        // so asking it first would silently discard a priority difference
        // BETWEEN two classes — a guide that put Edge above Vertex would still
        // get the Vertex the cascade prefers, and the reverse pairing would
        // break the other way. Resolving priority first, and only then asking
        // the cascade to settle the classes that remain, keeps both rules
        // whole: priority decides between classes, the cascade decides within
        // one priority.
        //
        // It is also the reference's own nesting. There, the cascade lives
        // INSIDE one source's proximity answer and has already reduced to a
        // single candidate before that source reports one priority; the
        // priority comparison is the outer loop over sources and the cascade
        // can never overturn it. Ours is asked per CANDIDATE rather than per
        // source, so the same nesting has to be written down instead of coming
        // for free — but it is the same nesting.
        //
        // Neutral where it has always been neutral: with an empty registry
        // every candidate carries priority 0, so `topPrio` is 0, no class is
        // masked, and the cascade sees exactly what it saw before.
        int topPrio = int.min;
        foreach (ref cb; clsBest)
            if (cb.has && cb.prio > topPrio) topPrio = cb.prio;

        bool[3]  has;
        float[3] dist = [kAbsentClassDist, kAbsentClassDist, kAbsentClassDist];
        foreach (i, ref cb; clsBest) {
            // An outranked class is absent as far as the cascade is concerned
            // — not merely far away. Handing it in at its true distance would
            // let it lose the *other* classes their tolerance clauses, which
            // is a vote it does not get to cast.
            if (!cb.has || cb.prio < topPrio) continue;
            has[i]  = true;
            dist[i] = cb.dist;
        }

        // THE VERTEX VETO, and it goes here — inside the top-priority set,
        // between the priority mask and the cascade.
        //
        // The reference has it upstream of both, in the element enumerator.
        // We cannot copy that placement literally, because the thing it would
        // run upstream of is not the reference's structure: the reference's
        // element guide answers ONE priority for vertex, edge and polygon
        // alike (recorded in this file's cascade header), so a priority
        // difference BETWEEN two classes of one source is not a state it can
        // reach, and "veto before priority" versus "veto after priority" is a
        // question its code never has to answer. Ours can reach that state,
        // because our guides are asked per candidate.
        //
        // So the ordering is decided by our own contract, and the contract is
        // already written down two paragraphs up: priority decides BETWEEN
        // classes, and everything else decides WITHIN one priority. The veto
        // is an "everything else". A guide that outranks the vertex class has
        // removed the edge from the election, and an edge that is not in the
        // election has no midpoint to veto with; a guide that outranks the
        // edge class has removed the vertex, and there is nothing left to
        // veto. Either way the registry's rule — higher priority wins
        // outright, at any distance — survives intact, which is what its own
        // two-direction unittest asserts.
        //
        // NEUTRAL WHERE IT MATTERS: with an empty registry — every call site —
        // every class carries priority 0, nothing is masked, and this set is
        // exactly the enumerated one. The ordering is observable ONLY through
        // a guide that splits priorities across cascade classes, i.e. only in
        // the case the reference cannot express.
        //
        // A VETOED VERTEX IS ABSENT BUT STILL VOTES. That asymmetry with the
        // priority mask above is measured, not an oversight: the reference's
        // comparator null-tests only the slot array and reads the distance
        // array unconditionally, and the veto clears the slot while leaving
        // the distance behind. So a vetoed vertex still casts its distance
        // into the edge's and the polygon's tolerance clauses. Only `has` is
        // cleared here; `dist` is deliberately left standing.
        if (has[kCascadeVertex] && has[kCascadeEdge] && vertexSlotVetoed())
            has[kCascadeVertex] = false;

        // The tolerance base. The reference builds it as the SMALLER of the
        // range its snap query carries — it has only the one — and the pick
        // size its enumerator was handed. Ours is the acceptance range:
        // `outerRangePx` is the extra "highlighted but not snapped" state in
        // front of it, which the reference has no analogue of (same reading
        // `consider` above already records for the guide loop's range).
        //
        // (Task 0721 rewrote the two names this sentence used to quote out of
        // it: they were the reference's own spellings, they were never
        // classified, and the sentence says the same thing in ours.)
        immutable float base = cfg.innerRangePx < kCandidateToleranceBasePx
                             ? cfg.innerRangePx : kCandidateToleranceBasePx;
        immutable float[3] tol = [kVertexToleranceScale * base, base, base];

        foreach (i; 0 .. 3) {
            if (!cascadeClassWins(cast(int)i, has, dist, tol[i])) continue;
            auto cb = clsBest[i];
            // The leg is elected. NOW the centre type gets to move its point —
            // after the cascade, never inside it, and without touching
            // `cb.dist`, which is the rank the leg won on and the rank the
            // fold below and the acceptance test further down both read.
            refineElectedLeg(cast(int)i, cb);
            if (cb.prio > bestPrio
                || (cb.prio == bestPrio
                    && (cb.dist < bestDist
                        || (cb.dist == bestDist && cb.seq < bestSeq)))) {
                bestDist   = cb.dist;
                bestPrio   = cb.prio;
                bestSeq    = cb.seq;
                bestWorld  = cb.world;
                bestIdx    = cb.idx;
                bestSource = cb.slot;
                bestType   = cb.type;
            }
            return;
        }
    }

public:

    /// Close the election and report it. Called once, after the last candidate
    /// has been offered; `snapCursor` returns whatever this returns.
    SnapResult resolve() {
        SnapResult res = passThrough(cursorWorld);

    // -----------------------------------------------------------------------
    // Stage 2: Result merge rule (D2).
    //
    // Priority: discrete snap > constraint snap > discrete highlight only.
    // Workplane (always-wins by ~0 screen distance) is in the discrete tier
    // so it keeps its existing behaviour unchanged.
    // -----------------------------------------------------------------------
    // Task 0551: resolve vertex / edge / polygon against each other by the
    // measured cascade, then let the champion compete with the types the
    // cascade does not model. Must run before the merge rule reads `bestDist`.
    foldCascadeChampion();

    bool discreteSnapped     = bestDist  <= cfg.innerRangePx;
    bool discreteHighlighted = bestDist  <= cfg.outerRangePx;
    bool constraintSnapped   = cBestDist <= cfg.innerRangePx;

    if (discreteSnapped) {
        // Discrete wins entirely — byte-identical to pre-Stage-2 for the
        // existing 7 targets (position + highlight + targetType/Index/Source).
        res.snapped      = true;
        res.worldPos     = bestWorld;
        res.highlighted  = true;
        res.highlightPos = bestWorld;
        res.targetType   = bestType;
        res.targetIndex  = bestIdx;
        res.targetSource = bestSource;
        // res.constraintType stays None
    } else if (constraintSnapped) {
        // Constraint provides the position; discrete highlight (if any) stays
        // for visual feedback — the user sees the nearby element hinted at.
        res.snapped        = true;
        res.worldPos       = cBestWorld;
        res.constraintType = cBestType;
        if (discreteHighlighted) {
            res.highlighted  = true;
            res.highlightPos = bestWorld;
            res.targetType   = bestType;
            res.targetIndex  = bestIdx;
            res.targetSource = bestSource;
        }
        // When no discrete highlight: targetType stays None, constraintType
        // carries the identity of what constrained the position.
    } else if (discreteHighlighted) {
        // Discrete only highlighted (not snapped) — no constraint snap.
        res.highlighted  = true;
        res.highlightPos = bestWorld;
        res.targetType   = bestType;
        res.targetIndex  = bestIdx;
        res.targetSource = bestSource;
    }
    return res;
    }
}
