module commands.snap.toggle;

import command;
import mesh;
import view;
import editmode;

import toolpipe.stages.snap    : heldDragGuideCount, liveSnapStage;

// ---------------------------------------------------------------------------
// `snap.toggle` — flip the SnapStage's master enable flag. Bound to
// `X` (the snap-state toggle).
//
// Hooked up via config/shortcuts.yaml:
//   commands:
//     snap.toggle: X
//
// Argstring takes no args.
// ---------------------------------------------------------------------------
class SnapToggleCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "snap.toggle"; }
    override string label() const { return "Toggle Snap"; }

    // Pipe configuration, not a mesh edit. Its key runs mid-drag iff the drag
    // holds a snap guide and reverts by the hold law; a UI toggle with no button
    // held records one entry whose undo / redo never touch the state
    // (findings_K-G2 / K-G3 G3-s, G3-r; script origin records nothing, gap 563).
    override CmdFlags cmdFlags() const {
        import held_gesture_buttons : g_heldGestureButtons;
        auto f = CmdFlags.SideEffect | CmdFlags.Momentary;
        if (heldDragGuideCount() >= 1) f |= CmdFlags.MouseDownOk;
        if (origin == CommandOrigin.ui && !g_heldGestureButtons.any) f |= CmdFlags.UndoForce;
        return f;
    }

    private bool applied_;
    protected override bool applyImpl() {
        if (applied_) return true;   // redo: inert
        applied_ = true;
        auto sn = liveSnapStage();
        if (sn is null)
            throw new Exception("snap.toggle: SNAP stage not registered");
        sn.setAttr("enabled", sn.enabled ? "false" : "true");
        return true;
    }
}
