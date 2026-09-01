module prepared_mirror_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.alignment.mirror : MirrorTool, PreparedMirrorActivationImage;

struct PreparedMirrorActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedMirrorActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextMirrorActivationOwner;

final class PreparedMirrorActivationOwner {
private:
    MirrorTool target_; Mesh* source_;
    PreparedMirrorActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMirrorActivationToken prepared_;
    ValidatedMirrorActivationToken validatedToken_;
public:
    @disable this();
    static PreparedMirrorActivationOwner prepare(MirrorTool target) {
        if (target is null || target.classinfo !is MirrorTool.classinfo) return null;
        auto result = new PreparedMirrorActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
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
            target_.classinfo !is MirrorTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !target_.preparedActivationParamsMatch(image_.params) ||
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
        return !image_.valid && !image_.baseline.filled && image_.mask.length == 0;
    }
private:
    this(MirrorTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextMirrorActivationOwner, 1UL);
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
    import math : Vec3;
    import mesh : GpuMesh, makeCube;
    import mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    auto mesh = makeCube();
    mesh.syncSelection(); mesh.selectFace(0);
    GpuMesh gpu;
    auto tool = new MirrorTool(() => &mesh, &gpu, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto dirtyGpu = GpuCreateOwner.fakeForTest(tool.preparedPreviewGpu());
    assert(dirtyGpu.beginEnlistedCreate() && dirtyGpu.validateEnlisted(7,11));
    dirtyGpu.installEnlisted();
    auto upload = GpuCreateUploadOwner.fakeForLegacyInitTest(tool.preparedPreviewGpu());
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); context.setResourceIdentity(7,11);
    auto effect = tool.prepareActivate(context, upload);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Mirror);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest() &&
        tool.preparedMaskSelectedForTest() == 1 && upload.fakeDeletedForTest().length == 0 &&
        context.installTraceForTest() == [36,12,8]);

    auto allMesh = makeCube(); allMesh.syncSelection();
    auto allTool = new MirrorTool(() => &allMesh, &gpu, LitShader.init);
    auto allUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        allTool.preparedPreviewGpu());
    auto allContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); allContext.setResourceIdentity(7,11);
    assert(allTool.prepareActivate(allContext, allUpload).accepted &&
        allContext.validate()); allContext.install();
    assert(allTool.preparedMaskSelectedForTest() == allMesh.faces.length);

    auto changedUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        tool.preparedPreviewGpu());
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); changed.setResourceIdentity(7,11);
    assert(tool.prepareActivate(changed, changedUpload).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new MirrorTool(() => selected, &gpu, LitShader.init);
    auto switchingUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        switching.preparedPreviewGpu());
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); switched.setResourceIdentity(7,11);
    assert(switching.prepareActivate(switched, switchingUpload).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto paramUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        tool.preparedPreviewGpu());
    auto paramChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); paramChanged.setResourceIdentity(7,11);
    assert(tool.prepareActivate(paramChanged, paramUpload).accepted);
    tool.setPreparedAxisForTest(1);
    assert(!paramChanged.validate()); paramChanged.discard();
    tool.setPreparedAxisForTest(0);

    auto faultUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        tool.preparedPreviewGpu()); faultUpload.failAfterBuildForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); fault.setResourceIdentity(7,11); bool threw;
    try tool.prepareActivate(fault, faultUpload); catch (Exception) threw = true;
    assert(threw && !fault.validate() &&
        faultUpload.fakeCreatedForTest() == faultUpload.fakeDeletedForTest());
    auto retryUpload = GpuCreateUploadOwner.fakeForLegacyInitTest(
        tool.preparedPreviewGpu());
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); retry.setResourceIdentity(7,11);
    assert(tool.prepareActivate(retry, retryUpload).accepted && retry.validate());
    retry.discard();

    auto corrupt = PreparedMirrorActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedMirrorActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    assert(!tool.prepareActivate(null, upload).accepted &&
        PreparedMirrorActivationOwner.prepare(null) is null);
}
