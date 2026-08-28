// l6_command_undo_census_test — task 1903, the stage-closing census for
// stage L6 (the DUPLICATION family) and the vertex half of stage L7.
//
// SIX COMMANDS — the five of §5.5's L6 row plus `mesh.vertexBevel` (L7-d) —
// ARE OFF THE WHOLE-MESH `MeshSnapshot`.
//
// WHY THE TWO STAGES SHARE ONE CENSUS. They landed in one lane, and the L7-d
// arming rests on a payload whose second-family witness L6 was EXPECTED to be
// and measurably is NOT (see the two readers' headers). A reader who splits
// them later has to re-derive that link; a single roster with the reason at
// the top does not.
//
// WHAT IS MEASURED, AND WHY IT IS NOT THE SAME OBSERVABLE L2 CHOSE. Stage L2's
// census (`l2_command_undo_census_test.d`) had to refuse the `private
// MeshSnapshot` DECLARATION count outright, because `map_edit_undo.runMapEdit`
// keeps a whole-mesh snapshot alive for every L2 command through the
// `VIBE3D_UNDO_TRACKER=0` hatch — so the count reads the same before and after
// and is green on the broken code. Its header says any inheriting stage must
// RE-CHOOSE its observable.
//
// THIS ROSTER HAS NO HATCH EITHER — measured: not one of the six ever called
// `undoTrackerEnabled()` — so all three deletion terms really do go to zero:
//
//   * the `MeshSnapshot` TYPE NAME, at 0 — the declaration and its import;
//   * the pre-migration `revert()` guard `!snap.filled`, at 0;
//   * the `snap.restore(` rollback, at 0.
//
// …and four POSITIVE terms, because a file holding none of the above and none
// of the below is not migrated, it is deleted:
//
//   * `MeshEditDelta`, `acceptRecordedEdit`, `delta_.revert(*mesh)` and
//     `DenseSelectionUndo` in every one of the six.
//
// NO ENUMERATED DIVERGENCE, and that is itself a claim. Stage L10's census
// carries one (`vert_merge.d` holds a bare `SelectionSnapshot` and therefore a
// standing `faceSelectionOrder` exception). All six here hold the dense image
// and NEITHER reader carries a per-plane exception table — measured, both
// compare plane-for-plane with no licence of any kind. A divergence appearing
// later has to be argued into this file rather than absorbed by a count.
//
// A FOURTH TERM THIS STAGE OWES AND L10 DID NOT: `kDuplicateEditScope` in the
// five L6 files. The five kernels are `Mesh` MEMBERS, so there is no
// `mesh_ops/` file to hang a scope constant off, and a per-command literal in
// five files is exactly the shape one shared constant exists to stop. It is
// asserted because a file that spells the scope inline is a file whose
// declared scope can drift from its siblings' without anything noticing.
//
// THE COMMENT STRIPPER IS LOAD-BEARING, not hygiene: every migrated file
// EXPLAINS in a comment that the `if (!snap.filled) return false;` guard was
// deleted rather than translated, and quotes it verbatim. A census that did
// not strip comments would forbid its own explanation and could never be
// green. It is the SAME stripper `l2_command_undo_census_test` uses, imported
// rather than copied — a private copy drifts, and then two gates answer
// differently to "what counts as code".
//
// LANE: `dub test --config=tests` (lane U) — a `tests/unit/**` block.
module tests.unit.l6_command_undo_census_test;

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

/// The five of §5.5's L6 row plus the one of L7-d, by file. A HAND-WRITTEN
/// list and not a directory walk, on purpose: the claim is about THIS ROSTER,
/// and a walk would silently absorb a seventh command written later without
/// anyone deciding it belongs here.
///
/// `paste.d` IS NOT IN IT, and that is a decision rather than an oversight:
/// `mesh.paste` shares `Mesh.appendFaceRaw` with this family but is declined
/// at §6.6 and still holds its snapshot. A roster that absorbed it would be
/// asserting a migration nobody performed.
private enum string[6] kL6Commands = [
    "array.d", "clone_.d", "duplicate.d", "mirror.d", "radial_array.d",
    "vertex_bevel.d",
];

/// The five that take the SHARED scope constant. `vertex_bevel.d` takes
/// `kBevelVertexEditScope` instead — its kernel is a `mesh_ops/` free function
/// with its own constant, which is the convention this stage did not have
/// available for the other five.
private enum string kSharedScopeExempt = "vertex_bevel.d";

unittest // the six are off the whole-mesh snapshot
{
    // TERM 1 — the roster is six DISTINCT names. A typo throws loudly (the
    // `exists` assert below); a DUPLICATE is silent, and it leaves one command
    // unscanned while the count of ROWS still reads six.
    auto sorted = kL6Commands.dup;
    sort(sorted);
    immutable size_t distinct = sorted.uniq.array.length;
    assert(distinct == 6,
        format("the L6 roster names only %d DISTINCT files across its six "
             ~ "entries: %s. A duplicated literal leaves one of the six "
             ~ "unscanned and green forever.", distinct, sorted));

    size_t scanned = 0;
    size_t snapType = 0, guards = 0, rollbacks = 0;
    size_t deltas = 0, accepts = 0, replays = 0, dense = 0, scopes = 0;
    string firstSnapFile, firstGuardFile, firstRollbackFile;
    string missingDelta, missingAccept, missingReplay, missingDense;
    string[] scopeFiles;

    foreach (name; kL6Commands) {
        immutable path = buildPath(repoRoot(), "source", "commands", "mesh", name);
        // TERM 2 — every literal exists, asserted BEFORE any count. A count
        // over a file that is not there is not zero, it is nothing.
        assert(exists(path),
            "cannot find source/commands/mesh/" ~ name ~ " at " ~ path
          ~ " — the roster names a file that is not in the tree, so its rows "
          ~ "below would be measuring nothing.");
        immutable code = codeOnly(readText(path));

        // TERM 3 — a PER-FILE non-vacuity floor for the stripper. Every one of
        // the six is a `Command` with exactly one `revert` override; a
        // stripper that ate the file would report 0 for every needle and pass
        // in silence.
        assert(countOf(code, "override bool revert()") == 1,
            "source/commands/mesh/" ~ name ~ ": the comment stripper ate the "
          ~ "file (or the command lost its `revert` override) — every count "
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

        if (countOf(code, "DenseSelectionUndo") > 0) ++dense;
        else if (missingDense is null) missingDense = name;

        if (countOf(code, "kDuplicateEditScope") > 0) { ++scopes; scopeFiles ~= name; }
    }

    assert(scanned >= 12_000,
        format("the census read only %d byte(s) of stripped code across the "
             ~ "six — the stripper ate the roster and every count below is "
             ~ "zero for the wrong reason", scanned));

    // ---- the three things the migration DELETES -------------------------
    assert(snapType == 0,
        format("the L6/L7-d roster still names `MeshSnapshot` %d time(s), "
             ~ "first in %s, expected 0.\n"
             ~ "  This family has NO hatch arm — not one of the six ever "
             ~ "called `undoTrackerEnabled()` — so the type name goes to zero "
             ~ "rather than surviving as the hatch's image. A non-zero here is "
             ~ "a command that kept, or got back, a whole-mesh capture beside "
             ~ "its delta: two writers over one restore.", snapType,
               firstSnapFile));

    assert(guards == 0,
        format("the L6/L7-d roster still holds %d `!snap.filled` guard(s), "
             ~ "first in %s, expected 0.\n"
             ~ "  That guard is the pre-migration `revert()`: "
             ~ "`if (!snap.filled) return false;`. Its delta-side replacement "
             ~ "is `if (!recorded_) return false;`, which answers for the same "
             ~ "condition — an instance whose `evaluate` refused — and is "
             ~ "correct only because the funnel records no history entry for a "
             ~ "refused forward.", guards, firstGuardFile));

    assert(rollbacks == 0,
        format("the L6/L7-d roster still holds %d `snap.restore(` call(s), "
             ~ "first in %s, expected 0.\n"
             ~ "  All six discarded their capture on a kernel refusal with "
             ~ "`snap = MeshSnapshot.init;` rather than restoring it, so this "
             ~ "term was already 0 before the migration and is asserted as a "
             ~ "REGRESSION guard rather than as a migration result: a "
             ~ "`snap.restore(` appearing here would be a whole-mesh rollback "
             ~ "re-entering a family whose undo is now a delta.",
               rollbacks, firstRollbackFile));

    // ---- the four things it ADDS ----------------------------------------
    assert(deltas == 6,
        format("only %d of the six name `MeshEditDelta`%s — a command without "
             ~ "one has no delta to revert and is still snapshot-only, "
             ~ "whatever its `revert()` reads.", deltas,
               missingDelta is null ? "" : " (first missing: " ~ missingDelta ~ ")"));
    assert(accepts == 6,
        format("only %d of the six call `acceptRecordedEdit`%s — that is the "
             ~ "shipped post-close ruling (plan §S-6): `affected == 0` is a "
             ~ "refusal, and `affected > 0` over an EMPTY delta ticks "
             ~ "`changeBus.emptyDeltaOverMutation` instead of passing "
             ~ "silently. FOR THIS FAMILY THAT SECOND ARM IS THE WHOLE POINT: "
             ~ "`mesh.duplicate` and `mesh.clone` reach no tracker hook at all "
             ~ "without `Mesh.recordBulkAppendRound`, so without it the "
             ~ "migration would ship `status:error` over a duplicated mesh.",
               accepts,
               missingAccept is null ? "" : " (first missing: " ~ missingAccept ~ ")"));
    assert(replays == 6,
        format("only %d of the six replay `delta_.revert(*mesh)`%s — a file "
             ~ "that holds a delta and never replays it answers true from "
             ~ "`revert()` over a mesh it did not restore.", replays,
               missingReplay is null ? "" : " (first missing: " ~ missingReplay ~ ")"));
    assert(dense == 6,
        format("only %d of the six hold a `DenseSelectionUndo`%s. The "
             ~ "armed-revert residual for BOTH families is Select-class and "
             ~ "NOTHING ELSE — measured, exact, both ways — so the dense image "
             ~ "is the entire remainder of their undo. A file without it "
             ~ "restores the geometry and drops the selection, which no count "
             ~ "assertion anywhere sees.", dense,
               missingDense is null ? "" : " (first missing: " ~ missingDense ~ ")"));

    // ---- the shared scope constant, in the five that can take it --------
    assert(scopes == 5,
        format("%d of the six name `kDuplicateEditScope`, expected 5: %s. "
             ~ "Five is not a budget — it is six minus `%s`, whose kernel is a "
             ~ "`mesh_ops/` free function and therefore has its own "
             ~ "`kBevelVertexEditScope`. A file that spells the scope inline "
             ~ "instead can drift from its siblings' declaration without "
             ~ "anything noticing, and the scope is what the change bus "
             ~ "publishes.", scopes, scopeFiles, kSharedScopeExempt));
    foreach (n; scopeFiles)
        assert(n != kSharedScopeExempt,
            "source/commands/mesh/" ~ kSharedScopeExempt ~ " now names "
          ~ "`kDuplicateEditScope`. Its kernel is `bevelVerticesByMask`, whose "
          ~ "own scope constant is `kBevelVertexEditScope`; declaring the "
          ~ "duplication family's scope on it would publish a change class its "
          ~ "kernel does not make.");
}

// ---------------------------------------------------------------------------
// THE ARMING THIS PAIR OF STAGES ADDED, AND THE ONE IT DID NOT.
//
// L7-d arms `bevelVerticesByMask`. L6 arms NOTHING — its row named
// `arrayFacesGrid`, which is (a) measured harmful by Stage K and (b)
// unreachable from all five commands. Both facts are asserted here as SOURCE
// terms, because `face_reindex_arming_test.d`'s own census answers "which
// kernels arm" and cannot answer "which kernels the L6 COMMANDS can reach".
// ---------------------------------------------------------------------------
unittest
{
    immutable root = repoRoot();

    // (a) the vertex chamfer IS armed, at its single rewrite.
    immutable bv = codeOnly(readText(
        buildPath(root, "source", "mesh_ops", "bevel_vertex.d")));
    assert(countOf(bv, "faceReindexScope()") == 1,
        format("mesh_ops/bevel_vertex.d names `faceReindexScope()` %d time(s), "
             ~ "expected exactly 1. Zero means stage L7-d's arming is gone and "
             ~ "`mesh.vertexBevel`'s delta restores no face array; more than "
             ~ "one means a second rewrite was armed under a scope this "
             ~ "kernel's single `rewriteFaces` call does not have.",
               countOf(bv, "faceReindexScope()")));

    // (b) NO L6 command file reaches `arrayFacesGrid`. The kernel is not
    // struck from the tree — the interactive Array TOOL is its only production
    // caller and that is Stage M's — but a COMMAND acquiring it would inherit
    // Stage K's measured double-revert, on a path whose undo is now a delta.
    foreach (name; kL6Commands) {
        immutable code = codeOnly(readText(
            buildPath(root, "source", "commands", "mesh", name)));
        assert(countOf(code, "arrayFacesGrid") == 0,
            "source/commands/mesh/" ~ name ~ " now calls `arrayFacesGrid`. "
          ~ "Stage K measured that kernel's arming as making the revert WORSE "
          ~ "(E=45 disarmed against E=48 armed) and left it DISARMED, and its "
          ~ "own growth is hook-free, so a command reaching it would record a "
          ~ "delta describing only the weld pass and land on a third mesh "
          ~ "while answering true. It belongs to the Array TOOL and to stage "
          ~ "M; `mesh.array` calls `Mesh.arrayFaces`, the 1D line kernel.");
    }

    // (c) …and the tool that DOES call it still does, so (b) is a statement
    // about the commands and not about a kernel nobody uses any more.
    immutable tool = codeOnly(readText(
        buildPath(root, "source", "tools", "alignment", "array_tool.d")));
    assert(countOf(tool, "arrayFacesGrid") >= 1,
        "source/tools/alignment/array_tool.d no longer calls "
      ~ "`arrayFacesGrid`, so the assertion above is now vacuous — it would "
      ~ "be satisfied by a kernel with no callers at all.");
}
