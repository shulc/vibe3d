// The `with (app)` census guard for `source/app.d` (task 0781, step 3).
//
// WHAT THE CONTRACT IS. `source/app.d` must contain no LIVE `with (app)`
// statement. Comments and string literals that spell the same three tokens are
// not violations — today the file carries ten of them and zero live ones.
//
// WHY THIS IS WORTH A GATE, and it is not a style rule. Step 3 of task 0781
// deletes sixteen same-name `@property ref` forwarders out of `main()` and
// rewrites every bare call site to `ifs.X`. The whole method rests on one
// claim: **the compiler is the census.** Delete a forwarder, and every use the
// rewrite missed becomes `undefined identifier` — so a name cannot be
// half-finished, and no separate audit of the 56 sites is needed.
//
// That claim is only true while no `with (app)` is open, because `EditorApp`
// declares members of the SAME NAMES as four of the deleted forwarders —
// `hoveredVertex` / `hoveredEdge` / `hoveredFace` and `buildToolVts`
// (`source/editor_app.d`). Inside a `with (app)` block a missed bare
// `hoveredVertex` would not fail to compile: it would SILENTLY REBIND to
// `app.hoveredVertex` and keep building. For the hover triple the two storages
// happen to alias today (`app.hoveredVertexPtr` points into the cluster), so
// even the tests would stay green while the source lost its stated binding;
// for `buildToolVts` a bare 2-argument call would route through the `EditorApp`
// delegate field instead of the cluster's own six-argument method. Either way
// the census stops being a census and becomes a hope.
//
// So this guard does not defend a preference. It defends the PRECONDITION of
// the technique that step 3 used, and it keeps defending it for whoever edits
// `app.d` next — the failure mode it prevents is invisible at the point of
// introduction and only shows up as a wrong binding much later.
//
// WHAT THE SCANNER SEES, EXACTLY. A `with` keyword at an identifier boundary,
// followed by a balanced parenthesised subject, in code that survives comment
// and literal removal. `/* */`, `/+ +/` (nested), `//`, `"..."`, `` `...` ``,
// `r"..."` and `'x'` are all blanked before the search, so a `with (app)` typed
// inside any of them is correctly NOT a hit. The subject text is reported
// verbatim so the failure message names what was opened.
//
// WHAT IT DOES NOT SEE, said plainly rather than left to be discovered: an
// alias for the same object (`with (*appPtr)`, `with (someOtherName)`) rebinds
// just as silently and this guard is blind to it; and the guard is scoped to
// `source/app.d` alone — `ui/panels.d`, `ui/viewport_render.d`,
// `http_providers.d` and `registration.d` legitimately open `with (app)` and
// are none of its business. The census argument only ever applied to the file
// the forwarders lived in.
//
// Section (d) at the bottom (task 4066) extends the same scanner to
// `registration.d` and `input_router.d` — not as a zero gate, which would be
// red by design, but as a CLOSED census of the blocks they open on purpose.
module tests.unit.app_with_app_scan_test;

import std.algorithm : canFind, count;
import std.array     : appender;
import std.ascii     : isAlphaNum;
import std.file      : exists, isFile, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : strip;

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

struct WithHit {
    size_t line;      /// 1-based line of the `with` keyword
    string subject;   /// the parenthesised expression, trimmed
}

private bool isIdentChar(char c) { return isAlphaNum(c) || c == '_'; }

/// Replace every comment and literal with spaces, preserving length and every
/// newline so that byte offsets and line numbers still address the original.
string blankNonCode(string src) {
    auto outBuf = new char[src.length];
    outBuf[] = ' ';
    size_t i = 0;
    while (i < src.length) {
        const char c = src[i];

        // Keep newlines wherever they fall, so line counting stays exact.
        void copyThrough(size_t from, size_t to) {
            foreach (k; from .. to)
                if (src[k] == '\n') outBuf[k] = '\n';
        }

        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
            size_t j = i;
            while (j < src.length && src[j] != '\n') j++;
            copyThrough(i, j);
            i = j;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
            size_t j = i + 2;
            while (j + 1 < src.length && !(src[j] == '*' && src[j + 1] == '/')) j++;
            j = (j + 1 < src.length) ? j + 2 : src.length;
            copyThrough(i, j);
            i = j;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '+') {
            size_t j = i + 2;
            int depth = 1;
            while (j + 1 < src.length && depth > 0) {
                if (src[j] == '/' && src[j + 1] == '+') { depth++; j += 2; }
                else if (src[j] == '+' && src[j + 1] == '/') { depth--; j += 2; }
                else j++;
            }
            copyThrough(i, j);
            i = j;
            continue;
        }
        // WYSIWYG string: r"..." or `...` — no escapes inside.
        if (c == '`' || (c == 'r' && i + 1 < src.length && src[i + 1] == '"'
                         && (i == 0 || !isIdentChar(src[i - 1])))) {
            const char term = (c == '`') ? '`' : '"';
            size_t j = (c == '`') ? i + 1 : i + 2;
            while (j < src.length && src[j] != term) j++;
            j = (j < src.length) ? j + 1 : src.length;
            copyThrough(i, j);
            i = j;
            continue;
        }
        if (c == '"' || c == '\'') {
            size_t j = i + 1;
            while (j < src.length && src[j] != c) {
                if (src[j] == '\\') j++;
                j++;
            }
            j = (j < src.length) ? j + 1 : src.length;
            copyThrough(i, j);
            i = j;
            continue;
        }
        outBuf[i] = c;
        i++;
    }
    return cast(string) outBuf;
}

/// Every live `with (subject)` in `src`, in source order.
WithHit[] scanLiveWith(string src) {
    const code = blankNonCode(src);
    auto hits = appender!(WithHit[]);
    size_t p = 0;
    while (p + 4 <= code.length) {
        if (code[p .. p + 4] == "with"
            && (p == 0 || !isIdentChar(code[p - 1]))
            && (p + 4 == code.length || !isIdentChar(code[p + 4]))) {
            size_t q = p + 4;
            while (q < code.length && (code[q] == ' ' || code[q] == '\t'
                                       || code[q] == '\n' || code[q] == '\r')) q++;
            if (q < code.length && code[q] == '(') {
                size_t r = q + 1;
                int depth = 1;
                while (r < code.length && depth > 0) {
                    if (code[r] == '(') depth++;
                    else if (code[r] == ')') depth--;
                    if (depth == 0) break;
                    r++;
                }
                if (depth == 0) {
                    size_t line = 1;
                    foreach (k; 0 .. p) if (code[k] == '\n') line++;
                    hits.put(WithHit(line, code[q + 1 .. r].strip.idup));
                    p = r + 1;
                    continue;
                }
            }
        }
        p++;
    }
    return hits.data;
}

// ---------------------------------------------------------------------------
// (a) The scanner discriminates — the positive control.
// ---------------------------------------------------------------------------

unittest { // a live `with (app)` IS found, and its subject is reported
    enum sample = q{
        void f() {
            with (app) {
                hoveredVertex = -1;
            }
        }
    };
    const hits = scanLiveWith(sample);
    assert(hits.length == 1,
        format("a live `with (app)` must be seen; the scanner found %d hits",
               hits.length));
    assert(hits[0].subject == "app",
        "the subject must be reported verbatim; got `" ~ hits[0].subject ~ "`");
}

unittest { // the subject is reported, not assumed — a different `with` is not `app`
    enum sample = q{ void f() { with (layout) { vpX = 0; } } };
    const hits = scanLiveWith(sample);
    assert(hits.length == 1, "a live `with (layout)` is still a `with`");
    assert(hits[0].subject == "layout",
        "the guard must distinguish subjects, not just count `with` keywords; "
      ~ "got `" ~ hits[0].subject ~ "`");
}

// ---------------------------------------------------------------------------
// (b) The scanner does not fire on the ten shapes app.d actually contains —
//     the negative control, and the reason the real-tree green means anything.
// ---------------------------------------------------------------------------

unittest { // `with (app)` inside a line comment is not a `with (app)`
    enum sample = "void f() {\n    // open `with (app) { ... }` so the moved text\n}\n";
    assert(scanLiveWith(sample).length == 0,
        "a line comment naming `with (app)` must not be a hit — ten such "
      ~ "comments live in app.d and the gate would be permanently red");
}

unittest { // block comments, nested block comments and string literals likewise
    enum sample = "void f() {\n"
                ~ "    /* with (app) */\n"
                ~ "    /+ with (app) /+ with (app) +/ +/\n"
                ~ "    string s = \"with (app)\";\n"
                ~ "    string t = `with (app)`;\n"
                ~ "    string u = r\"with (app)\";\n"
                ~ "}\n";
    assert(scanLiveWith(sample).length == 0,
        "comments and literals spelling `with (app)` must not be hits");
}

unittest { // and blanking preserves line numbers, so a hit is reportable
    enum sample = "// with (app)\n"
                ~ "/* two\n   lines */\n"
                ~ "with (app) { }\n";
    const hits = scanLiveWith(sample);
    assert(hits.length == 1, "one live hit after two dead ones");
    assert(hits[0].line == 4,
        format("the live `with (app)` is on line 4; the scanner said %d — "
             ~ "comment blanking dropped a newline", hits[0].line));
}

unittest { // `within`, `withdraw`: identifier boundaries are respected
    enum sample = q{ void f() { auto within = g(x); withdraw(app); } };
    assert(scanLiveWith(sample).length == 0,
        "an identifier merely starting with `with` is not a `with` statement");
}

// ---------------------------------------------------------------------------
// (c) THE GATE, over the real file, with an in-tree canary.
// ---------------------------------------------------------------------------

private enum gateRepoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    const p = buildPath(gateRepoRoot, "source/app.d");
    assert(exists(p) && isFile(p),
        "the guard cannot find " ~ p ~ " — it is measuring nothing, which is "
      ~ "worse than being absent");
    const src = readText(p);
    assert(src.length > 100_000,
        format("source/app.d read as only %d bytes — the guard is scanning the "
             ~ "wrong file", src.length));

    string[] live;
    foreach (h; scanLiveWith(src))
        if (h.subject == "app")
            live ~= format("app.d:%d", h.line);

    // THE CANARY, and it does not depend on app.d's comment text. Append one
    // live `with (app)` to the real file's contents and require the scanner to
    // find exactly ONE MORE than it found without it. This is what makes the
    // green below non-vacuous: the scanner is proven to fire on THIS file's
    // content, so a zero over the unmodified text is a measurement and not a
    // silent no-op. The check is DIFFERENTIAL on purpose — an absolute
    // `== 1` would fire first when the gate is genuinely violated and bury the
    // real failure under a "the scanner is broken" message that is not true.
    const canaried = src ~ "\nvoid _guardCanary() { with (app) { hoveredVertex = -1; } }\n";
    size_t canaryHits;
    foreach (h; scanLiveWith(canaried))
        if (h.subject == "app") canaryHits++;
    assert(canaryHits == live.length + 1,
        format("appending one live `with (app)` to app.d must raise the hit "
             ~ "count from %d to %d; the scanner saw %d — the scanner is "
             ~ "broken and the gate below cannot fail",
               live.length, live.length + 1, canaryHits));

    assert(live.length == 0,
        "source/app.d must contain no LIVE `with (app)`, and now does at "
      ~ format("%s", live) ~ ". This breaks the census argument task 0781 "
      ~ "step 3 relied on: `EditorApp` declares hoveredVertex/hoveredEdge/"
      ~ "hoveredFace/buildToolVts under the same names as the cluster, so "
      ~ "inside this block a bare use of one of those names REBINDS to the "
      ~ "EditorApp member instead of failing to compile. Write `ifs.X` or "
      ~ "`app.X` explicitly instead of opening the block.");
}

// ---------------------------------------------------------------------------
// (d) THE TWO FILES THAT OPEN `with (app)` ON PURPOSE — a closed census
//     (task 4066, row 9).
// ---------------------------------------------------------------------------
//
// `registration.d` wraps each registration family in `with (app) { … }` — the
// 315 factory lambdas inside read bare EditorApp names through it, and its
// header says so — and `input_router.d` opens it in three handlers, each with
// a comment on the `buildToolVts` rebinding hazard beside it. Those blocks are
// deliberate. What this row refuses is a FOURTH input_router block or a
// fifteenth registration one born without anyone deciding: the failure mode
// is the one described at the top of this file, a bare name that silently
// REBINDS to an `EditorApp` member of the same spelling, and it is invisible
// at the point of introduction. So the set is enumerated, not merely
// permitted — a block added or removed must change the number here, and the
// message names every live site so the reviewer can see which one moved.
//
// The count is the contract, not the line numbers: a family function that
// grows or a comment that lands above a block shifts every line and changes
// nothing about how many blocks exist.

private struct WithAppCensusRow { string file; size_t live; }

/// Measured 2026-09-04 with `scanLiveWith` over the committed files:
/// `grep -c 'with (app)'` reads 17 and 18 for the two files, but three of
/// registration.d's and fifteen of input_router.d's are comments and doc
/// lines — the scanner is what separates them, which is why the recorded
/// numbers are the scanner's and not grep's.
private static immutable WithAppCensusRow[] kWithAppCensus = [
    WithAppCensusRow("source/registration.d", 14),
    WithAppCensusRow("source/input_router.d",  3),
];

unittest {
    foreach (row; kWithAppCensus) {
        const p = buildPath(gateRepoRoot, row.file);
        assert(exists(p) && isFile(p),
            "the census cannot find " ~ p ~ " — it is measuring nothing");
        const src = readText(p);
        assert(src.length > 10_000,
            format("%s read as only %d bytes — the census is scanning the "
                 ~ "wrong file", row.file, src.length));

        string[] live;
        foreach (h; scanLiveWith(src))
            if (h.subject == "app")
                live ~= format("%s:%d", row.file, h.line);

        // The same differential canary as gate (c): appending one live block
        // must raise THIS file's count by exactly one, so the number below
        // is a measurement of this file's content and not a scanner no-op.
        const canaried = src ~ "\nvoid _guardCanary() { with (app) { hoveredVertex = -1; } }\n";
        size_t canaryHits;
        foreach (h; scanLiveWith(canaried))
            if (h.subject == "app") canaryHits++;
        assert(canaryHits == live.length + 1,
            format("appending one live `with (app)` to %s must raise the hit "
                 ~ "count from %d to %d; the scanner saw %d — the scanner is "
                 ~ "broken and the census below cannot fail",
                   row.file, live.length, live.length + 1, canaryHits));

        // POPULATION FLOOR. A row recording zero is the app.d gate in (c),
        // not a census; a file that opens no block has no business here.
        assert(row.live > 0,
            row.file ~ " is recorded with zero live blocks — that is gate (c)'s "
          ~ "contract, not a census row; delete the row or record the count");

        assert(live.length == row.live,
            format("%s opens %d live `with (app)` block(s); the census records "
                 ~ "%d. Live sites: %s. Inside such a block a bare "
                 ~ "hoveredVertex / hoveredEdge / hoveredFace / buildToolVts "
                 ~ "rebinds to the EditorApp member of that name without a "
                 ~ "compile error, so a new block is a decision: write "
                 ~ "`app.X` explicitly, or update the recorded count here and "
                 ~ "say why in the commit (task 4066, extending task 0781).",
                   row.file, live.length, row.live, live));
    }
}
