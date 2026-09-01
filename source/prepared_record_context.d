module prepared_record_context;

// P1.0b.3d dormant producer context. Production activation doors do not import
// or construct this until the single P1.0c unified cutover.
import command : Command;
import command_history : CommandHistory, PreparedHistoryKind,
                         PreparedHistoryResult, PreparedHistoryToken,
                         ValidatedPreparedHistoryToken;
import record_observer_hub : RecordObserverHub;
import mesh : Mesh;
import mesh_gpu : GpuResourceOwner, GpuUploadOwner;
import handler : ClickPointResourceOwner;

private enum PreparedResourceKind : ubyte {
    HistoryInstall, GpuMeshDestroy, GpuUpload, ClickPointDestroy
}
private struct PreparedResourceEntry {
    PreparedResourceKind kind;
    GpuResourceOwner gpuDestroy;
    GpuUploadOwner gpuUpload;
    ClickPointResourceOwner clickDestroy;
}

/// One fallible prepare transaction jointly owns the detached history and
/// observer evolution. Tool producers receive this owner; they never discover
/// a global history, observer, or legacy delegate.
final class PreparedRecordContext {
private:
    CommandHistory history_;
    RecordObserverHub observers_;
    PreparedHistoryToken token_;
    ValidatedPreparedHistoryToken validated_;
    bool begun_, validated_Once;
    PreparedResourceEntry[] resources_;
    ulong resourceThread_, resourceContext_;
    bool historyMarker_;
    version (unittest) {
        static bool failAfterResourceBegin_;
        ubyte[16] installTrace_;
        size_t installTraceLength_;
    }
public:
    this(CommandHistory history, RecordObserverHub observers) {
        history_ = history;
        observers_ = observers;
        if (history_ !is null) {
            token_ = history_.beginPrepared();
            begun_ = true;
        }
    }

    void setResourceIdentity(ulong threadIdentity, ulong contextIdentity)
                             nothrow @nogc {
        resourceThread_ = threadIdentity;
        resourceContext_ = contextIdentity;
    }

    /// Append the exact history position among resource effects. Resource
    /// transactions require exactly one marker; history-only transactions keep
    /// their historical direct install path.
    bool markHistoryInstall() {
        if (!begun_ || validated_Once || historyMarker_) return false;
        resources_.reserve(resources_.length + 1);
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.HistoryInstall;
        resources_ ~= e;
        historyMarker_ = true;
        return true;
    }

    bool prepareDestroy(GpuResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        resources_ ~= PreparedResourceEntry(
            PreparedResourceKind.GpuMeshDestroy, owner);
        return true;
    }

    bool prepareUpload(GpuUploadOwner owner, ref const Mesh mesh,
                       const uint[] edgeOrigin = null,
                       const uint[] vertOrigin = null,
                       const uint[] faceOrigin = null) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedUpload(mesh, edgeOrigin, vertOrigin,
                                       faceOrigin)) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.GpuUpload; e.gpuUpload = owner;
        resources_ ~= e;
        return true;
    }

    bool prepareDestroy(ClickPointResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.ClickPointDestroy;
        e.clickDestroy = owner;
        resources_ ~= e;
        return true;
    }

    PreparedHistoryResult prepare(Command cmd, PreparedHistoryKind kind,
                                  ulong runId = 0,
                                  string preparedTraceJson = null) {
        if (!begun_ || validated_Once) return PreparedHistoryResult.init;
        return history_.prepareRecord(token_, cmd, kind, runId,
                                      observers_, preparedTraceJson);
    }

    PreparedHistoryResult consolidate(ulong runId) {
        if (!begun_ || validated_Once) return PreparedHistoryResult.init;
        return history_.prepareConsolidate(token_, runId);
    }

    ulong nextRun() {
        if (!begun_ || validated_Once) return 0;
        return history_.prepareNextRun(token_);
    }

    bool validate() nothrow @nogc {
        if (!begun_ || validated_Once) return false;
        if (resources_.length > 0 && !historyMarker_) {
            invalidateTransaction();
            return false;
        }
        foreach (ref e; resources_) {
            bool ok;
            final switch (e.kind) {
            case PreparedResourceKind.HistoryInstall: ok = true; break;
            case PreparedResourceKind.GpuMeshDestroy:
                ok = e.gpuDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.GpuUpload:
                ok = e.gpuUpload.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.ClickPointDestroy:
                ok = e.clickDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            }
            if (!ok) { invalidateTransaction(); return false; }
        }
        validated_ = history_.validatesPreparedToken(token_, observers_);
        validated_Once = validated_.valid;
        if (!validated_Once) invalidateTransaction();
        return validated_Once;
    }

    void install() nothrow @nogc {
        if (!validated_Once) return;
        bool installedHistory;
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall:
            history_.installPreparedToken(validated_); installedHistory = true;
            version (unittest) installTrace_[installTraceLength_++] = 1;
            break;
        case PreparedResourceKind.GpuMeshDestroy:
            e.gpuDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.GpuUpload:
            e.gpuUpload.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.ClickPointDestroy:
            e.clickDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        }
        if (!installedHistory) history_.installPreparedToken(validated_);
        resources_.length = 0;
        historyMarker_ = false;
        validated_Once = false;
        begun_ = false;
    }

    void discard() nothrow @nogc {
        if (!begun_ || validated_Once) return;
        history_.discardPreparedToken(token_);
        abortResources();
        begun_ = false;
    }

private:
    void abortResources() nothrow @nogc {
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall: break;
        case PreparedResourceKind.GpuMeshDestroy: e.gpuDestroy.abortEnlisted(); break;
        case PreparedResourceKind.GpuUpload: e.gpuUpload.abortEnlisted(); break;
        case PreparedResourceKind.ClickPointDestroy: e.clickDestroy.abortEnlisted(); break;
        }
        resources_.length = 0;
        historyMarker_ = false;
    }

    void invalidateTransaction() nothrow @nogc {
        abortResources();
        if (begun_ && !validated_Once) history_.discardPreparedToken(token_);
        begun_ = false;
        validated_Once = false;
    }
public:

    void installedDepths(out size_t modelDepth, out size_t uiDepth) const {
        modelDepth = 0; uiDepth = 0;
        if (history_ !is null) history_.undoDepthCounts(modelDepth, uiDepth);
    }
    version (unittest) const(ubyte)[] installTraceForTest() const nothrow @nogc {
        return installTrace_[0 .. installTraceLength_];
    }
}

unittest {
    import command : Command, CmdFlags;
    import mesh : Mesh;
    import view : View;
    import editmode : EditMode;
    final class C : Command {
        private Mesh mesh_;
        private View view_ = new View(0, 0, 1, 1);
        this() { super(&mesh_, view_, EditMode.Vertices); }
        override string name() const { return "prepared.context.test"; }
        override string label() const { return "prepared context"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto context = new PreparedRecordContext(history, hub);
    auto result = context.prepare(new C(), PreparedHistoryKind.Plain);
    size_t models, ui;
    history.undoDepthCounts(models, ui);
    assert(result.accepted && models == 0 && hub.macroLength == 0);
    assert(context.validate());
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
}

version (unittest) unittest {
    import mesh : GpuMesh;
    import handler : ClickPointHandler, ClickPointResourceOwner;
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();

    // Resource then history (Box/Primitive ordering).
    auto firstHandle = new ClickPointHandler();
    auto firstOwner = new ClickPointResourceOwner(firstHandle, 7, 11);
    auto first = new PreparedRecordContext(history, hub);
    first.setResourceIdentity(7, 11);
    assert(first.prepareDestroy(firstOwner));
    assert(first.markHistoryInstall());
    assert(first.validate());
    first.install();
    assert(first.installTrace_[0 .. first.installTraceLength_] == [2, 1]);

    // History then resource (CommandWrapper ordering).
    auto secondHandle = new ClickPointHandler();
    auto secondOwner = new ClickPointResourceOwner(secondHandle, 7, 11);
    auto second = new PreparedRecordContext(history, hub);
    second.setResourceIdentity(7, 11);
    assert(second.markHistoryInstall());
    assert(second.prepareDestroy(secondOwner));
    assert(second.validate());
    second.install();
    assert(second.installTrace_[0 .. second.installTraceLength_] == [1, 2]);

    // Allocation/post-begin failure cannot strand an owner; discard and a
    // fresh transaction can immediately enlist the same owner.
    GpuMesh faultGpu;
    auto faultOwner = new GpuResourceOwner(&faultGpu, 7, 11);
    auto fault = new PreparedRecordContext(history, hub);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    bool threw;
    try fault.prepareDestroy(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw);
    fault.discard();
    auto retry = new PreparedRecordContext(history, hub);
    retry.setResourceIdentity(7, 11);
    assert(retry.prepareDestroy(faultOwner));
    assert(retry.markHistoryInstall());
    retry.discard();

    // A joint-validation refusal is terminal: even correcting the identity
    // cannot revive or partially install the discarded transaction.
    GpuMesh refusedGpu;
    auto refusedOwner = new GpuResourceOwner(&refusedGpu, 7, 11);
    auto refused = new PreparedRecordContext(history, hub);
    refused.setResourceIdentity(8, 11);
    assert(refused.prepareDestroy(refusedOwner));
    assert(refused.markHistoryInstall());
    assert(!refused.validate());
    refused.setResourceIdentity(7, 11);
    assert(!refused.validate());
    refused.install();
    auto afterRefusal = new PreparedRecordContext(history, hub);
    afterRefusal.setResourceIdentity(7, 11);
    assert(afterRefusal.prepareDestroy(refusedOwner));
    afterRefusal.discard();
}
