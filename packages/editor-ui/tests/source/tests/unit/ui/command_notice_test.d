// Module unittests for `ui.command_notice`, moved verbatim out of source/ui/command_notice.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.command_notice_test;


import ui.command_notice;

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
