module ui.history_panel;

import command_history : CommandHistory, HistoryEntry;
import macro_recorder : MacroRecorder;

enum size_t HistoryFilterCapacity = 256;
enum size_t HistoryReplCapacity = 512;

/// Form storage owned by one Command History panel instance.  The backing
/// buffers are allocated per instance so widget slices remain stable across
/// frames and never alias another panel state.
final class HistoryPanelState {
    private char[] filterStorage_;
    private char[] replStorage_;

    bool visible;
    bool showArgs = true;
    bool showRowNumbers;
    bool showTimestamps;
    bool showCommandIds;
    bool replLastWasError;

    this() {
        filterStorage_ = new char[](HistoryFilterCapacity);
        replStorage_ = new char[](HistoryReplCapacity);
        filterStorage_[] = 0;
        replStorage_[] = 0;
    }

    @property char[] filterBuffer() { return filterStorage_; }
    @property char[] replBuffer() { return replStorage_; }

    @property const(char)[] filterText() const {
        import std.string : fromStringz;
        return fromStringz(filterStorage_.ptr);
    }

    @property const(char)[] replText() const {
        import std.string : fromStringz;
        return fromStringz(replStorage_.ptr);
    }

    void setFilterText(string text) {
        setFixedBuffer(filterStorage_, text);
    }

    void setReplText(string text) {
        setFixedBuffer(replStorage_, text);
    }

    void clearRepl() {
        replStorage_[] = 0;
    }
}

private void setFixedBuffer(ref char[] target, string text) {
    import std.algorithm.comparison : min;

    target[] = 0;
    const n = min(text.length, target.length - 1);
    target[0 .. n] = text[0 .. n];
}

alias HistoryEntriesRead = const(HistoryEntry)[] delegate();
alias HistoryCommandLineRead = string delegate(size_t);

/// The panel's read-only view of the raw history stacks.  HTTP keeps its
/// separate visible-entry role; this adapter deliberately reads undoEntries
/// and redoEntries without adding another index space.
struct HistoryPanelRead {
    HistoryEntriesRead undoEntries;
    HistoryEntriesRead redoEntries;
    HistoryCommandLineRead undoEntryCommandLine;
}

HistoryPanelRead bindHistoryPanelRead(CommandHistory history) {
    assert(history !is null, "HistoryPanelRead requires CommandHistory");
    return HistoryPanelRead(
        () => history.undoEntries(),
        () => history.redoEntries(),
        (size_t rawIndex) => history.undoEntryCommandLine(rawIndex));
}

struct HistoryMacroStatus {
    bool active;
    size_t length;
}

alias HistoryNavigateAction = bool delegate(bool isUndo);
alias HistoryRawJumpAction = bool delegate(size_t target);
alias HistoryClearAction = void delegate();
alias HistoryReplayAction = void delegate(size_t rawIndex);
alias HistoryDispatchAction = void delegate(string id, string paramsJson);
alias HistoryOpenArgsAction = bool delegate(string id);
alias HistoryMacroStatusRead = HistoryMacroStatus delegate();

struct HistoryPanelActions {
    HistoryNavigateAction navigate;
    HistoryRawJumpAction rawJump;
    HistoryClearAction clearHistory;
    HistoryReplayAction replay;
    HistoryDispatchAction dispatch;
    HistoryOpenArgsAction openArgs;
    HistoryMacroStatusRead macroStatus;
}

/// Bind the exact application actions used by the visible panel.  Navigation
/// remains the session-aware cursor hook; raw row jumps remain CommandHistory
/// jumps; replay and dispatch remain ApplicationCommandBinding operations.
HistoryPanelActions bindHistoryPanelActions(CommandHistory history,
        HistoryNavigateAction navigate,
        HistoryReplayAction replay,
        HistoryDispatchAction dispatch,
        HistoryOpenArgsAction openArgs,
        MacroRecorder macroRecorder) {
    assert(history !is null, "HistoryPanelActions requires CommandHistory");
    assert(navigate !is null, "HistoryPanelActions requires cursor navigation");
    assert(replay !is null, "HistoryPanelActions requires replay");
    assert(dispatch !is null, "HistoryPanelActions requires dispatch");
    assert(openArgs !is null, "HistoryPanelActions requires args opener");
    assert(macroRecorder !is null, "HistoryPanelActions requires macro status");

    return HistoryPanelActions(
        navigate,
        (size_t target) => history.jumpTo(target),
        () => history.clear(),
        replay,
        dispatch,
        openArgs,
        () => HistoryMacroStatus(macroRecorder.active, macroRecorder.length));
}

enum HistoryReplOutcome {
    ignored,
    failed,
    dispatched,
}

/// Headless controller for the reactions initiated by History panel widgets.
/// Drawing decides which event occurred; this type owns the resulting action
/// and REPL state transition without depending on ImGui.
struct HistoryPanelController {
private:
    HistoryPanelState state_;
    HistoryPanelActions actions_;

public:
    this(HistoryPanelState state, HistoryPanelActions actions) {
        assert(state !is null, "HistoryPanelController requires state");
        assert(actions.navigate !is null);
        assert(actions.rawJump !is null);
        assert(actions.clearHistory !is null);
        assert(actions.replay !is null);
        assert(actions.dispatch !is null);
        assert(actions.openArgs !is null);
        assert(actions.macroStatus !is null);
        state_ = state;
        actions_ = actions;
    }

    bool navigate(bool isUndo) { return actions_.navigate(isUndo); }
    bool rawJump(size_t target) { return actions_.rawJump(target); }
    void clearHistory() { actions_.clearHistory(); }
    void replay(size_t rawIndex) { actions_.replay(rawIndex); }
    void dispatch(string id, string paramsJson) { actions_.dispatch(id, paramsJson); }
    bool openArgs(string id) { return actions_.openArgs(id); }
    HistoryMacroStatus macroStatus() { return actions_.macroStatus(); }

    HistoryReplOutcome submitRepl() {
        import argstring : parseArgstring;

        // Own the line through parsing and synchronous dispatch.  Clearing the
        // widget buffer after dispatch must not invalidate parser-owned slices.
        string line = state_.replText.dup;
        if (line.length == 0) return HistoryReplOutcome.ignored;

        try {
            auto parsed = parseArgstring(line);
            if (parsed.isEmpty) {
                state_.replLastWasError = true;
                return HistoryReplOutcome.failed;
            }
            actions_.dispatch(parsed.commandId, parsed.params.toString());
        } catch (Exception) {
            state_.replLastWasError = true;
            return HistoryReplOutcome.failed;
        }

        // Preserve the pre-extraction contract: a dispatch that returned
        // without throwing clears the input regardless of applied/refused.
        state_.clearRepl();
        state_.replLastWasError = false;
        return HistoryReplOutcome.dispatched;
    }
}
