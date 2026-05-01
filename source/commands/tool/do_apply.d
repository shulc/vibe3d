module commands.tool.do_apply;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import commands.tool.host : ToolHost;

// ---------------------------------------------------------------------------
// ToolDoApplyCommand — MODO-style `tool.doApply`
//
// Applies the currently active tool one-shot (headless path) and wraps the
// operation with a snapshot pair for undo.  Mirrors the cache-refresh pattern
// used by MeshVertMerge and other mutating commands.
//
// apply()  — snapshot pre, call t.applyHeadless(), refresh caches.
// revert() — restore snapshot, refresh caches.
// ---------------------------------------------------------------------------
class ToolDoApplyCommand : Command {
    private ToolHost         toolHost;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private string           appliedToolId;   // captured at apply() for label()

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc)
    {
        super(mesh, view, editMode);
        this.toolHost = host;
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "tool.doApply"; }
    override string label() const {
        return appliedToolId.length > 0 ? "Apply " ~ appliedToolId : "Apply Tool";
    }

    override bool apply() {
        auto t = toolHost.getActiveTool();
        if (t is null) return false;

        snap = MeshSnapshot.capture(*mesh);
        if (!t.applyHeadless()) {
            snap = MeshSnapshot.init;
            return false;
        }
        appliedToolId = toolHost.getActiveToolId();
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
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
