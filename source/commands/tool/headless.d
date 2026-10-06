module commands.tool.headless;

import command;
import mesh;
import view;
import editmode;
import tool : Tool;
import registry : ToolFactory;
import params : Param;
import tool_attr_bounds : applyToolAttrBound;
import snapshot : MeshSnapshot;
import commands.mesh.mesh_edit_payload : MeshEditPayload;

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
    string           toolId_;
    ToolFactory      factory;
    Tool             toolInstance;   // lazily created on first params()/apply()
    MeshEditPayload  payload;

public:
    this(Mesh* mesh, ref View view, EditMode editMode,
         string toolId, ToolFactory factory)
    {
        super(mesh, view, editMode);
        this.toolId_ = toolId;
        this.factory = factory;
    }

    override string name() const { return toolId_; }

    /// Human-readable label for the history panel.
    override string label() const {
        return "Apply " ~ toolId_;
    }

    /// Returns the schema of a freshly-built tool instance. Used by the
    /// HTTP injector (injectParamsInto) before apply() runs. The same
    /// toolInstance is reused in apply(), so injected values persist.
    override Param[] params() {
        if (toolInstance is null) toolInstance = factory();
        // A scripted one-shot writes the attributes through the same captured
        // bounds as `tool.attr` (tool_attr_bounds).
        auto ps = toolInstance.params();
        foreach (ref p; ps) applyToolAttrBound(toolId_, p);
        return ps;
    }

    // TASK 0669 — this command WRITES THE MESH but overrides `apply()`, so it
    // never reached the base class's no-edit-target refusal (task 0654) and
    // was the one mesh-mutating command in the build that reported `ok` with
    // no item selected. Measured before the fix, against a live instance with
    // the selection cleared:
    //
    //     POST /api/command "mesh.subdivide"  ->  error, "no item is selected…"
    //     POST /api/command "prim.cube"       ->  {"status":"ok"}
    //     GET  /api/model                     ->  {"error":"no item is selected…"}
    //
    // — a success report for a cube built into the read-only stand-in mesh
    // (`document.noEditTargetMesh`), which nothing draws and no endpoint will
    // even read back. That is the owner's "Box does not work", in its command
    // form: not a refusal wearing the costume of success, but a SUCCESS
    // wearing it. 21 registered ids route through this class (`prim.*`,
    // `mesh.mirrorTool`, `mesh.tack`, …).
    //
    // Declaring the requirement here is also what lets the ctrl-variant
    // buttons ("Unit Box" et al., `config/buttons.yaml`) grey out with the
    // rest: they dispatch this command id through a `kind: script` line.
    override bool needsEditTarget() const { return true; }

    protected override bool applyImpl() {
        if (refusedForNoEditTarget()) return false;
        if (payload.present()) { payload.forward(*mesh); return true; }
        if (toolInstance is null) toolInstance = factory();
        auto transaction = MeshInvocation(*mesh);
        auto before = MeshSnapshot.capture(*mesh);
        if (!toolInstance.applyHeadless()) { transaction.rollback(); return false; }
        auto after = MeshSnapshot.capture(*mesh);
        auto prepared = MeshEditPayload.snapshots(before, after);
        transaction.validate();
        payload = prepared;
        noteUndoRecorded();
        transaction.release();
        return true;
    }

    protected override void revertImpl() {
        payload.reverse(*mesh);
    }

private:
}
