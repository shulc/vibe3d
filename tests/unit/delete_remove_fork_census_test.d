// delete_remove_fork_census_test — the two TEXT censuses that keep task 1903
// stage L3-b's deletion deleted, and keep the gate it retired from being
// re-manufactured.
//
// WHY A TEXT CENSUS AND NOT A BEHAVIOURAL CELL, for each of the two.
//
//   * W-3-c1 (the fork): a re-added `if (undoTrackerEnabled())` arm in
//     `delete.d` / `remove.d` is INVISIBLE at runtime under the default
//     environment — the default is the delta path, so every behavioural test
//     takes the same branch it takes today and stays green. The only lane that
//     would notice is one that sets the env var, and stage L3-b removed those
//     tests from that lane precisely because they no longer select anything.
//   * W-3-c2 (the vacuous gate): a `[off]`/`[on]` comparison inside
//     `tests/test_undo_tracker_delete.d` is not merely green — it is green
//     under EVERY possible regression, because with one path left it compares
//     a path against itself. Vacuity is not observable at runtime by
//     construction; that is what makes it vacuity.
//
// COMMENTS ARE STRIPPED BEFORE SCANNING, and that is deliberate rather than
// convenient. `test_undo_tracker_delete.d`'s header now EXPLAINS the deleted
// parity gate and names it verbatim, which is exactly the record a later
// reader needs; a census that counted prose would force that explanation out
// of the file to stay green. What is being enumerated is calls, not mentions.
// The stripper is line-comment-only (`//` to end of line) and does not
// understand `/* */` or strings — stated plainly, because the two scanned
// files contain neither construct in a way that could hide a call, and a
// census that overclaims its own precision is worse than one that does not.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score the mutations
// one at a time.
module tests.unit.delete_remove_fork_census_test;

import std.algorithm : canFind, sort, uniq;
import std.array     : array;
import std.file      : exists, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, splitLines;

/// Repository root, rooted at THIS FILE rather than at the working directory.
/// A census that quietly finds nothing when the lane runs from elsewhere is a
/// test that passes for the wrong reason.
private string repoRoot()
{
    // …/tests/unit/<this file>  ->  …
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}

/// The file's text with `//` line comments removed.
private string codeOnly(string text)
{
    string outp;
    foreach (line; text.splitLines()) {
        immutable i = line.indexOf("//");
        outp ~= (i < 0 ? line : line[0 .. i]);
        outp ~= "\n";
    }
    return outp;
}

/// Read a file that MUST exist, and return its code with comments stripped
/// plus its raw byte count.
private void scanFile(string rel, out string code, out size_t bytes)
{
    immutable path = buildPath(repoRoot(), rel);
    assert(exists(path),
        "census target " ~ path ~ " does not exist — the census then scans "
      ~ "nothing and is green forever. If the file MOVED, move this entry "
      ~ "with it");
    immutable raw = readText(path);
    bytes = raw.length;
    code  = codeOnly(raw);
}

unittest // W-3-c1: the undo-tracker fork is gone from delete.d and remove.d
{
    // MUTATIONS, each scored on its own:
    //   (a) re-add one `if (undoTrackerEnabled())` arm to either file — the
    //       token assert reddens naming the file. On its own (a) is satisfied
    //       by a census that never looked at anything, which is what (b) and
    //       the byte floor are for.
    //   (b) duplicate one path in `kTargets` — the de-duplication assert
    //       reddens. This is NOT decoration: a duplicated literal in a list
    //       whose LENGTH is the only other check leaves one file unscanned and
    //       the census green forever.
    static immutable string[] kTargets = [
        "source/commands/mesh/delete.d",
        "source/commands/mesh/remove.d",
    ];

    // The list must name each file once. Checked before anything is read, so
    // a duplicate cannot be masked by the scan itself succeeding.
    auto sorted = kTargets.dup.sort().uniq().array;
    assert(sorted.length == kTargets.length,
        format("the census path list holds %d entries but only %d distinct "
             ~ "ones — a duplicate leaves a target unscanned and this census "
             ~ "green forever", kTargets.length, sorted.length));

    // The tokens, and why each is here. `undoTrackerEnabled` is the fork
    // itself. `MeshSnapshot` is the thing the fork existed to hold: a file
    // that lost the branch but kept the field has not finished the migration,
    // and the class's own byte cost is the §6.4 observable this stage moves.
    static immutable string[] kForbidden = [
        "undoTrackerEnabled",
        "MeshSnapshot",
    ];

    size_t scannedBytes = 0;
    size_t scannedFiles = 0;
    foreach (rel; kTargets) {
        string code; size_t bytes;
        scanFile(rel, code, bytes);
        scannedBytes += bytes;
        ++scannedFiles;
        foreach (tok; kForbidden)
            assert(!code.canFind(tok),
                format("%s still names `%s` in CODE. Stage L3-b deleted the "
                     ~ "`undoTrackerEnabled()` fork and the whole-mesh "
                     ~ "snapshot arm from both destructive commands; a "
                     ~ "re-added arm is invisible to every behavioural test, "
                     ~ "because the default environment takes the delta "
                     ~ "branch either way", rel, tok));
    }

    // Totals READ FROM THE SCAN, never written as literals — a hard-coded
    // count is satisfied by a scan that never ran.
    assert(scannedFiles == kTargets.length,
        format("scanned %d files, the list names %d", scannedFiles,
               kTargets.length));
    assert(scannedBytes >= 100,
        format("the census read %d bytes in total — a scan over an empty or "
             ~ "truncated file finds no forbidden token either", scannedBytes));
}

unittest // W-3-c2: the retired parity gate has not come back
{
    // MUTATION: leave (or re-add) the `[off]` half of `runScenario` in
    // `tests/test_undo_tracker_delete.d`. With one undo path left, its
    // surviving `sameGeometry(undoneOn, undoneOff)` compares a path against
    // itself and is green under every possible regression — a check that
    // cannot come out differently, manufactured by the very commit that
    // deleted the fork.
    string code; size_t bytes;
    scanFile("tests/test_undo_tracker_delete.d", code, bytes);
    assert(bytes >= 100,
        format("the parity-gate file is %d bytes — a scan over a truncated "
             ~ "file finds no forbidden token either", bytes));

    // `undo.tracker` in CODE means the file still flips a toggle that cannot
    // steer the commands it drives. The header names it in prose on purpose;
    // comments are stripped above.
    assert(!code.canFind("undo.tracker"),
        "tests/test_undo_tracker_delete.d issues an `undo.tracker.*` command. "
      ~ "After stage L3-b the toggle does not select a path for `mesh.delete` "
      ~ "or `mesh.remove`, so the call is inert — and it tells the next reader "
      ~ "that the class still has two arms");

    assert(!code.canFind("undoneOff"),
        "tests/test_undo_tracker_delete.d still runs its scenario under both "
      ~ "arms and compares them. That comparison is between one path and "
      ~ "itself now: green before a regression, green after it, and green "
      ~ "again when the fix is reverted. The comparison it used to make is "
      ~ "frozen in tests/fixtures/undo_parity/delete_remove.json and read by "
      ~ "tests/unit/undo_parity_l3_test");

    // ANTI-VACUITY: the file must still be the round-trip test this census is
    // guarding, not an empty stub that trivially names none of the above.
    assert(code.canFind("runScenario") && code.canFind("sameGeometry"),
        "tests/test_undo_tracker_delete.d no longer holds `runScenario` or "
      ~ "`sameGeometry` — then the two absences asserted above say nothing "
      ~ "about a gate and this census is guarding a file that stopped "
      ~ "testing");
}
