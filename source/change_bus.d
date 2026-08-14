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
// Polygons, so this expands to
// Position|Points|Polygons|Marks|Material|Visibility.)
enum uint MeshChangeAll =
      MeshEditScope.Position
    | MeshEditScope.Points
    | MeshEditScope.Polygons
    | MeshEditScope.Marks
    | MeshEditScope.Material
    | MeshEditScope.Visibility;

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
// appearing/disappearing, reordering, per-row attribute edits (name/visible)
// and the active(foreground)-layer switch. Foreground/background is DERIVED
// from item selection, so it rides the SEL channel (SelDomain.Item), not here.
// Like the mesh + sel
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
    // 1 << 5 was the retired transitional `BackgroundChanged` slot (Stage 5).
    // Survey #3 P3 reclaims the free bit for a generic per-layer PROPERTY edit
    // (transform/pivot component, or any future scalar layer param written
    // through the `layer.attr` command). Distinct from Renamed/VisibilityChanged
    // (which have their own kinds for the bespoke name/visible fields) — this is
    // the catch-all "a registered layer Param changed" signal. Like the others
    // it carries NO payload; a subscriber re-polls `document` / `/api/layers`.
    // Background remains DERIVED (visible && !selected) and rides the SEL
    // channel (`SelDomain.Item`), never a layer-channel kind.
    PropertyChanged   = 1 << 5,
    ActiveChanged     = 1 << 6,  // the active (foreground) layer changed
}

// Whole-document replacement mask (load / multi-part import): the layer list is
// replaced wholesale AND the active layer changes. Mirrors MeshChangeAll's role
// for the layer channel. Rename/visibility are deliberately NOT in
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

    // Missed-publisher count (task 0462). Incremented by the per-frame debug
    // guard in app.d whenever a layer's mutationVersion advanced with ZERO
    // pending change flags — a mutation site bumped the version but did not
    // noteChange/commitChange, leaving bus-keyed caches (subpatch preview,
    // snap, symmetry, pick) stale. The guard also logs a one-shot stderr line;
    // this counter is the test-introspectable form (via /api/changes) so a
    // regression can assert it stays 0. Debug-build only (the guard is under
    // `debug`); release builds leave it 0.
    ulong missedPublishers;

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
    ulong totalLayerProperty;   // #3 P3: a registered layer Param edit (layer.attr)
    ulong totalLayerActive;

    // Current-type channel total: how many flushes carried a current-type flip
    // (the `Current(type)` analog). Distinct from selectionChanged — a type
    // switch is NOT selection content, so this ticks while sel/mesh stay zero.
    ulong currentTypeChanged;

    /// Monotonic count of DOCUMENT-CONTENT mutations delivered so far: the
    /// persisted mesh classes (geometry + marks + material) plus the
    /// persisted layer-structural kinds (add / remove / reorder / rename /
    /// visibility / per-item property). Deliberately EXCLUDES selection,
    /// current-type flips, and layer-active changes — those are view/edit
    /// state, not saved document content. io.doc_state compares this value
    /// against the revision at the last save/open/new to detect unsaved
    /// changes (see doc/tasks/work/0434-window-title-unsaved-changes.md).
    ulong docRevision() const {
        return totalPosition + totalPoints + totalPolygons
             + totalMarks + totalMaterial
             + totalLayerAdded + totalLayerRemoved + totalLayerReordered
             + totalLayerRenamed + totalLayerVisible + totalLayerProperty;
    }

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
        if (layerKinds & LayerChange.PropertyChanged)   ++totalLayerProperty;
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









// ===========================================================================
// Layer channel (layerChanged(uint kinds)) — same five contracts as the mesh +
// sel channels, mirrored for the third channel.
// ===========================================================================






// ===========================================================================
// Current-type channel (currentTypeChanged) — the fourth bus channel. Same
// no-op / coalesce / order contracts, mirrored for current-type flips.
// ===========================================================================
