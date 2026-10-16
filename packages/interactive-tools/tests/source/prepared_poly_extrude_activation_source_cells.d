module prepared_poly_extrude_activation_source_cells;

import prepared_poly_extrude_activation;
import core.atomic : atomicOp;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import tools.edit.poly_extrude : PolyExtrudeTool,
    PreparedPolyExtrudeActivationImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Polygons; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectFace(0);
    const expectedAnchor = mesh.faceCentroid(0);
    const expectedAxis = mesh.faceNormal(0);
    const expectedHash = mesh.selectionSignature(EditMode.Polygons);
    auto tool = new PolyExtrudeTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.PolyExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr,
            expectedAnchor, expectedAxis, expectedHash) &&
        context.installTraceForTest() == [23,8]);

    // Legacy computeGizmoFrame updates validity/signature on refusal, but
    // deliberately preserves the last usable frame vectors.
    Mesh empty;
    auto emptyTool = new PolyExtrudeTool(() => &empty, &gpu, &mode,
        LitShader.init);
    emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate());
    const emptyHash = empty.selectionSignature(EditMode.Polygons);
    emptyContext.install();
    assert(emptyTool.preparedInvalidActivationForTest(emptyHash));

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new PolyExtrudeTool(() => selected, &gpu, &mode, LitShader.init);
    switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedPolyExtrudeActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedPolyExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedPolyExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedPolyExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedPolyExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedExtrude : PolyExtrudeTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedExtrude(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
