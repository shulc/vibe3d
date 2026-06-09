module tools.scale;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import sdl.stdinc : SDL_FALSE, SDL_TRUE, SDL_bool;

import tools.transform;
import handler;
import mesh;
import editmode;
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


// ---------------------------------------------------------------------------
// ScaleTool : TransformTool — shows ScaleHandler at selection/mesh center; scales
//             selected vertices along the dragged axis relative to the center.
// ---------------------------------------------------------------------------

class ScaleTool : TransformTool {
    ScaleHandler handler;

private:
    Vec3     scaleAccum     = Vec3(1, 1, 1);  // cumulative scale factor per axis since tool activated
    Vec3     dragScaleAccum = Vec3(1, 1, 1);  // scale within current drag (for yellow arrows)
    Vec3     propScale      = Vec3(1, 1, 1);  // persistent value shown in Tool Properties
    Vec3[]   activationVertices;              // mesh snapshot at tool activation (for props apply)
    Vec3     activationCenter;               // gizmo center at activation
    Vec3     dragStartScaleAccum = Vec3(1, 1, 1);
    float    dragScaleScalarDelta;
    SDL_bool preDragRelativeMouse = SDL_FALSE;
    bool     ownsRelativeMouse;

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
    }

    void destroy() { handler.destroy(); }

    void setWrapperGizmoPose(Vec3 center, Vec3 bX, Vec3 bY, Vec3 bZ) {
        cachedCenter = center;
        if (!editIsOpen())
            activationCenter = center;
        handler.setPosition(center);
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
        restoreRelativeMouseMode();
        if (editIsOpen())
            commitEdit("Scale");
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
        //
        // Phase 2 (Q5 / brief item 5): idle-time gate + reachability note —
        // identical to the rotate falloff site (rotate.d update()). For a GIZMO
        // scale run the session self-closes at every handle mouse-up, so this
        // site is DEAD at idle; it is reachable only for an OPEN PANEL scale
        // session (tool.attr SX … with scaleAccum != identity), where the
        // existing in-place mutation IS the correct coalesce-until-drop behavior
        // (scenario C, out of scope). The OBJ-4 wrap (record-as-tagged-entry) is
        // therefore NOT applied — its target idle gizmo-run re-apply no longer
        // exists post-Phase-2. Only the idle-time gate below lands; flagged for
        // the plan owner. (See the rotate site for the full rationale.)
        // Two-arm branch (Phase 2; mirrors the wrapper-Move + rotate sites):
        //  - ARM 1 (open panel session, editIsOpen() true): the OLD in-place
        //    coalesce, UNCHANGED — a scale panel session (tool.attr SX … with
        //    scaleAccum != identity) folds the re-apply into its single drop
        //    commit and records nothing (scenario C, out of scope).
        //  - ARM 2 (committed gizmo gesture, editIsOpen() false but the wrapper's
        //    run is open with a landed Scale gesture): the NEW record path. The
        //    re-grade is baked as a tagged in-session entry in the current run.
        //    The wrapper owns the run / history / currentRunBank / refire state,
        //    so the bank+staleness gate and the record route through its public
        //    R/S seam (refireScaleEligible / recordFalloffRefireScale).
        import tools.xfrm_transform : XfrmTransformTool;
        bool dragLive = false;
        XfrmTransformTool wrap = null;
        if (wrapperRef !is null) {
            if (auto w = cast(XfrmTransformTool) wrapperRef) {
                dragLive = w.dragInFlight();
                wrap = w;
            }
        }
        if (!dragLive && scaleAccum != Vec3(1, 1, 1)) {
            if (editIsOpen()) {
                // ARM 1 — panel session: old in-place coalesce, no record.
                // P-C: trigger spans falloff + snap + symmetry.
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
                    applyScaleFromActivationCpuOnly(vts);
                    needsGpuUpdate = true;
                }
            } else if (wrap !is null && wrap.refireScaleEligible()) {
                // ARM 2 — committed gizmo gesture: re-grade + record. The
                // bank (Scale) + staleness gates live inside refireScaleEligible.
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
                    // the re-grade entry's hooks restore the whole config.
                    FalloffPacket  preF  = dragFalloff,  postF  = liveF;
                    SnapPacket     preSn = dragSnap,     postSn = liveSn;
                    SymmetryPacket preSy = dragSymmetry, postSy = liveSy;
                    dragFalloff  = liveF;
                    dragSnap     = liveSn;
                    dragSymmetry = liveSy;
                    buildVertexCacheIfNeeded();
                    applyScaleFromActivationCpuOnly(vts);   // mutates mesh.vertices
                    Vec3[] after = mesh.vertices.dup;
                    // Empty idx → helper iterates the full vertex range (S1).
                    wrap.recordFalloffRefireScale("Falloff", anchor, after, null,
                                                  preF, postF, preSn, postSn,
                                                  preSy, postSy);
                    needsGpuUpdate = true;
                }
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
        if (suppressCommit) { cancelEdit(); return; }
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        Vec3 accBefore  = preEditScaleAccum;
        Vec3 propBefore = preEditPropScale;
        Vec3 accAfter   = scaleAccum;
        Vec3 propAfter  = propScale;

        // P-A + P-C — UNIFORM hook family (see rotate.d commitEdit for the full
        // rationale): compose the WHOLE transient pipe CONFIG restore (falloff +
        // snap + symmetry) into this gesture's accumulator hooks so mergeRun's
        // merged first.revert restores both the accumulators AND the run-start
        // pipe config (snapshot captured at this gesture's commit = run-start,
        // since a config tweak only fires after a gesture commits). ABSOLUTE
        // assign; the accum field + the three disjoint stages compose without
        // clobber.
        FalloffPacket  fSnap;  bool haveF  = false;
        SnapPacket     snSnap; bool haveSn = false;
        SymmetryPacket sySnap; bool haveSy = false;
        if (auto fs = falloffStageForHooks())  { fSnap  = fs.snapshotConfigToPacket(); haveF  = true; }
        if (auto sn = snapStageForHooks())     { snSnap = sn.snapshotConfigToPacket(); haveSn = true; }
        if (auto sy = symmetryStageForHooks()) { sySnap = sy.snapshotConfigToPacket(); haveSy = true; }
        // P-F Phase 3a (MAJOR-5) — capture the WRAPPER field-snapshot hooks (the
        // run-absolute headlessScale pre/post) into locals so the closures below
        // compose them alongside the accumulator + pipe-config restores. Null when
        // standalone (no wrapper) ⇒ inert. DISJOINT wrapper field — composes into
        // the same closure without clobbering scaleAccum/propScale.
        auto wrapApply  = wrapperFieldApplyHook;
        auto wrapRevert = wrapperFieldRevertHook;
        cmd.setHooks(
            () {
                scaleAccum = accAfter;  propScale = propAfter;
                if (haveF)  if (auto fs = falloffStageForHooks())  fs.restoreConfigFromPacket(fSnap);
                if (haveSn) if (auto sn = snapStageForHooks())     sn.restoreConfigFromPacket(snSnap);
                if (haveSy) if (auto sy = symmetryStageForHooks()) sy.restoreConfigFromPacket(sySnap);
                if (wrapApply !is null) wrapApply();
            },
            () {
                scaleAccum = accBefore; propScale = propBefore;
                if (haveF)  if (auto fs = falloffStageForHooks())  fs.restoreConfigFromPacket(fSnap);
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
    // composed T+R+S preset). Sibling cross-instance access to the protected
    // commitEdit()/editIsOpen() is not granted by D `protected`; this method
    // calls its OWN protected members (legal), mirroring `publicEditIsOpen()`.
    // No-op when no session is open (single-mode preset, or no prior S drag).
    public void commitSessionIfOpen() {
        if (!editIsOpen()) return;
        // Cross-slot boundary commit (Phase 2) — route PLAIN, same rationale as
        // RotateTool.commitSessionIfOpen: this closes a separate-bank session at
        // another bank's boundary and must land as its OWN surviving entry, not
        // join that bank's in-session run (which consolidate would then merge
        // across banks). A plain record() trips the layer-A foreign-record guard
        // to consolidate the boundary-bank's open run first.
        bool wasInSession = recordViaInSession;
        recordViaInSession = false;
        scope(exit) recordViaInSession = wasInSession;
        commitEdit("Scale");
    }

    // Per-gesture commit (record+consolidate, Phase 2): the wrapper calls this
    // from its onMouseButtonUp when a wrapper-owned scale drag ends, so each
    // scale gesture bakes a TAGGED in-session entry (recordViaInSession is set
    // on this sub-tool while the tool is live). The next handle grab reopens a
    // fresh session (beginEdit in onMouseButtonDown), so two consecutive scale
    // drags land as TWO in-session entries — one Ctrl+Z steps each — that
    // consolidate into ONE surviving entry at the run boundary / drop. commitEdit
    // attaches the scaleAccum/propScale accumulator hooks BEFORE the terminal
    // recordCommit, so stepping a per-gesture entry restores the accumulator for
    // free. Public for the same sibling-cross-instance reason as
    // commitSessionIfOpen. No-op when no session is open (no scale drag happened).
    public void commitGesture() {
        if (editIsOpen())
            commitEdit("Scale");
    }

    // In-session-cancel PUBLIC mirror (same sibling-access reasoning as
    // commitSessionIfOpen): the composing wrapper's cancelUncommittedEdit()
    // calls this to abort THIS sub-tool's open scale session WITHOUT recording,
    // restoring the mesh to the session's pre-edit baseline. Scale keeps its
    // geometry session on the sub-tool (MS-5), so the wrapper's own
    // cancelUncommittedEdit() cannot reach it — this widens the whole-open-run
    // cancel (D6) to the S slot. Restores the Tool-Properties state (scaleAccum /
    // propScale) to the values snapshotEditState() froze at session open, then
    // hands the geometry/GPU teardown to the shared base helper.
    // activationVertices is left untouched: the (activationVertices, scaleAccum)
    // invariant holds again once scaleAccum is back at its session-start value
    // and the verts are restored. No-op (returns false) when no scale session is
    // open; on cancel returns true and writes the restored session-start PANEL
    // value (factors) to `outFactors` so the wrapper can snap its own
    // `headlessScale` mirror — the attr the panel reads back — to the pre-edit
    // value in lockstep with the geometry.
    public bool cancelSessionIfOpen(out Vec3 outFactors) {
        if (!editIsOpen()) return false;
        scaleAccum = preEditScaleAccum;
        propScale  = preEditPropScale;
        outFactors = preEditPropScale;
        cancelOpenSessionGeometry();
        return true;
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

        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.draw(shader, vp);

        // Cyan element + yellow cursor marker for the active snap
        // candidate. Populated by updateLiveSnapPreview(, vts) during idle
        // hover (click-outside-relocate hint).
        drawSnapOverlay(lastSnap, vp, *mesh);
        // Falloff overlay + endpoint handles are drawn ONCE by the
        // XfrmTransformTool wrapper, which owns the single shared
        // FalloffGizmo (step 4b-2). The banks no longer touch it.
    }

    void drawAxisBoxesOnly(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
    {
        if (!active) return;
        cachedVp = vp;

        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ, vts);
        handler.setOrientation(bX, bY, bZ);
        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.drawAxisBoxesOnly(shader, vp);

        drawSnapOverlay(lastSnap, vp, *mesh);
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
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            lastMX = e.x; lastMY = e.y;
            dragStartScaleAccum = scaleAccum;
            dragScaleAccum = Vec3(1, 1, 1);
            dragScaleScalarDelta = 0.0f;
            preDragRelativeMouse = SDL_GetRelativeMouseMode();
            ownsRelativeMouse = SDL_SetRelativeMouseMode(SDL_TRUE) == 0;

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
        // Phase 2 cross-slot: in a composed T+R+S preset the WRAPPER's Move
        // session may also be open. A relocate commits EVERY open session, so
        // close the wrapper's Move run too (independent of this scale session
        // → two distinct runs, correct). Reached via the base-typed wrapperRef
        // cast. Null / standalone unit-test instance → skipped.
        if (wrapperRef !is null) {
            import tools.xfrm_transform : XfrmTransformTool;
            if (auto wrap = cast(XfrmTransformTool) wrapperRef)
                wrap.commitMoveSessionIfOpen();
        }
        handler.setPosition(hit);
        centerManual = true;
        notifyAcenUserPlaced(hit);
        activationVertices = mesh.vertices.dup;
        activationCenter   = hit;
        scaleAccum         = Vec3(1, 1, 1);
        propScale          = Vec3(1, 1, 1);
        // Consume the click (no scale drag starts). The relocate
        // already moved the ACEN pivot via notifyAcenUserPlaced above;
        // returning true makes click-away-relocate behave uniformly
        // with Move / Rotate (both relocate + consume the click in
        // Auto), so a scale-tool click away from the gizmo can't fall
        // through to selection-picking and drop the user's selection.
        return true;
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
        wholeMeshDrag = false;
        restoreRelativeMouseMode();

        dragAxis = -1;
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

    private float clampScaleFactor(float f) const {
        return f < 0.0f ? 0.0f : f;
    }

    private void setDragAxisScale(bool scaleX, bool scaleY, bool scaleZ,
                                  float scaleFactor)
    {
        if (scaleX) {
            dragScaleAccum.x = scaleFactor;
            scaleAccum.x = dragStartScaleAccum.x * scaleFactor;
        }
        if (scaleY) {
            dragScaleAccum.y = scaleFactor;
            scaleAccum.y = dragStartScaleAccum.y * scaleFactor;
        }
        if (scaleZ) {
            dragScaleAccum.z = scaleFactor;
            scaleAccum.z = dragStartScaleAccum.z * scaleFactor;
        }
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
            if (wholeMesh && wrapperRef is null) {
                // STANDALONE whole-mesh: GPU bypass — upload base once at drag
                // start, then only update matrix (matrix is around
                // activationVertices, the correct base with no wrapper baseline).
                if (!propsDragging) {
                    uploadPropsBase(activationVertices);
                    propsDragging = true;
                }
                gpuMatrix = pivotScaleMatrixBasis(activationCenter,
                    handler.axisX, handler.axisY, handler.axisZ,
                    scaleAccum.x, scaleAccum.y, scaleAccum.z);
            } else {
                // WRAPPED path (Phase 1): GPU bypass would preview from the wrong
                // base (activationVertices), ignoring baked history in
                // dragBaseline. applyTRS wrote correct CPU verts — defer upload.
                // Partial selection always defers too.
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

    // Open a bare edit session with NO geometry change (forms-engine Phase 5b /
    // re-eval plan D5 test opener). Mirrors the FIRST-active-frame gating of
    // drawProperties: snapshot the Tool-Properties state then beginEdit() so a
    // subsequent applyScalePanelValue() lands inside the same coalesced session.
    void openEditForValue() {
        buildVertexCacheIfNeeded();
        if (!editIsOpen()) {
            snapshotEditState();
            beginEdit();
        }
    }

    // Value-driven panel entry point (forms-engine Phase 5b). The forms panel
    // dispatches an absolute `SX`/`SY`/`SZ` factor through the `reEvaluate()`
    // seam, which calls this once per edit. It mirrors the ABSOLUTE arm of
    // `drawProperties` above WITHOUT any ImGui calls: the caller already holds
    // the value, so there is no `DragFloat` / `IsItemActive` gating — every call
    // is treated as an active edit (the wrapper's commit guards close the
    // session, exactly as for a gizmo drag). The geometry apply, session/snapshot
    // gating, per-edit falloff/symmetry re-capture and the `propsDragging`
    // whole-mesh GPU bypass are kept identical to the inline path so a panel
    // value edit blends through falloff and uses the fast path the same way a
    // slider drag does.
    void applyScalePanelValue(Vec3 factors) {
        // Absolute value-driven: the panel value IS scaleAccum (clamped >= 0).
        if (factors.x < 0) factors.x = 0;
        if (factors.y < 0) factors.y = 0;
        if (factors.z < 0) factors.z = 0;
        scaleAccum = factors;
        propScale  = factors;

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
        // this delegates to applyScaleAbsoluteFromRun → applyTRS(dragBaseline);
        // standalone it runs the activationVertices kernel.
        applyScaleFromActivationCpuOnly(propVts);

        if (wholeMesh && wrapperRef is null) {
            // STANDALONE whole-mesh: GPU bypass — upload base once, then only
            // update matrix (around activationVertices, the correct base with no
            // wrapper run baseline).
            if (!propsDragging) {
                uploadPropsBase(activationVertices);
                propsDragging = true;
            }
            gpuMatrix = pivotScaleMatrixBasis(activationCenter,
                handler.axisX, handler.axisY, handler.axisZ,
                scaleAccum.x, scaleAccum.y, scaleAccum.z);
        } else {
            // WRAPPED path (Phase 1): the GPU bypass would preview from the wrong
            // base (activationVertices), ignoring baked history in dragBaseline.
            // applyTRS wrote correct CPU verts — defer the upload. Partial
            // selection / falloff always defers too.
            needsGpuUpdate = true;
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
    // the wrapper's `applyScaleAbsoluteFromRun` → `applyTRS(dragBaseline)` so
    // the "ui" (panel) path shares the SAME single geometry-apply entry point
    // AND the SAME run baseline as the "handle" (drag) and "headless" (numeric)
    // paths. Phase 1 (R/S run-baseline): applying from the run baseline (not
    // activationVertices) preserves any baked cross-axis gizmo history. The edit
    // session + undo display hooks stay on this sub-tool (no session migration →
    // no cross-instance commit), mirroring RotateTool.applyAbsoluteFromOrigCpuOnly.
    //
    // Standalone fallback (a bare ScaleTool with no wrapper — only unit-test
    // construction): the original `applyScaleFromActivation` kernel call,
    // numerically identical for the absolute scaleAccum apply.
    void applyScaleFromActivationCpuOnly(ref VectorStack vts) {
        if (wrapperRef !is null) {
            import tools.xfrm_transform : XfrmTransformTool;
            auto wrap = cast(XfrmTransformTool) wrapperRef;
            if (wrap !is null) {
                // Phase 1 (R/S run-baseline fix): apply from the WRAPPER's run
                // baseline (`dragBaseline`), NOT activationVertices. After a
                // cross-axis gizmo gesture the prior transform is baked into
                // dragBaseline + mesh, not into activationVertices, so applying
                // the full scaleAccum from activationVertices would discard it.
                // The run-baseline entry reads the live headlessScale absolutely
                // against dragBaseline-with-baked-history. The edit SESSION stays
                // on this sub-tool — the run-baseline entry does NOT open the
                // wrapper session (MS-5).
                wrap.applyScaleAbsoluteFromRun(scaleAccum);
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

    public int hitTestAxisHeads(int mx, int my) {
        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float ex, ey, ndcZ;
            if (!projectToWindowFull(arrow.end, cachedVp, ex, ey, ndcZ)) continue;
            float dx = cast(float)mx - ex;
            float dy = cast(float)my - ey;
            if (sqrt(dx*dx + dy*dy) < 12.0f)
                return cast(int)i;
        }
        return -1;
    }
}
