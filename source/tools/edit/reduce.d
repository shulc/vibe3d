module tools.edit.reduce;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedPrivateStateToolDoorClient;
import prepared_private_state : PreparedPrivateStateOwner;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.decimate : reduceToTarget, kReduceEditScope;
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
import prepared_param_update : PreparedParamUpdateOwner,
    PreparedParamUpdateProducer, DefaultParamEffectKind;
import prepared_tool_effect : PreparedReductionParamEffect,
    PreparedReductionParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
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
    mixin DefaultParamEffectKind!PreparedReductionParamKind;
    bool valid;
    ReductionParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        valid = false;
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
class ReductionTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient {
    // A recording command through the UI door closes the live edit first —
    // `Tool.commitOperation`'s in-place default — and the tool stays armed
    // (slice M2; the C1-h-sel-fam law, captured for Edge Extend and Polygon
    // Bevel and inferred for the rest of the in-place family, R20 gap g5).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyRecordedSteps: true };
        return policy;
    }

    mixin PreparedNamedGpuParamDoorClient;
    mixin PreparedPrivateStateToolDoorClient!(Layer,
        PreparedPrivateStateOwner.reductionSession);
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
        // onto these fields by the attribute cache recall
        // (prepareStickyToolDefaults, from the prepared arm) BEFORE activate()
        // runs —
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
    final PreparedReductionParamImage buildPreparedParamUpdate(string, ref const Mesh live) {
        PreparedReductionParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.expectedLive = MeshSnapshot.capture(live);
        image.expectedBefore = before;
        return image;
    }
    final bool preparedParamUpdateMatches(in PreparedReductionParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) &&
            image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(ref PreparedReductionParamImage image)
            nothrow @nogc {
        image.clear();
    }
    mixin PreparedParamUpdateProducer!(PreparedParamUpdateOwner!(ReductionTool,
        PreparedReductionParamImage, PreparedReductionParamKind), PreparedReductionParamEffect);
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
        if (operation(*mesh) == 0) return false;
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
        built = operation(*mesh) != 0;
        refreshDisplay(mesh, gpu);
    }

    // The one operation (task 9433): preview and scripted
    // apply. A ratio that keeps every face (or a faceless mesh) is the
    // kernel's own no-op (it returns 0 for a target at or above the count).
    // UNRECORDED (task 1903 D2): a preview frame must not build an op-log per
    // drag frame, and the apply's snapshot pair belongs to `ToolDoApplyCommand`.
    // The batch closes before the caller's `refreshDisplay`, which reads the
    // version stamps the batch defers.
    size_t operation(ref Mesh target) {
        immutable size_t origFaces = target.faces.length;
        size_t keep = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (keep < 1) keep = 1;
        auto ed = MeshEditBatch.unrecorded(target, kReduceEditScope);
        const n = ed.reduceToTarget(keep, pb_);
        ed.close();
        return n;
    }

    // Record the interactive session as one snapshot-pair undo entry.
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool accepted;
        if (active && built && c !is null && history !is null &&
            gestureFactory !is null && before.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd !is null) {
                cmd.setSnapshots(before, MeshSnapshot.capture(*mesh), "Reduce");
                accepted = c.prepare(cmd, PreparedHistoryKind.Plain).accepted;
                if (accepted) sessionTagPreparedCompleted(cmd);
            }
        }
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Reduction, accepted);
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
