module commands.mesh.bevel_edit;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive bevel session (see BevelTool,
/// Phase C.4). The tool captures a full MeshSnapshot at the moment bevel
/// topology is first built, mutates the mesh freely while the user drags
/// the gizmo and tweaks Tool Properties (intermediate revert+reapply
/// cycles within the tool itself), and on deactivation records this
/// command holding (pre-bevel, post-bevel) snapshots.
///
/// apply() = restore post; revert() = restore pre. Heavyweight (~MB for
/// large meshes) but bevel sessions are discrete user actions, not
/// continuous, so the snapshot cost is paid once per session.
class MeshBevelEdit : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.bevel_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Bevel";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Bevel") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
    }

    override bool apply() {
        after.restore(*mesh);
        refreshCaches();
        return true;
    }

    override bool revert() {
        before.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
