module tools.transform.xfrm_apply;

/// Geometry-apply half of `XfrmTransformTool` — the single apply entry point
/// (`applyTRS`), the canonical-matrix fold it composes, its two per-pass
/// kernels. Split out of `xfrm_transform.d` by task 0719
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
/// `blendToIdentity` — is
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
    // `applyTRS` rebuilds `mesh.vertices` from it (R → S → T, using
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
    // the incremental kernels are `+=` and the symmetry
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
    //   S: the per-cluster scale matrix uses each cluster's own axes.

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

        // A mixed interactive run replays the pipe from its frozen source and
        // folds about the run centre. A one-shot numeric apply owns a fresh
        // baseline and deliberately samples the current pipe (task 6207).
        immutable bool compositeRun = flagT && (flagR || flagS)
            && runBaselineValid && !headlessApplyActive_;
        if (compositeRun) samplePipeFromBaseline = true;

        if (samplePipeFromBaseline) {
            restoreBaseline();
            buildLocalVts(subj, vts);
        } else {
            buildLocalVts(subj, vts);
        }

        // Value-edit reEvaluate semantics are revert-then-rerun: for those paths,
        // geometry-derived ACEN/AXIS state must be sampled from the baseline, not
        // from the previous preview result. Composite live drags use that same
        // frozen sample through `compositeRun`; pure-bank drags retain their
        // historical caller-selected sampling.
        Vec3 pivot = queryActionCenter(vts);
        auto cp    = queryClusterPivots(vts);
        auto ap    = queryClusterAxes(vts);

        // Task 0614 Phase 3 — item branch. Short-circuits BEFORE
        // buildVertexCacheIfNeeded() (Q2 hazard: mesh.selectedVertexIndices*
        // returns ALL vertices on an empty selection, so reaching the vertex
        // path in item mode would translate the whole layer's mesh). Reads
        // `subj.selType` FRESH from THIS call's own `buildLocalVts` above —
        // not the instance-cached `cachedSubjType_`; that field's declaration
        // owns its complete writer list, and no arbitrary `applyTRS` caller is
        // one of its live refresh points. Thus a headless/panel-replay call
        // with no preceding mouse event still resolves the LIVE subject
        // correctly.
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
        if (compositeRun && runFrameValid) pivot = runFrameOrigin;

        // MS-4.3/4.4 — canonical-matrix FOLD. The whole R->S->T map is composed
        // into ONE pivot-relative matrix (per cluster in the ACEN.Local case) and
        // applied through a SINGLE `applyXformMatrix` call, blended toward identity
        // per vertex by ONE falloff weight at the BASELINE position — see
        // `applyFold`. MS-4.1/4.2 proved this is what the reference does (one
        // composed matrix, one baseline weight; multi-axis rotate + combined
        // T+R+S + per-cluster translate-under-falloff all reproduce exactly), and
        // it is what fixes the per-cluster-translate-falloff divergence.
        //
        // The decomposed state fields (run.t / headlessRotate /
        // run.s) + the transient view-ring params (viewAxis / viewAngleDeg,
        // MS-3.4) remain the input attributes that BUILD the matrix.
        // `mesh.vertices` already holds the restored baseline.
        {
            bool hasT = flagT && (run.t.x != 0
                              || run.t.y != 0
                              || run.t.z != 0);
            bool hasS = flagS && (run.s.x != 1
                              || run.s.y != 1
                              || run.s.z != 1);
            applyFold(baseline, pivot, bX, bY, bZ, cp, ap,
                      hasT, hasS, viewAxis, viewAngleDeg);
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
        // background-mesh surface. Runs AFTER applyFold so
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
        // DOES NOT REDISCOVER IT. The pass above runs AFTER `applyFold` has
        // already published this apply's class, and on
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

    // MS-4.3/4.4 — canonical-matrix FOLD. Composes the whole R->S->T map into
    // ONE pivot-relative matrix per moving set and applies it through a SINGLE
    // `applyXformMatrix` call, blended toward identity per vertex by ONE falloff
    // weight evaluated at the BASELINE position. This is what MS-4.1/4.2 proved
    // the reference engine does (one composed matrix, one baseline weight):
    // `tests/test_fixture_falloff_multi.d` + `tests/fixtures/falloff_*_multi.json`
    // confirm it reproduces multi-axis rotation + combined T+R+S exactly, where
    // the prior per-pass sequential blend diverged 0.02-0.03.
    //
    // Order: with each linear factor origin-fixing and T the basis-space delta,
    //   M = T . S . (view . Rz . Ry . Rx),
    // and applyXformMatrix re-applies `pivot` as `pivot + blend(M)*(v - pivot)`.
    //
    // Per-cluster (ACEN.Local): each cluster composes the SAME chain in ITS OWN
    // frame (ap.right/up/fwd[cid]) about ITS OWN pivot (cp), blended by ONE
    // weight. Unlike the legacy per-cluster chain this WEIGHTS the translate too,
    // matching the reference (per-cluster translate is falloff-weighted there, not
    // exempt — the divergence this fold fixes). View-ring is global only.
    void applyFold(Vec3[] baseline, Vec3 pivot, Vec3 bX, Vec3 bY, Vec3 bZ,
                   TransformTool.ClusterPivots cp,
                   TransformTool.ClusterAxes ap,
                   bool hasT, bool hasS,
                   Vec3 viewAxis, float viewAngleDeg) {
        import std.math : PI;
        // Compose T·S·R. R/S use the rotate/scale frame (ax/ay/az); the TRANSLATE
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
            float[16] tr = identityMatrix;
            if (hasT)
                tr = translationMatrix(tx * run.t.x
                                     + ty * run.t.y
                                     + tz * run.t.z);
            float[16] rotLin = identityMatrix;
            if (flagR) {
                if (useRotM) {
                    rotLin = rotM;
                } else {
                    void rot(Vec3 axis, float deg) {
                        if (deg == 0) return;
                        rotLin = matMul4(
                            pivotRotationMatrix(Vec3(0, 0, 0), axis,
                                deg * cast(float)(PI / 180.0)), rotLin);
                    }
                    rot(rx, headlessRotate.x);
                    rot(ry, headlessRotate.y);
                    rot(rz, headlessRotate.z);
                }
            }
            float[16] scaleLin = identityMatrix;
            if (hasS)
                scaleLin = pivotScaleMatrixBasis(Vec3(0, 0, 0), ax, ay, az,
                                                  run.s.x, run.s.y, run.s.z);
            return composeRunMatrix(hasT, tr, flagR, rotLin, hasS, scaleLin);
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

        Vec3 sX, sY, sZ;
        runScaleAxes(frame.valid, frame.right, frame.up, frame.axis,
                     flagR, run.r, tX, tY, tZ, sX, sY, sZ);

        // MATRIX-AS-TRUTH — run.r is the origin-fixed world rotation. The
        // caller has already selected the run pivot, and the fold applies
        // T·S·R around that point; translation stays outside R and S.

        float[16] M = composeFor(/*useRotM=*/true, run.r,
                                 Vec3(0,0,0), Vec3(0,0,0), Vec3(0,0,0),
                                 sX, sY, sZ, tX, tY, tZ);

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
        // the display-authorized tool matrix into `itemMatrix`
        // (ui/viewport_render.d), so `gpuMatrix`
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
        const elementWeightKey = currentElementWeightCacheKey();
        const bool cachedElement = !routed
            && elementWeightCacheMatches(dragFalloff, elementWeightKey);
        const bool skipElementDriver = cachedElement
            && !elementWeightCache_.hasElement
            && elementWeightCache_.samplePos.length == mesh.vertices.length;
        const(Vec3)[] weightFrom = cachedElement
            && elementWeightCache_.hasElement
            && elementWeightCache_.samplePos.length == mesh.vertices.length
            ? cast(const(Vec3)[]) elementWeightCache_.samplePos : evalFrom;

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
        // DRIVER pass. Transforms exactly the operand with each vertex's own
        // falloff weight + matrix M. The packet is passed for the AUTHORING
        // FRAME only (task 7144: off the authoring side a vertex takes
        // M·K(M·p)); the kernel has no mirror tail — the pair mirror is the
        // single position-copy call below.
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
        if (!skipElementDriver)
            applyXformMatrix(mesh, vertexIndicesToProcess, src, pivot, M,
                             lastFoldAnchor,
                             foldMode, dragFalloff, dragAimSpace(), cp, ap,
                             clusterM, dragSymmetry, toProcess,
                             /*weightVerts=*/ weightFrom,
                             /*route=*/ route);

        // MIRROR pass — the pair write rule (`symmetry.mirrorStepFor`): a
        // pair in the operand is copied from its +X member's FINAL position
        // (its weight and result drive both halves — gap 73/318), every
        // vertex having been authored in A by the driver pass; a partner
        // outside the operand is never written (gap 316). Cluster-agnostic:
        // it copies the per-cluster (ACEN.Local) final positions too.
        if (!skipElementDriver && dragSymmetry.enabled
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
        //
        // Task 2000 — CONFINED, and this is the site the whole marker exists
        // for: it is the one a plain gizmo drag reaches on every step. The
        // vertices it moved are `vertexIndicesToProcess`, the same set the drag
        // hands `snapCursor` as `excludeVerts`. See
        // `Mesh.publishConfinedChange`.
        mesh.publishConfinedChange(routed ? MeshEditScope.Maps : MeshEditScope.Position);
    }
}
