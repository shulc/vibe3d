module tools.create.box_source_cells;

import tools.create.box;
import display_state : DrawPlan;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_record_context : PreparedToolParamDoorClient;
import prepared_box_param : PreparedBoxParamOwner;
import prepared_tool_effect : PreparedBoxParamEffect, PreparedSessionActivateEffect,
    PreparedActivateKind, PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_private_state : PreparedPrivateStateOwner;
import mesh_gpu : GpuCreateOwner, GpuUploadOwner, GpuResourceOwner;
import mesh_gpu : GpuMesh;
import command_history : PreparedHistoryKind;
import document : Layer;
import snap_render : SnapOverlayOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import operator : VectorStack;
import bindbc.sdl;
import tool;
import mesh;
import math;
import spatial : Viewport;
import handler : MoveHandler, BoxHandler, getGizmoPixels, gizmoSize,
                 axisFacesViewer, ToolHandles;
import viewport_scheme : axisColor, schemeColor, SchemeColor;
import eventlog : queryMouse;
import drag;
import shader : Shader, LitShader;
import model_preview : ModelPreviewView;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.gesture_payload : GesturePayload;
import snapshot : MeshSnapshot;
import tools.create.create_common : WorkplaneFrame,
                              primitivePlacementFrame, screenToPlacementLocal,
                              planeLocalViewport,
                              viewPrincipalAxis,
                              transformPoint, transformDir, snapLocalHit,
                              frameIsLeftHanded, reverseFaceWinding,
                              workplaneCursorPlaneHit, moverDrag, snapMoverCentre, heightDragNormal, baseDragPoint;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : publishLastSnap, clearLastSnap;
import params : Param;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : abs, sqrt, sin, cos, PI;
import std.json : JSONValue;
public import mesh_ops.box_geom;

unittest {
    import record_observer_hub : RecordObserverHub;
    import mesh_gpu : GpuMesh;
    Layer layer = new Layer();
    GpuMesh sceneGpu;
    auto box = new BoxTool(() => &layer.meshRef(), &sceneGpu, LitShader.init);
    box.liveRunActive = true;
    box.liveUndoDepth = 3;
    box.paramBeforeValid = true;
    auto context = new PreparedRecordContext(null, new RecordObserverHub());
    assert(box.prepareDoorParamChanged("sizeX", context, layer, 7, 11));
    assert(box.paramBeforeValid,
           "Box parameter door installed private state during preparation");
    assert(context.validate()); context.install();
    assert(box.liveRunActive && box.liveUndoDepth == 3 && !box.paramBeforeValid,
           "Box parameter door omitted prepared private-state install");
    assert(context.installTraceForTest() == [72, 8]);
}
