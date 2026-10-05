// The published snap is drawn once per cell by the frame, in the captured look
// (toolcards findings_O: O1 idle rollover in `preHighlight`; O1d drag cross,
// `handleUnsnap` before the snap, `handle` once snapped). Compiler pins on the
// tools' composition, the marks read back from a headless ImGui foreground
// list, then a census of the production text.
module tests.unit.snap_overlay_test;

import std.algorithm : canFind, filter, sort;
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
import snap_render : SnapMark, drawSnapOverlay;
import toolpipe.packets : SnapType;
import view        : View;
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

private uint rgba(ubyte r, ubyte g, ubyte b) { return 0xFF000000u | (b << 16) | (g << 8) | r; }

unittest // the mark law, its captured colours and shapes
{
    scope (exit) g_heldGestureButtons.clear();
    auto vp = new View(0, 0, 400, 300).viewport();
    // v0 is the vertex target; v0..v3 a quad, v0..v4 a concave pentagon.
    Mesh m;
    foreach (p; [Vec3(0.3f, 0.2f, 0.1f), Vec3(0.9f, 0.2f, 0.1f), Vec3(0.9f, 0.8f, 0.1f),
                 Vec3(0.3f, 0.8f, 0.1f), Vec3(0.6f, 0.5f, 0.1f)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([0u, 1u, 2u, 4u, 3u]);
    float px, py, cx, cy, ndcZ;
    immutable Vec3 cursor = Vec3(-0.4f, 0.1f, 0.0f);   // the cross sits here, off v0
    assert(projectToWindowFull(m.vertices[0], vp, px, py, ndcZ)
        && projectToWindowFull(cursor, vp, cx, cy, ndcZ), "fixture off screen");
    assert(abs(cx - px) + abs(cy - py) > 20, "vacuous fixture: the marks coincide");

    enum Box { none, square, cross, any }
    static struct Row {
        bool highlighted, held, snapped; SnapType type; int index;
        size_t count, opaque; uint col; Box box;
    }
    // Colours are the captured pixel reads (preHighlight, handleUnsnap, handle);
    // counts are measured: a 2 px line is 4 opaque vertices, an anti-aliased fill
    // 2n with n opaque, the cross four such lines.
    immutable roll = rgba(140, 181, 199), unsnap = rgba(230, 179, 255), handle = rgba(102, 255, 255);
    immutable Row[] rows = [
        Row(false, false, true, SnapType.Vertex,  0,  0,  0, 0,      Box.none),
        Row(true,  false, true, SnapType.Vertex,  0,  4,  4, roll,   Box.square),
        Row(true,  true,  true, SnapType.Vertex,  0, 16, 16, handle, Box.cross),
        Row(true,  true, false, SnapType.Vertex,  0, 16, 16, unsnap, Box.cross),
        Row(true,  false, true, SnapType.Edge,    0,  4,  4, roll,   Box.any),
        Row(true,  false, true, SnapType.Polygon, 0,  8,  4, roll,   Box.any),
        Row(true,  false, true, SnapType.Polygon, 1, 10,  5, roll,   Box.any),
    ];
    assert(rows.length == 7);
    foreach (i, row; rows) {
        SnapResult r;
        r.highlighted = row.highlighted; r.snapped = row.snapped;
        r.targetType = row.type; r.targetIndex = row.index; r.worldPos = cursor;
        g_heldGestureButtons.clear();
        if (row.held) g_heldGestureButtons.press(1);
        auto got = drawn(r, vp, m);
        immutable size_t opaque = got.filter!(v => v.col == row.col).array.length;
        assert(got.length == row.count && opaque == row.opaque,
            format("row %s: %s vertices, %s opaque in %08x", i, got.length, opaque, row.col));
        foreach (v; got) {
            assert((v.col & 0x00FFFFFF) == (row.col & 0x00FFFFFF), format("row %s: another colour", i));
            immutable float dx = abs(v.x - (row.box == Box.cross ? cx : px));
            immutable float dy = abs(v.y - (row.box == Box.cross ? cy : py));
            if (row.box == Box.square)
                assert(abs(dx - 3) < 1e-3 && abs(dy - 3) < 1e-3, format("row %s: not the 6x6 square", i));
            if (row.box == Box.cross)
                assert(dx < 9.5f && dy < 9.5f && (dx > 3f || dy > 3f),
                    format("row %s: vertex (%s,%s) outside the gapped cross", i, v.x, v.y));
        }
    }
}

// ---- the census: one draw site, tools publish -------------------------------
unittest
{
    string[2][] files;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        files ~= [de.name[repoRoot.length + 1 .. $],
                  blankUnittestBodies(blankNonCode(readText(de.name)))];
    assert(files.length >= 500, format("population floor: %s source files", files.length));
    string[] drawers, publishers;
    foreach (f; files) {
        if (f[0] == "source/snap_render.d") continue;
        if (countIdent(f[1], "drawSnapOverlay")) drawers ~= f[0];
        if (countIdent(f[1], "publishLastSnap")) publishers ~= f[0];
    }
    drawers.sort();
    // Floor: the publishers are the tools that snap.
    assert(publishers.length == 9, format("publishLastSnap files: %s", publishers));
    // Needle: every spelling of the drawer (import, call, address) — the frame
    // and pen, whose call waits for the pen-owned slice.
    assert(drawers == ["source/frame_runner.d", "source/tools/create/pen.d"],
        format("drawSnapOverlay outside the frame: %s", drawers));
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
