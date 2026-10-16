module prepared_tack_activation_source_cells;

import prepared_tack_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import tools.edit.tack : TackTool, PreparedTackActivationImage;

unittest {
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import mesh_gpu : GpuCreateOwner;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(); GpuMesh gpu;
    auto tool = new TackTool(() => &mesh, &gpu, LitShader.init);
    tool.seedPreparedActivationForTest(true);
    auto gpuOwner = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto context = new PreparedRecordContext(null, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareActivate(context, gpuOwner);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Tack &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(true) &&
        context.installTraceForTest() == [33,5,8] &&
        gpuOwner.fakeDeletedForTest().length == 0);

    auto empty = new TackTool(() => &mesh, &gpu, LitShader.init);
    empty.seedPreparedActivationForTest(false);
    auto emptyGpu = GpuCreateOwner.fakeForLegacyInitTest(empty.preparedPreviewGpu());
    auto emptyContext = new PreparedRecordContext(null, new RecordObserverHub());
    emptyContext.setResourceIdentity(7,11);
    assert(empty.prepareActivate(emptyContext, emptyGpu).accepted &&
        emptyContext.validate()); emptyContext.install();
    assert(empty.preparedActivationForTest(false));

    tool.seedPreparedActivationForTest(true);
    auto changedGpu = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto changed = new PreparedRecordContext(null, new RecordObserverHub());
    changed.setResourceIdentity(7,11);
    assert(tool.prepareActivate(changed, changedGpu).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new TackTool(() => selected, &gpu, LitShader.init);
    switching.seedPreparedActivationForTest(true);
    auto switchingGpu = GpuCreateOwner.fakeForLegacyInitTest(switching.preparedPreviewGpu());
    auto switched = new PreparedRecordContext(null, new RecordObserverHub());
    switched.setResourceIdentity(7,11);
    assert(switching.prepareActivate(switched, switchingGpu).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    Mesh alternatingA = makeCube(), alternatingB = makeCube();
    alternatingA.syncSelection(); alternatingA.selectFace(0);
    alternatingB.syncSelection(); alternatingB.selectFace(2);
    size_t providerCalls;
    auto alternating = new TackTool(() {
        ++providerCalls;
        return providerCalls % 3 == 2 ? &alternatingB : &alternatingA;
    }, &gpu, LitShader.init);
    auto alternatingGpu = GpuCreateOwner.fakeForLegacyInitTest(
        alternating.preparedPreviewGpu());
    auto alternatingContext = new PreparedRecordContext(null,
        new RecordObserverHub()); alternatingContext.setResourceIdentity(7,11);
    assert(alternating.prepareActivate(alternatingContext, alternatingGpu).accepted &&
        !alternatingContext.validate());

    tool.seedPreparedActivationForTest(true);
    auto createFailureGpu = GpuCreateOwner.fakeForLegacyInitTest(
        tool.preparedPreviewGpu()); createFailureGpu.failNextCreateForTest();
    auto createFailure = new PreparedRecordContext(null, new RecordObserverHub());
    createFailure.setResourceIdentity(7,11);
    auto createFailureEffect = tool.prepareActivate(createFailure, createFailureGpu);
    assert(!createFailureEffect.accepted && !createFailure.validate() &&
        createFailureGpu.fakeCleanupCountForTest() == 1 &&
        createFailureGpu.fakeCreatedForTest() == createFailureGpu.fakeDeletedForTest() &&
        tool.preparedActivationDirtyForTest());

    auto jointGpu = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto joint = new PreparedRecordContext(null, new RecordObserverHub());
    joint.setResourceIdentity(8,11);
    assert(tool.prepareActivate(joint, jointGpu).accepted && !joint.validate() &&
        jointGpu.fakeCleanupCountForTest() == 1 &&
        jointGpu.fakeCreatedForTest() == jointGpu.fakeDeletedForTest() &&
        tool.preparedActivationDirtyForTest());

    tool.seedPreparedActivationForTest(true);
    auto faultGpu = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto fault = new PreparedRecordContext(null, new RecordObserverHub());
    fault.setResourceIdentity(7,11);
    auto aborts = PreparedTackActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault, faultGpu); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedTackActivationOwner.abortCountForTest() == aborts + 1);
    auto retryGpu = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto retry = new PreparedRecordContext(null, new RecordObserverHub());
    retry.setResourceIdentity(7,11);
    assert(tool.prepareActivate(retry, retryGpu).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedTackActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedTackActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest(true);
    auto aborted = PreparedTackActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest());
    GpuMesh foreign;
    auto foreignOwner = GpuCreateOwner.fakeForLegacyInitTest(&foreign);
    auto foreignContext = new PreparedRecordContext(null, new RecordObserverHub());
    foreignContext.setResourceIdentity(7,11);
    assert(!tool.prepareActivate(foreignContext, foreignOwner).accepted &&
        !foreignContext.validate());
    auto missing = new TackTool(() => null, &gpu, LitShader.init);
    auto missingGpu = GpuCreateOwner.fakeForLegacyInitTest(missing.preparedPreviewGpu());
    auto missingContext = new PreparedRecordContext(null, new RecordObserverHub());
    missingContext.setResourceIdentity(7,11);
    assert(!missing.prepareActivate(missingContext, missingGpu).accepted &&
        !missingContext.validate() && !tool.prepareActivate(null, gpuOwner).accepted);
}
