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
/// Not undoable — matches MODO's select.element semantics.
class SelectElementCommand : Command {
    private string targetType;
    private string action;
    private int[]  indices;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "select.element"; }
    override bool isUndoable() const { return false; }

    void setTargetType(string t) { targetType = t; }
    void setAction(string a)     { action = a; }
    void setIndices(int[] i)     { indices = i; }

    override bool apply() {
        mesh.syncSelection();
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
