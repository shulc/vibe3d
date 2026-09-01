module prepared_loop_slice_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.slice.loop_slice_tool : LoopSliceTool, PreparedLoopSliceActivationImage;

struct PreparedLoopSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedLoopSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextLoopSliceActivationOwner;

final class PreparedLoopSliceActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    LoopSliceTool target_; Mesh* source_;
    PreparedLoopSliceActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedLoopSliceActivationToken prepared_;
    ValidatedLoopSliceActivationToken validatedToken_;
public:
    @disable this();
    static PreparedLoopSliceActivationOwner prepare(LoopSliceTool target) {
        if (target is null || target.classinfo !is LoopSliceTool.classinfo) return null;
        auto result = new PreparedLoopSliceActivationOwner(target);
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
            target_.classinfo !is LoopSliceTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !image_.before.matches(*source_)) return false;
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
    void abort() nothrow @nogc {
        if (consumed_) return; version(unittest) ++abortCount_;
        image_.clear(); consume();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled && image_.positions.length == 0;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
private:
    this(LoopSliceTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextLoopSliceActivationOwner, 1UL);
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
    import mesh : GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.LoopSlice &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest() && context.installTraceForTest() == [31,8]);

    auto freeTool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    freeTool.seedPreparedActivationFreeForTest();
    auto freeContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(freeTool.prepareActivate(freeContext).accepted && freeContext.validate());
    freeContext.install(); assert(freeTool.preparedActivationFreeForTest());

    auto boundaryTool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    boundaryTool.seedPreparedActivationBoundaryForTest();
    auto boundaryContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(boundaryTool.prepareActivate(boundaryContext).accepted &&
        boundaryContext.validate());
    boundaryContext.install();
    assert(boundaryTool.preparedActivationBoundaryForTest());

    tool.seedPreparedActivationForTest();
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new LoopSliceTool(() => selected, &gpu, &mode, LitShader.init);
    switching.seedPreparedActivationForTest();
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedLoopSliceActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedLoopSliceActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest();
    auto aborted = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest());
    auto missing = new LoopSliceTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted &&
        !missingContext.validate() && !tool.prepareActivate(null).accepted);
}
