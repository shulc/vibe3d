module prepared_command_wrapper_activation;

import core.atomic : atomicOp;
import mesh : Mesh;
import tools.common.command_wrapper : CommandWrapperTool,
    PreparedCommandWrapperActivationImage, XfrmSmoothTool, XfrmJitterTool,
    XfrmQuantizeTool;
import tools.slice.edge_slide : EdgeSlideTool;

struct PreparedCommandWrapperActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedCommandWrapperActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextCommandWrapperActivationOwner;

final class PreparedCommandWrapperActivationOwner {
private:
    CommandWrapperTool target_;
    Mesh* source_;
    PreparedCommandWrapperActivationImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedCommandWrapperActivationToken prepared_;
    ValidatedCommandWrapperActivationToken validatedToken_;
public:
    @disable this();
    static PreparedCommandWrapperActivationOwner prepare(CommandWrapperTool target) {
        if (!exactProduct(target)) return null;
        auto result = new PreparedCommandWrapperActivationOwner(target);
        result.source_ = target.preparedActivationMesh();
        result.image_ = target.buildPreparedActivation();
        return result.source_ !is null && result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || !exactProduct(target_) ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedActivationMatches(source_, image_.baseline)) return false;
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
        if (consumed_) return; image_.clear(); consume();
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && image_.baseline.length == 0 &&
            image_.falloffs.length == 0 && image_.clickHandle is null;
    }
private:
    this(CommandWrapperTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextCommandWrapperActivationOwner, 1UL);
    }
    static bool exactProduct(CommandWrapperTool target) nothrow @nogc {
        return target !is null && (target.classinfo is XfrmSmoothTool.classinfo ||
            target.classinfo is XfrmJitterTool.classinfo ||
            target.classinfo is XfrmQuantizeTool.classinfo ||
            target.classinfo is EdgeSlideTool.classinfo);
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
    import record_observer_hub : RecordObserverHub;
    import view : View;

    auto mesh = makeCube(); GpuMesh gpu; View view;
    auto tool = new XfrmSmoothTool(&mesh, view, EditMode.Vertices, &gpu);
    auto oldHandle = tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && context.validate()); context.install();
    assert(tool.preparedActivationInstalledForTest(oldHandle) &&
        context.installTraceForTest() == [34, 8]);

    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    oldHandle = tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() &&
        !tool.preparedActivationInstalledForTest(oldHandle));
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.install(); assert(tool.preparedActivationInstalledForTest(oldHandle));

    auto corrupt = PreparedCommandWrapperActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedCommandWrapperActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());

    class ForeignWrapper : CommandWrapperTool {
        this(Mesh* source, GpuMesh* target) { meshPtr = source; gpu = target; }
        protected override void onDragDelta(int, int) {}
        protected override float handleSize() const { return 0; }
    }
    auto foreign = new ForeignWrapper(&mesh, &gpu);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!foreign.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted &&
        PreparedCommandWrapperActivationOwner.prepare(null) is null);
}
