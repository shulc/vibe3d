// l8_command_undo_census_test — task 1903, the stage-closing census for stage
// L8, the EXTRUDE / EXTEND family.
//
// THE ROSTER IS SIX AND THE ANSWER IS FOUR AND TWO, so this census has TWO
// halves and neither of them is the other's negation. Four commands
// (`face_extrude`, `smooth_shift`, `stroke_extrude`, `vertex_extrude`) are off
// the whole-mesh `MeshSnapshot`; two (`edge_extrude`, `edge_extend`) are
// DECLINED on a measurement and still hold theirs. A census that only counted
// the deletions would go green the day somebody "finished the family" by
// migrating the two that must not be, and a census that only counted the
// survivors would go green if nobody had migrated anything.
//
// WHY THE TWO ARE DECLINED, in one sentence — the argument is at each class's
// own declaration (§6.6's convention) and the MEASUREMENT is in
// `tests/unit/l8_extrude_delta_test.d`'s block 4: both edge kernels end in a
// STATED per-corner drop (`CornerDrop.SweptSurfaceNoLaw`, task 0830) that the
// whole-mesh snapshot undoes and the op-log cannot, so migrating them would
// turn a shipped-correct undo into one that zeroes the UV map.
//
// WHAT IS MEASURED, AND WHY IT IS NOT THE `private MeshSnapshot` DECLARATION
// COUNT. Stage L2's census had to refuse that observable outright, because
// `map_edit_undo.runMapEdit` keeps a whole-mesh snapshot alive for every L2
// command through the `VIBE3D_UNDO_TRACKER=0` hatch, so the count reads the
// same before and after and is green on the broken code. Its header says any
// inheriting stage must RE-CHOOSE. MEASURED for this roster: not one of the
// six ever called `undoTrackerEnabled()` — the two hatched `edge_extend` /
// `edge_extrude` names CLAUDE.md lists are the interactive TOOLS under
// `source/tools/edit/`, NOT these commands (plan §0.2, §6.3's S8 census) — so
// the three deletion terms really do go to zero on the migrated four.
//
// THE COMMENT STRIPPER IS LOAD-BEARING, not hygiene, and on this roster it is
// load-bearing TWICE. Every migrated file EXPLAINS in a comment that the
// `if (!snap.filled) return false;` guard was deleted rather than translated,
// and quotes it verbatim; and both DECLINED files carry a long doc comment
// that names `MeshSnapshot`, `MeshEditDelta` and `acceptRecordedEdit` while
// using none of them. A census that did not strip comments would forbid its
// own explanation AND would read the declines as migrated. It is the SAME
// stripper `l2_command_undo_census_test` uses, imported rather than copied.
//
// LANE: `dub test --config=tests` (lane U) — a `tests/unit/**` block.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the two blocks in
// isolation when scoring a mutation.
module tests.unit.l8_command_undo_census_test;

import std.file      : readText, exists;
import std.path      : dirName, buildPath;
import std.format    : format;
import std.algorithm : sort, uniq;
import std.array     : array;

import tests.unit.l2_command_undo_census_test : codeOnly, countOf;

private string repoRoot()
{
    // …/tests/unit/<this file>  ->  …
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}

/// The four of §5.5's L8 row that moved, by file. A HAND-WRITTEN list and not
/// a directory walk, on purpose: the claim is about THIS ROSTER, and a walk
/// would silently absorb a command written later without anyone deciding it
/// belongs here.
private enum string[4] kL8Migrated = [
    "face_extrude.d", "smooth_shift.d", "stroke_extrude.d", "vertex_extrude.d",
];

/// …and the two that did NOT, which is the same row's other half.
private enum string[2] kL8Declined = [
    "edge_extrude.d", "edge_extend.d",
];

private string codeOf(string name)
{
    immutable path = buildPath(repoRoot(), "source", "commands", "mesh", name);
    // Every literal exists, asserted BEFORE any count. A count over a file
    // that is not there is not zero, it is nothing.
    assert(exists(path),
        "cannot find source/commands/mesh/" ~ name ~ " at " ~ path
      ~ " — the roster names a file that is not in the tree, so its rows "
      ~ "below would be measuring nothing.");
    immutable code = codeOnly(readText(path));
    // A PER-FILE non-vacuity floor for the stripper. All six are `Command`s
    // with exactly one `revertImpl` override; a stripper that ate the file would
    // report 0 for every needle and pass in silence.
    assert(countOf(code, "protected override void revertImpl()") == 1,
        "source/commands/mesh/" ~ name ~ ": the comment stripper ate the file "
      ~ "(or the command lost its `revertImpl` override) — every count below "
      ~ "would be 0 for the wrong reason.");
    return code;
}

private void assertDistinct(const(string)[] roster, string which)
{
    // A typo throws loudly (the `exists` assert above); a DUPLICATE is silent,
    // and it leaves one command unscanned while the count of ROWS still reads
    // right.
    auto sorted = roster.dup;
    sort(sorted);
    assert(sorted.uniq.array.length == roster.length,
        format("the L8 %s roster names only %d DISTINCT files across its %d "
             ~ "entries: %s. A duplicated literal leaves one command unscanned "
             ~ "and green forever.", which, sorted.uniq.array.length,
               roster.length, sorted));
}

unittest // half 1 — the FOUR are off the whole-mesh snapshot
{
    assertDistinct(kL8Migrated[], "migrated");

    size_t scanned = 0;
    size_t snapType = 0, guards = 0, rollbacks = 0;
    size_t deltas = 0, accepts = 0, replays = 0, dense = 0, inverses = 0;
    string firstSnapFile, firstGuardFile, firstRollbackFile;
    string missingDelta, missingAccept, missingReplay, missingDense,
           missingInverse;

    foreach (name; kL8Migrated) {
        immutable code = codeOf(name);
        scanned += code.length;

        // NO HATCH ON THIS ROSTER — asserted, not assumed. If one appeared,
        // the three deletion terms below would stop meaning what they say and
        // this census would inherit stage L2's problem without noticing.
        assert(countOf(code, "undoTrackerEnabled") == 0,
            "source/commands/mesh/" ~ name ~ " calls `undoTrackerEnabled()`. "
          ~ "No L8 command ever did — the hatched names are the TOOLS under "
          ~ "source/tools/edit/ — and with a hatch here the `MeshSnapshot` "
          ~ "count below would survive as the hatch's image rather than going "
          ~ "to zero, exactly the shape that made stage L2 refuse this "
          ~ "observable.");

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

        if (countOf(code, "DenseSelectionUndo") > 0) ++dense;
        else if (missingDense is null) missingDense = name;

        if (countOf(code, "override bool isOperationInverse() const") > 0)
            ++inverses;
        else if (missingInverse is null) missingInverse = name;
    }

    assert(scanned >= 8_000,
        format("the census read only %d byte(s) of stripped code across the "
             ~ "four — the stripper ate the roster and every count below is "
             ~ "zero for the wrong reason", scanned));

    // ---- the three things the migration DELETES -------------------------
    assert(snapType == 0,
        format("the L8 migrated roster still names `MeshSnapshot` %d time(s), "
             ~ "first in %s, expected 0.\n"
             ~ "  A non-zero here is a command that kept, or got back, a "
             ~ "whole-mesh capture beside its delta: two writers over one "
             ~ "restore.", snapType, firstSnapFile));

    assert(guards == 0,
        format("the L8 migrated roster still holds %d `!snap.filled` "
             ~ "guard(s), first in %s, expected 0.\n"
             ~ "  That guard is the pre-migration `revert()`: "
             ~ "`if (!snap.filled) return false;`. Its delta-side replacement "
             ~ "is `if (!recorded_) return false;`, which answers for the same "
             ~ "condition — an instance whose `evaluate` refused — and is "
             ~ "correct only because the funnel records no history entry for a "
             ~ "refused forward.", guards, firstGuardFile));

    assert(rollbacks == 0,
        format("the L8 migrated roster still holds %d `snap.restore(` "
             ~ "call(s), first in %s, expected 0.\n"
             ~ "  All four discarded their capture on a kernel refusal with "
             ~ "`snap = MeshSnapshot.init;` rather than restoring it, so this "
             ~ "term was already 0 before the migration and is asserted as a "
             ~ "REGRESSION guard rather than as a migration result.",
               rollbacks, firstRollbackFile));

    // ---- the five things it ADDS ----------------------------------------
    assert(deltas == 4,
        format("only %d of the four name `MeshEditDelta`%s — a command "
             ~ "without one has no delta to revert and is still snapshot-only",
               deltas, missingDelta is null ? "" : " (missing: " ~ missingDelta ~ ")"));
    assert(accepts == 4,
        format("only %d of the four call `acceptRecordedEdit`%s — without it a "
             ~ "mutation that recorded nothing would be accepted, and its undo "
             ~ "would do nothing while `/api/history` showed an entry",
               accepts, missingAccept is null ? "" : " (missing: " ~ missingAccept ~ ")"));
    assert(replays == 4,
        format("only %d of the four replay `delta_.revert(*mesh)`%s", replays,
               missingReplay is null ? "" : " (missing: " ~ missingReplay ~ ")"));
    assert(dense == 4,
        format("only %d of the four hold a `DenseSelectionUndo`%s — the "
             ~ "armed-revert residual of every kernel in this family is "
             ~ "Select-class and NOTHING else, so the dense image is the whole "
             ~ "of what the op-log does not restore. A command without one "
             ~ "loses its selection on Ctrl+Z with its geometry perfectly "
             ~ "intact, which no geometry assertion can see", dense,
               missingDense is null ? "" : " (missing: " ~ missingDense ~ ")"));
    assert(inverses == 4,
        format("only %d of the four override `isOperationInverse()`%s — "
             ~ "`/api/history`'s `opInverse` field then reports a delta-backed "
             ~ "entry as snapshot-backed", inverses,
               missingInverse is null ? "" : " (missing: " ~ missingInverse ~ ")"));
}

unittest // half 2 — the TWO declines still hold their snapshot, and say why
{
    assertDistinct(kL8Declined[], "declined");

    foreach (name; kL8Declined) {
        immutable code = codeOf(name);

        // The decline is a STATE, and it is asserted as THREE TERMS, not one.
        // They are the exact mirror of half 1's three deletion terms, and each
        // names a different way the decline could be silently undone. A single
        // `MeshSnapshot` count would NOT do it — measured: deleting both the
        // field and its `capture(` leaves the `import` and the
        // `snap = MeshSnapshot.init;` refusal arm behind, so the type name is
        // still there twice over a file that no longer captures anything.
        foreach (needle, why; [
            "MeshSnapshot.capture(":
                "no longer CAPTURES a whole-mesh snapshot, so its undo has "
              ~ "nothing to restore from",
            // TASK 2500 — the middle term moved with the mechanism. The
            // per-command `if (!snap.filled) return false;` guard is gone
            // tree-wide: `Command.revert` reads ONE flag and answers the
            // no-image case itself, and this file's flag is raised in the
            // statement beside its capture. A file that keeps the capture and
            // the restore but LOSES the raise reverts nothing while reporting
            // success — the same failure the old needle watched for, one
            // layer up.
            "noteUndoRecorded()":
                "lost the `noteUndoRecorded()` raise beside its capture, so "
              ~ "`Command.revert` would answer `true` without restoring "
              ~ "anything",
            "snap.restore(":
                "no longer RESTORES from the snapshot, so its Ctrl+Z is a "
              ~ "no-op that still reports success",
        ]) {
            assert(countOf(code, needle) == 1,
                format("source/commands/mesh/%s %s (`%s` appears %d time(s), "
                     ~ "expected 1).\n"
                     ~ "  Stage L8-d DECLINED this command on a MEASUREMENT: "
                     ~ "its kernel's stated `SweptSurfaceNoLaw` corner drop is "
                     ~ "restored by the whole-mesh snapshot and NOT by the "
                     ~ "op-log, so migrating it is a regression in the "
                     ~ "per-corner map — invisible to every geometry check. If "
                     ~ "the measurement has changed, "
                     ~ "`tests/unit/l8_extrude_delta_test.d`'s block 4 says so "
                     ~ "in its own message and this line moves WITH it, not "
                     ~ "before it.", name, why, needle,
                       countOf(code, needle)));
        }

        assert(countOf(code, "MeshEditDelta") == 0
            && countOf(code, "acceptRecordedEdit") == 0,
            "source/commands/mesh/" ~ name ~ " holds BOTH a snapshot and a "
          ~ "delta. That is two writers over one restore and it is worse than "
          ~ "either alone: whichever runs second silently overwrites the "
          ~ "other's answer.");

        // The kernel-side half of the same decision. If this vanished, the
        // reason above would still read as true while the thing it describes
        // was gone.
        immutable string kernel = buildPath(repoRoot(), "source", "mesh_ops",
                                            "extrude.d");
        immutable kcode = codeOnly(readText(kernel));
        assert(countOf(kcode, "CornerDrop.SweptSurfaceNoLaw") >= 2,
            "source/mesh_ops/extrude.d no longer makes its stated per-corner "
          ~ "drops. THAT IS GOOD NEWS and it retires stage L8-d: re-measure "
          ~ "`tests/unit/l8_extrude_delta_test.d`'s block 4 and migrate the "
          ~ "two declined commands, deleting the reason recorded at each "
          ~ "class declaration.");
    }
}
