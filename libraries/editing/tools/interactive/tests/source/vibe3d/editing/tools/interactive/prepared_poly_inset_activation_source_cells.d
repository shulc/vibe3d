module vibe3d.editing.tools.interactive.prepared_poly_inset_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_poly_inset_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh, makeCube;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool : PolyInsetTool,
    PreparedPolyInsetActivationImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.util.math.math : Vec3;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;

    Mesh mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Polygons; oldMesh.vertices[0] = Vec3(4,5,6);
    auto tool = new PolyInsetTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    const count = mesh.vertices.length, first = mesh.vertices[0];
    const livePtr = mesh.vertices.ptr;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.PolyInset &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(count, first, livePtr) &&
        context.installTraceForTest() == [22,8]);

    tool.seedPreparedActivationForTest(oldMesh);
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard(); mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new PolyInsetTool(() => selected, &gpu, &mode, LitShader.init);
    switching.seedPreparedActivationForTest(oldMesh);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedPolyInsetActivationOwner.abortCountForTest();
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedPolyInsetActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());

    auto wrong = PreparedPolyInsetActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedPolyInsetActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    auto aborted = PreparedPolyInsetActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());

    class DerivedInset : PolyInsetTool {
        this(Mesh* delegate() nothrow @nogc source, GpuMesh* target,
                EditMode* em) { super(source, target, em, LitShader.init); }
    }
    auto derived = new DerivedInset(() => &mesh, &gpu, &mode);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!derived.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted);
}
