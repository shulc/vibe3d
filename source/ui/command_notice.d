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

// ---------------------------------------------------------------------------
// N1 — a reason produces a notice that CARRIES THE WHOLE REASON.
//
// Discriminating: the reason here is the real one a pre-v8 document produces,
// and the assertion names the three things the owner's wording condition
// requires — the file's version, this build's, and "not damaged". An
// implementation that showed only "file.load did not run" (the generic half,
// which is all the dispatch funnel had before `refusalReason` existed) reads a
// string with none of them; one that showed only the reason reads a string
// without the command.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : canFind;

    immutable why = "/home/u/old.v3d — this document is .v3d format version 7, "
        ~ "written by an EARLIER build of the editor; this build reads version "
        ~ "8 only and does not convert older documents (deliberate clean break, "
        ~ "no migration). The file is not damaged.";
    immutable t = commandNoticeText("file.load", why);

    assert(t.length > 0, "a command that said WHY must produce a notice");
    assert(t.canFind("file.load"), "the notice names the command: " ~ t);
    assert(t.canFind("format version 7"), "…the file's version: " ~ t);
    assert(t.canFind("version 8"),        "…this build's: " ~ t);
    assert(t.canFind("not damaged"),      "…and that the file is fine: " ~ t);
    assert(t.canFind("/home/u/old.v3d"),  "…and WHICH file: " ~ t);
}

// ---------------------------------------------------------------------------
// N2 — NO reason means NO notice.
//
// This is the half that keeps a cancelled file dialog quiet, and it is the one
// a "show something whenever apply() returned false" implementation gets
// wrong: that implementation reads a non-empty string here.
//
// The `label`-only case is the exact shape of a cancel — the command is known,
// there is simply nothing to say about it.
// ---------------------------------------------------------------------------
unittest {
    assert(commandNoticeText("file.load", "") == "",
        "a command that declined without a reason is a CANCEL, and a cancel "
        ~ "must not raise a dialog");
    assert(commandNoticeText("", "") == "", "…nor an unnamed one");
    // …but a reason with no label still reaches the user: losing the message
    // because the command forgot to name itself would be the silent failure
    // this whole module exists to remove.
    assert(commandNoticeText("", "the disk is full").length > 0,
        "a reason is shown even when the command has no label");
    import std.algorithm : canFind;
    assert(commandNoticeText("", "the disk is full").canFind("the disk is full"));
}
