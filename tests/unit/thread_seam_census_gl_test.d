module tests.unit.thread_seam_census_gl_test;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    isIdentChar;

import std.algorithm : sort;
import std.file : SpanMode, remove, tempDir;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, exists = wave15Exists, readText = wave15ReadText;
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
python3 tools/ci/dmd_with_dub_flags.py "$flags" -deps="$3" -o- -c -version=web $(find apps/desktop/source packages/common/source libraries/mesh/ops/source libraries/documents/interchange/source libraries/editing/selection/query/source libraries/editing/pipeline/evaluation/source libraries/editing/tools/state/source libraries/editing/tools/transform/source libraries/editing/tools/creation/source libraries/editing/tools/alignment/source libraries/platform/input/source libraries/viewport/display-policy/source libraries/viewport/gpu/source libraries/viewport/subpatch/source libraries/editing/contracts/source libraries/mesh/change/source libraries/mesh/contracts/source libraries/mesh/edit-log/source libraries/mesh/edit-replay/source libraries/mesh/snapshot/source libraries/mesh/topology/source libraries/mesh/core/source libraries/util/profiling/source libraries/util/spatial/source libraries/util/log/source libraries/util/math/source libraries/util/parallel/source libraries/util/plane-bytes/source libraries/util/screen-buckets/source -name '*.d' ! -path 'libraries/util/math/source/vibe3d/util/math/package.d' ! -path 'libraries/mesh/core/source/vibe3d/mesh/core/package.d' ! -path 'libraries/documents/model/source/vibe3d/documents/model/package.d' -print)
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
    foreach (scanSourceRoot; [sourceRoot, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
    {
        ++filesScanned;
        if (baseName(entry.name) == "gl_thread_guard.d") continue;
        const code = blankUnittestBodies(blankNonCode(readText(entry.name)));
        const importsHere = identifierCount(code, "gl_thread_guard");
        const glUsesHere = identifierCount(code, "glThreadGuard");
        const markUsesHere = identifierCount(code, "markMainThread");
        if (importsHere || glUsesHere || markUsesHere)
        {
            auto moduleName = relativePath(entry.name, scanSourceRoot)[0 .. $ - 2]
                .replace("/", ".");
            subjects ~= moduleName;
        }
        importModules += importsHere;
        glThreadGuardUses += glUsesHere;
        markMainThreadUses += markUsesHere;
        guardedCalls += callCount(code, "glThreadGuard")
                      + callCount(code, "markMainThread");
    }
    foreach (sourceCarrier; [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
    ]) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        const sourceRelative = sourceCarrier ==
            "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d"
                ? "view.d"
                : sourceCarrier ==
                    "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d"
                        ? "io/image_decode.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d" ? "command_history.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d" ? "command.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d" ? "commands/mesh/session_edit.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d" ? "commands/select/element.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d" ? "record_observer_hub.d" : "io/native.d";

        if (baseName(sourceCarrierPath) == "gl_thread_guard.d") continue;
        const code = blankUnittestBodies(blankNonCode(readText(sourceCarrierPath)));
        const importsHere = identifierCount(code, "gl_thread_guard");
        const glUsesHere = identifierCount(code, "glThreadGuard");
        const markUsesHere = identifierCount(code, "markMainThread");
        if (importsHere || glUsesHere || markUsesHere)
        {
            auto moduleName = sourceRelative[0 .. $ - 2]
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
    assert(subjects.length == 7,
        format("W15-A gl_thread_guard subject population changed: expected 7 consuming modules, got %d (%s)",
               subjects.length, subjects));

    const carrier = blankNonCode(readText(
        buildPath(repoRoot, "packages/subpatch-preview/source", "subpatch_worker.d")));
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
        "subpatch_osd", "ui.image_rows", "viewport_env",
    ];
    assert(subjects == expectedSubjects,
        format("W15-A gl_thread_guard consumers changed: expected %s, got %s",
               expectedSubjects, subjects));
    assert(importModules == 9,
        format("W15-A must gate all 9 gl_thread_guard import statements; found %d",
               importModules));
    assert(glThreadGuardUses == 16 && markMainThreadUses == 2,
        format("W15-A identifier needle changed: expected glThreadGuard=16 and markMainThread=2, got %d and %d",
               glThreadGuardUses, markMainThreadUses));
    assert(glThreadGuardUses + markMainThreadUses - importModules == 9,
        "W15-A expected 9 imported guard names after subtracting 9 module names");
    assert(guardedCalls == 9,
        format("W15-A must gate all 9 guard calls; found %d", guardedCalls));

    const graphSubjectModules = [
        "app": "vibe3d.apps.desktop.app",
        "handles.gl_util": "vibe3d.editing.tools.interactive.handles.gl_util",
        "image_cache": "vibe3d.viewport.host.image_cache",
        "shader": "vibe3d.viewport.gpu.shader",
        "subpatch_osd": "vibe3d.viewport.subpatch.subpatch_osd",
        "ui.image_rows": "vibe3d.ui.editor.ui.image_rows",
        "viewport_env": "vibe3d.viewport.gpu.viewport_env",
    ];

    string[] leaks;
    foreach (subject; subjects)
    {
        if (reaches(graph, graphSubjectModules[subject], "vibe3d.viewport.gpu.gl_thread_guard"))
        {
            leaks ~= "gl_thread_guard";
            break;
        }
    }
    assert(leaks.length == 0,
        format("W15-A web closure still reaches gl_thread_guard; removing version (web) from one of the seven consuming modules must report leaks [\"gl_thread_guard\"]; got %s",
               leaks));
}
