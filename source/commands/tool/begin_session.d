module commands.tool.begin_session;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;
import tools.transform.xfrm_transform : XfrmTransformTool;

// ---------------------------------------------------------------------------
// ToolBeginSessionCommand — `tool.beginSession`
//
// Test-only (re-eval plan D5, Phase 3). Opens a live edit session on the
// active transform tool WITHOUT changing geometry, leaving
// hasUncommittedEdit()==true so a following raw `tool.attr` write reaches the
// already-live reEvaluate() branch and replays absolutely from the session
// baseline. There is no production HTTP way to leave a session open across two
// attr writes (tool.doApply opens AND commits in one call), so the contract
// tests need this bare opener to reach the live-session branch that production
// hits only via a gizmo drag.
//
// Gated behind g_testMode (set by --test, the same gate /api/play-events uses),
// so it is inert and unreachable in a normal build/run. No-op + error if there
// is no active tool. No undo entry (SideEffect): the session it opens is
// committed (or cancelled) by the usual tool-drop / selection-change guards.
//
// Wire format: no positional args.
// ---------------------------------------------------------------------------
class ToolBeginSessionCommand : Command {
    private ToolHost toolHost;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "tool.beginSession"; }
    override string label() const { return "Open Live Tool Session (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    protected override bool applyImpl() {
        if (!g_testMode)
            throw new Exception(
                "tool.beginSession: only available in --test mode");

        auto t = toolHost.getActiveTool();
        if (t is null)
            throw new Exception("tool.beginSession: no active tool");

        auto xt = cast(XfrmTransformTool) t;
        if (xt is null)
            throw new Exception(
                "tool.beginSession: active tool is not a transform tool");

        xt.openLiveSessionForTest();
        return true;
    }
}

// Test-only companion used to make the missing-call shape of an idle Rotate
// re-grade observable. It clears only the display pin; the held run, geometry,
// action-centre mode, and explicit user pin remain untouched.
class ToolClearSoftPinForTestCommand : Command {
    private ToolHost toolHost;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "tool.clearSoftPinForTest"; }
    override string label() const { return "Clear Transform Soft Pin (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    protected override bool applyImpl() {
        if (!g_testMode)
            throw new Exception(
                "tool.clearSoftPinForTest: only available in --test mode");

        auto xt = cast(XfrmTransformTool) toolHost.getActiveTool();
        if (xt is null)
            throw new Exception(
                "tool.clearSoftPinForTest: active tool is not a transform tool");

        xt.clearSoftPinForTest();
        return true;
    }
}
