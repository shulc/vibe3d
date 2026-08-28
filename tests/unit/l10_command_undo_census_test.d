// l10_command_undo_census_test — task 1903 Stage L10, the stage-closing census.
//
// ALL THIRTEEN COMMANDS OF §5.5's L10 ROW — the topo-misc REINDEXING half —
// ARE OFF THE WHOLE-MESH `MeshSnapshot`.
//
// WHAT IS MEASURED, AND WHY IT IS NOT THE SAME OBSERVABLE L2 CHOSE. Stage L2's
// census (`l2_command_undo_census_test.d`) had to refuse the `private
// MeshSnapshot` DECLARATION count outright: `map_edit_undo.runMapEdit`'s third
// arm is the `VIBE3D_UNDO_TRACKER=0` hatch, which captures a whole-mesh
// snapshot, so every migrated L2 command still declares one and the count
// reads 12 before and after — green on the broken code and green on the fixed
// code. Its own header says *"any stage that inherits this sentence must
// re-choose its observable"*.
//
// THIS FAMILY HAS NO HATCH. Not one of the thirteen ever called
// `undoTrackerEnabled()`, so their recording batches are unconditional and the
// declaration DOES go to zero — measured, not assumed. So this census asserts
// all three observables at once, which is strictly more than L2 could:
//
//   * the `MeshSnapshot` TYPE NAME, at 0 — the declaration and its import;
//   * the pre-migration `revert()` guard `!snap.filled`, at 0;
//   * the `snap.restore(` rollback five of them used on a kernel refusal, at 0.
//
// …and three POSITIVE terms, because a file that holds none of the above and
// none of the below is not migrated, it is deleted:
//
//   * `MeshEditDelta`, `acceptRecordedEdit` and a `delta_.revert(*mesh)` in
//     every one of the thirteen.
//
// THE ONE ENUMERATED DIVERGENCE. Twelve of the thirteen hold their pre-op
// selection in `DenseSelectionUndo`; `vert_merge.d` — the discriminating
// migration, which landed one commit earlier — holds a `SelectionSnapshot`
// plus `captureSelectedEdgeEnds` instead, and carries a standing
// `faceSelectionOrder` exception in `undo_parity_l10_test.d` because of it.
// That is asserted BY NAME rather than tolerated by a count: a THIRTEENTH file
// dropping `DenseSelectionUndo`, or `vert_merge` quietly gaining it without
// its exception being retired, both redden here.
//
// THE COMMENT STRIPPER IS LOAD-BEARING, not hygiene: every migrated file
// EXPLAINS in a comment that the `if (!snap.filled) return false;` guard was
// deleted rather than translated, and quotes it verbatim. A census that did
// not strip comments would forbid its own explanation and could never be
// green. It is the SAME stripper `l2_command_undo_census_test` uses, imported
// rather than copied.
//
// LANE: `dub test --config=tests` (lane U) — a `tests/unit/**` block.
module tests.unit.l10_command_undo_census_test;

import std.file   : readText, exists;
import std.path   : dirName, buildPath;
import std.format : format;
import std.algorithm : sort, uniq;
import std.array  : array;

import tests.unit.l2_command_undo_census_test : codeOnly, countOf;

private string repoRoot()
{
    // …/tests/unit/<this file>  ->  …
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}

/// The thirteen of §5.5's L10 row, by file. A HAND-WRITTEN list and not a
/// directory walk, on purpose: the claim is about THIS ROSTER, and a walk
/// would silently absorb a fourteenth command written later without anyone
/// deciding it belongs to L10.
private enum string[13] kL10Commands = [
    "bridge.d", "collapse.d", "detriangulate.d", "edge_join.d", "merge.d",
    "quadruple.d", "reduce.d", "sweep.d", "triple.d", "unify.d",
    "vert_join.d", "vert_merge.d", "weld_vertex_pair.d",
];

/// The one member that does NOT hold a `DenseSelectionUndo`, named rather than
/// counted. See this file's header.
private enum string kDenseSelectionUndoExempt = "vert_merge.d";

unittest // the thirteen are off the whole-mesh snapshot
{
    // TERM 1 — the roster is thirteen DISTINCT names. A typo throws loudly
    // (the `exists` assert below); a DUPLICATE is silent, and it leaves one
    // command unscanned while the count of ROWS still reads thirteen.
    auto sorted = kL10Commands.dup;
    sort(sorted);
    immutable size_t distinct = sorted.uniq.array.length;
    assert(distinct == 13,
        format("the L10 roster names only %d DISTINCT files across its "
             ~ "thirteen entries: %s. A duplicated literal leaves one of the "
             ~ "thirteen unscanned and green forever.", distinct, sorted));

    size_t scanned = 0;
    size_t snapType = 0, guards = 0, rollbacks = 0;
    size_t deltas = 0, accepts = 0, replays = 0, dense = 0;
    string firstSnapFile, firstGuardFile, firstRollbackFile;
    string missingDelta, missingAccept, missingReplay;
    string[] denseFiles;

    foreach (name; kL10Commands) {
        immutable path = buildPath(repoRoot(), "source", "commands", "mesh", name);
        // TERM 2 — every literal exists, asserted BEFORE any count. A count
        // over a file that is not there is not zero, it is nothing.
        assert(exists(path),
            "cannot find source/commands/mesh/" ~ name ~ " at " ~ path
          ~ " — the roster names a file that is not in the tree, so its rows "
          ~ "below would be measuring nothing.");
        immutable code = codeOnly(readText(path));

        // TERM 3 — a PER-FILE non-vacuity floor for the stripper. Every one of
        // the thirteen is a `Command` with exactly one `revertImpl` override; a
        // stripper that ate the file would report 0 for every needle and pass
        // in silence.
        assert(countOf(code, "protected override void revertImpl()") == 1,
            "source/commands/mesh/" ~ name ~ ": the comment stripper ate the "
          ~ "file (or the command lost its `revertImpl` override) — every count "
          ~ "below would be 0 for the wrong reason.");
        scanned += code.length;

        immutable size_t s = countOf(code, "MeshSnapshot");
        if (s > 0 && snapType == 0) firstSnapFile = name;
        snapType += s;

        immutable size_t g = countOf(code, "!snap.filled");
        if (g > 0 && guards == 0) firstGuardFile = name;
        guards += g;

        immutable size_t r = countOf(code, "snap.restore(");
        if (r > 0 && rollbacks == 0) firstRollbackFile = name;
        rollbacks += r;

        if (countOf(code, "MeshEditDelta") > 0) ++deltas;
        else if (missingDelta is null) missingDelta = name;

        if (countOf(code, "acceptRecordedEdit") > 0) ++accepts;
        else if (missingAccept is null) missingAccept = name;

        if (countOf(code, "delta_.revert(*mesh)") > 0) ++replays;
        else if (missingReplay is null) missingReplay = name;

        if (countOf(code, "DenseSelectionUndo") > 0) { ++dense; denseFiles ~= name; }
    }

    assert(scanned >= 30_000,
        format("the census read only %d byte(s) of stripped code across the "
             ~ "thirteen — the stripper ate the roster and every count below "
             ~ "is zero for the wrong reason", scanned));

    // ---- the three things the migration DELETES -------------------------
    assert(snapType == 0,
        format("the L10 roster still names `MeshSnapshot` %d time(s), first "
             ~ "in %s, expected 0.\n"
             ~ "  Unlike stage L2's roster this family has NO hatch arm — not "
             ~ "one of the thirteen ever called `undoTrackerEnabled()` — so "
             ~ "the type name goes to zero rather than surviving as the "
             ~ "hatch's image. A non-zero here is a command that kept, or got "
             ~ "back, a whole-mesh capture beside its delta: two writers over "
             ~ "one restore, which is how a restore starts disagreeing with "
             ~ "itself.", snapType, firstSnapFile));

    assert(guards == 0,
        format("the L10 roster still holds %d `!snap.filled` guard(s), first "
             ~ "in %s, expected 0.\n"
             ~ "  That guard is the pre-migration `revert()`: "
             ~ "`if (!snap.filled) return false;`. Its delta-side replacement "
             ~ "is `if (!recorded_) return false;`, which answers for the same "
             ~ "condition — an instance whose `evaluate` refused — and is "
             ~ "correct only because the funnel records no history entry for a "
             ~ "refused forward.", guards, firstGuardFile));

    assert(rollbacks == 0,
        format("the L10 roster still holds %d `snap.restore(` call(s), first "
             ~ "in %s, expected 0.\n"
             ~ "  Five sites rolled a whole-mesh snapshot back on a KERNEL "
             ~ "REFUSAL (`collapse` x3, `vert_join`, `merge`, plus "
             ~ "`bridge`'s cap arm). Under a delta the equivalent is "
             ~ "`delta_.revert(*mesh)` then DISCARD, and never \"close the "
             ~ "batch and record an empty delta\", which lands a history entry "
             ~ "describing nothing (plan §S-6).",
               rollbacks, firstRollbackFile));

    // ---- the three things it ADDS ---------------------------------------
    assert(deltas == 13,
        format("only %d of the thirteen name `MeshEditDelta`%s — a command "
             ~ "without one has no delta to revert and is still snapshot-only, "
             ~ "whatever its `revert()` reads.", deltas,
               missingDelta is null ? "" : " (first missing: " ~ missingDelta ~ ")"));
    assert(accepts == 13,
        format("only %d of the thirteen call `acceptRecordedEdit`%s — that is "
             ~ "the shipped post-close ruling (plan §S-6): `affected == 0` is "
             ~ "a refusal, and `affected > 0` over an EMPTY delta ticks "
             ~ "`changeBus.emptyDeltaOverMutation` instead of passing "
             ~ "silently.", accepts,
               missingAccept is null ? "" : " (first missing: " ~ missingAccept ~ ")"));
    assert(replays == 13,
        format("only %d of the thirteen replay `delta_.revert(*mesh)`%s — a "
             ~ "file that holds a delta and never replays it answers true from "
             ~ "`revert()` over a mesh it did not restore.", replays,
               missingReplay is null ? "" : " (first missing: " ~ missingReplay ~ ")"));

    // ---- the ONE enumerated divergence, by NAME -------------------------
    assert(dense == 12,
        format("%d of the thirteen hold a `DenseSelectionUndo`, expected 12: "
             ~ "%s. Twelve is not a budget — it is thirteen minus the one "
             ~ "member named below.", dense, denseFiles));
    bool exemptHasDense = false;
    foreach (n; denseFiles) if (n == kDenseSelectionUndoExempt) exemptHasDense = true;
    assert(!exemptHasDense,
        "source/commands/mesh/" ~ kDenseSelectionUndoExempt ~ " now holds a "
      ~ "`DenseSelectionUndo`, and it is the one member this census records as "
      ~ "NOT holding one — it carries a `SelectionSnapshot` plus "
      ~ "`captureSelectedEdgeEnds`, and BECAUSE of that it carries a standing "
      ~ "`faceSelectionOrder` exception in tests/unit/undo_parity_l10_test.d "
      ~ "(`SelectionSnapshot.restore` re-zeroes an unselected element's order "
      ~ "stamp; `DenseSelectionUndo` restores it). If this file has been moved "
      ~ "onto the dense image, RETIRE THAT EXCEPTION in the same commit — "
      ~ "otherwise it becomes a licence over a plane that now agrees.");
}
