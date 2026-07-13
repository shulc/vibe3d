module commands.select.less;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

// SelectLess: all edit modes.
// Deselects the most recently selected element (highest *SelectionOrder).
class SelectLess : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.less"; }

    override bool apply() {
        // Perf (task 0388): use the lock-step `Xmarks.length` for the loop
        // bound rather than `mesh.selectedX.length` — the latter is a @property
        // that rebuilds a whole `bool[]` snapshot just to read its length. The
        // loop body reads only `XSelectionOrder` (a plain field).
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Polygons) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.faceMarks.length) {
                if (i >= mesh.faceSelectionOrder.length) break;
                int ord = mesh.faceSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectFace(last);
        } else if (editMode == EditMode.Edges) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.edgeMarks.length) {
                if (i >= mesh.edgeSelectionOrder.length) break;
                int ord = mesh.edgeSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectEdge(last);
        } else if (editMode == EditMode.Vertices) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.vertexMarks.length) {
                if (i >= mesh.vertexSelectionOrder.length) break;
                int ord = mesh.vertexSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectVertex(last);
        }
        return true;
    }
}
