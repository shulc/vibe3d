module vibe3d.apps.desktop.commands.symmetry.toggle;

import vibe3d.editing.commands.runtime.command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;

import vibe3d.editing.pipeline.runtime.toolpipe.pipeline         : g_pipeCtx;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.symmetry  : SymmetryStage;
import vibe3d.editing.pipeline.runtime.toolpipe.stage            : TaskCode;

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
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    protected override bool applyImpl() {
        if (g_pipeCtx is null)
            throw new Exception("symmetry.toggle: pipeline not initialised");
        auto sym = cast(SymmetryStage)
                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
        if (sym is null)
            throw new Exception("symmetry.toggle: SYMM stage not registered");
        sym.setAttr("enabled", sym.enabled ? "false" : "true");
        return true;
    }
}
