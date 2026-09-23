// tool_model_census_test — every Tool class against the live-edit state model
// (task 7110).
//
// ONE ledger row per tool class records, from the COMPILER and the runtime
// rather than from a regex, which class OWNS each of the four session hooks
// once inheritance is resolved, whether the class carries the two session
// capability interfaces, and a hand classification `live: yes|no` with its
// one-line reason. Beside the rows: per-file counts of the identity key a tool
// ARMS its live edit with (axis 2: aggregate FIELDS of the version-keyed type
// vs the session key) and of every history write spelling in the tool tree
// (axis 3, descriptive). Two violator constants are exact ratchets: growth is
// red, and so is a shrink the ledger has not recorded, so a migration lowers
// the constant in its own commit.
//
// The census answers STRUCTURE only. "Owner of hasUncommittedEdit is Tool"
// means the class does not OVERRIDE the hook; whether an undo keystroke then
// misbehaves is for a behavioural witness to show, never for this table.
//
// Axis 2 reads a field's type head LITERALLY: aliases of the key types are out
// of the scanner's scope, and a separate floor pins their count (and that of
// spelled-out `MeshKey!…MeshTermMutation`) at zero in source/tools.
//
// Order of the checks is part of the contract (a mutation touching several
// facts reddens at the EARLIEST step): (1) instrument floors, (2) population
// floors, (3) violator constants, axis 1 then axis 2, (4) row-by-row ledger
// comparison. On any mismatch the measured ledger is printed whole between
// `--- tool census ledger ---` markers; copy it from there and READ THE DIFF.
// Fast loop: tools/local/ut-standalone.sh tests/unit/tool_model_census_test.d
module tests.unit.tool_model_census_test;

// Pulls every production tool module into the import closure, so the runtime
// population is the same under `dmd -i` (ut-standalone) as in the full gate.
// Floor 5(i) makes any divergence loud: a class that falls out of the closure
// reddens as `ledger row … has no linked class`.
import edit_tool_registration;

import command_history : CommandHistory;
import edit_session    : KeepAliveOnCancel, SessionStepUndo;
import tool            : Tool;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   isIdentChar;

import std.algorithm : canFind, endsWith, sort, startsWith;
import std.array     : appender, array, join, split;
import std.conv      : to;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.stdio     : writeln;
import std.string    : indexOf, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum ledgerPath = "tests/unit/tool_model_census_ledger.txt";
private enum size_t[2] kNoKeys = [0, 0];

// ---------------------------------------------------------------------------
// Constants of the instrument.
// ---------------------------------------------------------------------------

/// The four virtual live-edit hooks of `Tool`. Their vtbl slots are asked of
/// the compiler, never counted.
private enum string[] kHooks = [
    "hasUncommittedEdit", "cancelUncommittedEdit", "resyncSession",
    "commitUncommittedEdit",
];
private enum string[] kHookKeys = ["has", "cancel", "resync", "commit"];

/// Module fixtures under `version (unittest)` in `source/` that the runtime
/// links. Named, not filtered by prefix: `tests/unit` module names do not all
/// start with `tests.`, so membership in the SOURCE module set is the filter
/// and these four are the only remaining non-tools.
private enum string[] kNamedExceptions = [
    "registry._TypedFactoryTool", "registry._RegParamTool",
    "registry._RegFreeTool", "tool.RecordingTool",
];

/// Public `CommandHistory` methods seen by the census build (which is always a
/// `-unittest` build, so the test-only `pushEntryForTest` is one of them).
/// A new method reddens until the axis-3 needles are reviewed.
private enum size_t kHistorySurface = 62;

/// Tool-side history wrappers, counted as identifier tokens (every spelling:
/// call, declaration, address-of).
private enum string[] kWriteWrappers = [
    "recordGestureEdit", "recordSnapshotUndo", "recordLiveDragEnd",
];

private string[] historySurface() {
    string[] names;
    static foreach (m; __traits(derivedMembers, CommandHistory)) {
        static if (m != "__ctor"
            && __traits(compiles, __traits(getOverloads, CommandHistory, m))
            && __traits(getOverloads, CommandHistory, m).length > 0
            && __traits(getVisibility, __traits(getMember, CommandHistory, m))
                == "public")
            names ~= m;
    }
    return names;
}

// ---------------------------------------------------------------------------
// Positive-control probes. Module-level so `localClasses` lists them; this
// module is not a SOURCE module, so they never enter the population.
// ---------------------------------------------------------------------------
version (unittest) {
    class CensusProbeOwn : Tool, SessionStepUndo {
        override bool hasUncommittedEdit() const { return true; }
        bool tryUndoStepInSession() { return false; }
    }
    final class CensusProbeInherit : CensusProbeOwn {}
    final class CensusProbeBare : Tool {}
    // Reaches SessionStepUndo only through a BASE interface, so the recursive
    // arm of `implementsIface` is the one that answers.
    interface CensusProbeStepChild : SessionStepUndo {}
    final class CensusProbeViaChild : Tool, CensusProbeStepChild {
        bool tryUndoStepInSession() { return false; }
    }
}

// ---------------------------------------------------------------------------
// Runtime resolution.
// ---------------------------------------------------------------------------

private size_t[kHooks.length] hookSlots() {
    size_t[kHooks.length] slots;
    static foreach (k, h; kHooks)
        slots[k] = __traits(getVirtualIndex, __traits(getMember, Tool, h));
    return slots;
}

private void*[kHooks.length] hookBaseImpls() {
    void*[kHooks.length] impls;
    static foreach (k, h; kHooks)
        impls[k] = cast(void*)&__traits(getMember, Tool, h);
    return impls;
}

/// The class that OWNS the implementation `c` dispatches to in `slot`: the
/// most-derived class of the chain whose entry equals `c`'s and whose base's
/// entry does not.
private TypeInfo_Class slotOwner(TypeInfo_Class c, size_t slot) {
    const impl = c.vtbl[slot];
    auto o = c;
    while (o.base !is null && o.base.vtbl.length > slot
           && o.base.vtbl[slot] is impl)
        o = o.base;
    return o;
}

private bool implementsIface(TypeInfo_Class c, TypeInfo_Class iface) {
    for (auto k = c; k !is null; k = k.base)
        foreach (ref i; k.interfaces) {
            if (i.classinfo is iface) return true;
            if (implementsIface(i.classinfo, iface)) return true;
        }
    return false;
}

/// Strictly derived: the walk starts at `c.base`, so `Tool` itself is out.
private bool derivesFromTool(TypeInfo_Class c) {
    for (auto b = c.base; b !is null; b = b.base)
        if (b is typeid(Tool)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Source text.
// ---------------------------------------------------------------------------

private struct SrcFile { string path; string mod; string src; }

/// Every `source/**.d` file with the name from its OWN `module` line (nine
/// modules here declare a name that is not their path).
private SrcFile[] sourceFiles(out size_t withoutModuleLine) {
    SrcFile[] files;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const src = readText(de.name);
        const rel = de.name[repoRoot.length + 1 .. $];
        const mod = moduleName(blankNonCode(src));
        if (mod.length == 0) { ++withoutModuleLine; continue; }
        files ~= SrcFile(rel, mod, src);
    }
    files.sort!((a, b) => a.path < b.path);
    return files;
}

private string moduleName(string code) {
    size_t i = 0;
    while (i < code.length) {
        if (wordAt(code, i, "module")) {
            size_t j = i + 6;
            skipWs(code, j);
            const s = j;
            while (j < code.length && (isIdentChar(code[j]) || code[j] == '.')) ++j;
            skipWs(code, j);
            if (j < code.length && code[j] == ';') return code[s .. j].strip;
            return "";
        }
        if (code[i] != ' ' && code[i] != '\n' && code[i] != '\t' && code[i] != '\r'
            && code[i] != '@' && !isIdentChar(code[i]))
            return "";
        ++i;
    }
    return "";
}

private bool wordAt(string code, size_t i, string w) {
    return i + w.length <= code.length && code[i .. i + w.length] == w
        && (i == 0 || !isIdentChar(code[i - 1]))
        && (i + w.length == code.length || !isIdentChar(code[i + w.length]));
}

private void skipWs(string code, ref size_t j) {
    while (j < code.length && (code[j] == ' ' || code[j] == '\n'
           || code[j] == '\t' || code[j] == '\r')) ++j;
}

private string identAt(string code, size_t j) {
    size_t e = j;
    while (e < code.length && isIdentChar(code[e])) ++e;
    return code[j .. e];
}

/// A declared class: its name, whether it is a template, and the leading
/// identifier of each base (the last dotted segment, before `!` / `(`).
/// `isAbstract`: the word `abstract` appears in the declaration's own head,
/// i.e. between the previous `;` / `{` / `}` and `class`.
private struct ClassDecl { string name; bool isTemplate; bool isAbstract; string[] bases; }

/// Class declarations of a code view that has had `unittest` bodies blanked.
package ClassDecl[] classDecls(string code) {
    ClassDecl[] out_;
    for (size_t i = 0; i < code.length; ++i) {
        if (!wordAt(code, i, "class")) continue;
        size_t j = i + 5;
        skipWs(code, j);
        const name = identAt(code, j);
        if (name.length == 0) continue;
        j += name.length;
        skipWs(code, j);
        ClassDecl d;
        d.name = name;
        {
            size_t b = i;
            while (b > 0 && code[b - 1] != ';' && code[b - 1] != '{' && code[b - 1] != '}') --b;
            for (size_t q = b; q < i; ++q)
                if (wordAt(code, q, "abstract")) d.isAbstract = true;
        }
        if (j < code.length && code[j] == '(') {
            d.isTemplate = true;
            int depth = 0;
            for (; j < code.length; ++j) {
                if (code[j] == '(') ++depth;
                else if (code[j] == ')') { if (--depth == 0) { ++j; break; } }
            }
            skipWs(code, j);
        }
        if (j < code.length && code[j] == ':') {
            ++j;
            // Bases run to the body `{`, the `;`, or a template constraint.
            size_t e = j;
            int depth = 0;
            while (e < code.length) {
                const ch = code[e];
                if (ch == '(' || ch == '[') ++depth;
                else if (ch == ')' || ch == ']') --depth;
                else if (depth == 0 && (ch == '{' || ch == ';')) break;
                else if (depth == 0 && wordAt(code, e, "if")) break;
                ++e;
            }
            foreach (part; splitTop(code[j .. e])) {
                auto p = part.strip;
                size_t k = 0;
                string last;
                while (k < p.length) {
                    const id = identAt(p, k);
                    if (id.length == 0) break;
                    last = id;
                    k += id.length;
                    if (k < p.length && p[k] == '.') { ++k; continue; }
                    break;
                }
                if (last.length) d.bases ~= last;
            }
        }
        out_ ~= d;
        i = j;
    }
    return out_;
}

private string[] splitTop(string s) {
    string[] parts;
    int depth = 0;
    size_t st = 0;
    foreach (k, ch; s) {
        if (ch == '(' || ch == '[') ++depth;
        else if (ch == ')' || ch == ']') --depth;
        else if (ch == ',' && depth == 0) { parts ~= s[st .. k]; st = k + 1; }
    }
    parts ~= s[st .. $];
    return parts;
}

// Words that, alone (with optional parenthesised arguments), head a block
// that is TRANSPARENT: its members belong to the enclosing scope.
private immutable string[] kTransparent = [
    "version", "debug", "else", "private", "public", "protected", "package",
    "export", "extern", "final", "abstract", "shared", "__gshared", "static",
    "deprecated", "align", "nothrow", "pure", "synchronized", "const",
    "immutable", "override",
];
private immutable string[] kAggregateWords =
    ["class", "struct", "union", "interface", "template"];

private enum Scope { moduleLevel, aggregate, other }

private Scope classifyBlock(string decl, Scope parent) {
    const d = decl.strip;
    if (d.length == 0) return parent;              // bare `{ }`
    // Aggregate keyword at paren depth 0.
    int depth = 0;
    for (size_t i = 0; i < d.length; ++i) {
        const ch = d[i];
        if (ch == '(') ++depth;
        else if (ch == ')') --depth;
        else if (depth == 0)
            foreach (w; kAggregateWords)
                if (wordAt(d, i, w)) return Scope.aggregate;
    }
    // Attribute-only / conditional-compilation heads are transparent.
    size_t k = 0;
    bool allAttr = true;
    while (k < d.length) {
        skipWs(d, k);
        if (k >= d.length) break;
        if (d[k] == '@') ++k;
        const id = identAt(d, k);
        if (id.length == 0) { allAttr = false; break; }
        const isStaticIf = (id == "if" || id == "foreach")
            && k > 0 && d[0 .. k].strip.endsWith("static");
        if (!kTransparent.canFind(id) && !isStaticIf && !(k > 0 && d[k - 1] == '@')) {
            allAttr = false;
            break;
        }
        k += id.length;
        skipWs(d, k);
        if (k < d.length && d[k] == '(') {
            int dp = 0;
            for (; k < d.length; ++k) {
                if (d[k] == '(') ++dp;
                else if (d[k] == ')') { if (--dp == 0) { ++k; break; } }
            }
        }
        if (k < d.length && d[k] == ':') ++k;      // `else:` never, `private:`
    }
    if (allAttr) return parent;
    return Scope.other;
}

/// Words skipped in front of a field's type head: protection (also as a label,
/// `private:`), storage classes, and braceless conditional / attribute heads
/// (`version (X) T f;`, `debug T f;`, `else T f;`, `static if (c) T f;`).
private immutable string[] kFieldPrefix = [
    "private", "public", "protected", "package", "export", "static", "const",
    "immutable", "shared", "__gshared", "version", "debug", "else", "extern",
    "deprecated", "align", "final", "abstract", "override", "nothrow", "pure",
    "synchronized",
];
private immutable string[] kTypeCtors = ["const", "immutable", "shared"];

/// Counts of aggregate FIELDS whose type head is `MeshCacheKey` / `SessionMeshKey`.
/// `code` must be `blankUnittestBodies(blankNonCode(src))`.
package size_t[2] keyFieldCounts(string code) {
    size_t[2] n;
    Scope[] stack = [Scope.moduleLevel];
    size_t stmt = 0;
    void judge(string s) {
        size_t k = 0;
        void skipParens() {
            skipWs(s, k);
            if (k >= s.length || s[k] != '(') return;
            int dp = 0;
            for (; k < s.length; ++k) {
                if (s[k] == '(') ++dp;
                else if (s[k] == ')') { if (--dp == 0) { ++k; break; } }
            }
        }
        while (true) {
            skipWs(s, k);
            // `@attr` / `@attr(...)`: an attribute, never the type head.
            if (k < s.length && s[k] == '@') {
                ++k;
                k += identAt(s, k).length;
                skipParens();
                continue;
            }
            const id = identAt(s, k);
            if (id.length == 0) return;
            if (kFieldPrefix.canFind(id)) {
                k += id.length;
                // `const(T)` is a type constructor: step inside, the type
                // head follows and its `)` is skipped with the suffixes.
                skipWs(s, k);
                if (kTypeCtors.canFind(id) && k < s.length && s[k] == '(') { ++k; continue; }
                if (id == "static") {
                    // `static if (...)`: a braceless conditional head.
                    if (wordAt(s, k, "if")) { k += 2; skipParens(); }
                } else skipParens();   // `version (X)`, `extern (C)`, `align (4)`
                skipWs(s, k);
                // A protection / attribute LABEL (`private:`) leaves the
                // declaration after it in the same statement.
                if (k < s.length && s[k] == ':') ++k;
                continue;
            }
            // Qualified type head: take the last dotted segment.
            string head = id;
            k += id.length;
            while (k < s.length && s[k] == '.') {
                ++k;
                head = identAt(s, k);
                k += head.length;
            }
            const which = head == "MeshCacheKey" ? 0
                        : head == "SessionMeshKey" ? 1 : -1;
            if (which < 0) return;
            int bd = 0;
            while (k < s.length && (bd > 0 || s[k] == '[' || s[k] == '*' || s[k] == ')'
                   || s[k] == ' ' || s[k] == '\n' || s[k] == '\t')) {
                if (s[k] == '[') ++bd;
                else if (s[k] == ']') --bd;
                ++k;
            }
            // A field needs a declarator name, and a name followed by `(` is
            // a METHOD returning the key, not a field holding one.
            const nm = identAt(s, k);
            size_t after = k + nm.length;
            skipWs(s, after);
            if (nm.length == 0 || (after < s.length && s[after] == '(')) return;
            n[which] += splitTop(s[k .. $]).length;
            return;
        }
    }
    foreach (i, ch; code) {
        if (ch == '{') {
            stack ~= classifyBlock(code[stmt .. i], stack[$ - 1]);
            stmt = i + 1;
        } else if (ch == '}') {
            if (stack.length > 1) stack = stack[0 .. $ - 1];
            stmt = i + 1;
        } else if (ch == ';') {
            if (stack[$ - 1] == Scope.aggregate) judge(code[stmt .. i]);
            stmt = i + 1;
        }
    }
    return n;
}

/// Spellings of the key types that `keyFieldCounts` does NOT resolve: an
/// `alias` naming `MeshCacheKey` / `SessionMeshKey` (either alias form), and a
/// spelled-out `MeshKey!` instantiation carrying `MeshTermMutation` (which is
/// what `MeshCacheKey` IS, `source/mesh.d`). Aliases are out of the scanner's
/// scope; the census pins this count at zero over `source/tools` instead.
package size_t keySpellingEscapes(string code) {
    size_t n;
    string dottedLast(ref size_t j) {
        string last;
        while (true) {
            skipWs(code, j);
            const id = identAt(code, j);
            if (id.length == 0) return last;
            last = id;
            j += id.length;
            skipWs(code, j);
            if (j < code.length && code[j] == '.') { ++j; continue; }
            return last;
        }
    }
    for (size_t i = 0; i < code.length; ++i) {
        if (wordAt(code, i, "alias")) {
            size_t j = i + 5;
            const first = dottedLast(j);
            string target = first;                       // `alias T name;`
            if (j < code.length && code[j] == '=') {     // `alias name = T;`
                ++j;
                target = dottedLast(j);
            }
            if (target == "MeshCacheKey" || target == "SessionMeshKey") ++n;
        } else if (wordAt(code, i, "MeshKey")) {
            size_t j = i + 7;
            skipWs(code, j);
            if (j >= code.length || code[j] != '!') continue;
            ++j;
            skipWs(code, j);
            size_t e = j;
            if (e < code.length && code[e] == '(') {
                int dp = 0;
                for (; e < code.length; ++e) {
                    if (code[e] == '(') ++dp;
                    else if (code[e] == ')') { if (--dp == 0) { ++e; break; } }
                }
            } else e += identAt(code, e).length;
            for (size_t q = j; q < e; ++q)
                if (wordAt(code, q, "MeshTermMutation")) { ++n; break; }
        }
    }
    return n;
}

/// The three production views, shared by the census and its scanner cells so
/// a cell can never drive a different path than the census does.
private size_t[2] keyCountsOf(string src) {
    return keyFieldCounts(blankUnittestBodies(blankNonCode(src)));
}
private size_t keyEscapesOf(string src) {
    return keySpellingEscapes(blankUnittestBodies(blankNonCode(src)));
}
private ClassDecl[] classDeclsOf(string src) {
    return classDecls(blankUnittestBodies(blankNonCode(src)));
}
private size_t[string] writeCountsOf(string src, const string[] surface) {
    return writeCounts(blankNonCode(src), surface);
}

/// Names declared in `code` with type `CommandHistory` (explicit, or `auto x =
/// new CommandHistory`).
private string[] historyTypedNames(string code) {
    string[] names;
    for (size_t i = 0; i < code.length; ++i) {
        if (!wordAt(code, i, "CommandHistory")) continue;
        size_t j = i + "CommandHistory".length;
        // Explicit: `CommandHistory name` (optionally `*` / `[]`).
        size_t e = j;
        while (e < code.length && (code[e] == '*' || code[e] == '[' || code[e] == ']'
               || code[e] == ' ' || code[e] == '\t' || code[e] == '\n')) ++e;
        const nm = identAt(code, e);
        if (nm.length && e > j) { names ~= nm; continue; }
        // Inferred: `<name> = new CommandHistory`.
        size_t b = i;
        while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t' || code[b - 1] == '\n')) --b;
        if (b >= 3 && code[b - 3 .. b] == "new" && (b == 3 || !isIdentChar(code[b - 4]))) {
            b -= 3;
            while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t' || code[b - 1] == '\n')) --b;
            if (b > 0 && code[b - 1] == '=') {
                --b;
                while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t' || code[b - 1] == '\n')) --b;
                size_t s = b;
                while (s > 0 && isIdentChar(code[s - 1])) --s;
                if (s < b) names ~= code[s .. b];
            }
        }
    }
    return names;
}

private bool isHistoryIdent(string id) {
    return id.indexOf("history") >= 0 || id.indexOf("History") >= 0;
}

/// Axis-3 counts of one file: `receiver.method` pairs (every spelling — call,
/// property read, address-of) and wrapper identifier tokens. `code` is
/// `blankNonCode(src)` (unittest bodies INCLUDED, as the plan's numbers are).
package size_t[string] writeCounts(string code, const string[] surface) {
    size_t[string] counts;
    const typed = historyTypedNames(code);
    for (size_t i = 0; i < code.length; ++i) {
        if (code[i] == '.' && i > 0) {
            size_t b = i;
            while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t' || code[b - 1] == '\n')) --b;
            size_t s = b;
            while (s > 0 && isIdentChar(code[s - 1])) --s;
            if (s == b) continue;
            const recv = code[s .. b];
            if (!isHistoryIdent(recv) && !typed.canFind(recv)) continue;
            size_t j = i + 1;
            skipWs(code, j);
            const m = identAt(code, j);
            if (m.length && surface.canFind(m)) counts[recv ~ "." ~ m] += 1;
        } else if (isIdentChar(code[i]) && (i == 0 || !isIdentChar(code[i - 1]))) {
            const id = identAt(code, i);
            if (kWriteWrappers.canFind(id)) counts[id] += 1;
            i += id.length - 1;
        }
    }
    return counts;
}

/// Comment-stripped `MeshSnapshot(\[\])?\s+ident` declarations — the live proxy.
private size_t snapshotDecls(string code) {
    size_t n;
    for (size_t i = 0; i < code.length; ++i) {
        if (!wordAt(code, i, "MeshSnapshot")) continue;
        size_t j = i + "MeshSnapshot".length;
        if (j + 1 < code.length && code[j] == '[' && code[j + 1] == ']') j += 2;
        const k0 = j;
        skipWs(code, j);
        if (j > k0 && identAt(code, j).length && !isDigitStart(code[j])) ++n;
    }
    return n;
}

private bool isDigitStart(char c) { return c >= '0' && c <= '9'; }

// ---------------------------------------------------------------------------
// Ledger.
// ---------------------------------------------------------------------------

private struct ToolRow {
    string name;
    string[kHooks.length] owners;
    bool step, keep;
    string live;     // "yes" | "no" | "?"
    size_t snap;
    string reason;
}

private struct Ledger {
    size_t axis1 = size_t.max, axis2 = size_t.max;
    ToolRow[string] tools;
    size_t[2][string] keys;       // file -> [mck, smk]
    size_t[string][string] writes; // file -> pair -> count
}

private string yn(bool b) { return b ? "yes" : "no"; }

private string toolLine(const ToolRow r) {
    return format("tool %s has=%s cancel=%s resync=%s commit=%s step=%s keep=%s snap=%s live=%s | %s",
        r.name, r.owners[0], r.owners[1], r.owners[2], r.owners[3],
        yn(r.step), yn(r.keep), r.snap, r.live, r.reason);
}

private Ledger parseLedger(string text) {
    Ledger l;
    foreach (raw; text.split("\n")) {
        const line = raw.strip;
        if (line.length == 0 || line[0] == '#') continue;
        const bar = line.indexOf(" |");
        const head = bar >= 0 ? line[0 .. bar] : line;
        auto f = head.split(" ");
        switch (f[0]) {
            case "axis1-violators": l.axis1 = f[1].to!size_t; break;
            case "axis2-violators": l.axis2 = f[1].to!size_t; break;
            case "tool": {
                ToolRow r;
                r.name = f[1];
                string[string] kv;
                foreach (p; f[2 .. $]) {
                    const eq = p.indexOf('=');
                    kv[p[0 .. eq]] = p[eq + 1 .. $];
                }
                foreach (k, key; kHookKeys) r.owners[k] = kv.get(key, "");
                r.step = kv.get("step", "") == "yes";
                r.keep = kv.get("keep", "") == "yes";
                r.snap = kv.get("snap", "0").to!size_t;
                r.live = kv.get("live", "?");
                r.reason = bar >= 0 ? line[bar + 2 .. $].strip : "";
                l.tools[r.name] = r;
                break;
            }
            case "key":
                l.keys[f[1]] = [f[2]["mck=".length .. $].to!size_t,
                                f[3]["smk=".length .. $].to!size_t];
                break;
            case "write": l.writes[f[1]][f[2]] = f[3].to!size_t; break;
            default: assert(false, "tool census: unreadable ledger line: " ~ line);
        }
    }
    return l;
}

private string renderLedger(const Ledger l) {
    auto o = appender!string;
    o.put("# Tool-model census ledger (task 7110). GENERATED by\n");
    o.put("# tests/unit/tool_model_census_test.d on mismatch, between the\n");
    o.put("# `--- tool census ledger ---` markers; `live` and the text after ` | `\n");
    o.put("# are hand-kept (carried over from this file). READ THE DIFF.\n");
    o.put("#\n# Axis 1 violator: live=yes and has=tool.Tool (does not OVERRIDE the hook).\n");
    o.put("# Axis 2 violator: a `key` file with mck > 0 (a MeshCacheKey FIELD).\n");
    o.put("# Axis 3 (`write` rows) is descriptive: any change reddens until recorded.\n");
    o.put(format("axis1-violators %s\naxis2-violators %s\n\n", l.axis1, l.axis2));
    foreach (n; l.tools.keys.sort) o.put(toolLine(l.tools[n]) ~ "\n");
    o.put("\n");
    foreach (f; l.keys.keys.sort)
        o.put(format("key %s mck=%s smk=%s\n", f, l.keys[f][0], l.keys[f][1]));
    o.put("\n");
    foreach (f; l.writes.keys.sort)
        foreach (p; l.writes[f].keys.sort)
            o.put(format("write %s %s %s\n", f, p, l.writes[f][p]));
    return o[];
}

private string[] axis1Violators(const ToolRow[string] rows) {
    string[] v;
    foreach (n, r; rows) if (r.live == "yes" && r.owners[0] == "tool.Tool") v ~= n;
    return v.sort.array;
}

private string[] axis2Violators(const size_t[2][string] keys) {
    string[] v;
    foreach (f, c; keys) if (c[0] > 0) v ~= f;
    return v.sort.array;
}

// ---------------------------------------------------------------------------
// The census. ONE unittest; the order of its steps is the contract above.
// ---------------------------------------------------------------------------
unittest {
    // ===== (1) instrument floors =========================================
    const slots = hookSlots();
    const baseImpls = hookBaseImpls();
    static foreach (k, h; kHooks)
        assert(typeid(Tool).vtbl[slots[k]] is baseImpls[k],
               "tool census: vtbl slot of " ~ h ~ " not located");

    string ownerName(TypeInfo_Class c, size_t k) {
        return slotOwner(c, slots[k]).name;
    }
    auto pOwn = typeid(CensusProbeOwn), pInh = typeid(CensusProbeInherit),
         pBare = typeid(CensusProbeBare);
    auto stepInfo = cast(TypeInfo_Class) typeid(SessionStepUndo).info;
    auto keepInfo = cast(TypeInfo_Class) typeid(KeepAliveOnCancel).info;
    assert(ownerName(pOwn, 0) == pOwn.name && ownerName(pInh, 0) == pOwn.name
           && ownerName(pBare, 0) == typeid(Tool).name
           && ownerName(pOwn, 1) == typeid(Tool).name
           && implementsIface(pInh, stepInfo) && !implementsIface(pBare, stepInfo)
           && implementsIface(typeid(CensusProbeViaChild), stepInfo),
           "tool census probe: inheritance not resolved");

    size_t noModule;
    auto files = sourceFiles(noModule);
    assert(noModule == 0 && files.length > 0,
           format("tool census: source module set degenerate (%s files, %s without a module line)",
                  files.length, noModule));
    string[string] fileOfModule;
    foreach (f; files) fileOfModule[f.mod] = f.path;

    // Axis 2 needle controls.
    size_t[2][string] keyMeasured;
    foreach (f; files) {
        if (!f.path.startsWith("source/tools/")) continue;
        const c = keyCountsOf(f.src);
        if (c[0] || c[1]) keyMeasured[f.path] = c;
    }
    assert(keyMeasured.get("source/tools/edit/bridge_tool.d", kNoKeys)[1] >= 1,
           "tool census: axis 2 needle positive control failed: source/tools/edit/bridge_tool.d");
    // Task 7112 moved the slice tools to SessionMeshKey, so no production
    // file holds a MeshCacheKey field any more; the needle's CAPACITY to see
    // one is witnessed by the scanner cell below ("expected [4, 1]"), which
    // drives the production `keyCountsOf`. This row is the FLIPPED control:
    // the migrated file reads zero MeshCacheKey fields and its measured
    // SessionMeshKey fields (activation / deactivate / param images + the
    // tool's own key).
    assert(keyMeasured.get("source/tools/slice/slice_tool.d", kNoKeys) == [0, 4],
           format("tool census: axis 2 flipped control failed: source/tools/slice/slice_tool.d reads %s, expected [0, 4]",
                  keyMeasured.get("source/tools/slice/slice_tool.d", kNoKeys)));
    // Axis 2 scope floor: the scanner reads type heads literally, so an alias
    // of the key or its spelled-out `MeshKey!` form would escape it. Measured 0.
    {
        string[] escaped;
        foreach (f; files)
            if (f.path.startsWith("source/tools/") && keyEscapesOf(f.src) > 0)
                escaped ~= f.path;
        assert(escaped.length == 0,
               format("tool census: axis 2 key type spelled through an alias or MeshKey! in %s",
                      escaped));
    }

    // Axis 3 surface pin and needle controls.
    const surface = historySurface();
    assert(surface.length == kHistorySurface,
           format("tool census: CommandHistory surface changed (%s public methods, pinned %s): %s",
                  surface.length, kHistorySurface, surface));
    size_t[string][string] writeMeasured;
    foreach (f; files) {
        if (!f.path.startsWith("source/tools/")) continue;
        auto c = writeCountsOf(f.src, surface);
        if (c.length) writeMeasured[f.path] = c;
    }
    size_t pairTotal(string pair) {
        size_t n;
        foreach (f, m; writeMeasured) n += m.get(pair, 0);
        return n;
    }
    assert(pairTotal("liveRefireHistory.recordInSession") >= 1
           && pairTotal("history.record") >= 1,
           "tool census: axis 3 needle positive control failed");

    // ===== measure the population and the ledger it implies ===============
    bool[string] runtime;              // R
    TypeInfo_Class[string] infoOf;
    foreach (m; ModuleInfo) {
        if (m is null || (m.name in fileOfModule) is null) continue;
        foreach (c; m.localClasses)
            if (derivesFromTool(c)) { runtime[c.name] = true; infoOf[c.name] = c; }
    }
    string[] population;               // P = R \ E
    foreach (n; runtime.keys.sort) if (!kNamedExceptions.canFind(n)) population ~= n;

    // S: text scan with a fixed point over template and population bases.
    bool[string] lineBases = ["Tool": true];
    foreach (n; population) lineBases[n.split(".")[$ - 1]] = true;
    ClassDecl[][string] declsOf;
    foreach (f; files) declsOf[f.mod] = classDeclsOf(f.src);
    bool[string] scanned;              // S
    bool[string] templateTools;        // template tool class -> declared abstract
    for (bool grew = true; grew;) {
        grew = false;
        foreach (mod, ds; declsOf)
            foreach (d; ds) {
                bool hit;
                foreach (b; d.bases) if (b in lineBases) hit = true;
                if (!hit) continue;
                if (d.isTemplate) {
                    templateTools[mod ~ "." ~ d.name] = d.isAbstract;
                    if (d.name !in lineBases) { lineBases[d.name] = true; grew = true; }
                } else if ((mod ~ "." ~ d.name) !in scanned) {
                    scanned[mod ~ "." ~ d.name] = true;
                    grew = true;
                }
            }
    }

    const recordedText = readText(buildPath(repoRoot, ledgerPath));
    const recorded = parseLedger(recordedText);

    Ledger measured;
    foreach (n; population) {
        auto c = infoOf[n];
        ToolRow r;
        r.name = n;
        foreach (k; 0 .. kHooks.length) r.owners[k] = ownerName(c, k);
        r.step = implementsIface(c, stepInfo);
        r.keep = implementsIface(c, keepInfo);
        const file = fileOfModule.get(n[0 .. n.length - n.split(".")[$ - 1].length - 1], "");
        foreach (f; files) if (f.path == file) r.snap = snapshotDecls(blankNonCode(f.src));
        if (auto old = n in recorded.tools) { r.live = old.live; r.reason = old.reason; }
        else r.live = "?";
        measured.tools[n] = r;
    }
    foreach (f, c; keyMeasured) measured.keys[f] = c;
    foreach (f, m; writeMeasured) foreach (p, n; m) measured.writes[f][p] = n;
    const v1 = axis1Violators(measured.tools);
    const v2 = axis2Violators(measured.keys);
    measured.axis1 = v1.length;
    measured.axis2 = v2.length;

    const measuredText = renderLedger(measured);
    if (measuredText != recordedText)
        writeln("tool census: measured ledger differs from ", ledgerPath,
                "; measured ledger follows\n--- tool census ledger ---\n",
                measuredText, "--- tool census ledger ---");

    // ===== (2) population floors ==========================================
    foreach (n; population)
        assert((n in recorded.tools) !is null,
               "tool census: new tool class " ~ n ~ " has no ledger row");
    foreach (n; recorded.tools.keys.sort)
        assert(population.canFind(n),
               "tool census: ledger row " ~ n ~ " has no linked class");
    foreach (n; scanned.keys.sort)
        assert(population.canFind(n) || kNamedExceptions.canFind(n),
               "tool census: " ~ n ~ " declared but not linked");
    assert(kNamedExceptions.length == 4, "tool census: named exception list changed");
    foreach (n; kNamedExceptions)
        assert((n in runtime) !is null, "tool census: named exception " ~ n ~ " not linked");
    // The converse keeps the scan honest: a scanner that stops following a
    // base (templates, qualified names) would shrink S and pass the line above.
    foreach (n; population ~ kNamedExceptions)
        assert((n in scanned) !is null,
               "tool census: " ~ n ~ " linked but not found by the text scan");
    // `localClasses` never lists a template INSTANCE, so a concrete template
    // tool (`final class T(P) : Tool` + `alias X = T!int`) would be a live tool
    // with no row. Every template tool class must therefore be abstract, and
    // the concrete subclasses that instantiate it are the rows. Measured: 1.
    assert(templateTools.length == 1,
           format("tool census: template tool class population changed: %s (measured 1)",
                  templateTools.keys.sort));
    foreach (n; templateTools.keys.sort)
        assert(templateTools[n],
               "tool census: template tool class " ~ n ~ " is not abstract; its instances escape the census");

    // ===== (3) violator constants, axis 1 then axis 2 =====================
    const r1 = axis1Violators(recorded.tools);
    foreach (n; v1) assert(r1.canFind(n), "tool census: axis 1 violator added: " ~ n);
    foreach (n; r1)
        assert(v1.canFind(n), "tool census: axis 1 violator removed: " ~ n ~ ", lower the ledger");
    assert(recorded.axis1 == v1.length,
           format("tool census: axis 1 violator constant %s, measured %s", recorded.axis1, v1.length));
    const r2 = axis2Violators(recorded.keys);
    foreach (f; v2) assert(r2.canFind(f), "tool census: axis 2 violator added: " ~ f);
    foreach (f; r2)
        assert(v2.canFind(f), "tool census: axis 2 violator removed: " ~ f ~ ", lower the ledger");
    assert(recorded.axis2 == v2.length,
           format("tool census: axis 2 violator constant %s, measured %s", recorded.axis2, v2.length));

    // ===== (4) row-by-row =================================================
    foreach (n; population) {
        const m = measured.tools[n];
        const r = recorded.tools.get(n, ToolRow.init);
        assert(r.live == "yes" || r.live == "no",
               "tool census: row " ~ n ~ " has no live classification");
        // Subsumed by the next assert; kept for its more specific message.
        assert(!(m.snap > 0 && r.live == "no" && r.reason.length == 0),
               "tool census: live proxy (MeshSnapshot) dismissed without a reason: " ~ n);
        assert(r.reason.length > 0, "tool census: row " ~ n ~ " has no reason");
        assert(toolLine(m) == toolLine(r),
               "tool census: row changed\n  recorded: " ~ toolLine(r) ~ "\n  measured: " ~ toolLine(m));
    }
    foreach (f; (measured.keys.keys ~ recorded.keys.keys).sort)
        assert(measured.keys.get(f, kNoKeys) == recorded.keys.get(f, kNoKeys),
               format("tool census: axis 2 counts changed for %s: recorded %s, measured %s",
                      f, recorded.keys.get(f, kNoKeys), measured.keys.get(f, kNoKeys)));
    foreach (f; (measured.writes.keys ~ recorded.writes.keys).sort) {
        size_t[string] m, r;
        if (auto p = f in measured.writes) m = cast(size_t[string]) *p;
        if (auto p = f in recorded.writes) r = cast(size_t[string]) *p;
        foreach (p; (m.keys ~ r.keys).sort)
            assert(m.get(p, 0) == r.get(p, 0),
                   format("tool census: axis 3 count changed: %s %s recorded %s, measured %s",
                          f, p, r.get(p, 0), m.get(p, 0)));
    }
    assert(measuredText == recordedText,
           "tool census: ledger text differs from the measurement (header or ordering)");

    writeln(format("tool census: |P|=%s |S|=%s |E|=%s axis1=%s axis2=%s",
                   population.length, scanned.length, kNamedExceptions.length,
                   v1.length, v2.length));
}

// Scanner cells: a field in an aggregate counts; a local, an import, a
// function-body use and a unittest body do not.
unittest {
    const src = q"EOS
import mesh : Mesh, MeshCacheKey;
struct Image { MeshCacheKey armedKey; int x; }
class T : Tool {
    private MeshCacheKey armedKey_;
    version (unittest) { SessionMeshKey probeKey; }
    static if (true) { MeshCacheKey[2] inStaticIf; }
    MeshCacheKey[extent(2)] sized;
    MeshCacheKey keyOf() const;
    void f() { MeshCacheKey local; armedKey_ = MeshCacheKey.init; }
}
unittest { struct U { MeshCacheKey inTest; } }
EOS";
    const c = keyCountsOf(src);
    assert(c[0] == 4 && c[1] == 1,
           format("tool census scanner cell: key fields %s, expected [4, 1]", c));
    // A label leaves the next declaration in the same statement; braceless
    // conditional heads, `@attr` and `const(T)` are transparent. One each.
    const heads = [
        "class L : Tool {\n    private:\n    MeshCacheKey afterLabel;\n}",
        "class L : Tool {\n    public: package: MeshCacheKey twoLabels;\n}",
        "class L : Tool {\n    version (X) MeshCacheKey braceless;\n}",
        "class L : Tool {\n    version (X) {} else MeshCacheKey inElse;\n}",
        "class L : Tool {\n    debug MeshCacheKey inDebug;\n}",
        "class L : Tool {\n    static if (a && b) MeshCacheKey inStaticIf;\n}",
        "class L : Tool {\n    @nogc @attr(1) MeshCacheKey attributed;\n}",
        "class L : Tool {\n    const(MeshCacheKey)[] ctor;\n}",
    ];
    foreach (h; heads)
        assert(keyCountsOf(h) == [1, 0],
               format("tool census scanner cell: key fields %s, expected [1, 0] in\n%s",
                      keyCountsOf(h), h));
    // Alias / spelled-out key spellings: four escapes; a bare `MeshKey` beside
    // the term (an import), a non-mutation term and another alias are not.
    const esc = keyEscapesOf(q"EOS
import mesh : MeshKey, MeshTermMutation;
alias K = mesh.MeshCacheKey;
alias SessionMeshKey S2;
class A { MeshKey!(MeshTermGeomEpoch, MeshTermMutation) k; MeshKey!MeshTermMutation j; }
class B { MeshKey!MeshTermMarks ok; alias Other = int; }
EOS");
    assert(esc == 4, format("tool census scanner cell: key spelling escapes %s, expected 4", esc));
    const ds = classDeclsOf("abstract class S(P) : H!(P) {}\nfinal class C : S!int, I {}\n"
                            ~ "final class F(P) : C {}\n"
                            ~ "unittest { class U : C {} }\n");
    assert(ds.length == 3 && ds[0].isTemplate && ds[0].isAbstract && ds[0].bases == ["H"]
           && !ds[1].isTemplate && !ds[1].isAbstract && ds[1].bases == ["S", "I"]
           && ds[2].isTemplate && !ds[2].isAbstract,
           "tool census scanner cell: class declarations misparsed");
    // Every receiver spelling: bare, qualified, camel-case, typed by `auto`,
    // address-of; a non-surface method and a comment do not count.
    const w = writeCountsOf(q"EOS
void g() {
    fooHistory.undo();
    this.history.record(c);
    auto hist = new CommandHistory();
    hist.canUndo;
    auto d = &history.undo;
    history.frobnicate();
    // history.redo();
    recordGestureEdit(c, m);
}
void k(CommandHistory h) { h.redo(); }
EOS", ["undo", "record", "canUndo", "redo"]);
    assert(w.get("fooHistory.undo", 0) == 1 && w.get("history.record", 0) == 1
           && w.get("hist.canUndo", 0) == 1 && w.get("history.undo", 0) == 1
           && w.get("h.redo", 0) == 1
           && w.length == 6 && w.get("recordGestureEdit", 0) == 1,
           format("tool census scanner cell: write spellings %s", w));
}
