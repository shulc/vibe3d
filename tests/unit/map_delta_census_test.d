// ===========================================================================
// Task 1903 Stage L1-P1 — the SOURCE-TEXT censuses for `Kind.MapValueDelta`.
//
// LANE: `dub test --config=tests` ONLY (`./run_test.d` links the prebuilt
// archive and never runs a `tests/unit/**` block).
//
// TWO THINGS A RUNTIME CELL CANNOT SAY, which is why these are text scans:
//
//   * W-K3 — that the exclusion is spelled ONCE. `MeshEditTracker.append` is
//     the only `log_ ~=` in its module, so every one of the sixteen recorders
//     passes the adjacency latch. A seventeenth recorder that appended
//     directly would bypass BOTH latches, produce a perfectly valid delta, and
//     nothing at runtime would notice.
//   * W-K12 — WHO calls the post-hoc recorders, and with WHAT argument. The
//     count row alone stays green when the ARGUMENT changes (L0-b's M-b4 /
//     M-b6 lesson), so the argument TEXT is a separate row.
//
// THE HONEST STATE OF W-K12 AT THIS COMMIT, and it is a DEBT, not a green:
// the kind has ZERO production recorder callers, so the caller sets below are
// EMPTY and no mutation of a call site can redden them. The rows that ARE
// live today are the two that do not depend on a caller existing: the
// declaration counts (a first caller cannot be added while this file still
// says there is none — the `l0_declined_census_test.d` shape) and the
// EXTRACTOR's own probe cells, which run the scanner over synthetic source so
// the machinery is proven before L1-a and L1-e have anything for it to read.
// ===========================================================================
module tests.unit.map_delta_census_test;

import std.file   : readText, exists, dirEntries, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName, baseName;

import tests.unit.version_poll_census_test : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The comment/string/unittest-body stripper is the SHARED one
// (`version_poll_census_test`), not a fourth copy: a doc comment that NAMES a
// symbol moves the count, and a unittest body that CALLS one is not a caller
// in the sense this census means. Reusing it also means a fix to its known
// desync cases lands here for free.
private string codeView(string src) {
    return blankUnittestBodies(blankNonCode(src));
}

private size_t countOccurrences(string hay, string needle) {
    size_t n = 0, i = 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

/// Every `needle(` call in `code`, as its balanced-paren argument text split on
/// TOP-LEVEL commas. This is the half of W-K12 that sees a substituted
/// before-image: a caller that swaps `pre` for `live.data` keeps the count and
/// changes this.
private string[][] callArgs(string code, string needle) {
    import std.string : strip;
    string[][] outp;
    size_t i = 0;
    const string pat = needle ~ "(";
    while (i + pat.length <= code.length) {
        if (code[i .. i + pat.length] != pat) { ++i; continue; }
        // Skip a DECLARATION: a call is preceded by `.` or by whitespace after
        // an expression, a declaration by the return type. Cheap and adequate
        // here — the declaration is the one occurrence whose preceding
        // non-space character is not `.`.
        size_t j = i + pat.length;
        int depth = 1;
        size_t argStart = j;
        string[] args;
        while (j < code.length && depth > 0) {
            const char c = code[j];
            if (c == '(' || c == '[') ++depth;
            else if (c == ')' || c == ']') {
                --depth;
                if (depth == 0) { args ~= code[argStart .. j].strip; break; }
            } else if (c == ',' && depth == 1) {
                args ~= code[argStart .. j].strip;
                argStart = j + 1;
            }
            ++j;
        }
        outp ~= args;
        i = j + 1;
    }
    return outp;
}

private string sourceFile(string rel) {
    const p = buildPath(repoRoot, rel);
    assert(exists(p), "census: " ~ p ~ " is missing — the scan would report 0");
    return codeView(readText(p));
}

// ===========================================================================
// W-K3 — the funnel is a FUNNEL: one `log_ ~=` in the whole module.
// ===========================================================================
unittest
{
    const string code = sourceFile("source/mesh_edit_delta.d");

    // NON-VACUITY, FIRST. A stripper that lost its place eats the rest of the
    // file, and every count below then reads 0 and passes.
    assert(code.length >= 60_000, format(
        "census: the code view of mesh_edit_delta.d is only %d bytes — the "
      ~ "stripper ate the file (a wysiwyg string or a character literal will "
      ~ "do it) and every count below is meaningless", code.length));
    const size_t routed = countOccurrences(code, "append(e);");
    assert(routed >= 16, format(
        "census: only %d recorder sites route through `append(e);`, expected "
      ~ "at least 16. Either the scan is broken or recorders have gone around "
      ~ "the funnel.", routed));

    const size_t raw = countOccurrences(code, "log_ ~=");
    assert(raw == 1, format(
        "census: `log_ ~=` occurs %d times in source/mesh_edit_delta.d, "
      ~ "expected exactly 1 (inside MeshEditTracker.append). A recorder that "
      ~ "appends DIRECTLY bypasses both adjacency latches, produces a "
      ~ "perfectly valid-looking delta, and nothing at runtime would notice. "
      ~ "A rule spelled sixteen times is a rule that drifts, which is why it "
      ~ "is spelled once.", raw));

    // And that once is inside `append`, not somewhere else that happens to be
    // alone. The funnel's body is the only place the two latches are read.
    const size_t inAppend = countOccurrences(code,
        "sawIndexMove_ |= moves;\n        log_ ~= e;");
    assert(inAppend == 1, format(
        "census: the single `log_ ~=` is not the one inside `append` (found "
      ~ "%d matches for the latch-then-append sequence). Moving it out of the "
      ~ "funnel keeps the count at 1 and removes the rule.", inAppend));
}

// ===========================================================================
// The `final switch` inventory of `mesh_edit_delta.d`.
//
// The owner PRICED this kind at a branch in six switches over `Kind` plus the
// one in `tests/test_mesh_edit_delta.d`. The extracted `kindHoldsIndexSpace`
// REPLACED `indexSpaceStable`'s switch rather than adding one, and
// `patchMapValues` / `patchMapValuesWrite` / `mapEntryChangesValues` switch
// over the SUB-enums (`MapOp`, `MapAddressing`) — the `SelDomain` precedent,
// which does not count against the six.
//
// This row is a tripwire, not a style rule: a seventh switch over `Kind` is a
// seventh place a new kind must be argued, and it should be a deliberate,
// visible decision rather than a diff nobody counted.
// ===========================================================================
unittest
{
    const string code = sourceFile("source/mesh_edit_delta.d");
    const size_t n = countOccurrences(code, "final switch");
    enum size_t kExpected = 10;   // 6 over Kind, 1 over SelDomain, 3 over the
                                  // MapValueDelta sub-enums
    assert(n == kExpected, format(
        "census: mesh_edit_delta.d has %d `final switch`es, the inventory says "
      ~ "%d. Over `Kind` (6): kindHoldsIndexSpace, owesTopologyBump, "
      ~ "displayTermFor, owesDisplayRefresh, applyForward, applyReverse. Over "
      ~ "a SUB-enum (4): patchSelection (SelDomain), patchMapValues (MapOp), "
      ~ "mapEntryChangesValues (MapOp), patchMapValuesWrite (MapAddressing). "
      ~ "If you added one over `Kind`, say so here and in the plan — that is "
      ~ "the cost the owner priced.", n, kExpected));
}

// ===========================================================================
// W-K12 — the closed caller sets of the map recorders.
//
// EMPTY AT THIS COMMIT, DELIBERATELY. Every count below is "one occurrence,
// and it is the declaration". That is a live check in exactly one direction:
// a FIRST caller cannot be added while this file still says there is none.
// The argument-TEXT half is owed by L1-a (`recordMapCreate*`) and L1-e
// (`recordMapValueDiff`); its machinery is proven by the probe cell below.
// ===========================================================================
/// One symbol's EXPECTED occurrence map over `source/**`, in a code view with
/// comments, strings and unittest bodies blanked. `file` is a basename; a
/// symbol absent from every other file is the closed half of the claim.
private struct SymRow { string sym; string file; size_t n; string why; }

unittest
{
    // THE SET IS CLOSED AND ENUMERATED. Six symbols, five call sites, and four
    // of the five are declarations. `recordMapValuesOwned`'s two calls in
    // `mesh.d` are `recordMapValueDiff`'s own two arms — the sparse one and
    // the dense one — and they are the reason that method reports WHICH
    // spelling won.
    static immutable SymRow[] rows = [
        SymRow("recordMapValueDiff(",         "mesh.d",             1, "its declaration on MeshEditBatch"),
        SymRow("recordMapValuesOwned(",       "mesh_edit_delta.d",  1, "its declaration on MeshEditTracker"),
        SymRow("recordMapValuesOwned(",       "mesh.d",             2, "recordMapValueDiff's WholeArray and Listed arms"),
        SymRow("recordMapCreate(",            "mesh_edit_delta.d",  1, "its declaration"),
        SymRow("recordMapCreateFilledOwned(", "mesh_edit_delta.d",  1, "its declaration"),
        SymRow("recordMapRemoveOwned(",       "mesh_edit_delta.d",  1, "its declaration"),
        SymRow("recordMapRename(",            "mesh_edit_delta.d",  1, "its declaration"),
    ];

    // The symbols, DEDUPED — `recordMapValuesOwned` is listed under two
    // files and counting it once per ROW would double every one of its counts.
    bool[string] symSet;
    foreach (ref r; rows) symSet[r.sym] = true;
    auto syms = symSet.keys;

    size_t scannedFiles = 0, scannedBytes = 0;
    size_t[string] got;      // "sym@file" -> count
    string[] extras;

    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const string code = codeView(readText(de.name));
        ++scannedFiles;
        scannedBytes += code.length;
        const string bn = baseName(de.name);
        foreach (sym; syms) {
            const size_t n = countOccurrences(code, sym);
            if (n == 0) continue;
            got[sym ~ "@" ~ bn] = got.get(sym ~ "@" ~ bn, 0) + n;
            bool named = false;
            foreach (ref q; rows) if (q.sym == sym && q.file == bn) named = true;
            if (!named) extras ~= format("%s in %s x%d", sym, bn, n);
        }
    }

    // The floor: a broken walk reports zero everywhere and passes.
    assert(scannedFiles >= 100 && scannedBytes >= 1_000_000, format(
        "census: only %d files / %d bytes of source/** were scanned — the walk "
      ~ "is broken and every count below is a zero it did not earn",
        scannedFiles, scannedBytes));

    foreach (ref r; rows) {
        const string key = r.sym ~ "@" ~ r.file;
        const size_t n = got.get(key, 0);
        assert(n == r.n, format(
            "census: `%s` occurs %d times in source/%s, the table says %d (%s).",
            r.sym, n, r.file, r.n, r.why));
    }

    assert(extras.length == 0, format(
        "census: a map recorder is called from a file the table does not name: "
      ~ "%s.\n"
      ~ "AT THIS COMMIT Kind.MapValueDelta has ZERO production recorder "
      ~ "callers; the first is Stage L1-a (commands/mesh/morph.d), and L1-e "
      ~ "fills `recordMapValueDiff`'s set. If you are that commit: add your "
      ~ "call sites to the table TOGETHER WITH the exact TEXT of each one's "
      ~ "before-image / content argument, because a count row stays green when "
      ~ "the ARGUMENT changes (L0-b, M-b4) and the two create spellings differ "
      ~ "by exactly that argument.", extras));
}

unittest // the extractor's OWN probe — the half that is live before L1-a
{
    // Without this cell the argument-text machinery above ships untested and
    // its first real use is the commit that also writes its expectations.
    enum string probe = q{
        void f(ref MeshEditBatch ed, ref Mesh m) {
            auto pre = m.meshMap("uv").data.dup;   // "uv" is a string, stripped
            uvRelax(m);
            ed.recordMapValueDiff("uv", pre, null);
            ed.recordMapValueDiff("uv2", m.meshMap("uv2").data, presPre);
        }
    };
    const string code = codeView(probe);
    auto calls = callArgs(code, "recordMapValueDiff");
    assert(calls.length == 2, format(
        "the call extractor found %d calls in the probe, expected 2 — it "
      ~ "cannot report on L1-e's call sites if it cannot read this one",
        calls.length));
    assert(calls[0].length == 3 && calls[1].length == 3, format(
        "the extractor split the argument lists wrong: %s", calls));
    assert(calls[0][1] == "pre", format(
        "the BEFORE-IMAGE argument of call 0 read as `%s`, expected `pre`. "
      ~ "This is the term that sees a caller substituting the LIVE array for "
      ~ "its pre-op image — the substitution a count row cannot see.",
        calls[0][1]));
    import std.algorithm.searching : canFind;
    assert(calls[1][1].canFind("m.meshMap(") && calls[1][1].canFind(").data"), format(
        "the extractor did not keep a nested call intact: `%s`", calls[1][1]));

    // POTENCY: change the argument and the row must move.
    enum string probe2 = q{
        void f() { ed.recordMapValueDiff("uv", live.data, null); }
    };
    auto c2 = callArgs(codeView(probe2), "recordMapValueDiff");
    assert(c2.length == 1 && c2[0][1] == "live.data", format(
        "the extractor reported `%s` for a substituted before-image — if it "
      ~ "cannot tell `pre` from `live.data` the whole row is a decoy",
        c2.length ? c2[0][1] : "<none>"));
}
