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
import seltype : SelType;

// Manifest "everything changed" mask for bulk transitions (scene reset, file
// load, snapshot restore, playback start) where the whole mesh is replaced and
// every cache must invalidate. This is NOT a member of MeshEditScope — that
// enum is the change tracker's vocabulary and stays minimal; All is a bus-level
// convenience OR of the concrete classes. (Geometry already folds Points|
// Polygons, so this expands to Position|Points|Polygons|Marks|Material.)
enum uint MeshChangeAll =
      MeshEditScope.Position
    | MeshEditScope.Points
    | MeshEditScope.Polygons
    | MeshEditScope.Marks
    | MeshEditScope.Material;

// Selection-domain bitfield. Mirrors MeshOpEntry.SelDomain's three members
// (Vertex / Edge / Face) but as power-of-two flags so one flush can OR several
// domains together (e.g. a command that touches vertex AND face selection).
enum SelDomain : uint {
    None   = 0,
    Vertex = 1 << 0,
    Edge   = 1 << 1,
    Face   = 1 << 2,
    Item   = 1 << 3,   // item (layer) selection changed — the #4 Stage-2a domain
}

// Layer-change bitfield — the third bus channel (layerChanged(uint kinds)).
// Carries the kind(s) of LAYER-STRUCTURAL change a frame produced: layers
// appearing/disappearing, reordering, per-row attribute edits (name/visible/
// background) and the active(foreground)-layer switch. Like the mesh + sel
// channels it is an event bitfield with NO per-layer payload — a subscriber
// re-polls `document` / `/api/layers` for detail. Power-of-two members so a
// frame that performs several layer ops coalesces them into one delivery.
enum LayerChange : uint {
    None              = 0,
    Added             = 1 << 0,  // a layer appeared (add, or whole-list replace on load/import)
    Removed           = 1 << 1,  // a layer was deleted
    Reordered         = 1 << 2,  // layers[] order changed (reorder)
    Renamed           = 1 << 3,  // a layer's display name changed
    VisibilityChanged = 1 << 4,  // a layer's `visible` flag changed
    BackgroundChanged = 1 << 5,  // a layer's `background` flag changed
    ActiveChanged     = 1 << 6,  // the active (foreground) layer changed
}

// Whole-document replacement mask (load / multi-part import): the layer list is
// replaced wholesale AND the active layer changes. Mirrors MeshChangeAll's role
// for the layer channel. Rename/visibility/background are deliberately NOT in
// All — a freshly loaded document has a new list, it has not "renamed" a layer.
enum uint LayerChangeAll =
      LayerChange.Added | LayerChange.Removed | LayerChange.Reordered
    | LayerChange.ActiveChanged;

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
    void delegate(uint kinds)[]   layerSubs;
    // The current-type channel — the `Current(type)` analog the layer-change
    // (Stage-5) work deferred to selection-types #4. Carries the newly-current
    // SelType when the front of the recent-ordering flips. Delivered LAST, after
    // the mesh/sel/layer channels (see flush). Invalidate-only, no unsubscribe.
    void delegate(SelType t)[]    currentTypeSubs;

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
    uint  lastLayerKinds;    // layer-change kinds of the most recent delivery
    SelType lastCurrentType; // the type made current by the most recent delivery

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
    ulong totalSelItem;   // #4 Stage 2a: item (layer) selection deliveries

    // Per-kind running totals for layer-structural changes.
    ulong totalLayerAdded;
    ulong totalLayerRemoved;
    ulong totalLayerReordered;
    ulong totalLayerRenamed;
    ulong totalLayerVisible;
    ulong totalLayerBackground;
    ulong totalLayerActive;

    // Current-type channel total: how many flushes carried a current-type flip
    // (the `Current(type)` analog). Distinct from selectionChanged — a type
    // switch is NOT selection content, so this ticks while sel/mesh stay zero.
    ulong currentTypeChanged;

    // --- Registration -----------------------------------------------------
    void onMeshChanged(void delegate(uint flags) dg) {
        if (dg !is null) meshSubs ~= dg;
    }

    void onSelectionChanged(void delegate(uint domains) dg) {
        if (dg !is null) selSubs ~= dg;
    }

    // Register a layer-change subscriber. Like the other channels, subscribers
    // are invalidate-only (must NOT mutate the document or re-enter flush) and
    // live for the app lifetime (no unsubscribe in v1). Delivered LAST, after
    // meshChanged + selectionChanged (see flush).
    void onLayerChanged(void delegate(uint kinds) dg) {
        if (dg !is null) layerSubs ~= dg;
    }

    // Register a current-type subscriber. Fires when the front of the recent
    // selection-type ordering flips (the `Current(type)` analog), delivered
    // LAST of the four channels. Invalidate-only, no unsubscribe (v1).
    void onCurrentTypeChanged(void delegate(SelType t) dg) {
        if (dg !is null) currentTypeSubs ~= dg;
    }

    // --- Flush ------------------------------------------------------------
    // Deliver accumulated mesh flags + selection domains + layer kinds + an
    // optional current-type flip to subscribers. If all four are empty there is
    // nothing to deliver, so return early (no counter bump, no subscriber call).
    // Documented fixed delivery order:
    //   meshChanged → selectionChanged → layerChanged → currentTypeChanged.
    // currentTypeChanged fires LAST so a subscriber reacting to a type flip sees
    // the mesh/selection/layer invalidation already signalled first.
    //
    // `typeChanged` gates the current-type channel: when true, `newType` is the
    // type promoted to current. (SelType has no None sentinel, hence the bool.)
    void flush(uint meshFlags, uint selDomains, uint layerKinds,
               bool typeChanged = false, SelType newType = SelType.Vertex) {
        if (meshFlags == 0 && selDomains == 0 && layerKinds == 0 && !typeChanged)
            return;

        assert(!flushing_,
            "change_bus: subscriber re-entered flush (subscribers are " ~
            "invalidate-only and must not mutate the mesh or re-flush)");
        flushing_ = true;
        scope (exit) flushing_ = false;

        ++flushCount;
        lastFlushFlags = meshFlags;
        lastSelDomains = selDomains;
        lastLayerKinds = layerKinds;

        if (meshFlags & MeshEditScope.Position) ++totalPosition;
        if (meshFlags & MeshEditScope.Points)   ++totalPoints;
        if (meshFlags & MeshEditScope.Polygons) ++totalPolygons;
        if (meshFlags & MeshEditScope.Marks)    ++totalMarks;
        if (meshFlags & MeshEditScope.Material) ++totalMaterial;

        if (selDomains & SelDomain.Vertex) ++totalSelVertex;
        if (selDomains & SelDomain.Edge)   ++totalSelEdge;
        if (selDomains & SelDomain.Face)   ++totalSelFace;
        if (selDomains & SelDomain.Item)   ++totalSelItem;

        if (layerKinds & LayerChange.Added)             ++totalLayerAdded;
        if (layerKinds & LayerChange.Removed)           ++totalLayerRemoved;
        if (layerKinds & LayerChange.Reordered)         ++totalLayerReordered;
        if (layerKinds & LayerChange.Renamed)           ++totalLayerRenamed;
        if (layerKinds & LayerChange.VisibilityChanged) ++totalLayerVisible;
        if (layerKinds & LayerChange.BackgroundChanged) ++totalLayerBackground;
        if (layerKinds & LayerChange.ActiveChanged)     ++totalLayerActive;

        if (typeChanged) { ++currentTypeChanged; lastCurrentType = newType; }

        if (meshFlags != 0)
            foreach (dg; meshSubs) dg(meshFlags);
        if (selDomains != 0)
            foreach (dg; selSubs) dg(selDomains);
        if (layerKinds != 0)
            foreach (dg; layerSubs) dg(layerKinds);
        if (typeChanged)
            foreach (dg; currentTypeSubs) dg(newType);
    }
}

// The one module-level instance. Main-thread access only (see header).
__gshared ChangeBus changeBus;

// Layer-change pending accumulator. Layer-structural changes are DOCUMENT-level,
// not per-Mesh — there is no single Mesh that owns "a layer was added" — so the
// accumulator is a module-level global beside the bus instance itself (the bus
// IS global). Drained read-and-zeroed at the single per-frame flush site (app.d)
// exactly like the per-mesh pending sets, then passed as flush's third arg.
__gshared uint pendingLayerChanges;

// OR-accumulate layer-change kinds into the frame's pending word (same coalesce
// contract as mesh.noteChange). Does NOT deliver — delivery is the single flush
// site. Called by the layer commands + the active-switch hook + FileLoad.
void noteLayerChange(uint kinds) {
    pendingLayerChanges |= kinds;
}

// Item-selection pending accumulator. Item (layer) selection is a DOCUMENT-level
// selection domain — there is no single Mesh whose `pendingSelDomains_` it could
// ride (mesh selection domains are geometry marks). So, exactly like
// `pendingLayerChanges`, it accumulates in a module-level global beside the bus
// and is OR-ed into the SELECTION word at the single per-frame flush site
// (app.d), drained read-and-zero there. A frame that selects/deselects items
// coalesces to one `SelDomain.Item` delivery. Mirrors noteLayerChange's
// accumulate-only contract: it does NOT deliver.
__gshared uint pendingItemSelDomain;

// Record an item-selection change for this frame. `kinds` is a SelDomain bit
// (SelDomain.Item). Called by the item-select command path. Drained at the
// app.d flush site and OR-ed into the selection-domain word.
void noteItemSelectionChange(uint kinds = SelDomain.Item) {
    pendingItemSelDomain |= kinds;
}

// Current-type pending accumulator. The current selection type is DOCUMENT/
// session-level (it lives in app.d scene state, not on any Mesh), so — like
// pendingLayerChanges — it accumulates in module-level globals beside the bus
// and is drained read-and-zeroed at the single per-frame flush site (app.d).
// `pendingCurrentType` holds the most-recent flip's target; `pendingCurrentType_set`
// is the "has a flip pending" flag (SelType has no None sentinel). Multiple
// flips within one frame coalesce to the LAST one — only the final current type
// matters to a subscriber that re-polls the order.
__gshared SelType pendingCurrentType;
__gshared bool    pendingCurrentTypeSet;

// Record a current-type flip into the frame's pending state. Does NOT deliver —
// delivery is the single flush site. Called by app.d's geometry-type switch
// funnel (and, later, the item-select path) whenever touchSelType flips the
// front type. Mirrors noteLayerChange's accumulate-only contract.
void noteCurrentType(SelType t) {
    pendingCurrentType    = t;
    pendingCurrentTypeSet = true;
}

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
    bus.flush(combined, 0, 0);

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

    bus.flush(MeshEditScope.Marks, 0, 0);
    assert(calls == 1);
    assert(bus.totalMarks == 1);

    // Second flush with nothing pending: no delivery.
    bus.flush(0, 0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// flush with both args zero is a complete no-op: no counter bump, no call.
unittest {
    ChangeBus bus;
    int meshCalls = 0, selCalls = 0;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onSelectionChanged((uint) { ++selCalls; });

    bus.flush(0, 0, 0);

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

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex | SelDomain.Face, 0);

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
            bus.flush(MeshEditScope.Position, 0, 0); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(MeshEditScope.Marks, 0, 0);
    assert(tripped, "re-entering flush from a subscriber must assert");
}

// SelDomain.Item (#4 Stage 2a) delivers on the SELECTION channel like the
// geometry domains and bumps its own running total. An Item-only sel flush
// reaches selSubs and ticks totalSelItem (not the geometry totals).
unittest {
    ChangeBus bus;
    uint selSeen = 0;
    int  selCalls = 0;
    bus.onSelectionChanged((uint d) { selSeen = d; ++selCalls; });

    bus.flush(0, SelDomain.Item, 0);

    assert(selCalls == 1, "item selection delivers on the selection channel");
    assert(selSeen == SelDomain.Item, "carries the Item domain bit");
    assert(bus.totalSelItem == 1, "totalSelItem ticks");
    assert(bus.totalSelVertex == 0 && bus.totalSelEdge == 0 && bus.totalSelFace == 0,
        "geometry domain totals untouched by an item-only selection");
    assert(bus.lastSelDomains == SelDomain.Item);
}

// Item coalesces with geometry domains in a single selection word.
unittest {
    ChangeBus bus;
    uint selSeen = 0;
    bus.onSelectionChanged((uint d) { selSeen = d; });
    bus.flush(0, SelDomain.Vertex | SelDomain.Item, 0);
    assert(selSeen == (SelDomain.Vertex | SelDomain.Item));
    assert(bus.totalSelVertex == 1 && bus.totalSelItem == 1);
}

// noteItemSelectionChange OR-accumulates into the module-level pending word and
// is pure accumulate (no delivery). Drains read-and-zero like the flush site.
unittest {
    pendingItemSelDomain = 0;
    noteItemSelectionChange();                  // default SelDomain.Item
    noteItemSelectionChange(SelDomain.Item);    // coalesces
    assert(pendingItemSelDomain == SelDomain.Item, "noteItemSelectionChange coalesces");

    uint drained = pendingItemSelDomain;
    pendingItemSelDomain = 0;
    assert(drained == SelDomain.Item);
    assert(pendingItemSelDomain == 0, "drain zeroes the pending word");
}

// ===========================================================================
// Layer channel (layerChanged(uint kinds)) — same five contracts as the mesh +
// sel channels, mirrored for the third channel.
// ===========================================================================

// Accumulate-coalesce: several layer kinds OR'd into one flush deliver once with
// every bit set, bumping each per-kind counter exactly once.
unittest {
    ChangeBus bus;
    uint seen = 0;
    int  calls = 0;
    bus.onLayerChanged((uint k) { seen |= k; ++calls; });

    const combined = LayerChange.Added | LayerChange.ActiveChanged;
    bus.flush(0, 0, combined);

    assert(calls == 1, "one delivery per flush");
    assert(seen == combined, "all coalesced layer bits delivered");
    assert(bus.flushCount == 1);
    assert(bus.lastLayerKinds == combined);
    assert(bus.totalLayerAdded == 1 && bus.totalLayerActive == 1);
    assert(bus.totalLayerRemoved == 0 && bus.totalLayerReordered == 0);
}

// A layer-only flush delivers once; a subsequent zero flush is a no-op.
unittest {
    ChangeBus bus;
    int calls = 0;
    bus.onLayerChanged((uint) { ++calls; });

    bus.flush(0, 0, LayerChange.Reordered);
    assert(calls == 1);
    assert(bus.totalLayerReordered == 1);

    bus.flush(0, 0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// Layer kinds are delivered to layerSubs AFTER meshSubs and selSubs, with the
// per-kind counters maintained. (meshChanged → selectionChanged → layerChanged.)
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0, layerSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1;
    bus.onMeshChanged((uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });
    bus.onLayerChanged((uint k) { layerSeen = k; layerOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex,
              LayerChange.Renamed | LayerChange.ActiveChanged);

    assert(meshSeen == MeshEditScope.Marks);
    assert(selSeen == SelDomain.Vertex);
    assert(layerSeen == (LayerChange.Renamed | LayerChange.ActiveChanged));
    assert(meshOrder == 0 && selOrder == 1 && layerOrder == 2,
        "layerChanged fires after meshChanged + selectionChanged");
    assert(bus.totalLayerRenamed == 1 && bus.totalLayerActive == 1);
}

// A layer-only delivery (mesh + sel both zero) is NOT swallowed by the early-out
// — the three-word zero check must consider layerKinds.
unittest {
    ChangeBus bus;
    int meshCalls = 0, layerCalls = 0;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onLayerChanged((uint) { ++layerCalls; });

    bus.flush(0, 0, LayerChange.VisibilityChanged);

    assert(meshCalls == 0, "no mesh delivery when meshFlags==0");
    assert(layerCalls == 1, "layer delivery must not be swallowed by the early-out");
    assert(bus.flushCount == 1);
    assert(bus.totalLayerVisible == 1);
}

// Reentrancy: a layer subscriber that re-enters flush trips the same guard.
unittest {
    import core.exception : AssertError;

    ChangeBus bus;
    bool tripped = false;
    bus.onLayerChanged((uint) {
        try {
            bus.flush(0, 0, LayerChange.Added); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(0, 0, LayerChange.Removed);
    assert(tripped, "re-entering flush from a layer subscriber must assert");
}

// ===========================================================================
// Current-type channel (currentTypeChanged) — the fourth bus channel. Same
// no-op / coalesce / order contracts, mirrored for current-type flips.
// ===========================================================================

// A current-type-only flush (mesh/sel/layer all zero) is NOT swallowed by the
// early-out, delivers the new SelType once, and bumps the counter.
unittest {
    ChangeBus bus;
    int  meshCalls = 0, typeCalls = 0;
    SelType seen = SelType.Vertex;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onCurrentTypeChanged((SelType t) { seen = t; ++typeCalls; });

    bus.flush(0, 0, 0, true, SelType.Polygon);

    assert(meshCalls == 0, "no mesh delivery when meshFlags==0");
    assert(typeCalls == 1, "current-type delivery must not be swallowed by the early-out");
    assert(seen == SelType.Polygon, "delivers the newly-current type");
    assert(bus.flushCount == 1);
    assert(bus.currentTypeChanged == 1, "currentTypeChanged counter ticks");
    assert(bus.lastCurrentType == SelType.Polygon);
}

// `typeChanged == false` carries NO current-type flip even with a non-default
// newType — the counter must not tick (it would otherwise false-positive every
// frame that does a mesh/sel edit).
unittest {
    ChangeBus bus;
    int typeCalls = 0;
    bus.onCurrentTypeChanged((SelType) { ++typeCalls; });

    bus.flush(MeshEditScope.Marks, 0, 0);              // 3-arg: typeChanged defaults false
    bus.flush(MeshEditScope.Marks, 0, 0, false, SelType.Edge); // explicit false
    assert(typeCalls == 0, "no current-type delivery when typeChanged is false");
    assert(bus.currentTypeChanged == 0, "counter does not tick without a flip");
}

// Current-type is delivered LAST, after mesh/sel/layer.
unittest {
    ChangeBus bus;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1, typeOrder = -1;
    bus.onMeshChanged((uint) { meshOrder = order++; });
    bus.onSelectionChanged((uint) { selOrder = order++; });
    bus.onLayerChanged((uint) { layerOrder = order++; });
    bus.onCurrentTypeChanged((SelType) { typeOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex,
              LayerChange.ActiveChanged, true, SelType.Edge);

    assert(meshOrder == 0 && selOrder == 1 && layerOrder == 2 && typeOrder == 3,
        "delivery order: mesh → sel → layer → currentType");
}

// A current-type flip alone (no mesh/sel) ticks currentTypeChanged but NOT the
// selection or mesh counters — a mode switch is not selection content.
unittest {
    ChangeBus bus;
    bus.flush(0, 0, 0, true, SelType.Edge);
    assert(bus.currentTypeChanged == 1);
    assert(bus.totalSelVertex == 0 && bus.totalSelEdge == 0 && bus.totalSelFace == 0,
        "a type flip publishes NO selection domain");
    assert(bus.totalPosition == 0 && bus.totalMarks == 0,
        "a type flip publishes NO mesh change");
}

// noteCurrentType records the LAST flip into the module-level pending state and
// is pure accumulate (no delivery). Drains read-and-zero like the flush site.
unittest {
    pendingCurrentTypeSet = false;
    pendingCurrentType    = SelType.Vertex;
    noteCurrentType(SelType.Edge);
    noteCurrentType(SelType.Polygon);             // coalesce to the LAST flip
    assert(pendingCurrentTypeSet, "a flip is pending");
    assert(pendingCurrentType == SelType.Polygon, "coalesces to the last type");

    // Drain semantics mirror the app.d flush site.
    bool drainedSet = pendingCurrentTypeSet;
    SelType drainedType = pendingCurrentType;
    pendingCurrentTypeSet = false;
    assert(drainedSet && drainedType == SelType.Polygon);
    assert(!pendingCurrentTypeSet, "drain clears the pending flag");
}

// noteLayerChange OR-accumulates into the module-level pending word and is pure
// accumulate (no delivery). Drains read-and-zero like the app.d flush site does.
unittest {
    pendingLayerChanges = 0;
    noteLayerChange(LayerChange.Added);
    noteLayerChange(LayerChange.ActiveChanged);
    assert(pendingLayerChanges
        == (LayerChange.Added | LayerChange.ActiveChanged),
        "noteLayerChange coalesces kinds");

    // Drain semantics mirror the app.d flush site.
    uint drained = pendingLayerChanges;
    pendingLayerChanges = 0;
    assert(drained == (LayerChange.Added | LayerChange.ActiveChanged));
    assert(pendingLayerChanges == 0, "drain zeroes the pending word");
}
