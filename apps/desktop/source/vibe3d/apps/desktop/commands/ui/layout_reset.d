module vibe3d.apps.desktop.commands.ui.layout_reset;

import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.contracts.editmode;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;

/// Authors a layout reset request. The main loop consumes it before the next
/// ImGui frame because loading ini state during a frame is unsafe (task 6245).
final class UiLayoutResetCommand : Command {
    private void delegate() authorReset_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() authorReset) {
        super(mesh, view, editMode);
        authorReset_ = authorReset;
    }

    override string name() const { return "layout.reset"; }
    override string label() const { return "Reset Layout"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    protected override bool applyImpl() {
        authorReset_();
        return true;
    }
}
