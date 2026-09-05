// `FileQuit.discardsUnsavedWork` over all four inputs (task 4380).
//
// WHY THIS CELL EXISTS AT ALL, AND WHY IT HAS TO BE HERE. The predicate is
//
//     if (fromWindowClose_ && command.g_testMode) return false;
//     return true;
//
// and `g_testMode` has exactly one setter — `app.d`, inside `--test`. So in
// every suite test the flag is TRUE, and the only combination in which it is
// false is the one no suite test can build: a shipped editor. Under that
// reading the `&& command.g_testMode` term is unfalsifiable from the suite —
// widening the arm to a bare `if (fromWindowClose_) return false;`, which
// makes a SHIPPED build throw unsaved work away on the window [X] with no
// question asked, was measured green across the whole affected lane. A term
// whose removal nothing can see is not guarded.
//
// The module-unittest binary is the one place `g_testMode` is false, because
// nothing there ever runs `--test`'s argument parsing. That is what makes the
// fourth row below expressible, and it is the only reason this is a unit cell
// and not a suite one.
//
// WHAT THE FOUR ROWS BUY, one mutation each:
//
//   windowClose  testMode   expect   the mutation this row alone catches
//   -----------  --------   ------   ----------------------------------------
//     false        false     true    —  (guarded with the row below)
//     false        true      true    dropping `&& !fromWindowClose_`-shaped
//                                    inversions; also pinned over HTTP by
//                                    tests/test_unsaved_guard.d
//     true         true      false   deleting the 4380 exemption — the harness
//                                    hang; also pinned live by
//                                    tests/test_sigterm_exit_after_edit.d
//     true         false     true    DROPPING `&& command.g_testMode`. Nothing
//                                    else in the tree reddens on it.
//
// ORDER IS LOAD-BEARING. druntime stops a module at its first failed assert,
// so the three rows that must STAY green sit above the row that must redden:
// one run then buys both halves, since reaching the red line proves every
// straight-line assert above it ran and passed.
//
// BOTH MUTATIONS WERE RUN on `dub test --config=tests` (2026-09-05), and each
// reddened one named row with rows above it known-passed by control flow:
//   A. `if (fromWindowClose_) return false;` — the reviewer's widening, the one
//      a shipped build pays for — reddens `4380 row 4`, and it was that run's
//      ONLY `AssertError`: nothing else in this lane sees the term. The suite
//      lane does not see it either — that same widening was measured green
//      there before this file existed.
//   B. the exemption line deleted outright — reddens `4380 row 3`.
// The lane counts 498 modules without this file and 499 with it. Raw output:
// the 4380 card.
//
// This is a statement about the PREDICATE, not about the guard: whether
// `runUiCommand` still asks it, and what it does with the answer, is
// `tests/test_unsaved_guard.d` and `tests/test_sigterm_exit_after_edit.d`.
// `app.d` is the entry module and is not linked into this binary, so that half
// is not reachable from here by construction.
module tests.unit.quit_window_close_guard_test;

import mesh     : Mesh, makeCube;
import view     : View;
import editmode : EditMode;
import commands.file.quit : FileQuit;
static import command;

// One `FileQuit` per row, built directly — no app, no HTTP, no registry.
private bool discardsWith(bool fromWindowClose, bool testMode) {
    // `g_testMode` is `__gshared` process state shared with every other module
    // in this binary; leave it exactly as this block found it even on a throw.
    const saved = command.g_testMode;
    scope (exit) command.g_testMode = saved;
    command.g_testMode = testMode;

    auto m = makeCube();
    auto v = new View(0, 0, 800, 600);
    EditMode em = EditMode.Vertices;

    auto cmd = new FileQuit(&m, v, em, () {});
    cmd.setFromWindowClose(fromWindowClose);
    return cmd.discardsUnsavedWork();
}

unittest {
    // Floor: the binary this cell needs. If some earlier module left the flag
    // set, row 4 would be measuring row 3 and would pass for the wrong reason.
    assert(!command.g_testMode,
        "4380 floor: `command.g_testMode` is already true in the unittest "
      ~ "binary. This cell's whole premise is that the flag is false here — "
      ~ "some module set it and did not restore it, and the shipped-build row "
      ~ "below is now measuring test mode instead.");

    // ---- Rows that must STAY green under the mutation, asserted first ----

    assert(discardsWith(false, false),
        "4380 row 1: a menu / keyboard File -> Quit in a shipped build must "
      ~ "declare that it discards unsaved work, so the guard asks before the "
      ~ "editor exits.");

    assert(discardsWith(false, true),
        "4380 row 2: a `file.quit` a test DISPATCHES must still declare the "
      ~ "discard. --test suppresses the modal, not the question, and it is "
      ~ "`applyImpl` that keeps such a quit from taking the shared instance "
      ~ "down. Widening the exemption to all of --test would silently unpin "
      ~ "tests/test_unsaved_guard.d's dirty-quit case.");

    assert(!discardsWith(true, true),
        "4380 row 3: THE 4380 EXEMPTION. SIGTERM reaches a --test instance as "
      ~ "SDL_QUIT, arrives as a `file.quit` carrying fromWindowClose, and "
      ~ "there is no user to answer the prompt --test suppressed. Declaring "
      ~ "the discard here holds the quit forever and every harness kill "
      ~ "becomes a hang (tests/test_sigterm_exit_after_edit.d, cell 2).");

    // ---- The row the mutation must redden ----

    assert(discardsWith(true, false),
        "4380 row 4: THE SHIPPED BUILD, and this is a data-loss path. Closing "
      ~ "the window of a real editor over unsaved work must still declare the "
      ~ "discard, so the user is asked. The 4380 exemption is licensed by "
      ~ "`command.g_testMode` and by nothing else: dropping that term from "
      ~ "`FileQuit.discardsUnsavedWork` makes the [X] throw the document away "
      ~ "with no prompt, and leaves the three rows above green.");
}
