module prepared_bridge_activation_source_cells;

import prepared_bridge_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.bridge_tool : BridgeTool, PreparedBridgeActivationImage,
    PreparedBridgeDeactivateImage;

unittest {
    import command_history : CommandHistory;
    import commands.mesh.session_edit : MeshSessionEdit;
    import document : Layer;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import mesh_gpu : GpuMesh;
    import mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner, GpuUploadOwner,
        GpuResourceOwner;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind, PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import snapshot : MeshSnapshot;
    import view : View;

    Mesh twoCaps() {
        Mesh m;
        foreach (v; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
                     Vec3(0,0,1), Vec3(1,0,1), Vec3(1,1,1), Vec3(0,1,1)])
            m.addVertex(v);
        m.addFace([0u,1u,2u,3u]); m.addFace([4u,5u,6u,7u]); m.buildLoops();
        m.faceMarks.length = m.faces.length;
        m.faceSelectionOrder.length = m.faces.length;
        m.selectFace(0); m.selectFace(1); return m;
    }
    auto mesh = twoCaps(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto dirtyGpu = GpuCreateOwner.fakeForTest(&gpu);
    assert(dirtyGpu.beginEnlistedCreate() && dirtyGpu.validateEnlisted(7,11));
    dirtyGpu.installEnlisted();
    auto tool = new BridgeTool(() => &mesh, &gpu, LitShader.init, &mode);
    tool.seedPreparedActivationForTest();
    auto create = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto upload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7,11);
    auto effect = tool.prepareActivate(context, create, upload);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Bridge);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest(true) &&
        context.installTraceForTest() == [35,12,8]);

    Mesh invalid = twoCaps(); invalid.faceMarks[] = 0;
    auto invalidTool = new BridgeTool(() => &invalid, &gpu, LitShader.init, &mode);
    auto invalidCreate = GpuCreateOwner.fakeForLegacyInitTest(
        invalidTool.preparedPreviewGpu());
    auto invalidUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        invalidTool.preparedPreviewGpu());
    auto invalidContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); invalidContext.setResourceIdentity(7,11);
    assert(invalidTool.prepareActivate(invalidContext, invalidCreate,
        invalidUpload).accepted && invalidContext.validate());
    invalidContext.install();
    assert(invalidTool.preparedActivationInstalledForTest(false) &&
        invalidContext.installTraceForTest() == [35,5,8]);

    auto changedCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto changedUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); changed.setResourceIdentity(7,11);
    assert(tool.prepareActivate(changed, changedCreate, changedUpload).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    Mesh replacement = twoCaps(); Mesh* selected = &mesh;
    auto switching = new BridgeTool(() => selected, &gpu, LitShader.init, &mode);
    auto switchingCreate = GpuCreateOwner.fakeForLegacyInitTest(
        switching.preparedPreviewGpu());
    auto switchingUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        switching.preparedPreviewGpu());
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); switched.setResourceIdentity(7,11);
    assert(switching.prepareActivate(switched, switchingCreate,
        switchingUpload).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto modeCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto modeUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto modeChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); modeChanged.setResourceIdentity(7,11);
    assert(tool.prepareActivate(modeChanged, modeCreate, modeUpload).accepted);
    mode = EditMode.Edges; assert(!modeChanged.validate()); modeChanged.discard();
    mode = EditMode.Polygons;

    auto faultCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto faultUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    faultUpload.failAfterBuildForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); fault.setResourceIdentity(7,11); bool threw;
    try tool.prepareActivate(fault, faultCreate, faultUpload);
    catch (Exception) threw = true;
    assert(threw && !fault.validate() &&
        faultUpload.fakeCreatedForTest() == faultUpload.fakeDeletedForTest());
    auto retryCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto retryUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); retry.setResourceIdentity(7,11);
    assert(tool.prepareActivate(retry, retryCreate, retryUpload).accepted &&
        retry.validate()); retry.discard();

    auto corrupt = PreparedBridgeActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedBridgeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    assert(!tool.prepareActivate(null, create, upload).accepted &&
        PreparedBridgeActivationOwner.prepare(null) is null);

    auto deactLayer = new Layer;
    auto deactSource = twoCaps();
    MeshSnapshot.capture(deactSource).restore(deactLayer.meshRef());
    GpuMesh deactGpu; EditMode deactMode = EditMode.Polygons;
    auto deactTool = new BridgeTool(() => &deactLayer.meshRef(), &deactGpu,
        LitShader.init, &deactMode);
    assert(deactTool.seedPreparedDeactivateCommitForTest());
    auto deactHistory = new CommandHistory(); auto deactView = new View(0,0,1,1);
    deactTool.setGestureBindings(deactHistory, () => new MeshSessionEdit(
        &deactLayer.meshRef(), deactView, deactMode,
        "test.bridge", "Bridge"));
    auto deactContext = new PreparedRecordContext(deactHistory,
        new RecordObserverHub()); deactContext.setResourceIdentity(7,11);
    auto deactEffect = deactTool.prepareDeactivate(deactContext, deactLayer,
        GpuUploadOwner.fakeForTest(&deactGpu),
        GpuResourceOwner.fakeForTest(deactTool.preparedPreviewGpu()));
    assert(deactEffect.resourceAccepted && deactEffect.historyAccepted &&
        deactEffect.kind == PreparedDeactivateKind.Bridge &&
        deactLayer.meshRef().faces.length == 2 && deactContext.validate());
    deactContext.install(); size_t modelDepth, uiDepth;
    deactHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(deactLayer.meshRef().faces.length > 2 && modelDepth == 1 &&
        uiDepth == 0 && deactTool.preparedDeactivateStateInstalledForTest() &&
        deactContext.installTraceForTest() == [3,4,2,2,1,41]);

    auto idleLayer = new Layer;
    MeshSnapshot.capture(deactSource).restore(idleLayer.meshRef());
    GpuMesh idleGpu; EditMode idleMode = EditMode.Polygons;
    auto idleTool = new BridgeTool(() => &idleLayer.meshRef(), &idleGpu,
        LitShader.init, &idleMode);
    auto idleContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); idleContext.setResourceIdentity(7,11);
    auto idleEffect = idleTool.prepareDeactivate(idleContext, idleLayer,
        GpuUploadOwner.fakeForTest(&idleGpu),
        GpuResourceOwner.fakeForTest(idleTool.preparedPreviewGpu()));
    assert(idleEffect.resourceAccepted && !idleEffect.historyAccepted &&
        idleContext.validate()); idleContext.install();
    assert(idleLayer.meshRef().faces.length == 2 &&
        idleContext.installTraceForTest() == [2,8,41]);

    auto mutationLayer = new Layer;
    MeshSnapshot.capture(deactSource).restore(mutationLayer.meshRef());
    GpuMesh mutationGpu; EditMode mutationMode = EditMode.Polygons;
    auto mutationTool = new BridgeTool(() => &mutationLayer.meshRef(),
        &mutationGpu, LitShader.init, &mutationMode);
    assert(mutationTool.seedPreparedDeactivateCommitForTest());
    auto mutationContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); mutationContext.setResourceIdentity(7,11);
    auto mutationEffect = mutationTool.prepareDeactivate(mutationContext,
        mutationLayer, GpuUploadOwner.fakeForTest(&mutationGpu),
        GpuResourceOwner.fakeForTest(mutationTool.preparedPreviewGpu()));
    assert(mutationEffect.resourceAccepted);
    mutationTool.mutatePreparedDeactivateForTest();
    assert(!mutationContext.validate()); mutationContext.discard();
    assert(mutationLayer.meshRef().faces.length == 2);

    auto corruptDeactivate = PreparedBridgeDeactivateOwner.prepare(idleTool);
    assert(corruptDeactivate.begin()); corruptDeactivate.corruptPreparedForTest();
    assert(!corruptDeactivate.validate()); corruptDeactivate.abort();
    assert(corruptDeactivate.payloadEmpty() &&
        PreparedBridgeDeactivateOwner.prepare(null) is null);
}
