module commands.tool.panel_edit;

import command;
import mesh;
import view;
import editmode;
import math : Vec3;
import commands.tool.host : ToolHost;
import tools.xfrm_transform : XfrmTransformTool;

// ---------------------------------------------------------------------------
// ToolPanelEditCommand — `tool.panelEdit <dx> <dy> <dz>`
//
// Test-only (re-eval plan D5, Phase 3). Invokes
// XfrmTransformTool.applyMovePanelDelta(Vec3(dx,dy,dz)) directly — the REAL
// first-edit panel entry point, which opens its own session + captures
// dragBaseline on the first call. This is the ONLY way to exercise the
// first-edit-opens-session transition headlessly, because that session-open
// lives in applyMovePanelDelta (NOT in any HTTP tool.attr path) and bypasses
// move.d's ImGui slider wrapper (which computes the localDiff from widget
// state). DELTA-driven, matching the legacy slider it stands in for: two
// successive 0.05 deltas accumulate to 0.10 (correct for the delta path; the
// absolute/no-accumulation property belongs to the tool.attr/reEvaluate path).
//
// Gated behind g_testMode (set by --test), so it is inert and unreachable in a
// normal build/run. No undo entry (SideEffect): the session it opens is
// committed by the usual tool-drop / selection-change guards.
//
// Wire format (from argstring / _positional):
//   positional[0] = dx, positional[1] = dy, positional[2] = dz (floats)
// ---------------------------------------------------------------------------
class ToolPanelEditCommand : Command {
    private ToolHost toolHost;
    private Vec3     delta_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
        this.delta_   = Vec3(0, 0, 0);
    }

    override string name()  const { return "tool.panelEdit"; }
    override string label() const { return "Tool Panel Edit (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setDelta(Vec3 d) { delta_ = d; }

    override bool apply() {
        if (!g_testMode)
            throw new Exception(
                "tool.panelEdit: only available in --test mode");

        auto t = toolHost.getActiveTool();
        if (t is null)
            throw new Exception("tool.panelEdit: no active tool");

        auto xt = cast(XfrmTransformTool) t;
        if (xt is null)
            throw new Exception(
                "tool.panelEdit: active tool is not a transform tool");

        xt.applyMovePanelDelta(delta_);
        return true;
    }

    override bool revert() { return false; }
}
