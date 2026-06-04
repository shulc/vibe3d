module tools.edge_extend;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.edge_extend_edit : MeshEdgeExtendEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import mesh_edit_delta : MeshEditTracker, MeshEditDelta, MeshEditScope;
import tools.xfrm_transform : XfrmTransformTool;
import tools.move : MoveTool;

/// The interactive tool reuses the dedicated MeshEdgeExtendEdit record command
/// (a before/after MeshSnapshot pair OR an operation-log MeshEditDelta) — the
/// same plumbing EdgeExtrudeTool uses for MeshEdgeExtrudeEdit. A dedicated class
/// keeps the undo label reading "Edge Extend".
alias EdgeExtendEditFactory = MeshEdgeExtendEdit delegate();

// VIBE3D_UNDO_TRACKER toggle (doc/undo_change_tracker_plan.md, Phase 4 §D), the
// same escape hatch the extrude tool exposes: truthy (the DEFAULT) records a
// MeshEditDelta at commit; an explicit falsey value forces the before/after
// MeshSnapshot pair. Read ONCE and cached. Independent of the extrude tool's
// flag so the two tools can be toggled separately by a parity test.
private bool g_undoTrackerChecked = false;
private bool g_undoTrackerOn      = true;
bool undoTrackerEnabled() {
    if (!g_undoTrackerChecked) {
        import std.process : environment;
        import std.uni : toLower;
        g_undoTrackerChecked = true;
        auto v  = environment.get("VIBE3D_UNDO_TRACKER", "");
        auto lv = v.toLower;
        g_undoTrackerOn = !(lv == "0" || lv == "off" || lv == "false" || lv == "no");
    }
    return g_undoTrackerOn;
}

// Test-automation override (parity-gate lever), mirroring the extrude tool's
// setUndoTrackerEnabled. Wired to the `undo.tracker` command in app.d.
void setUndoTrackerEnabled(bool on) {
    g_undoTrackerChecked = true;
    g_undoTrackerOn      = on;
}

// ---------------------------------------------------------------------------
// EdgeExtendTool — interactive Edge Extend (factory id `edge.extend`).
//
// Topology lifecycle is the EdgeExtrudeTool template (BoxTool/PenTool family):
// a topology-creating tool owns its undo plumbing and commits ONE before/after
// record command at deactivate. TransformTool's vertex-position-delta
// MeshVertexEdit cannot undo added verts/faces, so it is unusable here.
//
//   activate()  — capture `before` = MeshSnapshot.capture(mesh) (geometry +
//                 selection); reset offset/rotate/scale to identity; run the
//                 kernel once with the current params (so the ridge appears on
//                 activation, defaults inset=0.1/shift=0).
//   drag        — see "Interactive surface" below: the embedded transform
//                 gizmo's Move bank produces a basis-local translate scalar; the
//                 host drains it, projects it to a world delta, ADDS it into the
//                 `offset` param, then rebuildPreview() (revert to `before` →
//                 re-run extendEdgesByMask from the clean cage → refreshCaches).
//   deactivate() — if any geometry was built, capture `after`, build a
//                 MeshEdgeExtendEdit via the injected factory, and push it onto
//                 history as ONE undo step (snapshot or delta path).
//
// Interactive surface (doc/edge_extend_plan.md §4) — EMBED, do NOT clone gizmos.
// The host owns one XfrmTransformTool purely for its gizmo banks + shared
// ToolHandles arbiter. It NEVER calls the wrapper's applyTRS (which would mutate
// mesh.vertices and open the wrapper's own edit session). Instead the host
// drives the Move SUB-TOOL directly (moveBank()): MoveTool is a pure
// gesture-scalar producer — its onMouseButtonDown / onMouseMotion /
// onMouseButtonUp set dragAxis + write pendingTranslateDelta and touch no
// geometry. The host reads that scalar, projects it through the move handler's
// world axes, accumulates it into the Extend `offset` param, and the kernel
// RE-RUN is the geometry apply. The wrapper still gets draw/update so the banks
// render + the arbiter highlights on hover. Phase 4a consumes the Move bank +
// haul (Offset) only; Rotate/Scale banks are 4b (kernel pivot arg already wired).
//
// PER-TICK RE-EVALUATE (the critical law, §4.2): a drag WRITES the op's params
// and RE-RUNS the kernel from the pre-extend cage — it does NOT vertex-transform
// the post-extend ridge. With segments>1, ring k gets (k/N)·Offset; a plain
// selection-transform would move only the outermost ring. Re-running distributes
// correctly. rebuildPreview() is that revert+re-run.
//
// The headless path (`tool.set edge.extend on; tool.attr edge.extend offsetX
// <v>; tool.doApply`) drives the SAME kernel through applyHeadless();
// ToolDoApplyCommand wraps it with a snapshot pair for undo (so applyHeadless
// MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class EdgeExtendTool : Tool {
private:
    Mesh*            mesh;
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory        history;
    EdgeExtendEditFactory factory;

    // Embedded transform gizmo — T=R=S all enabled (all banks visible), but only
    // the Move bank's gesture is consumed in 4a. Constructed in this().
    XfrmTransformTool xfrm;

    // Parameters — exposed via params() so both the Tool Properties panel and
    // the headless tool.attr path write into them. Same defaults as the one-shot
    // mesh.edge_extend command (inset=0.1, shift=0, offset=0, rotate=0, scale=1,
    // segments=1).
    float inset_   = 0.1f;
    float shift_   = 0.0f;
    float offsetX_ = 0.0f, offsetY_ = 0.0f, offsetZ_ = 0.0f;
    float rotateX_ = 0.0f, rotateY_ = 0.0f, rotateZ_ = 0.0f;
    float scaleX_  = 1.0f, scaleY_  = 1.0f, scaleZ_  = 1.0f;
    int   segments_ = 1;

    // Interactive session state.
    bool         active;           // between activate() and deactivate()
    bool         built;            // true once the kernel built ridge topology
    MeshSnapshot before;           // captured at activate() (geometry + selection)
    Viewport     cachedVp;

    // Move-gesture drag state. While a Move drag is captured the host freezes the
    // kernel-fed pivot (§4.4) and the per-drag base offset; each motion sets
    // offset = dragBaseOffset + (move world delta since drag start).
    bool dragging;                 // a Move-bank gesture is captured
    Vec3 dragBaseOffset;           // `offset` at drag start
    Vec3 frozenPivot = Vec3(0, 0, 0);  // ACEN center frozen at drag start (R/S in 4b)

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
        // The embedded wrapper reuses the same mesh/gpu/editMode pointers. T/R/S
        // all on; for 4a only the Move bank's gesture is drained, but the Rotate/
        // Scale banks still render (4b consumes them).
        xfrm = new XfrmTransformTool(mesh, gpu, editMode);
    }

    /// Inject undo plumbing — called by app.d after construction. commitEdit()
    /// is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, EdgeExtendEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Edge Extend"; }

    // Edge Extend only makes sense on an edge selection.
    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        // 4a surfaces the full param set. Rotate/Scale are present (so the panel
        // + headless drive can set them and the kernel honours them), but the
        // interactive R/S gizmo drag is 4b — they are editable here, not hidden:
        // a numeric rotate/scale edit re-runs the kernel about the world origin
        // (pivot defaults to origin) exactly like the one-shot command.
        return [
            Param.float_("inset",   "Local Inset", &inset_,   0.1f),
            Param.float_("shift",   "Local Shift", &shift_,   0.0f),
            Param.float_("offsetX", "Offset X",    &offsetX_, 0.0f),
            Param.float_("offsetY", "Offset Y",    &offsetY_, 0.0f),
            Param.float_("offsetZ", "Offset Z",    &offsetZ_, 0.0f),
            Param.float_("rotateX", "Rotate X",    &rotateX_, 0.0f),
            Param.float_("rotateY", "Rotate Y",    &rotateY_, 0.0f),
            Param.float_("rotateZ", "Rotate Z",    &rotateZ_, 0.0f),
            Param.float_("scaleX",  "Scale X",     &scaleX_,  1.0f),
            Param.float_("scaleY",  "Scale Y",     &scaleY_,  1.0f),
            Param.float_("scaleZ",  "Scale Z",     &scaleZ_,  1.0f),
            Param.int_  ("segments","Segments",    &segments_, 1),
        ];
    }

    override void activate() {
        active = true;
        // Bring the embedded gizmo online (its sub-tools' activate + wrapperRef
        // wiring). The wrapper never owns geometry here, but it needs to be
        // active so its banks render + hit-test.
        xfrm.activate();
        reinitSession();
    }

    // (Re)initialise the edit session against the CURRENT mesh — shared by
    // activate() and resyncSession() (undo/redo P1) so they can't drift. Does
    // NOT set `active`. Re-snapshots the clean cage + selection and clears any
    // built preview, leaving the mesh UNTOUCHED.
    //
    // Deliberately does NOT build a preview here (the EdgeExtrudeTool template):
    // the headless `tool.doApply` path goes through activate()→applyHeadless(),
    // and ToolDoApplyCommand captures its pre-snapshot BEFORE applyHeadless runs.
    // Building a preview on activate would poison that pre-snapshot (undo would
    // restore the preview ridge, not the clean cage). The interactive ridge
    // appears on the first drag / param edit (rebuildPreview), exactly like the
    // extrude tool's ridge appears on the first drag.
    private void reinitSession() {
        built    = false;
        dragging = false;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // Commit one undo step iff the kernel actually built topology.
        if (active && built)
            commitEdit();
        xfrm.deactivate();
        active   = false;
        built    = false;
        dragging = false;
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    public override bool hasUncommittedEdit() const {
        return active && built;
    }
    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }
    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    override void onParamChanged(string name) {
        // Interactive Tool Properties edit → rebuild the live preview from the
        // clean cage. Headless `tool.attr ...; tool.doApply` leaves the mesh
        // untouched (applyHeadless owns the single apply), matching the extrude
        // template — otherwise ToolDoApplyCommand's pre-snapshot is poisoned.
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // Keep the embedded gizmo's per-frame state (handler center from ACEN, gizmo
    // orientation from AXIS) up to date. Forwarded so the banks co-locate at the
    // selection/action center.
    override void update(ref VectorStack vts) {
        if (!active) return;
        xfrm.update(vts);
    }

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the kernel once on the current edge
    // selection. MUST NOT snapshot — ToolDoApplyCommand wraps with undo.
    // -----------------------------------------------------------------------
    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live preview was built, restore the clean cage first so the kernel
        // applies exactly once. In the pure headless flow `before` == current
        // mesh, so this is a no-op and ToolDoApplyCommand's pre-snapshot is clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.edges.length == 0) return false;
        auto mask = currentMask();
        size_t n = mesh.extendEdgesByMask(mask, inset_, shift_,
                                          offsetVec(), rotateVec(), scaleVec(),
                                          segments_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // Interactive drag — driven by the embedded Move bank (§4.1 option (b)).
    //
    // LMB-down: forward to the Move sub-tool's hit-test. On an arrow/plane
    // handle (dragAxis>=0) begin the drag directly; on a miss begin a haul via
    // the Move bank's screen-plane drag (dragAxis==3). Either way the gesture
    // feeds the same `offset` param.
    // -----------------------------------------------------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            // Cancel: drop any built topology, restore the original cage.
            cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0) return false;

        MoveTool mv = xfrm.moveBank();
        bool onHandle = mv.onMouseButtonDown(e, vts);   // sets dragAxis on a hit
        if (!onHandle) {
            // Off-handle: begin a HAUL — the Move bank's screen-plane drag,
            // anchored at the gizmo center, accumulating into world-axis Offset
            // via the SAME work-plane projection MoveTool uses for free-move.
            bool ctrl = (mods & KMOD_CTRL) != 0;
            mv.beginScreenPlaneDragAt(e.x, e.y, xfrm.moveGizmoCenter(),
                                      ctrl, /*notifyAcen=*/false, vts);
        }
        // Begin the host-owned drag. Freeze the kernel-fed pivot at drag-start
        // (§4.4) — inert for pure Offset (Offset is pivot-agnostic), but the seam
        // R/S needs in 4b. Snapshot the per-drag base offset.
        dragging       = true;
        dragBaseOffset = offsetVec();
        frozenPivot    = xfrm.actionCenter(vts);
        accumLocal_    = Vec3(0, 0, 0);   // fresh basis-local accumulator per drag
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        MoveTool mv = xfrm.moveBank();
        bool consumed = mv.onMouseMotion(e, vts);   // writes pendingTranslateDelta
        if (!consumed) return true;
        // Drain the Move bank's basis-local scalar into the wrapper's running
        // headlessTranslate so moveWorldDeltaSinceDragStart() reflects the full
        // drag. (We drain via the wrapper accessor: read the per-event scalar
        // here, fold it into the wrapper's accumulator, then zero it — matching
        // how the wrapper itself drains in onMouseMotion.)
        Vec3 worldDelta = drainMoveWorldDelta();
        // offset = base + accumulated world delta since drag start. (worldDelta
        // here is the ABSOLUTE accumulated delta, not the per-event step.)
        offsetX_ = dragBaseOffset.x + worldDelta.x;
        offsetY_ = dragBaseOffset.y + worldDelta.y;
        offsetZ_ = dragBaseOffset.z + worldDelta.z;
        rebuildPreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        xfrm.moveBank().onMouseButtonUp(e, vts);   // clears the sub-tool dragAxis
        dragging = false;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        cachedVp = vp;
        if (!active) return;
        // The embedded wrapper renders the gizmo banks + runs the shared arbiter
        // (hover highlight). The Move bank co-locates at the selection/action
        // center the kernel re-selected (the new ridge edges).
        xfrm.draw(shader, vp, vts);
    }

private:
    Vec3 offsetVec() const { return Vec3(offsetX_, offsetY_, offsetZ_); }
    Vec3 rotateVec() const { return Vec3(rotateX_, rotateY_, rotateZ_); }
    Vec3 scaleVec()  const { return Vec3(scaleX_,  scaleY_,  scaleZ_); }

    // Pivot fed to the kernel for the live preview. 4a drives Offset only, which
    // is pivot-agnostic, so this is inert (origin == frozenPivot gives identical
    // output for translate). The seam is wired now: 4b's R/S drag conjugates R/S
    // about frozenPivot (the ACEN center frozen at drag start).
    Vec3 livePivot() const {
        return dragging ? frozenPivot : Vec3(0, 0, 0);
    }

    // Drain the per-event Move scalar the sub-tool just produced, fold it into a
    // host-owned basis-local accumulator (`accumLocal_`, reset at drag start),
    // and return the ABSOLUTE accumulated WORLD delta since drag start. The
    // wrapper's own drain in XfrmTransformTool.onMouseMotion never runs because
    // the host drives moveSub DIRECTLY (it never forwards motion to the wrapper),
    // so the host owns the accumulation. Project through the live move-handler
    // axes (the work-plane basis the free-move haul + on-arrow drags share).
    Vec3 drainMoveWorldDelta() {
        MoveTool mv = xfrm.moveBank();
        Vec3 pending = mv.pendingTranslateDelta;
        mv.pendingTranslateDelta = Vec3(0, 0, 0);
        accumLocal_ = accumLocal_ + pending;
        return mv.handler.axisX * accumLocal_.x
             + mv.handler.axisY * accumLocal_.y
             + mv.handler.axisZ * accumLocal_.z;
    }
    Vec3 accumLocal_ = Vec3(0, 0, 0);   // basis-local translate accumulated this drag

    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching the
    // mesh.edge_extend / mesh.delete convention).
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Edges)) {
            auto m = new bool[](mesh.edges.length);
            m[] = true;
            return m;
        }
        return mesh.selectedEdges;
    }

    // Revert to the pre-extend cage + selection, then re-run the kernel from the
    // current params. This is the per-tick re-evaluate (§4.2): WRITE params +
    // RE-RUN, never vertex-transform the post-extend ridge.
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        auto mask = currentMask();
        size_t n = mesh.extendEdgesByMask(mask, inset_, shift_,
                                          offsetVec(), rotateVec(), scaleVec(),
                                          segments_, livePivot());
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd = factory();

        if (undoTrackerEnabled()) {
            // Delta path. Re-run the kernel ONCE inside a Mesh edit batch so the
            // committed extend self-records an operation-log delta. before.restore
            // MUST precede beginEditBatch: a built preview left the mesh as the
            // ridge AND reselected the post-extend ridge edges; currentMask()
            // reads mesh.selectedEdges, so without the rewind the batch would
            // extend the WRONG (ridge) edges. The restore rewinds the clean cage +
            // the ORIGINAL edge selection (un-tracked rewind, not part of the
            // logged batch). The pivot is the same frozen pivot the last preview
            // used so the committed geometry matches what the user saw.
            before.restore(*mesh);

            auto rec = MeshEditTracker();
            mesh.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
            auto mask = currentMask();
            mesh.extendEdgesByMask(mask, inset_, shift_,
                                   offsetVec(), rotateVec(), scaleVec(),
                                   segments_, frozenPivot);
            auto delta = mesh.endEditBatch();

            refreshCaches();

            if (!delta.isEmpty) {
                cmd.setDelta(delta, "Edge Extend");
                history.record(cmd);
                return;
            }
            // Degenerate delta — fall through to the snapshot path.
        }

        // Snapshot path (VIBE3D_UNDO_TRACKER=off / degenerate delta).
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Extend");
        history.record(cmd);
    }

    void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }

    // Category A live-edit cancel (RMB / undo-redo P0): drop any built topology,
    // restore the original cage, reset the drag state. Records nothing.
    void cancelLiveEdit() {
        before.restore(*mesh);
        refreshCaches();
        built       = false;
        dragging    = false;
        accumLocal_ = Vec3(0, 0, 0);
    }
}
