// The published snap is drawn once per cell by the frame, in the captured look
// (toolcards findings_O: O1 idle rollover in `preHighlight`; O1d drag cross,
// `handleUnsnap` before the snap, `handle` once snapped). Compiler pins on the
// tools' composition, the marks read back from a headless ImGui foreground
// list, then a census of the production text.
module tests.unit.snap_overlay_test;


import tests.unit.census_symbols : exists = wave15Exists;

import std.algorithm : canFind, filter, sort;
import std.array     : array;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format    : format;
import std.math      : abs;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import ImGui = d_imgui;
import d_imgui.imgui_h : ImVec2;

import vibe3d.platform.input.held_gesture_buttons : g_heldGestureButtons;
import vibe3d.util.math.math : Vec3;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull;
import vibe3d.mesh.core.mesh        : Mesh;
import vibe3d.editing.selection.query.snap        : SnapResult;
import vibe3d.editing.tools.interactive.snap_render : SnapMark, drawSnapOverlay;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SnapType;
import vibe3d.viewport.camera.view        : View;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent;
import tests.unit.ui.headless_panel : openPanel;

import vibe3d.editing.tools.interactive.tools.transform.transform : TransformTool;
import vibe3d.editing.tools.interactive.tools.create.box : BoxTool;
import vibe3d.editing.tools.interactive.tools.create.primitive_create_tool : PrimitiveCreateTool;
import vibe3d.editing.tools.interactive.tools.create.vertex_place : VertexTool;
import vibe3d.editing.tools.interactive.tools.create.pen : PenTool;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---- the fence: no tool keeps a snap of its own ------------------------------
static assert([__traits(allMembers, SnapMark)] == ["none", "rollover", "unsnapped", "snapped"]);
private enum bool keepsSnap(T) = [__traits(allMembers, T)].canFind("lastSnap")
                              || [__traits(allMembers, T)].canFind("lastSnap_");
static assert(!keepsSnap!TransformTool && !keepsSnap!BoxTool && !keepsSnap!PrimitiveCreateTool
           && !keepsSnap!VertexTool && !keepsSnap!PenTool,
    "a tool regrew its own snap copy: publish through publishLastSnap instead");

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
        Row(false, true,  true, SnapType.Vertex,  0,  0,  0, 0,      Box.none),   // held: no other guard
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
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/pipe-contracts/source"), buildPath(repoRoot, "packages/mesh-preview/source"), buildPath(repoRoot, "util/json-number/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        files ~= [de.name[repoRoot.length + 1 .. $],
                  blankUnittestBodies(blankNonCode(readText(de.name)))];
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);files ~= [sourceCarrierPath[repoRoot.length + 1 .. $],
                  blankUnittestBodies(blankNonCode(readText(sourceCarrierPath)))];
    }
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
    // Needle: every spelling of the drawer (import, call, address) — the frame.
    assert(drawers == ["source/frame_runner.d"],
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
