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
// - The falloff endpoint gizmo is NOT per-sub-tool. A single
//   PipeGizmoHost-owned emitter, registered into the tool's shared
//   toolHandles, handles falloff for all banks — one source of truth,
//   no per-sub-tool copies.
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
// `run.t`, and reapplies the chain from the drag-start
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

import ai.interaction : AiInteractionPhase;
import math : Vec3, Viewport, translationMatrix,
               pivotRotationMatrix, pivotScaleMatrixBasis, dot,
               identityMatrix, matMul4, wrapAboutPivot, wrapAboutPivotStable, eulerZYXFromMatrix,
               frameMatrix, frameMatrixInverse;
import editmode : EditMode;
import mesh;
import handler  : ToolHandles;
import eventlog : queryMouse;
import shader : Shader;
import params : Param;
import tools.transform : TransformTool;
import tool            : ToolFlag;
import tools.move      : MoveTool;
import tools.rotate    : RotateTool;
import tools.scale     : ScaleTool;
import tools.xform_kernels :
    applyScaleFromActivation,   // dormant compoundPasses!=1 pow path only (applyTRS, F2)
    applyXformMatrix,
    BlendMode;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import change_bus : MeshEditScope;
import perf_probe : g_perf, Cat;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage, FalloffSetSnapshot,
                                 snapshotFalloffSet, restoreFalloffSet,
                                 restoreFalloffSetFromCombined;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import toolpipe.packets  : FalloffType, ElementMode, ElementConnect, FalloffPacket,
                          SnapPacket, SymmetryPacket;
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
// falloff base (PipeGizmoHost.FALLOFF_BASE = 100) is owned by the host:
// it registers its emitter's handles into this SAME pool FIRST (highest
// test priority) so a falloff endpoint handle wins over a co-located
// gizmo arrow — matching the click-dispatch order.
private enum int MOVE_BASE = 0, ROT_BASE = 10, SCALE_BASE = 20;

private enum LatchedHandleBank { None, Move, Rotate, Scale }

private struct LatchedHandlePart {
    LatchedHandleBank bank = LatchedHandleBank.None;
    int localPart = -1;
}

private LatchedHandlePart latchedHandlePart(int hitPart) pure nothrow @safe @nogc {
    if (hitPart >= MOVE_BASE && hitPart < MOVE_BASE + 10)
        return LatchedHandlePart(LatchedHandleBank.Move, hitPart - MOVE_BASE);
    if (hitPart >= ROT_BASE && hitPart < ROT_BASE + 10)
        return LatchedHandlePart(LatchedHandleBank.Rotate, hitPart - ROT_BASE);
    if (hitPart >= SCALE_BASE && hitPart < SCALE_BASE + 10)
        return LatchedHandlePart(LatchedHandleBank.Scale, hitPart - SCALE_BASE);
    return LatchedHandlePart();
}

version(unittest) int[2] xfrmLatchedHandlePartForTest(int hitPart)
        pure nothrow @safe @nogc {
    auto p = latchedHandlePart(hitPart);
    return [cast(int)p.bank, p.localPart];
}

private int compactScaleHeadFallbackHitPart(bool compact, bool scaleEnabled,
                                            int hitPart, int scaleHeadAxis)
        pure nothrow @safe @nogc {
    if (compact && scaleEnabled && hitPart < 0 && scaleHeadAxis >= 0)
        return SCALE_BASE + scaleHeadAxis;
    return hitPart;
}

version(unittest) int xfrmCompactScaleHeadFallbackForTest(
        bool compact, bool scaleEnabled, int hitPart, int scaleHeadAxis)
        pure nothrow @safe @nogc {
    return compactScaleHeadFallbackHitPart(compact, scaleEnabled,
                                           hitPart, scaleHeadAxis);
}

unittest { // shared handle winner maps to the exact subtool latch part
    assert(latchedHandlePart(-1).bank == LatchedHandleBank.None);
    auto move = latchedHandlePart(MOVE_BASE + 6);
    assert(move.bank == LatchedHandleBank.Move);
    assert(move.localPart == 6);
    auto rot = latchedHandlePart(ROT_BASE + 3);
    assert(rot.bank == LatchedHandleBank.Rotate);
    assert(rot.localPart == 3);
    auto scale = latchedHandlePart(SCALE_BASE + 4);
    assert(scale.bank == LatchedHandleBank.Scale);
    assert(scale.localPart == 4);
}

// Canonical run-state for the wrapper transform: translation Vec3, rotation
// as a matrix-truth float[16] (R is matrix-truth — euler is a derived view),
// and a per-component scale Vec3. Defaults are the identity transform
// (t = 0, r = identity, s = 1), so `XformState.init` is the identity state.
// The rotate matrix truth lives in `run.r`; `headlessRotate` is its derived
// euler display (eulerZYXFromMatrix) and the RX/RY/RZ param-bind target.
struct XformState {
    Vec3 t = Vec3(0, 0, 0);
    // Inline identity literal (matches math.identityMatrix); a field
    // initializer cannot CTFE-cast the `immutable float[16]` constant to a
    // mutable field, so the literal is spelled out here.
    float[16] r = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1];
    Vec3 s = Vec3(1, 1, 1);
}

// Unified gesture frame — the orthonormal world coordinate frame frozen at
// gesture start and chained across same-session gestures. It is the SINGLE
// SOURCE OF TRUTH for the chained frozen frame: the render ladder's top rung,
// the chained input channel, the chained rotate/scale apply axis, and
// runFrame's chained translate source ALL read it (gesture-frame unification
// Phases 1-4 re-pointed those reads onto it). It is written DIRECTLY by
// `settleGestureBasis` (the gesture-end persist) and re-gated by
// `refreshFrameValid()` — there is no longer a parallel mirror slot.
//
// `settled` records whether a gesture-end basis is currently persisted. `valid`
// is the EFFECTIVE chained gate, recomputed as `settled && acenSettleAllowed()`
// at exactly the points the basis or the action-center mode can change (settle /
// clear / each begin*DragSession) — so every read site sees the same value the
// former two-flag chained gate produced.
//
// `m`/`mInv` are COMPUTED from the existing math helpers rather than stored:
// every writer feeds a pure-rotation orthonormal triple, so the inverse of
// the frame matrix equals its transpose by construction (frameMatrixInverse,
// proven == transpose in math.d's unittest). A DEBUG assert at population
// keeps that invariant honest.
struct GestureFrame {
    Vec3 right   = Vec3(1, 0, 0);
    Vec3 up      = Vec3(0, 1, 0);
    Vec3 axis    = Vec3(0, 0, 1);  // "axis"/"forward" — the third frame vector
    bool settled = false;          // a gesture-end basis is persisted
    bool valid   = false;          // settled && acenSettleAllowed() — the chained-read gate
    float[16] m()    const @safe pure nothrow @nogc { return frameMatrix(right, up, axis); }
    float[16] mInv() const @safe pure nothrow @nogc { return frameMatrixInverse(right, up, axis); }
}

class XfrmTransformTool : TransformTool {
public:
    // T/R/S flags — `T integer 0/1` etc. in the preset config.
    // Default to all enabled (the bare `Transform` preset that shows
    // all three handler banks). Preset loader flips these per-preset
    // before the first activate().
    bool flagT = true;
    bool flagR = true;
    bool flagS = true;
    // Handle family selector: 0=Move, 1=Rotate, 2=Scale,
    // 3=Uniform Scale. Presentation is separate: bare Transform uses
    // compact combined handles, while per-mode presets use the full bank.
    int handleFamily = 0;
    string handlePresentation = "compact";

    // Headless TRS attrs — always exposed regardless of flag state
    // so scripted callers can set TX with R=1 S=1 without first
    // flipping flags. Defaults: 0 for translate / rotate, 1 for scale.
    // Run-absolute transform state. `run.t` (translate), `run.r` (rotate matrix
    // truth) and `run.s` (scale) are the canonical TRS truth; `headlessRotate` is
    // the DERIVED euler display of `run.r` (eulerZYXFromMatrix) and the RX/RY/RZ
    // param-bind target. `gestureStart` is the per-gesture snapshot of `run`
    // captured at mouse-down.
    XformState run;
    XformState gestureStart;
    Vec3 headlessRotate    = Vec3(0, 0, 0);

    // Per-tool fold blend mode for the ROTATE-ONLY soft path. The unified fold
    // blends the composed matrix toward identity by the falloff weight; the
    // production default is MatrixLerp (keep-b), confirmed reference-correct for
    // the combined T/R/S fold (MS-4.1/4.2). A pure-rotate-under-radial-falloff
    // preset wants instead to scale the ROTATION ANGLE by the weight (radius
    // preserved) — R(w·theta) — which equals slerp(I, R, w) when M is an
    // origin-fixed pure rotation. `rotFalloffBlend` is the Enum Param storage
    // ("linear" = MatrixLerp default, "arc" = PolarQuat angle-scaling), mapped to
    // `rotateBlendMode()` and consumed ONLY by the rotate-only guard in applyFold.
    // The reference engine's data backing "arc" is SINGLE-AXIS only (see the
    // applyFold guard comment). Presets xfrm.softRotate / xfrm.swirl set "arc";
    // the other two base:rotate presets (xfrm.twist / xfrm.vortex) deliberately
    // STAY on the default "linear" — they use linear/cylinder falloff with no
    // reference capture yet, so leaving them on MatrixLerp is intentional, not a
    // gap to be "completed".
    string rotFalloffBlend = "linear";

    // Map the rotFalloffBlend Enum Param storage onto the kernel BlendMode. This
    // is the per-tool rotate-only fold blend selector ("arc" = PolarQuat = scale
    // the rotation angle by the weight; anything else = MatrixLerp).
    BlendMode rotateBlendMode() const @safe pure nothrow @nogc {
        return rotFalloffBlend == "arc" ? BlendMode.PolarQuat : BlendMode.MatrixLerp;
    }

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

    // BUG-2 (reviewer BLOCKER) — gesture-START display SOFT-pin, captured LIVE at
    // beginEdit alongside gesturePinStart* (the W1 lesson: capture the live state
    // NOW, not a frozen snapshot). The Move soft pin (notifyAcenSoftPlaced, fired
    // AFTER commitEdit at mouse-up) is otherwise stranded by an in-session Ctrl+Z:
    // the Move revert hook restored only the userPlaced pin, never the soft pin,
    // and the update() clear is skipped on undo (undo bumps mutationVersion but
    // not the selection hash) — so geometry reverted to pristine while the gizmo
    // pivot stayed floating at the settled height. The commit now carries the
    // soft-pin endpoints into the same revert/apply closures as the userPlaced pin
    // + pipe config (disjoint state — no clobber): revert restores this
    // gesture-START soft state (typically cleared → pivot recomputes to the
    // reverted-geometry centroid), apply restores the gesture-END (settled) soft
    // pin. Gated identically to gesturePinStart* so a no-preceding-beginEdit commit
    // falls back to inert.
    private bool gestureSoftStartPlaced = false;
    private Vec3 gestureSoftStartCenter = Vec3(0, 0, 0);

    // flex_border_handles_plan.md Phase 3 (BUG-1, undo-splice) — the Rotate /
    // Scale equivalents of the Move gestureSoftStart* pair above. Captured at the
    // matching mouse-DOWN (begin*DragSession) from the LIVE soft pin so the
    // per-gesture undo hook can restore the gesture-START soft state on revert
    // (mirroring the Move commitEdit splice). Without these an in-session Ctrl+Z
    // after a frozen-frame rotate/scale reverts geometry but leaves the gizmo
    // floating at the settled pose — the exact desync the Move path already fixed.
    private bool rotateSoftStartPlaced  = false;
    private Vec3 rotateSoftStartCenter  = Vec3(0, 0, 0);
    private bool scaleSoftStartPlaced   = false;
    private Vec3 scaleSoftStartCenter   = Vec3(0, 0, 0);

    // flex_border_handles_plan.md Phase 3 / COMMIT B — the gesture-end gizmo BASIS
    // persistence frame (the analogue of softPlaced for the rendered orientation),
    // now the unified `GestureFrame` (gesture-frame unification, Phase 5 — the
    // separate persisted-basis and chained-rotate-axis slots were retired; this is
    // the SINGLE source of truth for the chained frozen frame).
    //
    // On release of a flex ROTATE the during-drag rendered basis is R_gesture·B0;
    // without this the idle renderBasis path falls back to the live currentBasis
    // (world-snapped, now-rotated-selection) → a visible snap-back. We snapshot
    // the gesture-END rendered basis at mouse-up (settleGestureBasis writes
    // `frame.{right,up,axis}` + `frame.settled`) and consult it from renderBasis
    // while idle (activeDrag is null) BEFORE the live currentBasis fallback, so the
    // dropped orientation persists until selection/mode change (cleared by the SAME
    // hooks that clear softPlaced — ONE lifecycle, clearFrame()). Captured
    // EXPLICITLY at mouse-up (from the bank's last-drawn handler.axis*) rather than
    // read from runFrame*, since a boundary-triggered resetRun could zero runFrame*
    // before the next idle frame reads it (the load-bearing ordering check).
    //
    // `frame.settled` records whether a basis is persisted; `frame.valid` is the
    // chained-read gate, re-evaluated as `settled && acenSettleAllowed()` whenever
    // the basis or ACEN mode can change (settle / clearFrame / each
    // begin*DragSession) — see refreshFrameValid().
    private GestureFrame frame;

    // Gizmo-basis undo splice — the per-bank gesture-START snapshot of the
    // persisted `frame`, the BASIS analogue of the *SoftStart* center snapshots
    // above. Captured at the matching mouse-DOWN (begin*DragSession) from the
    // LIVE `frame` so the per-gesture undo hook can restore the gesture-START
    // basis on revert, exactly as the center is restored via restoreSoftPlaced.
    //
    // WHY this is needed only for rotate in practice: an undo bumps the mutation
    // version but NOT the selection hash, so clearFrame() does not fire and the
    // idle renderBasis keeps returning the persisted `frame`. A rotate gesture's
    // settleGestureBasis leaves `frame` holding R_gesture·B0 (rotated), so after
    // an in-session Ctrl+Z the geometry returns to pristine while the rendered
    // gizmo basis stays stale-rotated. Move/scale re-settle the SAME orientation
    // (settleGestureBasis writes the un-rotated triple), so frameStart == frameEnd
    // there and the restore is an identity no-op (restore-to-same, harmless).
    // Non-flex modes never settle a basis (acenSettleAllowed gates it / frame
    // stays invalid), so frameEnd is unchanged from frameStart and the hook is
    // inert there too. Gated by the SAME *GestureStartKnown flags as the run /
    // soft-pin splice so a commit with no preceding mouse-down stays inert.
    private GestureFrame moveFrameStart;
    private GestureFrame rotateFrameStart;
    private GestureFrame scaleFrameStart;

    // P-F Phase 3 — per-GESTURE run-absolute snapshot. The WHOLE run state at
    // THIS gesture's mouse-down lives in `gestureStart` (one struct snapshot,
    // captured in every begin*DragSession after beginRunGesture). The per-gesture
    // undo hook restores `gestureStart` (run-START) on revert and `run` (run-END)
    // on apply; since a single gesture's drain only touches its OWN bank's field
    // (Move → run.t, Rotate → run.r, Scale → run.s), the inactive banks have
    // start == end and restoring them is an identity no-op — so the whole-struct
    // restore is byte-equivalent to the former per-bank field restores, and is
    // strictly more coherent across the mergeRun first.revert/last.apply splice
    // (every entry carries the full struct).
    //
    // The three `*GestureStartKnown` flags survive PER-BANK: each gates the inert
    // fallback (a commit with no preceding mouse-down — e.g. a relocate-boundary
    // no-op cmd — falls back to start == end so the hook does not move the field
    // on undo) for its bank's commit site, which fires independently. They are
    // set at the matching begin*DragSession and cleared at the matching commit.
    private bool moveGestureStartKnown     = false;
    private bool scaleGestureStartKnown    = false;
    private bool rotateGestureStartKnown   = false;

    // P-F Phase 3b — did the PRIOR rotate gesture in this run drive the view-ring
    // (ax==3)? The view-ring angle is a transient applyTRS axis-angle param, NEVER
    // stored in the Euler field, so a principal gesture AFTER a view-ring must
    // re-bake (the held view-ring rotation lives only in the baked geometry). Set
    // true on a view-ring mouse-down, false on a principal mouse-down, cleared by
    // resetRun at every run boundary.
    private bool runPriorRotateWasViewRing  = false;

    // Matrix-as-truth — is THIS rotate gesture running under per-cluster
    // ACEN.Local (cp.active && ap.active)? Captured at rotate mouse-down (in
    // beginRotateDragSession, BEFORE beginRunGesture) and read by
    // rotateRunNeedsRebake. The matrix-truth model (run.r) is GLOBAL-only;
    // the per-cluster path STAYS LEGACY (re-bakes every cross-axis / view-ring
    // gesture so its field carries ONE live axis per cluster). False for the global
    // / no-cluster path → NOTHING re-bakes there (run.r accumulates it all).
    private bool rotateGesturePerClusterLocal = false;

    // BUG-2 — a PENDING Move-settle soft pin, requested by the mouse-up handler
    // and consumed by commitEdit ONLY when a real edit command was built. A
    // zero-motion off-gizmo relocate CLICK opens a moveSub session (so the mouse-up
    // path runs) but produces NO geometry edit (buildEditCmd returns null) — its
    // mouse-DOWN already fired setUserPlaced (clearing the soft pin). Setting the
    // soft pin unconditionally on every Move mouse-up resurrected it on top of the
    // relocate. Routing the request through commitEdit lets the soft pin be set
    // (and captured into the hooks) only on a genuine edit; a no-op relocate leaves
    // the soft pin cleared. Cleared after each commit (one-shot).
    private bool pendingMoveSoftPin    = false;
    private Vec3 pendingMoveSoftCenter = Vec3(0, 0, 0);

    // MS-4.5 — the composed pivot-relative matrix the GLOBAL fold built on the
    // last applyGlobalFold (origin-fixing) plus the pivot it used. The GPU
    // fast-path (whole-mesh / no-falloff, which always takes the fold) reuses
    // THIS matrix — `gpuMatrix = wrapAboutPivot(lastFoldMatrix, lastFoldPivot)` —
    // instead of rebuilding a parallel about-pivot rotation/scale matrix, so the
    // GPU preview is the literal same transform the CPU fold applied.
    float[16] lastFoldMatrix  = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    Vec3      lastFoldPivot   = Vec3(0, 0, 0);
    Vec3      lastFoldAnchor  = Vec3(0, 0, 0);

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

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
        moveSub   = new MoveTool  (meshSrc, gpu, editMode);
        rotateSub = new RotateTool(meshSrc, gpu, editMode);
        scaleSub  = new ScaleTool (meshSrc, gpu, editMode);
        toolHandles = new ToolHandles();
        toolHandles.setAiHoverPreviewEnabled(true);
        toolHandles.setAiHoverPreviewPredicate(
            (int part) const => latchedHandlePart(part).bank != LatchedHandleBank.None);
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
        resetRun();                   // apply-path Phase 2: fresh geometry run (+ P-F frozen frame)
        lastAcenMode       = -1;      // P-C: re-latch the ACEN mode on first poll
        clearFrame();                 // COMMIT B — fresh session re-derives the basis
    }

    // Wrapper-level transient reset (undo/redo migration P1). Extends the base
    // TransformTool.resetTransientState() with the wrapper-owned headless TRS
    // accumulators and per-drag fast-path state. Shared by activate() and
    // resyncSession() so the two can't drift. Touches only drag-invariant
    // bookkeeping (no open edit exists when resyncSession() runs); the one-time
    // sub-tool activation + wrapperRef wiring stays in activate().
    protected override void resetTransientState() {
        super.resetTransientState();
        // P-F Phase 3 — display-field preservation on the resync-after-undo path.
        // resetTransientState() is shared by activate() (brand-new tool → MUST
        // zero the run-absolute display fields) and resyncSession() (after an
        // in-session Ctrl+Z/Y → must NOT zero them: the per-gesture revert/apply
        // hooks already restored the field to the reverted-to step's run total
        // during history.undo(), which runs BEFORE this). resyncSession() sets
        // resyncPreserveDisplayFields so this path keeps the hook-restored value
        // (and resetRun() below skips its own hadRun field-zero for the same
        // reason). activate() leaves the flag false → identical zeroing as before.
        if (!resyncPreserveDisplayFields) {
            // Struct-init reset — t=(0,0,0)/r=identity/s=(1,1,1). The rotate truth
            // resets with its derived euler display.
            run = XformState.init;
            headlessRotate = Vec3(0, 0, 0);
        }
        activeDrag                = null;
        dragBaseline.length       = 0;
        resetRun();                          // apply-path Phase 2: fresh run (+ P-F frozen frame)
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
        refirePreValid                    = false;
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
        refirePreValid                    = false;
        super.deactivate();
        activeDrag           = null;
        dragBaseline.length  = 0;
        resetRun();                     // apply-path Phase 2: tool drop = run boundary (+ P-F frozen frame)
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
                    refirePreValid                    = false;
                }
                // Apply-path Phase 2: a selection/mutation change is a GEOMETRY-run
                // boundary regardless of whether a history run is open — the moving
                // set (and thus the meaningful baseline) changed, so the next gesture
                // must re-capture from the current mesh.
                resetRun();   // + P-F: a new moving set freezes a NEW run-frame
                // BUG-1: the display soft-pin (Move-settle) tracks the prior
                // selection's settled pivot; a NEW SELECTION must recompute the
                // center from the new moving set, so drop it here. Gated to a
                // genuine selection change (NOT a bare mutation bump): a Move
                // gesture's own apply does not bump mutationVersion, but R/S panel
                // applies DO — clearing on a mutation-only bump would wipe the pin
                // mid-run after a rotate/scale, which is not a moving-set change.
                // BUG-2 (reviewer BLOCKER) — clear the soft pin ONLY on a GENUINE
                // selection change, NOT on the first-poll latch. lastSelectionHash
                // is seeded to uint.max by activate() / a session re-open as the
                // "not yet synced" sentinel (NOT a real selection); the very next
                // update() then sees curHash != uint.max and would spuriously wipe
                // the soft pin. After an in-session redo this is the bug: the Move
                // apply hook restores the settled soft pin, then this guard frame
                // (running with lastSelectionHash == uint.max because the session
                // re-opened) re-cleared it, snapping the gizmo back to the weighted
                // centroid. Mirror the ACEN-mode poll's first-poll latch (below):
                // when the prior hash is the sentinel, adopt curHash WITHOUT firing
                // the soft-pin clear. A real selection change (sentinel already
                // replaced by a concrete hash) still clears, as before.
                if (lastSelectionHash != uint.max
                 && curHash != lastSelectionHash) {
                    clearAcenSoftPlaced();
                    clearFrame();       // COMMIT B — one lifecycle with the center pin
                }
                lastSelectionHash   = curHash;
                lastMutationVersion = curMutVer;
            }
        }

        // P-C — ACEN-mode boundary poll. An action-center MODE change mid-run is
        // a session BOUNDARY (the reference restarts the op at a new pivot). But
        // `actr.*` is a SideEffect command (records nothing) so it never trips
        // the command-history foreign-record guard that the selection/mutation
        // boundary above relies on. So poll the published ACEN mode here, in the
        // SAME idle path: on a change with an open run, consolidate + nextRun so
        // the next gesture is a new run (mirrors the selection-boundary block's
        // consolidate/nextRun + the bank/anchor/baseline resets). This runs
        // BEFORE the refire block and before any mouse-down is processed this
        // frame (update() runs before event dispatch), so no gesture lands in the
        // wrong run — the poll always precedes the next gesture (invariant).
        // Skipped during a live drag (dragAxis frozen): a mode read mid-drag is
        // the drag's own state, not a user action.
        if (activeDrag is null) {
            if (auto ac = activeAcenStage()) {
                int curMode = cast(int) ac.mode;
                if (lastAcenMode == -1) {
                    // First poll this session: latch without firing a boundary.
                    lastAcenMode = curMode;
                } else if (curMode != lastAcenMode) {
                    if (editIsOpen())
                        commitEdit("Move");
                    if (history !is null && history.runOpen()) {
                        history.consolidate(history.currentRunId);
                        history.nextRun();
                        currentRunBank = DragBank.None;
                        // Run boundary: invalidate the re-grade anchor + staleness
                        // stamp so a later config change cannot re-grade the
                        // just-closed run (same resets as the selection boundary).
                        lastAppliedGestureMutationVersion = ulong.max;
                        refireAnchor.length               = 0;
                        refirePreValid                    = false;
                    }
                    // GEOMETRY-run boundary regardless of an open history run: the
                    // pivot moved, so the next gesture must re-capture its baseline.
                    resetRun();   // + P-F: a mode change freezes a NEW run-frame
                    // BUG-1: a mode change recomputes the center from scratch — drop
                    // any display soft-pin from a prior mode's settle. (applySetAttr
                    // "mode" already clears it inside the stage when the change came
                    // through setAttr; this covers any other path that moved the mode
                    // and is a no-op when already clear.)
                    clearAcenSoftPlaced();
                    clearFrame();       // COMMIT B — one lifecycle with the center pin
                    lastAcenMode     = curMode;
                }
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
            && (run.t.x != 0
             || run.t.y != 0
             || run.t.z != 0)) {
            if (editIsOpen()) {
                // ARM 1 — panel session: old in-place coalesce, no record.
                // P-C: the trigger now spans the whole pipe config — falloff,
                // snap AND symmetry. A mid-session toggle of any of the three
                // re-grades the COMPOSED op against the new pipe state.
                FalloffPacket liveF = currentFalloff(vts);
                SnapPacket     liveSn = currentSnap(vts);
                SymmetryPacket liveSy = currentSymmetry(vts);
                if (!falloffPacketsEqual(liveF, dragFalloff)
                 || !snapPacketsEqual(liveSn, dragSnap)
                 || !symmetryPacketsEqual(liveSy, dragSymmetry)) {
                    // Re-read ALL THREE live packets before the recompute so
                    // applyTRS's symmetry pass + per-vertex falloff weight read
                    // the new config. recaptureLivePipePackets() does a FRESH
                    // pipeline evaluate so a just-enabled symmetry stage's pairOf
                    // is populated (the single update() evaluate publishes a
                    // stale-empty pairOf on the toggle frame). Snap is a
                    // cursor-time op, NOT in the fold, so re-reading dragSnap
                    // changes no geometry — but keeps the run-state coherent for
                    // the config-restore hooks downstream.
                    recaptureLivePipePackets();
                    vertexCacheDirty = true;
                    // Apply-path Phase 2 (OBJ-1, decision (a)): full-fold
                    // re-grade. Re-weight the COMPOSED op (all preset banks'
                    // run-absolutes) from one baseline, not translate-only. On
                    // a Move-only run the held R/S are identity so this is
                    // byte-identical to the old applyTRSForBank(Move); the
                    // difference surfaces only when a held non-identity rotate/
                    // scale also wants re-weighting (the reference re-Evaluates
                    // the WHOLE held op when falloff changes).
                    applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                             /*samplePipeFromBaseline=*/true);
                    needsGpuUpdate = true;
                }
            } else if (history !is null
                    && history.runOpen()
                    && currentRunBank == DragBank.Move           // OBJ-2 single-winner
                    && mesh.mutationVersion == lastAppliedGestureMutationVersion) {
                // ARM 2 — committed gizmo gesture: re-grade + record.
                // Staleness gate (OBJ-1) checked at the SITE before the recompute
                // mutates the mesh; the helper re-checks as defense-in-depth.
                // P-C: the trigger spans falloff + snap + symmetry; a change in
                // any one re-grades + records ONE tagged in-session entry.
                FalloffPacket liveF  = currentFalloff(vts);
                SnapPacket     liveSn = currentSnap(vts);
                SymmetryPacket liveSy = currentSymmetry(vts);
                if (!falloffPacketsEqual(liveF, dragFalloff)
                 || !snapPacketsEqual(liveSn, dragSnap)
                 || !symmetryPacketsEqual(liveSy, dragSymmetry)) {
                    // Capture the pre-recompute (post-gesture) geometry LIVE for
                    // the once-per-run anchor (OBJ-3 W1: live, never frozen).
                    Vec3[] anchor = mesh.vertices.dup;
                    // P-A / P-C: PRE-tweak pipe config = the still-current
                    // captured packets (the geometry the gesture sat on); POST =
                    // the live (just-tweaked) packets. Captured BEFORE the
                    // re-read below so the entry's revert/apply hooks restore the
                    // whole config endpoints (falloff + snap + symmetry).
                    FalloffPacket  preF  = dragFalloff,  postF  = liveF;
                    SnapPacket     preSn = dragSnap,     postSn = liveSn;
                    SymmetryPacket preSy = dragSymmetry, postSy = liveSy;
                    // Re-capture the live packets via a FRESH evaluate so a
                    // just-enabled symmetry stage's pairOf is populated (see
                    // recaptureLivePipePackets); applyTRS below then mirrors. The
                    // POST hook packet (postSy) is the config-only `liveSy` from
                    // above — pairOf is rebuilt by evaluate() at undo/redo time,
                    // so the hook needs only the config fields.
                    recaptureLivePipePackets();
                    vertexCacheDirty = true;
                    // Apply-path Phase 2 (OBJ-1, decision (a)): full-fold
                    // re-grade of the committed gesture. Byte-identical to the
                    // old applyTRSForBank(Move) on a Move-only run (held R/S
                    // identity); composes the held banks otherwise. With symmetry
                    // toggled on mid-run, applyFold's mirror pass now drives the
                    // mirror partners (P-C). The anchor/after brackets still wrap
                    // exactly the recompute, so the recordPipeRefire before/after
                    // pair stays coherent.
                    applyTRS(dragBaseline);   // mutates mesh.vertices
                    Vec3[] after = mesh.vertices.dup;

                    // Index set = the full vertex range; pass an EMPTY idx so the
                    // helper iterates the whole range directly (S1 economy — no
                    // materialised identity array). The helper diffs against the
                    // anchor and keeps only moved verts (the symmetry mirror set
                    // is covered by the whole-mesh dragBaseline). The falloff
                    // support can be the whole mesh, so a full-range pass is the
                    // safe superset.
                    recordPipeRefire("Falloff", anchor, after,
                                     null, DragBank.Move,
                                     preF, postF, preSn, postSn, preSy, postSy);
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

        // Cross-bank single-winner hover/capture (two-pass hit-test → draw):
        // ONE shared arbiter over the falloff handles (registered first =
        // highest priority) + every enabled gizmo bank, resolve ONE
        // hot/captured part, THEN render.
        toolHandles.begin();
        if (fp.enabled && pipeGizmoHost !is null) pipeGizmoHost.registerInto(toolHandles, fp);
        registerGizmoHandles(toolHandles);
        // Capture precedence: a live falloff-handle drag wins; else the active
        // gizmo bank's dragAxis; scale suppresses all highlight during its drag.
        if      (pipeGizmoHost !is null && pipeGizmoHost.isDragging())  toolHandles.setHaul(pipeGizmoHost.capturedPart());
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
        if (fp.enabled && pipeGizmoHost !is null) pipeGizmoHost.drawGizmo(shader, vp, fp);

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
            Param.float_("TX", "Translate X", &run.t.x, 0.0f),
            Param.float_("TY", "Translate Y", &run.t.y, 0.0f),
            Param.float_("TZ", "Translate Z", &run.t.z, 0.0f),
            Param.float_("RX", "Rotate X",    &headlessRotate.x,    0.0f).angle(),
            Param.float_("RY", "Rotate Y",    &headlessRotate.y,    0.0f).angle(),
            Param.float_("RZ", "Rotate Z",    &headlessRotate.z,    0.0f).angle(),
            // Rotate-only fold blend selector (consumed in applyFold). "linear"
            // (MatrixLerp, default) keeps the reference-correct unified fold; "arc"
            // (PolarQuat) scales the rotation angle by the falloff weight, R(w*theta),
            // radius-preserving — used by xfrm.softRotate / xfrm.swirl.
            Param.enum_ ("rotFalloffBlend", "Rotate Falloff Blend",
                         &rotFalloffBlend,
                         [["linear", "Linear (matrix)"], ["arc", "Arc (angle)"]],
                         "linear").hidden(),
            Param.float_("SX", "Scale X",     &run.s.x,     1.0f),
            Param.float_("SY", "Scale Y",     &run.s.y,     1.0f),
            Param.float_("SZ", "Scale Z",     &run.s.z,     1.0f),
        ];
    }

    // When the config-driven transform form is rendering (forms_engine_plan.md
    // Phase 5 + 5b), it OWNS ALL the TRS value rows — Position (TX/TY/TZ),
    // Rotate (RX/RY/RZ) and Scale (SX/SY/SZ) — and drives them through the
    // reEvaluate() seam (a plain `interactive` tool.attr per axis). The legacy
    // moveSub/rotateSub/scaleSub.drawProperties() sliders must therefore NOT
    // also render, or two live widgets would fight over the same per-frame
    // edit (run.t / the rotate-scale activation deltas) and the
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

    // Test seam — the Move bank's live drag axis (0/1/2 axis, 3 center-box / most-
    // facing plane, 4/5/6 plane circles, -1 idle). Lets the gesture-chain test
    // confirm a center-box grab actually engaged dragAxis==3 (the basis-free path
    // excluded from gesture-frame chaining), rather than a rotated arrow.
    public int moveDragAxisPublic() const { return moveSub.dragAxisPublic(); }
    public int rotateDragAxisPublic() const { return rotateSub.dragAxisPublic(); }
    public int scaleDragAxisPublic() const { return scaleSub.dragAxisPublic(); }

    // Constraint-lock affordance seam — returns the Ctrl-locked axis index
    // (0=X 1=Y 2=Z) while a Ctrl center-drag lock is live, else -1.
    // Passthrough to MoveTool.constraintLockedAxis().
    public int constraintLockedAxis() const { return moveSub.constraintLockedAxis(); }

    // ----- Rendered-pose seam (flex_border_handles_plan.md Phase 4 step 1) ----
    //
    // The LIVE rendered per-bank gizmo orientation, so tests can witness the
    // rendered basis follow (or NOT follow) the gesture (bugs 2/3). CRITICAL
    // (Risk 7): these read the LIVE rendered `handler.axisX/Y/Z` (the basis
    // the bank actually drew this frame), NOT the frozen `runFrame*` — the
    // whole point is to observe the rendered orientation, which during a drag
    // is the Model-C render frame, distinct from the frozen input/apply frame.
    //
    // Each accessor returns the bank's right/up/fwd as a 3x3-in-Vec3 triple.
    public void moveRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        right = moveSub.handler.axisX;
        up    = moveSub.handler.axisY;
        fwd   = moveSub.handler.axisZ;
    }
    public void rotateRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        right = rotateSub.handler.axisX;
        up    = rotateSub.handler.axisY;
        fwd   = rotateSub.handler.axisZ;
    }
    public void scaleRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        right = scaleSub.handler.axisX;
        up    = scaleSub.handler.axisY;
        fwd   = scaleSub.handler.axisZ;
    }
    // The rotate ring's composed orientation = R_accum · frozenFrame (the
    // R_gesture·B0 the ring already draws, xfrm_transform.d ring compose). The
    // rotate bank's live handler.axis* IS that rendered ring orientation once
    // the Model-C render frame feeds it (Phase 2); before then it equals the
    // frozen idle basis. Published distinctly so a test can assert the ring
    // preview rate independently of the sibling banks.
    public void rotateRingFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        right = rotateSub.handler.axisX;
        up    = rotateSub.handler.axisY;
        fwd   = rotateSub.handler.axisZ;
    }

    // flex_border_handles_plan.md Model C — the SHARED rendered gizmo basis fed
    // to ALL enabled banks during a gesture:
    //
    //     renderBasis = (axisTracksSelection ? R_gesture : I) · B0
    //
    //   B0        = the gizmo basis FROZEN at gesture start. That is exactly the
    //               existing per-run frozen frame `runFrameR/U/F` (captured on the
    //               first applyTRS of the run; before the freeze, `currentBasis`
    //               == the about-to-be-frozen frame — same fallback the ring uses).
    //   R_gesture = the rotation accumulated DURING this gesture = the world run
    //               rotation now (`run.r`) relative to its gesture-start value
    //               (`gestureStart.r`): R_gesture = run.r · gestureStart.r⁻¹. For a
    //               move/scale gesture run.r == gestureStart.r ⇒ R_gesture = I, so
    //               renderBasis = B0 (frozen cross-bank — bug 2). For a rotate
    //               gesture it is the in-gesture ring rotation, so renderBasis is
    //               B0 rotated by the applied angle (matching the ring) — bug 3.
    //   axisTracksSelection = the single declared AxisStage capability (no mode
    //               branch). false ⇒ plain modes hold B0 (no sibling follow).
    //
    // When NOT dragging the wrapper keeps today's behavior: render = the live
    // `currentBasis` (so selecting different elements re-orients the idle gizmo).
    // Phase 3 (separate) handles post-release persistence; here a release reverts
    // to idle-live (a transient rotate-release snap is acceptable, Phase-3 work).
    private void renderBasis(out Vec3 rX, out Vec3 rY, out Vec3 rZ, ref VectorStack vts) {
        // Idle (no active gizmo drag).
        if (activeDrag is null) {
            // COMMIT B — a completed gesture left a persisted gesture-end basis
            // (R_gesture·B0). Hold it until selection/mode change so a flex rotate
            // release does NOT snap the rendered triples back to the world-snapped
            // idle currentBasis. Cleared on the same boundaries as softPlaced.
            //
            // GESTURE CHAINING: re-grabbing a handle WITHOUT changing selection now
            // chains off this persisted frame — begin*DragSession freezes the new
            // run's B0 from the unified frame (feeding BOTH render and apply
            // translate), and the sub-tools' input projection reads the same frame, so
            // render + input + apply all agree on the rotated frame for the whole
            // drag (no un-rotated pop). The frame re-pins each gesture (the move's
            // own settleGestureBasis), chaining across move→scale→… until a
            // selection/mode change clears it (clearFrame) → the first fresh
            // gesture re-derives the world-snapped basis again.
            if (frame.valid) {
                rX = frame.right; rY = frame.up; rZ = frame.axis;
                return;
            }
            // No persisted basis: live basis, exactly as before.
            currentBasis(rX, rY, rZ, vts);
            return;
        }
        // B0 — the gesture-frozen RENDER frame.
        //
        // WITHIN-SESSION CHAINING (render-only): runFrame is frozen ONCE per tool
        // session (lazily on the session's first applyTRS = at the FIRST gesture's
        // start). A SECOND gesture in the same session (the GUI keeps rotate→move in
        // one session) therefore inherits the FIRST gesture's runFrame — world if the
        // session opened on a rotate — and with gestureStart.r == run.r the
        // R_gesture below is I, so the handles would render WORLD even though the
        // prior rotate left a rotated frame (the user-found same-session bug).
        //
        // Fix the RENDER ONLY: when a prior gesture persisted a rotated frame
        // (frame.settled, selection/mode unchanged), source B0 from `frame` even
        // when runFrameValid. This corrects the rendered arrow/ring orientation.
        //
        // NOTE (task 0032, plan invariant ★): the claim that the apply path
        // "already lands worldDelta" held only for the ROTATED-INPUT case
        // (axis=Select/SelectAuto/Local, where the move projects onto run.r·B0 and
        // the fold's run.r cancels it). For the WORLD-INPUT case (Auto/None ACEN
        // where the rotate settles WORLD frame into `frame`, giving inputBasis=B0
        // and run.t=worldDelta), the old apply path yielded M=run.r·T(worldDelta)
        // — a rotated geometry delta. The `applyFold` translate de-rotation fix
        // (tdX/tdY/tdZ = run.rᵀ·inputBasis) corrects this for ALL configs;
        // render-only here remains the correct locus for the b0X/b0Y/b0Z source.
        Vec3 b0X, b0Y, b0Z;
        if (frame.valid) {
            // Persisted rotated frame — render it whether or not runFrame is valid
            // (within-session chain: runFrame may be the stale world frame).
            // frame.valid == (frame.settled && acenSettleAllowed()) by construction.
            b0X = frame.right; b0Y = frame.up; b0Z = frame.axis;
        } else if (runFrameValid) {
            b0X = runFrameR; b0Y = runFrameU; b0Z = runFrameF;
        } else {
            currentBasis(b0X, b0Y, b0Z, vts);
        }
        // axisTracksSelection — read the published axis mode (no stage lookup).
        bool tracksSelection = false;
        {
            import toolpipe.packets      : AxisPacket;
            import toolpipe.stages.axis  : AxisStage;
            if (auto ap = vts.get!AxisPacket())
                tracksSelection = AxisStage.modeTracksSelection(ap.type);
        }
        if (!tracksSelection) {
            rX = b0X; rY = b0Y; rZ = b0Z;     // plain / fixed axis modes hold B0
            return;
        }
        // R_gesture · B0. R_gesture = run.r · gestureStart.r⁻¹ (both pure
        // rotations ⇒ inverse = transpose of the 3x3). Apply to each frozen
        // basis vector (direction transform — these matrices have no translation).
        import math : transformPoint;
        float[16] gsInv = transpose3x3(gestureStart.r);
        float[16] rGesture = matMul4(run.r, gsInv);
        rX = transformPoint(rGesture, b0X);
        rY = transformPoint(rGesture, b0Y);
        rZ = transformPoint(rGesture, b0Z);
    }

    // Transpose of the upper-left 3x3 of a column-major float[16] (translation
    // column zeroed). For an orthonormal rotation this equals its inverse — used
    // to back out the gesture-start orientation when composing R_gesture.
    private static float[16] transpose3x3(float[16] m) pure nothrow @nogc @safe {
        return [
            m[0], m[4], m[8],  0,
            m[1], m[5], m[9],  0,
            m[2], m[6], m[10], 0,
            0,    0,    0,     1,
        ];
    }

    // "Did the gesture actually rotate / scale?" — the rotate/scale analogue of
    // the Move path's accumulatedWorldDelta length check, used to gate the
    // gesture-end settle (a degenerate no-motion grab must not pin softPlaced).
    // Compares only the relevant TRS component of the gesture-START vs gesture-END
    // run state; the other components are equal across a single-bank gesture.
    private static bool xformRotEqual(const ref XformState a, const ref XformState b)
        pure nothrow @nogc @safe {
        import std.math : fabs;
        enum float eps = 1e-6f;
        foreach (i; 0 .. 16)
            if (fabs(a.r[i] - b.r[i]) > eps) return false;
        return true;
    }
    private static bool xformScaleEqual(const ref XformState a, const ref XformState b)
        pure nothrow @nogc @safe {
        import std.math : fabs;
        enum float eps = 1e-6f;
        return fabs(a.s.x - b.s.x) <= eps
            && fabs(a.s.y - b.s.y) <= eps
            && fabs(a.s.z - b.s.z) <= eps;
    }

    private void setSharedGizmoPose(Vec3 center, ref VectorStack vts) {
        Vec3 bX, bY, bZ;
        renderBasis(bX, bY, bZ, vts);
        if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);
    }

    private bool compactPresentation() const {
        return handlePresentation == "compact";
    }

    // Element-move flow active? = the WGHT slot is falloff.element, so a
    // plain click relocates the gizmo onto the picked element (tryPickElement).
    // Mirrors MODO's ElementMove preset (center.element + falloff.element):
    // in that mode MODO drops the transform center handle (xfrm.transform
    // -16777211 vs the normal +EASFQG) so every click is an element pick, not
    // a center-handle grab. We match by hiding the Move centerBox below.
    private bool elementPickActive() const {
        auto fs = activeFalloffStage();
        return fs !is null && fs.type == FalloffType.Element;
    }

    private void registerGizmoHandles(ToolHandles th) {
        // Hide the Move center handle in the element-move flow (MODO parity):
        // invisible → ToolHandles.test() skips it (so a central click falls
        // through to tryPickElement) AND BoxHandler.draw early-outs (so it
        // isn't shown). Axis arrows / plane handles stay live.
        if (flagT)
            moveSub.handler.centerBox.setVisible(!elementPickActive());

        if (compactPresentation()) {
            // Bare Transform draws scale boxes at the same screen-space endpoints
            // as move arrows. Register scale first so hover and click prefer the
            // scale handle when they overlap.
            if (flagS) scaleSub.registerAxisHeadHandles(th, SCALE_BASE);
            if (flagR) rotateSub.registerPrincipalHandles(th, ROT_BASE);
            if (flagT) moveSub.registerCompactHandles(th, MOVE_BASE);
            return;
        }

        if (flagT) moveSub.registerHandles(th, MOVE_BASE);
        if (flagR) rotateSub.registerHandles(th, ROT_BASE);
        if (flagS) scaleSub.registerHandles(th, SCALE_BASE);
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
    // ε-exploration silent-hover setter (task 0033, Phase 3). Forwards to the
    // shared ToolHandles instance.  Called from app.d after tool construction
    // when ε-exploration is enabled; default false is byte-identical to before.
    public void setAiExploreSilentHover(bool silent) {
        toolHandles.setAiExploreSilentHover(silent);
    }
    // Public forwarder to the protected TransformTool.queryActionCenter so the
    // host can read the ACEN center to FREEZE as the kernel pivot at drag-start
    // (§4.4). Pivot-agnostic for 4a's Offset path; the seam R/S needs in 4b.
    public Vec3 actionCenter(ref VectorStack vts) { return queryActionCenter(vts); }

    version(unittest) bool routeResolvedHandlePartForTest(
            ref const SDL_MouseButtonEvent e, ref VectorStack vts, int hitPart) {
        return routeResolvedHandlePart(e, vts, hitPart);
    }

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
    // True between mouse-down and mouse-up of any gizmo/element haul. The host
    // freezes the element hover pick while this holds (only the dragged element
    // stays highlighted, not every element under the moving cursor).
    override bool isDragging() const { return activeDrag !is null; }

    override bool emitsLifecycleUndo() const { return true; }

    override bool wantsHoverForType(EditMode type) const {
        auto fs = activeFalloffStage();
        if (fs is null || fs.type != FalloffType.Element) return false;
        final switch (fs.elementMode) {
            case ElementMode.Auto:    return true;
            case ElementMode.Vertex:  return type == EditMode.Vertices;
            case ElementMode.Edge:    return type == EditMode.Edges;
            case ElementMode.Polygon: return type == EditMode.Polygons;
        }
    }

    // Pre-highlight the whole edge loop on hover ONLY when the active falloff
    // is Element type in EdgeLoops connect mode — the apply path expands a
    // picked edge to its loop ring (FalloffStage's EdgeLoops resolver), so the
    // hover preview should show the same ring. Any other connect mode (Ignore /
    // UseConnectivity / Rigid) or a non-Element falloff keeps the single-edge
    // hover. DYNAMIC (depends on the live stage config) so it stays a method
    // override like wantsHoverForType rather than a static flag.
    override bool wantsEdgeLoopHover() const {
        auto fs = activeFalloffStage();
        return fs !is null
            && fs.type == FalloffType.Element
            && fs.connect == ElementConnect.EdgeLoops;
    }

    // No queryActionCenter override here on purpose: ACEN is the
    // single source of truth for the gizmo pivot. When falloff.element
    // is active, ACEN.mode == element (set by the preset) and
    // ACEN.Element honours userPlaced first — tryPickElement below
    // pushes the picked element's centroid through setUserPlaced, so
    // ACEN.center == picked centroid for both the gizmo AND
    // FalloffStage.evaluate's `pickedCenter` snapshot (which now
    // reads state.actionCenter.center directly).

    private bool routeResolvedHandlePart(ref const SDL_MouseButtonEvent e,
                                         ref VectorStack vts,
                                         int hitPart) {
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
        auto latchedPart = latchedHandlePart(hitPart);

        if (flagT && allowMoveDispatch) {
            int resolvedMoveAxis = latchedPart.bank == LatchedHandleBank.Move
                                 ? latchedPart.localPart : -1;
            if (!moveSub.onMouseButtonDownWithResolvedAxis(e, vts,
                                                           resolvedMoveAxis))
                goto tryRotateBank;
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
                // Apply-path Phase 2: a relocate is a GEOMETRY-run boundary (the
                // pivot moved + the prior run committed) — re-capture the run
                // baseline at the relocated mesh on the fresh Move gesture below.
                resetRun();   // + P-F: relocate freezes a NEW run-frame (G8)
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
tryRotateBank:
        if (flagR && allowRotDispatch) {
            int resolvedRotateAxis = latchedPart.bank == LatchedHandleBank.Rotate
                                   ? latchedPart.localPart : -1;
            if (!rotateSub.onMouseButtonDownWithResolvedAxis(e, vts,
                                                             resolvedRotateAxis))
                goto tryScaleBank;
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
                // Apply-path Phase 2: relocate / no-axis click = geometry-run
                // boundary; re-capture the run baseline on the next gesture.
                resetRun();   // + P-F: this boundary freezes a NEW run-frame
            }
            activeDrag = rotateSub; return true;
        }
tryScaleBank:
        if (flagS && allowScaleDispatch) {
            int resolvedScaleAxis = latchedPart.bank == LatchedHandleBank.Scale
                                  ? latchedPart.localPart : -1;
            if (!scaleSub.onMouseButtonDownWithResolvedAxis(e, vts,
                                                            resolvedScaleAxis))
                goto noBankConsumed;
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
                // Apply-path Phase 2: relocate / no-axis click = geometry-run
                // boundary; re-capture the run baseline on the next gesture.
                resetRun();   // + P-F: this boundary freezes a NEW run-frame
            }
            activeDrag = scaleSub;  return true;
        }
noBankConsumed:
        return false;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Gizmo-handle hit test FIRST. When a click hits a registered shared
        // handle, dispatch only to that handle's bank; otherwise the Move bank
        // may consume a rotate/scale click as an off-gizmo relocate before R/S
        // see it. Computing hitPart up front is also load-bearing for the
        // element-pick gate below: a click on a transform handle is an
        // on-handle drag, NEVER an element pick/relocate.
        int hitPart = -1;
        if (e.button == SDL_BUTTON_LEFT) {
            toolHandles.begin();
            registerGizmoHandles(toolHandles);
            hitPart = toolHandles.test(e.x, e.y, cachedVp,
                                       AiInteractionPhase.mouseDown);
            if (compactPresentation() && flagS && hitPart < 0) {
                int scaleHeadAxis = scaleSub.hitTestAxisHeads(e.x, e.y);
                hitPart = compactScaleHeadFallbackHitPart(
                    compactPresentation(), flagS, hitPart, scaleHeadAxis);
            }
        }

        // Element-falloff click-pick PRE-step: when falloff.element
        // is active and the user clicks any element (vert/edge/face)
        // with no modifier keys, we push the picked element's
        // centroid through ACEN.setUserPlaced. ACEN.center then
        // becomes that point for every consumer (gizmo via
        // queryActionCenter, falloff sphere via state.actionCenter.center).
        // This DOES NOT add the picked element to the moving set —
        // ElementMove uses pick only as the pivot/anchor. The drag
        // moves the prior selection through the falloff sphere.
        //
        // Gated on `hitPart < 0`: a click that landed on a gizmo handle is an
        // on-handle drag and must NOT relocate. (Before the host refreshed
        // hover at mouse-down, a STALE empty-space hover hid this — grabbing
        // an arrow that overlaps a face would otherwise pick that face.)
        bool picked = false;
        bool ctrlMod = false;
        if (e.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            ctrlMod = (mods & KMOD_CTRL) != 0;
            // Ctrl is the axis-lock modifier for the screen-plane drag this pick
            // opens (forwarded as `ctrlMod` to beginScreenPlaneDragAt below), so
            // it MUST be allowed through the pick gate — gating on a no-modifier
            // `plain` swallowed Ctrl, leaving Element Move with no axis-lock.
            // Alt stays excluded (Ctrl+Alt+LMB = camera zoom, dispatched to the
            // view before the tool); Shift stays excluded (selection add).
            bool pickAllowed = (mods & (KMOD_ALT | KMOD_SHIFT)) == 0;   // Ctrl OK
            if (pickAllowed && hitPart < 0) picked = tryPickElement(e.x, e.y);
        }

        // Falloff endpoint handles claim the click first (Linear/Radial),
        // routed at the wrapper through the host-owned falloff emitter.
        if (e.button == SDL_BUTTON_LEFT) {
            FalloffPacket curFp = currentFalloff(vts);
            if (pipeGizmoHost !is null && pipeGizmoHost.tryClaimDown(e, cachedVp, curFp, toolHandles)) {
                activeDrag = null;   // falloff owns the drag, no gizmo bank
                return true;
            }
        }
        if (routeResolvedHandlePart(e, vts, hitPart))
            return true;

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
            // Apply-path Phase 2: an element-pick relocate is a geometry-run
            // boundary (pivot moved + prior run committed); re-capture the run
            // baseline at the relocated mesh on the fresh Move gesture below.
            resetRun();   // + P-F: relocate freezes a NEW run-frame (G8)
            // The fresh screen-plane drag below is a Move gesture; record its
            // bank (no-op switch when the prior run was also Move).
            noteRunBank(DragBank.Move);
            // Use the LIVE ACEN center, NOT queryActionCenter(vts): the `vts`
            // ActionCenterPacket was evaluated at the START of this frame —
            // BEFORE tryPickElement ran this mouse-down — so it still holds the
            // PRE-pick center (the old gizmo position / mesh centroid). The
            // ACEN stage's currentCenter() recomputes live and already reflects
            // the just-picked element (elementVerts_). Feeding the stale packet
            // here anchored the drag at the OLD center, so the gizmo moved
            // relative to its old location instead of jumping onto the picked
            // vertex first — the reported bug.
            auto acForPivot = activeAcenStage();
            Vec3 pivot = acForPivot !is null
                ? acForPivot.currentCenter()
                : queryActionCenter(vts);
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
                // Apply-path Phase 2: the P5 off-gizmo-in-relocate-DISALLOWED
                // click is a geometry-run boundary; re-capture on the next drag.
                resetRun();   // + P-F: this boundary freezes a NEW run-frame
            }
        }
        return false;
    }

    private void resetGestureAttrs() {
        // Struct-init reset — t=(0,0,0)/r=identity/s=(1,1,1) per XformState field
        // defaults. Also refresh the derived euler display (identity ⇒ 0).
        run = XformState.init;
        headlessRotate = Vec3(0, 0, 0);
    }

    // P-F — geometry-run boundary reset. Factored so EVERY `runBaselineValid =
    // false` site clears the frozen run-frame (and, as each field migrates to
    // run-absolute, its run-start value) together with the geometry-run baseline,
    // so a relocate resets DISPLAY + GEOMETRY as one (G8 relocate->0). Called at
    // all 11 boundary sites. Phase 1: only the frozen frame resets here; the
    // run-absolute field resets are added as each field migrates (Phase 2 Move,
    // Phase 3 R/S).
    private void resetRun() {
        // P-F Phase 2 — Move is run-absolute, so a geometry-run boundary that
        // ends an ACTIVE run (relocate / selection change after a gesture / tool
        // drop) resets the DISPLAY field with the geometry baseline (G8
        // relocate->0). GATE on `runBaselineValid`: only an established geometry
        // run (set by beginRunGesture on a gizmo gesture) carries a run-absolute
        // field worth resetting. A bare headless `tool.attr move TX v` write at
        // idle leaves runBaselineValid == false (the bare-write reEvaluate path
        // sets runFrameValid, never runBaselineValid), so a subsequent selection-
        // change boundary must NOT wipe that pending headless apply input — the
        // headless scripting contract (set-attr, then select, then doApply).
        bool hadRun = runBaselineValid;
        runBaselineValid = false;
        runFrameValid    = false;
        // P-F Phase 3a (MAJOR-4) — a run boundary re-freezes the baseline from the
        // current mesh on the next beginRunGesture, at which point the GPU buffer
        // (uploaded at the prior gesture's mouse-up) reflects that baseline. So the
        // buffer-vs-baseline invariant resets clean: the next run starts with
        // buffer == frozen baseline. Unconditional (not gated on hadRun): even a
        // bare-write boundary leaves the buffer == mesh == next baseline.
        runGpuBufferDirty = false;
        if (hadRun) {
            // P-F Phase 3 — on the resync-after-undo path the per-gesture revert/
            // apply hooks already restored each display field to the reverted-to
            // step's run total (during history.undo(), which runs before resync),
            // so this run-boundary field-zero must be SUPPRESSED there or it would
            // clobber that value (panel would snap back to identity while the
            // geometry sits at gesture-1's pose). Every OTHER resetRun() caller
            // (relocate / selection-change / mode-change / tool-drop / cancel)
            // leaves resyncPreserveDisplayFields == false and zeroes exactly as
            // before — preserving the G8 relocate->identity contract. The gesture-
            // start bookkeeping is always cleared (re-primed at the next gesture's
            // begin*DragSession), only the published display field is preserved.
            if (!resyncPreserveDisplayFields) {
                // P-F Phase 3a/3b — a geometry-run boundary that ended an ACTIVE
                // run resets the WHOLE run to identity with the geometry baseline
                // (G8 relocate->0 for T/R, relocate->1 for S). Struct-init reset:
                // t=(0,0,0)/r=identity/s=(1,1,1) per XformState field defaults,
                // plus the derived euler display (identity ⇒ 0).
                run = XformState.init;
                headlessRotate = Vec3(0, 0, 0);
            }
            // P-F Phase 3 — the per-gesture snapshot is the WHOLE `gestureStart`
            // struct (re-captured at the next gesture's begin*DragSession); only
            // the per-bank "known" flags need clearing at a run boundary.
            moveGestureStartKnown   = false;
            scaleGestureStartKnown  = false;
            // The view-ring run flag clears so the next run's first principal
            // gesture does not see a stale post-view-ring re-bake demand.
            rotateGestureStartKnown = false;
            runPriorRotateWasViewRing  = false;
        }
    }

    // Matrix-truth identity test for the rotate run. Gates the "is a rotation
    // held?" checks on `run.r` (the truth) rather than the DERIVED euler
    // `headlessRotate`: at a gimbal-lock pose the decomposed euler can read zero
    // while `run.r` is a genuine non-identity orientation, so an euler test would
    // mis-detect a held rotation as "none". The matrix accumulates float drift
    // across composed gestures, so this is an epsilon-tolerant element-wise
    // compare against the identity literal, not an exact `==`.
    private bool runRotIsIdentity() const {
        import std.math : abs;
        enum float eps = 1e-6f;
        foreach (i; 0 .. 16)
            if (abs(run.r[i] - identityMatrix[i]) > eps)
                return false;
        return true;
    }

    private bool bankIsNonIdentity(DragBank bank) {
        final switch (bank) {
            case DragBank.None:   return false;
            case DragBank.Move:   return run.t.x != 0
                                       || run.t.y != 0
                                       || run.t.z != 0;
            // Gimbal-correct: test the rotate truth `run.r`, not the derived euler.
            case DragBank.Rotate: return !runRotIsIdentity();
            case DragBank.Scale:  return run.s.x != 1
                                       || run.s.y != 1
                                       || run.s.z != 1;
        }
    }

    private void resetBankAttr(DragBank bank) {
        final switch (bank) {
            case DragBank.None:   break;
            case DragBank.Move:   run.t = Vec3(0, 0, 0); break;
            case DragBank.Rotate: headlessRotate    = Vec3(0, 0, 0); break;
            case DragBank.Scale:  run.s     = Vec3(1, 1, 1); break;
        }
    }

    // Run-baseline + held-attr discipline for a gizmo gesture (apply-path
    // unification Phase 2). Replaces the three identical per-gesture
    // `dragBaseline` dups + the blanket `resetGestureAttrs()` that each
    // `begin*DragSession` used to do. Called from each `begin*DragSession`
    // AFTER falloff/symmetry capture but BEFORE the fast-path predicate.
    //
    // Two cases, chosen so cross-bank gestures compose through ONE fold while
    // same-bank repeats stay byte-identical to the pre-refactor per-gesture
    // re-baseline:
    //   (A) FRESH RUN (`!runBaselineValid`) OR a SAME-bank repeat (this bank
    //       already holds a non-identity run-absolute, e.g. move-then-move):
    //       re-capture the run baseline from the CURRENT mesh and reset ALL
    //       held attrs to identity. A same-bank repeat re-baselines because
    //       the gizmo producer emits a value relative to THIS drag's start
    //       (move `+=` incremental, rotate/scale drag-absolute), so the prior
    //       same-bank gesture must be baked into the baseline to accumulate —
    //       exactly the old behaviour. A fresh run starts a new geometry run.
    //   (B) CROSS-bank into a bank with NO held value (e.g. move-then-rotate):
    //       REUSE the run baseline and reset ONLY this bank's attr (a no-op,
    //       since it is identity), so the HELD banks survive into the fold and
    //       `composeFor` folds active-live ⊕ held from ONE original baseline.
    private void beginRunGesture(DragBank bank) {
        // P-F Phase 2/3a — Move AND Scale are RUN-ABSOLUTE. A same-bank Move or
        // Scale repeat must NOT re-bake the prior gesture into `dragBaseline` and
        // must NOT zero its field (`run.t` / `run.s`): the run
        // keeps ONE frozen baseline and the field accumulates the run total across
        // gestures. Move's drain does `run.t += pending`; Scale's drain
        // (1677 `run.s = f`) writes the within-run absolute factor anchored
        // at the run-start accumulator (dragStartScaleAccum), so a same-axis repeat
        // multiplies into the run total. Scale factors commute per-axis ⇒ no
        // cross-axis hazard, fully run-absolute exactly like Move.
        //
        // Only a genuinely fresh run (`!runBaselineValid`) re-captures. For Move
        // and Scale the re-bake trigger is ONLY `!runBaselineValid`;
        // `bankIsNonIdentity` no longer forces a re-bake for those banks (that was
        // the pre-(c) per-gesture re-baseline-and-zero).
        //
        // P-F Phase 3b — Rotate is RUN-ABSOLUTE for REPEATED SAME-AXIS principal
        // gestures: the field accumulates that one axis and stays byte-frozen for
        // the run, exactly like Move/Scale (no re-bake, no resetBankAttr). Rotations
        // do NOT commute, so the field can hold only a SINGLE axis run-absolutely —
        // a CROSS-axis gesture (the drain is about to write a DIFFERENT component
        // than the held non-zero one) OR a gesture after a VIEW-RING (whose angle
        // never enters the Euler field) MUST re-bake: the held rotation bakes into
        // dragBaseline via the current mesh and the field zeros, so the new axis
        // starts fresh against the baked pose (sequential geometry, no fixed-order
        // Euler corruption — today's geometry-carried fallback for those
        // transitions). The view-ring gesture itself always re-bakes for the same
        // reason. `rotateRunNeedsRebake` reads `rotateSub.dragAxis` — the SETTLED
        // drag axis (rotateSub.onMouseButtonDown ran before this call, per the
        // 1003/1011 dispatch contract), NOT the not-yet-published pendingRotateAxis.
        bool rebake = !runBaselineValid
                   || (bank == DragBank.Rotate && rotateRunNeedsRebake());
        if (rebake) {
            dragBaseline.length = mesh.vertices.length;
            foreach (i; 0 .. mesh.vertices.length)
                dragBaseline[i] = mesh.vertices[i];
            resetGestureAttrs();
            runBaselineValid = true;
        }
        // else: reuse the held baseline; held banks stay. ALL THREE banks are now
        // run-absolute on the frozen (no-rebake) path, so NONE reset its bank attr
        // here — the field carries the run total across same-bank gestures (Move/
        // Scale per-axis-commutative; Rotate same-axis-only, with cross-axis/
        // view-ring forced onto the REBAKE branch above where resetGestureAttrs
        // zeroes the field). P-F Phase 3b removed the old `resetBankAttr(Rotate)`
        // here: it was a no-op only while Rotate ALWAYS re-baked on a non-identity
        // field; now a same-axis rotate-after-rotate takes this frozen branch with a
        // HELD field that MUST survive (zeroing it here clobbered the run total,
        // collapsing the second same-axis gesture to a no-op).
    }

    // P-F Phase 3b — does this Rotate gesture force a run re-bake? Same-axis
    // principal repeat (with no intervening view-ring) takes the Move/Scale frozen
    // branch (returns false). A re-bake (returns true) is forced when:
    //   - this gesture drives the VIEW-RING (dragAxis == 3): its angle is a
    //     transient axis-angle param, never stored in the Euler field, so it must
    //     bake the held rotation into geometry and start clean; OR
    //   - the PRIOR gesture in this run was a view-ring
    //     (`runPriorRotateWasViewRing`): the held view-ring rotation lives only in
    //     the baked geometry, so the incoming principal gesture must re-bake to
    //     compose on top of it; OR
    //   - CROSS-axis: the held `headlessRotate` carries a non-zero component on an
    //     axis DIFFERENT from the principal axis this gesture is about to write
    //     (dragAxis 0/1/2 → x/y/z). Re-baking bakes the held axis into geometry
    //     and zeros the field so the new axis starts fresh against the baked pose
    //     (the held rotation is PRESERVED in the re-baked baseline, not lost — and
    //     not doubled, because the field is zeroed by the re-bake).
    // The SETTLED drag axis is `rotateSub.dragAxis` (settled by
    // rotateSub.onMouseButtonDown before this runs); pendingRotateAxis is not yet
    // published at mouse-down.
    private bool rotateRunNeedsRebake() {
        immutable int ax = rotateSub.dragAxis;
        // The PER-CLUSTER ACEN.Local path STAYS LEGACY (the matrix-truth model is
        // GLOBAL-only — a single world rotation matrix re-applied about each
        // cluster's diverged local axes diverges). It keeps the per-gesture cross-
        // axis re-bake AND the view-ring re-bake (the view-ring is folded onto the
        // global run.r, which the per-cluster fold does not consume), so its
        // field carries ONE live axis per cluster gesture.
        if (rotateGesturePerClusterLocal) {
            if (ax == 3) return true;                 // view-ring → re-bake
            if (runPriorRotateWasViewRing) return true;
            immutable bool hx = headlessRotate.x != 0;
            immutable bool hy = headlessRotate.y != 0;
            immutable bool hz = headlessRotate.z != 0;
            if (ax == 0) return hy || hz;   // dragging X: any held Y/Z is cross-axis
            if (ax == 1) return hx || hz;   // dragging Y: any held X/Z is cross-axis
            if (ax == 2) return hx || hy;   // dragging Z: any held X/Y is cross-axis
            return bankIsNonIdentity(DragBank.Rotate);   // defensive (ax<0): legacy
        }
        // MATRIX-AS-TRUTH (global path) — NOTHING re-bakes. run.r is the
        // world-space accumulated rotation; cross-axis AND view-ring gestures fold
        // their increment onto it (about the frozen ring axis / captured world
        // axis), and composeFor applies it directly. History lives in the matrix +
        // the frozen baseline, not in re-baked geometry. Only a genuinely fresh run
        // re-captures (beginRunGesture via !runBaselineValid).
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
    //   - `run.t`: zeroed so this drag's accumulated
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
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger
        beginEdit();   // idempotent — opens tool-session edit on first call

        // `cachedVp` is already up to date from the most recent
        // `draw()` call (every frame, before any event dispatch);
        // `applyTRS` reuses it for falloff weight evaluation.

        // Run-scoped baseline + held-attr discipline (apply-path Phase 2):
        // capture once per geometry run (or re-baseline a same-bank repeat),
        // preserving held R/S into the fold on a cross-bank move gesture.
        beginRunGesture(DragBank.Move);
        // P-F Phase 3 — capture THIS gesture's run-absolute START (the WHOLE run
        // state before this gesture's drain). AFTER beginRunGesture so a fresh run
        // (just zeroed) snapshots the identity state and a same-bank repeat
        // snapshots the held run total. The unified commit hook restores
        // gestureStart (run-START) / run (run-END); for a Move gesture only run.t
        // changes, so the R/S fields of the snapshot are inert (start == end).
        gestureStart          = run;
        moveGestureStartKnown = true;
        // Gesture-START gizmo BASIS snapshot for the undo splice (mirror of the
        // soft-pin capture in beginEdit). Move never rotates the frame, so
        // frameStart == frameEnd at commit and the restore is an identity no-op.
        moveFrameStart = frame;
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

        // Re-gate the unified `frame` for this gesture (it carries the persisted,
        // possibly-chained gesture-end basis) under the same Element/Local gate the
        // chained reads use.
        refreshFrameValid();
        // Gesture-frame unification, Phase 2 — push the unified frame into the
        // Move bank's WRAPPED input-projection channel. This replaces the prior
        // hand-synced `inputBasis*` override: the channel carries `frame` (the
        // persisted gesture frame when chained), and the bank's DECOMPOSE reads
        // project the world delta onto it. The `chained` gate mirrors the old
        // override guard EXACTLY — `frame.valid` is `frame.settled &&
        // acenSettleAllowed()` — and
        // the center-box free-plane drag (dragAxis 3) is BASIS-FREE/screen-plane,
        // so it is excluded here (passes chained=false) and falls back to the
        // bank's live `inputBasis*` — its decompose and re-expand share the live
        // basis so they cancel and the drag stays screen-plane (the apply runFrame
        // swap + visual center-follow are excluded the same way via
        // moveCenterBoxDragActive()). Note: a center-box GRAB returns dragAxis 3
        // from hitTestAxes and does NOT relocate — only beginScreenPlaneDragAt
        // (the off-gizmo click-relocate) does.
        moveSub.setWrapperInputFrame(frame.right, frame.up, frame.axis,
            frame.valid && moveSub.dragAxis != 3);
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
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger

        // NOTE: the rotate edit SESSION is owned by `rotateSub` (its
        // `onMouseButtonDown` calls `beginEdit`, and its `deactivate`/`update`
        // commit "Rotate" with the display-state undo hooks). The wrapper here
        // captures only the GEOMETRY drag state (`dragBaseline`/falloff/
        // symmetry/fast-path); the geometry is applied through `applyTRS`. The
        // session deliberately stays on `rotateSub` (MS-5 decision) — keeping
        // it there avoids the cross-instance commit problem entirely.

        // Run-scoped baseline + held-attr discipline (apply-path Phase 2/3b): a
        // cross-bank rotate (e.g. after a held move) reuses the run baseline +
        // resets ONLY headlessRotate, so the held translate survives into the
        // composed fold. For Rotate (Phase 3b, run-absolute same-axis-only) a
        // SAME-AXIS principal repeat keeps the frozen baseline + accumulates the
        // field; a CROSS-axis / view-ring transition re-bakes (rotateRunNeedsRebake
        // reads rotateSub.dragAxis, settled above). beginRunGesture MUST run BEFORE
        // the view-ring flag is updated below so it sees the PRIOR gesture's value.
        //
        // Matrix-as-truth: capture whether this gesture is per-cluster ACEN.Local
        // BEFORE beginRunGesture, so rotateRunNeedsRebake can keep the per-cluster
        // path on the LEGACY cross-axis re-bake while the GLOBAL path takes the
        // no-rebake matrix-truth branch (run.r accumulates everything).
        {
            auto cpRb = queryClusterPivots(vts);
            auto apRb = queryClusterAxes(vts);
            rotateGesturePerClusterLocal = cpRb.active && apRb.active;
        }
        beginRunGesture(DragBank.Rotate);

        // P-F Phase 3 — capture THIS gesture's run-absolute START (the WHOLE run
        // state before this gesture's drain). AFTER beginRunGesture so a fresh run
        // or a re-baked transition (just zeroed) snapshots the identity state and a
        // same-axis repeat snapshots the held run orientation. The drain composes
        // this gesture's incremental ring rotation onto gestureStart.r (the run
        // orientation BEFORE this gesture), and the unified commit hook restores
        // gestureStart (run-START) / run (run-END). For a Rotate gesture only run.r
        // (and its derived euler) changes, so the T/S fields of the snapshot are
        // inert (start == end). DISTINCT from the sub-tool accumulator anchor
        // (angleAccum) — undo-only, never a fold input.
        gestureStart            = run;
        rotateGestureStartKnown = true;
        // flex_border_handles_plan.md Phase 3 (BUG-1, undo-splice) — capture the
        // gesture-START soft pin LIVE here so the rotate undo hook can restore it
        // on revert (gesture-1 of a run: typically cleared → pivot recomputes;
        // gesture-2+: the prior gesture's settle). Mirrors the Move W1 capture.
        if (auto ac = activeAcenStage()) {
            rotateSoftStartPlaced = ac.isSoftPlaced();
            rotateSoftStartCenter = ac.currentSoftCenter();
        } else {
            rotateSoftStartPlaced = false;
            rotateSoftStartCenter = Vec3(0, 0, 0);
        }
        // Capture the gesture-START gizmo BASIS for the undo splice (mirrors the
        // soft-pin capture above). For gesture-1 of a run this is typically the
        // unsettled default; for gesture-2+ it is the prior gesture's persisted
        // rotated frame (chaining). Revert restores exactly this on Ctrl+Z.
        rotateFrameStart = frame;
        // Track whether THIS gesture is a view-ring, for the NEXT gesture's
        // post-view-ring re-bake decision. Set AFTER beginRunGesture consumed the
        // prior value above.
        runPriorRotateWasViewRing  = (rotateSub.dragAxis == 3);

        // Ring index: 0/1/2 = principal (Euler slot), 3 = view-ring (axis-angle
        // slot). Both are wrapper-owned now; clamp anything else to -1
        // defensively.
        rotDragAxisIdx = (rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3)
                       ? rotateSub.dragAxis : -1;

        // Gesture chaining (flex_border_handles_plan.md) — when a prior
        // same-session gesture left a persisted gizmo frame (frame.settled, and
        // the selection/mode has not changed to clear it), this PRINCIPAL rotate
        // gesture must rotate about the DISPLAYED rotated ring axis, not the stale
        // world-snapped runFrame. The render already draws the ring at
        // R_gesture·frame (setGizmoRenderBasis ~1002) — without this the apply
        // would rotate about world X while the ring shows rotated X (the
        // user-found same-session bug: rotate Z, then grab X → X rotates about
        // world X). Two coupled chained reads, gated identically to where the basis
        // is settled (acenSettleAllowed mirrors the Element/Local exclusion):
        //   (1) the APPLY ring axis — the drain (~2232) reads `frame.{right,up,axis}`
        //       in place of runFrame{R,U,F}, the ONLY apply consumer that needs
        //       chaining (run.t / the translate fold are UNTOUCHED, so the
        //       move-after-rotate translate algebra stays correct — see the
        //       render-only note at ~989); and
        //   (2) the INPUT measurement plane — re-derive the sub-tool's frozen
        //       dragAxisVec / dragRefDir off the unified `frame`, so the measured
        //       angle is read in the rotated ring's plane (rotate freezes those at
        //       button-down, so a bare write would be too late — the channel push
        //       below re-derives them; gesture-frame unification Phase 2).
        // The VIEW-RING (rotDragAxisIdx == 3) is camera-axis basis-independent and
        // EXCLUDED (mirrors moveCenterBoxDragActive() excluding the move
        // center-box dragAxis 3). Both the apply read and the input channel
        // self-guard to 0/1/2.

        auto cp = queryClusterPivots(vts);
        // Same once-per-drag freeze contract as `moveDragFastPath`; see its
        // anti-relocation note. Do NOT recompute mid-drag.
        rotDragFastPath = !dragFalloff.enabled
                       && !dragSymmetry.enabled
                       && !cp.active
                       && (vertexProcessCount
                           == cast(int)mesh.vertices.length);

        // Re-gate the unified `frame` for this gesture (see beginMoveDragSession).
        refreshFrameValid();
        // Gesture-frame unification, Phase 2 — push the unified frame into the
        // Rotate bank's WRAPPED input channel, which re-derives the frozen
        // principal dragAxisVec/dragRefDir from it (the freeze-ordering trap:
        // button-down already froze them from the live basis BEFORE this runs).
        // The channel carries `frame` (the persisted gesture frame when chained), so
        // the rotation plane is byte-identical to the prior rechain. Gate mirrors the
        // apply read exactly — `frame.valid` is `frame.settled && acenSettleAllowed()`
        // — and the view-ring (rotDragAxisIdx == 3) is excluded (the channel push and
        // its re-derivation both self-guard to principal rings 0/1/2).
        rotateSub.setWrapperInputFrame(frame.right, frame.up, frame.axis,
            frame.valid && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 2);
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
    //   - `run.s`: reset to identity (1,1,1) — this drag's
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
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger

        // Run-scoped baseline + held-attr discipline (apply-path Phase 2): a
        // cross-bank scale reuses the run baseline + resets ONLY run.s,
        // so held T/R survive into the composed fold. For Scale (run-absolute,
        // Phase 3a) a scale-after-scale does NOT re-bake/zero: the run keeps ONE
        // frozen baseline and run.s accumulates the run-total factor.
        beginRunGesture(DragBank.Scale);
        // P-F Phase 3 — capture THIS gesture's run-absolute START (the WHOLE run
        // state before this gesture's drain). AFTER beginRunGesture so a fresh run
        // (just zeroed to identity) snapshots the identity state and a same-bank
        // repeat snapshots the held run-total factor. The unified commit hook
        // restores gestureStart (run-START) / run (run-END); for a Scale gesture
        // only run.s changes, so the T/R fields of the snapshot are inert
        // (start == end). DISTINCT from the sub-tool accumulator anchor
        // dragStartScaleAccum — undo-only, never a fold input.
        gestureStart           = run;
        scaleGestureStartKnown = true;
        // flex_border_handles_plan.md Phase 3 (BUG-1, undo-splice) — capture the
        // gesture-START soft pin LIVE (mirror of the rotate/Move capture) so the
        // scale undo hook restores it on revert.
        if (auto ac = activeAcenStage()) {
            scaleSoftStartPlaced = ac.isSoftPlaced();
            scaleSoftStartCenter = ac.currentSoftCenter();
        } else {
            scaleSoftStartPlaced = false;
            scaleSoftStartCenter = Vec3(0, 0, 0);
        }
        // Gesture-START gizmo BASIS snapshot for the undo splice (mirror of the
        // soft-pin capture). Scale never rotates the frame, so frameStart ==
        // frameEnd at commit and the restore is an identity no-op.
        scaleFrameStart = frame;

        auto cp = queryClusterPivots(vts);
        // Same once-per-drag freeze contract as `moveDragFastPath`; see its
        // anti-relocation note. Do NOT recompute mid-drag.
        scaleDragFastPath = !dragFalloff.enabled
                         && !dragSymmetry.enabled
                         && !cp.active
                         && (vertexProcessCount
                             == cast(int)mesh.vertices.length);
        scaleDragActive = true;

        // Re-gate the unified `frame` for this gesture (see beginMoveDragSession).
        refreshFrameValid();
        // Gesture-frame unification, Phase 2 — push the unified frame into the
        // Scale bank's WRAPPED input channel (mirror of the Move push). Replaces
        // the prior hand-synced inputBasis* override; the channel carries `frame`
        // (the persisted gesture frame when chained), so an axis scale after a
        // rotate scales along the rotated axes the rendered boxes show —
        // byte-identical input. `frame.valid` is the `frame.settled &&
        // acenSettleAllowed()` gate the old override used (scale has no center-box
        // exclusion).
        scaleSub.setWrapperInputFrame(frame.right, frame.up, frame.axis, frame.valid);
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (pipeGizmoHost !is null && pipeGizmoHost.isDragging())
            return pipeGizmoHost.routeMotion(e, cachedVp);
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
                // `run.t`. Idle / hover branches in
                // moveSub leave `pendingTranslateDelta` at zero, so
                // the drain is a no-op on those.
                Vec3 pending = moveSub.pendingTranslateDelta;
                moveSub.pendingTranslateDelta = Vec3(0, 0, 0);
                // Apply-path Phase 2: update ONLY this bank's attr. The held
                // R/S run-absolutes are NOT zeroed — they compose into the fold
                // via `applyTRS`'s preset flags (composeFor folds T·R·S from one
                // run baseline). Pre-Phase-2 this drain force-zeroed R/S so the
                // single-bank `applyTRSForBank(Move)` saw only translate.
                run.t = run.t + pending;

                // Visual: the gizmo center moves along the GLOBAL
                // basis projection of `run.t` (same
                // projection `applyTRS` does in the non-per-cluster
                // branch). Per-cluster doesn't have a single
                // visible "gizmo center" — the gizmo follows the
                // ACEN centroid which `update()` re-evaluates from
                // the moved verts on the next frame.
                // The center-box free-plane drag (dragAxis 3) decomposed `pending`
                // against the LIVE inputBasis (NOT the rotated gesture frame), so its
                // visual follow must re-expand along that SAME live inputBasis — else
                // the center drifts off the cursor by the gizmo rotation R. The
                // axis/plane grabs decomposed against the rendered frame (= rotated
                // handler.axis* when chaining), so they expand along handler.axis*.
                Vec3 eX, eY, eZ;
                if (moveCenterBoxDragActive()) {
                    eX = moveSub.inputBasisX; eY = moveSub.inputBasisY; eZ = moveSub.inputBasisZ;
                } else {
                    eX = moveSub.handler.axisX; eY = moveSub.handler.axisY; eZ = moveSub.handler.axisZ;
                }
                Vec3 worldStep = eX * pending.x + eY * pending.y + eZ * pending.z;
                accumulatedWorldDelta = accumulatedWorldDelta + worldStep;

                // Single per-frame mesh mutation through applyTRS with the
                // PRESET flags (apply-path Phase 2 — no per-bank force). For a
                // single-bank Move preset this folds T only; for a composed
                // Transform preset it folds the held R/S too. run.t
                // carries the running basis-local scalar; under ACEN.Local it
                // flows into `applyTranslatePerCluster`, otherwise into the
                // global-basis branch.
                //
                // Skip applyTRS when the WHOLE fold is identity: T=0, R=I,
                // S=1, and the current motion event contributed zero delta.
                // Under these conditions applyFold writes `anchor + M_lin*d +
                // off` with M_lin=I, t_fold=0, which in exact arithmetic is
                // `base` — no geometric effect. The old float formula
                // (pivot + applyAffine(I, base-pivot)) could introduce a 1-ULP
                // round-trip error (base-pivot+pivot ≠ base), producing a
                // spurious mesh.vertex_edit on a zero-motion relocate click at
                // a far pivot. The stable double-kernel (0061) eliminates that
                // drift, so the identity fold is now truly a no-op — and must
                // be skipped so `buildEditCmd` correctly returns null rather than
                // recording a phantom geometry edit.
                //
                // The "composed preset pivot matters" concern only applies when
                // the held R or S are non-identity: re-applying a non-trivial
                // rotation/scale at a NEW pivot genuinely changes geometry. When
                // BOTH are identity the whole fold reduces to the identity
                // regardless of pivot, so the skip is safe for ANY preset.
                //
                // This skip ONLY fires on a zero-distance drag frame
                // (pending==0, run.t==0, run.r==I, run.s==(1,1,1)); any
                // actual motion or held non-identity bank takes the live path.
                bool skipIdentityFold = pending.x == 0 && pending.y == 0
                                     && pending.z == 0
                                     && !bankIsNonIdentity(DragBank.Move)
                                     && !bankIsNonIdentity(DragBank.Rotate)
                                     && !bankIsNonIdentity(DragBank.Scale);
                if (!skipIdentityFold)
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
                // Apply-path Phase 3 — cross-bank GPU correctness. The Move
                // fast-path skips the per-frame vertex re-upload and instead draws
                // the GPU buffer through a single `gpuMatrix`. That is only valid
                // while the GPU buffer still holds the fold's RUN BASELINE: the
                // published `lastFoldMatrix` is composed RELATIVE to that baseline,
                // so `gpuMatrix · buffer` reconstructs the CPU pose only when
                // buffer == baseline.
                //
                // For a SINGLE-bank Move (no held R/S) that invariant holds — the
                // buffer is the run baseline and the fold is a pure translation, so
                // we keep the cheap `translationMatrix(accumulatedWorldDelta)` (a
                // translation is invariant under wrapAboutPivot, so this is
                // byte-identical to the pre-Phase-3 path).
                //
                // For a CROSS-bank Move (a Move drag after a COMMITTED rotate/scale
                // in the same composed run) the held bank's mouse-up did
                // `gpu.upload(*mesh)` — the GPU buffer is now the ALREADY-TRANSFORMED
                // mesh, NOT the run baseline. Multiplying it by the composed
                // `wrapAboutPivot(lastFoldMatrix)` would re-apply the held rotate/
                // scale a second time (double transform). So we DROP OUT of the
                // fast-path (chose plan option (b)): `needsGpuUpdate=true` re-uploads
                // the CPU-folded verts this frame. This is the small, already-CPU
                // multi-bank case; the single-bank common path is untouched.
                if (moveDragFastPath && !heldRotateOrScaleNonIdentity()) {
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
                    import math : eulerZYXFromMatrix;
                    // MATRIX-AS-TRUTH — `run.r` is the run's world-space
                    // accumulated rotation (the TRUTH); `headlessRotate` is DERIVED
                    // from it for the panel only. The producer's `ang`
                    // (pendingRotateAngle = totalAngle) is the WITHIN-GESTURE angle
                    // only (totalAngle resets to 0 at every drag start, rotate.d
                    // ~601/695). So we compose THIS gesture's incremental rotation
                    // about the ACTUAL PHYSICAL RING AXIS — the FROZEN gizmo basis
                    // axis runFrameR/U/F[ax] — onto the orientation captured at this
                    // gesture's mouse-down (gestureStart.r), IN gesture
                    // order:
                    //     run.r = R(frozenRingAxis, ang) · gestureStart.r
                    // Composing about the REAL ring axis (not a world canon axis) is
                    // what fixes the non-world-basis bug: on an oblique global basis
                    // (single-cluster acen=local→global, tilted workplane) the matrix
                    // is the true world orientation about the displayed ring, and
                    // composeFor applies it DIRECTLY (no Rz·Ry·Rx rebuild about a
                    // possibly-different frame). The run baseline + run basis + pivot
                    // stay FROZEN — NO re-bake. The held T/S are NOT touched (they
                    // compose via the preset flags). (Per-cluster acen=local does NOT
                    // reach the matrix path — it re-bakes per cross-axis gesture via
                    // rotateRunNeedsRebake and stays on the legacy per-cluster fold.)
                    //
                    // The frozen run frame is captured at the run's first applyTRS
                    // (M6). On the VERY FIRST motion of a fresh run the freeze has
                    // not happened yet (applyTRS below does it), so fall back to the
                    // live currentBasis axis for THIS frame — it equals the
                    // about-to-be-frozen frame (currentBasis is what M6 freezes).
                    // Gesture chaining (flex_border_handles_plan.md): when a prior
                    // same-session gesture persisted a rotated frame, the runFrame
                    // captured at THIS run's first applyTRS may be the STALE
                    // world-snapped basis (a cross-axis rotate-after-rotate reuses
                    // the run frame — no re-bake on the global matrix-truth path),
                    // while the ring is DRAWN at R_gesture·frame. Rotate about the
                    // DISPLAYED ring axis (the unified `frame`, persisted by the prior
                    // gesture's settleGestureBasis, principal axes only) so apply
                    // follows render. Self-consistent — no double-count: the render's
                    // R_gesture = R(frame[ax], ang) is then applied to `frame`, i.e.
                    // rotating the displayed frame about one of its OWN axes. Falls
                    // back to runFrame (then live currentBasis) for the un-chained
                    // first gesture / non-Border modes.
                    Vec3 ringAxis;
                    // Gesture-frame unification, Phase 5 — the chained ring axis
                    // reads the unified `frame` directly. The chained gate is
                    // inlined as `frame.valid && rotDragAxisIdx in 0..2` (the
                    // condition the retired chained-axis flag was set under in
                    // beginRotateDragSession; principal-ring gestures only — the
                    // view-ring takes the ax==3 branch, not this one), and we are
                    // already in the principal-ring branch, so `frame.{right,up,axis}`
                    // are the frozen gesture frame's axes. Falls back to runFrame
                    // (then live currentBasis) for the un-chained first gesture.
                    if (frame.valid && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 2) {
                        ringAxis = ax == 0 ? frame.right
                                 : ax == 1 ? frame.up
                                           : frame.axis;
                    } else if (runFrameValid) {
                        ringAxis = ax == 0 ? runFrameR
                                 : ax == 1 ? runFrameU
                                           : runFrameF;
                    } else {
                        Vec3 lbX, lbY, lbZ;
                        currentBasis(lbX, lbY, lbZ, vts);
                        ringAxis = ax == 0 ? lbX
                                 : ax == 1 ? lbY
                                           : lbZ;
                    }
                    run.r = matMul4(
                        pivotRotationMatrix(Vec3(0, 0, 0), ringAxis, ang),
                        gestureStart.r);
                    // DERIVE the panel euler from the truth (display only; lossy at
                    // gimbal is acceptable — the matrix is never lossy).
                    headlessRotate = eulerZYXFromMatrix(run.r);

                    // CPU is rebuilt from the run baseline EVERY frame so it
                    // is never stale at mouseUp (round-1/3 B3; landed-move
                    // parity). The fast-path then merely skips the per-frame
                    // vertex re-upload — the GPU keeps the baseline buffer and
                    // u_model = wrapAboutPivot(fold) bridges the rotation.
                    applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                             /*samplePipeFromBaseline=*/true);
                    // P-F Phase 3b (MAJOR-4) — the own-bank fast-path
                    // `wrapAboutPivot(lastFoldMatrix) · buffer` is valid ONLY while
                    // the GPU buffer still holds the FROZEN run baseline
                    // (lastFoldMatrix is built from the FULL run-absolute
                    // headlessRotate against that baseline). Once a prior committed
                    // gesture in this run uploaded the buffer (`runGpuBufferDirty`),
                    // buffer ≠ frozen baseline and the fast-path would DOUBLE-APPLY —
                    // drop to a CPU re-upload (mirrors Move 1626 / Scale). The
                    // single-Rotate common path (fresh run, dirty == false) is
                    // untouched.
                    if (rotDragFastPath && !runGpuBufferDirty) {
                        // MS-4.5 — reuse the matrix applyTRS's fold just built
                        // (wrapped about its pivot) rather than rebuilding a
                        // parallel about-pivot rotation. Whole-mesh/no-falloff
                        // fast-path always takes the global fold, so it is fresh.
                        gpuMatrix = wrapAboutPivotStable(lastFoldMatrix, lastFoldPivot);
                    } else {
                        needsGpuUpdate = true;
                    }
                } else if (ax == 3) {
                    import std.math : PI;
                    import math : eulerZYXFromMatrix;
                    // MATRIX-AS-TRUTH — the view-ring rotates about an ARBITRARY
                    // world axis (the camera-forward the producer captured). With
                    // the matrix model that is no longer a special transient param:
                    // we FOLD it onto run.r exactly like a principal ring,
                    // composing THIS gesture's within-gesture angle about the
                    // captured world axis onto gestureStart.r. The fold
                    // then applies run.r directly, so the view-ring rotation
                    // now appears in the DERIVED panel euler (cumulative) — fixing
                    // the prior "view-ring → panel shows 0" gap. No transient
                    // viewAxis/viewAngleDeg param is threaded for the live path.
                    Vec3  viewAxisLocal = rotateSub.pendingRotateViewAxis;
                    run.r = matMul4(
                        pivotRotationMatrix(Vec3(0, 0, 0), viewAxisLocal, ang),
                        gestureStart.r);
                    headlessRotate = eulerZYXFromMatrix(run.r);
                    applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                             /*samplePipeFromBaseline=*/true);
                    // P-F Phase 3b (MAJOR-4) — same own-bank buffer-vs-baseline
                    // drop-out as the principal path: once a prior committed gesture
                    // re-uploaded the buffer (`runGpuBufferDirty`), the view-ring
                    // fast-path would double-apply the held transform — drop to CPU.
                    if (rotDragFastPath && !runGpuBufferDirty) {
                        // MS-4.5 — reuse the fold's composed matrix (view-ring
                        // rotation included) wrapped about its pivot.
                        gpuMatrix = wrapAboutPivotStable(lastFoldMatrix, lastFoldPivot);
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
                // P-F Phase 3a — run.s is RUN-ABSOLUTE: it holds the
                // run-total factor = run-start base ⊗ this-gesture factor. The
                // producer's `pendingScale` (f) is the WITHIN-GESTURE absolute
                // factor only (dragScaleAccum, reset to 1 at this drag's start,
                // scale.d:510), so the drain multiplies it per-axis by the run
                // total captured at this gesture's mouse-down (gestureStart.s, the
                // scale component of the per-gesture run snapshot). For a fresh run
                // the snapshot is identity ⇒ run.s = f (byte-identical to pre-3a).
                // For a same-bank repeat the snapshot is the held run total ⇒ the
                // factors multiply into the run total (mirrors the producer's own
                // scaleAccum.x = dragStartScaleAccum.x * scaleFactor at
                // scale.d:694). Per-axis factors commute ⇒ no cross-axis hazard.
                // The held T/R are NOT touched — they compose into the fold via
                // the preset flags. composeFor (3253) reads this FULL run-absolute
                // run.s against the FROZEN dragBaseline — no divide.
                run.s = Vec3(gestureStart.s.x * f.x,
                             gestureStart.s.y * f.y,
                             gestureStart.s.z * f.z);

                // CPU is rebuilt from the run baseline EVERY frame so it is
                // never stale at mouseUp. The fast-path then merely skips the
                // per-frame vertex re-upload — the GPU keeps the baseline
                // buffer and u_model = wrapAboutPivot(fold) bridges the scale.
                applyTRS(dragBaseline);
                // P-F Phase 3a (MAJOR-4) — the own-bank fast-path
                // `wrapAboutPivot(lastFoldMatrix) · buffer` is valid ONLY while the
                // GPU buffer still holds the FROZEN run baseline (lastFoldMatrix is
                // built from the FULL run-absolute run.s against that
                // baseline). Once a prior committed gesture in this run uploaded the
                // buffer (`runGpuBufferDirty`), buffer ≠ frozen baseline and the
                // fast-path would DOUBLE-APPLY — drop to a CPU re-upload (mirrors the
                // Move buffer-vs-baseline drop-out at 1626). The single-Scale common
                // path (fresh run, dirty == false) is untouched.
                if (scaleDragFastPath && !runGpuBufferDirty) {
                    // MS-4.5 — reuse the fold's composed scale matrix wrapped
                    // about its pivot instead of rebuilding it here.
                    gpuMatrix = wrapAboutPivotStable(lastFoldMatrix, lastFoldPivot);
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
        if (pipeGizmoHost !is null && pipeGizmoHost.routeUp(e)) {
            // P-E: a falloff-handle DRAG just ended. Its per-frame setAttrs
            // (issued directly on the stage as the handle was hauled, bypassing
            // the command dispatcher) shared ONE generation and REPLACEd into one
            // in-session step — the continuous-coalesce case. Bump the generation
            // now so the NEXT pipe tweak (handle drag or discrete setAttr) starts
            // a fresh generation and APPENDS as its own step (G2).
            if (history !is null) history.bumpTweakGeneration();
            return true;
        }
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
            // P-F Phase 3a (MAJOR-4) — this upload moves the GPU buffer off the
            // frozen run baseline, so a subsequent R/S own-bank fast-path in this
            // run must drop to a CPU re-upload (its lastFoldMatrix is relative to
            // the frozen baseline).
            runGpuBufferDirty = true;

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
            // BUG-1 — Move gizmo settle (DISPLAY soft-pin). The reference keeps
            // the Move gizmo at the FULL-delta pivot on mouse-up. On mouse-up the
            // active drag clears and computeCenter (Auto/None/Screen) recomputes
            // the gizmo pose from the moving-set centroid.
            //
            //   • WITHOUT falloff every selected vert moved by the full delta, so
            //     that centroid ALREADY equals moveSub.handler.center — the gizmo
            //     does not move. Setting a soft pin here would only freeze a value
            //     equal-up-to-float-noise to the live centroid, but since the live
            //     centroid and handler.center are not bit-identical it would nudge
            //     the published pivot off the centroid the recompute would give —
            //     visible to the pixel-exact relocate-boundary tests. So the
            //     no-falloff path is left EXACTLY as today (byte-identical): no
            //     soft pin, computeCenter returns the centroid as before.
            //
            //   • WITH falloff the centroid is the WEIGHTED moving-set bbox-center,
            //     which sits well short of the full delta — that is the snap-back.
            //     Record the settled handler center (which followed the full delta
            //     via center + worldStep every motion frame) as a DISPLAY soft-pin
            //     so computeCenter returns it instead.
            //
            // Gated to the relocate-allowed modes (Auto/None/Screen) — the exact
            // set whose computeCenter reads the soft pin and where the snap-back
            // occurs (Select/Element/Local/Origin/Manual/Border keep their own
            // selection-derived pivot and never read it). Deliberately NOT
            // notifyAcenUserPlaced: it must NOT set userPlaced (a prior attempt
            // did, breaking the cross-slot relocate boundary), so the relocate
            // snapshot machinery is untouched. The soft pin is sticky for the next
            // same-run gesture and cleared at the selection / ACEN-mode boundaries
            // (where the moving set legitimately changes) and by any relocate.
            //
            // BUG-2 (reviewer BLOCKER) — set the soft pin BEFORE commitEdit so the
            // commit captures the gesture-END soft state LIVE (ac.isSoftPlaced() /
            // currentSoftCenter()) into its undo/redo hooks, alongside the
            // userPlaced pin + pipe config. Previously this fired AFTER commitEdit,
            // so the recorded hooks never carried the soft pin and an in-session
            // Ctrl+Z reverted geometry but left the gizmo floating at the settled
            // height (the update() clear is skipped on undo — undo bumps
            // mutationVersion but not the selection hash). Reordering does not
            // change any externally-observable steady state for a real drag: the
            // soft pin's effect (computeCenter returning it) is identical whether
            // published just before or just after the commit; the commit itself
            // does not read the soft pin (it captures the userPlaced pin, which the
            // soft pin does not touch).
            //
            // ALSO gated to actual MOTION (BUG-2 falloff+relocate): a Move mouse-up
            // can be a degenerate off-gizmo relocate CLICK — its mouse-DOWN opened a
            // moveSub session AND fired setUserPlaced (which CLEARS the soft pin),
            // but the gesture moved ZERO distance, so it is a pure relocate, not a
            // settle. (Such a click still builds a Move command, so a "non-null cmd"
            // test does NOT distinguish it.) accumulatedWorldDelta is this gesture's
            // total world translate — reset to 0 at beginMoveDragSession and summed
            // per motion frame — so a near-zero magnitude means no drag happened.
            // Setting the soft pin then would resurrect it on top of the explicit
            // userPlaced relocate (both pins set). So only REQUEST the soft pin when
            // the gesture genuinely moved geometry; commitEdit applies the pending
            // request (BEFORE recording the cmd hooks, so the END capture sees the
            // settle) only when a real edit command was also built. A relocate-only
            // click leaves the soft pin cleared (userPlaced wins, as the reference
            // does); a relocate-THEN-drag still stamps the settle (motion > 0).
            // flex_border_handles_plan.md Phase 3 (BUG-1): request the gesture-end
            // center settle. The relocate gate is GONE (it admitted only
            // Auto/None/Screen and excluded Border, the flex mode) — the actual
            // mode filter is settleGestureCenter's acenSettleAllowed() predicate,
            // applied when commitEdit consumes the request. The falloff gate STAYS:
            // without falloff every selected vert moves the full delta, so the live
            // recompute already equals the settled center (no jump-back, soft pin
            // unused) and pinning it would only nudge the published pivot off the
            // bit-exact recompute the relocate-boundary tests pin.
            enum float kMoveEps = 1e-5f;
            bool gestureMoved = accumulatedWorldDelta.length() > kMoveEps;
            // Set-or-keep discipline (stale-soft-pin fix): when a prior gesture
            // (a moved rotate in Auto/None/Screen, or a scale under falloff)
            // left a display soft pin, the Move mouse-up
            // must overwrite it with the moved pivot so the gizmo follows the
            // move instead of snapping back to the stale pin. Without a prior
            // soft pin AND without falloff, the predicate stays false and the
            // live centroid is already bit-exact — byte-identical baseline (R1).
            // Routes through pendingMoveSoftPin → commitEdit → settleGestureCenter
            // → acenSettleAllowed() so Element/Local stay excluded (R2), and the
            // END soft-pin capture in commitEdit sees the updated state (R5).
            bool softActive = false;
            if (auto ac = activeAcenStage()) softActive = ac.isSoftPlaced();
            if (gestureMoved && (currentFalloff(vts).enabled || softActive)) {
                pendingMoveSoftPin    = true;
                pendingMoveSoftCenter = moveSub.handler.center;
                // COMMIT B — persist the move bank's gesture-end rendered basis
                // (R_gesture=I ⇒ B0) so the idle gizmo holds it, gated identically
                // to the center settle (real motion + falloff/softActive) for a
                // byte-identical no-falloff / no-prior-pin path.
                settleGestureBasis(moveSub.handler.axisX,
                                   moveSub.handler.axisY,
                                   moveSub.handler.axisZ);
            }

            if (editIsOpen())
                commitEdit("Move");
            // A no-op commit (no cmd built) never consumes the request; drop it so
            // it cannot leak into an unrelated later commit.
            pendingMoveSoftPin = false;

            // In-session falloff re-grade — staleness stamp (OBJ-1). Record the
            // mesh version this gesture left behind: a later falloff tweak at
            // idle re-grades this gesture ONLY while the version still matches.
            // An in-session Ctrl+Z reverts geometry (bumps the version away from
            // the stamp), so the re-grade site then refuses — a popped gesture is
            // never resurrected. (A brush-reset tool DISARMS instead — see
            // armRegradeStamp: a baked stroke must not re-grade on a falloff tweak.)
            armRegradeStamp();

            // Open a FRESH re-fire window for this gesture. A run can hold more
            // than one gesture (g1 -> tweak -> g2 -> tweak), and a tweak after g2
            // must anchor before[] to the post-g2 geometry, NOT the stale post-g1
            // snapshot. Clearing here makes each gesture start a fresh window:
            // the next re-grade re-captures the anchor live. (The drop's
            // consolidate still reverts every touched vert to the run-start state
            // via mergeRun's first-touch before[], so the per-gesture window only
            // governs the SINGLE in-session Ctrl+Z granularity, exactly C.)
            refireAnchor.length = 0;
            refirePreValid      = false;   // fresh window ⇒ recapture pre-config
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
            // Gesture chaining (flex_border_handles_plan.md) — drop the chained
            // ring-axis read by clearing the principal-ring index; the chained drain
            // gate (`frame.valid && rotDragAxisIdx in 0..2`) is now false, so the
            // NEXT gesture re-evaluates the axis from the frame this gesture's own
            // settleGestureBasis just (re)pinned.
            rotDragAxisIdx  = -1;
            // P-F Phase 3a (MAJOR-4) — buffer moved off the frozen baseline; a
            // subsequent R/S own-bank fast-path must drop to CPU re-upload.
            runGpuBufferDirty = true;

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
            //
            // P-F Phase 3 (MAJOR-5) — unified WHOLE-STRUCT undo hook (identical
            // across all three banks + the refire). xfStart is THIS gesture's
            // run-START snapshot (captured at rotate mouse-down, gestureStart);
            // xfEnd is the current run-total state. Splice them onto the rotateSub
            // gesture entry through the wrapper-field hook pair so an in-session
            // Ctrl+Z restores the run state to BEFORE this gesture (mergeRun
            // first.revert/last.apply splices to run-START / run-END at the drop),
            // and redo restores the post-gesture run state. Gated by
            // rotateGestureStartKnown so a commit with no preceding mouse-down leaves
            // xfStart == xfEnd (inert). The SAME pre/post is recorded IDENTICALLY in
            // recordPipeRefire so a snap/falloff mid-run refire does not strand it.
            // A Rotate gesture only changes run.r (+ its derived euler); the T/S
            // fields are equal between xfStart and xfEnd, so restoring the WHOLE
            // struct is byte-equivalent to restoring run.r alone. On a cross-axis /
            // view-ring re-bake xfStart.r was identity (re-bake zeroed it), so the
            // hook restores the orientation to identity for the new-axis run-segment
            // — consistent with the geometry baseline (the prior axis is carried in
            // geometry). MATRIX-AS-TRUTH: run.r is the truth, headlessRotate is
            // re-derived (eulerZYXFromMatrix) so the panel + matrix never drift.
            bool rotAbsKnown = rotateGestureStartKnown;
            XformState xfStart = gestureStart;
            XformState xfEnd   = run;
            rotateGestureStartKnown = false;
            if (!rotAbsKnown) xfStart = xfEnd;   // inert (no preceding mouse-down)
            // flex_border_handles_plan.md Phase 3 (BUG-1) — settle the gesture-end
            // center through the shared helper (relocate gate GONE; the 2-entry
            // acenSettleAllowed() predicate is the sole filter). settleGestureCenter
            // pins the drop center and reports the END soft state so the undo hook
            // can carry it in lockstep with the geometry (gesture-START captured at
            // mouse-down in beginRotateDragSession). rotateSub.handler.center is the
            // pivot (rotate never translates it), so the live recompute for a Border
            // partial selection would otherwise drift off it after the rotation.
            // PER-BANK settle gate (preserves each bank's ORIGINAL main condition,
            // OR-ing in the flex/Border falloff branch). Rotate on main pinned in
            // the RELOCATE modes (acenAllowsClickRelocate: Auto/None/Screen) — its
            // handler.center stays at the pivot during the gesture but the recomputed
            // bbox center after rotation is angle-dependent (asymmetric meshes), so
            // the pin is needed even WITHOUT falloff (test_acen_softpin_settle). We
            // keep that AND add the falloff branch so flex/Border (which always has
            // falloff) also pins (bug 1 + rotate-basis-persist). acenSettleAllowed()
            // still excludes Element/Local (a single drop pose can't represent the
            // live element anchor / N cluster pivots). The "no if(mode==border)" rule
            // holds: these are capability predicates (relocate / settle-allowed /
            // falloff), never a mode-NAME branch. (Scale below is falloff-ONLY — main
            // had no scale settle, so without falloff a stale scale pin must not drift
            // the next cross-bank Move's pivot: test_run_absolute_scale.)
            bool rotGestureMoved = rotAbsKnown && !xformRotEqual(xfStart, xfEnd);
            bool rotSettle = rotGestureMoved && acenSettleAllowed()
                          && (acenAllowsClickRelocate() || currentFalloff(vts).enabled);
            bool   softEndPlaced; Vec3 softEndCenter;
            if (rotSettle)
                settleGestureCenter(rotateSub.handler.center, softEndPlaced, softEndCenter);
            else { softEndPlaced = false; softEndCenter = Vec3(0, 0, 0); }
            // COMMIT B — persist the rotate bank's gesture-end rendered basis
            // (R_gesture·B0 = the rotated frame the ring left on screen) so the idle
            // gizmo HOLDS it instead of snapping back to the world-snapped live
            // currentBasis on release. Read from the rendered handler.axis* NOW (the
            // last drag frame's render frame), before any boundary resetRun. Gated
            // identically (same falloff+moved condition) so center+basis stay in sync.
            if (rotSettle)
                settleGestureBasis(rotateSub.handler.axisX,
                                   rotateSub.handler.axisY,
                                   rotateSub.handler.axisZ);
            bool softStartPlaced = rotAbsKnown ? rotateSoftStartPlaced : softEndPlaced;
            Vec3 softStartCenter = rotAbsKnown ? rotateSoftStartCenter : softEndCenter;
            // BASIS undo splice — the rendered-frame analogue of the soft-pin pair
            // above. frameEnd = the gesture-END `frame` settleGestureBasis just
            // wrote (R_gesture·B0); frameStart = this gesture's mouse-down capture.
            // An in-session Ctrl+Z bumps the mutation version but not the selection
            // hash, so clearFrame never fires and the idle renderBasis keeps the
            // settled (rotated) basis — without this restore the gizmo would render
            // the rotated frame over the reverted-to-pristine geometry. Gated by
            // rotAbsKnown so a commit with no preceding mouse-down stays inert.
            GestureFrame frameEnd   = frame;
            GestureFrame frameStart = rotAbsKnown ? rotateFrameStart : frameEnd;
            rotateSub.wrapperFieldApplyHook  = () {
                run = xfEnd;   headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameEnd; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softEndPlaced, softEndCenter); };
            rotateSub.wrapperFieldRevertHook = () {
                run = xfStart; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameStart; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softStartPlaced, softStartCenter); };
            rotateSub.commitGesture();
            // Clear the wrapper-field hooks so a later sub-tool commit with no
            // wrapper splice (e.g. commitSessionIfOpen at a cross-bank boundary)
            // does not re-fire this gesture's stale snapshot.
            rotateSub.wrapperFieldApplyHook  = null;
            rotateSub.wrapperFieldRevertHook = null;

            // In-session falloff re-grade — staleness stamp + window reset
            // (OBJ-1 / OBJ-3), mirroring the Move commit above. Without these an
            // R/S gesture after a Move tweak (or a prior R/S tweak) would leave a
            // STALE refireAnchor + stamp: a subsequent falloff tweak would either
            // anchor before[] to the wrong (pre-this-gesture) geometry or fire
            // off a mismatched version. Stamp the version this rotate gesture left
            // behind so a later falloff tweak re-grades THIS gesture only while
            // the version still matches; clear refireAnchor so the tweak opens a
            // FRESH re-fire window anchored to this gesture's post-recompute state.
            armRegradeStamp();   // brush-reset tool disarms (no post-stroke re-grade)
            refireAnchor.length = 0;
            refirePreValid      = false;   // fresh window ⇒ recapture pre-config
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
            // P-F Phase 3a (MAJOR-4) — buffer moved off the frozen baseline; the
            // NEXT same-bank Scale own-bank fast-path in this run must drop to a
            // CPU re-upload (its lastFoldMatrix is built from the FULL run-absolute
            // run.s against the frozen baseline → wrapAboutPivot(fold) ×
            // this transformed buffer would double-scale).
            runGpuBufferDirty = true;

            // P-F Phase 3 (MAJOR-5) — unified WHOLE-STRUCT undo hook (identical to
            // the Rotate hook above / the Move hook). xfStart is THIS gesture's
            // run-START snapshot (captured at scale mouse-down, gestureStart);
            // xfEnd is the current run-total state. Splice them onto the scaleSub
            // gesture entry through the wrapper-field hook pair so an in-session
            // Ctrl+Z restores the run state to BEFORE this gesture (mergeRun
            // first.revert/last.apply splices to run-START / run-END at the drop),
            // and redo restores the post-gesture run state. Gated by
            // scaleGestureStartKnown so a commit with no preceding mouse-down leaves
            // xfStart == xfEnd (inert). The same pre/post is recorded IDENTICALLY in
            // recordPipeRefire (3747-region) so a snap/falloff mid-run refire does
            // not strand it. A Scale gesture only changes run.s; the T/R fields are
            // equal between xfStart and xfEnd, so the whole-struct restore is
            // byte-equivalent to restoring run.s alone.
            bool scaleAbsKnown = scaleGestureStartKnown;
            XformState xfStart = gestureStart;
            XformState xfEnd   = run;
            scaleGestureStartKnown = false;
            if (!scaleAbsKnown) xfStart = xfEnd;   // inert
            // flex_border_handles_plan.md Phase 3 (BUG-1) — Scale had NO settle at
            // all; add it through the shared helper (the 2-entry acenSettleAllowed()
            // predicate is the sole mode filter, no relocate gate) so a completed
            // scale leaves the gizmo at its drop pose. Pin BEFORE commitGesture so
            // the gesture-END snapshot the undo hook restores carries the settle;
            // splice the soft pin into both hooks (gesture-START captured at scale
            // mouse-down) so an in-session Ctrl+Z restores it in lockstep.
            // PER-BANK settle gate — Scale is FALLOFF-ONLY. Main had NO scale
            // settle at all, so WITHOUT falloff scale must NOT pin: a stale softPlaced
            // from this scale would shift the NEXT cross-bank Move gesture's
            // computeCenter under the relocate modes (Auto/None/Screen read softPlaced)
            // — the scale-then-move-under-None pivot drift (test_run_absolute_scale).
            // Scale's bbox center, UNLIKE rotate's, is NOT angle-dependent (scale about
            // the pivot keeps the centroid put), so the no-falloff pin the rotate bank
            // needs is unnecessary — hence falloff-only here, NOT acenAllowsClickRelocate.
            // WITH falloff (flex / Border, which always has falloff) the pin fires so
            // bug 1 + the basis persistence stay fixed. acenSettleAllowed() excludes
            // Element/Local as everywhere.
            bool scaleGestureMoved = scaleAbsKnown && !xformScaleEqual(xfStart, xfEnd);
            bool scaleSettle = scaleGestureMoved && acenSettleAllowed()
                            && currentFalloff(vts).enabled;
            bool   softEndPlaced; Vec3 softEndCenter;
            if (scaleSettle)
                settleGestureCenter(scaleSub.handler.center, softEndPlaced, softEndCenter);
            else { softEndPlaced = false; softEndCenter = Vec3(0, 0, 0); }
            // COMMIT B — persist the scale bank's gesture-end rendered basis
            // (R_gesture=I ⇒ B0) so the idle gizmo holds it after release. Gated
            // identically so center+basis persistence stay in sync.
            if (scaleSettle)
                settleGestureBasis(scaleSub.handler.axisX,
                                   scaleSub.handler.axisY,
                                   scaleSub.handler.axisZ);
            bool softStartPlaced = scaleAbsKnown ? scaleSoftStartPlaced : softEndPlaced;
            Vec3 softStartCenter = scaleAbsKnown ? scaleSoftStartCenter : softEndCenter;
            // BASIS undo splice (mirror of the rotate hook). Scale's R_gesture is I,
            // so frameStart == frameEnd and the restore is an identity no-op — it
            // exists purely so the splice composes uniformly across the three banks.
            GestureFrame frameEnd   = frame;
            GestureFrame frameStart = scaleAbsKnown ? scaleFrameStart : frameEnd;
            scaleSub.wrapperFieldApplyHook  = () {
                run = xfEnd;   headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameEnd; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softEndPlaced, softEndCenter); };
            scaleSub.wrapperFieldRevertHook = () {
                run = xfStart; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameStart; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softStartPlaced, softStartCenter); };

            // Per-gesture commit (record+consolidate, Phase 2): mirrors the
            // rotate path above — each scale drag bakes a tagged in-session entry
            // on mouse-up (scaleSub's commitEdit attaches the scaleAccum/propScale
            // hooks + routes in-session), the next handle grab reopens a fresh
            // scaleSub session, and the run consolidates at the boundary / drop.
            scaleSub.commitGesture();
            // Clear the wrapper-field hooks so a later sub-tool commit with no
            // wrapper splice (e.g. commitSessionIfOpen at a cross-bank boundary)
            // does not re-fire this gesture's stale snapshot.
            scaleSub.wrapperFieldApplyHook  = null;
            scaleSub.wrapperFieldRevertHook = null;

            // In-session falloff re-grade — staleness stamp + window reset
            // (OBJ-1 / OBJ-3), mirroring the Move + Rotate commits above. Same
            // rationale: stamp the version this scale gesture left behind and
            // clear refireAnchor so a later falloff tweak re-grades THIS gesture
            // from a fresh window, and an R/S gesture after a Move/R/S tweak never
            // inherits a stale anchor.
            armRegradeStamp();   // brush-reset tool disarms (no post-stroke re-grade)
            refireAnchor.length = 0;
            refirePreValid      = false;   // fresh window ⇒ recapture pre-config
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
    // `run.t` / `headlessRotate` / `run.s` as
    // attributes).
    //
    // Apply-path Phase 2: the former `applyTRSForBank(bank, …)` shim — which
    // force-restricted flagT/flagR/flagS to a single bank so a live drain saw
    // only its own factor — is DELETED. Every caller (the four motion drains +
    // the two Move falloff-refire sites) now calls `applyTRS` directly with the
    // PRESET flags intact, so `composeFor` folds the active bank's live value
    // ⊕ the held banks' run-absolutes from ONE run baseline (the reference
    // Evaluate-from-original shape). Per-bank inclusion is driven by the
    // preset's flag*/hasT/hasS gates, not an artificial per-gesture override.
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
                  float viewAngleDeg = 0,
                  bool samplePipeFromBaseline = false) {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;

        assert(baseline.length == mesh.vertices.length,
               "applyTRS: baseline/mesh length mismatch ("
             ~ "baseline must be a snapshot of mesh.vertices at the "
             ~ "edit-session start)");

        void restoreBaseline() {
            foreach (i; 0 .. mesh.vertices.length)
                mesh.vertices[i] = baseline[i];
        }

        if (samplePipeFromBaseline) {
            restoreBaseline();
            buildLocalVts(subj, vts);
        } else {
            buildLocalVts(subj, vts);
        }

        // Value-edit reEvaluate semantics are revert-then-rerun: for those paths,
        // geometry-derived ACEN/AXIS state must be sampled from the baseline, not
        // from the previous preview result. Live drags and their undo/resync hooks
        // keep the historical live-pipe sampling because their action-center pins
        // and soft-pins deliberately reflect the current gesture/run state.
        Vec3 pivot = queryActionCenter(vts);
        auto cp    = queryClusterPivots(vts);
        auto ap    = queryClusterAxes(vts);

        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        restoreBaseline();
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);

        // P-F (M6) — FREEZE the per-run gizmo frame on the FIRST applyTRS of a
        // run. Lazy capture here (just after currentBasis computes the live basis
        // and the pivot above) freezes one world-space frame for the whole run so
        // the run-absolute panel components sum along a STABLE axis even though
        // currentBasis re-derives per frame (drifts under acen=local). The capture
        // is published for assertion and used by run-absolute display/frozen
        // translate basis. Ordering is load-bearing: freeze BEFORE
        // applyFold/composeFor read the frame, so the first apply of a run
        // (incl. the bare-write replay path) has a valid frame to publish;
        // resetRun() at every geometry-run boundary clears it so a relocate
        // re-freezes a fresh frame next apply.
        if (!runFrameValid) {
            // Chain a new gesture off the PERSISTED gizmo frame: when a prior
            // gesture left a settled basis (frame.settled, and the selection/mode
            // hasn't changed to clear it), freeze THIS run's B0 from the unified
            // `frame` instead of the live world-snapped currentBasis. runFrame is the
            // SINGLE B0 that feeds BOTH the rendered frame (renderBasis drag branch)
            // AND the apply-path translate (tX/tY/tZ at applyFold), so this one swap
            // keeps render + apply coherent — the move-after-rotate gizmo draws
            // rotated AND translates along the rotated axes. The sub-tools' input
            // projection reads the same `frame` (pushed in begin*DragSession) so the
            // drag DIRECTION matches the rendered arrows (never split sources).
            // Gated by acenSettleAllowed() (the frame's own gate) so Element/Local —
            // which never persist a frame — re-derive fresh.
            // The Move center-box free-plane drag (dragAxis 3) is basis-free on the
            // input side, so it stays on the LIVE basis here too — else decompose
            // (live) vs re-expand (rotated runFrame) would round-trip to R·worldDelta.
            Vec3 f0X = bX, f0Y = bY, f0Z = bZ;
            // Gesture-frame unification — runFrame's CHAINED source reads the unified
            // `frame` (the single source of truth). `frame.valid` IS `frame.settled
            // && acenSettleAllowed()` by construction. The non-chained default
            // (bX/bY/bZ over the restored baseline) and the moveCenterBoxDragActive()
            // exclusion stay verbatim — runFrame itself, its freeze, runFrameValid,
            // the publish, and the translate read are untouched (runFrame is the
            // 6->2 boundary, it stays).
            if (frame.valid && !moveCenterBoxDragActive()) {
                f0X = frame.right; f0Y = frame.up; f0Z = frame.axis;
            }
            runFrameOrigin = pivot;
            runFrameR      = f0X;
            runFrameU      = f0Y;
            runFrameF      = f0Z;
            runFrameValid  = true;
        }

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
        // The decomposed state fields (run.t / headlessRotate /
        // run.s) + the transient view-ring params (viewAxis / viewAngleDeg,
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

            bool hasT = flagT && (run.t.x != 0
                              || run.t.y != 0
                              || run.t.z != 0);
            bool hasS = flagS && (run.s.x != 1
                              || run.s.y != 1
                              || run.s.z != 1);

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
                        Vec3 wd = ap.right[cid] * run.t.x
                                + ap.up[cid]    * run.t.y
                                + ap.fwd[cid]   * run.t.z;
                        clusterM[cid] = translationMatrix(wd);
                    }
                    FalloffPacket noFo;  noFo.enabled = false;   // w==1 exempt
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot, identityMatrix, Vec3(0, 0, 0),
                                     blendModeForMeasure(),
                                     noFo, cachedVp, cp, ap, clusterM,
                                     dragSymmetry, toProcess);
                } else {
                    // Global basis: delta = bX·TX + bY·TY + bZ·TZ; weight at the
                    // LIVE position (source == weightVerts == current scratch),
                    // matching applyTranslateIncremental.
                    Vec3 delta = bX * run.t.x
                               + bY * run.t.y
                               + bZ * run.t.z;
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot, translationMatrix(delta), Vec3(0, 0, 0),
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
                                             run.s,
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
                                run.s.x, run.s.y,
                                run.s.z);
                    }
                    applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                     pivot,
                                     pivotScaleMatrixBasis(Vec3(0, 0, 0),
                                         bX, bY, bZ,
                                         run.s.x, run.s.y,
                                         run.s.z),
                                     Vec3(0, 0, 0),
                                     blendModeForMeasure(),
                                     dragFalloff, cachedVp, cp, ap, clusterM,
                                     dragSymmetry, toProcess,
                                     /*weightVerts=*/ baseline);
                }
            }

            // Symmetry mirror for the DORMANT legacy pow-scale chain. The
            // in-kernel mirror tail was deleted in Stage 2 (the live fold owns
            // the mirror via Pass B). This branch is only reached when
            // compoundPasses != 1 (Selection-falloff scale pow — dormant in the
            // current tree), so it keeps the legacy POSITION-COPY mirror at its
            // own call site (per the plan: legacy/per-cluster paths retain
            // position-copy until their own stage). One copy after the whole
            // chain, OR-ing mirror verts into toProcess for upload/undo.
            if (dragSymmetry.enabled
                && dragSymmetry.pairOf.length == mesh.vertices.length) {
                import symmetry : applySymmetryMirror;
                applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
            }
            // Change-notification (Stage 1): the dormant legacy per-pass /
            // pow-scale chain also writes positions in place WITHOUT a version
            // bump (mid-drag stability). Mirror applyFold's note so this path
            // publishes Position too — ONE note for the whole T/R/S chain (never
            // per pass, never per vertex). compoundPasses is 1.0 everywhere in
            // the current tree, so this branch is dormant; the note keeps it
            // correct if the pow path is ever re-enabled.
            mesh.noteChange(MeshEditScope.Position);
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

    // Phase 1 (R/S run-baseline) — the FIX. The Rotate/Scale panel-apply path
    // used to rebuild absolutely from the SUB-TOOL's session-start snapshot
    // (origVertices / activationVertices = the original mesh at sub-tool
    // activation). After a cross-axis gizmo gesture the prior axis is baked into
    // the wrapper's run baseline (`dragBaseline`) + mesh, NOT into the sub-tool
    // snapshot, so a panel edit applied from that snapshot DISCARDED the baked
    // axis. These two entry points re-route the R/S panel apply onto the SAME
    // run baseline the gizmo apply uses (applyTRS(dragBaseline), see :1785 /
    // :1862), so the baked cross-axis history is preserved and the per-axis-delta
    // contract holds (headlessRotate carries only the LIVE axis; the prior axis
    // lives in dragBaseline).
    //
    // captureBaselinePacketsNoSession() snapshots dragBaseline if stale and
    // captures the live falloff/symmetry/snap WITHOUT opening the WRAPPER edit
    // session (MS-5: the R/S undo entry must stay on the sub-tool, which owns its
    // own beginEdit/commitEdit — the sub-tool's applyRotatePanelValue /
    // applyScalePanelValue already opened it before calling here). headlessRotate
    // / run.s are read ABSOLUTELY by applyTRS, exactly as the gizmo path.
    public void applyRotateAbsoluteFromRun(Vec3 angleAccumRad) {
        import std.math : PI;
        import math : matrixFromEulerZYX;
        captureBaselinePacketsNoSession();
        vertexCacheDirty = true;
        headlessRotate = Vec3(angleAccumRad.x * 180.0f / cast(float)PI,
                              angleAccumRad.y * 180.0f / cast(float)PI,
                              angleAccumRad.z * 180.0f / cast(float)PI);
        // MATRIX-AS-TRUTH (recompose-from-euler semantics) — a numeric/panel RX/RY/RZ write is
        // an ABSOLUTE orientation set, so RECOMPOSE the truth from the written euler.
        // matrixFromEulerZYX pins to the SAME Rz·Ry·Rx convention the global fold
        // applies (composeFor consumes run.r directly), so a bare write of
        // RZ=90 lands as an exact 90° world-Z rotation. This is the ONLY place a
        // panel/numeric edit feeds run.r; the gizmo drain feeds it directly.
        run.r = matrixFromEulerZYX(headlessRotate);
        // Euler-slot path: applyTRS defaults the transient view-ring rotation
        // to zero (MS-3.4), so a prior view-ring drag cannot re-apply on top.
        bool pureRotatePreset = flagR && !flagT && !flagS;
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                 /*samplePipeFromBaseline=*/pureRotatePreset);
        if (acenAllowsClickRelocate()) {
            if (auto ac = activeAcenStage())
                ac.setSoftPlaced(lastFoldPivot);
        }
    }

    public void applyScaleAbsoluteFromRun(Vec3 scaleAccum) {
        captureBaselinePacketsNoSession();
        vertexCacheDirty = true;
        run.s = scaleAccum;
        bool pureScalePreset = flagS && !flagT && !flagR;
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                 /*samplePipeFromBaseline=*/pureScalePreset);
    }

    // Numeric headless apply (`tool.doApply` + cross-engine deform
    // diff). Captures falloff + symmetry from the current toolpipe state
    // (no live-drag snapshot to read from), then delegates to
    // `applyTRS(mesh.vertices.dup)`. Restore-to-self in the prologue is
    // a no-op so the resulting mesh matches the legacy numeric output
    // byte-for-byte; the golden fixtures (`test_fixture_acen_local`,
    // `test_fixture_translate*`, `test_fixture_rotate*`,
    // `test_fixture_scale*`) stay green.
    // P-C: re-capture the live falloff + symmetry + snap packets into the
    // wrapper's dragFalloff / dragSymmetry / dragSnap via a FRESH pipeline
    // evaluate. The Move re-grade arm calls this before `applyTRS` so the
    // symmetry pass reads a packet with a POPULATED pairOf table: a symmetry
    // stage just toggled on publishes a stale-EMPTY pairOf on its first
    // evaluate (cachedReady_ flips true only after that rebuild — see
    // SymmetryStage.evaluate), so re-reading from update()'s single evaluate
    // would mirror nothing. A second evaluate here lands the rebuilt pairing.
    // Mirrors what applyRotateAbsoluteFromRun / applyScaleAbsoluteFromRun already
    // do for the R/S arms (capture from a fresh buildLocalVts). No-op cost on a non-symmetry
    // change (the extra evaluate is cheap and only runs on the rare config tweak).
    private void recaptureLivePipePackets() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        if (!buildLocalVts(subj, vts)) return;
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        captureSnapForDrag(vts);
    }

    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        import math : matrixFromEulerZYX;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger
        vertexCacheDirty = true;
        // MATRIX-AS-TRUTH — the numeric/headless path injects RX/RY/RZ into
        // headlessRotate via the attr system (no gizmo drain ran), so RECOMPOSE the
        // rotate truth from the injected euler (recompose-from-euler) before the fold
        // reads run.r. The Euler slot is the only numeric rotate input (the
        // view-ring has no numeric attr), so matrixFromEulerZYX is the exact truth.
        run.r = matrixFromEulerZYX(headlessRotate);
        return applyTRS(mesh.vertices.dup);
    }

    // Phase 4 — property-panel translate slider entry point.
    // MoveTool.drawProperties calls this once per active slider
    // frame with the basis-local delta the user just typed/dragged.
    //
    // Idempotent setup: opens a tool-session edit if one isn't yet
    // open, AND opens a "panel drag" baseline if no gizmo drag is
    // currently active (= panel and gizmo drag both feed the same
    // `run.t`, the same `applyTRS` evaluate, and the
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
        // fresh `dragBaseline` this call; we zero `run.t` ONLY then
        // (the first-active-frame — accumulation starts from zero). Zeroing on
        // every call would wipe the prior cumulative. The += sits between the
        // capture and applyTRS, so we can't reuse replayTranslateFromBaseline()
        // (which does capture-then-apply with nothing in between).
        bool freshBaseline = captureDragBaselineIfStale();
        if (freshBaseline)
            run.t = Vec3(0, 0, 0);
        run.t = run.t + basisLocalDelta;
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0, /*samplePipeFromBaseline=*/true);
        needsGpuUpdate = true;
    }

    // Shared session-setup + capture step for the panel-delta and value-driven
    // (reEvaluate) replay paths. Builds the local vector stack, captures the
    // live falloff / symmetry, builds the vertex cache, opens the edit session
    // (idempotent), and captures a fresh full-mesh `dragBaseline` IFF the
    // current one is stale (length mismatch). Returns true when it captured a
    // fresh baseline this call.
    //
    // CRITICAL: this body does NOT zero `run.t`. The zeroing is
    // coupled to the delta accumulation and lives in applyMovePanelDelta()'s
    // prologue (gated on the returned bool). If it lived here, reEvaluate()
    // acting as a session-opener would wipe the just-injected absolute
    // translate before applyTRS, applying 0.0 on the first edit.
    private bool captureDragBaselineIfStale() {
        // Phase 1 (R/S run-baseline) factor-out: the dragBaseline staleness
        // snapshot + live falloff/symmetry/snap capture is now a session-FREE
        // helper, so the Rotate/Scale panel-apply path can reuse the SAME run
        // baseline the gizmo uses WITHOUT opening the WRAPPER edit session (which
        // would record a spurious "Move" undo entry — the R/S edit session must
        // stay on the sub-tool, MS-5). The Move path keeps its original behaviour:
        // capture-no-session, then open the wrapper session + seed the tracking.
        bool fresh = captureBaselinePacketsNoSession();
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

        // `fresh` reflects whether captureBaselinePacketsNoSession snapshotted a
        // new dragBaseline this call (used by applyMovePanelDelta to gate the
        // run.t zero-on-first-active-frame).
        return fresh;
    }

    // Phase 1 (R/S run-baseline): session-FREE baseline + packet capture, split
    // out of captureDragBaselineIfStale so the Rotate/Scale panel-apply path can
    // share the SAME run baseline (`dragBaseline`) the gizmo uses without opening
    // the WRAPPER edit session. Opening the wrapper session for an R/S panel edit
    // would record a spurious "Move" undo entry (MS-5: R/S undo entries stay on
    // the sub-tool, which owns its own beginEdit/commitEdit).
    //
    // Captures the live falloff / symmetry / snap packets (overwriting
    // dragFalloff / dragSymmetry / dragSnap so a mid-edit falloff change takes
    // effect immediately), then snapshots a fresh full-mesh `dragBaseline` IFF
    // the current run baseline is invalid or structurally stale. Length alone is
    // not a validity signal: transform edits preserve vertex count, so a stale
    // same-length baseline from a previous run must not be reused by property
    // replay. A valid baseline is KEPT so a subsequent edit replays from the run
    // baseline that already has any prior same-run history baked in. Returns true
    // when it captured fresh.
    //
    // Does NOT call beginEdit() / buildVertexCacheIfNeeded() / seed the wrapper
    // selection-mutation tracking — those belong to the wrapper (Move) session
    // and are done by captureDragBaselineIfStale's tail.
    private bool captureBaselinePacketsNoSession() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger
        if (!runBaselineValid || dragBaseline.length != mesh.vertices.length) {
            dragBaseline.length = mesh.vertices.length;
            foreach (i; 0 .. mesh.vertices.length)
                dragBaseline[i] = mesh.vertices[i];
            runBaselineValid = true;
            return true;
        }
        return false;
    }

    // Value-driven replay (Decision D1): open the session if needed, capture a
    // fresh baseline if stale, then re-run applyTRS from `dragBaseline` reading
    // the CURRENT (already-injected) `run.t` ABSOLUTELY — no delta
    // accumulation, no zeroing of `run.t`. Keys off `dragBaseline`
    // (full-mesh, length-equal to mesh.vertices), NOT editBaseline() which is
    // partial and reordered (see :277-282) and would trip applyTRS's length
    // assert. Shared by reEvaluate() and the panel-delta path's setup.
    private void replayTranslateFromBaseline() {
        captureDragBaselineIfStale();
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0, /*samplePipeFromBaseline=*/true);
        needsGpuUpdate = true;
    }

    // (MS-2's `commitRotateEdit` / `applyRotatePanelDelta` scaffolding was
    // removed in MS-8: the simpler MS-5 design keeps the rotate edit session
    // on `RotateTool` and unifies only the GEOMETRY via `applyRotateAbsoluteFromRun`
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

    // P-F introspection seam (test-only): the LIVE published transform attrs the
    // panel binds (run.t/Rotate/Scale, the TX..SZ Param.float_
    // pointees). The /api/toolpipe/eval provider emits these so the run-absolute
    // panel-display contract can be asserted from a unit test without poking the
    // panel struct. Read-only — never mutates tool state. (Phase 1 extends this
    // with the companion frozen run-frame accessor.)
    public Vec3 publishedTranslate() const { return run.t; }
    public Vec3 publishedRotate()    const { return headlessRotate; }
    public Vec3 publishedScale()     const { return run.s; }

    // Phase 5a (rotate sub-tool re-scope) — the wrapper-truth rotate state the
    // wrapped RotateTool reads instead of its own `angleAccum`/`propDeg` second
    // accumulator. The LIVE run-total euler is `publishedRotate()` above (= the
    // derived display `headlessRotate`, in DEGREES). `gestureStartRotateEuler()`
    // is the run orientation captured at THIS gesture's mouse-down
    // (`gestureStart.r`, decomposed to the same ZYX euler, in DEGREES). Both are
    // the matrix-truth view (eulerZYXFromMatrix), so a wrapped read of them never
    // diverges from what the panel actually shows — unlike the sub-tool's
    // gizmo-basis decomposition, which drifts across cross-axis multi-gesture runs.
    public Vec3 gestureStartRotateEuler() const {
        import math : eulerZYXFromMatrix;
        return eulerZYXFromMatrix(gestureStart.r);
    }

    // Phase 5b (scale sub-tool re-scope) — the wrapper-truth scale state the
    // wrapped ScaleTool reads instead of its own `scaleAccum`/`propScale` second
    // accumulator. Unlike rotate there is no euler/matrix view: `run.s` IS the
    // per-axis run-total factor directly, so the LIVE run-total is just
    // `publishedScale()` above. `gestureStartScaleFactor()` is the run-total
    // factor captured at THIS gesture's mouse-down (`gestureStart.s`, the scale
    // component of the per-gesture run snapshot). A wrapped read of these never
    // diverges from what the panel shows — they ARE the panel-bound truth (SX..SZ
    // bind `&run.s.*`), unlike the sub-tool's own accumulator which is only the
    // standalone-path / legacy-panel mirror.
    public Vec3 gestureStartScaleFactor() const { return gestureStart.s; }

    // P-F Phase 1 — the FROZEN per-run gizmo frame, for assertion via
    // /api/toolpipe/eval. `valid` is false until the first applyTRS of a run
    // freezes it; a relocate resets it (resetRun) so the next apply re-freezes.
    public void publishedRunFrame(out bool valid, out Vec3 origin,
                                  out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        valid  = runFrameValid;
        origin = runFrameOrigin;
        right  = runFrameR;
        up     = runFrameU;
        fwd    = runFrameF;
    }

    // Falloff in-session re-fire — PUBLIC R/S seam. The Rotate / Scale falloff
    // re-grade sites live on the sub-tools, but the run, history, currentRunBank,
    // and the recordFalloffRefire helper all live on the wrapper. These thin
    // public forwarders let the sub-tools (siblings, reached via wrapperRef cast,
    // same pattern as dragInFlight) run the §4.3 ARM-2 gate + record without
    // naming the wrapper-private DragBank enum or the refire state fields.
    //
    // The bank gate (currentRunBank == this bank, OBJ-2 single-winner) and the
    // staleness gate (mesh.mutationVersion == lastAppliedGestureMutationVersion,
    // OBJ-1) are both bundled here so the site reads a single boolean. The bank
    // is fixed by the typed entry point (refireRotateEligible / refireScaleEligible)
    // so the sub-tool never references DragBank.
    public bool refireRotateEligible() const {
        return history !is null
            && history.runOpen()
            && currentRunBank == DragBank.Rotate
            && mesh.mutationVersion == lastAppliedGestureMutationVersion;
    }

    public bool refireScaleEligible() const {
        return history !is null
            && history.runOpen()
            && currentRunBank == DragBank.Scale
            && mesh.mutationVersion == lastAppliedGestureMutationVersion;
    }

    // Record forwarders: the sub-tool dup'd the pre-recompute (post-gesture)
    // geometry into `anchor`, ran its absolute recompute (mutating mesh.vertices),
    // and dup'd the result into `after`. These route into the shared helper with
    // the correct bank tag. The helper re-checks the staleness gate as
    // defense-in-depth (§4.1 step 0) and re-stamps lastAppliedGestureMutationVersion
    // after the record (a no-op today; defensive).
    public void recordFalloffRefireRotate(string label, Vec3[] anchor,
                                          Vec3[] after, size_t[] idx,
                                          FalloffPacket preF, FalloffPacket postF,
                                          SnapPacket preSn,  SnapPacket postSn,
                                          SymmetryPacket preSy, SymmetryPacket postSy) {
        recordPipeRefire(label, anchor, after, idx, DragBank.Rotate,
                         preF, postF, preSn, postSn, preSy, postSy);
    }

    public void recordFalloffRefireScale(string label, Vec3[] anchor,
                                         Vec3[] after, size_t[] idx,
                                         FalloffPacket preF, FalloffPacket postF,
                                         SnapPacket preSn,  SnapPacket postSn,
                                         SymmetryPacket preSy, SymmetryPacket postSy) {
        recordPipeRefire(label, anchor, after, idx, DragBank.Scale,
                         preF, postF, preSn, postSn, preSy, postSy);
    }

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
            attrBaseTranslate = run.t;
            attrBaseRotate    = headlessRotate;
            attrBaseScale     = run.s;
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

                // BUG-2 — capture the gesture-START SOFT pin LIVE here too (the
                // W1 lesson). For gesture-1 of a run this is typically unset (no
                // soft pin yet → revert clears, pivot recomputes to the
                // reverted-geometry centroid). For gesture-2+ of a sticky run it
                // is the prior gesture's settle, so revert restores that.
                gestureSoftStartPlaced = ac.isSoftPlaced();
                gestureSoftStartCenter = ac.currentSoftCenter();
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
        // BUG-2 — gesture-START SOFT pin, captured live at the same beginEdit and
        // gated by the SAME known flag (so a no-preceding-beginEdit commit makes
        // the soft-pin hook inert too, below).
        bool softStartPlaced = false;
        Vec3 softStartCenter = Vec3(0, 0, 0);
        if (startKnown) {
            softStartPlaced = gestureSoftStartPlaced;
            softStartCenter = gestureSoftStartCenter;
        }
        gesturePinStartKnown = false;

        // P-F Phase 3 — run-absolute WHOLE-STRUCT START/END for the per-gesture undo
        // hook (the Move arm of the unified hook; the Rotate/Scale arms live at the
        // gizmo mouse-up sites above). xfStart = this gesture's run-START snapshot
        // (captured at mouse-down, gestureStart); xfEnd = the current run-total
        // state. Gated by moveGestureStartKnown so a commit with no preceding
        // mouse-down (a no-op relocate cmd) leaves xfStart == xfEnd ⇒ the hook is
        // inert (no field jump on undo). A Move gesture only changes run.t; the R/S
        // fields are equal between xfStart and xfEnd, so the whole-struct restore is
        // byte-equivalent to restoring run.t alone. DISJOINT from the pin / soft-pin
        // / pipe-config hooks (a wrapper struct vs stage state) — composes into the
        // same closure without clobber.
        bool moveAbsKnown    = moveGestureStartKnown;
        XformState moveXfStart = gestureStart;
        XformState moveXfEnd   = run;
        moveGestureStartKnown = false;
        if (!moveAbsKnown) moveXfStart = moveXfEnd;   // inert

        // BASIS undo splice (mirror of the rotate/scale hooks). A Move gesture has
        // R_gesture == I — it never ROTATES the frame — but it DOES re-settle the
        // live handler basis via settleGestureBasis(moveSub.handler.axis*) above, so
        // frameEnd == frameStart only on an unrotated selection; on a selection whose
        // frame a prior gesture rotated, the re-settle equals frameStart there, so the
        // restore is effectively an identity no-op in that case too. The splice exists
        // so the basis restore composes uniformly across the three banks. frameEnd is
        // the gesture-END `frame` (settleGestureBasis above ran before this
        // commitEdit), frameStart the mouse-down capture. Gated by moveAbsKnown.
        GestureFrame moveFrameEnd   = frame;
        GestureFrame moveFrameStartLocal = moveAbsKnown ? moveFrameStart : moveFrameEnd;

        // Base commit discards the frozen pin snapshot, then builds + records the
        // cmd via recordCommit. We replicate the body so we can splice setHooks
        // between buildEditCmd and recordCommit (buildEditCmd returns null on a
        // no-op gesture — nothing to hook).
        discardAcenUserPlacedSnapshot();
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        // BUG-2 — a real edit command was built, so this gesture genuinely moved
        // geometry (NOT a no-op relocate click). Apply the pending Move-settle soft
        // pin NOW — after the null check (so a no-op relocate never sets it) and
        // BEFORE the gesture-END capture below (so the captured endSoft* reflects
        // the settle that the apply/redo hook must restore). publishState() inside
        // setSoftPlaced makes the live gizmo follow immediately. The display soft
        // pin is disjoint from the userPlaced pin captured here.
        if (pendingMoveSoftPin) {
            // Route through the shared settle so the 2-entry acenSettleAllowed()
            // predicate (Element + Local excluded) is the SINGLE mode filter; the
            // relocate gate that used to live at the mouse-up was dropped (Phase 3).
            bool _sp; Vec3 _sc;
            settleGestureCenter(pendingMoveSoftCenter, _sp, _sc);
            pendingMoveSoftPin = false;
        }

        // pin-END — current pin at mouse-up. If the gesture-START pin was never
        // captured (no preceding beginEdit-open), use the current pin for START
        // too so the hooks are inert (no pin jump on undo of a gesture that never
        // moved the pin).
        bool endPlaced = false;
        Vec3 endCenter = Vec3(0, 0, 0);
        // BUG-2 — gesture-END SOFT pin, the LIVE soft state at commit. The Move
        // mouse-up sets it (notifyAcenSoftPlaced) BEFORE this commit when falloff
        // is active and the mode allows relocate, so it is already settled here.
        bool softEndPlaced = false;
        Vec3 softEndCenter = Vec3(0, 0, 0);
        if (auto ac = activeAcenStage()) {
            endPlaced     = ac.isUserPlaced();
            endCenter     = ac.currentPinCenter();
            softEndPlaced = ac.isSoftPlaced();
            softEndCenter = ac.currentSoftCenter();
        }
        if (!startKnown) {
            startPlaced     = endPlaced;     startCenter     = endCenter;
            softStartPlaced = softEndPlaced; softStartCenter = softEndCenter;
        }

        // P-A blocker fix + P-C — UNIFORM hook family. Compose the WHOLE
        // transient pipe CONFIG restore (falloff + snap + symmetry) alongside the
        // pin restore. A transform run is consolidated at DROP as [moveGesture,
        // pipeRefire]; mergeRun keeps first.revert + last.apply. The refire entry
        // carries the pipe-CONFIG hooks (recordPipeRefire Step 3.5), the gesture
        // entry carries PIN hooks — and now ALSO the run-start pipe config. So the
        // merged first.revert (= this gesture's revert) restores the pin AND every
        // transient pipe handle (a single post-drop Ctrl+Z reverts geometry + pin
        // + falloff + snap + symmetry together; before P-A/P-C the handle was
        // stranded at its post-tweak value). Snapshot the config AT THIS gesture's
        // commit (= run-start config, since a config tweak only fires AFTER a
        // gesture commits) and restore it from BOTH hooks. The pin restore + the
        // three config restores are INDEPENDENT stage mutations
        // (ActionCenterStage / FalloffStage / SnapStage / SymmetryStage own
        // disjoint state) — none reads another, so the composed closure calls all
        // without clobber. ABSOLUTE (assign), splices through mergeRun like the
        // pin endpoints. The gesture never changes the pipe config, so the
        // snapshot is the same on apply and revert here; it exists purely so the
        // merged first.revert carries it.
        // FALLOFF is SET-aware: snapshot every active instance's config keyed
        // by stage identity (1-element = the prior single-stage path,
        // byte-identical). SNAP + SYMMETRY stay SINGLE.
        FalloffSetSnapshot fSnap = snapshotFalloffSet(activeFalloffStages());
        SnapPacket     snSnap; bool haveSn = false;
        SymmetryPacket sySnap; bool haveSy = false;
        if (auto sn = activeSnapStage())     { snSnap = sn.snapshotConfigToPacket(); haveSn = true; }
        if (auto sy = activeSymmetryStage()) { sySnap = sy.snapshotConfigToPacket(); haveSy = true; }

        cmd.setHooks(
            // apply (redo): restore the gesture-END pin + SOFT pin + run pipe
            // config + publish. The userPlaced pin and the display soft pin own
            // DISJOINT ActionCenterStage state (neither reads the other), so the
            // two restores compose in one closure without clobber — like the
            // independent pin / falloff / snap / symmetry restores (P-A).
            () {
                if (auto ac = activeAcenStage()) {
                    ac.restorePinState(endPlaced, endCenter);
                    ac.restoreSoftPlaced(softEndPlaced, softEndCenter);
                }
                restoreFalloffSet(fSnap);
                if (haveSn) if (auto sn = activeSnapStage())     sn.restoreConfigFromPacket(snSnap);
                if (haveSy) if (auto sy = activeSymmetryStage()) sy.restoreConfigFromPacket(sySnap);
                // P-F Phase 3: restore the gesture-END run state so the panel
                // TX/TY/TZ (+ RX/RY/RZ + SX/SY/SZ) track the redone geometry (run
                // total after this gesture). headlessRotate is re-derived from
                // run.r so the panel + matrix stay locked. DISJOINT wrapper struct —
                // composes without clobber.
                run = moveXfEnd; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = moveFrameEnd; refreshFrameValid();
            },
            // revert (undo): restore the gesture-START pin + SOFT pin + run pipe
            // config + publish. The gesture-START soft state is typically cleared
            // (gesture-1 of a run had no soft pin), so the pivot recomputes to the
            // reverted-geometry centroid — closing the BLOCKER where the gizmo
            // stayed floating at the settled height.
            () {
                if (auto ac = activeAcenStage()) {
                    ac.restorePinState(startPlaced, startCenter);
                    ac.restoreSoftPlaced(softStartPlaced, softStartCenter);
                }
                restoreFalloffSet(fSnap);
                if (haveSn) if (auto sn = activeSnapStage())     sn.restoreConfigFromPacket(snSnap);
                if (haveSy) if (auto sy = activeSymmetryStage()) sy.restoreConfigFromPacket(sySnap);
                // P-F Phase 3: restore the gesture-START run state so an in-session
                // Ctrl+Z steps the panel back one gesture (the run total BEFORE this
                // gesture). headlessRotate is re-derived from run.r. mergeRun
                // first.revert/last.apply splices these to run-START / run-END at the
                // drop.
                run = moveXfStart; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = moveFrameStartLocal; refreshFrameValid();
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

    // Phase 1 (R/S run-baseline) — VALUE-attr live-eval widening. A panel
    // RX/RY/RZ or SX/SY/SZ edit after a gizmo gesture (but before the tool
    // drops) must compose onto the run baseline. The per-gesture commit model
    // (P-F) CLOSES the sub-tool edit session at each gizmo mouse-up, so
    // `subToolEditOpen()` is false BETWEEN gestures even though the run
    // continues — the held run-absolute field + frozen `dragBaseline` are still
    // the live state. Including `runIsLive()` HERE (not in `hasLiveEval()`) lets
    // the value-attr path re-evaluate while leaving the pipe-stage config path
    // (`tool.pipe.attr falloff …`) on the narrower `hasLiveEval()`, so a
    // mid-run falloff change still flows through the idle re-grade RECORD path
    // (one tagged in-session entry) instead of a silent panel replay.
    override bool hasLiveAttrEval() const {
        return hasLiveEval() || runIsLive();
    }

    // A transform gizmo RUN is live: a gesture established a frozen run baseline
    // (`runBaselineValid`) AND the history run is still open (not yet
    // consolidated at a boundary / tool drop). Gating on BOTH keeps a bare idle
    // tool (no gesture yet ⇒ runBaselineValid==false) inert, preserving the
    // headless set-attr-then-doApply scripting contract.
    private bool runIsLive() const {
        return runBaselineValid && history !is null && history.runOpen();
    }

    // Re-run the live transform from the session baseline using the CURRENT
    // (already-injected) headless attrs, ABSOLUTELY (Decision D1). Per active
    // flag:
    //   - flagT → replayTranslateFromBaseline() (equivalent to applyMovePanelDelta
    //     minus the delta accumulation / run.t zeroing).
    //   - flagR → rotateSub.applyRotatePanelValue(headlessRotate) — re-runs the
    //     absolute rotate from RotateTool's origVertices baseline.
    //   - flagS → scaleSub.applyScalePanelValue(run.s) — re-runs the
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
        //
        // This gate STAYS on the DERIVED euler `headlessRotate` (NOT the matrix
        // `run.r`), unlike the held-rotation identity checks elsewhere: on the
        // headless attr / panel re-eval path the param write lands the new value
        // into `headlessRotate` first, while `run.r` is only RECOMPOSED INSIDE
        // applyRotatePanelValue (recompose-from-euler). So at this gate `headlessRotate` is the
        // freshly-written truth and `run.r` is still the stale pre-edit matrix —
        // gating on `run.r` would skip a genuine panel rotate. (Gimbal lock cannot
        // false-zero here: the value just came FROM the euler the user/script set.)
        bool hasR = flagR && (headlessRotate.x != 0 || headlessRotate.y != 0
                                                     || headlessRotate.z != 0);
        bool hasS = flagS && (run.s.x != 1 || run.s.y != 1
                                                    || run.s.z != 1);
        if (hasR) rotateSub.applyRotatePanelValue(headlessRotate);
        if (hasS) scaleSub.applyScalePanelValue(run.s);
    }

    // ----- Test-only headless session opener (re-eval plan D5, Phase 3) -----
    //
    // Open a live edit session with NO geometry change, leaving
    // hasUncommittedEdit()==true so a subsequent `tool.attr` write hits the
    // already-live reEvaluate() branch (test 1b-absolute / test 2). Runs the
    // same beginEdit() + dragBaseline capture as the panel/attr replay path but
    // applies nothing: run.t stays at its current value (0 on a
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
    // X/Y/Z sliders remain the SINGLE live widget driving run.t.
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
        // run.s mirror (the attr the panel reads back) to it in lockstep
        // — the sub-tools own their geometry session but NOT those wrapper
        // fields, so the mirror restore has to happen here. Mirrors the attrBase*
        // discipline below; no-op (returns false) when the slot has no open
        // session. Their suppressCommit latches are self-contained (set/cleared
        // inside each cancelSessionIfOpen → cancelOpenSessionGeometry).
        Vec3 subDeg, subFactors;
        if (rotateSub.cancelSessionIfOpen(subDeg))     headlessRotate = subDeg;
        if (scaleSub.cancelSessionIfOpen(subFactors))  run.s  = subFactors;

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
            // Session cancel restores positions to the pre-edit baseline — a real
            // version bump (not mid-drag), so commitChange (Position) reproduces
            // the raw mutationVersion bump AND publishes the class.
            mesh.commitChange(MeshEditScope.Position);
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate = false;

            // Restore the headless TRS attrs to their session-start values so the
            // Tool-Properties panel / config form (which read params() — the live
            // &run.t.x etc. pointers — per frame) snap back in
            // lockstep with the geometry. Without this the verts revert but the
            // numeric fields keep the stale edited numbers. Captured on the
            // closed->open transition in beginEdit() above. (headlessRotate /
            // run.s were already snapped above from the sub-tool's
            // pre-edit panel value when its session was open; if the wrapper froze
            // them too, attrBase* holds the identical session-start value.)
            run.t = attrBaseTranslate;
            headlessRotate    = attrBaseRotate;
            run.s     = attrBaseScale;

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
        resetRun();                    // apply-path Phase 2: cancelled run (+ P-F frozen frame)
        moveDragFastPath    = false;
        rotDragFastPath     = false;
        rotDragAxisIdx      = -1;
        scaleDragFastPath   = false;
        scaleDragActive     = false;
        // Caches (ViewCache vertex/edge/face) re-validate next frame: while a
        // tool is active app.d invalidates them every frame (app.d :4574).
    }

    // resyncSession() re-baselines the still-live tool after a committed history
    // pop (in-session Ctrl+Z / Ctrl+Y) moved geometry beneath it. It runs the
    // shared resetTransientState() (overridden above to also clear the wrapper's
    // per-drag fast-path state + gizmo/vertex cache) so they recompute from the
    // now-current mesh on the next update().
    //
    // P-F Phase 3 — the ONE difference from activate()'s reset: the run-absolute
    // DISPLAY state (run + the derived headlessRotate) must be PRESERVED here, not
    // zeroed. history.undo()/redo() runs BEFORE this and fires the per-gesture
    // whole-struct revert/apply hooks (the unified hook restores gestureStart /
    // run — the Move arm in commitEdit, the Rotate/Scale arms at the gizmo mouse-up
    // sites), which set the run state to the reverted-to step's run total. The
    // refire entry carries the same whole-struct hook. Zeroing here (as
    // resetTransientState() and
    // resetRun() do on every non-resync path) would clobber that, snapping the
    // panel to identity while the geometry sits at the reverted-to pose. The flag
    // gates BOTH zeroing sites (resetTransientState's field-zero AND resetRun's
    // hadRun field-zero); scope(exit) restores it so no other path is affected.
    //
    // No-hook case (an in-session undo/redo of a NON-transform command, e.g. an
    // extrude, with the transform tool still live): no transform field hook fired,
    // so the fields keep their current value — correct, because a non-transform
    // pop does not change the transform tool's geometry contribution, and the
    // field is re-primed at the next gesture's begin*DragSession if ever stale.
    override void resyncSession() {
        resyncPreserveDisplayFields = true;
        scope(exit) resyncPreserveDisplayFields = false;
        resetTransientState();
    }

private:
    // P-F Phase 3 — set ONLY for the duration of resyncSession()'s
    // resetTransientState() call; suppresses the run-absolute display-field
    // zeroing in resetTransientState() and resetRun() so an in-session undo/redo
    // keeps the hook-restored field. False everywhere else (activate(), relocate,
    // selection/mode change, tool drop, cancel) → unchanged identity-zeroing.
    bool resyncPreserveDisplayFields = false;

    // Element-falloff click-pick. Reads the GPU-resolved hover state
    // (g_hoveredVertex/Edge/Face — published by app.d after each
    // render frame) and pushes the picked element's centroid through
    // ACEN.setUserPlaced (via notifyAcenUserPlaced). The anchor is
    // always the element centroid (vertex position, edge midpoint,
    // face centroid) — click-position does not affect it.
    //
    // FalloffStage's connectMask is also updated (mask seed is the
    // picked element's vert ring). Pick-type restricted by the
    // stage's elementMode. Returns true iff the click landed on a
    // hovered element.
    bool tryPickElement(int mx, int my) {
        FalloffStage stage = activeFalloffStage();
        if (stage is null || stage.type != FalloffType.Element) return false;

        ElementMode em = stage.elementMode;
        bool autoMode = (em == ElementMode.Auto);
        bool wantV = autoMode || (em == ElementMode.Vertex);
        bool wantE = autoMode || (em == ElementMode.Edge);
        bool wantF = autoMode || (em == ElementMode.Polygon);

        if (wantV && g_hoveredVertex >= 0
            && g_hoveredVertex < cast(int)mesh.vertices.length)
            return takeVert(stage, g_hoveredVertex);
        if (wantE && g_hoveredEdge >= 0
            && g_hoveredEdge < cast(int)mesh.edges.length)
            return takeEdge(stage, g_hoveredEdge);
        if (wantF && g_hoveredFace >= 0
            && g_hoveredFace < cast(int)mesh.faces.length)
            return takeFace(stage, g_hoveredFace);
        return false;
    }

    // Per take*, two pieces are written:
    //   1. ACEN.userPlaced ← picked element's centroid (gizmo
    //      pivot + falloff sphere anchor).
    //   2. FalloffStage.anchorRing ← picked element's vert indices
    //      (every one gets weight=1 in elementWeight, so the picked
    //      element drags as a rigid unit regardless of sphere radius).
    // Both pieces together form the `falloff.element` internal
    // hybrid (anchor + sphere).

    bool takeVert(FalloffStage stage, int vi) {
        notifyAcenUserPlaced(mesh.vertices[vi]);
        stage.anchorRing = [cast(uint)vi];
        // ACEN.Element tracks the picked element LIVE (the gizmo follows it
        // under the drag instead of being dragged to the moving-set centroid).
        notifyAcenElementVerts(stage.anchorRing);
        updateConnectMask(stage, vi);
        return true;
    }

    bool takeEdge(FalloffStage stage, int ei) {
        auto edge = mesh.edges[ei];
        Vec3 a = mesh.vertices[edge[0]];
        Vec3 b = mesh.vertices[edge[1]];
        // Anchor = edge midpoint (centroid of the two endpoints), click-independent.
        Vec3 anchor = (a + b) * 0.5f;
        notifyAcenUserPlaced(anchor);
        stage.anchorRing = [cast(uint)edge[0], cast(uint)edge[1]];
        notifyAcenElementVerts(stage.anchorRing);
        updateConnectMask(stage, cast(int)edge[0]);
        return true;
    }

    bool takeFace(FalloffStage stage, int fi) {
        // Anchor = face centroid (vertex average), click-independent.
        Vec3 anchor = mesh.faceCentroid(cast(uint)fi);
        notifyAcenUserPlaced(anchor);
        auto face = mesh.faces[fi];
        stage.anchorRing.length = face.length;
        foreach (i, vi; face)
            stage.anchorRing[i] = vi;
        notifyAcenElementVerts(stage.anchorRing);
        if (face.length > 0)
            updateConnectMask(stage, cast(int)face[0]);
        return true;
    }

    // Apply-path Phase 3 — does a HELD rotate/scale bank carry a non-identity
    // run-absolute right now? Gates the Move GPU fast-path between the cheap
    // pure-translation `gpuMatrix` (single-bank, byte-identical to pre-Phase-3)
    // and the CPU re-upload (cross-bank: the held bank's mouse-up replaced the
    // GPU buffer with the transformed mesh, so the fold's baseline-relative
    // matrix can no longer reconstruct the pose — drop out of the fast-path).
    // Mirrors the `flagR && headlessRotate!=0` / `flagS && run.s!=1`
    // gates `applyTRS` uses for `composeFor`, so the GPU path switches exactly
    // when the CPU fold starts composing a held rotate/scale factor.
    bool heldRotateOrScaleNonIdentity() const {
        // Gimbal-correct: test the rotate truth `run.r`, not the derived euler.
        const bool heldRot = flagR && !runRotIsIdentity();
        const bool heldScl = flagS && (run.s.x != 1
                                    || run.s.y != 1
                                    || run.s.z != 1);
        return heldRot || heldScl;
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
        // Compose S·R·T. R/S use the rotate/scale frame (ax/ay/az); the TRANSLATE
        // term uses its OWN basis (tx/ty/tz) so P-F can project the run-absolute
        // run.t along the FROZEN run-frame (the global path) while the
        // scale term keeps its per-frame / per-cluster frame untouched. For the
        // per-cluster path tx/ty/tz == ax/ay/az (the cluster's own axes — M5
        // geometry unchanged). The GLOBAL rotate factor is run.r (matrix-as-
        // truth), with the view-ring already folded in at the drain; the unused
        // viewAxis/viewAngleDeg params are vestigial (the live global path no longer
        // threads a transient view rotation through the fold).
        //
        // P-F (c): run.t is RUN-ABSOLUTE and the run baseline
        // (dragBaseline) is FROZEN at the run start (never re-baked across same-
        // bank gestures), so the T term is the FULL field projected once against
        // the frozen baseline — geometry = baseline + full-run-translate. This is
        // numerically the same per-gesture matrix the pre-(c) re-bake path built
        // (it composed the per-gesture delta against a re-baked baseline); only
        // the stored field value (run-absolute vs per-gesture) and the T basis
        // (frozen vs per-frame) changed. At idle (bare-write) the field is read
        // absolutely exactly as before.
        // `ax/ay/az` are the SCALE axes; `tx/ty/tz` the TRANSLATE axes. The ROTATE
        // factor is supplied two ways:
        //   - GLOBAL path (useRotM=true): `rotM` is run.r DIRECTLY — the
        //     run's world-space accumulated rotation (matrix-as-truth), an origin-
        //     fixed rotation re-pivoted by applyXformMatrix. No per-axis Euler
        //     rebuild, no frame re-interpretation: the matrix already encodes the
        //     gesture-order rotation about the real (possibly non-world) ring axes.
        //   - PER-CLUSTER legacy (useRotM=false): per-axis Euler about the cluster's
        //     own rx/ry/rz, exactly as before (its field carries ONE live axis).
        float[16] composeFor(bool useRotM, float[16] rotM,
                             Vec3 rx, Vec3 ry, Vec3 rz,
                             Vec3 ax, Vec3 ay, Vec3 az,
                             Vec3 tx, Vec3 ty, Vec3 tz) {
            float[16] M = identityMatrix;
            if (hasT)
                M = translationMatrix(tx * run.t.x
                                    + ty * run.t.y
                                    + tz * run.t.z);    // T (rightmost)
            if (flagR) {
                if (useRotM) {
                    M = matMul4(rotM, M);   // world rotation matrix (truth)
                } else {
                    void rot(Vec3 axis, float deg) {
                        if (deg == 0) return;
                        M = matMul4(pivotRotationMatrix(Vec3(0, 0, 0), axis,
                                        deg * cast(float)(PI / 180.0)), M);
                    }
                    rot(rx, headlessRotate.x);
                    rot(ry, headlessRotate.y);
                    rot(rz, headlessRotate.z);
                }
            }
            if (hasS)
                M = matMul4(pivotScaleMatrixBasis(Vec3(0, 0, 0), ax, ay, az,
                                                  run.s.x, run.s.y,
                                                  run.s.z), M);   // S (leftmost)
            return M;
        }

        // P-F Phase 2 — the GLOBAL fold's TRANSLATE term projects the run-absolute
        // run.t along the FROZEN run-frame (runFrameR/U/F), so the
        // displayed run-absolute components sum along a stable axis across same-
        // bank gestures even though currentBasis (bX/bY/bZ) re-derives per frame.
        // The frozen frame is captured at the run's first applyTRS (M6); it is
        // valid by the time we reach here.
        Vec3 tX = runFrameValid ? runFrameR : bX;
        Vec3 tY = runFrameValid ? runFrameU : bY;
        Vec3 tZ = runFrameValid ? runFrameF : bZ;

        // SCALE-AXIS CHAIN (same fix class as the rotate-axis chain d4e0ea0 and
        // the translate frozen-frame above) — the GLOBAL fold's SCALE term must
        // use a FROZEN basis, NOT the live currentBasis (bX/bY/bZ).
        // pivotScaleMatrixBasis scales `run.s` along the axes it is handed, and a
        // single-axis scale (e.g. SZ) deforms the selection's bbox aspect ratio,
        // so the live world-snapped select-derived basis (axis.d
        // computeSelectionBboxBasis: `right` = world axis of largest in-plane
        // bbox extent) SWAPS its largest-extent axis as the drag crosses an
        // extent tie and swaps BACK — the apply axis OSCILLATES A->B->A within
        // one drag (the user-found scale-after-rotate flip).
        //
        // SOURCE — mirror renderBasis (~1017) and the input channel
        // (beginScaleDragSession): when a prior same-session gesture left a
        // persisted gizmo frame (frame.settled && acenSettleAllowed), source the
        // scale axes from the unified `frame` DIRECTLY, not from runFrame. The run
        // frame is frozen at the run's FIRST applyTRS, but a chained scale REUSES the
        // prior (e.g. rotate) gesture's still-open run (noteRunBank consolidates
        // history but does NOT resetRun), so runFrame holds that run's ORIGINAL
        // world-snapped frame — `frame` carries the rotated frame the displayed
        // boxes + the input projection already use. Scaling along `frame` (=
        // run.r·world) composes with the held `run.r` in composeFor as
        // M = S(frame)·run.r: at run.s=I, M = run.r (held rotation only); as
        // run.s grows the extra scale is along the DISPLAYED rotated axis — no
        // double-count (S composes with run.r, it does not replace or re-rotate
        // it). For a FRESH first gesture (frame.settled==false) this falls back
        // to the frozen runFrame == the gesture-start currentBasis, so a
        // non-flipping drag is geometry-identical to the old live read and differs
        // ONLY on the flip frames it suppresses. Uniform-disc scale (run.s
        // isotropic) is rotation-invariant ⇒ frozen vs live is a no-op there. The
        // per-cluster (ACEN.Local) path below keeps its own per-cluster axes
        // (Local never chains — acenSettleAllowed excludes it).
        Vec3 sX = tX, sY = tY, sZ = tZ;
        // Gesture-frame unification — the chained scale axes read the unified
        // `frame` (the single source of truth). `frame.valid` IS `frame.settled &&
        // acenSettleAllowed()` by construction.
        if (frame.valid) {
            sX = frame.right; sY = frame.up; sZ = frame.axis;
        }

        // MATRIX-AS-TRUTH — the GLOBAL rotate factor is `run.r` directly (the
        // run's world-space accumulated rotation, composed about the real frozen
        // ring axes at the drain; the view-ring is already folded into it). It is an
        // ORIGIN-fixed world rotation; composeFor multiplies it into the S·R·T fold
        // and applyXformMatrix re-applies the pivot as `pivot + M·(v - pivot)`. No
        // per-axis Euler rebuild, no rotate-frame argument, no frame re-interpretation
        // (the matrix already encodes the rotation about the physical ring axes —
        // fixing the prior euler-as-truth basis bug on a non-world global basis).
        //
        // The APPLY PIVOT stays the LIVE `pivot` (= queryActionCenter sampled from
        // the frozen baseline via samplePipeFromBaseline). It is ALREADY stable for
        // the run on the global path (b6d1be4: rotate value edits read a stable pivot
        // from the baseline; with the baseline frozen all-run the sampled pivot
        // equals runFrameOrigin every frame). Keeping the live pivot avoids perturbing
        // the SHARED-fold Move/Scale terms.

        // TRANSLATE-TERM DE-ROTATION (task 0032, plan invariant ★):
        //
        // The fold builds M = run.r · T(applyBasis · run.t). For geometry to track
        // the rendered arrow/handle, net Δ must equal worldDelta. The move decomposed
        //   run.t = inputBasisᵀ · worldDelta
        // where `inputBasis` is EXACTLY what beginMoveDragSession pushed via
        // setWrapperInputFrame (`:2059-2060`):
        //   inputBasis = frame.valid ? (frame.right, frame.up, frame.axis) : runFrame
        //
        // Substituting into net Δ = run.r · applyBasis · inputBasisᵀ · worldDelta:
        //   applyBasis = run.rᵀ · inputBasis   (★ the fix)
        // This lands net Δ = worldDelta whenever applyFold's inputBasis read matches
        // the basis the move actually decomposed against — world-input (Auto/None
        // ACEN where frame settles WORLD), rotated-input (axis=Select settles
        // run.r·B0, giving applyBasis=B0 so double-correction cannot occur), and
        // run.r==I (tdX/tdY/tdZ = inputBasis = tX/tY/tZ, byte-identical).
        //
        // EXCEPTION (pre-existing, not fully closed here): ACEN=Element never settles
        // a frame (acenSettleAllowed() false ⇒ frame.valid false), so this reads
        // `runFrame` (frozen at rotate-start) while the Element move projects onto a
        // LIVE element basis that drifts per-frame. A residual skew remains — but the
        // fix strictly IMPROVES it (it removes the dominant run.r term), so Element
        // rotate→move is closer to the handle than before, just not exact. Closing
        // that residual is out of scope (it predates this fix).
        //
        // The de-rotation is TRANSLATE-ONLY: tdX/tdY/tdZ is a SEPARATE triple;
        // tX/tY/tZ (and sX=tX above) are NOT modified, so the scale term is
        // byte-stable (BLOCKER 2). The gate `flagR && !runRotIsIdentity()` is a
        // no-op shortcut for the identity case; the algebra self-corrects without it.
        // center-box free-plane drag (dragAxis 3) is excluded — its decompose and
        // re-expand share the live basis, so the round-trip already cancels.
        //
        // SCOPE: the fix applies ONLY when an active move DRAG produced run.t via
        // the inputBasis decomposition (`:779-782` in move.d). In the panel/headless
        // path (tool.attr TX + RY, tool.doApply) `run.t` is a direct panel value in
        // the tX/tY/tZ basis — no decomposition, no de-rotation needed. The gate
        // `activeDrag is moveSub` distinguishes the two: live drag = true, panel =
        // false. (Panel path: `applyBasis = tX` → `M = run.r · T(worldDelta)` which
        // is the correct T-before-R chain semantics for numeric TX/RY attrs.)
        Vec3 tdX = tX, tdY = tY, tdZ = tZ;   // translate axes for composeFor
        if (activeDrag is moveSub
                && flagR && !runRotIsIdentity() && !moveCenterBoxDragActive()) {
            // inputBasis = what beginMoveDragSession pushed (`:2059-2060`)
            Vec3 ibX = frame.valid ? frame.right : tX;
            Vec3 ibY = frame.valid ? frame.up    : tY;
            Vec3 ibZ = frame.valid ? frame.axis  : tZ;
            // applyBasis = run.rᵀ · inputBasis
            import math : transformPoint;
            float[16] rT = transpose3x3(run.r);
            tdX = transformPoint(rT, ibX);
            tdY = transformPoint(rT, ibY);
            tdZ = transformPoint(rT, ibZ);
        }

        float[16] M = composeFor(/*useRotM=*/true, run.r,
                                 Vec3(0,0,0), Vec3(0,0,0), Vec3(0,0,0),
                                 sX, sY, sZ, tdX, tdY, tdZ);

        // MS-4.5 — publish the GLOBAL composed matrix + pivot for the GPU
        // fast-path to reuse (whole-mesh fast-path is never per-cluster).
        lastFoldMatrix  = M;
        lastFoldPivot   = pivot;
        // lastFoldAnchor is published below, after `src` is built.

        // Per-cluster (ACEN.Local): one composed matrix per cluster, in its OWN
        // per-frame frame about its OWN pivot. This path STAYS LEGACY — the single
        // global run.r is a WORLD rotation; re-applied about each cluster's
        // diverged local axes it would diverge, so the matrix-truth model is
        // GLOBAL-only. Here rotate (per-axis Euler about the cluster frame, NOT the
        // matrix), scale AND translate all use the cluster's per-frame axes (M5:
        // geometry unchanged), and rotateRunNeedsRebake still re-bakes cross-axis /
        // view-ring under acen=local (the field carries ONE live axis per cluster).
        float[16][] clusterM = null;
        if (cp.active && ap.active) {
            clusterM = new float[16][](ap.right.length);
            foreach (cid; 0 .. ap.right.length)
                clusterM[cid] = composeFor(/*useRotM=*/false, identityMatrix,
                                           ap.right[cid], ap.up[cid], ap.fwd[cid],
                                           ap.right[cid], ap.up[cid], ap.fwd[cid],
                                           ap.right[cid], ap.up[cid], ap.fwd[cid]);
        }

        // Source = restored baseline gathered ordinal-parallel to the moving set;
        // weight at the BASELINE position (weightVerts == the mesh-length baseline).
        auto src = new Vec3[](vertexIndicesToProcess.length);
        foreach (k, vi; vertexIndicesToProcess)
            src[k] = (vi >= 0 && vi < cast(int)baseline.length)
                   ? baseline[vi] : Vec3(0, 0, 0);

        // Anchor = first moving-vert's frozen baseline position, used ONLY by
        // the CPU per-vertex kernel (applyXformMatrix) to avoid large-minus-large
        // cancellation at a far pivot. The GPU helper (wrapAboutPivotStable) does
        // NOT take the anchor — it computes its translate column in double. CPU and
        // GPU stay consistent because both reduce to the same affine map
        // pivot + M·(v - pivot), not via a shared anchor value.
        lastFoldAnchor = (src.length > 0) ? src[0] : Vec3(0, 0, 0);

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
        // DRIVER pass. Transforms exactly the original selection with each
        // driver's own falloff weight + matrix M. `dragSymmetry` is passed
        // DISABLED so the in-kernel position-copy tail never runs here: the
        // symmetry mirror is owned by the single position-copy call below.
        SymmetryPacket noSym;   // enabled == false
        // ROTATE-ONLY fold blend guard. When `!hasT && !hasS && flagR` the composed
        // matrix M == run.r is an origin-fixed PURE rotation (the pivot is applied
        // OUTSIDE M by applyXformMatrix as `pivot + M*(v - pivot)`), so
        // blendToIdentity(M, w, PolarQuat) = slerp(I, R, w) = R(w*theta) — scaling
        // the rotation ANGLE by the weight, radius-preserving. That is what a soft
        // radial-rotation preset (xfrm.softRotate / xfrm.swirl) wants. For a
        // COMBINED T*R*S fold, decomposing M into a pure rotation is NOT equivalent
        // to scaling the gesture (the per-axis scale/translate residual would be
        // re-spread non-linearly), so those folds MUST stay on MatrixLerp — hence
        // the guard only fires when rotate is the SOLE active bank.
        //
        // CONVENTION: the reference data backing "arc" is SINGLE-AXIS rotation only.
        // For multi-axis standalone-soft rotation (RX+RY+RZ under one falloff),
        // PolarQuat blends slerp(I, composed-R, w) — i.e. compose-then-arc-by-weight
        // — which is NOT reference-verified; it is the chosen convention, stated here
        // so a future reader does not mistake it for a captured result.
        BlendMode foldMode = (!hasT && !hasS && flagR
                              && rotateBlendMode() != BlendMode.MatrixLerp)
                           ? rotateBlendMode()
                           : blendModeForMeasure();
        applyXformMatrix(mesh, vertexIndicesToProcess, src, pivot, M,
                         lastFoldAnchor,
                         foldMode, dragFalloff, cachedVp, cp, ap,
                         clusterM, noSym, toProcess, /*weightVerts=*/ baseline);

        // MIRROR pass — fixed-base position-copy symmetry. The fold carries
        // exactly ONE symmetry model: the positive-axis side drives and is
        // reflected onto the other side, copying each driver's FINAL position
        // (the position the DRIVER pass just wrote into mesh.vertices). The
        // fixed base side is `sp.baseSide` (default +1, the positive axis), so
        // the result is symmetric about the plane regardless of which side the
        // falloff sits on — an asymmetric falloff on the non-base side is
        // discarded; the base side's weight drives both halves. This is
        // cluster-agnostic: it copies the per-cluster (ACEN.Local) final
        // positions the driver pass produced just as it copies the global ones.
        if (dragSymmetry.enabled
            && dragSymmetry.pairOf.length == mesh.vertices.length) {
            import symmetry : applySymmetryMirror, applySymmetryMirrorDelta;
            // `toProcess` is passed as both the selected mask AND the
            // also-touched out-mask, so mirror writes fold into the GPU upload /
            // undo touched set (replacing the deleted Pass B's outAlsoTouched
            // OR-in). On-plane drivers are projected back onto the plane inside
            // both paths, preserving the "center stays on the plane" contract.
            if (dragSymmetry.topology)
                applySymmetryMirrorDelta(mesh, dragSymmetry, baseline, toProcess, toProcess);
            else
                applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
        }

        // Change-notification (doc/change_notification_bus_plan, Stage 1): the
        // drag apply moved positions in place WITHOUT bumping mutationVersion
        // (mid-drag version stability is intentional — symmetry/falloff/snap
        // caches keyed on mutationVersion must stay put). noteChange accumulates
        // the Position class WITHOUT touching the counters, so subscribers see
        // Position on exactly the frames geometry moved. ONE note per apply (both
        // the global fold and the per-cluster clusterM path run through the single
        // applyXformMatrix above) — never per vertex.
        mesh.noteChange(MeshEditScope.Position);
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
                             Vec3(0, 0, 0),
                             blendModeForMeasure(),
                             dragFalloff, cachedVp, cp, ap, clusterM,
                             dragSymmetry, toProcess);
        } else {
            // Global / view-ring: single origin-fixing rotation about `axis`.
            applyXformMatrix(mesh, vertexIndicesToProcess, srcGather(),
                             pivot,
                             pivotRotationMatrix(Vec3(0, 0, 0), axis, angleRad),
                             Vec3(0, 0, 0),
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
        // The per-cluster symmetry tail was DELETED here. The live per-cluster
        // ACEN.Local drag routes through applyFold, which carries the single
        // fixed-base position-copy mirror (the positive-axis side drives and is
        // reflected onto the other side, copying each driver's FINAL position —
        // cluster-agnostic). This method (now with no live caller — the wrapper
        // accumulates run.t and folds) therefore carries no mirror; if it is
        // ever re-wired into the live path the fixed-base position-copy in
        // applyFold covers the mirror.
    }

    // Connected-component BFS seeded at the picked vert, written into
    // FalloffStage.connectMask. Active only when connect != Ignore.
    void updateConnectMask(FalloffStage stage, int seedVi) {
        if (stage.connect == ElementConnect.Ignore) {
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

    // The WHOLE active falloff SET (every TaskCode.Wght stage, pipe order) —
    // the wrapper's plural accessor for its set-aware gesture-commit + refire
    // config-restore hooks. WRAPPER-owned (kept vtable-separate from the base
    // TransformTool's `final falloffStagesForHooks()` for the same SEGV reason
    // as activeFalloffStage vs falloffStageForHooks). With a single active
    // falloff this is a 1-element slice ⇒ snapshot/restore byte-identical.
    FalloffStage[] activeFalloffStages() const {
        FalloffStage[] set;
        if (g_pipeCtx is null) return set;
        foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
            if (auto fs = cast(FalloffStage) s)
                set ~= fs;
        return set;
    }

    // The single ACEN stage — source of truth for the gizmo pivot. Used to
    // freeze / restore the user-placed pin across an in-session edit cancel
    // (see beginEdit() / cancelUncommittedEdit()).
    ActionCenterStage activeAcenStage() const {
        if (g_pipeCtx is null) return null;
        return cast(ActionCenterStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
    }

    // Wrapper-side mirror of ActionCenterStage.acenSettleAllowed() — the 2-entry
    // Element/Local exclusion, used by the per-bank settle gates at the mouse-ups.
    // Defaults FALSE when no ACEN stage is registered (nothing to pin into; basis
    // persistence must not fire without the matching center pin — one lifecycle).
    bool acenSettleAllowed() const {
        auto ac = activeAcenStage();
        return ac !is null && ac.acenSettleAllowed();
    }

    // Gesture chaining — is the ACTIVE drag the Move center-box free-plane drag
    // (dragAxis == 3)? That drag is BASIS-FREE: its input decompose passes the full
    // 3D snap delta (constrainSnapDelta returns delta unchanged, move.d:586) and
    // pendingTranslateDelta decomposes against the LIVE inputBasis (the wrapped
    // input channel is NOT pushed for axis 3 in beginMoveDragSession). So it must be
    // EXCLUDED from the gesture-frame chaining on the APPLY side (runFrame B0) and
    // the visual center-follow too:
    // re-expanding run.t along a rotated runFrame while it was decomposed against the
    // live basis would round-trip to R·worldDelta — a center-box free-drag after a
    // Border rotate would translate rotated by the gizmo angle (off the cursor). The
    // surrounding gizmo can still draw rotated (renderBasis); only this handle's
    // input + apply + visual-follow stay on the live (un-rotated) basis, as before
    // the chaining change.
    bool moveCenterBoxDragActive() const {
        return activeDrag is moveSub && moveSub.dragAxis == 3;
    }

    // flex_border_handles_plan.md Phase 3 (BUG-1) — the ONE gesture-end center
    // settle, shared by the move / rotate / scale mouse-up paths. It pins the
    // drop center as a DISPLAY soft pin so the selection-derived modes (Auto /
    // None / Screen / Select / SelectAuto / Border) return it from computeCenter
    // instead of recomputing the (falloff-attenuated, post-deform) live center —
    // so a completed gesture leaves the gizmo at its drop pose, no jump-back
    // (the bug), persisting until selection/mode change clears the soft pin.
    //
    // It DELIBERATELY drops the `acenAllowsClickRelocate()` gate the old per-bank
    // calls carried — that gate admits only Auto/None/Screen and is exactly what
    // excluded Border (the flex mode) today. The ONLY exclusion is the 2-entry
    // `acenSettleAllowed()` predicate (Element + Local — modes with a
    // higher-precedence LIVE pivot source). Returns the (placed, center) the
    // caller's undo hook should restore as the gesture-END soft state, so the
    // splice carries the pin in lockstep with the geometry. When the settle is
    // not allowed it pins nothing and reports placed=false.
    void settleGestureCenter(Vec3 settledCenter,
                             out bool softEndPlaced, out Vec3 softEndCenter) {
        softEndPlaced = false;
        softEndCenter = Vec3(0, 0, 0);
        auto ac = activeAcenStage();
        if (ac is null) return;
        if (!ac.acenSettleAllowed()) return;
        ac.setSoftPlaced(settledCenter);
        softEndPlaced = ac.isSoftPlaced();
        softEndCenter = ac.currentSoftCenter();
    }

    // COMMIT B — persist the gesture-END rendered BASIS (the analogue of the center
    // settle above). Snapshot the bank's last-drawn handler.axis* (= the render
    // frame R_gesture·B0 the gesture left on screen) so the idle renderBasis holds
    // it after release instead of snapping to the world-snapped live currentBasis.
    // Called at every gesture mouse-up. Captured EXPLICITLY from the rendered basis
    // here (not runFrame*) so a boundary resetRun cannot strand it. Shares the
    // softPlaced lifecycle — cleared by clearFrame() on the same boundaries.
    void settleGestureBasis(Vec3 r, Vec3 u, Vec3 f) {
        // Gate mirrors settleGestureCenter's acenSettleAllowed() so center + basis
        // persistence share ONE Element/Local exclusion lifecycle: in Local the
        // center re-derives per-cluster on release, so the basis must NOT freeze (a
        // single drop-frame can't represent N clusters — Risk 5); in Element the
        // live picked-element anchor keeps tracking. Without this gate the basis
        // would freeze while the center re-derives → a center/basis desync.
        auto ac = activeAcenStage();
        if (ac is null || !ac.acenSettleAllowed()) return;
        // Write the persisted gesture-end basis DIRECTLY into the unified frame —
        // `frame` is the single source of truth now (no parallel mirror slot).
        frame.right   = r;
        frame.up      = u;
        frame.axis    = f;
        frame.settled = true;
        debug assertGestureFrameOrthonormal();
        refreshFrameValid();   // settled + ACEN allows ⇒ frame.valid = true
    }

    // Drop the persisted gesture-end basis so the idle gizmo re-derives from the
    // live selection (a new selection / a mode change recomputes the basis). Driven
    // from the SAME wrapper boundaries that clear the center soft pin.
    void clearFrame() { frame.settled = false; refreshFrameValid(); }

    // Re-gate the chained-read flag: `frame.valid = frame.settled &&
    // acenSettleAllowed()`. Called at exactly the points the basis or the ACEN
    // mode can change (settle / clearFrame / each begin*DragSession), so every
    // read site sees the value the former persisted-basis chained gate produced.
    // The triple is left untouched — when `settled` is false the gate makes it
    // unreadable, exactly as the old mirror did.
    private void refreshFrameValid() {
        frame.valid = frame.settled && acenSettleAllowed();
    }

    // DEBUG-only — the chained frame is always a pure-rotation orthonormal
    // triple, so `frameMatrixInverse == transpose(frameMatrix) == inverse`
    // holds by construction. Assert it at population (Risk G): unit-length,
    // mutually orthogonal vectors, and `m·mInv ≈ I`. Compiled out of release.
    debug private void assertGestureFrameOrthonormal() {
        import std.math : abs;
        enum float tol = 1e-3f;
        assert(abs(frame.right.length - 1.0f) < tol, "frame.right not unit length");
        assert(abs(frame.up.length    - 1.0f) < tol, "frame.up not unit length");
        assert(abs(frame.axis.length  - 1.0f) < tol, "frame.axis not unit length");
        assert(abs(dot(frame.right, frame.up))   < tol, "frame right·up not orthogonal");
        assert(abs(dot(frame.right, frame.axis)) < tol, "frame right·axis not orthogonal");
        assert(abs(dot(frame.up,    frame.axis)) < tol, "frame up·axis not orthogonal");
        auto m    = frame.m();
        auto mInv = frame.mInv();
        auto prod = matMul4(m, mInv);
        foreach (i; 0 .. 16)
            assert(abs(prod[i] - identityMatrix[i]) < tol,
                   "frame m·mInv not identity (orthonormality violated)");
    }

    // P-C: the single SNAP / SYMM stages — config sources of truth for the
    // snap + symmetry banks. The refire entry's config-restore hooks + the
    // gesture-commit hooks restore their config through these (mirrors
    // activeFalloffStage). Wrapper-owned virtuals; the base TransformTool keeps
    // its own `final` snapStageForHooks()/symmetryStageForHooks() for the R/S
    // sub-tools (the same vtable-collision avoidance as falloffStageForHooks).
    SnapStage activeSnapStage() const {
        if (g_pipeCtx is null) return null;
        return cast(SnapStage) g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
    }
    SymmetryStage activeSymmetryStage() const {
        if (g_pipeCtx is null) return null;
        return cast(SymmetryStage) g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
    }

    MoveTool   moveSub;
    RotateTool rotateSub;
    ScaleTool  scaleSub;

    // Single shared cross-bank handle arbiter (two-pass hit-test → draw).
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

    // P-C — ACEN-mode boundary poll. `actr.*` is a SideEffect command
    // (commands/actr.d) so it records nothing and never trips the
    // command-history foreign-record guard — yet an action-center MODE change
    // mid-run IS a session BOUNDARY (the reference restarts the op at a new
    // pivot, panel values reset to 0). So the wrapper polls the published ACEN
    // mode at idle in update() (the SAME path as the falloff-packet compare,
    // alongside the selection/mutation guard): on a change with an open run it
    // consolidates the open run + nextRun() so the next gesture is a new run.
    // -1 = "no mode observed yet"; the first poll latches the current mode
    // without spuriously firing a boundary (mirrors lastSelectionHash /
    // lastMutationVersion init-latch). Cast from ActionCenterStage.Mode (an
    // int-backed enum); -1 is outside its value range so any real mode differs.
    int lastAcenMode = -1;

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

    // Arm (or, for a BRUSH-RESET tool, DISARM) the in-session falloff re-grade
    // staleness stamp at a gesture's mouse-up commit. Called from all three bank
    // commit sites in place of a bare `= mesh.mutationVersion`.
    //
    // A brush-reset tool (`xfrm.softDrag`, `flags: [brushReset]`) bakes each LMB
    // stroke as an atomic action — its transform zeroes between strokes, so after
    // a move stroke a later radius gesture drives only the falloff, never the
    // transform, and the committed stroke does not re-deform. So a falloff /
    // radius change at idle must NOT re-grade the committed stroke. Disarming the stamp
    // (`ulong.max`) makes ARM 2's version gate fail, so any post-stroke falloff
    // tweak is inert for a brush tool. Plain move / rotate / scale (no
    // brushReset) arm normally and keep the in-session re-grade unchanged.
    private void armRegradeStamp() {
        lastAppliedGestureMutationVersion =
            hasFlag(ToolFlag.BrushReset) ? ulong.max : mesh.mutationVersion;
    }

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

    // refirePre{Falloff,Snap,Sym} — once-per-RE-FIRE-WINDOW PRE-tweak pipe config,
    // the config analogue of refireAnchor. BUG-2 fix: a CONTINUOUS falloff/snap/
    // symmetry scrub fires recordPipeRefire every frame and (per P-E) the frames
    // REPLACE into ONE coalesced in-session entry. Each site captures its
    // `preF = dragFalloff` BEFORE re-reading the live packets, so on the WINDOW's
    // FIRST frame `preF` IS run-start — but on later frames `dragFalloff` already
    // holds the PRIOR frame's tweaked value (captureFalloffForDrag /
    // recaptureLivePipePackets clobbers it every frame). Using that per-frame
    // `preF` as the coalesced entry's revert endpoint left an in-session Ctrl+Z
    // restoring the PENULTIMATE-frame config, not run-start — geometry reverted
    // but the viewport falloff viz stayed at the next-to-last scrub value.
    //
    // Fix: snapshot the PRE-tweak config ONCE at the window's first re-grade
    // (the same point refireAnchor is captured, from the SAME passed-in `preF`
    // that is still run-start on that first frame) and reuse it as the revert
    // endpoint for EVERY frame of the window. The DISCRETE path (one re-grade per
    // window) is unaffected: the captured value equals the single frame's `preF`.
    // `refirePreValid` distinguishes "no window open" from a legitimately captured
    // window (the packets are value structs with no empty sentinel). Cleared at
    // the SAME resets as refireAnchor.
    bool           refirePreValid;
    FalloffPacket  refirePreFalloff;
    SnapPacket     refirePreSnap;
    SymmetryPacket refirePreSym;

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
            refirePreValid                    = false;
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
    // The entry carries CONFIG-RESTORE hooks (P-A + P-C, Step 3.5 below): apply
    // restores the POST-tweak pipe config (falloff + snap + symmetry), revert
    // the PRE-tweak config, so an in-session Ctrl+Z reverts the pipe HANDLES /
    // config together with the geometry (and redo re-applies both). The entry
    // does NOT carry pin hooks: a falloff / snap / symmetry tweak never relocates
    // the pivot (an ACEN-mode change is a BOUNDARY, handled in update(), not a
    // refire), so the pin is unchanged across the re-grade. The MeshVertexEdit's
    // apply/revert still restore the geometry (contract C); the new hooks ride
    // alongside that, restoring config too.
    //
    // P-C: generalised from the P-A `recordFalloffRefire` (falloff only) to the
    // whole transient pipe config. The three config restores are INDEPENDENT
    // stage mutations (FalloffStage / SnapStage / SymmetryStage own disjoint
    // fields), so one composed closure calls all three without clobber.
    private void recordPipeRefire(string label, Vec3[] anchor,
                                  Vec3[] after, size_t[] idx, DragBank bank,
                                  FalloffPacket preF, FalloffPacket postF,
                                  SnapPacket preSn, SnapPacket postSn,
                                  SymmetryPacket preSy, SymmetryPacket postSy) {
        // `idx` is dead until a scoped-subset caller exists — only null
        // (full-range) callers today; kept so a future scoped re-grade need not
        // re-thread the signature.
        // Step 0 — staleness gate (defense-in-depth; the site already gated, but
        // the helper must refuse too). On a miss the run's anchor is invalid.
        if (mesh.mutationVersion != lastAppliedGestureMutationVersion) {
            refireAnchor.length = 0;
            refirePreValid      = false;
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

        // BUG-2: capture the PRE-tweak pipe config ONCE per re-fire window, from
        // the same first-frame `preF/preSn/preSy` the site passed in (still
        // run-start on the FIRST re-grade; clobbered to the prior frame's value on
        // later frames). On every subsequent frame OVERRIDE the passed-in pre-*
        // with this stored run-start config so the coalesced entry's revert hook
        // restores the TRUE run-start pipe config (the viewport falloff viz then
        // reverts WITH the geometry on an in-session Ctrl+Z), not the
        // penultimate-frame value. Captured at the SAME point as refireAnchor so
        // the geometry + config baselines stay in lockstep across the window.
        if (!refirePreValid) {
            refirePreFalloff = preF;
            refirePreSnap    = preSn;
            refirePreSym     = preSy;
            refirePreValid   = true;
        } else {
            preF  = refirePreFalloff;
            preSn = refirePreSnap;
            preSy = refirePreSym;
        }

        // Step 3 — build the entry. before[] = refireAnchor (post-gesture state)
        // for the moved indices; after[] = the re-graded positions. Drop any
        // index that did not actually move vs the anchor (no spurious payload).
        //
        // S1 economy: when `idx` is null/empty the index set is the FULL vertex
        // range (the falloff support can be the whole mesh, so a full pass is the
        // safe superset) — iterate `after` POSITIONALLY (after[vid] == the
        // re-graded position of vid, since every site dups the whole
        // mesh.vertices into `after`). This drops the per-re-grade identity
        // `size_t[] allIdx` allocation the sites previously materialised. When
        // `idx` is supplied (a scoped subset) it is honoured, with `after[k]`
        // positionally aligned to `idx[k]`.
        immutable bool fullRange = (idx.length == 0);
        immutable size_t n = fullRange ? after.length : idx.length;
        size_t[] movedIdx;
        Vec3[]   before;
        Vec3[]   movedAfter;
        movedIdx.reserve(n);
        before.reserve(n);
        movedAfter.reserve(n);
        foreach (k; 0 .. n) {
            immutable size_t vid = fullRange ? k : idx[k];
            if (vid >= refireAnchor.length || vid >= mesh.vertices.length)
                continue;
            Vec3 b = refireAnchor[vid];
            Vec3 a = after[k];
            if (a.x == b.x && a.y == b.y && a.z == b.z) continue;
            movedIdx   ~= vid;
            before     ~= b;
            movedAfter ~= a;
        }
        // movedIdx.length == 0 → the re-grade produced NO geometry delta. For a
        // falloff change this is the rare degenerate case (a weight tweak that
        // moved nothing). For snap it is the NORM (snap is a cursor-time op, not
        // in the fold). For symmetry it happens when the toggled-on pairing finds
        // no valid mirror partner on the deformed mesh. In ALL these cases the
        // pipe CONFIG still changed, and an in-session / post-drop undo must
        // restore that config (P-C). So instead of returning we record a
        // CONFIG-ONLY entry: an empty geometry edit (apply/revert no-op on the
        // mesh) carrying the SAME config-restore hooks. It rides the run like any
        // refire — replaceInSessionTail REPLACES a prior refire tail or APPENDS
        // after a gesture, and mergeRun keeps first.revert + last.apply, so the
        // config endpoints splice coherently. No geometry payload ⇒ no spurious
        // vertex churn on undo.
        uint[] uidx;
        uidx.length = movedIdx.length;
        foreach (k, vid; movedIdx) uidx[k] = cast(uint) vid;

        if (vertexEditFactory is null) return;
        auto cmd = vertexEditFactory();
        cmd.setEdit(uidx, before, movedAfter, label);

        // Step 3.5 — pipe CONFIG-restore hooks (P-A falloff + P-C snap/symmetry).
        // The re-grade entry must restore the pipe HANDLES / config together with
        // the geometry: an in-session Ctrl+Z reverts geometry (the MeshVertexEdit
        // revert) AND the falloff + snap + symmetry config to their PRE-tweak
        // values, and redo re-applies all — so the visible handles follow the
        // undo, not just the mesh. The hooks fire MAIN-thread (C4:
        // history.undo/redo runs from tickUndo() / navHistory, never the
        // background /api/undo poster), so mutating + publishing the stages from
        // inside them is safe — identical to the pin-hook precedent (commitEdit →
        // ActionCenterStage.restorePinState).
        //
        // ABSOLUTE snapshots, NOT deltas (mirrors rotate.d accum hooks): revert →
        // PRE-tweak packets, apply → POST-tweak packets. This is required for
        // mergeRun correctness — a consolidated run keeps first.revert +
        // last.apply, so absolute endpoints splice coherently (a delta would
        // double-apply across the merge). The captured packets are by-value
        // copies (struct), so they survive past this stack frame. The three
        // restores hit DISJOINT stage state (FalloffStage / SnapStage /
        // SymmetryStage own non-overlapping fields), so one closure calls all
        // three without clobber.
        FalloffPacket  preFCopy  = preF,  postFCopy  = postF;
        SnapPacket     preSnCopy = preSn, postSnCopy = postSn;
        SymmetryPacket preSyCopy = preSy, postSyCopy = postSy;
        // P-F Phase 3 (MAJOR-5) — the run-absolute WRAPPER state joins the unified
        // hook family on the refire entry IDENTICALLY to the gesture-commit entry,
        // or mergeRun first.revert/last.apply would strand it: an in-session Ctrl+Z
        // after a snap/falloff mid-run refire would restore geometry but leave the
        // run state (run.t/run.r/run.s) at the post-refire value (panel desyncs from
        // geometry). A refire re-grades geometry under the SAME transform, so the
        // run state does NOT change across it — snapshot the CURRENT WHOLE struct as
        // BOTH pre and post (pre == post). When the refire entry is merged with the
        // gesture entries, the struct endpoints splice coherently because every
        // entry in the run carries the whole-struct hook. DISJOINT from the
        // pipe-config restores. headlessRotate is re-derived from run.r so the panel
        // + matrix stay locked.
        XformState xfNow = run;
        // BASIS undo splice on the refire entry — IDENTICAL reasoning to xfNow: a
        // mid-run snap/falloff re-grade does NOT change the persisted gizmo basis,
        // so snapshot the CURRENT `frame` as BOTH pre and post. It must ride EVERY
        // entry in the run (gesture + refire) so mergeRun first.revert/last.apply
        // splices the basis coherently — without it a refire-tail first.revert
        // would leave the basis at its post-gesture (rotated) value on undo.
        GestureFrame frameNow = frame;
        cmd.setHooks(
            // apply (redo): restore the POST-tweak pipe config + the run state
            // (unchanged across the refire) + publish.
            () {
                // FALLOFF set-aware: the captured pre/post packets are the
                // COMBINED published packet. For a single falloff that IS the
                // primary's config (restored directly, byte-identical); for a
                // multi-falloff Composite each stage is restored from the
                // matching contributor (pipe-order positional, same order the
                // combiner builds contributors and findAllByTask yields).
                restoreFalloffSetFromCombined(activeFalloffStages(), postFCopy);
                if (auto sn = activeSnapStage())     sn.restoreConfigFromPacket(postSnCopy);
                if (auto sy = activeSymmetryStage()) sy.restoreConfigFromPacket(postSyCopy);
                run = xfNow; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameNow; refreshFrameValid();
            },
            // revert (undo): restore the PRE-tweak pipe config + the run state +
            // publish.
            () {
                restoreFalloffSetFromCombined(activeFalloffStages(), preFCopy);
                if (auto sn = activeSnapStage())     sn.restoreConfigFromPacket(preSnCopy);
                if (auto sy = activeSymmetryStage()) sy.restoreConfigFromPacket(preSyCopy);
                run = xfNow; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameNow; refreshFrameValid();
            },
        );

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
    // `dragBaseline`: full-mesh snapshot. Lifetime is now RUN-SCOPED
    // (apply-path unification Phase 2): captured ONCE at the run's
    // FIRST gizmo gesture and reused by every subsequent gesture in the
    // same geometry run, so the held banks' run-absolutes
    // (`run.t`/`headlessRotate`/`run.s`) compose
    // through ONE `applyFold` from one original baseline (the reference
    // "Evaluate-from-original" shape) rather than re-baselining off the
    // progressively-mutated mesh per gesture. The per-frame `applyTRS`
    // restores ALL of `mesh.vertices` from this snapshot before
    // re-applying the chain — required because the per-cluster
    // translate kernel `applyTranslatePerCluster` is `+=` incremental
    // and symmetry mirroring touches indices outside
    // `vertexIndicesToProcess`. Re-captured at GEOMETRY-RUN boundaries
    // (relocate / element-pick / selection-change / off-gizmo-disallowed
    // click / tool drop), signalled by `runBaselineValid` going false.
    // The tool-session edit baseline (`editBefore` in TransformTool) is
    // separate and lives at session scope.
    Vec3[] dragBaseline;

    // Run-scoped validity flag for `dragBaseline` (apply-path unification
    // Phase 2). False ⇒ the next gizmo `begin*DragSession` re-captures the
    // run baseline AND resets the held-bank attrs to identity (a fresh
    // geometry run). True ⇒ reuse the existing baseline + held attrs so a
    // bank switch composes the active bank's live value ON TOP of the held
    // banks via the fold (NOT via a mesh re-baseline). Decoupled from the
    // undo-run boundary (`currentRunBank` / `noteRunBank`): a bank switch is
    // an UNDO run boundary but NOT a geometry-run boundary, so it does NOT
    // invalidate the baseline. Set false at every geometry-run boundary; set
    // true after a capture. NOTE (run-scoped aliasing audit, plan MINOR): an
    // explicit flag rather than the length-equality proxy — transforms never
    // change vertex count, so a same-length-but-stale baseline must be
    // distinguished from a fresh-run one, which length alone cannot do.
    bool runBaselineValid = false;

    // P-F (run-absolute panel) — the FROZEN per-run gizmo frame. Lifetime is
    // IDENTICAL to the geometry-run baseline (`runBaselineValid`): captured ONCE
    // at the run's first `applyTRS` and reset at EVERY geometry-run boundary via
    // `resetRun()`. The reference captures the gizmo basis once at activation;
    // vibe3d's `currentBasis` re-derives per frame, so summing the run-absolute
    // TX/TY/TZ across gestures along that drifting frame would wander under
    // acen=local. Freezing one world-space frame per run gives the run-absolute
    // components a STABLE axis to sum along. STORED on the wrapper (NOT on
    // ActionCenterStage, which is per-frame live and per-cluster). INERT in
    // Phase 1: captured + reset, but nothing READS it yet (composeFor still uses
    // the per-frame currentBasis) — Phase 2 wires the Move T component to it.
    bool runFrameValid  = false;
    Vec3 runFrameOrigin = Vec3(0, 0, 0);
    Vec3 runFrameR      = Vec3(1, 0, 0);
    Vec3 runFrameU      = Vec3(0, 1, 0);
    Vec3 runFrameF      = Vec3(0, 0, 1);

    // MATRIX-AS-TRUTH rotate — the run-scoped, world-space accumulated rotation
    // lives in `run.r` (the XformState field). It is the SINGLE SOURCE OF TRUTH
    // for the global-path rotate factor: the fold (composeFor / applyFold) applies
    // `run.r` DIRECTLY (an origin-fixed world rotation re-pivoted by
    // applyXformMatrix), and the panel field `headlessRotate` is DERIVED from it
    // every frame (eulerZYXFromMatrix) for display only — never the other way
    // round during a gesture. Composed about the ACTUAL frozen gizmo ring axis
    // (runFrameR/U/F[ax]) in gesture order, so a NON-WORLD global basis (oblique
    // acen=local→global single cluster, tilted workplane, screen axis) rotates
    // about the real physical ring axis — the bug the prior euler-as-truth model
    // had (it composed about world canon axes but applied about the frozen
    // runFrame). A numeric/panel RX/RY/RZ write RECOMPOSES it
    // (matrixFromEulerZYX(headlessRotate) — recompose-from-euler). Reset to identity
    // at every run boundary alongside headlessRotate.
    //
    // The per-GESTURE snapshot of the WHOLE run state captured at rotate mouse-down
    // (the run orientation BEFORE this gesture, plus T/S) lives in `gestureStart`.
    // The drain composes THIS gesture's incremental ring rotation onto
    // `gestureStart.r` (the producer emits a within-gesture angle, totalAngle reset
    // to 0 at every drag start), and the unified undo revert hook restores the
    // whole `gestureStart` struct (the inactive T/S banks restore to an unchanged
    // value — an identity no-op).

    // P-F Phase 3a (MAJOR-4) — GPU buffer-vs-frozen-baseline invariant. With the
    // Scale baseline now FROZEN for the whole run, the Scale OWN-bank fast-path
    // (`scaleDragFastPath`, draws GPU buffer × wrapAboutPivot(lastFoldMatrix))
    // is valid ONLY while the GPU buffer still holds the frozen run baseline:
    // `lastFoldMatrix` is composed RELATIVE to that baseline from the FULL
    // run-absolute run.s, so `wrapAboutPivot(fold) · buffer` reconstructs
    // the CPU pose only when buffer == frozen baseline. The moment ANY prior
    // committed gesture in this run did `gpu.upload(*mesh)` (mouse-up), the buffer
    // becomes the already-transformed mesh ≠ frozen baseline, and the fast-path
    // would DOUBLE-APPLY. This flag tracks that: FALSE at run start (resetRun —
    // buffer reflects the about-to-be-frozen baseline), set TRUE at every gesture
    // mouse-up upload. The R/S own-bank fast-path drops to needsGpuUpdate=true
    // when set (mirrors the Move buffer-vs-baseline drop-out at 1626). INVARIANT:
    // the R/S own-bank fast-path is valid only while runGpuBufferDirty == false.
    bool runGpuBufferDirty = false;

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
    // SAME basis projection that `run.t` accumulates,
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
