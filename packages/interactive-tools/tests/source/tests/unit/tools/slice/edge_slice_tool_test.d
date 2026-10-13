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

// Slice M3: Edge Slice's gesture steps are its SESSION's (`sessionSteps`), not
// a tool-held peel; it no longer answers either tool-side capability.
unittest {
    assert((new EdgeSliceTool(null, null, null, null)).sessionPolicy().sessionSteps,
        "Edge Slice's policy lost the session-owned steps (slice M3)");
}
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
import command : Command, CmdFlags;
import view : View;
import mesh_edit_delta : MeshEditScope;

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

// Task 7114 (item 8): Shift+click's in-place apply reports whether it recorded
// by the IDENTITY of the top history entry, not the stack length — at the
// depth cap the length does not grow, and a length compare would answer
// "nothing committed" for a chain it just committed. The rig fills the
// history PAST the cap (60 records into a 50-deep stack), then applies an
// armed two-point chain.
private final class CapFillerCommand : Command {
    this(Mesh* m, View v) { super(m, v, EditMode.Edges); }
    override string name()  const { return "probe.cap_filler"; }
    override string label() const { return "Cap Filler"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect | CmdFlags.UndoForce; }
    protected override bool applyImpl()  { return true; }
    protected override void revertImpl() {}
}

unittest {
    Mesh m = makeCube();
    m.buildLoops();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    foreach (_; 0 .. 60) h.record(new CapFillerCommand(&m, v));
    assert(h.undoEntries().length == 50,
           "history cap floor: 60 records did not saturate a 50-deep stack");

    EditMode em = EditMode.Edges;
    auto t = new EdgeSliceTool(() => &m, null, &em, LitShader.init);
    t.setGestureBindings(h, () => cast(Command) new MeshSessionEdit(&m, v, EditMode.Edges,
        "mesh.edgeSliceTool", "Edge Slice", MeshEditScope.Geometry));
    t.activate();
    t.seedPreparedDeactivateForTest(m);   // arms a two-point chain, no GL refresh
    assert(t.hasUncommittedEdit() && m.vertices.length > 8,
           "history cap floor: the seeded chain is not armed and baked");

    const committed = t.commitUncommittedEdit();
    const ue = h.undoEntries();
    assert(ue.length == 50 && ue[$ - 1].cmd.label() == "Edge Slice" && !t.hasUncommittedEdit(),
           "history cap floor: the chain was not recorded as the top entry");
    assert(committed, "edge slice apply at the history cap reported nothing committed");
}

// Task 7114 (item 8), the other half of the same report: when the commit
// records NOTHING — here the mesh changed under the armed chain, so the
// identity guard drops it — the apply reports false and the top entry is the
// one that was there before.
unittest {
    Mesh m = makeCube();
    m.buildLoops();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    h.record(new CapFillerCommand(&m, v));
    const top0 = h.undoEntries()[$ - 1].cmd;

    EditMode em = EditMode.Edges;
    auto t = new EdgeSliceTool(() => &m, null, &em, LitShader.init);
    t.setGestureBindings(h, () => cast(Command) new MeshSessionEdit(&m, v, EditMode.Edges,
        "mesh.edgeSliceTool", "Edge Slice", MeshEditScope.Geometry));
    t.activate();
    t.seedPreparedDeactivateForTest(m);
    assert(t.hasUncommittedEdit(), "dropped chain floor: the seeded chain is not armed");
    m.addVertex(Vec3(9, 9, 9));          // the armed key no longer matches

    const committed = t.commitUncommittedEdit();
    assert(h.undoEntries().length == 1 && h.undoEntries()[$ - 1].cmd is top0,
           "dropped chain floor: a chain over a changed mesh was recorded");
    assert(!committed, "edge slice apply reported a commit it did not record");
}
