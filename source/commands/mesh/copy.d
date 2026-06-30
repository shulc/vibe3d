module commands.mesh.copy_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import geometry_clipboard : geometryClipboard, GeometryClip;

/// Snapshot the currently selected faces into the global geometry clipboard.
///
/// Read-only: the mesh is NOT modified, so no undo entry is created
/// (`cmdFlags = CmdFlags.None`). Polygons-mode-only, consistent with
/// mesh.duplicate — vertex/edge selections produce no standalone topology
/// in vibe3d's face-derived edge model.
class MeshCopy : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.copy"; }
    override string label() const { return "Copy"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    // CmdFlags.None → not recorded in the undo stack; read-only operation.
    override CmdFlags cmdFlags() const { return CmdFlags.None; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces())   return false;

        geometryClipboard = GeometryClip.fromSelectedFaces(*mesh);
        return !geometryClipboard.empty;
    }

    // Never called: CmdFlags.None means the command is not recorded.
    override bool revert() { return false; }
}
