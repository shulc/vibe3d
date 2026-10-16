module prepared_vertex_bevel_activation_source_cells;

import prepared_vertex_bevel_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.vertex_bevel_tool : VertexBevelTool,
    PreparedVertexBevelActivationImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import std.math : sqrt;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Vertices; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectVertex(0);
    auto tool = new VertexBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    const invRoot3 = 1.0f / sqrt(3.0f);
    const expectedAxis = Vec3(-invRoot3, -invRoot3, -invRoot3);
    const expectedAnchor = mesh.selectionCentroidVertices();
    const expectedHash = mesh.selectionSignature(EditMode.Vertices);
    assert(effect.accepted && effect.kind == PreparedActivateKind.VertexBevel &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        expectedAnchor, expectedAnchor, expectedAxis, expectedHash) &&
        context.installTraceForTest() == [27,8]);

    Mesh empty;
    auto emptyTool = new VertexBevelTool(() => &empty, &gpu, &mode,
        LitShader.init); emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), 10));
    Mesh allVertices = makeCube();
    auto allFrame = emptyTool.preparedFrameForTest(allVertices);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0) &&
        allFrame.insetAxis == Vec3(0,1,0));
    Mesh hiddenSelected = makeCube(); hiddenSelected.syncSelection();
    hiddenSelected.vertexMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hiddenSelected);
    assert(hiddenFrame.gizmoValid &&
        hiddenFrame.anchor == hiddenSelected.vertices[0] &&
        hiddenFrame.insetAxis == expectedAxis);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new VertexBevelTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedVertexBevelActivationOwner.abortCountForTest();
    bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() &&
        tool.preparedActivationDirtyForTest() &&
        PreparedVertexBevelActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedVertexBevelActivationOwner.prepare(tool);
    assert(wrong.begin());
    wrong.corruptPreparedForTest(); assert(!wrong.validate()); wrong.abort();
    assert(wrong.payloadEmpty());
    auto once = PreparedVertexBevelActivationOwner.prepare(tool);
    assert(once.begin() && once.validate());
    once.install(); assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedVertexBevelActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());
    class Derived : VertexBevelTool {
        this(Mesh* delegate() nothrow @nogc s, GpuMesh* g, EditMode* m) {
            super(s, g, m, LitShader.init);
        }
    }
    auto derived = new Derived(() => &mesh, &gpu, &mode);
    assert(!derived.prepareActivate(new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub())).accepted);
    auto missing = new VertexBevelTool(() => null, &gpu, &mode,
        LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted &&
        !missingContext.validate());
    assert(!tool.prepareActivate(null).accepted);
}
