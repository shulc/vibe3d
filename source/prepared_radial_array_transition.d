module prepared_radial_array_transition;

import mesh : Mesh;
import tools.alignment.radial_array_tool : RadialArrayTool,
    RadialArrayTransitionImage, PreparedRadialArrayTransitionKind;
import core.atomic : atomicOp;

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
    @property PreparedRadialArrayTransitionKind kind() const nothrow @nogc {
        return image_.kind;
    }
    bool owns(RadialArrayTool target) const nothrow @nogc { return target_ is target; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            prepared_.owner != owner_ || prepared_.generation != generation_) return false;
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
}
