// Task 6361: the overlay policy is a lower, import-free module. Every user
// imports it directly, editor_app cannot re-export or name it, and the
// viewport renderer cannot reach editor_app even through a transitive import.
module tests.unit.overlay_mode_import_census_test;

import std.algorithm : canFind, sort;
import std.array     : join, replace;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf, split, startsWith, strip;

import tests.unit.census_symbols : blankNonCode, containsWord,
    countOccurrences, ImportDecl, importDeclarations, reconcile, LedgerRow,
    statementsContaining, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum policyModule = "viewport_overlay_mode";

private struct Scan {
    bool definesMode, definesResolver;
    bool usesMode, usesResolver;          // outside import declarations
    bool importsPolicyModule;             // module list names policyModule
    bool publicImportOfPolicyModule;
    bool policyNamedInForeignImport;      // symbols name policy, module list does not
    bool importsEditorApp;
    string moduleName;
    string[] importedModules;
}

private bool inAny(size_t pos, const ImportDecl[] declarations) {
    foreach (decl; declarations)
        if (pos >= decl.start && pos < decl.end) return true;
    return false;
}

private string[] importTargets(string code, const ImportDecl[] declarations) {
    string[] result;
    foreach (decl; declarations) {
        auto list = code[decl.start + "import".length .. decl.moduleListEnd].strip;
        if (list.length && list[$ - 1] == ';') list = list[0 .. $ - 1].strip;
        foreach (binding; list.split(',')) {
            auto target = binding.strip;
            const equals = target.indexOf('=');
            if (equals >= 0) target = target[cast(size_t)equals + 1 .. $].strip;
            if (target.length) result ~= target;
        }
    }
    return result;
}

// Track D protection sections and blocks up to one import. This covers direct
// `public import`, `public: ... import`, and `public { ... import }` forms.
private bool importIsPublic(string code, size_t importAt) {
    import tests.unit.census_symbols : isIdentChar;

    bool[] publicScope = [false]; // module imports are private unless exposed
    string pendingProtection;
    size_t pos;
    while (pos < importAt) {
        if (isIdentChar(code[pos]) && !(code[pos] >= '0' && code[pos] <= '9')) {
            const start = pos++;
            while (pos < importAt && isIdentChar(code[pos])) ++pos;
            const word = code[start .. pos];
            if (word == "public" || word == "private" || word == "protected"
                || word == "package")
                pendingProtection = word;
            continue;
        }
        switch (code[pos]) {
            case ':':
                if (pendingProtection.length) {
                    publicScope[$ - 1] = pendingProtection == "public";
                    pendingProtection = null;
                }
                break;
            case '{':
                bool next = publicScope[$ - 1];
                if (pendingProtection.length)
                    next = pendingProtection == "public";
                publicScope ~= next;
                pendingProtection = null;
                break;
            case '}':
                if (publicScope.length > 1) publicScope.length--;
                pendingProtection = null;
                break;
            case ';':
                pendingProtection = null;
                break;
            default: break;
        }
        ++pos;
    }
    return pendingProtection == "public" || publicScope[$ - 1];
}

private Scan scan(string source) {
    import tests.unit.census_symbols : isIdentChar;

    const code = blankNonCode(source);
    const imports = importDeclarations(code);
    Scan result;
    result.importedModules = importTargets(code, imports);

    foreach (statement; statementsContaining(code, "module")) {
        if (statement.startsWith("module ") && statement.length > 8) {
            result.moduleName = statement["module ".length .. $ - 1].strip;
            break;
        }
    }
    foreach (decl; imports) {
        const list = code[decl.start .. decl.moduleListEnd];
        const whole = code[decl.start .. decl.end];
        if (containsWord(list, policyModule)) {
            result.importsPolicyModule = true;
            if (importIsPublic(code, decl.start))
                result.publicImportOfPolicyModule = true;
        } else if (containsWord(whole, "OverlayMode")
                   || containsWord(whole, "resolveOverlayMode")) {
            result.policyNamedInForeignImport = true;
        }
        if (containsWord(list, "editor_app")) result.importsEditorApp = true;
    }

    void words(string word, ref bool used) {
        size_t pos;
        while (pos + word.length <= code.length) {
            const rel = code[pos .. $].indexOf(word);
            if (rel < 0) break;
            const at = pos + cast(size_t)rel;
            pos = at + word.length;
            if ((at > 0 && isIdentChar(code[at - 1]))
                || (pos < code.length && isIdentChar(code[pos]))) continue;
            if (!inAny(at, imports)) used = true;
        }
    }
    words("OverlayMode", result.usesMode);
    words("resolveOverlayMode", result.usesResolver);
    foreach (statement; statementsContaining(code, "OverlayMode")) {
        if (statement.startsWith("enum OverlayMode")) result.definesMode = true;
        if (statement.startsWith("OverlayMode resolveOverlayMode(")
            && statement[$ - 1] == '{')
            result.definesResolver = true;
    }
    return result;
}

unittest // K0: scanner controls
{
    const probe = scan(q{
        module probe;
        // import editor_app : OverlayMode;  (comment)
        enum s = "import editor_app : OverlayMode;";
        import editor_app :
            EditorApp,
            OverlayMode;
        int lastOverlayMode;
    });
    assert(probe.moduleName == "probe");
    assert(probe.policyNamedInForeignImport && probe.importsEditorApp,
           "a wrapped selective import from editor_app must be seen");
    assert(!probe.usesMode && !probe.usesResolver,
           "comments, strings, imports and `lastOverlayMode` are not uses");

    const direct = scan(q{
        import viewport_overlay_mode : OverlayMode, resolveOverlayMode;
        void f() { auto m = resolveOverlayMode(0, 0, true); OverlayMode n = m; }
    });
    assert(direct.importsPolicyModule && direct.usesMode && direct.usesResolver
           && !direct.policyNamedInForeignImport);
    assert(scan(q{ public import viewport_overlay_mode; })
           .publicImportOfPolicyModule);
    assert(scan(q{ public: int intervening; import viewport_overlay_mode; })
           .publicImportOfPolicyModule,
           "a public protection section re-exports later imports");
    assert(scan(q{ public { int intervening; import viewport_overlay_mode; } })
           .publicImportOfPolicyModule,
           "a public protection block re-exports enclosed imports");
    assert(scan(q{ import ea = editor_app; }).importsEditorApp,
           "a module alias must retain its target module");
    // The K7b walk keys on `importedModules`, not on `importsEditorApp`, so the
    // alias branch needs its own witness: without it the BFS goes blind to
    // `import x = editor_app;` while every other cell here stays green (49 such
    // sites live in source/, e.g. app.d's).
    assert(scan(q{ import ea = editor_app; }).importedModules == ["editor_app"],
           "a module alias must reach the transitive walk by its target module");
}

unittest // K1-K9: whole-tree census
{
    string[] users, importers, foreign, publicImports, definers, resolverDefiners;
    string[] productionResolverUsers;
    Scan[string] productionModules;
    size_t sourceFiles, testFiles;
    Scan renderer, editorApp;
    size_t rendererSeen, editorAppSeen;
    foreach (root; ["source", "tests"]) {
        foreach (entry; dirEntries(buildPath(repoRoot, root), "*.d", SpanMode.depth)) {
            const rel = relativePath(entry.name, repoRoot).replace("\\", "/");
            if (root == "source") ++sourceFiles; else ++testFiles;
            const source = readText(entry.name);
            auto found = scan(source);
            if (found.definesMode) definers ~= rel;
            if (found.definesResolver) resolverDefiners ~= rel;
            if (found.moduleName == "ui.viewport_render") {
                renderer = found;
                ++rendererSeen;
            }
            if (found.moduleName == "editor_app") {
                editorApp = found;
                ++editorAppSeen;
            }
            if (root == "source" && found.moduleName.length) {
                assert(found.moduleName !in productionModules,
                       "duplicate source module " ~ found.moduleName);
                productionModules[found.moduleName] = found;
            }
            if (found.moduleName == policyModule) continue;
            if (found.usesMode || found.usesResolver) users ~= rel;
            if (found.importsPolicyModule) importers ~= rel;
            if (found.policyNamedInForeignImport) foreign ~= rel;
            if (found.publicImportOfPolicyModule) publicImports ~= rel;
            if (root == "source" && found.usesResolver)
                productionResolverUsers ~= rel;
        }
    }
    users.sort;
    importers.sort;
    foreign.sort;
    publicImports.sort;
    definers.sort;
    resolverDefiners.sort;
    productionResolverUsers.sort;

    // K1 population floors first.
    assert(sourceFiles >= 500 && testFiles >= 500,
           format("scanned %d source / %d test files", sourceFiles, testFiles));
    assert(rendererSeen == 1 && editorAppSeen == 1,
           format("renderer seen %d, editor_app seen %d", rendererSeen, editorAppSeen));
    assert(users.canFind("source/app.d")
           && users.canFind("source/ui/viewport_render.d"),
           format("named users missing: %s", users));

    // K2-K6: one definition, no re-export/foreign source, direct import identity.
    assert(definers == ["source/viewport_overlay_mode.d"],
           format("OverlayMode definitions: %s", definers));
    assert(resolverDefiners == ["source/viewport_overlay_mode.d"],
           format("resolveOverlayMode definitions: %s", resolverDefiners));
    assert(publicImports.length == 0, format("public re-export: %s", publicImports));
    assert(foreign.length == 0, format("policy imported from elsewhere: %s", foreign));
    assert(!editorApp.usesMode && !editorApp.usesResolver
           && !editorApp.importsPolicyModule,
           "editor_app still names the overlay policy");
    assert(users == importers, format("users %s\nimporters %s", users, importers));

    // K7: the renderer's direct dependency and the raw-literal blind spot.
    assert(!renderer.importsEditorApp,
           "ui.viewport_render still imports editor_app directly");
    assert(renderer.importsPolicyModule && renderer.usesMode,
           "ui.viewport_render does not import the policy directly");
    const rendererRaw = readText(buildPath(repoRoot, "source", "ui", "viewport_render.d"));
    assert(countOccurrences(rendererRaw, "editor_app") == 2,
           "ui.viewport_render raw editor_app count changed (expected two comments)");

    // K7b: breadth-first source import reachability, including local imports.
    enum rendererModule = "ui.viewport_render";
    string[] queue = [rendererModule];
    bool[string] reached = [rendererModule: true];
    string[string] parent;
    for (size_t head = 0; head < queue.length; ++head) {
        const current = queue[head];
        const node = current in productionModules;
        if (node is null) continue;
        foreach (next; node.importedModules) {
            if (!(next in productionModules) || next in reached) continue;
            reached[next] = true;
            parent[next] = current;
            queue ~= next;
        }
    }
    assert(queue.length >= 200,
           format("renderer import closure too small: %d modules", queue.length));
    if ("editor_app" in reached) {
        string[] chain;
        string current = "editor_app";
        while (true) {
            chain = [current] ~ chain;
            if (current == rendererModule) break;
            const previous = current in parent;
            if (previous is null) break;
            current = *previous;
        }
        assert(false, "ui.viewport_render reaches editor_app: "
               ~ chain.join(" -> "));
    }

    // K8: one production resolver call, in the owner-last loop.
    assert(productionResolverUsers == ["source/app.d"],
           format("production resolver users: %s", productionResolverUsers));
    const app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    const calls = statementsContaining(app, "resolveOverlayMode(");
    assert(calls.length == 1, format("resolver call statements: %s", calls));
    const ownerLastLoops = countOccurrences(app,
        "foreach (k; overlayDrawOrder(");
    assert(ownerLastLoops == 1,
           format("owner-last overlay loops: %d", ownerLastLoops));
    const hits = symbolTokenHits(app, "source/app.d", "resolveOverlayMode(");
    const findings = reconcile([
        LedgerRow("main.frame.overlayDrawOrder", 1,
            "the owner-last N-cell loop moved unchanged into frame (task 6970)")
    ], hits);
    assert(findings.length == 0, findings);

    // K9: the one result reaches both the stamp and renderer call.
    import std.regex : ctRegex, matchFirst;
    const match = calls[0].matchFirst(
        ctRegex!`^OverlayMode\s+(\w+)\s*=\s*resolveOverlayMode\(`);
    assert(!match.empty, "resolver result is not bound to a local: " ~ calls[0]);
    const variable = match[1];
    const stamps = statementsContaining(app,
        "lastOverlayMode = cast(int)" ~ variable ~ ";");
    assert(stamps.length == 1, format("stamp statements: %s", stamps));
    size_t drawSceneWithVariable;
    foreach (statement; statementsContaining(app, "drawScene(")) {
        import std.regex : regex;
        if (!statement.matchFirst(regex(`,\s*` ~ variable ~ `\s*\)\s*;$`)).empty)
            ++drawSceneWithVariable;
    }
    assert(drawSceneWithVariable == 1,
           "the resolved mode does not reach drawScene");
}
