module commands.tool.headless;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import tool : Tool;
import registry : ToolFactory;
import params : Param;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// ToolHeadlessCommand — generic Command wrapper around a Tool's applyHeadless
// path.
//
// Activates a fresh Tool instance via the given factory, injects JSON params
// through the tool's schema (via the caller calling injectParamsInto on
// cmd.params() before apply()), runs applyHeadless(), and supports
// snapshot-based undo.
//
// The tool is NOT registered as the App's activeTool — this is a pure
// headless invocation independent of UI state.
//
// Lazy init: both params() and apply() share the same toolInstance so that
// injectParamsInto() writes into the fields that applyHeadless() will read.
// ---------------------------------------------------------------------------
class ToolHeadlessCommand : Command {
private:
    GpuMesh*         gpu;
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;
    string           toolId_;
    ToolFactory      factory;
    Tool             toolInstance;   // lazily created on first params()/apply()
    MeshSnapshot     snap;

public:
    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         string toolId, ToolFactory factory)
    {
        super(mesh, view, editMode);
        this.gpu     = gpu;
        this.vc      = vc;
        this.ec      = ec;
        this.fc      = fc;
        this.toolId_ = toolId;
        this.factory = factory;
    }

    override string name() const { return toolId_; }

    /// Returns the schema of a freshly-built tool instance. Used by the
    /// HTTP injector (injectParamsInto) before apply() runs. The same
    /// toolInstance is reused in apply(), so injected values persist.
    override Param[] params() {
        if (toolInstance is null) toolInstance = factory();
        return toolInstance.params();
    }

    override bool apply() {
        if (toolInstance is null) toolInstance = factory();
        snap = MeshSnapshot.capture(*mesh);
        if (!toolInstance.applyHeadless()) {
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

private:
    void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
    }
}
