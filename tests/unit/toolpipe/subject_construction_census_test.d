// Task 1904 Stage 6 (doc/subject_stage_plan.md §6) — the census: "no site
// decides what the subject is" outside source/toolpipe/subject.d.
//
// WHAT THE CONTRACT IS. Before this task, ~15 call sites in 7 files each
// hand-decided what "the subject" is (which Mesh*, which editMode, which
// selType, which viewport, whether a cursor is valid). Stages 0-5 routed
// every one of them through `toolpipe.subject : fillSubject` /
// `evaluateSubject`. This file is the executable check that a future edit
// cannot silently re-open one of those sites, and that the funnel stays the
// single caller of `Pipeline.evaluate` outside `toolpipe/pipeline.d`.
//
// WHY FIELD ASSIGNMENT, NOT DECLARATION. `SubjectPacket subj;` at a call
// site is STORAGE, not a decision — `VectorStack` (source/operator.d) holds
// raw pointers into caller-owned frames, and the pipe is genuinely
// re-entered while an outer stack is alive (plan §2, hazard R1;
// `source/toolpipe/subject.d`'s header comment). So "no `SubjectPacket(`
// outside subject.d" is unreachable AND wrong: `SubjectPacket subj;`
// declarations must keep existing at every migrated call site. What must
// NOT exist outside `subject.d` is an assignment to one of `subj`'s fields
// — `subj.mesh = ...`, `subj.selType = ...`, etc. — since that is the
// actual "what is the subject" decision.
//
// WHAT THIS SCANNER SEES, EXACTLY (assertion a):
//   * within one file, every name declared as `SubjectPacket <name>`
//     (bare local/field, or `out SubjectPacket <name>` / `in SubjectPacket
//     <name>` parameter — any leading storage-class keyword, since the scan
//     only requires "SubjectPacket" immediately followed by an optional `*`
//     then an identifier then one of `; = , )`);
//   * for every such name, any later `<name>.<field> =` (a single `=`, not
//     `==`) where `<field>` is one of SubjectPacket's mutable fields, at
//     ANY scope EXCEPT inside a `unittest { }` body.
//
// WHAT IT DOES NOT SEE, stated so nobody mistakes it for the whole
// contract: a `SubjectPacket` reached through a pointer obtained from
// `vts.get!SubjectPacket()` (an `auto`-typed pointer never matches the
// `SubjectPacket <name>` declarator this scanner looks for — deliberately:
// those sites are READERS, e.g. `commands/mesh/transform.d ::
// MeshTransform.evaluate`, not the decision this contract guards); a name
// collected in one function scope is treated as "known" for the whole
// file, so a same-named `SubjectPacket` local in a different, unrelated
// function is covered by the same allow/deny decision (a conservative
// simplification in the SAME direction as `mark_view_field_guard_test.d`'s
// stated limits — it can only ever ADD false positives, never hide a real
// violation); a field reached through an alias or a template parameter.
// Also unseen: whole-struct assignment (`subj = SubjectPacket(...)` /
// `subj = other`) or a write through `*p = SubjectPacket(...)`, neither of
// which is a `<name>.<field> =` shape; `with (subj) { mesh = ...; }`,
// where the field write carries no `subj.` prefix at all; and
// `subj.tupleof[i] = ...`, an indexed write the field-name scanner does
// not recognise as touching `mesh`/`selType`/etc. Those remain review
// matters.
//
// `with (subj) { mesh = ...; }` LEFT THAT LIST at task 2007. The sweep
// proved the hole live — `with (subj) { mesh = hideBatchMesh; }` planted
// straight after `SubjectPacket subj;` in `source/command.d`, census green
// at the same module count — and `withSubjectOf` + `scanFieldAssignments`'
// `withStack` now cover both the braced and the braceless single-statement
// form. A bare field name is counted ONLY inside a `with` bound to a name
// this file already recognises as a `SubjectPacket`, and only when it is
// not itself a dotted receiver's field, so the arm cannot fire on unrelated
// code. `subj.tupleof[i] = ...` and the alias/template routes are still
// review matters.
//
// Two more holes worth stating plainly because they read as exclusions
// but are not: `version (unittest) { }` blocks are NOT excluded (only
// a literal `unittest { }` body is — see "WHY FIELD ASSIGNMENT" above),
// and an attributed head such as `@safe unittest {` is also NOT excluded,
// since `head.strip == "unittest"` fails to match "@safe unittest". Both
// can only make the scanner see MORE than production code actually
// contains (a false positive inside test-only code), never hide a real
// violation. And `q{ ... }` D token strings are not stripped by
// `stripCommentsAndStrings` (it only knows `//`, `/* */`, `/+ +/`, `"`,
// `` ` ``, `'`) — harmless today because the only files using them
// (`source/gpu_select.d`, `source/shader.d`, `source/subpatch_osd.d`, all
// GLSL source literals) declare no `SubjectPacket`.
//
// Assertion (a)'s scope is `source/**` only — a hand-built subject in
// `tests/**` or `tools/**` is invisible to this census by design; those
// are not the production call sites the contract guards.
//
// Assertion (b): `pipeline.evaluate(` (the literal substring, case-
// sensitive, comments/strings stripped) appears in `source/**` at most
// once — inside `evaluateSubject` (plan §5: `Pipeline.evaluate` is itself
// declared `void evaluate(ref VectorStack vts)`, never spelled
// `pipeline.evaluate(`, so the count this scanner is proving is 1, not 2).
// It is a TEXTUAL guard, not a call-graph one: `g_pipeCtx.pipeline
// .evaluate(` (whitespace before the dot) or an alias (`auto pl =
// g_pipeCtx.pipeline; ...; pl.evaluate(...)`) contains no literal
// `pipeline.evaluate(` substring and slips past uncounted.
//
// Assertion (c): the two workplane pickers (plan §1.3a) —
// `create_common.d :: pickWorkplane` / `:: pickWorkplaneFrame` — reach the
// funnel through `viewOnlySubject(` and contain no four-argument
// `SubjectSource(` literal. The frozen constant itself is pinned by
// `tests/unit/toolpipe/view_only_subject_pin_test.d`; this is the call-site
// half — a future edit that inlines `SubjectSource(null, EditMode.Vertices,
// currentSelType(...), vp)` at either site is named by file and function.
//
// Shape and precedent: modelled on `tests/unit/mark_view_field_guard_test.d`
// — comment/string-stripping scanner, a `Violation` struct, a repo root
// derived the same way, a non-vacuity floor, and (here) a POSITIVE control:
// the census must SEE the nine field assignments inside `subject.d` itself
// (before the allowlist excludes them from the "outside" count) — a
// scanner that finds nothing there cannot be trusted to find anything
// anywhere else.
module tests.unit.toolpipe.subject_construction_census_test;

import std.algorithm : canFind;
import std.array     : appender, join;
import std.ascii     : isAlphaNum, isWhite;
import std.file      : dirEntries, exists, isDir, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf, strip;
import std.traits    : FieldNameTuple;

import toolpipe.packets : SubjectPacket;
import tests.unit.census_symbols : stripCommentsAndStrings = blankNonCode;

// ---------------------------------------------------------------------------
// Shared low-level scan: comments and string/char literals are replaced by
// same-length whitespace (newlines preserved), so every later scan runs on
// a text whose byte offsets — and therefore line numbers — line up exactly
// with the original source, and can never be fooled by a comment or a
// string literal that happens to contain code-shaped text.
// ---------------------------------------------------------------------------

private bool isIdentChar(char c) { return isAlphaNum(c) || c == '_'; }

private void skipWs(string s, ref size_t i) {
    while (i < s.length && isWhite(s[i])) i++;
}

private size_t lineAt(string src, size_t pos) {
    size_t line = 1;
    foreach (i; 0 .. pos) if (i < src.length && src[i] == '\n') line++;
    return line;
}

private string lineTextAt(string src, size_t p) {
    size_t a = p;
    while (a > 0 && src[a - 1] != '\n') a--;
    size_t b = p;
    while (b < src.length && src[b] != '\n') b++;
    return src[a .. b].strip;
}

/// Does the identifier `word` occur at `s[p .. p+word.length]` as a whole
/// word (not part of a longer identifier on either side)?
private bool wordAt(string s, size_t p, string word) {
    if (p + word.length > s.length) return false;
    if (s[p .. p + word.length] != word) return false;
    if (p > 0 && isIdentChar(s[p - 1])) return false;
    immutable size_t after = p + word.length;
    if (after < s.length && isIdentChar(s[after])) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Assertion (a) — SubjectPacket field-assignment scanner.
// ---------------------------------------------------------------------------

// Derived from the struct itself (`FieldNameTuple`), not hand-transcribed
// — a field added to `SubjectPacket` later is picked up here automatically
// instead of being invisible to both the scanner and the `== 9` positive
// control below, which now cross-checks this count independently rather
// than being the only thing keeping it honest.
private enum string[] subjectFields = [FieldNameTuple!SubjectPacket];

struct FieldAssignment {
    size_t line;
    string varName;
    string fieldName;
    string text;
}

/// Collect every name declared as `SubjectPacket <name>` in `stripped`
/// (module-wide, not scope-aware — see the file header's "WHAT IT DOES NOT
/// SEE"). Matches a bare declarator (`SubjectPacket subj;`), an
/// initialised one (`SubjectPacket subj = ...`), and an `out`/`in`/`ref`
/// parameter (`out SubjectPacket subj,` / `...subj)`); rejects a template
/// call (`get!SubjectPacket()`, where the char after the identifier is
/// `(`, never in the accepted delimiter set).
private bool[string] declaredSubjectPacketVars(string stripped) {
    bool[string] names;
    size_t i = 0;
    while (i < stripped.length) {
        if (wordAt(stripped, i, "SubjectPacket")) {
            size_t j = i + "SubjectPacket".length;
            skipWs(stripped, j);
            while (j < stripped.length && stripped[j] == '*') {
                j++;
                skipWs(stripped, j);
            }
            if (j < stripped.length && (isAlphaNum(stripped[j]) || stripped[j] == '_')) {
                size_t k = j;
                while (k < stripped.length && isIdentChar(stripped[k])) k++;
                immutable string name = stripped[j .. k];
                size_t m = k;
                skipWs(stripped, m);
                if (m < stripped.length
                    && (stripped[m] == ';' || stripped[m] == '=' || stripped[m] == ','
                        || stripped[m] == ')'))
                    names[name] = true;
            }
        }
        i++;
    }
    return names;
}

/// Every `<name>.<field> =` in `stripped` for `name` in `declared` and
/// `field` in `subjectFields`, EXCLUDING sites textually inside a
/// `unittest { }` body (tracked via a brace stack that inherits its
/// parent's "inside unittest" state, so a nested block within a unittest
/// stays covered).
/// TASK 2007 — `with (subj) { mesh = …; }`, the field write that carries no
/// `subj.` prefix at all. This file's own header used to list the shape under
/// "WHAT IT DOES NOT SEE"; the sweep then PROVED it live, planting
/// `with (subj) { mesh = hideBatchMesh; }` straight after `SubjectPacket subj;`
/// in `source/command.d` and watching the census stay green at the same module
/// count. A hole a file names in its own header is still a hole.
///
/// Returns the SubjectPacket variable a `with (…)` head binds, or `null` if
/// this head is not such a `with`. `head` is the token buffer the scanner
/// accumulates since the last `{`/`}`/`;`, so it already has comments and
/// string literals blanked out.
private string withSubjectOf(string head, in bool[string] declared) {
    auto h = head.strip;
    if (h.length < 6 || h[$ - 1] != ')') return null;
    // Walk back to the `(` matching the trailing `)`.
    int d = 0;
    size_t k = h.length;
    while (k > 0) {
        --k;
        if (h[k] == ')') ++d;
        else if (h[k] == '(') { --d; if (d == 0) break; }
    }
    if (d != 0 || k == 0) return null;
    const string inner  = h[k + 1 .. $ - 1].strip;
    const string before = h[0 .. k].strip;
    if (before.length < 4 || before[$ - 4 .. $] != "with") return null;
    if (before.length > 4 && isIdentChar(before[before.length - 5])) return null;
    return (inner in declared) ? inner : null;
}

private FieldAssignment[] scanFieldAssignments(string stripped, in bool[string] declared) {
    auto out_ = appender!(FieldAssignment[]);
    bool[] unitStack;
    string[] withStack;   // the SubjectPacket this frame's `with` binds, or null
    string head;
    size_t i = 0;
    while (i < stripped.length) {
        immutable char c = stripped[i];
        if (c == '{') {
            immutable bool nowUnit = (head.strip == "unittest")
                ? true
                : (unitStack.length ? unitStack[$ - 1] : false);
            unitStack ~= nowUnit;
            const string w = withSubjectOf(head, declared);
            withStack ~= (w !is null)
                ? w
                : (withStack.length ? withStack[$ - 1] : null);
            head = "";
            i++;
            continue;
        }
        if (c == '}') {
            if (unitStack.length) unitStack = unitStack[0 .. $ - 1];
            if (withStack.length) withStack = withStack[0 .. $ - 1];
            head = "";
            i++;
            continue;
        }
        if (c == ';') { head = ""; i++; continue; }

        if (isAlphaNum(c) || c == '_') {
            size_t j = i;
            while (j < stripped.length && isIdentChar(stripped[j])) j++;
            immutable string word = stripped[i .. j];
            immutable bool boundary = (i == 0 || !isIdentChar(stripped[i - 1]));

            // The `with (subj)` arm: a BARE field name, no receiver. Active
            // inside a braced `with` frame, and for the braceless
            // single-statement form (`with (subj) mesh = x;`) via the head
            // buffer, which still carries the `with (subj)` tokens.
            if (boundary && subjectFields.canFind(word)) {
                string wsub = withStack.length ? withStack[$ - 1] : null;
                if (wsub is null) wsub = withSubjectOf(head, declared);
                if (wsub !is null) {
                    // Not `other.mesh = …` — a dotted receiver is the first
                    // arm's business, and counting it here would double-report.
                    size_t b = i;
                    while (b > 0 && isWhite(stripped[b - 1])) --b;
                    immutable bool dotted = (b > 0 && stripped[b - 1] == '.');
                    size_t eqW = j;
                    skipWs(stripped, eqW);
                    if (!dotted && eqW < stripped.length && stripped[eqW] == '='
                        && (eqW + 1 >= stripped.length || stripped[eqW + 1] != '=')) {
                        immutable bool insideUnitW = unitStack.length && unitStack[$ - 1];
                        if (!insideUnitW)
                            out_ ~= FieldAssignment(lineAt(stripped, i), wsub, word,
                                                    lineTextAt(stripped, i));
                    }
                }
            }

            if (boundary && (word in declared)) {
                size_t m = j;
                skipWs(stripped, m);
                if (m < stripped.length && stripped[m] == '.') {
                    m++;
                    skipWs(stripped, m);
                    immutable size_t fs = m;
                    while (m < stripped.length && isIdentChar(stripped[m])) m++;
                    immutable string field = stripped[fs .. m];
                    size_t eq = m;
                    skipWs(stripped, eq);
                    if (eq < stripped.length && stripped[eq] == '='
                        && (eq + 1 >= stripped.length || stripped[eq + 1] != '=')
                        && subjectFields.canFind(field)) {
                        immutable bool insideUnit = unitStack.length && unitStack[$ - 1];
                        if (!insideUnit)
                            out_ ~= FieldAssignment(lineAt(stripped, i), word, field,
                                                    lineTextAt(stripped, i));
                    }
                }
            }
            head ~= word;
            i = j;
            continue;
        }
        if (c == '\n') head ~= ' '; else head ~= c;
        i++;
    }
    return out_.data;
}

// ---------------------------------------------------------------------------
// Assertion (b) — pipeline.evaluate( call-site count.
// ---------------------------------------------------------------------------

struct EvalCallSite { string file; size_t line; }

private EvalCallSite[] findEvaluateCalls(string relFile, string stripped) {
    auto out_ = appender!(EvalCallSite[]);
    enum needle = "pipeline.evaluate(";
    size_t from = 0;
    while (true) {
        auto p = stripped.indexOf(needle, from);
        if (p < 0) break;
        out_ ~= EvalCallSite(relFile, lineAt(stripped, cast(size_t) p));
        from = cast(size_t) p + 1;
    }
    return out_.data;
}

// ---------------------------------------------------------------------------
// Assertion (c) — the two workplane pickers go through viewOnlySubject(.
// ---------------------------------------------------------------------------

/// The `{ ... }` body of the first top-level definition of `fnName` in
/// `stripped` — i.e. `fnName(` followed (after its balanced parameter
/// list, and any trailing qualifiers up to the next `{`) by a function
/// body. Returns null if not found. Scoped deliberately to a narrow shape
/// (signature directly followed by `{`, no `;` forward declaration in
/// between) — sufficient for the two named functions this assertion checks,
/// not a general D parser.
private string functionBodyOf(string stripped, string fnName) {
    size_t i = 0;
    while (i < stripped.length) {
        if (wordAt(stripped, i, fnName)) {
            size_t j = i + fnName.length;
            skipWs(stripped, j);
            if (j < stripped.length && stripped[j] == '(') {
                int depth = 1;
                j++;
                while (j < stripped.length && depth > 0) {
                    if (stripped[j] == '(') depth++;
                    else if (stripped[j] == ')') depth--;
                    j++;
                }
                skipWs(stripped, j);
                if (j < stripped.length && stripped[j] == '{') {
                    immutable size_t bodyStart = j;
                    int bdepth = 1;
                    j++;
                    while (j < stripped.length && bdepth > 0) {
                        if (stripped[j] == '{') bdepth++;
                        else if (stripped[j] == '}') {
                            bdepth--;
                            if (bdepth == 0) { j++; break; }
                        }
                        j++;
                    }
                    return stripped[bodyStart .. j];
                }
            }
        }
        i++;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Self-tests: the scanners are not allowed to be inert either.
// ---------------------------------------------------------------------------

unittest {
    // (a) field-assignment detection, including the unittest exclusion and
    // the `==` / compound-operator non-matches.
    auto declared = declaredSubjectPacketVars(stripCommentsAndStrings(
        "void f(out SubjectPacket subj) { subj.mesh = null; }"));
    assert("subj" in declared, "out-parameter declarator must be collected");

    auto v1 = scanFieldAssignments(stripCommentsAndStrings(
        "void f() { SubjectPacket subj; subj.selType = SelType.Vertex; }"),
        declaredSubjectPacketVars(stripCommentsAndStrings(
            "void f() { SubjectPacket subj; subj.selType = SelType.Vertex; }")));
    assert(v1.length == 1, "a direct field assignment must be seen");
    assert(v1[0].varName == "subj" && v1[0].fieldName == "selType");

    string srcU = "void f() { SubjectPacket subj; "
        ~ "unittest { subj.mesh = null; } }";
    auto declU = declaredSubjectPacketVars(stripCommentsAndStrings(srcU));
    auto vU = scanFieldAssignments(stripCommentsAndStrings(srcU), declU);
    assert(vU.length == 0, "an assignment textually inside unittest{} must be excluded");

    string srcEq = "void f() { SubjectPacket subj; "
        ~ "if (subj.selType == SelType.Item) {} }";
    auto declEq = declaredSubjectPacketVars(stripCommentsAndStrings(srcEq));
    auto vEq = scanFieldAssignments(stripCommentsAndStrings(srcEq), declEq);
    assert(vEq.length == 0, "`==` is a comparison, not an assignment");

    // TASK 2007 — the `with (subj)` arm. The field write carries no `subj.`
    // prefix; before this arm the scan read ZERO on every shape below, which
    // the sweep proved live in `source/command.d` with the census green.
    static FieldAssignment[] scanBoth(string src) {
        const st = stripCommentsAndStrings(src);
        return scanFieldAssignments(st, declaredSubjectPacketVars(st));
    }

    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) { mesh = hideBatchMesh; } }");
        assert(v.length == 1, format(
            "`with (subj) { mesh = …; }` scanned as %d assignment(s), expected "
          ~ "1 — this is task 2007's live-proven hole, the one this file used "
          ~ "to name in its own header as uncovered", v.length));
        assert(v[0].varName == "subj" && v[0].fieldName == "mesh",
            format("%s.%s", v[0].varName, v[0].fieldName));
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) { if (x) { selType = SelType.Vertex; } } }");
        assert(v.length == 1, "a NESTED block inside the with-frame is still "
            ~ "the with-frame");
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) mesh = m; }");
        assert(v.length == 1, "the braceless single-statement `with` must "
            ~ "be covered too");
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) { auto m = mesh; } }");
        assert(v.length == 0, "a field READ inside a with-frame is not a "
            ~ "decision and must not match");
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) { if (selType == SelType.Item) {} } }");
        assert(v.length == 0, "`==` inside a with-frame is a comparison");
    }
    {
        // THE FALSE-POSITIVE CONTROL. `mesh` is an ordinary identifier all
        // over this tree; the arm must fire only inside a `with` bound to a
        // name this file already knows is a SubjectPacket.
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (app) { mesh = other; } mesh = third; }");
        assert(v.length == 0, format(
            "a bare `mesh = …` outside any SubjectPacket `with` was counted "
          ~ "(%d) — a census that reddens on correct code is the same defect "
          ~ "as one that cannot redden", v.length));
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "with (subj) { other.mesh = m; } }");
        assert(v.length == 0, "a DOTTED receiver inside a with-frame belongs "
            ~ "to the first arm's rule, not this one — and `other` is not a "
            ~ "declared SubjectPacket here");
    }
    {
        auto v = scanBoth("void f() { SubjectPacket subj; "
            ~ "unittest { with (subj) { mesh = m; } } }");
        assert(v.length == 0, "the unittest exclusion applies to the with-arm too");
    }

    string srcGet = "void f(ref VectorStack vts) { "
        ~ "auto subj = vts.get!SubjectPacket(); subj.mesh = null; }";
    auto declGet = declaredSubjectPacketVars(stripCommentsAndStrings(srcGet));
    assert("subj" !in declGet,
        "`get!SubjectPacket()` must not be read as a declarator — the `(` "
        ~ "right after the type name is never in the accepted delimiter set");

    string srcCompound = "void f() { SubjectPacket subj; int x; x += 1; }";
    auto declCompound = declaredSubjectPacketVars(stripCommentsAndStrings(srcCompound));
    auto vCompound = scanFieldAssignments(stripCommentsAndStrings(srcCompound), declCompound);
    assert(vCompound.length == 0, "sanity: an unrelated compound assign must not appear");
}

unittest {
    // (b) pipeline.evaluate( counting — comments/strings must not count,
    // and multiple call sites in one file must all be found.
    auto s1 = stripCommentsAndStrings(
        "void f() { g_pipeCtx.pipeline.evaluate(vts); }\n"
        ~ "// pipeline.evaluate( in a comment must not count\n");
    assert(findEvaluateCalls("x.d", s1).length == 1);

    auto s2 = stripCommentsAndStrings(
        "void f() { p.pipeline.evaluate(a); p.pipeline.evaluate(b); }");
    assert(findEvaluateCalls("x.d", s2).length == 2, "both call sites must be found");
}

unittest {
    // (c) function-body extraction and the viewOnlySubject / SubjectSource
    // presence checks.
    auto s = stripCommentsAndStrings(
        "BuildPlane pickWorkplane(const ref Viewport vp) {\n"
        ~ "    SubjectPacket subj;\n"
        ~ "    evaluateSubject(subj, vts, viewOnlySubject(vp));\n"
        ~ "}\n"
        ~ "WorkplaneFrame pickWorkplaneFrame(const ref Viewport vp) {\n"
        ~ "    SubjectPacket subj;\n"
        ~ "    evaluateSubject(subj, vts, viewOnlySubject(vp));\n"
        ~ "}\n");
    auto b1 = functionBodyOf(s, "pickWorkplane");
    auto b2 = functionBodyOf(s, "pickWorkplaneFrame");
    assert(b1 !is null && b2 !is null);
    assert(b1.canFind("viewOnlySubject(") && !b1.canFind("SubjectSource("));
    assert(b2.canFind("viewOnlySubject(") && !b2.canFind("SubjectSource("));

    // The mutation (M6): a four-argument SubjectSource( literal with live
    // values inlined at the call site instead of viewOnlySubject(.
    auto sMut = stripCommentsAndStrings(
        "BuildPlane pickWorkplane(const ref Viewport vp) {\n"
        ~ "    SubjectPacket subj;\n"
        ~ "    evaluateSubject(subj, vts, "
        ~ "SubjectSource(null, EditMode.Vertices, currentSelType(o), vp));\n"
        ~ "}\n");
    auto bMut = functionBodyOf(sMut, "pickWorkplane");
    assert(!bMut.canFind("viewOnlySubject("), "the mutated body must fail the check");
    assert(bMut.canFind("SubjectSource("), "and be caught for the right reason");
}

// ---------------------------------------------------------------------------
// The census itself.
// ---------------------------------------------------------------------------

private enum censusRepoRoot = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));

unittest {
    // Non-vacuity: prove the walk actually reaches source/ before trusting
    // any "found nothing" result below.
    const dir = buildPath(censusRepoRoot, "source");
    assert(exists(dir) && isDir(dir),
        "the census cannot find source/ at " ~ dir ~ " — it is measuring "
        ~ "nothing, which is worse than being absent");

    enum allowlistRelPath = "source/toolpipe/subject.d";

    size_t filesScanned;
    string[] outsideViolations;      // assertion (a)
    size_t   positiveControlCount;   // assertion (a), inside subject.d itself
    EvalCallSite[] evalCalls;        // assertion (b)

    foreach (entry; dirEntries(dir, SpanMode.depth)) {
        if (!entry.isFile || entry.name.length < 2
            || entry.name[$ - 2 .. $] != ".d") continue;
        filesScanned++;

        immutable relPath = relativePath(entry.name, censusRepoRoot);
        immutable src      = readText(entry.name);
        immutable stripped = stripCommentsAndStrings(src);
        const     declared = declaredSubjectPacketVars(stripped);

        auto assigns = scanFieldAssignments(stripped, declared);
        if (relPath == allowlistRelPath) {
            positiveControlCount = assigns.length;
        } else {
            foreach (a; assigns)
                outsideViolations ~= format("%s:%d  %s.%s  [%s]",
                    relPath, a.line, a.varName, a.fieldName, a.text);
        }

        evalCalls ~= findEvaluateCalls(relPath, stripped);
    }

    assert(filesScanned > 100,
        format("only %d .d files under source/ — the walk is not reaching "
               ~ "the tree it claims to be guarding", filesScanned));

    // Positive control: the scanner must SEE the assignments it is meant to
    // allow inside subject.d, or it is trusted for nothing. `fillSubject`
    // assigns all 7 always-set fields plus the 2 opt-in morph fields inside
    // its `if` guard = 9.
    assert(positiveControlCount == 9,
        format("positive control failed: expected to see 9 SubjectPacket "
               ~ "field assignments inside %s (fillSubject's 7 unconditional "
               ~ "+ 2 morph-target fields), saw %d — a scanner that cannot "
               ~ "see the assignments it is supposed to ALLOW cannot be "
               ~ "trusted to catch the ones it must FORBID",
               allowlistRelPath, positiveControlCount));

    // Assertion (a): zero field assignments anywhere else.
    assert(outsideViolations.length == 0,
        "a SubjectPacket field is being assigned OUTSIDE "
        ~ allowlistRelPath ~ " and outside a unittest{} body — task 1904 "
        ~ "made fillSubject/evaluateSubject (source/toolpipe/subject.d) the "
        ~ "single place that decides what the subject is; re-inlining a "
        ~ "hand-built subject anywhere else re-opens the six divergences "
        ~ "the migration collapsed. Reuse evaluateSubject/fillSubject "
        ~ "instead.\n  " ~ outsideViolations.length.format!"%d site(s):\n  "
        ~ outsideViolations.join("\n  "));

    // Assertion (b): exactly one pipeline.evaluate( call site, and it must
    // be the one inside evaluateSubject.
    assert(evalCalls.length == 1,
        format("expected exactly 1 `pipeline.evaluate(` call site in "
               ~ "source/** (inside evaluateSubject) — found %d: %s. Every "
               ~ "pipe evaluation must go through "
               ~ "toolpipe.subject.evaluateSubject (plan §5); a second "
               ~ "direct call re-opens the very fan-out task 1904 collapsed.",
               evalCalls.length, evalCalls));
    assert(evalCalls[0].file == allowlistRelPath,
        format("the one surviving `pipeline.evaluate(` call site must be in "
               ~ "%s (evaluateSubject), found it in %s instead",
               allowlistRelPath, evalCalls[0].file));

    // Assertion (c): the two workplane pickers (plan §1.3a).
    immutable createCommonRel = "source/tools/create/create_common.d";
    immutable createCommonPath = buildPath(censusRepoRoot, createCommonRel);
    assert(exists(createCommonPath),
        "cannot find " ~ createCommonRel ~ " — assertion (c) is measuring nothing");
    immutable ccStripped = stripCommentsAndStrings(readText(createCommonPath));

    foreach (fn; ["pickWorkplane", "pickWorkplaneFrame"]) {
        auto body_ = functionBodyOf(ccStripped, fn);
        assert(body_ !is null,
            "could not find the body of " ~ createCommonRel ~ " :: " ~ fn
            ~ " — assertion (c) is measuring nothing for this function");
        assert(body_.canFind("viewOnlySubject("),
            "§1.3a: " ~ createCommonRel ~ " :: " ~ fn
            ~ " must build its subject through viewOnlySubject(vp) — the "
            ~ "frozen null-mesh / Vertices / Vertex source. It does not.");
        assert(!body_.canFind("SubjectSource("),
            "§1.3a: " ~ createCommonRel ~ " :: " ~ fn
            ~ " contains a four-argument SubjectSource( literal — the two "
            ~ "workplane pickers must reach the funnel ONLY through the "
            ~ "named, frozen viewOnlySubject(vp), never an inline literal "
            ~ "that could silently wire live editor state (plan §1.3a).");
    }
}
