module mesh_dirty;

// ===========================================================================
// HOW TO KEY A CACHE — READ THIS BEFORE WRITING A FRESHNESS CHECK
// ===========================================================================
// TWO KEY TYPES, AND THE DISCRIMINATOR IS THE TERMS — NOT THE CACHE, NOT THE
// MODULE, AND NOT WHETHER YOU HAVE A `Mesh` IN HAND (all eight `MeshDirtyKey`
// sites do). Ask what the key compares BESIDES the mesh address:
//
//   * ANY mesh COUNTER — alone, or with a bus epoch beside it
//       -> `mesh.MeshKey!(Terms...)`. A mesh ADDRESS (always, never optional)
//          plus one field per term you declare. `stamp(m)` writes them all
//          FROM THE MESH, `matches(m)` asks whether all still hold, and
//          `agreesOn!(Sub...)` asks the same over a SUBSET of them, against a
//          second key you sampled yourself. It can therefore only carry terms
//          that EXIST — the six below.
//   * an ADDRESS AND ONE BUS EPOCH, and nothing else
//       -> `MeshDirtyKey` (this module). `stamp(a, e)` / `matches(a, e)` take
//          the pair the caller sampled, so the epoch may come from any of the
//          four watchers — including `g_displayEpochs` and
//          `g_settledGeomEpochs`, which have NO `MeshKey` term at all, and a
//          key over those two cannot be a `MeshKey` today no matter what it
//          holds.
//
// MEASURED, not asserted (task 4060 review): the eight surviving
// `MeshDirtyKey` fields — `bvh_pick._surfKey`, `app.gpuUploadedKey_`,
// `app.displayServiced_`, `editor_app.BgGpu.uploaded`, `snap.meshKey`,
// `symmetry.cachedMeshKey_`, `falloff._selKey`, `actcenter._clusterKey` — are
// every one of them address + one epoch and carry NO counter, and every live
// `MeshKey` instantiation carries at least one counter. Four of the eight
// (display ×2, settled-geometry ×2) have no term to move to; the other four
// (geometry ×2, topology ×2) could be `MeshKey!MeshTermGeomEpoch` /
// `MeshKey!MeshTermTopoEpoch` and were left alone, because 4060 folded only
// the keys that already carried a counter beside their address.
//
// Terms available today, each with its argument at its own declaration:
//
//   mesh.MeshTermMutation   `mutationVersion` — "anything committed changed"
//   mesh.MeshTermStruct     `structVersion`   — the EDGE set
//   mesh.MeshTermTopology   `topologyVersion` — the FACE set
//   mesh.MeshTermMarks      `marksVersion`    — WHICH elements are selected
//   MeshTermGeomEpoch       g_geomEpochs      — position, through the bus
//   MeshTermTopoEpoch       g_topoEpochs      — connectivity, position EXCLUDED
//
// WHICH TO DECLARE. The law is the owner's and is measured (CLAUDE.md, "the
// two domains"): version counters own STRUCTURE, the bus's `Position` class
// owns POSITION, and a cache that depends on both carries BOTH terms.
//
//   * depends on where the vertices ARE  -> a geometry EPOCH, and a counter
//     beside it. An interactive gizmo transform is version-silent at drag AND
//     at commit, so a counter alone reads "fresh" over a cage that moved (task
//     0401 lost three caches to that; 1906 found a fourth). The epoch cannot
//     replace the counter either: `GeomEpochMask` drops `Marks` and
//     `Material`, so a Tab toggle and a crease weight move no epoch.
//     `SubpatchPreview.sourceKey` is the worked example — epoch + mutation +
//     topology, three terms, each with its own witness.
//   * depends only on CONNECTIVITY or on the selected set -> `MeshTermTopoEpoch`
//     and/or `MeshTermMarks`. Do NOT reach for the geometry epoch here: it
//     carries `Position`, so an O(V+E) walk would re-run on every step of
//     every drag.
//   * needs the IDENTITY of a layout rather than "did something change" (is
//     this stencil table still laid out for that topology?) -> a counter, and
//     say so: only an identity answers that question.
//   * the subject is not a `Mesh` at all — a VBO upload generation, a render
//     bridge frame, an undo epoch, an LRU tick -> none of this applies. Keep
//     your own field and say what its subject is at the declaration. 29 of the
//     38 hand-rolled version fields outside mesh.d are this case (task 4060).
//
// SAMPLE EACH TERM ONCE per call when the answer can move under you: stamp a
// local key, compare with `agreesOn`, assign that same local on a miss. An
// epoch re-read at the stamp can swallow a change that landed DURING the
// rebuild — under-invalidation, the unsafe direction.
//
// THE GATE. `tests/unit/version_poll_census_test.d` enumerates every version
// compare in `source/**`. A `MeshKey` instantiation adds NO row — the argument
// for reading that counter was made once, at the term. A NEW TERM, or a
// counter compared by hand, does, and has to be argued in a
// `recorded remainder` comment beside it.
// ===========================================================================

// ---------------------------------------------------------------------------
// Bus-driven, allocation-free per-mesh-address change EPOCHS — the consumer
// side of task 1906 stage 2 (`doc/bus_sync_listeners_plan.md` §3).
//
// WHAT THIS REPLACES. Until stage 2 every position-dependent cache in the tree
// keyed itself on a mesh VERSION COUNTER (`MeshCacheKey{addr, mutationVersion}`
// and friends). An interactive gizmo drag is deliberately version-silent —
// `mutationVersion` does not move at the drag steps NOR at the commit, because
// a bump there cancels an in-session falloff re-grade — so every such cache
// went stale on exactly the gesture users make most (task 0401: three caches;
// task 1906 found a fourth, the surface BVH). The bus's `Position` class IS
// published on that path. This module is how a consumer keys on the bus
// instead of on a counter, WITHOUT giving up the per-mesh-address term that
// stops two same-version layers aliasing.
//
// THE SHAPE, and why it is an epoch rather than a bool. §1.5 of the plan makes
// a listener DIRTY-BIT-ONLY: it may write its own flag and nothing else — no
// mesh read, no GL, no allocation, no publish — because it now runs INSIDE a
// mutation. A single global bool cannot serve several consumers (the first one
// to clear it starves the rest), and a per-consumer bool cannot be reached from
// one listener without a registration/unregistration lifecycle the bus does not
// have (`ChangeBus` has no unsubscribe by design). A monotone epoch per mesh
// address solves both: the listener only ever ADVANCES a number, and each
// consumer stores the epoch it last serviced and compares. That is the same
// shape `fboSelEpoch` in `app.d` already uses for the FBO dirty key, and the
// plan's §3.5 row 24 names it the correct one for a key that must be COMPARED
// rather than reacted to.
//
// A MISS MUST NOT MEAN "CHANGED", AND THAT IS A PERFORMANCE PROPERTY WITH
// TEETH. An address the table has never seen has never changed, so it reads
// `evicted_` — the `any_` value at the last eviction, 0 until one happens —
// and a consumer stamped at 0 stays fresh. The obvious alternative (a miss
// returns `any_`) is silently catastrophic for exactly the workload this
// module's biggest consumer serves: the Topology Pen hovers over a STATIC
// background mesh while every pen edit publishes on the PRIMARY, so that
// background mesh is never in the table, and under the `any_` fallback its
// O(V+T) surface BVH would be rebuilt on every raycast of every edited frame —
// a cache that was previously rebuilt never. Eviction still over-invalidates
// (`evicted_` only ever moves forward, and past any epoch an evicted address
// could hold), which is the safe direction.
//
// AND EVICTION IS A CLIFF, NOT A SLOPE — MEASURED (review of stage 2a/2b,
// 2026-08-25). With `kSlots` distinct addresses churning, a never-changed
// address reads the SAME epoch in 20 of 20 rounds; add ONE more churner and it
// reads a DIFFERENT epoch in 20 of 20 — i.e. every round is a full O(V+T)
// surface-BVH rebuild for a mesh nobody touched. There is no middle: the
// round-robin cursor evicts on every insert once the table is full, and
// `evicted_` moves with it. `kSlots` is therefore not a tuning knob but a
// LAYER-COUNT CEILING, and it is set to 32 (512 bytes per watcher, three
// watchers after stage 2d's review fold) rather than to the number of layers
// anyone has today. The cliff is pinned by the eviction unit test below,
// which asserts both sides of it.
//
// WHAT THIS KEY CANNOT SEE: ADDRESS REUSE (ABA). A consumer stamps `{A, e}`;
// the `Layer` whose mesh lived at A is collected; a NEW `Layer` is allocated
// at the same address and publishes nothing before the consumer next asks.
// `matches(A, e)` is then true and the consumer keeps a cache built over a
// mesh that no longer exists. Exposed today: `ConstrainStage._bgBvh[size_t]`
// and `item_pick._bvh[size_t]`, both keyed by RAW ADDRESS; `BgGpu` is safe
// because its map is keyed by `Layer` IDENTITY, which the GC keeps alive.
// CLOSED AT STAGE 3, by `noteMeshBirth` below, and the closing datum lives on
// `Layer` rather than on `Mesh` — see that function for why the choice matters.
// A birth at an address that already carried a DIFFERENT birth advances every
// watcher for that address, so a stamp taken against the previous occupant
// misses whether or not the new occupant ever publishes. That covers the two
// raw-address consumers above for free: both hold a `BvhPick` whose own
// `_surfKey` is one of these epoch keys, so the container's staleness is the
// key's staleness. The birth table is fixed-size like the watchers, and its
// FULL-TABLE arm answers "assume a different occupant" rather than "first
// use" — so eviction over-invalidates here too, and cannot reopen the hazard
// it was added to close (`MeshBirthTable.observe`).
//
// THE SUBJECT IS ALWAYS KNOWN, so there is no wildcard, and since stage 3 that
// is true by construction rather than by filtering. `ChangeBus.flush` used to
// deliver with `subjectAddr == 0` ("the union of every layer's pending classes,
// subject unknown") and this module ignored it, with `app.d`'s flush block
// re-feeding the same information per layer where the address WAS known. Stage
// 3 deleted both halves: the mesh channel left the flush entirely, so every
// delivery reaching here names a real subject. The `subjectAddr == 0` refusal
// in `note()` stays as a guard, because accepting an aggregate would poison
// every untracked address once per changed frame — the regression the
// paragraph above refuses.
//
// MAIN THREAD ONLY, exactly like the bus it is fed from (plan §1.8): every
// delivery is main-thread by construction (mutating HTTP endpoints reach the
// mesh through `MainThreadBridge`), and every reader below is a main-thread
// consumer. `__gshared` rather than TLS for the same reason `ChangeBus` is:
// the HTTP thread must see the same object, not a zeroed copy of it.
// ---------------------------------------------------------------------------

import mesh_edit_delta : MeshEditScope;
import display_sync    : DisplayRefreshMask;
import change_bus      : changeBus;

/// A watcher over ONE change-class group. Instances are module-level globals
/// below; a consumer never makes its own.
struct MeshDirtyEpochs {
    // A LAYER-COUNT CEILING, not a tuning knob — see the header's eviction
    // paragraph for the measurement. At `kSlots` churning addresses a
    // never-changed address is never disturbed; at `kSlots + 1` it is disturbed
    // on EVERY round, each one an O(V+T) rebuild of a cache nothing dirtied.
    // 32 slots cost 32*(8+8) = 512 bytes per watcher, three watchers, once — a
    // price paid to put the cliff well past any document anyone edits, rather
    // than one layer past the documents we happen to test with.
    private enum int kSlots = 32;

    private size_t[kSlots] addr_;    // 0 = empty; a real Mesh* is never 0
    private ulong[kSlots]  epoch_;
    private ulong          any_;     // advanced on EVERY qualifying change
    private ulong          evicted_; // `any_` at the last eviction; 0 = never
    private int            next_;    // round-robin eviction cursor
    private uint           classes_ = uint.max;

    /// CTFE factory so the `__gshared` instances below can carry their class
    /// mask without a module constructor.
    static MeshDirtyEpochs forClasses(uint classes) {
        MeshDirtyEpochs e;
        e.classes_ = classes;
        return e;
    }

    /// THE LISTENER BODY. `nothrow @nogc` is not decoration: the bus's
    /// subscriber alias is `nothrow` (plan R7) and a listener that allocated
    /// could run the GC from inside a half-finished mesh edit.
    void note(size_t subjectAddr, uint flags) nothrow @nogc {
        if ((flags & classes_) == 0) return;
        // The subject-less aggregate (`ChangeBus.flush`) is not ours to act
        // on — see the header. app.d feeds the same information per layer.
        if (subjectAddr == 0) return;
        ++any_;
        foreach (i; 0 .. kSlots) {
            if (addr_[i] == subjectAddr) { epoch_[i] = any_; return; }
        }
        foreach (i; 0 .. kSlots) {
            if (addr_[i] == 0) { addr_[i] = subjectAddr; epoch_[i] = any_; return; }
        }
        const int i = next_;
        next_ = (next_ + 1) % kSlots;
        // The evicted address loses its epoch, so from now on every untracked
        // address must read at least this far forward.
        evicted_  = any_;
        addr_[i]  = subjectAddr;
        epoch_[i] = any_;
    }

    /// THE READER SIDE, at the lazy recompute. An address the table does not
    /// hold has either never changed (`evicted_` is still 0) or was evicted
    /// (`evicted_` is past its last epoch) — see the header for why this is
    /// NOT `any_`.
    ulong epochFor(size_t a) const nothrow @nogc {
        foreach (i; 0 .. kSlots)
            if (addr_[i] == a) return epoch_[i];
        return evicted_;
    }

    /// Test seam: how many qualifying deliveries this watcher has seen.
    ulong anyEpoch() const nothrow @nogc { return any_; }

    /// Test-only reset: every slot, the round-robin cursor and both counters
    /// go back to their construction-time state. `classes_` is deliberately
    /// UNTOUCHED — it is this watcher's identity (which mask it is), not test
    /// state, and a reset that cleared it would turn `g_geomEpochs` into a
    /// wildcard watcher until the next process restart re-ran the module's
    /// `static` initialisers (it would not — `__gshared` globals are
    /// initialised once, not per test binary).
    void reset() nothrow @nogc {
        addr_[]  = 0;
        epoch_[] = 0;
        any_     = 0;
        evicted_ = 0;
        next_    = 0;
    }
}

/// The (address, epoch) pair a consumer stores — `MeshCacheKey`'s shape with
/// the bus in place of the version counter. The address term is unchanged in
/// meaning and still load-bearing: two layers can share an epoch, and a cache
/// re-pointed at a different mesh must rebuild even if nothing changed.
struct MeshDirtyKey {
    size_t addr;
    ulong  epoch = ulong.max;   // never a real epoch ⇒ a fresh key never matches

    bool matches(size_t a, ulong e) const nothrow @nogc {
        return addr == a && epoch == e;
    }
    void stamp(size_t a, ulong e) nothrow @nogc { addr = a; epoch = e; }
    void clear() nothrow @nogc { addr = 0; epoch = ulong.max; }
}

/// The GEOMETRY-EPOCH term of a `mesh.MeshKey` — `g_geomEpochs` for the key's
/// own mesh address. It is how a cache spells "position, through the bus"
/// inside the same key that carries its counter terms, instead of carrying an
/// epoch beside a `MeshDirtyKey` by hand (task 4060).
///
/// USE IT whenever the cached value depends on where the vertices ARE. It is
/// the term `mutationVersion` cannot replace: an interactive gizmo transform
/// is version-silent at drag AND at commit, so a counter-only key answers
/// "fresh" over a cage that has moved (task 0401 lost three caches to exactly
/// that, and 1906 found a fourth). It is equally the term that cannot replace
/// the counter: `GeomEpochMask` drops `Marks` and `Material`, so a Tab toggle
/// and a crease-weight write move no epoch here. A position-dependent cache
/// declares BOTH; see this module's header for the full recipe.
///
/// `read` and `same` are TEMPLATED on the mesh type, deliberately: it keeps
/// this module free of `import mesh`, which imports this one back. The key's
/// address term and this term's subject are the same `&m`, by construction.
struct MeshTermGeomEpoch {
    enum string field = "geomEpoch";

    static ulong read(M)(ref const M m) nothrow @nogc {
        return g_geomEpochs.epochFor(cast(size_t)&m);
    }
    static bool same(M)(ulong v, ref const M m) nothrow @nogc {
        return v == g_geomEpochs.epochFor(cast(size_t)&m);
    }
}

/// The CONNECTIVITY-EPOCH term of a `mesh.MeshKey` — `g_topoEpochs`, i.e.
/// `Points | Polygons` with `Position` deliberately EXCLUDED.
///
/// USE IT for a stage-owned derived structure that is a function of adjacency
/// and of the selected set and of nothing else. ONE consumer today —
/// `ActionCenterStage._bboxKey`, the bbox membership list, which pairs it with
/// `MeshTermMarks`. The watcher itself has two more (`FalloffStage`'s
/// selection-weight buffer and `ActionCenterStage`'s cluster partition), but
/// those reach it through a `MeshDirtyKey`, not through this term. Read that
/// watcher's own doc comment below before choosing it over `MeshTermGeomEpoch`
/// — the exclusion is the whole reason it exists, and getting it WIDER leaves
/// every value correct and moves only a count, which is why all three
/// consumers are pinned by rates.
///
/// It pairs with a `Marks` term, never replaces one: no watcher here carries
/// `Marks`, on purpose.
struct MeshTermTopoEpoch {
    enum string field = "topoEpoch";

    static ulong read(M)(ref const M m) nothrow @nogc {
        return g_topoEpochs.epochFor(cast(size_t)&m);
    }
    static bool same(M)(ulong v, ref const M m) nothrow @nogc {
        return v == g_topoEpochs.epochFor(cast(size_t)&m);
    }
}

// THE THREE WATCHER MASKS ARE NAMED, and that is not tidiness (task 1906
// stage 2e). A consumer may legitimately DECLINE to key on any of them —
// `render/render_mvp.d`'s IPR accumulator does, because its trigger set is
// neither a subset nor a superset of any mask here — and such a decision is
// only worth writing down if something notices when it stops being true. A
// named mask can be `static assert`ed against; the inline literals these
// replace could not. Values are unchanged.
enum uint DisplayEpochMask = DisplayRefreshMask;
enum uint GeomEpochMask    = MeshEditScope.Position
                           | MeshEditScope.Points
                           | MeshEditScope.Polygons;
enum uint TopoEpochMask    = MeshEditScope.Geometry;

/// Display-relevant classes — what makes the GPU buffers wrong
/// (`display_sync.DisplayRefreshMask`, single-sourced, NOT re-listed here).
__gshared MeshDirtyEpochs g_displayEpochs =
    MeshDirtyEpochs.forClasses(DisplayEpochMask);

/// Geometry-relevant classes — what makes a position-dependent derived
/// structure (a BVH, the cage VBO) wrong. Narrower than the display mask on
/// purpose: a material or map write moves no vertex.
__gshared MeshDirtyEpochs g_geomEpochs =
    MeshDirtyEpochs.forClasses(GeomEpochMask);

/// The SAME geometry classes, MINUS what a live gesture confines to its own
/// moving set (task 2000). `g_geomEpochs` advances on every drag STEP;
/// this one advances only on a change some cache cannot cover by refusing to
/// answer about the moving set.
///
/// WHY IT IS A SEPARATE WATCHER AND NOT A NARROWER MASK. The distinction is
/// not a class — the positions really did change, and the display, the GPU
/// upload and the surface BVH must all follow a drag step. It is a property of
/// the PUBLISHER: `Mesh.publishConfinedChange` says "the vertices I moved are
/// the ones the tool is already handing to its consumers as an exclusion set".
/// See `ChangeBus.deliveryIsConfined` for why that rides beside the word.
///
/// WHO MAY KEY ON IT, AND THE OBLIGATION THAT COMES WITH IT. Only a consumer
/// that can state, at its own reader, why a confined change cannot reach its
/// answer:
///
///   * `snap.queryCandidateGrid` — an element is dropped at query time iff ANY
///     of its incident verts is in `excludeVerts`, so "moves with the drag"
///     and "excluded" are the same predicate (snap.d, 'EXCLUDE IS QUERY-TIME,
///     NOT KEY'). It carries a SECOND term for the case that argument does not
///     cover: the exclusion set itself, so a query that excludes something
///     ELSE cannot be served from those buckets.
///   * `SymmetryStage.evaluate` — a drag under an ENABLED symmetry stage
///     applies the mirror, so the mesh stays symmetric and the pair table at
///     step 20 is the table computed at step 1.
///
/// A consumer that cannot make such a statement keys on `g_geomEpochs`, and
/// that is the default. The failure mode of getting this wrong is INVISIBLE
/// to every value assertion — a cache keyed too narrowly is stale, one keyed
/// too widely is merely slow, and both return the same numbers on the fixture
/// that would notice. Both directions are therefore pinned by rates:
/// `snap.g_snapGridBuilds` and
/// `toolpipe.stages.symmetry.g_symPairingRebuilds`, over
/// `/api/cache/rebuilds`.
///
/// THE RE-ARM. Confined changes must not accumulate forever, or a table built
/// before a gesture outlives the geometry it describes. `TransformTool
/// .recordCommit` — the one chokepoint every transform `commitEdit` override
/// routes through — publishes an UNCONFINED `Position` when a gesture's edit
/// is recorded, so this watcher advances exactly once per committed gesture.
/// A cancelled gesture already does it (`cancelOpenSessionGeometry` ends in
/// `commitChange(Position)`).
__gshared MeshDirtyEpochs g_settledGeomEpochs =
    MeshDirtyEpochs.forClasses(GeomEpochMask);

// TASK 1906 STAGE 2d — THERE IS NO ANY-CLASS WATCHER, AND THE REASONING THAT
// BRIEFLY ADDED ONE IS RECORDED HERE BECAUSE IT IS PLAUSIBLE AND WRONG.
//
// The subpatch preview was keyed on `Mesh.mutationVersion`, and the argument
// ran: `commitChange` bumps that counter for EVERY class, so a watcher with a
// mask of `uint.max` is not a widening — it is the invalidation set the cache
// already had, plus the version-silent gizmo path the counter cannot see.
//
// The premise is false. Not every class bump goes through `commitChange`:
//   * `Mesh.noteSelectionChange` — the funnel under every marks setter — ORs
//     in `Marks` and deliberately bumps NO version (its own unittest asserts
//     that it must not);
//   * `Mesh.noteChange(Visibility)` on the hide path, and `app.d`'s
//     `noteChange(MeshChangeAll)`, are version-silent the same way.
// All three reach a per-mesh epoch — since stage 3 through the DELIVERY the
// writer itself makes (`Mesh.deliverPending`), where stage 2 reached it through
// `app.d`'s per-layer feed at the frame drain. Either way an any-class epoch
// invalidates on a plain SELECTION CLICK, which the counter never did.
// MEASURED: six version-silent `selectVertex` calls with a live preview left
// the cage's `mutationVersion` at 13 and moved the preview's work counter
// 1 -> 7 — an OSD stencil evaluate plus the VBO fan-out per picking frame,
// where the cost had been zero.
//
// The preview therefore keys on `g_geomEpochs` (which carries the gizmo's
// version-silent `Position`) AND on `mutationVersion` (which carries `Marks`
// for Tab and `Material` for a crease weight, neither of which is in the
// geometry mask). Two complementary terms, both required to hit; see
// `SubpatchPreview.sourceKey`, whose terms they are.

/// CONNECTIVITY classes only — `Points | Polygons`, i.e. `MeshEditScope
/// .Geometry` with `Position` deliberately EXCLUDED (task 1906 stage 2d, plan
/// §3.4 rows 14 and 15).
///
/// Consumers: `FalloffStage`'s selection-weight buffer and
/// `ActionCenterStage`'s Local-mode cluster partition. They share one watcher
/// because they are the same KIND of cache — a stage-owned derived structure
/// that is a function of adjacency and of the selected set, and of nothing
/// else. Both keep a `selectionSignature()` term, which is how the selected
/// set reaches their keys exactly rather than through a change class.
///
/// THE EXCLUSION IS THE ENTIRE POINT OF THE WATCHER EXISTING. Neither cache
/// depends on where the vertices ARE: `ActionCenterStage` recomputes cluster
/// CENTRES from live positions on every call regardless, and
/// `recomputeSelectionWeights` states its own position-independence and calls
/// a kernel that takes no coordinates. Keyed on `g_geomEpochs`, which carries
/// `Position` for the display, BVH and subpatch-preview families, both O(V+E)
/// walks would re-run on every step of every gizmo drag. That is a
/// regression, not parity: `mutationVersion` is version-silent through a drag,
/// so both caches survive one intact today.
///
/// A wrong (wider) mask here leaves every VALUE both stages produce correct
/// and moves only a count, so it is pinned by two rates rather than by a value:
/// `toolpipe.stages.actcenter.g_acenClusterRebuilds` and
/// `toolpipe.stages.falloff.g_falloffSelWeightRebuilds`.
__gshared MeshDirtyEpochs g_topoEpochs =
    MeshDirtyEpochs.forClasses(TopoEpochMask);

/// The single fan-in the change-bus listener calls. Registered ONCE, from
/// `app.d`'s existing mesh-channel hub, so there is exactly one subscription
/// to lose: if it goes, the hub's own `meshChangedFlags` goes with it and the
/// viewport stops updating loudly rather than quietly.
///
/// Callable directly, and that is deliberate — it is the listener BODY, the
/// same arrangement `snap.invalidateSnapGrids()` has: a headless unit test
/// with no `app.d` and no `Document` (and therefore no delivery at all, see
/// `Mesh.deliverPending`'s subject filter) drives it by hand.
/// COST, stated because stage 2d added a watcher. `note()` is a linear scan of
/// `kSlots` per watcher — a hit scans to the slot, a miss scans all 32 twice
/// (once for the address, once for a free slot) before evicting. With three
/// watchers a delivery is therefore up to 6 x 32 = 192 word compares, and
/// there is ONE delivery per edit boundary since stage 3 retired the frame
/// drain and its second feed. That is the price of not widening
/// an existing watcher's mask: `g_geomEpochs` carries the surface BVH and
/// every snap grid, so folding a selection click into it would trade these
/// compares for O(V+T) rebuilds.
void noteMeshChange(size_t subjectAddr, uint flags) nothrow @nogc {
    g_displayEpochs.note(subjectAddr, flags);
    g_geomEpochs.note(subjectAddr, flags);
    g_topoEpochs.note(subjectAddr, flags);
    // The fourth watcher is the same classes with the live-gesture deliveries
    // withheld (task 2000). Read the publisher's claim HERE, at the one fan-in,
    // rather than giving `MeshDirtyEpochs` a second dimension: the marker is a
    // property of the delivery in flight, not of the table.
    //
    // A unit test that drives this listener BY HAND (there are several below,
    // and in snap.d / actcenter.d / falloff.d) has no live gesture, so it
    // advances both geometry watchers together — which is what those tests
    // mean.
    if (!changeBus.deliveryIsConfined())
        g_settledGeomEpochs.note(subjectAddr, flags);
}

// ---------------------------------------------------------------------------
// THE ABA CLOSE (task 1906 stage 3).
// ---------------------------------------------------------------------------
//
// The hazard, stated as the sequence that produces it: a consumer stamps
// `{A, e}`; the `Layer` whose mesh lives at address A is collected; a NEW
// `Layer` is allocated and its mesh lands at the SAME address A; it publishes
// nothing, so `epochFor(A)` still reads `e`, `matches` is true and the consumer
// serves the previous mesh's cache for the new one.
//
// WHY THE IDENTITY LIVES ON `Layer` AND NOT ON `Mesh`, which is the question
// the plan left open. A `ulong` on `Mesh` is copied by every wholesale
// `*mesh = …` kernel (~15 of them) and written by `MeshSnapshot.restore`, so a
// layer would silently inherit a scratch mesh's identity — or its own past
// one — and an undo would RESTORE an identity, which is the one thing an
// identity must never do. `Layer` is a class with a stable heap address, the
// property the whole document model already leans on; its id cannot be copied
// by a struct assignment, cannot be captured by a snapshot, and is exactly the
// object whose reuse of an address IS the hazard.
//
// WHY THE EPOCH IS THE SIGNAL rather than a new term in `MeshDirtyKey`. Every
// address-keyed consumer in the tree already compares an epoch for its
// address — the two raw-address maps (`ConstrainStage._bgBvh`,
// `item_pick._bvh`) hold `BvhPick` objects whose own `_surfKey` is one of these
// keys. Advancing the epoch on a changed birth therefore reaches all of them
// through the compare they already make, with no new term to thread through
// ten stamp sites and no site left to forget.
//
// COST OF THE FAIL-SAFE ARM, measured (stage-3 review round 2): the unit
// binary constructs a Layer at ~248 sites, so the full-table arm fires 1 551+
// times per `dub test --config=tests`, each a `noteMeshChange(addr, uint.max)`
// against all three watchers (and a bump of their `evicted_`). Deterministic
// per build and green at 278 modules — but any exact rebuild-COUNT assertion
// (`g_acenClusterRebuilds`, `g_falloffSelWeightRebuilds`, the preview count)
// is sensitive to how many layers earlier modules built. If a count test ever
// moves for no reason of its own, the remedy is a test-only reset seam here,
// not a wider ceiling.
private struct MeshBirthTable {
    private enum int kSlots = 32;   // one per layer, same ceiling as a watcher
    private size_t[kSlots] addr_;
    private ulong[kSlots]  birth_;
    private int            next_;
    // TASK 1932 (stage 4) — a flat, NON-saturating count of every `observe()`
    // call this table has served, hit/miss/evict alike. This is a DENOMINATOR
    // for a caller sizing a sweep (how many births has the process already
    // spent, before mine), not a price: the card's "don't measure the number
    // of `observe()` calls" ban is about the COST of eviction (a rebuild
    // rate), which this counter does not claim to be. It must not saturate at
    // `kSlots`, unlike the table itself — the slot-fill level past the
    // ceiling is `max(0, totalObserved_ - kSlots)`, and a counter that
    // stopped at `kSlots` could not compute that.
    private ulong totalObserved_;

    /// Returns true when the address may now be occupied by a DIFFERENT birth
    /// than the one it last held. "Held none" WITH A FREE SLOT is the ordinary
    /// first-use case and answers false — a fresh address has no stamp against
    /// it to invalidate. "Held none" on a FULL table answers true, because a
    /// full table cannot tell first use from a record it has already evicted;
    /// see the eviction arm below.
    bool observe(size_t a, ulong birth) nothrow @nogc {
        ++totalObserved_;
        foreach (i; 0 .. kSlots) {
            if (addr_[i] == a) {
                const bool changed = birth_[i] != birth;
                birth_[i] = birth;
                return changed;
            }
        }
        foreach (i; 0 .. kSlots) {
            if (addr_[i] == 0) { addr_[i] = a; birth_[i] = birth; return false; }
        }
        // FULL ⇒ THE ANSWER IS "ASSUME A DIFFERENT OCCUPANT", NOT "FIRST USE"
        // (review of stage 3, M3). Reaching here means the table has evicted,
        // or is about to, and an evicted address LOSES its record: the next
        // `observe` for it finds nothing and — if this path answered `false`,
        // as it first did — advanced no epoch. That is UNDER-invalidation, the
        // one direction the whole `mesh_dirty` design refuses, and it is
        // SILENT: a consumer stamped against the previous occupant keeps
        // matching and serves the collected layer's cache for the new one.
        //
        // The cell: 33 births at 33 distinct addresses, then a re-birth at
        // address #1 with a different id. Under `false` the stamp still
        // matches; under `true` it misses. (The unit block below drives it.)
        //
        // The price of `true` is ONE spurious epoch advance per `new Layer()`
        // once a document is past `kSlots` layers — over-invalidation, bounded
        // by the layer-construction rate, and the same direction
        // `MeshDirtyEpochs.evicted_` already takes for exactly this reason. A
        // document that never fills the table pays nothing: this path is not
        // reached at all while a free slot exists, so the ordinary first-use
        // case above still answers `false`.
        const int i = next_;
        next_ = (next_ + 1) % kSlots;
        addr_[i]  = a;
        birth_[i] = birth;
        return true;
    }

    /// Test seam: what birth this table last recorded for `a` (0 = none).
    ulong birthAt(size_t a) const nothrow @nogc {
        foreach (i; 0 .. kSlots) if (addr_[i] == a) return birth_[i];
        return 0;
    }

    /// Test seam: the flat, non-saturating count — see the field's own note.
    ulong totalObserved() const nothrow @nogc { return totalObserved_; }

    /// Test-only reset, paired with `MeshDirtyEpochs.reset()` below.
    void reset() nothrow @nogc {
        addr_[]  = 0;
        birth_[] = 0;
        next_    = 0;
        totalObserved_ = 0;
    }
}

private __gshared MeshBirthTable g_births;

/// Called from `Layer`'s constructor with the address of that layer's mesh and
/// the layer's own monotone birth id. Advances every watcher for the address
/// when the occupant changed.
void noteMeshBirth(size_t meshAddr, ulong birthId) nothrow @nogc {
    if (meshAddr == 0) return;
    if (g_births.observe(meshAddr, birthId))
        noteMeshChange(meshAddr, uint.max);
}

/// Test seam — see `MeshBirthTable.birthAt`.
ulong notedBirthAt(size_t meshAddr) nothrow @nogc {
    return g_births.birthAt(meshAddr);
}

// ---------------------------------------------------------------------------
// TASK 1932 (stage 4) — THE SLOT-CEILING CLIFF IS A CHAIN OF TWO TABLES, NOT
// ONE. `MeshDirtyEpochs.kSlots` (`D`, above) and `MeshBirthTable.kSlots`
// (`B`, this module) are two INDEPENDENT `private enum`s that happen to share
// the literal 32 today — nothing enforces that they stay equal, and this
// task's own review caught a stand that assumed they always would (a mode-A
// cliff written as `2*D` instead of `B + D`, invisible while `B == D`). Both
// accessors below exist so a caller — in particular a suite-tier stand that
// cannot see either `private enum` (it links no `source/` module at all,
// see `tests/test_bus_delivery_granularity.d`'s own header) — reads the REAL
// ceilings rather than hard-coding 32 a second time.
// ---------------------------------------------------------------------------

/// `D` — the ceiling that owns the CLIFF (mode B: `D + 1`; mode A, chained
/// through the birth table: `B + D + 1`). See the module header's eviction
/// paragraph.
int meshDirtySlotCeiling() nothrow @nogc { return MeshDirtyEpochs.kSlots; }

/// `B` — the birth table's own ceiling, read ONLY so mode-A's formula
/// (`B + D + 1`) does not have to assume it equals `D`. A caller does not
/// otherwise need this number: `B` is not itself a delivery ceiling, it is
/// the first link in the chain that produces one.
int meshBirthSlotCeiling() nothrow @nogc { return MeshBirthTable.kSlots; }

/// The birth table's flat, non-saturating observe() count — see
/// `MeshBirthTable.totalObserved_`'s own note for why it must not saturate.
ulong meshBirthsRecorded() nothrow @nogc { return g_births.totalObserved(); }

/// Test-only: every table this module owns goes back to its construction-time
/// state, so a unit-tier sweep over N can start from a known baseline in one
/// process instead of needing a fresh one per N (`source/mesh_dirty.d`'s own
/// header, the "COST OF THE FAIL-SAFE ARM" paragraph, already names this seam
/// as the remedy for a count that drifts with how many layers earlier test
/// modules built). `g_births` and EVERY `__gshared` watcher this module
/// declares reset — the body sweeps `allWatchers()` rather than naming them,
/// because a hand-written list is a seam a NEW watcher joins silently: task
/// 2000 adds a fourth (`g_settledGeomEpochs`) in a parallel lane, and a
/// three-way merge of a hand-list is textually clean while leaving the reset
/// incomplete and this comment false. The census cell in
/// `tests/unit/mesh_dirty_cliff_series_test.d` refuses a declared watcher that
/// `allWatchers()` does not carry.
/// nothing else in the process is touched — the app-level `/api/reset` this
/// pairs with resets DOCUMENT state, not this module's, and the two are
/// deliberately orthogonal (see `http_server.d`'s reset caveat).
/// Every `__gshared MeshDirtyEpochs` this module declares, in ONE place, so
/// anything that must act on all of them (the test reset seam; a future
/// census) cannot fall behind a newly added watcher.
MeshDirtyEpochs*[] allWatchers() nothrow @nogc {
    static MeshDirtyEpochs*[4] tbl;
    tbl = [&g_displayEpochs, &g_geomEpochs, &g_topoEpochs, &g_settledGeomEpochs];
    return tbl[];
}

void resetMeshDirtyStateForTest() nothrow @nogc {
    g_births.reset();
    foreach (w; allWatchers()) w.reset();
}

// TASK 1932 (stage 4) — THE INSTRUMENT: one plain counter, bumped at the ONE
// background-layer GPU re-upload site (`source/ui/viewport_render.d`, where
// `bg.gpu.upload(*bm)` runs), so a suite-tier stand can read a DELTA the same
// way it already reads `changeBus`'s own counters — "scalar, monotone, read
// as deltas across a step" (`http_server.d`'s route_apiChanges comment).
//
// STANDS ON `g_displayEpochs`, NOT `g_geomEpochs` — say so here, once, so a
// reader of the suite stand does not have to infer it from the call site.
// The card that asked for this asked for the rate against `g_geomEpochs` (the
// GEOMETRY consumer); the one site that actually re-uploads a background
// mesh keys its cache on `g_displayEpochs.epochFor(...)` (`viewport_render.d`,
// a few lines above the bump). The two watchers share the SAME cliff — the
// birth path that produces it calls `noteMeshChange(addr, uint.max)`, and
// `uint.max` passes every watcher's class mask (`note()`, above) — so a
// measurement on this counter is valid for "where the cliff is", but it is
// NOT a measurement of the geometry consumer specifically (BVH rebuilds,
// snap grids); that remains unmeasured — a deliberate non-goal, not an
// oversight (see the card's "what this lane does not do").
//
// Deliberately NOT reset by `resetMeshDirtyStateForTest()` above: it is an
// INSTRUMENT counter in the same family as the bus's own (`deliveryCount`,
// `flushCount`, …), which persist across `/api/reset` by the same convention
// — "the runner resets app state, not the bus, between test binaries"
// (`http_server.d`). Resetting it here would give it a different reset
// contract than every counter beside it on `/api/changes`, for no reason a
// caller could rely on.
__gshared ulong g_bgGpuUploads;

// ---------------------------------------------------------------------------
// THE ABA CELL (task 1906 stage 3). Address reuse is FORCED, not hoped for.
//
// The GC cannot be asked to place a new `Layer` at a collected one's address,
// so a cell that allocated two layers and waited would be measuring the
// allocator, not the law. What the law actually says is per-address and
// birth-keyed, so the cell states it that way: the same address, two births,
// and a key stamped against the first.
//
// Mutation this is the red for: delete the `noteMeshChange(meshAddr, uint.max)`
// line from `noteMeshBirth`. Then the second birth advances nothing, the stamp
// still matches, and the first assert below reddens in those words.
// ---------------------------------------------------------------------------
unittest {
    // An address no other cell in this module uses (they take 0x1000/0x2000).
    enum size_t A = 0x00ABA000;

    noteMeshBirth(A, 101);                       // layer #101's mesh lands at A
    noteMeshChange(A, MeshEditScope.Position);   // it publishes; a consumer stamps
    MeshDirtyKey k;
    k.stamp(A, g_geomEpochs.epochFor(A));
    assert(k.matches(A, g_geomEpochs.epochFor(A)),
        "PREMISE: a stamp taken right after a change must read fresh — without "
      ~ "this the cell below could pass on a key that never matched at all");

    // #101 is collected; layer #102 is allocated into the SAME block and
    // publishes NOTHING. Before stage 3 the consumer served #101's cache to
    // #102: same address, same epoch, `matches` true.
    noteMeshBirth(A, 102);
    assert(!k.matches(A, g_geomEpochs.epochFor(A)),
        "ABA: a DIFFERENT mesh now occupies address A and published nothing, "
      ~ "yet the key stamped against its predecessor still matched — the "
      ~ "consumer would serve the collected layer's cache");

    // The other half, and it is what stops the fix from being "invalidate on
    // every construction": re-observing the SAME birth must move nothing, or a
    // document that merely re-registers its layers would drop every cache.
    MeshDirtyKey k2;
    k2.stamp(A, g_geomEpochs.epochFor(A));
    noteMeshBirth(A, 102);
    assert(k2.matches(A, g_geomEpochs.epochFor(A)),
        "the SAME birth at the same address is not a change and must not "
      ~ "advance an epoch");
    assert(notedBirthAt(A) == 102, "the table records the current occupant");
}

// ---------------------------------------------------------------------------
// THE ABA CELL, PAST THE TABLE'S CEILING (review of stage 3, M3).
//
// The block above proves the close works while the birth table still holds a
// record for the address. This one proves it survives EVICTION, which is the
// case the first cut got wrong: a row per `new Layer()`, never freed, and once
// 32 addresses have been seen the round-robin cursor drops one on every
// insert. An evicted address's next birth used to read as first-use and
// advance nothing — under-invalidation, and silent.
//
// It is a separate block from the one above because the two need DIFFERENT
// table states (below the ceiling, past it) and the table is process-global:
// running them in one block would make the second depend on how many slots the
// first happened to leave.
//
// Mutation this is the red for: change `return true;` back to `return false;`
// on `MeshBirthTable.observe`'s eviction arm. Then the re-birth at `A1`
// advances nothing, the stamp still matches, and the second assert reddens in
// those words. (The FIRST assert is the anti-vacuity arm: it says the eviction
// actually happened, so a green second assert cannot be "the table never
// filled".)
// ---------------------------------------------------------------------------
unittest {
    // Addresses no other cell in this module uses.
    enum size_t A1     = 0x00E0_0000;
    enum size_t kChurn = 0x00E1_0000;

    // 1. The layer whose mesh lives at A1 is seated.
    noteMeshBirth(A1, 1000);

    // 2. Enough OTHER layers to guarantee A1's record is gone, whatever state
    //    the shared table was in when this block started: 2 * kSlots inserts
    //    fill the table and then overwrite every slot once through the
    //    round-robin cursor. (A bare `kSlots + 1` would evict SOMETHING, not
    //    necessarily A1 — the cursor's phase is not this block's to know.)
    foreach (i; 0 .. 2 * MeshBirthTable.kSlots)
        noteMeshBirth(kChurn + i * 0x40, 2000 + i);
    assert(notedBirthAt(A1) == 0,
        "PREMISE: A1's birth record must have been EVICTED — without that this "
      ~ "cell exercises the in-table path the block above already covers, and "
      ~ "its verdict below would be free");

    // 3. A consumer stamps against A1's CURRENT occupant, AFTER the churn (the
    //    churn moves untracked addresses' epochs through `evicted_`, so a
    //    stamp taken before it would miss for the wrong reason).
    MeshDirtyKey k;
    k.stamp(A1, g_geomEpochs.epochFor(A1));
    assert(k.matches(A1, g_geomEpochs.epochFor(A1)),
        "PREMISE: a stamp just taken must read fresh");

    // 4. That layer is collected and a NEW one lands at the same address,
    //    publishing nothing. The table holds no record for A1, so it cannot
    //    prove the occupant is unchanged — and must not pretend it can.
    noteMeshBirth(A1, 9001);
    assert(!k.matches(A1, g_geomEpochs.epochFor(A1)),
        "ABA PAST THE CEILING: the birth table had EVICTED this address, so a "
      ~ "re-birth there read as first use and advanced no epoch — the key "
      ~ "stamped against the collected layer still matched and the consumer "
      ~ "would serve its cache to the new one. An evicted record must "
      ~ "over-invalidate, never under-invalidate");
}

// ---------------------------------------------------------------------------
// Unit tests — the three properties the consumers depend on.
// ---------------------------------------------------------------------------
unittest {
    // Per-address exactness: a change to A must not move B's epoch.
    auto w = MeshDirtyEpochs.forClasses(MeshEditScope.Position);
    const size_t A = 0x1000, B = 0x2000;
    const ulong a0 = w.epochFor(A), b0 = w.epochFor(B);
    w.note(A, MeshEditScope.Position);
    assert(w.epochFor(A) != a0, "A's epoch must advance on A's change");
    assert(w.epochFor(B) == b0,
        "B HAS NOT CHANGED, so its epoch must not move — this is the property "
      ~ "that keeps a static background mesh's BVH from being rebuilt every "
      ~ "time the primary is edited (see the module header)");
    const ulong a1 = w.epochFor(A), b1 = w.epochFor(B);
    w.note(B, MeshEditScope.Position);
    assert(w.epochFor(A) == a1, "A's epoch must NOT move when B changes");
    assert(w.epochFor(B) != b1, "B's epoch must advance on B's change");
}

unittest {
    // The class filter: a watcher ignores classes outside its mask.
    auto w = MeshDirtyEpochs.forClasses(MeshEditScope.Position);
    const size_t A = 0x1000;
    w.note(A, MeshEditScope.Position);
    const ulong a1 = w.epochFor(A);
    w.note(A, MeshEditScope.Marks);
    assert(w.epochFor(A) == a1,
        "a Marks-only change must not advance a Position watcher");
    w.note(A, MeshEditScope.Marks | MeshEditScope.Position);
    assert(w.epochFor(A) != a1, "a change that INCLUDES the class must advance");
}

unittest {
    // THE STAGE-2d WATCHERS DISAGREE, AND THAT DISAGREEMENT IS THE WHOLE
    // REASON MORE THAN ONE EXISTS. Driven through the real fan-in
    // (`noteMeshChange`) on the real `__gshared` instances, because a local
    // `forClasses(...)` pair would prove the struct works and say nothing
    // about how the module wired them up — deleting `g_topoEpochs.note(...)`
    // from `noteMeshChange` has to be visible here.
    //
    // The address is unique to this block and never a real `Mesh*`: the table
    // is process-global and neighbouring unit blocks write it too.
    const size_t A = 0xB0_1906_2D;
    const ulong geomBefore = g_geomEpochs.epochFor(A);
    const ulong topoBefore = g_topoEpochs.epochFor(A);
    const ulong dispBefore = g_displayEpochs.epochFor(A);

    noteMeshChange(A, MeshEditScope.Position);
    assert(g_geomEpochs.epochFor(A) != geomBefore,
        "a Position-only publish MUST advance the geometry epoch — that is "
      ~ "the version-silent gizmo path `mutationVersion` cannot see, and the "
      ~ "surface BVH, the snap grids and the subpatch preview's staleness key "
      ~ "all ride on it");
    assert(g_topoEpochs.epochFor(A) == topoBefore,
        "a Position-only publish must NOT advance the connectivity epoch. If "
      ~ "it does, BOTH its consumers' O(V+E) walks re-run on every step of "
      ~ "every gizmo drag — ActionCenterStage's cluster MEMBERSHIP and "
      ~ "FalloffStage's selection-weight bake, neither of which reads a vertex "
      ~ "position. That is the regression this watcher's narrow mask exists to "
      ~ "refuse, and it is invisible to every value assertion in either stage");

    const ulong geomMid = g_geomEpochs.epochFor(A);
    noteMeshChange(A, MeshEditScope.Polygons);
    assert(g_topoEpochs.epochFor(A) != topoBefore,
        "a Polygons publish MUST advance the connectivity epoch");
    assert(g_geomEpochs.epochFor(A) != geomMid,
        "and the geometry epoch advances on a connectivity class too — its "
      ~ "mask is Position | Points | Polygons, not Position alone");

    // MARKS AND MATERIAL ARE THE TWO CLASSES NO EPOCH HERE CARRIES FOR THE
    // SUBPATCH PREVIEW, and that is deliberate: Tab writes `Marks` and a
    // crease weight writes `Material`, both through `commitChange`, so the
    // preview's SECOND key term (`mutationVersion`) is what sees them. If this
    // block ever showed `g_geomEpochs` advancing on either, the preview would
    // be back to rebuilding on every selection click.
    const ulong geomMarks = g_geomEpochs.epochFor(A);
    noteMeshChange(A, MeshEditScope.Marks);
    assert(g_geomEpochs.epochFor(A) == geomMarks,
        "a Marks-only publish (a selection click) must NOT advance the "
      ~ "geometry epoch — that widening is the review finding stage 2d was "
      ~ "landed on, measured at 6 extra subpatch-preview evaluations over 6 "
      ~ "version-silent selectVertex calls");
    const ulong dispMat = g_displayEpochs.epochFor(A);
    noteMeshChange(A, MeshEditScope.Material);
    assert(g_displayEpochs.epochFor(A) != dispMat,
        "a Material publish (what Mesh.setCreaseWeight commits) must advance "
      ~ "the DISPLAY epoch — `Material` is in DisplayRefreshMask, and this is "
      ~ "the anti-vacuity arm for the assert above: the fan-in is alive and "
      ~ "`g_geomEpochs` held still because of its mask, not because nothing "
      ~ "was delivered");
    assert(g_displayEpochs.epochFor(A) != dispBefore,
        "trace: the display watcher moved at some point in this block");
}

unittest {
    // Eviction and the wildcard both over-invalidate, never under-invalidate.
    // This is the property the whole fixed-size design rests on.
    auto w = MeshDirtyEpochs.forClasses(MeshEditScope.Position);
    const size_t A = 0x1000;
    w.note(A, MeshEditScope.Position);
    const ulong a1 = w.epochFor(A);

    // kSlots more distinct addresses: A is evicted from a kSlots-slot table.
    foreach (i; 1 .. MeshDirtyEpochs.kSlots + 2)
        w.note(0x2000 + i * 0x100, MeshEditScope.Position);
    assert(w.epochFor(A) != a1,
        "an EVICTED address must read as changed (it falls back to `evicted_`), "
      ~ "never as still-fresh");

    // The subject-less aggregate is IGNORED, and since stage 3 nothing
    // produces one: `ChangeBus.flush` no longer carries the mesh channel at
    // all, so every delivery reaching here names a real subject. The refusal
    // stays as a guard — see the header.
    auto w2 = MeshDirtyEpochs.forClasses(MeshEditScope.Position);
    w2.note(A, MeshEditScope.Position);
    const ulong a2 = w2.epochFor(A);
    w2.note(0, MeshEditScope.Position);
    assert(w2.epochFor(A) == a2,
        "a subject-less (addr 0) delivery must move nothing — accepting it "
      ~ "would invalidate every address once per changed frame");
}

unittest {
    // THE EVICTION CLIFF, BOTH SIDES OF IT — the cell that says what `kSlots`
    // buys. It is a discriminating pair on purpose: the "stays fresh" half
    // alone is satisfied by any table big enough, and would still pass if
    // `kSlots` were lowered to a number that over-invalidates in practice.
    // Only the second half says where the edge actually is.
    //
    // A NOTE ON WHAT "SPURIOUS" COSTS: every differing read here is a full
    // O(V+T) surface-BVH (or GPU-buffer) rebuild for a mesh that nobody
    // touched — the exact regression the header's "a miss must not mean
    // changed" paragraph refuses, arriving by the other door.
    static int spuriousRounds(int churners) {
        auto w = MeshDirtyEpochs.forClasses(MeshEditScope.Position);
        const size_t STATIC = 0xDEAD_0000;   // never noted: a background mesh
        size_t[] addrs;
        foreach (i; 0 .. churners) addrs ~= 0x3_0000 + i * 0x1000;
        foreach (a; addrs) w.note(a, MeshEditScope.Position);
        ulong prev = w.epochFor(STATIC);
        int spurious = 0;
        foreach (round; 0 .. 20) {
            foreach (a; addrs) w.note(a, MeshEditScope.Position);
            const ulong cur = w.epochFor(STATIC);
            if (cur != prev) ++spurious;
            prev = cur;
        }
        return spurious;
    }

    enum int K = MeshDirtyEpochs.kSlots;
    assert(spuriousRounds(K - 1) == 0,
        "with kSlots-1 churning addresses a NEVER-CHANGED address must read "
      ~ "the same epoch every round — a background layer's BVH must not be "
      ~ "rebuilt because OTHER layers are being edited");
    assert(spuriousRounds(K) == 0,
        "at exactly kSlots churners the table is full but nothing is evicted, "
      ~ "so the untouched address is still undisturbed");
    assert(spuriousRounds(K + 1) == 20,
        "AND THIS IS THE CLIFF, stated so nobody has to rediscover it: ONE "
      ~ "address past kSlots and the round-robin cursor evicts on every "
      ~ "insert, `evicted_` moves with it, and the never-changed address reads "
      ~ "as dirty in ALL 20 rounds. Not a slope — a step. If this number is "
      ~ "ever not 20, the eviction policy changed and the header's ceiling "
      ~ "argument needs re-deriving, not this assert relaxing");
}

unittest {
    // MeshDirtyKey: a default key never matches, and the ADDRESS term is
    // load-bearing on its own — same epoch, different mesh ⇒ rebuild.
    MeshDirtyKey k;
    assert(!k.matches(0x1000, 0), "a fresh key must not match anything");
    k.stamp(0x1000, 7);
    assert(k.matches(0x1000, 7));
    assert(!k.matches(0x2000, 7), "a different mesh at the same epoch must miss");
    assert(!k.matches(0x1000, 8));
}

// ---------------------------------------------------------------------------
// TASK 2000 — THE SETTLED WATCHER'S WHOLE SEMANTICS, IN ONE DISCRIMINATING
// PAIR.
//
// Both halves are required and neither is redundant:
//
//   * an UNCONFINED change must advance BOTH geometry watchers. Without this
//     half, a `g_settledGeomEpochs` that never advanced at all would satisfy
//     the second half perfectly — and every cache keyed on it would be frozen
//     for the life of the process.
//   * a CONFINED change must advance `g_geomEpochs` and NOT
//     `g_settledGeomEpochs`. The first clause is what says the narrowing is
//     the SETTLED watcher's alone: the display, the GPU upload and the surface
//     BVH still follow a drag step, and a marker that quietly suppressed the
//     wide watcher too would stop the viewport updating.
//
// Drives the listener body by hand, like the blocks above: a unit test has no
// `Document`, so nothing here would deliver on its own.
// ---------------------------------------------------------------------------
unittest {
    // An address no other block in this module names, so the two reads below
    // cannot be moved by a neighbour's `note`.
    enum size_t A = 0x2000_0000;

    const ulong g0 = g_geomEpochs.epochFor(A);
    const ulong s0 = g_settledGeomEpochs.epochFor(A);
    noteMeshChange(A, MeshEditScope.Position);
    assert(g_geomEpochs.epochFor(A) != g0,
        "an ordinary Position change must advance the geometry watcher");
    assert(g_settledGeomEpochs.epochFor(A) != s0,
        "an UNCONFINED Position change must advance the SETTLED watcher too — "
      ~ "a watcher that never advances is not a narrower key, it is a frozen "
      ~ "one, and every cache keyed on it would serve a pre-session answer "
      ~ "for the life of the process");

    const ulong g1 = g_geomEpochs.epochFor(A);
    const ulong s1 = g_settledGeomEpochs.epochFor(A);
    changeBus.beginConfinedDelivery();
    noteMeshChange(A, MeshEditScope.Position);
    changeBus.endConfinedDelivery();
    assert(g_geomEpochs.epochFor(A) != g1,
        "a CONFINED change is still a real geometry change: `g_geomEpochs` "
      ~ "carries the display, the GPU cage upload and the surface BVH, and "
      ~ "every one of them must follow a gizmo drag step. If this line ever "
      ~ "goes red the marker has leaked into the wide watcher and the "
      ~ "viewport has stopped updating mid-drag");
    assert(g_settledGeomEpochs.epochFor(A) == s1,
        "a CONFINED change must NOT advance the SETTLED watcher — that "
      ~ "withholding is the whole of task 2000: it is what lets the snap "
      ~ "candidate grid and the symmetry pair table survive a gesture whose "
      ~ "every step publishes Position");

    // And the marker is a DEPTH, not a flag: closing an inner window must not
    // release an outer one.
    const ulong s2 = g_settledGeomEpochs.epochFor(A);
    changeBus.beginConfinedDelivery();
    {
        changeBus.beginConfinedDelivery();
        changeBus.endConfinedDelivery();
        noteMeshChange(A, MeshEditScope.Position);
    }
    changeBus.endConfinedDelivery();
    assert(g_settledGeomEpochs.epochFor(A) == s2,
        "the confined marker must nest: a closed INNER window left the outer "
      ~ "one's claim standing, and a bool would have dropped it here");
}
