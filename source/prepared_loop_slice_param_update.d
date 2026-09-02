module prepared_loop_slice_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedLoopSliceParamKind;
import tools.slice.loop_slice_tool : LoopSliceTool, PreparedLoopSliceParamImage;

struct PreparedLoopSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedLoopSliceParamToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextLoopSliceParamOwner;

final class PreparedLoopSliceParamUpdateOwner {
private:
    LoopSliceTool target_; Layer layer_; Mesh* source_;
    PreparedLoopSliceParamImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedLoopSliceParamToken prepared_;
    ValidatedLoopSliceParamToken validatedToken_;
public:
    @disable this();
    static PreparedLoopSliceParamUpdateOwner prepare(LoopSliceTool target,
            Layer layer, string pname) {
        if (target is null || target.classinfo !is LoopSliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedLoopSliceParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(pname.idup, layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool invalidateRedo() const nothrow @nogc { return image_.invalidateRedo; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    @property PreparedLoopSliceParamKind effectKind() const nothrow @nogc {
        if (image_.appliesMesh) return PreparedLoopSliceParamKind.Preview;
        return image_.expected.positions == image_.next.positions &&
            image_.expected.current == image_.next.current &&
            image_.expected.count == image_.next.count &&
            image_.expected.removeTrigger == image_.next.removeTrigger
            ? PreparedLoopSliceParamKind.Noop : PreparedLoopSliceParamKind.State;
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
    this(LoopSliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextLoopSliceParamOwner, 1UL);
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

    EditMode mode = EditMode.Edges;
    auto layer = new Layer; layer.meshRef() = makeCube(); GpuMesh gpu;
    auto history = new CommandHistory();
    auto tool = new LoopSliceTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init); tool.setGestureBindings(history, null);
    tool.seedPreparedDeactivateForTest(layer.meshRef(), true);
    tool.setPreparedPositionForTest(0.3f);
    const liveVersion = layer.meshRef().mutationVersion;
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged("position", context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedLoopSliceParamKind.Preview &&
        layer.meshRef().mutationVersion == liveVersion && context.validate());
    context.install();
    assert(tool.preparedParamStateForTest(true, 1) &&
        context.installTraceForTest() == [3,4,2,1,68]);

    auto stateLayer = new Layer; stateLayer.meshRef() = makeCube(); GpuMesh stateGpu;
    auto stateTool = new LoopSliceTool(() => &stateLayer.meshRef(), &stateGpu,
        &mode, LitShader.init); stateTool.setPreparedCountForTest(2);
    auto stateContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto stateEffect = stateTool.prepareParamChanged("count", stateContext,
        stateLayer, null);
    assert(stateEffect.accepted && stateEffect.kind == PreparedLoopSliceParamKind.State &&
        stateContext.validate()); stateContext.install();
    assert(stateTool.preparedParamStateForTest(false, 2) &&
        stateContext.installTraceForTest() == [8,68]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new LoopSliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init); auto staleHistory = new CommandHistory();
    staleTool.setGestureBindings(staleHistory, null);
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef(), true);
    staleTool.setPreparedPositionForTest(0.4f);
    auto staleContext = new PreparedRecordContext(staleHistory,
        new RecordObserverHub()); staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged("position", staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
