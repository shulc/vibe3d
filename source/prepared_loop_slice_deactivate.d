module prepared_loop_slice_deactivate;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import snapshot : MeshSnapshot;
import tools.slice.loop_slice_tool : LoopSliceTool,
    PreparedLoopSliceDeactivateImage;

struct PreparedLoopSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedLoopSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextLoopSliceDeactivateOwner;

final class PreparedLoopSliceDeactivateOwner {
private:
    LoopSliceTool target_; Layer layer_; Mesh* source_;
    PreparedLoopSliceDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedLoopSliceDeactivateToken prepared_;
    ValidatedLoopSliceDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedLoopSliceDeactivateOwner prepare(LoopSliceTool target,
            Layer layer) {
        if (target is null || target.classinfo !is LoopSliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedLoopSliceDeactivateOwner(target, layer);
        owner.image_ = target.buildPreparedDeactivateState(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool historyEligible() const nothrow @nogc { return image_.historyEligible; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    MeshSnapshot beforeSnapshot() { return image_.expectedBefore; }
    void markHistoryPrepared() nothrow @nogc { image_.installBeforeFromLive = true; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || layer_ is null ||
            &layer_.meshRef() !is source_ || prepared_.owner != owner_ ||
            prepared_.generation != generation_ ||
            !target_.preparedDeactivateStateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivateState(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(LoopSliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextLoopSliceDeactivateOwner, 1UL);
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
    import commands.mesh.session_edit : MeshSessionEdit;
    import editmode : EditMode;
    import mesh : GpuMesh, makeCube;
    import mesh_gpu : GpuUploadOwner;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import view : View;

    EditMode mode = EditMode.Edges;
    auto view = new View(0,0,1,1);

    auto commitLayer = new Layer; commitLayer.meshRef() = makeCube();
    GpuMesh commitGpu; auto history = new CommandHistory();
    auto commitTool = new LoopSliceTool(() => &commitLayer.meshRef(),
        &commitGpu, &mode, LitShader.init);
    commitTool.setGestureBindings(history, () => new MeshSessionEdit(
        &commitLayer.meshRef(), view, mode, "test.loopSlice", "Loop Slice"));
    commitTool.seedPreparedDeactivateForTest(commitLayer.meshRef(), true);
    const commitVersion = commitLayer.meshRef().mutationVersion;
    auto commitContext = new PreparedRecordContext(history,
        new RecordObserverHub());
    auto commitEffect = commitTool.prepareDeactivate(commitContext, commitLayer,
        null);
    assert(commitEffect.resourceAccepted && commitEffect.historyAccepted &&
        commitEffect.kind == PreparedDeactivateKind.LoopSlice &&
        commitLayer.meshRef().mutationVersion == commitVersion &&
        commitContext.validate());
    commitContext.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        commitTool.preparedDeactivateInstalledForTest(
            commitLayer.meshRef(), true) &&
        commitContext.installTraceForTest() == [1,67]);

    auto cancelLayer = new Layer; cancelLayer.meshRef() = makeCube();
    GpuMesh cancelGpu;
    auto cancelTool = new LoopSliceTool(() => &cancelLayer.meshRef(),
        &cancelGpu, &mode, LitShader.init);
    cancelTool.seedPreparedDeactivateForTest(cancelLayer.meshRef(), false);
    const cancelVersion = cancelLayer.meshRef().mutationVersion;
    auto cancelContext = new PreparedRecordContext(null,
        new RecordObserverHub()); cancelContext.setResourceIdentity(7, 11);
    auto cancelEffect = cancelTool.prepareDeactivate(cancelContext, cancelLayer,
        GpuUploadOwner.fakeForTest(&cancelGpu));
    assert(cancelEffect.resourceAccepted && !cancelEffect.historyAccepted &&
        cancelLayer.meshRef().mutationVersion == cancelVersion &&
        cancelContext.validate());
    cancelContext.install();
    assert(cancelTool.preparedDeactivateInstalledForTest(
        cancelLayer.meshRef(), true) &&
        cancelContext.installTraceForTest() == [3,4,2,8,67]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube(); GpuMesh idleGpu;
    auto idleTool = new LoopSliceTool(() => &idleLayer.meshRef(), &idleGpu,
        &mode, LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idleEffect = idleTool.prepareDeactivate(idleContext, idleLayer, null);
    assert(idleEffect.resourceAccepted && !idleEffect.historyAccepted &&
        idleContext.validate());
    idleContext.install();
    assert(idleTool.preparedDeactivateInstalledForTest(idleLayer.meshRef(), false) &&
        idleContext.installTraceForTest() == [8,67]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new LoopSliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef(), false);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareDeactivate(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
