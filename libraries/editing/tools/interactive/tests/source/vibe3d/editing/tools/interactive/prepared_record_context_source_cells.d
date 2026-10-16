module vibe3d.editing.tools.interactive.prepared_record_context_source_cells;

import vibe3d.editing.tools.interactive.prepared_record_context;
import std.algorithm.mutation : move;
import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.commands.runtime.command_history : CommandHistory, PreparedHistoryKind,
                         PreparedHistoryResult, PreparedHistoryToken,
                         ValidatedPreparedHistoryToken;
import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.viewport.gpu.mesh_gpu : GpuResourceOwner, GpuUploadOwner, GpuCreateOwner,
                  GpuCreateUploadOwner;
import vibe3d.editing.tools.interactive.handler : ClickPointResourceOwner, BoxHandlerBatchResourceOwner;
import vibe3d.editing.tools.interactive.snap_render : SnapOverlayOwner;
import vibe3d.editing.tools.interactive.prepared_private_state : PreparedPrivateStateOwner, PreparedPrivateStateKind;
import vibe3d.editing.tools.interactive.prepared_selection_profile : PreparedSelectionProfileOwner;
import vibe3d.editing.tools.interactive.prepared_radial_sweep_transition : PreparedRadialSweepTransitionOwner;
import vibe3d.editing.tools.interactive.prepared_radial_array_transition : PreparedRadialArrayTransitionOwner;
import vibe3d.editing.tools.interactive.prepared_transform_activation : PreparedTransformActivationOwner;
import vibe3d.editing.tools.interactive.prepared_transform_product_activation : PreparedTransformProductActivationOwner;
import vibe3d.editing.tools.interactive.prepared_move_update : PreparedMoveUpdateOwner;
import vibe3d.editing.tools.interactive.prepared_rotate_update : PreparedRotateUpdateOwner;
import vibe3d.editing.tools.interactive.prepared_scale_update : PreparedScaleUpdateOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_update_tail : PreparedXfrmUpdateTailOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_update_edit_close : PreparedXfrmUpdateEditCloseOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_slot_poll : PreparedXfrmSlotPollOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_update_boundary : PreparedXfrmUpdateBoundaryOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_replay : PreparedXfrmReplayOwner;
import vibe3d.editing.tools.interactive.prepared_inherited_noop : PreparedInheritedNoopOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation : PreparedStrokeExtrudeActivationOwner;
import vibe3d.editing.tools.interactive.prepared_vertex_merge_activation : PreparedVertexMergeActivationOwner;
import vibe3d.editing.tools.interactive.prepared_poly_inset_activation : PreparedPolyInsetActivationOwner;
import vibe3d.editing.tools.interactive.prepared_poly_extrude_activation : PreparedPolyExtrudeActivationOwner;
import vibe3d.editing.tools.interactive.prepared_smooth_shift_activation : PreparedSmoothShiftActivationOwner;
import vibe3d.editing.tools.interactive.prepared_edge_bevel_activation : PreparedEdgeBevelActivationOwner;
import vibe3d.editing.tools.interactive.prepared_poly_bevel_activation : PreparedPolyBevelActivationOwner;
import vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation : PreparedVertexBevelActivationOwner;
import vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation : PreparedVertexExtrudeActivationOwner;
import vibe3d.editing.tools.interactive.prepared_edge_extrude_activation : PreparedEdgeExtrudeActivationOwner;
import vibe3d.editing.tools.interactive.prepared_edge_slice_activation : PreparedEdgeSliceActivationOwner;
import vibe3d.editing.tools.interactive.prepared_loop_slice_activation : PreparedLoopSliceActivationOwner;
import vibe3d.editing.tools.interactive.prepared_slice_activation : PreparedSliceActivationOwner;
import vibe3d.editing.tools.interactive.prepared_tack_activation : PreparedTackActivationOwner;
import vibe3d.editing.tools.interactive.prepared_command_wrapper_activation : PreparedCommandWrapperActivationOwner;
import vibe3d.editing.tools.interactive.prepared_bridge_activation : PreparedBridgeActivationOwner,
    PreparedBridgeDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_mirror_activation : PreparedMirrorActivationOwner,
    PreparedMirrorDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation : PreparedEdgeExtendToolActivationOwner;
import vibe3d.editing.tools.interactive.prepared_topology_pen_activation : PreparedTopologyPenActivationOwner;
import vibe3d.editing.tools.interactive.prepared_topology_pen_update : PreparedTopologyPenUpdateOwner;
import vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate : PreparedTopologyPenDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_slice_deactivate : PreparedSliceDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate : PreparedEdgeSliceDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate : PreparedLoopSliceDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate : PreparedEdgeExtendDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_pipe_activation : PreparedPipeActivationOwner;
import vibe3d.editing.pipeline.evaluation.toolpipe.attr_cache : NodeAttrs;
import vibe3d.editing.commands.runtime.tool_activation_ownership : PipeArmScope;
import vibe3d.editing.tools.interactive.prepared_box_param : PreparedBoxParamOwner;
import vibe3d.editing.tools.interactive.registry : PreparedPipeAttrs;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : Pipeline;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.documents.model.document : Layer;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.mesh.change.change_bus : PreparedDeliveryJournal, PreparedDeliverySpec, changeBus;
import vibe3d.mesh.change.change_bus : MeshEditScope;

unittest {
    import vibe3d.editing.commands.runtime.command : Command, CmdFlags;
    import vibe3d.mesh.core.mesh : Mesh;
    import vibe3d.viewport.camera.view : View;
    import vibe3d.editing.contracts.editmode : EditMode;
    final class C : Command {
        private Mesh mesh_;
        private View view_ = new View(0, 0, 1, 1);
        this() { super(&mesh_, view_, EditMode.Vertices); }
        override string name() const { return "prepared.context.test"; }
        override string label() const { return "prepared context"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }

    struct FakeParamResult { bool accepted; }
    final class FakeParamDoor : PreparedToolParamDoorClient {
        import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
        GpuMesh storage;
        GpuMesh* gpu;
        Layer expectedLayer;
        string seenName;
        bool sawOwner;
        this() { gpu = &storage; }
        FakeParamResult prepareParamChanged(string name,
                PreparedRecordContext, Layer layer, GpuUploadOwner upload) {
            seenName = name;
            sawOwner = upload !is null && upload.owns(gpu) &&
                layer is expectedLayer;
            return FakeParamResult(sawOwner);
        }
        mixin PreparedNamedGpuParamDoorClient;
    }
    auto fakeParamDoor = new FakeParamDoor();
    fakeParamDoor.expectedLayer = new Layer();
    assert(fakeParamDoor.prepareDoorParamChanged("segments", null,
            fakeParamDoor.expectedLayer, 7, 11));
    assert(fakeParamDoor.seenName == "segments" && fakeParamDoor.sawOwner,
           "prepared param door lost name, Layer, or GPU owner identity");

    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto context = new PreparedRecordContext(history, hub);
    auto result = context.prepare(new C(), PreparedHistoryKind.Plain);
    size_t models, ui;
    history.undoDepthCounts(models, ui);
    assert(result.accepted && models == 0 && hub.macroLength == 0);
    assert(context.validate());
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);

    // A validated History journal owns a validated history/observer image:
    // discard is deliberately inert and the one later install remains exact.
    auto retainedHistory = new CommandHistory();
    auto retainedHub = new RecordObserverHub(); retainedHub.setMacroActive(true);
    auto retained = new PreparedRecordContext(retainedHistory, retainedHub);
    assert(retained.prepare(new C(), PreparedHistoryKind.Plain).accepted &&
        retained.validate());
    retained.discard();
    retainedHistory.undoDepthCounts(models, ui);
    assert(models == 0 && ui == 0 && retainedHub.macroLength == 0);
    retained.install(); retained.install();
    retainedHistory.undoDepthCounts(models, ui);
    assert(models == 1 && ui == 0 && retainedHub.macroLength == 1);

    // A context without a history is a supported NoHistory journal. Every
    // history-facing operation fails closed without poisoning that journal.
    auto empty = new PreparedRecordContext(null, new RecordObserverHub());
    assert(!empty.prepare(new C(), PreparedHistoryKind.Plain).accepted);
    assert(!empty.consolidate(1).accepted && empty.nextRun() == 0);
    assert(!empty.markHistoryInstall() && empty.resourceCountForTest() == 0);
    assert(empty.markNoHistoryInstall() && empty.validate());
    empty.install();
    assert(empty.installTraceForTest() == [8]);
}
