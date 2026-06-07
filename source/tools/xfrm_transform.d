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
               pivotRotationMatrix, pivotScaleMatrixBasis, dot,
               identityMatrix, matMul4, wrapAboutPivot;
import editmode : EditMode;
import mesh;
import handler  : ToolHandles;
import eventlog : queryMouse;
import shader : Shader;
import params : Param;
import tools.transform : TransformTool;
import tools.move      : MoveTool;
import tools.rotate    : RotateTool;
import tools.scale     : ScaleTool;
import tools.xform_kernels :
    applyScaleFromActivation,   // dormant compoundPasses!=1 pow path only (applyTRS, F2)
    applyXformMatrix,
    BlendMode;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import perf_probe : g_perf, Cat;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.packets  : FalloffType, ElementMode, ElementConnect, FalloffPacket;
import falloff_render    : drawFalloffOverlay;
import hover_state       : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;

// MS-3.5 — runtime blend-mode toggle. The fold blends the composed matrix toward
// identity by the falloff weight; MatrixLerp (keep-b) is the decision, confirmed
// reference-correct in MS-4.1/4.2. The production default is MatrixLerp; setting
// VIBE3D_BLEND_MODE=polarquat routes the apply through the polar/quat blend
// instead so the SAME drag can be re-measured under the alternative candidate.
// The env var is read ONCE (cached in a static) — no per-vertex getenv.
private BlendMode blendModeForMeasure() @trusted nothrow {
    import std.process : environment;
    static bool resolved = false;
    static BlendMode cached = BlendMode.MatrixLerp;
    if (!resolved) {
        resolved = true;
        try {
            if (environment.get("VIBE3D_BLEND_MODE", "") == "polarquat")
                cached = BlendMode.PolarQuat;
        } catch (Exception) {
            cached = BlendMode.MatrixLerp;
        }
    }
    return cached;
}

alias VertexEditFactory = MeshVertexEdit delegate();

// Part-id bases for the shared cross-bank handle arbiter. Each bank
// registers its local handle ids (0..6) at its base so overlapping
// handles at the shared gizmo center get distinct global part ids. The
// falloff base (100) hosts the single wrapper-owned FalloffGizmo, which
// registers FIRST (highest test priority) so a falloff endpoint handle
// wins over a co-located gizmo arrow — matching the click-dispatch order.
private enum int MOVE_BASE = 0, ROT_BASE = 10, SCALE_BASE = 20, FALLOFF_BASE = 100;

class XfrmTransformTool : TransformTool {
public:
    // T/R/S flags — `T integer 0/1` etc. in the preset config.
    // Default to all enabled (the bare `Transform` preset that shows
    // all three handler banks). Preset loader flips these per-preset
    // before the first activate().
    bool flagT = true;
    bool flagR = true;
    bool flagS = true;
    // MODO-style handle family selector: 0=Move, 1=Rotate, 2=Scale,
    // 3=Uniform Scale. Presentation is separate: bare Transform uses
    // compact combined handles, while per-mode presets use the full bank.
    int handleFamily = 0;
    string handlePresentation = "compact";

    // Headless TRS attrs — always exposed regardless of flag state
    // so scripted callers can set TX with R=1 S=1 without first
    // flipping flags. Defaults: 0 for translate / rotate, 1 for scale.
    Vec3 headlessTranslate = Vec3(0, 0, 0);
    Vec3 headlessRotate    = Vec3(0, 0, 0);
    Vec3 headlessScale     = Vec3(1, 1, 1);

    // Attr-state baseline captured at session OPEN (the closed->open
    // transition in beginEdit() below). cancelUncommittedEdit() restores these
    // alongside the vertices so the Tool-Properties values the panel/form read
    // (TX/TY/TZ etc. via params(), :361) snap back to their session-start state
    // on an in-session Ctrl+Z — without this the geometry reverts but the
    // numeric fields keep the stale edited values. Only meaningful while a
    // wrapper edit session is open; resetTransientState() zeroes the live attrs
    // on activate / resyncSession, so the commit (tool-drop) path is unaffected.
    private Vec3 attrBaseTranslate = Vec3(0, 0, 0);
    private Vec3 attrBaseRotate    = Vec3(0, 0, 0);
    private Vec3 attrBaseScale     = Vec3(1, 1, 1);

    // Per-gesture action-center pin START, captured from the LIVE pin at session
    // OPEN (the closed->open transition in beginEdit() below) — the gesture-START
    // value the Move commitEdit pin-revert hook restores (W1 fix). The frozen
    // snapshot (snapPlaced/snapPlacedCenter) holds the PRE-relocate pin staged at
    // the LAST relocate, which is the right in-flight cancel baseline but the
    // WRONG gesture-START for the 2nd+ plain on-gizmo gesture within one
    // userPlaced run (no boundary → no re-stage → the frozen value is stale, from
    // a relocate possibly a prior run). The live pin AT beginEdit IS this
    // gesture's true start: for a plain gesture it equals the previous gesture's
    // sticky-follow end; for a relocate-opened gesture beginEdit fires AFTER
    // setUserPlaced+restage so it captures the relocated pin (correct stepping —
    // undoing the haul returns to the relocate point, undoing further pops the
    // prior entry whose hooks restore the pre-relocate pin). gesturePinStartKnown
    // gates the capture so commitEdit can fall back to inert hooks when no
    // beginEdit-open preceded it (e.g. a relocate-boundary no-op commit).
    private bool gesturePinStartKnown   = false;
    private bool gesturePinStartPlaced  = false;
    private Vec3 gesturePinStartCenter  = Vec3(0, 0, 0);

    // MS-4.5 — the composed pivot-relative matrix the GLOBAL fold built on the
    // last applyGlobalFold (origin-fixing) plus the pivot it used. The GPU
    // fast-path (whole-mesh / no-falloff, which always takes the fold) reuses
    // THIS matrix — `gpuMatrix = wrapAboutPivot(lastFoldMatrix, lastFoldPivot)` —
    // instead of rebuilding a parallel about-pivot rotation/scale matrix, so the
    // GPU preview is the literal same transform the CPU fold applied.
    float[16] lastFoldMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    Vec3      lastFoldPivot  = Vec3(0, 0, 0);

    // View-ring rotate — the arbitrary-axis counterpart of `headlessRotate`.
    // `headlessRotate.{x,y,z}` are rotations about the basis axes bX/bY/bZ;
    // the view-ring rotates about the camera-forward axis, which is NOT one of
    // those three, so it cannot be expressed as three Euler angles without
    // breaking falloff (three independently weighted basis rotations ≠ one
    // weighted rotation about an arbitrary axis at fractional falloff weight).
    // MS-3.4: this is NO LONGER a persistent slot — it is threaded into
    // `applyTRS` as a transient (viewAxis, viewAngleDeg) parameter pair, set
    // only by the live view-ring drag (the onMouseMotion `ax == 3` branch) and
    // defaulted to zero everywhere else (panel Euler, numeric RX/RY/RZ).
    // mouseUp uploads the already-rotated CPU mesh rather than re-applying from
    // baseline, so the rotation is needed only during the synchronous per-frame
    // applyTRS call — a transient parameter is sufficient.

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        moveSub   = new MoveTool  (mesh, gpu, editMode);
        rotateSub = new RotateTool(mesh, gpu, editMode);
        scaleSub  = new ScaleTool (mesh, gpu, editMode);
        toolHandles = new ToolHandles();
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
        super.activate();   // sets active=true, runs resetTransientState()
        // One-time activation wiring (NOT part of resyncSession): bring the
        // composed sub-tools online and back-link them to this wrapper.
        if (flagT) moveSub.activate();
        if (flagR) rotateSub.activate();
        if (flagS) scaleSub.activate();
        moveSub.wrapperRef = this;
        rotateSub.wrapperRef = this;   // MS-2: rotate single-source plumbing
        scaleSub.wrapperRef = this;    // scale single-source plumbing

        // Record+consolidate: a fresh run opens for this tool session. Allocate a
        // run id so this session's gestures are tagged distinctly from any prior
        // session's, and route per-gesture commits through recordInSession while
        // the tool is live — each commitEdit then lands as a tagged in-session
        // entry that consolidate() collapses at a boundary / drop.
        //   - the WRAPPER's own (Move) commits route via this.recordViaInSession.
        //   - the R/S sub-tools' commits route via THEIR recordViaInSession
        //     (Phase 2): set them here so a per-gesture ring/scale commit and the
        //     R/S session's drop/boundary commit both land in-session, sharing the
        //     same history.currentRunId. recordViaInSession is protected (no
        //     sibling cross-instance write), so flip it through the public
        //     setRecordViaInSession() mirror.
        if (history !is null) history.nextRun();
        recordViaInSession = true;
        if (flagR) rotateSub.setRecordViaInSession(true);
        if (flagS) scaleSub.setRecordViaInSession(true);
        currentRunBank     = DragBank.None;
    }

    // Wrapper-level transient reset (undo/redo migration P1). Extends the base
    // TransformTool.resetTransientState() with the wrapper-owned headless TRS
    // accumulators and per-drag fast-path state. Shared by activate() and
    // resyncSession() so the two can't drift. Touches only drag-invariant
    // bookkeeping (no open edit exists when resyncSession() runs); the one-time
    // sub-tool activation + wrapperRef wiring stays in activate().
    protected override void resetTransientState() {
        super.resetTransientState();
        headlessTranslate         = Vec3(0, 0, 0);
        headlessRotate            = Vec3(0, 0, 0);
        headlessScale             = Vec3(1, 1, 1);
        activeDrag                = null;
        dragBaseline.length       = 0;
        moveDragFastPath          = false;
        rotDragFastPath           = false;
        rotDragAxisIdx            = -1;
        scaleDragFastPath         = false;
        scaleDragActive           = false;
        accumulatedWorldDelta     = Vec3(0, 0, 0);
        accumulatedAtDragStart    = Vec3(0, 0, 0);
        gesturePinStartKnown      = false;
        // In-session falloff re-grade state — no live gesture, no anchor.
        lastAppliedGestureMutationVersion = ulong.max;
        refireAnchor.length               = 0;
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
        // Tool drop (record+consolidate): consolidate the FINAL run's in-session
        // tail into one surviving entry. A clean multi-gesture run therefore
        // collapses to ONE undo entry at the drop (one post-drop Ctrl+Z reverts
        // the whole run); a session that already consolidated at a boundary
        // leaves that surviving entry untouched (no-op gather). Done AFTER the
        // sub-tool deactivate commits so the final consolidate sees this run's
        // whole tagged tail — including any R/S drop commit those deactivates
        // just landed in-session (Phase 2). Stop in-session routing afterwards
        // (wrapper + R/S sub-tools, the symmetric clear of the activate() set).
        if (history !is null) history.consolidate(history.currentRunId);
        recordViaInSession   = false;
        if (flagR) rotateSub.setRecordViaInSession(false);
        if (flagS) scaleSub.setRecordViaInSession(false);
        currentRunBank       = DragBank.None;
        // Tool drop: no live gesture, no re-grade anchor carries to the next
        // activation (resetTransientState also clears these on (re)activate).
        lastAppliedGestureMutationVersion = ulong.max;
        refireAnchor.length               = 0;
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
                // Session-close work stays editIsOpen()-gated (harmless no-op
                // once gestures self-commit on mouse-up). Run-close work gates
                // on history.runOpen() — the single source of truth for "is
                // there a run to close?" — so the run still splits at a
                // selection/mutation boundary even when the prior gesture
                // already closed its session per-gesture.
                if (editIsOpen())
                    commitEdit("Move");
                // Selection / mutation change is a run boundary
                // (record+consolidate, Phase 1 addendum A4): consolidate the
                // open run + bump the run id so the next gesture is tagged
                // distinctly. (The foreign select/edit record that drove this
                // change would also consolidate the open run via the
                // command_history layer-A guard; doing it here keeps the
                // boundary explicit and resets the bank.) Defensive tidy — no
                // test depends on this site (selection-change mid-run is forced
                // before any in-run record).
                if (history !is null && history.runOpen()) {
                    history.consolidate(history.currentRunId);
                    history.nextRun();
                    currentRunBank = DragBank.None;
                    // Run boundary: invalidate the re-grade anchor + staleness
                    // stamp so a falloff change after a selection/mutation
                    // boundary cannot re-grade the just-closed run.
                    lastAppliedGestureMutationVersion = ulong.max;
                    refireAnchor.length               = 0;
                }
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
        //
        // Two-arm branch (R3/R4):
        //  - ARM 1 (panel session, editIsOpen() true): the OLD in-place
        //    coalesce. A panel session (driven by tool.attr at idle) is its own
        //    coalescing world — the re-apply folds into the session's single
        //    drop commit, records nothing. UNCHANGED behaviour.
        //  - ARM 2 (committed gizmo gesture, editIsOpen() false but the run is
        //    open with a landed Move gesture): the NEW record path. The re-grade
        //    is baked as a tagged in-session entry in the current run so the
        //    in-session Ctrl+Z contract holds.
        if (activeDrag is null
            && dragBaseline.length == mesh.vertices.length
            && (headlessTranslate.x != 0
             || headlessTranslate.y != 0
             || headlessTranslate.z != 0)) {
            if (editIsOpen()) {
                // ARM 1 — panel session: old in-place coalesce, no record.
                FalloffPacket live = currentFalloff(vts);
                if (!falloffPacketsEqual(live, dragFalloff)) {
                    dragFalloff = live;
                    vertexCacheDirty = true;
                    applyTRSForBank(DragBank.Move, dragBaseline);
                    needsGpuUpdate = true;
                }
            } else if (history !is null
                    && history.runOpen()
                    && currentRunBank == DragBank.Move           // OBJ-2 single-winner
                    && mesh.mutationVersion == lastAppliedGestureMutationVersion) {
                // ARM 2 — committed gizmo gesture: re-grade + record.
                // Staleness gate (OBJ-1) checked at the SITE before the recompute
                // mutates the mesh; the helper re-checks as defense-in-depth.
                FalloffPacket live = currentFalloff(vts);
                if (!falloffPacketsEqual(live, dragFalloff)) {
                    // Capture the pre-recompute (post-gesture) geometry LIVE for
                    // the once-per-run anchor (OBJ-3 W1: live, never frozen).
                    Vec3[] anchor = mesh.vertices.dup;
                    dragFalloff = live;
                    vertexCacheDirty = true;
                    applyTRSForBank(DragBank.Move, dragBaseline);   // mutates mesh.vertices
                    Vec3[] after = mesh.vertices.dup;

                    // Index set = the full vertex range; the helper diffs against
                    // the anchor and keeps only moved verts. (The falloff support
                    // can be the whole mesh, so a full-range pass is the safe
                    // superset.)
                    size_t[] allIdx;
                    allIdx.length = mesh.vertices.length;
                    foreach (i; 0 .. allIdx.length) allIdx[i] = i;

                    recordFalloffRefire("Falloff", anchor, after,
                                        allIdx, DragBank.Move);
                    needsGpuUpdate = true;
                }
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
        if (activeDrag is moveSub)
            setSharedGizmoPose(moveSub.handler.center, vts);
        else if (activeDrag is rotateSub)
            setSharedGizmoPose(rotateSub.handler.center, vts);
        else if (activeDrag is scaleSub)
            setSharedGizmoPose(scaleSub.handler.center, vts);
        else
            setSharedGizmoPose(queryActionCenter(vts), vts);
        syncGpuMatrix();
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        if (!active) return;
        cachedVp = vp;

        // Live falloff packet: frozen snapshot during a gizmo drag, live
        // (so the overlay/handles follow a dragged endpoint) otherwise.
        FalloffPacket fp = (activeDrag !is null) ? dragFalloff : currentFalloff(vts);
        if (activeDrag is moveSub)
            setSharedGizmoPose(moveSub.handler.center, vts);
        else if (activeDrag is rotateSub)
            setSharedGizmoPose(rotateSub.handler.center, vts);
        else if (activeDrag is scaleSub)
            setSharedGizmoPose(scaleSub.handler.center, vts);
        else
            setSharedGizmoPose(queryActionCenter(vts), vts);

        // Cross-bank single-winner hover/capture (MODO's two-pass hit-test → draw):
        // ONE shared arbiter over the falloff handles (registered first =
        // highest priority) + every enabled gizmo bank, resolve ONE
        // hot/captured part, THEN render.
        toolHandles.begin();
        if (fp.enabled) {
            ensureFalloffGizmo();
            falloffGizmo.registerHandles(toolHandles, FALLOFF_BASE, fp);
        }
        if (flagT) {
            if (compactPresentation()) moveSub.registerCompactHandles(toolHandles, MOVE_BASE);
            else                       moveSub.registerHandles    (toolHandles, MOVE_BASE);
        }
        if (flagR) {
            if (compactPresentation()) rotateSub.registerPrincipalHandles(toolHandles, ROT_BASE);
            else                       rotateSub.registerHandles         (toolHandles, ROT_BASE);
        }
        if (flagS) {
            if (compactPresentation()) scaleSub.registerAxisHandles(toolHandles, SCALE_BASE);
            else                       scaleSub.registerHandles    (toolHandles, SCALE_BASE);
        }
        // Capture precedence: a live falloff-handle drag wins; else the active
        // gizmo bank's dragAxis; scale suppresses all highlight during its drag.
        if      (falloffGizmo !is null && falloffGizmo.isDragging())  toolHandles.setHaul(falloffGizmo.capturedPart(FALLOFF_BASE));
        else if (activeDrag is moveSub   && moveSub.dragAxis   >= 0)  toolHandles.setHaul(MOVE_BASE  + moveSub.dragAxis);
        else if (activeDrag is rotateSub && rotateSub.dragAxis >= 0)  toolHandles.setHaul(ROT_BASE   + rotateSub.dragAxis);
        else if (activeDrag is scaleSub  && scaleSub.dragAxis  >= 0)  toolHandles.suppress();
        else                                                          toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        if (flagT) {
            if (compactPresentation()) moveSub.drawCompact (shader, vp, vts);
            else                       moveSub.draw        (shader, vp, vts);
        }
        if (flagR) {
            if (compactPresentation()) rotateSub.drawPrincipalOnly(shader, vp, vts);
            else                       rotateSub.draw             (shader, vp, vts);
        }
        if (flagS) {
            if (compactPresentation()) scaleSub.drawAxisBoxesOnly(shader, vp, vts);
            else                       scaleSub.draw             (shader, vp, vts);
        }

        // Falloff overlay + handles drawn ONCE, on top of the gizmo banks.
        drawFalloffOverlay(fp, vp);
        if (fp.enabled) { ensureFalloffGizmo(); falloffGizmo.draw(shader, vp, fp); }

        syncGpuMatrix();
    }

    override Param[] params() {
        return [
            Param.bool_ ("T",  "Translate", &flagT, true),
            Param.bool_ ("R",  "Rotate",    &flagR, true),
            Param.bool_ ("S",  "Scale",     &flagS, true),
            Param.int_  ("H",  "Handle Family", &handleFamily, 0).hidden(),
            Param.enum_ ("presentation", "Handle Presentation",
                         &handlePresentation,
                         [["compact", "Compact"], ["full", "Full"]],
                         "compact").hidden(),
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

    // When the config-driven transform form is rendering (forms_engine_plan.md
    // Phase 5 + 5b), it OWNS ALL the TRS value rows — Position (TX/TY/TZ),
    // Rotate (RX/RY/RZ) and Scale (SX/SY/SZ) — and drives them through the
    // reEvaluate() seam (a plain `interactive` tool.attr per axis). The legacy
    // moveSub/rotateSub/scaleSub.drawProperties() sliders must therefore NOT
    // also render, or two live widgets would fight over the same per-frame
    // edit (headlessTranslate / the rotate-scale activation deltas) and the
    // panel would show each value row TWICE — once readable (form, left labels)
    // and once with the old right-of-widget labels (the unreadability the
    // rework targets). app.d raises this latch for the frame in which it drew
    // the transform form. Default false keeps the legacy panel intact for the
    // VIBE3D_FORMS=0 kill-switch and any non-form caller.
    public bool suppressTRSProperties = false;

    override void drawProperties() {
        if (suppressTRSProperties) return;   // form owns all TRS value rows
        if (flagT) moveSub.drawProperties();
        if (flagR) rotateSub.drawProperties();
        if (flagS) scaleSub.drawProperties();
    }

    // ----- Embed seam (Edge Extend Phase 4a, doc/edge_extend_plan.md §4.1
    //       option (b)) ---------------------------------------------------
    //
    // A HOST tool (EdgeExtendTool) embeds an XfrmTransformTool purely for its
    // gizmo banks + the shared ToolHandles arbiter, and routes the Move gesture
    // into its OWN op params (re-evaluating a kernel each tick) WITHOUT ever
    // letting this wrapper own the geometry. These thin accessors expose state
    // the wrapper already holds; they touch no apply path.
    //
    // The Move bank's gizmo center — the host uses it to anchor the haul drag
    // and (in 4b) as the action-center pivot.
    public Vec3 moveGizmoCenter() const { return moveSub.handler.center; }

    private void setSharedGizmoPose(Vec3 center, ref VectorStack vts) {
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);
        if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);
    }

    private bool compactPresentation() const {
        return handlePresentation == "compact";
    }

    // Direct handle to the embedded Move sub-tool so the host can drive the Move
    // GESTURE without routing through the wrapper's drain+applyTRS. MoveTool is a
    // pure gesture-scalar producer: its onMouseButtonDown / onMouseMotion /
    // onMouseButtonUp set dragAxis + write pendingTranslateDelta and NEVER mutate
    // mesh.vertices or open the wrapper's edit session (those moved to the
    // wrapper). So the host forwards the gesture events here, drains the scalar,
    // and applies geometry through ITS OWN kernel re-run.
    public MoveTool moveBank() { return moveSub; }
    // Rotate / Scale bank handles (Edge Extend Phase 4b, §4.1 option (b)). Same
    // contract as moveBank(): thin accessors so the host can forward the gesture
    // events to whichever bank the shared arbiter selected and drain the pending
    // gesture scalars (rotateSub.pendingRotate* / scaleSub.pendingScale*) WITHOUT
    // routing through the wrapper's drain+applyTRS. RotateTool / ScaleTool are
    // pure gesture-scalar producers (no geometry mutation, no wrapper edit
    // session) exactly like MoveTool. No apply-path change.
    public RotateTool rotateBank() { return rotateSub; }
    public ScaleTool  scaleBank()  { return scaleSub; }
    // Public forwarder to the protected TransformTool.queryActionCenter so the
    // host can read the ACEN center to FREEZE as the kernel pivot at drag-start
    // (§4.4). Pivot-agnostic for 4a's Offset path; the seam R/S needs in 4b.
    public Vec3 actionCenter(ref VectorStack vts) { return queryActionCenter(vts); }

    // consumesFalloff is inherited from TransformTool (NeedsFalloff flag).

    // Element-falloff hover gating — DYNAMIC, depends on the active
    // falloff stage's element mode, so this stays a method override
    // rather than a static Hover* flag.
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

        // Falloff endpoint handles claim the click first (Linear/Radial),
        // at the wrapper now that it owns the single FalloffGizmo.
        if (e.button == SDL_BUTTON_LEFT) {
            FalloffPacket curFp = currentFalloff(vts);
            if (falloffGizmo !is null && falloffGizmo.onMouseButtonDown(e, cachedVp, curFp)) {
                activeDrag = null;   // falloff owns the drag, no gizmo bank
                return true;
            }
        }

        // Dispatch to the first enabled sub-tool that consumes the
        // event. When a click hits a registered shared handle, dispatch only
        // to that handle's bank; otherwise the Move bank may consume a
        // rotate/scale click as an off-gizmo relocate before R/S see it.
        int hitPart = -1;
        if (e.button == SDL_BUTTON_LEFT) {
            toolHandles.begin();
            if (flagT) {
                if (compactPresentation()) moveSub.registerCompactHandles(toolHandles, MOVE_BASE);
                else                       moveSub.registerHandles       (toolHandles, MOVE_BASE);
            }
            if (flagR) {
                if (compactPresentation()) rotateSub.registerPrincipalHandles(toolHandles, ROT_BASE);
                else                       rotateSub.registerHandles         (toolHandles, ROT_BASE);
            }
            if (flagS) {
                if (compactPresentation()) scaleSub.registerAxisHandles(toolHandles, SCALE_BASE);
                else                       scaleSub.registerHandles    (toolHandles, SCALE_BASE);
            }
            hitPart = toolHandles.test(e.x, e.y, cachedVp);
            if (compactPresentation() && flagS) {
                int scaleHeadAxis = scaleSub.hitTestAxisHeads(e.x, e.y);
                if (scaleHeadAxis >= 0)
                    hitPart = SCALE_BASE + scaleHeadAxis;
            }
        }
        bool hitMoveBank  = hitPart >= MOVE_BASE  && hitPart < MOVE_BASE  + 10;
        bool hitRotBank   = hitPart >= ROT_BASE   && hitPart < ROT_BASE   + 10;
        bool hitScaleBank = hitPart >= SCALE_BASE && hitPart < SCALE_BASE + 10;
        bool allowMoveDispatch  = hitPart < 0 || hitMoveBank;
        bool allowRotDispatch   = compactPresentation()
            ? hitRotBank
            : (hitPart < 0 || hitRotBank);
        bool allowScaleDispatch = compactPresentation()
            ? hitScaleBank
            : (hitPart < 0 || hitScaleBank);

        if (flagT && allowMoveDispatch && moveSub.onMouseButtonDown(e, vts)) {
            // An off-gizmo click-relocate during a live session is a new
            // logical run: commit the prior run, then re-stage the
            // relocated pin so the fresh session freezes IT (not the stale
            // pre-relocate pin) as its in-session-cancel baseline. The
            // move edit session lives on the wrapper, so the commit must
            // run here, not on moveSub. Ordering is load-bearing:
            // setUserPlaced (in moveSub.onMouseButtonDown, no stage while
            // frozen) → commitEdit (discards snapshot, clears freeze) →
            // restageRelocatePin (stages relocated pin) →
            // beginMoveDragSession → beginEdit (re-freezes relocated pin).
            bool wasRelocate = moveSub.lastClickWasRelocate;
            moveSub.lastClickWasRelocate = false;   // consume
            // Phase 1 addendum A1 — split session-close vs run-close at the
            // Move-arm relocate boundary. The three landed `if (wasRelocate ...)`
            // blocks merge into one, with each action gated on what it actually
            // depends on:
            //   - commitEdit("Move") + the R/S commitSessionIfOpen mirrors stay
            //     SESSION-close work (gated on editIsOpen()/an open R/S session).
            //     Under per-gesture commit the Move session is normally already
            //     closed at this boundary, so commitEdit is a harmless no-op
            //     (buildEditCmd returns null when !editCapturing).
            //   - restageRelocatePin() is RUN-close work that must fire on the
            //     RELOCATE itself, UNCONDITIONAL on wasRelocate (NOT session-
            //     open): the pin was just moved by this relocate and the next
            //     gesture's beginEdit freezes it. Lifting it out of the
            //     editIsOpen() guard is the load-bearing addendum fix — after a
            //     per-gesture commit editIsOpen() is false, so the old gate
            //     never re-staged the relocated pin.
            //   - consolidate + nextRun is RUN-close work gated on
            //     history.runOpen() (the single source of truth) so the run
            //     splits even when the gesture already self-committed.
            // Ordering is load-bearing: commitEdit (discards the prior session's
            // snapshot, clears freeze) → restageRelocatePin (stages the relocated
            // pin) → beginMoveDragSession → beginEdit (re-freezes the relocated
            // pin). A-RISK-2: when wasRelocate fires as the very first
            // interaction (no session, no run), restageRelocatePin only stages
            // the ACEN pin from the already-staged userPlaced state — a safe,
            // idempotent stage that does not require a session — and runOpen() is
            // false so the consolidate/nextRun is skipped.
            if (wasRelocate) {
                if (editIsOpen()) commitEdit("Move");   // session-close (no-op once self-committed)
                moveSub.restageRelocatePin();           // run-close: UNCONDITIONAL on relocate
                // Cross-slot (symmetric): in a composed T+R+S preset an R/S
                // session may ALSO be open (a prior rotate/scale ring drag). A
                // Move relocate is a new run for EVERY open session, so close the
                // R/S sub-tool sessions too. commitSessionIfOpen() is a public
                // mirror on the sub-tool (the wrapper cannot call their protected
                // commitEdit cross-instance). No-op in single-mode presets.
                rotateSub.commitSessionIfOpen();
                scaleSub.commitSessionIfOpen();
                // Hard run boundary: collapse the open run's tagged in-session
                // entries into ONE surviving entry, then open a fresh run id so
                // the next gesture is tagged distinctly.
                if (history !is null && history.runOpen()) {
                    history.consolidate(history.currentRunId);
                    history.nextRun();
                }
            }
            // Bank-switch run boundary (Q-c): a switch INTO Move from a prior
            // R/S run consolidates that run first. After a Move relocate above,
            // currentRunBank is INTENTIONALLY left at Move (the wasRelocate block
            // does NOT reset it): the gesture this relocate opens IS the
            // relocate's own screen-plane Move drag, so the run stays a Move run.
            // noteRunBank(Move) is therefore a same-bank no-op here (the prior run
            // was already consolidated by the wasRelocate block above), and the
            // relocated-pin Move gesture extends the freshly-opened Move run.
            noteRunBank(DragBank.Move);
            beginMoveDragSession(vts);
            setSharedGizmoPose(moveSub.handler.center, vts);
            activeDrag = moveSub;  return true;
        }
        if (flagR && allowRotDispatch && rotateSub.onMouseButtonDown(e, vts)) {
            // Principal-axis ring (0/1/2) AND view-ring (3) → wrapper owns
            // geometry via applyTRS (capture the drag state). Principal axes
            // drain into headlessRotate (Euler); the view-ring drains into the
            // transient applyTRS view-axis/angle params. A relocate / no-axis click
            // (dragAxis == -1) starts no drag session.
            if (rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3) {
                // Bank-switch run boundary (Q-c): a switch INTO Rotate from a
                // prior Move/Scale run consolidates that run first, before the
                // fresh single-bank rotate run opens. No-op when the prior run
                // was already Rotate. With Phase 2 R/S recording live, the run
                // being consolidated here is whatever bank's tagged tail just
                // ended (Move, or a prior Rotate/Scale run after a relocate).
                noteRunBank(DragBank.Rotate);
                beginRotateDragSession(vts);
            } else {
                rotDragAxisIdx = -1;
                // Relocate / no-axis click run boundary (Phase 2). rotateSub's
                // own onMouseButtonDown relocate branch already committed any
                // OPEN rotate session (in-session now) and mirrored the wrapper's
                // Move commit, but it does NOT close the RUN. After a per-gesture
                // ring commit the session is already closed yet the run is still
                // open (the self-committed entry), so consolidate it into one
                // surviving entry + open a fresh run id here — mirroring the
                // Move-arm relocate boundary (A1). Gated on history.runOpen() (the
                // single source of truth) so it splits even when the gesture
                // already self-committed; a safe no-op on an empty/closed run.
                if (history !is null && history.runOpen()) {
                    history.consolidate(history.currentRunId);
                    history.nextRun();
                    currentRunBank = DragBank.None;
                }
            }
            activeDrag = rotateSub; return true;
        }
        if (flagS && allowScaleDispatch && scaleSub.onMouseButtonDown(e, vts)) {
            // Scale single-source: a real gizmo drag (dragAxis >= 0 — any
            // of single-axis 0/1/2, uniform disc 3, plane circle 4/5/6)
            // → wrapper owns geometry via applyTRS (capture the drag
            // state). A falloff-handle grab or click-relocate leaves
            // dragAxis == -1 and starts no scale session.
            if (scaleSub.dragAxis >= 0) {
                // Bank-switch run boundary (Q-c): a switch INTO Scale from a
                // prior Move/Rotate run consolidates that run first. No-op when
                // the prior run was already Scale. With Phase 2 R/S recording
                // live, the consolidated run is whatever bank's tagged tail just
                // ended.
                noteRunBank(DragBank.Scale);
                beginScaleDragSession(vts);
            } else {
                scaleDragActive = false;
                // Relocate / no-axis click run boundary (Phase 2), mirroring the
                // rotate arm: scaleSub's relocate branch committed any open scale
                // session + the wrapper's Move mirror, but does NOT close the RUN.
                // After a per-gesture scale commit the session is closed yet the
                // run is still open, so consolidate + open a fresh run here.
                if (history !is null && history.runOpen()) {
                    history.consolidate(history.currentRunId);
                    history.nextRun();
                    currentRunBank = DragBank.None;
                }
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
            // The element pick IS a relocate (it re-anchored ACEN to the
            // picked element's centroid via tryPickElement →
            // notifyAcenUserPlaced at the top of this method). If a Move
            // run is already open (prior haul drags accumulated), this
            // pick is an in-session relocate boundary: commit the prior
            // run before the haul opens a new session, mirroring the
            // common Move relocate boundary (Phase 1a) — except here the
            // relocate condition is `picked && flagT`, not
            // `moveSub.lastClickWasRelocate` (this branch never routes
            // through moveSub.onMouseButtonDown).
            //
            // Ordering is load-bearing (same snapFrozen trap as Phase 1a):
            //   pick → setUserPlaced (no stage while snapFrozen, BEFORE this) →
            //   commitEdit (discards frozen snapshot, clears snapFrozen) →
            //   restageActionCenterPin (re-fires the picked anchor, now stages) →
            //   beginScreenPlaneDragAt(notifyAcen=false) (does NOT re-push the
            //     pin — the pick already owns it, so without the restage above
            //     the new session would freeze a STALE pre-pick baseline) →
            //   beginMoveDragSession → beginEdit (freezes the PICKED pin).
            // commitEdit keeps the picked element anchor permanent, so the
            // element-falloff sphere anchor (state.actionCenter.center) is
            // unchanged across the boundary.
            // Phase 1 addendum A2 — split session-close vs run-close at the
            // element-pick boundary, mirroring A1:
            //   - commitEdit("Move") stays SESSION-close (editIsOpen()-gated;
            //     no-op once the prior gesture self-committed).
            //   - restageActionCenterPin() is RUN-close work tied to the pick
            //     (the relocate here), UNCONDITIONAL — the pick just moved the
            //     pin and the next session's beginEdit freezes it. Lifting it
            //     out of the editIsOpen() guard is the load-bearing fix (after a
            //     per-gesture commit editIsOpen() is false, so the old gate
            //     never re-staged the picked anchor).
            if (editIsOpen()) commitEdit("Move");   // session-close (no-op once self-committed)
            moveSub.restageActionCenterPin();       // run-close: UNCONDITIONAL on pick
            // Cross-slot (symmetric): an element-pick relocate, like any
            // relocate, commits EVERY open session — close any open R/S sub-tool
            // session too (composed preset). No-op in single-mode.
            rotateSub.commitSessionIfOpen();
            scaleSub.commitSessionIfOpen();
            // Hard run boundary (addendum A2): the element-pick relocate ends the
            // open run — consolidate its in-session tail into one surviving
            // entry, then open a fresh run id. Gated on history.runOpen() (the
            // single source of truth) so the run splits even when the prior
            // gesture already self-committed its session.
            if (history !is null && history.runOpen()) {
                history.consolidate(history.currentRunId);
                history.nextRun();
            }
            // The fresh screen-plane drag below is a Move gesture; record its
            // bank (no-op switch when the prior run was also Move).
            noteRunBank(DragBank.Move);
            Vec3 pivot = queryActionCenter(vts);
            // notifyAcen=false because tryPickElement already wrote
            // userPlaced (notifyAcenUserPlaced) — don't overwrite it
            // with the ray-hit point.
            moveSub.beginScreenPlaneDragAt(e.x, e.y, pivot,
                                           ctrlMod, /*notifyAcen=*/false, vts);
            beginMoveDragSession(vts);
            setSharedGizmoPose(moveSub.handler.center, vts);
            activeDrag = moveSub;
            syncGpuMatrix();
            return true;
        }

        // Phase 5 — off-gizmo commit boundary in relocate-DISALLOWED modes.
        // The click landed OFF every gizmo bank AND was not an element pick.
        // In a relocate-PERMITTED mode (Auto/None/Screen) the move bank above
        // would have consumed it as a relocate (Phase 1a); reaching here on a
        // plain LMB-down means the action center mode is relocate-DISALLOWED
        // (Select/SelectAuto/Element/Local/Origin/Manual/Border) — the click
        // is inert as far as the pivot goes (moveSub declined it). The
        // reference still SPLITS the undo run on such a click even though
        // nothing visibly relocates: the trigger is the off-gizmo mouse-DOWN
        // itself. Match it by committing EVERY open session (the cross-slot
        // rule, Phase 2) WITHOUT relocating — the next drag then opens a fresh
        // session = a separate undo entry.
        //
        // Gates:
        //  - LEFT button only, with NO camera-nav modifiers. app.d dispatches
        //    Alt+LMB (orbit) / Alt+Shift+LMB (pan) / Ctrl+Alt+LMB (zoom) to the
        //    tool FIRST (handleMouseButtonDown:2899-2902, before the
        //    DragMode branch at :2914), so a modified click DOES reach here;
        //    excluding modifiers keeps camera navigation between drags from
        //    splitting the run. (ImGui-panel clicks never reach the tool at
        //    all: processSdlEvent:4094-4099 returns early on WantCaptureMouse
        //    in interactive use, so panel-edit coalescing is safe.) This is the
        //    same `plain` filter the element-pick PRE-step uses (:489-491).
        //  - At least one open session (wrapper Move OR an R/S sub-tool). No
        //    open session ⇒ fully inert: no commit, no empty undo entry.
        // The commit set MIRRORS the Phase 1a cross-slot commit (Move on the
        // wrapper, R/S on the sub-tools). After the commit, re-stage the
        // current pin VERBATIM (stageCurrentActionCenterPin — no relocate, no
        // userPlaced mutation) so the next session's beginEdit freezes the
        // un-changed pin as its cancel baseline rather than a stale snapPlaced
        // (the commit's discardUserPlacedSnapshot cleared the freeze; without
        // the re-stage an in-session cancel in Element mode would yank the
        // pivot to a pin two sessions old). NB the next drag's beginEdit is
        // NOT opened here — this is a no-relocate, no-drag boundary; the
        // subsequent gizmo grab opens the fresh session on its own mouse-down.
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods2 = SDL_GetModState();
            bool plain2 = (mods2 & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0;
            // Phase 1 addendum A3 — split session-close vs run-close at the P5
            // off-gizmo-in-relocate-DISALLOWED boundary.
            //   - commitEdit("Move") + the R/S commitSessionIfOpen mirrors stay
            //     SESSION-close work (editIsOpen()/open-R/S-gated); harmless
            //     no-op once the gesture self-committed on mouse-up.
            //   - the verbatim stageCurrentActionCenterPin() is RUN-close work
            //     (the P5 analog of A1/A2's relocate restages): it re-stages the
            //     CURRENT pin (in Element mode, the picked anchor) as the NEXT
            //     gesture's in-session-cancel baseline. Under per-gesture commit
            //     editIsOpen() is FALSE at this boundary (gesture 1 already
            //     self-committed its haul), so leaving the re-stage inside the
            //     editIsOpen() arm would never fire it ⇒ the next gesture freezes
            //     a STALE pin and an in-session cancel yanks the pivot. So it
            //     LIFTS OUT of the editIsOpen() arm, gated on the boundary
            //     actually firing (plain2 + an open run) — pin behavior stays
            //     observably identical to the old open-session flow.
            //   - the run-close work (consolidate + nextRun + bank reset) gates
            //     on history.runOpen() so the run SPLITS even when the prior
            //     gesture already self-committed.
            bool p5Boundary = plain2 && history !is null && history.runOpen();
            if (plain2 &&
                (editIsOpen() || rotateSub.publicEditIsOpen()
                              || scaleSub.publicEditIsOpen())) {
                if (editIsOpen()) commitEdit("Move");   // session-close (no-op once self-committed)
                rotateSub.commitSessionIfOpen();
                scaleSub.commitSessionIfOpen();
            }
            // Run-close: verbatim re-stage of the current pin (NOT a relocate —
            // pin unchanged) so the next gesture freezes the picked anchor, plus
            // the consolidate/nextRun/bank-reset that SPLITS the run. p5Boundary
            // gates on plain2 + runOpen() (a modified nav click does not split;
            // runOpen() is the single source of truth for "a run to close").
            if (p5Boundary) {
                moveSub.stageCurrentActionCenterPin();
                history.consolidate(history.currentRunId);
                history.nextRun();
                currentRunBank = DragBank.None;
            }
        }
        return false;
    }

    private void resetGestureAttrs() {
        headlessTranslate = Vec3(0, 0, 0);
        headlessRotate    = Vec3(0, 0, 0);
        headlessScale     = Vec3(1, 1, 1);
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

        resetGestureAttrs();
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

        resetGestureAttrs();   // zero ALL axes (S1) and neutralize prior drags

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

        resetGestureAttrs();

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
        if (falloffGizmo !is null && falloffGizmo.isDragging())
            return falloffGizmo.onMouseMotion(e, cachedVp);
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
                headlessRotate = Vec3(0, 0, 0);
                headlessScale  = Vec3(1, 1, 1);
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
                applyTRSForBank(DragBank.Move, dragBaseline);

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
                setSharedGizmoPose(moveSub.handler.center, vts);
            }
        } else if (activeDrag is rotateSub) {
            r = rotateSub.onMouseMotion(e, vts);
            // Drain the gesture scalar rotateSub published this motion into the
            // wrapper-owned rotate state and run the single applyTRS evaluate.
            // Principal axes (0/1/2) → headlessRotate (Euler about bX/bY/bZ).
            // View-ring (3) → transient applyTRS view-axis/angle params
            // (axis-angle about the camera-forward axis). Both share applyTRS +
            // the fast-path bypass.
            if (r && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 3) {
                int   ax  = rotateSub.pendingRotateAxis;
                float ang = rotateSub.pendingRotateAngle;
                rotateSub.pendingRotateAxis = -1;
                if (ax >= 0 && ax <= 2) {
                    import std.math : PI;
                    float deg = ang * 180.0f / cast(float)PI;
                    // Absolute-from-baseline: only the dragged axis is set;
                    // beginRotateDragSession zeroed all three (S1).
                    headlessTranslate = Vec3(0, 0, 0);
                    headlessScale     = Vec3(1, 1, 1);
                    headlessRotate = Vec3(0, 0, 0);
                    if      (ax == 0) headlessRotate.x = deg;
                    else if (ax == 1) headlessRotate.y = deg;
                    else              headlessRotate.z = deg;

                    // CPU is rebuilt from the drag baseline EVERY frame so it
                    // is never stale at mouseUp (round-1/3 B3; landed-move
                    // parity). The fast-path then merely skips the per-frame
                    // vertex re-upload — the GPU keeps the baseline buffer and
                    // u_model = pivotRotationMatrix bridges the rotation.
                    applyTRSForBank(DragBank.Rotate, dragBaseline);
                    if (rotDragFastPath) {
                        // MS-4.5 — reuse the matrix applyTRS's fold just built
                        // (wrapped about its pivot) rather than rebuilding a
                        // parallel about-pivot rotation. Whole-mesh/no-falloff
                        // fast-path always takes the global fold, so it is fresh.
                        gpuMatrix = wrapAboutPivot(lastFoldMatrix, lastFoldPivot);
                    } else {
                        needsGpuUpdate = true;
                    }
                } else if (ax == 3) {
                    import std.math : PI;
                    float deg = ang * 180.0f / cast(float)PI;
                    // Absolute-from-baseline: the running view-axis angle this
                    // drag has accumulated, about the camera-forward axis the
                    // producer captured. Euler slot stays zeroed (S1).
                    // MS-3.4: the view-ring rotation is now a TRANSIENT applyTRS
                    // parameter — no persistent slot to set/clear.
                    headlessTranslate = Vec3(0, 0, 0);
                    headlessScale     = Vec3(1, 1, 1);
                    headlessRotate = Vec3(0, 0, 0);
                    Vec3  viewAxisLocal = rotateSub.pendingRotateViewAxis;
                    float viewDegLocal  = deg;
                    applyTRSForBank(DragBank.Rotate, dragBaseline,
                                    viewAxisLocal, viewDegLocal);
                    if (rotDragFastPath) {
                        // MS-4.5 — reuse the fold's composed matrix (view-ring
                        // rotation included) wrapped about its pivot.
                        gpuMatrix = wrapAboutPivot(lastFoldMatrix, lastFoldPivot);
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
                headlessTranslate = Vec3(0, 0, 0);
                headlessRotate    = Vec3(0, 0, 0);
                headlessScale = f;

                // CPU is rebuilt from the drag baseline EVERY frame so it is
                // never stale at mouseUp. The fast-path then merely skips the
                // per-frame vertex re-upload — the GPU keeps the baseline
                // buffer and u_model = pivotScaleMatrixBasis bridges the scale.
                applyTRSForBank(DragBank.Scale, dragBaseline);
                if (scaleDragFastPath) {
                    // MS-4.5 — reuse the fold's composed scale matrix wrapped
                    // about its pivot instead of rebuilding it here.
                    gpuMatrix = wrapAboutPivot(lastFoldMatrix, lastFoldPivot);
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
        if (falloffGizmo !is null && falloffGizmo.onMouseButtonUp(e))
            return true;
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
        // refreshed mesh state.
        if (wasMoveDrag && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate   = false;
            moveDragFastPath = false;

            // Per-gesture commit (record+consolidate, Phase 1): each move drag
            // is its own atomic gesture, baked to history at mouse-up as a
            // tagged in-session entry (recordViaInSession is true while the tool
            // is live). The next LMB-down reopens a fresh edit session (beginEdit
            // via beginMoveDragSession) at the grab point, so two consecutive
            // drags land as TWO in-session entries — one Ctrl+Z steps each — that
            // consolidate into ONE surviving entry at the run boundary / drop.
            // Within a single drag the per-pixel increments already coalesce
            // structurally (one applyTRS(baseline) per motion → one commitEdit
            // here). Committing on mouse-up also means there is NO open gizmo
            // session at idle, which keeps the in-session Ctrl+Z contract clean
            // (navHistory pops one gesture, tool stays live). The panel/forms
            // path is untouched: it opens its session via reEvaluate /
            // applyMovePanelDelta (never this gizmo mouse-up) and stays coalesced
            // until drop. discardAcenUserPlacedSnapshot stays on commitEdit
            // (Q-b): the next gesture's beginEdit re-freezes the pin.
            if (editIsOpen())
                commitEdit("Move");

            // In-session falloff re-grade — staleness stamp (OBJ-1). Record the
            // mesh version this gesture left behind: a later falloff tweak at
            // idle re-grades this gesture ONLY while the version still matches.
            // An in-session Ctrl+Z reverts geometry (bumps the version away from
            // the stamp), so the re-grade site then refuses — a popped gesture is
            // never resurrected.
            lastAppliedGestureMutationVersion = mesh.mutationVersion;

            // Open a FRESH re-fire window for this gesture. A run can hold more
            // than one gesture (g1 -> tweak -> g2 -> tweak), and a tweak after g2
            // must anchor before[] to the post-g2 geometry, NOT the stale post-g1
            // snapshot. Clearing here makes each gesture start a fresh window:
            // the next re-grade re-captures the anchor live. (The drop's
            // consolidate still reverts every touched vert to the run-start state
            // via mergeRun's first-touch before[], so the per-gesture window only
            // governs the SINGLE in-session Ctrl+Z granularity, exactly C.)
            refireAnchor.length = 0;
        }

        // Rotate drag (principal axes OR view-ring) — wrapper owns the final
        // upload + gpuMatrix reset (CPU verts were rebuilt by applyTRS every
        // frame, so this uploads the already-rotated mesh; no stale-CPU, B3).
        // MS-3.4: the view-ring rotation was a transient applyTRS parameter,
        // not a persistent slot, so there is nothing to clear here — a later
        // panel/falloff re-apply drives applyTRS with the default (zero) view
        // rotation. The edit SESSION lives on rotateSub.
        if (rotWrapperOwned && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate  = false;
            rotDragFastPath = false;
            rotDragAxisIdx  = -1;

            // Per-gesture commit (record+consolidate, Phase 2): each ring drag
            // bakes a tagged in-session entry on mouse-up (rotateSub's commitEdit
            // attaches the angleAccum/propDeg hooks + routes via recordCommit,
            // which is in-session because the wrapper set rotateSub's routing flag
            // at activate). The next ring grab reopens a fresh rotateSub session,
            // so two consecutive ring drags are two in-session entries that
            // consolidate into one at the boundary / drop — mirroring the Move
            // mouse-up commit above. Committing here also CLOSES the rotate
            // sub-tool session at idle, which flips case (d): an in-session Ctrl+Z
            // now pops one gesture rather than cancelling the whole open run.
            rotateSub.commitGesture();
        }

        // Scale single-source — wrapper owns the final upload + gpuMatrix
        // reset (CPU verts were rebuilt by applyTRS every frame, so this
        // uploads the already-scaled mesh; no stale-CPU). The edit SESSION
        // lives on scaleSub.
        if (wasScaleDrag && e.button == SDL_BUTTON_LEFT) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate    = false;
            scaleDragFastPath = false;
            scaleDragActive   = false;

            // Per-gesture commit (record+consolidate, Phase 2): mirrors the
            // rotate path above — each scale drag bakes a tagged in-session entry
            // on mouse-up (scaleSub's commitEdit attaches the scaleAccum/propScale
            // hooks + routes in-session), the next handle grab reopens a fresh
            // scaleSub session, and the run consolidates at the boundary / drop.
            scaleSub.commitGesture();
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
    private bool applyTRSForBank(DragBank bank, Vec3[] baseline,
                                 Vec3 viewAxis = Vec3(0, 0, 0),
                                 float viewAngleDeg = 0) {
        bool oldT = flagT, oldR = flagR, oldS = flagS;
        final switch (bank) {
            case DragBank.None:
                break;
            case DragBank.Move:
                flagT = true;  flagR = false; flagS = false;
                break;
            case DragBank.Rotate:
                flagT = false; flagR = true;  flagS = false;
                break;
            case DragBank.Scale:
                flagT = false; flagR = false; flagS = true;
                break;
        }
        scope(exit) { flagT = oldT; flagR = oldR; flagS = oldS; }
        return applyTRS(baseline, viewAxis, viewAngleDeg);
    }

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
    bool applyTRS(Vec3[] baseline, Vec3 viewAxis = Vec3(0, 0, 0),
                  float viewAngleDeg = 0) {
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

        // MS-4.3/4.4 — canonical-matrix FOLD. The whole T->R->S chain is composed
        // into ONE pivot-relative matrix (per cluster in the ACEN.Local case) and
        // applied through a SINGLE `applyXformMatrix` call, blended toward identity
        // per vertex by ONE falloff weight at the BASELINE position — see
        // `applyFold`. MS-4.1/4.2 proved this is what the reference does (one
        // composed matrix, one baseline weight; multi-axis rotate + combined
        // T+R+S + per-cluster translate-under-falloff all reproduce exactly), and
        // it is what fixes the per-cluster-translate-falloff divergence. Only the
        // dormant `pow(scale, passes)` path (no matrix form, F2) keeps the legacy
        // per-pass `else` chain below.
        //
        // The decomposed state fields (headlessTranslate / headlessRotate /
        // headlessScale) + the transient view-ring params (viewAxis / viewAngleDeg,
        // MS-3.4) remain the input attributes that BUILD the matrix.
        // `mesh.vertices` already holds the restored baseline.
        {
            import std.math : PI, fabs;

            // Each pass's matrix kernel takes an ORDINAL-parallel source buffer
            // (source[k] is the current position of vertex
            // vertexIndicesToProcess[k]) — see applyXformMatrix's array-layout
            // contract. ordinalSrc() gathers the LIVE post-prior-pass positions
            // for the moving set so each pass reads the previous pass's output.
            Vec3[] ordinalSrc() {
                auto s = new Vec3[](vertexIndicesToProcess.length);
                foreach (k, vi; vertexIndicesToProcess)
                    s[k] = (vi >= 0 && vi < cast(int)mesh.vertices.length)
                         ? mesh.vertices[vi] : Vec3(0, 0, 0);
                return s;
            }

            bool hasT = flagT && (headlessTranslate.x != 0
                              || headlessTranslate.y != 0
                              || headlessTranslate.z != 0);
            bool hasS = flagS && (headlessScale.x != 1
                              || headlessScale.y != 1
                              || headlessScale.z != 1);

            // MS-4.3/4.4 — fold: compose T->R->S into ONE pivot-relative matrix
            // (per cluster in the ACEN.Local case) and apply it once with ONE
            // baseline-position weight (the reference model, validated in
            // MS-4.1/4.2 globally and the per-cluster translate-weighting captured
            // in per_cluster_translate_falloff_bug). Only the dormant pow-scale
            // path falls through to the legacy per-pass chain below (no matrix
            // form, F2). At w==1 the fold is bit-equivalent to the chain (same
            // factor order), so the w==1 suite gates the compose; under fractional
            // falloff the fold is the validated change.
            float passesS = dragFalloff.compoundPasses > 0.0f
                          ? dragFalloff.compoundPasses : 1.0f;
            bool powScale = hasS && fabs(passesS - 1.0f) > 1e-4f;
            if (!powScale) {
                applyFold(baseline, pivot, bX, bY, bZ, cp, ap,
                          hasT, hasS, viewAxis, viewAngleDeg);
            } else {

            // ---- T pass -------------------------------------------------------
            if (hasT) {
                if (cp.active && ap.active) {
                    // Per-cluster translate: falloff-EXEMPT (w==1, no falloff),
                    // signed per-cluster axes — matches applyTranslatePerCluster.
                    // One pivot-relative translation matrix per cluster from its
                    // OWN right/up/fwd frame, selected per vertex via clusterM.
                    float[16][] clusterM;
                    clusterM.length = ap.right.length;
                    foreach (cid; 0 .. ap.right.length) {
                        Vec3 wd = ap.right[cid] * headlessTranslate.x
                                + ap.up[cid]    * headlessTranslate.y
                                + ap.fwd[cid]   * headlessTranslate.z;
                        clusterM[cid] = translationMatrix(wd);
                    }
                    FalloffPacket noFo;  noFo.enabled = false;   // w==1 exempt
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot, identityMatrix, blendModeForMeasure(),
                                     noFo, cachedVp, cp, ap, clusterM,
                                     dragSymmetry, toProcess);
                } else {
                    // Global basis: delta = bX·TX + bY·TY + bZ·TZ; weight at the
                    // LIVE position (source == weightVerts == current scratch),
                    // matching applyTranslateIncremental.
                    Vec3 delta = bX * headlessTranslate.x
                               + bY * headlessTranslate.y
                               + bZ * headlessTranslate.z;
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot, translationMatrix(delta),
                                     blendModeForMeasure(),
                                     dragFalloff, cachedVp, cp, ap, null,
                                     dragSymmetry, toProcess);
                }
            }

            // ---- R.x / R.y / R.z + view-ring passes --------------------------
            // Each rotation about a basis axis (or per-cluster axis,
            // dragAxisIdx 0/1/2); weight at the LIVE position. Per-cluster
            // rotate is LIVE-weighted, NOT falloff-exempt (unlike per-cluster
            // translate). The matrix is origin-fixing; applyXformMatrix
            // re-applies the (possibly per-cluster) pivot.
            if (flagR) {
                if (headlessRotate.x != 0)
                    applyRotatePass(bX, 0,
                        headlessRotate.x * cast(float)(PI / 180.0),
                        pivot, cp, ap, &ordinalSrc);
                if (headlessRotate.y != 0)
                    applyRotatePass(bY, 1,
                        headlessRotate.y * cast(float)(PI / 180.0),
                        pivot, cp, ap, &ordinalSrc);
                if (headlessRotate.z != 0)
                    applyRotatePass(bZ, 2,
                        headlessRotate.z * cast(float)(PI / 180.0),
                        pivot, cp, ap, &ordinalSrc);

                // View-ring rotation: a single rotation about the arbitrary
                // camera-forward axis. dragAxisIdx == -1 keeps the axis as-is
                // (no per-cluster substitution) and applies one weighted
                // rotation about one axis (correct under falloff). A view
                // rotation is global by definition. Nonzero only during a live
                // view-ring drag.
                bool hasViewRot = viewAngleDeg != 0
                    && (viewAxis.x != 0
                     || viewAxis.y != 0
                     || viewAxis.z != 0);
                if (hasViewRot)
                    applyRotatePass(viewAxis, -1,
                        viewAngleDeg * cast(float)(PI / 180.0),
                        pivot, cp, ap, &ordinalSrc);
            }

            // ---- S pass -------------------------------------------------------
            if (hasS) {
                // compoundPasses != 1 (Selection/flex falloff's scale pow) has
                // NO matrix expression (plan F2). The matrix path cannot carry
                // it, so route this one pass through the per-component scale
                // kernel — which applies pow(s_eff, compoundPasses) for real —
                // exactly as the legacy chain did. compoundPasses is published
                // 1.0 everywhere in the current tree, so the matrix branch is
                // the live path; this preserves the dormant pow path correctly.
                float passes = dragFalloff.compoundPasses > 0.0f
                             ? dragFalloff.compoundPasses : 1.0f;
                if (fabs(passes - 1.0f) > 1e-4f) {
                    Vec3[] activation = mesh.vertices.dup;
                    // Per-vert weight at the pre-chain BASELINE position.
                    applyScaleFromActivation(mesh, vertexIndicesToProcess,
                                             activation, pivot,
                                             bX, bY, bZ,
                                             headlessScale,
                                             dragFalloff, cachedVp,
                                             cp, ap, dragSymmetry, toProcess,
                                             baseline);
                } else {
                    // Matrix path. Source = current scratch (post-T/R), gathered
                    // ordinal-parallel; weight at the pre-chain BASELINE
                    // (weightVerts == baseline, mesh-length vid-indexed). The
                    // scale matrix is origin-fixing (built around Vec3(0));
                    // applyXformMatrix re-applies the pivot. Per-cluster scale
                    // uses each cluster's OWN right/up/fwd frame (matching the
                    // per-component kernel's axesFor()), selected via clusterM.
                    float[16][] clusterM = null;
                    if (cp.active && ap.active) {
                        clusterM = new float[16][](ap.right.length);
                        foreach (cid; 0 .. ap.right.length)
                            clusterM[cid] = pivotScaleMatrixBasis(
                                Vec3(0, 0, 0),
                                ap.right[cid], ap.up[cid], ap.fwd[cid],
                                headlessScale.x, headlessScale.y,
                                headlessScale.z);
                    }
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot,
                                     pivotScaleMatrixBasis(Vec3(0, 0, 0),
                                         bX, bY, bZ,
                                         headlessScale.x, headlessScale.y,
                                         headlessScale.z),
                                     blendModeForMeasure(),
                                     dragFalloff, cachedVp, cp, ap, clusterM,
                                     dragSymmetry, toProcess,
                                     /*weightVerts=*/ baseline);
                }
            }
            }  // MS-4.3 — close legacy per-pass else (per-cluster / pow-scale)
        }

        // (MS-3.6) The MS-2 measure-only per-pass shadow was retired here: it
        // reconstructed the LEGACY decomposed T->R->S chain and compared it to
        // the live apply, but MS-4.3/4.4 deliberately replaced that chain with the
        // canonical-matrix fold (which diverges from the per-pass reconstruction
        // under fractional falloff — the validated correctness change), so the
        // shadow now guarded a superseded model. The fold is gated instead by the
        // reference-parity fixtures (tests/fixtures/falloff_{rot,trs,local}_*.json,
        // tests/test_fixture_falloff_*).

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
        // Euler-slot path: applyTRS defaults the transient view-ring rotation
        // to zero (MS-3.4), so a prior view-ring drag cannot re-apply on top.
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
        // Numeric path uses RX/RY/RZ (Euler slot) only — the view-ring rotation
        // has no numeric attr, so applyTRS's transient param defaults to zero.
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

        // Delta path: capture/open the session, accumulate the slider's
        // per-frame diff onto the live translate, then replay from the session
        // baseline. captureDragBaselineIfStale() reports whether it captured a
        // fresh `dragBaseline` this call; we zero `headlessTranslate` ONLY then
        // (the first-active-frame — accumulation starts from zero). Zeroing on
        // every call would wipe the prior cumulative. The += sits between the
        // capture and applyTRS, so we can't reuse replayTranslateFromBaseline()
        // (which does capture-then-apply with nothing in between).
        bool freshBaseline = captureDragBaselineIfStale();
        if (freshBaseline)
            headlessTranslate = Vec3(0, 0, 0);
        headlessTranslate = headlessTranslate + basisLocalDelta;
        applyTRS(dragBaseline);
        needsGpuUpdate = true;
    }

    // Shared session-setup + capture step for the panel-delta and value-driven
    // (reEvaluate) replay paths. Builds the local vector stack, captures the
    // live falloff / symmetry, builds the vertex cache, opens the edit session
    // (idempotent), and captures a fresh full-mesh `dragBaseline` IFF the
    // current one is stale (length mismatch). Returns true when it captured a
    // fresh baseline this call.
    //
    // CRITICAL: this body does NOT zero `headlessTranslate`. The zeroing is
    // coupled to the delta accumulation and lives in applyMovePanelDelta()'s
    // prologue (gated on the returned bool). If it lived here, reEvaluate()
    // acting as a session-opener would wipe the just-injected absolute
    // translate before applyTRS, applying 0.0 on the first edit.
    private bool captureDragBaselineIfStale() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);

        // captureFalloffForDrag / captureSymmetryForDrag overwrite `dragFalloff`
        // / `dragSymmetry` every call; that's fine — for slider / attr edits we
        // want the live falloff to take effect immediately.
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        buildVertexCacheIfNeeded();
        beginEdit();   // idempotent

        // Pin the wrapper-owned selection/mutation tracking to the CURRENT mesh
        // state at the moment the session opens. activate() seeds these to
        // uint.max/ulong.max ("everything changed") so the first update() rebuilds
        // the gizmo/cache. For a gizmo drag that's harmless — the session opens at
        // mouse-down AFTER update() has already run and synced the tracking. But a
        // headless panel/attr edit (openLiveSessionForTest / reEvaluate) opens the
        // session BETWEEN frames, so without this the very next update() would see
        // curMutVer != ulong.max, treat the just-opened session as a user
        // selection/topology change, and commitEdit() it shut — leaving
        // hasLiveEval()==false so the following tool.attr moves nothing. Under
        // heavy -j the frame timing makes this fire intermittently (the residual
        // test_reevaluate Test-4 flake). Opening the session is NOT a user change,
        // so seed the tracking exactly as the post-commit branch of update() would.
        lastSelectionHash   = computeSelectionHash();
        lastMutationVersion = mesh.mutationVersion;

        // Panel/attr baseline: when no gizmo drag is open the panel/attr edit is
        // the only active write path, so we capture a fresh dragBaseline at the
        // first-active-frame. A subsequent edit re-uses this baseline
        // (length-equal check). Refreshing it every frame would zero out the
        // prior cumulative — keep stale ones.
        if (dragBaseline.length != mesh.vertices.length) {
            dragBaseline.length = mesh.vertices.length;
            foreach (i; 0 .. mesh.vertices.length)
                dragBaseline[i] = mesh.vertices[i];
            return true;
        }
        return false;
    }

    // Value-driven replay (Decision D1): open the session if needed, capture a
    // fresh baseline if stale, then re-run applyTRS from `dragBaseline` reading
    // the CURRENT (already-injected) `headlessTranslate` ABSOLUTELY — no delta
    // accumulation, no zeroing of `headlessTranslate`. Keys off `dragBaseline`
    // (full-mesh, length-equal to mesh.vertices), NOT editBaseline() which is
    // partial and reordered (see :277-282) and would trip applyTRS's length
    // assert. Shared by reEvaluate() and the panel-delta path's setup.
    private void replayTranslateFromBaseline() {
        captureDragBaselineIfStale();
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
    override public bool publicEditIsOpen() const { return editIsOpen(); }

    // True iff any R/S sub-tool owns an open edit session. Rotate/Scale keep
    // their geometry sessions on the sub-tools (MS-5), so the wrapper's own
    // editIsOpen() does NOT see them — this folds them in.
    private bool subToolEditOpen() const {
        return rotateSub.publicEditIsOpen() || scaleSub.publicEditIsOpen();
    }

    // True while ANY gizmo bank's drag is in flight (mouse held). The R/S
    // sub-tools read this through their wrapperRef to gate their idle-time
    // falloff re-apply (Q5 / brief item 5): an R/S sub-tool's own dragAxis
    // already guards ITS bank, but in a composed preset a DIFFERENT bank (Move)
    // could be mid-drag while the R/S session sits open — recording a falloff
    // re-apply entry underneath that in-flight gesture must not happen. Public
    // so the sub-tools (siblings) can query it cross-instance.
    public bool dragInFlight() const { return activeDrag !is null; }

    // Phase 2 — cross-slot relocate boundary. In a composed T+R+S preset
    // (Transform / xfrm.transform) two sessions can be open at once: the Move
    // session on this wrapper, the R/S sessions on the sub-tool instances. A
    // relocate on ANY slot is a new logical run and must commit EVERY open
    // session, not just the clicked slot's — otherwise the wrapper's open Move
    // run leaks across the boundary into the next gesture.
    //
    // This is the WRAPPER side: called from the R/S sub-tools' click-relocate
    // branches (via their `wrapperRef` cast) so an off-axis ring/handle click
    // that commits the R/S session ALSO closes any open Move run. Public so the
    // sibling sub-tools can reach it (D `protected` does not grant sibling
    // cross-instance access; `editIsOpen()` / `commitEdit()` are protected on
    // TransformTool). The Move side (a Move relocate committing open R/S
    // sessions) is symmetric and lives in onMouseButtonDown via the sub-tools'
    // own public `commitSessionIfOpen()` mirrors. In a single-mode preset the
    // wrapper Move session is never open here → no-op.
    public void commitMoveSessionIfOpen() {
        if (!editIsOpen()) return;
        // Cross-slot boundary commit (Phase 2) — symmetric to the R/S
        // commitSessionIfOpen mirrors: this closes the wrapper's open Move
        // session when an R/S relocate fires on a DIFFERENT slot. The Move
        // session is NOT part of the R/S bank's run, so route it PLAIN — a plain
        // record() trips the layer-A foreign-record guard to consolidate any open
        // run first, landing this Move entry as its OWN surviving entry rather
        // than merged into the R/S bank's in-session tail (which would violate
        // single-bank-per-run and collapse two surviving entries into one).
        bool wasInSession = recordViaInSession;
        recordViaInSession = false;
        scope(exit) recordViaInSession = wasInSession;
        commitEdit("Move");
    }

    // Session-open chokepoint override: every path that opens the wrapper edit
    // session funnels through beginEdit() (gizmo drag via beginMoveDragSession,
    // panel slider / numeric attr via captureDragBaselineIfStale, test opener).
    // On the closed->open transition we snapshot the current headless TRS attrs
    // so cancelUncommittedEdit() can restore the exact values the panel/form was
    // displaying when the session started. Idempotent re-opens (editIsOpen()
    // already true) must NOT re-snapshot — that would capture mid-edit values
    // and defeat the restore. super.beginEdit() is itself idempotent.
    protected override void beginEdit() {
        bool wasOpen = editIsOpen();
        super.beginEdit();
        if (!wasOpen && editIsOpen()) {
            attrBaseTranslate = headlessTranslate;
            attrBaseRotate    = headlessRotate;
            attrBaseScale     = headlessScale;
            // Freeze the action-center pin baseline alongside the attr/vertex
            // baseline. A click-away / element-pick relocate fired
            // setUserPlaced() on the preceding mouse-down (BEFORE this session
            // opened) and staged the PRE-relocate pin state there; freezing it
            // now adopts that staged state as the cancel baseline. Relocates
            // during this open session no longer re-stash. Idempotent re-opens
            // skip this — the first freeze of the session wins, like attrBase*.
            if (auto ac = activeAcenStage()) {
                ac.freezeUserPlacedSnapshot();
                // W1 fix: capture this gesture's pin-START from the LIVE pin NOW,
                // not from the frozen snapshot at commit time. The frozen snapshot
                // is the PRE-relocate pin (correct in-flight cancel baseline) but
                // is stale as a gesture-START for the 2nd+ plain gesture in a
                // userPlaced run (no boundary re-stages it). The live pin here IS
                // this gesture's true start — for a relocate-opened gesture this
                // fires AFTER setUserPlaced+restage, so it captures the relocated
                // pin (the correct START for stepping; see the field comment).
                gesturePinStartPlaced = ac.isUserPlaced();
                gesturePinStartCenter = ac.currentPinCenter();
                gesturePinStartKnown  = true;
            }
        }
    }

    // Per-gesture Move commit (record+consolidate, addendum-2): attach PIN HOOKS
    // to the recorded entry, exactly as RotateTool/ScaleTool attach their
    // accumulator hooks (rotate.d:264-271 verbatim shape: build cmd → setHooks →
    // recordCommit). The wrapper only ever commits the MOVE slot (R/S gestures
    // self-commit through their own sub-tool commitEdit via commitSessionIfOpen),
    // so this override is Move-exclusive and leaves R/S routing untouched.
    //
    // Under per-gesture commit each Move mouse-up records a tagged in-session
    // entry and DISCARDS the frozen pin snapshot (no open session at idle). The
    // in-session Ctrl+Z is now a plain history.undo()/redo() — so the pin must
    // ride the ENTRY: revert restores the gesture-START pin (the LIVE pin this
    // gesture's beginEdit captured into gesturePinStart* — W1 fix, NOT the frozen
    // snapshot), apply restores the gesture-END pin (the current pin at mouse-up,
    // post sticky-follow). A plain history step then snaps the action center
    // per-step for free; consolidate()'s first.revert + last.apply splice gives
    // the merged run entry run-START / run-END pin semantics for free.
    //
    // The gesture-START is the LIVE pin captured at beginEdit (gesturePinStart*),
    // so commit no longer needs to read it before the base commit's
    // discardUserPlacedSnapshot(). When no gesture-START was captured (a commit
    // with no preceding beginEdit-open —
    // e.g. a relocate-boundary commit on an already-closed session: a no-op cmd)
    // fall back to the current pin for BOTH endpoints, making the hooks inert.
    protected override void commitEdit(string label) {
        if (suppressCommit) { cancelEdit(); return; }

        // pin-START — the LIVE pin captured at this gesture's beginEdit
        // (closed->open), NOT the frozen snapshot (W1 fix). The frozen snapshot
        // holds the PRE-relocate pin staged at the last relocate, which is stale
        // as a gesture-START for the 2nd+ plain gesture in a userPlaced run (no
        // boundary re-stages it). gesturePinStart* was captured from
        // isUserPlaced()/currentPinCenter() at beginEdit, so it equals this
        // gesture's true start in every case (plain = prior gesture's
        // sticky-follow end; relocate-opened = the relocated pin). Consume the
        // capture (clear known) so a follow-on commit with no preceding
        // beginEdit-open (e.g. a relocate-boundary no-op) falls back to inert.
        bool startPlaced = false;
        Vec3 startCenter = Vec3(0, 0, 0);
        bool startKnown  = gesturePinStartKnown;
        if (startKnown) {
            startPlaced = gesturePinStartPlaced;
            startCenter = gesturePinStartCenter;
        }
        gesturePinStartKnown = false;

        // Base commit discards the frozen pin snapshot, then builds + records the
        // cmd via recordCommit. We replicate the body so we can splice setHooks
        // between buildEditCmd and recordCommit (buildEditCmd returns null on a
        // no-op gesture — nothing to hook).
        discardAcenUserPlacedSnapshot();
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        // pin-END — current pin at mouse-up. If the gesture-START pin was never
        // captured (no preceding beginEdit-open), use the current pin for START
        // too so the hooks are inert (no pin jump on undo of a gesture that never
        // moved the pin).
        bool endPlaced = false;
        Vec3 endCenter = Vec3(0, 0, 0);
        if (auto ac = activeAcenStage()) {
            endPlaced = ac.isUserPlaced();
            endCenter = ac.currentPinCenter();
        }
        if (!startKnown) { startPlaced = endPlaced; startCenter = endCenter; }

        cmd.setHooks(
            // apply (redo): restore the gesture-END pin + publish.
            () {
                if (auto ac = activeAcenStage())
                    ac.restorePinState(endPlaced, endCenter);
            },
            // revert (undo): restore the gesture-START pin + publish.
            () {
                if (auto ac = activeAcenStage())
                    ac.restorePinState(startPlaced, startCenter);
            },
        );
        recordCommit(cmd);
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // Commit guard: the wrapper-owned edit session commits from deactivate()
    // (:225), update() on selection/mutation change (:254) and BrushReset
    // mouse-up (:887) — every one gated by editIsOpen(). So the exact "a
    // commit would fire if the wrapper session ended now" predicate IS
    // editIsOpen().
    //
    // Widened (in-session R/S cancel) to ALSO see an open R/S sub-tool session,
    // BUT ONLY WHEN NO GIZMO DRAG IS IN FLIGHT (`activeDrag is null`). R/S keep
    // their geometry sessions on the sub-tools (MS-5); a PANEL value edit opens
    // such a session at IDLE (mouse not held), and today the P0 Ctrl+Z
    // chokepoint missed it entirely — navHistory saw hasUncommittedEdit()==false
    // and popped a prior committed step (or no-op'd on an empty stack) while the
    // geometry stayed transformed. Folding subToolEditOpen() in lets
    // cancelUncommittedEdit() abort that open R/S run instead.
    //
    // The `activeDrag is null` clause is load-bearing — it preserves today's
    // MID-GIZMO-DRAG semantics EXACTLY. During an R/S gizmo drag the sub-tool
    // session is open with the mouse HELD (`activeDrag !is null`), and a Ctrl+Z
    // then must behave as it does today: this predicate stays false (assuming no
    // wrapper T session), so navHistory falls through to history.undo() — it does
    // NOT cancel the live drag. After mouse-UP the drag is released
    // (`activeDrag = null`) but the R/S session stays open (gizmo mouse-up does
    // not commit — per-gesture coalescing), so a Ctrl+Z at THAT point now cancels
    // the open run (a deliberate behavior change, consistent with the D6
    // whole-open-run-cancel contract: the open run reverts first, committed runs
    // pop after).
    override bool hasUncommittedEdit() const {
        return editIsOpen() || (subToolEditOpen() && activeDrag is null);
    }

    // ----- Live re-evaluation hooks (attr edit re-runs a live tool) ---------
    //
    // "live" exactly when a transform edit session is open — on the WRAPPER (T)
    // OR on a sub-tool (R/S, MS-5). This drives the attr/pipe re-eval trigger
    // (attr.d / pipe.d): a value edit re-runs the apply only when a session is
    // already open. An attr edit on a fresh tool (no open session) therefore
    // stores the value and moves nothing (faithful). Widened in forms Phase 5b
    // to include the sub-tool sessions so an R/S value edit re-evaluates.
    override bool hasLiveEval() const {
        return editIsOpen() || subToolEditOpen();
    }

    // Re-run the live transform from the session baseline using the CURRENT
    // (already-injected) headless attrs, ABSOLUTELY (Decision D1). Per active
    // flag:
    //   - flagT → replayTranslateFromBaseline() (equivalent to applyMovePanelDelta
    //     minus the delta accumulation / headlessTranslate zeroing).
    //   - flagR → rotateSub.applyRotatePanelValue(headlessRotate) — re-runs the
    //     absolute rotate from RotateTool's origVertices baseline.
    //   - flagS → scaleSub.applyScalePanelValue(headlessScale) — re-runs the
    //     absolute scale from ScaleTool's activationVertices baseline.
    // (forms plan Phase 5b widened this body from the prior T-only seam — the
    // gate, trigger sites and the `interactive` discriminator are unchanged.)
    //
    // NOTE: do NOT early-return on !editIsOpen(). reEvaluate() must also be able
    // to OPEN the session for the forms command-trigger path; the embedded
    // beginEdit() + capture-if-stale (in replayTranslateFromBaseline) / each
    // sub-tool's beginEdit() does that. The "fire only when already-live OR
    // forms-interactive" gate lives in the attr command, not here.
    override void reEvaluate() {
        // Foot-gun retired (was a silent `if (!flagT) return;`): a re-eval against
        // a preset whose every relevant flag is off would silently no-op, looking
        // like the seam is broken when it is simply out of scope. Surface it.
        if (!flagT && !flagR && !flagS) {
            return;
        }
        // T always re-runs (its baseline replay is harmless at zero translate
        // and the wrapper session is the all-flags preset's "is-live" primer).
        if (flagT) replayTranslateFromBaseline();
        // Only DRIVE R/S when their value is actually non-identity. Each apply
        // opens the sub-tool's edit session via beginEdit(); doing so for an
        // IDENTITY rotate/scale (e.g. the user only edited TX on an all-flags
        // preset) would open an idle session that the OTHER slot's geometry then
        // dirties, recording a spurious "Rotate"/"Scale" entry. Mirrors the
        // hasT/hasS guards inside applyTRS.
        bool hasR = flagR && (headlessRotate.x != 0 || headlessRotate.y != 0
                                                     || headlessRotate.z != 0);
        bool hasS = flagS && (headlessScale.x != 1 || headlessScale.y != 1
                                                    || headlessScale.z != 1);
        if (hasR) rotateSub.applyRotatePanelValue(headlessRotate);
        if (hasS) scaleSub.applyScalePanelValue(headlessScale);
    }

    // ----- Test-only headless session opener (re-eval plan D5, Phase 3) -----
    //
    // Open a live edit session with NO geometry change, leaving
    // hasUncommittedEdit()==true so a subsequent `tool.attr` write hits the
    // already-live reEvaluate() branch (test 1b-absolute / test 2). Runs the
    // same beginEdit() + dragBaseline capture as the panel/attr replay path but
    // applies nothing: headlessTranslate stays at its current value (0 on a
    // fresh tool), so captureDragBaselineIfStale() snapshots the mesh and opens
    // the session without moving a vertex. Reached only via the testMode-gated
    // `tool.beginSession` command; production opens the session via a gizmo drag
    // or the panel slider path (applyMovePanelDelta).
    public void openLiveSessionForTest() {
        // Foot-gun retired (forms Phase 5b): was `if (!flagT) return;`, which
        // silently no-opped against a Rotate/Scale preset. Open the matching
        // session per active flag, mirroring how each path opens it in
        // production: the WRAPPER session for T (captureDragBaselineIfStale →
        // beginEdit), the SUB-TOOL session for R/S (their own beginEdit, exactly
        // as the gizmo path does in beginRotateDragSession/beginScaleDragSession,
        // which deliberately leave the session on the sub-tool — MS-5). Opening
        // the wrapper session for an R/S preset would make its commitEdit record
        // a spurious "Move" entry for geometry the sub-tool actually applied.
        if (!flagT && !flagR && !flagS) {
            return;
        }
        // Open exactly ONE bare session — the one for the FIRST enabled slot, in
        // T→R→S priority. This is only a "hasLiveEval() is true" primer so the
        // first subsequent tool.attr reaches the already-live reEvaluate() branch.
        // The R/S sub-tool sessions for the OTHER enabled slots open LAZILY, when
        // their applyRotatePanelValue/applyScalePanelValue is actually driven —
        // eagerly opening all three would pollute the idle sub-tool sessions:
        // editing only T would move verts the open (but undriven) rotate/scale
        // sessions are watching, recording spurious "Rotate"/"Scale" entries.
        if      (flagT) captureDragBaselineIfStale();   // WRAPPER session (translate)
        else if (flagR) rotateSub.openEditForValue();   // SUB-TOOL session (rotate)
        else if (flagS) scaleSub.openEditForValue();    // SUB-TOOL session (scale)
        // Deliberately NO applyTRS / needsGpuUpdate — bare session, no geometry.
    }

    // ----- Schema panel suppression (re-eval plan B2) -----------------------
    //
    // Hide the WHOLE schema panel (all 12 params: the T/R/S bools plus
    // TX..TZ / RX..RZ / SX..SZ, :361-376) so the legacy drawProperties()
    // X/Y/Z sliders remain the SINGLE live widget driving headlessTranslate.
    // Without this, app.d would render BOTH the schema panel (writing the TX
    // pointer directly) AND drawProperties() every frame for the transform
    // tool — two live widgets bound to the same translate state, a same-frame
    // double-apply. PropertyPanel.draw early-returns for
    // renderParamsAsPanel()==false, so the transform tool's params are owned
    // solely by drawProperties().
    //
    // Acceptable to hide the whole panel: the T/R/S bools are preset-driven
    // (config/tool_presets.yaml), not user-edited via the panel, and the
    // translate sliders live in drawProperties(). If a future non-TRS param
    // ever needs the schema panel, switch from whole-panel suppression to a
    // per-row filter.
    override bool renderParamsAsPanel() const { return false; }

    // Category C (NEW code — there is no RMB handler in the transform family).
    // Abort the open edit: write the session's pre-edit baseline (the same
    // editBefore[]/editIndices() pair commitEdit() reads) back into the mesh,
    // refresh GPU + caches, clear the open capture via cancelEdit(), and drop
    // any in-flight drag. The suppressCommit latch (honoured at the single
    // commitEdit() chokepoint on TransformTool) prevents deactivate()/update()/
    // BrushReset from re-firing a commit while we tear the session down.
    override void cancelUncommittedEdit() {
        // hasUncommittedEdit() gates the entry from navHistory, but this is also
        // reachable directly; bail when there is nothing open on EITHER the
        // wrapper or a sub-tool. (subToolEditOpen() folds in the R/S sessions
        // MS-5 keeps off the wrapper.)
        bool wrapperOpen = editIsOpen();
        if (!wrapperOpen && !subToolEditOpen()) return;

        // Cancel the open R/S sub-tool sessions FIRST, in a deterministic order
        // (R then S), so one in-session Ctrl+Z reverts the WHOLE open run — the
        // wrapper Move session AND any open sub-tool sessions — consistent with
        // the D6 whole-open-run-cancel contract. Each sub-tool restores its own
        // geometry baseline + Tool-Properties accumulator and returns the
        // pre-edit PANEL value so we can snap the wrapper's headlessRotate /
        // headlessScale mirror (the attr the panel reads back) to it in lockstep
        // — the sub-tools own their geometry session but NOT those wrapper
        // fields, so the mirror restore has to happen here. Mirrors the attrBase*
        // discipline below; no-op (returns false) when the slot has no open
        // session. Their suppressCommit latches are self-contained (set/cleared
        // inside each cancelSessionIfOpen → cancelOpenSessionGeometry).
        Vec3 subDeg, subFactors;
        if (rotateSub.cancelSessionIfOpen(subDeg))     headlessRotate = subDeg;
        if (scaleSub.cancelSessionIfOpen(subFactors))  headlessScale  = subFactors;

        suppressCommit = true;
        scope(exit) suppressCommit = false;

        // Wrapper-side restore (Move / T session). Only runs when the WRAPPER
        // session is open — a pure R/S panel-edit cancel (no Move session) skips
        // it; the sub-tool cancels above already reverted the geometry + GPU and
        // restored the R/S attr mirrors. The action-center pin snapshot is frozen
        // by beginEdit() ONLY on the wrapper session's open, so its restore lives
        // here too.
        if (wrapperOpen) {
            // Restore the moving set to its pre-edit positions. editIndices() /
            // editBaseline() are the per-selected-vertex snapshot beginEdit()
            // captured; restoring them is exactly what an undo of this session
            // would do, but without recording anything.
            uint[] idx  = editIndices();
            Vec3[] base = editBaseline();
            foreach (i, vid; idx) {
                if (vid < mesh.vertices.length)
                    mesh.vertices[vid] = base[i];
            }
            ++mesh.mutationVersion;
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate = false;

            // Restore the headless TRS attrs to their session-start values so the
            // Tool-Properties panel / config form (which read params() — the live
            // &headlessTranslate.x etc. pointers — per frame) snap back in
            // lockstep with the geometry. Without this the verts revert but the
            // numeric fields keep the stale edited numbers. Captured on the
            // closed->open transition in beginEdit() above. (headlessRotate /
            // headlessScale were already snapped above from the sub-tool's
            // pre-edit panel value when its session was open; if the wrapper froze
            // them too, attrBase* holds the identical session-start value.)
            headlessTranslate = attrBaseTranslate;
            headlessRotate    = attrBaseRotate;
            headlessScale     = attrBaseScale;

            // Restore the action-center pin to its session-start state. A
            // click-away / element-pick relocate that opened this gesture moved
            // the ACEN userPlaced pin on mouse-down; without this the gizmo would
            // stick at the click point while the geometry snaps back. The
            // pre-gesture pin state was staged at the relocate site and frozen as
            // the session baseline by beginEdit() above. No-op when nothing
            // relocated (no frozen snapshot). The commit (tool-drop) path never
            // reaches here, so a committed relocate persists, as today.
            if (auto ac = activeAcenStage())
                ac.restoreUserPlacedSnapshot();
        }

        // Close the wrapper capture session WITHOUT recording, and drop any live
        // drag. cancelEdit() is idempotent when the wrapper session was never
        // open (pure R/S cancel path).
        cancelEdit();
        activeDrag          = null;
        dragBaseline.length = 0;
        moveDragFastPath    = false;
        rotDragFastPath     = false;
        rotDragAxisIdx      = -1;
        scaleDragFastPath   = false;
        scaleDragActive     = false;
        // Caches (ViewCache vertex/edge/face) re-validate next frame: while a
        // tool is active app.d invalidates them every frame (app.d :4574).
    }

    // resyncSession() is inherited from TransformTool: it runs the shared
    // resetTransientState() (overridden above to also clear the wrapper's
    // headless-TRS + per-drag fast-path state), so the gizmo + vertex cache
    // recompute from the now-current mesh on the next update() after a
    // committed history pop. No wrapper-specific override is needed.

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

    // MS-4.3/4.4 — canonical-matrix FOLD. Composes the whole T->R->S chain into
    // ONE pivot-relative matrix per moving set and applies it through a SINGLE
    // `applyXformMatrix` call, blended toward identity per vertex by ONE falloff
    // weight evaluated at the BASELINE position. This is what MS-4.1/4.2 proved
    // the reference engine does (one composed matrix, one baseline weight):
    // `tests/test_fixture_falloff_multi.d` + `tests/fixtures/falloff_*_multi.json`
    // confirm it reproduces multi-axis rotation + combined T+R+S exactly, where
    // the prior per-pass sequential blend diverged 0.02-0.03.
    //
    // Order (matches the legacy pass order T -> R.x -> R.y -> R.z -> view -> S,
    // so at w==1 this is BIT-EQUIVALENT to the per-pass chain — the existing
    // w==1 multi-pass suite is the compose-correctness gate): with each factor
    // origin-fixing (R/S built around Vec3(0)) and T the basis-space delta,
    //   M = S . (view . Rz . Ry . Rx) . T,
    // and applyXformMatrix re-applies `pivot` as `pivot + blend(M)*(v - pivot)`.
    //
    // Per-cluster (ACEN.Local): each cluster composes the SAME chain in ITS OWN
    // frame (ap.right/up/fwd[cid]) about ITS OWN pivot (cp), blended by ONE
    // weight. Unlike the legacy per-cluster chain this WEIGHTS the translate too,
    // matching the reference (per-cluster translate is falloff-weighted there, not
    // exempt — the divergence this fold fixes). View-ring is global only.
    //
    // Scope: compoundPasses==1. The dormant `pow(scale, passes)` path keeps the
    // legacy per-pass chain in applyTRS (no matrix form, F2).
    void applyFold(Vec3[] baseline, Vec3 pivot, Vec3 bX, Vec3 bY, Vec3 bZ,
                   TransformTool.ClusterPivots cp,
                   TransformTool.ClusterAxes ap,
                   bool hasT, bool hasS,
                   Vec3 viewAxis, float viewAngleDeg) {
        import std.math : PI;
        // Compose S·R·T in a given frame (ax/ay/az). `withView` folds the global
        // view-ring rotation in (per-cluster frames get no view rotation).
        float[16] composeFor(Vec3 ax, Vec3 ay, Vec3 az, bool withView) {
            float[16] M = identityMatrix;
            if (hasT)
                M = translationMatrix(ax * headlessTranslate.x
                                    + ay * headlessTranslate.y
                                    + az * headlessTranslate.z);    // T (rightmost)
            void rot(Vec3 axis, float deg) {
                if (deg == 0) return;
                M = matMul4(pivotRotationMatrix(Vec3(0, 0, 0), axis,
                                                deg * cast(float)(PI / 180.0)), M);
            }
            if (flagR) {
                rot(ax, headlessRotate.x);
                rot(ay, headlessRotate.y);
                rot(az, headlessRotate.z);
                if (withView && viewAngleDeg != 0
                    && (viewAxis.x != 0 || viewAxis.y != 0 || viewAxis.z != 0))
                    rot(viewAxis, viewAngleDeg);
            }
            if (hasS)
                M = matMul4(pivotScaleMatrixBasis(Vec3(0, 0, 0), ax, ay, az,
                                                  headlessScale.x, headlessScale.y,
                                                  headlessScale.z), M);   // S (leftmost)
            return M;
        }

        float[16] M = composeFor(bX, bY, bZ, /*withView=*/true);

        // MS-4.5 — publish the GLOBAL composed matrix + pivot for the GPU
        // fast-path to reuse (whole-mesh fast-path is never per-cluster).
        lastFoldMatrix = M;
        lastFoldPivot  = pivot;

        // Per-cluster: one composed matrix per cluster, in its own frame.
        float[16][] clusterM = null;
        if (cp.active && ap.active) {
            clusterM = new float[16][](ap.right.length);
            foreach (cid; 0 .. ap.right.length)
                clusterM[cid] = composeFor(ap.right[cid], ap.up[cid], ap.fwd[cid],
                                           /*withView=*/false);
        }

        // Source = restored baseline gathered ordinal-parallel to the moving set;
        // weight at the BASELINE position (weightVerts == the mesh-length baseline).
        auto src = new Vec3[](vertexIndicesToProcess.length);
        foreach (k, vi; vertexIndicesToProcess)
            src[k] = (vi >= 0 && vi < cast(int)baseline.length)
                   ? baseline[vi] : Vec3(0, 0, 0);

        // Perf (doc/perf_harness_plan.md): this is the SINGLE per-frame
        // vertex-cloud apply for the live unified T/R/S drag — `applyFold`
        // composes one matrix and `applyXformMatrix` runs the per-vertex blend
        // loop (+ symmetry mirror) exactly once per `applyTRS`. The scope wraps
        // the whole apply but NOT the inner loop; the counters are DERIVED from
        // the moving-set size (recorded once, never per vertex). The legacy
        // incremental kernels self-time on their own (standalone) path — the
        // two paths are mutually exclusive per drag, so there is no
        // double-counting (see xform_kernels.d header).
        const long nProc = cast(long)vertexIndicesToProcess.length;
        g_perf.count(Cat.vertsTouched, nProc);
        if (dragFalloff.enabled) g_perf.count(Cat.falloffEvalCount, nProc);
        auto zKernel = g_perf.scope_(Cat.kernelApply);
        applyXformMatrix(mesh, vertexIndicesToProcess, src, pivot, M,
                         blendModeForMeasure(), dragFalloff, cachedVp, cp, ap,
                         clusterM, dragSymmetry, toProcess, /*weightVerts=*/ baseline);
    }

    // MS-3.2 — one rotation pass of the canonical-matrix apply (called from
    // applyTRS). Applies a single origin-fixing rotation about `axis` by
    // `angleRad` through the MS-1 matrix kernel, weight at the LIVE position.
    // `srcGather` re-gathers the current (post-prior-pass) scratch positions
    // ordinal-parallel to `vertexIndicesToProcess`, so each rotate pass reads
    // the previous pass's output. `dragAxisIdx ∈ {0,1,2}` enables per-cluster
    // axis lookup (each cluster rotates about its OWN right/up/fwd at that
    // index, around its OWN pivot via cp); -1 keeps `axis` as-is (global /
    // view-ring). Per-cluster rotate is LIVE-weighted, NOT falloff-exempt
    // (unlike per-cluster translate). Still used by the legacy pow-scale chain.
    void applyRotatePass(Vec3 axis, int dragAxisIdx, float angleRad,
                         Vec3 pivot,
                         TransformTool.ClusterPivots cp,
                         TransformTool.ClusterAxes ap,
                         Vec3[] delegate() srcGather)
    {
        if (dragAxisIdx >= 0 && dragAxisIdx <= 2 && ap.active) {
            // Per-cluster rotate: one origin-fixing rotation matrix per cluster
            // about that cluster's axis. The kernel resolves the per-cluster
            // pivot via cp; M is built around the ORIGIN so
            // pivot + M·(src - pivot) yields the cluster-pivoted rotation. The
            // GLOBAL fallback matrix (passed as `M`) rotates any non-cluster
            // vertex about the global `axis`/`pivot` — matching the legacy
            // rotate kernel, whose pivotFor()/axisFor() fall back to the global
            // axis/pivot for verts outside every cluster (NOT identity).
            float[16][] clusterM;
            clusterM.length = ap.right.length;
            foreach (cid; 0 .. ap.right.length) {
                Vec3 ca = dragAxisIdx == 0 ? ap.right[cid]
                        : dragAxisIdx == 1 ? ap.up[cid]
                                           : ap.fwd[cid];
                clusterM[cid] = pivotRotationMatrix(Vec3(0, 0, 0), ca, angleRad);
            }
            applyXformMatrix(mesh, vertexIndicesToProcess, srcGather(),
                             pivot,
                             pivotRotationMatrix(Vec3(0, 0, 0), axis, angleRad),
                             blendModeForMeasure(),
                             dragFalloff, cachedVp, cp, ap, clusterM,
                             dragSymmetry, toProcess);
        } else {
            // Global / view-ring: single origin-fixing rotation about `axis`.
            applyXformMatrix(mesh, vertexIndicesToProcess, srcGather(),
                             pivot,
                             pivotRotationMatrix(Vec3(0, 0, 0), axis, angleRad),
                             blendModeForMeasure(),
                             dragFalloff, cachedVp, cp, ap, null,
                             dragSymmetry, toProcess);
        }
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

    // The single ACEN stage — source of truth for the gizmo pivot. Used to
    // freeze / restore the user-placed pin across an in-session edit cancel
    // (see beginEdit() / cancelUncommittedEdit()).
    ActionCenterStage activeAcenStage() const {
        if (g_pipeCtx is null) return null;
        return cast(ActionCenterStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
    }

    MoveTool   moveSub;
    RotateTool rotateSub;
    ScaleTool  scaleSub;

    // Single shared cross-bank handle arbiter (MODO's two-pass hit-test → draw).
    // Every enabled bank registers its handles into this each frame at its
    // part-id base; one resolve picks ONE hot/captured part across move +
    // rotate + scale, so overlapping handles never co-highlight. Falloff
    // handles fold in here in step 4b. Constructed in the wrapper ctor.
    ToolHandles toolHandles;

    // Sub-tool that owns the currently active drag, set on
    // mouse-down and cleared on mouse-up. Null when no drag is
    // active; in that state mouse motion goes to every enabled
    // sub-tool for hover-preview updates.
    TransformTool activeDrag;

    // In-session run bank (record+consolidate, Q-c). A RUN is a sequence of
    // consecutive same-bank gizmo gestures that share one history runId and
    // consolidate into ONE surviving entry at the run boundary / tool drop. A
    // bank SWITCH within a live run is itself a run boundary, so every surviving
    // consolidated entry is single-bank. `currentRunBank` records the bank of
    // the run currently open (None before any gesture this session). The
    // bank-switch detect lives inside the three mouse-down consume arms: after a
    // sub-tool confirms the click landed on ITS bank, but before the arm opens
    // the drag session, a differing bank consolidates the prior run + bumps the
    // run id. None at session start makes the first gesture's check a harmless
    // empty-run consolidate (no-op) that just sets the bank.
    enum DragBank { None, Move, Rotate, Scale }
    DragBank currentRunBank = DragBank.None;

    // In-session falloff re-grade (re-fire) state.
    //
    // When a falloff configuration changes at idle while the current run has a
    // landed gesture, the just-applied gesture is re-evaluated against the new
    // weights and recorded as one tagged in-session entry in the SAME run. Two
    // pieces of state make that safe + bounded:
    //
    // lastAppliedGestureMutationVersion — STALENESS STAMP. Set to
    //   mesh.mutationVersion at the end of every gesture's mouse-up commit (all
    //   banks). The re-grade site fires ONLY if mesh.mutationVersion still
    //   equals this stamp. An in-session Ctrl+Z that pops a gesture reverts
    //   geometry and so bumps mutationVersion away from the stamp; the site then
    //   goes inert and never re-applies the popped gesture from a stale baseline.
    //   ulong.max = "no live gesture to re-grade". Reset at activate /
    //   deactivate / resetTransientState and at every run boundary (bank switch,
    //   selection/mutation guard).
    ulong lastAppliedGestureMutationVersion = ulong.max;

    // refireAnchor — once-per-RE-FIRE-WINDOW POST-GESTURE full-mesh snapshot.
    //   Captured ONCE at the FIRST re-grade after a gesture (before the recompute
    //   mutates the mesh) and reused as the before[] source for EVERY re-grade of
    //   that window. A re-fire WINDOW is per-gesture, NOT per-run: a run can hold
    //   more than one gesture (g1 -> tweak -> g2 -> tweak), and each gesture
    //   mouse-up commit CLEARS this anchor so the next re-grade re-captures the
    //   NEW post-gesture geometry — a tweak after g2 must anchor before[] to
    //   post-g2, not the stale post-g1 snapshot (the multi-gesture anchor
    //   hazard). Using the full post-gesture geometry (not just the falloff
    //   support) makes a WIDENING scrub revert cleanly: a re-grade that pulls in
    //   verts outside the prior re-grade's support still has a recorded baseline
    //   for them. Empty = none captured. Cleared at every gesture mouse-up
    //   commit, at every run boundary, at activate / deactivate /
    //   resetTransientState, and on a staleness miss (the window's anchor is then
    //   invalid; a later forward gesture re-captures fresh).
    Vec3[] refireAnchor;

    // Detect a bank switch at gizmo mouse-down and consolidate the prior run.
    // Called from each mouse-down consume arm AFTER the sub-tool confirmed the
    // click landed on its bank, BEFORE begin*DragSession. An empty/not-yet-open
    // run consolidates to nothing (safe no-op) — the gather finds no matching
    // in-session tail. Always (re)sets currentRunBank to this arm's bank so the
    // next gesture extends the same single-bank run.
    private void noteRunBank(DragBank thisBank) {
        if (currentRunBank != DragBank.None && currentRunBank != thisBank) {
            history.consolidate(history.currentRunId);
            history.nextRun();
            // A bank switch is a run boundary: the prior run's re-grade anchor +
            // staleness stamp must not leak into the new run.
            lastAppliedGestureMutationVersion = ulong.max;
            refireAnchor.length               = 0;
        }
        currentRunBank = thisBank;
    }

    // Record an in-session falloff re-grade entry for the current run.
    //
    // The SITE has already: gated on its own bank + the staleness stamp, dup'd
    // the pre-recompute geometry into `anchor`, run the recompute (mutating
    // mesh.vertices), and dup'd the result into `after`. This helper owns the
    // record: it anchors before[] to the POST-GESTURE snapshot of the current
    // re-fire WINDOW and ALWAYS routes through replaceInSessionTail, which owns
    // the REPLACE-vs-APPEND decision (keyed on the Refire bit): a re-grade whose
    // tail is the prior re-grade REPLACES it (consecutive tweaks stay ONE undo
    // step); a re-grade whose tail is a plain GESTURE entry APPENDS (preserving
    // that gesture). The helper itself no longer chooses — keying on a stale
    // "did any re-grade happen this run" signal dropped a second gesture's entry
    // (the C1 hazard).
    //
    // `anchor` is the site's pre-recompute snapshot (post-gesture geometry). On
    // the WINDOW's FIRST re-grade the helper STORES it as refireAnchor; on later
    // re-grades refireAnchor already holds the post-gesture state and `anchor` is
    // ignored. A new gesture CLEARS refireAnchor at its mouse-up commit, opening
    // a fresh window anchored to the new post-gesture geometry — so a tweak after
    // a SECOND gesture anchors before[] to post-gesture-2, not the stale
    // post-gesture-1 (the multi-gesture anchor hazard). before[] is sourced from
    // refireAnchor for ALL re-grades of the window, so a
    // widening scrub (verts pulled in that the prior re-grade never touched) has
    // a complete baseline and reverts cleanly on one Ctrl+Z (contract C).
    //
    // The entry carries NO Tool-Properties / pin hooks: the falloff CONFIG is an
    // accepted v1 undo divergence (the config command is a separate SideEffect,
    // not captured in geometry undo) and a falloff tweak never relocates the
    // pivot. So the MeshVertexEdit's apply/revert restore geometry alone — which
    // is exactly contract (C).
    private void recordFalloffRefire(string label, Vec3[] anchor,
                                     Vec3[] after, size_t[] idx, DragBank bank) {
        // Step 0 — staleness gate (defense-in-depth; the site already gated, but
        // the helper must refuse too). On a miss the run's anchor is invalid.
        if (mesh.mutationVersion != lastAppliedGestureMutationVersion) {
            refireAnchor.length = 0;
            return;
        }
        // Step 1 — guards: need a history, an OPEN run (a re-grade only extends a
        // run that has a landed gesture), and a real geometry change.
        if (history is null) return;
        if (!history.runOpen()) return;

        // Step 2 — anchor capture (once per RE-FIRE WINDOW). The FIRST re-grade
        // after a gesture stores that gesture's post-recompute snapshot; later
        // CONSECUTIVE re-grades reuse it unchanged. A new gesture CLEARS
        // refireAnchor at its mouse-up commit (see the per-bank commit sites),
        // opening a fresh window anchored to the NEW post-gesture geometry — so
        // a tweak after a second gesture anchors before[] to post-gesture-2, not
        // the stale post-gesture-1 (the multi-gesture-run anchor hazard).
        if (refireAnchor.length == 0)
            refireAnchor = anchor.dup;

        // Step 3 — build the entry. before[] = refireAnchor (post-gesture state)
        // for the moved indices; after[] = the re-graded positions. Drop any
        // index that did not actually move vs the anchor (no spurious payload).
        size_t[] movedIdx;
        Vec3[]   before;
        Vec3[]   movedAfter;
        movedIdx.reserve(idx.length);
        before.reserve(idx.length);
        movedAfter.reserve(idx.length);
        foreach (k, vid; idx) {
            if (vid >= refireAnchor.length || vid >= mesh.vertices.length)
                continue;
            Vec3 b = refireAnchor[vid];
            Vec3 a = after[k];
            if (a.x == b.x && a.y == b.y && a.z == b.z) continue;
            movedIdx   ~= vid;
            before     ~= b;
            movedAfter ~= a;
        }
        if (movedIdx.length == 0) return;   // no net change → no entry.

        // setEdit takes uint[] indices.
        uint[] uidx;
        uidx.length = movedIdx.length;
        foreach (k, vid; movedIdx) uidx[k] = cast(uint) vid;

        if (vertexEditFactory is null) return;
        auto cmd = vertexEditFactory();
        cmd.setEdit(uidx, before, movedAfter, label);

        // Step 4 — record. ALWAYS route through replaceInSessionTail: it is the
        // single re-fire primitive and owns the REPLACE-vs-APPEND decision,
        // keyed on the trustworthy Refire bit. It DROPS the tail only when the
        // tail is THIS run's prior RE-GRADE (InSession && Refire && runId) — so
        // a CONSECUTIVE tweak replaces the prior re-grade (N tweaks = ONE undo
        // step), while a tweak whose tail is a plain GESTURE entry (the run's
        // first tweak, OR the first tweak after a SECOND gesture) APPENDS,
        // preserving the gesture's geometry contribution. This is the fix for
        // the multi-gesture-run hazard: keying on "is the tail a refire" instead
        // of "did any refire happen this run" stops a tweak2 from erasing g2.
        history.replaceInSessionTail(cmd, history.currentRunId);

        // Step 5 — defensive re-stamps (no-ops today: the re-grade does NOT bump
        // mutationVersion — applyTRS is version-silent and recordInSession never
        // calls apply()). Kept future-proof should the apply path ever bump.
        lastMutationVersion               = mesh.mutationVersion;
        lastAppliedGestureMutationVersion = mesh.mutationVersion;
    }

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

        // Same for ANY rotate ring drag (rotDragAxisIdx 0/1/2 principal OR
        // 3 view-ring): the wrapper owns gpuMatrix (set to `pivotRotationMatrix`
        // / `wrapAboutPivot` in the fast-path branch of onMouseMotion), and
        // rotateSub no longer writes its own gpuMatrix during a wrapper-owned
        // drag. Forwarding rotateSub's identity here every update()/draw()
        // frame would clobber the wrapper's rotation matrix between motion
        // events — the whole-mesh cube would flicker back to its drag-start
        // pose (then snap to the rotated CPU result only at mouse-up). This
        // must match the `wrapperOwnsGpu` predicate in onMouseMotion, which
        // includes the view-ring (rotDragAxisIdx <= 3).
        if (activeDrag is rotateSub
            && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 3) return;

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
