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
import prepared_param_update : PreparedParamUpdateOwner;
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
import tools.edit.poly_inset_tool : PolyInsetTool, PreparedPolyInsetParamImage;
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
    static void seed(Tool t, ref Mesh m, bool i) { t.seedPreparedParamForTest(m, i); }
    enum builtBefore = false;   // a row's own declaration overrides it
}
private struct PolyInsetRow {
    mixin LitRow!(PolyInsetTool, PreparedPolyInsetParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct PolyBevelRow {
    mixin LitRow!(PolyBevelTool, PreparedPolyBevelParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamInstalledForTest(); }
}
private struct PolyExtrudeRow {
    mixin LitRow!(PolyExtrudeTool, PreparedPolyExtrudeParamKind, EditMode.Polygons,
        pickFace, vertexCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct EdgeBevelRow {
    mixin LitRow!(EdgeBevelTool, PreparedEdgeBevelParamKind, EditMode.Edges,
        pickEdge, vertexCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamInstalledForTest(); }
}
private struct EdgeExtrudeRow {
    mixin LitRow!(EdgeExtrudeTool, PreparedEdgeExtrudeParamKind, EditMode.Edges,
        pickEdge, vertexCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct ReductionRow {
    mixin LitRow!(ReductionTool, PreparedReductionParamKind, EditMode.Polygons,
        triangulateAll, faceCount, -1, 0.25f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct SmoothShiftRow {
    mixin LitRow!(SmoothShiftTool, PreparedSmoothShiftParamKind, EditMode.Polygons,
        pickFace, faceCount, 1, 17.0f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
    enum builtBefore = true;   // its seed marks an interactive preview built
}
private struct VertexMergeRow {
    mixin LitRow!(VertexMergeTool, PreparedVertexMergeParamKind, EditMode.Vertices,
        pickTwoVertices, vertexCount, -1, 0.25f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct VertexBevelRow {
    mixin LitRow!(VertexBevelTool, PreparedVertexBevelParamKind, EditMode.Vertices,
        pickVertex, vertexCount, 1, 0.4f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
}
private struct VertexExtrudeRow {
    mixin LitRow!(VertexExtrudeTool, PreparedVertexExtrudeParamKind, EditMode.Vertices,
        pickVertex, vertexCount, 1, 0.4f);
    static bool built(Tool t) { return t.preparedParamBuiltForTest(); }
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

/// Every row runs every cell; a failed cell is collected, not thrown, so ONE
/// red line names each row a shared-owner mutation breaks.
unittest {
    import std.array : join;
    size_t rows; string[] bad;
    void check(bool ok, string cell) { if (!ok) bad ~= cell; }
    // A refused prepare discards its transaction: the context takes nothing
    // more (and is never validated while still open).
    bool closed(PreparedRecordContext c) { return !c.markNoHistoryInstall() && !c.validate(); }
    static foreach (R; kRows) {{
        enum name = R.Tool.stringof;
        // Preview install: nothing moves until the context installs, then the
        // candidate lands once (a second install is a no-op) in trace order.
        auto p = Rig!R.make(true, true, new CommandHistory());
        p.context.setResourceIdentity(7, 11);
        const before = R.count(p.layer.meshRef());
        auto effect = p.tool.prepareParamChanged(p.context, p.layer,
            GpuUploadOwner.fakeForTest(&p.gpu));
        check(effect.accepted && effect.kind == R.Kind.Preview, name ~ ": preview refused");
        check(R.count(p.layer.meshRef()) == before && R.built(p.tool) == R.builtBefore,
            name ~ ": preview wrote before install");
        check(p.context.validate(), name ~ ": preview did not validate");
        p.context.install(); p.context.install();
        check((R.previewSign > 0 ? R.count(p.layer.meshRef()) > before
                : R.count(p.layer.meshRef()) < before) && R.built(p.tool),
            name ~ ": preview install did not land");
        check(p.context.installTraceForTest() == [3,4,43,2,8],
            name ~ ": preview install trace");

        // Noop install: a non-interactive edit enlists the slot and NoHistory only.
        auto n = Rig!R.make(false, false);
        const cube = R.count(n.layer.meshRef());
        auto noop = n.tool.prepareParamChanged(n.context, n.layer, null);
        check(noop.accepted && noop.kind == R.Kind.Noop && n.context.validate(),
            name ~ ": noop refused");
        n.context.install();
        check(R.count(n.layer.meshRef()) == cube &&
            n.context.installTraceForTest() == [43,8], name ~ ": noop install");

        // Stale image: a parameter write after prepare is refused at validate.
        auto s = Rig!R.make(true, true);
        s.context.setResourceIdentity(7, 11);
        const staleBefore = R.count(s.layer.meshRef());
        check(s.tool.prepareParamChanged(s.context, s.layer,
            GpuUploadOwner.fakeForTest(&s.gpu)).accepted, name ~ ": stale prepare");
        R.stale(s.tool);
        check(!s.context.validate(), name ~ ": a stale image validated");
        check(R.count(s.layer.meshRef()) == staleBefore, name ~ ": stale wrote");

        // Foreign GPU: an upload owner for another GpuMesh refuses the prepare.
        auto w = Rig!R.make(true, true);
        w.context.setResourceIdentity(7, 11);
        const wrongBefore = R.count(w.layer.meshRef());
        GpuMesh foreignGpu;
        auto wrong = w.tool.prepareParamChanged(w.context, w.layer,
            GpuUploadOwner.fakeForTest(&foreignGpu));
        check(!wrong.accepted && closed(w.context) &&
            R.count(w.layer.meshRef()) == wrongBefore, name ~ ": foreign GPU accepted");

        // Refusals before the slot: no context, no upload owner for a preview,
        // no layer, a layer whose mesh the tool does not edit.
        auto q = Rig!R.make(true, true);
        q.context.setResourceIdentity(7, 11);
        auto noContext = q.tool.prepareParamChanged(null, q.layer,
            GpuUploadOwner.fakeForTest(&q.gpu));
        check(!noContext.accepted && noContext.kind == R.Kind.None,
            name ~ ": accepted without a context");
        check(!q.tool.prepareParamChanged(q.context, q.layer, null).accepted &&
            closed(q.context), name ~ ": preview accepted without an upload owner");
        auto foreignLayer = new Layer; foreignLayer.meshRef() = makeCube();
        foreach (layer; [null, foreignLayer]) {
            auto f = Rig!R.make(true, true);
            f.context.setResourceIdentity(7, 11);
            auto refused = f.tool.prepareParamChanged(f.context, layer,
                GpuUploadOwner.fakeForTest(&f.gpu));
            check(!refused.accepted && refused.kind == R.Kind.None && closed(f.context),
                name ~ (layer is null ? ": accepted a null layer" : ": accepted a foreign layer"));
        }
        ++rows;
    }}
    assert(rows == 11, "prepared param-update table lost a row");
    assert(bad.length == 0, bad.join("; "));
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

// The owner's own transaction order, on one instantiation (the body is shared):
// prepare refuses a missing target or layer; validate needs begin; begin,
// validate and install each happen once; abort and install consume the owner.
unittest {
    alias O = PreparedParamUpdateOwner!(PolyInsetTool, PreparedPolyInsetParamImage,
        PreparedPolyInsetParamKind);
    auto r = Rig!PolyInsetRow.make(true, true);
    assert(O.prepare(null, r.layer) is null && O.prepare(r.tool, null) is null,
        "owner prepared without a target or layer");
    auto o = O.prepare(r.tool, r.layer);
    assert(o !is null && o.applies && o.effectKind == PreparedPolyInsetParamKind.Preview);
    o.install();
    assert(!r.tool.preparedParamBuiltForTest(), "owner installed before validate");
    assert(!o.validate(), "owner validated before begin");
    assert(o.begin() && !o.begin(), "owner began twice");
    o.install();
    assert(!r.tool.preparedParamBuiltForTest(), "owner installed before validate");
    assert(o.validate() && !o.validate(), "owner validated twice");
    o.install();
    assert(r.tool.preparedParamBuiltForTest() &&
        o.effectKind == PreparedPolyInsetParamKind.None, "owner install did not consume");
    assert(!o.begin(), "a consumed owner began again");

    auto a = Rig!PolyInsetRow.make(true, true);
    auto aborted = O.prepare(a.tool, a.layer);
    assert(aborted.begin()); aborted.abort();
    assert(!aborted.validate() && !aborted.begin(), "an aborted owner stayed live");
    aborted.install();
    assert(!a.tool.preparedParamBuiltForTest(), "an aborted owner installed");

    // The context slot: discard aborts the enlisted owner; a validated
    // context takes no further slot.
    auto d = Rig!PolyInsetRow.make(true, true);
    auto enlisted = O.prepare(d.tool, d.layer);
    assert(d.context.prepareParamUpdate(enlisted));
    d.context.discard();
    assert(enlisted.effectKind == PreparedPolyInsetParamKind.None,
        "discard left the enlisted owner live");
    auto v = Rig!PolyInsetRow.make(true, true);
    assert(v.context.prepareParamUpdate(O.prepare(v.tool, v.layer)) &&
        v.context.markNoHistoryInstall() && v.context.validate());
    assert(!v.context.prepareParamUpdate(O.prepare(v.tool, v.layer)),
        "a validated context enlisted another slot");

    // A throw while enlisting aborts the owner and discards the whole transaction.
    auto t = Rig!PolyInsetRow.make(true, true);
    auto thrown = O.prepare(t.tool, t.layer);
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    bool enlistThrew;
    try t.context.prepareParamUpdate(thrown); catch (Exception) enlistThrew = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(enlistThrew && thrown.effectKind == PreparedPolyInsetParamKind.None,
        "a failed enlist left the owner live");
    auto x = Rig!PolyInsetRow.make(true, true);
    x.context.setResourceIdentity(7, 11);
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    bool threw;
    try x.tool.prepareParamChanged(x.context, x.layer, GpuUploadOwner.fakeForTest(&x.gpu));
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !x.context.markNoHistoryInstall() && !x.context.validate(),
        "a failed enlist left the transaction live");
}
