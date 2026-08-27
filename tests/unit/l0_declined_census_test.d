// l0_declined_census_test — the gate under task 1903 Stage L0's CLOSING
// decisions (owner's rulings of 2026-08-27, Q2 / Q5).
//
// ===========================================================================
// WHY A CENSUS AT ALL, AND WHY THIS PARTICULAR ONE
// ===========================================================================
// L0 closed three of its groups by DECISION rather than by migration:
//
//   * `mesh.hide` / `hideUnselected` / `hideInvert` / `unhideAll`,
//     `mesh.subpatch_toggle` and `mesh.setPart` are PERMANENTLY DENSE — they
//     keep their whole-array undo capture for good and never move to a
//     recorded `MeshEditDelta`;
//   * `MeshOpEntry.Kind.HideDelta` and `Kind.SubpatchDelta` are DORMANT —
//     they get no production publisher, from L0 or otherwise.
//
// Each of those five facts is written down at its own declaration, in prose.
// Prose is not a check. A census over a comment is the WEAKEST instrument in
// this repository: it goes green on a file that says the right words while the
// code underneath says the opposite. So this module deliberately does not
// count words. It counts the two things that would have to CHANGE for the
// declarations to become lies:
//
//   GATE A — the CALLER COUNT of each dormant kind's recorder. A kind is
//     dormant exactly while nothing calls the one method that can put it into
//     a log. Add the first caller and the kind is shipped functionality, and
//     this gate goes red naming the file that did it. Counting the word
//     "dormant" instead would stay green through precisely that edit.
//
//   GATE B — for each permanently-dense command: (i) its dense capture field
//     is still there, and (ii) NO recorder call appears in its file. The
//     declaration says "this command is never migrated"; a migration is
//     exactly an `ed.rec().record*(…)` appearing in one of these three files
//     and a capture field going away. Either one contradicts the comment, and
//     this gate is what catches the contradiction.
//
// ===========================================================================
// WHAT GATE B DOES *NOT* FORBID, because getting this wrong would make the
// gate an obstacle to work that is still owed
// ===========================================================================
// The rulings decline AXIS 2 (the undo migration) ONLY. Axis 0 — the commit
// seam, i.e. these commands opening a `MeshEditBatch` so that `close()` owns
// their stamp — is still owed by all three, and `subpatch_toggle` is named for
// it explicitly. So `beginEditBatch` / `MeshEditBatch` / `commitChange`
// appearing in these files is NOT a contradiction and is NOT counted here.
// Only a `record*` call (or the `.rec()` accessor that reaches one) is.
//
// ===========================================================================
// THE CODE VIEW, AND WHY IT IS NOT A GREP
// ===========================================================================
// Both gates read the tree through `blankNonCode` (imported, not copied, from
// `version_poll_census_test`): comments and string literals are blanked. That
// is load-bearing in both directions here —
//   * this tree carries a dozen PROSE mentions of `recordHideDelta` and
//     `recordSubpatchDelta`, including the declarations this gate exists to
//     protect and the paragraph you are reading. A census that counted
//     sentences would move whenever someone explained the mechanism, and
//     would have to be silenced, which is how a gate stops firing;
//   * the row tables below name the identifiers as STRING LITERALS, so this
//     module contributes nothing to its own scan.
// `unittest` bodies are deliberately LEFT ALONE. "No caller anywhere,
// including tests" is the claim being pinned, and a caller inside a `unittest`
// is still a caller — it is what separates `SubpatchDelta` (one test caller)
// from `HideDelta` (none at all).
//
// ===========================================================================
// SEEN RED — every row, by its own mutation. See the task card (2150) for the
// verbatim messages and the lane each was observed in.
// ===========================================================================
module tests.unit.l0_declined_census_test;

import std.algorithm : sort;
import std.array     : appender;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, strip;

import tests.unit.version_poll_census_test : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Whole-word identifier counting. `recordHideDeltaTwice` must not count as
// `recordHideDelta`, and neither must a longer name ending in one of ours.
// ---------------------------------------------------------------------------
private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

package size_t countIdentIn(string text, string id) {
    if (id.length == 0 || id.length > text.length) return 0;
    size_t n = 0;
    foreach (i; 0 .. text.length - id.length + 1) {
        if (text[i .. i + id.length] == id
            && (i == 0 || !isIdentChar(text[i - 1]))
            && (i + id.length >= text.length || !isIdentChar(text[i + id.length])))
            ++n;
    }
    return n;
}

/// Every occurrence of an identifier of the shape `record<Uppercase>…`, plus
/// the `.rec()` accessor that reaches one. Shape rather than a spelling list
/// ON PURPOSE: a migration that lands a BRAND NEW recorder method — which is
/// exactly what a `PartDelta` publisher would be — must be caught by the gate
/// that says these commands are never migrated, and a list of today's method
/// names would not catch it.
package string[] recorderCallsIn(string code) {
    auto hits = appender!(string[]);
    foreach (li, ln; code.splitLines()) {
        foreach (i; 0 .. ln.length) {
            if (ln.length - i >= 7 && ln[i .. i + 6] == "record"
                && ln[i + 6] >= 'A' && ln[i + 6] <= 'Z'
                && (i == 0 || !isIdentChar(ln[i - 1])))
                hits.put(format("%d: %s", li + 1, ln.strip));
        }
        foreach (i; 0 .. ln.length) {
            if (ln.length - i >= 6 && ln[i .. i + 6] == ".rec()")
                hits.put(format("%d: %s", li + 1, ln.strip));
        }
    }
    return hits.data;
}

// ---------------------------------------------------------------------------
// SCANNER CELLS FIRST. druntime stops a module at its first failing assert, so
// a broken scanner has to say so in its own words rather than surface below as
// a strange verdict about the tree. The probes use MADE-UP identifiers
// (`recordFooDelta`) so that this file contributes nothing to its own scan
// even if a future `blankNonCode` stops blanking token strings.
// ---------------------------------------------------------------------------

/// A real call is seen; the same name in prose is not. BOTH directions,
/// because a scanner that flagged comments would be red for ever and one that
/// flagged nothing would be green for ever, and only the pair tells them apart.
unittest {
    enum string probe = q"PROBE
        // A sentence about recordFooDelta, which is not a call.
        /// And a doc comment naming recordFooDelta again.
        void f() {
            ed.rec().recordFooDelta([0u], [0u], [1u]);
        }
PROBE";
    const code = blankNonCode(probe);
    assert(countIdentIn(code, "recordFooDelta") == 1, format(
        "scanner: the code view must keep the ONE call and blank the two "
      ~ "prose mentions above it — counted %d",
        countIdentIn(code, "recordFooDelta")));
    assert(countIdentIn(probe, "recordFooDelta") == 3, format(
        "scanner: the RAW text must still carry all three, or the code view "
      ~ "above is not blanking anything and this cell is vacuous — counted %d",
        countIdentIn(probe, "recordFooDelta")));
}

/// Whole-word only, and the shape scan finds both spellings of a recorder call.
unittest {
    assert(countIdentIn("recordFooDeltaTwice(x);", "recordFooDelta") == 0,
        "scanner: a longer identifier must not count as the shorter one");
    assert(countIdentIn("a.recordFooDelta(x);", "recordFooDelta") == 1,
        "scanner: a member call must count");

    const h = recorderCallsIn("    ed.rec().recordFooDelta(a, b, c);\n"
                            ~ "    auto n = recorded;\n");
    assert(h.length == 2, format(
        "scanner: the recorder-shape scan must see the `.rec()` accessor AND "
      ~ "the `record<Upper>` name on that line, and must NOT see the "
      ~ "lower-case word `recorded` on the next one — it saw %d: %s",
        h.length, h));
}

// ===========================================================================
// GATE A — the dormant kinds' recorders have the caller sets their
// declarations claim.
// ===========================================================================

private struct DormantRow {
    string zone;        // "source" or "tests"
    string file;        // repo-relative
    string ident;
    size_t count;
    string why;
}

/// THE RECORDED SET, measured on this tree 2026-08-27 through the code view
/// above. Every row is the DECLARATION itself or a call; there is no third
/// possibility, which is what makes a changed number legible.
private immutable DormantRow[] kDormant = [
    DormantRow("source", "source/mesh_edit_delta.d", "recordHideDelta", 1,
        "the declaration, and nothing else in the whole tree. `HideDelta` has "
      ~ "NO caller: no MeshEditTracker has ever put one into a log"),
    DormantRow("source", "source/mesh_edit_delta.d", "recordSubpatchDelta", 1,
        "the declaration. Zero PRODUCTION callers"),
    DormantRow("tests", "tests/test_mesh_edit_delta.d", "recordSubpatchDelta", 1,
        "cell (d)'s sparse round-trip — the ONE caller this kind has ever "
      ~ "had, and the reason `SubpatchDelta` and `HideDelta` are different "
      ~ "diagnoses rather than one status"),
];

private immutable string[] kDormantIdents = ["recordHideDelta", "recordSubpatchDelta"];

private struct Found { string zone; string file; string ident; size_t count; }

private Found[] scanDormant() {
    auto found = appender!(Found[]);
    foreach (zone; ["source", "tests"]) {
        foreach (de; dirEntries(buildPath(repoRoot, zone), "*.d", SpanMode.depth)) {
            const rel  = de.name[repoRoot.length + 1 .. $];
            const code = blankNonCode(readText(de.name));
            foreach (id; kDormantIdents) {
                const n = countIdentIn(code, id);
                if (n) found.put(Found(zone, rel, id, n));
            }
        }
    }
    auto a = found.data;
    a.sort!((x, y) => x.file < y.file || (x.file == y.file && x.ident < y.ident));
    return a;
}

unittest // GATE A
{
    auto found = scanDormant();

    // (1) An identifier in a file nobody recorded. This is the shape a FIRST
    //     CALLER takes, and it is the whole point of the gate.
    foreach (f; found) {
        bool known = false;
        foreach (r; kDormant)
            if (r.file == f.file && r.ident == f.ident) { known = true; break; }
        assert(known, format(
            "L0 dormancy broken: `%s` now occurs in %s, which is not in this "
          ~ "gate's recorded set. If that is a real call then the kind is no "
          ~ "longer DORMANT and its declaration in source/mesh_edit_delta.d "
          ~ "says the opposite — fix the declaration and this table together, "
          ~ "in the same commit, or drop the call.", f.ident, f.file));
    }

    // (2) A recorded pair whose count moved. A SECOND caller in a file that
    //     already had one, or the declaration itself going away.
    foreach (r; kDormant) {
        size_t n = 0;
        bool seen = false;
        foreach (f; found)
            if (f.file == r.file && f.ident == r.ident) { n = f.count; seen = true; }
        assert(seen, format(
            "L0 dormancy census: recorded occurrence of `%s` in %s has "
          ~ "VANISHED (recorded %d, found 0). Either the recorder was deleted "
          ~ "— in which case say so at the kind's declaration — or the scanner "
          ~ "lost its place, and a scanner that reads nothing passes every "
          ~ "other row silently.", r.ident, r.file, r.count));
        assert(n == r.count, format(
            "L0 dormancy census: `%s` occurs %d time(s) in %s, recorded %d "
          ~ "(%s). A count that went UP in the declaring file is a caller the "
          ~ "declaration does not admit to.", r.ident, n, r.file, r.count, r.why));
    }

    // NOTE ON WHAT IS *NOT* ASSERTED HERE, because writing it was the first
    // draft and it was inert. A third row of the shape "the total across both
    // zones is 3" cannot come out differently: rows (1) and (2) together
    // already pin every (file, ident) count exactly, so the total is forced
    // and a `total == 3` assert is satisfied by every tree the two rows above
    // admit. Same for a row restating the 1-vs-2 asymmetry between the two
    // recorders — it is a consequence of the table, not an independent claim.
    // The anti-vacuity that IS load-bearing is the tree-walk floor, and it
    // lives in its own cell above so it can redden on its own message.
}

unittest // GATE A anti-vacuity — the tree walk actually read the tree
{
    // If `dirEntries` matched nothing, row (1) above passes vacuously (there
    // is nothing unrecorded) and row (2) reports a VANISHED declaration —
    // true, but a misleading sentence about a scanner that never looked. This
    // cell fires first, in its own words. The floor is deliberately far below
    // the real counts so it never needs touching as the tree grows.
    size_t nSource = 0, nTests = 0;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        ++nSource;
    foreach (de; dirEntries(buildPath(repoRoot, "tests"), "*.d", SpanMode.depth))
        ++nTests;
    assert(nSource >= 200 && nTests >= 100, format(
        "L0 census tree walk read %d file(s) under source/ and %d under "
      ~ "tests/ — far too few. Every row of GATE A is measured through this "
      ~ "walk, so a walk that reads nothing makes the whole gate quiet in a "
      ~ "way its own messages would misdescribe.", nSource, nTests));
}

// ===========================================================================
// GATE B — the three permanently-dense commands still are what their
// declarations say.
// ===========================================================================

private struct DenseRow {
    string file;
    string captureIdent;    // the dense capture the declaration promises
    size_t captureCount;    // declaration + write + read
    size_t anchorCount;     // occurrences of the declaration marker, RAW text
    string why;
}

private immutable DenseRow[] kDense = [
    DenseRow("source/commands/mesh/hide.d", "HideRevertCommon", 5,
        5,
        "the `mixin template` declaration plus one `mixin` in each of the "
      ~ "FOUR hide commands. The nine planes it captures are the ruling: a "
      ~ "measured capture says one undo restores the selection, its ORDER and "
      ~ "other domains, and a HideDelta-only revert answers `true` while "
      ~ "losing them"),
    DenseRow("source/commands/mesh/subpatch_toggle.d", "origSubpatch", 3,
        1,
        "the field, the `dup` capture and the revert loop. Declined because a "
      ~ "SubpatchDelta would be the same delta spelled twice"),
    DenseRow("source/commands/mesh/set_part.d", "origPart", 3,
        1,
        "the field, the `dup` capture and the revert. Declined because no "
      ~ "MeshOpEntry.Kind carries facePart as its payload and a fifteenth "
      ~ "kind would owe a branch in six exhaustive final switches for good"),
];

private enum string kAnchor = "PERMANENTLY DENSE";

unittest // GATE B — no recorder call, and the capture field is still there
{
    foreach (r; kDense) {
        const raw  = readText(buildPath(repoRoot, r.file));
        const code = blankNonCode(raw);

        // (i) The migration this file's declaration refuses would appear here.
        const calls = recorderCallsIn(code);
        assert(calls.length == 0, format(
            "L0 permanently-dense broken: %s now carries %d recorder-call "
          ~ "signal(s) (the `.rec()` accessor and the `record<Upper>` name on "
          ~ "one line count as two) — %s. Its own declaration says this command is NEVER "
          ~ "migrated to a recorded MeshEditDelta and gives the reason (%s). "
          ~ "A migration here is a decision to reopen, not an edit: change "
          ~ "the declaration first.", r.file, calls.length, calls, r.why));

        // (ii) …and the dense capture it promises instead is still present.
        const n = countIdentIn(code, r.captureIdent);
        assert(n == r.captureCount, format(
            "L0 permanently-dense broken: %s mentions `%s` %d time(s) in "
          ~ "code, recorded %d (%s). The declaration promises a dense "
          ~ "capture; if it is gone, undo is being restored from something "
          ~ "else and the comment is now false.",
            r.file, r.captureIdent, n, r.captureCount, r.why));

        // (iii) The WEAK half, and labelled as such: the declaration itself is
        //       still in the file. A comment check cannot catch a wrong
        //       comment — only a deleted one — which is exactly why (i) and
        //       (ii) above are the rows that carry this gate.
        const a = countIdentIn(raw, kAnchor);
        assert(a == r.anchorCount, format(
            "L0 permanently-dense declaration missing or duplicated: %s "
          ~ "carries the marker `%s` %d time(s), recorded %d. This is the "
          ~ "WEAK row of this gate — it can only see a declaration DELETED, "
          ~ "never one that has drifted away from the code. If you moved the "
          ~ "declaration, move this number with it.",
            r.file, kAnchor, a, r.anchorCount));
    }
}

unittest // GATE B instrument — the recorder scan can actually find something
{
    // POTENCY. The three assertions above are `length == 0` against three
    // files that contain no recorder call. If `recorderCallsIn` returned an
    // empty array for EVERY input they would be green under any migration.
    // This is the cell that says it does not.
    const migrated = readText(buildPath(repoRoot,
        "source/commands/mesh/magnet.d"));
    const calls = recorderCallsIn(blankNonCode(migrated));
    assert(calls.length >= 1, format(
        "instrument: `magnet.d` is a MIGRATED L0 command and records its own "
      ~ "positions through `ed.rec().recordSetPos(…)`; the recorder scan must "
      ~ "find it, or GATE B's three `length == 0` rows are vacuous. Found: %s",
        calls));
}
