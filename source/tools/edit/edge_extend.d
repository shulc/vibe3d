module tools.edit.edge_extend;

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
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import mesh_edit_delta : MeshEditTracker, MeshEditDelta, MeshEditScope,
    undoTrackerEnabled;
import tools.transform.xfrm_transform : XfrmTransformTool;
import pipe_gizmo_host : PipeGizmoHost;
import tools.transform.move : MoveTool;
import tools.transform.rotate : RotateTool;
import tools.transform.scale : ScaleTool;

import std.json : JSONValue;

/// The interactive tool reuses the dedicated MeshSessionEdit record command
/// (a before/after MeshSnapshot pair OR an operation-log MeshEditDelta) — the
/// same plumbing EdgeExtrudeTool uses for MeshSessionEdit. A dedicated class
/// keeps the undo label reading "Edge Extend".
alias EdgeExtendEditFactory = MeshSessionEdit delegate();

// The VIBE3D_UNDO_TRACKER toggle (`undoTrackerEnabled`/`setUndoTrackerEnabled`)
// lives in `mesh_edit_delta` — one definition shared with edge_extrude.d,
// delete.d and remove.d. See that module for the toggle's semantics.

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
//                 MeshSessionEdit via the injected factory, and push it onto
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
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
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

    // Which gizmo bank the shared arbiter handed this drag (mirrors how
    // XfrmTransformTool's onMouseButtonDown picks the hot bank: try Move, then
    // Rotate, then Scale, first real-handle grab wins). DragBank.None = no drag.
    enum DragBank { None, Move, Rotate, Scale }
    DragBank dragBank = DragBank.None;

    // Move-gesture drag state. While a drag is captured the host freezes the
    // kernel-fed pivot (§4.4, used by R/S) and, for Move, the per-drag base
    // offset; each motion sets offset = dragBaseOffset + (move world delta since
    // drag start).
    Vec3 dragBaseOffset;           // `offset` at drag start (Move bank)
    Vec3 frozenPivot = Vec3(0, 0, 0);  // ACEN center frozen at drag start (R/S pivot)

    // Test-only override for the headless apply pivot. Backed by the HIDDEN
    // `_dragPivot` param (set via tool.attr): writing it arms `.active`; the next
    // applyHeadless consumes it (one-shot). Lets a parity test pin the sel-center
    // R/S pivot the interactive drag would freeze, without a synthesized viewport
    // drag. `.value` IS the param's storage so injectParamsInto writes it directly.
    struct PivotOverride { bool active; Vec3 value = Vec3(0, 0, 0); }
    PivotOverride dragPivotOverride_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
        // The embedded wrapper reuses the same mesh/gpu/editMode pointers. T/R/S
        // all on; for 4a only the Move bank's gesture is drained, but the Rotate/
        // Scale banks still render (4b consumes them).
        xfrm = new XfrmTransformTool(meshSrc, gpu, editMode);
    }

    /// Inject undo plumbing — called by app.d after construction. commitEdit()
    /// is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, EdgeExtendEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    /// Forward the app-level falloff gizmo host to the embedded transform
    /// wrapper (falloff stage-gizmo refactor, step 4). The embedded
    /// XfrmTransformTool registers / routes the single shared emitter through
    /// its own arbiter cycle exactly like a standalone transform tool; without
    /// this the embedded wrapper would have a null host (falloff handles inert
    /// — and pre-fix, a null deref).
    void setPipeGizmoHost(PipeGizmoHost h) {
        xfrm.setPipeGizmoHost(h);
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
            Param.float_("rotateX", "Rotate X",    &rotateX_, 0.0f).angle(),
            Param.float_("rotateY", "Rotate Y",    &rotateY_, 0.0f).angle(),
            Param.float_("rotateZ", "Rotate Z",    &rotateZ_, 0.0f).angle(),
            Param.float_("scaleX",  "Scale X",     &scaleX_,  1.0f),
            Param.float_("scaleY",  "Scale Y",     &scaleY_,  1.0f),
            Param.float_("scaleZ",  "Scale Z",     &scaleZ_,  1.0f),
            // `.max(1024).enforceBounds()` matches Mesh.extendEdgesByMask's
            // internal `MAX_EXTEND_SEGMENTS` cap — the Param bound alone is
            // a UI-only hint and does not clamp a raw HTTP write.
            Param.int_  ("segments","Segments",    &segments_, 1).min(1).max(1024).enforceBounds(),
            // HIDDEN test-automation hook (Phase 4b): the sel-center R/S pivot the
            // interactive drag would freeze. Setting it via tool.attr arms a
            // one-shot override consumed by the next applyHeadless (see
            // dragPivotOverride_ / onParamChanged). Not shown in the panel.
            Param.vec3_ ("_dragPivot", "Drag Pivot (test)",
                         &dragPivotOverride_.value, Vec3(0, 0, 0)).hidden(),
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
        dragBank = DragBank.None;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // Commit one undo step iff the kernel actually built topology.
        if (active && built)
            commitEdit();
        xfrm.deactivate();
        active   = false;
        built    = false;
        dragBank = DragBank.None;
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

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    public override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
    }

    override void onParamChanged(string name) {
        // HIDDEN test hook: writing a NON-default _dragPivot arms the one-shot
        // headless pivot override (consumed by the next applyHeadless). It must
        // NOT rebuild a preview (it is not a geometry param) and is a no-op in
        // the panel (property_panel/args_dialog skip hidden params). Arming only
        // on a non-zero value keeps a default write inert so the override can
        // never be latched accidentally.
        if (name == "_dragPivot") {
            Vec3 p = dragPivotOverride_.value;
            dragPivotOverride_.active = (p.x != 0 || p.y != 0 || p.z != 0);
            return;
        }
        // Interactive Tool Properties edit → rebuild the live preview from the
        // clean cage. Headless `tool.attr ...; tool.doApply` leaves the mesh
        // untouched (applyHeadless owns the single apply), matching the extrude
        // template — otherwise ToolDoApplyCommand's pre-snapshot is poisoned.
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // Read-only test/introspection seam (mirrors poly.bevel / edge.bevel):
    // exposes the tool's live params to /api/tool/state + the step-trace `tool`
    // block so a per-step differential (trace_diff) can route this headless
    // `tool.doApply` edit by its identity and read the full inset/shift +
    // offset/rotate/scale/segments param set.
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]     = JSONValue("edgeExtend");
        root["inset"]    = JSONValue(inset_);
        root["shift"]    = JSONValue(shift_);
        root["offsetX"]  = JSONValue(offsetX_);
        root["offsetY"]  = JSONValue(offsetY_);
        root["offsetZ"]  = JSONValue(offsetZ_);
        root["rotateX"]  = JSONValue(rotateX_);
        root["rotateY"]  = JSONValue(rotateY_);
        root["rotateZ"]  = JSONValue(rotateZ_);
        root["scaleX"]   = JSONValue(scaleX_);
        root["scaleY"]   = JSONValue(scaleY_);
        root["scaleZ"]   = JSONValue(scaleZ_);
        root["segments"] = JSONValue(segments_);
        root["built"]    = JSONValue(built);
        return root;
    }

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
        // Headless pivot policy. The headless `tool.attr ...; tool.doApply` path
        // uses the world ORIGIN by default — the SAME pivot the one-shot
        // mesh.edge_extend command uses — so the headless tool path and the command
        // path stay byte-identical (the 4a command-parity test pins this; the ACEN
        // sel-center would diverge even on an origin cube because an edge's ACEN is
        // its centroid, not the origin). The sel-center R/S pivot is an
        // INTERACTIVE-drag property (frozenPivot, captured at drag-start, fed via
        // livePivot() into rebuildPreview) reached through the gizmo bank drain,
        // NOT this attr path. The HIDDEN test-automation param `_dragPivot` (set via
        // tool.attr) pins that drag pivot for ONE doApply so a parity test can
        // reproduce the captured off-origin R/S numbers — which depend on the
        // sel-center pivot — without a synthesized viewport drag.
        Vec3 pivot = dragPivotOverride_.active
                   ? dragPivotOverride_.value : Vec3(0, 0, 0);
        dragPivotOverride_.active = false;   // one-shot: never leak into a later apply
        size_t n = mesh.extendEdgesByMask(mask, inset_, shift_,
                                          offsetVec(), rotateVec(), scaleVec(),
                                          segments_, pivot);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // Interactive drag — driven by the three embedded gizmo banks (§4.1/§4.2/
    // §4.3, option (b)). The host forwards the down/motion/up events to whichever
    // bank the shared ToolHandles arbiter selected and drains that bank's pending
    // gesture scalar into the matching Extend op param, then re-runs the kernel.
    //
    // Bank selection mirrors XfrmTransformTool.onMouseButtonDown: try Move, then
    // Rotate, then Scale; the first bank whose hit-test grabs a REAL handle
    // (dragAxis>=0) owns the drag. The banks' screen radii are disjoint (move
    // arrows vs rotate rings vs scale handles) so in practice exactly one grabs.
    // On a total miss, the Move bank begins a HAUL (screen-plane Offset drag),
    // matching 4a.
    //   - Move   → Offset (world-axis, pivot-agnostic; haul + on-arrow share it).
    //   - Rotate → rotateDeg component (principal ring axis → X/Y/Z), about the
    //              FROZEN sel-center pivot.
    //   - Scale  → scale component (handle axis → X/Y/Z), about the FROZEN pivot.
    // R/S are absolute-since-drag-start (the sub-tools publish the accumulated
    // factor/angle), so the host SETS the component (not +=); Move accumulates a
    // world delta. The frozen pivot is captured at drag-start for ALL banks.
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

        // EdgeExtendTool drives these embedded banks DIRECTLY and never enters the
        // wrapper's begin*DragSession path, so the wrapped input-frame channel
        // (setWrapperInputFrame) is never pushed here — each bank reads its own
        // standalone inputBasis*, and the unified GestureFrame stays inert.
        MoveTool   mv = xfrm.moveBank();
        RotateTool rt = xfrm.rotateBank();
        ScaleTool  sc = xfrm.scaleBank();

        // Bank dispatch — same try-in-order priority the wrapper uses (T→R→S).
        // A bank "owns" the drag only when it consumed the click AND landed on a
        // real handle (dragAxis>=0); a click-relocate (dragAxis<0) does not start
        // a host drag. Rotate/Scale onMouseButtonDown return true even on a
        // relocate-miss, so gate on dragAxis, not the bool.
        //
        // NOTE the chain does NOT short-circuit on first-consumed (unlike the
        // wrapper): Rotate/Scale CONSUME a relocate-miss, so stopping there would
        // swallow the total-miss click before it can become a haul. On a total
        // miss all three banks' onMouseButtonDown run, so their click-side
        // effects (screen-falloff disc recenter, Move/Rotate ACEN click-relocate)
        // fire more than once — but all are IDEMPOTENT at the same click point
        // (same e.x,e.y → same projected ACEN, same disc center), so the observed
        // result is unchanged. Revisit if a bank's miss-handler ever gains
        // non-idempotent state; once a bank OWNS (dragAxis>=0) the `else if`
        // short-circuits and later banks never run.
        DragBank picked = DragBank.None;
        if (mv.onMouseButtonDown(e, vts) && mv.dragAxisPublic() >= 0) {
            picked = DragBank.Move;
        } else if (rt.onMouseButtonDown(e, vts)
                   && rt.dragAxisPublic() >= 0 && rt.dragAxisPublic() <= 2) {
            // Principal rings only (0/1/2 → X/Y/Z Euler component). The view-ring
            // (3) maps to no single rotateDeg component; defer it (the command's
            // rotateDeg has no arbitrary-axis slot). Leave it unowned.
            picked = DragBank.Rotate;
        } else if (sc.onMouseButtonDown(e, vts) && sc.dragAxisPublic() >= 0) {
            picked = DragBank.Scale;
        } else {
            // Total miss across every bank → HAUL via the Move bank's screen-plane
            // drag (world-axis Offset), anchored at the gizmo center.
            bool ctrl = (mods & KMOD_CTRL) != 0;
            mv.beginScreenPlaneDragAt(e.x, e.y, xfrm.moveGizmoCenter(),
                                      ctrl, /*notifyAcen=*/false, vts);
            picked = DragBank.Move;
        }

        // Begin the host-owned drag. Freeze the kernel-fed pivot for ALL banks
        // (§4.4): R/S conjugate about it; Offset is pivot-agnostic so it is inert
        // for a pure Move drag but harmless to freeze.
        dragBank       = picked;
        dragBaseOffset = offsetVec();
        frozenPivot    = xfrm.actionCenter(vts);
        accumLocal_    = Vec3(0, 0, 0);   // fresh basis-local accumulator per drag
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragBank == DragBank.None) return false;
        final switch (dragBank) {
            case DragBank.None: return false;   // unreachable (guarded above)
            case DragBank.Move:   return motionMove(e, vts);
            case DragBank.Rotate: return motionRotate(e, vts);
            case DragBank.Scale:  return motionScale(e, vts);
        }
    }

    private bool motionMove(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        MoveTool mv = xfrm.moveBank();
        bool consumed = mv.onMouseMotion(e, vts);   // writes pendingTranslateDelta
        if (!consumed) return true;
        // Drain the Move bank's basis-local scalar, project through the move
        // handler axes, accumulate, and fold into `offset` (ABSOLUTE delta since
        // drag start). Offset is world-axis → identical to the command path.
        Vec3 worldDelta = drainMoveWorldDelta();
        offsetX_ = dragBaseOffset.x + worldDelta.x;
        offsetY_ = dragBaseOffset.y + worldDelta.y;
        offsetZ_ = dragBaseOffset.z + worldDelta.z;
        rebuildPreview();
        return true;
    }

    private bool motionRotate(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        RotateTool rt = xfrm.rotateBank();
        bool consumed = rt.onMouseMotion(e, vts);   // publishes pendingRotate*
        if (!consumed) return true;
        // Drain the absolute accumulated ring angle (radians, since drag start).
        // Principal ring 0/1/2 → the matching rotateDeg X/Y/Z component. Like the
        // wrapper (xfrm_transform.d ~777): only the dragged axis is SET (absolute,
        // not accumulated) — the ring publishes its total angle every motion, and
        // the other two components stay at whatever the panel/numeric path holds.
        int   ax  = rt.pendingRotateAxis;
        float ang = rt.pendingRotateAngle;
        rt.pendingRotateAxis = -1;   // zero after draining (wrapper precedent)
        if (ax >= 0 && ax <= 2) {
            import std.math : PI;
            float deg = ang * 180.0f / cast(float)PI;
            // Single-axis-per-drag, matching the wrapper (xfrm_transform.d
            // ~777 zeroes the whole Euler then sets the dragged axis). Only the
            // sel-center INTERACTIVE single-axis rotation is reference-captured;
            // letting a prior axis (a numeric edit, or a previous ring drag in
            // this session) survive would silently feed the kernel the
            // multi-axis Rx→Ry→Rz regime about the sel-center pivot, which is
            // uncaptured. Zero the other two so every ring drag stays in the
            // validated single-axis law. (The command/numeric path keeps its
            // own multi-axis behaviour — that one is parity-tested at world
            // origin, rot_multiaxis.)
            rotateX_ = rotateY_ = rotateZ_ = 0.0f;
            if      (ax == 0) rotateX_ = deg;
            else if (ax == 1) rotateY_ = deg;
            else              rotateZ_ = deg;
            rebuildPreview();   // re-run about frozenPivot (livePivot())
        }
        return true;
    }

    private bool motionScale(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        ScaleTool sc = xfrm.scaleBank();
        bool consumed = sc.onMouseMotion(e, vts);   // publishes pendingScale*
        if (!consumed) return true;
        // Drain the absolute within-drag per-axis factor (since drag start). Every
        // scale gizmo mode (single-axis arrow, uniform disc, plane circle) reports
        // a full Vec3 of factors, so — mirroring the wrapper (xfrm_transform.d
        // ~828) — the host SETS `scale` to the published Vec3 (absolute, not
        // multiplied): the final `scale` param equals what the gizmo shows.
        if (sc.pendingScaleValid) {
            sc.pendingScaleValid = false;
            Vec3 f = sc.pendingScale;
            scaleX_ = f.x;
            scaleY_ = f.y;
            scaleZ_ = f.z;
            rebuildPreview();   // re-run about frozenPivot (livePivot())
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragBank == DragBank.None) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Forward LMB-up to the bank that owned the drag so it clears its dragAxis.
        final switch (dragBank) {
            case DragBank.None:   break;
            case DragBank.Move:   xfrm.moveBank().onMouseButtonUp(e, vts);   break;
            case DragBank.Rotate: xfrm.rotateBank().onMouseButtonUp(e, vts); break;
            case DragBank.Scale:  xfrm.scaleBank().onMouseButtonUp(e, vts);  break;
        }
        dragBank = DragBank.None;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
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

    // Pivot fed to the kernel for the live preview. During a drag (any bank) the
    // R/S factors conjugate about `frozenPivot` (the ACEN sel-center frozen at
    // drag-start); Offset is pivot-agnostic so a pure Move drag is unaffected.
    // Outside a drag (numeric param edits via the panel/onParamChanged) the pivot
    // is the world ORIGIN — matching the one-shot command path, which is the
    // distinction the off-origin pivot test pins.
    Vec3 livePivot() const {
        return (dragBank != DragBank.None) ? frozenPivot : Vec3(0, 0, 0);
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    // Category A live-edit cancel (RMB / undo-redo P0): drop any built topology,
    // restore the original cage, reset the drag state. Records nothing.
    void cancelLiveEdit() {
        before.restore(*mesh);
        refreshCaches();
        built       = false;
        dragBank    = DragBank.None;
        accumLocal_ = Vec3(0, 0, 0);
    }
}
