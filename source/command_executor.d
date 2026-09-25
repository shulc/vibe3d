module command_executor;

import command;
import command_history : CommandHistory, RecordMode;
import tool_activation_ownership : CloseOutcome, CommandDoor, ToolTransition;

// Project-owned command/history orchestration. Exact `grep -rl -w` checks for
// both `CommandExecutor` and `command_executor` in the SDK tree returned zero
// files before task 4570 introduced the type and module.
final class CommandExecutor {
private:
    CommandHistory history;
    bool delegate() activeTool;
    void delegate(ToolTransition) dropActiveTool;
    CloseOutcome delegate(CommandDoor) closeForCommand;
    void delegate() finishClose;
    bool inPreApplyToolHandling_;
    // Set for the extent of one UI-door invocation (`applyOrRefireFromUi`);
    // nested invocations inherit it, the outermost clears it.
    bool uiOrigin_;

public:
    this(CommandHistory history, bool delegate() activeTool,
         void delegate(ToolTransition) dropActiveTool,
         CloseOutcome delegate(CommandDoor) closeForCommand = null,
         void delegate() finishClose = null) {
        assert(history !is null, "CommandExecutor requires CommandHistory");
        assert(activeTool !is null, "CommandExecutor requires an armed-tool reader");
        assert(dropActiveTool !is null, "CommandExecutor requires a tool-drop hook");
        this.history = history;
        this.activeTool = activeTool;
        this.dropActiveTool = dropActiveTool;
        this.closeForCommand = closeForCommand;
        this.finishClose = finishClose;
    }

    // The UI door (keys, buttons, panels, `?origin=ui`): the same funnel with
    // the door marked, so a recording command closes a live operation of a
    // `uiDoor` tool first (slice M2; the captured C1-h-sel family law).
    bool applyOrRefireFromUi(Command cmd, RecordMode mode, string throwMsg) {
        const bool outer = !uiOrigin_;
        uiOrigin_ = true;
        scope(exit) if (outer) uiOrigin_ = false;
        return applyOrRefire(cmd, mode, throwMsg);
    }

    // Refire/apply-record dispatch helper (task 0183 C4). Folds the
    // `if (history.refireActive) fire else apply+record` dance that was
    // re-inlined at 4 call sites (generic command dispatch, selection
    // handler, transform handler, runCommand) into one place. Two axes are
    // load-bearing and stay fully parameterized — do NOT flatten them:
    //   - throwMsg is null  -> failures are silent (runCommand's case)
    //   - throwMsg not null -> failures throw new Exception(throwMsg)
    //   - mode selects record() vs recordCoalescing() on a successful apply
    // Equivalence per call site is documented at each call below.
    // Returns TRUE iff the command actually landed (applied, or fired inside
    // an open refire bracket). Task 1520 needs the answer: the UI adapter must
    // tell "refused" from "applied" WITHOUT a throw, because the throw is what
    // killed the editor from inside an ImGui draw.
    bool applyOrRefire(Command cmd, RecordMode mode, string throwMsg) {
        // Task 6250 latch extent: the whole invocation, including pre-apply
        // commit, command apply/record and post-apply resume. Declared first so
        // reverse-order scope guards run the resume before this latch clears.
        const bool reentrant = inPreApplyToolHandling_;
        if (!reentrant) inPreApplyToolHandling_ = true;
        scope(exit) if (!reentrant) inPreApplyToolHandling_ = false;

        // Post-mode finalize (task 0463, SDK-derived — the reference's
        // MODEL command class + its command-system post-mode listener; see
        // toolcards/_framework/shift_apply_rearm.md "Command-fired post-mode
        // finalize"). A Model (scene-mutating) command executed while an
        // interactive tool is armed normally DROPS the tool FIRST — committing
        // any pending live edit via deactivate() — then runs. Task 6250 ports
        // the narrower 2026-09-16 capture: mesh.subpatch_toggle instead commits
        // the pending transform, runs, and resumes the tool in place. The tool
        // decides whether that means a fresh run or a closed retained frame. The
        // exception is bounded by both a command predicate and a cast-discovered
        // tool capability; every other command/tool pair keeps the drop rule.
        // Without the default, Delete-while-bevelling ran on the live-preview
        // mesh, leaving the tool's session desynced.
        //
        // The single chokepoint: both runCommand (keyboard / UI) and the HTTP
        // /api/command dispatch funnel here. This targets INCREMENTAL mesh-edit
        // commands (delete / subdivide / bevel / extrude …) that build on the
        // current mesh. Excluded families keep the tool (or manage it
        // themselves):
        //   * tool.* — the tool's OWN commands (tool.attr / tool.set are
        //     SideEffect anyway; tool.doApply is Model but is the tool applying
        //     itself). They CONTINUE the session, never end it.
        //   * scene.* / file.* — document-replace / lifecycle commands bypass
        //     this generic commit-and-drop policy. Their discard behaviour is
        //     checked over the live registry by tests/test_disarm_census.d,
        //     so the authoritative set and mechanism are not duplicated here.
        //   * selection / edit-mode commands are UiState (not Model), already
        //     skipped by the flag.
        //   * layer.attr, and ONLY layer.attr, of the `layer.*` family (task
        //     0614 Phase 5 review, B1). It writes one property of one EXISTING
        //     layer through the same param path the item transform tool itself
        //     writes, so it CONTINUES the session for the same reason `tool.*`
        //     does. Concretely: under SelType.Item the Layers panel's transform
        //     rows dispatch `layer.attr` (config/forms/layer_props.yaml) and
        //     Phase 5 deliberately un-greyed those rows while a transform tool
        //     is armed — so without this exclusion the FIRST numeric edit in a
        //     freshly-enabled row would drop the tool and take the gizmo with
        //     it, making the phase's own goal unreachable through exactly the
        //     rows it enabled.
        //
        //     A blanket `layer.` prefix would be WRONG. Of the Model-class
        //     `layer.*` commands — add, duplicate, reorder, delete, rename,
        //     setVisible, attr, parent (`layer.select` is UiState and already
        //     skipped; on a genuine primary move it probes, restores, drops the
        //     tool while the old layer is current, then replays its mutation) —
        //     `layer.attr` is the only one that can change neither
        //     the layer SET nor WHICH layer is primary. add / duplicate make a
        //     NEW layer primary, delete can remove the tool's own target, and
        //     setVisible can promote a different layer when the primary is
        //     hidden: for those the drop is correct, and each additionally
        //     routes a primary change through `onActiveLayerChanged` (which
        //     drops the tool itself). reorder / rename / parent leave the
        //     primary put but are not session CONTINUATIONS either, so they
        //     keep the status-quo drop.
        // Re-entry from commit/apply/resume suppresses only the narrow boundary
        // exception below. An ordinary Model command reached re-entrantly
        // still owns the pre-existing drop policy.
        //
        // Task 0616 Ph5 review (S3): a command that knows WHY it declined gets
        // to say so. `Command.refusalReason()` is "" for everything that has
        // not opted in, in which case the thrown text is byte-identical to
        // what it always was; a command that refuses for several different
        // reasons (a bad index vs. an unreadable path vs. a row of the wrong
        // kind) can name the one it hit, and the caller — a script, an HTTP
        // client, the panel that surfaced the error — reads it instead of
        // "did not apply".
        string failMsg() {
            auto why = cmd.refusalReason();
            return why.length > 0 ? throwMsg ~ ": " ~ why : throwMsg;
        }
        // A refire command belongs to the already-open interactive bracket;
        // it never crosses the armed-tool post-mode policy a second time.
        if (history.refireActive) {
            if (history.fire(cmd)) return true;
            if (throwMsg !is null) throw new Exception(failMsg());
            return false;
        }

        // Slice M2 (tool session model, doc/tool_session_model_plan_2026-09-24.md
        // R4.2): the pre-apply commit above is now ONE close routine,
        // `EditSession.closeOperation(CloseReason.command, door)`, reached
        // through `closeForCommand` — for the 6250 command on either door,
        // and for any recording command (`endsLiveEditBeforeUiCommand`) on the
        // UI door. The tool's policy and its own `commitOperation` decide;
        // when it does not stay armed the funnel falls back to exactly the
        // rules above (drop for the 6250 command and for the drop set; a
        // UiState command leaves the tool alone). A command refused after the
        // close has already closed the operation, as the old pre-apply drop
        // had. The resume is the session's own (`finishClose`, at most once per
        // close), run from the non-reentrant frame only.
        if (activeTool()) {
            const bool commits = commitsActiveToolEditBeforeApply(cmd);
            if (!reentrant && (commits
                    || (uiOrigin_ && endsLiveEditBeforeUiCommand(cmd)))) {
                const o = closeForCommand !is null
                    ? closeForCommand(uiOrigin_ ? CommandDoor.ui : CommandDoor.script)
                    : CloseOutcome.init;
                if (!o.staysArmed && (commits || dropsActiveToolBeforeApply(cmd)))
                    dropActiveTool(ToolTransition.commandPreApplyDrop);
            } else if (dropsActiveToolBeforeApply(cmd)) {
                dropActiveTool(ToolTransition.commandPreApplyDrop);
            }
        }
        scope(exit) if (!reentrant && finishClose !is null) finishClose();
        if (cmd.apply()) {
            final switch (mode) {
                case RecordMode.Record:     history.record(cmd);           break;
                case RecordMode.Coalescing: history.recordCoalescing(cmd); break;
            }
            return true;
        }
        if (throwMsg !is null) throw new Exception(failMsg());
        return false;
    }
}
