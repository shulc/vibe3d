module tools.xfrm_transform;

// XfrmTransformTool — `xfrm.transform`: ONE tool that can translate,
// rotate, and scale based on three boolean flags
// (`T`/`R`/`S`). The legacy MoveTool / RotateTool / ScaleTool will
// be retired in favour of this once preset migration lands (see
// doc/unified_transform_plan.md).
//
// Architecture: COMPOSITION. The unified tool owns one
// MoveTool / RotateTool / ScaleTool sub-instance for each enabled
// flag and dispatches events to whichever was clicked. This avoids
// porting ~2 k LOC of intricate drag / falloff / symmetry / snap
// machinery into a new class — the legacy tools already have all of
// it.
//
// Limitations of the composition approach (documented for the
// Step 5 cutover, doc/unified_transform_plan.md):
//
// - When ALL THREE flags are set (the bare Transform preset), each
//   sub-tool maintains its own edit session and commits its own
//   history entry. Most presets toggle only one flag so this
//   doesn't bite in practice.
// - Each sub-tool has its own FalloffGizmo instance. Endpoint
//   handle dragging stays scoped to the sub-tool that owns it; no
//   shared state, no cross-talk.
// - Sub-tool mouse-button-down side effects (screen-falloff disc
//   re-center) fire idempotently when none of the sub-tools
//   short-circuit, which is fine — they all see the same cursor.
//
// Headless `applyHeadless` runs the T → R → S chain through
// xform_kernels directly, NOT through the sub-tools — keeps the
// chain monotonic with respect to a single captured pivot /
// falloff snapshot, in the documented xfrm.transform order
// (T → R → S).
//
// Single-source applyTRS contract (Phase 3 — transform-single-source plan):
//
// Drag, property-panel sliders, and headless `tool.doApply` all
// flow through ONE entry point: `applyTRS(baseline)`. The sub-tools
// no longer mutate geometry. `MoveTool.onMouseMotion`'s drag-axis
// branch is now a *gesture-scalar producer*: it projects the screen
// mouse delta onto the gizmo's shared axes and writes the basis-
// LOCAL scalar into `moveSub.pendingTranslateDelta`. The wrapper
// drains that on every motion event, accumulates into
// `headlessTranslate`, and reapplies the chain from the drag-start
// baseline. Under ACEN.Local + axis.local the same basis-local
// scalar then flows to `applyTranslatePerCluster` — one scalar per
// cluster, applied along each cluster's OWN signed fwd. This kills
// the round-1 per-cluster magnitude divergence (signed-fwd projections
// no longer go through the screen-projection step).
//
// Edit session: wrapper-owned. `beginEdit()` fires once at the
// down-time `onMouseButtonDown` when moveSub consumes the click;
// `commitEdit("Move")` fires from `deactivate()` and `update()`'s
// selection/mutation-change guard — same "live-tool / one undo per
// tool session" semantics MoveTool had pre-refactor, just relocated.
//
// Fast-path predicate (`moveDragFastPath`): per-frame `applyTRS` is
// strictly slower than the zero-CPU `gpuMatrix = translation(delta)`
// bypass MoveTool used for the unconstrained whole-mesh case. So
// the wrapper evaluates ONCE at drag-start whether all of these
// hold: not-falloff, not-symmetry, not-per-cluster, whole-mesh
// selection. If yes, the per-frame motion runs the matrix bypass
// (no CPU mesh mutation) until mouseUp. If no, every frame runs
// `applyTRS(dragBaseline)`. The inputs are FROZEN for the drag
// duration — `dragFalloff`/`dragSymmetry` captured at mouse-down,
// selection frozen by `update()`'s `dragAxis>=0` early-return,
// cluster info derived from the toolpipe which is stable during
// drag. **Do NOT recompute the predicate mid-drag** — it cannot
// flip.

import bindbc.sdl;
import operator : VectorStack;

import math : Vec3, Viewport, screenRay, rayPlaneIntersect,
               closestPointOnSegmentToRay, translationMatrix,
               pivotRotationMatrix, pivotScaleMatrixBasis, dot;
import editmode : EditMode;
import mesh;
import shader : Shader;
import params : Param;
import tools.transform : TransformTool;
import tools.move      : MoveTool;
import tools.rotate    : RotateTool;
import tools.scale     : ScaleTool;
import tools.xform_kernels :
    applyTranslateIncremental,
    applyRotateIncremental,
    applyScaleFromActivation;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.packets  : FalloffType, ElementMode, ElementConnect, FalloffPacket;
import hover_state       : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;

alias VertexEditFactory = MeshVertexEdit delegate();

class XfrmTransformTool : TransformTool {
public:
    // T/R/S flags — `T integer 0/1` etc. in the preset config.
    // Default to all enabled (the bare `Transform` preset that shows
    // all three handler banks). Preset loader flips these per-preset
    // before the first activate().
    bool flagT = true;
    bool flagR = true;
    bool flagS = true;

    // Headless TRS attrs — always exposed regardless of flag state
    // so scripted callers can set TX with R=1 S=1 without first
    // flipping flags. Defaults: 0 for translate / rotate, 1 for scale.
    Vec3 headlessTranslate = Vec3(0, 0, 0);
    Vec3 headlessRotate    = Vec3(0, 0, 0);
    Vec3 headlessScale     = Vec3(1, 1, 1);

    // View-ring rotate slot — the arbitrary-axis counterpart of
    // `headlessRotate`. `headlessRotate.{x,y,z}` are rotations about the
    // basis axes bX/bY/bZ; the view-ring rotates about the camera-forward
    // axis, which is NOT one of those three, so it cannot be expressed as
    // three Euler angles without breaking falloff (three independently
    // weighted basis rotations ≠ one weighted rotation about an arbitrary
    // axis at fractional falloff weight). `applyTRS` applies this through the
    // SAME `applyRotateIncremental` kernel with dragAxisIdx == -1 (arbitrary
    // axis, per-vertex falloff-correct). Nonzero ONLY during a live view-ring
    // drag; every other path (panel Euler, numeric RX/RY/RZ) keeps it zero.
    Vec3  headlessRotateViewAxis  = Vec3(0, 0, 0);
    float headlessRotateViewAngle = 0;   // degrees about headlessRotateViewAxis

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        moveSub   = new MoveTool  (mesh, gpu, editMode);
        rotateSub = new RotateTool(mesh, gpu, editMode);
        scaleSub  = new ScaleTool (mesh, gpu, editMode);
    }

    override string name() const { return "Transform"; }

    // Forward the undo bindings into each sub-tool so their drags
    // record on the same global history.
    override public void setUndoBindings(CommandHistory h,
                                  VertexEditFactory factory) {
        super.setUndoBindings(h, factory);
        moveSub.setUndoBindings(h, factory);
        rotateSub.setUndoBindings(h, factory);
        scaleSub.setUndoBindings(h, factory);
    }

    override void activate() {
        super.activate();
        headlessTranslate = Vec3(0, 0, 0);
        headlessRotate    = Vec3(0, 0, 0);
        headlessScale     = Vec3(1, 1, 1);
        headlessRotateViewAxis  = Vec3(0, 0, 0);
        headlessRotateViewAngle = 0;
        if (flagT) moveSub.activate();
        if (flagR) rotateSub.activate();
        if (flagS) scaleSub.activate();
        moveSub.wrapperRef = this;
        rotateSub.wrapperRef = this;   // MS-2: rotate single-source plumbing
        scaleSub.wrapperRef = this;    // scale single-source plumbing
        activeDrag                = null;
        dragBaseline.length       = 0;
        moveDragFastPath          = false;
        rotDragFastPath           = false;
        rotDragAxisIdx            = -1;
        scaleDragFastPath         = false;
        scaleDragActive           = false;
        accumulatedWorldDelta     = Vec3(0, 0, 0);
        accumulatedAtDragStart    = Vec3(0, 0, 0);
        lastSelectionHash         = uint.max;
        lastMutationVersion       = ulong.max;
    }

    override void deactivate() {
        // Wrapper-owned edit session: commit any pending edit BEFORE
        // forwarding to the sub-tools (they only reset their own
        // drag-axis / handler state now; the edit baseline lives on
        // the wrapper inherited from TransformTool).
        if (editIsOpen())
            commitEdit("Move");
        if (flagT) moveSub.deactivate();
        if (flagR) rotateSub.deactivate();
        if (flagS) scaleSub.deactivate();
        super.deactivate();
        activeDrag           = null;
        dragBaseline.length  = 0;
        moveDragFastPath     = false;
    }

    override void update(ref VectorStack vts) {
        if (!active) return;

        // Wrapper-owned selection/mutation-change guard. Closes any
        // pending edit when the user picks a different selection or
        // mesh topology changed under the open edit — same boundary
        // MoveTool used pre-refactor (move.d's update() at ~line 147),
        // relocated to the wrapper since the wrapper now owns the
        // edit session.
        //
        // Skip during a live drag: dragAxis on a sub-tool stays >= 0
        // and any selection/mutation we'd observe is the drag's own
        // input, not a user action.
        if (activeDrag is null) {
            uint  curHash   = computeSelectionHash();
            ulong curMutVer = mesh.mutationVersion;
            if (curHash != lastSelectionHash
             || curMutVer != lastMutationVersion) {
                if (editIsOpen())
                    commitEdit("Move");
                lastSelectionHash   = curHash;
                lastMutationVersion = curMutVer;
            }
        }

        // Mid-tool falloff re-apply. While an edit session is open
        // and a non-trivial translate has been applied, a falloff
        // packet change (status-bar pulldown / property panel / HTTP)
        // should re-evaluate verts against the new weight at the
        // baseline position — same semantics MoveTool offered
        // pre-refactor, hosted on the wrapper now.
        //
        // The baseline we want is the LAST drag's `dragBaseline`
        // (full mesh), not the tool-session `editBaseline()` (which
        // is partial — only the moving set's verts, in an order
        // distinct from `mesh.vertices`). `dragBaseline` was
        // captured at the most recent mouse-down and matches
        // `mesh.vertices.length`.
        if (editIsOpen() && activeDrag is null
            && dragBaseline.length == mesh.vertices.length
            && (headlessTranslate.x != 0
             || headlessTranslate.y != 0
             || headlessTranslate.z != 0)) {
            FalloffPacket live = currentFalloff(vts);
            if (!falloffPacketsEqual(live, dragFalloff)) {
                dragFalloff = live;
                vertexCacheDirty = true;
                applyTRS(dragBaseline);
                needsGpuUpdate = true;
            }
        }

        // Drain the wrapper's own deferred-upload flag. `onMouseMotion`
        // sets it on the non-fast-path translate branch after each
        // `applyTRS(dragBaseline)`; without flushing here the partial-
        // selection drag would only become visible at LMB-up (the
        // wrapper's `gpu.upload(*mesh)` in `onMouseButtonUp`). The
        // sub-tools' own `update()` methods drain their own
        // `needsGpuUpdate` fields, which are distinct from the wrapper's
        // — so this flush must live here, not piggy-back on `moveSub`.
        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        // Each sub-tool's update() pulls handler.center from ACEN
        // and refreshes its gizmo orientation from AXIS. They all
        // see the same pipeline state so the three gizmos co-locate.
        if (flagT) moveSub.update(vts);
        if (flagR) rotateSub.update(vts);
        if (flagS) scaleSub.update(vts);
        syncGpuMatrix();
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        if (!active) return;
        cachedVp = vp;
        if (flagT) moveSub.draw(shader, vp, vts);
        if (flagR) rotateSub.draw(shader, vp, vts);
        if (flagS) scaleSub.draw(shader, vp, vts);
        syncGpuMatrix();
    }

    override Param[] params() {
        return [
            Param.bool_ ("T",  "Translate", &flagT, true),
            Param.bool_ ("R",  "Rotate",    &flagR, true),
            Param.bool_ ("S",  "Scale",     &flagS, true),
            Param.float_("TX", "Translate X", &headlessTranslate.x, 0.0f),
            Param.float_("TY", "Translate Y", &headlessTranslate.y, 0.0f),
            Param.float_("TZ", "Translate Z", &headlessTranslate.z, 0.0f),
            Param.float_("RX", "Rotate X",    &headlessRotate.x,    0.0f),
            Param.float_("RY", "Rotate Y",    &headlessRotate.y,    0.0f),
            Param.float_("RZ", "Rotate Z",    &headlessRotate.z,    0.0f),
            Param.float_("SX", "Scale X",     &headlessScale.x,     1.0f),
            Param.float_("SY", "Scale Y",     &headlessScale.y,     1.0f),
            Param.float_("SZ", "Scale Z",     &headlessScale.z,     1.0f),
        ];
    }

    override void drawProperties() {
        if (flagT) moveSub.drawProperties();
        if (flagR) rotateSub.drawProperties();
        if (flagS) scaleSub.drawProperties();
    }

    override bool consumesFalloff() const { return true; }

    // Element-falloff hover gating.
    // When falloff.element is the active WGHT stage, the user wants to
    // click any vert / edge / face to set the falloff anchor — so the
    // tool opts into hover-highlight for every type matching the
    // FalloffStage's elementMode pick selector. Falls through to the
    // base (no hover) when no Element falloff is active — keeps the
    // gizmo-only highlight for plain Move / Rotate / Scale presets.
    override bool wantsHoverForType(EditMode type) const {
        auto fs = activeFalloffStage();
        if (fs is null || fs.type != FalloffType.Element) return false;
        final switch (fs.elementMode) {
            case ElementMode.Auto:
            case ElementMode.AutoCent: return true;
            case ElementMode.Vertex:   return type == EditMode.Vertices;
            case ElementMode.Edge:
            case ElementMode.EdgeCent: return type == EditMode.Edges;
            case ElementMode.Polygon:
            case ElementMode.PolyCent: return type == EditMode.Polygons;
        }
    }

    // No queryActionCenter override here on purpose: ACEN is the
    // single source of truth for the gizmo pivot. When falloff.element
    // is active, ACEN.mode == element (set by the preset) and
    // ACEN.Element honours userPlaced first — tryPickElement below
    // pushes the picked element's centroid through setUserPlaced, so
    // ACEN.center == picked centroid for both the gizmo AND
    // FalloffStage.evaluate's `pickedCenter` snapshot (which now
    // reads state.actionCenter.center directly).

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Element-falloff click-pick PRE-step: when falloff.element
        // is active and the user clicks any element (vert/edge/face)
        // with no modifier keys, we push the picked element's
        // centroid through ACEN.setUserPlaced. ACEN.center then
        // becomes that point for every consumer (gizmo via
        // queryActionCenter, falloff sphere via state.actionCenter.center).
        // This DOES NOT add the picked element to the moving set —
        // ElementMove uses pick only as the pivot/anchor. The drag
        // moves the prior selection through the falloff sphere.
        bool picked = false;
        bool ctrlMod = false;
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            ctrlMod = (mods & KMOD_CTRL) != 0;
            bool plain = (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0;
            if (plain) picked = tryPickElement(e.x, e.y);
        }

        // Dispatch to the first enabled sub-tool that consumes the
        // event. The sub-tool's own hit-test determines whether
        // this click lands on its handler bank or falls through to
        // ACEN click-relocate.
        if (flagT && moveSub.onMouseButtonDown(e, vts)) {
            beginMoveDragSession(vts);
            activeDrag = moveSub;  return true;
        }
        if (flagR && rotateSub.onMouseButtonDown(e, vts)) {
            // Principal-axis ring (0/1/2) AND view-ring (3) → wrapper owns
            // geometry via applyTRS (capture the drag state). Principal axes
            // drain into headlessRotate (Euler); the view-ring drains into the
            // headlessRotateViewAxis/Angle slot. A relocate / no-axis click
            // (dragAxis == -1) starts no drag session.
            if (rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3) {
                beginRotateDragSession(vts);
            } else {
                rotDragAxisIdx = -1;
            }
            activeDrag = rotateSub; return true;
        }
        if (flagS && scaleSub.onMouseButtonDown(e, vts)) {
            // Scale single-source: a real gizmo drag (dragAxis >= 0 — any
            // of single-axis 0/1/2, uniform disc 3, plane circle 4/5/6)
            // → wrapper owns geometry via applyTRS (capture the drag
            // state). A falloff-handle grab or click-relocate leaves
            // dragAxis == -1 and starts no scale session.
            if (scaleSub.dragAxis >= 0) {
                beginScaleDragSession(vts);
            } else {
                scaleDragActive = false;
            }
            activeDrag = scaleSub;  return true;
        }

        // Click landed OFF every gizmo handler bank. If we just
        // picked an element under falloff.element, snap moveSub's
        // handler.center to the new ACEN-pivot and start a
        // screen-plane drag immediately — the same click+drag UX
        // ElementMove uses. The drag moves the prior selection
        // (empty ⇒ whole mesh per the universal rule); the falloff
        // sphere now centred on the picked element attenuates the
        // per-vertex displacement. ACEN's normal click-relocate
        // gate (acenAllowsClickRelocate refuses Element mode) does
        // NOT apply here — Element mode IS the gate.
        //
        // Requires the T flag: with T off (TransformRotate /
        // TransformScale) there's no moveSub.handler to anchor on.
        if (picked && flagT) {
            Vec3 pivot = queryActionCenter(vts);
            // notifyAcen=false because tryPickElement already wrote
            // userPlaced (notifyAcenUserPlaced) — don't overwrite it
            // with the ray-hit point.
            moveSub.beginScreenPlaneDragAt(e.x, e.y, pivot,
                                           ctrlMod, /*notifyAcen=*/false, vts);
            beginMoveDragSession(vts);
            activeDrag = moveSub;
            syncGpuMatrix();
            return true;
        }
        return false;
    }

    // Capture the per-drag state that `applyTRS` and the fast-path
    // bypass read from. Runs exactly once per drag, immediately
    // after `moveSub.onMouseButtonDown` (or `beginScreenPlaneDragAt`)
    // has settled the sub-tool's drag-axis / `cachedVp` / hit-test
    // and BEFORE the first motion event arrives.
    //
    // Snapshot contents:
    //   - `dragFalloff` / `dragSymmetry`: captured ONCE here (not
    //     inside `applyTRS`), so subsequent per-frame `applyTRS`
    //     re-evaluates see a stable packet even if the user toggles
    //     falloff mid-drag (the change picks up at the NEXT mouse-
    //     down, matching MoveTool's pre-refactor behaviour).
    //   - `dragBaseline`: full-mesh dup — `applyTRS` rebuilds from
    //     this each frame.
    //   - `moveDragFastPath`: predicate evaluated from the FROZEN
    //     snapshot above + a cluster-pivot query (cluster info is
    //     stable for the drag's duration). Drag fast-path is the
    //     unconstrained whole-mesh case; everything else routes
    //     through `applyTRS` per frame.
    //   - `headlessTranslate`: zeroed so this drag's accumulated
    //     basis-local delta starts from 0.
    //   - `editBaseline()`: opened idempotently via
    //     `beginEdit()` — captures pre-tool-session positions on
    //     FIRST call within the tool session. Subsequent calls
    //     (across drags / panel edits in the same session) are
    //     no-ops; the same baseline drives the final
    //     `commitEdit("Move")` at deactivate / selection change.
    void beginMoveDragSession(ref VectorStack vts) {
        buildVertexCacheIfNeeded();
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        beginEdit();   // idempotent — opens tool-session edit on first call

        // `cachedVp` is already up to date from the most recent
        // `draw()` call (every frame, before any event dispatch);
        // `applyTRS` reuses it for falloff weight evaluation.

        dragBaseline.length = mesh.vertices.length;
        foreach (i; 0 .. mesh.vertices.length)
            dragBaseline[i] = mesh.vertices[i];

        headlessTranslate       = Vec3(0, 0, 0);
        accumulatedWorldDelta   = Vec3(0, 0, 0);
        accumulatedAtDragStart  = accumulatedWorldDelta;

        auto cp = queryClusterPivots(vts);
        // ANTI-RELOCATION: do NOT move this predicate out of
        // `beginMoveDragSession` and do NOT re-evaluate it in
        // `onMouseMotion`. The fast-path is a ONCE-PER-DRAG
        // decision; its inputs MUST come from the snapshot
        // taken at mouse-down:
        //   - `dragFalloff` / `dragSymmetry`: just captured
        //     above; both frozen for the drag.
        //   - `cp.active`: cluster-pivot presence is a function
        //     of ACEN mode + the moving set, both of which the
        //     wrapper's `update()` freezes during a drag
        //     (`dragAxis>=0` early-return in transform.d).
        //   - `vertexProcessCount`: selection-derived; same
        //     freeze.
        // Recomputing mid-drag from a live `vts` would let the
        // path silently flip (e.g. if falloff turned on
        // between frames), violating the "drag == numeric"
        // contract the parity test pins.
        moveDragFastPath = !dragFalloff.enabled
                        && !dragSymmetry.enabled
                        && !cp.active
                        && (vertexProcessCount
                            == cast(int)mesh.vertices.length);
    }

    // MS-2 (rotate single-source) — rotate counterpart of
    // `beginMoveDragSession`. Captures the per-drag state that the rotate
    // `applyTRS` path + the fast-path bypass read from. Runs once per drag,
    // right after `rotateSub.onMouseButtonDown` has settled the sub-tool's
    // `dragAxis` / `cachedVp`. INERT until MS-4 wires it into the wrapper's
    // mouse-down dispatch.
    //
    //   - `dragFalloff`/`dragSymmetry`: captured ONCE here so per-frame
    //     re-evaluates see a stable packet.
    //   - per-SESSION display snapshot (round-3 S-survivor-1): only on the
    //     first edit-open frame, so undo peels back the whole tool session.
    //   - `dragBaseline`: full-mesh dup AFTER any prior panel rotation is
    //     already baked into `mesh.vertices` (S1 composition).
    //   - `headlessRotate`: zeroed for ALL axes (move pattern; S1 — NOT
    //     per-axis, which would double-apply a prior panel rotation).
    //   - `rotDragAxisIdx` / `rotDragFastPath`: dragged ring index + the
    //     once-per-drag GPU-skip predicate.
    void beginRotateDragSession(ref VectorStack vts) {
        buildVertexCacheIfNeeded();
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);

        // NOTE: the rotate edit SESSION is owned by `rotateSub` (its
        // `onMouseButtonDown` calls `beginEdit`, and its `deactivate`/`update`
        // commit "Rotate" with the display-state undo hooks). The wrapper here
        // captures only the GEOMETRY drag state (`dragBaseline`/falloff/
        // symmetry/fast-path); the geometry is applied through `applyTRS`. The
        // session deliberately stays on `rotateSub` (MS-5 decision) — keeping
        // it there avoids the cross-instance commit problem entirely.

        dragBaseline.length = mesh.vertices.length;
        foreach (i; 0 .. mesh.vertices.length)
            dragBaseline[i] = mesh.vertices[i];

        headlessRotate = Vec3(0, 0, 0);   // zero ALL axes (S1)
        headlessRotateViewAxis  = Vec3(0, 0, 0);
        headlessRotateViewAngle = 0;

        // Ring index: 0/1/2 = principal (Euler slot), 3 = view-ring (axis-angle
        // slot). Both are wrapper-owned now; clamp anything else to -1
        // defensively.
        rotDragAxisIdx = (rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3)
                       ? rotateSub.dragAxis : -1;

        auto cp = queryClusterPivots(vts);
        // Same once-per-drag freeze contract as `moveDragFastPath`; see its
        // anti-relocation note. Do NOT recompute mid-drag.
        rotDragFastPath = !dragFalloff.enabled
                       && !dragSymmetry.enabled
                       && !cp.active
                       && (vertexProcessCount
                           == cast(int)mesh.vertices.length);
    }

    // Scale single-source — scale counterpart of `beginMoveDragSession` /
    // `beginRotateDragSession`. Captures the per-drag state the scale
    // `applyTRS` path + the fast-path bypass read from. Runs once per drag,
    // right after `scaleSub.onMouseButtonDown` has settled the sub-tool's
    // `dragAxis` / `cachedVp`.
    //
    //   - `dragFalloff`/`dragSymmetry`: captured ONCE here so per-frame
    //     re-evaluates see a stable packet (mirrors move/rotate).
    //   - `dragBaseline`: full-mesh dup AFTER any prior panel scale is
    //     already baked into `mesh.vertices`.
    //   - `headlessScale`: reset to identity (1,1,1) — this drag's
    //     within-drag absolute factor accumulates from there.
    //   - `scaleDragActive` / `scaleDragFastPath`: drag-owns-geometry flag +
    //     the once-per-drag GPU-skip predicate.
    //
    // The scale edit SESSION stays owned by `scaleSub` (its
    // `onMouseButtonDown` calls `beginEdit`, its `deactivate`/`update` commit
    // "Scale" with the scaleAccum/propScale undo hooks). The wrapper captures
    // only the GEOMETRY drag state; geometry is applied through `applyTRS`.
    void beginScaleDragSession(ref VectorStack vts) {
        buildVertexCacheIfNeeded();
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);

        dragBaseline.length = mesh.vertices.length;
        foreach (i; 0 .. mesh.vertices.length)
            dragBaseline[i] = mesh.vertices[i];

        headlessScale = Vec3(1, 1, 1);

        auto cp = queryClusterPivots(vts);
        // Same once-per-drag freeze contract as `moveDragFastPath`; see its
        // anti-relocation note. Do NOT recompute mid-drag.
        scaleDragFastPath = !dragFalloff.enabled
                         && !dragSymmetry.enabled
                         && !cp.active
                         && (vertexProcessCount
                             == cast(int)mesh.vertices.length);
        scaleDragActive = true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        bool r;
        if (activeDrag is moveSub) {
            r = moveSub.onMouseMotion(e, vts);
            if (r) {
                // Defensive: the gesture-scalar drain belongs to
                // moveSub's drag. If `activeDrag` somehow flipped
                // mid-event the read below would consume stale
                // accumulated delta from a previous drag.
                assert(activeDrag is moveSub,
                    "moveSub motion drain expected activeDrag == moveSub");
                // Drain the basis-local scalar moveSub produced this
                // motion event (drag-axis branch in
                // `MoveTool.onMouseMotion`) into the wrapper's
                // `headlessTranslate`. Idle / hover branches in
                // moveSub leave `pendingTranslateDelta` at zero, so
                // the drain is a no-op on those.
                Vec3 pending = moveSub.pendingTranslateDelta;
                moveSub.pendingTranslateDelta = Vec3(0, 0, 0);
                headlessTranslate = headlessTranslate + pending;

                // Visual: the gizmo center moves along the GLOBAL
                // basis projection of `headlessTranslate` (same
                // projection `applyTRS` does in the non-per-cluster
                // branch). Per-cluster doesn't have a single
                // visible "gizmo center" — the gizmo follows the
                // ACEN centroid which `update()` re-evaluates from
                // the moved verts on the next frame.
                Vec3 worldStep = moveSub.handler.axisX * pending.x
                               + moveSub.handler.axisY * pending.y
                               + moveSub.handler.axisZ * pending.z;
                accumulatedWorldDelta = accumulatedWorldDelta + worldStep;

                // Single per-frame mesh mutation through
                // applyTRS. headlessTranslate carries the running
                // basis-local scalar; under ACEN.Local it flows
                // into `applyTranslatePerCluster`, otherwise into
                // the global-basis branch.
                applyTRS(dragBaseline);

                // GPU update policy: the fast-path uses the
                // u_model matrix (one uniform per frame) instead
                // of re-uploading the full vertex buffer. The
                // non-fast-path schedules a partial / full upload
                // at draw() time. Both paths' mesh.vertices stay
                // in sync with the gizmo — fast-path is purely a
                // GPU-bandwidth optimization for the unconstrained
                // whole-mesh case (no falloff weights / no
                // symmetry mirror / no per-cluster axes / whole-
                // mesh selection).
                //
                // "- accumulatedAtDragStart" is anchored at zero
                // by `beginMoveDragSession`; it's there so a
                // future multi-drag-per-session design can pin
                // the per-drag GPU translate against the prior
                // mouseUp's upload.
                if (moveDragFastPath) {
                    gpuMatrix = translationMatrix(
                        accumulatedWorldDelta - accumulatedAtDragStart);
                } else {
                    needsGpuUpdate = true;
                }
                moveSub.handler.setPosition(
                    moveSub.handler.center + worldStep);
            }
        } else if (activeDrag is rotateSub) {
            r = rotateSub.onMouseMotion(e, vts);
            // Drain the gesture scalar rotateSub published this motion into the
            // wrapper-owned rotate state and run the single applyTRS evaluate.
            // Principal axes (0/1/2) → headlessRotate (Euler about bX/bY/bZ).
            // View-ring (3) → headlessRotateViewAxis/Angle (axis-angle about the
            // camera-forward axis). Both share applyTRS + the fast-path bypass.
            if (r && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 3) {
                int   ax  = rotateSub.pendingRotateAxis;
                float ang = rotateSub.pendingRotateAngle;
                rotateSub.pendingRotateAxis = -1;
                if (ax >= 0 && ax <= 2) {
                    import std.math : PI;
                    float deg = ang * 180.0f / cast(float)PI;
                    // Absolute-from-baseline: only the dragged axis is set;
                    // beginRotateDragSession zeroed all three (S1).
                    headlessRotate = Vec3(0, 0, 0);
                    headlessRotateViewAxis  = Vec3(0, 0, 0);
                    headlessRotateViewAngle = 0;
                    if      (ax == 0) headlessRotate.x = deg;
                    else if (ax == 1) headlessRotate.y = deg;
                    else              headlessRotate.z = deg;

                    // CPU is rebuilt from the drag baseline EVERY frame so it
                    // is never stale at mouseUp (round-1/3 B3; landed-move
                    // parity). The fast-path then merely skips the per-frame
                    // vertex re-upload — the GPU keeps the baseline buffer and
                    // u_model = pivotRotationMatrix bridges the rotation.
                    applyTRS(dragBaseline);
                    if (rotDragFastPath) {
                        Vec3 pivot = rotateSub.handler.center;
                        Vec3 axisV = ax == 0 ? rotateSub.handler.axisX
                                   : ax == 1 ? rotateSub.handler.axisY
                                             : rotateSub.handler.axisZ;
                        gpuMatrix = pivotRotationMatrix(pivot, axisV, ang);
                    } else {
                        needsGpuUpdate = true;
                    }
                } else if (ax == 3) {
                    import std.math : PI;
                    float deg = ang * 180.0f / cast(float)PI;
                    // Absolute-from-baseline: the running view-axis angle this
                    // drag has accumulated, about the camera-forward axis the
                    // producer captured. Euler slot stays zeroed (S1).
                    headlessRotate = Vec3(0, 0, 0);
                    headlessRotateViewAxis  = rotateSub.pendingRotateViewAxis;
                    headlessRotateViewAngle = deg;
                    applyTRS(dragBaseline);
                    if (rotDragFastPath) {
                        Vec3 pivot = rotateSub.handler.center;
                        gpuMatrix = pivotRotationMatrix(
                            pivot, headlessRotateViewAxis, ang);
                    } else {
                        needsGpuUpdate = true;
                    }
                }
            }
        } else if (activeDrag is scaleSub && scaleDragActive) {
            r = scaleSub.onMouseMotion(e, vts);
            // Drain the within-drag absolute per-axis scale factor the
            // producer published this motion (any gizmo drag mode). Idle /
            // hover frames leave pendingScaleValid false → no-op.
            if (r && scaleSub.pendingScaleValid) {
                scaleSub.pendingScaleValid = false;
                Vec3 f = scaleSub.pendingScale;
                // Absolute-from-baseline: headlessScale carries this drag's
                // running factor; beginScaleDragSession reset it to identity.
                headlessScale = f;

                // CPU is rebuilt from the drag baseline EVERY frame so it is
                // never stale at mouseUp. The fast-path then merely skips the
                // per-frame vertex re-upload — the GPU keeps the baseline
                // buffer and u_model = pivotScaleMatrixBasis bridges the scale.
                applyTRS(dragBaseline);
                if (scaleDragFastPath) {
                    gpuMatrix = pivotScaleMatrixBasis(
                        scaleSub.handler.center,
                        scaleSub.handler.axisX,
                        scaleSub.handler.axisY,
                        scaleSub.handler.axisZ,
                        f.x, f.y, f.z);
                } else {
                    needsGpuUpdate = true;
                }
            }
        } else if (activeDrag !is null) {
            r = activeDrag.onMouseMotion(e, vts);
        }
        else {
            // Idle: let each enabled sub-tool refresh its own hover /
            // snap preview. None will consume the event (dragAxis ==
            // -1 path on every sub-tool returns false after updating
            // the preview).
            if (flagT) moveSub.onMouseMotion(e, vts);
            if (flagR) rotateSub.onMouseMotion(e, vts);
            if (flagS) scaleSub.onMouseMotion(e, vts);
        }
        // GPU bypass: forward the active sub-tool's gpuMatrix.
        // app.d reads `activeTool.gpuMatrix` to drive the shader's
        // u_model uniform during whole-mesh drags; without this
        // forwarding the wrapper's gpuMatrix stays at identity and
        // the visible mesh lags behind the sub-tool's CPU vertices.
        //
        // The wrapper OWNS gpuMatrix when it drives the geometry itself —
        // moveSub drag, OR any rotateSub ring drag (principal 0/1/2 or
        // view-ring 3 — it wrote gpuMatrix in the fast-path branch / left it
        // identity otherwise), OR a scale drag. Forwarding the sub-tool's
        // identity gpuMatrix in those cases would clobber the wrapper's.
        bool wrapperOwnsGpu = (activeDrag is moveSub)
            || (activeDrag is rotateSub
                && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 3)
            || (activeDrag is scaleSub && scaleDragActive);
        if (!wrapperOwnsGpu)
            syncGpuMatrix();
        return r;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        bool r;
        bool wasMoveDrag = (activeDrag is moveSub);
        // Capture BEFORE rotateSub.onMouseButtonUp resets its dragAxis to -1.
        // Both principal (0/1/2) and view-ring (3) drags are wrapper-owned.
        bool rotWrapperOwned = (activeDrag is rotateSub)
            && rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3;
        bool wasScaleDrag = (activeDrag is scaleSub) && scaleDragActive;
        if (activeDrag !is null) {
            r = activeDrag.onMouseButtonUp(e, vts);
            activeDrag = null;
        } else {
            // No active drag: still forward LMB-up to each sub-tool
            // so they get a chance to close screen-falloff disc
            // overlays etc. None should claim the event.
            if (flagT) moveSub.onMouseButtonUp(e, vts);
            if (flagR) rotateSub.onMouseButtonUp(e, vts);
            if (flagS) scaleSub.onMouseButtonUp(e, vts);
        }

        // Phase 3 — wrapper owns the GPU upload + gpuMatrix reset
        // that MoveTool's mouseUp used to handle. One upload per
        // drag end; the next drag opens its own dragBaseline at the
        // refreshed mesh state. Edit session STAYS open (7.5h
        // semantics — commit fires at deactivate / selection
        // change / BrushReset preset).
        if (wasMoveDrag && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate   = false;
            moveDragFastPath = false;

            // BrushReset opt-out (xfrm.softDrag etc.): each LMB drag
            // is one atomic stroke. Bake the drag to history at
            // release; next LMB-down starts a fresh baseline at the
            // grab point. Without this the falloff weights would
            // re-apply onto stale baseline verts on subsequent
            // pulls.
            import tool : ToolFlag;
            if (hasFlag(ToolFlag.BrushReset) && editIsOpen())
                commitEdit("Move");
        }

        // Rotate drag (principal axes OR view-ring) — wrapper owns the final
        // upload + gpuMatrix reset (CPU verts were rebuilt by applyTRS every
        // frame, so this uploads the already-rotated mesh; no stale-CPU, B3).
        // Zero the view-ring slot so a later panel/falloff re-apply (which
        // drives applyTRS with the Euler slot) does NOT re-apply this drag's
        // view rotation on top. The edit SESSION is still committed by
        // rotateSub (its deactivate / update selection-change guard).
        if (rotWrapperOwned && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate  = false;
            rotDragFastPath = false;
            rotDragAxisIdx  = -1;
            headlessRotateViewAxis  = Vec3(0, 0, 0);
            headlessRotateViewAngle = 0;
        }

        // Scale single-source — wrapper owns the final upload + gpuMatrix
        // reset (CPU verts were rebuilt by applyTRS every frame, so this
        // uploads the already-scaled mesh; no stale-CPU). The edit SESSION
        // is still committed by scaleSub (its deactivate / update
        // selection-change guard).
        if (wasScaleDrag && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate    = false;
            scaleDragFastPath = false;
            scaleDragActive   = false;
        }

        // moveSub + all rotate rings + scale are wrapper-owned. Anything else
        // (a sub-tool driving its own gpuMatrix) still needs the forward.
        if (!wasMoveDrag && !rotWrapperOwned && !wasScaleDrag)
            syncGpuMatrix();
        return r;
    }

    // Single geometry-apply entry point — the "evaluate" of this tool.
    // Drag, property-panel sliders, and headless `tool.doApply` all run
    // through here. Absolute-from-baseline: the caller supplies the
    // pre-chain vertex array (e.g. drag-down snapshot for live drags,
    // current `mesh.vertices.dup` for the one-shot numeric path) and
    // `applyTRS` rebuilds `mesh.vertices` from it (T → R → S, using
    // `headlessTranslate` / `headlessRotate` / `headlessScale` as
    // attributes).
    //
    // Prologue: UNCONDITIONAL whole-baseline restore. Required because
    // `applyTranslatePerCluster` is `+=` incremental and the symmetry
    // mirror touches `dragSymmetry.pairOf` indices OUTSIDE
    // `vertexIndicesToProcess`. Without the restore those side effects
    // would accumulate across re-evaluates (the per-frame call pattern
    // during live drag). If the lengths can ever diverge in normal
    // flow that is itself a bug — the assert catches it loudly rather
    // than silently skipping the restore.
    //
    // Pivot, falloff, and symmetry are captured ONCE at drag start
    // (in `beginMoveDragSession`) and stored on the wrapper instance
    // (`dragFalloff`, `dragSymmetry` are inherited fields, written
    // once and read by `applyTRS` here). The headless numeric path
    // (`applyHeadless()`) captures them itself before calling
    // `applyTRS`. Either way `applyTRS` only READS them — it does NOT
    // re-capture per call. This keeps the live-drag fast-path predicate
    // and the per-frame evaluate looking at the SAME snapshot.
    //
    // Per-cluster (ACEN.Local) behaviour:
    //   T: when cp.active && ap.active, each vert's delta is projected
    //      onto that cluster's axis frame — so TX/TY/TZ mean "along
    //      cluster's right/up/fwd" instead of world XYZ.
    //   R: dragAxisIdx 0/1/2 enables per-cluster axis lookup in the
    //      kernel; pivotFor() already reads per-cluster centers.
    //   S: applyScaleFromActivation already handles per-cluster via
    //      axesFor() — no change needed.
    bool applyTRS(Vec3[] baseline) {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);

        Vec3 pivot = queryActionCenter(vts);
        auto cp    = queryClusterPivots(vts);
        auto ap    = queryClusterAxes(vts);

        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        // UNCONDITIONAL whole-baseline restore. Cheap (one vector copy)
        // and covers every cross-cluster / symmetry-mirror side effect.
        // The assert pins the only valid relationship — if it ever
        // trips, a caller is feeding the wrong baseline.
        assert(baseline.length == mesh.vertices.length,
               "applyTRS: baseline/mesh length mismatch ("
             ~ "baseline must be a snapshot of mesh.vertices at the "
             ~ "edit-session start)");
        foreach (i; 0 .. mesh.vertices.length)
            mesh.vertices[i] = baseline[i];

        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);

        if (flagT) {
            bool hasT = (headlessTranslate.x != 0
                      || headlessTranslate.y != 0
                      || headlessTranslate.z != 0);
            if (hasT) {
                // Per-cluster translate: when ACEN.Local provides per-cluster
                // axes, TX/TY/TZ are interpreted along each cluster's OWN
                // right/up/fwd axis frame. Without per-cluster axes (single
                // cluster or non-Local mode) fall back to the global basis.
                if (cp.active && ap.active) {
                    applyTranslatePerCluster(cp, ap, headlessTranslate);
                } else {
                    // Global basis: project headlessTranslate onto bX/bY/bZ.
                    Vec3 delta = bX * headlessTranslate.x
                               + bY * headlessTranslate.y
                               + bZ * headlessTranslate.z;
                    applyTranslateIncremental(mesh, vertexIndicesToProcess,
                                              delta,
                                              dragFalloff, cachedVp,
                                              dragSymmetry, toProcess);
                }
            }
        }

        if (flagR) {
            import std.math : PI;
            if (headlessRotate.x != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bX, 0,
                                       headlessRotate.x * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
            if (headlessRotate.y != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bY, 1,
                                       headlessRotate.y * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
            if (headlessRotate.z != 0)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, bZ, 2,
                                       headlessRotate.z * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);

            // View-ring rotation: a single rotation about the arbitrary
            // camera-forward axis. dragAxisIdx == -1 makes the kernel use the
            // axis as-is (no per-cluster substitution) and apply the SAME
            // per-vertex falloff-weighted Rodrigues rotation as the principal
            // axes — correct under falloff (one weighted rotation about one
            // axis, not three weighted Euler rotations). Per-cluster axes are
            // intentionally ignored here: a view rotation is global by
            // definition. Nonzero only during a live view-ring drag.
            bool hasViewRot = headlessRotateViewAngle != 0
                && (headlessRotateViewAxis.x != 0
                 || headlessRotateViewAxis.y != 0
                 || headlessRotateViewAxis.z != 0);
            if (hasViewRot)
                applyRotateIncremental(mesh, vertexIndicesToProcess,
                                       pivot, headlessRotateViewAxis, -1,
                                       headlessRotateViewAngle * cast(float)(PI / 180.0),
                                       dragFalloff, cachedVp,
                                       cp, ap, dragSymmetry, toProcess);
        }

        if (flagS) {
            bool hasS = (headlessScale.x != 1
                      || headlessScale.y != 1
                      || headlessScale.z != 1);
            if (hasS) {
                Vec3[] activation = mesh.vertices.dup;
                // Scale's per-vert falloff weight is evaluated at the
                // pre-chain BASELINE position so the weight stays
                // stable across the T/R stages' mutations. We pass
                // the same baseline we just restored from.
                applyScaleFromActivation(mesh, vertexIndicesToProcess,
                                         activation, pivot,
                                         bX, bY, bZ,
                                         headlessScale,
                                         dragFalloff, cachedVp,
                                         cp, ap, dragSymmetry, toProcess,
                                         baseline);
            }
        }

        return true;
    }

    // MS-5 (rotate single-source) — ABSOLUTE-from-origVertices rotate apply,
    // routed through the single `applyTRS` evaluate. `RotateTool`'s panel
    // slider path and its kept-open-edit falloff-reapply both call
    // `RotateTool.applyAbsoluteFromOrigCpuOnly`, which now delegates here so
    // the PANEL ("ui") and the live-drag / numeric ("handle" / "headless")
    // paths share ONE geometry-apply entry point. `angleAccumRad` is the
    // cumulative per-basis-axis Euler rotation (radians) the panel/display
    // maintains; we convert to the `headlessRotate` degree attribute and run
    // `applyTRS(baseline)` with `baseline == origVertices` (the absolute
    // rebuild baseline). Falloff/symmetry are (re)captured from the live
    // toolpipe so a mid-edit falloff change takes effect, matching the prior
    // `applyRotateFromOrig` behaviour.
    //
    // The edit SESSION stays owned by `RotateTool` (its `beginEdit` /
    // `commitEdit` with the angleAccum/propDeg undo hooks) — only the
    // GEOMETRY is unified here. This sidesteps the per-instance edit-snapshot
    // ownership problem (would-be B2) entirely: no session migrates to the
    // wrapper, so there is no cross-instance commit.
    void applyRotateAbsolute(Vec3[] baseline, Vec3 angleAccumRad) {
        import std.math : PI;
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;   // wrapper cache may be stale (panel path)
        headlessRotate = Vec3(angleAccumRad.x * 180.0f / cast(float)PI,
                              angleAccumRad.y * 180.0f / cast(float)PI,
                              angleAccumRad.z * 180.0f / cast(float)PI);
        // Euler-slot path: the view-ring slot must be clear so a prior
        // view-ring drag's axis-angle does not re-apply on top.
        headlessRotateViewAxis  = Vec3(0, 0, 0);
        headlessRotateViewAngle = 0;
        applyTRS(baseline);
    }

    // Scale single-source — ABSOLUTE-from-activationVertices scale apply,
    // routed through the single `applyTRS` evaluate. `ScaleTool`'s panel
    // slider path and its kept-open-edit falloff-reapply both call
    // `ScaleTool.applyScaleFromActivationCpuOnly`, which now delegates here so
    // the PANEL ("ui") and the live-drag / numeric ("handle" / "headless")
    // paths share ONE geometry-apply entry point. `scaleAccum` is the
    // cumulative per-axis scale factor the panel/display maintains; we write
    // it into the `headlessScale` attribute and run `applyTRS(baseline)` with
    // `baseline == activationVertices` (the absolute rebuild baseline).
    // Falloff/symmetry are (re)captured from the live toolpipe so a mid-edit
    // falloff change takes effect, matching the prior `applyScaleFromActivation`
    // behaviour.
    //
    // The edit SESSION stays owned by `ScaleTool` (its `beginEdit` /
    // `commitEdit` with the scaleAccum/propScale undo hooks) — only the
    // GEOMETRY is unified here, sidestepping the per-instance edit-snapshot
    // ownership problem (no session migrates to the wrapper).
    void applyScaleAbsolute(Vec3[] baseline, Vec3 scaleAccum) {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;   // wrapper cache may be stale (panel path)
        headlessScale = scaleAccum;
        applyTRS(baseline);
    }

    // Numeric headless apply (`tool.doApply` + cross-engine deform
    // diff). Captures falloff + symmetry from the current toolpipe state
    // (no live-drag snapshot to read from), then delegates to
    // `applyTRS(mesh.vertices.dup)`. Restore-to-self in the prologue is
    // a no-op so the resulting mesh matches the legacy numeric output
    // byte-for-byte; the golden fixtures (`test_fixture_acen_local`,
    // `test_fixture_translate*`, `test_fixture_rotate*`,
    // `test_fixture_scale*`) stay green.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;
        // Numeric path uses RX/RY/RZ (Euler slot) only — the view-ring slot
        // has no numeric attr, so keep it clear.
        headlessRotateViewAxis  = Vec3(0, 0, 0);
        headlessRotateViewAngle = 0;
        return applyTRS(mesh.vertices.dup);
    }

    // Phase 4 — property-panel translate slider entry point.
    // MoveTool.drawProperties calls this once per active slider
    // frame with the basis-local delta the user just typed/dragged.
    //
    // Idempotent setup: opens a tool-session edit if one isn't yet
    // open, AND opens a "panel drag" baseline if no gizmo drag is
    // currently active (= panel and gizmo drag both feed the same
    // `headlessTranslate`, the same `applyTRS` evaluate, and the
    // same `editBaseline()` for the final undo entry).
    //
    // No-op when no T flag — panel sliders for X/Y/Z only apply
    // under the Move (T) preset; Rotate / Scale presets have their
    // own panel paths in `rotateSub.drawProperties` /
    // `scaleSub.drawProperties`.
    public void applyMovePanelDelta(Vec3 basisLocalDelta) {
        if (!flagT) return;
        if (basisLocalDelta.x == 0 && basisLocalDelta.y == 0
            && basisLocalDelta.z == 0) return;

        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);

        // First-active-frame setup. captureFalloffForDrag /
        // captureSymmetryForDrag overwrite `dragFalloff` /
        // `dragSymmetry` every call; that's fine — for slider
        // edits we want the live falloff to take effect
        // immediately.
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        buildVertexCacheIfNeeded();
        beginEdit();   // idempotent

        // Panel-drag baseline: when no gizmo drag is open the panel
        // is the only active write path, so we capture a fresh
        // dragBaseline at the first-active-frame. A subsequent panel
        // edit re-uses this baseline (length-equal check below).
        // Refreshing the baseline at every panel frame would zero
        // out the prior cumulative — keep stale ones.
        if (dragBaseline.length != mesh.vertices.length) {
            dragBaseline.length = mesh.vertices.length;
            foreach (i; 0 .. mesh.vertices.length)
                dragBaseline[i] = mesh.vertices[i];
            headlessTranslate = Vec3(0, 0, 0);
        }

        headlessTranslate = headlessTranslate + basisLocalDelta;
        applyTRS(dragBaseline);
        needsGpuUpdate = true;
    }

    // (MS-2's `commitRotateEdit` / `applyRotatePanelDelta` scaffolding was
    // removed in MS-8: the simpler MS-5 design keeps the rotate edit session
    // on `RotateTool` and unifies only the GEOMETRY via `applyRotateAbsolute`
    // → `applyTRS`, so no wrapper-side commit / panel-delta path is needed.)

    // Phase 3 — public accessor for MoveTool's `update()` to gate
    // its ACEN-pull on whether the wrapper has an open edit
    // session. `editIsOpen()` is protected on `TransformTool`;
    // exposing this read-only wrapper avoids leaking the rest of
    // the edit-session API.
    public bool publicEditIsOpen() const { return editIsOpen(); }

private:
    // Element-falloff click-pick. Reads the GPU-resolved hover state
    // (g_hoveredVertex/Edge/Face — published by app.d after each
    // render frame) and pushes the picked element's anchor point
    // through ACEN.setUserPlaced (via notifyAcenUserPlaced). The
    // anchor depends on the FalloffStage's `elementMode`:
    //
    //   - `*Cent` variants (AutoCent / EdgeCent / PolyCent): element
    //     centroid (edge midpoint / Newell-method polygon centroid).
    //   - Non-Cent variants (Auto / Edge / Polygon): exact click-point
    //     on the element — closest point on the edge segment to the
    //     picking ray (edges) or ray ∩ face plane (polygons). This
    //     follows the per-mode distinction (e.g. `polygon` →
    //     intersection of click + polygon; `polyCent` → centroid).
    //
    // FalloffStage's connectMask is also updated (mask seed is the
    // picked element's vert ring). Pick-type restricted by the
    // stage's elementMode. Returns true iff the click landed on a
    // hovered element.
    bool tryPickElement(int mx, int my) {
        FalloffStage stage = activeFalloffStage();
        if (stage is null || stage.type != FalloffType.Element) return false;

        ElementMode em = stage.elementMode;
        bool autoMode = (em == ElementMode.Auto) || (em == ElementMode.AutoCent);
        bool wantV = autoMode || (em == ElementMode.Vertex);
        bool wantE = autoMode || (em == ElementMode.Edge)
                              || (em == ElementMode.EdgeCent);
        bool wantF = autoMode || (em == ElementMode.Polygon)
                              || (em == ElementMode.PolyCent);
        // Non-Cent variants (Auto / Edge / Polygon) use the exact
        // click-point on the element instead of its centroid.
        // EdgeCent / PolyCent / AutoCent and the *Cent-only modes
        // fall back to centroid. Vertex has no distinction (vertex
        // IS the click target).
        bool clickPointE = (em == ElementMode.Auto) || (em == ElementMode.Edge);
        bool clickPointF = (em == ElementMode.Auto) || (em == ElementMode.Polygon);

        if (wantV && g_hoveredVertex >= 0
            && g_hoveredVertex < cast(int)mesh.vertices.length)
            return takeVert(stage, g_hoveredVertex);
        if (wantE && g_hoveredEdge >= 0
            && g_hoveredEdge < cast(int)mesh.edges.length)
            return takeEdge(stage, g_hoveredEdge, clickPointE, mx, my);
        if (wantF && g_hoveredFace >= 0
            && g_hoveredFace < cast(int)mesh.faces.length)
            return takeFace(stage, g_hoveredFace, clickPointF, mx, my);
        return false;
    }

    // Per take*, two pieces are written:
    //   1. ACEN.userPlaced ← picked element's anchor point (gizmo
    //      pivot + falloff sphere anchor). Either the centroid
    //      (*Cent modes) or the exact click-point on the element.
    //   2. FalloffStage.anchorRing ← picked element's vert indices
    //      (every one gets weight=1 in elementWeight, so the picked
    //      element drags as a rigid unit regardless of sphere radius).
    // Both pieces together form the `falloff.element` internal
    // hybrid (anchor + sphere).

    bool takeVert(FalloffStage stage, int vi) {
        notifyAcenUserPlaced(mesh.vertices[vi]);
        stage.anchorRing = [cast(uint)vi];
        updateConnectMask(stage, vi);
        return true;
    }

    bool takeEdge(FalloffStage stage, int ei, bool clickPoint,
                  int mx, int my) {
        auto edge = mesh.edges[ei];
        Vec3 a = mesh.vertices[edge[0]];
        Vec3 b = mesh.vertices[edge[1]];
        Vec3 anchor = clickPoint
            ? closestPointOnSegmentToRay(a, b, cachedVp.eye,
                                         screenRay(cast(float)mx,
                                                   cast(float)my,
                                                   cachedVp))
            : (a + b) * 0.5f;
        notifyAcenUserPlaced(anchor);
        stage.anchorRing = [cast(uint)edge[0], cast(uint)edge[1]];
        updateConnectMask(stage, cast(int)edge[0]);
        return true;
    }

    bool takeFace(FalloffStage stage, int fi, bool clickPoint,
                  int mx, int my) {
        Vec3 anchor;
        bool gotClickHit = false;
        if (clickPoint) {
            // Ray ∩ face plane. The face was already hit by the
            // picker (g_hoveredFace >= 0) so the ray crosses the
            // plane; rayPlaneIntersect only returns false for ray ∥
            // plane (effectively edge-on, which the picker also
            // rejects). Fall back to the centroid if the projection
            // misbehaves — same anchor the *Cent path uses.
            Vec3 n = mesh.faceNormal(cast(uint)fi);
            Vec3 c = mesh.faceCentroid(cast(uint)fi);
            Vec3 dir = screenRay(cast(float)mx, cast(float)my, cachedVp);
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, dir, c, n, hit)) {
                anchor       = hit;
                gotClickHit  = true;
            }
        }
        if (!gotClickHit)
            anchor = mesh.faceCentroid(cast(uint)fi);
        notifyAcenUserPlaced(anchor);
        auto face = mesh.faces[fi];
        stage.anchorRing.length = face.length;
        foreach (i, vi; face)
            stage.anchorRing[i] = vi;
        if (face.length > 0)
            updateConnectMask(stage, cast(int)face[0]);
        return true;
    }


    // Per-cluster translate: each vertex is displaced along its OWN
    // cluster's axis frame (right/up/fwd from the ClusterAxes packet).
    // `delta` is in cluster-local coordinates: x=right, y=up, z=fwd.
    // Vertices not in any cluster (clusterOf[vi]==-1) are skipped.
    // No falloff support — matches the behaviour of the rotate/scale
    // kernels in Local mode (falloff + Local is an unusual combination).
    void applyTranslatePerCluster(
        TransformTool.ClusterPivots cp,
        TransformTool.ClusterAxes   ap,
        Vec3 localDelta)
    {
        import math : Vec3;
        foreach (vi; vertexIndicesToProcess) {
            if (vi < 0 || vi >= cast(int)cp.clusterOf.length) continue;
            int cid = cp.clusterOf[vi];
            if (cid < 0 || cid >= cast(int)ap.right.length) continue;
            Vec3 cr = ap.right[cid];
            Vec3 cu = ap.up   [cid];
            Vec3 cf = ap.fwd  [cid];
            Vec3 worldDelta = cr * localDelta.x
                            + cu * localDelta.y
                            + cf * localDelta.z;
            mesh.vertices[vi].x += worldDelta.x;
            mesh.vertices[vi].y += worldDelta.y;
            mesh.vertices[vi].z += worldDelta.z;
        }
        if (dragSymmetry.enabled
            && dragSymmetry.pairOf.length == mesh.vertices.length) {
            import symmetry : applySymmetryMirror;
            applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
        }
    }

    // Connected-component BFS seeded at the picked vert, written into
    // FalloffStage.connectMask. Active only when connect != Off.
    void updateConnectMask(FalloffStage stage, int seedVi) {
        if (stage.connect == ElementConnect.Off) {
            stage.connectMask = null;
            return;
        }
        size_t n = mesh.vertices.length;
        if (seedVi < 0 || seedVi >= cast(int)n) {
            stage.connectMask = null;
            return;
        }
        size_t[][] adj = new size_t[][](n);
        foreach (e; mesh.edges) {
            adj[e[0]] ~= e[1];
            adj[e[1]] ~= e[0];
        }
        bool[] visited = new bool[](n);
        size_t[] queue;
        queue ~= cast(size_t)seedVi;
        visited[seedVi] = true;
        while (queue.length > 0) {
            size_t v = queue[$ - 1];
            queue.length -= 1;
            foreach (nb; adj[v])
                if (!visited[nb]) { visited[nb] = true; queue ~= nb; }
        }
        stage.connectMask = visited;
    }

    FalloffStage activeFalloffStage() const {
        if (g_pipeCtx is null) return null;
        return cast(FalloffStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    }

    MoveTool   moveSub;
    RotateTool rotateSub;
    ScaleTool  scaleSub;

    // Sub-tool that owns the currently active drag, set on
    // mouse-down and cleared on mouse-up. Null when no drag is
    // active; in that state mouse motion goes to every enabled
    // sub-tool for hover-preview updates.
    TransformTool activeDrag;

    // Phase 3 — wrapper-owned drag state.
    //
    // `dragBaseline`: full-mesh snapshot captured at every mouse-down
    // when `moveSub` consumes the click. The per-frame `applyTRS`
    // restores ALL of `mesh.vertices` from this snapshot before
    // re-applying the chain — required because the per-cluster
    // translate kernel `applyTranslatePerCluster` is `+=` incremental
    // and symmetry mirroring touches indices outside
    // `vertexIndicesToProcess`. Reset at each drag start; the
    // tool-session edit baseline (`editBefore` in TransformTool) is
    // separate and lives longer (commit at deactivate / selection
    // change).
    Vec3[] dragBaseline;

    // `moveDragFastPath`: ONCE-PER-DRAG decision (evaluated at
    // mouse-down in `beginMoveDragSession`) for whether the per-frame
    // motion can use the zero-CPU `gpuMatrix` translation bypass
    // instead of `applyTRS`. The inputs are FROZEN for the drag's
    // duration — `dragFalloff`/`dragSymmetry` captured at mouse-down,
    // `cp.active` reflects the at-down ClusterPivots snapshot, and
    // the moving-set selection is frozen by `update()`'s
    // `dragAxis>=0` early-return at `transform.d`'s update. Do NOT
    // recompute mid-drag: the predicate cannot flip during a drag.
    bool moveDragFastPath;

    // MS-2 (rotate single-source): rotate counterpart of `moveDragFastPath`.
    // `rotDragFastPath` is the ONCE-PER-DRAG decision (evaluated in
    // `beginRotateDragSession`) for whether the whole-mesh / no-falloff /
    // no-symmetry / non-per-cluster principal-axis ring drag can use the
    // zero-CPU `gpuMatrix = pivotRotationMatrix(...)` GPU-skip bypass.
    // `rotDragAxisIdx` is the dragged ring's basis-axis index (0/1/2)
    // captured at drag start; view-ring stays legacy/exempt and leaves it -1.
    bool rotDragFastPath;
    int  rotDragAxisIdx = -1;

    // Scale single-source: scale counterpart of `moveDragFastPath` /
    // `rotDragFastPath`. `scaleDragActive` marks that the wrapper owns the
    // current scale drag's geometry + gpuMatrix (set in
    // `beginScaleDragSession`, cleared at mouseUp). `scaleDragFastPath` is the
    // ONCE-PER-DRAG decision for whether the whole-mesh / no-falloff /
    // no-symmetry / non-per-cluster drag can use the zero-CPU
    // `gpuMatrix = pivotScaleMatrixBasis(...)` GPU-skip bypass. Unlike rotate
    // there is no view-ring exemption — every scale gizmo mode is unified — so
    // a single `scaleDragActive` flag (no per-axis index) suffices.
    bool scaleDragFastPath;
    bool scaleDragActive;

    // `accumulatedWorldDelta`: total world-space translate for the
    // current drag, used to drive `gpuMatrix = translation(...)`
    // when the fast-path is active. Reset at drag start. Tracks the
    // SAME basis projection that `headlessTranslate` accumulates,
    // but expanded into a world vector for the matrix; we recompute
    // it here so the fast-path doesn't need to look at the chain's
    // per-cluster behaviour (the predicate guarantees single-cluster
    // when fast-path is on).
    Vec3 accumulatedWorldDelta;
    Vec3 accumulatedAtDragStart;

    // Forward the active sub-tool's gpuMatrix onto our public
    // `gpuMatrix` field — app.d reads `activeTool.gpuMatrix` to
    // drive u_model during whole-mesh drag bypass paths. Without
    // this the wrapper stays at identity while MoveTool /
    // RotateTool / ScaleTool internally translate / rotate / scale
    // their GPU matrix.
    void syncGpuMatrix() {
        // Phase 3 — when the active drag belongs to moveSub, the
        // wrapper OWNS gpuMatrix (set by `onMouseMotion`'s fast-
        // path branch). moveSub itself doesn't touch its own
        // gpuMatrix any more, so forwarding its identity here
        // would clobber the wrapper's drag-translate matrix every
        // frame (draw / update both call syncGpuMatrix).
        if (activeDrag is moveSub) return;

        // Same for a PRINCIPAL-AXIS rotate drag (rotDragAxisIdx 0/1/2):
        // the wrapper owns gpuMatrix (set to `pivotRotationMatrix` in the
        // fast-path branch of onMouseMotion), and rotateSub no longer writes
        // its own gpuMatrix for these axes. Forwarding rotateSub's identity
        // here every update()/draw() frame would clobber the wrapper's
        // rotation matrix between motion events — the whole-mesh cube would
        // flicker back to its drag-start pose. View-ring (idx == -1) still
        // drives rotateSub.gpuMatrix and needs the sync below.
        if (activeDrag is rotateSub
            && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 2) return;

        // Same for a scale drag (any gizmo mode): the wrapper owns gpuMatrix
        // (set to `pivotScaleMatrixBasis` in the fast-path branch of
        // onMouseMotion), and scaleSub no longer writes its own gpuMatrix
        // during a drag. Forwarding scaleSub's identity here every
        // update()/draw() frame would clobber the wrapper's scale matrix
        // between motion events — the whole-mesh cube would flicker back to
        // its drag-start size. The panel path (activeDrag is null) still
        // drives scaleSub.gpuMatrix and needs the sync below.
        if (activeDrag is scaleSub && scaleDragActive) return;

        if (activeDrag !is null) {
            gpuMatrix = activeDrag.gpuMatrix;
            return;
        }
        // Idle: sub-tools have reset to identity. Pick the first
        // enabled one's matrix (all are identity at this point).
        if      (flagT) gpuMatrix = moveSub.gpuMatrix;
        else if (flagR) gpuMatrix = rotateSub.gpuMatrix;
        else if (flagS) gpuMatrix = scaleSub.gpuMatrix;
    }
}
