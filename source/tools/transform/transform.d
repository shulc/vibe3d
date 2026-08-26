module tools.transform.transform;
import tool;
import operator : VectorStack;
import mesh;
import editmode;
import seltype : SelType;
import math : Vec3, Viewport, AimViewport, aimSpace;
import change_bus : MeshEditScope;
import command : Command;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.morph_edit  : MeshMorphEdit;
import snap : SnapResult;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket, SnapPacket, SubjectPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import pipe_gizmo_host : PipeGizmoHost;
// Task 0617 Stage 4: transform tools drag the active/primary mesh only, so
// its ModelSpace is the same resolver every other picking/snap call site
// uses.
import document : primaryModelSpace;

// Factory: builds a fresh MeshVertexEdit (the tools share a registry-driven
// constructor that wires gpu+caches; the tool just calls this delegate
// rather than knowing about ViewCache + GpuMesh + Mesh separately).
alias VertexEditFactory = MeshVertexEdit delegate();
/// Task 1069 — the ROUTED-gesture undo factory, `VertexEditFactory`'s twin.
/// Nullable: a tool with no morph factory simply records nothing for a
/// routed drag, the same way a null `vertexEditFactory` skips undo today.
alias MorphEditFactory = MeshMorphEdit delegate();

// ---------------------------------------------------------------------------
// Every vertex index a drag MOVES — which is exactly the set snapping must
// refuse to offer that drag as a candidate (`snap.d`'s `kindExcluded`, and the
// exclusion `move.d:applySnapToDelta` builds from it).
//
// It is NOT `vertexIndicesToProcess`. With a SYMM stage live, the apply's
// mirror pass writes the `pairOf` PARTNER of every processed vert, and those
// indices lie OUTSIDE the processed list by construction — `applyTRS`'s own
// prologue says so in as many words, which is why it restores the whole
// baseline instead of just the processed slice.
//
// Two things follow from a partner left out of the exclusion, and they are the
// same two the exclusion exists to prevent:
//
//   1. SELF-REFERENCE. The partner moves with the gesture, so it — and every
//      edge / face centre it drags along — chases the cursor at the mirrored
//      rate. On a symmetric mesh the partner is often the nearest candidate
//      there is.
//   2. A STALE GRID. `snap.d`'s candidate grid is keyed on
//      `mesh.mutationVersion`, which an interactive drag deliberately does not
//      bump, so it is built once at drag start and reused for the whole
//      gesture. That is sound for one reason only: every vertex whose cached
//      projection goes stale is one the query drops before the caller sees it.
//      A moving vertex that is not excluded is stale AND returned — the query
//      answers with where the partner WAS at drag start.
//
// UNION, not the mirror pass's driver rule. The pass skips writing a partner
// that is itself processed (each side then drives from its own base-side
// vertex), so taking the union of processed ∪ partners costs nothing in
// accuracy: a skipped partner was already in the list. Duplicates are left in
// rather than filtered — `snap.d`'s `excludeMembership` sets and clears bits
// idempotently, and de-duplicating would cost a vertex-count-sized mask on
// every motion event to buy nothing.
//
// `pairOf[i] == -1` means "no mirror" and is dropped; `pairOf[i] == i` is an
// on-plane vertex, which the pass projects in place and which is already in
// the list.
uint[] movingVertexIndices(const(int)[] processed, const ref SymmetryPacket sp,
                           size_t vertCount)
{
    uint[] moving;
    immutable bool mirrors = sp.enabled && sp.pairOf.length == vertCount;
    moving.reserve(mirrors ? processed.length * 2 : processed.length);
    foreach (vi; processed)
        if (vi >= 0) moving ~= cast(uint)vi;
    if (!mirrors) return moving;
    foreach (vi; processed) {
        if (vi < 0 || vi >= cast(int)sp.pairOf.length) continue;
        immutable int mi = sp.pairOf[vi];
        if (mi < 0 || mi == vi) continue;
        moving ~= cast(uint)mi;
    }
    return moving;
}

class TransformTool : Tool {
public:
    // app.d reads this every frame and sets u_model accordingly.
    // Reset to identity when not in a whole-mesh drag.
    float[16] gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

    // Public read of the protected `dragAxis` (0/1/2/… = a grabbed gizmo handle,
    // -1 = none/relocate). A host tool that EMBEDS the gizmo banks (EdgeExtendTool,
    // doc/edge_extend_plan.md §4) but does NOT derive from TransformTool needs to
    // know whether a forwarded onMouseButtonDown landed on a REAL handle (so it can
    // mirror the wrapper's try-Move-then-Rotate-then-Scale bank dispatch). The
    // value is the bank's own drag-axis convention (varies per tool); the host only
    // checks >= 0 (and the principal-ring 0..2 range for Rotate).
    final int dragAxisPublic() const { return dragAxis; }

protected:
    bool          active;

    // Seam 3: the mesh is resolved through a delegate so the same long-lived
    // tool instance can be retargeted (Stage 0b) without re-touching any body.
    // Stage 0a: app.d passes `() => &mesh` against the still-global mesh, so
    // `mesh` resolves identically to the old raw field — provably neutral.
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*  gpu;
    EditMode* editMode;

    // Blocker 1 (0614 review): the LIVE external source for "what SelType is
    // the CURRENT subject" — the SAME authority app.d's buildToolVts uses
    // (`currentSelType(selTypeOrder)`, app.d's `buildToolVts`). Wired at
    // construction (registration.d); null in tests / geometry-only tools
    // (e.g. EdgeExtendTool's embedded `xfrm` — its ctor in
    // tools/edit/edge_extend.d constructs it with no selTypeSrc). NIT (0614 review, 3rd instance of this class
    // of over-claim in this task): the omission there is harmless, but NOT
    // because "there is no item subject to misreport" — item-select does
    // NOT drop an armed tool (see below), so an item subject can very much
    // be live while EdgeExtendTool is armed. It is harmless because that
    // embedded `xfrm` never routes through THIS builder at all: EdgeExtendTool
    // drives its gizmo banks (`moveBank()`/`rotateBank()`/`scaleBank()`,
    // `onMouseButtonDown`/`draw`/`update`) with a `vts` handed in from
    // app.d's `buildToolVts` — which DOES read the live subject — and its
    // own apply path never calls `xfrm.doApply()`/`xfrm`'s `buildLocalVts()`,
    // only EdgeExtendTool's own `applyHeadless()`. If a future change ever
    // makes the embedded `xfrm` call ITS `buildLocalVts()` (e.g. a headless
    // apply routed through it directly), this null wiring reintroduces the
    // exact split Blocker 1 fixed, silently.
    //
    // Before this field existed, buildLocalVts (below) left
    // SubjectPacket.selType at its Vertex default unconditionally, while
    // app.d's buildToolVts (the RENDER path — the gizmo you see) correctly
    // read the live app state. Item-select does not drop the active tool
    // (app.d's promoteItemType), so the two paths could — and did —
    // disagree on the subject for the SAME gesture: the gizmo drawn at the
    // item's world pivot, the drag applied about the geometry centroid.
    SelType delegate() selTypeSrc_;

    // Phase C.2: undo support. history is the global stack; vertexEditFactory
    // builds a MeshVertexEdit pre-wired to the same gpu/caches the tool
    // mutates. Both are nullable for tests / older callers; tools must
    // handle the null case as "skip undo recording".
    CommandHistory     history;
    VertexEditFactory  vertexEditFactory;
    MorphEditFactory   morphEditFactory;

    // Drag snapshot — captured by beginEdit() at drag/slider start, used by
    // commitEdit() at drag/slider end to build the MeshVertexEdit. Reset to
    // empty between sessions; isCapturing() reports whether a drag is open.
    private uint[] editIdx;
    private Vec3[] editBefore;

    // ── Task 1069: the ROUTED session's own baseline ───────────────────────
    //
    // `editBefore` above stays POSITIONS, deliberately and non-negotiably.
    // BOTH cancel paths (`cancelOpenSessionGeometry` here and the wrapper's
    // `cancelUncommittedEdit`) replay that array straight back into
    // `mesh.vertices`; putting map DELTAS in it would teleport every moving
    // vertex to near the origin on a cancel and then publish the result. That
    // is a data-destroying bug, not a cosmetic one.
    //
    // The map's pre-gesture state therefore lives in its OWN parallel arrays,
    // and the two cancel sites restore BOTH. Whole-mesh rather than
    // moving-set-sized because a routed gesture can write entries outside the
    // moving set: the symmetry mirror writes partners (`pairOf`, derived from
    // positions, never from a mask) and the CONS post-pass re-projects. A
    // moving-set capture would leave those unrestorable.
    private string morphEditMap_;
    private Vec3[] morphEditBefore_;      // mesh-length stored values
    private bool[] morphEditBeforeHas_;   // mesh-length presence
    private bool   morphEditOpen_;
    private bool   editCapturing;

    int      dragAxis = -1;      // 0/1/2=X/Y/Z axis, -1=none (exact meaning varies per tool)
    int      lastMX, lastMY;     // mouse position at last motion event
    Viewport cachedVp;           // viewport captured in draw(), reused in event handlers
    bool     centerManual;       // true = update() must not recompute handler center
    Vec3     cachedCenter;       // gizmo center, recomputed when selection hash changes
    bool     needsGpuUpdate;     // deferred GPU upload flag, flushed in draw()
    SnapResult lastSnap;         // last snap query — drives the cyan/yellow overlay
                                 // in draw(). Populated by drag-snap (MoveTool's
                                 // applySnapToDelta) AND by updateLiveSnapPreview()
                                 // — gives the user a "if you click here, gizmo
                                 // lands HERE" hint before any drag.
    // Phase 7.5: falloff packet snapshot, captured at drag start so
    // per-vertex weight evaluation doesn't re-walk the toolpipe on
    // every motion event. Refreshed by captureFalloffForDrag(); the
    // packet's `enabled` flag stays false (default-init) until that
    // gets called, so any tool that hasn't opted in sees weight=1.0.
    FalloffPacket dragFalloff;

    // Phase 7.6b: symmetry packet snapshot. Same pattern as dragFalloff
    // — captured at drag start so the per-vertex mirror lookup is
    // stable through the drag (mesh.mutationVersion only bumps at
    // beginEdit baseline write; we don't want pairOf reshuffling
    // mid-drag). Refreshed by captureSymmetryForDrag(); default-init
    // (`enabled = false`) until that gets called.
    SymmetryPacket dragSymmetry;

    // P-C: snap packet snapshot. Same pattern as dragFalloff / dragSymmetry —
    // captured at drag start (captureSnapForDrag) so the transform-session
    // refire trigger can compare the LIVE snap config against the run-start
    // snapshot at idle (a mid-run snap toggle re-grades / restores config like a
    // falloff or symmetry change). default-init (`enabled = false`) until
    // captured. NB: snap is a CURSOR-time op (snapCursor during the live drag),
    // NOT part of the composed absolute fold (applyTRS/applyFold), so a
    // snap-ONLY change at idle re-grades to byte-identical geometry — its role
    // in P-C is the refire trigger + the uniform config-restore hook family, so
    // an in-session / post-drop undo restores the snap config with the geometry.
    SnapPacket dragSnap;

    // Falloff stage-gizmo refactor (step 4): the interactive falloff
    // endpoint gizmo is no longer owned per-tool. The single persistent
    // app-level PipeGizmoHost owns the one emitter; the tool registers it
    // INTO its own shared `toolHandles` arbiter cycle and routes events
    // through the host so a no-tool→tool transition continues one drag.
    // Injected by app.d at each XfrmTransformTool construction site via
    // setPipeGizmoHost(); nullable for tests / older callers.
    PipeGizmoHost pipeGizmoHost;

    // Whole-mesh GPU bypass (Rotate + Scale use these; Move uses gpuOffset instead)
    bool   wholeMeshDrag;
    bool   propsDragging;
    Vec3[] dragStartVertices;

    // Vertex index cache — rebuilt once per selection change, reused every event.
    int[]  vertexIndicesToProcess;
    bool[] toProcess;
    int    vertexProcessCount;
    bool   vertexCacheDirty = true;
    ulong  lastSelectionHash;

    // Phase C: track the mesh's mutationVersion so update() can refresh the
    // gizmo when geometry changes without selection — e.g. after Ctrl+Z
    // reverts a transform, the selection is identical but the verts moved,
    // so the gizmo (= selection centroid) must be recomputed.
    ulong  lastMutationVersion;

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         SelType delegate() selTypeSrc = null) {
        this.meshSrc_    = meshSrc;
        this.gpu         = gpu;
        this.editMode    = editMode;
        this.selTypeSrc_ = selTypeSrc;
    }

    // Inject undo plumbing — called by app.d after construction. Tools
    // built by tests or older paths can skip this; in that case
    // commitEdit() is a no-op.
    public void setUndoBindings(CommandHistory h, VertexEditFactory factory,
                                MorphEditFactory morphFactory = null) {
        this.morphEditFactory = morphFactory;
        this.history           = h;
        this.vertexEditFactory = factory;
    }

    // True iff a beginEdit() / commitEdit() pair is currently open.
    // Used by subclasses (RotateTool, ScaleTool) to decide whether to
    // snapshot tool-specific Tool-Properties state — only on the FIRST
    // active frame of a slider drag, not on subsequent frames.
    protected bool editIsOpen() const { return editCapturing; }

    // Public read-only mirror of editIsOpen(), so the composing wrapper
    // (XfrmTransformTool) can ask a sub-tool whether ITS edit session is open
    // (rotate/scale own their own sessions — MS-5). Forms Phase 5b reads this to
    // fold the sub-tool sessions into the wrapper's hasLiveEval()/commit gates.
    public bool publicEditIsOpen() const { return editCapturing; }

    // Phase 7.5h: read-only accessors for the in-flight edit snapshot.
    // MoveTool's "absolute-from-baseline" path rebuilds mesh.vertices
    // each motion event from these arrays + the running dragDelta, so
    // a mid-tool falloff change can re-apply with new weights instead
    // of being baked into the previous incremental mutation.
    protected uint[] editIndices() { return editIdx; }
    protected Vec3[] editBaseline() { return editBefore; }

    // (The former NeedsFalloff flags() override retired with the dead
    // consumesFalloff chain, task 0428 — falloff weighting reaches the
    // transform kernels through the WGHT packet, not a Tool capability bit.)

    // Begin recording an edit session. Captures the current positions of
    // the verts in vertexIndicesToProcess (must be filled by the caller —
    // typically via buildVertexCacheIfNeeded() right before this call).
    // Idempotent: a repeat call before commitEdit() is a no-op.
    protected void beginEdit() {
        if (history is null || vertexEditFactory is null) return;
        if (editCapturing) return;
        editIdx.length    = 0;
        editBefore.length = 0;
        foreach (vi; vertexIndicesToProcess) {
            editIdx    ~= cast(uint)vi;
            editBefore ~= mesh.vertices[vi];
        }
        captureMorphEditBaseline();   // task 1069 — a SEPARATE array, see above
        editCapturing = true;
    }

    // Snapshot the bound morph map's whole state at session open. No-op (and
    // leaves `morphEditOpen_` false) when no target is bound, which is what
    // keeps every non-routed gesture byte-identical to before this task.
    private void captureMorphEditBaseline() {
        import morph_target : resolveMorphTarget;
        import tools.transform.morph_route : defaultStored;
        import mesh : MapKind;
        morphEditOpen_ = false;
        morphEditMap_  = null;
        morphEditBefore_.length    = 0;
        morphEditBeforeHas_.length = 0;
        string nm; MapKind kind;
        if (!resolveMorphTarget(mesh, nm, kind)) return;
        auto map = mesh.morphMapForWrite(nm);
        if (map is null) return;
        const size_t n = mesh.vertices.length;
        morphEditMap_ = nm;
        morphEditBefore_.length    = n;
        morphEditBeforeHas_.length = n;
        foreach (i; 0 .. n) {
            morphEditBeforeHas_[i] = map.isPresent(i);
            morphEditBefore_[i]    = map.entryOr(i, defaultStored(mesh.vertices[i], kind));
        }
        morphEditOpen_ = true;
    }

    /// Restore the bound map to its session-open state. Called by BOTH cancel
    /// paths — a cancelled routed drag must leave the map exactly as it was,
    /// and restoring `mesh.vertices` alone would leave the edit in place while
    /// looking correct to any assertion that only reads geometry.
    protected void restoreMorphEditBaseline() {
        if (!morphEditOpen_) return;
        auto map = mesh.morphMapForWrite(morphEditMap_);
        if (map is null) return;
        const size_t n = morphEditBefore_.length;
        foreach (i; 0 .. n) {
            if (i >= mesh.vertices.length) break;
            if (morphEditBeforeHas_[i]) map.setEntry(i, morphEditBefore_[i]);
            else                        mesh.clearMorphValue(morphEditMap_, i);
        }
        import mesh_edit_delta : MeshEditScope;
        mesh.commitChange(MeshEditScope.Maps);
    }

    /// True when the open edit session is ROUTED — the commit sites branch on
    /// this to build the morph command instead of the vertex one.
    protected bool morphEditIsOpen() const { return morphEditOpen_; }

    /// Build the routed-gesture undo record, or null when the session was not
    /// routed / nothing changed. Closes the capture session, exactly like
    /// `buildEditCmd`.
    protected Command buildMorphEditCmd(string label) {
        import commands.mesh.morph_edit : MeshMorphEdit, MorphEntryEdit;
        import tools.transform.morph_route : defaultStored;
        import morph_target : resolveMorphTarget;
        import mesh : MapKind;
        if (!editCapturing || !morphEditOpen_) return null;
        scope(exit) cancelEdit();
        if (history is null) return null;
        auto map = mesh.morphMapForWrite(morphEditMap_);
        if (map is null) return null;
        string nm; MapKind kind;
        if (!resolveMorphTarget(mesh, nm, kind)) return null;

        MorphEntryEdit[] entries;
        const size_t n = morphEditBefore_.length;
        foreach (i; 0 .. n) {
            if (i >= mesh.vertices.length) break;
            const bool hasNow = map.isPresent(i);
            const Vec3 valNow = map.entryOr(i, defaultStored(mesh.vertices[i], kind));
            // PRESENCE alone is a real change: a zero-magnitude move still
            // creates an entry (`zero_move_creates_entries`), and an undo has
            // to be able to take it back out.
            if (hasNow == morphEditBeforeHas_[i]
             && valNow.x == morphEditBefore_[i].x
             && valNow.y == morphEditBefore_[i].y
             && valNow.z == morphEditBefore_[i].z)
                continue;
            entries ~= MorphEntryEdit(cast(uint) i,
                                      morphEditBefore_[i], morphEditBeforeHas_[i],
                                      valNow, hasNow);
        }
        if (entries.length == 0) return null;
        if (morphEditFactory is null) return null;
        auto cmd = morphEditFactory();
        cmd.setEdit(morphEditMap_, entries, label);
        return cmd;
    }

    // Cancel a captured edit without recording — used when the drag is
    // aborted (no movement happened, modifier-key escape, etc.).
    protected void cancelEdit() {
        editIdx.length    = 0;
        editBefore.length = 0;
        // Task 1069: the routed session's baseline is dropped with the
        // positional one. NOTE this only DISCARDS the capture — restoring the
        // map is `restoreMorphEditBaseline()`, which the two cancel sites call
        // BEFORE they reach here.
        morphEditOpen_ = false;
        morphEditMap_  = null;
        morphEditBefore_.length    = 0;
        morphEditBeforeHas_.length = 0;
        editCapturing     = false;
    }

    // Build a MeshVertexEdit from the captured snapshot + current state.
    // Returns null when no positions actually changed (no-op drag) or when
    // no edit session is open / undo plumbing is missing. Always closes the
    // capture session via cancelEdit() before returning. Subclasses can
    // call this from their own commitEdit override to attach tool-specific
    // state hooks before recording on history.
    protected MeshVertexEdit buildEditCmd(string label) {
        if (!editCapturing) return null;
        scope(exit) cancelEdit();
        if (history is null || vertexEditFactory is null) return null;

        // mesh.vertices.length can shrink between the open edit and
        // commit (e.g. SceneReset replacing a subdivided mesh with a
        // fresh cube while a tool drag is still open) — that flow
        // deactivates the active tool while disposing the mesh, which
        // triggers this very commit. Drop any stale indices that no
        // longer reference a live vert; the edit either records the
        // surviving subset or returns null when nothing's left.
        Vec3[] after_;
        after_.length = editIdx.length;
        bool changed = false;
        size_t valid = 0;
        foreach (i, vid; editIdx) {
            if (vid >= mesh.vertices.length) continue;
            editIdx[valid]    = vid;
            editBefore[valid] = editBefore[i];
            after_[valid]     = mesh.vertices[vid];
            if (after_[valid].x != editBefore[valid].x
             || after_[valid].y != editBefore[valid].y
             || after_[valid].z != editBefore[valid].z)
                changed = true;
            ++valid;
        }
        editIdx.length    = valid;
        editBefore.length = valid;
        after_.length     = valid;
        if (!changed) return null;

        auto cmd = vertexEditFactory();
        cmd.setEdit(editIdx.dup, editBefore.dup, after_, label);
        return cmd;
    }

    // Undo/redo migration P0 — single-chokepoint commit latch. The wrapper
    // (XfrmTransformTool) commits from THREE sites (deactivate :225,
    // update :254 on selection/mutation change, and BrushReset :887), all
    // resolving to THIS method. cancelUncommittedEdit() restores the open
    // session's baseline by hand and must guarantee none of those three sites
    // re-records a commit while it does so. Rather than guard each caller, the
    // suppression gates here: cancelUncommittedEdit() sets the latch around its
    // teardown, and commitEdit() honours it by closing the capture WITHOUT
    // recording. (cancelEdit() already discards the open snapshot, so once the
    // latch is set there is also nothing left to record.)
    protected bool suppressCommit = false;

    // In-session routing flag (record+consolidate). When the composing wrapper
    // has a live gizmo run open it sets this true, so a per-gesture commitEdit
    // lands as a TAGGED in-session entry (one step of the run) via
    // recordInSession; consolidate() collapses the run into one surviving entry
    // at the boundary / tool drop. Plain (false) routing is the ordinary
    // record() append — used for panel/forms commits and any path with no open
    // run. The base + R/S sub-tools all inherit this; the wrapper drives it —
    // it sets its OWN flag (Move commits) AND, via setRecordViaInSession() below,
    // the R/S sub-tools' flags, so an R/S per-gesture commit also lands in-session
    // and consolidate() collapses the R/S run at the boundary / drop.
    protected bool recordViaInSession = false;

    // PUBLIC mirror so the composing wrapper can route a SUB-TOOL's commits
    // in-session too. `recordViaInSession` is protected, and D `protected` does
    // not grant sibling (wrapper→sub-tool) cross-instance access, so the wrapper
    // cannot write `rotateSub.recordViaInSession` directly. This setter (calling
    // its OWN protected field — legal) lets the wrapper flip the R/S sub-tools'
    // routing at activate/deactivate, mirroring the public commitSessionIfOpen
    // pattern. Same shape as the wrapper setting its own flag in activate().
    public void setRecordViaInSession(bool on) { recordViaInSession = on; }

    // Single routing chokepoint for every commitEdit override. All three
    // commitEdit bodies (base + RotateTool + ScaleTool) funnel their terminal
    // record through here so ONE flag (recordViaInSession) routes all three.
    // In-session: stamp the entry with the history's current run id; plain:
    // ordinary append. Keeps the rotate/scale per-gesture accumulator hooks
    // (set on `cmd` before this call) intact — only the terminal record changes.
    //
    // Widened from `MeshVertexEdit` to the base `Command` (task 0614 Phase 4)
    // so the item-mode commit branch (XfrmTransformTool's commitEdit override)
    // can route a `LayerXformEdit` through this SAME chokepoint instead of a
    // parallel copy — purely a signature widening, every existing
    // `MeshVertexEdit`-typed call site upcasts implicitly, byte-identical
    // behaviour for the vertex path.
    protected void recordCommit(Command cmd) {
        if (recordViaInSession)
            history.recordInSession(cmd, history.currentRunId);
        else
            history.record(cmd);
        // TASK 2000 — THE GESTURE IS OVER: RE-ARM THE SETTLED-GEOMETRY
        // WATCHER.
        //
        // Every drag step published its `Position` as CONFINED
        // (`Mesh.publishConfinedChange`), so `mesh_dirty.g_settledGeomEpochs`
        // deliberately did not move and the two caches keyed on it — the snap
        // candidate grid and the symmetry pair table — held one build for the
        // whole gesture. That is sound only WHILE the gesture is live and its
        // moving set is still being excluded. Once the edit is recorded there
        // is no gesture and no exclusion, so the displacement has to become
        // visible to those caches: one UNCONFINED publish, here.
        //
        // WHY HERE. This is the single chokepoint every transform
        // `commitEdit` override routes through (base, Rotate, Scale and the
        // wrapper's item branch all end in `recordCommit`), and it is reached
        // only when a real edit was built — a no-op gesture returns before it,
        // which is right: nothing moved, nothing to settle. The cancel path
        // never comes here and does not need to; it ends in
        // `commitChange(Position)`, which is unconfined already.
        //
        // WHY `publishChange` AND NOT `commitChange`. A version bump here
        // would move `XfrmTransformTool.lastAppliedGestureMutationVersion`
        // away from its stamp and cancel the in-session falloff re-grade —
        // the interactive transform is version-silent at the commit too, and
        // that is a measured law (CLAUDE.md, "the two domains"). This adds a
        // DELIVERY, not a version.
        //
        // COST: one extra delivery per committed gesture. A 12-step drag
        // therefore delivers 13, which `tests/test_bus_delivery_granularity.d`
        // bounds at `>= steps && <= 2 * steps`. Measured on a 20-step drag:
        // 21 `Position` deliveries (round-1 review fold).
        //
        // IT FIRES FOR GESTURES THAT MOVED NO VERTEX, AND THAT IS THE NAMED
        // EXCEPTION TO THE RULE AT `xfrm_apply.d`'s applyFold tail. That rule
        // — "publishing Position under routing would tell every position-keyed
        // consumer that geometry changed when it did not" — governs a PER-STEP
        // site whose class is decided per apply, where a wrong word is repeated
        // on every step of every routed drag. This site is per committed
        // GESTURE and it is deliberately coarse: it publishes `Position`
        // whether the gesture was a component drag, an ITEM drag (which moves
        // the layer transform and never touches `mesh.vertices`), or a
        // `LinearAlignTool` / `RadialAlignTool` re-fire that already committed
        // its own change. Three reasons that is the right trade here and not a
        // slip:
        //
        //   * WHAT IT MUST NOT DO is under-invalidate. The whole gesture ran
        //     confined; if this publish is skipped for a gesture that DID move
        //     vertices, the two caches keyed on `g_settledGeomEpochs` keep a
        //     pre-gesture table and answer with where a vertex used to be.
        //     Deciding "did this gesture move a vertex" from the recorded
        //     command means a snapshot compare at every commit — a real cost,
        //     paid to avoid one delivery.
        //   * AN ITEM GESTURE IS NOT A LIE. The primary's vertices did move in
        //     WORLD space; only `mesh.vertices` stayed put. A position-keyed
        //     consumer that works in world space is right to hear about it —
        //     the snap grid already rebuilds through its viewport term on such
        //     a drag (round-1 review, MINOR-5).
        //   * THE RATE IS ONE PER GESTURE. Over-invalidation costs one grid
        //     build here, not one per step, and it happens on an edit boundary
        //     the user has already stopped moving the mouse for.
        if (mesh !is null)
            mesh.publishChange(MeshEditScope.Position);
    }

    // Default commit: build cmd, record on history. Subclasses override to
    // attach hooks before recording (RotateTool, ScaleTool, MoveTool).
    protected void commitEdit(string label) {
        if (suppressCommit) { cancelEdit(); return; }
        // A genuine commit (tool-drop / selection-change / per-gesture mouse-up)
        // makes any click-away relocate that happened during this session
        // PERMANENT, so drop the in-session-cancel pin snapshot WITHOUT restoring
        // it. The cancel path never reaches here (it sets suppressCommit and
        // restores the pin itself); leaving a stale frozen snapshot behind would
        // let a LATER cancel revert a relocate that was already committed.
        discardAcenUserPlacedSnapshot();
        // Task 1069 — a ROUTED gesture changed the map, not `mesh.vertices`,
        // so `buildEditCmd` would diff two identical position arrays and
        // return null: the drag would reach the undo stack not at all.
        if (auto mcmd = buildMorphEditCmd(label)) { recordCommit(mcmd); return; }
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;
        recordCommit(cmd);
    }

    // Drop the action-center stage's frozen in-session-cancel pin snapshot
    // (commit path — committed relocates persist). Counterpart of the freeze /
    // restore the transform wrapper drives across an edit session. No-op when
    // no ACEN stage is registered or no snapshot is frozen.
    protected void discardAcenUserPlacedSnapshot() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.discardUserPlacedSnapshot();
    }

    // In-session-cancel geometry/GPU teardown, shared by RotateTool /
    // ScaleTool's `cancelSessionIfOpen()`. Restores the moving set to the
    // per-vertex snapshot beginEdit() captured (editBaseline()), re-uploads it
    // to the GPU and clears the whole-mesh-bypass matrix state, then closes the
    // capture WITHOUT recording (suppressCommit gates the single commitEdit()
    // chokepoint so deactivate()/update() can't re-fire a commit during the
    // teardown). This is exactly the geometry half of the wrapper's
    // cancelUncommittedEdit() — factored here because rotate + scale do it
    // identically; the only per-subclass part stays in each sub-tool's
    // cancelSessionIfOpen() before it calls this. That per-subclass part is
    // ROLE-SPLIT: STANDALONE (`wrapperRef is null`) restores the sub-tool's own
    // angleAccum/propDeg vs scaleAccum/propScale to their session-start values;
    // WRAPPED returns the wrapper's own session-start truth instead
    // (`gestureStartRotateEuler()` / `gestureStartScaleFactor()`, i.e.
    // `gestureStart.r` / `gestureStart.s`) and leaves the accumulators alone.
    // Caller must have verified editIsOpen() == true.
    protected void cancelOpenSessionGeometry() {
        suppressCommit = true;
        scope(exit) suppressCommit = false;

        uint[] idx  = editIndices();
        Vec3[] base = editBaseline();
        foreach (i, vid; idx) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = base[i];
        }
        // Task 1069: a routed session moved the MAP, not the positions, so the
        // loop above restores nothing that changed. Without this the cancelled
        // drag keeps its edit — and an assertion that only reads
        // `mesh.vertices` cannot see it.
        restoreMorphEditBaseline();
        // Session cancel restores positions to the pre-edit baseline — a real
        // version bump (not mid-drag), so commitChange (Position) reproduces the
        // raw mutationVersion bump AND publishes the class.
        mesh.commitChange(MeshEditScope.Position);
        gpu.upload(*mesh);
        gpuMatrix      = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        propsDragging  = false;
        needsGpuUpdate = false;

        cancelEdit();
    }

    override void activate() {
        active = true;
        resetTransientState();
    }

    // Transient cache/gizmo reset shared by activate() and resyncSession()
    // (undo/redo migration P1). Factored out so the two paths can never drift:
    // activate() runs it on tool entry, resyncSession() re-runs it after a
    // committed history pop moved geometry beneath the still-active tool so the
    // gizmo + vertex cache recompute from the now-current mesh on the next
    // update(). Deliberately does NOT touch `active` (resync keeps the tool
    // active) nor any open edit session (resync is only called when there is
    // none) — it resets only the drag-invariant cache/gizmo bookkeeping that
    // activate() also clears, to the same values.
    protected void resetTransientState() {
        vertexCacheDirty = true;
        lastSelectionHash = ulong.max;
        lastMutationVersion = ulong.max;
        needsGpuUpdate = false;
        centerManual = false;
        wholeMeshDrag = false;
        propsDragging = false;
        dragAxis = -1;
        gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    }

    // Re-init the tool session against the now-current mesh after history
    // navigation popped a committed step beneath it (undo/redo P1). Only called
    // when there is NO open edit (the live-edit case is cancelUncommittedEdit).
    override void resyncSession() {
        resetTransientState();
    }

    override void deactivate() {
        if (wholeMeshDrag || propsDragging) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
            propsDragging = false;
        } else if (needsGpuUpdate) {
            gpu.upload(*mesh);
            needsGpuUpdate = false;
        }
        dragAxis = -1;
        centerManual = false;
        active = false;
    }
    
    // Single canonical selection-signature call (Mesh.selectionSignature) —
    // replaces the former per-mode selectionHash{V,E,F} dispatch. ulong (was
    // uint): a wider same-run change-detector token, harmless — nothing here
    // is persisted or compared across runs.
    // Memo for the line below, and it is worth its three fields: measured at
    // 21.25 % of a falloff drag's whole profile, the single largest symbol in
    // it — larger than the transform kernel, the falloff evaluation and the
    // GPU upload combined. `selectionSignature` is an FNV-1a walk over the
    // entire marks array, so it is O(V) per call, and `update()` asks it every
    // frame the tool is armed and not dragging.
    //
    // The key is (marksVersion, editMode, MESH ADDRESS). The address term is
    // not defensive padding: `mesh` is a pointer the tool re-binds when the
    // primary layer changes, and two layers can sit at the same marksVersion,
    // so without it a layer switch would serve the previous layer's signature.
    // Every version-keyed cache in this repository carries this term for that
    // reason.
    private ulong    selHashCache_;
    private ulong    selHashKeyVer_  = ulong.max;
    private size_t   selHashKeyMesh_;
    private EditMode selHashKeyMode_;

    // Single canonical selection-signature call (Mesh.selectionSignature) —
    // replaces the former per-mode selectionHash{V,E,F} dispatch. ulong (was
    // uint): a wider same-run change-detector token, harmless — nothing here
    // is persisted or compared across runs.
    ulong computeSelectionHash() {
        // recorded remainder (1906 §3.6): `marksVersion` owns this memo's
        // freshness term. It is the ONE counter stage 2 did not consider for
        // migration at all, and correctly: no watcher carries `Marks` (the
        // geometry and connectivity masks exclude it on purpose, and
        // `DisplayEpochMask` does not list it either), and the thing being
        // memoised — `selectionSignature` — IS the canonical content answer
        // this counter is the cheap key for. A `Marks` epoch would be a
        // strictly coarser restatement of a counter that already tracks exactly
        // this class, on the mesh itself, where every scratch mesh has one.
        //
        // (Census shape C: counter into a local, compared two lines down.)
        immutable ulong  ver  = mesh.marksVersion;
        immutable size_t addr = cast(size_t)mesh;
        if (ver == selHashKeyVer_ && addr == selHashKeyMesh_
            && *editMode == selHashKeyMode_)
            return selHashCache_;
        { import perf_probe : g_perf, Cat; g_perf.count(Cat.selectionHashCompute, 1); }
        selHashCache_   = mesh.selectionSignature(*editMode);
        selHashKeyVer_  = ver;
        selHashKeyMesh_ = addr;
        selHashKeyMode_ = *editMode;
        return selHashCache_;
    }

    void buildVertexCacheIfNeeded() {
        if (!vertexCacheDirty) return;

        int[] indices;
        if (*editMode == EditMode.Vertices)      indices = mesh.selectedVertexIndicesVertices();
        else if (*editMode == EditMode.Edges)    indices = mesh.selectedVertexIndicesEdges();
        else if (*editMode == EditMode.Polygons) indices = mesh.selectedVertexIndicesFaces();

        vertexIndicesToProcess = indices;
        vertexProcessCount = cast(int)indices.length;
        vertexCacheDirty = false;

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;
        foreach (vi; vertexIndicesToProcess)
            toProcess[vi] = true;
    }

    void uploadToGpu() {
        if (vertexProcessCount <= 0) return;
        // Change-notification (Stage 1): every standalone deformer tool
        // (Move/Rotate/Scale, bend/push) writes mesh.vertices in place mid-drag
        // WITHOUT a version bump, then funnels through this ONE per-apply upload
        // chokepoint — once per apply, never per vertex.
        //
        // Task 1906 stage 1 — `publishChange`: the Position class is DELIVERED
        // here, synchronously, and the version counters are still untouched
        // (mid-drag version stability is what keeps the in-session falloff
        // re-grade armed — see xfrm_apply.d :: applyFold's tail for the full
        // argument).
        //
        // HOW OFTEN THIS SITE RUNS, MEASURED rather than assumed (review S3; a
        // prior version of this comment said a wrapper-driven gesture step
        // "delivers twice", and that is NOT what a drag does). This function
        // is reached from exactly one shape of call site — the three banks'
        // `draw` / `drawAxesOnly` / `drawCompact`, each `if (needsGpuUpdate)`.
        // The common single-bank gizmo drag NEVER sets that flag: it stays on
        // the GPU-matrix fast path (`gpuMatrix = …`) and re-uploads nothing,
        // so a drag step publishes ONCE, in `applyFold`. Measured: a 12-step
        // drag moves `deliveryCount` by 12, not 24.
        //
        // The branches that DO set `needsGpuUpdate` are the ones that drop out
        // of that fast path — a cross-bank Move or a dirty run buffer for
        // Rotate/Scale, the value/panel-driven translate replay, and the
        // ARM-1 / ARM-2 falloff re-grade. On those a single step can publish
        // here as well as in `applyFold`; both deliveries carry the same class
        // and every listener is idempotent (dirty-bit-only), so that is a
        // parity wart and never a correctness one. It is also why
        // `tests/test_bus_delivery_granularity.d` bounds the count from BOTH
        // sides (`>= steps && <= 2 * steps`) rather than pinning `== steps`.
        //
        // Placed BEFORE the upload deliberately: a listener may not read the
        // mesh or touch GL (§1.5), so nothing here depends on the VBO being
        // current, and keeping the publish adjacent to the mutation it
        // describes is what makes the "once per apply" claim readable.
        // Task 2000 — CONFINED: `toProcess` below IS the moving set, and it is
        // the set this tool hands `snapCursor` as `excludeVerts`. See
        // `Mesh.publishConfinedChange`.
        mesh.publishConfinedChange(MeshEditScope.Position);
        if (vertexProcessCount < cast(int)(mesh.vertices.length * 0.8))
            gpu.uploadSelectedVertices(*mesh, toProcess);
        else
            gpu.upload(*mesh);
    }

    // Identical in Rotate and Scale — upload a vertex snapshot to GPU without
    // modifying mesh.vertices (used once at props-drag start to set the GPU base).
    void uploadPropsBase(Vec3[] base) {
        Vec3[] saved = mesh.vertices;
        mesh.vertices = base;
        gpu.upload(*mesh);
        mesh.vertices = saved;
    }

    // Extract camera origin from the cached view matrix (inverse of view rotation/translation).
    Vec3 viewCamOrigin() {
        const ref float[16] v = cachedVp.view;
        return Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
    }

    // Active world-space basis for transform tools. Phase 7.2c: routed
    // through the AxisStage so Move/Rotate/Scale gizmos respect the
    // user-selectable axis mode (`tool.pipe.attr axis mode <X>`).
    // Default mode=Auto + WorkplaneStage in auto = pickMostFacingPlane,
    // matching the pre-7.2 behaviour. Falls back to that direct path
    // when no AxisStage is registered (unit tests bypass app.d's pipe
    // init).
    /// Build a VectorStack for contexts that don't receive one from
    /// the app.d dispatch (headless tool.doApply, replay-without-input).
    /// Matches `buildToolVts` in app.d: stack-allocated SubjectPacket
    /// via the out-parameter so the vts pointer stays valid.
    /// Returns true if the global toolpipe is available; false in
    /// unit-test contexts with no pipe registered.
    protected bool buildLocalVts(out SubjectPacket subj, ref VectorStack vts) {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.subject  : SubjectSource, evaluateSubject;
        if (g_pipeCtx is null || mesh is null) return false;
        // Blocker 1 (0614 review): match app.d's buildToolVts — read the
        // SAME live authority so the apply path (this function) and the
        // render path (buildToolVts) agree on the subject. Left at the
        // packet's own Vertex default when no live source is wired (see
        // `selTypeSrc_`'s doc comment above).
        auto src = SubjectSource(mesh, *editMode,
                                  selTypeSrc_ ? selTypeSrc_() : SelType.Vertex,
                                  cachedVp);
        // Task 1069 — declare the morph routing target on the subject.
        // Resolved AGAINST THIS MESH by `fillSubject`, so a target naming a
        // map that this layer does not carry degrades to "no target" rather
        // than to a stale name. Requested here for every TransformTool
        // subclass; only XfrmTransformTool's apply path READS it (plan §2.0).
        src.resolveMorphTarget = true;
        return evaluateSubject(subj, vts, src);
    }

    void currentBasis(out Vec3 ax, out Vec3 ay, out Vec3 az,
                      ref VectorStack vts) {
        import toolpipe.packets            : AxisPacket;
        import tools.create.create_common         : pickMostFacingPlane;
        // ACEN.Local + multi-cluster: the gizmo's CENTER is anchored
        // to cluster 0 (actcenter.d documents
        // `state.actionCenter.center always = clusters[0]`). Orient
        // the gizmo with cluster 0's per-cluster basis too, so a
        // visible arrow direction matches the direction THAT cluster
        // actually moves under per-cluster transforms. The non-
        // primary clusters still translate along their own local
        // frames (which the kernel reads from ClusterAxes); only the
        // gizmo's displayed orientation changes.
        auto cap = queryClusterAxes(vts);
        if (cap.active) {
            ax = cap.right[0];
            ay = cap.up   [0];
            az = cap.fwd  [0];
            return;
        }
        if (auto axisPkt = vts.get!AxisPacket()) {
            // Mapping per phase7_2_plan §6: right=axisX, up=axisY
            // (=normal in workplane mode), fwd=axisZ.
            ax = axisPkt.right;
            ay = axisPkt.up;
            az = axisPkt.fwd;
            return;
        }
        auto bp = pickMostFacingPlane(cachedVp);
        ax = bp.axis1; ay = bp.normal; az = bp.axis2;
    }

    // Click-outside-gizmo hook. Move/Rotate/Scale call this after the
    // cursor ray hit the relocation plane outside the gizmo — the ACEN
    // stage records `userPlaced` so subsequent `queryActionCenter`
    // returns this point. Mode stays unchanged (Auto / None / Screen
    // all consume userPlaced; the other modes ignore it). No-op when
    // no ACEN stage is registered.
    void notifyAcenUserPlaced(Vec3 worldHit) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.setUserPlaced(worldHit);
    }

    // Task 1530 — FREEZE Mode.Element's pivot at the picked element's anchor
    // point. Paired with notifyAcenUserPlaced from the wrapper's click-pick
    // (takeVert/takeEdge/takeFace): the pin is a POINT, and from the write on
    // that button-DOWN the ACEN Element arm copies it and reads no geometry,
    // for this gesture and every later one until the next picking click.
    //
    // It replaced `notifyAcenElementVerts`, which handed the stage the picked
    // element's vertex RING so the centroid could be recomputed LIVE. That
    // recomputation read the same vertices the tool was moving; under a scale
    // or a rotate about the pivot it closed a divergent feedback loop.
    //
    // No-op when no ACEN stage is registered. PUBLIC for the wrapper→sub-tool
    // (sibling-instance) reason.
    public void notifyAcenElementPin(Vec3 anchor) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.setElementPin(anchor);
    }

    /// True iff the ACEN stage already holds EXACTLY this frozen Element
    /// anchor — the equal-write skip the wrapper's `take*` consults before
    /// re-firing the relocate. Kept here beside the writer so the two cannot
    /// drift apart. False when no ACEN stage is registered (nothing is held,
    /// so nothing can be skipped).
    public bool acenHoldsElementPin(Vec3 anchor) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return false;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return false;
        return ac.holdsElementPin(anchor);
    }

    // Display soft-pin hooks (BUG-1: Move gizmo settle, falloff-independent).
    // The Move mouse-up records the settled gizmo pivot here so the recompute
    // modes (Auto/None/Screen) keep the gizmo at the full-delta position instead
    // of snapping to the WEIGHTED moving-set centroid under falloff. This is
    // computeCenter-only and DOES NOT touch userPlaced / the relocate snapshot —
    // it leaves the relocate boundary, cross-slot commit and element-pick paths
    // exactly as they were (the whole point of a separate field). No-op when no
    // ACEN stage is registered.
    //
    // PUBLIC for the wrapper→sub-tool reason (the XfrmTransformTool wrapper sets
    // the soft pin from its moveSub's handler.center — a sibling instance, which
    // D `protected` does not grant cross-instance access to). Mirrors
    // restageActionCenterPin's public visibility.
    public void notifyAcenSoftPlaced(Vec3 settled) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.setSoftPlaced(settled);
    }

    // Clear the display soft-pin so the action center recomputes from the
    // selection. Driven from the transform wrapper at the selection / mutation
    // and ACEN-mode run boundaries — the same boundaries that invalidate the run
    // baseline (where the moving-set centroid legitimately changes). No-op when
    // no ACEN stage is registered. PUBLIC for the wrapper→sub-tool reason.
    public void clearAcenSoftPlaced() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.clearSoftPlaced();
    }

    // Re-stage the CURRENT action-center pin as the in-session-cancel
    // baseline after a relocate-boundary commit has cleared the frozen
    // snapshot. Used by the element-falloff pick+haul boundary (Phase 1b):
    // there the element pick fires `setUserPlaced` on mouse-DOWN while the
    // prior session's snapshot is still frozen (`snapFrozen == true`), so
    // that stage call does NOT stash the picked pin; `commitEdit` then
    // discards the frozen snapshot WITHOUT restoring. Re-firing the
    // notification with the stage's LIVE center (`currentCenter()` —
    // which, in Element mode, IS the picked element's anchor that the
    // pick wrote) AFTER the commit lands the stage with `snapFrozen ==
    // false`, so the fresh session's `beginEdit` freezes the PICKED pin
    // as its cancel baseline. Reading `currentCenter()` (not the move
    // handler / `vts` packet) is deliberate: the picked anchor is already
    // resident on the ACEN stage by this point, whereas the handler
    // position is only set later by `beginScreenPlaneDragAt` and the
    // `vts` packet still reflects the pre-pick evaluation. No-op when no
    // ACEN stage is registered.
    //
    // PUBLIC (not protected like its `notifyAcenUserPlaced` neighbour):
    // the wrapper (`XfrmTransformTool`) calls it on its `moveSub` —
    // a SIBLING instance, which D `protected` does not grant
    // cross-instance access to. Mirrors `MoveTool.restageRelocatePin`'s
    // public visibility for the same wrapper→sub-tool reason.
    public void restageActionCenterPin() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        notifyAcenUserPlaced(ac.currentCenter());
    }

    // Re-stage the CURRENT action-center pin VERBATIM as the in-session-cancel
    // baseline after a relocate-boundary commit cleared the frozen snapshot —
    // WITHOUT relocating the pin. Used by the Phase 5 boundary (an off-gizmo
    // plain LMB-down in a relocate-DISALLOWED mode while a session is open:
    // Select/SelectAuto/Element/Local/Origin/Manual/Border). That boundary
    // commits every open session to split the undo run but must NOT move the
    // pivot, so unlike `restageActionCenterPin` it CANNOT re-fire
    // `notifyAcenUserPlaced` (which calls `setUserPlaced` → `userPlaced = true`
    // and would force-place the pivot — wrong in Select mode). It re-stages the
    // pin state exactly as it stands via `ActionCenterStage.stageCurrentPinState`
    // (no publish, no pin mutation), so the next session's `beginEdit` freezes
    // the current (un-mutated) pin as its cancel baseline instead of a stale
    // `snapPlaced`. Matters in Element mode, where `userPlaced` is genuinely
    // set from a prior pick. No-op when no ACEN stage is registered. PUBLIC for
    // the wrapper→sub-tool reason, like `restageActionCenterPin`.
    public void stageCurrentActionCenterPin() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.stageCurrentPinState();
    }

    /// The single FalloffStage (TaskCode.Wght) — source of truth for the
    /// falloff CONFIG (type/shape/size/handle). Used by the R/S commitEdit
    /// gesture-commit hooks (P-A blocker fix) to capture the RUN-START config
    /// snapshot and compose a config-restore into the accumulator hooks, so
    /// mergeRun's first.revert restores both the accumulators AND the run-start
    /// falloff config. Mirrors the ACEN-stage accessors above.
    ///
    /// `final` (NON-virtual) and DISTINCTLY named — the XfrmTransformTool wrapper
    /// keeps its OWN same-purpose `activeFalloffStage()`. An earlier attempt made
    /// THIS the shared `public`/virtual `activeFalloffStage()` and dropped the
    /// wrapper's copy; that introduced a vtable collision: a closure that
    /// captured `this` and called `activeFalloffStage()` was dispatched through
    /// the wrong slot and SEGV'd inside the Move commitEdit revert hook. Keeping
    /// this `final` + uniquely named leaves the wrapper's virtual surface
    /// untouched, so the R/S sub-tools resolve a direct (non-virtual) call here.
    final FalloffStage falloffStageForHooks() const {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return null;
        return cast(FalloffStage)
               g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    }

    /// The WHOLE active falloff SET (every TaskCode.Wght stage, in pipe
    /// order), for the set-aware in-session re-grade undo/redo hooks. The
    /// singular `falloffStageForHooks()` above returns only the primary; with
    /// runtime falloff stacking the gesture-commit hooks must snapshot +
    /// restore EVERY instance's config, or an in-session Ctrl+Z would strand
    /// the secondaries at their post-tweak config. With a single active falloff
    /// this is a 1-element slice equivalent to `[falloffStageForHooks()]`, so
    /// the snapshot/restore stays byte-for-byte identical to the prior path.
    ///
    /// PARALLEL to (not a virtualization of) `falloffStageForHooks` — same
    /// `final` + uniquely-named discipline that the vtable-collision note above
    /// describes; the XfrmTransformTool wrapper keeps its OWN plural accessor.
    final FalloffStage[] falloffStagesForHooks() const {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        FalloffStage[] set;
        if (g_pipeCtx is null) return set;
        foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
            if (auto fs = cast(FalloffStage) s)
                set ~= fs;
        return set;
    }

    /// P-C: the single SnapStage / SymmetryStage — the config sources of truth
    /// for the snap + symmetry banks. Used by the R/S commitEdit gesture-commit
    /// hooks to snapshot the RUN-START snap + symmetry config and compose a
    /// config-restore alongside the accumulator + falloff hooks (uniform hook
    /// family). `final` + distinctly named for the same vtable-collision reason
    /// as falloffStageForHooks (the wrapper keeps its OWN
    /// activeSnapStage/activeSymmetryStage accessors).
    final SnapStage snapStageForHooks() const {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.stage    : TaskCode;
        if (g_pipeCtx is null) return null;
        return cast(SnapStage) g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
    }
    final SymmetryStage symmetryStageForHooks() const {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.stage    : TaskCode;
        if (g_pipeCtx is null) return null;
        return cast(SymmetryStage) g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
    }

    /// P-F Phase 3a (MAJOR-5) — WRAPPER field-snapshot hook pair, composed into
    /// this sub-tool's gesture-commit hook closures alongside the accumulator +
    /// pipe-config restores (uniform hook family). The R/S sub-tool accumulator
    /// hooks restore the SUB-TOOL panel state (scaleAccum/propScale, angleAccum/
    /// propDeg) — NOT the WRAPPER `run.s`/`headlessRotate` that
    /// `composeFor` folds. NB since the wrapped-role re-point: that accumulator
    /// arm is itself gated on `wrapperRef is null`, so whenever these two
    /// delegates are non-null it is INERT and the disjointness below is trivial
    /// rather than merely arranged. So the wrapper sets these two delegates right before it
    /// calls `commitGesture()`: `wrapperFieldApplyHook` restores the gesture-END
    /// run-absolute field (redo follows the geometry), `wrapperFieldRevertHook`
    /// restores the gesture-START field (in-session Ctrl+Z steps the panel back
    /// one gesture). DISJOINT from the accumulator + pipe-config state — composes
    /// into the same closure without clobber. Null when no wrapper is composing
    /// (standalone tool) ⇒ the closures skip them (inert). Cleared by the wrapper
    /// after each commit so a stale snapshot never bleeds into the next gesture.
    void delegate() wrapperFieldApplyHook  = null;
    void delegate() wrapperFieldRevertHook = null;

    /// Live falloff packet for rendering the viewport overlay. Walks
    /// the toolpipe each call — fine because draw() runs at most once
    /// per frame and the upstream stages (WORK / ACEN / etc.) are all
    /// cheap. Idle-state preview reads this; during drag the rendered
    /// overlay matches the captured `dragFalloff` (slight redundancy
    /// but they're in lockstep when no setAttr fires mid-drag).
    FalloffPacket currentFalloff(ref VectorStack vts) {
        if (auto fp = vts.get!FalloffPacket()) return *fp;
        return FalloffPacket.init;
    }

    /// Phase 7.5: snapshot the FalloffPacket at the start of a drag so
    /// per-vertex weight evaluation has stable input through the
    /// drag. Tools call this from onMouseButtonDown after they've set
    /// up `cachedVp`; lazy-evaluating per-frame would re-run every
    /// upstream stage too. No-op when no toolpipe is registered.
    /// Returns true iff falloff is active in the captured packet —
    /// callers use this to gate the whole-mesh GPU bypass off (the
    /// per-vertex weight breaks the "single uniform translation"
    /// assumption gpuMatrix relies on).
    bool captureFalloffForDrag(ref VectorStack vts) {
        if (auto fp = vts.get!FalloffPacket()) dragFalloff = *fp;
        else                                   dragFalloff = FalloffPacket.init;
        // Screen-falloff re-center fix. The host (app.d buildToolVts) evaluates
        // the pipeline and snapshots the FalloffPacket into `vts` BEFORE the
        // tool runs. A Screen-falloff soft drag re-centers the disc at the
        // click INSIDE the sub-tool's onMouseButtonDown (screenFalloffSetCenter
        // → the live FalloffStage), which happens AFTER that snapshot — so the
        // snapshot's screen center is one gesture stale. Without refreshing it,
        // `dragFalloff` freezes the PREVIOUS click's center for the whole drag
        // and the disc only catches up on the next eval at release ("screen
        // falloff modifies the geometry around the previous click during the
        // drag, then snaps to the new click on mouse-up"). Pull the live center
        // from the stage so the captured drag falloff is anchored at THIS click.
        // Move / Rotate / Scale all set the center the same way, so fixing it at
        // the shared capture site covers every soft-drag sub-tool at once.
        if (dragFalloff.enabled && dragFalloff.type == FalloffType.Screen) {
            if (auto fs = falloffStageForHooks()) {
                dragFalloff.screenCx = fs.screenCx;
                dragFalloff.screenCy = fs.screenCy;
            }
        }
        // Element-falloff re-anchor fix — same staleness as the Screen case
        // above, one level deeper. The element click-pick
        // (XfrmTransformTool.tryPickElement) runs INSIDE the sub-tool's
        // onMouseButtonDown, AFTER the host snapshotted `vts` — so the captured
        // packet still carries the PREVIOUS pick's sphere centre + anchor ring,
        // and the drag would deform around the OLD element (the picked vertex
        // wouldn't move; the previously-anchored region would). Pull the live
        // sphere centre (= the ACEN centre, which the pick just relocated onto
        // the new element) plus the freshly-built anchorRing / connectMask from
        // the stage so the drag deforms around THIS click.
        if (dragFalloff.enabled && dragFalloff.type == FalloffType.Element) {
            if (auto fs = falloffStageForHooks()) {
                // Re-run the SAME resolver evaluate() uses (ring walk /
                // connect-mask BFS / anchor world-positions) against the
                // stage's freshly click-picked raw fields (fs.anchorRing was
                // just written by tryPickElement, AFTER the host's vts
                // snapshot above — see the staleness note this branch
                // opens with). `fs.mesh_` and this tool's `mesh` accessor
                // both resolve to the document's primary under
                // single-primary editing, so the resolver reads the same
                // geometry the pick indexed (note a).
                //
                // .dup is required, not optional: resolveElementBuffers()
                // returns slices ALIASING the stage's owned buffers
                // (loopRing_/connectMask_/anchorPos_), which the very next
                // per-frame evaluate() rewrites in place. `dragFalloff` must
                // outlive that rewrite for the whole drag, so every slice is
                // copied here.
                //
                // Side effect (note b): calling this here mutates the
                // stage's owned buffers a frame early (normally only
                // evaluate() touches them). Benign — the next evaluate() in
                // the per-frame pipe walk re-runs all three resolvers and
                // overwrites them from scratch; nothing reads the owned
                // buffers between this capture and that re-eval.
                auto er = fs.resolveElementBuffers();
                dragFalloff.anchorRing  = er.ring.dup;
                dragFalloff.connectMask = er.connectMask.dup;
                dragFalloff.anchorPos   = er.anchorPos.dup;
            }
            import toolpipe.pipeline         : g_pipeCtx;
            import toolpipe.stages.actcenter : ActionCenterStage;
            import toolpipe.stage            : TaskCode;
            if (g_pipeCtx !is null)
                if (auto ac = cast(ActionCenterStage)
                              g_pipeCtx.pipeline.findByTask(TaskCode.Acen))
                    dragFalloff.pickedCenter = ac.currentCenter();
        }
        return dragFalloff.enabled;
    }

    /// Phase 7.6b: snapshot the SymmetryPacket at drag start. Same
    /// shape as captureFalloffForDrag — the pair table needs to stay
    /// stable for the duration of one drag so mirror writes don't
    /// reshuffle mid-stroke (mesh.mutationVersion would otherwise bump
    /// at beginEdit and trigger a rebuild). Returns `true` iff
    /// symmetry is active in the captured packet; tools use this to
    /// gate the whole-mesh GPU bypass off (the per-vertex mirror
    /// breaks the "single uniform translation" assumption).
    bool captureSymmetryForDrag(ref VectorStack vts) {
        if (auto sp = vts.get!SymmetryPacket()) dragSymmetry = *sp;
        else                                    dragSymmetry = SymmetryPacket.init;
        return dragSymmetry.enabled;
    }

    /// P-C: snapshot the SnapPacket at drag start — same shape as
    /// captureFalloffForDrag / captureSymmetryForDrag. Gives the
    /// transform-session refire trigger a stable run-start snap config to
    /// compare the live config against at idle. No-op (init packet, enabled
    /// false) when SnapStage is disabled / unregistered.
    void captureSnapForDrag(ref VectorStack vts) {
        if (auto sp = vts.get!SnapPacket()) dragSnap = *sp;
        else                                dragSnap = SnapPacket.init;
    }

    /// P-C: live SnapPacket for the idle-time refire compare (mirrors
    /// currentFalloff). Walks the toolpipe each call — cheap, and only the
    /// idle re-grade path reads it.
    SnapPacket currentSnap(ref VectorStack vts) {
        if (auto sp = vts.get!SnapPacket()) return *sp;
        return SnapPacket.init;
    }

    /// P-C: live SymmetryPacket for the idle-time refire compare (mirrors
    /// currentFalloff / currentSnap). The captured `dragSymmetry` already
    /// covers the drag-time read; this surfaces the live packet so the wrapper
    /// can detect a mid-run config change and re-read it before the re-grade.
    SymmetryPacket currentSymmetry(ref VectorStack vts) {
        if (auto sp = vts.get!SymmetryPacket()) return *sp;
        return SymmetryPacket.init;
    }

    /// Phase 7.6b: invoke the symmetry mirror pass on the verts that
    /// the active drag is moving (vertexIndicesToProcess). Writes
    /// mirror positions into `mesh.vertices[mi]` for every selected
    /// `vi` and projects on-plane selected verts back onto the plane.
    /// Updates `toProcess[]` so the deferred partial-upload picks up
    /// the mirror writes too. No-op when `dragSymmetry.enabled` is
    /// false.
    protected void applySymmetryToDrag() {
        if (!dragSymmetry.enabled) return;
        if (dragSymmetry.pairOf.length != mesh.vertices.length) return;
        // Build a per-vertex selected mask from vertexIndicesToProcess.
        // The base TransformTool already keeps `toProcess[]` in sync
        // with vertexIndicesToProcess — re-use it directly.
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
    }

    /// Per-vertex weight for the captured drag-falloff packet. Returns
    /// 1.0 when falloff is disabled — same convention as the snap.d
    /// short-circuit. Callers can blindly multiply per-vertex deltas
    /// by this without checking dragFalloff.enabled themselves.
    /// Task 0619: `aim` is the AIM space — `aimSpace(cachedVp, ms)` — and is
    /// a REQUIRED parameter rather than something built in here, because
    /// every caller is an O(V) loop and `aimSpace` composes a 4x4. Build it
    /// once above the loop (`dragAimSpace()` below) and pass it down.
    protected float falloffWeight(int vi, const ref AimViewport aim) {
        if (!dragFalloff.enabled) return 1.0f;
        if (vi < 0 || vi >= cast(int)mesh.vertices.length) return 1.0f;
        return evaluateFalloff(dragFalloff, mesh.vertices[vi], vi, aim);
    }

    /// The aim space for THIS tool's cached viewport and the primary layer's
    /// transform — the one composition every per-vertex falloff loop in a
    /// TransformTool subclass should hoist. Read fresh (there is no
    /// invalidation signal for `ItemXform`; 0617 §2.4 proved none exists).
    protected AimViewport dragAimSpace() {
        return aimSpace(cachedVp, primaryModelSpace());
    }

    /// Per-vertex weight evaluated at an explicit position. Used by
    /// absolute-from-baseline paths (MoveTool's re-apply-from-
    /// editBefore loop) so the weight stays anchored to the pre-edit
    /// vert position — otherwise verts on the falloff boundary would
    /// drift through the field as they move under the transform.
    /// Task 0619 — the name was a leftover and said "world": what
    /// `evaluateFalloff` takes is the vertex coordinate as it is STORED,
    /// i.e. local to the layer, and the one path this was written for
    /// (MoveTool's re-apply from `editBefore`) held exactly that. It
    /// currently has **no callers** tree-wide; it is converted rather than
    /// deleted so the next caller inherits the corrected contract instead of
    /// the old lie.
    /// Task 0659 — that contract is unchanged, and is now load-bearing in
    /// both directions: `aim` carries the layer, so `evaluateFalloff` lifts
    /// this LOCAL point into world itself. Handing it an already-world point
    /// would transform it twice on any non-identity layer.
    protected float falloffWeightAt(Vec3 localPos, int vi,
                                    const ref AimViewport aim) {
        if (!dragFalloff.enabled) return 1.0f;
        return evaluateFalloff(dragFalloff, localPos, vi, aim);
    }

    /// Hoisted to `source/falloff.d` as a free function so
    /// CommandWrapperTool and the transform tools share one
    /// implementation. Subclasses access it via the import below.
    protected static bool falloffPacketsEqual(const ref FalloffPacket a,
                                              const ref FalloffPacket b) {
        import falloff : fpeq = falloffPacketsEqual;
        return fpeq(a, b);
    }

    /// P-C: config-equality wrappers for the snap + symmetry packets, mirroring
    /// `falloffPacketsEqual`. The transform refire trigger now generalises
    /// beyond falloff (a mid-run snap toggle or symmetry toggle re-grades the
    /// applied op too), so the same idle-time inequality test is needed for all
    /// three pipe packets. Free functions in snap.d / symmetry.d so the wrapper
    /// + R/S sub-tools share one implementation.
    protected static bool snapPacketsEqual(const ref SnapPacket a,
                                           const ref SnapPacket b) {
        import snap : speq = snapPacketsEqual;
        return speq(a, b);
    }
    protected static bool symmetryPacketsEqual(const ref SymmetryPacket a,
                                               const ref SymmetryPacket b) {
        import symmetry : syeq = symmetryPacketsEqual;
        return syeq(a, b);
    }

    /// Inject the app-level persistent falloff gizmo host (mirror of
    /// setUndoBindings). app.d calls this at each XfrmTransformTool
    /// construction site so the tool registers/routes the single shared
    /// falloff emitter instead of owning its own.
    public final void setPipeGizmoHost(PipeGizmoHost h) {
        pipeGizmoHost = h;
    }

    /// True iff the ACEN stage currently holds a sticky click-outside
    /// pin. MoveTool reads this on mouse-up so it can update
    /// `userPlacedCenter` to the post-drag handler position — without
    /// it, the gizmo snaps back to the original click point on the
    /// next `update()` (the pin is sticky, but its location was frozen
    /// at click time).
    bool acenIsUserPlaced() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return false;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return false;
        return ac.isUserPlaced();
    }

    /// True iff the current ACEN mode lets click-outside-gizmo relocate
    /// the gizmo. Only Auto, None and Screen do — the other modes keep the
    /// gizmo pinned to a selection-derived or fixed point and ignore the
    /// click. With no ACEN stage registered we behave as Auto (legacy
    /// default).
    ///
    /// KNOWN DISAGREEMENT, deliberately preserved (task 0712): this answers
    /// FALSE for Pivot and Parent, while `ActionCenterStage.honoursPlacedCenter`
    /// — the stage-side predicate for what LOOKS like the same question —
    /// answers TRUE for them, and says so in its own comment ("Pivot/Parent
    /// ARE included by task 0187: an explicit relocation to a chosen point is
    /// defensible even for the live item pivot").
    ///
    /// The obvious reading of that — this predicate simply predates
    /// Pivot/Parent and was never revisited, so unify onto the deliberate one
    /// — was MEASURED AND REFUTED. Flipping these two arms to `true` makes
    /// `tests/test_item_panel_gizmo_sync.d` fail: "an off-gizmo drag in a
    /// relocate-DISALLOWED mode (`actr.pivot`) must still move the item ...
    /// pos stayed at (1.3, 0.7, -0.9)". The refusal is load-bearing and was
    /// chosen, in a later task and for a different reason than the one filed:
    /// `XfrmTransformTool`'s Item-mode off-gizmo guard (task 0614 phase 5)
    /// CONSUMES a plain off-gizmo press exactly when this predicate is true,
    /// so the two modes answering FALSE here is what keeps the item's
    /// off-gizmo drag alive — and `actr.pivot` is the natural item-mode action
    /// centre, so it is that drag's main home. That test's own comment names
    /// the coupling and says it picked `actr.pivot` BECAUSE the mode is
    /// relocate-disallowed.
    ///
    /// So the two predicates are not two spellings of one question. This one
    /// is the WRITE gate — "does a plain off-gizmo press PLACE a pin (and give
    /// up its off-gizmo drag)?" — and `honoursPlacedCenter` is the READ gate — "a
    /// pin exists; does this mode honour it over its own centre?" Pivot/Parent
    /// answer no to the first and yes to the second, and both answers are
    /// pinned: this one by `test_item_panel_gizmo_sync.d`, the other by task
    /// 0187's in-module characterization unittest in `actcenter.d`. The pin a
    /// Pivot-mode click refuses to place can still arrive by another route —
    /// `notifyAcenUserPlaced` has no mode gate, and the falloff element pick
    /// calls it whatever the mode is — and is then honoured.
    ///
    /// AND THERE IS A THIRD GATE, which 0712 counted as part of the second.
    /// `computeClickRelocateHitRaw` below has its own exhaustive `final
    /// switch` and puts Pivot/Parent in its `return false` arm: no projection
    /// plane, so no relocate, whatever THIS predicate says. Measured
    /// consequence — flipping the two arms here alone changes NOTHING about
    /// where a Pivot-mode click leaves the centre (the press reaches
    /// `computeClickRelocateHit`, gets no plane, and the bank refuses it); its
    /// only effect is to open the Item-mode guard and kill the item's
    /// off-gizmo drag. So option (A) of 0712 is not one edit that unifies two
    /// spellings: it is a fresh design decision about which plane a Pivot-mode
    /// click should project onto, plus an edit here that costs a working
    /// feature. That asymmetry is the strongest evidence the two sides are
    /// answering different questions.
    ///
    /// What 0712 still owes an answer to is whether that split should be
    /// NAMED (rename one predicate so the difference is legible) rather than
    /// erased. `tests/test_acen_relocate_read_write_split.d` pins the split
    /// itself — auto (both gates open) / pivot (write shut, read open) /
    /// origin (both shut) — so neither half can be unified away by accident
    /// while the naming question is open. Task 0705 only made the
    /// classification exhaustive.
    ///
    /// `final switch` since task 0705: the OR-chain form is exactly how the
    /// disagreement got in. The commit that added Pivot/Parent was FORCED to
    /// classify them 260 lines below, in `computeClickRelocateHitRaw`'s `final switch`,
    /// and sailed past this chain without a word.
    bool pressPlacesCenter() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return true;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return true;
        alias M = ActionCenterStage.Mode;
        final switch (ac.mode) {
            case M.Auto:
            case M.None:
            case M.Screen:
                return true;
            case M.Select:
            case M.SelectAuto:
            case M.Element:
            case M.Local:
            case M.Origin:
            case M.Manual:
            case M.Border:
                return false;
            case M.Pivot:
            case M.Parent:
                return false;   // see KNOWN DISAGREEMENT above — task 0712
        }
    }

    /// True iff an off-gizmo click already MEANS something else in the current
    /// ACEN mode, so the Move bank must not consume it as a screen-plane drag.
    ///
    /// Only Element does: there the click PICKS the anchor element, and the
    /// wrapper (not the bank) then starts a drag from the picked centre — see
    /// `XfrmTransformTool.onMouseButtonDown`'s `picked && flagT` branch, which
    /// runs AFTER the bank dispatch and would never be reached if the bank had
    /// already claimed the press. A click that misses every element in Element
    /// mode is the no-drag commit boundary, likewise owned by the wrapper.
    ///
    /// Distinct from `pressPlacesCenter()` on purpose: that predicate
    /// answers "may this click move the pivot?", this one answers "is this
    /// click already spoken for?". Element answers no to the first and yes to
    /// the second, which is exactly why one predicate could not carry both.
    bool acenClickPicksElement() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return false;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return false;
        return ac.mode == ActionCenterStage.Mode.Element;
    }

    /// Project a click pixel onto the appropriate relocation plane for
    /// the current ACEN mode:
    ///
    ///   Auto / None : active work plane — camera-most-facing principal
    ///                 axis (argmax|fwd|) through the camera focus by
    ///                 default; the user-pinned work plane when one is set.
    ///                 In-plane numeric point is PROVISIONAL (0058 follow-up).
    ///   Screen      : camera-perpendicular plane through the current
    ///                 selection bbox center.
    ///
    /// Returns false when relocation is not allowed in the current mode,
    /// or the click ray is parallel to the projection plane. Callers
    /// must have already checked `pressPlacesCenter()`.
    bool computeClickRelocateHit(int sx, int sy, out Vec3 worldHit,
                                  ref VectorStack vts) {
        if (!computeClickRelocateHitRaw(sx, sy, worldHit)) return false;
        // If SNAP is enabled, override the plane projection with the
        // snap target's world position. The user's click-outside
        // becomes a "place pivot ON this vertex / edge / face" gesture.
        // We don't exclude any verts — the gizmo isn't moving anything
        // yet, so it's legal to pin it to a selected vert too.
        SnapResult sr = evaluateSnap(worldHit, sx, sy, vts);
        publishSnap(sr);
        if (sr.snapped) worldHit = sr.worldPos;
        return true;
    }

    /// The THIRD gate task 0712 found living inside `computeClickRelocateHitRaw`
    /// below (see `pressPlacesCenter()`'s doc comment above for the full
    /// three-way split). Distinct from both siblings on purpose: that one
    /// asks "does a plain off-gizmo press PLACE a pin?" and
    /// `ActionCenterStage.honoursPlacedCenter()` asks "is an already-placed
    /// pin honoured?" — both are questions about the PIN. This one has
    /// nothing to do with pins: it is purely geometric — "does this ACEN
    /// mode even have a plane to project the click ray onto?" Auto/None and
    /// Screen do (computed below); every other mode — including Pivot/Parent,
    /// whose center is a live item pivot with no such plane — does not, and
    /// the click is refused here regardless of what the other two gates say.
    /// Measured (task 0712): flipping `pressPlacesCenter()` alone for
    /// Pivot/Parent changes nothing observable, because the press still
    /// reaches this gate and is refused here.
    import toolpipe.stages.actcenter : ActionCenterStage;
    private static bool hasProjectionSurface(ActionCenterStage.Mode m)
        pure nothrow @nogc @safe
    {
        final switch (m) {
            case ActionCenterStage.Mode.Auto:
            case ActionCenterStage.Mode.None:
            case ActionCenterStage.Mode.Screen:
                return true;
            case ActionCenterStage.Mode.Select:
            case ActionCenterStage.Mode.SelectAuto:
            case ActionCenterStage.Mode.Element:
            case ActionCenterStage.Mode.Local:
            case ActionCenterStage.Mode.Origin:
            case ActionCenterStage.Mode.Manual:
            case ActionCenterStage.Mode.Border:
            case ActionCenterStage.Mode.Pivot:
            case ActionCenterStage.Mode.Parent:
                return false;
        }
    }

    // Geometry-only click-relocate: project the cursor ray onto the
    // appropriate plane for the current ACEN mode (active work plane —
    // through the camera focus, normal = the principal world axis the
    // camera most directly faces, by default, for Auto/None; camera-
    // perpendicular through selection center for Screen). Returns false
    // in modes with no projection surface (`hasProjectionSurface` above). No
    // snap, no side-effects — pure geometry. Used by computeClickRelocateHit
    // (which then optionally snaps the result) and by updateLiveSnapPreview
    // (which decides separately what to do with the hit).
    // Both projection kinds are handled: screenPointToRay builds a
    // perspective ray from the eye or an ortho ray parallel to the view
    // forward. Under ortho a plane edge-on to the view would hold that
    // parallel ray and degenerate, so the Auto/None branch never leaves one
    // reachable — a PINNED plane and a non-axis-aligned ortho camera swap in
    // a camera-perpendicular plane (task 0226), and an axis-aligned ortho
    // camera on the AUTO plane goes through the ported law's no-ray arm,
    // which computes the same landing without intersecting anything.
    protected bool computeClickRelocateHitRaw(int sx, int sy, out Vec3 worldHit) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        import tools.create.create_common         : currentWorkplaneFrame, mostFacingAxis;
        import tools.transform.relocate_plane     : RelocatePlanePrefs, principalPlaneCenter,
                                                    lockedViewAxis;
        import viewgrid : g_viewGrid, viewWorldPerPixel, relocateQuantum,
                          viewGridSize, viewGridSubStep;
        import math : rayPlaneIntersect, screenPointToRay, isOrtho;
        Vec3 crHitOrig, dir;
        screenPointToRay(cast(float)sx, cast(float)sy, cachedVp, crHitOrig, dir);
        auto mode = ActionCenterStage.Mode.Auto;
        if (g_pipeCtx !is null) {
            auto ac = cast(ActionCenterStage)
                      g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
            if (ac !is null) mode = ac.mode;
        }
        if (!hasProjectionSurface(mode)) return false;
        final switch (mode) {
            case ActionCenterStage.Mode.Auto:
            case ActionCenterStage.Mode.None: {
                // currentWorkplaneFrame() reads WorkplaneStage state directly
                // (no pipeline.evaluate, no re-entrancy).
                auto wf = currentWorkplaneFrame();

                // --- A USER-PINNED WORK PLANE KEEPS ITS FULL FRAME. ---
                //
                // This branch is deliberately NOT routed through the ported
                // law, and the reason is a mismatch of representable state,
                // not a shortcut. A pinned plane here is an arbitrary
                // orientation plus an arbitrary point: WorkplaneStage carries
                // `rotation` as extrinsic-XYZ Euler degrees and `center` as a
                // full Vec3, both reachable from shipped commands
                // (`workplane.edit rotX/Y/Z`, `workplane.rotate`,
                // `workplane.offset`, `workplane.alignToSelection`).
                //
                // The law's lock arm cannot express that. Its whole pinned
                // state is one PRINCIPAL AXIS INDEX plus one SCALAR offset
                // along it — a free user preference in the reference, with no
                // rotation and no second/third origin component anywhere in
                // the structure. Collapsing our frame onto it would silently
                // discard the rotation and two thirds of the origin, so a
                // user who tilted the plane 30 degrees would get the pivot of
                // an axis-aligned plane instead and never be told. So the
                // pinned plane keeps `rayPlaneIntersect` against the full
                // (origin, normal), exactly as it did before the port.
                if (!wf.isAuto) {
                    Vec3 planeOrigin = wf.origin;
                    Vec3 planeNormal = wf.normal;
                    // Ortho fix (task 0226): an orthographic camera projects
                    // all rays parallel to its forward vector, so a pinned
                    // plane that is edge-on to the view holds the ray IN the
                    // plane and rayPlaneIntersect degenerates (denom≈0 →
                    // false) — the relocate would silently no-op. Swap in a
                    // camera-perpendicular plane through the same origin so
                    // the click always projects to the point under the cursor
                    // at plane-origin depth.
                    if (isOrtho(cachedVp))
                        planeNormal = Vec3(cachedVp.view[2],
                                           cachedVp.view[6],
                                           cachedVp.view[10]);
                    return rayPlaneIntersect(crHitOrig, dir,
                                             planeOrigin, planeNormal, worldHit);
                }

                // --- AUTO: the ported plane law. ---
                //
                // Everything about WHERE this lands lives in
                // `tools.transform.relocate_plane` as pure functions; this
                // call site's only job is to supply the argmax axis.
                //
                // `mostFacingAxis` is the SAME argmax `pickMostFacingPlane`
                // runs — same function, same tie-break, and that picker's
                // normal is exactly `e_k` for the same `k` — so the principal
                // axis, and hence the plane, is the one this branch already
                // used. It is a pure function of `cachedVp` (no
                // pipeline.evaluate), so this stays re-entrancy-safe on the
                // event-handling path.
                //
                // WHAT THIS CHANGES TODAY: NOTHING, and that is the honest
                // reading. With every optional term dormant (below) the law's
                // ray arm is `t = (focus[k] - P0[k]) / D[k]`, which is
                // `rayPlaneIntersect` against the plane through the focus with
                // normal `e_k` term for term; and in an axis-locked
                // orthographic view its no-ray arm returns the click with
                // coordinate `k` replaced by `focus[k]`, which is what the
                // 0226 camera-perpendicular plane already computed there
                // (under ortho the ray is parallel to `e_k`, so the
                // intersection only ever changed that one coordinate). The
                // port's gain is structural: the law is now stated where it
                // was read, each term is named and tested, and the parallel-ray
                // degeneracy is gone by construction in the one view class
                // that could hit it rather than papered over by a plane swap.
                //
                // The law's other terms are implemented and tested but
                // DORMANT, because each needs a number vibe3d has no field for
                // and no capture pinned: the out-of-plane quantum (whose step
                // our own two rigs contradict — see
                // `RelocatePlanePrefs.quantumStep`), the preferred-plane bias,
                // the view's vector-snap, and the lock arm (which this call
                // site refuses to feed, per the pinned branch above). Each
                // defaults to the value at which the reference itself skips
                // the feature.
                //
                // ONE VIEW CLASS IS CARVED OUT AND KEEPS THE 0226 FIX: an
                // orthographic camera that is NOT axis-aligned — vibe3d's
                // Perspective/Camera preset under ProjKind.Ortho. The
                // reference has no such view (its orthographic views are
                // exactly the six axis presets), so the read says nothing
                // about it and taking the law there would be a change with no
                // evidence behind it. Under ortho every point of the ray is
                // under the cursor, so the two answers differ only in DEPTH
                // along the view axis; 0226 chose focus depth and nothing
                // measured says otherwise.
                if (isOrtho(cachedVp) && lockedViewAxis(cachedVp) < 0) {
                    Vec3 camPerp = Vec3(cachedVp.view[2],
                                        cachedVp.view[6],
                                        cachedVp.view[10]);
                    return rayPlaneIntersect(crHitOrig, dir,
                                             cachedVp.focus, camPerp, worldHit);
                }
                Vec3 camBack = Vec3(cachedVp.view[2],
                                    cachedVp.view[6],
                                    cachedVp.view[10]);
                immutable int argmaxAxis =
                    mostFacingAxis(camBack, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
                RelocatePlanePrefs prefs;
                // THE OUT-OF-PLANE QUANTUM, SWITCHED ON (task 0570).
                //
                // The law rounds the plane point's out-of-plane coordinate to
                // a multiple of ten grid steps. It shipped dormant because
                // the step was unknown and two rigs appeared to demand
                // incompatible constants — see `RelocatePlanePrefs.quantumStep`
                // for how that turned out to be an axis-indexing mistake
                // rather than a real disagreement. The step is now a derived
                // quantity, not a constant, and the two rigs are two zooms of
                // it.
                //
                // It is a pure function of this view's pixel size, so it needs
                // no state and follows the camera automatically.
                immutable float _relPx = viewWorldPerPixel(cachedVp);
                prefs.quantumStep = relocateQuantum(_relPx, g_viewGrid);
                // THE VIEW'S VECTOR SNAP, SWITCHED ON (task 0570). A second,
                // separate and much finer term: every component is rounded to
                // the grid's SUB-step, which is the world length of ONE screen
                // pixel nice-ceiled — not a tenth of the drawn step. It is
                // applied to the plane point BEFORE the quantum above, and
                // `principalPlaneCenter` also feeds it to the final snap of
                // the answer.
                //
                // ONLY THE PLANE-POINT SNAP. The reference stores one
                // sub-step and would feed both this and the snap of the
                // ANSWER from it, and the first cut of this change did the
                // same — which moved a frozen characterization row by ~0.001
                // on a term the grid read does not cover. The read traces the
                // snap inside the plane-point routine; the answer-side snap
                // is the plane-law port's own reading, with no measurement
                // behind it here. So `RelocatePlanePrefs.answerSnapStep` is a
                // separate field and stays at zero until its own read
                // arrives. See its doc comment.
                //
                // Sub-pixel by construction: at most half a screen pixel of
                // world, and it cannot disturb the quantum above, which is
                // always a whole number of sub-steps.
                prefs.viewSnapStep =
                    viewGridSubStep(_relPx, viewGridSize(_relPx, g_viewGrid),
                                    g_viewGrid);
                int usedAxis;
                return principalPlaneCenter(cachedVp, crHitOrig, dir,
                                            argmaxAxis, prefs,
                                            worldHit, usedAxis);
            }
            case ActionCenterStage.Mode.Screen: {
                Vec3 selCen = currentSelectionBBoxCenter();
                Vec3 camBack = Vec3(cachedVp.view[2],
                                    cachedVp.view[6],
                                    cachedVp.view[10]);
                return rayPlaneIntersect(crHitOrig, dir,
                                         selCen, camBack, worldHit);
            }
            case ActionCenterStage.Mode.Select:
            case ActionCenterStage.Mode.SelectAuto:
            case ActionCenterStage.Mode.Element:
            case ActionCenterStage.Mode.Local:
            case ActionCenterStage.Mode.Origin:
            case ActionCenterStage.Mode.Manual:
            case ActionCenterStage.Mode.Border:
            // Task 0712: Pivot/Parent refuse HERE as well as in
            // `pressPlacesCenter` above, and the two refusals are
            // independent — opening only that one leaves the click with no
            // plane and changes nothing. Anyone reconciling the click-relocate
            // predicates has to answer "which plane?" for these two modes
            // before the question above even becomes live. Unreachable in
            // practice since `hasProjectionSurface(mode)` above already
            // returned false for every mode in this arm — kept (with the
            // rest of this arm) because `final switch` requires every Mode
            // classified here too, which is the property task 0705 relied on
            // to catch a silently-unclassified new Mode.
            case ActionCenterStage.Mode.Pivot:
            case ActionCenterStage.Mode.Parent:
                return false;
        }
    }

    // Run the SNAP stage against (rawHit, sx, sy). Returns the snap
    // result without side-effects on lastSnap or the global publish
    // channel — caller decides whether to publish. Empty exclude is
    // appropriate for click-relocate / live-preview paths (no drag
    // active, so no "moving set" to exclude); MoveTool's drag-time
    // path inlines its own snapCursor call with proper exclusions.
    protected SnapResult evaluateSnap(Vec3 rawHit, int sx, int sy,
                                       ref VectorStack vts) {
        import toolpipe.packets : SnapPacket;
        import snap             : snapCursor;
        SnapResult sr;
        auto snapPkt = vts.get!SnapPacket();
        if (snapPkt is null || !snapPkt.enabled) return sr;
        return snapCursor(rawHit, sx, sy, cachedVp, *mesh, primaryModelSpace(), *snapPkt, []);
    }

    // Mirror a SnapResult onto both the tool's local lastSnap and the
    // global publish channel (drives /api/snap/last and the cyan
    // overlay rendered from each tool's draw()).
    protected void publishSnap(SnapResult sr) {
        import snap_render : publishLastSnap;
        lastSnap = sr;
        publishLastSnap(sr);
    }

    // Live "where would the gizmo land if I clicked right now" preview.
    // Each transform tool calls this from onMouseMotion when no drag
    // is active. Updates lastSnap so draw() can render the cyan/yellow
    // overlay before the user has clicked. Cleared (no-op overlay)
    // when:
    //   - dragging (active drag owns the overlay).
    //   - cursor is ON a gizmo handle (`hitTestResult >= 0`) — clicking
    //     would start a drag, not a relocate, so a snap hint there
    //     would be misleading.
    //   - ACEN mode forbids click-relocate (Select/Element/Local/...).
    //   - Click-relocate ray missed (parallel to projection plane).
    //   - SnapStage disabled (evaluateSnap returns init).
    void updateLiveSnapPreview(int sx, int sy, int hitTestResult,
                                ref VectorStack vts) {
        SnapResult fresh;  // default-init = highlighted=false → no overlay
        scope(exit) publishSnap(fresh);
        if (dragAxis >= 0)            return;
        if (hitTestResult >= 0)        return;
        if (!pressPlacesCenter())return;
        Vec3 hit;
        if (!computeClickRelocateHitRaw(sx, sy, hit)) return;
        fresh = evaluateSnap(hit, sx, sy, vts);
    }

    // Bbox center of the current selection, independent of the ACEN
    // stage — used as the through-point for Screen-mode click-relocate
    // projection plane (the action-center stage in Screen mode publishes
    // the screen-center pixel, not the selection center).
    private Vec3 currentSelectionBBoxCenter() {
        if (mesh is null) return Vec3(0, 0, 0);
        final switch (*editMode) {
            case EditMode.Vertices: return mesh.selectionBBoxCenterVertices();
            case EditMode.Edges:    return mesh.selectionBBoxCenterEdges();
            case EditMode.Polygons: return mesh.selectionBBoxCenterFaces();
        }
    }

    // Per-cluster pivots from the ACEN stage (Phase 3 of the
    // action-center parity plan). Active only when ACEN.Local has
    // ≥2 disjoint clusters in the current selection. Tools that respect
    // per-cluster transforms (Scale, Rotate) call this and use
    // `centers[clusterOf[vi]]` as the per-vertex pivot. Move is
    // pivot-invariant for translates so it ignores the per-cluster path.
    public static struct ClusterPivots {
        Vec3[] centers;
        int [] clusterOf;
        bool active() const { return centers.length >= 2; }
    }
    ClusterPivots queryClusterPivots(ref VectorStack vts) {
        import toolpipe.packets : ActionCenterPacket;
        ClusterPivots out_;
        if (auto acen = vts.get!ActionCenterPacket()) {
            out_.centers   = acen.clusterCenters;
            out_.clusterOf = acen.clusterOf;
        }
        return out_;
    }

    // Per-cluster basis from the AXIS stage (Phase 4). Active only when
    // axis.local has ≥2 disjoint clusters in the current selection (kept
    // in lockstep with ClusterPivots via shared clusterOf indexing).
    public static struct ClusterAxes {
        Vec3[] right;
        Vec3[] up;
        Vec3[] fwd;
        bool active() const { return right.length >= 2; }
    }
    ClusterAxes queryClusterAxes(ref VectorStack vts) {
        import toolpipe.packets : AxisPacket;
        ClusterAxes out_;
        if (auto axis = vts.get!AxisPacket()) {
            out_.right = axis.clusterRight;
            out_.up    = axis.clusterUp;
            out_.fwd   = axis.clusterFwd;
        }
        return out_;
    }

    // Active action-center origin sourced from the ACEN stage (phase 7.2a).
    // Falls back to the bbox-center of the selection if no ACEN stage is
    // registered (unit tests that bypass app.d's pipe init). See the
    // action-center parity plan Phase 2.
    Vec3 queryActionCenter(ref VectorStack vts) {
        import toolpipe.packets : ActionCenterPacket;
        if (auto acen = vts.get!ActionCenterPacket())
            return acen.center;
        // Fallback (no ACEN packet published): bbox center of the
        // selection. Hits when callers passed a vts that hadn't been
        // through pipeline.evaluate, or when no ACEN-slot Operator is
        // plugged (unit tests bypassing app.d's pipe init).
        if (*editMode == EditMode.Vertices) return mesh.selectionBBoxCenterVertices();
        if (*editMode == EditMode.Edges)    return mesh.selectionBBoxCenterEdges();
        if (*editMode == EditMode.Polygons) return mesh.selectionBBoxCenterFaces();
        return Vec3(0, 0, 0);
    }
}
