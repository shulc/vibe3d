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
import display_sync : refreshDisplay;
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, undoTrackerEnabled;
import tools.transform.xfrm_transform : XfrmTransformTool;
import pipe_gizmo_host : PipeGizmoHost;
import tools.transform.move : MoveTool;
import tools.transform.rotate : RotateTool;
import tools.transform.scale : ScaleTool;

import std.json : JSONValue;
import perf_probe : g_perf, Cat;

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
// render + the arbiter highlights on hover.
//
// WHICH BANKS ARE DRAWN IS A PARAMETER, AND THE DEFAULT IS MOVE ALONE (task
// 1610). Five banks are offered there — move, rotate, scale, plane, local —
// each behind its own switch, and the tool-reset slot turns MOVE on and the
// other four off. That table is frozen in
// `tests/fixtures/edge_extend/handles_and_pivot.json`.
//
// We used to hard-wire T=R=S on, which drew two banks that are not drawn
// there. That is a live defect, not a cosmetic one: only the Move gesture was
// ever wired, so grabbing the rotate ring produced a TRANSLATE. The fix is
// this switch, not two missing drag handlers.
//
// `moveHandle_` / `rotateHandle_` / `scaleHandle_` are ordinary tool params
// (Tool Properties + headless `tool.attr`), pushed into the wrapper's
// flagT/flagR/flagS by syncBankFlags(). A bank that is off is not drawn, not
// registered with the shared arbiter, and not offered the click. The
// off-handle HAUL is deliberately NOT gated on them — it is a separate mode
// there too (global|local, default global = Offset), so the Move sub-tool is
// brought online even when its bank is hidden.
//
// The plane bank, the local bank and the local haul MODE are NOT implemented.
// They are default-off there as well, so they are gaps rather than
// divergences; the fixture records them so a later task starts from the
// measurement instead of from a fresh guess.
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


    CommandHistory        history;
    EdgeExtendEditFactory factory;

    // Embedded transform gizmo. WHICH of its banks render + hit-test is driven
    // by the bank params below through syncBankFlags(); the wrapper never owns
    // geometry here. Constructed in this().
    XfrmTransformTool xfrm;

    // Parameters — exposed via params() so both the Tool Properties panel and
    // the headless tool.attr path write into them. The defaults are the
    // captured tool-reset defaults: shift=0, offset=0, rotate=0, scale=1,
    // segments=1 and **inset=0** (task 1610 — ours was 0.1).
    //
    // The one-shot `mesh.edge_extend` COMMAND keeps its own inset=0.1 default.
    // That is our own convenience surface rather than a port of the tool's
    // reset slot, and the two are pinned by separate tests; the fixture's
    // `parameter_defaults` block is about the tool.
    float inset_   = 0.0f;
    float shift_   = 0.0f;
    float offsetX_ = 0.0f, offsetY_ = 0.0f, offsetZ_ = 0.0f;
    float rotateX_ = 0.0f, rotateY_ = 0.0f, rotateZ_ = 0.0f;
    float scaleX_  = 1.0f, scaleY_  = 1.0f, scaleZ_  = 1.0f;
    int   segments_ = 1;

    // Handle banks (task 1610) — independently switchable, MOVE alone on by
    // default. See the header note for why this is a switch and not two
    // missing drag handlers.
    bool  moveHandle_   = true;
    bool  rotateHandle_ = false;
    bool  scaleHandle_  = false;

    // Interactive session state.
    bool         active;           // between activate() and deactivate()
    bool         built;            // true once the kernel built ridge topology
    MeshSnapshot before;           // captured at activate() (geometry + selection)
    // The restore-and-rebuild seam (task 1620). Owns the split between a
    // topology-changing rebuild and a position-only one; see
    // tools/edit/preview_rebuild.d for what the key must contain and why.
    PreviewRebuild preview_;
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

    // The R/S pivot: the MID of the BOUNDING BOX of the SELECTED vertices,
    // captured once at tool INITIALISATION (reinitSession) and recomputed at
    // no later point — not at drag start, not per evaluation. Task 1610; the
    // law was read at its own compute site and is frozen in
    // `tests/fixtures/edge_extend/handles_and_pivot.json`.
    //
    // TWO things this is NOT, both of which this field used to be:
    //
    //  * NOT THE ACTION CENTRE. The action centre plays no part: the compute
    //    slot never asks for it, and forcing it to the world origin leaves the
    //    pivot bit-identical (`action_centre_control` in the fixture, and a
    //    cell of tests/test_fixture_edge_extend_handles_pivot.d). We used to
    //    read `xfrm.actionCenter(vts)` here, so an ACEN mode switch silently
    //    moved the extend's pivot.
    //  * NOT A CENTROID. It is (min + max) * 0.5 over the operand vertices,
    //    which on an asymmetric selection is nowhere near their mean — 0.57
    //    apart on the fixture's rig, and every ring vertex 0.30 out. A cube
    //    edge cannot tell the two apart, which is exactly how an earlier
    //    campaign came to write this pivot down as "the selection centroid".
    //
    // `Mesh.selectionBBoxCenterEdges()` already IS that quantity (it is also
    // what the action centre's Select MODE computes), so it is reused rather
    // than re-implemented: same point, arrived at independently of the stage,
    // which is the whole content of the finding above.
    Vec3 initPivot_ = Vec3(0, 0, 0);

    // Test-only override for the headless apply pivot. Backed by the HIDDEN
    // `_dragPivot` param (set via tool.attr): writing it arms `.active`; the next
    // applyHeadless consumes it (one-shot). Lets a test pin the INTERACTIVE
    // pivot (initPivot_) on the headless path without a synthesized viewport
    // drag. `.value` IS the param's storage so injectParamsInto writes it directly.
    struct PivotOverride { bool active; Vec3 value = Vec3(0, 0, 0); }
    PivotOverride dragPivotOverride_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        // The embedded wrapper reuses the same mesh/gpu/editMode pointers. The
        // bank switches land immediately, so a tool that is constructed and
        // never activated already reports the right set.
        xfrm = new XfrmTransformTool(meshSrc, gpu, editMode);
        syncBankFlags();
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
            Param.float_("inset",   "Local Inset", &inset_,   0.0f),
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
            // Handle banks — move ON, rotate/scale OFF (task 1610). Flipping
            // one goes straight through onParamChanged → syncBankFlags(), so
            // the panel checkbox and `tool.attr edge.extend rotateHandle true`
            // are the same write.
            Param.bool_ ("moveHandle",   "Move Handle",   &moveHandle_,   true),
            Param.bool_ ("rotateHandle", "Rotate Handle", &rotateHandle_, false),
            Param.bool_ ("scaleHandle",  "Scale Handle",  &scaleHandle_,  false),
            // HIDDEN test-automation hook: the interactive R/S pivot (the
            // bbox mid an armed tool holds in initPivot_). Setting it via
            // tool.attr arms a one-shot override consumed by the next
            // applyHeadless (see dragPivotOverride_ / onParamChanged), which
            // lets a test drive the kernel about a pivot it read back from
            // /api/tool/state without synthesising a viewport drag. Not shown
            // in the panel.
            Param.vec3_ ("_dragPivot", "Drag Pivot (test)",
                         &dragPivotOverride_.value, Vec3(0, 0, 0)).hidden(),
        ];
    }

    override void activate() {
        active = true;
        // Bank flags BEFORE xfrm.activate(): the wrapper activates only the
        // sub-tools its flags enable, so a bank that was switched on while the
        // tool was down has to be visible to that call.
        syncBankFlags();
        // Bring the embedded gizmo online (its sub-tools' activate + wrapperRef
        // wiring). The wrapper never owns geometry here, but it needs to be
        // active so its banks render + hit-test.
        xfrm.activate();
        // The Move sub-tool is ALSO the off-handle haul engine (see the header
        // note), and the haul is not gated on the move BANK — so bring it
        // online even when that bank is hidden, which xfrm.activate() did not.
        if (!moveHandle_) xfrm.moveBank().activate();
        reinitSession();
    }

    // Push the bank switches into the embedded wrapper. flagT/flagR/flagS gate
    // registration with the shared arbiter, the per-frame hit-geometry refresh
    // and each bank's draw (xfrm_handles.d / xfrm_transform.d), so this one
    // assignment is the whole "is the bank there" seam. The CLICK is gated
    // separately in onMouseButtonDown, because this host drives the sub-tools
    // directly rather than through the arbiter.
    private void syncBankFlags() {
        xfrm.flagT = moveHandle_;
        xfrm.flagR = rotateHandle_;
        xfrm.flagS = scaleHandle_;
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
        preview_.reset();          // a new clean cage ⇒ a new topology key
        before   = MeshSnapshot.capture(*mesh);
        // THE MOMENT the R/S pivot is captured (task 1610) — tool
        // initialisation, and nowhere else. It is not recomputed at drag
        // start and not per evaluation, so a gesture cannot chase its own
        // output (the failure mode task 1530 measured on the action centre)
        // and a mid-session selection change cannot move it either.
        //
        // reinitSession() is the shared init of activate() and
        // resyncSession(); both run against the CLEAN cage (resyncSession is
        // only reached after history navigation restored it), so both see the
        // same operand set and the same box.
        //
        // Layer space: the kernel conjugates against raw mesh vertices, so the
        // pivot is wanted in the layer's own coordinates — which is what the
        // default (identity) ModelSpace argument gives. The removed
        // action-centre read needed `primaryModelSpace().toLocalPoint` here
        // precisely because ACEN publishes in WORLD (task 0649).
        //
        // EMPTY-SELECTION FOOTNOTE, stated because the two fallbacks differ.
        // selectionBBoxCenterEdges falls back to EVERY edge when nothing is
        // selected; currentMask() (operandEdgeMask) falls back to every VISIBLE
        // edge, and the kernel drops hidden edges again on top of that. So on a
        // mesh with hidden geometry AND no selection, the pivot spans a little
        // more than the kernel extends. Left alone deliberately: the captured
        // law is about the selection, and forking a second implementation of
        // "mid of the box" to cover it would cost more than the case is worth.
        initPivot_ = mesh.selectionBBoxCenterEdges();
    }

    override void deactivate() {
        // Commit one undo step iff the kernel actually built topology.
        if (active && built)
            commitEdit();
        xfrm.deactivate();
        active   = false;
        built    = false;
        dragBank = DragBank.None;
        preview_.reset();          // drop the clean-cage scratch with the session
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
        // Bank switches: push the flags and, when the tool is already armed,
        // bring a newly-enabled sub-tool online (xfrm.activate() only
        // activates the banks its flags had at the time). Deliberately does
        // NOT rebuild the preview — a bank switch is not a geometry param, and
        // rebuilding would re-run the kernel for a purely visual change.
        // TransformTool.activate() is `active = true; resetTransientState()`,
        // which touches only drag-invariant cache/gizmo bookkeeping, so
        // calling it on an already-active bank between drags is inert.
        if (name == "moveHandle" || name == "rotateHandle" || name == "scaleHandle") {
            syncBankFlags();
            if (active) {
                xfrm.moveBank().activate();     // also the haul engine
                if (rotateHandle_) xfrm.rotateBank().activate();
                if (scaleHandle_)  xfrm.scaleBank().activate();
            }
            return;
        }
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

    /// Test/diagnostic seam (task 1620): how the preview-rebuild seam split
    /// this session's rebuilds. `fullRebuilds` are the restore-and-rebuild
    /// frames (a real topology change, and the ones that legitimately cost a
    /// subpatch dispatch), `placements` the position-only ones, `keyMisses`
    /// the frames where the declared topology key claimed "unchanged" and the
    /// produced topology disagreed. A correct key never misses — see
    /// tools/edit/preview_rebuild.d.
    public PreviewRebuildCounts previewRebuildCounts() const {
        return preview_.counts();
    }

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
        // Bank switches + the init-frozen R/S pivot (task 1610). The pivot is
        // read-only state, not a param, and exposing it is what lets a test
        // pin the POINT and the MOMENT separately: it is already populated
        // when the tool is armed, before any drag or param write.
        root["moveHandle"]   = JSONValue(moveHandle_);
        root["rotateHandle"] = JSONValue(rotateHandle_);
        root["scaleHandle"]  = JSONValue(scaleHandle_);
        root["pivot"] = JSONValue([JSONValue(initPivot_.x),
                                   JSONValue(initPivot_.y),
                                   JSONValue(initPivot_.z)]);
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
        // This path rebuilds the live mesh behind the seam's back, so the
        // key it remembers no longer describes what is standing.
        preview_.reset();
        if (mesh.edges.length == 0) return false;
        auto mask = currentMask();
        // Headless pivot policy — the world ORIGIN, and that is REFERENCE-
        // FAITHFUL rather than a convenience. The non-interactive command path
        // never initialises a pivot there either, so it rotates about the world
        // origin; the fixture carries that as its own case
        // (`command_path_rotate_pivot`, the CONTROL for the interactive one:
        // same tool, same params, same rig, pivot field simply never
        // populated). It also keeps this path byte-identical to the one-shot
        // mesh.edge_extend command, which the 4a command-parity test pins.
        //
        // The bbox-mid pivot is an INTERACTIVE property (initPivot_, captured
        // at tool init, fed to the kernel through livePivot()). The HIDDEN
        // test-automation param `_dragPivot` overrides this path's pivot for
        // ONE apply, so a test can drive the kernel about a pivot it read back
        // from the armed tool without synthesising a viewport drag.
        Vec3 pivot = dragPivotOverride_.active
                   ? dragPivotOverride_.value : Vec3(0, 0, 0);
        dragPivotOverride_.active = false;   // one-shot: never leak into a later apply
        // task 1903 Stage H: extendEdgesByMask takes `ref MeshEditBatch` now.
        // `ToolDoApplyCommand` wraps this whole call with a MeshSnapshot, so
        // this batch is unrecorded.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extendEdgesByMask(mask, inset_, shift_,
                                        offsetVec(), rotateVec(), scaleVec(),
                                        segments_, pivot);
        ed.close();
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
    // On a total miss, the Move bank begins a HAUL (screen-plane Offset drag).
    //   - Move   → Offset (world-axis, pivot-agnostic; haul + on-arrow share it).
    //   - Rotate → rotateDeg component (principal ring axis → X/Y/Z), about the
    //              init-frozen bbox-mid pivot.
    //   - Scale  → scale component (handle axis → X/Y/Z), about the same pivot.
    // R/S are absolute-since-drag-start (the sub-tools publish the accumulated
    // factor/angle), so the host SETS the component (not +=); Move accumulates a
    // world delta.
    //
    // A SWITCHED-OFF BANK IS NOT OFFERED THE CLICK (task 1610). Its flag has
    // already kept it out of the arbiter and off the screen, but this host
    // drives the sub-tools DIRECTLY, so an ungated call here would let an
    // invisible bank hit-test — and, worse, run its click-side effects. The
    // haul is deliberately NOT gated: it is a mode of its own, not part of the
    // move bank (see the header note).
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
        // miss every ENABLED bank's onMouseButtonDown runs, so their click-side
        // effects (screen-falloff disc recenter, Move/Rotate ACEN click-relocate)
        // fire more than once — but all are IDEMPOTENT at the same click point
        // (same e.x,e.y → same projected ACEN, same disc center), so the observed
        // result is unchanged. Revisit if a bank's miss-handler ever gains
        // non-idempotent state; once a bank OWNS (dragAxis>=0) the `else if`
        // short-circuits and later banks never run.
        //
        // With the default bank set (move only) this is now ONE call rather
        // than three, so the multiple-fire caveat above applies to strictly
        // fewer clicks than it used to — a switched-off bank is never asked.
        DragBank picked = DragBank.None;
        if (moveHandle_ && mv.onMouseButtonDown(e, vts) && mv.dragAxisPublic() >= 0) {
            picked = DragBank.Move;
        } else if (rotateHandle_ && rt.onMouseButtonDown(e, vts)
                   && rt.dragAxisPublic() >= 0 && rt.dragAxisPublic() <= 2) {
            // Principal rings only (0/1/2 → X/Y/Z Euler component). The view-ring
            // (3) maps to no single rotateDeg component; defer it (the command's
            // rotateDeg has no arbitrary-axis slot). Leave it unowned.
            picked = DragBank.Rotate;
        } else if (scaleHandle_ && sc.onMouseButtonDown(e, vts) && sc.dragAxisPublic() >= 0) {
            picked = DragBank.Scale;
        } else {
            // Total miss across every ENABLED bank (or none enabled) → HAUL via
            // the Move bank's screen-plane drag (world-axis Offset), anchored at
            // the gizmo center.
            bool ctrl = (mods & KMOD_CTRL) != 0;
            mv.beginScreenPlaneDragAt(e.x, e.y, xfrm.moveGizmoCenter(),
                                      ctrl, /*notifyAcen=*/false, vts);
            picked = DragBank.Move;
        }

        // Begin the host-owned drag. NOTHING about the pivot happens here: it
        // was captured at tool init (initPivot_) and a drag does not re-take
        // it. This line used to read the ACTION CENTRE at drag start, and both
        // halves of that were wrong — see initPivot_'s comment.
        dragBank       = picked;
        dragBaseOffset = offsetVec();
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
            rebuildPreview();   // re-run about initPivot_ (livePivot())
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
            rebuildPreview();   // re-run about initPivot_ (livePivot())
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

    // Pivot fed to the kernel for every INTERACTIVE evaluation — a bank drag
    // and a numeric Tool Properties edit alike. Both are "the tool is armed in
    // a viewport", which is the state whose pivot the fixture's first case
    // measures; the drag is not a separate regime (task 1610). Offset and
    // inset/shift are pivot-agnostic, so a pure Move drag is unaffected either
    // way.
    //
    // Inactive ⇒ the world origin, which is the non-interactive command path
    // (applyHeadless has its own copy of that policy, with the fixture's
    // control case cited).
    Vec3 livePivot() const {
        return active ? initPivot_ : Vec3(0, 0, 0);
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
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandEdgeMask();
    }

    // Revert to the pre-extend cage + selection, then re-run the kernel from the
    // current params. This is the per-tick re-evaluate (§4.2): WRITE params +
    // RE-RUN, never vertex-transform the post-extend ridge.
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        // TOPOLOGY KEY (task 1620): the operand mask and `segments`, and
        // nothing else. Those two decide how many ring vertices and how many
        // bridge quads `extendEdgesByMask` creates; inset / shift / offset /
        // rotate / scale / pivot only decide WHERE the created vertices sit
        // (the kernel's own per-ring formula is
        // `pivot + RS(E_src - pivot) + insetShiftDelta + (k/N)*offset`, with
        // the created SET fixed by `exEdges` x `segments`).
        //
        // NO DEGENERATE TERM, and that is a reading of the kernel rather than
        // an omission: extend's only early return is `exEdges.length == 0`,
        // which is a function of the mask alone. `segments < 1` is clamped to
        // 1 rather than refusing. So no position parameter of this tool can
        // make geometry appear or disappear — unlike both bevels, whose zero
        // crossing IS a topology change and is keyed as one.
        // task 1903 Stage H: the batch opens INSIDE the kernel lambda, not in
        // `preview_rebuild.d`'s own delegate signature (plan §9.1's decision,
        // taken at F2 and repeated at G — H is the last family on this shared
        // seam and inherits it unchanged): `target` is `cage_` on the
        // placement path and the live mesh on the key-changed path, so
        // opening `unrecorded` on `target` lands on whichever mesh the kernel
        // actually got, with no edit to preview_rebuild.d.
        size_t n = preview_.run(*mesh, before,
            (ref Mesh cage) => PreviewTopologyKey.make(cage.operandEdgeMask(),
                                                       false, segments_),
            (ref Mesh target) {
                auto ed = MeshEditBatch.unrecorded(target, kExtrudeEditScope);
                immutable r = ed.extendEdgesByMask(
                                 target.operandEdgeMask(), inset_, shift_,
                                 offsetVec(), rotateVec(), scaleVec(),
                                 segments_, livePivot());
                ed.close();
                return r;
            });
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

            // task 1903 Stage H: the RECORDING `MeshEditBatch` struct replaces
            // the legacy `beginEditBatch(&rec, …)` / `endEditBatch()` /
            // `abortEditBatch()` trio — see edge_extrude.d's twin comment.
            // This file drops out of the legacy-spelling roster in
            // `commit_seam_census_test.d` (2 left: `delete.d`, `remove.d`).
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Geometry | MeshEditScope.Marks);
            auto mask = currentMask();
            ed.extendEdgesByMask(mask, inset_, shift_,
                                 offsetVec(), rotateVec(), scaleVec(),
                                 segments_, livePivot());
            auto delta = ed.close();

            preview_.reset();      // the live mesh was rebuilt outside the seam
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
        refreshDisplay(mesh, gpu);
    }

    // Category A live-edit cancel (RMB / undo-redo P0): drop any built topology,
    // restore the original cage, reset the drag state. Records nothing.
    void cancelLiveEdit() {
        before.restore(*mesh);
        preview_.reset();
        refreshCaches();
        built       = false;
        dragBank    = DragBank.None;
        accumLocal_ = Vec3(0, 0, 0);
    }
}
