module commands.mesh.select;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;
import params            : Param, wireArgs;

/// Replace the current selection with the given indices in the given mode.
/// Switches editMode to match (vertices/edges/polygons). Used to be a direct
/// Generic HTTP command dispatch and interactive selection share this command,
/// so undo/redo
/// covers selection changes uniformly with the rest of the system.
class MeshSelect : Command {
    private EditMode*         editModePtr;       // app.d's editMode (writable)
    private string            mode;
    // `uint[]`, not `int[]`, because `Param.Kind.IntArray` is the declared
    // spelling of an index list and its storage is `uint[]`. The range check in
    // `applyImpl` is unchanged in EFFECT: a wire `-1` used to fail the `i < 0`
    // half, and as a `uint` it fails the `i >= max` half with the same message.
    private uint[]            indices;
    private SelectionSnapshot snap;
    private EditMode          prevEditMode;
    // Selection-types Stage 5 (audit c): when the app installs this hook, the
    // editMode write routes through the geometry-type funnel (touch the recent
    // ordering + note the current-type flip) so EditMode is never written
    // independently of SelType. Null (the default / unit-test path) falls back
    // to a plain `*editModePtr =` write — behaviourally identical for callers
    // that have no SelType ordering (the order is app-global state).
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "mesh.select"; }
    override string label() const { return "Select"; }

    // Selection is a UI-undo class operation (same class as interactive
    // MeshSelectionEdit). Scripted (/api/select) and interactive picks are
    // semantically equivalent — both change selection state, not geometry.
    // UiState (not Model) so a plain geometry undo steps past it.
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    // TASK 4062 — THE ARGUMENTS, DECLARED. `mode` and `indices` used to be
    // filled by a hand-written arm in the HTTP dispatcher (the retired
    // `/api/select` route's validation, moved there and then here). The index
    // list is an ARRAY slot, so it also ABSORBS the positional tail:
    // `mesh.select vertices 3 4 5` binds the same three indices the JSON body
    // `{"mode":"vertices","indices":[3,4,5]}` does.
    override Param[] params() {
        return wireArgs(
            Param.string_  ("mode",    "Mode",    &mode, ""),
            Param.intArray_("indices", "Indices", &indices),
        );
    }

    void setMode(string m)         { mode    = m; }
    /// In-process callers still speak `int[]` (`copilot.selectFinding` builds
    /// one after clamping it against the live mesh bound).
    void setIndices(int[] i)       {
        indices.length = i.length;
        foreach (k, v; i) indices[k] = cast(uint)v;
    }
    MeshSelect setPromoteHook(void delegate(EditMode) h) { promoteType = h; return this; }

    // Set editMode to `m`, routing through the app funnel when installed so the
    // SelType recent-ordering stays in lockstep; otherwise write directly.
    private void applyEditMode(EditMode m) {
        if (promoteType !is null) promoteType(m);
        else                      *editModePtr = m;
    }

    protected override bool applyImpl() {
        mesh.syncSelection();
        snap         = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        prevEditMode = *editModePtr;

        // A command door NEVER pairs (task 7144, captured law gap 315 /
        // C-script S-single): the mirror partner joins a selection only
        // through a pointer gesture (`symmetry.mirrorElement`).

        // `uint`, matching the declared index slot — the `i < 0` half of the
        // old test is now unrepresentable and the `i >= max` half catches a
        // wire `-1` (which arrives as `uint.max`) with the same message.
        uint max;
        switch (mode) {
            case "vertices":
                applyEditMode(EditMode.Vertices);
                mesh.clearVertexSelection();
                max = cast(uint)mesh.vertices.length;
                foreach (i; indices) {
                    if (i >= max)
                        throw new Exception("vertex index out of range");
                    mesh.selectVertex(cast(int)i);
                }
                break;
            case "edges":
                applyEditMode(EditMode.Edges);
                mesh.clearEdgeSelection();
                max = cast(uint)mesh.edges.length;
                foreach (i; indices) {
                    if (i >= max)
                        throw new Exception("edge index out of range");
                    mesh.selectEdge(cast(int)i);
                }
                break;
            case "polygons":
                applyEditMode(EditMode.Polygons);
                mesh.clearFaceSelection();
                max = cast(uint)mesh.faces.length;
                foreach (i; indices) {
                    if (i >= max)
                        throw new Exception("face index out of range");
                    mesh.selectFace(cast(int)i);
                }
                break;
            default:
                throw new Exception("invalid mode '" ~ mode ~
                                    "', expected vertices/edges/polygons");
        }
        return true;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        applyEditMode(prevEditMode);   // lockstep on undo too
    }
}
