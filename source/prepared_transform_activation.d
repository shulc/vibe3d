module prepared_transform_activation;

import core.atomic : atomicOp;
import tools.transform.transform : TransformTool, PreparedTransformActivationImage;
import tools.alignment.linear_align_tool : LinearAlignTool;
import tools.alignment.radial_align_tool : RadialAlignTool;

struct PreparedTransformActivationToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedTransformActivationToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextTransformActivationOwner;

/// Closed activation projection for the two exact registered alignment
/// products whose activation is precisely `super.activate()`.
final class PreparedTransformActivationOwner {
private:
    TransformTool target_;
    PreparedTransformActivationImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTransformActivationToken prepared_;
    ValidatedTransformActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTransformActivationOwner prepare(TransformTool target) {
        if (!admit(target)) return null;
        auto result = new PreparedTransformActivationOwner(target);
        result.image_ = target.buildPreparedActivationImage(); return result;
    }
    bool owns(TransformTool target) const nothrow @nogc { return target_ is target; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            prepared_.owner != owner_ || prepared_.generation != generation_) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) bool payloadEmpty() const nothrow @nogc { return !image_.valid; }
private:
    static bool admit(TransformTool target) nothrow @nogc {
        return target !is null && (target.classinfo is LinearAlignTool.classinfo ||
            target.classinfo is RadialAlignTool.classinfo);
    }
    this(TransformTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTransformActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        pending_ = validated_ = false; consumed_ = true; target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import mesh : Mesh, GpuMesh, makeCube;
    import editmode : EditMode;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    import prepared_tool_effect : PreparedTransformActivationKind;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto linear = new LinearAlignTool(() => &mesh, &gpu, &mode);
    auto radial = new RadialAlignTool(() => &mesh, &gpu, &mode);
    foreach (target; [cast(TransformTool) linear, radial]) {
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
}
