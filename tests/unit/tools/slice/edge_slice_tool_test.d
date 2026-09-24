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
import hover_state : g_hoveredEdge, g_hoverIndexSpaceStale;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
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

// Task 7114 (item 22, hypothesis (e)): a hover HELD over a stale subpatch
// preview index space names an edge of the mesh before the last bake. The
// click is absorbed and latches nothing. Two fresh tools, the same press and
// the same hovered edge; only the flag differs. The control latches first,
// so the needle below it cannot pass by the press never reaching the latch.
// The flag's production writers are pinned by
// tests/unit/hover_stale_writer_census_test.d (this cell sets it itself).
unittest {
    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);
    Mesh m = makeCube();
    EditMode em = EditMode.Edges;
    VectorStack vts;
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_LEFT;
    scope(exit) { g_hoveredEdge = -1; g_hoverIndexSpaceStale = false; }
    g_hoveredEdge = 0;

    g_hoverIndexSpaceStale = false;
    auto control = new EdgeSliceTool(() => &m, null, &em, LitShader.init);
    control.activate();
    assert(control.onMouseButtonDown(e, vts)
           && control.toolStateJson()["latchedPairs"].array.length == 1,
           "stale hover control: a fresh press on a current hover did not latch");

    g_hoverIndexSpaceStale = true;
    auto held = new EdgeSliceTool(() => &m, null, &em, LitShader.init);
    held.activate();
    assert(held.onMouseButtonDown(e, vts), "stale hover: the press was not absorbed");
    assert(held.toolStateJson()["latchedPairs"].array.length == 0,
           "edge slice latched a point from a stale hover index space");
}
