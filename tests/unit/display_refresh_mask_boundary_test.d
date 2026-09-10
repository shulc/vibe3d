// Source boundary for task 5280. Discover the production roles that define,
// import, or use the display-refresh mask and its one known epoch alias, then
// reconcile that tree-derived set with the reviewed role roster. Classification
// consumers must not import the display upload service.
//
// This is deliberately a lexical test-support scan, not a D parser. It handles
// ordinary semicolon-terminated imports (public/static/function-local, module
// aliases, comma-separated modules, selective bindings and binding aliases)
// and explicit `enum uint`/`alias` declarations of the two known names. It does
// name-based matching inside each import declaration, not semantic resolution;
// it does not expand string/template mixins or follow arbitrary renamed symbols
// across modules. Admitting such syntax requires extending these fixtures and
// the reviewed roster together.
module tests.unit.display_refresh_mask_boundary_test;

import std.algorithm : sort;
import std.array     : join;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.stdio     : stderr, writefln;
import std.string    : indexOf, replace, startsWith;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum uint definesPolicy = 1u << 0;
private enum uint importsPolicy = 1u << 1;
private enum uint usesPolicy    = 1u << 2;
private enum uint definesAlias  = 1u << 3;
private enum uint importsAlias  = 1u << 4;
private enum uint usesAlias     = 1u << 5;

private struct RoleRow {
    string path;
    uint roles;
}

private enum RoleRow[] kExpectedRoles = [
    RoleRow("source/mesh_dirty.d",
            importsPolicy | usesPolicy | definesAlias | usesAlias),
    RoleRow("source/mesh_edit_delta.d", definesPolicy | usesPolicy),
    RoleRow("source/render/render_mvp.d", importsAlias | usesAlias),
];

private struct ImportDecl {
    size_t start;
    size_t end;
    size_t moduleListEnd;
}

private struct RoleScan {
    uint roles;
    bool importsDisplaySync;
    size_t policyDefinitions;
    size_t aliasDefinitions;
}

private bool isIdentChar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private bool containsWord(string code, string word)
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

private void skipSpace(string code, ref size_t pos, size_t end)
{
    while (pos < end && (code[pos] == ' ' || code[pos] == '\t'
                      || code[pos] == '\r' || code[pos] == '\n')) ++pos;
}

private ImportDecl[] importDeclarations(string code)
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

private bool isInImport(size_t pos, const ImportDecl[] imports)
{
    foreach (decl; imports)
        if (pos >= decl.start && pos < decl.end) return true;
    return false;
}

private bool declarationEqualsAt(string code, size_t pos,
                                 bool policyDefinition)
{
    size_t after = pos + (policyDefinition
        ? "DisplayRefreshMask".length : "DisplayEpochMask".length);
    skipSpace(code, after, code.length);
    if (after >= code.length || code[after] != '=') return false;

    size_t start = pos;
    while (start > 0 && code[start - 1] != ';'
           && code[start - 1] != '{' && code[start - 1] != '}') --start;
    const prefix = code[start .. pos];
    if (policyDefinition)
        return containsWord(prefix, "enum") && containsWord(prefix, "uint");
    return containsWord(prefix, "enum") || containsWord(prefix, "alias");
}

private void classifyWord(string code, string word, const ImportDecl[] imports,
                          uint definitionRole, uint useRole,
                          bool policyDefinition, ref uint roles,
                          ref size_t definitions)
{
    size_t pos;
    while (pos < code.length) {
        const rel = code[pos .. $].indexOf(word);
        if (rel < 0) break;
        const at = pos + cast(size_t) rel;
        const before = at == 0 || !isIdentChar(code[at - 1]);
        const after = at + word.length == code.length
            || !isIdentChar(code[at + word.length]);
        if (before && after && !isInImport(at, imports)) {
            if (declarationEqualsAt(code, at, policyDefinition)) {
                roles |= definitionRole;
                ++definitions;
            } else {
                roles |= useRole;
            }
        }
        pos = at + word.length;
    }
}

private RoleScan scanDisplayRefreshRole(string source)
{
    const code = blankUnittestBodies(blankNonCode(source));
    const imports = importDeclarations(code);
    RoleScan result;

    foreach (decl; imports) {
        const text = code[decl.start .. decl.end];
        if (containsWord(text, "DisplayRefreshMask"))
            result.roles |= importsPolicy;
        if (containsWord(text, "DisplayEpochMask"))
            result.roles |= importsAlias;
        if (containsWord(code[decl.start .. decl.moduleListEnd], "display_sync"))
            result.importsDisplaySync = true;
    }

    classifyWord(code, "DisplayRefreshMask", imports,
                 definesPolicy, usesPolicy, true, result.roles,
                 result.policyDefinitions);
    classifyWord(code, "DisplayEpochMask", imports,
                 definesAlias, usesAlias, false, result.roles,
                 result.aliasDefinitions);
    return result;
}

private string roleNames(uint roles)
{
    string[] result;
    if (roles & definesPolicy) result ~= "defines-policy";
    if (roles & importsPolicy) result ~= "imports-policy";
    if (roles & usesPolicy)    result ~= "uses-policy";
    if (roles & definesAlias)  result ~= "defines-alias";
    if (roles & importsAlias)  result ~= "imports-alias";
    if (roles & usesAlias)     result ~= "uses-alias";
    return result.join("|");
}

unittest // the production scan and its fixtures use the same classifier
{
    const policy = scanDisplayRefreshRole(q{
        enum uint DisplayRefreshMask = 1;
        bool refreshes(uint flags) { return (flags & DisplayRefreshMask) != 0; }
    });
    assert(policy.roles == (definesPolicy | usesPolicy),
        "the scanner must distinguish the policy definition from its use");
    assert(policy.policyDefinitions == 1 && policy.aliasDefinitions == 0,
        "the scanner must count the policy definition independently of roles");

    const importForms = scanDisplayRefreshRole(q{
        public static import dirty = mesh_dirty :
            LocalEpoch = DisplayEpochMask;
        void localImport() {
            import delta = mesh_edit_delta : LocalMask = DisplayRefreshMask;
        }
    });
    assert(importForms.roles == (importsPolicy | importsAlias),
        "the import scanner must cover qualifiers, wrapping, module aliases, "
      ~ "function-local imports, and selective binding aliases");

    const aliases = scanDisplayRefreshRole(q{
        import mesh_edit_delta : DisplayRefreshMask;
        enum uint DisplayEpochMask = DisplayRefreshMask;
        enum watcher = DisplayEpochMask;
    });
    assert(aliases.roles == (importsPolicy | usesPolicy
                           | definesAlias | usesAlias),
        "the known epoch alias must be discovered at definition and use");
    assert(aliases.policyDefinitions == 0 && aliases.aliasDefinitions == 1,
        "the known epoch alias must have one counted definition");
    assert(scanDisplayRefreshRole(
        "alias DisplayEpochMask = DisplayRefreshMask;").roles
            == (definesAlias | usesPolicy),
        "the supported alias-declaration form must stay visible");

    const uploadBoundary = scanDisplayRefreshRole(q{
        module display_sync;
        import helper, sync = display_sync;
        // DisplayRefreshMask is only explanatory prose here.
        enum text = "DisplayEpochMask";
        unittest {
            import mesh_edit_delta : DisplayRefreshMask;
            enum hidden = DisplayRefreshMask;
        }
    });
    assert(uploadBoundary.roles == 0,
        "comments, strings, and unittest bodies must not create a role");
    assert(uploadBoundary.importsDisplaySync,
        "a display upload import remains visible independently of role discovery");

    const legalConsumer = scanDisplayRefreshRole(q{
        import mesh_edit_delta : DisplayRefreshMask;
        enum classification = DisplayRefreshMask;
    });
    assert(legalConsumer.roles == (importsPolicy | usesPolicy)
           && !legalConsumer.importsDisplaySync,
        "a classifier without the forbidden import is a legal role");

    const directViolation = scanDisplayRefreshRole(q{
        import mesh_edit_delta : DisplayRefreshMask;
        import display_sync : refreshDisplay;
        enum classification = DisplayRefreshMask;
    });
    const aliasViolation = scanDisplayRefreshRole(q{
        import mesh_dirty : DisplayEpochMask;
        import display_sync;
        enum classification = DisplayEpochMask;
    });
    assert(directViolation.roles == (importsPolicy | usesPolicy)
           && directViolation.importsDisplaySync,
        "a direct-mask classifier must expose the forbidden import");
    assert(aliasViolation.roles == (importsAlias | usesAlias)
           && aliasViolation.importsDisplaySync,
        "the known alias must not bypass the forbidden-import check");
}

unittest // the reviewed role roster is identical to production discovery
{
    RoleRow[] actual;
    string[] forbiddenImports;
    size_t sourceFiles;
    size_t renderSourceFiles;
    size_t policyDefinitions;
    size_t aliasDefinitions;

    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const relative = relativePath(de.name, repoRoot).replace("\\", "/");
        ++sourceFiles;
        if (relative.startsWith("source/render/")) ++renderSourceFiles;

        const scan = scanDisplayRefreshRole(readText(de.name));
        policyDefinitions += scan.policyDefinitions;
        aliasDefinitions += scan.aliasDefinitions;
        if (scan.roles != 0) {
            actual ~= RoleRow(relative, scan.roles);
            if (scan.importsDisplaySync) forbiddenImports ~= relative;
        }
    }
    actual.sort!((a, b) => a.path < b.path);

    assert(sourceFiles >= 500,
        format("display refresh boundary scanned only %d source files", sourceFiles));
    assert(renderSourceFiles >= 1,
        format("display refresh boundary scanned only %d render source files; "
             ~ "source/render must be inside the census", renderSourceFiles));
    assert(policyDefinitions == 1,
        format("DisplayRefreshMask has %d source definitions; expected exactly 1",
               policyDefinitions));
    assert(aliasDefinitions == 1,
        format("DisplayEpochMask has %d source definitions; expected exactly 1",
               aliasDefinitions));

    if (actual != kExpectedRoles) {
        stderr.writefln("display refresh role roster changed; actual roles follow:");
        foreach (row; actual)
            stderr.writefln("DISPLAY-REFRESH-ROLE-ACTUAL %s %s",
                            row.path, roleNames(row.roles));
        foreach (row; kExpectedRoles)
            stderr.writefln("DISPLAY-REFRESH-ROLE-EXPECTED %s %s",
                            row.path, roleNames(row.roles));
    }
    assert(actual == kExpectedRoles,
        "display refresh role roster changed; review the named actual/expected set");

    foreach (path; forbiddenImports)
        stderr.writefln("DISPLAY-REFRESH-FORBIDDEN %s imports display_sync", path);
    assert(forbiddenImports.length == 0,
        format("display refresh boundary found %d classifier(s) importing display_sync",
               forbiddenImports.length));
}
