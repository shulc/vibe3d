module guarded_action_controller;

import command : Command, g_testMode;
import command_history : RecordMode;
import ui.discard_guard : GuardAnswer, GuardRecord, GuardSettle, GuardVerdict,
    UiRunOutcome, guardVerdict, settlePerforms;

alias GuardApplyPort = bool delegate(Command, RecordMode);
alias GuardDirtyReadPort = bool delegate();
alias GuardSavePort = bool delegate();
alias GuardNoticePort = void delegate(Command);

struct GuardObservationPorts {
    void delegate(GuardRecord) request;
    void delegate(GuardAnswer, bool) answer;
    void delegate(bool) pending;
}

struct GuardedActionPorts {
    GuardApplyPort apply;
    GuardDirtyReadPort dirty;
    GuardSavePort save;
    GuardNoticePort notice;
    GuardObservationPorts observation;
}

/// Application owner for one deferred user action. It decides only when the
/// supplied apply port may run; command construction, execution and recording
/// remain owned by the existing application binding/executor (task 5640).
final class GuardedActionController {
private:
    GuardedActionPorts ports_;
    Command pendingCommand_;
    RecordMode pendingMode_;
    GuardSettle settle_;
    string promptText_;

public:
    this(GuardedActionPorts ports) {
        assert(ports.apply !is null,
            "GuardedActionController requires an apply port");
        assert(ports.dirty !is null,
            "GuardedActionController requires a dirty-read port");
        assert(ports.save !is null,
            "GuardedActionController requires a save port");
        assert(ports.notice !is null,
            "GuardedActionController requires a notice port");
        assert(ports.observation.request !is null,
            "GuardedActionController requires a request-record port");
        assert(ports.observation.answer !is null,
            "GuardedActionController requires an answer-record port");
        assert(ports.observation.pending !is null,
            "GuardedActionController requires a pending-record port");
        ports_ = ports;
    }

    @property bool pending() const {
        return pendingCommand_ !is null;
    }

    @property bool awaitingAnswer() const {
        return pending && settle_ == GuardSettle.none;
    }

    @property Command pendingCommand() {
        return pendingCommand_;
    }

    @property string promptText() const {
        return promptText_;
    }

    UiRunOutcome invoke(Command command, RecordMode mode,
                        string dispatchedId = "") {
        if (command is null) return UiRunOutcome.refused;

        const discards = command.discardsUnsavedWork();
        const dirty = ports_.dirty();
        const verdict = guardVerdict(discards, dirty);

        GuardRecord record;
        record.id = dispatchedId;
        record.name = command.name();
        record.discards = discards;
        record.dirty = dirty;
        record.verdict = verdict == GuardVerdict.prompt ? "prompt" : "proceed";
        record.answer = "none";

        if (verdict == GuardVerdict.prompt) {
            record.suppressed = g_testMode;
            record.outcome = "deferred";
            if (pending) {
                record.dropped = "guard already pending";
                ports_.observation.request(record);
                return UiRunOutcome.deferred;
            }

            pendingCommand_ = command;
            pendingMode_ = mode;
            settle_ = GuardSettle.none;
            promptText_ = "You have unsaved changes.\n\nSave them before "
                ~ (command.label().length ? command.label() : command.name())
                ~ "?";
            ports_.observation.request(record);
            ports_.observation.pending(true);
            return UiRunOutcome.deferred;
        }

        const applied = ports_.apply(command, mode);
        record.outcome = applied ? "applied" : "refused";
        record.refused = !applied;
        ports_.observation.request(record);
        if (!applied) ports_.notice(command);
        return applied ? UiRunOutcome.applied : UiRunOutcome.refused;
    }

    bool answerSave() {
        if (!awaitingAnswer) return false;
        const saved = ports_.save();
        settle_ = GuardSettle.afterSave;
        ports_.observation.answer(GuardAnswer.save, false);
        return saved;
    }

    void answerDiscard() {
        if (!awaitingAnswer) return;
        settle_ = GuardSettle.perform;
        ports_.observation.answer(GuardAnswer.discard, false);
    }

    void answerCancel() {
        if (!pending) return;
        dropPending();
        ports_.observation.answer(GuardAnswer.cancel, false);
    }

    void dropPending() {
        pendingCommand_ = null;
        pendingMode_ = RecordMode.init;
        settle_ = GuardSettle.none;
        promptText_ = "";
        ports_.observation.pending(false);
    }

    bool settle() {
        if (settle_ == GuardSettle.none) return false;

        auto command = pendingCommand_;
        const mode = pendingMode_;
        const settle = settle_;
        const afterSave = settle == GuardSettle.afterSave;
        dropPending();

        if (command is null || !settlePerforms(settle, ports_.dirty()))
            return false;

        const applied = ports_.apply(command, mode);
        ports_.observation.answer(
            afterSave ? GuardAnswer.save : GuardAnswer.discard, applied);
        if (!applied) ports_.notice(command);
        return applied;
    }
}
