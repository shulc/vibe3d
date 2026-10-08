// Module unittests for `tools.edit.bridge_tool`, moved verbatim out of source/tools/edit/bridge_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.edit.bridge_tool_test;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import std.json : JSONValue, JSONType;
import std.conv : to;
import tools.edit.bridge_tool;
import tests.unit.fixtures : findEdge;

unittest { // Edge mode: remove=true is a safe no-op when the loop bounds
           // no existing face (the common "open hole" case — matches
           // vibe3d's pre-existing edge-mode behaviour).
    Mesh m;
    // Two disjoint square rims with NO cap faces at all — just the 4 side
    // quads connecting them (an already-open tube).
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,5u,4u]);
    m.addFace([1u,2u,6u,5u]);
    m.addFace([2u,3u,7u,6u]);
    m.addFace([3u,0u,4u,7u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        bool bothA = e[0] < 4 && e[1] < 4;
        bool bothB = e[0] >= 4 && e[1] >= 4;
        if (bothA || bothB) m.selectEdge(cast(int)ei);
    }
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "edge-mode selection must resolve");
    assert(sel.capFaces.length == 0, "no face bounds either rim on an open tube");

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p);
    assert(r.added == 4, "expected 4 new bridge quads");
    assert(!r.removed, "no cap face existed to remove");
    assert(m.faces.length == facesBefore + 4, "face count: 4 existing + 4 new");
}

unittest { // Edge mode OPEN rows (task 0395 owner repro): cube minus 2
           // adjacent faces (8v/4f), select the 4 boundary edges away from
           // the two connector edges (two 2-edge open arcs) — resolve must
           // be valid + openRows=true + capFaces EMPTY (an open chain never
           // bounds an existing face), and applyBridgeOp(spans=1) must
           // reconstruct the 2 deleted faces bit-for-bit: 8v/4f -> 8v/6f,
           // reusing the existing boundary vertices (no new verts).
    Mesh m;
    m.addVertex(Vec3(-0.5,-0.5,-0.5)); m.addVertex(Vec3(0.5,-0.5,-0.5));
    m.addVertex(Vec3(0.5,0.5,-0.5));   m.addVertex(Vec3(-0.5,0.5,-0.5));
    m.addVertex(Vec3(-0.5,-0.5,0.5));  m.addVertex(Vec3(0.5,-0.5,0.5));
    m.addVertex(Vec3(0.5,0.5,0.5));    m.addVertex(Vec3(-0.5,0.5,0.5));
    m.addFace([0u,3u,2u,1u]);
    m.addFace([4u,5u,6u,7u]);
    m.addFace([0u,4u,7u,3u]);
    m.addFace([0u,1u,5u,4u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;

    int e32 = findEdge(m, 3, 2), e21 = findEdge(m, 2, 1);
    int e56 = findEdge(m, 5, 6), e67 = findEdge(m, 6, 7);
    assert(e32 >= 0 && e21 >= 0 && e56 >= 0 && e67 >= 0,
        "owner repro: all 4 boundary edges must exist on the fixture mesh");
    m.selectEdge(e32); m.selectEdge(e21);
    m.selectEdge(e56); m.selectEdge(e67);

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "owner repro: two open rows must resolve valid (was a silent no-op pre-0395)");
    assert(sel.openRows, "owner repro: must be detected as openRows");
    assert(!sel.polygonMode, "owner repro: edge mode is not polygonMode");
    assert(sel.capFaces.length == 0,
        "owner repro: open rows never bound an existing face, expected empty capFaces, got "
        ~ sel.capFaces.length.to!string);

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length, vertsBefore = m.vertices.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p, sel.openRows);
    assert(r.added == 2, "owner repro: expected 2 new quads, got " ~ r.added.to!string);
    assert(!r.removed, "owner repro: capFaces empty, nothing to remove");
    assert(m.faces.length == facesBefore + 2,
        "owner repro: expected 8v/6f (4+2 quads), got " ~ m.faces.length.to!string ~ " faces");
    assert(m.vertices.length == vertsBefore,
        "owner repro: bridge must reuse existing boundary verts, no new verts");

    // Winding-consistency (task 0395 rr-refinement): each new bridge face
    // must traverse any edge it shares with a PRE-EXISTING face in the
    // OPPOSITE direction — the same half-edge manifold invariant
    // `orientFaceConsistent` enforces for `makePolygonFromVerts` (task
    // 0394), now reused by `bridgeStripPaired`/`bridgeFanRows`. A
    // same-direction shared edge would corrupt the half-edge fan there —
    // this is exactly the connected-topology case the owner repro exercises
    // (both new quads border two of the cube's 4 remaining original faces).
    bool sharesEdgeSameDirection(const(uint)[] a, const(uint)[] b) {
        foreach (i; 0 .. a.length) {
            uint u = a[i], v = a[(i + 1) % a.length];
            foreach (k; 0 .. b.length) {
                uint p = b[k], q = b[(k + 1) % b.length];
                if (u == p && v == q) return true;
            }
        }
        return false;
    }
    foreach (nfi; facesBefore .. m.faces.length)
        foreach (ofi; 0 .. facesBefore)
            assert(!sharesEdgeSameDirection(m.faces[nfi], m.faces[ofi]),
                "owner repro: new face " ~ nfi.to!string ~ " traverses a shared edge in the "
                ~ "SAME direction as pre-existing face " ~ ofi.to!string ~ " (winding corruption)");
}

unittest { // Edge mode: mixed open+closed selection is a safe no-op
           // (deferred, task 0395) — resolve must report invalid, not crash
           // or silently pick one interpretation.
    Mesh m;
    // Open chain: verts 0-1-2.
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    // Closed cycle: verts 3-4-5-6.
    m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0));
    m.addVertex(Vec3(1,2,0)); m.addVertex(Vec3(0,2,0));
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.addEdge(3, 4); m.addEdge(4, 5); m.addEdge(5, 6); m.addEdge(6, 3);
    m.buildLoops();
    m.resizeEdgeSelection();
    foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(!sel.valid, "mixed open+closed selection must resolve invalid (no-op), not pick a side");
}

unittest {
    import commands.tool.attr : ToolAttrCommand;
    import commands.tool.host : ToolHost;
    import params : injectParamsInto;
    import edit_session : EditSession;
    import view : View;
    Mesh m; View v;
    Tool t = new BridgeTool(null, null, null, null);
    auto history = new CommandHistory;
    auto session = new EditSession(() => t, history, () {});
    ToolHost host;
    host.getActiveTool = () => t;
    host.getActiveToolId = () => "mesh.bridgeTool";
    host.session = () => session;
    auto c = new ToolAttrCommand(&m, v, EditMode.Edges, host);
    auto args = JSONValue.emptyObject;
    args["tool"] = JSONValue("mesh.bridgeTool");
    args["attr"] = JSONValue("uvs");
    args["value"] = JSONValue("3");
    injectParamsInto(c.params(), args);
    assert(c.apply(), "tool.attr connected accepted");
    auto ps = t.params();
    assert(*ps[8].iePtr == 0, "tool.attr connected UV storage coerced to none");
    args["value"] = JSONValue("1");
    injectParamsInto(c.params(), args);
    assert(c.apply(), "tool.attr U accepted");
    assert(*ps[8].iePtr == 1 && t.toolStateJson()["uvs"].integer == 1, "tool.attr U persists");
    args["value"] = JSONValue("2");
    injectParamsInto(c.params(), args);
    assert(c.apply() && *ps[8].iePtr == 2, "tool.attr V persists");
}

unittest {
    import params : paramToJson, injectParamsInto, stickyParseInto;
    auto t = new BridgeTool(null, null, null, null);
    auto ps = t.params();
    string[] names = ["segments", "twist", "mode", "tension", "connect", "remove",
        "flip", "orient", "uvs", "autoStep", "steps", "continuous"];
    string[] labels = ["Segments", "Twist", "Mode", "Tension", "Auto Connection",
        "Remove Polygons", "Flip Polygons", "Orient", "UVs", "Automatic", "Steps", "Continuous"];
    Param.Kind[] kinds = [Param.Kind.Int, Param.Kind.Float, Param.Kind.IntEnum,
        Param.Kind.Float, Param.Kind.Bool, Param.Kind.Bool, Param.Kind.Bool,
        Param.Kind.Bool, Param.Kind.IntEnum, Param.Kind.Bool, Param.Kind.Int, Param.Kind.Bool];
    assert(ps.length == 12, "bridge schema twelve attrs");
    foreach (i, ref p; ps) {
        assert(p.name == names[i] && p.label == labels[i] && p.kind == kinds[i],
            "bridge schema order labels kinds " ~ names[i]);
        assert(t.paramEnabled(p.name), "bridge ordinary attrs enabled");
    }
    assert(ps[0].default_.i == 1 && *ps[0].iptr == 1, "segments factory default");
    assert(ps[1].default_.f == 0 && *ps[1].fptr == 0, "twist factory default");
    assert(ps[2].default_.i == 1 && *ps[2].iePtr == 1, "mode factory default");
    assert(ps[3].default_.f == 1 && *ps[3].fptr == 1, "tension factory default");
    foreach (i; [4,5,9,11]) assert(ps[i].default_.b && *ps[i].bptr, "true factory default");
    foreach (i; [6,7]) assert(!ps[i].default_.b && !*ps[i].bptr, "false factory default");
    assert(ps[8].default_.i == 0 && *ps[8].iePtr == 0, "UV factory default");
    assert(ps[10].default_.i == 10 && *ps[10].iptr == 10, "steps factory default");
    assert(ps[2].intEnumValues.length == 3 && ps[8].intEnumValues.length == 4,
        "bridge enum choice populations");
    foreach (i, e; ps[8].intEnumValues) {
        assert(e.value == i && e.wireTag == ["none", "u", "v", "connected"][i] &&
            e.userLabel == ["None", "U", "V", "Connected"][i], "UV wire and visible choice identity");
    }
    auto j = t.toolStateJson();
    foreach (n; names) assert(n in j.object, "state missing " ~ n);
    assert(j["mode"].integer == 1 && j["tension"].floating == 1 &&
        j["connect"].type == JSONType.true_ && j["steps"].integer == 10,
        "state reports stored factory values");
    assert(j["effectiveSegments"].uinteger == 0 && j["twistRefused"].type == JSONType.false_,
        "inactive state effective segments and refusal");
    auto input = JSONValue.emptyObject;
    input["uvs"] = JSONValue(3);
    injectParamsInto(ps, input);
    assert(*ps[8].iePtr == 3, "JSON bypass stores connected");
    assert(t.toolStateJson()["uvs"].integer == 0, "JSON connected UV read mask");
    assert(stickyParseInto(ps[8], "connected"), "sticky connected accepted");
    assert(*ps[8].iePtr == 3 && t.toolStateJson()["uvs"].integer == 0, "sticky connected UV read mask");
    assert(t.prepareDoorParamChanged("uvs", null, null, 0, 0), "prepared UV hook accepted");
    assert(*ps[8].iePtr == 0, "interactive prepared UV coercion");
    input["orient"] = JSONValue(true);
    input["continuous"] = JSONValue(false);
    input["autoStep"] = JSONValue(false);
    input["connect"] = JSONValue(false);
    input["mode"] = JSONValue(2);
    input["tension"] = JSONValue(0.25);
    input["steps"] = JSONValue(0);
    injectParamsInto(ps, input);
    assert(*ps[10].iptr == 1, "steps declared floor enforced");
    j = t.toolStateJson();
    assert(j["orient"].type == JSONType.true_, "state orient stored");
    assert(j["continuous"].type == JSONType.false_, "state continuous stored");
    assert(j["autoStep"].type == JSONType.false_, "state autoStep stored");
    assert(j["connect"].type == JSONType.false_, "state connect stored");
    assert(j["mode"].integer == 2, "state mode stored");
    assert(j["tension"].floating == 0.25, "state tension stored");
    assert(j["steps"].integer == 1, "state steps stored");
    *ps[1].fptr = 1;
    assert(t.toolStateJson()["twistRefused"].type == JSONType.false_,
        "inactive closed twist not refused");
}

unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    auto root = __FILE_FULL_PATH__.dirName.dirName.dirName.dirName.dirName;
    auto source = readText(buildPath(root, "source/tools/edit/bridge_tool.d"));
    foreach (term; ["cachedMode     == params_.mode", "cachedTension  == params_.tension",
        "cachedConnect  == params_.connect", "cachedAutoStep == params_.autoStep",
        "cachedMode       = params_.mode", "cachedTension    = params_.tension",
        "cachedConnect    = params_.connect", "cachedAutoStep   = params_.autoStep",
        "lastEffectiveSegments_ = rebuildBridgePreview(", "lastEffectiveSegments_ = res.effectiveSegments",
        "cachedMode = params_.mode;", "cachedTension = params_.tension;",
        "cachedConnect = params_.connect;", "cachedAutoStep = params_.autoStep;"])
        assert(source.indexOf(term) >= 0, "production bridge preview wiring " ~ term);
}

unittest {
    import mesh_gpu : GpuMesh;
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(1,1,1)]) m.addVertex(p);
    m.addFace([0u,1u,2u]); m.addFace([3u,4u,5u]); m.buildLoops();
    m.resizeEdgeSelection();
    foreach (pair; [[0u,1u], [1u,2u], [3u,4u], [4u,5u]])
        m.selectEdge(findEdge(m, pair[0], pair[1]));
    EditMode mode = EditMode.Edges;
    GpuMesh gpu; gpu.suppressCageUpload = true;
    auto t = new BridgeTool(() nothrow @nogc => &m, &gpu, null, &mode);
    auto ps = t.params();
    *ps[0].iptr = 3; *ps[4].bptr = false;
    Mesh* source;
    auto image = t.buildPreparedActivation(source);
    assert(image.valid && image.selectionValid && image.openRows && image.preview.faces.length == 8,
        "prepared activation open preview population");
    assert(image.effectiveSegments == 3, "prepared activation carries effective segments");
    t.installPreparedActivation(image);
    auto j = t.toolStateJson();
    assert(j["effectiveSegments"].uinteger == 3 && j["openRows"].type == JSONType.true_,
        "prepared activation installs effective segments");
    assert(j["twistRefused"].type == JSONType.false_, "open zero twist not refused");
    *ps[1].fptr = 1;
    assert(t.toolStateJson()["twistRefused"].type == JSONType.true_, "open twist state refusal");
    auto refused = t.buildPreparedActivation(source);
    assert(refused.preview.faces.length == 2 && refused.effectiveSegments == 0,
        "open twist prepared preview baseline and zero effective");
}

unittest { // Prepared result metadata publishes only with its owning commit.
    import document : Layer;
    import mesh_gpu : GpuMesh, GpuUploadOwner, GpuResourceOwner;
    import prepared_record_context : PreparedRecordContext;
    import prepared_bridge_activation : PreparedBridgeDeactivateOwner;
    import record_observer_hub : RecordObserverHub;
    import params : injectParamsInto;
    import view : View;
    import mesh_ops.bridge : kBridgeEditScope;
    import mesh_edit_delta : MeshEditScope;
    class Rig {
        Layer layer;
        GpuMesh gpu;
        EditMode mode = EditMode.Edges;
        View view;
        BridgeTool t;
        CommandHistory history;
        this() {
            layer = new Layer;
            auto m = &layer.meshRef();
            foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0),
                         Vec3(0,0,1), Vec3(1,0,1), Vec3(1,1,1)]) m.addVertex(p);
            m.addFace([0u,1u,2u]); m.addFace([3u,4u,5u]); m.buildLoops();
            m.resizeEdgeSelection();
            foreach (pair; [[0u,1u], [1u,2u], [3u,4u], [4u,5u]])
                m.selectEdge(findEdge(*m, pair[0], pair[1]));
            t = new BridgeTool(() nothrow @nogc => &layer.meshRef(), &gpu, null, &mode);
            auto input = JSONValue.emptyObject;
            input["segments"] = JSONValue(3); input["connect"] = JSONValue(false);
            injectParamsInto(t.params(), input);
            Mesh* source;
            auto image = t.buildPreparedActivation(source);
            t.installPreparedActivation(image);
            assert(t.seedPreparedDeactivateCommitForTest(), "prepared fake engaged selection");
            history = new CommandHistory;
            t.setGestureBindings(history, () => new MeshSessionEdit(&layer.meshRef(), view,
                mode, "mesh.bridge_edit", "Bridge", cast(MeshEditScope)kBridgeEditScope));
        }
        PreparedRecordContext prepare() {
            auto c = new PreparedRecordContext(history, new RecordObserverHub);
            c.setResourceIdentity(7, 11);
            assert(t.prepareDeactivate(c, layer, GpuUploadOwner.fakeForTest(&gpu),
                GpuResourceOwner.fakeForTest(t.preparedPreviewGpu())).resourceAccepted,
                "prepared drop resources accepted");
            return c;
        }
        uint cached() { return cast(uint)t.toolStateJson()["effectiveSegments"].uinteger; }
        void injectFresh() {
            auto p = JSONValue.emptyObject; p["segments"] = JSONValue(5);
            injectParamsInto(t.params(), p);
            Mesh candidate; MeshSnapshot.capture(layer.meshRef()).restore(candidate);
            auto selection = resolveBridgeSelection(candidate, mode);
            BridgeParams params; params.segments = 5; params.connect = false;
            auto result = applyBridgeOp(candidate, selection.loopA, selection.loopB,
                selection.capFaces, params, selection.openRows);
            assert(cached() == 3 && result.effectiveSegments == 5 && result.added == 10,
                "prepared metadata stale-cache discriminator before prepare");
        }
    }
    auto r = new Rig;
    r.injectFresh();
    auto commit = r.prepare();
    assert(r.cached() == 3 && r.layer.meshRef().faces.length == 2 && r.history.undoEntriesVisible().length == 0,
        "prepared result remains detached before install");
    assert(commit.validate(), "prepared metadata commit validates: " ~ commit.validateFailureReason());
    commit.install();
    assert(r.layer.meshRef().faces.length == 12 && r.history.undoEntriesVisible().length == 1,
        "prepared metadata mesh and one history row committed");
    assert(r.cached() == 5, "prepared commit installs fresh candidate effective segments");

    auto abandoned = new Rig; abandoned.injectFresh();
    auto discarded = abandoned.prepare(); discarded.discard();
    assert(abandoned.cached() == 3 && abandoned.layer.meshRef().faces.length == 2 &&
        abandoned.history.undoEntriesVisible().length == 0, "discard retains old metadata mesh history");
    auto invalid = new Rig; invalid.injectFresh();
    auto failed = invalid.prepare(); invalid.t.mutatePreparedDeactivateForTest();
    assert(!failed.validate(), "changed params refuse prepared commit");
    failed.discard();
    assert(invalid.cached() == 3 && invalid.layer.meshRef().faces.length == 2 &&
        invalid.history.undoEntriesVisible().length == 0, "failed validation retains old metadata mesh history");

    auto idle = new Rig;
    Mesh* idleSource;
    auto idleActivation = idle.t.buildPreparedActivation(idleSource);
    idle.t.installPreparedActivation(idleActivation);
    auto idleDrop = idle.prepare();
    assert(idleDrop.validate(), "idle no-candidate drop validates");
    idleDrop.install();
    assert(idle.cached() == 3 && idle.layer.meshRef().faces.length == 2 && idle.history.undoEntriesVisible().length == 0,
        "idle no-candidate drop preserves seeded metadata");
    auto idleOwner = PreparedBridgeDeactivateOwner.prepare(idle.t);
    assert(idleOwner.setEffectiveSegments(3) && idleOwner.begin() && idleOwner.validate(),
        "typed metadata owner ready");
    assert(!idleOwner.setEffectiveSegments(9), "metadata setter refuses after begin and validation");
    idleOwner.install();
    assert(!idleOwner.setEffectiveSegments(9) && idle.cached() == 3,
        "metadata setter refuses after install");
    auto abortedOwner = PreparedBridgeDeactivateOwner.prepare(new Rig().t);
    abortedOwner.abort();
    assert(!abortedOwner.setEffectiveSegments(9), "metadata setter refuses after abort");
    auto pendingOwner = PreparedBridgeDeactivateOwner.prepare(new Rig().t);
    assert(pendingOwner.begin(), "metadata pending owner began");
    assert(!pendingOwner.setEffectiveSegments(9), "metadata setter refuses pending before validate");
    pendingOwner.abort();
}
