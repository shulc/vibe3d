// Module unittests for `edit_session`, moved verbatim out of source/edit_session.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.edit_session_test;

import tool            : Tool;
import command         : Command;
import command_history : CommandHistory;
import edit_session;

// SessionLiveRedo is one member (task 7118, gap 232): navigate() asks it, and
// only it, before stepping the redo stack.
static assert([__traits(allMembers, SessionLiveRedo)] == ["tryRedoLiveInSession"],
    "SessionLiveRedo changed shape");

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
