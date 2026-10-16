module vibe3d.editing.tools.interactive.commands.tool.bridge_headless;

import vibe3d.editing.tools.interactive.commands.tool.headless : ToolHeadlessCommand;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.registry : ToolFactory;
import vibe3d.editing.tools.interactive.tools.edit.bridge_tool : BridgeTool;
import vibe3d.viewport.camera.view : View;

// Task 20261600: relay the sole Bridge guard result; generic command refusal
// and invocation-time replacement factories retain their existing contracts.
class BridgeHeadlessCommand : ToolHeadlessCommand {
    this(Mesh* mesh, ref View view, EditMode editMode,
            string toolId, ToolFactory factory) {
        super(mesh, view, editMode, toolId, factory);
    }

    override string refusalReason() const {
        auto base = super.refusalReason();
        if (base.length) return base;
        auto bridge = cast(const BridgeTool) ownedToolInstance();
        return bridge is null ? "" : bridge.headlessRefusalReason();
    }
}
