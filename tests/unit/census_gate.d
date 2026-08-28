// The test census gate (task 0835).
//
// WHY THIS EXISTS. In task 0706 an extraction driver rewrote its destination
// files instead of appending to them and destroyed 279 `unittest` blocks and
// 1492 assertions. The build was clean, 179 modules reported passing, and not
// one lane went red. The only instrument that noticed was a human counting the
// blocks before and after. Every lane since has counted by hand because the
// brief told it to — a mechanical check repeated on every batch, which is
// exactly the kind of thing that belongs in the tooling.
//
// WHAT IS GATED. Two integers over `source/` ∪ `tests/unit/`:
//
//     blocks   — `unittest` block declarations
//     asserts  — assertion tokens: `assert`, and every identifier that begins
//                `assert` and continues with an uppercase letter or `_`. That
//                second half is TASK 2007 FINDING #1 and it is not a widening
//                for tidiness: this repo's house style is the NAMED
//                verification helper (`assertRevertShape`, `assertResidualLaw`,
//                `assertDocInvariants`, ~40 more), which carries its own
//                `assert` ONCE at the definition — so under the old
//                three-literal rule deleting a CALL moved neither counter, and
//                six deleted `assertRevertShape(...)` calls (the whole residual
//                check for six kernel families) printed the same four numbers
//                byte for byte. Measured again after the fix: the same deletion
//                now moves `asserts` by exactly 6. See `isAssertName`.
//
// WHERE THE BASELINE LIVES. Not in a checked-in number: in git. The baseline is
// this lane's own history — the branch point (`git merge-base HEAD main`) and
// every commit since — counted with THIS scanner, so both sides of the
// comparison are measured by the same rule and a change to the rule cannot
// manufacture a delta. Storing a number instead would mean every lane that adds
// a test edits the same line of the same file, which under this repo's
// concurrent lanes is a rebase conflict per lane; and a number that is only
// refreshed sometimes accumulates slack, which is a gate that stops firing
// without anyone noticing.
//
// IN CI THE BRANCH POINT IS HANDED IN, BECAUSE CI HAS NONE (task 0850). A push
// build checks out `main` itself, so `merge-base HEAD main` IS HEAD, the tree
// equals its own baseline and nothing can fall below it; a pull-request build
// checks out a merge commit with neither `main` nor `origin/main` present at
// all. Both shapes were measured against this repository, and in the first one
// the gate looked perfectly healthy while being unable to fail.
// So the workflow passes the revision CI knows and git does not: the previous
// tip of the branch (`github.event.before`) or the PR base, through
// `VIBE3D_CENSUS_BRANCH_POINT`. That plus `fetch-depth: 0` (the clone must
// actually contain the revision) is the whole CI wiring, and both halves are
// self-defending: remove the depth and the named revision stops resolving,
// remove the variable and the baseline collapses onto HEAD — either way a run
// under GitHub Actions goes RED instead of quiet.
//
// THE INVARIANT. Let A be the live count and D the sum of declared drops in
// `tests/unit/census_ledger.txt`. The gate asserts
//
//     A(work) + D(work)  >=  max over lane revisions r of ( A(r) + D(r) )
//
// for blocks and for asserts, independently. In words: **live tests plus
// declared losses never decreases, and never falls back below the best this
// lane already reached**. Growth is free and costs no ceremony — nothing to
// edit, nothing to bump; committing it simply raises the bar. A drop is red
// until a ledger line accounts for it, and the arithmetic has to close exactly:
// under-declare by one block and the gate still fails, naming the shortfall. A
// ledger line already present at a baseline revision is folded into that
// revision's A + D, so an old declaration cannot be spent a second time.
//
// WHY THE MAXIMUM AND NOT JUST THE BRANCH POINT. Because against a single
// baseline a lane can pay for a loss with its own gains, and that is not a
// theoretical hole — it was measured while building this gate. With the branch
// point as the only baseline, deleting a real unittest block from
// `tests/unit/coord_rounding_test.d` left `dub test --config=tests` GREEN at
// exit 0, because this lane had already added nine blocks of its own and the
// net was still +8. A gate that stays green while a test is destroyed is the
// thing this task exists to prevent, so the bar is the running maximum: once
// additions are committed they raise it permanently and cannot be spent again.
// What remains uncovered is narrow and stated plainly — a loss and a
// compensating gain inside ONE uncommitted edit, which is the shape of a move.
//
// WHY IT IS STABLE UNDER A PURE MOVE. Nothing is counted per file or per
// module: the two integers are sums over the union of both roots. A block that
// moves from `source/x.d` to `tests/unit/x_test.d`, or a module split into
// three, leaves both sums untouched. Validated against the wave-3 splits — see
// the pure-move list in the task file.
//
// STANDALONE USE (counting an arbitrary tree, e.g. a historical checkout):
//
//     rdmd -version=CensusTool tests/unit/census_gate.d <tree-root>
//
module tests.unit.census_gate;

import std.array      : appender, array, join;
import std.algorithm  : sort, filter, map, endsWith, startsWith;
import std.conv       : to;
import std.exception  : collectException;
import std.file       : dirEntries, exists, isDir, read, SpanMode, tempDir, remove;
import std.format     : format;
import std.path       : buildPath, dirName, relativePath;
import std.process    : environment, execute, pipe, spawnProcess, wait, Config, thisProcessID;
import std.string     : strip, splitLines, indexOf;

// ---------------------------------------------------------------------------
// The counted quantities
// ---------------------------------------------------------------------------

/// One tree's (or one file's) census.
struct Census
{
    long blocks;           /// `unittest` block declarations
    long asserts;          /// assertion tokens, anywhere in the file
    long assertsInBlocks;  /// assertion tokens lexically inside a unittest body
    long helperAsserts;    /// the subset of `asserts` that are NAMED verification
                           /// helpers (`assertRevertShape`, `assertThrown`, …).
                           /// DIAGNOSTIC ONLY — folded into `asserts` for the
                           /// gate, broken out here so a failure can say which
                           /// kind went missing. See `isAssertName`.

    void opOpAssign(string op : "+")(const Census rhs) @safe pure nothrow @nogc
    {
        blocks          += rhs.blocks;
        asserts         += rhs.asserts;
        assertsInBlocks += rhs.assertsInBlocks;
        helperAsserts   += rhs.helperAsserts;
    }

    string toString() const @safe pure
    {
        return format("%d blocks / %d asserts (%d of them inside blocks, "
                    ~ "%d of them named helpers)",
                      blocks, asserts, assertsInBlocks, helperAsserts);
    }
}

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------
//
// A D lexer reduced to exactly what the two counts need. It is a lexer and not
// a set of regexes on purpose: the two counters this session found wrong were
// both wrong for lexical reasons — one matched the word `unittest` inside a
// comment and inflated by 14, the other tripped over assertions spanning
// several lines. Comments, string literals of every form D has, and character
// literals are skipped here, so neither mistake is reachable.
//
// What counts as a block: the keyword `unittest` at a token boundary whose next
// significant character is `{`. That is the only form the declaration has, and
// it excludes `version (unittest)` / `debug (unittest)`, where the next
// character is `)`.
//
// What counts as an assertion: one of a NAMED set of identifiers at a token
// boundary, OUTSIDE an import declaration. The set is explicit rather than a
// prefix match so that a new helper is added deliberately, in a diff, and so
// `assertionsRemaining` or any other identifier that merely starts with the
// word is not swept in. `static assert` counts — it is an assertion, and the
// compiler is the thing running it.
//
// The import exclusion is not fastidiousness, it is the pure-move requirement.
// `import std.exception : assertThrown;` names an assertion helper without
// being one, and a block that uses `assertThrown` needs exactly such a line in
// whatever file it moves to — so counting it makes a pure move read as +1. That
// is not hypothetical: commit 8928893d, a 207-file extraction, measured +1
// assert against this scanner before the exclusion existed, and the entire +1
// was `tests/unit/argstring_test.d`'s new selective import.

/// Skip whitespace and comments; return the index of the next real character.
private size_t peekSignificant(const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    const n = s.length;
    while (i < n)
    {
        const c = s[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { ++i; continue; }
        if (c == '/' && i + 1 < n)
        {
            if (s[i + 1] == '/')
            {
                i += 2;
                while (i < n && s[i] != '\n') ++i;
                continue;
            }
            if (s[i + 1] == '*')
            {
                i += 2;
                while (i + 1 < n && !(s[i] == '*' && s[i + 1] == '/')) ++i;
                i = (i + 1 < n) ? i + 2 : n;
                continue;
            }
            if (s[i + 1] == '+')
            {
                int nest = 1;
                i += 2;
                while (i + 1 < n && nest > 0)
                {
                    if (s[i] == '/' && s[i + 1] == '+') { ++nest; i += 2; }
                    else if (s[i] == '+' && s[i + 1] == '/') { --nest; i += 2; }
                    else ++i;
                }
                if (nest > 0) i = n;
                continue;
            }
        }
        return i;
    }
    return n;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
}

private bool isIdentChar(char c) @safe pure nothrow @nogc
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

/// Is `id` an assertion token?
///
/// TASK 2007 FINDING #1 — WHY THIS IS A PREFIX RULE AND NOT THREE LITERALS.
/// This predicate used to be the enumeration
/// `id == "assert" || id == "assertThrown" || id == "assertNotThrown"`, and the
/// hole that leaves is the widest one that sweep found, because it grows with
/// the practice this repo actively encourages: a NAMED verification helper
/// carries its `assert` ONCE, at its DEFINITION, so deleting a CALL moves
/// neither counter by one. Measured on live data: six of the seven
/// `assertRevertShape(...)` calls in `tests/unit/face_reindex_arming_test.d`
/// were deleted — the whole residual check for six kernel families, each call
/// running four residual laws over every plane — and the census printed
/// `blocks=2301 asserts=13025 assertsInBlocks=12623 files=644` byte for byte
/// before and after.
///
/// It matters more than the other twelve findings put together because it is
/// the gate that would notice ANY of their fixes being silently deleted later.
///
/// THE RULE: an identifier that begins with `assert` and continues with an
/// UPPERCASE letter or `_`. Mechanical rather than a registry on purpose — a
/// hand-maintained list of helper names is the same defect one level up (a new
/// helper joins the tree, nobody adds it, the count stops moving). It subsumes
/// the two Phobos names the enumeration used to spell, and it rejects
/// `asserts`, `assertion`, `assertsInBlocks` — a lowercase continuation is a
/// different word, not a helper.
///
/// `check…` IS DELIBERATELY NOT INCLUDED. `assertX` is a naming convention that
/// means one thing here; `checkX` is an ordinary verb that names plenty of
/// production logic (`checkBounds`, `checkGlError`), and counting those would
/// make the assert bar move on refactors that touch no test at all.
private bool isAssertName(const(char)[] id) @safe pure nothrow @nogc
{
    if (id.length < 6 || id[0 .. 6] != "assert") return false;
    if (id.length == 6) return true;                       // bare `assert`
    const char c = id[6];
    return (c >= 'A' && c <= 'Z') || c == '_';
}

/// The helper half of `isAssertName`, for the REPORT only — it is not gated
/// separately (that would need a third column in `census_ledger.txt` and would
/// invalidate every line already in it). Its whole job is to let a failure
/// message say WHICH kind of assertion went missing.
private bool isHelperAssertName(const(char)[] id) @safe pure nothrow @nogc
{
    return isAssertName(id) && id != "assert";
}

/// Count the census of one D source text.
Census scanD(const(char)[] s) @safe pure nothrow @nogc
{
    Census c;

    size_t i = 0;
    const n  = s.length;

    int  depth       = 0;   // brace nesting outside token strings
    int  utBodyDepth = -1;  // brace depth the innermost open unittest body sits at
    bool pending     = false; // saw `unittest`, waiting to see whether a `{` follows
    int  tokenString = 0;   // `q{ }` nesting; 0 == not inside one
    bool inImport    = false; // inside an import DECLARATION, up to its `;`

    while (i < n)
    {
        const char ch = s[i];

        // ---- comments -----------------------------------------------------
        // A comment never clears `pending`: `unittest /* note */ { }` is one
        // block, and the banner comments this repo puts above its blocks make
        // that shape common.
        if (ch == '/' && i + 1 < n)
        {
            if (s[i + 1] == '/')
            {
                i += 2;
                while (i < n && s[i] != '\n') ++i;
                continue;
            }
            if (s[i + 1] == '*')
            {
                i += 2;
                while (i + 1 < n && !(s[i] == '*' && s[i + 1] == '/')) ++i;
                i = (i + 1 < n) ? i + 2 : n;
                continue;
            }
            if (s[i + 1] == '+')
            {
                int nest = 1;
                i += 2;
                while (i + 1 < n && nest > 0)
                {
                    if (s[i] == '/' && s[i + 1] == '+') { ++nest; i += 2; }
                    else if (s[i] == '+' && s[i + 1] == '/') { --nest; i += 2; }
                    else ++i;
                }
                if (nest > 0) i = n;
                continue;
            }
        }

        // ---- string and character literals ---------------------------------
        if (ch == '"')  { i = skipQuoted(s, i, /*escapes=*/true);  pending = false; continue; }
        if (ch == '`')  { i = skipWysiwyg(s, i, '`');              pending = false; continue; }
        if (ch == '\'') { i = skipQuoted(s, i, /*escapes=*/true);  pending = false; continue; }

        // ---- identifiers ---------------------------------------------------
        if (isIdentStart(ch))
        {
            size_t j = i;
            while (j < n && isIdentChar(s[j])) ++j;
            const id = s[i .. j];

            // Literal prefixes: `r"raw"`, `x"CAFE"`, `q{ tokens }`, `q"( )"`.
            // The `"`/`{` must abut the prefix, which is what D requires too,
            // so an ordinary identifier `r` or `q` followed by an operator is
            // never mistaken for one.
            if (j < n)
            {
                if ((id == "r" || id == "x") && s[j] == '"')
                {
                    i = skipWysiwyg(s, j, '"');
                    pending = false;
                    continue;
                }
                if (id == "q" && s[j] == '{')
                {
                    tokenString = 1;
                    i = j + 1;
                    pending = false;
                    continue;
                }
                if (id == "q" && s[j] == '"')
                {
                    i = skipDelimited(s, j);
                    pending = false;
                    continue;
                }
            }

            if (tokenString == 0 && !inImport)
            {
                if (id == "unittest")
                {
                    pending = true;
                    i = j;
                    continue;
                }
                // `import a.b : c;` is a declaration and ends at its `;`;
                // `import("file")` is an expression and is not skipped.
                if (id == "import" && peekSignificant(s, j) < n && s[peekSignificant(s, j)] != '(')
                {
                    inImport = true;
                    pending  = false;
                    i = j;
                    continue;
                }
                if (isAssertName(id))
                {
                    ++c.asserts;
                    if (isHelperAssertName(id)) ++c.helperAsserts;
                    if (utBodyDepth >= 0) ++c.assertsInBlocks;
                }
            }

            pending = false;
            i = j;
            continue;
        }

        // ---- braces ---------------------------------------------------------
        if (ch == '{')
        {
            if (tokenString > 0) { ++tokenString; ++i; continue; }
            if (pending)
            {
                ++c.blocks;
                if (utBodyDepth < 0) utBodyDepth = depth;
                pending = false;
            }
            ++depth;
            ++i;
            continue;
        }
        if (ch == '}')
        {
            if (tokenString > 0) { --tokenString; ++i; continue; }
            --depth;
            if (utBodyDepth >= 0 && depth <= utBodyDepth) utBodyDepth = -1;
            ++i;
            continue;
        }

        if (ch == ';') inImport = false;

        // Whitespace between `unittest` and its `{` is expected; anything else
        // means the keyword was not a block declaration.
        if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') pending = false;
        ++i;
    }

    return c;
}

/// Skip a literal opened at `i` by its quote character, honouring `\` escapes.
private size_t skipQuoted(const(char)[] s, size_t i, bool escapes) @safe pure nothrow @nogc
{
    const n     = s.length;
    const quote = s[i];
    ++i;
    while (i < n)
    {
        if (escapes && s[i] == '\\') { i += 2; continue; }
        if (s[i] == quote) return i + 1;
        ++i;
    }
    return n;
}

/// Skip a literal with no escape processing (backtick, `r"`, `x"`).
private size_t skipWysiwyg(const(char)[] s, size_t i, char quote) @safe pure nothrow @nogc
{
    const n = s.length;
    ++i;
    while (i < n && s[i] != quote) ++i;
    return (i < n) ? i + 1 : n;
}

/// Skip a delimited string `q"( … )"` / `q"IDENT … IDENT"` opened at the `"`.
private size_t skipDelimited(const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    const n = s.length;
    ++i;                       // past the `"`
    if (i >= n) return n;

    const char open = s[i];

    // THE HEREDOC FORM — `q"IDENT<newline> … <newline>IDENT"`. Added at task
    // 2007 alongside finding #1, and it was not hygiene: without it this
    // function fell into the `default` arm below with `close == 'P'` for
    // `q"PROBE`, found no `P"` anywhere, returned `n`, and SWALLOWED THE REST
    // OF THE FILE. Eight files under the two scanned roots use the form — all
    // of them census tests, whose probes are exactly this shape — so every
    // `unittest` block and every assertion after the first probe in each of
    // them was invisible to the gate that exists to notice tests being
    // destroyed. Measured on `tests/unit/mesh_dirty_cliff_series_test.d`:
    // 4 blocks / 11 asserts read as 1 / 0.
    if (isIdentStart(open))
    {
        size_t t = i;
        while (t < n && isIdentChar(s[t])) ++t;
        const tag = s[i .. t];
        // The terminator is the tag again, immediately followed by `"`.
        size_t k = t;
        while (k + tag.length < n)
        {
            if (s[k .. k + tag.length] == tag
                && s[k + tag.length] == '"') return k + tag.length + 1;
            ++k;
        }
        return n;
    }

    char close;
    switch (open)
    {
        case '(':  close = ')'; break;
        case '[':  close = ']'; break;
        case '{':  close = '}'; break;
        case '<':  close = '>'; break;
        default:   close = open; break;   // single-character delimiter
    }
    const bool nests = (close != open);
    ++i;
    int depth = 1;
    while (i + 1 < n)
    {
        if (nests && s[i] == open) ++depth;
        else if (s[i] == close)
        {
            if (!nests || depth == 1)
            {
                if (s[i + 1] == '"') return i + 2;
            }
            else --depth;
        }
        ++i;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Walking a tree
// ---------------------------------------------------------------------------

/// The two roots the census covers. `source/render/**` and `source/material/**`
/// are inside `source/` and therefore counted, even though the `tests`
/// configuration does not compile them: the point is that a block cannot vanish
/// unnoticed, and a block nobody compiles is the easiest kind to lose.
immutable string[] censusRoots = ["source", "tests/unit"];

/// One file's contribution, keyed by its repo-relative path with `/` separators.
struct FileCensus
{
    string  path;
    Census  census;
}

/// Census of a working-tree checkout rooted at `root`.
FileCensus[] scanWorkingTree(string root)
{
    auto acc = appender!(FileCensus[]);
    foreach (sub; censusRoots)
    {
        const dir = buildPath(root, sub);
        if (!exists(dir) || !isDir(dir)) continue;
        foreach (entry; dirEntries(dir, SpanMode.depth))
        {
            if (!entry.isFile || !entry.name.endsWith(".d")) continue;
            auto rel = relativePath(entry.name, root);
            version (Windows) { import std.array : replace; rel = rel.replace("\\", "/"); }
            // Keep the key identical to git's, so the per-file report can pair
            // the two sides even when the tool is pointed at `.`.
            if (rel.startsWith("./")) rel = rel[2 .. $];
            auto bytes = cast(const(char)[]) read(entry.name);
            acc.put(FileCensus(rel, scanD(bytes)));
        }
    }
    auto files = acc.data;
    files.sort!((a, b) => a.path < b.path);
    return files;
}

/// Sum of a per-file census list.
Census total(const FileCensus[] files) @safe pure nothrow @nogc
{
    Census t;
    foreach (ref f; files) t += f.census;
    return t;
}

// ---------------------------------------------------------------------------
// The ledger of declared drops
// ---------------------------------------------------------------------------

/// Repo-relative path of the ledger. It is read from the working tree AND from
/// the branch point, and only the difference between the two grants anything.
enum ledgerPath = "tests/unit/census_ledger.txt";

/// Sum of the drops a ledger declares. Blank lines and `#` comments are
/// ignored; anything else must be a well-formed `drop` line, so a typo in a
/// declaration is loud instead of silently granting nothing.
Census parseLedger(const(char)[] text, string origin)
{
    Census d;
    foreach (lineNo, line; text.splitLines)
    {
        auto t = line.strip;
        if (t.length == 0 || t[0] == '#') continue;
        if (!t.startsWith("drop "))
            throw new Exception(format(
                "%s:%d: not a declaration — every non-comment line must read " ~
                "`drop <blocks> <asserts> <task> <why>`, got: %s",
                origin, lineNo + 1, t));

        auto rest = t["drop ".length .. $].strip;
        long[2] nums;
        foreach (k; 0 .. 2)
        {
            size_t sp = 0;
            while (sp < rest.length && rest[sp] != ' ' && rest[sp] != '\t') ++sp;
            if (sp == 0 || sp == rest.length)
                throw new Exception(format(
                    "%s:%d: expected `drop <blocks> <asserts> <task> <why>`, got: %s",
                    origin, lineNo + 1, t));
            try nums[k] = rest[0 .. sp].to!long;
            catch (Exception)
                throw new Exception(format(
                    "%s:%d: `%s` is not a whole number of %s",
                    origin, lineNo + 1, rest[0 .. sp], k == 0 ? "blocks" : "asserts"));
            if (nums[k] < 0)
                throw new Exception(format(
                    "%s:%d: declare the MAGNITUDE of the drop, not a negative number: %s",
                    origin, lineNo + 1, t));
            rest = rest[sp .. $].strip;
        }
        if (rest.length == 0)
            throw new Exception(format(
                "%s:%d: a declared drop needs a task id and a reason: %s",
                origin, lineNo + 1, t));

        d.blocks  += nums[0];
        d.asserts += nums[1];
    }
    return d;
}

// ---------------------------------------------------------------------------
// The branch point, read through git
// ---------------------------------------------------------------------------

private struct GitOut { int status; string text; }

private GitOut git(string root, const(string)[] args)
{
    try
    {
        auto r = execute(["git"] ~ args, null, Config.none, size_t.max, root);
        return GitOut(r.status, r.output);
    }
    catch (Exception) { return GitOut(-1, ""); }
}

/// The environment variable through which CI hands in the branch point it knows
/// and the checkout does not. `none` is the one accepted excuse for having no
/// baseline at all (a fork, a first commit) — spelled out in the workflow file
/// where a reader can see it, rather than inferred from silence.
enum branchPointEnv = "VIBE3D_CENSUS_BRANCH_POINT";

/// Everything the baseline search decided, so the gate can tell "no baseline
/// exists" apart from "a baseline was named and this checkout does not have it".
struct Baseline
{
    string[] revs;        /// the revisions to take the maximum over; empty ⇒ no git
    /// The only revision left is HEAD, so the tree is being compared against
    /// itself and the gate cannot fail on anything already committed.
    bool     degraded;
    bool     supplied;    /// `branchPointEnv` named a revision
    bool     unresolved;  /// ... and git could not turn it into a commit
    bool     blindOnPurpose; /// `branchPointEnv` was the literal `none`
    /// The checkout is a shallow clone, so history is cut off at a graft and
    /// every range that crosses it answers with a number rather than an error.
    bool     shallow;
}

/// The revisions the working tree is measured against: the branch point, and
/// every commit the lane has made since.
///
/// WHY THE WHOLE LANE AND NOT JUST THE BRANCH POINT. Because a single baseline
/// lets a lane pay for a loss with its own gains. Measured, on this very task:
/// with the branch point as the only baseline, deleting a real unittest block
/// left the gate GREEN, because this lane had already added nine blocks of its
/// own and the net was still positive. That is the gate not firing, which is
/// the failure mode the whole task exists to prevent. Taking the MAXIMUM over
/// the lane closes it: additions raise the bar the moment they are committed,
/// so they can never be spent again.
///
/// WHERE THE BRANCH POINT COMES FROM, in order: `VIBE3D_CENSUS_BASE` (pins ONE
/// revision — a tool for aiming the gate and for the negative control, not an
/// escape hatch: whatever it names, the invariant still has to hold against
/// it); then `VIBE3D_CENSUS_BRANCH_POINT`, which CI fills from the event
/// (task 0850) and which is walked to HEAD like any other branch point; then
/// `merge-base HEAD main`. A supplied revision is passed through `merge-base`
/// too, so a force-push whose old tip is no longer an ancestor still yields a
/// real fork point instead of a range that walks the wrong way.
Baseline laneRevisions(string root)
{
    Baseline b;

    auto head = git(root, ["rev-parse", "HEAD"]);
    if (head.status != 0 || head.text.strip.length == 0) return b;
    const h = head.text.strip;

    // A shallow clone answers questions about history it does not have, and it
    // answers them with numbers. MEASURED: fetch the branch point on its own
    // into a depth-1 checkout — the cheap option this task was asked to
    // consider — and `rev-parse` resolves it, `merge-base` exits 1, and
    // `rev-list base..HEAD` reports ONE commit for a 21-commit lane because the
    // graft cuts the walk. The gate then compares against a real tree by a lane
    // that is not the lane, and passes. So shallowness is recorded and, under
    // CI, refused: it is not a baseline, it is a plausible-looking guess.
    b.shallow = git(root, ["rev-parse", "--is-shallow-repository"]).text.strip == "true";

    auto forced = environment.get("VIBE3D_CENSUS_BASE", "").strip;
    if (forced.length)
    {
        b.revs     = [forced];
        b.degraded = (forced == h);
        return b;
    }

    string base;

    auto named = environment.get(branchPointEnv, "").strip;
    if (named == "none")
        b.blindOnPurpose = true;
    else if (named.length && !isNullSha(named))
    {
        // An all-zero sha is git's way of saying "there was nothing here
        // before" — the first push of a branch. That is an absent baseline,
        // not a broken one, so it is not treated as supplied.
        b.supplied = true;
        auto mb = git(root, ["merge-base", "HEAD", named]);
        if (mb.status == 0 && mb.text.strip.length) base = mb.text.strip;
        else
        {
            auto rp = git(root, ["rev-parse", "--verify", "--quiet", named ~ "^{commit}"]);
            if (rp.status == 0 && rp.text.strip.length) base = rp.text.strip;
            else b.unresolved = true;   // named but absent: a shallow clone does this
        }
    }

    if (base.length == 0)
        foreach (mainRef; ["main", "origin/main"])
        {
            auto mb = git(root, ["merge-base", "HEAD", mainRef]);
            if (mb.status == 0 && mb.text.strip.length) { base = mb.text.strip; break; }
        }

    // No branch point, or a branch point that IS the head: either way the only
    // bar is the tree itself. The two are one state on purpose — what matters
    // is not whether a `main` was found but whether anything can fail, and a
    // push build that checks out `main` finds one and still cannot fail.
    if (base.length == 0 || base == h)
    {
        b.degraded = true;
        b.revs     = [h];
        return b;
    }

    auto revs = appender!(string[]);
    revs.put(base);
    auto rl = git(root, ["rev-list", "--max-count=" ~ maxLaneRevisions.to!string,
                         base ~ ".." ~ h]);
    if (rl.status == 0)
        foreach (line; rl.text.splitLines)
        {
            auto t = line.strip;
            if (t.length) revs.put(t);
        }
    b.revs = revs.data;
    return b;
}

/// git's "nothing was here before" sha: forty zeroes, what a push event carries
/// as its `before` when it creates the branch.
private bool isNullSha(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length < 7) return false;
    foreach (c; s) if (c != '0') return false;
    return true;
}

/// A lane longer than this is not a lane; the cap keeps a pathological branch
/// point from turning the gate into a history walk.
enum maxLaneRevisions = 512;

/// One `git ls-tree` record under the census roots.
private struct TreeEntry { string oid; string path; }

/// Tree entries at `rev`: the `.d` files, plus the ledger if it exists there.
private TreeEntry[] revEntries(string root, string rev)
{
    auto ls = git(root, ["ls-tree", "-r", "-z", rev, "--"] ~ censusRoots.dup);
    if (ls.status != 0) return null;

    auto acc = appender!(TreeEntry[]);
    size_t start = 0;
    foreach (i, ch; ls.text)
    {
        if (ch != '\0') continue;
        auto rec = ls.text[start .. i];
        start = i + 1;

        // "<mode> <type> <oid>\t<path>"
        auto tab = rec.indexOf('\t');
        if (tab < 0) continue;
        auto head3 = rec[0 .. tab];
        auto path  = rec[tab + 1 .. $];
        auto sp    = head3.lastIndexOf(' ');
        if (sp < 0) continue;
        auto oid = head3[sp + 1 .. $];

        if (path == ledgerPath || path.endsWith(".d"))
            acc.put(TreeEntry(oid, path));
    }
    return acc.data;
}

/// Fill the caches for every blob in `revs` not already known, in ONE
/// `git cat-file` call.
///
/// The census of a blob is a pure function of its bytes, so caching by object
/// id is exact — and it is what makes walking a whole lane cost about what
/// walking one revision costs, since adjacent commits share nearly every blob.
private void fetchBlobs(string root, const(TreeEntry[])[] revs,
                        ref Census[string] blobCensus,
                        ref Census[string] ledgerDrops)
{
    bool[string] wantLedger;
    auto order = appender!(string[]);
    foreach (entries; revs)
        foreach (ref e; entries)
        {
            if (e.path == ledgerPath)
            {
                if (e.oid in ledgerDrops || e.oid in wantLedger) continue;
                wantLedger[e.oid] = true;
                order.put(e.oid);
            }
            else
            {
                if (e.oid in blobCensus) continue;
                blobCensus[e.oid] = Census.init;   // claim the slot, keep order unique
                order.put(e.oid);
            }
        }

    auto oids = order.data;
    if (oids.length == 0) return;

    auto blob = catFileBatch(root, oids);
    size_t pos = 0;
    foreach (oid; oids)
    {
        auto nl = blob.length;
        foreach (k; pos .. blob.length) if (blob[k] == '\n') { nl = k; break; }
        if (nl >= blob.length) break;
        auto header = cast(const(char)[]) blob[pos .. nl];
        pos = nl + 1;
        if (header.endsWith("missing")) continue;

        auto sp = header.lastIndexOf(' ');
        if (sp < 0) break;
        size_t size;
        try size = header[sp + 1 .. $].to!size_t;
        catch (Exception) break;
        if (pos + size > blob.length) break;

        auto text = cast(const(char)[]) blob[pos .. pos + size];
        pos += size + 1;                       // blob plus its trailing newline

        if (oid in wantLedger) ledgerDrops[oid] = parseLedger(text, ledgerPath ~ " @" ~ oid[0 .. 8]);
        else                   blobCensus[oid]  = scanD(text);
    }
}

/// Read many blobs from one `git cat-file --batch` process.
///
/// The path list goes in through a FILE rather than a pipe on purpose: writing
/// the request into a pipe while the answer (megabytes) is still buffering on
/// the other one is the classic way to deadlock a child process.
private ubyte[] catFileBatch(string root, const(string)[] specs)
{
    import std.stdio : File, stderr;
    import std.file  : write;

    const tmp = buildPath(tempDir(), format("vibe3d-census-%d.batch", thisProcessID));
    write(tmp, specs.join("\n") ~ "\n");
    scope(exit) collectException(remove(tmp));

    auto fin  = File(tmp, "rb");
    auto outp = pipe();
    auto pid  = spawnProcess(["git", "cat-file", "--batch"],
                             fin, outp.writeEnd, stderr, null, Config.none, root);
    outp.writeEnd.close();

    auto acc = appender!(ubyte[]);
    ubyte[1 << 16] buf;
    for (;;)
    {
        auto chunk = outp.readEnd.rawRead(buf[]);
        if (chunk.length == 0) break;
        acc.put(chunk);
    }
    wait(pid);
    return acc.data;
}

/// Per-file census of the tree at `rev`. Empty when git cannot answer.
FileCensus[] scanRevision(string root, string rev)
{
    auto entries = revEntries(root, rev);
    if (entries.length == 0) return null;

    Census[string] blobCensus;
    Census[string] ledgerDrops;
    fetchBlobs(root, [entries], blobCensus, ledgerDrops);
    return filesOf(entries, blobCensus);
}

/// Rebuild the per-file census of a revision from its entries and the cache.
private FileCensus[] filesOf(const(TreeEntry)[] entries, const Census[string] blobCensus)
{
    auto acc = appender!(FileCensus[]);
    foreach (ref e; entries)
    {
        if (e.path == ledgerPath) continue;
        if (auto c = e.oid in blobCensus) acc.put(FileCensus(e.path, *c));
    }
    auto files = acc.data;
    files.sort!((a, b) => a.path < b.path);
    return files;
}

/// Drops declared by the ledger at a revision (zero when it has none).
private Census dropsOf(const(TreeEntry)[] entries, const Census[string] ledgerDrops)
{
    foreach (ref e; entries)
        if (e.path == ledgerPath)
            if (auto d = e.oid in ledgerDrops) return *d;
    return Census.init;
}

private ptrdiff_t lastIndexOf(const(char)[] s, char c) @safe pure nothrow @nogc
{
    for (ptrdiff_t k = cast(ptrdiff_t) s.length - 1; k >= 0; --k)
        if (s[k] == c) return k;
    return -1;
}

private ptrdiff_t indexOf(const(char)[] s, char c) @safe pure nothrow @nogc
{
    foreach (k, ch; s) if (ch == c) return k;
    return -1;
}

// ---------------------------------------------------------------------------
// The verdict
// ---------------------------------------------------------------------------

/// Everything the gate measured, so the failure message can be specific about
/// which files lost what rather than only naming a total.
struct Verdict
{
    bool          ran;         /// false when git could not answer at all
    /// True when the only baseline left is HEAD, so the tree is compared
    /// against itself and nothing already committed can fail. The check still
    /// catches an uncommitted destruction. Both CI shapes landed here before
    /// task 0850 — a shallow PR clone with no `main` at all, and a push build
    /// that has `main` and is standing on it.
    bool          degraded;
    bool          baselineSupplied;   /// `VIBE3D_CENSUS_BRANCH_POINT` named a revision
    bool          baselineUnresolved; /// ... and this checkout does not contain it
    bool          blindOnPurpose;     /// `VIBE3D_CENSUS_BRANCH_POINT=none`
    bool          shallowClone;       /// history is grafted, so any range is a guess
    string        baseRev;     /// the HIGH-WATER revision, the one that binds
    size_t        revsWalked;
    Census        work, base;  /// live counts
    Census        workDrops, baseDrops;
    FileCensus[]  workFiles, baseFiles;

    /// Slack in the invariant, per quantity. Negative means the gate fails.
    long blocksSlack()  const @safe pure nothrow @nogc
    {
        return (work.blocks + workDrops.blocks) - (base.blocks + baseDrops.blocks);
    }
    long assertsSlack() const @safe pure nothrow @nogc
    {
        return (work.asserts + workDrops.asserts) - (base.asserts + baseDrops.asserts);
    }
    bool ok() const @safe pure nothrow @nogc
    {
        return !ran || (blocksSlack >= 0 && assertsSlack >= 0);
    }
}

/// Run the census comparison for the checkout at `root`.
Verdict judge(string root)
{
    Verdict v;

    auto baseline = laneRevisions(root);
    auto revs     = baseline.revs;
    if (revs.length == 0) return v;                   // no git: v.ran stays false
    v.degraded           = baseline.degraded;
    v.baselineSupplied   = baseline.supplied;
    v.baselineUnresolved = baseline.unresolved;
    v.blindOnPurpose     = baseline.blindOnPurpose;
    v.shallowClone       = baseline.shallow;

    auto entries = new TreeEntry[][](revs.length);
    foreach (i, rev; revs)
    {
        entries[i] = revEntries(root, rev);
        if (entries[i].length == 0) return v;         // shallow clone / unknown rev
    }

    Census[string] blobCensus;
    Census[string] ledgerDrops;
    fetchBlobs(root, entries, blobCensus, ledgerDrops);

    size_t bestIx;
    long   bestBar = long.min;
    Census bestLive, bestDrops;
    foreach (i; 0 .. revs.length)
    {
        const live  = total(filesOf(entries[i], blobCensus));
        const drops = dropsOf(entries[i], ledgerDrops);
        // One scalar picks the binding revision, so the failure message names a
        // single coherent baseline instead of two different ones.
        const bar = (live.blocks + drops.blocks) + (live.asserts + drops.asserts);
        if (bar > bestBar) { bestBar = bar; bestIx = i; bestLive = live; bestDrops = drops; }
    }

    v.baseRev    = revs[bestIx];
    v.revsWalked = revs.length;
    v.baseFiles  = filesOf(entries[bestIx], blobCensus);
    v.base       = bestLive;
    v.baseDrops  = bestDrops;

    v.workFiles  = scanWorkingTree(root);
    v.work       = total(v.workFiles);

    const workLedgerPath = buildPath(root, ledgerPath);
    v.workDrops = parseLedger(
        exists(workLedgerPath) ? cast(const(char)[]) read(workLedgerPath) : "",
        ledgerPath ~ " (working tree)");

    v.ran = true;
    return v;
}

/// The message a failing census prints. Kept out of the unittest so its shape
/// can be exercised without provoking a real loss.
string report(const ref Verdict v)
{
    auto s = appender!string;
    s.put("TEST CENSUS DROPPED (task 0835)\n");
    s.put(format("  high-water rev : %s   (of %d lane revision(s))\n", v.baseRev, v.revsWalked));
    s.put(format("  blocks         : %d there -> %d now  (declared drops %d -> %d)  slack %d\n",
                 v.base.blocks, v.work.blocks, v.baseDrops.blocks, v.workDrops.blocks, v.blocksSlack));
    s.put(format("  asserts        : %d there -> %d now  (declared drops %d -> %d)  slack %d\n",
                 v.base.asserts, v.work.asserts, v.baseDrops.asserts, v.workDrops.asserts, v.assertsSlack));

    // Per-file losses, biggest first — the 0706 failure would have named its
    // own destination files here.
    long[string] baseBlocks, baseAsserts;
    foreach (ref f; v.baseFiles) { baseBlocks[f.path] = f.census.blocks; baseAsserts[f.path] = f.census.asserts; }
    long[string] workBlocks, workAsserts;
    foreach (ref f; v.workFiles) { workBlocks[f.path] = f.census.blocks; workAsserts[f.path] = f.census.asserts; }

    struct Loss { string path; long db, da; }
    auto losses = appender!(Loss[]);
    foreach (path, b; baseBlocks)
    {
        const db = (path in workBlocks  ? workBlocks[path]  : 0) - b;
        const da = (path in workAsserts ? workAsserts[path] : 0) - baseAsserts[path];
        if (db < 0 || da < 0) losses.put(Loss(path, db, da));
    }
    auto ls = losses.data;
    ls.sort!((a, b) => (a.db + a.da) < (b.db + b.da));
    if (ls.length)
    {
        s.put("  files that lost tests (a pure MOVE shows up here too — check the gainers):\n");
        foreach (l; ls[0 .. ls.length > 12 ? 12 : $])
            s.put(format("    %+4d blocks %+5d asserts  %s\n", l.db, l.da, l.path));
    }

    s.put("\n  If the loss is deliberate, declare it: append one line to\n");
    s.put("  " ~ ledgerPath ~ "\n");
    s.put(format("      drop %d %d <task-id> <what was removed and why>\n",
                 v.blocksSlack < 0 ? -v.blocksSlack : 0,
                 v.assertsSlack < 0 ? -v.assertsSlack : 0));
    s.put("  The numbers must close exactly; under-declaring leaves the gate red.\n");
    return s.data;
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

/// The repo this test binary was built from.
private enum censusRepoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest
{
    import std.stdio : stderr;

    auto v = judge(censusRepoRoot);

    if (!v.ran)
    {
        // No git, no branch point, nothing to compare against. Say so loudly:
        // a check that quietly passes when it cannot run is the exact shape of
        // the two CI lanes this repo found green-but-idle.
        stderr.writeln("census gate: SKIPPED — git could not answer for ", censusRepoRoot,
                       " (set VIBE3D_CENSUS_BASE=<rev> to force a baseline)");
        return;
    }

    if (v.degraded)
        stderr.writefln("census gate: DEGRADED — the only baseline is HEAD itself " ~
                        "(%d blocks / %d asserts), so the tree is being compared against " ~
                        "the revision it was checked out from. Uncommitted losses are still " ~
                        "caught; committed ones are not. Standing on `main` does this, and " ~
                        "so does a shallow clone — hand in a branch point with %s=<rev>, or " ~
                        "pin one with VIBE3D_CENSUS_BASE=<rev>.",
                        v.base.blocks, v.base.asserts, branchPointEnv);

    // Under CI, blindness is a failure and not a footnote (task 0850).
    //
    // `GITHUB_ACTIONS` is set by the runner, not by our workflow file, so this
    // rule cannot be switched off by editing the workflow — which is the point.
    // Both ways the CI wiring can rot are covered: drop `fetch-depth: 0` and the
    // named revision stops resolving; drop the environment variable and the
    // baseline collapses onto HEAD. Before this task the second one was the live
    // state of the lane, and it printed nothing at all.
    if (environment.get("GITHUB_ACTIONS", "") == "true")
    {
        assert(!v.shallowClone || v.blindOnPurpose, format(
            "census gate: this checkout is a SHALLOW clone, so the history behind " ~
            "any revision is cut off at a graft and a lane walk over it returns a " ~
            "number instead of an error (measured: one commit for a 21-commit lane). " ~
            "Set `fetch-depth: 0` on actions/checkout — fetching the branch point on " ~
            "its own is not a substitute, it is the failure mode."));

        assert(!v.baselineUnresolved, format(
            "census gate: %s names %s, which this checkout does not contain — the " ~
            "clone is too shallow to hold it. Restore `fetch-depth: 0` on " ~
            "actions/checkout, or set %s=none if this build genuinely has no " ~
            "baseline (a fork, a first commit).",
            branchPointEnv, environment.get(branchPointEnv, ""), branchPointEnv));

        assert(!v.degraded || v.blindOnPurpose, format(
            "census gate: running under CI with no baseline but HEAD — nothing " ~
            "committed can fail this check, which is the state task 0850 exists to " ~
            "end. Pass the branch point in: %s: ${{ github.event.before }} for a " ~
            "push, ${{ github.event.pull_request.base.sha }} for a pull request. If " ~
            "this build really has no baseline, say so with %s=none.",
            branchPointEnv, branchPointEnv));
    }

    assert(v.ok, report(v));
}

unittest
{
    // THE NEGATIVE CONTROL, AUTOMATED.
    //
    // A gate nobody has watched fail is indistinguishable from a gate that
    // never runs — this repo has now found two CI lanes in exactly that state.
    // So the verdict is exercised for real here, every run: a throwaway git
    // repo, a test taken away, and a check that the answer actually turns from
    // green to red and back. It was first done by hand against
    // `dub test --config=tests` (red at exit 2 naming the file, green once
    // declared); this is that transcript nailed down so it cannot rot.
    import std.file : mkdirRecurse, rmdirRecurse, write;

    const sandbox = buildPath(tempDir(), format("vibe3d-census-selftest-%d", thisProcessID));
    collectException(rmdirRecurse(sandbox));
    mkdirRecurse(buildPath(sandbox, "source"));
    mkdirRecurse(buildPath(sandbox, "tests", "unit"));
    scope(exit) collectException(rmdirRecurse(sandbox));

    // The gate under test must not read the ambient overrides — and under CI
    // one of them IS set, pointing at a revision of the real repository that
    // this sandbox has never heard of.
    const savedBase  = environment.get("VIBE3D_CENSUS_BASE", "");
    const savedPoint = environment.get(branchPointEnv, "");
    if (savedBase.length)  environment.remove("VIBE3D_CENSUS_BASE");
    if (savedPoint.length) environment.remove(branchPointEnv);
    scope(exit)
    {
        if (savedBase.length)  environment["VIBE3D_CENSUS_BASE"] = savedBase;
        if (savedPoint.length) environment[branchPointEnv]       = savedPoint;
    }

    const src = buildPath(sandbox, "source", "a.d");
    write(src, "unittest { assert(1); assert(2); }\nunittest { assert(3); }\n");

    if (git(sandbox, ["init", "-q"]).status != 0) return;      // no git on this host
    git(sandbox, ["symbolic-ref", "HEAD", "refs/heads/probe"]); // deliberately not `main`
    git(sandbox, ["add", "-A"]);
    git(sandbox, ["-c", "user.email=census@invalid", "-c", "user.name=census",
                  "commit", "-q", "-m", "baseline"]);

    auto v0 = judge(sandbox);
    if (!v0.ran) return;                    // git present but unusable; the gate says so itself
    assert(v0.ok, "a tree identical to its own baseline must be green");
    assert(v0.base.blocks == 2 && v0.base.asserts == 3, v0.base.toString);

    // Take one block away and declare nothing.
    write(src, "unittest { assert(1); assert(2); }\n");
    auto v1 = judge(sandbox);
    assert(!v1.ok, "an undeclared loss must be RED — this is the whole gate");
    assert(v1.blocksSlack == -1 && v1.assertsSlack == -1, report(v1));

    // Under-declare: the block is accounted for, the assertion is not.
    const ledger = buildPath(sandbox, ledgerPath);
    write(ledger, "drop 1 0 0835 under-declared on purpose\n");
    auto v2 = judge(sandbox);
    assert(!v2.ok, "under-declaring must stay RED, or the numbers mean nothing");
    assert(v2.blocksSlack == 0 && v2.assertsSlack == -1, report(v2));

    // Declare it exactly: green.
    write(ledger, "drop 1 1 0835 the second block, removed on purpose\n");
    auto v3 = judge(sandbox);
    assert(v3.ok, report(v3));

    // And a declaration cannot be spent twice: commit it, then take another
    // block away with the same line still standing.
    git(sandbox, ["add", "-A"]);
    git(sandbox, ["-c", "user.email=census@invalid", "-c", "user.name=census",
                  "commit", "-q", "-m", "declared"]);
    write(src, "// everything gone\n");
    auto v4 = judge(sandbox);
    assert(!v4.ok, "a ledger line already in the baseline must not pay for a second loss");
}

unittest
{
    // THE CI SHAPE, AUTOMATED (task 0850).
    //
    // The control above builds a lane and destroys a test in the WORKING TREE,
    // which is the shape a developer is in. CI is never in that shape: it
    // checks out a commit, so the loss it has to catch is already committed —
    // and against a baseline of HEAD a committed loss is invisible, because
    // HEAD is what the tree was made from.
    //
    // That is not a hypothetical. Measured on this repository before the fix:
    // a depth-1 checkout of `main` (53 of the last 60 runs of the lane) judged
    // `ran=true degraded=false ok=true` — not merely blind but showing no sign
    // of it, because `merge-base HEAD main` succeeds and returns HEAD. This
    // reproduces that state and then shows the supplied branch point turning it
    // red, which is the entire content of the CI wiring.
    import std.file : mkdirRecurse, rmdirRecurse, write;

    const sandbox = buildPath(tempDir(), format("vibe3d-census-cishape-%d", thisProcessID));
    collectException(rmdirRecurse(sandbox));
    mkdirRecurse(buildPath(sandbox, "source"));
    scope(exit) collectException(rmdirRecurse(sandbox));

    const savedBase  = environment.get("VIBE3D_CENSUS_BASE", "");
    const savedPoint = environment.get(branchPointEnv, "");
    if (savedBase.length)  environment.remove("VIBE3D_CENSUS_BASE");
    if (savedPoint.length) environment.remove(branchPointEnv);
    scope(exit)
    {
        if (savedBase.length)  environment["VIBE3D_CENSUS_BASE"] = savedBase;
        if (savedPoint.length) environment[branchPointEnv]       = savedPoint;
    }

    string commit(string root, string msg)
    {
        git(root, ["add", "-A"]);
        git(root, ["-c", "user.email=census@invalid", "-c", "user.name=census",
                   "commit", "-q", "-m", msg]);
        return git(root, ["rev-parse", "HEAD"]).text.strip;
    }

    const src = buildPath(sandbox, "source", "a.d");
    write(src, "unittest { assert(1); assert(2); }\nunittest { assert(3); }\n");

    if (git(sandbox, ["init", "-q"]).status != 0) return;      // no git on this host
    git(sandbox, ["symbolic-ref", "HEAD", "refs/heads/main"]); // a push build stands on main
    const before = commit(sandbox, "baseline");
    if (before.length == 0) return;

    // The loss, COMMITTED — a test destroyed by a merge that already landed.
    write(src, "unittest { assert(1); assert(2); }\n");
    commit(sandbox, "the extraction that ate a block");

    // What CI saw before this task: `main` resolves, merge-base is HEAD, the
    // tree equals its own baseline, and the verdict is a clean green.
    auto blind = judge(sandbox);
    assert(blind.ran);
    assert(blind.ok, "reproduction failed: this is supposed to be the INERT state");
    assert(blind.degraded, "an inert baseline must at least say so");
    assert(!blind.baselineSupplied && !blind.blindOnPurpose);

    // Hand in the branch point the event knows: red, by the exact −1/−1 the
    // deletion cost.
    environment[branchPointEnv] = before;
    auto armed = judge(sandbox);
    assert(!armed.degraded, "a supplied branch point is a real baseline");
    assert(armed.baselineSupplied);
    assert(!armed.ok, "a committed, undeclared loss must be RED once CI hands in a base");
    assert(armed.blocksSlack == -1 && armed.assertsSlack == -1, report(armed));

    // Declaring it closes the arithmetic here exactly as it does locally.
    mkdirRecurse(buildPath(sandbox, dirName(ledgerPath)));
    write(buildPath(sandbox, ledgerPath), "drop 1 1 0850 the block this control removed\n");
    auto declared = judge(sandbox);
    assert(declared.ok, report(declared));

    // A shallow clone is the other way the wiring rots: the revision is named
    // and simply is not there. That must be distinguishable from having no
    // baseline, because one is a broken configuration and the other is a fork.
    environment[branchPointEnv] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    auto missing = judge(sandbox);
    assert(missing.baselineSupplied && missing.baselineUnresolved,
           "a named-but-absent revision must be reported as such, not silently ignored");
    assert(missing.degraded, "and with nothing else to stand on, it is blind");

    // And the one accepted excuse, spelled out rather than inferred.
    environment[branchPointEnv] = "none";
    auto excused = judge(sandbox);
    assert(excused.blindOnPurpose && excused.degraded && !excused.baselineSupplied);
    environment.remove(branchPointEnv);

    // A shallow clone must be recognised as one. This is the case that made the
    // first rehearsal of this task pass when it should have failed: fetching the
    // branch point into a depth-1 checkout leaves `rev-parse` able to resolve it,
    // so the gate found a real tree to compare against and walked a lane that the
    // graft had already truncated.
    const shallowClone = buildPath(tempDir(), format("vibe3d-census-shallow-%d", thisProcessID));
    collectException(rmdirRecurse(shallowClone));
    scope(exit) collectException(rmdirRecurse(shallowClone));
    if (git(sandbox, ["clone", "-q", "--depth=1", "file://" ~ sandbox, shallowClone]).status == 0)
    {
        auto shallowVerdict = judge(shallowClone);
        assert(shallowVerdict.shallowClone,
               "a shallow checkout must be recognised as one — under CI it is refused");
    }
}

// ---------------------------------------------------------------------------
// The scanner's own tests
// ---------------------------------------------------------------------------

unittest
{
    // A block is the keyword followed by `{`, and nothing else is.
    assert(scanD("unittest { }").blocks == 1);
    assert(scanD("@safe unittest { }").blocks == 1);
    assert(scanD("unittest /* note */ { }").blocks == 1);
    assert(scanD("unittest\n// banner\n{ }").blocks == 1);
    assert(scanD("version (unittest) { }").blocks == 0);
    assert(scanD("debug (unittest) { }").blocks == 0);
    assert(scanD("version (unittest) private int x;").blocks == 0);
}

unittest
{
    // The inflation this session actually measured: the word inside a comment.
    assert(scanD("// a unittest block used to live here\n").blocks == 0);
    assert(scanD("/* unittest { } */").blocks == 0);
    assert(scanD("/+ unittest { } +/").blocks == 0);
    assert(scanD("/+ /+ unittest { } +/ +/").blocks == 0);
    assert(scanD(`enum s = "unittest { assert(1); }";`).blocks == 0);
    assert(scanD(`enum s = "unittest { assert(1); }";`).asserts == 0);
    assert(scanD("enum s = `unittest { assert(1); }`;").asserts == 0);
}

unittest
{
    // Assertions are counted as tokens, so line breaks inside one are
    // irrelevant — the other thing an earlier hand count got wrong.
    assert(scanD("unittest { assert(\n  1 == 1,\n  \"why\"); }").asserts == 1);
    assert(scanD("static assert(is(int == int));").asserts == 1);
    assert(scanD("assertThrown!Exception(f());").asserts == 1);
    assert(scanD("assertNotThrown(f());").asserts == 1);
    // ... and an identifier that merely begins with the word is not one.
    assert(scanD("int assertsRemaining = 3;").asserts == 0);
    assert(scanD("x.assertive = 1;").asserts == 0);
}

unittest
{
    // TASK 2007 FINDING #1 — A NAMED VERIFICATION HELPER'S CALL IS AN
    // ASSERTION. The predicate used to be three literals, so a helper carried
    // its `assert` once at the DEFINITION and deleting a CALL moved neither
    // counter. Measured on live data: six of seven `assertRevertShape(...)`
    // calls deleted from `face_reindex_arming_test.d` — the residual check for
    // six kernel families — and the census printed the same four numbers byte
    // for byte. Revert `isAssertName` to the enumeration and every assert below
    // reads 0.
    assert(scanD("assertRevertShape(m, pre, post);").asserts == 1,
        "a named verification helper's CALL must count as an assertion — "
      ~ "this is the whole of finding #1");
    assert(scanD("assertResidualLaw(d, plan);").asserts == 1);
    assert(scanD("assertNoUnaccountedTails(root, sites, rows);").asserts == 1);
    assert(scanD("assert_(x);").asserts == 1,
        "an underscore continuation is a helper too");
    // The helper sub-count is the diagnostic half, and it excludes bare
    // `assert` so a report can say which kind went missing.
    auto mix = scanD("assert(1); assertRevertShape(a, b); assertThrown(f());");
    assert(mix.asserts == 3, format("%s", mix));
    assert(mix.helperAsserts == 2,
        format("helperAsserts should exclude the bare `assert`: %s", mix));

    // THE FALSE-POSITIVE CONTROL. A lowercase continuation is a DIFFERENT WORD,
    // and the gate must not move when one of these is edited — widening the
    // rule to every identifier merely starting with `assert` would count the
    // scanner's own `assertsInBlocks` field.
    assert(scanD("int assertsInBlocks;").asserts == 0);
    assert(scanD("x.assertion = 1;").asserts == 0);
    assert(scanD("bool asserted = true;").asserts == 0);
    assert(scanD("void checkBounds() { }").asserts == 0,
        "`check…` is deliberately NOT in the rule — it names production logic "
      ~ "as often as it names a test helper");
}

unittest
{
    // TASK 2007 — THE HEREDOC DELIMITED STRING, `q"IDENT … IDENT"`. Found while
    // fixing finding #1 and it is a defect of the same family: `skipDelimited`
    // fell into its single-character arm with `close == 'P'` for `q"PROBE`,
    // never found `P"`, returned the end of the text and SWALLOWED THE REST OF
    // THE FILE. Eight files under the two scanned roots use the form — all
    // census tests, whose probes are exactly this shape — so everything after
    // the first probe in each was invisible to the gate that exists to notice
    // tests being destroyed. Measured on
    // `tests/unit/mesh_dirty_cliff_series_test.d`: 4 blocks / 11 asserts read
    // as 1 / 0; over the whole tree the recovered count was +47 blocks.
    const probe = "enum p = q\"PROBE\nunittest { assert(9); }\nPROBE\";\n"
                ~ "unittest { assert(1); assert(2); }\n";
    auto h = scanD(probe);
    assert(h.blocks == 1, format(
        "a `q\"IDENT … IDENT\"` heredoc swallowed the file: expected 1 block "
      ~ "after it, got %d", h.blocks));
    assert(h.asserts == 2, format(
        "expected the two asserts AFTER the heredoc and neither of the one "
      ~ "inside it, got %d", h.asserts));

    // The tag must match exactly — a mere prefix of it does not close.
    const tricky = "enum p = q\"PRO\nPROBE\nPRO\";\nunittest { assert(1); }\n";
    assert(scanD(tricky).blocks == 1, "the tag `PRO` closes at `PRO\"`");

    // Bracket delimiters NEST, which the single-depth loop got wrong.
    assert(scanD("enum d = q\"(a (b) c)\"; unittest { assert(1); }").blocks == 1,
        "a nested `(` inside q\"( )\" must not close the literal early");
    assert(scanD("enum d = q\"[a [b] c]\"; unittest { assert(1); }").blocks == 1);

    // …and the non-nesting single-character delimiter still works.
    assert(scanD("enum d = q\"/unittest { }/\"; unittest { assert(1); }").blocks == 1);
}

unittest
{
    // An import that NAMES an assertion helper is not an assertion. This is the
    // move-stability rule, measured on commit 8928893d: without it, a moved
    // block's new selective import reads as an added assertion.
    assert(scanD("import std.exception : assertThrown;").asserts == 0);
    assert(scanD("import std.exception : assertThrown, assertNotThrown;").asserts == 0);
    assert(scanD("import se = std.exception;\nunittest { assert(1); }").asserts == 1);
    assert(scanD("static import std.exception;\nassert(1);").asserts == 1);
    assert(scanD("void f() { import std.exception : assertThrown; assertThrown(g()); }").asserts == 1);
    // A string-import EXPRESSION is not a declaration and must not swallow the
    // rest of the statement.
    assert(scanD(`enum s = import("shader.glsl"); unittest { assert(1); }`).asserts == 1);
    assert(scanD(`enum s = import("shader.glsl"); unittest { assert(1); }`).blocks == 1);
}

unittest
{
    // Inside-the-block accounting, including a nested declaration.
    auto c = scanD("assert(0); unittest { assert(1); assert(2); } assert(3);");
    assert(c.blocks == 1);
    assert(c.asserts == 4);
    assert(c.assertsInBlocks == 2);

    auto nested = scanD("unittest { struct S { } assert(1); if (x) { assert(2); } }");
    assert(nested.blocks == 1);
    assert(nested.assertsInBlocks == 2);
}

unittest
{
    // Literal forms that would otherwise desynchronise the brace counter.
    assert(scanD("enum src = q{ void main() { assert(0); } };").asserts == 0);
    assert(scanD("enum src = q{ { { } } }; unittest { assert(1); }").blocks == 1);
    assert(scanD(`enum p = r"C:\raw\"; unittest { assert(1); }`).blocks == 1);
    assert(scanD(`enum h = x"DEADBEEF"; unittest { assert(1); }`).blocks == 1);
    assert(scanD(`enum d = q"(unittest { })"; unittest { assert(1); }`).blocks == 1);
    assert(scanD("char c = '{'; unittest { assert(1); }").blocks == 1);
    assert(scanD(`char q = '\''; unittest { assert(1); }`).blocks == 1);
    // A `q` or `r` that is an ordinary identifier is not a literal prefix.
    assert(scanD("if (q) { assert(1); } unittest { assert(2); }").blocks == 1);
}

unittest
{
    // A pure move is invisible to the census: the counts are sums over the
    // union of both roots, never per file.
    const donor    = "module a;\nunittest { assert(1); assert(2); }\nunittest { assert(3); }\n";
    const split    = ["module a;\n", "module a1;\nunittest { assert(1); assert(2); }\n",
                      "module a2;\nunittest { assert(3); }\n"];
    Census before = scanD(donor);
    Census after;
    foreach (part; split) after += scanD(part);
    assert(before.blocks  == after.blocks);
    assert(before.asserts == after.asserts);
}

unittest
{
    // Ledger parsing: what a declaration is, and what is rejected.
    auto d = parseLedger("# a comment\n\ndrop 1 9 0727 the unittest of the deleted path\n", "t");
    assert(d.blocks == 1 && d.asserts == 9);

    assert(parseLedger("", "t").blocks == 0);
    assert(parseLedger("# nothing but prose\n", "t").asserts == 0);

    auto twoLines = parseLedger("drop 1 9 0727 one\ndrop 2 3 0835 two\n", "t");
    assert(twoLines.blocks == 3 && twoLines.asserts == 12);

    bool threw = false;
    try parseLedger("we removed a test because reasons\n", "t"); catch (Exception) threw = true;
    assert(threw, "prose must not parse as a declaration");

    threw = false;
    try parseLedger("drop -1 -9 0727 negative\n", "t"); catch (Exception) threw = true;
    assert(threw, "the magnitude is declared, not a signed delta");

    threw = false;
    try parseLedger("drop 1 9\n", "t"); catch (Exception) threw = true;
    assert(threw, "a declaration without a task and a reason is not a declaration");
}

// ---------------------------------------------------------------------------
// Standalone counter
// ---------------------------------------------------------------------------

version (CensusTool)
void main(string[] args)
{
    import std.stdio : writeln, writefln;

    const root = args.length > 1 ? args[1] : ".";

    // `--rev <sha>` counts a historical tree through git, using the very code
    // path the gate uses for the branch point. That is what makes the
    // pure-move validation a test of the SHIPPED rule and not of a lookalike.
    string rev;
    bool   wantJudge;
    foreach (k; 2 .. args.length)
    {
        if (args[k] == "--rev" && k + 1 < args.length) rev = args[k + 1];
        if (args[k] == "--judge") wantJudge = true;
    }

    // `--judge` runs the gate's own verdict against a tree, which is how the
    // no-branch-point and shallow-clone paths get exercised somewhere other
    // than the repo this binary was built from.
    if (wantJudge)
    {
        auto v = judge(root);
        writefln("ran=%s degraded=%s supplied=%s unresolved=%s shallow=%s " ~
                 "blindOnPurpose=%s ok=%s baseRev=%s revs=%d blocksSlack=%d assertsSlack=%d",
                 v.ran, v.degraded, v.baselineSupplied, v.baselineUnresolved,
                 v.shallowClone, v.blindOnPurpose, v.ok, v.baseRev, v.revsWalked,
                 v.blocksSlack, v.assertsSlack);
        if (!v.ok) writeln(report(v));
        return;
    }

    auto files = rev.length ? scanRevision(root, rev) : scanWorkingTree(root);
    auto t     = total(files);

    if (args.length > 2 && args[2] == "--per-file")
        foreach (ref f; files)
            if (f.census.blocks || f.census.asserts)
                writefln("%6d %6d  %s", f.census.blocks, f.census.asserts, f.path);

    writefln("blocks=%d asserts=%d assertsInBlocks=%d files=%d",
             t.blocks, t.asserts, t.assertsInBlocks, files.length);
}
