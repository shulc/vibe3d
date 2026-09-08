module tools.transform.rotate;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tools.transform.transform;

struct PreparedRotateActivationImage {
    PreparedTransformActivationImage base;
    Vec3 pendingRotateViewAxis;
    int pendingRotateAxis;
    float pendingRotateAngle;
    bool valid;
    void clear() nothrow @nogc { this = PreparedRotateActivationImage.init; }
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

import std.math;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import tools.transform.arcball : ARCBALL_RADIUS_PX, arcballRotation,
                                 arcballAxisToWorld;
import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import params : Param;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind,
    PreparedTransformProductEffect, PreparedTransformProductKind,
    PreparedRotateUpdateEffect, PreparedRotateUpdateKind;
import prepared_transform_product_activation : PreparedTransformProductActivationOwner;
import prepared_rotate_update : PreparedRotateUpdateOwner;
import prepared_xfrm_refire_state : PreparedXfrmRefireStateImage;

/// Closed observation of the branches owned by `RotateTool.update`.  This is
/// deliberately pointer-free: the future prepared owner can retain the exact
/// tool separately while this value records which legacy arm must be built.
enum PreparedRotateUpdateBranch : ubyte {
    InactiveNoop,
    DraggingNoop,
    IdleRefresh,
    SelectionRefresh,
    MutationRefresh,
}

struct PreparedRotateUpdateProjection {
    PreparedRotateUpdateBranch branch;
    ulong selectionHash, mutationVersion;
    bool selectionChanged, mutationChanged, ownerEditOpen;
    Vec3 actionCenter;
    bool valid;
    void clear() nothrow @nogc { this = PreparedRotateUpdateProjection.init; }
}

struct PreparedRotateUpdateImage {
    PreparedRotateUpdateProjection projection;
    Mesh candidate;
    ulong expectedSelectionHash, expectedMutationVersion;
    ulong nextSelectionHash, nextMutationVersion;
    bool expectedCacheDirty, nextCacheDirty;
    bool expectedCenterManual, nextCenterManual;
    Vec3 expectedCachedCenter, expectedHandlerCenter;
    Vec3 nextCachedCenter, nextHandlerCenter;
    bool valid;

    void clear() nothrow @nogc {
        this = PreparedRotateUpdateImage.init;
    }
}

// ---------------------------------------------------------------------------
// RotateTool : Tool — shows RotateHandler at selection/mesh center;
//              rotates selected vertices around the dragged axis.
// ---------------------------------------------------------------------------

class RotateTool : TransformTool {
    RotateHandler handler;

private:
    float    cachedSize;      // gizmo radius in world units (from last draw)
    Vec3     dragStartDir;    // direction from center to click point in arc plane
    float    totalAngle = 0;       // accumulated raw angle during drag (radians)
    float    lastSnappedAngle = 0; // last snapped angle value (kept in sync for display)
    // Absolute-angle drag state: the gesture angle is measured each frame as
    // the signed angle from a FIXED grab reference to the cursor's current
    // point on the rotation plane, never integrated frame-to-frame. This
    // immunises the ring against the edge-on ray-plane singularity that
    // otherwise flips the angle ~180° in a single frame and launches the model.
    Vec3     dragRefDir;           // unit center→grab-point direction in the arc plane
    float    dragRefRadius = 0;    // |grab point − center|; sets the grazing-reject scale
    float    prevWrapped = 0;      // previous frame's wrapped [-π,π] angle (unwrap state)
    Vec3     viewDragAxis;    // camera forward captured at start of view-plane drag
    Vec3     dragAxisVec;     // axis vector for current drag (cached to avoid recomputation)
    // Input-projection basis, captured ONCE at drag start from the live
    // `currentBasis(...)`. The principal-axis ring already freezes its
    // gesture math into `dragAxisVec` / `dragRefDir`; this names the frozen
    // frame the VIEW-RING mouse-up decomposition reads (the dot products
    // that split a camera-aligned rotation onto the gizmo axes), so that
    // decode no longer depends on the rendered `handler.axis*` staying
    // frozen. Captured from the same `currentBasis(...)` the last idle draw
    // used ⇒ byte-stable today.
    Vec3     inputBasisX = Vec3(1, 0, 0);
    Vec3     inputBasisY = Vec3(0, 1, 0);
    Vec3     inputBasisZ = Vec3(0, 0, 1);

    // Owner-provided input-frame channel (gesture-frame unification, Phase 2).
    // The rotate freeze-ordering trap: the principal `dragAxisVec`/`dragRefDir`
    // are frozen at `onMouseButtonDown` (from `inputBasis*`), which runs BEFORE
    // the wrapper's `beginRotateDragSession`. So a bare channel write would be
    // too late — `setWrapperInputFrame` RE-DERIVES `dragAxisVec`/`dragRefDir`
    // from the pushed frame after button-down (the former `rechainPrincipalDragAxis`
    // logic, now routed through the unified frame channel). When chained, the
    // pushed frame is the wrapper's persisted gesture frame, so the rotation plane
    // is byte-identical to the prior override. The view-ring (dragAxis==3) is
    // camera-axis/basis-free and
    // EXCLUDED: this never fires for it (principal rings 0/1/2 only), and the
    // view-ring mouse-up decompose keeps reading the LIVE `inputBasis*` (which is
    // never overwritten now). An unchained gesture keeps deriving
    // `dragAxisVec` from its own `inputBasis*`.
    Vec3     wrapperInputFrameX = Vec3(1, 0, 0);
    Vec3     wrapperInputFrameY = Vec3(0, 1, 0);
    Vec3     wrapperInputFrameZ = Vec3(0, 0, 1);
    bool     wrapperInputFrameValid = false;

public:
    final Mesh* preparedMeshForUpdate() const { return mesh; }
    final EditMode preparedEditModeForUpdate() const nothrow @nogc { return *editMode; }

    // ── rotate single-source plumbing (doc/rotate_single_source_plan.md) ──
    //
    // Gesture-scalar producer output. MS-3 makes the principal-axis drag
    // branch (axis 0/1/2) publish the ABSOLUTE accumulated ring angle here
    // and return without mutating geometry; the wrapper drains it into its
    // `headlessRotate` and runs `applyTRS`. `axis == -1` means "nothing
    // pending" (idle / hover / view-ring frames leave it untouched).
    int   pendingRotateAxis  = -1;      // 0/1/2 principal ring, 3 view-ring
    float pendingRotateAngle = 0;       // radians, absolute since drag start
    // View axis (camera-forward) published alongside pendingRotateAxis == 3.
    // The wrapper FOLDS the within-gesture angle about this world axis onto
    // `gestureStart.r` to get `run.r` (there is no separate view-axis/angle
    // slot any more — the matrix IS the truth), then applies through applyTRS.
    // Meaningless for axes 0/1/2.
    Vec3  pendingRotateViewAxis = Vec3(0, 0, 0);

    // ── the off-gizmo arcball (tools.transform.arcball) ──────────────────
    // Set at a press that lands away from every ring, cleared at every other
    // press and at mouse-up. While set, `dragAxis` is 3 (an arbitrary world
    // axis, published with its angle) but the axis and angle come from the
    // BALL, not from an arc plane.
    bool  arcballDrag = false;
    float arcballCx = 0, arcballCy = 0;          // ball centre, window pixels
    float arcballPressX = 0, arcballPressY = 0;  // the gesture's fixed reference

    // Read + cleared by the wrapper on the press that set them, exactly as the
    // Move bank's pair are: `lastClickWasRelocate` says this press MOVED the
    // pivot, `lastClickWasOffGizmo` says it missed every ring. An off-gizmo
    // press is an undo-run boundary in every mode; only the pin handling
    // differs between the two.
    bool  lastClickWasRelocate = false;
    bool  lastClickWasOffGizmo = false;

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         SelType delegate() selTypeSrc = null) {
        super(meshSrc, gpu, editMode, selTypeSrc);
        handler = new RotateHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    // Register this bank's gizmo handles into the shared arbiter `th`
    // at part-id offset `base` (so overlapping handles across banks get
    // distinct parts). Order = hitTestAxes priority (X, Y, Z, view-ring)
    // so the highlighted arc matches the one a click grabs. bgCircle is
    // decorative — not registered. Does NOT begin()/update()/suppress()
    // — the wrapper owns the single test+update pass.
    void registerHandles(ToolHandles th, int base) {
        th.add(handler.arcX,    base + 0);
        th.add(handler.arcY,    base + 1);
        th.add(handler.arcZ,    base + 2);
        th.add(handler.arcView, base + 3);
    }

    void registerPrincipalHandles(ToolHandles th, int base) {
        th.add(handler.arcX,    base + 0);
        th.add(handler.arcY,    base + 1);
        th.add(handler.arcZ,    base + 2);
        th.add(handler.arcView, base + 3);
    }

    void setWrapperGizmoPose(Vec3 center, Vec3 bX, Vec3 bY, Vec3 bZ)
            nothrow @nogc {
        cachedCenter = center;
        handler.setPosition(center);
        // flex_border_handles_plan.md Phase 2 — apply the wrapper's Model-C
        // RENDER basis UNCONDITIONALLY (old `dragAxis < 0` render gate removed,
        // Risk 1). For the rotate bank the wrapper-supplied basis during a drag
        // IS the composed `R_gesture · B0` (the ring's own rotated frame), so the
        // rendered ring + sibling banks share one orientation. The rotation INPUT
        // math reads the drag-start-frozen `inputBasisX/Y/Z` (Phase 1) /
        // dragAxisVec / dragRefDir, never handler.axis*, so the angle is
        // unaffected by the moving rendered frame.
        handler.setOrientation(bX, bY, bZ);
    }

    override string name() const { return "Rotate"; }

    override void activate() {
        super.activate();
        // Reset the gesture-producer scratch on (re)activation.
        pendingRotateAxis    = -1;
        pendingRotateAngle   = 0;
        pendingRotateViewAxis = Vec3(0, 0, 0);
    }
    final PreparedRotateActivationImage buildPreparedProductActivation() {
        PreparedRotateActivationImage image;
        auto live = mesh; if (live is null) return image;
        image.base = buildPreparedActivationImage();
        image.pendingRotateAxis = -1; image.pendingRotateAngle = 0;
        image.pendingRotateViewAxis = Vec3(0,0,0);
        image.valid = true; return image;
    }
    final void installPreparedProductActivation(ref PreparedRotateActivationImage image)
            nothrow @nogc {
        if (!image.valid) return;
        installPreparedActivation(image.base);
        pendingRotateAxis = image.pendingRotateAxis;
        pendingRotateAngle = image.pendingRotateAngle;
        pendingRotateViewAxis = image.pendingRotateViewAxis; image.clear();
    }
    version(unittest) void seedPreparedProductActivationForTest() {
        seedPreparedActivationForTest(); pendingRotateAxis = 2;
        pendingRotateAngle = 7; pendingRotateViewAxis = Vec3(8,8,8);
    }
    version(unittest) bool preparedProductActivationForTest() const
            nothrow @nogc {
        return preparedActivationForTest() &&
            pendingRotateAxis == -1 &&
            pendingRotateAngle == 0 && pendingRotateViewAxis == Vec3(0,0,0);
    }
    version(unittest) bool preparedProductActivationSeedForTest() const nothrow @nogc {
        return preparedActivationSeedForTest() &&
            pendingRotateAxis == 2 &&
            pendingRotateAngle == 7 && pendingRotateViewAxis == Vec3(8,8,8);
    }
    final PreparedTransformProductEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedTransformProductEffect(
            preparedToolStateOwner, PreparedTransformProductKind.Rotate, false);
        scope(failure) context.discard();
        auto owner = PreparedTransformProductActivationOwner.prepare(this);
        bool ok = owner !is null &&
            context.prepareTransformProductActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedTransformProductEffect(preparedToolStateOwner,
            PreparedTransformProductKind.Rotate, ok);
    }

    final PreparedRotateUpdateEffect prepareUpdate(bool ownerEditOpen,
            Vec3 actionCenter, PreparedRecordContext context, Layer layer) {
        if (context is null) return PreparedRotateUpdateEffect(
            preparedToolStateOwner, PreparedRotateUpdateKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedRotateUpdateOwner.prepare(
            this, layer, ownerEditOpen, actionCenter);
        bool ok = owner !is null && context.markNoHistoryInstall();
        if (ok) ok = context.prepareRotateUpdate(owner);
        if (!ok) context.discard();
        return PreparedRotateUpdateEffect(preparedToolStateOwner,
            owner is null ? PreparedRotateUpdateKind.None : owner.effectKind(), ok);
    }

    /// Allocation-free projection of the bank-owned refresh work. The wrapper
    /// supplies its edit gate and the already-evaluated action-center pose.
    final PreparedRotateUpdateProjection projectPreparedUpdate(
            bool ownerEditOpen, Vec3 actionCenter) {
        PreparedRotateUpdateProjection image;
        image.valid = true;
        if (!active) {
            image.branch = PreparedRotateUpdateBranch.InactiveNoop;
            return image;
        }
        if (dragAxis >= 0) {
            image.branch = PreparedRotateUpdateBranch.DraggingNoop;
            return image;
        }

        image.selectionHash = computeSelectionHash();
        // recorded remainder (1906 §3.6): this is the detached twin of the
        // legacy update guard below. `mutationVersion` owns detection of a
        // FOREIGN structural edit; a Position bus epoch would also observe
        // this tool's own version-silent gesture and would misclassify it.
        image.mutationVersion = mesh.mutationVersion;
        image.selectionChanged = image.selectionHash != lastSelectionHash;
        image.mutationChanged = image.mutationVersion != lastMutationVersion;
        image.ownerEditOpen = ownerEditOpen;

        if (image.selectionChanged) {
            image.branch = PreparedRotateUpdateBranch.SelectionRefresh;
        } else if (image.mutationChanged) {
            image.branch = PreparedRotateUpdateBranch.MutationRefresh;
        } else {
            image.branch = PreparedRotateUpdateBranch.IdleRefresh;
        }
        if (!(ownerEditOpen && !image.selectionChanged))
            image.actionCenter = actionCenter;
        return image;
    }

    final PreparedRotateUpdateImage buildPreparedUpdate(
            bool ownerEditOpen, Vec3 actionCenter) {
        PreparedRotateUpdateImage image;
        image.projection = projectPreparedUpdate(ownerEditOpen, actionCenter);
        if (!image.projection.valid) return image;
        image.expectedSelectionHash = image.nextSelectionHash = lastSelectionHash;
        image.expectedMutationVersion = image.nextMutationVersion = lastMutationVersion;
        image.expectedCacheDirty = image.nextCacheDirty = vertexCacheDirty;
        image.expectedCenterManual = image.nextCenterManual = centerManual;
        image.expectedCachedCenter = image.nextCachedCenter = cachedCenter;
        image.expectedHandlerCenter = image.nextHandlerCenter = handler.center;

        if (image.projection.selectionChanged ||
            image.projection.mutationChanged) {
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
        image.valid = true;
        return image;
    }

    final bool preparedUpdateMatches(ref const PreparedRotateUpdateImage image,
            in Mesh live) const nothrow @nogc {
        return image.valid && lastSelectionHash == image.expectedSelectionHash &&
            lastMutationVersion == image.expectedMutationVersion &&
            vertexCacheDirty == image.expectedCacheDirty &&
            centerManual == image.expectedCenterManual &&
            preparedVec3Equal(cachedCenter, image.expectedCachedCenter) &&
            preparedVec3Equal(handler.center, image.expectedHandlerCenter);
    }

    final void installPreparedUpdate(ref PreparedRotateUpdateImage image)
            nothrow @nogc {
        if (!image.valid) return;
        lastSelectionHash = image.nextSelectionHash;
        lastMutationVersion = image.nextMutationVersion;
        vertexCacheDirty = image.nextCacheDirty;
        centerManual = image.nextCenterManual;
        cachedCenter = image.nextCachedCenter;
        handler.center = image.nextHandlerCenter;
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

    // No `applyHeadless()` override — same reason MoveTool has none (see the
    // note at move.d's `params()`): RotateTool is only ever instantiated by
    // `XfrmTransformTool`, `applyHeadless` is dispatched on the ACTIVE tool
    // only, and every factory that could put a rotate on screen (`rotate`,
    // `TransformRotate`, `Transform`, `xfrm.elementMove`) builds the wrapper.
    // The wrapper's own `applyHeadless` recomposes `run.r` from the injected
    // euler and folds it through `applyTRS`, which is the single geometry-apply
    // entry point. This sub-tool's version could not run and has been removed
    // (audit №4, T3).

    override void deactivate() {
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
        // Phase 7.5h: skip while an edit session is open — handler
        // position is maintained by drag / slider / click-relocate,
        // and re-pulling on every frame can snap the pivot away from
        // where the user expects after a falloff-driven rotation
        // (selection bbox centroid drifts). Edit closes at deactivate
        // / selection change; the next update() then re-pulls cleanly.
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

        // Flush pending partial-selection GPU upload once per frame.
        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        handler.draw(shader, vp);
        cachedSize = handler.size;

        if (dragAxis >= 0 && (dragStartDir.x != 0 || dragStartDir.y != 0 || dragStartDir.z != 0))
            drawRotationSector(vp);

        // Cyan element + yellow cursor marker for the active snap
        // candidate. Populated by updateLiveSnapPreview(, vts) during idle
        // hover (click-outside-relocate hint). Drag-time snap math
        // for rotation isn't wired yet, so during a drag this overlay
        // reflects whatever the last preview frame produced and can
        // freeze — acceptable for now.
        drawSnapOverlay(lastSnap, vp, *mesh);
        // Falloff overlay + endpoint handles are drawn ONCE at the
        // XfrmTransformTool wrapper, via the PipeGizmoHost-owned emitter.
        // The banks never touch falloff.
    }

    void drawPrincipalOnly(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false)
    {
        if (!active) return;
        if (!visualOnly) cachedVp = vp;

        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        handler.drawPrincipalOnly(shader, vp);
        handler.arcView.draw(shader, vp);
        cachedSize = handler.size;

        if (dragAxis >= 0 && (dragStartDir.x != 0 || dragStartDir.y != 0 || dragStartDir.z != 0))
            drawRotationSector(vp);
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
        // the falloff is anchored). Must happen BEFORE
        // captureFalloffForDrag(vts) below. No-ops when no Screen-type
        // falloff stage is active.
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
        arcballDrag = false;
        if (dragAxis < 0) {
            // A press away from every ring. TWO independent questions, and one
            // predicate used to answer both — the same conflation the Move bank
            // untangled:
            //
            //   (a) may this click MOVE the pivot?  Only Auto / None / Screen.
            //       The rest derive it from the selection or pin it.
            //   (b) may this click start a ROTATE DRAG?  Always. The off-gizmo
            //       gesture is an arcball centred on the pivot's screen
            //       projection (tools.transform.arcball), and a pinned mode has
            //       a perfectly good pivot to centre it on.
            //
            // (b) used to be answered by (a)'s predicate, so under every pinned
            // mode a press away from the rings returned false and the tool never
            // engaged: no drag, no rotation, nothing, while the command that set
            // the mode reported success. In the relocate modes it engaged only
            // far enough to MOVE the pivot and then also did nothing.
            //
            // The two behaviours those modes show are one gesture: a relocate
            // puts the pivot under the press, which is the arcball's trackball
            // limit, and a pinned pivot leaves the press hundreds of pixels out,
            // which is its rim limit. Same ball, same radius, same solve.
            //
            // Element keeps the old answer to (b): there an off-gizmo click is
            // already spoken for — it PICKS the anchor element, in a wrapper
            // branch that runs after the bank dispatch — so claiming the press
            // here would strand the pick.
            immutable bool relocates = pressPlacesCenter();
            if (!relocates && acenClickPicksElement())
                return false;
            Vec3 hit;
            if (relocates) {
            if (!computeClickRelocateHit(e.x, e.y, hit, vts))
                return false;
            handler.setPosition(hit);
            centerManual = true;
            notifyAcenUserPlaced(hit);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            lastClickWasRelocate = true;
            }
            lastClickWasOffGizmo = true;
            // Centre the ball on the pivot AS IT NOW STANDS — after any
            // relocate, so a relocate genuinely presses at the centre. A pivot
            // that does not project (behind the eye, outside the frustum) has
            // no ball to draw and no gesture: the relocate still happened, the
            // drag does not start.
            float ndcZ;
            if (!projectToWindowFull(handler.center, cachedVp,
                                     arcballCx, arcballCy, ndcZ))
                return true;
            arcballDrag  = true;
            arcballPressX = cast(float)e.x;
            arcballPressY = cast(float)e.y;
            // The arcball rotates about an ARBITRARY world axis that moves with
            // the cursor, which is the view-ring's own contract (dragAxis == 3
            // publishes an axis alongside its angle) — so it arms as a view-ring
            // drag and falls through to the shared setup below.
            dragAxis = 3;
        }
        // A gizmo arc was grabbed (dragAxis >= 0), or the arcball just armed.
        lastMX = e.x; lastMY = e.y;
        totalAngle = 0;
        lastSnappedAngle = 0;

        // Freeze the input-projection basis for the gesture (= the current
        // idle basis = the frozen rendered orientation today). The view-ring
        // mouse-up decomposition reads it instead of the rendered handler.
        currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);

        // Cache the axis vector for the duration of this drag — basis-
        // aware (workplane axis1/normal/axis2 when non-auto).
        if (dragAxis == 3) {
            viewDragAxis = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
            dragAxisVec = viewDragAxis;
        } else {
            // Principal ring: the rotation axis is the frozen INPUT basis
            // vector (== rendered `handler.axis*` at drag start today), so
            // the gesture plane stays fixed even once the rendered frame moves.
            dragAxisVec = dragAxis == 0 ? inputBasisX
                        : dragAxis == 1 ? inputBasisY
                                        : inputBasisZ;
        }

        // The arcball has no arc plane and no in-plane grab reference: its
        // fixed reference is the PRESS PIXEL, already stored. Zero the
        // plane-grab fields so nothing downstream reads a stale one, and skip
        // the ray/plane solve that would only find the pivot's own plane.
        // `dragStartDir` staying zero also suppresses the ring sector overlay,
        // which draws an arc this gesture does not have.
        if (arcballDrag) {
            prevWrapped   = 0;
            dragStartDir  = Vec3(0,0,0);
            dragRefDir    = Vec3(0,0,0);
            dragRefRadius = 0;
            return true;
        }

        // Compute drag start direction in the arc plane.
        Vec3 hit;
        prevWrapped = 0;
        Vec3 rotOrig771, rotDir771;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, rotOrig771, rotDir771);
        if (rayPlaneIntersect(rotOrig771, rotDir771,
                              handler.center, dragAxisVec, hit)) {
            Vec3 d = hit - handler.center;
            float draw = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
            dragStartDir = draw * 1.05f > 1e-6f ? d / (draw * 1.05f)
                                                : Vec3(0,0,0);
            // Fixed reference for the absolute-angle measurement (see fields).
            dragRefDir    = draw > 1e-6f ? d / draw : Vec3(0,0,0);
            dragRefRadius = draw;
        } else {
            dragStartDir  = Vec3(0,0,0);
            dragRefDir    = Vec3(0,0,0);
            dragRefRadius = 0;
        }
        return true;
    }

    // Wrapped-mode input-frame channel (gesture-frame unification, Phase 2) —
    // push the wrapper's unified gesture frame into the principal ring's frozen
    // drag axis. Called once per gesture from beginRotateDragSession (which runs
    // AFTER the sub-tool's onMouseButtonDown), so the rotation PLANE + the frozen
    // dragAxisVec follow the DISPLAYED rotated ring, not the un-chained world
    // frame. This is the rotate counterpart of the move/scale channel push, but
    // rotate freezes dragAxisVec/dragRefDir at button-down (the freeze-ordering
    // trap), so a bare channel write would be too late — it RE-DERIVES those
    // frozen fields here from the pushed frame. When chained, the pushed frame is
    // the wrapper's persisted gesture frame, so the plane is byte-identical to the
    // prior override.
    //
    // Principal axes (0/1/2) ONLY. The view-ring (dragAxis == 3) rotates about
    // the camera-forward axis (basis-independent) and decomposes onto the LIVE
    // inputBasis* on mouse-up — chaining it would mis-attribute the view rotation
    // onto the rotated principal slots. The wrapper's `chained` gate already
    // excludes it; this self-guards too. Note inputBasis* is NOT overwritten here
    // (unlike the former rechain), so the view-ring decompose stays on the live
    // basis (a principal gesture never reaches the view-ring sites — dragAxis is
    // fixed for the gesture — so dropping the overwrite is byte-stable).
    void setWrapperInputFrame(Vec3 r, Vec3 u, Vec3 f, bool chained) {
        wrapperInputFrameX     = r;
        wrapperInputFrameY     = u;
        wrapperInputFrameZ     = f;
        wrapperInputFrameValid = chained;
        if (!chained || dragAxis < 0 || dragAxis > 2) return;   // principal rings only
        debug assertWrapperInputFrameChained();
        dragAxisVec = dragAxis == 0 ? r
                    : dragAxis == 1 ? u
                                    : f;
        // Re-derive the fixed grab reference in the NEW arc plane, from the same
        // grab pixel onMouseButtonDown stored (lastMX/lastMY) against the same
        // cachedVp — so dragRefDir / dragStartDir / dragRefRadius all describe the
        // rotated ring's plane, matching dragAxisVec.
        prevWrapped = 0;
        Vec3 hit;
        Vec3 rotOrig824, rotDir824;
        screenPointToRay(cast(float)lastMX, cast(float)lastMY, cachedVp, rotOrig824, rotDir824);
        if (rayPlaneIntersect(rotOrig824, rotDir824,
                              handler.center, dragAxisVec, hit)) {
            Vec3 d = hit - handler.center;
            float draw = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
            dragStartDir = draw * 1.05f > 1e-6f ? d / (draw * 1.05f)
                                                : Vec3(0,0,0);
            dragRefDir    = draw > 1e-6f ? d / draw : Vec3(0,0,0);
            dragRefRadius = draw;
        } else {
            dragStartDir  = Vec3(0,0,0);
            dragRefDir    = Vec3(0,0,0);
            dragRefRadius = 0;
        }
    }

    // DEBUG-only — input-side parity guard (gesture-frame unification, Phase 2).
    // The pushed channel must carry the wrapper's unified `frame` (an orthonormal
    // triple, asserted on the wrapper side at population). Compiled out of release.
    debug void assertWrapperInputFrameChained() const {
        import std.math : abs;
        if (!wrapperInputFrameValid) return;
        enum float tol = 1e-3f;
        assert(abs(wrapperInputFrameX.length - 1.0f) < tol,
               "rotate wrapperInputFrameX not unit length");
        assert(abs(wrapperInputFrameY.length - 1.0f) < tol,
               "rotate wrapperInputFrameY not unit length");
        assert(abs(wrapperInputFrameZ.length - 1.0f) < tol,
               "rotate wrapperInputFrameZ not unit length");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameY)) < tol,
               "rotate wrapperInputFrame X·Y not orthogonal");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameZ)) < tol,
               "rotate wrapperInputFrame X·Z not orthogonal");
        assert(abs(dot(wrapperInputFrameY, wrapperInputFrameZ)) < tol,
               "rotate wrapperInputFrame Y·Z not orthogonal");
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
        // Geometry, cumulative matrix truth, display Euler and upload are all
        // finalized by the owner after this input bank closes the gesture.
        arcballDrag   = false;

        dragAxis   = -1;
        totalAngle = 0;
        // Drop the snap overlay so it doesn't linger after the drag.
        // (No-op when the live-preview already cleared it.)
        lastSnap = SnapResult.init;
        clearLastSnap();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (dragAxis == -1) {
            // Live snap preview during idle hover — same convention as
            // MoveTool. hitTestAxes >= 0 means cursor is over an arc
            // (would start a rotate drag, not a relocate), so the
            // preview suppresses itself there.
            updateLiveSnapPreview(e.x, e.y, hitTestAxes(e.x, e.y), vts);
            return false;
        }

        Vec3 center = handler.center;

        // The off-gizmo gesture: read the ball, not an arc plane. Both pixels
        // are offsets from the ball's centre — the pivot's screen projection,
        // frozen at the press so the gesture cannot chase its own result — and
        // the rotation is re-derived from the PRESS every frame, so it is
        // absolute, path-independent and exactly reversible.
        //
        // `viewDragAxis` is overwritten each frame because the arcball's axis
        // MOVES with the cursor (that is the trackball half of it). The mouse-up
        // decomposition onto the panel's three slots reads the axis this leaves
        // behind, which is the gesture's final axis — the right one to attribute
        // the final angle to.
        if (arcballDrag) {
            Vec3 axisCam; float ang;
            if (!arcballRotation(arcballPressX - arcballCx,
                                 arcballPressY - arcballCy,
                                 cast(float)e.x - arcballCx,
                                 cast(float)e.y - arcballCy,
                                 ARCBALL_RADIUS_PX, axisCam, ang))
            { lastMX = e.x; lastMY = e.y; return true; }
            Vec3 axisW = arcballAxisToWorld(axisCam, cachedVp);
            dragAxisVec  = axisW;
            viewDragAxis = axisW;
            totalAngle   = ang;
            import std.math : round;
            enum float arcStep = PI / 12.0f;   // 15 deg, as every other ring
            lastSnappedAngle = round(totalAngle / arcStep) * arcStep;
            version(unittest) immutable bool arcCtrl = false;
            else immutable bool arcCtrl = (SDL_GetModState() & KMOD_CTRL) != 0;
            immutable float arcAngle = arcCtrl ? lastSnappedAngle : totalAngle;
            pendingRotateAxis     = 3;
            pendingRotateAngle    = arcAngle;
            pendingRotateViewAxis = axisW;
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // Absolute-angle drag: the gesture angle is measured each frame as the
        // signed angle from the FIXED grab reference (dragRefDir) to the cursor's
        // current point on the rotation plane — it is NOT integrated from
        // frame-to-frame deltas. The
        // old per-frame `atan2(prevDir, currDir)` accumulator was poisoned when
        // the plane went near edge-on: the ray-plane hit raced past the horizon,
        // the direction flipped ~180° in one frame, that ~π delta entered the
        // accumulator permanently, and the model "flew away". Here a degenerate
        // (off-plane / horizon-racing) frame is REJECTED and the last good angle
        // is held instead. `angle` below stays the per-frame increment so the
        // downstream snap / standalone-apply code is untouched.
        Vec3 rotOrigCurr, rotDirCurr;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, rotOrigCurr, rotDirCurr);
        Vec3 hitCurr;
        if (dragRefRadius < 1e-6f ||
            !rayPlaneIntersect(rotOrigCurr, rotDirCurr, center, dragAxisVec, hitCurr))
        { lastMX = e.x; lastMY = e.y; return true; }

        Vec3 d2 = hitCurr - center;
        float l2 = sqrt(d2.x*d2.x + d2.y*d2.y + d2.z*d2.z);
        // Grazing guard: near edge-on the hit shoots toward the horizon
        // (l2 ≫ grab radius). Reject the frame rather than feed the singularity
        // into the angle.
        enum float grazeFactor = 64.0f;
        if (l2 < 1e-6f || l2 > grazeFactor * dragRefRadius)
        { lastMX = e.x; lastMY = e.y; return true; }
        d2 = d2 / l2;

        // Signed wrapped angle [-π, π] from the fixed reference to the current dir.
        Vec3  cr       = cross(dragRefDir, d2);
        float aWrapped = atan2(dot(cr, dragAxisVec), dot(dragRefDir, d2));
        // Unwrap into a continuous total via the minimal signed step from the
        // previous frame's wrapped value (handles passing through ±π).
        float angle = aWrapped - prevWrapped;
        if (angle >  PI) angle -= 2.0f * PI;
        if (angle < -PI) angle += 2.0f * PI;
        prevWrapped = aWrapped;
        totalAngle += angle;

        bool ctrlHeld = (SDL_GetModState() & KMOD_CTRL) != 0;
        float effectiveAngle;
        if (ctrlHeld) {
            import std.math : round, PI;
            enum float step = PI / 12.0f; // 15°
            lastSnappedAngle = round(totalAngle / step) * step;
            effectiveAngle = lastSnappedAngle;
        } else {
            effectiveAngle = totalAngle;
            import std.math : round, PI;
            lastSnappedAngle = round(totalAngle / (PI / 12.0f)) * (PI / 12.0f);
        }

        if (dragAxis >= 0 && dragAxis <= 2) {
            // MS-3 (rotate single-source): the principal-axis ring is now a
            // GESTURE-SCALAR PRODUCER. Publish the ABSOLUTE accumulated angle
            // for the dragged ring; the unified wrapper drains it into its
            // `headlessRotate` and runs `applyTRS` (matrix bypass for the
            // whole-mesh fast path). NO geometry mutation here — the single
            // geometry-apply entry point is `XfrmTransformTool.applyTRS`.
            // (The legacy whole-mesh `gpuMatrix` and `applyAbsoluteFromOrigCpuOnly`
            // paths are owned by the wrapper now for these axes.)
            pendingRotateAxis  = dragAxis;
            pendingRotateAngle = effectiveAngle;
        } else if (dragAxis == 3) {
            // View-aligned ring: publish the absolute accumulated angle and
            // camera-forward axis. The owner folds them onto its gesture-start
            // matrix and performs the geometry update.
            pendingRotateAxis     = 3;
            pendingRotateAngle    = effectiveAngle;
            pendingRotateViewAxis = dragAxisVec;
        }

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    struct PanelInput {
        Vec3 degrees;
        bool active;
        bool done;
    }

    PanelInput drawInputProperties(Vec3 publishedDegrees) {
        Vec3 value = publishedDegrees;
        ImGui.DragFloat("X", &value.x, 0.1f, 0, 0, "%.2f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &value.y, 0.1f, 0, 0, "%.2f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &value.z, 0.1f, 0, 0, "%.2f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        return PanelInput(value, xActive || yActive || zActive,
                          xDone || yDone || zDone);
    }

private:
    void drawRotationSector(const ref Viewport vp) {
        import std.math : cos, sin, sqrt, abs, PI;

        Vec3 axisVec = dragAxisVec;
        Vec3 center = handler.center;

        float cx, cy, cndcZ;
        if (!projectToWindowFull(center, vp, cx, cy, cndcZ)) return;

        uint fillCol = dragAxis == 0 ? IM_COL32(220, 60,  60,  50)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60,  50)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220,  50)
                                     : IM_COL32(160, 160, 160,  50);
        uint lineCol = dragAxis == 0 ? IM_COL32(220, 60,  60, 200)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60, 200)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220, 200)
                                     : IM_COL32(180, 180, 180, 200);

        Vec3 rodrig(Vec3 p, float a) {
            return rotateAboutPivot(p, Vec3(0,0,0), axisVec, a);
        }

        ImDrawList* dl = ImGui.GetForegroundDrawList();

        float dispAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
        float aFrom = dispAngle < 0 ? dispAngle : 0.0f;
        float aTo   = dispAngle > 0 ? dispAngle : 0.0f;
        enum N = 32;
        dl.PathLineTo(ImVec2(cx, cy));
        bool sectorOk = true;
        for (int i = 0; i <= N; i++) {
            float a = aFrom + (aTo - aFrom) * i / N;
            Vec3 w = center + rodrig(dragStartDir, a) * cachedSize;
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { sectorOk = false; break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        if (sectorOk) dl.PathFillConvex(fillCol);
        else          dl.PathClear();

        for (int i = 0; i <= N; i++) {
            float a = dispAngle * i / N;
            Vec3 w = center + rodrig(dragStartDir, a) * cachedSize;
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { dl.PathClear(); break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        dl.PathStroke(lineCol, ImDrawFlags.None, 1.0f);

        float ssx, ssy, sex, sey, ndcZ;
        Vec3 startWorld = center + dragStartDir * cachedSize;
        Vec3 endWorld   = center + rodrig(dragStartDir, dispAngle) * cachedSize;
        if (projectToWindowFull(startWorld, vp, ssx, ssy, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(ssx, ssy), lineCol, 1.0f);
        if (projectToWindowFull(endWorld,   vp, sex, sey, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(sex, sey), lineCol, 1.0f);

        import std.format : format;
        float deg = dispAngle * 180.0f / PI;
        string label = format("%.1f°", deg);
        dl.AddText(ImVec2(cx + 8, cy - 20), IM_COL32(255, 255, 255, 220), label);
    }

    int hitTestAxes(int mx, int my) {
        SemicircleHandler[3] arcs = [handler.arcX, handler.arcY, handler.arcZ];
        foreach (i, arc; arcs)
            if (arc.hitTest(mx, my, cachedVp))
                return cast(int)i;
        if (handler.arcView.hitTest(mx, my, cachedVp))
            return 3;
        return -1;
    }
}
