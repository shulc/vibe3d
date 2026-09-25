module tests.unit.thread_seam_census_gl_test;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    isIdentChar;

import std.algorithm : sort;
import std.file : SpanMode, dirEntries, exists, readText, remove, tempDir;
import std.format : format;
import std.path : baseName, buildPath, dirName, relativePath;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, replace, splitLines;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum sourceRoot = buildPath(repoRoot, "source");

private size_t identifierCount(string code, string needle)
{
    size_t count;
    size_t from;
    while (from + needle.length <= code.length)
    {
        const rel = code[from .. $].indexOf(needle);
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        const before = at == 0 || !isIdentChar(code[at - 1]);
        const afterAt = at + needle.length;
        const after = afterAt == code.length || !isIdentChar(code[afterAt]);
        if (before && after) ++count;
        from = afterAt;
    }
    return count;
}

private size_t callCount(string code, string needle)
{
    size_t count;
    size_t from;
    while (from + needle.length <= code.length)
    {
        const rel = code[from .. $].indexOf(needle);
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        const afterAt = at + needle.length;
        if ((at == 0 || !isIdentChar(code[at - 1]))
            && (afterAt == code.length || !isIdentChar(code[afterAt])))
        {
            size_t next = afterAt;
            while (next < code.length
                   && (code[next] == ' ' || code[next] == '\t'
                       || code[next] == '\r' || code[next] == '\n'))
                ++next;
            if (next < code.length && code[next] == '(') ++count;
        }
        from = afterAt;
    }
    return count;
}

private bool reaches(ref string[][string] graph, string root, string target)
{
    bool[string] seen;
    string[] queue = [root];
    size_t head;
    while (head < queue.length)
    {
        const current = queue[head++];
        if (current in seen) continue;
        seen[current] = true;
        if (current == target) return true;
        if (auto next = current in graph)
            queue ~= *next;
    }
    return false;
}

unittest
{
    const depsPath = buildPath(tempDir(),
        format("vibe3d-w15-a-web-deps-%d.txt", thisProcessID()));
    const describeErrorPath = buildPath(tempDir(),
        format("vibe3d-w15-a-web-describe-%d.txt", thisProcessID()));
    scope (exit)
    {
        if (exists(depsPath)) remove(depsPath);
        if (exists(describeErrorPath)) remove(describeErrorPath);
    }

    enum compileWebGraph = q"SH
set -o pipefail
cd "$1"
flags=$(dub describe --config=tests \
    --data=import-paths,string-import-paths,versions,debug-versions \
    2>"$2") || { cat "$2"; exit 1; }
python3 tools/ci/dmd_with_dub_flags.py "$flags" -deps="$3" -o- -c -version=web $(find source -name '*.d' -print)
SH";
    const run = execute(["bash", "-c", compileWebGraph, "w15-a-web-deps",
                         repoRoot, describeErrorPath, depsPath],
                        null, Config.none, size_t.max, repoRoot);
    assert(run.status == 0,
        format("W15-A web dependency graph did not compile (status %d):\n%s",
               run.status, run.output));
    assert(exists(depsPath),
        "W15-A dmd -deps produced no dependency file");

    string[][string] graph;
    size_t edgesScanned;
    foreach (line; readText(depsPath).splitLines)
    {
        const first = line.indexOf(" : ");
        if (first < 0) continue;
        const tail = line[cast(size_t) first + 3 .. $];
        const secondRel = tail.indexOf(" : ");
        if (secondRel < 0) continue;

        const importerField = line[0 .. cast(size_t) first];
        const importerEnd = importerField.indexOf(" (");
        if (importerEnd < 0) continue;
        const targetField = tail[cast(size_t) secondRel + 3 .. $];
        size_t targetEnd;
        while (targetEnd < targetField.length
               && (isIdentChar(targetField[targetEnd])
                   || targetField[targetEnd] == '.'))
            ++targetEnd;
        if (targetEnd == 0) continue;

        const importer = importerField[0 .. cast(size_t) importerEnd].idup;
        const target = targetField[0 .. targetEnd].idup;
        graph[importer] ~= target;
        ++edgesScanned;
    }

    string[] subjects;
    size_t filesScanned;
    size_t importModules;
    size_t glThreadGuardUses;
    size_t markMainThreadUses;
    size_t guardedCalls;
    foreach (entry; dirEntries(sourceRoot, "*.d", SpanMode.depth))
    {
        ++filesScanned;
        if (baseName(entry.name) == "gl_thread_guard.d") continue;
        const code = blankUnittestBodies(blankNonCode(readText(entry.name)));
        const importsHere = identifierCount(code, "gl_thread_guard");
        const glUsesHere = identifierCount(code, "glThreadGuard");
        const markUsesHere = identifierCount(code, "markMainThread");
        if (importsHere || glUsesHere || markUsesHere)
        {
            auto moduleName = relativePath(entry.name, sourceRoot)[0 .. $ - 2]
                .replace("/", ".");
            subjects ~= moduleName;
        }
        importModules += importsHere;
        glThreadGuardUses += glUsesHere;
        markMainThreadUses += markUsesHere;
        guardedCalls += callCount(code, "glThreadGuard")
                      + callCount(code, "markMainThread");
    }
    subjects.sort;

    assert(filesScanned > 0,
        "W15-A source census found zero D files");
    assert(edgesScanned > 0,
        "W15-A parsed zero dmd -deps edges; an empty graph makes every closure clean");
    assert(subjects.length == 6,
        format("W15-A gl_thread_guard subject population changed: expected 6 consuming modules, got %d (%s)",
               subjects.length, subjects));

    const carrier = blankNonCode(readText(
        buildPath(sourceRoot, "subpatch_worker.d")));
    assert(identifierCount(carrier, "core.thread") == 1,
        "W15-A positive control moved: source/subpatch_worker.d must carry core.thread once");
    assert(identifierCount(blankUnittestBodies(carrier), "core.thread") == 1,
        "W15-A unittest blanker erased the foreign module-level positive control");

    enum tokenInUnittest =
        "module m;\nunittest\n{\n    import core.thread : Thread;\n}\n";
    enum tokenAtModule =
        "module m;\nimport core.thread : Thread;\nunittest { }\n";
    enum nestedUnittest =
        "module m;\nunittest\n{\n    auto f = () { return 1; };\n}\n"
      ~ "import core.thread : Thread;\n";
    assert(identifierCount(
               blankUnittestBodies(blankNonCode(tokenInUnittest)),
               "core.thread") == 0,
        "W15-A predicate does not blank an in-module unittest witness");
    assert(identifierCount(
               blankUnittestBodies(blankNonCode(tokenAtModule)),
               "core.thread") == 1,
        "W15-A predicate blanks module code and would make the closure pin vacuous");
    assert(identifierCount(
               blankUnittestBodies(blankNonCode(nestedUnittest)),
               "core.thread") == 1,
        "W15-A predicate consumed code after a nested unittest block");

    const string[] expectedSubjects = [
        "app", "handles.gl_util", "image_cache", "shader",
        "subpatch_osd", "ui.image_rows",
    ];
    assert(subjects == expectedSubjects,
        format("W15-A gl_thread_guard consumers changed: expected %s, got %s",
               expectedSubjects, subjects));
    assert(importModules == 8,
        format("W15-A must gate all 8 gl_thread_guard import statements; found %d",
               importModules));
    assert(glThreadGuardUses == 14 && markMainThreadUses == 2,
        format("W15-A identifier needle changed: expected glThreadGuard=14 and markMainThread=2, got %d and %d",
               glThreadGuardUses, markMainThreadUses));
    assert(glThreadGuardUses + markMainThreadUses - importModules == 8,
        "W15-A expected 8 imported guard names after subtracting 8 module names");
    assert(guardedCalls == 8,
        format("W15-A must gate all 8 guard calls; found %d", guardedCalls));

    string[] leaks;
    foreach (subject; subjects)
    {
        if (reaches(graph, subject, "gl_thread_guard"))
        {
            leaks ~= "gl_thread_guard";
            break;
        }
    }
    assert(leaks.length == 0,
        format("W15-A web closure still reaches gl_thread_guard; removing version (web) from one of the six consuming modules must report leaks [\"gl_thread_guard\"]; got %s",
               leaks));
}
