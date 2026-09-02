module tools.edit.poly_inset_tool;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import drag : haulWorldPerPixel, gesturePrevPixel;
import overlay_space : OverlaySpace;
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
import prepared_poly_inset_activation : PreparedPolyInsetActivationOwner;
import prepared_poly_inset_param_update : PreparedPolyInsetParamUpdateOwner;
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
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; valid = applies = false;
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
// Drag law (NOT captured — flagged as an open TODO in the toolcard's
// viewport-drag finding): this implementation maps vertical screen motion
// (drag UP = increase inset, matching this codebase's other haul tools'
// "up/out = positive" convention) to world units via the same
// perspective/zoom-correct `gizmoSize` scale poly_bevel.d uses for its arrow
// handles, anchored at the selected faces' centroid. If a captured
// drag-distance→value law ever lands, only `motionHaul`'s scale factor needs
// to change — the rest of the session/undo plumbing is unaffected.
//
// Session lifecycle mirrors PolyBevelTool (its closest sibling: one
// attribute, topology-creating, per-face independent): activate() snapshots
// the clean cage; a drag/param-edit reverts to that cage and RE-RUNS the
// kernel from the current `inset_` (rebuildPreview — never vertex-transforms
// the already-split ridge); deactivate() commits ONE undo entry if any
// topology was built. This does NOT reproduce the reference editor's
// per-release auto-chain (each haul-release committing its own step, so a
// second drag insets the FRESH inner faces) — that would need a materially
// different commit lifecycle than every other topology tool in this
// codebase uses, and the toolcard does not treat it as a load-bearing
// requirement. Deferred; see task 0359 Лог.
// ---------------------------------------------------------------------------
class PolyInsetTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient {
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
    Viewport     cachedVp;

    // Haul drag state. No drawn handle to hit-test — any LMB press (outside
    // camera-nav modifiers) begins the haul directly.
    bool  dragging;
    int   dragLastMX, dragLastMY;
    float dragBaseInset;
    // Frozen at drag-start (see haulAnchor) — the LOCAL length one pixel is
    // worth at the anchor, item transform included (task 0645).
    float localPerPixel;

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
        active = true; built = false; dragging = false; inset_ = 0.0f;
        image.before.moveInto(before); image.valid = false;
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
        dragLastMX = 11; dragLastMY = 12; dragBaseInset = 13;
        localPerPixel = 14; cachedVp.view[0] = 15;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const nothrow @nogc {
        return !active && built && dragging && inset_ == 7 &&
            dragLastMX == 11 && dragLastMY == 12 && dragBaseInset == 13 &&
            localPerPixel == 14 && cachedVp.view[0] == 15;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr) const nothrow @nogc {
        return active && !built && !dragging && inset_ == 0 && before.filled &&
            before.vertices.length == count && count && before.vertices[0] == first &&
            before.vertices.ptr !is livePtr && dragLastMX == 11 &&
            dragLastMY == 12 && dragBaseInset == 13 && localPerPixel == 14 &&
            cachedVp.view[0] == 15;
    }

    private void reinitSession() {
        built    = false;
        dragging = false;
        inset_   = 0.0f;
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
    private PolyInsetParamProjection paramProjection() const nothrow @nogc {
        return PolyInsetParamProjection(interactiveParamEdit, active, built, inset_);
    }
    final PreparedPolyInsetParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedPolyInsetParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        if (!before.filled) return image;
        auto shadow = beginPreparedShadow(image.candidate);
        before.restore(image.candidate);
        image.expectedBefore = MeshSnapshot.capture(image.candidate);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        image.deliveryFlags = image.deliveryDomains = 0;
        if (!interactiveParamEdit || !active) { shadow.close(); return image; }
        image.applies = true;
        auto mask = image.candidate.operandFaceMask();
        auto ed = MeshEditBatch.unrecorded(image.candidate, kPolyBevelEditScope);
        const n = ed.insetFacesByMask(mask, inset_);
        ed.close(); image.nextBuilt = (n != 0);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedPolyInsetParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) && image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(ref PreparedPolyInsetParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; image.clear();
    }
    final PreparedPolyInsetParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedPolyInsetParamEffect(
            preparedToolStateOwner, PreparedPolyInsetParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedPolyInsetParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedPolyInsetParamKind.None : owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.preparePolyInsetParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedPolyInsetParamEffect(preparedToolStateOwner, kind, ok);
    }
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
        if (mesh.faces.length == 0) return false;
        auto mask = currentMask();
        // Task 1903 Stage F2 — the batch opens at the TOOL boundary (§4.1).
        // This is the COMMIT path (`tool.doApply` / the panel Apply button),
        // so one deferred stamp at `close()`. UNRECORDED all the same: this
        // tool's undo is the whole-mesh `MeshSnapshot` pair `commitEdit()`
        // records, so a recording batch would build an op-log nothing reads.
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
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera nav
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        // No drawn handle to hit-test (task 0359 toolcard: confirmed no
        // gizmo graphic at idle/hover/drag) — any qualifying click begins
        // the generic haul directly, anchored at the selected faces'
        // centroid (empty selection ⇒ whole-mesh centroid, matching
        // currentMask's empty-selection convention).
        dragging       = true;
        dragLastMX     = e.x;
        dragLastMY     = e.y;
        dragBaseInset  = inset_;
        // Anchored where the geometry is DRAWN, and converted back into the
        // LOCAL units `insetFacesByMask` means (task 0645). The inset is a
        // distance with no direction, so the conversion is the declared mean
        // — see `OverlaySpace.meanWorldPerLocal`.
        const auto os  = OverlaySpace.ofPrimary();
        localPerPixel  = haulWorldPerPixel(os.pos(haulAnchor()), cachedVp)
                       / os.meanWorldPerLocal();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        // Vertical screen delta → world inset delta. Drag UP (screen Y
        // decreases) increases inset. See the class doc-comment for why this
        // particular law was picked (drag calibration is uncaptured).
        // The previous pixel comes from the cooked gesture, not from this
        // tool's own pair. Same integer subtraction, sourced one level up;
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        float dyPixels = cast(float)(prevMY - e.y);
        inset_ = dragBaseInset + dyPixels * localPerPixel;
        dragLastMX = e.x;
        dragLastMY = e.y;
        rebuildPreview();
        return true;
    }

    // No drawn gizmo/handle (task 0359 toolcard: confirmed absent at idle/
    // hover/drag in every captured screenshot) — intentionally empty.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching
    // the mesh.poly_inset command convention).
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandFaceMask();
    }

    // The selected faces' centroid — this tool's anchor for the pixel→world
    // haul scale. The scale itself is `drag.haulWorldPerPixel` (LAW C of the
    // conversion seam); only the anchor is ours.
    Vec3 haulAnchor() {
        Vec3 anchor = Vec3(0, 0, 0);
        bool any = mesh.hasAnySelectedFaces();
        int cnt = 0;
        foreach (fi; 0 .. mesh.faces.length) {
            if (any && !mesh.isFaceSelected(fi)) continue;
            anchor = anchor + mesh.faceCentroid(cast(uint)fi);
            ++cnt;
        }
        if (cnt > 0) anchor = anchor * (1.0f / cast(float)cnt);
        return anchor;
    }

    // Revert to the pre-inset cage + selection, then re-run the kernel from
    // the current `inset_`. This is the per-tick re-evaluate: WRITE the
    // param + RE-RUN, never vertex-transform the post-inset ridge.
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        auto mask = currentMask();
        // Task 1903 Stage F2 — ONE UNRECORDED batch per DRAG FRAME, and
        // unrecorded is not a convenience here: plan §9 is explicit that a
        // recording batch opened per frame would build and throw away a full
        // op-log at 60 Hz. This tool keeps the plain `before.restore(*mesh)`
        // preview shape (it is not one of `preview_rebuild.d`'s three), so the
        // batch is on the LIVE mesh and the frame's deferred stamp lands at
        // `close()` — one per frame instead of one per appended corner vertex
        // and ring quad. That is the STAMP; DELIVERIES are a separate count
        // with a separate mechanism, and the drag test records the measured
        // per-frame figure rather than assuming it follows the stamp.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
            n = ed.insetFacesByMask(mask, inset_);
            ed.close();
        }
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Inset");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.PolyInset,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Inset");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
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
