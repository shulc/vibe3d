module prepared_transform_product_activation_source_cells;

import prepared_transform_product_activation;
import core.atomic : atomicOp;
import tools.transform.transform : TransformTool;
import tools.transform.move : MoveTool, PreparedMoveActivationImage;
import tools.transform.rotate : RotateTool, PreparedRotateActivationImage;
import tools.transform.scale : ScaleTool, PreparedScaleActivationImage;

unittest {
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    import tools.transform.xfrm_transform : XfrmTransformTool;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedTransformProductKind;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto move = new MoveTool(() => &mesh, &gpu, &mode);
    auto rotate = new RotateTool(() => &mesh, &gpu, &mode);
    auto scale = new ScaleTool(() => &mesh, &gpu, &mode);
    move.seedPreparedProductActivationForTest();
    auto moveOwner = PreparedTransformProductActivationOwner.prepare(move);
    auto moveContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(moveOwner !is null &&
        moveContext.prepareTransformProductActivation(moveOwner) &&
        moveContext.markNoHistoryInstall() && moveContext.validate());
    moveContext.install(); moveContext.install();
    assert(move.preparedProductActivationForTest() && moveOwner.payloadEmpty() &&
        moveContext.installTraceForTest() == [15,8] && !moveOwner.begin());

    rotate.seedPreparedProductActivationForTest();
    auto rotateOwner = PreparedTransformProductActivationOwner.prepare(rotate);
    auto rotateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(rotateContext.prepareTransformProductActivation(rotateOwner) &&
        rotateContext.markNoHistoryInstall() && rotateContext.validate());
    rotateContext.install();
    rotateContext.install();
    assert(rotate.preparedProductActivationForTest() &&
        rotateOwner.payloadEmpty() &&
        rotateContext.installTraceForTest() == [15,8]);

    scale.seedPreparedProductActivationForTest();
    auto aborted = PreparedTransformProductActivationOwner.prepare(scale);
    assert(aborted !is null && aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin());
    auto faultOwner = PreparedTransformProductActivationOwner.prepare(scale);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try fault.prepareTransformProductActivation(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw); fault.discard();
    auto fresh = PreparedTransformProductActivationOwner.prepare(scale);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(retry.prepareTransformProductActivation(fresh) &&
        retry.markNoHistoryInstall() && retry.validate());
    scale.mutatePreparedHandlerForTest(Vec3(20,30,40));
    mesh.vertices[0].x += 5;
    retry.install(); retry.install();
    assert(scale.preparedProductActivationForTest() && fresh.payloadEmpty() &&
        retry.installTraceForTest() == [15,8]);

    class DerivedMove : MoveTool {
        this(Mesh* delegate() source, GpuMesh* gpu, EditMode* mode) {
            super(source, gpu, mode);
        }
        override void activate() { super.activate(); }
    }
    assert(PreparedTransformProductActivationOwner.prepare(
        new DerivedMove(() => &mesh, &gpu, &mode)) is null);
    class DerivedRotate : RotateTool {
        this(Mesh* delegate() source, GpuMesh* gpu, EditMode* mode) { super(source,gpu,mode); }
        override void activate() { super.activate(); }
    }
    class DerivedScale : ScaleTool {
        this(Mesh* delegate() source, GpuMesh* gpu, EditMode* mode) { super(source,gpu,mode); }
        override void activate() { super.activate(); }
    }
    assert(PreparedTransformProductActivationOwner.prepare(
        new DerivedRotate(() => &mesh, &gpu, &mode)) is null);
    assert(PreparedTransformProductActivationOwner.prepare(
        new DerivedScale(() => &mesh, &gpu, &mode)) is null);
    assert(PreparedTransformProductActivationOwner.prepare(
        new XfrmTransformTool(() => &mesh, &gpu, &mode)) is null);

    move.seedPreparedProductActivationForTest();
    auto moveProducerContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto moveEffect = move.prepareActivate(moveProducerContext);
    assert(moveEffect.accepted && moveEffect.kind == PreparedTransformProductKind.Move &&
        moveEffect.owner == move.preparedOwnerForTest &&
        move.preparedProductActivationSeedForTest());
    assert(moveProducerContext.validate());
    moveProducerContext.install(); moveProducerContext.install();
    assert(move.preparedProductActivationForTest() &&
        moveProducerContext.installTraceForTest() == [15,8]);

    rotate.seedPreparedProductActivationForTest();
    auto rotateProducerContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto rotateEffect = rotate.prepareActivate(rotateProducerContext);
    assert(rotateEffect.accepted &&
        rotateEffect.kind == PreparedTransformProductKind.Rotate &&
        rotateEffect.owner == rotate.preparedOwnerForTest &&
        rotate.preparedProductActivationSeedForTest());
    assert(rotateProducerContext.validate());
    rotateProducerContext.install();
    assert(rotate.preparedProductActivationForTest() &&
        rotateProducerContext.installTraceForTest() == [15,8]);

    scale.seedPreparedProductActivationForTest();
    auto scaleProducerContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto scaleEffect = scale.prepareActivate(scaleProducerContext);
    assert(scaleEffect.accepted &&
        scaleEffect.kind == PreparedTransformProductKind.Scale &&
        scaleEffect.owner == scale.preparedOwnerForTest &&
        scale.preparedProductActivationSeedForTest());
    assert(scaleProducerContext.validate());
    scaleProducerContext.install(); scaleProducerContext.install();
    assert(scale.preparedProductActivationForTest() &&
        scaleProducerContext.installTraceForTest() == [15,8]);

    auto derived = new DerivedRotate(() => &mesh, &gpu, &mode);
    auto refusedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refused = derived.prepareActivate(refusedContext);
    assert(!refused.accepted && refused.kind == PreparedTransformProductKind.Rotate &&
        refused.owner == derived.preparedOwnerForTest && !refusedContext.validate());
    auto nullMove = move.prepareActivate(null);
    assert(!nullMove.accepted && nullMove.kind == PreparedTransformProductKind.Move &&
        nullMove.owner == move.preparedOwnerForTest);

    rotate.seedPreparedProductActivationForTest();
    auto abortsBefore = PreparedTransformProductActivationOwner.abortCountForTest();
    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try rotate.prepareActivate(producerFault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !producerFault.validate() &&
        rotate.preparedProductActivationSeedForTest() &&
        PreparedTransformProductActivationOwner.abortCountForTest() == abortsBefore + 1);
    auto producerRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(rotate.prepareActivate(producerRetry).accepted &&
        rotate.preparedProductActivationSeedForTest() && producerRetry.validate());
    producerRetry.discard();
    assert(rotate.preparedProductActivationSeedForTest() &&
        PreparedTransformProductActivationOwner.abortCountForTest() == abortsBefore + 2);
}
