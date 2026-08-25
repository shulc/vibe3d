module tools.transform.xfrm_apply;

/// Geometry-apply half of `XfrmTransformTool` — the single apply entry point
/// (`applyTRS`), the canonical-matrix fold it composes, its two per-pass
/// kernels, and the dormant pow-scale chain that survives for
/// `compoundPasses != 1`. Split out of `xfrm_transform.d` by task 0719
/// (audit 4, finding T1).
///
/// A `mixin template`, for the reason derived in `xfrm_item.d`'s header: these
/// bodies read the tool's `private` run state and the host module's
/// module-`private` `restoreBaselinePrefix`, and a template mixin resolves
/// identifiers at the INSTANTIATION site, so nothing had to be published.
/// `restoreBaselinePrefix` and its unittest stay in the host for exactly that
/// reason — reachable from here, and not worth publishing to move.
///
/// The pure per-vertex math these bodies call — `applyXformMatrix`,
/// `applyRotateFromOrig`, `applyScaleFromActivation`, `blendToIdentity` — is
/// NOT here: it lives in `xform_kernels.d`, is free of tool state, and is
/// unit-tested there (task 0719, finding T5). What this file holds is the
/// composition and ordering around those kernels.
///
/// Same hazard as the other halves: a member declared directly in the class
/// silently WINS over one of the same name mixed in. Never leave a copy behind.

mixin template XfrmApplyImpl() {
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
            restoreBaselinePrefix(mesh.vertices, baseline);
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

        // Task 0614 Phase 3 — item branch. Short-circuits BEFORE
        // buildVertexCacheIfNeeded() (Q2 hazard: mesh.selectedVertexIndices*
        // returns ALL vertices on an empty selection, so reaching the vertex
        // path in item mode would translate the whole layer's mesh). Reads
        // `subj.selType` FRESH from THIS call's own `buildLocalVts` above —
        // not the instance-cached `cachedSubjType_` (refreshed only at this
        // tool's three per-frame/per-event entry points — `update()`,
        // `draw()` and `syncInputViewport` — so it is one frame phase behind
        // for anyone who arrives by another route) — so a headless/
        // panel-replay `applyTRS` call with no preceding mouse event still
        // resolves the LIVE subject correctly.
        //
        // Goes THROUGH the freeze (REVIEW-1 / Phase 2.5), not around it:
        // restoreItemBaseline() (the item analogue of restoreBaseline())
        // FIRST, then currentBasis(), then freezeRunFrameIfNeeded() — the
        // SAME three-step prologue the vertex path below runs, just against
        // the item baseline instead of the vertex one. An early return above
        // the freeze would strand runFrameValid false for the whole item run
        // (§(b) of the plan's boxed warning).
        if (subj.selType == SelType.Item) {
            restoreItemBaseline();
            Vec3 ibX, ibY, ibZ;
            currentBasis(ibX, ibY, ibZ, vts);
            freezeRunFrameIfNeeded(pivot, ibX, ibY, ibZ);
            return applyItemTRS();
        }

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
        // NIT (0614 review): no post-call assert here — freezeRunFrameIfNeeded
        // sets runFrameValid=true on the only path where it was false, so
        // asserting it afterward is a tautology that can never catch a bug.
        freezeRunFrameIfNeeded(pivot, bX, bY, bZ);

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
                applyTRSLegacyPowPath(baseline, pivot, bX, bY, bZ, cp, ap,
                                      hasT, hasS, viewAxis, viewAngleDeg);
            }  // MS-4.3 — legacy per-pass chain → applyTRSLegacyPowPath
        }

        // (MS-3.6) The MS-2 measure-only per-pass shadow was retired here: it
        // reconstructed the LEGACY decomposed T->R->S chain and compared it to
        // the live apply, but MS-4.3/4.4 deliberately replaced that chain with the
        // canonical-matrix fold (which diverges from the per-pass reconstruction
        // under fractional falloff — the validated correctness change), so the
        // shadow now guarded a superseded model. The fold is gated instead by the
        // reference-parity fixtures (tests/fixtures/falloff_{rot,trs,local}_*.json,
        // tests/test_fixture_falloff_*).

        // CONS post-pass (Stage 4 of doc/cons_constraint_plan.md):
        // Re-project each MOVED vertex's final position onto the nearest
        // background-mesh surface. Runs AFTER applyFold / legacy chain so
        // it sees the final geometry, BEFORE `return true;`.
        //
        // Working assumptions (unverified — see plan DoD):
        //   (a) `point` mode = nearest-foot (perpendicular closest-point),
        //       not camera-ray projection (§6.5).
        //   (b) Per-vertex projection applied post-fold, not per-delta at
        //       move.d:applySnapToDelta (§6.6). Both are revisited if/when
        //       Stage-0 captures contradict them (swap behind the same packet,
        //       no API churn).
        //
        // Teleport guard: skip verts whose final position equals their
        // baseline. The fold kernel's `w==0` early-continue leaves those
        // verts at baseline; projecting them would yank them to the bg
        // surface even though they didn't participate in the transform.
        {
            import toolpipe.packets : ConstrainPacket;
            import toolpipe.packets : ConstrainGeom;
            import snap : backgroundSourcesFull;
            import constraint : constrainPoint;
            if (auto consPkt = vts.get!ConstrainPacket()) {
                if (consPkt.enabled && consPkt.geom != ConstrainGeom.Off) {
                    auto bgSrc = backgroundSourcesFull();
                    if (bgSrc.length > 0) {
                        // Task 1069 — the ROUTED form. This pass does not
                        // "need the same treatment" as a nicety: left alone it
                        // silently becomes a NO-OP under routing, because its
                        // teleport guard compares `mesh.vertices[vid]` against
                        // `baseline[vid]` and under routing those are equal for
                        // EVERY vertex. Every vertex would be skipped and
                        // nothing would notice — a test that only asserts "the
                        // base was not corrupted" passes on the dead pass.
                        //
                        // The comparison point is the RUN baseline
                        // (`route.runPos`), NOT the true base: a vertex that
                        // already carried a delta from an earlier gesture and
                        // that the falloff gives weight 0 this gesture is
                        // skipped by the fold kernel, so it still sits at its
                        // run position — comparing against the true base would
                        // see a difference, not skip it, and CONS would
                        // re-project (and corrupt) a delta this gesture never
                        // touched. That is only visible with TWO gestures.
                        import tools.transform.morph_route :
                            routedDisplayPos, storeRouted;
                        auto route = buildMorphRouteFor(baseline);
                        const bool routed = route.covers(mesh.vertices.length);
                        auto routeMap = routed ? mesh.morphMapForWrite(route.name) : null;
                        bool consWrote = false;
                        foreach (vid; vertexIndicesToProcess) {
                            if (vid < 0 || vid >= cast(int)mesh.vertices.length)
                                continue;
                            // Teleport guard: leave w==0 verts (the fold left
                            // them at their run baseline) undisturbed.
                            Vec3 finalPos = (routeMap !is null)
                                          ? routedDisplayPos(routeMap, route, cast(size_t)vid)
                                          : mesh.vertices[vid];
                            Vec3 basePos  = (routeMap !is null)
                                          ? route.runPos[vid]
                                          : baseline[vid];
                            if (finalPos.x == basePos.x
                             && finalPos.y == basePos.y
                             && finalPos.z == basePos.z)
                                continue;
                            // editDelta is a meaningful projection direction only for
                            // translation; for rotate/scale each vertex has its own
                            // non-uniform displacement (vector-mode is analytic only for T).
                            Vec3 editDelta = finalPos - basePos;
                            Vec3 constrained = constrainPoint(
                                finalPos,
                                editDelta,
                                cachedVp,
                                bgSrc,
                                *consPkt);
                            if (routeMap !is null)
                                consWrote |= storeRouted(routeMap, route,
                                                         cast(size_t)vid, constrained);
                            else
                                mesh.vertices[vid] = constrained;
                        }
                        if (consWrote) mesh.noteChange(MeshEditScope.Maps);
                    }
                }
            }
        }

        // Task 1906 stage 1, NIT7 — WRITE-AFTER-PUBLISH, NAMED SO STAGE 3
        // DOES NOT REDISCOVER IT. The pass above runs AFTER `applyFold` (or
        // the legacy chain) has already published this apply's class, and on
        // the UNROUTED branch it writes `mesh.vertices[vid]` and notes
        // nothing at all — only the routed branch adds a `noteChange(Maps)`.
        // So a listener is told "Position" while the positions it names are
        // still one CONS projection away from final.
        //
        // Harmless, for two independent reasons, and BOTH must survive any
        // later change: the class is already right (a second publish here
        // would carry the same word `applyFold` just delivered), and a
        // listener may not read the mesh at all — the contract is dirty-bit
        // only (§1.5), so nothing can have observed the intermediate
        // geometry. The routed `noteChange(Maps)` above rides the once-per-
        // frame drain, which stage 3 deletes; it is a no-op against the
        // `Maps` `applyFold` published on the same routed apply, which is why
        // that deletion does not turn this into a lost class either.
        return true;
    }

    // MS-4.3/4.4 — the DORMANT legacy per-pass T→R→S chain, reached only when
    // dragFalloff.compoundPasses != 1 (the pow-scale S pass has no matrix
    // form, F2; compoundPasses is published 1.0 everywhere in the current
    // tree). Cut VERBATIM from applyTRS's `else` branch (Phase B); the
    // ordinalSrc gather moved with it (that branch was its only consumer).
    // The parameter list is exactly the set of applyTRS locals the branch
    // read; all mutation still goes through member state (mesh / toProcess).
    void applyTRSLegacyPowPath(Vec3[] baseline, Vec3 pivot,
                               Vec3 bX, Vec3 bY, Vec3 bZ,
                               TransformTool.ClusterPivots cp,
                               TransformTool.ClusterAxes ap,
                               bool hasT, bool hasS,
                               Vec3 viewAxis, float viewAngleDeg) {
        import std.math : PI, fabs;
        // TASK 1073 (review SF3) — this arm is entirely UNROUTED. Every pass
        // below reads and writes `mesh.vertices` directly, so a routed
        // gesture arriving here would move the BASE while the user believes
        // it is authoring a morph map: silent corruption of the one surface
        // the whole seam exists to protect, with no visible symptom until the
        // map is cleared and the geometry does not come back.
        //
        // It cannot happen today — this branch is reached only when
        // `dragFalloff.compoundPasses != 1`, and nothing in the tree
        // publishes anything but 1.0 — which is exactly why it is worth an
        // assert rather than a route: routing a dormant path is untestable
        // work, while this costs one resolve and turns the failure from
        // silent into loud the moment the branch is woken up.
        //
        // `morphRoutingActive()` rather than `buildMorphRouteFor(baseline)`:
        // the latter CAPTURES the run baseline as a side effect, and a
        // side-effecting assert changes behaviour between `-release` (where
        // asserts are stripped entirely) and every other build. This form is
        // a pure read and is strictly stronger — it is true whenever a target
        // is bound, including the cases where the route would fail to build
        // and the fold would write the base anyway.
        assert(!morphRoutingActive(),
            "applyTRSLegacyPowPath is unrouted: a morph target is bound and "
          ~ "this arm would write the BASE. Route it (or refuse) before "
          ~ "waking compoundPasses != 1 -- see tools/transform/morph_route.d");
        // WORLD -> LAYER (task 0649), applied per pass at each kernel call
        // rather than once up front: the passes BUILD their matrices from the
        // world basis, so the conversion has to happen after each build. The
        // composition of conjugated maps is the conjugate of the composition,
        // so a chain of per-pass conversions is the same map as one conversion
        // of the whole chain — and each pass reads the previous pass's LAYER
        // output from `mesh.vertices`, which is what makes the chain close.
        const auto ims = applyItemSpace();
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
                                 ims.toLocalPoint(pivot), identityMatrix,
                                 Vec3(0, 0, 0),
                                 blendModeForMeasure(),
                                 noFo, dragAimSpace(),
                                 inItemFrame(ims, cp), ap,
                                 inItemFrame(ims, clusterM),
                                 dragSymmetry, toProcess);
            } else {
                // Global basis: delta = bX·TX + bY·TY + bZ·TZ; weight at the
                // LIVE position (source == weightVerts == current scratch),
                // matching applyTranslateIncremental.
                Vec3 delta = bX * run.t.x
                           + bY * run.t.y
                           + bZ * run.t.z;
                applyXformMatrix(mesh, vertexIndicesToProcess, ordinalSrc(),
                                 ims.toLocalPoint(pivot),
                                 ims.conjugate(translationMatrix(delta)),
                                 Vec3(0, 0, 0),
                                 blendModeForMeasure(),
                                 dragFalloff, dragAimSpace(),
                                 inItemFrame(ims, cp), ap, null,
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
                // THE ONE ARM WITH NO MATRIX FORM, and therefore the one
                // place the 0649 conversion is not exact. `pow(s, passes)`
                // has no matrix expression (F2), so this kernel takes a PIVOT
                // and a BASIS rather than a matrix, and the basis has to be
                // carried by `toLocalDir` instead of conjugated. That carry is
                // exact when the item's linear part is a similarity and a
                // declared approximation otherwise (the basis stops being
                // orthonormal under a non-uniform item scale, and this kernel
                // assumes it is). Reached only when `compoundPasses != 1`,
                // which is published 1.0 everywhere in the current tree — so
                // this arm is dormant, and it is converted at all so that the
                // path is not left reading world coordinates against layer
                // vertices, which is the half conversion the task refuses.
                Vec3 nz(Vec3 v) {
                    Vec3 d = ims.toLocalDir(v);
                    return d.length > 1e-12f ? normalize(d) : v;
                }
                applyScaleFromActivation(mesh, vertexIndicesToProcess,
                                         activation, ims.toLocalPoint(pivot),
                                         ims.isIdentity ? bX : nz(bX),
                                         ims.isIdentity ? bY : nz(bY),
                                         ims.isIdentity ? bZ : nz(bZ),
                                         run.s,
                                         dragFalloff, dragAimSpace(),
                                         inItemFrame(ims, cp), ap,
                                         dragSymmetry, toProcess,
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
                                 ims.toLocalPoint(pivot),
                                 ims.conjugate(
                                     pivotScaleMatrixBasis(Vec3(0, 0, 0),
                                         bX, bY, bZ,
                                         run.s.x, run.s.y,
                                         run.s.z)),
                                 Vec3(0, 0, 0),
                                 blendModeForMeasure(),
                                 dragFalloff, dragAimSpace(),
                                 inItemFrame(ims, cp), ap,
                                 inItemFrame(ims, clusterM),
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
        // bump (mid-drag stability). Mirror applyFold's publish so this path
        // publishes Position too — ONE publish for the whole T/R/S chain
        // (never per pass, never per vertex). compoundPasses is 1.0 everywhere
        // in the current tree, so this branch is dormant; the publish keeps it
        // correct if the pow path is ever re-enabled.
        //
        // Task 1906 stage 1 — `publishChange`, not `noteChange`: DELIVER the
        // Position class synchronously, still WITHOUT touching a version
        // counter. See applyFold's tail for the whole rationale.
        mesh.publishChange(MeshEditScope.Position);
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

        // WORLD -> LAYER (task 0649). Everything above composed in the space
        // the pipe publishes in; everything below writes `mesh.vertices`,
        // which are the layer's own coordinates.
        const auto ims  = applyItemSpace();
        lastFoldPivotWorld = pivot;      // published BEFORE the conversion
        M     = ims.conjugate(M);
        pivot = ims.toLocalPoint(pivot);
        cp    = inItemFrame(ims, cp);

        // MS-4.5 — publish the GLOBAL composed matrix + pivot for the GPU
        // fast-path to reuse (whole-mesh fast-path is never per-cluster).
        // Published AFTER the conversion, deliberately: the draw path folds
        // `matMul4(itemMatrix, tt.gpuMatrix)` (ui/panels.d), so `gpuMatrix`
        // has to be the LAYER-space matrix — the same one the CPU kernel
        // below applies. Publishing the world one here would apply the item
        // transform twice on the GPU preview and once on the CPU, and the
        // preview would disagree with the commit.
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
            // Composed from the WORLD per-cluster axes, then carried across
            // exactly like the global fold above.
            clusterM = inItemFrame(ims, clusterM);
        }

        // Task 1069 — the routing target for THIS apply, resolved once.
        // `MorphRoute.init` (no target bound) makes every use below inert and
        // the whole fold byte-identical to before this task.
        auto route = buildMorphRouteFor(baseline);
        const bool routed = route.covers(mesh.vertices.length);
        // The array the fold EVALUATES from. Unrouted that is `baseline` (the
        // true base); routed it is `route.runPos` (base + the map's value at
        // RUN START), which is what law L7 forces — gesture 2 must build on
        // gesture 1, not replace it. Both are mesh-length and vertex-id
        // indexed, which is what `weightVerts` needs.
        const(Vec3)[] evalFrom = routed ? route.runPos : cast(const(Vec3)[]) baseline;

        // Source = the eval array gathered ORDINAL-parallel to the moving set.
        // The two index spaces here are NOT the same and the mismatch is
        // silent: `src` is ordinal (parallel to `vertexIndicesToProcess`),
        // `weightVerts` is vertex-id indexed and mesh-length. The whole-mesh
        // case — our empty-selection convention — makes them coincide, so a
        // test written on a full selection cannot see a swap. Gather ONE
        // ordinal array here and pass the vid array through unchanged.
        // (task 0202) Reuse the tool-owned scratch buffer instead of allocating a
        // fresh Vec3[] every motion event — guarded resize is a no-op except on a
        // moving-set length change (grow/shrink only at a NEW drag's first frame);
        // contents are fully overwritten below, byte-identical to a fresh alloc.
        if (foldSrc_.length != vertexIndicesToProcess.length)
            foldSrc_.length = vertexIndicesToProcess.length;
        auto src = foldSrc_;
        foreach (k, vi; vertexIndicesToProcess)
            src[k] = (vi >= 0 && vi < cast(int)evalFrom.length)
                   ? evalFrom[vi] : Vec3(0, 0, 0);

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
        // Perf (doc/frame_probe_scenarios_plan.md, task 0195): FrameProbe's
        // `tool` phase — the ONE deliberate nest (toolNs ⊆ eventNs, since
        // this whole apply runs inside the events/replay-dispatch region of
        // the main loop). Same scope as `zKernel` above by design: this is
        // the single per-frame vertex-cloud apply for the live drag. No-op
        // in the default build.
        auto zFramesTool = g_frames.phase(Phase.tool);
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
        // `weightVerts` is the SAME array the fold evaluates from, built once
        // above — so the fold's evaluation space and its weighting space
        // cannot drift apart. Under routing that means the falloff weight is
        // sampled at the MORPHED position, which is a DIVERGENCE chosen for
        // coherence with the measured preview (the surface draws morphed and
        // the action centre is routed to the morphed centroid, so weighting
        // from the base would grade the falloff from a point the user is not
        // looking at). Unmeasured — registry row 46b.
        applyXformMatrix(mesh, vertexIndicesToProcess, src, pivot, M,
                         lastFoldAnchor,
                         foldMode, dragFalloff, dragAimSpace(), cp, ap,
                         clusterM, noSym, toProcess, /*weightVerts=*/ evalFrom,
                         /*route=*/ route);

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
            import tools.transform.morph_route :
                applySymmetryMirrorRouted, applySymmetryMirrorDeltaRouted;
            // `toProcess` is passed as both the selected mask AND the
            // also-touched out-mask, so mirror writes fold into the GPU upload /
            // undo touched set (replacing the deleted Pass B's outAlsoTouched
            // OR-in). On-plane drivers are projected back onto the plane inside
            // both paths, preserving the "center stays on the plane" contract.
            //
            // Task 1069 — the ROUTED overloads, and this is the ONLY call site
            // in the tree allowed to use them. They tail-call the unrouted
            // originals when `route` is inert, so the no-target case runs the
            // existing code path verbatim. The seam is HERE, on the caller,
            // and not inside `symmetry.d`: that function has seven production
            // callers and most of them do not route their own primary write,
            // so a route parameter down there would make one gesture write the
            // primary vertex to the base and its mirror partner to the map.
            if (dragSymmetry.topology)
                applySymmetryMirrorDeltaRouted(mesh, dragSymmetry, baseline,
                                               toProcess, toProcess, route);
            else
                applySymmetryMirrorRouted(mesh, dragSymmetry,
                                          toProcess, toProcess, route);
        }

        // Change-notification (doc/change_notification_bus_plan, Stage 1): the
        // drag apply moved positions in place WITHOUT bumping mutationVersion
        // (mid-drag version stability is intentional — symmetry/falloff/snap
        // caches keyed on mutationVersion must stay put). ONE publish per apply
        // (both the global fold and the per-cluster clusterM path run through
        // the single applyXformMatrix above) — never per vertex.
        // Task 1069: under routing NOTHING positional moved — the class is
        // Maps, not Position. Publishing Position there would tell every
        // position-keyed consumer that geometry changed when it did not.
        //
        // TASK 1906 STAGE 1 — `publishChange`, NOT `noteChange`, AND STILL NO
        // VERSION BUMP. The two halves are independent and both are load-
        // bearing:
        //
        //   * DELIVER. `noteChange` only ORs the class into the pending words
        //     and waits for the frame flush; every position-dependent listener
        //     therefore learned about the drag a frame late at best, and the
        //     version-polling consumers never learned at all (the counters do
        //     not move here). `publishChange` hands the class to the listeners
        //     at the edit boundary — that is the whole of the 0401 class, made
        //     unrepresentable rather than patched consumer by consumer.
        //   * STAY VERSION-SILENT. A `mutationVersion` bump here would move
        //     `XfrmTransformTool.lastAppliedGestureMutationVersion` away from
        //     its stamp and CANCEL the in-session falloff re-grade (§2.2/§2.3:
        //     version counters own STRUCTURE, the bus's Position class owns
        //     POSITION). `tests/test_refire_after_sync_publish.d` is that
        //     half's regression lock.
        //
        // Granularity: this site runs ONCE per gesture step (one applyFold per
        // apply), so a 12-step drag delivers 12 times — the claim
        // `tests/test_bus_delivery_granularity.d` measures.
        mesh.publishChange(routed ? MeshEditScope.Maps : MeshEditScope.Position);
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
        // WORLD -> LAYER, same conversion the live fold does (task 0649);
        // `axis`, `pivot` and `cp` arrive in the space the pipe publishes in.
        const auto ims = applyItemSpace();
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
                             ims.toLocalPoint(pivot),
                             ims.conjugate(
                                 pivotRotationMatrix(Vec3(0,0,0), axis, angleRad)),
                             Vec3(0, 0, 0),
                             blendModeForMeasure(),
                             dragFalloff, dragAimSpace(),
                             inItemFrame(ims, cp), ap,
                             inItemFrame(ims, clusterM),
                             dragSymmetry, toProcess);
        } else {
            // Global / view-ring: single origin-fixing rotation about `axis`.
            applyXformMatrix(mesh, vertexIndicesToProcess, srcGather(),
                             ims.toLocalPoint(pivot),
                             ims.conjugate(
                                 pivotRotationMatrix(Vec3(0,0,0), axis, angleRad)),
                             Vec3(0, 0, 0),
                             blendModeForMeasure(),
                             dragFalloff, dragAimSpace(),
                             inItemFrame(ims, cp), ap, null,
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
}
