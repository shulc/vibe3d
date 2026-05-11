module commands.mesh.select;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;
import math : Vec3;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : SubjectPacket;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.symmetry : SymmetryStage;
import symmetry          : mirrorEdge, mirrorFace;

/// Replace the current selection with the given indices in the given mode.
/// Switches editMode to match (vertices/edges/polygons). Used to be a direct
/// HTTP handler in app.d (setSelectionHandler); now a Command so undo/redo
/// covers selection changes uniformly with the rest of the system.
class MeshSelect : Command {
    private EditMode*         editModePtr;       // app.d's editMode (writable)
    private string            mode;
    private int[]             indices;
    private SelectionSnapshot snap;
    private EditMode          prevEditMode;
    private bool              captured;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "mesh.select"; }
    override string label() const { return "Select"; }

    void setMode(string m)         { mode    = m; }
    void setIndices(int[] i)       { indices = i; }

    override bool apply() {
        mesh.syncSelection();
        snap         = SelectionSnapshot.capture(*mesh);
        prevEditMode = *editModePtr;
        captured     = true;

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
            Vec3 anchor = computeAnchor(mode, indices[0]);
            if (auto sym = cast(SymmetryStage)
                          g_pipeCtx.pipeline.findByTask(TaskCode.Symm))
                sym.anchorAt(anchor);
        }

        int max;
        switch (mode) {
            case "vertices":
                *editModePtr = EditMode.Vertices;
                mesh.clearVertexSelection();
                max = cast(int)mesh.vertices.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("vertex index out of range");
                    mesh.selectVertex(i);
                    if (symmActive) {
                        int mi = symm.pairOf[i];
                        if (mi >= 0 && mi != i) mesh.selectVertex(mi);
                    }
                }
                break;
            case "edges":
                *editModePtr = EditMode.Edges;
                mesh.clearEdgeSelection();
                max = cast(int)mesh.edges.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("edge index out of range");
                    mesh.selectEdge(i);
                    if (symmActive) {
                        uint me = mirrorEdge(*mesh, symm, cast(uint)i);
                        if (me != ~0u && me != cast(uint)i)
                            mesh.selectEdge(cast(int)me);
                    }
                }
                break;
            case "polygons":
                *editModePtr = EditMode.Polygons;
                mesh.clearFaceSelection();
                max = cast(int)mesh.faces.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("face index out of range");
                    mesh.selectFace(i);
                    if (symmActive) {
                        uint mf = mirrorFace(*mesh, symm, cast(uint)i);
                        if (mf != ~0u && mf != cast(uint)i)
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
            Vec3 sum = Vec3(0, 0, 0);
            foreach (vi; f) sum = sum + mesh.vertices[vi];
            return sum * (1.0f / cast(float)f.length);
        }
        return Vec3(0, 0, 0);
    }

    /// Snapshot the live SymmetryPacket via the global toolpipe. Gated
    /// on the SymmetryStage being registered AND enabled — pipeline
    /// .evaluate has cross-stage side effects (FalloffStage caches
    /// workplane normal on every fire), so we skip the call entirely
    /// when symmetry is off.
    private auto captureSymmetryPacket() {
        import toolpipe.packets : SymmetryPacket;
        SymmetryPacket result;
        if (g_pipeCtx is null) return result;
        auto sym = cast(SymmetryStage)
                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
        if (sym is null || !sym.enabled) return result;
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editModePtr;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto vp = view.viewport();
        auto state = g_pipeCtx.pipeline.evaluate(subj, vp);
        return state.symmetry;
    }

    override bool revert() {
        if (!captured) return false;
        snap.restore(*mesh);
        *editModePtr = prevEditMode;
        return true;
    }
}
