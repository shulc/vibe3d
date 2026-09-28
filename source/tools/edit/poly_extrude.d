module tools.edit.poly_extrude;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import command : Command;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.extrude;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : PreparedPlaneDrag, automaticPlanePressHit, preparePlaneDrag,
    screenAxisDelta, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_poly_extrude_activation : PreparedPolyExtrudeActivationOwner;
import prepared_poly_extrude_param_update : PreparedPolyExtrudeParamUpdateOwner;
import prepared_tool_effect : PreparedPolyExtrudeParamEffect,
    PreparedPolyExtrudeParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;
import tools.transform.relocate_plane : vectorSnap;
import tools.create.create_common : primitiveParameterFrame, transformDir;
import viewgrid : g_viewGrid, viewWorldPerPixel, viewGridSize,
    viewGridSubStep;

version (unittest) {
    private enum PolyDragPressStage { upstreamB0, jacobianInput }
    private struct PolyDragPressRecord { PolyDragPressStage stage; Vec3 value; }
    private PolyDragPressRecord[] polyDragPressRecords;
    private void recordPolyDragPress(PolyDragPressStage stage, Vec3 value) {
        polyDragPressRecords ~= PolyDragPressRecord(stage, value);
    }
}

struct PreparedPolyExtrudeActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, extrudeAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc { this = PreparedPolyExtrudeActivationImage.init; }
}

struct PolyExtrudeParamProjection {
    bool interactive, active, built;
    float distance, shiftX, shiftY, shiftZ;
    Vec3 extentFrameX = Vec3(1, 0, 0);
    Vec3 extentFrameY = Vec3(0, 1, 0);
    Vec3 extentFrameZ = Vec3(0, 0, 1);
    bool opEquals(const PolyExtrudeParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&distance, &other.distance, float.sizeof) == 0 &&
            memcmp(&shiftX, &other.shiftX, float.sizeof) == 0 &&
            memcmp(&shiftY, &other.shiftY, float.sizeof) == 0 &&
            memcmp(&shiftZ, &other.shiftZ, float.sizeof) == 0 &&
            extentFrameX == other.extentFrameX &&
            extentFrameY == other.extentFrameY &&
            extentFrameZ == other.extentFrameZ;
    }
}

struct PreparedPolyExtrudeParamImage {
    bool valid, applies, nextBuilt;
    PolyExtrudeParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; valid = applies = false;
    }
}

// ---------------------------------------------------------------------------
// PolyExtrudeTool — interactive Face Extrude (factory id `poly.extrude`).
//
// Task 8030: Polygon Extrude uses the same history-owned topology-step
// contract as Edge Extrude. Each completed drag, Middle/Shift boundary and
// interactive parameter write owns one MeshSessionEdit; `before` is only the
// current operation's preview basis. The Polygon first group carries its
// activation and opens at the first press; these are policy data, not a
// ToolSession class branch. Evidence: W2 plan and test_poly_extrude_drag.d.
//
// The normal arrow changes `distance`. An off-handle haul translates the cap
// in the view plane through the Shift X/Y/Z parameter image.
//
// The headless distance path is unchanged; ToolDoApplyCommand owns its
// snapshot pair for undo.
// ---------------------------------------------------------------------------
class PolyExtrudeTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    // Polygon opens at its first press and its first topology row carries the
    // activation; later rows remain independent history entries.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, recordCarriesActivation: true,
            commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            dormantAfterClosedRedo: true,
            opensAt: OpensAt.firstPress,
            imageAttrs: ["distance", "shiftX", "shiftY", "shiftZ"],
            haulAttrs: ["distance", "shiftX", "shiftY", "shiftZ"]
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

    // Parameters.
    float distance_ = 0.0f;
    float shiftX_ = 0.0f, shiftY_ = 0.0f, shiftZ_ = 0.0f;

    // Interactive session state.
    bool          active;
    bool          built;
    bool          topologyDormant;
    MeshSnapshot  before;
    Viewport      cachedVp;

    // Gizmo frame.
    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 extrudeAxis;
    ulong gizmoSelHash;

    // Drag state.
    enum int PART_EXTRUDE = 0;
    enum int PART_FREE    = 1;   // off-handle view-plane haul
    int   dragPart = -1;
    int   dragButton_;
    int   dragLastMX, dragLastMY;
    int   dragStartMX, dragStartMY;
    Vec3  dragBaseShift;
    Viewport dragVp;
    int dragPressContentX, dragPressContentY;
    float dragSnapStep;
    Vec3 dragUpstreamBase, dragSnapBase;
    PreparedPlaneDrag dragPlane;
    OverlaySpace dragOverlay;

    // Cached workplane/overlay frame image. Parameters remain Extent-local;
    // this basis is the sole conversion used by live and prepared cap writes.
    Vec3 extentFrameX = Vec3(1, 0, 0);
    Vec3 extentFrameY = Vec3(0, 1, 0);
    Vec3 extentFrameZ = Vec3(0, 0, 1);

    Arrow       extrudeArrow;
    ToolHandles toolHandles;

    enum Vec3 EXTRUDE_COLOR = schemeColor(SchemeColor.toolOffset);

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        extrudeArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 1, 0), EXTRUDE_COLOR);
        toolHandles  = new ToolHandles();
    }

    void destroy() {
        if (extrudeArrow !is null) extrudeArrow.destroy();
    }

    override string name() const { return "Face Extrude"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.float_("distance", "Distance", &distance_, 0.0f),
            Param.float_("shiftX", "Shift X", &shiftX_, 0.0f),
            Param.float_("shiftY", "Shift Y", &shiftY_, 0.0f),
            Param.float_("shiftZ", "Shift Z", &shiftZ_, 0.0f),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedPolyExtrudeActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedPolyExtrudeActivationImage image;
        source = mesh; if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        image.anchor = anchor; image.baseAnchor = baseAnchor;
        image.extrudeAxis = extrudeAxis;
        computePreparedGizmoFrame(*source, image);
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedPolyExtrudeActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1;
        distance_ = shiftX_ = shiftY_ = shiftZ_ = 0.0f;
        resetExtentFrame();
        image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;
        gizmoSelHash = image.gizmoSelHash; image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.PolyExtrude, false);
        scope(failure) context.discard();
        auto owner = PreparedPolyExtrudeActivationOwner.prepare(this);
        bool ok = owner !is null && context.preparePolyExtrudeActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.PolyExtrude, ok);
    }

    private void reinitSession() {
        built     = false;
        dragPart  = -1;
        distance_ = shiftX_ = shiftY_ = shiftZ_ = 0.0f;
        before    = MeshSnapshot.capture(*mesh);
        resetExtentFrame();
        computeGizmoFrame();
    }

    override void deactivate() {
        // Completed images already belong to CommandHistory.
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && (distance_ != 0.0f || shiftVec() != Vec3(0, 0, 0));
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
        return false; // Shift starts the next topology operation below.
    }

    public override bool commitOperation() {
        if (!active) return false;
        resyncSession();
        return true;
    }

    public override Mesh* topologyStepMesh() { return mesh; }
    public override MeshSnapshot topologyStepBasis() { return before; }
    public override Command topologyStepCarrier() {
        return gestureFactory is null ? null : gestureFactory();
    }
    public override bool recordTopologyStep(Command cmd) {
        return recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
    public override string topologyStepLabel() { return "Face Extrude"; }
    public override void setTopologyDormant(bool dormant) {
        topologyDormant = dormant;
    }
    public override void rebaseTopologyStep(MeshSnapshot basis) { before = basis; }
    public override void restoreTopologyStep(in AttrImage attrs,
            MeshSnapshot basis) {
        before = basis;
        auto visible = MeshSnapshot.capture(*mesh);
        before.restore(*mesh);
        computeGizmoFrame();
        visible.restore(*mesh);
        restoreRecordedAttrs(attrs);
        built = !before.matches(*mesh);
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private PolyExtrudeParamProjection paramProjection() const nothrow @nogc {
        return PolyExtrudeParamProjection(interactiveParamEdit, active, built,
            distance_, shiftX_, shiftY_, shiftZ_,
            extentFrameX, extentFrameY, extentFrameZ);
    }
    final PreparedPolyExtrudeParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedPolyExtrudeParamImage image;
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
        if (distance_ == 0.0f && shiftVec() == Vec3(0, 0, 0))
            image.nextBuilt = false;
        else {
            auto mask = image.candidate.operandFaceMask();
            auto ed = MeshEditBatch.unrecorded(image.candidate, kExtrudeEditScope);
            const n = ed.extrudeFacesByMask(mask, distance_, false,
                UvWallLaw.SweepU, shiftVec() != Vec3(0, 0, 0),
                FaceExtrudeOrder.WallsThenCap);
            if (n != 0) applyCapShift(ed, extentToMesh(shiftVec()));
            ed.close(); image.nextBuilt = (n != 0);
        }
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedPolyExtrudeParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) && image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(ref PreparedPolyExtrudeParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; image.clear();
    }
    final PreparedPolyExtrudeParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedPolyExtrudeParamEffect(
            preparedToolStateOwner, PreparedPolyExtrudeParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedPolyExtrudeParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedPolyExtrudeParamKind.None : owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.preparePolyExtrudeParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedPolyExtrudeParamEffect(preparedToolStateOwner, kind, ok);
    }
    override void evaluate() {}

    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        if (distance_ == 0.0f) return true;   // identity is a clean no-op
        auto mask = currentMask();
        // task 1903 Stage H: extrudeFacesByMask takes `ref MeshEditBatch`
        // now. `commitEdit` below undoes via a MeshSnapshot pair, not the
        // op-log, so the batch is unrecorded.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeFacesByMask(mask, distance_);
        ed.close();
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            closeOwnOperation(false);
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT && e.button != SDL_BUTTON_MIDDLE) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;
        if (e.button == SDL_BUTTON_MIDDLE && (mods & (KMOD_SHIFT | KMOD_CTRL)))
            return false;
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0 || !gizmoValid) return false;

        const bool boundary = e.button == SDL_BUTTON_MIDDLE || (mods & KMOD_SHIFT);
        int part = toolHandles.test(e.x, e.y, cachedVp);
        const bool freeDrag = boundary || part != PART_EXTRUDE;
        const Vec3 downExtent = boundary || topologyDormant
            ? Vec3(0, 0, 0) : shiftVec();
        if (freeDrag && !prepareFreeDrag(e.x, e.y, downExtent)) return false;

        sessionStepBegins(e.button == SDL_BUTTON_MIDDLE ? PressKind.middle
            : boundary ? PressKind.shift : PressKind.plain);
        if (boundary) {
            before = MeshSnapshot.capture(*mesh);
            if (e.button != SDL_BUTTON_MIDDLE) {
                distance_ = shiftX_ = shiftY_ = shiftZ_ = 0.0f;
            }
            computeGizmoFrame();
        }
        // Polygon's zero tap is still a topology operation. The kernel keeps
        // its default zero-distance refusal for commands; only this interactive
        // boundary opts into coincident topology.
        rebuildPreview(true);

        dragLastMX       = e.x;
        dragLastMY       = e.y;
        dragStartMX      = e.x;
        dragStartMY      = e.y;
        dragBaseShift    = downExtent;
        dragButton_       = e.button;

        if (boundary) {
            dragPart = PART_FREE;
            return true;
        }

        if (part == PART_EXTRUDE) {
            dragPart = PART_EXTRUDE;
            toolHandles.setHaul(part);
            return true;
        }
        // Off-handle: view-plane cap haul.
        dragPart = PART_FREE;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;

        if (dragPart == PART_FREE) {
            if (dragPlane.valid) {
                // Exact captured Polygon law: the shared inverse
                // Jacobian is frozen at upstream-snapped B0; Polygon Down
                // freezes the idempotently snapped B1. Endpoint snap is
                // spatially anchored, cached-frame conversion follows it,
                // and the press-time Extent is added last.
                const Vec3 raw = dragPlane.apply(e.x - dragVp.x,
                    e.y - dragVp.y, dragPressContentX, dragPressContentY);
                const Vec3 d = vectorSnap(dragSnapBase + raw, dragSnapStep)
                             - dragSnapBase;
                const Vec3 local = dragBaseShift + dragOverlay.toLocalDelta(d);
                shiftX_ = local.x;
                shiftY_ = local.y;
                shiftZ_ = local.z;
            }
            // A Polygon gesture owns topology even when its current distance
            // is zero (captured zero-tap/Middle law).  Keep that opt-in for
            // every motion in the gesture; otherwise the helper's stationary
            // motion event would erase the coincident preview opened on down.
            rebuildPreview(true);
            dragLastMX = e.x;
            dragLastMY = e.y;
            return true;
        }

        // PART_EXTRUDE: project per-event delta onto the extrude axis. The
        // previous pixel comes from the cooked gesture, not from this tool's
        // own pair — same integer subtraction, sourced one level up.
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check. The
        // PART_FREE branch above measures from the PRESS pixel, not the
        // previous one, and is deliberately left alone.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        bool skip;
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length `extrudeFaces` means (task 0645) — one OverlayAxis
        // in both roles, so the arm the pixels are dotted against is the arm
        // on screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(extrudeAxis);
        Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            distance_ += ax.toLocal(dot(delta, ax.dir));
            rebuildPreview(true);
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != dragButton_) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        sessionStepEnds();
        return true;
    }


    // Read-only test seam (task 0645) — GET /api/tool/handles. The registry
    // stays the hit-testing authority; this only exposes its already-drawn
    // state, and that state is the ONLY place a handle's SPACE is observable
    // from outside the process. Mirrors PolyBevelTool / EdgeBevelTool, which
    // carried it already.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
        // Recompute gizmo frame when selection changes while idle (not mid-drag,
        // not after built preview — that would double-count the distance offset).
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        // Anchor slides analytically along extrudeAxis by distance_ — in the
        // LOCAL space both of them live in.
        anchor = baseAnchor + extrudeAxis * distance_ + shiftVec();

        // ONE overlay space for the pass (task 0645): the arm is positioned in
        // it and `toolHandles.update` below hit-tests this same object, so
        // drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const auto ax      = os.axis(extrudeAxis);
        const Vec3 anchorW = os.pos(anchor);

        float armLen = gizmoSize(anchorW, vp, 1.0f);
        extrudeArrow.start = anchorW + ax.dir * (armLen / 6.0f);
        extrudeArrow.end   = anchorW + ax.dir * armLen;
        extrudeArrow.color = EXTRUDE_COLOR;

        toolHandles.begin();
        toolHandles.add(extrudeArrow, PART_EXTRUDE);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        extrudeArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandFaceMask();
    }

    void rebuildPreview(bool allowCoincidentTopology = false) {
        if (!active) return;
        if (topologyDormant) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        const shift = shiftVec();
        if (distance_ == 0.0f && shift == Vec3(0, 0, 0) &&
            !allowCoincidentTopology) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        // task 1903 Stage H: unrecorded — the per-drag-frame preview rerun.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeFacesByMask(mask, distance_, false,
            UvWallLaw.SweepU, allowCoincidentTopology || shift != Vec3(0, 0, 0),
            FaceExtrudeOrder.WallsThenCap);
        if (n != 0) applyCapShift(ed, extentToMesh(shift));
        ed.close();
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        if (c is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.PolyExtrude,
            false, false);
        const accepted = c.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.PolyExtrude, false, accepted);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

    void cancelLiveEdit() {
        if (dragPart < 0) return; // completed images belong to history
        before.restore(*mesh);
        refreshCaches();
        distance_ = shiftX_ = shiftY_ = shiftZ_ = 0.0f;
        built     = false;
        dragPart  = -1;
        toolHandles.clearHaul();
    }

    // Compute gizmo anchor + extrude axis from the current face selection.
    // anchor      = centroid of selected face centroids.
    // extrudeAxis = normalized average of selected face normals.
    void computeGizmoFrame() {
        PreparedPolyExtrudeActivationImage image;
        image.anchor = anchor; image.baseAnchor = baseAnchor;
        image.extrudeAxis = extrudeAxis;
        computePreparedGizmoFrame(*mesh, image);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;
        gizmoSelHash = image.gizmoSelHash;
    }

    Vec3 shiftVec() const nothrow @nogc {
        return Vec3(shiftX_, shiftY_, shiftZ_);
    }

    void resetExtentFrame() nothrow @nogc {
        extentFrameX = Vec3(1, 0, 0);
        extentFrameY = Vec3(0, 1, 0);
        extentFrameZ = Vec3(0, 0, 1);
    }

    Vec3 extentToMesh(Vec3 extent) const nothrow @nogc {
        return extentFrameX * extent.x + extentFrameY * extent.y
             + extentFrameZ * extent.z;
    }

    bool prepareFreeDrag(int mx, int my, Vec3 downExtent) {
        dragVp = cachedVp;
        dragPressContentX = mx - dragVp.x;
        dragPressContentY = my - dragVp.y;
        dragBaseShift = downExtent;
        dragOverlay = OverlaySpace.ofPrimary();

        auto frame = primitiveParameterFrame();
        extentFrameX = dragOverlay.toLocalDelta(
            transformDir(frame.toWorld, Vec3(1, 0, 0)));
        extentFrameY = dragOverlay.toLocalDelta(
            transformDir(frame.toWorld, Vec3(0, 1, 0)));
        extentFrameZ = dragOverlay.toLocalDelta(
            transformDir(frame.toWorld, Vec3(0, 0, 1)));

        const auto ax = dragOverlay.axis(Vec3(1, 0, 0));
        const auto ay = dragOverlay.axis(Vec3(0, 1, 0));
        const auto az = dragOverlay.axis(Vec3(0, 0, 1));
        Vec3 rawHit;
        if (!automaticPlanePressHit(mx, my, dragVp, rawHit,
                                    ax.dir, ay.dir, az.dir))
            return false;

        const float px = viewWorldPerPixel(dragVp);
        dragSnapStep = viewGridSubStep(px,
            viewGridSize(px, g_viewGrid), g_viewGrid);
        dragUpstreamBase = vectorSnap(rawHit, dragSnapStep);
        const Vec3 jacobianInput = dragUpstreamBase;
        version (unittest) {
            recordPolyDragPress(PolyDragPressStage.upstreamB0,
                                dragUpstreamBase);
            recordPolyDragPress(PolyDragPressStage.jacobianInput,
                                jacobianInput);
        }
        dragPlane = preparePlaneDrag(jacobianInput, 3, dragVp,
                                     ax.dir, ay.dir, az.dir);
        if (!dragPlane.valid) return false;
        dragSnapBase = vectorSnap(dragUpstreamBase, dragSnapStep);
        return true;
    }

    static void applyCapShift(ref MeshEditBatch ed, Vec3 shift) {
        if (shift == Vec3(0, 0, 0)) return;
        auto selected = ed.selectedVertexIndicesFaces();
        uint[] idx;
        Vec3[] to;
        idx.reserve(selected.length);
        to.reserve(selected.length);
        foreach (vi; selected) {
            idx ~= cast(uint)vi;
            to ~= ed.vertices[vi] + shift;
        }
        ed.setVertexPositions(idx, to);
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedPolyExtrudeActivationImage image) {
        image.gizmoValid = false;
        image.gizmoSelHash = source.selectionSignature(EditMode.Polygons);
        if (source.faces.length == 0) return;

        // L1 funnel (task 0613, S5). This is the SAME operand set currentMask()
        // builds — the gizmo anchor/axis must be framed on exactly the faces
        // the apply will extrude, or the handle sits somewhere the edit does
        // not happen. Routing it through operandFaceMask() keeps the two in
        // lockstep, including the hidden subtraction.
        auto opFaces = source.operandFaceMask();

        Vec3   centSum = Vec3(0, 0, 0);
        size_t centN   = 0;
        Vec3   normSum = Vec3(0, 0, 0);

        foreach (fi; 0 .. source.faces.length) {
            bool selected = fi < opFaces.length && opFaces[fi];
            if (!selected) continue;
            Vec3 c = source.faceCentroid(cast(uint)fi);
            centSum = centSum + c;
            ++centN;
            normSum = normSum + source.faceNormal(cast(uint)fi);
        }

        if (centN == 0) return;
        image.anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);
        image.baseAnchor = image.anchor;

        float nl = sqrt(normSum.x*normSum.x + normSum.y*normSum.y + normSum.z*normSum.z);
        image.extrudeAxis = (nl > 1e-6f) ? normSum * (1.0f / nl) : Vec3(0, 1, 0);

        image.gizmoValid = true;
    }

public:
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        distance_ = 0.5f; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { distance_ = value; }
    version(unittest) final void mutatePreparedFrameForTest(Vec3 x)
            nothrow @nogc { extentFrameX = x; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; built = true; dragPart = 9; distance_ = 7;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        extrudeAxis = Vec3(7,8,9); gizmoSelHash = 10;
        dragLastMX = 11; dragLastMY = 12; dragStartMX = 13; dragStartMY = 14;
        cachedVp.view[0] = 16;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const nothrow @nogc {
        return !active && built && dragPart == 9 && distance_ == 7 &&
            !gizmoValid && anchor == Vec3(1,2,3) &&
            baseAnchor == Vec3(4,5,6) && extrudeAxis == Vec3(7,8,9) &&
            gizmoSelHash == 10;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, Vec3 expectedAnchor,
            Vec3 expectedAxis, ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && distance_ == 0 &&
            before.filled && before.vertices.length == count && count &&
            before.vertices[0] == first && before.vertices.ptr !is livePtr &&
            gizmoValid && anchor == expectedAnchor && baseAnchor == anchor &&
            extrudeAxis == expectedAxis && gizmoSelHash == expectedHash &&
            dragLastMX == 11 && dragLastMY == 12 && dragStartMX == 13 &&
            dragStartMY == 14 && cachedVp.view[0] == 16;
    }
    version(unittest) final bool preparedInvalidActivationForTest(
            ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && distance_ == 0 &&
            !gizmoValid && anchor == Vec3(1,2,3) &&
            baseAnchor == Vec3(4,5,6) && extrudeAxis == Vec3(7,8,9) &&
            gizmoSelHash == expectedHash;
    }
}

unittest { // P1.0b.3d identity preview must not prepare history.
    import view : View; import mesh_gpu : GpuMesh;
    import record_observer_hub : RecordObserverHub;
    Mesh m; GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto view = new View(0, 0, 1, 1);
    auto history = new CommandHistory(); auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto tool = new PolyExtrudeTool(() => &m, &gpu, &mode, LitShader.init);
    tool.setGestureBindings(history, () => new MeshSessionEdit(&m, view, mode,
        "test.polyExtrude", "poly extrude"));
    tool.active = true; tool.built = true; tool.before = MeshSnapshot.capture(m);
    tool.shiftX_ = 0.2f;
    assert(tool.hasUncommittedEdit(),
        "a live shift-only Polygon preview must report uncommitted work");
    tool.shiftX_ = 0.0f;
    tool.distance_ = 0;
    auto context = new PreparedRecordContext(history, hub);
    auto effect = tool.prepareDeactivate(context);
    assert(!effect.historyAccepted);
    assert(context.validate()); context.install();
    size_t modelDepth, uiDepth; context.installedDepths(modelDepth, uiDepth);
    assert(modelDepth == 0 && uiDepth == 0 && hub.macroLength == 0);
}

unittest { // free drag press prepares Jacobian from captured upstream-snapped B0
    import document : primaryModelSpaceResolver;
    import display_sync : activeMeshResolver;
    import std.format : format;
    import std.math : atan;
    import toolpipe.pipeline : g_pipeCtx;
    import viewgrid : ViewGridPrefs;

    Viewport capturedViewport(Vec3 eye, float pixelSize) {
        Viewport vp;
        vp.x = 4; vp.y = 4; vp.width = 1144; vp.height = 966;
        vp.eye = eye; vp.focus = Vec3(0, 0, 0);
        vp.view = lookAt(eye, vp.focus, Vec3(0, 1, 0));
        const float focalPx = 0.8f * (eye - vp.focus).length / pixelSize;
        const float fovY = 2.0f * atan(0.5f * vp.height / focalPx);
        vp.proj = perspectiveMatrix(fovY,
            cast(float)vp.width / vp.height, 0.001f, 100.0f);
        return vp;
    }
    Mesh capturedRig() {
        Mesh result;
        foreach (v; [Vec3(-.5f,-.5f,-.5f), Vec3(-.5f,-.5f,.5f),
                     Vec3(-.5f,.5f,-.5f),  Vec3(-.5f,.5f,.5f),
                     Vec3(.5f,-.5f,-.5f),  Vec3(.5f,-.5f,.5f),
                     Vec3(.5f,.5f,-.5f),   Vec3(.5f,.5f,.5f)])
            result.addVertex(v);
        result.addFace([0u,2u,6u,4u]); result.addFace([0u,1u,3u,2u]);
        result.addFace([2u,3u,7u,6u]); result.addFace([0u,4u,5u,1u]);
        result.buildLoops(); result.syncSelection(); result.selectFace(0);
        return result;
    }
    bool near(Vec3 a, Vec3 b, float epsilon = 2e-6f) {
        return abs(a.x-b.x) < epsilon && abs(a.y-b.y) < epsilon &&
               abs(a.z-b.z) < epsilon;
    }
    Vec3 rotateZXY(Vec3 v, Vec3 degrees) {
        enum float k = 0.017453292519943295f;
        const rx = degrees.x*k, ry = degrees.y*k, rz = degrees.z*k;
        import std.math : cos, sin;
        auto a = Vec3(cos(ry)*v.x + sin(ry)*v.z, v.y,
                      -sin(ry)*v.x + cos(ry)*v.z);
        auto b = Vec3(a.x, cos(rx)*a.y - sin(rx)*a.z,
                      sin(rx)*a.y + cos(rx)*a.z);
        return Vec3(cos(rz)*b.x - sin(rz)*b.y,
                    sin(rz)*b.x + cos(rz)*b.y, b.z);
    }

    auto savedResolver = primaryModelSpaceResolver;
    auto savedDisplayResolver = activeMeshResolver;
    auto savedPipe = g_pipeCtx;
    auto savedGrid = g_viewGrid;
    Mesh offscreen;
    scope(exit) {
        primaryModelSpaceResolver = savedResolver;
        activeMeshResolver = savedDisplayResolver;
        g_pipeCtx = savedPipe;
        g_viewGrid = savedGrid;
    }
    primaryModelSpaceResolver = () => ModelSpace.world();
    activeMeshResolver = () => &offscreen;
    g_pipeCtx = null;
    g_viewGrid = ViewGridPrefs.init;

    Mesh m; GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new PolyExtrudeTool(() => &m, &gpu, &mode, LitShader.init);
    tool.cachedVp = capturedViewport(Vec3(-2.079347162902738f,
        1.690473046962798f, -2.969615506024416f),
        0.003184857364427978f);

    polyDragPressRecords.length = 0;
    assert(tool.prepareFreeDrag(900, 250, Vec3(0, 0, 0)));
    assert(polyDragPressRecords.length == 2,
        "production press preparation must expose exactly B0 and Jacobian input");
    assert(polyDragPressRecords[0].stage == PolyDragPressStage.upstreamB0);
    assert(polyDragPressRecords[1].stage == PolyDragPressStage.jacobianInput);
    const capturedB0 = Vec3(-1.160f, 1.075f, 0);
    bool atCapturedB0(Vec3 v) {
        return abs(v.x - capturedB0.x) < 2e-6f &&
               abs(v.y - capturedB0.y) < 2e-6f &&
               abs(v.z - capturedB0.z) < 2e-6f;
    }
    assert(atCapturedB0(polyDragPressRecords[0].value),
        format("upstream press checkpoint used %s instead of captured B0",
            polyDragPressRecords[0].value));
    assert(atCapturedB0(polyDragPressRecords[1].value),
        "Jacobian was not prepared at captured upstream-snapped B0");
    assert(tool.dragPressContentX == 896 && tool.dragPressContentY == 246 &&
        tool.dragVp.x == 4 && tool.dragVp.y == 4,
        "press viewport and content-local pixels were not frozen at Down");
    assert(atCapturedB0(tool.dragSnapBase) && tool.dragPlane.valid);

    void expectCapturedCap(Viewport vp, int pressX, int pressY,
            int endX, int endY, Vec3 downExtent, Vec3 wantExtent,
            bool tilted = false) {
        auto rig = capturedRig(); GpuMesh rigGpu;
        auto candidateTool = new PolyExtrudeTool(() => &rig, &rigGpu, &mode,
            LitShader.init);
        candidateTool.seedPreparedParamForTest(rig);
        candidateTool.mutatePreparedParamForTest(0.0f);
        candidateTool.cachedVp = vp;
        assert(candidateTool.prepareFreeDrag(pressX, pressY, downExtent));
        const raw = candidateTool.dragPlane.apply(endX, endY, pressX, pressY);
        const d = vectorSnap(candidateTool.dragSnapBase + raw,
            candidateTool.dragSnapStep) - candidateTool.dragSnapBase;
        const extent = downExtent + candidateTool.dragOverlay.toLocalDelta(d);
        assert(near(extent, wantExtent),
            format("captured Polygon Extent drifted: got %s want %s",
                extent, wantExtent));

        if (tilted) {
            const angles = Vec3(55, 20, 15);
            candidateTool.extentFrameX = rotateZXY(Vec3(1,0,0), angles);
            candidateTool.extentFrameY = rotateZXY(Vec3(0,1,0), angles);
            candidateTool.extentFrameZ = rotateZXY(Vec3(0,0,1), angles);
        }
        candidateTool.shiftX_ = extent.x;
        candidateTool.shiftY_ = extent.y;
        candidateTool.shiftZ_ = extent.z;
        auto image = candidateTool.buildPreparedParamUpdate(rig);
        scope(exit) image.clear();
        assert(image.valid && image.applies && image.candidate.vertices.length == 12 &&
            image.candidate.faces.length == 8 && image.candidate.edges.length == 19,
            "captured Polygon candidate lost full W2 topology");
        Vec3 meshDelta = tilted
            ? Vec3(-0.091958761f, -0.001721144f, 0.088264525f)
            : extent;
        foreach (i; 0 .. 8)
            assert(image.candidate.vertices[i] == rig.vertices[i]);
        foreach (i, vi; [0u,2u,6u,4u])
            assert(near(image.candidate.vertices[8+i], rig.vertices[vi] + meshDelta),
                "captured Polygon candidate lost a full cap position");
        foreach (fi; 0 .. image.candidate.faces.length)
            assert(image.candidate.isFaceSelected(cast(uint)fi) == (fi == 7));

        candidateTool.rebuildPreview(true);
        assert(rig.vertices.length == image.candidate.vertices.length &&
            rig.faces == image.candidate.faces && rig.edges == image.candidate.edges,
            "live Polygon preview differs from the prepared full-state candidate");
        foreach (i, p; image.candidate.vertices)
            assert(near(rig.vertices[i], p),
                "live Polygon cap position differs from the prepared candidate");
        foreach (fi; 0 .. rig.faces.length)
            assert(rig.isFaceSelected(cast(uint)fi) == (fi == 7));
    }

    auto defaultVp = tool.cachedVp;
    expectCapturedCap(defaultVp, 900, 250, 940, 220,
        Vec3(0,0,0), Vec3(-.105f,.100f,0));
    expectCapturedCap(defaultVp, 900, 250, 940, 220,
        Vec3(-.030f,.025f,0), Vec3(-.135f,.125f,0));
    auto alternateVp = capturedViewport(Vec3(3.8976265487139683f,
        1.285207906652404f, -1.5747433441918124f), 0.003500000000175f);
    expectCapturedCap(alternateVp, 903, 257, 940, 228,
        Vec3(0,0,0), Vec3(0,.105f,-.120f));
    expectCapturedCap(defaultVp, 900, 250, 935, 225,
        Vec3(0,0,0), Vec3(-.095f,.085f,0), true);
}
