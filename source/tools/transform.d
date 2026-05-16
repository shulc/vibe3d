module tools.transform;
import tool;
import mesh;
import editmode;
import math : Vec3, Viewport;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import snap : SnapResult;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import falloff : evaluateFalloff;
import falloff_handles : FalloffGizmo;
import symmetry : applySymmetryMirror;

// Factory: builds a fresh MeshVertexEdit (the tools share a registry-driven
// constructor that wires gpu+caches; the tool just calls this delegate
// rather than knowing about ViewCache + GpuMesh + Mesh separately).
alias VertexEditFactory = MeshVertexEdit delegate();

class TransformTool : Tool {
public:
    // app.d reads this every frame and sets u_model accordingly.
    // Reset to identity when not in a whole-mesh drag.
    float[16] gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

protected:
    bool          active;

    Mesh*     mesh;
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

    // Phase 7.5h+: interactive falloff endpoint handles. Built lazily
    // on first draw() that sees a Linear-typed enabled falloff packet,
    // so non-falloff sessions don't allocate GL buffers. Owned by the
    // base class because all three TransformTool subclasses (Move /
    // Rotate / Scale) need the same dispatch wiring.
    FalloffGizmo falloffGizmo;

    // Whole-mesh GPU bypass (Rotate + Scale use these; Move uses gpuOffset instead)
    bool   wholeMeshDrag;
    bool   propsDragging;
    Vec3[] dragStartVertices;

    // Vertex index cache — rebuilt once per selection change, reused every event.
    int[]  vertexIndicesToProcess;
    bool[] toProcess;
    int    vertexProcessCount;
    bool   vertexCacheDirty = true;
    int    lastSelectionHash;

    // Phase C: track the mesh's mutationVersion so update() can refresh the
    // gizmo when geometry changes without selection — e.g. after Ctrl+Z
    // reverts a transform, the selection is identical but the verts moved,
    // so the gizmo (= selection centroid) must be recomputed.
    ulong  lastMutationVersion;

    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
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
    override bool consumesFalloff() const { return true; }

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

    // Default commit: build cmd, record on history. Subclasses override to
    // attach hooks before recording (RotateTool, ScaleTool, MoveTool).
    protected void commitEdit(string label) {
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;
        history.record(cmd);
    }

    override void activate() {
        active = true;
        vertexCacheDirty = true;
        lastSelectionHash = uint.max;
        lastMutationVersion = ulong.max;
        needsGpuUpdate = false;
        centerManual = false;
        wholeMeshDrag = false;
        propsDragging = false;
        dragAxis = -1;
        gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
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
    
    uint computeSelectionHash() {
        if (*editMode == EditMode.Vertices) return mesh.selectionHashVertices();
        if (*editMode == EditMode.Edges)    return mesh.selectionHashEdges();
        if (*editMode == EditMode.Polygons) return mesh.selectionHashFaces();
        return 0;
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
    void currentBasis(out Vec3 ax, out Vec3 ay, out Vec3 az) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        import toolpipe.packets            : SubjectPacket;
        import tools.create_common         : pickMostFacingPlane;
        if (g_pipeCtx !is null
            && g_pipeCtx.pipeline.findByTask(TaskCode.Axis) !is null)
        {
            SubjectPacket subj;
            auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
            // Mapping per phase7_2_plan §6: right=axisX, up=axisY (=normal
            // in workplane mode), fwd=axisZ.
            ax = state.axis.right;
            ay = state.axis.up;
            az = state.axis.fwd;
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

    /// Live falloff packet for rendering the viewport overlay. Walks
    /// the toolpipe each call — fine because draw() runs at most once
    /// per frame and the upstream stages (WORK / ACEN / etc.) are all
    /// cheap. Idle-state preview reads this; during drag the rendered
    /// overlay matches the captured `dragFalloff` (slight redundancy
    /// but they're in lockstep when no setAttr fires mid-drag).
    FalloffPacket currentFalloff() {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.packets  : SubjectPacket;
        if (g_pipeCtx is null) return FalloffPacket.init;
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        return state.falloff;
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
    bool captureFalloffForDrag() {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.packets  : SubjectPacket;
        if (g_pipeCtx is null) {
            dragFalloff = FalloffPacket.init;
            return false;
        }
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        dragFalloff = state.falloff;
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
    bool captureSymmetryForDrag() {
        import toolpipe.pipeline : g_pipeCtx;
        import toolpipe.packets  : SubjectPacket;
        if (g_pipeCtx is null) {
            dragSymmetry = SymmetryPacket.init;
            return false;
        }
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        dragSymmetry = state.symmetry;
        return dragSymmetry.enabled;
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

    /// Phase 7.5h: structural equality for FalloffPacket — drives
    /// MoveTool.update()'s "did the user tweak falloff mid-tool?"
    /// detection. Compares the fields used by evaluateFalloff; ignores
    /// status-bar-only flags. Treats the lasso polygon as a length +
    /// element comparison (slice identity isn't enough since setAttr
    /// rebuilds the array).
    protected static bool falloffPacketsEqual(const ref FalloffPacket a,
                                              const ref FalloffPacket b) {
        if (a.enabled != b.enabled) return false;
        if (a.type    != b.type)    return false;
        if (a.shape   != b.shape)   return false;
        if (a.in_     != b.in_)     return false;
        if (a.out_    != b.out_)    return false;
        // Per-type fields. Cheap to compare all of them.
        if (a.start.x  != b.start.x  || a.start.y  != b.start.y  || a.start.z  != b.start.z)  return false;
        if (a.end.x    != b.end.x    || a.end.y    != b.end.y    || a.end.z    != b.end.z)    return false;
        if (a.center.x != b.center.x || a.center.y != b.center.y || a.center.z != b.center.z) return false;
        if (a.size.x   != b.size.x   || a.size.y   != b.size.y   || a.size.z   != b.size.z)   return false;
        if (a.screenCx     != b.screenCx)     return false;
        if (a.screenCy     != b.screenCy)     return false;
        if (a.screenSize   != b.screenSize)   return false;
        if (a.transparent  != b.transparent)  return false;
        if (a.lassoStyle   != b.lassoStyle)   return false;
        if (a.softBorderPx != b.softBorderPx) return false;
        if (a.lassoPolyX.length != b.lassoPolyX.length) return false;
        if (a.lassoPolyY.length != b.lassoPolyY.length) return false;
        foreach (i; 0 .. a.lassoPolyX.length)
            if (a.lassoPolyX[i] != b.lassoPolyX[i]) return false;
        foreach (i; 0 .. a.lassoPolyY.length)
            if (a.lassoPolyY[i] != b.lassoPolyY[i]) return false;
        return true;
    }

    /// Lazy-construct the falloff endpoint gizmo. Called from each
    /// subclass's draw() once the live falloff packet is observed.
    /// Constructing eagerly in the ctor would allocate GL VAO/VBO for
    /// tools that may never see a falloff in their lifetime.
    protected void ensureFalloffGizmo() {
        if (falloffGizmo is null)
            falloffGizmo = new FalloffGizmo();
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
    /// the gizmo. Per MODO 9: only Auto, None and Screen do — the other
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
    /// the current ACEN mode. Per MODO 9:
    ///
    ///   Auto / None : most-facing world-axis plane through (0,0,0).
    ///   Screen      : camera-perpendicular plane through the current
    ///                 selection bbox center.
    ///
    /// Returns false when relocation is not allowed in the current mode,
    /// or the click ray is parallel to the projection plane. Callers
    /// must have already checked `acenAllowsClickRelocate()`.
    bool computeClickRelocateHit(int sx, int sy, out Vec3 worldHit) {
        if (!computeClickRelocateHitRaw(sx, sy, worldHit)) return false;
        // If SNAP is enabled, override the plane projection with the
        // snap target's world position. The user's click-outside
        // becomes a "place pivot ON this vertex / edge / face" gesture.
        // We don't exclude any verts — the gizmo isn't moving anything
        // yet, so it's legal to pin it to a selected vert too.
        SnapResult sr = evaluateSnap(worldHit, sx, sy);
        publishSnap(sr);
        if (sr.snapped) worldHit = sr.worldPos;
        return true;
    }

    // Geometry-only click-relocate: project the cursor ray onto the
    // appropriate plane for the current ACEN mode (most-facing world
    // plane through origin for Auto/None; camera-perpendicular through
    // selection center for Screen). Returns false in modes that don't
    // allow click-relocate. No snap, no side-effects — pure geometry.
    // Used by computeClickRelocateHit (which then optionally snaps the
    // result) and by updateLiveSnapPreview (which decides separately
    // what to do with the hit).
    protected bool computeClickRelocateHitRaw(int sx, int sy, out Vec3 worldHit) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        import tools.create_common         : pickMostFacingPlane;
        import math : screenRay, rayPlaneIntersect;
        Vec3 dir = screenRay(sx, sy, cachedVp);
        auto mode = ActionCenterStage.Mode.Auto;
        if (g_pipeCtx !is null) {
            auto ac = cast(ActionCenterStage)
                      g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
            if (ac !is null) mode = ac.mode;
        }
        final switch (mode) {
            case ActionCenterStage.Mode.Auto:
            case ActionCenterStage.Mode.None: {
                auto bp = pickMostFacingPlane(cachedVp);
                return rayPlaneIntersect(cachedVp.eye, dir,
                                         Vec3(0, 0, 0), bp.normal, worldHit);
            }
            case ActionCenterStage.Mode.Screen: {
                Vec3 selCen = currentSelectionBBoxCenter();
                Vec3 camBack = Vec3(cachedVp.view[2],
                                    cachedVp.view[6],
                                    cachedVp.view[10]);
                return rayPlaneIntersect(cachedVp.eye, dir,
                                         selCen, camBack, worldHit);
            }
            case ActionCenterStage.Mode.Select:
            case ActionCenterStage.Mode.SelectAuto:
            case ActionCenterStage.Mode.Element:
            case ActionCenterStage.Mode.Local:
            case ActionCenterStage.Mode.Origin:
            case ActionCenterStage.Mode.Manual:
            case ActionCenterStage.Mode.Border:
                return false;
        }
    }

    // Run the SNAP stage against (rawHit, sx, sy). Returns the snap
    // result without side-effects on lastSnap or the global publish
    // channel — caller decides whether to publish. Empty exclude is
    // appropriate for click-relocate / live-preview paths (no drag
    // active, so no "moving set" to exclude); MoveTool's drag-time
    // path inlines its own snapCursor call with proper exclusions.
    protected SnapResult evaluateSnap(Vec3 rawHit, int sx, int sy) {
        import toolpipe.pipeline   : g_pipeCtx;
        import toolpipe.packets    : SubjectPacket;
        import snap                : snapCursor;
        SnapResult sr;
        if (g_pipeCtx is null) return sr;
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        if (!state.snap.enabled) return sr;
        return snapCursor(rawHit, sx, sy, cachedVp, *mesh, state.snap, []);
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
    void updateLiveSnapPreview(int sx, int sy, int hitTestResult) {
        SnapResult fresh;  // default-init = highlighted=false → no overlay
        scope(exit) publishSnap(fresh);
        if (dragAxis >= 0)            return;
        if (hitTestResult >= 0)        return;
        if (!acenAllowsClickRelocate())return;
        Vec3 hit;
        if (!computeClickRelocateHitRaw(sx, sy, hit)) return;
        fresh = evaluateSnap(hit, sx, sy);
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

    // Per-cluster pivots from the ACEN stage (Phase 3 of
    // doc/acen_modo_parity_plan.md). Active only when ACEN.Local has
    // ≥2 disjoint clusters in the current selection. Tools that respect
    // per-cluster transforms (Scale, Rotate) call this and use
    // `centers[clusterOf[vi]]` as the per-vertex pivot. Move is
    // pivot-invariant for translates so it ignores the per-cluster path.
    static struct ClusterPivots {
        Vec3[] centers;
        int [] clusterOf;
        bool active() const { return centers.length >= 2; }
    }
    ClusterPivots queryClusterPivots() {
        import toolpipe.pipeline             : g_pipeCtx;
        import toolpipe.stage                : TaskCode;
        import toolpipe.packets              : SubjectPacket;
        import toolpipe.stages.actcenter     : ActionCenterStage;
        ClusterPivots out_;
        if (g_pipeCtx is null) return out_;
        // Fast path: per-cluster pivots only exist when ACEN.mode is
        // Local. Anything else (Auto / Select / Element / …) → empty
        // ClusterPivots. Skip the full pipeline.evaluate (~1 ms on
        // 8 K-vert meshes) and the per-cluster solve unless we
        // actually need it.
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null || ac.mode != ActionCenterStage.Mode.Local)
            return out_;
        SubjectPacket subj;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        out_.centers   = state.actionCenter.clusterCenters;
        out_.clusterOf = state.actionCenter.clusterOf;
        return out_;
    }

    // Per-cluster basis from the AXIS stage (Phase 4). Active only when
    // axis.local has ≥2 disjoint clusters in the current selection (kept
    // in lockstep with ClusterPivots via shared clusterOf indexing).
    static struct ClusterAxes {
        Vec3[] right;
        Vec3[] up;
        Vec3[] fwd;
        bool active() const { return right.length >= 2; }
    }
    ClusterAxes queryClusterAxes() {
        import toolpipe.pipeline         : g_pipeCtx;
        import toolpipe.stage            : TaskCode;
        import toolpipe.packets          : SubjectPacket;
        import toolpipe.stages.axis      : AxisStage;
        ClusterAxes out_;
        if (g_pipeCtx is null) return out_;
        // Fast path: per-cluster axes only when AXIS.mode is Local.
        auto ax = cast(AxisStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Axis);
        if (ax is null || ax.mode != AxisStage.Mode.Local)
            return out_;
        SubjectPacket subj;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        out_.right = state.axis.clusterRight;
        out_.up    = state.axis.clusterUp;
        out_.fwd   = state.axis.clusterFwd;
        return out_;
    }

    // Active action-center origin sourced from the ACEN stage (phase 7.2a).
    // Falls back to the bbox-center of the selection if no ACEN stage is
    // registered (unit tests that bypass app.d's pipe init). Bbox center
    // matches MODO 9 — see doc/acen_modo_parity_plan.md Phase 2.
    Vec3 queryActionCenter() {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        import toolpipe.packets            : SubjectPacket;
        if (g_pipeCtx !is null
            && g_pipeCtx.pipeline.findByTask(TaskCode.Acen) !is null)
        {
            SubjectPacket subj;
            auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
            return state.actionCenter.center;
        }
        // Fallback (no ACEN registered): bbox center of the selection.
        if (*editMode == EditMode.Vertices) return mesh.selectionBBoxCenterVertices();
        if (*editMode == EditMode.Edges)    return mesh.selectionBBoxCenterEdges();
        if (*editMode == EditMode.Polygons) return mesh.selectionBBoxCenterFaces();
        return Vec3(0, 0, 0);
    }
}