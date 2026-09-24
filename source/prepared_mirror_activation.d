module prepared_mirror_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.alignment.mirror : MirrorTool, PreparedMirrorActivationImage,
    PreparedMirrorDeactivateImage;

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

struct PreparedMirrorDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedMirrorDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextMirrorDeactivateOwner;

final class PreparedMirrorDeactivateOwner {
private:
    MirrorTool target_;
    PreparedMirrorDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMirrorDeactivateToken prepared_;
    ValidatedMirrorDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedMirrorDeactivateOwner prepare(MirrorTool target) {
        if (target is null || target.classinfo !is MirrorTool.classinfo) return null;
        auto result = new PreparedMirrorDeactivateOwner(target);
        result.image_ = target.buildPreparedDeactivateState();
        return result.image_.valid ? result : null;
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
            !target_.preparedDeactivateStateMatches(image_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivateState(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null;
    }
private:
    this(MirrorTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextMirrorDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false;
        consumed_ = true; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import document : Layer;
    import math : Vec3, ModelSpace;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind, PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import snapshot : MeshSnapshot;
    import tools.alignment.mirror : MirrorParams, mirrorInPlace;

    PreparedRecordContext freshContext(CommandHistory h = null) {
        auto c = new PreparedRecordContext(h is null ? new CommandHistory() : h,
            new RecordObserverHub());
        c.setResourceIdentity(7,11); return c;
    }

    // Activation: baseline + mask + params only (no preview mesh, no
    // upload; nothing is evaluated before the first press).
    auto mesh = makeCube();
    mesh.syncSelection(); mesh.selectFace(0);
    GpuMesh gpu;
    auto tool = new MirrorTool(() => &mesh, &gpu, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto context = freshContext();
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Mirror);
    assert(mesh.faces.length == 6, "prepare must not mutate the live mesh");
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest() &&
        tool.preparedMaskSelectedForTest() == 1 &&
        context.installTraceForTest() == [36,8] && mesh.faces.length == 6);

    auto allMesh = makeCube(); allMesh.syncSelection();
    auto allTool = new MirrorTool(() => &allMesh, &gpu, LitShader.init);
    auto allContext = freshContext();
    assert(allTool.prepareActivate(allContext).accepted && allContext.validate());
    allContext.install();
    assert(allTool.preparedMaskSelectedForTest() == allMesh.faces.length);

    auto changed = freshContext();
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new MirrorTool(() => selected, &gpu, LitShader.init);
    auto switched = freshContext();
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto paramChanged = freshContext();
    assert(tool.prepareActivate(paramChanged).accepted);
    tool.setPreparedAxisForTest(1);
    assert(!paramChanged.validate()); paramChanged.discard();
    tool.setPreparedAxisForTest(0);

    auto fault = freshContext(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate());
    auto retry = freshContext();
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard();

    auto corrupt = PreparedMirrorActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedMirrorActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    assert(!tool.prepareActivate(null).accepted &&
        PreparedMirrorActivationOwner.prepare(null) is null);

    tool.seedPreparedDeactivateStateForTest();
    auto deactivateContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto deactivateOwner = PreparedMirrorDeactivateOwner.prepare(tool);
    assert(deactivateContext.prepareMirrorDeactivate(deactivateOwner) &&
        deactivateContext.markNoHistoryInstall() && deactivateContext.validate());
    deactivateContext.install(); deactivateContext.install();
    assert(tool.preparedDeactivateStateInstalledForTest() &&
        deactivateContext.installTraceForTest() == [40,8]);
    tool.seedPreparedDeactivateStateForTest();
    auto changedDeactivate = PreparedMirrorDeactivateOwner.prepare(tool);
    assert(changedDeactivate.begin()); tool.installPreparedDeactivateStateForTest();
    assert(!changedDeactivate.validate()); changedDeactivate.abort();
    tool.seedPreparedDeactivateStateForTest();
    auto corruptDeactivate = PreparedMirrorDeactivateOwner.prepare(tool);
    assert(corruptDeactivate.begin()); corruptDeactivate.corruptPreparedForTest();
    assert(!corruptDeactivate.validate()); corruptDeactivate.abort();
    assert(corruptDeactivate.payloadEmpty() &&
        PreparedMirrorDeactivateOwner.prepare(null) is null);

    // The drop commits what the live edit already wrote: the prepared door
    // does not mirror a second time (a second mirror of the 12-face live
    // mesh would leave 24).
    auto commitSource = makeCube();
    MirrorParams plane; plane.center = Vec3(1.5f, 0, 0); plane.mergeVerts = false;
    void writeLiveCopy(Layer l) {
        auto whole = l.meshRef().operandFaceMask();
        assert(mirrorInPlace(l.meshRef(), whole, plane, ModelSpace.world()) > 0);
    }
    auto commitLayer = new Layer;
    MeshSnapshot.capture(commitSource).restore(commitLayer.meshRef());
    GpuMesh commitGpu;
    auto commitTool = new MirrorTool(() => &commitLayer.meshRef(), &commitGpu,
        LitShader.init);
    commitTool.seedLiveEditForTest(); writeLiveCopy(commitLayer);
    auto commitContext = freshContext();
    auto commitEffect = commitTool.prepareDeactivate(commitContext, commitLayer);
    assert(commitEffect.resourceAccepted && !commitEffect.historyAccepted &&
        commitEffect.kind == PreparedDeactivateKind.Mirror &&
        commitLayer.meshRef().faces.length == 12);
    assert(commitContext.validate()); commitContext.install();
    assert(commitLayer.meshRef().faces.length == 12 &&
        commitTool.preparedDeactivateStateInstalledForTest() &&
        commitContext.installTraceForTest() == [8,40]);

    auto idleLayer = new Layer;
    MeshSnapshot.capture(commitSource).restore(idleLayer.meshRef());
    GpuMesh idleGpu;
    auto idleTool = new MirrorTool(() => &idleLayer.meshRef(), &idleGpu,
        LitShader.init);
    auto idleContext = freshContext();
    auto idleEffect = idleTool.prepareDeactivate(idleContext, idleLayer);
    assert(idleEffect.resourceAccepted && !idleEffect.historyAccepted &&
        idleContext.validate()); idleContext.install();
    assert(idleLayer.meshRef().faces.length == 6 &&
        idleContext.installTraceForTest() == [8,40]);

    import commands.mesh.session_edit : MeshSessionEdit;
    import editmode : EditMode;
    import view : View;
    auto historyLayer = new Layer;
    MeshSnapshot.capture(commitSource).restore(historyLayer.meshRef());
    GpuMesh historyGpu;
    auto historyTool = new MirrorTool(() => &historyLayer.meshRef(), &historyGpu,
        LitShader.init);
    historyTool.seedLiveEditForTest(); writeLiveCopy(historyLayer);
    auto history = new CommandHistory(); auto historyView = new View(0,0,1,1);
    historyTool.setGestureBindings(history, () => new MeshSessionEdit(
        &historyLayer.meshRef(), historyView, EditMode.Polygons,
        "test.mirror", "Mirror"));
    auto historyContext = freshContext(history);
    auto historyEffect = historyTool.prepareDeactivate(historyContext,
        historyLayer);
    assert(historyEffect.resourceAccepted && historyEffect.historyAccepted &&
        historyLayer.meshRef().faces.length == 12 && historyContext.validate());
    historyContext.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(historyLayer.meshRef().faces.length == 12 && modelDepth == 1 &&
        uiDepth == 0 && historyContext.installTraceForTest() == [1,40]);
    // The record's pre-image is the BASE (6 faces), not the live mesh.
    history.undo();
    assert(historyLayer.meshRef().faces.length == 6,
        "the mirror record's pre-image is not the base snapshot");
}
