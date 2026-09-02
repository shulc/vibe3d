module prepared_edge_extend_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import prepared_tool_effect : PreparedEdgeExtendParamKind;
import prepared_transform_product_activation : PreparedTransformProductActivationOwner;
import tools.edit.edge_extend : EdgeExtendTool, PreparedEdgeExtendParamImage;

struct PreparedEdgeExtendParamToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeExtendParamToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeExtendParamOwner;

final class PreparedEdgeExtendParamUpdateOwner {
private:
    EdgeExtendTool target_; Layer layer_; Mesh* source_;
    PreparedEdgeExtendParamImage image_;
    PreparedTransformProductActivationOwner moveOwner_, rotateOwner_, scaleOwner_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeExtendParamToken prepared_;
    ValidatedEdgeExtendParamToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeExtendParamUpdateOwner prepare(EdgeExtendTool target,
            Layer layer, string name) {
        if (target is null || target.classinfo !is EdgeExtendTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedEdgeExtendParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(name.idup, layer.meshRef());
        if (!owner.image_.valid) return null;
        if (owner.image_.activateMove)
            owner.moveOwner_ = target.preparedParamMoveOwner();
        if (owner.image_.activateRotate)
            owner.rotateOwner_ = target.preparedParamRotateOwner();
        if (owner.image_.activateScale)
            owner.scaleOwner_ = target.preparedParamScaleOwner();
        if ((owner.image_.activateMove && owner.moveOwner_ is null) ||
            (owner.image_.activateRotate && owner.rotateOwner_ is null) ||
            (owner.image_.activateScale && owner.scaleOwner_ is null)) return null;
        return owner;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool activateMove() const nothrow @nogc { return image_.activateMove; }
    @property bool activateRotate() const nothrow @nogc { return image_.activateRotate; }
    @property bool activateScale() const nothrow @nogc { return image_.activateScale; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    @property PreparedTransformProductActivationOwner moveOwner() { return moveOwner_; }
    @property PreparedTransformProductActivationOwner rotateOwner() { return rotateOwner_; }
    @property PreparedTransformProductActivationOwner scaleOwner() { return scaleOwner_; }
    @property PreparedEdgeExtendParamKind effectKind() const nothrow @nogc {
        if (image_.appliesMesh) return PreparedEdgeExtendParamKind.Preview;
        if (image_.bankSwitch) return PreparedEdgeExtendParamKind.BankSwitch;
        if (image_.pivotUpdate) return PreparedEdgeExtendParamKind.Pivot;
        return PreparedEdgeExtendParamKind.Noop;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null) return false;
        if ((moveOwner_ !is null && !moveOwner_.begin()) ||
            (rotateOwner_ !is null && !rotateOwner_.begin()) ||
            (scaleOwner_ !is null && !scaleOwner_.begin())) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || layer_ is null ||
            &layer_.meshRef() !is source_ || prepared_.owner != owner_ ||
            prepared_.generation != generation_ ||
            (moveOwner_ !is null && !moveOwner_.validate()) ||
            (rotateOwner_ !is null && !rotateOwner_.validate()) ||
            (scaleOwner_ !is null && !scaleOwner_.validate()) ||
            !target_.preparedParamUpdateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedParamUpdate(image_);
        if (moveOwner_ !is null) moveOwner_.install();
        if (rotateOwner_ !is null) rotateOwner_.install();
        if (scaleOwner_ !is null) scaleOwner_.install();
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) {
            if (moveOwner_ !is null) moveOwner_.abort();
            if (rotateOwner_ !is null) rotateOwner_.abort();
            if (scaleOwner_ !is null) scaleOwner_.abort();
            image_.clear(); consume();
        }
    }
private:
    this(EdgeExtendTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextEdgeExtendParamOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; source_ = null;
        moveOwner_ = rotateOwner_ = scaleOwner_ = null;
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
    auto layer = new Layer; layer.meshRef() = makeCube();
    layer.meshRef().syncSelection(); layer.meshRef().selectEdge(0);
    GpuMesh gpu;
    auto tool = new EdgeExtendTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init); tool.seedPreparedParamForTest(layer.meshRef());
    const oldVertices = layer.meshRef().vertices.length;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7, 11);
    auto effect = tool.prepareParamChanged("inset", context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.accepted && effect.kind == PreparedEdgeExtendParamKind.Preview &&
        layer.meshRef().vertices.length == oldVertices && context.validate());
    context.install();
    assert(layer.meshRef().vertices.length > oldVertices &&
        tool.preparedParamInstalledForTest(true, false) &&
        context.installTraceForTest() == [3,4,2,69,8]);

    auto bankLayer = new Layer; bankLayer.meshRef() = makeCube(); GpuMesh bankGpu;
    auto bankTool = new EdgeExtendTool(() => &bankLayer.meshRef(), &bankGpu,
        &mode, LitShader.init); bankTool.seedPreparedParamForTest(bankLayer.meshRef());
    bankTool.setPreparedRotateBankForTest(true);
    auto bankContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto bank = bankTool.prepareParamChanged("rotateHandle", bankContext,
        bankLayer, null);
    assert(bank.accepted && bank.kind == PreparedEdgeExtendParamKind.BankSwitch &&
        bankContext.validate()); bankContext.install();
    assert(bankTool.preparedParamInstalledForTest(false, true) &&
        bankContext.installTraceForTest() == [69,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    staleLayer.meshRef().syncSelection(); staleLayer.meshRef().selectEdge(0);
    GpuMesh staleGpu;
    auto staleTool = new EdgeExtendTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init); staleTool.seedPreparedParamForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged("inset", staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(17.0f);
    assert(!staleContext.validate() && staleLayer.meshRef().vertices.length == 8);

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    wrongLayer.meshRef().syncSelection(); wrongLayer.meshRef().selectEdge(0);
    auto wrongTool = new EdgeExtendTool(() => &wrongLayer.meshRef(), &staleGpu,
        &mode, LitShader.init); wrongTool.seedPreparedParamForTest(wrongLayer.meshRef());
    GpuMesh foreignGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    assert(!wrongTool.prepareParamChanged("inset", wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignGpu)).accepted &&
        wrongLayer.meshRef().vertices.length == 8);
}
