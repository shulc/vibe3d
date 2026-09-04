// revert_entry_census_test — TWO gates over one scan of `source/**`.
//
//   GATE 1 (task 1932): every production NO-ARGUMENT `.revert()` call site is
//     one of the SEVEN recorded ones, each of which runs inside a global
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
// half of the correction: it fails the moment the production no-argument
// `.revert()` call-site set changes anywhere in `source/**`, because a new
// site is exactly how the false claim got written the first time — someone
// added a revert path and never checked whether it landed inside one of the
// three batches.
//
// A new call site is not necessarily wrong. It is UNACCOUNTED — the census
// forces a human decision: does it already live inside
// `beginDeliveryBatchGlobal`/`endDeliveryBatchGlobal`, or does it need a row
// added to the table (and, if not, a batch of its own)?
//
// WHAT COUNTS AS A SITE. A `revert` method call in CODE, with or without an
// argument — the two gates partition the same scan by that one bit. The
// TRIGGER is `revertSiteHere` below, three forms rather than the literal
// `".revert("` this file shipped until task 2007: a direct call, an
// ADDRESS-OF take (`&cmd.revert`, the indirection finding #2 built and showed
// scanning as zero), and an optional-paren call in statement position. Its doc
// comment says why the finding's own prescription — the bare identifier — was
// measured and rejected, and which correct code it reddened. Comments,
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
// DETERMINISTIC and to resolve the seven known sites correctly, which the
// scanner cells below prove directly. A resolution that is wrong for some
// site nobody has written yet still reddens the census the same way a
// correct one would, because either way the (file, function) pair the
// scanner reports will not be in the recorded table.
//
// Before task 3694, three sites shared `source/command_history.d :: undo`:
// ToolLifecycle, Case A and Case B. Strict lifecycle LIFO removed all three
// branches and added one common-tail call in the same function. The table
// below records that seven-site result and the gate still aggregates by
// (file, function) to compare COUNTS, the same move
// `command_tail_publisher_census_test.d` makes for the reason R2-4 already
// gave: a per-name count is immune to line drift, a per-line table is not.
module tests.unit.revert_entry_census_test;

import std.algorithm : canFind, startsWith;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : strip;

import tests.unit.census_symbols : sharedBlankNonCode = blankNonCode,
    sharedBlankUnittestBodies = blankUnittestBodies, enclosingSymbols,
    symbolAt, LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Duplicated from `version_poll_census_test.d` (accepted pattern — see that
// file's header). Blank comments and/or literals IN PLACE — same length, same
// line breaks, so a finding still reports the real line number.
// ---------------------------------------------------------------------------
package alias blankNonCode = sharedBlankNonCode;

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Duplicated from `version_poll_census_test.d`: blank the BODY of every real
/// `unittest` block (not `version (unittest)`, which is production code).
private alias blankUnittestBodies = sharedBlankUnittestBodies;

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
    string symbol;
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

/// Does a `.revert` SITE begin at `i` in `code`? Three triggers, and the set is
/// deliberately NOT "the bare identifier".
///
/// TASK 2007 FINDING #2, and the correction the fix needed. The finding was
/// real: the old needle was the literal `".revert("`, so the indirection
/// `auto fn = &cmd.revert; fn();` — the same call, with the parenthesis
/// belonging to `fn` — scanned as ZERO sites, and an added production revert
/// path outside every delivery batch would have been invisible. The finding's
/// prescribed fix was the bare identifier, as already used by
/// `sel_channel_census_test.d`'s `kMethod` and
/// `confined_publisher_census_test.d`'s `kIdents`.
///
/// THAT FIX WAS MEASURED AND REJECTED: it reddens on CORRECT code. `revert` is
/// not one name in this tree — `void delegate() revert;` is a FIELD on two
/// gesture-hook structs (`vertex_edit.d`'s `Hooks`, `xfrm_transform.d`'s
/// `GestureHooks`), and the bare match reported five of their reads/writes
/// (`h.revert = () {…}`, `gh.revert`, `fh.revert`) as unaccounted call sites.
/// A census that reddens on correct code is the same defect as one that cannot
/// redden, so the trigger is narrowed to the three forms that CANNOT be a field
/// access:
///
///   1. `.revert` … `(`  — the direct call. Whitespace between the name and the
///      paren is allowed; the old needle required them adjacent.
///   2. `&` … `.revert`  — the ADDRESS of the method, which is the escape the
///      finding built. Taking `&` of a delegate FIELD yields a pointer to a
///      delegate and appears nowhere in `source/**` (checked), so this trigger
///      adds no site today and fires the moment the indirection is written.
///   3. `.revert` … `;` in STATEMENT POSITION — D's optional-paren call spelled
///      as a bare statement (`cmd.revert;`). The statement-position term is
///      load-bearing and was added after a measurement: without it the trigger
///      also fired on `scaleSub.wrapperFieldRevertHook = gh.revert;`
///      (`xfrm_transform.d:3670`, and its rotate twin at `:3564`) — a plain
///      field READ whose statement happens to end in a semicolon. WITH it, the
///      only `.revert;` that can reach the trigger is one that is the whole
///      statement, and a bare field read there is not valid D ("has no effect
///      in expression"), so it must be a call.
///
/// WHAT IS STILL NOT COVERED, said plainly rather than left to be discovered:
/// an optional-paren call used inside a larger expression (`if (cmd.revert &&
/// …)`). It is textually identical to a field read (`if (gh.revert !is null)`),
/// and nothing short of type resolution separates them — so it is left out
/// rather than shipped as a false positive. The `&`-form above is the one the
/// finding actually demonstrated.
private bool revertSiteHere(string code, size_t i) {
    enum string kName = ".revert";
    if (!code[i .. $].startsWith(kName)) return false;
    const size_t after = i + kName.length;
    if (after < code.length && isIdentChar(code[after])) return false;   // .revertImpl

    // Trigger 2: the receiver run walks left over identifier-ish characters;
    // an `&` immediately before that run is the address-of take.
    size_t rb = i;
    while (rb > 0) {
        const char pc = code[rb - 1];
        const bool idish = (pc >= 'a' && pc <= 'z') || (pc >= 'A' && pc <= 'Z')
                        || (pc >= '0' && pc <= '9') || pc == '_'
                        || pc == ')' || pc == ']' || pc == '.';
        if (!idish) break;
        --rb;
    }
    if (rb > 0 && code[rb - 1] == '&') return true;

    // Triggers 1 and 3: the next non-space token.
    size_t k = after;
    while (k < code.length && (code[k] == ' ' || code[k] == '\t'
                            || code[k] == '\n' || code[k] == '\r')) ++k;
    if (k >= code.length) return false;
    if (code[k] == '(') return true;
    if (code[k] != ';') return false;

    // Trigger 3's statement-position term: nothing but whitespace between the
    // receiver run and a statement boundary. `x = gh.revert;` fails here, as it
    // must — that is a field read, not a call.
    size_t b = rb;
    while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t'
                  || code[b - 1] == '\n' || code[b - 1] == '\r')) --b;
    return b == 0 || code[b - 1] == ';' || code[b - 1] == '{'
                  || code[b - 1] == '}' || code[b - 1] == ':';
}

/// Scan ONE file's already-blanked CODE text for `.revert()` call sites,
/// attributing each to its nearest enclosing callable by walking a brace
/// stack built as the text is consumed left to right.
private RevertSite[] scanRevertSites(string label, string src) {
    const string code = blankUnittestBodies(blankNonCode(src));
    const symbols = enclosingSymbols(code);

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
        if (revertSiteHere(code, i)) {
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

            // The argument list, IF the site spells one. A delegate take
            // (`&cmd.revert`) and D's optional-paren call (`cmd.revert;`) both
            // reach here with no `(` at all; both are argument-LESS, so they
            // join gate 1's `Command.revert()` bucket, which is exactly where
            // an unaccounted no-argument path has to surface.
            size_t k = i + ".revert".length;
            while (k < code.length && (code[k] == ' ' || code[k] == '\t'
                                    || code[k] == '\n' || code[k] == '\r')) ++k;
            bool parens = false;
            string arg;
            if (k < code.length && code[k] == '(') {
                parens = true;
                ++k;
                int depth = 1;
                size_t e = k;
                while (e < code.length && depth > 0) {
                    if (code[e] == '(') ++depth;
                    else if (code[e] == ')') --depth;
                    ++e;
                }
                arg = (e > k) ? code[k .. e - 1].strip : "";
            }

            sites.put(RevertSite(label, symbolAt(symbols, line - 1), fn, line,
                                 "…" ~ recv ~ ".revert"
                                 ~ (parens ? "(" ~ arg ~ ")" : ""),
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
// SCANNER CELLS, FIRST — proving the resolver on current recorded shapes and
// the retired pre-3694 multi-branch undo shape before the tree gate runs.
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

/// The retired pre-3694 `undo()` shape: three `.revert()` calls, each nested
/// inside its own `if`/`else`, all inside ONE function named `undo`. It remains
/// a scanner probe because count aggregation must not lose same-key sites.
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

/// TASK 2007 FINDING #2 — THE ESCAPE, PINNED. `auto fn = &cmd.revert; fn();`
/// is a real revert path with no parenthesis after the name, and the old
/// literal needle `".revert("` scanned it as ZERO sites. This cell is the
/// mutation the finding used, frozen: revert `revertSiteHere`'s trigger 2 and
/// this assert reads 0 and reddens by its own message.
unittest {
    enum string probe = q"PROBE
bool applyUndo(Command cmd) {
    auto fn = &cmd.revert;
    return fn();
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("the delegate take `&cmd.revert` scanned as %d "
        ~ "site(s), expected 1 — this is task 2007 finding #2's escape and the "
        ~ "whole reason the trigger is not the literal `.revert(`: %s",
        s.length, s));
    assert(!s[0].hasArg, format("`&cmd.revert` carries no argument list, so it "
        ~ "belongs to gate 1's `Command.revert()` bucket; got hasArg=%s",
        s[0].hasArg));
    assert(s[0].func == "applyUndo", s[0].func);
}

/// …and the optional-paren CALL as a bare statement, the other spelling that
/// reaches `Command.revert` without writing a parenthesis.
unittest {
    enum string probe = q"PROBE
void applyUndo(Command cmd) {
    cmd.revert;
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 1, format("the optional-paren call statement `cmd.revert;` "
        ~ "scanned as %d site(s), expected 1: %s", s.length, s));
    assert(!s[0].hasArg, "an optional-paren call passes no argument");
}

/// THE NEGATIVE CONTROL, and it is not decoration: `revert` is ALSO a
/// `void delegate()` FIELD in this tree (`vertex_edit.d`'s `Hooks`,
/// `xfrm_transform.d`'s `GestureHooks`). Task 2007 finding #2 prescribed a BARE
/// identifier match; measured, that reddened on five correct field reads and
/// writes. Every shape below must scan as ZERO — widen the trigger and this
/// cell says which spelling the widening broke.
unittest {
    enum string probe = q"PROBE
struct GestureHooks { void delegate() apply; void delegate() revert; }
void buildGestureHooks() {
    GestureHooks h;
    h.revert = () {
        run = runStart;
    };
    scaleSub.wrapperFieldRevertHook = gh.revert;
    merged.setHooks(lh.apply, fh.revert);
}
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 0, format("a gesture-hook FIELD named `revert` scanned as "
        ~ "%d call site(s) — a census that reddens on correct code is the same "
        ~ "defect as one that cannot redden: %s", s.length, s));
}

/// `.revertImpl` is a different method and must not be swallowed by the
/// identifier-boundary check.
unittest {
    enum string probe = q"PROBE
bool f(Command cmd) { return cmd.revertImpl(); }
PROBE";
    auto s = scanRevertSites("probe.d", probe);
    assert(s.length == 0, format("`revertImpl` scanned as a `revert` site: %s", s));
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
// THE RECORDED TABLE — seven rows, one per production `.revert()` site.
//
// Task 3694 changed exactly four logical rows in `undo()` while preserving its
// one enclosing `beginDeliveryBatchGlobal()`:
//   REMOVED — ToolLifecycle hard-step call: lifecycle is no longer classified
//             or reverted on a dedicated branch.
//   REMOVED — Case A call: the nearest-Model selector and suffix splice were
//             deleted when UI/Model/lifecycle became one strict-LIFO tail.
//   REMOVED — Case B call: there is no separate fallback after that selector.
//   ADDED   — common-tail call: the popped tail entry is now reverted once,
//             regardless of whether it is UI, Model or lifecycle.
// Every other row below is the pre-3694 classification; no unrelated call
// site changed.
// ---------------------------------------------------------------------------

private static immutable LedgerRow[] kRecorded = [
    LedgerRow("CompositeCommand.revertImpl", 1,
        "CompositeCommand.revertImpl() — foreach_reverse over children_, nests "
      ~ "inside the caller's batch rather than opening its own. TASK 2500 "
      ~ "renamed the enclosing function: `Command.revert` is `final` now and "
      ~ "`revertImpl` is the override point, so the `func` column moved with "
      ~ "it. The call itself did not move and is still inside undo()'s batch."),
    LedgerRow("CommandHistory.undo", 1,
        "undo(), task 3694 common strict-LIFO tail — replaces the retired "
      ~ "ToolLifecycle / Case A / Case B calls and remains inside undo()'s "
      ~ "single beginDeliveryBatchGlobal()"),
    LedgerRow("CommandHistory.fire", 1,
        "fire()'s live-command revert before the re-fire's apply — inside "
      ~ "fire()'s own beginDeliveryBatchGlobal() at :1507"),
    LedgerRow("CopilotCycleFindingCommand.revertImpl", 1,
        "delegates to the inner select-only command's revert()"),
    LedgerRow("CopilotSelectFindingCommand.revertImpl", 1,
        "delegates to inner.revert(), then restores the panel's active row"),
    LedgerRow("Ai3dGenerate.revertImpl", 1,
        "delegates to importer.revert()"),
    LedgerRow("ImageRemove.revertImpl", 1,
        "delegates to inner_.revert()"),
];

static assert(kRecorded.length == 7,
    "the recorded table must have exactly seven rows — task 3694 collapsed "
  ~ "undo()'s three branches to one common-tail call; if the tree has grown "
  ~ "or shrunk this set, the count changes together with the rows");

// ---------------------------------------------------------------------------
// NOT-A-`Command.revert()` EXCLUSIONS. The scanner is a textual `.revert()`
// match with no type information, so it also finds `.revert()` calls on
// types that are not `Command` at all. There is exactly one such site in the
// tree today, and the card names it explicitly so it is not mistaken for a
// eighth Command-revert site: `xfrm_transform.d:4426` calls `gh.revert()` on
// a `GestureHook` (built by `buildGestureHooks`, `:4376`) from inside the
// REVERT closure `commitEdit` composes for `setCmdHooks` — that closure runs
// later, when the `Command` this commit builds is itself reverted, so this
// line is a HOOK BODY, not a call this test's seven-row table is about.
// Excluded by (file, function) like everything else, so a second, unrelated
// `.revert()` added to the SAME function would still be counted and would
// still redden the gate (proven by the probe cell below).
// ---------------------------------------------------------------------------
private struct ExcludedRow { string symbol; string why; }

private static immutable ExcludedRow[] kNotCommandRevert = [
    ExcludedRow("XfrmTransformTool.commitEdit",
        "`gh.revert()` on a `GestureHook`, not on a `Command` — a hook body "
      ~ "composed for `setCmdHooks`, not a call this census's batches govern"),
];

/// Subtract exactly ONE occurrence per excluded row, not the whole key — a
/// second, unrelated `.revert()` landing in the same (file, function) must
/// still show up as unaccounted afterwards. Split out from the gate so the
/// probe cell below can exercise it on a synthetic map instead of the tree.
private size_t[string] applyExclusions(size_t[string] found, const ExcludedRow[] exclusions) {
    foreach (ref ex; exclusions) {
        const size_t cur = found.get(ex.symbol, 0);
        assert(cur > 0, format(
            "excluded (file, function) pair %s :: %s has ZERO scanned "
          ~ "occurrences — the exclusion is now stale (the excluded call "
          ~ "moved or was deleted). Delete this exclusion row rather than "
          ~ "let it silently cover for a future, unrelated site.",
            "(any file)", ex.symbol));
        if (cur <= 1) found.remove(ex.symbol); else found[ex.symbol] = cur - 1;
    }
    return found;
}

/// The exclusion must not swallow a second, unrelated site at the same
/// (file, function) pair — proven on a synthetic map before trusting it on
/// the tree.
unittest {
    static immutable ExcludedRow[] ex = [ExcludedRow("fn", "test-only")];

    size_t[string] one = ["fn": 1];
    assert(applyExclusions(one, ex).length == 0,
        "the sole excluded occurrence must be fully removed");

    size_t[string] two = ["fn": 2];
    auto after = applyExclusions(two, ex);
    assert(after.get("fn", 0) == 1,
        "a second, unexcluded occurrence at the same key must SURVIVE the "
      ~ "exclusion, not be swallowed by it");
}

// ---------------------------------------------------------------------------
// THE GATE.
// ---------------------------------------------------------------------------
unittest {
    const scanned = scanTree();

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
        found[s.symbol] = found.get(s.symbol, 0) + 1;
    }
    found = applyExclusions(found, kNotCommandRevert);

    LedgerHit[] hits;
    foreach (ref s; scanned.sites)
        if (!s.hasArg && s.symbol in found)
            hits ~= LedgerHit(s.symbol, s.file, s.line, s.text);
    // The one hook exclusion was removed from `found`; mirror that subtraction
    // in the diagnostic hit stream before reconciliation.
    foreach (i, ref s; scanned.sites)
        if (!s.hasArg && s.symbol == kNotCommandRevert[0].symbol)
            foreach_reverse (j; 0 .. hits.length)
                if (hits[j].key == s.symbol) { hits = hits[0 .. j] ~ hits[j + 1 .. $]; break; }
    const bad = reconcile(kRecorded, hits);

    assert(bad.length == 0, format(
        "task 1932: the production `.revert()` call-site SET no longer "
      ~ "matches the recorded seven-row table.%s\n\n"
      ~ "  A `.revert()` call is not wrong by itself — all seven recorded "
      ~ "sites are safe because `Command.apply`, `CommandHistory.undo()`, "
      ~ "`.redo()` and `.fire()` each hold `beginDeliveryBatchGlobal()` "
      ~ "around every revert they drive. What is wrong is an UNACCOUNTED "
      ~ "site: either it already lives inside one of those four batches (in "
      ~ "which case add its row here), or it does not (in which case it "
      ~ "needs a batch of its own before it can be safe, same as the other "
      ~ "seven got).\n\n"
      ~ "  Recorded: %d site(s). Scanner: %d no-argument sites.",
        bad, kRecorded.length, hits.length));
    assert(hits.length == 7,
        format("expected exactly 7 Command.revert sites, found %d", hits.length));

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

private static immutable LedgerRow[] kUndoImage = [
    LedgerRow("MeshAddPoint.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshArray.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshAxisSlice.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshAxisSlice.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshJulienne.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshJulienne.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshBevel.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshBevel.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshBridge.settle", 1, "recorded undo-image revert"),
    LedgerRow("MeshBridge.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshCleanup.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshClone.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshCollapse.accept", 1, "recorded undo-image revert"),
    LedgerRow("MeshCollapse.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshCut.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshCut.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshDelete.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshDetriangulate.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshDuplicate.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("EdgeCreaseSet.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("runCreaseWrites", 1, "recorded undo-image revert"),
    LedgerRow("EdgeCreaseClear.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshEdgeJoin.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshEdgeJoin.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshEdgeSlice.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshEdgeSlice.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshEdgeSlide.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshFaceExtrude.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshFaceExtrude.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshFixOrientation.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshFlip.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshJitter.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshLinearAlign.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshAddLoop.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshAddLoop.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshLoopSlice.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshLoopSlice.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshMagnet.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshMakePolygon.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshMergeFaces.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshMergeFaces.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshMirror.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphCreate.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphRemove.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphRename.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphSet.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphClear.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MorphApplyCmd.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshPolygonInset.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshPolygonInset.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshAlign.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("RecordedUndo", 1, "recorded undo-image revert"),
    LedgerRow("MeshQuadruple.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshQuantize.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshRadialAlign.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshRadialArray.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshReduce.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshReduce.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshRemove.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshScreenSlice.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshScreenSlice.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSessionEdit.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSmooth.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSmoothShift.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshSmoothShift.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSpikey.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSpinEdge.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSplitEdge.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSplitFace.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshStrokeExtrude.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshStrokeExtrude.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSweep.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSymmetrize.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshThicken.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshTransform.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshTriple.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshUnify.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvDelete.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvRename.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvCopy.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvClear.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvFit.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvPack.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvProject.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvRelax.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvFlip.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvMirror.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvRotate.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("UvUnwrap.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertJoin.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertJoin.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertMerge.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertexBevel.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshCenterVertices.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertexExtrude.evaluate", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertexExtrude.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertexNew.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshSetPosition.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshVertexSplit.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("WeightmapCreate.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("WeightmapRemove.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("WeightmapRename.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("WeightmapSet.revertImpl", 1, "recorded undo-image revert"),
    LedgerRow("MeshWeldVertexPair.revertImpl", 1, "recorded undo-image revert"),
];

/// The EXACT total, not a floor. A threshold would stay green over a file
/// that stopped reverting for an unrelated reason while another gained a site.
private enum size_t kUndoImageTotal = 104;

static assert(kUndoImage.length == 104,
    "the undo-image roster must hold exactly 104 owning symbols. It was 48 files / 71 "
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

    size_t total = 0;
    LedgerHit[] hits;
    foreach (ref s; scanned.sites) {
        if (!s.hasArg) continue;
        ++total;
        assert(canFind(kUndoImageReceivers, s.recv), format(
            "%s:%d — `%s.revert(...)` takes an argument and `%s` is not one of "
          ~ "the recorded undo-image receivers %s. Either a new undo image was "
          ~ "introduced (add its spelling, with what type it is), or a "
          ~ "`Command`-typed receiver has grown an argument, which would slip "
          ~ "past gate 1 and land here on purpose.",
            s.file, s.line, s.recv, s.recv, kUndoImageReceivers));
        hits ~= LedgerHit(s.symbol, s.file, s.line, s.text);
    }

    const bad = reconcile(kUndoImage, hits);

    assert(bad.length == 0, format(
        "task 1903 stage N-d: the argument-bearing `.revert(` site set no "
      ~ "longer matches the 104-symbol roster.%s\n\n"
      ~ "  These are undo IMAGES — `MeshEditDelta.revert(*mesh)` and "
      ~ "`RecordedUndo.revert(*mesh)` — not `Command.revert()`, which gate 1 "
      ~ "above owns. A new one is not wrong; it is UNACCOUNTED, and declaring "
      ~ "it here is what §S-8 item 1 of the seam plan asked every migration "
      ~ "commit to do and what no migration could do while the scanner "
      ~ "matched only the empty-paren spelling.\n\n"
      ~ "  Roster: %d site(s) over %d symbols. Scanner: %d.",
        bad, kUndoImageTotal, kUndoImage.length, total));

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

}
