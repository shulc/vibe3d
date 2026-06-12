module change_bus;

// ---------------------------------------------------------------------------
// Change-notification bus — Stage 0 core (no subscribers yet).
//
// One in-process publish-subscribe bus replacing per-consumer version polling
// and blanket per-frame cache invalidation. Mesh mutations accumulate
// change-class flags on the Mesh (pendingChanges_ / pendingSelDomains_); the
// main loop drains them once per frame into `changeBus.flush(...)`, which
// fans the flags out to registered subscriber delegates.
//
// The change-class vocabulary IS the existing `MeshEditScope` enum from
// mesh_edit_delta.d — re-exported here, NOT redefined. The selection-domain
// vocabulary mirrors `MeshOpEntry.SelDomain` (Vertex / Edge / Face), promoted
// here to a small bitfield so a single flush can carry several domains.
//
// MIT-clean naming: vibe3d-native infrastructure. No proprietary / SDK symbol
// names appear here — provenance lives in doc/ + agent memory.
//
// v1 constraints (per the plan): single-process, main-thread only, no locks,
// no unsubscribe (subscribers live for the app lifetime), no per-element
// payloads. Subscribers are invalidate-only by contract: they must NOT mutate
// the mesh or re-enter flush (enforced by the reentrancy guard below).
// ---------------------------------------------------------------------------

public import mesh_edit_delta : MeshEditScope;

// Selection-domain bitfield. Mirrors MeshOpEntry.SelDomain's three members
// (Vertex / Edge / Face) but as power-of-two flags so one flush can OR several
// domains together (e.g. a command that touches vertex AND face selection).
enum SelDomain : uint {
    None   = 0,
    Vertex = 1 << 0,
    Edge   = 1 << 1,
    Face   = 1 << 2,
}

// ---------------------------------------------------------------------------
// The bus. A plain struct with one module-level __gshared instance: the module
// import is the service locator (no singleton ceremony). All access is on the
// main thread, so the __gshared global needs no synchronisation.
// ---------------------------------------------------------------------------
struct ChangeBus {
    // Subscriber delegate arrays. Appended once at startup via the registration
    // helpers below; never removed in v1. flush() iterates these.
    void delegate(uint flags)[]   meshSubs;
    void delegate(uint domains)[] selSubs;

    // Reentrancy guard: a subscriber must not re-enter flush (nor mutate the
    // mesh, which could note new changes mid-delivery). The assert turns a
    // contract violation into a hard failure in debug builds rather than a
    // silent corruption.
    private bool flushing_;

    // --- Debug / test-introspectable counters -----------------------------
    // Plain fields so tests (and the future /api/changes endpoint) can read
    // them directly. Updated on every non-empty flush.
    ulong flushCount;        // number of flushes that actually delivered
    uint  lastFlushFlags;    // mesh flags of the most recent delivered flush
    uint  lastSelDomains;    // selection domains of the most recent delivery

    // Per-class running totals — how many flushes carried each mesh class.
    ulong totalPosition;
    ulong totalPoints;
    ulong totalPolygons;
    ulong totalMarks;
    ulong totalMaterial;

    // Per-domain running totals for selection.
    ulong totalSelVertex;
    ulong totalSelEdge;
    ulong totalSelFace;

    // --- Registration -----------------------------------------------------
    void onMeshChanged(void delegate(uint flags) dg) {
        if (dg !is null) meshSubs ~= dg;
    }

    void onSelectionChanged(void delegate(uint domains) dg) {
        if (dg !is null) selSubs ~= dg;
    }

    // --- Flush ------------------------------------------------------------
    // Deliver accumulated mesh flags + selection domains to subscribers. If
    // both are zero there is nothing to deliver, so return early (no counter
    // bump, no subscriber call). meshChanged delegates fire before selChanged
    // delegates (documented fixed order).
    void flush(uint meshFlags, uint selDomains) {
        if (meshFlags == 0 && selDomains == 0) return;

        assert(!flushing_,
            "change_bus: subscriber re-entered flush (subscribers are " ~
            "invalidate-only and must not mutate the mesh or re-flush)");
        flushing_ = true;
        scope (exit) flushing_ = false;

        ++flushCount;
        lastFlushFlags = meshFlags;
        lastSelDomains = selDomains;

        if (meshFlags & MeshEditScope.Position) ++totalPosition;
        if (meshFlags & MeshEditScope.Points)   ++totalPoints;
        if (meshFlags & MeshEditScope.Polygons) ++totalPolygons;
        if (meshFlags & MeshEditScope.Marks)    ++totalMarks;
        if (meshFlags & MeshEditScope.Material) ++totalMaterial;

        if (selDomains & SelDomain.Vertex) ++totalSelVertex;
        if (selDomains & SelDomain.Edge)   ++totalSelEdge;
        if (selDomains & SelDomain.Face)   ++totalSelFace;

        if (meshFlags != 0)
            foreach (dg; meshSubs) dg(meshFlags);
        if (selDomains != 0)
            foreach (dg; selSubs) dg(selDomains);
    }
}

// The one module-level instance. Main-thread access only (see header).
__gshared ChangeBus changeBus;

// ===========================================================================
// In-module unittests. Each is fully self-contained: it constructs its own
// local ChangeBus rather than touching the __gshared global, so tests do not
// leak counter/subscriber state into each other (lesson from the masked
// falloff unittest — keep samples hermetic).
// ===========================================================================

// Accumulate-coalesce: multiple noteChange-style ORs combine, and flush sees
// the union once.
unittest {
    // The OR-accumulate happens on the Mesh; here we just verify the bus
    // delivers a pre-combined flag word once with all bits set.
    ChangeBus bus;
    uint seen = 0;
    int  calls = 0;
    bus.onMeshChanged((uint f) { seen |= f; ++calls; });

    const combined = MeshEditScope.Position | MeshEditScope.Points
                   | MeshEditScope.Polygons;
    bus.flush(combined, 0);

    assert(calls == 1, "one delivery per flush");
    assert(seen == combined, "all coalesced bits delivered");
    assert(bus.flushCount == 1);
    assert(bus.lastFlushFlags == combined);
    assert(bus.totalPosition == 1 && bus.totalPoints == 1
        && bus.totalPolygons == 1);
}

// flush delivers once and (since pending state lives on the Mesh, not the bus)
// a subsequent zero-arg flush is a no-op that does not re-deliver.
unittest {
    ChangeBus bus;
    int calls = 0;
    bus.onMeshChanged((uint) { ++calls; });

    bus.flush(MeshEditScope.Marks, 0);
    assert(calls == 1);
    assert(bus.totalMarks == 1);

    // Second flush with nothing pending: no delivery.
    bus.flush(0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// flush with both args zero is a complete no-op: no counter bump, no call.
unittest {
    ChangeBus bus;
    int meshCalls = 0, selCalls = 0;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onSelectionChanged((uint) { ++selCalls; });

    bus.flush(0, 0);

    assert(meshCalls == 0 && selCalls == 0);
    assert(bus.flushCount == 0);
    assert(bus.lastFlushFlags == 0 && bus.lastSelDomains == 0);
}

// Selection domains are delivered to selSubs after meshSubs, with per-domain
// counters maintained.
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1;
    bus.onMeshChanged((uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex | SelDomain.Face);

    assert(meshSeen == MeshEditScope.Marks);
    assert(selSeen == (SelDomain.Vertex | SelDomain.Face));
    assert(meshOrder == 0 && selOrder == 1, "meshChanged fires before selChanged");
    assert(bus.totalSelVertex == 1 && bus.totalSelFace == 1);
    assert(bus.totalSelEdge == 0);
}

// Reentrancy: a subscriber that re-enters flush trips the guard assert.
unittest {
    import core.exception : AssertError;

    ChangeBus bus;
    bool tripped = false;
    bus.onMeshChanged((uint) {
        try {
            bus.flush(MeshEditScope.Position, 0); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(MeshEditScope.Marks, 0);
    assert(tripped, "re-entering flush from a subscriber must assert");
}
