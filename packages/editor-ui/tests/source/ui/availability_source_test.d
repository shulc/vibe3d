module ui.availability_source_test;

import ui.availability;
import buttonset : Action, ActionKind, Button;
import registry : Registry;
import vibe3d.editing.contracts.editmode : EditMode;

unittest {
    import command  : Command, kNoEditTargetReason;
    import tool     : Tool;
    import vibe3d.mesh.core.mesh     : Mesh;
    import vibe3d.viewport.camera.view     : View;
    import vibe3d.editing.contracts.editmode : EditMode;

    static final class NeedsCmd : Command {
        private Mesh  _m;
        private View  _v = new View(0, 0, 1, 1);
        this() { super(&_m, _v, EditMode.Vertices); }
        override string name() const { return "test.needs"; }
        override bool needsEditTarget() const { return true; }
    }
    static final class FreeCmd : Command {
        private Mesh  _m;
        private View  _v = new View(0, 0, 1, 1);
        this() { super(&_m, _v, EditMode.Vertices); }
        override string name() const { return "test.free"; }
        override bool needsEditTarget() const { return false; }
    }
    static final class NeedsTool : Tool {
        override bool needsEditTarget() const { return true; }
    }

    Registry reg;
    reg.commandNeedsTarget["test.needs"] = true;
    reg.commandNeedsTarget["test.free"]  = false;
    reg.toolNeedsTarget["test.tool"]     = true;

    // WITH a target nothing is refused — the both-sides half. An
    // implementation that greys everything always fails right here.
    {
        auto a = Action(ActionKind.command, "test.needs");
        assert(actionRefusal(reg, a, true, "") == "");
        auto t = Action(ActionKind.tool, "test.tool");
        assert(actionRefusal(reg, t, true, "") == "");
    }
    // WITHOUT one, only what declared the requirement is refused.
    {
        auto need = Action(ActionKind.command, "test.needs");
        assert(actionRefusal(reg, need, false, "") == kNoEditTargetReason);
        auto free = Action(ActionKind.command, "test.free");
        assert(actionRefusal(reg, free, false, "") == "");
        auto unknown = Action(ActionKind.command, "test.never.registered");
        assert(actionRefusal(reg, unknown, false, "") == "");
    }
    // The armed tool's own button stays live: pressing it DROPS the tool, and
    // dropping never needed a target.
    {
        auto t = Action(ActionKind.tool, "test.tool");
        assert(actionRefusal(reg, t, false, "")          == kNoEditTargetReason);
        assert(actionRefusal(reg, t, false, "test.tool") == "");
        assert(actionRefusal(reg, t, false, "other")     == kNoEditTargetReason);
    }
    // A script is refused by any one of its lines. This is the ctrl-variant
    // path ("Unit Box" et al. in config/buttons.yaml) — a `kind: script`
    // button whose one line dispatches a command id — and it has no HTTP
    // counterpart, because the frame record only carries the variant the
    // unmodified button shows.
    {
        Action s;
        s.kind = ActionKind.script;
        s.scriptLines = ["test.free a:1", "test.needs b:2"];
        assert(actionRefusal(reg, s, false, "") == kNoEditTargetReason,
            "a script whose SECOND line would refuse was reported available. "
            ~ "A script is dispatched line by line with no rollback, so a run "
            ~ "that stops partway is not 'mostly available'. Got: '"
            ~ actionRefusal(reg, s, false, "") ~ "'");
        s.scriptLines = ["test.free a:1"];
        assert(actionRefusal(reg, s, false, "") == "",
            "a script none of whose lines needs a target was refused");
    }
    // A popup always opens.
    {
        Action p;
        p.kind = ActionKind.popup;
        assert(actionRefusal(reg, p, false, "") == "");
    }
    // The defaults the two base classes declare, off real instances: a
    // non-Operator command needs nothing, every tool needs a target.
    assert(!(new FreeCmd()).needsEditTarget());
    assert((new NeedsCmd()).needsEditTarget());
    assert((new NeedsTool()).needsEditTarget());
    assert((new class Tool {}).needsEditTarget(),
        "Tool.needsEditTarget() must default to true — a tool binds Mesh* when "
        ~ "it arms");
}
