module prepared_poly_inset_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedPolyInsetParamKind;
import tools.edit.poly_inset_tool : PolyInsetTool, PreparedPolyInsetParamImage;

struct PreparedPolyInsetParamToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedPolyInsetParamToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextPolyInsetParamOwner;

final class PreparedPolyInsetParamUpdateOwner {
private:
    PolyInsetTool target_; Layer layer_; Mesh* source_;
    PreparedPolyInsetParamImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedPolyInsetParamToken prepared_;
    ValidatedPolyInsetParamToken validatedToken_;
public:
    @disable this();
    static PreparedPolyInsetParamUpdateOwner prepare(PolyInsetTool target,
            Layer layer) {
        if (target is null || target.classinfo !is PolyInsetTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedPolyInsetParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property PreparedPolyInsetParamKind effectKind() const nothrow @nogc {
        return !image_.valid ? PreparedPolyInsetParamKind.None : image_.applies
            ? PreparedPolyInsetParamKind.Preview : PreparedPolyInsetParamKind.Noop;
    }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null || !image_.valid)
            return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null || layer_ is null ||
            source_ is null || &layer_.meshRef() !is source_ ||
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
    this(PolyInsetTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextPolyInsetParamOwner, 1UL);
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
    layer.meshRef().syncSelection(); layer.meshRef().selectFace(0);
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new PolyInsetTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.seedPreparedParamForTest(layer.meshRef());
    const oldVertices = layer.meshRef().vertices.length;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged(context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedPolyInsetParamKind.Preview &&
        layer.meshRef().vertices.length == oldVertices &&
        !tool.preparedParamBuiltForTest());
    assert(context.validate()); context.install(); context.install();
    assert(layer.meshRef().vertices.length > oldVertices &&
        tool.preparedParamBuiltForTest() &&
        context.installTraceForTest() == [3,4,50,2,8]);

    auto noopLayer = new Layer; noopLayer.meshRef() = makeCube();
    GpuMesh noopGpu;
    auto noopTool = new PolyInsetTool(() => &noopLayer.meshRef(), &noopGpu,
        &mode, LitShader.init);
    noopTool.seedPreparedParamForTest(noopLayer.meshRef(), false);
    auto noopContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto noop = noopTool.prepareParamChanged(noopContext, noopLayer, null);
    assert(noop.accepted && noop.kind == PreparedPolyInsetParamKind.Noop &&
        noopContext.validate()); noopContext.install();
    assert(noopLayer.meshRef().vertices.length == 8 &&
        noopContext.installTraceForTest() == [50,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    staleLayer.meshRef().syncSelection(); staleLayer.meshRef().selectFace(0);
    GpuMesh staleGpu;
    auto staleTool = new PolyInsetTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(17.0f);
    assert(!staleContext.validate() && staleLayer.meshRef().vertices.length == 8);

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    wrongLayer.meshRef().syncSelection(); wrongLayer.meshRef().selectFace(0);
    auto wrongTool = new PolyInsetTool(() => &wrongLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    wrongTool.seedPreparedParamForTest(wrongLayer.meshRef());
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    auto wrong = wrongTool.prepareParamChanged(wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu));
    assert(!wrong.accepted && !wrongContext.validate() &&
        wrongLayer.meshRef().vertices.length == 8);
}
