module prepared_move_update;

import core.atomic : atomicOp;
import operator : VectorStack;
import tools.transform.move : MoveTool, PreparedMoveUpdateImage,
                              PreparedMoveUpdateBranch;

struct PreparedMoveUpdateToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedMoveUpdateToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextMoveUpdateOwner;

/// Closed owner for the exact MoveTool.update state projection. The detached
/// image remains private; only scalar tokens cross PreparedRecordContext.
final class PreparedMoveUpdateOwner {
private:
    MoveTool target_;
    PreparedMoveUpdateImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMoveUpdateToken prepared_;
    ValidatedMoveUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedMoveUpdateOwner prepare(MoveTool target, ref VectorStack vts) {
        if (target is null || target.classinfo !is MoveTool.classinfo) return null;
        auto result = new PreparedMoveUpdateOwner(target);
        result.image_ = target.buildPreparedMoveUpdate(vts);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is MoveTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_)
            return false;
        validated_ = true;
        validatedToken_.owner = owner_; validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedMoveUpdate(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
    version(unittest) PreparedMoveUpdateBranch branchForTest() const
            nothrow @nogc { return image_.branch; }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid;
    }
    version(unittest) void corruptPreparedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++prepared_.owner; else ++prepared_.generation;
    }
    version(unittest) void corruptValidatedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++validatedToken_.owner;
        else ++validatedToken_.generation;
    }
private:
    this(MoveTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextMoveUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import editmode : EditMode;
    import math : Vec3;
    import mesh : Mesh, GpuMesh, makeCube;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import toolpipe.packets : ActionCenterPacket;
    import tools.transform.rotate : RotateTool;
    import tools.transform.xfrm_transform : XfrmTransformTool;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto move = new MoveTool(() => &mesh, &gpu, &mode);
    VectorStack vts; ActionCenterPacket acen; acen.center = Vec3(7,8,9);
    vts.put(&acen);
    enum oldCached = Vec3(1,2,3); enum oldHandler = Vec3(4,5,6);

    // Every legacy branch is represented, including foreign-wrapper cast
    // failure (which refreshes rather than refusing).
    move.seedPreparedMoveUpdateForTest(false, -1, null, oldCached, oldHandler);
    auto inactive = PreparedMoveUpdateOwner.prepare(move, vts);
    assert(inactive !is null && inactive.branchForTest == PreparedMoveUpdateBranch.InactiveNoop);
    inactive.abort(); assert(move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    move.seedPreparedMoveUpdateForTest(true, 0, null, oldCached, oldHandler);
    auto dragging = PreparedMoveUpdateOwner.prepare(move, vts);
    assert(dragging !is null && dragging.branchForTest == PreparedMoveUpdateBranch.DraggingNoop);
    dragging.abort();

    auto foreign = new RotateTool(() => &mesh, &gpu, &mode);
    move.seedPreparedMoveUpdateForTest(true, -1, foreign, oldCached, oldHandler);
    auto castFailure = PreparedMoveUpdateOwner.prepare(move, vts);
    assert(castFailure !is null && castFailure.branchForTest == PreparedMoveUpdateBranch.Refresh);
    castFailure.abort();

    auto wrapper = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    wrapper.preparedMoveUpdateOpenForTest(true);
    move.seedPreparedMoveUpdateForTest(true, -1, wrapper, oldCached, oldHandler);
    auto open = PreparedMoveUpdateOwner.prepare(move, vts);
    assert(open !is null && open.branchForTest == PreparedMoveUpdateBranch.WrapperEditOpenNoop);
    open.abort();

    // Prepare captures the ACEN value and performs no live write. Later packet
    // mutation cannot alias the owner image.
    wrapper.preparedMoveUpdateOpenForTest(false);
    move.seedPreparedMoveUpdateForTest(true, -1, null, oldCached, oldHandler);
    auto owner = PreparedMoveUpdateOwner.prepare(move, vts);
    assert(owner !is null && owner.branchForTest == PreparedMoveUpdateBranch.Refresh &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    acen.center = Vec3(70,80,90);
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareMoveUpdate(owner) && context.markNoHistoryInstall() &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler) && context.validate());
    context.install(); context.install();
    assert(move.preparedMoveUpdateStateForTest(Vec3(7,8,9), Vec3(7,8,9)) &&
           owner.payloadEmpty && context.installTraceForTest == [16,8] && !owner.begin());

    // Failure after begin is terminal, scrubs payload, leaves live state intact,
    // and permits a fresh owner/context retry.
    move.seedPreparedMoveUpdateForTest(true, -1, null, oldCached, oldHandler);
    auto faultOwner = PreparedMoveUpdateOwner.prepare(move, vts);
    auto fault = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try fault.prepareMoveUpdate(faultOwner); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.payloadEmpty && !faultOwner.begin() &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    fault.discard();
    auto retryOwner = PreparedMoveUpdateOwner.prepare(move, vts);
    auto retry = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(retry.prepareMoveUpdate(retryOwner) && retry.markNoHistoryInstall() && retry.validate());
    retry.discard();
    assert(retryOwner.payloadEmpty && move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    // Both scalar identity terms are load-bearing before and after validation.
    foreach (ownerIdentity; [false, true]) {
        auto wrongPrepared = PreparedMoveUpdateOwner.prepare(move, vts);
        assert(wrongPrepared.begin());
        wrongPrepared.corruptPreparedForTest(ownerIdentity);
        assert(!wrongPrepared.validate()); wrongPrepared.abort();
        assert(wrongPrepared.payloadEmpty &&
               move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

        auto wrongValidated = PreparedMoveUpdateOwner.prepare(move, vts);
        assert(wrongValidated.begin() && wrongValidated.validate());
        wrongValidated.corruptValidatedForTest(ownerIdentity);
        wrongValidated.install();
        assert(!wrongValidated.payloadEmpty &&
               move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
        wrongValidated.abort(); assert(wrongValidated.payloadEmpty);
    }

    // Exact class admission refuses behaviorful derived products.
    class DerivedMove : MoveTool {
        this(Mesh* delegate() source, GpuMesh* gpu_, EditMode* mode_) {
            super(source, gpu_, mode_);
        }
    }
    assert(PreparedMoveUpdateOwner.prepare(
        new DerivedMove(() => &mesh, &gpu, &mode), vts) is null);
}
