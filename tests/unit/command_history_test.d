// Module unittests for `command_history`, moved verbatim out of source/command_history.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.command_history_test;

import command;
import command : CmdFlags;
import argstring : serializeParams, serializeCommandLine;
import perf_probe : g_perf, Cat;
import mesh    : Mesh;
import view    : View;
import editmode : EditMode;
import mesh     : Mesh;
import view     : View;
import std.stdio : writeln;
import command_history;

// task 0678 D9-a (REVERTED) — recordToolLifecycle deliberately does NOT feed
// the macro recorder; see the comment at its emit point for the measurements
// that overturned the original finding. Pin the silence so a future "fix" has
// to re-read that reasoning instead of re-deriving the same broken line.
unittest {
    import mesh : Mesh, makeCube;
    import view : View;
    import editmode : EditMode;
    import commands.tool.lifecycle : ToolDeactivationCommand;

    Mesh m = makeCube();
    View v = new View(0, 0, 800, 600);
    auto hist = new CommandHistory();

    string[] lines;
    hist.onRecord = (string line, uint flags) { lines ~= line; };
    hist.recordToolLifecycle(new ToolDeactivationCommand(&m, v, EditMode.Vertices, "move"));

    assert(lines.length == 0,
           "a tool drop must not reach the macro recorder on its own: the "
           ~ "matching arm step never does either, and `tool.set <id> off` "
           ~ "ignores the id and would drop whatever tool the replay finds armed");
    assert(hist.canUndo(), "the lifecycle entry itself must still be recorded");
}
