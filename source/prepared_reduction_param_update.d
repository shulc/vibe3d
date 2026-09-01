module prepared_reduction_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedReductionParamKind;
import tools.edit.reduce : ReductionTool, PreparedReductionParamImage;

struct PreparedReductionParamToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedReductionParamToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextReductionParamOwner;

final class PreparedReductionParamUpdateOwner {
private:
    ReductionTool target_; Layer layer_; Mesh* source_;
    PreparedReductionParamImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedReductionParamToken prepared_;
    ValidatedReductionParamToken validatedToken_;
public:
    @disable this();
    static PreparedReductionParamUpdateOwner prepare(ReductionTool target,
            Layer layer) {
        if (target is null || target.classinfo !is ReductionTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedReductionParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property PreparedReductionParamKind effectKind() const nothrow @nogc {
        return !image_.valid ? PreparedReductionParamKind.None : image_.applies
            ? PreparedReductionParamKind.Preview : PreparedReductionParamKind.Noop;
    }
    ref const(Mesh) candidate() const return scope nothrow @nogc {
        return image_.candidate;
    }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null ||
            !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            layer_ is null || source_ is null || &layer_.meshRef() !is source_ ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedParamUpdateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedParamUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(ReductionTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextReductionParamOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null; layer_ = null; source_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import editmode : EditMode;
    import mesh : GpuMesh, makeCube;
    import mesh_gpu : GpuUploadOwner;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    auto layer = new Layer; layer.meshRef() = makeCube();
    auto triMask = layer.meshRef().operandFaceMask();
    layer.meshRef().triangulateFacesByMask(triMask);
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new ReductionTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.seedPreparedParamForTest(layer.meshRef());
    const oldFaces = layer.meshRef().faces.length;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged(context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted);
    assert(effect.kind == PreparedReductionParamKind.Preview);
    assert(layer.meshRef().faces.length == oldFaces);
    assert(!tool.preparedParamBuiltForTest());
    assert(context.validate()); context.install(); context.install();
    assert(layer.meshRef().faces.length < oldFaces &&
        tool.preparedParamBuiltForTest() &&
        context.installTraceForTest() == [3,4,51,2,8]);

    auto noopLayer = new Layer; noopLayer.meshRef() = makeCube();
    GpuMesh noopGpu;
    auto noopTool = new ReductionTool(() => &noopLayer.meshRef(), &noopGpu,
        &mode, LitShader.init);
    noopTool.seedPreparedParamForTest(noopLayer.meshRef(), false);
    auto noopContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto noop = noopTool.prepareParamChanged(noopContext, noopLayer, null);
    assert(noop.accepted && noop.kind == PreparedReductionParamKind.Noop &&
        noopContext.validate()); noopContext.install();
    assert(noopLayer.meshRef().faces.length == 6 &&
        noopContext.installTraceForTest() == [51,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    auto staleMask = staleLayer.meshRef().operandFaceMask();
    staleLayer.meshRef().triangulateFacesByMask(staleMask);
    GpuMesh staleGpu;
    auto staleTool = new ReductionTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(0.25f);
    assert(!staleContext.validate() && staleLayer.meshRef().faces.length == 12);

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    auto wrongMask = wrongLayer.meshRef().operandFaceMask();
    wrongLayer.meshRef().triangulateFacesByMask(wrongMask);
    auto wrongTool = new ReductionTool(() => &wrongLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    wrongTool.seedPreparedParamForTest(wrongLayer.meshRef());
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    auto wrong = wrongTool.prepareParamChanged(wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu));
    assert(!wrong.accepted && !wrongContext.validate() &&
        wrongLayer.meshRef().faces.length == 12);
}
