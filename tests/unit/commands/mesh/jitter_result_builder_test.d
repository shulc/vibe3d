// Task 4560, Jitter slice: the result builder owns the one computation used by
// command and wrapper lifecycles.  The frozen literals below were captured
// from the pre-builder command at public SHA e4e6fb84252af8bc60dcd1c9026497abd4826a8c;
// no expectation in the anchor is recomputed through the new builder.
module tests.unit.commands.mesh.jitter_result_builder_test;

import std.format : format;
import std.math : fabs, sqrt;

import change_bus : MeshEditScope, changeBus;
import command_history : CommandHistory;
import commands.mesh.jitter : MeshJitter;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.vertex_position_result : VertexPositionResult;
import display_sync : activeMeshResolver;
import document : primaryModelSpaceResolver;
import editmode : EditMode;
import falloff : evaluateFalloff;
import math : ModelSpace, Vec3, aimSpace, projectToWindowFull;
import mesh : Mesh, makeCube;
import operator : VectorStack;
import toolpipe.packets : FalloffPacket, FalloffShape, FalloffType,
                          SubjectPacket;
import tools.common.command_wrapper : XfrmJitterTool;
import view : View;

private immutable Vec3[8] kAnchorBaseline = [
    Vec3(-0.5f, -0.5f, -0.5f), Vec3( 0.5f, -0.5f, -0.5f),
    Vec3( 0.5f,  0.5f, -0.5f), Vec3(-0.5f,  0.5f, -0.5f),
    Vec3(-0.5f, -0.5f,  0.5f), Vec3( 0.5f, -0.5f,  0.5f),
    Vec3( 0.5f,  0.5f,  0.5f), Vec3(-0.5f,  0.5f,  0.5f),
];
private immutable Vec3 kAnchorAfter6 = Vec3(
    0x1.538aa2p-2f, 0x1.e832ccp-3f, 0x1.9dd77p-1f);
private immutable Vec3 kAnchorDelta6 = Vec3(
    -0x1.58eabcp-3f, -0x1.0be69ap-2f, 0x1.3baeep-2f);

private Mesh cubeStand(int selected = -1) {
    Mesh m = makeCube();
    m.buildLoops();
    m.syncSelection();
    if (selected >= 0) m.selectVertex(selected);
    return m;
}

private Mesh asymmetricStand() {
    Mesh m;
    m.vertices = [
        Vec3(-1.20f, -0.75f,  0.05f),
        Vec3( 0.00f, -0.62f,  0.00f),
        Vec3( 1.35f, -0.90f,  0.12f),
        Vec3(-0.92f,  0.91f, -0.16f),
        Vec3( 0.08f,  0.68f,  0.00f),
        Vec3( 1.08f,  1.16f,  0.18f),
    ];
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.buildLoops();
    m.syncSelection();
    m.selectVertex(5);
    return m;
}

private void setFloat(MeshJitter cmd, string name, float value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.fptr = value;
        return;
    }
    assert(false, "missing float parameter " ~ name);
}

private void setInt(MeshJitter cmd, string name, int value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.iptr = value;
        return;
    }
    assert(false, "missing int parameter " ~ name);
}

private void setBool(MeshJitter cmd, string name, bool value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.bptr = value;
        return;
    }
    assert(false, "missing bool parameter " ~ name);
}

private void configureAnchor(MeshJitter cmd) {
    setFloat(cmd, "rangeX", 0.17f);
    setFloat(cmd, "rangeY", 0.31f);
    setFloat(cmd, "rangeZ", 0.47f);
    setInt(cmd, "seed", 1749);
    setBool(cmd, "enableX", true);
    setBool(cmd, "enableY", true);
    setBool(cmd, "enableZ", true);
}

private void putSubject(ref VectorStack vts, ref SubjectPacket subj,
                        Mesh* mesh, ref View view) {
    subj.mesh = mesh;
    subj.editMode = EditMode.Vertices;
    subj.viewport = view.viewport();
    vts.put(&subj);
}

private size_t resultOffset(ref const VertexPositionResult result, uint vi) {
    foreach (i, candidate; result.indices)
        if (candidate == vi) return i;
    assert(false, format("result has no vertex %s", vi));
}

private Vec3 displacement(ref const VertexPositionResult result, uint vi) {
    const i = resultOffset(result, vi);
    return result.after[i] - result.before[i];
}

private bool close(float a, float b, float eps = 1e-6f) {
    return fabs(a - b) <= eps;
}

private void assertScaled(Vec3 actual, Vec3 raw, float weight,
                          string label) {
    assert(close(actual.x, raw.x * weight) &&
           close(actual.y, raw.y * weight) &&
           close(actual.z, raw.z * weight), format(
        "%s used the wrong position image for falloff: actual=(%.9g,%.9g,%.9g) " ~
        "raw=(%.9g,%.9g,%.9g) baselineWeight=%.9g",
        label, actual.x, actual.y, actual.z,
        raw.x, raw.y, raw.z, weight));
}

unittest { // frozen pre-builder command anchor: builder and direct command
    Mesh builderMesh = cubeStand(6);
    assert(builderMesh.vertices == kAnchorBaseline,
        "frozen Jitter anchor baseline/order changed before evaluation");
    View view = new View(0, 0, 800, 600);
    auto builder = new MeshJitter(&builderMesh, view, EditMode.Vertices);
    configureAnchor(builder);
    SubjectPacket subject;
    VectorStack vts;
    putSubject(vts, subject, &builderMesh, view);
    VertexPositionResult result;
    assert(builder.buildVertexPositionResult(kAnchorBaseline[], vts, result));
    assert(result.indices.length == 1 && result.before.length == 1 &&
           result.after.length == 1 && result.indices[0] == 6,
        "frozen Jitter anchor population must be exactly late vertex 6");
    assert(result.before[0] == kAnchorBaseline[6]);

    // This control deliberately precedes the absolute anchor: moving RNG
    // consumption below the mask must name the sparse/full law, while a seed
    // change preserves sparse/full equality and reaches the frozen literals.
    Mesh fullMesh = cubeStand();
    auto fullBuilder = new MeshJitter(&fullMesh, view, EditMode.Vertices);
    configureAnchor(fullBuilder);
    SubjectPacket fullSubject;
    VectorStack fullVts;
    putSubject(fullVts, fullSubject, &fullMesh, view);
    VertexPositionResult fullResult;
    assert(fullBuilder.buildVertexPositionResult(kAnchorBaseline[], fullVts,
                                                 fullResult));
    assert(fullResult.indices.length == 8,
        "frozen RNG control must populate all 8 full-selection vertices");
    assert(displacement(fullResult, 6) == displacement(result, 6),
        "Jitter RNG moved after the selection mask: late vertex 6 differs " ~
        "between full and sparse selection");

    assert(result.after[0] == kAnchorAfter6 &&
           result.after[0] - result.before[0] == kAnchorDelta6, format(
        "FROZEN Jitter anchor changed: got pos=(%.9g,%.9g,%.9g) " ~
        "delta=(%.9g,%.9g,%.9g)",
        result.after[0].x, result.after[0].y, result.after[0].z,
        displacement(result, 6).x, displacement(result, 6).y,
        displacement(result, 6).z));

    Mesh directMesh = cubeStand(6);
    auto direct = new MeshJitter(&directMesh, view, EditMode.Vertices);
    configureAnchor(direct);
    SubjectPacket directSubject;
    VectorStack directVts;
    putSubject(directVts, directSubject, &directMesh, view);
    assert(direct.evaluate(directVts));
    assert(directMesh.vertices.length == kAnchorBaseline.length);
    foreach (i; 0 .. directMesh.vertices.length) {
        const expected = i == 6 ? kAnchorAfter6 : kAnchorBaseline[i];
        assert(directMesh.vertices[i] == expected, format(
            "direct Jitter diverged from frozen anchor at vertex %s", i));
    }
}

unittest { // RNG stream is selection- and axis-invariant
    View view = new View(0, 0, 800, 600);
    Mesh fullMesh = cubeStand();
    auto full = new MeshJitter(&fullMesh, view, EditMode.Vertices);
    configureAnchor(full);
    SubjectPacket fullSubject;
    VectorStack fullVts;
    putSubject(fullVts, fullSubject, &fullMesh, view);
    VertexPositionResult fullResult;
    assert(full.buildVertexPositionResult(kAnchorBaseline[], fullVts, fullResult));
    assert(fullResult.indices.length == 8,
        "full-selection RNG control must populate all 8 vertices");

    Mesh sparseMesh = cubeStand(6);
    auto sparse = new MeshJitter(&sparseMesh, view, EditMode.Vertices);
    configureAnchor(sparse);
    SubjectPacket sparseSubject;
    VectorStack sparseVts;
    putSubject(sparseVts, sparseSubject, &sparseMesh, view);
    VertexPositionResult sparseResult;
    assert(sparse.buildVertexPositionResult(kAnchorBaseline[], sparseVts,
                                            sparseResult));
    assert(sparseResult.indices.length == 1 && sparseResult.indices[0] == 6,
        "sparse RNG control must populate exactly late vertex 6");
    assert(displacement(fullResult, 6) == displacement(sparseResult, 6),
        "Jitter RNG moved after the selection mask: late vertex 6 differs " ~
        "between full and sparse selection");

    Mesh gatedMesh = cubeStand(6);
    auto gated = new MeshJitter(&gatedMesh, view, EditMode.Vertices);
    configureAnchor(gated);
    setBool(gated, "enableX", false);
    SubjectPacket gatedSubject;
    VectorStack gatedVts;
    putSubject(gatedVts, gatedSubject, &gatedMesh, view);
    VertexPositionResult gatedResult;
    assert(gated.buildVertexPositionResult(kAnchorBaseline[], gatedVts,
                                           gatedResult));
    assert(gatedResult.indices.length == 1 && gatedResult.indices[0] == 6,
        "axis-gated RNG control must retain one populated vertex");
    const allDelta = displacement(sparseResult, 6);
    const gatedDelta = displacement(gatedResult, 6);
    assert(gatedDelta.x == 0.0f && gatedDelta.y == allDelta.y &&
           gatedDelta.z == allDelta.z,
        "Jitter RNG became conditional on enableX: retained Y/Z components " ~
        "changed or disabled X moved");
}

unittest { // Screen and Lasso weights read the explicit baseline
    auto savedModelSpace = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = savedModelSpace;
    primaryModelSpaceResolver = () => ModelSpace.world();

    Mesh subject = asymmetricStand();
    const baseline = subject.vertices.dup;
    auto live = baseline.dup;
    live[5] = live[5] + Vec3(2.6f, -1.9f, 0.65f);
    subject.vertices[] = live[];
    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshJitter(&subject, view, EditMode.Vertices);
    configureAnchor(cmd);
    SubjectPacket subj;
    VectorStack plainVts;
    putSubject(plainVts, subj, &subject, view);
    VertexPositionResult raw;
    assert(cmd.buildVertexPositionResult(baseline, plainVts, raw));
    assert(raw.indices.length == 1 && raw.indices[0] == 5,
        "falloff control must populate exactly selected late vertex 5");
    const rawDelta = displacement(raw, 5);

    const aim = aimSpace(subj.viewport, ModelSpace.world());
    float bx, by, bz, lx, ly, lz;
    assert(projectToWindowFull(baseline[5], aim.vp, bx, by, bz) &&
           projectToWindowFull(live[5], aim.vp, lx, ly, lz),
        "Jitter falloff stand must project through a real viewport");
    const pixelDistance = sqrt((lx - bx) * (lx - bx) + (ly - by) * (ly - by));
    assert(pixelDistance > 30.0f, format(
        "falloff position images must project differently first; %.9g px",
        pixelDistance));

    FalloffPacket screen;
    screen.enabled = true;
    screen.type = FalloffType.Screen;
    screen.shape = FalloffShape.Linear;
    screen.transparent = true;
    screen.screenCx = bx;
    screen.screenCy = by;
    screen.screenSize = pixelDistance * 1.25f;
    const screenBaselineWeight = evaluateFalloff(
        screen, baseline[5], 5, aim);
    const screenLiveWeight = evaluateFalloff(screen, live[5], 5, aim);
    assert(fabs(screenBaselineWeight - screenLiveWeight) > 0.50f, format(
        "Screen baseline/live weights must differ first; baseline=%.9g live=%.9g",
        screenBaselineWeight, screenLiveWeight));
    SubjectPacket screenSubject;
    VectorStack screenVts;
    putSubject(screenVts, screenSubject, &subject, view);
    screenVts.put(&screen);
    VertexPositionResult screenResult;
    assert(cmd.buildVertexPositionResult(baseline, screenVts, screenResult));
    assert(screenResult.indices.length == 1 && screenResult.indices[0] == 5,
        "Screen result population must be exactly one selected vertex");
    assertScaled(displacement(screenResult, 5), rawDelta,
                 screenBaselineWeight, "Screen Jitter");

    FalloffPacket lasso;
    lasso.enabled = true;
    lasso.type = FalloffType.Lasso;
    lasso.shape = FalloffShape.Linear;
    lasso.transparent = true;
    const half = 12.0f;
    lasso.lassoPolyX = [bx - half, bx + half, bx + half, bx - half];
    lasso.lassoPolyY = [by - half, by - half, by + half, by + half];
    lasso.softBorderPx = 6.0f;
    const lassoBaselineWeight = evaluateFalloff(
        lasso, baseline[5], 5, aim);
    const lassoLiveWeight = evaluateFalloff(lasso, live[5], 5, aim);
    assert(fabs(lassoBaselineWeight - lassoLiveWeight) > 0.50f, format(
        "Lasso baseline/live weights must differ first; baseline=%.9g live=%.9g",
        lassoBaselineWeight, lassoLiveWeight));
    SubjectPacket lassoSubject;
    VectorStack lassoVts;
    putSubject(lassoVts, lassoSubject, &subject, view);
    lassoVts.put(&lasso);
    VertexPositionResult lassoResult;
    assert(cmd.buildVertexPositionResult(baseline, lassoVts, lassoResult));
    assert(lassoResult.indices.length == 1 && lassoResult.indices[0] == 5,
        "Lasso result population must be exactly one selected vertex");
    assertScaled(displacement(lassoResult, 5), rawDelta,
                 lassoBaselineWeight, "Lasso Jitter");
    assert(subject.vertices == live,
        "falloff result construction changed the occupied live preview");
}

unittest { // bound Subject marks win over a same-sized decoy primary
    Mesh bound = cubeStand(6);
    Mesh decoy = cubeStand(1);
    View view = new View(0, 0, 800, 600);
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &decoy;
    scope(exit) activeMeshResolver = savedResolver;

    auto cmd = new MeshJitter(&bound, view, EditMode.Vertices);
    configureAnchor(cmd);
    SubjectPacket boundSubject;
    VectorStack boundVts;
    putSubject(boundVts, boundSubject, &bound, view);
    VertexPositionResult result;
    assert(cmd.buildVertexPositionResult(bound.vertices, boundVts, result));
    assert(result.indices.length == 1 && result.indices[0] == 6,
        "Jitter marks came from decoy primary instead of bound Subject mesh");

    SubjectPacket wrongSubject;
    VectorStack wrongVts;
    putSubject(wrongVts, wrongSubject, &decoy, view);
    assert(!cmd.buildVertexPositionResult(bound.vertices, wrongVts, result),
        "same-sized decoy primary replaced Jitter's bound Subject");
}

private void historyCounts(CommandHistory history,
                           out size_t model, out size_t ui) {
    history.undoDepthCounts(model, ui);
}

unittest { // accepted all-hidden and zero-range no-ops keep history traversable
    View view = new View(0, 0, 800, 600);

    Mesh hiddenMesh = cubeStand(6);
    const hiddenBaseline = hiddenMesh.vertices.dup;
    auto hiddenHistory = new CommandHistory();
    auto realHidden = new MeshJitter(&hiddenMesh, view, EditMode.Vertices);
    configureAnchor(realHidden);
    assert(hiddenHistory.fire(realHidden));
    hiddenMesh.deselectVertex(6);
    foreach (ref mark; hiddenMesh.vertexMarks) mark |= Mesh.Marks.Hide;
    auto hiddenNoop = new MeshJitter(&hiddenMesh, view, EditMode.Vertices);
    configureAnchor(hiddenNoop);
    assert(hiddenHistory.fire(hiddenNoop),
        "all-hidden Jitter must remain an accepted no-op");
    size_t model, ui;
    historyCounts(hiddenHistory, model, ui);
    assert(model == 2 && ui == 0,
        "all-hidden no-op must remain a populated Model history entry");
    assert(hiddenHistory.undo(), "undo of all-hidden Jitter no-op was refused");
    historyCounts(hiddenHistory, model, ui);
    assert(model == 1, "all-hidden no-op undo must pop exactly one entry");
    assert(hiddenHistory.undo(), "real Jitter below all-hidden no-op was lost");
    assert(hiddenMesh.vertices == hiddenBaseline,
        "all-hidden no-op sequence did not restore the earlier real Jitter");

    Mesh zeroMesh = cubeStand(6);
    const zeroBaseline = zeroMesh.vertices.dup;
    auto zeroHistory = new CommandHistory();
    auto realZero = new MeshJitter(&zeroMesh, view, EditMode.Vertices);
    configureAnchor(realZero);
    assert(zeroHistory.fire(realZero));
    auto zeroNoop = new MeshJitter(&zeroMesh, view, EditMode.Vertices);
    setFloat(zeroNoop, "rangeX", 0.0f);
    setFloat(zeroNoop, "rangeY", 0.0f);
    setFloat(zeroNoop, "rangeZ", 0.0f);
    setInt(zeroNoop, "seed", 1749);
    assert(zeroHistory.fire(zeroNoop),
        "zero-range Jitter must remain an accepted no-op");
    historyCounts(zeroHistory, model, ui);
    assert(model == 2 && ui == 0,
        "zero-range no-op must remain a populated Model history entry");
    assert(zeroHistory.undo(), "undo of zero-range Jitter no-op was refused");
    historyCounts(zeroHistory, model, ui);
    assert(model == 1, "zero-range no-op undo must pop exactly one entry");
    assert(zeroHistory.undo(), "real Jitter below zero-range no-op was lost");
    assert(zeroMesh.vertices == zeroBaseline,
        "zero-range no-op sequence did not restore the earlier real Jitter");
}

unittest { // occupied-preview refire construction is observationally pure
    Mesh target = cubeStand(6);
    const sessionBaseline = target.vertices.dup;
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory();
    auto tool = new XfrmJitterTool(&target, view, EditMode.Vertices, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&target, view, EditMode.Vertices));

    auto savedResolver = activeMeshResolver;
    Mesh offscreen = cubeStand(1);
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;
    const subscriberCheckpoint = changeBus.meshSubscriberCheckpointForTest();
    scope(exit) changeBus.restoreMeshSubscribersForTest(subscriberCheckpoint);

    size_t records;
    history.onRecord = (string, uint) { ++records; };
    tool.activate();
    scope(exit) {
        tool.cancelUncommittedEdit();
        tool.deactivate();
    }
    foreach (ref p; tool.params()) {
        if (p.name == "rangeX") *p.fptr = 0.17f;
        if (p.name == "rangeY") *p.fptr = 0.31f;
        if (p.name == "rangeZ") *p.fptr = 0.47f;
        if (p.name == "seed") *p.iptr = 1749;
    }
    tool.onParamChanged("rangeX");
    tool.evaluate();
    const occupiedPreview = target.vertices.dup;
    assert(occupiedPreview != sessionBaseline,
        "control: Jitter refire purity needs a non-empty occupied preview");

    foreach (ref p; tool.params())
        if (p.name == "rangeX") *p.fptr = 0.29f;

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
    assert(refire !is null && !refire.isEmpty(),
        "Jitter refire must build a populated deterministic carrier");
    assert(targetCallbacks == 0, format(
        "Jitter refire construction published %s Position callback(s); " ~
        "callback observed different positions=%s",
        targetCallbacks, callbackSawDifferentPositions));
    assert(!callbackSawDifferentPositions,
        "Jitter refire callback observed temporary live positions");
    assert(target.vertices == occupiedPreview,
        "Jitter refire construction changed the occupied preview");
    assert(changeBus.deliveryCount == deliveriesBefore &&
           changeBus.totalPosition == positionsBefore,
        "Jitter refire construction changed bus delivery counters");
    assert(target.mutationVersion == mutationBefore &&
           target.topologyVersion == topologyBefore &&
           target.structVersion == structureBefore &&
           target.marksVersion == marksBefore,
        "Jitter refire construction changed mesh counters");
    assert(records == recordsBefore && !history.canUndo(),
        "Jitter refire construction changed history");
}
