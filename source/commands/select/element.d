module commands.select.element;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

/// select.element <vertex|edge|polygon> <set|add|remove> <indices...>
///
/// Mutates selection in the given element type:
///   set / replace — clear first, then select the given indices.
///   add           — add the indices to the current selection.
///   remove / del  — deselect the given indices.
///
/// EditMode is NOT changed (contrast with mesh.select which switches mode).
/// The selection mutation is one undoable UI-state record.
class SelectElementCommand : Command {
    private string targetType;
    private string action;
    private int[]  indices;
    private SelectionSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "select.element"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    void setTargetType(string t) { targetType = t; }
    void setAction(string a)     { action = a; }
    void setIndices(int[] i)     { indices = i; }

    protected override bool applyImpl() {
        mesh.syncSelection();
        snap = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();
        switch (targetType) {
            case "vertex":
                applyToVertices();
                break;
            case "edge":
                applyToEdges();
                break;
            case "polygon":
                applyToPolygons();
                break;
            default:
                throw new Exception(
                    "select.element: unknown type '" ~ targetType ~
                    "' — expected vertex, edge, or polygon");
        }
        return true;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
    }

private:

    void applyToVertices() {
        int maxIdx = cast(int)mesh.vertices.length;
        final switch (normaliseAction()) {
            case Action.set:
                mesh.clearVertexSelection();
                foreach (i; indices) {
                    checkRange(i, maxIdx, "vertex");
                    mesh.selectVertex(i);
                }
                break;
            case Action.add:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "vertex");
                    mesh.selectVertex(i);
                }
                break;
            case Action.remove:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "vertex");
                    mesh.deselectVertex(i);
                }
                break;
        }
    }

    void applyToEdges() {
        int maxIdx = cast(int)mesh.edges.length;
        final switch (normaliseAction()) {
            case Action.set:
                mesh.clearEdgeSelection();
                foreach (i; indices) {
                    checkRange(i, maxIdx, "edge");
                    mesh.selectEdge(i);
                }
                break;
            case Action.add:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "edge");
                    mesh.selectEdge(i);
                }
                break;
            case Action.remove:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "edge");
                    mesh.deselectEdge(i);
                }
                break;
        }
    }

    void applyToPolygons() {
        int maxIdx = cast(int)mesh.faces.length;
        final switch (normaliseAction()) {
            case Action.set:
                mesh.clearFaceSelection();
                foreach (i; indices) {
                    checkRange(i, maxIdx, "polygon");
                    mesh.selectFace(i);
                }
                break;
            case Action.add:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "polygon");
                    mesh.selectFace(i);
                }
                break;
            case Action.remove:
                foreach (i; indices) {
                    checkRange(i, maxIdx, "polygon");
                    mesh.deselectFace(i);
                }
                break;
        }
    }

    enum Action { set, add, remove }

    Action normaliseAction() const {
        switch (action) {
            case "set", "replace": return Action.set;
            case "add":            return Action.add;
            case "remove", "del":  return Action.remove;
            default:
                throw new Exception(
                    "select.element: unknown action '" ~ action ~
                    "' — expected set, add, or remove");
        }
    }

    static void checkRange(int idx, int maxIdx, string typeName) {
        import std.conv : to;
        if (idx < 0 || idx >= maxIdx)
            throw new Exception(
                "select.element: " ~ typeName ~ " index " ~
                idx.to!string ~ " out of range");
    }
}

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
