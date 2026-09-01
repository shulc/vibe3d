module prepared_scale_update;

import core.atomic : atomicOp;
import document : Layer;
import editmode : EditMode;
import mesh : Mesh;
import operator : VectorStack;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedScaleUpdateKind;
import tool : Tool;
import tools.transform.scale : ScaleTool, PreparedScaleUpdateImage,
    PreparedScaleUpdateBranch;

struct PreparedScaleUpdateToken { @disable this(this); private ulong owner, generation; }
struct ValidatedScaleUpdateToken { @disable this(this); private ulong owner, generation; }
private shared ulong nextScaleUpdateOwner;

final class PreparedScaleUpdateOwner {
private:
    ScaleTool target_; Layer layer_; Mesh* mesh_; Tool wrapper_; EditMode mode_;
    PreparedScaleUpdateImage image_; immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedScaleUpdateToken prepared_; ValidatedScaleUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedScaleUpdateOwner prepare(ScaleTool target, Layer layer,
            ref VectorStack vts, PreparedRecordContext context) {
        if (target is null || target.classinfo !is ScaleTool.classinfo ||
            layer is null || target.preparedMeshForUpdate() !is &layer.meshRef())
            return null;
        auto owner = new PreparedScaleUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedUpdate(vts, context);
        return owner.image_.valid ? owner : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is ScaleTool.classinfo || layer_ is null ||
            mesh_ !is &layer_.meshRef() || target_.preparedWrapperForUpdate() !is wrapper_ ||
            target_.preparedEditModeForUpdate() != mode_ ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedUpdateMatches(image_, layer_.meshRef())) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    bool meshPrepared() const nothrow @nogc { return image_.meshPrepared; }
    ref const(Mesh) candidate() const nothrow @nogc { return image_.candidate; }
    uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    bool historyPrepared() const nothrow @nogc { return image_.wrapperRefire.valid; }
    PreparedScaleUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedScaleUpdateKind.None;
        final switch (image_.projection.branch) {
        case PreparedScaleUpdateBranch.InactiveNoop: return PreparedScaleUpdateKind.InactiveNoop;
        case PreparedScaleUpdateBranch.DraggingNoop: return PreparedScaleUpdateKind.DraggingNoop;
        case PreparedScaleUpdateBranch.IdleRefresh: return PreparedScaleUpdateKind.IdleRefresh;
        case PreparedScaleUpdateBranch.SelectionRefresh: return PreparedScaleUpdateKind.SelectionRefresh;
        case PreparedScaleUpdateBranch.MutationRefresh: return PreparedScaleUpdateKind.MutationRefresh;
        case PreparedScaleUpdateBranch.PanelRegrade: return PreparedScaleUpdateKind.PanelRegrade;
        case PreparedScaleUpdateBranch.WrapperRegrade: return PreparedScaleUpdateKind.WrapperRegrade;
        }
    }
    version(unittest) bool targetMatchesForTest() const nothrow @nogc {
        return target_ !is null && layer_ !is null &&
            target_.preparedUpdateMatches(image_, layer_.meshRef());
    }
private:
    this(ScaleTool target, Layer layer) {
        target_ = target; layer_ = layer; mesh_ = target.preparedMeshForUpdate();
        wrapper_ = target.preparedWrapperForUpdate(); mode_ = target.preparedEditModeForUpdate();
        owner_ = atomicOp!"+="(nextScaleUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; mesh_ = null; wrapper_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import mesh : GpuMesh, makeCube;
    import record_observer_hub : RecordObserverHub;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Polygons; VectorStack vts;
    auto tool = new ScaleTool(() => &layer.meshRef(), &gpu, &mode);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto direct = PreparedScaleUpdateOwner.prepare(tool, layer, vts, context);
    assert(direct !is null && direct.targetMatchesForTest(), "scale image mismatch immediately after prepare");
    direct.abort(); context.discard();
    context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    auto effect = tool.prepareUpdate(vts, context, layer);
    assert(effect.accepted);
    assert(effect.kind == PreparedScaleUpdateKind.InactiveNoop);
    assert(context.validate());
    context.install(); context.install();
    assert(context.installTraceForTest() == [8, 57]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    auto staleTool = new ScaleTool(() => &staleLayer.meshRef(), &gpu, &mode);
    auto staleContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(staleTool.prepareUpdate(vts, staleContext, staleLayer).accepted);
    staleLayer.meshRef().vertices[0].x += 1;
    assert(!staleContext.validate()); staleContext.discard();
}
