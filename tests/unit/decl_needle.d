// decl_needle — the one attribute-chain predicate the source censuses key on
// (task 3280).
//
// WHY THIS FILE EXISTS. Four lanes in a row measured the same blindness and
// each recorded it as a different fact:
//
//   * phase B: "31 against 32 — the predicate only allowed `private`";
//   * task 3200: "25 against 24 — the predicate does not allow `override`";
//   * task 3220: the same shape again;
//   * task 3250: "1 declaration of 4 — the alternation
//     `(private|protected|public|package )` puts the space ONLY on `package`,
//     so after `public` it demands `void` with nothing in between".
//
// Three diagnoses of one defect, and none of them was written down as a
// PREDICATE anyone could run. The lesson is not that the list was one keyword
// short: a hand-written prefix rule per census is a list every later author
// has to widen, and the feedback for forgetting is a census that goes GREEN.
//
// THE FAILURE DIRECTION IS THE WHOLE POINT. A census that recognises a
// declaration by its leading attributes and MISSES one does not report a
// smaller number — it reports the same number. The unseen declaration never
// enters the found set, so it is never a NEW row, and the roster it should
// have contradicted is still satisfied. That is a floor a new declaration
// walks under: green before, green after, green when reverted. So this module
// is built so the only way to be wrong is to count too MUCH:
//
//   * `stripDeclAttrs` consumes a CHAIN, in any order and any length, not one
//     optional attribute;
//   * the table below is derived from a census of `source/` (see
//     `kTreeAttrChains`), not from memory;
//   * and `hasUnknownDeclPrefix` is the net under the table: a type token in
//     declaration position behind a word this table does NOT know is
//     reported, not skipped. An unanticipated attribute therefore reddens a
//     census instead of dissolving a row in it.
//
// ADDITIVE ON PURPOSE. The `tool_commit_seam_census_g*_test.d` family keys on
// a RAW substring (`countOccurrences(src, "void setUndoBindings")`), which has
// no attribute term at all and is therefore already immune; nothing here
// changes it, and a new sibling census in that family may keep doing the same.
// What this module replaces is the two places that DID carry an attribute
// term and got it wrong.
module tests.unit.decl_needle;

import std.string : strip, startsWith;

// ---------------------------------------------------------------------------
// THE TABLE, AND WHERE IT COMES FROM.
// ---------------------------------------------------------------------------
//
// `kTreeAttrChains` below is the census of every attribute chain that
// actually precedes a declaration in `source/` as of 2026-08-29, most
// frequent first. It is not decoration: it is the fixture the pinning
// unittest at the foot of this file feeds to the predicate, one spelling per
// row, so that "the needle sees every spelling the tree uses" is a check with
// a witness rather than a claim. Re-derive it, do not extend it by guessing.

/// Bare keyword attributes. `ref` / `auto` / `scope` / `in` / `out` / `lazy`
/// are DELIBERATELY ABSENT from the variable half: they are parameter and
/// function storage classes, and admitting them would make a `ref T p,`
/// continuation line inside a parameter list read as a field declaration.
/// They ARE in `kAttrChainRe` below, which is the FUNCTION-declaration half —
/// `ref inout(Mesh) mesh() inout return` is a real declaration in `mesh.d`
/// and the old predicate read its owner as `inout`.
package immutable string[] kVarAttrKeywords = [
    "private", "protected", "public", "package", "export",
    "static", "final", "override", "abstract",
    "const", "immutable", "inout", "shared", "__gshared",
    "nothrow", "pure", "synchronized", "deprecated", "extern", "align",
    "pragma", "enum",
    // NOT attributes — conditional-compilation guards. They are here because
    // they occupy the SAME SLOT in front of a declaration
    // (`version (unittest) private Mesh buildRawMesh(…)` is a real line in
    // `source/mesh.d`), and a chain walker that stops at them drops whatever
    // stands behind them. Stopping there is the same silent under-read this
    // module exists to end, only spelled with a different keyword.
    "version", "debug",
];

/// The attribute keywords that may be spelled with a parenthesised argument
/// (`extern (C)`, `pragma(inline, true)`, `deprecated("why")`, `align(8)`,
/// `package(a.b)`).
package immutable string[] kParenAttrKeywords = [
    "extern", "pragma", "deprecated", "align", "package", "synchronized",
    "version", "debug",
];

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private bool isIdentStart(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool inList(const(string)[] list, string s) {
    foreach (e; list) if (e == s) return true;
    return false;
}

/// Skip a balanced `( … )` starting at `i` (which must index the `(`).
/// Returns the index just past the closing paren, or `i` if unbalanced.
private size_t skipParens(string s, size_t i) {
    if (i >= s.length || s[i] != '(') return i;
    int depth = 0;
    size_t j = i;
    while (j < s.length) {
        if (s[j] == '(') ++depth;
        else if (s[j] == ')') {
            --depth;
            if (depth == 0) return j + 1;
        }
        ++j;
    }
    return i;
}

/// Consume the leading D attribute chain of an already comment-stripped line.
///
/// `attrs` receives the tokens consumed, in source order, spelled as they
/// appear (`extern (C)` comes back whole). The return value is the rest of the
/// line, stripped. A chain of ANY length in ANY order is consumed — that is
/// the difference from every predicate this replaces, all of which took at
/// most one attribute and only from a short set.
package string stripDeclAttrs(string line, out string[] attrs) {
    string t = line.strip;
    for (;;) {
        if (t.length == 0) break;
        size_t i = 0;
        if (t[0] == '@') {
            i = 1;
            if (i >= t.length || !isIdentStart(t[i])) break;
            while (i < t.length && isIdentChar(t[i])) ++i;
            size_t k = i;
            while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
            if (k < t.length && t[k] == '(') {
                immutable size_t e = skipParens(t, k);
                if (e == k) break;      // unbalanced — stop rather than guess
                i = e;
            }
        } else if (isIdentStart(t[0])) {
            while (i < t.length && isIdentChar(t[i])) ++i;
            immutable string word = t[0 .. i];
            if (!inList(kVarAttrKeywords, word)) break;
            size_t k = i;
            while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
            if (k < t.length && t[k] == '(' && inList(kParenAttrKeywords, word)) {
                immutable size_t e = skipParens(t, k);
                if (e == k) break;
                i = e;
            } else if (k < t.length && t[k] == '(') {
                // `pragma`-shaped word with a paren it is not allowed to
                // carry: not an attribute here. Stop.
                break;
            }
        } else {
            break;
        }
        attrs ~= t[0 .. i];
        t = t[i .. $].strip;
    }
    return t;
}

/// Same, for callers that do not need the tokens back.
package string stripDeclAttrs(string line) {
    string[] ignored;
    return stripDeclAttrs(line, ignored);
}

/// Skip the `[]` / `[N]` / `*` suffixes a declared type may carry.
private size_t skipTypeSuffix(string t, size_t i) {
    for (;;) {
        size_t k = i;
        while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
        if (k < t.length && t[k] == '[') {
            int d = 0;
            size_t close = k;
            foreach (j; k .. t.length) {
                if (t[j] == '[') ++d;
                else if (t[j] == ']') { --d; if (d == 0) { close = j + 1; break; } }
            }
            if (close == k) return i;
            i = close;
            continue;
        }
        if (k < t.length && t[k] == '*') { i = k + 1; continue; }
        return i;
    }
}

/// Does `line` DECLARE a variable (field or local) of type `typeToken`?
///
/// Yes for `MeshSnapshot snap;`, `private MeshSnapshot snap;`,
/// `protected override MeshSnapshot snap;`, `MeshSnapshot[] snaps;`,
/// `MeshSnapshot* p;`. No for `snap = MeshSnapshot.capture(*mesh);`,
/// `void f(MeshSnapshot a)` and `import snapshot : MeshSnapshot;`.
package bool declaresVarOfType(string line, string typeToken) {
    return declaredVarName(line, typeToken) !is null;
}

/// The NAME a `typeToken` declaration on this line gives its variable, or
/// `null` when the line declares nothing of that type. Callers that care
/// about one particular field (`editRecorder_`, `snap`) key on the name
/// rather than on a spelled-out declaration string, which is what makes them
/// survive an attribute being added in front of it.
package string declaredVarName(string line, string typeToken) {
    string t = stripDeclAttrs(line);
    if (!t.startsWith(typeToken)) return null;
    size_t i = typeToken.length;
    if (i < t.length && isIdentChar(t[i])) return null;    // a longer name
    if (i < t.length && t[i] == '.') return null;          // `T.capture(…)`
    i = skipTypeSuffix(t, i);
    while (i < t.length && (t[i] == ' ' || t[i] == '\t')) ++i;
    if (i >= t.length || !isIdentStart(t[i])) return null;
    size_t j = i;
    while (j < t.length && isIdentChar(t[j])) ++j;
    // A `(` behind the name makes this a FUNCTION, not a variable — measured,
    // not anticipated: `private MeshEditTracker* editRecorder_() const` in
    // `source/mesh.d` is the ACCESSOR that replaced the field, and the first
    // draft of this predicate reported it as the field coming back. That is
    // the over-count this module prefers to an under-count, and it showed up
    // where over-counts are supposed to: in a red run, with the line in hand.
    size_t k = j;
    while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
    if (k < t.length && t[k] == '(') return null;
    return t[i .. j];
}

/// Every DECLARATION of a function called `name` in `code`, reported as the
/// attribute chain standing in front of it — one entry per declaration, and an
/// EMPTY entry for a declaration that carries no attribute at all.
///
/// This is what a census should ask when its question is "is this name
/// `private` again?". Spelling the answer out as a needle
/// (`"private float smoothstep01("`) answers a narrower question than the one
/// asked: `private static float smoothstep01(` re-privatises the name and
/// reads ZERO against that needle, so the row that exists to catch it is
/// green, and — measured on this tree — the companion `publicDecl == 1` row
/// is green too, because the public spelling is a substring of the private
/// one. Asking for the CHAIN cannot be dodged that way.
package string[][] funcDeclAttrChains(string code, string name) {
    import std.string : splitLines;
    string[][] chains;
    foreach (line; code.splitLines) {
        string[] attrs;
        immutable string t = stripDeclAttrs(line, attrs);
        // A return type, then the name, then `(`. The return type is one
        // token, brackets and parens balanced (`uint[]`, `inout(Mesh)`,
        // `Tuple!(int,int)`).
        size_t i = 0;
        int depth = 0;
        while (i < t.length) {
            immutable char c = t[i];
            if (c == '(' || c == '[' || c == '!') { if (c != '!') ++depth; ++i; continue; }
            if (c == ')' || c == ']') { --depth; ++i; continue; }
            if (depth == 0 && (c == ' ' || c == '\t')) break;
            if (depth == 0 && (c == ';' || c == '=' || c == ',' || c == '{')) { i = t.length; break; }
            ++i;
        }
        if (i == 0 || i >= t.length) continue;
        // A STATEMENT keyword in the return-type slot is not a declaration.
        // Measured: `    return buildRawMesh(verts, faceList);` in
        // `source/mesh.d` otherwise parses as "type `return`, name
        // `buildRawMesh`" and reports a second, attribute-free declaration of
        // a name that has one. Over-counting is this module's preferred
        // direction, but a census that asks "is every declaration public?"
        // would then answer about a call.
        static immutable string[] kStatementHeads = [
            "return", "if", "else", "while", "do", "for", "foreach",
            "foreach_reverse", "switch", "case", "default", "assert", "cast",
            "new", "throw", "catch", "try", "with", "mixin", "typeof", "is",
            "import", "alias", "module", "goto", "break", "continue", "delete",
        ];
        if (inList(kStatementHeads, t[0 .. i])) continue;
        while (i < t.length && (t[i] == ' ' || t[i] == '\t')) ++i;
        if (i >= t.length || !isIdentStart(t[i])) continue;
        size_t j = i;
        while (j < t.length && isIdentChar(t[j])) ++j;
        if (t[i .. j] != name) continue;
        while (j < t.length && (t[j] == ' ' || t[j] == '\t')) ++j;
        if (j >= t.length || t[j] != '(') continue;
        chains ~= attrs;
    }
    return chains;
}

/// Does this attribute chain NARROW a declaration's visibility below public?
package bool narrowsVisibility(const(string)[] chain) {
    foreach (a; chain) {
        if (a == "private" || a == "protected") return true;
        if (a.length >= 7 && a[0 .. 7] == "package") return true;
    }
    return false;
}

/// THE NET UNDER THE TABLE.
///
/// True when `typeToken` sits in DECLARATION position on this line — nothing
/// but word-shaped tokens in front of it, a name behind it, and a `;` or `=`
/// after the name — and yet `declaresVarOfType` said no. That can only mean
/// one of the words in front is an attribute this module's table does not
/// know, and the honest answer is a loud row, not a silent skip.
///
/// Its own limits, stated: a chain whose unknown member carries a paren
/// (`somepragma(x) T v;`) is not caught, because the `(` disqualifies the
/// word run; and a parameter is not caught, because a parameter ends in `,`
/// or `)` rather than `;` or `=`. Both are deliberate — the second is what
/// keeps a `ref T p,` continuation line out of the findings.
package bool hasUnknownDeclPrefix(string line, string typeToken) {
    if (declaresVarOfType(line, typeToken)) return false;
    immutable string t = line.strip;
    // Walk word-shaped tokens until the type token shows up.
    size_t i = 0;
    for (;;) {
        while (i < t.length && (t[i] == ' ' || t[i] == '\t')) ++i;
        if (i >= t.length) return false;
        size_t j = i;
        if (t[j] == '@') ++j;
        if (j >= t.length || !isIdentStart(t[j])) return false;
        while (j < t.length && isIdentChar(t[j])) ++j;
        immutable string word = t[i .. j];
        if (word == typeToken) {
            size_t k = skipTypeSuffix(t, j);
            while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
            if (k >= t.length || !isIdentStart(t[k])) return false;
            while (k < t.length && isIdentChar(t[k])) ++k;
            while (k < t.length && (t[k] == ' ' || t[k] == '\t')) ++k;
            return k < t.length && (t[k] == ';' || t[k] == '=');
        }
        // Anything but a bare word in front of the type disqualifies the line
        // (a `(`, a `.`, a `=` … means this is not a declaration head).
        if (j < t.length && !(t[j] == ' ' || t[j] == '\t')) return false;
        i = j;
    }
}

// ---------------------------------------------------------------------------
// THE REGEX HALF — one sub-pattern, for the censuses that scan with `ctRegex`.
// ---------------------------------------------------------------------------
//
// This is the FUNCTION-declaration chain, so it carries `ref` / `auto` /
// `scope` / `return` as well: `ref inout(Mesh) mesh() inout return { … }` in
// `source/mesh.d` is a real declaration, and the predicate it replaces read
// its owner as `inout`. It matches a chain of ZERO OR MORE attributes, each
// followed by at least one space — the `?` in `(?:private |public |package )?`
// was half the four-lane defect and is not repeated here.
package enum string kAttrChainRe =
      `(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:[ \t]*\([^()]*\))?`
    ~ `|(?:extern|pragma|deprecated|align|package|synchronized|version|debug)`
    ~ `[ \t]*\([^()]*\)`
    ~ `|private|protected|public|package|export|static|final|override|abstract`
    ~ `|const|immutable|inout|shared|__gshared|nothrow|pure|synchronized`
    ~ `|deprecated|ref|auto|scope|return|enum)[ \t]+)*`;

// ---------------------------------------------------------------------------
// THE PINNING FIXTURE — every attribute chain the tree actually spells.
// ---------------------------------------------------------------------------
//
// Derived by census over `source/**.d` on 2026-08-29 (attribute run in front
// of a declaration, most frequent first), then extended with eight spellings
// the tree does NOT use yet. The eight are the point: a table that only knows
// today's tree is a table that goes green on tomorrow's.
package immutable string[] kTreeAttrChains = [
    // ---- measured in source/ ------------------------------------------
    "",                                 // 1400+ bare declarations
    "private",                          // 2965
    "const",                            // 1803
    "immutable",                        // 1733
    "override",                         // 1400
    "final",                            //  358
    "static",                           //  327
    "protected override",               //  323  <- the L2/L6/L8/L10 spelling
    "public",                           //  259
    "@property",                        //  171
    "package",                          //  141
    "public override",                  //  109  <- INVISIBLE to the old needle
    "private __gshared",                //   91
    "protected",                        //   82
    "private static",                   //   74
    "__gshared",                        //   57
    "static immutable",                 //   56
    "private immutable",                //   26
    "private static immutable",         //   20
    "@disable",                         //   16
    "pragma(inline, true)",             //   16
    "@safe pure nothrow",               //   15
    "private final",                    //   13
    "package @property",                //   13
    "package static",                   //   12
    "pure nothrow @nogc",               //   10
    "private shared",                   //   10
    "protected final",                  //    9
    "abstract",                         //    9
    "pure nothrow @safe",               //    7
    "shared static",                    //    6
    "shared",                           //    5
    "protected static",                 //    4
    "pure nothrow",                     //    3
    "public __gshared",                 //    3
    "private abstract",                 //    3
    "override protected",               //    3  <- ORDER REVERSED, also unseen
    "static final",                     //    3
    "extern (Objective-C)",             //    2
    "extern (C)",                       //    2
    "public final",                     //    2
    "private extern (C) static",        //    2
    "protected abstract",               //    2
    "package immutable",                //    2
    "public static",                    //    2
    "override public",                  //    2  <- task 3200's whole finding
    "const @safe pure nothrow",         //    1
    "@section(\".preinit_array\")",     //    1
    "__gshared extern (C)",             //    1
    "pragma(inline, true) static",      //    1
    "private @property",                //    1
    "@safe pure",                       //    1
    // ---- NOT in the tree today ----------------------------------------
    "export",
    "synchronized",
    "@trusted",
    "@system",
    "align(8)",
    "deprecated(\"gone in 3.0\")",
    "package(tests.unit)",
    "public override final @trusted",
    // Not attributes, but they stand in the same slot — see kVarAttrKeywords.
    "version (unittest)",
    "debug",
];

unittest // the needle sees EVERY attribute spelling the tree uses
{
    import std.format : format;

    // WHY THIS CELL. `stripDeclAttrs` is the instrument three censuses read
    // the tree through, and an instrument that under-reads makes all three
    // report a smaller world without saying so. The mutation that has to
    // redden it is the historical one: put the chain back to a single
    // optional visibility and this row names EVERY spelling that disappears,
    // not just a count. Collected rather than asserted per row on purpose —
    // druntime stops a module at its first failed assert, and the first row
    // alone would have read as "one spelling is off" when the truth was
    // "three quarters of the population is invisible" (task 3250 measured
    // 1 declaration of 4).
    string[] missed;
    foreach (chain; kTreeAttrChains) {
        immutable string line = chain.length
            ? "    " ~ chain ~ " MeshSnapshot snap;"
            : "    MeshSnapshot snap;";
        if (!declaresVarOfType(line, "MeshSnapshot"))
            missed ~= chain.length ? "`" ~ chain ~ "`" : "`<no attribute>`";
    }
    assert(missed.length == 0,
        format("the declaration needle CANNOT SEE %d of the %d attribute "
             ~ "spellings this tree uses. The missed spellings are: %-(%s, %).\n"
             ~ "  A holder written that way never enters a census's found "
             ~ "set, so it is never a NEW row and the roster it contradicts "
             ~ "stays satisfied: the census is green before the declaration, "
             ~ "green after it, and green when it is reverted. That is the "
             ~ "defect this predicate exists to end; four lanes recorded "
             ~ "three different diagnoses of it (`private`-only, "
             ~ "`override`-missing, the alternation space on `package` alone) "
             ~ "before it was written down as one rule.\n"
             ~ "  Fix the TABLE (`kVarAttrKeywords` / `kParenAttrKeywords` in "
             ~ "tests/unit/decl_needle.d), never the census that reads it.",
               missed.length, kTreeAttrChains.length, missed));
}

unittest // …and the chain comes back whole, in source order
{
    import std.format : format;
    string[] attrs;
    immutable rest = stripDeclAttrs(
        "    private extern (C) static @safe MeshSnapshot snap;", attrs);
    assert(attrs == ["private", "extern (C)", "static", "@safe"],
        format("stripDeclAttrs returned the chain %s. It must consume EVERY "
             ~ "attribute, in any order, including the parenthesised ones — a "
             ~ "predicate that stops at the first unknown token is the "
             ~ "one-attribute-deep rule this module replaces.", attrs));
    assert(rest == "MeshSnapshot snap;",
        format("stripDeclAttrs left `%s`, expected `MeshSnapshot snap;`",
               rest));
}

unittest // what it must REFUSE — the over-count has limits too
{
    import std.format : format;
    static immutable string[] notDecls = [
        "        snap = MeshSnapshot.capture(*mesh);",
        "            if (nEdge == 0) { snap = MeshSnapshot.init; return false; }",
        "import snapshot : MeshSnapshot;",
        "    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_) {",
        "            MeshSnapshot.capture(src.meshRef()).restore(l2.meshRef());",
        "    private MeshSnapshotCache cache;",     // a LONGER type name
    ];
    foreach (line; notDecls)
        assert(!declaresVarOfType(line, "MeshSnapshot"),
            format("the needle counted `%s` as a MeshSnapshot DECLARATION. "
                 ~ "Over-counting is the direction this module prefers, but "
                 ~ "not this far: a capture call, an import and a parameter "
                 ~ "list are not holders, and a census whose per-file rows are "
                 ~ "exact would redden on all three.", line.strip));
}

unittest // the net: an attribute the table does not know is LOUD, not silent
{
    import std.format : format;
    // `mixin` is not in the table and is not meant to be. The point is what
    // happens when a chain the table has never seen shows up in front of a
    // real declaration: the line must be REPORTABLE, not invisible.
    assert(hasUnknownDeclPrefix("    mixin MeshSnapshot snap;", "MeshSnapshot"),
        "an unknown attribute in front of a declaration must be reported by "
      ~ "`hasUnknownDeclPrefix`, so a census reddens with the line in hand "
      ~ "instead of dropping the declaration out of its found set.");
    foreach (chain; kTreeAttrChains) {
        immutable string line = chain.length
            ? "    " ~ chain ~ " MeshSnapshot snap;"
            : "    MeshSnapshot snap;";
        assert(!hasUnknownDeclPrefix(line, "MeshSnapshot"),
            format("`%s` is a spelling the table DOES know, so the net must "
                 ~ "stay quiet on it — a net that fires on every known chain "
                 ~ "is noise and gets switched off.", chain));
    }
    // A parameter is not a declaration and must not reach the net either.
    assert(!hasUnknownDeclPrefix("        ref MeshSnapshot snapOut,",
                                 "MeshSnapshot"),
        "a `ref T p,` continuation line inside a parameter list is not a "
      ~ "holder; the net keys on a `;`/`=` terminator precisely so it stays "
      ~ "out of the findings.");
}

unittest // the function-declaration chain, and what "private again" really asks
{
    import std.format : format;

    // The eleven §2.6 widening rows in `commit_seam_census_test.d` used to ask
    // this question with a spelled-out needle, `"private float smoothstep01("`.
    // These four lines are why that was not the question: the first is the
    // spelling the needle knows, and the next three re-privatise the same name
    // in spellings it reads as ZERO.
    immutable string code =
        "private float smoothstep01(float t) { return t; }\n"
      ~ "private static float alsoPrivate(float t) { return t; }\n"
      ~ "@safe private float safePrivate(float t) { return t; }\n"
      ~ "package float packagePrivate(float t) { return t; }\n"
      ~ "float reallyPublic(float t) { return t; }\n"
      ~ "    float m = smoothstep01(0.5f);\n";      // a CALL, not a declaration

    static immutable string[] narrowed =
        ["smoothstep01", "alsoPrivate", "safePrivate", "packagePrivate"];
    foreach (n; narrowed) {
        auto chains = funcDeclAttrChains(code, n);
        assert(chains.length == 1,
            format("funcDeclAttrChains found %d declaration(s) of `%s`, "
                 ~ "expected 1. A census that cannot FIND the declaration "
                 ~ "cannot report on its visibility, and answers `not "
                 ~ "private` for the same reason a missing file answers "
                 ~ "zero.", chains.length, n));
        assert(narrowsVisibility(chains[0]),
            format("`%s` is declared with the chain %s and this predicate "
                 ~ "called it PUBLIC. That is the silent half of the defect: "
                 ~ "the §2.6 rows assert a name is no longer private, and a "
                 ~ "spelling they cannot see reads as compliance.",
                   n, chains[0]));
    }
    auto pub = funcDeclAttrChains(code, "reallyPublic");
    assert(pub.length == 1 && !narrowsVisibility(pub[0]),
        format("a declaration with NO attribute chain must still be found "
             ~ "(got %d) and must read as public (chain %s)",
               pub.length, pub.length ? pub[0] : null));
    assert(funcDeclAttrChains(code, "nosuchname").length == 0,
        "funcDeclAttrChains answered for a name the text does not declare");
    assert(funcDeclAttrChains("    return smoothstep01(t);\n", "smoothstep01")
             .length == 0,
        "a `return f(x);` statement was read as a DECLARATION of `f` — "
      ~ "measured on source/mesh.d, where `return buildRawMesh(verts, "
      ~ "faceList);` produced a second, attribute-free declaration of a name "
      ~ "that has exactly one.");
}

unittest // the declared NAME, so a census can key on the field it means
{
    import std.format : format;
    assert(declaredVarName("    private MeshEditTracker* editRecorder_;",
                           "MeshEditTracker") == "editRecorder_",
        "the name behind a pointer type must come back whole");
    assert(declaredVarName("    MeshEditTracker* rec;", "MeshEditTracker")
             == "rec",
        "a field with NO visibility keyword is still a field — D's default "
      ~ "inside a struct is public, which is the spelling a `private …` "
      ~ "needle is least able to see and most likely to meet");
    assert(declaredVarName("        rec = new MeshEditTracker;",
                           "MeshEditTracker") is null,
        format("an assignment read as a declaration: %s",
               declaredVarName("        rec = new MeshEditTracker;",
                               "MeshEditTracker")));
}

unittest // a method is not a field, however much its head looks like one
{
    // Measured 2026-08-29 while wiring `commit_seam_census_test.d`'s
    // `editRecorder_` row onto this predicate: `source/mesh.d` declares the
    // ACCESSOR that replaced the field, and without the `(` test the row
    // reddened saying the field was back.
    assert(declaredVarName("    private MeshEditTracker* editRecorder_() const {",
                           "MeshEditTracker") is null,
        "an accessor `T* name() const {` was read as a FIELD `T* name`. The "
      ~ "row that keys on this predicate then reports the field it forbids "
      ~ "coming back, on a tree where it did not.");
    assert(declaredVarName("    private MeshEditTracker* editRecorder_;",
                           "MeshEditTracker") == "editRecorder_",
        "…and the real field spelling must still be seen, or the row is "
      ~ "vacuous in the other direction.");
}
