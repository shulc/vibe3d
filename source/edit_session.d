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

import tool            : Tool;
import command         : Command;
import command_history : CommandHistory;

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
    void reEvaluate();
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
// EditSession
// ---------------------------------------------------------------------------
final class EditSession {
    // Live view of the active tool — a delegate, not a snapshot, so every
    // protocol method re-reads the current tool exactly like the app.d driver
    // blocks it absorbed re-read `activeTool`.
    private Tool delegate() tool_;
    private CommandHistory  history_;
    // { setActiveTool(null); activeToolId = ""; } — the app's tool-drop verb.
    private void delegate() dropTool_;
    // The ONLY state EditSession owns: the refire driver-bracket bit
    // (tryRefireDispatch's non-reentrancy tripwire). Everything else is
    // computed from tool_() — see SessionPhase.
    private bool refireDriving_ = false;

    this(Tool delegate() tool, CommandHistory history,
         void delegate() dropTool) {
        assert(tool !is null,     "EditSession: tool accessor required");
        assert(history !is null,  "EditSession: history required");
        assert(dropTool !is null, "EditSession: dropTool verb required");
        tool_     = tool;
        history_  = history;
        dropTool_ = dropTool;
    }

    // Computed phase classification (see SessionPhase above).
    SessionPhase phase() {
        auto t = tool_();
        if (t is null) return SessionPhase.NoTool;
        return t.hasUncommittedEdit() ? SessionPhase.EditOpen
                                      : SessionPhase.Idle;
    }

    // ----- live-eval (re-eval plan D4) --------------------------------------

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
    void onValueAttrApplied(bool interactive) {
        auto lc = cast(LiveEvalClient) tool_();
        if (lc is null) return;
        if (lc.hasLiveAttrEval())  lc.reEvaluate();
        else if (interactive)      lc.reEvaluate();
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
    void onStageConfigChanged() {
        auto lc = cast(LiveEvalClient) tool_();
        if (lc !is null && lc.hasLiveEval()) lc.reEvaluate();
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
}

// ---------------------------------------------------------------------------
// Module unittest — phase() classification (no GL / SDL: a bare Tool and a
// bare CommandHistory both construct headlessly).
// ---------------------------------------------------------------------------
unittest {
    Tool held = null;
    auto es = new EditSession(() => held, new CommandHistory(), () {});
    assert(es.phase() == SessionPhase.NoTool);

    held = new Tool();
    assert(es.phase() == SessionPhase.Idle);

    final class OpenEditTool : Tool {
        override bool hasUncommittedEdit() const { return true; }
    }
    held = new OpenEditTool();
    assert(es.phase() == SessionPhase.EditOpen);
}
