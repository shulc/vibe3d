module tools.edit.reduce;

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
import mesh_edit_delta : MeshEditScope;

import std.math : lround;
import perf_probe : g_perf, Cat;

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

    float ratio_  = 0.5f;
    bool  pb_     = true;

    bool         active;
    bool         built;     // true when a preview is baked into the live mesh
    MeshSnapshot before;    // session baseline (captured on activate)

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
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
        refreshDisplay(mesh, gpu);
    }

    override void resyncSession() {
        if (!active) return;
        // Re-capture baseline from the current (post-undo) mesh.
        if (built && before.filled) before.restore(*mesh);
        built  = false;
        before = MeshSnapshot.capture(*mesh);
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
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

        // TASK 1903 Stage D2 — the batch opens at the TOOL boundary, never
        // inside the kernel (plan §4.1); see the note at rebuildPreview below
        // for why both of this tool's batches are UNRECORDED.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kReduceEditScope);
            n = ed.reduceToTarget(target, pb_);
            ed.close();
        }
        if (n == 0) return false;

        refreshDisplay(mesh, gpu);
        return true;
    }

private:
    // Restore baseline then re-run the kernel at the current ratio so the
    // viewport shows a live preview. Never accumulates: always restore-first.
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);

        if (mesh.faces.length == 0) {
            built = false;
            refreshDisplay(mesh, gpu);
            return;
        }

        immutable size_t origFaces = mesh.faces.length;
        size_t target = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (target < 1) target = 1;
        if (target >= origFaces) {
            // No-op ratio — mesh already at baseline, leave it clean.
            built = false;
            refreshDisplay(mesh, gpu);
            return;
        }

        // TASK 1903 Stage D2 — UNRECORDED, and on this path that is a HARD
        // requirement rather than a track-1 economy (plan §9). `rebuildPreview`
        // runs once per parameter change, i.e. once per drag frame: a
        // RECORDING batch would build and throw away a full op-log at 60 Hz,
        // and `changeBus.opLogEntriesRecorded` would tick for an edit the user
        // has not committed. An unrecorded frame keeps every tracker hook on
        // its existing `if (editRecorder_ is null) return;` first line — one
        // predictable branch, exactly today's batchless cost — while still
        // collapsing the kernel's internal commits into ONE stamp, ONE hidden
        // derive and ONE delivery per frame. `close()` returns
        // `MeshEditDelta.init` and there is nothing to read.
        //
        // The close MUST precede `refreshDisplay`: the display refresh reads
        // the version stamps this batch is deferring, so refreshing inside the
        // batch would paint from the pre-edit stamps.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kReduceEditScope);
            n = ed.reduceToTarget(target, pb_);
            ed.close();
        }
        built = (n != 0);
        refreshDisplay(mesh, gpu);
    }

    // Record the interactive session as one snapshot-pair undo entry.
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Reduce");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
}
