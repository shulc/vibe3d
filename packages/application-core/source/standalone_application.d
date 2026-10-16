module standalone_application;

import active_mesh_resolver : activeMeshResolver;
import vibe3d.mesh.change.change_bus : changeBus, ChangeBus, MeshChangeAll;
import command : CommandOrigin, g_editTargetResolver;
import command_executor : CommandExecutor;
import command_history : CommandHistory, HistoryEntry;
import command_invocation : CommandInvocationService, CommandInvocationContext,
    CommandInvocationResult;
import command_registry : CommandRegistry;
import document : Document, primaryModelSpaceResolver;
import http_json : meshPlanesJson;
import vibe3d.util.spatial.spatial : ModelSpace, Viewport;
import mesh : Mesh, g_isDocumentMesh;
import vibe3d.mesh.change.mesh_dirty : noteMeshChange;
import pilot_command_registration : PilotCommandDeps, registerTripleCommand,
    registerMeshSelectionCommand, registerHistoryNavigationCommands,
    registerElementSelectionCommand, registerDropSelectionCommand, registerInvertSelectionCommand;
import session_owner : Session;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import view : View;

// A stable owner lends the same registry to factories and dispatch. Observation
// happens after invocation returns; disposal restores borrowed process globals.
final class StandaloneApplication {
private:
    Session* session_;
    View view_;
    CommandHistory history_;
    CommandRegistry registry_;
    CommandExecutor executor_;
    CommandInvocationService service_;
    ChangeBus savedBus_;
    typeof(g_editTargetResolver) savedTarget_;
    typeof(activeMeshResolver) savedActive_;
    typeof(primaryModelSpaceResolver) savedSpace_;
    typeof(g_isDocumentMesh) savedFilter_;
    bool closed_;

public:
    this(Document loadedDocument) {
        savedBus_ = changeBus;
        savedTarget_ = g_editTargetResolver;
        savedActive_ = activeMeshResolver;
        savedSpace_ = primaryModelSpaceResolver;
        savedFilter_ = g_isDocumentMesh;
        session_ = Session.create(loadedDocument);
        view_ = new View(0, 0, 640, 480);
        history_ = new CommandHistory();
        changeBus = ChangeBus.init;
        g_editTargetResolver = () => session_.document.hasEditTarget();
        activeMeshResolver = () => &session_.editMesh();
        primaryModelSpaceResolver = () => session_.document.hasEditTarget()
            ? session_.document.primary.xform.modelSpace() : ModelSpace.world();
        g_isDocumentMesh = (const(Mesh)* mesh) => session_.document.ownsMesh(mesh);
        changeBus.onMeshChanged((size_t address, uint flags) nothrow {
            noteMeshChange(address, flags);
        });
        registry_.bindSelTypeAuthority(() => session_.selTypeOrder.current());
        PilotCommandDeps deps;
        ref Mesh liveMesh() { return session_.editMesh(); }
        ref View liveView() { return view_; }
        deps.activeMesh = &liveMesh;
        deps.view = &liveView;
        deps.mode = session_.editModePtr();
        deps.resolvedViewport = () => view_.viewport();
        deps.promoteGeometryType = (mode) { session_.promoteGeometryType(mode); };
        registerMeshSelectionCommand(registry_, deps);
        registerTripleCommand(registry_, deps);
        registerElementSelectionCommand(registry_, deps);
        registerDropSelectionCommand(registry_, deps);
        registerInvertSelectionCommand(registry_, deps);
        registerHistoryNavigationCommands(registry_, deps, history_);
        executor_ = new CommandExecutor(history_, () => false,
            (transition) { throw new Exception("standalone host has no tools to drop"); });
        service_ = new CommandInvocationService(registry_, executor_, history_);
        if (session_.document.hasEditTarget()) {
            session_.editMesh().syncSelection();
            session_.editMesh().publishChange(MeshChangeAll);
        }
    }

    void close() {
        if (closed_) return;
        closed_ = true;
        g_editTargetResolver = savedTarget_;
        activeMeshResolver = savedActive_;
        primaryModelSpaceResolver = savedSpace_;
        g_isDocumentMesh = savedFilter_;
        changeBus = savedBus_;
    }

    @property ref Document document() { return session_.document; }
    @property ref Mesh activeMesh() { return session_.editMesh(); }
    @property Session* session() { return session_; }
    @property CommandHistory history() { return history_; }

    CommandInvocationResult invoke(string id, string paramsJson = "") {
        return service_.invokeLine(id, paramsJson,
            CommandInvocationContext(CommandOrigin.script, false));
    }

    JSONValue state() {
        JSONValue history;
        history["undo"] = historyRows(history_.undoEntriesVisible());
        history["redo"] = historyRows(history_.redoEntriesVisible());
        size_t modelDepth, uiDepth;
        history_.undoDepthCounts(modelDepth, uiDepth);
        history["modelDepth"] = modelDepth;
        history["uiDepth"] = uiDepth;
        JSONValue changes;
        changes["deliveryCount"] = changeBus.deliveryCount;
        changes["lastDeliveryFlags"] = changeBus.lastDeliveryFlags;
        changes["lastDeliverySelDomains"] = changeBus.lastDeliverySelDomains;
        changes["docRevision"] = changeBus.docRevision();
        JSONValue state;
        state["hasEditTarget"] = session_.document.hasEditTarget();
        state["selType"] = session_.selTypeOrder.current().to!string;
        state["editMode"] = session_.editMode.to!string;
        state["planes"] = parseJSON(meshPlanesJson(session_.editMesh()));
        state["history"] = history;
        state["changes"] = changes;
        return state;
    }
}

private JSONValue historyRows(const(HistoryEntry)[] entries) {
    JSONValue[] rows;
    foreach (entry; entries) {
        JSONValue row;
        row["command"] = entry.commandName;
        row["label"] = entry.label;
        row["args"] = entry.args;
        row["flags"] = entry.flags;
        row["runId"] = entry.runId;
        row["tweakGen"] = entry.tweakGeneration;
        rows ~= row;
    }
    return JSONValue(rows);
}
