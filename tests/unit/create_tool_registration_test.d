module tests.unit.create_tool_registration_test;

import command : Command;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.tool.headless : ToolHeadlessCommand;
import mesh : Mesh;
import params : Param;
import registration : registerTools;
import registry : ToolFactory;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import tools.alignment.mirror : MirrorTool;
import tools.create.box : BoxTool;
import tools.edit.topology_pen : TopologyPenTool;
import tools.edit.topology_pen.defs : TopoPenFactories;

import std.meta : AliasSeq;
import std.traits : BaseClassesTuple, FieldNameTuple;

private enum string[] kPairedIds = [
    "prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cylinder",
    "prim.tube", "prim.cone", "prim.capsule", "prim.torus", "prim.arc",
    "mesh.mirrorTool", "mesh.radialSweepTool", "mesh.tack", "mesh.bridgeTool",
];
private enum string[] kToolOnly = ["pen", "prim.vertex", "mesh.topoPen"];
private enum string[] kCreateIds = kPairedIds ~ kToolOnly;

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(typeof(f) : F)) return cast(F) f;
    }
    assert(0, "6507 reflection floor: no field named " ~ name
        ~ " convertible to " ~ F.stringof ~ " on " ~ T.stringof);
}

private final class MarkerTool : Tool {
    int marker;
    this(int value) { marker = value; }
    override Param[] params() {
        return [Param.int_("createMarker", "Create Marker", &marker, marker)];
    }
}

// C1: the production door owns all sixteen tools, exactly thirteen paired.
unittest {
    static assert(kCreateIds.length == 16);
    static assert(kPairedIds.length == 13);
    static assert(kToolOnly.length == 3);
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    registerTools(rig.app);
    foreach (id; kCreateIds)
        assert(rig.registry.hasTool(id),
            "6507 population: registry lacks tool " ~ id);
    foreach (id; kPairedIds)
        assert(rig.registry.hasCommand(id),
            "6507 population: registry lacks paired command " ~ id);
    foreach (id; kToolOnly)
        assert(!rig.registry.hasCommand(id),
            "6507 command-negative: tool-only id became paired: " ~ id);
}

// C2: every headless wrapper samples the current edit target when built.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    registerTools(rig.app);
    rig.switchToB();
    foreach (id; kPairedIds) {
        auto command = rig.registry.makeCommand(id);
        assert(command.meshPtr() is &rig.layerB.meshRef(),
            "6507 live command mesh: " ~ id ~ " retained layer A");
    }
}

// C3: both family representatives keep a live tool-side mesh source even
// when the product itself was constructed before the primary-layer switch.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    registerTools(rig.app);
    auto cube = cast(BoxTool) rig.registry.toolFactory("prim.cube")();
    auto mirror = cast(MirrorTool) rig.registry.toolFactory("mesh.mirrorTool")();
    auto cubeMesh = fieldOf!(Mesh* delegate())(cube, "meshSrc_");
    auto mirrorMesh = fieldOf!(Mesh* delegate())(mirror, "meshSrc_");
    assert(cubeMesh() is &rig.layerA.meshRef(),
        "6507 live mesh floor: prim.cube did not begin on layer A");
    assert(mirrorMesh() is &rig.layerA.meshRef(),
        "6507 live mesh floor: mesh.mirrorTool did not begin on layer A");
    rig.switchToB();
    assert(cubeMesh() is &rig.layerB.meshRef(),
        "6507 live mesh: prim.cube tool source retained the registration-time Mesh");
    assert(mirrorMesh() is &rig.layerB.meshRef(),
        "6507 live mesh: mesh.mirrorTool tool source retained the registration-time Mesh");
}

// C4: one representative of each family resolves the registry slot late.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    registerTools(rig.app);
    foreach (i, id; ["prim.cube", "mesh.mirrorTool"]) {
        immutable marker = 6507 + cast(int) i;
        ToolFactory probe = () => new MarkerTool(marker);
        rig.registry.replaceTool(id, probe);
        auto command = cast(ToolHeadlessCommand)
            rig.registry.makeCommand(id);
        auto held = fieldOf!ToolFactory(command, "factory");
        assert(held is probe,
            "6353 late lookup: " ~ id ~ " wrapper holds the registration-time "
          ~ "factory, not the one in the registry at fire");
    }
}

// C5: the topology pen retains both independent binding doors.
unittest {
    static assert(FieldNameTuple!TopoPenFactories.length == 13);
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    static foreach (field; FieldNameTuple!TopoPenFactories)
        __traits(getMember, rig.app.topoPenFactories, field) = () =>
            new MeshSessionEdit(&rig.session.editMesh(), rig.liveView(),
                rig.session.editMode, "probe." ~ field, field);
    registerTools(rig.app);
    auto pen = cast(TopologyPenTool)
        rig.registry.toolFactory("mesh.topoPen")();
    auto held = fieldOf!TopoPenFactories(pen, "factories_");
    static foreach (field; FieldNameTuple!TopoPenFactories)
        assert(__traits(getMember, held, field) !is null,
            "6507 topology bundle: missing field " ~ field);
    auto placement = fieldOf!(Command delegate())(pen, "gestureFactory");
    assert(placement !is null,
        "6507 topology placement: gesture carrier was not bound");
}
