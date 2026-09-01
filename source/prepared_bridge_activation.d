module prepared_bridge_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.bridge_tool : BridgeTool, PreparedBridgeActivationImage;

struct PreparedBridgeActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedBridgeActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextBridgeActivationOwner;

final class PreparedBridgeActivationOwner {
private:
    BridgeTool target_; Mesh* source_;
    PreparedBridgeActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedBridgeActivationToken prepared_;
    ValidatedBridgeActivationToken validatedToken_;
public:
    @disable this();
    static PreparedBridgeActivationOwner prepare(BridgeTool target) {
        if (target is null || target.classinfo !is BridgeTool.classinfo) return null;
        auto result = new PreparedBridgeActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    @property bool selectionValid() const nothrow @nogc {
        return image_.selectionValid;
    }
    @property ref const(Mesh) previewMesh() return scope nothrow @nogc {
        return image_.preview;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is BridgeTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            target_.preparedActivationMode() != image_.mode ||
            !image_.baseline.matches(*source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.baseline.filled && image_.loopA.length == 0 &&
            image_.loopB.length == 0 && image_.capFaces.length == 0;
    }
private:
    this(BridgeTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextBridgeActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import editmode : EditMode;
    import math : Vec3;
    import mesh : GpuMesh;
    import mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh twoCaps() {
        Mesh m;
        foreach (v; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
                     Vec3(0,0,1), Vec3(1,0,1), Vec3(1,1,1), Vec3(0,1,1)])
            m.addVertex(v);
        m.addFace([0u,1u,2u,3u]); m.addFace([4u,5u,6u,7u]); m.buildLoops();
        m.faceMarks.length = m.faces.length;
        m.faceSelectionOrder.length = m.faces.length;
        m.selectFace(0); m.selectFace(1); return m;
    }
    auto mesh = twoCaps(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto dirtyGpu = GpuCreateOwner.fakeForTest(&gpu);
    assert(dirtyGpu.beginEnlistedCreate() && dirtyGpu.validateEnlisted(7,11));
    dirtyGpu.installEnlisted();
    auto tool = new BridgeTool(() => &mesh, &gpu, LitShader.init, &mode);
    tool.seedPreparedActivationForTest();
    auto create = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto upload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7,11);
    auto effect = tool.prepareActivate(context, create, upload);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Bridge);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest(true) &&
        context.installTraceForTest() == [35,12,8]);

    Mesh invalid = twoCaps(); invalid.faceMarks[] = 0;
    auto invalidTool = new BridgeTool(() => &invalid, &gpu, LitShader.init, &mode);
    auto invalidCreate = GpuCreateOwner.fakeForLegacyInitTest(
        invalidTool.preparedPreviewGpu());
    auto invalidUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        invalidTool.preparedPreviewGpu());
    auto invalidContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); invalidContext.setResourceIdentity(7,11);
    assert(invalidTool.prepareActivate(invalidContext, invalidCreate,
        invalidUpload).accepted && invalidContext.validate());
    invalidContext.install();
    assert(invalidTool.preparedActivationInstalledForTest(false) &&
        invalidContext.installTraceForTest() == [35,5,8]);

    auto changedCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto changedUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); changed.setResourceIdentity(7,11);
    assert(tool.prepareActivate(changed, changedCreate, changedUpload).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    Mesh replacement = twoCaps(); Mesh* selected = &mesh;
    auto switching = new BridgeTool(() => selected, &gpu, LitShader.init, &mode);
    auto switchingCreate = GpuCreateOwner.fakeForLegacyInitTest(
        switching.preparedPreviewGpu());
    auto switchingUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        switching.preparedPreviewGpu());
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); switched.setResourceIdentity(7,11);
    assert(switching.prepareActivate(switched, switchingCreate,
        switchingUpload).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto modeCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto modeUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto modeChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); modeChanged.setResourceIdentity(7,11);
    assert(tool.prepareActivate(modeChanged, modeCreate, modeUpload).accepted);
    mode = EditMode.Edges; assert(!modeChanged.validate()); modeChanged.discard();
    mode = EditMode.Polygons;

    auto faultCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto faultUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    faultUpload.failAfterBuildForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); fault.setResourceIdentity(7,11); bool threw;
    try tool.prepareActivate(fault, faultCreate, faultUpload);
    catch (Exception) threw = true;
    assert(threw && !fault.validate() &&
        faultUpload.fakeCreatedForTest() == faultUpload.fakeDeletedForTest());
    auto retryCreate = GpuCreateOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto retryUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); retry.setResourceIdentity(7,11);
    assert(tool.prepareActivate(retry, retryCreate, retryUpload).accepted &&
        retry.validate()); retry.discard();

    auto corrupt = PreparedBridgeActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedBridgeActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    assert(!tool.prepareActivate(null, create, upload).accepted &&
        PreparedBridgeActivationOwner.prepare(null) is null);
}
