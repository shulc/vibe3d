// Session ownership pilot witness (task 5700, related backlog 1901).
module tests.unit.session_ownership_test;

import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.string : indexOf;

import application_command_binding : ApplicationCommandBinding,
    CommandInvocationContext, CommandInvocationOutcome;
import command : Command, CommandOrigin, g_editTargetResolver;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.mesh.move_vertex : MeshMoveVertex;
import document : Document;
import edit_session : EditSession;
import editmode : EditMode;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import math : Vec3;
import mesh : Mesh, g_isDocumentMesh, makeCube;
import registry : Registry;
import seltype : SelType;
import session_owner : Session;
import tests.unit.census_symbols : blankNonCode;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.discard_guard : UiRunOutcome;
import view : View;

static assert(!__traits(isCopyable, Session),
    "session ownership: Session must remain non-copyable");

private string repoCode(string relative) {
    auto root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    auto path = buildPath(root, relative);
    assert(exists(path), "session ownership census: missing " ~ relative);
    return blankNonCode(readText(path));
}

private size_t occurrences(string source, string needle) {
    size_t count;
    size_t offset;
    while (offset < source.length) {
        auto found = source[offset .. $].indexOf(needle);
        if (found < 0) break;
        ++count;
        offset += cast(size_t)found + needle.length;
    }
    return count;
}

unittest {
    auto owner = Session.bootstrap(makeCube());
    assert(owner !is null && owner.document.layers.length == 1,
        "session ownership type witness: owner/document population collapsed");

    assert(owner.promoteGeometryType(EditMode.Polygons),
        "session ownership type witness: polygon promotion did not flip");
    assert(owner.editMode == EditMode.Polygons,
        "session ownership type witness: derived EditMode missed polygon promotion");
    assert(owner.selTypeOrder.current == SelType.Polygon,
        "session ownership type witness: order missed polygon promotion");

    assert(owner.switchItemType(),
        "session ownership type witness: item switch did not flip");
    assert(owner.selTypeOrder.current == SelType.Item,
        "session ownership type witness: item switch missed the order");
    assert(owner.editMode == EditMode.Polygons,
        "session ownership type witness: item switch overwrote geometry EditMode");

    assert(owner.switchGeometryType(EditMode.Edges),
        "session ownership type witness: edge switch did not flip");
    assert(owner.editMode == EditMode.Edges,
        "session ownership type witness: derived EditMode missed edge switch");
    assert(owner.selTypeOrder.current == SelType.Edge,
        "session ownership type witness: order missed edge switch");
}

unittest {
    auto owner = Session.bootstrap(makeCube());
    auto documentSlot = owner.documentPtr();
    auto layerA = owner.document.primary;
    auto meshA = &owner.editMesh();
    immutable aStart = Vec3(-0.5f, -0.5f, -0.5f);
    immutable aMoved = Vec3(-2.0f, -2.0f, -2.0f);
    assert(layerA !is null && meshA.vertices.length == 8
        && meshA.vertices[0] == aStart,
        "session ownership lifetime witness: document A population changed");

    Mesh bSeed = makeCube();
    immutable bStart = Vec3(2.0f, 3.0f, 4.0f);
    immutable bMoved = Vec3(5.0f, 6.0f, 7.0f);
    bSeed.vertices[0] = bStart;
    Document documentB = Document.bootstrap(bSeed);
    auto layerB = documentB.primary;
    auto meshB = &layerB.meshRef();
    assert(layerB !is null && layerB !is layerA && meshB !is meshA
        && meshB.vertices.length == 8 && meshB.vertices[0] == bStart,
        "session ownership lifetime witness: independent document B population collapsed");

    auto savedTargetResolver = g_editTargetResolver;
    auto savedDocumentFilter = g_isDocumentMesh;
    scope (exit) {
        g_editTargetResolver = savedTargetResolver;
        g_isDocumentMesh = savedDocumentFilter;
    }
    g_editTargetResolver = () => owner.document.hasEditTarget();
    g_isDocumentMesh = (const(Mesh)* subject) => owner.document.ownsMesh(subject);

    auto view = new View(0, 0, 800, 600);
    auto history = new CommandHistory();
    Tool activeTool;
    auto executor = new CommandExecutor(
        history,
        () => activeTool !is null,
        (ToolTransition transition) { activeTool = null; });
    auto editSession = new EditSession(
        () => activeTool,
        history,
        () { activeTool = null; });
    auto guard = new GuardedActionController(GuardedActionPorts(
        (Command command, RecordMode mode) =>
            executor.applyOrRefire(command, mode, null),
        () => false,
        () => true,
        (Command command) {},
        GuardObservationPorts(
            (record) {},
            (answer, performed) {},
            (pending) {})));

    Registry registry;
    registry.commandFactories["mesh.move_vertex"] = () => cast(Command)
        new MeshMoveVertex(&owner.editMesh(), view, owner.editMode);
    auto binding = new ApplicationCommandBinding(
        registry, executor, editSession, history, guard,
        (Command command) {},
        (string message) {});
    immutable context = CommandInvocationContext(CommandOrigin.script, false);

    auto resultA = binding.invokeLine("mesh.move_vertex",
        `{"from":[-0.5,-0.5,-0.5],"to":[-2,-2,-2]}`, context);
    assert(resultA.outcome == CommandInvocationOutcome.applied
        && history.canUndo && meshA.vertices[0] == aMoved
        && meshB.vertices[0] == bStart,
        "session ownership lifetime witness: production command A did not bind document A");

    owner.replaceDocument(documentB);
    assert(owner.documentPtr() is documentSlot,
        "session ownership lifetime witness: replacement moved the Document field");
    assert(owner.document.primary is layerB,
        "session ownership lifetime witness: replacement did not install document B");

    assert(history.undo(),
        "session ownership lifetime witness: command A did not remain undoable");
    assert(meshA.vertices[0] == aStart && meshB.vertices[0] == bStart,
        "session ownership lifetime witness: undo A targeted the replacement document");

    auto resultB = binding.invokeLine("mesh.move_vertex",
        `{"from":[2,3,4],"to":[5,6,7]}`, context);
    assert(resultB.outcome == CommandInvocationOutcome.applied
        && meshB.vertices[0] == bMoved && meshA.vertices[0] == aStart,
        "session ownership lifetime witness: a new command did not bind document B after replacement");

    const historyBeforeEmpty = history.undoEntriesVisible.length;
    owner.document.resetSelectionState();
    assert(!owner.document.hasEditTarget() && owner.document.layers.length == 1
        && meshB.vertices.length == 8 && owner.editMesh().vertices.length == 0,
        "session ownership lifetime witness: empty target lost document or stand population");
    auto emptyResult = binding.invokeLine("mesh.move_vertex",
        `{"from":[5,6,7],"to":[8,9,10]}`, context);
    assert(emptyResult.outcome == CommandInvocationOutcome.refused
        && history.undoEntriesVisible.length == historyBeforeEmpty
        && meshB.vertices[0] == bMoved && owner.editMesh().vertices.length == 0,
        "session ownership lifetime witness: empty target accepted a mesh write");
}

unittest {
    auto app = repoCode("source/app.d");
    auto editor = repoCode("source/editor_app.d");
    auto http = repoCode("source/http_providers.d");

    assert(app.length > 200_000 && editor.length > 30_000 && http.length > 8_000,
        "session ownership census: source population is implausibly small");
    assert(occurrences(app,
        "Session* sessionOwner = Session.bootstrap(makeCube());") == 1
        && occurrences(app, "app.sessionOwner = sessionOwner;") == 1
        && occurrences(editor, "Session* sessionOwner;") == 1,
        "session ownership census: the single owner allocation/wiring changed");
    assert(occurrences(app, "sessionOwner.editModePtr()") == 4,
        "session ownership census: all four lazy pipeline mode aliases were not rebound");
    assert(occurrences(app, "sessionOwner.documentPtr()") == 1
        && occurrences(http, "app.sessionOwner.documentPtr()") == 1
        && occurrences(http, "app.sessionOwner.selTypeOrderPtr()") == 1,
        "session ownership census: document/selection read aliases were not rebound");
    assert(occurrences(app, "&editMode") == 0
        && occurrences(app, "&document") == 0
        && occurrences(app, "&selTypeOrder") == 0,
        "session ownership census: a main-frame address still escapes");
    assert(occurrences(app, "app.editModePtr") == 0
        && occurrences(app, "app.documentPtr") == 0
        && occurrences(app, "app.selTypeOrderPtr") == 0
        && occurrences(editor, "EditMode* editModePtr;") == 0
        && occurrences(editor, "Document* documentPtr;") == 0
        && occurrences(editor, "SelTypeOrder* selTypeOrderPtr;") == 0,
        "session ownership census: retired EditorApp pointer wiring returned");
    assert(occurrences(app, "Document document = Document.bootstrap") == 0
        && occurrences(app, "EditMode editMode =") == 0
        && occurrences(app, "SelTypeOrder selTypeOrder;") == 0,
        "session ownership census: retired main-frame storage returned");
}
