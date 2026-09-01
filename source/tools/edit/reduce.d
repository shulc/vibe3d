module tools.edit.reduce;
import prepared_record_context : PreparedRecordContext;
import prepared_private_state : PreparedPrivateStateOwner;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;

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
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import command_history : PreparedHistoryKind;
import prepared_reduction_param_update : PreparedReductionParamUpdateOwner;
import prepared_tool_effect : PreparedReductionParamEffect,
    PreparedReductionParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;

struct ReductionParamProjection {
    bool interactive, active, built, preserveBoundary;
    float ratio;
    bool opEquals(const ReductionParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built && preserveBoundary == other.preserveBoundary &&
            memcmp(&ratio, &other.ratio, float.sizeof) == 0;
    }
}

struct PreparedReductionParamImage {
    bool valid, applies, nextBuilt;
    ReductionParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; valid = applies = false;
    }
}

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
    final MeshSnapshot prepareActivationBaseline() { return MeshSnapshot.capture(*mesh); }
    final void installPreparedActivation(ref MeshSnapshot image) nothrow @nogc {
        active = true; built = false; image.moveInto(before);
    }
    final PreparedSessionActivateEffect prepareActivate(PreparedRecordContext context,
            PreparedPrivateStateOwner owner) {
        bool accepted = context !is null && owner !is null && owner.owns(this) &&
            context.preparePrivateState(owner) && context.markNoHistoryInstall();
        if (!accepted && context !is null) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Reduction, accepted);
    }
    version(unittest) void seedPreparedActivationForTest(bool a, bool b) nothrow @nogc {
        active = a; built = b;
    }
    version(unittest) bool preparedActiveForTest() const nothrow @nogc { return active; }
    version(unittest) bool preparedBuiltForTest() const nothrow @nogc { return built; }
    version(unittest) float preparedBaselineXForTest() const nothrow @nogc {
        return before.filled && before.vertices.length ? before.vertices[0].x : float.nan;
    }
    version(unittest) bool preparedBaselineFilledForTest() const nothrow @nogc {
        return before.filled;
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
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private ReductionParamProjection paramProjection() const nothrow @nogc {
        return ReductionParamProjection(interactiveParamEdit, active, built,
            pb_, ratio_);
    }
    final PreparedReductionParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedReductionParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        if (!before.filled) return image;
        Mesh baseline;
        auto baselineShadow = beginPreparedShadow(baseline);
        before.restore(baseline);
        uint baselineFlags, baselineDomains;
        drainPreparedShadowDelivery(baseline, baselineFlags, baselineDomains);
        baselineShadow.close();
        image.expectedBefore = MeshSnapshot.capture(baseline);
        image.deliveryFlags = image.deliveryDomains = 0;
        if (!interactiveParamEdit || !active) return image;
        image.applies = true; image.candidate = baseline; baseline = Mesh.init;
        auto shadow = beginPreparedShadow(image.candidate);
        if (image.candidate.faces.length == 0) {
            image.nextBuilt = false;
        } else {
            immutable size_t origFaces = image.candidate.faces.length;
            size_t target = cast(size_t)lround(ratio_ * cast(double)origFaces);
            if (target < 1) target = 1;
            if (target >= origFaces) {
                image.nextBuilt = false;
            } else {
                auto ed = MeshEditBatch.unrecorded(image.candidate,
                    kReduceEditScope);
                const n = ed.reduceToTarget(target, pb_);
                ed.close(); image.nextBuilt = (n != 0);
            }
        }
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        if (image.deliveryFlags == 0) {
            image.deliveryFlags = baselineFlags;
            image.deliveryDomains = baselineDomains;
        }
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedReductionParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) &&
            image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(ref PreparedReductionParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; image.clear();
    }
    final PreparedReductionParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedReductionParamEffect(
            preparedToolStateOwner, PreparedReductionParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedReductionParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedReductionParamKind.None :
            owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.prepareReductionParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedReductionParamEffect(preparedToolStateOwner, kind, ok);
    }
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        ratio_ = 0.5f; pb_ = true; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { ratio_ = value; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
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
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Reduce");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.Reduction,ok);
    }
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
