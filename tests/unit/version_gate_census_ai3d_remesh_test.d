module tests.unit.version_gate_census_ai3d_remesh_test;

import tests.unit.census_symbols : isIdentChar;

import std.algorithm : sort, startsWith;
import std.file : exists, readText, remove, tempDir;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, splitLines;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool isGatedTarget(string moduleName)
{
    return moduleName.startsWith("ai3d.")
        || moduleName.startsWith("commands.ai3d.")
        || moduleName == "ai3d_command_registration"
        || moduleName.startsWith("remesh.")
        || moduleName == "commands.mesh.remesh"
        || moduleName == "ui.remesh_modal_state";
}

unittest
{
    foreach (moduleName; [
            "ai3d.job_controller", "commands.ai3d.import_result",
            "ai3d_command_registration", "remesh.remesh_job",
            "commands.mesh.remesh", "ui.remesh_modal_state",
        ])
        assert(isGatedTarget(moduleName), moduleName);
    foreach (moduleName; ["ai.model_adapter", "commands.mesh.bevel", "ui.panels"])
        assert(!isGatedTarget(moduleName), moduleName);
}

unittest
{
    const depsPath = buildPath(tempDir(),
        format("vibe3d-w15-d-web-deps-%d.txt", thisProcessID()));
    const describeErrorPath = buildPath(tempDir(),
        format("vibe3d-w15-d-web-describe-%d.txt", thisProcessID()));
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
dmd -deps="$3" -o- -c -version=web $flags $(find source -name '*.d' -print)
SH";
    const run = execute(["bash", "-c", compileWebGraph, "w15-d-web-deps",
                         repoRoot, describeErrorPath, depsPath],
                        null, Config.none, size_t.max, repoRoot);
    assert(run.status == 0,
        format("W15-D+D2 web dependency graph did not compile (status %d):\n%s",
               run.status, run.output));
    assert(exists(depsPath),
        "W15-D+D2 dmd -deps produced no dependency file");

    enum subjects = [
        "app", "editor_app", "http_providers", "mesh_command_registration",
        "registration", "ui.panels",
    ];
    enum fullyGatedModules = [
        "commands.mesh.remesh", "remesh.region_stitch",
        "remesh.remesh_job", "ui.remesh_modal_state",
    ];
    bool[string] subjectSet;
    foreach (subject; subjects) subjectSet[subject] = true;
    bool[string] fullyGatedSet;
    foreach (subject; fullyGatedModules) fullyGatedSet[subject] = true;

    bool[string] importersSeen;
    bool[string] leakSet;
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

        const importer = importerField[0 .. cast(size_t) importerEnd];
        const target = targetField[0 .. targetEnd];
        ++edgesScanned;
        if (importer in subjectSet)
        {
            importersSeen[importer] = true;
            if (isGatedTarget(target)) leakSet[importer] = true;
        }
        if (importer in fullyGatedSet && target != "object")
            leakSet[importer] = true;
    }

    string[] leaks;
    foreach (subject; subjects)
        if (subject in leakSet) leaks ~= subject;
    foreach (subject; fullyGatedModules)
        if (subject in leakSet) leaks ~= subject;
    leaks.sort;
    const gatedModulesSeen = importersSeen.length;

    assert(edgesScanned > 0,
        "W15-D+D2 parsed zero dmd -deps edges; an empty graph makes every closure clean");
    assert(gatedModulesSeen == 6,
        format("W15-D+D2 gated-module population changed: expected 6 composition modules, got %d",
               gatedModulesSeen));
    assert(leaks.length == 0,
        format("W15-D+D2 web graph still has direct ai3d/remesh edges: %s; "
             ~ "removing version (web) from one use in source/ui/panels.d "
             ~ "must report [\"ui.panels\"] here", leaks));

    const editorApp = readText(buildPath(repoRoot, "source", "editor_app.d"));
    assert(editorApp.indexOf("version (web) {\n    enum bool kGenerateAiAvailable = false;\n}") >= 0,
        "W15-D web builds must keep the AI generation action unavailable");
    assert(editorApp.indexOf("version (web) {\n} else {\nstruct Ai3dModalState") >= 0,
        "W15-D web builds must compile out the native AI modal state");
}
