// revert_entry_census_test — every production `.revert()` call site is one of
// the NINE recorded ones, each of which runs inside a global delivery batch
// (task 1932, closing task 1906 stage 0b review S3's open item 3).
//
// WHAT THIS GATE IS FOR. `source/command.d`'s doc comment used to claim the
// two undo paths ("`/api/undo` / `navHistory` call `history.undo()` raw" vs.
// "the registered `history.undo` command wraps it") differ in delivery
// granularity. Task 1932 re-measured that claim by grep and found it FALSE:
// `CommandHistory.undo()` (`command_history.d:1091`), `.redo()` (`:1208`) and
// `.fire()` (`:1507`) each hold `beginDeliveryBatchGlobal()` around every
// `revert()` they drive, so ALL production paths deliver once per step. The
// comment was rewritten to say that instead. This census is the executable
// half of the correction: it fails the moment a TENTH production `.revert()`
// call site is added anywhere in `source/**`, because a new site is exactly
// how the false claim got written the first time — someone added a revert
// path and never checked whether it landed inside one of the three batches.
//
// A new call site is not necessarily wrong. It is UNACCOUNTED — the census
// forces a human decision: does it already live inside
// `beginDeliveryBatchGlobal`/`endDeliveryBatchGlobal`, or does it need a row
// added to the table (and, if not, a batch of its own)?
//
// WHAT COUNTS AS A SITE. A `.revert()` method call in CODE — comments,
// string/backtick/char literals and `unittest` bodies are blanked in place
// first (same three views, same reasons, as
// `tests/unit/version_poll_census_test.d`; duplicated here rather than
// imported, which is the accepted pattern between census files — see that
// file's own header). `version (unittest)` blocks are left alone: they are
// production seams, not test bodies.
//
// THE KEY IS (file, enclosing function name), NOT (file, line). A `.revert()`
// call is attributed to the nearest enclosing CALLABLE scope by walking the
// brace stack outward past control-flow blocks (`if`/`else`/`foreach`/`scope`/
// `try`/`catch`/…, none of which is a callable) until a scope whose opening
// line looks like a signature (`<modifiers> <type> name(...) {`) is found.
// This is a heuristic, not a parser — see `looksLikeFunctionHeader`'s own
// caveat — but it does not need to be perfect: it only needs to be
// DETERMINISTIC and to resolve the nine known sites correctly, which the
// scanner cells below prove directly. A resolution that is wrong for some
// site nobody has written yet still reddens the census the same way a
// correct one would, because either way the (file, function) pair the
// scanner reports will not be in the recorded table.
//
// Three of the nine sites share a (file, function) pair — `undo()` drives
// `revert()` on three different branches (ToolLifecycle / Case A / Case B),
// all inside the SAME `beginDeliveryBatchGlobal()` it opens once at the top
// of the function. The table below therefore has one row per (file,
// function, why) — nine rows, matching the card's nine-row table by hand —
// and the gate aggregates by (file, function) to compare COUNTS, the same
// move `command_tail_publisher_census_test.d` makes for the reason R2-4
// already gave: a per-name count is immune to line drift, a per-line table
// is not.
module tests.unit.revert_entry_census_test;

import std.algorithm : canFind, startsWith;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Duplicated from `version_poll_census_test.d` (accepted pattern — see that
// file's header). Blank comments and/or literals IN PLACE — same length, same
// line breaks, so a finding still reports the real line number.
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

/// Duplicated from `version_poll_census_test.d`: blank the BODY of every real
/// `unittest` block (not `version (unittest)`, which is production code).
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

// ---------------------------------------------------------------------------
// Function-name resolution. NOT a parser: a header-classifying heuristic over
// the brace stack. It only has to be deterministic and correct for the nine
// known sites (proven by the scanner cells below) — a wrong resolution on
// code nobody has written yet still reddens the gate, because either way the
// reported (file, function) pair will not be in the recorded table.
// ---------------------------------------------------------------------------

/// Keywords that open a CONTROL-FLOW or non-callable block, not a callable.
/// `static` is here to catch `static if`/`static foreach` — the one named
/// blind spot: a `static` FUNCTION modifier (`static bool helper() { … }`)
/// is misclassified as non-callable by this same rule, so a `.revert()`
/// call whose nearest real enclosing function is `static` attributes to
/// that function's own PARENT scope instead. None of the nine recorded
/// sites is `static`; a future one that is will still redden the gate (as
/// an unaccounted pair), just possibly under the parent's name rather than
/// its own — the census does not need the name to be right, only new.
private static immutable string[] kControlKeywords = [
    "if", "for", "foreach", "foreach_reverse", "while", "switch",
    "catch", "else", "try", "finally", "scope", "version", "debug",
    "synchronized", "with", "do", "case", "default", "class", "struct",
    "interface", "template", "union", "enum", "mixin", "static", "align",
    "extern", "import", "module", "unittest", "invariant", "in", "out",
    "body", "asm",
];

private bool looksLikeFunctionHeader(string h) {
    h = h.strip;
    if (h.length == 0) return false;
    size_t i = 0;
    while (i < h.length && isIdentChar(h[i])) ++i;
    const string first = h[0 .. i];
    if (first.length == 0) return false;
    foreach (kw; kControlKeywords) if (first == kw) return false;
    return h.canFind('(');
}

/// The identifier immediately before the FIRST top-level `(` in `h`.
private string extractName(string h) {
    const ptrdiff_t p = () {
        foreach (i, c; h) if (c == '(') return cast(ptrdiff_t)i;
        return cast(ptrdiff_t)-1;
    }();
    if (p < 0) return h.strip;
    string before = h[0 .. p].strip;
    size_t e = before.length;
    size_t s = e;
    while (s > 0 && isIdentChar(before[s - 1])) --s;
    return s < e ? before[s .. e] : "<anonymous>";
}

private struct RevertSite {
    string file;
    string func;
    size_t line;      // 1-based, into the ORIGINAL text — diagnostic only
    string text;
}

private struct ScopeEntry { string name; bool isFunc; }

/// Scan ONE file's already-blanked CODE text for `.revert()` call sites,
/// attributing each to its nearest enclosing callable by walking a brace
/// stack built as the text is consumed left to right.
private RevertSite[] scanRevertSites(string label, string src) {
    const string code = blankUnittestBodies(blankNonCode(src));

    ScopeEntry[] stack;
    auto header = appender!string;
    auto sites  = appender!(RevertSite[]);
    size_t line = 1;

    size_t i = 0;
    while (i < code.length) {
        const char c = code[i];
        if (c == '\n') { ++line; ++i; continue; }
        if (c == '{') {
            const string h = header.data;
            const bool isFunc = looksLikeFunctionHeader(h);
            stack ~= ScopeEntry(isFunc ? extractName(h) : h.strip, isFunc);
            header = appender!string();
            ++i;
            continue;
        }
        if (c == '}') {
            if (stack.length) stack = stack[0 .. $ - 1];
            header = appender!string();
            ++i;
            continue;
        }
        if (c == ';') {
            header = appender!string();
            ++i;
            continue;
        }
        if (code[i .. $].startsWith(".revert()")) {
            string fn = "<module-level>";
            foreach_reverse (s; stack) if (s.isFunc) { fn = s.name; break; }
            sites.put(RevertSite(label, fn, line, "…" ~ ".revert()"));
        }
        header.put(c);
        ++i;
    }
    return sites.data;
}

private struct ScanResult { RevertSite[] sites; size_t filesScanned; }

private ScanResult scanTree() {
    auto sites = appender!(RevertSite[]);
    size_t n = 0;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++n;
        sites.put(scanRevertSites(de.name[repoRoot.length + 1 .. $], readText(de.name)));
    }
    return ScanResult(sites.data, n);
}

/// Code-level occurrence count of `beginDeliveryBatchGlobal(` (the CALL, not
/// a comment naming it) in one file — comments/literals/unittest bodies
/// blanked first, same reason `version_poll_census_test.d` reads its marker
/// off the MARKER view and not raw text: a comment that quotes the call
/// (this file's own rewritten `command.d` doc block does, twice) must not
/// inflate a raw grep.
private size_t codeLevelCallCount(string src, string needle) {
    const string code = blankUnittestBodies(blankNonCode(src));
    size_t n = 0;
    size_t i = 0;
    while (i + needle.length <= code.length) {
        if (code[i .. i + needle.length] == needle) { ++n; i += needle.length; continue; }
        ++i;
    }
    return n;
}

// ---------------------------------------------------------------------------
// SCANNER CELLS, FIRST — proving the resolver on the actual shapes the nine
// recorded sites take, before the tree gate runs on top of it.
// ---------------------------------------------------------------------------

/// `CompositeCommand.revert`'s child loop: a `.revert()` call inside a
/// `foreach_reverse` inside the function named `revert` itself.
unittest {
    enum string probe = q"PROBE
class CompositeCommand : Command {
    override bool revert() {
        foreach_reverse (c; children_) {
            if (!c.revert()) return false;
        }
        return true;
    }
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("expected one call site: %s", s));
    assert(s[0].func == "revert", format("resolved '%s', expected 'revert' — "
        ~ "the foreach_reverse must not be mistaken for the callable", s[0].func));
}

/// `undo()`'s three branches: three `.revert()` calls, each nested inside its
/// own `if`/`else` shape, all inside ONE function named `undo`.
unittest {
    enum string probe = q"PROBE
bool undo() {
    beginDeliveryBatchGlobal();
    scope(exit) endDeliveryBatchGlobal();
    if (!foundModel) {
        if (!e.cmd.revert()) return false;
    }
    if (mi < undoStack.length) {
        if (!modelEntry.cmd.revert()) {
            return false;
        }
    } else {
        if (!e.cmd.revert()) return false;
    }
    return true;
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 3, format("expected three call sites inside undo(): %s", s));
    foreach (ref site; s)
        assert(site.func == "undo", format("resolved '%s' for a branch nested "
            ~ "inside undo() — if/else must not be mistaken for the callable",
            site.func));
}

/// `fire()`'s live-command revert, nested one level inside an `if`.
unittest {
    enum string probe = q"PROBE
bool fire(Command cmd) {
    beginDeliveryBatchGlobal();
    scope(exit) endDeliveryBatchGlobal();
    if (liveCmd !is null) {
        if (!liveCmd.revert()) return false;
    }
    return true;
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("%s", s));
    assert(s[0].func == "fire", s[0].func);
}

/// The four delegation sites: `override bool revert() { return inner.revert(); }`.
unittest {
    enum string probe = q"PROBE
class Wrapper : Command {
    override bool revert() {
        if (inner is null) return false;
        return inner.revert();
    }
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("%s", s));
    assert(s[0].func == "revert", s[0].func);
}

/// A `.revert()` call that is only a comment, a string, or inside a
/// `unittest` body is not a site at all.
unittest {
    enum string probe = q"PROBE
void f() {
    // this.revert() is not a call
    string s = "cmd.revert()";
}
unittest {
    assert(c.revert());
}
PROBE";
    assert(scanRevertSites("probe.d", probe).length == 0,
        "a commented-out / string-literal / unittest-body '.revert()' must not count");
}

/// `version (unittest)` is production code and is scanned like any other
/// callable, unlike a real `unittest` body.
unittest {
    enum string probe = q"PROBE
version (unittest) {
    bool helper() { return inner.revert(); }
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("version (unittest) body was blanked: %s", s));
    assert(s[0].func == "helper", s[0].func);
}

// ---------------------------------------------------------------------------
// THE RECORDED TABLE — nine rows, one per production `.revert()` site,
// matching the card's grep table by hand (task 1932, "Посылка 3 опровергнута").
// Grouped by (file, function): `undo()` carries three of the nine because it
// drives three different branches inside the SAME `beginDeliveryBatchGlobal`
// it opens once.
// ---------------------------------------------------------------------------

private struct RevertRow { string file; string func; string why; }

private static immutable RevertRow[] kRecorded = [
    RevertRow("source/command_history.d", "revert",
        "CompositeCommand.revert() — foreach_reverse over children_, nests "
      ~ "inside the caller's batch rather than opening its own"),
    RevertRow("source/command_history.d", "undo",
        "undo(), ToolLifecycle branch — inside undo()'s own "
      ~ "beginDeliveryBatchGlobal() at :1091"),
    RevertRow("source/command_history.d", "undo",
        "undo(), Case A (nearestModelIndexFromTail found a Model entry) — "
      ~ "same batch"),
    RevertRow("source/command_history.d", "undo",
        "undo(), Case B (no Model entry, B1 fallback) — same batch"),
    RevertRow("source/command_history.d", "fire",
        "fire()'s live-command revert before the re-fire's apply — inside "
      ~ "fire()'s own beginDeliveryBatchGlobal() at :1507"),
    RevertRow("source/commands/copilot/cycle_finding.d", "revert",
        "delegates to the inner select-only command's revert()"),
    RevertRow("source/commands/copilot/select_finding.d", "revert",
        "delegates to inner.revert(), then restores the panel's active row"),
    RevertRow("source/commands/ai3d/generate.d", "revert",
        "delegates to importer.revert()"),
    RevertRow("source/commands/image/commands.d", "revert",
        "delegates to inner_.revert()"),
];

static assert(kRecorded.length == 9,
    "the recorded table must have exactly nine rows — task 1932's grep found "
  ~ "nine production `.revert()` call sites; if the tree has genuinely grown "
  ~ "or shrunk this set, the count changes together with the rows");

// ---------------------------------------------------------------------------
// NOT-A-`Command.revert()` EXCLUSIONS. The scanner is a textual `.revert()`
// match with no type information, so it also finds `.revert()` calls on
// types that are not `Command` at all. There is exactly one such site in the
// tree today, and the card names it explicitly so it is not mistaken for a
// tenth Command-revert site: `xfrm_transform.d:4426` calls `gh.revert()` on
// a `GestureHook` (built by `buildGestureHooks`, `:4376`) from inside the
// REVERT closure `commitEdit` composes for `setCmdHooks` — that closure runs
// later, when the `Command` this commit builds is itself reverted, so this
// line is a HOOK BODY, not a call this test's nine-row table is about.
// Excluded by (file, function) like everything else, so a second, unrelated
// `.revert()` added to the SAME function would still be counted and would
// still redden the gate (proven by the probe cell below).
// ---------------------------------------------------------------------------
private struct ExcludedRow { string file; string func; string why; }

private static immutable ExcludedRow[] kNotCommandRevert = [
    ExcludedRow("source/tools/transform/xfrm_transform.d", "commitEdit",
        "`gh.revert()` on a `GestureHook`, not on a `Command` — a hook body "
      ~ "composed for `setCmdHooks`, not a call this census's batches govern"),
];

/// Subtract exactly ONE occurrence per excluded row, not the whole key — a
/// second, unrelated `.revert()` landing in the same (file, function) must
/// still show up as unaccounted afterwards. Split out from the gate so the
/// probe cell below can exercise it on a synthetic map instead of the tree.
private size_t[string] applyExclusions(size_t[string] found, const ExcludedRow[] exclusions) {
    foreach (ref ex; exclusions) {
        const string key = ex.file ~ "\0" ~ ex.func;
        const size_t cur = found.get(key, 0);
        assert(cur > 0, format(
            "excluded (file, function) pair %s :: %s has ZERO scanned "
          ~ "occurrences — the exclusion is now stale (the excluded call "
          ~ "moved or was deleted). Delete this exclusion row rather than "
          ~ "let it silently cover for a future, unrelated site.",
            ex.file, ex.func));
        if (cur <= 1) found.remove(key); else found[key] = cur - 1;
    }
    return found;
}

/// The exclusion must not swallow a second, unrelated site at the same
/// (file, function) pair — proven on a synthetic map before trusting it on
/// the tree.
unittest {
    static immutable ExcludedRow[] ex = [ExcludedRow("f.d", "fn", "test-only")];

    size_t[string] one = ["f.d\0fn": 1];
    assert(applyExclusions(one, ex).length == 0,
        "the sole excluded occurrence must be fully removed");

    size_t[string] two = ["f.d\0fn": 2];
    auto after = applyExclusions(two, ex);
    assert(after.get("f.d\0fn", 0) == 1,
        "a second, unexcluded occurrence at the same key must SURVIVE the "
      ~ "exclusion, not be swallowed by it");
}

// ---------------------------------------------------------------------------
// THE GATE.
// ---------------------------------------------------------------------------
unittest {
    // Every recorded file must still exist — checked first, same reason
    // `version_poll_census_test.d` checks it first: a moved module should be
    // diagnosed as "row stale", not as "scanner found 0" further down.
    bool[string] seenFiles;
    foreach (ref r; kRecorded) seenFiles[r.file] = true;
    foreach (f; seenFiles.byKey)
        assert(buildPath(repoRoot, f).exists, format(
            "the revert census records site(s) in %s and that file is gone. "
          ~ "If the module moved, move the row(s); if the revert() call went "
          ~ "with it, delete the row(s).", f));

    const scanned = scanTree();

    size_t[string] expected;
    foreach (ref r; kRecorded) expected[r.file ~ "\0" ~ r.func]
        = expected.get(r.file ~ "\0" ~ r.func, 0) + 1;

    size_t[string] found;
    foreach (ref s; scanned.sites) found[s.file ~ "\0" ~ s.func]
        = found.get(s.file ~ "\0" ~ s.func, 0) + 1;
    found = applyExclusions(found, kNotCommandRevert);

    auto bad = appender!string;
    foreach (key, n; expected) {
        const size_t got = found.get(key, 0);
        if (got == n) continue;
        auto parts = key.split0();
        bad.put(format("\n    %s :: %s — recorded %d, scanner found %d",
                        parts[0], parts[1], n, got));
    }
    foreach (key, n; found) {
        if (key in expected) continue;
        auto parts = key.split0();
        bad.put(format("\n    %s :: %s — NOT IN THE RECORDED TABLE AT ALL, "
                      ~ "scanner found %d site(s)", parts[0], parts[1], n));
        foreach (ref s; scanned.sites)
            if (s.file == parts[0] && s.func == parts[1])
                bad.put(format("\n        found %s:%d", s.file, s.line));
    }

    assert(bad.data.length == 0, format(
        "task 1932: the production `.revert()` call-site SET no longer "
      ~ "matches the recorded nine-row table.%s\n\n"
      ~ "  A `.revert()` call is not wrong by itself — all nine recorded "
      ~ "sites are safe because `Command.apply`, `CommandHistory.undo()`, "
      ~ "`.redo()` and `.fire()` each hold `beginDeliveryBatchGlobal()` "
      ~ "around every revert they drive. What is wrong is an UNACCOUNTED "
      ~ "site: either it already lives inside one of those four batches (in "
      ~ "which case add its row here), or it does not (in which case it "
      ~ "needs a batch of its own before it can be safe, same as the other "
      ~ "nine got).\n\n"
      ~ "  Recorded: %d site(s) over %d (file, function) pair(s). Scanner: "
      ~ "%d over %d.",
        bad.data, kRecorded.length, expected.length,
        scanned.sites.length, found.length));

    // Vacuity floor, AFTER the real assertion — a scanner that lost its place
    // (an unterminated literal, a stripper bug) finds nothing and the gate
    // above passes for the wrong reason. 437 `.d` files stand under source/
    // today (2026-08-26); the floor is set well below that so retiring a few
    // files does not require touching this test, but far enough above zero
    // to catch a scan that lost half the tree.
    assert(scanned.filesScanned >= 400, format(
        "the revert-census scanner only walked %d file(s) under source/ — it "
      ~ "has almost certainly lost its place, which makes the gate above "
      ~ "vacuous. Fix the walk, do not lower this floor.", scanned.filesScanned));
}

/// Small local helper: split a `"\0"`-joined `(file, func)` key back apart.
/// Kept next to its one caller rather than in the shared blank-strip section
/// above, since nothing else in this file needs it.
private string[2] split0(string key) {
    foreach (i, c; key) if (c == '\0') return [key[0 .. i], key[i + 1 .. $]];
    return [key, ""];
}

// ---------------------------------------------------------------------------
// POSITIVE CONTROL — without this, block A above is vacuous on a broken
// walk in a way the file-count floor cannot catch: if `blankNonCode` or
// `blankUnittestBodies` desynced and ate the rest of a file, the census could
// report "0 revert() sites found, table also says 0 outside this file" and
// look healthy. `beginDeliveryBatchGlobal(` — the actual CALL, counted on the
// CODE view so a comment mentioning it (this file's own rewritten
// `command.d` doc block does, twice) cannot inflate it — is known to appear
// exactly three times in `command_history.d` (`undo()`, `redo()`, `fire()`)
// and exactly once in `command.d` (`Command.apply`). `redo()` is not itself a
// `.revert()` site (it replays forward through `cmd.apply()`), so this control
// also proves the scanner distinguishes "opens the batch" from "drives a
// revert inside it".
// ---------------------------------------------------------------------------
unittest {
    const string historySrc = readText(buildPath(repoRoot, "source/command_history.d"));
    const string commandSrc = readText(buildPath(repoRoot, "source/command.d"));

    const size_t nHistory = codeLevelCallCount(historySrc, "beginDeliveryBatchGlobal(");
    const size_t nCommand = codeLevelCallCount(commandSrc, "beginDeliveryBatchGlobal(");

    assert(nHistory == 3, format(
        "expected beginDeliveryBatchGlobal( to be CALLED exactly 3 times in "
      ~ "command_history.d (undo(), redo(), fire()); code-level scan found %d "
      ~ "— either a batch was removed/added, or this scanner lost its place",
        nHistory));
    assert(nCommand == 1, format(
        "expected beginDeliveryBatchGlobal( to be CALLED exactly 1 time in "
      ~ "command.d (Command.apply); code-level scan found %d", nCommand));

    // And the table rows' files are the ones the census actually depends on.
    foreach (ref r; kRecorded)
        assert(buildPath(repoRoot, r.file).exists,
            format("recorded file missing: %s", r.file));
}
