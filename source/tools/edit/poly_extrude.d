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
import drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;

import std.math : abs, round, sqrt;
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
    bool opEquals(const PolyExtrudeParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&distance, &other.distance, float.sizeof) == 0 &&
            memcmp(&shiftX, &other.shiftX, float.sizeof) == 0 &&
            memcmp(&shiftY, &other.shiftY, float.sizeof) == 0 &&
            memcmp(&shiftZ, &other.shiftZ, float.sizeof) == 0;
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
            distance_, shiftX_, shiftY_, shiftZ_);
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
            if (n != 0) applyCapShift(ed, shiftVec());
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

        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragLastMX       = e.x;
        dragLastMY       = e.y;
        dragStartMX      = e.x;
        dragStartMY      = e.y;
        dragBaseShift    = topologyDormant ? Vec3(0, 0, 0) : shiftVec();
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
            bool skip;
            const auto os = OverlaySpace.ofPrimary();
            const auto ax = os.axis(Vec3(1, 0, 0));
            const auto ay = os.axis(Vec3(0, 1, 0));
            const auto az = os.axis(Vec3(0, 0, 1));
            Vec3 world = planeDragDelta(e.x, e.y, dragStartMX, dragStartMY,
                3, os.pos(baseAnchor), cachedVp, skip,
                ax.dir, ay.dir, az.dir, os.axis(extrudeAxis).dir);
            if (!skip) {
                // Calibrate the captured free-haul response after solving the
                // view plane; the topology kernel receives a plain cap offset.
                enum float FREE_HAUL_XZ_GAIN = 0.35f;
                enum float FREE_HAUL_Y_GAIN = 4.0f / 11.0f;
                auto d = os.toLocalDelta(world);
                Vec3 local = dragBaseShift +
                    Vec3(d.x * FREE_HAUL_XZ_GAIN,
                        d.y * FREE_HAUL_Y_GAIN,
                        d.z * FREE_HAUL_XZ_GAIN);
                shiftX_ = snapShift(local.x);
                shiftY_ = snapShift(local.y);
                shiftZ_ = snapShift(local.z);
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
        if (n != 0) applyCapShift(ed, shift);
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

    static float snapShift(float value) nothrow @nogc {
        enum float quantum = 0.005f;
        return cast(float)round(value / quantum) * quantum;
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
