module commands.tool.do_apply;

import display_sync : refreshDisplay;
import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import commands.tool.host : ToolHost;
import command_history : CommandHistory;

// ---------------------------------------------------------------------------
// ToolDoApplyCommand — `tool.doApply`
//
// Applies the currently active tool one-shot (headless path) and wraps the
// operation with a snapshot pair for undo.  Mirrors the cache-refresh pattern
// used by MeshVertMerge and other mutating commands.
//
// apply()  — snapshot pre, call t.applyHeadless(), refresh caches.
// revert() — restore snapshot, refresh caches.
//
// T-SEP class-aware stepping (task 0038):
//   When _classAwareStepping is on (VIBE3D_UNDO_CLASS_STEP != "0"), revert()
//   calls MeshSnapshot.restoreGeometryKeepSelection() instead of the full
//   restore(). This preserves the live selection across a geometry-only undo,
//   matching the T-SEP rule that selection is a separate timeline.
//
//   Topology safety: restoreGeometryKeepSelection() falls back to the full
//   snapshot marks when element counts changed (edge.extrude / edge.extend
//   path), so topology-creating tools are unaffected.
//
//   When _classAwareStepping is off (kill-switch), revert() uses the legacy
//   full restore() so the kill-switch stays faithful to old behaviour.
// ---------------------------------------------------------------------------
class ToolDoApplyCommand : Command {
    private ToolHost         toolHost;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private string           appliedToolId;   // captured at apply() for label()
    private CommandHistory   history;         // for classAwareStepping flag

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         CommandHistory history)
    {
        super(mesh, view, editMode);
        this.toolHost = host;
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
        this.history = history;
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
        // T-SEP: under class-aware stepping, keep the live selection across a
        // geometry undo (topology-safe fallback built into the method).
        if (history !is null && history.classAwareStepping())
            snap.restoreGeometryKeepSelection(*mesh);
        else
            snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
