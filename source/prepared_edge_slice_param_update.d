module prepared_edge_slice_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedEdgeSliceParamKind;
import tools.slice.edge_slice_tool : EdgeSliceTool, PreparedEdgeSliceParamImage;

struct PreparedEdgeSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeSliceParamOwner;

final class PreparedEdgeSliceParamUpdateOwner {
private:
    EdgeSliceTool target_; Layer layer_; Mesh* source_;
    PreparedEdgeSliceParamImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeSliceParamToken prepared_;
    ValidatedEdgeSliceParamToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeSliceParamUpdateOwner prepare(EdgeSliceTool target,
            Layer layer, string pname) {
        if (target is null || target.classinfo !is EdgeSliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedEdgeSliceParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(pname.idup, layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool invalidateRedo() const nothrow @nogc { return image_.invalidateRedo; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    @property PreparedEdgeSliceParamKind effectKind() const nothrow @nogc {
        if (!image_.recognized) return PreparedEdgeSliceParamKind.Noop;
        if (image_.pname == "chainArm") return image_.appliesMesh
            ? PreparedEdgeSliceParamKind.ChainArm : PreparedEdgeSliceParamKind.Noop;
        if (image_.pname == "activePoint") return PreparedEdgeSliceParamKind.ActivePoint;
        return image_.appliesMesh ? PreparedEdgeSliceParamKind.Preview
                                  : PreparedEdgeSliceParamKind.Noop;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || layer_ is null ||
            &layer_.meshRef() !is source_ || prepared_.owner != owner_ ||
            prepared_.generation != generation_ ||
            !target_.preparedParamUpdateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedParamUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(EdgeSliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextEdgeSliceParamOwner, 1UL);
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
    GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto history = new CommandHistory();
    auto tool = new EdgeSliceTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init); tool.setGestureBindings(history, null);
    tool.seedPreparedParamForTest(layer.meshRef());
    const liveVersion = layer.meshRef().mutationVersion;
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged("chainArm", context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedEdgeSliceParamKind.ChainArm &&
        layer.meshRef().mutationVersion == liveVersion && context.validate());
    context.install();
    assert(tool.preparedParamStateForTest(true, 1) &&
        context.installTraceForTest() == [3,4,2,1,66]);

    auto pointLayer = new Layer; pointLayer.meshRef() = makeCube(); GpuMesh pointGpu;
    auto pointHistory = new CommandHistory();
    auto pointTool = new EdgeSliceTool(() => &pointLayer.meshRef(), &pointGpu,
        &mode, LitShader.init); pointTool.setGestureBindings(pointHistory, null);
    pointTool.seedPreparedParamForTest(pointLayer.meshRef(), true);
    pointTool.setPreparedPointProxyForTest(0.4f);
    auto pointContext = new PreparedRecordContext(pointHistory,
        new RecordObserverHub()); pointContext.setResourceIdentity(7, 11);
    auto point = pointTool.prepareParamChanged("pointT", pointContext, pointLayer,
        GpuUploadOwner.fakeForTest(&pointGpu));
    assert(point.accepted && point.kind == PreparedEdgeSliceParamKind.Preview &&
        pointContext.validate()); pointContext.install();
    assert(pointTool.preparedParamStateForTest(true, 1) &&
        pointContext.installTraceForTest() == [3,4,2,1,66]);

    auto stateLayer = new Layer; stateLayer.meshRef() = makeCube(); GpuMesh stateGpu;
    auto stateTool = new EdgeSliceTool(() => &stateLayer.meshRef(), &stateGpu,
        &mode, LitShader.init); stateTool.seedPreparedParamForTest(stateLayer.meshRef(), true);
    stateTool.setPreparedActivePointForTest(20);
    auto stateContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto state = stateTool.prepareParamChanged("activePoint", stateContext,
        stateLayer, null);
    assert(state.accepted && state.kind == PreparedEdgeSliceParamKind.ActivePoint &&
        stateContext.validate()); stateContext.install();
    assert(stateTool.preparedParamStateForTest(true, 1) &&
        stateContext.installTraceForTest() == [8,66]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleHistory = new CommandHistory();
    auto staleTool = new EdgeSliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init); staleTool.setGestureBindings(staleHistory, null);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef(), true);
    auto staleContext = new PreparedRecordContext(staleHistory,
        new RecordObserverHub()); staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged("split", staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest();
    assert(!staleContext.validate());
}
