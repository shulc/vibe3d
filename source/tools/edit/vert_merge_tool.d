module tools.edit.vert_merge_tool;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import editmode : EditMode;
import params : Param;
import drag : viewWorldPerPixel;
import value_drag : ValueDrag, mergeValueDragLaw;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import command_history : PreparedHistoryKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_vertex_merge_activation : PreparedVertexMergeActivationOwner;
import prepared_vertex_merge_param_update : PreparedVertexMergeParamUpdateOwner;
import prepared_tool_effect : PreparedVertexMergeParamEffect,
    PreparedVertexMergeParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;

struct VertexMergeParamProjection {
    bool interactive, active, built;
    float dist;
    bool opEquals(const VertexMergeParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&dist, &other.dist, float.sizeof) == 0;
    }
}

struct PreparedVertexMergeParamImage {
    bool valid, applies, nextBuilt;
    VertexMergeParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; valid = applies = false;
    }
}

struct PreparedVertexMergeActivationImage {
    MeshSnapshot before;
    bool valid;
    void clear() nothrow @nogc {
        before = MeshSnapshot.init;
        valid = false;
    }
}

// ---------------------------------------------------------------------------
// VertexMergeTool — interactive Vertex Merge (factory id `vert.merge`,
// task 0360 promotion of the one-shot `vert.merge` command).
//
// Grounded in the captured toolcard (private spec tree — not reproduced
// here beyond the geometry/behavior facts baked into
// mesh.weldVerticesByMask, source/mesh.d — see that kernel's doc-comment
// for the full captured-law writeup):
//   - ONE attribute exposed on the interactive tool: `dist` (Distance,
//     world units, default 0.001 — bit-exact match to the pre-existing
//     one-shot command's own default, and to the reference's own live-
//     confirmed default). NO drawn gizmo/handle at idle/hover/drag — a
//     plain click+drag ANYWHERE over the viewport hauls the threshold
//     directly (the SAME undecorated "numeric haul" family as
//     mesh.polyInsetTool): horizontal, press-relative, gain 0.05·P —
//     `value_drag.d`, measured law §26, task 7122.
//   - Threshold law: welds any two (or, transitively, more) SELECTED
//     vertices whose distance apart is <= dist (inclusive boundary,
//     confirmed at the exact grid-edge-length boundary of a captured
//     test mesh). mesh.weldVerticesByMask's own boundary check was fixed
//     to `<=` (from a strict `<`) to match — see its doc-comment for the
//     parity evidence and the still-open transitive/connected-component
//     clustering caveat this port did NOT fully resolve.
//   - The one-shot command's `range` auto/fixed toggle and the `keep`/
//     `morph` attributes are COMMAND-only in the reference (the captured
//     toolcard confirms them absent from the interactive tool's own
//     panel — only Distance/Keep/Morph appear there, and even Keep/Morph
//     have no vibe3d counterpart honored yet). This tool deliberately
//     does NOT expose `range`; it always runs the reference's "always a
//     plain Distance field" mode by calling `weldVerticesByMask` directly
//     rather than routing through the one-shot MeshVertMerge command
//     (which keeps its own `range`/`keep`/`morph` params for the
//     one-shot/menu path, untouched by this tool).
//
// Session lifecycle mirrors PolyInsetTool (one attribute, no drawn handle,
// generic viewport haul, topology-mutating via a shared MeshSessionEdit
// before/after snapshot).
// ---------------------------------------------------------------------------
class VertexMergeTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient {
    // A recording command through the UI door closes the live edit first —
    // `Tool.commitOperation`'s in-place default — and the tool stays armed
    // (slice M2; the C1-h-sel-fam law, captured for Edge Extend and Polygon
    // Bevel and inferred for the rest of the in-place family, R20 gap g5).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        import tool_activation_ownership : CommandClose;
        static immutable ToolSessionPolicy policy = { commandClose: CommandClose.uiDoor };
        return policy;
    }

    mixin PreparedGpuParamDoorClient;
    mixin PreparedSimpleToolDoorClient!Layer;
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    // Reference default (task 0360 toolcard: live-confirmed bit-exact
    // 1mm), matching vibe3d's pre-existing one-shot command default
    // (dist_ = 0.001f).
    float dist_ = 0.001f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    // Haul drag state. No drawn handle to hit-test — any LMB press
    // (outside camera-nav modifiers, with a live vertex selection) begins
    // the haul directly. The value law is the shared press-relative
    // horizontal drag (`value_drag`); its gain is frozen at the
    // press.
    bool      dragging;
    ValueDrag valueDrag_;

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
    }

    override string name() const { return "Vertex Merge"; }

    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [
            Param.float_("dist", "Distance", &dist_, 0.001f).min(0.0f).fmt("%.4f"),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedVertexMergeActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedVertexMergeActivationImage image;
        source = mesh;
        if (source is null) return image;
        image.before = MeshSnapshot.capture(*source);
        image.valid = true;
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedVertexMergeActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragging = false; dist_ = 0.001f;
        image.before.moveInto(before);
        image.valid = false;
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.VertexMerge, false);
        scope(failure) context.discard();
        auto owner = PreparedVertexMergeActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareVertexMergeActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.VertexMerge, ok);
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(
            ref Mesh oldMesh) {
        active = false; built = true; dragging = true; dist_ = 7.0f;
        valueDrag_.pressX = 11; valueDrag_.lastX = 12;
        valueDrag_.pressValue = 13; valueDrag_.law.gain = 14;
        cachedVp.view[0] = 15;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragging && dist_ == 7.0f &&
            valueDrag_.pressX == 11 && valueDrag_.lastX == 12 &&
            valueDrag_.pressValue == 13 && valueDrag_.law.gain == 14 &&
            cachedVp.view[0] == 15;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr) const nothrow @nogc {
        return active && !built && !dragging && dist_ == 0.001f &&
            before.filled && before.vertices.length == count && count != 0 &&
            before.vertices[0] == first && before.vertices.ptr !is livePtr &&
            valueDrag_.pressX == 11 && valueDrag_.lastX == 12 &&
            valueDrag_.pressValue == 13 && valueDrag_.law.gain == 14 &&
            cachedVp.view[0] == 15;
    }

    private void reinitSession() {
        built    = false;
        dragging = false;
        dist_    = 0.001f;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built) commitEdit();
        active   = false;
        built    = false;
        dragging = false;
    }

    public override bool hasUncommittedEdit() const {
        return active && built;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    public override bool commitUncommittedEdit() {
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
    private VertexMergeParamProjection paramProjection() const nothrow @nogc {
        return VertexMergeParamProjection(interactiveParamEdit, active, built,
            dist_);
    }
    final PreparedVertexMergeParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedVertexMergeParamImage image;
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
        if (!interactiveParamEdit || !active) return image;
        image.applies = true; image.candidate = baseline; baseline = Mesh.init;
        auto shadow = beginPreparedShadow(image.candidate);
        if (!image.candidate.hasAnySelectedVertices()) {
            image.nextBuilt = false;
        } else {
            const double epsSq = kernelEpsSq();
            const n = image.candidate.weldVerticesByMask(
                image.candidate.selectedVertices, epsSq, true);
            image.nextBuilt = (n != 0);
        }
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        if (image.deliveryFlags == 0) {
            image.deliveryFlags = baselineFlags;
            image.deliveryDomains = baselineDomains;
        }
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(
            in PreparedVertexMergeParamImage image, ref const Mesh live) const
            nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) &&
            image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(
            ref PreparedVertexMergeParamImage image) nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; image.clear();
    }
    final PreparedVertexMergeParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedVertexMergeParamEffect(
            preparedToolStateOwner, PreparedVertexMergeParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedVertexMergeParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedVertexMergeParamKind.None :
            owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.prepareVertexMergeParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedVertexMergeParamEffect(preparedToolStateOwner, kind, ok);
    }
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        dist_ = 3.0f; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { dist_ = value; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
    }
    override void evaluate() {}

    // Headless apply (tool.doApply) — MUST NOT snapshot; ToolDoApplyCommand
    // wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Vertices) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.vertices.length == 0) return false;
        if (!mesh.hasAnySelectedVertices()) return false;
        double epsSq = kernelEpsSq();
        // average:true — survivor at per-cluster centroid, matching the
        // vert.merge command path (source/commands/mesh/vert_merge.d).
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera nav
        if (*editMode != EditMode.Vertices) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // No drawn handle to hit-test (task 0360 toolcard: confirmed no
        // gizmo graphic at idle/hover/drag) — any qualifying click begins
        // the generic haul directly.
        dragging = true;
        // The gain is the VIEW's pixel size (§26: no anchor term), converted
        // into the LOCAL units the merge threshold means (task 0645) by the
        // declared mean — a threshold has no direction.
        const auto os = OverlaySpace.ofPrimary();
        valueDrag_.press(e.x, dist_,
            mergeValueDragLaw(viewWorldPerPixel(cachedVp), os.meanWorldPerLocal()));
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        // §26: the value kept after release is max(0, last). No rebuild: a
        // negative value already previewed as zero (`kernelEpsSq`).
        dist_ = cast(float) valueDrag_.release();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        // §26: `dist = dist_press + 0.05·P·Δx`, Δx the HORIZONTAL
        // offset from the press pixel; vertical travel changes nothing, and
        // the value is signed while the button is held.
        dist_ = cast(float) valueDrag_.motion(e.x);
        rebuildPreview();
        return true;
    }

    // No drawn gizmo/handle (task 0360 toolcard: confirmed absent at idle/
    // hover/drag in every captured screenshot) — intentionally empty.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    // Revert to the pre-merge cage + selection, then re-run the kernel from
    // the current `dist_`. Per-tick re-evaluate: WRITE the param + RE-RUN,
    // never incrementally mutate the already-welded mesh.
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (!mesh.hasAnySelectedVertices()) {
            built = false;
            refreshCaches();
            return;
        }
        double epsSq = kernelEpsSq();
        // average:true — survivor at per-cluster centroid, matching the
        // vert.merge command path (source/commands/mesh/vert_merge.d).
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Merge Vertices");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.VertexMerge,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Merge Vertices");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    // The threshold the weld kernel runs with: a negative drag value (signed
    // mid-drag, §26) welds what a zero threshold welds, never |dist|.
    double kernelEpsSq() const nothrow @nogc {
        const double d = dist_ > 0 ? cast(double) dist_ : 0.0;
        return d * d;
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragging = false;
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }
}
