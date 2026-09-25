module edit_session;

// ---------------------------------------------------------------------------
// EditSession — the single driver of the Tool session protocol (task 0428,
// campaign 0407 §V3).
//
// The session protocol — live re-evaluation (attr / pipe-stage edits
// re-running a live tool), refire dispatch (record-once panel-edit
// sessions), and history coordination (undo/redo navigation around an open
// live edit) — used to be spread across narrow virtual hooks on the Tool
// base plus driver blocks in app.d and three command files. This class owns
// the PROTOCOL (when the hooks fire and in what order); Tool subclasses keep
// owning their session STATE and the hook bodies (what a cancel / re-eval
// actually does). Behavior is frozen: every method body here is a verbatim
// transplant of the driver block it replaced.
//
// Structure:
//  * The wide 3-hook contract stays virtual on Tool (hasUncommittedEdit /
//    cancelUncommittedEdit / resyncSession — genuinely polymorphic, ~30
//    overriders each). EditSession is their only driver, plus two documented
//    read-only render gates in ui/panels.d.
//  * The narrow session hooks (1-2 overriders each) are optional capability
//    interfaces below, discovered by cast on the active tool. Absence of the
//    interface == the former base-class default (false / no-op / null).
//  * Tool does NOT reference EditSession (no back-edge): the session pulls
//    through the tool accessor + the capability interfaces.
//
// THREADING: every method is MAIN-THREAD ONLY (same discipline as the
// navHistory chokepoint — the protocol touches the active tool). The /api
// paths reach it through the epoch-marshalled tickCommand bridge, so no
// locks are needed here.
// ---------------------------------------------------------------------------

import tool            : Tool, CommandClose, AttrImage, PressKind, OpensAt,
                         ToolSessionLink;
import command         : Command;
import std.json        : JSONValue;
import command_history : CommandHistory, UndoState;
import held_gesture_buttons : g_heldGestureButtons;
import std.typecons    : Rebindable;
import params          : ParamProvider;
import toolpipe.stage  : Stage;
import tool_activation_ownership : CloseReason, CommandDoor, CloseOutcome;
import tools.common.session_mesh_key : SessionMeshKey;

// Computed classification of the session protocol's current phase. There is
// deliberately NO stored state machine mirroring this: the truth about an
// open edit lives in the tools (flipped inside mouse handlers without
// notification), so a stored enum would be a second source of truth waiting
// to desync. The invariants this module codifies are expressed as pre/post-
// conditions on the protocol methods, not as transitions of a stored automaton.
enum SessionPhase {
    NoTool,     // no active tool
    Idle,       // active tool, no uncommitted edit
    EditOpen,   // active tool holding an open live edit
}

/// Why a parameter value changed.  Source is explicit because an interactive
/// value may open a live session, a scripted value may not, and a slot
/// activation must end a held operation before any stage re-evaluation.
enum ParameterChangeSource {
    InteractiveValue,
    ScriptedValue,
    StageAttribute,
    SlotActivation,
}

/// Where a caller is in one logical widget/command batch.  ValueWritten may
/// occur more than once; BatchComplete occurs once and owns evaluation.
enum ParameterChangePhase {
    ValueWritten,
    BatchComplete,
}

/// The values that were actually written in one logical parameter batch.
/// `names` is the write set, not a projection from the provider's current
/// values: an RX write back to 0 and an SX write back to 1 therefore remain
/// observable causes.  EditSession owns the accumulation and the slice is
/// valid only for the synchronous BatchComplete dispatch.
struct ParameterChangeBatch {
    ParameterChangeSource source;
    string[] names;
}

// ---------------------------------------------------------------------------
// LiveEvalClient — optional capability: the tool supports live re-evaluation
// (an attribute / pipe-stage edit re-runs the open session's apply).
// XfrmTransformTool is the sole implementor.
//
// INVARIANT (double-apply hazard): no tool may BOTH override evaluate() to
// mutate geometry AND implement this interface with hasLiveEval()==true. The
// attr-command path calls onParamChanged()+evaluate() before the session's
// re-eval trigger (commands/tool/attr.d), so a tool doing both would apply
// twice on one attr write. Tools whose preview runs through evaluate()
// (primitives) stay OFF this interface; tools whose geometry runs through a
// session replay (the transform tool) keep evaluate() a no-op.
// ---------------------------------------------------------------------------
interface LiveEvalClient {
    // Whether this tool has an OPEN live-evaluation session that an attribute
    // edit should re-run. While false, a `tool.attr` edit just stores the new
    // value into the tool's attribute store and changes no geometry — the
    // faithful "fresh-tool inertness" semantics. While true, the session
    // driver calls reEvaluate() to re-run the tool's apply with the freshly
    // written attribute values.
    bool hasLiveEval() const;

    // Live-eval predicate SPECIFICALLY for a value-attribute write (`tool.attr
    // <id> RX 30` etc.), distinct from `hasLiveEval()` (which also gates the
    // pipe-stage config path `tool.pipe.attr falloff …`). Implementations
    // widen THIS predicate (only) to include a still-open gizmo RUN whose
    // per-gesture edit session already self-committed (P-F): a panel RX/RY/RZ
    // edit after a gizmo gesture must compose onto the run baseline, but a
    // falloff CONFIG change in that same window must STILL flow through the
    // idle re-grade record path (which appends a tagged in-session entry)
    // rather than the silent panel-replay. Keeping the pipe path on the
    // narrower `hasLiveEval()` preserves that falloff-refire entry-count
    // contract.
    bool hasLiveAttrEval() const;

    // Re-run this tool's apply from its open live-evaluation session baseline
    // using the tool's CURRENT attribute values (ABSOLUTE — read the value
    // straight from the baseline, never accumulate a per-call delta). The
    // result coalesces into the session's single undo entry, committed when
    // the session ends.
    void reEvaluate(ParameterChangeBatch batch);
}

// ---------------------------------------------------------------------------
// FrameParameterEvalClient — optional capability for a tool whose parameter
// result can become stale without a new value-widget event.
//
// CommandWrapperTool is the first and only family on this seam.  Its own
// params are event-driven, but it also observes the active falloff packet set;
// that set can change independently of a tool widget.  Keeping this as a
// narrow capability makes the per-frame work explicit instead of retaining
// PropertyPanel's blanket evaluate() call for every legacy tool.
// ---------------------------------------------------------------------------
interface FrameParameterEvalClient {
    /// Called once from the main tool tick.  Implementations must keep their
    /// own cheap no-change gate and apply only when observed state moved.
    void evaluateParameterFrame();
}

// ---------------------------------------------------------------------------
// SlotActivationClient — optional capability (task 0791): a tool that treats
// ACTIVATING a pipe slot differently from writing one of its ATTRIBUTES.
//
// The distinction is measured, not stylistic. Putting a tool into a slot — even
// the same tool that was already there — ENDS the held operation and freezes
// its result; writing an attribute of the tool in the slot RE-WEIGHS the held
// operation in place. XfrmTransformTool is the sole implementor; every other
// tool keeps the old, single-branch behaviour by simply not implementing it.
//
// This seam exists because the two answers must be decided BEFORE the
// stage-config re-evaluate below runs: the re-evaluate IS the re-weigh, so a
// tool whose run has just ended must not have it fired at all. An idle poll one
// frame later cannot undo an already-recomputed geometry.
// ---------------------------------------------------------------------------
interface SlotActivationClient {
    /// A pipe-stage config edit has been published. Return true iff it was a
    /// SLOT ACTIVATION for this tool, in which case the tool has ALREADY ended
    /// its held run and the caller must skip the re-evaluate. Must be
    /// idempotent — the driver may call it more than once per change.
    bool endHeldRunIfSlotActivated();
}

// ---------------------------------------------------------------------------
// RefireClient — optional capability: record-once, re-evaluate panel-edit
// sessions (undo/redo migration P4). CommandWrapperTool (the deform-command
// wrapper base: xfrm.smooth / jitter / quantize + edge slide) is the sole
// implementor.
//
// A Tool-Properties (panel) param edit on an opted-in tool becomes ONE
// re-evaluated undo entry instead of a tool-internal preview followed by a
// separate commit-at-deactivate. The driver (EditSession) brackets a
// panel-param-edit SESSION with the history's refireBegin / refireEnd
// primitives and, on each param change inside the bracket, fires
// buildRefireCommand() so each tick reverts the previous live command and
// applies the freshly-evaluated one — the net stack effect is a single
// entry reflecting the LAST param value.
// ---------------------------------------------------------------------------
interface RefireClient {
    // Opt-in gate: a tool may implement the interface yet answer false when
    // its undo plumbing isn't wired — it is then never routed through refire.
    bool wantsRefire() const;

    // Build the command that represents the tool's CURRENT param state, ready
    // to apply(). For a deform tool this re-runs the deformation against the
    // session baseline and packages the resulting per-vertex before/after as a
    // single undoable command, WITHOUT recording it (the history's fire() owns
    // the apply / revert / record lifecycle). Returns null when there is no
    // meaningful edit to fire (e.g. the params produced a no-op diff) — the
    // driver then skips the fire() for that tick.
    Command buildRefireCommand();

    // Toggle the tool's "a refire session is driving me" state. Set true by
    // the driver around a param injection so the tool suppresses its own
    // internal preview (the fired command owns mutation); cleared by the
    // driver when the injection tick ends.
    void setRefireDriving(bool on);

    // Driver callback once a refire session committed its single entry (after
    // refireEnd). Lets the tool latch its double-record guard and advance its
    // baseline so the subsequent commit chokepoint records nothing.
    void onRefireCommitted();
}

// ---------------------------------------------------------------------------
// commandMeetsTool — the command funnel's rule for an armed tool (slice M4,
// the "M2 follow-up" of doc/tool_session_model_plan_2026-09-24.md). A command
// that closes a live operation first (the 6250 command on either door, any
// recording command on the UI door; never re-entrantly) asks the tool's close
// (`close`, the session's `closeOperation`, which reads the policy's
// `commandClose`); when the tool does not stay armed, the policy's fallback
// applies — a Model command drops it, a UiState one leaves it, and the 6250
// command drops a tool it could not close. `close` null: no session (the
// fallback alone, for a funnel wired without one).
// ---------------------------------------------------------------------------
CloseOutcome commandMeetsTool(const Command cmd, CommandDoor door, bool reentrant,
                              scope CloseOutcome delegate(CommandDoor) close) {
    import command : commitsActiveToolEditBeforeApply, dropsActiveToolBeforeApply,
                     endsLiveEditBeforeUiCommand;
    const bool commits = commitsActiveToolEditBeforeApply(cmd);
    const bool closes = !reentrant
        && (commits || (door == CommandDoor.ui && endsLiveEditBeforeUiCommand(cmd)));
    CloseOutcome o = closes && close !is null ? close(door) : CloseOutcome.init;
    o.dropsTool = !o.staysArmed && (dropsActiveToolBeforeApply(cmd) || (closes && commits));
    return o;
}

// ---------------------------------------------------------------------------
// EditSession
// ---------------------------------------------------------------------------
final class EditSession {
    // Live view of the active tool — a delegate, not a snapshot, so every
    // protocol method re-reads the current tool exactly like the app.d driver
    // blocks it absorbed re-read `activeTool`.
    private Tool delegate() tool_;
    private CommandHistory  history_;
    // Bound in app.d to a drop under the editCancelDrop transition — the
    // app's tool-drop verb. Spelled without the `ToolTransition.` prefix
    // deliberately: the per-transition site census in
    // tests/unit/tool_activation_ownership_test.d counts MENTIONS raw, and
    // its editCancelDrop row records the CALL site, not this pointer to it.
    private void delegate() dropTool_;
    // The ONLY state EditSession owns: the refire driver-bracket bit
    // (tryRefireDispatch's non-reentrancy tripwire). Everything else is
    // computed from tool_() — see SessionPhase.
    private bool refireDriving_ = false;
    // The tool session: history navigation around the active tool (slice M1).
    private ToolSession tools_;
    // One write-set accumulator for the synchronous ValueWritten ->
    // BatchComplete protocol.  It deliberately records names at write time;
    // reconstructing the set from final values would lose identity returns.
    private ParamProvider parameterBatchProvider_;
    private string[] parameterBatchNames_;
    private ParameterChangeSource parameterBatchSource_;
    private bool parameterBatchSourceKnown_;

    this(Tool delegate() tool, CommandHistory history,
         void delegate() dropTool) {
        assert(tool !is null,     "EditSession: tool accessor required");
        assert(history !is null,  "EditSession: history required");
        assert(dropTool !is null, "EditSession: dropTool verb required");
        tool_     = tool;
        history_  = history;
        dropTool_ = dropTool;
        tools_    = ToolSession(tool, history, dropTool);
    }

    // Computed phase classification (see SessionPhase above).
    SessionPhase phase() {
        auto t = tool_();
        if (t is null) return SessionPhase.NoTool;
        return t.hasUncommittedEdit() ? SessionPhase.EditOpen
                                      : SessionPhase.Idle;
    }

    /// Give the active tool family that explicitly opted into frame-driven
    /// parameter observation one tick.  This is independent of whether the
    /// Tool Properties panel is visible.
    void tickParameterEvaluation() {
        auto fc = cast(FrameParameterEvalClient) tool_();
        if (fc !is null) fc.evaluateParameterFrame();
    }

    // ----- live-eval (re-eval plan D4) --------------------------------------

    /// Orchestrate one parameter-change batch after the widget or command has
    /// already written the value.  Call ValueWritten for every actual write,
    /// then BatchComplete exactly once.  This keeps notifications per value
    /// while grouping evaluate/live-session work per user gesture.
    ///
    /// A pointer-written stage batch uses both phases; ValueWritten supplies
    /// its notification and, for a slot-selector row, its slot epoch.  An
    /// already-published stage command or stack change instead uses the
    /// compatibility entry below and therefore carries no write-set names.
    void orchestrateParameterChange(ParamProvider provider, string name,
            ParameterChangeSource source, ParameterChangePhase phase) {
        final switch (phase) {
            case ParameterChangePhase.ValueWritten:
                assert(provider !is null,
                    "parameter ValueWritten requires its provider");
                rememberParameterWrite(provider, name, source);
                final switch (source) {
                    case ParameterChangeSource.InteractiveValue: {
                        auto t = cast(Tool)provider;
                        assert(t !is null,
                            "interactive parameter source requires a Tool");
                        const step = tools_.actionStepBegins(t, name);
                        t.notifyInteractiveParamChanged(name);
                        if (step) tools_.stepEnds(t, false);
                        return;
                    }
                    case ParameterChangeSource.ScriptedValue: {
                        auto t = cast(Tool)provider;
                        assert(t !is null,
                            "scripted parameter source requires a Tool");
                        const step = tools_.actionStepBegins(t, name);
                        t.onParamChanged(name);
                        if (step) tools_.stepEnds(t, false);
                        return;
                    }
                    case ParameterChangeSource.StageAttribute:
                        assert(cast(Stage)provider !is null,
                            "stage attribute source requires a Stage");
                        provider.onParamChanged(name);
                        return;
                    case ParameterChangeSource.SlotActivation: {
                        auto stage = cast(Stage)provider;
                        assert(stage !is null,
                            "slot activation source requires a Stage");
                        stage.onParamChanged(name);
                        stage.noteSlotArmed();
                        return;
                    }
                }

            case ParameterChangePhase.BatchComplete:
                assert(provider !is null,
                    "parameter BatchComplete requires its provider");
                assert(parameterBatchProvider_ is provider,
                    "parameter BatchComplete must close its provider's write batch");
                assert(parameterBatchNames_.length != 0,
                    "parameter BatchComplete requires at least one written value");
                assert(parameterBatchSourceKnown_ && parameterBatchSource_ == source,
                    "parameter BatchComplete source must match its written values");
                auto batch = ParameterChangeBatch(source, parameterBatchNames_);
                scope(exit) {
                    parameterBatchProvider_ = null;
                    parameterBatchNames_.length = 0;
                    parameterBatchSourceKnown_ = false;
                }
                final switch (source) {
                    case ParameterChangeSource.InteractiveValue:
                    case ParameterChangeSource.ScriptedValue: {
                        auto t = cast(Tool)provider;
                        assert(t !is null,
                            "value parameter batch requires a Tool");
                        // Notification already ran for every write.  Evaluate
                        // the grouped value set before a live replay reads it.
                        t.evaluate();
                        applyValueToLiveSession(batch,
                            source == ParameterChangeSource.InteractiveValue);
                        return;
                    }
                    case ParameterChangeSource.StageAttribute:
                        finishStageChange(batch);
                        return;
                    case ParameterChangeSource.SlotActivation:
                        finishStageChange(batch);
                        return;
                }
        }
    }

    private void rememberParameterWrite(ParamProvider provider, string name,
                                        ParameterChangeSource source) {
        assert(name.length != 0, "a parameter write requires a channel name");
        if (parameterBatchProvider_ is null) {
            parameterBatchProvider_ = provider;
            parameterBatchSource_ = source;
            parameterBatchSourceKnown_ = true;
        }
        assert(parameterBatchProvider_ is provider,
            "one parameter batch cannot span providers");
        assert(parameterBatchSource_ == source,
            "one parameter batch cannot span change sources: production panel "
          ~ "schemas do not co-expose slot selectors and ordinary attributes");
        foreach (written; parameterBatchNames_)
            if (written == name) return;
        parameterBatchNames_ ~= name;
    }

    // A `tool.attr` VALUE write has been injected onto the active tool
    // (injectParamsInto + onParamChanged + evaluate already ran). Decide
    // whether it re-runs a live session. The value is injected BEFORE this
    // trigger so reEvaluate() reads it absolutely from the session baseline
    // (no accumulation).
    //   - hasLiveAttrEval(): a session is ALREADY open (a live drag, a prior
    //     panel/form edit, or a still-open gizmo RUN after a per-gesture
    //     self-commit — see LiveEvalClient.hasLiveAttrEval) — re-run the
    //     apply from the session baseline using the just-written value.
    //   - interactive: a forms-dispatched FIRST edit — reEvaluate() opens
    //     the session (idempotent beginEdit + baseline capture) and replays.
    //   - else: raw HTTP `tool.attr` on a fresh tool — inert (faithful;
    //     every existing HTTP tool.attr golden depends on this).
    // A tool that is not a LiveEvalClient keeps the former base-Tool default:
    // hasLiveAttrEval()==false and reEvaluate() a no-op — i.e. nothing.
    private void applyValueToLiveSession(ParameterChangeBatch batch,
                                         bool interactive) {
        auto lc = cast(LiveEvalClient) tool_();
        if (lc is null) return;
        if (lc.hasLiveAttrEval())  lc.reEvaluate(batch);
        else if (interactive)      lc.reEvaluate(batch);
    }

    // A pipe-stage config edit (tool.pipe.attr / falloff.preset / falloff
    // add/remove) has been published to the stage. Mid-session immediacy:
    // when the tool ALREADY has a live evaluation session, re-run its apply
    // now so the new stage state takes effect this edit instead of on the
    // next update() tick (re-eval plan, stage re-eval). Stage edits never
    // carry the forms `interactive` opener — a stage edit with no live
    // session stays inert. DELIBERATELY gated on the narrower hasLiveEval()
    // (not hasLiveAttrEval()) — see LiveEvalClient.hasLiveAttrEval for the
    // falloff-refire entry-count contract this asymmetry preserves.
    private void applyStageToLiveSession(ParameterChangeBatch batch) {
        auto lc = cast(LiveEvalClient) tool_();
        if (lc !is null && lc.hasLiveEval()) lc.reEvaluate(batch);
    }

    // Ask FIRST and unconditionally (task 0791): the stage's event/capability,
    // not the source enum, decides whether a slot activated. Re-evaluation is
    // the re-weigh and cannot precede that boundary decision.
    private void finishStageChange(ParameterChangeBatch batch) {
        if (requestSlotActivationEnd()) return;
        applyStageToLiveSession(batch);
    }

    private bool requestSlotActivationEnd() {
        auto sa = cast(SlotActivationClient) tool_();
        return sa !is null && sa.endHeldRunIfSlotActivated();
    }

    // Compatibility entry for stage commands outside task 4590's ownership.
    // Their Stage.setAttr call has already published notification/slot epoch.
    void onStageConfigChanged() {
        finishStageChange(ParameterChangeBatch(
            ParameterChangeSource.StageAttribute, null));
    }

    // ----- refire (undo/redo migration P4) ----------------------------------

    // Open a refire block on the history. The bracket is driven externally
    // (the /api/refire test endpoint today) — begin / end are separate calls,
    // not a scope; tryRefireDispatch handles the per-tick fires in between.
    void refireBegin() { history_.refireBegin(); }

    // Refire dispatch (see RefireClient): a `tool.attr` arriving inside an
    // open refire window on an opted-in tool routes through the tool's own
    // buildRefireCommand() rather than firing the (non-undoable) tool.attr
    // command itself. Each tick reverts the previous live command and applies
    // the freshly-evaluated one, so refireEnd lands ONE entry reflecting the
    // LAST param value. The attr is injected onto the tool first (with the
    // tool marked refire-driving so its internal preview stays inert), then
    // the rebuilt command is fired.
    //
    // Returns false — and does NOTHING — when this dispatch is not a refire
    // tick (no refire window open / not a tool.attr / tool not opted in): the
    // caller then keeps its plain fire path. Non-reentrant by construction
    // (history.fire applies the built command directly, never through the
    // command dispatcher) — asserted via the session-owned driving bit, which
    // is scope(exit)-cleared so either throw path below unlatches it.
    bool tryRefireDispatch(Command cmd, string id) {
        auto rc = cast(RefireClient) tool_();
        if (!(history_.refireActive
              && id == "tool.attr"
              && rc !is null
              && rc.wantsRefire()))
            return false;
        assert(!refireDriving_, "refire bracket re-entered");
        refireDriving_ = true;
        scope(exit) refireDriving_ = false;
        rc.setRefireDriving(true);
        scope(exit) rc.setRefireDriving(false);
        if (!cmd.apply())   // inject attr onto the tool's inner cmd
            throw new Exception("command '" ~ id ~ "' did not apply");
        auto refireCmd = rc.buildRefireCommand();
        if (refireCmd !is null) {
            if (!history_.fire(refireCmd))
                throw new Exception(
                    "refire command did not apply");
        }
        return true;
    }

    // Close the refire block: refireEnd() lands the session's single entry;
    // then — ONLY after refireEnd(), the call order encodes the P4 contract —
    // if the session was driving an opted-in tool, tell it the entry has
    // landed so its commit chokepoint (deactivate/Apply) records nothing for
    // the same edit.
    void refireEnded() {
        history_.refireEnd();
        auto rc = cast(RefireClient) tool_();
        if (rc !is null && rc.wantsRefire()) rc.onRefireCommitted();
    }

    // ----- history coordination (undo/redo migration P0 + 0232/0321/0400) ---

    // Interactive history-navigation chokepoint: the keyboard, the panel
    // Undo/Redo rows and the History panel all end here (app.d `navHistory`).
    // The held-button refusal is the input rule's, so it stays at the door;
    // the branch bodies are the tool session's (ToolSession.undo / redo,
    // whose contract paragraph is carried there verbatim by slice M1).
    // Returns true if anything happened (edit cancelled OR stack moved).
    bool navigate(bool isUndo) {
        // No history step while a mouse button is held (slice M1a): the same
        // held-button rule the key router applies, here for every door that
        // reaches this chokepoint (keyboard, panel Undo/Redo, History rows).
        // Refused, not queued; nothing happened, so false.
        if (g_heldGestureButtons.any) return false;
        return isUndo ? tools_.undo() : tools_.redo();
    }

    // Framework "apply and continue" (task 0461 — the reference editor's
    // apply-and-continue gesture, Shift+click on a creation/interactive-edit
    // tool). If the active tool holds an open edit AND supports in-place
    // commit, finalize that edit as its own discrete undo entry
    // (commitUncommittedEdit) and re-arm the SAME session in place
    // (resyncSession) — never a deactivate/reactivate, so the tool's ACEN/
    // AXIS/pipe state and identity survive: commit-into-history then
    // re-arm-in-place, in that order.
    //
    // Returns true iff it committed+rearmed (⇒ the caller consumes the
    // triggering click). Returns false — and does NOTHING — when there is no
    // tool, no open edit, or the tool opts OUT of in-place commit
    // (commitUncommittedEdit()==false, the base default). The opt-out is
    // load-bearing: it guarantees a tool with an open edit it can't finalize
    // in place (e.g. a transform tool's panel session) is left fully intact
    // for the caller's normal path, never re-armed onto a lost edit.
    //
    // Slice M4: the commit is accounted as a close of the tool's operation (its
    // row carries the session token) and the continuing press opens the next
    // operation as a Shift press (ToolSession.applyAndContinue).
    bool applyAndContinue() {
        auto t = tool_();
        if (t is null || !t.hasUncommittedEdit()) return false;
        return tools_.applyAndContinue(t);   // opted out ⇒ false, the edit left alone
    }

    // The operation's close — ONE routine for every reason (slice M2, H3;
    // doc/tool_session_model_plan_2026-09-24.md R4.2). For `command` the
    // tool's policy decides on which door it closes, and its own
    // `commitOperation` whether and how; every other reason's commit belongs
    // to its door (`deactivate()` / the prepared deactivation), so the session
    // only keeps its account of it. Returns what the command funnel needs:
    // whether the tool stays armed across the command.
    CloseOutcome closeOperation(CloseReason r, CommandDoor door = CommandDoor.ui) {
        // No command close while a mouse button is held — the held-button rule
        // `navigate` applies (slice M1a): refused, the tool is not called, and
        // the funnel keeps its pre-M2 rules. A door's close is the door's and
        // runs regardless, so its account is kept.
        if (r == CloseReason.command && g_heldGestureButtons.any)
            return CloseOutcome(false, false);
        return tools_.close(r, door);
    }

    // The command funnel's one question (slice M4, the plan's "M2 follow-up"):
    // what an armed tool does before `cmd` applies — close its operation (the
    // policy's `commandClose`, through `closeOperation`), stay armed, or be
    // dropped (the `none` fallback). The funnel executes the outcome and reads
    // no command predicate itself.
    CloseOutcome closeForCommand(const Command cmd, CommandDoor door, bool reentrant) {
        return commandMeetsTool(cmd, door, reentrant,
            (CommandDoor d) => closeOperation(CloseReason.command, d));
    }

    // After the door (a drop / switch) or after the command applied: marks the
    // row the close wrote, and resumes the tool at most once per command close.
    // Called only from a NON-reentrant frame (opponent R3 C3).
    void finishClose() { tools_.finishClose(); }

    // The history row the last close WROTE, or null when it wrote none — the
    // row slice M4 tags with the closing session's token.
    const(Command) lastClosedRow() const { return tools_.closedRow_.get; }

    // An arm has published the active tool (slice M3; called by the one arm
    // door, `armPreparedTool`, for every arm transition). The session binds
    // the tool — installs the link it reports its gesture steps through — and
    // starts a fresh account: no operation, no steps, no redo.
    void noteArm(string id, ulong token = 0) { tools_.noteArm(id, token); }

    // The session token (slice M4): a fresh one for every arm — the arm's
    // activation row carries it — and the bound tool's current one, which the
    // incoming row records as its predecessor's.
    ulong issueToken() { return tools_.issueToken(); }
    ulong currentToken() { return tools_.currentToken(); }

    // Test introspection (`/api/tool/state`'s `session` member): the operation
    // of a tool whose session owns its steps — `live`, `steps`, `redo` — and
    // JSON null for every other tool.
    JSONValue sessionStateJson() { return tools_.stateJson(); }

    // Discard the active tool's in-progress edit WITHOUT committing it and
    // WITHOUT touching history (cancel bodies are pure mesh restores). The
    // tool.reset path uses this so a reset THROWS the open edit away rather
    // than committing it.
    void discardOpenEdit() {
        auto t = tool_();
        if (t !is null && t.hasUncommittedEdit())
            t.cancelUncommittedEdit();
    }
}

// ---------------------------------------------------------------------------
// ToolSession — the tool session model's core (slice M1,
// doc/tool_session_model_plan_2026-09-24.md R2.5 / R3.5). EditSession owns
// exactly one, privately; it moves the history-navigation branches out of
// `EditSession.navigate` with the branch order unchanged, split by direction.
// Slice M3 gives it the operation of a tool whose policy says `sessionSteps`
// (R2.2, R4.3, R4.5): whether that operation's window is open, the image it
// opened from, the stack of gesture-step images, their redo (H4), and the end
// of the window's first group — with the activation row that group joins when
// the tool was armed through the key/UI door (H1, C-H1-door). Everything it
// stores is keyed to the tool it BOUND at the arm (`noteArm`); what the tool
// reports goes through that link, never through a cast.
// ---------------------------------------------------------------------------
private struct ToolSession {
    private Tool delegate() tool_;
    private CommandHistory  history_;
    private void delegate() dropTool_;
    // The operation's close (slice M2). `topBefore_` is the undo top when the
    // close began; a row counts as written BY the close only if the top is a
    // different entry afterwards — identity, never the depth, which stops
    // moving at the history cap — and that test is the same for every reason
    // (opponent R3 C2: a command close may commit nothing, e.g. a transform
    // between gestures, and must then mark nothing). `pendingMark_`: a door
    // writes the row after `close` returns. `pendingResume_` / `resumeTool_`:
    // the command close committed, so the tool it closed resumes once after
    // the command — and only that tool, so a drop during the command (the
    // tool is gone) or a later tool can never receive it.
    private Rebindable!(const Command) topBefore_;
    private Rebindable!(const Command) closedRow_;
    private bool pendingMark_;
    // The session token (slice M4): issued at every arm (`issueToken`), held
    // by the bound tool's session (`token_`) and written onto the row each
    // close of THAT session writes (`closingToken_`, taken when the close
    // began — a switch's row is marked after the incoming tool was bound).
    private static ulong lastToken_;
    private ulong token_;
    private ulong closingToken_;
    private bool pendingResume_;
    private Tool resumeTool_;

    // ----- the operation of a `sessionSteps` tool (slice M3) ----------------
    // `bound_` / `armedId_`: the tool the last arm published and its id.
    // `live_`: its operation window is open. `openImage_`: the image the window
    // opened from — what undoing its first group restores. `steps_`: the image
    // before each later gesture step, newest last (capped, oldest dropped).
    // `redo_`: the image AFTER each step an undo popped, newest last (H4: a
    // redo returns it live); a new step clears it. `pending_`: the image at the
    // start of the step in flight; `pendingIfChanged_`: it is the rest of the
    // press that armed an `OpensAt.arm` tool, a step only if it changed the image.
    enum size_t kMaxSessionSteps = 256;
    private Tool bound_;
    private string armedId_;
    private bool live_;
    private AttrImage openImage_;
    private AttrImage[] steps_;
    private AttrImage[] redo_;
    // The undo top when `undoFirstGroup_` stashed a group it could not pop
    // with a row (rule K, script door): that stash is valid only while the
    // history has not moved since (review B1) — otherwise its point would be
    // re-seated on a mesh it was never taken on.
    private Rebindable!(const Command) stashAt_;
    private AttrImage pending_;
    private bool pendingSet_;
    private bool pendingIfChanged_;
    // The first group a key-door undo ended together with its activation row
    // (task 7137, §22), held for the NAVIGATE redo of that row — keyed by the
    // row's identity, sealed with the mesh as the redo will find it. Not in
    // the history: a replay from inside `ToolActivationCommand.apply` would run
    // under the history's Suspend state and fire from the raw redo doors too,
    // which re-arm bare by design.
    private AttrImage replay_;
    private Rebindable!(const Command) replayFor_;
    private SessionMeshKey replayKey_;

    this(Tool delegate() tool, CommandHistory history,
         void delegate() dropTool) {
        tool_     = tool;
        history_  = history;
        dropTool_ = dropTool;
    }

    // The contract of the two directions below (in-session record+consolidate
    // Phase 1; carried from EditSession.navigate by slice M1). The STRUCTURE
    // is the invariant: peel → whole-edit cancel → drop-or-survive → stack
    // step → resync, in that order (the branch order can no longer drift
    // apart across three hooks).
    //
    // Gizmo gestures no longer hold an open session at idle: each Move drag
    // commits its own tagged in-session entry on mouse-up (record+consolidate
    // Phase 1), so an idle Move run leaves NOTHING to "cancel" — an undo
    // keystroke just pops the last in-session gesture entry via the plain
    // history.undo() path and resyncSession() re-baselines the still-live
    // tool against the now-current mesh. The residual cancel branch survives
    // ONLY for an open PANEL session (coalesce-until-drop value edits) and an
    // open R/S gizmo session (R/S per-gesture recording lands in a later
    // phase) — both reported by hasUncommittedEdit() ONLY when no drag is
    // active, so a mid-gizmo-drag undo still falls through to history.undo()
    // and never aborts the live drag. The UNDO direction always cancels an
    // open edit; the REDO direction never does (task 0429 — this replaced
    // task 0232's narrow redo-cancel exception): a standing preview's
    // writes invalidate the redo timeline at their own write-points
    // (CommandHistory.invalidateRedo — reference-captured semantics), so a
    // redo pressed while a preview is armed finds an empty redo stack and is
    // a no-op by MECHANISM, with no special branch here; refire-based tools
    // (e.g. BoxTool's live property edit), which report
    // hasUncommittedEdit()==true yet must redo their own param changes, redo
    // exactly as before.
    //
    // A `sessionSteps` tool's live operation is answered FIRST, by the
    // session itself (slice M3): its steps are attribute images here, not
    // tool state, so no branch below ever sees it.
    //
    // NOTE the deliberate RE-READS of tool_() after cancelUncommittedEdit():
    // the absorbed app.d block re-evaluated `activeTool` live at each mention,
    // and that tolerant shape is preserved byte-for-byte — the postcondition
    // assert below is a debug-build DIAGNOSTIC on top, not a replacement.
    //
    // Each returns true if anything happened (edit cancelled OR stack moved).

    bool undo() {
        // A held first group is valid only for the NEXT navigate step after
        // the undo that ended its window; a raw redo in between has already
        // re-armed that row bare.
        replay_ = AttrImage.init;
        replayFor_ = null;
        // H2: the newest gesture step of the live operation, restored as the
        // image it started from; the first group ends the window (H1).
        if (auto t = liveSteps_()) {
            if (steps_.length == 0) return undoFirstGroup_(t);
            redo_ ~= t.captureAttrImage();
            auto img = steps_[$ - 1];
            steps_ = steps_[0 .. $ - 1];
            t.applyAttrImage(img);
            return true;
        }
        auto t = tool_();
        if (t !is null && t.hasUncommittedEdit()) {
            t.cancelUncommittedEdit();
            // NO postcondition assert here — deliberately. The one-shot
            // "cancel ⇒ !hasUncommittedEdit" reading of the base-class
            // comment is FALSE for the primitive live-run family: their
            // cancel body pops ONE recorded live step (history.undo() +
            // early return — the interactive undo LADDER) and legitimately
            // keeps hasUncommittedEdit()==true until the ladder empties.
            // The tolerant re-read below IS the contract: a tool that still
            // reports an open edit after cancel is kept alive so the next
            // undo steps it again; a tool that fully cancelled falls
            // through to the drop branch. (Codifying the stronger claim as
            // an assert aborted the editor on the first box-gesture Ctrl+Z.)
            // Tasks 0400 + 0430: a tool whose policy says `keepAliveOnCancel`
            // (the create family, Mirror) is never dropped by this cancel;
            // every other tool keeps the pre-0400 cancel-then-drop behavior.
            // RE-READ, not the `t` cached above — see the contract above.
            auto t2 = tool_();
            if (t2 !is null && !t2.hasUncommittedEdit()
                && !t2.sessionPolicy().keepAliveOnCancel) {
                dropTool_();
            }
            return true;
        }
        // H1 + the session token (slice M4, gap 218): the record that closed
        // THIS session's first operation is undone together with the
        // activation row it joined, and the row's revert ends the tool.
        // Identity, read BEFORE the step moves the stack: the record's token is
        // the active session's and the row below carries the same token.
        const bool pair = recordCarriesActivation_();
        Rebindable!(const Command) last = undoEntryAt_(pair ? 1 : 0);
        bool ok = history_.undo();
        if (ok && pair && !history_.undo()) {
            // The row refused its undo (review of slice M4): the record is
            // already reverted, so the pair is split. The step taken stands, the
            // resync below re-baselines the tool on the mesh it now sees, and
            // no predecessor was restored — said, not silent.
            import log : logWarn;
            logWarn("tool", "session undo: the activation row paired with the record refused its undo");
            last = null;
        }
        if (ok) {
            // Only AFTER a successful stack step, with no open edit remaining:
            // re-sync the still-live tool's baseline to the now-current mesh.
            auto t3 = tool_();
            if (t3 !is null) t3.resyncSession();
            adoptPredecessorToken_(last);
        }
        return ok;
    }

    bool redo() {
        // H4: a step an undo popped comes back LIVE — the window re-opens if
        // that undo had closed it (the first group of a script-door arm, or a
        // later operation's first group: rule K).
        {
            auto t = tool_();
            if (!live_ && redo_.length && undoTop_() !is stashAt_.get)
                redo_ = null;   // the history moved: the stash is stale
            if (redo_.length && t !is null && t is bound_
                && t.sessionPolicy().sessionSteps) {
                auto cur = t.captureAttrImage();
                if (live_) pushStep_(cur);
                else { openImage_ = cur; live_ = true; }
                auto img = redo_[$ - 1];
                redo_ = redo_[0 .. $ - 1];
                t.applyAttrImage(img);
                return true;
            }
        }
        // Replay only when the redo head IS the activation row this session
        // popped (identity, read before the redo moves it; see undoFirstGroup_).
        bool replay;
        bool pair;
        import commands.tool.lifecycle : ToolActivationCommand;
        Rebindable!(const ToolActivationCommand) act;
        {
            const re = history_.redoEntries();
            replay = !replay_.empty && re.length > 0
                && re[0].cmd is replayFor_.get;
            act = re.length ? cast(const ToolActivationCommand) re[0].cmd : null;
            // The inverse of the undo pair: the row, then the record that
            // carries it (same token), in one redo step (slice M4).
            pair = act !is null && act.carriesFirstRecord() && re.length > 1
                && act.sessionToken() != 0
                && re[1].cmd.sessionToken() == act.sessionToken();
        }
        bool ok = history_.redo();
        // The redo that re-armed a tool re-armed the ROW's session: its token.
        if (ok && act !is null) adoptToken_(act.armedId, act.sessionToken());
        if (ok && pair && !history_.redo()) {
            // The row came back but its record refused (review of slice M4): the
            // tool is armed without the record; the resync below re-baselines it.
            import log : logWarn;
            logWarn("tool", "session redo: the record paired with its activation row refused its redo");
        }
        if (ok) {
            // Only AFTER a successful stack step: re-sync the still-live
            // tool's baseline to the now-current mesh.
            auto t3 = tool_();
            if (t3 !is null) t3.resyncSession();
        }
        // AFTER the redo: it is the redo that arms the tool (its arm binds
        // the fresh instance, `noteArm`), and the replay re-seats the group.
        if (ok && replay) replayFirstGroup_();
        replay_ = AttrImage.init;
        replayFor_ = null;
        return ok;
    }

    // The one close routine (EditSession.closeOperation's body; plan R4.2).
    CloseOutcome close(CloseReason r, CommandDoor door) {
        // A new close starts a new account, whatever an unfinished one left.
        pendingMark_ = false;
        closedRow_ = null;
        auto t = tool_();
        if (t is null) { endOperation_(); return CloseOutcome(false, false); }
        topBefore_ = undoTop_();
        closingToken_ = currentToken();
        if (r != CloseReason.command && r != CloseReason.enter) {
            // The door commits (or discards, or has nothing left); the
            // session only accounts for the row it may write, and the
            // operation ends with the door.
            endOperation_();
            pendingMark_ = r != CloseReason.none;
            return CloseOutcome(false, false);
        }
        const bool command = r == CloseReason.command;
        if (command) {
            const cc = t.sessionPolicy().commandClose;
            // (2) not this tool's door: the funnel keeps its old rules, untouched.
            if (cc == CommandClose.none
                || (door == CommandDoor.script && cc != CommandClose.allDoors))
                return CloseOutcome(false, false);
            // (3) an idle covered tool stays armed and is not called (R20 law).
            if (cc == CommandClose.uiDoor && !t.hasUncommittedEdit())
                return CloseOutcome(false, true);
        }
        // (4) the tool closes its own operation — before a command, or by its
        // own Enter (slice M3) — and the row (if any) is written now,
        // synchronously, BEFORE a command applies and records. Refused before
        // a command, the funnel drops the tool as before; refused on Enter,
        // the tool's own key reads only `closed` and the tool stays.
        const committed = t.commitOperation();
        endOperation_();
        if (!committed) return CloseOutcome(false, false);
        markClosedRow_();
        if (command) {
            pendingResume_ = true;
            resumeTool_ = t;
        }
        return CloseOutcome(true, true);
    }

    void finishClose() {
        if (pendingMark_) { pendingMark_ = false; markClosedRow_(); }
        if (!pendingResume_) return;
        pendingResume_ = false;
        auto t = tool_();
        auto closed = resumeTool_;
        resumeTool_ = null;
        if (t is null || t !is closed) return;   // the closed tool is gone
        // C-rearm-key (gap 370): whether the window re-opens is the PRESET's
        // answer, never the tool's centre mode.
        import tool : ToolFlag;
        t.resumeAfterClose(!t.hasFlag(ToolFlag.NoRearmAfterCommand));
    }

    // ----- the bound tool's reports (slice M3) ------------------------------

    ulong issueToken() { return ++lastToken_; }

    /// The token of the bound tool's session; 0 when the active tool is not
    /// the one the last arm bound (or there is none).
    ulong currentToken() {
        auto t = tool_();
        return t !is null && t is bound_ ? token_ : 0;
    }

    void noteArm(string id, ulong token) {
        auto t = tool_();
        bound_ = t;
        armedId_ = id.idup;
        token_ = token;
        endOperation_();
        if (t is null) return;
        ToolSessionLink link;
        link.stepBegins     = &stepBegins;
        link.stepEnds       = &stepEnds;
        link.operationArmed = &operationArmed;
        link.operationEnded = &operationEnded;
        link.closeOwn       = &closeOwn;
        t.bindSession(link);
        // H1 (slice M3b, C-H1-bev): an `OpensAt.arm` tool whose policy names the
        // attribute its arm raises is APPLIED by the arm, and that apply is the
        // window's first group — the image before it is the group's start. An
        // arm replayed by a history step (Suspend: the redo of an activation
        // row) re-arms bare, like every raw redo door; the navigate redo
        // re-seats the group itself (`replayFirstGroup_`).
        const pol = t.sessionPolicy();
        if (pol.opensAt == OpensAt.arm && pol.armAttr.length
            && history_.state() != UndoState.Suspend) {
            stepBegins(t, PressKind.plain);
            t.applyArmAttr();
            operationArmed(t);
            // No `stepEnds`: the image after the arm IS the pending one, so the
            // arm's own rest is never a step (the next press re-begins).
        }
    }

    void stepBegins(Tool t, PressKind kind) {
        if (!reporting_(t)) return;
        auto before = t.captureAttrImage();
        // H5: an in-window press opens an operation boundary of its kind. The
        // step restores the image the new operation STARTED from — after the
        // reset / clone (H2, 283: C-H5-bev-shift z1 0.0, C-H5-bev-mmb z1 the
        // clone's 0.04; slice M3b).
        if (live_ && kind != PressKind.plain) {
            t.openOperation(kind, before);
            before = t.captureAttrImage();
        }
        pending_ = before;
        pendingSet_ = true;
        pendingIfChanged_ = false;
    }

    void stepEnds(Tool t, bool ifChanged) {
        if (!reporting_(t) || !pendingSet_) return;
        pendingSet_ = false;
        if (!live_) {
            // H1: under `firstPress` this whole gesture is the window's first
            // group; an `arm` tool's window opens only at its arm.
            final switch (t.sessionPolicy().opensAt) {
                case OpensAt.firstPress:
                    live_ = true;
                    openImage_ = pending_;
                    steps_ = null;
                    redo_ = null;
                    return;
                case OpensAt.arm:
                    return;
            }
        }
        if ((pendingIfChanged_ || ifChanged) && t.captureAttrImage() == pending_) return;
        pushStep_(pending_);
        redo_ = null;
    }

    void operationArmed(Tool t) {
        if (!reporting_(t)) return;
        if (t.sessionPolicy().opensAt != OpensAt.arm) return;   // opens at the gesture's end
        // An arm opens a NEW operation: one still counted live here ended
        // without a report (a prepared update disarmed the tool), and none of
        // its steps may leak into this one. The arm is the first group; what
        // the arming press does after it is an ordinary step if it changes
        // anything.
        auto before = pendingSet_ ? pending_ : AttrImage.init;
        endOperation_();
        live_ = true;
        openImage_ = before;
        pending_ = t.captureAttrImage();
        pendingSet_ = true;
        pendingIfChanged_ = true;
    }

    void operationEnded(Tool t) {
        if (reporting_(t)) endOperation_();
    }

    bool closeOwn(Tool t, bool commit) {
        if (t !is tool_()) {
            // Not the active tool (a stale instance): its own body, no account.
            if (commit) return t.commitOperation();
            t.cancelUncommittedEdit();
            return true;
        }
        if (commit) return close(CloseReason.enter, CommandDoor.ui).closed;
        t.cancelUncommittedEdit();
        endOperation_();
        return true;
    }

    // A `sessionStepBegins` for an Action parameter write (C-H2-ls-insert:
    // the write is its own undo step, pushed before it acts). True iff the
    // caller must close it with `stepEnds`.
    bool actionStepBegins(Tool t, string name) {
        if (!reporting_(t)) return false;
        foreach (ref p; t.params())
            if (p.name == name) {
                if (!p.action_) return false;
                stepBegins(t, PressKind.plain);
                return true;
            }
        return false;
    }

    JSONValue stateJson() {
        auto t = tool_();
        if (!reporting_(t)) return JSONValue(null);
        auto j = JSONValue.emptyObject;
        j["live"]  = JSONValue(live_);
        j["steps"] = JSONValue(cast(long) steps_.length);
        j["redo"]  = JSONValue(cast(long) redo_.length);
        j["token"] = JSONValue(cast(long) token_);
        return j;
    }

    private bool reporting_(Tool t) {
        return t !is null && t is bound_ && t is tool_()
            && t.sessionPolicy().sessionSteps;
    }

    private Tool liveSteps_() {
        auto t = tool_();
        return live_ && reporting_(t) ? t : null;
    }

    private void pushStep_(AttrImage img) {
        if (steps_.length >= kMaxSessionSteps) steps_ = steps_[1 .. $];
        steps_ ~= img;
    }

    private void endOperation_() {
        live_ = false;
        openImage_ = AttrImage.init;
        steps_ = null;
        redo_ = null;
        pending_ = AttrImage.init;
        pendingSet_ = false;
        pendingIfChanged_ = false;
    }

    // The undo of the window's first group (H1, 283): back to the image the
    // window opened from. Armed through the key/UI door, the activation row
    // joined that group, so it is popped too — the tool ends through the row's
    // revert and the row goes to redo carrying the group. Any other top is a
    // script-door arm (its own row, gap 300) or a re-arm inside one activation
    // (rule K, verdict K1): the tool stays, armed with nothing, and nothing
    // else is undone; the group waits in the redo stash (H4).
    private bool undoFirstGroup_(Tool t) {
        import commands.tool.lifecycle : ToolActivationCommand;
        auto end = t.captureAttrImage();
        auto open = openImage_;
        endOperation_();
        t.applyAttrImage(open);
        const ue = history_.undoEntries();
        auto act = ue.length ? cast(const ToolActivationCommand) ue[$ - 1].cmd : null;
        if (act is null || !act.joinsFirstGroup() || act.armedId != armedId_) {
            redo_ = [end];
            stashAt_ = undoTop_();
            return true;
        }
        if (act.armedMesh() !is null) replayKey_.stamp(*act.armedMesh());
        replay_ = end;
        replayFor_ = ue[$ - 1].cmd;
        if (!history_.undo()) { replay_ = AttrImage.init; replayFor_ = null; }
        return true;
    }

    // After the navigate redo of the popped activation row re-armed the tool:
    // the group comes back LIVE and released, on the same mesh or not at all.
    private void replayFirstGroup_() {
        import commands.tool.lifecycle : ToolActivationCommand;
        import log : logWarn;
        auto t = tool_();
        if (!reporting_(t)) return;
        auto act = cast(const ToolActivationCommand) replayFor_.get;
        if (act is null || act.armedMesh() is null || !replayKey_.matches(*act.armedMesh())) {
            logWarn("tool", "session redo: the mesh changed since the session ended; re-armed bare");
            return;
        }
        auto open = t.captureAttrImage();
        t.applyAttrImage(replay_);
        live_ = true;
        openImage_ = open;
        steps_ = null;
        redo_ = null;
    }

    private const(Command) undoTop_() {
        const ue = history_.undoEntries();
        return ue.length ? ue[$ - 1].cmd : null;
    }

    // The row the close wrote: the FIRST entry above the undo top the close
    // began at — by identity, never the depth, which stops moving at the
    // history cap. Not the top: after a switch the incoming tool's activation
    // row lands above the row the outgoing door wrote. The row carries the
    // session that wrote it (slice M4, R4.2 N6); the same test for every
    // reason, so a close that wrote nothing marks nothing (opponent R3 C2).
    private void markClosedRow_() {
        import commands.tool.lifecycle : ToolActivationCommand;
        closedRow_ = null;
        const ue = history_.undoEntries();
        size_t first = 0;
        if (topBefore_.get !is null) {
            bool found;
            foreach_reverse (i, ref e; ue)
                if (e.cmd is topBefore_.get) { first = i + 1; found = true; break; }
            if (!found) return;   // trimmed under the cap: nothing is known
        }
        if (first >= ue.length) return;
        const row = ue[first].cmd;
        if (cast(const ToolActivationCommand) row !is null) return;
        closedRow_ = row;
        history_.markEntrySession(row, closingToken_);
    }

    // Apply-and-continue (Shift+click, task 0461) through the session: the
    // tool's in-place commit is a close of its operation — the row it writes
    // carries the session — and the press it continues into opens the next
    // operation as a SHIFT press (H5: the haul attributes reset; slice M4).
    // False — and nothing — when the tool opts out of the in-place commit.
    bool applyAndContinue(Tool t) {
        pendingMark_ = false;
        closedRow_ = null;
        topBefore_ = undoTop_();
        closingToken_ = currentToken();
        if (!t.commitUncommittedEdit()) return false;
        // Re-read (the tolerant discipline of navigate): the commit ran
        // main-thread synchronously, so t is stable, but mirror the pattern.
        auto t2 = tool_();
        if (t2 !is null) t2.resyncSession();
        if (t2 is t) {
            if (t is bound_) endOperation_();
            markClosedRow_();
            t.openOperation(PressKind.shift, t.captureAttrImage());
        }
        return true;
    }

    // Whether the undo top is the record that closed the ACTIVE session's
    // first operation, sitting on the activation row it carries (gap 218).
    private bool recordCarriesActivation_() {
        import commands.tool.lifecycle : ToolActivationCommand;
        const ue = history_.undoEntries();
        if (ue.length < 2) return false;
        const top = ue[$ - 1].cmd;
        const tok = top.sessionToken();
        if (tok == 0 || tok != currentToken()) return false;
        if (cast(const ToolActivationCommand) top !is null) return false;
        auto act = cast(const ToolActivationCommand) ue[$ - 2].cmd;
        return act !is null && act.carriesFirstRecord() && act.sessionToken() == tok;
    }

    private const(Command) undoEntryAt_(size_t fromTop) {
        const ue = history_.undoEntries();
        return ue.length > fromTop ? ue[$ - 1 - fromTop].cmd : null;
    }

    // restorePredecessor (slice M4): undoing an activation row re-armed its
    // predecessor (the row's revert, a replay arm); the restored instance
    // continues the predecessor's SESSION — its token, carried by the row —
    // so the record that closed that session's first operation still pairs
    // with its own activation row (gap 221/241).
    private void adoptPredecessorToken_(const Command undone) {
        import commands.tool.lifecycle : ToolActivationCommand;
        auto act = cast(const ToolActivationCommand) undone;
        if (act is null || act.previousId.length == 0) return;
        adoptToken_(act.previousId, act.previousToken());
    }

    private void adoptToken_(string id, ulong token) {
        auto t = tool_();
        if (token != 0 && t !is null && t is bound_ && armedId_ == id) token_ = token;
    }
}

