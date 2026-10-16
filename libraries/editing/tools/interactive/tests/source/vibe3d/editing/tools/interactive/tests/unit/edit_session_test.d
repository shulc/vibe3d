// Module unittests for `edit_session`, moved verbatim out of source/edit_session.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.edit_session_test;

import vibe3d.editing.tools.interactive.tool            : Tool;
import vibe3d.editing.commands.runtime.command         : Command;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.tools.interactive.edit_session;

// (The SessionLiveRedo shape pin left with the interface, slice M4: a redo
// that brings back a cancelled live operation is the tool session's own redo
// stash — tests/unit/tool_session_steps_test.d, cells (2)/(3).)

// ---------------------------------------------------------------------------
// Module unittest — phase() classification (no GL / SDL: a bare Tool and a
// bare CommandHistory both construct headlessly).
// ---------------------------------------------------------------------------
unittest {
    Tool held = null;
    auto es = new EditSession(() => held, new CommandHistory(), () {});
    assert(es.phase() == SessionPhase.NoTool);

    held = new Tool();
    assert(es.phase() == SessionPhase.Idle);

    final class OpenEditTool : Tool {
        override bool hasUncommittedEdit() const { return true; }
    }
    held = new OpenEditTool();
    assert(es.phase() == SessionPhase.EditOpen);
}
