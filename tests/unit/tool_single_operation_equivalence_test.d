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
import tools.alignment.array_tool : ArrayTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.poly_bevel : PolyBevelTool;
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
        if (p.kind == Param.Kind.Bool) *p.bptr = v != 0;
        else if (p.kind == Param.Kind.Int) *p.iptr = cast(int) v;
        else *p.fptr = v;
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

// The seams that differ by tool: the array tool's constructor has no shader,
// its seed spells the session out, and the radial array's panel image is its
// transition owner's `buildPreparedParamImage`.
private T makeTool(T)(Rig r) {
    static if (is(T == ArrayTool)) return new T(() => &r.mesh, &r.gpu, &r.mode);
    else return new T(() => &r.mesh, &r.gpu, &r.mode, null);
}
private void seedSession(T)(T t, ref Mesh m) {
    static if (is(T == ArrayTool)) t.seedPreparedParamForTest(m, true, true, false);
    else t.seedPreparedParamForTest(m, true);
}
private auto panelImage(T)(T t, string name, ref Mesh m) {
    static if (is(T == RadialArrayTool)) return t.buildPreparedParamImage(m);
    else return t.buildPreparedParamUpdate(name, m);
}

private void row(T)(EditMode mode, void function(ref Mesh) pick,
        string[] names, float[] values, size_t verts, size_t faces, double dig,
        void function(ref Mesh, Tool) refuse = &hideAll, bool emptyApplies = false) {
    enum name = T.stringof;
    ++rows;
    alias make = makeTool!T;

    // LIVE: an interactive session (the seed is the armed state a press
    // leaves), then the panel's two-step on the last name: poke, notify.
    auto live = new Rig(mode, pick);
    auto lt = make(live);
    seedSession(lt, live.mesh);
    foreach (i, n; names) poke(lt, n, values[i]);
    lt.notifyInteractiveParamChanged(names[$ - 1]);

    // PREPARED: the same session, the panel image built on its candidate.
    auto prep = new Rig(mode, pick);
    auto pt = make(prep);
    seedSession(pt, prep.mesh);
    foreach (i, n; names) poke(pt, n, values[i]);
    auto image = panelImage(pt, names[$ - 1], prep.mesh);
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
    same("headless", head.mesh);

    // DEGENERATE: an operation that builds nothing refuses the scripted apply
    // (the command no-op contract: no `ok`, no history entry) -- except the
    // clone family, which applies an empty step (capture K-AR: ok, one record).
    auto none = new Rig(mode, pick);
    auto nt = make(none);
    nt.activate();
    foreach (i, n; names) poke(nt, n, values[i]);
    refuse(none.mesh, nt);
    const v0 = none.mesh.vertices.dup, f0 = none.mesh.faces.length;
    assert(nt.applyHeadless() == emptyApplies && none.mesh.vertices == v0 &&
        none.mesh.faces.length == f0, name ~ (emptyApplies
        ? ": the scripted apply of an empty operand must apply and change nothing"
        : ": the scripted apply did not refuse an operation that built nothing"));
}

// The scripted polygon extrude against the reference's scripted apply (capture
// K-PX, task 9487; fixture private): on the open box (8v/4f, polygon 0 = the
// -Z face selected) every cell gives walls first, the cap LAST and selected,
// the cap shift in full, and a ZERO extent still builds the coincident
// topology. Our `distance` is the reference's extent = normal x distance (PX_B).
unittest {
    static immutable float[3][8] box = [[-.5, -.5, -.5], [-.5, -.5, .5],
        [-.5, .5, -.5], [-.5, .5, .5], [.5, -.5, -.5], [.5, -.5, .5],
        [.5, .5, -.5], [.5, .5, .5]];
    static immutable uint[][] faceIn = [[0, 2, 6, 4], [0, 1, 3, 2], [2, 3, 7, 6],
        [0, 4, 5, 1]];
    static immutable uint[][] faceOut = [[0, 1, 3, 2], [2, 3, 7, 6], [0, 4, 5, 1],
        [11, 4, 0, 8], [8, 0, 2, 9], [9, 2, 6, 10], [10, 6, 4, 11], [8, 9, 10, 11]];
    static immutable uint[4] ring = [0, 2, 6, 4];   // new vertex 8+k from ring[k]
    size_t cells;
    // cell, distance, shift X, the extent every new vertex sits at
    void cell(string id, float distance, float shiftX, float[3] extent) {
        auto r = new Rig(EditMode.Polygons, (ref Mesh m) {});
        r.mesh = Mesh.init;
        foreach (p; box) r.mesh.addVertex(Vec3(p[0], p[1], p[2]));
        foreach (f; faceIn) r.mesh.addFace(f.dup);
        r.mesh.syncSelection(); r.mesh.selectFace(0);
        auto t = new PolyExtrudeTool(() => &r.mesh, &r.gpu, &r.mode, null);
        t.activate();
        poke(t, "distance", distance); poke(t, "shiftX", shiftX);
        assert(t.applyHeadless(), id ~ ": the scripted apply refused");
        const m = &r.mesh;
        assert(m.vertices.length == 12 && m.faces.length == 8, format(
            "%s: %sv/%sf, the capture gives 12v/8f", id, m.vertices.length, m.faces.length));
        foreach (i, f; faceOut) assert(m.faces[i] == f, format(
            "%s: faces %s, the capture gives walls then cap %s", id, m.faces.range, faceOut));
        size_t[] sel;
        foreach (i; 0 .. m.faces.length) if (m.isFaceSelected(i)) sel ~= i;
        assert(sel == [7], format("%s: selected %s, the capture selects the cap 7", id, sel));
        foreach (k, v; ring) {
            const want = Vec3(box[v][0] + extent[0], box[v][1] + extent[1],
                box[v][2] + extent[2]);
            assert((m.vertices[8 + k] - want).length < 1e-6, format("%s: vertex %s "
                ~ "at %s, the capture %s", id, 8 + k, m.vertices[8 + k], want));
        }
        ++cells;
    }
    cell("PX_A", 0.3f, 0.2f, [0.2f, 0, -0.3f]);
    cell("PX_B", 0.3f, 0.0f, [0, 0, -0.3f]);
    cell("PX_Z", 0.0f, 0.0f, [0, 0, 0]);       // zero extent: coincident, not a no-op
    assert(cells == 3);
}

// Pins measured on main a9192104 (task 9433 Step 0), the same in all three modes.
unittest {
    row!EdgeExtrudeTool(EditMode.Edges, &pickEdge, ["width", "extrude"],
        [0.1f, 0.3f], 12, 10, -85.9279);
    row!PolyExtrudeTool(EditMode.Polygons, &pickFace, ["distance"],
        [0.3f], 12, 10, -66.8);
    row!VertexBevelTool(EditMode.Vertices, &pickVertex, ["inset"],
        [0.2f], 10, 7, -38.0);
    row!VertexExtrudeTool(EditMode.Vertices, &pickVertex, ["shift", "width"],
        [0.1f, 0.2f], 14, 12, -147.6392);
    row!PolyInsetTool(EditMode.Polygons, &pickFace, ["inset"],
        [0.1f], 12, 10, -29.2828);
    // Vertex Merge's operand is the selection alone (no visible fallback):
    // a cleared selection welds nothing and refuses.
    row!VertexMergeTool(EditMode.Vertices, &pickTwoVertices, ["dist"],
        [1.5f], 7, 6, 31.5, (ref Mesh m, Tool) { m.clearVertexSelection(); });
    row!ReductionTool(EditMode.Polygons, &triangulateAll, ["ratio"],
        [0.5f], 5, 6, 13.5, (ref Mesh, Tool t) { poke(t, "ratio", 1.0f); });
    // A ratio rounding to no face keeps one (the operation's floor; on an open
    // grid without boundary preservation the kernel would otherwise take all).
    row!ReductionTool(EditMode.Polygons, &triangulatedGrid, ["preserveBoundary", "ratio"],
        [0.0f, 0.01f], 3, 1, 3.75, (ref Mesh, Tool t) { poke(t, "ratio", 1.0f); });
    row!SmoothShiftTool(EditMode.Polygons, &pickFace, ["scale", "shift"],
        [1.0f, 0.3f], 12, 10, -66.8);
    assert(rows == 9, format("%s rows ran, expected 9 (8 tools, reduce twice)", rows));
}

// The bevel / extend / array family (task 9434, wave plan PV3b). Pins measured
// on main da313d9a (Step 0), the same in all three modes. Edge Extend's params
// are pivot-agnostic: the live pivot is the armed bounding-box centre, the
// scripted one the origin (fixture case `command_path_rotate_pivot`).
unittest {
    rows = 0;
    row!EdgeBevelTool(EditMode.Edges, &pickEdge, ["roundLevel", "widthMode", "width"],
        [1.0f, 0.0f, 0.1f], 12, 8, -72.5054);
    row!PolyBevelTool(EditMode.Polygons, &pickFace,
        ["group", "segments", "square", "inset", "shift"],
        [1.0f, 1.0f, 0.0f, 0.1f, 0.2f], 12, 10, -54.6);
    row!EdgeExtendTool(EditMode.Edges, &pickEdge,
        ["opOpen", "offsetX", "offsetY", "shift", "inset"],
        [1.0f, 0.3f, 0.1f, 0.2f, 0.1f], 10, 7, 11.9);
    row!ArrayTool(EditMode.Polygons, &pickFace, ["numX", "numZ", "offZ", "offX"],
        [3.0f, 2.0f, 1.25f, 1.5f], 28, 11, 1105.5, &hideAll, true);
    row!RadialArrayTool(EditMode.Polygons, &pickFace,
        ["count", "weld", "offset", "angle"], [4.0f, 0.0f, 0.5f, 90.0f], 20, 9, -74.3146,
        &hideAll, true);
    assert(rows == 5, format("%s rows ran, expected 5", rows));
}

// The callers' pre-steps around the one operation (task 9434 sweep): each
// cell is the witness of one term the shared rows cannot see.
unittest {
    // Edge Bevel's topology key carries the zero-width crossing: dragging the
    // width through zero and back never claims "same topology" wrongly.
    {
        auto r = new Rig(EditMode.Edges, &pickEdge);
        auto t = makeTool!EdgeBevelTool(r);
        seedSession(t, r.mesh);
        foreach (w; [0.1f, 0.0f, 0.1f]) {
            poke(t, "width", w); t.notifyInteractiveParamChanged("width");
            const want = w == 0 ? 8 : 12;
            assert(r.mesh.vertices.length == want, format("edge bevel at width "
                ~ "%s: %s vertices, expected %s", w, r.mesh.vertices.length, want));
        }
        assert(t.previewRebuildCounts().keyMisses == 0, format("edge bevel: the "
            ~ "key missed the zero crossing %s times", t.previewRebuildCounts().keyMisses));
        assert(abs(digest(r.mesh) - -72.5054) < 1e-3, "edge bevel: back at 0.1, "
            ~ "not the measured mesh");
    }
    // Polygon Bevel builds the live operation only once a press applied it,
    // and its key carries that crossing.
    {
        auto r = new Rig(EditMode.Polygons, &pickFace);
        auto t = makeTool!PolyBevelTool(r);
        t.activate();
        poke(t, "inset", 0.1f); poke(t, "shift", 0.2f);
        t.notifyInteractiveParamChanged("inset");
        assert(r.mesh.vertices.length == 8 && r.mesh.faces.length == 6, format(
            "polygon bevel built %sv/%sf before a press", r.mesh.vertices.length,
            r.mesh.faces.length));
        poke(t, "applied", 1.0f); t.notifyInteractiveParamChanged("applied");
        assert(r.mesh.vertices.length == 12 && r.mesh.faces.length == 10, format(
            "polygon bevel applied: %sv/%sf, expected 12v/10f",
            r.mesh.vertices.length, r.mesh.faces.length));
        assert(t.previewRebuildCounts().keyMisses == 0, format("polygon bevel: "
            ~ "the key missed the applied crossing %s times",
            t.previewRebuildCounts().keyMisses));
    }
    // Polygon Bevel's scripted apply at 0/0 is the base itself (the arm's
    // zero ring is not applied) and succeeds.
    {
        auto r = new Rig(EditMode.Polygons, &pickFace);
        auto t = makeTool!PolyBevelTool(r);
        t.activate();
        poke(t, "inset", 0.0f); poke(t, "shift", 0.0f);
        const before = r.mesh.vertices.dup;
        assert(t.applyHeadless() && r.mesh.vertices == before &&
            r.mesh.faces.length == 6, format("polygon bevel 0/0 scripted: %sv/%sf, "
            ~ "expected the base 8v/6f", r.mesh.vertices.length, r.mesh.faces.length));
    }
    // Array 1x1x1 with Replace Source transforms the source in place and adds
    // no face: the kernel answers 0, yet the edit is built and applies.
    {
        rows = 0;
        row!ArrayTool(EditMode.Polygons, &pickFace,
            ["numX", "numZ", "replace", "angB"], [1.0f, 1.0f, 1.0f, 30.0f], 8, 6, 30.4641,
            (ref Mesh m, Tool t) { poke(t, "replace", 0.0f); }, true);
        assert(rows == 1);
        foreach (panel; [false, true]) {
            auto r = new Rig(EditMode.Polygons, &pickFace);
            auto t = makeTool!ArrayTool(r);
            seedSession(t, r.mesh);
            foreach (n, v; ["numX": 1.0f, "numZ": 1.0f, "replace": 1.0f, "angB": 30.0f])
                poke(t, n, v);
            if (panel) {
                auto image = t.buildPreparedParamUpdate("angB", r.mesh);
                scope(exit) image.clear();
                assert(image.applies && image.nextBuilt, "array replace-in-place: "
                    ~ "the panel image is not built");
            } else {
                t.notifyInteractiveParamChanged("angB");
                assert(t.preparedParamStateForTest(true), "array replace-in-place: "
                    ~ "the live edit is not built");
            }
        }
    }
}

// Radial Array at ONE copy builds nothing (the kernel's `count <= 1` refusal is
// the only guard since task 9434): the live preview and the panel image keep
// the source faces and the face and vertex selection. (The topology version is
// no witness: the preview restores its cage every frame, which bumps it.)
unittest {
    size_t[] selectedFaces(const Mesh* m) {
        size_t[] r; foreach (i; 0 .. m.faces.length) if (m.isFaceSelected(i)) r ~= i; return r;
    }
    size_t[] selectedVerts(const Mesh* m) {
        size_t[] r; foreach (i; 0 .. m.vertices.length) if (m.isVertexSelected(i)) r ~= i; return r;
    }
    size_t cells;
    foreach (panel; [false, true]) {
        auto r = new Rig(EditMode.Polygons, (ref Mesh m) {
            m.syncSelection(); m.selectFace(0); m.selectVertex(0); });
        auto t = makeTool!RadialArrayTool(r);
        seedSession(t, r.mesh);
        foreach (n, v; ["count": 1.0f, "angle": 90.0f, "offset": 0.5f]) poke(t, n, v);
        const verts = r.mesh.vertices.dup;
        const faces = r.mesh.faces.length;
        const selF = selectedFaces(&r.mesh), selV = selectedVerts(&r.mesh);
        assert(selF == [0] && selV == [0], format("rig: selection %s / %s", selF, selV));
        Mesh* m = &r.mesh;
        typeof(t.buildPreparedParamImage(r.mesh)) image;
        scope(exit) image.clear();
        if (panel) {
            image = t.buildPreparedParamImage(r.mesh);
            assert(image.applies && !image.built, "radial count 1: the panel image built");
            m = &image.candidate;
        } else {
            t.notifyInteractiveParamChanged("angle");
            assert(t.preparedParamStateForTest(false), "radial count 1: the preview built");
        }
        const mode = panel ? "panel image" : "preview";
        assert(m.vertices == verts && m.faces.length == faces, format("radial count 1 "
            ~ "%s: %sv/%sf, expected the source", mode, m.vertices.length, m.faces.length));
        assert(selectedFaces(m) == selF && selectedVerts(m) == selV, format("radial "
            ~ "count 1 %s: selection %s / %s, expected %s / %s", mode, selectedFaces(m),
            selectedVerts(m), selF, selV));
        ++cells;
    }
    assert(cells == 2);
}

// Loose points, no face: the clone family's scripted apply still answers ok
// (capture K-AR AR_E0; the reference also copies the points, ours copies none).
unittest {
    void cell(T)() {
        auto r = new Rig(EditMode.Polygons, (ref Mesh m) {
            m = Mesh.init;
            foreach (i; 0 .. 3) m.addVertex(Vec3(i, 0, 0));
            m.syncSelection();
        });
        auto t = makeTool!T(r);
        t.activate();
        assert(r.mesh.faces.length == 0 && r.mesh.vertices.length == 3, "rig: 3 loose points");
        assert(t.applyHeadless(), T.stringof ~ ": loose points only -- the scripted "
            ~ "apply must answer ok");
    }
    cell!ArrayTool();
    cell!RadialArrayTool();
}
