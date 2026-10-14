// census_symbols — ONE census scanner, and a ledger keyed by the SYMBOL a
// site sits in rather than by the PATH of the file that happens to hold it
// (task 4056).
// General pattern: doc/derived_census_pattern.md (project-owned path; an exact
// SDK-tree search for derived_census_pattern returned no files).
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
// WHAT IS NOT WEAKENED, AND THE RESIDUAL THAT IS NARROWED BUT NOT CLOSED
// ===========================================================================
// Dropping the module from the key opens exactly one shape: a call deleted
// from a recorded `applyFold` and added, in the same commit, to a DIFFERENT
// module's function that also happens to be called `applyFold`, netting to
// the recorded count.
//
// The AMBIGUITY finding in `reconcile` below NARROWS that shape. It does not
// close it, and this header said it did until task 4056's review measured
// otherwise. Ambiguity fires on a key whose SURVIVING hits are spread over
// two or more FILES, so what it catches is a PARTIAL migration: the recorded
// `applyFold` keeps some of its sites and the homonym acquires the rest.
// A WHOLESALE migration of a row whose count is ONE leaves the key realised
// in exactly one file again and produces NO finding at all — `found[key] ==
// r.count` skips the count branch, the key is recorded so it skips the
// unrecorded branch, and `files.length < 2` skips ambiguity. That is the
// ordinary row, not a corner: of the 50 rows in the three ledgers converted
// here, 46 have count 1 (version_poll 22 of 24, confined 10 of 10,
// mesh_planes 14 of 16).
//
// THE RESIDUAL IS ACCEPTED, and the alternative was weighed rather than
// waved off. Keying on MODULE plus symbol would close it, and in D the module
// is always knowable — but module names in this tree mirror the directory
// path (`source/tools/transform/xfrm_apply.d` declares `module
// tools.transform.xfrm_apply;`), so a `git mv` cannot leave the declaration
// alone. A module-qualified key is therefore the PATH key with different
// punctuation, and it would redden on precisely the reorganisations this
// module exists to survive — paying for every row to defend a shape nobody
// has yet produced. What is given up in exchange is bounded: the residual
// needs a call DELETED from one module's function and ADDED to a homonym in
// another, which is not a code move at all. It edits two bodies in two files
// and lands in review as a diff to read, whereas the case this key was built
// for — a directory reorganisation — carries no diff to read and is exactly
// where a reflex number-bump happens. A pure move keeps the symbol in one
// file and stays green either way, which is the whole point.
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
//
// "ANONYMOUS when it cannot name" is a claim with a known way of failing, and
// it HAS failed once here. An attribute carrying arguments — `@Attr("x") void
// f() { … }` — puts a top-level `(` in front of the function's own with an
// arbitrary identifier before it, so instead of degrading to anonymous the
// walker NAMED THE ATTRIBUTE, and two functions under the same UDA in one
// file collapsed into one key (task 4056 review; latent, no such site in
// `source/` today). Attributes with arguments now have their own arm in
// `declaratorName` and their own cell. The keyword-headed forms `extern(C)`
// and `pragma(…)` were already covered by `kNotAName`; the lesson is that a
// list of keywords cannot cover a construct whose head is user-chosen.
module tests.unit.census_symbols;

import std.algorithm : canFind, find, sort;
import std.array     : appender, join;
import std.conv      : to;
import std.exception : assertThrown;
import core.exception : AssertError;
import std.file : SpanMode;
private alias dirEntries = wave15DirEntries;
private alias exists = wave15Exists;
private alias isFile = wave15IsFile;
private alias readText = wave15ReadText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.regex     : ctRegex, matchAll, regex;
import std.string    : indexOf, lastIndexOf, replace, split, strip;

package bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Whole-identifier occurrences of `ident` in `code`; an empty name counts 0.
package size_t countIdent(string code, string ident) {
    if (ident.length == 0) return 0;
    size_t n = 0, i = 0;
    while (i + ident.length <= code.length) {
        if (code[i .. i + ident.length] == ident &&
            (i == 0 || !isIdentChar(code[i - 1])) &&
            (i + ident.length == code.length ||
             !isIdentChar(code[i + ident.length]))) {
            ++n; i += ident.length;
        } else ++i;
    }
    return n;
}

/// 1-based line number of byte offset `pos` in `src`.
package size_t lineOf(string src, size_t pos) {
    size_t n = 1;
    foreach (i; 0 .. pos) if (src[i] == '\n') ++n;
    return n;
}

/// Non-overlapping occurrences of `needle` in `hay`.
///
/// The empty-needle guard is not defensive dressing: without it the loop
/// condition `i + 0 <= hay.length` is permanently true and `i += 0` never
/// advances, so an empty needle HANGS the lane rather than returning a
/// number. Seven of the eight inline copies this replaces lacked it; only
/// `tool_commit_seam_census_g8_test.d`'s carried it, and merging onto the
/// unguarded majority would have been a silent regression.
package size_t countOccurrences(string hay, string needle) {
    size_t n = 0, i = 0;
    if (needle.length == 0) return 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

/// Bytes of the registration family: `registration.d` plus every
/// `source/*_registration.d`. The total is conserved when a registrar is
/// extracted from the root, unlike a floor on `registration.d` alone.
/// `files` includes the root and is floored by every caller so an empty or
/// truncated glob cannot make the byte census vacuously useful.
package(tests.unit) size_t registrationFamilyBytes(
        string repoRoot, out size_t files) {
    const sourceDir = buildPath(repoRoot, "source");
    size_t bytes;
    files = 1;
    bytes += readText(buildPath(sourceDir, "registration.d")).length;
    foreach (scanSourceRoot; [sourceDir, buildPath(repoRoot, "packages/application-core/source")])
    foreach (de; dirEntries(scanSourceRoot, "*_registration.d", SpanMode.shallow)) {
        ++files;
        bytes += readText(de.name).length;
    }
    return bytes;
}

/// Shared production registration reader. Legacy families keep their exact
/// root entry; the common pilot has six operation-only template entries.
/// Task 20261770; the signatures and actual desktop callers are identities.
package(tests.unit) string registrationFamilyText(string repoRoot) {
    const sourceDir = buildPath(repoRoot, "source");
    const parentPath = buildPath(sourceDir, "registration.d");
    const parentCode = blankNonCode(readText(parentPath));
    string[] paths = [parentPath];
    foreach (scanSourceRoot; [sourceDir, buildPath(repoRoot, "packages/application-core/source")])
    foreach (de; dirEntries(scanSourceRoot, "*_registration.d", SpanMode.shallow))
        paths ~= de.name;
    sort(paths);
    assert(paths.length >= 4, "registration reader family population");
    enum legacyEntry = ctRegex!(
        `void[ \t\r\n]+(register[A-Za-z0-9_]*Commands)[ \t\r\n]*\([ \t\r\n]*ref[ \t\r\n]+Registry[ \t\r\n]+reg\b`);
    string result;
    foreach (path; paths) {
        assert(exists(path) && isFile(path), "registration reader missing " ~ path);
        const source = readText(path);
        const code = blankNonCode(source);
        if (baseName(path) == "pilot_command_registration.d") {
            enum names = ["registerTripleCommand", "registerMeshSelectionCommand",
                "registerHistoryNavigationCommands", "registerElementSelectionCommand",
                "registerDropSelectionCommand", "registerInvertSelectionCommand"];
            enum callers = ["mesh_command_registration.d", "mesh_command_registration.d",
                "history_macro_registration.d", "selection_command_registration.d",
                "selection_command_registration.d", "selection_command_registration.d"];
            pilotRegistrationIds(source);
            foreach (i, name; names) {
                const caller = blankNonCode(readText(buildPath(sourceDir, callers[i])));
                const entry = i == 2 ? "registerHistoryCommands" : i >= 3 ? "registerSelectionCommands" : "registerMeshCommands";
                requirePilotDesktopCaller(caller, name, entry);
            }
        } else if (path != parentPath) {
            string[] entries;
            foreach (m; matchAll(code, legacyEntry)) entries ~= m[1].idup;
            assert(entries.length == 1,
                format("%s must expose exactly one register…Commands(ref Registry reg entry; found %d",
                    path, entries.length));
            assert(countOccurrences(parentCode, entries[0] ~ "(") == 1,
                path ~ " exposes " ~ entries[0] ~ " but registration.d never calls it exactly once");
        }
        result ~= source;
    }
    return result;
}

/// Structural heads use only the byte-aligned code projection; the returned
/// offsets point just past an immediate body statement's opening parenthesis.
/// Inputs are balanced body spans, so the opening brace supplies the first head.
private size_t[] statementCallOffsets(string code, string head) {
    size_t[] offsets;
    size_t scanned;
    int depth;
    foreach (m; matchAll(code, regex("[;{}]\\s*" ~ head ~ "\\s*\\("))) {
        const offset = m.pre.length + m[0].length;
        foreach (c; code[scanned .. offset]) {
            if (c == '{') ++depth;
            else if (c == '}') --depth;
        }
        scanned = offset;
        if (depth == 1) offsets ~= offset;
    }
    return offsets;
}

// Both pilot and desktop entries are top-level declarations. Parameter
// groups own their nested delimiters; only the next code token owns the body.
private string registrationBody(string code, size_t declaration, string name) {
    int depth;
    foreach (c; code[0 .. declaration]) {
        if (c == '{') ++depth;
        else if (c == '}') --depth;
    }
    assert(depth == 0, "1D common registrar top-level production entry: " ~ name);
    const head = matchAll(code[declaration .. $], regex("^void\\s+" ~ name ~ "\\s*\\("));
    assert(!head.empty, "1D common registrar declaration head: " ~ name);
    size_t open = declaration + head.front[0].length - 1;
    do {
        const parameters = balancedSpan(code, open, '(', ')');
        assert(parameters.length != 0, "1D common registrar balanced parameter group: " ~ name);
        open += parameters.length;
        skipSpace(code, open, code.length);
    } while (open < code.length && code[open] == '(');
    assert(open < code.length && code[open] == '{',
        "1D common registrar immediate production body: " ~ name);
    const body = balancedSpan(code, open, '{', '}');
    assert(body.length != 0, "1D common registrar balanced production body: " ~ name);
    return body;
}

package(tests.unit) void requirePilotDesktopCaller(string caller, string name, string entry) {
    assert(countOccurrences(caller, name ~ "(") == 1,
        "1D common registrar exact desktop caller: " ~ name);
    size_t[] declarations;
    foreach (m; matchAll(caller, regex("\\bvoid\\s+" ~ entry
            ~ "\\s*\\(\\s*ref\\s+Registry\\s+reg\\b")))
        declarations ~= m.pre.length;
    assert(declarations.length == 1,
        "1D common registrar exact desktop entry: " ~ entry);
    const body = registrationBody(caller, declarations[0], entry);
    size_t supportedCalls;
    foreach (offset; statementCallOffsets(body, name)) {
        if (!matchAll(body[offset .. $], ctRegex!(`^\s*reg\s*,`)).empty)
            ++supportedCalls;
    }
    assert(supportedCalls == 1,
        "1D common registrar supported desktop reg receiver: " ~ name);
}

/// Only the frozen pilot bodies admit the `registry` receiver. The returned
/// IDs are data read only after a structural head was admitted as actual code.
package(tests.unit) string[] pilotRegistrationIds(string source) {
    enum names = ["registerTripleCommand", "registerMeshSelectionCommand",
        "registerHistoryNavigationCommands", "registerElementSelectionCommand",
                "registerDropSelectionCommand", "registerInvertSelectionCommand"];
    enum expected = [["mesh.triple"], ["mesh.select"], ["history.undo", "history.redo"],
        ["select.element"], ["select.drop"], ["select.invert"]];
    const code = blankNonCode(source);
    const literals = blankNonCode(source, true);
    auto visible = source.dup;
    foreach (i; 0 .. visible.length)
        if (code[i] != literals[i]) visible[i] = code[i];
    string[] entries;
    foreach (m; matchAll(code, ctRegex!(`\bvoid\s+(register[A-Za-z0-9_]*)\s*\(`)))
        entries ~= m[1].idup;
    assert(entries == names, "1D common registrar exact six entry identities");
    string[] result;
    foreach (i, name; names) {
        const tail = i == 2 ? ", CommandHistory history) {" : ") {";
        const header = "void " ~ name
            ~ "(Registrar)(ref Registrar registry, PilotCommandDeps deps" ~ tail;
        const declaration = matchAll(code, regex("\\bvoid\\s+" ~ name ~ "\\s*\\(")).front.pre.length;
        const body = registrationBody(code, declaration, name);
        const open = body.ptr - code.ptr;
        assert(code[declaration .. open + 1].split.join(" ") == header,
            "1D common registrar supported template signature: " ~ name);
        string[] ids;
        foreach (offset; statementCallOffsets(body, `registry\s*\.\s*registerCommand`)) {
            foreach (m; matchAll(visible[open + offset .. open + body.length],
                    ctRegex!(`^\s*"([^"]+)"\s*,`)))
                ids ~= m[1].idup;
        }
        assert(ids == expected[i], "1D common registrar exact pilot IDs and receiver: " ~ name);
        result ~= ids;
    }
    assert(countIdent(code, "registerCommand") == 7,
        "1D common registrar exact seven supported registration sites");
    return result;
}

/// The span starting at `open` through its matching delimiter, inclusive.
/// Returns "" for a missing opener or an unclosed span so callers can put an
/// area-specific population floor above the census that consumes it.
package(tests.unit) string balancedSpan(
        string src, size_t open, char lo, char hi) {
    if (open >= src.length || src[open] != lo) return "";
    int depth;
    foreach (i; open .. src.length) {
        if (src[i] == lo) ++depth;
        else if (src[i] == hi && --depth == 0)
            return src[open .. i + 1];
    }
    return "";
}

package(tests.unit) string toolRegistrationHead(string id) {
    return "reg.registerTool(\"" ~ id ~ "\", ";
}

package(tests.unit) string commandRegistrationHead(string id) {
    return "reg.registerCommand(\"" ~ id ~ "\", ";
}

/// Extract one brace-lambda tool registration in either the literal legacy
/// assignment or the paired helper form. The source stays raw for id matching;
/// the same-length code projection owns brace balancing so literals/comments
/// cannot extend the block into the next registration.
package string toolRegistrationBlock(string src, string id, out string problem) {
    immutable oldHead = toolRegistrationHead(id);
    immutable pairedHead = "reg, \"" ~ id ~ "\", () {";
    immutable size_t oldDefs = countOccurrences(src, oldHead);
    immutable size_t pairedDefs = countOccurrences(src, pairedHead);
    immutable size_t defs = oldDefs + pairedDefs;
    if (defs != 1) {
        problem = "wire id `" ~ id ~ "`: found " ~ defs.to!string
                ~ " registration definitions, expected exactly 1";
        return null;
    }

    size_t start;
    size_t bodyOpen;
    if (oldDefs == 1) {
        start = cast(size_t) src.indexOf(oldHead);
        const relOpen = src[start .. $].indexOf('{');
        if (relOpen < 0) {
            problem = "wire id `" ~ id ~ "`: legacy registration has no lambda body";
            return null;
        }
        bodyOpen = start + cast(size_t) relOpen;
    } else {
        const idAt = src.indexOf(pairedHead);
        const prefix = src[0 .. cast(size_t) idAt];
        const callAt = prefix.lastIndexOf("registerHeadlessTool!");
        if (callAt < 0 || prefix[cast(size_t) callAt .. $].canFind(';')) {
            problem = "wire id `" ~ id ~ "`: paired head is not owned by registerHeadlessTool";
            return null;
        }
        start = cast(size_t) callAt;
        bodyOpen = cast(size_t) idAt + pairedHead.length - 1;
    }

    const code = blankNonCode(src);
    size_t depth = 1;
    foreach (i; bodyOpen + 1 .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return src[start .. i + 1];
    }
    problem = "wire id `" ~ id ~ "`: registration lambda is unbalanced";
    return null;
}

/// Statements of a CODE view that contain `needle`: text between `;`, `{`
/// or `}` boundaries, stripped. A `=>` lambda stays inside its statement; a
/// brace-bodied lambda's inner statements are separate statements.
package string[] statementsContaining(string code, string needle) {
    string[] result;
    size_t from;
    foreach (i, c; code) {
        if (c != ';' && c != '{' && c != '}') continue;
        const statement = code[from .. i + 1].strip;
        if (statement.canFind(needle)) result ~= statement;
        from = i + 1;
    }
    return result;
}

/// Import-declaration lexer shared with task 5280; its fixture cells are the
/// first unittest in display_refresh_mask_boundary_test.d.
package struct ImportDecl {
    size_t start;
    size_t end;
    size_t moduleListEnd;
}

package bool containsWord(string code, string word)
{
    size_t pos;
    while (pos < code.length) {
        const rel = code[pos .. $].indexOf(word);
        if (rel < 0) return false;
        const at = pos + cast(size_t) rel;
        const before = at == 0 || !isIdentChar(code[at - 1]);
        const after = at + word.length == code.length
            || !isIdentChar(code[at + word.length]);
        if (before && after) return true;
        pos = at + word.length;
    }
    return false;
}

package void skipSpace(string code, ref size_t pos, size_t end)
{
    while (pos < end && (code[pos] == ' ' || code[pos] == '\t'
                      || code[pos] == '\r' || code[pos] == '\n')) ++pos;
}

package ImportDecl[] importDeclarations(string code)
{
    ImportDecl[] result;
    size_t searchAt;
    while (searchAt < code.length) {
        const rel = code[searchAt .. $].indexOf("import");
        if (rel < 0) break;
        const at = searchAt + cast(size_t) rel;
        searchAt = at + "import".length;
        if ((at > 0 && isIdentChar(code[at - 1]))
            || (searchAt < code.length && isIdentChar(code[searchAt])))
            continue;

        size_t body = searchAt;
        skipSpace(code, body, code.length);
        if (body < code.length && code[body] == '(')
            continue; // string import expression, not an import declaration

        const semiRel = code[body .. $].indexOf(';');
        if (semiRel < 0) break;
        const end = body + cast(size_t) semiRel + 1;
        const colonRel = code[body .. end].indexOf(':');
        const moduleListEnd = colonRel < 0
            ? end : body + cast(size_t) colonRel;
        result ~= ImportDecl(at, end, moduleListEnd);
        searchAt = end;
    }
    return result;
}

/// One `history.<NAME>(` call site: the symbol it sits in, the primitive
/// called, and the 1-based line.
package struct SurfaceHit { string symbol; string name; size_t line; }

/// Every `history.<NAME>(` / `history_.<NAME>(` CALL in `src`.
///
/// Hand-scanned rather than regex'd, deliberately: the tool-seam censuses
/// (task 1905 phase B/C) are defined over the whole call surface of the
/// receiver, not over a list of primitive names, so that a sixth history
/// primitive called from a tool tomorrow reddens them for free. Three rules
/// carry that, and each is a case a regex on one name got wrong:
///
///  * `history` must be a WHOLE identifier — nothing identifier-ish may
///    precede it, so `myHistory.record(` is not a hit;
///  * a single trailing `_` is accepted (`history_`), because the seam's own
///    field is spelled that way in some tools;
///  * the member must be CALLED — a `(` after the name, whitespace allowed —
///    so a read such as `history.entries.length` is not a recorder.
///
/// Caller contract: pass source that has been through `blankNonCode`, or a
/// doc comment naming `history.record(` moves the count.
package SurfaceHit[] historySurface(string src) {
    import std.string : indexOf;

    SurfaceHit[] hits;
    const symbols = enclosingSymbols(src);
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf("history");
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + 7;
        // Must be a whole identifier: nothing identifier-ish before it.
        if (p > 0 && isIdentChar(src[p - 1])) continue;
        size_t q = p + 7;
        if (q < src.length && src[q] == '_') ++q;            // `history_`
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        if (q >= src.length || src[q] != '.') continue;
        ++q;
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        size_t nameStart = q;
        while (q < src.length && isIdentChar(src[q])) ++q;
        if (q == nameStart) continue;
        string nm = src[nameStart .. q];
        size_t r = q;
        while (r < src.length && (src[r] == ' ' || src[r] == '\t' || src[r] == '\n')) ++r;
        if (r >= src.length || src[r] != '(') continue;      // a read, not a call
        const line = lineOf(src, p);
        hits ~= SurfaceHit(symbolAt(symbols, line - 1), nm, line);
    }
    return hits;
}

unittest // the scanner cluster's own contracts (task 0678 M10)
{
    // ORDER MATTERS HERE. Everything above the first failed assert has run
    // and passed, so the cheap total sits first and the three discriminating
    // rules follow it; a single run then reports which rule broke.
    assert(lineOf("a\nb\nc", 4) == 3, "lineOf is 1-based and counts newlines");
    assert(countOccurrences("aaaa", "aa") == 2, "occurrences are non-overlapping");
    assert(countOccurrences("aaaa", "") == 0,
           "an empty needle must return 0 — without the guard this call HANGS");
    assert(countIdent("ab xab abx ab_ (ab) ab", "ab") == 3,
           "countIdent counts whole identifiers only, on both boundaries");

    enum string probe = q{
        void owner() {
            history.record(c);
            history_ . setDelta (d);
            myHistory.record(c);
            auto n = history.entries.length;
        }
    };
    const hits = historySurface(probe);
    // POPULATION FLOOR: `hits.length == 2` below is vacuously satisfiable by a
    // scanner that lost its place and returned nothing, so pin the count as a
    // number before reading any element of it.
    assert(hits.length == 2,
           "two of the four `history`-ish lines are calls on the receiver");
    assert(hits[0].name == "record" && hits[1].name == "setDelta",
           "the member name is what the roster is reconciled against");
    assert(hits[0].symbol == "owner" && hits[1].symbol == "owner",
           "each hit carries the symbol it sits in, not the file");
    // The two rejects, named so a widened scanner cannot pass this quietly.
    foreach (h; hits) assert(h.symbol.length > 0, "no hit may be symbol-less");
    assert(historySurface("myHistory.record(c);").length == 0,
           "`history` must be a WHOLE identifier");
    assert(historySurface("history.entries.length;").length == 0,
           "a read is not a call");
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
package(tests.unit) string blankNonCode(string src, bool keepComments = false) {
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
///
/// This list cannot be the whole story, because a UDA's head is user-chosen:
/// `@Attr("x")` is caught by the `@` arm in `declaratorName`, not from here.
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
        // An ATTRIBUTE'S parenthesis is not a parameter list, and an
        // attribute that carries ARGUMENTS cannot be caught by name the way
        // `extern(C)` / `pragma(…)` are: a UDA is spelled with an arbitrary
        // identifier, so `@Attr("x") void f() { … }` would name the block
        // `Attr` and merge every function under the same UDA into one ledger
        // key. Recognise it by the `@` instead — walking back over a
        // qualified name (`@core.attribute.gnuAbiTag`) and a template
        // instantiation (`@Attr!int`) but NEVER across whitespace, because
        // skipping blanks here would read `@safe void f()` as an attribute
        // too and lose `f`.
        size_t at = s;
        while (at > 0 && (isIdentChar(d[at - 1]) || d[at - 1] == '.'
                                                 || d[at - 1] == '!')) --at;
        if (at > 0 && d[at - 1] == '@') continue;   // `@Attr(…) void f() { … }`
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

/// Every non-overlapping occurrence of `needle` in an already-blanked CODE
/// view, attributed to its enclosing declaration. `tag` is an optional
/// discriminator for ledgers that count several predicates over the same
/// declaration (for example `recordGestureEdit` and its three modes).
package LedgerHit[] symbolTokenHits(string code, string file, string needle,
                                    string tag = "")
{
    LedgerHit[] hits;
    if (needle.length == 0) return hits;
    const symbols = enclosingSymbols(code);
    size_t from, line0;
    while (from + needle.length <= code.length) {
        auto rel = code[from .. $].find(needle);
        if (rel.length == 0) break;
        const pos = cast(size_t)(rel.ptr - code.ptr);
        foreach (c; code[from .. pos]) if (c == '\n') ++line0;
        size_t lineEnd = pos;
        while (lineEnd < code.length && code[lineEnd] != '\n') ++lineEnd;
        const symbol = symbolAt(symbols, line0);
        hits ~= LedgerHit(tag.length ? symbol ~ "|" ~ tag : symbol,
                          file, line0 + 1, code[pos .. lineEnd]);
        from = pos + needle.length;
    }
    return hits;
}

/// Compare the found multiset against the recorded one. Returns `""` when
/// they agree, and otherwise a block of findings, one paragraph each.
///
/// FOUR findings, and the fourth is what makes a module-free key defensible:
///   1. a recorded key whose count changed (a vanished key is this with 0);
///   2. a key found that nobody recorded;
///   3. a recorded key with no occurrences at all, called out in its own
///      words because "recorded 2, found 0" reads like a scanner fault;
///   4. AMBIGUITY — one key realised in more than one FILE. A pure move keeps
///      a symbol in exactly one file, so this never fires on the thing this
///      module exists to allow; what it catches is a PARTIAL migration to a
///      homonym in another module — some sites left behind, some acquired,
///      the total unchanged. It catches nothing when the migration is
///      WHOLESALE and the row's count is 1, because the key is then realised
///      in one file again; that residual is stated in full in this file's
///      header and deliberately accepted, not closed here.
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

/// …AND AN ATTRIBUTE THAT CARRIES ARGUMENTS, which is the same rule reached
/// through a different door and the one that has no keyword to be caught by.
/// `extern` and `pragma` are in `kNotAName`; a UDA is spelled with an
/// ARBITRARY identifier, so `@Attr("x") void f() { … }` puts a top-level `(`
/// in front of the function's own with `Attr` sitting where a declarator name
/// would sit. A walker that stops there names the block `Attr`, and TWO
/// functions carrying the same UDA in one file then collapse into ONE ledger
/// key — which the AMBIGUITY finding cannot catch, because ambiguity is
/// defined over FILES and these two are in the same one. That is a silent
/// merge of two symbols, the exact failure the nested-aggregate cell above
/// exists for.
///
/// LATENT, not live: `grep -rnE '@[A-Za-z_][A-Za-z0-9_.]*\(' source/
/// --include=*.d` reports four hits on 2026-09-04 (`@selector(…)` ×3 in
/// `source/app.d`, `@section(…)` in `source/tsan_preinit.d`) and every one of
/// them sits on a declaration that ends in `;`, so none of them reaches a
/// brace. The cell is here because the walker is claimed to make anything it
/// cannot name ANONYMOUS, and this shape made it name the wrong thing instead.
unittest {
    enum string probe = q"PROBE
@Attr("x") void first() {
    hit();
}
@core.attribute.gnuAbiTag("v2") @Other!int(3) void second() {
    hit();
}
PROBE";
    auto s = symsOf(probe);
    assert(symbolAt(s, 1) == "first", format(
        "an attribute with arguments must not be taken for the declarator: "
      ~ "`@Attr(\"x\") void first()` names `first`, not the attribute. "
      ~ "Got `%s`.", symbolAt(s, 1)));
    assert(symbolAt(s, 4) == "second", format(
        "a QUALIFIED attribute (`@core.attribute.gnuAbiTag`) and a TEMPLATED "
      ~ "one (`@Other!int`) must both be stepped over — got `%s`.",
        symbolAt(s, 4)));
    // Said again as the consequence, so a future walker that names both
    // blocks after some third thing still reddens with the reason.
    assert(symbolAt(s, 1) != symbolAt(s, 4), format(
        "two functions under attributes must not share a key: both came out "
      ~ "as `%s`, so one ledger row would cover two declarations and no "
      ~ "AMBIGUITY finding could see it — they are in the same file.",
        symbolAt(s, 1)));
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
        LedgerHit("Mesh.publishConfinedChange", "packages/mesh/source/mesh.d", 10, "x"),
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
    //    between two homonymous functions unseen. With it, only a PARTIAL
    //    migration is caught; see the header for the wholesale case, which
    //    is a stated and accepted residual rather than a covered one.
    LedgerHit[] split = [
        LedgerHit("Mesh.publishConfinedChange", "packages/mesh/source/mesh.d", 10, "x"),
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

unittest { // generic token attribution used by the remaining census families
    enum sample = "void f() {\n  x();\n  x();\n}\nvoid g() {\n  x();\n}\n";
    const hits = symbolTokenHits(blankNonCode(sample), "moved.d", "x(", "call");
    assert(hits.length == 3, format("expected three token sites, got %s", hits));
    assert(hits[0].key == "f|call" && hits[1].key == "f|call"
        && hits[2].key == "g|call", format("wrong symbol attribution: %s", hits));
    assert(hits[2].file == "moved.d" && hits[2].line == 6,
        format("diagnostic address drifted: %s", hits[2]));
}

unittest { // statement boundaries used by late-read registrar censuses
    enum probe = "void r() {\n"
        ~ "  auto e = host.read();\n"
        ~ "  a = () => new X(host.read());\n"
        ~ "  b = () { return new X(host.read()); };\n"
        ~ "  c[\"x;y\"] = () => new Y(host.read());\n"
        ~ "  if (true) { sink(); }\n"
        ~ "  d = () => new Z(host.read());\n"
        ~ "}\n";
    const statements = statementsContaining(
        blankNonCode(probe), "host.read()");
    assert(statements.length == 5, format(
        "6350 statement scanner: expected 5 reads, got %s: %s",
        statements.length, statements));
    assert(statements[0] == "auto e = host.read();",
        "6350 statement scanner lost a plain statement");
    assert(statements[1] == "a = () => new X(host.read());",
        "6350 statement scanner split an expression lambda");
    assert(statements[2] == "return new X(host.read());",
        "6350 statement scanner kept a brace-lambda prefix");
    assert(statements[3] == "c[     ] = () => new Y(host.read());",
        "6350 statement scanner split at blanked literal content");
    assert(statements[4] == "d = () => new Z(host.read());",
        "6350 statement scanner kept a closing-brace prefix");
}

unittest { // task 6353 registration-block boundaries, old and paired forms
    enum probe = q"PROBE
registerHeadlessTool!BoxTool(reg, "prim.cube", () {
    auto t = new BoxTool();
    // an unbalanced { in a comment
    t.tag("{");
    if (ready) { t.bind(); }
    return t;
}, owner, live);
registerHeadlessTool!SphereTool(reg, "prim.sphere", () {
    return new SphereTool();
}, owner, live);
reg.registerTool("pen", typedToolFactory!PenTool(() {
    return new PenTool();
});
reg.registerTool("prim.vertex", typedToolFactory!VertexTool(() {
    return new VertexTool();
});
PROBE";
    string problem;
    const paired = toolRegistrationBlock(probe, "prim.cube", problem);
    assert(problem.length == 0, problem);
    assert(countOccurrences(paired, "new BoxTool(") == 1,
        "6353 block: the prim.cube registration lost its own constructor");
    assert(!paired.canFind("\"prim.sphere\""),
        "6353 block: the prim.cube registration block reached \"prim.sphere\"");

    const legacy = toolRegistrationBlock(probe, "pen", problem);
    assert(problem.length == 0, problem);
    assert(countOccurrences(legacy, "new PenTool(") == 1,
        "6353 block: the pen registration lost its own constructor");
    assert(!legacy.canFind("\"prim.vertex\""),
        "6353 block: the pen registration block reached \"prim.vertex\"");
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
    auto wave15Inputs = wave15InputStart();
    size_t registrationFiles;
    const registrationBytes = registrationFamilyBytes(
        repoRoot, registrationFiles);
    assert(registrationFiles >= 15 && registrationBytes > 110_000,
        format("6509 registration-family helper reached only %d file(s) / "
             ~ "%d byte(s)", registrationFiles, registrationBytes));

    size_t nFiles = 0, nWithMembers = 0, nLines = 0;
    auto bad = appender!string;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/pipe-contracts/source"), buildPath(repoRoot, "packages/mesh-preview/source"), buildPath(repoRoot, "util/json-number/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
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
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);

        auto syms = enclosingSymbols(
            blankUnittestBodies(blankNonCode(readText(sourceCarrierPath))));
        nLines += syms.length;
        if (syms.length && syms[$ - 1].length)
            bad.put(format("\n    %s — the walker ended the file still inside "
                         ~ "`%s`", sourceCarrierPath[repoRoot.length + 1 .. $],
                           syms[$ - 1]));
        foreach (s; syms) if (s.canFind('.')) { ++nWithMembers; break; }

    }

    assert((bad.data.length == 0) && wave15InputsIntact(wave15Inputs), format(
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

unittest {
    enum probe = `void registerTripleCommand(Registrar)(ref Registrar registry, PilotCommandDeps deps) {
        registry.registerCommand("mesh.triple", factory);
    }
    void registerMeshSelectionCommand(Registrar)(ref Registrar registry, PilotCommandDeps deps) {
        registry.registerCommand("mesh.select", factory);
    }
    void registerHistoryNavigationCommands(Registrar)(ref Registrar registry, PilotCommandDeps deps, CommandHistory history) {
        registry.registerCommand("history.undo", factory);
        registry.registerCommand("history.redo", factory);
    }
    void registerElementSelectionCommand(Registrar)(ref Registrar registry, PilotCommandDeps deps) {
        registry.registerCommand("select.element", factory);
    }
    void registerDropSelectionCommand(Registrar)(ref Registrar registry, PilotCommandDeps deps) {
        registry.registerCommand("select.drop", factory);
    }
    void registerInvertSelectionCommand(Registrar)(ref Registrar registry, PilotCommandDeps deps) {
        registry.registerCommand("select.invert", factory);
    }`;
    assert(pilotRegistrationIds(probe) == ["mesh.triple", "mesh.select", "history.undo", "history.redo", "select.element", "select.drop", "select.invert"],
        "1D bounded pilot scanner positive");
    assert(pilotRegistrationIds(probe.replace(`registry.registerCommand("mesh.triple", factory);`,
            `/* registry.registerCommand("comment.example", factory); */ registry.registerCommand("mesh.triple", factory);`))
        == ["mesh.triple", "mesh.select", "history.undo", "history.redo", "select.element", "select.drop", "select.invert"],
        "1D bounded pilot scanner excludes comments");
    void rejected(string bad, string reason) {
        string actual;
        try { pilotRegistrationIds(bad); }
        catch (AssertError error) { actual = error.msg; }
        assert(actual.canFind(reason), "1D bounded pilot scanner named refusal: " ~ reason);
    }
    rejected(probe.replace(`"mesh.triple"`, `"mesh.select"`), "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo", factory);`,
        `registry.registerCommand(dynamicId, "history.redo", factory);`),
        "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.undo", factory);`, ``), "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo"`, `other.registerCommand("history.redo"`),
        "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo"`, `other.registry.registerCommand("history.redo"`),
        "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo"`, `other . registry . registerCommand("history.redo"`),
        "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo"`, `other /* owner */ . /* receiver */ registry.registerCommand("history.redo"`),
        "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("history.redo"`, `myregistry.registerCommand("history.redo"`),
        "exact pilot IDs and receiver");
    foreach (literal; ["` ; registry.registerCommand(\"history.redo\", `",
            `q{ ; registry.registerCommand("history.redo", }`,
            `q"[ ; registry.registerCommand("history.redo", ]"`])
        rejected(probe.replace(`registry.registerCommand("history.redo", factory);`,
            `other.registry.registerCommand("history.redo", factory); auto text = ` ~ literal ~ `;`),
            "exact pilot IDs and receiver");
    rejected(probe.replace(`registry.registerCommand("mesh.triple", factory);`,
        `registry.registerCommand("mesh.triple", factory); registry.registerCommand("mesh.triple", factory);`),
        "exact pilot IDs and receiver");
    rejected(probe ~ ` registry.registerCommand("outside.example", factory);`, "exact seven supported registration sites");
    rejected(probe[0 .. $ - 1], "balanced production body");
    rejected(probe.replace("registerTripleCommand", "registerOtherCommand"), "exact six entry identities");
    rejected(probe.replace("ref Registrar registry", "Registrar registry"), "supported template signature");
    foreach (outside; [`unittest`, `void unrelated()`])
        rejected(outside ~ " { " ~ probe ~ " }", "top-level production entry");
    foreach (inside; [`void delayed()`, `auto delayed = ()`])
        rejected(probe.replace(`registry.registerCommand("mesh.triple", factory);`,
            inside ~ ` { registry.registerCommand("mesh.triple", factory); };`),
            "exact pilot IDs and receiver");
    rejected(probe.replace(`PilotCommandDeps deps) {`, `PilotCommandDeps deps); unittest {`),
        "immediate production body");


    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.process : thisProcessID;
    const root = buildPath(tempDir, format("pilot-reader-%d", thisProcessID));
    mkdirRecurse(buildPath(root, "source"));
    scope(exit) rmdirRecurse(root);
    const directory = buildPath(root, "source");
    const commonDirectory = buildPath(root, "packages/application-core/source");
    mkdirRecurse(commonDirectory);
    const pilotPath = buildPath(commonDirectory, "pilot_command_registration.d");
    const historyPath = buildPath(directory, "history_macro_registration.d");
    enum historySource = `void registerHistoryCommands(ref Registry reg) {
        registerHistoryNavigationCommands(reg, deps, history);
    }`;
    write(buildPath(directory, "registration.d"), `registerMeshCommands(reg); registerHistoryCommands(reg); registerSelectionCommands(reg);`);
    write(buildPath(directory, "mesh_command_registration.d"), `void registerMeshCommands(ref Registry reg) {
        registerTripleCommand(reg, deps); registerMeshSelectionCommand(reg, deps);
    }`);
    write(historyPath, historySource);
    write(buildPath(directory, "selection_command_registration.d"), `void registerSelectionCommands(ref Registry reg) {
        registerElementSelectionCommand(reg, deps); registerDropSelectionCommand(reg, deps);
        registerInvertSelectionCommand(reg, deps);
    }`);
    write(pilotPath, probe);
    assert(registrationFamilyText(root).canFind("history.undo"), "1D registration reader bounded pilot positive");
    write(pilotPath, probe.replace(`"mesh.triple"`, `"mesh.select"`));
    assertThrown!AssertError(registrationFamilyText(root));
    write(pilotPath, probe);
    write(historyPath, historySource.replace("registerHistoryNavigationCommands(reg,", "registerHistoryNavigationCommands(other,"));
    assertThrown!AssertError(registrationFamilyText(root));
    foreach (outside; [`unittest`, `void unrelated()`]) {
        write(historyPath, historySource.replace(`registerHistoryNavigationCommands(reg, deps, history);`, ``)
            ~ outside ~ ` { registerHistoryNavigationCommands(reg, deps, history); }`);
        string movedMessage;
        try { registrationFamilyText(root); }
        catch (AssertError error) { movedMessage = error.msg; }
        assert(movedMessage.canFind("supported desktop reg receiver"),
            "1D desktop caller remains inside production entry");
    }
}

unittest {
    enum name = "registerHistoryNavigationCommands";
    enum entry = "registerHistoryCommands";
    string caller(string call) {
        return "void registerHistoryCommands(ref Registry reg) { " ~ call ~ " }";
    }
    requirePilotDesktopCaller(caller("registerHistoryNavigationCommands(reg, deps, history);"), name, entry);
    requirePilotDesktopCaller(caller("ref View pilotView() { return view; } "
        ~ "registerHistoryNavigationCommands(reg, deps, history);"), name, entry);
    void refused(string source, string reason) {
        string actual;
        try { requirePilotDesktopCaller(blankNonCode(source), name, entry); }
        catch (AssertError error) { actual = error.msg; }
        assert(actual.canFind(reason), "1D desktop declaration named refusal: " ~ reason);
    }
    foreach (outside; [`unittest`, `void unrelated()`])
        refused(outside ~ " { " ~ caller("registerHistoryNavigationCommands(reg, deps, history);") ~ " }",
            "top-level production entry");
    foreach (inside; [`void delayed()`, `auto delayed = ()`])
        refused(caller(inside ~ " { registerHistoryNavigationCommands(reg, deps, history); };"),
            "supported desktop reg receiver");
    refused(caller("registerHistoryNavigationCommands(other, reg, deps, history);"),
        "supported desktop reg receiver");
    refused("void registerHistoryCommands(ref Registry reg); unittest { "
        ~ "registerHistoryNavigationCommands(reg, deps, history); }", "immediate production body");
    refused("void registerHistoryCommands(ref Registry reg, void delegate() callback = () { "
        ~ "registerHistoryNavigationCommands(reg, deps, history); }) {}", "supported desktop reg receiver");
    refused("void registerHistoryCommands(ref Registry reg, void delegate() callback = () { "
        ~ "registerHistoryNavigationCommands(reg, deps, history); }", "balanced parameter group");
    refused("registerHistoryNavigationCommands(reg, deps, history); "
        ~ "void registerHistoryCommands(ref Registry reg)", "immediate production body");

    foreach (head; ["otherregisterHistoryNavigationCommands", "other.registerHistoryNavigationCommands",
            "other . registerHistoryNavigationCommands", "other /* owner */ . /* callee */ registerHistoryNavigationCommands"]) {
        string prefixedMessage;
        try { requirePilotDesktopCaller(caller(head ~ "(reg, deps, history);"), name, entry); }
        catch (AssertError error) { prefixedMessage = error.msg; }
        assert(prefixedMessage.canFind("supported desktop reg receiver"),
            "1D supported desktop caller rejects qualified or prefixed helper name");
    }
    assertThrown!AssertError(requirePilotDesktopCaller(caller("registerHistoryNavigationCommands(other, deps, history);"), name, entry));
    assertThrown!AssertError(requirePilotDesktopCaller(caller("registerHistoryNavigationCommands(reg, deps, history); registerHistoryNavigationCommands(other, deps, history);"), name, entry));
}

// Finite logical source admission for the approved body relocation. Keep each
// reader's existing roots, depth, labels and masks; carrier headers are excluded.
// Task 20262780; source/fragment custody and actual later controls are in the
// private Wave15 P execution receipt.
private struct Wave15Move { string oldPath, newPath; }
private immutable Wave15Move[] wave15Moves = [
    Wave15Move("source/ai/interaction.d", "packages/interaction-data/source/ai/interaction.d"),
    Wave15Move("source/bg_gpu_cache.d", "packages/viewport-host/source/bg_gpu_cache.d"),
    Wave15Move("source/commands/tool/attr.d", "packages/interactive-tools/source/commands/tool/attr.d"),
    Wave15Move("source/commands/tool/begin_session.d", "packages/interactive-tools/source/commands/tool/begin_session.d"),
    Wave15Move("source/commands/tool/bridge_headless.d", "packages/interactive-tools/source/commands/tool/bridge_headless.d"),
    Wave15Move("source/commands/tool/do_apply.d", "packages/interactive-tools/source/commands/tool/do_apply.d"),
    Wave15Move("source/commands/tool/headless.d", "packages/interactive-tools/source/commands/tool/headless.d"),
    Wave15Move("source/commands/tool/host.d", "packages/interactive-tools/source/commands/tool/host.d"),
    Wave15Move("source/commands/tool/lifecycle.d", "packages/interactive-tools/source/commands/tool/lifecycle.d"),
    Wave15Move("source/commands/tool/panel_edit.d", "packages/interactive-tools/source/commands/tool/panel_edit.d"),
    Wave15Move("source/commands/tool/pipe.d", "packages/interactive-tools/source/commands/tool/pipe.d"),
    Wave15Move("source/commands/tool/reset.d", "packages/interactive-tools/source/commands/tool/reset.d"),
    Wave15Move("source/commands/tool/set.d", "packages/interactive-tools/source/commands/tool/set.d"),
    Wave15Move("source/deform_magnet.d", "packages/interactive-tools/source/deform_magnet.d"),
    Wave15Move("source/display_sync.d", "packages/viewport-gpu/source/display_sync.d"),
    Wave15Move("source/drag.d", "packages/interactive-tools/source/drag.d"),
    Wave15Move("source/drag_identity.d", "packages/interactive-tools/tests/source/drag_identity.d"),
    Wave15Move("source/edit_session.d", "packages/interactive-tools/source/edit_session.d"),
    Wave15Move("source/evaluated_move_weld.d", "packages/interactive-tools/source/evaluated_move_weld.d"),
    Wave15Move("source/falloff_handles.d", "packages/interactive-tools/source/falloff_handles.d"),
    Wave15Move("source/falloff_render.d", "packages/interactive-tools/source/falloff_render.d"),
    Wave15Move("source/gizmo.d", "packages/interactive-tools/source/gizmo.d"),
    Wave15Move("source/handler.d", "packages/interactive-tools/source/handler.d"),
    Wave15Move("source/handles/arbiter.d", "packages/interactive-tools/source/handles/arbiter.d"),
    Wave15Move("source/handles/gizmo_metrics.d", "packages/interactive-tools/source/handles/gizmo_metrics.d"),
    Wave15Move("source/handles/gl_util.d", "packages/interactive-tools/source/handles/gl_util.d"),
    Wave15Move("source/handles/shapes.d", "packages/interactive-tools/source/handles/shapes.d"),
    Wave15Move("source/image_cache.d", "packages/viewport-host/source/image_cache.d"),
    Wave15Move("source/image_plane.d", "packages/viewport-host/source/image_plane.d"),
    Wave15Move("source/model_preview.d", "packages/interactive-tools/source/model_preview.d"),
    Wave15Move("source/overlay_space.d", "packages/interactive-tools/source/overlay_space.d"),
    Wave15Move("source/pipe_gizmo_host.d", "packages/interactive-tools/source/pipe_gizmo_host.d"),
    Wave15Move("source/prepared_box_param.d", "packages/interactive-tools/source/prepared_box_param.d"),
    Wave15Move("source/prepared_bridge_activation.d", "packages/interactive-tools/source/prepared_bridge_activation.d"),
    Wave15Move("source/prepared_command_wrapper_activation.d", "packages/interactive-tools/source/prepared_command_wrapper_activation.d"),
    Wave15Move("source/prepared_edge_bevel_activation.d", "packages/interactive-tools/source/prepared_edge_bevel_activation.d"),
    Wave15Move("source/prepared_edge_extend_deactivate.d", "packages/interactive-tools/source/prepared_edge_extend_deactivate.d"),
    Wave15Move("source/prepared_edge_extend_tool_activation.d", "packages/interactive-tools/source/prepared_edge_extend_tool_activation.d"),
    Wave15Move("source/prepared_edge_extrude_activation.d", "packages/interactive-tools/source/prepared_edge_extrude_activation.d"),
    Wave15Move("source/prepared_edge_slice_activation.d", "packages/interactive-tools/source/prepared_edge_slice_activation.d"),
    Wave15Move("source/prepared_edge_slice_deactivate.d", "packages/interactive-tools/source/prepared_edge_slice_deactivate.d"),
    Wave15Move("source/prepared_inherited_noop.d", "packages/interactive-tools/source/prepared_inherited_noop.d"),
    Wave15Move("source/prepared_loop_slice_activation.d", "packages/interactive-tools/source/prepared_loop_slice_activation.d"),
    Wave15Move("source/prepared_loop_slice_deactivate.d", "packages/interactive-tools/source/prepared_loop_slice_deactivate.d"),
    Wave15Move("source/prepared_mirror_activation.d", "packages/interactive-tools/source/prepared_mirror_activation.d"),
    Wave15Move("source/prepared_move_update.d", "packages/interactive-tools/source/prepared_move_update.d"),
    Wave15Move("source/prepared_param_update.d", "packages/interactive-tools/source/prepared_param_update.d"),
    Wave15Move("source/prepared_pipe_activation.d", "packages/interactive-tools/source/prepared_pipe_activation.d"),
    Wave15Move("source/prepared_poly_bevel_activation.d", "packages/interactive-tools/source/prepared_poly_bevel_activation.d"),
    Wave15Move("source/prepared_poly_extrude_activation.d", "packages/interactive-tools/source/prepared_poly_extrude_activation.d"),
    Wave15Move("source/prepared_poly_inset_activation.d", "packages/interactive-tools/source/prepared_poly_inset_activation.d"),
    Wave15Move("source/prepared_private_state.d", "packages/interactive-tools/source/prepared_private_state.d"),
    Wave15Move("source/prepared_radial_array_transition.d", "packages/interactive-tools/source/prepared_radial_array_transition.d"),
    Wave15Move("source/prepared_radial_sweep_transition.d", "packages/interactive-tools/source/prepared_radial_sweep_transition.d"),
    Wave15Move("source/prepared_record_context.d", "packages/interactive-tools/source/prepared_record_context.d"),
    Wave15Move("source/prepared_rotate_update.d", "packages/interactive-tools/source/prepared_rotate_update.d"),
    Wave15Move("source/prepared_scale_update.d", "packages/interactive-tools/source/prepared_scale_update.d"),
    Wave15Move("source/prepared_selection_profile.d", "packages/interactive-tools/source/prepared_selection_profile.d"),
    Wave15Move("source/prepared_selection_profile_image.d", "packages/interactive-tools/source/prepared_selection_profile_image.d"),
    Wave15Move("source/prepared_slice_activation.d", "packages/interactive-tools/source/prepared_slice_activation.d"),
    Wave15Move("source/prepared_slice_deactivate.d", "packages/interactive-tools/source/prepared_slice_deactivate.d"),
    Wave15Move("source/prepared_smooth_shift_activation.d", "packages/interactive-tools/source/prepared_smooth_shift_activation.d"),
    Wave15Move("source/prepared_stroke_extrude_activation.d", "packages/interactive-tools/source/prepared_stroke_extrude_activation.d"),
    Wave15Move("source/prepared_tack_activation.d", "packages/interactive-tools/source/prepared_tack_activation.d"),
    Wave15Move("source/prepared_tool_transition.d", "packages/interactive-tools/source/prepared_tool_transition.d"),
    Wave15Move("source/prepared_topology_pen_activation.d", "packages/interactive-tools/source/prepared_topology_pen_activation.d"),
    Wave15Move("source/prepared_topology_pen_deactivate.d", "packages/interactive-tools/source/prepared_topology_pen_deactivate.d"),
    Wave15Move("source/prepared_topology_pen_update.d", "packages/interactive-tools/source/prepared_topology_pen_update.d"),
    Wave15Move("source/prepared_transform_activation.d", "packages/interactive-tools/source/prepared_transform_activation.d"),
    Wave15Move("source/prepared_transform_product_activation.d", "packages/interactive-tools/source/prepared_transform_product_activation.d"),
    Wave15Move("source/prepared_vertex_bevel_activation.d", "packages/interactive-tools/source/prepared_vertex_bevel_activation.d"),
    Wave15Move("source/prepared_vertex_extrude_activation.d", "packages/interactive-tools/source/prepared_vertex_extrude_activation.d"),
    Wave15Move("source/prepared_vertex_merge_activation.d", "packages/interactive-tools/source/prepared_vertex_merge_activation.d"),
    Wave15Move("source/prepared_xfrm_activation_session.d", "packages/interactive-tools/source/prepared_xfrm_activation_session.d"),
    Wave15Move("source/prepared_xfrm_refire_state.d", "packages/interactive-tools/source/prepared_xfrm_refire_state.d"),
    Wave15Move("source/prepared_xfrm_replay.d", "packages/interactive-tools/source/prepared_xfrm_replay.d"),
    Wave15Move("source/prepared_xfrm_slot_poll.d", "packages/interactive-tools/source/prepared_xfrm_slot_poll.d"),
    Wave15Move("source/prepared_xfrm_update_boundary.d", "packages/interactive-tools/source/prepared_xfrm_update_boundary.d"),
    Wave15Move("source/prepared_xfrm_update_edit_close.d", "packages/interactive-tools/source/prepared_xfrm_update_edit_close.d"),
    Wave15Move("source/prepared_xfrm_update_tail.d", "packages/interactive-tools/source/prepared_xfrm_update_tail.d"),
    Wave15Move("source/property_panel.d", "packages/interactive-tools/source/property_panel.d"),
    Wave15Move("source/registry.d", "packages/interactive-tools/source/registry.d"),
    Wave15Move("source/snap_render.d", "packages/interactive-tools/source/snap_render.d"),
    Wave15Move("source/tool.d", "packages/interactive-tools/source/tool.d"),
    Wave15Move("source/tool_attr_bounds.d", "packages/interactive-tools/source/tool_attr_bounds.d"),
    Wave15Move("source/tool_disarm.d", "packages/interactive-tools/source/tool_disarm.d"),
    Wave15Move("source/tool_presets.d", "packages/interactive-tools/source/tool_presets.d"),
    Wave15Move("source/tools/alignment/array_tool.d", "packages/interactive-tools/source/tools/alignment/array_tool.d"),
    Wave15Move("source/tools/alignment/clone_tool.d", "packages/interactive-tools/source/tools/alignment/clone_tool.d"),
    Wave15Move("source/tools/alignment/linear_align_tool.d", "packages/interactive-tools/source/tools/alignment/linear_align_tool.d"),
    Wave15Move("source/tools/alignment/mirror.d", "packages/interactive-tools/source/tools/alignment/mirror.d"),
    Wave15Move("source/tools/alignment/radial_align_tool.d", "packages/interactive-tools/source/tools/alignment/radial_align_tool.d"),
    Wave15Move("source/tools/alignment/radial_array_tool.d", "packages/interactive-tools/source/tools/alignment/radial_array_tool.d"),
    Wave15Move("source/tools/alignment/radial_sweep_tool.d", "packages/interactive-tools/source/tools/alignment/radial_sweep_tool.d"),
    Wave15Move("source/tools/common/command_wrapper.d", "packages/interactive-tools/source/tools/common/command_wrapper.d"),
    Wave15Move("source/tools/create/arc.d", "packages/interactive-tools/source/tools/create/arc.d"),
    Wave15Move("source/tools/create/box.d", "packages/interactive-tools/source/tools/create/box.d"),
    Wave15Move("source/tools/create/capsule.d", "packages/interactive-tools/source/tools/create/capsule.d"),
    Wave15Move("source/tools/create/cone.d", "packages/interactive-tools/source/tools/create/cone.d"),
    Wave15Move("source/tools/create/create_common.d", "packages/interactive-tools/source/tools/create/create_common.d"),
    Wave15Move("source/tools/create/cylinder.d", "packages/interactive-tools/source/tools/create/cylinder.d"),
    Wave15Move("source/tools/create/pen.d", "packages/interactive-tools/source/tools/create/pen.d"),
    Wave15Move("source/tools/create/primitive_create_tool.d", "packages/interactive-tools/source/tools/create/primitive_create_tool.d"),
    Wave15Move("source/tools/create/sphere.d", "packages/interactive-tools/source/tools/create/sphere.d"),
    Wave15Move("source/tools/create/torus.d", "packages/interactive-tools/source/tools/create/torus.d"),
    Wave15Move("source/tools/create/tube.d", "packages/interactive-tools/source/tools/create/tube.d"),
    Wave15Move("source/tools/create/vertex_place.d", "packages/interactive-tools/source/tools/create/vertex_place.d"),
    Wave15Move("source/tools/deform/bend.d", "packages/interactive-tools/source/tools/deform/bend.d"),
    Wave15Move("source/tools/deform/magnet.d", "packages/interactive-tools/source/tools/deform/magnet.d"),
    Wave15Move("source/tools/deform/push.d", "packages/interactive-tools/source/tools/deform/push.d"),
    Wave15Move("source/tools/deform/smooth_shift_tool.d", "packages/interactive-tools/source/tools/deform/smooth_shift_tool.d"),
    Wave15Move("source/tools/deform/stroke_extrude_tool.d", "packages/interactive-tools/source/tools/deform/stroke_extrude_tool.d"),
    Wave15Move("source/tools/edit/bridge_tool.d", "packages/interactive-tools/source/tools/edit/bridge_tool.d"),
    Wave15Move("source/tools/edit/edge_bevel.d", "packages/interactive-tools/source/tools/edit/edge_bevel.d"),
    Wave15Move("source/tools/edit/edge_extend.d", "packages/interactive-tools/source/tools/edit/edge_extend.d"),
    Wave15Move("source/tools/edit/edge_extrude.d", "packages/interactive-tools/source/tools/edit/edge_extrude.d"),
    Wave15Move("source/tools/edit/haul_axis_latch.d", "packages/interactive-tools/source/tools/edit/haul_axis_latch.d"),
    Wave15Move("source/tools/edit/poly_bevel.d", "packages/interactive-tools/source/tools/edit/poly_bevel.d"),
    Wave15Move("source/tools/edit/poly_extrude.d", "packages/interactive-tools/source/tools/edit/poly_extrude.d"),
    Wave15Move("source/tools/edit/poly_inset_tool.d", "packages/interactive-tools/source/tools/edit/poly_inset_tool.d"),
    Wave15Move("source/tools/edit/reduce.d", "packages/interactive-tools/source/tools/edit/reduce.d"),
    Wave15Move("source/tools/edit/smooth_relax.d", "packages/interactive-tools/source/tools/edit/smooth_relax.d"),
    Wave15Move("source/tools/edit/tack.d", "packages/interactive-tools/source/tools/edit/tack.d"),
    Wave15Move("source/tools/edit/topology_pen/defs.d", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d"),
    Wave15Move("source/tools/edit/topology_pen/json.d", "packages/interactive-tools/source/tools/edit/topology_pen/json.d"),
    Wave15Move("source/tools/edit/topology_pen/package.d", "packages/interactive-tools/source/tools/edit/topology_pen/package.d"),
    Wave15Move("source/tools/edit/topology_pen/render.d", "packages/interactive-tools/source/tools/edit/topology_pen/render.d"),
    Wave15Move("source/tools/edit/topology_pen/snap_guide.d", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d"),
    Wave15Move("source/tools/edit/topology_pen/tool.d", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d"),
    Wave15Move("source/tools/edit/vert_merge_tool.d", "packages/interactive-tools/source/tools/edit/vert_merge_tool.d"),
    Wave15Move("source/tools/edit/vertex_bevel_tool.d", "packages/interactive-tools/source/tools/edit/vertex_bevel_tool.d"),
    Wave15Move("source/tools/edit/vertex_extrude_tool.d", "packages/interactive-tools/source/tools/edit/vertex_extrude_tool.d"),
    Wave15Move("source/tools/slice/edge_slice_tool.d", "packages/interactive-tools/source/tools/slice/edge_slice_tool.d"),
    Wave15Move("source/tools/slice/edge_slide.d", "packages/interactive-tools/source/tools/slice/edge_slide.d"),
    Wave15Move("source/tools/slice/loop_slice_tool.d", "packages/interactive-tools/source/tools/slice/loop_slice_tool.d"),
    Wave15Move("source/tools/slice/slice_tool.d", "packages/interactive-tools/source/tools/slice/slice_tool.d"),
    Wave15Move("source/tools/topology_step.d", "packages/interactive-tools/source/tools/topology_step.d"),
    Wave15Move("source/tools/transform/move.d", "packages/interactive-tools/source/tools/transform/move.d"),
    Wave15Move("source/tools/transform/rotate.d", "packages/interactive-tools/source/tools/transform/rotate.d"),
    Wave15Move("source/tools/transform/scale.d", "packages/interactive-tools/source/tools/transform/scale.d"),
    Wave15Move("source/tools/transform/transform.d", "packages/interactive-tools/source/tools/transform/transform.d"),
    Wave15Move("source/tools/transform/xfrm_apply.d", "packages/interactive-tools/source/tools/transform/xfrm_apply.d"),
    Wave15Move("source/tools/transform/xfrm_handles.d", "packages/interactive-tools/source/tools/transform/xfrm_handles.d"),
    Wave15Move("source/tools/transform/xfrm_item.d", "packages/interactive-tools/source/tools/transform/xfrm_item.d"),
    Wave15Move("source/tools/transform/xfrm_transform.d", "packages/interactive-tools/source/tools/transform/xfrm_transform.d"),
    Wave15Move("source/viewport.d", "packages/viewport-host/source/viewport.d"),
    Wave15Move("source/viewport_composite.d", "packages/viewport-host/source/viewport_composite.d"),
    Wave15Move("source/coord_rounding.d", "packages/interactive-tools/source/coord_rounding.d"),
    Wave15Move("source/value_drag.d", "packages/interactive-tools/source/value_drag.d"),
    Wave15Move("source/params_widgets.d", "packages/interactive-tools/source/params_widgets.d"),
    Wave15Move("source/commands/layer/xform_edit.d", "packages/editor-commands/source/commands/layer/xform_edit.d"),
    Wave15Move("source/io/doc_state.d", "packages/application-core/source/io/doc_state.d"),
    Wave15Move("source/ai/advisor.d", "packages/interaction-data/source/ai/advisor.d"),
    Wave15Move("source/ai/debug_trace.d", "packages/interaction-data/source/ai/debug_trace.d"),
    Wave15Move("source/commands/mesh/smooth.d", "packages/interactive-tools/source/commands/mesh/smooth.d"),
    Wave15Move("tests/unit/ai/advisor_test.d", "packages/interaction-data/tests/source/tests/unit/ai/advisor_test.d"),
    Wave15Move("tests/unit/ai/debug_trace_test.d", "packages/interaction-data/tests/source/tests/unit/ai/debug_trace_test.d"),
    Wave15Move("tests/unit/ai/interaction_test.d", "packages/interaction-data/tests/source/tests/unit/ai/interaction_test.d"),
    Wave15Move("tests/unit/bevel_cold_arm_param_image_test.d", "packages/interactive-tools/tests/source/tests/unit/bevel_cold_arm_param_image_test.d"),
    Wave15Move("tests/unit/camera_intrinsics_test.d", "packages/viewport-host/tests/source/tests/unit/camera_intrinsics_test.d"),
    Wave15Move("tests/unit/close_reason_table_test.d", "packages/interactive-tools/tests/source/tests/unit/close_reason_table_test.d"),
    Wave15Move("tests/unit/command_history_test.d", "packages/interactive-tools/tests/source/tests/unit/command_history_test.d"),
    Wave15Move("tests/unit/command_wrapper_result_test.d", "packages/interactive-tools/tests/source/tests/unit/command_wrapper_result_test.d"),
    Wave15Move("tests/unit/commands/mesh/edge_slide_result_builder_test.d", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/edge_slide_result_builder_test.d"),
    Wave15Move("tests/unit/commands/mesh/jitter_result_builder_test.d", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/jitter_result_builder_test.d"),
    Wave15Move("tests/unit/constraint_surface_at_test.d", "packages/interactive-tools/tests/source/tests/unit/constraint_surface_at_test.d"),
    Wave15Move("tests/unit/deform_magnet_test.d", "packages/interactive-tools/tests/source/tests/unit/deform_magnet_test.d"),
    Wave15Move("tests/unit/dirty_key_camera_stamp_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_camera_stamp_test.d"),
    Wave15Move("tests/unit/dirty_key_tool_preview_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_tool_preview_test.d"),
    Wave15Move("tests/unit/dirty_key_weightmap_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_weightmap_test.d"),
    Wave15Move("tests/unit/drag_gain_oblique_test.d", "packages/interactive-tools/tests/source/tests/unit/drag_gain_oblique_test.d"),
    Wave15Move("tests/unit/edge_slice_locate_base_test.d", "packages/interactive-tools/tests/source/tests/unit/edge_slice_locate_base_test.d"),
    Wave15Move("tests/unit/edit_session_test.d", "packages/interactive-tools/tests/source/tests/unit/edit_session_test.d"),
    Wave15Move("tests/unit/falloff_rmb_discipline_test.d", "packages/interactive-tools/tests/source/tests/unit/falloff_rmb_discipline_test.d"),
    Wave15Move("tests/unit/gesture_carrier_interface_test.d", "packages/interactive-tools/tests/source/tests/unit/gesture_carrier_interface_test.d"),
    Wave15Move("tests/unit/gesture_record_belt_test.d", "packages/interactive-tools/tests/source/tests/unit/gesture_record_belt_test.d"),
    Wave15Move("tests/unit/handles/gl_util_test.d", "packages/interactive-tools/tests/source/tests/unit/handles/gl_util_test.d"),
    Wave15Move("tests/unit/handles/shapes_test.d", "packages/interactive-tools/tests/source/tests/unit/handles/shapes_test.d"),
    Wave15Move("tests/unit/image_cache_test.d", "packages/viewport-host/tests/source/tests/unit/image_cache_test.d"),
    Wave15Move("tests/unit/image_plane_test.d", "packages/viewport-host/tests/source/tests/unit/image_plane_test.d"),
    Wave15Move("tests/unit/mesh_ops/bridge_frozen_kernel_test.d", "packages/interactive-tools/tests/source/tests/unit/mesh_ops/bridge_frozen_kernel_test.d"),
    Wave15Move("tests/unit/model_preview_test.d", "packages/interactive-tools/tests/source/tests/unit/model_preview_test.d"),
    Wave15Move("tests/unit/overlay_space_test.d", "packages/interactive-tools/tests/source/tests/unit/overlay_space_test.d"),
    Wave15Move("tests/unit/prepared_param_update_test.d", "packages/interactive-tools/tests/source/tests/unit/prepared_param_update_test.d"),
    Wave15Move("tests/unit/prepared_tool_transition_test.d", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d"),
    Wave15Move("tests/unit/quad_overlay_eligibility_test.d", "packages/interactive-tools/tests/source/tests/unit/quad_overlay_eligibility_test.d"),
    Wave15Move("tests/unit/shared_hover_record_test.d", "packages/interactive-tools/tests/source/tests/unit/shared_hover_record_test.d"),
    Wave15Move("tests/unit/tool_gesture_runopen_test.d", "packages/interactive-tools/tests/source/tests/unit/tool_gesture_runopen_test.d"),
    Wave15Move("tests/unit/tool_single_operation_equivalence_test.d", "packages/interactive-tools/tests/source/tests/unit/tool_single_operation_equivalence_test.d"),
    Wave15Move("tests/unit/toolpipe/local_component_frame_test.d", "packages/interactive-tools/tests/source/tests/unit/toolpipe/local_component_frame_test.d"),
    Wave15Move("tests/unit/tools/alignment/mirror_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/mirror_test.d"),
    Wave15Move("tests/unit/tools/alignment/radial_sweep_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/radial_sweep_tool_test.d"),
    Wave15Move("tests/unit/tools/create/arc_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/arc_test.d"),
    Wave15Move("tests/unit/tools/create/box_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/box_test.d"),
    Wave15Move("tests/unit/tools/create/create_common_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/create_common_test.d"),
    Wave15Move("tests/unit/tools/create/tube_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/tube_test.d"),
    Wave15Move("tests/unit/tools/edit/preview_topology_churn_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/preview_topology_churn_test.d"),
    Wave15Move("tests/unit/tools/edit/smooth_relax_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/smooth_relax_test.d"),
    Wave15Move("tests/unit/tools/edit/tack_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/tack_test.d"),
    Wave15Move("tests/unit/tools/edit/topology_pen/move_protocol_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/move_protocol_test.d"),
    Wave15Move("tests/unit/tools/edit/topology_pen/press_compatibility_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/press_compatibility_test.d"),
    Wave15Move("tests/unit/tools/slice/edge_slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/edge_slice_tool_test.d"),
    Wave15Move("tests/unit/tools/slice/loop_slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/loop_slice_tool_test.d"),
    Wave15Move("tests/unit/tools/slice/slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/slice_tool_test.d"),
    Wave15Move("tests/unit/tools/transform/move_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/move_test.d"),
    Wave15Move("tests/unit/tools/transform/rotate_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/rotate_test.d"),
    Wave15Move("tests/unit/tools/transform/scale_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/scale_test.d"),
    Wave15Move("tests/unit/tools/transform/transform_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/transform_test.d"),
    Wave15Move("tests/unit/topology_step_mixin_test.d", "packages/interactive-tools/tests/source/tests/unit/topology_step_mixin_test.d"),
    Wave15Move("tests/unit/viewport_plane_turn_test.d", "packages/viewport-host/tests/source/tests/unit/viewport_plane_turn_test.d"),
    Wave15Move("tests/unit/viewport_test.d", "packages/viewport-host/tests/source/tests/unit/viewport_test.d"),
    Wave15Move("tests/unit/wrapper_shift_apply_inheritance_test.d", "packages/interactive-tools/tests/source/tests/unit/wrapper_shift_apply_inheritance_test.d"),
    // Task 20262890: approved original logical inputs; independent frozen rows.
    Wave15Move("source/ai/analysis.d", "packages/ai-advisor/source/ai/analysis.d"),
    Wave15Move("source/ai/copilot_gate.d", "packages/ai-advisor/source/ai/copilot_gate.d"),
    Wave15Move("source/ai/element_candidates.d", "packages/ai-advisor/source/ai/element_candidates.d"),
    Wave15Move("source/ai/exploration.d", "packages/ai-advisor/source/ai/exploration.d"),
    Wave15Move("source/ai/interaction_log.d", "packages/ai-advisor/source/ai/interaction_log.d"),
    Wave15Move("source/ai/interaction_log_writer.d", "packages/ai-advisor/source/ai/interaction_log_writer.d"),
    Wave15Move("source/ai/mode_candidates.d", "packages/ai-advisor/source/ai/mode_candidates.d"),
    Wave15Move("source/ai/model_adapter.d", "packages/ai-advisor/source/ai/model_adapter.d"),
    Wave15Move("source/ai/offline_evaluator.d", "packages/ai-advisor/source/ai/offline_evaluator.d"),
    Wave15Move("source/ai/onnx_backend.d", "packages/ai-advisor/source/ai/onnx_backend.d"),
    Wave15Move("source/ai/ranker_schema.d", "packages/ai-advisor/source/ai/ranker_schema.d"),
    Wave15Move("source/ai/state.d", "packages/ai-advisor/source/ai/state.d"),
    Wave15Move("source/ai/support_loop_candidates.d", "packages/ai-advisor/source/ai/support_loop_candidates.d"),
    Wave15Move("source/ai/synthetic_dataset.d", "packages/ai-advisor/source/ai/synthetic_dataset.d"),
    Wave15Move("source/ai/training_dataset.d", "packages/ai-advisor/source/ai/training_dataset.d"),
    Wave15Move("source/ai3d/event_queue.d", "packages/ai3d-runtime/source/ai3d/event_queue.d"),
    Wave15Move("source/ai3d/job_controller.d", "packages/ai3d-runtime/source/ai3d/job_controller.d"),
    Wave15Move("source/ai3d/job_events.d", "packages/ai3d-runtime/source/ai3d/job_events.d"),
    Wave15Move("source/ai3d/scene_validator.d", "packages/ai3d-runtime/source/ai3d/scene_validator.d"),
    Wave15Move("source/ai3d/stage_artifact.d", "packages/ai3d-runtime/source/ai3d/stage_artifact.d"),
    Wave15Move("source/ai3d/worker_manager.d", "packages/ai3d-runtime/source/ai3d/worker_manager.d"),
    Wave15Move("source/commands/file/quit.d", "packages/document-actions/source/commands/file/quit.d"),
    Wave15Move("source/commands/image/commands.d", "packages/document-actions/source/commands/image/commands.d"),
    Wave15Move("source/commands/image_plane/commands.d", "packages/document-actions/source/commands/image_plane/commands.d"),
    Wave15Move("source/commands/layer/commands.d", "packages/document-actions/source/commands/layer/commands.d"),
    Wave15Move("source/commands/scene/load_mesh.d", "packages/document-actions/source/commands/scene/load_mesh.d"),
    Wave15Move("source/commands/scene/reset.d", "packages/document-actions/source/commands/scene/reset.d"),
    Wave15Move("source/http_server.d", "packages/http-runtime/source/http_server.d"),
    Wave15Move("source/http_transport.d", "packages/http-runtime/source/http_transport.d"),
    Wave15Move("source/io/browser_pick_resume.d", "packages/platform-file/source/io/browser_pick_resume.d"),
    Wave15Move("source/io/file_dialog.d", "packages/platform-file/source/io/file_dialog.d"),
    Wave15Move("source/io/file_dialog_browser.d", "packages/platform-file/source/io/file_dialog_browser.d"),
    Wave15Move("source/playback_controller.d", "packages/http-runtime/source/playback_controller.d"),
    Wave15Move("source/remesh/region_stitch.d", "packages/remesh-runtime/source/remesh/region_stitch.d"),
    Wave15Move("source/remesh/remesh_job.d", "packages/remesh-runtime/source/remesh/remesh_job.d"),
    Wave15Move("source/ui/discard_guard.d", "packages/platform-file/source/ui/discard_guard.d"),
    Wave15Move("source/commands/falloff.d", "packages/interactive-tools/source/commands/falloff.d"),
    Wave15Move("tests/unit/ai/analysis_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/analysis_test.d"),
    Wave15Move("tests/unit/ai/element_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/element_candidates_test.d"),
    Wave15Move("tests/unit/ai/exploration_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_test.d"),
    Wave15Move("tests/unit/ai/interaction_log_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_test.d"),
    Wave15Move("tests/unit/ai/interaction_log_writer_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_writer_test.d"),
    Wave15Move("tests/unit/ai/mode_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/mode_candidates_test.d"),
    Wave15Move("tests/unit/ai/model_adapter_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/model_adapter_test.d"),
    Wave15Move("tests/unit/ai/ranker_schema_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/ranker_schema_test.d"),
    Wave15Move("tests/unit/ai/support_loop_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/support_loop_candidates_test.d"),
    Wave15Move("tests/unit/ai/training_dataset_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/training_dataset_test.d"),
    Wave15Move("tests/unit/ai3d/event_queue_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_test.d"),
    Wave15Move("tests/unit/ai3d/job_controller_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/job_controller_test.d"),
    Wave15Move("tests/unit/ai3d/scene_validator_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/scene_validator_test.d"),
    Wave15Move("tests/unit/ai3d/stage_artifact_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/stage_artifact_test.d"),
    Wave15Move("tests/unit/ai3d/worker_manager_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_test.d"),
    Wave15Move("tests/unit/remesh/remesh_job_test.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_test.d"),
    Wave15Move("tests/unit/commands/image/commands_test.d", "packages/document-actions/tests/source/tests/unit/commands/image/commands_test.d"),
    Wave15Move("tests/unit/commands/layer/add_injection_range_test.d", "packages/document-actions/tests/source/tests/unit/commands/layer/add_injection_range_test.d"),

 ];
private struct Wave15Fragment {
    string id, origin, destination, prefix;
    size_t bytes;
    string digest;
}
private immutable Wave15Fragment[] wave15Fragments = [
    Wave15Fragment("drag:UT1", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: the gain IS the reference's own reported pixel size.\n    import std.math : PI, tan, abs;\n\n    // Our pinned pane, our hard-coded 45-degree vertical fov.\n    Viewpo", 2209, "a50d55d5bb1a2f570b88216eca30b6afa8d63d14865c7a062e6a12dd905b8098"),
    Wave15Fragment("drag:UT2", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: NO foreshortening compensation. The headline.\n    import std.math : PI, cos, abs;\n\n    auto vp = corpusViewport(corpusCams[0]);\n    // Base at the view focus, so i", 3634, "db3780863c5ef6adb301f08eb59233a6823736069b08b6a0c04776757cf1a40a"),
    Wave15Fragment("drag:UT3", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: measured from the press, and linear in the offset.\n    auto vp = corpusViewport(corpusCams[0]);\n    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);\n    Vec3 axis = Vec3(1, 0,", 3157, "cf896861ffcfe92085becbfbd87d6645fe7ca89e6d975776d6b6efabe90427ec"),
    Wave15Fragment("drag:UT4", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: THE STAIRCASE, scored on 19 reference rows.\n    import std.math : abs;\n    import std.conv : to;\n    import std.format : format;\n\n    // 1. The law, row by row, ov", 3338, "976ef7691ecca61954a88be25dc401f955d82c84f585190d0cf198a9bc5a15ea"),
    Wave15Fragment("drag:UT5", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: the ROUNDING, against the reference's own six rows.\n    import std.math : abs, floor;\n    import std.conv : to;\n    import std.format : format;\n\n    // The step th", 6698, "99eea92420f1049c46beb816808957f48a1d9fa92afac27d28477559bf214d9b"),
    Wave15Fragment("drag:UT6", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW A ported: the GATE — `None` is the exact identity.\n    import std.math : abs;\n    import std.format : format;\n\n    // The whole path has one gate and it is `step > 0`. The", 2651, "602ac03a74b5d2165403d435ed02cdcb9ec80ec0fe9a10f239942b22adbf24be"),
    Wave15Fragment("drag:UT7", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW B: the finite-difference step is a STEP, not a gain.\n    // The matrix divides by the same step it differenced with, so the step\n    // cancels to first order and a four-dec", 2338, "626a44ccd397ec32a98bd4263639bbe86842566813cd877feeb8ba60df7e30bd"),
    Wave15Fragment("drag:UT8", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW B: linear in the pixel offset => invariant in the event count.\n    // The harness asserts this across the process boundary (same total\n    // displacement at N = 1, 5, 20 mu", 904, "982c4f20eae92b687c2d142ad396cc9d418447b025eab860d0e67ec1a99c22e4"),
    Wave15Fragment("drag:UT9", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW B: under an affine projection the port IS the exact solve.\n    // Orthographic projection has no perspective divide, so the screen map is\n    // affine and its first-order l", 1129, "251faecbfedd0c18f1ee517a412ba8d8b900701d7aed059fbb67c5986a3f5a70"),
    Wave15Fragment("drag:UT10", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW B: how far the frozen linearisation is from the exact solve.\n    // The behaviour a user can feel, stated as a number rather than as \"it\n    // drifts\". Same camera, same an", 1992, "a5b59c9c0b8f3448aa644c21a2534d054f20d1085f29a5c6f64dd2922f6595b8"),
    Wave15Fragment("drag:UT13", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "unittest {  // LAW B: the result stays in the plane, whatever the in-plane basis.\n    auto vp = corpusViewport(corpusCams[3]);   // side camera, X-dominant\n    Vec3 center = Vec3(0.2f, -0.1f, ", 970, "cd39587b9969e8e80b20c9955f3f7b0a44b3f04c091404b481009b430cc8e386"),
    Wave15Fragment("drag_identity:UT1", "source/drag_identity.d", "packages/interactive-tools/tests/source/drag_identity.d", "unittest {\n    // --- cameras: near/far, oblique, near-top-down, offset viewport, ortho ---\n    Viewport[] vps = [\n        mkVp(Vec3(0,    0,   5),    Vec3(0,0,0), false, 1280, 720,  0,  0),\n ", 6084, "bd219fea3ecfc116ac26d10268b073dc6dc1f833a786906990a6baeab5e14fad"),
    Wave15Fragment("handles.arbiter:UT1", "source/handles/arbiter.d", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "unittest {\n    Viewport vp;\n    auto pool = new ToolHandles();\n    auto hovered = new EngageProbeHandle(true);\n    auto missed  = new EngageProbeHandle(false);\n\n    pool.begin();\n    pool.add(", 584, "089e41f660eb20579295928d3cad7b20afd85af05bff78c762b0b381a17dcc9d"),
    Wave15Fragment("handles.arbiter:UT2", "source/handles/arbiter.d", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "unittest {\n    Viewport vp;\n    auto pool = new ToolHandles();\n    auto grabbed = new EngageProbeHandle(false);   // pointer has moved off it\n    auto other   = new EngageProbeHandle(true);   ", 874, "345f6364967e57c76f53f6f4be629c0493334de9c9ff603c989fcbbf41c5b151"),
    Wave15Fragment("handles.arbiter:UT3", "source/handles/arbiter.d", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "unittest {\n    Viewport vp;\n    auto pool = new ToolHandles();\n    auto h = new EngageProbeHandle(true);\n\n    pool.begin();\n    pool.add(h, 7);\n    pool.setHaul(7);\n    pool.suppress();\n    po", 332, "504dceb12c4862d1addefb6e26413d8ae111d73c05c3990b3931736464b21c2c"),
    Wave15Fragment("handles.gizmo_metrics:UT1", "source/handles/gizmo_metrics.d", "packages/interactive-tools/source/handles/gizmo_metrics.d", "unittest {\n    import std.math : abs;\n\n    // Build a simple lookAt view (camera at +Z looking at origin, +Y up).\n    float[16] view = lookAt(Vec3(0, 0, 10), Vec3(0, 0, 0), Vec3(0, 1, 0));\n\n  ", 2488, "f8372bb565f9388e28d381cc626c80b7da281f0d8eaf87482cf378cba729265e"),
    Wave15Fragment("handles.gl_util:UT1", "source/handles/gl_util.d", "packages/interactive-tools/tests/source/handles/gl_util_source_cells.d", "unittest {\n    // The arrowhead is a CLOSED, CAPPED tetrahedron wound uniformly outward,\n    // and its body sits in one quadrant. Every claim below is re-derived from\n    // the emitted float", 4017, "7c6547df1390585caa354aad8c51698d4276a7ad925ebc673d966b46a121eba5"),
    Wave15Fragment("handles.shapes:UT1", "source/handles/shapes.d", "packages/interactive-tools/source/handles/shapes.d", "unittest {\n    // Task 0604 — the shaft's batch really carries a SECOND, identical segment,\n    // and `doubledShaft` really selects it.\n    //\n    // This is the pin the pixel tests cannot ", 2181, "e1591b08f6dd5ed19b0ec3d2fc90b3c3af34d04b8e9f9e56ce2c9a18599c5c57"),
    Wave15Fragment("image_plane:UT1", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    auto p = planeData();\n    ItemXform x;                       // identity: pos 0, rot 0, scl 1, pivot 0\n    auto r = place(p, 512, 256, x);\n\n    a", 1123, "b6c402bd891c334524ac4c1e28acd2735710426154baf4c87a2363cdbc696dd3"),
    Wave15Fragment("image_plane:UT2", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    import std.math   : cos, sin, PI;\n\n    auto p = planeData();\n    ItemXform x;\n    x.pos   = Vec3(1, 2, 3);\n    x.rot   = Vec3(0, 0, 30);\n    x.sc", 1820, "ed78f297d6da23408120c9951479d600fbad5fa0085c555eb5104789bdbd9b8a"),
    Wave15Fragment("image_plane:UT3", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    ItemXform x;\n    struct Row { string tok; Vec3 halfU, halfV; }\n    immutable Row[6] rows = [\n        Row(\"top\",    Vec3( 2.56f, 0, 0),      Vec3(", 1314, "b4196e7267bfcd93badf67a2ffec7a8500523dc766e0a0d8ca7616ce9b1863a2"),
    Wave15Fragment("image_plane:UT4", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    ItemXform x;\n    auto plain   = place(planeData(), 512, 256, x);\n    auto flipped = { auto p = planeData(); p.flipHorizontal = true;\n            ", 702, "93509597cd27be9ff916713d60f6f80be18cb731639c9f0951ed5f9b5434eb6d"),
    Wave15Fragment("image_plane:UT5", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    ItemXform x;\n    foreach (bad; [ImagePlaneSource.Unbound, ImagePlaneSource.Dangling,\n                   ImagePlaneSource.Missing]) {\n        auto", 1136, "4c4fd8afa1a0d4c9592e63326bc1634cae0b7174f80eb2f5d6f34b0060642ea4"),
    Wave15Fragment("image_plane:UT6", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    struct Row {\n        string label; int w, h; float p, sx, sy, sz; bool keepAspect;\n        float extU, extV;\n    }\n    immutable Row[] table = [\n", 2875, "7967c9529bc1f99752a75a7913078053c485e1f9832f9214c27735296887b9c5"),
    Wave15Fragment("image_plane:UT7", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    auto p = planeData();\n    ItemXform unit;\n    auto base = place(p, 512, 256, unit);\n\n    foreach (scl; [Vec3(3, 1, 1), Vec3(1, 3, 1)]) {\n        ", 871, "a74a95d88ca23572763fa6084abb9a150f82e604af98f9ec692fc8f870e4c353"),
    Wave15Fragment("image_plane:UT8", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    auto p = planeData();\n    p.pixelSize = float.nan;\n    ItemXform x;\n    auto r = place(p, 512, 256, x);\n    assert(r.halfU == Vec3(0, 0, 0) && r.", 1157, "572cfa90699a5b00877a2f71da545e45afd335c6fba2a2c13b23b640bd68bc9f"),
    Wave15Fragment("image_plane:UT9", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    auto p = planeData(\"right\");\n    ItemXform x;\n    x.scl = Vec3(4, 1, 0.5f);          // the P0-d case\n    auto r = place(p, 512, 256, x, ViewPres", 557, "0725a07ce9104a9182efa9aa3a92b720a97389574edeada1021054a5137a340b"),
    Wave15Fragment("image_plane:UT10", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    ItemXform x;\n    struct Row { ViewPreset cell; bool ortho; bool drawn; string why; }\n    immutable Row[] rows = [\n        Row(ViewPreset.Front, t", 1337, "279b242678ef829fab151291cdd098de16ca7ac07a2841303a0e6bf820cf89fd"),
    Wave15Fragment("image_plane:UT11", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "unittest {\n    import std.format : format;\n    Layer plane, target;\n    auto doc = planeFixture(plane, target);\n\n    ulong epoch = 0;\n    ulong h = imagePlaneDigest(doc, epoch);\n    void step(", 2579, "eb1a379a0aa887e1ac0acb56af62479265b742b5151010bcf2b63563f431bfa6"),
    Wave15Fragment("overlay_space:UT1", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // The gain is the axis's OWN scale, not the mean and not the determinant.\n    // Two wrong-but-plausible implementations this separates:\n    //   * `worldPerLocal = cbrt(|det L|)` ", 977, "fe7b723c11f54b0d1d1360828eda1e5feacdfa1ec744093cdb609ec5887d8ff0"),
    Wave15Fragment("overlay_space:UT2", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // `pos` is the FULL affine; `axis`/`toLocalDelta` are the LINEAR part.\n    // The wrong implementation this refuses is the one task 0649's\n    // `conjugate` doc warns about from t", 856, "30bc90cb71aec5dddde1bda399a49d91ac2a9f2be0f581a12dc2cb3f12d41264"),
    Wave15Fragment("overlay_space:UT3", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // toLocal / toWorld invert each other, and toLocalDelta agrees with the axis gain.\n    import std.math : abs;\n    auto os = OverlaySpace(tiltedStand());\n    auto az = os.axis(Vec3(", 700, "acee624f94fb552bfcc4e9d35b5c16b44056b732cc5ccccbb3f110a5f65f0da3"),
    Wave15Fragment("overlay_space:UT4", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // `toLocalPos` is the FULL affine inverse, not the linear one.\n    // The wrong implementation this refuses (task 0660): reusing\n    // `toLocalDelta` for a POINT, i.e. dropping th", 1838, "baf4cd303f613b3060dd64a832a10a871c24e01f58290edf839175fcf850cf6d"),
    Wave15Fragment("overlay_space:UT5", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // `rayModelSpace` honours `active`, it does not just hand out `ms`.\n    // The wrong implementation this refuses: returning `ms` unconditionally.\n    // A caller carrying a cursor ", 729, "8a0d4947631241d6fae2af4f415744210e7d8078889df004f004de870aa4301a"),
    Wave15Fragment("overlay_space:UT6", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // A degenerate axis falls back instead of producing a NaN handle.\n    ModelSpace ms = tiltedStand();\n    // Collapse Z: the third column becomes zero, so toWorldDir(z) has no\n    /", 553, "8af7addd4da2f6d15fe262c16cbb1e25e59e7a434c7f838a134ad6ecad979e78"),
    Wave15Fragment("overlay_space:UT7", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "unittest { // A non-invertible item matrix is \"no conversion\", everywhere or nowhere.\n    // The wrong implementation: convert the handle position (which needs only\n    // `m`) but not the dra", 687, "de19806500e327970e14f5c46ddffa9420483b3836de522e16b8a487bf41f850"),
    Wave15Fragment("prepared_bridge_activation:UT1", "source/prepared_bridge_activation.d", "packages/interactive-tools/tests/source/prepared_bridge_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import commands.mesh.session_edit : MeshSessionEdit;\n    import document : Layer;\n    import editmode : EditMode;\n    import math : ", 9701, "f94e25040b5cac876250899531377d1d507c1aa260df051a602fd02e34a741e1"),
    Wave15Fragment("prepared_command_wrapper_activation:UT1", "source/prepared_command_wrapper_activation.d", "packages/interactive-tools/tests/source/prepared_command_wrapper_activation_source_cells.d", "unittest {\n    import commands.mesh.vertex_position_result : VertexPositionResultBuilder;\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import mesh : makeCub", 2961, "5871291f544d482b15565fe1935ba472addaf875263ccc8375041a6ad20ab416"),
    Wave15Fragment("prepared_edge_bevel_activation:UT1", "source/prepared_edge_bevel_activation.d", "packages/interactive-tools/tests/source/prepared_edge_bevel_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_r", 5887, "e090a28e91ba1faf90a6d769acc53e1262d28cc9ab5634e6fece73258363aff5"),
    Wave15Fragment("prepared_edge_extend_deactivate:UT1", "source/prepared_edge_extend_deactivate.d", "packages/interactive-tools/tests/source/prepared_edge_extend_deactivate_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import mesh_gpu : GpuUploadOwner;\n    imp", 2720, "d2270f1159c8e908bce642c23b2488f4df200a1838d66086615870655ba116ce"),
    Wave15Fragment("prepared_edge_extend_tool_activation:UT1", "source/prepared_edge_extend_tool_activation.d", "packages/interactive-tools/tests/source/prepared_edge_extend_tool_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_r", 3809, "080e5c41c2de3276240dec924ab9fad45f09654c55b9e6ce8d453c52f6e71333"),
    Wave15Fragment("prepared_edge_extrude_activation:UT1", "source/prepared_edge_extrude_activation.d", "packages/interactive-tools/tests/source/prepared_edge_extrude_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_r", 5393, "f3cf73cf58197d8eae86e1730afaa0fc9e2c73d9fb8e9e529093bdb900f678c0"),
    Wave15Fragment("prepared_edge_slice_activation:UT1", "source/prepared_edge_slice_activation.d", "packages/interactive-tools/tests/source/prepared_edge_slice_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_record_context : Prepared", 2696, "85013d5c7ba26ade4f30331ad5fa9c059d5b21ab0adfd7ef5308f1b94b23429c"),
    Wave15Fragment("prepared_edge_slice_deactivate:UT1", "source/prepared_edge_slice_deactivate.d", "packages/interactive-tools/tests/source/prepared_edge_slice_deactivate_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import commands.mesh.session_edit : MeshSessionEdit;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu", 3083, "b54270edf8a0ed5cdfff598fd9c3a82601ee023c46354497e67d96cb72410753"),
    Wave15Fragment("prepared_inherited_noop:UT1", "source/prepared_inherited_noop.d", "packages/interactive-tools/tests/source/prepared_inherited_noop_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import mesh : Mesh;\n    import mesh_gpu : GpuMesh;\n    import prepared_record_context : PreparedRecordContext;\n    import record_obs", 5686, "890d598a16b89f90155a662064f7a3eb84aa77618cf458a5fc59821449a0d31d"),
    Wave15Fragment("prepared_loop_slice_activation:UT1", "source/prepared_loop_slice_activation.d", "packages/interactive-tools/tests/source/prepared_loop_slice_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_record_context : Prepared", 4384, "1d46605edaca9478dd5fd86554f625f927402542bd4724170d6513bb5bc75e90"),
    Wave15Fragment("prepared_loop_slice_deactivate:UT1", "source/prepared_loop_slice_deactivate.d", "packages/interactive-tools/tests/source/prepared_loop_slice_deactivate_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import commands.mesh.session_edit : MeshSessionEdit;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu", 4035, "d358f00c2fb618d7adb9c34b9d7ea54690fffcf5e99b6efefe7136afc73b3938"),
    Wave15Fragment("prepared_mirror_activation:UT1", "source/prepared_mirror_activation.d", "packages/interactive-tools/tests/source/prepared_mirror_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import document : Layer;\n    import math : Vec3;\nimport spatial : ModelSpace;\n    import mesh : makeCube;\n    import mesh_gpu : GpuM", 7913, "bfddf0718f8e84de83dfc93c7021f4efabdb918a8d1e86225e2812ee64bfaaa9"),
    Wave15Fragment("prepared_move_update:UT1", "source/prepared_move_update.d", "packages/interactive-tools/tests/source/prepared_move_update_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : Mesh, makeCube;\n    import mesh_gpu : GpuMesh;\n    import prep", 9758, "5db7a34948aeab8a1e3087ad2c6e6e6f89c2aeaae7739aee8e85ee567a64b35d"),
    Wave15Fragment("prepared_pipe_activation:UT1", "source/prepared_pipe_activation.d", "packages/interactive-tools/tests/source/prepared_pipe_activation_source_cells.d", "unittest {\n    import toolpipe.packets : ConstrainGeom;\n    import pipe_gizmo_host : PipeGizmoHost;\n\n    Pipeline pipeline;\n    auto acen = new ActionCenterStage(null, null);\n    auto axis = n", 3688, "933c970abdf0d38328b0cc84b56f6840d5145b193e44d45202686521a2fd5ec0"),
    Wave15Fragment("prepared_poly_bevel_activation:UT1", "source/prepared_poly_bevel_activation.d", "packages/interactive-tools/tests/source/prepared_poly_bevel_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3, cross;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import pre", 6047, "745a301218212aa0dc81951678ed82d28ad0708905dfd5eb3de6cbf41d727b90"),
    Wave15Fragment("prepared_poly_extrude_activation:UT1", "source/prepared_poly_extrude_activation.d", "packages/interactive-tools/tests/source/prepared_poly_extrude_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import prepared_record_context : PreparedRecordContext;\n    import prepared_", 4757, "e617a437ab49cb1f82abde093abe0fd2dcd927793c177e3ef284205c0a3a5b13"),
    Wave15Fragment("prepared_poly_inset_activation:UT1", "source/prepared_poly_inset_activation.d", "packages/interactive-tools/tests/source/prepared_poly_inset_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import prepared_record_context : PreparedRecordContext;\n    import prepared_", 3805, "016c698fa018e11eb136fd9a0987093318b0aadcd2efed435002553176259ce2"),
    Wave15Fragment("prepared_private_state:UT2", "source/prepared_private_state.d", "packages/interactive-tools/tests/source/prepared_private_state_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import commands.mesh.session_edit : MeshSessionEdit;\n    import document : Layer;\n    import editmode : EditMode;\n    import mesh_gp", 4070, "4db7980a2dac1dba481de908edcbb3fbe361bd6c6b7764be38ff69df9eae89b7"),
    Wave15Fragment("prepared_radial_array_transition:UT1", "source/prepared_radial_array_transition.d", "packages/interactive-tools/tests/source/prepared_radial_array_transition_source_cells.d", "unittest {\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import editmode : EditMode;\n    import shader : LitShader;\n    Mesh source = makeCube(); GpuMesh gpu; EditMode mode = ", 13340, "f084da843a5fa577d10fce15ee322324076247780aecd5f46a7f5508b5528bfa"),
    Wave15Fragment("prepared_radial_sweep_transition:UT1", "source/prepared_radial_sweep_transition.d", "packages/interactive-tools/tests/source/prepared_radial_sweep_transition_source_cells.d", "unittest {\n    import math : Vec3;\n    import mesh : makeCube;\n    import editmode : EditMode;\n    import shader : LitShader;\n    import prepared_record_context : PreparedRecordContext;\n    im", 20679, "bb7342eaa1195eaf5cb91e507e0f6b25b53f83a0b239b0f7d289cfa39ea0385f"),
    Wave15Fragment("prepared_record_context:UT1", "source/prepared_record_context.d", "packages/interactive-tools/tests/source/prepared_record_context_source_cells.d", "unittest {\n    import command : Command, CmdFlags;\n    import mesh : Mesh;\n    import view : View;\n    import editmode : EditMode;\n    final class C : Command {\n        private Mesh mesh_;\n   ", 3599, "d0b7bde1f5c183d77c0cee5afd8dec26dfbbb10ae2631085bbed5b1283768df6"),
    Wave15Fragment("prepared_rotate_update:UT1", "source/prepared_rotate_update.d", "packages/interactive-tools/tests/source/prepared_rotate_update_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import record_observer_hub : RecordObserverHub;\n\n    auto layer = new Lay", 1570, "c2d9132da89ec224080d7c66eb9bfc12d5e58633fcc1379b4ce55fd2a0c14fac"),
    Wave15Fragment("prepared_scale_update:UT1", "source/prepared_scale_update.d", "packages/interactive-tools/tests/source/prepared_scale_update_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import record_observer_hub : RecordObserverHub;\n\n    auto layer = new Lay", 1565, "76a48e2088306da80851fbf5cfe8298f0a585aaad81ebc7733d8b91e9be63e4a"),
    Wave15Fragment("prepared_selection_profile:UT1", "source/prepared_selection_profile.d", "packages/interactive-tools/tests/source/prepared_selection_profile_source_cells.d", "unittest {\n    import mesh : makeCube;\n    Mesh source = makeCube();\n    source.syncSelection();\n    source.selectFace(0);\n    EditMode mode = EditMode.Polygons;\n    import shader : LitShader;", 2633, "b97d89a0a31b02712a232ec880a3eabcfd8226db4bfc1a90cdb2429754b0ebba"),
    Wave15Fragment("prepared_slice_activation:UT1", "source/prepared_slice_activation.d", "packages/interactive-tools/tests/source/prepared_slice_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_record_context : Prepared", 3999, "153b43d9e68ef5af89acf85856ce6e4ad13d304f164d57cbd6c78cb8ba048802"),
    Wave15Fragment("prepared_slice_deactivate:UT1", "source/prepared_slice_deactivate.d", "packages/interactive-tools/tests/source/prepared_slice_deactivate_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import commands.mesh.session_edit : MeshSessionEdit;\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu", 2450, "4ae7591c0a742e7231bc52976cd15747f4b6559cf5c8a9c620ac1b6480360af8"),
    Wave15Fragment("prepared_smooth_shift_activation:UT1", "source/prepared_smooth_shift_activation.d", "packages/interactive-tools/tests/source/prepared_smooth_shift_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3, cross;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import pre", 6656, "2a5352e523cf43715f7afe6c753203c72dece33e612a939c66c468ea2b92eb68"),
    Wave15Fragment("prepared_stroke_extrude_activation:UT1", "source/prepared_stroke_extrude_activation.d", "packages/interactive-tools/tests/source/prepared_stroke_extrude_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import mesh : Mesh, makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_record_context : PreparedRecordContext;\n    import ", 4160, "08033b4929a8f018c2443fa7b16274eb9db238f9296e85477a1ecb82df5e77a5"),
    Wave15Fragment("prepared_tack_activation:UT1", "source/prepared_tack_activation.d", "packages/interactive-tools/tests/source/prepared_tack_activation_source_cells.d", "unittest {\n    import editmode : EditMode;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import mesh_gpu : GpuCreateOwner;\n    import prepared_record_context : PreparedRecordC", 6952, "d235252f9533cfb8a3afa781c3b61c8fbdea75c88865a0b78cb22a6374af102a"),
    Wave15Fragment("prepared_topology_pen_activation:UT1", "source/prepared_topology_pen_activation.d", "packages/interactive-tools/tests/source/prepared_topology_pen_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import popup_state : getStatePath;\n    import prepared_record_context : PreparedRecordContext;\n    import prepared_tool_effect : Pre", 5839, "780eef21a9c3e57d4636ecb7012f53496ed6cb1bba4348a0d7ce9ae7821aeee5"),
    Wave15Fragment("prepared_topology_pen_deactivate:UT1", "source/prepared_topology_pen_deactivate.d", "packages/interactive-tools/tests/source/prepared_topology_pen_deactivate_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import prepared_tool_effect : PreparedDeactivateKind;\n    import record_observer_hub : RecordObserverHub;\n\n    auto savedPipe = g_pi", 1289, "4dc134736dbd9ce682838b092f745eb4a75fcb8ac58f4ad3bbdc228715d35751"),
    Wave15Fragment("prepared_topology_pen_update:UT1", "source/prepared_topology_pen_update.d", "packages/interactive-tools/tests/source/prepared_topology_pen_update_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import prepared_record_context : PreparedRecordContext;\n    import record_observer_hub : RecordObserverHub;\n    import toolpipe.pack", 1782, "1ed0f00f9fcd9faf005e05a6a3836121a8ad631ccfc907e66166dce0f96b5ee0"),
    Wave15Fragment("prepared_transform_activation:UT1", "source/prepared_transform_activation.d", "packages/interactive-tools/tests/source/prepared_transform_activation_source_cells.d", "unittest {\n    import mesh : Mesh, makeCube;\n    import mesh_gpu : GpuMesh;\n    import editmode : EditMode;\n    import prepared_record_context : PreparedRecordContext;\n    import command_histo", 7725, "ba7493f87aec60b60455222dc40f19ff0a6937c47c39b9a8eb327a48741c486d"),
    Wave15Fragment("prepared_transform_product_activation:UT1", "source/prepared_transform_product_activation.d", "packages/interactive-tools/tests/source/prepared_transform_product_activation_source_cells.d", "unittest {\n    import mesh : Mesh, makeCube;\n    import mesh_gpu : GpuMesh;\n    import editmode : EditMode;\n    import math : Vec3;\n    import prepared_record_context : PreparedRecordContext;\n", 7894, "b18100fcc93ed0c40db8ed5c47d37a609013bc9fac06c20c2d4f333d0d4b066d"),
    Wave15Fragment("prepared_vertex_bevel_activation:UT1", "source/prepared_vertex_bevel_activation.d", "packages/interactive-tools/tests/source/prepared_vertex_bevel_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import prepared_r", 5531, "d7b44247fad19d6b413cf3c49c340039a9f7bb05ba9b0c7095a5c3839a1a57db"),
    Wave15Fragment("prepared_vertex_extrude_activation:UT1", "source/prepared_vertex_extrude_activation.d", "packages/interactive-tools/tests/source/prepared_vertex_extrude_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3, cross;\n    import mesh : makeCube;\n    import mesh_gpu : GpuMesh;\n    import pre", 5811, "1d4341cd9c02789f3acc97415c3d13fcda3434b74d88d187329755dedc1d14b1"),
    Wave15Fragment("prepared_vertex_merge_activation:UT1", "source/prepared_vertex_merge_activation.d", "packages/interactive-tools/tests/source/prepared_vertex_merge_activation_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import prepared_record_context : PreparedRecordContext;\n    import prepared_", 3843, "c6b117305c387d1e95479e6ae76e23a787fda3588f538fc4e5dfaaaf61f5d1c4"),
    Wave15Fragment("prepared_xfrm_activation_session:UT1", "source/prepared_xfrm_activation_session.d", "packages/interactive-tools/tests/source/prepared_xfrm_activation_session_source_cells.d", "unittest {\n    import command_history : CommandHistory;\n    import editmode : EditMode;\n    import math : Vec3;\n    import mesh : Mesh, makeCube;\n    import mesh_gpu : GpuMesh;\n    import prep", 10309, "a927679e02e5e8902cbc9a477dc82e6f52baf6777b64bdc8ab83d27670297678"),
    Wave15Fragment("registry:UT2", "source/registry.d", "packages/interactive-tools/tests/source/registry_source_cells.d", "unittest {\n    // The prepared descriptor owns every variable buffer.  A shallow AA dup\n    // passes value-only tests, so mutate all three producer buffers after the\n    // copy; this is the ", 663, "f4f021d1b0a7e7167f3aeb44a4b5f7f51f7da8096cf61a28329b17ff72363fb4"),
    Wave15Fragment("snap_render:UT1", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_cells.d", "unittest {\n    auto owner = new SnapOverlayOwner();\n    SnapResult seeded; seeded.snapped = true; seeded.targetIndex = 17;\n    publishLastSnap(seeded);\n    assert(owner.beginClear());\n    asse", 669, "f361bee5b7618c40b40a91d0135388891b56285d5a7f264aae674a2fb023d5f0"),
    Wave15Fragment("snap_render:UT2", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_cells.d", "unittest { // 0619: the highlighted VERTEX is marked where it is drawn.\n    auto saved = primaryModelSpaceResolver;\n    scope (exit) primaryModelSpaceResolver = saved;\n    t0619InstallPrimary(", 1743, "3f92d667b6d82584487706bc66ea0f551e78ec1175d609807d2e8034641f6ef1"),
    Wave15Fragment("snap_render:UT3", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_cells.d", "unittest { // 0619: the highlighted EDGE is marked where it is drawn.\n    auto saved = primaryModelSpaceResolver;\n    scope (exit) primaryModelSpaceResolver = saved;\n    t0619InstallPrimary();", 1777, "b90d4a1ff0ee5ad43b1bb47b865be7b7a88726dfc35d02e9c0eb073e54a9db29"),
    Wave15Fragment("snap_render:UT4", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_cells.d", "unittest { // 0619: the highlighted FACE outline follows the drawn corners.\n    auto saved = primaryModelSpaceResolver;\n    scope (exit) primaryModelSpaceResolver = saved;\n    t0619InstallPrim", 1213, "9c5eea5b183023d27001cd2f3e08aaf921ca9ff8622a2cb21118faa410a5f1d5"),
    Wave15Fragment("snap_render:UT5", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_helpers.d", "unittest { // 0619: a BACKGROUND source is marked through ITS OWN space.\n    // THE POINT OF THE SLOT MACHINERY. `snapSourceSpace` and the\n    // `targetSource >= 1` arm of `snapHighlightPixel", 4668, "f087c6350817bfaeaf53fc86df569b424257dd0a7861cc5d9e5a52a86b100bd6"),
    Wave15Fragment("tool_disarm:UT1", "source/tool_disarm.d", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d", "unittest {\n    // Uninstalled: a no-op that reports nothing, and CLEARS a stale record.\n    g_lastDisarm = DisarmOutcome(true, 3, true, DisarmMode.cancelAndDrop);\n    g_disarmActiveTool = null", 812, "5cb31fbf40858004e3c84e0e44cf695bb5b21321effbb1fa1b5ddddc2dd8a2cd"),
    Wave15Fragment("tool_disarm:UT2", "source/tool_disarm.d", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d", "unittest {\n    // A gesture that cancels in one step: recorded as one step, not armed.\n    bool armed = true;\n    g_disarmActiveTool = (DisarmMode) {\n        DisarmOutcome o;\n        o.hadTool", 779, "7dcf1ad936086f32777c5dbc659617dc1c5376948ab077a17456074b1503b882"),
    Wave15Fragment("tool_disarm:UT3", "source/tool_disarm.d", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d", "unittest {\n    // THE CAP IS REAL, and this is the cell that shows it: a tool whose cancel\n    // NEVER clears must not spin. Without the `< kMaxDisarmSteps` term this\n    // loop does not ter", 947, "f10b3f264dc40a681a1bdf8bf7ea204ff9833494672696a5a91d41a620023362"),
    Wave15Fragment("tool_disarm:UT4", "source/tool_disarm.d", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d", "unittest {\n    // A live edit is the population floor: without it, zero cancel calls says\n    // only that there was nothing for dropOnly to preserve.\n    bool armed = true;\n    int cancelStep", 1056, "2ba13c2d50d10af4027e254601687f449793fbc0a51e6e1974ebb6f7a9eb6bc2"),
    Wave15Fragment("tool_presets:UT1", "source/tool_presets.d", "packages/interactive-tools/tests/source/tool_presets_source_cells.d", "unittest {\n    import toolpipe.attr_cache : PipelineAttrCache, kToolNode;\n    PipelineAttrCache cache;\n    char[] producerName = \"label\".dup;\n    char[] producerValue = \"owned-value\".dup;\n    ", 825, "12c0c703ac34dafdde8f745b548d7eb08e14d0a1c1467dca80f0a9235133b6e7"),
    Wave15Fragment("tools.alignment.mirror:UT1", "source/tools/alignment/mirror.d", "packages/interactive-tools/source/tools/alignment/mirror.d", "unittest {\n    Mesh owned;\n    auto tool = new MirrorTool(() => &owned, null, LitShader.init);\n    tool.engaged = false; tool.havePreviewCache = true;\n    auto prepared = tool.prepareParamStat", 809, "4cad9917792b7644e7c6159eabc99db500d847e423182b041a619816d4324bc7"),
    Wave15Fragment("tools.create.arc:UT1", "source/tools/create/arc.d", "packages/interactive-tools/source/tools/create/arc.d", "unittest {\n    Mesh owned;\n    auto tool = new ArcTool(() => &owned, null, LitShader.init);\n    tool.state = ArcState.Drawing;\n    auto prepared = tool.prepareIdleState();\n    assert(tool.stat", 720, "eba247176d32451494a5f37c5bd166303261967892bd05822afaa313eb4fda02"),
    Wave15Fragment("tools.create.box:UT1", "source/tools/create/box.d", "packages/interactive-tools/source/tools/create/box.d", "unittest {\n    import record_observer_hub : RecordObserverHub;\n    import mesh_gpu : GpuMesh;\n    Layer layer = new Layer();\n    GpuMesh sceneGpu;\n    auto box = new BoxTool(() => &layer.meshR", 836, "d1febfbbd86ccec6929d087bfceec4f228d248e6aa83f63243c0c7dc0aa9123c"),
    Wave15Fragment("tools.create.create_common:UT1", "source/tools/create/create_common.d", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d", "unittest { // ortho: the in-plane answer is the click, NOT the click times distance\n    import std.math : abs, tan, PI;\n\n    immutable float dist = 3.0f;\n    immutable Vec3  focus = Vec3(0, 0,", 1587, "56c443548c56eb2743a827033dc993d119dba5bba527cb5d14e571eab26459a3"),
    Wave15Fragment("tools.create.create_common:UT2", "source/tools/create/create_common.d", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d", "unittest { // ortho: the plane's DEPTH is the focus snapped to q (K-W2 finding 2)\n    import std.math : abs;\n    // Focus depth OFF the q lattice; `placementPlaneHit` is UNQUANTISED, so\n    //", 953, "2c68975385f80efa5344f994673fca52a6b83cef621470ea284b45bbec7ecbaf"),
    Wave15Fragment("tools.create.create_common:UT3", "source/tools/create/create_common.d", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d", "unittest { // the placement click is TOTAL where the old floor plane refused\n    import std.math : abs;\n    import spatial : screenPointToRay;\n\n    immutable float dist  = 3.0f;\n    // The foc", 2350, "bad7d1c65291ab89716bed3741fd9df2b4ba0ef212834cb8a6978c20f776d82e"),
    Wave15Fragment("tools.create.sphere:UT1", "source/tools/create/sphere.d", "packages/interactive-tools/source/tools/create/sphere.d", "unittest {\n    // The base choosePlane reads the pinned basis and keeps its unsigned normal.\n    import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;\n    import toolpipe.stages.workplane : W", 2990, "358c1b64f050939c225cd0bad08386c64f2b2a3ca875ddb560231ff2af23e785"),
    Wave15Fragment("tools.edit.bridge_tool:UT1", "source/tools/edit/bridge_tool.d", "packages/interactive-tools/source/tools/edit/bridge_tool.d", "unittest {\n    Mesh owned;\n    auto tool = new BridgeTool(() => &owned, null, LitShader.init, null);\n    tool.engaged = false;\n    auto prepared = tool.prepareParamState(\"segments\");\n    asser", 589, "06265a66d3547c0af73013ed08a14a04b43edf4f59ae9909048a5738446b6067"),
    Wave15Fragment("tools.edit.bridge_tool:UT2", "source/tools/edit/bridge_tool.d", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d", "unittest { // Polygon mode, spans=1: remove=true/false are bit-exact both\n           // states (task 0357 Remove Polygons requirement).\n    Mesh m1 = makeTwoCapMesh();\n    m1.selectFace(0);\n  ", 1501, "4fcdbada7427f9bcd145c1adc1268e53bdd062408a7c08ff576d5aebbd0f20b6"),
    Wave15Fragment("tools.edit.bridge_tool:UT3", "source/tools/edit/bridge_tool.d", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d", "unittest { // Edge mode: remove=true generalizes to deleting a face that\n           // happens to be exactly bounded by a bridged loop (task 0357\n           // closes the \"edge-mode never remo", 1553, "7efbbbb297dad562d9aeb8ebf307c4710458e1c16687cdee6fb2a649ebbd6a16"),
    Wave15Fragment("tools.edit.bridge_tool:UT4", "source/tools/edit/bridge_tool.d", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d", "unittest { // rebuildBridgePreview is NON-CUMULATIVE — 5 repeat calls land\n           // on the identical vertex/face count (mirrors tools/mirror.d's\n           // / tools/tack.d's own non-c", 1454, "63335d3f278e4aa3b35d205765c5816ccc13b0a315e2d7f2706370f18dee06cd"),
    Wave15Fragment("tools.edit.edge_extend:UT1", "source/tools/edit/edge_extend.d", "packages/interactive-tools/tests/source/tools/edit/edge_extend_source_cells.d", "unittest {\n    import record_observer_hub : RecordObserverHub;\n\n    auto layer = new Layer(); layer.meshRef() = makeCube();\n    GpuMesh gpu; EditMode mode = EditMode.Edges;\n    auto tool = new", 1034, "2de1732040d7120b6a7f661fc5b33fc1cac7e15e997121760c4fda7e86f28d01"),
    Wave15Fragment("tools.transform.transform:UT1", "source/tools/transform/transform.d", "packages/interactive-tools/source/tools/transform/transform.d", "unittest {\n    import record_observer_hub : RecordObserverHub;\n    import command : Command, CmdFlags;\n    import view : View;\n    final class PreparedProbeCommand : Command {\n        private ", 6624, "396f828d723b5636fa9147c6c3de7a31cbb7401ed4f046c94bdeb2372a79d554"),
    Wave15Fragment("commands.layer.xform_edit:UT1", "source/commands/layer/xform_edit.d", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d", "unittest { // mergeRunTail: single target, first-touch before + latest after.\n    Mesh mesh;\n    View view = new View(0, 0, 1, 1);\n    auto layer = new Layer();\n\n    auto c1 = new LayerXformEd", 882, "e72fb290588a7bf9b56756b734cdef357e67c9b4707b86bb1b9420f965d4c283"),
    Wave15Fragment("commands.layer.xform_edit:UT2", "source/commands/layer/xform_edit.d", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d", "unittest { // mergeRunTail: two targets unioned by Layer IDENTITY.\n    Mesh mesh;\n    View view = new View(0, 0, 1, 1);\n    auto layerA = new Layer();\n    auto layerB = new Layer();\n\n    // Ge", 1662, "f912c2603f03e67230327092fb846679c355a8533adab29cb2cdb0e0a0bf7828"),
    Wave15Fragment("commands.layer.xform_edit:UT3", "source/commands/layer/xform_edit.d", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d", "unittest { // apply()/revert() write the WHOLE xform, both directions.\n    Mesh mesh;\n    View view = new View(0, 0, 1, 1);\n    auto layer = new Layer();\n    layer.xform = xf(5);\n\n    auto cmd", 433, "0fa7e5d96149bcc467080c011ced6966ef4cf3016d9897440cd6460ecb408252"),
    Wave15Fragment("drag:helper1", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_cells.d", "version (unittest) {\n    // The two reference cameras of the pixel-size read, verbatim: each row is\n    // the eye distance and the pixel size the REFERENCE ITSELF reported for\n    // that vie", 4047, "e2429771031414dd461ae663e3e88f28123c1e7d13618283f0640248b50260de"),
    Wave15Fragment("drag:helper2", "source/drag.d", "packages/interactive-tools/tests/source/drag_source_helpers.d", "version (unittest) {\n    import std.math : PI, sin, cos, tan;\n\n    // The cameras the cross-engine drag corpus actually runs, in our own\n    // terms. `az`/`el`/`dist` came out of the corpus h", 2293, "d11cf6ecbfd3812c5c198678fb408101b6b0a9314511542ef13c3a625e1cfef5"),
    Wave15Fragment("handles.arbiter:helper3", "source/handles/arbiter.d", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "version (unittest) {\n    private class EngageProbeHandle : Handler {\n        bool hits;\n        this(bool hits) { this.hits = hits; }\n        override protected bool hitTest(int mx, int my, co", 257, "968ef29f31df1881d9808640af11216448835f02614a56df891dbc86e0989699"),
    Wave15Fragment("image_plane:helper4", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "version (unittest) {\n    import document : ItemKind, ImageData, ImagePlaneData;\n\n    /// [mesh, clipA, clipB(middle target), clipC, plane] — three clips, the\n    /// plane bound to the MIDDL", 1579, "5556c7308a9e92b9bd536f62a197beadd30b1a89fd202bc70b96408c70de1ba8"),
    Wave15Fragment("image_plane:helper5", "source/image_plane.d", "packages/viewport-host/tests/source/image_plane_source_cells.d", "version (unittest) {\n    private bool near(float a, float b, float tol = 1e-4f) {\n        import std.math : abs, isFinite;\n        return isFinite(a) && isFinite(b) && abs(a - b) <= tol;\n    }", 1344, "1b97784f3dc2ab2c149f3501ba3a02407add7f70f725c8eaebb4dd8cee2021ce"),
    Wave15Fragment("snap_render:helper6", "source/snap_render.d", "packages/interactive-tools/tests/source/snap_render_source_helpers.d", "version (unittest) {\n    import math     : lookAt, perspectiveMatrix, transformPoint;\n    import document : ItemXform, primaryModelSpaceResolver;\n    import std.format : format;\n\n    // Delibe", 5384, "1ae5ceb2b775d10ce840c7776c2774539e318ff2678937f7c4979a0d228895d1"),
    Wave15Fragment("tool_presets:helper7", "source/tool_presets.d", "packages/interactive-tools/tests/source/tool_presets_source_cells.d", "version (unittest) {\n    // Tiny ParamProvider fake — one float param — so the restore mechanism\n    // is testable without a GL-heavy real Tool. Records the names\n    // `onParamChanged` ", 752, "9dd00e7b6e793887c9f691191f3a036bded4e12f458187d6c1265a6bf56173c1"),
    Wave15Fragment("commands.layer.xform_edit:helper8", "source/commands/layer/xform_edit.d", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d", "version (unittest) {\n    import math : Vec3;\n    private ItemXform xf(float px) {\n        ItemXform x;\n        x.pos = Vec3(px, 0, 0);\n        return x;\n    }\n}", 160, "57a18df95208ea9467aaa950d87334bcda2ef5dabf59f2d93d98aee268f53603"),
    Wave15Fragment("overlay_space:helper9", "source/overlay_space.d", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "version (unittest) private ModelSpace tiltedStand() {\n    // Translation + rotation about Z + a DIFFERENT scale on all three axes,\n    // built by hand so the test does not depend on document.", 1117, "9fd022d82e1239ceaf71737372375010ddd0a2161d1b69bac1ea5bbf8c17b8de"),
    Wave15Fragment("tools.create.create_common:helper10", "source/tools/create/create_common.d", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d", "// ---------------------------------------------------------------------------\n// workplaneCursorPlaneHit — the ortho arm, and the equality that makes it the\n// ported law rather than a seco", 1288, "1977aa3f34bda186f7286a99dd33c3999a0e84350aa5d6c9e43defc4b2fa24dc"),
    Wave15Fragment("tools.edit.bridge_tool:helper11", "source/tools/edit/bridge_tool.d", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d", "// ---------------------------------------------------------------------------\n// Module unittests — dubtest-lane parity + regression gate (task 0357).\n// CPU-only (plain Mesh, no GpuMesh/GL", 1340, "3ad0b39f64447da293ed70307ffef371eaed312f3c0f5afd85a39484c72292c2"),
    // Task 20262890: approved original logical inputs; independent frozen rows.
    Wave15Fragment("ai.exploration:UT1", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // state machine: retry-different → Emit with re-grabbed label\n    auto ctrl = new AiExplorationController(1.0f, 1u);\n\n    // Build a record with 2 candidates; grabbed i", 1182, "a36bd221f2611551bcb2ff80c95bb424d44b22c8133f144172671685fb3f21bd"),
    Wave15Fragment("ai.exploration:UT2", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // state machine: same-handle retry → discard\n    auto ctrl = new AiExplorationController(1.0f, 2u);\n\n    auto rec  = _makeTestRecord([\"handle:0\", \"handle:10\"], 1);\n    ", 651, "66b92114ba80807bb838b6d67387e8abe21cab78c92f58d9414726c9ccbd7144"),
    Wave15Fragment("ai.exploration:UT3", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // state machine: camera-move → discard\n    auto ctrl = new AiExplorationController(1.0f, 3u);\n\n    auto rec  = _makeTestRecord([\"handle:0\", \"handle:10\"], 1);\n    string", 631, "da2c7b9c243170fe3931fa13b9fc7482dfb6e820e962805d6ef64ed79e20a283"),
    Wave15Fragment("ai.exploration:UT4", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // state machine: abandon (no regrab, discard explicitly)\n    auto ctrl = new AiExplorationController(1.0f, 4u);\n\n    auto rec  = _makeTestRecord([\"handle:0\", \"handle:10", 442, "a13d4f3b46463b69c6785d5e24f9dbb210c2651219148012c6021982287d7336"),
    Wave15Fragment("ai.exploration:UT5", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // state machine: camera move BEFORE undo → discard\n    auto ctrl = new AiExplorationController(1.0f, 5u);\n\n    auto rec  = _makeTestRecord([\"handle:0\", \"handle:10\"], 1)", 543, "291c3a923c4f98dbf36c253a460c438d030554532dcc96f89f716c3aff6c1b03"),
    Wave15Fragment("ai.exploration:UT6", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "unittest { // Emit record passes exportAiTrainingDatasetJsonl with labeled==1\n    import ai.training_dataset : exportAiTrainingDatasetJsonl;\n\n    auto ctrl = new AiExplorationContr", 1206, "f775369107cf5b7c2e7449e6086fa5580576ed913a3ef5965e85aff32da30f95"),
    Wave15Fragment("ai3d.event_queue:UT1", "source/ai3d/event_queue.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "unittest {\n    // Coalescing: two status events for the same {jobId,generation} collapse\n    // to the latest one.\n    auto q = new Ai3dEventQueue();\n    q.push(statusEv(\"job1\", 1,", 456, "ec4254bb1319ae519caa06e8924f1109d6e1703a9cfdce38dcb785d4ecdc1080"),
    Wave15Fragment("ai3d.event_queue:UT2", "source/ai3d/event_queue.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "unittest {\n    // Distinct jobs/generations do not coalesce with each other.\n    auto q = new Ai3dEventQueue();\n    q.push(statusEv(\"jobA\", 1, 0.1));\n    q.push(statusEv(\"jobB\", 1,", 369, "fed6def8da8fa3d9d147c079dc0919a36c6aa794b9b2babacc79808c6695b1c4"),
    Wave15Fragment("ai3d.event_queue:UT3", "source/ai3d/event_queue.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "unittest {\n    // Retention: a terminal/error event is never coalesced away by a status\n    // event that shares its jobId but NOT its generation (a late update from\n    // a stale", 808, "b488e0ef2a461cebf40a645269a05294c13a4b6be8cda6565a6895b0ff3725e0"),
    Wave15Fragment("ai3d.event_queue:UT4", "source/ai3d/event_queue.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "unittest {\n    // LOAD-BEARING, genuine two-thread proof: drain() must invoke the\n    // delegate LOCK-FREE (copy the pending events under the mutex, release\n    // it, THEN invoke", 2960, "a57363bd2044d2919fcd02b9bba3c4554441442380cb6e26f29e10d353dd2bb2"),
    Wave15Fragment("ai3d.worker_manager:UT1", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"roundtrip\");\n    scope(exit) cleanScratchDir(dir);\n    const path = buildPath(dir, \"ai3d.json\");\n\n    Ai3dInstallConfig c;\n    c.installed", 802, "74b56ecd5eefe933bba16d5eaf631b4d321eb57eb9f7f6c631c071acca36cf7e"),
    Wave15Fragment("ai3d.worker_manager:UT2", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"missing\");\n    scope(exit) cleanScratchDir(dir);\n    auto c = loadAi3dConfig(buildPath(dir, \"does_not_exist.json\"));\n    assert(c.installe", 234, "a1cb46975a9bf0ca8e7e09bae09924f0cfcf8c62fb8be9ca7a7b51c5992322e0"),
    Wave15Fragment("ai3d.worker_manager:UT3", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"malformed\");\n    scope(exit) cleanScratchDir(dir);\n    const path = buildPath(dir, \"ai3d.json\");\n    write(path, \"{ not json ]]\");\n    aut", 243, "b0a363f246f6785bc9aeaa537090b05eb9ff7dce5409645325d7c6b9e26bd73b"),
    Wave15Fragment("ai3d.worker_manager:UT4", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"badport\");\n    scope(exit) cleanScratchDir(dir);\n    const path = buildPath(dir, \"ai3d.json\");\n    write(path, `{\"version\":1,\"installed\":t", 357, "137b859a8f4a2f56e214e93c7a9042279bee7a493c403d618cae5944f8815366"),
    Wave15Fragment("ai3d.worker_manager:UT5", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"nullcache\");\n    scope(exit) cleanScratchDir(dir);\n    const path = buildPath(dir, \"ai3d.json\");\n\n    Ai3dInstallConfig c;\n    c.installed", 466, "2fe91013416e8a53713307ee112531c474c410c296f5f041a647bfce71c0ec38"),
    Wave15Fragment("ai3d.worker_manager:UT7", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"state\");\n    scope(exit) cleanScratchDir(dir);\n    const path = buildPath(dir, \"ai3d.json\");\n\n    auto mgr = new Ai3dWorkerManager(path);\n", 1052, "cca5866f75b47e7ed3b91f9ac309c97846b66234ba25394af25b55d96fc95e7c"),
    Wave15Fragment("ai3d.worker_manager:UT8", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    auto dir = makeScratchDir(\"modelcache\");\n    scope(exit) cleanScratchDir(dir);\n\n    assert(resolveModelCacheDir(dir) == dir, \"explicit override wins\");\n\n    assert(!", 860, "34c54cd84fe826b6098fc347c82181e718e7963641c37db4e7bbfc1b66ab087c"),
    Wave15Fragment("ai3d.worker_manager:UT9", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "unittest {\n    // Editor worker lifecycle (task 0403): spawn -> health -> kill, driven\n    // through the worker's `fake` backend (no torch/GPU/model -- a\n    // deterministic cann", 3459, "0fd243852c17160fbfe7f5db015d0106d0a49dcd4e05cda685ba8cf0f86ee1a9"),
    Wave15Fragment("commands.layer.commands:UT6", "source/commands/layer/commands.d", "packages/document-actions/tests/source/tests/unit/commands/layer/commands_source_public_test.d", "unittest {\n    import mesh : makeCube;\n\n    auto doc = Document.bootstrap(makeCube());\n    auto meshA = doc.layers[0];\n\n    auto added = new Layer;\n    added.name    = \"Empty\";\n   ", 1738, "afb8a2f3143d34761af37ccf3f04fe8edeb0eb538e7a1454331047e40c447e4c"),
    Wave15Fragment("commands.layer.commands:UT9", "source/commands/layer/commands.d", "packages/document-actions/tests/source/tests/unit/commands/layer/commands_source_public_test.d", "unittest {\n    import mesh : makeCube;\n\n    auto doc = Document.bootstrap(makeCube());\n    auto meshA = doc.layers[0];\n    auto meshB = new Layer; meshB.name = \"MeshB\"; meshB.meshR", 1107, "f3433f245dd37a634c16ba1317d661c8776f6205d661756bc36e846e10a6334a"),
    Wave15Fragment("remesh.remesh_job:UT5", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Full RemeshJob lifecycle (success / failure / cancel), driven through\n    // VIBE3D_AUTOREMESHER_BIN pointed at tiny throwaway shell scripts —\n    // never the re", 4313, "4cf9918647c3d99f2a35512713fe3569dfc64dca776e86d315708b3cbd2c4607"),
    Wave15Fragment("remesh.remesh_job:UT6", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Region mode (task 0385): start()'s selection-mask path, driven end to\n    // end through a FAKE `autoremesher_cli` (never the real, heavy,\n    // environment-spec", 7172, "a15542e40e4500c81cb1cef0f4a1e26f49eb5cfcacf8490cf6acacfd5a3c08ab"),
    Wave15Fragment("remesh.remesh_job:UT7", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Region mode: a selection covering EVERY face is equivalent to no\n    // selection at all (nothing left to \"keep\") -- must take the ORIGINAL\n    // whole-mesh path", 2457, "4a0f40f511bde46ad51aa9fd368ffa98c37e6804d0af98d78c9f392b6f5941ea"),
    Wave15Fragment("remesh.remesh_job:UT8", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Task 0386, case (a): a CONNECTED 4x4 block selection missing ONE\n    // interior face -- Mesh.fillSelectionHoles must fold the missed face\n    // back in so the r", 2522, "a543b5a86ab8e33203268819b42bab7485fddbf637124b4617dd4c243543e399"),
    Wave15Fragment("remesh.remesh_job:UT9", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Task 0386, case (b): TWO DISJOINT selected blocks (a wide unselected\n    // gap between them, itself touching the mesh's own open boundary and\n    // far larger t", 2746, "c16a60c88fa13221068f35dada3648eb5fdc420f25fe6564e9cc5ab7d406cd6b"),
    Wave15Fragment("remesh.remesh_job:UT10", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "unittest {\n    // Task 0386, case (c): of TWO disjoint selected blocks, one gets a\n    // patch the stitch can never accept (positioned nowhere near its\n    // region boundary -- f", 3025, "67bf7ba03d1f46e287d8d8241e9d69e4c3f1b1232e47d320e31b05993e6277e5"),
    Wave15Fragment("ai.exploration:helper1", "source/ai/exploration.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "version (unittest) {\n    import ai.interaction : AiInteractionContext;\n    import ai.interaction_log : makeAiInteractionLogRecord,\n        AiInteractionLogRecord;\n    import ai.int", 906, "8c77ac9480f8fc706040f053a85faf7324309fdb100c8c88a58b2fb53db1f835"),
    Wave15Fragment("ai3d.event_queue:helper1", "source/ai3d/event_queue.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "version (unittest) {\n    private Ai3dEvent statusEv(string jobId, long gen, double progress) {\n        Ai3dEvent e;\n        e.kind = Ai3dEventKind.status;\n        e.jobId = jobId;\n", 264, "ad6860eedc492b7f73182f94402b4eaa06941dbaf53489d177e06553082f283f"),
    Wave15Fragment("ai3d.worker_manager:helper1", "source/ai3d/worker_manager.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "version (unittest) {\n    import std.file : tempDir, rmdirRecurse;\n    import std.random : uniform;\n\n    private string makeScratchDir(string tag) {\n        auto d = buildPath(tempD", 437, "a229bc792f16b950ca940abf42be2243aa190dfec13f4dea71f747739134f0c0"),
    Wave15Fragment("remesh.remesh_job:helper4", "source/remesh/remesh_job.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "version (unittest) {\n    private Mesh hfGridMesh(int nx, int ny, float cell) {\n        Mesh m = Mesh.init;\n        m.vertices = new Vec3[]((nx + 1) * (ny + 1));\n        foreach (j;", 5525, "cd5794b85e98025e74ae9c645614b71b08cb765c201db39bf0742f7c27ea72b1"),
    Wave15Fragment("remesh.remesh_job:helper2", "source/remesh/remesh_job.d", "packages/remesh-runtime/source/remesh/remesh_job.d", "version (unittest) private void tryRemove(string path) nothrow {\n    import std.file : remove;\n    try remove(path); catch (Exception) {}\n}", 139, "e48b0b96b49dae92bf78f87b7a0d854823a0bc64dcf2d53df94122ef6bdb2e42"),

 ];
private bool[string] wave15InputValidity;
private bool[] wave15InputReads;

public size_t wave15InputStart() { return wave15InputReads.length; }

private void wave15RecordInput(string key, bool valid) {
    wave15InputValidity[key] = valid;
    wave15InputReads ~= valid;
}

// A memoized source use belongs to its current consumer just like a file read.
public void wave15UseInputs(string path) {
    import std.algorithm : startsWith;
    const prefix = wave15Normalize(wave15LogicalPath(path)) ~ ":";
    foreach (key, valid; wave15InputValidity)
        if (key.startsWith(prefix)) wave15InputReads ~= valid;
}
// These pins are independent of the admitted rows; deleting or duplicating an
// admission cannot delete or duplicate its expectation with it.
private immutable Wave15Move[] wave15MovePins = [
    Wave15Move("source/ai/interaction.d", "packages/interaction-data/source/ai/interaction.d"),
    Wave15Move("source/bg_gpu_cache.d", "packages/viewport-host/source/bg_gpu_cache.d"),
    Wave15Move("source/commands/tool/attr.d", "packages/interactive-tools/source/commands/tool/attr.d"),
    Wave15Move("source/commands/tool/begin_session.d", "packages/interactive-tools/source/commands/tool/begin_session.d"),
    Wave15Move("source/commands/tool/bridge_headless.d", "packages/interactive-tools/source/commands/tool/bridge_headless.d"),
    Wave15Move("source/commands/tool/do_apply.d", "packages/interactive-tools/source/commands/tool/do_apply.d"),
    Wave15Move("source/commands/tool/headless.d", "packages/interactive-tools/source/commands/tool/headless.d"),
    Wave15Move("source/commands/tool/host.d", "packages/interactive-tools/source/commands/tool/host.d"),
    Wave15Move("source/commands/tool/lifecycle.d", "packages/interactive-tools/source/commands/tool/lifecycle.d"),
    Wave15Move("source/commands/tool/panel_edit.d", "packages/interactive-tools/source/commands/tool/panel_edit.d"),
    Wave15Move("source/commands/tool/pipe.d", "packages/interactive-tools/source/commands/tool/pipe.d"),
    Wave15Move("source/commands/tool/reset.d", "packages/interactive-tools/source/commands/tool/reset.d"),
    Wave15Move("source/commands/tool/set.d", "packages/interactive-tools/source/commands/tool/set.d"),
    Wave15Move("source/deform_magnet.d", "packages/interactive-tools/source/deform_magnet.d"),
    Wave15Move("source/display_sync.d", "packages/viewport-gpu/source/display_sync.d"),
    Wave15Move("source/drag.d", "packages/interactive-tools/source/drag.d"),
    Wave15Move("source/drag_identity.d", "packages/interactive-tools/tests/source/drag_identity.d"),
    Wave15Move("source/edit_session.d", "packages/interactive-tools/source/edit_session.d"),
    Wave15Move("source/evaluated_move_weld.d", "packages/interactive-tools/source/evaluated_move_weld.d"),
    Wave15Move("source/falloff_handles.d", "packages/interactive-tools/source/falloff_handles.d"),
    Wave15Move("source/falloff_render.d", "packages/interactive-tools/source/falloff_render.d"),
    Wave15Move("source/gizmo.d", "packages/interactive-tools/source/gizmo.d"),
    Wave15Move("source/handler.d", "packages/interactive-tools/source/handler.d"),
    Wave15Move("source/handles/arbiter.d", "packages/interactive-tools/source/handles/arbiter.d"),
    Wave15Move("source/handles/gizmo_metrics.d", "packages/interactive-tools/source/handles/gizmo_metrics.d"),
    Wave15Move("source/handles/gl_util.d", "packages/interactive-tools/source/handles/gl_util.d"),
    Wave15Move("source/handles/shapes.d", "packages/interactive-tools/source/handles/shapes.d"),
    Wave15Move("source/image_cache.d", "packages/viewport-host/source/image_cache.d"),
    Wave15Move("source/image_plane.d", "packages/viewport-host/source/image_plane.d"),
    Wave15Move("source/model_preview.d", "packages/interactive-tools/source/model_preview.d"),
    Wave15Move("source/overlay_space.d", "packages/interactive-tools/source/overlay_space.d"),
    Wave15Move("source/pipe_gizmo_host.d", "packages/interactive-tools/source/pipe_gizmo_host.d"),
    Wave15Move("source/prepared_box_param.d", "packages/interactive-tools/source/prepared_box_param.d"),
    Wave15Move("source/prepared_bridge_activation.d", "packages/interactive-tools/source/prepared_bridge_activation.d"),
    Wave15Move("source/prepared_command_wrapper_activation.d", "packages/interactive-tools/source/prepared_command_wrapper_activation.d"),
    Wave15Move("source/prepared_edge_bevel_activation.d", "packages/interactive-tools/source/prepared_edge_bevel_activation.d"),
    Wave15Move("source/prepared_edge_extend_deactivate.d", "packages/interactive-tools/source/prepared_edge_extend_deactivate.d"),
    Wave15Move("source/prepared_edge_extend_tool_activation.d", "packages/interactive-tools/source/prepared_edge_extend_tool_activation.d"),
    Wave15Move("source/prepared_edge_extrude_activation.d", "packages/interactive-tools/source/prepared_edge_extrude_activation.d"),
    Wave15Move("source/prepared_edge_slice_activation.d", "packages/interactive-tools/source/prepared_edge_slice_activation.d"),
    Wave15Move("source/prepared_edge_slice_deactivate.d", "packages/interactive-tools/source/prepared_edge_slice_deactivate.d"),
    Wave15Move("source/prepared_inherited_noop.d", "packages/interactive-tools/source/prepared_inherited_noop.d"),
    Wave15Move("source/prepared_loop_slice_activation.d", "packages/interactive-tools/source/prepared_loop_slice_activation.d"),
    Wave15Move("source/prepared_loop_slice_deactivate.d", "packages/interactive-tools/source/prepared_loop_slice_deactivate.d"),
    Wave15Move("source/prepared_mirror_activation.d", "packages/interactive-tools/source/prepared_mirror_activation.d"),
    Wave15Move("source/prepared_move_update.d", "packages/interactive-tools/source/prepared_move_update.d"),
    Wave15Move("source/prepared_param_update.d", "packages/interactive-tools/source/prepared_param_update.d"),
    Wave15Move("source/prepared_pipe_activation.d", "packages/interactive-tools/source/prepared_pipe_activation.d"),
    Wave15Move("source/prepared_poly_bevel_activation.d", "packages/interactive-tools/source/prepared_poly_bevel_activation.d"),
    Wave15Move("source/prepared_poly_extrude_activation.d", "packages/interactive-tools/source/prepared_poly_extrude_activation.d"),
    Wave15Move("source/prepared_poly_inset_activation.d", "packages/interactive-tools/source/prepared_poly_inset_activation.d"),
    Wave15Move("source/prepared_private_state.d", "packages/interactive-tools/source/prepared_private_state.d"),
    Wave15Move("source/prepared_radial_array_transition.d", "packages/interactive-tools/source/prepared_radial_array_transition.d"),
    Wave15Move("source/prepared_radial_sweep_transition.d", "packages/interactive-tools/source/prepared_radial_sweep_transition.d"),
    Wave15Move("source/prepared_record_context.d", "packages/interactive-tools/source/prepared_record_context.d"),
    Wave15Move("source/prepared_rotate_update.d", "packages/interactive-tools/source/prepared_rotate_update.d"),
    Wave15Move("source/prepared_scale_update.d", "packages/interactive-tools/source/prepared_scale_update.d"),
    Wave15Move("source/prepared_selection_profile.d", "packages/interactive-tools/source/prepared_selection_profile.d"),
    Wave15Move("source/prepared_selection_profile_image.d", "packages/interactive-tools/source/prepared_selection_profile_image.d"),
    Wave15Move("source/prepared_slice_activation.d", "packages/interactive-tools/source/prepared_slice_activation.d"),
    Wave15Move("source/prepared_slice_deactivate.d", "packages/interactive-tools/source/prepared_slice_deactivate.d"),
    Wave15Move("source/prepared_smooth_shift_activation.d", "packages/interactive-tools/source/prepared_smooth_shift_activation.d"),
    Wave15Move("source/prepared_stroke_extrude_activation.d", "packages/interactive-tools/source/prepared_stroke_extrude_activation.d"),
    Wave15Move("source/prepared_tack_activation.d", "packages/interactive-tools/source/prepared_tack_activation.d"),
    Wave15Move("source/prepared_tool_transition.d", "packages/interactive-tools/source/prepared_tool_transition.d"),
    Wave15Move("source/prepared_topology_pen_activation.d", "packages/interactive-tools/source/prepared_topology_pen_activation.d"),
    Wave15Move("source/prepared_topology_pen_deactivate.d", "packages/interactive-tools/source/prepared_topology_pen_deactivate.d"),
    Wave15Move("source/prepared_topology_pen_update.d", "packages/interactive-tools/source/prepared_topology_pen_update.d"),
    Wave15Move("source/prepared_transform_activation.d", "packages/interactive-tools/source/prepared_transform_activation.d"),
    Wave15Move("source/prepared_transform_product_activation.d", "packages/interactive-tools/source/prepared_transform_product_activation.d"),
    Wave15Move("source/prepared_vertex_bevel_activation.d", "packages/interactive-tools/source/prepared_vertex_bevel_activation.d"),
    Wave15Move("source/prepared_vertex_extrude_activation.d", "packages/interactive-tools/source/prepared_vertex_extrude_activation.d"),
    Wave15Move("source/prepared_vertex_merge_activation.d", "packages/interactive-tools/source/prepared_vertex_merge_activation.d"),
    Wave15Move("source/prepared_xfrm_activation_session.d", "packages/interactive-tools/source/prepared_xfrm_activation_session.d"),
    Wave15Move("source/prepared_xfrm_refire_state.d", "packages/interactive-tools/source/prepared_xfrm_refire_state.d"),
    Wave15Move("source/prepared_xfrm_replay.d", "packages/interactive-tools/source/prepared_xfrm_replay.d"),
    Wave15Move("source/prepared_xfrm_slot_poll.d", "packages/interactive-tools/source/prepared_xfrm_slot_poll.d"),
    Wave15Move("source/prepared_xfrm_update_boundary.d", "packages/interactive-tools/source/prepared_xfrm_update_boundary.d"),
    Wave15Move("source/prepared_xfrm_update_edit_close.d", "packages/interactive-tools/source/prepared_xfrm_update_edit_close.d"),
    Wave15Move("source/prepared_xfrm_update_tail.d", "packages/interactive-tools/source/prepared_xfrm_update_tail.d"),
    Wave15Move("source/property_panel.d", "packages/interactive-tools/source/property_panel.d"),
    Wave15Move("source/registry.d", "packages/interactive-tools/source/registry.d"),
    Wave15Move("source/snap_render.d", "packages/interactive-tools/source/snap_render.d"),
    Wave15Move("source/tool.d", "packages/interactive-tools/source/tool.d"),
    Wave15Move("source/tool_attr_bounds.d", "packages/interactive-tools/source/tool_attr_bounds.d"),
    Wave15Move("source/tool_disarm.d", "packages/interactive-tools/source/tool_disarm.d"),
    Wave15Move("source/tool_presets.d", "packages/interactive-tools/source/tool_presets.d"),
    Wave15Move("source/tools/alignment/array_tool.d", "packages/interactive-tools/source/tools/alignment/array_tool.d"),
    Wave15Move("source/tools/alignment/clone_tool.d", "packages/interactive-tools/source/tools/alignment/clone_tool.d"),
    Wave15Move("source/tools/alignment/linear_align_tool.d", "packages/interactive-tools/source/tools/alignment/linear_align_tool.d"),
    Wave15Move("source/tools/alignment/mirror.d", "packages/interactive-tools/source/tools/alignment/mirror.d"),
    Wave15Move("source/tools/alignment/radial_align_tool.d", "packages/interactive-tools/source/tools/alignment/radial_align_tool.d"),
    Wave15Move("source/tools/alignment/radial_array_tool.d", "packages/interactive-tools/source/tools/alignment/radial_array_tool.d"),
    Wave15Move("source/tools/alignment/radial_sweep_tool.d", "packages/interactive-tools/source/tools/alignment/radial_sweep_tool.d"),
    Wave15Move("source/tools/common/command_wrapper.d", "packages/interactive-tools/source/tools/common/command_wrapper.d"),
    Wave15Move("source/tools/create/arc.d", "packages/interactive-tools/source/tools/create/arc.d"),
    Wave15Move("source/tools/create/box.d", "packages/interactive-tools/source/tools/create/box.d"),
    Wave15Move("source/tools/create/capsule.d", "packages/interactive-tools/source/tools/create/capsule.d"),
    Wave15Move("source/tools/create/cone.d", "packages/interactive-tools/source/tools/create/cone.d"),
    Wave15Move("source/tools/create/create_common.d", "packages/interactive-tools/source/tools/create/create_common.d"),
    Wave15Move("source/tools/create/cylinder.d", "packages/interactive-tools/source/tools/create/cylinder.d"),
    Wave15Move("source/tools/create/pen.d", "packages/interactive-tools/source/tools/create/pen.d"),
    Wave15Move("source/tools/create/primitive_create_tool.d", "packages/interactive-tools/source/tools/create/primitive_create_tool.d"),
    Wave15Move("source/tools/create/sphere.d", "packages/interactive-tools/source/tools/create/sphere.d"),
    Wave15Move("source/tools/create/torus.d", "packages/interactive-tools/source/tools/create/torus.d"),
    Wave15Move("source/tools/create/tube.d", "packages/interactive-tools/source/tools/create/tube.d"),
    Wave15Move("source/tools/create/vertex_place.d", "packages/interactive-tools/source/tools/create/vertex_place.d"),
    Wave15Move("source/tools/deform/bend.d", "packages/interactive-tools/source/tools/deform/bend.d"),
    Wave15Move("source/tools/deform/magnet.d", "packages/interactive-tools/source/tools/deform/magnet.d"),
    Wave15Move("source/tools/deform/push.d", "packages/interactive-tools/source/tools/deform/push.d"),
    Wave15Move("source/tools/deform/smooth_shift_tool.d", "packages/interactive-tools/source/tools/deform/smooth_shift_tool.d"),
    Wave15Move("source/tools/deform/stroke_extrude_tool.d", "packages/interactive-tools/source/tools/deform/stroke_extrude_tool.d"),
    Wave15Move("source/tools/edit/bridge_tool.d", "packages/interactive-tools/source/tools/edit/bridge_tool.d"),
    Wave15Move("source/tools/edit/edge_bevel.d", "packages/interactive-tools/source/tools/edit/edge_bevel.d"),
    Wave15Move("source/tools/edit/edge_extend.d", "packages/interactive-tools/source/tools/edit/edge_extend.d"),
    Wave15Move("source/tools/edit/edge_extrude.d", "packages/interactive-tools/source/tools/edit/edge_extrude.d"),
    Wave15Move("source/tools/edit/haul_axis_latch.d", "packages/interactive-tools/source/tools/edit/haul_axis_latch.d"),
    Wave15Move("source/tools/edit/poly_bevel.d", "packages/interactive-tools/source/tools/edit/poly_bevel.d"),
    Wave15Move("source/tools/edit/poly_extrude.d", "packages/interactive-tools/source/tools/edit/poly_extrude.d"),
    Wave15Move("source/tools/edit/poly_inset_tool.d", "packages/interactive-tools/source/tools/edit/poly_inset_tool.d"),
    Wave15Move("source/tools/edit/reduce.d", "packages/interactive-tools/source/tools/edit/reduce.d"),
    Wave15Move("source/tools/edit/smooth_relax.d", "packages/interactive-tools/source/tools/edit/smooth_relax.d"),
    Wave15Move("source/tools/edit/tack.d", "packages/interactive-tools/source/tools/edit/tack.d"),
    Wave15Move("source/tools/edit/topology_pen/defs.d", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d"),
    Wave15Move("source/tools/edit/topology_pen/json.d", "packages/interactive-tools/source/tools/edit/topology_pen/json.d"),
    Wave15Move("source/tools/edit/topology_pen/package.d", "packages/interactive-tools/source/tools/edit/topology_pen/package.d"),
    Wave15Move("source/tools/edit/topology_pen/render.d", "packages/interactive-tools/source/tools/edit/topology_pen/render.d"),
    Wave15Move("source/tools/edit/topology_pen/snap_guide.d", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d"),
    Wave15Move("source/tools/edit/topology_pen/tool.d", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d"),
    Wave15Move("source/tools/edit/vert_merge_tool.d", "packages/interactive-tools/source/tools/edit/vert_merge_tool.d"),
    Wave15Move("source/tools/edit/vertex_bevel_tool.d", "packages/interactive-tools/source/tools/edit/vertex_bevel_tool.d"),
    Wave15Move("source/tools/edit/vertex_extrude_tool.d", "packages/interactive-tools/source/tools/edit/vertex_extrude_tool.d"),
    Wave15Move("source/tools/slice/edge_slice_tool.d", "packages/interactive-tools/source/tools/slice/edge_slice_tool.d"),
    Wave15Move("source/tools/slice/edge_slide.d", "packages/interactive-tools/source/tools/slice/edge_slide.d"),
    Wave15Move("source/tools/slice/loop_slice_tool.d", "packages/interactive-tools/source/tools/slice/loop_slice_tool.d"),
    Wave15Move("source/tools/slice/slice_tool.d", "packages/interactive-tools/source/tools/slice/slice_tool.d"),
    Wave15Move("source/tools/topology_step.d", "packages/interactive-tools/source/tools/topology_step.d"),
    Wave15Move("source/tools/transform/move.d", "packages/interactive-tools/source/tools/transform/move.d"),
    Wave15Move("source/tools/transform/rotate.d", "packages/interactive-tools/source/tools/transform/rotate.d"),
    Wave15Move("source/tools/transform/scale.d", "packages/interactive-tools/source/tools/transform/scale.d"),
    Wave15Move("source/tools/transform/transform.d", "packages/interactive-tools/source/tools/transform/transform.d"),
    Wave15Move("source/tools/transform/xfrm_apply.d", "packages/interactive-tools/source/tools/transform/xfrm_apply.d"),
    Wave15Move("source/tools/transform/xfrm_handles.d", "packages/interactive-tools/source/tools/transform/xfrm_handles.d"),
    Wave15Move("source/tools/transform/xfrm_item.d", "packages/interactive-tools/source/tools/transform/xfrm_item.d"),
    Wave15Move("source/tools/transform/xfrm_transform.d", "packages/interactive-tools/source/tools/transform/xfrm_transform.d"),
    Wave15Move("source/viewport.d", "packages/viewport-host/source/viewport.d"),
    Wave15Move("source/viewport_composite.d", "packages/viewport-host/source/viewport_composite.d"),
    Wave15Move("source/coord_rounding.d", "packages/interactive-tools/source/coord_rounding.d"),
    Wave15Move("source/value_drag.d", "packages/interactive-tools/source/value_drag.d"),
    Wave15Move("source/params_widgets.d", "packages/interactive-tools/source/params_widgets.d"),
    Wave15Move("source/commands/layer/xform_edit.d", "packages/editor-commands/source/commands/layer/xform_edit.d"),
    Wave15Move("source/io/doc_state.d", "packages/application-core/source/io/doc_state.d"),
    Wave15Move("source/ai/advisor.d", "packages/interaction-data/source/ai/advisor.d"),
    Wave15Move("source/ai/debug_trace.d", "packages/interaction-data/source/ai/debug_trace.d"),
    Wave15Move("source/commands/mesh/smooth.d", "packages/interactive-tools/source/commands/mesh/smooth.d"),
    Wave15Move("tests/unit/ai/advisor_test.d", "packages/interaction-data/tests/source/tests/unit/ai/advisor_test.d"),
    Wave15Move("tests/unit/ai/debug_trace_test.d", "packages/interaction-data/tests/source/tests/unit/ai/debug_trace_test.d"),
    Wave15Move("tests/unit/ai/interaction_test.d", "packages/interaction-data/tests/source/tests/unit/ai/interaction_test.d"),
    Wave15Move("tests/unit/bevel_cold_arm_param_image_test.d", "packages/interactive-tools/tests/source/tests/unit/bevel_cold_arm_param_image_test.d"),
    Wave15Move("tests/unit/camera_intrinsics_test.d", "packages/viewport-host/tests/source/tests/unit/camera_intrinsics_test.d"),
    Wave15Move("tests/unit/close_reason_table_test.d", "packages/interactive-tools/tests/source/tests/unit/close_reason_table_test.d"),
    Wave15Move("tests/unit/command_history_test.d", "packages/interactive-tools/tests/source/tests/unit/command_history_test.d"),
    Wave15Move("tests/unit/command_wrapper_result_test.d", "packages/interactive-tools/tests/source/tests/unit/command_wrapper_result_test.d"),
    Wave15Move("tests/unit/commands/mesh/edge_slide_result_builder_test.d", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/edge_slide_result_builder_test.d"),
    Wave15Move("tests/unit/commands/mesh/jitter_result_builder_test.d", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/jitter_result_builder_test.d"),
    Wave15Move("tests/unit/constraint_surface_at_test.d", "packages/interactive-tools/tests/source/tests/unit/constraint_surface_at_test.d"),
    Wave15Move("tests/unit/deform_magnet_test.d", "packages/interactive-tools/tests/source/tests/unit/deform_magnet_test.d"),
    Wave15Move("tests/unit/dirty_key_camera_stamp_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_camera_stamp_test.d"),
    Wave15Move("tests/unit/dirty_key_tool_preview_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_tool_preview_test.d"),
    Wave15Move("tests/unit/dirty_key_weightmap_test.d", "packages/viewport-host/tests/source/tests/unit/dirty_key_weightmap_test.d"),
    Wave15Move("tests/unit/drag_gain_oblique_test.d", "packages/interactive-tools/tests/source/tests/unit/drag_gain_oblique_test.d"),
    Wave15Move("tests/unit/edge_slice_locate_base_test.d", "packages/interactive-tools/tests/source/tests/unit/edge_slice_locate_base_test.d"),
    Wave15Move("tests/unit/edit_session_test.d", "packages/interactive-tools/tests/source/tests/unit/edit_session_test.d"),
    Wave15Move("tests/unit/falloff_rmb_discipline_test.d", "packages/interactive-tools/tests/source/tests/unit/falloff_rmb_discipline_test.d"),
    Wave15Move("tests/unit/gesture_carrier_interface_test.d", "packages/interactive-tools/tests/source/tests/unit/gesture_carrier_interface_test.d"),
    Wave15Move("tests/unit/gesture_record_belt_test.d", "packages/interactive-tools/tests/source/tests/unit/gesture_record_belt_test.d"),
    Wave15Move("tests/unit/handles/gl_util_test.d", "packages/interactive-tools/tests/source/tests/unit/handles/gl_util_test.d"),
    Wave15Move("tests/unit/handles/shapes_test.d", "packages/interactive-tools/tests/source/tests/unit/handles/shapes_test.d"),
    Wave15Move("tests/unit/image_cache_test.d", "packages/viewport-host/tests/source/tests/unit/image_cache_test.d"),
    Wave15Move("tests/unit/image_plane_test.d", "packages/viewport-host/tests/source/tests/unit/image_plane_test.d"),
    Wave15Move("tests/unit/mesh_ops/bridge_frozen_kernel_test.d", "packages/interactive-tools/tests/source/tests/unit/mesh_ops/bridge_frozen_kernel_test.d"),
    Wave15Move("tests/unit/model_preview_test.d", "packages/interactive-tools/tests/source/tests/unit/model_preview_test.d"),
    Wave15Move("tests/unit/overlay_space_test.d", "packages/interactive-tools/tests/source/tests/unit/overlay_space_test.d"),
    Wave15Move("tests/unit/prepared_param_update_test.d", "packages/interactive-tools/tests/source/tests/unit/prepared_param_update_test.d"),
    Wave15Move("tests/unit/prepared_tool_transition_test.d", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d"),
    Wave15Move("tests/unit/quad_overlay_eligibility_test.d", "packages/interactive-tools/tests/source/tests/unit/quad_overlay_eligibility_test.d"),
    Wave15Move("tests/unit/shared_hover_record_test.d", "packages/interactive-tools/tests/source/tests/unit/shared_hover_record_test.d"),
    Wave15Move("tests/unit/tool_gesture_runopen_test.d", "packages/interactive-tools/tests/source/tests/unit/tool_gesture_runopen_test.d"),
    Wave15Move("tests/unit/tool_single_operation_equivalence_test.d", "packages/interactive-tools/tests/source/tests/unit/tool_single_operation_equivalence_test.d"),
    Wave15Move("tests/unit/toolpipe/local_component_frame_test.d", "packages/interactive-tools/tests/source/tests/unit/toolpipe/local_component_frame_test.d"),
    Wave15Move("tests/unit/tools/alignment/mirror_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/mirror_test.d"),
    Wave15Move("tests/unit/tools/alignment/radial_sweep_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/radial_sweep_tool_test.d"),
    Wave15Move("tests/unit/tools/create/arc_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/arc_test.d"),
    Wave15Move("tests/unit/tools/create/box_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/box_test.d"),
    Wave15Move("tests/unit/tools/create/create_common_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/create_common_test.d"),
    Wave15Move("tests/unit/tools/create/tube_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/create/tube_test.d"),
    Wave15Move("tests/unit/tools/edit/preview_topology_churn_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/preview_topology_churn_test.d"),
    Wave15Move("tests/unit/tools/edit/smooth_relax_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/smooth_relax_test.d"),
    Wave15Move("tests/unit/tools/edit/tack_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/tack_test.d"),
    Wave15Move("tests/unit/tools/edit/topology_pen/move_protocol_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/move_protocol_test.d"),
    Wave15Move("tests/unit/tools/edit/topology_pen/press_compatibility_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/press_compatibility_test.d"),
    Wave15Move("tests/unit/tools/slice/edge_slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/edge_slice_tool_test.d"),
    Wave15Move("tests/unit/tools/slice/loop_slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/loop_slice_tool_test.d"),
    Wave15Move("tests/unit/tools/slice/slice_tool_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/slice/slice_tool_test.d"),
    Wave15Move("tests/unit/tools/transform/move_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/move_test.d"),
    Wave15Move("tests/unit/tools/transform/rotate_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/rotate_test.d"),
    Wave15Move("tests/unit/tools/transform/scale_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/scale_test.d"),
    Wave15Move("tests/unit/tools/transform/transform_test.d", "packages/interactive-tools/tests/source/tests/unit/tools/transform/transform_test.d"),
    Wave15Move("tests/unit/topology_step_mixin_test.d", "packages/interactive-tools/tests/source/tests/unit/topology_step_mixin_test.d"),
    Wave15Move("tests/unit/viewport_plane_turn_test.d", "packages/viewport-host/tests/source/tests/unit/viewport_plane_turn_test.d"),
    Wave15Move("tests/unit/viewport_test.d", "packages/viewport-host/tests/source/tests/unit/viewport_test.d"),
    Wave15Move("tests/unit/wrapper_shift_apply_inheritance_test.d", "packages/interactive-tools/tests/source/tests/unit/wrapper_shift_apply_inheritance_test.d"),
    // Task 20262890: approved original logical inputs; independent frozen rows.
    Wave15Move("source/ai/analysis.d", "packages/ai-advisor/source/ai/analysis.d"),
    Wave15Move("source/ai/copilot_gate.d", "packages/ai-advisor/source/ai/copilot_gate.d"),
    Wave15Move("source/ai/element_candidates.d", "packages/ai-advisor/source/ai/element_candidates.d"),
    Wave15Move("source/ai/exploration.d", "packages/ai-advisor/source/ai/exploration.d"),
    Wave15Move("source/ai/interaction_log.d", "packages/ai-advisor/source/ai/interaction_log.d"),
    Wave15Move("source/ai/interaction_log_writer.d", "packages/ai-advisor/source/ai/interaction_log_writer.d"),
    Wave15Move("source/ai/mode_candidates.d", "packages/ai-advisor/source/ai/mode_candidates.d"),
    Wave15Move("source/ai/model_adapter.d", "packages/ai-advisor/source/ai/model_adapter.d"),
    Wave15Move("source/ai/offline_evaluator.d", "packages/ai-advisor/source/ai/offline_evaluator.d"),
    Wave15Move("source/ai/onnx_backend.d", "packages/ai-advisor/source/ai/onnx_backend.d"),
    Wave15Move("source/ai/ranker_schema.d", "packages/ai-advisor/source/ai/ranker_schema.d"),
    Wave15Move("source/ai/state.d", "packages/ai-advisor/source/ai/state.d"),
    Wave15Move("source/ai/support_loop_candidates.d", "packages/ai-advisor/source/ai/support_loop_candidates.d"),
    Wave15Move("source/ai/synthetic_dataset.d", "packages/ai-advisor/source/ai/synthetic_dataset.d"),
    Wave15Move("source/ai/training_dataset.d", "packages/ai-advisor/source/ai/training_dataset.d"),
    Wave15Move("source/ai3d/event_queue.d", "packages/ai3d-runtime/source/ai3d/event_queue.d"),
    Wave15Move("source/ai3d/job_controller.d", "packages/ai3d-runtime/source/ai3d/job_controller.d"),
    Wave15Move("source/ai3d/job_events.d", "packages/ai3d-runtime/source/ai3d/job_events.d"),
    Wave15Move("source/ai3d/scene_validator.d", "packages/ai3d-runtime/source/ai3d/scene_validator.d"),
    Wave15Move("source/ai3d/stage_artifact.d", "packages/ai3d-runtime/source/ai3d/stage_artifact.d"),
    Wave15Move("source/ai3d/worker_manager.d", "packages/ai3d-runtime/source/ai3d/worker_manager.d"),
    Wave15Move("source/commands/file/quit.d", "packages/document-actions/source/commands/file/quit.d"),
    Wave15Move("source/commands/image/commands.d", "packages/document-actions/source/commands/image/commands.d"),
    Wave15Move("source/commands/image_plane/commands.d", "packages/document-actions/source/commands/image_plane/commands.d"),
    Wave15Move("source/commands/layer/commands.d", "packages/document-actions/source/commands/layer/commands.d"),
    Wave15Move("source/commands/scene/load_mesh.d", "packages/document-actions/source/commands/scene/load_mesh.d"),
    Wave15Move("source/commands/scene/reset.d", "packages/document-actions/source/commands/scene/reset.d"),
    Wave15Move("source/http_server.d", "packages/http-runtime/source/http_server.d"),
    Wave15Move("source/http_transport.d", "packages/http-runtime/source/http_transport.d"),
    Wave15Move("source/io/browser_pick_resume.d", "packages/platform-file/source/io/browser_pick_resume.d"),
    Wave15Move("source/io/file_dialog.d", "packages/platform-file/source/io/file_dialog.d"),
    Wave15Move("source/io/file_dialog_browser.d", "packages/platform-file/source/io/file_dialog_browser.d"),
    Wave15Move("source/playback_controller.d", "packages/http-runtime/source/playback_controller.d"),
    Wave15Move("source/remesh/region_stitch.d", "packages/remesh-runtime/source/remesh/region_stitch.d"),
    Wave15Move("source/remesh/remesh_job.d", "packages/remesh-runtime/source/remesh/remesh_job.d"),
    Wave15Move("source/ui/discard_guard.d", "packages/platform-file/source/ui/discard_guard.d"),
    Wave15Move("source/commands/falloff.d", "packages/interactive-tools/source/commands/falloff.d"),
    Wave15Move("tests/unit/ai/analysis_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/analysis_test.d"),
    Wave15Move("tests/unit/ai/element_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/element_candidates_test.d"),
    Wave15Move("tests/unit/ai/exploration_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_test.d"),
    Wave15Move("tests/unit/ai/interaction_log_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_test.d"),
    Wave15Move("tests/unit/ai/interaction_log_writer_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_writer_test.d"),
    Wave15Move("tests/unit/ai/mode_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/mode_candidates_test.d"),
    Wave15Move("tests/unit/ai/model_adapter_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/model_adapter_test.d"),
    Wave15Move("tests/unit/ai/ranker_schema_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/ranker_schema_test.d"),
    Wave15Move("tests/unit/ai/support_loop_candidates_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/support_loop_candidates_test.d"),
    Wave15Move("tests/unit/ai/training_dataset_test.d", "packages/ai-advisor/tests/source/tests/unit/ai/training_dataset_test.d"),
    Wave15Move("tests/unit/ai3d/event_queue_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_test.d"),
    Wave15Move("tests/unit/ai3d/job_controller_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/job_controller_test.d"),
    Wave15Move("tests/unit/ai3d/scene_validator_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/scene_validator_test.d"),
    Wave15Move("tests/unit/ai3d/stage_artifact_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/stage_artifact_test.d"),
    Wave15Move("tests/unit/ai3d/worker_manager_test.d", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_test.d"),
    Wave15Move("tests/unit/remesh/remesh_job_test.d", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_test.d"),
    Wave15Move("tests/unit/commands/image/commands_test.d", "packages/document-actions/tests/source/tests/unit/commands/image/commands_test.d"),
    Wave15Move("tests/unit/commands/layer/add_injection_range_test.d", "packages/document-actions/tests/source/tests/unit/commands/layer/add_injection_range_test.d"),

    Wave15Move("source/sdl_error.d", "packages/input-events/source/sdl_error.d"),
    Wave15Move("tests/unit/sdl_error_test.d", "packages/input-events/tests/source/tests/unit/sdl_error_test.d"),

    Wave15Move("source/sdl_error.d", "packages/input-events/source/sdl_error.d"),
    Wave15Move("tests/unit/sdl_error_test.d", "packages/input-events/tests/source/tests/unit/sdl_error_test.d"),

];
private struct Wave15FragmentPin { string origin, id, destination; }
private immutable Wave15FragmentPin[] wave15FragmentPins = [
    Wave15FragmentPin("source/drag.d", "drag:UT1", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT2", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT3", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT4", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT5", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT6", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT7", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT8", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT9", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT10", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:UT13", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag_identity.d", "drag_identity:UT1", "packages/interactive-tools/tests/source/drag_identity.d"),
    Wave15FragmentPin("source/handles/arbiter.d", "handles.arbiter:UT1", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d"),
    Wave15FragmentPin("source/handles/arbiter.d", "handles.arbiter:UT2", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d"),
    Wave15FragmentPin("source/handles/arbiter.d", "handles.arbiter:UT3", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d"),
    Wave15FragmentPin("source/handles/gizmo_metrics.d", "handles.gizmo_metrics:UT1", "packages/interactive-tools/source/handles/gizmo_metrics.d"),
    Wave15FragmentPin("source/handles/gl_util.d", "handles.gl_util:UT1", "packages/interactive-tools/tests/source/handles/gl_util_source_cells.d"),
    Wave15FragmentPin("source/handles/shapes.d", "handles.shapes:UT1", "packages/interactive-tools/source/handles/shapes.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT1", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT2", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT3", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT4", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT5", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT6", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT7", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT8", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT9", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT10", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:UT11", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT1", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT2", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT3", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT4", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT5", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT6", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:UT7", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/prepared_bridge_activation.d", "prepared_bridge_activation:UT1", "packages/interactive-tools/tests/source/prepared_bridge_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_command_wrapper_activation.d", "prepared_command_wrapper_activation:UT1", "packages/interactive-tools/tests/source/prepared_command_wrapper_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_bevel_activation.d", "prepared_edge_bevel_activation:UT1", "packages/interactive-tools/tests/source/prepared_edge_bevel_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_extend_deactivate.d", "prepared_edge_extend_deactivate:UT1", "packages/interactive-tools/tests/source/prepared_edge_extend_deactivate_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_extend_tool_activation.d", "prepared_edge_extend_tool_activation:UT1", "packages/interactive-tools/tests/source/prepared_edge_extend_tool_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_extrude_activation.d", "prepared_edge_extrude_activation:UT1", "packages/interactive-tools/tests/source/prepared_edge_extrude_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_slice_activation.d", "prepared_edge_slice_activation:UT1", "packages/interactive-tools/tests/source/prepared_edge_slice_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_edge_slice_deactivate.d", "prepared_edge_slice_deactivate:UT1", "packages/interactive-tools/tests/source/prepared_edge_slice_deactivate_source_cells.d"),
    Wave15FragmentPin("source/prepared_inherited_noop.d", "prepared_inherited_noop:UT1", "packages/interactive-tools/tests/source/prepared_inherited_noop_source_cells.d"),
    Wave15FragmentPin("source/prepared_loop_slice_activation.d", "prepared_loop_slice_activation:UT1", "packages/interactive-tools/tests/source/prepared_loop_slice_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_loop_slice_deactivate.d", "prepared_loop_slice_deactivate:UT1", "packages/interactive-tools/tests/source/prepared_loop_slice_deactivate_source_cells.d"),
    Wave15FragmentPin("source/prepared_mirror_activation.d", "prepared_mirror_activation:UT1", "packages/interactive-tools/tests/source/prepared_mirror_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_move_update.d", "prepared_move_update:UT1", "packages/interactive-tools/tests/source/prepared_move_update_source_cells.d"),
    Wave15FragmentPin("source/prepared_pipe_activation.d", "prepared_pipe_activation:UT1", "packages/interactive-tools/tests/source/prepared_pipe_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_poly_bevel_activation.d", "prepared_poly_bevel_activation:UT1", "packages/interactive-tools/tests/source/prepared_poly_bevel_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_poly_extrude_activation.d", "prepared_poly_extrude_activation:UT1", "packages/interactive-tools/tests/source/prepared_poly_extrude_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_poly_inset_activation.d", "prepared_poly_inset_activation:UT1", "packages/interactive-tools/tests/source/prepared_poly_inset_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_private_state.d", "prepared_private_state:UT2", "packages/interactive-tools/tests/source/prepared_private_state_source_cells.d"),
    Wave15FragmentPin("source/prepared_radial_array_transition.d", "prepared_radial_array_transition:UT1", "packages/interactive-tools/tests/source/prepared_radial_array_transition_source_cells.d"),
    Wave15FragmentPin("source/prepared_radial_sweep_transition.d", "prepared_radial_sweep_transition:UT1", "packages/interactive-tools/tests/source/prepared_radial_sweep_transition_source_cells.d"),
    Wave15FragmentPin("source/prepared_record_context.d", "prepared_record_context:UT1", "packages/interactive-tools/tests/source/prepared_record_context_source_cells.d"),
    Wave15FragmentPin("source/prepared_rotate_update.d", "prepared_rotate_update:UT1", "packages/interactive-tools/tests/source/prepared_rotate_update_source_cells.d"),
    Wave15FragmentPin("source/prepared_scale_update.d", "prepared_scale_update:UT1", "packages/interactive-tools/tests/source/prepared_scale_update_source_cells.d"),
    Wave15FragmentPin("source/prepared_selection_profile.d", "prepared_selection_profile:UT1", "packages/interactive-tools/tests/source/prepared_selection_profile_source_cells.d"),
    Wave15FragmentPin("source/prepared_slice_activation.d", "prepared_slice_activation:UT1", "packages/interactive-tools/tests/source/prepared_slice_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_slice_deactivate.d", "prepared_slice_deactivate:UT1", "packages/interactive-tools/tests/source/prepared_slice_deactivate_source_cells.d"),
    Wave15FragmentPin("source/prepared_smooth_shift_activation.d", "prepared_smooth_shift_activation:UT1", "packages/interactive-tools/tests/source/prepared_smooth_shift_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_stroke_extrude_activation.d", "prepared_stroke_extrude_activation:UT1", "packages/interactive-tools/tests/source/prepared_stroke_extrude_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_tack_activation.d", "prepared_tack_activation:UT1", "packages/interactive-tools/tests/source/prepared_tack_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_topology_pen_activation.d", "prepared_topology_pen_activation:UT1", "packages/interactive-tools/tests/source/prepared_topology_pen_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_topology_pen_deactivate.d", "prepared_topology_pen_deactivate:UT1", "packages/interactive-tools/tests/source/prepared_topology_pen_deactivate_source_cells.d"),
    Wave15FragmentPin("source/prepared_topology_pen_update.d", "prepared_topology_pen_update:UT1", "packages/interactive-tools/tests/source/prepared_topology_pen_update_source_cells.d"),
    Wave15FragmentPin("source/prepared_transform_activation.d", "prepared_transform_activation:UT1", "packages/interactive-tools/tests/source/prepared_transform_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_transform_product_activation.d", "prepared_transform_product_activation:UT1", "packages/interactive-tools/tests/source/prepared_transform_product_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_vertex_bevel_activation.d", "prepared_vertex_bevel_activation:UT1", "packages/interactive-tools/tests/source/prepared_vertex_bevel_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_vertex_extrude_activation.d", "prepared_vertex_extrude_activation:UT1", "packages/interactive-tools/tests/source/prepared_vertex_extrude_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_vertex_merge_activation.d", "prepared_vertex_merge_activation:UT1", "packages/interactive-tools/tests/source/prepared_vertex_merge_activation_source_cells.d"),
    Wave15FragmentPin("source/prepared_xfrm_activation_session.d", "prepared_xfrm_activation_session:UT1", "packages/interactive-tools/tests/source/prepared_xfrm_activation_session_source_cells.d"),
    Wave15FragmentPin("source/registry.d", "registry:UT2", "packages/interactive-tools/tests/source/registry_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:UT1", "packages/interactive-tools/tests/source/snap_render_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:UT2", "packages/interactive-tools/tests/source/snap_render_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:UT3", "packages/interactive-tools/tests/source/snap_render_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:UT4", "packages/interactive-tools/tests/source/snap_render_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:UT5", "packages/interactive-tools/tests/source/snap_render_source_helpers.d"),
    Wave15FragmentPin("source/tool_disarm.d", "tool_disarm:UT1", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d"),
    Wave15FragmentPin("source/tool_disarm.d", "tool_disarm:UT2", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d"),
    Wave15FragmentPin("source/tool_disarm.d", "tool_disarm:UT3", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d"),
    Wave15FragmentPin("source/tool_disarm.d", "tool_disarm:UT4", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d"),
    Wave15FragmentPin("source/tool_presets.d", "tool_presets:UT1", "packages/interactive-tools/tests/source/tool_presets_source_cells.d"),
    Wave15FragmentPin("source/tools/alignment/mirror.d", "tools.alignment.mirror:UT1", "packages/interactive-tools/source/tools/alignment/mirror.d"),
    Wave15FragmentPin("source/tools/create/arc.d", "tools.create.arc:UT1", "packages/interactive-tools/source/tools/create/arc.d"),
    Wave15FragmentPin("source/tools/create/box.d", "tools.create.box:UT1", "packages/interactive-tools/source/tools/create/box.d"),
    Wave15FragmentPin("source/tools/create/create_common.d", "tools.create.create_common:UT1", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d"),
    Wave15FragmentPin("source/tools/create/create_common.d", "tools.create.create_common:UT2", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d"),
    Wave15FragmentPin("source/tools/create/create_common.d", "tools.create.create_common:UT3", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d"),
    Wave15FragmentPin("source/tools/create/sphere.d", "tools.create.sphere:UT1", "packages/interactive-tools/source/tools/create/sphere.d"),
    Wave15FragmentPin("source/tools/edit/bridge_tool.d", "tools.edit.bridge_tool:UT1", "packages/interactive-tools/source/tools/edit/bridge_tool.d"),
    Wave15FragmentPin("source/tools/edit/bridge_tool.d", "tools.edit.bridge_tool:UT2", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d"),
    Wave15FragmentPin("source/tools/edit/bridge_tool.d", "tools.edit.bridge_tool:UT3", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d"),
    Wave15FragmentPin("source/tools/edit/bridge_tool.d", "tools.edit.bridge_tool:UT4", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d"),
    Wave15FragmentPin("source/tools/edit/edge_extend.d", "tools.edit.edge_extend:UT1", "packages/interactive-tools/tests/source/tools/edit/edge_extend_source_cells.d"),
    Wave15FragmentPin("source/tools/transform/transform.d", "tools.transform.transform:UT1", "packages/interactive-tools/source/tools/transform/transform.d"),
    Wave15FragmentPin("source/commands/layer/xform_edit.d", "commands.layer.xform_edit:UT1", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d"),
    Wave15FragmentPin("source/commands/layer/xform_edit.d", "commands.layer.xform_edit:UT2", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d"),
    Wave15FragmentPin("source/commands/layer/xform_edit.d", "commands.layer.xform_edit:UT3", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d"),
    Wave15FragmentPin("source/drag.d", "drag:helper1", "packages/interactive-tools/tests/source/drag_source_cells.d"),
    Wave15FragmentPin("source/drag.d", "drag:helper2", "packages/interactive-tools/tests/source/drag_source_helpers.d"),
    Wave15FragmentPin("source/handles/arbiter.d", "handles.arbiter:helper3", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:helper4", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/image_plane.d", "image_plane:helper5", "packages/viewport-host/tests/source/image_plane_source_cells.d"),
    Wave15FragmentPin("source/snap_render.d", "snap_render:helper6", "packages/interactive-tools/tests/source/snap_render_source_helpers.d"),
    Wave15FragmentPin("source/tool_presets.d", "tool_presets:helper7", "packages/interactive-tools/tests/source/tool_presets_source_cells.d"),
    Wave15FragmentPin("source/commands/layer/xform_edit.d", "commands.layer.xform_edit:helper8", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d"),
    Wave15FragmentPin("source/overlay_space.d", "overlay_space:helper9", "packages/interactive-tools/tests/source/overlay_space_source_cells.d"),
    Wave15FragmentPin("source/tools/create/create_common.d", "tools.create.create_common:helper10", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d"),
    Wave15FragmentPin("source/tools/edit/bridge_tool.d", "tools.edit.bridge_tool:helper11", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d"),
    // Task 20262890: approved original logical inputs; independent frozen rows.
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT1", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT2", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT3", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT4", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT5", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:UT6", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/event_queue.d", "ai3d.event_queue:UT1", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/event_queue.d", "ai3d.event_queue:UT2", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/event_queue.d", "ai3d.event_queue:UT3", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/event_queue.d", "ai3d.event_queue:UT4", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT1", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT2", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT3", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT4", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT5", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT7", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT8", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:UT9", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/commands/layer/commands.d", "commands.layer.commands:UT6", "packages/document-actions/tests/source/tests/unit/commands/layer/commands_source_public_test.d"),
    Wave15FragmentPin("source/commands/layer/commands.d", "commands.layer.commands:UT9", "packages/document-actions/tests/source/tests/unit/commands/layer/commands_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT5", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT6", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT7", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT8", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT9", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:UT10", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/ai/exploration.d", "ai.exploration:helper1", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/event_queue.d", "ai3d.event_queue:helper1", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d"),
    Wave15FragmentPin("source/ai3d/worker_manager.d", "ai3d.worker_manager:helper1", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:helper4", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d"),
    Wave15FragmentPin("source/remesh/remesh_job.d", "remesh.remesh_job:helper2", "packages/remesh-runtime/source/remesh/remesh_job.d"),

];

private bool wave15MoveRowIntact(const Wave15Move pin) {
    size_t rows;
    foreach (move; wave15Moves)
        if (move.oldPath == pin.oldPath) {
            if (move.newPath != pin.newPath) return false;
            ++rows;
        }
    return rows == 1;
}

private bool wave15FragmentRowsIntact(string origin) {
    foreach (fragment; wave15Fragments) {
        if (fragment.origin != origin) continue;
        size_t pins;
        foreach (pin; wave15FragmentPins)
            if (pin.origin == fragment.origin && pin.id == fragment.id
                    && pin.destination == fragment.destination) ++pins;
        if (pins != 1) return false;
    }
    foreach (pin; wave15FragmentPins) {
        if (pin.origin != origin) continue;
        size_t rows;
        foreach (fragment; wave15Fragments)
            if (fragment.origin == pin.origin && fragment.id == pin.id
                    && fragment.destination == pin.destination) ++rows;
        if (rows != 1) return false;
    }
    return true;
}


private string wave15Normalize(string path) {
    import std.path : absolutePath, buildNormalizedPath;
    import std.string : replace;
    return buildNormalizedPath(absolutePath(path)).replace("\\", "/");
}

private bool wave15Match(string path, string relative, out string root) {
    import std.algorithm : endsWith;
    if (!path.endsWith("/" ~ relative)) return false;
    root = path[0 .. $ - relative.length - 1];
    return root == wave15Normalize(repoRoot);
}

public string wave15LogicalPath(string path) {
    const normal = wave15Normalize(path);
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.newPath, root))
            return buildPath(root, move.oldPath);
    }
    return normal;
}

public string wave15PhysicalPath(string path) {
    import std.file : exists;
    const normal = wave15Normalize(path);
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.oldPath, root)) {
            if (exists(normal)) return normal;
            return buildPath(root, move.newPath);
        }
    }
    return normal;
}

public bool wave15Exists(string path) {
    import std.file : exists;
    import std.algorithm : startsWith;
    const normal = wave15Normalize(path);
    if (exists(normal)) return true;
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.oldPath, root)
                && exists(buildPath(root, move.newPath))) return true;
        size_t prefix = move.oldPath.length;
        while (prefix) {
            import std.path : dirName;
            const directory = dirName(move.oldPath[0 .. prefix]);
            if (directory == "." || directory.length >= prefix) break;
            prefix = directory.length;
            if (wave15Match(normal, directory, root)
                    && exists(buildPath(root, move.newPath))) return true;
        }
    }
    return false;
}

public bool wave15IsFile(string path) {
    import std.file : isFile;
    return isFile(wave15PhysicalPath(path));
}

public bool wave15IsDir(string path) {
    import std.file : exists, isDir;
    return exists(wave15PhysicalPath(path))
        ? isDir(wave15PhysicalPath(path)) : wave15Exists(path);
}

private string wave15FragmentText(string text, const Wave15Fragment fragment,
        out size_t matches) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : indexOf, toLower;
    string result;
    import std.string : replace;
    if (fragment.id == "prepared_topology_pen_activation:UT1")
        text = text.replace("import toolpipe.state_paths : getStatePath;", "import popup_state : getStatePath;");
    if (fragment.id == "ai3d.worker_manager:UT9")
        text = text.replace("enum repoRoot  = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))));",
            "enum repoRoot  = dirName(dirName(dirName(__FILE_FULL_PATH__)));");
    if (fragment.id == "remesh.remesh_job:helper2")
        text = text.replace("version (unittest) public void tryRemove(string path)",
            "version (unittest) private void tryRemove(string path)");
    string[] declarations;
    if (fragment.id == "drag:helper2")
        declarations = ["immutable Cam[] corpusCams =", "Viewport corpusViewport(",
            "float vlen(", "Vec3 exactPlaneDelta("];
    else if (fragment.id == "snap_render:helper6")
        declarations = ["float[16] t0619Matrix(", "Viewport t0619Viewport(",
            "Mesh t0619Mesh(", "void t0619DrawnPx(", "void t0619IdentityPx(",
            "double t0619Dist(", "ItemXform t0619Xf(", "void t0619PxUnder(",
            "Mesh t0619BgMeshA(", "Mesh t0619BgMeshB(", "void t0619InstallPrimary("];
    bool publicHelpers;
    foreach (declaration; declarations)
        if (text.indexOf("\n    public " ~ declaration) >= 0) publicHelpers = true;
    if (publicHelpers) {
        foreach (declaration; declarations)
            if (text.indexOf("\n    public " ~ declaration) < 0
                    || text.indexOf("\n    private " ~ declaration) >= 0) return "";
        foreach (declaration; declarations)
            text = text.replace("\n    public " ~ declaration, "\n    private " ~ declaration);
    }
    size_t offset;
    while (offset < text.length) {
        const found = text[offset .. $].indexOf(fragment.prefix);
        if (found < 0) break;
        const begin = offset + cast(size_t) found;
        const end = begin + fragment.bytes;
        if (end <= text.length
                && sha256Of(text[begin .. end]).toHexString().toLower == fragment.digest) {
            ++matches;
            result ~= text[begin .. end] ~ "\n";
        }
        offset = begin + 1;
    }
    return result;
}


private string wave15WithoutCarrierImports(string source) {
    import std.regex : matchAll, regex;
    import std.string : indexOf;
    auto text = source.dup;
    const code = blankNonCode(source);
    foreach (site; matchAll(code, regex(`\bimport\s+([A-Za-z_][A-Za-z_0-9.]*)`))) {
        bool carrier;
        foreach (name; ["drag_identity", "drag_source_cells", "drag_source_helpers", "handles.arbiter_source_cells", "handles.gizmo_metrics_source_cells", "handles.gl_util_source_cells", "handles.shapes_source_cells", "image_plane_source_cells", "overlay_space_source_cells", "prepared_bridge_activation_source_cells", "prepared_command_wrapper_activation_source_cells", "prepared_edge_bevel_activation_source_cells", "prepared_edge_extend_deactivate_source_cells", "prepared_edge_extend_tool_activation_source_cells", "prepared_edge_extrude_activation_source_cells", "prepared_edge_slice_activation_source_cells", "prepared_edge_slice_deactivate_source_cells", "prepared_inherited_noop_source_cells", "prepared_loop_slice_activation_source_cells", "prepared_loop_slice_deactivate_source_cells", "prepared_mirror_activation_source_cells", "prepared_move_update_source_cells", "prepared_pipe_activation_source_cells", "prepared_poly_bevel_activation_source_cells", "prepared_poly_extrude_activation_source_cells", "prepared_poly_inset_activation_source_cells", "prepared_private_state_source_cells", "prepared_radial_array_transition_source_cells", "prepared_radial_sweep_transition_source_cells", "prepared_record_context_source_cells", "prepared_rotate_update_source_cells", "prepared_scale_update_source_cells", "prepared_selection_profile_source_cells", "prepared_slice_activation_source_cells", "prepared_slice_deactivate_source_cells", "prepared_smooth_shift_activation_source_cells", "prepared_stroke_extrude_activation_source_cells", "prepared_tack_activation_source_cells", "prepared_topology_pen_activation_source_cells", "prepared_topology_pen_deactivate_source_cells", "prepared_topology_pen_update_source_cells", "prepared_transform_activation_source_cells", "prepared_transform_product_activation_source_cells", "prepared_vertex_bevel_activation_source_cells", "prepared_vertex_extrude_activation_source_cells", "prepared_vertex_merge_activation_source_cells", "prepared_xfrm_activation_session_source_cells", "registry_source_cells", "snap_render_source_cells", "snap_render_source_helpers", "tests.unit.commands.layer.xform_edit_source_public_test", "tool_disarm_source_cells", "tool_presets_source_cells", "tools.alignment.mirror_source_cells", "tools.create.arc_source_cells", "tools.create.box_source_cells", "tools.create.create_common_source_cells", "tools.create.sphere_source_cells", "tools.edit.bridge_tool_source_cells", "tools.edit.edge_extend_source_cells", "tools.transform.transform_source_cells", "tests.unit.ai.exploration_source_public_test", "tests.unit.ai3d.event_queue_source_public_test", "tests.unit.ai3d.worker_manager_source_public_test", "tests.unit.commands.layer.commands_source_public_test", "tests.unit.remesh.remesh_job_source_public_test"])
            if (site[1] == name) { carrier = true; break; }
        if (!carrier) continue;
        const begin = site.pre.length;
        const tail = code[begin .. $].indexOf(';');
        if (tail < 0) continue;
        foreach (i; begin .. begin + cast(size_t) tail + 1)
            if (text[i] != '\n' && text[i] != '\r') text[i] = ' ';
    }
    return text.idup;
}

public string wave15ReadText(string path) {
    import std.file : exists, readText;
    const normal = wave15Normalize(wave15LogicalPath(path));
    foreach (pin; wave15MovePins) {
        string root;
        if (wave15Match(normal, pin.oldPath, root)) {
            wave15RecordInput(normal ~ ":move-row", wave15MoveRowIntact(pin));
            wave15RecordInput(normal ~ ":fragment-rows", wave15FragmentRowsIntact(pin.oldPath));
        }
    }
    foreach (move; wave15Moves) {
        string root;
        if (!wave15Match(normal, move.oldPath, root)) continue;
        const destination = buildPath(root, move.newPath);
        const oldPresent = exists(normal), newPresent = exists(destination);
        auto text = readText(oldPresent ? normal : destination);
        if (!oldPresent) {
            text = wave15WithoutCarrierImports(text);
            if (move.oldPath == "source/drag.d") {
                import std.algorithm : count;
                import std.string : replace;
                enum context = "version (unittest) {\n    import std.math : PI, sin, cos, tan;\n}\n";
                wave15RecordInput(normal ~ ":retained-math-context", text.count(context) == 1);
                text = text.replace(context, "");
            }
            if (move.oldPath == "source/snap_render.d") {
                import std.algorithm : count;
                import std.string : replace;
                enum context = "version (unittest) {\n    import math     : lookAt, perspectiveMatrix, transformPoint;\n    import document : ItemXform, primaryModelSpaceResolver;\n    import std.format : format;\n}\n";
                wave15RecordInput(normal ~ ":retained-import-context", text.count(context) == 1);
                text = text.replace(context, "");
            }
            if (move.oldPath == "source/ai/state.d") {
                import std.algorithm : count;
                enum context = "import toolpipe.state_paths : setStatePath;";
                wave15RecordInput(normal ~ ":state-import-context", text.count(context) == 1);
                text = text.replace(context, "import popup_state : setStatePath;");
            }
            if (move.oldPath == "source/ai3d/worker_manager.d") {
                import std.algorithm : count;
                enum context = "        enum repoRoot = dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__)))));";
                wave15RecordInput(normal ~ ":worker-root-context", text.count(context) == 1);
                text = text.replace(context, "        enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));");
            }
            if (move.oldPath == "source/remesh/remesh_job.d") {
                import std.algorithm : count;
                enum context = "version (unittest) public void tryRemove(string path)";
                wave15RecordInput(normal ~ ":retained-cleanup-context", text.count(context) == 1);
                text = text.replace(context, "version (unittest) private void tryRemove(string path)");
            }
            if (move.oldPath == "source/coord_rounding.d") {
                import std.string : replace;
                text = text.replace("import toolpipe.state_paths : setStatePath;", "import popup_state : setStatePath;");
            }
        }
        wave15RecordInput(normal ~ ":physical", oldPresent != newPresent);
        foreach (fragment; wave15Fragments) {
            if (fragment.origin != move.oldPath) continue;
            size_t matches;
            string original;
            if (oldPresent) original = wave15FragmentText(text, fragment, matches);
            else {
                const carrier = buildPath(root, fragment.destination);
                if (exists(carrier)) original = wave15FragmentText(readText(carrier), fragment, matches);
                if (fragment.destination != move.newPath) text ~= "\n" ~ original;
            }
            wave15RecordInput(normal ~ ":" ~ fragment.id, matches == 1);
        }
        return text;
    }
    return readText(normal);
}

// Each consuming domain owns a start before its reads (task 20262780). Its
// original needle checks only those admissions after the original floors;
// frozen fragment digests retain omitted and duplicate inputs as invalid.
public bool wave15InputsIntact(size_t first) {
    foreach (valid; wave15InputReads[first .. $]) if (!valid) return false;
    return true;
}

public struct Wave15Entry {
    string name;
    alias name this;
    bool isFile, isDir;
    ulong size;
}

public Wave15Entry[] wave15DirEntries(string directory, string pattern,
        SpanMode span, bool followSymlink = true) {
    import std.file : dirEntries, exists, isFile, isDir, getSize;
    import std.path : baseName, dirName, globMatch, relativePath;
    import std.algorithm : startsWith, canFind;
    const normal = wave15Normalize(directory);
    Wave15Entry[] result;
    foreach (pin; wave15MovePins) {
        string root;
        size_t prefix = pin.oldPath.length;
        while (prefix) {
            const oldDirectory = dirName(pin.oldPath[0 .. prefix]);
            if (oldDirectory == "." || oldDirectory.length >= prefix) break;
            prefix = oldDirectory.length;
            if (!wave15Match(normal, oldDirectory, root)) continue;
            const logical = buildPath(root, pin.oldPath);
            const relative = relativePath(logical, normal);
            if (span == SpanMode.shallow && relative.canFind("/")) break;
            if (!globMatch(baseName(logical), pattern)) break;
            wave15RecordInput(logical ~ ":directory-admission", wave15MoveRowIntact(pin)
                && (exists(logical) != exists(buildPath(root, pin.newPath))));
            break;
        }
    }
    if (exists(normal)) foreach (entry; dirEntries(directory, pattern, span, followSymlink)) {
        bool movedDestination;
        foreach (move; wave15Moves) {
            string root;
            if (wave15Match(wave15Normalize(entry.name), move.newPath, root)) { movedDestination = true; break; }
        }
        if (!movedDestination)
            result ~= Wave15Entry(entry.name, entry.isFile, entry.isDir, entry.isFile ? entry.size : 0);
    }
    foreach (move; wave15Moves) {
        string root;
        size_t prefix = move.oldPath.length;
        while (prefix) {
            const oldDirectory = dirName(move.oldPath[0 .. prefix]);
            if (oldDirectory == "." || oldDirectory.length >= prefix) break;
            prefix = oldDirectory.length;
            if (!wave15Match(normal, oldDirectory, root)) continue;
            const logical = buildPath(root, move.oldPath);
            const relative = relativePath(logical, normal);
            if (span == SpanMode.shallow && relative.canFind("/")) break;
            if (!globMatch(baseName(logical), pattern)) break;
            const physical = buildPath(root, move.newPath);
            if (exists(physical))
                result ~= Wave15Entry(buildPath(directory, relative), isFile(physical), isDir(physical), isFile(physical) ? getSize(physical) : 0);
            break;
        }
    }
    return result;
}

public Wave15Entry[] wave15DirEntries(string directory, SpanMode span,
        bool followSymlink = true) {
    return wave15DirEntries(directory, "*", span, followSymlink);
}
