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
//   layer.setBackground — UI-undo class
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
import change_bus : MeshChangeAll;

// ---------------------------------------------------------------------------
// Shared base — owns the Document* and the switch hook.
// ---------------------------------------------------------------------------

private abstract class LayerCommandBase : Command {
    protected Document* doc;
    // Active-layer-switch hook (installed by app.d). Null in unit-test
    // construction; commands that move activeIndex no-op the display side then.
    protected void delegate(size_t prev, size_t next) onSwitch;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc      = doc;
        this.onSwitch = onSwitch;
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
        l.background = false;
        doc.layers ~= l;
        addedIndex  = doc.layers.length - 1;
        doc.activeIndex = addedIndex;
        applied = true;
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
        doc.activeIndex = prevActiveIndex >= doc.layers.length
            ? doc.layers.length - 1 : prevActiveIndex;
        fireSwitchIfChanged(prevLayer, prevIdx);
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
        doc.activeIndex = newActive;
        applied = true;
        // The hook fires iff the active layer OBJECT changed (deleting a layer
        // below the active one shifts the index but keeps the same mesh).
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
        doc.activeIndex = prevActiveIndex >= doc.layers.length
            ? doc.layers.length - 1 : prevActiveIndex;
        fireSwitchIfChanged(prevLayer, prevIdx);
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.select — set the active layer. UI-undo class.
// ---------------------------------------------------------------------------

final class LayerSelect : LayerCommandBase {
    private int    indexArg = 0;
    private size_t prevActiveIndex;
    private size_t newActiveIndex;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.select"; }
    override string label() const { return "Select Layer"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, 0) ];
    }

    override bool apply() {
        prevActiveIndex = doc.activeIndex;
        auto prevLayer  = doc.active();
        newActiveIndex  = resolveIndex(indexArg);
        doc.activeIndex = newActiveIndex;
        applied = true;
        fireSwitchIfChanged(prevLayer, prevActiveIndex);
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        auto prevLayer = doc.active();
        size_t prevIdx = doc.activeIndex;
        doc.activeIndex = prevActiveIndex >= doc.layers.length
            ? doc.layers.length - 1 : prevActiveIndex;
        fireSwitchIfChanged(prevLayer, prevIdx);
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
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        doc.layers[target].name = prevName;
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
        doc.layers[target].visible = valueArg;
        applied = true;
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        doc.layers[target].visible = prevVal;
        return true;
    }
}

// ---------------------------------------------------------------------------
// layer.setBackground — UI-undo class. No active-index move.
// ---------------------------------------------------------------------------

final class LayerSetBackground : LayerCommandBase {
    private int    indexArg = -1;     // -1 → active
    private bool   valueArg = true;
    private size_t target;
    private bool   prevVal;
    private bool   applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode, doc, onSwitch);
    }

    override string name()  const { return "layer.setBackground"; }
    override string label() const { return "Set Layer Background"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.int_("index", "Index", &indexArg, -1),
                 Param.bool_("value", "Background", &valueArg, true) ];
    }

    override bool apply() {
        target  = resolveIndex(indexArg);
        prevVal = doc.layers[target].background;
        doc.layers[target].background = valueArg;
        applied = true;
        return true;
    }

    override bool revert() {
        if (!applied) return false;
        doc.layers[target].background = prevVal;
        return true;
    }
}
