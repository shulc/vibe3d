// The R5 import-direction witness. Operation families are discovered from the
// compile-time `Mesh`-member tripwire each converted family already owns; the
// base module and every family are identified by D module declaration, not by
// path. A family marked `mesh-ops-import: explicit` imports Mesh but must have
// no reverse import edge from the base module (task 4600).
module tests.unit.mesh_ops_import_boundary_test;

import std.file   : dirEntries, readText, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : endsWith, splitLines, startsWith, strip;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum explicitMarker = "// mesh-ops-import: explicit";

private struct ImportHit {
    string target;
    bool isPublic;
}

private struct Family {
    string moduleName;
    string path;
    string code;
    bool explicitImport;
}

private size_t countOccurrences(string haystack, string needle) {
    size_t n, i;
    if (needle.length == 0) return 0;
    while (i + needle.length <= haystack.length) {
        if (haystack[i .. i + needle.length] == needle) {
            ++n;
            i += needle.length;
        } else {
            ++i;
        }
    }
    return n;
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

/// Import declarations in this tree put the module name on their first line.
/// The scanner accepts indentation (including function-local imports), plus
/// `public` and `static`, and stops before a selective symbol list.
private ImportHit[] importsOf(string code) {
    ImportHit[] hits;
    foreach (line; code.splitLines) {
        string s = line.strip;
        bool isPublic;
        if (s.startsWith("public ")) {
            isPublic = true;
            s = s["public ".length .. $].strip;
        }
        if (s.startsWith("static "))
            s = s["static ".length .. $].strip;
        if (!s.startsWith("import ")) continue;
        s = s["import ".length .. $].strip;
        size_t n;
        while (n < s.length && ((s[n] >= 'a' && s[n] <= 'z')
                              || (s[n] >= 'A' && s[n] <= 'Z')
                              || (s[n] >= '0' && s[n] <= '9')
                              || s[n] == '_' || s[n] == '.')) ++n;
        if (n > 0) hits ~= ImportHit(s[0 .. n], isPublic);
    }
    return hits;
}

unittest // mesh operation families have explicit import boundaries
{
    // Scanner controls run before the tree assertions. A path rename changes
    // neither result: identity comes from `module`, and the import target is
    // parsed independently of selective names.
    immutable probe = blankNonCode(q"D
module mesh_ops.renamed_family;
public import mesh;
static import mesh_ops.helper : ignored;
D");
    assert(moduleNameOf(probe) == "mesh_ops.renamed_family",
        "module identity must come from the declaration, not the filename");
    const probeImports = importsOf(probe);
    assert(probeImports.length == 2,
        "the import scanner must see public and static/selective declarations");
    assert(probeImports[0] == ImportHit("mesh", true)
        && probeImports[1] == ImportHit("mesh_ops.helper", false),
        "the import scanner must preserve target identity and public visibility");

    Family[] families;
    string[][string] pathsByModule;
    string[] meshPaths;
    string meshCode;
    size_t filesScanned;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++filesScanned;
        immutable raw = readText(de.name);
        immutable code = blankNonCode(raw);
        immutable mod = moduleNameOf(code);
        if (mod.length > 0) pathsByModule[mod] ~= de.name;
        if (mod == "mesh") {
            meshPaths ~= de.name;
            meshCode = code;
        }
        if (mod.startsWith("mesh_ops.")
            && countOccurrences(code, "__traits(hasMember, Mesh") > 0)
            families ~= Family(mod, de.name, code, hasExplicitMarker(raw));
    }

    // POPULATION FLOORS precede every absence assertion they protect. The
    // first catches a dead tree walk; the next makes a deleted/renamed base
    // module loud; the last two stop an empty family or migrated-family set
    // from satisfying every `no edge` assertion below for free.
    assert(filesScanned >= 500,
        format("mesh import-boundary scan visited only %d source modules", filesScanned));
    assert(meshPaths.length == 1,
        format("expected exactly one D module named `mesh`; found %d at %s",
               meshPaths.length, meshPaths));
    assert(families.length == 13,
        format("expected 13 converted mesh operation families from their "
             ~ "`hasMember` tripwires; discovered %d", families.length));
    size_t explicitCount;
    foreach (ref f; families) if (f.explicitImport) ++explicitCount;
    assert(explicitCount == 1,
        format("R5 has migrated exactly one operation family in task 4600; "
             ~ "the tree-derived marker set contains %d", explicitCount));

    const meshImports = importsOf(meshCode);
    foreach (ref f; families) {
        assert(pathsByModule.get(f.moduleName, []).length == 1,
            format("operation module `%s` must have exactly one declaration; found %s",
                   f.moduleName, pathsByModule.get(f.moduleName, [])));

        size_t meshEdges, meshPublicEdges;
        foreach (hit; meshImports) if (hit.target == f.moduleName) {
            ++meshEdges;
            if (hit.isPublic) ++meshPublicEdges;
        }

        if (f.explicitImport) {
            size_t importsMesh;
            foreach (hit; importsOf(f.code)) if (hit.target == "mesh") ++importsMesh;
            assert(importsMesh == 1,
                format("explicit family `%s` must still import the base `mesh` "
                     ~ "module exactly once; found %d", f.moduleName, importsMesh));
            assert(meshEdges == 0,
                format("mesh imports explicit family `%s` through %d edge(s); "
                     ~ "task 4600 requires no base-module edge to that family",
                       f.moduleName, meshEdges));
        } else {
            assert(meshEdges == 1 && meshPublicEdges == 1,
                format("unmigrated family `%s` must retain exactly one public "
                     ~ "mesh import during the one-family-at-a-time R5 migration; "
                     ~ "found %d edge(s), %d public", f.moduleName,
                       meshEdges, meshPublicEdges));
        }
    }
}
