module commands.mesh.select;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;
import math : Vec3;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : SymmetryPacket;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.symmetry : SymmetryStage;
import symmetry          : mirrorEdge, mirrorFace;
import symmetry_pick     : captureLiveSymmetry;
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

        // Phase 7.6c: when symmetry is on, every successful pick also
        // selects the mirror counterpart of each clicked element. Gated
        // on the SymmetryStage's `enabled` flag so the no-symmetry path
        // is identical to pre-7.6 behaviour (and `tool.pipe.attr` users
        // who never enable symmetry never pay the pipeline.evaluate
        // tax).
        auto symm = captureSymmetryPacket();
        bool symmActive = symm.enabled
                       && symm.pairOf.length == mesh.vertices.length;

        // Phase 7.6 (BaseSide): anchor the symmetry stage on the FIRST
        // user-passed index's world-space centroid. Subsequent
        // mirror-move / rotate / scale operations consult `baseSide`
        // to decide which side of a fully-mirrored pair drives the
        // deformation. Updated even if the anchor sits on the plane
        // (no-op there — `anchorAt` keeps the previous baseSide).
        if (symmActive && indices.length > 0) {
            Vec3 anchor = computeAnchor(mode, cast(int)indices[0]);
            if (auto sym = cast(SymmetryStage)
                          g_pipeCtx.pipeline.findByTask(TaskCode.Symm))
                sym.anchorAt(anchor);
        }

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
                    if (symmActive) {
                        int mi = symm.pairOf[i];
                        if (mi >= 0 && mi != cast(int)i) mesh.selectVertex(mi);
                    }
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
                    if (symmActive) {
                        uint me = mirrorEdge(*mesh, symm, i);
                        if (me != ~0u && me != i)
                            mesh.selectEdge(cast(int)me);
                    }
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
                    if (symmActive) {
                        uint mf = mirrorFace(*mesh, symm, i);
                        if (mf != ~0u && mf != i)
                            mesh.selectFace(cast(int)mf);
                    }
                }
                break;
            default:
                throw new Exception("invalid mode '" ~ mode ~
                                    "', expected vertices/edges/polygons");
        }
        return true;
    }

    /// World-space anchor for the picked element — used as the input
    /// to `SymmetryStage.anchorAt`. Vertices anchor at their position;
    /// edges / polygons at their vertex centroid.
    private Vec3 computeAnchor(string m, int firstIdx) {
        if (m == "vertices") {
            if (firstIdx < 0 || firstIdx >= cast(int)mesh.vertices.length)
                return Vec3(0, 0, 0);
            return mesh.vertices[firstIdx];
        }
        if (m == "edges") {
            if (firstIdx < 0 || firstIdx >= cast(int)mesh.edges.length)
                return Vec3(0, 0, 0);
            auto e = mesh.edges[firstIdx];
            return (mesh.vertices[e[0]] + mesh.vertices[e[1]]) * 0.5f;
        }
        if (m == "polygons") {
            if (firstIdx < 0 || firstIdx >= cast(int)mesh.faces.length)
                return Vec3(0, 0, 0);
            auto f = mesh.faces[firstIdx];
            if (f.length == 0) return Vec3(0, 0, 0);
            return mesh.faceCentroid(cast(uint)firstIdx);
        }
        return Vec3(0, 0, 0);
    }

    /// Snapshot the live SymmetryPacket via the global toolpipe. Gated
    /// on the SymmetryStage being registered AND enabled — pipeline
    /// .evaluate has cross-stage side effects (FalloffStage caches
    /// workplane normal on every fire), so we skip the call entirely
    /// when symmetry is off.
    ///
    /// Task 1904 Stage 2: this used to build its own SubjectPacket by
    /// hand; it now shares `symmetry_pick.d :: captureLiveSymmetry` with
    /// `MeshTransform` and the interactive symmetric*Select* helpers.
    /// selType stays left at its default (Vertex) inside that shared
    /// function — this command only ever mirrors a GEOMETRY selection
    /// (vertex/edge/polygon), never an item one (`layer.select` is the
    /// separate command for item selection), and this class carries no
    /// SelType/SelTypeOrder reference to read.
    private auto captureSymmetryPacket() {
        SymmetryPacket result;
        SymmetryStage  stageUnused;
        captureLiveSymmetry(mesh, effectiveViewport(), *editModePtr,
                            result, stageUnused);
        return result;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        applyEditMode(prevEditMode);   // lockstep on undo too
    }
}
