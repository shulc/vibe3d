module tests.unit.production_tool_policies;

// Task 8920 (topology-redo wave S2a): every registered tool id built by its
// PRODUCTION factory, with the session-policy answers the S2a census reads.
// Its own module so the policy test names no registry type (the 6510 census
// scope); the pen factory bundle is filled field by field, one getMember.

/// The registry the app builds: every static registration (`registerTools`),
/// then the presets (`registerToolPresets`). Each id is built by its
/// PRODUCTION factory — a preset's policy is its constructed instance's, not a
/// blitted class initializer's (the transform presets set fields at build).
package(tests.unit) string[4][] productionPolicies(out size_t ids) {
    import ai.exploration : AiExplorationController;
    import ai.interaction_log_writer : AiInteractionLogWriter;
    import command_history : CommandHistory;
    import commands.layer.xform_edit : LayerXformEdit;
    import commands.mesh.morph_edit : MeshMorphEdit;
    import commands.mesh.vertex_edit : MeshVertexEdit;
    import document : Document, Layer;
    import editor_app : EditorApp;
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import pipe_gizmo_host : PipeGizmoHost;
    import registration : registerTools;
    import registry : Registry;
    import seltype : SelMode;
    import session_owner : Session;
    import tool : capturedTopologyModel, firstStepCarriesActivation, opensAtArm,
        postmodeStartsOnPressFor;
    import tool_presets : loadToolPresets, registerToolPresets;
    import tools.edit.topology_pen.defs : TopoPenFactories;
    import view : View;
    import std.traits : FieldNameTuple;
    static struct Rig { Registry registry; GpuMesh gpu; Session* session; Layer layer;
                        View view; EditorApp app; }
    auto r = new Rig;
    r.layer = new Layer;
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
    r.app.vxEditFactory = () => cast(MeshVertexEdit) null;
    r.app.morphEditFactory = () => cast(MeshMorphEdit) null;
    r.app.layerXformEditFactory = () => cast(LayerXformEdit) null;
    r.app.pipeGizmoHost = new PipeGizmoHost;
    r.app.bevelEditFactory = () => null;
    r.app.loopSliceEditFactory = () => null;
    r.app.reduceEditFactory = () => null;
    r.app.cloneEditFactory = () => null;
    r.app.arrayEditFactory = () => null;
    r.app.edgeExtrudeEditFactory = () => null;
    r.app.edgeExtendEditFactory = () => null;
    r.app.polyExtrudeEditFactory = () => null;
    r.app.radialArrayEditFactory = () => null;
    r.app.smoothShiftEditFactory = () => null;
    r.app.strokeExtrudeEditFactory = () => null;
    static foreach (f; FieldNameTuple!TopoPenFactories)
        __traits(getMember, r.app.topoPenFactories, f) = () => null;
    r.app.aiExplore = new AiExplorationController(0, 42);
    r.app.aiLogWriter = new AiInteractionLogWriter("");
    registerTools(r.app);
    registerToolPresets(r.registry, loadToolPresets("config/tool_presets.yaml"));
    string[4][] rows;     // [id, "model"|"model+arm"|"topo"|"", carries, startsOnPress]
    foreach (id; r.registry.toolIds()) {
        ++ids;
        const pol = r.registry.toolFactory(id)().sessionPolicy();
        rows ~= [id, capturedTopologyModel(pol) ? (opensAtArm(pol) ? "model+arm" : "model")
                     : pol.historyTopologySteps ? "topo" : "",
                 firstStepCarriesActivation(pol) ? "carries" : "",
                 postmodeStartsOnPressFor(pol) ? "onPress" : ""];
    }
    return rows;
}
