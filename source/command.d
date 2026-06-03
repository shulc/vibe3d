module command;

import mesh;
import view;
import editmode;
import params : Param, ParamHints;

// ---------------------------------------------------------------------------
// Command — base class for every user-visible action.
//
// Undo/redo model (see doc/undo_redo_plan.md):
// - apply()    — runs the operation. Mutating commands MUST snapshot
//                pre-state into instance fields here.
// - revert()   — restore the pre-apply state (using the snapshot).
//                Default: no-op (returns false). Mutating commands MUST
//                override and return true on successful revert.
// - cmdFlags() — bitfield classifying the command (see CmdFlags).
//                Undoability is DERIVED from it: a command is undoable
//                iff its flags carry CmdFlags.Model. Read-only /
//                non-mutating commands override cmdFlags() to drop Model;
//                the dispatcher then skips pushing to the undo stack.
// - label()    — short human-readable text for the Edit menu / history
//                viewer ("Bevel edges", "Move 3 verts"). Defaults to
//                name().
// ---------------------------------------------------------------------------

// Bitfield classifying a command's effect on the application. The
// undo dispatcher and history panel read these bits; behaviour for any
// single command is determined entirely by which bits are set.
enum CmdFlags : uint {
    None       = 0,
    Model      = 1 << 0, // Alters scene/document (mesh) state → undoable.
    UI         = 1 << 1, // Alters UI/view state only (camera, panels) — no undo entry.
    Quiet      = 1 << 2, // Suppress logging / notification for this command.
    SideEffect = 1 << 3, // Transient session/tool-pipe change — no undo entry.
}

// Result of comparing a freshly-applied command against the command that
// currently sits on top of the undo stack. `Compatible` means the new command
// is a CONTINUATION of the previous one (same logical edit, same targets) and
// should be MERGED into the existing top entry rather than appended as a new
// step — so a run of repeated identical-target edits collapses to one undo.
// `Different` (the default for every command) means "append normally". Only
// commands that explicitly opt in by overriding compareOp() ever coalesce; the
// merge mechanism is driven by CommandHistory.recordCoalescing().
enum CompareResult { Different, Compatible }

class Command {
    // Internal command id (e.g. "mesh.bevel"). Used by the dispatcher.
    string name() const { return "Command"; }

    // Run the operation. Two paths post-Phase-6:
    //
    //   * Operator commands (mesh-mutating ones from Phases 2/5) put
    //     their kernel in `evaluate(ref VectorStack vts)`. The default
    //     apply() here builds a minimal vts from the command's mesh +
    //     editMode + selection state and dispatches via the Operator
    //     interface, preserving the bool-return contract for callers
    //     (history.fire, app.d /api/command).
    //
    //   * Non-Operator commands (file load/save, history meta-commands,
    //     selection ops) override apply() with their kernel as before.
    //
    // Mutating commands snapshot pre-state into instance fields so
    // revert() can restore.
    bool apply() {
        import operator        : Operator, VectorStack;
        import toolpipe.packets : SubjectPacket;
        if (auto op = cast(Operator)this) {
            VectorStack vts;
            SubjectPacket subj;
            subj.mesh     = mesh;
            subj.editMode = editMode;
            vts.put(&subj);
            return op.evaluate(vts);
        }
        return true;
    }

    // Restore the pre-apply mesh/selection/state. Default: not undoable.
    // Mutating commands override and return true on success.
    bool revert() { return false; }

    // Classify the command. BASE default is CmdFlags.Model — most
    // commands alter scene state and are therefore undoable. Read-only /
    // view-only / transient commands override this to drop Model (and
    // pick UI or SideEffect as appropriate).
    CmdFlags cmdFlags() const { return CmdFlags.Model; }

    // Whether this command should land on the undo stack after a
    // successful apply(). Derived from cmdFlags(): a command is undoable
    // iff it alters scene/document state (carries CmdFlags.Model). Kept
    // as a final accessor so existing call sites need not change.
    final bool isUndoable() const { return (cmdFlags() & CmdFlags.Model) != 0; }

    // Short human-readable label. Defaults to name() — override for a
    // friendlier menu / history-viewer string.
    string label() const { return name(); }

    // Coalescing predicate (op-merge analog). Called by
    // CommandHistory.recordCoalescing() with `prev` = the command on top of
    // the undo stack. Return Compatible iff `this` is a continuation of `prev`
    // that should merge into the existing top entry (so consecutive compatible
    // edits become ONE undo step). Default: Different — no command coalesces
    // unless it overrides this. A Compatible verdict obliges the command to
    // also implement an in-place merge (e.g. mergeFrom()) that the history
    // invokes on `prev`.
    CompareResult compareOp(const Command prev) const {
        return CompareResult.Different;
    }

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
    // cross-field graying (arg-enable callback).
    bool paramEnabled(string name) const { return true; }

    // Per-parameter hint overrides at runtime (e.g. cap a range to mesh
    // size).
    void paramHints(string name, ref ParamHints hints) {}

    // Edit modes in which this command makes sense. The status-bar /
    // side-panel button auto-disables when the current `editMode` is
    // not in this list — visual cue that the row is "available but
    // not in this mode". `apply()` may also throw defensively (e.g.
    // mesh.subdivide enforces Polygons inside apply too). Default:
    // every mode — most commands are mode-agnostic.
    EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        this.mesh = mesh;
        this.view = view;
        this.editMode = editMode;
    }

    // Read-only accessors to the construction context. Needed so a wrapper
    // command in another module (e.g. CompositeCommand in command_history.d)
    // can forward another command's mesh/view/editMode into the base ctor —
    // `protected` fields are only reachable on `this`, not on a sibling
    // instance across module boundaries.
    final Mesh*    meshPtr() { return mesh; }
    final ref View viewRef() { return view; }
    final EditMode editModeVal() const { return editMode; }

protected:
    Mesh* mesh;
    View view;
    EditMode editMode;
};