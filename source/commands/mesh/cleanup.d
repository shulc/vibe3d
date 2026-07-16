module commands.mesh.cleanup;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params : Param;

/// Sequential mesh hygiene sweep: optionally weld coincident vertices, drop
/// degenerate / zero-area faces, remove duplicate-vertex-set faces, remove
/// floating (unreferenced) vertices, and optionally dissolve 2-valent vertices.
/// Operates on the whole active mesh regardless of current selection.
/// Stage toggles and weld distance are exposed as command parameters.
/// Undo via MeshSnapshot.
class MeshCleanup : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    // Parameter backing fields — defaults match CleanupOptions.init.
    private bool  dropDegenerate_  = true;
    private bool  unify_           = true;
    private bool  removeOrphans_   = true;
    private bool  dissolve2Valent_ = false;
    private bool  mergeVerts_      = true;
    private float dist_            = 1e-5f;  // linear weld distance

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.cleanup"; }
    override string label() const { return "Mesh Cleanup"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    override Param[] params() {
        return [
            Param.bool_("dropDegenerate",  "Remove Degenerate Faces",    &dropDegenerate_,  true),
            Param.bool_("unify",           "Unify Duplicate Faces",      &unify_,           true),
            Param.bool_("removeOrphans",   "Remove Floating Vertices",   &removeOrphans_,   true),
            Param.bool_("dissolve2Valent", "Dissolve 2-Valent Vertices", &dissolve2Valent_, false),
            Param.bool_("mergeVerts",      "Merge Coincident Vertices",  &mergeVerts_,      true),
            Param.float_("dist", "Merge Distance", &dist_, 1e-5f)
                 .min(1e-7f).max(10.0f).fmt("%.5f"),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "dist") return mergeVerts_;
        return true;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        CleanupOptions opts;
        opts.dropDegenerate  = dropDegenerate_;
        opts.unify           = unify_;
        opts.removeOrphans   = removeOrphans_;
        opts.dissolve2Valent = dissolve2Valent_;
        opts.mergeVerts      = mergeVerts_;
        opts.weldEpsSq       = cast(double)dist_ * cast(double)dist_;

        snap = MeshSnapshot.capture(*mesh);
        auto r = mesh.cleanupMesh(opts);
        if (!r.anyAffected()) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshDisplayActive(mesh);
        return true;
    }
}
