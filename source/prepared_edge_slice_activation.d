module prepared_edge_slice_activation;

import core.atomic : atomicOp;
import tools.slice.edge_slice_tool : EdgeSliceTool, PreparedEdgeSliceActivationImage;

struct PreparedEdgeSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import editmode : EditMode;
    import mesh : GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    auto mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeSlice &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest(oldMesh));
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(oldMesh) &&
        context.installTraceForTest() == [30,8]);

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedEdgeSliceActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() &&
        tool.preparedActivationDirtyForTest(oldMesh) &&
        PreparedEdgeSliceActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest(oldMesh));
    auto wrong = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest(oldMesh);
    auto aborted = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest(oldMesh));
    assert(!tool.prepareActivate(null).accepted);
    assert(PreparedEdgeSliceActivationOwner.prepare(null) is null);
}
struct ValidatedEdgeSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeSliceActivationOwner;

final class PreparedEdgeSliceActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    EdgeSliceTool target_; PreparedEdgeSliceActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeSliceActivationToken prepared_;
    ValidatedEdgeSliceActivationToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeSliceActivationOwner prepare(EdgeSliceTool target) {
        if (target is null || target.classinfo !is EdgeSliceTool.classinfo) return null;
        auto result = new PreparedEdgeSliceActivationOwner(target);
        result.image_ = target.buildPreparedActivation(); return result;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is EdgeSliceTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_) return false;
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
    version(unittest) bool payloadEmpty() const nothrow @nogc { return !image_.valid; }
    version(unittest) static size_t abortCountForTest() nothrow @nogc { return abortCount_; }
    version(unittest) void corruptPreparedForTest() nothrow @nogc { ++prepared_.generation; }
private:
    this(EdgeSliceTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextEdgeSliceActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
