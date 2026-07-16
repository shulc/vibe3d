module tools.reduce;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import display_sync : refreshDisplay;
import shader : LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

import std.math : lround;

alias MeshReduceEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// ReductionTool — interactive polygon reduction (factory id `mesh.reduceTool`).
//
// Wraps Mesh.reduceToTarget with a ratio param (fraction of faces to keep) and
// a preserveBoundary flag. No viewport gizmo — parameter-panel attribute tool.
//
// Headless: tool.set mesh.reduceTool on; tool.attr mesh.reduceTool ratio <v>;
//           tool.doApply → applyHeadless(); ToolDoApplyCommand wraps undo.
//
// Interactive: activate() captures baseline; onParamChanged() previews via
// rebuildPreview (restore-from-baseline + re-run kernel); deactivate() commits
// exactly one snapshot-pair undo entry when a preview was built.
//
// CRITICAL: applyHeadless() self-heals at the top (restores baseline if a
// preview is already baked in) so that tool.doApply's snapshot is always
// captured from the ORIGINAL mesh — idempotent regardless of preview state.
// ---------------------------------------------------------------------------
class ReductionTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory        history;
    MeshReduceEditFactory factory;

    float ratio_  = 0.5f;
    bool  pb_     = true;

    bool         active;
    bool         built;     // true when a preview is baked into the live mesh
    MeshSnapshot before;    // session baseline (captured on activate)

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, MeshReduceEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "mesh.reduceTool"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.float_("ratio",            "Ratio",             &ratio_, 0.5f).min(0).max(1),
            Param.bool_ ("preserveBoundary", "Preserve Boundary", &pb_,    true),
        ];
    }

    override void activate() {
        active = true;
        // Task 0393: ratio_/pb_ are STICKY tool-defaults, already restored
        // onto these fields by applyStickyToolDefaults() (tool_presets.d,
        // called from app.d activateToolById) BEFORE activate() runs —
        // don't reset them back to the constructor defaults here. A
        // brand-new (never-activated) tool still gets 0.5/true from the
        // field initializers above.
        built  = false;
        before = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built)
            commitEdit();
        active = false;
        built  = false;
    }

    override bool hasUncommittedEdit() const {
        return active && built;
    }

    override void cancelUncommittedEdit() {
        if (built && before.filled) before.restore(*mesh);
        built = false;
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    override void resyncSession() {
        if (!active) return;
        // Re-capture baseline from the current (post-undo) mesh.
        if (built && before.filled) before.restore(*mesh);
        built  = false;
        before = MeshSnapshot.capture(*mesh);
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }

    override void evaluate() {}

    override bool applyHeadless() {
        // Self-heal: if an interactive preview is already baked into the mesh,
        // restore the session baseline so the commit starts from the original
        // mesh. This makes applyHeadless() idempotent regardless of preview
        // state: tool.doApply captures its undo snapshot AFTER this restore,
        // so Ctrl+Z always rewinds to the true original.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;

        immutable size_t origFaces = mesh.faces.length;
        size_t target = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (target < 1) target = 1;
        if (target >= origFaces) return false;  // no-op (ratio >= 1.0 or rounding)

        size_t n = mesh.reduceToTarget(target, pb_);
        if (n == 0) return false;

        refreshDisplay(mesh, gpu, vc, ec, fc);
        return true;
    }

private:
    // Restore baseline then re-run the kernel at the current ratio so the
    // viewport shows a live preview. Never accumulates: always restore-first.
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);

        if (mesh.faces.length == 0) {
            built = false;
            refreshDisplay(mesh, gpu, vc, ec, fc);
            return;
        }

        immutable size_t origFaces = mesh.faces.length;
        size_t target = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (target < 1) target = 1;
        if (target >= origFaces) {
            // No-op ratio — mesh already at baseline, leave it clean.
            built = false;
            refreshDisplay(mesh, gpu, vc, ec, fc);
            return;
        }

        size_t n = mesh.reduceToTarget(target, pb_);
        built = (n != 0);
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    // Record the interactive session as one snapshot-pair undo entry.
    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Reduce");
        history.record(cmd);
    }
}
