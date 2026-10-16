module prepared_smooth_shift_activation_source_cells;

import prepared_smooth_shift_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.deform.smooth_shift_tool : SmoothShiftTool,
    PreparedSmoothShiftActivationImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3, cross;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Polygons; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectFace(0);
    const expectedAnchor = mesh.faceCentroid(0);
    const expectedOffset = mesh.faceNormal(0);
    const up = (expectedOffset.y < 0.9f && expectedOffset.y > -0.9f) ?
        Vec3(0,1,0) : Vec3(1,0,0);
    import std.math : sqrt;
    const side = cross(expectedOffset, up);
    const sideLen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
    const expectedScale = sideLen > 1e-6f ? side * (1.0f/sideLen) : Vec3(1,0,0);
    const expectedHash = mesh.selectionSignature(EditMode.Polygons);
    auto tool = new SmoothShiftTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.SmoothShift &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        expectedAnchor, expectedAnchor, expectedOffset, expectedScale,
        expectedHash) && context.installTraceForTest() == [24,8]);

    Mesh empty;
    auto emptyTool = new SmoothShiftTool(() => &empty, &gpu, &mode,
        LitShader.init);
    emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), Vec3(10,11,12), 13));

    // No selection means every face, including hidden faces: the symmetric
    // cube cancels its normals and takes the exact +Y / -Z fallbacks.
    Mesh allFaces = makeCube();
    auto allFrame = emptyTool.preparedFrameForTest(allFaces);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0) &&
        allFrame.baseAnchor == Vec3(0,0,0) &&
        allFrame.offsetAxis == Vec3(0,1,0) &&
        allFrame.scaleAxis == Vec3(0,0,-1));

    // Legacy selection framing does not subtract Hide. Use a deliberately
    // stale word to distinguish that law from operandFaceMask().
    Mesh hiddenSelected = makeCube(); hiddenSelected.syncSelection();
    hiddenSelected.faceMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hiddenSelected);
    assert(hiddenFrame.gizmoValid &&
        hiddenFrame.anchor == hiddenSelected.faceCentroid(0) &&
        hiddenFrame.offsetAxis == hiddenSelected.faceNormal(0));

    // Stale selection outside the face plane makes hasAnySelectedFaces true,
    // while every real face is skipped: anchor is cleared before cnt==0,
    // the remaining frame and signature stay untouched.
    Mesh stale = makeCube(); stale.syncSelection();
    stale.faceMarks ~= Mesh.Marks.Select;
    auto staleFrame = emptyTool.preparedFrameForTest(stale);
    assert(!staleFrame.gizmoValid && staleFrame.anchor == Vec3(0,0,0) &&
        staleFrame.baseAnchor == Vec3(4,5,6) &&
        staleFrame.offsetAxis == Vec3(7,8,9) &&
        staleFrame.scaleAxis == Vec3(10,11,12) && staleFrame.gizmoSelHash == 13);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted); mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new SmoothShiftTool(() => selected, &gpu, &mode,
        LitShader.init);
    switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedSmoothShiftActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedSmoothShiftActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedSmoothShiftActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedSmoothShiftActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedSmoothShiftActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedSmoothShift : SmoothShiftTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedSmoothShift(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
