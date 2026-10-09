module tests.unit.standalone_application_test;

import active_mesh_resolver : activeMeshResolver;
import change_bus : changeBus;
import command : g_editTargetResolver;
import command_invocation : CommandInvocationOutcome;
import document : Document, primaryModelSpaceResolver;
import mesh : Mesh, makeCube, g_isDocumentMesh;
import mesh_dirty : allWatchers, MeshDirtyEpochs, g_geomEpochs, g_topoEpochs, noteMeshChange;
import mesh_edit_delta : MeshEditScope;
import snapshot : MeshSnapshot;
import standalone_application : StandaloneApplication;
import std.stdio : writeln;

unittest {
    const beforeTarget = g_editTargetResolver;
    const beforeActive = activeMeshResolver;
    const beforeSpace = primaryModelSpaceResolver;
    const beforeFilter = g_isDocumentMesh;

    auto watchers = allWatchers();
    MeshDirtyEpochs[] epochs;
    foreach (watcher; watchers) epochs ~= *watcher;
    scope(exit) foreach (i, watcher; watchers) *watcher = epochs[i];
    auto first = Document.bootstrap(makeCube());
    auto second = Document.bootstrap(makeCube());
    assert(first.primary !is second.primary, "standalone-lifetime: two distinct documents");
    auto beforeBus = changeBus;
    auto firstMesh = &first.activeMeshRef();
    auto secondMesh = &second.activeMeshRef();
    auto host = new StandaloneApplication(first);
    scope(exit) host.close();
    assert(activeMeshResolver() is firstMesh && g_editTargetResolver(),
        "standalone-lifetime: current mesh identity and target");
    g_geomEpochs.reset(); g_topoEpochs.reset();
    noteMeshChange(cast(size_t)firstMesh, MeshEditScope.Geometry);
    noteMeshChange(cast(size_t)secondMesh, MeshEditScope.Geometry);
    const epoch = g_geomEpochs.epochFor(cast(size_t)firstMesh);
    const otherEpoch = g_geomEpochs.epochFor(cast(size_t)secondMesh);
    auto selected = host.invoke("mesh.select", `{"mode":"polygons","indices":[0]}`);
    assert(selected.outcome == CommandInvocationOutcome.applied,
        "standalone-roundtrip: shared selection applies");
    auto before = MeshSnapshot.capture(host.activeMesh);
    const revision = changeBus.docRevision();
    const deliveries = changeBus.deliveryCount;
    assert(host.invoke("mesh.triple").outcome == CommandInvocationOutcome.applied,
        "standalone-roundtrip: shared triple applies");
    auto after = MeshSnapshot.capture(host.activeMesh);
    assert(!before.matches(host.activeMesh) && host.activeMesh.faces.length == 7
        && host.activeMesh.vertices.length == 8,
        "standalone-roundtrip: populated forward differs with seven faces");
    assert(changeBus.deliveryCount == deliveries + 1
        && changeBus.lastDeliverySubject == cast(size_t)firstMesh,
        "standalone-delivery: synchronous real subject after command scopes close");
    assert(g_geomEpochs.epochFor(cast(size_t)firstMesh) > epoch
        && g_topoEpochs.epochFor(cast(size_t)firstMesh) > epoch
        && g_geomEpochs.epochFor(cast(size_t)secondMesh) == otherEpoch,
        "standalone-delivery: model consumer advances only delivered mesh epochs");
    assert(changeBus.docRevision() > revision,
        "standalone-delivery: document revision advances");
    assert(host.history.undoEntriesVisible().length == 2
        && host.history.redoEntriesVisible().length == 0,
        "standalone-roundtrip: selection plus topology exact history");
    const observationDeliveries = changeBus.deliveryCount;
    auto state = host.state();
    assert(state["changes"]["docRevision"].uinteger == changeBus.docRevision()
        && state["changes"]["docRevision"].uinteger > revision
        && state["changes"]["lastDeliveryFlags"].uinteger == changeBus.lastDeliveryFlags
        && state["changes"]["lastDeliverySelDomains"].uinteger == changeBus.lastDeliverySelDomains,
        "standalone-observer: actual revision and delivery gauges after supported command");
    assert(state["planes"]["counts"]["faces"].integer == 7
        && changeBus.deliveryCount == observationDeliveries,
        "standalone-observer: full planes read without delivering");
    assert(host.invoke("history.undo").outcome == CommandInvocationOutcome.applied
        && before.matches(host.activeMesh),
        "standalone-roundtrip: undo restores all planes");
    assert(host.invoke("history.redo").outcome == CommandInvocationOutcome.applied
        && after.matches(host.activeMesh),
        "standalone-roundtrip: redo restores all planes");
    assert(changeBus.lastDeliveryFlags != 0,
        "standalone-current-context: supported commands establish nonzero gauge");
    const currentDeliveries = changeBus.deliveryCount;
    host.document.layers = null; host.document.noteLayerListChanged();
    assert(!host.document.hasEditTarget() && host.document.primary is null && !g_editTargetResolver()
        && changeBus.deliveryCount == currentDeliveries,
        "standalone-current-context: target removal has no mesh delivery");
    auto currentContext = host.state();
    assert(currentContext["history"]["undo"].array.length == 2
        && currentContext["changes"]["lastDeliveryFlags"].uinteger != 0,
        "standalone-current-context: populated history and real nonzero observation");
    assert(host.invoke("mesh.triple").outcome == CommandInvocationOutcome.refused,
        "standalone-current-context: no-target refusal with incoming context");
    assert(host.state() == currentContext,
        "standalone-current-context: complete state and incoming gauges preserved");
    host.close(); host.close();
    assert(g_editTargetResolver == beforeTarget && activeMeshResolver == beforeActive
        && primaryModelSpaceResolver == beforeSpace && g_isDocumentMesh == beforeFilter
        && changeBus.deliveryCount == beforeBus.deliveryCount,
        "standalone-lifetime: owner restores all borrowed globals");
    auto next = new StandaloneApplication(second);
    scope(exit) next.close();
    assert(activeMeshResolver() is secondMesh && activeMeshResolver() !is firstMesh
        && next.history.undoEntriesVisible().length == 0,
        "standalone-lifetime: second owner has no alias/history from first document");
    assert(next.invoke("mesh.select", `{"mode":"polygons","indices":[1]}`).applied
        && next.invoke("mesh.triple").applied && secondMesh.faces.length == 7
        && firstMesh.faces.length == 7,
        "standalone-lifetime: second owner's live factories edit second document");
    writeln("CORE-CELL passed=standalone-owner");
}

unittest {
    auto doc = Document.bootstrap(makeCube());
    doc.clearItemSelection();
    // Clear the primary target explicitly; selection emptiness can retain it.
    doc.layers = null; doc.noteLayerListChanged();
    assert(!doc.hasEditTarget() && doc.primary is null,
        "standalone-no-target: absent primary asserted");
    auto host = new StandaloneApplication(doc);
    scope(exit) host.close();
    auto before = host.state();
    assert(!before["hasEditTarget"].boolean && host.document.primary is null && !g_editTargetResolver()
        && before["history"]["undo"].array.length == 0
        && before["history"]["redo"].array.length == 0
        && before["history"]["modelDepth"].uinteger == 0
        && before["history"]["uiDepth"].uinteger == 0
        && before["changes"]["deliveryCount"].uinteger == 0
        && before["changes"]["lastDeliveryFlags"].uinteger == 0
        && before["changes"]["lastDeliverySelDomains"].uinteger == 0,
        "standalone-no-target: init-only construction has empty history and zero gauges");
    auto result = host.invoke("mesh.triple");
    assert(result.outcome == CommandInvocationOutcome.refused,
        "standalone-no-target: script refusal");
    assert(host.state() == before,
        "standalone-no-target: complete planes/history/delivery preserved");
    writeln("CORE-CELL passed=standalone-no-target");
}
