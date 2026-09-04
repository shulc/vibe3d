// l2_command_undo_census_test — task 1903 Stage L2, the stage-closing census.
//
// ALL TWELVE COMMANDS OF §5.5's L2 ROW ARE OFF THE SNAPSHOT-ONLY UNDO.
//
// WHAT THE PLAN ASKED FOR, AND WHY IT CANNOT BE MEASURED THAT WAY. §L2.7's
// W-2-CENSUS specifies "a source-text census recording the exact {file: count}
// map of `private MeshSnapshot` declarations", and §L2.1 predicts those
// declarations "drop by 12 when the stage completes". THEY DO NOT, and the
// shape stage L2-a actually shipped is why: `map_edit_undo.runMapEdit` has
// THREE arms, and the third is the hatch (`VIBE3D_UNDO_TRACKER=0`), which
// captures a whole-mesh `MeshSnapshot` so that a hatched run's undo image is
// still correct. Every migrated command therefore still DECLARES a
// `MeshSnapshot` — annotated `// the hatch's arm only` — and will until the
// hatch itself is retired (plan §7). A census keyed on the declaration would
// have to read 12 both before and after this stage: green on the broken code,
// green on the fixed code, which is the defect this project pays for most.
//
// WHAT IS MEASURED INSTEAD is the shape the migration actually deletes, named
// by the plan's own refusal ruling: the pre-migration `revert()` body
// (`if (!snap.filled) return false; snap.restore(*mesh); return true;`) and the
// `snap.restore(*mesh)` rollback four of the twelve used on a kernel refusal.
// Both are ZERO across the roster afterwards, and both are non-zero before it —
// so this census reddens if any of the twelve is reverted to the old shape, and
// it could not have been green before the stage.
//
// THE COMMENT STRIPPER IS LOAD-BEARING, not hygiene: every migrated file
// EXPLAINS in a comment that `if (!snap.filled) return false;` was deleted
// rather than translated, quoting it verbatim. A census that did not strip
// comments would forbid its own explanation and could never be green.
//
// LANE: `dub test --config=tests` (lane U) — a `tests/unit/**` block.
module tests.unit.l2_command_undo_census_test;

import std.file   : readText, exists;
import std.path   : dirName, buildPath;
import std.format : format;
import std.algorithm : sort, uniq;
import std.array  : array;

import tests.unit.census_symbols : blankNonCode;

private string repoRoot()
{
    // …/tests/unit/<this file>  ->  …
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}

/// The twelve of §5.5's L2 row, by file. A HAND-WRITTEN list and not a
/// directory walk, on purpose: the claim is about THIS ROSTER, and a walk would
/// silently absorb a thirteenth command written later without anyone deciding
/// it belongs to L2.
private enum string[12] kL2Commands = [
    "add_point.d", "fix_orientation.d", "flip.d", "make_polygon.d",
    "polygon_align.d", "spikey.d", "spin_edge.d", "split_edge.d",
    "split_face.d", "thicken.d", "vertex_new.d", "vertex_split.d",
];

/// `//` line comments, `/* */`, `/+ +/` and string literals blanked.
///
/// PUBLIC, and shared with `tests/unit/l10_command_undo_census_test.d` (task
/// 1903 Stage L10). Not tidiness: a census whose stripper is a private copy
/// can drift from this one, and then two gates disagree about what counts as
/// code — the second spelling being the one that drifts. Both censuses carry
/// their own per-file non-vacuity floor, so a stripper regression reddens in
/// both rather than being silently absorbed by either.
alias codeOnly = blankNonCode;

/// ditto — shared with the L10 census for the same reason.
size_t countOf(string hay, string needle)
{
    size_t n = 0, i = 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

unittest // the twelve are off the snapshot-only undo
{
    // TERM 1 — the roster is twelve DISTINCT names. A typo throws loudly
    // (`readText` on a missing file, plus the `exists` assert below); a
    // DUPLICATE is silent, and it leaves one command unscanned while the count
    // of ROWS still reads twelve.
    auto sorted = kL2Commands.dup;
    sort(sorted);
    immutable size_t distinct = sorted.uniq.array.length;
    assert(distinct == 12,
        format("the L2 roster names only %d DISTINCT files across its twelve "
             ~ "entries: %s. A duplicated literal leaves one of the twelve "
             ~ "unscanned and green forever.", distinct, sorted));

    size_t scanned = 0;
    size_t guards = 0, rollbacks = 0, recorded = 0, emptyOk = 0;
    string firstGuardFile, firstRollbackFile, missingRecorded, missingEmptyOk;

    foreach (name; kL2Commands) {
        immutable path = buildPath(repoRoot(), "source", "commands", "mesh", name);
        // TERM 2 — every literal exists, asserted BEFORE any count. A count
        // over a file that is not there is not zero, it is nothing.
        assert(exists(path),
            "cannot find source/commands/mesh/" ~ name ~ " at " ~ path
          ~ " — the roster names a file that is not in the tree, so its rows "
          ~ "below would be measuring nothing.");
        immutable code = codeOnly(readText(path));

        // TERM 3 — a PER-FILE non-vacuity floor for the stripper. Every one of
        // the twelve is a `Command` with a `revertImpl` override; a stripper that
        // ate the file would report 0 for every needle and pass in silence.
        assert(countOf(code, "protected override void revertImpl()") == 1,
            "source/commands/mesh/" ~ name ~ ": the comment stripper ate the "
          ~ "file (or the command lost its `revertImpl` override) — every count "
          ~ "below would be 0 for the wrong reason.");
        scanned += code.length;

        immutable size_t g = countOf(code, "!snap.filled");
        if (g > 0 && guards == 0) firstGuardFile = name;
        guards += g;

        immutable size_t r = countOf(code, "snap.restore(");
        if (r > 0 && rollbacks == 0) firstRollbackFile = name;
        rollbacks += r;

        if (countOf(code, "RecordedUndo") == 0 && missingRecorded is null)
            missingRecorded = name;
        else if (countOf(code, "RecordedUndo") > 0) ++recorded;

        // TASK 2500 — the needle moved because the mechanism did, not
        // because the row was relaxed. `revertMapEditEmptyOk(mesh, undo_,
        // applied_)` is gone, along with the per-command `applied_` bit it
        // took: `Command.revert` answers the empty-delta case itself (the
        // flag is raised inside `RecordedUndo.arm`, and only for a NON-empty
        // delta), so every one of the twelve now reverts through the bare
        // `undo_.revert(*mesh)`. A command that lost that line reverts
        // NOTHING while still reporting success, which is the same failure
        // this row has always been watching for.
        if (countOf(code, "undo_.revert(*mesh)") == 0 && missingEmptyOk is null)
            missingEmptyOk = name;
        else if (countOf(code, "undo_.revert(*mesh)") > 0) ++emptyOk;
    }

    assert(scanned >= 30_000,
        format("the census read only %d byte(s) of stripped code across the "
             ~ "twelve — the stripper ate the roster and every count below is "
             ~ "zero for the wrong reason", scanned));

    assert(guards == 0,
        format("the L2 roster still holds %d `!snap.filled` guard(s), first in "
             ~ "%s, expected 0.\n"
             ~ "  That guard is the pre-migration `revert()`: "
             ~ "`if (!snap.filled) return false;`. Task 2110 established that "
             ~ "a `false` from a Model entry's `revert()` does not decline one "
             ~ "step — `CommandHistory.undo` discards that entry AND its whole "
             ~ "trailing suffix (regression 0099). The plan's refusal ruling "
             ~ "says it is DELETED, not translated; the delta-side replacement "
             ~ "is `revertMapEditEmptyOk`, which answers per the command's own "
             ~ "forward.", guards, firstGuardFile));

    assert(rollbacks == 0,
        format("the L2 roster still holds %d `snap.restore(` call(s), first in "
             ~ "%s, expected 0.\n"
             ~ "  Four of the twelve used to roll a snapshot back on a KERNEL "
             ~ "REFUSAL (`polygon_align`, `split_face`, `vertex_split`, "
             ~ "`make_polygon`). Under a delta that is unavailable: "
             ~ "`MeshEditDelta` carries no pre-image of the face array, so "
             ~ "nothing downstream can detect a half-revert. Measured at this "
             ~ "stage, all four kernels refuse BEFORE their first mutation, so "
             ~ "the rollback was undoing something that cannot happen — the "
             ~ "refusal is pre-flight and atomic and the call goes.",
               rollbacks, firstRollbackFile));

    assert(recorded == 12,
        format("only %d of the twelve name `RecordedUndo`%s — a command "
             ~ "without one has no delta to revert and is still snapshot-only, "
             ~ "whatever its `revert()` reads.", recorded,
               missingRecorded is null ? "" : " (first missing: "
                                              ~ missingRecorded ~ ")"));
    assert(emptyOk == 12,
        format("only %d of the twelve revert through `undo_.revert(*mesh)`%s "
             ~ "— see the guard row above for why the empty-delta answer is "
             ~ "`Command.revert`'s and not `false` (task 2500).", emptyOk,
               missingEmptyOk is null ? "" : " (first missing: "
                                             ~ missingEmptyOk ~ ")"));
}
