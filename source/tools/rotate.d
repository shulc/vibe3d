module tools.rotate;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tools.transform;
import handler;
import mesh;
import editmode;
import math;
import shader;
import toolpipe.packets : FalloffPacket;

import std.math;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import params : Param;

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

    // Wrapped-mode input-frame channel (gesture-frame unification, Phase 2).
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
    // never overwritten now). The STANDALONE path (`wrapperRef is null`) never
    // calls this and keeps deriving `dragAxisVec` from its own `inputBasis*`.
    Vec3     wrapperInputFrameX = Vec3(1, 0, 0);
    Vec3     wrapperInputFrameY = Vec3(0, 1, 0);
    Vec3     wrapperInputFrameZ = Vec3(0, 0, 1);
    bool     wrapperInputFrameValid = false;

    // Standalone-only (`wrapperRef is null`): in the wrapped role the truth is
    // `run.r` / `headlessRotate` on the wrapper. Every wrapped read is re-pointed
    // to `wrap.publishedRotate()` / the refire/commit-hook gate; these fields are
    // kept so the `wrapperRef is null` branches compile and the legacy FORMS=0
    // standalone panel continues to work.
    Vec3     angleAccum = Vec3(0, 0, 0);  // total rotation per axis since tool activated (radians)
    Vec3     propDeg = Vec3(0, 0, 0);     // persistent value shown in Tool Properties (degrees)
    Vec3[]   origVertices;                // snapshot of vertex positions at activate()

    // Phase C.3: Tool Properties state at the START of the current edit
    // session, captured by snapshotEditState() and restored on undo via
    // hooks attached to the recorded MeshVertexEdit. Standalone-only: the
    // wrapped commit-hook restore is gated on `wrapperRef is null`.
    Vec3     preEditAngleAccum;
    Vec3     preEditPropDeg;

    // Numeric rotate attrs (`xfrm.transform RX/RY/RZ`).
    // Driven via `tool.attr <toolId> RX <degrees>` — used by the
    // headless apply path to rotate verts around the AXIS-stage basis,
    // weighted by the active falloff stage. Three independent rotations
    // applied in X→Y→Z order; for the soft-twist preset only one is
    // typically set, so the order is moot in the common case.
    Vec3     headlessRotate;

public:
    // ── rotate single-source plumbing (MS-2; doc/rotate_single_source_plan.md) ──
    // Inert until MS-3/MS-4/MS-5 switch the call sites; declared here so the
    // wrapper-side scaffolding compiles against stable members.
    //
    // Gesture-scalar producer output. MS-3 makes the principal-axis drag
    // branch (axis 0/1/2) publish the ABSOLUTE accumulated ring angle here
    // and return without mutating geometry; the wrapper drains it into its
    // `headlessRotate` and runs `applyTRS`. `axis == -1` means "nothing
    // pending" (idle / hover / view-ring frames leave it untouched).
    int   pendingRotateAxis  = -1;      // 0/1/2 principal ring, 3 view-ring
    float pendingRotateAngle = 0;       // radians, absolute since drag start
    // View axis (camera-forward) published alongside pendingRotateAxis == 3.
    // The wrapper drains it into headlessRotateViewAxis and applies the
    // arbitrary-axis rotation through applyTRS. Meaningless for axes 0/1/2.
    Vec3  pendingRotateViewAxis = Vec3(0, 0, 0);

    // Back-pointer to the unified `XfrmTransformTool`, wired at the wrapper's
    // `activate()`. Typed as the base class to avoid a field-level circular
    // import (mirrors `MoveTool.wrapperRef`); cast to `XfrmTransformTool`
    // locally where needed. Null for any standalone (unit-test) instance.
    TransformTool wrapperRef;

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
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

    void setWrapperGizmoPose(Vec3 center, Vec3 bX, Vec3 bY, Vec3 bZ) {
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
        angleAccum = Vec3(0, 0, 0);
        propDeg = Vec3(0, 0, 0);
        origVertices = mesh.vertices.dup;
        headlessRotate = Vec3(0, 0, 0);
        // Reset the gesture-producer scratch on (re)activation.
        pendingRotateAxis    = -1;
        pendingRotateAngle   = 0;
        pendingRotateViewAxis = Vec3(0, 0, 0);
    }

    // `xfrm.transform` RX/RY/RZ surfaced for `tool.attr <id> RY 30`
    // / `tool.doApply` headless flows. Each is degrees of rotation
    // around the matching AXIS-stage basis vector (right / up / fwd).
    override Param[] params() {
        return [
            Param.float_("RX", "Rotate X", &headlessRotate.x, 0.0f).angle(),
            Param.float_("RY", "Rotate Y", &headlessRotate.y, 0.0f).angle(),
            Param.float_("RZ", "Rotate Z", &headlessRotate.z, 0.0f).angle(),
        ];
    }

    // Headless apply path. Reuses applyRotationVec — same per-vertex
    // weighting + symmetry mirror that interactive drag uses. Each
    // non-zero R{X,Y,Z} fires one rotation around its basis axis,
    // pivoting at the ACEN center. dragAxis stays -1 here, so
    // applyRotationVec uses the global axisVec (no per-cluster axis
    // lookup) — Local / Element ACEN modes that need per-cluster
    // pivots already work because pivotFor() consults
    // queryClusterPivots(vts) regardless of dragAxis.
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

        // Pull the pivot from ACEN. Interactive update() does this
        // every frame; headless never runs update(), so we do it here.
        cachedCenter = queryActionCenter(vts);
        handler.setPosition(cachedCenter);

        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);

        if (headlessRotate.x != 0)
            applyRotationVec(bX, headlessRotate.x * cast(float)(PI / 180.0), vts);
        if (headlessRotate.y != 0)
            applyRotationVec(bY, headlessRotate.y * cast(float)(PI / 180.0), vts);
        if (headlessRotate.z != 0)
            applyRotationVec(bZ, headlessRotate.z * cast(float)(PI / 180.0), vts);
        return true;
    }

    // Phase 7.5h: tool-session boundary — commit any pending edit
    // before tool switch so the session lands as one undo entry.
    override void deactivate() {
        if (editIsOpen())
            commitEdit("Rotate");
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
            // entry (matches deactivate()).
            if (editIsOpen() && selChanged)
                commitEdit("Rotate");
            lastSelectionHash   = currentHash;
            lastMutationVersion = currentMutVer;
            vertexCacheDirty    = true;

            // Geometry-only change: the per-edit hook on the (un)applied
            // MeshVertexEdit has already restored angleAccum / propDeg to
            // the value they held at that edit's boundary. origVertices
            // stays at its activate-time value — the (origVertices,
            // angleAccum) contract is invariant: applying angleAccum to
            // origVertices always reproduces the current mesh state,
            // even across undo/redo.

            // Selection change: zero the accumulators and refresh
            // everything. The per-edit hooks for now-stale entries on
            // the stack still reference the OLD (origVertices,
            // angleAccum) tuple — they'll misfire if undone after re-
            // selection, but that's an acceptable edge case (cross-
            // selection undo rarely makes sense anyway).
            if (selChanged) {
                angleAccum   = Vec3(0, 0, 0);
                propDeg      = Vec3(0, 0, 0);
                origVertices = mesh.vertices.dup;
                centerManual = false;
            }
        }

        // Phase 7.5h: live falloff change → re-apply with new weights.
        // Rotate's existing applyAbsoluteFromOrigCpuOnly already
        // rebuilds verts from origVertices using the captured
        // dragFalloff; just need to trigger it on packet change.
        //
        // Phase 2 (Q5 / brief item 5): gate on idle-time — never fire under an
        // in-flight gizmo drag on ANY bank. This sub-tool's own dragAxis is
        // already < 0 here (the update() early-return at the top bails while THIS
        // ring is dragging), but in a composed preset a DIFFERENT bank (Move)
        // could be mid-drag with this rotate session open; the per-frame drag
        // path re-captures falloff itself there (captureFalloffForDrag), so this
        // update()-driven re-apply is redundant — and recording one underneath
        // an in-flight gesture would create an entry below the live drag.
        //
        // Reachability note (Phase 2 as-implemented): the OBJ-4 plan asked to
        // WRAP this re-apply in its own beginEdit/commitEdit so it records as a
        // tagged in-session entry. Under per-gesture R/S commit the gizmo session
        // CLOSES at every ring mouse-up, so for a GIZMO run editIsOpen() is false
        // at idle and this site is DEAD — exactly as the Move falloff site is
        // dead post-Phase-1. It is reachable ONLY for an OPEN PANEL rotate session
        // (tool.attr RZ … keeps the session open at idle with angleAccum != 0).
        // For that case the EXISTING in-place mutation is the correct
        // coalesce-until-drop behavior (scenario C, OUT OF SCOPE per the plan):
        // the open panel session's editBefore already anchors the session
        // baseline, the re-apply mutates within it, and the single drop commit
        // captures the final result as ONE entry. Wrapping it in a nested
        // beginEdit/commitEdit would either no-op (beginEdit is idempotent while
        // the session is open) or split the panel session into two entries,
        // breaking the panel-coalescing contract. So the OBJ-4 wrap is NOT applied
        // — the prescribed target (an idle gizmo-run re-apply) does not exist
        // post-Phase-1/2. Only the idle-time gate below lands. (Flagged for the
        // plan owner: OBJ-4's wrap premise is moot once gizmo sessions self-close.)
        // Two-arm branch (Phase 2; mirrors the wrapper-Move site):
        //  - ARM 1 (open panel session, editIsOpen() true): the OLD in-place
        //    coalesce, UNCHANGED. A rotate panel session (tool.attr RZ … keeps a
        //    session open at idle with angleAccum != 0) folds the re-apply into
        //    its single drop commit and records nothing (scenario C, out of scope).
        //  - ARM 2 (committed gizmo gesture, editIsOpen() false but the wrapper's
        //    run is open with a landed Rotate gesture): the NEW record path. The
        //    re-grade is baked as a tagged in-session entry in the current run so
        //    the in-session Ctrl+Z contract holds. The wrapper owns the run /
        //    history / currentRunBank / refire state, so the bank+staleness gate
        //    and the record both route through its public R/S seam
        //    (refireRotateEligible / recordFalloffRefireRotate), reached via the
        //    same wrapperRef cast that backs dragLive.
        import tools.xfrm_transform : XfrmTransformTool;
        bool dragLive = false;
        XfrmTransformTool wrap = null;
        if (wrapperRef !is null) {
            if (auto w = cast(XfrmTransformTool) wrapperRef) {
                dragLive = w.dragInFlight();
                wrap = w;
            }
        }
        // Refire gate: in the WRAPPED role read wrapper truth (`publishedRotate()`
        // = headlessRotate in degrees, derived from run.r — never stale after
        // undo) rather than the sub-tool accumulator. In the standalone role keep
        // the accumulator gate (the only truth it has). Note A: this re-point
        // ships in the SAME commit as the commit-hook restore gate below so that
        // after a wrapped undo-to-identity the gate reads wrapper truth (identity
        // = Vec3(0,0,0)) rather than the stale-nonzero `angleAccum`.
        bool heldNonIdentity = (wrap !is null)
            ? (wrap.publishedRotate() != Vec3(0, 0, 0))
            : (angleAccum != Vec3(0, 0, 0));
        if (!dragLive && heldNonIdentity) {
            if (editIsOpen()) {
                // ARM 1 — panel session: old in-place coalesce, no record.
                // P-C: trigger spans falloff + snap + symmetry. The wrapper's
                // applyAbsolute*/applyTRS path re-captures the live symmetry +
                // falloff from a fresh vts, so a mid-session symmetry toggle
                // re-grades the mirror set here; re-read the sub-tool's own
                // captured packets so the next compare baseline is current.
                FalloffPacket liveF  = currentFalloff(vts);
                SnapPacket     liveSn = currentSnap(vts);
                SymmetryPacket liveSy = currentSymmetry(vts);
                if (!falloffPacketsEqual(liveF, dragFalloff)
                 || !snapPacketsEqual(liveSn, dragSnap)
                 || !symmetryPacketsEqual(liveSy, dragSymmetry)) {
                    dragFalloff  = liveF;
                    dragSnap     = liveSn;
                    dragSymmetry = liveSy;
                    buildVertexCacheIfNeeded();
                    applyAbsoluteFromOrigCpuOnly(vts);
                    needsGpuUpdate = true;
                }
            } else if (wrap !is null && wrap.refireRotateEligible()) {
                // ARM 2 — committed gizmo gesture: re-grade + record. The
                // bank (Rotate) + staleness gates live inside refireRotateEligible.
                // P-C: trigger spans falloff + snap + symmetry.
                FalloffPacket liveF  = currentFalloff(vts);
                SnapPacket     liveSn = currentSnap(vts);
                SymmetryPacket liveSy = currentSymmetry(vts);
                if (!falloffPacketsEqual(liveF, dragFalloff)
                 || !snapPacketsEqual(liveSn, dragSnap)
                 || !symmetryPacketsEqual(liveSy, dragSymmetry)) {
                    // Capture the pre-recompute (post-gesture) geometry LIVE for
                    // the once-per-window anchor (OBJ-3 W1: live, never frozen).
                    Vec3[] anchor = mesh.vertices.dup;
                    // P-A / P-C: PRE-tweak config = still-current captured packets;
                    // POST = the live packets. Captured BEFORE the re-read below so
                    // the re-grade entry's hooks restore the whole config (falloff +
                    // snap + symmetry).
                    FalloffPacket  preF  = dragFalloff,  postF  = liveF;
                    SnapPacket     preSn = dragSnap,     postSn = liveSn;
                    SymmetryPacket preSy = dragSymmetry, postSy = liveSy;
                    dragFalloff  = liveF;
                    dragSnap     = liveSn;
                    dragSymmetry = liveSy;
                    buildVertexCacheIfNeeded();
                    applyAbsoluteFromOrigCpuOnly(vts);   // mutates mesh.vertices
                    Vec3[] after = mesh.vertices.dup;
                    // Empty idx → helper iterates the full vertex range (S1).
                    wrap.recordFalloffRefireRotate("Falloff", anchor, after, null,
                                                   preF, postF, preSn, postSn,
                                                   preSy, postSy);
                    needsGpuUpdate = true;
                }
            }
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
        if (!editIsOpen()) {
            cachedCenter = queryActionCenter(vts);
            handler.setPosition(cachedCenter);
        }
    }

    // Snapshot Tool-Properties state at the start of an edit session, so
    // the matching commitEdit can attach an undo-restore hook holding
    // these values. Called from beginEdit-adjacent sites (mouseButtonDown,
    // first slider-active frame).
    private void snapshotEditState() {
        preEditAngleAccum = angleAccum;
        preEditPropDeg    = propDeg;
    }

    protected override void commitEdit(string label) {
        if (suppressCommit) { cancelEdit(); return; }
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        // Closure-capture the before/after Tool-Properties state. After
        // recording, history.undo() runs revert (vert positions revert,
        // then angleAccum/propDeg snap back to the pre-edit values);
        // history.redo() does the opposite.
        Vec3 accBefore  = preEditAngleAccum;
        Vec3 propBefore = preEditPropDeg;
        Vec3 accAfter   = angleAccum;
        Vec3 propAfter  = propDeg;

        // P-A + P-C — UNIFORM hook family: compose the WHOLE transient pipe
        // CONFIG restore (falloff + snap + symmetry) into this gesture's
        // accumulator hooks. A transform run can be consolidated at DROP as
        // [gesture, pipeRefire]; mergeRun keeps first.revert + last.apply. The
        // refire entry carries the pipe-config hooks, but without config here the
        // merged first.revert (this gesture) would NOT restore the run-start
        // config — leaving the pipe handle stranded at its post-tweak value after
        // a post-drop Ctrl+Z (geometry reverts, config does not). So snapshot the
        // config AT THIS gesture's commit (= run-start config for the first
        // gesture in the run, since a config tweak only happens AFTER a gesture
        // commit) and have BOTH hooks restore it. The gesture itself never changes
        // the pipe config, so before==after here; the snapshot exists purely so
        // the merged first.revert carries it. ABSOLUTE (assign), never delta —
        // splices through mergeRun like the accums. The accum assignment + the
        // three config restores are INDEPENDENT mutations (local fields vs three
        // disjoint stages); none reads another, so they compose without clobber.
        // FALLOFF is now SET-aware: snapshot every active falloff instance's
        // config (1-element = the prior single-stage behaviour, byte-identical),
        // keyed by stage identity so restore targets the same instances. SNAP +
        // SYMMETRY stay SINGLE (one stage each).
        import toolpipe.stages.falloff : FalloffSetSnapshot, snapshotFalloffSet,
                                         restoreFalloffSet;
        FalloffSetSnapshot fSnap = snapshotFalloffSet(falloffStagesForHooks());
        SnapPacket     snSnap; bool haveSn = false;
        SymmetryPacket sySnap; bool haveSy = false;
        if (auto sn = snapStageForHooks())     { snSnap = sn.snapshotConfigToPacket(); haveSn = true; }
        if (auto sy = symmetryStageForHooks()) { sySnap = sy.snapshotConfigToPacket(); haveSy = true; }
        // P-F Phase 3b (MAJOR-5) — capture the WRAPPER field-snapshot hooks (the
        // run-absolute headlessRotate pre/post) into locals so the closures below
        // compose them alongside the accumulator + pipe-config restores. Null when
        // standalone (no wrapper) ⇒ inert. DISJOINT wrapper field — composes into
        // the same closure without clobbering angleAccum/propDeg. Mirrors the Scale
        // wiring (scale.d) exactly.
        auto wrapApply  = wrapperFieldApplyHook;
        auto wrapRevert = wrapperFieldRevertHook;
        cmd.setHooks(
            () {
                // Accumulator restore is standalone-only: the wrapped role's
                // geometry is driven by wrapApply (run.r / headlessRotate
                // restored by the wrapper hook). Gate on wrapperRef is null so
                // a wrapped undo-to-identity leaves angleAccum at its stale
                // pre-gesture value without corrupting the refire gate (which
                // now reads wrapper truth, not this accumulator).
                if (wrapperRef is null) { angleAccum = accAfter;  propDeg = propAfter; }
                restoreFalloffSet(fSnap);
                if (haveSn) if (auto sn = snapStageForHooks())     sn.restoreConfigFromPacket(snSnap);
                if (haveSy) if (auto sy = symmetryStageForHooks()) sy.restoreConfigFromPacket(sySnap);
                if (wrapApply !is null) wrapApply();
            },
            () {
                if (wrapperRef is null) { angleAccum = accBefore; propDeg = propBefore; }
                restoreFalloffSet(fSnap);
                if (haveSn) if (auto sn = snapStageForHooks())     sn.restoreConfigFromPacket(snSnap);
                if (haveSy) if (auto sy = symmetryStageForHooks()) sy.restoreConfigFromPacket(sySnap);
                if (wrapRevert !is null) wrapRevert();
            }
        );
        recordCommit(cmd);
    }

    // Phase 2 cross-slot relocate boundary — PUBLIC mirror of the protected
    // commitEdit, so the composing wrapper can close THIS sub-tool's open
    // session when a relocate fires on a DIFFERENT slot (a Move relocate in a
    // composed T+R+S preset). The wrapper is a sibling class and D `protected`
    // does not grant sibling cross-instance access to commitEdit()/editIsOpen()
    // — this method calls its OWN protected members, which is legal. Mirrors
    // the public `publicEditIsOpen()` read accessor for the same reason. No-op
    // when no session is open (single-mode preset, or no prior R drag).
    public void commitSessionIfOpen() {
        if (!editIsOpen()) return;
        // Cross-slot boundary commit (Phase 2): this closes a SEPARATE-bank
        // session (e.g. an open rotate PANEL session when a MOVE relocate fires)
        // at the boundary-triggering bank's run boundary. It is NOT part of that
        // bank's gizmo run, so it must NOT join that run's in-session tail —
        // otherwise consolidate() at the boundary would merge it across banks
        // (violating single-bank-per-run, Q-c) and collapse two distinct
        // surviving entries into one. Route it PLAIN: a plain record() trips the
        // command_history layer-A foreign-record guard, which consolidates the
        // boundary-bank's open run FIRST, so this rotate entry lands as its OWN
        // surviving entry on top of the consolidated run. Restore the routing
        // flag afterwards (the gizmo per-gesture commitGesture path keeps using
        // in-session routing). buildEditCmd attaches the accum hooks regardless.
        bool wasInSession = recordViaInSession;
        recordViaInSession = false;
        scope(exit) recordViaInSession = wasInSession;
        commitEdit("Rotate");
    }

    // Per-gesture commit (record+consolidate, Phase 2): the wrapper calls this
    // from its onMouseButtonUp when a wrapper-owned ring drag ends, so each
    // ring gesture bakes a TAGGED in-session entry (recordViaInSession is set on
    // this sub-tool while the tool is live). The next ring grab reopens a fresh
    // session (beginEdit in onMouseButtonDown), so two consecutive ring drags
    // land as TWO in-session entries — one Ctrl+Z steps each — that consolidate
    // into ONE surviving entry at the run boundary / drop. commitEdit attaches
    // the angleAccum/propDeg accumulator hooks BEFORE the terminal recordCommit,
    // so stepping a per-gesture entry restores the accumulator for free. Public
    // for the same sibling-cross-instance reason as commitSessionIfOpen. No-op
    // when no session is open (no ring drag happened).
    public void commitGesture() {
        if (editIsOpen())
            commitEdit("Rotate");
    }

    // In-session-cancel PUBLIC mirror (same sibling-access reasoning as
    // commitSessionIfOpen): the composing wrapper's cancelUncommittedEdit()
    // calls this to abort THIS sub-tool's open rotate session WITHOUT recording,
    // restoring the mesh to the session's pre-edit baseline. Rotate keeps its
    // geometry session on the sub-tool (MS-5), so the wrapper's own
    // cancelUncommittedEdit() cannot reach it — this widens the whole-open-run
    // cancel (D6) to the R slot. Restores the Tool-Properties state (angleAccum /
    // propDeg) to the values snapshotEditState() froze at session open, then
    // hands the geometry/GPU teardown to the shared base helper. origVertices is
    // left untouched: the (origVertices, angleAccum) invariant holds again once
    // angleAccum is back at its session-start value and the verts are restored.
    // No-op (returns false) when no rotate session is open; on cancel returns
    // true and writes the restored session-start PANEL value (degrees) to
    // `outDeg` so the wrapper can snap its own `headlessRotate` mirror — the attr
    // the panel reads back — to the pre-edit value in lockstep with the geometry.
    public bool cancelSessionIfOpen(out Vec3 outDeg) {
        if (!editIsOpen()) return false;
        // STANDALONE accumulator restore (wrapperRef is null): the
        // (origVertices, angleAccum) invariant must hold again once the verts
        // are restored, so peel the sub-tool accumulator back to its session
        // start. In the WRAPPED role the geometry is reverted from the wrapper's
        // editBaseline (cancelOpenSessionGeometry) and the refire gate reads
        // wrapper truth, so the accumulator restore is skipped to avoid leaving
        // stale values that would be inert anyway.
        if (wrapperRef is null) {
            angleAccum = preEditAngleAccum;
            propDeg    = preEditPropDeg;
        }
        // Phase 5a — the pre-edit PANEL value returned to the wrapper (which
        // snaps its `headlessRotate` display mirror to it) comes from the
        // WRAPPER TRUTH in the wrapped role, NOT this sub-tool's `propDeg`
        // second accumulator. `gestureStartRotateEuler()` is the matrix-truth
        // run orientation at this session's mouse-down (eulerZYXFromMatrix of
        // gestureStart.r, degrees) — exactly the value the panel was showing
        // when the session opened. The sub-tool's gizmo-basis `preEditPropDeg`
        // would drift from that across a cross-axis multi-gesture run; the
        // wrapper truth is what the forms panel reads back, so this keeps the
        // restored display locked to geometry. STANDALONE (no wrapper) keeps
        // returning `preEditPropDeg` — the only accumulator it has.
        if (wrapperRef !is null) {
            import tools.xfrm_transform : XfrmTransformTool;
            if (auto wrap = cast(XfrmTransformTool) wrapperRef) {
                outDeg = wrap.gestureStartRotateEuler();
                cancelOpenSessionGeometry();
                return true;
            }
        }
        outDeg = preEditPropDeg;
        cancelOpenSessionGeometry();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
    {
        if (!active) return;
        cachedVp = vp;

        // Wrapped: wrapper owns the Model-C renderBasis (= R_gesture·B0 for the
        // ring during a drag), set every frame before draw. Standalone (no
        // wrapper — unit tests) self-orients from the live basis. Re-deriving
        // while wrapped would clobber the gesture-frozen rotated ring frame.
        if (wrapperRef is null) {
            Vec3 bX, bY, bZ;
            currentBasis(bX, bY, bZ, vts);
            handler.setOrientation(bX, bY, bZ);
        }

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

    void drawPrincipalOnly(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
    {
        if (!active) return;
        cachedVp = vp;

        // Wrapped: wrapper owns renderBasis; standalone self-orients (see draw()).
        if (wrapperRef is null) {
            Vec3 bX, bY, bZ;
            currentBasis(bX, bY, bZ, vts);
            handler.setOrientation(bX, bY, bZ);
        }

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
        if (dragAxis < 0) {
            // Click outside gizmo: relocate ACEN to the click projected
            // onto the per-mode plane (most-facing world plane through
            // origin for Auto/None; camera-perpendicular through
            // selection center for Screen). Other ACEN modes keep the
            // gizmo pinned and ignore the click.
            if (!acenAllowsClickRelocate())
                return false;
            Vec3 hit;
            if (!computeClickRelocateHit(e.x, e.y, hit, vts))
                return false;
            // Phase 7.5h: relocating to a new pivot is a new logical
            // tool session — bake the prior session's rotations into
            // one undo entry first, then start fresh.
            if (editIsOpen())
                commitEdit("Rotate");
            // Phase 2 cross-slot: in a composed T+R+S preset the WRAPPER's
            // Move session may also be open (a prior move drag). A relocate
            // commits EVERY open session, so close the wrapper's Move run too
            // (its own editIsOpen() is independent of this rotate session —
            // committing both yields two distinct runs, which is correct).
            // Reached via the base-typed wrapperRef cast to the wrapper, which
            // owns the public commitMoveSessionIfOpen(). Null / non-wrapper
            // (standalone unit-test) instance → skipped.
            if (wrapperRef !is null) {
                import tools.xfrm_transform : XfrmTransformTool;
                if (auto wrap = cast(XfrmTransformTool) wrapperRef)
                    wrap.commitMoveSessionIfOpen();
            }
            handler.setPosition(hit);
            centerManual = true;
            notifyAcenUserPlaced(hit);
            origVertices = mesh.vertices.dup;
            angleAccum = Vec3(0, 0, 0);
            propDeg    = Vec3(0, 0, 0);
            propsDragging = false;
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            return true;
        }
        // A gizmo arc was grabbed (dragAxis >= 0).
        lastMX = e.x; lastMY = e.y;
        totalAngle = 0;
        lastSnappedAngle = 0;

        // Freeze the input-projection basis for the gesture (= the current
        // idle basis = the frozen rendered orientation today). The view-ring
        // mouse-up decomposition reads it instead of the rendered handler.
        currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);

        // Build vertex cache now so we know whether this is a whole-mesh drag.
        buildVertexCacheIfNeeded();
        // Phase 7.5: capture falloff packet — when active, force the
        // per-vertex CPU path (gpuMatrix's single-rotation-uniform fast
        // path is incompatible with per-vertex angle scaling).
        bool falloffActive = captureFalloffForDrag(vts);
        // Phase 7.6d: capture symmetry too; the per-vertex mirror pass
        // breaks the single-uniform-rotation gpuMatrix fast path the
        // same way falloff does.
        bool symmActive    = captureSymmetryForDrag(vts);
        wholeMeshDrag = !falloffActive && !symmActive
            && (vertexProcessCount == cast(int)mesh.vertices.length);
        if (wholeMeshDrag) {
            // Snapshot current vertex positions — GPU is in sync with these.
            dragStartVertices = mesh.vertices.dup;
        }
        snapshotEditState();   // capture pre-drag Tool-Properties state.
        beginEdit();           // Phase C.3: snapshot pre-drag positions for undo.

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

        // Compute drag start direction in the arc plane.
        Vec3 hit;
        prevWrapped = 0;
        if (rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
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
        if (rayPlaneIntersect(viewCamOrigin(), screenRay(lastMX, lastMY, cachedVp),
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
        if (wrapperRef is null || !wrapperInputFrameValid) return;
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
        float effectiveAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
        if (dragAxis == 0) angleAccum.x += effectiveAngle;
        else if (dragAxis == 1) angleAccum.y += effectiveAngle;
        else if (dragAxis == 2) angleAccum.z += effectiveAngle;
        else if (dragAxis == 3) {
            // angleAccum.{x,y,z} are rotations around the gizmo's basis.
            // Decompose the view-aligned rotation onto those axes via dot
            // products against the frozen INPUT basis (captured at drag
            // start), not the rendered `handler.axis*` — identity basis
            // collapses to the legacy world-XYZ behaviour.
            angleAccum.x += effectiveAngle * dot(viewDragAxis, inputBasisX);
            angleAccum.y += effectiveAngle * dot(viewDragAxis, inputBasisY);
            angleAccum.z += effectiveAngle * dot(viewDragAxis, inputBasisZ);
        }

        // Geometry + GPU for EVERY ring (principal 0/1/2 AND view-ring 3) are
        // owned by the wrapper now (XfrmTransformTool.onMouseButtonUp uploads
        // and resets gpuMatrix; applyTRS already wrote the final CPU verts).
        // The angleAccum fold above still runs for ALL axes so the panel
        // display total stays correct (round-3 B-survivor-1).
        //
        // STANDALONE fallback only (no wrapper — unit-test construction): the
        // view-ring's legacy onMouseMotion path mutated geometry directly, so
        // here it must commit/upload the result itself.
        if (dragAxis == 3 && wrapperRef is null) {
            if (wholeMeshDrag) {
                // Apply the final rotation to CPU vertices from the drag-start snapshot.
                commitWholeMeshRotation(effectiveAngle, vts);
                gpu.upload(*mesh);
                gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            } else if (needsGpuUpdate) {
                uploadToGpu();
                needsGpuUpdate = false;
            }
        }
        wholeMeshDrag = false;

        dragAxis   = -1;
        totalAngle = 0;
        // Drop the snap overlay so it doesn't linger after the drag.
        // (No-op when the live-preview already cleared it.)
        lastSnap = SnapResult.init;
        clearLastSnap();
        import std.math : PI;
        propDeg = Vec3(angleAccum.x * 180.0f / PI,
                       angleAccum.y * 180.0f / PI,
                       angleAccum.z * 180.0f / PI);
        // Phase 7.5h: don't commit at mouseUp — keep the edit open so
        // mid-tool falloff changes / further drags re-apply onto the
        // same origVertices baseline. Commit fires at deactivate /
        // selection change / click-outside-relocate.
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
        Vec3 camOrigin = viewCamOrigin();
        Vec3 hitCurr;
        if (dragRefRadius < 1e-6f ||
            !rayPlaneIntersect(camOrigin, screenRay(e.x, e.y, cachedVp), center, dragAxisVec, hitCurr))
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
        } else if (dragAxis == 3 && wrapperRef !is null) {
            // view-aligned ring under the unified wrapper: GESTURE-SCALAR
            // PRODUCER, same contract as the principal axes. Publish the
            // ABSOLUTE accumulated angle AND the camera-forward axis; the
            // wrapper drains them into headlessRotateViewAxis/Angle and runs
            // applyTRS (the single geometry-apply entry point). NO geometry
            // mutation here. Falloff is now correct (one weighted rotation
            // about the view axis via the kernel's dragAxisIdx == -1 path).
            pendingRotateAxis     = 3;
            pendingRotateAngle    = effectiveAngle;
            pendingRotateViewAxis = dragAxisVec;
        } else {
            // view-aligned ring on a STANDALONE RotateTool (no wrapper — only
            // unit-test construction): legacy incremental path. Whole-mesh uses
            // the matrix bypass; partial selection mutates verts.
            if (wholeMeshDrag) {
                gpuMatrix = pivotRotationMatrix(center, dragAxisVec, effectiveAngle);
            } else if (ctrlHeld) {
                import std.math : round, PI;
                enum float step2 = PI / 12.0f;
                float prevSnapped = round((totalAngle - angle) / step2) * step2;
                float delta = lastSnappedAngle - prevSnapped;
                if (delta != 0.0f)
                    applyRotationVec(dragAxisVec, delta, vts);
            } else {
                applyRotationVec(dragAxisVec, angle, vts);
            }
        }

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Rotate           E");
        if (active)
            ImGui.PopStyleColor();
        return clicked;
    }

    override void drawProperties() {
        import std.math : PI;
        if (wrapperRef !is null) {
            // WRAPPED role (FORMS=0 kill-switch only — FORMS=1 suppresses this
            // path entirely). Seed propDeg from the wrapper truth each frame;
            // REPLACES the dragAxis>=0 recompute (Note B: publishedRotate()
            // already reflects the in-progress gizmo angle in the wrapped path,
            // so adding dispAngle on top would double-count it).
            import tools.xfrm_transform : XfrmTransformTool;
            if (auto wrap = cast(XfrmTransformTool) wrapperRef)
                propDeg = wrap.publishedRotate();
        } else if (dragAxis >= 0) {
            // STANDALONE role: derive propDeg from the sub-tool accumulator +
            // the in-progress gizmo angle, as before.
            float dispAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
            // For view-axis drag (==3) the in-progress angle is decomposed
            // onto the frozen INPUT basis (captured at drag start), not the
            // rendered `handler.axis*` — matching onMouseButtonUp's
            // accumulation so the displayed degrees stay consistent once the
            // rendered frame moves.
            float vx = dragAxis == 3 ? dot(viewDragAxis, inputBasisX) : 0;
            float vy = dragAxis == 3 ? dot(viewDragAxis, inputBasisY) : 0;
            float vz = dragAxis == 3 ? dot(viewDragAxis, inputBasisZ) : 0;
            propDeg.x = (angleAccum.x + (dragAxis == 0 ? dispAngle : dispAngle * vx)) * 180.0f / PI;
            propDeg.y = (angleAccum.y + (dragAxis == 1 ? dispAngle : dispAngle * vy)) * 180.0f / PI;
            propDeg.z = (angleAccum.z + (dragAxis == 2 ? dispAngle : dispAngle * vz)) * 180.0f / PI;
        }
        ImGui.DragFloat("X", &propDeg.x, 0.1f, 0, 0, "%.2f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propDeg.y, 0.1f, 0, 0, "%.2f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propDeg.z, 0.1f, 0, 0, "%.2f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        bool anyActive = xActive || yActive || zActive;
        bool anyDone   = xDone   || yDone   || zDone;
        if (!(anyActive || anyDone)) return;

        angleAccum.x = propDeg.x * PI / 180.0f;
        angleAccum.y = propDeg.y * PI / 180.0f;
        angleAccum.z = propDeg.z * PI / 180.0f;
        buildVertexCacheIfNeeded();
        // Phase 7.5: re-capture falloff each active frame; gates the
        // wholeMesh GPU bypass off when the per-vertex weight breaks
        // the single-uniform fast path. drawProperties() is outside
        // the input-dispatch path — build a local vts.
        import toolpipe.packets : SubjectPacket;
        SubjectPacket propSubj;
        VectorStack propVts;
        buildLocalVts(propSubj, propVts);
        bool falloffActive = captureFalloffForDrag(propVts);
        bool symmActive    = captureSymmetryForDrag(propVts);
        bool wholeMesh = !falloffActive && !symmActive
            && (vertexProcessCount == cast(int)mesh.vertices.length);

        // Phase C.3: snapshot pre-drag positions on first active frame so
        // commitEdit at slider release has a baseline. beginEdit is
        // idempotent within an open edit; snapshotEditState too if we
        // gate it on the same edit-not-yet-open check.
        if (anyActive && !editIsOpen()) {
            snapshotEditState();
            beginEdit();
        } else if (anyActive) {
            beginEdit();   // idempotent
        }

        // Update CPU vertices from origVertices (fast, no GPU).
        applyAbsoluteFromOrigCpuOnly(propVts);

        if (anyActive) {
            if (wholeMesh && wrapperRef is null) {
                // STANDALONE whole-mesh: GPU bypass — upload base once at drag
                // start, then only update matrix (matrix is around origVertices,
                // the correct base when there is no wrapper run baseline).
                if (!propsDragging) {
                    uploadPropsBase(origVertices);
                    propsDragging = true;
                }
                gpuMatrix = computePropsRotationMatrix();
            } else {
                // WRAPPED path (Phase 1): GPU bypass would preview from the wrong
                // base (origVertices), ignoring the baked cross-axis history in
                // dragBaseline. applyTRS already wrote the correct CPU verts —
                // defer the upload. Partial selection always defers too.
                needsGpuUpdate = true;
            }
        } else {
            // Drag ended: commit final CPU state to GPU. 7.5h: don't
            // commit the edit here either — props sliders are part of
            // the same tool session as gizmo drags.
            if (propsDragging) {
                gpu.upload(*mesh);
                gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
                propsDragging = false;
            } else {
                needsGpuUpdate = true;
            }
        }
    }

    // Open a bare edit session with NO geometry change (forms-engine Phase 5b /
    // re-eval plan D5 test opener). Mirrors the FIRST-active-frame gating of
    // drawProperties: snapshot the Tool-Properties state then beginEdit() so a
    // subsequent applyRotatePanelValue() lands inside the same coalesced session.
    void openEditForValue() {
        buildVertexCacheIfNeeded();
        if (!editIsOpen()) {
            snapshotEditState();
            beginEdit();
        }
    }

    // Value-driven panel entry point (forms-engine Phase 5b). The forms panel
    // dispatches an absolute `RX`/`RY`/`RZ` value (degrees) through the
    // `reEvaluate()` seam, which calls this once per edit. It mirrors the
    // ABSOLUTE arm of `drawProperties` above WITHOUT any ImGui calls: the
    // caller already holds the value, so there is no `DragFloat` / `IsItemActive`
    // gating — every call is treated as an active edit (the wrapper's commit
    // guards close the session, exactly as for a gizmo drag). The geometry apply,
    // session/snapshot gating, per-edit falloff/symmetry re-capture and the
    // `propsDragging` whole-mesh GPU bypass are kept identical to the inline path
    // so a panel value edit blends through falloff and uses the fast path the
    // same way a slider drag does.
    void applyRotatePanelValue(Vec3 deg) {
        import std.math : PI;

        // Absolute value-driven: the panel value IS angleAccum (no accumulation).
        propDeg = deg;
        angleAccum.x = deg.x * PI / 180.0f;
        angleAccum.y = deg.y * PI / 180.0f;
        angleAccum.z = deg.z * PI / 180.0f;

        buildVertexCacheIfNeeded();
        // Re-capture falloff/symmetry each edit (mirrors drawProperties); gates
        // the whole-mesh GPU bypass off when a per-vertex weight breaks the
        // single-uniform fast path. No dispatcher vts here — build a local one.
        import toolpipe.packets : SubjectPacket;
        SubjectPacket propSubj;
        VectorStack propVts;
        buildLocalVts(propSubj, propVts);
        bool falloffActive = captureFalloffForDrag(propVts);
        bool symmActive    = captureSymmetryForDrag(propVts);
        bool wholeMesh = !falloffActive && !symmActive
            && (vertexProcessCount == cast(int)mesh.vertices.length);

        // Snapshot pre-edit Tool-Properties state on the FIRST edit of the
        // session (before beginEdit opens it); beginEdit is idempotent after.
        if (!editIsOpen()) {
            snapshotEditState();
            beginEdit();
        } else {
            beginEdit();   // idempotent
        }

        // Rebuild CPU vertices via the shared apply path. In the WRAPPED path
        // this delegates to applyRotateAbsoluteFromRun → applyTRS(dragBaseline);
        // standalone it runs the origVertices kernel.
        applyAbsoluteFromOrigCpuOnly(propVts);

        if (wholeMesh && wrapperRef is null) {
            // STANDALONE whole-mesh: GPU bypass — upload base once, then only
            // update matrix. The matrix is computed around origVertices, which IS
            // the correct base when there is no wrapper run baseline.
            if (!propsDragging) {
                uploadPropsBase(origVertices);
                propsDragging = true;
            }
            gpuMatrix = computePropsRotationMatrix();
        } else {
            // WRAPPED path (Phase 1): the GPU bypass would preview from the wrong
            // base (origVertices) — it ignores the baked cross-axis history in
            // dragBaseline. applyTRS already wrote the correct CPU verts, so defer
            // the upload; the wrapper re-uploads from the live mesh. Also the
            // partial-selection / falloff path always defers.
            needsGpuUpdate = true;
        }
    }

private:

    Vec3 rotateVec(Vec3 v, Vec3 pivot, Vec3 axis, float angle) {
        float c = cos(angle), s = sin(angle);
        Vec3 p = v - pivot;
        float d = dot(p, axis);
        Vec3 pcr = cross(axis, p);
        return pivot + p * c + pcr * s + axis * (d * (1.0f - c));
    }

    // Phase 4 of the action-center parity plan: per-cluster pivot for
    // vertex `vi`. Mirrors Scale's pivotFor.
    Vec3 pivotFor(size_t vi, ClusterPivots cp, Vec3 fallback) {
        if (!cp.active) return fallback;
        if (vi >= cp.clusterOf.length) return fallback;
        int cid = cp.clusterOf[vi];
        if (cid < 0 || cid >= cast(int)cp.centers.length) return fallback;
        return cp.centers[cid];
    }

    // Per-cluster axis for vertex `vi`. `axisIdx` ∈ {0,1,2} → right/up/fwd.
    // Returns the gizmo's global axis (`fallback`) when no cluster basis
    // is published or the vertex doesn't belong to any cluster.
    Vec3 axisFor(size_t vi, int axisIdx,
                 ClusterAxes ap, ClusterPivots cp, Vec3 fallback)
    {
        if (!ap.active) return fallback;
        if (vi >= cp.clusterOf.length) return fallback;
        int cid = cp.clusterOf[vi];
        if (cid < 0 || cid >= cast(int)ap.right.length) return fallback;
        if (axisIdx == 0) return ap.right[cid];
        if (axisIdx == 1) return ap.up   [cid];
        return ap.fwd[cid];
    }

    // Apply final rotation from dragStartVertices to mesh.vertices at mouseUp.
    void commitWholeMeshRotation(float angle, ref VectorStack vts) {
        if (dragStartVertices.length != mesh.vertices.length) return;
        auto cp = queryClusterPivots(vts);
        auto ap = queryClusterAxes(vts);
        int axisIdx = (dragAxis >= 0 && dragAxis <= 2) ? dragAxis : -1;
        foreach (i; 0 .. mesh.vertices.length) {
            Vec3 pivot = pivotFor(i, cp, handler.center);
            Vec3 ax    = (axisIdx >= 0)
                       ? axisFor(i, axisIdx, ap, cp, dragAxisVec)
                       : dragAxisVec;
            mesh.vertices[i] = rotateVec(dragStartVertices[i], pivot, ax, angle);
        }
    }

    // Apply X→Y→Z Euler rotation from origVertices to CPU vertices only (no GPU).
    // angleAccum.x/.y/.z are interpreted around the gizmo's basis (workplane
    // axis1/normal/axis2 when non-auto, world XYZ when auto). With per-cluster
    // basis active, each cluster uses its own (right, up, fwd).
    //
    // MS-5 (rotate single-source): the panel slider path and the kept-open-edit
    // falloff-reapply both reach geometry through here. It now DELEGATES to the
    // wrapper's `applyRotateAbsoluteFromRun` → `applyTRS(dragBaseline)` so the
    // "ui" (panel) path shares the SAME single geometry-apply entry point AND the
    // SAME run baseline as the "handle" (drag) and "headless" (numeric) paths.
    // Phase 1 (R/S run-baseline): applying from the run baseline (not
    // origVertices) preserves any baked cross-axis gizmo history. The edit
    // session + undo display hooks stay on this sub-tool (no session migration →
    // no cross-instance commit).
    //
    // Standalone fallback (a bare RotateTool with no wrapper — only unit-test
    // construction): the original `applyRotateFromOrig` kernel call. For a
    // single non-zero axis the two are numerically identical (weight at the
    // baseline position; per-cluster via pivotFor/axisFor), so behaviour is
    // preserved either way.
    void applyAbsoluteFromOrigCpuOnly(ref VectorStack vts) {
        if (wrapperRef !is null) {
            import tools.xfrm_transform : XfrmTransformTool;
            auto wrap = cast(XfrmTransformTool) wrapperRef;
            if (wrap !is null) {
                // Phase 1 (R/S run-baseline fix): apply from the WRAPPER's run
                // baseline (`dragBaseline`), NOT origVertices. After a cross-axis
                // gizmo gesture the prior axis is baked into dragBaseline + mesh,
                // not into origVertices, so applying the full euler from
                // origVertices would discard the baked axis. The run-baseline
                // entry reads the live headlessRotate absolutely against
                // dragBaseline-with-baked-history. The edit SESSION stays on this
                // sub-tool (its own beginEdit/commitEdit) — the run-baseline entry
                // does NOT open the wrapper session (MS-5).
                //
                // Phase 5a — feed the WRAPPER TRUTH, not this sub-tool's
                // `angleAccum` second accumulator. The panel path
                // (applyRotatePanelValue) already wrote the wrapper's
                // `headlessRotate` to the same value it set `angleAccum` to, so
                // the two are equal there. But the falloff-refire ARM in update()
                // re-enters here at idle on the PERSISTENT accumulator, where
                // `angleAccum` (gizmo-basis decomposition) drifts from the
                // matrix-truth euler across a cross-axis run. `publishedRotate()`
                // is eulerZYXFromMatrix(run.r) in degrees → radians here, so
                // applyRotateAbsoluteFromRun recomposes run.r against the TRUE run
                // orientation (an identity recompose). Standalone (no wrapper)
                // still drives geometry from `angleAccum` via the kernel below.
                import std.math : PI;
                Vec3 wrapDeg = wrap.publishedRotate();
                wrap.applyRotateAbsoluteFromRun(
                    Vec3(wrapDeg.x * cast(float)(PI / 180.0),
                         wrapDeg.y * cast(float)(PI / 180.0),
                         wrapDeg.z * cast(float)(PI / 180.0)));
                return;
            }
        }
        import tools.xform_kernels : applyRotateFromOrig;
        applyRotateFromOrig(mesh, origVertices, toProcess,
                            handler.center,
                            handler.axisX, handler.axisY, handler.axisZ,
                            angleAccum,
                            dragFalloff, cachedVp,
                            queryClusterPivots(vts), queryClusterAxes(vts),
                            dragSymmetry, toProcess);
    }

    // Compose the current angleAccum into a single 4x4 rotation matrix around the pivot.
    float[16] computePropsRotationMatrix() {
        Vec3 pivot = handler.center;
        float[16] m = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        if (angleAccum.x != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisX, angleAccum.x));
        if (angleAccum.y != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisY, angleAccum.y));
        if (angleAccum.z != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisZ, angleAccum.z));
        return m;
    }

    // Apply incremental rotation to cached vertex indices — used for
    // partial selection. When ACEN.Local + AXIS.Local publish per-cluster
    // pivots/basis, each cluster rotates around ITS pivot using ITS axis
    // (actr.local + axis.local).
    //
    // Phase 7.5: each vertex's rotation is scaled by the falloff weight.
    // Soft-twist effect — verts near full-influence rotate by `angle`,
    // verts in the falloff transition rotate by `angle * weight(vi)`.
    void applyRotationVec(Vec3 axisVec, float angle, ref VectorStack vts) {
        import tools.xform_kernels : applyRotateIncremental;
        int axisIdx = (dragAxis >= 0 && dragAxis <= 2) ? dragAxis : -1;
        applyRotateIncremental(mesh, vertexIndicesToProcess,
                               handler.center, axisVec, axisIdx, angle,
                               dragFalloff, cachedVp,
                               queryClusterPivots(vts), queryClusterAxes(vts),
                               dragSymmetry, toProcess);
        needsGpuUpdate = true;
    }

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
            return rotateVec(p, Vec3(0,0,0), axisVec, a);
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
