module tools.transform.xfrm_item;

/// Item-mode half of `XfrmTransformTool` — the write target SET, its run
/// baseline, the world -> layer conversion, and the item-gesture undo session.
/// Split out of `xfrm_transform.d` by task 0719 (audit 4, finding T1).
///
/// WHY A `mixin template` AND NOT FREE FUNCTIONS. Everything here reads the
/// tool's `private` state (`run`, `frame`, `runFrame*`, `history`). Free
/// functions taking the tool would have forced ~20 members to `public`, and
/// the split is not allowed to buy itself with visibility. A template mixin
/// costs nothing: measured on dmd 2.111 before the split, a mixin body
/// instantiated inside a class in ANOTHER module reads that class's `private`
/// members and that module's module-`private` free functions and types
/// unchanged, because identifier lookup happens at the INSTANTIATION site.
///
/// The same measurement is why this module imports nothing. The moved bodies
/// resolve `Layer`, `ItemXform`, `Vec3`, `LayerXformEdit`, `applyGestureToItems`
/// and the rest through `xfrm_transform.d`'s own import list, exactly as they
/// did when the text lived there. Adding an import HERE would not help a
/// missing symbol — the lookup never consults this module's scope — so a
/// build error in this file is always fixed in the host's imports.
///
/// The corollary is the one hazard worth naming: a member declared directly in
/// the class SILENTLY wins over a member of the same name mixed in here. Never
/// leave a copy behind when moving something into this file.

mixin template XfrmItemImpl() {
    // Task 0614 — the item-mode write target SET. Mirrors the `primarySrc_`
    // pattern `ActionCenterStage`/`AxisStage` already use (`primarySrc_` in
    // stages/actcenter.d and stages/axis.d): a live delegate, never cached across calls, so a layer-select
    // mid-session is picked up on the next apply. Null in tests / call sites
    // that never engage item mode (edge_extend.d's embedded wrapper — its own
    // apply path never reaches `applyTRS` here, same reasoning as
    // `selTypeSrc_`'s doc comment on `TransformTool`).
    //
    // Phase 6 (law L2): this resolves the WHOLE SELECTED SET, not the
    // primary. Fill-a-buffer rather than return-an-array so the two
    // long-lived target lists below (`itemTargets`, `itemEditTargets_`) are
    // refreshed without an allocation per gesture, and so neither can alias
    // a buffer the other owns.
    //
    // NOTE the deliberate asymmetry with `ActionCenterStage`, which keeps its
    // own `primarySrc_`: the moving SET is the whole selection, but the
    // shared CENTRE follows the PRIMARY (L2, measured — not the set
    // midpoint), so ACEN needs exactly the single-primary source it already
    // has. Widening ACEN to the set would be a measured-behaviour change, not
    // a Phase 6 consistency fix.
    private void delegate(ref Layer[]) itemTargetsSrc_;

    // Resolve the moving set into `buf`. THE single funnel: all three target
    // lists (`beginRunGesture`'s run baseline, `restoreItemBaseline`'s
    // headless one-shot fallback, `beginEdit`'s undo session) go through
    // here, so a future change to what "the selected set" means cannot teach
    // one of them and miss the others — the Phase 4 lesson (three session
    // openers, only one taught) applied ahead of time rather than after.
    private void resolveItemTargets(ref Layer[] buf) {
        if (itemTargetsSrc_ is null) { buf.length = 0; return; }
        itemTargetsSrc_(buf);
    }

    // Cached subject type — refreshed once per input event in
    // `syncInputViewport` (the SAME point that caches `cachedVp`), from the
    // SAME `SubjectPacket` `selTypeSrc_` publishes into the toolpipe. A
    // per-field cache here is safe (unlike the process-wide-singleton hazard
    // Blocker 2 fixed on the pipe STAGES): this is a per-INSTANCE field on
    // the tool itself, refreshed at the top of every mouse handler this
    // instance receives, never read across a different tool's evaluate().
    private SelType cachedSubjType_ = SelType.Vertex;
    private bool itemSubjectActive() const { return cachedSubjType_ == SelType.Item; }

    // Task 0614 Phase 4 — the factory for the item-transform undo command,
    // mirroring `vertexEditFactory` (TransformTool). Injected by app.d
    // alongside `setUndoBindings`; null in tests that never engage item mode
    // (then the item commit branch skips recording, matching
    // `vertexEditFactory is null`'s existing "skip undo recording" contract).
    alias LayerXformEditFactory = LayerXformEdit delegate();
    private LayerXformEditFactory layerXformEditFactory_;
    public void setItemUndoFactory(LayerXformEditFactory factory) {
        layerXformEditFactory_ = factory;
    }

    // Item-mode gesture-undo snapshot — the analogue of TransformTool's
    // `editIdx`/`editBefore`/`editCapturing`, but keyed on `ItemXform`
    // instead of vertex positions. Deliberately SEPARATE fields (not a
    // reuse of the vertex ones): the item branch bypasses the
    // `vertexEditFactory` requirement entirely (transform.d's `beginEdit()`/
    // `commitEdit()` base bodies are never reached in item mode — see the
    // overrides below), so there is nothing to alias into.
    private ItemXform[] itemEditBefore_;
    private Layer[]     itemEditTargets_;
    private bool        itemEditCapturing_ = false;

    // Task 0614 Phase 4 — `editIsOpen()` (transform.d) reads only the base
    // class's vertex-only `editCapturing` flag, which the item branch never
    // sets (it bypasses `super.beginEdit()` entirely). Every chokepoint that
    // gates a commit on "is a session open" — `deactivate()`'s tool-drop
    // commit, `hasUncommittedEdit()`, `hasLiveEval()` — calls `editIsOpen()`
    // virtually, so overriding it here (rather than touching each call site)
    // makes an open ITEM session visible everywhere an open VERTEX session
    // already is. An open item session with no open vertex session (the
    // common single-bank-preset case) would otherwise be silently dropped at
    // tool-drop — never committed, never undoable.
    protected override bool editIsOpen() const {
        return itemEditCapturing_ || super.editIsOpen();
    }

    // Task 0614 Phase 3 — item-mode analogue of `restoreBaseline()` (the
    // closure inside `applyTRS`, `:3799-3801`). Restores every item target's
    // `ItemXform` from `itemDragBaseline` (the RUN-START snapshot) before
    // each apply, so `applyGestureToItems` always folds the run-absolute
    // gesture against the same baseline `restoreBaseline()` gives the vertex
    // path — required for the SAME reason: a live drag re-evaluates every
    // motion frame, and without restoring first each frame would compose on
    // top of the PREVIOUS frame's write instead of the run start.
    //
    // Headless fallback: `applyHeadless()` (`:4413-...`) never calls
    // `beginRunGesture` — it hands `applyTRS` a FRESH `mesh.vertices.dup`
    // baseline on every call instead of reusing a run-scoped one (there is
    // no gizmo mouse-down to open a run). The item path's baseline has no
    // equivalent "passed in fresh" seam (`applyGestureToItems` reads
    // `itemDragBaseline`, a FIELD, not a parameter), so when no drag session
    // is open (`itemBaselineValid` false) this captures a fresh one-shot
    // baseline from the LIVE moving set right here — mirroring
    // `mesh.vertices.dup`'s freshness for the vertex path. Without this a
    // bare `tool.attr <bank> ... ; tool.doApply` in item mode with no
    // preceding drag silently no-ops (itemTargets stays empty).
    private void restoreItemBaseline() {
        if (!itemBaselineValid) {
            // Re-resolved (not allocated fresh) into the existing buffer —
            // this runs once per RUN, not per frame, but the allocation is
            // free to avoid. Phase 6: the whole selected set (law L2).
            resolveItemTargets(itemTargets);
            itemDragBaseline.length = itemTargets.length;
            foreach (i, t; itemTargets) itemDragBaseline[i] = t.xform;
            itemBaselineValid = itemTargets.length > 0;
            return;   // freshly captured from the live state == already "restored"
        }
        if (itemTargets.length != itemDragBaseline.length) return;
        foreach (i, t; itemTargets) t.xform = itemDragBaseline[i];
    }

    // Task 0614 Phase 3 — the item-mode consumer of `item_xform_kernels`.
    // Called ONLY from `applyTRS`'s item branch, AFTER `restoreItemBaseline`
    // and `freezeRunFrameIfNeeded` have both already run this call — so the
    // frozen input frame (`frame`/`runFrame`) and the frozen centre
    // (`runFrameOrigin`, R15) are both valid by the time this reads them.
    //
    // Reads the SAME run-absolute TRS truth the vertex fold reads
    // (`run.t`/`run.r`/`run.s` — MATRIX-AS-TRUTH, `:391-392`) rather than a
    // parallel per-bank state, so an item drag and a vertex drag driven by
    // the identical gesture scalars land on the identical inputs (the basis
    // of `test_item_drag_law_parity.d`). `run.t` is already expressed LOCAL
    // to the frozen frame (the same value the Move drain accumulates,
    // `:2868`), matching the kernel's `tLocal` parameter directly — no
    // extra decomposition needed.
    private bool applyItemTRS() {
        if (itemTargets.length == 0) return false;
        if (itemTargets.length != itemDragBaseline.length) return false;

        // The FROZEN input frame — `frame.valid ? frame.{right,up,axis} :
        // runFrame{R,U,F}` — is the SAME expression `beginMoveDragSession`
        // pushes as the sub-tools' `inputBasis` (`:2661-2662`) and the SAME
        // one the vertex fold's translate term reads (`tX/tY/tZ`,
        // `:5232-5234`). NEVER `currentBasis` — REVIEW-1's whole point.
        Vec3 iX = frame.valid ? frame.right : runFrameR;
        Vec3 iY = frame.valid ? frame.up    : runFrameU;
        Vec3 iZ = frame.valid ? frame.axis  : runFrameF;

        return applyGestureToItems(itemTargets, itemDragBaseline, runFrameOrigin,
                                    iX, iY, iZ, run.t, run.r, run.s);
    }

    // ======================================================================
    // TASK 0649 — THE WORLD -> LAYER CONVERSION, AND WHY IT IS HERE
    //
    // The pipe publishes the action centre and the axis frame in WORLD space
    // (see `ActionCenterStage.itemSpace()`). Everything that AIMS reads them
    // there and is right to: the gizmo is drawn with the view/projection and
    // no model matrix, the drag planes are hit by world cursor rays, the
    // overlay and `/api/toolpipe` report world points. What is NOT in world
    // space is `mesh.vertices` — those are the edited layer's own
    // coordinates. So exactly one place has to convert, and this is it.
    //
    // THE CONVERSION IS NOT "MOVE THE PIVOT". A world map `W(x) = c + F(x-c)`
    // carried into the layer's coordinates is
    //     x |-> c' + (L^-1 F_lin L)(x - c') + L^-1 F_t,   c' = M^-1 c
    // — the PIVOT takes the full affine inverse and the MATRIX takes the
    // linear part on both sides (`ModelSpace.conjugate`, which carries its own
    // derivation and an anti-vacuity unittest). Converting the pivot alone
    // would be right only for a translate-only item transform; converting with
    // the full `m`/`mInv` would apply the item translation twice.
    //
    // WHY THE MATRIX AND NOT THE BASIS VECTORS. The obvious cheaper move is to
    // carry `bX/bY/bZ` through `toLocalDir` and leave the rest alone. That is
    // exact only when the item's linear part is a similarity (rotation x
    // uniform scale): `L^-1 B` is orthonormal only then, and the fold's scale
    // factor `B diag(s) B^T` needs an orthonormal `B` to mean what it says.
    // The 0648 stand carries the scale (2, 0.5, 3), so the cheaper move is
    // wrong on the very rig this was measured against.
    //
    // WHY BEFORE THE PER-VERTEX BLEND. `blendToIdentity` is a lerp toward the
    // identity, and conjugation commutes with it exactly (unittest in math.d),
    // so conjugating the composed matrix ONCE is equivalent to conjugating
    // every blended per-vertex result. `BlendMode.PolarQuat` (rotate-only soft
    // presets) is a slerp and does not commute under a non-similarity `L`;
    // there the conjugated form stays exact at w==0 and w==1 and is a declared
    // reading between them. Stated, not hidden.
    //
    // The identity fast path costs nothing: `ModelSpace.conjugate` returns its
    // argument untouched and `toLocalPoint` is `applyAffine(identity, p)`, so
    // every existing rig is byte-identical.
    // ======================================================================

    /// The space `mesh.vertices` lives in, relative to the world the pipe
    /// publishes in. Same source as the two stages use.
    ModelSpace applyItemSpace() {
        import document : primaryModelSpace;
        return primaryModelSpace();
    }

    /// Per-cluster pivots, world -> layer. Returns a COPY: `cp.centers`
    /// aliases the live `ActionCenterPacket`'s array, and writing through it
    /// would convert the published packet in place — the next reader (the
    /// gizmo, `/api/toolpipe`) would then see layer coordinates, and the one
    /// after that would convert them a second time.
    static TransformTool.ClusterPivots inItemFrame(
            ModelSpace ms, TransformTool.ClusterPivots cp) {
        if (ms.isIdentity || !ms.invertible || cp.centers.length == 0)
            return cp;
        TransformTool.ClusterPivots outCp;
        outCp.clusterOf = cp.clusterOf;
        outCp.centers   = cp.centers.dup;
        foreach (ref c; outCp.centers) c = ms.toLocalPoint(c);
        return outCp;
    }

    /// Per-cluster fold matrices, world -> layer. Also a copy, same reason.
    static float[16][] inItemFrame(ModelSpace ms, float[16][] cm) {
        if (ms.isIdentity || !ms.invertible || cm is null) return cm;
        auto outM = cm.dup;
        foreach (ref m; outM) m = ms.conjugate(m);
        return outM;
    }

    // Task 0614 Phase 4 — item-mode commit body, called from `commitEdit`'s
    // item branch (Move-bank gestures) AND from the Rotate/Scale gesture-end
    // sites (§Undo — every bank routes item recording through this ONE
    // wrapper method, since the wrapper is the only instance holding
    // `itemTargets`/the layer-xform undo factory). Builds ONE
    // `LayerXformEdit` covering every target, comparing the gesture-open
    // snapshot against the CURRENT xform; records nothing when nothing
    // changed (mirrors `buildEditCmd`'s no-op guard) or when undo plumbing
    // isn't wired (tests that never call `setItemUndoFactory`).
    private void commitItemEdit() {
        if (!itemEditCapturing_) return;
        scope(exit) {
            itemEditCapturing_      = false;
            itemEditTargets_.length = 0;
            itemEditBefore_.length  = 0;
        }
        if (history is null || layerXformEditFactory_ is null) return;
        if (itemEditTargets_.length == 0) return;
        if (itemEditTargets_.length != itemEditBefore_.length) return;

        LayerXformTarget[] payload;
        payload.reserve(itemEditTargets_.length);
        bool changed = false;
        foreach (i, t; itemEditTargets_) {
            ItemXform before = itemEditBefore_[i];
            ItemXform after  = t.xform;
            if (before != after) changed = true;
            payload ~= LayerXformTarget(t, before, after);
        }
        if (!changed) return;

        auto cmd = layerXformEditFactory_();
        cmd.setEdit(payload);
        recordCommit(cmd);
    }

    // Task 0614 Phase 3 — the item-mode analogue of `dragBaseline`/
    // `runBaselineValid`. `itemDragBaseline[i]` is `itemTargets[i]`'s
    // `ItemXform` at the START of the current geometry run; `applyTRS`'s item
    // branch restores from it before every apply (mirrors
    // `restoreBaseline()`), and `applyGestureToItems` folds the run-absolute
    // gesture against it (mirrors the "Evaluate-from-original" shape the
    // vertex fold uses). Captured inside `beginRunGesture`'s `if (rebake)`
    // block — the SAME predicate `dragBaseline` uses, so a same-bank repeat
    // holds the run baseline and a cross-axis rotate bakes the held rotation
    // in, exactly as the vertex path does. Cleared in `resetRun()` alongside
    // `runBaselineValid`/`runFrameValid` (R15 lifecycle parity).
    //
    // Phase 6: `itemTargets` is the WHOLE SELECTED SET (law L2), resolved
    // through `resolveItemTargets` — the primary is in it, but so is every
    // other selected item, INCLUDING kinds that can never be primary (an
    // `ItemKind.Empty` is transformable for the first time here). The
    // per-target index is shared with `itemDragBaseline`, so the two arrays
    // are always the same length or the fold declines.
    private Layer[]     itemTargets;
    private ItemXform[] itemDragBaseline;
    private bool        itemBaselineValid = false;
}
