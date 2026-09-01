module tools.create.box;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedBoxParamEffect, PreparedSessionActivateEffect,
    PreparedActivateKind;
import prepared_private_state : PreparedPrivateStateOwner;
import mesh_gpu : GpuCreateOwner;
import command_history : PreparedHistoryKind;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import edit_session : KeepAliveOnCancel;
import mesh;
import math;
import handler : MoveHandler, BoxHandler, getGizmoPixels, gizmoSize, ToolHandles;
import viewport_scheme : axisColor, schemeColor, SchemeColor;
import eventlog : queryMouse;
import drag;
import shader : Shader, LitShader, drawLitPreview;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.gesture_payload : GesturePayload;
import snapshot : MeshSnapshot;
import tools.create.create_common : pickWorkplane, BuildPlane,
                              pickWorkplaneFrame, WorkplaneFrame,
                              currentWorkplaneFrame, mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              frameIsLeftHanded, reverseFaceWinding,
                              workplaneCursorPlaneHit;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import params : Param;
import view : View;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : abs, sqrt, sin, cos, PI;

// Task 0719 (T8) — the mesh GENERATORS (`BoxParams` plus the cuboid /
// rounded-cube / rounded-plane builders) moved to `mesh_ops/box_geom.d`;
// they read no tool state and make no GL call. Re-exported so the five
// modules and two test modules that `import tools.create.box;` keep
// resolving `BoxParams` / `buildCuboidParametric` unchanged.
public import mesh_ops.box_geom;


// ---------------------------------------------------------------------------
// BoxTool — two-drag 3-D cuboid creation
//
//   Drag 1  (LMB down → move → up)  : draw base rectangle on most-facing plane
//   Drag 2  (LMB down → move → up)  : extrude height along plane normal → cuboid
//   RMB / deactivate                 : cancel current operation
// ---------------------------------------------------------------------------

private enum BoxState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

private __gshared View gBoxLiveEditView;

// ---------------------------------------------------------------------------
// BoxTool does NOT extend tools.create.primitive_create_tool's PrimitiveCreateTool/
// HandledCreateTool/SizedRadialCreateTool!P hierarchy (evaluated and
// declined, task 0418; that base was introduced by task 0414 for cylinder/
// cone/capsule/torus/tube/sphere). The two share a family resemblance —
// same 5-stage state-shape naming (Idle/DrawingBase/BaseSet/DrawingHeight/
// HeightSet), same params_-as-single-source-of-truth convention, same
// preview/commit split, same snap-overlay + ToolHandles/MoveHandler.
// hitTest plumbing (0410) — but the mechanics diverge past the point where
// inheriting would be more than a handful of small helpers wearing a
// misleading "is-a":
//   - choosePlane() below signs planeNormal by camera side and writes
//     params_.axis as a side effect; the base's choosePlane is unsigned
//     and never touches params_. basePlaneOrigin (snap-relocatable, set
//     on the first click) has no counterpart in the base, which always
//     ray-plane-tests against a fixed local origin.
//   - the handle rig is edgeH[4] (in-plane edge midpoints, screenAxisDelta
//     drag) + heightH[2] (top/bottom faces, ray-plane-intersect drag) with
//     3-tier click priority and a snap query on EVERY handle type — not
//     the base's uniform sizeH[6] outward-axis rig (screenAxisDelta only,
//     no snap hook at all).
//   - preview/commit dispatches on state (buildBase vs. buildCuboid), and
//     buildBase() carries an ADDITIONAL planeNormal-signed reverse
//     (choosePlane's signed normal can itself produce a mirrored frame,
//     on top of the shared frameIsLeftHanded() check both this tool and
//     the base now run in applyFrameToMesh/applyFrameToMeshRange — task
//     0424 hoisted that shared check into create_common.d); the base's
//     buildInto()/applyFrameToMeshRange() do the shared check but have no
//     state to dispatch on and no signed-planeNormal builder to correct for.
//   - the per-drag live-undo ladder (recordInSession/BoxLiveEditCommand,
//     captureLiveDragStart/recordLiveDragEnd below) is unique to this
//     tool and predates/is orthogonal to the base's willCommit()/
//     commitEdit() single-commit-at-deactivate skeleton.
//   - see applyFrameToMesh()/applyFrameToMeshRange() below for the
//     frameIsLeftHanded()/reverseFaceWinding() winding correction, shared
//     with the base since task 0424.
// Only a handful of leaf-level helpers line up byte-for-byte with the base
// (the local<->world transforms, worldAxisIdxOf, the Idle-state snap-
// preview shape) — see task 0418 for the full field/method comparison.
// ---------------------------------------------------------------------------
class BoxTool : Tool, KeepAliveOnCancel {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*  gpu;
    LitShader litShader;

    Mesh    previewMesh;
    GpuMesh previewGpu;

    BoxState  state;

    // params_ is the single source of truth for all box geometry.
    // All drag handlers write into params_; rendering and handle positions
    // are derived from params_ on demand.
    BoxParams params_;

    // Ephemeral drag anchors — valid only during active drag phases:
    //   startPoint / currentPoint : valid during DrawingBase only.
    //   heightDragStart / baseAnchor : valid during DrawingHeight and heightH re-drag.
    //   hpOrigin / hpn : valid during DrawingHeight and heightH re-drag.
    Vec3    startPoint;
    Vec3    currentPoint;
    // Origin of the base construction plane. Defaults to the workplane origin
    // (0,0,0 in local frame), but when the FIRST corner snaps to a target the
    // plane relocates to that point — so the whole base is built coplanar with
    // the snapped vertex's face instead of straddling the origin-plane and the
    // face (which left the base drawn at the half-offset between them).
    Vec3    basePlaneOrigin;
    Vec3    hpn;
    Vec3    hpOrigin;        // plane origin for height ray-plane intersect (drag anchor)
    Vec3    heightDragStart; // world hit at second LMB press
    Vec3    baseAnchor;      // base centroid captured at DrawingHeight start

    // Sticky modifier captured at LMB-down: Ctrl held at click → uniform
    // cube drag (all three sizes equal). At first click, the click point
    // anchors the cube center; at second click, the existing center stays
    // and only the uniform extent updates.
    bool    dragUniform;

    // Plane frame chosen at first click — persistent through the whole
    // interaction. After the workplane refactor (step 2), tool internals
    // operate in the LOCAL workplane space — so planeNormal / Axis1 /
    // Axis2 are always the local-frame identity (Y / X / Z). They stay
    // here as fields so the existing writeSizeParam / sizeAlong /
    // axisColor helpers (which look at axis component magnitudes) keep
    // working unchanged. Conversion to world for rendering / hit-test
    // happens via `frame`.
    Vec3  planeNormal;
    Vec3  planeAxis1;
    Vec3  planeAxis2;
    /// Workplane local↔world transform captured at choosePlane(). All
    /// tool-internal Vec3 fields (startPoint, currentPoint, baseAnchor,
    /// hpOrigin, heightDragStart, params_.cen*) and previewMesh / commit
    /// mesh vertices live in this frame's local space; mesh upload
    /// transforms vertices through `frame.toWorld` immediately before
    /// uploading to GPU.
    WorkplaneFrame frame;

    Viewport cachedVp;

    // Last snap query — drives the cyan/yellow overlay during the
    // Idle state. Refreshed by onMouseMotion's hover preview and by
    // the first click that moves the construction-plane hit onto a
    // snap target.
    SnapResult lastSnap;

    // Move gizmo (axis-only, no plane circles)
    MoveHandler mover;
    int         moverDragAxis = -1;   // 0/1/2 = X/Y/Z, -1 = none
    int         moverLastMX, moverLastMY;

    // Edge midpoint handles (BaseSet only)
    // 0 = edge 0-1, 1 = edge 1-2, 2 = edge 2-3, 3 = edge 3-0
    BoxHandler[4] edgeH;
    int           edgeDragIdx    = -1;
    int           edgeLastMX, edgeLastMY;

    BoxHandler[2] heightH;           // [0] = bottom face, [1] = top face
    int           heightHDragIdx  = -1;  // -1 = none, 0/1 = which handle is dragging

    // Single-source hover/capture arbiter for edge handles + height handles
    // + mover. Registration order = click hit-test priority so the
    // highlighted handle is always the one a click would grab.
    ToolHandles   toolHandles;

    // Phase C-followup: undo plumbing. Pre-commit mesh state is captured
    // in deactivate() right before commitBase / commitCuboid mutates the
    // cage; post-state is captured immediately after, and one
    // MeshSessionEdit lands on history. Both nullable for legacy / tests.

    bool     liveRunActive;
    int      liveUndoDepth;
    BoxParams dragBeforeParams;
    BoxState  dragBeforeState;
    bool      dragBeforeValid;
    BoxParams paramBeforeParams;
    BoxState  paramBeforeState;
    bool      paramBeforeValid;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0,0,0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        // Seed colours only — both sets are re-coloured per frame from the
        // world axis they end up aligned with (updateEdgeHandlers /
        // updateHeightHandlers, via axisColorFor).
        foreach (i; 0 .. 4)
            edgeH[i] = new BoxHandler(Vec3(0,0,0), axisColor(0));
        foreach (i; 0 .. 2)
            heightH[i] = new BoxHandler(Vec3(0,0,0), schemeColor(SchemeColor.toolExtent));
        toolHandles = new ToolHandles();
    }

    void destroy() {
        mover.destroy();
        foreach (h; edgeH) h.destroy();
        foreach (h; heightH) h.destroy();
    }

    override string name() const { return "Box"; }

    override void activate() {
        state           = BoxState.Idle;
        moverDragAxis   = -1;
        edgeDragIdx     = -1;
        heightHDragIdx  = -1;
        clearLiveEditTracking();
        toolHandles.clearHaul();
        previewGpu.init();
    }

    /// Dormant atomic activation producer. GL names are allocated by their
    /// resource owner during preparation; the private reset and name transfer
    /// remain ordered exactly like the legacy body and are installed only by
    /// PreparedRecordContext after joint validation.
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context, GpuCreateOwner gpuOwner) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.Box, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedPrivateStateOwner.box(this);
        bool ok = stateOwner !is null && gpuOwner !is null &&
            gpuOwner.replacesLikeLegacyInit() &&
            gpuOwner.owns(&previewGpu) && context.preparePrivateState(stateOwner) &&
            context.prepareCreate(gpuOwner) && context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Box, ok);
    }

    final GpuMesh* preparedPreviewGpu() nothrow @nogc { return &previewGpu; }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }

    final void installPreparedPrivateActivation() nothrow @nogc {
        state = BoxState.Idle; moverDragAxis = edgeDragIdx = heightHDragIdx = -1;
        liveRunActive = false; liveUndoDepth = 0;
        dragBeforeValid = paramBeforeValid = false; toolHandles.clearHaul();
    }

    override void deactivate() {
        // Decide what (if anything) is going to be committed; capture the
        // pre-commit snapshot ONLY when we're about to mutate the cage,
        // so an empty Idle deactivate doesn't pollute the undo stack.
        bool willCommit = (state == BoxState.BaseSet)
                       || (state >= BoxState.DrawingHeight && abs(currentHeight()) > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == BoxState.BaseSet)
            commitBase();
        else if (state >= BoxState.DrawingHeight && abs(currentHeight()) > 1e-5f)
            commitCuboid();
        state = BoxState.Idle;
        previewGpu.destroy();

        if (willCommit) commitBoxEdit(pre);
        else clearLiveEditTracking();

        // Drop the snap overlay so it doesn't linger after deactivate.
        lastSnap = SnapResult.init;
        clearLastSnap();
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // Commit guard mirror: deactivate() commits exactly when `willCommit`
    // (:1918) is true. The compound guard is NOT `state != Idle` — a height
    // drag with sub-epsilon height (|currentHeight()| <= 1e-5) commits nothing
    // even though state != Idle, so it must report no uncommitted edit.
    public override bool hasUncommittedEdit() const {
        return (state == BoxState.BaseSet)
            || (state >= BoxState.DrawingHeight && abs(currentHeight()) > 1e-5f);
    }

    // KeepAliveOnCancel (task 0430, reference-measured — 0428 capture Q2 on
    // this very tool): the interactive-undo cancel (a ladder step or the
    // final wipe below) leaves the tool armed instead of dropping it; the
    // press after the wipe steps prior history. Unconditional `true` — no
    // `active` guard: EditSession consults this only by cast on the ACTIVE
    // tool (see PrimitiveCreateTool's identical note).
    public override bool survivesEditCancel() const { return true; }

    // Category B cancel — preview-only reset (the RMB body in
    // onMouseButtonDown). Box builds a separate previewMesh/previewGpu; the
    // scene mesh is never touched until commit, so dropping back to Idle
    // discards the whole live edit. The FIRST branch is the interactive
    // undo LADDER (task 0414): one recorded live step popped per press,
    // early return, session kept — everything else about it stays live, so
    // NO sanitization there. Only the fall-through wipe is a full cancel,
    // and with keep-alive (task 0430) the post-wipe state is lived-in
    // rather than a stop on the way to deactivate(), so it also sanitizes
    // the transient drag state back to fresh-armed.
    public override void cancelUncommittedEdit() {
        if (history !is null && liveRunActive && liveUndoDepth > 0) {
            if (history.undo())
                return;
        }
        state = BoxState.Idle;
        clearLiveEditTracking();
        resetTransientDragState();
    }

    // Resync after a committed undo/redo moved geometry beneath the active tool
    // (undo/redo migration P1). Box builds a SEPARATE previewMesh from `state`
    // each frame and caches no scene-mesh baseline, so nothing needs re-capture;
    // the only safe action is to drop a half-drawn primitive (an in-progress
    // draw can't survive an external topology change), so reset to Idle —
    // and, since keep-alive (task 0430) makes this a lived-in state on a
    // still-armed tool, sanitize the transient drag state too.
    public override void resyncSession() {
        if (liveRunActive) return;
        state = BoxState.Idle;
        resetTransientDragState();
    }

    // THE ONE TOOL IN THE TREE THAT WALKS ALL THREE RECORD MODES, which is why
    // it is group G1's flagship: `ReplaceRunTail` here, `InSession` in
    // `recordLiveEdit`, `Plain` on the branch below. The fork is on the tool's
    // OWN `liveRunActive` flag — not on `history.runOpen()` — and it has to
    // stay that way: `ensureLiveRun` calls `nextRun()`, which does NOT raise
    // `_runOpen`, so a mode derived from history state could never pick either
    // in-session arm (task 1905, D11's impossibility argument).
    private void commitBoxEdit(MeshSnapshot pre) {
        if (history is null || gestureFactory is null) return;
        if (!pre.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Box");
        if (liveRunActive)
            recordGestureEdit(cmd, GestureRecordMode.ReplaceRunTail);
        else
            recordGestureEdit(cmd, GestureRecordMode.Plain);
        clearLiveEditTracking();
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button == SDL_BUTTON_RIGHT && state != BoxState.Idle) {
            state = BoxState.Idle;
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt / Shift remain reserved for camera. Ctrl is consumed here as
        // "constrain drag to a uniform cube".
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        // Edge handle hit-test (BaseSet / HeightSet)
        if (state == BoxState.BaseSet || state == BoxState.HeightSet) {
            foreach (i, h; edgeH) {
                if (h.hitTest(e.x, e.y, cachedVp)) {
                    edgeDragIdx = cast(int)i;
                    edgeLastMX  = e.x;
                    edgeLastMY  = e.y;
                    captureLiveDragStart();
                    return true;
                }
            }
        }

        // Height handles (BaseSet / HeightSet) — priority over mover centerBox
        // BaseSet: only bottom [0]; HeightSet: both [0] and [1]
        int heightHHitIdx = -1;
        if (heightH[0].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 0;
        else if (state == BoxState.HeightSet && heightH[1].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 1;
        if ((state == BoxState.BaseSet || state == BoxState.HeightSet) && heightHHitIdx >= 0) {
            heightHDragIdx = heightHHitIdx;
            captureLiveDragStart();
            if (state == BoxState.BaseSet) {
                // Transition from BaseSet → DrawingHeight via bottom handle.
                // Zero out height in params_ (the plane-normal axis size) before
                // setting up the height plane so hpOrigin is at the correct position.
                writeSizeParam(planeNormal, 0.0f);
            }
            // Capture base anchor before setupHeightPlane (baseCentroid() is correct now).
            baseAnchor = baseCentroid();
            setupHeightPlane();
            Vec3 hhit;
            bool hhitOk = localCursorPlane(e.x, e.y, hpOrigin, hpn, hhit);
            if (heightHHitIdx == 1) {
                // Top handle: non-incremental drag; anchor so current height is preserved.
                heightDragStart = hhitOk
                    ? hhit - planeNormal * currentHeight()
                    : hpOrigin;
            } else {
                // Bottom handle: incremental drag; anchor at the current hit point.
                heightDragStart = hhitOk ? hhit : hpOrigin;
            }
            if (state == BoxState.BaseSet) {
                state = BoxState.DrawingHeight;
            }
            uploadCuboid();
            return true;
        }

        // Move gizmo hit-test only once the base is finalized
        if (state >= BoxState.BaseSet) {
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis  = hit;
                moverLastMX    = e.x;
                moverLastMY    = e.y;
                captureLiveDragStart();
                return true;
            }
        }

        if (state == BoxState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!localCursorPlane(e.x, e.y, Vec3(0,0,0), planeNormal, hit))
                return false;
            // Snap the click to the closest pipeline-enabled target.
            // hit is rewritten in place when a candidate falls within
            // the SnapStage's innerRange; lastSnap drives the overlay.
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
            startPoint   = hit;
            currentPoint = hit;
            // Relocate the base construction plane to the (possibly snapped)
            // first corner. If snap pulled the corner onto a face vertex, the
            // base now lies in that face's plane; with no snap this is just the
            // workplane hit, so the unsnapped path is unchanged.
            basePlaneOrigin = hit;
            // Ctrl at the first click jumps straight into a 3D uniform cube
            // (center = click point, drag = half-extent applied to all three
            // axes), skipping the BaseSet → DrawingHeight stage. Otherwise
            // fall through to the normal bbox-corner-to-corner drag.
            dragUniform = ctrlAtClick;
            // Seed params_ to a degenerate (size=0) cube at the click point
            // BEFORE uploadBase. Otherwise uploadBase reads stale defaults
            // (cen=0, size=1) and the preview flashes a unit cube at the
            // workplane origin — visible as an "offset cube" the first
            // frame after click whenever the workplane isn't auto/identity.
            if (dragUniform) syncParamsFromUniformDrag();
            else             syncParamsFromBaseDrag();
            state = BoxState.DrawingBase;
            uploadBase();
            return true;
        }

        if (state == BoxState.BaseSet) {
            captureLiveDragStart();
            // Ctrl at the second click keeps the existing cube center and
            // re-drives all three sizes from the cursor's distance to that
            // center (uniform half-extent). The flat base from the first
            // drag is replaced by a 3D cube.
            if (ctrlAtClick) {
                baseAnchor = boxCenter();
                Vec3 hit;
                if (!localCursorPlane(e.x, e.y, baseAnchor, planeNormal, hit))
                    return false;
                Vec3  d = hit - baseAnchor;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                params_.cenX = baseAnchor.x;
                params_.cenY = baseAnchor.y;
                params_.cenZ = baseAnchor.z;
                params_.sizeX = 2.0f * r;
                params_.sizeY = 2.0f * r;
                params_.sizeZ = 2.0f * r;
                dragUniform = true;
                state = BoxState.DrawingHeight;
                uploadCuboid();
                return true;
            }
            // Zero out height in params_ (the plane-normal axis size).
            writeSizeParam(planeNormal, 0.0f);
            setupHeightPlane();
            baseAnchor = baseCentroid();
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = BoxState.DrawingHeight;
            uploadCuboid();
            return true;
        }

        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        // A drag is ending — drop the snap overlay so the highlight doesn't
        // linger frozen at the last snapped point after the mouse is released.
        // It re-appears on the next hover (Idle preview) or drag.
        lastSnap = SnapResult.init;
        clearLastSnap();

        if (edgeDragIdx >= 0) {
            recordLiveDragEnd();
            edgeDragIdx = -1;
            toolHandles.clearHaul();
            return true;
        }
        if (moverDragAxis >= 0) {
            recordLiveDragEnd();
            moverDragAxis = -1;
            toolHandles.clearHaul();
            return true;
        }
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) {
            recordLiveDragEnd();
            heightHDragIdx = -1;
            toolHandles.clearHaul();
            return true;
        }

        if (state == BoxState.DrawingBase) {
            // Ctrl-uniform mode: the drag fully defined a 3D cube on its
            // own — reject only zero-extent drags, then jump straight to
            // the finalized state (skip BaseSet → DrawingHeight).
            if (dragUniform) {
                if (!(sizeAlong(planeAxis1) > 1e-5f)) {
                    state = BoxState.Idle;
                    return true;
                }
                state = BoxState.HeightSet;
                uploadCuboid();
                return true;
            }
            // Normal corner-to-corner flow: reject degenerate ellipses and
            // otherwise wait for the second drag.
            // Also rejects NaN (NaN comparisons are false, so !(s > 1e-5f) catches NaN).
            float s1 = sizeAlong(planeAxis1);
            float s2 = sizeAlong(planeAxis2);
            if (!(s1 > 1e-5f) || !(s2 > 1e-5f)) {
                state = BoxState.Idle;
                return true;
            }
            state = BoxState.BaseSet;
            uploadBase();
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            state = BoxState.HeightSet;
            recordLiveDragEnd();
            heightHDragIdx = -1;
            toolHandles.clearHaul();
            return true;
        }

        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // Idle-state live snap preview. Before any clicks, show the
        // cyan target where the first click would anchor the box.
        // Frame isn't captured until the first click — use the live
        // workplane frame, same one choosePlane() will lock onto.
        if (state == BoxState.Idle) {
            WorkplaneFrame f = pickWorkplaneFrame(cachedVp);
            Vec3 lEye = transformPoint(f.toLocal, cachedVp.eye);
            Vec3 lRay = transformDir  (f.toLocal, screenRay(e.x, e.y, cachedVp));
            // Plane normal in local frame is +Y by construction (the
            // workplane lies in local XZ).
            Vec3 hit;
            if (rayPlaneIntersect(lEye, lRay, Vec3(0, 0, 0), Vec3(0, 1, 0), hit)) {
                lastSnap = snapLocalHit(hit, f, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
            } else {
                lastSnap = SnapResult.init;
                clearLastSnap();
            }
        }
        if (edgeDragIdx >= 0) {
            // The handle pos lives in world (rendered via cachedVp); pass
            // the world version of the local axis we want to project the
            // drag onto. applyEdgeDelta receives a world-space delta and
            // converts to local via toLocalD before mutating params_.
            Vec3 moveAxisLocal = (edgeDragIdx == 0 || edgeDragIdx == 2) ? planeAxis2 : planeAxis1;
            Vec3 moveAxisWorld = toWorldD(moveAxisLocal);
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, edgeLastMX, edgeLastMY,
                                         edgeH[edgeDragIdx].pos, moveAxisWorld, cachedVp, skip);
            if (!skip) applyEdgeDelta(edgeDragIdx, delta);
            // Snap the moved face to the nearest target on its axis (the flip
            // inside applyEdgeDelta may have toggled edgeDragIdx, so re-read it).
            lastSnap = snapMovedEdge(edgeDragIdx, e.x, e.y);
            publishLastSnap(lastSnap);
            edgeLastMX = e.x;
            edgeLastMY = e.y;
            return true;
        }

        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip,
                                 frame.axis1, frame.normal, frame.axis2,
                                 frame.normal);
            if (!skip) applyMoverDelta(delta);
            lastSnap = snapMover(moverDragAxis, e.x, e.y);
            publishLastSnap(lastSnap);
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }

        // heightH drag in HeightSet (re-drag without changing state)
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) {
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, hpOrigin, hpn, hit))
            {
                if (heightHDragIdx == 1) {
                    // Top handle (non-incremental). Top follows cursor, base
                    // stays at baseAnchor. signedH < 0 ⇒ top crossed below
                    // base ⇒ cuboid flips. After flip the visual top handle
                    // is on baseAnchor's side (not where cursor is); swap
                    // to bottom-handle drag so the handle on the cursor
                    // side continues following.
                    float signedH = dot(hit - heightDragStart, planeNormal);
                    float newH    = abs(signedH);
                    Vec3 newCen   = baseAnchor + planeNormal * (signedH * 0.5f);
                    params_.cenX = newCen.x;
                    params_.cenY = newCen.y;
                    params_.cenZ = newCen.z;
                    writeSizeParam(planeNormal, newH);
                    if (signedH < 0.0f) {
                        // After flip: baseAnchor is now the upper face.
                        // Switch to bottom-handle mode: incremental delta
                        // anchored at the current hit. baseAnchor stays.
                        heightHDragIdx = 0;
                        heightDragStart = hit;
                        hpOrigin = baseAnchor + planeNormal * (signedH); // = newBase
                    }
                } else {
                    // Bottom handle (incremental). Base follows cursor, top
                    // stays. signedH = oldH - delta < 0 ⇒ base crosses top
                    // ⇒ cuboid flips; same swap logic as top handle.
                    float delta = dot(hit - heightDragStart, planeNormal);
                    float oldH  = currentHeight();
                    float signedH = oldH - delta;
                    float newH    = abs(signedH);
                    Vec3 cenDelta = planeNormal * (delta * 0.5f);
                    params_.cenX += cenDelta.x;
                    params_.cenY += cenDelta.y;
                    params_.cenZ += cenDelta.z;
                    writeSizeParam(planeNormal, newH);
                    hpOrigin     += planeNormal * delta;
                    heightDragStart = hit; // incremental: advance anchor
                    if (signedH < 0.0f) {
                        // After flip: roles swap. Switch to top-handle mode.
                        // Re-anchor: top handle is non-incremental; set
                        // baseAnchor to the current top (formerly base) and
                        // heightDragStart so projection gives current height.
                        heightHDragIdx = 1;
                        baseAnchor = cenVec() - planeNormal * (newH * 0.5f);
                        heightDragStart = hit - planeNormal * newH;
                    }
                }
                uploadCuboid();
                // Snap the moved top/bottom face to a target on the normal axis
                // (heightHDragIdx may have flipped above, so re-read it).
                lastSnap = snapHeightFace(heightHDragIdx, e.x, e.y);
                publishLastSnap(lastSnap);
            }
            return true;
        }

        // Hover highlight is owned by the ToolHandles arbiter (resolved in
        // draw() from the live mouse position), so no per-motion hover
        // bookkeeping is needed here.

        if (state == BoxState.DrawingBase) {
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, basePlaneOrigin, planeNormal, hit))
            {
                // Snap the dragged base-corner to the closest snap
                // target. Falls through to raw `hit` when no snap fires.
                Vec3 hitRaw = hit;
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                // Free-axis projection: the base corner has 2 DOF (the two
                // in-plane axes), so adopt the snap target's in-plane coords
                // but keep the plane-normal coord on the base plane — an edge
                // snap must not drag the base off its plane. Matches as many
                // of the snap point's coords as the base drag allows.
                if (lastSnap.snapped)
                    hit -= planeNormal * dot(hit - hitRaw, planeNormal);
                currentPoint = hit;
                if (dragUniform) syncParamsFromUniformDrag();
                else             syncParamsFromBaseDrag();
                uploadBase();
            }
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            // Ctrl-uniform: project cursor onto the construction plane
            // through the cube center; cursor distance from baseAnchor
            // becomes the new uniform half-extent for all three sizes.
            // Center stays put.
            if (dragUniform) {
                Vec3 hit;
                if (localCursorPlane(e.x, e.y, baseAnchor, planeNormal, hit))
                {
                    // Snap the cursor's plane hit; cube radius then
                    // becomes the distance from baseAnchor to the
                    // snap target.
                    lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                             *mesh, EditMode.Vertices);
                    publishLastSnap(lastSnap);
                    Vec3  d = hit - baseAnchor;
                    float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                    params_.cenX = baseAnchor.x;
                    params_.cenY = baseAnchor.y;
                    params_.cenZ = baseAnchor.z;
                    params_.sizeX = 2.0f * r;
                    params_.sizeY = 2.0f * r;
                    params_.sizeZ = 2.0f * r;
                    uploadCuboid();
                }
                return true;
            }
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, hpOrigin, hpn, hit))
            {
                // Snap the height-drag hit too — useful for matching
                // box top/bottom to an existing vertex's height.
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                // Signed projection onto planeNormal — sign decides which side
                // of the base the cuboid grows on; size is always positive.
                // Free drag measures the delta from where the height drag was
                // grabbed (heightDragStart); a SNAP instead measures from the
                // base so the top face lands exactly on the snap target's
                // normal level (height aligns to the snapped axis), not merely
                // by the drag distance from the click point.
                float signedH = lastSnap.snapped
                    ? dot(hit - baseAnchor,      planeNormal)
                    : dot(hit - heightDragStart, planeNormal);
                float newH    = abs(signedH);
                Vec3 newCen   = baseAnchor + planeNormal * (signedH * 0.5f);
                params_.cenX = newCen.x;
                params_.cenY = newCen.y;
                params_.cenZ = newCen.z;
                writeSizeParam(planeNormal, newH);
                uploadCuboid();
            }
            return true;
        }

        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // Snap overlay renders even in Idle so the user sees the cyan
        // target before the first click anchors the box.
        drawSnapOverlay(lastSnap, vp, *mesh);
        if (state == BoxState.Idle) return;

        drawLitPreview(litShader, shader, vp, previewGpu);

        // Handles + move gizmo (BaseSet and above). Geometry is positioned
        // first; hover/capture is then resolved by the single-source
        // ToolHandles arbiter so highlight always matches what a click grabs.
        if (state >= BoxState.BaseSet) {
            updateEdgeHandlers(vp);
            updateHeightHandler(vp);
            mover.setPosition(toWorldP(boxCenter()));
            // Mover gizmo follows the workplane frame captured at first
            // click — keeps the arrows aligned with the cube's local axes
            // (frame.axis1, frame.normal, frame.axis2 in world).
            mover.setOrientation(frame.axis1, frame.normal, frame.axis2);

            // Register in click hit-test priority order (see
            // onMouseButtonDown): edge handles, then height handles
            // (heightH[1] only once a height exists), then the mover
            // (centerBox before arrows, mirroring moverHitTest). Distinct
            // part-id ranges keep groups from colliding:
            //   edges 0..3, heights 20/21, mover centerBox 13 / arrows 10/11/12.
            toolHandles.begin();
            foreach (i, h; edgeH) toolHandles.add(h, cast(int)i);
            toolHandles.add(heightH[0], 20);
            if (state >= BoxState.DrawingHeight)
                toolHandles.add(heightH[1], 21);
            toolHandles.add(mover.centerBox, 13);
            toolHandles.add(mover.arrowX,    10);
            toolHandles.add(mover.arrowY,    11);
            toolHandles.add(mover.arrowZ,    12);

            // Capture the active drag's part so it stays highlighted through
            // the drag. Mirrors the old force flags exactly: an edge drag
            // wins, then the mover, then the height handles — where a live
            // DrawingHeight always drives the top handle (heightH[1]).
            if      (edgeDragIdx >= 0)                 toolHandles.setHaul(edgeDragIdx);
            else if (moverDragAxis >= 0)              toolHandles.setHaul(10 + moverDragAxis);
            else if (state == BoxState.DrawingHeight) toolHandles.setHaul(21);
            else if (heightHDragIdx == 0)             toolHandles.setHaul(20);
            else if (heightHDragIdx == 1)             toolHandles.setHaul(21);
            else                                      toolHandles.setHaul(-1);

            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);

            foreach (h; edgeH) h.draw(shader, vp);
            heightH[0].draw(shader, vp);
            if (state >= BoxState.DrawingHeight)
                heightH[1].draw(shader, vp);
            mover.draw(shader, vp);
        }
    }

    /// Wire schema for prim.cube headless invocation.
    /// Phase 6.1a: 9 core attrs (position/size/segments).
    /// Phase 6.1b: 3 rounded-edge attrs (radius/segmentsR/axis).
    /// Phase 6.1c: sharp attr (enabled only when radius > 0 and segmentsR <= 3).
    override Param[] params() {
        import params : IntEnumEntry;
        if (state != BoxState.Idle) {
            paramBeforeParams = params_;
            paramBeforeState = state;
            paramBeforeValid = true;
        }
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Size X",     &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Size Y",     &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Size Z",     &params_.sizeZ, 1.0f).min(0.0f),
            Param.int_("segmentsX", "Segments X", &params_.segmentsX, 1).min(1).max(64).enforceBounds(),
            Param.int_("segmentsY", "Segments Y", &params_.segmentsY, 1).min(1).max(64).enforceBounds(),
            Param.int_("segmentsZ", "Segments Z", &params_.segmentsZ, 1).min(1).max(64).enforceBounds(),
            Param.float_("radius",    "Radius",          &params_.radius,    0.0f).min(0.0f),
            // segmentsR (task 0314 CRITICAL): the rounded-corner builder is
            // O(segmentsR^2) — unclamped, segmentsR:1000 allocates 8M+
            // verts / GB-scale RSS / hangs the main thread. `.enforceBounds()`
            // makes the already-declared `.min(1).max(64)` hint authoritative
            // on the headless JSON path too (previously UI-slider-only).
            Param.int_(  "segmentsR", "Radius Segments", &params_.segmentsR, 3  )
                .min(1).max(64).enforceBounds(),
            Param.bool_( "sharp",     "Sharp",           &params_.sharp,     false),
            // axis is auto-picked from the most-facing workplane normal
            // at choosePlane() time; hidden from the Property Panel but
            // retained in the schema for headless prim.cube parity tests
            // that set axis explicitly via JSON.
            Param.intEnum_("axis", "Axis", cast(int*)&params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1).hidden(),
        ];
    }

    final PreparedBoxParamEffect prepareParamChanged(PreparedRecordContext context,
                                                       string name) {
        bool accepted;
        bool nextRunActive = liveRunActive;
        int nextUndoDepth = liveUndoDepth;
        if (paramBeforeValid && context !is null && history !is null &&
            !sameLiveEdit(paramBeforeParams, paramBeforeState, params_, state)) {
            ulong runId = history.currentRunId;
            if (!nextRunActive) {
                runId = context.nextRun();
                nextRunActive = runId != 0;
                nextUndoDepth = 0;
            }
            if (nextRunActive) {
                auto cmd = new BoxLiveEditCommand(this, paramBeforeParams,
                    paramBeforeState, params_, state);
                accepted = context.prepare(cmd, PreparedHistoryKind.InSession,
                                           runId).accepted;
                if (accepted) ++nextUndoDepth;
            }
        }
        return PreparedBoxParamEffect(preparedToolStateOwner, accepted,
            nextRunActive, nextUndoDepth, false);
    }

    override void onParamChanged(string name) {
        if (paramBeforeValid) {
            recordLiveEdit(paramBeforeParams, paramBeforeState, params_, state);
            paramBeforeValid = false;
        }
    }

    /// Disable `sharp` when radius == 0 or segmentsR > 3 (no K-table entry).
    override bool paramEnabled(string name) const {
        if (name == "sharp")
            return params_.radius > 1e-9f && params_.segmentsR <= 3;
        return true;
    }

    /// Headless one-shot: append a cuboid built from params_ into the scene
    /// mesh. Called by ToolHeadlessCommand.apply(); the command wraps this
    /// with a snapshot pair for undo. GPU upload + cache refresh are handled
    /// by the caller. Append matches commitCuboid's interactive convention —
    /// scripted callers (Ctrl-click "Unit Box", etc.) expect existing
    /// geometry to survive.
    override bool applyHeadless() {
        // Headless prim.cube honours the active WorkplaneStage — params_
        // are interpreted in LOCAL workplane space (mirroring the
        // interactive commitCuboid path). Auto-mode falls back to identity
        // (world XZ) since there's no camera to drive the most-facing pick.
        //
        // buildCuboidParametric appends to `mesh` (existing geometry
        // survives — matches the interactive Append convention), so the
        // workplane transform must apply ONLY to the newly-emitted
        // vertices, not the pre-existing ones.
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        size_t firstNewFace = mesh.faces.length;
        buildCuboidParametric(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert, firstNewFace);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override void drawProperties() {
        if (state == BoxState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a base.");
        // Schema panel (property_panel.d) handles all param widgets.
    }

    /// Re-evaluate the preview from params_ after a schema slider change.
    /// Called by PropertyPanel immediately after onParamChanged().
    /// uploadPreview() picks uploadBase / uploadCuboid based on state and
    /// goes through applyFrameToMesh — same path as the interactive drag,
    /// so a slider tweak and a mouse-driven update produce identical
    /// previews in world space.
    override void evaluate() {
        if (state == BoxState.Idle) return;
        uploadPreview();
    }

private:
    void clearLiveEditTracking() {
        liveRunActive = false;
        liveUndoDepth = 0;
        dragBeforeValid = false;
        paramBeforeValid = false;
    }

    // Full-cancel sanitization (task 0430 D3) — called ONLY from the wipe
    // branch of cancelUncommittedEdit() and from resyncSession(), never
    // from the ladder branch (a peeled ladder step keeps its live session,
    // including any in-progress handle-drag arbitration). With keep-alive
    // the post-wipe state is lived-in, so it must equal fresh-armed
    // (activate()) for every interaction field; previewGpu is deliberately
    // NOT touched (draw() Idle-gates it, destroy stays in deactivate()).
    // The lastSnap drop mirrors deactivate()'s overlay drop so a cancelled
    // gesture's snap overlay doesn't linger on the armed tool.
    void resetTransientDragState() {
        moverDragAxis  = -1;
        edgeDragIdx    = -1;
        heightHDragIdx = -1;
        toolHandles.clearHaul();
        lastSnap = SnapResult.init;
        clearLastSnap();
    }

    void ensureLiveRun() {
        if (history is null) return;
        if (!liveRunActive) {
            history.nextRun();
            liveRunActive = true;
            liveUndoDepth = 0;
        }
    }

    bool sameLiveEdit(const ref BoxParams a, BoxState as,
                      const ref BoxParams b, BoxState bs) const {
        return as == bs && a == b;
    }

    // The FOURTH payload form: a parametric tool-state edit, built by
    // constructor from this tool's own fields — neither a snapshot pair nor a
    // vertex delta, and reachable from a factory closure by no spelling at
    // all. It is the reason the seam takes a FILLED command (task 1905, Б2).
    //
    // The `sameLiveEdit` early return stays AHEAD of `ensureLiveRun()` and is
    // not delegated to the recorder's belt: it also guards the run-opening and
    // the ladder counter, which the belt knows nothing about. The belt is a
    // second line behind it, and `BoxLiveEditCommand.hasGesturePayload()` is
    // the same comparison, so the two cannot disagree.
    void recordLiveEdit(BoxParams before, BoxState beforeState,
                        BoxParams after, BoxState afterState) {
        if (history is null) return;
        if (sameLiveEdit(before, beforeState, after, afterState)) return;
        ensureLiveRun();
        if (!liveRunActive) return;
        auto cmd = new BoxLiveEditCommand(this, before, beforeState, after, afterState);
        // The ladder counter follows the record: if the belt ever refused, an
        // unconditional `++` would leave `liveUndoDepth` one step ahead of the
        // stack and the interactive undo ladder would pop an entry that is not
        // there. Unreachable today (the guard above already returned), and
        // written this way so it stays unreachable rather than merely unlikely.
        if (recordGestureEdit(cmd, GestureRecordMode.InSession))
            ++liveUndoDepth;
    }

    void captureLiveDragStart() {
        dragBeforeParams = params_;
        dragBeforeState = state;
        dragBeforeValid = true;
    }

    void recordLiveDragEnd() {
        if (!dragBeforeValid) return;
        recordLiveEdit(dragBeforeParams, dragBeforeState, params_, state);
        dragBeforeValid = false;
    }

    void restoreLiveEdit(BoxParams p, BoxState s) {
        params_ = p;
        state = s;
        if (state == BoxState.Idle) {
            previewMesh.clear();
            previewGpu.upload(previewMesh);
            return;
        }
        uploadPreview();
    }

    void noteLiveHistoryApply() {
        if (liveRunActive)
            ++liveUndoDepth;
    }

    void noteLiveHistoryRevert() {
        if (liveRunActive && liveUndoDepth > 0)
            --liveUndoDepth;
    }

    // -----------------------------------------------------------------------
    // Helpers that derive geometry from params_ (single source of truth).
    // -----------------------------------------------------------------------

    // Box center == params_ center (always).
    Vec3 cenVec() const {
        return Vec3(params_.cenX, params_.cenY, params_.cenZ);
    }

    // Size stored in params_ along the given world axis (one of ±X/Y/Z).
    float sizeAlong(Vec3 axisVec) const {
        if (abs(axisVec.x) > 0.5f) return params_.sizeX;
        if (abs(axisVec.y) > 0.5f) return params_.sizeY;
        return params_.sizeZ;
    }

    // Height of the cuboid along planeNormal (params_.size for that axis).
    float currentHeight() const { return sizeAlong(planeNormal); }

    // Base centroid: center offset downward along planeNormal by half height.
    Vec3 baseCentroid() const {
        return cenVec() - planeNormal * (currentHeight() * 0.5f);
    }

    // Four corners of the base rectangle derived from params_.
    Vec3[4] computedBaseCorners() const {
        Vec3 bc  = baseCentroid();
        float s1 = sizeAlong(planeAxis1);
        float s2 = sizeAlong(planeAxis2);
        Vec3 a   = planeAxis1 * (s1 * 0.5f);
        Vec3 b   = planeAxis2 * (s2 * 0.5f);
        Vec3[4] c;
        c[0] = bc - a - b;
        c[1] = bc + a - b;
        c[2] = bc + a + b;
        c[3] = bc - a + b;
        return c;
    }

    // Write a magnitude into the params_ size field matching the given world axis.
    void writeSizeParam(Vec3 axisVec, float magnitude) {
        float v = abs(magnitude);
        if      (abs(axisVec.x) > 0.5f) params_.sizeX = v;
        else if (abs(axisVec.y) > 0.5f) params_.sizeY = v;
        else                             params_.sizeZ = v;
    }

    // Sync params_ from startPoint/currentPoint after a DrawingBase motion frame.
    // The plane-normal axis size is left at 0 (plane mode until height drag).
    void syncParamsFromBaseDrag() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        Vec3  cen = (startPoint + currentPoint) * 0.5f;
        params_.cenX = cen.x; params_.cenY = cen.y; params_.cenZ = cen.z;
        params_.sizeX = 0.0f; params_.sizeY = 0.0f; params_.sizeZ = 0.0f;
        writeSizeParam(planeAxis1, d1);
        writeSizeParam(planeAxis2, d2);
        // planeNormal axis intentionally stays 0 → plane mode.
    }

    // Ctrl-at-first-click shortcut: center stays at the click point and the
    // distance from start to current on the construction plane becomes the
    // half-extent for all three axes (full size = 2× drag length). The
    // resulting cube is volumetric from frame one — DrawingBase preview
    // immediately shows a 3D cuboid instead of a flat rectangle.
    void syncParamsFromUniformDrag() {
        Vec3  d = currentPoint - startPoint;
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        params_.sizeX = 2.0f * r;
        params_.sizeY = 2.0f * r;
        params_.sizeZ = 2.0f * r;
    }

    // -----------------------------------------------------------------------
    // Gizmo center.
    // -----------------------------------------------------------------------

    // mover sits at the box center = params_ center.
    Vec3 boxCenter() const { return cenVec(); }

    // -----------------------------------------------------------------------
    // Hit-test axis arrows (0/1/2) and centerBox (3).
    // -----------------------------------------------------------------------
    // Delegates to the shared MoveHandler.hitTest (task 0410, dedup 0407
    // §A.D5) — was a verbatim inline copy of the same 3=centerBox,
    // 0/1/2=arrowX/Y/Z, -1=miss test.
    int moverHitTest(int mx, int my) {
        return mover.hitTest(mx, my, cachedVp);
    }

    // Apply world-space delta to box by updating params_ center.
    // The mover gizmo lives in world (its arrows align with world XYZ),
    // so axisDragDelta returns a world-space vector. Project it into
    // the workplane local frame before adding to params_.
    void applyMoverDelta(Vec3 d) {
        Vec3 dl = toLocalD(d);
        params_.cenX += dl.x;
        params_.cenY += dl.y;
        params_.cenZ += dl.z;
        uploadPreview();
    }

    // Snap the moved box center onto the nearest snap target on the mover's
    // free axes (free-axis projection). Arrows 0/1/2 free a single axis;
    // the centerBox (3) frees the two axes spanning the most-camera-facing
    // plane (its locked axis matches planeDragDelta's most-facing pick).
    SnapResult snapMover(int axisIdx, int sx, int sy) {
        bool f1, fn, f2;
        if      (axisIdx == 0) f1 = true;
        else if (axisIdx == 1) fn = true;
        else if (axisIdx == 2) f2 = true;
        else {
            Vec3 cb = Vec3(cachedVp.view[2], cachedVp.view[6], cachedVp.view[10]);
            float a1 = abs(dot(cb, frame.axis1));
            float an = abs(dot(cb, frame.normal));
            float a2 = abs(dot(cb, frame.axis2));
            int lock = (a1 >= an && a1 >= a2) ? 0 : (an >= a1 && an >= a2) ? 1 : 2;
            f1 = lock != 0; fn = lock != 1; f2 = lock != 2;
        }
        Vec3 hitLocal = toLocalP(mover.center);
        auto sr = snapLocalHit(hitLocal, frame, sx, sy, cachedVp,
                                *mesh, EditMode.Vertices);
        if (sr.snapped) {
            Vec3 cen = cenVec();
            if (f1) cen = cen - planeAxis1 * dot(cen, planeAxis1)
                              + planeAxis1 * dot(hitLocal, planeAxis1);
            if (fn) cen = cen - planeNormal * dot(cen, planeNormal)
                              + planeNormal * dot(hitLocal, planeNormal);
            if (f2) cen = cen - planeAxis2 * dot(cen, planeAxis2)
                              + planeAxis2 * dot(hitLocal, planeAxis2);
            params_.cenX = cen.x; params_.cenY = cen.y; params_.cenZ = cen.z;
            uploadPreview();
        }
        return sr;
    }

    // Snap a height handle's moved face (idx 1 = top, idx 0 = bottom) onto the
    // nearest snap target along the plane normal — free-axis projection on the
    // single normal axis, with the opposite face held fixed. No-op without a
    // candidate near the cursor.
    SnapResult snapHeightFace(int idx, int sx, int sy) {
        Vec3 botL = baseCentroid();
        Vec3 topL = botL + planeNormal * currentHeight();
        Vec3 movedL = (idx == 1) ? topL : botL;
        Vec3 oppL   = (idx == 1) ? botL : topL;
        Vec3 hitLocal = movedL;
        auto sr = snapLocalHit(hitLocal, frame, sx, sy, cachedVp,
                                *mesh, EditMode.Vertices);
        if (sr.snapped) {
            float t = dot(hitLocal, planeNormal);   // snap target normal coord
            float o = dot(oppL, planeNormal);       // held opposite face
            Vec3  cen = cenVec();
            cen = cen - planeNormal * dot(cen, planeNormal)
                      + planeNormal * ((t + o) * 0.5f);
            params_.cenX = cen.x; params_.cenY = cen.y; params_.cenZ = cen.z;
            writeSizeParam(planeNormal, abs(t - o));
            uploadCuboid();
        }
        return sr;
    }

    // Color by world axis direction — resolved from the viewport scheme, not
    // from literals. Named `axisColorFor` so it does not shadow the scheme's
    // own index-keyed `axisColor` imported above.
    static Vec3 axisColorFor(Vec3 axis) {
        if (abs(axis.x) > 0.5f) return axisColor(0);
        if (abs(axis.y) > 0.5f) return axisColor(1);
        return axisColor(2);
    }

    // Update height handles — positions derived from params_.
    // [0] = base centroid (bottom face center).
    // [1] = base centroid + planeNormal * currentHeight() (top face center).
    // Positions are computed in LOCAL space then transformed to world for
    // rendering / hit-test against the live viewport.
    void updateHeightHandler(const ref Viewport vp) {
        Vec3 botL = baseCentroid();
        Vec3 topL = botL + planeNormal * currentHeight();
        Vec3 botW = toWorldP(botL);
        Vec3 topW = toWorldP(topL);
        Vec3[2] pts = [botW, topW];
        Vec3 colorAxis = toWorldD(planeNormal);
        foreach (i; 0 .. 2) {
            heightH[i].pos   = pts[i];
            heightH[i].size  = gizmoSize(pts[i], vp, 0.04f);
            heightH[i].color = axisColorFor(colorAxis);
        }
    }

    // Update edge handler positions — derived from computedBaseCorners().
    // BaseSet: midpoints of base edges.
    // DrawingHeight/HeightSet: centers of the 4 side faces (midpoint + halfH).
    void updateEdgeHandlers(const ref Viewport vp) {
        Vec3[4] corners = computedBaseCorners();   // local
        Vec3 halfH = (state >= BoxState.DrawingHeight)
            ? planeNormal * (currentHeight() * 0.5f)
            : Vec3(0, 0, 0);

        static immutable int[4][4] edgePairs = [[0,1],[1,2],[2,3],[3,0]];
        Vec3[4] mids;
        foreach (i, pair; edgePairs)
            mids[i] = toWorldP((corners[pair[0]] + corners[pair[1]]) * 0.5f + halfH);

        Vec3 c1 = toWorldD(planeAxis1);
        Vec3 c2 = toWorldD(planeAxis2);
        Vec3[4] colors = [axisColorFor(c2), axisColorFor(c1),
                          axisColorFor(c2), axisColorFor(c1)];

        foreach (i; 0 .. 4) {
            edgeH[i].pos   = mids[i];
            edgeH[i].size  = gizmoSize(mids[i], vp, 0.04f);
            edgeH[i].color = colors[i];
        }
    }

    // Move one edge of the base rectangle along its perpendicular axis.
    // Each edge moves along either planeAxis1 or planeAxis2; the opposite
    // edge stays fixed, so only the moved edge's world-axis size+center changes.
    //
    // Edge mapping (corners 0=(-a,-b), 1=(+a,-b), 2=(+a,+b), 3=(-a,+b)):
    //   Edge 0 (0,1): south edge → moves along -planeAxis2 (signed by delta projection)
    //   Edge 1 (1,2): east  edge → moves along +planeAxis1
    //   Edge 2 (2,3): north edge → moves along +planeAxis2
    //   Edge 3 (3,0): west  edge → moves along -planeAxis1
    //
    // For an edge moving along `moveAxis` by signed scalar `d`:
    //   The moved edge shifts by d; opposite stays. Center shifts by d/2;
    //   size changes by abs(d) (one side only).
    //   Precisely: newSize = oldSize + d*sign; newCen = oldCen + moveAxis*(d/2).
    void applyEdgeDelta(int idx, Vec3 delta) {
        // Incoming delta is in WORLD (axisDragDelta projects screen
        // motion onto a world-space axis). Convert to local before
        // running the size-+-center math, since planeAxis1/Axis2/normal
        // are the local-frame identity.
        Vec3 deltaL = toLocalD(delta);
        // Determine which local axis this edge moves along and the sign convention.
        //   Edge 0 → planeAxis2, sign = -1 (south edge: + delta means "shrink" from south side)
        //   Edge 1 → planeAxis1, sign = +1
        //   Edge 2 → planeAxis2, sign = +1
        //   Edge 3 → planeAxis1, sign = -1
        Vec3  moveAxis;
        float sign;
        final switch (idx) {
            case 0: moveAxis = planeAxis2; sign = -1.0f; break;
            case 1: moveAxis = planeAxis1; sign = +1.0f; break;
            case 2: moveAxis = planeAxis2; sign = +1.0f; break;
            case 3: moveAxis = planeAxis1; sign = -1.0f; break;
        }

        float d        = dot(deltaL, moveAxis) * sign;
        float oldSize  = sizeAlong(moveAxis);
        float signedSz = oldSize + d;
        // signedSz < 0 ⇒ dragged edge crossed the opposite edge ⇒
        // rectangle flips. Size is |signedSz|; cen shifts by the FULL
        // signed drag distance (always equals dot(delta, moveAxis), no
        // matter the sign), so the rectangle stays anchored at the
        // un-dragged opposite edge.
        float newSize = abs(signedSz);
        float fullD   = dot(deltaL, moveAxis);

        writeSizeParam(moveAxis, newSize);
        Vec3 cenShift = moveAxis * (fullD * 0.5f);
        params_.cenX += cenShift.x;
        params_.cenY += cenShift.y;
        params_.cenZ += cenShift.z;

        // Flip detected: swap drag index so the handle on the cursor's
        // new side becomes "the dragged one" for next frame. Without
        // this, the handle would visually stay anchored to the un-dragged
        // edge (the original opposite face that's now on the cursor's
        // SIDE post-flip would have NO handle being dragged). XOR with 2
        // toggles 0↔2 (south↔north) and 1↔3 (east↔west).
        if (signedSz < 0.0f)
            edgeDragIdx ^= 2;

        uploadPreview();
    }

    void choosePlane(const ref Viewport vp) {
        // Capture the active workplane as a local↔world transform. From
        // here on, all tool-internal coords are in local-space (where the
        // workplane is the identity XZ plane), so plane axes are the
        // canonical local triple. The previous behaviour — caching world-
        // space (axis1, normal, axis2) from pickWorkplane — implied an
        // axis-aligned workplane and broke after alignToSelection.
        frame = pickWorkplaneFrame(vp);
        // Pick the construction plane by camera, just like the corner
        // gizmo's most-facing-quad: in the workplane basis (a1, n, a2),
        // the basis axis most aligned with the camera-back vector is the
        // plane normal; the other two span the construction plane. With
        // auto-mode the basis is already pickMostFacingPlane → normal
        // wins by definition → planeNormal=local Y, falls back to the
        // XZ-base behaviour. With non-auto + camera looking from the
        // side, the construction plane swaps to the right local plane
        // so it agrees with what the corner gizmo highlights.
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        final switch (mostFacingAxis(camBack, frame.axis1, frame.normal, frame.axis2)) {
        case 0: {
            float s = dot(camBack, frame.axis1) >= 0.0f ? 1.0f : -1.0f;
            planeNormal = Vec3(s, 0, 0);
            planeAxis1  = Vec3(0, 1, 0);
            planeAxis2  = Vec3(0, 0, 1);
            break;
        }
        case 1: {
            float s = dot(camBack, frame.normal) >= 0.0f ? 1.0f : -1.0f;
            planeNormal = Vec3(0, s, 0);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 0, 1);
            break;
        }
        case 2: {
            float s = dot(camBack, frame.axis2) >= 0.0f ? 1.0f : -1.0f;
            planeNormal = Vec3(0, 0, s);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 1, 0);
            break;
        }
        }
        // Align the rounded-cap primary axis with the construction-plane
        // normal so the cap orientation tracks the most-facing plane
        // rather than the hard-coded local-Y default.
        params_.axis = worldAxisIdxOf(planeNormal);
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    // ---- Local ↔ world helpers (workplane refactor step 2) ----------------
    // cachedVp is in world space; mouse rays come from world; gizmo handles
    // hit-test against world-space projection. These wrappers do the
    // single-point transform between the two spaces.

    // Where the camera IS, in local coords. Only `setupHeightPlane` wants
    // this — a point, not a ray — so it keeps the plain eye under both
    // projections. Every cursor RAY goes through `localCursorPlane` instead:
    // pairing this apex with a screen direction is the perspective law, and
    // in an ortho cell it scales the answer by the camera distance (0661).
    Vec3 localEye() const {
        return transformPoint(frame.toLocal, cachedVp.eye);
    }
    /// The cursor ray at pixel (x, y) against a plane in LOCAL coords.
    /// Ortho-aware — see `create_common.workplaneCursorPlaneHit`.
    bool localCursorPlane(int x, int y, Vec3 planeOrigin, Vec3 planeNormal,
                          out Vec3 hitLocal) const
    {
        return workplaneCursorPlaneHit(frame, cachedVp,
                                       cast(float)x, cast(float)y,
                                       planeOrigin, planeNormal, hitLocal);
    }
    Vec3 toWorldP(Vec3 p)  const { return transformPoint(frame.toWorld, p); }
    Vec3 toWorldD(Vec3 d)  const { return transformDir  (frame.toWorld, d); }
    Vec3 toLocalP(Vec3 p)  const { return transformPoint(frame.toLocal, p); }
    Vec3 toLocalD(Vec3 d)  const { return transformDir  (frame.toLocal, d); }

    // Snap an edge size-handle's moved face onto the nearest snap target along
    // the handle's single free axis. Free-axis projection: only the moveAxis
    // coordinate is taken from the snap point — the opposite (un-dragged) face
    // and the other two axes are untouched, so the face slides to the target
    // without leaving its plane. No-op when no candidate is near the cursor.
    SnapResult snapMovedEdge(int idx, int sx, int sy) {
        Vec3 moveAxis; float faceSign;
        final switch (idx) {
            case 0: moveAxis = planeAxis2; faceSign = -1.0f; break;
            case 1: moveAxis = planeAxis1; faceSign = +1.0f; break;
            case 2: moveAxis = planeAxis2; faceSign = +1.0f; break;
            case 3: moveAxis = planeAxis1; faceSign = -1.0f; break;
        }
        // Cursor world = current moved-face position (anchors the overlay on
        // the handle); snapLocalHit picks a candidate near the cursor pixel.
        Vec3 hitLocal = toLocalP(edgeH[idx].pos);
        auto sr = snapLocalHit(hitLocal, frame, sx, sy, cachedVp,
                                *mesh, EditMode.Vertices);
        if (sr.snapped) {
            Vec3  cen  = cenVec();
            float size = sizeAlong(moveAxis);
            float o    = dot(cen, moveAxis) - faceSign * size * 0.5f; // un-moved face
            float t    = dot(hitLocal, moveAxis);                     // snap target
            float newCenAxis = (t + o) * 0.5f;
            cen = cen - moveAxis * dot(cen, moveAxis) + moveAxis * newCenAxis;
            params_.cenX = cen.x; params_.cenY = cen.y; params_.cenZ = cen.z;
            writeSizeParam(moveAxis, abs(t - o));
            uploadPreview();
        }
        return sr;
    }

    // Build a preview/commit mesh directly from params_ (no sync needed).
    // Mesh is emitted in LOCAL workplane space; callers transform vertices
    // through `frame.toWorld` before uploading / committing.
    void buildBase(Mesh* m) {
        // params_.size on planeNormal axis is 0 at this point (plane mode).
        size_t firstFace = m.faces.length;
        buildCuboidParametric(m, params_);
        if (planeNormal.x < -0.5f || planeNormal.y < -0.5f || planeNormal.z < -0.5f)
            reverseFaceWinding(m, firstFace);
    }

    // Apply `frame.toWorld` to every vertex of `m`. The cuboid generator
    // emits vertices in local space (axis-aligned around params_.cen with
    // ±size/2 extents along local X/Y/Z); this rotates+translates them
    // into world coords so renderers / commit see the workplane-aligned
    // primitive.
    //
    // The auto-mode frame is NOT necessarily identity (X-dominant camera
    // gets normal=+X / axis1=+Y, etc.) — always run the per-vertex math
    // rather than special-casing.
    //
    // pickMostFacingPlane returns LEFT-handed bases for cases 1 and 3
    // (camera most-facing X or Z). The toWorld matrix for those cases
    // has det = -1 → mirrors local-space polygon winding into world →
    // face normals point INWARD. Detect via det of the toWorld 3×3 and
    // reverse every face's vertex order to compensate. `frameIsLeftHanded`/
    // `reverseFaceWinding` are shared with `PrimitiveCreateTool` (task 0424
    // hoisted them into create_common.d — BoxTool was the only Create-tool
    // that had this correction pre-0424; the other 6 primitive create-tools
    // now apply it too via the base's `applyFrameToMeshRange`).
    void applyFrameToMesh(Mesh* m) {
        foreach (ref v; m.vertices)
            v = transformPoint(frame.toWorld, v);
        if (frameIsLeftHanded(frame))
            reverseFaceWinding(m, 0);
    }

    // Apply frame.toWorld to only vertices [firstIdx .. $] — used by
    // applyHeadless where buildCuboidParametric APPENDS to an existing
    // mesh. Transforming the whole vertex array would also re-transform
    // unrelated geometry that was placed in world coords by other tools.
    void applyFrameToMeshRange(Mesh* m, size_t firstIdx, size_t firstFaceIdx) {
        foreach (i; firstIdx .. m.vertices.length)
            m.vertices[i] = transformPoint(frame.toWorld, m.vertices[i]);
        if (frameIsLeftHanded(frame))
            reverseFaceWinding(m, firstFaceIdx);
    }

    void uploadBase() {
        previewMesh.clear();
        buildBase(&previewMesh);
        applyFrameToMesh(&previewMesh);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    // Upload whichever preview is appropriate for the current state.
    void uploadPreview() {
        if (state >= BoxState.DrawingHeight)
            uploadCuboid();
        else
            uploadBase();
    }

    void commitBase() {
        // buildBase APPENDS to `mesh` (cube tools preserve existing
        // geometry, the prim.cube convention). Transform
        // only the newly-emitted vertices.
        size_t firstNewVert = mesh.vertices.length;
        size_t firstNewFace = mesh.faces.length;
        buildBase(mesh);
        applyFrameToMeshRange(mesh, firstNewVert, firstNewFace);
        mesh.buildLoops();
        gpu.upload(*mesh);
        // buildBase appended geometry through mesh.addVertex / addFace, which
        // publish a Geometry change on the change-notification bus; the app's
        // per-frame flush drives the pick-cache resize. No explicit flag.
    }

    void setupHeightPlane() {
        hpOrigin = baseCentroid();
        // Camera direction in LOCAL space — height-drag plane sits with
        // its normal in the workplane (perpendicular to planeNormal),
        // pointing roughly at the camera so the user's screen-vertical
        // mouse motion projects cleanly onto planeNormal.
        Vec3 toCamera = localEye() - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f
            ? inPlane / len
            : planeAxis1;
    }

    // Build a cuboid preview/commit mesh directly from params_. Like
    // buildBase, emitted vertices are in local workplane space.
    void buildCuboid(Mesh* m) {
        buildCuboidParametric(m, params_);
    }

    void uploadCuboid() {
        previewMesh.clear();
        buildCuboid(&previewMesh);
        applyFrameToMesh(&previewMesh);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void commitCuboid() {
        size_t firstNewVert = mesh.vertices.length;
        size_t firstNewFace = mesh.faces.length;
        buildCuboid(mesh);
        applyFrameToMeshRange(mesh, firstNewVert, firstNewFace);
        mesh.buildLoops();
        gpu.upload(*mesh);
        // buildCuboid appended geometry through mesh.addVertex / addFace, which
        // publish a Geometry change on the change-notification bus; the app's
        // per-frame flush drives the pick-cache resize. No explicit flag.
    }
}

version(unittest) unittest {
    import record_observer_hub : RecordObserverHub;

    Mesh mesh; GpuMesh sceneGpu;
    auto box = new BoxTool(() => &mesh, &sceneGpu, LitShader.init);
    box.state = BoxState.DrawingHeight;
    box.moverDragAxis = 2; box.edgeDragIdx = 1; box.heightHDragIdx = 0;
    box.liveRunActive = true; box.liveUndoDepth = 7;
    box.dragBeforeValid = box.paramBeforeValid = true;
    box.toolHandles.setHaul(9);
    box.previewGpu.faceVao = 41; box.previewGpu.faceVbo = 42;
    auto gpuOwner = GpuCreateOwner.fakeForLegacyInitTest(box.preparedPreviewGpu());
    auto context = new PreparedRecordContext(null, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = box.prepareActivate(context, gpuOwner);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Box &&
        effect.owner == box.preparedOwnerForTest() &&
        box.previewGpu.faceVao == 41 && box.previewGpu.faceVbo == 42 &&
        box.toolHandles.haulForPreparedTest() == 9 &&
        box.state == BoxState.DrawingHeight && box.liveUndoDepth == 7);
    assert(context.validate());
    box.state = BoxState.HeightSet; // commit uses the captured reset, not live shape
    context.install(); context.install();
    assert(box.state == BoxState.Idle && box.moverDragAxis == -1 &&
        box.edgeDragIdx == -1 && box.heightHDragIdx == -1 &&
        !box.liveRunActive && box.liveUndoDepth == 0 &&
        !box.dragBeforeValid && !box.paramBeforeValid &&
        box.toolHandles.haulForPreparedTest() == -1 &&
        box.previewGpu.faceVao != 0 && box.previewGpu.faceVao != 41 &&
        context.installTraceForTest() == [7, 5, 8]);

    auto nullContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto nullEffect = box.prepareActivate(nullContext, null);
    assert(!nullEffect.accepted && nullEffect.kind == PreparedActivateKind.Box &&
        nullEffect.owner == box.preparedOwnerForTest() && !nullContext.validate());

    // A failure in joint validation aborts both earlier private enlistment and
    // owner-held GL names, leaves the live projection intact, and releases the
    // context for a fresh owner on the same target.
    auto fault = new BoxTool(() => &mesh, &sceneGpu, LitShader.init);
    fault.state = BoxState.BaseSet; fault.moverDragAxis = 1;
    fault.liveRunActive = true; fault.liveUndoDepth = 5;
    fault.toolHandles.setHaul(4); fault.previewGpu.faceVao = 71;
    auto faultOwner = GpuCreateOwner.fakeForLegacyInitTest(
        fault.preparedPreviewGpu());
    auto faultContext = new PreparedRecordContext(null, new RecordObserverHub());
    faultContext.setResourceIdentity(99, 100);
    auto faultEffect = fault.prepareActivate(faultContext, faultOwner);
    assert(faultEffect.accepted && !faultContext.validate() &&
        faultOwner.fakeCleanupCountForTest() == 1 &&
        fault.state == BoxState.BaseSet && fault.moverDragAxis == 1 &&
        fault.liveRunActive && fault.liveUndoDepth == 5 &&
        fault.toolHandles.haulForPreparedTest() == 4 &&
        fault.previewGpu.faceVao == 71 && !faultContext.validate());
    auto retryOwner = GpuCreateOwner.fakeForLegacyInitTest(
        fault.preparedPreviewGpu());
    auto retryContext = new PreparedRecordContext(null, new RecordObserverHub());
    retryContext.setResourceIdentity(7, 11);
    auto retryEffect = fault.prepareActivate(retryContext, retryOwner);
    assert(retryEffect.accepted && retryContext.validate());
    retryContext.install();
    assert(retryContext.installTraceForTest() == [7, 5, 8] &&
        fault.state == BoxState.Idle && fault.previewGpu.faceVao != 71);

    // Exact concrete admission and GPU identity are terminal refusals.
    class DerivedBox : BoxTool {
        this(Mesh* delegate() source, GpuMesh* gpu, LitShader shader) {
            super(source, gpu, shader);
        }
    }
    auto derived = new DerivedBox(() => &mesh, &sceneGpu, LitShader.init);
    auto derivedContext = new PreparedRecordContext(null, new RecordObserverHub());
    derivedContext.setResourceIdentity(7, 11);
    auto derivedGpu = GpuCreateOwner.fakeForLegacyInitTest(derived.preparedPreviewGpu());
    auto derivedEffect = derived.prepareActivate(derivedContext, derivedGpu);
    assert(!derivedEffect.accepted && derivedEffect.kind == PreparedActivateKind.Box &&
        derivedEffect.owner == derived.preparedOwnerForTest() &&
        !derivedContext.validate());

    GpuMesh foreignGpu;
    auto foreignOwner = GpuCreateOwner.fakeForLegacyInitTest(&foreignGpu);
    auto foreignContext = new PreparedRecordContext(null, new RecordObserverHub());
    foreignContext.setResourceIdentity(7, 11);
    auto foreignEffect = box.prepareActivate(foreignContext, foreignOwner);
    assert(!foreignEffect.accepted && foreignEffect.kind == PreparedActivateKind.Box &&
        foreignEffect.owner == box.preparedOwnerForTest() &&
        !foreignContext.validate());
}

private final class BoxLiveEditCommand : Command, GesturePayload {
private:
    BoxTool tool_;
    BoxParams before_;
    BoxParams after_;
    BoxState beforeState_;
    BoxState afterState_;

public:
    this(BoxTool tool, BoxParams before, BoxState beforeState,
         BoxParams after, BoxState afterState) {
        tool_ = tool;
        before_ = before;
        after_ = after;
        beforeState_ = beforeState;
        afterState_ = afterState;
        super(null, gBoxLiveEditView, EditMode.Vertices);
        // TASK 2500 — the undo image is the `before_`/`beforeState_` pair the
        // constructor just took, and the tool pushes this straight to
        // `history.record(cmd)` without ever calling `apply()`.
        noteUndoRecorded();
    }

    /// GesturePayload (task 1905) — the same comparison `BoxTool.sameLiveEdit`
    /// makes before it opens a live run. "Nothing to roll back" for this
    /// carrier is not an empty array; it is a before/after pair that is equal.
    override bool hasGesturePayload() const {
        return !(before_ == after_ && beforeState_ == afterState_);
    }

    override string name() const { return "prim.cube.live"; }
    override string label() const { return "Edit Box"; }
    override CmdFlags cmdFlags() const {
        return CmdFlags.SideEffect | CmdFlags.Quiet | CmdFlags.UndoForce;
    }

    protected override bool applyImpl() {
        if (tool_ is null) return false;
        tool_.restoreLiveEdit(after_, afterState_);
        tool_.noteLiveHistoryApply();
        return true;
    }

    protected override void revertImpl() {
        if (tool_ is null) {
            failRevert("the box tool that owns this live edit is gone");
            return;
        }
        tool_.restoreLiveEdit(before_, beforeState_);
        tool_.noteLiveHistoryRevert();
    }
}
