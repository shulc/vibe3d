// census_symbols — ONE census scanner, and a ledger keyed by the SYMBOL a
// site sits in rather than by the PATH of the file that happens to hold it
// (task 4056).
//
// ===========================================================================
// THE DEFECT THIS REPLACES
// ===========================================================================
// The censuses in this package each encode a real measured law as a table of
// rows shaped `("source/<file>.d", <literal count>)`. Because the KEY is a
// file path, the table is a function of where code LIVES and not of what the
// code DOES: `git mv` a function from one module to another without touching
// one character of its body and N censuses go red, each demanding an edit
// that carries no information. 360 such rows stood over 22 files when this
// module was written (`cat tests/unit/*census*.d | grep -cE '"source/[^"]+
// \.d"'`), and moving code between files is precisely what the audit-4 §6
// plan, task 4051 and task 4064 consist of. A gate whose red means "someone
// reorganised a directory" trains people to bump numbers, and a number people
// bump on reflex is the same thing as no gate.
//
// The key here is the enclosing DECLARATION PATH — `Mesh.publishConfinedChange`,
// `XfrmApplyImpl.applyFold`, `SubpatchPreview.rebuildIfStale` — which is what
// each of these laws is actually about. It survives a move between files and,
// in the one direction that matters more, it reddens on something the
// path-keyed table could never see: a call that migrates from one function to
// another INSIDE the same file.
//
// ===========================================================================
// WHAT IS NOT WEAKENED, AND THE ONE HOLE THAT IS CLOSED BY HAND
// ===========================================================================
// Dropping the module from the key opens exactly one narrow hole: a call
// deleted from a recorded `applyFold` and added, in the same commit, to a
// DIFFERENT module's function that also happens to be called `applyFold`
// would net to the same count. That hole is closed by the AMBIGUITY finding
// in `reconcile` below — a recorded symbol seen in more than one file is a
// finding in its own right, so the two homonyms cannot merge silently. A pure
// move still keeps the symbol in exactly one file and stays green, which is
// the whole point.
//
// ===========================================================================
// WHY A HAND-ROLLED SCOPE WALKER AND NOT A PARSE
// ===========================================================================
// Same reason the strippers below are hand-rolled: a census that needs a D
// front end is a census nobody can run inside `dub test`. The walker is
// deliberately conservative — anything it cannot name is ANONYMOUS and
// contributes nothing to the path, so an unrecognised construct degrades the
// key towards the enclosing aggregate instead of inventing a name. Every
// shape it is claimed to handle has a cell at the bottom of this file, and
// the NESTED-AGGREGATE cell is there because the first draft of a walker like
// this reported a member `C.run` as bare `C` — a bug that is invisible in a
// flat module and turns two distinct symbols into one the moment anything is
// nested.
module tests.unit.census_symbols;

import std.algorithm : canFind;
import std.array     : appender, join;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, strip;

package bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

// ---------------------------------------------------------------------------
// Blank comments and/or literals IN PLACE — same length, same line breaks, so a
// finding still reports the real line number. `keepComments` selects the MARKER
// view (comments kept, literals blanked) over the CODE view (both blanked);
// either way the walker still RECOGNISES comments, so a quote mark inside one
// can never open a literal.
//
// HANDLED SINCE TASK 2007: wysiwyg (`r"…"`) and delimited/token strings
// (`q"…"`, `q{…}`). This block used to claim "neither unhandled form appears in
// a scanned file today" and rest the whole no-parser argument on that. HALF of
// it was false, and the false half was the one that matters — MEASURED
// 2026-08-28 over `source/**` with an identifier-boundary test, which is what
// the original claim lacked:
//
//   * `q{…}` — REAL, and in THREE files: `source/gpu_select.d`,
//     `source/shader.d`, `source/subpatch_osd.d` (GLSL sources). `gpu_select.d`
//     is itself a `kRemainder` file, so the desync risk sat directly under a
//     recorded site.
//   * `q"…"` — ZERO occurrences. (A naive `grep q"` reports three, all of them
//     the two characters `q"` INSIDE an ordinary literal: `entry["seq"]`,
//     `` `{"seq":` ``. The card that raised this item counted that grep.)
//   * `r"…"` — ZERO occurrences as a LITERAL. The naive `grep r"` reports 166
//     files and the boundary-aware one still reports four, and all four are
//     `…"r"…` / `'\r'` inside ordinary literals — `File(path, "r")`,
//     `enabled["r"]`, `"\\r"`, `,"r":%d`. So the ORIGINAL claim happened to be
//     true for these two forms and false for the third.
//
// Both are lexed now rather than argued about, because "no such literal in the
// tree today" is a claim that decays silently with every commit, and the one
// that decayed took the argument down with it. Character literals ARE handled,
// including `'\''` and `'"'`. The floor at the bottom still notices a desync
// from any form nobody has thought of, because a desynced scanner eats the rest
// of the file and the site count collapses.
// ---------------------------------------------------------------------------
package string blankNonCode(string src, bool keepComments = false) {
    auto outBuf = new char[src.length];
    foreach (i, c; src) outBuf[i] = (c == '\n') ? '\n' : ' ';
    size_t codeStart = 0;
    void keep(size_t a, size_t b) {
        foreach (k; a .. b) if (src[k] != '\n') outBuf[k] = src[k];
    }
    // Blank [a, b) by closing the kept run before it and reopening after.
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
        // TOKEN and WYSIWYG strings, before the plain `"` handler — they open
        // on a LETTER, so by the time the walker reaches the quote the prefix
        // is already behind it. See the block comment above for what was
        // measured and why this is not the "no such literal here" claim it
        // replaced.
        if ((src[i] == 'q' || src[i] == 'r')
            && (i == 0 || !isIdentChar(src[i - 1]))
            && i + 1 < src.length) {
            // `r"…"` — wysiwyg, no escape processing at all.
            if (src[i] == 'r' && src[i + 1] == '"') {
                const size_t s = i;
                i += 2;
                while (i < src.length && src[i] != '"') ++i;
                i = (i + 1 <= src.length) ? i + 1 : src.length;
                drop(s, i);
                continue;
            }
            // `q{…}` — token string, braces NEST.
            if (src[i] == 'q' && src[i + 1] == '{') {
                const size_t s = i;
                i += 2;
                int depth = 1;
                while (i < src.length && depth > 0) {
                    if (src[i] == '{') ++depth;
                    else if (src[i] == '}') --depth;
                    ++i;
                }
                drop(s, i);
                continue;
            }
            // `q"…"` — delimited. Bracket forms nest; anything else is the
            // heredoc form, closed by `<ident>"` on its own.
            if (src[i] == 'q' && src[i + 1] == '"') {
                const size_t s = i;
                const char open = (i + 2 < src.length) ? src[i + 2] : '\0';
                char close = '\0';
                switch (open) {
                    case '(': close = ')'; break;
                    case '[': close = ']'; break;
                    case '<': close = '>'; break;
                    case '{': close = '}'; break;
                    default:  break;
                }
                if (close != '\0') {
                    i += 3;
                    int depth = 1;
                    while (i < src.length && depth > 0) {
                        if (src[i] == open) ++depth;
                        else if (src[i] == close) --depth;
                        ++i;
                    }
                    if (i < src.length && src[i] == '"') ++i;
                } else {
                    // q"IDENT\n … \nIDENT"
                    size_t t = i + 2;
                    while (t < src.length && isIdentChar(src[t])) ++t;
                    const string tag = src[i + 2 .. t];
                    i = t;
                    if (tag.length) {
                        const string term = tag ~ "\"";
                        while (i + term.length <= src.length
                               && src[i .. i + term.length] != term) ++i;
                        i = (i + term.length <= src.length)
                            ? i + term.length : src.length;
                    }
                }
                drop(s, i);
                continue;
            }
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

/// Blank the body of every `unittest` block in an already-code-only view.
///
/// `package`, like `blankNonCode` above and for the same reason: the other
/// censuses in this package need the same two views and a second copy of a
/// stripper is a second thing to get wrong.
///
/// `version (unittest)` is NOT such a block and must survive: it holds
/// PRODUCTION seams (mock hooks, test-visible accessors) that a poll can hide
/// in, and there are ~195 of them under `source/`. The two differ by one
/// character of context — the `(` that precedes the keyword — because a real
/// `unittest` block is a DECLARATION and can never be parenthesised. That is
/// the whole test below, and it is a cell (`versionUnittestIsProductionCode`)
/// rather than a comment because the first version of this scanner got it
/// wrong while the header claimed otherwise.
package string blankUnittestBodies(string code) {
    auto buf = code.dup;
    void blankBlock(size_t from) {
        size_t j = from;
        while (j < buf.length && buf[j] != '{') {
            if (buf[j] == ';') return;      // `unittest` used as a name; bail
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
    // True when the keyword at `i` is the `unittest` of `version (unittest)` /
    // `debug (unittest)` — i.e. the nearest non-blank character before it is an
    // open parenthesis.
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

// ===========================================================================
// THE SCOPE WALKER
// ===========================================================================

/// Words that can head a `… { }` block without DECLARING anything. A `(`
/// preceded by one of these is a control-flow or attribute parenthesis, never
/// a parameter list, so the walker keeps looking. `this` and `~this` are
/// deliberately absent: they ARE names.
private immutable string[] kNotAName = [
    "if", "else", "for", "foreach", "foreach_reverse", "while", "do",
    "switch", "with", "try", "catch", "finally", "scope", "synchronized",
    "version", "debug", "static", "return", "assert", "cast", "in", "out",
    "body", "invariant", "mixin", "typeof", "is", "new", "throw", "case",
    "default", "asm", "delete", "__traits", "pragma", "align", "extern",
    "deprecated", "unittest", "enum", "struct", "class", "union",
    "interface", "template", "immutable", "const", "shared", "inout",
    "ref", "auto", "alias", "import", "module", "typeid", "super",
    "lazy", "final", "abstract", "override", "nothrow", "pure", "function",
    "delegate", "public", "private", "protected", "package", "export",
];

private bool isNotAName(string s) {
    foreach (k; kNotAName) if (k == s) return true;
    return false;
}

/// The aggregate keywords that name what they open. `enum` is here for
/// `enum E : int { … }`; `enum X = 3;` never reaches a brace, and an
/// anonymous `enum { … }` / `union { … }` has no identifier after the
/// keyword and so falls through to ANONYMOUS, which is the right answer.
private immutable string[] kAggregate =
    ["struct", "class", "union", "interface", "template", "enum"];

/// The name a declarator opens, or `""` for a block that declares nothing.
///
/// `d` is the CODE text between the previous `;` / `{` / `}` and the `{` this
/// call is naming. Everything the walker cannot recognise is ANONYMOUS on
/// purpose: an unknown construct then degrades the path towards its enclosing
/// aggregate instead of inventing a segment.
package string declaratorName(string d)
{
    // --- an aggregate names itself -----------------------------------------
    foreach (k; kAggregate) {
        for (size_t i = 0; i + k.length <= d.length; ++i) {
            if (d[i .. i + k.length] != k) continue;
            if (i > 0 && isIdentChar(d[i - 1])) continue;
            size_t j = i + k.length;
            if (j < d.length && isIdentChar(d[j])) continue;
            while (j < d.length && (d[j] == ' ' || d[j] == '\t'
                                 || d[j] == '\n' || d[j] == '\r')) ++j;
            size_t e = j;
            while (e < d.length && isIdentChar(d[e])) ++e;
            if (e > j) return d[j .. e];
        }
    }

    // --- otherwise the identifier in front of the parameter list ------------
    int depth = 0;
    foreach (i, c; d) {
        if (c == ')') { --depth; continue; }
        if (c != '(') continue;
        const bool topLevel = (depth == 0);
        ++depth;
        if (!topLevel) continue;
        size_t e = i;
        while (e > 0 && (d[e - 1] == ' ' || d[e - 1] == '\t'
                      || d[e - 1] == '\n' || d[e - 1] == '\r')) --e;
        size_t s = e;
        while (s > 0 && isIdentChar(d[s - 1])) --s;
        if (s == e) continue;                       // `(x) { … }` — a lambda
        const string ident = d[s .. e];
        if (isNotAName(ident)) continue;            // `if (…) { … }`
        if (s > 0 && d[s - 1] == '~') return "~" ~ ident;
        return ident;
    }
    return "";
}

/// The enclosing declaration path at the START of every line of a CODE view,
/// indexed the way `splitLines()` indexes: `[0]` is line 1.
///
/// START OF LINE, not the exact column: a hit on `void f() { g(); }` is
/// attributed to whatever encloses `f`, not to `f`. That is a real limit and
/// it is pinned by a cell below rather than left to be discovered — the shape
/// exists in this tree (`Scope cur() { return …; }`) and a census whose
/// scanned identifier could appear inside a one-line body has to say so.
///
/// `code` must already be a code view (`blankUnittestBodies(blankNonCode(src))`
/// or at least `blankNonCode(src)`): a brace inside a comment or a string
/// literal would otherwise unbalance the stack for the rest of the file.
package string[] enclosingSymbols(string code)
{
    string[] names;
    auto out_ = appender!(string[]);

    string pathNow() {
        auto a = appender!string;
        foreach (n; names) {
            if (n.length == 0) continue;
            if (a.data.length) a.put(".");
            a.put(n);
        }
        return a.data;
    }

    out_.put(pathNow());
    size_t declFrom = 0;
    foreach (i, c; code) {
        switch (c) {
            case '{':
                names ~= declaratorName(code[declFrom .. i]);
                declFrom = i + 1;
                break;
            case '}':
                if (names.length) names = names[0 .. $ - 1];
                declFrom = i + 1;
                break;
            case ';':
                declFrom = i + 1;
                break;
            case '\n':
                out_.put(pathNow());
                break;
            default: break;
        }
    }
    // One final entry, so `[$ - 1]` means "the path after the last character"
    // whether or not the file ends in a newline.
    // `source/commands/select/connect.d` ends `};` with NO trailing newline,
    // and without this the balance cell below would read the last LINE's path
    // — still inside the class — and report a desync that is not there. It
    // reported exactly that, once.
    out_.put(pathNow());
    return out_.data;
}

/// `syms[li]` with a bound check, rendered for a message: module scope is a
/// real answer and must not print as an empty string.
package string symbolAt(const string[] syms, size_t li0) {
    const string s = li0 < syms.length ? syms[li0] : "";
    return s.length ? s : "(module scope)";
}

// ===========================================================================
// THE LEDGER
// ===========================================================================

/// One recorded row. `key` is the enclosing declaration path, optionally with
/// a discriminator appended after `|` (the identifier counted, the statement
/// text, …) — whatever the census needs to say WHICH occurrence it means.
/// There is no file path in it, and that is the point.
package struct LedgerRow {
    string key;
    size_t count;
    string why;
}

/// One occurrence the scanner found. `file` and `line` are DIAGNOSTIC ONLY:
/// they are printed so a human can go and look, and they are never compared,
/// so moving the file cannot move the verdict.
package struct LedgerHit {
    string key;
    string file;
    size_t line;
    string text;
}

/// Compare the found multiset against the recorded one. Returns `""` when
/// they agree, and otherwise a block of findings, one paragraph each.
///
/// FOUR findings, and the fourth is what keeps the module out of the key:
///   1. a recorded key whose count changed (a vanished key is this with 0);
///   2. a key found that nobody recorded;
///   3. a recorded key with no occurrences at all, called out in its own
///      words because "recorded 2, found 0" reads like a scanner fault;
///   4. AMBIGUITY — one key realised in more than one FILE. A pure move keeps
///      a symbol in exactly one file, so this never fires on the thing this
///      module exists to allow; what it catches is the one shape a
///      module-free key would otherwise miss, namely an occurrence deleted
///      from a recorded `f` and added to a different module's `f` in the same
///      commit, netting to the recorded count.
package string reconcile(const LedgerRow[] rows, const LedgerHit[] hits)
{
    size_t[string] found;
    foreach (ref h; hits) found[h.key] = found.get(h.key, 0) + 1;

    auto bad = appender!string;

    void dump(string key) {
        foreach (ref h; hits)
            if (h.key == key)
                bad.put(format("\n        found  %s:%d  %s", h.file, h.line, h.text));
    }

    foreach (ref r; rows) {
        const size_t n = found.get(r.key, 0);
        if (n == r.count) continue;
        if (n == 0)
            bad.put(format("\n    %s — recorded %d occurrence(s), the scanner "
                         ~ "found NONE. Either the symbol was renamed (move the "
                         ~ "row with it) or the sites are gone (drop the row).\n"
                         ~ "        recorded as: %s", r.key, r.count, r.why));
        else
            bad.put(format("\n    %s — recorded %d, scanner found %d\n"
                         ~ "        recorded as: %s", r.key, r.count, n, r.why));
        dump(r.key);
    }

    foreach (key, n; found) {
        bool recorded = false;
        foreach (ref r; rows) if (r.key == key) { recorded = true; break; }
        if (recorded) continue;
        bad.put(format("\n    %s — NOT RECORDED AT ALL, scanner found %d "
                     ~ "occurrence(s)", key, n));
        dump(key);
    }

    foreach (key, n; found) {
        string[] files;
        foreach (ref h; hits)
            if (h.key == key && !files.canFind(h.file)) files ~= h.file;
        if (files.length < 2) continue;
        bad.put(format("\n    %s — AMBIGUOUS: this one symbol is realised in "
                     ~ "%d different files (%s). The ledger is keyed by symbol "
                     ~ "and cannot tell them apart, so a site deleted from one "
                     ~ "and added to the other would net to the recorded "
                     ~ "count. Rename one of them, or nest it so the paths "
                     ~ "differ.", key, files.length, files.join(", ")));
        dump(key);
    }
    return bad.data;
}

// ===========================================================================
// SCANNER CELLS. druntime stops a module at its first failed assert, so a
// broken walker has to say so in its own words rather than surface as a
// strange verdict in one of the three censuses that key on it. Ordered
// cheapest-first, and the tree-wide balance cell last.
// ===========================================================================

private string[] symsOf(string probe) {
    return enclosingSymbols(blankUnittestBodies(blankNonCode(probe)));
}

/// A MEMBER OF A NESTED AGGREGATE KEEPS BOTH SEGMENTS. This cell exists
/// because the first walker written for this task reported `C.run` as bare
/// `C`: the bug is invisible in a flat module, and it silently merges every
/// member of an aggregate into one ledger key — which would make the three
/// converted censuses weaker than the path-keyed tables they replace, in the
/// exact direction nobody would look.
unittest {
    enum string probe = q"PROBE
struct C {
    void run() {
        mesh.publishConfinedChange(MeshEditScope.Position);
    }
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 0) == "(module scope)", symbolAt(s, 0));
    assert(symbolAt(s, 1) == "C", symbolAt(s, 1));
    assert(symbolAt(s, 2) == "C.run", format(
        "a member of a nested aggregate must keep BOTH segments — got `%s` "
      ~ "instead of `C.run`. A walker that drops the member name collapses "
      ~ "every method of an aggregate into one ledger key.", symbolAt(s, 2)));
    // The path is the one in force at the START of the line, so line 4 —
    // `C`'s own closing brace — is still inside `C`, and only line 5 is back
    // at module scope. Both are asserted because an off-by-one here would
    // shift every key in a converted ledger by one scope.
    assert(symbolAt(s, 3) == "C.run", symbolAt(s, 3));
    assert(symbolAt(s, 4) == "C", symbolAt(s, 4));
    assert(symbolAt(s, 5) == "(module scope)", symbolAt(s, 5));
}

/// …and it nests arbitrarily deep, through a class, a struct, a method and a
/// nested function — four segments, none of them optional.
unittest {
    enum string probe = q"PROBE
class Outer {
    struct Inner {
        void go() {
            void helper() {
                hit();
            }
        }
    }
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 4) == "Outer.Inner.go.helper", symbolAt(s, 4));
    assert(symbolAt(s, 2) == "Outer.Inner", symbolAt(s, 2));
}

/// Control flow declares nothing, so it contributes no segment. Without this
/// the key of a site inside a loop would depend on how many `if`s happen to
/// wrap it — i.e. on formatting, which is worse than depending on a path.
unittest {
    enum string probe = q"PROBE
void f() {
    if (x) {
        foreach (a; b) {
            version (unittest) {
                scope (exit) {
                    hit();
                }
            }
        }
    }
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 5) == "f", format(
        "control-flow heads must contribute nothing; got `%s`", symbolAt(s, 5)));
}

/// An ATTRIBUTE parenthesis is not a parameter list. `extern(C)` and
/// `pragma(inline, true)` both put a `(` in front of the function's own, and
/// a walker that took the first `(` it saw would name these `extern` and
/// `pragma`.
unittest {
    enum string probe = q"PROBE
extern(C) void cb() {
    hit();
}
pragma(inline, true) void inl() {
    hit();
}
@safe pure nothrow void attrs()
{
    hit();
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 1) == "cb",    symbolAt(s, 1));
    assert(symbolAt(s, 4) == "inl",   symbolAt(s, 4));
    assert(symbolAt(s, 8) == "attrs", symbolAt(s, 8));
}

/// A lambda is anonymous — and the ONE-LINE BODY LIMIT, stated as a cell
/// rather than as a comment. A line's key is the path at its START, so a hit
/// inside `int cur() { return hit(); }` belongs to whatever encloses `cur`.
/// This shape is real in this tree; pinning it here means a census whose
/// scanned identifier could land in one has to say so instead of finding out.
unittest {
    enum string probe = q"PROBE
void owner() {
    arr.each!((a) {
        hit();
    });
}
int cur() { return hit(); }
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 2) == "owner", format(
        "a lambda declares nothing and must add no segment; got `%s`",
        symbolAt(s, 2)));
    assert(symbolAt(s, 5) == "(module scope)", format(
        "THE DOCUMENTED LIMIT: a one-line body is attributed to its enclosing "
      ~ "scope, because a line's key is the path at its START. Got `%s`.",
        symbolAt(s, 5)));
}

/// A blanked `unittest` body leaves the keyword behind and takes its braces
/// with it. Both halves matter: the declarations AFTER it must still be named
/// correctly (the braces balanced), and a line inside the blanked body must
/// report module scope rather than a plausible-looking symbol.
unittest {
    enum string probe = q"PROBE
unittest {
    hit();
}
struct After {
    void m() {
        hit();
    }
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 1) == "(module scope)", format(
        "a blanked unittest body must not manufacture a symbol; got `%s`",
        symbolAt(s, 1)));
    assert(symbolAt(s, 5) == "After.m", format(
        "a blanked unittest body must leave the brace stack balanced, so the "
      ~ "next declaration is still named — got `%s`", symbolAt(s, 5)));
}

/// Braces inside a comment or a string literal are not braces. This is why
/// the walker's input is a CODE VIEW and the two are one function apart.
unittest {
    enum string probe = q"PROBE
// { { {
void f() {
    auto s = "}}}";
    hit();
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 3) == "f", symbolAt(s, 3));
    assert(symbolAt(s, 5) == "(module scope)", symbolAt(s, 5));
}

/// Constructors and destructors are names, not keywords, and the `~` belongs
/// to the name — `S.this` and `S.~this` are two different symbols.
unittest {
    enum string probe = q"PROBE
struct S {
    this(int x) {
        hit();
    }
    ~this() {
        hit();
    }
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 2) == "S.this",  symbolAt(s, 2));
    assert(symbolAt(s, 5) == "S.~this", symbolAt(s, 5));
}

/// Aggregates that name themselves through a base list, a template parameter
/// list or an enum base — and the anonymous forms, which must stay anonymous
/// rather than borrow the next identifier they see.
unittest {
    enum string probe = q"PROBE
class Derived : Base, IFace {
    hit();
}
template Tmpl(string name) {
    hit();
}
enum Kind : int {
    hit
}
union {
    hit();
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 1) == "Derived", symbolAt(s, 1));
    assert(symbolAt(s, 4) == "Tmpl",    symbolAt(s, 4));
    assert(symbolAt(s, 7) == "Kind",    symbolAt(s, 7));
    assert(symbolAt(s, 10) == "(module scope)", format(
        "an anonymous union must stay anonymous; got `%s`", symbolAt(s, 10)));
}

// ---------------------------------------------------------------------------
// THE LEDGER ENGINE'S OWN CELLS — every branch of `reconcile`, in both
// directions. A reconciler that never returns a finding is the vacuity defect
// with extra steps.
// ---------------------------------------------------------------------------
unittest {
    static immutable LedgerRow[] rows = [
        LedgerRow("Mesh.publishConfinedChange", 1, "the declaration"),
        LedgerRow("XfrmApplyImpl.applyFold",    1, "the applyFold tail"),
    ];

    // GREEN FIRST, so the reddening cells below are read against a baseline
    // that is known to agree.
    LedgerHit[] exact = [
        LedgerHit("Mesh.publishConfinedChange", "source/mesh.d", 10, "x"),
        LedgerHit("XfrmApplyImpl.applyFold", "source/tools/x.d", 20, "y"),
    ];
    assert(reconcile(rows, exact) == "", reconcile(rows, exact));

    // …and the SAME hits with the files swapped are still green: that is the
    // whole task. Nothing in the verdict may read a path.
    LedgerHit[] moved = [
        LedgerHit("Mesh.publishConfinedChange", "source/mesh_core.d", 3, "x"),
        LedgerHit("XfrmApplyImpl.applyFold", "source/tools/other.d", 4, "y"),
    ];
    assert(reconcile(rows, moved) == "", reconcile(rows, moved));

    // 1. a count that changed
    auto twice = exact ~ LedgerHit("XfrmApplyImpl.applyFold",
                                   "source/tools/x.d", 21, "y2");
    assert(reconcile(rows, twice).canFind("recorded 1, scanner found 2"),
           reconcile(rows, twice));

    // 2. a key nobody recorded
    auto stranger = exact ~ LedgerHit("SomeTool.doThing",
                                       "source/tools/new.d", 5, "z");
    assert(reconcile(rows, stranger).canFind("NOT RECORDED AT ALL"),
           reconcile(rows, stranger));

    // 3. a recorded key with nothing left
    assert(reconcile(rows, exact[0 .. 1]).canFind("found NONE"),
           reconcile(rows, exact[0 .. 1]));

    // 4. AMBIGUITY — one symbol in two files, netting to the recorded count.
    //    Without this branch the module-free key would let a site migrate
    //    between two homonymous functions unseen.
    LedgerHit[] split = [
        LedgerHit("Mesh.publishConfinedChange", "source/mesh.d", 10, "x"),
        LedgerHit("XfrmApplyImpl.applyFold", "source/tools/a.d", 20, "y"),
        LedgerHit("XfrmApplyImpl.applyFold", "source/tools/b.d", 30, "y"),
    ];
    static immutable LedgerRow[] rows2 = [
        LedgerRow("Mesh.publishConfinedChange", 1, "the declaration"),
        LedgerRow("XfrmApplyImpl.applyFold",    2, "two tails"),
    ];
    assert(reconcile(rows2, split).canFind("AMBIGUOUS"),
           reconcile(rows2, split));
}

// ---------------------------------------------------------------------------
// THE WALKER AGAINST THE REAL TREE, and the population floor under it.
//
// The probes above show the walker handles the shapes it was DESIGNED for. The
// shape nobody designed for is the dangerous one: an unhandled construct that
// leaves the brace stack unbalanced silently re-parents every symbol after it
// in the file. That failure is invisible from a probe and invisible from a
// count — the ledger would simply reconcile against wrong keys — so it is
// checked where it can actually happen, over every module under `source/`.
//
// The floors are the population guard. "Every file balanced" is VACUOUSLY TRUE
// over zero files, and this cell reaches the tree through a path constant, so
// a wrong root would pass it in silence.
// ---------------------------------------------------------------------------
private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    size_t nFiles = 0, nWithMembers = 0, nLines = 0;
    auto bad = appender!string;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++nFiles;
        auto syms = enclosingSymbols(
            blankUnittestBodies(blankNonCode(readText(de.name))));
        nLines += syms.length;
        if (syms.length && syms[$ - 1].length)
            bad.put(format("\n    %s — the walker ended the file still inside "
                         ~ "`%s`", de.name[repoRoot.length + 1 .. $],
                           syms[$ - 1]));
        foreach (s; syms) if (s.canFind('.')) { ++nWithMembers; break; }
    }

    assert(bad.data.length == 0, format(
        "task 4056: the scope walker did not come out of %d module(s) with an "
      ~ "empty stack.%s\n\n"
      ~ "  An unbalanced walk is not a cosmetic fault: every symbol after the "
      ~ "point of desync is re-parented, so the three symbol-keyed censuses "
      ~ "reconcile their ledgers against keys that do not exist. The cause is "
      ~ "either a literal form `blankNonCode` does not lex (it eats the rest "
      ~ "of the file, braces included) or a construct `declaratorName` has "
      ~ "not been shown. Add the arm and the cell; do not relax this.",
        nFiles, bad.data));

    // POPULATION FLOOR, after the assertion it protects. Measured 2026-09-04
    // (`rdmd` over this same walker): 510 files, 293 539 lines, 432 files
    // carrying at least one dotted symbol, 0 unbalanced. The floors sit below
    // that so ordinary growth and ordinary deletion never touch them.
    assert(nFiles >= 400, format(
        "only %d module(s) under source/ were walked — the tree root is "
      ~ "wrong, or the walk is broken, and 'every file balanced' is then true "
      ~ "over almost nothing.", nFiles));
    assert(nLines >= 200_000, format(
        "only %d line(s) walked over %d file(s) — a stripper that eats files "
      ~ "whole leaves the count above intact and this one collapsed.",
        nLines, nFiles));
    assert(nWithMembers >= 350, format(
        "only %d of %d module(s) produced a DOTTED symbol path. The walker is "
      ~ "naming aggregates but losing their members — which is the `C.run` → "
      ~ "`C` bug the first cell in this file exists for, and it would merge "
      ~ "ledger keys rather than break a build.", nWithMembers, nFiles));
}
