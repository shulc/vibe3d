module commands.ai3d.generate_test_hooks;

// ---------------------------------------------------------------------------
// ai3d.generate.start / ai3d.generate.cancel — test-only hooks (task 0381
// Phase 2, doc/ai3d_ui_plan.md). Mirror commands/tool/begin_session.d's
// pattern: gated on g_testMode (throws outside --test), CmdFlags.SideEffect
// (no undo entry — starting/cancelling an async job is not a document
// mutation), inert and unreachable in a normal build/run.
//
// There is no production HTTP path to the async Ai3dJobController until the
// Phase 3 modal exists (a live UI picker + Generate/Cancel button click), so
// an automated test needs a bare starter/canceller to drive the app-owned
// controller directly and exercise the per-frame drain + ai3d.importResult
// wiring end-to-end against a real running vibe3d --test process (see
// tests/test_ai3d_ui.d). Neither command touches the controller's HTTP/curl
// transport itself — that only ever happens on the controller's own worker
// thread (ai3d.job_controller).
// ---------------------------------------------------------------------------

import command;
import mesh;
import view;
import editmode;
import params : Param;
import ai3d.job_controller : Ai3dJobController;

final class Ai3dGenerateStartTestCommand : Command {
    private Ai3dJobController controller;
    private string imageArg;
    private string workerUrlArg = "http://127.0.0.1:47831";
    private int timeoutMsArg = 120_000;

    this(Mesh* mesh, ref View view, EditMode editMode, Ai3dJobController controller) {
        super(mesh, view, editMode);
        this.controller = controller;
    }

    override string name()  const { return "ai3d.generate.start"; }
    override string label() const { return "Start AI3D Generate (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [
            Param.string_("image", "Image", &imageArg, ""),
            Param.string_("workerUrl", "Worker URL", &workerUrlArg, "http://127.0.0.1:47831"),
            Param.int_("timeoutMs", "Timeout (ms)", &timeoutMsArg, 120_000),
        ];
    }

    override bool apply() {
        if (!g_testMode)
            throw new Exception("ai3d.generate.start: only available in --test mode");
        if (imageArg.length == 0)
            throw new Exception("ai3d.generate.start: image is required");
        if (!controller.start(imageArg, workerUrlArg, timeoutMsArg))
            throw new Exception("ai3d.generate.start: a job is already in flight");
        return true;
    }

    override bool revert() { return false; }
}

final class Ai3dGenerateCancelTestCommand : Command {
    private Ai3dJobController controller;

    this(Mesh* mesh, ref View view, EditMode editMode, Ai3dJobController controller) {
        super(mesh, view, editMode);
        this.controller = controller;
    }

    override string name()  const { return "ai3d.generate.cancel"; }
    override string label() const { return "Cancel AI3D Generate (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (!g_testMode)
            throw new Exception("ai3d.generate.cancel: only available in --test mode");
        controller.requestCancel();
        return true;
    }

    override bool revert() { return false; }
}
