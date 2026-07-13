module tools.transform;
import tool;
import operator : VectorStack;
import mesh;
import editmode;
import math : Vec3, Viewport;
import change_bus : MeshEditScope;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import snap : SnapResult;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket, SnapPacket, SubjectPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import pipe_gizmo_host : PipeGizmoHost;

// Factory: builds a fresh MeshVertexEdit (the tools share a registry-driven
// constructor that wires gpu+caches; the tool just calls this delegate
// rather than knowing about ViewCache + GpuMesh + Mesh separately).
alias VertexEditFactory = MeshVertexEdit delegate();

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

    // Phase C.2: undo support. history is the global stack; vertexEditFactory
    // builds a MeshVertexEdit pre-wired to the same gpu/caches the tool
    // mutates. Both are nullable for tests / older callers; tools must
    // handle the null case as "skip undo recording".
    CommandHistory     history;
    VertexEditFactory  vertexEditFactory;

    // Drag snapshot — captured by beginEdit() at drag/slider start, used by
    // commitEdit() at drag/slider end to build the MeshVertexEdit. Reset to
    // empty between sessions; isCapturing() reports whether a drag is open.
    private uint[] editIdx;
    private Vec3[] editBefore;
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

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        this.meshSrc_ = meshSrc;
        this.gpu      = gpu;
        this.editMode = editMode;
    }

    // Inject undo plumbing — called by app.d after construction. Tools
    // built by tests or older paths can skip this; in that case
    // commitEdit() is a no-op.
    public void setUndoBindings(CommandHistory h, VertexEditFactory factory) {
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

    // Phase 7.5: every TransformTool subclass (Move / Rotate / Scale)
    // applies per-vertex transforms during drag, so the Falloff stage's
    // per-vertex weight is meaningful for all of them. The actual
    // weighting logic lands per subphase (7.5b Move, 7.5c Rotate /
    // Scale). Until then this flag is harmless — there's no
    // evaluateFalloff caller yet.
    // Static capability: every TransformTool subclass (Move / Rotate /
    // Scale) applies per-vertex transforms during drag, so the Falloff
    // stage's per-vertex weight is meaningful for all of them. Declared
    // as a flag; the base `consumesFalloff()` derives from it.
    override ToolFlag flags() const { return ToolFlag.NeedsFalloff; }

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
        editCapturing = true;
    }

    // Cancel a captured edit without recording — used when the drag is
    // aborted (no movement happened, modifier-key escape, etc.).
    protected void cancelEdit() {
        editIdx.length    = 0;
        editBefore.length = 0;
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
    protected void recordCommit(MeshVertexEdit cmd) {
        if (recordViaInSession)
            history.recordInSession(cmd, history.currentRunId);
        else
            history.record(cmd);
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
    // identically; the only per-subclass part (restoring angleAccum/propDeg vs
    // scaleAccum/propScale to their session-start values) stays in each
    // sub-tool's cancelSessionIfOpen() before it calls this. Caller must have
    // verified editIsOpen() == true.
    protected void cancelOpenSessionGeometry() {
        suppressCommit = true;
        scope(exit) suppressCommit = false;

        uint[] idx  = editIndices();
        Vec3[] base = editBaseline();
        foreach (i, vid; idx) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = base[i];
        }
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
    ulong computeSelectionHash() {
        return mesh.selectionSignature(*editMode);
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
        // chokepoint. noteChange accumulates the Position class without touching
        // the counters (preserving mid-drag version stability) — once per apply,
        // never per vertex. (The unified XfrmTransformTool path also notes in
        // applyFold; a second OR within the same frame is idempotent.)
        mesh.noteChange(MeshEditScope.Position);
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
        if (g_pipeCtx is null || mesh is null) return false;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.viewport         = cachedVp;
        vts.put(&subj);
        g_pipeCtx.pipeline.evaluate(vts);
        return true;
    }

    void currentBasis(out Vec3 ax, out Vec3 ay, out Vec3 az,
                      ref VectorStack vts) {
        import toolpipe.packets            : AxisPacket;
        import tools.create_common         : pickMostFacingPlane;
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

    // Record the picked element's vertex ring on the ACEN stage so Mode.Element
    // tracks the element LIVE (gizmo follows it under the drag + stays on it
    // after release). Paired with notifyAcenUserPlaced from the wrapper's
    // click-pick (takeVert/takeEdge/takeFace). No-op when no ACEN stage is
    // registered. PUBLIC for the wrapper→sub-tool (sibling-instance) reason.
    public void notifyAcenElementVerts(const(uint)[] verts) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.setElementVerts(verts);
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
    /// `composeFor` folds. So the wrapper sets these two delegates right before it
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
    protected float falloffWeight(int vi) {
        if (!dragFalloff.enabled) return 1.0f;
        if (vi < 0 || vi >= cast(int)mesh.vertices.length) return 1.0f;
        return evaluateFalloff(dragFalloff, mesh.vertices[vi], vi, cachedVp);
    }

    /// Per-vertex weight evaluated at an explicit world position. Used
    /// by absolute-from-baseline paths (MoveTool's re-apply-from-
    /// editBefore loop) so the weight stays anchored to the pre-edit
    /// vert position — otherwise verts on the falloff boundary would
    /// drift through the field as they move under the transform.
    protected float falloffWeightAt(Vec3 worldPos, int vi) {
        if (!dragFalloff.enabled) return 1.0f;
        return evaluateFalloff(dragFalloff, worldPos, vi, cachedVp);
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
    /// the gizmo. Only Auto, None and Screen do — the other
    /// modes (Select / SelectAuto / Element / Local / Origin / Manual /
    /// Border) keep the gizmo pinned to a selection-derived or fixed
    /// point and ignore the click. With no ACEN stage registered we
    /// behave as Auto (legacy default).
    bool acenAllowsClickRelocate() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return true;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return true;
        auto m = ac.mode;
        return m == ActionCenterStage.Mode.Auto
            || m == ActionCenterStage.Mode.None
            || m == ActionCenterStage.Mode.Screen;
    }

    /// Project a click pixel onto the appropriate relocation plane for
    /// the current ACEN mode:
    ///
    ///   Auto / None : active work plane (ground Y=0 by default; the
    ///                 user-pinned work plane when one is set).
    ///                 In-plane numeric point is PROVISIONAL (0058 follow-up).
    ///   Screen      : camera-perpendicular plane through the current
    ///                 selection bbox center.
    ///
    /// Returns false when relocation is not allowed in the current mode,
    /// or the click ray is parallel to the projection plane. Callers
    /// must have already checked `acenAllowsClickRelocate()`.
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

    // Geometry-only click-relocate: project the cursor ray onto the
    // appropriate plane for the current ACEN mode (active work plane —
    // through the camera focus, normal = the principal world axis the
    // camera most directly faces, by default, for Auto/None; camera-
    // perpendicular through selection center for Screen). Returns false
    // in modes that don't allow click-relocate. No snap, no side-effects
    // — pure geometry. Used by computeClickRelocateHit (which then
    // optionally snaps the result) and by updateLiveSnapPreview (which
    // decides separately what to do with the hit).
    // Both projection kinds are handled: screenPointToRay builds a
    // perspective ray from the eye or an ortho ray parallel to the view
    // forward, and the Auto/None branch swaps in a camera-perpendicular
    // plane under ortho so the parallel ray never degenerates (task 0226).
    protected bool computeClickRelocateHitRaw(int sx, int sy, out Vec3 worldHit) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        import tools.create_common         : currentWorkplaneFrame, pickMostFacingPlane;
        import math : screenRay, rayPlaneIntersect, screenPointToRay, isOrtho;
        Vec3 crHitOrig, dir;
        screenPointToRay(cast(float)sx, cast(float)sy, cachedVp, crHitOrig, dir);
        auto mode = ActionCenterStage.Mode.Auto;
        if (g_pipeCtx !is null) {
            auto ac = cast(ActionCenterStage)
                      g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
            if (ac !is null) mode = ac.mode;
        }
        final switch (mode) {
            case ActionCenterStage.Mode.Auto:
            case ActionCenterStage.Mode.None: {
                // Project onto the active work plane. currentWorkplaneFrame()
                // reads WorkplaneStage state directly (no pipeline.evaluate,
                // no re-entrancy) and returns the stored normal/center for a
                // user-pinned (non-auto) work plane — that branch is
                // unchanged. In auto mode the plane's through-point is the
                // camera focus (not the world origin), and its normal is the
                // principal world axis the camera is most directly facing
                // (`pickMostFacingPlane`, the same camera-facing pick
                // Create-tool primitive placement already uses via
                // `pickWorkplaneFrame`) — recomputed instantaneously from the
                // live viewport on every call, with no sticky state carried
                // between clicks. `pickMostFacingPlane` is a pure function of
                // `cachedVp` (no pipeline.evaluate), so this stays
                // re-entrancy-safe on the event-handling path.
                auto wf = currentWorkplaneFrame();
                Vec3 planeOrigin = wf.origin;
                Vec3 planeNormal = wf.normal;
                if (wf.isAuto) {
                    planeOrigin = cachedVp.focus;
                    planeNormal = pickMostFacingPlane(cachedVp).normal;
                }
                // Ortho fix: an orthographic camera projects all rays parallel
                // to its forward vector. When that forward is (near-)parallel
                // to the chosen plane (e.g. a pinned plane edge-on to the
                // view), the projection ray lies IN the plane —
                // rayPlaneIntersect degenerates (denom≈0 → returns false) and
                // the relocate silently no-ops. Swap in a camera-perpendicular
                // plane through the same origin so the click always projects
                // to the point under the cursor at focus depth — matching the
                // perspective relocate in every cell. For the auto case this
                // is now largely redundant (the principal-axis normal is
                // already the axis most perpendicular to the parallel ortho
                // rays, so it rarely degenerates), but it is kept — and still
                // needed — for a user-pinned plane that happens to be edge-on
                // to an ortho camera.
                if (isOrtho(cachedVp))
                    planeNormal = Vec3(cachedVp.view[2],
                                       cachedVp.view[6],
                                       cachedVp.view[10]);
                return rayPlaneIntersect(crHitOrig, dir,
                                         planeOrigin, planeNormal, worldHit);
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
        return snapCursor(rawHit, sx, sy, cachedVp, *mesh, *snapPkt, []);
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
        if (!acenAllowsClickRelocate())return;
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
