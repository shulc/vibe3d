module vibe3d.editing.tools.interactive.tools.edit.edge_extend_source_cells;

import vibe3d.editing.tools.interactive.tools.edit.edge_extend;
import vibe3d.viewport.display_policy.display_state : DrawPlan;
import bindbc.sdl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.mesh.ops.mesh_ops.extrude;
import vibe3d.util.math.math;
import vibe3d.util.spatial.spatial : ModelSpace, Viewport, screenPointToRay;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : Param;
import vibe3d.viewport.gpu.shader : Shader, LitShader;
import vibe3d.editing.commands.runtime.command_history : CommandHistory, PreparedHistoryKind;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.viewport.gpu.display_sync : refreshDisplay;
import vibe3d.editing.tools.state.tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts, PreparedPreviewRebuildImage;
import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform : XfrmTransformTool;
import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform : PreparedXfrmEmbeddedDeactivateImage;
import vibe3d.editing.tools.interactive.tools.transform.xfrm_handles : DragBank;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.editing.tools.interactive.tools.transform.move : MoveTool, PreparedMoveActivationImage;
import vibe3d.editing.tools.interactive.tools.transform.rotate : RotateTool, PreparedRotateActivationImage;
import vibe3d.editing.tools.interactive.tools.transform.scale : ScaleTool, PreparedScaleActivationImage;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedEdgeExtendParamEffect, PreparedEdgeExtendParamKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedXfrmUpdateEffect, PreparedXfrmUpdateKind;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolPoseDoorClient;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation : PreparedEdgeExtendToolActivationOwner;
import vibe3d.editing.tools.interactive.prepared_param_update : PreparedParamUpdateOwner, PreparedParamUpdateProducer;
import vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate : PreparedEdgeExtendDeactivateOwner;
import vibe3d.editing.tools.interactive.prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import vibe3d.documents.model.document : Layer;
import vibe3d.viewport.gpu.mesh_gpu : GpuUploadOwner;
import std.json : JSONValue;
import vibe3d.util.profiling.perf_probe : g_perf, Cat;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SymmetryPacket;

unittest {
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;

    auto layer = new Layer(); layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new EdgeExtendTool(
        () nothrow @nogc => &layer.meshRef(), &gpu, &mode, LitShader.init);
    tool.activate();
    VectorStack vts;
    auto context = new PreparedRecordContext(null, new RecordObserverHub());
    auto effect = tool.prepareUpdate(vts, context, layer, null);
    assert(effect.accepted && effect.kind == PreparedXfrmUpdateKind.Active &&
        context.validate());
    context.install();
    assert(context.installTraceForTest() == [8,60,62,61,16,59],
        "EdgeExtend embedded Xfrm tick installed out of legacy order");

    auto foreign = new Layer(); foreign.meshRef() = makeCube();
    auto refused = new PreparedRecordContext(null, new RecordObserverHub());
    assert(!tool.prepareUpdate(vts, refused, foreign, null).accepted &&
        !refused.validate(),
        "EdgeExtend update accepted a foreign Layer");
}
