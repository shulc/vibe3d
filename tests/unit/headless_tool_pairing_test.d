module tests.unit.headless_tool_pairing_test;

// Task 6353: Generator and Primitive headless commands are paired with their
// tools by the production registration helper. The source census proves the
// old four-spelling channel is gone; the registry blocks prove population,
// command-negative exceptions, invocation-time lookup, and concrete products.

import command : Command;
import command_history : CommandHistory;
import commands.tool.headless : ToolHeadlessCommand;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import document : Document, Layer;
import editmode : EditMode;
import editor_app : EditorApp;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import params : Param;
import pipe_gizmo_host : PipeGizmoHost;
import registration : registerTools;
import registry : Registry, ToolFactory;
import seltype : SelMode;
import session_owner : Session;
import tests.unit.census_symbols : balancedSpan, blankNonCode, countOccurrences;
import tool : Tool;
import tools.alignment.mirror : MirrorTool;
import tools.alignment.radial_sweep_tool : RadialSweepTool;
import tools.create.arc : ArcTool;
import tools.create.box : BoxTool;
import tools.create.capsule : CapsuleTool;
import tools.create.cone : ConeTool;
import tools.create.cylinder : CylinderTool;
import tools.create.sphere : SphereTool;
import tools.create.torus : TorusTool;
import tools.create.tube : TubeTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.edit.tack : TackTool;
import tools.edit.topology_pen.defs : TopoPenFactories;
import view : View;

import std.algorithm : map, sort;
import std.array : array;
import std.conv : to;
import std.file : readText;
import std.meta : AliasSeq;
import std.path : buildPath, dirName;
import std.string : indexOf;
import std.traits : BaseClassesTuple, FieldNameTuple;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum string[] kPaired = [
    "prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cylinder",
    "prim.tube", "prim.cone", "prim.capsule", "prim.torus", "prim.arc",
    "mesh.mirrorTool", "mesh.radialSweepTool", "mesh.tack", "mesh.bridgeTool",
];

private enum string[] kToolOnly = ["pen", "prim.vertex", "mesh.topoPen"];

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(typeof(f) : F)) return cast(F) f;
    }
    assert(0, "6353 reflection floor: no field named " ~ name
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

private Rig* makeRig() {
    auto r = new Rig;
    r.layer = new Layer;
    r.layer.name = "A";
    r.layer.meshRef() = makeCube();
    Document doc;
    doc.layers = [r.layer];
    doc.noteLayerListChanged();
    doc.selectItem(r.layer, SelMode.Set);
    r.session = Session.create(doc);
    r.view = new View(0, 0, 800, 600);
    auto session = r.session;
    ref Mesh currentMesh() { return session.document.activeMeshRef(); }
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
    r.app.bevelEditFactory = () => null;
    static foreach (f; FieldNameTuple!TopoPenFactories)
        __traits(getMember, r.app.topoPenFactories, f) = () => null;
    return r;
}

private final class MarkerTool : Tool {
    int marker;
    this(int value) { marker = value; }
    override Param[] params() {
        return [Param.int_("pairMarker", "Pair Marker", &marker, marker)];
    }
}

private alias ProductCheck = bool function(Tool);
private bool isProduct(T)(Tool tool) { return cast(T) tool !is null; }
private struct ProductRow {
    string id;
    string expected;
    ProductCheck matches;
}

// Block 0: prove every behavioural block below drives production registration,
// and pin the disappearance of the old four-spelling channel before any object
// construction can fail first.
unittest {
    immutable self = blankNonCode(readText(__FILE_FULL_PATH__));
    assert(countOccurrences(self, "registerTools(") == 4
        && countOccurrences(self, "new ToolHeadlessCommand(") == 0
        && countOccurrences(self, "registerHeadlessTool!") == 0
        && countOccurrences(self, "reg.commandFactories[") == 0,
        "6353 self-census: the witness must drive production registration");

    immutable rawRegistration = readText(
        buildPath(repoRoot, "source", "registration.d"));
    immutable rawCreate = readText(
        buildPath(repoRoot, "source", "create_tool_registration.d"));
    enum registrationCommentDecoy = "// new ToolHeadlessCommand(\n";
    enum structuralCommentDecoy =
        "// registerHeadlessTool! private void registerHeadlessTool( "
      ~ "new ToolHeadlessCommand(\n";
    immutable registration = blankNonCode(
        rawRegistration ~ registrationCommentDecoy);
    immutable create = blankNonCode(rawCreate ~ structuralCommentDecoy);
    assert(rawRegistration.length > 50_000,
        "6353 source population: registration.d is unexpectedly small");
    assert(rawCreate.length > 8_000,
        "6353 source population: create_tool_registration.d is unexpectedly small");

    assert(countOccurrences(registration, "new ToolHeadlessCommand(") == 3,
        "6353 wrapper population: expected three residual Convolve wrappers");
    assert(countOccurrences(registration, "registerHeadlessTool!") == 0,
        "6353 old path: paired helper calls survived in registration.d");
    assert(countOccurrences(registration,
            "private void registerHeadlessTool(") == 0,
        "6353 old path: paired helper survived in registration.d");

    assert(countOccurrences(create, "registerHeadlessTool!") == 13,
        "6353 source population: expected 13 paired helper calls");
    assert(countOccurrences(create, "private void registerHeadlessTool(") == 1,
        "6353 helper population: expected one private registerHeadlessTool");
    assert(countOccurrences(create, "new ToolHeadlessCommand(") == 1,
        "6353 wrapper population: expected one create-family wrapper recipe");

    string spanAt(string marker, string label) {
        const at = create.indexOf(marker);
        assert(at >= 0, "6353 " ~ label ~ " slice floor: marker vanished: " ~ marker);
        const brace = create[cast(size_t) at .. $].indexOf('{');
        assert(brace >= 0, "6353 " ~ label ~ " slice floor: body opener vanished");
        const span = balancedSpan(
            create, cast(size_t) at + cast(size_t) brace, '{', '}');
        assert(span.length != 0, "6353 " ~ label
            ~ " slice floor: balancedSpan returned an empty span for marker "
            ~ marker);
        return span;
    }

    const helper = spanAt("private void registerHeadlessTool(", "helper");
    const generator = spanAt("private void registerGeneratorTools(", "generator");
    const primitive = spanAt("private void registerPrimitiveTools(", "primitive");
    assert(countOccurrences(helper,
            "reg.toolFactories[id] = typedToolFactory!T(") == 1,
        "6353 helper: typed tool write must occur exactly once");
    assert(countOccurrences(helper, "reg.commandFactories[id] = ") == 1,
        "6353 helper: command write must occur exactly once");
    assert(countOccurrences(helper, "new ToolHeadlessCommand(") == 1,
        "6353 helper: wrapper construction must occur exactly once");
    assert(countOccurrences(generator, "registerHeadlessTool!") == 4,
        "6353 generator population: expected four paired calls");
    assert(countOccurrences(primitive, "registerHeadlessTool!") == 9,
        "6353 primitive population: expected nine paired calls");
    assert(countOccurrences(generator, "registerHeadlessTool!")
         + countOccurrences(primitive, "registerHeadlessTool!")
         == countOccurrences(create, "registerHeadlessTool!"),
        "6353 family reconciliation: 4 + 9 paired calls must cover all 13");

    foreach (id; kPaired) {
        foreach (raw; [rawRegistration, rawCreate]) {
            assert(countOccurrences(raw,
                    "reg.toolFactories[\"" ~ id ~ "\"] = ") == 0,
                "6353 old channel: literal tool assignment survived for " ~ id);
            assert(countOccurrences(raw,
                    "reg.commandFactories[\"" ~ id ~ "\"]") == 0,
                "6353 old channel: literal command assignment survived for " ~ id);
        }
    }
    foreach (id; kToolOnly) {
        assert(countOccurrences(rawCreate,
                "reg.toolFactories[\"" ~ id ~ "\"] = ") == 1,
            "6353 command-negative source: create tool registration moved for " ~ id);
        assert(countOccurrences(rawCreate,
                "reg, \"" ~ id ~ "\", () {") == 0,
            "6353 command-negative source: tool-only id became paired: " ~ id);
    }

    immutable app = readText(buildPath(repoRoot, "source", "app.d"));
    assert(app.indexOf("registerTools(app);") >= 0
        && app.indexOf("registerTools(app);") < app.indexOf("registerCommands(app);"),
        "6353 source order: registerTools must precede registerCommands/withSelType");
}
// Block 1: the real registry contains every pair, with the wrapper metadata
// derived from the same id.
unittest {
    static assert(kPaired.length == 13);
    auto r = makeRig();
    r.session.editMode = EditMode.Edges;
    auto firstMesh = &r.layer.meshRef();
    auto firstView = r.view;
    registerTools(r.app);
    foreach (id; kPaired) {
        assert(id in r.registry.toolFactories,
            "6353 population: registry lacks " ~ id ~ " tool factory");
        assert(id in r.registry.commandFactories,
            "6353 population: registry lacks " ~ id);
        auto cmd = r.registry.commandFactories[id]();
        assert(cmd !is null, "6353 population: null command for " ~ id);
        assert(cmd.name() == id,
            "6353 name: " ~ id ~ " wrapper reports name '" ~ cmd.name() ~ "'");
        assert(cmd.label() == "Apply " ~ id,
            "6353 label: " ~ id ~ " wrapper reports '" ~ cmd.label() ~ "'");
        assert(cmd.needsEditTarget(),
            "6353 target contract: " ~ id ~ " wrapper does not require an edit target");
        assert(cmd.meshPtr() is firstMesh,
            "6353 live role: " ~ id ~ " wrapper did not take the live Mesh");
        assert(cmd.viewRef() is firstView,
            "6353 live role: " ~ id ~ " wrapper did not take the live View");
        assert(cmd.editModeVal() == EditMode.Edges,
            "6353 live role: " ~ id ~ " wrapper did not take the live EditMode");
    }

    auto secondLayer = new Layer;
    r.session.document.layers ~= secondLayer;
    r.session.document.setPrimary(secondLayer);
    r.session.editMode = EditMode.Polygons;
    r.view = new View(0, 0, 640, 480);
    assert(&secondLayer.meshRef() !is firstMesh,
        "6353 live-role fixture: second Mesh must differ from the first");
    assert(r.view !is firstView,
        "6353 live-role fixture: second View must differ from the first");
    foreach (id; kPaired) {
        auto cmd = r.registry.commandFactories[id]();
        assert(cmd.meshPtr() is &secondLayer.meshRef(),
            "6353 live role: " ~ id ~ " wrapper retained the registration-time Mesh");
        assert(cmd.viewRef() is r.view,
            "6353 live role: " ~ id ~ " wrapper retained the registration-time View");
        assert(cmd.editModeVal() == EditMode.Polygons,
            "6353 live role: " ~ id ~ " wrapper retained the registration-time EditMode");
    }
}

// Block 2: the three interactive-only registrations stay command-negative.
unittest {
    auto r = makeRig();
    registerTools(r.app);
    foreach (id; kToolOnly) {
        assert(id in r.registry.toolFactories,
            "6353 command-negative floor: registry lacks tool " ~ id);
        assert(id !in r.registry.commandFactories,
            "6353 command-negative: " ~ id ~ " must have no command factory");
    }
}

// Block 3: replacing the tool factory after registration is observed by the
// wrapper factory when it fires. Reflection comes first so an early-capture
// mutation reddens by name before it can construct a real GL-backed tool.
unittest {
    auto r = makeRig();
    registerTools(r.app);
    foreach (i, id; kPaired) {
        immutable marker = 100 + cast(int) i;
        ToolFactory probe = () => new MarkerTool(marker);
        auto reboundFactories = r.registry.toolFactories.dup;
        reboundFactories[id] = probe;
        r.registry.toolFactories = reboundFactories;
        auto cmd = cast(ToolHeadlessCommand) r.registry.commandFactories[id]();
        assert(cmd !is null, "6353 late lookup: wrapper type changed for " ~ id);
        auto held = fieldOf!ToolFactory(cmd, "factory");
        assert(held is probe,
            "6353 late lookup: " ~ id ~ " wrapper holds the registration-time "
          ~ "factory, not the one in the registry at fire");
        auto schema = cmd.params();
        assert(schema.length == 1 && schema[0].name == "pairMarker"
            && schema[0].iptr !is null && *schema[0].iptr == marker,
            "6353 late lookup use: " ~ id ~ " did not invoke the held probe factory");
    }
}

// Block 4: each call-site body builds its reviewed product. Sphere and
// ellipsoid intentionally share a class, so the constructor flag is the only
// compiling discriminator and is asserted in both directions.
unittest {
    auto rows = [
        ProductRow("prim.cube", "BoxTool", &isProduct!BoxTool),
        ProductRow("prim.sphere", "SphereTool", &isProduct!SphereTool),
        ProductRow("prim.ellipsoid", "SphereTool", &isProduct!SphereTool),
        ProductRow("prim.cylinder", "CylinderTool", &isProduct!CylinderTool),
        ProductRow("prim.tube", "TubeTool", &isProduct!TubeTool),
        ProductRow("prim.cone", "ConeTool", &isProduct!ConeTool),
        ProductRow("prim.capsule", "CapsuleTool", &isProduct!CapsuleTool),
        ProductRow("prim.torus", "TorusTool", &isProduct!TorusTool),
        ProductRow("prim.arc", "ArcTool", &isProduct!ArcTool),
        ProductRow("mesh.mirrorTool", "MirrorTool", &isProduct!MirrorTool),
        ProductRow("mesh.radialSweepTool", "RadialSweepTool", &isProduct!RadialSweepTool),
        ProductRow("mesh.tack", "TackTool", &isProduct!TackTool),
        ProductRow("mesh.bridgeTool", "BridgeTool", &isProduct!BridgeTool),
    ];
    assert(rows.length == 13,
        "6353 product population: expected 13 rows, got " ~ rows.length.to!string);
    auto rowKeys = rows.map!(row => row.id).array;
    auto pairedKeys = kPaired.dup;
    rowKeys.sort();
    pairedKeys.sort();
    assert(rowKeys == pairedKeys,
        "6353 product population: product rows do not match kPaired");

    auto r = makeRig();
    registerTools(r.app);
    foreach (row; rows) {
        auto product = r.registry.toolFactories[row.id]();
        assert(product !is null && row.matches(product),
            "6353 product: " ~ row.id ~ " did not build " ~ row.expected);
    }
    auto ellipsoid = cast(SphereTool) r.registry.toolFactories["prim.ellipsoid"]();
    assert(ellipsoid.preparedSphereClearMethod,
        "6353 product: prim.ellipsoid built a SphereTool with ellipsoidMode=false "
      ~ "(the ctor flag, not the class, is what separates this pair)");
    auto sphere = cast(SphereTool) r.registry.toolFactories["prim.sphere"]();
    assert(!sphere.preparedSphereClearMethod,
        "6353 product: prim.sphere built a SphereTool with ellipsoidMode=true "
      ~ "(the ctor flag, not the class, is what separates this pair)");
}
