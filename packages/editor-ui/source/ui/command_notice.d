module ui.command_notice;

// ---------------------------------------------------------------------------
// Task 0616 review, blocker B1 — WHAT THE USER IS SHOWN when a command run
// from the UI declines and has a reason.
//
// WHY THIS IS A MODULE AND NOT THREE LINES INSIDE `runCommand`: the same split
// `ui/image_rows.d` makes, for the same reason. The ImGui modal that carries
// this text is not observable headlessly, so an assertion written against the
// draw call could only say "the function ran". The DECISION — is there a
// notice at all, and what does it say — is pure, and pure is assertable. What
// is left unasserted is where the box appears on screen.
//
// THE PROBLEM IT EXISTS FOR. `log.d` has one sink: a stderr echo. There is no
// log panel, no status line for diagnostics, and no non-test listener anywhere
// in the tree. `app.d`'s `runCommand` passes `throwMsg = null`, so a command
// that returns false from a keyboard shortcut or a UI button used to no-op in
// silence. Concretely: opening a pre-v8 `.v3d` through File → Open (or through
// the recent-files list, which hands the command an explicit path) made the
// menu item look broken — no dialog, no message, viewport unchanged — while
// the reader had already written a sentence naming both format versions and
// saying the file is not damaged.
//
// THE RULE, and why it is a rule and not "show every failure". A command that
// declines WITHOUT a reason must stay silent, because that is the shape of a
// user CANCELLING something: `FileLoad` returns false when the file chooser is
// dismissed, and popping "file.load did not run" at someone who just pressed
// Cancel is worse than saying nothing. `Command.refusalReason()` is "" for
// every command that does not override it, so opting in is per command and the
// silent default is preserved for all of them.
// ---------------------------------------------------------------------------

/// The text of the failure notice for a command that declined, or `""` when
/// there is nothing to show.
///
/// `label` is the command's own `label()` (which defaults to its id, e.g.
/// `file.load`); `why` is its `refusalReason()`.
///
/// An empty `why` yields an empty result — see the header: a reasonless
/// decline is a cancel, and a cancel is silent.
string commandNoticeText(string label, string why) pure @safe {
    if (why.length == 0) return "";
    // The command is named FIRST because the notice is modal and unanchored:
    // by the time it is read, the button or menu item that produced it is
    // covered by the dialog.
    return (label.length ? label : "The command") ~ " did not run:\n\n" ~ why;
}
