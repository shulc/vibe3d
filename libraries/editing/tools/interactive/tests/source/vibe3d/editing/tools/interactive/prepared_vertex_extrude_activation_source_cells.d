module vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool : VertexExtrudeTool,
    PreparedVertexExtrudeActivationImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.util.math.math : Vec3, cross;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import std.math : sqrt;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Vertices; oldMesh.vertices[0] = Vec3(4,5,6);
    mesh.syncSelection(); mesh.selectVertex(0);
    const invRoot3 = 1.0f / sqrt(3.0f);
    const expectedShift = Vec3(-invRoot3, -invRoot3, -invRoot3);
    const up = Vec3(0,1,0), side = cross(expectedShift, up);
    const sideLen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
    const expectedWidth = side * (1.0f/sideLen);
    auto tool = new VertexExtrudeTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    const expectedAnchor = mesh.selectionCentroidVertices();
    const expectedHash = mesh.selectionSignature(EditMode.Vertices);
    assert(effect.accepted && effect.kind == PreparedActivateKind.VertexExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        expectedAnchor, expectedAnchor, expectedShift, expectedWidth,
        expectedHash) && context.installTraceForTest() == [28,8]);

    Mesh empty;
    auto emptyTool = new VertexExtrudeTool(() => &empty, &gpu, &mode,
        LitShader.init); emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), Vec3(10,11,12), 13));
    Mesh allVertices = makeCube(); auto allFrame = emptyTool.preparedFrameForTest(allVertices);
    assert(allFrame.gizmoValid && allFrame.anchor == Vec3(0,0,0) &&
        allFrame.shiftAxis == Vec3(0,1,0) && allFrame.widthAxis == Vec3(0,0,-1));
    Mesh hidden = makeCube(); hidden.syncSelection();
    hidden.vertexMarks[0] = Mesh.Marks.Select | Mesh.Marks.Hide;
    auto hiddenFrame = emptyTool.preparedFrameForTest(hidden);
    assert(hiddenFrame.gizmoValid && hiddenFrame.anchor == hidden.vertices[0] &&
        hiddenFrame.shiftAxis == expectedShift && hiddenFrame.widthAxis == expectedWidth);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new VertexExtrudeTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedVertexExtrudeActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedVertexExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedVertexExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort(); assert(aborted.payloadEmpty() && !aborted.begin());

    class Derived : VertexExtrudeTool {
        this(Mesh* delegate() nothrow @nogc s, GpuMesh* g, EditMode* m) {
            super(s, g, m, LitShader.init);
        }
    }
    auto derived = new Derived(() => &mesh, &gpu, &mode);
    assert(!derived.prepareActivate(new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub())).accepted);
    auto missing = new VertexExtrudeTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted && !missingContext.validate());
    assert(!tool.prepareActivate(null).accepted);
}
