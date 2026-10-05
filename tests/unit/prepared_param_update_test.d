module unit.prepared_param_update_test;

// Task 9426: ONE `PreparedParamUpdateOwner` and ONE record-context slot serve
// eleven tools' interactive parameter preview. Each row is a tool as DATA
// (constructor, operand selection, seed, the stale write, the built probe, the
// element count its preview moves); every row runs the same four cells that
// each tool's own module used to carry: preview install, noop install, stale
// image refused, foreign GPU refused. Tool-specific cells follow the table.
// The slot's install-trace code is 43 for every row.

import std.meta : AliasSeq;
import std.math : abs;
import command_history : CommandHistory;
import document : Layer;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh, GpuUploadOwner;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect;
import record_observer_hub : RecordObserverHub;
import shader : LitShader;
import tools.alignment.array_tool : ArrayTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.edit.reduce : ReductionTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;

private size_t vertexCount(ref Mesh m) { return m.vertices.length; }
private size_t faceCount(ref Mesh m) { return m.faces.length; }
private void pickFace(ref Mesh m) { m.syncSelection(); m.selectFace(0); }
private void pickEdge(ref Mesh m) { m.syncSelection(); m.selectEdge(0); }
private void pickVertex(ref Mesh m) { m.syncSelection(); m.selectVertex(0); }
private void pickTwoVertices(ref Mesh m) {
    m.syncSelection(); m.selectVertex(0); m.selectVertex(1);
}
private void triangulateAll(ref Mesh m) {
    auto mask = m.operandFaceMask(); m.triangulateFacesByMask(mask);
}

/// A row: `Tool`, `Kind`, `mode`, `operand` (the selection the preview acts
/// on), `seed`, `stale` (a write the frozen image must refuse), `built`
/// (`before`/`after` install expectations), `count` and its preview sign.
private mixin template LitRow(ToolT, KindT, EditMode m, alias pick, alias countFn,
        int sign, float staleValue) {
    alias Tool = ToolT; alias Kind = KindT; enum mode = m;
    static Tool make(Layer l, GpuMesh* g, EditMode* e) {
        return new Tool(() => &l.meshRef(), g, e, LitShader.init);
    }
    static void operand(ref Mesh mesh) { pick(mesh); }
    static size_t count(ref Mesh mesh) { return countFn(mesh); }
    enum previewSign = sign;
    static void stale(Tool t) { t.mutatePreparedParamForTest(staleValue); }
}
private struct PolyInsetRow {
    mixin LitRow!(PolyInsetTool, PreparedPolyInsetParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct PolyBevelRow {
    mixin LitRow!(PolyBevelTool, PreparedPolyBevelParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamInstalledForTest(); }
    enum builtBefore = false;
}
private struct PolyExtrudeRow {
    mixin LitRow!(PolyExtrudeTool, PreparedPolyExtrudeParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct EdgeBevelRow {
    mixin LitRow!(EdgeBevelTool, PreparedEdgeBevelParamKind, EditMode.Edges,
        pickEdge, vertexCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamInstalledForTest(); }
    enum builtBefore = false;
}
private struct EdgeExtrudeRow {
    mixin LitRow!(EdgeExtrudeTool, PreparedEdgeExtrudeParamKind, EditMode.Edges,
        pickEdge, vertexCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct ReductionRow {
    mixin LitRow!(ReductionTool, PreparedReductionParamKind, EditMode.Polygons,
        triangulateAll, faceCount, -1, 0.25f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct SmoothShiftRow {
    mixin LitRow!(SmoothShiftTool, PreparedSmoothShiftParamKind, EditMode.Polygons,
        pickFace, faceCount, 1, 17.0f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = true;   // its seed marks an interactive preview built
}
private struct VertexMergeRow {
    mixin LitRow!(VertexMergeTool, PreparedVertexMergeParamKind, EditMode.Vertices,
        pickTwoVertices, vertexCount, -1, 0.25f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct VertexBevelRow {
    mixin LitRow!(VertexBevelTool, PreparedVertexBevelParamKind, EditMode.Vertices,
        pickVertex, vertexCount, 1, 0.4f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct VertexExtrudeRow {
    mixin LitRow!(VertexExtrudeTool, PreparedVertexExtrudeParamKind, EditMode.Vertices,
        pickVertex, vertexCount, 1, 0.4f);
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = false;
}
private struct ArrayRow {
    alias Tool = ArrayTool; alias Kind = PreparedArrayParamKind;
    enum mode = EditMode.Polygons;
    static Tool make(Layer l, GpuMesh* g, EditMode* e) {
        return new Tool(() => &l.meshRef(), g, e);
    }
    static void operand(ref Mesh mesh) { pickFace(mesh); }
    static size_t count(ref Mesh mesh) { return faceCount(mesh); }
    enum previewSign = 1;
    static void stale(Tool t) { t.mutatePreparedParamForTest(17); }
    static void seed(Tool t, ref Mesh m, bool i) {
        t.seedPreparedParamForTest(m, i, true, false);
    }
    static bool built(Tool t) { return t.preparedParamStateForTest(true); }
    enum builtBefore = false;
}

private alias kRows = AliasSeq!(ArrayRow, SmoothShiftRow, EdgeBevelRow,
    EdgeExtrudeRow, PolyBevelRow, PolyExtrudeRow, PolyInsetRow, ReductionRow,
    VertexMergeRow, VertexBevelRow, VertexExtrudeRow);

private struct Rig(R) {
    Layer layer; GpuMesh gpu; EditMode mode = R.mode; R.Tool tool;
    PreparedRecordContext context;
    static Rig* make(bool operand, bool interactive, CommandHistory history = null) {
        auto r = new Rig;
        r.layer = new Layer; r.layer.meshRef() = makeCube();
        if (operand) R.operand(r.layer.meshRef());
        r.tool = R.make(r.layer, &r.gpu, &r.mode);
        R.seed(r.tool, r.layer.meshRef(), interactive);
        r.context = new PreparedRecordContext(history, new RecordObserverHub());
        return r;
    }
}

static assert(kRows.length == 11, "prepared param-update table lost a row");

unittest {
    size_t rows;
    static foreach (R; kRows) {{
        enum name = R.Tool.stringof;
        // Preview install: nothing moves until the context installs, then the
        // candidate lands once (a second install is a no-op) in trace order.
        auto p = Rig!R.make(true, true, new CommandHistory());
        p.context.setResourceIdentity(7, 11);
        const before = R.count(p.layer.meshRef());
        auto effect = p.tool.prepareParamChanged(p.context, p.layer,
            GpuUploadOwner.fakeForTest(&p.gpu));
        assert(effect.accepted && effect.kind == R.Kind.Preview, name ~ ": preview refused");
        assert(R.count(p.layer.meshRef()) == before && R.built(p.tool) == R.builtBefore,
            name ~ ": preview wrote before install");
        assert(p.context.validate(), name ~ ": preview did not validate");
        p.context.install(); p.context.install();
        assert((R.previewSign > 0 ? R.count(p.layer.meshRef()) > before
                : R.count(p.layer.meshRef()) < before) && R.built(p.tool),
            name ~ ": preview install did not land");
        assert(p.context.installTraceForTest() == [3,4,43,2,8],
            name ~ ": preview install trace");

        // Noop install: a non-interactive edit enlists the slot and NoHistory only.
        auto n = Rig!R.make(false, false);
        const cube = R.count(n.layer.meshRef());
        auto noop = n.tool.prepareParamChanged(n.context, n.layer, null);
        assert(noop.accepted && noop.kind == R.Kind.Noop && n.context.validate(),
            name ~ ": noop refused");
        n.context.install();
        assert(R.count(n.layer.meshRef()) == cube &&
            n.context.installTraceForTest() == [43,8], name ~ ": noop install");

        // Stale image: a parameter write after prepare is refused at validate.
        auto s = Rig!R.make(true, true);
        s.context.setResourceIdentity(7, 11);
        const staleBefore = R.count(s.layer.meshRef());
        assert(s.tool.prepareParamChanged(s.context, s.layer,
            GpuUploadOwner.fakeForTest(&s.gpu)).accepted, name ~ ": stale prepare");
        R.stale(s.tool);
        assert(!s.context.validate(), name ~ ": a stale image validated");
        assert(R.count(s.layer.meshRef()) == staleBefore, name ~ ": stale wrote");

        // Foreign GPU: an upload owner for another GpuMesh refuses the prepare.
        auto w = Rig!R.make(true, true);
        w.context.setResourceIdentity(7, 11);
        const wrongBefore = R.count(w.layer.meshRef());
        GpuMesh foreignGpu;
        auto wrong = w.tool.prepareParamChanged(w.context, w.layer,
            GpuUploadOwner.fakeForTest(&foreignGpu));
        assert(!wrong.accepted && !w.context.validate() &&
            R.count(w.layer.meshRef()) == wrongBefore, name ~ ": foreign GPU accepted");
        ++rows;
    }}
    assert(rows == 11, "prepared param-update table lost a row");
}


// Polygon Bevel (slice M3b): the session image beyond the haul is in the
// projection, so an `applied` / `op` raw write between prepare and install
// is a mismatch.
unittest {
    foreach (name; ["applied", "op"]) {
        auto r = Rig!PolyBevelRow.make(true, true);
        r.context.setResourceIdentity(7, 11);
        assert(r.tool.prepareParamChanged(r.context, r.layer,
            GpuUploadOwner.fakeForTest(&r.gpu)).accepted);
        foreach (ref p; r.tool.params()) if (p.name == name) {
            if (name == "applied") *p.bptr = false; else *p.iptr = 1;
        }
        assert(!r.context.validate(),
            "M3b: a prepared bevel update validated over a changed " ~ name);
    }
}

// Vertex Bevel / Vertex Extrude: a zero-width preview still enlists the full
// preview transaction but installs no geometry and leaves `built` false.
unittest {
    static foreach (R; AliasSeq!(VertexBevelRow, VertexExtrudeRow)) {{
        auto z = Rig!R.make(true, true);
        static if (is(R == VertexBevelRow))
            z.tool.seedPreparedParamForTest(z.layer.meshRef(), true, 0.0f);
        else
            z.tool.seedPreparedParamForTest(z.layer.meshRef(), true, 1.0f, 0.0f);
        z.context.setResourceIdentity(7, 11);
        auto zero = z.tool.prepareParamChanged(z.context, z.layer,
            GpuUploadOwner.fakeForTest(&z.gpu));
        assert(zero.accepted && zero.kind == R.Kind.Preview && z.context.validate());
        z.context.install();
        assert(z.layer.meshRef().vertices.length == 8 && !R.built(z.tool) &&
            z.context.installTraceForTest() == [3,4,43,2,8],
            R.Tool.stringof ~ ": zero-width preview");
    }}
}

// Polygon Extrude: the candidate is the full cap topology at the frozen
// shift, the install selects only the cap, and every shift axis and the
// Extent frame are in the projection.
unittest {
    auto r = Rig!PolyExtrudeRow.make(true, true, new CommandHistory());
    r.tool.mutatePreparedParamForTest(0.0f);
    auto sourcePositions = r.layer.meshRef().vertices.dup;
    auto sourceRing = r.layer.meshRef().faces[0].dup;
    void setShift(PolyExtrudeTool t, string name, float value) {
        bool found;
        foreach (ref p; t.params()) if (p.name == name) { *p.fptr = value; found = true; }
        assert(found, "Polygon parameter list lost " ~ name);
    }
    void expectFullCandidate(Vec3 shift) {
        auto image = r.tool.buildPreparedParamUpdate(r.layer.meshRef());
        scope(exit) image.clear();
        assert(image.valid && image.applies && image.candidate.vertices.length == 12 &&
            image.candidate.faces.length == 10 && image.candidate.edges.length == 20,
            "prepared Polygon candidate lost full cap topology");
        foreach (i, p; sourcePositions)
            assert(image.candidate.vertices[i] == p,
                "prepared Polygon candidate moved a survivor vertex");
        foreach (i, vi; sourceRing)
            assert(image.candidate.vertices[sourcePositions.length + i] ==
                sourcePositions[vi] + shift,
                "prepared Polygon candidate cap position differs from frozen parameter state");
        foreach (fi; 0 .. image.candidate.faces.length)
            assert(image.candidate.isFaceSelected(cast(uint)fi) == (fi == 9),
                "prepared Polygon candidate selection differs from frozen cap state");
    }
    setShift(r.tool, "shiftX", 0.125f);
    expectFullCandidate(Vec3(0.125f, 0, 0));
    r.context.setResourceIdentity(7, 11);
    assert(r.tool.prepareParamChanged(r.context, r.layer,
        GpuUploadOwner.fakeForTest(&r.gpu)).accepted && r.context.validate());
    r.context.install();
    assert(r.layer.meshRef().faces.length == 10 && r.layer.meshRef().isFaceSelected(9),
        "prepared Polygon parameter preview did not install the W2 walls-before-cap selection");
    assert(abs(r.layer.meshRef().faceCentroid(9).x - 0.125f) < 1e-6f,
        "prepared Polygon parameter preview lost the cap shift");
    foreach (fi; 0 .. r.layer.meshRef().faces.length)
        if (fi != 9) assert(!r.layer.meshRef().isFaceSelected(fi),
            "prepared Polygon parameter preview selected a wall or survivor");
    setShift(r.tool, "shiftY", -0.235f);
    expectFullCandidate(Vec3(0.125f, -0.235f, 0));
    setShift(r.tool, "shiftZ", 0.345f);
    expectFullCandidate(Vec3(0.125f, -0.235f, 0.345f));

    auto f = Rig!PolyExtrudeRow.make(true, true);
    f.context.setResourceIdentity(7, 11);
    assert(f.tool.prepareParamChanged(f.context, f.layer,
        GpuUploadOwner.fakeForTest(&f.gpu)).accepted);
    f.tool.mutatePreparedFrameForTest(Vec3(0, 1, 0));
    assert(!f.context.validate() && f.layer.meshRef().vertices.length == 8,
        "prepared Polygon projection omitted its frozen Extent frame");

    foreach (shiftName; ["shiftX", "shiftY", "shiftZ"]) {
        auto s = Rig!PolyExtrudeRow.make(true, true);
        s.context.setResourceIdentity(7, 11);
        assert(s.tool.prepareParamChanged(s.context, s.layer,
            GpuUploadOwner.fakeForTest(&s.gpu)).accepted);
        setShift(s.tool, shiftName, 0.25f);
        assert(!s.context.validate() && s.layer.meshRef().vertices.length == 8,
            "prepared Polygon parameter projection omitted " ~ shiftName);
    }
}
