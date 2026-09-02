module prepared_slice_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedSliceParamKind;
import tools.slice.slice_tool : SliceTool, PreparedSliceParamImage;

struct PreparedSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextSliceParamOwner;

final class PreparedSliceParamUpdateOwner {
private:
    SliceTool target_; Layer layer_; Mesh* source_;
    PreparedSliceParamImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedSliceParamToken prepared_;
    ValidatedSliceParamToken validatedToken_;
public:
    @disable this();
    static PreparedSliceParamUpdateOwner prepare(SliceTool target,
            Layer layer, string pname) {
        if (target is null || target.classinfo !is SliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedSliceParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(pname.idup,
                                                       layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property PreparedSliceParamKind effectKind() const nothrow @nogc {
        if (!image_.valid || !image_.recognized) return PreparedSliceParamKind.Noop;
        if (image_.applies) return PreparedSliceParamKind.Preview;
        return image_.pname == "axis" ? PreparedSliceParamKind.AxisLatch
                                      : PreparedSliceParamKind.Noop;
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
    this(SliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextSliceParamOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
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
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new SliceTool(() => &layer.meshRef(), &gpu, &mode, LitShader.init);
    tool.seedPreparedParamForTest(layer.meshRef());
    const beforeFaces = layer.meshRef().faces.length;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged("split", context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedSliceParamKind.Preview &&
        layer.meshRef().faces.length == beforeFaces);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedParamInstalledForTest(layer.meshRef()) &&
        context.installTraceForTest() == [3,4,64,2,8]);

    auto axisLayer = new Layer; axisLayer.meshRef() = makeCube();
    GpuMesh axisGpu;
    auto axisTool = new SliceTool(() => &axisLayer.meshRef(), &axisGpu, &mode,
        LitShader.init); axisTool.seedPreparedParamForTest(axisLayer.meshRef(), false);
    auto axisContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto axisEffect = axisTool.prepareParamChanged("axis", axisContext, axisLayer, null);
    assert(axisEffect.accepted && axisEffect.kind == PreparedSliceParamKind.AxisLatch &&
        axisContext.validate()); axisContext.install();
    assert(axisTool.preparedAxisLockedForTest() &&
        axisContext.installTraceForTest() == [64,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    GpuMesh staleGpu;
    auto staleTool = new SliceTool(() => &staleLayer.meshRef(), &staleGpu, &mode,
        LitShader.init); staleTool.seedPreparedParamForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged("split", staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest();
    assert(!staleContext.validate() && staleLayer.meshRef().faces.length == 6);

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    auto wrongTool = new SliceTool(() => &wrongLayer.meshRef(), &staleGpu, &mode,
        LitShader.init); wrongTool.seedPreparedParamForTest(wrongLayer.meshRef());
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    assert(!wrongTool.prepareParamChanged("split", wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu)).accepted &&
        wrongLayer.meshRef().faces.length == 6);
}
