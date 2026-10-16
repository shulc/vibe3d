module tests.unit.standalone_application_test;
import vibe3d.mesh.edit_replay.mesh_edit_replay : apply, revert;

import vibe3d.mesh.preview.active_mesh_resolver : activeMeshResolver;
import vibe3d.mesh.change.change_bus : changeBus;
import command : g_editTargetResolver;
import command_invocation : CommandInvocationOutcome;
import vibe3d.documents.model.document : Document, primaryModelSpaceResolver;
import vibe3d.mesh.core.mesh : Mesh, makeCube, g_isDocumentMesh;
import vibe3d.mesh.change.mesh_dirty : allWatchers, MeshDirtyEpochs, g_geomEpochs, g_topoEpochs, noteMeshChange;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot, SelectionSnapshot;
import vibe3d.editing.contracts.editmode : EditMode;
import std.algorithm : sort, canFind;
import std.conv : to;
import std.json : JSONValue;
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


private void seedSelection(StandaloneApplication host) {
    host.activeMesh.syncSelection();
    host.activeMesh.clearVertexSelection(); host.activeMesh.clearEdgeSelection();
    host.activeMesh.clearFaceSelection();
    foreach (id; [6, 1]) host.activeMesh.selectVertex(id);
    foreach (id; [5, 3]) host.activeMesh.selectEdge(id);
    foreach (id; [1, 0]) host.activeMesh.selectFace(id);
    host.session.promoteGeometryType(EditMode.Polygons);
    host.history.clear();
    assert(host.activeMesh.vertices.length == 8 && host.activeMesh.edges.length == 12
        && host.activeMesh.faces.length == 6 && host.history.undoEntriesVisible().length == 0,
        "selection rig: cube population and history headroom");
}

// Observe ranks independently of command enumeration and production order readers.
private uint[] ordered(const bool[] selected, const int[] ranks) {
    uint[] ids;
    foreach (i, on; selected) if (on) ids ~= cast(uint)i;
    ids.sort!((a, b) => ranks[a] < ranks[b]);
    return ids;
}

private void sameGeometry(StandaloneApplication host, ref MeshSnapshot before) {
    assert(host.activeMesh.vertices == before.vertices && host.activeMesh.edges == before.edges
        && host.activeMesh.faces == before.faces && host.activeMesh.faceMaterial == before.faceMaterial,
        "selection: geometry and material planes preserved");
}

unittest {
    struct Case { string payload; uint[] expected; int counter; }
    Case[] cases = [
        Case(`{"type":"vertex","action":"set","indices":[5,2]}`, [5u,2u], 2),
        Case(`{"type":"vertex","action":"replace","indices":[5,2]}`, [5u,2u], 2),
        Case(`{"type":"vertex","action":"add","indices":[5,2]}`, [6u,1u,5u,2u], 4),
        Case(`{"type":"vertex","action":"add","indices":[6,6]}`, [6u,1u], 2),
        Case(`{"type":"vertex","action":"remove","indices":[6]}`, [1u], 2),
        Case(`{"type":"vertex","action":"del","indices":[6]}`, [1u], 2),
        Case(`{"type":"vertex","action":"remove","indices":[7]}`, [6u,1u], 2),
        Case(`{"type":"vertex","action":"toggle","indices":[6,2]}`, [1u,2u], 3),
        Case(`{"type":"vertex","action":"toggle","indices":[2,2]}`, [6u,1u], 3),
        Case(`{"type":"vertex","action":"set","indices":[-1,5,99,2]}`, [5u,2u], 2),
        Case(`{"type":"vertex","action":"set","indices":[99,-1]}`, [6u,1u], 2),
        Case(`{"type":"vertex","action":"set","indices":[]}`, [], 0),
        Case(`{"type":"unknown","action":"unknown","indices":[2]}`, [6u,1u,2u], 3),
    ];
    assert(cases.length == 13, "element: named batch-case population");
    foreach (cell; cases) {
        auto host = new StandaloneApplication(Document.bootstrap(makeCube()));
        scope(exit) host.close();
        seedSelection(host);
        auto before = SelectionSnapshot.capture(host.activeMesh);
        auto geometry = MeshSnapshot.capture(host.activeMesh);
        assert(host.invoke("select.element", cell.payload).applied, "element: batch accepted " ~ cell.payload);
        auto after = SelectionSnapshot.capture(host.activeMesh);
        assert(ordered(after.selectedVertices, after.vertexSelectionOrder) == cell.expected
            && after.vertexSelectionOrderCounter == cell.counter,
            "element: exact sequential fold/order/counter " ~ cell.payload);
        int rank;
        foreach (id; cell.expected) {
            assert(after.vertexSelectionOrder[id] > rank, "element: increasing stored ranks");
            rank = after.vertexSelectionOrder[id];
        }
        assert(after.selectedEdges == before.selectedEdges && after.edgeSelectionOrder == before.edgeSelectionOrder
            && after.edgeSelectionOrderCounter == 2 && after.selectedFaces == before.selectedFaces
            && after.faceSelectionOrder == before.faceSelectionOrder && after.faceSelectionOrderCounter == 2,
            "element: populated dormant ordered domains preserved");
        sameGeometry(host, geometry);
        assert(host.session.editMode == EditMode.Polygons && host.state()["selType"].str == "Polygon",
            "element: active type unchanged");
        assert(host.state()["history"]["uiDepth"].uinteger == 1
            && host.history.undoEntriesVisible().length == 1,
            "element: exactly one UI invocation row including identity");
        assert(host.invoke("history.undo").applied && SelectionSnapshot.capture(host.activeMesh) == before,
            "element: undo restores exact image");
        assert(host.invoke("history.redo").applied && SelectionSnapshot.capture(host.activeMesh) == after,
            "element: redo restores exact image");
    }
    auto host = new StandaloneApplication(Document.bootstrap(makeCube()));
    scope(exit) host.close();
    seedSelection(host);
    foreach (payload; [`{"action":"set","indices":[]}`, `{"type":"vertex","indices":[]}`,
            `{"type":"vertex","action":"set"}`, `{"type":"vertex","action":"set","indices":[1,"bad"]}`]) {
        auto before = host.state();
        bool refused;
        try { host.invoke("select.element", payload); } catch (Exception e) { refused = true; }
        assert(refused && host.state() == before, "element: required or malformed arguments refuse before writes");
    }
    // The same registered factories must resolve a replacement document and mode.
    host.document = Document.bootstrap(makeCube());
    seedSelection(host);
    host.session.promoteGeometryType(EditMode.Edges);
    assert(host.invoke("select.element", `{"type":"edge","action":"set","indices":[9,2]}`).applied
        && ordered(host.activeMesh.selectedEdges, host.activeMesh.edgeSelectionOrder) == [9u,2u]
        && host.session.editMode == EditMode.Edges, "element: lower host resolves replacement mesh/mode");
    assert(host.invoke("select.element", `{"type":"polygon","action":"set","indices":[4,1]}`).applied
        && ordered(host.activeMesh.selectedFaces, host.activeMesh.faceSelectionOrder) == [4u,1u],
        "element: polygon domain wiring");
    assert(ordered(host.activeMesh.selectedVertices, host.activeMesh.vertexSelectionOrder) == [6u,1u]
        && ordered(host.activeMesh.selectedEdges, host.activeMesh.edgeSelectionOrder) == [9u,2u],
        "element: domain sets preserve populated dormant orders");
    foreach (domain; ["edge", "polygon"]) {
        const added = domain == "edge" ? 11 : 5;
        assert(host.invoke("select.element", `{"type":"` ~ domain ~ `","action":"add","indices":[`
                ~ added.to!string ~ `]}`).applied, "element: component add accepted");
        assert(domain == "edge" ? host.activeMesh.isEdgeSelected(added) : host.activeMesh.isFaceSelected(added),
            "element: component add writes its domain");
        assert(host.invoke("select.element", `{"type":"` ~ domain ~ `","action":"remove","indices":[`
                ~ added.to!string ~ `]}`).applied, "element: component remove accepted");
        assert(domain == "edge" ? !host.activeMesh.isEdgeSelected(added) : !host.activeMesh.isFaceSelected(added),
            "element: component remove writes its domain");
        assert(host.invoke("select.element", `{"type":"` ~ domain ~ `","action":"toggle","indices":[`
                ~ added.to!string ~ `,` ~ added.to!string ~ `]}`).applied, "element: component repeated toggle accepted");
        auto selected = domain == "edge" ? host.activeMesh.selectedEdges : host.activeMesh.selectedFaces;
        auto ranks = domain == "edge" ? host.activeMesh.edgeSelectionOrder : host.activeMesh.faceSelectionOrder;
        const counter = domain == "edge" ? host.activeMesh.edgeSelectionOrderCounter : host.activeMesh.faceSelectionOrderCounter;
        assert(ordered(selected, ranks) == (domain == "edge" ? [9u,2u] : [4u,1u]) && counter == 4,
            "element: edge/polygon action callbacks preserve exact ordered membership");
    }
    writeln("CORE-CELL passed=standalone-select-element");
}

unittest {
    auto host = new StandaloneApplication(Document.bootstrap(makeCube()));
    scope(exit) host.close();
    seedSelection(host);
    foreach (payload; ["", `{"type":"unknown"}`]) {
        auto beforeState = host.state(); bool refused;
        try { host.invoke("select.drop", payload); } catch (Exception e) { refused = true; }
        assert(refused && host.state() == beforeState, "drop: required type and strict unknown refusal");
    }
    auto before = SelectionSnapshot.capture(host.activeMesh);
    auto geometry = MeshSnapshot.capture(host.activeMesh);
    assert(host.invoke("select.drop", `{"type":"edge"}`).applied, "drop: explicit edge accepted");
    auto after = SelectionSnapshot.capture(host.activeMesh);
    assert(ordered(after.selectedEdges, after.edgeSelectionOrder).length == 0
        && after.edgeSelectionOrderCounter == 0 && after.selectedVertices == before.selectedVertices
        && after.vertexSelectionOrder == before.vertexSelectionOrder && after.vertexSelectionOrderCounter == 2
        && after.selectedFaces == before.selectedFaces && after.faceSelectionOrder == before.faceSelectionOrder
        && after.faceSelectionOrderCounter == 2, "drop: only explicit domain clears");
    assert(host.session.editMode == EditMode.Edges && host.state()["selType"].str == "Edge",
        "drop: explicit target promotion");
    assert(host.invoke("select.drop", `{"type":"edge"}`).applied
        && SelectionSnapshot.capture(host.activeMesh) == after,
        "drop: empty repeat accepted identity");
    assert(host.state()["history"]["uiDepth"].uinteger == 2
        && host.history.undoEntriesVisible().length == 2, "drop: two UI invocation rows");
    assert(host.invoke("history.undo").applied && SelectionSnapshot.capture(host.activeMesh) == after
        && host.session.editMode == EditMode.Edges, "drop: undo empty repeat retains prior edge mode");
    assert(host.invoke("history.undo").applied && SelectionSnapshot.capture(host.activeMesh) == before
        && host.session.editMode == EditMode.Polygons && host.state()["selType"].str == "Polygon",
        "drop: undo restores ordered image and prior polygon mode");
    assert(host.invoke("history.redo").applied && SelectionSnapshot.capture(host.activeMesh) == after
        && host.session.editMode == EditMode.Edges, "drop: redo reapplies target mode and image");
    assert(host.invoke("history.redo").applied && SelectionSnapshot.capture(host.activeMesh) == after
        && host.history.undoEntriesVisible().length == 2, "drop: redo empty repeat keeps both rows");
    sameGeometry(host, geometry);
    foreach (target; ["vertex", "polygon"])
        assert(host.invoke("select.drop", `{"type":"` ~ target ~ `"}`).applied,
            "drop: all component domain doors execute");
    assert(!host.activeMesh.selectedVertices.canFind(true) && !host.activeMesh.selectedFaces.canFind(true)
        && host.session.editMode == EditMode.Polygons, "drop: vertex/polygon domain wiring");
    import commands.select.drop : SelectDropCommand;
    import vibe3d.viewport.camera.view : View;
    auto directMesh = makeCube(); directMesh.syncSelection(); directMesh.selectVertex(2);
    auto directView = new View(0,0,10,10);
    EditMode directMode = EditMode.Polygons;
    auto direct = new SelectDropCommand(&directMesh, directView, directMode, &directMode);
    direct.setTargetType("vertex");
    assert(direct.isUiUndo() && direct.apply() && direct.undoRecorded()
        && directMode == EditMode.Vertices && !directMesh.isVertexSelected(2),
        "drop: in-process setter and mode-cell fallback remain usable");
    assert(direct.revert() && directMode == EditMode.Polygons && directMesh.isVertexSelected(2),
        "drop: in-process fallback restores mode and image");
    auto legacy = new SelectDropCommand(&directMesh, directView, EditMode.Edges);
    legacy.setTargetType("vertex");
    assert(legacy.apply() && legacy.revert() && directMesh.isVertexSelected(2),
        "drop: legacy construction retains selection undo");
    writeln("CORE-CELL passed=standalone-select-drop");
}

unittest {
    foreach (mode; [EditMode.Vertices, EditMode.Edges, EditMode.Polygons]) {
        auto host = new StandaloneApplication(Document.bootstrap(makeCube()));
        scope(exit) host.close();
        seedSelection(host); host.session.promoteGeometryType(mode);
        auto before = SelectionSnapshot.capture(host.activeMesh);
        auto geometry = MeshSnapshot.capture(host.activeMesh);
        assert(host.invoke("select.invert").applied, "invert: first complement accepted");
        auto after = SelectionSnapshot.capture(host.activeMesh);
        assert(host.invoke("select.invert").applied, "invert: second complement accepted");
        auto repeated = SelectionSnapshot.capture(host.activeMesh);
        foreach (domain; [EditMode.Vertices, EditMode.Edges, EditMode.Polygons]) {
            const original = domain == EditMode.Vertices ? before.selectedVertices
                : domain == EditMode.Edges ? before.selectedEdges : before.selectedFaces;
            const first = domain == EditMode.Vertices ? after.selectedVertices
                : domain == EditMode.Edges ? after.selectedEdges : after.selectedFaces;
            const second = domain == EditMode.Vertices ? repeated.selectedVertices
                : domain == EditMode.Edges ? repeated.selectedEdges : repeated.selectedFaces;
            const ranks = domain == EditMode.Vertices ? after.vertexSelectionOrder
                : domain == EditMode.Edges ? after.edgeSelectionOrder : after.faceSelectionOrder;
            const originalRanks = domain == EditMode.Vertices ? before.vertexSelectionOrder
                : domain == EditMode.Edges ? before.edgeSelectionOrder : before.faceSelectionOrder;
            const reranks = domain == EditMode.Vertices ? repeated.vertexSelectionOrder
                : domain == EditMode.Edges ? repeated.edgeSelectionOrder : repeated.faceSelectionOrder;
            assert(original.length == (domain == EditMode.Vertices ? 8 : domain == EditMode.Edges ? 12 : 6),
                "invert: real domain population");
            if (domain == mode) {
                uint[] expected;
                foreach (i, on; original) { assert(first[i] == !on && second[i] == on, "invert: complement membership");
                    if (!on) expected ~= cast(uint)i; }
                assert(ordered(first, ranks) == expected, "invert: first complement enumeration order");
                assert(ordered(second, reranks) == (domain == EditMode.Vertices ? [1u,6u]
                    : domain == EditMode.Edges ? [3u,5u] : [0u,1u]), "invert: repeat enumeration order");
            } else {
                assert(first == original && second == original && ranks == originalRanks && reranks == originalRanks,
                    "invert: dormant ordered domain preserved");
                const originalCounter = domain == EditMode.Vertices ? before.vertexSelectionOrderCounter
                    : domain == EditMode.Edges ? before.edgeSelectionOrderCounter : before.faceSelectionOrderCounter;
                const firstCounter = domain == EditMode.Vertices ? after.vertexSelectionOrderCounter
                    : domain == EditMode.Edges ? after.edgeSelectionOrderCounter : after.faceSelectionOrderCounter;
                const secondCounter = domain == EditMode.Vertices ? repeated.vertexSelectionOrderCounter
                    : domain == EditMode.Edges ? repeated.edgeSelectionOrderCounter : repeated.faceSelectionOrderCounter;
                assert(firstCounter == originalCounter, "invert: first forward preserves original dormant counter");
                assert(secondCounter == originalCounter, "invert: second forward preserves original dormant counter");
            }
        }
        assert(host.session.editMode == mode && host.state()["history"]["modelDepth"].uinteger == 2,
            "invert: unchanged mode and two Model rows");
        assert(host.invoke("history.undo").applied && SelectionSnapshot.capture(host.activeMesh) == after,
            "invert: undo second exact image");
        assert(host.invoke("history.undo").applied && SelectionSnapshot.capture(host.activeMesh) == before,
            "invert: undo first exact descending image");
        assert(host.invoke("history.redo").applied && SelectionSnapshot.capture(host.activeMesh) == after,
            "invert: redo first exact image");
        assert(host.invoke("history.redo").applied && SelectionSnapshot.capture(host.activeMesh) == repeated,
            "invert: redo second exact image");
        sameGeometry(host, geometry);
    }
    auto empty = new StandaloneApplication(Document.bootstrap(Mesh.init));
    scope(exit) empty.close();
    empty.history.clear();
    assert(empty.activeMesh.vertices.length == 0 && empty.activeMesh.edges.length == 0
        && empty.activeMesh.faces.length == 0, "invert: genuinely empty mesh");
    foreach (_; 0 .. 2) assert(empty.invoke("select.invert").applied, "invert: empty invocation accepted");
    assert(empty.history.undoEntriesVisible().length == 2, "invert: two empty steps retained");
    foreach (_; 0 .. 2) assert(empty.invoke("history.undo").applied, "invert: each empty step undone");
    assert(empty.history.undoEntriesVisible().length == 0 && empty.history.redoEntriesVisible().length == 2,
        "invert: both empty undo steps observed");
    foreach (_; 0 .. 2) assert(empty.invoke("history.redo").applied, "invert: each empty step redone");
    assert(empty.history.undoEntriesVisible().length == 2, "invert: both empty redo steps observed");
    writeln("CORE-CELL passed=standalone-select-invert");
}
