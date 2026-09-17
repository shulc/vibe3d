module tests.unit.unified_transform_recipe_test;

// Task 6351: the four unified transform registry ids must share the production
// construction recipe while retaining independent declared defaults, live
// mesh/subject/item-target sources, undo carriers, gizmo host, and exploration
// polarity. The final source census rejects a behavior-equivalent return to a
// handwritten factory body; the preceding cells isolate the recipe mutations.

import core.exception : RangeError;
import ai.exploration : AiExplorationController;
import ai.interaction_log_writer : AiInteractionLogWriter;
import command_history : CommandHistory;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import document : Document, Layer;
import editor_app : EditorApp;
import editmode : EditMode;
import handles.arbiter : ToolHandles;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registration : buildRegisteredXfrmTransformForOwnershipTest;
import registry : Registry;
import seltype : SelType, SelMode;
import session_owner : Session;
import tests.unit.census_symbols : blankNonCode, countOccurrences;
import tools.transform.xfrm_transform : XfrmTransformTool;
import std.conv : to;
import std.file : readText;
import std.meta : AliasSeq;
import std.path : buildPath, dirName;
import std.string : indexOf;
import std.traits : BaseClassesTuple;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private immutable string[] kKeys = ["move", "rotate", "scale", "xfrm.transform"];

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name) {
                static if (is(typeof(f) : F)) return cast(F) f;
            }
    }
    assert(0, "6351 reflection floor: field not found: " ~ name);
}

private struct Rig {
    Registry registry;
    GpuMesh gpu;
    Session* session;
    Layer a, b;
    EditorApp app;
}

private Rig* makeRig() {
    auto r = new Rig;
    r.a = new Layer; r.a.name = "A"; r.a.meshRef() = makeCube();
    r.b = new Layer; r.b.name = "B"; r.b.meshRef() = makeCube();
    Document doc;
    doc.layers = [r.a, r.b];
    doc.noteLayerListChanged();
    doc.selectItem(r.a, SelMode.Set);
    r.session = Session.create(doc);
    auto s = r.session;
    ref Mesh currentMesh() { return s.document.activeMeshRef(); }
    r.app.meshDg = cast(typeof(r.app.meshDg)) &currentMesh;
    r.app.gpuPtr = &r.gpu;
    r.app.sessionOwner = r.session;
    r.app.regPtr = &r.registry;
    r.app.history = new CommandHistory();
    r.app.vxEditFactory = () => cast(MeshVertexEdit) null;
    r.app.morphEditFactory = () => cast(MeshMorphEdit) null;
    r.app.layerXformEditFactory = () => cast(LayerXformEdit) null;
    r.app.pipeGizmoHost = new PipeGizmoHost();
    r.app.aiExplore = new AiExplorationController(0, 42);
    r.app.aiLogWriter = new AiInteractionLogWriter("");
    return r;
}

private XfrmTransformTool build(Rig* r, string key) {
    XfrmTransformTool t;
    try {
        t = cast(XfrmTransformTool)
            buildRegisteredXfrmTransformForOwnershipTest(r.app, key);
    } catch (RangeError e) {
        if ((key in r.app.reg.toolFactories) !is null) throw e;
        assert(0, "6351 population: registry lacks " ~ key);
    }
    assert(t !is null,
        "6351 population: factory '" ~ key ~ "' did not build XfrmTransformTool");
    return t;
}

// Block 1: population, declarative rows, constructor equivalence.
unittest {
    auto r = makeRig();
    assert(kKeys.length == 4
        && kKeys == ["move", "rotate", "scale", "xfrm.transform"],
        "6351 population floor: the four unified transform ids");
    foreach (key; kKeys) {
        auto t1 = build(r, key);
        assert((key in r.app.reg.toolFactories) !is null,
            "6351 population: registry lacks " ~ key);
        auto t2 = r.app.reg.toolFactories[key]();
        assert(t2 !is null && t1 !is t2,
            "6351 population: fresh instance per call " ~ key);
    }

    struct Want { string key; bool t, r_, s; int h; string p; }
    immutable Want[] wants = [
        Want("move", true, false, false, 0, "full"),
        Want("rotate", false, true, false, 1, "full"),
        Want("scale", false, false, true, 2, "full"),
        Want("xfrm.transform", true, true, true, 0, "compact"),
    ];
    assert(wants.length == kKeys.length, "6351 rows floor");
    foreach (w; wants) {
        auto t = build(r, w.key);
        assert(t.flagT == w.t && t.flagR == w.r_ && t.flagS == w.s
            && t.handleFamily == w.h && t.handlePresentation == w.p,
            "6351 row " ~ w.key ~ ": T/R/S/H/presentation = "
            ~ t.flagT.to!string ~ t.flagR.to!string ~ t.flagS.to!string
            ~ " " ~ t.handleFamily.to!string ~ " " ~ t.handlePresentation);
    }

    Mesh m = makeCube(); GpuMesh g; EditMode mode;
    auto bare = new XfrmTransformTool(() => &m, &g, &mode);
    auto t = build(r, "xfrm.transform");
    assert(t.flagT == bare.flagT && t.flagR == bare.flagR && t.flagS == bare.flagS
        && t.handleFamily == bare.handleFamily
        && t.handlePresentation == bare.handlePresentation,
        "6351 ctor: the explicit xfrm.transform row diverged from the constructor defaults");
}

// Block 2: live subject, primary and item targets are read per call.
unittest {
    auto r = makeRig();
    auto doc = &r.session.document();
    foreach (key; kKeys) {
        r.session.selTypeOrder.touch(SelType.Item);
        auto t = build(r, key);
        assert(fieldOf!SelType(t, "cachedSubjType_") == SelType.Item,
            "6351 subject: ctor did not seed from the live source " ~ key);
        r.session.selTypeOrder.touch(SelType.Polygon);
        auto src = fieldOf!(SelType delegate())(t, "selTypeSrc_");
        assert(src !is null && src() == SelType.Polygon,
            "6351 subject not live " ~ key);

        doc.selectItem(r.a, SelMode.Set);
        t = build(r, key);
        assert(t.preparedMeshForUpdate() is &r.a.meshRef(),
            "6351 primary floor " ~ key);
        doc.selectItem(r.b, SelMode.Set);
        assert(t.preparedMeshForUpdate() is &r.b.meshRef(),
            "6351 primary: factory froze the mesh at construction " ~ key);

        doc.selectItem(r.a, SelMode.Set);
        t = build(r, key);
        auto items = fieldOf!(void delegate(ref Layer[]))(t, "itemTargetsSrc_");
        assert(items !is null,
            "6351 items floor: no live item-target source " ~ key);
        Layer[] buf;
        items(buf);
        assert(buf.length == 1 && buf[0] is r.a, "6351 items floor " ~ key);
        doc.selectItem(r.b, SelMode.Set);
        items(buf);
        assert(buf.length == 1 && buf[0] is r.b,
            "6351 items (a) snapshot " ~ key);
        doc.selectItem(r.a, SelMode.Add);
        assert(doc.primary is r.b && doc.focusedItem is r.a,
            "6351 items rig: Add must keep B as the target and focus A");
        items(buf);
        assert(buf.length == 2 && buf[0] is r.a && buf[1] is r.b,
            "6351 items (b) set: expected {A,B}, got "
            ~ buf.length.to!string ~ " " ~ key);
    }
}

// Block 3: the undo carrier and stable references, by identity.
unittest {
    auto r = makeRig();
    foreach (key; kKeys) {
        auto t = build(r, key);
        assert(fieldOf!CommandHistory(t, "history") is r.app.history,
            "6351 carrier history " ~ key);
        assert(fieldOf!(MeshVertexEdit delegate())(t, "vertexEditFactory")
                is r.app.vxEditFactory,
            "6351 carrier vx " ~ key);
        assert(fieldOf!(MeshMorphEdit delegate())(t, "morphEditFactory")
                is r.app.morphEditFactory,
            "6351 carrier morph " ~ key);
        assert(fieldOf!(LayerXformEdit delegate())(t, "layerXformEditFactory_")
                is r.app.layerXformEditFactory,
            "6351 carrier item " ~ key);
        assert(fieldOf!PipeGizmoHost(t, "pipeGizmoHost") is r.app.pipeGizmoHost,
            "6351 carrier host " ~ key);
        assert(fieldOf!(GpuMesh*)(t, "gpu") is r.app.gpuPtr, "6351 gpu " ~ key);
        assert(fieldOf!(EditMode*)(t, "editMode") is &r.session.editMode(),
            "6351 mode " ~ key);
    }
}

// Block 4: exploration silent-hover flag, all four polarities.
unittest {
    import std.file : exists, remove, tempDir;
    import std.process : thisProcessID;
    auto r = makeRig();
    immutable logPath = buildPath(tempDir(),
        "vibe3d_6351_explore_" ~ thisProcessID.to!string ~ ".jsonl");
    static void cleanup(string p) {
        try { if (exists(p)) remove(p); } catch (Exception) {}
    }
    cleanup(logPath);
    scope (exit) cleanup(logPath);

    bool silent(string key, bool explore, bool log) {
        r.app.aiExplore = new AiExplorationController(explore ? 0.5f : 0.0f, 42);
        auto writer = new AiInteractionLogWriter(log ? logPath : "");
        scope (exit) writer.close();
        assert(writer.enabled == log && r.app.aiExplore.enabled == explore,
            "6351 explore rig floor");
        r.app.aiLogWriter = writer;
        auto t = build(r, key);
        return fieldOf!bool(fieldOf!ToolHandles(t, "toolHandles"),
            "aiExploreSilent");
    }
    foreach (key; kKeys) {
        assert(!silent(key, false, false), "6351 explore off/off " ~ key);
        assert(!silent(key, true, false), "6351 explore on/off " ~ key);
        assert(!silent(key, false, true), "6351 explore off/on " ~ key);
        assert(silent(key, true, true), "6351 explore on/on " ~ key);
    }
}

private string bodyAt(string code, string marker) {
    immutable at = code.indexOf(marker);
    assert(at >= 0, "6351 census missing marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "6351 census body unterminated " ~ marker);
}

// Block 5: source census — registration uses the helper; this witness does not
// build an analogue of it.
unittest {
    immutable reg = blankNonCode(readText(
        buildPath(repoRoot, "source", "registration.d")));
    immutable fam = bodyAt(reg,
        "private void registerTransformTools(EditorApp app)");
    assert(countOccurrences(fam, "typedToolFactory!XfrmTransformTool(") == 4,
        "6351 census floor: four typed unified-transform entries");
    assert(countOccurrences(fam, "buildUnifiedTransform(") == 4
        && countOccurrences(fam, "new XfrmTransformTool(") == 0,
        "6351 census: every unified-transform entry must build through the helper");
    immutable helper = bodyAt(reg,
        "private XfrmTransformTool buildUnifiedTransform(");
    foreach (needle; ["new XfrmTransformTool(", "setUndoBindings(",
                      "setItemUndoFactory(", "setPipeGizmoHost(",
                      "setAiExploreSilentHover("])
        assert(countOccurrences(helper, needle) == 1,
            "6351 census helper: " ~ needle);
    assert(countOccurrences(reg, "new XfrmTransformTool(") == 1
        && countOccurrences(reg, "buildUnifiedTransform(") == 5,
        "6351 census: one construction site and four helper calls in registration.d");

    immutable self = blankNonCode(readText(__FILE_FULL_PATH__));
    assert(countOccurrences(self,
            "buildRegisteredXfrmTransformForOwnershipTest(") >= 1
        && countOccurrences(self, "new XfrmTransformTool(") == 1
        && countOccurrences(self, "setItemUndoFactory(") == 0
        && countOccurrences(self, "setUndoBindings(") == 0
        && countOccurrences(self, "itemTransformTargets(") == 0,
        "6351 census: the witness must drive the production factory, not an analogue");
}
