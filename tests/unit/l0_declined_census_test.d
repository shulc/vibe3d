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

import tests.unit.census_symbols : blankNonCode, enclosingSymbols, symbolAt,
    LedgerRow, LedgerHit, reconcile, symbolTokenHits;

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

/// THE RECORDED SET, measured on this tree 2026-08-27 through the code view
/// above. Every row is the DECLARATION itself or a call; there is no third
/// possibility, which is what makes a changed number legible.
private immutable LedgerRow[] kDormant = [
    LedgerRow("MeshEditTracker|recordHideDelta", 1,
        "the declaration, and nothing else in the whole tree. `HideDelta` has "
      ~ "NO caller: no MeshEditTracker has ever put one into a log"),
    LedgerRow("MeshEditTracker|recordSubpatchDelta", 1,
        "the declaration. Zero PRODUCTION callers"),
    LedgerRow("(module scope)|recordSubpatchDelta", 1,
        "cell (d)'s sparse round-trip — the ONE caller this kind has ever "
      ~ "had, and the reason `SubpatchDelta` and `HideDelta` are different "
      ~ "diagnoses rather than one status"),
];

private immutable string[] kDormantIdents = ["recordHideDelta", "recordSubpatchDelta"];

private struct Found { string zone; string file; string symbol; string ident; size_t line; }

private Found[] scanDormant() {
    auto found = appender!(Found[]);
    foreach (zone; ["source", "tests"]) {
        foreach (de; dirEntries(buildPath(repoRoot, zone), "*.d", SpanMode.depth)) {
            const rel  = de.name[repoRoot.length + 1 .. $];
            const code = blankNonCode(readText(de.name));
            const symbols = enclosingSymbols(code);
            foreach (id; kDormantIdents) {
                foreach (li, line; code.splitLines)
                    foreach (_; 0 .. countIdentIn(line, id))
                        found.put(Found(zone, rel, symbolAt(symbols, li), id, li + 1));
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
    LedgerHit[] hits;
    foreach (ref f; found)
        hits ~= LedgerHit(f.symbol ~ "|" ~ f.ident, f.file, f.line, f.ident);
    const bad = reconcile(kDormant, hits);
    assert(bad.length == 0, format(
        "L0 dormancy symbol ledger changed:%s\nA new caller means the kind is "
      ~ "no longer DORMANT; change the declaration and ledger together.", bad));
    assert(hits.length == 3,
        format("L0 dormant population changed: expected 3, found %d", hits.length));

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

private immutable LedgerRow[] kDenseCaptures = [
    LedgerRow("(module scope)|HideRevertCommon", 1, "mixin declaration"),
    LedgerRow("MeshHide|HideRevertCommon", 1, "mesh.hide mixin"),
    LedgerRow("MeshHideUnselected|HideRevertCommon", 1, "mesh.hideUnselected mixin"),
    LedgerRow("MeshHideInvert|HideRevertCommon", 1, "mesh.hideInvert mixin"),
    LedgerRow("MeshUnhideAll|HideRevertCommon", 1, "mesh.unhideAll mixin"),
    LedgerRow("SubpatchToggle|origSubpatch", 1, "dense field"),
    LedgerRow("SubpatchToggle.evaluate|origSubpatch", 1, "dense capture"),
    LedgerRow("SubpatchToggle.revertImpl|origSubpatch", 1, "dense restore"),
    LedgerRow("MeshSetPart|origPart", 1, "dense field"),
    LedgerRow("MeshSetPart.evaluate|origPart", 1, "dense capture"),
    LedgerRow("MeshSetPart.revertImpl|origPart", 1, "dense restore"),
];

private immutable string[] kDenseOwners = [
    "HideRevertCommon", "MeshHide", "MeshHideUnselected", "MeshHideInvert",
    "MeshUnhideAll", "SubpatchToggle", "MeshSetPart",
];

private enum string kAnchor = "PERMANENTLY DENSE";

private bool belongsToDenseOwner(string symbol) {
    import std.string : startsWith;
    foreach (owner; kDenseOwners)
        if (symbol == owner || symbol.startsWith(owner ~ ".")) return true;
    return false;
}

unittest // GATE B — dense declarations and the absence of recorder calls
{
    LedgerHit[] captures;
    LedgerHit[] recorderHits;
    size_t anchorCount;
    size_t filesRead;

    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const rel = de.name[repoRoot.length + 1 .. $];
        const raw = readText(de.name);
        const code = blankNonCode(raw);
        const symbols = enclosingSymbols(code);
        LedgerHit[] inFile;
        foreach (ident; ["HideRevertCommon", "origSubpatch", "origPart"])
            foreach (li, line; code.splitLines)
                foreach (_; 0 .. countIdentIn(line, ident))
                    inFile ~= LedgerHit(symbolAt(symbols, li) ~ "|" ~ ident,
                                        rel, li + 1, line.strip);
        if (inFile.length) {
            captures ~= inFile;
            anchorCount += countIdentIn(raw, kAnchor);
        }

        foreach (li, line; code.splitLines) {
            const symbol = symbolAt(symbols, li);
            if (!belongsToDenseOwner(symbol)) continue;
            foreach (hit; recorderCallsIn(line))
                recorderHits ~= LedgerHit(symbol, rel, li + 1, hit);
        }
        ++filesRead;
    }

    const problems = reconcile(kDenseCaptures, captures);
    assert(problems.length == 0,
        "L0 permanently-dense capture symbol ledger changed." ~ problems);
    assert(captures.length == 11 && filesRead >= 200, format(
        "L0 dense census found %d capture sites over %d source files",
        captures.length, filesRead));
    assert(recorderHits.length == 0, format(
        "L0 permanently-dense declarations now contain recorder calls: %s",
        recorderHits));
    assert(anchorCount == 7, format(
        "L0 dense declarations carry %d `%s` markers, expected 7",
        anchorCount, kAnchor));
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
