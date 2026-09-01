module prepared_record_context;

// P1.0b.3d dormant producer context. Production activation doors do not import
// or construct this until the single P1.0c unified cutover.
import command : Command;
import command_history : CommandHistory, PreparedHistoryKind,
                         PreparedHistoryResult, PreparedHistoryToken,
                         ValidatedPreparedHistoryToken;
import record_observer_hub : RecordObserverHub;

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
public:
    this(CommandHistory history, RecordObserverHub observers) {
        history_ = history;
        observers_ = observers;
        if (history_ !is null) {
            token_ = history_.beginPrepared();
            begun_ = true;
        }
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
        validated_ = history_.validatesPreparedToken(token_, observers_);
        validated_Once = validated_.valid;
        return validated_Once;
    }

    void install() nothrow @nogc {
        if (!validated_Once) return;
        history_.installPreparedToken(validated_);
        validated_Once = false;
        begun_ = false;
    }

    void discard() nothrow @nogc {
        if (!begun_ || validated_Once) return;
        history_.discardPreparedToken(token_);
        begun_ = false;
    }

    void installedDepths(out size_t modelDepth, out size_t uiDepth) const {
        modelDepth = 0; uiDepth = 0;
        if (history_ !is null) history_.undoDepthCounts(modelDepth, uiDepth);
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
