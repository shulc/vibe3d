module tools.transform.xfrm_transform;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedXfrmActivationEffect,
    PreparedXfrmUpdateEffect, PreparedXfrmUpdateKind;
import prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import prepared_xfrm_refire_state : PreparedXfrmRefireStateImage;
import prepared_xfrm_update_tail : PreparedXfrmUpdateTailOwner;
import prepared_xfrm_update_edit_close : PreparedXfrmUpdateEditCloseOwner;
import prepared_xfrm_slot_poll : PreparedXfrmSlotPollOwner;
import prepared_xfrm_update_boundary : PreparedXfrmUpdateBoundaryOwner;
import prepared_xfrm_replay : PreparedXfrmReplayOwner;
import prepared_move_update : PreparedMoveUpdateOwner;
import prepared_rotate_update : PreparedRotateUpdateOwner;
import prepared_scale_update : PreparedScaleUpdateOwner;
import document : Layer;
import mesh_gpu : GpuUploadOwner;

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
// - The wrapper owns the single edit session and history capability for all
//   enabled banks. Embedded tools retain their input and accumulator state but
//   cannot record independently.
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

import prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind;
private struct XfrmPreparedState {
    bool apply; Vec3 scale; bool consumable;
    @disable this(this);
}
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
import std.json : JSONValue;
import std.traits : FieldNameTuple, FieldTypeTuple;
import operator : VectorStack;

import ai.interaction : AiInteractionPhase;
import math : Vec3, Pin, Viewport, translationMatrix,
               pivotRotationMatrix, pivotScaleMatrixBasis, dot,
               identityMatrix, matMul4, wrapAboutPivot, wrapAboutPivotStable, eulerZYXFromMatrix,
               frameMatrix, frameMatrixInverse, ModelSpace, normalize;
import editmode : EditMode;
import seltype : SelType;
import mesh;
import mesh_ops.connected_mask : connectedComponentMask, edgeCentroid;
import handler  : ToolHandles;
import eventlog : queryMouse;
import shader : Shader;
import params : Param;
import tools.transform.transform : TransformTool, VertexEditFactory,
    MorphEditFactory, PreparedTransformActivationImage,
    PreparedTransformEditCloseImage;
import tool            : ToolFlag;
import edit_session    : LiveEvalClient, ParameterChangeBatch,
                         ParameterChangeSource, SlotActivationClient,
                         LifecycleUndoEmitter;
import tools.transform.move      : MoveTool;
import tools.transform.rotate    : RotateTool;
import tools.transform.scale     : ScaleTool;
import tools.transform.scale     : PreparedScaleEmbeddedDeactivateImage;
import prepared_record_context : PreparedToolDoorClient,
    PreparedToolParamDoorClient, PreparedToolPoseDoorClient;

struct PreparedXfrmEmbeddedDeactivateImage {
    TransformTool.PreparedScalarDeactivateImage wrapper, move, rotate;
    PreparedScaleEmbeddedDeactivateImage scale;
    bool expectedRecordViaInSession;
    bool flagT, flagR, flagS;
    bool valid;
    void clear() nothrow @nogc {
        valid = false; wrapper.clear(); move.clear(); rotate.clear(); scale.clear();
        expectedRecordViaInSession = flagT = flagR = flagS = false;
    }
}
// Task 0719 (T1) — halves of THIS class that live in sibling files as
// `mixin template`s. Plain (non-selective) imports on purpose: a template
// mixin resolves its identifiers at the instantiation site, so the template
// name has to be in scope HERE, and the moved bodies read the rest of this
// module's import list rather than one of their own.
import tools.transform.xfrm_item;
import tools.transform.xfrm_handles;
import tools.transform.xfrm_apply;
import tools.transform.morph_route : MorphRoute, defaultStored;
import tools.transform.xform_kernels :
    applyScaleFromActivation,   // dormant compoundPasses!=1 pow path only (applyTRS, F2)
    applyXformMatrix,
    BlendMode;
import command_history : CommandHistory, PreparedHistoryKind;
import command : Command;
import commands.mesh.vertex_edit : MeshVertexEdit;
import change_bus : MeshEditScope;
// Task 0614 Phase 3/4 — the item-mode apply path + its undo command.
import document : Layer, ItemXform;
import tools.transform.item_xform_kernels : applyGestureToItems;
import commands.layer.xform_edit : LayerXformEdit, LayerXformTarget;
import perf_probe : g_perf, Cat, g_frames, Phase;
import toolpipe.pipeline : g_pipeCtx, Pipeline;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage, FalloffSetSnapshot,
                                 snapshotFalloffSet, restoreFalloffSet,
                                 restoreFalloffSetFromCombined;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import toolpipe.packets  : FalloffType, ElementMode, ElementConnect, FalloffPacket,
                          SnapPacket, SymmetryPacket, SubjectPacket;
import toolpipe.subject  : SubjectSource, evaluateSubject;
import hover_state       : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
import snapshot          : MeshSnapshot;

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

// Local handle ids per bank (0..6 used; the stride must clear the highest
// local id so the per-bank [base, base+HANDLES_PER_BANK) ranges never
// overlap).
private enum int HANDLES_PER_BANK = 10;

private enum LatchedHandleBank { None, Move, Rotate, Scale }

private struct LatchedHandlePart {
    LatchedHandleBank bank = LatchedHandleBank.None;
    int localPart = -1;
}

private LatchedHandlePart latchedHandlePart(int hitPart) pure nothrow @safe @nogc {
    if (hitPart >= MOVE_BASE && hitPart < MOVE_BASE + HANDLES_PER_BANK)
        return LatchedHandlePart(LatchedHandleBank.Move, hitPart - MOVE_BASE);
    if (hitPart >= ROT_BASE && hitPart < ROT_BASE + HANDLES_PER_BANK)
        return LatchedHandlePart(LatchedHandleBank.Rotate, hitPart - ROT_BASE);
    if (hitPart >= SCALE_BASE && hitPart < SCALE_BASE + HANDLES_PER_BANK)
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

// Baseline restore used by `applyTRS.restoreBaseline`: copy `src` over the
// PREFIX of `dst` that both share, never more. `applyTRS` asserts the two
// agree in length, but `dub.json`'s `perf` buildType is `releaseMode`, which
// strips that assert — so the length agreement must be enforced by something
// that survives `-release`. A bare slice assignment (`dst[] = src[]`) does
// not: it requires exact agreement and throws RangeError otherwise, in every
// build type. The explicit bound below keeps the copy total-and-safe under
// `-release` while preserving the prefix semantics a longer `src` had.
private void restoreBaselinePrefix(Vec3[] dst, const(Vec3)[] src)
        pure nothrow @safe @nogc {
    const n = dst.length < src.length ? dst.length : src.length;
    foreach (i; 0 .. n) dst[i] = src[i];
}

unittest { // restoreBaselinePrefix: a length mismatch copies the shared prefix
           // and never throws — the contract `applyTRS.restoreBaseline` needs
           // in `perf` (releaseMode) builds, where its assert is stripped.
    // Longer source: copy the prefix, leave nothing out of range touched.
    Vec3[] dst = [Vec3(0, 0, 0), Vec3(0, 0, 0)];
    const(Vec3)[] longer = [Vec3(1, 2, 3), Vec3(4, 5, 6), Vec3(7, 8, 9)];
    restoreBaselinePrefix(dst, longer);
    assert(dst.length == 2, "prefix copy must not resize the destination");
    assert(dst[0] == Vec3(1, 2, 3), "prefix copy must take src[0]");
    assert(dst[1] == Vec3(4, 5, 6), "prefix copy must take src[1]");

    // Shorter source: copy what exists, leave the tail of dst alone.
    Vec3[] dst2 = [Vec3(0, 0, 0), Vec3(9, 9, 9)];
    const(Vec3)[] shorter = [Vec3(1, 1, 1)];
    restoreBaselinePrefix(dst2, shorter);
    assert(dst2[0] == Vec3(1, 1, 1), "shared prefix is restored");
    assert(dst2[1] == Vec3(9, 9, 9), "dst beyond src length is untouched");

    // Empty on either side is a no-op, not a fault.
    Vec3[] empty;
    restoreBaselinePrefix(empty, longer);
    restoreBaselinePrefix(dst2, []);
    assert(dst2[0] == Vec3(1, 1, 1), "empty src leaves dst unchanged");

    // Equal lengths (the normal case) copy everything.
    Vec3[] dst3 = [Vec3(0, 0, 0), Vec3(0, 0, 0)];
    restoreBaselinePrefix(dst3, [Vec3(1, 0, 0), Vec3(0, 1, 0)]);
    assert(dst3[0] == Vec3(1, 0, 0) && dst3[1] == Vec3(0, 1, 0),
           "equal-length restore is a full copy");
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

// F3a — per-bank gesture-record: the mechanical AoS regroup of the scattered
// `*Start*` fields (gesturePinStart* / gestureSoftStart* / rotate|
// scaleSoftStart* / move|rotate|scaleFrameStart / the three
// `*GestureStartKnown` flags) into ONE struct type, reused per-bank as
// `moveRec` / `rotateRec` / `scaleRec` (three instances — F3c's optional
// three-into-one collapse is a SEPARATE, deferred step).
//
// TWO known bits, NOT ONE — this is the load-bearing shape, not a stylistic
// choice:
//   - `pinKnown` gates `pinStart` + `softStart`. Set ONLY inside beginEdit's
//     closed->open guard (`if (!wasOpen && editIsOpen())`) — "first freeze of
//     the session wins".
//   - `runKnown` gates `runStart` + `frameStart`. Set UNCONDITIONALLY per
//     mouse-down inside each begin*DragSession, AFTER beginRunGesture.
// They diverge on the numeric/panel Move edit path (tool.attr TX via
// reEvaluate -> captureDragBaselineIfStale -> beginEdit, WITHOUT
// beginMoveDragSession): pinKnown goes true (a real beginEdit-open fired),
// runKnown stays false (no begin*DragSession ever ran) — so that commit's
// pin/soft hooks are LIVE while its run/frame hooks are inert (start==end).
// Merging the two bits would either strand the pin or fabricate a run jump on
// that path's undo. Rotate/Scale have NO pin-known family: their `pinKnown`
// stays permanently false (they never restore the userPin on commit).
//
// `runStart` is a COMMIT-HOOK COPY of the live, standalone `gestureStart`
// field (captured at each begin*DragSession's run-capture site, read at the
// matching commit site) — NOT a replacement for `gestureStart` itself.
// `gestureStart` stays a single shared field because renderBasis and the
// rotate-run-gesture drain read it without an active bank; an "active-bank"
// alias would be undefined there.
struct GestureRecord {
    bool pinKnown;
    bool runKnown;
    XformState    runStart;
    GestureFrame  frameStart;
    Pin           softStart;
    Pin           pinStart;
}

/// Detached value projection of the wrapper-owned reset state on activation.
/// Sub-tool activation, wrapper links and the history run live in separate
/// ordered phases; this image deliberately owns only the state written by the
/// virtual reset plus the post-history session tail.
struct PreparedXfrmActivationResetImage {
    PreparedTransformActivationImage base;
    XformState run;
    Vec3 headlessRotate;
    bool moveRunKnown;
    bool rotateRunKnown;
    bool scaleRunKnown;
    bool priorRotateWasViewRing;
    bool valid;

    void clear() nothrow @nogc {
        base.clear();
        run = XformState.init;
        headlessRotate = Vec3(0, 0, 0);
        moveRunKnown = rotateRunKnown = scaleRunKnown = false;
        priorRotateWasViewRing = valid = false;
    }
}

/// Detached geometry product used by the Rotate/Scale update producers.  The
/// wrapper itself remains untouched; all synchronous mesh delivery is drained
/// from the private candidate and replayed later by PreparedRecordContext.
struct PreparedXfrmRefireCandidate {
    Mesh mesh;
    int[] vertexIndices;
    bool[] vertexMask;
    int vertexCount;
    bool vertexCacheDirty;
    bool runFrameValid;
    Vec3 runFrameOrigin;
    Vec3 runFrameR;
    Vec3 runFrameU;
    Vec3 runFrameF;
    Layer[] itemTargets;
    ItemXform[] expectedItemXforms;
    ItemXform[] nextItemXforms;
    uint deliveryFlags;
    uint deliveryDomains;
    bool itemPrepared;
    bool applied;
    void clear() nothrow @nogc {
        mesh = Mesh.init;
        vertexIndices = null;
        vertexMask = null;
        itemTargets = null;
        expectedItemXforms = null;
        nextItemXforms = null;
        deliveryFlags = deliveryDomains = 0;
        itemPrepared = applied = false;
    }
}

struct PreparedXfrmReplayImage {
    MeshSnapshot expectedLive;
    Mesh candidate;
    int[] expectedIndices;
    int[] nextIndices;
    bool[] expectedMask;
    bool[] nextMask;
    int expectedCount;
    int nextCount;
    bool expectedCacheDirty;
    bool nextCacheDirty;
    bool expectedNeedsGpu;
    bool nextNeedsGpu;
    bool expectedRunFrameValid;
    bool nextRunFrameValid;
    Vec3 expectedRunFrameOrigin;
    Vec3 nextRunFrameOrigin;
    Vec3 expectedRunFrameR, expectedRunFrameU, expectedRunFrameF;
    Vec3 nextRunFrameR, nextRunFrameU, nextRunFrameF;
    FalloffPacket expectedFalloff;
    FalloffPacket nextFalloff;
    SnapPacket expectedSnap;
    SnapPacket nextSnap;
    SymmetryPacket expectedSymmetry;
    SymmetryPacket nextSymmetry;
    Layer[] itemTargets;
    ItemXform[] expectedItemXforms;
    ItemXform[] nextItemXforms;
    PreparedXfrmRefireStateImage historyRefire;
    uint deliveryFlags;
    uint deliveryDomains;
    bool panel;
    bool wrapper;
    bool meshPrepared;
    bool itemPrepared;
    bool valid;
    void clear() nothrow @nogc { this = PreparedXfrmReplayImage.init; }
}

/// Detached final phase of `update`: subject publication, shared gizmo pose
/// and wrapper GPU-matrix forwarding. Sub-tool updates are separate owners;
/// this image records only the wrapper writes that must follow them.
struct PreparedXfrmUpdateTailImage {
    SelType expectedSubject;
    SelType nextSubject;
    Vec3 center;
    Vec3 basisX;
    Vec3 basisY;
    Vec3 basisZ;
    float[16] expectedGpuMatrix;
    float[16] nextGpuMatrix;
    GpuMesh* expectedGpu;
    TransformTool expectedActiveDrag;
    MoveTool expectedMove;
    RotateTool expectedRotate;
    ScaleTool expectedScale;
    ubyte flags;
    bool expectedNeedsGpu;
    bool clearNeedsGpu;
    bool writeGpuMatrix;
    bool valid;

    void clear() nothrow @nogc {
        this = PreparedXfrmUpdateTailImage.init;
    }
}

struct PreparedXfrmItemEditCloseImage {
    Layer[] targets;
    ItemXform[] before;
    bool capturing;
    bool valid;
    void clear() nothrow @nogc { this = PreparedXfrmItemEditCloseImage.init; }
}

struct PreparedXfrmEditCloseImage {
    PreparedTransformEditCloseImage vertex;
    PreparedXfrmItemEditCloseImage item;
    bool itemSubject;
    SelType expectedSubject;
    ubyte expectedBank;
    bool closeWrapper;
    bool historyPrepared;
    bool discardAcenSnapshot;
    bool installCommitState;
    bool consumeGestureState;
    bool settleSoftPin;
    bool expectedPendingSoft;
    bool expectedCancelFrozen;
    Vec3 expectedPendingCenter;
    Pin expectedUserPin;
    Pin expectedSoftPin;
    Pin nextSoftPin;
    ActionCenterStage expectedAcen;
    FalloffPacket expectedDragFalloff;
    FalloffPacket nextDragFalloff;
    bool expectedPinKnown;
    bool expectedRunKnown;
    bool valid;
    void clear() nothrow @nogc {
        vertex.clear(); item.clear();
        itemSubject = closeWrapper = false;
        expectedAcen = null;
        expectedBank = 0;
        historyPrepared = discardAcenSnapshot = installCommitState =
            consumeGestureState = settleSoftPin = valid = false;
    }
}

private struct OwnedEditCloseProjection {
    PreparedXfrmEditCloseImage state;
    Command command;
    bool valid;
}

private struct PipeRefireProjection {
    PreparedXfrmRefireStateImage state;
    MeshVertexEdit command;
    bool stale;
    bool valid;
}

struct PreparedXfrmUpdatePreProjection {
    SelType subject;
    ulong selectionHash;
    ulong mutationVersion;
    ulong slotSignature;
    uint acenEpoch;
    FalloffPacket liveFalloff;
    SnapPacket liveSnap;
    SymmetryPacket liveSymmetry;
    bool selectionChanged;
    bool mutationChanged;
    bool selectionBoundary;
    bool slotBoundary;
    bool pivotMoved;
    bool editOpen;
    ubyte regradeBank;
    bool bankHeld;
    bool packetChanged;
    bool panelRegrade;
    bool wrapperRegrade;
    bool valid;
    void clear() nothrow @nogc { this = PreparedXfrmUpdatePreProjection.init; }
}

struct PreparedXfrmSlotPollImage {
    ulong expectedSignature;
    ulong nextSignature;
    uint expectedAcenEpoch;
    uint nextAcenEpoch;
    bool expectedValid;
    bool nextValid;
    bool boundary;
    bool pivotMoved;
    bool valid;
    void clear() nothrow @nogc { this = PreparedXfrmSlotPollImage.init; }
}

/// Exact wrapper-private state written by the two idle run boundaries in
/// `update`. History/session-close and the slot latch are ordered as separate
/// resources around this image; this owns only invalidate/reset/soft-frame
/// state and the selection census latches.
struct PreparedXfrmUpdateBoundaryImage {
    ulong expectedSelectionHash;
    ulong expectedMutationVersion;
    ulong nextSelectionHash;
    ulong nextMutationVersion;
    ulong expectedGestureMutation;
    ulong expectedUndoEpoch;
    Vec3[] expectedRefireAnchor;
    bool expectedRefirePreValid;
    XformState expectedRun;
    Vec3 expectedHeadlessRotate;
    GestureFrame expectedFrame;
    bool expectedRunBaselineValid;
    bool expectedRunFrameValid;
    bool expectedMorphRunValid;
    bool expectedItemBaselineValid;
    bool expectedRunGpuBufferDirty;
    bool expectedMoveRunKnown;
    bool expectedRotateRunKnown;
    bool expectedScaleRunKnown;
    bool expectedPriorRotateWasViewRing;
    ubyte expectedRunBank;
    Pin expectedSoftPin;
    ActionCenterStage expectedAcen;
    bool selectionBoundary;
    bool slotBoundary;
    bool invalidateRefire;
    bool hadRun;
    bool clearSoft;
    bool valid;
    void clear() nothrow @nogc {
        expectedRefireAnchor = null;
        expectedAcen = null;
        valid = false;
    }
}

// LiveEvalClient (task 0428): the sole implementor of the live re-evaluation
// capability — hasLiveEval / hasLiveAttrEval / reEvaluate below are the
// interface's implementations (EditSession discovers them by cast).
// LifecycleUndoEmitter (task 0428): marker — this tool records a
// ToolActivationCommand on arm (undo-cursor lifecycle stepping).
class XfrmTransformTool : TransformTool, LiveEvalClient, SlotActivationClient,
                          PreparedToolDoorClient, PreparedToolParamDoorClient,
                          PreparedToolPoseDoorClient,
                          LifecycleUndoEmitter {
public:
    final Mesh* preparedMeshForUpdate() const { return mesh; }
    // T/R/S flags — `T integer 0/1` etc. in the preset config.
    // Default to all enabled (the bare `Transform` preset that shows
    // all three handler banks). Preset loader flips these per-preset
    // before the first activate().
    bool flagT = true;
    bool flagR = true;
    bool flagS = true;
    // Uniform scale preset: when true, locks all three scale axes to one
    // factor. The single `uniformScale` param fans its value into
    // run.s=(v,v,v); only the centre disc handle is live (per-axis
    // arrows and plane circles are suppressed). Set via the hidden
    // `uniform` bool param (preset attr `uniform: "true"`).
    bool  uniform    = false;
    float uniformVal = 1.0f;

    // Task 0332 — Negative Scale. Off by default (preserves the pre-existing
    // "scale factor clamps at 0" behavior); when on, the scale-factor clamps
    // at both the app-code layer (scale.d clampScaleFactor/post-write clamps,
    // the uniform post-write clamp below) AND the ImGui slider `v_min` floor
    // (scale.d panel sliders, the uniform slider below) are relaxed so a drag
    // can cross zero into a mirrored (negative) scale. Reference-faithful
    // winding (capture-settled, task 0332 golden `xform_attrs_golden.json`):
    // a negative-axis scale mirrors positions with polygon vertex order
    // UNCHANGED (winding is NOT auto-reversed) — normals invert on non-
    // perpendicular faces, which is left as-is (inside-out is the intended
    // result of the mirror, not a bug).
    bool negScale = false;

    // Task 0332 — Slip UVs. Off by default. vibe3d's transform apply path
    // never touches UVs today, so OFF already matches the captured reference
    // default byte-exact (dUV==0) — no apply-path code is needed for OFF.
    // The ON law (per-face/per-corner planar reprojection, captured but
    // MEDIUM-confidence and deep — see xform_attrs_golden.json) is DEFERRED;
    // this flag is stored/exposed for panel parity and is currently a no-op
    // when set. Follow-up: doc/tasks/backlog/0383-slipuv-on-planar-reproject.md.
    bool slipUV = false;

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
    // Cause of the operation that OPENED the single wrapper-owned edit.  A
    // later value batch may change another channel in the same live parameter
    // region, but it does not rewrite this boundary identity.  Replay order is
    // therefore unable to manufacture provenance.
    private DragBank editCauseBank = DragBank.None;
    private bool editCauseProvisional;

    // Last completed value-batch observation. These fields are surfaced only
    // through the existing test-state endpoint so the actual command path can
    // prove both the write set and the one-fold rate.
    private string[] lastValueReplayChannels;
    private ParameterChangeSource lastValueReplaySource;
    private bool lastValueReplayValid;
    private DragBank lastValueReplayCause = DragBank.None;
    private ulong valueReplayFolds;

    // F3a — per-bank gesture records (see the `GestureRecord` doc comment
    // above for the two-known-bit / runStart-vs-gestureStart rationale). One
    // instance per bank; each begin*DragSession captures into its own
    // instance, each commit site (Move's commitEdit; the Rotate/Scale
    // mouse-up blocks) reads and clears its own instance. Rotate/Scale never
    // set `pinKnown` / `pinStart` — they never restore the userPin on commit.
    //
    // Replaces (mechanical field-for-field regroup, no read/write-site
    // semantics changed):
    //   gesturePinStartKnown/Placed/Center   -> moveRec.pinKnown / .pinStart
    //   gestureSoftStartPlaced/Center        -> moveRec.softStart
    //   rotateSoftStartPlaced/Center         -> rotateRec.softStart
    //   scaleSoftStartPlaced/Center          -> scaleRec.softStart
    //   move|rotate|scaleFrameStart          -> *Rec.frameStart
    //   move|scale|rotateGestureStartKnown   -> *Rec.runKnown
    //   (runStart is a NEW commit-hook copy of the standalone `gestureStart`
    //   field below — captured at each begin site, read at the matching
    //   commit site; `gestureStart` itself is unchanged and un-aliased.)
    private GestureRecord moveRec;
    private GestureRecord rotateRec;
    private GestureRecord scaleRec;

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
    // persisted `frame`, the BASIS analogue of the softStart center snapshots
    // in `GestureRecord` above (folded in there as `*Rec.frameStart`). Captured
    // at the matching mouse-DOWN (begin*DragSession) from the LIVE `frame` so
    // the per-gesture undo hook can restore the gesture-START basis on revert,
    // exactly as the center is restored via restoreSoftPlaced.
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
    // inert there too. Gated by each bank's OWN `runKnown` (frameStart rides the
    // same gate as runStart) so a commit with no preceding mouse-down stays inert.

    // P-F Phase 3 — per-GESTURE run-absolute snapshot. The WHOLE run state at
    // THIS gesture's mouse-down lives in `gestureStart` (one standalone struct
    // snapshot, captured in every begin*DragSession after beginRunGesture, and
    // copied into `*Rec.runStart` for the commit hook — see the GestureRecord
    // doc comment above / OBJ 3). The per-gesture undo hook restores
    // `gestureStart`'s captured value (run-START) on revert and `run` (run-END)
    // on apply; since a single gesture's drain only touches its OWN bank's field
    // (Move → run.t, Rotate → run.r, Scale → run.s), the inactive banks have
    // start == end and restoring them is an identity no-op — so the whole-struct
    // restore is byte-equivalent to the former per-bank field restores, and is
    // strictly more coherent across the mergeRun first.revert/last.apply splice
    // (every entry carries the full struct).
    //
    // Each bank's `runKnown` gates the inert fallback (a commit with no
    // preceding mouse-down — e.g. a relocate-boundary no-op cmd — falls back to
    // start == end so the hook does not move the field on undo) for its bank's
    // commit site, which fires independently. Set at the matching
    // begin*DragSession and cleared at the matching commit.

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
    // Inline identity literal (matches math.identityMatrix); a field
    // initializer cannot CTFE-cast the `immutable float[16]` constant to a
    // mutable field, so the literal is spelled out here (same constraint as
    // XformState.r).
    float[16] lastFoldMatrix  = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    Vec3      lastFoldPivot   = Vec3(0, 0, 0);
    // The SAME pivot before the 0649 world -> layer conversion. `lastFoldPivot`
    // is layer-space because its consumer is the GPU preview matrix, which the
    // draw path folds UNDER the item matrix. Anything that hands the pivot back
    // to a WORLD consumer — the ACEN display soft-pin, whose whole pin family is
    // world — needs this one instead. They are the same point at the identity
    // item transform and `pos` apart under a displaced layer, which is exactly
    // how far the gizmo would settle away from the geometry if the wrong one
    // were used.
    Vec3      lastFoldPivotWorld = Vec3(0, 0, 0);
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

    // Item mode: target set, run baseline, world -> layer conversion,
    // and the item-gesture undo session — `xfrm_item.d` (task 0719).
    mixin XfrmItemImpl;

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         SelType delegate() selTypeSrc = null,
         void delegate(ref Layer[]) itemTargetsSrc = null) {
        super(meshSrc, gpu, editMode, selTypeSrc);
        this.itemTargetsSrc_ = itemTargetsSrc;
        // Blocker 1 (0614 review): the sub-tools each have their OWN
        // `buildLocalVts` call sites (the property-panel replay entries in
        // scale.d / rotate.d), so the same live selType source must reach
        // every one of them, not just the wrapper. (The applyHeadless call
        // sites this used to cite as well are gone — audit №4, T3.)
        moveSub   = new MoveTool  (meshSrc, gpu, editMode, selTypeSrc);
        rotateSub = new RotateTool(meshSrc, gpu, editMode, selTypeSrc);
        scaleSub  = new ScaleTool (meshSrc, gpu, editMode, selTypeSrc);
        toolHandles = new ToolHandles();
        toolHandles.setAiHoverPreviewEnabled(true);
        toolHandles.setAiHoverPreviewPredicate(
            (int part) const => latchedHandlePart(part).bank != LatchedHandleBank.None);
    }

    override string name() const { return "Transform"; }

    // The wrapper is the sole history/payload owner.  Embedded banks receive
    // input state only; in particular they never receive CommandHistory or
    // undo factories, so they cannot accidentally emit a second record.
    override public void setUndoBindings(CommandHistory h,
                                  VertexEditFactory factory,
                                         MorphEditFactory morphFactory = null) {
        super.setUndoBindings(h, factory, morphFactory);
    }

    public struct EmbeddedHistoryBindingState {
        bool canonicalIdentity;
        size_t historyBound;
        size_t pipeHostBound;
    }

    public final EmbeddedHistoryBindingState embeddedHistoryBindingState()
            const nothrow @nogc {
        EmbeddedHistoryBindingState state;
        state.canonicalIdentity = moveSub !is null && rotateSub !is null &&
            scaleSub !is null && moveSub !is rotateSub &&
            moveSub !is scaleSub && rotateSub !is scaleSub;
        alias Names = FieldNameTuple!XfrmTransformTool;
        alias Types = FieldTypeTuple!XfrmTransformTool;
        static foreach (i, T; Types) {
            static if (is(T : TransformTool)) {
                {
                    const candidate = __traits(getMember, this, Names[i]);
                    if (candidate !is null && candidate !is moveSub &&
                        candidate !is rotateSub && candidate !is scaleSub)
                        state.canonicalIdentity = false;
                }
            }
        }
        foreach (candidate; [cast(const TransformTool) moveSub,
                             cast(const TransformTool) rotateSub,
                             cast(const TransformTool) scaleSub]) {
            if (candidate is null) continue;
            if (candidate.hasUndoBindings()) ++state.historyBound;
            if (candidate.hasPipeGizmoHost()) ++state.pipeHostBound;
        }
        return state;
    }

    // Enabled sub-tools in bank order T → R → S, backed by a fixed member
    // buffer — NO GC allocation (several call sites are per-frame: update(),
    // the idle motion/button-up forwards). Single-threaded reuse (the SDL
    // dispatch thread only), so the shared buffer cannot race.
    private TransformTool[3] enabledSubsBuf_;
    private TransformTool[] enabledSubs() {
        size_t n = 0;
        if (flagT) enabledSubsBuf_[n++] = moveSub;
        if (flagR) enabledSubsBuf_[n++] = rotateSub;
        if (flagS) enabledSubsBuf_[n++] = scaleSub;
        return enabledSubsBuf_[0 .. n];
    }

    override void activate() {
        super.activate();   // sets active=true, runs resetTransientState()
        // Bring the composed input banks online.
        foreach (sub; enabledSubs()) sub.activate();
        scaleSub.setInputOptions(negScale);

        // Record+consolidate: a fresh run opens for this tool session. Allocate a
        // run id so this session's gestures are tagged distinctly from any prior
        // session's, and route per-gesture commits through recordInSession while
        // the tool is live — each commitEdit then lands as a tagged in-session
        // entry that consolidate() collapses at a boundary / drop. The wrapper's
        // typed history-intent switch owns every bank's terminal write.
        if (history !is null) history.nextRun();
        recordViaInSession = true;
        currentRunBank     = DragBank.None;
        resetRun();                   // apply-path Phase 2: fresh geometry run (+ P-F frozen frame)
        lastAcenMode       = -1;      // P-C: re-latch the ACEN mode on first poll
        // Task 0791 — the other slot latches re-latch on the first poll too, so
        // arming a tool never reads a slot change that happened while no
        // transform tool was armed as an activation of ITS run.
        lastSlotSigValid = false;
        clearFrame();                 // COMMIT B — fresh session re-derives the basis
    }

    final PreparedXfrmActivationEffect prepareActivate(
            PreparedRecordContext context) {
        const ubyte flags = preparedActivationFlags();
        if (context is null)
            return PreparedXfrmActivationEffect(preparedToolStateOwner, 0,
                flags, false);
        if (!context.ownsHistory(preparedHistoryOwner())) {
            context.discard();
            return PreparedXfrmActivationEffect(preparedToolStateOwner, 0,
                flags, false);
        }
        scope(failure) context.discard();
        auto owner = PreparedXfrmActivationSessionOwner.prepare(this);
        bool ok = owner !is null && context.prepareXfrmActivationPre(owner);
        ulong runId;
        if (ok && context.hasHistory()) {
            runId = context.nextRun();
            ok = runId != 0 && context.markHistoryInstall();
        } else if (ok) {
            ok = context.markNoHistoryInstall();
        }
        if (ok) ok = context.prepareXfrmActivationPost(owner);
        if (!ok) context.discard();
        return PreparedXfrmActivationEffect(preparedToolStateOwner, runId,
            flags, ok);
    }

    /// Prepare only the wrapper-owned reset projection. This performs no live
    /// write and intentionally leaves sub-tool/history preparation to the
    /// activation-session owner that orders them between pre and post install.
    final PreparedXfrmActivationResetImage buildPreparedActivationReset()
            nothrow @nogc {
        PreparedXfrmActivationResetImage image;
        image.base = buildPreparedActivationImage();
        const bool hadRun = runBaselineValid;
        image.run = resyncPreserveDisplayFields ? run : XformState.init;
        image.headlessRotate = resyncPreserveDisplayFields
            ? headlessRotate : Vec3(0, 0, 0);
        image.moveRunKnown = hadRun ? false : moveRec.runKnown;
        image.rotateRunKnown = hadRun ? false : rotateRec.runKnown;
        image.scaleRunKnown = hadRun ? false : scaleRec.runKnown;
        image.priorRotateWasViewRing = hadRun
            ? false : runPriorRotateWasViewRing;
        image.valid = image.base.valid;
        return image;
    }

    /// Phase before enabled sub-tool activation and prepared history.nextRun.
    final void installPreparedActivationResetPre(
            ref PreparedXfrmActivationResetImage image) nothrow @nogc {
        if (!image.valid) return;
        installPreparedActivation(image.base);
        run = image.run;
        headlessRotate = image.headlessRotate;
        activeDrag = null;
        dragBaseline.length = 0;
        moveDragFastPath = false;
        rotDragFastPath = false;
        rotDragAxisIdx = -1;
        scaleDragFastPath = false;
        scaleDragActive = false;
        accumulatedWorldDelta = Vec3(0, 0, 0);
        accumulatedAtDragStart = Vec3(0, 0, 0);
        moveRec.pinKnown = false;
        moveRec.runKnown = image.moveRunKnown;
        rotateRec.runKnown = image.rotateRunKnown;
        scaleRec.runKnown = image.scaleRunKnown;
        runPriorRotateWasViewRing = image.priorRotateWasViewRing;
        lastAppliedGestureMutationVersion = ulong.max;
        armedUndoEpoch = ulong.max;
        refireAnchor.length = 0;
        refirePreValid = false;
        foldSrc_.length = 0;
        itemEditCapturing_ = false;
        itemEditTargets_.length = 0;
        itemEditBefore_.length = 0;
        runBaselineValid = false;
        runFrameValid = false;
        morphRunValid_ = false;
        itemBaselineValid = false;
        runGpuBufferDirty = false;
    }

    /// Phase after sub-tool wiring and prepared history.nextRun. Repeats the
    /// second resetRun projection at its real sequence position, then installs
    /// the session routing/latches and clearFrame result.
    final void installPreparedActivationResetPost(
            ref PreparedXfrmActivationResetImage image) nothrow @nogc {
        if (!image.valid) return;
        recordViaInSession = true;
        currentRunBank = DragBank.None;
        runBaselineValid = false;
        runFrameValid = false;
        morphRunValid_ = false;
        itemBaselineValid = false;
        runGpuBufferDirty = false;
        lastAcenMode = -1;
        lastSlotSigValid = false;
        frame.settled = false;
        frame.valid = false;
        image.clear();
    }

    version(unittest) final void seedPreparedActivationResetForTest(
            bool preserveDisplay, bool hadRun, bool moveRoute,
            bool rotateRoute, bool scaleRoute) {
        seedPreparedActivationForTest();
        resyncPreserveDisplayFields = preserveDisplay;
        run.t = Vec3(7, 8, 9); run.s = Vec3(4, 5, 6);
        run.r[] = 3; headlessRotate = Vec3(10, 11, 12);
        activeDrag = moveSub;
        dragBaseline = [Vec3(1, 2, 3)];
        moveDragFastPath = rotDragFastPath = scaleDragFastPath = true;
        rotDragAxisIdx = 2; scaleDragActive = true;
        accumulatedWorldDelta = Vec3(13, 14, 15);
        accumulatedAtDragStart = Vec3(16, 17, 18);
        moveRec.pinKnown = true;
        moveRec.runKnown = rotateRec.runKnown = scaleRec.runKnown = true;
        runPriorRotateWasViewRing = true;
        lastAppliedGestureMutationVersion = 22; armedUndoEpoch = 23;
        refireAnchor = [Vec3(19, 20, 21)]; refirePreValid = true;
        foldSrc_ = [Vec3(22, 23, 24)];
        itemEditCapturing_ = true;
        itemEditTargets_.length = 1; itemEditBefore_.length = 1;
        runBaselineValid = hadRun; runFrameValid = morphRunValid_ = true;
        itemBaselineValid = runGpuBufferDirty = true;
        recordViaInSession = false;
        currentRunBank = DragBank.Scale;
        lastAcenMode = 4; lastSlotSigValid = true;
        frame.right = Vec3(2, 0, 0); frame.up = Vec3(0, 3, 0);
        frame.axis = Vec3(0, 0, 4); frame.settled = frame.valid = true;
    }

    version(unittest) final void seedPreparedUpdateBoundaryForTest(
            ulong selectionHash, ulong mutationVersion) {
        lastSelectionHash = selectionHash;
        lastMutationVersion = mutationVersion;
        runBaselineValid = true;
        runFrameValid = true;
        morphRunValid_ = true;
        itemBaselineValid = true;
        runGpuBufferDirty = true;
        run.t = Vec3(3, 4, 5);
        headlessRotate = Vec3(6, 7, 8);
        moveRec.runKnown = true;
        rotateRec.runKnown = true;
        scaleRec.runKnown = true;
        runPriorRotateWasViewRing = true;
    }

    version(unittest) final bool preparedUpdateBoundaryInstalledForTest(
            out ulong selectionLatch, out ulong mutationLatch) const {
        selectionLatch = lastSelectionHash;
        mutationLatch = lastMutationVersion;
        return !runBaselineValid && !runFrameValid && !morphRunValid_ &&
            !itemBaselineValid && !runGpuBufferDirty &&
            run == XformState.init && headlessRotate == Vec3(0, 0, 0) &&
            !moveRec.runKnown && !rotateRec.runKnown &&
            !scaleRec.runKnown && !runPriorRotateWasViewRing;
    }

    version(unittest) final bool preparedActivationResetSeedForTest()
            const nothrow @nogc {
        return activeDrag is moveSub && dragBaseline.length == 1 &&
            moveDragFastPath && rotDragFastPath && rotDragAxisIdx == 2 &&
            scaleDragFastPath && scaleDragActive && moveRec.pinKnown &&
            refireAnchor.length == 1 && refirePreValid && foldSrc_.length == 1 &&
            itemEditCapturing_ && itemEditTargets_.length == 1 &&
            itemEditBefore_.length == 1 && lastAcenMode == 4 &&
            lastSlotSigValid && frame.settled && frame.valid;
    }

    version(unittest) final bool preparedActivationResetPreForTest(
            bool preserveDisplay, bool hadRun) const nothrow @nogc {
        float[16] threes; threes[] = 3;
        const bool displayOk = preserveDisplay
            ? run.t == Vec3(7,8,9) && run.s == Vec3(4,5,6) &&
              run.r == threes && headlessRotate == Vec3(10,11,12)
            : run == XformState.init && headlessRotate == Vec3(0,0,0);
        const bool knownOk = hadRun
            ? !moveRec.runKnown && !rotateRec.runKnown &&
              !scaleRec.runKnown && !runPriorRotateWasViewRing
            : moveRec.runKnown && rotateRec.runKnown &&
              scaleRec.runKnown && runPriorRotateWasViewRing;
        return preparedActivationForTest() && displayOk && knownOk &&
            activeDrag is null && dragBaseline.length == 0 &&
            !moveDragFastPath && !rotDragFastPath && rotDragAxisIdx == -1 &&
            !scaleDragFastPath && !scaleDragActive &&
            accumulatedWorldDelta == Vec3(0,0,0) &&
            accumulatedAtDragStart == Vec3(0,0,0) && !moveRec.pinKnown &&
            lastAppliedGestureMutationVersion == ulong.max &&
            armedUndoEpoch == ulong.max && refireAnchor.length == 0 &&
            !refirePreValid && foldSrc_.length == 0 && !itemEditCapturing_ &&
            itemEditTargets_.length == 0 && itemEditBefore_.length == 0 &&
            !runBaselineValid && !runFrameValid && !morphRunValid_ &&
            !itemBaselineValid && !runGpuBufferDirty && lastAcenMode == 4 &&
            lastSlotSigValid && frame.settled && frame.valid;
    }

    version(unittest) final bool preparedActivationResetPostForTest(
            bool moveRoute, bool rotateRoute, bool scaleRoute)
            const nothrow @nogc {
        return recordViaInSession &&
            !moveSub.recordViaInSessionForTest() &&
            !rotateSub.recordViaInSessionForTest() &&
            !scaleSub.recordViaInSessionForTest() &&
            currentRunBank == DragBank.None && !runBaselineValid &&
            !runFrameValid && !morphRunValid_ && !itemBaselineValid &&
            !runGpuBufferDirty && lastAcenMode == -1 && !lastSlotSigValid &&
            !frame.settled && !frame.valid && frame.right == Vec3(2,0,0) &&
            frame.up == Vec3(0,3,0) && frame.axis == Vec3(0,0,4);
    }

    // Wrapper-level transient reset (undo/redo migration P1). Extends the base
    // TransformTool.resetTransientState() with the wrapper-owned headless TRS
    // accumulators and per-drag fast-path state. Shared by activate() and
    // resyncSession() so the two can't drift. Touches only drag-invariant
    // bookkeeping (no open edit exists when resyncSession() runs); the one-time
    // sub-tool activation and owner-provided inputs stay in activate().
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
        editCauseBank            = DragBank.None;
        editCauseProvisional     = false;
        lastValueReplayChannels.length = 0;
        lastValueReplaySource    = ParameterChangeSource.ScriptedValue;
        lastValueReplayValid     = false;
        lastValueReplayCause     = DragBank.None;
        valueReplayFolds         = 0;
        dragBaseline.length       = 0;
        resetRun();                          // apply-path Phase 2: fresh run (+ P-F frozen frame)
        moveDragFastPath          = false;
        rotDragFastPath           = false;
        rotDragAxisIdx            = -1;
        scaleDragFastPath         = false;
        scaleDragActive           = false;
        accumulatedWorldDelta     = Vec3(0, 0, 0);
        accumulatedAtDragStart    = Vec3(0, 0, 0);
        moveRec.pinKnown          = false;
        // In-session falloff re-grade state — no live gesture, no anchor.
        lastAppliedGestureMutationVersion = ulong.max;
        armedUndoEpoch                    = ulong.max;   // task 1906 census
        refireAnchor.length               = 0;
        refirePreValid                    = false;
        // (task 0202) Idle tool should not pin the fold-source scratch buffer
        // between drags; the next drag's first frame re-allocates cold.
        foldSrc_.length                   = 0;
        // Task 0614 Phase 4 — defensive: `deactivate()`'s tool-drop commit
        // (gated on the `editIsOpen()` override above) already clears these
        // via the live projected-close installer before this ever runs in
        // practice; cleared again here so a fresh activate() never inherits
        // a stale open-session flag from any path that reaches
        // resetTransientState() without going through deactivate() first.
        itemEditCapturing_       = false;
        itemEditTargets_.length  = 0;
        itemEditBefore_.length   = 0;
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        bool accepted = prepareEditRecord(context, "Move");
        // TASK 4053 measured what this line does NOT do, and left it alone.
        // The consolidate prepares INTO the history token, and the door below
        // picks `markNoHistoryInstall()` whenever the run recorded no NEW
        // edit — at which point `PreparedRecordContext.install` calls
        // `discardPreparedToken` and this consolidate goes with it, while
        // `deactivate()` consolidates unconditionally. Counting it as a
        // history effect DOES close that gap (it turned
        // `tests/test_rs_insession_cancel.d:517` from "floor=1 now=3" back to
        // green) but it is not this task's to land: the run id it passes is
        // read off the LIVE history while the consolidate runs against the
        // detached image, which is the second half of the same defect. Task
        // 4243 owns both halves together.
        if (context !is null && history !is null)
            context.consolidate(history.currentRunId);
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Xfrm, accepted);
    }

    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        auto effect = prepareDeactivate(context);
        if (context is null) return false;
        const ok = effect.historyAccepted ? context.markHistoryInstall()
                                          : context.markNoHistoryInstall();
        if (!ok) context.discard();
        return ok;
    }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareActivate(context).accepted;
    }

    override bool prepareDoorInitialPose(ref VectorStack vts,
            PreparedRecordContext context, Layer layer,
            ulong threadIdentity, ulong contextIdentity) {
        auto upload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);
        return prepareUpdate(vts, context, layer, upload).accepted;
    }

    final PreparedXfrmEmbeddedDeactivateImage
            buildPreparedEmbeddedDeactivateImage() const nothrow @nogc {
        PreparedXfrmEmbeddedDeactivateImage image;
        // EdgeExtend drives only the banks' gesture-scalar surfaces. The
        // wrapper itself must therefore still be at an idle run boundary;
        // any open wrapper edit/history makes this the standalone product and
        // is deliberately refused here.
        if (history !is null || editIsOpen() || activeDrag !is null ||
            dragBaseline.length != 0 || currentRunBank != DragBank.None ||
            moveDragFastPath || rotDragFastPath || scaleDragFastPath ||
            scaleDragActive || runBaselineValid || runFrameValid ||
            refireAnchor.length != 0 || refirePreValid || foldSrc_.length != 0 ||
            itemEditCapturing_ || itemEditTargets_.length != 0 ||
            itemEditBefore_.length != 0) return image;
        image.wrapper = buildPreparedScalarDeactivateImage();
        image.flagT = flagT; image.flagR = flagR; image.flagS = flagS;
        if (flagT) image.move = moveSub.buildPreparedScalarDeactivateImage();
        if (flagR) image.rotate = rotateSub.buildPreparedScalarDeactivateImage();
        if (flagS) image.scale = scaleSub.buildPreparedEmbeddedDeactivateImage();
        image.expectedRecordViaInSession = recordViaInSession;
        image.valid = image.wrapper.valid && (!flagT || image.move.valid) &&
            (!flagR || image.rotate.valid) && (!flagS || image.scale.valid);
        return image;
    }

    final bool preparedEmbeddedDeactivateMatches(
            in PreparedXfrmEmbeddedDeactivateImage image) const nothrow @nogc {
        return image.valid && history is null && !editIsOpen() &&
            flagT == image.flagT && flagR == image.flagR && flagS == image.flagS &&
            recordViaInSession == image.expectedRecordViaInSession &&
            activeDrag is null && dragBaseline.length == 0 &&
            currentRunBank == DragBank.None && !moveDragFastPath &&
            !rotDragFastPath && !scaleDragFastPath && !scaleDragActive &&
            !runBaselineValid && !runFrameValid && refireAnchor.length == 0 &&
            !refirePreValid && foldSrc_.length == 0 && !itemEditCapturing_ &&
            itemEditTargets_.length == 0 && itemEditBefore_.length == 0 &&
            preparedScalarDeactivateMatches(image.wrapper) &&
            (!flagT || moveSub.preparedScalarDeactivateMatches(image.move)) &&
            (!flagR || rotateSub.preparedScalarDeactivateMatches(image.rotate)) &&
            (!flagS || scaleSub.preparedEmbeddedDeactivateMatches(image.scale));
    }

    final void installPreparedEmbeddedDeactivate(
            ref PreparedXfrmEmbeddedDeactivateImage image) nothrow @nogc {
        if (!image.valid) return;
        if (image.flagT) moveSub.installPreparedScalarDeactivate(image.move);
        if (image.flagR) rotateSub.installPreparedScalarDeactivate(image.rotate);
        if (image.flagS) scaleSub.installPreparedEmbeddedDeactivate(image.scale);
        recordViaInSession = false;
        currentRunBank = DragBank.None;
        lastAppliedGestureMutationVersion = ulong.max;
        armedUndoEpoch = ulong.max;
        installPreparedScalarDeactivate(image.wrapper);
        image.clear();
    }

    override void deactivate() {
        // Wrapper-owned edit session: commit any pending edit BEFORE
        // forwarding to the sub-tools (they only reset input/handler state;
        // the edit baseline and bank provenance live on the wrapper).
        if (editIsOpen())
            commitEdit("Move");
        foreach (sub; enabledSubs()) sub.deactivate();
        // Tool drop (record+consolidate): consolidate the FINAL run's in-session
        // tail into one surviving entry. A clean multi-gesture run therefore
        // collapses to ONE undo entry at the drop (one post-drop Ctrl+Z reverts
        // the whole run); a session that already consolidated at a boundary
        // leaves that surviving entry untouched (no-op gather). Done AFTER the
        // sub-tool deactivation so the final consolidate sees the wrapper's
        // whole tagged tail. Stop the legacy routing flag afterward.
        if (history !is null) history.consolidate(history.currentRunId);
        recordViaInSession   = false;
        currentRunBank       = DragBank.None;
        // Tool drop: no live gesture, no re-grade anchor carries to the next
        // activation (resetTransientState also clears these on (re)activate).
        lastAppliedGestureMutationVersion = ulong.max;
        armedUndoEpoch                    = ulong.max;   // task 1906 census
        refireAnchor.length               = 0;
        refirePreValid                    = false;
        // (task 0202) Release the fold-source scratch buffer on tool drop too,
        // mirroring refireAnchor above.
        foldSrc_.length                   = 0;
        super.deactivate();
        activeDrag           = null;
        dragBaseline.length  = 0;
        resetRun();                     // apply-path Phase 2: tool drop = run boundary (+ P-F frozen frame)
        moveDragFastPath     = false;
    }

    override void update(ref VectorStack vts) {
        if (!active) return;

        // Task 0614 Phase 3 — refresh the cached subject type HERE, the
        // frame's FIRST tick of this tool, not only in `draw()` further
        // down.
        //
        // Why it cannot stay draw-only. `update()` and `draw()` are two
        // different phases of one frame: app.d ticks the tool right after the
        // event drain, then builds the whole ImGui panel section, and only
        // then runs the N-cell FBO loop that calls `draw()`. The gizmo pose
        // (`setSharedGizmoPose(queryActionCenter(vts), ...)`, the bottom of
        // this method) was already written in the FIRST phase while
        // `cachedSubjType_` was still written in the SECOND — so for the
        // whole ImGui section the tool's two resident records of "what am I
        // targeting" disagreed: the gizmo sat on the item's world pivot while
        // `cachedSubjType_` still held the constructor default `Vertex`
        // (every `tool.set` builds a FRESH tool — the arm door replaces the
        // old one — so the default is what a newly-armed tool starts from).
        //
        // That is observable, and it was measured: GET /api/tool/state is a
        // DIRECT read of these fields on the HTTP thread (http_providers.d's
        // setToolStateDataProvider — no main-thread marshalling, by design,
        // "because it reads resident per-tool fields"), so a read landing in
        // that window answers `pivot` = the item pivot and `subject` =
        // "component" in ONE response — a self-contradicting snapshot. That
        // is a CI-only failure of tests/test_item_panel_gizmo_sync.d's case 2
        // on a loaded host, reproduced 15/15 by widening the update→draw gap.
        //
        // The packet is the same one `draw()` reads (app.d's `buildToolVts`
        // publishes `currentSelType(selTypeOrder)`), and panels.d guarantees
        // `update()` has already run once this frame before ANY cell's
        // `draw()` — so this refresh is never later than the draw-site one,
        // only earlier. The draw-site refresh below stays: it is `!visualOnly`
        // gated for the multi-cell replica rule and is what keeps the cache
        // honest if a future caller draws without ticking.
        {
            import toolpipe.packets : SubjectPacket;
            if (auto sp = vts.get!SubjectPacket()) cachedSubjType_ = sp.selType;
        }

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
            // recorded remainder (1906 §3.6): `mutationVersion` owns the
            // compare below, via `curMutVer` — same argument as row 21, plan
            // §2.3/§2.3.1. A GESTURE BOUNDARY, not a cache: it asks whether a
            // FOREIGN edit landed between two of the user's gestures. The
            // counter is (§2.2's law, cage carve-out aside) blind to the
            // transform kernels' own output; `g_geomEpochs` is NOT, because
            // the drag delivers `publishChange(Position)` version-silently
            // (xfrm_apply.d :551/:971, transform.d :741) and Position is in
            // that mask. Re-keyed on an epoch this guard would fire on the
            // tool's OWN drag at the first update() after mouse-up — commit
            // the edit, split the run, cancel the re-grade §2.3 protects.
            ulong curHash   = computeSelectionHash();
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
                    commitOpenEdit(TransformHistoryIntent.RunClose);
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
                    closeRunBoundary();
                    // A falloff change after a selection/mutation boundary
                    // cannot re-grade the just-closed run.
                    invalidateRunRefireAnchor();
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
                // is seeded to ulong.max by activate() / a session re-open as the
                // "not yet synced" sentinel (NOT a real selection); the very next
                // update() then sees curHash != ulong.max and would spuriously wipe
                // the soft pin. After an in-session redo this is the bug: the Move
                // apply hook restores the settled soft pin, then this guard frame
                // (running with lastSelectionHash == ulong.max because the session
                // re-opened) re-cleared it, snapping the gizmo back to the weighted
                // centroid. Mirror the ACEN-mode poll's first-poll latch (below):
                // when the prior hash is the sentinel, adopt curHash WITHOUT firing
                // the soft-pin clear. A real selection change (sentinel already
                // replaced by a concrete hash) still clears, as before.
                if (lastSelectionHash != ulong.max
                 && curHash != lastSelectionHash) {
                    clearAcenSoftPlaced();
                    clearFrame();       // COMMIT B — one lifecycle with the center pin
                }
                lastSelectionHash   = curHash;
                lastMutationVersion = curMutVer;
            }
        }

        // Pipe-slot ACTIVATION check (task 0791; grew out of P-C's ACEN-mode
        // poll) — the law lives on `endHeldRunIfSlotActivated` below. This site
        // catches the routes that publish no stage-config signal at all (the
        // `actr.*` side-effect commands record nothing, so they never trip the
        // command-history foreign-record guard the selection/mutation boundary
        // above relies on); every `tool.pipe.attr` reaches the same check
        // synchronously through EditSession.onStageConfigChanged.
        //
        // It runs BEFORE the re-grade block and before any mouse-down is
        // processed this frame (update() runs before event dispatch), so no
        // gesture lands in the wrong run — the check always precedes the next
        // gesture (invariant).
        //
        // Skipped during a live drag (dragAxis frozen): a slot read mid-drag is
        // the drag's own state, not a user action.
        endHeldRunIfSlotActivated();     // no-ops mid-drag, see the method

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
        DragBank regradeBank = editIsOpen() ? editCauseBank : currentRunBank;
        if (activeDrag is null
            && dragBaseline.length == mesh.vertices.length
            && (regradeBank == DragBank.Move ||
                regradeBank == DragBank.Rotate ||
                regradeBank == DragBank.Scale)
            && bankIsNonIdentity(regradeBank)) {
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
                             samplePipeFromBaselineForRegrade(regradeBank));
                    settleRotateRegradeCenter(regradeBank);
                    needsGpuUpdate = true;
                }
            } else if (history !is null
                    && history.runOpen()
                    && (currentRunBank == DragBank.Move ||
                        currentRunBank == DragBank.Rotate ||
                        currentRunBank == DragBank.Scale)
                    && regradeStampCurrent()) {
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
                    applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                             samplePipeFromBaselineForRegrade(regradeBank));
                    settleRotateRegradeCenter(regradeBank);
                    Vec3[] after = mesh.vertices.dup;

                    // Index set = the full vertex range; pass an EMPTY idx so the
                    // helper iterates the whole range directly (S1 economy — no
                    // materialised identity array). The helper diffs against the
                    // anchor and keeps only moved verts (the symmetry mirror set
                    // is covered by the whole-mesh dragBaseline). The falloff
                    // support can be the whole mesh, so a full-range pass is the
                    // safe superset.
                    recordPipeRefire(anchor, after, null, currentRunBank,
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
        immutable Vec3 actionCenter = queryActionCenter(vts);
        if (flagT)
            moveSub.updateInput(actionCenter, editIsOpen());
        if (flagR)
            rotateSub.updateInput(actionCenter, editIsOpen());
        if (flagS) {
            scaleSub.setInputOptions(negScale);
            scaleSub.updateInput(actionCenter, editIsOpen());
        }
        if (activeDrag is moveSub)
            setSharedGizmoPose(moveSub.handler.center, vts);
        else if (activeDrag is rotateSub)
            setSharedGizmoPose(rotateSub.handler.center, vts);
        else if (activeDrag is scaleSub)
            setSharedGizmoPose(scaleSub.handler.center, vts);
        else
            setSharedGizmoPose(actionCenter, vts);
        syncGpuMatrix();
    }

    final PreparedXfrmUpdateTailImage buildPreparedUpdateTail(
            ref VectorStack vts, bool forceClearNeedsGpu = false) {
        PreparedXfrmUpdateTailImage image;
        if (!active) return image;
        image.expectedSubject = cachedSubjType_;
        image.nextSubject = cachedSubjType_;
        import toolpipe.packets : SubjectPacket;
        if (auto sp = vts.get!SubjectPacket()) image.nextSubject = sp.selType;
        image.expectedActiveDrag = activeDrag;
        image.expectedMove = moveSub;
        image.expectedRotate = rotateSub;
        image.expectedScale = scaleSub;
        image.expectedGpu = gpu;
        image.expectedNeedsGpu = needsGpuUpdate;
        image.clearNeedsGpu = needsGpuUpdate || forceClearNeedsGpu;
        image.flags = cast(ubyte)((flagT ? 1 : 0) | (flagR ? 2 : 0) |
                                 (flagS ? 4 : 0));
        if (activeDrag is moveSub) image.center = moveSub.handler.center;
        else if (activeDrag is rotateSub) image.center = rotateSub.handler.center;
        else if (activeDrag is scaleSub) image.center = scaleSub.handler.center;
        else image.center = queryActionCenter(vts);
        renderBasis(image.basisX, image.basisY, image.basisZ, vts);
        image.expectedGpuMatrix = gpuMatrix;
        image.nextGpuMatrix = projectedGpuMatrix(image.writeGpuMatrix);
        image.valid = true;
        return image;
    }

    final PreparedXfrmUpdatePreProjection projectPreparedUpdatePre(
            ref VectorStack vts) {
        PreparedXfrmUpdatePreProjection p;
        if (!active) return p;
        p.valid = true;
        p.subject = cachedSubjType_;
        import toolpipe.packets : SubjectPacket;
        if (auto sp = vts.get!SubjectPacket()) p.subject = sp.selType;
        p.selectionHash = computeSelectionHash();
        // recorded remainder (1906 §3.6): preparation-time twin of this
        // root's legacy foreign-edit boundary. Position bus epochs include
        // this tool's own version-silent fold and would split its run; the
        // structure-owned mutationVersion is deliberately blind to that fold.
        p.mutationVersion = mesh.mutationVersion;
        p.selectionChanged = p.selectionHash != lastSelectionHash;
        p.mutationChanged = p.mutationVersion != lastMutationVersion;
        p.selectionBoundary = activeDrag is null &&
            (p.selectionChanged || p.mutationChanged);
        p.slotSignature = slotStateSignature();
        if (auto ac = activeAcenStage()) p.acenEpoch = ac.slotEpoch;
        p.slotBoundary = activeDrag is null && lastSlotSigValid &&
            p.slotSignature != lastSlotSig;
        p.pivotMoved = p.slotBoundary && p.acenEpoch != lastAcenEpoch;
        p.editOpen = editIsOpen();
        auto regradeBank = p.editOpen ? editCauseBank : currentRunBank;
        p.regradeBank = cast(ubyte)regradeBank;
        p.bankHeld = dragBaseline.length == mesh.vertices.length &&
            (regradeBank == DragBank.Move ||
             regradeBank == DragBank.Rotate ||
             regradeBank == DragBank.Scale) &&
            bankIsNonIdentity(regradeBank);
        p.liveFalloff = currentFalloff(vts).ownedDup();
        p.liveSnap = currentSnap(vts);
        p.liveSymmetry = currentSymmetry(vts).ownedDup();
        p.packetChanged = !falloffPacketsEqual(p.liveFalloff, dragFalloff) ||
            !snapPacketsEqual(p.liveSnap, dragSnap) ||
            !symmetryPacketsEqual(p.liveSymmetry, dragSymmetry);
        if (!p.selectionBoundary && !p.slotBoundary && activeDrag is null &&
            p.bankHeld && p.packetChanged) {
            p.panelRegrade = p.editOpen;
            p.wrapperRegrade = !p.editOpen && history !is null &&
                history.runOpen() && regradeStampCurrent();
        }
        return p;
    }

    final PreparedXfrmSlotPollImage buildPreparedSlotPoll(
            ref const PreparedXfrmUpdatePreProjection p) const nothrow @nogc {
        PreparedXfrmSlotPollImage image;
        if (!p.valid) return image;
        image.expectedSignature = lastSlotSig;
        image.expectedAcenEpoch = lastAcenEpoch;
        image.expectedValid = lastSlotSigValid;
        image.nextSignature = lastSlotSig;
        image.nextAcenEpoch = lastAcenEpoch;
        image.nextValid = lastSlotSigValid;
        if (activeDrag is null) {
            if (!lastSlotSigValid || p.slotBoundary) {
                image.nextValid = true;
                image.nextSignature = p.slotSignature;
                image.nextAcenEpoch = p.acenEpoch;
            }
            image.boundary = p.slotBoundary;
            image.pivotMoved = p.pivotMoved;
        }
        image.valid = true;
        return image;
    }

    final bool preparedSlotPollMatches(
            ref const PreparedXfrmSlotPollImage image) const nothrow @nogc {
        return image.valid && lastSlotSig == image.expectedSignature &&
            lastAcenEpoch == image.expectedAcenEpoch &&
            lastSlotSigValid == image.expectedValid;
    }

    final void installPreparedSlotPoll(ref PreparedXfrmSlotPollImage image)
            nothrow @nogc {
        if (!image.valid) return;
        lastSlotSig = image.nextSignature;
        lastAcenEpoch = image.nextAcenEpoch;
        lastSlotSigValid = image.nextValid;
        image.clear();
    }

    final PreparedXfrmUpdateBoundaryImage buildPreparedUpdateBoundary(
            ref const PreparedXfrmUpdatePreProjection p) const {
        PreparedXfrmUpdateBoundaryImage image;
        if (!p.valid || (!p.selectionBoundary && !p.slotBoundary)) return image;
        image.expectedSelectionHash = lastSelectionHash;
        image.expectedMutationVersion = lastMutationVersion;
        image.nextSelectionHash = p.selectionBoundary
            ? p.selectionHash : lastSelectionHash;
        image.nextMutationVersion = p.selectionBoundary
            ? p.mutationVersion : lastMutationVersion;
        image.expectedGestureMutation = lastAppliedGestureMutationVersion;
        image.expectedUndoEpoch = armedUndoEpoch;
        image.expectedRefireAnchor = refireAnchor.dup;
        image.expectedRefirePreValid = refirePreValid;
        image.expectedRun = run;
        image.expectedHeadlessRotate = headlessRotate;
        image.expectedFrame = frame;
        image.expectedRunBaselineValid = runBaselineValid;
        image.expectedRunFrameValid = runFrameValid;
        image.expectedMorphRunValid = morphRunValid_;
        image.expectedItemBaselineValid = itemBaselineValid;
        image.expectedRunGpuBufferDirty = runGpuBufferDirty;
        image.expectedMoveRunKnown = moveRec.runKnown;
        image.expectedRotateRunKnown = rotateRec.runKnown;
        image.expectedScaleRunKnown = scaleRec.runKnown;
        image.expectedPriorRotateWasViewRing = runPriorRotateWasViewRing;
        image.expectedRunBank = cast(ubyte)currentRunBank;
        image.selectionBoundary = p.selectionBoundary;
        image.slotBoundary = p.slotBoundary;
        image.invalidateRefire = history !is null && history.runOpen();
        image.hadRun = runBaselineValid;
        image.expectedAcen = activeAcenStage();
        if (image.expectedAcen !is null)
            image.expectedSoftPin = image.expectedAcen.currentSoftPin();
        image.clearSoft =
            (p.selectionBoundary && lastSelectionHash != ulong.max &&
                p.selectionChanged) ||
            (p.slotBoundary && p.pivotMoved);
        image.valid = true;
        return image;
    }

    final bool preparedUpdateBoundaryMatches(
            ref PreparedXfrmUpdateBoundaryImage image) const
            nothrow @nogc {
        return image.valid &&
            lastSelectionHash == image.expectedSelectionHash &&
            // recorded remainder (1906 §3.6): validation half of the
            // conversion-only foreign-structure boundary image above. It
            // retires with that dormant twin at unified cutover.
            lastMutationVersion == image.expectedMutationVersion &&
            lastAppliedGestureMutationVersion == image.expectedGestureMutation &&
            armedUndoEpoch == image.expectedUndoEpoch &&
            refireAnchor == image.expectedRefireAnchor &&
            refirePreValid == image.expectedRefirePreValid &&
            run == image.expectedRun && headlessRotate == image.expectedHeadlessRotate &&
            frame == image.expectedFrame &&
            runBaselineValid == image.expectedRunBaselineValid &&
            runFrameValid == image.expectedRunFrameValid &&
            morphRunValid_ == image.expectedMorphRunValid &&
            itemBaselineValid == image.expectedItemBaselineValid &&
            runGpuBufferDirty == image.expectedRunGpuBufferDirty &&
            moveRec.runKnown == image.expectedMoveRunKnown &&
            rotateRec.runKnown == image.expectedRotateRunKnown &&
            scaleRec.runKnown == image.expectedScaleRunKnown &&
            runPriorRotateWasViewRing == image.expectedPriorRotateWasViewRing &&
            cast(ubyte)currentRunBank == image.expectedRunBank &&
            ((g_pipeCtx is null && image.expectedAcen is null) ||
             (g_pipeCtx !is null &&
              (cast(Pipeline)g_pipeCtx.pipeline).ownsTaskStage(
                  TaskCode.Acen, image.expectedAcen))) &&
            (image.expectedAcen is null ||
                image.expectedAcen.preparedSoftPinMatches(image.expectedSoftPin));
    }

    final void installPreparedUpdateBoundary(
            ref PreparedXfrmUpdateBoundaryImage image) nothrow {
        if (!image.valid) return;
        lastSelectionHash = image.nextSelectionHash;
        lastMutationVersion = image.nextMutationVersion;
        if (image.invalidateRefire) {
            currentRunBank = DragBank.None;
            lastAppliedGestureMutationVersion = ulong.max;
            armedUndoEpoch = ulong.max;
            refireAnchor = null;
            refirePreValid = false;
        }
        runBaselineValid = false;
        runFrameValid = false;
        morphRunValid_ = false;
        itemBaselineValid = false;
        runGpuBufferDirty = false;
        if (image.hadRun) {
            if (!resyncPreserveDisplayFields) {
                run = XformState.init;
                headlessRotate = Vec3(0, 0, 0);
            }
            moveRec.runKnown = false;
            rotateRec.runKnown = false;
            scaleRec.runKnown = false;
            runPriorRotateWasViewRing = false;
        }
        if (image.clearSoft) {
            if (image.expectedAcen !is null)
                image.expectedAcen.installPreparedClearSoftPlaced();
            frame.settled = false;
            frame.valid = false;
        }
        image.clear();
    }

    final PreparedXfrmEditCloseImage buildPreparedUpdateEditClose(
            PreparedRecordContext context,
            bool useItemSubjectOverride = false,
            bool itemSubjectOverride = false) {
        const itemSubject = useItemSubjectOverride
            ? itemSubjectOverride : itemSubjectActive();
        auto projection = projectPreparedOwnedEditClose(
            editCauseBank, itemSubject);
        if (!projection.valid) return PreparedXfrmEditCloseImage.init;
        if (!prepareOwnedEditClose(projection, context,
                                   TransformHistoryIntent.RunClose))
            return PreparedXfrmEditCloseImage.init;
        return projection.state;
    }

    final bool preparedUpdateEditCloseMatches(
            ref const PreparedXfrmEditCloseImage image) const nothrow @nogc {
        return image.valid && cachedSubjType_ == image.expectedSubject &&
            cast(ubyte) editCauseBank == image.expectedBank &&
            preparedEditCloseMatches(image.vertex) &&
            preparedItemEditCloseMatches(image.item) &&
            (!image.discardAcenSnapshot ||
                (((g_pipeCtx is null && image.expectedAcen is null) ||
                  (g_pipeCtx !is null &&
                   (cast(Pipeline)g_pipeCtx.pipeline).ownsTaskStage(
                       TaskCode.Acen,
                       cast(ActionCenterStage)image.expectedAcen))) &&
                 (image.expectedAcen is null ||
                    image.expectedAcen.projectedEditCloseMatches(
                        image.expectedUserPin, image.expectedSoftPin,
                        image.expectedCancelFrozen)))) &&
            (!image.installCommitState ||
                (pendingMoveSoftPin == image.expectedPendingSoft &&
                 (!image.expectedPendingSoft ||
                    pendingMoveSoftCenter == image.expectedPendingCenter) &&
                 preparedGestureRecordMatches(image) &&
                 falloffPacketsEqual(dragFalloff,
                                     image.expectedDragFalloff)));
    }

    private bool preparedGestureRecordMatches(
            ref const PreparedXfrmEditCloseImage image) const
            pure nothrow @nogc {
        const bank = cast(DragBank)image.expectedBank;
        if (bank == DragBank.Move)
            return moveRec.pinKnown == image.expectedPinKnown &&
                   moveRec.runKnown == image.expectedRunKnown;
        if (bank == DragBank.Rotate)
            return rotateRec.pinKnown == image.expectedPinKnown &&
                   rotateRec.runKnown == image.expectedRunKnown;
        if (bank == DragBank.Scale)
            return scaleRec.pinKnown == image.expectedPinKnown &&
                   scaleRec.runKnown == image.expectedRunKnown;
        return false;
    }

    final void installPreparedUpdateEditClose(
            ref PreparedXfrmEditCloseImage image) nothrow @nogc {
        if (!image.valid) return;
        if (image.discardAcenSnapshot && image.expectedAcen !is null)
            image.expectedAcen.installProjectedEditClose(
                image.nextSoftPin, image.settleSoftPin);
        if (image.installCommitState) {
            dragFalloff = image.nextDragFalloff;
            if (image.consumeGestureState) {
                pendingMoveSoftPin = false;
                const bank = cast(DragBank)image.expectedBank;
                if (bank == DragBank.Move) {
                    moveRec.pinKnown = false; moveRec.runKnown = false;
                } else if (bank == DragBank.Rotate) {
                    rotateRec.pinKnown = false; rotateRec.runKnown = false;
                } else if (bank == DragBank.Scale) {
                    scaleRec.pinKnown = false; scaleRec.runKnown = false;
                }
            }
        }
        if (image.closeWrapper) {
            installPreparedEditClose(image.vertex);
            installPreparedItemEditClose(image.item);
        }
        editCauseBank = DragBank.None;
        editCauseProvisional = false;
        image.clear();
    }

    final bool preparedUpdateTailMatches(
            ref const PreparedXfrmUpdateTailImage image) const nothrow @nogc {
        return image.valid && active && cachedSubjType_ == image.expectedSubject &&
            activeDrag is image.expectedActiveDrag && moveSub is image.expectedMove &&
            rotateSub is image.expectedRotate && scaleSub is image.expectedScale &&
            gpu is image.expectedGpu && needsGpuUpdate == image.expectedNeedsGpu &&
            cast(ubyte)((flagT ? 1 : 0) | (flagR ? 2 : 0) | (flagS ? 4 : 0)) ==
                image.flags && gpuMatrix == image.expectedGpuMatrix;
    }

    final void installPreparedUpdateTail(ref PreparedXfrmUpdateTailImage image)
            nothrow @nogc {
        if (!image.valid) return;
        cachedSubjType_ = image.nextSubject;
        installPreparedSharedGizmoPose(image.center, image.basisX,
                                       image.basisY, image.basisZ);
        if (image.writeGpuMatrix) gpuMatrix = image.nextGpuMatrix;
        if (image.clearNeedsGpu) needsGpuUpdate = false;
        image.clear();
    }

    /// Prepared composition of the already-closed T/R/S update products and
    /// the wrapper tail. The wrapper pre-phase (selection/run boundary and
    /// wrapper replay) is deliberately a separate owner so its history must be
    /// decided before this method is used by the complete root producer.
    final PreparedXfrmUpdateEffect prepareUpdateBanksAndTail(
            ref VectorStack vts, PreparedRecordContext context, Layer layer) {
        if (context is null) return PreparedXfrmUpdateEffect(
            preparedToolStateOwner, PreparedXfrmUpdateKind.None, false);
        scope(failure) context.discard();
        if (!active) {
            bool idleOk = context.markNoHistoryInstall();
            if (!idleOk) context.discard();
            return PreparedXfrmUpdateEffect(preparedToolStateOwner,
                PreparedXfrmUpdateKind.InactiveNoop, idleOk);
        }

        PreparedMoveUpdateOwner moveOwner;
        PreparedRotateUpdateOwner rotateOwner;
        PreparedScaleUpdateOwner scaleOwner;
        immutable Vec3 actionCenter = queryActionCenter(vts);
        if (flagT) moveOwner = PreparedMoveUpdateOwner.prepare(
            moveSub, editIsOpen(), actionCenter);
        if (flagR) rotateOwner = PreparedRotateUpdateOwner.prepare(
            rotateSub, layer, editIsOpen(), actionCenter);
        if (flagS) scaleOwner = PreparedScaleUpdateOwner.prepare(
            scaleSub, layer, editIsOpen(), actionCenter);
        auto tailOwner = PreparedXfrmUpdateTailOwner.prepare(this, vts);

        bool ok = (!flagT || moveOwner !is null) &&
                  (!flagR || rotateOwner !is null) &&
                  (!flagS || scaleOwner !is null) && tailOwner !is null;
        if (ok) ok = context.markNoHistoryInstall();
        if (ok && flagT) ok = context.prepareMoveUpdate(moveOwner);
        if (ok && flagR) ok = context.prepareRotateUpdate(rotateOwner);
        if (ok && flagS) ok = context.prepareScaleUpdate(scaleOwner);
        if (ok) ok = context.prepareXfrmUpdateTail(tailOwner);
        if (!ok) context.discard();
        return PreparedXfrmUpdateEffect(preparedToolStateOwner,
            PreparedXfrmUpdateKind.Active, ok);
    }

    /// Complete dormant root for the shipped `update` order. The context owns
    /// one history image and every state/resource effect is enlisted in legacy
    /// sequence; unified cutover therefore changes only the door.
    final PreparedXfrmUpdateEffect prepareUpdate(ref VectorStack vts,
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner wrapperUpload) {
        if (context is null || layer is null ||
            preparedMeshForUpdate() !is &layer.meshRef())
            return PreparedXfrmUpdateEffect(preparedToolStateOwner,
                PreparedXfrmUpdateKind.None, false);
        scope(failure) context.discard();
        if (!active) {
            bool idleOk = context.markNoHistoryInstall();
            if (!idleOk) context.discard();
            return PreparedXfrmUpdateEffect(preparedToolStateOwner,
                PreparedXfrmUpdateKind.InactiveNoop, idleOk);
        }

        auto projection = projectPreparedUpdatePre(vts);
        const bool boundary = projection.selectionBoundary ||
                              projection.slotBoundary;
        PreparedXfrmUpdateEditCloseOwner editClose;
        PreparedXfrmUpdateBoundaryOwner boundaryOwner;
        if (boundary) {
            editClose = PreparedXfrmUpdateEditCloseOwner.prepare(
                this, context, true, projection.subject == SelType.Item);
            boundaryOwner = PreparedXfrmUpdateBoundaryOwner.prepare(
                this, projection);
        }
        auto slotOwner = PreparedXfrmSlotPollOwner.prepare(this, projection);
        PreparedXfrmReplayOwner replay;
        if (projection.panelRegrade || projection.wrapperRegrade)
            replay = PreparedXfrmReplayOwner.prepare(
                this, layer, projection, context);

        PreparedMoveUpdateOwner moveOwner;
        PreparedRotateUpdateOwner rotateOwner;
        PreparedScaleUpdateOwner scaleOwner;
        immutable Vec3 actionCenter = queryActionCenter(vts);
        if (flagT) moveOwner = PreparedMoveUpdateOwner.prepare(
            moveSub, editIsOpen(), actionCenter);
        if (flagR) rotateOwner = PreparedRotateUpdateOwner.prepare(
            rotateSub, layer, editIsOpen(), actionCenter);
        if (flagS) scaleOwner = PreparedScaleUpdateOwner.prepare(
            scaleSub, layer, editIsOpen(), actionCenter);
        auto tailOwner = PreparedXfrmUpdateTailOwner.prepare(
            this, vts, replay !is null);

        bool ok = projection.valid && slotOwner !is null && tailOwner !is null &&
            (!boundary || (editClose !is null && boundaryOwner !is null)) &&
            (!(projection.panelRegrade || projection.wrapperRegrade) ||
                replay !is null) &&
            (!flagT || moveOwner !is null) &&
            (!flagR || rotateOwner !is null) &&
            (!flagS || scaleOwner !is null);
        bool hasHistory = (editClose !is null && editClose.historyPrepared()) ||
            (replay !is null && replay.historyPrepared());
        if (ok && boundaryOwner !is null && boundaryOwner.closesRun()) {
            auto consolidated = context.consolidate(history.currentRunId);
            ok = consolidated.accepted && context.nextRun() != 0;
            hasHistory = hasHistory || ok;
        }
        if (ok) ok = hasHistory ? context.markHistoryInstall()
                                : context.markNoHistoryInstall();
        if (ok && editClose !is null)
            ok = context.prepareXfrmUpdateEditClose(editClose);
        if (ok && boundaryOwner !is null)
            ok = context.prepareXfrmUpdateBoundary(boundaryOwner);
        if (ok) ok = context.prepareXfrmSlotPoll(slotOwner);
        if (ok && replay !is null && replay.meshPrepared()) {
            ok = replay.deliveryFlags() != 0 &&
                context.prepareStampedMeshImage(layer, replay.candidate(),
                    replay.deliveryFlags(), replay.deliveryDomains());
        }
        if (ok && replay !is null)
            ok = context.prepareXfrmReplay(replay);

        // Wrapper upload precedes the sub-tool updates. Item re-grade has no
        // vertex upload; tail still clears its deferred flag exactly once.
        if (ok && ((needsGpuUpdate && vertexProcessCount > 0) ||
                   (replay !is null && replay.wantsWrapperUpload()))) {
            if (gpu is null)
                ok = false;
            else if (gpu.suppressCageUpload) {
                if (replay !is null && replay.meshPrepared())
                    ok = context.preparePositionCommitOnEnlisted(layer);
                else
                    ok = context.preparePositionCommit(layer);
            } else if (wrapperUpload is null || !wrapperUpload.owns(gpu))
                ok = false;
            else if (replay !is null && replay.meshPrepared())
                ok = context.prepareUpload(wrapperUpload,
                                           replay.candidate());
            else
                ok = context.prepareUpload(wrapperUpload, layer.meshRef());
        }
        if (ok && flagT) ok = context.prepareMoveUpdate(moveOwner);
        if (ok && flagR) ok = context.prepareRotateUpdate(rotateOwner);
        if (ok && flagS) ok = context.prepareScaleUpdate(scaleOwner);
        if (ok) ok = context.prepareXfrmUpdateTail(tailOwner);
        if (!ok) context.discard();
        return PreparedXfrmUpdateEffect(preparedToolStateOwner,
            PreparedXfrmUpdateKind.Active, ok);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        if (!active) return;
        // Task 0206: `cachedVp` is read by every event handler (screen→world
        // drag math, hit-test) for THIS tool. Only the interactive (owner)
        // cell's draw may pin it — a Quad/Split "visual" replica draws under
        // a FOREIGN cell's projection and must not clobber it. See
        // Tool.draw's doc comment (source/tool.d) for the full invariant.
        if (!visualOnly) cachedVp = vp;

        // Task 0614 Phase 3 — refresh the cached subject type from THIS
        // draw's own vts (the render-path packet app.d's buildToolVts
        // publishes), so a render-only frame (no mouse event in between,
        // e.g. after a layer-panel click) still sees the current subject
        // for the centre-box visibility decision below. Mirrors
        // `syncInputViewport`'s cache but for the draw entry point, which
        // has no SDL event to gate a call to that method on. Gated on
        // `!visualOnly` for the SAME reason `cachedVp` is, right above: a
        // foreign-cell visual replica must not clobber the owner cell's
        // cached state.
        if (!visualOnly) {
            if (auto sp = vts.get!SubjectPacket()) cachedSubjType_ = sp.selType;
        }

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
        //
        // Task 0206: the WHOLE block is gated on `!visualOnly`, not just
        // `begin()`/`add()` — `toolHandles.update(hmx, hmy, vp)` hit-tests
        // under `vp` using the ACTIVE mouse coords (`queryMouse`), which are
        // for the OWNER cell. Running it under a foreign cell's `vp` would
        // resolve a WRONG hot/captured part and stomp the shared
        // `ToolHandles.hot` / `Handler.state` that the real (owner-cell)
        // arbiter pass just set — corrupting the highlight (and, if a haul
        // is in flight, the drag) for every cell. Skipping the whole block
        // under `visualOnly` leaves the resident registration/hot-state from
        // the owner cell's most recent real pass untouched; the gizmo banks
        // below still render (world-derived, reprojected under `vp`), so the
        // SAME hot part highlights in every cell (reference-faithful: Test only
        // in the active cell, Draw — and the persistent hot state — in all).
        if (!visualOnly) {
            toolHandles.begin();
            if (fp.enabled && pipeGizmoHost !is null) pipeGizmoHost.registerInto(toolHandles, fp);
            registerGizmoHandles(toolHandles);
            // Task 0212: refresh OWNER-cell hit geometry (see
            // refreshBankGeometry's doc comment) BEFORE the Test pass below
            // (`toolHandles.update`) — this is the fix.
            refreshBankGeometry(vp);
            if (fp.enabled && pipeGizmoHost !is null) pipeGizmoHost.syncGeometry(vp, fp);
            // Capture precedence: a live falloff-handle drag wins; else the
            // active gizmo bank's dragAxis names the hauled part.
            //
            // THE SCALE BANK USED TO CALL `suppress()` HERE, and that is why a
            // grabbed scale handle went DARK at the moment you grabbed it. The
            // colour law was reached and nothing bypassed it — it was fed the
            // wrong input: `suppress()` clears `hot` and calls
            // `setEngaged(false)` on EVERY registered handle, so the one part
            // that should have been `grabbed` could not reach that state at
            // all. The handle lit under the pointer and then reverted on press,
            // which is a non-monotonic cue the law allows for exactly one part
            // (the plane ring, where it is measured) and not for an axis.
            // Measured for this bank: its grabbed state is the active colour,
            // the same as move and rotate. So this is now the same `setHaul`
            // the other two banks use.
            //
            // `PLANE_DRAG_AXIS` is the off-handle plane drag — a gesture that
            // grabs no registered handle — so it stays hauling nothing rather
            // than naming a part id that was never registered.
            if      (pipeGizmoHost !is null && pipeGizmoHost.isDragging())  toolHandles.setHaul(pipeGizmoHost.capturedPart());
            else if (activeDrag is moveSub   && moveSub.dragAxis   >= 0)  toolHandles.setHaul(MOVE_BASE  + moveSub.dragAxis);
            else if (activeDrag is rotateSub && rotateSub.dragAxis >= 0)  toolHandles.setHaul(ROT_BASE   + rotateSub.dragAxis);
            else if (activeDrag is scaleSub  && scaleSub.dragAxis  >= 0
                                             && scaleSub.dragAxis != ScaleTool.PLANE_DRAG_AXIS)
                                                                          toolHandles.setHaul(SCALE_BASE + scaleSub.dragAxis);
            else                                                          toolHandles.setHaul(-1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
        }

        if (flagT) {
            if (compactPresentation()) moveSub.drawCompact (shader, vp, vts, visualOnly);
            else                       moveSub.draw        (shader, vp, vts, visualOnly);
        }
        if (flagR) {
            if (compactPresentation()) rotateSub.drawPrincipalOnly(shader, vp, vts, visualOnly);
            else                       rotateSub.draw             (shader, vp, vts, visualOnly);
        }
        if (flagS) {
            if (compactPresentation()) scaleSub.drawAxisBoxesOnly(shader, vp, vts, visualOnly);
            else                       scaleSub.draw             (shader, vp, vts, visualOnly);
        }

        // GL falloff handles drawn ONCE, on top of the gizmo banks.
        // `pipeGizmoHost.drawGizmo` is ALREADY render-only (no begin/
        // register/update — the arbiter cycle above owns that), so it
        // needs no `visualOnly` gate. The ImGui ring/sphere overlay
        // (task 0213) is emitted once per cell from the app.d
        // `Viewport##k` window loop instead of here — this call used to
        // draw on ImGui's background list, which is occluded by the
        // opaque per-cell viewport image (task 0170) and never visible.
        if (fp.enabled && pipeGizmoHost !is null) pipeGizmoHost.drawGizmo(shader, vp, fp);

        syncGpuMatrix();
    }

    override Param[] params() {
        // In uniform mode, hide the per-axis SX/SY/SZ rows and show a single
        // "uniformScale" row instead (forms engine shows only non-hidden params).
        // The reverse applies in non-uniform mode: uniformScale is hidden so it
        // never appears for the standard scale/TransformScale presets.
        // SX/SY/SZ/uniformScale + TX/TY/TZ/RX/RY/RZ below are per-gesture
        // transform run-state (run.t / headlessRotate / run.s) — reset each
        // session (reference auto-reset), not a remembered setting. Excluded from
        // sticky-tool-defaults capture via .transient().
        auto pSX = Param.float_("SX", "Scale X", &run.s.x, 1.0f).transient();
        auto pSY = Param.float_("SY", "Scale Y", &run.s.y, 1.0f).transient();
        auto pSZ = Param.float_("SZ", "Scale Z", &run.s.z, 1.0f).transient();
        auto pUS = Param.float_("uniformScale", "Scale",   &uniformVal, 1.0f).transient();
        if (uniform) { pSX = pSX.hidden(); pSY = pSY.hidden(); pSZ = pSZ.hidden(); }
        else         { pUS = pUS.hidden(); }
        return [
            Param.bool_ ("T",  "Translate", &flagT, true),
            Param.bool_ ("R",  "Rotate",    &flagR, true),
            Param.bool_ ("S",  "Scale",     &flagS, true),
            // Task 0332 — negScale gates the scale-factor clamp (scale.d
            // clampScaleFactor + panel post-write clamps + the ImGui `v_min`
            // floors, both here and in scale.d) so a drag/panel edit can cross
            // zero into a negative (mirrored) factor. Default off preserves
            // the pre-0332 clamp-at-0 behavior.
            Param.bool_ ("negScale", "Negative Scale", &negScale, false),
            // Task 0332 — slipUV: OFF (default) already matches vibe3d's
            // current transform behavior (UVs untouched) with no apply-path
            // code. ON is captured but deferred (see field doc comment) — the
            // flag is stored/exposed for panel parity only; it is a no-op.
            Param.bool_ ("slipUV", "Slip UVs", &slipUV, false),
            // Hidden bool: set by the preset's `uniform: "true"` attr.
            // Controls single-factor lock (uniformScale param + disc-only handle).
            Param.bool_ ("uniform", "Uniform Scale", &uniform, false).hidden(),
            Param.int_  ("H",  "Handle Family", &handleFamily, 0).hidden(),
            Param.enum_ ("presentation", "Handle Presentation",
                         &handlePresentation,
                         [["compact", "Compact"], ["full", "Full"]],
                         "compact").hidden(),
            Param.float_("TX", "Translate X", &run.t.x, 0.0f).transient(),
            Param.float_("TY", "Translate Y", &run.t.y, 0.0f).transient(),
            Param.float_("TZ", "Translate Z", &run.t.z, 0.0f).transient(),
            Param.float_("RX", "Rotate X",    &headlessRotate.x,    0.0f).angle().transient(),
            Param.float_("RY", "Rotate Y",    &headlessRotate.y,    0.0f).angle().transient(),
            Param.float_("RZ", "Rotate Z",    &headlessRotate.z,    0.0f).angle().transient(),
            // Rotate-only fold blend selector (consumed in applyFold). "linear"
            // (MatrixLerp, default) keeps the reference-correct unified fold; "arc"
            // (PolarQuat) scales the rotation angle by the falloff weight, R(w*theta),
            // radius-preserving — used by xfrm.softRotate / xfrm.swirl.
            Param.enum_ ("rotFalloffBlend", "Rotate Falloff Blend",
                         &rotFalloffBlend,
                         [["linear", "Linear (matrix)"], ["arc", "Arc (angle)"]],
                         "linear").hidden(),
            pSX, pSY, pSZ,
            pUS,
        ];
    }

    // Fan a uniformScale write into all three scale axes.
    // Only reacts to "uniformScale" — all other attr writes are no-ops here
    // (the per-axis SX/SY/SZ params bind directly to run.s.x/y/z so they
    // take effect through the Param pointer without needing this hook).
    override void onParamChanged(string name) {
        auto prepared = prepareParamState(name);
        XfrmPreparedState handle;
        if (validatePreparedState(prepared, handle)) installLegacyPreparedState(handle);
    }

    override bool prepareDoorParamChanged(string name, PreparedRecordContext,
            Layer, ulong, ulong) {
        auto prepared = prepareParamState(name);
        XfrmPreparedState handle;
        if (!validatePreparedState(prepared, handle)) return false;
        installLegacyPreparedState(handle);
        return true;
    }

private:
    PreparedToolStateDelta prepareParamState(string name) const nothrow @nogc {
        if (uniform && name == "uniformScale")
            return PreparedToolStateDelta.vec3(preparedToolStateOwner,
                                               uniformVal, uniformVal, uniformVal);
        return PreparedToolStateDelta.none(preparedToolStateOwner);
    }
    bool validatePreparedState(ref PreparedToolStateDelta prepared,
                               out XfrmPreparedState handle) nothrow @nogc {
        if (prepared.owner != preparedToolStateOwner) return false;
        if (prepared.kind == PreparedToolStateKind.None) {
            handle = XfrmPreparedState(false, Vec3.init, true);
            return true;
        }
        if (prepared.kind != PreparedToolStateKind.Vec3) return false;
        handle = XfrmPreparedState(true,
            Vec3(prepared.x, prepared.y, prepared.z), true);
        return true;
    }
    void installLegacyPreparedState(ref XfrmPreparedState handle) nothrow @nogc {
        if (!handle.consumable) return;
        handle.consumable = false;
        if (handle.apply) run.s = handle.scale;
    }
public:

    // When the config-driven transform form is rendering (forms_engine_plan.md
    // Phase 5 + 5b), it OWNS ALL the TRS value rows — Position (TX/TY/TZ),
    // Rotate (RX/RY/RZ) and Scale (SX/SY/SZ) — and drives them through the
    // reEvaluate() seam (a plain `interactive` tool.attr per axis). The legacy
    // input-bank sliders must therefore NOT
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
        if (flagT) {
            auto input = moveSub.drawInputProperties(run.t);
            if (input.active && input.delta != Vec3(0, 0, 0)) {
                applyMovePanelDelta(input.delta);
                Vec3 worldDelta = moveSub.handler.axisX * input.delta.x
                                + moveSub.handler.axisY * input.delta.y
                                + moveSub.handler.axisZ * input.delta.z;
                moveSub.handler.setPosition(moveSub.handler.center + worldDelta);
                moveSub.cachedCenter = moveSub.handler.center;
            }
            if (input.done) needsGpuUpdate = true;
        }
        if (flagR) {
            auto input = rotateSub.drawInputProperties(publishedRotate());
            if (input.active) {
                import std.math : PI;
                captureDragBaselineIfStale(DragBank.Rotate);
                Vec3 radians = Vec3(
                    input.degrees.x * cast(float)(PI / 180.0),
                    input.degrees.y * cast(float)(PI / 180.0),
                    input.degrees.z * cast(float)(PI / 180.0));
                applyRotateAbsoluteFromRun(radians);
                needsGpuUpdate = true;
            }
            if (input.done) needsGpuUpdate = true;
        }
        if (flagS) {
            scaleSub.setInputOptions(negScale);
            if (uniform) {
                // Single "Scale" row seeded from wrapper truth each frame
                // (run.s.x == y == z in uniform mode). Mirrors the
                // bank input row pattern but
                // fans the single edit value back into all three axes.
                import ImGui = d_imgui;
                uniformVal = publishedScale().x;
                // Task 0332: negScale relaxes both the slider's v_min floor
                // and the post-write clamp below so a uniform-scale drag can
                // cross zero into a negative (mirrored) factor.
                float scaleVMin = negScale ? -float.max : 0.0f;
                ImGui.DragFloat("Scale", &uniformVal, 0.01f, scaleVMin, float.max, "%.4f");
                bool active = ImGui.IsItemActive();
                bool done = ImGui.IsItemDeactivatedAfterEdit();
                if (active || done) {
                    if (!negScale && uniformVal < 0.0f) uniformVal = 0.0f;
                    captureDragBaselineIfStale(DragBank.Scale);
                    applyScaleAbsoluteFromRun(
                        Vec3(uniformVal, uniformVal, uniformVal));
                    needsGpuUpdate = true;
                }
                if (done) needsGpuUpdate = true;
            } else {
                auto input = scaleSub.drawInputProperties(publishedScale());
                if (input.active || input.done) {
                    captureDragBaselineIfStale(DragBank.Scale);
                    applyScaleAbsoluteFromRun(input.scale);
                    needsGpuUpdate = true;
                }
                if (input.done) needsGpuUpdate = true;
            }
        }
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
    // Shared body, templated because `handler` is typed per sub-tool
    // (MoveHandler / RotateHandler / ScaleHandler — axisX/Y/Z are declared
    // per subclass in handles/shapes.d, not on the Handler base).
    private static void renderFrameOf(H)(const(H) handler,
            out Vec3 right, out Vec3 up, out Vec3 fwd) {
        right = handler.axisX;
        up    = handler.axisY;
        fwd   = handler.axisZ;
    }
    public void moveRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        renderFrameOf(moveSub.handler, right, up, fwd);
    }
    public void rotateRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        renderFrameOf(rotateSub.handler, right, up, fwd);
    }
    public void scaleRenderFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        renderFrameOf(scaleSub.handler, right, up, fwd);
    }
    // The rotate ring's composed orientation = R_accum · frozenFrame (the
    // R_gesture·B0 the ring already draws, xfrm_transform.d ring compose). The
    // rotate bank's live handler.axis* IS that rendered ring orientation once
    // the Model-C render frame feeds it (Phase 2); before then it equals the
    // frozen idle basis. Published distinctly so a test can assert the ring
    // preview rate independently of the sibling banks.
    public void rotateRingFrame(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        renderFrameOf(rotateSub.handler, right, up, fwd);
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
        // (the selection-derived axis modes — Select/Local, and SelectAuto until
        // its frame was corrected to the auto one — where the move projects onto
        // run.r·B0 and the fold's run.r cancels it). The set is whatever
        // `AxisStage.modeTracksSelection` returns, read below; this note names
        // the modes only to say which case the 0032 claim covered.
        // For the WORLD-INPUT case (Auto/None ACEN
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
        // Read the PUBLISHED capability, not the mode name (no stage
        // lookup, and NOT a call to `AxisStage.axisTracksSelection()` —
        // that instance method has no production caller; see its own doc
        // comment in axis.d). Item mode 0614 / review should-fix 1: read
        // `AxisPacket.tracksSelection` directly off the packet below (not a
        // re-derive off `ap.type` via `AxisStage.modeTracksSelection`) —
        // `type` still names e.g. Select
        // even when AxisStage's item-mode guard made this evaluation publish
        // the Auto/world basis instead, so re-deriving from `type` alone
        // used to render a world-fixed item frame as if it co-rotated with
        // the gesture. `tracksSelection` is computed once, in AxisStage's
        // own evaluate(), from the SAME subject type that produced
        // right/up/fwd — this is the single place that formula must live.
        bool tracksSelection = false;
        {
            import toolpipe.packets : AxisPacket;
            if (auto ap = vts.get!AxisPacket())
                tracksSelection = ap.tracksSelection;
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

    // Gizmo pose, handle registration, hit-geometry refresh, part routing
    // and the arbiter JSON — `xfrm_handles.d` (task 0719).
    mixin XfrmHandlesImpl;


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
    final ubyte preparedActivationFlags() const nothrow @nogc {
        return cast(ubyte)((flagT ? 1 : 0) | (flagR ? 2 : 0) |
                           (flagS ? 4 : 0));
    }
    final bool preparedActivationShape(ubyte flags, MoveTool move,
            RotateTool rotate, ScaleTool scale) const nothrow @nogc {
        return this.classinfo is XfrmTransformTool.classinfo &&
            preparedActivationFlags() == flags && moveSub is move &&
            rotateSub is rotate && scaleSub is scale;
    }
    final void installPreparedBankInputs() nothrow @nogc {
        scaleSub.setInputOptions(negScale);
    }
    version(unittest) final bool preparedBankInputsForTest() const
            nothrow @nogc {
        return scaleSub.negativeScaleEnabled == negScale;
    }
    version(unittest) final void seedPreparedWrapperUploadForTest() {
        needsGpuUpdate = true;
        vertexProcessCount = 1;
    }
    version(unittest) final bool preparedWrapperUploadPendingForTest() const
            nothrow @nogc {
        return needsGpuUpdate;
    }
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

    // Lifecycle-undo emit opt-in is the LifecycleUndoEmitter marker on the
    // class declaration (task 0428) — no method needed.

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


    // Task 0209 (Quad/Split any-cell input): the projection to hit-test/drag
    // against now arrives WITH the event, via SubjectPacket.viewport
    // (app.d's buildToolVts stamps `vpm.inputSnapshot()` — the hovered cell
    // outside a gesture, the drag-origin cell throughout one). Sync it into
    // `cachedVp` (this tool's own, plus every sub-tool's) as the FIRST
    // statement of every mouse handler so the hit-test/drag math below never
    // depends on a stale value left by the last DRAW pass (which only ran for
    // the previous owner cell). During a drag `inputSnapshot()` returns the
    // constant drag-origin vp for the whole gesture, so this is a no-op
    // re-write of the same value each motion frame — the frozen apply-frame
    // invariants (flip-fix `dragAxis<0` gate, frozen `dragAxisVec`/
    // `dragRefDir`) are untouched.
    private void syncInputViewport(ref VectorStack vts) {
        if (auto sp = vts.get!SubjectPacket()) {
            cachedVp           = sp.viewport;
            moveSub.cachedVp   = sp.viewport;
            rotateSub.cachedVp = sp.viewport;
            scaleSub.cachedVp  = sp.viewport;
            // Task 0614 Phase 3 — cache the subject type from the SAME packet
            // `cachedVp` reads, at the SAME per-event refresh point, so
            // `itemSubjectActive()` is a cheap field read instead of an
            // extra `selTypeSrc_()` call at every use site.
            cachedSubjType_    = sp.selType;
        }
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        syncInputViewport(vts);
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
            // Task 0212: same owner-geometry refresh as the draw arbiter
            // block (refreshBankGeometry's doc comment) — closes the
            // analogous latent CLICK miss: a mouse-down can land while the
            // shared handler geometry still reflects a non-owner cell's
            // last draw. `cachedVp` here is the owner cell's pinned vp
            // (synced by syncInputViewport above).
            refreshBankGeometry(cachedVp);
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
            // Task 0614 Phase 3 — tryPickElement is the element-falloff
            // centroid pick (relocates the gizmo onto a clicked vertex/edge/
            // face); falloff is not consumed in item mode (§Q2), so skip it
            // here rather than let it relocate the gizmo off a mesh element
            // while an item is the actual subject.
            if (pickAllowed && hitPart < 0 && !itemSubjectActive())
                picked = tryPickElement(e.x, e.y);
        }

        // Falloff endpoint handles claim the click first (Linear/Radial),
        // routed at the wrapper through the host-owned falloff emitter.
        if (e.button == SDL_BUTTON_LEFT) {
            FalloffPacket curFp = currentFalloff(vts);
            // Task 0212 optional extension: the falloff endpoint gizmo's
            // hit geometry (FalloffEndpointHandle.centerBox.size,
            // radial size-handle positions) is likewise refreshed from a
            // shared object a foreign cell's draw may have last touched —
            // see PipeGizmoHost.syncGeometry's doc comment for why this is
            // safe to extend uniformly (Arrow/Box-style, no discrete flip).
            if (pipeGizmoHost !is null) pipeGizmoHost.syncGeometry(cachedVp, curFp);
            if (pipeGizmoHost !is null && pipeGizmoHost.tryClaimDown(e, cachedVp, curFp, toolHandles)) {
                activeDrag = null;   // falloff owns the drag, no gizmo bank
                return true;
            }
        }
        // Task 0614 Phase 5 (R3) — the off-gizmo mis-click guard for Item mode.
        //
        // MEASURED, not assumed. R3 as written in the plan predicted that an
        // off-gizmo click would run the geometry pick and `promoteGeometryType`
        // the current type away from Item. It does not: `app.d`'s pick arm is
        // gated on `dragMode` being a Select mode, and `dragMode` is only ever
        // assigned a Select mode when NO tool is active — so with a transform
        // tool up the click never reaches the pick at all, and the interactive
        // pick does not call the promote hook in any case (only the selection
        // COMMANDS do). The damage the click actually does is a different one,
        // and worse: every bank treats an off-gizmo press in a relocate-
        // PERMITTED action-centre mode (Auto/None/Screen — the default) as a
        // RELOCATE, which pushes a `userPlaced` pin through
        // `notifyAcenUserPlaced`. That pin takes precedence over the item
        // redirect in `ActionCenterStage.computeCenter`, so the gizmo LEAVES the
        // item it is transforming and parks wherever the click ray met the work
        // plane — after which every subsequent rotate/scale of the item happens
        // about a point with no relation to it. Measured on a fixture with
        // `pos+pivot = (1, 0.7, -0.4)`: one click in empty space moved the
        // published centre to `(-1.7905, 1.0466, 0)`, for all three of
        // move/rotate/scale.
        //
        // The fix is the one the plan prescribes, and it cures the real defect
        // as well as the predicted one: while the subject is an item, the tool
        // CONSUMES a plain off-gizmo left-down itself and returns true. The
        // banks never see it, so nothing relocates and nothing arms an
        // off-gizmo drag; the existing off-gizmo run-boundary block at the
        // bottom of this method still runs, so the press still SPLITS the undo
        // run exactly as it does for a geometry subject.
        //
        // Gating, and why each term:
        //  - `hitPart < 0` — every interactive part of all three banks is
        //    registered into `toolHandles` (`registerGizmoHandles`), including
        //    the rotate VIEW ring, so a negative part genuinely means "no gizmo
        //    under the cursor". A handle grab is untouched by this guard.
        //  - LEFT + no ALT/CTRL/SHIFT — the identical `plain2` filter the
        //    boundary block below uses, so the set of downs we consume is
        //    exactly the set it already recognises as a boundary. Excluding ALT
        //    is load-bearing: `app.d` offers the camera chords (Alt+LMB orbit,
        //    Alt+Shift pan, Ctrl+Alt zoom) to the tool FIRST, and consuming one
        //    would kill camera navigation in Item mode.
        //  - `pressPlacesCenter()` — the relocate is the ONLY thing that
        //    needs suppressing, and this predicate is exactly where it can
        //    fire. Getting this term wrong is a live regression, not a corner
        //    case: in a relocate-DISALLOWED mode the same press relocates
        //    nothing and still arms an off-gizmo drag from the stable pinned
        //    pivot — `move.d`'s `relocates == false` arm reaches
        //    `beginScreenPlaneDragAt(..., notifyAcen=false)`, `rotate.d`'s arms
        //    the arcball as `dragAxis = 3`, and `scale.d`'s pinned `else`
        //    branch takes `queryActionCenter(vts)` and calls `armPlaneDrag`
        //    unconditionally (the `wasPinnedOffGizmo` / `rotWasPinnedOffGizmo`
        //    twins below exist for precisely this case). Since the predicate
        //    admits only Auto/None/Screen, EVERY other mode — Select,
        //    SelectAuto, Element, Local, Origin, Manual, Pivot, Parent, Border
        //    — keeps its off-gizmo drag, and `actr.pivot` (the natural
        //    item-mode action centre) is one of them. Swallowing the press
        //    there would turn a legitimate drag into a no-op for no benefit:
        //    there is no relocate to prevent.
        //
        // What this deliberately gives up, in Item mode AND only in a
        // relocate-permitted action-centre mode (Auto/None/Screen): the
        // off-gizmo screen-plane move drag, the off-ring arcball rotate and the
        // off-handle plane scale. In those modes all three arrive through the
        // same press that relocates, so all three would drag the item about the
        // just-relocated (i.e. wrong) centre. Grab a handle to transform an
        // item — or pin the centre with an item-anchored mode, which restores
        // the off-gizmo drags because nothing relocates under them.
        immutable bool itemOffGizmoDown =
            itemSubjectActive()
            && e.button == SDL_BUTTON_LEFT
            && hitPart < 0
            && (SDL_GetModState() & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) == 0
            && pressPlacesCenter();

        if (!itemOffGizmoDown && routeResolvedHandlePart(e, vts, hitPart))
            return true;

        // Click landed OFF every gizmo handler bank. If we just
        // picked an element under falloff.element, snap moveSub's
        // handler.center to the new ACEN-pivot and start a
        // screen-plane drag immediately — the same click+drag UX
        // ElementMove uses. The drag moves the prior selection
        // (empty ⇒ whole mesh per the universal rule); the falloff
        // sphere now centred on the picked element attenuates the
        // per-vertex displacement. ACEN's normal click-relocate
        // gate (pressPlacesCenter refuses Element mode) does
        // NOT apply here — Element mode IS the gate.
        //
        // Requires the T flag: with T off (TransformRotate /
        // TransformScale) there's no moveSub.handler to anchor on.
        //
        // Task 1530 — AND an active Element FALLOFF, which until 1530 was
        // implied: `tryPickElement` itself refused without one, so `picked`
        // could not be true here. Now that the pick is gated on the ACEN mode
        // instead, this haul would become reachable from `actr.element` on any
        // T-enabled tool with no falloff configured at all — a click on a
        // vertex would start hauling the whole mesh. Keeping the falloff term
        // leaves `xfrm.elementMove` byte-identical and gives bare
        // `actr.element` what the reference gives it: the click moves the
        // pivot, and nothing else.
        if (picked && flagT && elementFalloffActive()) {
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
            if (editIsOpen()) commitEditAtBankBoundary(DragBank.Move);
            moveSub.restageActionCenterPin();       // run-close: UNCONDITIONAL on pick
            // Cross-slot (symmetric): an element-pick relocate, like any
            // relocate, commits EVERY open session — close any open R/S sub-tool
            // session too (composed preset). No-op in single-mode.
            // Hard run boundary (addendum A2): the element-pick relocate ends the
            // open run — consolidate its in-session tail into one surviving
            // entry, then open a fresh run id. Gated on history.runOpen() (the
            // single source of truth) so the run splits even when the prior
            // gesture already self-committed its session.
            if (history !is null && history.runOpen()) {
                consolidateRunAndAdvance();
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
            // ACEN stage's currentCenter() reads the pin the pick just froze
            // (`elementPin`, task 1530 — before that, the live ring centroid of
            // the same element) and so already reflects the just-picked
            // element. Feeding the stale packet here anchored the drag at the
            // OLD center, so the gizmo moved relative to its old location
            // instead of jumping onto the picked vertex first — the reported
            // bug.
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
        //  - An open wrapper edit. No open edit means no record.
        // After the close, re-stage the
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
            // Split wrapper-edit close from run-close at the P5
            // off-gizmo-in-relocate-DISALLOWED boundary.
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
            if (plain2 && editIsOpen())
                commitEditAtBankBoundary(DragBank.Move);
            // Run-close: verbatim re-stage of the current pin (NOT a relocate —
            // pin unchanged) so the next gesture freezes the picked anchor, plus
            // the consolidate/nextRun/bank-reset that SPLITS the run. p5Boundary
            // gates on plain2 + runOpen() (a modified nav click does not split;
            // runOpen() is the single source of truth for "a run to close").
            if (p5Boundary) {
                moveSub.stageCurrentActionCenterPin();
                closeRunBoundary();
                // Apply-path Phase 2: the P5 off-gizmo-in-relocate-DISALLOWED
                // click is a geometry-run boundary; re-capture on the next drag.
                resetRun();   // + P-F: this boundary freezes a NEW run-frame
            }
        }
        // Task 0614 Phase 5 (R3): an item-mode off-gizmo down is CONSUMED here.
        // The boundary work above already ran (it shares `plain2` with the guard
        // above), so the press keeps its run-splitting meaning; returning true is
        // what stops it from reaching any bank, and stops `app.d` from offering
        // it to the selection path afterwards.
        return itemOffGizmoDown;
    }

    private void resetGestureAttrs() {
        // Struct-init reset — t=(0,0,0)/r=identity/s=(1,1,1) per XformState field
        // defaults. Also refresh the derived euler display (identity ⇒ 0).
        run = XformState.init;
        headlessRotate = Vec3(0, 0, 0);
    }

    // Run-boundary close helpers (record+consolidate). The gizmo mouse-down
    // consume arms and the idle boundary polls split the open run the same
    // few ways; these cover the exact field sets those sites reset. Every
    // caller gates on `history !is null && history.runOpen()` (or an
    // equivalent, e.g. p5Boundary) BEFORE calling, so `history` is non-null
    // and the run is open here.

    // Hard run boundary: collapse the open run's tagged in-session entries
    // into ONE surviving entry, then open a fresh run id so the next gesture
    // is tagged distinctly.
    private void consolidateRunAndAdvance() {
        history.consolidate(history.currentRunId);
        history.nextRun();
    }

    // consolidateRunAndAdvance + reset the in-session run bank: the closed
    // run's bank does not carry into the fresh run.
    private void closeRunBoundary() {
        consolidateRunAndAdvance();
        currentRunBank = DragBank.None;
    }

    // ── THE LAW (task 0791), and the two halves it separates ────────────
    //
    //   ACTIVATING a slot  — putting a (possibly identical) tool into one of
    //                        the pipe's slots — ENDS the held run. The result
    //                        stays frozen at the pipe state that produced it
    //                        and the tool re-arms.
    //   WRITING an ATTRIBUTE of a slot's tool — RE-WEIGHS the held run from
    //                        its pre-gesture baseline (the re-grade block
    //                        the re-grade block in update(); unchanged).
    //
    // Measured on the reference under a debugger, eight cells in one boot,
    // in full agreement with the trace (task 0791). The decisive cell put
    // the SAME tool back into a slot that already held it: the pipeline is
    // byte-identical before and after and the held operation still ends, so
    // the trigger is the activation EVENT, not a diff of the pipeline. That
    // is also why there is no packet comparison to copy here — the reference
    // compares nothing, it rolls the held result back and re-runs the pipe.
    //
    // Covered: the three slots the reference was actually driven through —
    // action centre, falloff, axis. Snap and symmetry are NOT covered: they
    // were never driven there, and guessing is what this task spent four
    // reference boots not doing. See the task file's gap list.
    //
    // ONE counter answers all of it. An earlier version of this also kept a
    // second, value-comparing latch on the action centre's MODE "as belt and
    // braces for the paths that change it without a command". That claim was a
    // hypothesis, and it is false: every live writer of the mode goes through a
    // command site (the pipe-attr command or the action-centre preset), and the
    // only direct writes left in the tree are inside that stage's own
    // unittests. Deleted after measuring — the suite does not notice, and the
    // mode cell stays red under a mutation that stops the mode arming the slot.
    //
    // The check is callable from BOTH places that can see an activation:
    //   * EditSession.onStageConfigChanged, synchronously with the pipe-stage
    //     command and BEFORE its re-evaluate (SlotActivationClient). An open
    //     panel session re-evaluates the moment the stage publishes, so the
    //     boundary has to win that race — a frame later the geometry has
    //     already been recomputed and freezing it is no longer possible.
    //   * update()'s idle path, for the routes that publish no stage-config
    //     signal at all (the `actr.*` side-effect commands).
    // Returns whether it ended a run this call. Idempotent: the latches are
    // updated by the firing call, so a second call sees no change.
    override bool endHeldRunIfSlotActivated() {
        // Never mid-drag. A slot read while a gesture is in flight is the
        // drag's own state, not a user action — and the reference's cells were
        // all taken at idle, so ending a run underneath a live drag would be
        // extrapolation. The guard lives HERE rather than only at the update()
        // call site because the stage-config seam fires synchronously with the
        // command, and a handle drag (the RMB falloff-radius drag, the falloff
        // handles) publishes stage config while dragging.
        if (activeDrag !is null) return false;
        bool fired = false;
        // — the pipe's slot state, ALL stages at once. A move means the user
        //   armed a slot: a different tool in it, the SAME tool re-issued, a
        //   node added or removed, or -- for the action centre -- an explicit
        //   relocate through the command surface, which is the one this task
        //   started from (the pointer routes already end the run themselves).
        {
            ulong curSig = slotStateSignature();
            uint  acenEp = 0;
            if (auto ac = activeAcenStage()) acenEp = ac.slotEpoch;
            if (!lastSlotSigValid) {
                // First poll after the tool armed: latch without firing.
                lastSlotSigValid = true;
                lastSlotSig      = curSig;
                lastAcenEpoch    = acenEp;
            } else if (curSig != lastSlotSig) {
                // pivotMoved is ASKED, not assumed: an action-centre activation
                // moves the gizmo pivot, so the display soft-pin from a prior
                // settle goes with the run; a falloff or axis activation leaves
                // the pivot alone and must not yank the gizmo.
                endHeldRunAtSlotActivation(acenEp != lastAcenEpoch);
                fired = true;
                lastSlotSig   = curSig;
                lastAcenEpoch = acenEp;
            }
        }

        return fired;
    }

    // Task 0791 — the ONE thing a pipe-slot ACTIVATION does: end the held run.
    // The held result stays exactly where the old pipe state put it (nothing is
    // recomputed here) and the tool re-arms on a fresh run/frame. Called from
    // the idle slot poll in update(); the pointer routes reach the same state
    // through their own mouse-down boundaries (Phase 1a / element pick / P5),
    // which is why those already answered this way before 0791.
    //
    // `pivotMoved` is for the action-centre slot only: its activations also move
    // the gizmo pivot, so the display soft-pin from a prior settle must go with
    // the run. A falloff/axis activation leaves the pivot alone and must NOT
    // yank the gizmo.
    private void endHeldRunAtSlotActivation(bool pivotMoved) {
        // Session close first, for ALL THREE banks — a slot activation ends the
        // held operation, not just the Move part of it. (The pointer boundaries
        // commit the same set; the pre-0791 ACEN-mode poll committed only Move,
        // a gap of the same shape as the one this task closes.)
        if (editIsOpen())
            commitOpenEdit(TransformHistoryIntent.RunClose);
        if (history !is null && history.runOpen()) {
            closeRunBoundary();
            // Same reset as the selection boundary: a later config change
            // cannot re-grade the run that just ended.
            invalidateRunRefireAnchor();
        }
        // GEOMETRY-run boundary regardless of an open history run: the next
        // gesture must re-capture its baseline against the new pipe state.
        resetRun();   // + P-F: freezes a NEW run-frame
        if (pivotMoved) {
            clearAcenSoftPlaced();
            clearFrame();   // COMMIT B — one lifecycle with the center pin
        }
    }

    // The pipe's SLOT STATE, as one comparable value: every stage's
    // slot-arming write counter, folded in pipeline order. It moves when the
    // user arms any slot -- including re-arming the tool ALREADY in it, which
    // is the case a value comparison cannot see and which the reference was
    // measured to end the operation on -- and when a node is added or removed
    // (the fold walks the live stage list, so its length is part of the value).
    // Every OTHER pipe attribute leaves it alone: those are attribute writes
    // and still re-grade.
    //
    // WHICH attributes count is each stage's own answer (Stage.attrArmsSlot),
    // so the snap stage -- measured NOT to end a held operation, the one slot
    // that does not follow the rule -- simply never moves this.
    private ulong slotStateSignature() const {
        ulong sig = 1469598103934665603UL;          // FNV-1a offset basis
        if (g_pipeCtx is null) return sig;
        foreach (st; (cast(Pipeline) g_pipeCtx.pipeline).allMut()) {
            sig ^= cast(ulong) st.slotEpoch + 1;
            sig *= 1099511628211UL;                 // FNV-1a prime
        }
        return sig;
    }

    // Run boundary: invalidate the re-grade anchor + staleness stamp so a
    // falloff/snap/symmetry config change after the boundary cannot re-grade
    // the just-closed run.
    private void invalidateRunRefireAnchor() {
        lastAppliedGestureMutationVersion = ulong.max;
        armedUndoEpoch                    = ulong.max;   // task 1906 census
        refireAnchor.length               = 0;
        refirePreValid                    = false;
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
        // Task 1069 — the routed run baseline shares the geometry-run
        // boundary exactly. Without this a second gesture would evaluate from
        // the FIRST gesture's start position and overwrite its delta instead
        // of adding to it (law L7).
        morphRunValid_   = false;
        // Task 0614 Phase 3 — R15 lifecycle parity: the item baseline shares
        // the vertex baseline's boundary exactly (same gate, same call
        // site), so the next item run re-baselines + re-freezes together.
        itemBaselineValid = false;
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
            moveRec.runKnown   = false;
            scaleRec.runKnown  = false;
            // The view-ring run flag clears so the next run's first principal
            // gesture does not see a stale post-view-ring re-bake demand.
            rotateRec.runKnown = false;
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

    // Idle replay preserves the pre-cutover sampling rules. Move samples the
    // pipe against the current preview before the fold restores its baseline,
    // while Rotate/Scale sample the baseline only for their pure presets. A
    // composed preset keeps the live pipe sample so held neighbour banks retain
    // their established frame/pin semantics.
    private bool samplePipeFromBaselineForRegrade(DragBank bank) const {
        final switch (bank) {
        case DragBank.None:   return false;
        case DragBank.Move:   return false;
        case DragBank.Rotate: return flagR && !flagT && !flagS;
        case DragBank.Scale:  return flagS && !flagT && !flagR;
        }
    }

    // Rotate's former absolute-replay entry point advanced the display soft
    // pin after every idle replay in relocate-capable modes. Keep that side
    // effect beside both wrapper-owned replay arms now that neither routes
    // back through the input bank.
    private void settleRotateRegradeCenter(DragBank bank) {
        if (bank != DragBank.Rotate || !pressPlacesCenter()) return;
        if (auto ac = activeAcenStage())
            ac.setSoftPlaced(lastFoldPivotWorld);
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
        // at the run-start accumulator, so a same-axis repeat
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
            // Task 1069 — the routed run baseline rides the SAME `rebake`
            // predicate as `dragBaseline`, so a same-bank repeat holds it
            // exactly as it holds the base one.
            captureMorphRunBaseline(dragBaseline);
            resetGestureAttrs();
            runBaselineValid = true;

            // Task 0614 Phase 3 — item-mode run baseline, captured on the
            // SAME predicate as `dragBaseline` above: a same-bank repeat
            // holds the run baseline (itemBaselineValid stays true, no
            // re-capture below); a fresh run OR a rotate cross-axis re-bake
            // re-captures. Re-resolved on every rebake so a fresh run after a
            // mid-session layer-select picks up the new selection. Phase 6:
            // the WHOLE selected set (law L2), not just the primary.
            resolveItemTargets(itemTargets);
            itemDragBaseline.length = itemTargets.length;
            foreach (i, t; itemTargets) itemDragBaseline[i] = t.xform;
            itemBaselineValid = itemTargets.length > 0;
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

    // F3b — per-bank record accessor shared by beginGesture / buildGestureHooks
    // / the run-boundary resets, so there is exactly one bank->field mapping.
    private ref GestureRecord recFor(DragBank bank) {
        final switch (bank) {
            case DragBank.None:   assert(false, "recFor: bank must be Move/Rotate/Scale");
            case DragBank.Move:   return moveRec;
            case DragBank.Rotate: return rotateRec;
            case DragBank.Scale:  return scaleRec;
        }
    }

    // F3b — single RUN/FRAME-START capture chokepoint: the RK gate of the
    // "two internal gates" (OBJ 4). Called from every begin*DragSession
    // UNCONDITIONALLY, immediately after `beginRunGesture(bank)` — matching
    // the load-bearing ordering `beginEdit (PK capture) -> beginRunGesture ->
    // RK capture` the plan specifies.
    //
    // The SIBLING gate — pin/soft-START (PK) — deliberately does NOT live
    // here. It stays inside `beginEdit()`'s override (unchanged since F3a),
    // because `beginEdit()` is the ONE chokepoint EVERY session-open funnels
    // through, including the numeric/panel-attr path
    // (`captureDragBaselineIfStale` -> `beginEdit`) that NEVER calls this
    // function at all — moving the PK capture here would silently drop it on
    // that path and defeat the OBJ 1 divergence (pinKnown true / runKnown
    // false) the whole task exists to preserve. So "two gates" resolves to
    // two call sites by necessity, not by choice: beginEdit's `!wasOpen`
    // guard (PK) and this function (RK), invoked together in that order from
    // every begin*DragSession.
    //
    // Rotate/Scale additionally capture their gesture-START SOFT pin here
    // (gated by the SAME runKnown flag — they have no pin-known family, so
    // their soft-pin rides the run gate; see the GestureRecord field-mapping
    // comment). Move's soft-pin rides the PK gate instead (captured inside
    // beginEdit's override alongside pinStart) — so Move does NOT touch
    // softStart here.
    private void beginGesture(DragBank bank) {
        gestureStart = run;   // OBJ 3 — the standalone field, unaliased
        auto rec = &recFor(bank);
        rec.runStart   = gestureStart;
        rec.frameStart = frame;
        if (bank != DragBank.Move) {
            if (auto ac = activeAcenStage())
                rec.softStart = ac.currentSoftPin();
            else
                rec.softStart = Pin.init;
        }
        rec.runKnown = true;
    }

    // F3b — {apply, revert} closure pair for a gesture-record undo hook.
    private struct GestureHooks { void delegate() apply; void delegate() revert; }

    // F3b — single gesture-COMMIT hook-composition chokepoint: reads
    // `<bank>Rec` (this gesture's START capture) plus the caller-supplied
    // LIVE gesture-END state, and returns the {apply, revert} pair every
    // commit site installs. Move's commitEdit composes this with its OWN
    // falloff/snap/symmetry restore inside `cmd.setHooks`; the Rotate/Scale
    // mouse-up sites install it directly as
    // `rotateSub`/`scaleSub`.wrapperField{Apply,Revert}Hook.
    //
    // Gates each sub-restore by its OWN known bit, decided ONCE here instead
    // of three hand-rolled copies: pin+soft-pin by `pinKnown` for Move (soft
    // rides the SAME gate as pin there — matching beginGesture/beginEdit's
    // capture side), run+frame by `runKnown`, and — for Rotate/Scale, which
    // have no pin-known family — soft-pin ALSO by `runKnown`. A commit with
    // no preceding begin (a no-op relocate-boundary cmd) leaves start==end,
    // so the hook is inert without a separate branch: the fallback is baked
    // into the start/end resolution below, not into whether the restore
    // calls happen (they always happen, mirroring the pre-F3b hook bodies,
    // which never skipped the restorePinState/restoreSoftPlaced calls either
    // — only the VALUES were start==end).
    //
    // Move ALONE restores the userPin — `bank == DragBank.Move` inside the
    // helper, so all three call sites look identical.
    //
    // The projector only reads the known bits. The selected installer consumes
    // them exactly once after the projected state has been validated.
    private GestureHooks projectGestureHooks(DragBank bank,
        XformState runEnd, GestureFrame frameEnd, Pin softEnd, Pin pinEnd)
    {
        auto rec = &recFor(bank);

        bool pinKnown = rec.pinKnown;
        bool runKnown = rec.runKnown;

        Pin pinStart = pinKnown ? rec.pinStart : pinEnd;
        Pin softStart;
        if (bank == DragBank.Move) softStart = pinKnown ? rec.softStart : softEnd;
        else                       softStart = runKnown ? rec.softStart : softEnd;
        XformState   runStart = runKnown ? rec.runStart   : runEnd;
        GestureFrame frmStart = runKnown ? rec.frameStart : frameEnd;

        GestureHooks h;
        if (bank == DragBank.Move) {
            h.apply = () {
                if (auto ac = activeAcenStage()) {
                    ac.restorePinState(pinEnd);
                    ac.restoreSoftPlaced(softEnd);
                }
                run = runEnd; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameEnd; refreshFrameValid();
            };
            h.revert = () {
                if (auto ac = activeAcenStage()) {
                    ac.restorePinState(pinStart);
                    ac.restoreSoftPlaced(softStart);
                }
                run = runStart; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frmStart; refreshFrameValid();
            };
        } else {
            h.apply = () {
                run = runEnd; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameEnd; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softEnd);
            };
            h.revert = () {
                run = runStart; headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frmStart; refreshFrameValid();
                if (auto ac = activeAcenStage())
                    ac.restoreSoftPlaced(softStart);
            };
        }
        return h;
    }

    // Shared begin*DragSession prologue: the per-drag captures every bank
    // runs at mouse-down, BEFORE its bank-specific session/baseline work.
    // The `beginRunGesture(bank)` / `beginGesture(bank)` pair deliberately
    // stays at each call site — Move inserts `beginEdit()` and Rotate its
    // per-cluster capture between this prologue and beginRunGesture
    // (load-bearing order, documented at those sites).
    private void beginDragSessionPrologue(ref VectorStack vts) {
        buildVertexCacheIfNeeded();
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        captureSnapForDrag(vts);   // P-C: run-start snap config for the refire trigger
    }

    // Once-per-drag GPU-bypass predicate (moveDragFastPath / rotDragFastPath /
    // scaleDragFastPath): the unconstrained whole-mesh case — no falloff, no
    // symmetry, no per-cluster pivots, whole-mesh selection.
    //
    // ANTI-RELOCATION: do NOT move the evaluation of this predicate out of
    // the `begin*DragSession` functions and do NOT re-evaluate it in
    // `onMouseMotion`. The fast-path is a ONCE-PER-DRAG decision; its inputs
    // MUST come from the snapshot taken at mouse-down:
    //   - `dragFalloff` / `dragSymmetry`: just captured by
    //     beginDragSessionPrologue; both frozen for the drag.
    //   - `cp.active`: cluster-pivot presence is a function of ACEN mode +
    //     the moving set, both of which the wrapper's `update()` freezes
    //     during a drag (`dragAxis>=0` early-return in transform.d).
    //   - `vertexProcessCount`: selection-derived; same freeze.
    // Recomputing mid-drag from a live `vts` would let the path silently
    // flip (e.g. if falloff turned on between frames), violating the
    // "drag == numeric" contract the parity test pins.
    private bool wholeMeshGpuBypassAllowed(ClusterPivots cp) const {
        // Task 0614 Phase 3 — item mode never takes the GPU bypass: the
        // bypass composes `matMul4(itemMatrix, tt.gpuMatrix)`
        // (ui/panels.d:~1928) on the assumption that `itemMatrix` is
        // whatever the LAYER already holds; in item mode the item matrix
        // itself is what the gesture is writing, so a non-identity
        // `gpuMatrix` on top would double-apply it.
        if (itemSubjectActive()) return false;
        return !dragFalloff.enabled
            && !dragSymmetry.enabled
            && !cp.active
            && (vertexProcessCount == cast(int)mesh.vertices.length);
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
        beginDragSessionPrologue(vts);
        beginEditForBank(DragBank.Move);

        // `cachedVp` is already up to date from the most recent
        // `draw()` call (every frame, before any event dispatch);
        // `applyTRS` reuses it for falloff weight evaluation.

        // Run-scoped baseline + held-attr discipline (apply-path Phase 2):
        // capture once per geometry run (or re-baseline a same-bank repeat),
        // preserving held R/S into the fold on a cross-bank move gesture.
        beginRunGesture(DragBank.Move);
        // F3b — RK-gate capture (run-absolute START + basis snapshot for the
        // undo splice), unconditional per mouse-down. See beginGesture's doc
        // comment for why the PK gate (pin/soft-START) is NOT here — Move's
        // rides beginEdit()'s own `!wasOpen` guard instead.
        beginGesture(DragBank.Move);
        accumulatedWorldDelta   = Vec3(0, 0, 0);
        accumulatedAtDragStart  = accumulatedWorldDelta;

        auto cp = queryClusterPivots(vts);
        // Once-per-drag predicate; the anti-relocation contract (frozen
        // mouse-down inputs, never recomputed mid-drag) lives on
        // wholeMeshGpuBypassAllowed.
        moveDragFastPath = wholeMeshGpuBypassAllowed(cp);

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
        beginDragSessionPrologue(vts);

        // The wrapper captures both the edit session and the geometry drag
        // state (`dragBaseline`/falloff/symmetry/fast-path). rotateSub remains
        // the input/value producer; applyTRS and the wrapper-owned history path
        // consume its result for both component and item subjects.
        beginEditForBank(DragBank.Rotate);

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
        // F3b — RK-gate capture: run-absolute START, gesture-START soft pin
        // (flex_border_handles_plan.md Phase 3 BUG-1 undo-splice — Rotate has
        // no pin-known family, so its soft-pin rides THIS gate instead of a
        // PK guard, mirroring the Move W1 capture), and the gesture-START
        // gizmo BASIS for the undo splice. See beginGesture's doc comment.
        beginGesture(DragBank.Rotate);
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
        // Same once-per-drag freeze contract as `moveDragFastPath`; see
        // wholeMeshGpuBypassAllowed's anti-relocation note. Do NOT recompute
        // mid-drag.
        rotDragFastPath = wholeMeshGpuBypassAllowed(cp);

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
    // The wrapper owns the Scale edit and history payload. scaleSub produces
    // input state; geometry is applied through applyTRS.
    void beginScaleDragSession(ref VectorStack vts) {
        beginDragSessionPrologue(vts);

        beginEditForBank(DragBank.Scale);

        // Run-scoped baseline + held-attr discipline (apply-path Phase 2): a
        // cross-bank scale reuses the run baseline + resets ONLY run.s,
        // so held T/R survive into the composed fold. For Scale (run-absolute,
        // Phase 3a) a scale-after-scale does NOT re-bake/zero: the run keeps ONE
        // frozen baseline and run.s accumulates the run-total factor.
        beginRunGesture(DragBank.Scale);
        // F3b — RK-gate capture: run-absolute START, gesture-START soft pin
        // (flex_border_handles_plan.md Phase 3 BUG-1 undo-splice, mirror of
        // the rotate/Move capture — Scale has no pin-known family), and the
        // gesture-START gizmo BASIS for the undo splice. See beginGesture's
        // doc comment.
        beginGesture(DragBank.Scale);

        auto cp = queryClusterPivots(vts);
        // Same once-per-drag freeze contract as `moveDragFastPath`; see
        // wholeMeshGpuBypassAllowed's anti-relocation note. Do NOT recompute
        // mid-drag.
        scaleDragFastPath = wholeMeshGpuBypassAllowed(cp);
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
        syncInputViewport(vts);
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
                // factor only (`dragScaleAccum`, reset to 1 at this drag's start
                // in ScaleTool's drag-begin), so the drain multiplies it per-axis by the run
                // total captured at this gesture's mouse-down (gestureStart.s, the
                // scale component of the per-gesture run snapshot). For a fresh run
                // the snapshot is identity ⇒ run.s = f (byte-identical to pre-3a).
                // For a same-bank repeat the snapshot is the held run total ⇒ the
                // factors multiply into the run total. Per-axis factors commute ⇒
                // no cross-axis hazard.
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
                //
                // Task 1530 — `samplePipeFromBaseline = true`, the same
                // argument the rotate drain above already passes (:3065/:3104).
                // It restores the run baseline BEFORE `buildLocalVts`, so the
                // whole pipe — action centre, axis, cluster pivots — is
                // evaluated against PRE-gesture geometry instead of against the
                // geometry this very drain just wrote. Scale was the only live
                // bank still sampling the pipe live, and any geometry-DERIVED
                // action centre (Auto / Select / Border / Local, and Element's
                // pre-click fallback) therefore drifted with its own output:
                // `p_{n+1} = S·C0 + (I−S)·p_n`, divergent for |1−s| > 1. The
                // geometry itself never compounded — `applyTRS` restores the
                // baseline every frame and `run.s` is run-absolute — so the
                // pivot was the only accumulator, which is exactly what the
                // owner's trace shows: the dragged axis alone moving, by an
                // order of magnitude per sample, with sign flips.
                //
                // Deliberately NOT done by freezing the pivot inside `applyTRS`
                // (`runFrameValid ? runFrameOrigin : queryActionCenter`): that
                // moves the pivot for EVERY caller — the item branch, the
                // headless numeric path, and the panel path on a MIXED T+R+S
                // preset, where :3741/:3778 pass `true` only for a pure preset.
                // The flag keeps the radius at "the scale drag", and it is the
                // more faithful mechanism besides: the reference rolls the
                // geometry back before EVERY tool evaluation, so its whole pipe
                // reads pre-gesture positions, not just its pivot.
                applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                         /*samplePipeFromBaseline=*/true);
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
            foreach (sub; enabledSubs()) sub.onMouseMotion(e, vts);
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
        syncInputViewport(vts);
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
            foreach (sub; enabledSubs()) sub.onMouseButtonUp(e, vts);
        }

        // Per-bank drag-end epilogues (Phase B split) — one private method
        // per bank, cut VERBATIM from this function at the wasMoveDrag /
        // rotWrapperOwned / wasScaleDrag markers. The cross-block ORDER
        // (Move → Rotate → Scale) is load-bearing — the side-effect order
        // is documented fragile — so the calls below preserve it exactly.
        if (wasMoveDrag && e.button == SDL_BUTTON_LEFT)
            endMoveDrag(vts);
        if (rotWrapperOwned && e.button == SDL_BUTTON_LEFT)
            endRotateDrag(vts);
        if (wasScaleDrag && e.button == SDL_BUTTON_LEFT)
            endScaleDrag(vts);

        // moveSub + all rotate rings + scale are wrapper-owned. Anything else
        // (a sub-tool driving its own gpuMatrix) still needs the forward.
        if (!wasMoveDrag && !rotWrapperOwned && !wasScaleDrag)
            syncGpuMatrix();
        return r;
    }

    // Phase 3 — wrapper owns the GPU upload + gpuMatrix reset
    // that MoveTool's mouseUp used to handle. One upload per
    // drag end; the next drag opens its own dragBaseline at the
    // refreshed mesh state.
    private void endMoveDrag(ref VectorStack vts) {
        gpu.upload(*mesh);
        gpuMatrix = identityMatrix;
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
        // commit captures the gesture-END soft state LIVE (ac.currentSoftPin())
        // into its undo/redo hooks, alongside the
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
            commitOwnedEdit(DragBank.Move, TransformHistoryIntent.RunGesture);
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
    private void endRotateDrag(ref VectorStack vts) {
        gpu.upload(*mesh);
        gpuMatrix = identityMatrix;
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

        // Per-gesture commit: each ring drag finalizes the wrapper-owned Rotate
        // payload as a tagged in-session entry. The next ring grab opens a new
        // wrapper edit, so consecutive drags remain individually step-able and
        // consolidate into one row at the boundary/drop.
        //
        // P-F Phase 3 (MAJOR-5) — unified WHOLE-STRUCT undo hook (identical
        // across all three banks + the refire). xfStart is THIS gesture's
        // run-START snapshot (captured at rotate mouse-down, gestureStart);
        // xfEnd is the current run-total state. Splice them onto the rotateSub
        // gesture entry through the wrapper-field hook pair so an in-session
        // Ctrl+Z restores the run state to BEFORE this gesture (mergeRun
        // first.revert/last.apply splices to run-START / run-END at the drop),
        // and redo restores the post-gesture run state. Gated by
        // rotateRec.runKnown so a commit with no preceding mouse-down leaves
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
        // F3b — read (not yet consumed: buildGestureHooks below clears
        // runKnown) so the settle-gate logic can still tell whether this
        // gesture actually moved the orientation.
        bool rotAbsKnown = rotateRec.runKnown;
        XformState xfStart = rotAbsKnown ? rotateRec.runStart : run;
        XformState xfEnd   = run;
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
        // the RELOCATE modes (pressPlacesCenter: Auto/None/Screen) — its
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
                      && (pressPlacesCenter() || currentFalloff(vts).enabled);
        if (rotSettle) settleGestureCenter(rotateSub.handler.center);
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
        // BASIS undo splice — the rendered-frame analogue of the soft-pin pair
        // above. frameEnd = the gesture-END `frame` settleGestureBasis just
        // wrote (R_gesture·B0); frameStart (resolved inside buildGestureHooks)
        // is this gesture's mouse-down capture. An in-session Ctrl+Z bumps the
        // mutation version but not the selection hash, so clearFrame never
        // fires and the idle renderBasis keeps the settled (rotated) basis —
        // without this restore the gizmo would render the rotated frame over
        // the reverted-to-pristine geometry.
        // F3b — single chokepoint composing the {apply, revert} pair from
        // rotateRec + this gesture's live END state (Rotate never restores
        // the userPin — pinEnd is unused for a non-Move bank, Pin.init is a
        // harmless placeholder). The close installer clears rotateRec.runKnown.
        // The wrapper owns both payload construction and the history decision;
        // the bank has already finished its input/value work at this point.
        commitOwnedEdit(DragBank.Rotate, TransformHistoryIntent.RunGesture);

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
    private void endScaleDrag(ref VectorStack vts) {
        gpu.upload(*mesh);
        gpuMatrix = identityMatrix;
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
        // scaleRec.runKnown so a commit with no preceding mouse-down leaves
        // xfStart == xfEnd (inert). The same pre/post is recorded IDENTICALLY in
        // recordPipeRefire (3747-region) so a snap/falloff mid-run refire does
        // not strand it. A Scale gesture only changes run.s; the T/R fields are
        // equal between xfStart and xfEnd, so the whole-struct restore is
        // byte-equivalent to restoring run.s alone.
        // F3b — read (not yet consumed: buildGestureHooks below clears
        // runKnown) so the settle-gate logic can still tell whether this
        // gesture actually moved the scale factor.
        bool scaleAbsKnown = scaleRec.runKnown;
        XformState xfStart = scaleAbsKnown ? scaleRec.runStart : run;
        XformState xfEnd   = run;
        // flex_border_handles_plan.md Phase 3 (BUG-1) — Scale had NO settle at
        // all; add it through the shared helper (the 2-entry acenSettleAllowed()
        // predicate is the sole mode filter, no relocate gate) so a completed
        // scale leaves the gizmo at its drop pose. Pin BEFORE finalizing so
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
        // needs is unnecessary — hence falloff-only here, NOT pressPlacesCenter.
        // WITH falloff (flex / Border, which always has falloff) the pin fires so
        // bug 1 + the basis persistence stay fixed. acenSettleAllowed() excludes
        // Element/Local as everywhere.
        bool scaleGestureMoved = scaleAbsKnown && !xformScaleEqual(xfStart, xfEnd);
        bool scaleSettle = scaleGestureMoved && acenSettleAllowed()
                        && currentFalloff(vts).enabled;
        if (scaleSettle) settleGestureCenter(scaleSub.handler.center);
        // COMMIT B — persist the scale bank's gesture-end rendered basis
        // (R_gesture=I ⇒ B0) so the idle gizmo holds it after release. Gated
        // identically so center+basis persistence stay in sync.
        if (scaleSettle)
            settleGestureBasis(scaleSub.handler.axisX,
                               scaleSub.handler.axisY,
                               scaleSub.handler.axisZ);
        // BASIS undo splice (mirror of the rotate hook). Scale's R_gesture is I,
        // so frameStart == frameEnd and the restore is an identity no-op — it
        // exists purely so the splice composes uniformly across the three banks.
        // F3b — single chokepoint composing the {apply, revert} pair from
        // scaleRec + this gesture's live END state (Scale never restores
        // the userPin — pinEnd is unused, Pin.init is a harmless
        // placeholder). The close installer clears scaleRec.runKnown.
        // The wrapper owns both payload construction and the history decision;
        // the bank has already finished its input/value work at this point.
        commitOwnedEdit(DragBank.Scale, TransformHistoryIntent.RunGesture);

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

    // Phase 2.5 of doc/item_mode_transform_plan.md (task 0614) — VERBATIM
    // extraction of applyTRS's run-frame freeze into its own function, no
    // behaviour change (R11). Reads only `pivot`/`bX`/`bY`/`bZ`, `frame.valid`
    // and `moveCenterBoxDragActive()`; writes only `runFrameOrigin`/`R`/`U`/`F`
    // + `runFrameValid`. Extracted so the coming item-mode branch (Phase 3)
    // can call the SAME freeze instead of skipping it — the freeze must not be
    // downgraded there; see the plan's boxed warning at §(b). The call site in
    // `applyTRS` keeps its own P-F/M6 ordering comment (freeze BEFORE
    // applyFold/composeFor read the frame); this function's body carries the
    // rest of the original explanation verbatim.
    private void freezeRunFrameIfNeeded(Vec3 pivot, Vec3 bX, Vec3 bY, Vec3 bZ) {
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
    }


    // The geometry-apply path: `applyTRS`, the canonical-matrix fold and
    // its per-pass kernels — `xfrm_apply.d` (task 0719).
    mixin XfrmApplyImpl;

    // Phase 1 (R/S run-baseline) — the FIX. The Rotate/Scale panel-apply path
    // used to rebuild absolutely from a sub-tool session-start snapshot. After
    // a cross-axis gizmo gesture the prior axis is baked into
    // the wrapper's run baseline (`dragBaseline`) + mesh, NOT into the sub-tool
    // snapshot, so a panel edit applied from that snapshot DISCARDED the baked
    // axis. These two entry points re-route the R/S panel apply onto the SAME
    // run baseline the gizmo apply uses (applyTRS(dragBaseline), see :1785 /
    // :1862), so the baked cross-axis history is preserved and the per-axis-delta
    // contract holds (headlessRotate carries only the LIVE axis; the prior axis
    // lives in dragBaseline).
    //
    // captureBaselinePacketsNoSession() snapshots dragBaseline if stale and
    // captures the live falloff/symmetry/snap. The caller opens the wrapper edit
    // with the correct bank provenance before the input-producing sub-tool applies
    // the absolute value through applyTRS.
    //
    // Shared prologue of the two entry points below: snapshot the run
    // baseline + live pipe packets (no wrapper session — see above), then
    // dirty the vertex cache so applyTRS rebuilds from the refreshed
    // baseline.
    private void prepareRunAbsoluteApply() {
        captureBaselinePacketsNoSession();
        vertexCacheDirty = true;
    }

    // Legacy FORMS=0 sliders and idle pipe re-fire still enter from an embedded
    // bank.  Value-batch replay no longer calls either method: it updates the
    // wrapper's canonical TRS directly and folds once in reEvaluate().
    public void applyRotateAbsoluteFromRun(Vec3 angleAccumRad) {
        import std.math : PI;
        import math : matrixFromEulerZYX;
        prepareRunAbsoluteApply();
        headlessRotate = Vec3(angleAccumRad.x * 180.0f / cast(float)PI,
                              angleAccumRad.y * 180.0f / cast(float)PI,
                              angleAccumRad.z * 180.0f / cast(float)PI);
        run.r = matrixFromEulerZYX(headlessRotate);
        bool pureRotatePreset = flagR && !flagT && !flagS;
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                 /*samplePipeFromBaseline=*/pureRotatePreset);
        if (pressPlacesCenter()) {
            if (auto ac = activeAcenStage())
                ac.setSoftPlaced(lastFoldPivotWorld);
        }
    }
    // Tasks 3023 (capture) / 3310 (fix) — THE negScale FLOOR shared by
    // canonical value replay, the legacy/refire door below, and applyHeadless.
    //
    // The law is MEASURED, not designed (fixture
    // `tests/fixtures/scale_negative_typed_value.json`, gap-registry row 85):
    // a numeric write of a scale AXIS is ACCEPTED — it reports success — and
    // the value that gets STORED is `max(+0.0, v)` while the option is off,
    // and `v` verbatim while it is on. The option is consumed at the WRITE and
    // never on the apply path, so the stored value is the whole law. It is
    // specific to the scale axes: a translate value written at the same option
    // state is stored verbatim.
    private Vec3 floorNegativeScale(Vec3 s) const {
        if (negScale) return s;
        if (s.x < 0.0f) s.x = 0.0f;
        if (s.y < 0.0f) s.y = 0.0f;
        if (s.z < 0.0f) s.z = 0.0f;
        return s;
    }

    private Vec3 normalizeScaleRunValue(Vec3 value) const {
        import std.math : isFinite;
        float rejectNonFinite(float f) { return isFinite(f) ? f : 1.0f; }
        value.x = rejectNonFinite(value.x);
        value.y = rejectNonFinite(value.y);
        value.z = rejectNonFinite(value.z);
        return floorNegativeScale(value);
    }

    // Legacy FORMS=0 / idle-refire companion to the rotate entry above.
    // Live value batches bypass the embedded ScaleTool and normalize run.s in
    // reEvaluate() before the batch's single wrapper fold.
    public void applyScaleAbsoluteFromRun(Vec3 factors) {
        prepareRunAbsoluteApply();
        run.s = normalizeScaleRunValue(factors);
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
    // evaluate. The wrapper replay arm calls this before `applyTRS` so the
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
        // Task 3310 — the NUMERIC door's floor. `SX`/`SY`/`SZ` are Params bound
        // straight to `&run.s.{x,y,z}`, so a `tool.attr` write lands in the run
        // state with nothing between it and the fold: before this line a typed
        // `SX -3` with the option OFF mirrored the mesh, while the same write
        // inside a live session floored to 0. The reference floors BOTH (it
        // floors at the setter, so the stored value is the whole law — see
        // `floorNegativeScale`), and it is our numeric path that was wrong.
        // Written back into `run.s` rather than clamped in a local, because the
        // stored value is what the law is about and what a later refire re-reads.
        run.s = floorNegativeScale(run.s);
        // Task 1069 — a headless apply supplies its OWN fresh baseline
        // (`mesh.vertices.dup`), so it is its own one-shot run and must NOT
        // inherit a `dragMorphBaseline` captured by some earlier gizmo drag.
        // Without this, a headless apply following a drag would evaluate from
        // that drag's start position and overwrite its delta.
        morphRunValid_ = false;
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
    // own input-bank panel paths.
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
        // capture and applyTRS, which is why this path stays hand-rolled: the
        // single batch fold captures and applies with nothing in between.
        bool freshBaseline = captureDragBaselineIfStale(DragBank.Move);
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
    private bool captureDragBaselineIfStale(DragBank bank) {
        // Capture baseline/pipe packets first, then open the single wrapper edit
        // with explicit bank provenance. This lets every panel bank reuse the
        // same run baseline without inventing a second session owner.
        bool fresh = captureBaselinePacketsNoSession();
        buildVertexCacheIfNeeded();
        if (bank != DragBank.None) {
            beginEditForBank(bank);
        } else {
            assert(editIsOpen(),
                "a stage replay requires an already-open wrapper edit");
        }

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

    // Session-free baseline + packet capture, split from the wrapper session
    // opener so Rotate/Scale panel apply can prepare shared geometry state before
    // beginEditForBank records their actual provenance.
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
    // Does NOT call beginEdit() / buildVertexCacheIfNeeded() / seed tracking;
    // captureDragBaselineIfStale owns that wrapper-session tail.
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
            captureMorphRunBaseline(dragBaseline);   // task 1069, same predicate
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
    // Phase 3 — public accessor for MoveTool's `update()` to gate
    // its ACEN-pull on whether the wrapper has an open edit
    // session. `editIsOpen()` is protected on `TransformTool`;
    // exposing this read-only wrapper avoids leaking the rest of
    // the edit-session API.
    override public bool publicEditIsOpen() const { return editIsOpen(); }

    // P-F introspection seam (test-only): the LIVE published transform attrs the
    // panel binds (run.t/Rotate/Scale, the TX..SZ Param.float_
    // pointees). The /api/toolpipe/eval provider emits these so the run-absolute
    // panel-display contract can be asserted from a unit test without poking the
    // panel struct. Read-only — never mutates tool state. (Phase 1 extends this
    // with the companion frozen run-frame accessor.)
    public Vec3 publishedTranslate() const { return run.t; }
    public Vec3 publishedRotate()    const { return headlessRotate; }
    public Vec3 publishedScale()     const { return run.s; }

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

    /// Evaluate the wrapper's canonical fold on an isolated clone.  This is
    /// intentionally narrower than cloning the whole tool lifecycle: update
    /// refire is idle (`activeDrag == null`) and consumes only the held run,
    /// frozen run/frame state, the run baseline, viewport and live pipe
    /// packets.  The real wrapper and live mesh are never written.
    public PreparedXfrmRefireCandidate buildPreparedRefireCandidate(
            FalloffPacket falloff, SnapPacket snap, SymmetryPacket symmetry,
            bool useItemSubjectOverride = false,
            bool itemSubjectOverride = false) {
        PreparedXfrmRefireCandidate result;
        auto live = mesh;
        if (live is null || editMode is null ||
            dragBaseline.length != live.vertices.length)
            return result;

        MeshSnapshot.capture(*live).restore(result.mesh);
        GpuMesh scratchGpu;
        EditMode scratchMode = *editMode;
        Layer[] detachedItemTargets;
        const bool itemSubject = useItemSubjectOverride
            ? itemSubjectOverride : itemSubjectActive();
        if (itemSubject) {
            resolveItemTargets(result.itemTargets);
            result.expectedItemXforms.length = result.itemTargets.length;
            detachedItemTargets.length = result.itemTargets.length;
            foreach (i, target; result.itemTargets) {
                result.expectedItemXforms[i] = target.xform;
                detachedItemTargets[i] = new Layer();
                detachedItemTargets[i].xform = target.xform;
            }
        }
        void detachedItemSource(ref Layer[] outTargets) {
            outTargets = detachedItemTargets;
        }
        SelType detachedSubjectSource() {
            return itemSubject ? SelType.Item : SelType.Vertex;
        }
        auto shadow = new XfrmTransformTool(
            () => &result.mesh, &scratchGpu, &scratchMode,
            &detachedSubjectSource,
            &detachedItemSource);
        shadow.cachedSubjType_ = itemSubject ? SelType.Item : SelType.Vertex;
        shadow.flagT = flagT;
        shadow.flagR = flagR;
        shadow.flagS = flagS;
        shadow.uniform = uniform;
        shadow.uniformVal = uniformVal;
        shadow.negScale = negScale;
        shadow.slipUV = slipUV;
        shadow.handleFamily = handleFamily;
        shadow.handlePresentation = handlePresentation;
        shadow.run = run;
        shadow.gestureStart = gestureStart;
        shadow.headlessRotate = headlessRotate;
        shadow.rotFalloffBlend = rotFalloffBlend;
        shadow.dragBaseline = dragBaseline.dup;
        shadow.dragFalloff = falloff;
        shadow.dragSnap = snap;
        shadow.dragSymmetry = symmetry;
        shadow.cachedVp = cachedVp;
        shadow.frame = frame;
        shadow.runFrameValid = runFrameValid;
        shadow.runFrameOrigin = runFrameOrigin;
        shadow.runFrameR = runFrameR;
        shadow.runFrameU = runFrameU;
        shadow.runFrameF = runFrameF;
        shadow.runBaselineValid = runBaselineValid;
        shadow.itemTargets = detachedItemTargets;
        shadow.itemDragBaseline = itemDragBaseline.dup;
        shadow.itemBaselineValid = itemBaselineValid;
        shadow.vertexCacheDirty = true;
        shadow.activeDrag = null;

        auto delivery = beginPreparedShadow(result.mesh);
        result.applied = shadow.applyTRS(shadow.dragBaseline);
        drainPreparedShadowDelivery(result.mesh, result.deliveryFlags,
                                    result.deliveryDomains);
        result.vertexIndices = shadow.vertexIndicesToProcess.dup;
        result.vertexMask = shadow.toProcess.dup;
        result.vertexCount = shadow.vertexProcessCount;
        result.vertexCacheDirty = shadow.vertexCacheDirty;
        result.runFrameValid = shadow.runFrameValid;
        result.runFrameOrigin = shadow.runFrameOrigin;
        result.runFrameR = shadow.runFrameR;
        result.runFrameU = shadow.runFrameU;
        result.runFrameF = shadow.runFrameF;
        if (result.itemTargets.length > 0) {
            result.nextItemXforms.length = detachedItemTargets.length;
            foreach (i, target; detachedItemTargets)
                result.nextItemXforms[i] = target.xform;
            result.itemPrepared = result.applied;
        }
        return result;
    }

    public PreparedXfrmReplayImage buildPreparedReplay(
            ref const PreparedXfrmUpdatePreProjection projection,
            PreparedRecordContext context) {
        PreparedXfrmReplayImage image;
        if (!projection.valid || (!projection.panelRegrade &&
                                  !projection.wrapperRegrade) || mesh is null)
            return image;
        image.expectedLive = MeshSnapshot.capture(*mesh);
        image.expectedIndices = vertexIndicesToProcess.dup;
        image.expectedMask = toProcess.dup;
        image.expectedCount = vertexProcessCount;
        image.expectedCacheDirty = vertexCacheDirty;
        image.expectedNeedsGpu = needsGpuUpdate;
        image.expectedRunFrameValid = runFrameValid;
        image.expectedRunFrameOrigin = runFrameOrigin;
        image.expectedRunFrameR = runFrameR;
        image.expectedRunFrameU = runFrameU;
        image.expectedRunFrameF = runFrameF;
        image.expectedFalloff = dragFalloff.ownedDup();
        image.expectedSnap = dragSnap;
        image.expectedSymmetry = dragSymmetry.ownedDup();
        FalloffPacket liveFalloff = projection.liveFalloff.ownedDup();
        SnapPacket liveSnap = projection.liveSnap;
        SymmetryPacket liveSymmetry = projection.liveSymmetry.ownedDup();
        auto prepared = buildPreparedRefireCandidate(
            liveFalloff, liveSnap, liveSymmetry, true,
            projection.subject == SelType.Item);
        if (!prepared.applied) return image;
        image.candidate = prepared.mesh;
        image.nextIndices = prepared.vertexIndices;
        image.nextMask = prepared.vertexMask;
        image.nextCount = prepared.vertexCount;
        image.nextCacheDirty = prepared.vertexCacheDirty;
        image.nextNeedsGpu = true;
        image.nextRunFrameValid = prepared.runFrameValid;
        image.nextRunFrameOrigin = prepared.runFrameOrigin;
        image.nextRunFrameR = prepared.runFrameR;
        image.nextRunFrameU = prepared.runFrameU;
        image.nextRunFrameF = prepared.runFrameF;
        image.nextFalloff = projection.liveFalloff.ownedDup();
        image.nextSnap = projection.liveSnap;
        image.nextSymmetry = projection.liveSymmetry.ownedDup();
        image.itemTargets = prepared.itemTargets;
        image.expectedItemXforms = prepared.expectedItemXforms;
        image.nextItemXforms = prepared.nextItemXforms;
        image.deliveryFlags = prepared.deliveryFlags;
        image.deliveryDomains = prepared.deliveryDomains;
        image.itemPrepared = prepared.itemPrepared;
        image.meshPrepared = !image.itemPrepared;
        image.panel = projection.panelRegrade;
        image.wrapper = projection.wrapperRegrade;
        if (image.wrapper) {
            image.historyRefire = buildPreparedRefireState(context,
                image.expectedLive.vertices, image.candidate.vertices,
                image.expectedFalloff, image.nextFalloff,
                image.expectedSnap, image.nextSnap,
                image.expectedSymmetry, image.nextSymmetry);
            if (!image.historyRefire.valid)
                return PreparedXfrmReplayImage.init;
        }
        image.valid = true;
        return image;
    }

    public bool preparedReplayMatches(
            ref const PreparedXfrmReplayImage image, in Mesh live) const
            nothrow @nogc {
        if (!image.valid || !image.expectedLive.matches(live) ||
            vertexIndicesToProcess != image.expectedIndices ||
            toProcess != image.expectedMask ||
            vertexProcessCount != image.expectedCount ||
            vertexCacheDirty != image.expectedCacheDirty ||
            needsGpuUpdate != image.expectedNeedsGpu ||
            runFrameValid != image.expectedRunFrameValid ||
            runFrameOrigin != image.expectedRunFrameOrigin ||
            runFrameR != image.expectedRunFrameR ||
            runFrameU != image.expectedRunFrameU ||
            runFrameF != image.expectedRunFrameF ||
            !falloffPacketsEqual(dragFalloff, image.expectedFalloff) ||
            !snapPacketsEqual(dragSnap, image.expectedSnap) ||
            !symmetryPacketsEqual(dragSymmetry, image.expectedSymmetry) ||
            itemTargets.length != image.itemTargets.length ||
            image.itemTargets.length != image.expectedItemXforms.length)
            return false;
        foreach (i, target; image.itemTargets)
            if (target is null || itemTargets[i] !is target ||
                target.xform != image.expectedItemXforms[i]) return false;
        return !image.historyRefire.valid ||
            preparedRefireStateMatches(image.historyRefire);
    }

    public void installPreparedReplay(
            ref PreparedXfrmReplayImage image) nothrow @nogc {
        if (!image.valid) return;
        vertexIndicesToProcess = image.nextIndices; image.nextIndices = null;
        toProcess = image.nextMask; image.nextMask = null;
        vertexProcessCount = image.nextCount;
        vertexCacheDirty = image.nextCacheDirty;
        needsGpuUpdate = image.nextNeedsGpu;
        runFrameValid = image.nextRunFrameValid;
        runFrameOrigin = image.nextRunFrameOrigin;
        runFrameR = image.nextRunFrameR;
        runFrameU = image.nextRunFrameU;
        runFrameF = image.nextRunFrameF;
        dragFalloff = image.nextFalloff;
        dragSnap = image.nextSnap;
        dragSymmetry = image.nextSymmetry;
        foreach (i, target; image.itemTargets)
            target.xform = image.nextItemXforms[i];
        if (image.historyRefire.valid)
            installPreparedRefireState(image.historyRefire);
        image.clear();
    }

    /// Prepare the exact history carrier and wrapper-private tail of
    /// `recordPipeRefire` without touching the live wrapper, mesh, stages or
    /// census counters. `anchor` is the live post-gesture image and `after` is
    /// the already detached recompute candidate.
    public PreparedXfrmRefireStateImage buildPreparedRefireState(
            PreparedRecordContext context,
            const Vec3[] anchor, const Vec3[] after,
            FalloffPacket preF, FalloffPacket postF,
            SnapPacket preSn, SnapPacket postSn,
            SymmetryPacket preSy, SymmetryPacket postSy) {
        auto projection = projectPreparedPipeRefire(anchor, after, null,
            preF, postF, preSn, postSn, preSy, postSy);
        if (!preparePipeRefireProjection(projection, context))
            return PreparedXfrmRefireStateImage.init;
        return projection.state;
    }

    private bool preparePipeRefireProjection(ref PipeRefireProjection p,
            PreparedRecordContext context) {
        if (context is null || !p.valid || p.stale || history is null)
            return false;
        return context.prepare(p.command,
            PreparedHistoryKind.ReplaceInSessionTail,
            history.currentRunId).accepted;
    }

    private PipeRefireProjection projectPreparedPipeRefire(
            const Vec3[] anchor, const Vec3[] after, const size_t[] idx,
            FalloffPacket preF, FalloffPacket postF,
            SnapPacket preSn, SnapPacket postSn,
            SymmetryPacket preSy, SymmetryPacket postSy) {
        return projectPipeRefire(anchor, after, idx,
            preF, postF, preSn, postSn, preSy, postSy);
    }

    public bool preparedRefireStateMatches(
            ref const PreparedXfrmRefireStateImage image) const nothrow @nogc {
        return image.valid && refireAnchor == image.expectedAnchor &&
            refirePreValid == image.expectedPreValid &&
            falloffPacketsEqual(refirePreFalloff, image.expectedPreFalloff) &&
            snapPacketsEqual(refirePreSnap, image.expectedPreSnap) &&
            symmetryPacketsEqual(refirePreSym, image.expectedPreSymmetry) &&
            lastMutationVersion == image.expectedLastMutation &&
            lastAppliedGestureMutationVersion == image.expectedGestureMutation &&
            armedUndoEpoch == image.expectedUndoEpoch;
    }

    public void installPreparedRefireState(
            ref PreparedXfrmRefireStateImage image) nothrow @nogc {
        if (!image.valid) return;
        refireAnchor = image.nextAnchor; image.nextAnchor = null;
        refirePreValid = image.nextPreValid;
        refirePreFalloff = image.nextPreFalloff;
        refirePreSnap = image.nextPreSnap;
        refirePreSym = image.nextPreSymmetry;
        lastMutationVersion = image.nextLastMutation;
        lastAppliedGestureMutationVersion = image.nextGestureMutation;
        armedUndoEpoch = image.nextUndoEpoch;
        image.clear();
    }

    private void beginEditForBank(DragBank bank) {
        beginEdit();
        // The operation that opened a live parameter region owns its close.
        // Held nonidentity values replayed by later batches are operands, not
        // new causes, and a later channel write inside the same region does not
        // manufacture an internal boundary.
        if (editIsOpen() && (editCauseBank == DragBank.None ||
                             editCauseProvisional)) {
            editCauseBank = bank;
            editCauseProvisional = false;
        }
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
        // Task 0614 Phase 4 — item branch. Bypasses the base class entirely
        // (transform.d's `if (history is null || vertexEditFactory is null)
        // return;` guard would otherwise refuse to open — the item path
        // needs `history` but never `vertexEditFactory`, per the plan's "the
        // merge, not the tool, owns run-start state"). Snapshots THIS
        // GESTURE's opening ItemXform per target — a SEPARATE snapshot from
        // `itemDragBaseline` (the RUN-scoped fold baseline `beginRunGesture`
        // captures): `itemDragBaseline` feeds `applyGestureToItems`'s fold
        // math, this feeds the per-gesture undo `before`. Mirrors
        // editIdx/editBefore/editCapturing's role on the vertex path.
        // Idempotent — a repeat call before commitEdit() is a no-op, same
        // contract as the base.
        if (itemSubjectActive()) {
            if (itemEditCapturing_) return;
            // Re-resolve the moving set HERE rather than reading the
            // `itemTargets` field: `beginEdit()` runs BEFORE
            // `beginRunGesture()` in every begin*DragSession (load-bearing
            // for the vertex path's pin/attr baseline capture below, which
            // this branch does not disturb), so `itemTargets` — populated
            // only by beginRunGesture's rebake — is not yet valid at this
            // point in a fresh run. A self-sufficient resolve sidesteps the
            // ordering entirely, mirroring restoreItemBaseline()'s headless
            // fallback; both go through the same `resolveItemTargets` funnel,
            // so the undo session and the fold baseline cover the same set by
            // construction, not by two sites agreeing.
            resolveItemTargets(itemEditTargets_);
            itemEditBefore_.length = itemEditTargets_.length;
            foreach (i, t; itemEditTargets_) itemEditBefore_[i] = t.xform;
            itemEditCapturing_ = true;
            // S2 (0614 review) — snapshot the panel display mirrors at
            // session-open too, mirroring the vertex branch below
            // (attrBaseTranslate/Rotate/Scale). Without this,
            // cancelUncommittedEdit()'s item arm has nothing correct to
            // restore RX/RY/RZ/SX/SY/SZ to, and would leave the panel
            // showing the cancelled gesture's stale values even though the
            // item's own xform correctly reverted.
            attrBaseTranslate = run.t;
            attrBaseRotate    = headlessRotate;
            attrBaseScale     = run.s;
            return;
        }

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
                moveRec.pinStart = ac.currentUserPin();
                moveRec.pinKnown = true;

                // BUG-2 — capture the gesture-START SOFT pin LIVE here too (the
                // W1 lesson). For gesture-1 of a run this is typically unset (no
                // soft pin yet → revert clears, pivot recomputes to the
                // reverted-geometry centroid). For gesture-2+ of a sticky run it
                // is the prior gesture's settle, so revert restores that.
                moveRec.softStart = ac.currentSoftPin();
            }
        }
    }

    // One wrapper close for every bank. It attaches the shared run/pin/config
    // hooks, then routes the command according to the explicit history intent.
    //
    // Under per-gesture commit each Move mouse-up records a tagged in-session
    // entry and DISCARDS the frozen pin snapshot (no open session at idle). The
    // in-session Ctrl+Z is now a plain history.undo()/redo() — so the pin must
    // ride the ENTRY: revert restores the gesture-START pin (the LIVE pin this
    // gesture's beginEdit captured into moveRec.pinStart — W1 fix, NOT the frozen
    // snapshot), apply restores the gesture-END pin (the current pin at mouse-up,
    // post sticky-follow). A plain history step then snaps the action center
    // per-step for free; consolidate()'s first.revert + last.apply splice gives
    // the merged run entry run-START / run-END pin semantics for free.
    //
    // The gesture-START is the LIVE pin captured at beginEdit (moveRec.pinStart),
    // so commit no longer needs to read it before the base commit's
    // discardUserPlacedSnapshot(). When no gesture-START was captured (a commit
    // with no preceding beginEdit-open —
    // e.g. a relocate-boundary commit on an already-closed session: a no-op cmd)
    // fall back to the current pin for BOTH endpoints, making the hooks inert.
    protected override void commitEdit(string) {
        commitOpenEdit(TransformHistoryIntent.RunClose);
    }

    // A relocate/off-gizmo boundary keeps a same-bank open edit in the current
    // run, matching the pre-1905 commitEdit path. Only a bank transition is a
    // BoundaryCommit and therefore a distinct undo unit.
    private void commitEditAtBankBoundary(DragBank incomingBank) {
        if (editCauseBank == incomingBank)
            commitOpenEdit(TransformHistoryIntent.RunClose);
        else
            commitOpenEdit(TransformHistoryIntent.BoundaryCommit);
    }

    private void commitOpenEdit(TransformHistoryIntent intent) {
        const bank = editCauseBank;
        if (bank == DragBank.None) {
            assert(0, "an open wrapper edit must retain its operation cause");
            return;
        }
        // History rows are named by the wrapper command, never by whichever
        // bank happens to supply or hold an operand for the fold.
        commitOwnedEdit(bank, intent);
    }

    // One calculation owns the close image, command payload, gesture endpoints
    // and pipe hooks. The two callers below intentionally differ only in how
    // they install that result: live records immediately; prepared enlists the
    // command and installs the captured state later through its typed owner.
    private OwnedEditCloseProjection projectOwnedEditClose(
            DragBank bank, bool itemSubject) {
        OwnedEditCloseProjection p;
        auto image = &p.state;
        image.expectedSubject = cachedSubjType_;
        image.expectedBank = cast(ubyte)bank;
        image.itemSubject = itemSubject;
        image.vertex = capturePreparedEditClose();
        image.item = capturePreparedItemEditClose();
        image.closeWrapper = editIsOpen();
        if (image.closeWrapper && bank == DragBank.None) return p;

        image.discardAcenSnapshot = !itemSubject && !suppressCommit;
        if (image.discardAcenSnapshot) {
            image.expectedAcen = activeAcenStage();
            if (image.expectedAcen !is null) {
                image.expectedUserPin = image.expectedAcen.currentUserPin();
                image.expectedSoftPin = image.expectedAcen.currentSoftPin();
                image.expectedCancelFrozen = image.expectedAcen
                    .projectedEditCloseSnapshotFrozen();
            }
        }

        if (image.closeWrapper && !suppressCommit)
            p.command = itemSubject ? projectItemEditCommand()
                                    : projectEditCommand(name());

        if (image.closeWrapper && !itemSubject && !suppressCommit) {
            image.installCommitState = true;
            image.expectedPendingSoft = pendingMoveSoftPin;
            image.expectedPendingCenter = pendingMoveSoftCenter;
            image.expectedDragFalloff = dragFalloff.ownedDup();
            image.nextDragFalloff = dragFalloff.ownedDup();
            auto rec = &recFor(bank);
            image.expectedPinKnown = rec.pinKnown;
            image.expectedRunKnown = rec.runKnown;

            if (p.command !is null) {
                image.consumeGestureState = true;
                image.nextSoftPin = image.expectedSoftPin;
                image.settleSoftPin = pendingMoveSoftPin &&
                    image.expectedAcen !is null && acenSettleAllowed();
                if (image.settleSoftPin)
                    image.nextSoftPin = Pin(true, pendingMoveSoftCenter);
                if (image.nextDragFalloff.enabled &&
                    image.nextDragFalloff.type == FalloffType.Element &&
                    image.expectedAcen !is null)
                    image.nextDragFalloff.pickedCenter = image.expectedAcen
                        .projectedCenterAfterSoftPin(
                            image.nextSoftPin, image.settleSoftPin);

                Pin pinEnd = image.expectedUserPin;
                auto gh = projectGestureHooks(bank, run, frame,
                    image.nextSoftPin, pinEnd);
                FalloffSetSnapshot fSnap =
                    snapshotFalloffSet(activeFalloffStages());
                SnapPacket snSnap; bool haveSn;
                SymmetryPacket sySnap; bool haveSy;
                if (auto sn = activeSnapStage()) {
                    snSnap = sn.snapshotConfigToPacket(); haveSn = true;
                }
                if (auto sy = activeSymmetryStage()) {
                    sySnap = sy.snapshotConfigToPacket(); haveSy = true;
                }
                void delegate(void delegate(), void delegate()) setHooks;
                import commands.mesh.morph_edit : MeshMorphEdit;
                if (auto mcmd = cast(MeshMorphEdit)p.command)
                    setHooks = (a, r) { mcmd.setHooks(a, r); };
                else if (auto vcmd = cast(MeshVertexEdit)p.command)
                    setHooks = (a, r) { vcmd.setHooks(a, r); };
                if (setHooks !is null) setHooks(
                    () {
                        gh.apply(); restoreFalloffSet(fSnap);
                        if (haveSn) if (auto sn = activeSnapStage())
                            sn.restoreConfigFromPacket(snSnap);
                        if (haveSy) if (auto sy = activeSymmetryStage())
                            sy.restoreConfigFromPacket(sySnap);
                    },
                    () {
                        gh.revert(); restoreFalloffSet(fSnap);
                        if (haveSn) if (auto sn = activeSnapStage())
                            sn.restoreConfigFromPacket(snSnap);
                        if (haveSy) if (auto sy = activeSymmetryStage())
                            sy.restoreConfigFromPacket(sySnap);
                    });
            }
        }
        image.valid = true;
        p.valid = true;
        return p;
    }

    private OwnedEditCloseProjection projectPreparedOwnedEditClose(
            DragBank bank, bool itemSubject) {
        return projectOwnedEditClose(bank, itemSubject);
    }

    private bool prepareOwnedEditClose(ref OwnedEditCloseProjection p,
            PreparedRecordContext context, TransformHistoryIntent intent) {
        if (!p.valid) return false;
        if (p.command is null) return true;
        if (context is null || history is null) return false;
        const kind = intent == TransformHistoryIntent.BoundaryCommit
            ? PreparedHistoryKind.Plain : PreparedHistoryKind.InSession;
        const runId = kind == PreparedHistoryKind.InSession
            ? history.currentRunId : 0;
        if (!context.prepare(p.command, kind, runId).accepted) return false;
        p.state.historyPrepared = true;
        return true;
    }

    private void installLiveOwnedEditClose(ref OwnedEditCloseProjection p,
            TransformHistoryIntent intent) {
        if (!p.valid) return;
        auto image = &p.state;
        if (image.discardAcenSnapshot)
            discardAcenUserPlacedSnapshot();
        if (image.installCommitState) {
            if (image.settleSoftPin)
                settleGestureCenter(image.nextSoftPin.center);
            dragFalloff = image.nextDragFalloff;
            if (image.consumeGestureState) {
                pendingMoveSoftPin = false;
                auto rec = &recFor(cast(DragBank)image.expectedBank);
                rec.pinKnown = false;
                rec.runKnown = false;
            }
        }
        if (image.closeWrapper) {
            installPreparedEditClose(image.vertex);
            installPreparedItemEditClose(image.item);
        }
        editCauseBank = DragBank.None;
        editCauseProvisional = false;
        if (p.command !is null) recordTransformCommand(p.command, intent);
        p.valid = false;
    }

    private void commitOwnedEdit(DragBank bank,
                                 TransformHistoryIntent intent) {
        auto projection = projectOwnedEditClose(bank, itemSubjectActive());
        installLiveOwnedEditClose(projection, intent);
    }

    // Typed history intents preserve four distinct causes. A landed gesture
    // and a normal run close append inside the open run, a relocate/cross-slot
    // boundary is an ordinary record, and a pipe refire may replace only a
    // compatible Refire tail in the current tweak generation.
    private enum TransformHistoryIntent {
        RunGesture,
        RunClose,
        BoundaryCommit,
        GenerationRefire,
    }

    private void recordTransformCommand(Command cmd,
                                        TransformHistoryIntent intent) {
        final switch (intent) {
            case TransformHistoryIntent.RunGesture:
            case TransformHistoryIntent.RunClose:
                history.recordInSession(cmd, history.currentRunId);
                publishCommittedTransform();
                break;
            case TransformHistoryIntent.BoundaryCommit:
                history.record(cmd);
                publishCommittedTransform();
                break;
            case TransformHistoryIntent.GenerationRefire:
                history.replaceInSessionTail(cmd, history.currentRunId);
                break;
        }
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // The single wrapper edit is the exact "a close would record now" predicate
    // for Move, Rotate, Scale, component, and item payloads alike.
    override bool hasUncommittedEdit() const {
        return editIsOpen();
    }

    // ----- Live re-evaluation hooks (attr edit re-runs a live tool) ---------
    //
    // "live" exactly when the wrapper's transform edit is open. This drives the
    // attr/pipe re-eval trigger; a raw attr edit on a fresh tool remains inert.
    override bool hasLiveEval() const {
        return editIsOpen();
    }

    // Phase 1 (R/S run-baseline) — VALUE-attr live-eval widening. A panel
    // RX/RY/RZ or SX/SY/SZ edit after a gizmo gesture (but before the tool
    // drops) must compose onto the run baseline. The per-gesture commit model
    // (P-F) closes the wrapper edit at each gizmo mouse-up, so editIsOpen() is
    // false BETWEEN gestures even though the run continues — the held
    // run-absolute field + frozen `dragBaseline` are still
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

    private static ubyte replayBankBit(DragBank bank)
            pure nothrow @safe @nogc {
        return bank == DragBank.None ? 0
             : cast(ubyte)(1 << cast(int)bank);
    }

    private static DragBank replayBankForChannel(string channel)
            pure nothrow @safe @nogc {
        if (channel == "T" || channel == "TX" || channel == "TY" ||
            channel == "TZ") return DragBank.Move;
        if (channel == "R" || channel == "RX" || channel == "RY" ||
            channel == "RZ" || channel == "rotFalloffBlend")
            return DragBank.Rotate;
        if (channel == "S" || channel == "SX" || channel == "SY" ||
            channel == "SZ" || channel == "uniformScale" ||
            channel == "uniform" || channel == "negScale")
            return DragBank.Scale;
        return DragBank.None;
    }

    private static string replayBankName(DragBank bank)
            pure nothrow @safe @nogc {
        final switch (bank) {
            case DragBank.None:   return "none";
            case DragBank.Move:   return "move";
            case DragBank.Rotate: return "rotate";
            case DragBank.Scale:  return "scale";
        }
    }

    private static string replaySourceName(ParameterChangeSource source)
            pure nothrow @safe @nogc {
        final switch (source) {
            case ParameterChangeSource.InteractiveValue: return "interactive";
            case ParameterChangeSource.ScriptedValue:    return "scripted";
            case ParameterChangeSource.StageAttribute:   return "stage";
            case ParameterChangeSource.SlotActivation:   return "slot";
        }
    }

    // Re-run one logical parameter batch from the frozen session baseline.
    // The write-set says WHY the replay happened; current nonidentity values
    // are merely operands in the canonical T/R/S fold.  This distinction keeps
    // RX->0 and SX->1 observable and prevents a held bank from claiming a TX
    // edit.  Stage batches have no value-channel cause and re-weight the same
    // canonical operation without changing its owner.
    override void reEvaluate(ParameterChangeBatch batch) {
        immutable bool valueBatch =
            batch.source == ParameterChangeSource.InteractiveValue ||
            batch.source == ParameterChangeSource.ScriptedValue;
        DragBank cause = DragBank.None;
        ubyte changedBanks;

        if (valueBatch) {
            lastValueReplayChannels = batch.names.dup;
            lastValueReplaySource = batch.source;
            lastValueReplayValid = true;
            foreach (channel; batch.names) {
                const bank = replayBankForChannel(channel);
                if (cause == DragBank.None && bank != DragBank.None)
                    cause = bank;
                changedBanks |= replayBankBit(bank);
            }
            lastValueReplayCause = cause;
            // A wrapper-only option with no TRS effect (currently slipUV) is a
            // real write but does not manufacture a geometry replay.
            if (cause == DragBank.None) return;

            // Setter projections land before BatchComplete.  Finish the two
            // canonical representations whose bound display values are not the
            // fold truth, preserving the existing rotation convention and
            // scale non-finite/negative clamps.
            if (changedBanks & replayBankBit(DragBank.Rotate)) {
                import math : matrixFromEulerZYX;
                run.r = matrixFromEulerZYX(headlessRotate);
            }
            if (changedBanks & replayBankBit(DragBank.Scale))
                run.s = normalizeScaleRunValue(run.s);
        }

        if (!flagT && !flagR && !flagS) return;

        // Value batches may open a wrapper edit; a stage batch is delivered
        // only while one is already open.  The opener's cause remains the
        // region owner across later batches, preserving the existing boundary
        // contract while each batch still reports its own replay cause.
        captureDragBaselineIfStale(cause);
        applyTRS(dragBaseline, Vec3(0, 0, 0), 0,
                 /*samplePipeFromBaseline=*/true);
        needsGpuUpdate = true;
        if (valueBatch) ++valueReplayFolds;

        if (valueBatch &&
            (changedBanks & replayBankBit(DragBank.Rotate)) &&
            pressPlacesCenter()) {
            if (auto ac = activeAcenStage())
                ac.setSoftPlaced(lastFoldPivotWorld);
        }
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
        // silently no-opped against a Rotate/Scale preset. Open the wrapper with
        // the first enabled bank's provenance, matching production.
        if (!flagT && !flagR && !flagS) {
            return;
        }
        // Preserve the opener's historical first-enabled-bank owner for tests
        // that manually mutate geometry, but mark it provisional: the first
        // real value batch replaces it with that operation's actual cause.
        const wasOpen = editIsOpen();
        if      (flagT) captureDragBaselineIfStale(DragBank.Move);
        else if (flagR) captureDragBaselineIfStale(DragBank.Rotate);
        else if (flagS) captureDragBaselineIfStale(DragBank.Scale);
        if (!wasOpen && editIsOpen()) editCauseProvisional = true;
        // Deliberately NO applyTRS / needsGpuUpdate — bare session, no geometry.
    }

    // Test-only discriminator for idle Rotate re-grade. Gesture mouse-up
    // normally leaves this pin populated, so a deletion of the re-grade settle
    // call is observationally inert unless the test can remove that prior value
    // without also closing the held run.
    public void clearSoftPinForTest() {
        clearAcenSoftPlaced();
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
        // reachable directly; bail when neither wrapper payload is open.
        //
        // S2 (0614 review) — split the WRAPPER'S OWN "open" state into its two
        // DISJOINT sub-sessions instead of reading the combined editIsOpen()
        // override (`itemEditCapturing_ || super.editIsOpen()`). The combined
        // read is right for "is there anything to cancel at all" but WRONG as
        // a gate for the vertex-restore body below: with only an item session
        // open, editIsOpen() still reads true, so the vertex arm used to run
        // anyway — restoring an EMPTY editIndices()/editBaseline() (beginEdit()'s
        // item branch bypasses super.beginEdit() entirely, so those base-class
        // fields were never populated for this session), then unconditionally
        // calling mesh.commitChange(Position) + gpu.upload on a mesh that was
        // never touched. That phantom mutationVersion bump made the NEXT
        // update() see a "mutation" and commit the still-applied item edit
        // instead of the cancel having reverted it — the first Ctrl+Z did
        // nothing, the second one (now undoing that phantom commit) did.
        bool itemOpen   = itemEditCapturing_;
        bool vertexOpen = super.editIsOpen();
        if (!itemOpen && !vertexOpen) return;

        suppressCommit = true;
        scope(exit) suppressCommit = false;

        // Item arm (S2, 0614 review). Restores every captured target's
        // PRE-edit xform — the same beginEdit()-open snapshot the close projector
        // would otherwise have diffed against — then clears the trio so
        // editIsOpen() reports closed afterward, and restores the panel
        // display mirrors captured alongside it. Deliberately does NOT touch
        // mesh.vertices / mesh.commitChange / gpu.upload: nothing on the mesh
        // ever changed for an item-mode session (applyTRS's item branch never
        // reaches mesh.vertices), so running that code here would be both
        // wrong (nothing to restore) and actively harmful (the phantom
        // version bump described above).
        if (itemOpen) {
            foreach (i, t; itemEditTargets_) {
                if (i < itemEditBefore_.length) t.xform = itemEditBefore_[i];
            }
            run.t          = attrBaseTranslate;
            headlessRotate = attrBaseRotate;
            run.s          = attrBaseScale;
            itemEditCapturing_      = false;
            itemEditTargets_.length = 0;
            itemEditBefore_.length  = 0;
        }

        // Wrapper-side restore (Move / T session). Only runs when the WRAPPER's
        // OWN vertex session is open — a pure item-mode cancel skips it. The
        // action-center pin snapshot is frozen by
        // beginEdit() ONLY on the wrapper session's open, so its restore lives
        // here too.
        if (vertexOpen) {
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
            // Task 1069 — a routed session moved the
            // MAP and left `mesh.vertices` alone, so the loop above restores
            // nothing that changed; without this the cancelled drag keeps its
            // edit. (And note why `editBefore` still holds POSITIONS: this
            // loop writes it straight into geometry, so putting deltas in
            // there would teleport every moving vertex to near the origin.)
            restoreMorphEditBaseline();
            // Session cancel restores positions to the pre-edit baseline — a real
            // version bump (not mid-drag), so commitChange (Position) reproduces
            // the raw mutationVersion bump AND publishes the class.
            mesh.commitChange(MeshEditScope.Position);
            gpu.upload(*mesh);
            gpuMatrix = identityMatrix;
            needsGpuUpdate = false;

            // Restore the headless TRS attrs to their session-start values so the
            // Tool-Properties panel / config form (which read params() — the live
            // &run.t.x etc. pointers — per frame) snap back in
            // lockstep with the geometry. Without this the verts revert but the
            // numeric fields keep stale edited numbers. Captured on the
            // wrapper's closed->open transition in beginEdit() above.
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
        editCauseBank      = DragBank.None;
        editCauseProvisional = false;
        activeDrag          = null;
        dragBaseline.length = 0;
        resetRun();                    // apply-path Phase 2: cancelled run (+ P-F frozen frame)
        moveDragFastPath    = false;
        rotDragFastPath     = false;
        rotDragAxisIdx      = -1;
        scaleDragFastPath   = false;
        scaleDragActive     = false;
        // (Until task 1930 this also noted that app.d re-invalidated the
        // screen-space pick caches every frame while a tool was active.
        // Those caches are gone; nothing here needs re-validating.)
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
        // Task 1530 — the GATE is the action-centre mode, not falloff. The
        // frozen Element pivot is ACEN state; a click that relocates it must
        // work wherever that mode is armed (`actr.element` on a plain move
        // tool, say), not only inside the one preset that also happens to arm
        // an Element falloff. This is the reference's shape too: its writer is
        // the centre tool's own event handler, and the falloff is a separate
        // slot it knows nothing about.
        auto ac = activeAcenStage();
        if (ac is null || ac.mode != ActionCenterStage.Mode.Element) return false;

        // The falloff side effects below (anchor ring, connect mask) stay
        // gated: they belong to the Element FALLOFF, and with no such stage
        // there is nothing to seed. `null` here means "pin only".
        FalloffStage stage = activeFalloffStage();
        if (stage !is null && stage.type != FalloffType.Element) stage = null;

        ElementMode em = stage !is null ? stage.elementMode : ElementMode.Auto;
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
    //   1. ACEN ← the picked element's centroid, as BOTH the frozen Element
    //      pivot (`notifyAcenElementPin`, task 1530 — the gizmo pivot and the
    //      falloff sphere anchor from here on) and the ordinary relocate pin
    //      (`notifyAcenUserPlaced`, which the OTHER modes read and which the
    //      Element arm keeps as its second tier).
    //   2. FalloffStage.anchorRing ← picked element's vert indices
    //      (every one gets weight=1 in elementWeight, so the picked
    //      element drags as a rigid unit regardless of sphere radius).
    // Piece 2 is skipped when `stage` is null (Element ACEN armed without an
    // Element falloff — see tryPickElement's gate).

    /// Write the picked anchor into ACEN, skipping a write of the point
    /// already frozen. The skip lives HERE and not inside `setUserPlaced`: that
    /// setter also stages the in-session-cancel baseline for every relocate
    /// caller in the editor, and widening the skip to all of them would be a
    /// far larger radius than the behaviour it buys.
    private void writeElementAnchor(Vec3 anchor) {
        if (acenHoldsElementPin(anchor)) return;   // equal write skipped
        notifyAcenUserPlaced(anchor);
        notifyAcenElementPin(anchor);
    }

    bool takeVert(FalloffStage stage, int vi) {
        writeElementAnchor(mesh.vertices[vi]);
        if (stage !is null) {
            stage.anchorRing = [cast(uint)vi];
            updateConnectMask(stage, vi);
        }
        return true;
    }

    bool takeEdge(FalloffStage stage, int ei) {
        auto edge = mesh.edges[ei];
        // Anchor = edge midpoint (centroid of the two endpoints),
        // click-independent — `edgeCentroid` (mesh_ops/connected_mask.d), a
        // free function over `ref const(Mesh)` since task 1903 Stage D1.
        // `mesh` is a `Mesh*`: the member call auto-dereferenced, the UFCS
        // free function does not — hence `(*mesh).`.
        writeElementAnchor((*mesh).edgeCentroid(cast(uint)ei));
        if (stage !is null) {
            stage.anchorRing = [cast(uint)edge[0], cast(uint)edge[1]];
            updateConnectMask(stage, cast(int)edge[0]);
        }
        return true;
    }

    bool takeFace(FalloffStage stage, int fi) {
        // Anchor = face centroid (vertex average), click-independent.
        writeElementAnchor(mesh.faceCentroid(cast(uint)fi));
        auto face = mesh.faces[fi];
        if (stage !is null) {
            stage.anchorRing = face.dup;
            if (face.length > 0)
                updateConnectMask(stage, cast(int)face[0]);
        }
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


    // Connected-component BFS seeded at the picked vert, written into
    // FalloffStage.connectMask. Active only when connect != Ignore.
    // The BFS itself moved to `connectedComponentMask`
    // (source/mesh_ops/connected_mask.d, xfrm Phase B) — this wrapper keeps
    // the Ignore / seed-bounds guards and the stage write. Task 1903 Stage D1
    // turned it into a free function over `ref Mesh` (it calls the memoizing
    // `vertexAdjacencyCSR`, so it cannot be `const`); it writes nothing and
    // opens no edit batch. `(*mesh).` below: UFCS does not deref a `Mesh*`.
    void updateConnectMask(FalloffStage stage, int seedVi) {
        if (stage.connect == ElementConnect.Ignore) {
            stage.connectMask = null;
            return;
        }
        if (seedVi < 0 || seedVi >= cast(int)mesh.vertices.length) {
            stage.connectMask = null;
            return;
        }
        stage.connectMask = (*mesh).connectedComponentMask(cast(size_t)seedVi);
    }

    FalloffStage activeFalloffStage() const {
        if (g_pipeCtx is null) return null;
        return cast(FalloffStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    }

    /// True iff an Element FALLOFF is armed right now. Task 1530 — the pick
    /// itself no longer needs one (its gate is the ACEN mode), but the
    /// screen-plane haul an element click opens still does: without a falloff
    /// there is no attenuation, so the "haul" would drag the entire moving set
    /// (empty selection ⇒ the whole mesh) off a pivot click.
    private bool elementFalloffActive() const {
        auto st = activeFalloffStage();
        return st !is null && st.type == FalloffType.Element;
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

    // The single AXIS stage — read by the slot-activation poll (task 0791) to
    // notice which axis tool sits in the slot.
    AxisStage activeAxisStage() const {
        if (g_pipeCtx is null) return null;
        return cast(AxisStage) g_pipeCtx.pipeline.findByTask(TaskCode.Axis);
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
    // 3D snap delta (`MoveTool.constrainSnapDelta` returns delta unchanged) and
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
    // It DELIBERATELY drops the `pressPlacesCenter()` gate the old per-bank
    // calls carried — that gate admits only Auto/None/Screen and is exactly what
    // excluded Border (the flex mode) today. The ONLY exclusion is the 2-entry
    // `acenSettleAllowed()` predicate (Element + Local — modes with a
    // higher-precedence LIVE pivot source). RETURNS the `Pin` the caller's
    // undo hook should restore as the gesture-END soft state, so the splice
    // carries the pin in lockstep with the geometry. When the settle is not
    // allowed it pins nothing and returns `Pin.init` (placed = false).
    //
    // Returns rather than fills two `out` params (task 0724 / audit-4 P6).
    // Three of the four callers immediately packed the pair back into a
    // `Pin(...)` and the fourth declared `bool _sp; Vec3 _sc;` purely to throw
    // them away — the signature was making every caller do work to undo it.
    // The `out` form was also the riskier one in D: `out` resets its argument
    // to `T.init` on entry, so a caller reusing a live variable silently lost
    // it before the first line of the body ran.
    Pin settleGestureCenter(Vec3 settledCenter) {
        auto ac = activeAcenStage();
        if (ac is null) return Pin.init;
        if (!ac.acenSettleAllowed()) return Pin.init;
        ac.setSoftPlaced(settledCenter);
        return ac.currentSoftPin();
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


    // Task 0234 (GET /api/tool/state): active bank + drag axis + pivot.
    // `activeBank` is "none" while idle (mouse motion goes to every enabled
    // sub-tool for hover-preview, per the `activeDrag` doc comment below);
    // `dragAxis` mirrors whichever sub-tool's own convention is live (-1
    // idle). `pivot` reads the shared gizmo center — every enabled bank's
    // handler is posed to the same center each frame by `setSharedGizmoPose`,
    // so reading it off `moveSub` is bank-agnostic as long as T is enabled;
    // when only R/S are enabled (T off) `moveGizmoCenter()` still holds the
    // right value because `moveSub` exists (composed unconditionally) and is
    // posed alongside the enabled banks — only its GIZMO isn't drawn/hit-tested.
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"] = JSONValue("xfrm");
        auto enabled = JSONValue.emptyObject;
        enabled["t"] = JSONValue(flagT);
        enabled["r"] = JSONValue(flagR);
        enabled["s"] = JSONValue(flagS);
        root["enabled"] = enabled;
        string bankName = "none";
        int    dragAxis = -1;
        if (activeDrag is moveSub)        { bankName = "move";   dragAxis = moveSub.dragAxisPublic(); }
        else if (activeDrag is rotateSub) { bankName = "rotate"; dragAxis = rotateSub.dragAxisPublic(); }
        else if (activeDrag is scaleSub)  { bankName = "scale";  dragAxis = scaleSub.dragAxisPublic(); }
        root["activeBank"] = JSONValue(bankName);
        root["dragAxis"]   = JSONValue(dragAxis);
        root["dragging"]   = JSONValue(activeDrag !is null);
        root["editOpen"]   = JSONValue(editIsOpen());
        Vec3 pivot = moveGizmoCenter();
        root["pivot"] = JSONValue([JSONValue(pivot.x), JSONValue(pivot.y), JSONValue(pivot.z)]);
        // The relocate-order witness must read the handler that consumed the
        // press; `pivot` is the Move bank's idle pose, not an R/S witness.
        Vec3 handlerPivot = pivot;
        if (activeDrag is rotateSub)       handlerPivot = rotateSub.handler.center;
        else if (activeDrag is scaleSub)  handlerPivot = scaleSub.handler.center;
        root["handlerPivot"] = JSONValue([
            JSONValue(handlerPivot.x), JSONValue(handlerPivot.y), JSONValue(handlerPivot.z)]);
        // Task 0614 Phase 3 — expose which subject the apply path is
        // targeting, so a test can assert the item branch engaged rather
        // than inferring it indirectly from a byte-identical vertex diff.
        root["subject"] = JSONValue(cachedSubjType_ == SelType.Item ? "item" : "component");
        // Echo the frozen run frame (R11/Phase 2.5), so a test can prove an
        // item run actually froze one rather than silently falling back to a
        // live re-derived basis every frame.
        auto runFrameObj = JSONValue.emptyObject;
        runFrameObj["valid"]  = JSONValue(runFrameValid);
        runFrameObj["origin"] = JSONValue([JSONValue(runFrameOrigin.x), JSONValue(runFrameOrigin.y), JSONValue(runFrameOrigin.z)]);
        runFrameObj["right"]  = JSONValue([JSONValue(runFrameR.x), JSONValue(runFrameR.y), JSONValue(runFrameR.z)]);
        runFrameObj["up"]     = JSONValue([JSONValue(runFrameU.x), JSONValue(runFrameU.y), JSONValue(runFrameU.z)]);
        runFrameObj["fwd"]    = JSONValue([JSONValue(runFrameF.x), JSONValue(runFrameF.y), JSONValue(runFrameF.z)]);
        root["runFrame"] = runFrameObj;
        // Task 4691: expose the last VALUE batch's causal write-set separately
        // from the held canonical TRS values.  Tests use the cumulative fold
        // count to prove one geometry fold per accepted value batch.
        auto replay = JSONValue.emptyObject;
        replay["source"] = JSONValue(lastValueReplayValid
            ? replaySourceName(lastValueReplaySource) : "none");
        replay["cause"] = JSONValue(replayBankName(lastValueReplayCause));
        JSONValue[] channels;
        channels.reserve(lastValueReplayChannels.length);
        foreach (channel; lastValueReplayChannels)
            channels ~= JSONValue(channel);
        replay["channels"] = JSONValue(channels);
        replay["folds"] = JSONValue(cast(long)valueReplayFolds);
        root["valueReplay"] = replay;
        return root;
    }

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

    // Task 0791 — the slot-activation latches. Both re-latch (without firing)
    // on the first poll after the tool arms, so a slot change made while no
    // transform tool was armed is never read as an activation of ITS run.
    //   * `lastSlotSig` folds every stage's slot-arming write counter;
    //   * `lastAcenEpoch` is the action centre's own counter as of the last
    //     poll — it is how the boundary tells a pivot-moving activation from
    //     one that must leave the gizmo alone.
    // `lastSlotSigValid` is the signature's "-1": a hash has no spare value.
    ulong lastSlotSig      = 0;
    bool  lastSlotSigValid = false;
    uint  lastAcenEpoch    = 0;

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
    //
    // NOT a `mesh.MeshKey` (task 4060, declined at its declaration): its
    // `ulong.max` MEANS "disarmed", not "never stamped", and it has no
    // address term to fold in — adding one would change when a re-grade goes
    // inert. Same argument as `TransformTool.lastMutationVersion`.
    ulong lastAppliedGestureMutationVersion = ulong.max;

    // armedUndoEpoch — TASK 1906 §2.3, THE CENSUS'S SECOND TERM. Not a guard:
    // nothing branches on it, and the shipped staleness decision is still the
    // `mutationVersion` compare above, byte for byte.
    //
    // Task 1906 moves every POSITION-dependent cache off the version counters
    // and onto the change bus. This stamp is the recorded remainder — it is a
    // GESTURE-IDENTITY guard ("has a foreign edit landed since my gesture
    // committed?"), not a cache freshness key, and the bus has no class for
    // "someone other than me edited". The guard's own doc block names the
    // event it is detecting: an in-session Ctrl+Z that pops a gesture. That
    // event has a name of its own — `CommandHistory.undoEpoch()`, bumped
    // exactly once per successful `undo()` and by nothing else — and this
    // field is that name, stamped at the same instant.
    //
    // The equivalence is MEASURED before it is relied on: see
    // `regradeStampCurrent()` and `change_bus.regradeCensusChecks` /
    // `regradeCensusDisagreements`, read over `/api/changes`. Armed and
    // disarmed ONLY beside `lastAppliedGestureMutationVersion`, at all five of
    // its write sites; a term armed at a different moment would make the
    // census measure its own bookkeeping instead of the claim.
    ulong armedUndoEpoch = ulong.max;

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
        const bool disarm = hasFlag(ToolFlag.BrushReset);
        lastAppliedGestureMutationVersion = disarm ? ulong.max : mesh.mutationVersion;
        // Task 1906 §2.3 — the census's OTHER term, armed in the SAME
        // statement pair so the two can never be armed at different moments.
        // `ulong.max` is the disarmed sentinel on BOTH: `undoEpoch()` counts
        // from 0 and cannot reach it, exactly as `mutationVersion` cannot, so
        // a disarmed stamp reads false on both terms and the two AGREE while
        // disarmed rather than disagreeing vacuously.
        armedUndoEpoch = (disarm || history is null)
                       ? ulong.max : history.undoEpoch();
    }

    // regradeStampCurrent — THE re-grade staleness predicate, and the ONLY
    // place the four read sites evaluate it (task 1906 §2.3).
    //
    // The RETURNED VALUE is exactly the shipped term,
    // `mesh.mutationVersion == lastAppliedGestureMutationVersion`, unchanged:
    // this refactor moves no decision. What it adds is the CENSUS — the
    // measurement of whether that term could be replaced by the undo-epoch
    // term the guard's own doc block describes. See `armedUndoEpoch` for the
    // claim and `change_bus.regradeCensusChecks` for why the verdict is a
    // counter and never an `assert`.
    //
    // The census is skipped when `history is null` — three of the four sites
    // short-circuit on that before ever reaching the version term, so counting
    // there would census a comparison the product does not make. It is `const`
    // because two of the four sites are (`refireRotateEligible` /
    // `refireScaleEligible`); the counters are module-level `__gshared`, not
    // fields, so incrementing them from a `const` method is well-formed.
    //
    // THE ARMED ROW IS THE ONLY ROW THAT CAN DISAGREE (review B1). While the
    // stamp is DISARMED both terms hold the same `ulong.max` sentinel, both
    // compares answer false, and the row is scored as an agreement it could
    // not have avoided. `regradeCensusArmedChecks` counts only the rows where
    // the stamp is armed, and that — not `regradeCensusChecks` — is the
    // denominator the test's floor reads. Keyed on the SHIPPED term's arm
    // state (`lastAppliedGestureMutationVersion != ulong.max`), so deleting
    // `armedUndoEpoch`'s arm reddens the verdict instead of emptying the
    // denominator.
    //
    // MEASURED: on this tree the two counts are EQUAL — 117 of 117, 120 of
    // 120 (the absolute count is an idle-frame count and varies; the ratio is
    // 1). The only live read site is ARM-2, which short-circuits on
    // `history.runOpen()`, and an open run implies a gesture that armed the
    // stamp. The armed counter is a guarantee, not a filter. See
    // `change_bus.regradeCensusArmedChecks`.
    private bool regradeStampCurrent() const {
        // recorded remainder (1906 §3.6): `mutationVersion` owns this compare
        // and KEEPS it. It is a GESTURE IDENTITY stamp, not a cache key — "is
        // the mesh still at the state my last apply left it in?" — and §2.3's
        // census (run 2026-08-25) found the two candidate terms UNDECIDABLE at
        // this read site rather than equal: the only cell where the version
        // term and the undo-epoch term could differ is never evaluated. An
        // undecidable equivalence is not a licence to substitute. Plan §3.4
        // row 21.
        const bool armed = (lastAppliedGestureMutationVersion != ulong.max);
        const bool byVersion =
            (mesh.mutationVersion == lastAppliedGestureMutationVersion);
        if (history !is null) {
            import change_bus : regradeCensusChecks, regradeCensusArmedChecks,
                                regradeCensusDisagreements;
            const bool byEpoch = (history.undoEpoch() == armedUndoEpoch);
            ++regradeCensusChecks;
            if (armed) ++regradeCensusArmedChecks;
            if (byVersion != byEpoch) ++regradeCensusDisagreements;
        }
        return byVersion;
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

    // foldSrc_ — reused per-frame gather buffer for applyFold's ordinal-parallel
    // baseline source (moving-set length). `applyFold` used to `new Vec3[]`
    // this every motion event; on a whole-mesh drag (~100K verts) that is a
    // ~1.2 MB/frame allocation that trips the GC over a multi-event drag
    // (task 0202). Owned here, guarded-resized (grows/shrinks only when the
    // moving-set length changes — constant within one drag) and filled in
    // place every frame — contents are byte-identical to the old fresh
    // allocation. Main-thread only: `applyFold` runs on the SDL dispatch
    // thread only (the HTTP thread never calls into the tool's geometry
    // path), so no lock is needed. Cleared (not merely left stale) on
    // transient reset so an idle tool does not pin ~1.2 MB between drags;
    // the next drag's first frame re-allocates cold (see task 0202 plan,
    // "Cold re-alloc per drag" risk note — well below the GC pool
    // threshold).
    private Vec3[] foldSrc_;

    // Detect a bank switch at gizmo mouse-down and consolidate the prior run.
    // Called from each mouse-down consume arm AFTER the sub-tool confirmed the
    // click landed on its bank, BEFORE begin*DragSession. An empty/not-yet-open
    // run consolidates to nothing (safe no-op) — the gather finds no matching
    // in-session tail. Always (re)sets currentRunBank to this arm's bank so the
    // next gesture extends the same single-bank run.
    private void noteRunBank(DragBank thisBank) {
        if (currentRunBank != DragBank.None && currentRunBank != thisBank) {
            consolidateRunAndAdvance();
            // A bank switch is a run boundary: the prior run's re-grade anchor +
            // staleness stamp must not leak into the new run.
            invalidateRunRefireAnchor();
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
    private PipeRefireProjection projectPipeRefire(
            const Vec3[] anchor, const Vec3[] after, const size_t[] idx,
            FalloffPacket preF, FalloffPacket postF,
            SnapPacket preSn, SnapPacket postSn,
            SymmetryPacket preSy, SymmetryPacket postSy) {
        PipeRefireProjection p;
        if (!regradeStampCurrent()) {
            p.stale = p.valid = true;
            return p;
        }
        if (history is null || vertexEditFactory is null ||
            !history.runOpen() || anchor.length != mesh.vertices.length ||
            (idx.length == 0 ? after.length != mesh.vertices.length
                             : after.length != idx.length))
            return p;

        auto image = &p.state;
        image.expectedAnchor = refireAnchor.dup;
        image.nextAnchor = refireAnchor.length == 0
            ? anchor.dup : refireAnchor.dup;
        image.expectedPreValid = refirePreValid;
        image.nextPreValid = true;
        image.expectedPreFalloff = refirePreFalloff.ownedDup();
        image.expectedPreSnap = refirePreSnap;
        image.expectedPreSymmetry = refirePreSym.ownedDup();
        if (refirePreValid) {
            preF = refirePreFalloff;
            preSn = refirePreSnap;
            preSy = refirePreSym;
        }
        image.nextPreFalloff = preF.ownedDup();
        image.nextPreSnap = preSn;
        image.nextPreSymmetry = preSy.ownedDup();
        image.expectedLastMutation = lastMutationVersion;
        image.expectedGestureMutation = lastAppliedGestureMutationVersion;
        image.expectedUndoEpoch = armedUndoEpoch;
        image.nextLastMutation = mesh.mutationVersion;
        image.nextGestureMutation = mesh.mutationVersion;
        image.nextUndoEpoch = history.undoEpoch();

        const fullRange = idx.length == 0;
        const n = fullRange ? after.length : idx.length;
        uint[] movedIdx;
        Vec3[] before;
        Vec3[] movedAfter;
        movedIdx.reserve(n);
        before.reserve(n);
        movedAfter.reserve(n);
        foreach (k; 0 .. n) {
            const vid = fullRange ? k : idx[k];
            if (vid >= image.nextAnchor.length ||
                vid >= mesh.vertices.length) continue;
            const a = after[k];
            const b = image.nextAnchor[vid];
            if (a == b) continue;
            movedIdx ~= cast(uint)vid;
            before ~= b;
            movedAfter ~= a;
        }

        p.command = vertexEditFactory();
        if (p.command is null) return PipeRefireProjection.init;
        p.command.setEdit(movedIdx, before, movedAfter, name());

        const preFCopy = preF.ownedDup();
        const postFCopy = postF.ownedDup();
        const preSnCopy = preSn, postSnCopy = postSn;
        const preSyCopy = preSy.ownedDup();
        const postSyCopy = postSy.ownedDup();
        const xfNow = run;
        const frameNow = frame;
        p.command.setHooks(
            () {
                restoreFalloffSetFromCombined(activeFalloffStages(), postFCopy);
                if (auto sn = activeSnapStage())
                    sn.restoreConfigFromPacket(postSnCopy);
                if (auto sy = activeSymmetryStage())
                    sy.restoreConfigFromPacket(postSyCopy);
                run = xfNow;
                headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameNow;
                refreshFrameValid();
            },
            () {
                restoreFalloffSetFromCombined(activeFalloffStages(), preFCopy);
                if (auto sn = activeSnapStage())
                    sn.restoreConfigFromPacket(preSnCopy);
                if (auto sy = activeSymmetryStage())
                    sy.restoreConfigFromPacket(preSyCopy);
                run = xfNow;
                headlessRotate = eulerZYXFromMatrix(run.r);
                frame = frameNow;
                refreshFrameValid();
            });
        image.valid = true;
        p.valid = true;
        return p;
    }

    private void recordPipeRefire(Vec3[] anchor,
                                  Vec3[] after, size_t[] idx, DragBank,
                                  FalloffPacket preF, FalloffPacket postF,
                                  SnapPacket preSn, SnapPacket postSn,
                                  SymmetryPacket preSy, SymmetryPacket postSy) {
        auto projection = projectPipeRefire(anchor, after, idx,
            preF, postF, preSn, postSn, preSy, postSy);
        if (!projection.valid) return;
        if (projection.stale) {
            refireAnchor.length = 0;
            refirePreValid = false;
            return;
        }
        recordTransformCommand(
            projection.command, TransformHistoryIntent.GenerationRefire);
        installPreparedRefireState(projection.state);
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

    // ── Task 1069: the routing seam's tool-side half ───────────────────────

    /// Capture `dragMorphBaseline` from `base` (the TRUE base array) plus the
    /// bound map's CURRENT stored values. No target bound ⇒ the array is
    /// dropped and routing stays inert.
    private void captureMorphRunBaseline(const(Vec3)[] base) {
        import morph_target : resolveMorphTarget;
        import mesh_morph   : morphApply;
        import mesh         : MapKind;
        morphRunValid_ = false;
        dragMorphBaseline.length = 0;
        string nm; MapKind kind;
        if (!resolveMorphTarget(mesh, nm, kind)) return;
        if (base.length != mesh.vertices.length) return;
        auto map = mesh.morphMapForWrite(nm);
        if (map is null) return;
        dragMorphBaseline.length = base.length;
        foreach (i; 0 .. base.length)
            dragMorphBaseline[i] = morphApply(base[i],
                                              map.entryOr(i, defaultStored(base[i], kind)),
                                              kind, 1.0f);
        morphRunValid_ = true;
    }

    /// Build the route for THIS apply. `base` is whatever array this apply is
    /// evaluating from — `dragBaseline` for a live drag, a fresh
    /// `mesh.vertices.dup` for the one-shot headless/panel path — and it is
    /// the TRUE base either way, because the routed path never writes
    /// `mesh.vertices`.
    ///
    /// Returns `MorphRoute.init` (inert) when no target is bound, which is
    /// what keeps every non-routed drag byte-identical to before this task.
    protected MorphRoute buildMorphRouteFor(const(Vec3)[] base) {
        import morph_target : resolveMorphTarget;
        import mesh         : MapKind;
        MorphRoute r;
        string nm; MapKind kind;
        if (!resolveMorphTarget(mesh, nm, kind)) return r;
        if (base.length != mesh.vertices.length) return r;
        // A one-shot apply with no open run has no captured run baseline yet;
        // capture it here, ONCE. Doing this per apply would be the accumulate
        // bug in miniature — mid-drag the live map already holds THIS
        // gesture's partial delta, so re-deriving `runPos` from it every apply
        // would make the gesture accumulate against itself.
        if (!morphRunValid_ || dragMorphBaseline.length != mesh.vertices.length)
            captureMorphRunBaseline(base);
        if (!morphRunValid_) return r;
        r.kind   = kind;
        r.name   = nm;
        r.base   = base;
        r.runPos = dragMorphBaseline;
        return r;
    }

    /// True when this apply will route — used by the commit / cancel paths to
    /// choose the morph command over the vertex one.
    public bool morphRoutingActive() {
        import morph_target : resolveMorphTarget;
        import mesh         : MapKind;
        string nm; MapKind kind;
        return resolveMorphTarget(mesh, nm, kind);
    }

    // Task 1069 — the ROUTED run baseline: every vertex's DISPLAYED position
    // (base + the target map's value) at run start, mesh-length and
    // vertex-id indexed, exactly like `dragBaseline`.
    //
    // It is a SECOND array on purpose. The tempting shortcut — write the
    // morphed position into `dragBaseline` itself — is a data-corrupting bug,
    // not a simplification: `applyTRS` calls `restoreBaseline()` from
    // `dragBaseline` on EVERY apply including the last of the gesture, and the
    // routed kernel branch never writes `mesh.vertices`, so nothing would
    // overwrite it. `mesh.vertices` would hold the morphed position for the
    // whole gesture and after it, law L2's "the base is untouched" would fail
    // on the first apply, and the NEXT gesture's rebake would re-capture the
    // already-morphed position as its base and stack a second delta on the
    // first. `edits_accumulate` is the test that catches the second half.
    Vec3[] dragMorphBaseline;

    // Validity flag for `dragMorphBaseline`, cleared by `resetRun()` on the
    // same geometry-run boundary as `runBaselineValid` — a fresh run must
    // re-read the map, or gesture 2 evaluates from gesture 1's start.
    bool morphRunValid_ = false;

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

    float[16] projectedGpuMatrix(out bool write) const nothrow @nogc {
        write = false;
        if (activeDrag is moveSub) return gpuMatrix;
        if (activeDrag is rotateSub && rotDragAxisIdx >= 0 && rotDragAxisIdx <= 3)
            return gpuMatrix;
        if (activeDrag is scaleSub && scaleDragActive) return gpuMatrix;
        write = true;
        if (activeDrag !is null) return activeDrag.gpuMatrix;
        if (flagT) return moveSub.gpuMatrix;
        if (flagR) return rotateSub.gpuMatrix;
        if (flagS) return scaleSub.gpuMatrix;
        return gpuMatrix;
    }
}

unittest {
    import change_bus : changeBus;

    Mesh owned;
    EditMode mode = EditMode.Vertices;
    auto tool = new XfrmTransformTool(() => &owned, null, &mode);
    tool.uniform = true;
    tool.uniformVal = 2.5f;
    tool.run.s = Vec3(7, 8, 9);
    auto prepared = tool.prepareParamState("uniformScale");
    assert(tool.run.s == Vec3(7, 8, 9));
    assert(Vec3(prepared.x, prepared.y, prepared.z) == Vec3(2.5f, 2.5f, 2.5f));
    XfrmPreparedState handle;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    assert(tool.run.s == Vec3(2.5f, 2.5f, 2.5f));

    // The activation transaction reaches the same typed producer through the
    // interface, without invoking the legacy hook on the unpublished tool.
    tool.uniformVal = 3.5f;
    tool.run.s = Vec3(1, 1, 1);
    assert(tool.prepareDoorParamChanged("uniformScale", null, null, 0, 0));
    assert(tool.run.s == Vec3(3.5f, 3.5f, 3.5f),
        "candidate-local parameter door omitted the prepared install");
    tool.run.s = Vec3(8, 8, 8);
    tool.installLegacyPreparedState(handle);
    assert(tool.run.s == Vec3(8, 8, 8));

    auto absent = tool.prepareParamState("SX");
    assert(absent.kind == PreparedToolStateKind.None);
    assert(tool.validatePreparedState(absent, handle));
    tool.installLegacyPreparedState(handle);
    assert(tool.run.s == Vec3(8, 8, 8));

    tool.uniform = false;
    auto disabled = tool.prepareParamState("uniformScale");
    assert(disabled.kind == PreparedToolStateKind.None);

    // Selection/mutation update boundary: capture the record flags at the
    // exact update() site, before closeRunBoundary() erases that distinction.
    // A foreign command cannot witness this because CommandHistory's append
    // guard consolidates first. The open Move edit must land in-session.
    import command_history : HistoryFlags;
    import view : View;
    Mesh selectionBoundaryMesh = makeCube();
    selectionBoundaryMesh.resetSelection();
    GpuMesh selectionBoundaryGpu;
    EditMode selectionBoundaryMode = EditMode.Vertices;
    auto selectionBoundaryView = new View(0, 0, 800, 600);
    auto selectionBoundaryHistory = new CommandHistory();
    auto selectionBoundaryTool = new XfrmTransformTool(
        () => &selectionBoundaryMesh, &selectionBoundaryGpu,
        &selectionBoundaryMode);
    selectionBoundaryTool.flagT = true;
    selectionBoundaryTool.flagR = false;
    selectionBoundaryTool.flagS = false;
    selectionBoundaryTool.setUndoBindings(selectionBoundaryHistory,
        () => new MeshVertexEdit(&selectionBoundaryMesh,
                                 selectionBoundaryView,
                                 selectionBoundaryMode));
    selectionBoundaryTool.activate();
    VectorStack selectionBoundaryVts;
    selectionBoundaryTool.update(selectionBoundaryVts);
    selectionBoundaryTool.openLiveSessionForTest();
    selectionBoundaryMesh.vertices[0].x += 1;
    uint boundaryRecordFlags;
    size_t boundaryRecords;
    selectionBoundaryHistory.onRecord = (string, uint flags) {
        boundaryRecordFlags = flags;
        ++boundaryRecords;
    };
    selectionBoundaryMesh.selectVertex(0);
    selectionBoundaryTool.update(selectionBoundaryVts);
    assert(boundaryRecords == 1,
        "selection boundary must record the non-empty open Move edit once");
    assert((boundaryRecordFlags & HistoryFlags.InSession) != 0,
        "selection boundary must close its open edit with RunClose intent");

    foreach (mask; 0 .. 8) foreach (routeMask; 0 .. 8)
        foreach (preserveDisplay; [false, true])
        foreach (hadRun; [false, true]) {
        auto resetTool = new XfrmTransformTool(() => &owned, null, &mode);
        resetTool.flagT = (mask & 1) != 0;
        resetTool.flagR = (mask & 2) != 0;
        resetTool.flagS = (mask & 4) != 0;
        const bool moveRoute = (routeMask & 1) != 0;
        const bool rotateRoute = (routeMask & 2) != 0;
        const bool scaleRoute = (routeMask & 4) != 0;
        resetTool.seedPreparedActivationResetForTest(preserveDisplay, hadRun,
            moveRoute, rotateRoute, scaleRoute);
        auto image = resetTool.buildPreparedActivationReset();
        assert(image.valid && resetTool.preparedActivationResetSeedForTest(),
            "Xfrm activation reset preparation mutated live state");
        resetTool.installPreparedActivationResetPre(image);
        assert(image.valid && resetTool.preparedActivationResetPreForTest(
            preserveDisplay, hadRun));
        resetTool.installPreparedActivationResetPost(image);
        assert(!image.valid && resetTool.preparedActivationResetPostForTest(
            moveRoute, rotateRoute, scaleRoute));
        resetTool.installPreparedActivationResetPre(image);
        resetTool.installPreparedActivationResetPost(image);
        assert(resetTool.preparedActivationResetPostForTest(
            moveRoute, rotateRoute, scaleRoute),
            "consumed Xfrm reset image installed twice");
    }

    // Refire preparation runs the canonical fold on an isolated mesh.  A
    // non-symmetric vertex distinguishes a real 90-degree apply from a copied
    // candidate while the source must remain byte-identical.
    import math : matrixFromEulerZYX;
    Mesh refireMesh = makeCube();
    refireMesh.vertices[0] = Vec3(-2, -1, -1);
    auto beforeRefire = MeshSnapshot.capture(refireMesh);
    GpuMesh refireGpu;
    EditMode refireMode = EditMode.Vertices;
    auto refireTool = new XfrmTransformTool(
        () => &refireMesh, &refireGpu, &refireMode);
    refireTool.flagT = false;
    refireTool.flagR = true;
    refireTool.flagS = false;
    refireTool.run.r = matrixFromEulerZYX(Vec3(0, 0, 90));
    refireTool.headlessRotate = Vec3(0, 0, 90);
    refireTool.dragBaseline = refireMesh.vertices.dup;
    refireTool.runBaselineValid = true;
    refireTool.runFrameValid = true;
    auto refired = refireTool.buildPreparedRefireCandidate(
        FalloffPacket.init, SnapPacket.init, SymmetryPacket.init);
    assert(refired.applied && beforeRefire.matches(refireMesh) &&
           refired.mesh.vertices != refireMesh.vertices,
           "prepared Xfrm refire must mutate only the detached candidate");

    // Idle selection boundary: preparation owns the complete reset image and
    // performs no live write. A post-prepare latch mutation must refuse; the
    // untouched image then resets the active run exactly once.
    auto boundaryTool = new XfrmTransformTool(
        () => &refireMesh, &refireGpu, &refireMode);
    boundaryTool.seedPreparedUpdateBoundaryForTest(11, 12);
    PreparedXfrmUpdatePreProjection boundaryProjection;
    boundaryProjection.valid = true;
    boundaryProjection.selectionBoundary = true;
    boundaryProjection.selectionChanged = true;
    boundaryProjection.selectionHash = 21;
    boundaryProjection.mutationVersion = 22;
    auto boundary = boundaryTool.buildPreparedUpdateBoundary(boundaryProjection);
    assert(boundary.valid && boundaryTool.run.t == Vec3(3, 4, 5),
        "prepared Xfrm boundary mutated the live run");
    boundaryTool.seedPreparedUpdateBoundaryForTest(99, 12);
    assert(!boundaryTool.preparedUpdateBoundaryMatches(boundary),
        "prepared Xfrm boundary accepted a stale selection latch");
    boundaryTool.seedPreparedUpdateBoundaryForTest(11, 12);
    assert(boundaryTool.preparedUpdateBoundaryMatches(boundary));
    boundaryTool.installPreparedUpdateBoundary(boundary);
    ulong installedSelection, installedMutation;
    assert(!boundary.valid && boundaryTool.preparedUpdateBoundaryInstalledForTest(
        installedSelection, installedMutation) && installedSelection == 21 &&
        installedMutation == 22,
        "prepared Xfrm boundary did not install the complete run reset");
    boundaryTool.installPreparedUpdateBoundary(boundary);
    assert(boundaryTool.preparedUpdateBoundaryInstalledForTest(
        installedSelection, installedMutation) && installedSelection == 21 &&
        installedMutation == 22,
        "consumed Xfrm boundary image installed twice");

    // Wrapper replay runs the fold on an isolated wrapper, including its cache
    // outputs. The mesh resource remains a separate context entry, so direct
    // state installation below must not write the live mesh.
    Mesh replayMesh = makeCube();
    auto replayBefore = MeshSnapshot.capture(replayMesh);
    auto replayTool = new XfrmTransformTool(
        () => &replayMesh, &refireGpu, &refireMode);
    replayTool.flagT = true;
    replayTool.flagR = false;
    replayTool.flagS = false;
    replayTool.run.t = Vec3(2, 0, 0);
    replayTool.dragBaseline = replayMesh.vertices.dup;
    replayTool.runBaselineValid = true;
    replayTool.runFrameValid = true;
    PreparedXfrmUpdatePreProjection regradeProjection;
    regradeProjection.valid = true;
    regradeProjection.panelRegrade = true;
    auto regrade = replayTool.buildPreparedReplay(
        regradeProjection, null);
    assert(regrade.valid && regrade.meshPrepared &&
        replayBefore.matches(replayMesh) &&
        regrade.candidate.vertices != replayMesh.vertices,
        "prepared wrapper replay must own a detached changed candidate");
    assert(replayTool.preparedReplayMatches(regrade, replayMesh));
    replayMesh.vertices[0].x += 1;
    assert(!replayTool.preparedReplayMatches(regrade, replayMesh),
        "prepared wrapper replay accepted a stale live mesh");
    replayBefore.restore(replayMesh);
    replayTool.installPreparedReplay(regrade);
    assert(!regrade.valid && replayBefore.matches(replayMesh),
        "wrapper replay private-state install wrote the live mesh");
    replayTool.installPreparedReplay(regrade);
    assert(replayBefore.matches(replayMesh),
        "consumed wrapper replay image installed twice");

    // Complete-root idle cell: one no-history marker followed by the slot
    // latch, Move refresh and wrapper tail. Preparation leaves both mesh and
    // tool live state untouched; the context validates and installs once.
    auto rootLayer = new Layer();
    rootLayer.meshRef() = makeCube();
    auto rootBefore = MeshSnapshot.capture(rootLayer.meshRef());
    GpuMesh rootGpu;
    EditMode rootMode = EditMode.Vertices;
    auto rootTool = new XfrmTransformTool(
        () => &rootLayer.meshRef(), &rootGpu, &rootMode);
    rootTool.flagT = true;
    rootTool.flagR = false;
    rootTool.flagS = false;
    rootTool.activate();
    VectorStack rootVts;
    auto rootContext = new PreparedRecordContext(null, null);
    auto rootEffect = rootTool.prepareUpdate(
        rootVts, rootContext, rootLayer, null);
    assert(rootEffect.accepted && rootBefore.matches(rootLayer.meshRef()),
        "complete Xfrm update root mutated live state during preparation");
    assert(rootContext.validate());
    rootContext.install();
    assert(rootContext.installTraceForTest() == [8, 60, 62, 61, 16, 59],
        "complete Xfrm idle root installed out of legacy order");
    rootContext.install();
    assert(rootContext.installTraceForTest() == [8, 60, 62, 61, 16, 59],
        "complete Xfrm update root installed twice");

    // The preview arm never touches GL: it commits Position on the detached
    // cage image and publishes exactly one delivery before the sub-tool poll.
    auto suppressLayer = new Layer();
    suppressLayer.meshRef() = makeCube();
    const suppressVersion = suppressLayer.meshRef().mutationVersion;
    const suppressDeliveries = changeBus.deliveryCount;
    const suppressPositions = changeBus.totalPosition;
    GpuMesh suppressGpu;
    suppressGpu.suppressCageUpload = true;
    EditMode suppressMode = EditMode.Vertices;
    auto suppressTool = new XfrmTransformTool(
        () => &suppressLayer.meshRef(), &suppressGpu, &suppressMode);
    suppressTool.flagT = true;
    suppressTool.flagR = false;
    suppressTool.flagS = false;
    suppressTool.activate();
    suppressTool.seedPreparedWrapperUploadForTest();
    VectorStack suppressVts;
    auto suppressContext = new PreparedRecordContext(null, null);
    auto suppressEffect = suppressTool.prepareUpdate(
        suppressVts, suppressContext, suppressLayer, null);
    assert(suppressEffect.accepted &&
        suppressLayer.meshRef().mutationVersion == suppressVersion &&
        changeBus.deliveryCount == suppressDeliveries,
        "prepared suppress-cage update mutated live state");
    assert(suppressContext.validate());
    suppressContext.install();
    assert(suppressContext.installTraceForTest() ==
        [8, 60, 62, 61, 3, 4, 16, 59],
        "suppress-cage update installed out of legacy order");
    assert(suppressLayer.meshRef().mutationVersion == suppressVersion + 1 &&
        changeBus.deliveryCount == suppressDeliveries + 1 &&
        changeBus.totalPosition == suppressPositions + 1 &&
        (changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0 &&
        !suppressTool.preparedWrapperUploadPendingForTest(),
        "suppress-cage update lost its Position commit or tail clear");

    // Remaining root matrix: inactive is a marker-only no-op; a normal
    // wrapper flush owns one GPU upload; all enabled banks install in T/R/S
    // order. Layer and GPU identity mismatches refuse before validation.
    auto inactiveLayer = new Layer();
    inactiveLayer.meshRef() = makeCube();
    GpuMesh inactiveGpu;
    EditMode inactiveMode = EditMode.Vertices;
    auto inactiveTool = new XfrmTransformTool(
        () => &inactiveLayer.meshRef(), &inactiveGpu, &inactiveMode);
    VectorStack inactiveVts;
    auto inactiveContext = new PreparedRecordContext(null, null);
    auto inactiveEffect = inactiveTool.prepareUpdate(
        inactiveVts, inactiveContext, inactiveLayer, null);
    assert(inactiveEffect.accepted && inactiveContext.validate());
    inactiveContext.install();
    assert(inactiveContext.installTraceForTest() == [8],
        "inactive Xfrm root was not marker-only");

    auto uploadLayer = new Layer();
    uploadLayer.meshRef() = makeCube();
    GpuMesh uploadGpu;
    EditMode uploadMode = EditMode.Vertices;
    auto uploadTool = new XfrmTransformTool(
        () => &uploadLayer.meshRef(), &uploadGpu, &uploadMode);
    uploadTool.flagT = uploadTool.flagR = uploadTool.flagS = true;
    uploadTool.activate();
    uploadTool.seedPreparedWrapperUploadForTest();
    auto uploadOwner = GpuUploadOwner.fakeForTest(&uploadGpu);
    VectorStack uploadVts;
    auto uploadContext = new PreparedRecordContext(null, null);
    uploadContext.setResourceIdentity(7, 11);
    auto uploadEffect = uploadTool.prepareUpdate(
        uploadVts, uploadContext, uploadLayer, uploadOwner);
    assert(uploadEffect.accepted && uploadContext.validate());
    uploadContext.install();
    assert(uploadContext.installTraceForTest() ==
        [8, 60, 62, 61, 2, 16, 56, 57, 59],
        "complete Xfrm T/R/S root installed out of legacy order");

    auto wrongLayer = new Layer();
    wrongLayer.meshRef() = makeCube();
    auto staleContext = new PreparedRecordContext(null, null);
    assert(!uploadTool.prepareUpdate(
        uploadVts, staleContext, wrongLayer, uploadOwner).accepted,
        "complete Xfrm root accepted a foreign Layer");
    GpuMesh wrongGpu;
    auto wrongOwner = GpuUploadOwner.fakeForTest(&wrongGpu);
    uploadTool.seedPreparedWrapperUploadForTest();
    auto wrongGpuContext = new PreparedRecordContext(null, null);
    assert(!uploadTool.prepareUpdate(
        uploadVts, wrongGpuContext, uploadLayer, wrongOwner).accepted,
        "complete Xfrm root accepted a foreign GPU owner");

    // Live/prepared close pairs exercise the two installation adapters around
    // the same projected command. Payload equality is checked directly, then
    // undo/redo checks that the installed geometry and run hooks agree.
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    g_pipeCtx = null;
    alias DragBank = XfrmTransformTool.DragBank;
    alias TransformHistoryIntent =
        XfrmTransformTool.TransformHistoryIntent;
    struct ClosePairCell {
        DragBank bank;
        TransformHistoryIntent intent;
        float afterX;
        string failure;
    }
    foreach (cell; [
        ClosePairCell(DragBank.Rotate, TransformHistoryIntent.RunClose, 11,
            "paired open Rotate close payload diverged"),
        ClosePairCell(DragBank.Scale, TransformHistoryIntent.RunClose, 22,
            "paired open Scale close payload diverged"),
        ClosePairCell(DragBank.Move, TransformHistoryIntent.RunClose, 33,
            "paired same-bank boundary payload diverged"),
        ClosePairCell(DragBank.Move, TransformHistoryIntent.BoundaryCommit, 44,
            "paired cross-bank boundary payload diverged")]) {
        Mesh liveMesh = makeCube();
        Mesh preparedMesh = makeCube();
        liveMesh.resetSelection();
        preparedMesh.resetSelection();
        liveMesh.selectVertex(0);
        preparedMesh.selectVertex(0);
        EditMode liveMode = EditMode.Vertices;
        EditMode preparedMode = EditMode.Vertices;
        GpuMesh liveGpu, preparedGpu;
        auto liveView = new View(0, 0, 800, 600);
        auto preparedView = new View(0, 0, 800, 600);
        auto liveHistory = new CommandHistory();
        auto preparedHistory = new CommandHistory();
        auto liveTool = new XfrmTransformTool(
            () => &liveMesh, &liveGpu, &liveMode);
        auto preparedTool = new XfrmTransformTool(
            () => &preparedMesh, &preparedGpu, &preparedMode);
        foreach (t; [liveTool, preparedTool]) {
            t.flagT = cell.bank == DragBank.Move;
            t.flagR = cell.bank == DragBank.Rotate;
            t.flagS = cell.bank == DragBank.Scale;
        }
        liveTool.setUndoBindings(liveHistory,
            () => new MeshVertexEdit(&liveMesh, liveView, liveMode));
        preparedTool.setUndoBindings(preparedHistory,
            () => new MeshVertexEdit(&preparedMesh,
                                     preparedView, preparedMode));
        liveTool.activate();
        preparedTool.activate();
        VectorStack liveVts, preparedVts;
        liveTool.update(liveVts);
        preparedTool.update(preparedVts);
        liveTool.openLiveSessionForTest();
        preparedTool.openLiveSessionForTest();
        liveTool.editCauseBank = preparedTool.editCauseBank = cell.bank;
        liveTool.run.t = preparedTool.run.t = Vec3(cell.afterX, 2, 3);
        auto liveRec = &liveTool.recFor(cell.bank);
        auto preparedRec = &preparedTool.recFor(cell.bank);
        liveRec.runStart = preparedRec.runStart = XformState.init;
        liveRec.runKnown = preparedRec.runKnown = true;
        liveMesh.vertices[0].x = cell.afterX;
        preparedMesh.vertices[0].x = cell.afterX;

        auto liveProjection = liveTool.projectOwnedEditClose(cell.bank, false);
        auto preparedProjection = preparedTool.projectPreparedOwnedEditClose(
            cell.bank, false);
        auto liveCmd = cast(MeshVertexEdit)liveProjection.command;
        auto preparedCmd = cast(MeshVertexEdit)preparedProjection.command;
        assert(liveCmd !is null && preparedCmd !is null &&
               liveCmd.editIndices() == [0u] &&
               preparedCmd.editIndices() == [0u] &&
               liveCmd.editBefore() == [Vec3(-0.5f, -0.5f, -0.5f)] &&
               preparedCmd.editBefore() == [Vec3(-0.5f, -0.5f, -0.5f)] &&
               liveCmd.editAfter() == [Vec3(cell.afterX, -0.5f, -0.5f)] &&
               preparedCmd.editAfter() ==
                   [Vec3(cell.afterX, -0.5f, -0.5f)], cell.failure);

        liveTool.installLiveOwnedEditClose(liveProjection, cell.intent);
        auto context = new PreparedRecordContext(preparedHistory, null);
        assert(preparedTool.prepareOwnedEditClose(
            preparedProjection, context, cell.intent));
        assert(context.markHistoryInstall() && context.validate());
        context.install();
        preparedTool.installPreparedUpdateEditClose(preparedProjection.state);
        assert(!liveTool.editIsOpen() && !preparedTool.editIsOpen(),
            "paired close adapters did not close both captures");
        assert(liveHistory.undo() && preparedHistory.undo());
        assert(liveMesh.vertices == preparedMesh.vertices &&
               liveTool.run == preparedTool.run, cell.failure);
        assert(liveHistory.redo() && preparedHistory.redo());
        assert(liveMesh.vertices == preparedMesh.vertices &&
               liveTool.run == preparedTool.run, cell.failure);
    }

    import toolpipe.pipeline : ToolPipeContext;
    auto pairPipe = new ToolPipeContext();
    auto pairFalloff = new FalloffStage();
    auto pairSnap = new SnapStage();
    auto pairSymmetry = new SymmetryStage();
    pairPipe.pipeline.add(pairFalloff);
    pairPipe.pipeline.add(pairSnap);
    pairPipe.pipeline.add(pairSymmetry);
    g_pipeCtx = pairPipe;

    // A refire whose geometry is unchanged still carries real pipe-config
    // endpoints. Compare its empty geometry payload and execute both hook
    // pairs so the value-bearing config payload is witnessed, not inferred.
    Mesh liveRefireMesh = makeCube();
    Mesh preparedRefireMesh = makeCube();
    EditMode liveRefireMode = EditMode.Vertices;
    EditMode preparedRefireMode = EditMode.Vertices;
    GpuMesh liveRefireGpu, preparedRefireGpu;
    auto liveRefireView = new View(0, 0, 800, 600);
    auto preparedRefireView = new View(0, 0, 800, 600);
    auto liveRefireHistory = new CommandHistory();
    auto preparedRefireHistory = new CommandHistory();
    auto liveRefireTool = new XfrmTransformTool(
        () => &liveRefireMesh, &liveRefireGpu, &liveRefireMode);
    auto preparedRefireTool = new XfrmTransformTool(
        () => &preparedRefireMesh, &preparedRefireGpu,
        &preparedRefireMode);
    liveRefireTool.setUndoBindings(liveRefireHistory,
        () => new MeshVertexEdit(&liveRefireMesh,
                                 liveRefireView, liveRefireMode));
    preparedRefireTool.setUndoBindings(preparedRefireHistory,
        () => new MeshVertexEdit(&preparedRefireMesh,
                                 preparedRefireView, preparedRefireMode));
    auto liveSeed = new MeshVertexEdit(
        &liveRefireMesh, liveRefireView, liveRefireMode);
    auto preparedSeed = new MeshVertexEdit(
        &preparedRefireMesh, preparedRefireView, preparedRefireMode);
    liveSeed.setEdit([0], [liveRefireMesh.vertices[0]],
        [liveRefireMesh.vertices[0] + Vec3(1, 0, 0)], "Transform");
    preparedSeed.setEdit([0], [preparedRefireMesh.vertices[0]],
        [preparedRefireMesh.vertices[0] + Vec3(1, 0, 0)], "Transform");
    liveRefireHistory.recordInSession(
        liveSeed, liveRefireHistory.currentRunId);
    preparedRefireHistory.recordInSession(
        preparedSeed, preparedRefireHistory.currentRunId);
    liveRefireTool.lastAppliedGestureMutationVersion =
        liveRefireMesh.mutationVersion;
    preparedRefireTool.lastAppliedGestureMutationVersion =
        preparedRefireMesh.mutationVersion;
    liveRefireTool.armedUndoEpoch = liveRefireHistory.undoEpoch();
    preparedRefireTool.armedUndoEpoch = preparedRefireHistory.undoEpoch();
    FalloffPacket refirePre;
    refirePre.type = FalloffType.Element;
    refirePre.enabled = true;
    refirePre.pickedRadius = 2;
    FalloffPacket refirePost = refirePre.ownedDup();
    refirePost.pickedRadius = 7;
    pairFalloff.restoreConfigFromPacket(refirePost);
    const liveAnchor = liveRefireMesh.vertices.dup;
    const preparedAnchor = preparedRefireMesh.vertices.dup;
    auto liveRefireProjection = liveRefireTool.projectPipeRefire(
        liveAnchor, liveAnchor, null, refirePre, refirePost,
        SnapPacket.init, SnapPacket.init,
        SymmetryPacket.init, SymmetryPacket.init);
    auto preparedRefireProjection = preparedRefireTool.projectPreparedPipeRefire(
        preparedAnchor, preparedAnchor, null, refirePre, refirePost,
        SnapPacket.init, SnapPacket.init,
        SymmetryPacket.init, SymmetryPacket.init);
    assert(liveRefireProjection.valid && preparedRefireProjection.valid &&
           liveRefireProjection.command.editIndices().length == 0 &&
           preparedRefireProjection.command.editIndices().length == 0 &&
           liveRefireProjection.command.editBefore() ==
               preparedRefireProjection.command.editBefore() &&
           liveRefireProjection.command.editAfter() ==
               preparedRefireProjection.command.editAfter(),
        "paired config-only refire payload diverged");
    auto liveRefireHooks = liveRefireProjection.command.getHooks();
    auto preparedRefireHooks = preparedRefireProjection.command.getHooks();
    liveRefireHooks.revert();
    const liveRefireRevert = pairFalloff.snapshotConfigToPacket().pickedRadius;
    pairFalloff.restoreConfigFromPacket(refirePost);
    preparedRefireHooks.revert();
    const preparedRefireRevert =
        pairFalloff.snapshotConfigToPacket().pickedRadius;
    liveRefireHooks.apply();
    const liveRefireApply = pairFalloff.snapshotConfigToPacket().pickedRadius;
    pairFalloff.restoreConfigFromPacket(refirePre);
    preparedRefireHooks.apply();
    const preparedRefireApply =
        pairFalloff.snapshotConfigToPacket().pickedRadius;
    assert(liveRefireRevert == 2 && preparedRefireRevert == 2 &&
           liveRefireApply == 7 && preparedRefireApply == 7,
        "paired config-only refire hook payload diverged");

    // Pin/run/pipe endpoints are part of the command payload too. Exercise
    // both closure pairs against the same deliberately displaced live state.
    auto pairAcen = new ActionCenterStage(null, null);
    pairPipe.pipeline.add(pairAcen);
    Mesh liveHookMesh = makeCube(), preparedHookMesh = makeCube();
    EditMode liveHookMode = EditMode.Vertices;
    EditMode preparedHookMode = EditMode.Vertices;
    GpuMesh liveHookGpu, preparedHookGpu;
    auto liveHookView = new View(0, 0, 800, 600);
    auto preparedHookView = new View(0, 0, 800, 600);
    auto liveHookHistory = new CommandHistory();
    auto preparedHookHistory = new CommandHistory();
    auto liveHookTool = new XfrmTransformTool(
        () => &liveHookMesh, &liveHookGpu, &liveHookMode);
    auto preparedHookTool = new XfrmTransformTool(
        () => &preparedHookMesh, &preparedHookGpu, &preparedHookMode);
    foreach (t; [liveHookTool, preparedHookTool]) {
        t.flagT = true; t.flagR = t.flagS = false;
    }
    liveHookTool.setUndoBindings(liveHookHistory,
        () => new MeshVertexEdit(&liveHookMesh, liveHookView, liveHookMode));
    preparedHookTool.setUndoBindings(preparedHookHistory,
        () => new MeshVertexEdit(&preparedHookMesh,
                                 preparedHookView, preparedHookMode));
    pairAcen.restorePinState(Pin(true, Vec3(1, 2, 3)));
    pairAcen.restoreSoftPlaced(Pin(true, Vec3(4, 5, 6)));
    liveHookMesh.resetSelection(); preparedHookMesh.resetSelection();
    liveHookMesh.selectVertex(0); preparedHookMesh.selectVertex(0);
    liveHookTool.activate(); preparedHookTool.activate();
    VectorStack liveHookVts, preparedHookVts;
    liveHookTool.update(liveHookVts); preparedHookTool.update(preparedHookVts);
    liveHookTool.openLiveSessionForTest();
    preparedHookTool.openLiveSessionForTest();
    liveHookTool.editCauseBank = preparedHookTool.editCauseBank = DragBank.Move;
    foreach (t; [liveHookTool, preparedHookTool]) {
        auto rec = &t.recFor(DragBank.Move);
        rec.runStart = XformState.init;
        rec.runKnown = true;
        t.run.t = Vec3(8, 9, 10);
    }
    pairAcen.restorePinState(Pin(true, Vec3(11, 12, 13)));
    pairFalloff.restoreConfigFromPacket(refirePre);
    liveHookMesh.vertices[0].x = 55;
    preparedHookMesh.vertices[0].x = 55;
    auto liveHookProjection = liveHookTool.projectOwnedEditClose(
        DragBank.Move, false);
    auto preparedHookProjection =
        preparedHookTool.projectPreparedOwnedEditClose(
            DragBank.Move, false);
    auto liveHookCmd = cast(MeshVertexEdit)liveHookProjection.command;
    auto preparedHookCmd = cast(MeshVertexEdit)preparedHookProjection.command;
    assert(liveHookCmd.editAfter() == preparedHookCmd.editAfter(),
        "paired pin/run/pipe-config geometry payload diverged");
    auto liveHooks = liveHookCmd.getHooks();
    auto preparedHooks = preparedHookCmd.getHooks();
    liveHooks.revert();
    const livePinRevert = pairAcen.currentUserPin();
    const liveRunRevert = liveHookTool.run;
    const livePipeRevert = pairFalloff.snapshotConfigToPacket().pickedRadius;
    assert(livePinRevert == Pin(true, Vec3(1, 2, 3)) &&
           liveRunRevert == XformState.init && livePipeRevert == 2,
        "live pin/run/pipe-config revert payload diverged");
    pairAcen.restorePinState(Pin(true, Vec3(99, 99, 99)));
    pairFalloff.restoreConfigFromPacket(refirePost);
    preparedHookTool.run.t = Vec3(99, 99, 99);
    preparedHooks.revert();
    assert(pairAcen.currentUserPin() == Pin(true, Vec3(1, 2, 3)) &&
           preparedHookTool.run == XformState.init &&
           pairFalloff.snapshotConfigToPacket().pickedRadius == 2,
        "paired pin/run/pipe-config revert payload diverged");
    liveHooks.apply();
    const livePinApply = pairAcen.currentUserPin();
    const liveRunApply = liveHookTool.run;
    const livePipeApply = pairFalloff.snapshotConfigToPacket().pickedRadius;
    assert(livePinApply == Pin(true, Vec3(11, 12, 13)) &&
           liveRunApply.t == Vec3(8, 9, 10) && livePipeApply == 2,
        "live pin/run/pipe-config apply payload diverged");
    pairAcen.restorePinState(Pin(true, Vec3(98, 98, 98)));
    pairFalloff.restoreConfigFromPacket(refirePost);
    preparedHookTool.run.t = Vec3(98, 98, 98);
    preparedHooks.apply();
    assert(pairAcen.currentUserPin() == Pin(true, Vec3(11, 12, 13)) &&
           preparedHookTool.run.t == Vec3(8, 9, 10) &&
           pairFalloff.snapshotConfigToPacket().pickedRadius == 2,
        "paired pin/run/pipe-config apply payload diverged");

    // P9: an explicit Auto relocate outranks the Move settle soft pin.
    Mesh p9Mesh = makeCube();
    p9Mesh.resetSelection();
    p9Mesh.selectVertex(0);
    EditMode p9Mode = EditMode.Vertices;
    GpuMesh p9Gpu;
    auto p9Pipe = new ToolPipeContext();
    auto p9Acen = new ActionCenterStage(() => &p9Mesh, &p9Mode);
    auto p9Falloff = new FalloffStage(() => &p9Mesh, &p9Mode);
    p9Pipe.pipeline.add(p9Acen);
    p9Pipe.pipeline.add(p9Falloff);
    p9Acen.mode = ActionCenterStage.Mode.Auto;
    p9Falloff.type = FalloffType.Element;
    g_pipeCtx = p9Pipe;
    immutable Vec3 p9UserCenter = Vec3(3, 4, 5);
    immutable Vec3 p9SoftCenter = Vec3(8, 9, 10);
    p9Acen.setUserPlaced(p9UserCenter);
    auto p9History = new CommandHistory();
    auto p9View = new View(0, 0, 800, 600);
    auto p9Tool = new XfrmTransformTool(() => &p9Mesh, &p9Gpu, &p9Mode);
    p9Tool.flagT = true;
    p9Tool.setUndoBindings(p9History,
        () => new MeshVertexEdit(&p9Mesh, p9View, p9Mode));
    p9Tool.activate();
    p9Tool.openLiveSessionForTest();
    p9Tool.editCauseBank = DragBank.Move;
    p9Tool.editCauseProvisional = false;
    p9Tool.currentRunBank = DragBank.Move;
    p9Tool.run.t = Vec3(1, 0, 0);
    p9Tool.recFor(DragBank.Move).runStart = XformState.init;
    p9Tool.recFor(DragBank.Move).runKnown = true;
    p9Mesh.vertices[0].x += 1;
    p9Tool.pendingMoveSoftPin = true;
    p9Tool.pendingMoveSoftCenter = p9SoftCenter;
    auto p9Projection = p9Tool.projectOwnedEditClose(DragBank.Move, false);
    assert(p9Acen.currentCenter() == p9UserCenter &&
           p9Projection.state.nextDragFalloff.pickedCenter == p9UserCenter,
        "projected Element falloff ignored userPin precedence");
    p9Tool.installLiveOwnedEditClose(
        p9Projection, TransformHistoryIntent.RunGesture);
    size_t p9BeforeModel, p9BeforeUi;
    p9History.undoDepthCounts(p9BeforeModel, p9BeforeUi);
    p9Tool.armRegradeStamp();
    SubjectPacket p9Subject;
    VectorStack p9Vts;
    evaluateSubject(p9Subject, p9Vts,
        SubjectSource(&p9Mesh, p9Mode, SelType.Vertex, Viewport.init));
    assert(p9Vts.get!FalloffPacket().pickedCenter == p9UserCenter,
        "live Element falloff ignored userPin precedence");
    p9Gpu.suppressCageUpload = true;
    p9Tool.update(p9Vts);
    size_t p9AfterModel, p9AfterUi;
    p9History.undoDepthCounts(p9AfterModel, p9AfterUi);
    assert(p9BeforeModel == 1 && p9AfterModel == 1,
        "Auto relocate plus Move settle created an idle re-grade undo record");

    // A closed Rotate/Scale mouse-up must still end the prior pin snapshot and
    // operation cause before the next session stages its cancel baseline.
    immutable Vec3 committedPin = Vec3(13, 14, 15);
    p9Acen.freezeUserPlacedSnapshot();
    p9Acen.setUserPlaced(committedPin);
    p9Tool.editCauseBank = DragBank.Rotate;
    p9Tool.editCauseProvisional = true;
    p9Tool.commitOwnedEdit(DragBank.Rotate, TransformHistoryIntent.RunGesture);
    assert(!p9Acen.projectedEditCloseSnapshotFrozen() &&
           p9Tool.editCauseBank == DragBank.None &&
           !p9Tool.editCauseProvisional,
        "closed owned edit retained pin snapshot or operation cause");
    p9Acen.stageCurrentPinState();
    p9Acen.freezeUserPlacedSnapshot();
    p9Acen.setUserPlaced(Vec3(90, 91, 92));
    p9Acen.restoreUserPlacedSnapshot();
    assert(p9Acen.currentUserPin() == Pin(true, committedPin),
        "next session restored a stale action-center cancel baseline");

    // prepareEditRecord preserves the destructive close of its old builders.
    p9Tool.openLiveSessionForTest();
    p9Mesh.vertices[0].x += 1;
    auto p9PrepareContext = new PreparedRecordContext(p9History, null);
    auto p9Deactivate = p9Tool.prepareDeactivate(p9PrepareContext);
    assert(p9Deactivate.kind == PreparedDeactivateKind.Xfrm &&
           p9Deactivate.historyAccepted && !p9Tool.editIsOpen(),
        "prepared edit record left its capture session open");
    p9PrepareContext.discard();
}

static assert(!__traits(compiles, { XfrmPreparedState a; XfrmPreparedState b = a; }));
