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
    protected override void revertImpl() {
        snap.restore(*mesh);
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.less"; }

    protected override bool applyImpl() {
        // ONE reader for "which element was selected last", shared with
        // `select.more` and `select.between`: `Mesh.lastSelectedInSelectionOrder`
        // (task 2440). The three files held nine hand-written copies of this
        // scan and none of them filtered by "is this element still selected"
        // first, so a stale stamp left behind by `bevel_vertex` / `extrude`
        // made this command spend its one deselect on an element that was not
        // in the selection at all — visibly a no-op. See the method's own
        // comment for the measured state and for why an UNSTAMPED selected
        // element is deliberately not a candidate.
        //
        // NO SELECTION-PLANE RESIZE HERE, unlike the two siblings, and that is
        // not the missing half of this change. Their guard is a precondition
        // of the WRITE they go on to make (`selectFace` indexes `faceMarks`
        // and `faceSelectionOrder` raw, at an index their loop walk produced,
        // which can sit past either plane). This command only DESELECTS, and
        // only at an index the reader above proved is inside both planes.
        snap = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        const sel = mesh.lastSelectedInSelectionOrder(editMode);
        if (sel.last < 0) return true;
        final switch (editMode) {
            case EditMode.Polygons: mesh.deselectFace(sel.last);   break;
            case EditMode.Edges:    mesh.deselectEdge(sel.last);   break;
            case EditMode.Vertices: mesh.deselectVertex(sel.last); break;
        }
        return true;
    }
}
