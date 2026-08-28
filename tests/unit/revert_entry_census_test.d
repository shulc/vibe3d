// revert_entry_census_test — TWO gates over one scan of `source/**`.
//
//   GATE 1 (task 1932): every production NO-ARGUMENT `.revert()` call site is
//     one of the NINE recorded ones, each of which runs inside a global
//     delivery batch. `Command.revert()` takes no argument, which is what
//     makes the empty-paren predicate the right one here.
//
//   GATE 2 (task 1903 stage N-d): every ARGUMENT-BEARING `.revert(x)` site is
//     in a 67-file roster totalling 104, and its receiver is one of four
//     recorded undo-image spellings. These are `MeshEditDelta.revert(*mesh)`
//     and `RecordedUndo.revert(*mesh)` — a different set with a different
//     obligation, and until N-d they had no census at all. See gate 2's own
//     header for why the fix was a second gate rather than a looser first one,
//     and for the number the roster moved from and to.
//
// WHAT THIS GATE IS FOR. `source/command.d`'s doc comment used to claim the
// two undo paths ("`/api/undo` / `navHistory` call `history.undo()` raw" vs.
// "the registered `history.undo` command wraps it") differ in delivery
// granularity. Task 1932 re-measured that claim by grep and found it FALSE:
// `CommandHistory.undo()` (`command_history.d:1091`), `.redo()` (`:1208`) and
// `.fire()` (`:1507`) each hold `beginDeliveryBatchGlobal()` around every
// `revert()` they drive, so ALL production paths deliver once per step. The
// comment was rewritten to say that instead. This census is the executable
// half of the correction: it fails the moment a TENTH production no-argument
// `.revert()` call site is added anywhere in `source/**`, because a new site is exactly
// how the false claim got written the first time — someone added a revert
// path and never checked whether it landed inside one of the three batches.
//
// A new call site is not necessarily wrong. It is UNACCOUNTED — the census
// forces a human decision: does it already live inside
// `beginDeliveryBatchGlobal`/`endDeliveryBatchGlobal`, or does it need a row
// added to the table (and, if not, a batch of its own)?
//
// WHAT COUNTS AS A SITE. A `.revert(` method call in CODE, with or without an
// argument — the two gates partition the same scan by that one bit. Comments,
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
    /// The identifier immediately left of the dot, e.g. `delta_` in
    /// `delta_.revert(*mesh)`. Diagnostic AND load-bearing: gate 2 below
    /// asserts the argument-bearing receivers are a CLOSED set of undo-image
    /// spellings, so a `Command`-typed field acquiring an argument would be
    /// named rather than silently counted.
    string recv;
    /// `revert()` (no argument) or `revert(x)`. THE DISCRIMINATOR, and it is
    /// not a nicety: `Command.revert()` takes none, every undo IMAGE
    /// (`MeshEditDelta.revert(Mesh&)`, `RecordedUndo.revert(Mesh&)`) takes one.
    bool hasArg;
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
        if (code[i .. $].startsWith(".revert(")) {
            string fn = "<module-level>";
            foreach_reverse (s; stack) if (s.isFunc) { fn = s.name; break; }

            // The receiver: walk left over an identifier / `)` / `]` run.
            size_t rb = i;
            while (rb > 0) {
                const char pc = code[rb - 1];
                const bool idish = (pc >= 'a' && pc <= 'z') || (pc >= 'A' && pc <= 'Z')
                                || (pc >= '0' && pc <= '9') || pc == '_'
                                || pc == ')' || pc == ']';
                if (!idish) break;
                --rb;
            }
            const string recv = code[rb .. i];

            // The argument list, to the matching close paren.
            size_t k = i + ".revert(".length;
            int depth = 1;
            size_t e = k;
            while (e < code.length && depth > 0) {
                if (code[e] == '(') ++depth;
                else if (code[e] == ')') --depth;
                ++e;
            }
            const string arg = (e > k) ? code[k .. e - 1].strip : "";

            sites.put(RevertSite(label, fn, line,
                                 "…" ~ recv ~ ".revert(" ~ arg ~ ")",
                                 recv, arg.length != 0));
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
    RevertRow("source/command_history.d", "revertImpl",
        "CompositeCommand.revertImpl() — foreach_reverse over children_, nests "
      ~ "inside the caller's batch rather than opening its own. TASK 2500 "
      ~ "renamed the enclosing function: `Command.revert` is `final` now and "
      ~ "`revertImpl` is the override point, so the `func` column moved with "
      ~ "it. The call itself did not move and is still inside undo()'s batch."),
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
    RevertRow("source/commands/copilot/cycle_finding.d", "revertImpl",
        "delegates to the inner select-only command's revert()"),
    RevertRow("source/commands/copilot/select_finding.d", "revertImpl",
        "delegates to inner.revert(), then restores the panel's active row"),
    RevertRow("source/commands/ai3d/generate.d", "revertImpl",
        "delegates to importer.revert()"),
    RevertRow("source/commands/image/commands.d", "revertImpl",
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
    foreach (ref s; scanned.sites) {
        // GATE 1 IS THE NO-ARGUMENT SET, and that restriction is the whole
        // discrimination: `Command.revert()` takes no argument, and every
        // undo-IMAGE revert (`MeshEditDelta`, `RecordedUndo`) takes the mesh.
        // Gate 2 below owns the argument-bearing ones. Before task 1903 stage
        // N the scanner matched the literal `.revert()` and there was no gate
        // 2 at all, so 71 sites this project added between L0 and L4 were not
        // merely unaccounted — they were invisible.
        if (s.hasArg) continue;
        found[s.file ~ "\0" ~ s.func] = found.get(s.file ~ "\0" ~ s.func, 0) + 1;
    }
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


// ===========================================================================
// GATE 2 — THE ARGUMENT-BEARING SET (task 1903 Stage N-d).
//
// WHY THERE IS A SECOND GATE AND NOT A WIDER FIRST ONE. Gate 1's predicate
// was, and remains, `revert` with NO argument. That is exactly right for the
// claim it makes: `Command.revert()` takes none. What was wrong was the rule
// written on top of it — §S-8 item 1 of the seam plan told every migration
// family to extend `kRecorded` in the same commit ("L7 adds 3, L9 adds 2, L10
// adds 13"), and no migration ever could, because a migrated command's undo
// image is `delta_.revert(*mesh)`, which the predicate does not and should not
// match. Three cards reported the roster "stuck at nine" and none of them
// found this. It was never a stuck roster; it was a roster asked to hold rows
// that belong to a different set.
//
// So the repair is not to loosen gate 1 — that would sweep every op-log
// revert into a table about delivery batches. It is to give the
// argument-bearing set a census of its own, which nothing has ever had.
// Measured when this gate was written: **9 recorded sites became 9 + 71**,
// across 48 files, and the 71 had no enumeration anywhere in the tree.
//
// WHAT THIS GATE REFUSES. A new argument-bearing `.revert(` site in a file
// that had none, or an extra one in a file that had some, or ANY receiver
// spelling outside the closed set below. The last is the part that carries
// the type information the scanner does not have: every one of these 71 is an
// undo IMAGE — `MeshEditDelta.revert(ref Mesh)` through a `delta_` field, or
// `RecordedUndo`/`PositionUndo.revert(ref Mesh)` through `undo_` / `undo`, or
// the `d` parameter inside `position_undo.d`'s own helper. A `Command`-typed
// receiver acquiring an argument would land here and be named, rather than
// vanish between two gates.
//
// A new row is not wrong by itself. It is UNACCOUNTED, and adding it is the
// declaration §S-8 always wanted: the migration commit that adds the site adds
// its row, and the card records the number the total moved from and to.
// ===========================================================================

private struct UndoImageRow { string file; size_t n; }

private static immutable UndoImageRow[] kUndoImage = [
    UndoImageRow("source/commands/mesh/add_point.d", 1),
    UndoImageRow("source/commands/mesh/array.d", 1),
    UndoImageRow("source/commands/mesh/axis_slice.d", 4),
    UndoImageRow("source/commands/mesh/bevel.d", 2),
    UndoImageRow("source/commands/mesh/bridge.d", 2),
    UndoImageRow("source/commands/mesh/cleanup.d", 1),
    UndoImageRow("source/commands/mesh/clone_.d", 1),
    UndoImageRow("source/commands/mesh/collapse.d", 2),
    UndoImageRow("source/commands/mesh/cut.d", 2),
    UndoImageRow("source/commands/mesh/delete.d", 1),
    UndoImageRow("source/commands/mesh/detriangulate.d", 1),
    UndoImageRow("source/commands/mesh/duplicate.d", 1),
    UndoImageRow("source/commands/mesh/edge_crease.d", 3),
    UndoImageRow("source/commands/mesh/edge_join.d", 2),
    UndoImageRow("source/commands/mesh/edge_slice.d", 2),
    UndoImageRow("source/commands/mesh/edge_slide.d", 1),
    UndoImageRow("source/commands/mesh/face_extrude.d", 2),
    UndoImageRow("source/commands/mesh/fix_orientation.d", 1),
    UndoImageRow("source/commands/mesh/flip.d", 1),
    UndoImageRow("source/commands/mesh/jitter.d", 1),
    UndoImageRow("source/commands/mesh/linear_align.d", 1),
    UndoImageRow("source/commands/mesh/loop_slice.d", 4),
    UndoImageRow("source/commands/mesh/magnet.d", 1),
    UndoImageRow("source/commands/mesh/make_polygon.d", 1),
    UndoImageRow("source/commands/mesh/merge.d", 2),
    UndoImageRow("source/commands/mesh/mirror.d", 1),
    UndoImageRow("source/commands/mesh/morph.d", 6),
    UndoImageRow("source/commands/mesh/poly_inset.d", 2),
    UndoImageRow("source/commands/mesh/polygon_align.d", 1),
    UndoImageRow("source/commands/mesh/position_undo.d", 1),
    UndoImageRow("source/commands/mesh/quadruple.d", 1),
    UndoImageRow("source/commands/mesh/quantize.d", 1),
    UndoImageRow("source/commands/mesh/radial_align.d", 1),
    UndoImageRow("source/commands/mesh/radial_array.d", 1),
    UndoImageRow("source/commands/mesh/reduce.d", 2),
    UndoImageRow("source/commands/mesh/remove.d", 1),
    UndoImageRow("source/commands/mesh/screen_slice.d", 2),
    UndoImageRow("source/commands/mesh/session_edit.d", 1),
    UndoImageRow("source/commands/mesh/smooth.d", 1),
    UndoImageRow("source/commands/mesh/smooth_shift.d", 2),
    UndoImageRow("source/commands/mesh/spikey.d", 1),
    UndoImageRow("source/commands/mesh/spin_edge.d", 1),
    UndoImageRow("source/commands/mesh/split_edge.d", 1),
    UndoImageRow("source/commands/mesh/split_face.d", 1),
    UndoImageRow("source/commands/mesh/stroke_extrude.d", 2),
    UndoImageRow("source/commands/mesh/sweep.d", 1),
    UndoImageRow("source/commands/mesh/symmetrize.d", 1),
    UndoImageRow("source/commands/mesh/thicken.d", 1),
    UndoImageRow("source/commands/mesh/transform.d", 1),
    UndoImageRow("source/commands/mesh/triple.d", 1),
    UndoImageRow("source/commands/mesh/unify.d", 1),
    UndoImageRow("source/commands/mesh/uv_map_util.d", 4),
    UndoImageRow("source/commands/mesh/uv_pack.d", 2),
    UndoImageRow("source/commands/mesh/uv_project.d", 1),
    UndoImageRow("source/commands/mesh/uv_relax.d", 1),
    UndoImageRow("source/commands/mesh/uv_transform.d", 3),
    UndoImageRow("source/commands/mesh/uv_unwrap.d", 1),
    UndoImageRow("source/commands/mesh/vert_join.d", 2),
    UndoImageRow("source/commands/mesh/vert_merge.d", 1),
    UndoImageRow("source/commands/mesh/vertex_bevel.d", 1),
    UndoImageRow("source/commands/mesh/vertex_center.d", 1),
    UndoImageRow("source/commands/mesh/vertex_extrude.d", 2),
    UndoImageRow("source/commands/mesh/vertex_new.d", 1),
    UndoImageRow("source/commands/mesh/vertex_set.d", 1),
    UndoImageRow("source/commands/mesh/vertex_split.d", 1),
    UndoImageRow("source/commands/mesh/weightmap.d", 4),
    UndoImageRow("source/commands/mesh/weld_vertex_pair.d", 1),
];

/// The EXACT total, not a floor. A threshold would stay green over a file
/// that stopped reverting for an unrelated reason while another gained a site.
private enum size_t kUndoImageTotal = 104;

static assert(kUndoImage.length == 67,
    "the undo-image roster must hold exactly 67 files. It was 48 files / 71 "
  ~ "sites when task 1903 stage N-d gave this set its first census; task 2500 "
  ~ "moved it to 67 / 104 by deleting `map_edit_undo.revertMapEdit` (and its "
  ~ "`…EmptyOk` twin) and putting the bare `undo_.revert(*mesh)` those "
  ~ "helpers wrapped into the twenty map-edit commands themselves — one "
  ~ "helper site became thirty-four call sites, and every one of them is now "
  ~ "declared here rather than hidden behind a forwarder. A family that "
  ~ "migrates changes this together with the rows and with kUndoImageTotal");

/// The CLOSED set of receiver spellings. This is where the type information
/// the scanner cannot see is pinned by hand.
private static immutable string[] kUndoImageReceivers = [
    "delta_",   // MeshEditDelta, the migrated commands' field
    "undo_",    // RecordedUndo / PositionUndo, the L0–L2 position families
    "undo",     // the same, as a `ref` parameter (map_edit_undo.runMapEdit)
    "d",        // position_undo.d's own helper parameter
];

unittest
{
    const scanned = scanTree();

    size_t[string] found;
    size_t total = 0;
    string[string] recvOf;
    foreach (ref s; scanned.sites) {
        if (!s.hasArg) continue;
        found[s.file] = found.get(s.file, 0) + 1;
        ++total;
        assert(canFind(kUndoImageReceivers, s.recv), format(
            "%s:%d — `%s.revert(...)` takes an argument and `%s` is not one of "
          ~ "the recorded undo-image receivers %s. Either a new undo image was "
          ~ "introduced (add its spelling, with what type it is), or a "
          ~ "`Command`-typed receiver has grown an argument, which would slip "
          ~ "past gate 1 and land here on purpose.",
            s.file, s.line, s.recv, s.recv, kUndoImageReceivers));
    }

    size_t[string] expected;
    foreach (ref r; kUndoImage) expected[r.file] = r.n;

    auto bad = appender!string;
    foreach (file, n; expected) {
        const size_t got = found.get(file, 0);
        if (got != n)
            bad.put(format("\n    %s — roster says %d, scanner found %d",
                           file, n, got));
    }
    foreach (file, n; found)
        if (file !in expected)
            bad.put(format("\n    %s — NOT IN THE ROSTER AT ALL, scanner "
                         ~ "found %d site(s)", file, n));

    assert(bad.data.length == 0, format(
        "task 1903 stage N-d: the argument-bearing `.revert(` site set no "
      ~ "longer matches the 67-file roster.%s\n\n"
      ~ "  These are undo IMAGES — `MeshEditDelta.revert(*mesh)` and "
      ~ "`RecordedUndo.revert(*mesh)` — not `Command.revert()`, which gate 1 "
      ~ "above owns. A new one is not wrong; it is UNACCOUNTED, and declaring "
      ~ "it here is what §S-8 item 1 of the seam plan asked every migration "
      ~ "commit to do and what no migration could do while the scanner "
      ~ "matched only the empty-paren spelling.\n\n"
      ~ "  Roster: %d site(s) over %d file(s). Scanner: %d over %d.",
        bad.data, kUndoImageTotal, kUndoImage.length, total, found.length));

    assert(total == kUndoImageTotal, format(
        "the roster's per-file counts add up but the total is %d, not the "
      ~ "recorded %d — kUndoImageTotal and the rows have drifted apart",
        total, kUndoImageTotal));
}

/// THE TREE-ROOTED CANARY (P0-N-3). The synthetic scanner cells above prove
/// the resolver on hand-written probes; they cannot prove the predicate fires
/// on the spelling the TREE actually uses, and a census whose predicate
/// matches nothing reads 0 for free — which is precisely how the
/// argument-bearing set stayed invisible for four migration stages.
///
/// So: take a real file the census depends on, append ONE synthetic
/// `delta_.revert(*mesh)` inside a real function, and assert the scanner's
/// argument-bearing count for that text goes up by exactly one. Reverting the
/// predicate to the empty-paren form makes both readings 0 and this cell
/// reddens before the roster gate does.
unittest
{
    immutable real_ = readText(buildPath(repoRoot, "source/commands/mesh/array.d"));
    size_t argCount(string src) {
        size_t n = 0;
        foreach (ref s; scanRevertSites("array.d", src)) if (s.hasArg) ++n;
        return n;
    }
    const size_t base = argCount(real_);
    assert(base == 1, format(
        "the canary's host file no longer holds exactly the 1 argument-bearing "
      ~ "revert site this cell was calibrated on — it found %d. A ZERO here is "
      ~ "not a calibration problem: it is the predicate matching nothing, i.e. "
      ~ "the empty-paren defect of task 1903 stage N-d coming back. Any other "
      ~ "number means array.d genuinely changed — re-calibrate on it rather "
      ~ "than deleting the canary.", base));

    immutable planted = real_ ~ "\n"
        ~ "private bool censusCanaryNeverCompiled(ref Mesh m) {\n"
        ~ "    MeshEditDelta delta_;\n"
        ~ "    return delta_.revert(m);\n"
        ~ "}\n";
    assert(argCount(planted) == base + 1,
        "the census scanner did NOT find a planted `delta_.revert(m)` in real "
      ~ "tree text. Its predicate matches nothing the tree writes, so every "
      ~ "count assertion above is satisfied for free — this is the empty-paren "
      ~ "defect of task 1903 stage N-d, in the shape it takes when it comes "
      ~ "back.");

    // …and the same plant must NOT move gate 1's no-argument count, or the two
    // gates are reading one set between them.
    size_t noArgCount(string src) {
        size_t n = 0;
        foreach (ref s; scanRevertSites("array.d", src)) if (!s.hasArg) ++n;
        return n;
    }
    assert(noArgCount(planted) == noArgCount(real_),
        "planting an ARGUMENT-bearing revert moved gate 1's no-argument count "
      ~ "— the two gates are not partitioning the scan and one of them is "
      ~ "double-counting");
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
