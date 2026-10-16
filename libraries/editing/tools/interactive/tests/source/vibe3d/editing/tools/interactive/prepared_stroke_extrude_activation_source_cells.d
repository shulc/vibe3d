module vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool : StrokeExtrudeTool,
    PreparedStrokeExtrudeActivationImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.mesh.core.mesh : Mesh, makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import vibe3d.util.math.math : Vec3;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    oldMesh.vertices[0] = Vec3(4,5,6);
    auto tool = new StrokeExtrudeTool(() => &mesh, &gpu, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length;
    const first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.StrokeExtrude &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr) &&
        context.installTraceForTest() == [20,8]);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0] = Vec3(70,80,90);
    assert(!changed.validate()); changed.discard();

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new StrokeExtrudeTool(() => selected, &gpu, LitShader.init);
    switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement;
    assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedStrokeExtrudeActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedStrokeExtrudeActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest(true);
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());

    mesh.vertices[0] = first;
    auto once = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedStrokeExtrudeActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedStroke : StrokeExtrudeTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target) {
            super(source, target, LitShader.init);
        }
    }
    auto derived = new DerivedStroke(() => &mesh, &gpu);
    auto refusedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refused = derived.prepareActivate(refusedContext);
    assert(!refused.accepted && refused.kind == PreparedActivateKind.StrokeExtrude &&
        refused.owner == derived.preparedOwnerForTest() &&
        !refusedContext.validate());
    auto nullEffect = tool.prepareActivate(null);
    assert(!nullEffect.accepted && nullEffect.kind == PreparedActivateKind.StrokeExtrude &&
        nullEffect.owner == tool.preparedOwnerForTest());
}
