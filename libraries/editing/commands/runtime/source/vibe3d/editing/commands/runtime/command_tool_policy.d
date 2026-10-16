module vibe3d.editing.commands.runtime.command_tool_policy;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.commands.runtime.tool_activation_ownership : CloseOutcome, CommandDoor;

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
    import vibe3d.editing.commands.runtime.command : commitsActiveToolEditBeforeApply, dropsActiveToolBeforeApply,
                     endsLiveEditBeforeUiCommand;
    const bool commits = commitsActiveToolEditBeforeApply(cmd);
    const bool closes = !reentrant
        && (commits || (door == CommandDoor.ui && endsLiveEditBeforeUiCommand(cmd)));
    CloseOutcome o = closes && close !is null ? close(door) : CloseOutcome.init;
    o.dropsTool = !o.staysArmed && (dropsActiveToolBeforeApply(cmd) || (closes && commits));
    return o;
}

