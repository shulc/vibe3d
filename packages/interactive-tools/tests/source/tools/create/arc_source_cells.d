module tools.create.arc_source_cells;

import tools.create.arc;
import display_state : DrawPlan;
import operator : VectorStack;
import bindbc.sdl;
import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import spatial : Viewport;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.create.create_common : primitivePlacementFrame, WorkplaneFrame, transformPoint;
import editmode : EditMode;
import prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_private_state : PreparedPrivateStateOwner;
import document : Layer;
import std.math : sin, cos, PI;

unittest {
    Mesh owned;
    auto tool = new ArcTool(() => &owned, null, LitShader.init);
    tool.state = ArcState.Drawing;
    auto prepared = tool.prepareIdleState();
    assert(tool.state == ArcState.Drawing); // producer reads no live-after-write state
    assert(prepared.intValue == cast(int) ArcState.Idle); // original-state mutation RED
    ArcPreparedState handle;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    assert(tool.state == ArcState.Idle); // installed state == legacy assignment
    tool.state = ArcState.Drawing;
    tool.installLegacyPreparedState(handle);
    assert(tool.state == ArcState.Drawing); // consumed handle cannot replay
}
