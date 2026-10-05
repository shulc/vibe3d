// Task 9444 (OVL3): the published snap is drawn once per cell by the frame,
// in the captured look (findings_O, task 9425: O1 idle rollover square in
// `preHighlight`; O1d drag cross, `handleUnsnap` before the snap, `handle`
// once snapped). Compiler pins on the tools' composition, the marks drawn
// into a headless ImGui foreground list, then a census of the production text.
module tests.unit.snap_overlay_test;

import std.algorithm : canFind, filter, map, sort;
import std.array     : array;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.math      : abs;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import ImGui = d_imgui;
import d_imgui.imgui_h : ImVec2;

import held_gesture_buttons : g_heldGestureButtons;
import math        : Vec3, Viewport, projectToWindowFull;
import mesh        : Mesh;
import snap        : SnapResult;
import snap_render : SnapMark, snapMarkOf, snapMarkColor, drawSnapOverlay, g_lastSnap;
import toolpipe.packets : SnapType;
import view        : View;
import viewport_scheme : SchemeColor;
import handles.shapes  : packImCol;
import viewport_scheme : schemeColor;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent;
import tests.unit.ui.headless_panel : openPanel;

import tools.transform.transform : TransformTool;
import tools.create.box : BoxTool;
import tools.create.primitive_create_tool : PrimitiveCreateTool;
import tools.create.vertex_place : VertexTool;
import tools.create.pen : PenTool;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---- the fence: no tool keeps a snap of its own (pen waits for its slice) --
static assert([__traits(allMembers, SnapMark)] == ["none", "rollover", "unsnapped", "snapped"]);
private enum bool keepsSnap(T) = [__traits(allMembers, T)].canFind("lastSnap")
                              || [__traits(allMembers, T)].canFind("lastSnap_");
static assert(!keepsSnap!TransformTool && !keepsSnap!BoxTool
           && !keepsSnap!PrimitiveCreateTool && !keepsSnap!VertexTool,
    "a tool regrew its own snap copy: publish through publishLastSnap instead");
static assert(keepsSnap!PenTool, "pen dropped its field: drop it from this pin too");

unittest // the mark law and its colours (O1, O1d)
{
    scope (exit) g_heldGestureButtons.clear();
    SnapResult r;
    assert(snapMarkOf(r) == SnapMark.none, "an unhighlighted snap must draw nothing");
    r.highlighted = true;
    assert(snapMarkOf(r) == SnapMark.rollover, "idle hover: the rollover mark");
    r.snapped = true;
    assert(snapMarkOf(r) == SnapMark.rollover, "idle hover stays the rollover mark when snapped");
    g_heldGestureButtons.press(1);
    assert(snapMarkOf(r) == SnapMark.snapped, "held gesture, snapped: the handle cross");
    r.snapped = false;
    assert(snapMarkOf(r) == SnapMark.unsnapped, "held gesture, not snapped: the unsnap cross");
    // The packed colours are the captured pixel reads.
    import d_imgui.imgui_h : IM_COL32;
    assert(packImCol(schemeColor(snapMarkColor(SnapMark.rollover)), 255) == IM_COL32(140, 181, 199, 255));
    assert(packImCol(schemeColor(snapMarkColor(SnapMark.unsnapped)), 255) == IM_COL32(230, 179, 255, 255));
    assert(packImCol(schemeColor(snapMarkColor(SnapMark.snapped)), 255) == IM_COL32(102, 255, 255, 255));
}

// ---- the draw, read back from a headless foreground list -------------------
private struct VecView(T) { int size, capacity; T* data; }
private struct Vert { float x, y, u, v; uint col; }
private struct DrawListHead { VecView!void cmd; VecView!void idx; VecView!Vert vtx; }

/// The foreground vertices `drawSnapOverlay` adds for `r`, behind a positive
/// control: a known rect read back first proves the list view.
private Vert[] drawn(const ref SnapResult r, const ref Viewport vp, const ref Mesh m) {
    Vert[] got;
    auto ui = openPanel(() {
        auto dl = cast(DrawListHead*) ImGui.GetForegroundDrawList();
        immutable int base = dl.vtx.size;
        ImGui.GetForegroundDrawList().AddRectFilled(ImVec2(1, 2), ImVec2(5, 7), 0xFF123456);
        assert(dl.vtx.size == base + 4 && dl.vtx.data[base].col == 0xFF123456
               && dl.vtx.data[base].x == 1 && dl.vtx.data[base + 2].y == 7,
               "ImDrawList layout moved: the control rect does not read back");
        immutable int from = dl.vtx.size;
        drawSnapOverlay(r, vp, m);
        got = dl.vtx.data[from .. dl.vtx.size].dup;
    }, "snap overlay");
    scope (exit) ui.close();
    ui.frame();
    return got;
}

unittest // what the frame's draw puts on screen
{
    scope (exit) g_heldGestureButtons.clear();
    auto vp = new View(0, 0, 400, 300).viewport();
    Mesh m;
    m.addVertex(Vec3(0.3f, 0.2f, 0.1f));
    float px, py, ndcZ;
    assert(projectToWindowFull(m.vertices[0], vp, px, py, ndcZ), "fixture vertex off screen");

    SnapResult r;
    r.highlighted = r.snapped = true;
    r.targetType = SnapType.Vertex; r.targetIndex = 0;
    r.worldPos = r.highlightPos = m.vertices[0];
    // The cross centre sits away from the vertex so the two marks cannot alias.
    r.worldPos = Vec3(-0.4f, 0.1f, 0.0f);
    float cx, cy;
    assert(projectToWindowFull(r.worldPos, vp, cx, cy, ndcZ));
    assert(abs(cx - px) + abs(cy - py) > 20, "vacuous fixture: the marks coincide");

    // Idle: one 6x6 px square on the vertex, pre-highlight, nothing else.
    auto idle = drawn(r, vp, m);
    immutable uint roll = packImCol(schemeColor(SchemeColor.preHighlight), 255);
    assert(idle.length == 4, format("idle draws one square: %s vertices", idle.length));
    foreach (v; idle)
        assert(v.col == roll && abs(abs(v.x - px) - 3) < 1e-3 && abs(abs(v.y - py) - 3) < 1e-3,
            format("idle square corner (%s,%s) col %08x, vertex at (%s,%s)", v.x, v.y, v.col, px, py));

    // Held: a gapped cross at worldPos, no square; colour by snapped.
    void checkCross(SchemeColor role, string what) {
        auto cross = drawn(r, vp, m);
        immutable uint col = packImCol(schemeColor(role), 255);
        auto solid = cross.filter!(v => v.col == col).array;
        assert(solid.length >= 16, format("%s: %s solid vertices", what, solid.length));
        foreach (v; cross) {
            immutable float dx = abs(v.x - cx), dy = abs(v.y - cy);
            assert((v.col & 0x00FFFFFF) == (col & 0x00FFFFFF), what ~ ": a vertex of another colour");
            assert(dx < 9.5f && dy < 9.5f && (dx > 3f || dy > 3f),
                format("%s: vertex (%s,%s) outside the gapped cross at (%s,%s)", what, v.x, v.y, cx, cy));
        }
    }
    g_heldGestureButtons.press(1);
    checkCross(SchemeColor.handle, "snapped");
    r.snapped = false;
    checkCross(SchemeColor.handleUnsnap, "unsnapped");

    r.highlighted = false;
    assert(drawn(r, vp, m).length == 0, "an unhighlighted snap drew something");

    // Idle edge and polygon targets: the rollover colour (uncaptured shapes:
    // a 2 px line, a solid fill). Measured: the line is 4 opaque vertices; the
    // fill is 4 opaque corners plus a 4-vertex transparent fringe (a closed
    // outline would be 8 opaque).
    g_heldGestureButtons.clear();
    Mesh q;
    foreach (p; [Vec3(-0.5f, -0.4f, 0), Vec3(0.5f, -0.4f, 0), Vec3(0.5f, 0.4f, 0), Vec3(-0.5f, 0.4f, 0)])
        q.addVertex(p);
    q.addFace([0u, 1u, 2u, 3u]);
    r = SnapResult.init;
    r.highlighted = true;
    foreach (t; [SnapType.Edge, SnapType.Polygon]) {
        r.targetType = t; r.targetIndex = 0;
        auto got = drawn(r, vp, q);
        immutable size_t opaque = got.filter!(v => v.col == roll).array.length;
        assert(got.length == (t == SnapType.Edge ? 4 : 8) && opaque == 4,
            format("%s: %s vertices, %s opaque", t, got.length, opaque));
        foreach (v; got)
            assert((v.col & 0x00FFFFFF) == (roll & 0x00FFFFFF), format("%s: a vertex of another colour", t));
    }
}

// ---- the census: one draw site, tools publish -------------------------------
private string[2][] productionSources() {
    string[2][] files;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        files ~= [de.name[repoRoot.length + 1 .. $],
                  blankUnittestBodies(blankNonCode(readText(de.name)))];
    return files;
}

unittest
{
    const files = productionSources();
    assert(files.length >= 500, format("population floor: %s source files", files.length));
    string[] drawers, publishers, fields;
    foreach (f; files) {
        if (f[0] == "source/snap_render.d") continue;
        if (countIdent(f[1], "drawSnapOverlay")) drawers ~= f[0];
        if (countIdent(f[1], "publishLastSnap")) publishers ~= f[0];
        if (f[0].indexOf("source/tools/") == 0 && f[1].indexOf("SnapResult lastSnap") >= 0)
            fields ~= f[0];
    }
    drawers.sort(); publishers.sort();
    // Floor: the publishers are the tools that snap.
    assert(publishers.length == 9, format("publishLastSnap files: %s", publishers));
    // Needle: every spelling of the drawer (import, call, address) — the frame
    // and pen, whose call and field wait for the pen-owned slice.
    assert(drawers == ["source/frame_runner.d", "source/tools/create/pen.d"],
        format("drawSnapOverlay outside the frame: %s", drawers));
    assert(fields == ["source/tools/create/pen.d"], format("tools keeping a snap field: %s", fields));
    // Structure: the frame's one call draws the published snap in drawScene,
    // behind the overlay-mode gate.
    const fr = files.filter!(f => f[0] == "source/frame_runner.d").front[1];
    const scene = fr[fr.indexOf("void drawScene(") .. $];
    const call = scene.indexOf("drawSnapOverlay(g_lastSnap, *view.viewport, *scene.mesh)");
    assert(countIdent(fr, "drawSnapOverlay") == 2 && call > 0
        && scene[0 .. call].indexOf("if (overlayMode != OverlayMode.None)") > 0
        && call < scene.indexOf("\n    }"),
        "frame_runner.drawScene no longer draws g_lastSnap once behind the overlay gate");
}
