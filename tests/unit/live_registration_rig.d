module tests.unit.live_registration_rig;

import ai.exploration : AiExplorationController;
import ai.state : EditorAiState;
import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.tool.host : ToolHost;
import document : Layer;
import edit_session : EditSession;
import editmode : EditMode;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import http_command_adapter : AutomationResetContext, CommandHttpAdapter;
import http_server : HttpServer;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh : makeCube, makeOctahedron;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry;
import session_owner : Session;
import std.json : JSONValue;
import step_trace : StepTrace;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tool_lifecycle_registration : registerToolLifecycleCommands;
import view : View;

private void noOpResetUi() {}
private void noOpClearTraces() {}
private void noOpParkMouse() {}
private void noOpClosePie() {}

/// Shared by registration slices F-I. This is a class because the binding
/// retains &registry and registrars retain &host; moving a struct would stale
/// both pointers (task 5980; evidence: this module and each family test).
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

    string[] activatePreparedIds;
    size_t deactivates;
    size_t staleResets;
    size_t liveResets;

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
            registry, liveSession(), liveViewMode(), &host);
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
