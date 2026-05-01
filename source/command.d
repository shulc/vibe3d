module command;

import mesh;
import view;
import editmode;
import params : Param, ParamHints;

// ---------------------------------------------------------------------------
// Command — base class for every user-visible action.
//
// MODO-style undo/redo (see doc/undo_redo_plan.md):
// - apply()    — runs the operation. Mutating commands MUST snapshot
//                pre-state into instance fields here.
// - revert()   — restore the pre-apply state (using the snapshot).
//                Default: no-op (returns false). Mutating commands MUST
//                override and return true on successful revert.
// - isUndoable — false for read-only / non-mutating commands; the
//                dispatcher then skips pushing to the undo stack.
// - label()    — short human-readable text for the Edit menu / history
//                viewer ("Bevel edges", "Move 3 verts"). Defaults to
//                name().
// ---------------------------------------------------------------------------

class Command {
    // Internal command id (e.g. "mesh.bevel"). Used by the dispatcher.
    string name() const { return "Command"; }

    // Run the operation. Mutating commands snapshot pre-state into
    // instance fields here so revert() can restore.
    bool apply() { return true; }

    // Restore the pre-apply mesh/selection/state. Default: not undoable.
    // Mutating commands override and return true on success.
    bool revert() { return false; }

    // Whether this command should land on the undo stack after a
    // successful apply(). Read-only queries / fit-camera / file.save
    // override to return false.
    bool isUndoable() const { return true; }

    // Short human-readable label. Defaults to name() — override for a
    // friendlier menu / history-viewer string.
    string label() const { return name(); }

    // Schema: list of parameters. Default: none. Commands that surface
    // an args dialog or accept JSON params via /api/command override this.
    Param[] params() { return []; }

    // Called immediately before opening an args dialog. Override to set
    // defaults that depend on the current selection / scene state.
    void dialogInit() {}

    // Called by the renderer after a parameter value changes. Override
    // to recompute dependent parameters (cross-field rules).
    void onParamChanged(string name) {}

    // Whether the named parameter widget should be enabled. Override for
    // cross-field graying (MODO-style cmd_ArgEnable).
    bool paramEnabled(string name) const { return true; }

    // Per-parameter hint overrides at runtime (e.g. cap a range to mesh
    // size).
    void paramHints(string name, ref ParamHints hints) {}

    this(Mesh* mesh, ref View view, EditMode editMode) {
        this.mesh = mesh;
        this.view = view;
        this.editMode = editMode;
    }

protected:
    Mesh* mesh;
    View view;
    EditMode editMode;
};