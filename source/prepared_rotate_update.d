module prepared_rotate_update;

import core.atomic : atomicOp;
import document : Layer;
import editmode : EditMode;
import mesh : Mesh;
import operator : VectorStack;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedRotateUpdateKind;
import tool : Tool;
import tools.transform.rotate : RotateTool, PreparedRotateUpdateImage,
    PreparedRotateUpdateBranch;

struct PreparedRotateUpdateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedRotateUpdateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextRotateUpdateOwner;

/// Exact-class owner for one dormant RotateTool.update projection. Layer,
/// mesh, wrapper and edit-mode identities are retained outside the owned
/// value image and revalidated immediately before the nothrow install.
final class PreparedRotateUpdateOwner {
private:
    RotateTool target_;
    Layer layer_;
    Mesh* mesh_;
    Tool wrapper_;
    EditMode mode_;
    PreparedRotateUpdateImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedRotateUpdateToken prepared_;
    ValidatedRotateUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedRotateUpdateOwner prepare(RotateTool target, Layer layer,
            ref VectorStack vts, PreparedRecordContext context) {
        if (target is null || target.classinfo !is RotateTool.classinfo ||
            layer is null || target.preparedMeshForUpdate() !is &layer.meshRef())
            return null;
        auto owner = new PreparedRotateUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedUpdate(vts, context);
        return owner.image_.valid ? owner : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is RotateTool.classinfo || layer_ is null ||
            mesh_ !is &layer_.meshRef() ||
            target_.preparedWrapperForUpdate() !is wrapper_ ||
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
    PreparedRotateUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedRotateUpdateKind.None;
        final switch (image_.projection.branch) {
        case PreparedRotateUpdateBranch.InactiveNoop:
            return PreparedRotateUpdateKind.InactiveNoop;
        case PreparedRotateUpdateBranch.DraggingNoop:
            return PreparedRotateUpdateKind.DraggingNoop;
        case PreparedRotateUpdateBranch.IdleRefresh:
            return PreparedRotateUpdateKind.IdleRefresh;
        case PreparedRotateUpdateBranch.SelectionRefresh:
            return PreparedRotateUpdateKind.SelectionRefresh;
        case PreparedRotateUpdateBranch.MutationRefresh:
            return PreparedRotateUpdateKind.MutationRefresh;
        case PreparedRotateUpdateBranch.PanelRegrade:
            return PreparedRotateUpdateKind.PanelRegrade;
        case PreparedRotateUpdateBranch.WrapperRegrade:
            return PreparedRotateUpdateKind.WrapperRegrade;
        }
    }
    version(unittest) bool targetMatchesForTest() const nothrow @nogc {
        return target_ !is null && layer_ !is null &&
            target_.preparedUpdateMatches(image_, layer_.meshRef());
    }
private:
    this(RotateTool target, Layer layer) {
        target_ = target; layer_ = layer;
        mesh_ = target.preparedMeshForUpdate();
        wrapper_ = target.preparedWrapperForUpdate();
        mode_ = target.preparedEditModeForUpdate();
        owner_ = atomicOp!"+="(nextRotateUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; mesh_ = null;
        wrapper_ = null; pending_ = validated_ = false; consumed_ = true;
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
    auto tool = new RotateTool(() => &layer.meshRef(), &gpu, &mode);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto direct = PreparedRotateUpdateOwner.prepare(tool, layer, vts, context);
    assert(direct !is null && direct.targetMatchesForTest(), "rotate image mismatch immediately after prepare");
    direct.abort(); context.discard();
    context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    auto effect = tool.prepareUpdate(vts, context, layer);
    assert(effect.accepted);
    assert(effect.kind == PreparedRotateUpdateKind.InactiveNoop);
    assert(context.validate());
    context.install(); context.install();
    assert(context.installTraceForTest() == [8, 56]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    auto staleTool = new RotateTool(() => &staleLayer.meshRef(), &gpu, &mode);
    auto staleContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(staleTool.prepareUpdate(vts, staleContext, staleLayer).accepted);
    staleLayer.meshRef().vertices[0].x += 1;
    assert(!staleContext.validate()); staleContext.discard();
}
