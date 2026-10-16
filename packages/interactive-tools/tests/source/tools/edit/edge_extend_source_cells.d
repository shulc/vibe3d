module tools.edit.edge_extend_source_cells;

import tools.edit.edge_extend;
import display_state : DrawPlan;
import bindbc.sdl;
import operator : VectorStack;
import tool;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.extrude;
import math;
import vibe3d.util.spatial.spatial : ModelSpace, Viewport, screenPointToRay;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory, PreparedHistoryKind;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts, PreparedPreviewRebuildImage;
import tools.transform.xfrm_transform : XfrmTransformTool;
import tools.transform.xfrm_transform : PreparedXfrmEmbeddedDeactivateImage;
import tools.transform.xfrm_handles : DragBank;
import pipe_gizmo_host : PipeGizmoHost;
import tools.transform.move : MoveTool, PreparedMoveActivationImage;
import tools.transform.rotate : RotateTool, PreparedRotateActivationImage;
import tools.transform.scale : ScaleTool, PreparedScaleActivationImage;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedEdgeExtendParamEffect, PreparedEdgeExtendParamKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedXfrmUpdateEffect, PreparedXfrmUpdateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolPoseDoorClient;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import prepared_edge_extend_tool_activation : PreparedEdgeExtendToolActivationOwner;
import prepared_param_update : PreparedParamUpdateOwner, PreparedParamUpdateProducer;
import prepared_edge_extend_deactivate : PreparedEdgeExtendDeactivateOwner;
import prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import std.json : JSONValue;
import vibe3d.util.profiling.perf_probe : g_perf, Cat;
import toolpipe.packets : SymmetryPacket;

unittest {
    import record_observer_hub : RecordObserverHub;

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
