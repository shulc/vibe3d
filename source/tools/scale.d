module tools.scale;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tools.transform;
import handler;
import eventlog : queryMouse;
import mesh;
import editmode;
import math;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt;

import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import falloff_render : drawFalloffOverlay;
import toolpipe.packets : FalloffPacket;
import params : Param;


// ---------------------------------------------------------------------------
// ScaleTool : TransformTool — shows ScaleHandler at selection/mesh center; scales
//             selected vertices along the dragged axis relative to the center.
// ---------------------------------------------------------------------------

class ScaleTool : TransformTool {
    ScaleHandler handler;

    // Single-source hover/capture arbiter for the scale gizmo handles
    // (arrows 0..2, centerDisk 3 uniform, plane circles 4..6). Replaces
    // the old force/block loop. Scale is special: during a drag NO handle
    // highlights (the animated scaleArrow is the feedback), so the draw
    // path calls toolHandles.suppress() while dragAxis >= 0 instead of
    // setHaul.
    ToolHandles toolHandles;

private:
    Vec3     scaleAccum     = Vec3(1, 1, 1);  // cumulative scale factor per axis since tool activated
    Vec3     dragScaleAccum = Vec3(1, 1, 1);  // scale within current drag (for yellow arrows)
    Vec3     propScale      = Vec3(1, 1, 1);  // persistent value shown in Tool Properties
    Vec3[]   activationVertices;              // mesh snapshot at tool activation (for props apply)
    Vec3     activationCenter;               // gizmo center at activation

    // Phase C.3: Tool Properties state at the start of the current edit
    // session, restored by hooks on undo of the matching MeshVertexEdit.
    Vec3   preEditScaleAccum;
    Vec3   preEditPropScale;

    // Numeric scale attrs (`xfrm.transform SX/SY/SZ`).
    // Driven via `tool.attr <toolId> SX <factor>` — used by the headless
    // apply path to scale verts about the ACEN center, weighted by the
    // active falloff stage. Default 1.0 (identity scale).
    Vec3   headlessScale = Vec3(1, 1, 1);

public:
    // ── scale single-source plumbing (mirrors RotateTool / MoveTool) ──
    // Gesture-scalar producer output. The principal-axis / uniform-disc /
    // plane-circle drag branches publish the ABSOLUTE within-drag per-axis
    // scale factor here (`dragScaleAccum`, reset to 1 at drag start) and
    // return WITHOUT mutating geometry; the unified wrapper drains it into
    // its `headlessScale` and runs `applyTRS`. `pendingScaleValid == false`
    // means "nothing pending" (idle / hover frames leave it untouched).
    bool pendingScaleValid = false;
    Vec3 pendingScale = Vec3(1, 1, 1);   // per-axis factor, absolute since drag start

    // Back-pointer to the unified `XfrmTransformTool`, wired at the
    // wrapper's `activate()`. Typed as the base class to avoid a
    // field-level circular import (mirrors `MoveTool` / `RotateTool`);
    // cast to `XfrmTransformTool` locally where needed. Null for a
    // standalone (unit-test) instance, which keeps the legacy kernel path.
    TransformTool wrapperRef;

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        handler = new ScaleHandler(Vec3(0, 0, 0));
        toolHandles = new ToolHandles();
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Scale"; }

    override void activate() {
        super.activate();
        scaleAccum = Vec3(1, 1, 1);
        propScale  = Vec3(1, 1, 1);
        activationVertices = mesh.vertices.dup;
        activationCenter   = handler.center;
        headlessScale = Vec3(1, 1, 1);
        // Reset the gesture-producer scratch on (re)activation.
        pendingScaleValid = false;
        pendingScale      = Vec3(1, 1, 1);
    }

    // `xfrm.transform` SX/SY/SZ surfaced for `tool.attr <id> SX 1.5`
    // / `tool.doApply` headless flows. Each is a per-axis scale factor
    // about the ACEN center, applied along the AXIS-stage basis.
    override Param[] params() {
        return [
            Param.float_("SX", "Scale X", &headlessScale.x, 1.0f),
            Param.float_("SY", "Scale Y", &headlessScale.y, 1.0f),
            Param.float_("SZ", "Scale Z", &headlessScale.z, 1.0f),
        ];
    }

    // Headless apply path. Drives applyScaleFromActivationCpuOnly with
    // scaleAccum = headlessScale and the activation snapshot pinned to
    // the current verts — same per-vertex falloff weighting + symmetry
    // mirror as interactive drag. Caller (ToolDoApplyCommand) wraps us
    // in a MeshSnapshot pair for undo.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;
        // Skip identity scale entirely — applyScaleFromActivationCpuOnly
        // would touch every vert pointlessly and a no-op apply is a
        // useful escape hatch for callers driving us scriptedly.
        if (headlessScale == Vec3(1, 1, 1)) return true;

        // Pull pivot from ACEN (interactive update() does this every
        // frame; headless never runs update()).
        cachedCenter     = queryActionCenter(vts);
        activationCenter = cachedCenter;
        handler.setPosition(cachedCenter);

        // Orient the handler basis from AXIS — applyScaleFromActivation
        // reads handler.axisX/Y/Z to scale along the right basis vectors
        // (auto workplane = world; local AXIS uses workplane axes).
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);
        handler.setOrientation(bX, bY, bZ);

        // Pin the activation snapshot to the current mesh — the inner
        // loop reads activationVertices[vi] as the pre-scale baseline,
        // so without this the very first headless apply per session
        // would scale relative to whatever was in mesh.vertices at
        // activate() time (typically a stale older mesh).
        activationVertices = mesh.vertices.dup;
        scaleAccum = headlessScale;
        applyScaleFromActivationCpuOnly(vts);
        return true;
    }

    // Phase 7.5h: tool-session boundary — bake pending edit into one
    // undo entry on tool switch.
    override void deactivate() {
        if (editIsOpen())
            commitEdit("Scale");
        toolHandles.clearHaul();
        super.deactivate();
    }

    override void update(ref VectorStack vts) {
        if (!active) return;

        // Selection / mesh cannot change during a drag — skip checks entirely.
        if (dragAxis >= 0) return;

        uint  currentHash   = computeSelectionHash();
        ulong currentMutVer = mesh.mutationVersion;
        bool selChanged = (currentHash   != lastSelectionHash);
        bool mutChanged = (currentMutVer != lastMutationVersion);

        if (selChanged || mutChanged) {
            // Phase 7.5h: close out any pending edit FIRST so this
            // session's drags + falloff tweaks land as one history
            // entry.
            if (editIsOpen() && selChanged)
                commitEdit("Scale");
            lastSelectionHash   = currentHash;
            lastMutationVersion = currentMutVer;
            vertexCacheDirty    = true;

            // Geometry-only change: per-edit hooks have already
            // restored scaleAccum / propScale. activationVertices stays
            // at the activate-time baseline — applying scaleAccum to
            // activationVertices around activationCenter always
            // reproduces current mesh state.

            // Selection change: zero accumulators and refresh
            // everything.
            if (selChanged) {
                scaleAccum         = Vec3(1, 1, 1);
                propScale          = Vec3(1, 1, 1);
                activationVertices = mesh.vertices.dup;
                centerManual       = false;
            }
        }

        // Phase 7.5h: live falloff change → re-apply with new weights.
        // Scale's existing applyScaleFromActivationCpuOnly rebuilds
        // verts from activationVertices using the captured dragFalloff;
        // trigger it on packet change.
        if (editIsOpen() && scaleAccum != Vec3(1, 1, 1)) {
            FalloffPacket live = currentFalloff(vts);
            if (!falloffPacketsEqual(live, dragFalloff)) {
                dragFalloff = live;
                buildVertexCacheIfNeeded();
                applyScaleFromActivationCpuOnly(vts);
                needsGpuUpdate = true;
            }
        }

        // Pull the gizmo center from the ACEN stage every frame: mode /
        // userPlaced changes don't bump the selection hash or mesh
        // mutation, so they would otherwise not propagate to the
        // visible gizmo. activationCenter (= scale pivot for the next
        // drag / prop-apply) tracks cachedCenter so a mid-tool ACEN
        // mode change reaches the next scale operation too.
        //
        // 7.5h: skip during an open edit — the active scale's pivot is
        // activationCenter (captured when the session began), and re-
        // pulling from ACEN here would drift it as the bbox-centroid
        // of the deformed selection moves under non-uniform per-vertex
        // weight.
        if (!editIsOpen()) {
            cachedCenter = queryActionCenter(vts);
            activationCenter = cachedCenter;
            handler.setPosition(cachedCenter);
        }
    }

    private void snapshotEditState() {
        preEditScaleAccum = scaleAccum;
        preEditPropScale  = propScale;
    }

    protected override void commitEdit(string label) {
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        Vec3 accBefore  = preEditScaleAccum;
        Vec3 propBefore = preEditPropScale;
        Vec3 accAfter   = scaleAccum;
        Vec3 propAfter  = propScale;
        cmd.setHooks(
            () { scaleAccum = accAfter;  propScale = propAfter;  },
            () { scaleAccum = accBefore; propScale = propBefore; }
        );
        history.record(cmd);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
    {
        if (!active) return;
        cachedVp = vp;

        // Orient gizmo into the active workplane basis.
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);
        handler.setOrientation(bX, bY, bZ);

        // Flush pending partial-selection GPU upload once per frame.
        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        // Single-source hover/capture: register the scale handles in
        // hitTestAxes priority order (disc, plane circles, then arrows) so
        // the highlighted handle is the one a click grabs. During a drag the
        // animated scale arrow is the feedback, so suppress ALL handle
        // highlight (matches the old "block every handle while dragAxis>=0").
        toolHandles.begin();
        toolHandles.add(handler.centerDisk, 3);
        toolHandles.add(handler.circleXY,   4);
        toolHandles.add(handler.circleYZ,   5);
        toolHandles.add(handler.circleXZ,   6);
        toolHandles.add(handler.arrowX,     0);
        toolHandles.add(handler.arrowY,     1);
        toolHandles.add(handler.arrowZ,     2);
        if (dragAxis >= 0) toolHandles.suppress();
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.draw(shader, vp);

        // Cyan element + yellow cursor marker for the active snap
        // candidate. Populated by updateLiveSnapPreview(, vts) during idle
        // hover (click-outside-relocate hint).
        drawSnapOverlay(lastSnap, vp, *mesh);
        FalloffPacket fp = dragAxis >= 0 ? dragFalloff : currentFalloff(vts);
        drawFalloffOverlay(fp, vp);
        if (fp.enabled) {
            ensureFalloffGizmo();
            falloffGizmo.draw(shader, vp, fp);
        }
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        if (SDL_GetModState() & (KMOD_ALT | KMOD_SHIFT)) return false;
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
        FalloffPacket curFp = currentFalloff(vts);
        if (falloffGizmo !is null
         && falloffGizmo.onMouseButtonDown(e, cachedVp, curFp))
            return true;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            lastMX = e.x; lastMY = e.y;
            dragScaleAccum = Vec3(1, 1, 1);

            buildVertexCacheIfNeeded();
            // Capture falloff/symmetry so the standalone (no-wrapper)
            // fast-path predicate below is meaningful; the unified path
            // re-captures these in XfrmTransformTool.beginScaleDragSession.
            // Phase 7.6d: symmetry mirror breaks the single-uniform scale
            // gpuMatrix fast path the same way falloff does.
            bool falloffActive = captureFalloffForDrag(vts);
            bool symmActive    = captureSymmetryForDrag(vts);
            wholeMeshDrag = !falloffActive && !symmActive
                && (vertexProcessCount == cast(int)mesh.vertices.length);
            snapshotEditState();   // capture pre-drag Tool-Properties state.
            beginEdit();           // Phase C.3: snapshot pre-drag positions for undo.
            return true;
        }

        // Click outside gizmo: relocate ACEN to the click projected
        // onto the per-mode plane (most-facing world plane through
        // origin for Auto/None; camera-perpendicular through selection
        // center for Screen). Other ACEN modes keep the gizmo pinned
        // and ignore the click.
        if (!acenAllowsClickRelocate())
            return false;
        Vec3 hit;
        if (!computeClickRelocateHit(e.x, e.y, hit, vts))
            return false;
        // Phase 7.5h: relocating to a new pivot is a new logical tool
        // session — bake the prior session into one undo entry first,
        // then capture a fresh baseline at the new pivot.
        if (editIsOpen())
            commitEdit("Scale");
        handler.setPosition(hit);
        centerManual = true;
        notifyAcenUserPlaced(hit);
        activationVertices = mesh.vertices.dup;
        activationCenter   = hit;
        scaleAccum         = Vec3(1, 1, 1);
        propScale          = Vec3(1, 1, 1);
        return false;  // don't start a drag
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (falloffGizmo !is null && falloffGizmo.onMouseButtonUp(e))
            return true;
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
        wholeMeshDrag = false;

        dragAxis = -1;
        toolHandles.clearHaul();
        propScale = scaleAccum;
        // Phase 7.5h: don't reset activationVertices / activationCenter
        // here. The invariant is `mesh == scaleAlongBasis(activationVertices,
        // activationCenter, ..., scaleAccum)`; resetting the baseline
        // while leaving scaleAccum non-identity breaks it (next slider
        // edit / falloff re-apply would compound scaleAccum onto an
        // already-scaled baseline). Baseline lives until the session
        // closes at deactivate / selection change / new tool session.
        // Drop the snap overlay so it doesn't linger after the drag.
        lastSnap = SnapResult.init;
        clearLastSnap();
        // 7.5h: don't commit at mouseUp — keep edit open so mid-tool
        // falloff changes / further drags re-apply onto the same
        // activationVertices baseline.
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (falloffGizmo !is null && falloffGizmo.isDragging())
            return falloffGizmo.onMouseMotion(e, cachedVp);
        if (dragAxis == -1) {
            // Live snap preview during idle hover — same convention as
            // Move/Rotate. hitTestAxes >= 0 = on a scale handle
            // (would start a drag), so the preview suppresses itself.
            updateLiveSnapPreview(e.x, e.y, hitTestAxes(e.x, e.y), vts);
            return false;
        }

        Vec3 center = handler.center;

        if (dragAxis == 3) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            float dx = cast(float)(e.x - lastMX);
            float scaleFactor = 1.0f + dx / gizmoScreenPx;
            float minAccum = scaleAccum.x < scaleAccum.y ? scaleAccum.x : scaleAccum.y;
            if (scaleAccum.z < minAccum) minAccum = scaleAccum.z;
            if (minAccum * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.x *= scaleFactor; scaleAccum.y *= scaleFactor; scaleAccum.z *= scaleFactor;
            dragScaleAccum.x *= scaleFactor; dragScaleAccum.y *= scaleFactor; dragScaleAccum.z *= scaleFactor;
            publishScaleGesture();
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        if (dragAxis >= 4) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            float dx = cast(float)(e.x - lastMX);
            float scaleFactor = 1.0f + dx / gizmoScreenPx;
            bool scaleX = (dragAxis == 4 || dragAxis == 6);
            bool scaleY = (dragAxis == 4 || dragAxis == 5);
            bool scaleZ = (dragAxis == 5 || dragAxis == 6);
            if (scaleX) { if (scaleAccum.x * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleY) { if (scaleAccum.y * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleZ) { if (scaleAccum.z * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleX) { scaleAccum.x *= scaleFactor; dragScaleAccum.x *= scaleFactor; }
            if (scaleY) { scaleAccum.y *= scaleFactor; dragScaleAccum.y *= scaleFactor; }
            if (scaleZ) { scaleAccum.z *= scaleFactor; dragScaleAccum.z *= scaleFactor; }
            publishScaleGesture();
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        Vec3 axis = dragAxis == 0 ? handler.axisX
                  : dragAxis == 1 ? handler.axisY
                                  : handler.axisZ;

        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(center + axis, cachedVp, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx = ax_ - cx, sdy = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        float delta       = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
        float scaleFactor = 1.0f + delta;
        bool  axX = (dragAxis == 0), axY = (dragAxis == 1), axZ = (dragAxis == 2);
        if (axX) { if (scaleAccum.x * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.x *= scaleFactor; dragScaleAccum.x *= scaleFactor; }
        if (axY) { if (scaleAccum.y * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.y *= scaleFactor; dragScaleAccum.y *= scaleFactor; }
        if (axZ) { if (scaleAccum.z * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.z *= scaleFactor; dragScaleAccum.z *= scaleFactor; }
        publishScaleGesture();

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    // Gesture-scalar producer (scale single-source). Publishes the
    // ABSOLUTE within-drag per-axis scale factor (`dragScaleAccum`,
    // reset to 1 at drag start) for the unified wrapper to drain into
    // its `headlessScale` and feed `applyTRS`. Every gizmo drag mode
    // (single-axis arrow 0/1/2, uniform centre disc 3, plane circle
    // 4/5/6) maps onto the same Vec3 of per-axis factors, so — unlike
    // rotate's view-ring — there is no interactive-only exemption: ALL
    // scale drags route through here. NO geometry mutation; the single
    // geometry-apply entry point is `XfrmTransformTool.applyTRS`.
    private void publishScaleGesture() {
        pendingScale      = dragScaleAccum;
        pendingScaleValid = true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Scale            R");
        if (active)
            ImGui.PopStyleColor();
        return clicked;
    }

    override void drawProperties() {
        if (dragAxis >= 0) propScale = scaleAccum;
        ImGui.DragFloat("X", &propScale.x, 0.01f, 0.0f, float.max, "%.4f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propScale.y, 0.01f, 0.0f, float.max, "%.4f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propScale.z, 0.01f, 0.0f, float.max, "%.4f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        bool anyActive = xActive || yActive || zActive;
        bool anyDone   = xDone   || yDone   || zDone;
        if (!(anyActive || anyDone)) return;

        // Clamp and update scaleAccum from propScale.
        if (xActive || xDone) { if (propScale.x < 0) propScale.x = 0; scaleAccum.x = propScale.x; }
        if (yActive || yDone) { if (propScale.y < 0) propScale.y = 0; scaleAccum.y = propScale.y; }
        if (zActive || zDone) { if (propScale.z < 0) propScale.z = 0; scaleAccum.z = propScale.z; }

        buildVertexCacheIfNeeded();
        // Phase 7.5: re-capture falloff per active frame; per-vertex
        // weight breaks the wholeMesh GPU bypass fast path.
        // drawProperties() doesn't have a dispatcher-built vts —
        // construct one locally for the falloff/symmetry re-capture.
        import toolpipe.packets : SubjectPacket;
        SubjectPacket propSubj;
        VectorStack propVts;
        buildLocalVts(propSubj, propVts);
        bool falloffActive = captureFalloffForDrag(propVts);
        bool symmActive    = captureSymmetryForDrag(propVts);
        bool wholeMesh = !falloffActive && !symmActive
            && (vertexProcessCount == cast(int)mesh.vertices.length);

        // Phase C.3: snapshot pre-drag state on the FIRST active frame
        // only (before beginEdit() opens the session); subsequent frames
        // are no-ops on both calls.
        if (anyActive && !editIsOpen()) {
            snapshotEditState();
            beginEdit();
        } else if (anyActive) {
            beginEdit();   // idempotent
        }

        // Update CPU vertices from activationVertices (fast, no GPU).
        applyScaleFromActivationCpuOnly(propVts);

        if (anyActive) {
            if (wholeMesh) {
                // Whole-mesh: GPU bypass — upload base once at drag start, then only update matrix.
                if (!propsDragging) {
                    uploadPropsBase(activationVertices);
                    propsDragging = true;
                }
                gpuMatrix = pivotScaleMatrixBasis(activationCenter,
                    handler.axisX, handler.axisY, handler.axisZ,
                    scaleAccum.x, scaleAccum.y, scaleAccum.z);
            } else {
                // Partial selection: deferred GPU upload in draw().
                needsGpuUpdate = true;
            }
        } else {
            // Drag ended: commit final CPU state to GPU. 7.5h: don't
            // commit the edit here — props sliders are part of the
            // same tool session as gizmo drags.
            if (propsDragging) {
                gpu.upload(*mesh);
                gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
                propsDragging = false;
            } else {
                needsGpuUpdate = true;
            }
        }
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

    // Apply scale from activationVertices to CPU vertices only (no GPU).
    // Uses current scaleAccum for all three basis axes.
    // Phase 7.5: per-axis factor blended toward 1.0 by falloff weight,
    // evaluated at the activation-time vert position so the weight
    // doesn't drift as the slider scales the vert through the falloff
    // field.
    //
    // Single-source: the property-panel slider path and the kept-open-edit
    // falloff-reapply both reach geometry through here. It now DELEGATES to
    // the wrapper's `applyScaleAbsolute` → `applyTRS` so the "ui" (panel)
    // path shares the SAME single geometry-apply entry point as the
    // "handle" (drag) and "headless" (numeric) paths. The edit session +
    // undo display hooks stay on this sub-tool (no session migration → no
    // cross-instance commit), mirroring RotateTool.applyAbsoluteFromOrigCpuOnly.
    //
    // Standalone fallback (a bare ScaleTool with no wrapper — only unit-test
    // construction): the original `applyScaleFromActivation` kernel call,
    // numerically identical for the absolute scaleAccum apply.
    void applyScaleFromActivationCpuOnly(ref VectorStack vts) {
        if (wrapperRef !is null) {
            import tools.xfrm_transform : XfrmTransformTool;
            auto wrap = cast(XfrmTransformTool) wrapperRef;
            if (wrap !is null) {
                wrap.applyScaleAbsolute(activationVertices, scaleAccum);
                return;
            }
        }
        import tools.xform_kernels : applyScaleFromActivation;
        applyScaleFromActivation(mesh, vertexIndicesToProcess,
                                 activationVertices,
                                 activationCenter,
                                 handler.axisX, handler.axisY, handler.axisZ,
                                 scaleAccum,
                                 dragFalloff, cachedVp,
                                 queryClusterPivots(vts), queryClusterAxes(vts),
                                 dragSymmetry, toProcess);
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
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}
