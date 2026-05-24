module commands.symmetry.toggle;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline         : g_pipeCtx;
import toolpipe.stages.symmetry  : SymmetryStage;
import toolpipe.stage            : TaskCode;

// ---------------------------------------------------------------------------
// `symmetry.toggle` — flip the SymmetryStage's master enable flag.
// Mirrors the `snap.toggle` pattern; status-bar Symmetry button binds
// click → toggle, alt+click → axis-options popup.
// ---------------------------------------------------------------------------
class SymmetryToggleCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "symmetry.toggle"; }
    override string label() const { return "Toggle Symmetry"; }

    // Pipe configuration is UI state, not a mesh edit.
    override bool isUndoable() const { return false; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("symmetry.toggle: pipeline not initialised");
        auto sym = cast(SymmetryStage)
                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
        if (sym is null)
            throw new Exception("symmetry.toggle: SYMM stage not registered");
        sym.setAttr("enabled", sym.enabled ? "false" : "true");
        return true;
    }

    override bool revert() { return false; }
}
