module commands.mesh.triple;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Split every selected (or whole-mesh) n-gon into triangles by fanning from
/// the first vertex. Convex polygons (quads, convex n-gons) are handled
/// correctly; concave polygons are a documented v1 limitation (ear-clip
/// follow-up). Already-triangles are left untouched.
///
/// Selection-aware (Polygons mode + non-empty selection): only the selected
/// faces are triangulated; children of selected parents are re-selected.
/// Otherwise: whole active layer (same convention as mesh.delete).
///
/// Undo via MeshSnapshot (whole-mesh snapshot — topology-replacing op).
class MeshTriple : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.triple"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();

        bool   polygonMode        = editMode == EditMode.Polygons;
        bool   hasSelection       = polygonMode && mesh.hasAnySelectedFaces();
        bool[] prevSelectedFaces  = hasSelection ? mesh.selectedFaces.dup : null;

        // Whole-mesh: allTrue mask (NOT null — length-checked kernel).
        bool[] mask = hasSelection
            ? mesh.selectedFaces
            : allTrue(mesh.faces.length);

        uint[] faceOrigin;
        mesh.triangulateFacesByMask(mask, &faceOrigin);

        // Re-select children of originally-selected parents.
        if (hasSelection) {
            mesh.resetSelection();
            foreach (k, parentFi; faceOrigin) {
                if (parentFi < prevSelectedFaces.length
                    && prevSelectedFaces[parentFi])
                    mesh.selectFace(cast(int)k);
            }
        }

        mesh.noteChange(MeshEditScope.Geometry);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}
