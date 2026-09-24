// The native `-m32` target is x86, not WebAssembly. This test is deliberately only a
// WIDTH proxy: it asks the D frontend to compile the real web configuration with 32-bit
// size_t/pointers. Target-specific browser behavior belongs to the web toolchain lanes.
module tests.unit.web_width32_compile_test;

import std.algorithm : count, endsWith, startsWith;
import std.array : join;
import std.file : dirEntries, exists, mkdir, readText, remove, rmdirRecurse,
    SpanMode, tempDir, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, lastIndexOf, splitLines, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private struct DepNode
{
    string moduleName;
    string path;
}

private bool parseDepNode(string field, out DepNode node)
{
    field = field.strip;
    const open = field.indexOf(" (");
    if (open < 0) return false;
    const afterOpen = cast(size_t)open + 2;
    const closeRel = field[afterOpen .. $].indexOf(')');
    if (closeRel < 0) return false;
    node.moduleName = field[0 .. cast(size_t)open];
    node.path = field[afterOpen .. afterOpen + cast(size_t)closeRel];
    return node.moduleName.length != 0 && node.path.length != 0;
}

private string errorLines(string output)
{
    string[] errors;
    foreach (line; output.splitLines)
        if (line.indexOf("Error:") >= 0)
            errors ~= line;
    return errors.length == 0 ? "(no Error lines)" : errors.join("\n");
}

unittest
{
    const stem = format("vibe3d-w16-w-width32-%d", thisProcessID());
    const depsPath = buildPath(tempDir(), stem ~ ".deps");
    const manifestPath = buildPath(tempDir(), stem ~ ".files");
    const proxyPath = buildPath(tempDir(), stem ~ "-proxy.d");
    const objectDir = buildPath(tempDir(), stem ~ "-objects");
    const describeErrorPath = buildPath(tempDir(), stem ~ ".describe-errors");
    mkdir(objectDir);
    scope (exit)
    {
        if (exists(depsPath)) remove(depsPath);
        if (exists(manifestPath)) remove(manifestPath);
        if (exists(proxyPath)) remove(proxyPath);
        if (exists(describeErrorPath)) remove(describeErrorPath);
        rmdirRecurse(objectDir);
    }

    enum inventoryWebGraph = q"SH
set -euo pipefail
cd "$1"
flags=$(dub describe --config=web \
    --data=import-paths,string-import-paths,versions,debug-versions,dflags \
    2>"$2") || { cat "$2"; exit 1; }
case " $flags " in *" -version=web "*) ;; *)
  echo "FATAL: --config=web described no -version=web; the width proxy would compile the wrong build" >&2
  exit 2
esac
mapfile -t files < <(dub describe --config=web --data=source-files --data-list \
    2>>"$2" | sed '/^$/d' | grep '\.d$')
# Every file is explicit. This is required by the nine command modules whose declared
# names end in `_` while their paths do not; import lookup alone cannot resolve them.
dmd -deps="$3" -o- -c $flags "${files[@]}"
SH";
    const inventory = execute(["bash", "-c", inventoryWebGraph,
                               "w16-w-width32-inventory", repoRoot,
                               describeErrorPath, depsPath],
                              null, Config.none, size_t.max, repoRoot);
    assert(inventory.status == 0,
        format("W16-W native-width web dependency inventory failed (status %d):\n%s",
               inventory.status, inventory.output));
    string[][string] importsByModule;
    string[string] sourcePathByModule;
    const sourcePrefix = buildPath(repoRoot, "source") ~ "/";
    foreach (line; readText(depsPath).splitLines)
    {
        const first = line.indexOf(" : ");
        if (first < 0) continue;
        const tail = line[cast(size_t)first + 3 .. $];
        const secondRel = tail.indexOf(" : ");
        if (secondRel < 0) continue;

        DepNode importer, imported;
        if (!parseDepNode(line[0 .. cast(size_t)first], importer)) continue;
        if (!parseDepNode(tail[cast(size_t)secondRel + 3 .. $], imported)) continue;
        importsByModule[importer.moduleName] ~= imported.moduleName;
        foreach (node; [importer, imported])
            if (node.path.startsWith(sourcePrefix) && node.path.endsWith(".d"))
                sourcePathByModule[node.moduleName] = node.path;
    }
    bool[string] reached;
    string[] pending = ["app"];
    reached["app"] = true;
    while (pending.length != 0)
    {
        const current = pending[$ - 1];
        pending.length--;
        auto dependencies = current in importsByModule;
        if (dependencies !is null)
            foreach (dependency; *dependencies)
                if (dependency !in reached)
                {
                    reached[dependency] = true;
                    pending ~= dependency;
                }
    }

    string[] closurePaths;
    foreach (moduleName; reached.byKey)
    {
        auto path = moduleName in sourcePathByModule;
        if (path !is null)
        {
            closurePaths ~= *path;
        }
    }
    // Measured on the current W16 LD+B12 stack at
    // b777bc26e50e45da10f70889fed2d1ada5891237. This is the population floor:
    // successful dmd over fewer (or zero) files must not masquerade as a clean width pass.
    enum expectedWebModules = 529; // +1: workplane_fit; +1: io.assimp_wire
    assert(closurePaths.length == expectedWebModules,
        format("W16-W web closure population changed: expected %d source modules to reach "
             ~ "the 32-bit compiler, got %d", expectedWebModules, closurePaths.length));

    write(manifestPath, closurePaths.join("\n") ~ "\n");
    enum compileWidthProxy = q"SH
set -euo pipefail
cd "$1"
flags=$(dub describe --config=web \
    --data=import-paths,string-import-paths,versions,debug-versions,dflags \
    2>"$2") || { cat "$2"; exit 1; }
mapfile -t files < "$3"
dmd -v -m32 $6 -o- -c -od="$5" $flags "${files[@]}" "$4"
SH";

    size_t[string] rootsExpected;
    foreach (moduleName; reached.byKey)
        if ((moduleName in sourcePathByModule) !is null)
        {
            const dot = moduleName.lastIndexOf('.');
            const shortName = dot < 0
                ? moduleName : moduleName[cast(size_t) dot + 1 .. $];
            ++rootsExpected.require(shortName, 0);
        }
    ++rootsExpected.require("w16_w_width_proxy", 0);

    size_t modesRun;
    foreach (mode; ["production", "unittest"])
    {
        ++modesRun;
        const unittestFlag = mode == "unittest" ? "-unittest" : "";
        write(proxyPath,
            "module w16_w_width_proxy;\n"
          ~ "static assert(size_t.sizeof == 4, \"-m32 width proxy is missing\");\n"
          ~ "version (web) {} else static assert(false, \"-version=web is missing\");\n"
          ~ (mode == "production" ? "" :
             "version (unittest) {} else static assert(false, \"-unittest is missing\");\n"));
        const compiled = execute(["bash", "-c", compileWidthProxy,
                                  "w16-w-width32-compile", repoRoot,
                                  describeErrorPath, manifestPath, proxyPath, objectDir,
                                  unittestFlag],
                                 null, Config.none, size_t.max, repoRoot);
        assert(compiled.status == 0,
            format("W16-W dmd -m32 x86 WIDTH proxy rejected the %d-module web closure "
                 ~ "in %s mode (status %d):\n%s", expectedWebModules, mode,
                   compiled.status, errorLines(compiled.output)));

        // `semantic3 <identifier>` is emitted once for every root source named on
        // dmd's command line. Compare its short-name multiset with the closure so a
        // truncated command cannot satisfy the independently measured graph floor.
        size_t[string] rootsSeen;
        size_t rootLines;
        foreach (line; compiled.output.splitLines)
            if (line.startsWith("semantic3 "))
            {
                ++rootLines;
                ++rootsSeen.require(line["semantic3 ".length .. $].strip, 0);
            }
        assert(rootLines == expectedWebModules + 1 && rootsSeen == rootsExpected,
            format("W16-W %s dmd analysed %d root modules; the %d-module closure "
                 ~ "plus the probe must each reach semantic3",
                   mode, rootLines, expectedWebModules));

        size_t objectFiles;
        foreach (_; dirEntries(objectDir, SpanMode.shallow)) ++objectFiles;
        assert(objectFiles == 0,
            format("W16-W %s width proxy must keep dmd -o- (no codegen), but it "
                 ~ "wrote %d object files", mode, objectFiles));
    }
    assert(modesRun == 2, "both production and unittest width probes must run");

    // The native runtime cell documents the long-domain contract, while this
    // wiring pin makes an inline cast-before-check regression visible on x86_64.
    const nativeSource = readText(buildPath(repoRoot, "source", "io", "native.d"));
    assert(nativeSource.count(
            "if (!morphVertexIndexInBounds(vidx, mesh.vertices.length))") == 1,
        "W16-W morph indices must be range-checked as long before size_t narrowing");
}
