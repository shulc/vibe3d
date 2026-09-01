module prepared_radial_sweep_transition;

import mesh : Mesh;
import prepared_selection_profile : PreparedSelectionProfileOwner;
import prepared_selection_profile_image : RadialSweepProfileImage;
import tools.alignment.radial_sweep_tool : RadialSweepTool,
    RadialSweepTransitionImage, PreparedRadialSweepTransitionKind;

/// Exact, owner-held private transition image. No generic pointer/callback is
/// accepted; the context retains this owner and carries only its closed kind.
final class PreparedRadialSweepTransitionOwner {
private:
    RadialSweepTool target_;
    PreparedRadialSweepTransitionKind kind_;
    RadialSweepTransitionImage image_;
    bool begun_, consumed_;
public:
    @disable this();

    static PreparedRadialSweepTransitionOwner activation(
            RadialSweepTool target, PreparedSelectionProfileOwner profile) {
        if (!admit(target) || profile is null) return null;
        RadialSweepProfileImage profileImage;
        if (!profile.takeUnbegun(target, profileImage)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Activate);
        owner.image_ = target.buildPreparedActivationImage(profileImage);
        return owner;
    }
    static PreparedRadialSweepTransitionOwner param(RadialSweepTool target,
                                                     string name) {
        if (!admit(target)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Param);
        owner.image_ = target.buildPreparedParamImage(name);
        return owner;
    }
    static PreparedRadialSweepTransitionOwner deactivate(RadialSweepTool target) {
        if (!admit(target)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Deactivate);
        owner.image_ = target.buildPreparedDeactivateImage();
        return owner;
    }
    @property PreparedRadialSweepTransitionKind kind() const nothrow @nogc {
        return kind_;
    }
    bool owns(RadialSweepTool target) const nothrow @nogc {
        return target_ is target;
    }
    ref const(Mesh) previewForGpuUpload() const return nothrow @nogc {
        return image_.previewMesh;
    }
    bool begin() nothrow @nogc {
        if (begun_ || consumed_ || target_ is null || !image_.valid) return false;
        begun_ = true; return true;
    }
    bool validate() const nothrow @nogc {
        return begun_ && !consumed_ && target_ !is null && image_.valid;
    }
    void install() nothrow @nogc {
        if (!validate()) return;
        target_.installPreparedTransition(image_);
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && image_.previewMesh.vertices.length == 0;
    }
private:
    static bool admit(RadialSweepTool target) nothrow @nogc {
        return target !is null && target.classinfo is RadialSweepTool.classinfo;
    }
    this(RadialSweepTool target, PreparedRadialSweepTransitionKind kind) {
        target_ = target; kind_ = kind;
    }
}

version(unittest) unittest {
    import math : Vec3;
    import mesh : makeCube;
    import editmode : EditMode;
    import shader : LitShader;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;

    Mesh source = makeCube(); source.syncSelection(); source.selectFace(0);
    EditMode mode = EditMode.Polygons;
    auto tool = new RadialSweepTool(() => &source, null, &mode, LitShader.init);
    auto profile = PreparedSelectionProfileOwner.radialSweep(tool, source, mode);
    auto activation = PreparedRadialSweepTransitionOwner.activation(tool, profile);
    assert(activation !is null && activation.kind == PreparedRadialSweepTransitionKind.Activate);
    auto previewCount = activation.previewForGpuUpload.vertices.length;
    assert(previewCount > 0 && activation.begin() && activation.validate());
    source.vertices[0].x += 1000; // detached source cannot alter retained preview
    activation.install();
    assert(tool.preparedTransitionForTest(false) && activation.payloadEmpty());
    assert(!activation.begin()); activation.install();
    assert(tool.preparedTransitionForTest(false));

    tool.seedPreparedHaulForTest(4);
    auto param = PreparedRadialSweepTransitionOwner.param(tool, "axis");
    assert(param !is null && param.kind == PreparedRadialSweepTransitionKind.Param);
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareRadialSweepTransition(param));
    assert(context.markNoHistoryInstall() && context.validate()); context.install();
    assert(tool.preparedTransitionForTest(true));
    assert(tool.preparedHaulForTest() == 4);
    assert(context.installTraceForTest() == [10,8]);

    foreach (preset, expected; [Vec3(2,0,0), Vec3(0,2,0), Vec3(0,0,2), Vec3(0,2,0)]) {
        tool.seedPreparedAxisForTest(cast(int)preset, Vec3(0,2,0));
        auto image = tool.buildPreparedParamImage("axisPreset");
        assert(image.params.axis == expected && image.params.axis.length == 2 &&
               image.engaged && image.hasPreview &&
               image.kind == PreparedRadialSweepTransitionKind.Param);
    }
    foreach (axisValue, expected; [
            Vec3(0,0,0): Vec3(1,0,0),
            Vec3(0.5e-6f,0,0): Vec3(1,0,0),
            Vec3(1e-6f,0,0): Vec3(1e-6f,0,0)]) {
        tool.seedPreparedAxisForTest(0, axisValue);
        auto boundary = tool.buildPreparedParamImage("axisPreset");
        assert(boundary.params.axis == expected);
    }
    tool.seedPreparedAxisForTest(1, Vec3(4,0,0));
    auto manualAxis = tool.buildPreparedParamImage("axis");
    assert(manualAxis.params.axisPreset == 3 && manualAxis.params.axis == Vec3(4,0,0) &&
           manualAxis.engaged && manualAxis.hasPreview);

    auto previewVerts = tool.buildPreparedParamImage("unchanged").previewMesh.vertices.length;
    auto profileCount = manualAxis.profile.profile.length;
    tool.seedPreparedDeactivateParityForTest();
    auto reset = PreparedRadialSweepTransitionOwner.deactivate(tool);
    assert(reset.previewForGpuUpload.vertices.length == 0 && reset.begin()); reset.install();
    assert(reset.payloadEmpty() && !reset.begin());
    assert(tool.preparedDeactivateParityForTest(previewVerts, profileCount));

    // Dormant b5i producer composition: no live state moves until the joint
    // context installs. Activation remains deferred: a separately prepared
    // upload borrows the pre-create empty GL header and therefore cannot
    // honestly follow a prepared create without a combined create+upload owner.
    import document : Layer;
    import mesh : GpuMesh;
    auto layer = new Layer; layer.meshRef() = makeCube(); layer.meshRef().syncSelection();
    layer.meshRef().selectFace(0);
    GpuMesh mainGpu;
    auto producerTool = new RadialSweepTool(() => &layer.meshRef(), &mainGpu,
                                             &mode, LitShader.init);
    auto producerProfile = PreparedSelectionProfileOwner.radialSweep(
        producerTool, layer.meshRef(), mode);
    auto activateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    activateContext.setResourceIdentity(7, 11);
    auto activateResult = producerTool.prepareActivate(activateContext,
        producerProfile, producerTool.fakePreviewCreateUploadOwnerForTest());
    assert(activateResult.accepted && !producerTool.preparedTransitionForTest(false));
    assert(activateContext.validate()); activateContext.install();
    assert(producerTool.preparedTransitionForTest(false));
    assert(producerTool.preparedActivationForTest(true));
    assert(activateContext.installTraceForTest() == [10,12,8]);
    activateContext.install();
    assert(activateContext.installTraceForTest() == [10,12,8]);

    // Edge and invalid polygon activation retain the same private/GPU/order
    // transaction; invalid profile still mirrors legacy init+empty upload.
    auto edgeLayer = new Layer; edgeLayer.meshRef() = makeCube();
    edgeLayer.meshRef().syncSelection(); edgeLayer.meshRef().selectEdge(0);
    EditMode edgeMode = EditMode.Edges; GpuMesh edgeMain;
    auto edgeTool = new RadialSweepTool(() => &edgeLayer.meshRef(), &edgeMain,
        &edgeMode, LitShader.init);
    auto edgeContext = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    edgeContext.setResourceIdentity(7,11);
    assert(edgeTool.prepareActivate(edgeContext,
        PreparedSelectionProfileOwner.radialSweep(edgeTool, edgeLayer.meshRef(), edgeMode),
        edgeTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    assert(edgeContext.validate()); edgeContext.install();
    assert(edgeTool.preparedActivationForTest(true) &&
        edgeContext.installTraceForTest() == [10,12,8]);

    auto invalidLayer = new Layer; invalidLayer.meshRef() = makeCube();
    invalidLayer.meshRef().syncSelection(); GpuMesh invalidMain;
    auto invalidTool = new RadialSweepTool(() => &invalidLayer.meshRef(), &invalidMain,
        &mode, LitShader.init);
    auto invalidContext = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    invalidContext.setResourceIdentity(7,11);
    assert(invalidTool.prepareActivate(invalidContext,
        PreparedSelectionProfileOwner.radialSweep(invalidTool,
            invalidLayer.meshRef(), mode),
        invalidTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    assert(invalidContext.validate()); invalidContext.install();
    assert(invalidTool.preparedActivationForTest(false) &&
        invalidContext.installTraceForTest() == [10,12,8]);

    auto refusedLayer = new Layer; refusedLayer.meshRef() = makeCube();
    refusedLayer.meshRef().syncSelection(); refusedLayer.meshRef().selectFace(0);
    GpuMesh refusedMain;
    auto refusedTool = new RadialSweepTool(() => &refusedLayer.meshRef(),
        &refusedMain, &mode, LitShader.init);
    GpuMesh foreignMain;
    auto foreignTool = new RadialSweepTool(() => &refusedLayer.meshRef(),
        &foreignMain, &mode, LitShader.init);
    auto foreignProfile = PreparedSelectionProfileOwner.radialSweep(foreignTool,
        refusedLayer.meshRef(), mode);
    auto wrongProfileContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); wrongProfileContext.setResourceIdentity(7,11);
    assert(!refusedTool.prepareActivate(wrongProfileContext, foreignProfile,
        refusedTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    assert(!wrongProfileContext.validate() && refusedTool.previewGpuEmptyForTest() &&
        foreignTool.previewGpuEmptyForTest() &&
        !foreignTool.preparedProfileValidityForTest());
    auto foreignRetryContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); foreignRetryContext.setResourceIdentity(7,11);
    assert(foreignTool.prepareActivate(foreignRetryContext, foreignProfile,
        foreignTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    assert(foreignRetryContext.validate()); foreignRetryContext.install();
    assert(foreignTool.preparedActivationForTest(true));

    auto reusableProfile = PreparedSelectionProfileOwner.radialSweep(refusedTool,
        refusedLayer.meshRef(), mode);
    auto wrongActivateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); wrongActivateContext.setResourceIdentity(7,11);
    assert(!refusedTool.prepareActivate(wrongActivateContext, reusableProfile,
        invalidTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    auto retryActivateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); retryActivateContext.setResourceIdentity(7,11);
    assert(refusedTool.prepareActivate(retryActivateContext, reusableProfile,
        refusedTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    retryActivateContext.discard();

    auto faultProfile = PreparedSelectionProfileOwner.radialSweep(refusedTool,
        refusedLayer.meshRef(), mode);
    auto faultCreateUpload = refusedTool.fakePreviewCreateUploadOwnerForTest();
    faultCreateUpload.failAfterBuildForTest();
    auto activateFaultContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); activateFaultContext.setResourceIdentity(7,11);
    bool activateThrew;
    try refusedTool.prepareActivate(activateFaultContext, faultProfile, faultCreateUpload);
    catch (Exception) activateThrew = true;
    assert(activateThrew && !activateFaultContext.validate() &&
        faultCreateUpload.fakeCreatedForTest() ==
            [301,302,303,304,305,306,307,308,309] &&
        faultCreateUpload.fakeDeletedForTest() ==
            faultCreateUpload.fakeCreatedForTest() &&
        refusedTool.previewGpuEmptyForTest() &&
        !refusedTool.preparedProfileValidityForTest());
    auto faultRetryProfile = PreparedSelectionProfileOwner.radialSweep(refusedTool,
        refusedLayer.meshRef(), mode);
    auto faultRetryContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); faultRetryContext.setResourceIdentity(7,11);
    assert(refusedTool.prepareActivate(faultRetryContext, faultRetryProfile,
        refusedTool.fakePreviewCreateUploadOwnerForTest()).accepted);
    assert(faultRetryContext.validate()); faultRetryContext.install();
    assert(refusedTool.preparedActivationForTest(true));

    producerTool.seedPreparedHaulForTest(6);
    auto producerParam = PreparedRadialSweepTransitionOwner.param(producerTool, "axis");
    auto paramContext = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    paramContext.setResourceIdentity(7, 11);
    auto paramResult = producerTool.prepareParamChanged(paramContext, producerParam,
        producerTool.fakePreviewUploadOwnerForTest());
    assert(paramResult.accepted && paramContext.validate()); paramContext.install();
    assert(producerTool.preparedHaulForTest() == 6);
    assert(paramContext.installTraceForTest() == [10,2,8]);

    auto wrongTool = new RadialSweepTool(() => &layer.meshRef(), &mainGpu, &mode, LitShader.init);
    auto refusedContext = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    refusedContext.setResourceIdentity(7, 11);
    auto refused = producerTool.prepareParamChanged(refusedContext,
        PreparedRadialSweepTransitionOwner.param(producerTool, "axis"),
        wrongTool.fakePreviewUploadOwnerForTest());
    assert(!refused.accepted && !refusedContext.validate());
    auto wrongTransitionContext = new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub());
    wrongTransitionContext.setResourceIdentity(7, 11);
    auto wrongTransition = producerTool.prepareParamChanged(wrongTransitionContext,
        PreparedRadialSweepTransitionOwner.param(wrongTool, "axis"),
        producerTool.fakePreviewUploadOwnerForTest());
    assert(!wrongTransition.accepted && !wrongTransitionContext.validate());

    // Throws at both owner enlist seams are terminal for that context and
    // leave every begun owner abortable/reusable by a fresh transaction.
    import mesh_gpu : GpuUploadOwner;
    auto faultTransition = PreparedRadialSweepTransitionOwner.param(
        producerTool, "axis");
    auto faultUpload = producerTool.fakePreviewUploadOwnerForTest();
    auto transitionFaultContext = new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub());
    transitionFaultContext.setResourceIdentity(7, 11);
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    bool transitionThrew;
    try producerTool.prepareParamChanged(transitionFaultContext,
        faultTransition, faultUpload);
    catch (Exception) transitionThrew = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(transitionThrew && !transitionFaultContext.validate());
    auto transitionRetry = new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub());
    transitionRetry.setResourceIdentity(7, 11);
    assert(producerTool.prepareParamChanged(transitionRetry,
        PreparedRadialSweepTransitionOwner.param(producerTool, "axis"),
        producerTool.fakePreviewUploadOwnerForTest()).accepted);
    transitionRetry.discard();

    auto uploadFaultTransition = PreparedRadialSweepTransitionOwner.param(
        producerTool, "axis");
    auto uploadFaultOwner = producerTool.fakePreviewUploadOwnerForTest();
    auto uploadFaultContext = new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub());
    uploadFaultContext.setResourceIdentity(7, 11);
    GpuUploadOwner.failPreparedUploadForTest(true);
    bool uploadThrew;
    try producerTool.prepareParamChanged(uploadFaultContext,
        uploadFaultTransition, uploadFaultOwner);
    catch (Exception) uploadThrew = true;
    GpuUploadOwner.failPreparedUploadForTest(false);
    assert(uploadThrew && !uploadFaultContext.validate());
    auto uploadRetry = new PreparedRecordContext(
        new CommandHistory(), new RecordObserverHub());
    uploadRetry.setResourceIdentity(7, 11);
    assert(producerTool.prepareParamChanged(uploadRetry,
        PreparedRadialSweepTransitionOwner.param(producerTool, "axis"),
        producerTool.fakePreviewUploadOwnerForTest()).accepted);
    uploadRetry.discard();

    import commands.mesh.session_edit : MeshSessionEdit;
    import view : View;
    auto deactHistory = new CommandHistory();
    auto deactView = new View(0,0,1,1);
    producerTool.setGestureBindings(deactHistory, () => new MeshSessionEdit(
        &layer.meshRef(), deactView, mode, "test.radialSweep", "Radial Sweep"));
    auto liveVertexCount = layer.meshRef().vertices.length;
    import change_bus : PreparedDeliveryJournal;
    auto journalFaultContext = new PreparedRecordContext(deactHistory,
        new RecordObserverHub());
    journalFaultContext.setResourceIdentity(7, 11);
    PreparedDeliveryJournal.setFailPrepareForTest(true);
    bool journalThrew;
    try producerTool.prepareDeactivate(journalFaultContext,
        PreparedRadialSweepTransitionOwner.deactivate(producerTool), layer,
        producerTool.fakeMainUploadOwnerForTest(),
        producerTool.fakePreviewDestroyOwnerForTest());
    catch (Exception) journalThrew = true;
    PreparedDeliveryJournal.setFailPrepareForTest(false);
    assert(journalThrew && !journalFaultContext.validate() &&
        layer.meshRef().vertices.length == liveVertexCount);

    MeshSessionEdit throwingFactory() { throw new Exception("injected carrier factory failure"); }
    producerTool.setGestureBindings(deactHistory, &throwingFactory);
    auto factoryFaultContext = new PreparedRecordContext(deactHistory,
        new RecordObserverHub());
    factoryFaultContext.setResourceIdentity(7, 11);
    bool factoryThrew;
    try producerTool.prepareDeactivate(factoryFaultContext,
        PreparedRadialSweepTransitionOwner.deactivate(producerTool), layer,
        producerTool.fakeMainUploadOwnerForTest(),
        producerTool.fakePreviewDestroyOwnerForTest());
    catch (Exception) factoryThrew = true;
    assert(factoryThrew && !factoryFaultContext.validate() &&
        layer.meshRef().vertices.length == liveVertexCount);
    producerTool.setGestureBindings(deactHistory, () => new MeshSessionEdit(
        &layer.meshRef(), deactView, mode, "test.radialSweep", "Radial Sweep"));
    auto deactContext = new PreparedRecordContext(deactHistory, new RecordObserverHub());
    deactContext.setResourceIdentity(7, 11);
    auto deactResult = producerTool.prepareDeactivate(deactContext,
        PreparedRadialSweepTransitionOwner.deactivate(producerTool), layer,
        producerTool.fakeMainUploadOwnerForTest(),
        producerTool.fakePreviewDestroyOwnerForTest());
    assert(deactResult.accepted && deactResult.inserted > 0);
    assert(layer.meshRef().vertices.length == liveVertexCount);
    assert(deactContext.validate()); deactContext.install();
    assert(layer.meshRef().vertices.length > liveVertexCount);
    assert(producerTool.installedCommitMatchesPreparedForTest());
    assert(deactContext.installTraceForTest() == [3,4,2,2,1,10]);
    size_t modelDepth, uiDepth; deactHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1);

    // A positionally mis-bound carrier keeps the exact legacy edit and
    // counted diagnostic, but does not manufacture a history entry.
    import command : Command, CmdFlags;
    import change_bus : changeBus;
    final class WrongCarrier : Command {
        private Mesh ownedMesh_;
        this(View view) { super(&ownedMesh_, view, EditMode.Polygons); }
        override string name() const { return "prepared.radial.wrong"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }
    auto mismatchLayer = new Layer; mismatchLayer.meshRef() = makeCube();
    mismatchLayer.meshRef().syncSelection(); mismatchLayer.meshRef().selectFace(0);
    GpuMesh mismatchMain;
    auto mismatchTool = new RadialSweepTool(() => &mismatchLayer.meshRef(),
        &mismatchMain, &mode, LitShader.init);
    auto mismatchProfile = PreparedSelectionProfileOwner.radialSweep(mismatchTool,
        mismatchLayer.meshRef(), mode);
    auto mismatchActivation = PreparedRadialSweepTransitionOwner.activation(
        mismatchTool, mismatchProfile);
    assert(mismatchActivation.begin()); mismatchActivation.install();
    mismatchTool.seedPreparedDeactivateParityForTest();
    auto mismatchHistory = new CommandHistory();
    mismatchTool.setGestureBindings(mismatchHistory,
        () => cast(Command) new WrongCarrier(deactView));
    auto mismatchContext = new PreparedRecordContext(mismatchHistory,
        new RecordObserverHub());
    mismatchContext.setResourceIdentity(7, 11);
    auto mismatchResult = mismatchTool.prepareDeactivate(mismatchContext,
        PreparedRadialSweepTransitionOwner.deactivate(mismatchTool), mismatchLayer,
        mismatchTool.fakeMainUploadOwnerForTest(),
        mismatchTool.fakePreviewDestroyOwnerForTest());
    assert(mismatchResult.accepted && mismatchResult.inserted > 0);
    assert(mismatchContext.validate()); mismatchContext.install();
    assert(mismatchContext.installTraceForTest() == [3,4,2,2,11,8,10]);
    mismatchHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 0 && changeBus.gestureCarrierMismatch > 0);

    // No gesture: no topology/upload/history, but preview destroy then the
    // no-history seal then the exact two-field private reset still install.
    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube();
    idleLayer.meshRef().syncSelection(); idleLayer.meshRef().selectFace(0);
    GpuMesh idleMain;
    auto idleTool = new RadialSweepTool(() => &idleLayer.meshRef(), &idleMain,
                                        &mode, LitShader.init);
    auto idleProfile = PreparedSelectionProfileOwner.radialSweep(idleTool,
        idleLayer.meshRef(), mode);
    auto idleActivation = PreparedRadialSweepTransitionOwner.activation(idleTool, idleProfile);
    assert(idleActivation.begin()); idleActivation.install();
    auto idleContext = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    idleContext.setResourceIdentity(7,11);
    auto idleResult = idleTool.prepareDeactivate(idleContext,
        PreparedRadialSweepTransitionOwner.deactivate(idleTool), idleLayer,
        idleTool.fakeMainUploadOwnerForTest(), idleTool.fakePreviewDestroyOwnerForTest());
    assert(idleResult.accepted && idleResult.inserted == 0);
    assert(idleContext.validate()); idleContext.install();
    assert(idleContext.installTraceForTest() == [2,8,10]);
}
