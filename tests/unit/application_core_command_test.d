module tests.unit.application_core_command_test;

import command : Command, g_editTargetResolver, kNoEditTargetReason;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode, HistoryFlags;
import commands.mesh.triple : MeshTriple;
import commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.documents.model.document : Document;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh, makeCube, Surface, MapDomain, g_isDocumentMesh;
import vibe3d.mesh.core.mesh_planes : kFacePlanes, kVertPlanes, kEdgePlanes;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.mesh.topology.mesh_topo : edgeKey;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditDelta, MeshEditScope;
import vibe3d.mesh.change.mesh_dirty : noteMeshChange, g_geomEpochs, g_topoEpochs,
    MeshDirtyEpochs, allWatchers;
import vibe3d.mesh.change.change_bus : changeBus, ChangeBus;
import vibe3d.editing.contracts.tool_policy_values : AttrImage, StepOrigin, Rollover, rolloverDraws,
    DropUndoPolicy, DropUndoExtent, DropRedoPopulation, DropUndoResidualPopulation;
import vibe3d.viewport.camera.view : View;
import std.stdio : writeln;

// The production snapshot is a read-only deep projection. The plane roster
// makes a newly declared plane fail compilation until its projection exists.
static foreach (plane; kFacePlanes ~ kVertPlanes ~ kEdgePlanes)
    static assert(__traits(hasMember, MeshSnapshot, plane));

private Mesh selectedQuad() {
    auto m = makeCube();
    m.syncSelection();
    m.surfaces = [Surface("first"), Surface("second")];
    m.faceMaterial.length = m.faces.length; m.facePart.length = m.faces.length;
    m.faceSetMask.length = m.faces.length; m.vertexSetMask.length = m.vertices.length;
    foreach (i; 0 .. m.faces.length) {
        m.faceMaterial[i] = cast(uint)(i % 2);
        m.facePart[i] = cast(uint)(i + 4);
        m.faceSetMask[i] = 1;
    }
    m.vertexSetNames = ["points"];
    m.edgeSetNames = ["edges"];
    m.polygonSetNames = ["faces"];
    m.vertexSetMask[4] = 1;
    m.edgeSetMask[edgeKey(m.edges[1][0], m.edges[1][1])] = 1;
    auto weight = m.addMeshMap("weight", 1, MapDomain.Point);
    foreach (i, ref value; weight.data) value = cast(float)(i + 1) / 8;
    auto uv = m.addMeshMap("uv", 2, MapDomain.PolyVertex);
    foreach (i, ref value; uv.data) value = cast(float)(i + 1) / 48;
    m.selectVertex(4);
    m.selectVertex(6);
    m.selectEdge(2);
    m.selectFace(0);
    assert(m.meshMaps.length == 2 && m.meshMaps[0].data.length == 8
        && m.meshMaps[1].data.length == 48, "core fixture: populated point/corner maps");
    assert(m.selectedFaces[0] && m.faceSelectionOrderCounter != 0
        && m.vertexSelectionOrderCounter == 2 && m.edgeSelectionOrderCounter == 1,
        "core fixture: all selection domains and order counters populated");
    return m;
}

private CommandExecutor executor(CommandHistory history) {
    return new CommandExecutor(history, () => false,
        (transition) { assert(false, "core executor: no armed tool may be dropped"); });
}

unittest {
    auto savedBus = changeBus;
    const savedResolver = g_editTargetResolver;
    const savedMeshFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedMeshFilter;
    g_isDocumentMesh = null;
    scope(exit) { changeBus = savedBus; g_editTargetResolver = savedResolver; }
    changeBus = ChangeBus.init;
    g_editTargetResolver = null;
    auto m = selectedQuad();
    m.publishChange(MeshEditScope.None);
    auto before = MeshSnapshot.capture(m);
    auto h = new CommandHistory(); h.clear();
    assert(h.undoEntries().length == 0 && h.undoEntries().length < 50, "triple-roundtrip: history headroom");
    auto e = executor(h);
    auto v = new View(0, 0, 1, 1);
    auto cmd = new MeshTriple(&m, v, EditMode.Polygons, null);
    const deliveries = changeBus.deliveryCount;
    assert(e.applyOrRefire(cmd, RecordMode.Record, null), "triple-roundtrip: forward applies");
    assert(!before.matches(m), "triple-roundtrip: forward differs from before");
    assert(m.faces.length == 7 && m.vertices.length == 8, "triple-roundtrip: selected quad 6 to 7 faces");
    size_t selected;
    foreach (i, yes; m.selectedFaces) if (yes) {
        ++selected;
        assert(m.faces[i].length == 3, "triple-roundtrip: selected children are triangles");
    }
    assert(selected == 2, "triple-roundtrip: exactly two children selected");
    assert(h.undoEntries().length == 1 && h.redoEntries().length == 0
        && h.undoEntries()[0].cmd is cmd && h.undoEntries()[0].commandName == "mesh.triple"
        && h.undoEntries()[0].flags == (HistoryFlags.Succeeded | HistoryFlags.Undoable),
        "triple-roundtrip: exact one production history row");
    assert(changeBus.deliveryCount == deliveries + 1, "triple-roundtrip: forward delivers once after scope close");
    auto after = MeshSnapshot.capture(m);
    assert(h.undo(), "triple-roundtrip: undo steps");
    assert(before.matches(m), "triple-roundtrip: undo restores whole planes/selection/order/maps/counters");
    assert(h.undoEntries().length == 0 && h.redoEntries().length == 1 && h.undoEpoch == 1,
        "triple-roundtrip: exact undo history step");
    assert(h.redo(), "triple-roundtrip: redo steps");
    assert(after.matches(m), "triple-roundtrip: redo restores whole planes/selection/order/maps/counters");
    assert(h.undoEntries().length == 1 && h.redoEntries().length == 0 && h.undoEpoch == 1,
        "triple-roundtrip: exact redo history step");
    assert(changeBus.deliveryCount == deliveries + 3, "triple-roundtrip: forward/undo/redo synchronous deliveries");
    writeln("CORE-CELL passed=triple-roundtrip");
}

unittest {
    auto savedBus = changeBus;
    const savedResolver = g_editTargetResolver;
    const savedMeshFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedMeshFilter;
    g_isDocumentMesh = null;
    scope(exit) { changeBus = savedBus; g_editTargetResolver = savedResolver; }
    changeBus = ChangeBus.init;
    g_editTargetResolver = null;
    auto m = makeCube();
    // Fixture data: one triangle, already selected, so the frozen kernel's
    // refusal clears the selection while publishing one delivery.
    m.faces = [[0u, 1u, 2u]];
    m.faceMarks = [0u]; m.faceSelectionOrder = [0];
    m.faceMaterial = [0u]; m.facePart = [0u]; m.faceSetMask = [0UL];
    m.buildLoops(); m.syncSelection();
    m.selectFace(0);
    m.publishChange(MeshEditScope.None);
    auto before = MeshSnapshot.capture(m);
    auto h = new CommandHistory(); h.clear();
    auto e = executor(h); auto v = new View(0, 0, 1, 1);
    const deliveries = changeBus.deliveryCount;
    assert(!e.applyOrRefire(new MeshTriple(&m, v, EditMode.Polygons, null), RecordMode.Record, null),
        "selected-triangle-refusal: production executor refuses");
    assert(m.faces.length == 1 && m.faces[0] == before.faces[0] && m.vertices == before.vertices,
        "selected-triangle-refusal: geometry unchanged");
    assert(!m.selectedFaces[0] && m.faceSelectionOrderCounter == 0,
        "selected-triangle-refusal: frozen selected triangle clears marks/order");
    assert(h.undoEntries().length == 0 && h.redoEntries().length == 0,
        "selected-triangle-refusal: refused command records no history");
    assert(changeBus.deliveryCount == deliveries + 1,
        "selected-triangle-refusal: frozen refusal delivers once after scope close");
    writeln("CORE-CELL passed=selected-triangle-refusal");
}

unittest {
    auto savedBus = changeBus;
    const savedResolver = g_editTargetResolver;
    const savedMeshFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedMeshFilter;
    g_isDocumentMesh = null;
    scope(exit) { changeBus = savedBus; g_editTargetResolver = savedResolver; }
    changeBus = ChangeBus.init;
    g_editTargetResolver = null;
    auto m = makeCube(); auto v = new View(0, 0, 1, 1);
    auto carrier = new MeshSessionEdit(&m, v, EditMode.Polygons, "mesh.session", "Session");
    assert(!carrier.isTopologyStep() && carrier.stepOrigin() == StepOrigin.unclassified
        && carrier.stepOperation() == 0 && carrier.stepInstance() == 0
        && !carrier.stepOpenedByPress() && carrier.stepBeforeAttrs().empty()
        && carrier.stepAfterAttrs().empty(), "session-carrier: production defaults");
    assert(cast(ubyte)StepOrigin.unclassified == 0 && cast(ubyte)StepOrigin.refire == 1
        && cast(ubyte)StepOrigin.opens == 2 && cast(ubyte)StepOrigin.restart == 3,
        "session-carrier: StepOrigin numeric identity");
    assert(cast(ubyte)Rollover.none == 0 && cast(ubyte)Rollover.target == 1
        && cast(ubyte)Rollover.vertices == 2, "session-carrier: Rollover numeric identity");
    assert(!rolloverDraws(Rollover.none, EditMode.Vertices, false)
        && rolloverDraws(Rollover.target, EditMode.Edges, false)
        && !rolloverDraws(Rollover.target, EditMode.Edges, true)
        && rolloverDraws(Rollover.vertices, EditMode.Vertices, true)
        && !rolloverDraws(Rollover.vertices, EditMode.Polygons, false),
        "session-carrier: production rollover predicate");
    assert(DropUndoPolicy.init == DropUndoPolicy(DropUndoExtent.none,
        DropRedoPopulation.editRows, DropUndoResidualPopulation.removeSuffix),
        "session-carrier: drop policy defaults");
    immutable(ubyte)[] first = [1, 2]; immutable(ubyte)[] second = [3, 4];
    auto attrs = AttrImage(["first", "second"], [cast(immutable(void)[])first, cast(immutable(void)[])second]);
    assert(!attrs.empty() && attrs == attrs && attrs.without(["first"]) ==
        AttrImage(["second"], [cast(immutable(void)[])second]), "session-carrier: production attribute image");
    auto basis = MeshSnapshot.capture(m);
    carrier.setTopologyStep(attrs, attrs.without(["first"]), basis, basis,
        true, 17, StepOrigin.opens, 19);
    assert(carrier.isTopologyStep() && carrier.stepOrigin() == StepOrigin.opens
        && carrier.stepOperation() == 19 && carrier.stepInstance() == 17 && carrier.stepOpenedByPress()
        && carrier.stepBeforeAttrs() == attrs && carrier.stepAfterAttrs() == attrs.without(["first"])
        && carrier.stepBeforeBasis().matches(basis) && carrier.stepAfterBasis().matches(basis),
        "session-carrier: production topology carrier identity/images");
    carrier.setSnapshots(basis, basis, "snapshot");
    assert(carrier.hasGesturePayload() && !carrier.isOperationInverse() && carrier.label() == "snapshot",
        "session-carrier: production snapshot payload");
    auto deltaCarrier = new MeshSessionEdit(&m, v, EditMode.Polygons, "mesh.delta", "Delta");
    deltaCarrier.setDelta(MeshEditDelta.init, "delta");
    assert(deltaCarrier.hasGesturePayload() && deltaCarrier.isOperationInverse() && deltaCarrier.label() == "delta",
        "session-carrier: production delta payload");
    writeln("CORE-CELL passed=session-carrier");
}

unittest {
    auto savedBus = changeBus;
    const savedResolver = g_editTargetResolver;
    const savedMeshFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedMeshFilter;
    g_isDocumentMesh = null;
    scope(exit) { changeBus = savedBus; g_editTargetResolver = savedResolver; }
    changeBus = ChangeBus.init;
    auto doc = Document.bootstrap(selectedQuad());
    auto target = &doc.layers[0].meshRef();
    doc.layers = null; doc.noteLayerListChanged();
    assert(doc.primary is null && !doc.hasEditTarget(), "no-edit-target: genuinely absent primary");
    g_editTargetResolver = () => doc.hasEditTarget();
    target.publishChange(MeshEditScope.None);
    auto before = MeshSnapshot.capture(*target);
    auto h = new CommandHistory(); h.clear();
    auto e = executor(h); auto v = new View(0, 0, 1, 1);
    auto cmd = new MeshTriple(target, v, EditMode.Polygons, null);
    const deliveries = changeBus.deliveryCount;
    assert(!e.applyOrRefire(cmd, RecordMode.Record, null) && cmd.refusalReason() == kNoEditTargetReason,
        "no-edit-target: live production resolver refuses before apply");
    assert(before.matches(*target), "no-edit-target: complete planes unchanged");
    assert(h.undoEntries().length == 0 && h.redoEntries().length == 0 && h.undoEpoch == 0,
        "no-edit-target: complete history unchanged");
    assert(changeBus.deliveryCount == deliveries, "no-edit-target: no delivery");
    writeln("CORE-CELL passed=no-edit-target");
}

unittest {
    auto savedBus = changeBus;
    const savedResolver = g_editTargetResolver;
    const savedMeshFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedMeshFilter;
    g_isDocumentMesh = null;
    auto watchers = allWatchers();
    MeshDirtyEpochs[] savedEpochs;
    foreach (watcher; watchers) savedEpochs ~= *watcher;
    scope(exit) {
        foreach (i, watcher; watchers) *watcher = savedEpochs[i];
        changeBus = savedBus; g_editTargetResolver = savedResolver;
    }
    changeBus = ChangeBus.init;
    g_editTargetResolver = null;
    auto m = selectedQuad(); auto other = makeCube();
    m.publishChange(MeshEditScope.None); other.publishChange(MeshEditScope.None);
    const addr = cast(size_t)&m, otherAddr = cast(size_t)&other;
    assert(addr != 0 && otherAddr != 0 && addr != otherAddr,
        "model-delivery: two distinct real mesh addresses");
    // Resident subjects distinguish targeted delivery from the conservative
    // eviction fallback; save every watcher touched by the production fan-in.
    g_geomEpochs.reset(); g_topoEpochs.reset();
    noteMeshChange(addr, MeshEditScope.Geometry);
    noteMeshChange(otherAddr, MeshEditScope.Geometry);
    const geom = g_geomEpochs.epochFor(addr), topo = g_topoEpochs.epochFor(addr);
    const otherGeom = g_geomEpochs.epochFor(otherAddr), otherTopo = g_topoEpochs.epochFor(otherAddr);
    assert(g_geomEpochs.anyEpoch() == 2 && g_topoEpochs.anyEpoch() == 2
        && geom == 1 && topo == 1 && otherGeom == 2 && otherTopo == 2,
        "model-delivery: both subjects resident before command notification");
    assert(g_geomEpochs.epochFor(size_t.max) == 0 && g_topoEpochs.epochFor(size_t.max) == 0,
        "model-delivery: untracked address still reads zero fallback before notification");
    size_t deliveredAddr; uint deliveredFlags; size_t deliveries;
    changeBus.onMeshChanged((size_t subject, uint flags) nothrow {
        deliveredAddr = subject; deliveredFlags = flags; ++deliveries;
        noteMeshChange(subject, flags);
    });
    auto h = new CommandHistory(); h.clear(); auto e = executor(h);
    auto v = new View(0, 0, 1, 1);
    const revision = changeBus.docRevision();
    assert(e.applyOrRefire(new MeshTriple(&m, v, EditMode.Polygons, null), RecordMode.Record, null),
        "model-delivery: production command applies");
    assert(deliveries == 1 && deliveredAddr == addr && (deliveredFlags & MeshEditScope.Geometry) != 0,
        "model-delivery: synchronous identity/flags after command scope close");
    assert(g_geomEpochs.epochFor(addr) > geom && g_topoEpochs.epochFor(addr) > topo,
        "model-delivery: production model subscriber advances epochs");
    assert(g_geomEpochs.epochFor(otherAddr) == otherGeom && g_topoEpochs.epochFor(otherAddr) == otherTopo,
        "model-delivery: distinct mesh epochs unchanged");
    assert(changeBus.docRevision() > revision, "model-delivery: document revision advances");
    writeln("CORE-CELL passed=model-delivery");
}
