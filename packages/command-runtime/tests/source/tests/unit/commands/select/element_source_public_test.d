module tests.unit.commands.select.element_source_public_test;

import commands.select.element : SelectElementCommand;
import mesh : Mesh;
import view : View;
import vibe3d.editing.contracts.editmode : EditMode;

version (unittest) {
    import math : Vec3;

    private SelectElementCommand vertexSetCommand(Mesh* m, int[] indices) {
        View v = new View(0, 0, 1, 1);
        auto c = new SelectElementCommand(m, v, EditMode.Vertices);
        c.setTargetType("vertex");
        c.setAction("set");
        c.setIndices(indices);
        return c;
    }
}

unittest {
    auto m = new Mesh;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0)];
    m.syncSelection();
    m.selectVertex(0);

    auto c = vertexSetCommand(m, [1]);
    assert(c.isUndoable(), "select.element must create an undoable record");
    assert(c.isUiUndo(), "select.element record must have the UI-state class");
    assert(c.apply(), "select.element forward apply must succeed");
    assert(c.undoRecorded(), "select.element must arm its selection undo image");
    assert(!m.isVertexSelected(0) && m.isVertexSelected(1),
        "select.element forward apply must install the requested selection");

    assert(c.revert(), "select.element undo must succeed");
    assert(m.isVertexSelected(0) && !m.isVertexSelected(1),
        "select.element undo must restore the complete prior selection");
}
