// Task 4560, Smooth slice: the deterministic result must derive every
// position-dependent quantity from the explicit baseline even while the bound
// subject contains a later preview.  Preserve and lockSharp deliberately have
// separate cells and independently-selectable test seams: either live-normal
// substitution must fail its own cell with the other option disabled.
module tests.unit.commands.mesh.smooth_result_builder_test;

import std.algorithm : max;
import std.format : format;
import std.math : acos, fabs, PI;

import commands.mesh.smooth : MeshSmooth;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.vertex_position_result : VertexPositionResult;
import command_history : CommandHistory;
import change_bus : MeshEditScope, changeBus;
import display_sync : activeMeshResolver;
import document : primaryModelSpaceResolver;
import editmode : EditMode;
import falloff : evaluateFalloff;
import math : AimViewport, ModelSpace, Vec3, aimSpace, cross, dot,
              projectToWindowFull;
import mesh : Mesh, makeCube;
import operator : VectorStack;
import toolpipe.packets : FalloffPacket, FalloffShape, FalloffType,
                          SubjectPacket;
import view : View;
import tools.common.command_wrapper : XfrmSmoothTool;

private Mesh openAsymmetricStand() {
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
    return m;
}

private Vec3[] livePreviewImage(const(Vec3)[] baseline) {
    auto live = baseline.dup;
    live[0].z -= 0.55f;
    live[2].z += 1.75f;
    live[3].z += 0.72f;
    live[5].z += 1.05f;
    return live;
}

private Vec3 faceNormal(const ref Mesh m, uint fi, const(Vec3)[] pos) {
    const f = m.faces[fi];
    Vec3 n = cross(pos[f[1]] - pos[f[0]], pos[f[2]] - pos[f[0]]);
    return n * (1.0f / n.length);
}

private float normalDiff(Vec3 a, Vec3 b) {
    return max(fabs(a.x - b.x), max(fabs(a.y - b.y), fabs(a.z - b.z)));
}

private float dihedralDeg(const ref Mesh m, const(Vec3)[] pos) {
    float d = dot(faceNormal(m, 0, pos), faceNormal(m, 1, pos));
    if (d < -1.0f) d = -1.0f;
    if (d >  1.0f) d =  1.0f;
    return acos(d) * (180.0f / PI);
}

private Vec3[] fullResult(const(Vec3)[] source,
                          ref const VertexPositionResult result) {
    auto out_ = source.dup;
    foreach (i, vi; result.indices) out_[vi] = result.after[i];
    return out_;
}

private float maxPositionDiff(const(Vec3)[] a, const(Vec3)[] b) {
    assert(a.length == b.length);
    float d = 0.0f;
    foreach (i; 0 .. a.length)
        d = max(d, max(fabs(a[i].x - b[i].x),
                   max(fabs(a[i].y - b[i].y), fabs(a[i].z - b[i].z))));
    return d;
}

private void setFloat(MeshSmooth cmd, string name, float value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.fptr = value;
        return;
    }
    assert(false, "missing float parameter " ~ name);
}

private void setInt(MeshSmooth cmd, string name, int value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.iptr = value;
        return;
    }
    assert(false, "missing int parameter " ~ name);
}

private void setBool(MeshSmooth cmd, string name, bool value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        *p.bptr = value;
        return;
    }
    assert(false, "missing bool parameter " ~ name);
}

private void putSubject(ref VectorStack vts, ref SubjectPacket subj,
                        Mesh* mesh, ref View view) {
    subj.mesh = mesh;
    subj.editMode = EditMode.Vertices;
    subj.viewport = view.viewport();
    vts.put(&subj);
}

private void projectedBounds(const(Vec3)[] pos, ref const AimViewport aim,
                             out float minX, out float minY,
                             out float maxX, out float maxY) {
    minX = minY = float.max;
    maxX = maxY = -float.max;
    foreach (p; pos) {
        float x, y, z;
        assert(projectToWindowFull(p, aim.vp, x, y, z),
            "open Smooth stand must project into its real viewport");
        minX = x < minX ? x : minX;
        minY = y < minY ? y : minY;
        maxX = x > maxX ? x : maxX;
        maxY = y > maxY ? y : maxY;
    }
}

unittest { // preserve: baseline tangent normals, lockSharp OFF, Screen falloff
    auto savedModelSpace = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = savedModelSpace;
    primaryModelSpaceResolver = () => ModelSpace.world();

    Mesh subject = openAsymmetricStand();
    const baseline = subject.vertices.dup;
    const live = livePreviewImage(baseline);
    subject.vertices[] = live[];
    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&subject, view, EditMode.Vertices);
    setFloat(cmd, "strn", 0.73f);
    setInt(cmd, "iter", 4);
    setBool(cmd, "preserve", true);
    setBool(cmd, "lockSharp", false);

    SubjectPacket subj;
    VectorStack vts;
    putSubject(vts, subj, &subject, view);
    auto aim = aimSpace(subj.viewport, ModelSpace.world());
    float minX, minY, maxX, maxY;
    projectedBounds(baseline, aim, minX, minY, maxX, maxY);
    FalloffPacket screen;
    screen.enabled = true;
    screen.type = FalloffType.Screen;
    screen.shape = FalloffShape.Linear;
    screen.transparent = true;
    screen.screenCx = minX;
    screen.screenCy = (minY + maxY) * 0.5f;
    screen.screenSize = (maxX - minX) * 1.35f;
    vts.put(&screen);

    float minWeight = 1.0f, maxWeight = 0.0f;
    foreach (i, p; baseline) {
        const w = evaluateFalloff(screen, p, cast(int)i, aim);
        minWeight = w < minWeight ? w : minWeight;
        maxWeight = w > maxWeight ? w : maxWeight;
    }
    assert(maxWeight - minWeight > 0.20f, format(
        "Screen control needs distinct real-viewport weights; min=%.9g max=%.9g",
        minWeight, maxWeight));

    const tangentNormalDelta = max(
        normalDiff(faceNormal(subject, 0, baseline), faceNormal(subject, 0, live)),
        normalDiff(faceNormal(subject, 1, baseline), faceNormal(subject, 1, live)));
    assert(tangentNormalDelta > 0.20f, format(
        "preserve candidates baseline/live normals must differ first; max component %.9g",
        tangentNormalDelta));

    VertexPositionResult expected, liveNormalCandidate, actual;
    assert(cmd.buildVertexPositionResultWithNormalSourcesForTest(
        baseline, baseline, baseline, vts, expected));
    assert(cmd.buildVertexPositionResultWithNormalSourcesForTest(
        baseline, live, baseline, vts, liveNormalCandidate));
    const candidateDelta = maxPositionDiff(
        fullResult(baseline, expected), fullResult(baseline, liveNormalCandidate));
    assert(candidateDelta > 0.01f, format(
        "preserve baseline/live result candidates must differ first; max position %.9g",
        candidateDelta));
    assert(cmd.buildVertexPositionResult(baseline, vts, actual));
    assert(fullResult(baseline, actual) == fullResult(baseline, expected), format(
        "Smooth preserve read live tangent normals; candidate delta %.9g",
        candidateDelta));
    assert(subject.vertices == live,
        "pure preserve result construction changed the occupied live preview");
}

unittest { // lockSharp: baseline dihedral, preserve OFF, Lasso falloff
    auto savedModelSpace = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = savedModelSpace;
    primaryModelSpaceResolver = () => ModelSpace.world();

    Mesh subject = openAsymmetricStand();
    const baseline = subject.vertices.dup;
    const live = livePreviewImage(baseline);
    subject.vertices[] = live[];
    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&subject, view, EditMode.Vertices);
    setFloat(cmd, "strn", 0.73f);
    setInt(cmd, "iter", 4);
    setBool(cmd, "preserve", false);
    setBool(cmd, "lockSharp", true);

    const baselineAngle = dihedralDeg(subject, baseline);
    const liveAngle = dihedralDeg(subject, live);
    const threshold = (baselineAngle + liveAngle) * 0.5f;
    assert(baselineAngle < threshold && liveAngle > threshold &&
           liveAngle - baselineAngle > 20.0f, format(
        "lockSharp candidates must cross threshold first; baseline=%.9g° " ~
        "live=%.9g° threshold=%.9g°", baselineAngle, liveAngle, threshold));
    setFloat(cmd, "sharpAngle", threshold);

    SubjectPacket subj;
    VectorStack vts;
    putSubject(vts, subj, &subject, view);
    auto aim = aimSpace(subj.viewport, ModelSpace.world());
    float minX, minY, maxX, maxY;
    projectedBounds(baseline, aim, minX, minY, maxX, maxY);
    FalloffPacket lasso;
    lasso.enabled = true;
    lasso.type = FalloffType.Lasso;
    lasso.shape = FalloffShape.Linear;
    lasso.transparent = true;
    const pad = 8.0f;
    lasso.lassoPolyX = [minX - pad, maxX + pad, maxX + pad, minX - pad];
    lasso.lassoPolyY = [minY - pad, minY - pad, maxY + pad, maxY + pad];
    lasso.softBorderPx = 24.0f;
    vts.put(&lasso);
    foreach (i, p; baseline)
        assert(evaluateFalloff(lasso, p, cast(int)i, aim) > 0.99f,
            "Lasso control must include this open stand in the real viewport");

    VertexPositionResult expected, liveSharpCandidate, actual;
    assert(cmd.buildVertexPositionResultWithNormalSourcesForTest(
        baseline, baseline, baseline, vts, expected));
    assert(cmd.buildVertexPositionResultWithNormalSourcesForTest(
        baseline, baseline, live, vts, liveSharpCandidate));
    const candidateDelta = maxPositionDiff(
        fullResult(baseline, expected), fullResult(baseline, liveSharpCandidate));
    assert(candidateDelta > 0.01f, format(
        "lockSharp baseline/live result candidates must differ first; max position %.9g",
        candidateDelta));
    assert(cmd.buildVertexPositionResult(baseline, vts, actual));
    assert(fullResult(baseline, actual) == fullResult(baseline, expected), format(
        "Smooth lockSharp read live dihedral classification; baseline=%.9g° " ~
        "live=%.9g° threshold=%.9g° candidate delta=%.9g",
        baselineAngle, liveAngle, threshold, candidateDelta));
    assert(subject.vertices == live,
        "pure lockSharp result construction changed the occupied live preview");
}

unittest { // bound subject identity and script no-op success
    Mesh bound = openAsymmetricStand();
    Mesh decoy = openAsymmetricStand();
    View view = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&bound, view, EditMode.Vertices);
    setInt(cmd, "iter", 0);
    SubjectPacket subj;
    VectorStack vts;
    putSubject(vts, subj, &bound, view);
    VertexPositionResult empty;
    assert(cmd.buildVertexPositionResult(bound.vertices, vts, empty) && empty.empty,
        "zero-iteration Smooth builder must be successful and empty");
    assert(cmd.evaluate(vts),
        "zero-iteration scripted Smooth command must remain successful");

    SubjectPacket wrong;
    VectorStack wrongVts;
    putSubject(wrongVts, wrong, &decoy, view);
    assert(!cmd.buildVertexPositionResult(bound.vertices, wrongVts, empty),
        "a same-sized new primary must not replace Smooth's bound subject");
}

unittest { // occupied-preview refire construction is observationally pure
    Mesh target = makeCube();
    target.buildLoops();
    const sessionBaseline = target.vertices.dup;
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory();
    auto tool = new XfrmSmoothTool(&target, view, EditMode.Vertices, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&target, view, EditMode.Vertices));

    auto savedResolver = activeMeshResolver;
    Mesh offscreen = makeCube();
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
        if (p.name == "strn") *p.fptr = 0.35f;
        if (p.name == "iter") *p.iptr = 3;
    }
    tool.onParamChanged("strn");
    tool.evaluate();
    const occupiedPreview = target.vertices.dup;
    assert(occupiedPreview != sessionBaseline,
        "control: Smooth refire purity needs a non-empty occupied preview");

    // Refire a DIFFERENT parameter value without an ordinary preview tick.
    // A legacy apply/diff/restore path publishes that new image inside the
    // callback even if it later restores an identical final image.
    foreach (ref p; tool.params())
        if (p.name == "strn") *p.fptr = 0.82f;

    size_t targetCallbacks;
    bool callbackSawDifferentPositions;
    // Explicit test-only exception to the production subscriber contract:
    // observing positions synchronously is the tripwire for hidden temporary
    // writes and never mutates or re-enters the bus.
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
        "Smooth refire must build a populated deterministic carrier");
    assert(targetCallbacks == 0, format(
        "Smooth refire construction published %d Position callback(s); " ~
        "callback observed different positions=%s",
        targetCallbacks, callbackSawDifferentPositions));
    assert(!callbackSawDifferentPositions,
        "Smooth refire callback observed temporary live positions");
    assert(target.vertices == occupiedPreview,
        "Smooth refire construction changed the occupied preview");
    assert(changeBus.deliveryCount == deliveriesBefore &&
           changeBus.totalPosition == positionsBefore,
        "Smooth refire construction changed bus delivery counters");
    assert(target.mutationVersion == mutationBefore &&
           target.topologyVersion == topologyBefore &&
           target.structVersion == structureBefore &&
           target.marksVersion == marksBefore,
        "Smooth refire construction changed mesh counters");
    assert(records == recordsBefore && !history.canUndo(),
        "Smooth refire construction changed history");
}
