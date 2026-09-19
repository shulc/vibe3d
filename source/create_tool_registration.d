module create_tool_registration;

import command : Command;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.tool.headless : ToolHeadlessCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh_gpu : GpuMesh;
import registry : Registry, typedToolFactory;
import shader : LitShader;
import std.traits : FieldNameTuple;
import tool : Tool;
import tools.alignment.mirror : MirrorTool;
import tools.alignment.radial_sweep_tool : RadialSweepTool;
import tools.create.arc : ArcTool;
import tools.create.box : BoxTool;
import tools.create.capsule : CapsuleTool;
import tools.create.cone : ConeTool;
import tools.create.cylinder : CylinderTool;
import tools.create.pen : PenTool;
import tools.create.sphere : SphereTool;
import tools.create.torus : TorusTool;
import tools.create.tube : TubeTool;
import tools.create.vertex_place : VertexTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.edit.tack : TackTool;
import tools.edit.topology_pen : TopologyPenTool;
import tools.edit.topology_pen.defs : TopoPenFactories;

/// Narrow collaborators owned by create-family registration. Task 6507.
struct CreateToolDeps {
private:
    GpuMesh* gpu_;
    LitShader litShader_;
    CommandHistory history_;
    MeshSessionEdit delegate() bevelEditFactory_;
    TopoPenFactories penFactories_;

public:
    @disable this();

    this(GpuMesh* gpu, LitShader litShader, CommandHistory history,
            MeshSessionEdit delegate() bevelEditFactory,
            TopoPenFactories penFactories) {
        assert(gpu !is null, "create registration requires a GPU mesh");
        assert(history !is null,
            "create registration requires command history");
        assert(bevelEditFactory !is null,
            "create registration requires a bevel-edit factory");
        static assert(FieldNameTuple!TopoPenFactories.length == 13);
        static foreach (field; FieldNameTuple!TopoPenFactories)
            assert(__traits(getMember, penFactories, field) !is null,
                "6507 create registration requires pen factory " ~ field);
        gpu_ = gpu;
        litShader_ = litShader;
        history_ = history;
        bevelEditFactory_ = bevelEditFactory;
        penFactories_ = penFactories;
    }

    GpuMesh* gpu() nothrow @nogc { return gpu_; }
    LitShader litShader() nothrow @nogc { return litShader_; }
    CommandHistory history() nothrow @nogc { return history_; }
    MeshSessionEdit delegate() bevelEditFactory() nothrow @nogc {
        return bevelEditFactory_;
    }
    TopoPenFactories penFactories() nothrow @nogc { return penFactories_; }
}

/// One typed registration owns both entries, so a paired id is written once.
/// The command deliberately resolves the registry slot when it is created,
/// preserving replacement of a tool factory after registration. Task 6353.
private void registerHeadlessTool(T : Tool)(ref Registry reg, string id,
        T delegate() factory, LiveSessionRole owner, LiveViewModeRole live) {
    auto regPtr = &reg;
    reg.toolFactories[id] = typedToolFactory!T(factory);
    reg.commandFactories[id] = () => cast(Command)
        new ToolHeadlessCommand(&owner.activeMesh(), live.view(), live.mode(),
                                id, regPtr.toolFactories[id]);
}

/// Register generator-preview, topology, and primitive creation tools through
/// explicit live roles and the create family's narrow dependency bundle.
void registerCreateToolCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, CreateToolDeps deps) {
    registerGeneratorTools(reg, owner, live, deps);
    registerPrimitiveTools(reg, owner, live, deps);
}

private void registerGeneratorTools(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, CreateToolDeps deps) {
    registerHeadlessTool!MirrorTool(reg, "mesh.mirrorTool", () {
        auto t = new MirrorTool(() => &owner.activeMesh(), deps.gpu(),
            deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);

    // Radial Sweep — interactive revolve/lathe (task 0326), promoting the
    // pre-existing `mesh.sweep` one-shot command to a drag/handle tool.
    registerHeadlessTool!RadialSweepTool(reg, "mesh.radialSweepTool", () {
        auto t = new RadialSweepTool(() => &owner.activeMesh(), deps.gpu(),
            live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);

    registerHeadlessTool!TackTool(reg, "mesh.tack", () {
        auto t = new TackTool(() => &owner.activeMesh(), deps.gpu(),
            deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);

    reg.toolFactories["mesh.topoPen"] = typedToolFactory!TopologyPenTool(() {
        auto t = new TopologyPenTool(() => &owner.activeMesh(), deps.gpu());
        t.setGestureBindings(deps.history(), () => new MeshVertexNew(
            &owner.activeMesh(), live.view(), live.mode()));
        t.setPenFactories(deps.penFactories());
        return t;
    });

    registerHeadlessTool!BridgeTool(reg, "mesh.bridgeTool", () {
        auto t = new BridgeTool(() => &owner.activeMesh(), deps.gpu(),
            deps.litShader(), live.modeCell());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
}

private void registerPrimitiveTools(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, CreateToolDeps deps) {
    registerHeadlessTool!BoxTool(reg, "prim.cube", () {
        auto t = new BoxTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!SphereTool(reg, "prim.sphere", () {
        auto t = new SphereTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!SphereTool(reg, "prim.ellipsoid", () {
        auto t = new SphereTool(() => &owner.activeMesh(), deps.gpu(),
            deps.litShader(), true);
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!CylinderTool(reg, "prim.cylinder", () {
        auto t = new CylinderTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!TubeTool(reg, "prim.tube", () {
        auto t = new TubeTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!ConeTool(reg, "prim.cone", () {
        auto t = new ConeTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!CapsuleTool(reg, "prim.capsule", () {
        auto t = new CapsuleTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!TorusTool(reg, "prim.torus", () {
        auto t = new TorusTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);
    registerHeadlessTool!ArcTool(reg, "prim.arc", () {
        auto t = new ArcTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }, owner, live);

    reg.toolFactories["pen"] = typedToolFactory!PenTool(() {
        auto t = new PenTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    });
    reg.toolFactories["prim.vertex"] = typedToolFactory!VertexTool(() {
        auto t = new VertexTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    });
}
