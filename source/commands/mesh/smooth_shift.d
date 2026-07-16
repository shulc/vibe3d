module commands.mesh.smooth_shift;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`.  Mirrors the helpers in
/// face_extrude.d and edge_extrude.d — empty selection ⇒ whole mesh.
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Smooth Shift (one-shot, undoable): extrude the selected polygon region
/// where each cloned cap vertex is offset along the normalized average of its
/// incident selected-face normals ("per-vertex smooth normal"), instead of the
/// single shared region normal used by the rigid Face Extrude.
///
/// vibe3d-divergence: uniform weighting of the vertex-normal average (each
/// incident selected face's unit normal contributes equally).  Area- or
/// angle-weighted averaging would be a one-line change to the accumulator in
/// Mesh.extrudeFacesByMask; deferred — reference harness absent from this
/// checkout so empirical capture is infeasible.
///
/// Polygons-mode only; empty selection ⇒ whole mesh; shift==0 or a closed
/// island (no boundary edges) are clean no-ops (snapshot discarded).
class MeshSmoothShift : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            shift_ = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.smooth_shift"; }
    override string label() const { return "Smooth Shift"; }

    override Param[] params() {
        return [Param.float_("shift", "Shift", &shift_, 0.5f)];
    }
    void setShift(float v) { shift_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Polygons);
        auto mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
        size_t n = mesh.extrudeFacesByMask(mask, shift_, true);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplayActive(mesh);
    }
}
