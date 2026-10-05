module tools.edit.poly_inset_tool;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import tools.topology_step;
import command : Command;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.poly_bevel;
import math;
import editmode : EditMode;
import params : Param;
import drag : viewWorldPerPixel;
import value_drag : ValueDrag, insetValueDragLaw;
import overlay_space : OverlaySpace;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts, PreparedPreviewRebuildImage;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_poly_inset_activation : PreparedPolyInsetActivationOwner;
import prepared_param_update : PreparedParamUpdateOwner,
    PreparedParamUpdateProducer;
import prepared_tool_effect : PreparedPolyInsetParamEffect,
    PreparedPolyInsetParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;

struct PreparedPolyInsetActivationImage {
    MeshSnapshot before;
    bool valid;
    void clear() nothrow @nogc { before = MeshSnapshot.init; valid = false; }
}

struct PolyInsetParamProjection {
    bool interactive, active, built;
    float inset;
    bool opEquals(const PolyInsetParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&inset, &other.inset, float.sizeof) == 0;
    }
}

struct PreparedPolyInsetParamImage {
    bool valid, applies, nextBuilt;
    PolyInsetParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    PreparedPreviewRebuildImage preview;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        preview.clear(); candidate = Mesh.init; valid = applies = false;
    }
}

// ---------------------------------------------------------------------------
// PolyInsetTool — interactive Polygon Inset (factory id `mesh.polyInsetTool`,
// task 0359 promotion of the one-shot `mesh.poly_inset` command).
//
// Grounded in the captured toolcard (in the private spec
// tree — not reproduced here beyond the geometry/behavior facts baked into
// mesh.insetFacesByMask):
//   - ONE attribute (`inset`, world units, default 0.0).
//   - Always per-polygon (no group/island toggle exists to diverge from).
//   - Sign law: positive shrinks (inward along the corner bisector), negative
//     grows (outward). The captured wording was "toward the centroid"; task
//     1190 measured that the DIRECTION is the bisector, not the centroid — the
//     two coincide on the square faces the toolcard was captured on.
//   - `inset == 0` is NOT a no-op — the kernel always performs the split.
//   - NO drawn gizmo/handle in the viewport (confirmed by capture screenshots
//     at idle/hover/drag) — draw() is intentionally empty. A plain click+drag
//     ANYWHERE over the viewport (while the tool is active, outside camera-nav
//     modifiers) drives the sole `inset` value: a generic, undecorated
//     "numeric haul" (the same un-rigged mechanism poly.bevel's Shift/Inset
//     rails and the smooth-shift tool's Shift use, just without their extra arrow
//     graphic — see toolcard `gestures[1]`).
//
// Drag law (measured, §26/§27; task 7122): HORIZONTAL travel only, stepped
// per pixel on the {1,2,5} ladder of 0.2·P with a detent near 20·P and a
// 36-px hold, signed, kept after release — the Stepped quantiser of the
// shared `value_drag.ValueDrag`.
//
// Each release records a history-owned mesh step and re-baselines the next
// drag on the completed image. The two-drag Z/Z/R/R chain is MCP-captured in
// toolcards/tool_session_preview_mcp_capture/raw/poly-inset-second-20260928.
// ---------------------------------------------------------------------------
class PolyInsetTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    // A recording command through the UI door closes the live edit first —
    // `Tool.commitOperation`'s in-place default — and the tool stays armed
    // (slice M2; the C1-h-sel-fam law, captured for Edge Extend and Polygon
    // Bevel and inferred for the rest of the in-place family, R20 gap g5).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true,
            commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress,
            imageAttrs: ["inset"], haulAttrs: ["inset"],
            // captured: a refire records no new mesh image (topology-redo S7r)
            redoPinsRefireImage: true
        };
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

    // Reference default (task 0359 toolcard: bit-exact 0.0). Deliberately
    // NOT changed to a safe non-zero value like the one-shot command
    // (commands/mesh/poly_inset.d) — this 0.0 is only ever a TRANSIENT
    // starting value: activate()/reinitSession() do not build a preview
    // (see reinitSession's doc-comment), so a session that ends without any
    // drag/param-edit/doApply never manufactures the degenerate zero-area
    // ring. Geometry is only ever produced once `inset_` has actually been
    // written to something (a drag, a panel edit, or an explicit
    // tool.attr), at which point the caller owns whatever value they chose.
    float inset_ = 0.0f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    PreviewRebuild preview_;     // the restore-and-rebuild seam (preview_rebuild.d)
    Viewport     cachedVp;

    // Haul drag state. No drawn handle to hit-test — any LMB press (outside
    // camera-nav modifiers) begins the haul directly. `valueDrag_` carries the
    // value in double between events (the rule is exact; `inset_` is its
    // float image) plus the step, detent and hold, all frozen at the press.
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

    override string name() const { return "Polygon Inset"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.0f),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedPolyInsetActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedPolyInsetActivationImage image;
        source = mesh;
        if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedPolyInsetActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragging = false;
        preview_.reset(); image.before.moveInto(before); image.valid = false;
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.PolyInset, false);
        scope(failure) context.discard();
        auto owner = PreparedPolyInsetActivationOwner.prepare(this);
        bool ok = owner !is null && context.preparePolyInsetActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.PolyInset, ok);
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        inset_ = 0.0f; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { inset_ = value; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; built = dragging = true; inset_ = 7;
        valueDrag_.pressX = 11; valueDrag_.lastX = 12;
        valueDrag_.value = 13; valueDrag_.law.step = 14;
        cachedVp.view[0] = 15;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const nothrow @nogc {
        return !active && built && dragging && inset_ == 7 &&
            valueDrag_.pressX == 11 && valueDrag_.lastX == 12 &&
            valueDrag_.value == 13 && valueDrag_.law.step == 14 &&
            cachedVp.view[0] == 15;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr) const nothrow @nogc {
        return active && !built && !dragging && inset_ == 7 && before.filled &&
            before.vertices.length == count && count && before.vertices[0] == first &&
            before.vertices.ptr !is livePtr && valueDrag_.pressX == 11 &&
            valueDrag_.lastX == 12 && valueDrag_.value == 13 &&
            valueDrag_.law.step == 14 && cachedVp.view[0] == 15;
    }

    private void reinitSession() {
        built    = false;
        dragging = false;
        preview_.reset();          // a new clean cage ⇒ a new topology key
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // Completed inset steps are owned by history.
        active   = false;
        built    = false;
        dragging = false;
        preview_.reset();          // drop the clean-cage scratch with the session
    }

    public override bool hasUncommittedEdit() const {
        return active && dragging && built;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    mixin SessionCommitHooks;
    mixin TopologyStepClientBody!("Inset", before);
    override void rebaseTopologyStep(MeshSnapshot basis) {
        before = basis;
        preview_.reset();
        built = !before.matches(*mesh);
        dragging = false;
        refreshCaches();
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private PolyInsetParamProjection paramProjection() const nothrow @nogc {
        return PolyInsetParamProjection(interactiveParamEdit, active, built, inset_);
    }
    final PreparedPolyInsetParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedPolyInsetParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        // Above the early return: the preview conjunct below is unconditional
        // (the cold-arm hole, task 4491).
        {
            auto cageShadow = beginPreparedShadow(image.preview.nextCage);
            preview_.prepareImage(image.preview);
            uint cageFlags, cageDomains;
            drainPreparedShadowDelivery(image.preview.nextCage, cageFlags,
                cageDomains);
            cageShadow.close();
        }
        if (!before.filled) return image;
        image.expectedBefore = before;
        if (!interactiveParamEdit || !active) return image;
        image.applies = true;
        auto shadow = beginPreparedShadow(image.candidate);
        image.expectedLive.restore(image.candidate);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        image.deliveryFlags = image.deliveryDomains = 0;
        PreviewRebuild preparedPreview; preparedPreview.loadPreparedNext(image.preview);
        image.nextBuilt = preparedPreview.run(image.candidate, before,
            &previewKey, &previewKernel) != 0;
        preparedPreview.savePreparedNext(image.preview);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedPolyInsetParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) && image.expectedBefore.matches(before) &&
            preview_.matchesImage(image.preview);
    }
    final void installPreparedParamUpdate(ref PreparedPolyInsetParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; preview_.installImage(image.preview); image.clear();
    }
    /// The preview seam's counters (read by the churn test).
    public PreviewRebuildCounts previewRebuildCounts() const {
        return preview_.counts();
    }
    mixin PreparedParamUpdateProducer!(PreparedParamUpdateOwner!(PolyInsetTool,
        PreparedPolyInsetParamImage, PreparedPolyInsetParamKind), PreparedPolyInsetParamEffect);
    override void evaluate() {}

    // Headless apply (tool.doApply) — the Post-Mode path a panel numeric
    // edit + Apply button drives (toolcard `gestures[0]`, "panel-apply").
    // MUST NOT snapshot — ToolDoApplyCommand wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        preview_.reset();   // the live mesh is rebuilt behind the seam's back
        if (mesh.faces.length == 0) return false;
        auto mask = currentMask();
        // Task 1903 Stage F2 — the batch opens at the TOOL boundary (§4.1).
        // This is the COMMIT path (`tool.doApply` / the panel Apply button),
        // so one deferred stamp at `close()`. UNRECORDED all the same: this
        // ToolDoApplyCommand owns this headless edit's snapshot pair, so a
        // recording batch would build an op-log nothing reads.
        // Stage M owns the tool pair-holders; Stage L7 owns this family's
        // delta undo.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
            n = ed.insetFacesByMask(mask, inset_);
            ed.close();
        }
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { closeOwnOperation(false); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera nav
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        // No drawn handle to hit-test (task 0359 toolcard: confirmed no
        // gizmo graphic at idle/hover/drag) — any qualifying click begins
        // the generic haul directly.
        sessionStepBegins();
        dragging = true;
        // Step and detent come from the VIEW's pixel size (§27: no anchor
        // term), converted into the LOCAL units `insetFacesByMask` means by
        // the declared mean (task 0645) — the inset has no direction.
        const auto os = OverlaySpace.ofPrimary();
        valueDrag_.press(e.x, inset_,
            insetValueDragLaw(viewWorldPerPixel(cachedVp), os.meanWorldPerLocal()));
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        // §27: the last value is kept, signed.
        inset_ = cast(float) valueDrag_.release();
        sessionStepEnds();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        // §27: every pixel of HORIZONTAL travel is one stepped pixel of the
        // shared value drag (vertical travel is not read); the per-event
        // pixel count is capped inside `value_drag.steppedDragEvent`.
        const int wanted = e.x - valueDrag_.lastX;
        inset_ = cast(float) valueDrag_.motion(e.x);
        if (valueDrag_.lastStepped < (wanted < 0 ? -wanted : wanted)) {
            import std.stdio : stderr;
            stderr.writefln("[inset] drag event of %d px clamped to %d",
                wanted, valueDrag_.lastStepped);
        }
        rebuildPreview();
        return true;
    }

    // No drawn gizmo/handle (task 0359 toolcard: confirmed absent at idle/
    // hover/drag in every captured screenshot) — intentionally empty.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching
    // the mesh.poly_inset command convention).
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandFaceMask();
    }

    // Re-run from the clean cage at the current `inset_` through the seam (a
    // key change restores and rebuilds; an unchanged key moves positions only).
    void rebuildPreview() {
        if (!active) return;
        if (previewGated()) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        built = preview_.run(*mesh, before, &previewKey, &previewKernel) != 0;
        refreshCaches();
    }

    // The topology key: the operand mask only. The kernel has no degenerate
    // branch (`inset == 0` still splits, mesh_ops/poly_bevel.d) and its
    // collinear-start refusal reads the cage, not the parameter.
    PreviewTopologyKey previewKey(ref Mesh cage) {
        return PreviewTopologyKey.make(cage.operandFaceMask(), false);
    }
    // Unrecorded: a preview frame records nothing.
    size_t previewKernel(ref Mesh target) {
        auto mask = target.operandFaceMask();
        auto ed = MeshEditBatch.unrecorded(target, kPolyBevelEditScope);
        const n = ed.insetFacesByMask(mask, inset_);
        ed.close();
        return n;
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        if (c is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.PolyInset, false, false);
        const accepted = c.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.PolyInset, false, accepted);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        preview_.reset();
        built    = false;
        dragging = false;
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }
}
