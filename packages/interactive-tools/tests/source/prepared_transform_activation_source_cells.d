module prepared_transform_activation_source_cells;

import prepared_transform_activation;
import core.atomic : atomicOp;
import tools.transform.transform : TransformTool, PreparedTransformActivationImage;
import tools.alignment.linear_align_tool : LinearAlignTool;
import tools.alignment.radial_align_tool : RadialAlignTool;
import tools.deform.bend : BendTool;
import tools.deform.push : PushTool;

unittest {
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import vibe3d.editing.contracts.editmode : EditMode;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedTransformActivationEffect,
        PreparedTransformActivationKind;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto linear = new LinearAlignTool(() => &mesh, &gpu, &mode);
    auto radial = new RadialAlignTool(() => &mesh, &gpu, &mode);
    auto bend = new BendTool(() => &mesh, &gpu, &mode);
    auto push = new PushTool(() => &mesh, &gpu, &mode);
    foreach (target; [cast(TransformTool) linear, radial, bend, push]) {
        target.seedPreparedActivationForTest();
        auto owner = PreparedTransformActivationOwner.prepare(target);
        assert(owner !is null && owner.owns(target) && owner.begin() &&
            owner.validate()); owner.install();
        assert(target.preparedActivationForTest() && owner.payloadEmpty());
        owner.install(); assert(!owner.begin());
    }
    class ForeignTransform : TransformTool {
        this(Mesh* delegate() source, GpuMesh* gpu, EditMode* mode) {
            super(source, gpu, mode);
        }
    }
    assert(PreparedTransformActivationOwner.prepare(
        new ForeignTransform(() => &mesh, &gpu, &mode)) is null);
    class BehaviorfulLinear : LinearAlignTool {
        bool behaviorRan;
        this(Mesh* delegate() source, GpuMesh* gpu, EditMode* mode) {
            super(source, gpu, mode);
        }
        override void activate() { behaviorRan = true; super.activate(); }
    }
    auto behaviorful = new BehaviorfulLinear(() => &mesh, &gpu, &mode);
    assert(PreparedTransformActivationOwner.prepare(behaviorful) is null);
    behaviorful.activate(); assert(behaviorful.behaviorRan);

    linear.seedPreparedActivationForTest();
    auto aborted = PreparedTransformActivationOwner.prepare(linear);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        !linear.preparedActivationForTest());
    auto contextOwner = PreparedTransformActivationOwner.prepare(linear);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(context.prepareTransformActivation(contextOwner) &&
        context.markNoHistoryInstall() && context.validate());
    context.install();
    assert(linear.preparedActivationForTest() &&
        context.installTraceForTest() == [14, 8]);

    linear.seedPreparedActivationForTest();
    auto faultOwner = PreparedTransformActivationOwner.prepare(linear);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try fault.prepareTransformActivation(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.payloadEmpty()); fault.discard();
    auto fresh = PreparedTransformActivationOwner.prepare(linear);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(retry.prepareTransformActivation(fresh)); retry.discard();
    assert(fresh.payloadEmpty() && !linear.preparedActivationForTest());

    linear.seedPreparedActivationForTest();
    auto linearContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto linearEffect = linear.prepareActivate(linearContext);
    assert(linearEffect.accepted &&
        linearEffect.kind == PreparedTransformActivationKind.LinearAlign &&
        linearEffect.owner == linear.preparedOwnerForTest &&
        linear.preparedActivationSeedForTest() && linearContext.validate());
    linearContext.install(); linearContext.install();
    assert(linear.preparedActivationForTest() &&
        linearContext.installTraceForTest() == [14, 8]);

    radial.seedPreparedActivationForTest();
    auto radialContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto radialEffect = radial.prepareActivate(radialContext);
    assert(radialEffect.accepted &&
        radialEffect.kind == PreparedTransformActivationKind.RadialAlign &&
        radialEffect.owner == radial.preparedOwnerForTest &&
        radial.preparedActivationSeedForTest() && radialContext.validate());
    radialContext.install();
    radialContext.install();
    assert(radial.preparedActivationForTest() &&
        radialContext.installTraceForTest() == [14, 8]);

    auto subclassContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refused = behaviorful.prepareActivate(subclassContext);
    assert(!refused.accepted &&
        refused.kind == PreparedTransformActivationKind.LinearAlign &&
        refused.owner == behaviorful.preparedOwnerForTest &&
        !subclassContext.validate());
    auto nullLinear = linear.prepareActivate(null);
    auto nullRadial = radial.prepareActivate(null);
    assert(!nullLinear.accepted &&
        nullLinear.kind == PreparedTransformActivationKind.LinearAlign &&
        nullLinear.owner == linear.preparedOwnerForTest &&
        !nullRadial.accepted &&
        nullRadial.kind == PreparedTransformActivationKind.RadialAlign &&
        nullRadial.owner == radial.preparedOwnerForTest);
    linear.seedPreparedActivationForTest();
    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try linear.prepareActivate(producerFault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !producerFault.validate() &&
        linear.preparedActivationSeedForTest());

    radial.seedPreparedActivationForTest();
    auto radialFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try radial.prepareActivate(radialFault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !radialFault.validate() &&
        radial.preparedActivationSeedForTest());
    auto radialRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(radial.prepareActivate(radialRetry).accepted &&
        radial.preparedActivationSeedForTest() && radialRetry.validate());
    radialRetry.install();
    assert(radial.preparedActivationForTest()); radialRetry.install();

    TransformTool[] productTargets = [bend, push];
    const productKinds = [PreparedTransformActivationKind.Bend,
                          PreparedTransformActivationKind.Push];
    foreach (i, target; productTargets) {
        target.seedPreparedActivationForTest();
        auto productContext = new PreparedRecordContext(new CommandHistory(),
            new RecordObserverHub());
        PreparedTransformActivationEffect effect;
        if (target is bend) effect = bend.prepareActivate(productContext);
        else effect = push.prepareActivate(productContext);
        assert(effect.accepted && effect.kind == productKinds[i] &&
            effect.owner == target.preparedOwnerForTest &&
            target.preparedActivationSeedForTest() &&
            productContext.validate());
        productContext.install(); productContext.install();
        assert(target.preparedActivationForTest() &&
            productContext.installTraceForTest() == [14, 8]);
    }
}
