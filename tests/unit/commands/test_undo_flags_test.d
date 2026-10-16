// Module unittests for `commands.test_undo_flags`, moved verbatim out of source/commands/test_undo_flags.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.test_undo_flags_test;

import vibe3d.editing.commands.runtime.command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.apps.desktop.commands.test_undo_flags;

unittest {
    import vibe3d.viewport.camera.view : View;
    Mesh m;
    View v;
    auto sup = new UndoSuppressNoop(&m, v, EditMode.Vertices);
    // Model bit present, but UndoSuppress wins → not undoable.
    assert(!sup.isUndoable());

    auto frc = new UndoForceNoop(&m, v, EditMode.Vertices);
    // No Model/UiState bit, but UndoForce opts in → undoable.
    assert(frc.isUndoable());
}
