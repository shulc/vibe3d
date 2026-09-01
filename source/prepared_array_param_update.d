module prepared_array_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedArrayParamKind;
import tools.alignment.array_tool : ArrayTool, PreparedArrayParamImage;

struct PreparedArrayParamToken {
    @disable this(this);
private: ulong owner, generation;
}
struct ValidatedArrayParamToken {
    @disable this(this);
private: ulong owner, generation;
}
private shared ulong nextArrayParamOwner;

/// Closed owner for ArrayTool's interactive parameter-preview transition.
final class PreparedArrayParamUpdateOwner {
private:
    ArrayTool target_;
    Layer layer_;
    Mesh* source_;
    PreparedArrayParamImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedArrayParamToken prepared_;
    ValidatedArrayParamToken validatedToken_;
public:
    @disable this();
    static PreparedArrayParamUpdateOwner prepare(ArrayTool target, Layer layer) {
        if (target is null || target.classinfo !is ArrayTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedArrayParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property PreparedArrayParamKind effectKind() const nothrow @nogc {
        return !image_.valid ? PreparedArrayParamKind.None : image_.applies
            ? PreparedArrayParamKind.Preview : PreparedArrayParamKind.Noop;
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
        if (pending_ || consumed_ || target_ is null || layer_ is null ||
            !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            layer_ is null || source_ is null || &layer_.meshRef() !is source_ ||
            prepared_.owner != owner_ ||
            prepared_.generation != generation_ ||
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
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(ArrayTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextArrayParamOwner, 1UL);
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
    layer.meshRef().syncSelection(); layer.meshRef().selectFace(0);
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new ArrayTool(() => &layer.meshRef(), &gpu, &mode);
    tool.seedPreparedParamForTest(layer.meshRef(), true, true, false);
    const oldFaces = layer.meshRef().faces.length;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged(context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedArrayParamKind.Preview &&
        layer.meshRef().faces.length == oldFaces &&
        tool.preparedParamStateForTest(false));
    assert(context.validate()); context.install(); context.install();
    assert(layer.meshRef().faces.length > oldFaces &&
        tool.preparedParamStateForTest(true) &&
        context.installTraceForTest() == [3,4,43,2,8]);

    auto noopLayer = new Layer; noopLayer.meshRef() = makeCube();
    GpuMesh noopGpu;
    auto noopTool = new ArrayTool(() => &noopLayer.meshRef(), &noopGpu, &mode);
    noopTool.seedPreparedParamForTest(noopLayer.meshRef(), false, true, false);
    auto noopContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto noop = noopTool.prepareParamChanged(noopContext, noopLayer, null);
    assert(noop.accepted && noop.kind == PreparedArrayParamKind.Noop &&
        noopContext.validate()); noopContext.install();
    assert(noopLayer.meshRef().faces.length == 6 &&
        noopContext.installTraceForTest() == [43,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    GpuMesh staleGpu;
    auto staleTool = new ArrayTool(() => &staleLayer.meshRef(), &staleGpu, &mode);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef(), true, true, false);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(17);
    assert(!staleContext.validate() && staleLayer.meshRef().faces.length == 6 &&
        staleTool.preparedParamStateForTest(false));

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    auto wrongTool = new ArrayTool(() => &wrongLayer.meshRef(), &staleGpu, &mode);
    wrongTool.seedPreparedParamForTest(wrongLayer.meshRef(), true, true, false);
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    auto wrong = wrongTool.prepareParamChanged(wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu));
    assert(!wrong.accepted && !wrongContext.validate() &&
        wrongLayer.meshRef().faces.length == 6);
}
