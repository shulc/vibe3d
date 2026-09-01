module tools.edit.poly_extrude;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta, gesturePrevPixel;
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
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import command_history : PreparedHistoryKind;
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
    float distance;
    bool opEquals(const PolyExtrudeParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&distance, &other.distance, float.sizeof) == 0;
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
// Cloned from EdgeExtrudeTool and simplified to a SINGLE axis (distance) with
// no width axis. Polygon-mode only; topology-creating: one snapshot-based undo
// entry per session (Phase 5 delta undo is deferred).
//
// Session model (matches EdgeExtrudeTool):
//   activate()   — snapshot cage+selection; reset distance to 0; build gizmo.
//   drag         — restore cage, reapply extrudeFacesByMask(mask, distance_).
//   deactivate() — if built && distance != 0: commit MeshSessionEdit.
//
// Single handle:
//   PART_EXTRUDE = BLUE Arrow along averaged region normal. Dragging changes
//   `distance` only. Off-handle (miss click) starts a blind vertical free drag
//   (up/down → distance_).
//
// Headless path: `tool.set poly.extrude on; tool.attr poly.extrude distance
// <v>; tool.doApply` drives through applyHeadless(); ToolDoApplyCommand wraps
// it with a snapshot pair for undo (applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class PolyExtrudeTool : Tool {
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    // Parameters.
    float distance_ = 0.0f;

    // Interactive session state.
    bool          active;
    bool          built;
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
    enum int PART_FREE    = 1;   // off-handle blind vertical drag
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    int   dragStartMX, dragStartMY;
    float dragBaseDistance;

    enum float FREE_SCALE = 0.01f;

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
        return [Param.float_("distance", "Distance", &distance_, 0.0f)];
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
        active = true; built = false; dragPart = -1; distance_ = 0.0f;
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
        distance_ = 0.0f;
        before    = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && distance_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && distance_ != 0.0f;
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
    private PolyExtrudeParamProjection paramProjection() const nothrow @nogc {
        return PolyExtrudeParamProjection(interactiveParamEdit, active, built,
            distance_);
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
        if (distance_ == 0.0f) image.nextBuilt = false;
        else {
            auto mask = image.candidate.operandFaceMask();
            auto ed = MeshEditBatch.unrecorded(image.candidate, kExtrudeEditScope);
            const n = ed.extrudeFacesByMask(mask, distance_);
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
            cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0 || !gizmoValid) return false;

        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragLastMX       = e.x;
        dragLastMY       = e.y;
        dragStartMX      = e.x;
        dragStartMY      = e.y;
        dragBaseDistance = distance_;

        if (part == PART_EXTRUDE) {
            dragPart = PART_EXTRUDE;
            toolHandles.setHaul(part);
            return true;
        }
        // Off-handle: blind vertical free drag.
        dragPart = PART_FREE;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;

        if (dragPart == PART_FREE) {
            int dy = e.y - dragStartMY;
            distance_ = dragBaseDistance + (-dy) * FREE_SCALE;
            rebuildPreview();
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
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // Recompute gizmo frame when selection changes while idle (not mid-drag,
        // not after built preview — that would double-count the distance offset).
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        // Anchor slides analytically along extrudeAxis by distance_ — in the
        // LOCAL space both of them live in.
        anchor = baseAnchor + extrudeAxis * distance_;

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

    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (distance_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        // task 1903 Stage H: unrecorded — the per-drag-frame preview rerun.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeFacesByMask(mask, distance_);
        ed.close();
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && distance_ != 0.0f && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Face Extrude");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.PolyExtrude,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Face Extrude");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

    void cancelLiveEdit() {
        before.restore(*mesh);
        refreshCaches();
        distance_ = 0.0f;
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
        dragBaseDistance = 15; cachedVp.view[0] = 16;
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
            dragStartMY == 14 && dragBaseDistance == 15 && cachedVp.view[0] == 16;
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
    tool.distance_ = 0;
    auto context = new PreparedRecordContext(history, hub);
    auto effect = tool.prepareDeactivate(context);
    assert(!effect.historyAccepted);
    assert(context.validate()); context.install();
    size_t modelDepth, uiDepth; context.installedDepths(modelDepth, uiDepth);
    assert(modelDepth == 0 && uiDepth == 0 && hub.macroLength == 0);
}
