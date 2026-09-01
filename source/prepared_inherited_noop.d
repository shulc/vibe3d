module prepared_inherited_noop;

import core.atomic : atomicOp;
import tool : Tool;
import tools.edit.drag_weld : DragWeldTool;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedInheritedNoopEffect,
                              PreparedInheritedNoopKind, OwnedId;

struct PreparedInheritedNoopToken {
    @disable this(this);
private:
    ulong owner, generation;
}

/// Dormant Prepared+Legacy producer for the two inherited base lifecycle
/// roots.  No production door calls this before the unified cutover.
PreparedInheritedNoopEffect prepareInheritedNoop(
        Tool target, PreparedInheritedNoopKind kind,
        PreparedRecordContext context) {
    auto exactTarget = target !is null &&
        target.classinfo is DragWeldTool.classinfo
        ? cast(DragWeldTool) target : null;
    auto targetOwner = exactTarget is null ? OwnedId.init
                                           : exactTarget.preparedInheritedOwner;
    if (context is null)
        return PreparedInheritedNoopEffect(targetOwner, kind, false);
    scope(failure) context.discard();
    auto owner = PreparedInheritedNoopOwner.prepare(target, kind);
    const bool accepted = owner !is null &&
        context.prepareInheritedNoop(owner) && context.markNoHistoryInstall();
    if (!accepted) context.discard();
    return PreparedInheritedNoopEffect(targetOwner, kind, accepted);
}

struct ValidatedInheritedNoopToken {
    @disable this(this);
private:
    ulong owner, generation;
}

private shared ulong nextInheritedNoopOwner;

/// Closed owner for the two base Tool no-op hooks whose sole effective
/// factory product is exact DragWeldTool.  Install intentionally mutates no
/// live state; consuming the validated token is the complete effect.
final class PreparedInheritedNoopOwner {
private:
    Tool target_;
    PreparedInheritedNoopKind kind_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedInheritedNoopToken prepared_;
    ValidatedInheritedNoopToken validatedToken_;
public:
    @disable this();

    static PreparedInheritedNoopOwner prepare(
            Tool target, PreparedInheritedNoopKind kind) {
        if (target is null || target.classinfo !is DragWeldTool.classinfo)
            return null;
        return new PreparedInheritedNoopOwner(target, kind);
    }

    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_;
        pending_ = true;
        prepared_.owner = owner_;
        prepared_.generation = generation_;
        return true;
    }

    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is DragWeldTool.classinfo ||
            prepared_.owner != owner_ ||
            prepared_.generation != generation_) return false;
        validated_ = true;
        validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }

    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        consume();
    }

    void abort() nothrow @nogc {
        if (!consumed_) consume();
    }

    PreparedInheritedNoopKind kind() const nothrow @nogc { return kind_; }
    version(unittest) bool consumedForTest() const nothrow @nogc {
        return consumed_ && target_ is null;
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
    this(Tool target, PreparedInheritedNoopKind kind) {
        target_ = target;
        kind_ = kind;
        owner_ = atomicOp!"+="(nextInheritedNoopOwner, 1UL);
    }

    void consume() nothrow @nogc {
        pending_ = validated_ = false;
        consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import mesh : Mesh, GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import tools.create.arc : ArcTool;

    Mesh mesh;
    GpuMesh gpu;
    auto target = new DragWeldTool(() => &mesh, &gpu, LitShader.init);

    foreach (kind; [PreparedInheritedNoopKind.Activate,
                    PreparedInheritedNoopKind.Deactivate]) {
        auto owner = PreparedInheritedNoopOwner.prepare(target, kind);
        auto context = new PreparedRecordContext(new CommandHistory(),
                                                  new RecordObserverHub());
        assert(owner !is null && owner.kind == kind &&
            context.prepareInheritedNoop(owner) &&
            context.markNoHistoryInstall() && context.validate());
        context.install();
        context.install();
        assert(owner.consumedForTest &&
               context.installTraceForTest == [17, 8]);
    }

    // A different factory product may also inherit Tool.update, but it is not
    // admitted for the two lifecycle kinds owned by this tranche.
    assert(PreparedInheritedNoopOwner.prepare(
        new ArcTool(() => &mesh, &gpu, LitShader.init),
        PreparedInheritedNoopKind.Activate) is null);

    foreach (ownerIdentity; [false, true]) {
        auto wrong = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Activate);
        assert(wrong.begin());
        wrong.corruptPreparedForTest(ownerIdentity);
        assert(!wrong.validate());
        wrong.abort();
        assert(wrong.consumedForTest);

        auto validated = PreparedInheritedNoopOwner.prepare(
            target, PreparedInheritedNoopKind.Deactivate);
        assert(validated.begin() && validated.validate());
        validated.corruptValidatedForTest(ownerIdentity);
        validated.install();
        assert(!validated.consumedForTest);
        validated.abort();
        assert(validated.consumedForTest);
    }

    auto aborted = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Activate);
    assert(aborted.begin());
    aborted.abort();
    assert(aborted.consumedForTest && !aborted.begin());

    // A throw after begin is terminal for this owner and leaves no journal
    // entry.  Discard makes the old context inert; a fresh pair can retry.
    auto faultOwner = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Deactivate);
    auto fault = new PreparedRecordContext(new CommandHistory(),
                                            new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    bool threw;
    try fault.prepareInheritedNoop(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && faultOwner.consumedForTest &&
           fault.resourceCountForTest == 0);
    fault.discard();
    assert(!fault.validate());

    auto retryOwner = PreparedInheritedNoopOwner.prepare(
        target, PreparedInheritedNoopKind.Deactivate);
    auto retry = new PreparedRecordContext(new CommandHistory(),
                                            new RecordObserverHub());
    assert(retry.prepareInheritedNoop(retryOwner) &&
           retry.markNoHistoryInstall() && retry.validate());
    retry.discard();
    assert(retryOwner.consumedForTest && !retry.validate());

    // Dormant producer preserves zero-live/no-history behavior for both exact
    // effective roots and never validates or installs early.
    foreach (kind; [PreparedInheritedNoopKind.Activate,
                    PreparedInheritedNoopKind.Deactivate]) {
        auto producerContext = new PreparedRecordContext(new CommandHistory(),
            new RecordObserverHub());
        auto effect = prepareInheritedNoop(target, kind, producerContext);
        assert(effect.accepted && effect.kind == kind &&
               effect.owner == target.preparedInheritedOwner);
        assert(producerContext.validate());
        producerContext.install();
        producerContext.install();
        assert(producerContext.installTraceForTest == [17,8]);
    }
    auto foreignContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto foreignEffect = prepareInheritedNoop(
        new ArcTool(() => &mesh, &gpu, LitShader.init),
        PreparedInheritedNoopKind.Activate, foreignContext);
    assert(!foreignEffect.accepted && foreignEffect.owner == OwnedId.init &&
           foreignEffect.kind == PreparedInheritedNoopKind.Activate &&
           !foreignContext.validate());
    auto nullEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Deactivate, null);
    assert(!nullEffect.accepted && nullEffect.owner == target.preparedInheritedOwner &&
           nullEffect.kind == PreparedInheritedNoopKind.Deactivate);

    auto producerFault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    threw = false;
    try prepareInheritedNoop(target, PreparedInheritedNoopKind.Activate,
                             producerFault);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && producerFault.resourceCountForTest == 0);
    producerFault.discard();
    assert(!producerFault.validate());

    auto producerRetry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto retryEffect = prepareInheritedNoop(target,
        PreparedInheritedNoopKind.Activate, producerRetry);
    assert(retryEffect.accepted &&
           retryEffect.owner == target.preparedInheritedOwner &&
           retryEffect.kind == PreparedInheritedNoopKind.Activate &&
           producerRetry.validate());
    producerRetry.install();
    producerRetry.install();
    assert(producerRetry.installTraceForTest == [17,8]);
}
