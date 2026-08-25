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
//
// TASK 1906 stage 0 — SYNCHRONOUS DELIVERY AT THE EDIT BOUNDARY.
// `deliverMesh` is a SECOND entry point beside `flush`, called from
// `Mesh.deliverPending()` at the tail of `Mesh.commitChange` /
// `Mesh.publishChange`, i.e. INSIDE the mutation rather than once per frame.
// Two consequences that shape everything below:
//
//   * a listener now runs while a mesh edit is in progress, so the contract is
//     tighter than "invalidate-only": a listener may write ONLY ITS OWN DIRTY
//     STATE. It may not read the mesh, mutate anything, touch GL, publish, or
//     re-enter delivery. The recompute is LAZY, at the reader. `nothrow` on
//     every listener alias is the compile-time half of that; the always-on
//     `assert(!delivering_, …)` in `deliverMesh` is the run-time half.
//   * delivery carries the SUBJECT's address, because every consumer in this
//     tree already keys its cache on the mesh address (`MeshCacheKey.addr`,
//     `BvhPick._meshAddr`, `CandidateGrid.meshAddr`, …). One global port that
//     names its subject speaks the language they already speak, and needs no
//     `change_bus → mesh` import.
//
// `deliverMesh` deliberately shares NOTHING with `flush`'s counters — see its
// own comment for why double-counting would dirty a clean document.
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
    // helpers below; never removed in v1. flush() and deliverMesh() iterate
    // these.
    //
    // R7 (task 1906) — EVERY subscriber alias is `nothrow`, and that is the whole
    // enforcement of "a listener does not throw". A synchronous listener runs
    // inside `Mesh.commitChange`, AFTER the version bump: a throwing body would
    // abandon the edit half-done, with the counters already advanced. `nothrow`
    // is checked by the COMPILER at every registration site, which is the only
    // enforcement here that cannot be forgotten. `deliverMesh` deliberately does
    // NOT wrap its loop in a try/catch — a wrap would swallow the contract
    // violation instead of preventing it.
    //
    // `subjectAddr` on the mesh channel is `cast(size_t)&mesh` of the mesh that
    // changed; it is 0 on the per-frame `flush`, which ORs every layer's pending
    // word together and so has NO single subject.
    alias MeshSubscriber        = void delegate(size_t subjectAddr, uint flags) nothrow;
    alias SelSubscriber         = void delegate(uint domains) nothrow;
    alias LayerSubscriber       = void delegate(uint kinds) nothrow;
    alias CurrentTypeSubscriber = void delegate(SelType t) nothrow;

    MeshSubscriber[]  meshSubs;
    SelSubscriber[]   selSubs;
    LayerSubscriber[] layerSubs;
    // The current-type channel — the `Current(type)` analog the layer-change
    // (Stage-5) work deferred to selection-types #4. Carries the newly-current
    // SelType when the front of the recent-ordering flips. Delivered LAST, after
    // the mesh/sel/layer channels (see flush). Invalidate-only, no unsubscribe.
    // DOCUMENT-level: it has no owning `Mesh`, so it stays on the frame flush
    // and `deliverMesh` never touches it (task 1906 §1.6).
    CurrentTypeSubscriber[] currentTypeSubs;

    // Re-entrancy guard, shared by `flush` and `deliverMesh`: a listener must
    // not re-enter delivery, and — since task 1906 made delivery synchronous
    // with the mutation — must not publish or mutate the mesh either, because
    // that IS a re-entry. Renamed from `flushing_` when the second entry point
    // landed: the state it names is "a listener is running", not "we are in
    // flush". The assert on it is ALWAYS-ON (no `debug`, no `version`): it is
    // the contract's only run-time enforcement and it must be reachable in
    // every lane, including the suite-test binaries `run_test.d` compiles with
    // a bare `dmd -unittest` and no `-debug`.
    private bool delivering_;

    // --- Debug / test-introspectable counters -----------------------------
    // Plain fields so tests (and the future /api/changes endpoint) can read
    // them directly. Updated on every non-empty flush.
    ulong flushCount;        // number of flushes that actually delivered
    uint  lastFlushFlags;    // mesh flags of the most recent delivered flush
    uint  lastSelDomains;    // selection domains of the most recent delivery
    uint  lastLayerKinds;    // layer-change kinds of the most recent delivery
    SelType lastCurrentType; // the type made current by the most recent delivery

    // --- Synchronous-delivery counters (task 1906 stage 0) ----------------
    // A SEPARATE family from the flush counters above, deliberately: the frame
    // flush still drains `Mesh.pendingChanges_` for the same mutation, so a
    // per-class total incremented on BOTH paths would count every edit twice
    // and `docRevision()` — which decides whether the document is dirty —
    // would move at twice its rate. `deliverMesh` therefore touches only these
    // four fields, and `tests/test_change_bus.d`'s exact per-frame deltas stay
    // byte-for-byte what they were.
    //
    // Plain always-on fields (not `version (unittest)`): `/api/changes` reads
    // them from the editor binary, which is where the per-command census and
    // the delivery-granularity test look. Tests read them as DELTAS, like every
    // other counter on this endpoint.
    ulong  deliveryCount;         // synchronous deliveries that reached a listener
    size_t lastDeliverySubject;   // `cast(size_t)&mesh` of the most recent subject
    uint   lastDeliveryFlags;     // mesh flags of the most recent DELIVERY
    uint   lastDeliverySelDomains;// selection domains of the most recent DELIVERY

    // Missed-publisher count (task 0462). Incremented by the per-frame debug
    // guard in app.d whenever a layer's mutationVersion advanced with ZERO
    // pending change flags — a mutation site bumped the version but did not
    // noteChange/commitChange, leaving bus-keyed caches (subpatch preview,
    // snap, symmetry, pick) stale. The guard also logs a one-shot stderr line;
    // this counter is the test-introspectable form (via /api/changes) so a
    // regression can assert it stays 0. Debug-build only (the guard is under
    // `debug`); release builds leave it 0.
    ulong missedPublishers;

    // --- The mesh-edit seam counters (task 1903 §5.8) ---------------------
    // Five plain scalars, here rather than module-level in `mesh.d`, for one
    // reason: `/api/changes` takes ONE `const snap = changeBus;` copy up front
    // (task 0763) precisely so the response cannot contradict itself, and a
    // counter living anywhere else would be read outside that copy. They are
    // also not fields of `Mesh` — the six wholesale `*mesh = …` kernels would
    // zero them — and not fields of the per-batch tracker, which dies at the
    // batch close, i.e. once per drag frame.
    //
    // All five are asserted (`== 0`, or as a delta across a step) by the
    // suite; `unbatchedGeometryCommits` additionally carries a POSITIVE
    // control, because its document-mesh predicate can be uninstalled and then
    // every `== 0` on it is vacuous.

    /// 1->2 batch-depth transitions. A kernel never opens a batch — the
    /// command or the tool does — so this counts command-calls-command, and a
    /// test asserts it stays 0. A counter with a consumer, not a bit with none.
    ulong nestedBatchOpens;

    /// Geometry-class `commitChange` calls that reached a DOCUMENT mesh
    /// outside any edit batch. Telemetry per family: as each family migrates,
    /// its ops stop ticking this. Gated by `mesh.g_isDocumentMesh`, which
    /// reads UNINSTALLED as "not a document mesh" — so this is a suite-lane
    /// observable only, and a unit case that reads it must install the
    /// predicate against its own mesh or be green in both directions.
    ulong unbatchedGeometryCommits;

    /// Recording batches opened inside an UNRECORDED one — a hard refusal
    /// (`mesh.pushEditFrame`). The alternative to refusing is a corrupt undo
    /// record: the inner delta would be missing everything the outer batch did
    /// before it. This counter is the refusal's witness in BOTH build kinds,
    /// which a `debug assert` could not be.
    ulong batchUpgradeRefusals;

    /// Op-log entries the closed batches recorded, summed. Read as a delta
    /// across a step: zero across the frames of an interactive drag (the
    /// preview path must be unrecorded), non-zero at the drop.
    ulong opLogEntriesRecorded;

    /// `MeshEditBatch` handles destroyed while still open — i.e. an exception
    /// escaped between the open and the close. The destructor pops and ticks
    /// this instead of asserting, because an `Error` raised during unwinding
    /// replaces the exception the command funnel is already handling.
    ulong batchLeaks;

    // Per-class running totals — how many flushes carried each mesh class.
    ulong totalPosition;
    ulong totalPoints;
    ulong totalPolygons;
    ulong totalMarks;
    ulong totalMaterial;
    // Per-element MAP values (task 1069): morph entries and the crease weight.
    // PERSISTED document content — `.v3d` writes `meshMaps` / `edgeMaps` and
    // `.lwo` writes VMAPs — so unlike `totalMapsDisplay` below this one is
    // summed into `docRevision()`. Without it a whole morph session (the
    // routed drag, `mesh.morph.set`, `mesh.morph.clear`, create / remove /
    // rename) published ONLY `Maps` and left the document reading clean, so
    // Quit closed with no save prompt and the title showed no asterisk.
    ulong totalMaps;
    // The display-only twin. Counted here so `/api/changes` and a test can
    // still SEE the target-change deliveries; deliberately absent from
    // `docRevision()` — picking a morph to look at is not an edit.
    ulong totalMapsDisplay;

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
    /// persisted mesh classes (geometry + marks + material + per-element
    /// maps) plus the persisted layer-structural kinds (add / remove /
    /// reorder / rename / visibility / per-item property). Deliberately
    /// EXCLUDES selection, current-type flips, layer-active changes and
    /// `MapsDisplay` — those are view/edit state, not saved document content.
    /// io.doc_state compares this value against the revision at the last
    /// save/open/new to detect unsaved changes (see
    /// doc/tasks/work/0434-window-title-unsaved-changes.md).
    ///
    /// THE RULE FOR ADDING A CLASS HERE: does a `.v3d` written before and
    /// after the change differ? `Maps` does (morph entries and crease weights
    /// are both persisted), so it is summed; `MapsDisplay` does not.
    ulong docRevision() const {
        return totalPosition + totalPoints + totalPolygons
             + totalMarks + totalMaterial + totalMaps
             + totalLayerAdded + totalLayerRemoved + totalLayerReordered
             + totalLayerRenamed + totalLayerVisible + totalLayerProperty;
    }

    // --- Registration -----------------------------------------------------
    // The mesh channel carries the subject's ADDRESS as well as the flags
    // (task 1906 §1.1). A subscriber that does not care passes an unnamed
    // first parameter.
    void onMeshChanged(MeshSubscriber dg) {
        if (dg !is null) meshSubs ~= dg;
    }

    void onSelectionChanged(SelSubscriber dg) {
        if (dg !is null) selSubs ~= dg;
    }

    // Register a layer-change subscriber. Like the other channels, subscribers
    // are invalidate-only (must NOT mutate the document or re-enter flush) and
    // live for the app lifetime (no unsubscribe in v1). Delivered LAST, after
    // meshChanged + selectionChanged (see flush).
    void onLayerChanged(LayerSubscriber dg) {
        if (dg !is null) layerSubs ~= dg;
    }

    // Register a current-type subscriber. Fires when the front of the recent
    // selection-type ordering flips (the `Current(type)` analog), delivered
    // LAST of the four channels. Invalidate-only, no unsubscribe (v1).
    void onCurrentTypeChanged(CurrentTypeSubscriber dg) {
        if (dg !is null) currentTypeSubs ~= dg;
    }

    /// "Is a listener running right now?" — the read half of the contract
    /// guard, for the companion asserts in `Mesh.noteChange` /
    /// `noteSelectionChange` / `publishChange`. Those catch an illegal publish
    /// AT the offending line; the always-on assert inside `deliverMesh` below
    /// catches the same violation when it re-enters delivery. Both are needed:
    /// a publish made while a DELIVERY BATCH is open does not re-enter
    /// delivery at all (it only accumulates), so `deliverMesh`'s assert alone
    /// would never see it.
    bool delivering() const nothrow @nogc { return delivering_; }

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
               bool typeChanged = false, SelType newType = SelType.Vertex) nothrow {
        if (meshFlags == 0 && selDomains == 0 && layerKinds == 0 && !typeChanged)
            return;

        assert(!delivering_,
            "change_bus: subscriber re-entered flush (subscribers are " ~
            "invalidate-only and must not mutate the mesh or re-flush)");
        delivering_ = true;
        scope (exit) delivering_ = false;

        ++flushCount;
        lastFlushFlags = meshFlags;
        lastSelDomains = selDomains;
        lastLayerKinds = layerKinds;

        if (meshFlags & MeshEditScope.Position) ++totalPosition;
        if (meshFlags & MeshEditScope.Points)   ++totalPoints;
        if (meshFlags & MeshEditScope.Polygons) ++totalPolygons;
        if (meshFlags & MeshEditScope.Marks)    ++totalMarks;
        if (meshFlags & MeshEditScope.Material) ++totalMaterial;
        if (meshFlags & MeshEditScope.Maps)        ++totalMaps;
        if (meshFlags & MeshEditScope.MapsDisplay) ++totalMapsDisplay;

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

        // Subject 0: the per-frame flush ORs every layer's pending word into
        // one delivery, so there is no single mesh it is about. A subscriber
        // that keys on the address treats 0 as "unknown — invalidate on the
        // flags alone", which is exactly today's behaviour.
        if (meshFlags != 0)
            foreach (dg; meshSubs) dg(0, meshFlags);
        if (selDomains != 0)
            foreach (dg; selSubs) dg(selDomains);
        if (layerKinds != 0)
            foreach (dg; layerSubs) dg(layerKinds);
        if (typeChanged)
            foreach (dg; currentTypeSubs) dg(newType);
    }

    // --- Synchronous delivery (task 1906 stage 0) -------------------------
    // The edit-boundary entry point. Called from `Mesh.deliverPending()` at
    // delivery-batch depth 0, i.e. at the tail of `commitChange` /
    // `publishChange`, AFTER the version bump and AFTER `refreshHiddenDerived`
    // (`source/mesh.d :: commitChange` states the ordering and why each half
    // of it is load-bearing).
    //
    // Carries the mesh + selection channels ONLY, in the same fixed order
    // `flush` documents (meshChanged → selectionChanged). `layerChanged` and
    // `currentTypeChanged` are DOCUMENT-level with no owning `Mesh` to hang a
    // synchronous boundary on, and their only consumer is a counter poller, so
    // they stay on the frame flush (§1.6).
    //
    // WHAT IT DELIBERATELY DOES NOT TOUCH, and this is not tidiness: neither
    // `flushCount`/`lastFlushFlags` nor any per-class total. Until the last
    // frame-drain consumer leaves, the SAME mutation is delivered twice — once
    // here, once out of `Mesh.pendingChanges_` at the frame flush — so a total
    // bumped on both paths would double `docRevision()` and make a clean
    // document read dirty after one edit. Stage 0 is therefore byte-identical
    // on every counter an existing test reads.
    // `nothrow` IS KEPT, AND THE PRICE IS NAMED (task 1906 review S4).
    //
    // `nothrow` is the compile-time half of the listener contract: it is what
    // makes `format`, `writeln` and `logWarn` inside a listener a COMPILE
    // ERROR rather than a runtime surprise, and a dirty-bit set — which is all
    // a listener is allowed to do — costs nothing to declare. That is the good
    // news, and it is why the attribute stays.
    //
    // The price: an `Error` raised inside this frame — the asserts below, or an
    // `AssertError` from a listener — DOES NOT RELEASE `delivering_`. dmd emits
    // no unwind cleanup in a `nothrow` frame, so the `scope (exit)` never runs
    // and the guard latches on. That is deliberate, because in production the
    // latch is unreachable rather than survivable:
    //
    //   * `app.d` never catches `Error` (nothing in the main loop does), and
    //     `/api/command` is marshalled onto the main thread — so an `Error`
    //     here ends the process. A guard that never releases in a process that
    //     is already dying costs nothing.
    //   * `flush` gained `nothrow` in this same change. Its two pre-existing
    //     re-entrancy test blocks stay green ONLY because they catch the
    //     `AssertError` INSIDE the listener, where the guard's `scope (exit)`
    //     is still ahead of them. A test that let the error escape the listener
    //     would latch `delivering_` for every later module in the shared
    //     unittest binary; the two synchronous-delivery blocks in
    //     `tests/unit/change_bus_test.d` copy that placement for that reason,
    //     and say so.
    //   * `assert` is compiled OUT under `-release`. Of the buildTypes in
    //     `dub.json`, `perf` and `check-release` set `releaseMode`, as does the
    //     shipped `--build=release`; NONE of them is a lane that runs tests. So
    //     the guard is present in every lane that could observe a violation,
    //     and absent only where an already-validated build is being timed.
    //
    // The alternative — dropping `nothrow` and wrapping the loop in a
    // `try`/`catch` — was rejected in §1.5: it would swallow the contract
    // violation instead of preventing it, and it would give back the
    // compile-time half for nothing.
    void deliverMesh(size_t subjectAddr, uint meshFlags, uint selDomains) nothrow {
        if (meshFlags == 0 && selDomains == 0) return;

        // THE GUARD. Always-on — no `debug`, no `version` — because a listener
        // that publishes, mutates the mesh, or re-enters delivery corrupts an
        // edit in progress, and the lane that compiles this into a suite-test
        // binary (`dmd -unittest`, no `-debug`) is exactly the lane a
        // `debug {}` body would be absent from.
        assert(!delivering_,
            "change_bus: a listener mutated the mesh, published, or " ~
            "re-entered delivery — listeners are dirty-bit-only");
        delivering_ = true;
        scope (exit) delivering_ = false;

        ++deliveryCount;
        lastDeliverySubject     = subjectAddr;
        lastDeliveryFlags       = meshFlags;
        lastDeliverySelDomains  = selDomains;

        if (meshFlags != 0)
            foreach (dg; meshSubs) dg(subjectAddr, meshFlags);
        if (selDomains != 0)
            foreach (dg; selSubs) dg(selDomains);
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
// TASK 1906 STAGE 1 — the re-grade DECOUPLING CENSUS (plan §2.3).
// ===========================================================================
//
// `XfrmTransformTool.lastAppliedGestureMutationVersion` is the one surviving
// consumer of `mutationVersion` that this task deliberately does NOT move onto
// the bus: it is not a cache freshness key, it is a gesture-identity guard
// asking "has a FOREIGN edit landed since my gesture committed?", and the bus
// has no class for "someone other than me edited". It is the RECORDED
// REMAINDER, and these two counters are the measurement that says whether the
// remainder could one day be paid off.
//
// The claim under measurement, evaluated at all four of the guard's read sites
// (`tools/transform/xfrm_transform.d :: regradeStampCurrent`):
//
//     (mesh.mutationVersion == lastAppliedGestureMutationVersion)
//       == (history.undoEpoch() == armedUndoEpoch)
//
// A COUNTER, not an `assert`, and the reason is the verdict channel rather
// than the claim (plan §2.3, Revision 2):
//
//   1. the census lives in the EDITOR binary, because it is measured by
//      driving `./vibe3d` over HTTP with the falloff / refire suite. An
//      `AssertError` there kills the main thread while the process lives on,
//      and every later HTTP request then costs the full 120 s command-bridge
//      timeout — the suite HANGS instead of reporting (dub.json's `check`
//      buildType comment states this verbatim);
//   2. a counter gives a NUMBER — how many times the two disagreed out of how
//      many evaluations — which is what "the disagreement is the finding"
//      needs. An abort gives only "at least once".
//
// WHY THEY LIVE IN `change_bus` AND NOT IN THE TOOL. They must be readable
// from `/api/changes`, which is answered on the HTTP thread and reads this
// module's `__gshared` state directly. Declaring them here is what keeps
// `http_server` free of a dependency on `tools.transform.*` for two integers;
// both sides already import this module. They are module-level, NOT fields of
// `ChangeBus`, so `route_apiChanges`'s whole-struct snapshot copy is unchanged
// and nothing here pretends to be bus traffic.
//
// LIFETIME: process-global and monotone, like every other counter on that
// endpoint. Tests read them as DELTAS across a step.
//
// WHY THERE ARE THREE COUNTERS AND NOT TWO (review B1). `regradeCensusChecks`
// counts EVERY evaluation, and a DISARMED evaluation cannot disagree: both
// terms hold the same `ulong.max` sentinel, both compares answer false, and
// the row is scored as an agreement it had no way to avoid. A floor written
// as `checks > 0` is therefore satisfiable by rows that could never have
// produced the finding.
//
// `regradeCensusArmedChecks` is the honest denominator: only the rows where
// the stamp is ARMED (`lastAppliedGestureMutationVersion != ulong.max`), i.e.
// where the two terms are free to differ. The test's floor reads THIS counter.
//
// AND THE MEASUREMENT REFUTED THE HYPOTHESIS THAT PROMPTED IT, which is worth
// more than the guard it added. The review predicted the census was mostly
// disarmed rows (~76 of 122). It is not: on the block-(2) scenario of
// `tests/test_refire_after_sync_publish.d` EVERY evaluation is armed — 117 of
// 117, 120 of 120 (the absolute count is an idle-frame count and varies run to
// run; the RATIO is 1). The reason is structural: the only
// live read site is the ARM-2 branch, which short-circuits on
// `history.runOpen()`, and a run is open only after a gesture that ARMED the
// stamp on its way through `armRegradeStamp`. So the counter is currently a
// guarantee rather than a filter — it costs one compare and it keeps the floor
// honest if that mix ever changes. The census's real weakness was never
// disarmed rows; it is that every row is armed-and-nothing-happened, which is
// what block (3) of that file exists to address.
//
// It is keyed on the SHIPPED term's arm state, deliberately, and not on
// `armedUndoEpoch != ulong.max`: the mutation that deletes `armedUndoEpoch`'s
// arm (plan §5 row `1b`) leaves the epoch term at the sentinel while the
// version term is armed. Keyed the other way that mutation would silently
// empty the denominator instead of reddening the verdict.
//
// DELETION CONDITION, so this does not become permanent furniture: when open
// question #21 is decided — either the guard is re-keyed on `undoEpoch` or the
// remainder is accepted for good — this trio goes with the decision.
__gshared ulong regradeCensusChecks;        // times the equivalence was evaluated
__gshared ulong regradeCensusArmedChecks;   // … of those, with the stamp ARMED
__gshared ulong regradeCensusDisagreements; // times the two terms disagreed

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
