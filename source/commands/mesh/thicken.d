module commands.mesh.thicken;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// Thicken (mesh.thicken): build an offset copy of the whole surface
/// (vertices displaced along averaged vertex normals), reverse its winding
/// to form the inner skin, and stitch every open boundary loop original↔offset
/// with a ring of quads — yielding a closed, watertight shell.
///
/// Self-intersection on tight concavities is a known v1 limitation.
///
/// Parameters:
///   thickness  (float)  Offset distance (default 0.1).
///   symmetric  (bool)   When true, split ±thickness/2; when false (default),
///                       keep the original surface as the outer skin.
class MeshThicken : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            thickness_ = 0.1f;
    private bool             symmetric_ = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.thicken"; }
    override string label() const { return "Thicken"; }

    override Param[] params() {
        return [
            Param.float_("thickness", "Thickness", &thickness_, 0.1f),
            Param.bool_("symmetric",  "Symmetric",  &symmetric_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t n = mesh.thickenSurface(thickness_, symmetric_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
