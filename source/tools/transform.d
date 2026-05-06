module tools.transform;
import tool;
import mesh;
import editmode;
import math : Vec3, Viewport;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;

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

        Vec3[] after_;
        after_.length = editIdx.length;
        bool changed = false;
        foreach (i, vid; editIdx) {
            after_[i] = mesh.vertices[vid];
            if (after_[i].x != editBefore[i].x
             || after_[i].y != editBefore[i].y
             || after_[i].z != editBefore[i].z)
                changed = true;
        }
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

    // Click-outside-gizmo hook (phase 7.2b). Move/Rotate/Scale call this
    // after the cursor ray hit a construction plane outside the gizmo —
    // the ACEN stage records `userPlaced` so subsequent
    // `queryActionCenter` returns this point. Mode stays Auto (matches
    // MODO "Auto NOT fixed; click away → new center"). No-op when no
    // ACEN stage is registered.
    void notifyAcenUserPlaced(Vec3 worldHit) {
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stages.actcenter   : ActionCenterStage;
        import toolpipe.stage              : TaskCode;
        if (g_pipeCtx is null) return;
        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        if (ac is null) return;
        ac.setAutoUserPlaced(worldHit);
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
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        import toolpipe.packets            : SubjectPacket;
        ClusterPivots out_;
        if (g_pipeCtx is null) return out_;
        if (g_pipeCtx.pipeline.findByTask(TaskCode.Acen) is null) return out_;
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
        import toolpipe.pipeline           : g_pipeCtx;
        import toolpipe.stage              : TaskCode;
        import toolpipe.packets            : SubjectPacket;
        ClusterAxes out_;
        if (g_pipeCtx is null) return out_;
        if (g_pipeCtx.pipeline.findByTask(TaskCode.Axis) is null) return out_;
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