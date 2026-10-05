// One operation per tool, behaviourally: for each edit-family tool the live
// preview (an interactive param write → `rebuildPreview`), the prepared panel
// image (`buildPreparedParamUpdate` → its candidate) and the scripted apply
// (`applyHeadless`) land the SAME mesh for the same parameters (task 9433;
// wave plan PV3a). Each mode is first pinned to its measured counts and a
// position digest, so a change of the one operation reddens EVERY mode that
// reaches it, not only their equality; then the modes are compared bit for bit.
// The text half (one kernel site per tool) is tool_single_operation_census_test.
module tests.unit.tool_single_operation_equivalence_test;

import std.format : format;
import std.math : abs;

import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, makeCube, makeGridPlane;
import mesh_gpu : GpuMesh;
import params : Param;
import tool : Tool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.edit.reduce : ReductionTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;

private final class Rig {
    Mesh mesh; GpuMesh gpu; EditMode mode;
    this(EditMode m, void function(ref Mesh) pick) {
        mode = m; mesh = makeCube(); pick(mesh);
        gpu.suppressCageUpload = true;   // no GL: the upload becomes a publish
    }
}

private void pickFace(ref Mesh m) { m.syncSelection(); m.selectFace(0); }
private void pickEdge(ref Mesh m) { m.syncSelection(); m.selectEdge(0); }
private void pickVertex(ref Mesh m) { m.syncSelection(); m.selectVertex(0); }
private void pickTwoVertices(ref Mesh m) {
    m.syncSelection(); m.selectVertex(0); m.selectVertex(1);
}
private void triangulateAll(ref Mesh m) {
    auto mask = m.operandFaceMask(); m.triangulateFacesByMask(mask);
}
private void triangulatedGrid(ref Mesh m) { m = makeGridPlane(2); triangulateAll(m); }

/// The scripted apply's refusal rig: every element hidden leaves each
/// kernel's operand mask empty.
private void hideAll(ref Mesh m, Tool) {
    foreach (ref w; m.vertexMarks) w |= Mesh.Marks.Hide;
    foreach (ref w; m.edgeMarks) w |= Mesh.Marks.Hide;
    foreach (ref w; m.faceMarks) w |= Mesh.Marks.Hide;
}

private void poke(Tool t, string name, float v) {
    foreach (ref p; t.params()) {
        if (p.name != name) continue;
        if (p.kind == Param.Kind.Bool) *p.bptr = v != 0; else *p.fptr = v;
        return;
    }
    assert(false, "no param named `" ~ name ~ "`");
}

/// A digest that moves with any vertex position (weights break symmetry).
private double digest(ref const Mesh m) {
    double s = 0;
    foreach (i, v; m.vertices) s += (i + 1) * (v.x + 2.0 * v.y + 3.0 * v.z);
    return s;
}

private size_t rows;

/// `headlessShared` false: the scripted apply has its own kernel call (the
/// polygon extrude row, an open finding on task 9433) — its faces must then
/// DIFFER from the live ones, so the row flips when the finding is resolved.
private void row(T)(EditMode mode, void function(ref Mesh) pick,
        string[] names, float[] values, size_t verts, size_t faces, double dig,
        bool headlessShared = true, void function(ref Mesh, Tool) refuse = &hideAll) {
    enum name = T.stringof;
    ++rows;
    T make(Rig r) { return new T(() => &r.mesh, &r.gpu, &r.mode, null); }

    // LIVE: an interactive session (the seed is the armed state a press
    // leaves), then the panel's two-step on the last name: poke, notify.
    auto live = new Rig(mode, pick);
    auto lt = make(live);
    lt.seedPreparedParamForTest(live.mesh, true);
    foreach (i, n; names) poke(lt, n, values[i]);
    lt.notifyInteractiveParamChanged(names[$ - 1]);

    // PREPARED: the same session, the panel image built on its candidate.
    auto prep = new Rig(mode, pick);
    auto pt = make(prep);
    pt.seedPreparedParamForTest(prep.mesh, true);
    foreach (i, n; names) poke(pt, n, values[i]);
    auto image = pt.buildPreparedParamUpdate(prep.mesh);
    scope(exit) image.clear();
    assert(image.applies, name ~ ": the prepared image did not apply");

    // HEADLESS: armed, attrs written without a notification, applied.
    auto head = new Rig(mode, pick);
    auto ht = make(head);
    ht.activate();
    foreach (i, n; names) poke(ht, n, values[i]);
    assert(ht.applyHeadless(), name ~ ": the scripted apply refused");

    // PIN, every mode in one message: the one operation's measured output.
    string missed;
    void pin(string mode, ref const Mesh m) {
        if (m.vertices.length != verts || m.faces.length != faces ||
                abs(digest(m) - dig) > 1e-3)
            missed ~= format(" %s=%sv/%sf/%.4f", mode, m.vertices.length,
                m.faces.length, digest(m));
    }
    pin("live", live.mesh); pin("prepared", image.candidate); pin("headless", head.mesh);
    assert(missed.length == 0, format("%s: expected %sv/%sf/%.4f; off:%s",
        name, verts, faces, dig, missed));

    // EQUALITY, bit for bit, against the live mesh.
    void same(string mode, ref const Mesh m) {
        assert(m.vertices == live.mesh.vertices && m.faces == live.mesh.faces,
            format("%s: %s differs from live\n  %s\n  %s\n  %s\n  %s", name, mode,
                m.vertices, live.mesh.vertices, m.faces, live.mesh.faces));
    }
    same("prepared", image.candidate);
    if (headlessShared) same("headless", head.mesh);
    else assert(head.mesh.faces != live.mesh.faces, name ~ ": the scripted apply "
        ~ "now matches the live faces — the open finding is resolved; share the row");

    // REFUSAL: an operation that builds nothing refuses the scripted apply
    // (the command no-op contract: no `ok`, no history entry).
    auto none = new Rig(mode, pick);
    auto nt = make(none);
    nt.activate();
    foreach (i, n; names) poke(nt, n, values[i]);
    refuse(none.mesh, nt);
    const v0 = none.mesh.vertices.length, f0 = none.mesh.faces.length;
    assert(!nt.applyHeadless() && none.mesh.vertices.length == v0 &&
        none.mesh.faces.length == f0, name ~ ": the scripted apply did not refuse "
        ~ "an operation that built nothing");
}

// Pins measured on main a9192104 (task 9433 Step 0), the same in all three modes.
unittest {
    row!EdgeExtrudeTool(EditMode.Edges, &pickEdge, ["width", "extrude"],
        [0.1f, 0.3f], 12, 10, -85.9279);
    row!PolyExtrudeTool(EditMode.Polygons, &pickFace, ["distance"],
        [0.3f], 12, 10, -66.8, false);
    row!VertexBevelTool(EditMode.Vertices, &pickVertex, ["inset"],
        [0.2f], 10, 7, -38.0);
    row!VertexExtrudeTool(EditMode.Vertices, &pickVertex, ["shift", "width"],
        [0.1f, 0.2f], 14, 12, -147.6392);
    row!PolyInsetTool(EditMode.Polygons, &pickFace, ["inset"],
        [0.1f], 12, 10, -29.2828);
    row!VertexMergeTool(EditMode.Vertices, &pickTwoVertices, ["dist"],
        [1.5f], 7, 6, 31.5);
    row!ReductionTool(EditMode.Polygons, &triangulateAll, ["ratio"],
        [0.5f], 5, 6, 13.5, true, (ref Mesh, Tool t) { poke(t, "ratio", 1.0f); });
    // A ratio rounding to no face keeps one (the operation's floor; on an open
    // grid without boundary preservation the kernel would otherwise take all).
    row!ReductionTool(EditMode.Polygons, &triangulatedGrid, ["preserveBoundary", "ratio"],
        [0.0f, 0.01f], 3, 1, 3.75, true, (ref Mesh, Tool t) { poke(t, "ratio", 1.0f); });
    row!SmoothShiftTool(EditMode.Polygons, &pickFace, ["scale", "shift"],
        [1.0f, 0.3f], 12, 10, -66.8);
    assert(rows == 9, format("%s rows ran, expected 9 (8 tools, reduce twice)", rows));
}
