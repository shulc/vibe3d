module tools.alignment.mirror_source_cells;

import tools.alignment.mirror;
import display_state : DrawPlan;
import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI;
import tool;
import tools.topology_step;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import spatial : ModelSpace, Viewport, screenPointToRay;
import params : Param, IntEnumEntry;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import editmode : EditMode;
import shader : Shader, LitShader;
import handler : MoveHandler, ToolHandles, BoxHandler, HandlePart, firstHitPart, gizmoSize, drawWorldSegments;
import drag : HandleDrag, DragFrame, DragKind, screenAxisDelta, gesturePrevPixel;
import eventlog : queryMouse;
import prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind,
    PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient;
import prepared_mirror_activation : PreparedMirrorActivationOwner,
    PreparedMirrorDeactivateOwner;
import document : Layer, primaryModelSpace;
import command_history : PreparedHistoryKind;
import display_sync : refreshDisplay;
version (unittest) import std.conv : to;

unittest {
    Mesh owned;
    auto tool = new MirrorTool(() => &owned, null, LitShader.init);
    tool.engaged = false; tool.havePreviewCache = true;
    auto prepared = tool.prepareParamState("axis");
    assert(!tool.engaged);
    assert(prepared.boolValue); // using the original false state instead REDs
    MirrorPreparedState handle;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    // A parameter write before the first press never engages.
    assert(!tool.engaged && tool.havePreviewCache);
    tool.engaged = true;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    // After it: still engaged, and the live copy is owed a rebuild.
    assert(tool.engaged && !tool.havePreviewCache);
}
