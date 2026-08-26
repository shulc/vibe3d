// command_tail_publisher_census_test — a command's LAST mesh publisher must
// be a DELIVERING one (task 1932, closing task 1906 stage 2a review item 1).
//
// WHAT THIS GATE IS FOR. `Mesh` has TWO accumulate-only funnels —
// `noteChange` (`source/mesh.d:2246`) and `noteSelectionChange`
// (`source/mesh.d:2610`, "the SECOND of two funnels", `:2625`) — and neither
// one registers with `deliverPending`/the batch close on its own. A command
// whose only mesh-side calls are accumulate-only therefore delivers NOTHING
// on its own commits and rides only the once-per-frame drain (or, since task
// 1932 stage 3, the `Command.apply` anchor) — measured on the live app:
// `select.invert` moved `deliveryCount` by 0 while moving `flushCount` by 1.
// Three such tails were found witness-less by review (`load.d` revert,
// `import_result.d` apply + revert) and closed at the RULE level rather than
// with three individual behavioural cells — the table below is the rule's
// executable form.
//
// THE RULE, PRECISELY. Scan `source/commands/**` for occurrences of EITHER
// funnel. An occurrence is LEGAL only if the SAME operation reaches a real
// publisher — `publishChange`, `commitChange` or `commitRestored` — AFTER it,
// so the accumulate-only call is a "note now, real publish comes right after"
// shape rather than a genuine dead tail. "After it" takes three shapes, and
// each row below names WHICH, because they are not equally easy to keep true:
//   (a) lower in the SAME function — the strongest, and the only shape under
//       `source/commands/**` today (`hide.d`);
//   (b) in the CALLER, which the note's own function cannot see — a row of
//       this shape is only as durable as the caller, so it names the caller;
//   (c) EARLIER in the same operation (a write-after-publish), which is legal
//       only because the class was already published for this edit. That argument cannot be checked mechanically (it needs to know
// WHICH function, and whether the publisher is really downstream in the same
// operation) — so it is checked BY HAND, once, and recorded in the table
// below with the file:line of the real publisher that makes it legal. What
// IS checked mechanically is that the SET of accumulate-only occurrences
// does not grow past what was checked by hand.
//
// Empty on the FIRST funnel today: zero `noteChange(` under
// `source/commands/**`. Seven legal occurrences on the combined set: three
// `noteSelectionChange(` in `commands/mesh/hide.d` (block A) and four
// `noteChange(MeshEditScope.Maps)` under `source/tools/**` (block C, made
// mandatory by review O1 — the same rule, the same mechanism, a different
// root). An EIGHTH occurrence anywhere, in either root, is a finding.
//
// KEYED ON (file, COUNT), NOT (file, line) — same move
// `revert_entry_census_test.d` makes and for the same reason (R2-4): a line
// number rots on any unrelated insertion above it, and the argument lives in
// this table's TEXT, not in a line number the table would have to keep in
// sync by hand. `hide.d`'s three sites collapse to one row with count 3; the
// four `source/tools/**` sites are documented as four individual rows (one
// per site, matching the card's own table by hand) and aggregated by file
// when compared, because `morph_route.d` carries two of the four.
//
// THREE BLOCKS, ONE COMMIT (both roots share the mechanism, so the table and
// the exception rows are reviewed together):
//   A — `source/commands/**`, both funnels, against the recorded exceptions.
//   B — POSITIVE CONTROL: `publishChange(` is found in exactly the twelve
//       named files under `source/commands/**`. Without this, block A is
//       vacuous on a scanner that lost its place: a desynced blanker finds
//       NOTHING for either funnel and reports a clean, wrong, pass.
//   C — `source/tools/**`, same rule, own root, own floor, own exceptions.
//
// THE COMMENT STRIPPER IS MANDATORY, NOT HYGIENE — two live witnesses, not a
// hypothetical: `source/commands/file/load.d`'s own doc comment contains the
// prose "`publishChange`, not `noteChange`" and
// `source/commands/mesh/loop_slice.d`'s contains
// "`noteSelectionChange(...); deliverPending();`" verbatim, INSIDE a
// backtick span, with the trailing paren a naive line-grep would match. A
// scanner that did not blank comments would either double-count a legal
// site or, worse, invent a finding in a file that has none. Probed directly
// below with the same sentences.
module tests.unit.command_tail_publisher_census_test;

import std.algorithm : canFind, startsWith;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Duplicated from `version_poll_census_test.d` / `revert_entry_census_test.d`
// (accepted pattern between census files — see either file's own header).
// ---------------------------------------------------------------------------
package string blankNonCode(string src, bool keepComments = false) {
    auto outBuf = new char[src.length];
    foreach (i, c; src) outBuf[i] = (c == '\n') ? '\n' : ' ';
    size_t codeStart = 0;
    void keep(size_t a, size_t b) {
        foreach (k; a .. b) if (src[k] != '\n') outBuf[k] = src[k];
    }
    void drop(size_t a, size_t b) { keep(codeStart, a); codeStart = b; }

    size_t i = 0;
    while (i < src.length) {
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            const size_t s = i;
            while (i < src.length && src[i] != '\n') ++i;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            const size_t s = i;
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') {
            const size_t s = i;
            int depth = 0;
            while (i < src.length) {
                if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') { ++depth; i += 2; continue; }
                if (i + 1 < src.length && src[i] == '+' && src[i + 1] == '/') { --depth; i += 2; if (depth == 0) break; continue; }
                ++i;
            }
            if (!keepComments) drop(s, i);
            continue;
        }
        if (src[i] == '"') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '`') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '`') ++i;
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '\'') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '\'') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        ++i;
    }
    keep(codeStart, src.length);
    return cast(string)outBuf;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private string blankUnittestBodies(string code) {
    auto buf = code.dup;
    void blankBlock(size_t from) {
        size_t j = from;
        while (j < buf.length && buf[j] != '{') {
            if (buf[j] == ';') return;
            ++j;
        }
        if (j >= buf.length) return;
        int depth = 0;
        for (; j < buf.length; ++j) {
            const char c = buf[j];
            if (c == '{') ++depth;
            else if (c == '}') { --depth; if (depth == 0) { buf[j] = ' '; return; } }
            if (c != '\n') buf[j] = ' ';
        }
    }
    bool parenthesised(size_t i) {
        size_t k = i;
        while (k > 0 && (buf[k - 1] == ' ' || buf[k - 1] == '\t'
                      || buf[k - 1] == '\n' || buf[k - 1] == '\r')) --k;
        return k > 0 && buf[k - 1] == '(';
    }
    enum kw = "unittest";
    size_t i = 0;
    while (i + kw.length <= buf.length) {
        if (buf[i .. i + kw.length] == kw
            && (i == 0 || !isIdentChar(buf[i - 1]))
            && (i + kw.length >= buf.length || !isIdentChar(buf[i + kw.length]))
            && !parenthesised(i))
        {
            blankBlock(i + kw.length);
            i += kw.length;
            continue;
        }
        ++i;
    }
    return cast(string)buf;
}

private string codeView(string src) { return blankUnittestBodies(blankNonCode(src)); }

// ---------------------------------------------------------------------------
// Scanning.
// ---------------------------------------------------------------------------

private struct FunnelSite { string file; string funnel; size_t line; }

/// Both accumulate-only funnels, over one file's already-code-only text.
private FunnelSite[] scanFunnels(string label, string code) {
    auto sites = appender!(FunnelSite[]);
    auto lines = code.splitLinesKeep();
    foreach (li, ln; lines) {
        if (ln.canFind("noteChange("))
            sites.put(FunnelSite(label, "noteChange", li + 1));
        if (ln.canFind("noteSelectionChange("))
            sites.put(FunnelSite(label, "noteSelectionChange", li + 1));
    }
    return sites.data;
}

/// `std.string.splitLines`, spelled locally so the file has one fewer import
/// to keep in sync with the other census files' duplicated helper set.
private string[] splitLinesKeep(string s) {
    import std.string : splitLines;
    return s.splitLines();
}

private bool hasPublisher(string code) {
    return code.canFind("publishChange(");
}

private struct TreeScan {
    FunnelSite[] sites;
    bool[string]  publisherFiles;  // files containing publishChange(
    size_t        filesScanned;
}

private TreeScan scanRoot(string relRoot) {
    TreeScan r;
    foreach (de; dirEntries(buildPath(repoRoot, relRoot), "*.d", SpanMode.depth)) {
        ++r.filesScanned;
        const string label = de.name[repoRoot.length + 1 .. $];
        const string code  = codeView(readText(de.name));
        r.sites.put_(scanFunnels(label, code));
        if (hasPublisher(code)) r.publisherFiles[label] = true;
    }
    return r;
}

// appender-free accumulation helper (TreeScan.sites is a plain dynamic
// array; `put_` just appends, named to avoid colliding with Appender.put).
private void put_(ref FunnelSite[] arr, FunnelSite[] more) { arr ~= more; }

// ---------------------------------------------------------------------------
// SCANNER CELLS, FIRST.
// ---------------------------------------------------------------------------

/// The comment stripper is load-bearing, not hygiene — reproduced verbatim
/// from `source/commands/mesh/loop_slice.d`'s own prose, which contains the
/// funnel call INSIDE a comment, backticked, with the trailing paren a naive
/// line-grep would match.
unittest {
    enum string probe = q"PROBE
void f() {
    // every selection writer calls
    // `noteSelectionChange(...); deliverPending();` unconditionally. So
    // the kernel's tail delivers from inside this batch.
}
PROBE";
    const code = codeView(probe);
    assert(scanFunnels("probe.d", code).length == 0,
        "a funnel call quoted INSIDE A COMMENT must not be a site — this is "
      ~ "loop_slice.d's own sentence, verbatim");
}

/// Same for `load.d`'s prose ("`publishChange`, not `noteChange`") — here the
/// bare word has no trailing paren, so even a naive scanner keyed on
/// `noteChange(` would not match it; the cell exists so the probe corpus
/// documents BOTH real witnesses, not just the one that would fool a weaker
/// scanner.
unittest {
    enum string probe = q"PROBE
void f() {
    // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`, and this site
    // is the one that was MEASURED blind.
}
PROBE";
    const code = codeView(probe);
    assert(scanFunnels("probe.d", code).length == 0);
}

/// A live site is still found when comments surround it.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    // a real note, then a real publisher right after
    mesh.noteSelectionChange(SelDomain.Vertex);
    mesh.commitChange(MeshEditScope.Marks);
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 1 && s[0].funnel == "noteSelectionChange",
        format("%s", s));
}

/// The positive control's own discriminator: `publishChange(` is found, and
/// a nearby `noteChange` (a DIFFERENT identifier, `publishChange` is not a
/// substring match of it) is not confused with it.
unittest {
    enum string withPublisher = q"PROBE
void applyImpl() {
    mesh.publishChange(MeshEditScope.Position);
}
PROBE";
    assert(hasPublisher(codeView(withPublisher)));

    enum string withoutPublisher = q"PROBE
void applyImpl() {
    mesh.noteChange(MeshEditScope.Maps);
}
PROBE";
    assert(!hasPublisher(codeView(withoutPublisher)));
}

// ---------------------------------------------------------------------------
// THE RECORDED TABLES.
// ---------------------------------------------------------------------------

/// `count` is how many funnel occurrences THIS row accounts for — 3 for
/// `hide.d`'s single row (all three sites share one argument), 1 for each of
/// block C's four individual-site rows.
private struct ExceptionRow { string file; size_t count; string why; }

/// Block A's exceptions, `source/commands/**`. One row: `hide.d` carries
/// three `noteSelectionChange(` calls, all legal because the SAME function
/// (`revertImpl`'s restore path) calls the real publisher
/// `mesh.commitChange(MeshEditScope.Marks | MeshEditScope.Visibility)` right
/// after them, at `hide.d:277`.
private static immutable ExceptionRow[] kCommandsExceptions = [
    ExceptionRow("source/commands/mesh/hide.d", 3,
        "three noteSelectionChange( calls (Vertex/Edge/Face) followed, in "
      ~ "the same function, by the real publisher "
      ~ "mesh.commitChange(MeshEditScope.Marks | MeshEditScope.Visibility) "
      ~ "at hide.d:277"),
];

/// The twelve files under `source/commands/**` known to call `publishChange(`
/// — block B's positive control. NAMES only; block B does not count
/// occurrences per file.
private static immutable string[] kPublishChangeFiles = [
    "source/commands/ai3d/import_result.d",
    "source/commands/file/load.d",
    "source/commands/mesh/detriangulate.d",
    "source/commands/mesh/merge.d",
    "source/commands/mesh/move_vertex.d",
    "source/commands/mesh/quadruple.d",
    "source/commands/mesh/remesh.d",
    "source/commands/mesh/subdivide.d",
    "source/commands/mesh/subdivide_faceted.d",
    "source/commands/mesh/triple.d",
    "source/commands/scene/load_mesh.d",
    "source/commands/scene/reset.d",
];

/// Block C's exceptions, `source/tools/**` — one row per site (four total,
/// matching the card's table by hand), all `noteChange(MeshEditScope.Maps)`.
/// `morph_route.d` carries two; the argument is the SAME shape for all four
/// — a real publisher lower in the same operation — and `xfrm_apply.d`
/// writes that argument out loud at `:299-308`.
private static immutable ExceptionRow[] kToolsExceptions = [
    ExceptionRow("source/tools/transform/xform_kernels.d", 1,
        "noteChange(Maps) at :716 — SHAPE (b): the publisher is in the "
      ~ "CALLER, xfrm_apply.d's routed-constraint apply (:971), not in this "
      ~ "function; this row is only as durable as that caller"),
    ExceptionRow("source/tools/transform/morph_route.d", 1,
        "noteChange(Maps) at :214 — SHAPE (b), same caller (site 1 of 2)"),
    ExceptionRow("source/tools/transform/morph_route.d", 1,
        "noteChange(Maps) at :367 — SHAPE (b), same caller (site 2 of 2)"),
    ExceptionRow("source/tools/transform/xfrm_apply.d", 1,
        "noteChange(Maps) at :289 — SHAPE (c), write-after-publish: the "
      ~ "class was already published by applyFold EARLIER in the same apply; "
      ~ "xfrm_apply.d:299-308 writes that argument out loud"),
];

/// Group a per-site exception table into (file -> expected count).
private size_t[string] byFile(const ExceptionRow[] rows) {
    size_t[string] m;
    foreach (ref r; rows) m[r.file] = m.get(r.file, 0) + r.count;
    return m;
}

// ---------------------------------------------------------------------------
// Shared comparison, reused by blocks A and C so the "unaccounted" message is
// worded once.
// ---------------------------------------------------------------------------
private void assertNoUnaccountedTails(string blockLabel, string rootLabel,
                                       const FunnelSite[] sites,
                                       const ExceptionRow[] recorded)
{
    const size_t[string] expected = byFile(recorded);
    size_t[string] found;
    foreach (ref s; sites) found[s.file] = found.get(s.file, 0) + 1;

    auto bad = appender!string;
    foreach (file, n; found) {
        const size_t exp = expected.get(file, 0);
        if (n == exp) continue;
        bad.put(format("\n    %s — recorded %d, scanner found %d", file, exp, n));
        foreach (ref s; sites)
            if (s.file == file)
                bad.put(format("\n        found  %s:%d  [%s]", s.file, s.line, s.funnel));
    }
    // Under-counts (a row recorded for a file the scanner no longer sees
    // anything in) are ALSO a mismatch — the table must track the tree in
    // both directions, same as the revert census's set match.
    foreach (file, n; expected) {
        if (file in found) continue;
        bad.put(format("\n    %s — recorded %d, scanner found 0", file, n));
    }

    assert(bad.data.length == 0, format(
        "task 1932 (%s, %s): the accumulate-only funnel tail SET no longer "
      ~ "matches the recorded exception table.%s\n\n"
      ~ "  A command's tail must be a `publishChange` / `commitChange` / "
      ~ "`commitRestored` — a DELIVERING publisher. An accumulate-only "
      ~ "funnel call (`noteChange` / `noteSelectionChange`) is legal ONLY if "
      ~ "a real publisher runs lower in the SAME function for the SAME "
      ~ "operation — add the file to this table with that argument and bump "
      ~ "its count, or (if there truly is no downstream publisher) give the "
      ~ "command a real one instead of leaving it silent.",
        blockLabel, rootLabel, bad.data));
}

// ---------------------------------------------------------------------------
// THE GATE — one commit, three blocks.
// ---------------------------------------------------------------------------
unittest {
    // Block A + (part of) B: source/commands/**.
    const cmdScan = scanRoot("source/commands");

    assertNoUnaccountedTails("block A", "source/commands",
        cmdScan.sites, kCommandsExceptions);

    // Block B — positive control. Without it, block A is vacuous on a
    // scanner that lost its place: a desynced blanker finds nothing for
    // EITHER funnel and ALSO nothing for `publishChange(`, so a bad walk and
    // a healthy tree with the funnels genuinely retired look identical to
    // block A alone.
    {
        auto missing = appender!string;
        foreach (f; kPublishChangeFiles)
            if (f !in cmdScan.publisherFiles)
                missing.put("\n    " ~ f ~ " — recorded, but no publishChange( found");
        auto extra = appender!string;
        foreach (f, _; cmdScan.publisherFiles) {
            bool recorded = false;
            foreach (k; kPublishChangeFiles) if (k == f) { recorded = true; break; }
            if (!recorded) extra.put("\n    " ~ f ~ " — NOT recorded, but publishChange( found");
        }
        assert(missing.data.length == 0 && extra.data.length == 0, format(
            "task 1932 block B (positive control): the set of "
          ~ "source/commands/** files calling publishChange( no longer "
          ~ "matches the recorded twelve.%s%s",
            missing.data, extra.data));
    }

    assert(cmdScan.filesScanned >= 150, format(
        "the tail-publisher census only walked %d file(s) under "
      ~ "source/commands/ — it has almost certainly lost its place (164 "
      ~ "stand there as of 2026-08-26). Fix the walk, do not lower this "
      ~ "floor.", cmdScan.filesScanned));

    // Block C — source/tools/**, same rule, own root (mandatory per review
    // O1: the mechanism the first two blocks build is needed here anyway).
    const toolsScan = scanRoot("source/tools");

    assertNoUnaccountedTails("block C", "source/tools",
        toolsScan.sites, kToolsExceptions);

    assert(toolsScan.filesScanned >= 60, format(
        "the tail-publisher census only walked %d file(s) under "
      ~ "source/tools/ — it has almost certainly lost its place (65 stand "
      ~ "there as of 2026-08-26). Fix the walk, do not lower this floor.",
        toolsScan.filesScanned));

    // Every recorded file must still exist.
    foreach (ref r; kCommandsExceptions)
        assert(buildPath(repoRoot, r.file).exists, "recorded file missing: " ~ r.file);
    foreach (ref r; kToolsExceptions)
        assert(buildPath(repoRoot, r.file).exists, "recorded file missing: " ~ r.file);
    foreach (f; kPublishChangeFiles)
        assert(buildPath(repoRoot, f).exists, "recorded file missing: " ~ f);
}
