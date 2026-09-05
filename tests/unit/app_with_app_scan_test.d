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

import std.array     : appender;
import std.ascii     : isAlphaNum;
import std.file      : dirEntries, exists, isFile, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf, strip;

import tests.unit.census_symbols : LedgerHit, LedgerRow,
    sharedBlankNonCode = blankNonCode, enclosingSymbols, reconcile, symbolAt;

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
alias blankNonCode = sharedBlankNonCode;

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

/// Measured 2026-09-04 with `scanLiveWith` over the committed files:
/// `grep -c 'with (app)'` reads 17 and 18 for the two files, but three of
/// registration.d's and fifteen of input_router.d's are comments and doc
/// lines — the scanner is what separates them, which is why the recorded
/// numbers are the scanner's and not grep's.
private static immutable LedgerRow[] kWithAppCensus = [
    LedgerRow("registerTransformTools", 1, "transform registrations"),
    LedgerRow("registerGeneratorTools", 1, "generator registrations"),
    LedgerRow("registerPrimitiveTools", 1, "primitive registrations"),
    LedgerRow("registerEditTools", 1, "edit-tool registrations"),
    LedgerRow("registerCommands", 1, "top-level command registrations"),
    LedgerRow("registerToolLifecycleCommands", 1, "tool lifecycle commands"),
    LedgerRow("registerItemCommands", 1, "item commands"),
    LedgerRow("registerPipeStageCommands", 1, "pipe-stage commands"),
    LedgerRow("registerSelectionCommands", 1, "selection commands"),
    LedgerRow("registerViewCommands", 1, "view commands"),
    LedgerRow("registerFileCommands", 1, "file commands"),
    LedgerRow("registerMeshCommands", 1, "mesh commands"),
    LedgerRow("registerHistoryCommands", 1, "history commands"),
    LedgerRow("registerSelfTestCommands", 1, "self-test commands"),
    LedgerRow("InputRouter.handleWindowEvent", 1, "window-event handler"),
    LedgerRow("InputRouter.handleMouseWheel", 1, "mouse-wheel handler"),
    LedgerRow("InputRouter.handleKeyDown", 1, "key-down handler"),
];

private string moduleNameOf(string code) {
    auto at = code.indexOf("module ");
    if (at < 0) return null;
    immutable start = cast(size_t) at + "module ".length;
    auto semi = code.indexOf(';', start);
    return semi < 0 ? null : code[start .. cast(size_t) semi].strip;
}

unittest {
    LedgerHit[] ledgerHits;
    size_t filesScanned;
    size_t scopeModulesScanned;
    const sourceDir = buildPath(gateRepoRoot, "source");
    foreach (de; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
        filesScanned++;
        const rel = relativePath(de.name, gateRepoRoot);
        const src = readText(de.name);
        const code = blankNonCode(src);
        const symbols = enclosingSymbols(code);
        const moduleName = moduleNameOf(code);
        const inOriginalScope = moduleName == "registration"
                             || moduleName == "input_router";
        if (inOriginalScope) scopeModulesScanned++;

        const live = scanLiveWith(src);
        foreach (h; live) {
            if (h.subject != "app") continue;
            const symbol = symbolAt(symbols, h.line - 1);
            bool recorded;
            foreach (row; kWithAppCensus)
                if (row.key == symbol) { recorded = true; break; }
            if (recorded || inOriginalScope)
                ledgerHits ~= LedgerHit(symbol, rel, h.line, "with (app)");
        }

        // Keep the original differential canary on both scoped modules, but
        // discover them by their D module declaration instead of their path.
        if (inOriginalScope) {
            const canaried = src
                ~ "\nvoid _guardCanary() { with (app) { hoveredVertex = -1; } }\n";
            size_t liveApp, canaryApp;
            foreach (h; live) if (h.subject == "app") liveApp++;
            foreach (h; scanLiveWith(canaried))
                if (h.subject == "app") canaryApp++;
            assert(canaryApp == liveApp + 1,
                format("appending one live `with (app)` to module %s must "
                     ~ "raise the hit count from %d to %d; the scanner saw %d",
                       moduleName, liveApp, liveApp + 1, canaryApp));
        }
    }

    string problems = reconcile(kWithAppCensus, ledgerHits);
    if (ledgerHits.length != 17)
        problems ~= format("\n    with(app) population — recorded 17, scanner "
                         ~ "found %d", ledgerHits.length);
    if (filesScanned < 400)
        problems ~= format("\n    source population — scanned only %d file(s)",
                           filesScanned);
    if (scopeModulesScanned != 2)
        problems ~= format("\n    module population — recorded 2 scoped "
                         ~ "modules, scanner found %d", scopeModulesScanned);
    assert(problems.length == 0,
        "the declaration-keyed `with (app)` census changed. Inside such a "
      ~ "block a bare hoveredVertex / hoveredEdge / hoveredFace / buildToolVts "
      ~ "rebinds to the EditorApp member of that name without a compile error, "
      ~ "so a new block is a decision: write `app.X` explicitly, or update the "
      ~ "recorded declaration and say why in the commit (task 4066, extended "
      ~ "by task 4170)." ~ problems);
}
