module tests.unit.live_registration_rig;

import ai.exploration : AiExplorationController;
import ai.interaction_log_writer : AiInteractionLogWriter;
import ai.state : EditorAiState;
import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.tool.host : ToolHost, ToolHostReadView;
import document : Layer;
import edit_session : EditSession;
import editmode : EditMode;
import editor_app : EditorApp;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import http_command_adapter : AutomationResetContext, CommandHttpAdapter;
import http_server : HttpServer;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import math : Vec3;
import mesh : Mesh, makeCube, makeOctahedron;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import remesh.remesh_job : RemeshJob;
import registry : Registry;
import registration : buildRegisteredXfrmTransformForOwnershipTest;
import seltype : SelType;
import session_owner : Session;
import std.json : JSONValue;
import std.traits : FieldNameTuple;
import step_trace : StepTrace;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tool_lifecycle_registration : registerToolLifecycleCommands;
import tools.edit.topology_pen.defs : TopoPenFactories;
import ui.remesh_modal_state : RemeshModalState;
import view : View;
import viewport : LayoutPreset, ViewportManager;

private void noOpResetUi() {}
private void noOpClearTraces() {}
private void noOpParkMouse() {}
private void noOpClosePie() {}

/// Shared by registration slices F-I. This is a class because the binding
/// retains &registry and registrar views bind &host; moving a struct would
/// stale both addresses (task 5980; evidence: this module and each family test).
final class LiveRegistrationRig {
    Session* session;
    Layer layerA;
    Layer layerB;
    View[2] cells;
    int activeCell;

    Registry registry;
    CommandHistory history;
    Tool activeTool;
    string activeToolId = "probe.tool";
    CommandExecutor executor;
    EditSession editSession;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    HttpServer httpServer;
    CommandHttpAdapter adapter;
    ToolHost host;

    EditorApp app;
    GpuMesh gpu;
    ViewportManager vpm;
    RemeshJob remeshJob;
    RemeshModalState remeshModalState;

    string[] activatePreparedIds;
    size_t deactivates;
    size_t staleResets;
    size_t liveResets;
    size_t meshRebuildDrops;
    EditMode[] promotions;

    this() {
        session = Session.bootstrap(makeCube());
        layerA = session.document.layers[0];
        layerB = new Layer;
        layerB.name = "B";
        layerB.meshRef() = makeOctahedron();
        session.document.layers ~= layerB;

        cells[0] = new View(0, 0, 800, 600);
        cells[1] = new View(0, 0, 640, 480);

        history = new CommandHistory;
        executor = new CommandExecutor(
            history,
            () => activeTool !is null,
            (ToolTransition transition) { activeTool = null; });
        editSession = new EditSession(
            () => activeTool,
            history,
            () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => false,
            () => true,
            (Command command) {},
            GuardObservationPorts(
                (record) {},
                (answer, performed) {},
                (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, editSession, history, guard,
            (Command command) {},
            (string message) {});
        httpServer = new HttpServer(8400);
        adapter = new CommandHttpAdapter(
            httpServer,
            binding,
            AutomationResetContext(
                guard,
                new PipeGizmoHost,
                new EditorAiState,
                new AiExplorationController(0.0f, 5980u),
                new StepTrace,
                &noOpResetUi,
                &noOpClearTraces,
                &noOpParkMouse,
                &noOpClosePie,
                &noOpClosePie));

        host.getActiveTool = () => activeTool;
        host.getActiveToolId = () => activeToolId;
        host.activate = (id) { activatePreparedIds ~= id; };
        host.activatePrepared = (id, ref JSONValue params) {
            activatePreparedIds ~= id;
        };
        host.deactivate = () {
            ++deactivates;
            activeTool = null;
        };
        bindStaleReset();
        host.session = () => editSession;
    }

    ref View liveView() {
        return cells[activeCell];
    }

    LiveSessionRole liveSession() {
        return LiveSessionRole(session);
    }

    LiveViewModeRole liveViewMode() {
        return LiveViewModeRole(&liveView, session.editModePtr());
    }

    void registerLifecycle() {
        registerToolLifecycleCommands(
            registry, liveSession(), liveViewMode(), ToolHostReadView(&host));
    }

    void wireEditorApp() {
        ref Mesh currentMesh() { return session.editMesh(); }
        app.meshDg = cast(typeof(app.meshDg)) &currentMesh;
        app.cameraViewDg = &liveView;
        app.gpuPtr = &gpu;
        app.sessionOwner = session;
        app.regPtr = &registry;
        app.history = history;
        app.vxEditFactory = () => new MeshVertexEdit(
            &session.editMesh(), liveView(), session.editMode);
        app.morphEditFactory = () => new MeshMorphEdit(
            &session.editMesh(), liveView(), session.editMode);
        app.layerXformEditFactory = () => new LayerXformEdit(
            &session.editMesh(), liveView(), session.editMode);
        app.bevelEditFactory = () => cast(MeshSessionEdit) null;
        static foreach (field; FieldNameTuple!TopoPenFactories)
            __traits(getMember, app.topoPenFactories, field) = () => null;
        app.pipeGizmoHost = new PipeGizmoHost;
        app.aiExplore = new AiExplorationController(0.0f, 6506u);
        app.aiLogWriter = new AiInteractionLogWriter("");
    }

    /// Wire every edit-family session factory to a distinguishable product.
    /// A sibling swap must change the command name, not merely remain non-null.
    void wireEditToolDeps() {
        MeshSessionEdit delegate() probe(string field) {
            return () => new MeshSessionEdit(
                &session.editMesh(), liveView(), session.editMode,
                "probe." ~ field, field);
        }

        app.bevelEditFactory = probe("bevelEditFactory");
        app.loopSliceEditFactory = probe("loopSliceEditFactory");
        app.reduceEditFactory = probe("reduceEditFactory");
        app.cloneEditFactory = probe("cloneEditFactory");
        app.arrayEditFactory = probe("arrayEditFactory");
        app.edgeExtrudeEditFactory = probe("edgeExtrudeEditFactory");
        app.edgeExtendEditFactory = probe("edgeExtendEditFactory");
        app.polyExtrudeEditFactory = probe("polyExtrudeEditFactory");
        app.radialArrayEditFactory = probe("radialArrayEditFactory");
        app.smoothShiftEditFactory = probe("smoothShiftEditFactory");
        app.strokeExtrudeEditFactory = probe("strokeExtrudeEditFactory");
    }

    void wireMeshCommandDeps() {
        vpm = new ViewportManager(0, 0, 800, 600);
        vpm.applyLayout(LayoutPreset.Quad);
        remeshJob = new RemeshJob;
        remeshModalState = new RemeshModalState;
        app.vpm = vpm;
        app.remeshJob = remeshJob;
        app.remeshModalState = remeshModalState;
        app.dropActiveTool = (ToolTransition transition) {
            ++meshRebuildDrops;
            activeTool = null;
        };
        app.promoteGeometryType = (EditMode mode) { promotions ~= mode; };
    }

    Tool buildTransform(string key) {
        return buildRegisteredXfrmTransformForOwnershipTest(app, key);
    }

    void bindStaleReset() {
        host.resetActiveTool = (id) {
            ++staleResets;
            return true;
        };
    }

    void bindLiveReset() {
        host.resetActiveTool = (id) {
            ++liveResets;
            return true;
        };
    }

    void switchToB() {
        session.document.setPrimary(layerB);
        session.switchGeometryType(EditMode.Polygons);
        activeCell = 1;
    }
}

unittest {
    auto rig = new LiveRegistrationRig;
    assert(rig.layerA.meshRef().vertices.length == 8
        && rig.layerB.meshRef().vertices.length == 6,
        "5980 rig population: expected distinct cube/octahedron layers");
    assert(rig.cells[0] !is rig.cells[1],
        "5980 rig population: expected two distinct live View cells");

    auto meshA = &rig.session.editMesh();
    auto viewA = rig.liveView();
    assert(rig.session.editMode == EditMode.Vertices,
        "5980 rig population: A must begin in vertex mode");
    rig.switchToB();
    assert(&rig.session.editMesh() !is meshA,
        "5980 rig population: primary switch did not change the edit mesh");
    assert(rig.liveView() !is viewA,
        "5980 rig population: cell switch did not change the live View");
    assert(rig.session.editMode == EditMode.Polygons,
        "5980 rig population: geometry switch did not change the live mode");
}

unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    rig.wireEditToolDeps();
    auto loop = rig.app.loopSliceEditFactory();
    auto reduce = rig.app.reduceEditFactory();
    assert(loop !is null && reduce !is null,
        "6670 edit-factory rig population: probe products must exist");
    assert(loop.name() == "probe.loopSliceEditFactory"
        && reduce.name() == "probe.reduceEditFactory"
        && loop.name() != reduce.name(),
        "6670 edit-factory rig does not distinguish sibling session factories");
}

unittest { // 6509: resolved Quad snapshot must differ from the raw active cell
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    rig.wireMeshCommandDeps();
    rig.vpm.activeId = 0;
    rig.vpm.views[3].camera.focus = Vec3(37, 0, 0);
    const resolved = rig.vpm.originSnapshot();
    const raw = rig.vpm.views[0].camera;
    assert(resolved.focus.x == 37.0f && raw.focus.x != resolved.focus.x,
        "6509 rig floor: the Quad follow link does not make originSnapshot() "
      ~ "differ numerically from the active cell's own camera");
}

unittest {
    auto rig = new LiveRegistrationRig;
    auto live = rig.liveSession();
    assert(live.subjectType() == SelType.Vertex,
        "6506 live subject floor: rig must begin in vertex subject mode");
    rig.session.selTypeOrder.touch(SelType.Item);
    assert(live.subjectType() == SelType.Item,
        "6506 live subject: role froze the pre-item selection type");
    rig.session.selTypeOrder.touch(SelType.Polygon);
    assert(live.subjectType() == SelType.Polygon,
        "6506 live subject: role froze the pre-polygon selection type");
}
