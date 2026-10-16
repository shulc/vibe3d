module prepared_edge_bevel_activation_source_cells;

import prepared_edge_bevel_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import tools.edit.edge_bevel : EdgeBevelTool, PreparedEdgeBevelActivationImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import vibe3d.mesh.core.mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Edges; oldMesh.vertices[0] = Vec3(4,5,6);
    const expectedHash = mesh.selectionSignature(EditMode.Edges);
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeBevel &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr, true,
        Vec3(0,0,0), Vec3(0,0,0), Vec3(0,0,1), expectedHash) &&
        context.installTraceForTest() == [25,8]);

    Mesh empty;
    auto emptyTool = new EdgeBevelTool(() => &empty, &gpu, &mode,
        LitShader.init);
    emptyTool.seedPreparedActivationForTest(oldMesh);
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(emptyTool.preparedActivationForTest(0, Vec3.init, null, false,
        Vec3(1,2,3), Vec3(4,5,6), Vec3(7,8,9), 10));

    // One selected edge distinguishes the adjacent-face branch from the
    // empty-selection all-face fallback.
    Mesh selectedEdge = makeCube(); selectedEdge.syncSelection();
    selectedEdge.selectEdge(0);
    Vec3 normalSum = Vec3(0,0,0);
    const a = selectedEdge.edges[0][0], b = selectedEdge.edges[0][1];
    foreach (fi, face; selectedEdge.faces) {
        bool adjacent;
        foreach (k; 0 .. face.length) {
            const u = face[k], w = face[(k + 1) % face.length];
            if ((a == u && b == w) || (a == w && b == u)) {
                adjacent = true; break;
            }
        }
        if (adjacent) normalSum = normalSum +
            selectedEdge.faceNormal(cast(uint)fi);
    }
    import std.math : sqrt;
    const normalLen = sqrt(normalSum.x*normalSum.x +
        normalSum.y*normalSum.y + normalSum.z*normalSum.z);
    const selectedAxis = normalLen > 1e-6f ?
        normalSum * (1.0f/normalLen) : Vec3(0,1,0);
    auto selectedFrame = emptyTool.preparedFrameForTest(selectedEdge);
    assert(selectedFrame.gizmoValid);
    assert(selectedFrame.anchor == selectedEdge.selectionCentroidEdges());
    assert(selectedFrame.baseAnchor == selectedFrame.anchor);
    assert((selectedFrame.widthAxis - selectedAxis).length < 1e-6f);
    assert(selectedFrame.gizmoSelHash ==
        selectedEdge.selectionSignature(EditMode.Edges));

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted); mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new EdgeBevelTool(() => selected, &gpu, &mode,
        LitShader.init); switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedEdgeBevelActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedEdgeBevelActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedEdgeBevelActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedEdgeBevel : EdgeBevelTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedEdgeBevel(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
