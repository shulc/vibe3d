module tools.transform.xfrm_handles;

/// Gizmo-handle half of `XfrmTransformTool` — posing the shared gizmo,
/// registering the three banks' handles into the cross-bank arbiter,
/// refreshing their hit geometry, routing a resolved part id to the bank that
/// owns it, and serialising the arbiter for `/api/tool/handles`.
/// Split out of `xfrm_transform.d` by task 0719 (audit 4, finding T1).
///
/// A `mixin template`, for the reason derived in `xfrm_item.d`'s header: the
/// bodies below read the tool's `private` state AND `xfrm_transform.d`'s
/// module-`private` part-id decoding (`MOVE_BASE` / `ROT_BASE` /
/// `SCALE_BASE`, `latchedHandlePart`, `compactScaleHeadFallbackHitPart`),
/// and a template mixin resolves identifiers at the INSTANTIATION site, so
/// all of that stays reachable with nothing made public. That decoding and
/// its two unittests therefore stay in the host on purpose: moving them here
/// would have meant publishing them, and the split does not buy itself with
/// visibility.
///
/// Same hazard as the other halves: a member declared directly in the class
/// silently WINS over one of the same name mixed in. Never leave a copy behind.

mixin template XfrmHandlesImpl() {
    private void setSharedGizmoPose(Vec3 center, ref VectorStack vts) {
        Vec3 bX, bY, bZ;
        renderBasis(bX, bY, bZ, vts);
        // Per-frame fan-out over the enabled banks. setWrapperGizmoPose is
        // sub-tool-specific (not on the TransformTool base), so each bank is
        // called out explicitly — no allocation, bank order T → R → S.
        if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);
        syncScaleBankStandoff();
    }

    private void installPreparedSharedGizmoPose(Vec3 center, Vec3 bX,
                                                Vec3 bY, Vec3 bZ)
            nothrow @nogc {
        if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);
        if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);
        syncScaleBankStandoff();
    }

    // The scale bank's axis boxes stand a further tenth of an arm out when
    // ANOTHER bank shares the gizmo (handles/gl_util.GIZMO_SCALE_ARM_CROSS_-
    // BANK_SHIFT). The gate is a disjunction — either companion pushes the
    // boxes out, and it took a second measuring run to establish that, since
    // an all-on cell against an all-off one fits `T`, `R` and `T || R` alike.
    //
    // The wrapper is the only thing that knows what else is drawn, so it is
    // the only writer. It re-derives the value rather than caching it: `flagT`
    // / `flagR` are Param-bound and a headless `tool.attr` write can flip
    // either between any two frames, with no hook to observe it.
    //
    // Called from BOTH per-frame funnels because the two cover different
    // paths and neither covers the other: `setSharedGizmoPose` runs at the top
    // of `update()` and `draw()` (so replica cells, which skip the arbiter
    // block, still draw the right box), and `registerGizmoHandles` runs
    // immediately before `refreshBankGeometry` on the mouse-down hit pass
    // (which registers and refreshes without ever posing). Both write the same
    // pure function of the flags, so the order they run in cannot matter.
    private void syncScaleBankStandoff() nothrow @nogc {
        if (flagS) scaleSub.handler.setCrossBankShift(flagT || flagR);
    }

    private bool compactPresentation() const {
        return handlePresentation == "compact";
    }

    // Element-move flow active? = the WGHT slot is falloff.element, so a
    // plain click relocates the gizmo onto the picked element (tryPickElement).
    // Mirrors the captured element-move preset (element centre + falloff.element):
    // in that mode the reference drops the transform center handle (xfrm.transform
    // -16777211 vs the normal +EASFQG) so every click is an element pick, not
    // a center-handle grab. We match by hiding the Move centerBox below.
    private bool elementPickActive() const {
        auto fs = activeFalloffStage();
        return fs !is null && fs.type == FalloffType.Element;
    }

    private void registerGizmoHandles(ToolHandles th) {
        // Hide the Move center handle in the element-move flow (reference parity):
        // invisible → ToolHandles.test() skips it (so a central click falls
        // through to tryPickElement) AND BoxHandler.draw early-outs (so it
        // isn't shown). Axis arrows / plane handles stay live.
        //
        // Task 0614 Phase 3 / Phase 0c finding: item mode hides the SAME
        // handle for a different, shipped-config-grounded reason — the
        // item Move preset sets `cenHandle 0` ("Show center handle for
        // translation"), where the bare Move preset and the item Rotate/
        // Scale presets do not. Side benefit: this also makes
        // `moveCenterBoxDragActive()` trivially false in item mode, so the
        // freeze's `frame.valid && !moveCenterBoxDragActive()` seed
        // condition simplifies rather than gaining a case.
        if (flagT)
            moveSub.handler.centerBox.setVisible(
                !elementPickActive() && !itemSubjectActive());

        // Uniform scale mode: propagate the draw-suppression flag to the
        // handler so only the centre disc is rendered (arrows/circles are
        // gated inside ScaleHandler.draw by this flag — updateGeometry()
        // would override a plain setVisible(false) on arrows each frame).
        if (flagS)
            scaleSub.handler.uniformMode = uniform;

        // Same kind of per-frame bank configuration as `uniformMode` above,
        // and it must land BEFORE `refreshBankGeometry` re-derives the hit
        // geometry a few statements later at both call sites.
        syncScaleBankStandoff();

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
        if (flagS) {
            if (uniform)
                // Uniform preset: only the centre disc is interactive.
                // Part id SCALE_BASE+3 matches centerDisk's slot in registerHandles.
                th.add(scaleSub.handler.centerDisk, SCALE_BASE + 3);
            else
                scaleSub.registerHandles(th, SCALE_BASE);
        }
    }

    // Task 0212 (rotate/scale hover-highlight flicker root cause + fix):
    // re-establish OWNER-cell hit geometry for every enabled bank
    // immediately before the shared arbiter's Test pass resolves. Without
    // this, `toolHandles.update()`/`.test()` hit-test against whatever
    // camera-dependent members (`RotateHandler.startAngle`, ScaleHandler's
    // `centerDisk.normal`/`radius`, plane-circle offsets) a NON-OWNER
    // (visualOnly) cell's draw last wrote under its OWN foreign `vp` — a
    // discrete miss that flips the resolved hot part frame-to-frame (the
    // `overlayHot` DirtyKey term then amplifies it into a visible flicker;
    // see doc/rotate_scale_hover_flicker_plan.md).
    //
    // `syncGeometry` is exactly the CPU-only, side-effect-free geometry math
    // the subsequent bank `draw()` would run anyway — idempotent, so this
    // extra call produces byte-identical rendered output; it only makes the
    // Test pass see owner-correct geometry a few statements earlier. It
    // reads center/axis*/scaleAccum (already set by `setSharedGizmoPose`
    // above) and writes ONLY derived hit/draw geometry — never `axis*` /
    // `center` themselves — so it cannot perturb the frozen-basis /
    // `dragAxis < 0` setOrientation gating ([[flex_border_gizmo_model_c]],
    // [[flex_move_handle_flip_fix]]) or the Model-C render-basis freeze.
    // Gated on the SAME flagT/R/S the registered set uses, so refreshed ==
    // registered. In `--test` (single cell, no foreign draws) geometry was
    // already owner-correct, so this is a byte-neutral no-op on output.
    private void refreshBankGeometry(const ref Viewport vp) {
        // Same explicit fan-out as setSharedGizmoPose: `handler` is
        // typed per sub-tool (MoveHandler / RotateHandler / ScaleHandler),
        // so a base-class array cannot reach syncGeometry.
        if (flagT) moveSub.handler.syncGeometry(vp);
        if (flagR) rotateSub.handler.syncGeometry(vp);
        if (flagS) scaleSub.handler.syncGeometry(vp);
    }

    version(unittest) bool routeResolvedHandlePartForTest(
            ref const SDL_MouseButtonEvent e, ref VectorStack vts, int hitPart) {
        return routeResolvedHandlePart(e, vts, hitPart);
    }

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
            // An off-gizmo press in a PINNED action-centre mode: the bank now
            // starts a screen-plane drag from the pinned pivot instead of
            // declining the press, so it no longer falls through to the
            // off-gizmo commit boundary at the bottom of this method. That
            // boundary still has to happen — an off-gizmo press splits the undo
            // run in every mode; only the pin handling differs — so it runs
            // here, with the pin re-staged VERBATIM (nothing relocated).
            bool wasPinnedOffGizmo = moveSub.lastClickWasOffGizmo && !wasRelocate;
            moveSub.lastClickWasOffGizmo = false;   // consume
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
                    consolidateRunAndAdvance();
                }
                // Apply-path Phase 2: a relocate is a GEOMETRY-run boundary (the
                // pivot moved + the prior run committed) — re-capture the run
                // baseline at the relocated mesh on the fresh Move gesture below.
                resetRun();   // + P-F: relocate freezes a NEW run-frame (G8)
            }
            // The pinned-mode twin of the block above. Identical set of actions
            // in an identical order — session-close for every open bank, pin
            // re-stage, consolidate + nextRun, resetRun — with ONE difference:
            // `stageCurrentActionCenterPin` (verbatim, no pin mutation) instead
            // of `restageRelocatePin` (which re-fires notifyAcenUserPlaced and
            // would force-place a pivot these modes must own themselves). It is
            // the same pin call the off-gizmo boundary at the bottom of this
            // method makes, for the same reason: the commit cleared the freeze,
            // so the drag opening below must freeze the CURRENT pin, not a
            // stale one.
            if (wasPinnedOffGizmo) {
                if (editIsOpen()) commitEdit("Move");
                rotateSub.commitSessionIfOpen();
                scaleSub.commitSessionIfOpen();
                moveSub.stageCurrentActionCenterPin();
                if (history !is null && history.runOpen()) {
                    consolidateRunAndAdvance();
                }
                resetRun();
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
            // An off-gizmo press now ALSO starts a drag — the screen-space
            // arcball — so it no longer falls through to the else-branch's run
            // boundary below. That boundary still has to happen: an off-gizmo
            // press splits the undo run in every action-centre mode, and only
            // the PIN handling differs between a relocate (Auto/None/Screen —
            // the press moved the pivot, re-stage the moved one) and a pinned
            // mode (the press moved nothing, re-stage the current one VERBATIM).
            // Both are the exact twins of the Move arm's pair above, in the same
            // order, for the same reasons.
            immutable bool rotWasRelocate = rotateSub.lastClickWasRelocate;
            rotateSub.lastClickWasRelocate = false;   // consume
            immutable bool rotWasPinnedOffGizmo =
                rotateSub.lastClickWasOffGizmo && !rotWasRelocate;
            rotateSub.lastClickWasOffGizmo = false;   // consume
            if (rotWasRelocate || rotWasPinnedOffGizmo) {
                // Session-close for every open bank. rotateSub's own relocate
                // branch already committed ITS session and mirrored the Move
                // commit; the pinned branch commits nothing, so both are done
                // here and both are no-ops when already closed.
                if (editIsOpen()) commitEdit("Move");
                rotateSub.commitSessionIfOpen();
                scaleSub.commitSessionIfOpen();
                // Run-close: re-stage the pin the fresh gesture's beginEdit will
                // freeze as its in-session-cancel baseline. A relocate moved the
                // pin, so it is staged from the (already-pushed) userPlaced
                // state; a pinned mode moved nothing, so it is staged verbatim.
                if (rotWasRelocate) rotateSub.restageActionCenterPin();
                else                rotateSub.stageCurrentActionCenterPin();
                if (history !is null && history.runOpen()) {
                    consolidateRunAndAdvance();
                }
                resetRun();
            }
            // Principal-axis ring (0/1/2), view-ring (3) AND the off-gizmo
            // arcball (which arms as 3) → wrapper owns geometry via applyTRS
            // (capture the drag state). Principal axes drain into headlessRotate
            // (Euler); the view-ring and the arcball drain into the arbitrary-
            // world-axis fold. A press that starts no drag at all (dragAxis == -1
            // — a pivot that does not project) opens no session.
            if (rotateSub.dragAxis >= 0 && rotateSub.dragAxis <= 3) {
                // Bank-switch run boundary (Q-c): a switch INTO Rotate from a
                // prior Move/Scale run consolidates that run first, before the
                // fresh single-bank rotate run opens. No-op when the prior run
                // was already Rotate. With Phase 2 R/S recording live, the run
                // being consolidated here is whatever bank's tagged tail just
                // ended (Move, or a prior Rotate/Scale run after a relocate).
                noteRunBank(DragBank.Rotate);
                beginRotateDragSession(vts);
            } else if (!rotWasRelocate && !rotWasPinnedOffGizmo) {
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
                //
                // An off-gizmo press cannot reach here any more unless the pivot
                // did not project and no drag armed — and in that case the block
                // above has ALREADY closed the run, so it is excluded rather than
                // allowed to close it twice.
                if (history !is null && history.runOpen()) {
                    closeRunBoundary();
                }
                // Apply-path Phase 2: relocate / no-axis click = geometry-run
                // boundary; re-capture the run baseline on the next gesture.
                resetRun();   // + P-F: this boundary freezes a NEW run-frame
            } else {
                rotDragAxisIdx = -1;
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
            // An off-handle press in a RELOCATING action-centre mode now
            // relocates AND arms a plane-scale drag, so `dragAxis >= 0` no
            // longer means "a handle was grabbed". The relocate is still a run
            // boundary — an off-gizmo press splits the undo run in every mode —
            // and that work used to happen only in the `else` arm below, which
            // this press no longer reaches. Mirrors the Move arm's `wasRelocate`
            // consume above and Rotate's off-ring arm, which have had exactly
            // this shape since their own off-gizmo drags landed.
            bool scaleWasRelocate = scaleSub.lastClickWasRelocate;
            scaleSub.lastClickWasRelocate = false;   // consume
            if (scaleSub.dragAxis >= 0) {
                if (scaleWasRelocate && history !is null && history.runOpen()) {
                    closeRunBoundary();
                }
                if (scaleWasRelocate) resetRun();
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
                    closeRunBoundary();
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

    // Task 0209 (Quad/Split any-cell input), Phase 4: the shared "hot"
    // (rollover) part, exposed publicly so app.d's per-frame DirtyKey stamp
    // can detect a hot-part flip and re-render every eligible Quad/Split
    // cell to mirror it (see viewport.d's `DirtyKey.overlayHot` doc).
    // `toolHandles` itself stays private to this module — everything below
    // this point in the class is under the `private:` label.
    public int hotPart() const { return toolHandles.hot; }

    // Task 0234 (GET /api/tool/handles): wrap the shared cross-bank arbiter's
    // registry as JSON, keyed against the owner-cell viewport it was last
    // hit-tested/drawn against. `viewport` is echoed so a future
    // `?viewport=N` extension (Quad/Split, see the plan's risk 2) has
    // something to compare against — this tool doesn't expose `cachedVp`
    // itself, only its serialization.
    public override JSONValue toolHandlesJson() const {
        JSONValue root = toolHandles.toJson(cachedVp);
        auto vpObj = JSONValue.emptyObject;
        vpObj["x"]      = JSONValue(cachedVp.x);
        vpObj["y"]      = JSONValue(cachedVp.y);
        vpObj["width"]  = JSONValue(cachedVp.width);
        vpObj["height"] = JSONValue(cachedVp.height);
        root["viewport"] = vpObj;
        return root;
    }
}
