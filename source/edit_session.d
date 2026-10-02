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

import tool            : capturedTopologyModel, opensAtArm;
import tool            : Tool, CommandClose, AttrImage, PressKind, OpensAt,
                         StepOrigin, ToolSessionLink, TopologyStepClient;
import command         : Command, CmdFlags;
import std.json        : JSONValue;
import command_history : CommandHistory, UndoState, HistoryFlags;
import held_gesture_buttons : g_heldGestureButtons;
import std.typecons    : Rebindable;
import params          : ParamProvider;
import toolpipe.stage  : Stage;
import tool_activation_ownership : CloseReason, CommandDoor, CloseOutcome, DropContext;
import tools.common.session_mesh_key : SessionMeshKey;
import snapshot : MeshSnapshot;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.gesture_payload : GesturePayload;

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
    private bool toolRefireOwned_ = false;
    private Tool toolRefireOwner_;
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
         void delegate() dropTool,
         void delegate(string) rearmClosedTool = null) {
        assert(tool !is null,     "EditSession: tool accessor required");
        assert(history !is null,  "EditSession: history required");
        assert(dropTool !is null, "EditSession: dropTool verb required");
        tool_     = tool;
        history_  = history;
        dropTool_ = dropTool;
        tools_    = ToolSession(tool, history, dropTool, rearmClosedTool);
    }

    // Computed phase classification (see SessionPhase above).
    SessionPhase phase() {
        auto t = tool_();
        if (t is null) return SessionPhase.NoTool;
        return t.hasUncommittedEdit() ? SessionPhase.EditOpen
                                      : SessionPhase.Idle;
    }

    /// True while `name` of `provider` holds an open widget step.
    bool parameterStepHeld(ParamProvider provider, string name) {
        return tools_.holdsParameter(cast(Object) provider, name);
    }

    /// Close the widget-held parameter step, if it is still open: its widget
    /// deactivated or stopped drawing. See `ToolSession.holdParameter`.
    void releaseParameterStep() { tools_.releaseParameter(); }

    /// Give the active tool family that explicitly opted into frame-driven
    /// parameter observation one tick.  This is independent of whether the
    /// Tool Properties panel is visible.
    void tickParameterEvaluation() {
        auto fc = cast(FrameParameterEvalClient) tool_();
        if (fc !is null) fc.evaluateParameterFrame();
    }

    // ----- live-eval (re-eval plan D4) --------------------------------------

    /// Orchestrate one parameter-change batch after the widget or command has
    /// already written the value. `beforeWrite` carries the image captured by
    /// that pointer-writing producer when a topology step needs its real
    /// start. Call ValueWritten for every actual write, then BatchComplete
    /// exactly once. This keeps notifications per value while grouping
    /// evaluate/live-session work per user gesture.
    ///
    /// A pointer-written stage batch uses both phases; ValueWritten supplies
    /// its notification and, for a slot-selector row, its slot epoch.  An
    /// already-published stage command or stack change instead uses the
    /// compatibility entry below and therefore carries no write-set names.
    void orchestrateParameterChange(ParamProvider provider, string name,
            ParameterChangeSource source, ParameterChangePhase phase,
            AttrImage beforeWrite = AttrImage.init, bool widgetHeld = false) {
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
                        // A held widget (a scrub, a typed edit in progress)
                        // is ONE topology step: open at its first write, closed
                        // by `releaseParameterStep` (captured: a scrub is one row).
                        if (widgetHeld && tools_.holdsParameter(t, name)) {
                            t.notifyInteractiveParamChanged(name);
                            return;
                        }
                        tools_.releaseParameter();
                        const action = tools_.actionStepBegins(t, name);
                        const topology = !action
                            && tools_.topologyParameterStepBegins(t, beforeWrite);
                        t.notifyInteractiveParamChanged(name);
                        if (topology && widgetHeld)
                            tools_.holdParameter(t, name);
                        else if (action || topology)
                            tools_.stepEnds(t, false);
                        return;
                    }
                    case ParameterChangeSource.ScriptedValue: {
                        auto t = cast(Tool)provider;
                        assert(t !is null,
                            "scripted parameter source requires a Tool");
                        tools_.scriptedWriteEndsOperation(t);
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
    private void recordRefireRowAfter_(const Command previous, bool owned) {
        if (!owned || tool_() !is toolRefireOwner_) return;
        const after = history_.undoEntries();
        if (after.length && after[$ - 1].cmd !is previous)
            tools_.recordCompleted(tool_(), after[$ - 1].cmd);
    }

    void refireBegin() {
        const before = history_.undoEntries();
        const Command previous = before.length ? before[$ - 1].cmd : null;
        const owned = toolRefireOwned_;
        history_.refireBegin();
        recordRefireRowAfter_(previous, owned);
        toolRefireOwned_ = false;
        toolRefireOwner_ = null;
    }

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
            toolRefireOwned_ = true;
            toolRefireOwner_ = tool_();
        }
        return true;
    }

    // Close the refire block: refireEnd() lands the session's single entry;
    // then — ONLY after refireEnd(), the call order encodes the P4 contract —
    // if the session was driving an opted-in tool, tell it the entry has
    // landed so its commit chokepoint (deactivate/Apply) records nothing for
    // the same edit.
    void refireEnded() {
        const before = history_.undoEntries();
        const Command previous = before.length ? before[$ - 1].cmd : null;
        const owned = toolRefireOwned_;
        history_.refireEnd();
        recordRefireRowAfter_(previous, owned);
        toolRefireOwned_ = false;
        toolRefireOwner_ = null;
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

    bool terminalRedoRequested() const { return tools_.terminalRedoRequested(); }

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
    //
    // `dropRow` (wave plan 8640 S6): the drop door's answer, decided before
    // the door runs — the tool's `dropWritesRow` policy and
    // `dropWritesRowFor(transition)`. The row is written by `finishClose`,
    // after the door, through the factory the app installs (`installDropRows`).
    CloseOutcome closeOperation(CloseReason r, CommandDoor door = CommandDoor.ui,
                                bool dropRow = false,
                                DropContext ctx = DropContext.init) {
        // No command close while a mouse button is held — the held-button rule
        // `navigate` applies (slice M1a): refused, the tool is not called, and
        // the funnel keeps its pre-M2 rules. A door's close is the door's and
        // runs regardless, so its account is kept.
        // The refusal also drops a drop row an aborted drop left pending
        // (S6), so the funnel's `finishClose` cannot write it late.
        if (r == CloseReason.command && g_heldGestureButtons.any) {
            tools_.pendingDropRow_ = false;
            return CloseOutcome(false, false);
        }
        return tools_.close(r, door, dropRow, ctx);
    }

    /// S6: a drop door that failed after its `closeOperation` abandons the
    /// drop row that close took — the tool was not dropped.
    void abandonDropRow() { tools_.pendingDropRow_ = false; }

    /// S6: the factories of a drop row (a `ToolActivationCommand` with no
    /// armed tool) and of the Esc rung's empty task row, installed by the app
    /// (they need its mesh, view and arm/drop verbs).
    void installDropRows(Command delegate(const DropRowSpec) dropRow,
                         Command delegate() taskRow) {
        tools_.dropRowFactory_ = dropRow;
        tools_.taskRowFactory_ = taskRow;
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

    /// Headless tool.doApply is recorded by CommandExecutor, rather than by
    /// the tool's gesture writer. Give that same history row to ToolSession.
    void recordAppliedToolCommand(Command cmd) {
        tools_.recordCompleted(tool_(), cmd);
    }

    // The history row the last close WROTE, or null when it wrote none — the
    // row slice M4 tags with the closing session's token.
    const(Command) lastClosedRow() const { return tools_.closedRow_.get; }

    // An arm has published the active tool (slice M3; called by the one arm
    // door, `armPreparedTool`, for every arm transition). The session binds
    // the tool — installs the link it reports its gesture steps through — and
    // starts a fresh account: no operation, no steps, no redo.
    void noteArm(string id, ulong token = 0, bool postmodeArmed = true) {
        tools_.noteArm(id, token, postmodeArmed);
    }

    /// A selected pipe stage may be waiting for its first viewport press.
    void notePointerDown() { tools_.notePointerDown(); }

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
/// The dormant postmode records an attribute adjustment without a mesh image;
/// command history owns the completed before/after image. Both directions are
/// a no-op SUCCESS when the tool is gone (a later command dropped it, e.g. a
/// select.invert under Mirror): a refused redo would strand every row above
/// it (topology-redo S2b fix, `mirror_cmdclose_ui` R-tail; revertImpl's rule).
/// Written only into the instance that recorded it (`instance_`); in any other
/// it is an orphan and writes nothing (law 4, model doc §R9).
private class TopologyAdjustmentEdit : Command, GesturePayload {
    private Tool delegate() currentTool_;
    private ulong instance_;
    private AttrImage before_, after_;

    this(Command context, ulong instance, Tool delegate() currentTool,
            AttrImage before, AttrImage after) {
        super(context.meshPtr(), context.viewRef(), context.editModeVal());
        instance_ = instance;
        currentTool_ = currentTool;
        before_ = before;
        after_ = after;
        noteUndoRecorded();
    }
    override string name() const { return "tool.topology_adjustment"; }
    override string label() const { return "Tool Adjustment"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }
    override bool hasGesturePayload() const { return !before_.opEquals(after_); }
    ulong instance() const { return instance_; }
    AttrImage before() const { return AttrImage(before_.names.dup, before_.raw.dup); }
    protected override bool applyImpl() {
        if (auto t = recorder_()) t.applyAttrImage(after_);
        return true;
    }
    protected override void revertImpl() {
        if (auto t = recorder_()) t.applyAttrImage(before_);
    }
    private Tool recorder_() {
        auto t = currentTool_();
        return t !is null && t.preparedLifecycleOwner().value == instance_ ? t : null;
    }
}

/// What a drop row records (wave plan 8640 S6): the dropped tool, the session
/// token its undo hands back, and the drop context. No attribute-image term:
/// the undo's replay arm restores the dropped tool's attributes from the
/// preset attribute cache, which keeps them at the drop.
struct DropRowSpec {
    string previousId;
    ulong previousToken;
    DropContext ctx;
}

/// What a navigation saw BEFORE it ran: the undo depth, so the settle after
/// it keys on the stack having MOVED (a cancelled live edit answers `true`
/// with no movement); the session token and whether a bound model tool's
/// post mode was armed — the settle's "same session, armed before"
/// (topology-redo S2b, model doc §2.4).
private struct NavBefore {
    size_t depth;
    ulong token;
    bool armed;
}

private struct ToolSession {
    private Tool delegate() tool_;
    private CommandHistory  history_;
    private void delegate() dropTool_;
    private void delegate(string) rearmClosedTool_;
    private Rebindable!(const Command) terminalClosedRunRow_;
    private size_t terminalClosedRunDepth_;
    private bool terminalClosedRunArmed_;
    private bool terminalRedoRequested_;
    private bool postmodeArmed_ = true;
    private NavBefore navBefore_;
    // The operation of a captured-model tool (topology-redo S2b, model doc §2.3):
    // `operation_` the current one (0 = none), `nextOperation_` its counter,
    // `operationOpen_` "the next write refires it". Written ONLY by noteArm,
    // stepEnds, settleAfterNavigation_ and scriptedWriteEndsOperation — never
    // by endOperation_ / close / closeOwn (a right tap is no close, §1.3).
    // `postmodeOpenAtPress_`: the post mode before the press that is
    // running; `topologyPendingKind_` its kind; `topologyPendingAttrOnly_`:
    // the step in flight is an attribute-only row (dormant, or a write while
    // the post mode is not armed — model doc §R6.1).
    private ulong operation_;
    private ulong nextOperation_;
    private bool operationOpen_;
    private bool postmodeOpenAtPress_;
    private PressKind topologyPendingKind_;
    private bool topologyPendingAttrOnly_;
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
    // S6: a drop that writes a drop row — taken at `close`, before the door
    // destroys the tool; written by `finishClose`, after the door.
    private bool pendingDropRow_;
    private DropRowSpec pendingDrop_;
    private Command delegate(const DropRowSpec) dropRowFactory_;
    private Command delegate() taskRowFactory_;

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
    // Only an in-flight topology image lives here. Completed
    // images, attributes and preview bases belong to history commands.
    private MeshSnapshot topologyPendingMesh_;
    private MeshSnapshot topologyPendingBasis_;
    private AttrImage topologyPendingAttrs_;
    private bool topologyPendingPress_;
    // The last recorded topology row's `after`, reused as the next step's
    // before and a no-op row's after when `matches` says the mesh still is
    // that image, so a motionless press shares storage instead of holding two
    // fresh copies (~25 MB a row on a 50k-vertex mesh). Sound because
    // `MeshSnapshot.restore` copies and no code writes a snapshot in place;
    // released with the operation. Wave plan 8646 §9.25 [A13-2].
    private MeshSnapshot lastAfter_;
    // The base of the operation a captured-model tool opens next (topology-redo
    // S3, model doc §R6.2): set where an operation ENDS with the tool still bound
    // (`rebaseOnCurrent_`) and seeded by the arm; an opening press rebases it
    // only when the mesh moved since (`notePointerDown`).
    private MeshSnapshot baseImage_;
    private struct TopologyAttrOwner {
        string id;
        ulong token;
        AttrImage attrs;
    }
    // Completed mesh images remain history-owned. Retained raw attributes are
    // keyed by the tool identity AND the session that produced them, so a
    // lifecycle undo can restore its predecessor without ever feeding the
    // incoming tool's foreign parameter names through Tool.writeRaw.
    private TopologyAttrOwner[] topologyAttrOwners_;
    private bool topologyPending_;
    private Rebindable!(const Command) dormantActivation_;
    private bool topologyDormant_;
    private bool topologyFirstGroupLive_;
    private bool redoneTopologyStep_;
    private bool closedTopologyRedo_;
    private Rebindable!(const Command) closedTopologyRedoSource_;
    private string closedTopologyId_;
    private ulong closedTopologyToken_;
    // The first group a key-door undo ended together with its activation row
    // (task 7137, §22), held for the NAVIGATE redo of that row — keyed by the
    // row's identity, sealed with the mesh as the redo will find it. Not in
    // the history: a replay from inside `ToolActivationCommand.apply` would run
    // under the history's Suspend state and fire from the raw redo doors too,
    // which re-arm bare by design.
    private AttrImage replay_;
    private Rebindable!(const Command) replayFor_;
    private SessionMeshKey replayKey_;
    // The OPEN BLOCK of a `foldsParamRowsIntoBlock` session (wave plan 8640
    // S7a, §9.19.3, §9.22.1, §9.26.4): the row the session's open step folds
    // into — the activation row of a key/UI-door arm, then each press row; or,
    // after a navigation cleared it, the first parameter row written since
    // (the base of an open step of its own). A press row or a switch / drop
    // closes the open step: the parameter rows written above the block are
    // marked `JoinsBelow`. An
    // undo clears it (L41); the redo of a press reopens that press (L42), the
    // redo of a parameter row the press or activation below it (L55). A
    // script-door arm opens nothing (C1-F3).
    private Rebindable!(const Command) openBlock_;

    this(Tool delegate() tool, CommandHistory history,
         void delegate() dropTool,
         void delegate(string) rearmClosedTool) {
        tool_     = tool;
        history_  = history;
        dropTool_ = dropTool;
        rearmClosedTool_ = rearmClosedTool;
    }

    bool terminalRedoRequested() const { return terminalRedoRequested_; }

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
    // A `sessionSteps` tool's live operation is answered FIRST. Attribute
    // steps use the session stack; topology steps use history
    // commands with mesh, attrs and basis, via the same navigation door.
    //
    // NOTE the deliberate RE-READS of tool_() after cancelUncommittedEdit():
    // the absorbed app.d block re-evaluated `activeTool` live at each mention,
    // and that tolerant shape is preserved byte-for-byte — the postcondition
    // assert below is a debug-build DIAGNOSTIC on top, not a replacement.
    //
    // Each returns true if anything happened (edit cancelled OR stack moved).

    // The two navigation doors: the step itself, then — after a redo — the
    // parameter-row prune once the history is Active again (wave plan 8640
    // S7a, §9.17.5 [A6-n8]; the undo door's prune was inert, amendment A16).
    // Any navigation re-keys the open block: an undo closes it (L41); a redo
    // reopens only what its own step says (`navigateTopology_`, L42/L55).
    // `armed` after a navigation is ONE assignment (`settleAfterNavigation_`),
    // asked of the tool bound AFTER the step — the step itself re-binds it
    // (an activation's undo re-arms the predecessor, its redo re-arms the row's
    // tool). Task 8920, law 1; model doc §2.4.
    bool undo() {
        navBefore_ = NavBefore(history_.undoEntries().length, token_,
                               boundModel_() && postmodeArmed_);
        const r = undoImpl_();
        if (r) openBlock_ = null;
        if (r && history_.undoEntries().length != navBefore_.depth)
            settleAfterNavigation_(true);
        return r;
    }

    bool redo() {
        navBefore_ = NavBefore(history_.undoEntries().length, token_,
                               boundModel_() && postmodeArmed_);
        auto block = openBlock_;
        openBlock_ = null;
        const r = redoImpl_();
        if (r) pruneRedoTop_();
        else openBlock_ = block;
        if (r && history_.undoEntries().length != navBefore_.depth)
            settleAfterNavigation_(false);
        return r;
    }

    // The post mode is open after a navigation exactly when the undo top is
    // the bound model tool's own opener. A tool outside the model keeps the
    // value its replay arm wrote. The operation stays open only for the SAME
    // session armed before (N1/N2/N4: it is the moved row's operation); a
    // re-begin (N5/N6) and every other case leave it closed — the next press
    // opens a new one (topology-redo S2b, model doc §2.4).
    private void settleAfterNavigation_(bool isUndo) {
        const aModel = boundModel_();
        const aToken = aModel ? token_ : 0;
        const armedAfter = aModel && ownOpenerOnTop_(aToken);
        if (aModel) postmodeArmed_ = armedAfter;
        const same = aModel && navBefore_.armed && aToken == navBefore_.token;
        operationOpen_ = aModel && same && armedAfter;
        if (operationOpen_)
            operation_ = isUndo ? headOfRedoOperation_(aToken) : topOperation_(aToken);
        // A re-begin and every closed case end the operation here (N3/N5/N6):
        // the next one is based on the image the navigation left.
        if (aModel && !operationOpen_) rebaseOnCurrent_(tool_(), false);
    }

    // The base of a new operation := the live image (topology-redo S3, model doc
    // §R6.2). Called where an operation ends with its tool still bound, and —
    // `ifStale` — on the opening press, only when the mesh moved since the base
    // was taken. The tool's rebase body writes no mesh when the base matches it.
    private void rebaseOnCurrent_(Tool t, bool ifStale) {
        if (t is null || !reporting_(t) || !capturedTopologyModel(t.sessionPolicy())) return;
        auto c = cast(TopologyStepClient) t;
        if (c is null) return;
        auto m = c.topologyStepMesh();
        if (m is null) return;
        if (ifStale && baseImage_.filled && baseImage_.matches(*m)) return;
        baseImage_ = MeshSnapshot.capture(*m);
        c.rebaseTopologyStep(baseImage_);
    }

    // The operation of the row an undo just took off (the head of the redo
    // stack; a folded group's rows share it) / a redo just put back (the undo
    // top) — when it is session `tok`'s topology step; else unchanged.
    private ulong headOfRedoOperation_(ulong tok) {
        const re = history_.redoEntries();
        return stepOperationOf_(re.length ? re[0].cmd : null, tok);
    }

    private ulong topOperation_(ulong tok) {
        return stepOperationOf_(undoTop_(), tok);
    }

    private ulong stepOperationOf_(const Command row, ulong tok) {
        if (auto step = cast(const MeshSessionEdit) row)
            if (step.isTopologyStep() && step.sessionToken() == tok)
                return step.stepOperation();
        return operation_;
    }

    private bool boundModel_() {
        auto t = tool_();
        return t !is null && t is bound_ && capturedTopologyModel(t.sessionPolicy());
    }

    // The undo top opens session `tok`'s post mode: its topology step, or —
    // until the begin row exists — the activation of a tool that opens at
    // the arm.
    private bool ownOpenerOnTop_(ulong tok) {
        import commands.tool.lifecycle : ToolActivationCommand;
        const top = undoTop_();
        if (auto step = cast(const MeshSessionEdit) top)
            return step.isTopologyStep() && step.sessionToken() == tok;
        auto t = tool_();
        if (t !is null && opensAtArm(t.sessionPolicy()))
            if (auto act = cast(const ToolActivationCommand) top)
                return act.sessionToken() == tok;
        return false;
    }

    private bool undoImpl_() {
        terminalRedoRequested_ = false;
        // Task 8261, e001/e005: two retained adjustment rows are visible
        // after close, yet one outside Undo restores the run-start image.
        // Their tag and run identity are history-owned, so this works for any
        // producer that explicitly opts into visible closed rows.
        const ueClosed = history_.undoEntries();
        if (tool_() is null && ueClosed.length &&
            (ueClosed[$ - 1].flags & HistoryFlags.ClosedRun)) {
            const stepUndo = (ueClosed[$ - 1].flags & HistoryFlags.ClosedStep) != 0;
            const keepRedo = stepUndo ||
                (ueClosed[$ - 1].flags & HistoryFlags.ClosedGroupRedo) != 0;
            const token = ueClosed[$ - 1].cmd.sessionToken();
            const ownerId = ueClosed[$ - 1].closedOwnerId;
            size_t count;
            foreach_reverse (entry; ueClosed) {
                if (!entry.sameClosedNavigation(ueClosed[$ - 1])) break;
                ++count;
                if (stepUndo) break;
            }
            if (count == 0 || rearmClosedTool_ is null || ownerId.length == 0)
                return false;
            foreach (_; 0 .. count)
                if (!history_.undo()) return false;
            if (!keepRedo) history_.invalidateRedo();
            history_.replayWithoutRecord(() => rearmClosedTool_(ownerId));
            // The replay arm continues this closed run's session even when
            // maxDepth has evicted its original activation row. Keep its token
            // across the next gesture so a C branch can close and undo too.
            adoptToken_(ownerId, token);
            if (!keepRedo) {
                terminalClosedRunRow_ = undoTop_();
                terminalClosedRunDepth_ = history_.undoEntries().length;
                terminalClosedRunArmed_ = true;
            }
            return true;
        }
        // A held first group is valid only for the NEXT navigate step after
        // the undo that ended its window; a raw redo in between has already
        // re-armed that row bare.
        replay_ = AttrImage.init;
        replayFor_ = null;
        if (navigateRecorded_(true)) return true;
        if (navigateTopology_(true)) return true;
        if (topologyDormant_) {
            const ue = history_.undoEntries();
            if (ue.length >= 2 &&
                cast(const TopologyAdjustmentEdit)ue[$ - 1].cmd !is null &&
                ue[$ - 2].cmd is dormantActivation_.get) {
                auto drop = dropImage_(1);
                if (history_.undo()) {
                    storeDropImage_(drop);
                    history_.undo();
                    return true;
                }
            }
        }
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
        // The Edge first step is a separate row. Its undone branch is erased
        // when the activation itself is undone, leaving that activation as
        // the only redo candidate. The policy states the first-group law;
        // history remains the sole owner of completed mesh images.
        if (t !is null && topologyFirstGroupLive_ &&
            t.sessionPolicy().discardFirstTopologyRedoOnActivationUndo) {
            import commands.tool.lifecycle : ToolActivationCommand;
            auto act = cast(const ToolActivationCommand)undoTop_();
            const re = history_.redoEntries();
            if (act !is null && re.length > 0 &&
                re[0].cmd.sessionToken() == act.sessionToken() &&
                cast(const MeshSessionEdit)re[0].cmd !is null)
                history_.invalidateRedo();
            if (act !is null) topologyFirstGroupLive_ = false;
        }
        // Once a topology step has ended, its mesh image belongs
        // to history even though the tool may retain `built` parameters for
        // command-close policy. A foreign row above that image must reach the
        // stack; the legacy cancel hook is only first responder while this
        // session still owns a pending topology image.
        const completedTopologyIsHistoryOwned = reporting_(t) &&
            t.sessionPolicy().historyTopologySteps && !topologyPending_;
        if (t !is null && t.hasUncommittedEdit() &&
            !completedTopologyIsHistoryOwned) {
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
        // M-G (wave plan 8640 S7a, [A2-3]): the parameter rows folded into the
        // activation pop with it, through this same tail. Exclusive with the
        // pair: the pair's record is a press row, never folded.
        const size_t run = absorbedRunAbove_();
        assert(!(pair && run), "session undo: a carried record and a folded run on one activation");
        const size_t extra = pair ? 1 : run;
        Rebindable!(const Command) last = undoEntryAt_(extra);
        // A lifecycle row may restore the topology tool that preceded it.
        // Resolve the raw image by that predecessor's identity/session, never
        // from the incoming tool currently bound to the session.
        import commands.tool.lifecycle : ToolActivationCommand;
        auto activation = cast(const ToolActivationCommand)last.get;
        // Law 4: this session's activation drops the tool with its rows.
        auto drop = activation !is null &&
                activation.sessionToken() == currentToken()
            ? dropImage_(extra) : DropImage.init;
        auto topologyRestore = activation !is null &&
                activation.previousHistoryTopology()
            ? topologyAttrsFor_(activation.previousId(), activation.previousToken())
            : AttrImage.init;
        bool ok = history_.undo();
        if (ok) storeDropImage_(drop);
        foreach (_; 0 .. ok ? extra : 0) {
            if (history_.undo()) continue;
            // The row refused its undo (review of slice M4): the record is
            // already reverted, so the pair is split. The step taken stands, the
            // resync below re-baselines the tool on the mesh it now sees, and
            // no predecessor was restored — said, not silent.
            import log : logWarn;
            logWarn("tool", "session undo: the activation row paired with the record refused its undo");
            last = null;
            break;
        }
        if (ok) {
            if (last.get is closedTopologyRedoSource_.get)
                clearClosedTopologyRedo_();
            // Only AFTER a successful stack step, with no open edit remaining:
            // re-sync the still-live tool's baseline to the now-current mesh.
            // An attribute-only row restored its exact image and has no mesh
            // basis to re-sync — doing so would reset its parameters (the redo
            // door's rule; topology-redo S2b: such a row now also stands outside dormant).
            auto t3 = tool_();
            const re3 = history_.redoEntries();
            if (t3 !is null && !(re3.length &&
                    cast(const TopologyAdjustmentEdit) re3[0].cmd !is null))
                t3.resyncSession();
            adoptPredecessorToken_(last);
            if (t3 !is null && activation !is null &&
                activation.previousHistoryTopology() &&
                !topologyRestore.empty) {
                // M-H: the restored predecessor is a fresh instance; what it
                // was given is what the session remembers.
                auto img = navigableAttrs_(t3, null, topologyRestore);
                t3.restoreRecordedAttrs(img);
                rememberTopologyAttrs_(img);
            }
        }
        return ok;
    }

    private bool redoClosedRecordedStep_() {
        // Task 8530: closed rows retain their navigation policy and owner.
        // A step replays one row; a retained group replays its contiguous run.
        // Both restore through the same activation/token ownership path.
        const entries = history_.redoEntries();
        if (!entries.length || rearmClosedTool_ is null) return false;
        const first = entries[0];
        const grouped = (first.flags & HistoryFlags.ClosedGroupRedo) != 0;
        if ((!grouped && (tool_() !is null ||
                !(first.flags & HistoryFlags.ClosedStep))) ||
            first.closedOwnerId.length == 0) return false;
        const ownerId = first.closedOwnerId.idup;
        const token = first.cmd.sessionToken();
        size_t count = 1;
        if (grouped) {
            count = 0;
            foreach (entry; entries) {
                if (!entry.sameClosedNavigation(first)) break;
                ++count;
            }
        }
        foreach (_; 0 .. count)
            if (!history_.redo()) return false;
        history_.replayWithoutRecord(() => rearmClosedTool_(ownerId));
        adoptToken_(ownerId, token);
        return true;
    }

    private bool redoImpl_() {
        terminalRedoRequested_ = false;
        if (redoClosedRecordedStep_()) return true;
        if (history_.redoEntries().length == 0 &&
            terminalClosedRunArmed_ &&
            history_.undoEntries().length == terminalClosedRunDepth_ &&
            undoTop_() is terminalClosedRunRow_.get) {
            terminalRedoRequested_ = true;
            return false;
        }
        if (navigateRecorded_(false)) return true;
        if (navigateTopology_(false)) return true;
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
            pair = act !is null && !act.dormantTopology() &&
                act.carriesFirstRecord() && re.length > 1
                && act.sessionToken() != 0
                && re[1].cmd.sessionToken() == act.sessionToken();
        }
        bool ok = history_.redo();
        // The redo that re-armed a tool re-armed the ROW's session: its token.
        if (ok && act !is null) adoptToken_(act.armedId, act.sessionToken());
        // M-G: the parameter rows folded into this activation come back with
        // it, as one step; none of their attributes is restored (C1-F2
        // F-preset: the re-armed instance keeps its arm image).
        if (ok && act !is null && !pair) {
            // The run above the activation is its own fold, of its token
            // (A16 R5), so no token term.
            for (auto re = history_.redoEntries(); re.length &&
                    (re[0].flags & HistoryFlags.JoinsBelow);
                    re = history_.redoEntries())
                if (!history_.redo()) break;
        }
        if (ok && act !is null && act.previousHistoryTopology()) {
            closedTopologyId_ = act.previousId().idup;
            closedTopologyToken_ = act.previousToken();
        }
        if (ok && act !is null &&
            (redoneTopologyStep_ || act.previousHistoryTopology())) {
            closedTopologyRedo_ = true;
            closedTopologyRedoSource_ = act;
        }
        if (ok && pair && !history_.redo()) {
            // The row came back but its record refused (review of slice M4): the
            // tool is armed without the record; the resync below re-baselines it.
            import log : logWarn;
            logWarn("tool", "session redo: the record paired with its activation row refused its redo");
        }
        if (ok && pair) {
            auto rearmed = tool_();
            if (rearmed !is null && rearmed.sessionPolicy()
                    .discardLaterTopologyRedoOnRearm)
                history_.invalidateRedo();
        }
        if (ok) {
            // Only AFTER a successful stack step: re-sync the still-live
            // tool's baseline to the now-current mesh. An attribute-only
            // topology row already restored its exact image and has no mesh
            // basis to re-sync; doing so would reset its parameters.
            auto t3 = tool_();
            if (t3 !is null && cast(const TopologyAdjustmentEdit)
                    history_.undoEntries()[$ - 1].cmd is null)
                t3.resyncSession();
        }
        if (ok && act !is null) {
            // Law 4: every redo that re-creates the instance (a bare activation
            // as well as the pair) takes its session's seed, after the resync;
            // an attribute row redone with it is an orphan in it (9020 PF-A).
            auto t = tool_();
            if (reporting_(t) && capturedTopologyModel(t.sessionPolicy())) {
                auto seed = seedRecreated_(act.get, null);
                if (!seed.empty) {
                    t.restoreRecordedAttrs(seed);
                    rememberTopologyAttrs_(seed);
                }
            }
        }
        // AFTER the redo: it is the redo that arms the tool (its arm binds
        // the fresh instance, `noteArm`), and the replay re-seats the group.
        if (ok && replay) replayFirstGroup_();
        replay_ = AttrImage.init;
        replayFor_ = null;
        return ok;
    }

    // The one close routine (EditSession.closeOperation's body; plan R4.2).
    CloseOutcome close(CloseReason r, CommandDoor door, bool dropRow = false,
                       DropContext ctx = DropContext.init) {
        // A new close starts a new account, whatever an unfinished one left.
        pendingMark_ = false;
        pendingDropRow_ = false;
        closedRow_ = null;
        auto t = tool_();
        if (t is null) { endOperation_(); return CloseOutcome(false, false); }
        topBefore_ = undoTop_();
        closingToken_ = currentToken();
        if (dropRow && r == CloseReason.drop && t is bound_ && armedId_.length) {
            pendingDropRow_ = true;
            pendingDrop_ = DropRowSpec(armedId_.idup, closingToken_, ctx);
        }
        topologyFirstGroupLive_ = false;
        if (topologyPending_ && reporting_(t) &&
            t.sessionPolicy().historyTopologySteps)
            stepEnds(t, false);
        // A switch or a drop closes the open step (L38/L45; a drop by the
        // switch rule, gap t): the fold walk, before the lifecycle row lands.
        if ((r == CloseReason.switch_ || r == CloseReason.drop) && reporting_(t)
            && t.sessionPolicy().foldsParamRowsIntoBlock) {
            foldOpenRows_(null);
            openBlock_ = null;
        }
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
            // L57 (capture C5; plan amendment A17): a recording command
            // reaching this tool's close ends the post-mode session, so it
            // closes the open step by the switch rule (L38) — selection and
            // model commands alike — and the tool stays armed.
            if (reporting_(t) && t.sessionPolicy().foldsParamRowsIntoBlock) {
                foldOpenRows_(null);
                openBlock_ = null;
            }
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
        if (t.sessionPolicy().historyTopologySteps)
            rememberTopologyAttrs_(t.captureAttrImage());
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
        if (pendingDropRow_) { pendingDropRow_ = false; recordDropRow_(); }
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
        if (t.sessionPolicy().historyTopologySteps)
            rememberTopologyAttrs_(t.captureAttrImage());
    }

    // ----- the bound tool's reports (slice M3) ------------------------------

    ulong issueToken() { return ++lastToken_; }

    /// The token of the bound tool's session; 0 when the active tool is not
    /// the one the last arm bound (or there is none).
    private ulong recordTokenFor_(Tool source) {
        return source is bound_ ? currentToken() : 0;
    }

    ulong currentToken() {
        auto t = tool_();
        return t !is null && t is bound_ ? token_ : 0;
    }

    void noteArm(string id, ulong token, bool postmodeArmed = true) {
        auto t = tool_();
        bound_ = t;
        armedId_ = id.idup;
        token_ = token;
        postmodeArmed_ = postmodeArmed;
        endOperation_();
        if (t is null) return;
        import commands.tool.lifecycle : ToolActivationCommand;
        auto arm = cast(ToolActivationCommand)undoTop_();
        if (history_.state() == UndoState.Suspend &&
            (arm is null || arm.armedId() != id)) {
            // During an undo the reverted row is off the undo stack, while
            // its redo entry is not installed until revertImpl returns. A
            // restored predecessor is already the undo top. During a redo
            // the activating row is still the redo head instead.
            const re = history_.redoEntries();
            arm = re.length ? cast(ToolActivationCommand)re[0].cmd : null;
        }
        AttrImage closedAttrs;
        if (history_.state() != UndoState.Suspend &&
            validClosedTopologyRedo_(arm, id))
            closedAttrs = topologyAttrsFor_(id, closedTopologyToken_);
        topologyDormant_ = t.sessionPolicy().dormantAfterClosedRedo &&
            (history_.state() == UndoState.Suspend
                ? arm !is null && arm.armedId() == id && arm.dormantTopology()
                : !closedAttrs.empty);
        if (topologyDormant_ && arm !is null) {
            if (history_.state() != UndoState.Suspend) arm.markDormantTopology();
            dormantActivation_ = arm;
        }
        // The operation belongs to the token (topology-redo S2b, model doc §2.3): every
        // arm — a history step's replay arm too — starts its own, open at the
        // arm only for a tool that opens there; the settle after a navigation
        // then rewrites it.
        operationOpen_ = capturedTopologyModel(t.sessionPolicy())
            && opensAtArm(t.sessionPolicy()) && !topologyDormant_;
        operation_ = operationOpen_ ? ++nextOperation_ : 0;
        if (history_.state() != UndoState.Suspend)
            topologyFirstGroupLive_ = t.sessionPolicy().historyTopologySteps
                && !topologyDormant_;
        if (history_.state() != UndoState.Suspend) {
            clearClosedTopologyRedo_();
            redoneTopologyStep_ = false;
        }
        // A new session's open block is its own key/UI-door activation row
        // (`joinsFirstGroup`); a script-door arm, and an arm replayed by a
        // history step, open none (C1-F3; §9.19.3).
        openBlock_ = null;
        if (history_.state() != UndoState.Suspend && arm !is null &&
            t.sessionPolicy().foldsParamRowsIntoBlock && arm.armedId() == id &&
            arm.joinsFirstGroup() && arm.sessionToken() == token)
            openBlock_ = arm;
        ToolSessionLink link;
        // The tool's own door is the only PRESS (plan 8646 [R2-2]): every
        // internal `stepBegins` passes `press: false`.
        link.stepBegins     = (Tool t, PressKind k) =>
            stepBegins(t, k, AttrImage.init, true);
        link.stepEnds       = &stepEnds;
        link.stepOpenImage  = &stepOpenImage_;
        link.operationArmed = &operationArmed;
        link.operationEnded = &operationEnded;
        link.closeOwn       = &closeOwn;
        link.recordCompleted = &recordCompleted;
        link.tagPreparedCompleted = &tagPreparedCompleted;
        link.recordToken = &recordTokenFor_;
        link.previewGated = &previewGated;
        t.bindSession(link);
        auto ownedAttrs = topologyAttrsFor_(id, token);
        if (topologyDormant_ && ownedAttrs.empty)
            ownedAttrs = closedAttrs;
        if (t.sessionPolicy().historyTopologySteps && topologyDormant_ &&
            !ownedAttrs.empty)
            t.restoreRecordedAttrs(ownedAttrs);
        // A lifecycle replay binds a fresh instance before navigate() can
        // finish the stack step. Preserve any image already owned by this
        // exact session; a new arm (or an unremembered replay) seeds one.
        if (t.sessionPolicy().historyTopologySteps &&
            (history_.state() != UndoState.Suspend || ownedAttrs.empty || topologyDormant_))
            rememberTopologyAttrs_(t.captureAttrImage());
        // The arm's own base is the tool's `activate`; the session only records
        // the image it was taken on. Dormant: left empty, so the first press of
        // the dormant arm still rebases (`notePointerDown`: an unfilled base is stale).
        baseImage_ = MeshSnapshot.init;
        if (auto client = cast(TopologyStepClient)t) {
            client.setTopologyDormant(topologyDormant_);
            if (capturedTopologyModel(t.sessionPolicy()) && !topologyDormant_)
                if (auto m = client.topologyStepMesh())
                    baseImage_ = MeshSnapshot.capture(*m);
        }
        if (t.sessionPolicy().historyTopologySteps &&
            t.sessionPolicy().opensAt == OpensAt.arm && !topologyDormant_) {
            live_ = true;
            openImage_ = t.captureAttrImage();
        }
        // H1 (slice M3b, C-H1-bev): an `OpensAt.arm` tool whose policy names the
        // attribute its arm raises is APPLIED by the arm, and that apply is the
        // window's first group — the image before it is the group's start. An
        // arm replayed by a history step (Suspend: the redo of an activation
        // row) re-arms bare, like every raw redo door; the navigate redo
        // re-seats the group itself (`replayFirstGroup_`).
        const pol = t.sessionPolicy();
        if (pol.opensAt == OpensAt.arm && pol.armAttr.length
            && history_.state() != UndoState.Suspend) {
            stepBegins(t, PressKind.plain, AttrImage.init, false);
            t.applyArmAttr();
            operationArmed(t);
            // No `stepEnds`: the image after the arm IS the pending one, so the
            // arm's own rest is never a step (the next press re-begins).
        }
    }

    void notePointerDown() {
        if (tool_() !is null && tool_() is bound_) {
            if (!operationOpen_) rebaseOnCurrent_(tool_(), true);
            postmodeOpenAtPress_ = postmodeArmed_;
            postmodeArmed_ = true;
        }
    }

    // A SCRIPTED attribute write while the post mode is armed ENDS the
    // operation with no row of its own (topology-redo S2b, model doc §3 PS: the
    // closing half of the reference's script write; its row half is handed
    // to the activation/command-close wave). The next press opens anew.
    void scriptedWriteEndsOperation(Tool t) {
        if (reporting_(t) && capturedTopologyModel(t.sessionPolicy()) && postmodeArmed_) {
            operationOpen_ = false;
            postmodeArmed_ = false;
            rebaseOnCurrent_(t, false);
        }
    }

    // The session holds the tool's preview of a dormant operation (topology-redo
    // S2b, model doc §R7.2). An unarmed post mode needs no term: every event that
    // disarms it rebases the tool on the live mesh first (S3).
    bool previewGated(Tool t) {
        return reporting_(t) && capturedTopologyModel(t.sessionPolicy())
            && topologyDormant_;
    }

    // `press`: the step was opened by the tool's own press door (the link),
    // never by an arm, an Action or a parameter write. Recorded on the row
    // (`MeshSessionEdit.stepOpenedByPress`); no default, so every caller says
    // which door it is (plan 8646 [R1-8, R2-2]).
    void stepBegins(Tool t, PressKind kind, AttrImage beforeWrite, bool press) {
        releaseParameter();
        if (!reporting_(t)) return;
        if (t.sessionPolicy().historyTopologySteps) {
            topologyPendingPress_ = press;
            topologyPendingKind_ = kind;
            // An attribute-only row (topology-redo S2b, model doc §R6.1): a dormant
            // step, or a write — never a press — while the post mode is not
            // armed. One path for both (the reference's apply-less write).
            topologyPendingAttrOnly_ = topologyDormant_ ||
                (capturedTopologyModel(t.sessionPolicy()) && !press && !postmodeArmed_);
            // M-C (a): a press of a `pressOpensOperation` tool opens a new
            // operation — the haul resets BEFORE the open image is taken.
            if (press && t.sessionPolicy().pressOpensOperation)
                t.openOperation(PressKind.shift, AttrImage.init);
            auto client = cast(TopologyStepClient)t;
            if (topologyPendingAttrOnly_) {
                topologyPendingAttrs_ = beforeWrite.empty
                    ? t.captureAttrImage() : beforeWrite;
                auto m = client is null ? null : client.topologyStepMesh();
                topologyPendingMesh_ = m is null ? MeshSnapshot.init
                    : MeshSnapshot.capture(*m);
                topologyPending_ = true;
                return;
            }
            auto m = client is null ? null : client.topologyStepMesh();
            if (m is null) return;
            topologyPendingMesh_ = lastAfter_.matches(*m) ? lastAfter_
                : baseImage_.matches(*m) ? baseImage_ : MeshSnapshot.capture(*m);
            topologyPendingBasis_ = client.topologyStepBasis();
            topologyPendingAttrs_ = beforeWrite.empty
                ? t.captureAttrImage() : beforeWrite;
            topologyPending_ = true;
            return;
        }
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
        if (reporting_(t) && t.sessionPolicy().historyTopologySteps) {
            if (topologyPendingAttrOnly_) {
                if (!topologyPending_) return;
                topologyPending_ = false;
                auto after = t.captureAttrImage();
                auto client = cast(TopologyStepClient)t;
                auto m = client is null ? null : client.topologyStepMesh();
                if (m !is null) topologyPendingMesh_.restore(*m);
                topologyPendingMesh_ = MeshSnapshot.init;
                if (after.opEquals(topologyPendingAttrs_)) return;
                auto context = client.topologyStepCarrier();
                if (context is null) {
                    t.restoreRecordedAttrs(topologyPendingAttrs_);
                    return;
                }
                auto cmd = new TopologyAdjustmentEdit(context, instanceOf_(t), tool_,
                    topologyPendingAttrs_, after);
                if (client.recordTopologyStep(cmd) && undoTop_() is cmd) {
                    history_.markEntrySession(cmd, token_);
                    rememberTopologyAttrs_(after);
                } else {
                    t.restoreRecordedAttrs(topologyPendingAttrs_);
                }
                return;
            }
            if (!topologyPending_) return;
            topologyPending_ = false;
            auto client = cast(TopologyStepClient)t;
            auto m = client is null ? null : client.topologyStepMesh();
            if (m is null) return;
            auto cmd = cast(MeshSessionEdit)client.topologyStepCarrier();
            if (cmd is null) {
                topologyPendingMesh_.restore(*m);
                client.restoreTopologyStep(topologyPendingAttrs_, topologyPendingBasis_);
                return;
            }
            auto after = topologyPendingMesh_.matches(*m) ? topologyPendingMesh_
                : MeshSnapshot.capture(*m);
            auto attrs = t.captureAttrImage();
            cmd.setSnapshots(topologyPendingMesh_, after, client.topologyStepLabel());
            // The step's origin and operation (topology-redo S2b, model doc §3 E4-E7,
            // P1, PR); outside the captured model nothing is classified.
            auto origin = StepOrigin.unclassified;
            bool prWrite;
            if (capturedTopologyModel(t.sessionPolicy())) {
                if (topologyPendingPress_)
                    origin = topologyPendingKind_ != PressKind.plain ? StepOrigin.restart
                        : operationOpen_ ? StepOrigin.refire
                        : postmodeOpenAtPress_ ? StepOrigin.restart : StepOrigin.opens;
                else {
                    // A parameter row reaches here only with the post mode
                    // armed: inside the open operation it refires it; with
                    // none open (a re-begun post mode) it is applied as an
                    // operation of its own that stays closed (M-PR, §R8.1).
                    prWrite = !operationOpen_;
                    origin = prWrite ? StepOrigin.restart : StepOrigin.refire;
                }
                if (origin != StepOrigin.refire) operation_ = ++nextOperation_;
            }
            // The row keeps its operation's base (topology-redo S3, model doc
            // §R6.2): a redo restores it; the next operation's base is set
            // where this one ends (`rebaseOnCurrent_`).
            cmd.setTopologyStep(topologyPendingAttrs_, attrs,
                topologyPendingBasis_, client.topologyStepBasis(), topologyPendingPress_,
                instanceOf_(t), origin,
                origin == StepOrigin.unclassified ? 0 : operation_);
            if (client.recordTopologyStep(cmd) && undoTop_() is cmd) {
                if (origin != StepOrigin.unclassified && !prWrite)
                    operationOpen_ = true;
                history_.markEntrySession(cmd, token_);
                noteFoldRow_(t, cmd);
                rememberTopologyAttrs_(attrs);
                lastAfter_ = after;
            } else {
                topologyPendingMesh_.restore(*m);
                client.restoreTopologyStep(topologyPendingAttrs_, topologyPendingBasis_);
            }
            topologyPendingMesh_ = MeshSnapshot.init;
            topologyPendingBasis_ = MeshSnapshot.init;
            return;
        }
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

    void recordCompleted(Tool t, const(Command) cmd) {
        if (!reporting_(t) || !t.sessionPolicy().historyRecordedSteps ||
            cmd is null) return;
        if (!history_.blockActive() && undoTop_() !is cmd) return;
        if (history_.markEntrySession(cmd, token_)) live_ = true;
    }

    void tagPreparedCompleted(Tool t, Command cmd) {
        if (!reporting_(t) || !t.sessionPolicy().historyRecordedSteps ||
            cmd is null) return;
        cmd.markSession(token_);
    }

    bool closeOwn(Tool t, bool commit) {
        if (t !is tool_()) {
            // Not the active tool (a stale instance): its own body, no account.
            if (commit) return t.commitOperation();
            t.cancelUncommittedEdit();
            return true;
        }
        if (commit) return close(CloseReason.enter, CommandDoor.ui).closed;
        if (reporting_(t) && t.sessionPolicy().historyTopologySteps) {
            if (topologyPending_) {
                auto client = cast(TopologyStepClient)t;
                auto m = client.topologyStepMesh();
                if (m !is null) topologyPendingMesh_.restore(*m);
                if (topologyDormant_)
                    t.restoreRecordedAttrs(topologyPendingAttrs_);
                else
                    client.restoreTopologyStep(topologyPendingAttrs_, topologyPendingBasis_);
                rememberTopologyAttrs_(topologyPendingAttrs_);
            }
            endOperation_();
            return true;
        }
        t.cancelUncommittedEdit();
        endOperation_();
        return true;
    }

    // A `sessionStepBegins` for an Action parameter write (C-H2-ls-insert:
    // the write is its own undo step, pushed before it acts). True iff the
    // caller must close it with `stepEnds`.
    bool actionStepBegins(Tool t, string name) {
        // A recorded producer writes the command that owns this step. Do not
        // probe params() after the value write or build an attribute image;
        // some tools capture their before-value in params() itself.
        if (!reporting_(t) || t.sessionPolicy().historyRecordedSteps) return false;
        foreach (ref p; t.params())
            if (p.name == name) {
                if (!p.action_) return false;
                stepBegins(t, PressKind.plain, AttrImage.init, false);
                return true;
            }
        return false;
    }

    // A topology parameter step held open by its widget (a scrub, a typed
    // edit in progress) — one step until the widget lets go (captured: a
    // scrub is one row). Anything else that opens or ends a step, or ends
    // the operation, closes or forgets it first, so a release can only ever
    // end the step its own write opened.
    private Tool   heldParamTool_;
    private string heldParamName_;

    bool holdsParameter(Object p, string name) {
        return heldParamTool_ !is null && cast(Object) heldParamTool_ is p
            && heldParamName_ == name;
    }

    void holdParameter(Tool t, string name) {
        if (!topologyPending_) return;
        heldParamTool_ = t;
        heldParamName_ = name;
    }

    void releaseParameter() {
        auto t = heldParamTool_;
        if (t is null) return;
        heldParamTool_ = null;
        heldParamName_ = null;
        stepEnds(t, false);
    }

    bool topologyParameterStepBegins(Tool t, AttrImage beforeWrite) {
        if (!reporting_(t) || !t.sessionPolicy().historyTopologySteps)
            return false;
        // A write that lands while a gesture's step is open joins that step.
        if (topologyPending_) return false;
        stepBegins(t, PressKind.plain, beforeWrite, false);
        return topologyPending_;
    }

    JSONValue stateJson() {
        auto t = tool_();
        if (!reporting_(t)) return JSONValue(null);
        auto j = JSONValue.emptyObject;
        j["live"]  = JSONValue(live_);
        j["steps"] = JSONValue(cast(long) (t.sessionPolicy().historyTopologySteps
            ? topologyHistoryDepth_(false) : t.sessionPolicy().historyRecordedSteps
            ? recordedHistoryDepth_(false) : steps_.length));
        j["redo"]  = JSONValue(cast(long) (t.sessionPolicy().historyTopologySteps
            ? topologyHistoryDepth_(true) : t.sessionPolicy().historyRecordedSteps
            ? recordedHistoryDepth_(true) : redo_.length));
        j["dormant"] = JSONValue(topologyDormant_);
        j["pendingPress"] = JSONValue(topologyPending_ && topologyPendingPress_);
        j["armed"] = JSONValue(postmodeArmed_);
        j["postmodeOwner"] = JSONValue(postmodeArmed_ ? "human" : "none");
        j["token"] = JSONValue(cast(long) token_);
        j["operationOpen"] = JSONValue(operationOpen_);
        j["operation"] = JSONValue(cast(long) operation_);
        return j;
    }

    private bool reporting_(Tool t) {
        return t !is null && t is bound_ && t is tool_()
            && t.sessionPolicy().sessionSteps;
    }

    private Tool liveSteps_() {
        auto t = tool_();
        return live_ && reporting_(t) &&
            !t.sessionPolicy().historyTopologySteps &&
            !t.sessionPolicy().historyRecordedSteps ? t : null;
    }

    // A closed-topology redo is a one-arm continuation of the exact lifecycle
    // row that recreated it. The new activation must sit directly above that
    // row at the current cursor and continue its armed id/token lineage; an
    // undone or bypassed source row cannot make a later same-class arm dormant.
    private bool validClosedTopologyRedo_(const Command armRow, string id) {
        import commands.tool.lifecycle : ToolActivationCommand;
        if (!closedTopologyRedo_) return false;
        auto source = cast(const ToolActivationCommand)
            closedTopologyRedoSource_.get;
        auto arm = cast(const ToolActivationCommand)armRow;
        if (source is null || arm is null || closedTopologyId_ != id ||
            arm.armedId() != id || arm.previousId() != source.armedId() ||
            arm.previousToken() != source.sessionToken()) return false;
        const ue = history_.undoEntries();
        return ue.length >= 2 && ue[$ - 1].cmd is arm &&
            ue[$ - 2].cmd is source;
    }

    private void clearClosedTopologyRedo_() {
        closedTopologyRedo_ = false;
        closedTopologyRedoSource_ = null;
        closedTopologyId_ = null;
        closedTopologyToken_ = 0;
    }

    private void pushStep_(AttrImage img) {
        if (steps_.length >= kMaxSessionSteps) steps_ = steps_[1 .. $];
        steps_ ~= img;
    }

    private void endOperation_() {
        heldParamTool_ = null;
        heldParamName_ = null;
        live_ = false;
        openImage_ = AttrImage.init;
        steps_ = null;
        redo_ = null;
        pending_ = AttrImage.init;
        pendingSet_ = false;
        pendingIfChanged_ = false;
        topologyPending_ = false;
        topologyPendingMesh_ = MeshSnapshot.init;
        topologyPendingBasis_ = MeshSnapshot.init;
        lastAfter_ = MeshSnapshot.init;
    }

    // The image the pending topology step opened from, shared with the tool
    // that opened it (one snapshot per press, plan 8646 [R1-m]). Empty unless
    // THIS instance is the one the session is tracking a step for.
    private MeshSnapshot stepOpenImage_(Tool t) {
        if (!reporting_(t) || !topologyPending_) return MeshSnapshot.init;
        return topologyPendingMesh_;
    }

    private size_t topologyHistoryDepth_(bool redo) {
        size_t n;
        if (redo) {
            foreach (e; history_.redoEntries())
                if (e.cmd.sessionToken() == token_ &&
                    cast(const MeshSessionEdit)e.cmd !is null) ++n;
        } else {
            foreach (e; history_.undoEntries())
                if (e.cmd.sessionToken() == token_ &&
                    cast(const MeshSessionEdit)e.cmd !is null) ++n;
        }
        return n;
    }

    private size_t recordedHistoryDepth_(bool redo) {
        import commands.tool.lifecycle : ToolActivationCommand;
        size_t n;
        if (redo) {
            foreach (e; history_.redoEntries())
                if (e.cmd.sessionToken() == token_ &&
                    cast(const ToolActivationCommand)e.cmd is null) ++n;
        } else {
            foreach (e; history_.undoEntries())
                if (e.cmd.sessionToken() == token_ &&
                    cast(const ToolActivationCommand)e.cmd is null) ++n;
        }
        return n;
    }

    private bool navigateRecorded_(bool isUndo) {
        import commands.tool.lifecycle : ToolActivationCommand;
        import command_history : HistoryFlags;
        auto t = tool_();
        if (!reporting_(t) || !t.sessionPolicy().historyRecordedSteps)
            return false;
        // A pending preview is still owned by the tool. The ordinary cancel
        // branch must peel it before an older completed History row moves.
        if (isUndo && t.hasUncommittedEdit()) {
            if (!t.sessionPolicy().previewHistoryLadder) return false;
            const entries = history_.undoEntries();
            if (entries.length == 0 ||
                entries[$ - 1].cmd.sessionToken() != token_ ||
                !(entries[$ - 1].flags & HistoryFlags.InSession)) return false;
            // A live parameter row is part of this preview. Its command
            // restores the tool state; the next Undo cancels only after the
            // last such row has been consumed.
            return history_.undo();
        }
        const Command row = isUndo ? undoTop_() :
            (history_.redoEntries().length ? history_.redoEntries()[0].cmd : null);
        if (row is null || row.sessionToken() != token_ ||
            cast(const ToolActivationCommand)row !is null) return false;
        const bool endsTool = isUndo && t.sessionPolicy().recordedFirstUndoEndsTool
            && recordedHistoryDepth_(false) == 1;
        if (endsTool && !history_.markRecordedFirstStep(token_, armedId_))
            return false;
        const moved = isUndo ? history_.undo() : history_.redo();
        if (moved) {
            if (endsTool) {
                dropTool_();
                return true;
            }
            auto current = tool_();
            if (current !is null) current.resyncSession();
        }
        return moved;
    }

    private bool navigateTopology_(bool isUndo) {
        auto t = tool_();
        import commands.tool.lifecycle : ToolActivationCommand;
        if (isUndo) {
            if (t is null || !reporting_(t) ||
                !t.sessionPolicy().historyTopologySteps) return false;
            auto cmd = cast(const MeshSessionEdit)undoTop_();
            if (cmd is null || !cmd.isTopologyStep() ||
                cmd.sessionToken() != token_) return false;
            // A folded group (§9.19.3) pops whole, down to its base, and the
            // BASE's open image comes back. A group based on the activation is
            // the activation path's ([A2-3]: it must run that path's tail).
            // Any other base is this session's press or parameter row: the
            // walk marks a run only when it ends on the open block (A16 R4).
            const size_t run = foldedRunAbove_();
            if (run && cast(const ToolActivationCommand)undoEntryAt_(run) !is null)
                return false;
            const pair = recordCarriesActivation_();
            assert(!(pair && run), "session undo: a carried record and a folded run on one row");
            Rebindable!(const MeshSessionEdit) popped = cmd;
            auto drop = pair ? dropImage_(1) : DropImage.init;
            if (!history_.undo()) return false;
            storeDropImage_(drop);
            foreach (_; 0 .. run) {
                auto next = cast(const MeshSessionEdit)undoTop_();
                if (!history_.undo()) break;
                popped = next;
            }
            if (pair) {
                history_.undo();
            } else {
                // Law 4 (orphan): a row another instance wrote moves the mesh only.
                const orphan = capturedTopologyModel(t.sessionPolicy())
                    && !boundToLive_(popped.get, t);
                auto img = orphan ? t.captureAttrImage()
                    : navigableAttrs_(t, popped.get, popped.stepBeforeAttrs());
                (cast(TopologyStepClient)t).restoreTopologyStep(
                    img, popped.stepBeforeBasis());
                if (!orphan) rememberTopologyAttrs_(img);
            }
            return true;
        }
        const re = history_.redoEntries();
        if (re.length == 0) return false;
        auto act = cast(const ToolActivationCommand)re[0].cmd;
        const bool pair = act !is null && !act.dormantTopology() &&
            act.carriesFirstRecord() &&
            re.length > 1 && re[1].cmd.sessionToken() == act.sessionToken();
        auto head = cast(const MeshSessionEdit)re[pair ? 1 : 0].cmd;
        if (head is null || !head.isTopologyStep()) return false;
        if (!pair && (t is null || !reporting_(t) ||
            !t.sessionPolicy().historyTopologySteps ||
            head.sessionToken() != token_)) return false;
        if (pair) {
            if (!history_.redo()) return false;
            adoptToken_(act.armedId, act.sessionToken());
        }
        if (!history_.redo()) return pair;
        // The rows folded above this base come back with it, as one step;
        // the attributes are the LAST one's (C3-L2r2 G-after, through M-H).
        Rebindable!(const MeshSessionEdit) cmd = head;
        for (auto next = history_.redoEntries(); !pair && next.length &&
                (next[0].flags & HistoryFlags.JoinsBelow) &&
                next[0].cmd.sessionToken() == token_; next = history_.redoEntries()) {
            auto row = cast(const MeshSessionEdit)next[0].cmd;
            if (row is null || !history_.redo()) break;
            cmd = row;
        }
        redoneTopologyStep_ = true;
        auto current = tool_();
        if (current !is null && reporting_(current)) {
            // Law 4: the redo that re-creates the tool with its first row seeds
            // it (`seedRecreated_`); a row another instance wrote (orphan) moves
            // the mesh only; any other redo, the last redone row's attributes.
            const orphan = !pair && capturedTopologyModel(current.sessionPolicy())
                && !boundToLive_(cmd.get, current);
            auto img = orphan ? current.captureAttrImage()
                : navigableAttrs_(current, cmd.get,
                    pair ? seedRecreated_(act, cmd.get) : cmd.stepAfterAttrs());
            (cast(TopologyStepClient)current).restoreTopologyStep(
                img, cmd.stepAfterBasis());
            if (!orphan) rememberTopologyAttrs_(img);
            // Reopen (L42): the redo of a press reopens that press's block;
            // Reopen-base (L55): the redo of a parameter row reopens the
            // press or activation below it.
            if (current.sessionPolicy().foldsParamRowsIntoBlock)
                openBlock_ = head.stepOpenedByPress() ? head : blockBelow_(head);
        }
        if (pair && current !is null && current.sessionPolicy()
                .discardLaterTopologyRedoOnRearm)
            history_.invalidateRedo();
        return true;
    }

    // ----- the parameter-row fold (wave plan 8640 S7a, §9.19.3, §9.22.1,
    // §9.24 [A12-3], §9.26.4) -------------------------------------------------

    private static ulong instanceOf_(const Tool t) {
        return t.preparedLifecycleOwner().value;
    }

    // Law 4 (model doc §R9): a navigated row writes its attributes
    // only into the instance that recorded it; any other instance is not its.
    private bool boundToLive_(const MeshSessionEdit row, Tool t) {
        return row.stepInstance() == instanceOf_(t);
    }

    // Law 4, the seed: an undo that drops the tool together with its top `rows`
    // remembers, for the session, the live image with each of those rows the
    // live instance recorded undone (top down); the redo that re-creates the
    // tool restores it (`seedRecreated_`). Computed (with its session key)
    // before the first row moves, stored only once `history_.undo()` took the
    // step: a refused undo leaves the remembered image as it was (9020 F).
    private struct DropImage {
        string id;
        ulong token;
        AttrImage attrs;
        bool valid;
    }

    private void storeDropImage_(DropImage d) {
        if (d.valid) rememberTopologyAttrsFor_(d.id, d.token, d.attrs);
    }

    private DropImage dropImage_(size_t rows) {
        auto t = tool_();
        if (!reporting_(t) || !capturedTopologyModel(t.sessionPolicy()))
            return DropImage.init;
        auto img = t.captureAttrImage();
        const ue = history_.undoEntries();
        foreach (k; 0 .. rows < ue.length ? rows : ue.length) {
            const c = ue[$ - 1 - k].cmd;
            if (auto row = cast(const MeshSessionEdit) c) {
                if (boundToLive_(row, t)) img = row.stepBeforeAttrs();
            } else if (auto adj = cast(const TopologyAdjustmentEdit) c) {
                if (adj.instance() == instanceOf_(t)) img = adj.before();
            }
        }
        return DropImage(armedId_.idup, token_, img, armedId_.length != 0);
    }

    // The image a re-created instance of `act`'s session starts from: what its
    // drop remembered; none remembered (evicted past `kMaxSessionSteps`
    // sessions) — `fallback`'s before attributes, or nothing.
    private AttrImage seedRecreated_(
            const imported!"commands.tool.lifecycle".ToolActivationCommand act,
            const MeshSessionEdit fallback) {
        auto img = topologyAttrsFor_(act.armedId, act.sessionToken());
        if (img.empty && fallback !is null) img = fallback.stepBeforeAttrs();
        return img;
    }

    // M-H: a `pressOpensOperation` tool's operation context (its haul names)
    // is restored only into the instance that recorded `row`; any other
    // instance, or a restore that names no row, gets the image without them.
    private static AttrImage navigableAttrs_(Tool t, const MeshSessionEdit row,
                                             AttrImage img) {
        const pol = t.sessionPolicy();
        if (!pol.pressOpensOperation) return img;
        if (row !is null && row.stepInstance() == instanceOf_(t)) return img;
        return img.without(pol.haulAttrs);
    }

    // The contiguous `JoinsBelow` rows on top of the undo stack: the run a
    // group undo pops above its base. One fold's rows, of one token: a walk
    // marks only its token's rows and never its base, so an unmarked base
    // separates two runs; each caller checks the token on the top row or the
    // base (amendment A16 R3).
    private size_t foldedRunAbove_() {
        const ue = history_.undoEntries();
        size_t n;
        while (n < ue.length && (ue[$ - 1 - n].flags & HistoryFlags.JoinsBelow))
            ++n;
        return n;
    }

    // ...when its base is this session's activation row (M-G, [A2-3]).
    private size_t absorbedRunAbove_() {
        import commands.tool.lifecycle : ToolActivationCommand;
        const n = foldedRunAbove_();
        if (n == 0) return 0;
        auto act = cast(const ToolActivationCommand)undoEntryAt_(n);
        return act !is null && act.sessionToken() == currentToken() ? n : 0;
    }

    private static bool foldRow_(const Command c, ulong token) {
        auto r = cast(const MeshSessionEdit)c;
        return r !is null && r.isTopologyStep() && !r.stepOpenedByPress()
            && r.sessionToken() == token;
    }

    // A recorded row's place in the open block: a press closes the open step
    // and becomes the block; a parameter row is the base of a new open step
    // when there is none (after a navigation, or a script-door arm), else it
    // is foldable and remembers whether the block was a press or activation.
    private void noteFoldRow_(Tool t, MeshSessionEdit cmd) {
        if (!t.sessionPolicy().foldsParamRowsIntoBlock) return;
        if (cmd.stepOpenedByPress()) {
            foldOpenRows_(cmd);
            openBlock_ = cmd;
            return;
        }
        if (openBlock_.get is null) {
            openBlock_ = cmd;
            return;
        }
        if (!foldRow_(openBlock_.get, token_))
            history_.markEntryFold(cmd, HistoryFlags.PreNavOpen);
    }

    // Close the open step: walk down from below `trigger` (from the top when
    // null) over this session's contiguous parameter rows; only when the walk
    // ENDS on the open block are they marked `JoinsBelow`.
    private void foldOpenRows_(const Command trigger) {
        auto base = openBlock_.get;
        if (base is null) return;
        const ue = history_.undoEntries();
        size_t hi = ue.length;
        if (trigger !is null) {
            if (hi == 0 || ue[hi - 1].cmd !is trigger) return;
            --hi;
        }
        size_t lo = hi;
        while (lo > 0 && ue[lo - 1].cmd !is base) {
            if (!foldRow_(ue[lo - 1].cmd, token_)) return;   // ends elsewhere
            --lo;
        }
        if (lo == 0) return;   // the block is not on the stack
        foreach (k; lo .. hi)
            history_.markEntryFold(ue[k].cmd, HistoryFlags.JoinsBelow);
    }

    // The press or activation row of this session below `row` (on the undo
    // stack), across this session's parameter rows; null when the walk ends
    // on anything else.
    private const(Command) blockBelow_(const Command row) {
        import commands.tool.lifecycle : ToolActivationCommand;
        const ue = history_.undoEntries();
        size_t i = ue.length;
        while (i > 0 && ue[i - 1].cmd !is row) --i;
        if (i == 0) return null;
        --i;
        while (i > 0 && foldRow_(ue[i - 1].cmd, token_)) --i;
        if (i == 0) return null;
        auto c = ue[i - 1].cmd;
        auto press = cast(const MeshSessionEdit)c;
        if (press !is null && press.isTopologyStep() && press.stepOpenedByPress()
            && press.sessionToken() == token_) return c;
        auto act = cast(const ToolActivationCommand)c;
        return act !is null && act.sessionToken() == token_ ? c : null;
    }

    // L2p/L53/L54 (§9.26.4 [A14-4]): after a redo, a redo-head parameter row
    // of this session written while the block was a press or the activation
    // (`PreNavOpen`) redoes only in the instance that wrote it; anywhere else
    // the redo stack is cut there — everything above it is that open step's,
    // so the cut is exact. No "closed" term (amendment A16, `StepClosed`
    // withdrawn): a folded row never reaches the head without its base, and
    // under the [A12-3] keying a `PreNavOpen` row is never a row-based step's.
    // Runs once the history is Active again, else `invalidateRedo` refuses.
    // A `PreNavOpen` head may be ANOTHER session's: a session tool armed
    // without an activation row (the `rotate` factory) leaves a foreign redo
    // head in place, so the head is skipped unless it is this session's row
    // (cell `cross-tool-redo`; gap row ee'').
    private void pruneRedoTop_() {
        auto t = tool_();
        if (!reporting_(t)) return;
        const re = history_.redoEntries();
        if (re.length == 0 || !(re[0].flags & HistoryFlags.PreNavOpen)) return;
        auto row = cast(const MeshSessionEdit)re[0].cmd;
        if (row is null || !foldRow_(row, token_)) return;
        if (row.stepInstance() == instanceOf_(t)) return;
        history_.invalidateRedo();
    }

    private AttrImage topologyAttrsFor_(string id, ulong token) {
        foreach_reverse (ref owner; topologyAttrOwners_)
            if (owner.id == id && owner.token == token) return owner.attrs;
        return AttrImage.init;
    }

    private void rememberTopologyAttrs_(AttrImage attrs) {
        if (armedId_.length == 0) return;
        rememberTopologyAttrsFor_(armedId_, token_, attrs);
    }

    private void rememberTopologyAttrsFor_(string id, ulong token, AttrImage attrs) {
        foreach_reverse (ref owner; topologyAttrOwners_)
            if (owner.id == id && owner.token == token) {
                owner.attrs = attrs;
                return;
            }
        if (topologyAttrOwners_.length >= kMaxSessionSteps)
            topologyAttrOwners_ = topologyAttrOwners_[1 .. $];
        topologyAttrOwners_ ~= TopologyAttrOwner(id.idup, token, attrs);
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

    // S6: the drop row, above whatever the door wrote (a salvaged press),
    // then — on the Esc rung only — the empty task row above it (L39).
    private void recordDropRow_() {
        if (dropRowFactory_ is null) return;
        Command[2] rows = [dropRowFactory_(pendingDrop_),
            pendingDrop_.ctx.clearsTask && taskRowFactory_ !is null
                ? taskRowFactory_() : null];
        foreach (row; rows)
            if (row !is null) history_.recordToolLifecycle(row);
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
        return act !is null && !act.dormantTopology() &&
            act.carriesFirstRecord() && act.sessionToken() == tok;
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
