module prepared_radial_array_transition;

import mesh : Mesh;
import tools.alignment.radial_array_tool : RadialArrayTool,
    RadialArrayTransitionImage, PreparedRadialArrayTransitionKind;
import core.atomic : atomicOp;
import document : Layer;
import prepared_tool_effect : PreparedRadialArrayKind;

struct PreparedRadialArrayTransitionToken {
    @disable this(this);
private: ulong owner, generation;
}
struct ValidatedRadialArrayTransitionToken {
    @disable this(this);
private: ulong owner, generation;
}

private shared ulong nextRadialArrayTransitionOwner;

/// Closed owner for RadialArray's shared activation/deactivation session
/// projection. No mesh candidate, GPU payload, callback or open virtual
/// behavior crosses this boundary.
final class PreparedRadialArrayTransitionOwner {
private:
    RadialArrayTool target_;
    RadialArrayTransitionImage image_;
    Layer layer_;
    Mesh* source_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedRadialArrayTransitionToken prepared_;
    ValidatedRadialArrayTransitionToken validatedToken_;
public:
    @disable this();
    static PreparedRadialArrayTransitionOwner activation(RadialArrayTool target,
                                                          ref Mesh source) {
        if (!admit(target) || !target.ownsPreparedMesh(&source)) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.image_ = target.buildPreparedActivationImage(source); return result;
    }
    static PreparedRadialArrayTransitionOwner deactivation(RadialArrayTool target) {
        if (!admit(target)) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.image_ = target.buildPreparedDeactivateImage(); return result;
    }
    static PreparedRadialArrayTransitionOwner param(RadialArrayTool target,
                                                     Layer layer) {
        if (!admit(target) || layer is null ||
            !target.ownsPreparedMesh(&layer.meshRef())) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.layer_ = layer; result.source_ = &layer.meshRef();
        result.image_ = target.buildPreparedParamImage(layer.meshRef());
        return result.image_.valid ? result : null;
    }
    @property PreparedRadialArrayTransitionKind kind() const nothrow @nogc {
        return image_.kind;
    }
    bool owns(RadialArrayTool target) const nothrow @nogc { return target_ is target; }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    ref const(Mesh) candidate() const return scope nothrow @nogc {
        return image_.candidate;
    }
    @property uint deliveryFlags() const nothrow @nogc {
        return image_.deliveryFlags;
    }
    @property uint deliveryDomains() const nothrow @nogc {
        return image_.deliveryDomains;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            (image_.kind == PreparedRadialArrayTransitionKind.Param &&
             (layer_ is null || source_ is null || &layer_.meshRef() !is source_ ||
              !target_.preparedParamMatches(image_, *source_)))) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedTransition(image_);
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled &&
            image_.before.vertices.length == 0 && image_.before.edges.length == 0 &&
            image_.before.faces.length == 0 && image_.before.meshMaps.length == 0;
    }
private:
    static bool admit(RadialArrayTool target) nothrow @nogc {
        return target !is null && target.classinfo is RadialArrayTool.classinfo;
    }
    this(RadialArrayTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextRadialArrayTransitionOwner, 1UL);
    }
    void consume() nothrow @nogc {
        pending_ = validated_ = false; consumed_ = true; target_ = null;
        layer_ = null; source_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import mesh : makeCube, GpuMesh;
    import editmode : EditMode;
    import shader : LitShader;
    Mesh source = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new RadialArrayTool(() => &source, &gpu, &mode, LitShader.init);
    tool.seedPreparedTransitionForTest();
    const originalVertices = source.vertices.length;
    const originalEdges = source.edges.length;
    const originalFaces = source.faces.length;
    const originalFirst = source.vertices[0];
    const originalMutationVersion = source.mutationVersion;
    const originalTopologyVersion = source.topologyVersion;
    auto activate = PreparedRadialArrayTransitionOwner.activation(tool, source);
    Mesh foreign = makeCube();
    assert(PreparedRadialArrayTransitionOwner.activation(tool, foreign) is null);
    source.vertices[0].x += 19;
    assert(source.mutationVersion == originalMutationVersion &&
        source.topologyVersion == originalTopologyVersion);
    assert(activate.owns(tool) && activate.begin() && activate.validate());
    activate.install();
    assert(tool.preparedTransitionForTest(true) && activate.payloadEmpty());
    assert(tool.preparedSnapshotForTest(originalVertices, originalEdges,
        originalFaces, originalFirst, &source));
    activate.install(); assert(!activate.begin());
    source = makeCube();
    auto abortedActivation = PreparedRadialArrayTransitionOwner.activation(tool, source);
    assert(abortedActivation.begin()); abortedActivation.abort();
    assert(abortedActivation.payloadEmpty());
    tool.seedPreparedTransitionForTest();
    auto deactivate = PreparedRadialArrayTransitionOwner.deactivation(tool);
    assert(deactivate.begin()); deactivate.abort();
    assert(deactivate.payloadEmpty() && !deactivate.begin() &&
        !tool.preparedTransitionForTest(false));
    auto fresh = PreparedRadialArrayTransitionOwner.deactivation(tool);
    assert(fresh.begin() && fresh.validate()); fresh.install();
    assert(tool.preparedTransitionForTest(false));

    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    auto contextTool = new RadialArrayTool(() => &source, &gpu, &mode, LitShader.init);
    contextTool.seedPreparedTransitionForTest();
    auto contextOwner = PreparedRadialArrayTransitionOwner.activation(contextTool, source);
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareRadialArrayTransition(contextOwner));
    assert(context.markNoHistoryInstall() && !contextTool.preparedTransitionForTest(true));
    assert(context.validate()); context.install();
    assert(contextTool.preparedTransitionForTest(true) &&
        context.installTraceForTest() == [13,8]);

    auto faultTool = new RadialArrayTool(() => &source, &gpu, &mode, LitShader.init);
    auto faultOwner = PreparedRadialArrayTransitionOwner.activation(faultTool, source);
    auto fault = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try fault.prepareRadialArrayTransition(faultOwner); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.payloadEmpty());
    fault.discard(); assert(!fault.validate());
    auto retryOwner = PreparedRadialArrayTransitionOwner.activation(faultTool, source);
    auto retry = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(retry.prepareRadialArrayTransition(retryOwner)); retry.discard();
    assert(retryOwner.payloadEmpty() && !faultTool.preparedTransitionForTest(true));

    auto activateTool = new RadialArrayTool(() => &source, &gpu, &mode,
        LitShader.init);
    activateTool.seedPreparedTransitionForTest();
    auto activateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto activateEffect = activateTool.prepareActivate(activateContext);
    assert(activateEffect.accepted && activateContext.validate());
    activateContext.install();
    assert(activateTool.preparedTransitionForTest(true) &&
        activateContext.installTraceForTest() == [13, 8]);

    activateTool.seedPreparedTransitionForTest();
    auto deactivateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto deactivateEffect = activateTool.prepareSessionDeactivate(deactivateContext);
    assert(deactivateEffect.accepted && deactivateContext.validate());
    deactivateContext.install();
    assert(activateTool.preparedTransitionForTest(false) &&
        deactivateContext.installTraceForTest() == [8, 13]);

    import commands.mesh.session_edit : MeshSessionEdit;
    import view : View;
    auto historyTool = new RadialArrayTool(() => &source, &gpu, &mode,
        LitShader.init);
    historyTool.seedPreparedBuiltTransitionForTest(source);
    auto producerHistory = new CommandHistory();
    auto producerView = new View(0, 0, 1, 1);
    historyTool.setGestureBindings(producerHistory, () => new MeshSessionEdit(
        &source, producerView, mode, "test.radialArray", "Radial Array"));
    auto historyContext = new PreparedRecordContext(producerHistory,
        new RecordObserverHub());
    assert(historyTool.prepareSessionDeactivate(historyContext).accepted &&
        historyContext.validate());
    historyContext.install();
    assert(historyTool.preparedTransitionForTest(false) &&
        historyContext.installTraceForTest() == [1, 13]);

    Mesh foreignHistoryMesh = makeCube();
    historyTool.seedPreparedBuiltTransitionForTest(source);
    historyTool.setGestureBindings(producerHistory, () => new MeshSessionEdit(
        &foreignHistoryMesh, producerView, mode, "test.foreign", "Foreign"));
    auto mismatchContext = new PreparedRecordContext(producerHistory,
        new RecordObserverHub());
    assert(historyTool.prepareSessionDeactivate(mismatchContext).accepted &&
        mismatchContext.validate());
    mismatchContext.install();
    assert(mismatchContext.installTraceForTest() == [11, 8, 13] &&
        historyTool.preparedTransitionForTest(false));

    historyTool.seedPreparedBuiltTransitionForTest(source);
    historyTool.bindPreparedHistoryOnlyForTest(producerHistory);
    auto nullFactoryContext = new PreparedRecordContext(producerHistory,
        new RecordObserverHub());
    assert(historyTool.prepareSessionDeactivate(nullFactoryContext).accepted &&
        nullFactoryContext.validate()); nullFactoryContext.install();
    assert(nullFactoryContext.installTraceForTest() == [8, 13]);
    historyTool.seedPreparedBuiltTransitionForTest(source);
    historyTool.bindPreparedFactoryOnlyForTest(() => new MeshSessionEdit(
        &source, producerView, mode, "test.radialArray", "Radial Array"));
    auto nullHistoryContext = new PreparedRecordContext(producerHistory,
        new RecordObserverHub());
    assert(historyTool.prepareSessionDeactivate(nullHistoryContext).accepted &&
        nullHistoryContext.validate()); nullHistoryContext.install();
    assert(nullHistoryContext.installTraceForTest() == [8, 13]);

    historyTool.seedPreparedBuiltTransitionForTest(source);
    auto faultHistory = new CommandHistory();
    historyTool.setGestureBindings(faultHistory, () => new MeshSessionEdit(
        &source, producerView, mode, "test.radialArray", "Radial Array"));
    auto historyFault = new PreparedRecordContext(faultHistory,
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try historyTool.prepareSessionDeactivate(historyFault);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    size_t modelDepth, uiDepth; historyFault.installedDepths(modelDepth, uiDepth);
    assert(threw && !historyFault.validate() && modelDepth == 0 && uiDepth == 0 &&
        historyTool.preparedBuiltSeedUnchangedForTest());
    auto historyRetry = new PreparedRecordContext(faultHistory,
        new RecordObserverHub());
    assert(historyTool.prepareSessionDeactivate(historyRetry).accepted &&
        historyRetry.validate()); historyRetry.discard();
    assert(historyTool.preparedBuiltSeedUnchangedForTest());

    size_t meshReads;
    Mesh* changingMeshSource() { ++meshReads; return &source; }
    auto singleReadTool = new RadialArrayTool(&changingMeshSource, &gpu, &mode,
        LitShader.init);
    singleReadTool.seedPreparedBuiltTransitionForTest(source);
    auto singleReadHistory = new CommandHistory();
    singleReadTool.setGestureBindings(singleReadHistory,
        () => new MeshSessionEdit(&source, producerView, mode,
            "test.radialArray", "Radial Array"));
    auto singleReadContext = new PreparedRecordContext(singleReadHistory,
        new RecordObserverHub());
    assert(singleReadTool.prepareSessionDeactivate(singleReadContext).accepted &&
        meshReads == 1); singleReadContext.discard();

    Mesh* missingDeactivateMesh;
    auto missingDeactivateTool = new RadialArrayTool(
        () => missingDeactivateMesh, &gpu, &mode, LitShader.init);
    missingDeactivateTool.seedPreparedBuiltTransitionForTest(source);
    auto missingDeactivateHistory = new CommandHistory();
    missingDeactivateTool.setGestureBindings(missingDeactivateHistory,
        () => new MeshSessionEdit(&source, producerView, mode,
            "test.radialArray", "Radial Array"));
    auto missingDeactivateHub = new RecordObserverHub();
    auto missingDeactivateContext = new PreparedRecordContext(
        missingDeactivateHistory, missingDeactivateHub);
    assert(!missingDeactivateTool.prepareSessionDeactivate(
        missingDeactivateContext).accepted &&
        !missingDeactivateContext.validate() &&
        missingDeactivateContext.installTraceForTest().length == 0 &&
        missingDeactivateTool.preparedBuiltSeedUnchangedForTest());
    missingDeactivateContext.installedDepths(modelDepth, uiDepth);
    assert(modelDepth == 0 && uiDepth == 0);

    Mesh* missing;
    auto missingTool = new RadialArrayTool(() => missing, &gpu, &mode,
        LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missingTool.prepareActivate(missingContext).accepted &&
        !missingContext.validate());

    import document : Layer;
    import mesh_gpu : GpuUploadOwner;
    auto paramLayer = new Layer; paramLayer.meshRef() = makeCube();
    paramLayer.meshRef().syncSelection(); paramLayer.meshRef().selectFace(0);
    GpuMesh paramGpu;
    auto paramTool = new RadialArrayTool(() => &paramLayer.meshRef(), &paramGpu,
        &mode, LitShader.init);
    paramTool.seedPreparedParamForTest(paramLayer.meshRef(), true);
    const paramOldFaces = paramLayer.meshRef().faces.length;
    auto paramContext = new PreparedRecordContext(null, new RecordObserverHub());
    paramContext.setResourceIdentity(7, 11);
    auto paramEffect = paramTool.prepareParamChanged(paramContext, paramLayer,
        GpuUploadOwner.fakeForTest(&paramGpu));
    assert(paramEffect.accepted && paramEffect.kind == PreparedRadialArrayKind.Param &&
        paramLayer.meshRef().faces.length == paramOldFaces &&
        paramTool.preparedParamStateForTest(false) && paramContext.validate());
    paramContext.install(); paramContext.install();
    assert(paramLayer.meshRef().faces.length > paramOldFaces &&
        paramTool.preparedParamStateForTest(true) &&
        paramContext.installTraceForTest() == [3,4,13,2,8]);

    auto noopLayer = new Layer; noopLayer.meshRef() = makeCube();
    GpuMesh noopGpu;
    auto noopTool = new RadialArrayTool(() => &noopLayer.meshRef(), &noopGpu,
        &mode, LitShader.init);
    noopTool.seedPreparedParamForTest(noopLayer.meshRef(), false);
    auto noopContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto noopEffect = noopTool.prepareParamChanged(noopContext, noopLayer, null);
    assert(noopEffect.accepted && noopEffect.kind == PreparedRadialArrayKind.Param &&
        noopContext.validate()); noopContext.install();
    assert(noopLayer.meshRef().faces.length == 6 &&
        noopContext.installTraceForTest() == [13,8]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    GpuMesh staleGpu;
    auto staleTool = new RadialArrayTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedParamForTest(staleLayer.meshRef(), true);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareParamChanged(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).accepted);
    staleTool.mutatePreparedParamForTest(180);
    assert(!staleContext.validate() && staleLayer.meshRef().faces.length == 6 &&
        staleTool.preparedParamStateForTest(false));

    auto wrongLayer = new Layer; wrongLayer.meshRef() = makeCube();
    auto wrongTool = new RadialArrayTool(() => &wrongLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    wrongTool.seedPreparedParamForTest(wrongLayer.meshRef(), true);
    GpuMesh foreignParamGpu;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11);
    assert(!wrongTool.prepareParamChanged(wrongContext, wrongLayer,
        GpuUploadOwner.fakeForTest(&foreignParamGpu)).accepted &&
        !wrongContext.validate() && wrongLayer.meshRef().faces.length == 6);

    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try activateTool.prepareActivate(producerFault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !producerFault.validate());
}
