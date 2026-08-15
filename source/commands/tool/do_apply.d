module commands.tool.do_apply;

import command;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import commands.tool.host : ToolHost;

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
//   revert() calls MeshSnapshot.restoreGeometryKeepSelection() instead of the
//   full restore(). This preserves the live selection across a geometry-only
//   undo, matching the T-SEP rule that selection is a separate timeline.
//
//   Topology safety: restoreGeometryKeepSelection() falls back to the full
//   snapshot marks when element counts changed (edge.extrude / edge.extend
//   path), so topology-creating tools are unaffected.
//
//   Until task 0727 this was a branch: the history's `classAwareStepping()`
//   kill-switch selected the full restore() instead. Both the switch and the
//   LIFO undo path behind it are gone, so the geometry-only revert is
//   unconditional and this command no longer holds a CommandHistory.
// ---------------------------------------------------------------------------
class ToolDoApplyCommand : Command {
    private ToolHost         toolHost;
    private MeshSnapshot     snap;
    private string           appliedToolId;   // captured at apply() for label()

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host)
    {
        super(mesh, view, editMode);
        this.toolHost = host;
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
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        // T-SEP: keep the live selection across a geometry undo (topology-safe
        // fallback built into the method).
        snap.restoreGeometryKeepSelection(*mesh);
        return true;
    }
}
