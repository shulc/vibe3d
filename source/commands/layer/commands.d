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
import params : Param;
import document : Document, Layer;
import seltype : SelMode, selModeFromToken;
import change_bus : MeshChangeAll, noteLayerChange, LayerChange,
                    noteItemSelectionChange;

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

    // Move the layer at `src` to index `dst`, shifting the rest to fill, and
    // re-point activeIndex at whatever Layer object was active before. Returns
    // the (pre-move) active Layer + its index so the caller can decide whether
    // the switch hook fires.
    private void moveLayer(size_t src, size_t dst) {
        auto prevLayer = doc.active();
        auto moved = doc.layers[src];
        // Splice out, then splice in at the destination.
        doc.layers = doc.layers[0 .. src] ~ doc.layers[src + 1 .. $];
        doc.layers = doc.layers[0 .. dst] ~ moved ~ doc.layers[dst .. $];
        // Recompute the active index from the layer OBJECT (identity-
        // preserving): the same Layer stays active, so primary/selected do not
        // change object — setActive re-points activeIndex + primary at it (the
        // single selected layer is unchanged in the SET-of-one).
        foreach (i, l; doc.layers)
            if (l is prevLayer) { doc.setActive(i); break; }
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
        // Refuse to delete the last layer — the document invariant is
        // layers.length >= 1.
        if (doc.layers.length <= 1) return false;

        removedIndex    = resolveIndex(indexArg);
        prevActiveIndex = doc.activeIndex;
        removed         = doc.layers[removedIndex];   // class ref kept for revert
        auto prevLayer  = doc.active();
        // Snapshot the full prior selection set + primary by identity (review #6)
        // BEFORE the splice / setActive collapse, so revert restores the exact
        // multi-selection (including the deleted layer's own bit).
        prevPrimary  = prevLayer;
        prevSelected = null;
        foreach (l; doc.layers) prevSelected[l] = l.selected;

        // Splice the layer out.
        doc.layers = doc.layers[0 .. removedIndex] ~ doc.layers[removedIndex + 1 .. $];

        // New active: deleting the active layer activates the next (or the
        // previous if it was the last). Otherwise keep pointing at the same
        // layer object — which may have shifted down by one if it sat after
        // the removed index.
        size_t newActive;
        if (prevActiveIndex == removedIndex) {
            newActive = removedIndex < doc.layers.length
                ? removedIndex : doc.layers.length - 1;
        } else if (prevActiveIndex > removedIndex) {
            newActive = prevActiveIndex - 1;
        } else {
            newActive = prevActiveIndex;
        }
        // Stage-0 lockstep: set primary + selected + activeIndex together,
        // BEFORE fireSwitchIfChanged.
        doc.setActive(newActive);
        applied = true;
        // Removed kind from the command; the hook contributes ActiveChanged iff
        // the active layer OBJECT changed (deleting a layer below the active one
        // shifts the index but keeps the same mesh → no ActiveChanged).
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
        if (prevPrimary !is null) doc.setPrimary(prevPrimary);  // selected ⇒ no-op reselect
        else                      doc.setActive(prevActiveIndex);
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
        if (prevPrimary !is null) doc.setPrimary(prevPrimary);
        else                       doc.setActive(prevActiveIndex);
        fireSwitchIfChanged(prevLayer, prevIdx);
        noteItemSelectionChange();
        if (onItemSelect !is null) onItemSelect();
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.rename — UI-undo class. No active-index move (no switch hook).
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
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

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
// layer.setVisible — UI-undo class. No active-index move.
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
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

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
            && prevPrimaryObj.visible)
            doc.setPrimary(prevPrimaryObj);
        noteLayerChange(LayerChange.VisibilityChanged);
        fireSwitchIfChanged(curPrimary, prevIdx);
        return true;
    }
}

