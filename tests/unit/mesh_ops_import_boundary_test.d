// The R5 import-direction witness. General pattern:
// doc/derived_census_pattern.md. The roster comes from every D module declared
// directly under source/mesh_ops, while module identity and public-import
// reachability come from declarations rather than paths. A module marked
// `mesh-ops-import: explicit` imports Mesh but must have no reverse import edge
// from the base module, including through a publicly imported sibling (tasks 4600-4602).
// Known blind spot: string mixins can re-export modules but remain invisible
// because `blankNonCode` intentionally blanks strings; the tree has 0 such
// `public import` uses as of 2026-09-07.
module tests.unit.mesh_ops_import_boundary_test;

import std.file   : dirEntries, readText, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : endsWith, indexOf, splitLines, startsWith, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum explicitMarker = "// mesh-ops-import: explicit";

private struct ImportHit {
    string target;
    bool isPublic;
}

private struct OperationModule {
    string moduleName;
    string path;
    string code;
    bool explicitImport;
}

private string moduleNameOf(string code) {
    foreach (line; code.splitLines) {
        const s = line.strip;
        if (s.startsWith("module ") && s.endsWith(";") && s.length > 8)
            return s["module ".length .. $ - 1].strip;
    }
    return "";
}

private bool hasExplicitMarker(string raw) {
    foreach (line; raw.splitLines)
        if (line.strip == explicitMarker) return true;
    return false;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private void skipSpace(string code, ref size_t pos, size_t end) {
    while (pos < end && (code[pos] == ' ' || code[pos] == '\t'
                      || code[pos] == '\r' || code[pos] == '\n')) ++pos;
}

private string qualifiedNameAt(string code, ref size_t pos, size_t end) {
    skipSpace(code, pos, end);
    const start = pos;
    while (pos < end && (isIdentChar(code[pos]) || code[pos] == '.')) ++pos;
    return code[start .. pos];
}

private bool containsWord(string code, string word) {
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

/// Scan whole import declarations through their semicolon. This deliberately
/// sees module aliases, comma-separated targets, line wraps, function-local
/// imports, and `static import`; a selective symbol list after `:` is not a
/// second module list.
private ImportHit[] importsOf(string code) {
    ImportHit[] hits;
    size_t searchAt;
    while (searchAt < code.length) {
        const rel = code[searchAt .. $].indexOf("import");
        if (rel < 0) break;
        const importAt = searchAt + cast(size_t) rel;
        searchAt = importAt + "import".length;
        if ((importAt > 0 && isIdentChar(code[importAt - 1]))
            || (searchAt < code.length && isIdentChar(code[searchAt]))) continue;

        size_t headAt = importAt;
        while (headAt > 0 && code[headAt - 1] != ';'
               && code[headAt - 1] != '{' && code[headAt - 1] != '}'
               && code[headAt - 1] != ':') --headAt;
        const isPublic = containsWord(code[headAt .. importAt], "public");

        const semicolonRel = code[searchAt .. $].indexOf(';');
        if (semicolonRel < 0) break;
        const end = searchAt + cast(size_t) semicolonRel;
        size_t pos = searchAt;
        while (pos < end) {
            skipSpace(code, pos, end);
            if (pos < end && code[pos] == ',') {
                ++pos;
                continue;
            }
            if (pos >= end || code[pos] == ':') break;

            string target = qualifiedNameAt(code, pos, end);
            if (target.length == 0) break;
            skipSpace(code, pos, end);
            if (pos < end && code[pos] == '=') {
                ++pos; // `ident =` aliases the module named after it.
                target = qualifiedNameAt(code, pos, end);
            }
            if (target.length > 0) hits ~= ImportHit(target, isPublic);
            skipSpace(code, pos, end);
            if (pos < end && code[pos] == ':') break;
            if (pos < end && code[pos] != ',') break;
        }
        searchAt = end + 1;
    }
    return hits;
}

private string[string] publicImportPaths(string root,
                                         const string[string] codeByModule) {
    string[string] paths;
    string[] queue = [root];
    paths[root] = root;
    size_t next;
    while (next < queue.length) {
        const current = queue[next++];
        auto src = current in codeByModule;
        if (src is null) continue;
        foreach (hit; importsOf(*src)) {
            if (!hit.isPublic || hit.target in paths) continue;
            paths[hit.target] = paths[current] ~ " -> " ~ hit.target;
            queue ~= hit.target;
        }
    }
    return paths;
}

unittest // mesh operation families have explicit import boundaries
{
    // Scanner controls run before the tree assertions. A path rename changes
    // neither result: identity comes from `module`, and the import target is
    // parsed independently of selective names.
    immutable probe = blankNonCode(q"D
module mesh_ops.renamed_family;
public import math, mesh_ops.comma_target;
public import
    mesh_ops.wrapped_target;
public import bf = mesh_ops.renamed_target;
void localImports() {
    import mesh_ops.local_target;
    static import mesh_ops.static_target : ignored;
}
D");
    assert(moduleNameOf(probe) == "mesh_ops.renamed_family",
        "module identity must come from the declaration, not the filename");
    const probeImports = importsOf(probe);
    assert(probeImports == [ImportHit("math", true),
                            ImportHit("mesh_ops.comma_target", true),
                            ImportHit("mesh_ops.wrapped_target", true),
                            ImportHit("mesh_ops.renamed_target", true),
                            ImportHit("mesh_ops.local_target", false),
                            ImportHit("mesh_ops.static_target", false)],
        "the import scanner must cover comma lists, line wraps, aliases, "
      ~ "function-local imports, static imports, and public visibility");

    const closureProbe = publicImportPaths("mesh", [
        "mesh": "public import mesh_ops.sibling;",
        "mesh_ops.sibling": "public import mesh_ops.explicit_family;",
        "mesh_ops.explicit_family": "import mesh;",
    ]);
    assert(closureProbe.get("mesh_ops.explicit_family", "")
            == "mesh -> mesh_ops.sibling -> mesh_ops.explicit_family",
        "public-import reachability must close transitively through a sibling");

    OperationModule[] operationModules;
    bool[string] operationNames;
    string[][string] pathsByModule;
    string[string] codeByModule;
    size_t filesScanned;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++filesScanned;
        immutable raw = readText(de.name);
        immutable code = blankNonCode(raw);
        immutable mod = moduleNameOf(code);
        if (mod.length > 0) {
            pathsByModule[mod] ~= de.name;
            if (mod !in codeByModule) codeByModule[mod] = code;
        }
    }
    foreach (de; dirEntries(buildPath(repoRoot, "source", "mesh_ops"),
                            "*.d", SpanMode.shallow)) {
        immutable raw = readText(de.name);
        immutable code = blankNonCode(raw);
        immutable mod = moduleNameOf(code);
        operationModules ~= OperationModule(mod, de.name, code,
                                             hasExplicitMarker(raw));
        operationNames[mod] = true;
    }

    // POPULATION FLOORS precede every absence assertion they protect. The
    // first catches a dead tree walk; the next makes a deleted/renamed base
    // module loud; the last two stop an empty family or migrated-family set
    // from satisfying every `no edge` assertion below for free.
    assert(filesScanned >= 500,
        format("mesh import-boundary scan visited only %d source modules", filesScanned));
    assert(pathsByModule.get("mesh", []).length == 1,
        format("expected exactly one D module named `mesh`; found %d at %s",
               pathsByModule.get("mesh", []).length,
               pathsByModule.get("mesh", [])));
    assert(operationModules.length == 16,
        format("expected 16 D modules declared under source/mesh_ops/*.d; "
             ~ "discovered %d", operationModules.length));
    size_t explicitCount;
    foreach (ref op; operationModules) {
        assert(op.moduleName.startsWith("mesh_ops."),
            format("operation source `%s` declares unexpected module `%s`",
                   op.path, op.moduleName));
        assert(pathsByModule.get(op.moduleName, []).length == 1,
            format("operation module `%s` must have exactly one declaration; found %s",
                   op.moduleName, pathsByModule.get(op.moduleName, [])));
        if (op.explicitImport) ++explicitCount;
    }
    assert(explicitCount == 14,
        format("R5 has fourteen explicit operation modules after tasks 4600-4602; "
             ~ "the tree-derived marker set contains %d", explicitCount));

    const meshImports = importsOf(codeByModule["mesh"]);
    const publicPaths = publicImportPaths("mesh", codeByModule);
    size_t publicOperationEdges;
    foreach (hit; meshImports) if (hit.isPublic && hit.target.startsWith("mesh_ops.")) {
        assert(hit.target in operationNames,
            format("mesh publicly imports `%s`, which is not declared by a direct "
                 ~ "source/mesh_ops/*.d module", hit.target));
        ++publicOperationEdges;
    }

    foreach (ref op; operationModules) {
        size_t meshEdges;
        foreach (hit; meshImports) if (hit.target == op.moduleName) {
            ++meshEdges;
        }
        if (op.explicitImport) {
            size_t importsMesh;
            foreach (hit; importsOf(op.code)) if (hit.target == "mesh") ++importsMesh;
            assert(importsMesh == 1,
                format("explicit family `%s` must still import the base `mesh` "
                     ~ "module exactly once; found %d", op.moduleName, importsMesh));
            assert(meshEdges == 0,
                format("mesh imports explicit family `%s` through %d edge(s); "
                     ~ "tasks 4600-4602 require no base-module edge to that family",
                       op.moduleName, meshEdges));
            assert(op.moduleName !in publicPaths,
                format("mesh publicly exposes explicit family `%s` through `%s`; "
                     ~ "tasks 4600-4602 require no public-import path to that family",
                       op.moduleName, publicPaths.get(op.moduleName, "")));
        }
    }

    assert(publicOperationEdges == 0,
        format("mesh declares %d direct public import edge(s) to modules under "
             ~ "source/mesh_ops/*.d; task 4602 requires exactly 0 after "
             ~ "the bridge family migration", publicOperationEdges));
}
