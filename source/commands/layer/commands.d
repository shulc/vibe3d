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
import document : Document, Layer;
import layer_params : LayerPropsProvider;
import seltype : SelMode, selModeFromToken;
import change_bus : MeshChangeAll, noteLayerChange, LayerChange,
                    noteItemSelectionChange;

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

        // Task 0082: collect layers whose parent points at `removed`, snapshot
        // them by identity, then clear their parent to avoid dangling refs.
        orphanedChildren_ = null;
        foreach (l; doc.layers)
            if (l.parent is removed) orphanedChildren_ ~= l;
        foreach (l; orphanedChildren_) l.parent = null;

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
        if (prevPrimary !is null) doc.setPrimary(prevPrimary);
        else                       doc.setActive(prevActiveIndex);
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
            && prevPrimaryObj.visible)
            doc.setPrimary(prevPrimaryObj);
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

        // Write: snapshot the prior value for revert(), then inject the new one
        // through the param's typed pointer (which aliases the live Layer field).
        priorValue_ = paramToJson(*found);
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = attrValue_;
        injectParamsInto(ps, pj);
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
        JSONValue pj = JSONValue(cast(JSONValue[string]) null);
        pj[attrName_] = priorValue_;
        injectParamsInto(ps, pj);
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
    import std.json : JSONValue, JSONType;
    import std.math : isClose;

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
