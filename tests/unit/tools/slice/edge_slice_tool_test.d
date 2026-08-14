// Module unittests for `tools.slice.edge_slice_tool`, moved verbatim out of source/tools/slice/edge_slice_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.slice.edge_slice_tool_test;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : round;
import ImGui = d_imgui;
import d_imgui.imgui_h;   // ImDrawList / ImVec2 / IM_COL32 for the `t = %` HUD
import operator : VectorStack;
import tool;
import edit_session : KeepAliveOnCancel, SessionStepUndo;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import hover_state : g_hoveredEdge;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment;
import viewport_scheme : schemeColor, SchemeColor;
import document : primaryModelSpace;
import overlay_space : OverlaySpace;
import tools.slice.edge_slice_tool;

unittest {
    assert(edgeSliceHudLabel(0.25f) == "25.00 %");
    assert(edgeSliceHudLabel(0.5f)  == "50.00 %");
    assert(edgeSliceHudLabel(0.0f)  == "0.00 %");
    assert(edgeSliceHudLabel(1.0f)  == "100.00 %");
}
