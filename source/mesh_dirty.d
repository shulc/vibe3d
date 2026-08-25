module mesh_dirty;

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
// LAYER-COUNT CEILING, and it is set to 32 (512 bytes per watcher, two
// watchers) rather than to the number of layers anyone has today. The cliff is
// pinned by the eviction unit test below, which asserts both sides of it.
//
// WHAT THIS KEY CANNOT SEE: ADDRESS REUSE (ABA). A consumer stamps `{A, e}`;
// the `Layer` whose mesh lived at A is collected; a NEW `Layer` is allocated
// at the same address and publishes nothing before the consumer next asks.
// `matches(A, e)` is then true and the consumer keeps a cache built over a
// mesh that no longer exists. Exposed today: `ConstrainStage._bgBvh[size_t]`
// and `item_pick._bvh[size_t]`, both keyed by RAW ADDRESS; `BgGpu` is safe
// because its map is keyed by `Layer` IDENTITY, which the GC keeps alive.
// NOT FIXED, and deliberately: it is pre-existing IN KIND — `MeshCacheKey`'s
// `{addr, mutationVersion}` had exactly the same hole, and a fresh mesh starts
// at version 0 the same way it starts at epoch `evicted_` — and every normal
// layer-creation path (`layer.add`, `file.load`, `ai3d.importResult`) does
// publish. Closing it needs a monotone per-mesh birth id, which is a `Mesh`
// field and therefore stage 3's business, not this module's.
//
// THE SUBJECT IS ALWAYS KNOWN, so there is no wildcard. `ChangeBus.flush` —
// the per-frame drain, alive until stage 3 — delivers with `subjectAddr == 0`
// ("the union of every layer's pending classes, subject unknown"), and that
// delivery is IGNORED here. It is not lost: `app.d`'s flush block feeds this
// module per LAYER, from each layer's own `pendingChanges_`, at the top of the
// same block — where the subject IS known. Accepting the aggregate instead
// would poison every untracked address once per changed frame, which is the
// same regression the paragraph above refuses.
//
// MAIN THREAD ONLY, exactly like the bus it is fed from (plan §1.8): every
// delivery is main-thread by construction (mutating HTTP endpoints reach the
// mesh through `MainThreadBridge`), and every reader below is a main-thread
// consumer. `__gshared` rather than TLS for the same reason `ChangeBus` is:
// the HTTP thread must see the same object, not a zeroed copy of it.
// ---------------------------------------------------------------------------

import mesh_edit_delta : MeshEditScope;
import display_sync    : DisplayRefreshMask;

/// A watcher over ONE change-class group. Instances are module-level globals
/// below; a consumer never makes its own.
struct MeshDirtyEpochs {
    // A LAYER-COUNT CEILING, not a tuning knob — see the header's eviction
    // paragraph for the measurement. At `kSlots` churning addresses a
    // never-changed address is never disturbed; at `kSlots + 1` it is disturbed
    // on EVERY round, each one an O(V+T) rebuild of a cache nothing dirtied.
    // 32 slots cost 32*(8+8) = 512 bytes per watcher, two watchers, once — a
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

/// Display-relevant classes — what makes the GPU buffers wrong
/// (`display_sync.DisplayRefreshMask`, single-sourced, NOT re-listed here).
__gshared MeshDirtyEpochs g_displayEpochs =
    MeshDirtyEpochs.forClasses(DisplayRefreshMask);

/// Geometry-relevant classes — what makes a position-dependent derived
/// structure (a BVH, the cage VBO) wrong. Narrower than the display mask on
/// purpose: a material or map write moves no vertex.
__gshared MeshDirtyEpochs g_geomEpochs =
    MeshDirtyEpochs.forClasses(MeshEditScope.Position
                             | MeshEditScope.Points
                             | MeshEditScope.Polygons);

/// The single fan-in the change-bus listener calls. Registered ONCE, from
/// `app.d`'s existing mesh-channel hub, so there is exactly one subscription
/// to lose: if it goes, the hub's own `meshChangedFlags` goes with it and the
/// viewport stops updating loudly rather than quietly.
///
/// Callable directly, and that is deliberate — it is the listener BODY, the
/// same arrangement `snap.invalidateSnapGrids()` has: a headless unit test
/// with no `app.d` and no `Document` (and therefore no delivery at all, see
/// `Mesh.deliverPending`'s subject filter) drives it by hand.
void noteMeshChange(size_t subjectAddr, uint flags) nothrow @nogc {
    g_displayEpochs.note(subjectAddr, flags);
    g_geomEpochs.note(subjectAddr, flags);
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

    // The subject-less aggregate is IGNORED, and that is deliberate: app.d
    // feeds the same flags per layer, with the address, from the drain.
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
