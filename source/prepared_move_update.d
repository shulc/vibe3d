module prepared_move_update;

import core.atomic : atomicOp;
import math : Vec3;
import tools.transform.move : MoveTool, PreparedMoveUpdateImage,
                              PreparedMoveUpdateBranch;
import prepared_tool_effect : PreparedMoveUpdateKind;

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
    version(unittest) static size_t abortCount_;
    MoveTool target_;
    PreparedMoveUpdateImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMoveUpdateToken prepared_;
    ValidatedMoveUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedMoveUpdateOwner prepare(MoveTool target,
            bool ownerEditOpen, Vec3 actionCenter) {
        if (target is null || target.classinfo !is MoveTool.classinfo) return null;
        auto result = new PreparedMoveUpdateOwner(target);
        result.image_ = target.buildPreparedMoveUpdate(
            ownerEditOpen, actionCenter);
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
        if (!consumed_) {
            version(unittest) ++abortCount_;
            image_.clear(); consume();
        }
    }
    PreparedMoveUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedMoveUpdateKind.None;
        final switch (image_.branch) {
        case PreparedMoveUpdateBranch.InactiveNoop:
            return PreparedMoveUpdateKind.InactiveNoop;
        case PreparedMoveUpdateBranch.DraggingNoop:
            return PreparedMoveUpdateKind.DraggingNoop;
        case PreparedMoveUpdateBranch.WrapperEditOpenNoop:
            return PreparedMoveUpdateKind.WrapperEditOpenNoop;
        case PreparedMoveUpdateBranch.Refresh:
            return PreparedMoveUpdateKind.Refresh;
        }
    }
    version(unittest) PreparedMoveUpdateBranch branchForTest() const
            nothrow @nogc { return image_.branch; }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
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

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto move = new MoveTool(() => &mesh, &gpu, &mode);
    enum oldCached = Vec3(1,2,3); enum oldHandler = Vec3(4,5,6);

    // Every input branch is represented. Edit ownership and the action-center
    // pose arrive as explicit values from the wrapper.
    move.seedPreparedMoveUpdateForTest(false, -1, oldCached, oldHandler);
    auto inactive = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
    assert(inactive !is null && inactive.branchForTest == PreparedMoveUpdateBranch.InactiveNoop);
    inactive.abort(); assert(move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    move.seedPreparedMoveUpdateForTest(true, 0, oldCached, oldHandler);
    auto dragging = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
    assert(dragging !is null && dragging.branchForTest == PreparedMoveUpdateBranch.DraggingNoop);
    dragging.abort();

    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto open = PreparedMoveUpdateOwner.prepare(move, true, Vec3(7,8,9));
    assert(open !is null && open.branchForTest == PreparedMoveUpdateBranch.WrapperEditOpenNoop);
    open.abort();

    // Prepare captures the ACEN value and performs no live write. Later packet
    // mutation cannot alias the owner image.
    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto owner = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
    assert(owner !is null && owner.branchForTest == PreparedMoveUpdateBranch.Refresh &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareMoveUpdate(owner) && context.markNoHistoryInstall() &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler) && context.validate());
    context.install(); context.install();
    assert(move.preparedMoveUpdateStateForTest(Vec3(7,8,9), Vec3(7,8,9)) &&
           owner.payloadEmpty && context.installTraceForTest == [16,8] && !owner.begin());

    // Failure after begin is terminal, scrubs payload, leaves live state intact,
    // and permits a fresh owner/context retry.
    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto faultOwner = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
    auto fault = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); bool threw;
    try fault.prepareMoveUpdate(faultOwner); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.payloadEmpty && !faultOwner.begin() &&
           move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    fault.discard();
    auto retryOwner = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
    auto retry = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(retry.prepareMoveUpdate(retryOwner) && retry.markNoHistoryInstall() && retry.validate());
    retry.discard();
    assert(retryOwner.payloadEmpty && move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    // Both scalar identity terms are load-bearing before and after validation.
    foreach (ownerIdentity; [false, true]) {
        auto wrongPrepared = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
        assert(wrongPrepared.begin());
        wrongPrepared.corruptPreparedForTest(ownerIdentity);
        assert(!wrongPrepared.validate()); wrongPrepared.abort();
        assert(wrongPrepared.payloadEmpty &&
               move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

        auto wrongValidated = PreparedMoveUpdateOwner.prepare(move, false, Vec3(7,8,9));
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
    auto derived = new DerivedMove(() => &mesh, &gpu, &mode);
    assert(PreparedMoveUpdateOwner.prepare(derived, false, Vec3(7,8,9)) is null);

    // Dormant producer: every branch is accepted without a prepare-time live
    // write and installs in MoveUpdate -> NoHistory order.
    move.seedPreparedMoveUpdateForTest(false, -1, oldCached, oldHandler);
    auto inactiveContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto inactiveEffect = move.prepareUpdate(false, Vec3(7,8,9), inactiveContext);
    assert(inactiveEffect.accepted &&
        inactiveEffect.kind == PreparedMoveUpdateKind.InactiveNoop &&
        inactiveEffect.owner == move.preparedOwnerForTest() &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler) &&
        inactiveContext.validate());
    inactiveContext.install(); inactiveContext.install();
    assert(inactiveContext.installTraceForTest == [16,8] &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    move.seedPreparedMoveUpdateForTest(true, 2, oldCached, oldHandler);
    auto dragContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto dragEffect = move.prepareUpdate(false, Vec3(7,8,9), dragContext);
    assert(dragEffect.accepted &&
        dragEffect.kind == PreparedMoveUpdateKind.DraggingNoop &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler) &&
        dragContext.validate());
    dragContext.install(); dragContext.install();
    assert(dragContext.installTraceForTest == [16,8] &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler));

    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto openContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto openEffect = move.prepareUpdate(true, Vec3(7,8,9), openContext);
    assert(openEffect.accepted &&
        openEffect.kind == PreparedMoveUpdateKind.WrapperEditOpenNoop &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler) &&
        openContext.validate());
    openContext.install(); openContext.install();
    assert(openContext.installTraceForTest == [16,8] &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto refreshContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refreshEffect = move.prepareUpdate(false, Vec3(17,18,19), refreshContext);
    assert(refreshEffect.accepted && refreshEffect.kind == PreparedMoveUpdateKind.Refresh &&
        refreshEffect.owner == move.preparedOwnerForTest() &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler) &&
        refreshContext.validate());
    refreshContext.install(); refreshContext.install();
    assert(refreshContext.installTraceForTest == [16,8] &&
        move.preparedMoveUpdateStateForTest(Vec3(17,18,19), Vec3(17,18,19)));

    // Null and exact-class refusal are terminal and carry no accepted effect.
    auto nullEffect = move.prepareUpdate(false, Vec3(0,0,0), null);
    assert(!nullEffect.accepted && nullEffect.kind == PreparedMoveUpdateKind.None &&
        nullEffect.owner == move.preparedOwnerForTest());
    auto refusedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto refused = derived.prepareUpdate(false, Vec3(0,0,0), refusedContext);
    assert(!refused.accepted && refused.kind == PreparedMoveUpdateKind.None &&
        refused.owner == derived.preparedOwnerForTest() &&
        refusedContext.resourceCountForTest == 0);

    // A throw after owner begin triggers function-wide context cleanup, scrubs
    // the owner, leaves live state unchanged, and a fresh retry succeeds.
    move.seedPreparedMoveUpdateForTest(true, -1, oldCached, oldHandler);
    auto producerAborts = PreparedMoveUpdateOwner.abortCountForTest();
    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true); threw = false;
    try move.prepareUpdate(false, Vec3(27,28,29), producerFault);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && producerFault.resourceCountForTest == 0 &&
        PreparedMoveUpdateOwner.abortCountForTest() == producerAborts + 1 &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
    auto producerRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto retryEffect = move.prepareUpdate(false, Vec3(27,28,29), producerRetry);
    assert(retryEffect.accepted && retryEffect.kind == PreparedMoveUpdateKind.Refresh &&
        move.preparedMoveUpdateStateForTest(oldCached, oldHandler) &&
        producerRetry.validate());
    producerRetry.discard();
    assert(move.preparedMoveUpdateStateForTest(oldCached, oldHandler));
}
