module vibe3d.editing.tools.interactive.prepared_private_state_source_cells;

import vibe3d.editing.tools.interactive.prepared_private_state;
import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.create.box : BoxTool, PreparedBoxDeactivateImage;
import vibe3d.editing.tools.interactive.tools.create.pen : PenTool, PreparedPenDeactivateImage,
    PreparedPenParamImage;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedPenParamKind;
import vibe3d.editing.tools.interactive.tools.create.primitive_create_tool : PrimitiveCreateTool, HandledCreateTool,
    PreparedPrimitiveDeactivateImage;
import vibe3d.editing.tools.interactive.tools.create.sphere : SphereTool;
import vibe3d.editing.tools.interactive.tools.create.capsule : CapsuleTool;
import vibe3d.editing.tools.interactive.tools.create.cone : ConeTool;
import vibe3d.editing.tools.interactive.tools.create.cylinder : CylinderTool;
import vibe3d.editing.tools.interactive.tools.create.torus : TorusTool;
import vibe3d.editing.tools.interactive.tools.create.tube : TubeTool;
import vibe3d.editing.tools.interactive.tools.create.arc : ArcTool;
import vibe3d.editing.tools.interactive.tools.alignment.array_tool : ArrayTool;
import vibe3d.editing.tools.interactive.tools.alignment.clone_tool : CloneTool;
import vibe3d.editing.tools.interactive.tools.deform.magnet : MagnetTool;
import vibe3d.editing.tools.interactive.tools.edit.reduce : ReductionTool;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.mesh.core.mesh : Mesh;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
    import vibe3d.documents.model.document : Layer;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.viewport.gpu.mesh_gpu : GpuUploadOwner, GpuResourceOwner;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import vibe3d.editing.tools.interactive.snap_render : SnapOverlayOwner;
    import vibe3d.viewport.camera.view : View;

    auto layer = new Layer; GpuMesh gpu;
    auto sphere = new SphereTool(() => &layer.meshRef(), &gpu, LitShader.init);
    sphere.seedPreparedDeactivateForTest();
    Mesh probeCandidate; uint probeFlags, probeDomains;
    auto probeOwner = PreparedPrivateStateOwner.primitiveDeactivate(sphere,
        probeCandidate, probeFlags, probeDomains);
    assert(probeOwner !is null && probeOwner.begin());
    assert(probeOwner.validate(), "primitive private state validation refused");
    probeOwner.abort();
    auto history = new CommandHistory(); auto view = new View(0,0,1,1);
    sphere.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, EditMode.Vertices, "test.sphere", "Create Sphere"));
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7,11);
    auto effect = sphere.prepareDeactivate(context, layer,
        GpuUploadOwner.fakeForTest(&gpu),
        GpuResourceOwner.fakeForTest(sphere.preparedPreviewGpu()),
        new SnapOverlayOwner());
    assert(effect.resourceAccepted, "primitive resources refused");
    assert(effect.historyAccepted, "primitive history refused");
    assert(effect.kind == PreparedDeactivateKind.Primitive);
    assert(layer.meshRef().faces.length == 0);
    assert(context.validate(), "primitive validation refused");
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(layer.meshRef().faces.length > 0 && modelDepth == 1 &&
        sphere.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [3,4,2,7,2,1,6]);

    auto changedLayer = new Layer; GpuMesh changedGpu;
    auto changed = new SphereTool(() => &changedLayer.meshRef(), &changedGpu,
        LitShader.init); changed.seedPreparedDeactivateForTest();
    auto changedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); changedContext.setResourceIdentity(7,11);
    auto changedEffect = changed.prepareDeactivate(changedContext, changedLayer,
        GpuUploadOwner.fakeForTest(&changedGpu),
        GpuResourceOwner.fakeForTest(changed.preparedPreviewGpu()),
        new SnapOverlayOwner());
    assert(changedEffect.resourceAccepted);
    changed.mutatePreparedDeactivateForTest();
    assert(!changedContext.validate()); changedContext.discard();

    auto torusLayer = new Layer; GpuMesh torusGpu;
    auto torus = new TorusTool(() => &torusLayer.meshRef(), &torusGpu,
        LitShader.init); torus.seedPreparedEmptyDeactivateForTest();
    auto torusHistory = new CommandHistory();
    torus.setGestureBindings(torusHistory, () => new MeshSessionEdit(
        &torusLayer.meshRef(), view, EditMode.Vertices,
        "test.torus", "Create Torus"));
    auto torusContext = new PreparedRecordContext(torusHistory,
        new RecordObserverHub()); torusContext.setResourceIdentity(7,11);
    auto torusEffect = torus.prepareDeactivate(torusContext, torusLayer, null,
        GpuResourceOwner.fakeForTest(torus.preparedPreviewGpu()),
        new SnapOverlayOwner());
    assert(torusEffect.resourceAccepted && torusEffect.historyAccepted &&
        torusEffect.kind == PreparedDeactivateKind.Primitive &&
        torusContext.validate());
    torusContext.install();
    torusHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(torusLayer.meshRef().faces.length == 0 && modelDepth == 1 &&
        torus.preparedEmptyDeactivateInstalledForTest() &&
        torusContext.installTraceForTest() == [7,2,1,6]);
}
