module prepared_transform_product_activation;

import core.atomic : atomicOp;
import tools.transform.transform : TransformTool;
import tools.transform.move : MoveTool, PreparedMoveActivationImage;
import tools.transform.rotate : RotateTool, PreparedRotateActivationImage;
import tools.transform.scale : ScaleTool, PreparedScaleActivationImage;

enum PreparedTransformProductActivationKind : ubyte { Move, Rotate, Scale }
struct PreparedTransformProductActivationToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedTransformProductActivationToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextTransformProductActivationOwner;

/// Closed exact-product activation owner. Product images remain owner-held;
/// only scalar identity/generation tokens cross the context boundary.
final class PreparedTransformProductActivationOwner {
private:
    TransformTool target_;
    PreparedTransformProductActivationKind kind_;
    PreparedMoveActivationImage move_;
    PreparedRotateActivationImage rotate_;
    PreparedScaleActivationImage scale_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTransformProductActivationToken prepared_;
    ValidatedTransformProductActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTransformProductActivationOwner prepare(TransformTool target) {
        if (target is null) return null;
        auto result = new PreparedTransformProductActivationOwner(target);
        if (target.classinfo is MoveTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Move;
            result.move_ = (cast(MoveTool) target).buildPreparedProductActivation();
            if (!result.move_.valid) return null;
        } else if (target.classinfo is RotateTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Rotate;
            result.rotate_ = (cast(RotateTool) target).buildPreparedProductActivation();
            if (!result.rotate_.valid) return null;
        } else if (target.classinfo is ScaleTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Scale;
            result.scale_ = (cast(ScaleTool) target).buildPreparedProductActivation();
            if (!result.scale_.valid) return null;
        } else return null;
        return result;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
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
        final switch (kind_) {
        case PreparedTransformProductActivationKind.Move:
            (cast(MoveTool) target_).installPreparedProductActivation(move_); break;
        case PreparedTransformProductActivationKind.Rotate:
            (cast(RotateTool) target_).installPreparedProductActivation(rotate_); break;
        case PreparedTransformProductActivationKind.Scale:
            (cast(ScaleTool) target_).installPreparedProductActivation(scale_); break;
        }
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { scrub(); consume(); } }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !move_.valid && !rotate_.valid && !scale_.valid &&
            rotate_.origVertices.length == 0 &&
            scale_.activationVertices.length == 0;
    }
private:
    this(TransformTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextTransformProductActivationOwner, 1UL);
    }
    void scrub() nothrow @nogc { move_.clear(); rotate_.clear(); scale_.clear(); }
    void consume() nothrow @nogc {
        scrub(); pending_ = validated_ = false; consumed_ = true; target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import mesh : Mesh, GpuMesh, makeCube;
    import editmode : EditMode;
    import math : Vec3;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    import tools.transform.xfrm_transform : XfrmTransformTool;
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
    auto rotateFirst = mesh.vertices[0];
    auto rotateLivePtr = mesh.vertices.ptr;
    auto rotateOwner = PreparedTransformProductActivationOwner.prepare(rotate);
    mesh.vertices[0].x += 12;
    auto rotateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(rotateContext.prepareTransformProductActivation(rotateOwner) &&
        rotateContext.markNoHistoryInstall() && rotateContext.validate());
    rotateContext.install();
    rotateContext.install();
    assert(rotate.preparedProductActivationForTest(mesh.vertices.length,
        rotateFirst, rotateLivePtr) && rotateOwner.payloadEmpty() &&
        rotateContext.installTraceForTest() == [15,8]);

    scale.seedPreparedProductActivationForTest();
    auto scaleFirst = mesh.vertices[0];
    auto scaleLivePtr = mesh.vertices.ptr;
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
    assert(scale.preparedProductActivationForTest(mesh.vertices.length,
        scaleFirst, scaleLivePtr, Vec3(2,3,4)) && fresh.payloadEmpty() &&
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
}
