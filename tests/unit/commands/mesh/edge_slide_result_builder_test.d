module tests.unit.commands.mesh.edge_slide_result_builder_test;

import change_bus : changeBus, MeshEditScope;
import command_history : CommandHistory;
import commands.mesh.edge_slide : MeshEdgeSlide;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.vertex_position_result : VertexPositionResult;
import display_sync : activeMeshResolver;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, edgeSlidePositions;
import operator : VectorStack;
import toolpipe.packets : FalloffPacket, FalloffType, SubjectPacket;
import tools.slice.edge_slide : EdgeSlideTool;
import view : View;

private Mesh asymmetricOpenStrip(out bool[] selected) {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f, -0.5f,  0.2f),
        Vec3( 1.0f,  0.0f,  0.0f),
        Vec3( 1.0f,  2.0f,  0.5f),
        Vec3(-0.5f,  2.5f, -0.3f),
        Vec3( 3.0f, -0.5f,  0.2f),
        Vec3( 2.5f,  3.0f,  1.0f),
    ];
    m.makePolygonFromVerts([0, 1, 2, 3], false);
    m.makePolygonFromVerts([1, 4, 5, 2], false);
    m.buildLoops();
    selected = new bool[](m.edges.length);
    const uint sharedEdge = m.edgeIndex(1, 2);
    assert(sharedEdge != uint.max, "fixture: shared strip edge must exist");
    selected[sharedEdge] = true;
    m.selectEdgesFrom(selected);
    return m;
}

private void setT(EdgeSlideTool tool, float value) {
    foreach (ref p; tool.params()) if (p.name == "t") {
        *p.fptr = value;
        return;
    }
    assert(false, "EdgeSlideTool lost its t parameter");
}

private size_t changedCount(const(Vec3)[] a, const(Vec3)[] b) {
    assert(a.length == b.length);
    size_t result;
    foreach (i; 0 .. a.length) if (a[i] != b[i]) ++result;
    return result;
}

private void putSubject(ref VectorStack vts, ref SubjectPacket subject,
                        Mesh* mesh, ref View view) {
    subject.mesh = mesh;
    subject.editMode = EditMode.Edges;
    subject.viewport = view.viewport();
    vts.put(&subject);
}

private Vec3 afterFor(ref const VertexPositionResult result, uint vertex) {
    foreach (i, vi; result.indices) if (vi == vertex) return result.after[i];
    assert(false, "result does not contain vertex");
}

private bool approx(Vec3 a, Vec3 b, float eps = 1.0e-5f) {
    import std.math : abs;
    return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps &&
           abs(a.z - b.z) <= eps;
}

unittest { // preview, cancel, drop, undo and redo preserve the wrapper lifecycle
    bool[] selected;
    Mesh target = asymmetricOpenStrip(selected);
    const baseline = target.vertices.dup;
    const previewExpected = edgeSlidePositions(target, selected, 0.25f);
    assert(changedCount(baseline, previewExpected) == 2,
        "fixture: the asymmetric strip must move both shared-edge endpoints");

    Mesh decoy;
    bool[] ignored;
    decoy = asymmetricOpenStrip(ignored);
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &decoy;
    scope(exit) activeMeshResolver = savedResolver;

    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;
    size_t records;
    history.onRecord = (string, uint) { ++records; };
    auto tool = new EdgeSlideTool(&target, view, EditMode.Edges, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&target, view, EditMode.Edges));
    tool.activate();

    setT(tool, 0.25f);
    tool.onParamChanged("t");
    tool.evaluate();
    assert(target.vertices == previewExpected,
        "EdgeSlide preview did not install the expected sparse result");
    assert(tool.hasUncommittedEdit() && records == 0,
        "preview must be dirty without recording history");

    tool.cancelUncommittedEdit();
    assert(target.vertices == baseline && !tool.hasUncommittedEdit() && records == 0,
        "cancel must restore baseline without recording history");

    const dropExpected = edgeSlidePositions(target, selected, -0.6f);
    assert(changedCount(baseline, dropExpected) == 2,
        "fixture: negative drop must move both endpoints");
    setT(tool, -0.6f);
    tool.onParamChanged("t");
    tool.evaluate();
    assert(target.vertices == dropExpected);
    tool.deactivate();
    assert(target.vertices == dropExpected && records == 1 && history.canUndo(),
        "drop must retain preview and record exactly one history entry");
    assert(history.undo() && target.vertices == baseline,
        "wrapper undo must restore the session baseline");
    assert(history.redo() && target.vertices == dropExpected,
        "wrapper redo must reinstall the dropped preview");
}

unittest { // refire builds the next command from the session baseline
    bool[] selected;
    Mesh target = asymmetricOpenStrip(selected);
    const baseline = target.vertices.dup;
    const expected = edgeSlidePositions(target, selected, 0.75f);
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;
    auto tool = new EdgeSlideTool(&target, view, EditMode.Edges, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&target, view, EditMode.Edges));

    Mesh decoy;
    bool[] ignored;
    decoy = asymmetricOpenStrip(ignored);
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &decoy;
    scope(exit) activeMeshResolver = savedResolver;

    tool.activate();
    setT(tool, 0.2f);
    tool.onParamChanged("t");
    tool.evaluate();
    assert(changedCount(baseline, target.vertices) == 2,
        "fixture: refire needs an occupied live preview");

    setT(tool, 0.75f);
    auto refire = cast(MeshVertexEdit)tool.buildRefireCommand();
    assert(refire !is null && refire.editIndices.length == 2,
        "refire must produce a populated two-vertex carrier");
    assert(refire.apply() && target.vertices == expected,
        "firing the refire carrier must install the baseline-derived result");
    size_t model, ui;
    history.undoDepthCounts(model, ui);
    assert(model == 0 && ui == 0,
        "constructing and directly firing an unrecorded refire changed history");
}

unittest { // explicit baseline owns both the moving endpoint and stationary rail
    bool[] selected;
    Mesh subject = asymmetricOpenStrip(selected);
    const baseline = subject.vertices.dup;
    Vec3[] live = baseline.dup;
    live[1] = Vec3(11.0f, 7.0f, -3.0f); // selected endpoint
    live[4] = Vec3(31.0f, 9.0f,  5.0f); // unselected stationary rail
    subject.vertices[] = live[];

    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshEdgeSlide(&subject, view, EditMode.Edges);
    cmd.setT(0.25f);
    SubjectPacket packet;
    VectorStack vts;
    putSubject(vts, packet, &subject, view);
    FalloffPacket ignoredFalloff;
    ignoredFalloff.enabled = true;
    ignoredFalloff.type = FalloffType.Linear;
    ignoredFalloff.start = Vec3(100, 100, 100);
    ignoredFalloff.end = Vec3(101, 100, 100);
    vts.put(&ignoredFalloff);

    VertexPositionResult result;
    assert(cmd.buildVertexPositionResult(baseline, vts, result));
    assert(result.indices == [1u, 2u],
        "baseline result population must be the two selected-edge endpoints");
    const actual = afterFor(result, 1);
    const expected = Vec3(1.5f, -0.125f, 0.05f);
    const endpointFromLive = live[1] + 0.25f * (baseline[4] - live[1]);
    const railFromLive = baseline[1] + 0.25f * (live[4] - baseline[1]);
    assert(!approx(actual, endpointFromLive),
        "EdgeSlide builder read the moving endpoint from live preview");
    assert(!approx(actual, railFromLive),
        "EdgeSlide builder read the stationary rail endpoint from live preview");
    assert(approx(actual, expected),
        "EdgeSlide builder did not use the explicit baseline for both endpoints");
    assert(approx(afterFor(result, 2), Vec3(1.375f, 2.25f, 0.625f)) &&
           subject.vertices == live,
        "pure EdgeSlide result construction changed or read the live preview");
    foreach (vi; result.indices) assert(vi != 4,
        "stationary rail endpoint entered the sparse result");
}

unittest { // explicit-position overload preserves both clamp limits and signs
    bool[] selected;
    Mesh subject = asymmetricOpenStrip(selected);
    const source = subject.vertices.dup;
    const positiveLimit = edgeSlidePositions(subject, source, selected, 1.0f);
    const negativeLimit = edgeSlidePositions(subject, source, selected, -1.0f);
    assert(positiveLimit != negativeLimit &&
           edgeSlidePositions(subject, source, selected, 3.0f) == positiveLimit &&
           edgeSlidePositions(subject, source, selected, -3.0f) == negativeLimit,
        "explicit EdgeSlide positions lost signed clamp behaviour");
    assert(edgeSlidePositions(subject, source, selected, 0.0f) == source,
        "explicit EdgeSlide t=0 must remain identity");
}

unittest { // bound Subject selection wins over a same-sized decoy primary
    bool[] selected, ignored;
    Mesh bound = asymmetricOpenStrip(selected);
    Mesh decoy = asymmetricOpenStrip(ignored);
    decoy.selectEdgesFrom(new bool[](decoy.edges.length));
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &decoy;
    scope(exit) activeMeshResolver = savedResolver;

    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshEdgeSlide(&bound, view, EditMode.Edges);
    cmd.setT(0.4f);
    SubjectPacket packet;
    VectorStack vts;
    putSubject(vts, packet, &bound, view);
    VertexPositionResult result;
    assert(cmd.buildVertexPositionResult(bound.vertices, vts, result) &&
           result.indices.length == 2,
        "EdgeSlide builder read selection from decoy primary instead of bound Subject");

    SubjectPacket wrongPacket;
    VectorStack wrongVts;
    putSubject(wrongVts, wrongPacket, &decoy, view);
    assert(!cmd.buildVertexPositionResult(bound.vertices, wrongVts, result),
        "same-sized decoy primary replaced EdgeSlide's bound Subject");
}

unittest { // accepted t=0 no-op remains a populated, traversable history row
    bool[] selected;
    Mesh target = asymmetricOpenStrip(selected);
    const baseline = target.vertices.dup;
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;

    auto realCmd = new MeshEdgeSlide(&target, view, EditMode.Edges);
    realCmd.setT(0.4f);
    assert(history.fire(realCmd));
    const occupied = target.vertices.dup;
    assert(changedCount(baseline, occupied) == 2,
        "fixture: real EdgeSlide below the no-op must move two vertices");

    auto noop = new MeshEdgeSlide(&target, view, EditMode.Edges);
    noop.setT(0.0f);
    assert(history.fire(noop), "t=0 EdgeSlide must remain an accepted no-op");
    size_t model, ui;
    history.undoDepthCounts(model, ui);
    assert(model == 2 && ui == 0,
        "t=0 no-op must remain a populated Model history entry");
    assert(history.undo() && target.vertices == occupied,
        "undoing t=0 must pop one row without changing occupied geometry");
    history.undoDepthCounts(model, ui);
    assert(model == 1, "t=0 undo removed the earlier real EdgeSlide row");
    assert(history.undo() && target.vertices == baseline,
        "earlier real EdgeSlide was lost below the accepted no-op");
}

private uint floatBits(float value) @trusted {
    return *cast(uint*)&value;
}

unittest { // component equality filters populated signed-zero-only candidates
    bool[] selected;
    Mesh subject = asymmetricOpenStrip(selected);
    subject.vertices[1] = Vec3(-0.0f, 1.0f, -0.0f);
    subject.vertices[4] = Vec3( 0.0f, 1.0f,  0.0f);
    subject.vertices[2] = Vec3(-0.0f, 2.0f, -0.0f);
    subject.vertices[5] = Vec3( 0.0f, 2.0f,  0.0f);
    const baseline = subject.vertices.dup;
    const dense = edgeSlidePositions(subject, baseline, selected, 1.0f);
    size_t bitOnlyPopulation;
    foreach (i; 0 .. baseline.length) {
        assert(dense[i] == baseline[i],
            "signed-zero fixture changed a component numerically");
        if (floatBits(dense[i].x) != floatBits(baseline[i].x) ||
            floatBits(dense[i].y) != floatBits(baseline[i].y) ||
            floatBits(dense[i].z) != floatBits(baseline[i].z))
            ++bitOnlyPopulation;
    }
    assert(bitOnlyPopulation == 2,
        "signed-zero fixture must populate exactly two bit-only candidates");

    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshEdgeSlide(&subject, view, EditMode.Edges);
    cmd.setT(1.0f);
    SubjectPacket packet;
    VectorStack vts;
    putSubject(vts, packet, &subject, view);
    VertexPositionResult result;
    assert(cmd.buildVertexPositionResult(baseline, vts, result) && result.empty,
        "component-wise equality must filter signed-zero-only EdgeSlide candidates");
}

unittest { // occupied-preview refire construction is observationally pure
    bool[] selected;
    Mesh target = asymmetricOpenStrip(selected);
    const baseline = target.vertices.dup;
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;
    size_t records;
    history.onRecord = (string, uint) { ++records; };
    auto tool = new EdgeSlideTool(&target, view, EditMode.Edges, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&target, view, EditMode.Edges));

    Mesh decoy;
    bool[] ignored;
    decoy = asymmetricOpenStrip(ignored);
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &decoy;
    scope(exit) activeMeshResolver = savedResolver;
    const subscriberCheckpoint = changeBus.meshSubscriberCheckpointForTest();
    scope(exit) changeBus.restoreMeshSubscribersForTest(subscriberCheckpoint);

    tool.activate();
    setT(tool, 0.2f);
    tool.onParamChanged("t");
    tool.evaluate();
    const occupiedPreview = target.vertices.dup;
    assert(changedCount(baseline, occupiedPreview) == 2,
        "fixture: purity check needs a non-empty occupied preview");
    setT(tool, 0.75f);

    size_t targetCallbacks;
    bool callbackSawDifferentPositions;
    changeBus.onMeshChanged((size_t subjectAddr, uint flags) nothrow {
        if (subjectAddr != cast(size_t)&target ||
            !(flags & MeshEditScope.Position)) return;
        ++targetCallbacks;
        if (target.vertices.length != occupiedPreview.length) {
            callbackSawDifferentPositions = true;
            return;
        }
        foreach (i; 0 .. target.vertices.length)
            if (target.vertices[i] != occupiedPreview[i]) {
                callbackSawDifferentPositions = true;
                return;
            }
    });

    const deliveriesBefore = changeBus.deliveryCount;
    const positionsBefore = changeBus.totalPosition;
    const mutationBefore = target.mutationVersion;
    const topologyBefore = target.topologyVersion;
    const structureBefore = target.structVersion;
    const marksBefore = target.marksVersion;
    const recordsBefore = records;

    auto refire = cast(MeshVertexEdit)tool.buildRefireCommand();
    assert(refire !is null && refire.editIndices.length == 2,
        "EdgeSlide refire must build a populated deterministic carrier");
    assert(targetCallbacks == 0 && !callbackSawDifferentPositions,
        "EdgeSlide refire construction exposed a temporary live Position write");
    assert(target.vertices == occupiedPreview,
        "EdgeSlide refire construction changed the occupied preview");
    assert(changeBus.deliveryCount == deliveriesBefore &&
           changeBus.totalPosition == positionsBefore,
        "EdgeSlide refire construction changed bus delivery counters");
    assert(target.mutationVersion == mutationBefore &&
           target.topologyVersion == topologyBefore &&
           target.structVersion == structureBefore &&
           target.marksVersion == marksBefore,
        "EdgeSlide refire construction changed mesh counters");
    assert(records == recordsBefore && !history.canUndo(),
        "EdgeSlide refire construction changed history");
}
