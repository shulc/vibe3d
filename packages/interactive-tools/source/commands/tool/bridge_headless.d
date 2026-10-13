module commands.tool.bridge_headless;

import commands.tool.headless : ToolHeadlessCommand;
import editmode : EditMode;
import mesh : Mesh;
import registry : ToolFactory;
import tools.edit.bridge_tool : BridgeTool;
import view : View;

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
