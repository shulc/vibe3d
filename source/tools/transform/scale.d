module tools.transform.scale;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import sdl.stdinc : SDL_FALSE, SDL_TRUE, SDL_bool;

import tools.transform.transform;

struct PreparedScaleActivationImage {
    PreparedTransformActivationImage base;
    Vec3 pendingScale = Vec3(1,1,1);
    bool pendingScaleValid, valid;
    void clear() nothrow @nogc { this = PreparedScaleActivationImage.init; }
}
struct PreparedScaleEmbeddedDeactivateImage {
    TransformTool.PreparedScalarDeactivateImage base;
    SDL_bool preRelative;
    bool ownsRelative, valid;
    void clear() nothrow @nogc { valid = ownsRelative = false; base.clear(); }
}
import handler;
import mesh;
import editmode;
import document : Layer;
import seltype : SelType;
import tool : Tool;
import math;
import shader;
import toolpipe.packets : FalloffPacket;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt;

import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import params : Param;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind,
    PreparedTransformProductEffect, PreparedTransformProductKind,
    PreparedScaleUpdateEffect, PreparedScaleUpdateKind;
import prepared_transform_product_activation : PreparedTransformProductActivationOwner;
import prepared_scale_update : PreparedScaleUpdateOwner;
import prepared_xfrm_refire_state : PreparedXfrmRefireStateImage;

enum PreparedScaleUpdateBranch : ubyte {
    InactiveNoop,
    DraggingNoop,
    IdleRefresh,
    SelectionRefresh,
    MutationRefresh,
}

struct PreparedScaleUpdateProjection {
    PreparedScaleUpdateBranch branch;
    ulong selectionHash, mutationVersion;
    bool selectionChanged, mutationChanged, ownerEditOpen;
    Vec3 actionCenter;
    bool valid;
    void clear() nothrow @nogc { this = PreparedScaleUpdateProjection.init; }
}

struct PreparedScaleUpdateImage {
    PreparedScaleUpdateProjection projection;
    Mesh candidate;
    ulong expectedSelectionHash, nextSelectionHash;
    ulong expectedMutationVersion, nextMutationVersion;
    bool expectedCacheDirty, nextCacheDirty;
    bool expectedCenterManual, nextCenterManual;
    Vec3 expectedCachedCenter, nextCachedCenter;
    Vec3 expectedHandlerCenter, nextHandlerCenter;
    bool valid;
    void clear() nothrow @nogc { this = PreparedScaleUpdateImage.init; }
}


// ---------------------------------------------------------------------------
// ScaleTool : TransformTool — shows ScaleHandler at selection/mesh center; scales
//             selected vertices along the dragged axis relative to the center.
// ---------------------------------------------------------------------------

private class ScaleHeadHandle : Handler {
    CubicArrow target;

    this(CubicArrow target) {
        this.target = target;
    }

    override void setState(HandleState s) {
        super.setState(s);
        target.setState(s);
    }

    override protected bool hitTest(int mx, int my, const ref Viewport vp) {
        return aiScreenDistance(mx, my, vp) < GIZMO_PICK_SCALE_HEAD_PX;
    }

    override protected float aiScreenDistance(int mx, int my,
                                              const ref Viewport vp) {
        if (!target.isVisible()) return float.infinity;
        float ex, ey, ndcZ;
        if (!projectToWindowFull(target.end, vp, ex, ey, ndcZ))
            return float.infinity;
        float dx = cast(float)mx - ex;
        float dy = cast(float)my - ey;
        return sqrt(dx*dx + dy*dy);
    }

    // Task 0553. Without this override `/api/tool/handles` reported
    // `screen: null` for every scale handle in the `compact` presentation —
    // i.e. there was no test-introspectable "press here to grab scale" point
    // in exactly the preset where scale has its OWN pick tolerance
    // (GIZMO_PICK_SCALE_HEAD_PX around `target.end`, not the stem capsule the
    // other presentations use). Unlike ShaftedArrow's 70 %-along-the-shaft
    // anchor, the anchor here is `target.end` itself, because that is the
    // exact centre of this handle's grab disc — the anchor and the hit test
    // read the same point, so a press at the anchor cannot miss.
    override bool screenAnchor(const ref Viewport vp,
                               out float sx, out float sy) const
    {
        if (!target.isVisible()) return false;
        float ndcZ;
        return projectToWindowFull(target.end, vp, sx, sy, ndcZ);
    }
}

class ScaleTool : TransformTool {
public:
    final PreparedScaleEmbeddedDeactivateImage
            buildPreparedEmbeddedDeactivateImage() const nothrow @nogc {
        PreparedScaleEmbeddedDeactivateImage image;
        image.base = buildPreparedScalarDeactivateImage();
        image.preRelative = preDragRelativeMouse;
        image.ownsRelative = ownsRelativeMouse;
        image.valid = image.base.valid; return image;
    }
    final bool preparedEmbeddedDeactivateMatches(
            in PreparedScaleEmbeddedDeactivateImage image) const nothrow @nogc {
        return image.valid && image.preRelative == preDragRelativeMouse &&
            image.ownsRelative == ownsRelativeMouse &&
            preparedScalarDeactivateMatches(image.base);
    }
    final void installPreparedEmbeddedDeactivate(
            ref PreparedScaleEmbeddedDeactivateImage image) nothrow @nogc {
        if (!image.valid) return;
        if (image.ownsRelative) SDL_SetRelativeMouseMode(image.preRelative);
        ownsRelativeMouse = false;
        installPreparedScalarDeactivate(image.base); image.clear();
    }
    ScaleHandler handler;
    ScaleHeadHandle headX, headY, headZ;

private:
    // Per-gesture input accumulation. The owner drains this through
    // `pendingScale` and owns the run-total scale separately.
    Vec3     dragScaleAccum = Vec3(1, 1, 1);  // scale within current drag (for yellow arrows)
    float    dragScaleScalarDelta;
    SDL_bool preDragRelativeMouse = SDL_FALSE;
    bool     ownsRelativeMouse;

    // ── the off-handle PLANE drag (dragAxis == PLANE_DRAG_AXIS) ─────────────
    // A press that misses every handle, in an action-centre mode that lets the
    // pivot relocate, scales in a PLANE. One basis axis is ELECTED OUT — the
    // one most nearly along the eye ray through the action centre — and the
    // two survivors take the drag's horizontal and vertical components by a
    // fixed table (`pickScalePlaneAxes`). The excluded axis is left at exactly
    // 1. Armed in `onMouseButtonDownWithResolvedAxis`, consumed in
    // `onMouseMotion`, cleared on mouse-up with every other drag mode.
    // Public because the wrapper has to tell this gesture apart from the ones
    // that grabbed a handle: every other `dragAxis` value is a registered part
    // id offset, and this one names no handle at all.
    public enum int PLANE_DRAG_AXIS = 7;
    // Screen pixels per unit of scale gain. The gain on each of the two axes is
    // `1 + component / PLANE_DRAG_PIXELS`, i.e. linear in the pixels and passing
    // through zero — a long enough drag the other way MIRRORS rather than
    // clamping, which is why this shares `clampScaleFactor`'s negScale gate with
    // the handle drags instead of flooring at 0 on its own.
    enum float PLANE_DRAG_PIXELS = 312.5f;
    // Read + cleared by the wrapper on the press that set it, exactly as the
    // Move and Rotate banks' equivalents are. An off-handle press RELOCATES and
    // then ARMS, so the wrapper can no longer infer "this press was a relocate"
    // from `dragAxis == -1` the way it could while the relocate started no drag.
    public bool lastClickWasRelocate = false;
    int   planeAxisH = -1, planeAxisV = -1;   // basis-axis indices 0/1/2
    float planeAccumX = 0.0f, planeAccumY = 0.0f;

public:
    final Mesh* preparedMeshForUpdate() const { return mesh; }
    final EditMode preparedEditModeForUpdate() const nothrow @nogc { return *editMode; }
    // ── scale single-source plumbing (mirrors RotateTool / MoveTool) ──
    // Gesture-scalar producer output. The principal-axis / uniform-disc /
    // plane-circle drag branches publish the ABSOLUTE within-drag per-axis
    // scale factor here (`dragScaleAccum`, reset to 1 at drag start) and
    // return WITHOUT mutating geometry; the unified wrapper drains it into
    // its `run.s` and runs `applyTRS`. `pendingScaleValid == false`
    // means "nothing pending" (idle / hover frames leave it untouched).
    bool pendingScaleValid = false;
    Vec3 pendingScale = Vec3(1, 1, 1);   // per-axis factor, absolute since drag start

    // Input-projection basis, captured ONCE at drag start (in
    // `onMouseButtonDown`, where `dragAxis` becomes >= 0) from the live
    // `currentBasis(...)`. The single-axis drag projects the screen drag
    // onto THIS frozen frame, kept SEPARATE from the rendered gizmo
    // orientation (`handler.axisX/Y/Z`). Phase 2 (flex_border_handles_plan.md)
    // moves the RENDERED frame to the Model-C `(axisTracksSelection ? R_gesture
    // : I)·B0` during a drag, while this input frame stays drag-start-frozen —
    // so the rendered handle can re-orient (flex sibling-follow) WITHOUT
    // reversing the drag direction mid-gesture (the axis-sign flip 0b812cf
    // fixed). The two are now genuinely distinct during a flex rotate.
    Vec3 inputBasisX = Vec3(1, 0, 0);
    Vec3 inputBasisY = Vec3(0, 1, 0);
    Vec3 inputBasisZ = Vec3(0, 0, 1);

    // Owner-provided input-frame channel (gesture-frame unification, Phase 2).
    // When the owner chained this
    // gesture off the persisted gizmo frame, the wrapper pushes that ONE unified
    // frame here (via `setWrapperInputFrame`, called once per gesture from
    // `beginScaleDragSession`). The single-axis DECOMPOSE site then projects onto
    // THIS frame instead of the bank's own `inputBasis*`. Replaces the prior
    // hand-synced override that copied the wrapper's persisted basis into
    // `inputBasis*` at gesture start — same value (the channel carries the unified
    // `frame`, the persisted gesture frame when chained). An unchained gesture
    // keeps its own `inputBasis*` (seeded by `currentBasis`).
    Vec3 wrapperInputFrameX = Vec3(1, 0, 0);
    Vec3 wrapperInputFrameY = Vec3(0, 1, 0);
    Vec3 wrapperInputFrameZ = Vec3(0, 0, 1);
    bool wrapperInputFrameValid = false;

    // Push the wrapper's unified gesture frame into this bank for the WRAPPED
    // scale input projection. `chained` is the wrapper's `frame.valid &&
    // acenSettleAllowed()` gate (mirrors the old override guard) — false for a
    // fresh/non-chained gesture, in which case the DECOMPOSE read stays on
    // `inputBasis*`.
    void setWrapperInputFrame(Vec3 r, Vec3 u, Vec3 f, bool chained) {
        wrapperInputFrameX     = r;
        wrapperInputFrameY     = u;
        wrapperInputFrameZ     = f;
        wrapperInputFrameValid = chained;
    }

    // Source selector for the WRAPPED-role DECOMPOSE read. Reads the unified
    // frame when wrapper-chained, else the bank's drag-start-frozen
    // `inputBasis*` (standalone / fresh non-chained).
    Vec3 inAxisX() const {
        return wrapperInputFrameValid ? wrapperInputFrameX : inputBasisX;
    }
    Vec3 inAxisY() const {
        return wrapperInputFrameValid ? wrapperInputFrameY : inputBasisY;
    }
    Vec3 inAxisZ() const {
        return wrapperInputFrameValid ? wrapperInputFrameZ : inputBasisZ;
    }

    // DEBUG-only — input-side parity guard (gesture-frame unification, Phase 2).
    // The pushed channel must carry the wrapper's unified `frame` (an orthonormal
    // triple, asserted on the wrapper side at population). Assert that invariant
    // here, mirroring the render-rung asserts. Compiled out of release.
    debug void assertWrapperInputFrameChained() const {
        import std.math : abs;
        if (!wrapperInputFrameValid) return;
        enum float tol = 1e-3f;
        assert(abs(wrapperInputFrameX.length - 1.0f) < tol,
               "scale wrapperInputFrameX not unit length");
        assert(abs(wrapperInputFrameY.length - 1.0f) < tol,
               "scale wrapperInputFrameY not unit length");
        assert(abs(wrapperInputFrameZ.length - 1.0f) < tol,
               "scale wrapperInputFrameZ not unit length");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameY)) < tol,
               "scale wrapperInputFrame X·Y not orthogonal");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameZ)) < tol,
               "scale wrapperInputFrame X·Z not orthogonal");
        assert(abs(dot(wrapperInputFrameY, wrapperInputFrameZ)) < tol,
               "scale wrapperInputFrame Y·Z not orthogonal");
    }

    bool negativeScaleEnabled;

    void setInputOptions(bool allowNegativeScale) nothrow @nogc {
        negativeScaleEnabled = allowNegativeScale;
    }

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         SelType delegate() selTypeSrc = null) {
        super(meshSrc, gpu, editMode, selTypeSrc);
        handler = new ScaleHandler(Vec3(0, 0, 0));
        headX = new ScaleHeadHandle(handler.arrowX);
        headY = new ScaleHeadHandle(handler.arrowY);
        headZ = new ScaleHeadHandle(handler.arrowZ);
    }

    void destroy() { handler.destroy(); }

    void setWrapperGizmoPose(Vec3 center, Vec3 bX, Vec3 bY, Vec3 bZ)
            nothrow @nogc {
        cachedCenter = center;
        handler.setPosition(center);
        // flex_border_handles_plan.md Phase 2 — apply the wrapper's Model-C
        // RENDER basis UNCONDITIONALLY (old `dragAxis < 0` render gate removed,
        // Risk 1). The single-axis scale INPUT projection reads the separately-
        // frozen `inputBasis*` (Phase 1), not handler.axis*, so the scale math
        // stays stable while the rendered frame follows renderBasis cross-bank.
        handler.setOrientation(bX, bY, bZ);
    }

    // Register this bank's gizmo handles into the shared arbiter `th`
    // at part-id offset `base` (so overlapping handles across banks get
    // distinct parts). Order = hitTestAxes priority (disc, plane
    // circles, then arrows) so the highlighted handle matches the one a
    // click grabs. Does NOT begin()/update()/suppress() — the wrapper
    // owns the single test+update pass, and suppresses all highlight
    // during a scale drag (the animated scale arrow is the feedback).
    void registerHandles(ToolHandles th, int base) {
        th.add(handler.centerDisk, base + 3);
        th.add(handler.circleXY,   base + 4);
        th.add(handler.circleYZ,   base + 5);
        th.add(handler.circleXZ,   base + 6);
        th.add(handler.arrowX,     base + 0);
        th.add(handler.arrowY,     base + 1);
        th.add(handler.arrowZ,     base + 2);
    }

    void registerAxisHandles(ToolHandles th, int base) {
        th.add(handler.arrowX, base + 0);
        th.add(handler.arrowY, base + 1);
        th.add(handler.arrowZ, base + 2);
    }

    void registerAxisHeadHandles(ToolHandles th, int base) {
        th.add(headX, base + 0);
        th.add(headY, base + 1);
        th.add(headZ, base + 2);
    }

    override string name() const { return "Scale"; }

    override void activate() {
        super.activate();
        // Reset the gesture-producer scratch on (re)activation.
        pendingScaleValid = false;
        pendingScale      = Vec3(1, 1, 1);
    }
    final PreparedScaleActivationImage buildPreparedProductActivation() {
        PreparedScaleActivationImage image;
        auto live = mesh; if (live is null) return image;
        image.base = buildPreparedActivationImage();
        image.valid = true; return image;
    }
    final void installPreparedProductActivation(ref PreparedScaleActivationImage image)
            nothrow @nogc {
        if (!image.valid) return;
        installPreparedActivation(image.base);
        pendingScaleValid = image.pendingScaleValid;
        pendingScale = image.pendingScale; image.clear();
    }
    version(unittest) void seedPreparedProductActivationForTest() {
        seedPreparedActivationForTest();
        handler.setPosition(Vec3(2,3,4));
        pendingScaleValid = true; pendingScale = Vec3(7,7,7);
    }
    version(unittest) void mutatePreparedHandlerForTest(Vec3 center) {
        handler.setPosition(center);
    }
    version(unittest) bool preparedProductActivationForTest() const
            nothrow @nogc {
        return preparedActivationForTest() && !pendingScaleValid &&
            pendingScale == Vec3(1,1,1);
    }
    version(unittest) bool preparedProductActivationSeedForTest() const nothrow @nogc {
        return preparedActivationSeedForTest() && handler.center == Vec3(2,3,4) &&
            pendingScaleValid && pendingScale == Vec3(7,7,7);
    }
    final PreparedTransformProductEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedTransformProductEffect(
            preparedToolStateOwner, PreparedTransformProductKind.Scale, false);
        scope(failure) context.discard();
        auto owner = PreparedTransformProductActivationOwner.prepare(this);
        bool ok = owner !is null &&
            context.prepareTransformProductActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedTransformProductEffect(preparedToolStateOwner,
            PreparedTransformProductKind.Scale, ok);
    }
    final PreparedScaleUpdateEffect prepareUpdate(bool ownerEditOpen,
            Vec3 actionCenter, PreparedRecordContext context, Layer layer) {
        if (context is null) return PreparedScaleUpdateEffect(
            preparedToolStateOwner, PreparedScaleUpdateKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedScaleUpdateOwner.prepare(
            this, layer, ownerEditOpen, actionCenter);
        bool ok = owner !is null && context.markNoHistoryInstall();
        if (ok) ok = context.prepareScaleUpdate(owner);
        if (!ok) context.discard();
        return PreparedScaleUpdateEffect(preparedToolStateOwner,
            owner is null ? PreparedScaleUpdateKind.None : owner.effectKind(), ok);
    }

    /// Pointer-free classification of bank-owned refresh work. The wrapper
    /// supplies its edit gate and already-evaluated action-center pose.
    final PreparedScaleUpdateProjection projectPreparedUpdate(
            bool ownerEditOpen, Vec3 actionCenter) {
        PreparedScaleUpdateProjection image;
        image.valid = true;
        if (!active) {
            image.branch = PreparedScaleUpdateBranch.InactiveNoop;
            return image;
        }
        if (dragAxis >= 0) {
            image.branch = PreparedScaleUpdateBranch.DraggingNoop;
            return image;
        }

        image.selectionHash = computeSelectionHash();
        // recorded remainder (1906 §3.6): dormant prepared twin of the legacy
        // foreign-structure guard. Position epochs also see this tool's own
        // version-silent gesture, so they cannot answer this question.
        image.mutationVersion = mesh.mutationVersion;
        image.selectionChanged = image.selectionHash != lastSelectionHash;
        image.mutationChanged = image.mutationVersion != lastMutationVersion;
        image.ownerEditOpen = ownerEditOpen;

        if (image.selectionChanged) {
            image.branch = PreparedScaleUpdateBranch.SelectionRefresh;
        } else if (image.mutationChanged) {
            image.branch = PreparedScaleUpdateBranch.MutationRefresh;
        } else {
            image.branch = PreparedScaleUpdateBranch.IdleRefresh;
        }
        if (!(ownerEditOpen && !image.selectionChanged))
            image.actionCenter = actionCenter;
        return image;
    }

    final PreparedScaleUpdateImage buildPreparedUpdate(
            bool ownerEditOpen, Vec3 actionCenter) {
        PreparedScaleUpdateImage image;
        image.projection = projectPreparedUpdate(ownerEditOpen, actionCenter);
        if (!image.projection.valid) return image;
        image.expectedSelectionHash = image.nextSelectionHash = lastSelectionHash;
        image.expectedMutationVersion = image.nextMutationVersion = lastMutationVersion;
        image.expectedCacheDirty = image.nextCacheDirty = vertexCacheDirty;
        image.expectedCenterManual = image.nextCenterManual = centerManual;
        image.expectedCachedCenter = image.nextCachedCenter = cachedCenter;
        image.expectedHandlerCenter = image.nextHandlerCenter = handler.center;

        if (image.projection.selectionChanged || image.projection.mutationChanged) {
            image.nextSelectionHash = image.projection.selectionHash;
            image.nextMutationVersion = image.projection.mutationVersion;
            image.nextCacheDirty = true;
            if (image.projection.selectionChanged)
                image.nextCenterManual = false;
        }
        const bool effectiveEditOpen = image.projection.ownerEditOpen &&
            !image.projection.selectionChanged;
        if (!effectiveEditOpen) {
            image.nextCachedCenter = image.projection.actionCenter;
            image.nextHandlerCenter = image.projection.actionCenter;
        }
        image.valid = true; return image;
    }

    final bool preparedUpdateMatches(ref const PreparedScaleUpdateImage image,
            in Mesh live) const nothrow @nogc {
        return image.valid && lastSelectionHash == image.expectedSelectionHash &&
            lastMutationVersion == image.expectedMutationVersion &&
            vertexCacheDirty == image.expectedCacheDirty &&
            centerManual == image.expectedCenterManual &&
            preparedVec3Equal(cachedCenter, image.expectedCachedCenter) &&
            preparedVec3Equal(handler.center, image.expectedHandlerCenter);
    }

    final void installPreparedUpdate(ref PreparedScaleUpdateImage image)
            nothrow @nogc {
        if (!image.valid) return;
        lastSelectionHash = image.nextSelectionHash;
        lastMutationVersion = image.nextMutationVersion;
        vertexCacheDirty = image.nextCacheDirty;
        centerManual = image.nextCenterManual;
        cachedCenter = image.nextCachedCenter; handler.center = image.nextHandlerCenter;
        image.clear();
    }

    version(unittest) final void seedPreparedUpdateProjectionForTest(
            bool isActive, int axis, ulong selectionHash,
            ulong mutationVersion) nothrow @nogc {
        active = isActive;
        dragAxis = axis;
        lastSelectionHash = selectionHash;
        lastMutationVersion = mutationVersion;
    }

    // No `applyHeadless()` override — same reason MoveTool and RotateTool have
    // none: ScaleTool is only ever instantiated by `XfrmTransformTool`,
    // `applyHeadless` is dispatched on the ACTIVE tool only, and every factory
    // that could put a scale on screen builds the wrapper. The wrapper folds
    // `run.s` through `applyTRS`, the single geometry-apply entry point. This
    // sub-tool's version could not run and has been removed (audit №4, T3).

    override void deactivate() {
        restoreRelativeMouseMode();
        super.deactivate();
    }

    void updateInput(Vec3 actionCenter, bool ownerEditOpen) {
        if (!active) return;

        // Selection / mesh cannot change during a drag — skip checks entirely.
        if (dragAxis >= 0) return;

        // recorded remainder (1906 §3.6): `mutationVersion` owns the compare
        // below, via `currentMutVer`. Same gate and same argument as the
        // wrapper's (`xfrm_transform.d :: update`; row 21 in plan §2.3): a
        // gesture boundary asking whether a FOREIGN edit landed, which works
        // because the counter does not see this tool's own version-silent
        // `publishChange(Position)`. `g_geomEpochs` carries Position, so an
        // epoch key would fire on this tool's own drag. Argued at the wrapper.
        ulong currentHash   = computeSelectionHash();
        ulong currentMutVer = mesh.mutationVersion;
        bool selChanged = (currentHash   != lastSelectionHash);
        bool mutChanged = (currentMutVer != lastMutationVersion);

        if (selChanged || mutChanged) {
            lastSelectionHash   = currentHash;
            lastMutationVersion = currentMutVer;
            vertexCacheDirty    = true;

            if (selChanged) centerManual = false;
        }

        // Pull the gizmo center from the ACEN stage every frame: mode /
        // userPlaced changes don't bump the selection hash or mesh
        // mutation, so they would otherwise not propagate to the
        // visible gizmo.
        //
        // Skip during an owner edit: re-pulling from ACEN here would drift it
        // as the bbox-centroid
        // of the deformed selection moves under non-uniform per-vertex
        // weight.
        if (!ownerEditOpen) {
            cachedCenter = actionCenter;
            handler.setPosition(cachedCenter);
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false)
    {
        if (!active) return;
        // Task 0206: gate cachedVp on the interactive (owner-cell) draw —
        // see Tool.draw's doc comment.
        if (!visualOnly) cachedVp = vp;

        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.draw(shader, vp);

        // Cyan element + yellow cursor marker for the active snap
        // candidate. Populated by updateLiveSnapPreview(, vts) during idle
        // hover (click-outside-relocate hint).
        drawSnapOverlay(lastSnap, vp, *mesh);
        // Falloff overlay + endpoint handles are drawn ONCE at the
        // XfrmTransformTool wrapper, via the PipeGizmoHost-owned emitter.
        // The banks never touch falloff.
    }

    void drawAxisBoxesOnly(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false)
    {
        if (!active) return;
        if (!visualOnly) cachedVp = vp;

        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.drawAxisBoxesOnly(shader, vp);

        drawSnapOverlay(lastSnap, vp, *mesh);
    }

    bool onMouseButtonDownWithResolvedAxis(ref const SDL_MouseButtonEvent e,
                                           ref VectorStack vts,
                                           int resolvedAxis) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        version(unittest) SDL_Keymod mods = 0;
        else SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        // Soft Drag: re-center the screen-falloff disc at the click on
        // every fresh grab AND flip the overlay-visibility flag on so
        // the disc renders for the duration of the LMB hold — even
        // when the click lands outside a gizmo handle (no drag will
        // start, but the user still gets visual confirmation of where
        // the falloff is anchored). No-ops when no Screen-type falloff stage
        // is active.
        {
            import falloff_handles : screenFalloffActive,
                                     screenFalloffSetCenter,
                                     screenFalloffLMBBegin;
            if (screenFalloffActive()) {
                screenFalloffSetCenter(e.x, e.y);
                screenFalloffLMBBegin();
            }
        }
        dragAxis = resolvedAxis >= 0 ? resolvedAxis : hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            lastMX = e.x; lastMY = e.y;
            // Freeze the input-projection basis for the gesture (= the
            // current idle basis = the frozen rendered orientation today).
            currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);
            dragScaleAccum = Vec3(1, 1, 1);
            dragScaleScalarDelta = 0.0f;
            version(unittest) {
                preDragRelativeMouse = SDL_FALSE;
                ownsRelativeMouse = false;
            } else {
                preDragRelativeMouse = SDL_GetRelativeMouseMode();
                ownsRelativeMouse = SDL_SetRelativeMouseMode(SDL_TRUE) == 0;
            }

            return true;
        }

        // ── A PRESS OUTSIDE THE GIZMO IS TWO INDEPENDENT THINGS ─────────────
        //
        //   1. the PIVOT may relocate — only in the modes that allow it;
        //   2. a plane-scale HAUL arms — in EVERY mode.
        //
        // They used to be one branch. The haul sat AFTER the relocate's two
        // early returns, so a mode that pins its pivot could not reach the
        // election at all: an off-handle drag in such a mode did nothing
        // whatsoever, measurably (all three axes at exactly 1).
        //
        // The reference has no such coupling, and this is the one part of the
        // election that is settled STRUCTURALLY rather than by observation. Its
        // haul fetches the action centre ONCE, as a packet whose entire payload
        // is a single position, and elects from that. There is no
        // action-centre-mode test anywhere on the path — and a packet carrying
        // nothing but a point could not carry one even if the code wanted it.
        // The mode reaches the election only by changing what the two inputs
        // ARE: the centre, and the tool axis frame. Both of those we already
        // have (see `pickPlaneAxes`), and both are ours.
        //
        // So the relocate keeps its gate and the haul gets none. A press whose
        // relocate ray missed its plane also falls through to the haul now,
        // instead of returning without doing anything.
        Vec3 center;
        if (pressPlacesCenter()
            && computeClickRelocateHit(e.x, e.y, center, vts))
        {
            handler.setPosition(center);
            centerManual = true;
            notifyAcenUserPlaced(center);
            lastClickWasRelocate = true;
        } else {
            // PINNED (or a relocate ray that missed its plane). Nothing about
            // the pivot changes — no `notifyAcenUserPlaced`, no
            // `centerManual`, no run boundary — so the centre the election
            // reads is simply the one the pipeline already published for this
            // press. That is the same single point the reference's haul
            // fetches; the mode chose it upstream, in the ACEN stage, exactly
            // as the mode chooses the axis frame upstream in the AXIS stage.
            center = queryActionCenter(vts);
        }
        // Arming here mirrors Rotate's off-ring arcball, which relocates and
        // then arms in exactly the same place.
        //
        // `center` is passed rather than re-read from the handler because it
        // IS the action centre for this press, and the election is a function
        // of it. Where the press relocated, that centre lies ON the press ray,
        // so the eye ray through it is the ray through the press pixel and two
        // presses at one camera can elect different axes. Where the pivot is
        // pinned it does not, and the election is camera-only for that mode —
        // which is the whole of the auto/origin split.
        //
        // Returning true keeps a scale-tool click away from the gizmo from
        // falling through to selection-picking and dropping the user's
        // selection, in every mode now rather than only the relocating ones.
        // `armPlaneDrag` still returns false on a degenerate eye ray (the
        // action centre sitting exactly on the eye); the click is consumed
        // either way.
        armPlaneDrag(e, vts, center);
        return true;
    }

    // Choose the two basis axes the two screen components drive. Delegates to
    // the pure kernel so the law lives in exactly one place; the kernel's
    // docstring carries the read it implements and the evidence for each term.
    // Returns false only when the eye ray is degenerate.
    //
    // WHAT THIS SUPPLIES, AND WHAT BECAME OF THE OLD BASIS REFUSAL.
    // The election consumes the EYE RAY at the action centre — `center - eye`,
    // which reads no up vector and is therefore roll-invariant no matter what
    // the camera can do. That much is unconditional and unchanged.
    //
    // The refusal itself rested on a premise that is NO LONGER TRUE. It used to
    // read: our viewports are built `lookAt(eye, focus, Vec3(0,1,0))` and can
    // never be banked while the reference's are, so a screen-basis election is
    // structurally unportable. `View` now carries a bank (`view.d`, the
    // "Camera BANK" section) — screen-right can leave the world XZ plane, and
    // the reference's own recorded bank is reproducible here.
    //
    // WHAT SURVIVES is the conclusion for THIS function, and it never rested on
    // the camera model: two of the three branches compare nothing at all, so
    // they are basis-independent either way. The bank is what makes the third
    // branch TESTABLE — it is not what made the other two safe. So the scoping
    // decision this comment justifies (delegate the law, pass `screenRight`
    // only for the branch that reads it) stands on its original footing.
    //
    // `screenRight` is passed for the third branch only (`excluded == 1`),
    // which is the branch three of the shipped action-centre modes take on the
    // reference-comparison corpus's own rig — not the rare leg an earlier
    // comment here called it. That branch's single comparison IS bank-sensitive,
    // and it is now exercisable at a non-zero bank rather than only against a
    // structurally zero operand — see the kernel for what that measured, and
    // for why no parity row moves.
    //
    // `center` is the action centre for this press — the relocated point in a
    // mode that relocates, the pipeline's published centre in one that pins.
    // Where it relocated it lies ON the press ray, so the eye ray through it
    // is the ray through the press pixel and the election is press-dependent
    // rather than camera-only. Where it is pinned it does not move with the
    // press, and the election IS camera-only for that mode.
    //
    // THE AXES ARE THE AXIS STAGE'S, PER MODE — NOT THE WORLD AXES.
    // `currentBasis` resolves to the `AxisPacket` the AXIS stage published,
    // and the `actr.*` presets flip ACEN and AXIS together
    // (`registration.d`'s preset table: auto->auto, origin->world,
    // select/border->select, local->local, screen->screen). That is our own
    // equivalent of the reference's tool axis matrix, which a second read
    // showed to be per-mode rather than the identity it looked like when only
    // one mode had been sampled. We hand ours in; we do not transcribe theirs.
    // See `pickScalePlaneAxes`'s `A_k` bullet.
    private bool pickPlaneAxes(ref VectorStack vts, Vec3 center,
                               out int hIdx, out int vIdx)
    {
        import tools.transform.xform_kernels : pickScalePlaneAxes;
        import math : isOrtho;
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);
        immutable Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4],
                                       cachedVp.view[8]);
        // Perspective: the ray from the eye through the action centre. Ortho
        // has no eye point — every ray is the view direction, which is what
        // the reference's own accessor would return there too.
        immutable Vec3 eyeVec = isOrtho(cachedVp)
            ? Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10])
            : Vec3(center.x - cachedVp.eye.x,
                   center.y - cachedVp.eye.y,
                   center.z - cachedVp.eye.z);
        int excluded; float margin;
        return pickScalePlaneAxes(eyeVec, camRight, bX, bY, bZ,
                                  hIdx, vIdx, excluded, margin);
    }

    private bool armPlaneDrag(ref const SDL_MouseButtonEvent e,
                              ref VectorStack vts, Vec3 center)
    {
        if (!pickPlaneAxes(vts, center, planeAxisH, planeAxisV))
            return false;
        dragAxis = PLANE_DRAG_AXIS;
        lastMX = e.x; lastMY = e.y;
        planeAccumX = 0.0f; planeAccumY = 0.0f;
        // Freeze the input-projection basis for the gesture, exactly as a
        // handle drag does, so the drag direction cannot reverse if the
        // rendered frame moves under it.
        currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);
        dragScaleAccum       = Vec3(1, 1, 1);
        dragScaleScalarDelta = 0.0f;
        version(unittest) {
            preDragRelativeMouse = SDL_FALSE;
            ownsRelativeMouse = false;
        } else {
            preDragRelativeMouse = SDL_GetRelativeMouseMode();
            ownsRelativeMouse = SDL_SetRelativeMouseMode(SDL_TRUE) == 0;
        }
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        return onMouseButtonDownWithResolvedAxis(e, vts, -1);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Hide the screen-falloff disc on every LMB-up — onMouseButtonDown
        // turned it on unconditionally when Screen falloff is active so
        // the disc shows for the whole click+hold, including the click-
        // outside-gizmo case where no drag ever starts.
        if (e.button == SDL_BUTTON_LEFT) {
            import falloff_handles : screenFalloffLMBEnd;
            screenFalloffLMBEnd();
        }
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;

        // Single-source: the unified wrapper owns the drag geometry +
        // final GPU upload (it rebuilt mesh.vertices through applyTRS
        // every frame and uploads / resets gpuMatrix in
        // XfrmTransformTool.onMouseButtonUp). This sub-tool only resets
        // its own drag bookkeeping here; no geometry, no upload.
        restoreRelativeMouseMode();

        dragAxis = -1;
        // Drop the snap overlay so it doesn't linger after the drag.
        lastSnap = SnapResult.init;
        clearLastSnap();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (dragAxis == -1) {
            // Live snap preview during idle hover — same convention as
            // Move/Rotate. hitTestAxes >= 0 = on a scale handle
            // (would start a drag), so the preview suppresses itself.
            updateLiveSnapPreview(e.x, e.y, hitTestAxes(e.x, e.y), vts);
            return false;
        }

        Vec3 center = handler.center;
        int dxRel = motionDeltaX(e);
        int dyRel = motionDeltaY(e);

        if (dragAxis == 3) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            dragScaleScalarDelta += cast(float)dxRel / gizmoScreenPx;
            float scaleFactor = clampScaleFactor(1.0f + dragScaleScalarDelta);
            setDragAxisScale(true, true, true, scaleFactor);
            publishScaleGesture();
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        if (dragAxis == PLANE_DRAG_AXIS) {
            // A PLANE scale: two axes, two DIFFERENT gains, one per screen
            // component; the third axis is left at exactly 1. The gains are
            // positional in the accumulated drag (not per-event), so the result
            // is path-independent — the same property the handle drags have.
            planeAccumX += cast(float)dxRel;
            planeAccumY += cast(float)dyRel;
            import tools.transform.xform_kernels : screenPlaneScaleGain;
            // The signs here are the SCREEN CONVENTION and nothing else. The
            // reference accumulates `cur.x - last.x` and `last.y - cur.y` and
            // writes both into the elected attributes with NO per-axis sign —
            // an elected axis whose screen projection points left still GROWS
            // on a rightward drag. Our deltas are y-down, so the vertical
            // carries the -1 and the horizontal carries +1, whichever axes the
            // election handed us.
            immutable float fH = clampScaleFactor(screenPlaneScaleGain(
                planeAccumX, +1.0f, PLANE_DRAG_PIXELS));
            immutable float fV = clampScaleFactor(screenPlaneScaleGain(
                planeAccumY, -1.0f, PLANE_DRAG_PIXELS));
            setAxisScale(planeAxisH, fH);
            setAxisScale(planeAxisV, fV);
            publishScaleGesture();
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        if (dragAxis >= 4) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            dragScaleScalarDelta += cast(float)dxRel / gizmoScreenPx;
            float scaleFactor = clampScaleFactor(1.0f + dragScaleScalarDelta);
            bool scaleX = (dragAxis == 4 || dragAxis == 6);
            bool scaleY = (dragAxis == 4 || dragAxis == 5);
            bool scaleZ = (dragAxis == 5 || dragAxis == 6);
            setDragAxisScale(scaleX, scaleY, scaleZ, scaleFactor);
            publishScaleGesture();
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // Single-axis drag projects the screen drag onto the unified gesture
        // frame when wrapper-chained (gesture-frame unification, Phase 2), else
        // the bank's drag-start-frozen INPUT basis — never the rendered
        // `handler.axis*`, so the drag direction can't reverse if the rendered
        // frame moves. The channel carries the same value the old hand-synced
        // override wrote, so this is byte-identical when chained.
        debug assertWrapperInputFrameChained();
        Vec3 axis = dragAxis == 0 ? inAxisX()
                  : dragAxis == 1 ? inAxisY()
                                  : inAxisZ();

        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(center + axis, cachedVp, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx = ax_ - cx, sdy = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        dragScaleScalarDelta += (dxRel * sdx + dyRel * sdy) / slen2;
        float scaleFactor = clampScaleFactor(1.0f + dragScaleScalarDelta);
        bool  axX = (dragAxis == 0), axY = (dragAxis == 1), axZ = (dragAxis == 2);
        setDragAxisScale(axX, axY, axZ, scaleFactor);
        publishScaleGesture();

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    // Gesture-scalar producer (scale single-source). Publishes the
    // ABSOLUTE within-drag per-axis scale factor (`dragScaleAccum`,
    // reset to 1 at drag start) for the unified wrapper to drain into
    // its `run.s` and feed `applyTRS`. Every gizmo drag mode
    // (single-axis arrow 0/1/2, uniform centre disc 3, plane circle
    // 4/5/6) maps onto the same Vec3 of per-axis factors, so — unlike
    // rotate's view-ring — there is no interactive-only exemption: ALL
    // scale drags route through here. NO geometry mutation; the single
    // geometry-apply entry point is `XfrmTransformTool.applyTRS`.
    private void publishScaleGesture() {
        pendingScale      = dragScaleAccum;
        pendingScaleValid = true;
    }

    // Task 0332 — gated on the owner-provided negative-scale option: when on, a
    // negative scale factor (the drag has crossed zero) is let through
    // unclamped (mirror). Off keeps the pre-0332 clamp-at-0 behavior.
    // Regardless of the flag, a non-finite delta (NaN/inf, float drift
    // in the accumulated `dragScaleScalarDelta`) is rejected back to the
    // identity factor 1.0 — never propagated into the kernel.
    private float clampScaleFactor(float f) {
        import std.math : isFinite;
        if (!isFinite(f)) return 1.0f;
        if (negativeScaleEnabled) return f;
        return f < 0.0f ? 0.0f : f;
    }

    // Per-INDEX form of `setDragAxisScale`. The plane drag needs a DIFFERENT
    // factor on each of its two axes, which the boolean form cannot express.
    private void setAxisScale(int idx, float scaleFactor) {
        final switch (idx) {
            case 0: setDragAxisScale(true,  false, false, scaleFactor); break;
            case 1: setDragAxisScale(false, true,  false, scaleFactor); break;
            case 2: setDragAxisScale(false, false, true,  scaleFactor); break;
        }
    }

    // Publish this motion's within-drag factor. The owner folds it onto its
    // gesture-start run value; this bank owns no cumulative transform state.
    private void setDragAxisScale(bool scaleX, bool scaleY, bool scaleZ,
                                  float scaleFactor)
    {
        if (scaleX) dragScaleAccum.x = scaleFactor;
        if (scaleY) dragScaleAccum.y = scaleFactor;
        if (scaleZ) dragScaleAccum.z = scaleFactor;
    }

    private int motionDeltaX(ref const SDL_MouseMotionEvent e) const {
        return e.xrel != 0 ? e.xrel : e.x - lastMX;
    }

    private int motionDeltaY(ref const SDL_MouseMotionEvent e) const {
        return e.yrel != 0 ? e.yrel : e.y - lastMY;
    }

    private void restoreRelativeMouseMode() {
        if (!ownsRelativeMouse) return;
        SDL_SetRelativeMouseMode(preDragRelativeMouse);
        ownsRelativeMouse = false;
    }

    struct PanelInput {
        Vec3 scale;
        bool active;
        bool done;
    }

    PanelInput drawInputProperties(Vec3 publishedValue) {
        Vec3 value = publishedValue;
        // Task 0332: negScale relaxes both the slider's v_min floor and the
        // post-write clamp below so a panel drag can cross zero into a
        // negative (mirrored) factor.
        float scaleVMin = negativeScaleEnabled ? -float.max : 0.0f;
        ImGui.DragFloat("X", &value.x, 0.01f, scaleVMin, float.max, "%.4f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &value.y, 0.01f, scaleVMin, float.max, "%.4f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &value.z, 0.01f, scaleVMin, float.max, "%.4f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        if (!negativeScaleEnabled) {
            if (value.x < 0.0f) value.x = 0.0f;
            if (value.y < 0.0f) value.y = 0.0f;
            if (value.z < 0.0f) value.z = 0.0f;
        }
        return PanelInput(value, xActive || yActive || zActive,
                          xDone || yDone || zDone);
    }

private:
    float gizmoScreenWidth(Vec3 center) {
        Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4], cachedVp.view[8]);
        Vec3 rightEnd = center + camRight * handler.size;
        float cx, cy, cndcZ, rx, ry, rndcZ;
        if (!projectToWindowFull(center,   cachedVp, cx, cy, cndcZ)) return -1.0f;
        if (!projectToWindowFull(rightEnd, cachedVp, rx, ry, rndcZ)) return -1.0f;
        return sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    }

    int hitTestAxes(int mx, int my) {
        if (handler.centerDisk.hitTest(mx, my, cachedVp)) return 3;
        if (handler.circleXY.hitTest(mx, my, cachedVp)) return 4;
        if (handler.circleYZ.hitTest(mx, my, cachedVp)) return 5;
        if (handler.circleXZ.hitTest(mx, my, cachedVp)) return 6;

        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < GIZMO_PICK_AXIS_PX)
                return cast(int)i;
        }
        return -1;
    }

    public int hitTestAxisHeads(int mx, int my) {
        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float ex, ey, ndcZ;
            if (!projectToWindowFull(arrow.end, cachedVp, ex, ey, ndcZ)) continue;
            float dx = cast(float)mx - ex;
            float dy = cast(float)my - ey;
            if (sqrt(dx*dx + dy*dy) < GIZMO_PICK_SCALE_HEAD_PX)
                return cast(int)i;
        }
        return -1;
    }
}
