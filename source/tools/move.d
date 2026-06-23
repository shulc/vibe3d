module tools.move;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tools.transform;
import handler;
import mesh;
import editmode;
import math;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math;
import drag;
import snap : snapCursor, SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;

// ---------------------------------------------------------------------------
// MoveTool : TransformTool — shows MoveHandler at selection/mesh center
//
// Phase 3 (transform-single-source plan) responsibilities:
//   - Own the MoveHandler instance, draw it, hit-test against it
//     (`hitTestAxes`), and run the screen-space drag math
//     (`axisDragDelta` / `planeDragDelta` / `applySnapToDelta`).
//   - On drag-axis motion, produce a basis-LOCAL gesture scalar in
//     `pendingTranslateDelta` and return. The wrapper drains it and
//     runs the unified `applyTRS` evaluate — MoveTool no longer
//     mutates `mesh.vertices` on its own.
//
// What MoveTool no longer owns:
//   - Edit-session boundaries (`beginEdit`/`commitEdit`) — wrapper.
//   - Geometry mutation (`applyDelta` / `applyDeltaImmediate` /
//     `applyPerClusterDelta` / `applyAbsoluteFromBaseline` — all
//     deleted; the wrapper's `applyTRS(dragBaseline)` covers every
//     case those wrappers used to dispatch among).
//   - `gpuMatrix` whole-mesh bypass — wrapper.
//   - Property-panel TRS sliders' apply path — wrapper's
//     `applyMovePanelDelta`.
// ---------------------------------------------------------------------------

class MoveTool : TransformTool {
    MoveHandler handler;

    // Phase 3 — gesture-scalar producer for the unified
    // `XfrmTransformTool.applyTRS` flow. `MoveTool.onMouseMotion`'s
    // drag-axis path writes the basis-LOCAL drag delta here and
    // returns; the wrapper reads it, accumulates into
    // `run.t`, and calls `applyTRS(dragBaseline)`. This
    // routes every per-frame translate through the same kernels the
    // numeric `tool.attr move T<axis>` + `tool.doApply` path uses, so
    // per-cluster magnitudes can't diverge.
    //
    // The wrapper is expected to drain (read + reset to 0) on every
    // motion event it processes; if it doesn't, the next read sees
    // accumulated delta. Public so the wrapper can poke at it without
    // a friend-class dance.
    Vec3 pendingTranslateDelta = Vec3(0, 0, 0);

    // Set true on the off-gizmo click-relocate branch of
    // `onMouseButtonDown` (the gizmo is re-anchored to the click
    // projection), false on every axis/handle grab. A relocate during a
    // live tool session is a new logical run, so the wrapper (which owns
    // the move edit session) reads + clears this immediately after
    // `onMouseButtonDown` returns true to decide whether to commit the
    // prior run before opening the next.
    //
    // Why a dedicated flag and not `dragAxis`: the relocate path leaves
    // `dragAxis = 3` (see `beginScreenPlaneDragAt`) — byte-identical to a
    // most-facing-plane center grab — so `dragAxis` cannot distinguish
    // the two. `centerManual` is the "update() must not recompute center"
    // latch, not a relocate marker, so it can't discriminate either.
    bool lastClickWasRelocate = false;

    // Input-projection basis, captured ONCE at drag start (in
    // `onMouseButtonDown`, where `dragAxis` becomes >= 0) from the live
    // `currentBasis(...)`. This is the frame the screen→world input math
    // reads (axis-constrain / delta projection), kept SEPARATE from the
    // rendered gizmo orientation (`handler.axisX/Y/Z`). Today both are the
    // same drag-start frame — the render orientation is frozen during a
    // drag via the `dragAxis < 0` gate, and `inputBasis*` is captured from
    // the same `currentBasis(...)` the last idle draw used — so this split
    // is byte-stable. It lets the rendered frame move later without
    // dragging the input projection with it (the oscillation eb3fd47 /
    // baa8a92 / 0b812cf fixed).
    Vec3 inputBasisX = Vec3(1, 0, 0);
    Vec3 inputBasisY = Vec3(0, 1, 0);
    Vec3 inputBasisZ = Vec3(0, 0, 1);

    // Wrapped-mode input-frame channel (gesture-frame unification, Phase 2).
    // When this bank is driven by `XfrmTransformTool` (`wrapperRef !is null`)
    // AND the wrapper chained this gesture off the persisted gizmo frame, the
    // wrapper pushes that ONE unified frame here (via `setWrapperInputFrame`,
    // called once per gesture from `beginMoveDragSession`). The DECOMPOSE read
    // sites then project the world delta onto THIS frame instead of the bank's
    // own `inputBasisX/Y/Z`. This replaces the prior hand-synced override that
    // overwrote `inputBasis*` from the wrapper's softBasis at gesture start —
    // same value (the channel carries the unified `frame`, which equals
    // softBasis when chained), now sourced from the single frame. The STANDALONE
    // path (`wrapperRef is null`) NEVER consults this; it keeps reading its own
    // `inputBasis*` (seeded by the `currentBasis(inputBasis*, vts)` writes). The
    // center-box drag (dragAxis==3) is basis-free/screen-plane and is excluded
    // at the push site (the wrapper passes `chained=false` for it), so it falls
    // back to the live `inputBasis*` exactly as before.
    Vec3 wrapperInputFrameX = Vec3(1, 0, 0);
    Vec3 wrapperInputFrameY = Vec3(0, 1, 0);
    Vec3 wrapperInputFrameZ = Vec3(0, 0, 1);
    bool wrapperInputFrameValid = false;

    // Push the wrapper's unified gesture frame into this bank for the WRAPPED
    // input projection. `chained` is the wrapper's `frame.valid &&
    // acenSettleAllowed() && dragAxis != 3` gate (mirrors the old override
    // guard) — false for a fresh/non-chained gesture or the basis-free
    // center-box, in which case the DECOMPOSE reads stay on `inputBasis*`.
    void setWrapperInputFrame(Vec3 r, Vec3 u, Vec3 f, bool chained) {
        wrapperInputFrameX     = r;
        wrapperInputFrameY     = u;
        wrapperInputFrameZ     = f;
        wrapperInputFrameValid = chained;
    }

    // DEBUG-only — input-side parity guard (gesture-frame unification, Phase 2).
    // When a wrapped DECOMPOSE read consults the pushed channel, that channel
    // must carry the wrapper's unified `frame` (proven == softBasis by the
    // wrapper-side assert), which is always a pure-rotation orthonormal triple.
    // Assert that local invariant here so the input-read safety net mirrors the
    // render-rung asserts. Compiled out of release.
    debug void assertWrapperInputFrameChained() const {
        import std.math : abs;
        if (wrapperRef is null || !wrapperInputFrameValid) return;
        enum float tol = 1e-3f;
        assert(abs(wrapperInputFrameX.length - 1.0f) < tol,
               "move wrapperInputFrameX not unit length");
        assert(abs(wrapperInputFrameY.length - 1.0f) < tol,
               "move wrapperInputFrameY not unit length");
        assert(abs(wrapperInputFrameZ.length - 1.0f) < tol,
               "move wrapperInputFrameZ not unit length");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameY)) < tol,
               "move wrapperInputFrame X·Y not orthogonal");
        assert(abs(dot(wrapperInputFrameX, wrapperInputFrameZ)) < tol,
               "move wrapperInputFrame X·Z not orthogonal");
        assert(abs(dot(wrapperInputFrameY, wrapperInputFrameZ)) < tol,
               "move wrapperInputFrame Y·Z not orthogonal");
    }

    // Source selector for the WRAPPED-role DECOMPOSE reads. When this bank is
    // wrapper-driven and the gesture chained off the unified frame, the input
    // projection reads that frame; otherwise (standalone, or fresh/center-box
    // non-chained) it reads the bank's own drag-start-frozen `inputBasis*`.
    Vec3 inAxisX() const {
        return (wrapperRef !is null && wrapperInputFrameValid)
             ? wrapperInputFrameX : inputBasisX;
    }
    Vec3 inAxisY() const {
        return (wrapperRef !is null && wrapperInputFrameValid)
             ? wrapperInputFrameY : inputBasisY;
    }
    Vec3 inAxisZ() const {
        return (wrapperRef !is null && wrapperInputFrameValid)
             ? wrapperInputFrameZ : inputBasisZ;
    }

    // Phase 4 — property-panel back-pointer. Set by the wrapper at
    // `activate()` (the only path that constructs MoveTool); read
    // by `drawProperties` to route slider edits through
    // `wrapperRef.applyMovePanelDelta(localDiff)` so panel and drag
    // share the same `applyTRS` evaluate. Stored as `TransformTool`
    // to avoid a top-level import of `tools.xfrm_transform` (which
    // imports back into MoveTool — mutual dependence is fine at the
    // type level but ugly at the module level). `drawProperties`
    // casts when needed.
    TransformTool wrapperRef;

private:
    // Phase 3 — `dragDelta` + `dragDeltaAtDragStart` deleted. The
    // wrapper now owns the accumulated world delta (its
    // `accumulatedWorldDelta` / `accumulatedAtDragStart`) plus the
    // per-drag full-mesh `dragBaseline` that `applyTRS` rebuilds from.
    Vec3     propInput;       // basis-local slider state (drawProperties)

    bool     ctrlConstrain;        // Ctrl: axis TBD from initial movement (only for dragAxis==3)
    int      constrainStartMX, constrainStartMY;
    // (lastSnap moved to TransformTool — same semantics, also drives
    // the live click-outside snap preview now.)

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
        handler = new MoveHandler(Vec3(0, 0, 0));
        cachedCenter = Vec3(0, 0, 0);
    }

    void destroy() {
        handler.destroy();
    }

    override string name() const { return "Move"; }

    override void activate() {
        super.activate();
        propInput = Vec3(0, 0, 0);
    }

    // No `params()` override: TX/TY/TZ live on the wrapper now
    // (`XfrmTransformTool.params()` at xfrm_transform.d), since
    // factory ids `move` / `xfrm.transform` etc. all route to the
    // wrapper. `tool.attr <id> TX` writes into the wrapper's
    // `run.t`, then `tool.doApply` → `applyHeadless()`
    // → `applyTRS(mesh.vertices.dup)` uses it.

    // Phase 3 — MoveTool is only ever instantiated by
    // `XfrmTransformTool`; the wrapper overrides `applyHeadless` to
    // route through the unified `applyTRS(mesh.vertices.dup)` path.
    // No factory builds a bare MoveTool any more, so the sub-tool's
    // own `applyHeadless` was dead code and was removed.

    // Phase 3 — the edit session lives on the wrapper now. MoveTool's
    // deactivate just resets sub-tool state via `super.deactivate()`;
    // the wrapper's `deactivate()` already committed any open edit
    // before forwarding.
    override void deactivate() {
        super.deactivate();
    }

    // Register this bank's gizmo handles into the shared arbiter `th`
    // at part-id offset `base` (so overlapping handles across banks get
    // distinct parts). Order = hitTestAxes priority (circles > box >
    // arrows) so the highlighted handle matches the one a click grabs.
    // Does NOT begin()/update()/suppress() — the wrapper owns the
    // single test+update pass.
    void registerHandles(ToolHandles th, int base) {
        th.add(handler.circleXY,  base + 4);
        th.add(handler.circleYZ,  base + 5);
        th.add(handler.circleXZ,  base + 6);
        th.add(handler.centerBox, base + 3);
        th.add(handler.arrowX,    base + 0);
        th.add(handler.arrowY,    base + 1);
        th.add(handler.arrowZ,    base + 2);
    }

    void registerAxisHandles(ToolHandles th, int base) {
        th.add(handler.arrowX, base + 0);
        th.add(handler.arrowY, base + 1);
        th.add(handler.arrowZ, base + 2);
    }

    void registerCompactHandles(ToolHandles th, int base) {
        th.add(handler.centerBox, base + 3);
        th.add(handler.arrowX,    base + 0);
        th.add(handler.arrowY,    base + 1);
        th.add(handler.arrowZ,    base + 2);
    }

    void setWrapperGizmoPose(Vec3 center, Vec3 bX, Vec3 bY, Vec3 bZ) {
        cachedCenter = center;
        handler.setPosition(center);
        // flex_border_handles_plan.md Phase 2 — the wrapper passes the Model-C
        // RENDER basis (idle: live currentBasis; during a drag: the gesture-
        // frozen `(axisTracksSelection ? R_gesture : I)·B0`). It is now applied
        // UNCONDITIONALLY — the old `dragAxis < 0` render gate is removed so the
        // rendered orientation follows renderBasis cross-bank (Risk 1). The INPUT
        // projection is unaffected: it reads the separately-frozen `inputBasis*`
        // (Phase 1), never handler.axis*, so the gesture math stays stable while
        // the rendered frame moves.
        handler.setOrientation(bX, bY, bZ);
    }

    // Recompute gizmo center from current selection / mesh state.
    //
    // Phase 3 — the wrapper owns the selection/mutation-change commit
    // hook AND the mid-tool falloff-change re-apply (both keyed off
    // its own `editBaseline()`). MoveTool's update only refreshes the
    // gizmo center from ACEN when idle. The wrapper checks the same
    // selection/mutation versions BEFORE calling moveSub.update(),
    // so by the time we get here either: (a) versions matched (no
    // change), or (b) versions mismatched and the wrapper already
    // committed — either way reading the current ACEN center is
    // correct.
    override void update(ref VectorStack vts) {
        if (!active) return;

        // Skip during drag — selection and mesh can't change "outside"
        // the tool's own input. Without this, a drag motion event
        // would mid-frame re-pull the ACEN center and yank the gizmo
        // off the cursor.
        if (dragAxis >= 0) return;

        // Wrapper owns the open-edit gate (skip ACEN pull while a
        // tool-session edit is open — drag / slider already maintain
        // handler.center; re-pulling from ACEN here would snap the
        // gizmo to the bbox-centroid of the deformed selection).
        // Use the wrapper's `editIsOpen()` when available; bare
        // MoveTool (unit tests) sees this as a no-op (wrapperRef ==
        // null).
        bool wrapEditOpen = false;
        if (wrapperRef !is null) {
            // The cast can only fail if MoveTool got wired to a non-
            // XfrmTransformTool wrapperRef. That isn't a path that
            // exists today, so treat it as a programmer bug.
            import tools.xfrm_transform : XfrmTransformTool;
            auto w = cast(XfrmTransformTool) wrapperRef;
            if (w !is null) wrapEditOpen = w.publicEditIsOpen();
        }
        if (!wrapEditOpen) {
            cachedCenter = queryActionCenter(vts);
            handler.setPosition(cachedCenter);
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
    {
        if (!active) return;
        cachedVp = vp;

        // Orient the gizmo. When WRAPPED (XfrmTransformTool), the wrapper owns
        // the rendered basis: it calls setWrapperGizmoPose with the Model-C
        // renderBasis every frame BEFORE draw, so re-deriving currentBasis here
        // would clobber the gesture-frozen render frame. Only a STANDALONE bank
        // (no wrapper — unit tests) self-orients from the live basis.
        if (wrapperRef is null) {
            Vec3 bX, bY, bZ;
            currentBasis(bX, bY, bZ, vts);
            handler.setOrientation(bX, bY, bZ);
        }

        // Flush pending GPU upload once per frame (partial selection during drag).
        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        handler.draw(shader, vp);

        // Phase 7.3d: snap visual feedback. Yellow ring (highlighted)
        // + filled disc (snapped) at the snap candidate's screen pixel,
        // plus a cyan highlight on the actual mesh element being
        // snapped to (vertex / edge / face). No-op when no recent snap
        // (init/cleared SnapResult has highlighted=false).
        drawSnapOverlay(lastSnap, vp, *mesh);
        // Falloff overlay + endpoint handles are drawn ONCE at the
        // XfrmTransformTool wrapper, via the PipeGizmoHost-owned emitter.
        // The banks never touch falloff.
    }

    void drawAxesOnly(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
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

        handler.drawAxesOnly(shader, vp);
        drawSnapOverlay(lastSnap, vp, *mesh);
    }

    void drawCompact(const ref Shader shader, const ref Viewport vp, ref VectorStack vts)
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

        handler.drawAxesAndCenter(shader, vp);
        drawSnapOverlay(lastSnap, vp, *mesh);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Hide the screen-falloff disc on every LMB-up — onMouseButtonDown
        // turned it on unconditionally when Screen falloff is active so
        // the disc renders for the whole click+hold, including the
        // click-outside-gizmo case where no drag ever starts. Must run
        // before the dragAxis-guard early return below.
        if (e.button == SDL_BUTTON_LEFT) {
            import falloff_handles : screenFalloffLMBEnd;
            screenFalloffLMBEnd();
        }
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;

        ctrlConstrain = false;

        // Phase 3 — the wrapper now owns the GPU upload / gpuMatrix
        // reset / wholeMeshDrag handling, the commit-edit hooks, and
        // the BrushReset stroke boundary. MoveTool only resets the
        // drag-axis state it owns (dragAxis = -1) and clears the snap
        // overlay it published.
        dragAxis = -1;
        lastSnap = SnapResult.init;
        clearLastSnap();
        // Sticky-pin follow: when ACEN.userPlaced is active (set by
        // click-outside-relocate at drag start), update the pin to the
        // post-drag handler position. Without this, the next update()
        // frame asks ACEN for the center and gets back the original
        // click point — snap-final position is lost and the gizmo
        // visually jumps back. With snap on the jump is dramatic
        // because the gizmo had locked onto a discrete snap target.
        //
        // Gated to the relocate-allowed modes (Auto / None / Screen). In
        // Element mode the pin is owned by the click-pick (tryPickElement →
        // setUserPlaced at the picked element), NOT by the drag: re-pinning to
        // handler.center here would drag the gizmo OFF the picked element to
        // the moving-set position (the whole-mesh centroid under an empty
        // selection), so the gizmo snapped back to the center on release. Skip
        // the follow there and the picked-element pin survives the gesture.
        if (acenIsUserPlaced() && acenAllowsClickRelocate())
            notifyAcenUserPlaced(handler.center);
        lastSelectionHash = computeSelectionHash();
        return true;
    }

    // Returns 0/1/2=axis  3=most-facing plane  4/5/6=XY/YZ/XZ plane  -1=miss
    private int hitTestAxes(int mx, int my) {
        // Circles checked first (larger hit area, drawn behind arrows)
        if (handler.circleXY.hitTest(mx, my, cachedVp)) return 4;
        if (handler.circleYZ.hitTest(mx, my, cachedVp)) return 5;
        if (handler.circleXZ.hitTest(mx, my, cachedVp)) return 6;

        // Skip the center handle when hidden (element-move flow): the wrapper
        // hides it so a central click falls through to the element pick rather
        // than grabbing a center-plane drag. Mirrors the arrow isVisible guard.
        if (handler.centerBox.isVisible()
            && handler.centerBox.hitTest(mx, my, cachedVp)) return 3;

        Arrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        // Don't interfere with pan/rotate/zoom modifier combos.
        SDL_Keymod mods = SDL_GetModState();
        bool ctrl = (mods & KMOD_CTRL) != 0;
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        // Soft Drag: re-center the screen-falloff disc at the click
        // point on every fresh grab AND flip the overlay-visibility
        // flag on so the disc renders for the duration of the LMB
        // hold — even when the click lands outside a gizmo arrow
        // (no drag will start in that case, but the user still gets
        // visual confirmation of where the falloff is anchored).
        // Must happen BEFORE captureFalloffForDrag(vts) below so the
        // snapshot picks up the new center. No-ops when no Screen-
        // type falloff stage is active.
        {
            import falloff_handles : screenFalloffActive,
                                     screenFalloffSetCenter,
                                     screenFalloffLMBBegin;
            if (screenFalloffActive()) {
                screenFalloffSetCenter(e.x, e.y);
                screenFalloffLMBBegin();
            }
        }

        ctrlConstrain = false;
        lastClickWasRelocate = false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            // Ctrl constraint applies only to the most-facing plane (dragAxis==3)
            if (ctrl && dragAxis == 3) {
                ctrlConstrain = true;
                constrainStartMX = e.x; constrainStartMY = e.y;
            }
            lastMX = e.x; lastMY = e.y;
            // Freeze the input-projection basis for the gesture (= the
            // current idle basis = the frozen rendered orientation today).
            currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);
            buildVertexCacheIfNeeded();
            // Phase 3 — wrapper (`XfrmTransformTool.beginMoveDragSession`)
            // captures falloff / symmetry / edit-session baseline /
            // dragBaseline / fast-path predicate AFTER this returns
            // true. MoveTool only owns dragAxis + ctrlConstrain +
            // lastMX/Y now.
            return true;
        }

        // Click outside gizmo. Only Auto / None / Screen
        // ACEN modes relocate the gizmo on click-outside; the others
        // (Select / SelectAuto / Element / Local / Origin / Manual /
        // Border) keep the gizmo pinned to a selection-derived or
        // fixed point and ignore the click entirely.
        //
        //   Auto / None : project click onto the most-facing world-axis
        //                 plane through (0,0,0).
        //   Screen      : project click onto a camera-perpendicular
        //                 plane through the current selection bbox
        //                 centre.
        //
        // After relocation the drag plane is the most-facing plane
        // THROUGH the new gizmo center — drag projection feels natural
        // across camera angles regardless of where the new center
        // landed.
        if (!acenAllowsClickRelocate())
            return false;
        Vec3 hit;
        if (!computeClickRelocateHit(e.x, e.y, hit, vts))
            return false;
        // Off-gizmo relocate: mark so the wrapper commits the prior run
        // and re-stages this relocated pin before the new session opens.
        lastClickWasRelocate = true;
        beginScreenPlaneDragAt(e.x, e.y, hit, ctrl, /*notifyAcen=*/true, vts);
        return true;
    }

    // Start a screen-plane drag with the gizmo positioned at `hit`.
    // Extracted from the click-outside-gizmo path so callers can
    // initiate the same drag from a different anchor.
    // XfrmTransformTool calls this on its MoveTool sub-instance when
    // falloff.element click-pick lands off all gizmo handles — the
    // gizmo snaps to the picked centre and a screen-plane drag of
    // the prior selection (= moving set) starts on the same click —
    // an ElementMove-style "click+drag on an element drags the
    // selection through the new falloff anchor" UX.
    //
    // `notifyAcen` controls the ACEN userPlaced push: true for the
    // Auto/None/Screen relocate flow (so the user-placed point
    // sticks across queries), false for tool-driven re-anchors
    // where ACEN's pivot logic already owns the position.
    public void beginScreenPlaneDragAt(int mx, int my, Vec3 hit,
                                       bool ctrl, bool notifyAcen,
                                       ref VectorStack vts) {
        // Phase 3 — relocate is just "set up the dragAxis + visual
        // gizmo position". The wrapper's `beginMoveDragSession`
        // (called immediately after this returns) handles the
        // dragBaseline / edit-session / falloff/symmetry capture
        // / fast-path predicate.
        //
        // Note: we no longer pre-commit any open edit here. The
        // tool-session edit baseline (captured idempotently in the
        // wrapper) spans the WHOLE session including any relocate-
        // mid-session — same "live tool" undo unit MoveTool had
        // pre-refactor.
        handler.setPosition(hit);
        centerManual = true;
        if (notifyAcen)
            notifyAcenUserPlaced(hit);
        dragAxis = 3;   // most-facing plane through gizmo center
        lastMX = mx; lastMY = my;
        // Freeze the input-projection basis for this relocate drag.
        currentBasis(inputBasisX, inputBasisY, inputBasisZ, vts);
        buildVertexCacheIfNeeded();
        if (ctrl) {
            ctrlConstrain = true;
            constrainStartMX = mx; constrainStartMY = my;
        }
    }

    // Re-push the (relocated) gizmo pivot into the ACEN stage after the
    // wrapper has committed the prior run. At an in-session relocate the
    // relocate's own `notifyAcenUserPlaced` (fired from
    // `beginScreenPlaneDragAt`) ran while the prior session's snapshot was
    // still frozen, so it did NOT stage the new pin as a cancel baseline.
    // `commitEdit` then clears the freeze WITHOUT restoring (a committed
    // relocate is permanent). Re-firing the notification now — after the
    // freeze is cleared and before the new session's `beginEdit` re-freezes
    // — makes the relocated pin the fresh run's in-session-cancel baseline.
    // `handler.center` holds the relocated pivot (set by
    // `beginScreenPlaneDragAt`'s `handler.setPosition(hit)`).
    public void restageRelocatePin() {
        notifyAcenUserPlaced(handler.center);
    }

    // Phase 7.3a/c: route the would-be gizmo position through
    // SnapStage. Returns the (possibly-adjusted) world delta to apply
    // this frame. No-op when no pipeline is registered or snap is
    // disabled. The dragged element's own verts are excluded so a
    // single-vert drag can't snap to itself. 7.3d: also stashes the
    // SnapResult on the tool + global so draw() can render the
    // overlay and HTTP /api/snap/last can read it.
    private Vec3 applySnapToDelta(Vec3 gizmoCenter, Vec3 worldDelta,
                                  int sx, int sy, ref VectorStack vts)
    {
        import toolpipe.packets : SnapPacket;
        // SNAP packet is already published in vts (upstream stage ran
        // during the dispatcher's pipeline.evaluate).
        auto snapPkt = vts.get!SnapPacket();
        if (snapPkt is null || !snapPkt.enabled) {
            lastSnap = SnapResult.init;
            clearLastSnap();
            return worldDelta;
        }

        // Exclude verts the drag is moving — same set
        // buildVertexCacheIfNeeded already populated. Otherwise a
        // single-vert drag always snaps to its own (zero-distance)
        // projected pixel.
        uint[] exclude;
        exclude.length = vertexProcessCount;
        foreach (i; 0 .. vertexProcessCount)
            exclude[i] = cast(uint)vertexIndicesToProcess[i];

        Vec3 desired = gizmoCenter + worldDelta;
        SnapResult sr = snapCursor(desired, sx, sy, cachedVp,
                                   *mesh, *snapPkt, exclude);
        lastSnap = sr;
        publishLastSnap(sr);
        if (sr.snapped)
            return constrainSnapDelta(sr.worldPos - gizmoCenter);
        return worldDelta;
    }

    // Project a raw snap delta (snapTarget - gizmoCenter) onto the active
    // drag axis / plane so an off-axis snap candidate doesn't smear the
    // selection across axes. For an X-arrow drag with snap to a vertex
    // at (Tx, Ty, Tz), this returns ((Tx - Gx) * axisX) — i.e. the gizmo
    // moves only along X to the snap target's X coordinate. This is
    // "axis-locked snap".
    //
    // The centerBox handle (dragAxis==3) is intentionally NOT constrained:
    // it's the "free move" handle, and the user expectation is that
    // grabbing it + snapping lands the gizmo exactly at the snap point in
    // 3D. The explicit plane circles (4/5/6) keep their plane lock — the
    // user picked that plane on purpose.
    private Vec3 constrainSnapDelta(Vec3 delta) {
        // Single-axis drag — keep only the component along the locked axis.
        // Reads the unified gesture frame when wrapper-chained (gesture-frame
        // unification, Phase 2), else the bank's drag-start-frozen INPUT basis —
        // never the rendered `handler.axis*`, so input projection is insulated
        // from the rendered frame. The channel carries the same value the old
        // softBasis override wrote, so this is byte-identical when chained.
        debug assertWrapperInputFrameChained();
        Vec3 ax0 = inAxisX(), ax1 = inAxisY(), ax2 = inAxisZ();
        if (dragAxis == 0) return ax0 * dot(delta, ax0);
        if (dragAxis == 1) return ax1 * dot(delta, ax1);
        if (dragAxis == 2) return ax2 * dot(delta, ax2);
        // Plane circles — strip the component along the plane normal.
        if (dragAxis == 4) return delta - ax2 * dot(delta, ax2);
        if (dragAxis == 5) return delta - ax0 * dot(delta, ax0);
        if (dragAxis == 6) return delta - ax1 * dot(delta, ax1);
        // dragAxis == 3 (centerBox) and any unrecognised value: pass
        // through the full 3D snap delta.
        return delta;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (dragAxis == -1) {
            // Idle hover: refresh the live click-outside snap preview
            // so the cyan overlay shows where the gizmo would land if
            // the user clicked right now. hitTestAxes returns >= 0
            // when the cursor is on a gizmo handle (would start a
            // drag, not a relocate) — preview is suppressed there.
            updateLiveSnapPreview(e.x, e.y, hitTestAxes(e.x, e.y), vts);
            return false;
        }

        // Ctrl-constrain: wait for initial movement to determine which of the two
        // in-plane axes to lock to, then switch dragAxis to that axis (0/1/2).
        if (ctrlConstrain) {
            int tdx = e.x - constrainStartMX;
            int tdy = e.y - constrainStartMY;
            if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }

            // Identify the two basis axes that lie in the most-facing plane
            // (the third axis — the one most parallel to the camera ray — is
            // the plane normal).
            import std.math : abs;
            const ref float[16] vv = cachedVp.view;
            Vec3 camBack = Vec3(vv[2], vv[6], vv[10]);
            // ctrlConstrain only ever runs for the center-box drag (dragAxis==3),
            // which the wrapper excludes from chaining (chained=false), so the
            // selector resolves to the live `inputBasis*` here — basis-free as
            // before. Routed through the selector for uniformity.
            debug assertWrapperInputFrameChained();
            Vec3 di0 = inAxisX(), di1 = inAxisY(), di2 = inAxisZ();
            float aXdot = abs(dot(camBack, di0));
            float aYdot = abs(dot(camBack, di1));
            float aZdot = abs(dot(camBack, di2));
            int ax1, ax2;
            if      (aXdot >= aYdot && aXdot >= aZdot) { ax1 = 1; ax2 = 2; } // normal=axisX → Y,Z
            else if (aYdot >= aXdot && aYdot >= aZdot) { ax1 = 0; ax2 = 2; } // normal=axisY → X,Z
            else                                       { ax1 = 0; ax2 = 1; } // normal=axisZ → X,Y

            // Project each candidate axis onto screen; pick best alignment.
            float cx, cy, dummy;
            float dmag = sqrt(cast(float)(tdx*tdx + tdy*tdy));
            float ndx = tdx / dmag, ndy = tdy / dmag;
            Vec3[3] axisEnds = [handler.arrowX.end, handler.arrowY.end, handler.arrowZ.end];
            dragAxis = ax1; // fallback
            if (projectToWindowFull(handler.center, cachedVp, cx, cy, dummy)) {
                float bestDot = -1.0f;
                foreach (a; [ax1, ax2]) {
                    float ax, ay, andcZ;
                    if (!projectToWindowFull(axisEnds[a], cachedVp, ax, ay, andcZ)) continue;
                    float sdx = ax - cx, sdy = ay - cy;
                    float slen = sqrt(sdx*sdx + sdy*sdy);
                    if (slen < 1.0f) continue;
                    float dot = abs(ndx * sdx/slen + ndy * sdy/slen);
                    if (dot > bestDot) { bestDot = dot; dragAxis = a; }
                }
            }
            ctrlConstrain = false;
            lastMX = e.x; lastMY = e.y;
            return true; // axis locked — movement starts on the next motion event
        }

        // Project the screen drag against the unified gesture frame when
        // wrapper-chained (gesture-frame unification, Phase 2), else the bank's
        // own drag-start INPUT basis. The center-box (dragAxis==3) is excluded
        // from chaining at the push site, so its plane drag resolves to the live
        // `inputBasis*` here — basis-free as before.
        debug assertWrapperInputFrameChained();
        Vec3 mi0 = inAxisX(), mi1 = inAxisY(), mi2 = inAxisZ();
        Vec3 worldDelta;
        bool skip;
        if (dragAxis <= 2)
            worldDelta = axisDragDelta(e.x, e.y, lastMX, lastMY,
                                       dragAxis, handler,
                                       mi0, mi1, mi2,
                                       cachedVp, skip);
        else
            worldDelta = planeDragDelta(e.x, e.y, lastMX, lastMY,
                                        dragAxis, handler.center, cachedVp, skip,
                                        mi0, mi1, mi2);
        if (skip) { lastMX = e.x; lastMY = e.y; return true; }

        // Phase 7.3a: snap. Bend the would-be gizmo position towards a
        // mesh element when SNAP is on. Adjust `worldDelta` so the
        // gizmo lands at the snapped point — selection moves by the
        // same delta. Snap result for the overlay was stashed in
        // `lastSnap` inside `applySnapToDelta`.
        worldDelta = applySnapToDelta(handler.center, worldDelta, e.x, e.y, vts);

        // Phase 3 — single-source refactor.
        //
        // MoveTool's drag-axis path no longer mutates geometry. It
        // produces ONE basis-local scalar (projected onto the gizmo's
        // shared axes — same basis as `run.t`'s
        // interpretation in `XfrmTransformTool.applyTRS`) and parks it
        // in `pendingTranslateDelta`. The wrapper drains this on every
        // motion event, accumulates into `headlessTranslate`, and
        // runs the unified `applyTRS(dragBaseline)`. Under ACEN.Local
        // + axis.local the SAME basis-local scalar then flows to
        // `applyTranslatePerCluster` (one scalar per cluster, applied
        // along each cluster's OWN signed fwd) so per-cluster
        // magnitudes can't diverge — that was the round-1 bug.
        //
        // `dragDelta`, `gpuMatrix`, `needsGpuUpdate`, the visual
        // `handler.setPosition` update, and the wholeMesh fast-path
        // are now all the wrapper's responsibility. Idle/hover and
        // falloff-gizmo branches above are unchanged.
        pendingTranslateDelta = pendingTranslateDelta
            + Vec3(dot(worldDelta, mi0),
                   dot(worldDelta, mi1),
                   dot(worldDelta, mi2));

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override void drawProperties() {
        // Phase 4 — slider edits route through
        // `XfrmTransformTool.applyMovePanelDelta`, the same
        // `applyTRS` evaluate the drag uses. Without a wrapper
        // (legacy unit-test paths that construct a bare MoveTool
        // directly) the panel does nothing — gizmo drag is the
        // only mutation path. Production never hits this branch:
        // MoveTool is only instantiated by `XfrmTransformTool`
        // which sets `wrapperRef` at `activate()`.
        Vec3 ax = handler.axisX, ay = handler.axisY, az = handler.axisZ;

        // The wrapper's `run.t` is the BASIS-LOCAL
        // cumulative for the current drag. With dragAxis >= 0 we
        // mirror that into propInput so the sliders track the live
        // drag. Outside a drag, propInput stays at whatever the
        // last slider edit left it (= 0 after a tool-session
        // commit, since reactivate zeroes the wrapper's
        // run.t).
        import tools.xfrm_transform : XfrmTransformTool;
        auto wrap = cast(XfrmTransformTool) wrapperRef;
        if (wrap !is null && dragAxis >= 0) {
            propInput = wrap.run.t;
        }
        Vec3 propBefore = propInput;

        ImGui.DragFloat("X", &propInput.x, 0.01f, 0, 0, "%.4f");
        bool xActive = ImGui.IsItemActive();
        bool xDone   = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propInput.y, 0.01f, 0, 0, "%.4f");
        bool yActive = ImGui.IsItemActive();
        bool yDone   = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propInput.z, 0.01f, 0, 0, "%.4f");
        bool zActive = ImGui.IsItemActive();
        bool zDone   = ImGui.IsItemDeactivatedAfterEdit();

        if (wrap !is null && (xActive || yActive || zActive)) {
            // localDiff is the slider edit's basis-local delta this
            // frame. Hand it to the wrapper, which captures (idempotent)
            // a drag baseline + edit baseline, accumulates into its
            // `run.t`, and runs `applyTRS`.
            Vec3 localDiff = propInput - propBefore;
            if (localDiff.x != 0 || localDiff.y != 0 || localDiff.z != 0) {
                wrap.applyMovePanelDelta(localDiff);
                // Visual gizmo follow — same world-delta projection
                // applyTRS does in the non-per-cluster T branch.
                Vec3 delta = ax*localDiff.x + ay*localDiff.y + az*localDiff.z;
                handler.setPosition(handler.center + delta);
                cachedCenter = handler.center;
            }
        }

        if (wrap !is null && (xDone || yDone || zDone)) {
            gpu.upload(*mesh);
            // 7.5h: don't commit here either — props sliders are part
            // of the same tool session as gizmo drags. Commit fires
            // at deactivate / selection change.
        }
    }

    // Phase 3 — the `applyDelta` / `applyDeltaImmediate` /
    // `applyAbsoluteFromBaseline` / `applyPerClusterDelta` helpers
    // were deleted. The drag-axis branch produces a basis-local
    // gesture scalar (parked in `pendingTranslateDelta`); the
    // wrapper drains, accumulates into `run.t`, and
    // runs the single `applyTRS(dragBaseline)` evaluate which
    // dispatches into the same `xform_kernels.applyTranslate*` /
    // `applyTranslatePerCluster` routines those wrappers used to
    // call. Per-cluster magnitudes can no longer diverge because
    // the screen-projection happens ONCE per frame against the
    // gizmo's shared axes, not per-cluster.
}
