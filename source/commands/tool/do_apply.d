module commands.tool.do_apply;

import command;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import commands.mesh.mesh_edit_payload : MeshEditPayload, MeshRestorePolicy;
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
// Separate selection records and strict-LIFO stepping (task 3693):
//   revert() calls MeshSnapshot.restoreGeometryKeepSelection() instead of the
//   full restore(). This preserves the live selection across a geometry-only
//   undo. Selection changes are their own records and are stepped separately.
//
//   Topology safety: restoreGeometryKeepSelection() falls back to the full
//   snapshot marks when element counts changed (edge.extrude / edge.extend
//   path), so topology-creating tools are unaffected.
//
//   Until task 0727 this was a branch selected by a history kill-switch. The
//   geometry-only revert is now unconditional and this command no longer holds
//   a CommandHistory.
// ---------------------------------------------------------------------------
class ToolDoApplyCommand : Command {
    private ToolHost         toolHost;
    private MeshEditPayload  payload;
    private const(void)*     document_;
    private string           appliedToolId;   // captured at apply() for label()

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host, const(void)* document = null)
    {
        super(mesh, view, editMode);
        this.toolHost = host;
        document_ = document;
    }

    override string name()  const { return "tool.doApply"; }
    override string label() const {
        return appliedToolId.length > 0 ? "Apply " ~ appliedToolId : "Apply Tool";
    }

    protected override bool applyImpl() {
        if (payload.present()) { payload.forward(*mesh); return true; }
        auto t = toolHost.getActiveTool();
        if (t is null) return false;
        auto transaction = MeshInvocation(*mesh);
        string identity;
        MeshEditPayload prepared;
        bool complete() {
            const bool replaces = t.sessionPolicy().headlessReplacesWindow
                                  && t.hasUncommittedEdit();
            auto before = MeshSnapshot.capture(*mesh);
            if (!t.applyHeadless()) { transaction.rollback(); return false; }
            if (replaces) {
                auto result = MeshSnapshot.capture(*mesh);
                t.cancelUncommittedEdit();
                before = MeshSnapshot.capture(*mesh);
                result.restore(*mesh);
            }
            auto after = MeshSnapshot.capture(*mesh);
            identity = toolHost.getActiveToolId().idup;
            prepared = MeshEditPayload.snapshots(before, after,
                MeshRestorePolicy.geometryKeepSelection);
            transaction.validate();
            return true;
        }
        auto session = toolHost.session is null ? null : toolHost.session();
        const accepted = session is null ? complete()
            : session.invokeHeadless(t, *mesh, document_, editMode, &complete);
        if (!accepted) { transaction.rollback(); return false; }
        appliedToolId = identity;
        payload = prepared;
        noteUndoRecorded();
        transaction.release();
        return true;
    }

    protected override void revertImpl() {
        // Keep the live selection across a geometry undo (topology-safe
        // fallback built into the method).
        payload.reverse(*mesh);
    }
}
