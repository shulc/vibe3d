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

import tools.harness.dsource : sourceBlankNonCode = blankNonCode;

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
import std.regex     : ctRegex, matchAll, matchFirst, regex;
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
package(tests.unit) alias blankNonCode = sourceBlankNonCode;

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

    Wave15Move("source/sdl_error.d", "packages/input-events/source/sdl_error.d"),
    Wave15Move("tests/unit/sdl_error_test.d", "packages/input-events/tests/source/tests/unit/sdl_error_test.d"),
    Wave15Move("source/render/backend.d", "packages/render-model/source/render/backend.d"),
    Wave15Move("source/render/backend_bridge.d", "packages/render-backends/source/render/backend_bridge.d"),
    Wave15Move("source/render/cycles_backend.d", "packages/render-backends/source/render/cycles_backend.d"),
    Wave15Move("source/render/render_diff.d", "packages/render-backends/source/render/render_diff.d"),
    Wave15Move("source/render/rpr_backend.d", "packages/render-backends/source/render/rpr_backend.d"),
    Wave15Move("source/render/scene.d", "packages/render-model/source/render/scene.d"),
    Wave15Move("source/args_dialog.d", "packages/editor-ui/source/args_dialog.d"),
    Wave15Move("source/buttonset.d", "packages/editor-ui/source/buttonset.d"),
    Wave15Move("source/copilot_overlay.d", "packages/editor-ui/source/copilot_overlay.d"),
    Wave15Move("source/copilot_panel.d", "packages/editor-ui/source/copilot_panel.d"),
    Wave15Move("source/forms_render.d", "packages/editor-ui/source/forms_render.d"),
    Wave15Move("source/imgui_event_gate.d", "packages/editor-ui/source/imgui_event_gate.d"),
    Wave15Move("source/imgui_flag_boundary.d", "packages/editor-ui/source/imgui_flag_boundary.d"),
    Wave15Move("source/imgui_style.d", "packages/editor-ui/source/imgui_style.d"),
    Wave15Move("source/pie_geometry.d", "packages/editor-ui/source/pie_geometry.d"),
    Wave15Move("source/pie_menus.d", "packages/editor-ui/source/pie_menus.d"),
    Wave15Move("source/pie_state.d", "packages/editor-ui/source/pie_state.d"),
    Wave15Move("source/popup_state.d", "packages/editor-ui/source/popup_state.d"),
    Wave15Move("source/ui/action_menu.d", "packages/editor-ui/source/ui/action_menu.d"),
    Wave15Move("source/ui/availability.d", "packages/editor-ui/source/ui/availability.d"),
    Wave15Move("source/ui/button_face.d", "packages/editor-ui/source/ui/button_face.d"),
    Wave15Move("source/ui/channel_rows.d", "packages/editor-ui/source/ui/channel_rows.d"),
    Wave15Move("source/ui/channels_panel.d", "packages/editor-ui/source/ui/channels_panel.d"),
    Wave15Move("source/ui/command_notice.d", "packages/editor-ui/source/ui/command_notice.d"),
    Wave15Move("source/ui/dock_drag.d", "packages/editor-ui/source/ui/dock_drag.d"),
    Wave15Move("source/ui/guard_modal_state.d", "packages/editor-ui/source/ui/guard_modal_state.d"),
    Wave15Move("source/ui/history_panel.d", "packages/editor-ui/source/ui/history_panel.d"),
    Wave15Move("source/ui/image_list_panel.d", "packages/editor-ui/source/ui/image_list_panel.d"),
    Wave15Move("source/ui/image_rows.d", "packages/editor-ui/source/ui/image_rows.d"),
    Wave15Move("source/ui/imgui_window_class.d", "packages/editor-ui/source/ui/imgui_window_class.d"),
    Wave15Move("source/ui/item_glyphs.d", "packages/editor-ui/source/ui/item_glyphs.d"),
    Wave15Move("source/ui/item_rename.d", "packages/editor-ui/source/ui/item_rename.d"),
    Wave15Move("source/ui/item_rows.d", "packages/editor-ui/source/ui/item_rows.d"),
    Wave15Move("source/ui/layer_list_panel.d", "packages/editor-ui/source/ui/layer_list_panel.d"),
    Wave15Move("source/ui/mode_popup.d", "packages/editor-ui/source/ui/mode_popup.d"),
    Wave15Move("source/ui/panel_chrome.d", "packages/editor-ui/source/ui/panel_chrome.d"),
    Wave15Move("source/ui/panels.d", "packages/editor-ui/source/ui/panels.d"),
    Wave15Move("source/ui/pie_record.d", "packages/editor-ui/source/ui/pie_record.d"),
    Wave15Move("source/ui/pie_render.d", "packages/editor-ui/source/ui/pie_render.d"),
    Wave15Move("source/ui/remesh_modal_state.d", "packages/editor-ui/source/ui/remesh_modal_state.d"),
    Wave15Move("source/ui/retained_item.d", "packages/editor-ui/source/ui/retained_item.d"),
    Wave15Move("source/ui/stat_record.d", "packages/editor-ui/source/ui/stat_record.d"),
    Wave15Move("source/ui/stat_rows.d", "packages/editor-ui/source/ui/stat_rows.d"),
    Wave15Move("source/ui/tool_properties_panel.d", "packages/editor-ui/source/ui/tool_properties_panel.d"),
    Wave15Move("source/ui/viewport_props_role.d", "packages/editor-ui/source/ui/viewport_props_role.d"),
    Wave15Move("tests/unit/ui/channel_rows_test.d", "packages/editor-ui/tests/source/tests/unit/ui/channel_rows_test.d"),
    Wave15Move("tests/unit/ui/command_notice_test.d", "packages/editor-ui/tests/source/tests/unit/ui/command_notice_test.d"),
    Wave15Move("tests/unit/ui/stat_rows_test.d", "packages/editor-ui/tests/source/tests/unit/ui/stat_rows_test.d"),
    Wave15Move("source/forms.d", "packages/forms-model/source/forms.d"),

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
    Wave15Fragment("source/ui/availability.d:original-public-cells", "source/ui/availability.d", "packages/editor-ui/tests/source/ui/availability_source_test.d", "unittest {\n    import command  : Command, kNoEditTargetReason;\n    import tool     : Tool;\n    import mesh     : Mesh;\n    impor", 3909, "1393fd982b656bc3dfc461293b7c4d3c26ab822ddfeccef1a46ad2656a7f7a04"),
    Wave15Fragment("source/ui/item_rows.d:original-public-cells", "source/ui/item_rows.d", "packages/editor-ui/tests/source/ui/item_click_source_test.d", "unittest {\n    // Every cell of the 2x2, because the interesting one is the pair and a\n    // three-case test would not have it.", 447, "d0d38730d0dd9760624cb4d234b3242fe898ee21f281c7cdbc720d6e0072492d"),
    Wave15Fragment("source/forms.d:original-public-cells", "source/forms.d", "packages/forms-model/tests/source/forms_source_test.d", "version (unittest)\n{\n    unittest { // RowKind discriminator + makeControl payload\n        auto r = Row.makeControl(\"tool.attr x", 14106, "0cfcdefd754d5462aa694f1a0b58a4ab4029a4c0b8c03c92f0de4641324ce77e"),

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
    Wave15Move("source/render/backend.d", "packages/render-model/source/render/backend.d"),
    Wave15Move("source/render/backend_bridge.d", "packages/render-backends/source/render/backend_bridge.d"),
    Wave15Move("source/render/cycles_backend.d", "packages/render-backends/source/render/cycles_backend.d"),
    Wave15Move("source/render/render_diff.d", "packages/render-backends/source/render/render_diff.d"),
    Wave15Move("source/render/rpr_backend.d", "packages/render-backends/source/render/rpr_backend.d"),
    Wave15Move("source/render/scene.d", "packages/render-model/source/render/scene.d"),
    Wave15Move("source/args_dialog.d", "packages/editor-ui/source/args_dialog.d"),
    Wave15Move("source/buttonset.d", "packages/editor-ui/source/buttonset.d"),
    Wave15Move("source/copilot_overlay.d", "packages/editor-ui/source/copilot_overlay.d"),
    Wave15Move("source/copilot_panel.d", "packages/editor-ui/source/copilot_panel.d"),
    Wave15Move("source/forms_render.d", "packages/editor-ui/source/forms_render.d"),
    Wave15Move("source/imgui_event_gate.d", "packages/editor-ui/source/imgui_event_gate.d"),
    Wave15Move("source/imgui_flag_boundary.d", "packages/editor-ui/source/imgui_flag_boundary.d"),
    Wave15Move("source/imgui_style.d", "packages/editor-ui/source/imgui_style.d"),
    Wave15Move("source/pie_geometry.d", "packages/editor-ui/source/pie_geometry.d"),
    Wave15Move("source/pie_menus.d", "packages/editor-ui/source/pie_menus.d"),
    Wave15Move("source/pie_state.d", "packages/editor-ui/source/pie_state.d"),
    Wave15Move("source/popup_state.d", "packages/editor-ui/source/popup_state.d"),
    Wave15Move("source/ui/action_menu.d", "packages/editor-ui/source/ui/action_menu.d"),
    Wave15Move("source/ui/availability.d", "packages/editor-ui/source/ui/availability.d"),
    Wave15Move("source/ui/button_face.d", "packages/editor-ui/source/ui/button_face.d"),
    Wave15Move("source/ui/channel_rows.d", "packages/editor-ui/source/ui/channel_rows.d"),
    Wave15Move("source/ui/channels_panel.d", "packages/editor-ui/source/ui/channels_panel.d"),
    Wave15Move("source/ui/command_notice.d", "packages/editor-ui/source/ui/command_notice.d"),
    Wave15Move("source/ui/dock_drag.d", "packages/editor-ui/source/ui/dock_drag.d"),
    Wave15Move("source/ui/guard_modal_state.d", "packages/editor-ui/source/ui/guard_modal_state.d"),
    Wave15Move("source/ui/history_panel.d", "packages/editor-ui/source/ui/history_panel.d"),
    Wave15Move("source/ui/image_list_panel.d", "packages/editor-ui/source/ui/image_list_panel.d"),
    Wave15Move("source/ui/image_rows.d", "packages/editor-ui/source/ui/image_rows.d"),
    Wave15Move("source/ui/imgui_window_class.d", "packages/editor-ui/source/ui/imgui_window_class.d"),
    Wave15Move("source/ui/item_glyphs.d", "packages/editor-ui/source/ui/item_glyphs.d"),
    Wave15Move("source/ui/item_rename.d", "packages/editor-ui/source/ui/item_rename.d"),
    Wave15Move("source/ui/item_rows.d", "packages/editor-ui/source/ui/item_rows.d"),
    Wave15Move("source/ui/layer_list_panel.d", "packages/editor-ui/source/ui/layer_list_panel.d"),
    Wave15Move("source/ui/mode_popup.d", "packages/editor-ui/source/ui/mode_popup.d"),
    Wave15Move("source/ui/panel_chrome.d", "packages/editor-ui/source/ui/panel_chrome.d"),
    Wave15Move("source/ui/panels.d", "packages/editor-ui/source/ui/panels.d"),
    Wave15Move("source/ui/pie_record.d", "packages/editor-ui/source/ui/pie_record.d"),
    Wave15Move("source/ui/pie_render.d", "packages/editor-ui/source/ui/pie_render.d"),
    Wave15Move("source/ui/remesh_modal_state.d", "packages/editor-ui/source/ui/remesh_modal_state.d"),
    Wave15Move("source/ui/retained_item.d", "packages/editor-ui/source/ui/retained_item.d"),
    Wave15Move("source/ui/stat_record.d", "packages/editor-ui/source/ui/stat_record.d"),
    Wave15Move("source/ui/stat_rows.d", "packages/editor-ui/source/ui/stat_rows.d"),
    Wave15Move("source/ui/tool_properties_panel.d", "packages/editor-ui/source/ui/tool_properties_panel.d"),
    Wave15Move("source/ui/viewport_props_role.d", "packages/editor-ui/source/ui/viewport_props_role.d"),
    Wave15Move("tests/unit/ui/channel_rows_test.d", "packages/editor-ui/tests/source/tests/unit/ui/channel_rows_test.d"),
    Wave15Move("tests/unit/ui/command_notice_test.d", "packages/editor-ui/tests/source/tests/unit/ui/command_notice_test.d"),
    Wave15Move("tests/unit/ui/stat_rows_test.d", "packages/editor-ui/tests/source/tests/unit/ui/stat_rows_test.d"),
    Wave15Move("source/forms.d", "packages/forms-model/source/forms.d"),

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
    Wave15FragmentPin("source/ui/availability.d", "source/ui/availability.d:original-public-cells", "packages/editor-ui/tests/source/ui/availability_source_test.d"),
    Wave15FragmentPin("source/ui/item_rows.d", "source/ui/item_rows.d:original-public-cells", "packages/editor-ui/tests/source/ui/item_click_source_test.d"),
    Wave15FragmentPin("source/forms.d", "source/forms.d:original-public-cells", "packages/forms-model/tests/source/forms_source_test.d"),

];

// Task 20263013: finite math + D1 rows from the frozen Wave19 map. These
// coordinates compose with the original historical move/hash inverses below.
private struct Wave19Owner { string name, oldRoot, newRoot; }
private immutable Wave19Owner[] wave19Owners = [
    Wave19Owner("math", "util/math", "libraries/util/math"),
    Wave19Owner("edit-contracts", "packages/edit-contracts", "libraries/editing/contracts"),
    Wave19Owner("interaction-data", "packages/interaction-data", "libraries/editing/interaction/data"),
    Wave19Owner("json-number", "util/json-number", "libraries/util/json-number"),
    Wave19Owner("log", "util/log", "libraries/util/log"),
    Wave19Owner("mesh-contracts", "packages/mesh-contracts", "libraries/mesh/contracts"),
    Wave19Owner("parallel", "util/parallel", "libraries/util/parallel"),
    Wave19Owner("param-schema", "packages/param-schema", "libraries/editing/params"),
    Wave19Owner("plane-bytes", "util/plane-bytes", "libraries/util/plane-bytes"),
    Wave19Owner("profiling", "packages/profiling", "libraries/util/profiling"),
    Wave19Owner("screen-buckets", "util/screen-buckets", "libraries/util/screen-buckets"),
    Wave19Owner("spatial", "packages/spatial", "libraries/util/spatial"),
    Wave19Owner("mesh-change", "packages/mesh-change", "libraries/mesh/change"),
    Wave19Owner("camera-model", "packages/camera-model", "libraries/viewport/camera"),
    Wave19Owner("image-codec", "packages/image-codec", "libraries/documents/image-codec"),
    Wave19Owner("input-events", "packages/input-events", "libraries/platform/input"),
    Wave19Owner("mesh-edit-log", "packages/mesh-edit-log", "libraries/mesh/edit-log"),
    Wave19Owner("mesh-topology", "packages/mesh-topology", "libraries/mesh/topology"),
    Wave19Owner("render-model", "packages/render-model", "libraries/render/model"),
    Wave19Owner("mesh", "packages/mesh", "libraries/mesh/core"),
    Wave19Owner("document-model", "packages/document-model", "libraries/documents/model"),
    Wave19Owner("mesh-edit-replay", "packages/mesh-edit-replay", "libraries/mesh/edit-replay"),
    Wave19Owner("mesh-ops", "packages/mesh-ops", "libraries/mesh/ops"),
    Wave19Owner("mesh-preview", "packages/mesh-preview", "libraries/mesh/preview"),
    Wave19Owner("mesh-snapshot", "packages/mesh-snapshot", "libraries/mesh/snapshot"),
    Wave19Owner("pipe-contracts", "packages/pipe-contracts", "libraries/editing/pipeline/contracts"),
    Wave19Owner("display-policy", "packages/display-policy", "libraries/viewport/display-policy"),
    Wave19Owner("document-channels", "packages/document-channels", "libraries/documents/channels"),
    Wave19Owner("interaction-query", "packages/interaction-query", "libraries/editing/selection/query"),
    Wave19Owner("interchange", "packages/interchange", "libraries/documents/interchange"),
    Wave19Owner("pipe-runtime", "packages/pipe-runtime", "libraries/editing/pipeline/runtime"),
    Wave19Owner("remesh-runtime", "packages/remesh-runtime", "libraries/runtime/remesh"),
    Wave19Owner("render-backends", "packages/render-backends", "libraries/render/backends"),
    Wave19Owner("selection-model", "packages/selection-model", "libraries/editing/selection/model"),
    Wave19Owner("tool-state", "packages/tool-state", "libraries/editing/tools/state"),
    Wave19Owner("document-io", "packages/document-io", "libraries/documents/io"),
    Wave19Owner("pipe-evaluation", "packages/pipe-evaluation", "libraries/editing/pipeline/evaluation"),
    Wave19Owner("viewport-gpu", "packages/viewport-gpu", "libraries/viewport/gpu"),
    Wave19Owner("ai-advisor", "packages/ai-advisor", "libraries/runtime/ai-advisor"),
    Wave19Owner("ai3d-runtime", "packages/ai3d-runtime", "libraries/runtime/ai3d"),
    Wave19Owner("alignment-ops", "packages/alignment-ops", "libraries/editing/tools/alignment"),
    Wave19Owner("creation-ops", "packages/creation-ops", "libraries/editing/tools/creation"),
    Wave19Owner("scene-query", "packages/scene-query", "libraries/editing/selection/scene-query"),
    Wave19Owner("subpatch-preview", "packages/subpatch-preview", "libraries/viewport/subpatch"),
    Wave19Owner("transform-ops", "packages/transform-ops", "libraries/editing/tools/transform"),
    Wave19Owner("command-runtime", "packages/command-runtime", "libraries/editing/commands/runtime"),
    Wave19Owner("application-core", "packages/application-core", "libraries/runtime/application-core"),
    Wave19Owner("editor-commands", "packages/editor-commands", "libraries/editing/commands/editor"),
    Wave19Owner("interactive-tools", "packages/interactive-tools", "libraries/editing/tools/interactive"),
    Wave19Owner("forms-model", "packages/forms-model", "libraries/ui/forms"),
    Wave19Owner("http-runtime", "packages/http-runtime", "libraries/runtime/http"),
    Wave19Owner("platform-file", "packages/platform-file", "libraries/platform/file"),
    Wave19Owner("viewport-host", "packages/viewport-host", "libraries/viewport/host"),
    Wave19Owner("document-actions", "packages/document-actions", "libraries/runtime/document-actions"),
    Wave19Owner("editor-ui", "packages/editor-ui", "libraries/ui/editor"),
    Wave19Owner("cli", "tools/cli", "apps/cli"),
];
private struct Wave19Module { string owner, oldPath, newPath, oldModule, newModule; }
private immutable Wave19Module[] wave19Modules = [
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/analysis.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/analysis.d", "ai.analysis", "vibe3d.runtime.ai_advisor.ai.analysis"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/copilot_gate.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/copilot_gate.d", "ai.copilot_gate", "vibe3d.runtime.ai_advisor.ai.copilot_gate"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/element_candidates.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/element_candidates.d", "ai.element_candidates", "vibe3d.runtime.ai_advisor.ai.element_candidates"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/exploration.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/exploration.d", "ai.exploration", "vibe3d.runtime.ai_advisor.ai.exploration"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/interaction_log.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/interaction_log.d", "ai.interaction_log", "vibe3d.runtime.ai_advisor.ai.interaction_log"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/interaction_log_writer.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/interaction_log_writer.d", "ai.interaction_log_writer", "vibe3d.runtime.ai_advisor.ai.interaction_log_writer"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/mode_candidates.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/mode_candidates.d", "ai.mode_candidates", "vibe3d.runtime.ai_advisor.ai.mode_candidates"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/model_adapter.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/model_adapter.d", "ai.model_adapter", "vibe3d.runtime.ai_advisor.ai.model_adapter"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/offline_evaluator.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/offline_evaluator.d", "ai.offline_evaluator", "vibe3d.runtime.ai_advisor.ai.offline_evaluator"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/onnx_backend.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/onnx_backend.d", "ai.onnx_backend", "vibe3d.runtime.ai_advisor.ai.onnx_backend"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/ranker_schema.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/ranker_schema.d", "ai.ranker_schema", "vibe3d.runtime.ai_advisor.ai.ranker_schema"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/state.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/state.d", "ai.state", "vibe3d.runtime.ai_advisor.ai.state"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/support_loop_candidates.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/support_loop_candidates.d", "ai.support_loop_candidates", "vibe3d.runtime.ai_advisor.ai.support_loop_candidates"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/synthetic_dataset.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/synthetic_dataset.d", "ai.synthetic_dataset", "vibe3d.runtime.ai_advisor.ai.synthetic_dataset"),
    Wave19Module("ai-advisor", "packages/ai-advisor/source/ai/training_dataset.d", "libraries/runtime/ai-advisor/source/vibe3d/runtime/ai_advisor/ai/training_dataset.d", "ai.training_dataset", "vibe3d.runtime.ai_advisor.ai.training_dataset"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/analysis_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/analysis_test.d", "tests.unit.ai.analysis_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.analysis_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/element_candidates_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/element_candidates_test.d", "tests.unit.ai.element_candidates_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.element_candidates_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_source_public_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/exploration_source_public_test.d", "tests.unit.ai.exploration_source_public_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.exploration_source_public_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/exploration_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/exploration_test.d", "tests.unit.ai.exploration_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.exploration_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/interaction_log_test.d", "tests.unit.ai.interaction_log_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.interaction_log_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/interaction_log_writer_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/interaction_log_writer_test.d", "tests.unit.ai.interaction_log_writer_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.interaction_log_writer_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/mode_candidates_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/mode_candidates_test.d", "tests.unit.ai.mode_candidates_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.mode_candidates_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/model_adapter_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/model_adapter_test.d", "tests.unit.ai.model_adapter_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.model_adapter_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/ranker_schema_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/ranker_schema_test.d", "tests.unit.ai.ranker_schema_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.ranker_schema_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/support_loop_candidates_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/support_loop_candidates_test.d", "tests.unit.ai.support_loop_candidates_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.support_loop_candidates_test"),
    Wave19Module("ai-advisor", "packages/ai-advisor/tests/source/tests/unit/ai/training_dataset_test.d", "libraries/runtime/ai-advisor/tests/source/vibe3d/runtime/ai_advisor/tests/unit/ai/training_dataset_test.d", "tests.unit.ai.training_dataset_test", "vibe3d.runtime.ai_advisor.tests.unit.ai.training_dataset_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/event_queue.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/event_queue.d", "ai3d.event_queue", "vibe3d.runtime.ai3d.ai3d.event_queue"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/job_controller.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/job_controller.d", "ai3d.job_controller", "vibe3d.runtime.ai3d.ai3d.job_controller"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/job_events.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/job_events.d", "ai3d.job_events", "vibe3d.runtime.ai3d.ai3d.job_events"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/scene_validator.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/scene_validator.d", "ai3d.scene_validator", "vibe3d.runtime.ai3d.ai3d.scene_validator"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/stage_artifact.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/stage_artifact.d", "ai3d.stage_artifact", "vibe3d.runtime.ai3d.ai3d.stage_artifact"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/source/ai3d/worker_manager.d", "libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/worker_manager.d", "ai3d.worker_manager", "vibe3d.runtime.ai3d.ai3d.worker_manager"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_source_public_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/event_queue_source_public_test.d", "tests.unit.ai3d.event_queue_source_public_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.event_queue_source_public_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/event_queue_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/event_queue_test.d", "tests.unit.ai3d.event_queue_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.event_queue_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/job_controller_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/job_controller_test.d", "tests.unit.ai3d.job_controller_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.job_controller_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/scene_validator_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/scene_validator_test.d", "tests.unit.ai3d.scene_validator_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.scene_validator_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/stage_artifact_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/stage_artifact_test.d", "tests.unit.ai3d.stage_artifact_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.stage_artifact_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/worker_manager_source_public_test.d", "tests.unit.ai3d.worker_manager_source_public_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.worker_manager_source_public_test"),
    Wave19Module("ai3d-runtime", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_test.d", "libraries/runtime/ai3d/tests/source/vibe3d/runtime/ai3d/tests/unit/ai3d/worker_manager_test.d", "tests.unit.ai3d.worker_manager_test", "vibe3d.runtime.ai3d.tests.unit.ai3d.worker_manager_test"),
    Wave19Module("alignment-ops", "packages/alignment-ops/source/tools/alignment/align_kernels.d", "libraries/editing/tools/alignment/source/vibe3d/editing/tools/alignment/tools/alignment/align_kernels.d", "tools.alignment.align_kernels", "vibe3d.editing.tools.alignment.tools.alignment.align_kernels"),
    Wave19Module("alignment-ops", "packages/alignment-ops/tests/source/tests/unit/alignment_ops_population_test.d", "libraries/editing/tools/alignment/tests/source/vibe3d/editing/tools/alignment/tests/unit/alignment_ops_population_test.d", "tests.unit.alignment_ops_population_test", "vibe3d.editing.tools.alignment.tests.unit.alignment_ops_population_test"),
    Wave19Module("alignment-ops", "packages/alignment-ops/tests/source/tests/unit/tools/alignment/align_kernels_test.d", "libraries/editing/tools/alignment/tests/source/vibe3d/editing/tools/alignment/tests/unit/tools/alignment/align_kernels_test.d", "tests.unit.tools.alignment.align_kernels_test", "vibe3d.editing.tools.alignment.tests.unit.tools.alignment.align_kernels_test"),
    Wave19Module("application-core", "packages/application-core/source/app_version.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/app_version.d", "app_version", "vibe3d.runtime.application_core.app_version"),
    Wave19Module("application-core", "packages/application-core/source/http_json.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/http_json.d", "http_json", "vibe3d.runtime.application_core.http_json"),
    Wave19Module("application-core", "packages/application-core/source/io/doc_state.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/io/doc_state.d", "io.doc_state", "vibe3d.runtime.application_core.io.doc_state"),
    Wave19Module("application-core", "packages/application-core/source/live_registration_roles.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/live_registration_roles.d", "live_registration_roles", "vibe3d.runtime.application_core.live_registration_roles"),
    Wave19Module("application-core", "packages/application-core/source/morph_target.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/morph_target.d", "morph_target", "vibe3d.runtime.application_core.morph_target"),
    Wave19Module("application-core", "packages/application-core/source/pilot_command_registration.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/pilot_command_registration.d", "pilot_command_registration", "vibe3d.runtime.application_core.pilot_command_registration"),
    Wave19Module("application-core", "packages/application-core/source/session_owner.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/session_owner.d", "session_owner", "vibe3d.runtime.application_core.session_owner"),
    Wave19Module("application-core", "packages/application-core/source/standalone_application.d", "libraries/runtime/application-core/source/vibe3d/runtime/application_core/standalone_application.d", "standalone_application", "vibe3d.runtime.application_core.standalone_application"),
    Wave19Module("application-core", "packages/application-core/tests/source/tests/unit/application_core_population_test.d", "libraries/runtime/application-core/tests/source/vibe3d/runtime/application_core/tests/unit/application_core_population_test.d", "tests.unit.application_core_population_test", "vibe3d.runtime.application_core.tests.unit.application_core_population_test"),
    Wave19Module("application-core", "packages/application-core/tests/source/tests/unit/command_invocation_test.d", "libraries/runtime/application-core/tests/source/vibe3d/runtime/application_core/tests/unit/command_invocation_test.d", "tests.unit.command_invocation_test", "vibe3d.runtime.application_core.tests.unit.command_invocation_test"),
    Wave19Module("application-core", "packages/application-core/tests/source/tests/unit/standalone_application_test.d", "libraries/runtime/application-core/tests/source/vibe3d/runtime/application_core/tests/unit/standalone_application_test.d", "tests.unit.standalone_application_test", "vibe3d.runtime.application_core.tests.unit.standalone_application_test"),
    Wave19Module("camera-model", "packages/camera-model/source/view.d", "libraries/viewport/camera/source/vibe3d/viewport/camera/view.d", "view", "vibe3d.viewport.camera.view"),
    Wave19Module("camera-model", "packages/camera-model/tests/source/tests/unit/camera_model_population_test.d", "libraries/viewport/camera/tests/source/vibe3d/viewport/camera/tests/unit/camera_model_population_test.d", "tests.unit.camera_model_population_test", "vibe3d.viewport.camera.tests.unit.camera_model_population_test"),
    Wave19Module("camera-model", "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d", "libraries/viewport/camera/tests/source/vibe3d/viewport/camera/tests/unit/view_source_cells_test.d", "tests.unit.view_source_cells_test", "vibe3d.viewport.camera.tests.unit.view_source_cells_test"),
    Wave19Module("camera-model", "packages/camera-model/tests/source/tests/unit/view_test.d", "libraries/viewport/camera/tests/source/vibe3d/viewport/camera/tests/unit/view_test.d", "tests.unit.view_test", "vibe3d.viewport.camera.tests.unit.view_test"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command.d", "command", "vibe3d.editing.commands.runtime.command"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_args.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_args.d", "command_args", "vibe3d.editing.commands.runtime.command_args"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_executor.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_executor.d", "command_executor", "vibe3d.editing.commands.runtime.command_executor"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_history.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_history.d", "command_history", "vibe3d.editing.commands.runtime.command_history"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_invocation.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_invocation.d", "command_invocation", "vibe3d.editing.commands.runtime.command_invocation"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_registry.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_registry.d", "command_registry", "vibe3d.editing.commands.runtime.command_registry"),
    Wave19Module("command-runtime", "packages/command-runtime/source/command_tool_policy.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/command_tool_policy.d", "command_tool_policy", "vibe3d.editing.commands.runtime.command_tool_policy"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/history/redo.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/commands/history/redo.d", "commands.history.redo", "vibe3d.editing.commands.runtime.commands.history.redo"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/history/undo.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/commands/history/undo.d", "commands.history.undo", "vibe3d.editing.commands.runtime.commands.history.undo"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/gesture_payload.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/gesture_payload.d", "commands.mesh.gesture_payload", "vibe3d.editing.commands.editor.commands.mesh.gesture_payload"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/mesh_edit_payload.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/mesh_edit_payload.d", "commands.mesh.mesh_edit_payload", "vibe3d.editing.commands.editor.commands.mesh.mesh_edit_payload"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/select.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/select.d", "commands.mesh.select", "vibe3d.editing.commands.editor.commands.mesh.select"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/selection_undo.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/selection_undo.d", "commands.mesh.selection_undo", "vibe3d.editing.commands.editor.commands.mesh.selection_undo"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/session_edit.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/session_edit.d", "commands.mesh.session_edit", "vibe3d.editing.commands.editor.commands.mesh.session_edit"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/triple.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/triple.d", "commands.mesh.triple", "vibe3d.editing.commands.editor.commands.mesh.triple"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/mesh/vertex_edit.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/editor/commands/mesh/vertex_edit.d", "commands.mesh.vertex_edit", "vibe3d.editing.commands.editor.commands.mesh.vertex_edit"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/select/drop.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/commands/select/drop.d", "commands.select.drop", "vibe3d.editing.commands.runtime.commands.select.drop"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/select/element.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/commands/select/element.d", "commands.select.element", "vibe3d.editing.commands.runtime.commands.select.element"),
    Wave19Module("command-runtime", "packages/command-runtime/source/commands/select/invert.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/commands/select/invert.d", "commands.select.invert", "vibe3d.editing.commands.runtime.commands.select.invert"),
    Wave19Module("command-runtime", "packages/command-runtime/source/history_lifecycle_contract.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/history_lifecycle_contract.d", "history_lifecycle_contract", "vibe3d.editing.commands.runtime.history_lifecycle_contract"),
    Wave19Module("command-runtime", "packages/command-runtime/source/record_observer_hub.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/record_observer_hub.d", "record_observer_hub", "vibe3d.editing.commands.runtime.record_observer_hub"),
    Wave19Module("command-runtime", "packages/command-runtime/source/tool_activation_ownership.d", "libraries/editing/commands/runtime/source/vibe3d/editing/commands/runtime/tool_activation_ownership.d", "tool_activation_ownership", "vibe3d.editing.commands.runtime.tool_activation_ownership"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/base_revert_flag_test.d", "tests.unit.base_revert_flag_test", "vibe3d.editing.commands.runtime.tests.unit.base_revert_flag_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_apply_anchor_test.d", "tests.unit.command_apply_anchor_test", "vibe3d.editing.commands.runtime.tests.unit.command_apply_anchor_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_bindargs_test.d", "tests.unit.command_bindargs_test", "vibe3d.editing.commands.runtime.tests.unit.command_bindargs_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_history_source_public_test.d", "tests.unit.command_history_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.command_history_source_public_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_registry_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_registry_test.d", "tests.unit.command_registry_test", "vibe3d.editing.commands.runtime.tests.unit.command_registry_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_runtime_population_test.d", "tests.unit.command_runtime_population_test", "vibe3d.editing.commands.runtime.tests.unit.command_runtime_population_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/command_source_public_test.d", "tests.unit.command_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.command_source_public_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/commands/mesh/session_edit_source_public_test.d", "tests.unit.commands.mesh.session_edit_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.mesh.session_edit_source_public_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/commands/select/element_source_public_test.d", "tests.unit.commands.select.element_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.select.element_source_public_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/record_observer_hub_source_public_test.d", "tests.unit.record_observer_hub_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.record_observer_hub_source_public_test"),
    Wave19Module("command-runtime", "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d", "libraries/editing/commands/runtime/tests/source/vibe3d/editing/commands/runtime/tests/unit/session_edit_payload_test.d", "tests.unit.session_edit_payload_test", "vibe3d.editing.commands.runtime.tests.unit.session_edit_payload_test"),
    Wave19Module("creation-ops", "packages/creation-ops/source/tools/create/pen_geometry.d", "libraries/editing/tools/creation/source/vibe3d/editing/tools/creation/tools/create/pen_geometry.d", "tools.create.pen_geometry", "vibe3d.editing.tools.creation.tools.create.pen_geometry"),
    Wave19Module("creation-ops", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "libraries/editing/tools/creation/tests/source/vibe3d/editing/tools/creation/tests/unit/tools/create/pen_geometry_population_test.d", "tests.unit.tools.create.pen_geometry_population_test", "vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_population_test"),
    Wave19Module("creation-ops", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_test.d", "libraries/editing/tools/creation/tests/source/vibe3d/editing/tools/creation/tests/unit/tools/create/pen_geometry_test.d", "tests.unit.tools.create.pen_geometry_test", "vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_test"),
    Wave19Module("display-policy", "packages/display-policy/source/camera_stamp.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/camera_stamp.d", "camera_stamp", "vibe3d.viewport.display_policy.camera_stamp"),
    Wave19Module("display-policy", "packages/display-policy/source/display_state.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/display_state.d", "display_state", "vibe3d.viewport.display_policy.display_state"),
    Wave19Module("display-policy", "packages/display-policy/source/light_rig.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/light_rig.d", "light_rig", "vibe3d.viewport.display_policy.light_rig"),
    Wave19Module("display-policy", "packages/display-policy/source/retopology_dot_cull.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/retopology_dot_cull.d", "retopology_dot_cull", "vibe3d.viewport.display_policy.retopology_dot_cull"),
    Wave19Module("display-policy", "packages/display-policy/source/retopology_line_shade.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/retopology_line_shade.d", "retopology_line_shade", "vibe3d.viewport.display_policy.retopology_line_shade"),
    Wave19Module("display-policy", "packages/display-policy/source/retopology_order.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/retopology_order.d", "retopology_order", "vibe3d.viewport.display_policy.retopology_order"),
    Wave19Module("display-policy", "packages/display-policy/source/select_visibility.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/select_visibility.d", "select_visibility", "vibe3d.viewport.display_policy.select_visibility"),
    Wave19Module("display-policy", "packages/display-policy/source/vertex_normals.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/vertex_normals.d", "vertex_normals", "vibe3d.viewport.display_policy.vertex_normals"),
    Wave19Module("display-policy", "packages/display-policy/source/viewport_overlay_mode.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/viewport_overlay_mode.d", "viewport_overlay_mode", "vibe3d.viewport.display_policy.viewport_overlay_mode"),
    Wave19Module("display-policy", "packages/display-policy/source/viewport_probe_sampling.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/viewport_probe_sampling.d", "viewport_probe_sampling", "vibe3d.viewport.display_policy.viewport_probe_sampling"),
    Wave19Module("display-policy", "packages/display-policy/source/viewport_scheme.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/viewport_scheme.d", "viewport_scheme", "vibe3d.viewport.display_policy.viewport_scheme"),
    Wave19Module("display-policy", "packages/display-policy/source/weightmap_view.d", "libraries/viewport/display-policy/source/vibe3d/viewport/display_policy/weightmap_view.d", "weightmap_view", "vibe3d.viewport.display_policy.weightmap_view"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/camera_stamp_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/camera_stamp_test.d", "tests.unit.camera_stamp_test", "vibe3d.viewport.display_policy.tests.unit.camera_stamp_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/display_policy_population_test.d", "tests.unit.display_policy_population_test", "vibe3d.viewport.display_policy.tests.unit.display_policy_population_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/retopology_display_model_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/retopology_display_model_test.d", "tests.unit.retopology_display_model_test", "vibe3d.viewport.display_policy.tests.unit.retopology_display_model_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/retopology_dot_cull_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/retopology_dot_cull_test.d", "tests.unit.retopology_dot_cull_test", "vibe3d.viewport.display_policy.tests.unit.retopology_dot_cull_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/retopology_line_shade_algorithm_cells_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/retopology_line_shade_algorithm_cells_test.d", "tests.unit.retopology_line_shade_algorithm_cells_test", "vibe3d.viewport.display_policy.tests.unit.retopology_line_shade_algorithm_cells_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/retopology_order_algorithm_cells_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/retopology_order_algorithm_cells_test.d", "tests.unit.retopology_order_algorithm_cells_test", "vibe3d.viewport.display_policy.tests.unit.retopology_order_algorithm_cells_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/select_visibility_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/select_visibility_test.d", "tests.unit.select_visibility_test", "vibe3d.viewport.display_policy.tests.unit.select_visibility_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/vertex_normals_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/vertex_normals_test.d", "tests.unit.vertex_normals_test", "vibe3d.viewport.display_policy.tests.unit.vertex_normals_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/viewport_scheme_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/viewport_scheme_test.d", "tests.unit.viewport_scheme_test", "vibe3d.viewport.display_policy.tests.unit.viewport_scheme_test"),
    Wave19Module("display-policy", "packages/display-policy/tests/source/tests/unit/weightmap_state_test.d", "libraries/viewport/display-policy/tests/source/vibe3d/viewport/display_policy/tests/unit/weightmap_state_test.d", "tests.unit.weightmap_state_test", "vibe3d.viewport.display_policy.tests.unit.weightmap_state_test"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/file/quit.d", "libraries/runtime/document-actions/source/vibe3d/apps/desktop/commands/file/quit.d", "commands.file.quit", "vibe3d.apps.desktop.commands.file.quit"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/image/commands.d", "libraries/runtime/document-actions/source/vibe3d/runtime/document_actions/commands/image/commands.d", "commands.image.commands", "vibe3d.runtime.document_actions.commands.image.commands"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/image_plane/commands.d", "libraries/runtime/document-actions/source/vibe3d/runtime/document_actions/commands/image_plane/commands.d", "commands.image_plane.commands", "vibe3d.runtime.document_actions.commands.image_plane.commands"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/layer/commands.d", "libraries/runtime/document-actions/source/vibe3d/runtime/document_actions/commands/layer/commands.d", "commands.layer.commands", "vibe3d.runtime.document_actions.commands.layer.commands"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/scene/load_mesh.d", "libraries/runtime/document-actions/source/vibe3d/runtime/document_actions/commands/scene/load_mesh.d", "commands.scene.load_mesh", "vibe3d.runtime.document_actions.commands.scene.load_mesh"),
    Wave19Module("document-actions", "packages/document-actions/source/commands/scene/reset.d", "libraries/runtime/document-actions/source/vibe3d/runtime/document_actions/commands/scene/reset.d", "commands.scene.reset", "vibe3d.runtime.document_actions.commands.scene.reset"),
    Wave19Module("document-actions", "packages/document-actions/tests/source/tests/unit/commands/image/commands_test.d", "libraries/runtime/document-actions/tests/source/vibe3d/runtime/document_actions/tests/unit/commands/image/commands_test.d", "tests.unit.commands.image.commands_test", "vibe3d.runtime.document_actions.tests.unit.commands.image.commands_test"),
    Wave19Module("document-actions", "packages/document-actions/tests/source/tests/unit/commands/layer/add_injection_range_test.d", "libraries/runtime/document-actions/tests/source/vibe3d/runtime/document_actions/tests/unit/commands/layer/add_injection_range_test.d", "tests.unit.commands.layer.add_injection_range_test", "vibe3d.runtime.document_actions.tests.unit.commands.layer.add_injection_range_test"),
    Wave19Module("document-actions", "packages/document-actions/tests/source/tests/unit/commands/layer/commands_source_public_test.d", "libraries/runtime/document-actions/tests/source/vibe3d/runtime/document_actions/tests/unit/commands/layer/commands_source_public_test.d", "tests.unit.commands.layer.commands_source_public_test", "vibe3d.runtime.document_actions.tests.unit.commands.layer.commands_source_public_test"),
    Wave19Module("document-channels", "packages/document-channels/source/layer_params.d", "libraries/documents/channels/source/vibe3d/documents/channels/layer_params.d", "layer_params", "vibe3d.documents.channels.layer_params"),
    Wave19Module("document-channels", "packages/document-channels/tests/source/tests/unit/document_channels_population_test.d", "libraries/documents/channels/tests/source/vibe3d/documents/channels/tests/unit/document_channels_population_test.d", "tests.unit.document_channels_population_test", "vibe3d.documents.channels.tests.unit.document_channels_population_test"),
    Wave19Module("document-channels", "packages/document-channels/tests/source/tests/unit/layer_params_test.d", "libraries/documents/channels/tests/source/vibe3d/documents/channels/tests/unit/layer_params_test.d", "tests.unit.layer_params_test", "vibe3d.documents.channels.tests.unit.layer_params_test"),
    Wave19Module("document-io", "packages/document-io/source/io/file_model.d", "libraries/documents/io/source/vibe3d/documents/io/io/file_model.d", "io.file_model", "vibe3d.documents.io.io.file_model"),
    Wave19Module("document-io", "packages/document-io/source/io/image_path.d", "libraries/documents/io/source/vibe3d/documents/io/io/image_path.d", "io.image_path", "vibe3d.documents.io.io.image_path"),
    Wave19Module("document-io", "packages/document-io/source/io/native.d", "libraries/documents/io/source/vibe3d/documents/io/io/native.d", "io.native", "vibe3d.documents.io.io.native"),
    Wave19Module("document-io", "packages/document-io/tests/source/tests/unit/document_io_population_test.d", "libraries/documents/io/tests/source/vibe3d/documents/io/tests/unit/document_io_population_test.d", "tests.unit.document_io_population_test", "vibe3d.documents.io.tests.unit.document_io_population_test"),
    Wave19Module("document-io", "packages/document-io/tests/source/tests/unit/io/image_path_test.d", "libraries/documents/io/tests/source/vibe3d/documents/io/tests/unit/io/image_path_test.d", "tests.unit.io.image_path_test", "vibe3d.documents.io.tests.unit.io.image_path_test"),
    Wave19Module("document-io", "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d", "libraries/documents/io/tests/source/vibe3d/documents/io/tests/unit/io/native_source_cells_test.d", "tests.unit.io.native_source_cells_test", "vibe3d.documents.io.tests.unit.io.native_source_cells_test"),
    Wave19Module("document-io", "packages/document-io/tests/source/tests/unit/io/native_test.d", "libraries/documents/io/tests/source/vibe3d/documents/io/tests/unit/io/native_test.d", "tests.unit.io.native_test", "vibe3d.documents.io.tests.unit.io.native_test"),
    Wave19Module("document-model", "packages/document-model/source/document.d", "libraries/documents/model/source/vibe3d/documents/model/document.d", "document", "vibe3d.documents.model.document"),
    Wave19Module("document-model", "packages/document-model/source/document_selection.d", "libraries/documents/model/source/vibe3d/documents/model/document_selection.d", "document_selection", "vibe3d.documents.model.document_selection"),
    Wave19Module("document-model", "packages/document-model/source/edit_target_contract.d", "libraries/documents/model/source/vibe3d/documents/model/edit_target_contract.d", "edit_target_contract", "vibe3d.documents.model.edit_target_contract"),
    Wave19Module("document-model", "packages/document-model/source/image_data.d", "libraries/documents/model/source/vibe3d/documents/model/image_data.d", "image_data", "vibe3d.documents.model.image_data"),
    Wave19Module("document-model", "packages/document-model/source/item_kinds.d", "libraries/documents/model/source/vibe3d/documents/model/item_kinds.d", "item_kinds", "vibe3d.documents.model.item_kinds"),
    Wave19Module("document-model", "packages/document-model/tests/source/tests/unit/document_test.d", "libraries/documents/model/tests/source/vibe3d/documents/model/tests/unit/document_test.d", "tests.unit.document_test", "vibe3d.documents.model.tests.unit.document_test"),
    Wave19Module("edit-contracts", "packages/edit-contracts/source/editmode.d", "libraries/editing/contracts/source/vibe3d/editing/contracts/editmode.d", "editmode", "vibe3d.editing.contracts.editmode"),
    Wave19Module("edit-contracts", "packages/edit-contracts/source/prepared_tool_effect.d", "libraries/editing/contracts/source/vibe3d/editing/contracts/prepared_tool_effect.d", "prepared_tool_effect", "vibe3d.editing.contracts.prepared_tool_effect"),
    Wave19Module("edit-contracts", "packages/edit-contracts/source/seltype.d", "libraries/editing/contracts/source/vibe3d/editing/contracts/seltype.d", "seltype", "vibe3d.editing.contracts.seltype"),
    Wave19Module("edit-contracts", "packages/edit-contracts/source/tool_policy_values.d", "libraries/editing/contracts/source/vibe3d/editing/contracts/tool_policy_values.d", "tool_policy_values", "vibe3d.editing.contracts.tool_policy_values"),
    Wave19Module("edit-contracts", "packages/edit-contracts/tests/source/tests/unit/seltype_test.d", "libraries/editing/contracts/tests/source/vibe3d/editing/contracts/tests/unit/seltype_test.d", "tests.unit.seltype_test", "vibe3d.editing.contracts.tests.unit.seltype_test"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/history/clear.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/history/clear.d", "commands.history.clear", "vibe3d.editing.commands.editor.commands.history.clear"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/history/save_as_script.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/history/save_as_script.d", "commands.history.save_as_script", "vibe3d.editing.commands.editor.commands.history.save_as_script"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/history/show.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/history/show.d", "commands.history.show", "vibe3d.editing.commands.editor.commands.history.show"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/layer/xform_edit.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/layer/xform_edit.d", "commands.layer.xform_edit", "vibe3d.editing.commands.editor.commands.layer.xform_edit"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/macros/record.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/macros/record.d", "commands.macros.record", "vibe3d.editing.commands.editor.commands.macros.record"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/macros/save_recorded.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/macros/save_recorded.d", "commands.macros.save_recorded", "vibe3d.editing.commands.editor.commands.macros.save_recorded"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/add_point.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/add_point.d", "commands.mesh.add_point", "vibe3d.editing.commands.editor.commands.mesh.add_point"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/array_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/array_.d", "commands.mesh.array_", "vibe3d.editing.commands.editor.commands.mesh.array_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/axis_slice.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/axis_slice.d", "commands.mesh.axis_slice", "vibe3d.editing.commands.editor.commands.mesh.axis_slice"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/bevel.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/bevel.d", "commands.mesh.bevel", "vibe3d.editing.commands.editor.commands.mesh.bevel"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/bridge.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/bridge.d", "commands.mesh.bridge", "vibe3d.editing.commands.editor.commands.mesh.bridge"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/cleanup.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/cleanup.d", "commands.mesh.cleanup", "vibe3d.editing.commands.editor.commands.mesh.cleanup"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/clone_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/clone_.d", "commands.mesh.clone_", "vibe3d.editing.commands.editor.commands.mesh.clone_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/collapse.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/collapse.d", "commands.mesh.collapse", "vibe3d.editing.commands.editor.commands.mesh.collapse"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/copy_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/copy_.d", "commands.mesh.copy_", "vibe3d.editing.commands.editor.commands.mesh.copy_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/cut_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/cut_.d", "commands.mesh.cut_", "vibe3d.editing.commands.editor.commands.mesh.cut_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/delete_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/delete_.d", "commands.mesh.delete_", "vibe3d.editing.commands.editor.commands.mesh.delete_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/detriangulate.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/detriangulate.d", "commands.mesh.detriangulate", "vibe3d.editing.commands.editor.commands.mesh.detriangulate"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/duplicate_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/duplicate_.d", "commands.mesh.duplicate_", "vibe3d.editing.commands.editor.commands.mesh.duplicate_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_crease.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_crease.d", "commands.mesh.edge_crease", "vibe3d.editing.commands.editor.commands.mesh.edge_crease"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_extend.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_extend.d", "commands.mesh.edge_extend", "vibe3d.editing.commands.editor.commands.mesh.edge_extend"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_extrude.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_extrude.d", "commands.mesh.edge_extrude", "vibe3d.editing.commands.editor.commands.mesh.edge_extrude"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_join.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_join.d", "commands.mesh.edge_join", "vibe3d.editing.commands.editor.commands.mesh.edge_join"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_slice.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_slice.d", "commands.mesh.edge_slice", "vibe3d.editing.commands.editor.commands.mesh.edge_slice"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/edge_slide.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/edge_slide.d", "commands.mesh.edge_slide", "vibe3d.editing.commands.editor.commands.mesh.edge_slide"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/face_extrude.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/face_extrude.d", "commands.mesh.face_extrude", "vibe3d.editing.commands.editor.commands.mesh.face_extrude"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/fix_orientation.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/fix_orientation.d", "commands.mesh.fix_orientation", "vibe3d.editing.commands.editor.commands.mesh.fix_orientation"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/flip.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/flip.d", "commands.mesh.flip", "vibe3d.editing.commands.editor.commands.mesh.flip"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/hide.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/hide.d", "commands.mesh.hide", "vibe3d.editing.commands.editor.commands.mesh.hide"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/jitter.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/jitter.d", "commands.mesh.jitter", "vibe3d.editing.commands.editor.commands.mesh.jitter"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/linear_align.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/linear_align.d", "commands.mesh.linear_align", "vibe3d.editing.commands.editor.commands.mesh.linear_align"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/loop_slice.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/loop_slice.d", "commands.mesh.loop_slice", "vibe3d.editing.commands.editor.commands.mesh.loop_slice"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/make_polygon.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/make_polygon.d", "commands.mesh.make_polygon", "vibe3d.editing.commands.editor.commands.mesh.make_polygon"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/map_edit_undo.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/map_edit_undo.d", "commands.mesh.map_edit_undo", "vibe3d.editing.commands.editor.commands.mesh.map_edit_undo"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/merge.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/merge.d", "commands.mesh.merge", "vibe3d.editing.commands.editor.commands.mesh.merge"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/mirror_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/mirror_.d", "commands.mesh.mirror_", "vibe3d.editing.commands.editor.commands.mesh.mirror_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/morph_edit.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/morph_edit.d", "commands.mesh.morph_edit", "vibe3d.editing.commands.editor.commands.mesh.morph_edit"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/move_vertex.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/move_vertex.d", "commands.mesh.move_vertex", "vibe3d.editing.commands.editor.commands.mesh.move_vertex"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/paste_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/paste_.d", "commands.mesh.paste_", "vibe3d.editing.commands.editor.commands.mesh.paste_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/poly_inset.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/poly_inset.d", "commands.mesh.poly_inset", "vibe3d.editing.commands.editor.commands.mesh.poly_inset"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/polygon_align.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/polygon_align.d", "commands.mesh.polygon_align", "vibe3d.editing.commands.editor.commands.mesh.polygon_align"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/position_undo.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/position_undo.d", "commands.mesh.position_undo", "vibe3d.editing.commands.editor.commands.mesh.position_undo"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/quadruple.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/quadruple.d", "commands.mesh.quadruple", "vibe3d.editing.commands.editor.commands.mesh.quadruple"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/quantize.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/quantize.d", "commands.mesh.quantize", "vibe3d.editing.commands.editor.commands.mesh.quantize"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/radial_align.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/radial_align.d", "commands.mesh.radial_align", "vibe3d.editing.commands.editor.commands.mesh.radial_align"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/radial_array_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/radial_array_.d", "commands.mesh.radial_array_", "vibe3d.editing.commands.editor.commands.mesh.radial_array_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/reduce.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/reduce.d", "commands.mesh.reduce", "vibe3d.editing.commands.editor.commands.mesh.reduce"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/remove_.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/remove_.d", "commands.mesh.remove_", "vibe3d.editing.commands.editor.commands.mesh.remove_"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/screen_slice.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/screen_slice.d", "commands.mesh.screen_slice", "vibe3d.editing.commands.editor.commands.mesh.screen_slice"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/selection_edit.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/selection_edit.d", "commands.mesh.selection_edit", "vibe3d.editing.commands.editor.commands.mesh.selection_edit"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/set_material.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/set_material.d", "commands.mesh.set_material", "vibe3d.editing.commands.editor.commands.mesh.set_material"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/set_part.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/set_part.d", "commands.mesh.set_part", "vibe3d.editing.commands.editor.commands.mesh.set_part"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/smooth_shift.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/smooth_shift.d", "commands.mesh.smooth_shift", "vibe3d.editing.commands.editor.commands.mesh.smooth_shift"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/spikey.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/spikey.d", "commands.mesh.spikey", "vibe3d.editing.commands.editor.commands.mesh.spikey"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/spin_edge.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/spin_edge.d", "commands.mesh.spin_edge", "vibe3d.editing.commands.editor.commands.mesh.spin_edge"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/split_edge.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/split_edge.d", "commands.mesh.split_edge", "vibe3d.editing.commands.editor.commands.mesh.split_edge"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/split_face.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/split_face.d", "commands.mesh.split_face", "vibe3d.editing.commands.editor.commands.mesh.split_face"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/stroke_extrude.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/stroke_extrude.d", "commands.mesh.stroke_extrude", "vibe3d.editing.commands.editor.commands.mesh.stroke_extrude"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/subdivide.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/subdivide.d", "commands.mesh.subdivide", "vibe3d.editing.commands.editor.commands.mesh.subdivide"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/subdivide_faceted.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/subdivide_faceted.d", "commands.mesh.subdivide_faceted", "vibe3d.editing.commands.editor.commands.mesh.subdivide_faceted"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/subpatch_toggle.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/subpatch_toggle.d", "commands.mesh.subpatch_toggle", "vibe3d.editing.commands.editor.commands.mesh.subpatch_toggle"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/surface_attr.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/surface_attr.d", "commands.mesh.surface_attr", "vibe3d.editing.commands.editor.commands.mesh.surface_attr"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/sweep.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/sweep.d", "commands.mesh.sweep", "vibe3d.editing.commands.editor.commands.mesh.sweep"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/symmetrize.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/symmetrize.d", "commands.mesh.symmetrize", "vibe3d.editing.commands.editor.commands.mesh.symmetrize"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/thicken.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/thicken.d", "commands.mesh.thicken", "vibe3d.editing.commands.editor.commands.mesh.thicken"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/transform.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/transform.d", "commands.mesh.transform", "vibe3d.editing.commands.editor.commands.mesh.transform"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/unify.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/unify.d", "commands.mesh.unify", "vibe3d.editing.commands.editor.commands.mesh.unify"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_map_util.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_map_util.d", "commands.mesh.uv_map_util", "vibe3d.editing.commands.editor.commands.mesh.uv_map_util"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_pack.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_pack.d", "commands.mesh.uv_pack", "vibe3d.editing.commands.editor.commands.mesh.uv_pack"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_project.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_project.d", "commands.mesh.uv_project", "vibe3d.editing.commands.editor.commands.mesh.uv_project"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_relax.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_relax.d", "commands.mesh.uv_relax", "vibe3d.editing.commands.editor.commands.mesh.uv_relax"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_transform.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_transform.d", "commands.mesh.uv_transform", "vibe3d.editing.commands.editor.commands.mesh.uv_transform"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/uv_unwrap.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/uv_unwrap.d", "commands.mesh.uv_unwrap", "vibe3d.editing.commands.editor.commands.mesh.uv_unwrap"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vert_join.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vert_join.d", "commands.mesh.vert_join", "vibe3d.editing.commands.editor.commands.mesh.vert_join"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vert_merge.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vert_merge.d", "commands.mesh.vert_merge", "vibe3d.editing.commands.editor.commands.mesh.vert_merge"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_bevel.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_bevel.d", "commands.mesh.vertex_bevel", "vibe3d.editing.commands.editor.commands.mesh.vertex_bevel"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_center.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_center.d", "commands.mesh.vertex_center", "vibe3d.editing.commands.editor.commands.mesh.vertex_center"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_extrude.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_extrude.d", "commands.mesh.vertex_extrude", "vibe3d.editing.commands.editor.commands.mesh.vertex_extrude"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_new.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_new.d", "commands.mesh.vertex_new", "vibe3d.editing.commands.editor.commands.mesh.vertex_new"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_position_result.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_position_result.d", "commands.mesh.vertex_position_result", "vibe3d.editing.commands.editor.commands.mesh.vertex_position_result"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_set.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_set.d", "commands.mesh.vertex_set", "vibe3d.editing.commands.editor.commands.mesh.vertex_set"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/vertex_split.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/vertex_split.d", "commands.mesh.vertex_split", "vibe3d.editing.commands.editor.commands.mesh.vertex_split"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/weightmap.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/weightmap.d", "commands.mesh.weightmap", "vibe3d.editing.commands.editor.commands.mesh.weightmap"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/mesh/weld_vertex_pair.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/mesh/weld_vertex_pair.d", "commands.mesh.weld_vertex_pair", "vibe3d.editing.commands.editor.commands.mesh.weld_vertex_pair"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/between.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/between.d", "commands.select.between", "vibe3d.editing.commands.editor.commands.select.between"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/boundary.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/boundary.d", "commands.select.boundary", "vibe3d.editing.commands.editor.commands.select.boundary"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/by_stat.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/by_stat.d", "commands.select.by_stat", "vibe3d.editing.commands.editor.commands.select.by_stat"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/by_tag.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/by_tag.d", "commands.select.by_tag", "vibe3d.editing.commands.editor.commands.select.by_tag"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/connect.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/connect.d", "commands.select.connect", "vibe3d.editing.commands.editor.commands.select.connect"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/contract.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/contract.d", "commands.select.contract", "vibe3d.editing.commands.editor.commands.select.contract"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/convert.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/convert.d", "commands.select.convert", "vibe3d.editing.commands.editor.commands.select.convert"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/expand.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/expand.d", "commands.select.expand", "vibe3d.editing.commands.editor.commands.select.expand"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/fill.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/fill.d", "commands.select.fill", "vibe3d.editing.commands.editor.commands.select.fill"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/less.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/less.d", "commands.select.less", "vibe3d.editing.commands.editor.commands.select.less"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/loop.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/loop.d", "commands.select.loop", "vibe3d.editing.commands.editor.commands.select.loop"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/more.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/more.d", "commands.select.more", "vibe3d.editing.commands.editor.commands.select.more"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/ring.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/ring.d", "commands.select.ring", "vibe3d.editing.commands.editor.commands.select.ring"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/sets.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/sets.d", "commands.select.sets", "vibe3d.editing.commands.editor.commands.select.sets"),
    Wave19Module("editor-commands", "packages/editor-commands/source/commands/select/type_from.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/commands/select/type_from.d", "commands.select.type_from", "vibe3d.editing.commands.editor.commands.select.type_from"),
    Wave19Module("editor-commands", "packages/editor-commands/source/macro_recorder.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/macro_recorder.d", "macro_recorder", "vibe3d.editing.commands.editor.macro_recorder"),
    Wave19Module("editor-commands", "packages/editor-commands/source/step_trace.d", "libraries/editing/commands/editor/source/vibe3d/editing/commands/editor/step_trace.d", "step_trace", "vibe3d.editing.commands.editor.step_trace"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/layer/xform_edit_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/layer/xform_edit_source_public_test.d", "tests.unit.commands.layer.xform_edit_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.layer.xform_edit_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/mesh/edge_crease_source_public_test.d", "tests.unit.commands.mesh.edge_crease_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.edge_crease_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/mesh/remove_source_public_test.d", "tests.unit.commands.mesh.remove_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.remove_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/mesh/symmetrize_source_public_test.d", "tests.unit.commands.mesh.symmetrize_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.symmetrize_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/mesh/vertex_set_source_public_test.d", "tests.unit.commands.mesh.vertex_set_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.vertex_set_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/select/boundary_source_public_test.d", "tests.unit.commands.select.boundary_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.boundary_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/select/by_stat_source_public_test.d", "tests.unit.commands.select.by_stat_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.by_stat_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/select/by_tag_source_public_test.d", "tests.unit.commands.select.by_tag_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.by_tag_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/commands/select/type_from_source_public_test.d", "tests.unit.commands.select.type_from_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.type_from_source_public_test"),
    Wave19Module("editor-commands", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "libraries/editing/commands/editor/tests/source/vibe3d/editing/commands/editor/tests/unit/editor_commands_population_test.d", "tests.unit.editor_commands_population_test", "vibe3d.editing.commands.editor.tests.unit.editor_commands_population_test"),
    Wave19Module("editor-ui", "packages/editor-ui/source/args_dialog.d", "libraries/ui/editor/source/vibe3d/ui/editor/args_dialog.d", "args_dialog", "vibe3d.ui.editor.args_dialog"),
    Wave19Module("editor-ui", "packages/editor-ui/source/buttonset.d", "libraries/ui/editor/source/vibe3d/ui/editor/buttonset.d", "buttonset", "vibe3d.ui.editor.buttonset"),
    Wave19Module("editor-ui", "packages/editor-ui/source/copilot_overlay.d", "libraries/ui/editor/source/vibe3d/ui/editor/copilot_overlay.d", "copilot_overlay", "vibe3d.ui.editor.copilot_overlay"),
    Wave19Module("editor-ui", "packages/editor-ui/source/copilot_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/copilot_panel.d", "copilot_panel", "vibe3d.ui.editor.copilot_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/forms_render.d", "libraries/ui/editor/source/vibe3d/ui/editor/forms_render.d", "forms_render", "vibe3d.ui.editor.forms_render"),
    Wave19Module("editor-ui", "packages/editor-ui/source/imgui_event_gate.d", "libraries/ui/editor/source/vibe3d/ui/editor/imgui_event_gate.d", "imgui_event_gate", "vibe3d.ui.editor.imgui_event_gate"),
    Wave19Module("editor-ui", "packages/editor-ui/source/imgui_flag_boundary.d", "libraries/ui/editor/source/vibe3d/ui/editor/imgui_flag_boundary.d", "imgui_flag_boundary", "vibe3d.ui.editor.imgui_flag_boundary"),
    Wave19Module("editor-ui", "packages/editor-ui/source/imgui_style.d", "libraries/ui/editor/source/vibe3d/ui/editor/imgui_style.d", "imgui_style", "vibe3d.ui.editor.imgui_style"),
    Wave19Module("editor-ui", "packages/editor-ui/source/pie_geometry.d", "libraries/ui/editor/source/vibe3d/ui/editor/pie_geometry.d", "pie_geometry", "vibe3d.ui.editor.pie_geometry"),
    Wave19Module("editor-ui", "packages/editor-ui/source/pie_menus.d", "libraries/ui/editor/source/vibe3d/ui/editor/pie_menus.d", "pie_menus", "vibe3d.ui.editor.pie_menus"),
    Wave19Module("editor-ui", "packages/editor-ui/source/pie_state.d", "libraries/ui/editor/source/vibe3d/ui/editor/pie_state.d", "pie_state", "vibe3d.ui.editor.pie_state"),
    Wave19Module("editor-ui", "packages/editor-ui/source/popup_state.d", "libraries/ui/editor/source/vibe3d/ui/editor/popup_state.d", "popup_state", "vibe3d.ui.editor.popup_state"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/action_menu.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/action_menu.d", "ui.action_menu", "vibe3d.ui.editor.ui.action_menu"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/availability.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/availability.d", "ui.availability", "vibe3d.ui.editor.ui.availability"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/button_face.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/button_face.d", "ui.button_face", "vibe3d.ui.editor.ui.button_face"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/channel_rows.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/channel_rows.d", "ui.channel_rows", "vibe3d.ui.editor.ui.channel_rows"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/channels_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/channels_panel.d", "ui.channels_panel", "vibe3d.ui.editor.ui.channels_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/command_notice.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/command_notice.d", "ui.command_notice", "vibe3d.ui.editor.ui.command_notice"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/dock_drag.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/dock_drag.d", "ui.dock_drag", "vibe3d.ui.editor.ui.dock_drag"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/guard_modal_state.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/guard_modal_state.d", "ui.guard_modal_state", "vibe3d.ui.editor.ui.guard_modal_state"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/history_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/history_panel.d", "ui.history_panel", "vibe3d.ui.editor.ui.history_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/image_list_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/image_list_panel.d", "ui.image_list_panel", "vibe3d.ui.editor.ui.image_list_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/image_rows.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/image_rows.d", "ui.image_rows", "vibe3d.ui.editor.ui.image_rows"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/imgui_window_class.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/imgui_window_class.d", "ui.imgui_window_class", "vibe3d.ui.editor.ui.imgui_window_class"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/item_glyphs.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/item_glyphs.d", "ui.item_glyphs", "vibe3d.ui.editor.ui.item_glyphs"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/item_rename.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/item_rename.d", "ui.item_rename", "vibe3d.ui.editor.ui.item_rename"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/item_rows.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/item_rows.d", "ui.item_rows", "vibe3d.ui.editor.ui.item_rows"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/layer_list_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/layer_list_panel.d", "ui.layer_list_panel", "vibe3d.ui.editor.ui.layer_list_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/mode_popup.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/mode_popup.d", "ui.mode_popup", "vibe3d.ui.editor.ui.mode_popup"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/panel_chrome.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/panel_chrome.d", "ui.panel_chrome", "vibe3d.ui.editor.ui.panel_chrome"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/panel_host_roles.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/panel_host_roles.d", "ui.panel_host_roles", "vibe3d.ui.editor.ui.panel_host_roles"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/panels.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/panels.d", "ui.panels", "vibe3d.ui.editor.ui.panels"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/pie_record.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/pie_record.d", "ui.pie_record", "vibe3d.ui.editor.ui.pie_record"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/pie_render.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/pie_render.d", "ui.pie_render", "vibe3d.ui.editor.ui.pie_render"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/remesh_modal_state.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/remesh_modal_state.d", "ui.remesh_modal_state", "vibe3d.ui.editor.ui.remesh_modal_state"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/retained_item.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/retained_item.d", "ui.retained_item", "vibe3d.ui.editor.ui.retained_item"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/stat_record.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/stat_record.d", "ui.stat_record", "vibe3d.ui.editor.ui.stat_record"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/stat_rows.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/stat_rows.d", "ui.stat_rows", "vibe3d.ui.editor.ui.stat_rows"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/tool_properties_panel.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/tool_properties_panel.d", "ui.tool_properties_panel", "vibe3d.ui.editor.ui.tool_properties_panel"),
    Wave19Module("editor-ui", "packages/editor-ui/source/ui/viewport_props_role.d", "libraries/ui/editor/source/vibe3d/ui/editor/ui/viewport_props_role.d", "ui.viewport_props_role", "vibe3d.ui.editor.ui.viewport_props_role"),
    Wave19Module("editor-ui", "packages/editor-ui/tests/source/tests/unit/ui/channel_rows_test.d", "libraries/ui/editor/tests/source/vibe3d/ui/editor/tests/unit/ui/channel_rows_test.d", "tests.unit.ui.channel_rows_test", "vibe3d.ui.editor.tests.unit.ui.channel_rows_test"),
    Wave19Module("editor-ui", "packages/editor-ui/tests/source/tests/unit/ui/command_notice_test.d", "libraries/ui/editor/tests/source/vibe3d/ui/editor/tests/unit/ui/command_notice_test.d", "tests.unit.ui.command_notice_test", "vibe3d.ui.editor.tests.unit.ui.command_notice_test"),
    Wave19Module("editor-ui", "packages/editor-ui/tests/source/tests/unit/ui/stat_rows_test.d", "libraries/ui/editor/tests/source/vibe3d/ui/editor/tests/unit/ui/stat_rows_test.d", "tests.unit.ui.stat_rows_test", "vibe3d.ui.editor.tests.unit.ui.stat_rows_test"),
    Wave19Module("editor-ui", "packages/editor-ui/tests/source/ui/availability_source_test.d", "libraries/ui/editor/tests/source/vibe3d/ui/editor/ui/availability_source_test.d", "ui.availability_source_test", "vibe3d.ui.editor.ui.availability_source_test"),
    Wave19Module("editor-ui", "packages/editor-ui/tests/source/ui/item_click_source_test.d", "libraries/ui/editor/tests/source/vibe3d/ui/editor/ui/item_click_source_test.d", "ui.item_click_source_test", "vibe3d.ui.editor.ui.item_click_source_test"),
    Wave19Module("forms-model", "packages/forms-model/source/forms.d", "libraries/ui/forms/source/vibe3d/ui/forms/forms.d", "forms", "vibe3d.ui.forms.forms"),
    Wave19Module("forms-model", "packages/forms-model/tests/source/forms_source_test.d", "libraries/ui/forms/tests/source/vibe3d/ui/forms/forms_source_test.d", "forms_source_test", "vibe3d.ui.forms.forms_source_test"),
    Wave19Module("http-runtime", "packages/http-runtime/source/http_server.d", "libraries/runtime/http/source/vibe3d/runtime/http/http_server.d", "http_server", "vibe3d.runtime.http.http_server"),
    Wave19Module("http-runtime", "packages/http-runtime/source/http_transport.d", "libraries/runtime/http/source/vibe3d/runtime/http/http_transport.d", "http_transport", "vibe3d.runtime.http.http_transport"),
    Wave19Module("http-runtime", "packages/http-runtime/source/playback_controller.d", "libraries/runtime/http/source/vibe3d/runtime/http/playback_controller.d", "playback_controller", "vibe3d.runtime.http.playback_controller"),
    Wave19Module("image-codec", "packages/image-codec/source/io/image_decode.d", "libraries/documents/image-codec/source/vibe3d/documents/image_codec/io/image_decode.d", "io.image_decode", "vibe3d.documents.image_codec.io.image_decode"),
    Wave19Module("image-codec", "packages/image-codec/tests/source/tests/unit/image_codec_population_test.d", "libraries/documents/image-codec/tests/source/vibe3d/documents/image_codec/tests/unit/image_codec_population_test.d", "tests.unit.image_codec_population_test", "vibe3d.documents.image_codec.tests.unit.image_codec_population_test"),
    Wave19Module("image-codec", "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d", "libraries/documents/image-codec/tests/source/vibe3d/documents/image_codec/tests/unit/io/image_decode_source_cells_test.d", "tests.unit.io.image_decode_source_cells_test", "vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test"),
    Wave19Module("image-codec", "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d", "libraries/documents/image-codec/tests/source/vibe3d/documents/image_codec/tests/unit/io/image_decode_test.d", "tests.unit.io.image_decode_test", "vibe3d.documents.image_codec.tests.unit.io.image_decode_test"),
    Wave19Module("input-events", "packages/input-events/source/eventlog.d", "libraries/platform/input/source/vibe3d/platform/input/eventlog.d", "eventlog", "vibe3d.platform.input.eventlog"),
    Wave19Module("input-events", "packages/input-events/source/held_gesture_buttons.d", "libraries/platform/input/source/vibe3d/platform/input/held_gesture_buttons.d", "held_gesture_buttons", "vibe3d.platform.input.held_gesture_buttons"),
    Wave19Module("input-events", "packages/input-events/source/input_context.d", "libraries/platform/input/source/vibe3d/platform/input/input_context.d", "input_context", "vibe3d.platform.input.input_context"),
    Wave19Module("input-events", "packages/input-events/source/input_zones.d", "libraries/platform/input/source/vibe3d/platform/input/input_zones.d", "input_zones", "vibe3d.platform.input.input_zones"),
    Wave19Module("input-events", "packages/input-events/source/sdl_error.d", "libraries/platform/input/source/vibe3d/platform/input/sdl_error.d", "sdl_error", "vibe3d.platform.input.sdl_error"),
    Wave19Module("input-events", "packages/input-events/source/shortcuts.d", "libraries/platform/input/source/vibe3d/platform/input/shortcuts.d", "shortcuts", "vibe3d.platform.input.shortcuts"),
    Wave19Module("input-events", "packages/input-events/source/tool_input.d", "libraries/platform/input/source/vibe3d/platform/input/tool_input.d", "tool_input", "vibe3d.platform.input.tool_input"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/binding_resolve_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/binding_resolve_test.d", "tests.unit.binding_resolve_test", "vibe3d.platform.input.tests.unit.binding_resolve_test"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/eventlog_parser_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/eventlog_parser_test.d", "tests.unit.eventlog_parser_test", "vibe3d.platform.input.tests.unit.eventlog_parser_test"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/eventlog_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/eventlog_test.d", "tests.unit.eventlog_test", "vibe3d.platform.input.tests.unit.eventlog_test"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/input_events_population_test.d", "tests.unit.input_events_population_test", "vibe3d.platform.input.tests.unit.input_events_population_test"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/sdl_error_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/sdl_error_test.d", "tests.unit.sdl_error_test", "vibe3d.platform.input.tests.unit.sdl_error_test"),
    Wave19Module("input-events", "packages/input-events/tests/source/tests/unit/tool_input_test.d", "libraries/platform/input/tests/source/vibe3d/platform/input/tests/unit/tool_input_test.d", "tests.unit.tool_input_test", "vibe3d.platform.input.tests.unit.tool_input_test"),
    Wave19Module("interaction-data", "packages/interaction-data/source/ai/advisor.d", "libraries/editing/interaction/data/source/vibe3d/editing/interaction/data/ai/advisor.d", "ai.advisor", "vibe3d.editing.interaction.data.ai.advisor"),
    Wave19Module("interaction-data", "packages/interaction-data/source/ai/debug_trace.d", "libraries/editing/interaction/data/source/vibe3d/editing/interaction/data/ai/debug_trace.d", "ai.debug_trace", "vibe3d.editing.interaction.data.ai.debug_trace"),
    Wave19Module("interaction-data", "packages/interaction-data/source/ai/interaction.d", "libraries/editing/interaction/data/source/vibe3d/editing/interaction/data/ai/interaction.d", "ai.interaction", "vibe3d.editing.interaction.data.ai.interaction"),
    Wave19Module("interaction-data", "packages/interaction-data/tests/source/tests/unit/ai/advisor_test.d", "libraries/editing/interaction/data/tests/source/vibe3d/editing/interaction/data/tests/unit/ai/advisor_test.d", "tests.unit.ai.advisor_test", "vibe3d.editing.interaction.data.tests.unit.ai.advisor_test"),
    Wave19Module("interaction-data", "packages/interaction-data/tests/source/tests/unit/ai/debug_trace_test.d", "libraries/editing/interaction/data/tests/source/vibe3d/editing/interaction/data/tests/unit/ai/debug_trace_test.d", "tests.unit.ai.debug_trace_test", "vibe3d.editing.interaction.data.tests.unit.ai.debug_trace_test"),
    Wave19Module("interaction-data", "packages/interaction-data/tests/source/tests/unit/ai/interaction_test.d", "libraries/editing/interaction/data/tests/source/vibe3d/editing/interaction/data/tests/unit/ai/interaction_test.d", "tests.unit.ai.interaction_test", "vibe3d.editing.interaction.data.tests.unit.ai.interaction_test"),
    Wave19Module("interaction-query", "packages/interaction-query/source/constraint.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/constraint.d", "constraint", "vibe3d.editing.selection.query.constraint"),
    Wave19Module("interaction-query", "packages/interaction-query/source/hover_state.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/hover_state.d", "hover_state", "vibe3d.editing.selection.query.hover_state"),
    Wave19Module("interaction-query", "packages/interaction-query/source/mesh_bbox.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/mesh_bbox.d", "mesh_bbox", "vibe3d.editing.selection.query.mesh_bbox"),
    Wave19Module("interaction-query", "packages/interaction-query/source/mesh_visibility.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/mesh_visibility.d", "mesh_visibility", "vibe3d.editing.selection.query.mesh_visibility"),
    Wave19Module("interaction-query", "packages/interaction-query/source/path.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/path.d", "path", "vibe3d.editing.selection.query.path"),
    Wave19Module("interaction-query", "packages/interaction-query/source/snap.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/snap.d", "snap", "vibe3d.editing.selection.query.snap"),
    Wave19Module("interaction-query", "packages/interaction-query/source/snap_election.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/snap_election.d", "snap_election", "vibe3d.editing.selection.query.snap_election"),
    Wave19Module("interaction-query", "packages/interaction-query/source/surface_pick.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/surface_pick.d", "surface_pick", "vibe3d.editing.selection.query.surface_pick"),
    Wave19Module("interaction-query", "packages/interaction-query/source/symmetry.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/symmetry.d", "symmetry", "vibe3d.editing.selection.query.symmetry"),
    Wave19Module("interaction-query", "packages/interaction-query/source/toolpipe/guide.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/toolpipe/guide.d", "toolpipe.guide", "vibe3d.editing.selection.query.toolpipe.guide"),
    Wave19Module("interaction-query", "packages/interaction-query/source/viewgrid.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/viewgrid.d", "viewgrid", "vibe3d.editing.selection.query.viewgrid"),
    Wave19Module("interaction-query", "packages/interaction-query/source/workplane_fit.d", "libraries/editing/selection/query/source/vibe3d/editing/selection/query/workplane_fit.d", "workplane_fit", "vibe3d.editing.selection.query.workplane_fit"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/constraint_regression_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/constraint_regression_test.d", "tests.unit.constraint_regression_test", "vibe3d.editing.selection.query.tests.unit.constraint_regression_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/constraint_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/constraint_test.d", "tests.unit.constraint_test", "vibe3d.editing.selection.query.tests.unit.constraint_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/path_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/path_test.d", "tests.unit.path_test", "vibe3d.editing.selection.query.tests.unit.path_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/snap_election_corpus_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/snap_election_corpus_test.d", "tests.unit.snap_election_corpus_test", "vibe3d.editing.selection.query.tests.unit.snap_election_corpus_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/snap_regression_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/snap_regression_test.d", "tests.unit.snap_regression_test", "vibe3d.editing.selection.query.tests.unit.snap_regression_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/snap_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/snap_test.d", "tests.unit.snap_test", "vibe3d.editing.selection.query.tests.unit.snap_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/symmetry_regression_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/symmetry_regression_test.d", "tests.unit.symmetry_regression_test", "vibe3d.editing.selection.query.tests.unit.symmetry_regression_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/viewgrid_regression_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/viewgrid_regression_test.d", "tests.unit.viewgrid_regression_test", "vibe3d.editing.selection.query.tests.unit.viewgrid_regression_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/viewgrid_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/viewgrid_test.d", "tests.unit.viewgrid_test", "vibe3d.editing.selection.query.tests.unit.viewgrid_test"),
    Wave19Module("interaction-query", "packages/interaction-query/tests/source/tests/unit/workplane_fit_test.d", "libraries/editing/selection/query/tests/source/vibe3d/editing/selection/query/tests/unit/workplane_fit_test.d", "tests.unit.workplane_fit_test", "vibe3d.editing.selection.query.tests.unit.workplane_fit_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/falloff.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/falloff.d", "commands.falloff", "vibe3d.editing.tools.interactive.commands.falloff"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/mesh/smooth.d", "libraries/editing/tools/interactive/source/vibe3d/editing/commands/editor/commands/mesh/smooth.d", "commands.mesh.smooth", "vibe3d.editing.commands.editor.commands.mesh.smooth"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/attr.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/attr.d", "commands.tool.attr", "vibe3d.editing.tools.interactive.commands.tool.attr"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/begin_session.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/begin_session.d", "commands.tool.begin_session", "vibe3d.editing.tools.interactive.commands.tool.begin_session"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/bridge_headless.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/bridge_headless.d", "commands.tool.bridge_headless", "vibe3d.editing.tools.interactive.commands.tool.bridge_headless"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/do_apply.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/do_apply.d", "commands.tool.do_apply", "vibe3d.editing.tools.interactive.commands.tool.do_apply"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/headless.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/headless.d", "commands.tool.headless", "vibe3d.editing.tools.interactive.commands.tool.headless"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/host.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/host.d", "commands.tool.host", "vibe3d.editing.tools.interactive.commands.tool.host"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/lifecycle.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/lifecycle.d", "commands.tool.lifecycle", "vibe3d.editing.tools.interactive.commands.tool.lifecycle"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/panel_edit.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/panel_edit.d", "commands.tool.panel_edit", "vibe3d.editing.tools.interactive.commands.tool.panel_edit"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/pipe.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/pipe.d", "commands.tool.pipe", "vibe3d.editing.tools.interactive.commands.tool.pipe"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/reset.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/reset.d", "commands.tool.reset", "vibe3d.editing.tools.interactive.commands.tool.reset"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/commands/tool/set.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/commands/tool/set.d", "commands.tool.set", "vibe3d.editing.tools.interactive.commands.tool.set"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/coord_rounding.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/coord_rounding.d", "coord_rounding", "vibe3d.editing.tools.interactive.coord_rounding"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/deform_magnet.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/deform_magnet.d", "deform_magnet", "vibe3d.editing.tools.interactive.deform_magnet"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/drag.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/drag.d", "drag", "vibe3d.editing.tools.interactive.drag"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/edit_session.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/edit_session.d", "edit_session", "vibe3d.editing.tools.interactive.edit_session"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/evaluated_move_weld.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/evaluated_move_weld.d", "evaluated_move_weld", "vibe3d.editing.tools.interactive.evaluated_move_weld"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/falloff_handles.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/falloff_handles.d", "falloff_handles", "vibe3d.editing.tools.interactive.falloff_handles"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/falloff_render.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/falloff_render.d", "falloff_render", "vibe3d.editing.tools.interactive.falloff_render"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/gizmo.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/gizmo.d", "gizmo", "vibe3d.editing.tools.interactive.gizmo"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/handler.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/handler.d", "handler", "vibe3d.editing.tools.interactive.handler"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/handles/arbiter.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/handles/arbiter.d", "handles.arbiter", "vibe3d.editing.tools.interactive.handles.arbiter"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/handles/gizmo_metrics.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/handles/gizmo_metrics.d", "handles.gizmo_metrics", "vibe3d.editing.tools.interactive.handles.gizmo_metrics"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/handles/gl_util.d", "handles.gl_util", "vibe3d.editing.tools.interactive.handles.gl_util"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/handles/shapes.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/handles/shapes.d", "handles.shapes", "vibe3d.editing.tools.interactive.handles.shapes"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/model_preview.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/model_preview.d", "model_preview", "vibe3d.editing.tools.interactive.model_preview"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/overlay_space.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/overlay_space.d", "overlay_space", "vibe3d.editing.tools.interactive.overlay_space"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/params_widgets.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/params_widgets.d", "params_widgets", "vibe3d.editing.tools.interactive.params_widgets"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/pipe_gizmo_host.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/pipe_gizmo_host.d", "pipe_gizmo_host", "vibe3d.editing.tools.interactive.pipe_gizmo_host"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_box_param.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_box_param.d", "prepared_box_param", "vibe3d.editing.tools.interactive.prepared_box_param"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_bridge_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_bridge_activation.d", "prepared_bridge_activation", "vibe3d.editing.tools.interactive.prepared_bridge_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_command_wrapper_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_command_wrapper_activation.d", "prepared_command_wrapper_activation", "vibe3d.editing.tools.interactive.prepared_command_wrapper_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_bevel_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_bevel_activation.d", "prepared_edge_bevel_activation", "vibe3d.editing.tools.interactive.prepared_edge_bevel_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_extend_deactivate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_extend_deactivate.d", "prepared_edge_extend_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_extend_tool_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_extend_tool_activation.d", "prepared_edge_extend_tool_activation", "vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_extrude_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_extrude_activation.d", "prepared_edge_extrude_activation", "vibe3d.editing.tools.interactive.prepared_edge_extrude_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_slice_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_slice_activation.d", "prepared_edge_slice_activation", "vibe3d.editing.tools.interactive.prepared_edge_slice_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_edge_slice_deactivate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_edge_slice_deactivate.d", "prepared_edge_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_inherited_noop.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_inherited_noop.d", "prepared_inherited_noop", "vibe3d.editing.tools.interactive.prepared_inherited_noop"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_loop_slice_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_loop_slice_activation.d", "prepared_loop_slice_activation", "vibe3d.editing.tools.interactive.prepared_loop_slice_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_loop_slice_deactivate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_loop_slice_deactivate.d", "prepared_loop_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_mirror_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_mirror_activation.d", "prepared_mirror_activation", "vibe3d.editing.tools.interactive.prepared_mirror_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_move_update.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_move_update.d", "prepared_move_update", "vibe3d.editing.tools.interactive.prepared_move_update"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_param_update.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_param_update.d", "prepared_param_update", "vibe3d.editing.tools.interactive.prepared_param_update"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_pipe_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_pipe_activation.d", "prepared_pipe_activation", "vibe3d.editing.tools.interactive.prepared_pipe_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_poly_bevel_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_poly_bevel_activation.d", "prepared_poly_bevel_activation", "vibe3d.editing.tools.interactive.prepared_poly_bevel_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_poly_extrude_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_poly_extrude_activation.d", "prepared_poly_extrude_activation", "vibe3d.editing.tools.interactive.prepared_poly_extrude_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_poly_inset_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_poly_inset_activation.d", "prepared_poly_inset_activation", "vibe3d.editing.tools.interactive.prepared_poly_inset_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_private_state.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_private_state.d", "prepared_private_state", "vibe3d.editing.tools.interactive.prepared_private_state"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_radial_array_transition.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_radial_array_transition.d", "prepared_radial_array_transition", "vibe3d.editing.tools.interactive.prepared_radial_array_transition"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_radial_sweep_transition.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_radial_sweep_transition.d", "prepared_radial_sweep_transition", "vibe3d.editing.tools.interactive.prepared_radial_sweep_transition"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_record_context.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_record_context.d", "prepared_record_context", "vibe3d.editing.tools.interactive.prepared_record_context"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_rotate_update.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_rotate_update.d", "prepared_rotate_update", "vibe3d.editing.tools.interactive.prepared_rotate_update"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_scale_update.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_scale_update.d", "prepared_scale_update", "vibe3d.editing.tools.interactive.prepared_scale_update"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_selection_profile.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_selection_profile.d", "prepared_selection_profile", "vibe3d.editing.tools.interactive.prepared_selection_profile"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_selection_profile_image.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_selection_profile_image.d", "prepared_selection_profile_image", "vibe3d.editing.tools.interactive.prepared_selection_profile_image"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_slice_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_slice_activation.d", "prepared_slice_activation", "vibe3d.editing.tools.interactive.prepared_slice_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_slice_deactivate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_slice_deactivate.d", "prepared_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_slice_deactivate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_smooth_shift_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_smooth_shift_activation.d", "prepared_smooth_shift_activation", "vibe3d.editing.tools.interactive.prepared_smooth_shift_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_stroke_extrude_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_stroke_extrude_activation.d", "prepared_stroke_extrude_activation", "vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_tack_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_tack_activation.d", "prepared_tack_activation", "vibe3d.editing.tools.interactive.prepared_tack_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_tool_transition.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_tool_transition.d", "prepared_tool_transition", "vibe3d.editing.tools.interactive.prepared_tool_transition"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_topology_pen_activation.d", "prepared_topology_pen_activation", "vibe3d.editing.tools.interactive.prepared_topology_pen_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_deactivate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_topology_pen_deactivate.d", "prepared_topology_pen_deactivate", "vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_update.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_topology_pen_update.d", "prepared_topology_pen_update", "vibe3d.editing.tools.interactive.prepared_topology_pen_update"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_transform_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_transform_activation.d", "prepared_transform_activation", "vibe3d.editing.tools.interactive.prepared_transform_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_transform_product_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_transform_product_activation.d", "prepared_transform_product_activation", "vibe3d.editing.tools.interactive.prepared_transform_product_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_vertex_bevel_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_vertex_bevel_activation.d", "prepared_vertex_bevel_activation", "vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_vertex_extrude_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_vertex_extrude_activation.d", "prepared_vertex_extrude_activation", "vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_vertex_merge_activation.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_vertex_merge_activation.d", "prepared_vertex_merge_activation", "vibe3d.editing.tools.interactive.prepared_vertex_merge_activation"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_activation_session.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_activation_session.d", "prepared_xfrm_activation_session", "vibe3d.editing.tools.interactive.prepared_xfrm_activation_session"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_refire_state.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_refire_state.d", "prepared_xfrm_refire_state", "vibe3d.editing.tools.interactive.prepared_xfrm_refire_state"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_replay.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_replay.d", "prepared_xfrm_replay", "vibe3d.editing.tools.interactive.prepared_xfrm_replay"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_slot_poll.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_slot_poll.d", "prepared_xfrm_slot_poll", "vibe3d.editing.tools.interactive.prepared_xfrm_slot_poll"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_boundary.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_update_boundary.d", "prepared_xfrm_update_boundary", "vibe3d.editing.tools.interactive.prepared_xfrm_update_boundary"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_edit_close.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_update_edit_close.d", "prepared_xfrm_update_edit_close", "vibe3d.editing.tools.interactive.prepared_xfrm_update_edit_close"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_tail.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/prepared_xfrm_update_tail.d", "prepared_xfrm_update_tail", "vibe3d.editing.tools.interactive.prepared_xfrm_update_tail"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/property_panel.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/property_panel.d", "property_panel", "vibe3d.editing.tools.interactive.property_panel"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/registry.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/registry.d", "registry", "vibe3d.editing.tools.interactive.registry"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/snap_render.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/snap_render.d", "snap_render", "vibe3d.editing.tools.interactive.snap_render"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tool.d", "tool", "vibe3d.editing.tools.interactive.tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tool_attr_bounds.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tool_attr_bounds.d", "tool_attr_bounds", "vibe3d.editing.tools.interactive.tool_attr_bounds"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tool_disarm.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tool_disarm.d", "tool_disarm", "vibe3d.editing.tools.interactive.tool_disarm"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tool_presets.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tool_presets.d", "tool_presets", "vibe3d.editing.tools.interactive.tool_presets"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/array_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/array_tool.d", "tools.alignment.array_tool", "vibe3d.editing.tools.interactive.tools.alignment.array_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/clone_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/clone_tool.d", "tools.alignment.clone_tool", "vibe3d.editing.tools.interactive.tools.alignment.clone_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/linear_align_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/linear_align_tool.d", "tools.alignment.linear_align_tool", "vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/mirror.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/mirror.d", "tools.alignment.mirror", "vibe3d.editing.tools.interactive.tools.alignment.mirror"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/radial_align_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/radial_align_tool.d", "tools.alignment.radial_align_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/radial_array_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/radial_array_tool.d", "tools.alignment.radial_array_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/alignment/radial_sweep_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/alignment/radial_sweep_tool.d", "tools.alignment.radial_sweep_tool", "vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/common/command_wrapper.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/common/command_wrapper.d", "tools.common.command_wrapper", "vibe3d.editing.tools.interactive.tools.common.command_wrapper"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/arc.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/arc.d", "tools.create.arc", "vibe3d.editing.tools.interactive.tools.create.arc"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/box.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/box.d", "tools.create.box", "vibe3d.editing.tools.interactive.tools.create.box"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/capsule.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/capsule.d", "tools.create.capsule", "vibe3d.editing.tools.interactive.tools.create.capsule"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/cone.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/cone.d", "tools.create.cone", "vibe3d.editing.tools.interactive.tools.create.cone"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/create_common.d", "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/cylinder.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/cylinder.d", "tools.create.cylinder", "vibe3d.editing.tools.interactive.tools.create.cylinder"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/pen.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/pen.d", "tools.create.pen", "vibe3d.editing.tools.interactive.tools.create.pen"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/primitive_create_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/primitive_create_tool.d", "tools.create.primitive_create_tool", "vibe3d.editing.tools.interactive.tools.create.primitive_create_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/sphere.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/sphere.d", "tools.create.sphere", "vibe3d.editing.tools.interactive.tools.create.sphere"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/torus.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/torus.d", "tools.create.torus", "vibe3d.editing.tools.interactive.tools.create.torus"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/tube.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/tube.d", "tools.create.tube", "vibe3d.editing.tools.interactive.tools.create.tube"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/create/vertex_place.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/create/vertex_place.d", "tools.create.vertex_place", "vibe3d.editing.tools.interactive.tools.create.vertex_place"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/deform/bend.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/deform/bend.d", "tools.deform.bend", "vibe3d.editing.tools.interactive.tools.deform.bend"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/deform/magnet.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/deform/magnet.d", "tools.deform.magnet", "vibe3d.editing.tools.interactive.tools.deform.magnet"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/deform/push.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/deform/push.d", "tools.deform.push", "vibe3d.editing.tools.interactive.tools.deform.push"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/deform/smooth_shift_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/deform/smooth_shift_tool.d", "tools.deform.smooth_shift_tool", "vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/deform/stroke_extrude_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/deform/stroke_extrude_tool.d", "tools.deform.stroke_extrude_tool", "vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/bridge_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/bridge_tool.d", "tools.edit.bridge_tool", "vibe3d.editing.tools.interactive.tools.edit.bridge_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/edge_bevel.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/edge_bevel.d", "tools.edit.edge_bevel", "vibe3d.editing.tools.interactive.tools.edit.edge_bevel"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/edge_extend.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/edge_extend.d", "tools.edit.edge_extend", "vibe3d.editing.tools.interactive.tools.edit.edge_extend"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/edge_extrude.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/edge_extrude.d", "tools.edit.edge_extrude", "vibe3d.editing.tools.interactive.tools.edit.edge_extrude"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/haul_axis_latch.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/haul_axis_latch.d", "tools.edit.haul_axis_latch", "vibe3d.editing.tools.interactive.tools.edit.haul_axis_latch"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/poly_bevel.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/poly_bevel.d", "tools.edit.poly_bevel", "vibe3d.editing.tools.interactive.tools.edit.poly_bevel"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/poly_extrude.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/poly_extrude.d", "tools.edit.poly_extrude", "vibe3d.editing.tools.interactive.tools.edit.poly_extrude"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/poly_inset_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/poly_inset_tool.d", "tools.edit.poly_inset_tool", "vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/reduce.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/reduce.d", "tools.edit.reduce", "vibe3d.editing.tools.interactive.tools.edit.reduce"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/smooth_relax.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/smooth_relax.d", "tools.edit.smooth_relax", "vibe3d.editing.tools.interactive.tools.edit.smooth_relax"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/tack.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/tack.d", "tools.edit.tack", "vibe3d.editing.tools.interactive.tools.edit.tack"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/defs.d", "tools.edit.topology_pen.defs", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.defs"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/json.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/json.d", "tools.edit.topology_pen.json", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.json"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/package.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/package.d", "tools.edit.topology_pen", "vibe3d.editing.tools.interactive.tools.edit.topology_pen"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/render.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/render.d", "tools.edit.topology_pen.render", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.render"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/snap_guide.d", "tools.edit.topology_pen.snap_guide", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.snap_guide"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/tool.d", "tools.edit.topology_pen.tool", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/vert_merge_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/vert_merge_tool.d", "tools.edit.vert_merge_tool", "vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/vertex_bevel_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/vertex_bevel_tool.d", "tools.edit.vertex_bevel_tool", "vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/edit/vertex_extrude_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/edit/vertex_extrude_tool.d", "tools.edit.vertex_extrude_tool", "vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/slice/edge_slice_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/slice/edge_slice_tool.d", "tools.slice.edge_slice_tool", "vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/slice/edge_slide.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/slice/edge_slide.d", "tools.slice.edge_slide", "vibe3d.editing.tools.interactive.tools.slice.edge_slide"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/slice/loop_slice_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/slice/loop_slice_tool.d", "tools.slice.loop_slice_tool", "vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/slice/slice_tool.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/slice/slice_tool.d", "tools.slice.slice_tool", "vibe3d.editing.tools.interactive.tools.slice.slice_tool"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/topology_step.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/topology_step.d", "tools.topology_step", "vibe3d.editing.tools.interactive.tools.topology_step"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/move.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/move.d", "tools.transform.move", "vibe3d.editing.tools.interactive.tools.transform.move"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/rotate.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/rotate.d", "tools.transform.rotate", "vibe3d.editing.tools.interactive.tools.transform.rotate"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/scale.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/scale.d", "tools.transform.scale", "vibe3d.editing.tools.interactive.tools.transform.scale"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/transform.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/transform.d", "tools.transform.transform", "vibe3d.editing.tools.interactive.tools.transform.transform"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/xfrm_apply.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/xfrm_apply.d", "tools.transform.xfrm_apply", "vibe3d.editing.tools.interactive.tools.transform.xfrm_apply"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/xfrm_handles.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/xfrm_handles.d", "tools.transform.xfrm_handles", "vibe3d.editing.tools.interactive.tools.transform.xfrm_handles"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/xfrm_item.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/xfrm_item.d", "tools.transform.xfrm_item", "vibe3d.editing.tools.interactive.tools.transform.xfrm_item"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/tools/transform/xfrm_transform.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/tools/transform/xfrm_transform.d", "tools.transform.xfrm_transform", "vibe3d.editing.tools.interactive.tools.transform.xfrm_transform"),
    Wave19Module("interactive-tools", "packages/interactive-tools/source/value_drag.d", "libraries/editing/tools/interactive/source/vibe3d/editing/tools/interactive/value_drag.d", "value_drag", "vibe3d.editing.tools.interactive.value_drag"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/drag_identity.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/drag_identity.d", "drag_identity", "vibe3d.editing.tools.interactive.drag_identity"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/drag_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/drag_source_cells.d", "drag_source_cells", "vibe3d.editing.tools.interactive.drag_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/drag_source_helpers.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/drag_source_helpers.d", "drag_source_helpers", "vibe3d.editing.tools.interactive.drag_source_helpers"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/handles/arbiter_source_cells.d", "handles.arbiter_source_cells", "vibe3d.editing.tools.interactive.handles.arbiter_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/handles/gl_util_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/handles/gl_util_source_cells.d", "handles.gl_util_source_cells", "vibe3d.editing.tools.interactive.handles.gl_util_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/overlay_space_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/overlay_space_source_cells.d", "overlay_space_source_cells", "vibe3d.editing.tools.interactive.overlay_space_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_bridge_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_bridge_activation_source_cells.d", "prepared_bridge_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_bridge_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_command_wrapper_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_command_wrapper_activation_source_cells.d", "prepared_command_wrapper_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_command_wrapper_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_bevel_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_bevel_activation_source_cells.d", "prepared_edge_bevel_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_bevel_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_extend_deactivate_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_extend_deactivate_source_cells.d", "prepared_edge_extend_deactivate_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_extend_tool_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_extend_tool_activation_source_cells.d", "prepared_edge_extend_tool_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_extrude_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_extrude_activation_source_cells.d", "prepared_edge_extrude_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_extrude_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_slice_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_slice_activation_source_cells.d", "prepared_edge_slice_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_slice_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_edge_slice_deactivate_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_edge_slice_deactivate_source_cells.d", "prepared_edge_slice_deactivate_source_cells", "vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_inherited_noop_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_inherited_noop_source_cells.d", "prepared_inherited_noop_source_cells", "vibe3d.editing.tools.interactive.prepared_inherited_noop_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_loop_slice_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_loop_slice_activation_source_cells.d", "prepared_loop_slice_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_loop_slice_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_loop_slice_deactivate_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_loop_slice_deactivate_source_cells.d", "prepared_loop_slice_deactivate_source_cells", "vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_mirror_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_mirror_activation_source_cells.d", "prepared_mirror_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_mirror_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_move_update_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_move_update_source_cells.d", "prepared_move_update_source_cells", "vibe3d.editing.tools.interactive.prepared_move_update_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_pipe_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_pipe_activation_source_cells.d", "prepared_pipe_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_pipe_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_poly_bevel_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_poly_bevel_activation_source_cells.d", "prepared_poly_bevel_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_poly_bevel_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_poly_extrude_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_poly_extrude_activation_source_cells.d", "prepared_poly_extrude_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_poly_extrude_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_poly_inset_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_poly_inset_activation_source_cells.d", "prepared_poly_inset_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_poly_inset_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_private_state_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_private_state_source_cells.d", "prepared_private_state_source_cells", "vibe3d.editing.tools.interactive.prepared_private_state_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_radial_array_transition_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_radial_array_transition_source_cells.d", "prepared_radial_array_transition_source_cells", "vibe3d.editing.tools.interactive.prepared_radial_array_transition_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_radial_sweep_transition_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_radial_sweep_transition_source_cells.d", "prepared_radial_sweep_transition_source_cells", "vibe3d.editing.tools.interactive.prepared_radial_sweep_transition_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_record_context_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_record_context_source_cells.d", "prepared_record_context_source_cells", "vibe3d.editing.tools.interactive.prepared_record_context_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_rotate_update_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_rotate_update_source_cells.d", "prepared_rotate_update_source_cells", "vibe3d.editing.tools.interactive.prepared_rotate_update_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_scale_update_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_scale_update_source_cells.d", "prepared_scale_update_source_cells", "vibe3d.editing.tools.interactive.prepared_scale_update_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_selection_profile_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_selection_profile_source_cells.d", "prepared_selection_profile_source_cells", "vibe3d.editing.tools.interactive.prepared_selection_profile_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_slice_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_slice_activation_source_cells.d", "prepared_slice_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_slice_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_slice_deactivate_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_slice_deactivate_source_cells.d", "prepared_slice_deactivate_source_cells", "vibe3d.editing.tools.interactive.prepared_slice_deactivate_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_smooth_shift_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_smooth_shift_activation_source_cells.d", "prepared_smooth_shift_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_smooth_shift_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_stroke_extrude_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_stroke_extrude_activation_source_cells.d", "prepared_stroke_extrude_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_tack_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_tack_activation_source_cells.d", "prepared_tack_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_tack_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_topology_pen_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_topology_pen_activation_source_cells.d", "prepared_topology_pen_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_topology_pen_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_topology_pen_deactivate_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_topology_pen_deactivate_source_cells.d", "prepared_topology_pen_deactivate_source_cells", "vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_topology_pen_update_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_topology_pen_update_source_cells.d", "prepared_topology_pen_update_source_cells", "vibe3d.editing.tools.interactive.prepared_topology_pen_update_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_transform_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_transform_activation_source_cells.d", "prepared_transform_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_transform_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_transform_product_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_transform_product_activation_source_cells.d", "prepared_transform_product_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_transform_product_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_vertex_bevel_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_vertex_bevel_activation_source_cells.d", "prepared_vertex_bevel_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_vertex_extrude_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_vertex_extrude_activation_source_cells.d", "prepared_vertex_extrude_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_vertex_merge_activation_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_vertex_merge_activation_source_cells.d", "prepared_vertex_merge_activation_source_cells", "vibe3d.editing.tools.interactive.prepared_vertex_merge_activation_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/prepared_xfrm_activation_session_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/prepared_xfrm_activation_session_source_cells.d", "prepared_xfrm_activation_session_source_cells", "vibe3d.editing.tools.interactive.prepared_xfrm_activation_session_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/registry_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/registry_source_cells.d", "registry_source_cells", "vibe3d.editing.tools.interactive.registry_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/snap_render_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/snap_render_source_cells.d", "snap_render_source_cells", "vibe3d.editing.tools.interactive.snap_render_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/snap_render_source_helpers.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/snap_render_source_helpers.d", "snap_render_source_helpers", "vibe3d.editing.tools.interactive.snap_render_source_helpers"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/bevel_cold_arm_param_image_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/unit/bevel_cold_arm_param_image_test.d", "unit.bevel_cold_arm_param_image_test", "vibe3d.editing.tools.interactive.unit.bevel_cold_arm_param_image_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/close_reason_table_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/close_reason_table_test.d", "tests.unit.close_reason_table_test", "vibe3d.editing.tools.interactive.tests.unit.close_reason_table_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/command_history_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/command_history_test.d", "tests.unit.command_history_test", "vibe3d.editing.tools.interactive.tests.unit.command_history_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/command_wrapper_result_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/command_wrapper_result_test.d", "tests.unit.command_wrapper_result_test", "vibe3d.editing.tools.interactive.tests.unit.command_wrapper_result_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/edge_slide_result_builder_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/commands/mesh/edge_slide_result_builder_test.d", "tests.unit.commands.mesh.edge_slide_result_builder_test", "vibe3d.editing.tools.interactive.tests.unit.commands.mesh.edge_slide_result_builder_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/commands/mesh/jitter_result_builder_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/commands/mesh/jitter_result_builder_test.d", "tests.unit.commands.mesh.jitter_result_builder_test", "vibe3d.editing.tools.interactive.tests.unit.commands.mesh.jitter_result_builder_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/constraint_surface_at_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/constraint_surface_at_test.d", "tests.unit.constraint_surface_at_test", "vibe3d.editing.tools.interactive.tests.unit.constraint_surface_at_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/deform_magnet_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/deform_magnet_test.d", "tests.unit.deform_magnet_test", "vibe3d.editing.tools.interactive.tests.unit.deform_magnet_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/drag_gain_oblique_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/drag_gain_oblique_test.d", "tests.unit.drag_gain_oblique_test", "vibe3d.editing.tools.interactive.tests.unit.drag_gain_oblique_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/edge_slice_locate_base_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/edge_slice_locate_base_test.d", "tests.unit.edge_slice_locate_base_test", "vibe3d.editing.tools.interactive.tests.unit.edge_slice_locate_base_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/edit_session_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/edit_session_test.d", "tests.unit.edit_session_test", "vibe3d.editing.tools.interactive.tests.unit.edit_session_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/falloff_rmb_discipline_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/falloff_rmb_discipline_test.d", "falloff_rmb_discipline_test", "vibe3d.editing.tools.interactive.falloff_rmb_discipline_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/gesture_carrier_interface_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/gesture_carrier_interface_test.d", "tests.unit.gesture_carrier_interface_test", "vibe3d.editing.tools.interactive.tests.unit.gesture_carrier_interface_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/gesture_record_belt_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/gesture_record_belt_test.d", "tests.unit.gesture_record_belt_test", "vibe3d.editing.tools.interactive.tests.unit.gesture_record_belt_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/handles/gl_util_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/handles/gl_util_test.d", "tests.unit.handles.gl_util_test", "vibe3d.editing.tools.interactive.tests.unit.handles.gl_util_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/handles/shapes_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/handles/shapes_test.d", "tests.unit.handles.shapes_test", "vibe3d.editing.tools.interactive.tests.unit.handles.shapes_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/mesh_ops/bridge_frozen_kernel_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/mesh_ops/bridge_frozen_kernel_test.d", "tests.unit.mesh_ops.bridge_frozen_kernel_test", "vibe3d.editing.tools.interactive.tests.unit.mesh_ops.bridge_frozen_kernel_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/model_preview_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/model_preview_test.d", "tests.unit.model_preview_test", "vibe3d.editing.tools.interactive.tests.unit.model_preview_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/overlay_space_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/overlay_space_test.d", "tests.unit.overlay_space_test", "vibe3d.editing.tools.interactive.tests.unit.overlay_space_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/prepared_param_update_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/unit/prepared_param_update_test.d", "unit.prepared_param_update_test", "vibe3d.editing.tools.interactive.unit.prepared_param_update_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/unit/prepared_tool_transition_test.d", "unit.prepared_tool_transition_test", "vibe3d.editing.tools.interactive.unit.prepared_tool_transition_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/quad_overlay_eligibility_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/quad_overlay_eligibility_test.d", "tests.unit.quad_overlay_eligibility_test", "vibe3d.editing.tools.interactive.tests.unit.quad_overlay_eligibility_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/shared_hover_record_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/shared_hover_record_test.d", "tests.unit.shared_hover_record_test", "vibe3d.editing.tools.interactive.tests.unit.shared_hover_record_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tool_gesture_runopen_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tool_gesture_runopen_test.d", "tests.unit.tool_gesture_runopen_test", "vibe3d.editing.tools.interactive.tests.unit.tool_gesture_runopen_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tool_single_operation_equivalence_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tool_single_operation_equivalence_test.d", "tests.unit.tool_single_operation_equivalence_test", "vibe3d.editing.tools.interactive.tests.unit.tool_single_operation_equivalence_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/toolpipe/local_component_frame_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/toolpipe/local_component_frame_test.d", "tests.unit.toolpipe.local_component_frame_test", "vibe3d.editing.tools.interactive.tests.unit.toolpipe.local_component_frame_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/mirror_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/alignment/mirror_test.d", "tests.unit.tools.alignment.mirror_test", "vibe3d.editing.tools.interactive.tests.unit.tools.alignment.mirror_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/alignment/radial_sweep_tool_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/alignment/radial_sweep_tool_test.d", "tests.unit.tools.alignment.radial_sweep_tool_test", "vibe3d.editing.tools.interactive.tests.unit.tools.alignment.radial_sweep_tool_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/create/arc_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/create/arc_test.d", "tests.unit.tools.create.arc_test", "vibe3d.editing.tools.interactive.tests.unit.tools.create.arc_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/create/box_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/create/box_test.d", "tests.unit.tools.create.box_test", "vibe3d.editing.tools.interactive.tests.unit.tools.create.box_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/create/create_common_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/create/create_common_test.d", "tests.unit.tools.create.create_common_test", "vibe3d.editing.tools.interactive.tests.unit.tools.create.create_common_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/create/tube_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/create/tube_test.d", "tests.unit.tools.create.tube_test", "vibe3d.editing.tools.interactive.tests.unit.tools.create.tube_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/edit/preview_topology_churn_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/edit/preview_topology_churn_test.d", "tests.unit.tools.edit.preview_topology_churn_test", "vibe3d.editing.tools.interactive.tests.unit.tools.edit.preview_topology_churn_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/edit/smooth_relax_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/edit/smooth_relax_test.d", "tests.unit.tools.edit.smooth_relax_test", "vibe3d.editing.tools.interactive.tests.unit.tools.edit.smooth_relax_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/edit/tack_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/edit/tack_test.d", "tests.unit.tools.edit.tack_test", "vibe3d.editing.tools.interactive.tests.unit.tools.edit.tack_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/move_protocol_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/move_protocol_test.d", "tools.edit.topology_pen.move_protocol_test", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.move_protocol_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/edit/topology_pen/press_compatibility_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tools/edit/topology_pen/press_compatibility_test.d", "tools.edit.topology_pen.press_compatibility_test", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.press_compatibility_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/slice/edge_slice_tool_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/slice/edge_slice_tool_test.d", "tests.unit.tools.slice.edge_slice_tool_test", "vibe3d.editing.tools.interactive.tests.unit.tools.slice.edge_slice_tool_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/slice/loop_slice_tool_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/slice/loop_slice_tool_test.d", "tests.unit.tools.slice.loop_slice_tool_test", "vibe3d.editing.tools.interactive.tests.unit.tools.slice.loop_slice_tool_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/slice/slice_tool_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/slice/slice_tool_test.d", "tests.unit.tools.slice.slice_tool_test", "vibe3d.editing.tools.interactive.tests.unit.tools.slice.slice_tool_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/transform/move_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/transform/move_test.d", "tests.unit.tools.transform.move_test", "vibe3d.editing.tools.interactive.tests.unit.tools.transform.move_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/transform/rotate_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/transform/rotate_test.d", "tests.unit.tools.transform.rotate_test", "vibe3d.editing.tools.interactive.tests.unit.tools.transform.rotate_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/transform/scale_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/transform/scale_test.d", "tests.unit.tools.transform.scale_test", "vibe3d.editing.tools.interactive.tests.unit.tools.transform.scale_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/tools/transform/transform_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/tools/transform/transform_test.d", "tests.unit.tools.transform.transform_test", "vibe3d.editing.tools.interactive.tests.unit.tools.transform.transform_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/topology_step_mixin_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/topology_step_mixin_test.d", "tests.unit.topology_step_mixin_test", "vibe3d.editing.tools.interactive.tests.unit.topology_step_mixin_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tests/unit/wrapper_shift_apply_inheritance_test.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tests/unit/wrapper_shift_apply_inheritance_test.d", "tests.unit.wrapper_shift_apply_inheritance_test", "vibe3d.editing.tools.interactive.tests.unit.wrapper_shift_apply_inheritance_test"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tool_disarm_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tool_disarm_source_cells.d", "tool_disarm_source_cells", "vibe3d.editing.tools.interactive.tool_disarm_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tool_presets_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tool_presets_source_cells.d", "tool_presets_source_cells", "vibe3d.editing.tools.interactive.tool_presets_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tools/create/create_common_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tools/create/create_common_source_cells.d", "tools.create.create_common_source_cells", "vibe3d.editing.tools.interactive.tools.create.create_common_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tools/edit/bridge_tool_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tools/edit/bridge_tool_source_cells.d", "tools.edit.bridge_tool_source_cells", "vibe3d.editing.tools.interactive.tools.edit.bridge_tool_source_cells"),
    Wave19Module("interactive-tools", "packages/interactive-tools/tests/source/tools/edit/edge_extend_source_cells.d", "libraries/editing/tools/interactive/tests/source/vibe3d/editing/tools/interactive/tools/edit/edge_extend_source_cells.d", "tools.edit.edge_extend_source_cells", "vibe3d.editing.tools.interactive.tools.edit.edge_extend_source_cells"),
    Wave19Module("interchange", "packages/interchange/source/io/assimp_runtime.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/assimp_runtime.d", "io.assimp_runtime", "vibe3d.documents.interchange.io.assimp_runtime"),
    Wave19Module("interchange", "packages/interchange/source/io/assimp_wire.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/assimp_wire.d", "io.assimp_wire", "vibe3d.documents.interchange.io.assimp_wire"),
    Wave19Module("interchange", "packages/interchange/source/io/formats.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/formats.d", "io.formats", "vibe3d.documents.interchange.io.formats"),
    Wave19Module("interchange", "packages/interchange/source/io/lwo_export.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/lwo_export.d", "io.lwo_export", "vibe3d.documents.interchange.io.lwo_export"),
    Wave19Module("interchange", "packages/interchange/source/io/lwo_import.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/lwo_import.d", "io.lwo_import", "vibe3d.documents.interchange.io.lwo_import"),
    Wave19Module("interchange", "packages/interchange/source/io/scene_export.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/scene_export.d", "io.scene_export", "vibe3d.documents.interchange.io.scene_export"),
    Wave19Module("interchange", "packages/interchange/source/io/scene_import.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/scene_import.d", "io.scene_import", "vibe3d.documents.interchange.io.scene_import"),
    Wave19Module("interchange", "packages/interchange/source/io/scene_ir.d", "libraries/documents/interchange/source/vibe3d/documents/interchange/io/scene_ir.d", "io.scene_ir", "vibe3d.documents.interchange.io.scene_ir"),
    Wave19Module("interchange", "packages/interchange/tests/source/tests/unit/assimp_wire_test.d", "libraries/documents/interchange/tests/source/vibe3d/documents/interchange/tests/unit/assimp_wire_test.d", "tests.unit.assimp_wire_test", "vibe3d.documents.interchange.tests.unit.assimp_wire_test"),
    Wave19Module("interchange", "packages/interchange/tests/source/tests/unit/io/lwo_export_ptag_census_test.d", "libraries/documents/interchange/tests/source/vibe3d/documents/interchange/tests/unit/io/lwo_export_ptag_census_test.d", "tests.unit.io.lwo_export_ptag_census_test", "vibe3d.documents.interchange.tests.unit.io.lwo_export_ptag_census_test"),
    Wave19Module("interchange", "packages/interchange/tests/source/tests/unit/io/lwo_export_test.d", "libraries/documents/interchange/tests/source/vibe3d/documents/interchange/tests/unit/io/lwo_export_test.d", "tests.unit.io.lwo_export_test", "vibe3d.documents.interchange.tests.unit.io.lwo_export_test"),
    Wave19Module("interchange", "packages/interchange/tests/source/tests/unit/io/lwo_import_test.d", "libraries/documents/interchange/tests/source/vibe3d/documents/interchange/tests/unit/io/lwo_import_test.d", "tests.unit.io.lwo_import_test", "vibe3d.documents.interchange.tests.unit.io.lwo_import_test"),
    Wave19Module("interchange", "packages/interchange/tests/source/tests/unit/io/lwo_ptag_fixture.d", "libraries/documents/interchange/tests/source/vibe3d/documents/interchange/tests/unit/io/lwo_ptag_fixture.d", "tests.unit.io.lwo_ptag_fixture", "vibe3d.documents.interchange.tests.unit.io.lwo_ptag_fixture"),
    Wave19Module("mesh-change", "packages/mesh-change/source/change_bus.d", "libraries/mesh/change/source/vibe3d/mesh/change/change_bus.d", "change_bus", "vibe3d.mesh.change.change_bus"),
    Wave19Module("mesh-change", "packages/mesh-change/source/mesh_dirty.d", "libraries/mesh/change/source/vibe3d/mesh/change/mesh_dirty.d", "mesh_dirty", "vibe3d.mesh.change.mesh_dirty"),
    Wave19Module("mesh-contracts", "packages/mesh-contracts/source/mesh_corner_maps.d", "libraries/mesh/contracts/source/vibe3d/mesh/contracts/mesh_corner_maps.d", "mesh_corner_maps", "vibe3d.mesh.contracts.mesh_corner_maps"),
    Wave19Module("mesh-contracts", "packages/mesh-contracts/source/mesh_plane_types.d", "libraries/mesh/contracts/source/vibe3d/mesh/contracts/mesh_plane_types.d", "mesh_plane_types", "vibe3d.mesh.contracts.mesh_plane_types"),
    Wave19Module("mesh-contracts", "packages/mesh-contracts/source/mesh_scope.d", "libraries/mesh/contracts/source/vibe3d/mesh/contracts/mesh_scope.d", "mesh_scope", "vibe3d.mesh.contracts.mesh_scope"),
    Wave19Module("mesh-contracts", "packages/mesh-contracts/source/mesh_types.d", "libraries/mesh/contracts/source/vibe3d/mesh/contracts/mesh_types.d", "mesh_types", "vibe3d.mesh.contracts.mesh_types"),
    Wave19Module("mesh-contracts", "packages/mesh-contracts/tests/source/tests/unit/mesh_plane_types_test.d", "libraries/mesh/contracts/tests/source/vibe3d/mesh/contracts/tests/unit/mesh_plane_types_test.d", "tests.unit.mesh_plane_types_test", "vibe3d.mesh.contracts.tests.unit.mesh_plane_types_test"),
    Wave19Module("mesh-edit-log", "packages/mesh-edit-log/source/mesh_edit_delta.d", "libraries/mesh/edit-log/source/vibe3d/mesh/edit_log/mesh_edit_delta.d", "mesh_edit_delta", "vibe3d.mesh.edit_log.mesh_edit_delta"),
    Wave19Module("mesh-edit-log", "packages/mesh-edit-log/tests/source/mesh_edit_log_protocol_test.d", "libraries/mesh/edit-log/tests/source/vibe3d/mesh/edit_log/mesh_edit_log_protocol_test.d", "mesh_edit_log_protocol_test", "vibe3d.mesh.edit_log.mesh_edit_log_protocol_test"),
    Wave19Module("mesh-edit-replay", "packages/mesh-edit-replay/source/mesh_edit_replay.d", "libraries/mesh/edit-replay/source/vibe3d/mesh/edit_replay/mesh_edit_replay.d", "mesh_edit_replay", "vibe3d.mesh.edit_replay.mesh_edit_replay"),
    Wave19Module("mesh-edit-replay", "packages/mesh-edit-replay/tests/source/mesh_edit_replay_roundtrip_test.d", "libraries/mesh/edit-replay/tests/source/vibe3d/mesh/edit_replay/mesh_edit_replay_roundtrip_test.d", "mesh_edit_replay_roundtrip_test", "vibe3d.mesh.edit_replay.mesh_edit_replay_roundtrip_test"),
    Wave19Module("mesh-edit-replay", "packages/mesh-edit-replay/tests/source/tests/unit/mesh_edit_delta_test.d", "libraries/mesh/edit-replay/tests/source/vibe3d/mesh/edit_replay/tests/unit/mesh_edit_delta_test.d", "tests.unit.mesh_edit_delta_test", "vibe3d.mesh.edit_replay.tests.unit.mesh_edit_delta_test"),
    Wave19Module("mesh-edit-replay", "packages/mesh-edit-replay/tests/source/tests/unit/mesh_selsets_replay_test.d", "libraries/mesh/edit-replay/tests/source/vibe3d/mesh/edit_replay/tests/unit/mesh_selsets_replay_test.d", "tests.unit.mesh_selsets_replay_test", "vibe3d.mesh.edit_replay.tests.unit.mesh_selsets_replay_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/geometry_clipboard.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/geometry_clipboard.d", "geometry_clipboard", "vibe3d.mesh.ops.geometry_clipboard"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_analysis.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_analysis.d", "mesh_analysis", "vibe3d.mesh.ops.mesh_analysis"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_edge_slice.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_edge_slice.d", "mesh_edge_slice", "vibe3d.mesh.ops.mesh_edge_slice"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/bevel_curves.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/bevel_curves.d", "mesh_ops.bevel_curves", "vibe3d.mesh.ops.mesh_ops.bevel_curves"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/bevel_fin.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/bevel_fin.d", "mesh_ops.bevel_fin", "vibe3d.mesh.ops.mesh_ops.bevel_fin"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/bevel_vertex.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/bevel_vertex.d", "mesh_ops.bevel_vertex", "vibe3d.mesh.ops.mesh_ops.bevel_vertex"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/box_geom.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/box_geom.d", "mesh_ops.box_geom", "vibe3d.mesh.ops.mesh_ops.box_geom"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/bridge.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/bridge.d", "mesh_ops.bridge", "vibe3d.mesh.ops.mesh_ops.bridge"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/bridge_patch.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/bridge_patch.d", "mesh_ops.bridge_patch", "vibe3d.mesh.ops.mesh_ops.bridge_patch"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/cleanup.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/cleanup.d", "mesh_ops.cleanup", "vibe3d.mesh.ops.mesh_ops.cleanup"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/connected_mask.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/connected_mask.d", "mesh_ops.connected_mask", "vibe3d.mesh.ops.mesh_ops.connected_mask"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/cut.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/cut.d", "mesh_ops.cut", "vibe3d.mesh.ops.mesh_ops.cut"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/decimate.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/decimate.d", "mesh_ops.decimate", "vibe3d.mesh.ops.mesh_ops.decimate"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/edge_bevel.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/edge_bevel.d", "mesh_ops.edge_bevel", "vibe3d.mesh.ops.mesh_ops.edge_bevel"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/extrude.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/extrude.d", "mesh_ops.extrude", "vibe3d.mesh.ops.mesh_ops.extrude"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/face_alignment.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/face_alignment.d", "mesh_ops.face_alignment", "vibe3d.mesh.ops.mesh_ops.face_alignment"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/face_merge.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/face_merge.d", "mesh_ops.face_merge", "vibe3d.mesh.ops.mesh_ops.face_merge"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/loop_slice.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/loop_slice.d", "mesh_ops.loop_slice", "vibe3d.mesh.ops.mesh_ops.loop_slice"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/poly_bevel.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/poly_bevel.d", "mesh_ops.poly_bevel", "vibe3d.mesh.ops.mesh_ops.poly_bevel"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/revolve.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/revolve.d", "mesh_ops.revolve", "vibe3d.mesh.ops.mesh_ops.revolve"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/select_loop.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/select_loop.d", "mesh_ops.select_loop", "vibe3d.mesh.ops.mesh_ops.select_loop"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/thicken.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/thicken.d", "mesh_ops.thicken", "vibe3d.mesh.ops.mesh_ops.thicken"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_ops/triangulate.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_ops/triangulate.d", "mesh_ops.triangulate", "vibe3d.mesh.ops.mesh_ops.triangulate"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/mesh_stats.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/mesh_stats.d", "mesh_stats", "vibe3d.mesh.ops.mesh_stats"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_island.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_island.d", "uv_island", "vibe3d.mesh.ops.uv_island"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_project.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_project.d", "uv_project", "vibe3d.mesh.ops.uv_project"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_relax.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_relax.d", "uv_relax", "vibe3d.mesh.ops.uv_relax"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_transform.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_transform.d", "uv_transform", "vibe3d.mesh.ops.uv_transform"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_unwrap.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_unwrap.d", "uv_unwrap", "vibe3d.mesh.ops.uv_unwrap"),
    Wave19Module("mesh-ops", "packages/mesh-ops/source/uv_weld.d", "libraries/mesh/ops/source/vibe3d/mesh/ops/uv_weld.d", "uv_weld", "vibe3d.mesh.ops.uv_weld"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_analysis_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_analysis_test.d", "tests.unit.mesh_analysis_test", "vibe3d.mesh.ops.tests.unit.mesh_analysis_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_edge_slice_gate_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_edge_slice_gate_test.d", "tests.unit.mesh_edge_slice_gate_test", "vibe3d.mesh.ops.tests.unit.mesh_edge_slice_gate_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_edge_slice_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_edge_slice_test.d", "tests.unit.mesh_edge_slice_test", "vibe3d.mesh.ops.tests.unit.mesh_edge_slice_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/bevel_fin_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/bevel_fin_test.d", "tests.unit.mesh_ops.bevel_fin_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_fin_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/bevel_vertex_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/bevel_vertex_test.d", "tests.unit.mesh_ops.bevel_vertex_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_vertex_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/box_geom_corner_provenance_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/box_geom_corner_provenance_test.d", "tests.unit.mesh_ops.box_geom_corner_provenance_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.box_geom_corner_provenance_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/bridge_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/bridge_test.d", "tests.unit.mesh_ops.bridge_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.bridge_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/cleanup_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/cleanup_test.d", "tests.unit.mesh_ops.cleanup_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.cleanup_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/connected_mask_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/connected_mask_test.d", "tests.unit.mesh_ops.connected_mask_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.connected_mask_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/cut_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/cut_test.d", "tests.unit.mesh_ops.cut_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.cut_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/edge_fixture.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/edge_fixture.d", "tests.unit.mesh_ops.edge_fixture", "vibe3d.mesh.ops.tests.unit.mesh_ops.edge_fixture"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/extrude_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/extrude_test.d", "tests.unit.mesh_ops.extrude_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.extrude_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/face_alignment_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/face_alignment_test.d", "tests.unit.mesh_ops.face_alignment_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.face_alignment_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/face_merge_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/face_merge_test.d", "tests.unit.mesh_ops.face_merge_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.face_merge_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/loop_slice_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/loop_slice_test.d", "tests.unit.mesh_ops.loop_slice_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.loop_slice_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/poly_bevel_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/poly_bevel_test.d", "tests.unit.mesh_ops.poly_bevel_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.poly_bevel_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/revolve_seam_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/revolve_seam_test.d", "tests.unit.mesh_ops.revolve_seam_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.revolve_seam_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/revolve_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/revolve_test.d", "tests.unit.mesh_ops.revolve_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.revolve_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/seam_differential.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/seam_differential.d", "tests.unit.mesh_ops.seam_differential", "vibe3d.mesh.ops.tests.unit.mesh_ops.seam_differential"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/select_loop_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/select_loop_test.d", "tests.unit.mesh_ops.select_loop_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.select_loop_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/triangulate_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/triangulate_test.d", "tests.unit.mesh_ops.triangulate_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.triangulate_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_ops/vertex_pos_grid_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_ops/vertex_pos_grid_test.d", "tests.unit.mesh_ops.vertex_pos_grid_test", "vibe3d.mesh.ops.tests.unit.mesh_ops.vertex_pos_grid_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/mesh_wire_analysis_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/mesh_wire_analysis_test.d", "tests.unit.mesh_wire_analysis_test", "vibe3d.mesh.ops.tests.unit.mesh_wire_analysis_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_island_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_island_test.d", "tests.unit.uv_island_test", "vibe3d.mesh.ops.tests.unit.uv_island_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_project_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_project_test.d", "tests.unit.uv_project_test", "vibe3d.mesh.ops.tests.unit.uv_project_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_relax_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_relax_test.d", "tests.unit.uv_relax_test", "vibe3d.mesh.ops.tests.unit.uv_relax_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_transform_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_transform_test.d", "tests.unit.uv_transform_test", "vibe3d.mesh.ops.tests.unit.uv_transform_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_unwrap_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_unwrap_test.d", "tests.unit.uv_unwrap_test", "vibe3d.mesh.ops.tests.unit.uv_unwrap_test"),
    Wave19Module("mesh-ops", "packages/mesh-ops/tests/source/tests/unit/uv_weld_test.d", "libraries/mesh/ops/tests/source/vibe3d/mesh/ops/tests/unit/uv_weld_test.d", "tests.unit.uv_weld_test", "vibe3d.mesh.ops.tests.unit.uv_weld_test"),
    Wave19Module("mesh-preview", "packages/mesh-preview/source/active_mesh_resolver.d", "libraries/mesh/preview/source/vibe3d/mesh/preview/active_mesh_resolver.d", "active_mesh_resolver", "vibe3d.mesh.preview.active_mesh_resolver"),
    Wave19Module("mesh-preview", "packages/mesh-preview/source/morph_preview.d", "libraries/mesh/preview/source/vibe3d/mesh/preview/morph_preview.d", "morph_preview", "vibe3d.mesh.preview.morph_preview"),
    Wave19Module("mesh-preview", "packages/mesh-preview/tests/source/tests/unit/morph_routing_law_test.d", "libraries/mesh/preview/tests/source/vibe3d/mesh/preview/tests/unit/morph_routing_law_test.d", "tests.unit.morph_routing_law_test", "vibe3d.mesh.preview.tests.unit.morph_routing_law_test"),
    Wave19Module("mesh-snapshot", "packages/mesh-snapshot/source/snapshot.d", "libraries/mesh/snapshot/source/vibe3d/mesh/snapshot/snapshot.d", "snapshot", "vibe3d.mesh.snapshot.snapshot"),
    Wave19Module("mesh-snapshot", "packages/mesh-snapshot/tests/source/tests/unit/mesh_map_kind_snapshot_test.d", "libraries/mesh/snapshot/tests/source/vibe3d/mesh/snapshot/tests/unit/mesh_map_kind_snapshot_test.d", "tests.unit.mesh_map_kind_snapshot_test", "vibe3d.mesh.snapshot.tests.unit.mesh_map_kind_snapshot_test"),
    Wave19Module("mesh-snapshot", "packages/mesh-snapshot/tests/source/tests/unit/mesh_selsets_snapshot_test.d", "libraries/mesh/snapshot/tests/source/vibe3d/mesh/snapshot/tests/unit/mesh_selsets_snapshot_test.d", "tests.unit.mesh_selsets_snapshot_test", "vibe3d.mesh.snapshot.tests.unit.mesh_selsets_snapshot_test"),
    Wave19Module("mesh-snapshot", "packages/mesh-snapshot/tests/source/tests/unit/mesh_wire_snapshot_test.d", "libraries/mesh/snapshot/tests/source/vibe3d/mesh/snapshot/tests/unit/mesh_wire_snapshot_test.d", "tests.unit.mesh_wire_snapshot_test", "vibe3d.mesh.snapshot.tests.unit.mesh_wire_snapshot_test"),
    Wave19Module("mesh-snapshot", "packages/mesh-snapshot/tests/source/tests/unit/snapshot_test.d", "libraries/mesh/snapshot/tests/source/vibe3d/mesh/snapshot/tests/unit/snapshot_test.d", "tests.unit.snapshot_test", "vibe3d.mesh.snapshot.tests.unit.snapshot_test"),
    Wave19Module("mesh-topology", "packages/mesh-topology/source/mesh_topo.d", "libraries/mesh/topology/source/vibe3d/mesh/topology/mesh_topo.d", "mesh_topo", "vibe3d.mesh.topology.mesh_topo"),
    Wave19Module("mesh", "packages/mesh/source/mesh.d", "libraries/mesh/core/source/vibe3d/mesh/core/mesh.d", "mesh", "vibe3d.mesh.core.mesh"),
    Wave19Module("mesh", "packages/mesh/source/mesh_morph.d", "libraries/mesh/core/source/vibe3d/mesh/core/mesh_morph.d", "mesh_morph", "vibe3d.mesh.core.mesh_morph"),
    Wave19Module("mesh", "packages/mesh/source/mesh_planes.d", "libraries/mesh/core/source/vibe3d/mesh/core/mesh_planes.d", "mesh_planes", "vibe3d.mesh.core.mesh_planes"),
    Wave19Module("mesh", "packages/mesh/source/mesh_selsets.d", "libraries/mesh/core/source/vibe3d/mesh/core/mesh_selsets.d", "mesh_selsets", "vibe3d.mesh.core.mesh_selsets"),
    Wave19Module("mesh", "packages/mesh/tests/source/tests/unit/mesh_key_test.d", "libraries/mesh/core/tests/source/vibe3d/mesh/core/tests/unit/mesh_key_test.d", "tests.unit.mesh_key_test", "vibe3d.mesh.core.tests.unit.mesh_key_test"),
    Wave19Module("mesh", "packages/mesh/tests/source/tests/unit/mesh_map_kind_test.d", "libraries/mesh/core/tests/source/vibe3d/mesh/core/tests/unit/mesh_map_kind_test.d", "tests.unit.mesh_map_kind_test", "vibe3d.mesh.core.tests.unit.mesh_map_kind_test"),
    Wave19Module("mesh", "packages/mesh/tests/source/tests/unit/mesh_selsets_test.d", "libraries/mesh/core/tests/source/vibe3d/mesh/core/tests/unit/mesh_selsets_test.d", "tests.unit.mesh_selsets_test", "vibe3d.mesh.core.tests.unit.mesh_selsets_test"),
    Wave19Module("mesh", "packages/mesh/tests/source/tests/unit/mesh_topology_integration_test.d", "libraries/mesh/core/tests/source/vibe3d/mesh/core/tests/unit/mesh_topology_integration_test.d", "tests.unit.mesh_topology_integration_test", "vibe3d.mesh.core.tests.unit.mesh_topology_integration_test"),
    Wave19Module("param-schema", "packages/param-schema/source/argstring.d", "libraries/editing/params/source/vibe3d/editing/params/argstring.d", "argstring", "vibe3d.editing.params.argstring"),
    Wave19Module("param-schema", "packages/param-schema/source/params.d", "libraries/editing/params/source/vibe3d/editing/params/params.d", "params", "vibe3d.editing.params.params"),
    Wave19Module("param-schema", "packages/param-schema/tests/source/tests/unit/argstring_test.d", "libraries/editing/params/tests/source/vibe3d/editing/params/tests/unit/argstring_test.d", "tests.unit.argstring_test", "vibe3d.editing.params.tests.unit.argstring_test"),
    Wave19Module("param-schema", "packages/param-schema/tests/source/tests/unit/param_cast_overflow_test.d", "libraries/editing/params/tests/source/vibe3d/editing/params/tests/unit/param_cast_overflow_test.d", "tests.unit.param_cast_overflow_test", "vibe3d.editing.params.tests.unit.param_cast_overflow_test"),
    Wave19Module("param-schema", "packages/param-schema/tests/source/tests/unit/params_test.d", "libraries/editing/params/tests/source/vibe3d/editing/params/tests/unit/params_test.d", "tests.unit.params_test", "vibe3d.editing.params.tests.unit.params_test"),
    Wave19Module("pipe-contracts", "packages/pipe-contracts/source/operator.d", "libraries/editing/pipeline/contracts/source/vibe3d/editing/pipeline/contracts/operator.d", "operator", "vibe3d.editing.pipeline.contracts.operator"),
    Wave19Module("pipe-contracts", "packages/pipe-contracts/source/toolpipe/packets.d", "libraries/editing/pipeline/contracts/source/vibe3d/editing/pipeline/contracts/toolpipe/packets.d", "toolpipe.packets", "vibe3d.editing.pipeline.contracts.toolpipe.packets"),
    Wave19Module("pipe-contracts", "packages/pipe-contracts/tests/source/tests/unit/operator_test.d", "libraries/editing/pipeline/contracts/tests/source/vibe3d/editing/pipeline/contracts/tests/unit/operator_test.d", "tests.unit.operator_test", "vibe3d.editing.pipeline.contracts.tests.unit.operator_test"),
    Wave19Module("pipe-contracts", "packages/pipe-contracts/tests/source/tests/unit/toolpipe/packets_test.d", "libraries/editing/pipeline/contracts/tests/source/vibe3d/editing/pipeline/contracts/tests/unit/toolpipe/packets_test.d", "tests.unit.toolpipe.packets_test", "vibe3d.editing.pipeline.contracts.tests.unit.toolpipe.packets_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/attr_cache.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/attr_cache.d", "toolpipe.attr_cache", "vibe3d.editing.pipeline.evaluation.toolpipe.attr_cache"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/obbox.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/obbox.d", "toolpipe.obbox", "vibe3d.editing.pipeline.evaluation.toolpipe.obbox"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/package.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/package.d", "toolpipe", "vibe3d.editing.pipeline.evaluation.toolpipe"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/actcenter.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/actcenter.d", "toolpipe.stages.actcenter", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/axis.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/axis.d", "toolpipe.stages.axis", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/constrain.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/constrain.d", "toolpipe.stages.constrain", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/falloff.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/falloff.d", "toolpipe.stages.falloff", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.falloff"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/path.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/path.d", "toolpipe.stages.path", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.path"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/snap.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/snap.d", "toolpipe.stages.snap", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/symmetry.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/symmetry.d", "toolpipe.stages.symmetry", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.symmetry"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/workplane.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/stages/workplane.d", "toolpipe.stages.workplane", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.workplane"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/state_paths.d", "libraries/editing/pipeline/evaluation/source/vibe3d/editing/pipeline/evaluation/toolpipe/state_paths.d", "toolpipe.state_paths", "vibe3d.editing.pipeline.evaluation.toolpipe.state_paths"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/falloff_screen_default_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/falloff_screen_default_test.d", "tests.unit.falloff_screen_default_test", "vibe3d.editing.pipeline.evaluation.tests.unit.falloff_screen_default_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/obbox_regression_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/obbox_regression_test.d", "tests.unit.toolpipe.obbox_regression_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.obbox_regression_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/obbox_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/obbox_test.d", "tests.unit.toolpipe.obbox_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.obbox_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/pipeline_order_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/pipeline_order_test.d", "tests.unit.toolpipe.pipeline_order_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.pipeline_order_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/prepared_stage_regression_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/prepared_stage_regression_test.d", "tests.unit.toolpipe.prepared_stage_regression_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.prepared_stage_regression_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/snap_stage_regression_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/snap_stage_regression_test.d", "tests.unit.toolpipe.snap_stage_regression_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.snap_stage_regression_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/actcenter_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/actcenter_test.d", "tests.unit.toolpipe.stages.actcenter_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.actcenter_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/axis_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/axis_test.d", "tests.unit.toolpipe.stages.axis_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.axis_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/falloff_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/falloff_test.d", "tests.unit.toolpipe.stages.falloff_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.falloff_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/snap_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/snap_test.d", "tests.unit.toolpipe.stages.snap_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.snap_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/symmetry_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/symmetry_test.d", "tests.unit.toolpipe.stages.symmetry_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.symmetry_test"),
    Wave19Module("pipe-evaluation", "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/stages/workplane_test.d", "libraries/editing/pipeline/evaluation/tests/source/vibe3d/editing/pipeline/evaluation/tests/unit/toolpipe/stages/workplane_test.d", "tests.unit.toolpipe.stages.workplane_test", "vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.workplane_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/source/falloff.d", "libraries/editing/pipeline/runtime/source/vibe3d/editing/pipeline/runtime/falloff.d", "falloff", "vibe3d.editing.pipeline.runtime.falloff"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/source/toolpipe/pipeline.d", "libraries/editing/pipeline/runtime/source/vibe3d/editing/pipeline/runtime/toolpipe/pipeline.d", "toolpipe.pipeline", "vibe3d.editing.pipeline.runtime.toolpipe.pipeline"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/source/toolpipe/stage.d", "libraries/editing/pipeline/runtime/source/vibe3d/editing/pipeline/runtime/toolpipe/stage.d", "toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/source/toolpipe/subject.d", "libraries/editing/pipeline/runtime/source/vibe3d/editing/pipeline/runtime/toolpipe/subject.d", "toolpipe.subject", "vibe3d.editing.pipeline.runtime.toolpipe.subject"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/falloff_selection_bake_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/falloff_selection_bake_test.d", "tests.unit.falloff_selection_bake_test", "vibe3d.editing.pipeline.runtime.tests.unit.falloff_selection_bake_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/falloff_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/falloff_test.d", "tests.unit.falloff_test", "vibe3d.editing.pipeline.runtime.tests.unit.falloff_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/toolpipe/pipeline_registration_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/toolpipe/pipeline_registration_test.d", "tests.unit.toolpipe.pipeline_registration_test", "vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.pipeline_registration_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/toolpipe/required_packets_witness_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/toolpipe/required_packets_witness_test.d", "tests.unit.toolpipe.required_packets_witness_test", "vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.required_packets_witness_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/toolpipe/stage_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/toolpipe/stage_test.d", "tests.unit.toolpipe.stage_test", "vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.stage_test"),
    Wave19Module("pipe-runtime", "packages/pipe-runtime/tests/source/tests/unit/toolpipe/view_only_subject_pin_test.d", "libraries/editing/pipeline/runtime/tests/source/vibe3d/editing/pipeline/runtime/tests/unit/toolpipe/view_only_subject_pin_test.d", "tests.unit.toolpipe.view_only_subject_pin_test", "vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.view_only_subject_pin_test"),
    Wave19Module("platform-file", "packages/platform-file/source/io/browser_pick_resume.d", "libraries/platform/file/source/vibe3d/platform/file/io/browser_pick_resume.d", "io.browser_pick_resume", "vibe3d.platform.file.io.browser_pick_resume"),
    Wave19Module("platform-file", "packages/platform-file/source/io/file_dialog.d", "libraries/platform/file/source/vibe3d/platform/file/io/file_dialog.d", "io.file_dialog", "vibe3d.platform.file.io.file_dialog"),
    Wave19Module("platform-file", "packages/platform-file/source/io/file_dialog_browser.d", "libraries/platform/file/source/vibe3d/platform/file/io/file_dialog_browser.d", "io.file_dialog_browser", "vibe3d.platform.file.io.file_dialog_browser"),
    Wave19Module("platform-file", "packages/platform-file/source/ui/discard_guard.d", "libraries/platform/file/source/vibe3d/ui/editor/ui/discard_guard.d", "ui.discard_guard", "vibe3d.ui.editor.ui.discard_guard"),
    Wave19Module("profiling", "packages/profiling/source/perf_probe.d", "libraries/util/profiling/source/vibe3d/util/profiling/perf_probe.d", "perf_probe", "vibe3d.util.profiling.perf_probe"),
    Wave19Module("remesh-runtime", "packages/remesh-runtime/source/remesh/region_stitch.d", "libraries/runtime/remesh/source/vibe3d/runtime/remesh/remesh/region_stitch.d", "remesh.region_stitch", "vibe3d.runtime.remesh.remesh.region_stitch"),
    Wave19Module("remesh-runtime", "packages/remesh-runtime/source/remesh/remesh_job.d", "libraries/runtime/remesh/source/vibe3d/runtime/remesh/remesh/remesh_job.d", "remesh.remesh_job", "vibe3d.runtime.remesh.remesh.remesh_job"),
    Wave19Module("remesh-runtime", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_source_public_test.d", "libraries/runtime/remesh/tests/source/vibe3d/runtime/remesh/tests/unit/remesh/remesh_job_source_public_test.d", "tests.unit.remesh.remesh_job_source_public_test", "vibe3d.runtime.remesh.tests.unit.remesh.remesh_job_source_public_test"),
    Wave19Module("remesh-runtime", "packages/remesh-runtime/tests/source/tests/unit/remesh/remesh_job_test.d", "libraries/runtime/remesh/tests/source/vibe3d/runtime/remesh/tests/unit/remesh/remesh_job_test.d", "tests.unit.remesh.remesh_job_test", "vibe3d.runtime.remesh.tests.unit.remesh.remesh_job_test"),
    Wave19Module("render-backends", "packages/render-backends/source/render/backend_bridge.d", "libraries/render/backends/source/vibe3d/render/backends/render/backend_bridge.d", "render.backend_bridge", "vibe3d.render.backends.render.backend_bridge"),
    Wave19Module("render-backends", "packages/render-backends/source/render/cycles_backend.d", "libraries/render/backends/source/vibe3d/render/backends/render/cycles_backend.d", "render.cycles_backend", "vibe3d.render.backends.render.cycles_backend"),
    Wave19Module("render-backends", "packages/render-backends/source/render/render_diff.d", "libraries/render/backends/source/vibe3d/render/backends/render/render_diff.d", "render.render_diff", "vibe3d.render.backends.render.render_diff"),
    Wave19Module("render-backends", "packages/render-backends/source/render/rpr_backend.d", "libraries/render/backends/source/vibe3d/render/backends/render/rpr_backend.d", "render.rpr_backend", "vibe3d.render.backends.render.rpr_backend"),
    Wave19Module("render-backends", "packages/render-backends/tests/source/render_backends_population_test.d", "libraries/render/backends/tests/source/vibe3d/render/backends/render_backends_population_test.d", "render_backends_population_test", "vibe3d.render.backends.render_backends_population_test"),
    Wave19Module("render-model", "packages/render-model/source/render/backend.d", "libraries/render/model/source/vibe3d/render/model/render/backend.d", "render.backend", "vibe3d.render.model.render.backend"),
    Wave19Module("render-model", "packages/render-model/source/render/scene.d", "libraries/render/model/source/vibe3d/render/model/render/scene.d", "render.scene", "vibe3d.render.model.render.scene"),
    Wave19Module("render-model", "packages/render-model/tests/source/render_model_population_test.d", "libraries/render/model/tests/source/vibe3d/render/model/render_model_population_test.d", "render_model_population_test", "vibe3d.render.model.render_model_population_test"),
    Wave19Module("scene-query", "packages/scene-query/source/bvh_pick.d", "libraries/editing/selection/scene-query/source/vibe3d/editing/selection/scene_query/bvh_pick.d", "bvh_pick", "vibe3d.editing.selection.scene_query.bvh_pick"),
    Wave19Module("scene-query", "packages/scene-query/source/symmetry_pick.d", "libraries/editing/selection/scene-query/source/vibe3d/editing/selection/scene_query/symmetry_pick.d", "symmetry_pick", "vibe3d.editing.selection.scene_query.symmetry_pick"),
    Wave19Module("scene-query", "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d", "libraries/editing/selection/scene-query/tests/source/vibe3d/editing/selection/scene_query/tests/unit/bvh_pick_test.d", "tests.unit.bvh_pick_test", "vibe3d.editing.selection.scene_query.tests.unit.bvh_pick_test"),
    Wave19Module("scene-query", "packages/scene-query/tests/source/tests/unit/scene_query_population_test.d", "libraries/editing/selection/scene-query/tests/source/vibe3d/editing/selection/scene_query/tests/unit/scene_query_population_test.d", "tests.unit.scene_query_population_test", "vibe3d.editing.selection.scene_query.tests.unit.scene_query_population_test"),
    Wave19Module("selection-model", "packages/selection-model/source/selection_product.d", "libraries/editing/selection/model/source/vibe3d/editing/selection/model/selection_product.d", "selection_product", "vibe3d.editing.selection.model.selection_product"),
    Wave19Module("selection-model", "packages/selection-model/source/selection_projection.d", "libraries/editing/selection/model/source/vibe3d/editing/selection/model/selection_projection.d", "selection_projection", "vibe3d.editing.selection.model.selection_projection"),
    Wave19Module("selection-model", "packages/selection-model/tests/source/tests/unit/selection_model_population_test.d", "libraries/editing/selection/model/tests/source/vibe3d/editing/selection/model/tests/unit/selection_model_population_test.d", "tests.unit.selection_model_population_test", "vibe3d.editing.selection.model.tests.unit.selection_model_population_test"),
    Wave19Module("selection-model", "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d", "libraries/editing/selection/model/tests/source/vibe3d/editing/selection/model/tests/unit/selection_product_source_public_test.d", "tests.unit.selection_product_source_public_test", "vibe3d.editing.selection.model.tests.unit.selection_product_source_public_test"),
    Wave19Module("selection-model", "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d", "libraries/editing/selection/model/tests/source/vibe3d/editing/selection/model/tests/unit/selection_projection_algorithm_cells_test.d", "tests.unit.selection_projection_algorithm_cells_test", "vibe3d.editing.selection.model.tests.unit.selection_projection_algorithm_cells_test"),
    Wave19Module("spatial", "packages/spatial/source/item_xform.d", "libraries/util/spatial/source/vibe3d/util/spatial/item_xform.d", "item_xform", "vibe3d.util.spatial.item_xform"),
    Wave19Module("spatial", "packages/spatial/source/spatial.d", "libraries/util/spatial/source/vibe3d/util/spatial/spatial.d", "spatial", "vibe3d.util.spatial.spatial"),
    Wave19Module("spatial", "packages/spatial/source/symmetry_plane.d", "libraries/util/spatial/source/vibe3d/util/spatial/symmetry_plane.d", "symmetry_plane", "vibe3d.util.spatial.symmetry_plane"),
    Wave19Module("spatial", "packages/spatial/source/trackball.d", "libraries/util/spatial/source/vibe3d/util/spatial/trackball.d", "trackball", "vibe3d.util.spatial.trackball"),
    Wave19Module("spatial", "packages/spatial/source/workplane_basis.d", "libraries/util/spatial/source/vibe3d/util/spatial/workplane_basis.d", "workplane_basis", "vibe3d.util.spatial.workplane_basis"),
    Wave19Module("spatial", "packages/spatial/tests/source/tests/unit/spatial_test.d", "libraries/util/spatial/tests/source/vibe3d/util/spatial/tests/unit/spatial_test.d", "tests.unit.spatial_test", "vibe3d.util.spatial.tests.unit.spatial_test"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/source/subpatch_factories.d", "libraries/viewport/subpatch/source/vibe3d/viewport/subpatch/subpatch_factories.d", "subpatch_factories", "vibe3d.viewport.subpatch.subpatch_factories"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/source/subpatch_osd.d", "libraries/viewport/subpatch/source/vibe3d/viewport/subpatch/subpatch_osd.d", "subpatch_osd", "vibe3d.viewport.subpatch.subpatch_osd"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/source/subpatch_preview.d", "libraries/viewport/subpatch/source/vibe3d/viewport/subpatch/subpatch_preview.d", "subpatch_preview", "vibe3d.viewport.subpatch.subpatch_preview"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/source/subpatch_worker.d", "libraries/viewport/subpatch/source/vibe3d/viewport/subpatch/subpatch_worker.d", "subpatch_worker", "vibe3d.viewport.subpatch.subpatch_worker"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/source/subpatch_worker_web.d", "libraries/viewport/subpatch/source/vibe3d/viewport/subpatch/subpatch_worker_web.d", "subpatch_worker_web", "vibe3d.viewport.subpatch.subpatch_worker_web"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_key_fold_test.d", "libraries/viewport/subpatch/tests/source/vibe3d/viewport/subpatch/tests/unit/subpatch_key_fold_test.d", "tests.unit.subpatch_key_fold_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_key_fold_test"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_level_policy_test.d", "libraries/viewport/subpatch/tests/source/vibe3d/viewport/subpatch/tests/unit/subpatch_level_policy_test.d", "tests.unit.subpatch_level_policy_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_level_policy_test"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_osd_test.d", "libraries/viewport/subpatch/tests/source/vibe3d/viewport/subpatch/tests/unit/subpatch_osd_test.d", "tests.unit.subpatch_osd_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_osd_test"),
    Wave19Module("subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "libraries/viewport/subpatch/tests/source/vibe3d/viewport/subpatch/tests/unit/subpatch_preview_population_test.d", "tests.unit.subpatch_preview_population_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_preview_population_test"),
    Wave19Module("tool-state", "packages/tool-state/source/tools/common/session_mesh_key.d", "libraries/editing/tools/state/source/vibe3d/editing/tools/state/tools/common/session_mesh_key.d", "tools.common.session_mesh_key", "vibe3d.editing.tools.state.tools.common.session_mesh_key"),
    Wave19Module("tool-state", "packages/tool-state/source/tools/edit/preview_rebuild.d", "libraries/editing/tools/state/source/vibe3d/editing/tools/state/tools/edit/preview_rebuild.d", "tools.edit.preview_rebuild", "vibe3d.editing.tools.state.tools.edit.preview_rebuild"),
    Wave19Module("tool-state", "packages/tool-state/tests/source/tests/unit/session_mesh_key_stamp_as_test.d", "libraries/editing/tools/state/tests/source/vibe3d/editing/tools/state/tests/unit/session_mesh_key_stamp_as_test.d", "tests.unit.session_mesh_key_stamp_as_test", "vibe3d.editing.tools.state.tests.unit.session_mesh_key_stamp_as_test"),
    Wave19Module("tool-state", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "libraries/editing/tools/state/tests/source/vibe3d/editing/tools/state/tests/unit/tool_state_population_test.d", "tests.unit.tool_state_population_test", "vibe3d.editing.tools.state.tests.unit.tool_state_population_test"),
    Wave19Module("tool-state", "packages/tool-state/tests/source/tests/unit/tools/common/session_mesh_key_test.d", "libraries/editing/tools/state/tests/source/vibe3d/editing/tools/state/tests/unit/tools/common/session_mesh_key_test.d", "tests.unit.tools.common.session_mesh_key_test", "vibe3d.editing.tools.state.tests.unit.tools.common.session_mesh_key_test"),
    Wave19Module("tool-state", "packages/tool-state/tests/source/tests/unit/tools/edit/preview_rebuild_test.d", "libraries/editing/tools/state/tests/source/vibe3d/editing/tools/state/tests/unit/tools/edit/preview_rebuild_test.d", "tests.unit.tools.edit.preview_rebuild_test", "vibe3d.editing.tools.state.tests.unit.tools.edit.preview_rebuild_test"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/arcball.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/arcball.d", "tools.transform.arcball", "vibe3d.editing.tools.transform.tools.transform.arcball"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/cluster_values.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/cluster_values.d", "tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/item_xform_kernels.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/item_xform_kernels.d", "tools.transform.item_xform_kernels", "vibe3d.editing.tools.transform.tools.transform.item_xform_kernels"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/morph_route.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/morph_route.d", "tools.transform.morph_route", "vibe3d.editing.tools.transform.tools.transform.morph_route"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/relocate_plane.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/relocate_plane.d", "tools.transform.relocate_plane", "vibe3d.editing.tools.transform.tools.transform.relocate_plane"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/scale_input.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/scale_input.d", "tools.transform.scale_input", "vibe3d.editing.tools.transform.tools.transform.scale_input"),
    Wave19Module("transform-ops", "packages/transform-ops/source/tools/transform/xform_kernels.d", "libraries/editing/tools/transform/source/vibe3d/editing/tools/transform/tools/transform/xform_kernels.d", "tools.transform.xform_kernels", "vibe3d.editing.tools.transform.tools.transform.xform_kernels"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/ortho_relocate_prior_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/ortho_relocate_prior_test.d", "tests.unit.ortho_relocate_prior_test", "vibe3d.editing.tools.transform.tests.unit.ortho_relocate_prior_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/arcball_regression_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/arcball_regression_test.d", "tests.unit.tools.transform.arcball_regression_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_regression_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/arcball_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/arcball_test.d", "tests.unit.tools.transform.arcball_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/item_xform_kernels_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/item_xform_kernels_test.d", "tests.unit.tools.transform.item_xform_kernels_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_kernels_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/item_xform_regression_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/item_xform_regression_test.d", "tests.unit.tools.transform.item_xform_regression_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_regression_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/morph_route_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/morph_route_test.d", "tests.unit.tools.transform.morph_route_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.morph_route_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/scale_input_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/scale_input_test.d", "tests.unit.tools.transform.scale_input_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.scale_input_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/transform_ops_population_test.d", "tests.unit.tools.transform.transform_ops_population_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.transform_ops_population_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/xform_kernels_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tests/unit/tools/transform/xform_kernels_test.d", "tests.unit.tools.transform.xform_kernels_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.xform_kernels_test"),
    Wave19Module("transform-ops", "packages/transform-ops/tests/source/tools/transform/relocate_plane_test.d", "libraries/editing/tools/transform/tests/source/vibe3d/editing/tools/transform/tools/transform/relocate_plane_test.d", "tools.transform.relocate_plane_test", "vibe3d.editing.tools.transform.tools.transform.relocate_plane_test"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/display_sync.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/display_sync.d", "display_sync", "vibe3d.viewport.gpu.display_sync"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/gl_thread_guard.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/gl_thread_guard.d", "gl_thread_guard", "vibe3d.viewport.gpu.gl_thread_guard"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/gpu_pass_timer.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/gpu_pass_timer.d", "gpu_pass_timer", "vibe3d.viewport.gpu.gpu_pass_timer"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/gpu_select.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/gpu_select.d", "gpu_select", "vibe3d.viewport.gpu.gpu_select"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/mesh_gpu.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/mesh_gpu.d", "mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/shader.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/shader.d", "shader", "vibe3d.viewport.gpu.shader"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/source/viewport_env.d", "libraries/viewport/gpu/source/vibe3d/viewport/gpu/viewport_env.d", "viewport_env", "vibe3d.viewport.gpu.viewport_env"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/tests/source/tests/unit/viewport_env_test.d", "libraries/viewport/gpu/tests/source/vibe3d/viewport/gpu/tests/unit/viewport_env_test.d", "tests.unit.viewport_env_test", "vibe3d.viewport.gpu.tests.unit.viewport_env_test"),
    Wave19Module("viewport-gpu", "packages/viewport-gpu/tests/source/tests/unit/viewport_gpu_population_test.d", "libraries/viewport/gpu/tests/source/vibe3d/viewport/gpu/tests/unit/viewport_gpu_population_test.d", "tests.unit.viewport_gpu_population_test", "vibe3d.viewport.gpu.tests.unit.viewport_gpu_population_test"),
    Wave19Module("viewport-host", "packages/viewport-host/source/bg_gpu_cache.d", "libraries/viewport/host/source/vibe3d/viewport/host/bg_gpu_cache.d", "bg_gpu_cache", "vibe3d.viewport.host.bg_gpu_cache"),
    Wave19Module("viewport-host", "packages/viewport-host/source/image_cache.d", "libraries/viewport/host/source/vibe3d/viewport/host/image_cache.d", "image_cache", "vibe3d.viewport.host.image_cache"),
    Wave19Module("viewport-host", "packages/viewport-host/source/image_plane.d", "libraries/viewport/host/source/vibe3d/viewport/host/image_plane.d", "image_plane", "vibe3d.viewport.host.image_plane"),
    Wave19Module("viewport-host", "packages/viewport-host/source/viewport.d", "libraries/viewport/host/source/vibe3d/viewport/host/viewport.d", "viewport", "vibe3d.viewport.host.viewport"),
    Wave19Module("viewport-host", "packages/viewport-host/source/viewport_composite.d", "libraries/viewport/host/source/vibe3d/viewport/host/viewport_composite.d", "viewport_composite", "vibe3d.viewport.host.viewport_composite"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/image_plane_source_cells.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/image_plane_source_cells.d", "image_plane_source_cells", "vibe3d.viewport.host.image_plane_source_cells"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/camera_intrinsics_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/camera_intrinsics_test.d", "tests.unit.camera_intrinsics_test", "vibe3d.viewport.host.tests.unit.camera_intrinsics_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/dirty_key_camera_stamp_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/dirty_key_camera_stamp_test.d", "tests.unit.dirty_key_camera_stamp_test", "vibe3d.viewport.host.tests.unit.dirty_key_camera_stamp_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/dirty_key_tool_preview_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/dirty_key_tool_preview_test.d", "tests.unit.dirty_key_tool_preview_test", "vibe3d.viewport.host.tests.unit.dirty_key_tool_preview_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/dirty_key_weightmap_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/dirty_key_weightmap_test.d", "tests.unit.dirty_key_weightmap_test", "vibe3d.viewport.host.tests.unit.dirty_key_weightmap_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/image_cache_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/image_cache_test.d", "tests.unit.image_cache_test", "vibe3d.viewport.host.tests.unit.image_cache_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/image_plane_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/image_plane_test.d", "tests.unit.image_plane_test", "vibe3d.viewport.host.tests.unit.image_plane_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/viewport_plane_turn_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/viewport_plane_turn_test.d", "tests.unit.viewport_plane_turn_test", "vibe3d.viewport.host.tests.unit.viewport_plane_turn_test"),
    Wave19Module("viewport-host", "packages/viewport-host/tests/source/tests/unit/viewport_test.d", "libraries/viewport/host/tests/source/vibe3d/viewport/host/tests/unit/viewport_test.d", "tests.unit.viewport_test", "vibe3d.viewport.host.tests.unit.viewport_test"),
    Wave19Module("desktop", "source/ai3d_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/ai3d_command_registration.d", "ai3d_command_registration", "vibe3d.apps.desktop.ai3d_command_registration"),
    Wave19Module("desktop", "source/ai_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/ai_command_registration.d", "ai_command_registration", "vibe3d.apps.desktop.ai_command_registration"),
    Wave19Module("desktop", "source/app.d", "apps/desktop/source/vibe3d/apps/desktop/app.d", "app", "vibe3d.apps.desktop.app"),
    Wave19Module("desktop", "source/application_command_binding.d", "apps/desktop/source/vibe3d/apps/desktop/application_command_binding.d", "application_command_binding", "vibe3d.apps.desktop.application_command_binding"),
    Wave19Module("desktop", "source/commands/actr.d", "apps/desktop/source/vibe3d/apps/desktop/commands/actr.d", "commands.actr", "vibe3d.apps.desktop.commands.actr"),
    Wave19Module("desktop", "source/commands/ai/toggle.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ai/toggle.d", "commands.ai.toggle", "vibe3d.apps.desktop.commands.ai.toggle"),
    Wave19Module("desktop", "source/commands/ai3d/generate.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ai3d/generate.d", "commands.ai3d.generate", "vibe3d.apps.desktop.commands.ai3d.generate"),
    Wave19Module("desktop", "source/commands/ai3d/generate_open.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ai3d/generate_open.d", "commands.ai3d.generate_open", "vibe3d.apps.desktop.commands.ai3d.generate_open"),
    Wave19Module("desktop", "source/commands/ai3d/generate_test_hooks.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ai3d/generate_test_hooks.d", "commands.ai3d.generate_test_hooks", "vibe3d.apps.desktop.commands.ai3d.generate_test_hooks"),
    Wave19Module("desktop", "source/commands/ai3d/import_result.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ai3d/import_result.d", "commands.ai3d.import_result", "vibe3d.apps.desktop.commands.ai3d.import_result"),
    Wave19Module("desktop", "source/commands/constrain/toggle.d", "apps/desktop/source/vibe3d/apps/desktop/commands/constrain/toggle.d", "commands.constrain.toggle", "vibe3d.apps.desktop.commands.constrain.toggle"),
    Wave19Module("desktop", "source/commands/copilot/analyze.d", "apps/desktop/source/vibe3d/apps/desktop/commands/copilot/analyze.d", "commands.copilot.analyze", "vibe3d.apps.desktop.commands.copilot.analyze"),
    Wave19Module("desktop", "source/commands/copilot/cycle_finding.d", "apps/desktop/source/vibe3d/apps/desktop/commands/copilot/cycle_finding.d", "commands.copilot.cycle_finding", "vibe3d.apps.desktop.commands.copilot.cycle_finding"),
    Wave19Module("desktop", "source/commands/copilot/select_finding.d", "apps/desktop/source/vibe3d/apps/desktop/commands/copilot/select_finding.d", "commands.copilot.select_finding", "vibe3d.apps.desktop.commands.copilot.select_finding"),
    Wave19Module("desktop", "source/commands/file/load.d", "apps/desktop/source/vibe3d/apps/desktop/commands/file/load.d", "commands.file.load", "vibe3d.apps.desktop.commands.file.load"),
    Wave19Module("desktop", "source/commands/file/save.d", "apps/desktop/source/vibe3d/apps/desktop/commands/file/save.d", "commands.file.save", "vibe3d.apps.desktop.commands.file.save"),
    Wave19Module("desktop", "source/commands/mesh/magnet.d", "apps/desktop/source/vibe3d/editing/commands/editor/commands/mesh/magnet.d", "commands.mesh.magnet", "vibe3d.editing.commands.editor.commands.mesh.magnet"),
    Wave19Module("desktop", "source/commands/mesh/morph.d", "apps/desktop/source/vibe3d/editing/commands/editor/commands/mesh/morph.d", "commands.mesh.morph", "vibe3d.editing.commands.editor.commands.mesh.morph"),
    Wave19Module("desktop", "source/commands/mesh/remesh.d", "apps/desktop/source/vibe3d/editing/commands/editor/commands/mesh/remesh.d", "commands.mesh.remesh", "vibe3d.editing.commands.editor.commands.mesh.remesh"),
    Wave19Module("desktop", "source/commands/path/define.d", "apps/desktop/source/vibe3d/apps/desktop/commands/path/define.d", "commands.path.define", "vibe3d.apps.desktop.commands.path.define"),
    Wave19Module("desktop", "source/commands/prefs/coord_rounding.d", "apps/desktop/source/vibe3d/apps/desktop/commands/prefs/coord_rounding.d", "commands.prefs.coord_rounding", "vibe3d.apps.desktop.commands.prefs.coord_rounding"),
    Wave19Module("desktop", "source/commands/prefs/trackball.d", "apps/desktop/source/vibe3d/apps/desktop/commands/prefs/trackball.d", "commands.prefs.trackball", "vibe3d.apps.desktop.commands.prefs.trackball"),
    Wave19Module("desktop", "source/commands/snap/mode.d", "apps/desktop/source/vibe3d/apps/desktop/commands/snap/mode.d", "commands.snap.mode", "vibe3d.apps.desktop.commands.snap.mode"),
    Wave19Module("desktop", "source/commands/snap/toggle.d", "apps/desktop/source/vibe3d/apps/desktop/commands/snap/toggle.d", "commands.snap.toggle", "vibe3d.apps.desktop.commands.snap.toggle"),
    Wave19Module("desktop", "source/commands/snap/toggle_type.d", "apps/desktop/source/vibe3d/apps/desktop/commands/snap/toggle_type.d", "commands.snap.toggle_type", "vibe3d.apps.desktop.commands.snap.toggle_type"),
    Wave19Module("desktop", "source/commands/symmetry/toggle.d", "apps/desktop/source/vibe3d/apps/desktop/commands/symmetry/toggle.d", "commands.symmetry.toggle", "vibe3d.apps.desktop.commands.symmetry.toggle"),
    Wave19Module("desktop", "source/commands/test_undo_flags.d", "apps/desktop/source/vibe3d/apps/desktop/commands/test_undo_flags.d", "commands.test_undo_flags", "vibe3d.apps.desktop.commands.test_undo_flags"),
    Wave19Module("desktop", "source/commands/ui/about.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/about.d", "commands.ui.about", "vibe3d.apps.desktop.commands.ui.about"),
    Wave19Module("desktop", "source/commands/ui/channels.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/channels.d", "commands.ui.channels", "vibe3d.apps.desktop.commands.ui.channels"),
    Wave19Module("desktop", "source/commands/ui/copilot_panel.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/copilot_panel.d", "commands.ui.copilot_panel", "vibe3d.apps.desktop.commands.ui.copilot_panel"),
    Wave19Module("desktop", "source/commands/ui/image_list.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/image_list.d", "commands.ui.image_list", "vibe3d.apps.desktop.commands.ui.image_list"),
    Wave19Module("desktop", "source/commands/ui/layer_list.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/layer_list.d", "commands.ui.layer_list", "vibe3d.apps.desktop.commands.ui.layer_list"),
    Wave19Module("desktop", "source/commands/ui/layout_reset.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/layout_reset.d", "commands.ui.layout_reset", "vibe3d.apps.desktop.commands.ui.layout_reset"),
    Wave19Module("desktop", "source/commands/ui/pie.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/pie.d", "commands.ui.pie", "vibe3d.apps.desktop.commands.ui.pie"),
    Wave19Module("desktop", "source/commands/ui/statistics.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/statistics.d", "commands.ui.statistics", "vibe3d.apps.desktop.commands.ui.statistics"),
    Wave19Module("desktop", "source/commands/ui/tool_properties.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/tool_properties.d", "commands.ui.tool_properties", "vibe3d.apps.desktop.commands.ui.tool_properties"),
    Wave19Module("desktop", "source/commands/ui/viewport_props.d", "apps/desktop/source/vibe3d/apps/desktop/commands/ui/viewport_props.d", "commands.ui.viewport_props", "vibe3d.apps.desktop.commands.ui.viewport_props"),
    Wave19Module("desktop", "source/commands/viewport/command_base.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/command_base.d", "commands.viewport.command_base", "vibe3d.apps.desktop.commands.viewport.command_base"),
    Wave19Module("desktop", "source/commands/viewport/display.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/display.d", "commands.viewport.display", "vibe3d.apps.desktop.commands.viewport.display"),
    Wave19Module("desktop", "source/commands/viewport/fit.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/fit.d", "commands.viewport.fit", "vibe3d.apps.desktop.commands.viewport.fit"),
    Wave19Module("desktop", "source/commands/viewport/fit_selected.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/fit_selected.d", "commands.viewport.fit_selected", "vibe3d.apps.desktop.commands.viewport.fit_selected"),
    Wave19Module("desktop", "source/commands/viewport/grid_steps.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/grid_steps.d", "commands.viewport.grid_steps", "vibe3d.apps.desktop.commands.viewport.grid_steps"),
    Wave19Module("desktop", "source/commands/viewport/independence.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/independence.d", "commands.viewport.independence", "vibe3d.apps.desktop.commands.viewport.independence"),
    Wave19Module("desktop", "source/commands/viewport/layout_preset.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/layout_preset.d", "commands.viewport.layout_preset", "vibe3d.apps.desktop.commands.viewport.layout_preset"),
    Wave19Module("desktop", "source/commands/viewport/master.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/master.d", "commands.viewport.master", "vibe3d.apps.desktop.commands.viewport.master"),
    Wave19Module("desktop", "source/commands/viewport/view_preset.d", "apps/desktop/source/vibe3d/apps/desktop/commands/viewport/view_preset.d", "commands.viewport.view_preset", "vibe3d.apps.desktop.commands.viewport.view_preset"),
    Wave19Module("desktop", "source/commands/workplane.d", "apps/desktop/source/vibe3d/apps/desktop/commands/workplane.d", "commands.workplane", "vibe3d.apps.desktop.commands.workplane"),
    Wave19Module("desktop", "source/copilot_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/copilot_command_registration.d", "copilot_command_registration", "vibe3d.apps.desktop.copilot_command_registration"),
    Wave19Module("desktop", "source/create_tool_registration.d", "apps/desktop/source/vibe3d/apps/desktop/create_tool_registration.d", "create_tool_registration", "vibe3d.apps.desktop.create_tool_registration"),
    Wave19Module("desktop", "source/edit_tool_registration.d", "apps/desktop/source/vibe3d/apps/desktop/edit_tool_registration.d", "edit_tool_registration", "vibe3d.apps.desktop.edit_tool_registration"),
    Wave19Module("desktop", "source/editor_app.d", "apps/desktop/source/vibe3d/apps/desktop/editor_app.d", "editor_app", "vibe3d.apps.desktop.editor_app"),
    Wave19Module("desktop", "source/file_io_registration.d", "apps/desktop/source/vibe3d/apps/desktop/file_io_registration.d", "file_io_registration", "vibe3d.apps.desktop.file_io_registration"),
    Wave19Module("desktop", "source/frame_runner.d", "apps/desktop/source/vibe3d/apps/desktop/frame_runner.d", "frame_runner", "vibe3d.apps.desktop.frame_runner"),
    Wave19Module("desktop", "source/frame_stall.d", "apps/desktop/source/vibe3d/apps/desktop/frame_stall.d", "frame_stall", "vibe3d.apps.desktop.frame_stall"),
    Wave19Module("desktop", "source/guarded_action_controller.d", "apps/desktop/source/vibe3d/apps/desktop/guarded_action_controller.d", "guarded_action_controller", "vibe3d.apps.desktop.guarded_action_controller"),
    Wave19Module("desktop", "source/history_macro_registration.d", "apps/desktop/source/vibe3d/apps/desktop/history_macro_registration.d", "history_macro_registration", "vibe3d.apps.desktop.history_macro_registration"),
    Wave19Module("desktop", "source/http_command_adapter.d", "apps/desktop/source/vibe3d/apps/desktop/http_command_adapter.d", "http_command_adapter", "vibe3d.apps.desktop.http_command_adapter"),
    Wave19Module("desktop", "source/http_providers.d", "apps/desktop/source/vibe3d/apps/desktop/http_providers.d", "http_providers", "vibe3d.apps.desktop.http_providers"),
    Wave19Module("desktop", "source/input_frame_state.d", "apps/desktop/source/vibe3d/apps/desktop/input_frame_state.d", "input_frame_state", "vibe3d.apps.desktop.input_frame_state"),
    Wave19Module("desktop", "source/input_router.d", "apps/desktop/source/vibe3d/apps/desktop/input_router.d", "input_router", "vibe3d.apps.desktop.input_router"),
    Wave19Module("desktop", "source/item_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/item_command_registration.d", "item_command_registration", "vibe3d.apps.desktop.item_command_registration"),
    Wave19Module("desktop", "source/item_pick.d", "apps/desktop/source/vibe3d/apps/desktop/item_pick.d", "item_pick", "vibe3d.apps.desktop.item_pick"),
    Wave19Module("desktop", "source/layout_reset_action.d", "apps/desktop/source/vibe3d/apps/desktop/layout_reset_action.d", "layout_reset_action", "vibe3d.apps.desktop.layout_reset_action"),
    Wave19Module("desktop", "source/mesh_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/mesh_command_registration.d", "mesh_command_registration", "vibe3d.apps.desktop.mesh_command_registration"),
    Wave19Module("desktop", "source/pipe_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/pipe_command_registration.d", "pipe_command_registration", "vibe3d.apps.desktop.pipe_command_registration"),
    Wave19Module("desktop", "source/prefs.d", "apps/desktop/source/vibe3d/apps/desktop/prefs.d", "prefs", "vibe3d.apps.desktop.prefs"),
    Wave19Module("desktop", "source/registration.d", "apps/desktop/source/vibe3d/apps/desktop/registration.d", "registration", "vibe3d.apps.desktop.registration"),
    Wave19Module("desktop", "source/render/render_mvp.d", "apps/desktop/source/vibe3d/apps/desktop/render/render_mvp.d", "render.render_mvp", "vibe3d.apps.desktop.render.render_mvp"),
    Wave19Module("desktop", "source/scene_file_lifecycle_registration.d", "apps/desktop/source/vibe3d/apps/desktop/scene_file_lifecycle_registration.d", "scene_file_lifecycle_registration", "vibe3d.apps.desktop.scene_file_lifecycle_registration"),
    Wave19Module("desktop", "source/scene_reset_effects.d", "apps/desktop/source/vibe3d/apps/desktop/scene_reset_effects.d", "scene_reset_effects", "vibe3d.apps.desktop.scene_reset_effects"),
    Wave19Module("desktop", "source/selection_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/selection_command_registration.d", "selection_command_registration", "vibe3d.apps.desktop.selection_command_registration"),
    Wave19Module("desktop", "source/selftest_fault.d", "apps/desktop/source/vibe3d/apps/desktop/selftest_fault.d", "selftest_fault", "vibe3d.apps.desktop.selftest_fault"),
    Wave19Module("desktop", "source/tool_lifecycle_registration.d", "apps/desktop/source/vibe3d/apps/desktop/tool_lifecycle_registration.d", "tool_lifecycle_registration", "vibe3d.apps.desktop.tool_lifecycle_registration"),
    Wave19Module("desktop", "source/transform_tool_registration.d", "apps/desktop/source/vibe3d/apps/desktop/transform_tool_registration.d", "transform_tool_registration", "vibe3d.apps.desktop.transform_tool_registration"),
    Wave19Module("desktop", "source/tsan_preinit.d", "apps/desktop/source/vibe3d/apps/desktop/tsan_preinit.d", "tsan_preinit", "vibe3d.apps.desktop.tsan_preinit"),
    Wave19Module("desktop", "source/ui/viewport_render.d", "apps/desktop/source/vibe3d/ui/editor/ui/viewport_render.d", "ui.viewport_render", "vibe3d.ui.editor.ui.viewport_render"),
    Wave19Module("desktop", "source/view_settings_registration.d", "apps/desktop/source/vibe3d/apps/desktop/view_settings_registration.d", "view_settings_registration", "vibe3d.apps.desktop.view_settings_registration"),
    Wave19Module("desktop", "source/viewport_command_registration.d", "apps/desktop/source/vibe3d/apps/desktop/viewport_command_registration.d", "viewport_command_registration", "vibe3d.apps.desktop.viewport_command_registration"),
    Wave19Module("desktop", "source/web_gl_loader.d", "apps/desktop/source/vibe3d/apps/desktop/web_gl_loader.d", "web_gl_loader", "vibe3d.apps.desktop.web_gl_loader"),
    Wave19Module("desktop-tests", "tests/unit/commands/file/file_io_registration_test.d", "tests/unit/commands/file/file_io_registration_test.d", "commands.file.file_io_registration_test", "vibe3d.apps.desktop.commands.file.file_io_registration_test"),
    Wave19Module("desktop-tests", "tests/unit/tools/edit/topology_pen/gestures_test.d", "tests/unit/tools/edit/topology_pen/gestures_test.d", "tools.edit.topology_pen.gestures_test", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.gestures_test"),
    Wave19Module("desktop-tests", "tests/unit/tools/edit/topology_pen/reapply_test.d", "tests/unit/tools/edit/topology_pen/reapply_test.d", "tools.edit.topology_pen.reapply_test", "vibe3d.editing.tools.interactive.tools.edit.topology_pen.reapply_test"),
    Wave19Module("desktop-tests", "tests/unit/ui/grid_plane_test.d", "tests/unit/ui/grid_plane_test.d", "ui.grid_plane_test", "vibe3d.ui.editor.ui.grid_plane_test"),
    Wave19Module("desktop-tests", "tests/unit/ui/viewport_render_plan_test.d", "tests/unit/ui/viewport_render_plan_test.d", "ui.viewport_render_plan_test", "vibe3d.ui.editor.ui.viewport_render_plan_test"),
    Wave19Module("cli", "tools/cli/source/main.d", "apps/cli/source/vibe3d/apps/cli/main.d", "main", "vibe3d.apps.cli.main"),
    Wave19Module("json-number", "util/json-number/source/json_num.d", "libraries/util/json-number/source/vibe3d/util/json_number/json_num.d", "json_num", "vibe3d.util.json_number.json_num"),
    Wave19Module("json-number", "util/json-number/tests/source/tests/unit/json_num_test.d", "libraries/util/json-number/tests/source/vibe3d/util/json_number/tests/unit/json_num_test.d", "tests.unit.json_num_test", "vibe3d.util.json_number.tests.unit.json_num_test"),
    Wave19Module("log", "util/log/source/log.d", "libraries/util/log/source/vibe3d/util/log/log.d", "log", "vibe3d.util.log.log"),
    Wave19Module("math", "util/math/source/math.d", "libraries/util/math/source/vibe3d/util/math/math.d", "math", "vibe3d.util.math.math"),
    Wave19Module("math", "util/math/source/math_geometry.d", "libraries/util/math/source/vibe3d/util/math/math_geometry.d", "math_geometry", "vibe3d.util.math.math_geometry"),
    Wave19Module("math", "util/math/source/math_matrix.d", "libraries/util/math/source/vibe3d/util/math/math_matrix.d", "math_matrix", "vibe3d.util.math.math_matrix"),
    Wave19Module("math", "util/math/source/math_quaternion.d", "libraries/util/math/source/vibe3d/util/math/math_quaternion.d", "math_quaternion", "vibe3d.util.math.math_quaternion"),
    Wave19Module("math", "util/math/source/math_vector.d", "libraries/util/math/source/vibe3d/util/math/math_vector.d", "math_vector", "vibe3d.util.math.math_vector"),
    Wave19Module("math", "util/math/tests/source/tests/unit/math_test.d", "libraries/util/math/tests/source/vibe3d/util/math/tests/unit/math_test.d", "tests.unit.math_test", "vibe3d.util.math.tests.unit.math_test"),
    Wave19Module("parallel", "util/parallel/source/tsan_annotate.d", "libraries/util/parallel/source/vibe3d/util/parallel/tsan_annotate.d", "tsan_annotate", "vibe3d.util.parallel.tsan_annotate"),
    Wave19Module("plane-bytes", "util/plane-bytes/source/plane_bytes.d", "libraries/util/plane-bytes/source/vibe3d/util/plane_bytes/plane_bytes.d", "plane_bytes", "vibe3d.util.plane_bytes.plane_bytes"),
    Wave19Module("screen-buckets", "util/screen-buckets/source/screen_buckets.d", "libraries/util/screen-buckets/source/vibe3d/util/screen_buckets/screen_buckets.d", "screen_buckets", "vibe3d.util.screen_buckets.screen_buckets"),
];
public enum wave19MathOldRoot = "util/math";
public enum wave19MathNewRoot = "libraries/util/math";
private enum wave19MathModules = ["math", "math_geometry", "math_matrix",
    "math_quaternion", "math_vector", "tests.unit.math_test"];
private string mathRelative(string name, bool moved) {
    const carrier = name == "tests.unit.math_test";
    const suffix = carrier ? "tests/source/" : "source/";
    return suffix ~ (moved ? "vibe3d/util/math/" : "")
        ~ name.replace(".", "/") ~ ".d";
}

// A reader operation is synchronous and has no mutation callbacks. Validate
// each owner once inside that operation, then discard every cached decision so
// a later read observes changed recipes, missing files and declarations again.
private size_t wave19ReadDepth;
private bool[string] wave19OwnerSelections;
private bool[string] wave19DesktopSelections;
private struct Wave19ReadScope {
    this(bool active) { ++wave19ReadDepth; }
    ~this() {
        if (--wave19ReadDepth == 0) {
            wave19OwnerSelections = null;
            wave19DesktopSelections = null;
        }
    }
}

// Select the complete real owner. Optional facade/shim files are outside this
// roster and can never stand in for a missing original definition or carrier.
// Proposed inline addition to existing census_symbols.d; source-only. The
// caller appends the80 canonical rows to existing wave19Modules, and retains
// all existing library, lexical singleton and historical/body guard functions.
private bool wave19DesktopRowMoved(string root, const Wave19Module target) {
    import std.algorithm : canFind;
    import std.file : exists, isFile, readText;
    import std.json : parseJSON;
    import std.path : buildPath;
    const base = wave15Normalize(root);
    const cacheKey = base ~ "\0" ~ target.oldPath;
    if (wave19ReadDepth) if (auto cached = cacheKey in wave19DesktopSelections) return *cached;
    auto recipe = parseJSON(readText(buildPath(base, "dub.json")));
    assert(recipe["name"].str == "vibe3d", "Wave19 root application identity");
    string[] roots;
    foreach (value; recipe["sourcePaths"].array) roots ~= value.str;
    const entry = recipe["mainSourceFile"].str;
    const oldState = roots == ["source"] && entry == "source/app.d";
    const finalState = roots == ["apps/desktop/source"]
        && entry == "apps/desktop/source/vibe3d/apps/desktop/app.d";
    assert(oldState != finalState, "Wave19 desktop selected root coordinates");
    // These are the six already-approved explicit host selections, not roots
    // or a second physical map. Their actual row destinations remain canonical.
    immutable peerKeys = ["source/commands/mesh/magnet.d",
        "source/commands/mesh/morph.d", "source/commands/mesh/remesh.d",
        "source/commands/file/load.d", "source/commands/file/save.d",
        "source/ui/viewport_render.d"];
    string[] peers;
    foreach (key; peerKeys) {
        size_t hits;
        string path;
        foreach (row; wave19Modules)
            if (row.owner == "desktop" && row.oldPath == key) {
                ++hits; path = row.newPath;
            }
        assert(hits == 1, "Wave19 desktop coupled-peer row identity");
        peers ~= path;
    }
    string[] explicitSources;
    bool[string] seenExplicit;
    foreach (value; recipe["sourceFiles"].array) {
        const path = value.str;
        assert(path !in seenExplicit, "Wave19 duplicate root explicit source");
        seenExplicit[path] = true;
        assert(peers.canFind(path), "Wave19 unauthorized root explicit desktop source");
        explicitSources ~= path;
    }
    const stage0 = explicitSources.length == 0;
    const stage3 = explicitSources.length == 3
        && peers[0 .. 3].canFind(explicitSources[0])
        && peers[0 .. 3].canFind(explicitSources[1])
        && peers[0 .. 3].canFind(explicitSources[2]);
    const stage6 = explicitSources.length == 6;
    assert(finalState ? stage0 : (stage0 || stage3 || stage6),
        "Wave19 incomplete/duplicate coupled desktop peer stage");
    if (finalState || !stage0) {
        string[] imports;
        foreach (value; recipe["importPaths"].array) imports ~= value.str;
        assert(imports == ["apps/desktop/source"],
            "Wave19 selected desktop import root");
    }
    size_t population, targetHits;
    bool selected;
    bool[string] selections;
    bool[string] oldPaths, newPaths;
    foreach (row; wave19Modules) {
        if (row.owner != "desktop") continue;
        ++population;
        assert(row.oldPath !in oldPaths && row.newPath !in newPaths,
            "Wave19 duplicate desktop coordinate");
        oldPaths[row.oldPath] = true; newPaths[row.newPath] = true;
        const moved = finalState || explicitSources.canFind(row.newPath);
        selections[base ~ "\0" ~ row.oldPath] = moved;
        const active = buildPath(base, moved ? row.newPath : row.oldPath);
        const other = buildPath(base, moved ? row.oldPath : row.newPath);
        assert(exists(active) && isFile(active) && !exists(other),
            "Wave19 desktop missing/duplicate real source: " ~ row.oldPath);
        if (row.oldPath == target.oldPath && row.newPath == target.newPath) {
            ++targetHits; selected = moved;
        }
    }
    assert(population == 79, "Wave19 desktop frozen79 coordinate population");
    assert(target.owner == "desktop" && targetHits == 1,
        "Wave19 desktop selected target identity");
    if (wave19ReadDepth) foreach (key, value; selections) wave19DesktopSelections[key] = value;
    return selected;
}


private bool wave19OwnerMoved(string root, const Wave19Owner owner) {
    import std.file : exists, isFile, readText;
    import std.json : parseJSON;
    const base = wave15Normalize(root);
    const cacheKey = base ~ "\0" ~ owner.name;
    if (wave19ReadDepth) if (auto cached = cacheKey in wave19OwnerSelections) return *cached;
    const oldRecipe = buildPath(base, owner.oldRoot, "dub.json");
    const newRecipe = buildPath(base, owner.newRoot, "dub.json");
    const oldPresent = exists(oldRecipe), newPresent = exists(newRecipe);
    assert(oldPresent != newPresent, "Wave19 requires exactly one owner recipe: " ~ owner.name);
    const moved = newPresent;
    const selectedRecipe = parseJSON(readText(moved ? newRecipe : oldRecipe));
    assert(selectedRecipe["name"].str == (moved ? owner.name : "vibe3d-" ~ owner.name),
        "Wave19 selected recipe identity: " ~ owner.name);
    if (owner.name == "cli" && moved)
        assert(selectedRecipe["targetName"].str == "vibe3d-cli"
            && selectedRecipe["targetPath"].str == "../.."
            && selectedRecipe["mainSourceFile"].str == "source/vibe3d/apps/cli/main.d",
            "Wave19 CLI output/source root identity");
    size_t population;
    foreach (row; wave19Modules) {
        if (row.owner != owner.name) continue;
        ++population;
        const physical = buildPath(base, moved ? row.newPath : row.oldPath);
        assert(exists(physical) && isFile(physical), "Wave19 missing real source: " ~ physical);
        assert(!exists(buildPath(base, moved ? row.oldPath : row.newPath)),
            "Wave19 duplicate real source: " ~ row.oldPath);
        const expected = moved ? row.newModule : row.oldModule;
        const code = blankNonCode(readText(physical));
        size_t count;
        foreach (declaration; matchAll(code, ctRegex!(`\bmodule\b`))) ++count;
        assert(count == 1, "Wave19 requires one real module declaration: " ~ row.oldPath);
        auto declaration = matchFirst(code,
            ctRegex!(`\bmodule\s+([A-Za-z_][A-Za-z_0-9.]*)\s*;`));
        assert(!declaration.empty && declaration[1] == expected,
            "Wave19 real module identity: " ~ row.oldPath);
    }
    assert(population != 0, "Wave19 selected owner must have original real inputs: " ~ owner.name);
    if (wave19ReadDepth) wave19OwnerSelections[cacheKey] = moved;
    return moved;
}

private bool wave19RowMoved(string root, const Wave19Module row) {
    if (row.owner == "desktop") return wave19DesktopRowMoved(root, row);
    if (row.owner == "desktop-tests") {
        if (row.oldPath == "tests/unit/commands/file/file_io_registration_test.d") return wave19OwnerMoved(root, "document-actions");
        if (row.oldPath == "tests/unit/tools/edit/topology_pen/gestures_test.d") return wave19OwnerMoved(root, "interactive-tools");
        if (row.oldPath == "tests/unit/tools/edit/topology_pen/reapply_test.d") return wave19OwnerMoved(root, "interactive-tools");
        if (row.oldPath == "tests/unit/ui/grid_plane_test.d") return wave19OwnerMoved(root, "editor-ui");
        if (row.oldPath == "tests/unit/ui/viewport_render_plan_test.d") return wave19OwnerMoved(root, "editor-ui");
        assert(0, "Wave19 unknown stationary host peer");
    }
    return wave19OwnerMoved(root, row.owner);
}
private bool wave19TargetMoved(string root, string target) {
    import std.file : readText;
    size_t hits;
    bool selected;
    foreach (row; wave19Modules) if (row.oldPath == target) {
        ++hits; selected = wave19RowMoved(root, row);
        const physical = buildPath(wave15Normalize(root), selected ? row.newPath : row.oldPath);
        const code = blankNonCode(readText(physical));
        auto declaration = matchFirst(code, ctRegex!(`\bmodule\s+([A-Za-z_][A-Za-z_0-9.]*)\s*;`));
        size_t count;
        foreach (item; matchAll(code, ctRegex!(`\bmodule\b`))) ++count;
        assert(count == 1 && !declaration.empty
            && declaration[1] == (selected ? row.newModule : row.oldModule),
            "Wave19 exact referenced target declaration");
    }
    assert(hits == 1, "Wave19 exact referenced target coordinate");
    return selected;
}

public bool wave19OwnerMoved(string root, string name) {
    foreach (owner; wave19Owners)
        if (owner.name == name) return wave19OwnerMoved(root, owner);
    assert(0, "Wave19 owner is outside the finite math+D1 cut: " ~ name);
}

public string wave19OwnerRoot(string root, string name) {
    foreach (owner; wave19Owners)
        if (owner.name == name)
            return buildPath(wave15Normalize(root), wave19OwnerMoved(root, owner) ? owner.newRoot : owner.oldRoot);
    assert(0, "Wave19 owner is outside the finite math+D1 cut: " ~ name);
}

public bool wave19MathMoved(string root) {
    foreach (owner; wave19Owners)
        if (owner.name == "math") return wave19OwnerMoved(root, owner);
    assert(0, "Wave19 math owner row is required");
}

// Only frozen real files and their original scan roots are coordinates. Reject
// missing/mixed owner states before returning a selected physical input.
public string wave19PhysicalPath(string path, string root = repoRoot) {
    auto readScope = Wave19ReadScope(true);
    import std.file : readText;
    import std.json : parseJSON;
    const normal = wave15Normalize(path), base = wave15Normalize(root);
    foreach (row; wave19Modules)
        if (row.owner == "desktop" || row.owner == "desktop-tests")
            if (normal == buildPath(base, row.oldPath) || normal == buildPath(base, row.newPath))
                return buildPath(base, wave19TargetMoved(base, row.oldPath) ? row.newPath : row.oldPath);
    if (normal == buildPath(base, "source") || normal == buildPath(base, "apps/desktop/source")) {
        foreach (row; wave19Modules) if (row.owner == "desktop")
            return buildPath(base, wave19DesktopRowMoved(base, row) && parseJSON(readText(buildPath(base, "dub.json")))["sourcePaths"].array[0].str == "apps/desktop/source" ? "apps/desktop/source" : "source");
    }
    foreach (owner; wave19Owners) {
        foreach (suffix; ["", "/source", "/tests", "/tests/source"])
            if (normal == buildPath(base, owner.oldRoot) ~ suffix)
                return buildPath(base, wave19OwnerMoved(base, owner) ? owner.newRoot : owner.oldRoot) ~ suffix;
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            if (normal == buildPath(base, row.oldPath) || normal == buildPath(base, row.newPath))
                return buildPath(base, wave19OwnerMoved(base, owner) ? row.newPath : row.oldPath);
        }
    }
    return normal;
}

public string wave19LogicalPath(string path, string root = repoRoot) {
    const normal = wave15Normalize(path), base = wave15Normalize(root);
    if (normal == buildPath(base, "apps/desktop/source")) return buildPath(base, "source");
    foreach (row; wave19Modules)
        if (normal == buildPath(base, row.newPath)) return buildPath(base, row.oldPath);
    foreach (owner; wave19Owners)
        foreach (suffix; ["", "/source", "/tests", "/tests/source"])
            if (normal == buildPath(base, owner.newRoot) ~ suffix)
                return buildPath(base, owner.oldRoot) ~ suffix;
    return normal;
}

// Existing direct-reader entry points retain their math contract while the
// shared bridge now also admits the twelve approved D1 owners.
public string wave19MathPhysicalPath(string path, string root = repoRoot) {
    return wave19PhysicalPath(path, root);
}
public string wave19MathLogicalPath(string path, string root = repoRoot) {
    return wave19LogicalPath(path, root);
}

// Only module/import token spans may be inverted. Strings, comments and body
// expressions retain their actual bytes for the original census assertions.
package(tests.unit) string wave19MathLogicalText(string source) {
    const code = blankNonCode(source);
    struct Edit { size_t begin, end; string text; }
    Edit[] edits;
    foreach (statement; matchAll(code, regex(`\b(?:module|import)\s+[A-Za-z_][^;{}]*;`))) {
        foreach (token; matchAll(statement[0], regex(`[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*`))) {
            foreach (row; wave19Modules) {
                if (token[0] != row.newModule) continue;
                const offset = statement.pre.length + token.pre.length;
                auto binding = matchFirst(token.pre, regex("\\b" ~ row.oldModule.replace(".", "\\.") ~ `\s*=\s*$`));
                const begin = binding.empty ? offset : statement.pre.length + binding.pre.length;
                edits ~= Edit(begin, offset + token[0].length, row.oldModule);
            }
        }
    }
    string text;
    size_t offset;
    foreach (edit; edits) {
        text ~= source[offset .. edit.begin] ~ edit.text;
        offset = edit.end;
    }
    return text ~ source[offset .. $];
}

// Raw current D input, before historical body reconstruction. This also
// preserves historical import bytes in unmoved consumers and fragment carriers.

// Approved full460 of460 non-import live identities. Referenced-owner state
// controls spelling; source/module custody remains the original158-row table.
private struct Wave19Identity {
    string id, path, owner, target, anchor;
    size_t offset;
    string oldText, newText;
    bool literal;
}
private immutable Wave19Identity[] wave19Identities = [
    Wave19Identity("ID001", "packages/alignment-ops/tests/source/tests/unit/alignment_ops_population_test.d", "alignment-ops", "packages/alignment-ops/tests/source/tests/unit/tools/alignment/align_kernels_test.d", "        \"tests.unit.tools.alignment.align_kernels_test\",", 9, "tests.unit.tools.alignment.align_kernels_test", "vibe3d.editing.tools.alignment.tests.unit.tools.alignment.align_kernels_test", true),
    Wave19Identity("ID002", "packages/alignment-ops/tests/source/tests/unit/alignment_ops_population_test.d", "alignment-ops", "packages/alignment-ops/source/tools/alignment/align_kernels.d", "        \"tools.alignment.align_kernels\",", 9, "tools.alignment.align_kernels", "vibe3d.editing.tools.alignment.tools.alignment.align_kernels", true),
    Wave19Identity("ID003", "packages/application-core/tests/source/tests/unit/application_core_population_test.d", "application-core", "packages/application-core/tests/source/tests/unit/application_core_population_test.d", "    immutable string[] expected = [\"tests.unit.application_core_population_test\", \"tests.unit.command_invocation_test\", \"tests.unit.standalone_application_test\"];", 36, "tests.unit.application_core_population_test", "vibe3d.runtime.application_core.tests.unit.application_core_population_test", true),
    Wave19Identity("ID004", "packages/application-core/tests/source/tests/unit/application_core_population_test.d", "application-core", "packages/application-core/tests/source/tests/unit/command_invocation_test.d", "    immutable string[] expected = [\"tests.unit.application_core_population_test\", \"tests.unit.command_invocation_test\", \"tests.unit.standalone_application_test\"];", 83, "tests.unit.command_invocation_test", "vibe3d.runtime.application_core.tests.unit.command_invocation_test", true),
    Wave19Identity("ID005", "packages/application-core/tests/source/tests/unit/application_core_population_test.d", "application-core", "packages/application-core/tests/source/tests/unit/standalone_application_test.d", "    immutable string[] expected = [\"tests.unit.application_core_population_test\", \"tests.unit.command_invocation_test\", \"tests.unit.standalone_application_test\"];", 121, "tests.unit.standalone_application_test", "vibe3d.runtime.application_core.tests.unit.standalone_application_test", true),
    Wave19Identity("ID006", "packages/camera-model/tests/source/tests/unit/camera_model_population_test.d", "camera-model", "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d", "        \"tests.unit.view_source_cells_test\",", 9, "tests.unit.view_source_cells_test", "vibe3d.viewport.camera.tests.unit.view_source_cells_test", true),
    Wave19Identity("ID007", "packages/camera-model/tests/source/tests/unit/camera_model_population_test.d", "camera-model", "packages/camera-model/tests/source/tests/unit/view_test.d", "        \"tests.unit.view_test\",", 9, "tests.unit.view_test", "vibe3d.viewport.camera.tests.unit.view_test", true),
    Wave19Identity("ID008", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/source/command_history.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 36, "command_history", "vibe3d.editing.commands.runtime.command_history", true),
    Wave19Identity("ID009", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/source/command_registry.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 55, "command_registry", "vibe3d.editing.commands.runtime.command_registry", true),
    Wave19Identity("ID010", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 75, "tests.unit.base_revert_flag_test", "vibe3d.editing.commands.runtime.tests.unit.base_revert_flag_test", true),
    Wave19Identity("ID011", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 111, "tests.unit.command_apply_anchor_test", "vibe3d.editing.commands.runtime.tests.unit.command_apply_anchor_test", true),
    Wave19Identity("ID012", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 151, "tests.unit.command_bindargs_test", "vibe3d.editing.commands.runtime.tests.unit.command_bindargs_test", true),
    Wave19Identity("ID013", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 187, "tests.unit.command_history_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.command_history_source_public_test", true),
    Wave19Identity("ID014", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_registry_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 236, "tests.unit.command_registry_test", "vibe3d.editing.commands.runtime.tests.unit.command_registry_test", true),
    Wave19Identity("ID015", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 272, "tests.unit.command_runtime_population_test", "vibe3d.editing.commands.runtime.tests.unit.command_runtime_population_test", true),
    Wave19Identity("ID016", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 318, "tests.unit.command_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.command_source_public_test", true),
    Wave19Identity("ID017", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 359, "tests.unit.commands.mesh.session_edit_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.mesh.session_edit_source_public_test", true),
    Wave19Identity("ID018", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 419, "tests.unit.commands.select.element_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.select.element_source_public_test", true),
    Wave19Identity("ID019", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 476, "tests.unit.record_observer_hub_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.record_observer_hub_source_public_test", true),
    Wave19Identity("ID020", "packages/command-runtime/tests/source/tests/unit/command_runtime_population_test.d", "command-runtime", "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d", "    immutable string[] expected = [\"command_history\", \"command_registry\", \"tests.unit.base_revert_flag_test\", \"tests.unit.command_apply_anchor_test\", \"tests.unit.command_bindargs_test\", \"tests.unit.command_history_source_public_test\", \"tests.unit.command_registry_test\", \"tests.unit.command_runtime_population_test\", \"tests.unit.command_source_public_test\", \"tests.unit.commands.mesh.session_edit_source_public_test\", \"tests.unit.commands.select.element_source_public_test\", \"tests.unit.record_observer_hub_source_public_test\", \"tests.unit.session_edit_payload_test\"];", 529, "tests.unit.session_edit_payload_test", "vibe3d.editing.commands.runtime.tests.unit.session_edit_payload_test", true),
    Wave19Identity("ID021", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "creation-ops", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "        \"tests.unit.tools.create.pen_geometry_population_test\",", 9, "tests.unit.tools.create.pen_geometry_population_test", "vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_population_test", true),
    Wave19Identity("ID022", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "creation-ops", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_test.d", "        \"tests.unit.tools.create.pen_geometry_test\",", 9, "tests.unit.tools.create.pen_geometry_test", "vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_test", true),
    Wave19Identity("ID023", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "creation-ops", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_population_test.d", "            m.name.startsWith(\"tests.unit.tools.create.pen_geometry_\"))", 31, "tests.unit.tools.create.pen_geometry_", "vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_", true),
    Wave19Identity("ID024", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/camera_stamp_test.d", "        \"tests.unit.camera_stamp_test\",", 9, "tests.unit.camera_stamp_test", "vibe3d.viewport.display_policy.tests.unit.camera_stamp_test", true),
    Wave19Identity("ID025", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/retopology_display_model_test.d", "        \"tests.unit.retopology_display_model_test\",", 9, "tests.unit.retopology_display_model_test", "vibe3d.viewport.display_policy.tests.unit.retopology_display_model_test", true),
    Wave19Identity("ID026", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/retopology_dot_cull_test.d", "        \"tests.unit.retopology_dot_cull_test\",", 9, "tests.unit.retopology_dot_cull_test", "vibe3d.viewport.display_policy.tests.unit.retopology_dot_cull_test", true),
    Wave19Identity("ID027", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/retopology_line_shade_algorithm_cells_test.d", "        \"tests.unit.retopology_line_shade_algorithm_cells_test\",", 9, "tests.unit.retopology_line_shade_algorithm_cells_test", "vibe3d.viewport.display_policy.tests.unit.retopology_line_shade_algorithm_cells_test", true),
    Wave19Identity("ID028", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/retopology_order_algorithm_cells_test.d", "        \"tests.unit.retopology_order_algorithm_cells_test\",", 9, "tests.unit.retopology_order_algorithm_cells_test", "vibe3d.viewport.display_policy.tests.unit.retopology_order_algorithm_cells_test", true),
    Wave19Identity("ID029", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/select_visibility_test.d", "        \"tests.unit.select_visibility_test\",", 9, "tests.unit.select_visibility_test", "vibe3d.viewport.display_policy.tests.unit.select_visibility_test", true),
    Wave19Identity("ID030", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/vertex_normals_test.d", "        \"tests.unit.vertex_normals_test\",", 9, "tests.unit.vertex_normals_test", "vibe3d.viewport.display_policy.tests.unit.vertex_normals_test", true),
    Wave19Identity("ID031", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/viewport_scheme_test.d", "        \"tests.unit.viewport_scheme_test\",", 9, "tests.unit.viewport_scheme_test", "vibe3d.viewport.display_policy.tests.unit.viewport_scheme_test", true),
    Wave19Identity("ID032", "packages/display-policy/tests/source/tests/unit/display_policy_population_test.d", "display-policy", "packages/display-policy/tests/source/tests/unit/weightmap_state_test.d", "        \"tests.unit.weightmap_state_test\",", 9, "tests.unit.weightmap_state_test", "vibe3d.viewport.display_policy.tests.unit.weightmap_state_test", true),
    Wave19Identity("ID033", "packages/document-actions/source/commands/file/quit.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (fromWindowClose_ && command.g_testMode) return false;", 32, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID034", "packages/document-actions/source/commands/file/quit.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (command.g_testMode && !fromWindowClose_) return true;", 12, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID035", "packages/document-channels/tests/source/tests/unit/document_channels_population_test.d", "document-channels", "packages/document-channels/tests/source/tests/unit/layer_params_test.d", "        \"tests.unit.layer_params_test\",", 9, "tests.unit.layer_params_test", "vibe3d.documents.channels.tests.unit.layer_params_test", true),
    Wave19Identity("ID036", "packages/document-io/tests/source/tests/unit/document_io_population_test.d", "document-io", "packages/document-io/source/io/native.d", "        \"io.native\",", 9, "io.native", "vibe3d.documents.io.io.native", true),
    Wave19Identity("ID037", "packages/document-io/tests/source/tests/unit/document_io_population_test.d", "document-io", "packages/document-io/tests/source/tests/unit/io/image_path_test.d", "        \"tests.unit.io.image_path_test\",", 9, "tests.unit.io.image_path_test", "vibe3d.documents.io.tests.unit.io.image_path_test", true),
    Wave19Identity("ID038", "packages/document-io/tests/source/tests/unit/document_io_population_test.d", "document-io", "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d", "        \"tests.unit.io.native_source_cells_test\",", 9, "tests.unit.io.native_source_cells_test", "vibe3d.documents.io.tests.unit.io.native_source_cells_test", true),
    Wave19Identity("ID039", "packages/document-io/tests/source/tests/unit/document_io_population_test.d", "document-io", "packages/document-io/tests/source/tests/unit/io/native_test.d", "        \"tests.unit.io.native_test\",", 9, "tests.unit.io.native_test", "vibe3d.documents.io.tests.unit.io.native_test", true),
    Wave19Identity("ID040", "packages/editor-commands/source/commands/mesh/subdivide_faceted.d", "editor-commands", "packages/editor-commands/source/commands/mesh/subdivide_faceted.d", "package void runFacetedFamily(Mesh* mesh, EditMode editMode, bool smooth)", 0, "package", "package(vibe3d.editing.commands.editor.commands.mesh)", false),
    Wave19Identity("ID041", "packages/editor-commands/source/commands/mesh/uv_project.d", "editor-commands", "packages/editor-commands/source/commands/mesh/uv_project.d", "package struct UvLoopRef { uint fi; size_t loop; }", 0, "package", "package(vibe3d.editing.commands.editor.commands.mesh)", false),
    Wave19Identity("ID042", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/source/commands/mesh/edge_crease.d", "        \"commands.mesh.edge_crease\",", 9, "commands.mesh.edge_crease", "vibe3d.editing.commands.editor.commands.mesh.edge_crease", true),
    Wave19Identity("ID043", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d", "        \"tests.unit.commands.mesh.edge_crease_source_public_test\",", 9, "tests.unit.commands.mesh.edge_crease_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.edge_crease_source_public_test", true),
    Wave19Identity("ID044", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d", "        \"tests.unit.commands.mesh.remove_source_public_test\",", 9, "tests.unit.commands.mesh.remove_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.remove_source_public_test", true),
    Wave19Identity("ID045", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d", "        \"tests.unit.commands.mesh.symmetrize_source_public_test\",", 9, "tests.unit.commands.mesh.symmetrize_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.symmetrize_source_public_test", true),
    Wave19Identity("ID046", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d", "        \"tests.unit.commands.mesh.vertex_set_source_public_test\",", 9, "tests.unit.commands.mesh.vertex_set_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.mesh.vertex_set_source_public_test", true),
    Wave19Identity("ID047", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d", "        \"tests.unit.commands.select.boundary_source_public_test\",", 9, "tests.unit.commands.select.boundary_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.boundary_source_public_test", true),
    Wave19Identity("ID048", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d", "        \"tests.unit.commands.select.by_stat_source_public_test\",", 9, "tests.unit.commands.select.by_stat_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.by_stat_source_public_test", true),
    Wave19Identity("ID049", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d", "        \"tests.unit.commands.select.by_tag_source_public_test\",", 9, "tests.unit.commands.select.by_tag_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.by_tag_source_public_test", true),
    Wave19Identity("ID050", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d", "        \"tests.unit.commands.select.type_from_source_public_test\",", 9, "tests.unit.commands.select.type_from_source_public_test", "vibe3d.editing.commands.editor.tests.unit.commands.select.type_from_source_public_test", true),
    Wave19Identity("ID051", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "editor-commands", "packages/editor-commands/tests/source/tests/unit/editor_commands_population_test.d", "        \"tests.unit.editor_commands_population_test\",", 9, "tests.unit.editor_commands_population_test", "vibe3d.editing.commands.editor.tests.unit.editor_commands_population_test", true),
    Wave19Identity("ID052", "packages/http-runtime/source/http_server.d", "http-runtime", "packages/http-runtime/source/http_server.d", "    package static string statusLineFor(int code) {", 4, "package", "private", false),
    Wave19Identity("ID053", "packages/image-codec/tests/source/tests/unit/image_codec_population_test.d", "image-codec", "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d", "        \"tests.unit.io.image_decode_source_cells_test\",", 9, "tests.unit.io.image_decode_source_cells_test", "vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test", true),
    Wave19Identity("ID054", "packages/image-codec/tests/source/tests/unit/image_codec_population_test.d", "image-codec", "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d", "        \"tests.unit.io.image_decode_test\",", 9, "tests.unit.io.image_decode_test", "vibe3d.documents.image_codec.tests.unit.io.image_decode_test", true),
    Wave19Identity("ID055", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/source/eventlog.d", "        \"eventlog\",", 9, "eventlog", "vibe3d.platform.input.eventlog", true),
    Wave19Identity("ID056", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/tests/source/tests/unit/binding_resolve_test.d", "        \"tests.unit.binding_resolve_test\",", 9, "tests.unit.binding_resolve_test", "vibe3d.platform.input.tests.unit.binding_resolve_test", true),
    Wave19Identity("ID057", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/tests/source/tests/unit/eventlog_parser_test.d", "        \"tests.unit.eventlog_parser_test\",", 9, "tests.unit.eventlog_parser_test", "vibe3d.platform.input.tests.unit.eventlog_parser_test", true),
    Wave19Identity("ID058", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/tests/source/tests/unit/eventlog_test.d", "        \"tests.unit.eventlog_test\",", 9, "tests.unit.eventlog_test", "vibe3d.platform.input.tests.unit.eventlog_test", true),
    Wave19Identity("ID059", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/tests/source/tests/unit/tool_input_test.d", "        \"tests.unit.tool_input_test\",", 9, "tests.unit.tool_input_test", "vibe3d.platform.input.tests.unit.tool_input_test", true),
    Wave19Identity("ID060", "packages/input-events/tests/source/tests/unit/input_events_population_test.d", "input-events", "packages/input-events/source/tool_input.d", "        \"tool_input\",", 9, "tool_input", "vibe3d.platform.input.tool_input", true),
    Wave19Identity("ID061", "packages/interactive-tools/source/edit_session.d", "interactive-tools", "packages/interactive-tools/source/commands/tool/lifecycle.d", "            const imported!\"commands.tool.lifecycle\".ToolActivationCommand act,", 28, "commands.tool.lifecycle", "vibe3d.editing.tools.interactive.commands.tool.lifecycle", true),
    Wave19Identity("ID062", "packages/interactive-tools/source/handles/gl_util.d", "interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "package GLuint buildVao3f(float[] data, out GLuint vbo) {", 0, "package", "package(vibe3d.editing.tools.interactive.handles)", false),
    Wave19Identity("ID063", "packages/interactive-tools/source/handles/gl_util.d", "interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "package void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {", 0, "package", "package(vibe3d.editing.tools.interactive.handles)", false),
    Wave19Identity("ID064", "packages/interactive-tools/source/handles/gl_util.d", "interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "package void buildUnitCubeData(ref float[] data) {", 0, "package", "package(vibe3d.editing.tools.interactive.handles)", false),
    Wave19Identity("ID065", "packages/interactive-tools/source/handles/gl_util.d", "interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "package void buildWedgeHeadData(ref float[] data) {", 0, "package", "package(vibe3d.editing.tools.interactive.handles)", false),
    Wave19Identity("ID066", "packages/interactive-tools/source/handles/gl_util.d", "interactive-tools", "packages/interactive-tools/source/handles/gl_util.d", "package void drawThickLines(GLuint vao, int vertCount, GLenum mode,", 0, "package", "package(vibe3d.editing.tools.interactive.handles)", false),
    Wave19Identity("ID067", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum BuildCase { None, Edge, Tri, Quad }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID068", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum PenMode { Move, Duplicate, Remove, Split, AddLoop, Point, Fill, Smooth }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID069", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum PenStepKind : int {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID070", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum ReapplyShape { attributeOnly, carriedT, rerunFromBasis, basisOnly }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID071", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package struct ReapplyRow { string[] reads; ReapplyShape shape; }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID072", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package static immutable ReapplyRow[PenStepKind.max + 1] kReapply = [", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID073", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum SlideDecline { None, NoEdge, NoContinuation }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID074", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum MoveElem { None, Vertex, Edge, Face }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID075", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum PenGesture {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID076", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum ModeOv : ubyte { FromUser, Duplicate, Split, AddLoop, Remove, Smooth }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID077", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum FlagOv : ubyte { FromUser, ForceOn }", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID078", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package struct ChordOv {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID079", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package enum TopoPenChord : ToolAction {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID080", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package immutable ChordOv[12] kChordOv = [", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID081", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package InputButton chordButton(TopoPenChord c) {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID082", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package PenMode modeOfOverride(ModeOv m) {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID083", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/defs.d", "package immutable InputBinding[] kTopoPenBindings = [", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID084", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "package bool isEdgeInterior(in int[] polyCount, uint ei) {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID085", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "package bool isEdgeInterior(Mesh* m, uint ei) {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID086", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "package bool isVertexInterior(Mesh* m, uint vi) {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID087", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "    package Vec3     aimDir_ = Vec3(0, 0, 0);", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID088", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d", "package bool admitsMoveElement(ref Mesh m, SnapType type, int index,", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID089", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "package enum string[] kGestureArmFields = () {", 0, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID090", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Mesh* delegate() meshSrc_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID091", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void history_(CommandHistory h) { history = h; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID092", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenBuildFactory        buildEditFactory_()        { return factories_.build; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID093", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenMoveFactory         moveEditFactory_()         { return factories_.move; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID094", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenRemoveFactory       removeEditFactory_()       { return factories_.remove; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID095", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenRemoveEdgeFactory   removeEdgeEditFactory_()   { return factories_.removeEdge; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID096", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenRemoveVertexFactory removeVertexEditFactory_() { return factories_.removeVertex; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID097", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenAddLoopFactory      addLoopEditFactory_()      { return factories_.addLoop; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID098", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenSlideFactory        slideEditFactory_()        { return factories_.slide; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID099", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenSmoothFactory       smoothEditFactory_()       { return factories_.smooth; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID100", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenSplitFactory        splitEditFactory_()        { return factories_.split; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID101", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenMoveLoopFactory     moveLoopEditFactory_()     { return factories_.moveLoop; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID102", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenDupLoopFactory      dupLoopEditFactory_()      { return factories_.dupLoop; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID103", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenSmoothLoopFactory   smoothLoopEditFactory_()   { return factories_.smoothLoop; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID104", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenFillFactory         fillEditFactory_()         { return factories_.fill; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID105", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenPlaceFactory        placeEditFactory_()        { return factories_.place; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID106", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package @property ref TopoPenAttrFactory         attrEditFactory_()         { return factories_.attr; }", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID107", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int       sourceVert_     = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID108", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm      dragArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID109", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm placeArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID110", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm moveArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID111", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  grabbedVert_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID112", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MoveElem     moveElem_  = MoveElem.None;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID113", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[]       moveVerts_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID114", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3[]       moveBase_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID115", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3         moveAnchor_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID116", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3         moveOffset_ = Vec3(0, 0, 0);", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID117", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool         moveAxisLock_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID118", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int          moveAxis_     = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID119", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int          moveStartX_, moveStartY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID120", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool         moveDirty_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID121", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MeshSnapshot basis_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID122", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool         stepOpen_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID123", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package ubyte        heldMask_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID124", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package ubyte        inertButtons_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID125", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float        offsetX_ = 0.0f, offsetY_ = 0.0f, offsetZ_ = 0.0f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID126", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package PenStepKind[] stepKind_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID127", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[]       stepVerts_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID128", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3[]       stepOrig_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID129", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package PenStepKind stepKind() const {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID130", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  addLoopSeed_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID131", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm addLoopArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID132", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3 seedRailA_, seedRailB_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID133", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float addLoopRatio_ = 0.5f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID134", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool addLoopMiddle_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID135", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideSeed_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID136", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm  slideArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID137", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideStartX_, slideStartY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID138", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideEndA_ = -1, slideEndB_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID139", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideNbrA_ = -1, slideNbrB_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID140", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3  slideAnchor_ = Vec3(0, 0, 0);", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID141", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float slideDeltaK_ = 0.0f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID142", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideVertex_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID143", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slideAxis_   = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID144", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3  slideVertexTarget_ = Vec3(0, 0, 0);", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID145", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool  slideOverBg_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID146", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float slidePathPx_ = 0.0f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID147", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   slidePrevX_, slidePrevY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID148", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3  slideEdgeTargetA_ = Vec3(0, 0, 0), slideEdgeTargetB_ = Vec3(0, 0, 0);", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID149", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package SlideDecline slideDecline_     = SlideDecline.None;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID150", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int          slideDeclineSeed_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID151", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm  smoothArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID152", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm splitArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID153", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  splitSourceVert_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID154", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  splitTargetVert_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID155", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package SnapPacket dragSnap_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID156", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package PenMode penMode_ = PenMode.Move;   // live-measured reference default", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID157", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool edgeLoop_  = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID158", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool edgeSlide_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID159", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool innerSnap_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID160", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool backFace_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID161", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool keepVertex_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID162", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float fillRange_    = kFillRangeDefault;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID163", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool  fillQuadOnly_ = true;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID164", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package PenGesture[3] gestureOn_ = PenGesture.PlaceOrMove;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID165", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm  moveLoopArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID166", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   moveLoopSeed_   = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID167", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   moveLoopStartX_, moveLoopStartY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID168", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[] moveLoopVerts_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID169", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm  dupLoopArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID170", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   dupLoopSeed_    = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID171", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int[] dupLoopEdges_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID172", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   dupLoopStartX_, dupLoopStartY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID173", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm  dupEdgeArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID174", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int   dupEdgeSeed_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID175", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int[] dupEdgeEdges_;          // what the release will duplicate: [seed], or the trimmed border run", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID176", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package GestureArm   smoothLoopArmed_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID177", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int    smoothLoopSeed_    = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID178", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[] smoothLoopVerts_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID179", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int    smoothLoopStartX_, smoothLoopStartY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID180", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int    smoothLoopCurX_,   smoothLoopCurY_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID181", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float  smoothLoopDragPx_ = 0.0f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID182", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static int smoothPassesForDragDx(int dragDx) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID183", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float smoothStrength_ = kSmoothStrengthDefault;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID184", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool hoverOverMesh_     = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID185", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  hoverNearestVert_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID186", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  hoverNearestEdge_  = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID187", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool hoverBoundary_     = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID188", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int  hoverBoundaryFace_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID189", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MoveElem hoverGrabElem_  = MoveElem.None;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID190", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int      hoverGrabIndex_ = -1;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID191", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool showVertex_ = true;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID192", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool showEdge_   = true;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID193", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[] fillRing_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID194", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool  fillRadiusValid_ = false;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID195", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float fillRadiusPx_    = 0.0f;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID196", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static bool projectWorldPt(Vec3 pWorld, const ref Viewport vp, out ImVec2 pt) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID197", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static float fillHoverRadiusPx(float cursorX, float cursorY,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID198", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void reapplyLastStep(string name) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID199", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package PenSnapGuide snapGuide_;", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID200", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void registerSnapGuide() {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID201", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void unregisterSnapGuide() {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID202", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int resolveSnapTargetVert(int mx, int my, const ref Viewport vp,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID203", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int resolveSplitTargetVert(int mx, int my, const ref Viewport vp, int a) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID204", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int findSourceVertex(int mx, int my, const ref Viewport vp,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID205", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static void sideIncidence(const Mesh* m, uint a, uint x,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID206", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int triNeighbourAt(int x, int y, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID207", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3 sourceTangentNormal(int a) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID208", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int nAngleNeighbour(int a, Vec3 deltaW, Vec3 nW) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID209", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int fillSeedEdge(int mx, int my, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID210", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package uint[] findFillRing(int mx, int my, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID211", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool openPressStep(ubyte button, PenMode chordMode) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID212", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void closePressStep() {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID213", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void resetAllGestureArms() {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID214", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool anyGestureArmed() const {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID215", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onPlainLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID216", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MoveElem resolveGrabTarget(int mx, int my, const ref Viewport vp, out int index,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID217", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MoveElem grabTargetElement(hover_state.ToolPressTarget hit, out int index) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID218", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interaction-query", "packages/interaction-query/source/hover_state.d", "    package MoveElem grabTargetElement(hover_state.ToolPressTarget hit, out int index) {", 39, "hover_state", "vibe3d.editing.selection.query.hover_state", false),
    Wave19Identity("ID219", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package auto queryPressTarget(int mx, int my, const ref Viewport vp, bool occlusion,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID220", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package auto legacyPressGather(int mx, int my, const ref Viewport vp, bool occlusion,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID221", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interaction-query", "packages/interaction-query/source/hover_state.d", "            hover_state.ToolPressSource primary, const(bool)[] ordinaryV = null,", 12, "hover_state", "vibe3d.editing.selection.query.hover_state", false),
    Wave19Identity("ID222", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package MoveElem hoverIndicatorElem() const {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID223", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int[] trimBorderRunAroundSeed(const(int)[] gathered, int seed) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID224", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3 pressAnchor(MoveElem kind, int index, int px, int py, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID225", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3[] moveTargets(int px, int py, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID226", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    // geometry pass consumes H+Offset (9528, perspective guide amendment).\n    package bool grabOffset(Vec3 anchorLocal, int dx, int dy, const ref Viewport vp,\n                            out Vec3 offLocal) {", 80, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID227", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "\n    package bool grabOffset(Vec3 anchorLocal, int dx, int dy, const ref Viewport vp,\n                            out Vec3 offLocal, out bool acceptedPerspective, bool perspectiveGuideRequested,", 5, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID228", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void applyMoveTargets(const(Vec3)[] targets, ref VectorStack vts,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID229", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onShiftLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID230", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package int findRingSeedEdge(int mx, int my, const ref Viewport vp,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID231", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void computeHoverIndicator(int mx, int my, const ref Viewport vp) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID232", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static float dominantAxisDelta(Vec3 delta) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID233", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static int[] continuationRailCandidates(Mesh* m, uint x, uint other) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID234", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static int continuationNeighbor(Mesh* m, uint x, uint other) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID235", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID236", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static bool screenAxisImages(const ref Viewport vp, Vec3 p, out double[2][3] J) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID237", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static int vertexSlideAxis(const double[2][3] J, double dx, double dy, double tau,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID238", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static int edgeSlideAxis(Vec3 d, double eps) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID239", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static uint[] uniqueRingVerts(Mesh* m, uint seedEdge) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID240", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onMoveLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID241", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onDupLoopShiftRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID242", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool onSmoothLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID243", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool resnapToBackground(Vec3 orig, int px, int py,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID244", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3[] perVertexTargets(const(uint)[] verts, int dx, int dy,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID245", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package Vec3[] perVertexTargetsFrom(const(Vec3)[] base, int dx, int dy,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID246", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool lmbPlaceOrMoveUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID247", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool buildUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID248", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool slideUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID249", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool splitUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID250", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package float addLoopFrac(float cursorRatio) const {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID251", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool addLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID252", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool moveLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID253", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool dupLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID254", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool smoothLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID255", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package bool lmbModeUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID256", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitSlide(uint seed, int eA, int eB, int nA, int nB, double deltaK) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID257", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitSlideTargets(int eA, int eB, Vec3 pA, Vec3 pB) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID258", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static bool isOpenEdge(Mesh* m, uint ei) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID259", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static bool isOpenVertex(Mesh* m, uint v,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID260", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static Vec3 inverseEdgeLenRelax(const(Vec3)[] readPos, uint v,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID261", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static RelaxTopology buildRelaxTopology(Mesh* m) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID262", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static uint[][uint] loopNeighborsOf(Mesh* m, uint seed) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID263", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void applySmoothPasses(int passCount) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID264", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void applySmoothLoopPasses(int passCount) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID265", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void buildFromSource(int a, BuildCase casee, int n, int p, int q,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID266", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void removeFaceAt(int faceIdx) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID267", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void removeEdgeAt(int edgeIdx, bool loop) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID268", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitAddLoop(uint seedEdge, float r) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID269", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitSplit(int a, int c) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID270", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitFill(const(uint)[] ringVerts) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID271", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package static void consumeDegenerateOnRing(Mesh* m, const(uint)[] ring) {", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID272", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitMoveLoop(const(uint)[] verts, const(Vec3)[] targets,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID273", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "interactive-tools", "packages/interactive-tools/source/tools/edit/topology_pen/tool.d", "    package void commitDupLoop(const(int)[] loopEdges, int dx, int dy,", 4, "package", "package(vibe3d.editing.tools.interactive.tools.edit.topology_pen)", false),
    Wave19Identity("ID274", "packages/interactive-tools/source/tools/transform/transform.d", "transform-ops", "packages/transform-ops/source/tools/transform/cluster_values.d", "    public alias ClusterPivots = tools.transform.cluster_values.ClusterPivots;", 33, "tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values", false),
    Wave19Identity("ID275", "packages/interactive-tools/source/tools/transform/transform.d", "transform-ops", "packages/transform-ops/source/tools/transform/cluster_values.d", "    public alias ClusterAxes = tools.transform.cluster_values.ClusterAxes;", 31, "tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values", false),
    Wave19Identity("ID276", "packages/interactive-tools/tests/source/tests/unit/command_history_test.d", "interactive-tools", "packages/interactive-tools/source/commands/tool/lifecycle.d", "static assert(is(commands.tool.lifecycle.ToolArmLifecyclePolicy ==", 17, "commands.tool.lifecycle", "vibe3d.editing.tools.interactive.commands.tool.lifecycle", false),
    Wave19Identity("ID277", "packages/interactive-tools/tests/source/tests/unit/command_history_test.d", "command-runtime", "packages/command-runtime/source/commands/mesh/session_edit.d", "class ResidualPress : commands.mesh.session_edit.MeshSessionEdit {", 22, "commands.mesh.session_edit", "vibe3d.editing.commands.editor.commands.mesh.session_edit", false),
    Wave19Identity("ID278", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "command-runtime", "packages/command-runtime/source/command_history.d", "    \"command_history\",", 5, "command_history", "vibe3d.editing.commands.runtime.command_history", true),
    Wave19Identity("ID279", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "document-model", "packages/document-model/source/document.d", "    \"document\",", 5, "document", "vibe3d.documents.model.document", true),
    Wave19Identity("ID280", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/handles/shapes.d", "    \"handles.shapes\",", 5, "handles.shapes", "vibe3d.editing.tools.interactive.handles.shapes", true),
    Wave19Identity("ID281", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "viewport-gpu", "packages/viewport-gpu/source/mesh_gpu.d", "    \"mesh_gpu\",", 5, "mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu", true),
    Wave19Identity("ID282", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_bridge_activation.d", "    \"prepared_bridge_activation\",", 5, "prepared_bridge_activation", "vibe3d.editing.tools.interactive.prepared_bridge_activation", true),
    Wave19Identity("ID283", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_command_wrapper_activation.d", "    \"prepared_command_wrapper_activation\",", 5, "prepared_command_wrapper_activation", "vibe3d.editing.tools.interactive.prepared_command_wrapper_activation", true),
    Wave19Identity("ID284", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_bevel_activation.d", "    \"prepared_edge_bevel_activation\",", 5, "prepared_edge_bevel_activation", "vibe3d.editing.tools.interactive.prepared_edge_bevel_activation", true),
    Wave19Identity("ID285", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_extend_deactivate.d", "    \"prepared_edge_extend_deactivate\",", 5, "prepared_edge_extend_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate", true),
    Wave19Identity("ID286", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_extend_tool_activation.d", "    \"prepared_edge_extend_tool_activation\",", 5, "prepared_edge_extend_tool_activation", "vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation", true),
    Wave19Identity("ID287", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_extrude_activation.d", "    \"prepared_edge_extrude_activation\",", 5, "prepared_edge_extrude_activation", "vibe3d.editing.tools.interactive.prepared_edge_extrude_activation", true),
    Wave19Identity("ID288", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_slice_activation.d", "    \"prepared_edge_slice_activation\",", 5, "prepared_edge_slice_activation", "vibe3d.editing.tools.interactive.prepared_edge_slice_activation", true),
    Wave19Identity("ID289", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_edge_slice_deactivate.d", "    \"prepared_edge_slice_deactivate\",", 5, "prepared_edge_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate", true),
    Wave19Identity("ID290", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_inherited_noop.d", "    \"prepared_inherited_noop\",", 5, "prepared_inherited_noop", "vibe3d.editing.tools.interactive.prepared_inherited_noop", true),
    Wave19Identity("ID291", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_loop_slice_activation.d", "    \"prepared_loop_slice_activation\",", 5, "prepared_loop_slice_activation", "vibe3d.editing.tools.interactive.prepared_loop_slice_activation", true),
    Wave19Identity("ID292", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_loop_slice_deactivate.d", "    \"prepared_loop_slice_deactivate\",", 5, "prepared_loop_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate", true),
    Wave19Identity("ID293", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_mirror_activation.d", "    \"prepared_mirror_activation\",", 5, "prepared_mirror_activation", "vibe3d.editing.tools.interactive.prepared_mirror_activation", true),
    Wave19Identity("ID294", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_move_update.d", "    \"prepared_move_update\",", 5, "prepared_move_update", "vibe3d.editing.tools.interactive.prepared_move_update", true),
    Wave19Identity("ID295", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_param_update.d", "    \"prepared_param_update\",", 5, "prepared_param_update", "vibe3d.editing.tools.interactive.prepared_param_update", true),
    Wave19Identity("ID296", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_poly_bevel_activation.d", "    \"prepared_poly_bevel_activation\",", 5, "prepared_poly_bevel_activation", "vibe3d.editing.tools.interactive.prepared_poly_bevel_activation", true),
    Wave19Identity("ID297", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_poly_extrude_activation.d", "    \"prepared_poly_extrude_activation\",", 5, "prepared_poly_extrude_activation", "vibe3d.editing.tools.interactive.prepared_poly_extrude_activation", true),
    Wave19Identity("ID298", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_poly_inset_activation.d", "    \"prepared_poly_inset_activation\",", 5, "prepared_poly_inset_activation", "vibe3d.editing.tools.interactive.prepared_poly_inset_activation", true),
    Wave19Identity("ID299", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_private_state.d", "    \"prepared_private_state\",", 5, "prepared_private_state", "vibe3d.editing.tools.interactive.prepared_private_state", true),
    Wave19Identity("ID300", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_radial_array_transition.d", "    \"prepared_radial_array_transition\",", 5, "prepared_radial_array_transition", "vibe3d.editing.tools.interactive.prepared_radial_array_transition", true),
    Wave19Identity("ID301", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_rotate_update.d", "    \"prepared_rotate_update\",", 5, "prepared_rotate_update", "vibe3d.editing.tools.interactive.prepared_rotate_update", true),
    Wave19Identity("ID302", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_scale_update.d", "    \"prepared_scale_update\",", 5, "prepared_scale_update", "vibe3d.editing.tools.interactive.prepared_scale_update", true),
    Wave19Identity("ID303", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_slice_activation.d", "    \"prepared_slice_activation\",", 5, "prepared_slice_activation", "vibe3d.editing.tools.interactive.prepared_slice_activation", true),
    Wave19Identity("ID304", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_slice_deactivate.d", "    \"prepared_slice_deactivate\",", 5, "prepared_slice_deactivate", "vibe3d.editing.tools.interactive.prepared_slice_deactivate", true),
    Wave19Identity("ID305", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_smooth_shift_activation.d", "    \"prepared_smooth_shift_activation\",", 5, "prepared_smooth_shift_activation", "vibe3d.editing.tools.interactive.prepared_smooth_shift_activation", true),
    Wave19Identity("ID306", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_stroke_extrude_activation.d", "    \"prepared_stroke_extrude_activation\",", 5, "prepared_stroke_extrude_activation", "vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation", true),
    Wave19Identity("ID307", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_tack_activation.d", "    \"prepared_tack_activation\",", 5, "prepared_tack_activation", "vibe3d.editing.tools.interactive.prepared_tack_activation", true),
    Wave19Identity("ID308", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "edit-contracts", "packages/edit-contracts/source/prepared_tool_effect.d", "    \"prepared_tool_effect\",", 5, "prepared_tool_effect", "vibe3d.editing.contracts.prepared_tool_effect", true),
    Wave19Identity("ID309", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_activation.d", "    \"prepared_topology_pen_activation\",", 5, "prepared_topology_pen_activation", "vibe3d.editing.tools.interactive.prepared_topology_pen_activation", true),
    Wave19Identity("ID310", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_deactivate.d", "    \"prepared_topology_pen_deactivate\",", 5, "prepared_topology_pen_deactivate", "vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate", true),
    Wave19Identity("ID311", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_topology_pen_update.d", "    \"prepared_topology_pen_update\",", 5, "prepared_topology_pen_update", "vibe3d.editing.tools.interactive.prepared_topology_pen_update", true),
    Wave19Identity("ID312", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_transform_activation.d", "    \"prepared_transform_activation\",", 5, "prepared_transform_activation", "vibe3d.editing.tools.interactive.prepared_transform_activation", true),
    Wave19Identity("ID313", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_transform_product_activation.d", "    \"prepared_transform_product_activation\",", 5, "prepared_transform_product_activation", "vibe3d.editing.tools.interactive.prepared_transform_product_activation", true),
    Wave19Identity("ID314", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_vertex_bevel_activation.d", "    \"prepared_vertex_bevel_activation\",", 5, "prepared_vertex_bevel_activation", "vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation", true),
    Wave19Identity("ID315", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_vertex_extrude_activation.d", "    \"prepared_vertex_extrude_activation\",", 5, "prepared_vertex_extrude_activation", "vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation", true),
    Wave19Identity("ID316", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_vertex_merge_activation.d", "    \"prepared_vertex_merge_activation\",", 5, "prepared_vertex_merge_activation", "vibe3d.editing.tools.interactive.prepared_vertex_merge_activation", true),
    Wave19Identity("ID317", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_activation_session.d", "    \"prepared_xfrm_activation_session\",", 5, "prepared_xfrm_activation_session", "vibe3d.editing.tools.interactive.prepared_xfrm_activation_session", true),
    Wave19Identity("ID318", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_replay.d", "    \"prepared_xfrm_replay\",", 5, "prepared_xfrm_replay", "vibe3d.editing.tools.interactive.prepared_xfrm_replay", true),
    Wave19Identity("ID319", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_slot_poll.d", "    \"prepared_xfrm_slot_poll\",", 5, "prepared_xfrm_slot_poll", "vibe3d.editing.tools.interactive.prepared_xfrm_slot_poll", true),
    Wave19Identity("ID320", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_boundary.d", "    \"prepared_xfrm_update_boundary\",", 5, "prepared_xfrm_update_boundary", "vibe3d.editing.tools.interactive.prepared_xfrm_update_boundary", true),
    Wave19Identity("ID321", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_edit_close.d", "    \"prepared_xfrm_update_edit_close\",", 5, "prepared_xfrm_update_edit_close", "vibe3d.editing.tools.interactive.prepared_xfrm_update_edit_close", true),
    Wave19Identity("ID322", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/prepared_xfrm_update_tail.d", "    \"prepared_xfrm_update_tail\",", 5, "prepared_xfrm_update_tail", "vibe3d.editing.tools.interactive.prepared_xfrm_update_tail", true),
    Wave19Identity("ID323", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/snap_render.d", "    \"snap_render\",", 5, "snap_render", "vibe3d.editing.tools.interactive.snap_render", true),
    Wave19Identity("ID324", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "interactive-tools", "packages/interactive-tools/source/handles/shapes.d", "    \"handles.shapes.PreparedClickPointResourceToken\",", 5, "handles.shapes", "vibe3d.editing.tools.interactive.handles.shapes", true),
    Wave19Identity("ID325", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "viewport-gpu", "packages/viewport-gpu/source/mesh_gpu.d", "    \"mesh_gpu.PreparedGpuResourceToken\",", 5, "mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu", true),
    Wave19Identity("ID326", "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d", "edit-contracts", "packages/edit-contracts/source/prepared_tool_effect.d", "    \"prepared_tool_effect.PreparedSubjectToken\",", 5, "prepared_tool_effect", "vibe3d.editing.contracts.prepared_tool_effect", true),
    Wave19Identity("ID327", "packages/render-backends/tests/source/render_backends_population_test.d", "render-backends", "packages/render-backends/source/render/backend_bridge.d", "    immutable string[] expected = [\"render.backend_bridge\", \"render.cycles_backend\", \"render.render_diff\", \"render.rpr_backend\"];", 36, "render.backend_bridge", "vibe3d.render.backends.render.backend_bridge", true),
    Wave19Identity("ID328", "packages/render-backends/tests/source/render_backends_population_test.d", "render-backends", "packages/render-backends/source/render/cycles_backend.d", "    immutable string[] expected = [\"render.backend_bridge\", \"render.cycles_backend\", \"render.render_diff\", \"render.rpr_backend\"];", 61, "render.cycles_backend", "vibe3d.render.backends.render.cycles_backend", true),
    Wave19Identity("ID329", "packages/render-backends/tests/source/render_backends_population_test.d", "render-backends", "packages/render-backends/source/render/render_diff.d", "    immutable string[] expected = [\"render.backend_bridge\", \"render.cycles_backend\", \"render.render_diff\", \"render.rpr_backend\"];", 86, "render.render_diff", "vibe3d.render.backends.render.render_diff", true),
    Wave19Identity("ID330", "packages/render-backends/tests/source/render_backends_population_test.d", "render-backends", "packages/render-backends/source/render/rpr_backend.d", "    immutable string[] expected = [\"render.backend_bridge\", \"render.cycles_backend\", \"render.render_diff\", \"render.rpr_backend\"];", 108, "render.rpr_backend", "vibe3d.render.backends.render.rpr_backend", true),
    Wave19Identity("ID331", "packages/render-model/tests/source/render_model_population_test.d", "render-model", "packages/render-model/source/render/backend.d", "    immutable string[] expected = [\"render.backend\", \"render.scene\"];", 36, "render.backend", "vibe3d.render.model.render.backend", true),
    Wave19Identity("ID332", "packages/render-model/tests/source/render_model_population_test.d", "render-model", "packages/render-model/source/render/scene.d", "    immutable string[] expected = [\"render.backend\", \"render.scene\"];", 54, "render.scene", "vibe3d.render.model.render.scene", true),
    Wave19Identity("ID333", "packages/scene-query/tests/source/tests/unit/scene_query_population_test.d", "scene-query", "packages/scene-query/source/bvh_pick.d", "        \"bvh_pick\",", 9, "bvh_pick", "vibe3d.editing.selection.scene_query.bvh_pick", true),
    Wave19Identity("ID334", "packages/scene-query/tests/source/tests/unit/scene_query_population_test.d", "scene-query", "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d", "        \"tests.unit.bvh_pick_test\",", 9, "tests.unit.bvh_pick_test", "vibe3d.editing.selection.scene_query.tests.unit.bvh_pick_test", true),
    Wave19Identity("ID335", "packages/scene-query/tests/source/tests/unit/scene_query_population_test.d", "scene-query", "packages/scene-query/tests/source/tests/unit/scene_query_population_test.d", "        \"tests.unit.scene_query_population_test\",", 9, "tests.unit.scene_query_population_test", "vibe3d.editing.selection.scene_query.tests.unit.scene_query_population_test", true),
    Wave19Identity("ID336", "packages/selection-model/tests/source/tests/unit/selection_model_population_test.d", "selection-model", "packages/selection-model/tests/source/tests/unit/selection_model_population_test.d", "        \"tests.unit.selection_model_population_test\",", 9, "tests.unit.selection_model_population_test", "vibe3d.editing.selection.model.tests.unit.selection_model_population_test", true),
    Wave19Identity("ID337", "packages/selection-model/tests/source/tests/unit/selection_model_population_test.d", "selection-model", "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d", "        \"tests.unit.selection_product_source_public_test\",", 9, "tests.unit.selection_product_source_public_test", "vibe3d.editing.selection.model.tests.unit.selection_product_source_public_test", true),
    Wave19Identity("ID338", "packages/selection-model/tests/source/tests/unit/selection_model_population_test.d", "selection-model", "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d", "        \"tests.unit.selection_projection_algorithm_cells_test\",", 9, "tests.unit.selection_projection_algorithm_cells_test", "vibe3d.editing.selection.model.tests.unit.selection_projection_algorithm_cells_test", true),
    Wave19Identity("ID339", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "viewport-gpu", "packages/viewport-gpu/source/gl_thread_guard.d", "        \"gl_thread_guard\",", 9, "gl_thread_guard", "vibe3d.viewport.gpu.gl_thread_guard", true),
    Wave19Identity("ID340", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "viewport-gpu", "packages/viewport-gpu/source/mesh_gpu.d", "        \"mesh_gpu\",", 9, "mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu", true),
    Wave19Identity("ID341", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_key_fold_test.d", "        \"tests.unit.subpatch_key_fold_test\",", 9, "tests.unit.subpatch_key_fold_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_key_fold_test", true),
    Wave19Identity("ID342", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_level_policy_test.d", "        \"tests.unit.subpatch_level_policy_test\",", 9, "tests.unit.subpatch_level_policy_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_level_policy_test", true),
    Wave19Identity("ID343", "packages/subpatch-preview/tests/source/tests/unit/subpatch_preview_population_test.d", "subpatch-preview", "packages/subpatch-preview/tests/source/tests/unit/subpatch_osd_test.d", "        \"tests.unit.subpatch_osd_test\",", 9, "tests.unit.subpatch_osd_test", "vibe3d.viewport.subpatch.tests.unit.subpatch_osd_test", true),
    Wave19Identity("ID344", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/tests/source/tests/unit/session_mesh_key_stamp_as_test.d", "        \"tests.unit.session_mesh_key_stamp_as_test\",", 9, "tests.unit.session_mesh_key_stamp_as_test", "vibe3d.editing.tools.state.tests.unit.session_mesh_key_stamp_as_test", true),
    Wave19Identity("ID345", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "        \"tests.unit.tool_state_population_test\",", 9, "tests.unit.tool_state_population_test", "vibe3d.editing.tools.state.tests.unit.tool_state_population_test", true),
    Wave19Identity("ID346", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/tests/source/tests/unit/tools/common/session_mesh_key_test.d", "        \"tests.unit.tools.common.session_mesh_key_test\",", 9, "tests.unit.tools.common.session_mesh_key_test", "vibe3d.editing.tools.state.tests.unit.tools.common.session_mesh_key_test", true),
    Wave19Identity("ID347", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/tests/source/tests/unit/tools/edit/preview_rebuild_test.d", "        \"tests.unit.tools.edit.preview_rebuild_test\",", 9, "tests.unit.tools.edit.preview_rebuild_test", "vibe3d.editing.tools.state.tests.unit.tools.edit.preview_rebuild_test", true),
    Wave19Identity("ID348", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/source/tools/common/session_mesh_key.d", "        \"tools.common.session_mesh_key\",", 9, "tools.common.session_mesh_key", "vibe3d.editing.tools.state.tools.common.session_mesh_key", true),
    Wave19Identity("ID349", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/source/tools/edit/preview_rebuild.d", "        \"tools.edit.preview_rebuild\",", 9, "tools.edit.preview_rebuild", "vibe3d.editing.tools.state.tools.edit.preview_rebuild", true),
    Wave19Identity("ID350", "packages/tool-state/tests/source/tests/unit/tool_state_population_test.d", "tool-state", "packages/tool-state/source/tools/common/session_mesh_key.d", "            if (name == \"tools.common.session_mesh_key\")", 25, "tools.common.session_mesh_key", "vibe3d.editing.tools.state.tools.common.session_mesh_key", true),
    Wave19Identity("ID351", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/ortho_relocate_prior_test.d", "        \"tests.unit.ortho_relocate_prior_test\",", 9, "tests.unit.ortho_relocate_prior_test", "vibe3d.editing.tools.transform.tests.unit.ortho_relocate_prior_test", true),
    Wave19Identity("ID352", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/arcball_regression_test.d", "        \"tests.unit.tools.transform.arcball_regression_test\",", 9, "tests.unit.tools.transform.arcball_regression_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_regression_test", true),
    Wave19Identity("ID353", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/arcball_test.d", "        \"tests.unit.tools.transform.arcball_test\",", 9, "tests.unit.tools.transform.arcball_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_test", true),
    Wave19Identity("ID354", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/item_xform_kernels_test.d", "        \"tests.unit.tools.transform.item_xform_kernels_test\",", 9, "tests.unit.tools.transform.item_xform_kernels_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_kernels_test", true),
    Wave19Identity("ID355", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/item_xform_regression_test.d", "        \"tests.unit.tools.transform.item_xform_regression_test\",", 9, "tests.unit.tools.transform.item_xform_regression_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_regression_test", true),
    Wave19Identity("ID356", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/morph_route_test.d", "        \"tests.unit.tools.transform.morph_route_test\",", 9, "tests.unit.tools.transform.morph_route_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.morph_route_test", true),
    Wave19Identity("ID357", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/scale_input_test.d", "        \"tests.unit.tools.transform.scale_input_test\",", 9, "tests.unit.tools.transform.scale_input_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.scale_input_test", true),
    Wave19Identity("ID358", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tests/unit/tools/transform/xform_kernels_test.d", "        \"tests.unit.tools.transform.xform_kernels_test\",", 9, "tests.unit.tools.transform.xform_kernels_test", "vibe3d.editing.tools.transform.tests.unit.tools.transform.xform_kernels_test", true),
    Wave19Identity("ID359", "packages/transform-ops/tests/source/tests/unit/tools/transform/transform_ops_population_test.d", "transform-ops", "packages/transform-ops/tests/source/tools/transform/relocate_plane_test.d", "        \"tools.transform.relocate_plane_test\",", 9, "tools.transform.relocate_plane_test", "vibe3d.editing.tools.transform.tools.transform.relocate_plane_test", true),
    Wave19Identity("ID360", "packages/viewport-gpu/tests/source/tests/unit/viewport_gpu_population_test.d", "viewport-gpu", "packages/viewport-gpu/source/gl_thread_guard.d", "        \"gl_thread_guard\",", 9, "gl_thread_guard", "vibe3d.viewport.gpu.gl_thread_guard", true),
    Wave19Identity("ID361", "packages/viewport-gpu/tests/source/tests/unit/viewport_gpu_population_test.d", "viewport-gpu", "packages/viewport-gpu/source/mesh_gpu.d", "        \"mesh_gpu\",", 9, "mesh_gpu", "vibe3d.viewport.gpu.mesh_gpu", true),
    Wave19Identity("ID362", "packages/viewport-gpu/tests/source/tests/unit/viewport_gpu_population_test.d", "viewport-gpu", "packages/viewport-gpu/tests/source/tests/unit/viewport_env_test.d", "        \"tests.unit.viewport_env_test\",", 9, "tests.unit.viewport_env_test", "vibe3d.viewport.gpu.tests.unit.viewport_env_test", true),
    Wave19Identity("ID363", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "            command.g_testMode = true;  // gate testMode-only commands (re-eval D5)", 12, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID364", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        prefsActive = !command.g_testMode", 23, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID365", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "    } else if (!command.g_testMode) {", 16, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID366", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "    auto visFlag = (command.g_testMode && !visibleTest)", 20, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID367", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        (perfMode || (command.g_testMode && !visibleTest)) ? 0 : 1);", 22, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID368", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        &g_prefs, command.g_testMode,", 18, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID369", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "    if (command.g_testMode) {", 8, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID370", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "    if (!command.g_testMode) {", 9, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID371", "source/app.d", "editor-ui", "packages/editor-ui/source/forms_render.d", "    auto formsPanel    = new forms_render.FormsPanel();", 29, "forms_render", "vibe3d.ui.editor.forms_render", false),
    Wave19Identity("ID372", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "    auto aiExplore = (command.g_testMode || playbackMode)", 22, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID373", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        string shortcutsPath = command.g_testMode", 31, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID374", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (command.g_testMode) return;", 12, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID375", "source/app.d", "desktop", "source/editor_app.d", "        drawSidePanel(editor_app.bindPanelHostRoles!(SidePanelRole)(app), actionMenuRoles);", 22, "editor_app", "vibe3d.apps.desktop.editor_app", false),
    Wave19Identity("ID376", "source/app.d", "desktop", "source/editor_app.d", "        drawTabPanel(editor_app.bindPanelHostRoles!(TabPanelRole)(app));", 21, "editor_app", "vibe3d.apps.desktop.editor_app", false),
    Wave19Identity("ID377", "source/app.d", "desktop", "source/editor_app.d", "        drawAi3dModal(editor_app.bindPanelHostRoles!(Ai3dPanelRole)(app));", 22, "editor_app", "vibe3d.apps.desktop.editor_app", false),
    Wave19Identity("ID378", "source/app.d", "desktop", "source/editor_app.d", "        drawQuitGuardModal(guardModalState, testMode, editor_app.makeGuardModalRole(guardController));", 54, "editor_app", "vibe3d.apps.desktop.editor_app", false),
    Wave19Identity("ID379", "source/app.d", "desktop", "source/editor_app.d", "        drawStatusBar(editor_app.bindPanelHostRoles!(StatusPanelRole)(app), actionMenuRoles);", 22, "editor_app", "vibe3d.apps.desktop.editor_app", false),
    Wave19Identity("ID380", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_layerListShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID381", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_imageListShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID382", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_channelsShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID383", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_statisticsShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID384", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_viewportPropsShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID385", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode || g_copilotPanelShown) {", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID386", "source/app.d", "command-runtime", "packages/command-runtime/source/command.d", "            && (!command.g_testMode || g_toolPropertiesShown)) {", 17, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID387", "source/commands/file/load.d", "desktop", "source/commands/file/load.d", "    package FileLoadMode configuredMode() const { return mode; }", 4, "package", "package(vibe3d.apps.desktop.commands.file)", false),
    Wave19Identity("ID388", "source/commands/file/load.d", "desktop", "source/commands/file/load.d", "    package string configuredExtension() const { return singleExt; }", 4, "package", "package(vibe3d.apps.desktop.commands.file)", false),
    Wave19Identity("ID389", "source/commands/file/save.d", "desktop", "source/commands/file/save.d", "    package FileSaveMode configuredMode() const { return mode; }", 4, "package", "package(vibe3d.apps.desktop.commands.file)", false),
    Wave19Identity("ID390", "source/commands/file/save.d", "desktop", "source/commands/file/save.d", "    package string configuredExtension() const { return singleExt; }", 4, "package", "package(vibe3d.apps.desktop.commands.file)", false),
    Wave19Identity("ID391", "source/editor_app.d", "command-runtime", "packages/command-runtime/source/command.d", "    @property ref bool testMode() { return command.g_testMode; }", 43, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID392", "source/http_providers.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (!command.g_testMode) optionalSlots ~= \"injectLayerHandler\";", 13, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID393", "source/http_providers.d", "command-runtime", "packages/command-runtime/source/command.d", "        if (command.g_testMode) {", 12, "command", "vibe3d.editing.commands.runtime.command", false),
    Wave19Identity("ID394", "source/ui/viewport_render.d", "desktop", "source/ui/viewport_render.d", "    package void drawToolOverlays(ToolOverlayInputs inputs, OverlayMode mode,", 4, "package", "package(vibe3d.ui.editor.ui)", false),
    Wave19Identity("ID395", "tests/test_liveness_gate.d", "mesh", "packages/mesh/source/mesh.d", "        \"import mesh;\\n\"", 16, "mesh", "vibe3d.mesh.core.mesh", true),
    Wave19Identity("ID396", "tests/unit/commands/tool/tool_host_read_view_test.d", "interactive-tools", "packages/interactive-tools/source/commands/tool/host.d", "    static assert([__traits(allMembers, commands.tool.host)]", 40, "commands.tool.host", "vibe3d.editing.tools.interactive.commands.tool.host", false),
    Wave19Identity("ID397", "tests/unit/edge_crease_weight_test.d", "mesh", "packages/mesh/source/mesh.d", "    import mesh : beginDeliveryBatchGlobal, endDeliveryBatchGlobal;", 11, "mesh", "vibe3d.mesh.core.mesh", true),
    Wave19Identity("ID398", "tests/unit/headless_edit_lifecycle_test.d", "command-runtime", "packages/command-runtime/source/command_history.d", "    return rig.executor.applyOrRefire(c, command_history.RecordMode.Record, null);", 41, "command_history", "vibe3d.editing.commands.runtime.command_history", false),
    Wave19Identity("ID399", "tests/unit/io/file_model_test.d", "platform-file", "packages/platform-file/source/io/file_dialog.d", "static assert(__traits(isSame, browserFileModel, io.file_dialog.browserFileModel));", 49, "io.file_dialog", "vibe3d.platform.file.io.file_dialog", false),
    Wave19Identity("ID400", "tests/unit/io/file_model_test.d", "platform-file", "packages/platform-file/source/io/file_dialog.d", "                       io.file_dialog.selectBrowserBackendForTest));", 23, "io.file_dialog", "vibe3d.platform.file.io.file_dialog", false),
    Wave19Identity("ID401", "tests/unit/io/file_model_test.d", "platform-file", "packages/platform-file/source/io/file_dialog.d", "    io.file_dialog.selectBrowserBackendForTest(false);", 4, "io.file_dialog", "vibe3d.platform.file.io.file_dialog", false),
    Wave19Identity("ID402", "tests/unit/io/file_model_test.d", "platform-file", "packages/platform-file/source/io/file_dialog.d", "    io.file_dialog.selectBrowserBackendForTest(true);", 4, "io.file_dialog", "vibe3d.platform.file.io.file_dialog", false),
    Wave19Identity("ID403", "tests/unit/io/file_model_test.d", "platform-file", "packages/platform-file/source/io/file_dialog.d", "    assert(!io.file_dialog.browserFileModel(), \"file model lower setter shares storage\");", 12, "io.file_dialog", "vibe3d.platform.file.io.file_dialog", false),
    Wave19Identity("ID404", "tests/unit/mesh_thicken_surface_test.d", "mesh-ops", "packages/mesh-ops/source/mesh_ops/thicken.d", "mixin MeshByValueGate!(mesh_ops.thicken);", 23, "mesh_ops.thicken", "vibe3d.mesh.ops.mesh_ops.thicken", false),
    Wave19Identity("ID405", "tests/unit/root_test_package_population_test.d", "mesh", "packages/mesh/source/mesh.d", "    enum coreCells = __traits(getUnitTests, mesh).length;", 44, "mesh", "vibe3d.mesh.core.mesh", false),
    Wave19Identity("ID406", "tests/unit/root_test_package_population_test.d", "mesh", "packages/mesh/source/mesh.d", "        static foreach (cell; __traits(getUnitTests, mesh)) {", 53, "mesh", "vibe3d.mesh.core.mesh", false),
    Wave19Identity("ID407", "tests/unit/symmetry_test.d", "transform-ops", "packages/transform-ops/source/tools/transform/cluster_values.d", "    static assert(is(TransformTool.ClusterPivots == tools.transform.cluster_values.ClusterPivots));", 52, "tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values", false),
    Wave19Identity("ID408", "tests/unit/symmetry_test.d", "transform-ops", "packages/transform-ops/source/tools/transform/cluster_values.d", "    static assert(is(TransformTool.ClusterAxes == tools.transform.cluster_values.ClusterAxes));", 50, "tools.transform.cluster_values", "vibe3d.editing.tools.transform.tools.transform.cluster_values", false),
    Wave19Identity("ID409", "tests/unit/tool_attr_bounds_test.d", "pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/constrain.d", "private final class RefusingOffset : toolpipe.stages.constrain.ConstrainStage {", 37, "toolpipe.stages.constrain", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain", false),
    Wave19Identity("ID410", "tests/unit/tool_attr_bounds_test.d", "pipe-runtime", "packages/pipe-runtime/source/toolpipe/stage.d", "private final class AxisStageProbe : toolpipe.stage.Stage {", 37, "toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage", false),
    Wave19Identity("ID411", "tests/unit/tool_attr_bounds_test.d", "pipe-runtime", "packages/pipe-runtime/source/toolpipe/stage.d", "    override ubyte ordinal() const { return toolpipe.stage.ordCons; }", 44, "toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage", false),
    Wave19Identity("ID412", "tests/unit/tool_attr_bounds_test.d", "pipe-runtime", "packages/pipe-runtime/source/toolpipe/stage.d", "    override toolpipe.stage.TaskCode taskCode() const pure nothrow @nogc @safe {", 13, "toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage", false),
    Wave19Identity("ID413", "tests/unit/tool_attr_bounds_test.d", "pipe-runtime", "packages/pipe-runtime/source/toolpipe/stage.d", "        return toolpipe.stage.TaskCode.Cons;", 15, "toolpipe.stage", "vibe3d.editing.pipeline.runtime.toolpipe.stage", false),
    Wave19Identity("ID414", "tests/unit/tool_single_operation_census_test.d", "mesh-ops", "packages/mesh-ops/source/mesh_ops/cut.d", "    static foreach (m; __traits(allMembers, mesh_ops.cut))", 44, "mesh_ops.cut", "vibe3d.mesh.ops.mesh_ops.cut", false),
    Wave19Identity("ID415", "tests/unit/tools/alignment/radial_nsided_original_test.d", "interactive-tools", "packages/interactive-tools/source/tool.d", "private void radialAttrs(tool.Tool t, JSONValue cell) {", 25, "tool", "vibe3d.editing.tools.interactive.tool", false),
    Wave19Identity("ID416", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert([__traits(allMembers, ui.action_menu)] == [", 36, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID417", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert([__traits(allMembers, ui.action_menu.ActionMenuRead)]", 36, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID418", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert([__traits(allMembers, ui.action_menu.ActionMenuActions)]", 36, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID419", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert([__traits(allMembers, ui.action_menu.ActionMenuRoles)]", 36, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID420", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert(!__traits(compiles, new ui.action_menu.ActionMenuRead()),", 38, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID421", "tests/unit/ui/action_menu_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "static assert(__traits(compiles, (ui.action_menu.ActionMenuActions actions) {", 34, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", false),
    Wave19Identity("ID422", "tests/unit/ui/history_panel_test.d", "interactive-tools", "packages/interactive-tools/source/tool.d", "private final class HistoryPanelModelTool : Tool, tool.TopologyStepClient {", 50, "tool", "vibe3d.editing.tools.interactive.tool", false),
    Wave19Identity("ID423", "tests/unit/ui/history_panel_test.d", "mesh-snapshot", "packages/mesh-snapshot/source/snapshot.d", "    override snapshot.MeshSnapshot topologyStepBasis() { return snapshot.MeshSnapshot.capture(*mesh); }", 13, "snapshot", "vibe3d.mesh.snapshot.snapshot", false),
    Wave19Identity("ID424", "tests/unit/ui/history_panel_test.d", "mesh-snapshot", "packages/mesh-snapshot/source/snapshot.d", "    override snapshot.MeshSnapshot topologyStepBasis() { return snapshot.MeshSnapshot.capture(*mesh); }", 64, "snapshot", "vibe3d.mesh.snapshot.snapshot", false),
    Wave19Identity("ID425", "tests/unit/ui/history_panel_test.d", "mesh-snapshot", "packages/mesh-snapshot/source/snapshot.d", "    override void rebaseTopologyStep(snapshot.MeshSnapshot) { ++rebases; }", 37, "snapshot", "vibe3d.mesh.snapshot.snapshot", false),
    Wave19Identity("ID426", "tests/unit/ui/history_panel_test.d", "interactive-tools", "packages/interactive-tools/source/tool.d", "    override void restoreTopologyStep(in tool.AttrImage, snapshot.MeshSnapshot) { assert(false); }", 41, "tool", "vibe3d.editing.tools.interactive.tool", false),
    Wave19Identity("ID427", "tests/unit/ui/history_panel_test.d", "mesh-snapshot", "packages/mesh-snapshot/source/snapshot.d", "    override void restoreTopologyStep(in tool.AttrImage, snapshot.MeshSnapshot) { assert(false); }", 57, "snapshot", "vibe3d.mesh.snapshot.snapshot", false),
    Wave19Identity("ID428", "tests/unit/ui/layer_list_panel_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/item_rows.d", "static assert(typeof(__traits(getMember, ui.item_rows, \"rowParentOf\")).stringof", 41, "ui.item_rows", "vibe3d.ui.editor.ui.item_rows", false),
    Wave19Identity("ID429", "tests/unit/ui/layer_list_panel_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/item_rows.d", "static assert(typeof(__traits(getMember, ui.item_rows, \"roleOf\")).stringof", 41, "ui.item_rows", "vibe3d.ui.editor.ui.item_rows", false),
    Wave19Identity("ID430", "tests/unit/ui/tool_attr_bounds_panels_test.d", "pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/constrain.d", "private final class FreeOffset : toolpipe.stages.constrain.ConstrainStage {", 33, "toolpipe.stages.constrain", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain", false),
    Wave19Identity("ID431", "tests/unit/ui/tool_attr_bounds_panels_test.d", "pipe-evaluation", "packages/pipe-evaluation/source/toolpipe/stages/constrain.d", "private final class OffsetHints : toolpipe.stages.constrain.ConstrainStage {", 34, "toolpipe.stages.constrain", "vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain", false),
    Wave19Identity("ID432", "tests/unit/ui/tool_properties_panel_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/tool_properties_panel.d", "static assert([__traits(allMembers, ui.tool_properties_panel)] == [", 36, "ui.tool_properties_panel", "vibe3d.ui.editor.ui.tool_properties_panel", false),
    Wave19Identity("ID433", "tests/unit/ui/tool_properties_panel_roles_test.d", "editor-ui", "packages/editor-ui/source/ui/tool_properties_panel.d", "        ~ memberList!ui.tool_properties_panel ~ memberPinSuffix);", 21, "ui.tool_properties_panel", "vibe3d.ui.editor.ui.tool_properties_panel", false),
    Wave19Identity("ID452", "tests/unit/version_gate_census_ai3d_remesh_test.d", "desktop", "source/commands/file/load.d", "import commands.file.load : FileLoad;", 7, "commands.file.load", "vibe3d.apps.desktop.commands.file.load", true),
    Wave19Identity("ID453", "tests/unit/version_gate_census_ai3d_remesh_test.d", "desktop", "source/commands/file/save.d", "import commands.file.save : FileSave;", 7, "commands.file.save", "vibe3d.apps.desktop.commands.file.save", true),
    Wave19Identity("ID434", "tests/unit/version_gate_census_ai3d_remesh_test.d", "document-model", "packages/document-model/source/document.d", "import document : Document;", 7, "document", "vibe3d.documents.model.document", true),
    Wave19Identity("ID435", "tests/unit/version_gate_census_ai3d_remesh_test.d", "edit-contracts", "packages/edit-contracts/source/editmode.d", "import editmode : EditMode;", 7, "editmode", "vibe3d.editing.contracts.editmode", true),
    Wave19Identity("ID436", "tests/unit/version_gate_census_ai3d_remesh_test.d", "http-runtime", "packages/http-runtime/source/http_server.d", "import http_server : HttpServer, InProcessHttpTransport;", 7, "http_server", "vibe3d.runtime.http.http_server", true),
    Wave19Identity("ID437", "tests/unit/version_gate_census_ai3d_remesh_test.d", "interchange", "packages/interchange/source/io/assimp_runtime.d", "import io.assimp_runtime : initAssimp, isAssimpAvailable, shutdownAssimp;", 7, "io.assimp_runtime", "vibe3d.documents.interchange.io.assimp_runtime", true),
    Wave19Identity("ID438", "tests/unit/version_gate_census_ai3d_remesh_test.d", "interchange", "packages/interchange/source/io/scene_export.d", "import io.scene_export : exportDocumentViaAssimp, exportViaAssimp;", 7, "io.scene_export", "vibe3d.documents.interchange.io.scene_export", true),
    Wave19Identity("ID439", "tests/unit/version_gate_census_ai3d_remesh_test.d", "interchange", "packages/interchange/source/io/scene_import.d", "import io.scene_import : importViaAssimp;", 7, "io.scene_import", "vibe3d.documents.interchange.io.scene_import", true),
    Wave19Identity("ID440", "tests/unit/version_gate_census_ai3d_remesh_test.d", "interchange", "packages/interchange/source/io/scene_ir.d", "import io.scene_ir : ImportedScene;", 7, "io.scene_ir", "vibe3d.documents.interchange.io.scene_ir", true),
    Wave19Identity("ID441", "tests/unit/version_gate_census_ai3d_remesh_test.d", "mesh", "packages/mesh/source/mesh.d", "import mesh : makeCube, Mesh;", 7, "mesh", "vibe3d.mesh.core.mesh", true),
    Wave19Identity("ID442", "tests/unit/version_gate_census_ai3d_remesh_test.d", "parallel", "util/parallel/source/tsan_annotate.d", "import tsan_annotate : parallelForWithCompletion;", 7, "tsan_annotate", "vibe3d.util.parallel.tsan_annotate", true),
    Wave19Identity("ID443", "tests/unit/version_gate_census_ai3d_remesh_test.d", "editor-ui", "packages/editor-ui/source/ui/action_menu.d", "import ui.action_menu : popupActionNeedsAssimp;", 7, "ui.action_menu", "vibe3d.ui.editor.ui.action_menu", true),
    Wave19Identity("ID444", "tests/unit/version_gate_census_ai3d_remesh_test.d", "camera-model", "packages/camera-model/source/view.d", "import view : View;", 7, "view", "vibe3d.viewport.camera.view", true),
    Wave19Identity("ID445", "tests/unit/webgl2_shader_sources_test.d", "viewport-gpu", "packages/viewport-gpu/source/shader.d", "        ~ \"import shader; import gpu_select;\\n\";", 18, "shader", "vibe3d.viewport.gpu.shader", true),
    Wave19Identity("ID446", "tests/unit/webgl2_shader_sources_test.d", "viewport-gpu", "packages/viewport-gpu/source/gpu_select.d", "        ~ \"import shader; import gpu_select;\\n\";", 33, "gpu_select", "vibe3d.viewport.gpu.gpu_select", true),
    Wave19Identity("ID447", "tests/unit/workplane_frame_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "static assert(![__traits(allMembers, tools.create.create_common)].canFind(\"currentWorkplaneFrame\"));", 37, "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common", false),
    Wave19Identity("ID448", "tests/unit/workplane_frame_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "static assert(![__traits(allMembers, tools.create.create_common)].canFind(\"primitiveParameterFrame\"));", 37, "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common", false),
    Wave19Identity("ID449", "tests/unit/workplane_frame_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "static assert([__traits(allMembers, tools.create.create_common)].canFind(\"primitivePlacementFrame\"));", 36, "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common", false),
    Wave19Identity("ID450", "tests/unit/workplane_frame_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "static assert([__traits(allMembers, tools.create.create_common)].canFind(\"viewPrincipalAxis\"));", 36, "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common", false),
    Wave19Identity("ID451", "tests/unit/workplane_frame_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/create/create_common.d", "static assert([__traits(allMembers, tools.create.create_common)].canFind(\"axisUnit\"));", 36, "tools.create.create_common", "vibe3d.editing.tools.interactive.tools.create.create_common", false),
    Wave19Identity("ID454", "packages/mesh-ops/tests/source/tests/unit/mesh_edge_slice_gate_test.d", "mesh-ops", "packages/mesh-ops/source/mesh_edge_slice.d", "mixin MeshByValueGate!(mesh_edge_slice);", 23, "mesh_edge_slice", "vibe3d.mesh.ops.mesh_edge_slice", false),
    Wave19Identity("ID455", "tests/unit/handle_draw_funnel_census_test.d", "interactive-tools", "packages/interactive-tools/source/handles/shapes.d", "private alias kGatedHandleModules = AliasSeq!(\n    handles.shapes, handles.arbiter, tools.transform.scale,\n    handles.arbiter_source_cells);", 51, "handles.shapes", "vibe3d.editing.tools.interactive.handles.shapes", false),
    Wave19Identity("ID456", "tests/unit/handle_draw_funnel_census_test.d", "interactive-tools", "packages/interactive-tools/source/handles/arbiter.d", "private alias kGatedHandleModules = AliasSeq!(\n    handles.shapes, handles.arbiter, tools.transform.scale,\n    handles.arbiter_source_cells);", 67, "handles.arbiter", "vibe3d.editing.tools.interactive.handles.arbiter", false),
    Wave19Identity("ID457", "tests/unit/handle_draw_funnel_census_test.d", "interactive-tools", "packages/interactive-tools/source/tools/transform/scale.d", "private alias kGatedHandleModules = AliasSeq!(\n    handles.shapes, handles.arbiter, tools.transform.scale,\n    handles.arbiter_source_cells);", 84, "tools.transform.scale", "vibe3d.editing.tools.interactive.tools.transform.scale", false),
    Wave19Identity("ID458", "tests/unit/handle_draw_funnel_census_test.d", "interactive-tools", "packages/interactive-tools/tests/source/handles/arbiter_source_cells.d", "private alias kGatedHandleModules = AliasSeq!(\n    handles.shapes, handles.arbiter, tools.transform.scale,\n    handles.arbiter_source_cells);", 111, "handles.arbiter_source_cells", "vibe3d.editing.tools.interactive.handles.arbiter_source_cells", false),
    Wave19Identity("ID459", "tests/unit/mesh_bbox_test.d", "interaction-query", "packages/interaction-query/source/mesh_bbox.d", "mixin MeshByValueGate!(mesh_bbox);", 23, "mesh_bbox", "vibe3d.editing.selection.query.mesh_bbox", false),
    Wave19Identity("ID460", "tests/unit/mesh_visibility_gate_test.d", "interaction-query", "packages/interaction-query/source/mesh_visibility.d", "mixin MeshByValueGate!(mesh_visibility);", 23, "mesh_visibility", "vibe3d.editing.selection.query.mesh_visibility", false),
];
private string wave19IdentityLogicalText(string source, string path, string root = repoRoot) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower, lastIndexOf;
    static bool manifestValidated;
    if (!manifestValidated) {
        string manifest;
        foreach (i, row; wave19Identities) {
            foreach (other; wave19Identities[i + 1 .. $])
                assert(row.id != other.id, "Wave19 duplicate approved identity");
            manifest ~= row.id ~ "\t" ~ row.path ~ "\t" ~ row.owner ~ "\t" ~ row.target ~ "\t"
                ~ row.anchor ~ "\t" ~ row.offset.to!string ~ "\t" ~ row.oldText ~ "\t" ~ row.newText
                ~ "\t" ~ (row.literal ? "1" : "0") ~ "\n";
        }
        assert(wave19Identities.length == 460 && sha256Of(manifest).toHexString.toLower == "32101d7bb8bf913fbf8586377c34ff18a0b21c097eccdf5cd2fb045215dbf7b9",
            "Wave19 frozen approved identity population");
        manifestValidated = true;
    }
    const normal = wave19LogicalPath(path, root), base = wave15Normalize(root);
    const code = blankNonCode(source), literals = blankNonCode(source, true);
    struct Edit { size_t begin, end; string text; }
    Edit[] edits;
    foreach (row; wave19Identities) {
        if (normal != buildPath(base, row.path)) continue;
        const moved = wave19TargetMoved(root, row.target);
        string expected;
        size_t cursor, delta;
        foreach (member; wave19Identities) {
            if (member.path != row.path || member.anchor != row.anchor) continue;
            assert(member.offset >= cursor && member.anchor[member.offset .. member.offset + member.oldText.length] == member.oldText,
                "Wave19 approved original anchor: " ~ member.id);
            const selected = wave19TargetMoved(root, member.target);
            expected ~= row.anchor[cursor .. member.offset] ~ (selected ? member.newText : member.oldText);
            cursor = member.offset + member.oldText.length;
            if (member.offset < row.offset && selected) delta += member.newText.length - member.oldText.length;
        }
        expected ~= row.anchor[cursor .. $];
        const at = source.indexOf(expected);
        assert(at >= 0 && at == source.lastIndexOf(expected), "Wave19 raw approved identity anchor: " ~ row.id);
        const begin = cast(size_t) at;
        assert((begin == 0 || source[begin - 1] == '\n')
            && (begin + expected.length == source.length || source[begin + expected.length] == '\n'),
            "Wave19 approved complete anchor: " ~ row.id);
        const start = begin + row.offset + delta;
        const chosen = moved ? row.newText : row.oldText;
        const end = start + chosen.length;
        assert(source[start .. end] == chosen
            && (row.literal ? literals[start .. end].strip.length == 0 : code[start .. end] == chosen),
            "Wave19 raw approved identity lexical kind: " ~ row.id);
        if (moved) edits ~= Edit(start, end, row.oldText);
    }
    import std.algorithm : sort;
    edits.sort!((a, b) => a.begin < b.begin);
    string result;
    size_t cursor;
    foreach (edit; edits) {
        assert(edit.begin >= cursor, "Wave19 overlapping approved identity custody");
        result ~= source[cursor .. edit.begin] ~ edit.text;
        cursor = edit.end;
    }
    return result ~ source[cursor .. $];
}

private struct Wave19Locator { string id, path, owner, oldText, newText; }
private immutable Wave19Locator[] wave19Locators = [
    Wave19Locator("L03-retopology-root-fixture", "packages/display-policy/tests/source/tests/unit/retopology_display_model_test.d", "display-policy", "buildPath(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))), \"tests\", \"fixtures\",\n              \"retopology_display.json\")", "buildPath(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))))))), \"tests\", \"fixtures\",\n              \"retopology_display.json\")"),
    Wave19Locator("L04-retopology-production-census", "packages/display-policy/tests/source/tests/unit/retopology_display_model_test.d", "display-policy", "buildPath(\n            dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))), \"packages/display-policy/source\",\n            \"display_state.d\")", "buildPath(\n            dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))))))), \"libraries/viewport/display-policy/source/vibe3d/viewport/display_policy\",\n            \"display_state.d\")"),
    Wave19Locator("L01-align-owner-fixture", "packages/alignment-ops/source/tools/alignment/align_kernels.d", "alignment-ops", "    import std.path : buildPath, dirName;\n    enum root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));", "    import std.path : buildNormalizedPath, buildPath, dirName;\n    enum root = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__)))))))));"),
    Wave19Locator("L02-pen-owner-fixture", "packages/creation-ops/tests/source/tests/unit/tools/create/pen_geometry_test.d", "creation-ops", "dirName(dirName(dirName(dirName(dirName(dirName(__FILE__))))))", "dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__)))))))))))"),
    Wave19Locator("L06-ai3d-dev-script", "packages/ai3d-runtime/source/ai3d/worker_manager.d", "ai3d-runtime", "        enum repoRoot = dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__)))));", "        import std.path : buildNormalizedPath;\n        enum repoRoot = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__))))))))));"),
    Wave19Locator("L07-ai3d-worker-module", "packages/ai3d-runtime/tests/source/tests/unit/ai3d/worker_manager_source_public_test.d", "ai3d-runtime", "dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))))", "dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))))))))"),
    Wave19Locator("L05-oblique-root-fixture", "packages/interactive-tools/tests/source/tests/unit/drag_gain_oblique_test.d", "interactive-tools", "buildPath(dirName(__FILE_FULL_PATH__),\n                                   \"../../../../../../tests/fixtures\", kFixtureName)", "buildPath(dirName(__FILE_FULL_PATH__),\n                                   \"../../../../../../../../../../../../tests/fixtures\", kFixtureName)"),
];
private string wave19LocatorLogicalText(string source, string path, string root) {
    assert(wave19Locators.length == 7, "Wave19 frozen seven locator population");
    const logical = wave19LogicalPath(path, root), base = wave15Normalize(root);
    string result = source;
    foreach (row; wave19Locators) {
        if (logical != buildPath(base, row.path)) continue;
        const selected = wave19OwnerMoved(root, row.owner);
        const chosen = selected ? row.newText : row.oldText;
        const at = result.indexOf(chosen);
        assert(at >= 0 && at == result.lastIndexOf(chosen), "Wave19 raw whole locator: " ~ row.id);
        const code = blankNonCode(result);
        const macroName = chosen.indexOf("__FILE_FULL_PATH__") >= 0 ? "__FILE_FULL_PATH__" : "__FILE__";
        const macroAt = cast(size_t)at + cast(size_t)chosen.indexOf(macroName);
        assert(code[macroAt .. macroAt + macroName.length] == macroName,
            "Wave19 raw locator lexical kind: " ~ row.id);
        if (selected) result = result[0 .. at] ~ row.oldText ~ result[at + chosen.length .. $];
    }
    return result;
}

private string wave19ReadCurrent(string path, string root = repoRoot) {
    import std.file : readText;
    return wave19MathLogicalText(wave19IdentityLogicalText(
        wave19LocatorLogicalText(readText(wave19PhysicalPath(wave19LogicalPath(path, root), root)), path, root), path, root));
}

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
    const normal = wave19MathLogicalPath(path);
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.newPath, root))
            return buildPath(root, move.oldPath);
    }
    return normal;
}

public string wave15PhysicalPath(string path) {
    import std.file : exists;
    const normal = wave19MathPhysicalPath(wave19MathLogicalPath(path));
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.oldPath, root)) {
            if (exists(normal)) return normal;
            return wave19PhysicalPath(buildPath(root, move.newPath));
        }
    }
    return normal;
}

public bool wave15Exists(string path) {
    import std.file : exists;
    import std.algorithm : startsWith;
    const logical = wave19MathLogicalPath(path);
    const normal = wave19MathPhysicalPath(logical);
    if (exists(normal)) return true;
    // Nested logical directories need not have one physical directory: their
    // original files remain members after the qualified module relocation.
    const base = wave15Normalize(repoRoot);
    foreach (row; wave19Modules) {
        const child = buildPath(base, row.oldPath);
        if (child.startsWith(logical ~ "/") && exists(wave19PhysicalPath(child))) return true;
    }
    foreach (move; wave15Moves) {
        string root;
        if (wave15Match(normal, move.oldPath, root)
                && exists(wave19PhysicalPath(buildPath(root, move.newPath)))) return true;
        size_t prefix = move.oldPath.length;
        while (prefix) {
            import std.path : dirName;
            const directory = dirName(move.oldPath[0 .. prefix]);
            if (directory == "." || directory.length >= prefix) break;
            prefix = directory.length;
            if (wave15Match(normal, directory, root)
                    && exists(wave19PhysicalPath(buildPath(root, move.newPath)))) return true;
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


private struct Wave15Inverse { string origin; size_t offset; string physical, original; }
private immutable Wave15Inverse[] wave15Inverses = [
    Wave15Inverse("tests/unit/ui/stat_rows_test.d", 407, "module tests.unit.ui.stat_rows_test;\n\n", ""),
    Wave15Inverse("source/ui/availability.d", 11040, "", "unittest {\n    import command  : Command, kNoEditTargetReason;\n    import tool     : Tool;\n    import mesh     : Mesh;\n    import view     : View;\n    import editmode : EditMode;\n"),
    Wave15Inverse("source/ui/availability.d", 11041, "", "    static final class NeedsCmd : Command {\n        private Mesh  _m;\n        private View  _v = new View(0, 0, 1, 1);\n        this() { super(&_m, _v, EditMode.Vertices); }\n        override string name() const { return \"test.needs\"; }\n        override bool needsEditTarget() const { return true; }\n    }\n    static final class FreeCmd : Command {\n        private Mesh  _m;\n        private View  _v = new View(0, 0, 1, 1);\n        this() { super(&_m, _v, EditMode.Vertices); }\n        override string name() const { return \"test.free\"; }\n        override bool needsEditTarget() const { return false; }\n    }\n    static final class NeedsTool : Tool {\n        override bool needsEditTarget() const { return true; }\n    }\n\n    Registry reg;\n    reg.commandNeedsTarget[\"test.needs\"] = true;\n    reg.commandNeedsTarget[\"test.free\"]  = false;\n    reg.toolNeedsTarget[\"test.tool\"]     = true;\n\n    // WITH a target nothing is refused — the both-sides half. An\n    // implementation that greys everything always fails right here.\n    {\n        auto a = Action(ActionKind.command, \"test.needs\");\n        assert(actionRefusal(reg, a, true, \"\") == \"\");\n        auto t = Action(ActionKind.tool, \"test.tool\");\n        assert(actionRefusal(reg, t, true, \"\") == \"\");\n    }\n    // WITHOUT one, only what declared the requirement is refused.\n    {\n        auto need = Action(ActionKind.command, \"test.needs\");\n        assert(actionRefusal(reg, need, false, \"\") == kNoEditTargetReason);\n        auto free = Action(ActionKind.command, \"test.free\");\n        assert(actionRefusal(reg, free, false, \"\") == \"\");\n        auto unknown = Action(ActionKind.command, \"test.never.registered\");\n        assert(actionRefusal(reg, unknown, false, \"\") == \"\");\n    }\n    // The armed tool's own button stays live: pressing it DROPS the tool, and\n    // dropping never needed a target.\n    {\n        auto t = Action(ActionKind.tool, \"test.tool\");\n        assert(actionRefusal(reg, t, false, \"\")          == kNoEditTargetReason);\n        assert(actionRefusal(reg, t, false, \"test.tool\") == \"\");\n        assert(actionRefusal(reg, t, false, \"other\")     == kNoEditTargetReason);\n    }\n    // A script is refused by any one of its lines. This is the ctrl-variant\n    // path (\"Unit Box\" et al. in config/buttons.yaml) — a `kind: script`\n    // button whose one line dispatches a command id — and it has no HTTP\n    // counterpart, because the frame record only carries the variant the\n    // unmodified button shows.\n    {\n        Action s;\n        s.kind = ActionKind.script;\n        s.scriptLines = [\"test.free a:1\", \"test.needs b:2\"];\n        assert(actionRefusal(reg, s, false, \"\") == kNoEditTargetReason,\n            \"a script whose SECOND line would refuse was reported available. \"\n            ~ \"A script is dispatched line by line with no rollback, so a run \"\n            ~ \"that stops partway is not 'mostly available'. Got: '\"\n            ~ actionRefusal(reg, s, false, \"\") ~ \"'\");\n        s.scriptLines = [\"test.free a:1\"];\n        assert(actionRefusal(reg, s, false, \"\") == \"\",\n            \"a script none of whose lines needs a target was refused\");\n    }\n    // A popup always opens.\n    {\n        Action p;\n        p.kind = ActionKind.popup;\n        assert(actionRefusal(reg, p, false, \"\") == \"\");\n    }\n    // The defaults the two base classes declare, off real instances: a\n    // non-Operator command needs nothing, every tool needs a target.\n    assert(!(new FreeCmd()).needsEditTarget());\n    assert((new NeedsCmd()).needsEditTarget());\n    assert((new NeedsTool()).needsEditTarget());\n    assert((new class Tool {}).needsEditTarget(),\n        \"Tool.needsEditTarget() must default to true — a tool binds Mesh* when \"\n        ~ \"it arms\");\n}\n"),
    Wave15Inverse("source/ui/channels_panel.d", 75, "", "import application_command_binding : ApplicationCommandBinding;\n"),
    Wave15Inverse("source/ui/channels_panel.d", 6747, "        void delegate(string, string) interactive, FormsPanel forms,\n", "        ApplicationCommandBinding binding, FormsPanel forms,\n"),
    Wave15Inverse("source/ui/channels_panel.d", 6854, "    assert(interactive !is null && forms !is null);\n", "    assert(binding !is null && forms !is null);\n"),
    Wave15Inverse("source/ui/channels_panel.d", 6973, "        ChannelsActions(interactive, forms),\n", "        ChannelsActions(&binding.dispatchInteractiveUi, forms),\n"),
    Wave15Inverse("source/ui/image_list_panel.d", 77, "", "import application_command_binding : ApplicationCommandBinding;\n"),
    Wave15Inverse("source/ui/image_list_panel.d", 3868, "        ItemRenameDispatch dispatch) {\n    assert(dispatch !is null);\n", "        ApplicationCommandBinding binding) {\n    assert(binding !is null);\n"),
    Wave15Inverse("source/ui/image_list_panel.d", 3995, "        ImageListActions(dispatch), new ImageListPanelState);\n", "        ImageListActions(&binding.dispatchUi), new ImageListPanelState);\n"),
    Wave15Inverse("source/ui/item_rows.d", 19481, "\n", "unittest {\n    // Every cell of the 2x2, because the interesting one is the pair and a\n    // three-case test would not have it.\n    assert(itemClickMode(false, false) == `\"set\"`);\n    assert(itemClickMode(true,  false) == `\"toggle\"`);\n    assert(itemClickMode(false, true)  == `\"range\"`);\n    assert(itemClickMode(true,  true)  == `\"range\"`,   // Shift wins the pair\n        \"Ctrl+Shift must not fall back to toggle — Shift would be inert\");\n}\n"),
    Wave15Inverse("source/ui/layer_list_panel.d", 126, "", "import application_command_binding : ApplicationCommandBinding;\n"),
    Wave15Inverse("source/ui/layer_list_panel.d", 4984, "        ItemRenameDispatch dispatch, ItemRenameDispatch interactive, FormsPanel forms,\n", "        ApplicationCommandBinding binding, FormsPanel forms,\n"),
    Wave15Inverse("source/ui/layer_list_panel.d", 5109, "    assert(dispatch !is null && interactive !is null && forms !is null);\n", "    assert(binding !is null && forms !is null);\n"),
    Wave15Inverse("source/ui/layer_list_panel.d", 5293, "        LayerListActions(owner, dispatch,\n            interactive, forms, state), state);\n", "        LayerListActions(owner, &binding.dispatchUi,\n            &binding.dispatchInteractiveUi, forms, state), state);\n"),
    Wave15Inverse("source/ui/panels.d", 18, "\nimport ui.panel_host_roles : TabPanelRole, SidePanelRole, StatusPanelRole,\n    GuardModalRole, MeshDg;\nversion (web) {} else import ui.panel_host_roles : Ai3dPanelRole;\n", ""),
    Wave15Inverse("source/ui/panels.d", 2671, "\n", "import http_server;\n"),
    Wave15Inverse("source/ui/panels.d", 2787, "\n", "import prefs;\n"),
    Wave15Inverse("source/ui/panels.d", 6066, "\n\n\n\n", "import commands.viewport.fit_selected;\nimport commands.viewport.fit;\nimport commands.file.load;\nimport commands.file.save;\n"),
    Wave15Inverse("source/ui/panels.d", 9121, "\n", "import commands.mesh.magnet : MeshMagnet;\n"),
    Wave15Inverse("source/ui/panels.d", 9183, "\n", "import commands.mesh.morph;\n"),
    Wave15Inverse("source/ui/panels.d", 9881, "\n", "import commands.test_undo_flags : UndoSuppressNoop, UndoForceNoop;\n"),
    Wave15Inverse("source/ui/panels.d", 10523, "\n\n\n", "import commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;\nimport commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;\nimport commands.ui.viewport_props  : UiViewportPropsCommand, g_viewportPropsShown;\n"),
    Wave15Inverse("source/ui/panels.d", 10585, "\n\n\n", "import commands.snap.toggle_type : SnapToggleTypeCommand;\nimport commands.snap.mode        : SnapModeCommand;\nimport commands.ai.toggle    : AiToggleCommand, AiToggleAction;\n"),
    Wave15Inverse("source/ui/panels.d", 10720, "\n\n", "import commands.path.define    : PathDefineCommand;\nimport commands.workplane     : WorkplaneResetCommand, WorkplaneEditCommand,\n                                WorkplaneRotateCommand, WorkplaneOffsetCommand,\n                                WorkplaneAlignToSelectionCommand;\n"),
    Wave15Inverse("source/ui/panels.d", 12404, "\n", "    import commands.ai3d.import_result : Ai3dImportResult;\n"),
    Wave15Inverse("source/ui/panels.d", 12513, "\n", "import commands.mesh.remesh : Remesh, RemeshStart, RemeshOpen;\n"),
    Wave15Inverse("source/ui/panels.d", 12926, "", "import layout_reset_action : LayoutResetAction;\nimport guarded_action_controller : GuardedActionController;\n"),
    Wave15Inverse("source/ui/panels.d", 13990, "", "version (WithAI) import commands.ui.copilot_panel : UiCopilotPanelCommand, g_copilotPanelShown;\n"),
    Wave15Inverse("source/ui/panels.d", 14009, "\n\n\n", "    import commands.copilot.analyze        : CopilotAnalyzeCommand;\n    import commands.copilot.select_finding : CopilotSelectFindingCommand;\n    import commands.copilot.cycle_finding  : CopilotCycleFindingCommand;\n"),
    Wave15Inverse("source/ui/panels.d", 14264, "", "import editor_app : EditorApp, Layout, MeshDg,\n    kAiToggleAvailable, kGenerateAiAvailable,\n    buildItemFrame;\n"),
    Wave15Inverse("source/ui/panels.d", 23749, "void drawTabPanel(TabPanelRole app) {\n", "void drawTabPanel(EditorApp app) {\n"),
    Wave15Inverse("source/ui/panels.d", 32423, "                            void delegate() resetLayout,\n                            float kCavityGainMax, float kCavityDistanceMin,\n                            float kCavityDistanceMax, float kCavityAttenuationMax) {\n", "                            LayoutResetAction resetLayout) {\n"),
    Wave15Inverse("source/ui/panels.d", 32835, "", "    import commands.ui.viewport_props : g_viewportPropsShown;\n"),
    Wave15Inverse("source/ui/panels.d", 41174, "", "            import commands.viewport.display : kCavityGainMax;\n"),
    Wave15Inverse("source/ui/panels.d", 42550, "            static float clampGain(float g, float kCavityGainMax) {   // NaN -> 0\n", "            static float clampGain(float g) {   // NaN -> 0\n"),
    Wave15Inverse("source/ui/panels.d", 43061, "                    format(`{\"screenRidge\":%.6f}`, clampGain(ridge, kCavityGainMax)));\n", "                    format(`{\"screenRidge\":%.6f}`, clampGain(ridge)));\n"),
    Wave15Inverse("source/ui/panels.d", 43486, "                    format(`{\"screenValley\":%.6f}`, clampGain(valley, kCavityGainMax)));\n", "                    format(`{\"screenValley\":%.6f}`, clampGain(valley)));\n"),
    Wave15Inverse("source/ui/panels.d", 43936, "", "                import commands.viewport.display : kCavityDistanceMin, kCavityDistanceMax,\n                    kCavityAttenuationMax;\n"),
    Wave15Inverse("source/ui/panels.d", 52961, "        if (resetPressed) resetLayout();\n", "        if (resetPressed) resetLayout.authorReset();\n"),
    Wave15Inverse("source/ui/panels.d", 54132, "void drawAboutPanel(bool* aboutShown) {\n", "void drawAboutPanel(EditorApp app) {\n    with (app) {\n"),
    Wave15Inverse("source/ui/panels.d", 54212, "", "    import commands.ui.about : g_aboutShown;\n"),
    Wave15Inverse("source/ui/panels.d", 54383, "    if (ImGui.Begin(\"About\", aboutShown, ImGuiWindowFlags.AlwaysAutoResize)) {\n", "    if (ImGui.Begin(\"About\", &g_aboutShown, ImGuiWindowFlags.AlwaysAutoResize)) {\n"),
    Wave15Inverse("source/ui/panels.d", 54873, "", "    }\n"),
    Wave15Inverse("source/ui/panels.d", 58801, "void drawSidePanel(SidePanelRole app, ActionMenuRoles menu) {\n", "void drawSidePanel(EditorApp app, ActionMenuRoles menu) {\n"),
    Wave15Inverse("source/ui/panels.d", 71546, "void drawStatusBar(StatusPanelRole app, ActionMenuRoles menu) {\n", "void drawStatusBar(EditorApp app, ActionMenuRoles menu) {\n"),
    Wave15Inverse("source/ui/panels.d", 85227, "void drawAi3dModal(Ai3dPanelRole app) {\n", "void drawAi3dModal(EditorApp app) {\n"),
    Wave15Inverse("source/ui/panels.d", 105583, "                              GuardModalRole guardController) {\n", "                              GuardedActionController guardController) {\n"),
    Wave15Inverse("source/ui/panels.d", 105774, "                        GuardModalRole guardController) {\n", "                        GuardedActionController guardController) {\n"),
    Wave15Inverse("source/ui/panels.d", 105901, "    assert(guardController.isBound(), \"quit guard modal requires guard policy\");\n", "    assert(guardController !is null, \"quit guard modal requires guard policy\");\n"),
    Wave15Inverse("source/ui/tool_properties_panel.d", 82, "", "import application_command_binding : ApplicationCommandBinding;\n"),
    Wave15Inverse("source/ui/tool_properties_panel.d", 4740, "        DispatchFn dispatch, InteractiveDispatchFn interactive, FormsPanel forms,\n", "        ApplicationCommandBinding binding, FormsPanel forms,\n"),
    Wave15Inverse("source/ui/tool_properties_panel.d", 4921, "    assert(dispatch !is null && interactive !is null && activeTool !is null && activeToolId !is null);\n", "    assert(binding !is null && activeTool !is null && activeToolId !is null);\n"),
    Wave15Inverse("source/ui/tool_properties_panel.d", 5136, "        ToolPropertiesActions(dispatch,\n            interactive, forms, session, activeTool));\n", "        ToolPropertiesActions(&binding.dispatchUi,\n            &binding.dispatchInteractiveUi, forms, session, activeTool));\n"),
    Wave15Inverse("source/forms.d", 64802, "", "version (unittest)\n{\n    unittest { // RowKind discriminator + makeControl payload\n        auto r = Row.makeControl(\"tool.attr xfrm.transform TX ?\", \"X\", \"tx\");\n        assert(r.kind == RowKind.control);\n        assert(r.command == \"tool.attr xfrm.transform TX ?\");\n        assert(r.label == \"X\");\n        assert(r.id == \"tx\");\n        assert(r.showLabel);\n        assert(r.booleanStyle == BooleanStyle.checkbox);\n    }\n\n    unittest { // group nests rows; choice carries entries\n        auto g = Row.makeGroup(\"Position\", [\n            Row.makeControl(\"tool.attr xfrm.transform TX ?\", \"X\"),\n            Row.makeControl(\"tool.attr xfrm.transform TY ?\", \"Y\"),\n        ]);\n        assert(g.kind == RowKind.group);\n        assert(g.rows.length == 2);\n        assert(g.groupStyle == GroupStyle.inline_);\n\n        auto c = Row.makeChoice(\"Action Center\", [\n            ChoiceEntry(\"Auto\",   \"actr.auto\"),\n            ChoiceEntry(\"Select\", \"actr.select\"),\n        ]);\n        assert(c.kind == RowKind.choice);\n        assert(c.entries.length == 2);\n        assert(c.entries[0].cmd == \"actr.auto\");\n    }\n\n    unittest { // divider / label / sub / ref kinds\n        assert(Row.makeDivider().kind == RowKind.divider);\n        assert(Row.makeLabel(\"hello\").kind == RowKind.label);\n        assert(Row.makeLabel(\"hello\").label == \"hello\");\n        assert(Row.makeSub(\"transform.main\").formId == \"transform.main\");\n        assert(Row.makeRef(\"toolprops.falloff\").kind == RowKind.ref_);\n    }\n\n    unittest { // Form.matchesTool: filter-less never matches; list membership\n        Form shared_;                       // no whenTool — id-lookup / sub-form\n        assert(!shared_.matchesTool(\"anything\"));\n\n        Form stageForm;                     // stage form — not a tool form\n        stageForm.whenStage = \"falloff\";\n        assert(!stageForm.matchesTool(\"anything\"));\n\n        Form f;\n        f.whenTool = [\"xfrm.transform\", \"move\"];\n        assert(f.matchesTool(\"xfrm.transform\"));\n        assert(f.matchesTool(\"move\"));\n        assert(!f.matchesTool(\"scale\"));\n    }\n\n    // --- binding parse ----------------------------------------------------\n\n    unittest { // tool.attr round-trip: namespace + target + attr + query idx\n        auto b = parseBinding(\"tool.attr xfrm.transform TX ?\");\n        assert(b.commandId == \"tool.attr\");\n        assert(b.namespace == Namespace.tool);\n        assert(b.targetId  == \"xfrm.transform\");\n        assert(b.attr      == \"TX\");\n        assert(b.hasQuery);\n        assert(b.queryIdx  == 2);\n        assert(b.positionals == [\"xfrm.transform\", \"TX\", \"?\"]);\n    }\n\n    unittest { // tool.pipe.attr -> stage namespace\n        auto b = parseBinding(\"tool.pipe.attr falloff start ?\");\n        assert(b.namespace == Namespace.stage);\n        assert(b.targetId  == \"falloff\");\n        assert(b.attr      == \"start\");\n        assert(b.hasQuery);\n    }\n\n    unittest { // bool attr binds the same way as a float attr\n        auto b = parseBinding(\"tool.attr xfrm.transform T ?\");\n        assert(b.namespace == Namespace.tool);\n        assert(b.attr == \"T\");\n        assert(b.hasQuery);\n    }\n\n    unittest { // plain command (choice/cmd entry) -> command namespace, no query\n        auto b = parseBinding(\"actr.auto\");\n        assert(b.commandId == \"actr.auto\");\n        assert(b.namespace == Namespace.command);\n        assert(!b.hasQuery);\n        assert(b.queryIdx == -1);\n        assert(b.attr.length == 0);\n    }\n\n    unittest { // malformed: empty / blank line throws\n        bool threw = false;\n        try parseBinding(\"   \"); catch (BindingException) threw = true;\n        assert(threw);\n    }\n\n    unittest { // malformed: two '?' placeholders throws\n        bool threw = false;\n        try parseBinding(\"tool.attr xfrm.transform ? ?\");\n        catch (BindingException) threw = true;\n        assert(threw);\n    }\n\n    unittest { // malformed: tool.attr value bind missing its '?' throws\n        bool threw = false;\n        try parseBinding(\"tool.attr xfrm.transform TX\");\n        catch (BindingException) threw = true;\n        assert(threw);\n    }\n\n    unittest { // malformed: tool.attr with the '?' not in the value slot throws\n        bool threw = false;\n        try parseBinding(\"tool.attr xfrm.transform ? TX\");\n        catch (BindingException) threw = true;\n        assert(threw);\n    }\n\n    // --- widget-class decision -------------------------------------------\n\n    unittest { // datatype -> widget table (no overrides)\n        ParamHints none;\n        assert(widgetForKind(Param.Kind.Bool,    none) == WidgetKind.checkbox);\n        assert(widgetForKind(Param.Kind.Int,     none) == WidgetKind.dragInt);\n        assert(widgetForKind(Param.Kind.Float,   none) == WidgetKind.dragFloat);\n        assert(widgetForKind(Param.Kind.Enum,    none) == WidgetKind.combo);\n        assert(widgetForKind(Param.Kind.IntEnum, none) == WidgetKind.combo);\n        assert(widgetForKind(Param.Kind.String,  none) == WidgetKind.text);\n        assert(widgetForKind(Param.Kind.Vec3_,   none) == WidgetKind.vec3);\n        assert(widgetForKind(Param.Kind.IntArray, none) == WidgetKind.none);\n\n        ParamHints sl; sl.widget = ParamHints.Widget.Slider;\n        assert(widgetForKind(Param.Kind.Int,   sl) == WidgetKind.sliderInt);\n        assert(widgetForKind(Param.Kind.Float, sl) == WidgetKind.sliderFloat);\n    }\n\n    // --- resolver against a synthetic provider ---------------------------\n\n    // Build a small fake provider universe by hand (no running app). Mirrors\n    // the real XfrmTransformTool attr names so the test reads naturally.\n    version (unittest)\n    private Param[] fakeTransformParams(ref bool flagT, ref float tx,\n                                        ref float ty, ref int seg,\n                                        ref string mode, ref float dist)\n    {\n        import params : IntEnumEntry;\n        return [\n            Param.bool_  (\"T\",  \"Translate\",   &flagT, true),\n            Param.float_ (\"TX\", \"Translate X\", &tx, 0.0f),\n            Param.float_ (\"TY\", \"Translate Y\", &ty, 0.0f),\n            Param.int_   (\"seg\",\"Segments\",    &seg, 1),\n            Param.enum_  (\"mode\", \"Mode\", &mode,\n                          [[\"offset\",\"Offset\"], [\"width\",\"Width\"]], \"offset\"),\n            Param.float_ (\"dist\", \"Distance\", &dist, 0.5f),\n        ];\n    }\n\n    unittest { // a control line resolves to the right attr, kind, widget\n        bool flagT = true; float tx = 1.5f, ty = 0; int seg = 2;\n        string mode = \"width\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        auto rc = resolveControl(\n            Row.makeControl(\"tool.attr xfrm.transform TX ?\"), prov);\n        assert(rc.found);\n        assert(rc.param.name == \"TX\");\n        assert(rc.param.kind == Param.Kind.Float);\n        assert(rc.widget == WidgetKind.dragFloat);\n        assert(rc.choices.length == 0);\n    }\n\n    unittest { // bool attr -> checkbox by default, button under booleanStyle\n        bool flagT = true; float tx = 0, ty = 0; int seg = 1;\n        string mode = \"offset\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        auto cb = resolveControl(\n            Row.makeControl(\"tool.attr xfrm.transform T ?\"), prov);\n        assert(cb.found);\n        assert(cb.widget == WidgetKind.checkbox);\n\n        auto r = Row.makeControl(\"tool.attr xfrm.transform T ?\");\n        r.booleanStyle = BooleanStyle.button;\n        auto bt = resolveControl(r, prov);\n        assert(bt.widget == WidgetKind.button);\n    }\n\n    unittest { // enum attr -> combo + choices come from the Param, not YAML\n        bool flagT = true; float tx = 0, ty = 0; int seg = 1;\n        string mode = \"width\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        auto rc = resolveControl(\n            Row.makeControl(\"tool.attr xfrm.transform mode ?\"), prov);\n        assert(rc.found);\n        assert(rc.widget == WidgetKind.combo);\n        assert(rc.choices.length == 2);\n        assert(rc.choices[0] == [\"offset\", \"Offset\"]);\n        assert(rc.choices[1] == [\"width\", \"Width\"]);\n    }\n\n    unittest { // absent attr -> found=false (runtime-hidden, no throw)\n        bool flagT = true; float tx = 0, ty = 0; int seg = 1;\n        string mode = \"offset\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        auto rc = resolveControl(\n            Row.makeControl(\"tool.attr xfrm.transform NOPE ?\"), prov);\n        assert(!rc.found);\n        assert(rc.widget == WidgetKind.none);\n    }\n\n    unittest { // style override: force slider / drag on a Float\n        bool flagT = true; float tx = 0, ty = 0; int seg = 1;\n        string mode = \"offset\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        auto sl = Row.makeControl(\"tool.attr xfrm.transform dist ?\");\n        sl.style = ControlStyle.slider;\n        assert(resolveControl(sl, prov).widget == WidgetKind.sliderFloat);\n\n        auto dr = Row.makeControl(\"tool.attr xfrm.transform seg ?\");\n        dr.style = ControlStyle.slider;\n        assert(resolveControl(dr, prov).widget == WidgetKind.sliderInt);\n    }\n\n    unittest { // non-control rows do not resolve a value\n        bool flagT = true; float tx = 0, ty = 0; int seg = 1;\n        string mode = \"offset\"; float dist = 0.5f;\n        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);\n\n        // a cmd row carries no '?' — resolveControl returns not-found\n        assert(!resolveControl(Row.makeCmd(\"actr.auto\", \"Auto\"), prov).found);\n        // a divider is not a value bind\n        assert(!resolveControl(Row.makeDivider(), prov).found);\n    }\n\n    // --- write-path serialization (Phase 4) ------------------------------\n\n    unittest { // float token uses %g (byte-identical to argstring._fmtFloat)\n        assert(valueToArgToken(JSONValue(1.5))   == \"1.5\");\n        assert(valueToArgToken(JSONValue(1.0))   == \"1\");      // %g drops .0\n        assert(valueToArgToken(JSONValue(0.001)) == \"0.001\");\n    }\n\n    unittest { // cross-module byte-identity (task 0409): valueToArgToken vs.\n        // argstring.serializeParams for the pinned float set. Both now\n        // funnel through params.fmtFloatWire (fmtFloatG / argstring.\n        // _fmtFloat are thin delegates) — this exercises the real\n        // cross-module dependency rather than the hand-synced literals in\n        // the test just above (which stays as-is per task 0409's contract).\n        import argstring : serializeParams;\n        immutable float[] vals = [0.0f, 1.0f, -1.0f, 0.5f, 1e-7f, -3.25f,\n                                   1e20f, 123456.789f, 0.1f];\n        foreach (v; vals) {\n            float f = v;\n            // default deliberately != any pinned value so isUserSet is\n            // always true and serializeParams always emits \"w:<token>\".\n            auto p = Param.float_(\"w\", \"W\", &f, float.nan);\n            string viaArgstring = serializeParams([p]);\n            string viaForms     = valueToArgToken(JSONValue(cast(double)v));\n            assert(viaArgstring == \"w:\" ~ viaForms,\n                   viaArgstring ~ \" vs w:\" ~ viaForms);\n        }\n    }\n\n    unittest { // bool / int / string tokens\n        assert(valueToArgToken(JSONValue(true))  == \"true\");\n        assert(valueToArgToken(JSONValue(false)) == \"false\");\n        assert(valueToArgToken(JSONValue(42))    == \"42\");\n        assert(valueToArgToken(JSONValue(\"offset\")) == \"offset\");\n    }\n\n    unittest { // substituteQuery reconstructs a tool.attr write line\n        auto b = parseBinding(\"tool.attr xfrm.transform TX ?\");\n        auto line = substituteQuery(b, JSONValue(1.5));\n        assert(line == \"tool.attr xfrm.transform TX 1.5\", line);\n    }\n\n    unittest { // substituteQuery: bool checkbox write\n        auto b = parseBinding(\"tool.attr xfrm.transform T ?\");\n        assert(substituteQuery(b, JSONValue(true))\n               == \"tool.attr xfrm.transform T true\");\n    }\n\n    unittest { // substituteQuery: stage namespace round-trip\n        auto b = parseBinding(\"tool.pipe.attr falloff start ?\");\n        assert(substituteQuery(b, JSONValue(0.25))\n               == \"tool.pipe.attr falloff start 0.25\");\n    }\n\n    unittest { // substituteQuery: an enum tag that needs no quoting\n        auto b = parseBinding(\"tool.attr prim.sphere axis ?\");\n        assert(substituteQuery(b, JSONValue(\"x\"))\n               == \"tool.attr prim.sphere axis x\");\n    }\n\n    unittest { // round-trip: the substituted line re-parses to the same args\n        auto b = parseBinding(\"tool.attr xfrm.transform TX ?\");\n        auto line = substituteQuery(b, JSONValue(2.75));\n        auto p = parseArgstring(line);\n        assert(p.commandId == \"tool.attr\");\n        auto pos = positionalArgs(p.params);\n        assert(pos.length == 3);\n        assert(pos[0].str == \"xfrm.transform\");\n        assert(pos[1].str == \"TX\");\n        double n = pos[2].type == JSONType.float_ ? pos[2].floating\n                 : cast(double) pos[2].integer;\n        assert(n > 2.74 && n < 2.76);\n    }\n\n    unittest { // currentEnumTag reads the live Enum tag through *sptr\n        string mode = \"width\";\n        auto p = Param.enum_(\"mode\", \"Mode\", &mode,\n                             [[\"offset\",\"Offset\"], [\"width\",\"Width\"]], \"offset\");\n        assert(currentEnumTag(p) == \"width\");\n    }\n\n    unittest { // stage-namespace binding resolves against a stage's params()\n        // The resolver is namespace-agnostic: it takes whatever Param[] the\n        // caller hands it. Here we stand in for a falloff stage's params().\n        float start = 0.1f, end_ = 0.9f;\n        Param[] stageParams = [\n            Param.float_(\"start\", \"Start\", &start, 0.0f),\n            Param.float_(\"end\",   \"End\",   &end_,  1.0f),\n        ];\n        auto b = parseBinding(\"tool.pipe.attr falloff start ?\");\n        assert(b.namespace == Namespace.stage);\n        auto rc = resolveBinding(b, stageParams);\n        assert(rc.found);\n        assert(rc.param.name == \"start\");\n        assert(rc.widget == WidgetKind.dragFloat);\n    }\n}\n"),
    Wave15Inverse("source/app.d", 261261, "    auto layerListRoles = bindLayerListPanel(sessionOwner, &commandBinding.dispatchUi, &commandBinding.dispatchInteractiveUi,\n", "    auto layerListRoles = bindLayerListPanel(sessionOwner, commandBinding,\n"),
    Wave15Inverse("source/app.d", 261519, "    auto channelsPanelRoles = bindChannelsPanel(sessionOwner, &commandBinding.dispatchInteractiveUi,\n", "    auto channelsPanelRoles = bindChannelsPanel(sessionOwner, commandBinding,\n"),
    Wave15Inverse("source/app.d", 261816, "    auto toolPropertiesRoles = bindToolPropertiesPanel(&commandBinding.dispatchUi, &commandBinding.dispatchInteractiveUi,\n", "    auto toolPropertiesRoles = bindToolPropertiesPanel(commandBinding,\n"),
    Wave15Inverse("source/app.d", 262079, "    auto imageListRoles = bindImageListPanel(sessionOwner, &commandBinding.dispatchUi);\n", "    auto imageListRoles = bindImageListPanel(sessionOwner, commandBinding);\n"),
    Wave15Inverse("source/app.d", 281797, "    import ui.panel_host_roles : TabPanelRole, SidePanelRole, StatusPanelRole;\n    version (web) {} else import ui.panel_host_roles : Ai3dPanelRole;\n", ""),
    Wave15Inverse("source/app.d", 322572, "        drawSidePanel(editor_app.bindPanelHostRoles!(SidePanelRole)(app), actionMenuRoles);\n        drawTabPanel(editor_app.bindPanelHostRoles!(TabPanelRole)(app));\n", "        drawSidePanel(app, actionMenuRoles);\n        drawTabPanel(app);\n"),
    Wave15Inverse("source/app.d", 324388, "        drawAi3dModal(editor_app.bindPanelHostRoles!(Ai3dPanelRole)(app));\n", "        drawAi3dModal(app);\n"),
    Wave15Inverse("source/app.d", 324985, "        drawQuitGuardModal(guardModalState, testMode, editor_app.makeGuardModalRole(guardController));\n", "        drawQuitGuardModal(guardModalState, testMode, guardController);\n"),
    Wave15Inverse("source/app.d", 325089, "        drawStatusBar(editor_app.bindPanelHostRoles!(StatusPanelRole)(app), actionMenuRoles);\n", "        drawStatusBar(app, actionMenuRoles);\n"),
    Wave15Inverse("source/app.d", 329664, "            import commands.viewport.display : kCavityGainMax, kCavityDistanceMin,\n                kCavityDistanceMax, kCavityAttenuationMax;\n", ""),
    Wave15Inverse("source/app.d", 329874, "                                   uiCommandDelegate, &layoutResetAction.authorReset,\n                                   kCavityGainMax, kCavityDistanceMin,\n                                   kCavityDistanceMax, kCavityAttenuationMax);\n", "                                   uiCommandDelegate, layoutResetAction);\n"),
    Wave15Inverse("source/app.d", 330638, "            drawAboutPanel(&g_aboutShown);\n", "            drawAboutPanel(app);\n"),
    Wave15Inverse("source/editor_app.d", 48220, "\nimport ai.copilot_gate : kCopilotEnabled;\nimport guarded_action_controller : GuardedActionController;\nimport ui.panel_host_roles : GuardModalRole;\n\nGuardModalRole makeGuardModalRole(GuardedActionController guardController) {\n    if (guardController is null) return GuardModalRole.init;\n    return GuardModalRole(\n        &guardController.awaitingAnswer,\n        &guardController.promptText,\n        &guardController.answerSave,\n        &guardController.answerDiscard,\n        &guardController.answerCancel);\n}\n\nimport ui.panel_host_roles : TabLayoutBorrow, SideLayoutBorrow, StatusLayoutBorrow,\n    TabPanelRole, SidePanelRole, StatusPanelRole;\nversion (web) {} else import ui.panel_host_roles : Ai3dModalBorrow, Ai3dPanelRole;\n\n// The presentation roles borrow these same live slots at each original draw\n// point (task 20262940; evidence: approved Wave18 role custody).\nRole bindPanelHostRoles(Role)(EditorApp app) {\n    Role role;\n    static if (is(Role == TabPanelRole)) {\n        role.layout = TabLayoutBorrow(&app.layout.tabPos, &app.layout.tabSize);\n        role.panelsPtr = app.panelsPtr;\n        role.activePanelIdxPtr = app.activePanelIdxPtr;\n    } else static if (is(Role == SidePanelRole)) {\n        role.layout = SideLayoutBorrow(&app.layout.sidePos, &app.layout.sideSize);\n        role.panelsPtr = app.panelsPtr;\n        role.activePanelIdxPtr = app.activePanelIdxPtr;\n        role.activeToolIdPtr = app.activeToolIdPtr;\n        role.shortcutsPtr = app.shortcutsPtr;\n        role.regPtr = app.regPtr;\n        role.sessionOwner = app.sessionOwner;\n        role.meshDg = app.meshDg;\n        role.kGenerateAiAvailable = kGenerateAiAvailable;\n    } else static if (is(Role == StatusPanelRole)) {\n        role.layout = StatusLayoutBorrow(&app.layout.statusPos, &app.layout.statusSize);\n        role.statusLineGroupsPtr = app.statusLineGroupsPtr;\n        role.activeToolIdPtr = app.activeToolIdPtr;\n        role.shortcutsPtr = app.shortcutsPtr;\n        role.regPtr = app.regPtr;\n        role.sessionOwner = app.sessionOwner;\n        role.meshDg = app.meshDg;\n        role.kAiToggleAvailable = kAiToggleAvailable;\n        role.kCopilotEnabled = kCopilotEnabled;\n    } else {\n        version (web) {\n            static assert(0, \"no AI3D presentation role in web\");\n        } else {\n            static assert(is(Role == Ai3dPanelRole));\n            role.ai3dModal.healthCheckedPtr = &app.ai3dModal.healthChecked;\n            role.ai3dModal.healthOkPtr = &app.ai3dModal.healthOk;\n            role.ai3dModal.healthProtocolPtr = &app.ai3dModal.healthProtocol;\n            role.ai3dModal.healthBackendPtr = &app.ai3dModal.healthBackend;\n            role.ai3dModal.healthObjCapablePtr = &app.ai3dModal.healthObjCapable;\n            role.ai3dModal.healthMessagePtr = &app.ai3dModal.healthMessage;\n            role.ai3dModal.jobIdPtr = &app.ai3dModal.jobId;\n            role.ai3dModal.statePtr = &app.ai3dModal.state;\n            role.ai3dModal.stagePtr = &app.ai3dModal.stage;\n            role.ai3dModal.progressPtr = &app.ai3dModal.progress;\n            role.ai3dModal.errorCodePtr = &app.ai3dModal.errorCode;\n            role.ai3dModal.errorMessagePtr = &app.ai3dModal.errorMessage;\n            role.ai3dModalOpenPtr = &app.ai3dModalOpen();\n            role.ai3dModalPendingOpenPtr = &app.ai3dModalPendingOpen();\n            role.ai3dPickedImagePathPtr = &app.ai3dPickedImagePath();\n            role.ai3dWorkerUrlBufPtr = &app.ai3dWorkerUrlBuf();\n            role.ai3dWorkerStartingPtr = app.ai3dWorkerStartingPtr;\n            role.ai3dWorkerStartDeadlinePtr = app.ai3dWorkerStartDeadlinePtr;\n            role.ai3dWorkerNextHealthProbePtr = app.ai3dWorkerNextHealthProbePtr;\n            role.ai3dInstallConfirmOpenPtr = app.ai3dInstallConfirmOpenPtr;\n            role.ai3dInstallConfirmPendingOpenPtr = app.ai3dInstallConfirmPendingOpenPtr;\n            role.ai3dMaxFacesPtr = app.ai3dMaxFacesPtr;\n            role.ai3dController = app.ai3dController;\n            role.ai3dWorkerManager = app.ai3dWorkerManager;\n        }\n    }\n    return role;\n}\n", ""),
];

private struct Wave15WholePin { string origin; size_t physicalBytes; string physicalDigest; size_t originalBytes; string originalDigest; }
private immutable Wave15WholePin[] wave15WholePins = [
    Wave15WholePin("source/render/backend.d", 8037, "3882e8dfe4281bb197b72eab53bc13c5b683c25e88abf41cdc96baf85a6b2f52", 8037, "3882e8dfe4281bb197b72eab53bc13c5b683c25e88abf41cdc96baf85a6b2f52"),
    Wave15WholePin("source/render/backend_bridge.d", 9295, "2eba5fe82e0186fcee9d254311fc20678d48182feb785b0aa2029a561fd59ee8", 9295, "2eba5fe82e0186fcee9d254311fc20678d48182feb785b0aa2029a561fd59ee8"),
    Wave15WholePin("source/render/cycles_backend.d", 39322, "7b5286bf79541315f1f88f03c5e1a655dfff957c20e8403948462a6a9227517c", 39322, "7b5286bf79541315f1f88f03c5e1a655dfff957c20e8403948462a6a9227517c"),
    Wave15WholePin("source/render/render_diff.d", 14356, "64d0b63ad38a2122039567dffad7ecd41ebbaffccf8660e08e4ff37a1f996eb3", 14356, "64d0b63ad38a2122039567dffad7ecd41ebbaffccf8660e08e4ff37a1f996eb3"),
    Wave15WholePin("source/render/rpr_backend.d", 51610, "590194710b2b7bbc19c7804302322d143c0d7835cc61dd60a520904e0ed2e88b", 51610, "590194710b2b7bbc19c7804302322d143c0d7835cc61dd60a520904e0ed2e88b"),
    Wave15WholePin("source/render/scene.d", 8393, "b6f459664772366c2b16fbc08328e3e97db77e2a67758c5f2cef3e8cfdc6e11e", 8393, "b6f459664772366c2b16fbc08328e3e97db77e2a67758c5f2cef3e8cfdc6e11e"),
    Wave15WholePin("source/sdl_error.d", 319, "b124d7a12e3ed7d66e5045022a942023ca9434f2f3512639bf04e77d30bf284c", 319, "b124d7a12e3ed7d66e5045022a942023ca9434f2f3512639bf04e77d30bf284c"),
    Wave15WholePin("tests/unit/sdl_error_test.d", 453, "c18ed67efef193d4b61954ef29bbb97aeb16cca5e24ff0f40b6e990293d5d247", 453, "c18ed67efef193d4b61954ef29bbb97aeb16cca5e24ff0f40b6e990293d5d247"),
    Wave15WholePin("source/args_dialog.d", 4353, "959e825858a0428c56529c24cd1101bea41a68616bbbbe2a62aca0552066be1f", 4353, "959e825858a0428c56529c24cd1101bea41a68616bbbbe2a62aca0552066be1f"),
    Wave15WholePin("source/buttonset.d", 28997, "3d2c8d756198e0837fb4f4cd6f7c67a0b13490a99a20f4e01af2896dbbaa7594", 28997, "3d2c8d756198e0837fb4f4cd6f7c67a0b13490a99a20f4e01af2896dbbaa7594"),
    Wave15WholePin("source/copilot_overlay.d", 4829, "1e39c5c4c39fd7e23aa0d2a00bf72a33a75f8422cdd3a92a712e5a85051669fa", 4829, "1e39c5c4c39fd7e23aa0d2a00bf72a33a75f8422cdd3a92a712e5a85051669fa"),
    Wave15WholePin("source/copilot_panel.d", 9348, "00d95e59429a4ed8d832ff2f0b2ba17d8631f3109fff8c520c975ac28391e79a", 9348, "00d95e59429a4ed8d832ff2f0b2ba17d8631f3109fff8c520c975ac28391e79a"),
    Wave15WholePin("source/forms_render.d", 42005, "f7f1302588c5814ec8fe1fb56e0847f0f048db00abc734e86deb43f880bd7b52", 42005, "f7f1302588c5814ec8fe1fb56e0847f0f048db00abc734e86deb43f880bd7b52"),
    Wave15WholePin("source/imgui_event_gate.d", 4471, "721fce075b852866544fa222475ab363eae23a4d952c52ee25827eb4c6971324", 4471, "721fce075b852866544fa222475ab363eae23a4d952c52ee25827eb4c6971324"),
    Wave15WholePin("source/imgui_flag_boundary.d", 1118, "70465ce58b05c2ef0e52d18e9e9db659858afb0b9fc72f25a30b4ff1aace79e4", 1118, "70465ce58b05c2ef0e52d18e9e9db659858afb0b9fc72f25a30b4ff1aace79e4"),
    Wave15WholePin("source/imgui_style.d", 2058, "ffe15cd7d967f277fce9f5c9d3e58f7ffdbf4ef4ad2916ed02be032bae2e340d", 2058, "ffe15cd7d967f277fce9f5c9d3e58f7ffdbf4ef4ad2916ed02be032bae2e340d"),
    Wave15WholePin("source/pie_geometry.d", 2407, "6cc3e1c0a1bb56420b562a1bafeff7994a1e182f5ae1e1aadfee43a4d14f89bb", 2407, "6cc3e1c0a1bb56420b562a1bafeff7994a1e182f5ae1e1aadfee43a4d14f89bb"),
    Wave15WholePin("source/pie_menus.d", 1195, "4e0c4d41460fd913f3a893f6bbbbf609d9a16a20707ca15b93bdd2c7890b4a85", 1195, "4e0c4d41460fd913f3a893f6bbbbf609d9a16a20707ca15b93bdd2c7890b4a85"),
    Wave15WholePin("source/pie_state.d", 2392, "81e869bfa63ce3f813543d2764d831bf7da783de7ad103c24af69dd41c459fd6", 2392, "81e869bfa63ce3f813543d2764d831bf7da783de7ad103c24af69dd41c459fd6"),
    Wave15WholePin("source/popup_state.d", 1699, "1ffeab8efb43b8204971244d37e9f4cab22f1e8f77aee83bbabcc9adf258b2a8", 1699, "1ffeab8efb43b8204971244d37e9f4cab22f1e8f77aee83bbabcc9adf258b2a8"),
    Wave15WholePin("source/ui/action_menu.d", 14783, "f9717d9a5428e0842f2e62411de12aaf9bc57ef3d12daa17beddd00a768abd98", 14783, "f9717d9a5428e0842f2e62411de12aaf9bc57ef3d12daa17beddd00a768abd98"),
    Wave15WholePin("source/ui/availability.d", 11041, "1f6dc58fd734279092a5d2b09581d98f35845240bc56417e0c35d8ec072bfdb9", 14949, "41dee6cfff9f567680aa8836be7eaf87c3e93ed9d1e4525eb3470a0040a5da60"),
    Wave15WholePin("source/ui/button_face.d", 4269, "fa55d1953075e3b14c297abf84d76ed549a30932d470de02455c68913e48f884", 4269, "fa55d1953075e3b14c297abf84d76ed549a30932d470de02455c68913e48f884"),
    Wave15WholePin("source/ui/channel_rows.d", 18607, "c0413662d604adbb00a1b6effc9a88bf807b4e9a98d34b2e32a335777907353f", 18607, "c0413662d604adbb00a1b6effc9a88bf807b4e9a98d34b2e32a335777907353f"),
    Wave15WholePin("source/ui/channels_panel.d", 18896, "4860e14a7002a31a8493e5d9d41b17717aa4bf1a4d6e1e836af297eb1b7c44c7", 18967, "afa04884dddb1599a47f6045b84569e5527e60a70285e652f1af9353188bdd50"),
    Wave15WholePin("source/ui/command_notice.d", 2682, "9bfacbd47ec2fd7b8a29399901fa8361754b8a5d16bc99f329bedea6c668c2be", 2682, "9bfacbd47ec2fd7b8a29399901fa8361754b8a5d16bc99f329bedea6c668c2be"),
    Wave15WholePin("source/ui/dock_drag.d", 916, "f39f58f7cfb7c30f110553a37d60950c4a7026303488521cbf7a667e845794e6", 916, "f39f58f7cfb7c30f110553a37d60950c4a7026303488521cbf7a667e845794e6"),
    Wave15WholePin("source/ui/guard_modal_state.d", 1751, "414a7f5960a40459c2ff2d4b1d086eff13e1adfcc03b9e883dddd1d829dbeba3", 1751, "414a7f5960a40459c2ff2d4b1d086eff13e1adfcc03b9e883dddd1d829dbeba3"),
    Wave15WholePin("source/ui/history_panel.d", 6892, "402adb0ee610ed0de470ef17b8d6ffa547f18115c5782568eca2159618e7e86f", 6892, "402adb0ee610ed0de470ef17b8d6ffa547f18115c5782568eca2159618e7e86f"),
    Wave15WholePin("source/ui/image_list_panel.d", 23177, "0bae5fdafcf3ec19057dd9d5b6570283b07c12877880c2120481530291e7d0dc", 23257, "1dc2af24c654bcc804c99c6d02f6941f57cfc77e226e3e2bde0e2b365a6e3a42"),
    Wave15WholePin("source/ui/image_rows.d", 57156, "95358e650d4546e86ae0d24ba70a55cead26ccae4f268f12e36718781fa9ab40", 57156, "95358e650d4546e86ae0d24ba70a55cead26ccae4f268f12e36718781fa9ab40"),
    Wave15WholePin("source/ui/imgui_window_class.d", 1122, "741235791618f24ec341dc23fe76924f983899cca244dd54291a5727e29fdac3", 1122, "741235791618f24ec341dc23fe76924f983899cca244dd54291a5727e29fdac3"),
    Wave15WholePin("source/ui/item_glyphs.d", 9927, "76500e24f9849143b8e9ff32c314acb8afbe8db173946d676ea3c3fb05d7eea1", 9927, "76500e24f9849143b8e9ff32c314acb8afbe8db173946d676ea3c3fb05d7eea1"),
    Wave15WholePin("source/ui/item_rename.d", 3698, "d8628e7aed21575fc711d77d7e491eca6b0e44b3574b3e9cfdf2f402ca79fb48", 3698, "d8628e7aed21575fc711d77d7e491eca6b0e44b3574b3e9cfdf2f402ca79fb48"),
    Wave15WholePin("source/ui/item_rows.d", 32036, "b310748d4e6f79df588307eaeccdad7064dc5647bd5746e84b0fefda8cbbef6d", 32482, "31d8a3afff5f63356fa5e07ba97c29ff658424fb6d5a19032d0e9f8c73a8d901"),
    Wave15WholePin("source/ui/layer_list_panel.d", 44983, "37fd9ecf74b2b472fef9f21de48fe987642d3c4bf2bf7570189bca64677c216d", 45026, "5cbc0b5d2bad3b56a4e0ca32ac49a90add32b84864ddea8c338a11eda071e1ee"),
    Wave15WholePin("source/ui/mode_popup.d", 5651, "2e26bbbc64e53ad7435801ebd3bb59b009413953b8f3ee919572af9f66685791", 5651, "2e26bbbc64e53ad7435801ebd3bb59b009413953b8f3ee919572af9f66685791"),
    Wave15WholePin("source/ui/panel_chrome.d", 3230, "bb20b401032aadb3b3816fa29e3c6aea924ddf3f9651250602a22672086dcd2b", 3230, "bb20b401032aadb3b3816fa29e3c6aea924ddf3f9651250602a22672086dcd2b"),
    Wave15WholePin("source/ui/panels.d", 154150, "ec6268c7601a40122a331ca635a8e59f28475a64cf1ef1881b0f83b040e19458", 155726, "ee7ff3ff12afb44c8d9b66ac7f290dc2a4aa385b06d18ea36da0203e42373a06"),
    Wave15WholePin("source/ui/pie_record.d", 2749, "651392ffad2b443a62d28871c91661103b9c34ca3c5588e7241e8adb42e033e2", 2749, "651392ffad2b443a62d28871c91661103b9c34ca3c5588e7241e8adb42e033e2"),
    Wave15WholePin("source/ui/pie_render.d", 3753, "99995fa952317ce4b3a63807e523781c048c245a9247de883aaaed300d13c679", 3753, "99995fa952317ce4b3a63807e523781c048c245a9247de883aaaed300d13c679"),
    Wave15WholePin("source/ui/remesh_modal_state.d", 2108, "c5aabdf2edf09475750dd45689885eadeba1dbdc5b0f0c0ed83694a6766f39c4", 2108, "c5aabdf2edf09475750dd45689885eadeba1dbdc5b0f0c0ed83694a6766f39c4"),
    Wave15WholePin("source/ui/retained_item.d", 1884, "bee7544186341f0a0bc66c498b80cd6765ec9d5486e4bdbfde888884ea71a997", 1884, "bee7544186341f0a0bc66c498b80cd6765ec9d5486e4bdbfde888884ea71a997"),
    Wave15WholePin("source/ui/stat_record.d", 6402, "0178c5f0fab094c317af483eda0abdfa872c28992829574c6922fa405e15a522", 6402, "0178c5f0fab094c317af483eda0abdfa872c28992829574c6922fa405e15a522"),
    Wave15WholePin("source/ui/stat_rows.d", 45504, "ebf2d2d314250b33053cddd7b5a3cc475897dd9a86a9576e2b402819a5b9563d", 45504, "ebf2d2d314250b33053cddd7b5a3cc475897dd9a86a9576e2b402819a5b9563d"),
    Wave15WholePin("source/ui/tool_properties_panel.d", 20465, "d0dcffe0465bc316293d330fd2cc5ef6577ca6db14f00131fe0a9524292d2fda", 20513, "d41a23a12d8cbc11f719a29c414fbe7a4d4728ee5db5905fdfc8b405d6c1ff19"),
    Wave15WholePin("source/ui/viewport_props_role.d", 1833, "799c9a5e0514f465c3060e5ba453615f9446beeff25f2b7ecea7ae16f8f94853", 1833, "799c9a5e0514f465c3060e5ba453615f9446beeff25f2b7ecea7ae16f8f94853"),
    Wave15WholePin("tests/unit/ui/channel_rows_test.d", 18917, "e1509698233e3381522a28067478f4556622944e1dc70152fafc462fd016cfd7", 18917, "e1509698233e3381522a28067478f4556622944e1dc70152fafc462fd016cfd7"),
    Wave15WholePin("tests/unit/ui/command_notice_test.d", 3118, "fb1c7413c076e2eec1f654bde45799c81dc00a2a4d455ad4f52a78569a3ddc8b", 3118, "fb1c7413c076e2eec1f654bde45799c81dc00a2a4d455ad4f52a78569a3ddc8b"),
    Wave15WholePin("tests/unit/ui/stat_rows_test.d", 42593, "5892f4f35c889711b7a4599bdda174acf4e0f85a7f061382137b52772c806ccf", 42555, "25e0025e79f39974afceb111205f5710a32a7d82cfa95916e8249e68302997ee"),
    Wave15WholePin("source/forms.d", 64802, "f1072600396c4ab44b47656046a96f64592271456e8cdfe43c340c3c4cdab985", 78908, "75fece8e7fa8512268c02196c3c43b3b3b38f0e487f10895fccdc092a3ffbb90"),
    Wave15WholePin("source/app.d", 473488, "e77cffb3d2c0060af0de5fd24fd5859d7a691dc3a22c4af0b89276263e54f103", 472668, "bd6a2c936d2b23ac4b028a108e5a34d99fc57f2b1e410c5ff404491ef7e3a7c0"),
    Wave15WholePin("source/editor_app.d", 52269, "b95eea377eb75fe785385a28a47b1049d4e83f85233124a0ba7aeec2256d1de1", 48220, "59febb4cbc81bfbaf20d8065e9d28618c411c10f475a10a8857998a7f5ebe63c"),
];

private string wave15RestoreSource(string origin, string text, string root) {
    import std.file : exists, readText;
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    const(Wave15WholePin)* whole;
    foreach (ref pin; wave15WholePins) if (pin.origin == origin) { whole = &pin; break; }
    if (whole is null) return text;
    const physicalValid = text.length == whole.physicalBytes
        && sha256Of(text).toHexString.toLower == whole.physicalDigest;
    wave15RecordInput(origin ~ ":whole-physical", physicalValid);
    if (!physicalValid) return "";
    string part;
    foreach (fragment; wave15Fragments[$ - 3 .. $]) {
        if (fragment.origin != origin) continue;
        const carrier = buildPath(root, fragment.destination);
        const physical = wave19PhysicalPath(carrier);
        const raw = exists(physical) ? wave19ReadCurrent(physical) : "";
        if (origin == "source/ui/availability.d") {
            const valid = raw.length == 4074 && sha256Of(raw).toHexString.toLower ==
                "de05d3d31226b4e0a0f1dea8248dbea3278c5a6f6eedc4698f7dc5520da617ad";
            wave15RecordInput(origin ~ ":whole-carrier", valid);
            if (!valid) return "";
        }
        size_t matches;
        part = wave15FragmentText(raw, fragment, matches);
        // The existing extractor appends one delimiter after the exact fragment.
        if (matches == 1) part = part[0 .. $ - 1];
        wave15RecordInput(origin ~ ":carrier-fragment", matches == 1);
        if (matches != 1) return "";
    }
    foreach_reverse (row; wave15Inverses) {
        if (row.origin != origin) continue;
        const valid = row.offset <= text.length && row.physical.length <= text.length - row.offset
            && text[row.offset .. row.offset + row.physical.length] == row.physical;
        wave15RecordInput(origin ~ ":inverse-span", valid);
        if (!valid) return "";
        string original = row.original;
        if (part.length && original.length) {
            if (origin == "source/ui/availability.d")
                original = original.length == 179 ? part[0 .. 179] : part[180 .. $];
            else {
                wave15RecordInput(origin ~ ":fragment-bytes", part == original);
                if (part != original) return "";
                original = part;
            }
        }
        text = text[0 .. row.offset] ~ original ~ text[row.offset + row.physical.length .. $];
    }
    const originalValid = text.length == whole.originalBytes
        && sha256Of(text).toHexString.toLower == whole.originalDigest;
    wave15RecordInput(origin ~ ":whole-original", originalValid);
    return originalValid ? text : "";
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
    auto readScope = Wave19ReadScope(true);
    import std.file : exists, readText;
    const normal = wave15Normalize(wave15LogicalPath(path));
    // ImportC is an exact whole-file native input, outside the D move roster.
    string nativeRoot;
    if (wave15Match(normal, "source/imgui_flag_abi.c", nativeRoot)) {
        import std.digest.sha : sha256Of;
        import std.digest : toHexString;
        import std.string : toLower;
        const destination = buildPath(nativeRoot, wave19OwnerMoved(nativeRoot, "editor-ui")
            ? "libraries/ui/editor/source/vibe3d/ui/editor/imgui_flag_abi.c"
            : "packages/editor-ui/source/imgui_flag_abi.c");
        const oldPresent = exists(normal), newPresent = exists(destination);
        const text = readText(oldPresent ? normal : destination);
        const valid = text.length == 691 && sha256Of(text).toHexString.toLower ==
            "ad9728c0a90de1fb0e7837441af84b479d30520d97f180c4de008a96e4811819";
        wave15RecordInput(normal ~ ":native-whole", valid);
        wave15RecordInput(normal ~ ":native-owner", oldPresent != newPresent);
        return valid ? text : "";
    }
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
        const destination = wave19PhysicalPath(buildPath(root, move.newPath));
        const oldPresent = exists(normal), newPresent = exists(destination);
        auto text = wave19ReadCurrent(oldPresent ? normal : destination);
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
        if (!oldPresent) text = wave15RestoreSource(move.oldPath, text, root);
        wave15RecordInput(normal ~ ":physical", oldPresent != newPresent);
        foreach (fragment; wave15Fragments) {
            if (fragment.origin != move.oldPath) continue;
            if (fragment.id == "source/ui/availability.d:original-public-cells"
                    || fragment.id == "source/ui/item_rows.d:original-public-cells"
                    || fragment.id == "source/forms.d:original-public-cells") {
                if (oldPresent) {
                    size_t matches;
                    wave15FragmentText(text, fragment, matches);
                    wave15RecordInput(normal ~ ":" ~ fragment.id, matches == 1);
                }
                continue;
            }
            size_t matches;
            string original;
            if (oldPresent) original = wave15FragmentText(text, fragment, matches);
            else {
                const carrier = buildPath(root, fragment.destination);
                const physicalCarrier = wave19PhysicalPath(carrier);
                if (exists(physicalCarrier)) original = wave15FragmentText(wave19ReadCurrent(physicalCarrier), fragment, matches);
                if (fragment.destination != move.newPath) text ~= "\n" ~ original;
            }
            wave15RecordInput(normal ~ ":" ~ fragment.id, matches == 1);
        }
        return text;
    }
    auto text = wave19ReadCurrent(normal);
    foreach (origin; ["source/app.d", "source/editor_app.d"]) {
        string root;
        if (wave15Match(normal, origin, root)) text = wave15RestoreSource(origin, text, root);
    }
    return text;
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
        SpanMode span, bool followSymlink = true, string mathRoot = repoRoot) {
    auto readScope = Wave19ReadScope(true);
    import std.file : dirEntries, exists, isFile, isDir, getSize;
    import std.path : baseName, dirName, globMatch, relativePath, isAbsolute;
    import std.algorithm : startsWith, canFind;
    const base = wave15Normalize(mathRoot);
    const normal = wave19LogicalPath(directory, base);
    Wave15Entry[] result;
    string entryName(string absolute) {
        return isAbsolute(directory) ? absolute : relativePath(absolute, wave15Normalize("."));
    }
    // Project the real originals into their old logical layout; transitional
    // inputs are never directory members. Historical destinations below keep
    // their original single ownership through wave15Moves.
    foreach (row; wave19Modules) {
        if (row.owner != "desktop") continue;
        const logical = buildPath(base, row.oldPath);
        if (!logical.startsWith(normal ~ "/")) continue;
        if (!wave19RowMoved(base, row)) continue;
        const relative = relativePath(logical, normal);
        if (span == SpanMode.shallow && relative.canFind("/")) continue;
        if (!globMatch(baseName(logical), pattern)) continue;
        const physical = wave19PhysicalPath(logical, base);
        if (exists(physical)) result ~= Wave15Entry(entryName(logical), true, false, getSize(physical));
    }
    foreach (owner; wave19Owners) {
        const oldRoot = buildPath(base, owner.oldRoot);
        if (normal != oldRoot && !normal.startsWith(oldRoot ~ "/")
                && !oldRoot.startsWith(normal ~ "/")) continue;
        if (!wave19OwnerMoved(base, owner)) continue;
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            const logical = buildPath(base, row.oldPath);
            if (!logical.startsWith(normal ~ "/")) continue;
            bool historicalDestination;
            if (base == wave15Normalize(repoRoot)) foreach (move; wave15Moves)
                if (row.oldPath == move.newPath) { historicalDestination = true; break; }
            if (historicalDestination) continue;
            const relative = relativePath(logical, normal);
            if (span == SpanMode.shallow && relative.canFind("/")) continue;
            if (!globMatch(baseName(logical), pattern)) continue;
            const physical = wave19PhysicalPath(logical, base);
            result ~= Wave15Entry(entryName(logical), true, false, getSize(physical));
        }
    }
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
                && (exists(logical) != exists(wave19PhysicalPath(buildPath(root, pin.newPath)))));
            break;
        }
    }
    if (exists(normal)) foreach (entry; dirEntries(normal, pattern, span, followSymlink)) {
        bool movedDestination;
        foreach (move; wave15Moves) {
            string root;
            if (wave15Match(wave15Normalize(entry.name), move.newPath, root)) { movedDestination = true; break; }
        }
        if (!movedDestination)
            result ~= Wave15Entry(entryName(entry.name), entry.isFile, entry.isDir, entry.isFile ? entry.size : 0);
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
            const physical = wave19PhysicalPath(buildPath(root, move.newPath));
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

unittest { // approved stat header: whole physical input and whole original body
    import std.file : readText;
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    import std.path : dirName;
    const root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum origin = "tests/unit/ui/stat_rows_test.d";
    enum header = "module tests.unit.ui.stat_rows_test;\n\n";
    const physical = wave19ReadCurrent(buildPath(root,
        "packages/editor-ui/tests/source/tests/unit/ui/stat_rows_test.d"));
    assert(physical.length == 42593 && physical[407 .. 445] == header,
        "stat header physical whole-unit control");
    const original = physical[0 .. 407] ~ physical[445 .. $];
    assert(original.length == 42555 && sha256Of(original).toHexString.toLower ==
        "25e0025e79f39974afceb111205f5710a32a7d82cfa95916e8249e68302997ee",
        "stat header original whole-unit control");
    auto first = wave15InputStart();
    assert(wave15RestoreSource(origin, physical, root) == original && wave15InputsIntact(first),
        "stat header exact inverse must preserve the complete original unit");
    const wrongBody = physical[0 .. $ - 1] ~ (physical[$ - 1] == ' ' ? "\n" : " ");
    foreach (invalid; [original, physical[0 .. 407] ~ header ~ physical[407 .. $], wrongBody]) {
        first = wave15InputStart();
        assert(wave15RestoreSource(origin, invalid, root).length == 0
                && !wave15InputReads[first] && !wave15InputsIntact(first),
            "stat header missing/duplicate/wrong-body input must be refused");
    }
    first = wave15InputStart();
    assert(wave15RestoreSource(origin, physical, root) == original && wave15InputsIntact(first),
        "stat header restored whole-unit control");

    const native = readText(buildPath(wave19OwnerRoot(root, "editor-ui"), wave19OwnerMoved(root, "editor-ui") ? "source/vibe3d/ui/editor/imgui_flag_abi.c" : "source/imgui_flag_abi.c"));
    first = wave15InputStart();
    assert(wave15ReadText(buildPath(root, "source/imgui_flag_abi.c")) == native
            && wave15InputsIntact(first),
        "ImportC exact compiled-root whole-file owner control");
}

unittest { // Wave19 math: real selected inputs, exact coordinates and span-only inversion.
    import std.file : mkdirRecurse, write, remove, rmdirRecurse, tempDir;
    import std.process : thisProcessID;
    static import std.file;
    const scratch = buildPath(tempDir(), "wave19-math-reader-" ~ thisProcessID.to!string);
    mkdirRecurse(scratch);
    scope(exit) rmdirRecurse(scratch);
    void put(string relative, string bytes) {
        const path = buildPath(scratch, relative);
        mkdirRecurse(dirName(path));
        write(path, bytes);
    }
    foreach (name; wave19MathModules) {
        const old = mathRelative(name, false);
        put(buildPath(wave19MathOldRoot, old),
            "module " ~ name ~ ";\n");
    }
    put("util/math/dub.json", `{"name":"vibe3d-math"}`);
    assert(!wave19MathMoved(scratch), "Wave19 math old owner positive");
    const logical = buildPath(scratch, "util/math/source/math_vector.d");
    assert(wave19MathPhysicalPath(logical, scratch) == logical,
        "Wave19 math old physical positive");
    foreach (name; wave19MathModules) {
        remove(buildPath(scratch, wave19MathOldRoot, mathRelative(name, false)));
        put(buildPath(wave19MathNewRoot, mathRelative(name, true)),
            "module vibe3d.util.math." ~ name ~ ";\n");
    }
    remove(buildPath(scratch, "util/math/dub.json"));
    put("libraries/util/math/dub.json", `{"name":"math"}`);
    assert(wave19MathMoved(scratch), "Wave19 math moved owner positive");
    const physical = buildPath(scratch,
        "libraries/util/math/source/vibe3d/util/math/math_vector.d");
    assert(wave19MathPhysicalPath(logical, scratch) == physical
        && wave19MathLogicalPath(physical, scratch) == logical,
        "Wave19 math exact forward and inverse coordinates");
    assert(wave19MathPhysicalPath(buildPath(scratch, "util/math/source"), scratch)
        == buildPath(scratch, "libraries/util/math/source"),
        "Wave19 math direct scan root translation");
    const foreign = buildPath(scratch, "foreign/util/math/source/math_vector.d");
    assert(wave19MathPhysicalPath(foreign, scratch) == foreign,
        "Wave19 math foreign coordinate remains foreign");
    foreach (name; wave19MathModules[0 .. $ - 1])
        put("libraries/util/math/source/" ~ name ~ ".d",
            "module " ~ name ~ "; public import vibe3d.util.math." ~ name ~ ";");
    put("libraries/util/math/source/vibe3d/util/math/package.d", "module vibe3d.util.math;");
    assert(wave15DirEntries(buildPath(scratch, "util/math/source"), "*.d", SpanMode.depth, true, scratch ~ "/.").length == 5,
        "Wave19 math moved logical source walk excludes six transitional inputs");
    assert(wave15DirEntries(buildPath(scratch, "util/math"), "*.d", SpanMode.depth, true, scratch ~ "/.").length == 6
        && wave15DirEntries(buildPath(scratch, "util/math/tests/source"), "*.d", SpanMode.depth, true, scratch ~ "/.").length == 1,
        "Wave19 math moved logical owner walk retains six originals including carrier");
    assert(wave15DirEntries(buildPath(scratch, "util/math/source"), "*.d", SpanMode.shallow, true, scratch ~ "/.").length == 5
        && wave15DirEntries(buildPath(scratch, "util/math/tests/source"), "*.d", SpanMode.shallow, true, scratch ~ "/.").length == 0,
        "Wave19 math moved logical shallow walk retains original layout");
    // Operation-local memoization must expire on both success and refusal.
    const sourceDirectory = buildPath(scratch, "util/math/source");
    const mathInputPath = "libraries/util/math/source/vibe3d/util/math/math_vector.d";
    put(mathInputPath, "module vibe3d.util.math.math_wector;\n"); // same-length changed input
    assertThrown!AssertError(wave19MathPhysicalPath(logical, scratch));
    assertThrown!AssertError(wave15DirEntries(sourceDirectory, "*.d", SpanMode.depth, true, scratch));
    put(mathInputPath, "module vibe3d.util.math.math_vector;\n");
    assert(wave19MathPhysicalPath(logical, scratch) == physical,
        "Wave19 reader recovers after refused source without a stale selection");
    put("libraries/util/math/dub.json", `{"name":"wrong"}`);
    assertThrown!AssertError(wave15DirEntries(sourceDirectory, "*.d", SpanMode.depth, true, scratch));
    put("libraries/util/math/dub.json", `{"name":"math"}`);
    assert(wave15DirEntries(sourceDirectory, "*.d", SpanMode.depth, true, scratch).length == 5,
        "Wave19 reader sees changed recipe and restored inputs on the next call");
    remove(physical);
    assertThrown!AssertError(wave19MathPhysicalPath(logical, scratch));
    assertThrown!AssertError(wave19MathMoved(scratch)); // shim cannot replace missing real file
    put("libraries/util/math/source/vibe3d/util/math/math_vector.d", "module wrong;");
    assertThrown!AssertError(wave19MathMoved(scratch));
    put("libraries/util/math/source/vibe3d/util/math/math_vector.d", "");
    assertThrown!AssertError(wave19MathMoved(scratch)); // missing declaration
    put("libraries/util/math/source/vibe3d/util/math/math_vector.d",
        "module vibe3d.util.math.math_vector; module vibe3d.util.math.math_vector;");
    assertThrown!AssertError(wave19MathMoved(scratch)); // duplicate matching declarations
    put("libraries/util/math/source/vibe3d/util/math/math_vector.d", "module vibe3d.util.math.math_vector;");
    put("util/math/source/math_vector.d", "module math_vector;");
    assertThrown!AssertError(wave19MathMoved(scratch));
    remove(logical);
    put("util/math/dub.json", `{"name":"vibe3d-math"}`);
    assertThrown!AssertError(wave19MathMoved(scratch));
    remove(buildPath(scratch, "util/math/dub.json"));
    put("libraries/util/math/dub.json", `{"name":"vibe3d-math"}`);
    assertThrown!AssertError(wave19MathMoved(scratch));
    put("libraries/util/math/dub.json", `{"name":"math"}`);
    assert(wave19MathMoved(scratch), "Wave19 math restored positive");

    enum expression = `enum s = import("x") ~ __traits(identifier, vibe3d.util.math.math);`;
    assert(wave19MathLogicalText(expression) == expression,
        "Wave19 math string-import expression bytes remain unchanged");
    assert(wave19MathLogicalText(expression.replace("vibe3d.util.math.math", "math")) != expression,
        "Wave19 math changed string-import body remains distinguishable");

    enum renamed = "module vibe3d.util.math.math;\n"
        ~ "public import V = vibe3d.util.math.math_vector, vibe3d.util.math.math_matrix : Vec3;\n"
        ~ "static import\n vibe3d.util.math.math_quaternion;\n"
        ~ "import /* gap */ vibe3d.util.math.math_geometry : faceNormalFirst3;\n"
        ~ "// vibe3d.util.math.math_vector\n"
        ~ "enum text = \"vibe3d.util.math.math_matrix\";\n"
        ~ "void body() { vibe3d.util.math.math_vector.Vec3 v; }\n";
    enum original = "module math;\n"
        ~ "public import V = math_vector, math_matrix : Vec3;\n"
        ~ "static import\n math_quaternion;\n"
        ~ "import /* gap */ math_geometry : faceNormalFirst3;\n"
        ~ "// vibe3d.util.math.math_vector\n"
        ~ "enum text = \"vibe3d.util.math.math_matrix\";\n"
        ~ "void body() { vibe3d.util.math.math_vector.Vec3 v; }\n";
    assert(wave19MathLogicalText(renamed) == original,
        "Wave19 math inversion limited to declaration and import spans");
    assert(wave19MathLogicalText(renamed.replace("Vec3 v", "Vec3 changed")) != original,
        "Wave19 math inversion preserves changed body bytes");
    foreach (name; wave19MathModules) {
        const path = buildPath(repoRoot, wave19MathOldRoot, mathRelative(name, false));
        const raw = std.file.readText(wave15PhysicalPath(path));
        assert(wave15ReadText(path) == wave19MathLogicalText(raw),
            "Wave19 math actual selected source reader positive: " ~ name);
    }
    const actualSources = wave15DirEntries(buildPath(repoRoot, "util/math/source"), "*.d", SpanMode.depth);
    assert(actualSources.length == 5,
        "Wave19 math original logical source population five, actual=" ~ actualSources.length.to!string);
}

unittest { // Wave19 D1: frozen real-row bijection and each complete selected owner.
    assert(wave19MathLogicalText("static import spatial = vibe3d.util.spatial.spatial;")
        == "static import spatial;", "Wave19 preserves original static module binding in import span");
    import std.file : mkdirRecurse, write, remove, rmdirRecurse, tempDir;
    import std.process : thisProcessID;
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    static import std.file;
    assert(wave19Owners.length == 56 && wave19Modules.length == 922,
        "Wave19 math+D1+D2 original owners26 / real rows158, excluding transitions");
    string frozen;
    foreach (i, row; wave19Modules) {
        frozen ~= row.owner ~ "\t" ~ row.oldPath ~ "\t" ~ row.newPath ~ "\t"
            ~ row.oldModule ~ "\t" ~ row.newModule ~ "\n";
        foreach (other; wave19Modules[i + 1 .. $])
            assert(row.oldPath != other.oldPath && row.newPath != other.newPath
                && row.oldModule != other.oldModule && row.newModule != other.newModule,
                "Wave19 frozen real source/module coordinates must be bijective");
    }
    assert(sha256Of(frozen).toHexString.toLower ==
        "417cefb1b468a8adfaa18a5d94c3ab9e066112e36f56d94d5f732f82f97ae8ca",
        "Wave19 exact frozen math+D1 real rows, including every owner/carrier");
    enum ownerPopulations = [6, 5, 6, 2, 1, 5, 1, 5, 1, 1, 1, 6, 2, 4, 4, 13, 2, 1, 3, 8, 6, 4, 59, 3, 5, 4, 22, 3, 22, 13, 10, 4, 5, 5, 6, 7, 24, 9, 26, 13, 3, 3, 4, 9, 17, 33, 11, 111, 242, 2, 3, 4, 14, 9, 45, 1];
    const scratch = buildPath(tempDir(), "wave19-d1-reader-" ~ thisProcessID.to!string);
    mkdirRecurse(scratch);
    scope(exit) rmdirRecurse(scratch);
    void put(string relative, string bytes) {
        const path = buildPath(scratch, relative);
        mkdirRecurse(dirName(path));
        write(path, bytes);
    }
    string ownerRecipe(string name, bool moved) {
        return `{"name":"` ~ (moved ? name : "vibe3d-" ~ name) ~ `"`
            ~ (name == "cli" && moved ? `,"targetName":"vibe3d-cli","targetPath":"../..","mainSourceFile":"source/vibe3d/apps/cli/main.d"` : "") ~ "}";
    }
    foreach (index, owner; wave19Owners) {
        const oldRecipe = buildPath(owner.oldRoot, "dub.json");
        const newRecipe = buildPath(owner.newRoot, "dub.json");
        size_t population;
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            ++population;
            assert(row.oldPath.canFind(owner.oldRoot ~ "/")
                && row.newPath.canFind(owner.newRoot ~ "/"),
                "Wave19 exact owner coordinate roots: " ~ owner.name);
            put(row.oldPath, "module " ~ row.oldModule ~ ";\n");
        }
        assert(population == ownerPopulations[index],
            "Wave19 frozen per-owner real population: " ~ owner.name);
        put(oldRecipe, `{"name":"vibe3d-` ~ owner.name ~ `"}`);
        assert(!wave19OwnerMoved(scratch ~ "/.", owner.name)
            && wave19OwnerRoot(scratch ~ "/.", owner.name) == buildPath(scratch, owner.oldRoot),
            "Wave19 each old owner selects normalized real inputs: " ~ owner.name);
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            const logical = buildPath(scratch, row.oldPath);
            assert(wave19PhysicalPath(logical, scratch ~ "/.") == logical,
                "Wave19 each old real file remains selected: " ~ row.oldPath);
        }
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            const logical = buildPath(scratch, row.oldPath);
            remove(logical);
            put(row.newPath, "module " ~ row.newModule ~ ";\n");
        }
        remove(buildPath(scratch, oldRecipe));
        put(newRecipe, ownerRecipe(owner.name, true));
        assert(wave19OwnerMoved(scratch ~ "/.", owner.name)
            && wave19OwnerRoot(scratch ~ "/.", owner.name) == buildPath(scratch, owner.newRoot),
            "Wave19 each moved owner selects normalized real inputs: " ~ owner.name);
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            const logical = buildPath(scratch, row.oldPath);
            const physical = buildPath(scratch, row.newPath);
            assert(wave19PhysicalPath(logical, scratch ~ "/.") == physical
                && wave19PhysicalPath(physical, scratch ~ "/.") == physical
                && wave19LogicalPath(physical, scratch ~ "/.") == logical,
                "Wave19 each real coordinate round trip: " ~ row.oldPath);
            const foreign = buildPath(scratch, "foreign", row.oldPath);
            assert(wave19PhysicalPath(foreign, scratch) == foreign,
                "Wave19 foreign owner prefix is never a coordinate: " ~ row.oldPath);
            enum body = "// original body comment\nenum protocol = \"vibe3d.util.log.log\";\n"
                ~ "void body() { vibe3d.util.log.log.writeln(); }\n";
            const renamed = "module " ~ row.newModule ~ ";\npublic import A = "
                ~ row.newModule ~ ";\n" ~ body;
            const original = "module " ~ row.oldModule ~ ";\npublic import A = "
                ~ row.oldModule ~ ";\n" ~ body;
            assert(wave19MathLogicalText(renamed) == original
                && wave19MathLogicalText(renamed.replace("body()", "changed()")) != original,
                "Wave19 each module/import token inverse preserves body bytes: " ~ row.oldPath);
            // Omit every real row in turn; an old-import shim remains present.
            const shim = buildPath(owner.newRoot, "source", row.oldModule.replace(".", "/") ~ ".d");
            put(shim, "module " ~ row.oldModule ~ "; public import " ~ row.newModule ~ ";\n");
            remove(physical);
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            put(row.newPath, "module wrong;\n");
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            put(row.newPath, "// no module declaration\n");
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            put(row.newPath, "module " ~ row.newModule ~ "; module " ~ row.newModule ~ ";\n");
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            foreach (second; ["wrong . name", "wrong/*gap*/.name", "имя . name",
                    row.newModule.replace(".", " . "), row.newModule.replace(".", "/*gap*/.")]) {
                put(row.newPath, "module " ~ row.newModule ~ "; module " ~ second ~ ";\n");
                assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            }
            const decoys = "// module wrong . name;\n/+ module wrong/*gap*/.name; +/\n"
                ~ "enum a = \"module wrong . name;\";\n"
                ~ "enum b = q{ module wrong/*gap*/.name; };\n"
                ~ "enum moduleимя = 0;\n";
            put(row.newPath, "module " ~ row.newModule ~ ";\n" ~ decoys);
            assert(wave19OwnerMoved(scratch, owner.name),
                "Wave19 spaced/comment declaration decoys leave selected code identity: " ~ row.oldPath);
            put(row.newPath, decoys);
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            put(row.newPath, "module " ~ row.newModule ~ ";\n");
            put(row.oldPath, "module " ~ row.oldModule ~ ";\n");
            assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
            remove(logical);
        }
        foreach (suffix; ["", "/source", "/tests", "/tests/source"])
            assert(wave19PhysicalPath(buildPath(scratch, owner.oldRoot) ~ suffix, scratch ~ "/.")
                == buildPath(scratch, owner.newRoot) ~ suffix,
                "Wave19 each direct scan root translated: " ~ owner.name ~ suffix);
        assert(wave15DirEntries(buildPath(scratch, owner.oldRoot), "*.d", SpanMode.depth, true, scratch ~ "/.").length
            == ownerPopulations[index],
            "Wave19 each logical owner walk excludes transitional shims: " ~ owner.name);
        import std.path : relativePath, isAbsolute;
        import std.array : array;
        const absoluteDirectory = buildPath(scratch, owner.oldRoot);
        const relativeDirectory = relativePath(absoluteDirectory, wave15Normalize("."));
        foreach (directory; [absoluteDirectory, absoluteDirectory ~ "/.",
                relativeDirectory, relativeDirectory ~ "/."]) {
            string[] actualNames, expectedNames;
            foreach (entry; wave15DirEntries(directory, "*.d", SpanMode.depth, true, scratch ~ "/."))
                actualNames ~= entry.name;
            foreach (row; wave19Modules) if (row.owner == owner.name) {
                const absoluteName = buildPath(scratch, row.oldPath);
                expectedNames ~= isAbsolute(directory) ? absoluteName
                    : relativePath(absoluteName, wave15Normalize("."));
            }
            assert(actualNames.sort().array == expectedNames.sort().array,
                "Wave19 directory entries retain relative/absolute logical spelling: " ~ owner.name ~ " " ~ directory);
        }
        put(oldRecipe, `{"name":"vibe3d-` ~ owner.name ~ `"}`);
        assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
        remove(buildPath(scratch, oldRecipe));
        remove(buildPath(scratch, newRecipe));
        assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
        put(newRecipe, `{"name":"vibe3d-` ~ owner.name ~ `"}`);
        assertThrown!AssertError(wave19OwnerMoved(scratch, owner.name));
        put(newRecipe, ownerRecipe(owner.name, true));
        assert(wave19OwnerMoved(scratch, owner.name), "Wave19 each restored owner positive: " ~ owner.name);
        if (owner.name == "cli") {
            import std.json : parseJSON, JSONValue;
            foreach (field; ["targetName", "targetPath", "mainSourceFile"]) {
                auto recipe = parseJSON(ownerRecipe(owner.name, true));
                recipe[field] = JSONValue("wrong");
                put(newRecipe, recipe.toString());
                string refusal;
                try { wave19PhysicalPath(buildPath(scratch, "tools/cli/source/main.d"), scratch); }
                catch (AssertError error) { refusal = error.msg; }
                assert(refusal.canFind("Wave19 CLI output/source root identity"),
                    "Wave19 CLI actual coordinate caller rejects each output/source term: " ~ field ~ " " ~ refusal);
                put(newRecipe, ownerRecipe(owner.name, true));
            }
        }
        // Exercise every selected actual root/carrier, independent of the scratch fixture.
        foreach (row; wave19Modules) {
            if (row.owner != owner.name) continue;
            const logical = wave15Normalize(buildPath(repoRoot, row.oldPath));
            const physical = wave19PhysicalPath(logical);
            assert(wave19LogicalPath(physical) == logical
                && wave19MathLogicalText(std.file.readText(physical)).canFind("module " ~ row.oldModule ~ ";"),
                "Wave19 actual selected real source/carrier reaches original module: " ~ row.oldPath);
        }
    }
    // Virtual nested-directory predicates agree with the existing member walk.
    foreach (relative; ["packages/editor-commands/source/commands/mesh",
            "packages/command-runtime/source/commands/mesh",
            "util/math/tests/source/tests/unit"]) {
        const directory = buildPath(repoRoot, relative);
        assert(wave15DirEntries(directory, "*.d", SpanMode.shallow).length != 0
            && wave15Exists(directory) && wave15IsDir(directory),
            "Wave19 nested logical directory remains discoverable: " ~ relative);
        assert(!wave15Exists(directory ~ "/not-a-real-directory")
            && !wave15IsDir(directory ~ "/not-a-real-directory"),
            "Wave19 unlisted directory must remain absent");
    }
    // Bounded new role controls remain in the original all-owner cell.
    import std.json : parseJSON, JSONValue;
    string[] desktopPeers;
    foreach (key; ["source/commands/mesh/magnet.d", "source/commands/mesh/morph.d",
            "source/commands/mesh/remesh.d", "source/commands/file/load.d",
            "source/commands/file/save.d", "source/ui/viewport_render.d"])
        foreach (row; wave19Modules)
            if (row.owner == "desktop" && row.oldPath == key) desktopPeers ~= row.newPath;
    assert(desktopPeers.length == 6, "Wave19 six desktop role controls");
    void refusedRole(string path, string reason) {
        string refusal;
        try { wave19PhysicalPath(path, scratch); }
        catch (AssertError error) { refusal = error.msg; }
        catch (Throwable error) {
            assert(false, "Wave19 role caller unexpected interception: " ~ reason ~ " "
                ~ error.classinfo.name ~ " " ~ error.msg);
        }
        assert(refusal.canFind(reason), "Wave19 role caller named refusal: " ~ reason ~ " " ~ refusal);
    }
    foreach (stage; [0, 3, 6, 79]) {
        const finalState = stage == 79;
        auto recipe = parseJSON(finalState
            ? `{"name":"vibe3d","sourcePaths":["apps/desktop/source"],"mainSourceFile":"apps/desktop/source/vibe3d/apps/desktop/app.d","sourceFiles":[],"importPaths":["apps/desktop/source"]}`
            : `{"name":"vibe3d","sourcePaths":["source"],"mainSourceFile":"source/app.d","sourceFiles":[],"importPaths":[]}`);
        if (!finalState && stage != 0) {
            recipe["sourceFiles"] = JSONValue(desktopPeers[0 .. stage]);
            recipe["importPaths"] = JSONValue(["apps/desktop/source"]);
        }
        const selectedRecipe = recipe.toString();
        put("dub.json", selectedRecipe);
        size_t population, selectedCount;
        foreach (row; wave19Modules) {
            if (row.owner != "desktop") continue;
            ++population;
            foreach (relative; [row.oldPath, row.newPath])
                if (std.file.exists(buildPath(scratch, relative))) remove(buildPath(scratch, relative));
            const selected = finalState || desktopPeers[0 .. (finalState ? 0 : stage)].canFind(row.newPath);
            if (selected) ++selectedCount;
            put(selected ? row.newPath : row.oldPath,
                "module " ~ (selected ? row.newModule : row.oldModule) ~ ";\n");
        }
        assert(population == 79 && selectedCount == stage,
            "Wave19 desktop four selected populations0/3/6/79");
        foreach (key; ["source/commands/mesh/magnet.d", "source/editor_app.d"]) {
            Wave19Module target;
            size_t hits;
            foreach (row; wave19Modules) if (row.oldPath == key) { target = row; ++hits; }
            assert(hits == 1, "Wave19 exact desktop target fixture");
            const selected = finalState || desktopPeers[0 .. (finalState ? 0 : stage)].canFind(target.newPath);
            const path = buildPath(scratch, target.oldPath);
            assert(wave19PhysicalPath(path, scratch) == buildPath(scratch, selected ? target.newPath : target.oldPath)
                && wave19TargetMoved(scratch, target.oldPath) == selected,
                "Wave19 actual desktop row/target caller distinguishes unrelated peer selection");
            foreach (field; ["name", "sourcePaths", "mainSourceFile", "sourceFiles", "importPaths"]) {
                if (field == "importPaths" && stage == 0) continue;
                recipe = parseJSON(selectedRecipe);
                string reason;
                if (field == "name") { recipe[field] = JSONValue("other"); reason = "Wave19 root application identity"; }
                else if (field == "sourcePaths") { recipe[field] = JSONValue(["source", "apps/desktop/source"]); reason = "Wave19 desktop selected root coordinates"; }
                else if (field == "mainSourceFile") { recipe[field] = JSONValue("wrong.d"); reason = "Wave19 desktop selected root coordinates"; }
                else if (field == "sourceFiles") { recipe[field] = JSONValue(desktopPeers[0 .. 1]); reason = "Wave19 incomplete/duplicate coupled desktop peer stage"; }
                else { recipe[field] = JSONValue(["source"]); reason = "Wave19 selected desktop import root"; }
                put("dub.json", recipe.toString());
                refusedRole(path, reason);
                put("dub.json", selectedRecipe);
            }
            if (!finalState) foreach (position; 0 .. 3) {
                auto sources = desktopPeers[0 .. 3].dup;
                sources[position] = desktopPeers[3];
                recipe = parseJSON(selectedRecipe);
                recipe["sourceFiles"] = JSONValue(sources);
                put("dub.json", recipe.toString());
                refusedRole(path, "Wave19 incomplete/duplicate coupled desktop peer stage");
                put("dub.json", selectedRecipe);
            }
            foreach (sources; [[desktopPeers[0], desktopPeers[0]], ["outside.d"]]) {
                recipe = parseJSON(selectedRecipe);
                recipe["sourceFiles"] = JSONValue(sources);
                put("dub.json", recipe.toString());
                refusedRole(path, sources.length == 2 ? "Wave19 duplicate root explicit source"
                    : "Wave19 unauthorized root explicit desktop source");
                put("dub.json", selectedRecipe);
            }
            const physical = selected ? target.newPath : target.oldPath;
            const opposite = selected ? target.oldPath : target.newPath;
            const saved = std.file.readText(buildPath(scratch, physical));
            remove(buildPath(scratch, physical));
            refusedRole(path, "Wave19 desktop missing/duplicate real source:");
            put(physical, saved);
            put(opposite, saved);
            refusedRole(path, "Wave19 desktop missing/duplicate real source:");
            remove(buildPath(scratch, opposite));
            remove(buildPath(scratch, physical));
            mkdirRecurse(buildPath(scratch, physical));
            refusedRole(path, "Wave19 desktop missing/duplicate real source:");
            rmdirRecurse(buildPath(scratch, physical));
            foreach (malformed; ["module wrong;\n", "module malformed\n", saved ~ "module wrong;\n"]) {
                put(physical, malformed);
                refusedRole(path, "Wave19 exact referenced target declaration");
            }
            put(physical, saved);
        }
        // The early6 viewport access operand follows its referenced module,
        // independently of the still-old containing desktop root.
        foreach (identity; wave19Identities) if (identity.id == "ID394") {
            const selected = stage == 6 || stage == 79;
            const raw = identity.anchor[0 .. identity.offset]
                ~ (selected ? identity.newText : identity.oldText)
                ~ identity.anchor[identity.offset + identity.oldText.length .. $] ~ "\n";
            assert(wave19IdentityLogicalText(raw, buildPath(scratch, identity.path), scratch)
                == identity.anchor ~ "\n", "Wave19 early6 referenced viewport identity caller positive");
            const wrong = identity.anchor[0 .. identity.offset]
                ~ (selected ? identity.oldText : identity.newText)
                ~ identity.anchor[identity.offset + identity.oldText.length .. $] ~ "\n";
            string refusal;
            try { wave19IdentityLogicalText(wrong, buildPath(scratch, identity.path), scratch); }
            catch (AssertError error) { refusal = error.msg; }
            assert(refusal.canFind("Wave19 raw approved identity anchor: ID394"),
                "Wave19 early6 referenced viewport identity caller refuses wrong state: " ~ refusal);
        }
        // Stationary host declarations follow their library, whose state is
        // already selected, while desktop0/3/6/79 changes independently.
        size_t hostControls;
        foreach (row; wave19Modules) if (row.owner == "desktop-tests") {
            ++hostControls;
            put(row.oldPath, "module " ~ row.newModule ~ ";\n");
            assert(wave19PhysicalPath(buildPath(scratch, row.oldPath), scratch) == buildPath(scratch, row.oldPath)
                && wave19TargetMoved(scratch, row.oldPath), "Wave19 stationary host follows selected library");
            put(row.oldPath, "module " ~ row.oldModule ~ ";\n");
            refusedRole(buildPath(scratch, row.oldPath), "Wave19 exact referenced target declaration");
            put(row.oldPath, "module " ~ row.newModule ~ ";\n");
        }
        assert(hostControls == 5, "Wave19 five stationary host role controls");
    }
    // Approved460-inventory full:460 raw live operands, same original cell.
    string identityFixture(string path, bool moved, bool literalContext = true) {
        string result;
        bool[string] seen;
        foreach (row; wave19Identities) {
            if (row.path != path || row.anchor in seen) continue;
            seen[row.anchor] = true;
            string line;
            size_t cursor;
            foreach (member; wave19Identities) {
                if (member.path != path || member.anchor != row.anchor) continue;
                line ~= row.anchor[cursor .. member.offset]
                    ~ (moved ? member.newText : member.oldText);
                cursor = member.offset + member.oldText.length;
            }
            line ~= row.anchor[cursor .. $];
            result ~= row.literal && literalContext ? "enum payload" ~ seen.length.to!string
                ~ " = q{\n" ~ line ~ "\n};\n" : line ~ "\n";
        }
        return result;
    }
    // Existing fixture is fully moved at this point. Rebuild its finite real
    // rows in each state; no shim can replace a referenced real definition.
    foreach (moved; [false, true]) {
        put("dub.json", moved
            ? `{"name":"vibe3d","sourcePaths":["apps/desktop/source"],"mainSourceFile":"apps/desktop/source/vibe3d/apps/desktop/app.d","sourceFiles":[],"importPaths":["apps/desktop/source"]}`
            : `{"name":"vibe3d","sourcePaths":["source"],"mainSourceFile":"source/app.d","sourceFiles":[],"importPaths":[]}`);
        foreach (owner; wave19Owners) {
            foreach (root; [owner.oldRoot, owner.newRoot]) {
                const recipe = buildPath(scratch, root, "dub.json");
                if (std.file.exists(recipe)) remove(recipe);
            }
            put(buildPath(moved ? owner.newRoot : owner.oldRoot, "dub.json"),
                ownerRecipe(owner.name, moved));
        }
        foreach (row; wave19Modules) {
            foreach (relative; [row.oldPath, row.newPath]) {
                const physical = buildPath(scratch, relative);
                if (std.file.exists(physical)) remove(physical);
            }
            put(moved ? row.newPath : row.oldPath,
                "module " ~ (moved ? row.newModule : row.oldModule) ~ ";\n");
        }
        bool[string] seen;
        foreach (row; wave19Identities) {
            if (row.path in seen) continue;
            seen[row.path] = true;
            const path = buildPath(scratch, row.path);
            const good = identityFixture(row.path, moved);
            const original = identityFixture(row.path, false);
            assert(wave19IdentityLogicalText(good, path, scratch) == original,
                "Wave19 approved raw identity inverse in both owner states: " ~ row.path);
            assert(wave19IdentityLogicalText(good ~ "// body delta\n", path, scratch)
                == original ~ "// body delta\n", "Wave19 approved identity preserves outside body");
            assertThrown!AssertError(wave19IdentityLogicalText(identityFixture(row.path, !moved), path, scratch));
            assertThrown!AssertError(wave19IdentityLogicalText(good ~ good, path, scratch));
            assertThrown!AssertError(wave19IdentityLogicalText("/*\n" ~ good ~ "\n*/\n", path, scratch));
        }
        if (moved) {
            void rejectedIdentity(string raw, string relative, string reason) {
                string refusal;
                try { wave19IdentityLogicalText(raw, buildPath(scratch, relative), scratch); }
                catch (AssertError error) { refusal = error.msg; }
                assert(refusal.canFind(reason), "Wave19 named raw identity guard refusal: " ~ reason ~ " " ~ refusal);
            }
            enum codePath = "tests/unit/mesh_thicken_surface_test.d";
            const code = identityFixture(codePath, true);
            rejectedIdentity("X" ~ code, codePath, "Wave19 approved complete anchor:");
            rejectedIdentity(code[0 .. $ - 1] ~ " X\n", codePath, "Wave19 approved complete anchor:");
            rejectedIdentity("enum payload = q{\n" ~ code ~ "\n};\n", codePath,
                "Wave19 raw approved identity lexical kind:");
            enum payloadPath = "tests/unit/version_gate_census_ai3d_remesh_test.d";
            rejectedIdentity(identityFixture(payloadPath, true, false), payloadPath,
                "Wave19 raw approved identity lexical kind:");
            size_t referencedControls;
            foreach (identity; wave19Identities) {
                if (identity.id != "ID006") continue;
                ++referencedControls;
                const target = wave19PhysicalPath(buildPath(scratch, identity.target), scratch);
                const saved = std.file.readText(target);
                write(target, "module wrong;\n");
                rejectedIdentity(identityFixture(identity.path, true), identity.path,
                    "Wave19 real module identity:");
                write(target, saved);
            }
            assert(referencedControls == 1, "Wave19 referenced-target raw guard control population");
            // Full selected source reaches the production read/guard/inverse
            // chain; a duplicate raw anchor leaves the module declaration real.
            size_t callerControls;
            foreach (row; wave19Modules) {
                if (row.oldPath != "packages/camera-model/tests/source/tests/unit/camera_model_population_test.d") continue;
                ++callerControls;
                const path = buildPath(scratch, row.oldPath);
                const raw = std.file.readText(wave19PhysicalPath(buildPath(repoRoot, row.oldPath)));
                put(row.newPath, raw);
                assert(wave19ReadCurrent(path, scratch).canFind("module " ~ row.oldModule ~ ";"),
                    "Wave19 read-current selected source reaches original module");
                put(row.newPath, raw ~ "\n" ~ identityFixture(row.oldPath, true));
                string refusal;
                try { wave19ReadCurrent(path, scratch); }
                catch (AssertError error) { refusal = error.msg; }
                assert(refusal.canFind("Wave19 raw approved identity anchor:"),
                    "Wave19 read-current named raw identity refusal before syntax inverse: " ~ refusal);
                put(row.newPath, raw);
            }
            assert(callerControls == 1, "Wave19 read-current raw caller control population");
            size_t locatorControls;
            foreach (locator; wave19Locators) {
                if (locator.id != "L05-oblique-root-fixture"
                    && locator.id != "L01-align-owner-fixture" && locator.id != "L06-ai3d-dev-script") continue;
                ++locatorControls;
                const path = buildPath(scratch, locator.path);
                const physical = wave19PhysicalPath(path, scratch);
                const raw = std.file.readText(wave19PhysicalPath(buildPath(repoRoot, locator.path)));
                write(physical, raw);
                const original = wave19ReadCurrent(path, scratch);
                assert(original.canFind(locator.oldText)
                    && !original.canFind(locator.newText),
                    "Wave19 locator actual read caller reaches historical whole-expression inverse");
                if (locator.id == "L01-align-owner-fixture" || locator.id == "L06-ai3d-dev-script") {
                    import std.digest.sha : sha256Of;
                    import std.digest : toHexString;
                    import std.string : toLower;
                    const expected = locator.id == "L01-align-owner-fixture"
                        ? "0d41d5ccca2c3f8d29303911dac9bb6c0da431c91ead04fdfed61a71dde82ebf"
                        : "a7a6881daaa2107d7a38f8618cc577997fa60cc0500001c9e50c706255db9a70";
                    assert(sha256Of(original).toHexString.toLower == expected,
                        "Wave19 locator actual complete-file inverse: " ~ locator.id);
                }
                void rejectedLocator(string changed, string reason) {
                    write(physical, changed);
                    string refusal;
                    try { wave19ReadCurrent(path, scratch); }
                    catch (AssertError error) { refusal = error.msg; }
                    assert(refusal.canFind(reason),
                        "Wave19 locator caller guard precedes syntax/identity inverse: " ~ reason ~ " " ~ refusal);
                }
                rejectedLocator(raw.replace(locator.newText, "0"), "Wave19 raw whole locator: " ~ locator.id);
                if (locator.id == "L05-oblique-root-fixture")
                    rejectedLocator(raw.replace(locator.newText, locator.newText.replace("kFixtureName", "wrongFixture")),
                        "Wave19 raw whole locator: " ~ locator.id);
                else {
                    rejectedLocator(raw.replace(locator.newText, locator.newText.replace("buildNormalizedPath, ", "").replace(
                        "        import std.path : buildNormalizedPath;\n", "")), "Wave19 raw whole locator: " ~ locator.id);
                    rejectedLocator(raw.replace("buildNormalizedPath(__FILE_FULL_PATH__)", "__FILE_FULL_PATH__"),
                        "Wave19 raw whole locator: " ~ locator.id);
                    rejectedLocator(raw.replace("buildNormalizedPath(__FILE_FULL_PATH__)",
                        "dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__)))"), "Wave19 raw whole locator: " ~ locator.id);
                }
                rejectedLocator(raw ~ "\n" ~ locator.newText ~ "\n", "Wave19 raw whole locator: " ~ locator.id);
                rejectedLocator(raw.replace(locator.newText, "/*" ~ locator.newText ~ "*/"),
                    "Wave19 raw locator lexical kind: " ~ locator.id);
                rejectedLocator(raw.replace(locator.newText, "`" ~ locator.newText ~ "`"),
                    "Wave19 raw locator lexical kind: " ~ locator.id);
                rejectedLocator(raw.replace(locator.newText, locator.oldText), "Wave19 raw whole locator: " ~ locator.id);
                write(physical, raw);
            }
            assert(locatorControls == 3, "Wave19 bounded actual locator caller control population");
            // The literal production blocks bind arithmetic to raw custody;
            // cancellation happens before the unchanged ancestor chain.
            {
                enum block = q"BLOCK
    import std.path : buildNormalizedPath, buildPath, dirName;
    enum root = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__)))))))));
BLOCK"[0 .. $ - 1];
                size_t bound;
                foreach (locator; wave19Locators) if (locator.id == "L01-align-owner-fixture") {
                    ++bound;
                    assert(locator.newText == block, "Wave19 arithmetic exact raw block: l01");
                }
                assert(bound == 1, "Wave19 arithmetic raw block population: l01");
                static foreach (spelling; ["/wave19/libraries/editing/tools/alignment/source/vibe3d/editing/tools/alignment/tools/alignment/align_kernels.d",
                    "/wave19/libraries/editing/tools/alignment/tests/../source/vibe3d/editing/tools/alignment/tools/alignment/align_kernels.d",
                    "/wave19/./libraries/editing/tools/alignment/tests/../source/vibe3d/editing/tools/alignment/tools/alignment/align_kernels.d"]) {{
                    mixin(block.replace("__FILE_FULL_PATH__", "\"" ~ spelling ~ "\""));
                    assert(root == "/wave19/libraries/editing/tools/alignment", "Wave19 normalized source arithmetic: l01");
                }}
            }
            {
                enum block = q"BLOCK
        import std.path : buildNormalizedPath;
        enum repoRoot = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(buildNormalizedPath(__FILE_FULL_PATH__))))))))));
BLOCK"[0 .. $ - 1];
                size_t bound;
                foreach (locator; wave19Locators) if (locator.id == "L06-ai3d-dev-script") {
                    ++bound;
                    assert(locator.newText == block, "Wave19 arithmetic exact raw block: l06");
                }
                assert(bound == 1, "Wave19 arithmetic raw block population: l06");
                static foreach (spelling; ["/wave19/libraries/runtime/ai3d/source/vibe3d/runtime/ai3d/ai3d/worker_manager.d",
                    "/wave19/libraries/runtime/ai3d/tests/../source/vibe3d/runtime/ai3d/ai3d/worker_manager.d",
                    "/wave19/./libraries/runtime/ai3d/tests/../source/vibe3d/runtime/ai3d/ai3d/worker_manager.d"]) {{
                    mixin(block.replace("__FILE_FULL_PATH__", "\"" ~ spelling ~ "\""));
                    assert(repoRoot == "/wave19", "Wave19 normalized source arithmetic: l06");
                }}
            }
            size_t oldLocatorControls;
            foreach (locator; wave19Locators) {
                if (locator.id != "L02-pen-owner-fixture"
                    && locator.id != "L01-align-owner-fixture" && locator.id != "L06-ai3d-dev-script") continue;
                ++oldLocatorControls;
                // Reconstruct the legitimate original body through the actual
                // historical read seam, then select the complete old owner.
                const oldSource = wave19ReadCurrent(buildPath(repoRoot, locator.path));
                assert(oldSource.canFind(locator.oldText), "Wave19 old __FILE__ locator body control");
                foreach (owner; wave19Owners) if (owner.name == locator.owner) {
                    remove(buildPath(scratch, owner.newRoot, "dub.json"));
                    put(buildPath(owner.oldRoot, "dub.json"), ownerRecipe(owner.name, false));
                }
                foreach (row; wave19Modules) if (row.owner == locator.owner) {
                    remove(buildPath(scratch, row.newPath));
                    put(row.oldPath, "module " ~ row.oldModule ~ ";\n");
                }
                const path = buildPath(scratch, locator.path);
                write(path, oldSource);
                assert(wave19ReadCurrent(path, scratch) == oldSource,
                    "Wave19 old __FILE__ locator actual caller preserves unmoved complete body");
                foreach (commented; [true, false]) {
                    write(path, oldSource.replace(locator.oldText,
                        commented ? "/*" ~ locator.oldText ~ "*/" : locator.newText));
                    string refusal;
                    try { wave19ReadCurrent(path, scratch); }
                    catch (AssertError error) { refusal = error.msg; }
                    assert(refusal.canFind(commented ? "Wave19 raw locator lexical kind: " ~ locator.id
                                                   : "Wave19 raw whole locator: " ~ locator.id),
                        "Wave19 old __FILE__ locator caller refuses comment/wrong-current state: " ~ refusal);
                }
                write(path, oldSource);
            }
            assert(oldLocatorControls == 3, "Wave19 bounded old __FILE__ locator caller population");


        }
    }
    assertThrown!AssertError(wave19OwnerMoved(scratch, "unselected-owner"));
    assertThrown!AssertError(wave19OwnerRoot(scratch, "unselected-owner"));
}
