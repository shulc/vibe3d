module tests.unit.commands.ui.layout_reset_test;

import command_history : CommandHistory;
import commands.ui.layout_reset : UiLayoutResetCommand;
import editmode : EditMode;
import mesh : Mesh;
import view : View;

unittest {
    Mesh mesh;
    View view;
    size_t resets;
    auto command = new UiLayoutResetCommand(
        &mesh, view, EditMode.Polygons, () { ++resets; });
    auto history = new CommandHistory;
    const before = history.undoEntries.length;
    assert(command.name == "layout.reset" && command.label == "Reset Layout",
        "6245 F4d command identity changed");
    assert(command.apply() && resets == 1,
        "6245 F4d layout.reset did not author exactly one reset");
    history.record(command);
    assert(!command.isUndoable && history.undoEntries.length == before,
        "6245 F4d SideEffect command entered undo history");
}
