module tests.unit.topology_pen_factory_bundle_test;

// Task 6352: the Topology Pen's thirteen per-gesture undo factories reach the
// tool as ONE named `TopoPenFactories` value through the PRODUCTION
// `mesh.topoPen` registration. Block 0 comes first and pins that this witness
// drives that production registration rather than an analogue of its own.
// Block 1 drives the real factory with a bundle
// whose every field is a distinct probe and checks, for every field the struct
// declares (the compiler's list, not one written here), that the tool holds
// that field's own delegate. Block 2 is the placement carrier bound by
// `setGestureBindings`, deliberately BELOW block 1: deleting that binder leaves
// block 1 green and reddens block 2. The builder's field -> wire name / scope
// rows in app.d are text, pinned by member 7 of
// tests/unit/tool_commit_seam_census_g7_test.d.

import command : Command;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.vertex_new : MeshVertexNew;
import document : Document, Layer;
import editor_app : EditorApp;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registration : registerTools;
import registry : Registry;
import seltype : SelMode;
import session_owner : Session;
import tests.unit.census_symbols : blankNonCode, countOccurrences;
import tools.edit.topology_pen : TopologyPenTool;
import tools.edit.topology_pen.defs : TopoPenFactories;
import view : View;
import std.conv : to;
import std.file : readText;
import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, FieldNameTuple;

private enum string[] kFields = [FieldNameTuple!TopoPenFactories];

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name) {
                // The `static if` can fall through when the field EXISTS but its
                // type does not convert to F, so the message below names both —
                // otherwise a type drift reads as "field not found" (6352 review).
                static if (is(typeof(f) : F)) return cast(F) f;
            }
    }
    assert(0, "6352 reflection floor: no field named " ~ name
        ~ " convertible to " ~ F.stringof ~ " on " ~ T.stringof);
}

private struct Rig {
    Registry registry;
    GpuMesh gpu;
    Session* session;
    Layer layer;
    View view;
    EditorApp app;
}

/// A probe factory whose product names the field it was bound to.
private MeshSessionEdit delegate() probe(Rig* r, string field) {
    return () => new MeshSessionEdit(&r.session.document.activeMeshRef(),
        r.view, r.session.editMode, "probe." ~ field, field);
}

private Rig* makeRig() {
    auto r = new Rig;
    r.layer = new Layer; r.layer.name = "A"; r.layer.meshRef() = makeCube();
    Document doc;
    doc.layers = [r.layer];
    doc.noteLayerListChanged();
    doc.selectItem(r.layer, SelMode.Set);
    r.session = Session.create(doc);
    r.view = new View(0, 0, 800, 600);
    auto s = r.session;
    ref Mesh currentMesh() { return s.document.activeMeshRef(); }
    ref View currentView() { return r.view; }
    r.app.meshDg = cast(typeof(r.app.meshDg)) &currentMesh;
    r.app.cameraViewDg = &currentView;
    r.app.gpuPtr = &r.gpu;
    r.app.sessionOwner = r.session;
    r.app.regPtr = &r.registry;
    r.app.history = new CommandHistory();
    r.app.vxEditFactory = () => new MeshVertexEdit(
        &r.session.document.activeMeshRef(), r.view, r.session.editMode);
    r.app.morphEditFactory = () => new MeshMorphEdit(
        &r.session.document.activeMeshRef(), r.view, r.session.editMode);
    r.app.layerXformEditFactory = () => new LayerXformEdit(
        &r.session.document.activeMeshRef(), r.view, r.session.editMode);
    r.app.pipeGizmoHost = new PipeGizmoHost;
    static foreach (f; FieldNameTuple!TopoPenFactories)
        __traits(getMember, r.app.topoPenFactories, f) = probe(r, f);
    return r;
}

private TopologyPenTool buildPen(Rig* r) {
    registerTools(r.app);
    auto factory = "mesh.topoPen" in r.app.reg.toolFactories;
    assert(factory !is null, "6352 population: registry lacks mesh.topoPen");
    auto t = cast(TopologyPenTool) (*factory)();
    assert(t !is null, "6352 population: mesh.topoPen did not build a TopologyPenTool");
    return t;
}

// Block 0: the witness drives the production factory, never its own pen. It runs
// FIRST on purpose: druntime stops a module at its first failed assert, so a red
// behaviour block below would otherwise hide this one (6352 review).
unittest {
    immutable self = blankNonCode(readText(__FILE_FULL_PATH__));
    assert(countOccurrences(self, "registerTools(") >= 1
        && countOccurrences(self, "new TopologyPenTool(") == 0
        && countOccurrences(self, "setPenFactories(") == 0
        && countOccurrences(self, "setGestureBindings(") == 0,
        "6352 census: the witness must drive the production factory, not an analogue");
}

// Block 1: every declared field reaches the tool as that field's own factory.
unittest {
    assert(kFields.length == 13,
        "6352 population floor: TopoPenFactories declares "
        ~ kFields.length.to!string ~ " factories, expected 13");
    auto r = makeRig();
    auto t = buildPen(r);
    auto held = fieldOf!TopoPenFactories(t, "factories_");
    static foreach (f; FieldNameTuple!TopoPenFactories) {{
        auto dg = __traits(getMember, held, f);
        // Null first: calling a null delegate below would crash the module
        // instead of reddening it.
        assert(dg !is null, "6352 bundle: field " ~ f ~ " reached the tool null");
        auto cmd = dg();
        assert(cmd !is null && cmd.name() == "probe." ~ f,
            "6352 bundle: field " ~ f ~ " builds "
            ~ (cmd is null ? "null" : cmd.name()));
    }}
}

// Block 2: the placement carrier, independent of the bundle above.
unittest {
    auto r = makeRig();
    auto t = buildPen(r);
    auto carrier = fieldOf!(Command delegate())(t, "gestureFactory");
    assert(carrier !is null,
        "6352 placement: setGestureBindings did not bind the per-click carrier");
    assert(cast(MeshVertexNew) carrier() !is null,
        "6352 placement: the bound carrier does not build MeshVertexNew");
    assert(fieldOf!CommandHistory(t, "history") is r.app.history,
        "6352 placement: the tool's history is not EditorApp.history");
}
