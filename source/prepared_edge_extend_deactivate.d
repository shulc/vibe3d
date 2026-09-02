module prepared_edge_extend_deactivate;

import core.atomic : atomicOp;
import commands.mesh.session_edit : MeshSessionEdit;
import document : Layer;
import mesh : Mesh;
import tools.edit.edge_extend : EdgeExtendTool, PreparedEdgeExtendDeactivateImage;

struct PreparedEdgeExtendDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeExtendDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeExtendDeactivateOwner;

final class PreparedEdgeExtendDeactivateOwner {
private:
    EdgeExtendTool target_; Layer layer_; Mesh* source_;
    PreparedEdgeExtendDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeExtendDeactivateToken prepared_;
    ValidatedEdgeExtendDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeExtendDeactivateOwner prepare(EdgeExtendTool target,
            Layer layer, MeshSessionEdit cmd) {
        if (target is null || target.classinfo !is EdgeExtendTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedEdgeExtendDeactivateOwner(target, layer);
        owner.image_ = target.buildPreparedDeactivateState(layer.meshRef(), cmd);
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool historyEligible() const nothrow @nogc { return image_.historyEligible; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
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
    this(EdgeExtendTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextEdgeExtendDeactivateOwner, 1UL);
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
    import prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import view : View;

    EditMode mode = EditMode.Edges; auto view = new View(0,0,1,1);
    auto layer = new Layer; layer.meshRef() = makeCube();
    layer.meshRef().syncSelection(); layer.meshRef().selectEdge(0);
    GpuMesh gpu; auto history = new CommandHistory();
    auto tool = new EdgeExtendTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, mode, "test.edgeExtend", "Edge Extend"));
    tool.seedPreparedDeactivateForTest(layer.meshRef());
    const liveVersion = layer.meshRef().mutationVersion;
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareDeactivate(context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.resourceAccepted && effect.historyAccepted &&
        effect.kind == PreparedDeactivateKind.EdgeExtend &&
        layer.meshRef().mutationVersion == liveVersion && context.validate());
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        tool.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [3,4,2,1,70]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube(); GpuMesh idleGpu;
    auto idleTool = new EdgeExtendTool(() => &idleLayer.meshRef(), &idleGpu,
        &mode, LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idle = idleTool.prepareDeactivate(idleContext, idleLayer, null);
    assert(idle.resourceAccepted && !idle.historyAccepted && idleContext.validate());
    idleContext.install();
    assert(idleTool.preparedDeactivateInstalledForTest() &&
        idleContext.installTraceForTest() == [8,70]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new EdgeExtendTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    assert(staleTool.prepareDeactivate(staleContext, staleLayer, null).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
