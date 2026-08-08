module commands.layer.commands;

// Layer lifecycle commands (layers Stage 2). Each mutates the one `Document`
// owned by app.d (passed as `Document*`, the FileLoad pattern from Stage 1) and
// rides the generic `/api/command` dispatch — no new write endpoints.
//
// Undo classes (see the design table):
//   layer.add           — model undo  (creates geometry the user can lose)
//   layer.delete        — model undo  (removes geometry; stores the Layer +
//                         index + prior activeIndex for revert)
//   layer.select        — UI-undo class (item selection is UI state)
//   layer.rename        — UI-undo class
//   layer.setVisible    — UI-undo class
//
// Foreground/background is DERIVED from item selection (background == visible &&
// !selected), so there is NO `layer.setBackground` command — callers dispatch
// `layer.select mode:add` (foreground) / `mode:remove` (background) directly.
// (The transitional `layer.setBackground` alias retired in Stage 5.)
//
// The active-layer switch (add / delete / select all move activeIndex) funnels
// through ONE app-installed hook `onSwitch(prev, next)` so tool-drop, the
// coalesce barrier, GPU re-upload, cache invalidation and the MeshChangeAll
// notification happen in one place — see app.d's installSwitchHook.

import command;
import mesh;
import view;
import editmode;
import params : Param, paramToJson, injectParamsInto;
import document : Document, Layer, ItemKind, ItemXform, kindInfo, LinkState,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;
import layer_params : LayerPropsProvider;
import seltype : SelMode, selModeFromToken;
import change_bus : MeshChangeAll, noteLayerChange, LayerChange,
                    noteItemSelectionChange;
import snapshot : MeshSnapshot;

import std.json : JSONValue, JSONType;

// ---------------------------------------------------------------------------
// Shared base — owns the Document* and the switch hook.
// ---------------------------------------------------------------------------

private abstract class LayerCommandBase : Command {
    protected Document* doc;
    // Active-layer-switch hook (installed by app.d). Null in unit-test
    // construction; commands that move activeIndex no-op the display side then.
    protected void delegate(size_t prev, size_t next) onSwitch;
    // Item-selection-type hook (installed by app.d via setItemSelectHook). An
    // item select makes `SelType.Item` the current type — but the authoritative
    // `selTypeOrder` lives in app scene state, so the command calls back through
    // this hook after mutating the selection set. Null in unit-test / headless
    // construction (then the current-type promotion is simply skipped).
    protected void delegate() onItemSelect;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc      = doc;
        this.onSwitch = onSwitch;
    }

    /// Install the item-select-type hook (app.d's switchToItemType). Kept off
    /// the constructor so the 7 command ctors + the registration stay stable;
    /// app.d sets it on the LayerSelect factory only (the lone item-select
    /// command). Returns `this` for fluent registration.
    LayerCommandBase setItemSelectHook(void delegate() dg) {
        this.onItemSelect = dg;
        return this;
    }

    // Resolve an `index` param (default -1 → active layer), clamped into range.
    protected size_t resolveIndex(int raw) const {
        if (raw < 0) return doc.activeIndex;
        size_t i = cast(size_t)raw;
        if (i >= doc.layers.length) i = doc.layers.length - 1;
        return i;
    }

    // Fire the switch hook iff the active LAYER OBJECT changed (not merely its
    // index — a delete below the active layer shifts the index but keeps the
    // same object, and must NOT re-upload/invalidate). `prevLayer` is the
    // active layer object captured BEFORE the mutation.
    protected void fireSwitchIfChanged(Layer prevLayer, size_t prevIndex) {
        if (onSwitch is null) return;
        if (doc.active() is prevLayer) return;  // same mesh on screen — no-op
        onSwitch(prevIndex, doc.activeIndex);
    }
}

// ---------------------------------------------------------------------------
// layer.add — append a fresh empty layer, make it active. Model undo.
// ---------------------------------------------------------------------------

final class LayerAdd : LayerCommandBase {
    private string nameArg;           // "" → auto "Layer N"
    private size_t prevActiveIndex;
    private size_t addedIndex;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.add"; }
    override string label() const { return "Add Layer"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &nameArg, "") ];
    }

    override bool apply() {
        prevActiveIndex = doc.activeIndex;
        auto prevLayer  = doc.active();
        auto l = new Layer;
        import std.conv : to;
        l.name       = nameArg.length ? nameArg
                                      : "Layer " ~ to!string(doc.layers.length + 1);
        l.visible    = true;
        doc.layers ~= l;
        addedIndex  = doc.layers.length - 1;
        // Stage-0 lockstep: set primary + selected + activeIndex together,
        // BEFORE fireSwitchIfChanged (the hook reads activeMesh() == primary).
        doc.setActive(addedIndex);
        applied = true;
        // Structural kind from the command; ActiveChanged from the switch hook
        // (add makes the new layer active), both coalescing into one delivery.
        noteLayerChange(LayerChange.Added);
        fireSwitchIfChanged(prevLayer, prevActiveIndex);
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        auto prevLayer = doc.active();
        size_t prevIdx = doc.activeIndex;
        // Drop the appended layer (it is the tail) and restore the prior active.
        // History entries that mutated this layer keep it alive via GC, but on a
        // plain add-then-undo the layer carried no edits, so dropping it is safe.
        if (addedIndex < doc.layers.length)
            doc.layers = doc.layers[0 .. addedIndex];
        // setActive clamps an out-of-range index into the last layer (matching
        // the prior explicit clamp) and re-establishes primary+selected.
        doc.setActive(prevActiveIndex);
        // Undo of an add is a remove; ActiveChanged via the hook.
        noteLayerChange(LayerChange.Removed);
        fireSwitchIfChanged(prevLayer, prevIdx);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.duplicate — deep-copy the primary layer (or the layer at `index`) into
// a new Layer, append it, and make the clone the selected primary. Model undo.
//
// Deep copy: MeshSnapshot.capture(src.meshRef()).restore(clone.meshRef()) dups every
// array (vertices/edges/faces/marks/maps/surfaces/faceMaterial) and calls
// buildLoops + resizeAllMeshMaps, so the clone's mesh is fully independent.
// Name, xform (value struct → value copy), and parent are also copied;
// visible is always set true on the clone.
//
// Undo: the clone is always the tail (appended by apply), so revert drops it
// with a simple slice and restores the exact prior selection set + primary by
// layer OBJECT IDENTITY (the LayerDelete review-#6 pattern).
//
// Redo: apply() re-creates a FRESH clone each time (linear undo → safe; the
// old clone has no history-bound Mesh* that needs re-use, unlike LayerDelete
// which reinserts the exact removed Layer to keep captured Mesh* alive).
// ---------------------------------------------------------------------------

final class LayerDuplicate : LayerCommandBase {
    private int         indexArg = -1;    // -1 → primary (resolveIndex)
    private size_t      addedIndex;
    private Layer       added;            // the appended clone
    private bool[Layer] prevSelected;     // full selection snapshot by identity
    private Layer       prevPrimary;
    private size_t      prevActiveIndex;
    private bool        applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.duplicate"; }
    override string label() const { return "Duplicate Layer"; }
    // Model-undo (default): duplicate creates geometry the user can lose via
    // Ctrl+Z. Do NOT override cmdFlags() — Command.Model is the base default.

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1) ];
    }

    override bool apply() {
        if (doc.layers.length == 0) return false;

        prevActiveIndex = doc.activeIndex;
        auto prevLayer  = doc.active();

        // Snapshot the full prior selection set by layer identity, BEFORE
        // setActive (which collapses to SET-of-one) so revert can restore any
        // prior multi-selection exactly (LayerDelete review-#6 pattern).
        prevPrimary  = prevLayer;
        prevSelected = null;
        foreach (l; doc.layers) prevSelected[l] = l.selected;

        // Source: default -1 → primary; explicit index for test/scripted paths.
        size_t srcIdx = resolveIndex(indexArg);
        auto src = doc.layers[srcIdx];

        // Build the clone — deep-copy the source mesh in place into a fresh
        // Layer object (never alias the GC-managed arrays). Task 0615 Stage 4:
        // the clone must carry the source's `kind` too (a non-mesh layer's
        // clone was silently forced to `ItemKind.Mesh` before this), and the
        // mesh snapshot only makes sense when the source actually has one.
        auto l2 = new Layer;
        l2.kind = src.kind;
        if (src.hasMesh)
            MeshSnapshot.capture(src.meshRef()).restore(l2.meshRef());
        // Task 0616 Stage 2 (§O1): the same defect class as the `kind` fix
        // just above, one field over — a payload that is a class REFERENCE
        // does not follow `l2.kind = src.kind` for free. Unlike the mesh
        // (deep-copied above), the clone SHARES the source's image payload
        // by object identity: two layers pointing at the same loaded image
        // is the whole point (one decode, N consumers), not a bug to avoid.
        // The refcount bump this sharing implies is Stage 5's job (once the
        // pixel cache exists) — pinned there by T11b; this stage only wires
        // the pointer so a duplicated image row is a LIVE image row, not a
        // payload-null one (T11a).
        if (src.hasImage)
            l2.imageRef() = src.imageOrNull();
        l2.name    = src.name ~ " copy";
        l2.visible = true;
        l2.xform   = src.xform;    // ItemXform is a value struct → value copy
        l2.parent  = src.parent;   // same parent ref; clone is never a target
        // Task 0616 Stage 6 (Ph3): the clone's OUTGOING links. Third instance
        // of the same defect class as `kind` and `image_` above — a field that
        // `new Layer` leaves at its init and the field-by-field clone must be
        // told about, or a duplicated consumer silently forgets what it was
        // pointing at. Shallow by construction (`copyLinksFrom`): the slot
        // SET is copied so the two consumers can be re-pointed independently,
        // the TARGETS are shared by identity, because "two consumers, one
        // target" is the model, not an aliasing accident.
        l2.copyLinksFrom(src);

        // Append and make the clone the active primary (SET-of-one), BEFORE
        // fireSwitchIfChanged so the hook reads the correct (new) active mesh.
        doc.layers  ~= l2;
        addedIndex   = doc.layers.length - 1;
        doc.setActive(addedIndex);
        added   = l2;
        applied = true;

        // Structural add: the switch hook contributes ActiveChanged iff the
        // active OBJECT genuinely changed (it did — the clone has a new mesh
        // address and is a different Layer object than prevLayer).
        noteLayerChange(LayerChange.Added);
        fireSwitchIfChanged(prevLayer, prevActiveIndex);
        return true;
    }

    override bool revert() {
        if (!applied) return false;

        // Capture the current active BEFORE mutations so fireSwitchIfChanged
        // knows what the screen was showing (the clone, which is about to go).
        auto prevLayer = doc.active();
        size_t prevIdx = doc.activeIndex;

        // Drop the clone — it is always the tail (appended by apply).
        if (addedIndex < doc.layers.length)
            doc.layers = doc.layers[0 .. addedIndex];

        // Restore the exact prior selection set by identity, then the prior
        // primary (mirrors LayerDelete.revert, review #6). This handles any
        // multi-selection that was active before the duplicate.
        foreach (l; doc.layers) {
            auto wasSel = (l in prevSelected) ? prevSelected[l] : false;
            l.selected  = wasSel;
        }
        if (prevPrimary !is null) {
            // R5 (task 0615): `prevPrimary` was `doc.primary` at snapshot
            // time, so it is always `canBePrimary` — see LayerDelete.revert.
            debug assert(kindInfo(prevPrimary.kind).canBePrimary,
                "LayerDuplicate.revert: prevPrimary must be canBePrimary (R5)");
            doc.setPrimary(prevPrimary);
        } else {
            doc.setActive(prevActiveIndex);
        }

        // Undo of a duplicate is effectively a remove; the switch hook fires
        // because the active OBJECT changed from the clone back to prevPrimary.
        noteLayerChange(LayerChange.Removed);
        fireSwitchIfChanged(prevLayer, prevIdx);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.reorder — move the layer at `from` to position `to`; the others shift
// to fill. Model undo (changes layers[] STRUCTURE like add/delete).
//
// The ACTIVE layer is preserved by OBJECT IDENTITY, not by index: after the
// move, activeIndex is recomputed so it still points at the SAME Layer object
// it did before. A pure reorder that keeps the same active layer therefore does
// NOT fire the active-layer switch hook (the same mesh is on screen — no
// tool-drop / cache-invalidation), via the shared fireSwitchIfChanged-by-object
// mechanism. revert() moves the layer back to its original slot.
// ---------------------------------------------------------------------------

final class LayerReorder : LayerCommandBase {
    private int    fromArg = -1;
    private int    toArg   = -1;
    private size_t fromIdx;
    private size_t toIdx;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.reorder"; }
    override string label() const { return "Reorder Layer"; }
    // Model-undo class: like add/delete this mutates the layers[] structure,
    // not merely a UI flag — it belongs on the geometry-undo class so the
    // history/panel treat a reorder as a structural document edit.

    override Param[] params() {
        return [ Param.int_("from", "From", &fromArg, -1),
                 Param.int_("to",   "To",   &toArg,   -1) ];
    }

    // Move the layer at `src` to index `dst`, shifting the rest to fill. A
    // pure list-order edit: it must not touch selection/focus at all.
    private void moveLayer(size_t src, size_t dst) {
        auto prevLayer = doc.active();
        // Task 0615: `prevLayer` is `doc.primary` (== `doc.active()`), always
        // `canBePrimary` by the document invariant. Verified, not relied
        // upon: assert it rather than special-case it.
        debug assert(kindInfo(prevLayer.kind).canBePrimary,
            "LayerReorder.moveLayer: the active layer must be canBePrimary");
        auto moved = doc.layers[src];
        // Splice out, then splice in at the destination.
        doc.layers = doc.layers[0 .. src] ~ doc.layers[src + 1 .. $];
        doc.layers = doc.layers[0 .. dst] ~ moved ~ doc.layers[dst .. $];
        // NIT (task 0615 Stage 6 review round 2): no explicit re-point of
        // `primary`/`activeIndex` needed here, and — load-bearing — none
        // must be done. `primary` (and `focusedItem`) are class REFERENCES;
        // the splice above moves array SLOTS, not object identity, so both
        // keep pointing at the exact same `Layer` objects they did before
        // the move. `Document.activeIndex` is a DERIVED scan for
        // `primary`'s current position (`document.d`), so it comes back
        // correct on its own — nothing to write.
        //
        // The code this replaced called `doc.setActive(i)` "to re-point
        // activeIndex", which was never necessary for that reason (there is
        // no stored index to desync) — but `setActive` routes through
        // `exclusiveSelect`, which unconditionally deselects every OTHER
        // layer and resets `focusedItem` to the reselected target. On an
        // all-mesh document that's invisible (the SET-of-one already had
        // nothing else selected), but once a non-mesh item can hold FOCUS
        // independent of `primary` (§L2), that old call silently collapsed
        // any multi-selection or non-mesh focus back down to just `primary`
        // on EVERY reorder, even one that never touched the focused/
        // selected layer at all. Doing nothing here is the correct, and
        // strictly cheaper, fix.
    }

    override bool apply() {
        size_t n = doc.layers.length;
        // Bounds + no-op guards. Out-of-range or from==to is a graceful
        // failure (dispatch reports an error; nothing mutates, no undo entry).
        if (fromArg < 0 || toArg < 0) return false;
        fromIdx = cast(size_t)fromArg;
        toIdx   = cast(size_t)toArg;
        if (fromIdx >= n || toIdx >= n) return false;
        if (fromIdx == toIdx)           return false;

        auto prevLayer = doc.active();
        size_t prevIndex = doc.activeIndex;
        moveLayer(fromIdx, toIdx);
        applied = true;
        // Identity-preserving: a pure reorder keeps the same active Layer, so
        // the switch hook is a no-op. It only fires if the active object
        // genuinely changed (it should not, here — the guard documents the
        // invariant). The reorder kind is published regardless.
        noteLayerChange(LayerChange.Reordered);
        fireSwitchIfChanged(prevLayer, prevIndex);
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        auto prevLayer = doc.active();
        size_t prevIndex = doc.activeIndex;
        // Reverse the move: the layer now sits at toIdx; put it back at fromIdx.
        moveLayer(toIdx, fromIdx);
        noteLayerChange(LayerChange.Reordered);
        fireSwitchIfChanged(prevLayer, prevIndex);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 6 review round 2, NIT: `LayerReorder.moveLayer` used to
// call `doc.setActive(i)` to "re-point activeIndex" after the splice —
// unnecessary (`activeIndex` is a derived scan for `primary`'s identity, not
// a stored value), and that call's ACTUAL effect was `exclusiveSelect`'s
// unconditional "deselect everyone, refocus the reselected target" reset.
// On an all-mesh document that was invisible (nothing else was ever
// selected), but on a mixed document with a non-mesh item holding FOCUS
// independent of `primary` (§L2) plus another layer in the foreground
// (multi-select), a reorder that never even touches those layers silently
// collapsed the whole selection/focus state back down to just `primary`.
// Pin the fix directly: a reorder must leave selection/focus untouched.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;

    auto doc = Document.bootstrap(makeCube());        // [meshA(primary+focus+selected)]
    auto meshA = doc.layers[0];
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB"; meshB.meshRef() = makeCube();
    doc.layers ~= empty;
    doc.layers ~= meshB;                               // [meshA, empty, meshB]

    // Reach {meshA, meshB, empty} all selected, primary == meshA, focus ==
    // empty — through REAL mutators (mirrors document.d's own split-state
    // fixture): Add on a canBePrimary layer moves primary+focus to it;
    // setPrimary moves both back to meshA; Add on the non-mesh layer moves
    // focus WITHOUT moving primary (§L2) — exactly the split the old
    // `moveLayer` code could not tell apart from a plain SET-of-one.
    doc.selectItem(meshB, SelMode.Add);   // meshA, meshB selected; meshB primary+focus
    doc.setPrimary(meshA);                // primary+focus back to meshA
    doc.selectItem(empty, SelMode.Add);   // + empty selected; focus -> empty, primary stays meshA
    assert(doc.primary is meshA && doc.focusedItem is empty && meshB.selected,
        "setup: primary=meshA, focus=empty, {meshA,meshB,empty} all selected");

    auto v = new View(0, 0, 800, 600);
    auto reorder = new LayerReorder(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    reorder.fromArg = 2;   // move meshB (index 2) to the front — touches
    reorder.toArg   = 0;   // neither the primary nor the focused layer.
    assert(reorder.apply(), "reorder must succeed");

    assert(doc.layers[0] is meshB, "meshB moved to the front");
    assert(doc.primary is meshA, "reorder must never move primary");
    assert(doc.focusedItem is empty,
        "NIT fix: reorder must not clobber focus back onto primary");
    assert(meshA.selected && meshB.selected && empty.selected,
        "NIT fix: reorder must not collapse the multi-selection down to "
        ~ "{primary} — it never touched selection at all");
}

// ---------------------------------------------------------------------------
// The `layer.delete` refusal predicate — TRUE iff `target` can be removed
// from `doc`. Shared by `LayerDelete.apply` (below) and the Layers panel's
// Delete button (`layerDeleteButtonState`, `source/ui/panels.d`) so the
// button's enabled state and the command's own refusal are always evaluated
// against the SAME candidate layer through the SAME logic (task 0615 Stage
// 6 review round 2, blocker 2). Two independent copies is exactly how the
// bug happened: the button asked "can the PRIMARY be deleted?" while the
// click handler dispatched a delete of the FOCUSED row — two different
// layers, each internally consistent, silently disagreeing with each other.
//
// Two refusals:
//   - the document invariant `layers.length >= 1`: never delete the last
//     layer, full stop.
//   - the primary-availability invariant: never delete the last
//     `canBePrimary` layer — `Document.primary` must always name a
//     `canBePrimary` survivor (§Q2), and `Document.rehomePrimary` has
//     nothing to rehome to otherwise (see the crash-prevention comment
//     inside `LayerDelete.apply`, below). A non-`canBePrimary` target (e.g.
//     an `Empty`) is unaffected by this second refusal — deleting it never
//     touches who CAN be primary.
bool canDeleteLayer(const(Document)* doc, const(Layer) target) {
    if (doc.layers.length <= 1) return false;
    if (target is null) return false;
    if (kindInfo(target.kind).canBePrimary) {
        foreach (l; doc.layers)
            if (l !is target && kindInfo(l.kind).canBePrimary) return true;
        return false;
    }
    return true;
}

/// The Layers panel's Delete-button target + enabled state (task 0615 Stage
/// 6 review round 2, blocker 2): computed from `doc.focusedItem` — the
/// item-selection FOCUS, i.e. the row the panel highlights as active — NOT
/// `doc.activeIndex`/`doc.primary`. A non-mesh row can be the focus without
/// ever becoming primary (§L2), so the two diverge exactly when a non-mesh
/// item is selected; using `activeIndex` there deletes a different layer
/// than the one the user highlighted. `source/ui/panels.d` calls this
/// directly (not a hand-copy of the formula) so the drawn state and the
/// dispatched command can never disagree — see `canDeleteLayer` above.
struct LayerDeleteButtonState { size_t index; bool enabled; }
LayerDeleteButtonState layerDeleteButtonState(Document* doc) {
    auto   target = doc.focusedItem;
    size_t idx    = doc.indexOf(target);
    bool   ok     = idx < doc.layers.length && canDeleteLayer(doc, target);
    return LayerDeleteButtonState(idx, ok);
}

// ---------------------------------------------------------------------------
// layer.delete — remove a layer (default active). Refuses the LAST layer.
// Model undo: stores the removed Layer + its index + the prior activeIndex.
// ---------------------------------------------------------------------------

final class LayerDelete : LayerCommandBase {
    private int    indexArg = -1;     // -1 → active
    private Layer  removed;           // the deleted layer object (revert reinserts)
    private size_t removedIndex;
    private size_t prevActiveIndex;
    // Stage 2b (review #6): the delete may have collapsed a multi-selection
    // (deleting the primary promotes a NEW primary and `setActive` deselects the
    // rest). Snapshot the FULL prior selection set by layer OBJECT identity + the
    // prior primary so revert restores the EXACT set — not just the index. Keyed
    // by identity so the splice between apply and revert can't drift it.
    private bool[Layer] prevSelected;
    private Layer       prevPrimary;
    // Task 0082: layers whose `parent` pointed at `removed` — cleared on apply,
    // restored on revert (snapshot-by-identity, mirrors prevSelected pattern).
    private Layer[] orphanedChildren_;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.delete"; }
    override string label() const { return "Delete Layer"; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1) ];
    }

    override bool apply() {
        removedIndex    = resolveIndex(indexArg);
        prevActiveIndex = doc.activeIndex;
        removed         = doc.layers[removedIndex];   // class ref kept for revert
        auto prevLayer  = doc.active();

        // Task 0615 §L1 (blocker 2, review round 2): the refusal predicate
        // now lives in the free function `canDeleteLayer` (above) so the
        // Layers panel's Delete button can evaluate the SAME guard against
        // the SAME candidate layer, instead of duplicating (and risking
        // drifting from) this logic. Refuses before any mutation: deleting
        // the last layer in the document at all, or the last `canBePrimary`
        // layer — which would leave `rehomePrimary` below with nothing to
        // return (`exclusiveSelect`'s own stale-primary fallback would then
        // silently no-op, leaving `primary` dangling on the just-spliced-out
        // layer — worse than a null primary: it dereferences without
        // crashing).
        if (!canDeleteLayer(doc, removed)) return false;

        // Snapshot the full prior selection set + primary by identity (review #6)
        // BEFORE the splice / setActive collapse, so revert restores the exact
        // multi-selection (including the deleted layer's own bit).
        prevPrimary  = prevLayer;
        prevSelected = null;
        foreach (l; doc.layers) prevSelected[l] = l.selected;

        // Task 0082: collect layers whose parent points at `removed`, snapshot
        // them by identity, then clear their parent to avoid dangling refs.
        orphanedChildren_ = null;
        foreach (l; doc.layers)
            if (l.parent is removed) orphanedChildren_ ~= l;
        foreach (l; orphanedChildren_) l.parent = null;

        // Splice the layer out.
        doc.layers = doc.layers[0 .. removedIndex] ~ doc.layers[removedIndex + 1 .. $];

        // Task 0615 §L1: decide the successor by OBJECT IDENTITY, not by
        // array position. If the removed layer was NOT the primary, the
        // primary object is untouched and stays put — `setActive` just
        // re-points `activeIndex` at its (possibly shifted) new slot. If it
        // WAS the primary, `rehomePrimary` finds the nearest `canBePrimary`
        // survivor (forward from the vacated slot, then backward) — the
        // guard just above guarantees one exists. On an all-mesh document
        // this degenerates EXACTLY to the old positional rule (see
        // `rehomePrimary`'s doc comment), which is what keeps
        // `test_layers.d` / `test_layers_undo.d` / `test_layer_duplicate.d`
        // green unmodified.
        Layer survivor = (removed is prevPrimary)
            ? doc.rehomePrimary(removedIndex) : prevPrimary;
        // NIT (task 0615 Stage 6 review round 2): `rehomePrimary` filters
        // candidates on `canBePrimary` alone — unlike its sibling
        // `anotherPrimaryCandidate` (used by hide-primary promotion and the
        // multi-select `Remove` case), which also requires `l.visible` (and
        // `l.selected`). Deleting the primary can therefore re-home it onto
        // a HIDDEN mesh layer, where the other paths never would. This is
        // PRE-EXISTING (`rehomePrimary` predates this task; this call is
        // merely its first production caller — see its doc comment in
        // document.d) and deliberately NOT changed here: adding a
        // visibility filter would make `rehomePrimary` return `null` in
        // cases `canDeleteLayer`'s guard (above) currently treats as safe
        // (a hidden `canBePrimary` layer counts as "another candidate"
        // there too), breaking the "`rehomePrimary` returns null only in a
        // state the delete guard already forbids" contract — fixing it
        // properly means updating the guard and `rehomePrimary` together,
        // which is out of scope for this slice. Left faithfully preserved.
        // Stage-0 lockstep: set primary + selected + activeIndex together,
        // BEFORE fireSwitchIfChanged. `survivor` is `canBePrimary` by
        // construction (guard above / `rehomePrimary`'s contract), so this
        // takes `setActive`'s unchanged, exclusive-select branch.
        doc.setActive(doc.indexOf(survivor));
        applied = true;
        // Removed kind from the command; the hook contributes ActiveChanged iff
        // the active layer OBJECT changed (deleting a layer below the active one
        // shifts the index but keeps the same mesh → no ActiveChanged). Because
        // `primary` genuinely moves when IT is the one deleted, this now fires
        // for that case too (§L1) — the pre-Stage-6 positional rewrite silently
        // skipped it.
        noteLayerChange(LayerChange.Removed);
        fireSwitchIfChanged(prevLayer, prevActiveIndex);
        return true;
    }

    override bool revert() {
        if (!applied || removed is null) return false;
        auto prevLayer = doc.active();
        size_t prevIdx = doc.activeIndex;
        // Reinsert the layer object at its original index (GC kept it alive,
        // and any history entry bound to its interior Mesh* still targets it).
        if (removedIndex > doc.layers.length) removedIndex = doc.layers.length;
        doc.layers = doc.layers[0 .. removedIndex] ~ removed
                                                   ~ doc.layers[removedIndex .. $];
        // Restore the EXACT prior selection set by identity (review #6), then the
        // prior primary — `setActive(prevActiveIndex)` would collapse to a SET-of
        // -one and lose any sibling foreground layers a multi-selection had. The
        // reinserted `removed` layer carries its own bit from the snapshot.
        foreach (l; doc.layers) {
            auto wasSel = (l in prevSelected) ? prevSelected[l] : false;
            l.selected  = wasSel;
        }
        if (prevPrimary !is null) {
            // R5: `prevPrimary` was `doc.primary` at snapshot time, and the
            // document invariant guarantees a primary is always
            // `canBePrimary` — so this can never re-establish an illegal
            // (non-mesh) primary. `setPrimary` on an already-selected layer
            // is a no-op reselect.
            debug assert(kindInfo(prevPrimary.kind).canBePrimary,
                "LayerDelete.revert: prevPrimary must be canBePrimary (R5)");
            doc.setPrimary(prevPrimary);
        } else {
            doc.setActive(prevActiveIndex);
        }
        // Task 0082: restore parent links for any layers that had been orphaned.
        foreach (l; orphanedChildren_) l.parent = removed;
        // Undo of a delete is an add; ActiveChanged via the hook iff it changed.
        noteLayerChange(LayerChange.Added);
        fireSwitchIfChanged(prevLayer, prevIdx);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.select — item (layer) selection with a uniform `mode` arg. UI-undo
// class. Stage 2a §B1 fold: `mode:{set,add,remove,toggle}` replaces the prior
// exclusive-only select (`set` == today's behaviour) and any standalone
// deselect. Routes the selection mutation through `doc.selectItem`, which holds
// the SET invariants. A primary move funnels through `fireSwitchIfChanged`
// (which fires `onActiveLayerChanged` on a genuine primary-OBJECT change), and
// the item select promotes `SelType.Item` to current via `onItemSelect`.
//
// Undo is UI-class: the FULL prior selection bitset + the primary identity are
// snapshotted at apply (add/remove can touch several layers, so a single index
// is insufficient), and revert restores them exactly.
// ---------------------------------------------------------------------------

final class LayerSelect : LayerCommandBase {
    private int    indexArg = 0;
    private string modeArg  = "set";   // {set,add,remove,toggle}; set == today's
    // Full prior selection snapshot (per-layer selected bits keyed by layer
    // OBJECT identity, so reorder/delete between apply and revert can't drift
    // it) + the prior primary object.
    private bool[Layer] prevSelected;
    private Layer       prevPrimary;
    private size_t      prevActiveIndex;
    private bool        applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.select"; }
    override string label() const { return "Select Layer"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, 0),
                 Param.enum_("mode", "Mode", &modeArg,
                     [["set","Set"], ["add","Add"],
                      ["remove","Remove"], ["toggle","Toggle"]], "set") ];
    }

    override bool apply() {
        if (doc.layers.length == 0) return false;
        prevActiveIndex = doc.activeIndex;
        prevPrimary     = doc.active();
        // Snapshot the full prior selection set by layer identity.
        prevSelected = null;
        foreach (l; doc.layers) prevSelected[l] = l.selected;

        size_t idx = resolveIndex(indexArg);
        auto target = doc.layers[idx];
        const mode  = selModeFromToken(modeArg);

        doc.selectItem(target, mode);
        applied = true;

        // The primary may or may not have moved; fireSwitchIfChanged is a no-op
        // when the active (primary) OBJECT is unchanged (e.g. a non-primary
        // add/remove), so it does NOT re-upload / tool-drop on a pure set
        // expansion that leaves the edit target put.
        fireSwitchIfChanged(prevPrimary, prevActiveIndex);
        // The item select makes SelType.Item current (app's selTypeOrder + the
        // currentTypeChanged bus signal) and accumulates the Item sel domain.
        noteItemSelectionChange();
        if (onItemSelect !is null) onItemSelect();
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        auto prevLayer = doc.active();
        size_t prevIdx = doc.activeIndex;
        // Restore the exact prior selection set (background derives from it).
        foreach (l; doc.layers) {
            auto wasSel = (l in prevSelected) ? prevSelected[l] : false;
            l.selected  = wasSel;
        }
        // Restore the prior primary by identity (it is guaranteed selected in
        // the restored set since it was the primary at snapshot time).
        if (prevPrimary !is null) {
            // R5 (task 0615): see LayerDelete.revert.
            debug assert(kindInfo(prevPrimary.kind).canBePrimary,
                "LayerSelect.revert: prevPrimary must be canBePrimary (R5)");
            doc.setPrimary(prevPrimary);
        } else {
            doc.setActive(prevActiveIndex);
        }
        fireSwitchIfChanged(prevLayer, prevIdx);
        noteItemSelectionChange();
        if (onItemSelect !is null) onItemSelect();
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.rename — Model-undo class. The name is saved to .v3d, so it is a
// PERSISTENT document edit: plain Ctrl+Z must undo it. No active-index move
// (no switch hook needed — rename never changes the edit target).
// ---------------------------------------------------------------------------

final class LayerRename : LayerCommandBase {
    private int    indexArg = -1;     // -1 → active
    private string nameArg;
    private size_t target;
    private string prevName;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.rename"; }
    override string label() const { return "Rename Layer"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1),
                 Param.string_("name", "Name", &nameArg, "") ];
    }

    override bool apply() {
        target   = resolveIndex(indexArg);
        prevName = doc.layers[target].name;
        doc.layers[target].name = nameArg;
        applied  = true;
        // Pure document-state change: publish the kind, touch NO mesh-pending
        // state (must not bump any mesh-change counter).
        noteLayerChange(LayerChange.Renamed);
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        doc.layers[target].name = prevName;
        noteLayerChange(LayerChange.Renamed);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.setVisible — Model-undo class. Visibility is saved to .v3d, so it is
// a PERSISTENT document edit: plain Ctrl+Z must undo it. Visibility can
// trigger a primary promotion (promoteAwayFromHiddenPrimary), which is also
// reverted cleanly by the stored prevPrimaryObj snapshot.
// ---------------------------------------------------------------------------

final class LayerSetVisible : LayerCommandBase {
    private int    indexArg = -1;     // -1 → active
    private bool   valueArg = true;
    private size_t target;
    private bool   prevVal;
    private Layer  prevPrimaryObj;    // primary at apply time (revert restores)
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.setVisible"; }
    override string label() const { return "Set Layer Visible"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1),
                 Param.bool_("value", "Visible", &valueArg, true) ];
    }

    override bool apply() {
        target  = resolveIndex(indexArg);
        prevVal = doc.layers[target].visible;
        prevPrimaryObj   = doc.active();
        size_t prevIdx   = doc.activeIndex;

        // Hide-primary rule (Stage 2a): hiding the primary PROMOTES the primary
        // to another selected+visible layer when one exists. When NONE exists
        // (the SET-of-one case every pre-#4 test hits), hiding is ALLOWED and
        // leaves a hidden primary — this preserves the established behaviour
        // (hide your only layer) and keeps the suite neutral. The plan's literal
        // "(a) refuse if it is the only visible-selected layer" fallback is
        // DELIBERATELY softened to "allow" here to avoid breaking the existing
        // single-layer setVisible tests; see the report's ambiguity flag. The
        // edit target simply isn't drawn until shown again, and the toolpipe
        // still binds the primary's mesh regardless of visibility.
        doc.layers[target].visible = valueArg;
        if (!valueArg) doc.promoteAwayFromHiddenPrimary();  // best-effort promote
        applied = true;
        // Pure document-state change: publish the kind, touch NO mesh-pending
        // state (must not bump any mesh-change counter).
        noteLayerChange(LayerChange.VisibilityChanged);
        // A promotion moved the primary OBJECT → fire the active-switch hook so
        // the new edit target's mesh is uploaded + caches invalidated.
        fireSwitchIfChanged(prevPrimaryObj, prevIdx);
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        auto curPrimary = doc.active();
        size_t prevIdx  = doc.activeIndex;
        // Restore visibility first.
        doc.layers[target].visible = prevVal;
        // If hiding the primary had promoted the edit target away, the original
        // primary is now visible again — re-promote it by identity so undo
        // lands on the exact prior edit target. (It is still selected; setPrimary
        // is a no-op if it is already primary.)
        if (prevPrimaryObj !is null && doc.active() !is prevPrimaryObj
            && prevPrimaryObj.visible) {
            // R5 (task 0615): see LayerDelete.revert.
            debug assert(kindInfo(prevPrimaryObj.kind).canBePrimary,
                "LayerSetVisible.revert: prevPrimaryObj must be canBePrimary (R5)");
            doc.setPrimary(prevPrimaryObj);
        }
        noteLayerChange(LayerChange.VisibilityChanged);
        fireSwitchIfChanged(curPrimary, prevIdx);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.attr — `layer.attr <index> <attr> <value|?>`
//
// Generic write (and `?` read-back) of a single registered layer Param,
// resolved through `LayerPropsProvider` (survey #3). This is the command that
// makes a layer-props form edit take effect: the forms panel dispatches
// `layer.attr <idx> pos.x <v>` (or `… ?` to read the live value back).
//
// Undo class: Model-undo (CmdFlags.Model) — layer attrs (pos/rot/scl/pivot)
// are saved to .v3d (v5 xform block), so they are PERSISTENT document state.
// Plain Ctrl+Z must undo them by the same principle as layer.rename /
// layer.setVisible. Vertices never move (non-baked render-only transform), but
// the document on disk changes → the op is Model, not UiState.
//
// Coalescing: a run of writes to the SAME (index, attr) collapses into one
// undo entry (a panel drag of one field = one Ctrl+Z), exactly like the
// select-coalescing path (commands/mesh/selection_edit.d). A write to a
// DIFFERENT attr or a different layer breaks the run.
//
// Query (`?`) mode mirrors ToolAttrCommand: resolve the named param against the
// target layer's params(), box paramToJson(param), mutate nothing. The
// dispatcher's query short-circuit (app.d) recognizes isQuery() and returns the
// boxed value WITHOUT recording a history entry.
// ---------------------------------------------------------------------------

final class LayerAttr : LayerCommandBase {
    private int       indexArg = -1;      // -1 → active (resolveIndex)
    private string    attrName_;
    private JSONValue attrValue_;
    private bool      query_;
    private JSONValue queryResult_;
    // Undo snapshot: the PRIOR JSON value of the touched param (so revert()
    // restores exactly that one attr). The resolved layer index is captured at
    // apply time so revert hits the same row even if the active layer moved.
    private size_t    target_;
    private JSONValue priorValue_;
    private bool      applied_;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
        this.attrValue_   = JSONValue(null);
        this.queryResult_ = JSONValue(null);
        this.priorValue_  = JSONValue(null);
    }

    override string name()  const { return "layer.attr"; }
    override string label() const { return "Set Layer Property"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    // Programmatic setters (wired from app.d's positional injector, mirroring
    // ToolAttrCommand). The value/`?` discriminator follows the forms idiom.
    void setIndex(int i)           { indexArg = i; }
    void setAttrName(string n)     { attrName_ = n; }
    void setAttrValue(JSONValue v) { attrValue_ = v; }
    void setQuery(bool v)          { query_ = v; }
    bool isQuery() const           { return query_; }
    JSONValue queryResult() const  { return queryResult_; }
    string queryResultJsonOrEmpty() const {
        if (!query_ || queryResult_.type == JSONType.null_) return "";
        return queryResult_.toString();
    }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1) ];
    }

    override bool apply() {
        if (attrName_.length == 0)
            throw new Exception("layer.attr: no attribute name specified");
        if (doc.layers.length == 0)
            throw new Exception("layer.attr: no layers");

        target_      = resolveIndex(indexArg);
        auto layer   = doc.layers[target_];
        auto prov    = new LayerPropsProvider(layer);
        auto ps      = prov.params();

        // Resolve the named param (shared by query + write). Unknown attr is a
        // graceful error (no crash, no mutation) — caught by the dispatcher and
        // surfaced as a command error, exactly like ToolAttrCommand.
        Param* found;
        foreach (ref p; ps)
            if (p.name == attrName_) { found = &p; break; }
        if (found is null)
            throw new Exception(
                "layer.attr: unknown attribute '" ~ attrName_ ~ "'");

        // Query (read-back) mode: box the live value and return WITHOUT mutating
        // (no injectParamsInto, no bus, no history). A pure read.
        if (query_) {
            queryResult_ = paramToJson(*found);
            return true;
        }

        // READ-ONLY gate. Placed AFTER the resolve (so an unknown name still
        // reports "unknown", not "read-only") and AFTER the query
        // short-circuit (a readonly param stays fully READABLE — that is the
        // whole point of exposing it: the `visible` precedent, layer_params.d).
        //
        // `injectParamsInto` does not consult `readonly_` — it is a generic
        // typed-pointer writer with no policy — so without this check the flag
        // gates nothing on this path and `layer.attr <n> filename evil.png`
        // silently mutates the payload's stored path behind the resolve +
        // decode + refcount hook the dedicated replace command owns. The flag
        // is declared at the param; the enforcement belongs at the write path
        // that reaches it.
        if (found.readonly_)
            throw new Exception(
                "layer.attr: attribute '" ~ attrName_ ~ "' is read-only "
                ~ "(readable via '?', not writable through layer.attr)");

        // Write: snapshot the prior value for revert(), then inject the new one
        // through the param's typed pointer (which aliases the live Layer field).
        priorValue_ = paramToJson(*found);
        // Task 0614 Phase 5 (R7, layer two): the WHOLE pre-write xform, not just
        // the one attr, because `sanitizeXform` rejects a non-finite write by
        // restoring the component it came in on — and this is the only point that
        // still has that value. Captured unconditionally (a plain 4x Vec3 copy)
        // rather than only for the 12 transform attrs: a `name`/`visible` write
        // leaves the xform untouched, so the sanitiser is a no-op there and the
        // branch would buy nothing but a way to get the condition wrong.
        immutable ItemXform beforeXform = layer.xform;
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = attrValue_;
        injectParamsInto(ps, pj);
        // Repair anything the declared bounds could not catch (non-finite on any
        // of the 12; a `scl` component inside the degenerate band around zero) —
        // see LayerPropsProvider.sanitizeXform. Runs BEFORE the change-bus
        // publication so no consumer ever observes the unrepaired state.
        //
        // The verdict is CONSUMED, not discarded (task 0614 Phase 5 review,
        // SF4): a repair silently rewrites a number the user authored — a typed
        // `0` lands as ±1e-4 — and the log ring is this project's channel for
        // "we changed your value and here is why". `logWarnOnce` keys the
        // message per (layer, attr) so a slider dragged through the degenerate
        // band reports once instead of once per frame. Keeping the `bool` alive
        // matters beyond the message: it is the ONLY signal that separates "the
        // write landed as typed" from "the write was repaired", and nothing
        // downstream can re-derive it after the fact.
        if (prov.sanitizeXform(beforeXform)) {
            import log       : logWarnOnce;
            import std.conv  : to;
            immutable string key = "layer.attr.clamp:" ~ target_.to!string
                                 ~ ":" ~ attrName_;
            logWarnOnce("layer", key,
                        "layer " ~ target_.to!string ~ " " ~ attrName_
                      ~ ": value was out of range and has been repaired "
                      ~ "(scale magnitude is clamped to ["
                      ~ MIN_ITEM_SCALE_MAG.to!string ~ ", "
                      ~ MAX_ITEM_SCALE_MAG.to!string
                      ~ "] with the sign kept; a non-finite component is "
                      ~ "rejected back to its previous value)");
        }
        applied_ = true;

        // Pure document-state change: publish the generic property-changed kind,
        // touch NO mesh-pending / mutation-version state (an item transform is
        // non-baked render data — vertices do not move).
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    override bool revert() {
        if (!applied_) return false;
        if (target_ >= doc.layers.length) return false;
        // Restore the snapshotted prior value of the one touched attr.
        auto prov = new LayerPropsProvider(doc.layers[target_]);
        auto ps   = prov.params();
        immutable ItemXform beforeXform = doc.layers[target_].xform;
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = priorValue_;
        injectParamsInto(ps, pj);
        // Task 0614 Phase 5 review, B3: an undo is a WRITE like any other, so
        // it gets the same guard as apply(). `priorValue_` is normally already
        // legal (it was read off a sanitised layer), but "normally" is exactly
        // what the guard is not allowed to rely on: a document loaded before
        // this guard existed, or one whose xform was reached by some future
        // path, would let an undo re-inject a degenerate value into a layer
        // apply() had just repaired. A band enforced on some write paths makes
        // the invalid state rare; enforced on all of them it is impossible.
        prov.sanitizeXform(beforeXform);
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    // Coalescing predicate: a newer LayerAttr is COMPATIBLE iff it targets the
    // SAME resolved layer index AND the SAME attr name. A different attr or a
    // different layer breaks the run → a fresh undo entry. `prev` is the command
    // currently on top of the undo stack (this command was applied just before
    // recordCoalescing ran), so both are already applied; the merge only folds
    // the post-state (see mergeFrom). A query never coalesces (it records no
    // entry, so this is never reached for one).
    override CompareResult compareOp(const Command prev) const {
        auto p = cast(const(LayerAttr))prev;
        if (p is null) return CompareResult.Different;
        if (p.target_ != this.target_)   return CompareResult.Different;
        if (p.attrName_ != this.attrName_) return CompareResult.Different;
        return CompareResult.Compatible;
    }

    // In-place merge of a newer, COMPATIBLE LayerAttr into THIS (the kept top
    // entry): keep THIS entry's older priorValue_ (the value before the FIRST
    // write of the run — the revert target) and adopt `newer`'s attrValue_ (the
    // latest written value — the apply/redo target). One undo then unwinds the
    // whole drag back to the pre-run value. The dispatcher has ALREADY applied
    // `newer`, so the layer holds the merged post-state; do not mutate here.
    override bool mergeFrom(Command newer) {
        auto n = cast(LayerAttr)newer;
        if (n is null) return false;
        this.attrValue_ = n.attrValue_;   // adopt latest written value
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.parent — set/clear the item-parent reference for a given layer.
// Model undo (persistent document state). Guards: refuse self-parent, refuse
// cycles (bounded walk by doc.layers.length). parentArg < 0 or out-of-range
// clears the parent link.
// ---------------------------------------------------------------------------

final class LayerParent : LayerCommandBase {
    private int   childArg  = -1;    // -1 → active
    private int   parentArg = -1;    // -1 → clear
    private size_t childIdx_;
    private Layer  prevParent_;
    private bool   applied_;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.parent"; }
    override string label() const { return "Set Layer Parent"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    override Param[] params() {
        return [ Param.int_("child",  "Child",  &childArg,  -1),
                 Param.int_("parent", "Parent", &parentArg, -1) ];
    }

    override bool apply() {
        if (doc.layers.length == 0) return false;
        childIdx_   = resolveIndex(childArg);
        auto child  = doc.layers[childIdx_];
        prevParent_ = child.parent;

        // Clear: out-of-range or negative parentArg
        if (parentArg < 0 || parentArg >= cast(int)doc.layers.length) {
            child.parent = null;
            applied_ = true;
            noteLayerChange(LayerChange.PropertyChanged);
            return true;
        }
        auto newParent = doc.layers[cast(size_t)parentArg];

        if (newParent is child) return false;   // self-parent guard

        // Cycle guard — bounded walk (cap = layers.length prevents infinite loop
        // even if a pre-existing malformed cycle exists in the graph).
        {
            int cap = cast(int)doc.layers.length;
            Layer cur = newParent;
            while (cur !is null && cap-- > 0) {
                if (cur is child) return false;
                cur = cur.parent;
            }
        }

        child.parent = newParent;
        applied_ = true;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    override bool revert() {
        if (!applied_) return false;
        if (childIdx_ >= doc.layers.length) return false;
        doc.layers[childIdx_].parent = prevParent_;
        noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }
}

// ---------------------------------------------------------------------------
// In-module unittest — LayerDuplicate: apply/revert contract, deep-copy
// independence, xform copy, SET-of-one invariant restore.
//
// Runs under `dub test --config=modeling` (the mandatory core-module gate —
// no server needed; tests the command directly against a live Document).
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;
    import math : Vec3;
    import std.math : isClose;

    // One-layer doc with a cube (8 verts). Set a known xform on the source
    // BEFORE duplicating so we can verify the value copy.
    auto doc = Document.bootstrap(makeCube());
    auto src = doc.layers[0];
    src.xform.pos.x = 1.5f;

    auto v   = new View(0, 0, 800, 600);
    auto dup = new LayerDuplicate(doc.activeMesh(), v, EditMode.Vertices, &doc, null);

    // --- apply ---------------------------------------------------------------
    assert(dup.apply(), "apply must succeed");
    assert(doc.layers.length == 2, "apply: layer count == 2");
    assert(doc.primary is dup.added, "apply: primary is the clone");
    assert(dup.added.selected, "apply: clone is selected");
    assert(dup.added.visible, "apply: clone is visible");
    assert(dup.added.kind == src.kind, "apply: clone kind matches source kind");
    // Name derived from the source — do NOT hard-code "Layer 1 copy" here;
    // check against the actual source name so the test stays correct if the
    // bootstrap name ever changes.
    assert(dup.added.name == src.name ~ " copy",
           "apply: clone name == source.name ~ ' copy'");

    // --- deep-copy independence: distinct backing arrays ---------------------
    assert(dup.added.meshRef().vertices.ptr !is src.meshRef().vertices.ptr,
           "clone has its own vertex backing array (not an alias of the source)");
    assert(dup.added.meshRef().vertices.length == src.meshRef().vertices.length,
           "clone vertex count matches source");
    foreach (i; 0 .. src.meshRef().vertices.length)
        assert(dup.added.meshRef().vertices[i] == src.meshRef().vertices[i],
               "clone vertex positions match source element-wise");

    // Mutate source vertex 0 — the clone must not see the change.
    auto cloneV0 = dup.added.meshRef().vertices[0];
    src.meshRef().vertices[0] = Vec3(99, 99, 99);
    assert(dup.added.meshRef().vertices[0] == cloneV0,
           "editing source mesh does not affect the clone (deep copy verified)");

    // --- xform value copy ----------------------------------------------------
    assert(isClose(dup.added.xform.pos.x, 1.5f, 1e-6f),
           "clone carries the source xform.pos.x");

    // --- revert --------------------------------------------------------------
    assert(dup.revert(), "revert must succeed");
    assert(doc.layers.length == 1, "revert: back to 1 layer");
    assert(doc.primary is src, "revert: source layer is primary again");
    assert(src.selected, "revert: source is selected");
    {
        // SET-of-one invariant after revert.
        size_t selCount = 0;
        foreach (l; doc.layers) if (l.selected) ++selCount;
        assert(selCount == 1, "revert: exactly one layer selected");
    }

    // --- single-layer duplicate: no 'refuse' guard (unlike layer.delete) ----
    // (already proven above — apply succeeded on a single-layer doc.)
}

// ---------------------------------------------------------------------------
// Task 0615 S2 (review round 3): duplicating a NON-MESH layer. Pins the
// deliberate behaviour change at apply()'s `l2.kind = src.kind;` /
// `if (src.hasMesh) ...` pair — before this task, a non-mesh clone was
// silently forced to `ItemKind.Mesh`. This mirrors the shape of the mixed
// fixture at `document.d`'s `mixedDoc()` ([mesh(primary), non-mesh, ...]);
// that helper is `private` to `document`'s module and cannot be imported
// here, so the fixture is rebuilt inline.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;

    auto doc = Document.bootstrap(makeCube());        // "Layer 1" == meshA
    auto meshA = doc.layers[0];
    auto empty = new Layer;
    empty.name = "Empty";
    empty.kind = ItemKind.Empty;
    doc.layers ~= empty;                               // [meshA(primary), empty]
    assert(doc.primary is meshA, "fixture: meshA starts as primary");
    assert(!empty.hasMesh, "fixture: empty has no mesh capability");

    auto v   = new View(0, 0, 800, 600);
    auto dup = new LayerDuplicate(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    dup.indexArg = 1;                                  // target the non-mesh layer

    assert(dup.apply(), "apply must succeed on a non-mesh source");
    assert(doc.layers.length == 3, "apply: layer count == 3");
    assert(dup.added.kind == ItemKind.Empty, "clone of a non-mesh source keeps its kind");
    assert(!dup.added.hasMesh, "clone of a non-mesh source has no mesh capability");
    // The existing all-mesh test above asserts `doc.primary is dup.added` —
    // that would be FALSE here: a non-mesh layer can never become primary
    // (`ItemKindInfo.canBePrimary`), so the mesh snapshot the ctor's `mesh`
    // pointer aliases is correctly skipped, and the mesh edit target must
    // stay put.
    assert(doc.primary is meshA, "apply: a non-mesh clone never becomes primary");
    assert(doc.focusedItem is dup.added, "apply: the clone still becomes the item focus");
    assert(dup.added.selected, "apply: clone is selected");
    assert(meshA.selected, "apply: the mesh primary stays selected too");
    // §L2 / R12 (task 0615 Stage 6): `doc.setActive(addedIndex)` at apply()'s
    // call site is the EXACT call the pre-revision wording would have
    // deselected the mesh primary through — pin the formula, not just the
    // absence of the bug. RED under that wording: `:170`'s unconditional
    // deselect would clear `meshA.selected` and `background()` would then
    // reclassify the live edit target as background.
    assert(!Document.background(meshA),
        "§L2: the mesh primary must never be reclassified background by a "
        ~ "non-mesh duplicate becoming focus+selected");
    {
        size_t selCount = 0;
        foreach (l; doc.layers) if (l.selected) ++selCount;
        assert(selCount == 2,
            "§L2: selected set is exactly {target} ∪ {primary-after} == "
            ~ "{clone, meshA}, size 2");
    }

    assert(dup.revert(), "revert must succeed");
    assert(doc.layers.length == 2, "revert: back to 2 layers");
    assert(doc.primary is meshA, "revert: meshA is still primary");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T11a: duplicating an IMAGE-kind layer must yield a LIVE
// image row, not a payload-null one. This is the exact defect class the
// unittest above already fixed once for `ItemKind.Empty` (review round 3:
// `l2.kind = src.kind` alone was not enough once a non-mesh kind carries a
// FIELD, not just a capability flag) — kind #2 brings a field (`image_`)
// that `Empty` never had to carry, so the earlier fix's `if (src.hasMesh)
// ...` guard does not by itself cover it; the sibling `if (src.hasImage)
// ...` guard added at `apply()` above is what this test pins.
//
// Reached through the command exactly as a caller can reach it today
// (`resolveIndex`, `:72-77`, clamps the index but never checks kind or
// `canBePrimary`) — not by calling `Layer` accessors directly.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;
    import document : ImageData;

    auto doc = Document.bootstrap(makeCube());        // "Layer 1" == meshA
    auto meshA = doc.layers[0];
    auto img = new Layer;
    img.name = "logo";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();
    img.imageRef().storedPath = "logo.png";
    doc.layers ~= img;                                 // [meshA(primary), img]
    assert(doc.primary is meshA, "fixture: meshA starts as primary");
    assert(img.hasImage, "fixture: img has the image capability");
    assert(img.imageOrNull !is null, "fixture: img has a constructed payload");

    auto v   = new View(0, 0, 800, 600);
    auto dup = new LayerDuplicate(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    dup.indexArg = 1;                                  // target the image layer

    assert(dup.apply(), "apply must succeed on an image source");
    assert(doc.layers.length == 3, "apply: layer count == 3");
    assert(dup.added.kind == ItemKind.Image, "clone of an image source keeps its kind");
    assert(doc.primary is meshA, "apply: an image clone never becomes primary (not canBePrimary)");

    // (a) the clone must be a LIVE image row, not a payload-null one — the
    // "ships an image-kind layer with no payload" bug reads null here while
    // passing every kind-only assertion above.
    assert(dup.added.hasImage, "clone: hasImage capability follows kind");
    assert(dup.added.imageOrNull() !is null,
        "clone: imageOrNull() must be non-null — a payload-null image row is exactly the bug this test exists for");

    // (b) the clone's storedPath equals the source's — a clone that
    // allocated a FRESH, empty ImageData (instead of sharing the source's)
    // would read "" here, which is ALSO non-null, so (a) alone would miss it.
    assert(dup.added.imageOrNull().storedPath == "logo.png",
        "clone: storedPath must match the source's, not a fresh default");

    // Stronger than (b) alone, and covers what a cache-backed "residentBytes
    // unchanged" check (T11b, Stage 5 — no cache exists yet in this stage)
    // would otherwise be the only thing to catch: this stage's contract is
    // SHARE, not copy. Assert IDENTITY, so a "copy the fields into a fresh
    // ImageData" implementation — which would also pass the storedPath
    // check above — is caught here instead of silently waiting for a later
    // stage's test to notice.
    assert(dup.added.imageOrNull() is img.imageOrNull(),
        "clone: the image payload is the SAME object as the source's (shared, not copied)");

    assert(dup.revert(), "revert must succeed");
    assert(doc.layers.length == 2, "revert: back to 2 layers");
    assert(doc.primary is meshA, "revert: meshA is still primary");

    // NIT (review round 4): revert removes the CLONE, so the SOURCE'S own
    // payload must survive untouched — free today (nothing releases
    // anything yet), but this is the assertion a later stage needs once
    // `revert` decrements a share count: an implementation that released the
    // payload on revert (mistaking "the clone is gone" for "the clone's
    // reference to a still-shared object should be torn down") would null
    // or corrupt `img.imageOrNull()` here while every assertion above (all
    // scoped to `dup.added`, the clone) stays green.
    assert(img.imageOrNull() !is null,
        "revert: the SOURCE's image payload must survive — an over-release "
        ~ "on revert would null it here while leaving every clone-side "
        ~ "assertion above unaffected");
    assert(img.imageOrNull().storedPath == "logo.png",
        "revert: the SOURCE's payload content is unchanged");
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 6 §L2 / R12: `LayerAdd.apply()`'s `doc.setActive(addedIndex)`
// (`:124`, `doc.layers ~= l; … doc.setActive(addedIndex);`) is the exact call
// the pre-revision plan wording would have deselected the mesh primary
// through. There is no `kind` param on `layer.add` — the Stage 6 gate
// forbids any user/command-reachable path to a non-mesh item — so this test
// reproduces `apply()`'s own call SHAPE directly (append, then
// `doc.setActive` on the appended index) rather than through the command,
// which can only ever construct a mesh-kind layer. This proves the formula
// holds at the production call site's exact shape, not just at `Document`'s
// own unit tests (Stage 3 already proves the type-level mutator).
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;

    auto doc = Document.bootstrap(makeCube());
    auto meshA = doc.layers[0];

    auto added = new Layer;
    added.name    = "Empty";
    added.kind    = ItemKind.Empty;
    added.visible = true;
    doc.layers ~= added;
    doc.setActive(doc.layers.length - 1);   // mirrors LayerAdd.apply()'s doc.setActive(addedIndex)

    assert(!Document.background(meshA),
        "§L2 (LayerAdd): the mesh primary must never be reclassified "
        ~ "background by a non-mesh layer.add target");
    assert(meshA.selected, "§L2 (LayerAdd): the mesh primary stays selected");
    assert(doc.primary is meshA, "§L2 (LayerAdd): primary never moves to a non-mesh target");
    assert(doc.focusedItem is added, "§L2 (LayerAdd): focus moves to the new item");
    {
        size_t selCount = 0;
        foreach (l; doc.layers) if (l.selected) ++selCount;
        assert(selCount == 2,
            "§L2 (LayerAdd): selected set is exactly {target} ∪ {primary-after}, size 2");
    }
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 6 §L1: `LayerDelete` — the identity-based successor
// rewrite. `[MeshA(primary), Empty, MeshB]`, delete index 0 (the primary
// itself). RED against the pre-revision positional wording: `newActive =
// removedIndex < length ? removedIndex : length-1` would land on index 0 of
// the post-splice `[Empty, MeshB]`, i.e. the `Empty` layer — `setActive`
// would then find `primary` (MeshA) stale-but-non-null and, under the OLD
// (pre-Stage-3b) semantics, either strand it outside `layers` or (as this
// codebase's actual `exclusiveSelect` stale-primary fallback happens to
// recover via `rehomePrimary(0)`) land on the WRONG survivor when a
// non-mesh layer precedes a mesh layer that is not first — see the plan's
// worked example. The rewrite decides by identity + `rehomePrimary
// (removedIndex)` directly, matching the plan's algorithm exactly rather
// than relying on that incidental fallback.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;

    auto doc = Document.bootstrap(makeCube());       // "Layer 1" == MeshA
    auto meshA = doc.layers[0];
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    doc.layers ~= empty;
    doc.layers ~= meshB;                              // [MeshA(primary), Empty, MeshB]
    assert(doc.primary is meshA);

    auto v = new View(0, 0, 800, 600);
    bool switchFired = false;
    auto del = new LayerDelete(doc.activeMesh(), v, EditMode.Vertices, &doc,
        (size_t prev, size_t next) { switchFired = true; });
    del.indexArg = 0;                                 // delete MeshA (the primary)

    assert(del.apply(), "delete of the primary must succeed (MeshB survives)");
    assert(doc.layers.length == 2, "MeshA spliced out");
    assert(doc.primary is meshB,
        "§L1: primary rehomes to the surviving MESH layer, never to Empty");
    assert(doc.primary.hasMesh, "§L1: primary always hasMesh");
    assert(doc.layers[doc.activeIndex] is doc.primary,
        "§L1: activeIndex tracks the rehomed primary (false under the "
        ~ "pre-revision wording, where activeIndex silently falls back to 0)");
    assert(switchFired,
        "§L1 / R11: the switch hook must fire — primary genuinely moved "
        ~ "off the deleted layer (the pre-revision wording's stale-primary "
        ~ "identity check would have skipped this)");

    // §L1 guard: deleting the LAST canBePrimary layer is refused, even
    // though the document has more than one layer left ([Empty, MeshB]).
    auto del2 = new LayerDelete(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    del2.indexArg = 1;                                // MeshB is now the ONLY mesh layer
    assert(!del2.apply(), "§L1 guard: refuse deleting the last canBePrimary layer");
    assert(doc.layers.length == 2, "refused delete leaves the document untouched");
    assert(doc.primary is meshB, "refused delete leaves primary untouched");

    // §L1 undo symmetry: undo the FIRST delete restores MeshA as primary and
    // the full prior selection set.
    assert(del.revert(), "undo the delete of MeshA");
    assert(doc.layers.length == 3, "MeshA reinserted");
    assert(doc.primary is meshA, "undo restores MeshA as primary");
    assert(doc.layers[doc.activeIndex] is doc.primary,
        "undo: activeIndex tracks the restored primary");
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 6 review round 2, BLOCKER 2: the Layers panel's Delete
// button dispatched against `document.activeIndex` (the primary) while
// `:983-990` rendered a row as active when it was either the primary OR the
// FOCUS — so clicking a non-mesh row (which becomes focus, never primary,
// §L2) and pressing Delete removed a DIFFERENT layer than the one the user
// highlighted. Repro straight from the review, reproduced at the `Document`
// + `LayerDelete` level (the same layer `layerDeleteButtonState` and the
// fixed panel code both call — see `source/ui/panels.d`):
// `[MeshA(primary), MeshB, Empty]`, click the Empty row (focus moves there,
// primary correctly stays MeshA), press Delete. Pins WHICH layer survives,
// not merely that a delete occurred — the whole point of this blocker.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;

    auto doc = Document.bootstrap(makeCube());        // "Layer 1" == MeshA
    auto meshA = doc.layers[0];
    auto meshB = new Layer; meshB.name = "MeshB"; meshB.meshRef() = makeCube();
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    doc.layers ~= meshB;
    doc.layers ~= empty;                               // [MeshA(primary), MeshB, Empty]
    assert(doc.primary is meshA);

    // "Click the Empty row" — an exclusive select of a non-mesh target moves
    // FOCUS only (§L2); primary is untouched.
    doc.selectItem(empty, SelMode.Set);
    assert(doc.focusedItem is empty, "setup: clicking Empty moves focus to it");
    assert(doc.primary is meshA, "setup: primary correctly stays on MeshA");

    // Sanity: this is EXACTLY the split the old code could not see — the
    // buggy formula (`document.activeIndex`) targets a DIFFERENT layer than
    // the one the panel highlights as active (`focusedItem`).
    assert(doc.activeIndex == 0,
        "sanity: the OLD buggy formula (activeIndex) points at MeshA, the "
        ~ "primary — not the row the user just clicked");

    auto state = layerDeleteButtonState(&doc);
    assert(state.index == doc.indexOf(empty),
        "blocker 2 fix: the Delete button must target the FOCUSED row "
        ~ "(Empty), not document.activeIndex (MeshA)");
    assert(state.index != doc.activeIndex,
        "blocker 2 fix: the fixed target must differ from the old buggy "
        ~ "target in exactly this split-focus scenario");
    assert(state.enabled,
        "deleting a non-mesh layer is always allowed here — two "
        ~ "canBePrimary layers (MeshA, MeshB) remain either way");

    // Actually perform the delete the fixed panel code would dispatch —
    // `{"index": state.index}` — and assert WHICH layer is gone.
    auto v = new View(0, 0, 800, 600);
    auto del = new LayerDelete(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    del.indexArg = cast(int) state.index;
    assert(del.apply(), "delete of the focused (non-mesh) row must succeed");

    assert(doc.layers.length == 2, "exactly one layer removed");
    assert(doc.layers[0] is meshA && doc.layers[1] is meshB,
        "blocker 2: MeshA AND MeshB both survive — only the highlighted "
        ~ "(focused) Empty row was deleted, not the primary");
    assert(doc.primary is meshA,
        "primary is untouched — it was never the delete target");
}

// ---------------------------------------------------------------------------
// In-module unit test (P3): LayerAttr write/query/revert + coalescing.
//
// The HTTP-driven coalescing assertion in tests/test_layer_params.d already
// proves merging end-to-end through recordCoalescing(). This unittest locks the
// compareOp/mergeFrom CONTRACT directly (so a future refactor that breaks the
// merge shape fails here even without a running server) and verifies the
// write/query/revert single-attr round-trip against a live Document.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;
    import std.json   : JSONValue, JSONType;
    import std.math   : isClose;
    import std.conv   : to;
    import std.string : indexOf;

    auto doc  = Document.bootstrap(makeCube());
    auto v    = new View(0, 0, 800, 600);
    auto mPtr = doc.activeMesh();

    LayerAttr mk() {
        return new LayerAttr(mPtr, v, EditMode.Vertices, &doc, null);
    }

    // ---- write + revert round-trip on one attr ------------------------------
    {
        auto c = mk();
        c.setIndex(0);
        c.setAttrName("pos.x");
        c.setAttrValue(JSONValue(1.5));
        assert(c.apply(), "write apply");
        assert(isClose(doc.layers[0].xform.pos.x, 1.5f, 1e-6f),
               "write mutated the layer field through the param pointer");
        assert(c.revert(), "revert");
        assert(isClose(doc.layers[0].xform.pos.x, 0.0f, 1e-6f),
               "revert restored the prior value");
    }

    // ---- query (read-back) mutates nothing ----------------------------------
    {
        doc.layers[0].xform.pos.y = 2.25f;
        auto q = mk();
        q.setIndex(0);
        q.setAttrName("pos.y");
        q.setQuery(true);
        assert(q.isQuery());
        assert(q.apply(), "query apply");
        assert(q.queryResult().type == JSONType.float_);
        assert(isClose(q.queryResult().floating, 2.25, 1e-6), "query boxed live value");
        assert(isClose(doc.layers[0].xform.pos.y, 2.25f, 1e-6f), "query did not mutate");
    }

    // ---- unknown attr is a graceful error (no crash) ------------------------
    {
        auto bad = mk();
        bad.setIndex(0);
        bad.setAttrName("does.not.exist");
        bad.setAttrValue(JSONValue(1.0));
        bool threw = false;
        try { bad.apply(); } catch (Exception) { threw = true; }
        assert(threw, "unknown attr throws (caught by dispatcher), no crash");
    }

    // ---- coalescing: same (index, attr) merges; keep prior, adopt latest ----
    {
        auto first = mk();
        first.setIndex(0);
        first.setAttrName("pos.z");
        first.setAttrValue(JSONValue(1.0));
        assert(first.apply());
        // first.priorValue_ now holds the value BEFORE the run (0.0).

        auto second = mk();
        second.setIndex(0);
        second.setAttrName("pos.z");
        second.setAttrValue(JSONValue(2.0));
        assert(second.apply());

        // second is COMPATIBLE with first (same layer + attr).
        assert(second.compareOp(first) == CompareResult.Compatible,
               "same (index, attr) coalesces");
        // mergeFrom on the KEPT top entry (first) adopts second's value while
        // keeping first's prior-value (the revert target).
        assert(first.mergeFrom(second), "mergeFrom downcasts + folds");
        assert(isClose(first.attrValue_.floating, 2.0, 1e-6),
               "merged entry adopts the latest written value");
        assert(isClose(first.priorValue_.floating, 0.0, 1e-6),
               "merged entry keeps the pre-run value as the revert target");
        // One undo of the merged entry restores the pre-run value.
        assert(first.revert());
        assert(isClose(doc.layers[0].xform.pos.z, 0.0f, 1e-6f),
               "single undo of the coalesced run unwinds to pre-run");
    }

    // ---- a DIFFERENT attr does NOT coalesce ---------------------------------
    {
        auto px = mk(); px.setIndex(0); px.setAttrName("pos.x"); px.setAttrValue(JSONValue(3.0)); assert(px.apply());
        auto py = mk(); py.setIndex(0); py.setAttrName("pos.y"); py.setAttrValue(JSONValue(4.0)); assert(py.apply());
        assert(py.compareOp(px) == CompareResult.Different,
               "different attr breaks the coalescing run");
    }

    // ---- revert() is a WRITE, and gets the band too (Phase 5 review, B3) ----
    //
    // apply() sanitises; revert() re-injects `priorValue_` and used to do so
    // RAW. That is only harmless while every prior value is guaranteed legal —
    // which is exactly the guarantee the guard is not allowed to assume. The
    // fixture pokes the field directly to stand in for the value's real source
    // (a document written before the guard existed, or reached by a path added
    // later); the WRITE then repairs the layer, and the UNDO must not put the
    // singular value back.
    {
        doc.layers[0].xform.scl.x = 0.0f;         // pre-guard document state

        auto c = mk();
        c.setIndex(0);
        c.setAttrName("scl.x");
        c.setAttrValue(JSONValue(2.0));
        assert(c.apply(), "write apply");
        assert(isClose(doc.layers[0].xform.scl.x, 2.0f, 1e-6f),
               "the write landed");

        assert(c.revert(), "revert");
        assert(doc.layers[0].xform.scl.x == MIN_ITEM_SCALE_MAG,
               "undo must restore the prior value THROUGH the band: a raw "
             ~ "re-injection lands 0 and hands back the singular ItemXform "
             ~ "apply() had just repaired. Got "
             ~ doc.layers[0].xform.scl.x.to!string);

        // Sign side of the same rule: the mirror survives the undo.
        doc.layers[0].xform.scl.y = -1e-9f;
        auto c2 = mk();
        c2.setIndex(0);
        c2.setAttrName("scl.y");
        c2.setAttrValue(JSONValue(3.0));
        assert(c2.apply());
        assert(c2.revert());
        assert(doc.layers[0].xform.scl.y == -MIN_ITEM_SCALE_MAG,
               "an undo that repairs must keep the sign — clamping to +floor "
             ~ "un-mirrors the item. Got "
             ~ doc.layers[0].xform.scl.y.to!string);
    }

    // ---- a READONLY attr rejects the WRITE but still answers a `?` query ----
    // `filename` (Image kind, payload-bearing — layer_params.d) is the only
    // readonly Param reachable through layer.attr today.
    //
    // Discriminating: `injectParamsInto` is a generic typed-pointer writer
    // that never consults `readonly_`, so BEFORE the gate in apply() this
    // write SUCCEEDED and mutated storedPath. The assertion that pins the fix
    // is therefore the UNCHANGED value, not the throw — a bare "it threw"
    // would fire just as happily if the param had gone missing entirely
    // (which is what the `?` read-back above rules out).
    {
        import document : ImageData;

        auto imgLayer = new Layer;
        imgLayer.name = "logo";
        imgLayer.kind = ItemKind.Image;
        imgLayer.imageRef() = new ImageData();
        imgLayer.imageRef().storedPath = "assets/logo.png";
        doc.layers ~= imgLayer;
        immutable int imgIdx = cast(int)(doc.layers.length - 1);

        // Readonly means UNWRITABLE, not invisible: the `?` read-back path is
        // upstream of the gate and still boxes the live value.
        auto q = mk();
        q.setIndex(imgIdx);
        q.setAttrName("filename");
        q.setQuery(true);
        assert(q.apply(), "a readonly attr is still READABLE via ?");
        assert(q.queryResult().str == "assets/logo.png",
               "the ? query boxes the live storedPath (the param exists)");

        // The write is rejected...
        auto w = mk();
        w.setIndex(imgIdx);
        w.setAttrName("filename");
        w.setAttrValue(JSONValue("evil.png"));
        bool threw = false;
        try { w.apply(); } catch (Exception) { threw = true; }
        assert(threw, "writing a readonly attr through layer.attr throws");
        // ...and nothing moved — the half that actually discriminates.
        assert(imgLayer.imageOrNull.storedPath == "assets/logo.png",
               "a REJECTED readonly write leaves the field untouched");

        // The gate is PER-PARAM, not "image layers are read-only": a writable
        // channel on the very same layer still writes.
        auto ok = mk();
        ok.setIndex(imgIdx);
        ok.setAttrName("colorspace");
        ok.setAttrValue(JSONValue("sRGB"));
        assert(ok.apply(), "a writable channel on the same layer still writes");
        assert(imgLayer.imageOrNull.colorspace == "sRGB",
               "the readonly gate is scoped to the param, not the layer");

        // An UNKNOWN name on a readonly-bearing layer still reports "unknown",
        // not "read-only" — the gate sits AFTER the resolve.
        auto unk = mk();
        unk.setIndex(imgIdx);
        unk.setAttrName("filenam");     // typo, not a readonly param
        unk.setAttrValue(JSONValue("x"));
        string msg;
        try { unk.apply(); } catch (Exception e) { msg = e.msg; }
        assert(msg.length && msg.indexOf("unknown attribute") >= 0,
               "an unknown name is still reported as unknown, not read-only");
    }
}

// ---------------------------------------------------------------------------
// In-module unit tests — LayerParent: set/clear, self-parent guard, cycle
// guard, delete-clears-child, undo-delete-restores-child, reset-clears.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    import view : View;

    // Build a 3-layer doc: layer 0 = A (primary), 1 = B, 2 = C.
    auto doc = Document.bootstrap(makeCube());
    auto b = new Layer; b.name = "B"; doc.layers ~= b;
    auto c = new Layer; c.name = "C"; doc.layers ~= c;
    doc.setActive(0);
    auto a = doc.layers[0];
    auto mPtr = doc.activeMesh();

    LayerParent mkPar(int child, int parent_) {
        auto v = new View(0, 0, 800, 600);
        auto cmd = new LayerParent(mPtr, v, EditMode.Vertices, &doc, null);
        cmd.childArg  = child;
        cmd.parentArg = parent_;
        return cmd;
    }
    // set: B's parent = A
    assert(mkPar(1, 0).apply(), "set B parent=A");
    assert(b.parent is a, "B.parent is A after set");

    // revert: B's parent cleared back to null.
    // First clear B.parent so prevParent_ captures null before re-applying.
    {
        mkPar(1, -1).apply();    // clear to null first
        auto cmd = mkPar(1, 0);
        cmd.apply();
        assert(b.parent is a, "apply must set B.parent = A");
        assert(cmd.revert(), "revert LayerParent");
        assert(b.parent is null, "revert clears B.parent");
        // restore for further tests
        mkPar(1, 0).apply();
    }

    // self-parent guard
    assert(!mkPar(0, 0).apply(), "self-parent must be rejected");

    // cycle guard: set A parent=B, then try B parent=A (A is already parent of B)
    {
        // Start clean: no parent links so mkPar(0,1) can succeed.
        mkPar(1, -1).apply();   // clear B.parent
        assert(mkPar(0, 1).apply(), "A.parent=B must succeed (no cycle yet)");
        assert(!mkPar(1, 0).apply(), "cycle B→A must be rejected when A.parent=B");
        // clean up
        mkPar(0, -1).apply();   // clear A.parent
    }

    // clear: parentArg=-1
    mkPar(1, 0).apply();            // ensure B.parent = A
    assert(b.parent is a);
    mkPar(1, -1).apply();
    assert(b.parent is null, "clear via parentArg=-1");

    // delete-clears-child + undo-delete-restores-child
    mkPar(1, 0).apply();            // B.parent = A again
    assert(b.parent is a);

    // Delete A (layer index 0) — B's parent should be cleared
    auto v2 = new View(0, 0, 800, 600);
    auto del = new LayerDelete(mPtr, v2, EditMode.Vertices, &doc, null);
    del.indexArg = 0;
    assert(del.apply(), "delete layer 0 (A)");
    assert(b.parent is null, "delete cleared B.parent");

    // Undo the delete — B.parent must be restored to A
    assert(del.revert(), "undo delete");
    // A should be back in layers
    bool foundA = false;
    foreach (l; doc.layers) if (l is a) { foundA = true; break; }
    assert(foundA, "A restored after undo-delete");
    assert(b.parent is a, "undo-delete restored B.parent = A");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 6 (Ph3): the consumer → item link under the two commands
// that move items around. Both fixtures carry THREE image items and TWO
// consumers on purpose — with one of each, "resolved to the right image" and
// "resolved to the only image" are the same observation.
// ---------------------------------------------------------------------------

version (unittest) {
    private Layer mkLinkTestClip(string n) {
        auto l = new Layer; l.kind = ItemKind.Image; l.name = n; return l;
    }
    private Layer mkLinkTestConsumer(string n) {
        auto l = new Layer; l.kind = ItemKind.Empty; l.name = n; return l;
    }
}

unittest {  // layer.delete on a MIDDLE image that two consumers still point
            // at: the delete succeeds, both links report themselves dangling
            // rather than crashing or sliding onto the item that took the
            // vacated slot, and undo relinks both to ONE object with no
            // recorded link list to restore.
    import mesh : makeCube;
    import view : View;

    auto doc   = Document.bootstrap(makeCube());
    auto clipA = mkLinkTestClip("clipA");
    auto clipB = mkLinkTestClip("clipB");
    auto clipC = mkLinkTestClip("clipC");
    auto cx    = mkLinkTestConsumer("consumerX");
    auto cy    = mkLinkTestConsumer("consumerY");
    doc.layers ~= [clipA, clipB, clipC, cx, cy];   // [mesh, A, B, C, X, Y]
    cx.setLink("backdropImage", clipB);
    cx.setLink("maskImage",     clipC);
    cy.setLink("backdropImage", clipB);

    auto v   = new View(0, 0, 800, 600);
    auto del = new LayerDelete(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    del.indexArg = 2;                     // clipB — a MIDDLE layer, not the tail
    assert(doc.layers[2] is clipB, "fixture: index 2 is clipB");
    assert(del.apply(), "deleting an image two consumers reference must SUCCEED");

    assert(doc.layers.length == 5,
        "vacuity guard: the item list is still non-empty, so 'dangling' cannot "
        ~ "be an index clamped into an empty range");
    assert(doc.layers[3] is cx,
        "vacuity guard: the middle delete moved consumerX into clipC's old slot 3");

    assert(cx.link("backdropImage").state(doc) == LinkState.Dangling,
        "the deleted image's consumer reports Dangling");
    assert(cy.link("backdropImage").state(doc) == LinkState.Dangling,
        "…BOTH consumers, not just the first one reached");
    assert(cx.link("backdropImage").resolve(doc) is null);
    assert(cy.link("backdropImage").resolve(doc) is null);
    assert(cx.link("maskImage").resolve(doc) is clipC,
        "the untouched slot still resolves to clipC — by object, not by the "
        ~ "slot number clipC used to occupy");

    Layer[] refs;
    doc.referrersOf(clipB, refs);
    assert(refs.length == 2 && refs[0] is cx && refs[1] is cy,
        "the reverse sweep still names both consumers of the deleted image");

    // --- undo ---------------------------------------------------------------
    assert(del.revert(), "revert must succeed");
    assert(doc.layers.length == 6 && doc.layers[2] is clipB,
        "revert reinserts the SAME object at its original slot");
    auto xBack = cx.link("backdropImage").resolve(doc);
    auto yBack = cy.link("backdropImage").resolve(doc);
    assert(xBack is clipB && yBack is clipB, "undo relinks both consumers");
    assert(xBack is yBack,
        "…to one and the SAME object — an implementation that restored two "
        ~ "links onto two objects would pass a 'both non-null' check");
    assert(cx.link("backdropImage").state(doc) == LinkState.Live);
}

unittest {  // layer.duplicate carries the clone's OUTGOING links: same target
            // by identity, independent slot set.
    import mesh : makeCube;
    import view : View;

    auto doc   = Document.bootstrap(makeCube());
    auto clipA = mkLinkTestClip("clipA");
    auto clipB = mkLinkTestClip("clipB");
    auto cx    = mkLinkTestConsumer("consumerX");
    doc.layers ~= [clipA, clipB, cx];              // [mesh, A, B, X]
    cx.setLink("backdropImage", clipB);            // the SECOND clip, so
                                                   // "points at the only clip"
                                                   // cannot pass this test

    auto v   = new View(0, 0, 800, 600);
    auto dup = new LayerDuplicate(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    dup.indexArg = 3;                              // duplicate the consumer
    assert(dup.apply(), "duplicate must succeed");

    auto clone = dup.added;
    assert(clone !is cx, "the clone is a new object");
    assert(clone.link("backdropImage").resolve(doc) is clipB,
        "the clone kept the link, and it points at clipB");
    assert(clone.link("backdropImage").resolve(doc)
            is cx.link("backdropImage").resolve(doc),
        "source and clone resolve to the SAME image object");

    // Independent slot SET, shared TARGET — re-pointing one must not move the
    // other. (Without the `.dup` in copyLinksFrom this writes through.)
    clone.setLink("backdropImage", clipA);
    assert(cx.link("backdropImage").resolve(doc) is clipB,
        "re-pointing the clone must not write through into the source");
    assert(clone.link("backdropImage").resolve(doc) is clipA);
}
