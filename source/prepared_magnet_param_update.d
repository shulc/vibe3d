module prepared_magnet_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedMagnetParamKind;
import tools.deform.magnet : MagnetTool, PreparedMagnetParamImage;

struct PreparedMagnetParamToken {
    @disable this(this);
private: ulong owner, generation;
}
struct ValidatedMagnetParamToken {
    @disable this(this);
private: ulong owner, generation;
}
private shared ulong nextMagnetParamOwner;

final class PreparedMagnetParamUpdateOwner {
private:
    MagnetTool target_;
    Layer layer_;
    Mesh* source_;
    PreparedMagnetParamImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMagnetParamToken prepared_;
    ValidatedMagnetParamToken validatedToken_;
public:
    @disable this();
    static PreparedMagnetParamUpdateOwner prepare(MagnetTool target,
            string pname, Layer layer) {
        if (target is null || target.classinfo !is MagnetTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedMagnetParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamImage(pname, layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property PreparedMagnetParamKind effectKind() const nothrow @nogc {
        return !image_.valid ? PreparedMagnetParamKind.None : image_.applies
            ? PreparedMagnetParamKind.Preview : PreparedMagnetParamKind.Noop;
    }
    ref const(Mesh) candidate() const return scope nothrow @nogc {
        return image_.candidate;
    }
    @property uint deliveryFlags() const nothrow @nogc {
        return image_.deliveryFlags;
    }
    @property uint deliveryDomains() const nothrow @nogc {
        return image_.deliveryDomains;
    }
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
            !target_.preparedParamMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedParam(image_); consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(MagnetTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextMagnetParamOwner, 1UL);
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

    auto layer = new Layer; layer.meshRef() = makeCube();
    layer.meshRef().syncSelection(); layer.meshRef().selectVertex(0);
    GpuMesh gpu; EditMode mode = EditMode.Vertices;
    auto tool = new MagnetTool(() => &layer.meshRef(), &gpu, &mode);
    tool.seedPreparedParamForTest(layer.meshRef());
    const oldPosition = layer.meshRef().vertices[0];
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged(context, "dist", layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedMagnetParamKind.Preview &&
        layer.meshRef().vertices[0] == oldPosition &&
        tool.preparedParamStateForTest(false));
    assert(context.validate()); context.install(); context.install();
    assert(layer.meshRef().vertices[0] != oldPosition &&
        tool.preparedParamStateForTest(true) &&
        context.installTraceForTest() == [3,4,44,2,8]);

    auto noopLayer = new Layer; noopLayer.meshRef() = makeCube();
    GpuMesh noopGpu;
    auto noopTool = new MagnetTool(() => &noopLayer.meshRef(), &noopGpu, &mode);
    noopTool.seedPreparedParamForTest(noopLayer.meshRef(), false);
    auto noopContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto noop = noopTool.prepareParamChanged(noopContext, "dist", noopLayer, null);
    assert(noop.accepted && noop.kind == PreparedMagnetParamKind.Noop &&
        noopContext.validate()); noopContext.install();
    assert(noopLayer.meshRef().vertices[0] == oldPosition &&
        noopContext.installTraceForTest() == [44,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    staleLayer.meshRef().syncSelection(); staleLayer.meshRef().selectVertex(0);
    GpuMesh staleGpu;
    auto staleTool = new MagnetTool(() => &staleLayer.meshRef(), &staleGpu, &mode);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged(staleContext, "dist", staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(17.0f);
    assert(!staleContext.validate() &&
        staleLayer.meshRef().vertices[0] == oldPosition &&
        staleTool.preparedParamStateForTest(false));

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    wrongLayer.meshRef().syncSelection(); wrongLayer.meshRef().selectVertex(0);
    auto wrongTool = new MagnetTool(() => &wrongLayer.meshRef(), &staleGpu, &mode);
    wrongTool.seedPreparedParamForTest(wrongLayer.meshRef());
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    auto wrong = wrongTool.prepareParamChanged(wrongContext, "dist", wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu));
    assert(!wrong.accepted && !wrongContext.validate() &&
        wrongLayer.meshRef().vertices[0] == oldPosition);
}
