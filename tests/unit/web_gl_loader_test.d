module tests.unit.web_gl_loader_test;

import tests.unit.census_symbols : blankNonCode, countOccurrences, isIdentChar,
    lineOf;

import bindbc.opengl;
import std.algorithm : canFind, sort;
import std.array : join;
import std.conv : to;
import std.file : exists, readText, remove, tempDir;
import std.format : format;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, splitLines;
import web_gl_loader : WebGlProcLookup, loadWebOpenGL,
    optionalDesktopGlSymbols, requiredWebGlSymbols, webClosureGlSymbols;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private __gshared const(char)* gMissingSymbol;

private extern(C) void* fakeLookup(const(char)* name) nothrow @nogc
{
    import core.stdc.string : strcmp;
    if (gMissingSymbol !is null && strcmp(name, gMissingSymbol) == 0)
        return null;
    return cast(void*) 1;
}

private void snapshotSlots(out void*[webClosureGlSymbols.length] saved)
{
    static foreach (i, name; webClosureGlSymbols)
        saved[i] = cast(void*) __traits(getMember, bindbc.opengl, name);
}

private void restoreSlots(ref void*[webClosureGlSymbols.length] saved)
{
    static foreach (i, name; webClosureGlSymbols)
    {
        {
            alias slot = __traits(getMember, bindbc.opengl, name);
            slot = cast(typeof(slot)) saved[i];
        }
    }
}

private void clearSlots()
{
    static foreach (name; webClosureGlSymbols)
    {
        {
            alias slot = __traits(getMember, bindbc.opengl, name);
            slot = null;
        }
    }
}

unittest
{
    void*[webClosureGlSymbols.length] saved;
    snapshotSlots(saved);
    scope (exit) restoreSlots(saved);

    clearSlots();
    gMissingSymbol = "glCreateShader".ptr;
    const missing = loadWebOpenGL(cast(WebGlProcLookup) &fakeLookup);
    assert(missing == "glCreateShader",
        format("W16-LD loader must name the first missing pointer; got `%s`",
               missing));
    assert(glCreateProgram !is null && glCreateShader is null,
        "W16-LD missing-pointer fixture did not cross the preceding real slot");

    clearSlots();
    gMissingSymbol = null;
    const unexpected = loadWebOpenGL(cast(WebGlProcLookup) &fakeLookup);
    assert(unexpected is null,
        format("W16-LD loader rejected a fully populated function set; "
             ~ "missing=%s", unexpected));
    static foreach (name; webClosureGlSymbols)
    {
        assert(cast(void*) __traits(getMember, bindbc.opengl, name) !is null,
            "W16-LD closure slot stayed null: " ~ name);
    }

    static foreach (name; ["glGetVertexAttribiv", "glGetVertexAttribPointerv",
                           "glVertexAttribDivisor", "glDrawArraysInstanced"])
    {
        {
            enum missingName = name ~ "\0";
            clearSlots();
            gMissingSymbol = missingName.ptr;
            const thickLineMissing = loadWebOpenGL(
                cast(WebGlProcLookup) &fakeLookup);
            assert(thickLineMissing == name,
                format("W16-B12 required GL slot was not rejected: expected "
                     ~ "%s, got %s", name, thickLineMissing));
        }
    }
}

private struct DependencyGraph
{
    string[][string] edges;
    string[string] sourcePath;
    bool[string] ours;
    size_t edgeCount;
}

private DependencyGraph readDependencyGraph(string path)
{
    DependencyGraph result;
    foreach (line; readText(path).splitLines)
    {
        const first = line.indexOf(" : ");
        if (first < 0) continue;
        const importerField = line[0 .. cast(size_t) first];
        const importerEnd = importerField.indexOf(" (");
        if (importerEnd < 0) continue;
        const tail = line[cast(size_t) first + 3 .. $];
        const secondRel = tail.indexOf(" : ");
        if (secondRel < 0) continue;
        const targetField = tail[cast(size_t) secondRel + 3 .. $];
        size_t targetEnd;
        while (targetEnd < targetField.length
                && (isIdentChar(targetField[targetEnd])
                    || targetField[targetEnd] == '.'))
            ++targetEnd;
        if (targetEnd == 0) continue;

        const importer = importerField[0 .. cast(size_t) importerEnd];
        const target = targetField[0 .. targetEnd];
        result.edges[importer] ~= target;
        const pathStart = cast(size_t) importerEnd + 2;
        if (importerField[$ - 1] == ')' && pathStart < importerField.length - 1)
        {
            const sourcePath = importerField[pathStart .. $ - 1];
            if (sourcePath.length >= 7 && sourcePath[0 .. 7] == "source/")
            {
                result.ours[importer] = true;
                result.sourcePath[importer] = sourcePath.idup;
            }
        }
        ++result.edgeCount;
    }
    return result;
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
        if (auto next = current in graph) queue ~= *next;
    }
    return false;
}

private string[] glCalls(string code)
{
    bool[string] found;
    for (size_t i; i + 3 < code.length; ++i)
    {
        if (code[i] != 'g' || code[i + 1] != 'l'
                || code[i + 2] < 'A' || code[i + 2] > 'Z'
                || (i > 0 && isIdentChar(code[i - 1])))
            continue;
        size_t end = i + 3;
        while (end < code.length && isIdentChar(code[end])) ++end;
        size_t open = end;
        while (open < code.length
                && (code[open] == ' ' || code[open] == '\t'
                    || code[open] == '\r' || code[open] == '\n'))
            ++open;
        if (open >= code.length || code[open] != '(') continue;
        const name = code[i .. end];
        // source/gl_thread_guard.d owns this non-OpenGL helper; every other
        // glXxx call in the imported modules must belong to the pinned roster.
        if (name != "glThreadGuard") found[name] = true;
        i = end - 1;
    }
    string[] result;
    foreach (name; found.byKey) result ~= name;
    result.sort;
    return result;
}

private string callSites(string raw, string symbol)
{
    const code = blankNonCode(raw);
    string[] lines;
    size_t from;
    const needle = symbol ~ "(";
    while (from < code.length)
    {
        const rel = code[from .. $].indexOf(needle);
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        lines ~= lineOf(code, at).to!string;
        from = at + needle.length;
    }
    return lines.join(",");
}

unittest
{
    auto manifest = parseJSON(readText(buildPath(repoRoot, "dub.json")));
    size_t webConfigurations;
    string sdlSubconfiguration;
    string[] wasmLflags;
    foreach (configuration; manifest["configurations"].array)
    {
        if (configuration["name"].str != "web") continue;
        ++webConfigurations;
        sdlSubconfiguration = configuration["subConfigurations"]
            ["bindbc-sdl"].str.idup;
        foreach (flag; configuration["lflags-wasm"].array)
            wasmLflags ~= flag.str.idup;
    }
    assert(webConfigurations == 1 && sdlSubconfiguration == "static",
        format("W16-LD web must select bindbc-sdl:static exactly once; "
             ~ "configs=%d selection=%s", webConfigurations,
               sdlSubconfiguration));
    foreach (flag; ["-sUSE_SDL=2", "-sMIN_WEBGL_VERSION=2",
                    "-sMAX_WEBGL_VERSION=2", "-sFULL_ES3"])
        assert(wasmLflags.canFind(flag),
            "W16-LD web linker flag missing: " ~ flag);

    const appRaw = readText(buildPath(repoRoot, "source", "app.d"));
    const appCode = blankNonCode(appRaw);
    assert(countOccurrences(appCode, "loadSDL(") == 3
            && countOccurrences(appCode, "loadOpenGL(") == 1,
        format("W16-LD loader-call floor changed: expected loadSDL=3 "
             ~ "loadOpenGL=1; sites SDL=[%s] GL=[%s]",
               callSites(appRaw, "loadSDL"), callSites(appRaw, "loadOpenGL")));

    enum sdlNativeBlock = q{    version (web) {
    } else version (OSX) {
        import std.string : toStringz;
        const sdlBundled = bundledSDL2Path();
        const sdlResult  = sdlBundled !is null ? loadSDL(sdlBundled.toStringz) : loadSDL();
        if (sdlResult != sdlSupport) { writeln("Failed to load SDL2"); return; }
    } else {
        if (loadSDL() != sdlSupport) { writeln("Failed to load SDL2"); return; }
    }
};
    enum glNativeBlock = q{    version (web) {
        if (auto missing = loadWebOpenGL()) {
            writefln("Failed to load WebGL2 / OpenGL ES 3 function: %s", missing);
            return;
        }
    } else {
        if (loadOpenGL() < glSupport) { writeln("Failed to load OpenGL 3.3"); return; }
    }
};
    assert(appRaw.canFind(sdlNativeBlock),
        format("W16-LD loadSDL calls escaped the native arm; sites=[%s]",
               callSites(appRaw, "loadSDL")));
    assert(appRaw.canFind(glNativeBlock),
        format("W16-LD loadOpenGL call escaped the native arm; sites=[%s]",
               callSites(appRaw, "loadOpenGL")));

    enum emscriptenContextBlock = q{    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    version (Emscripten) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    } else {
        // Native --config=web is the live loader witness until the later
        // shader slices replace desktop GLSL; keep that witness on Core 3.3.
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    }
};
    assert(appRaw.canFind(emscriptenContextBlock),
        "W16-LD Emscripten context must request OpenGL ES 3.0");

    assert(requiredWebGlSymbols.length == 83
            && optionalDesktopGlSymbols ==
               ["glGetBufferSubData", "glPointSize", "glTexBuffer"]
            && webClosureGlSymbols.length == 86,
        format("W16-LD GL threshold population changed: required=%d optional=%s "
             ~ "total=%d", requiredWebGlSymbols.length,
               optionalDesktopGlSymbols, webClosureGlSymbols.length));

    const depsPath = buildPath(tempDir(),
        format("vibe3d-w16-ld-web-deps-%d.txt", thisProcessID()));
    const errPath = buildPath(tempDir(),
        format("vibe3d-w16-ld-web-deps-%d.err", thisProcessID()));
    scope (exit)
    {
        if (exists(depsPath)) remove(depsPath);
        if (exists(errPath)) remove(errPath);
    }
    enum compileGraph = q"SH
set -o pipefail
cd "$1"
flags=$(dub describe --config=web \
  --data=import-paths,string-import-paths,versions,debug-versions 2>"$2")
dmd -deps="$3" -o- -c $flags $(find source -name '*.d' -print)
SH";
    const run = execute(["bash", "-c", compileGraph, "w16-ld-deps",
                         repoRoot, errPath, depsPath],
                        null, Config.none, size_t.max, repoRoot);
    assert(run.status == 0 && exists(depsPath),
        format("W16-LD web dependency graph failed (status %d):\n%s",
               run.status, run.output));
    auto graph = readDependencyGraph(depsPath);
    assert(graph.edgeCount > 0,
        "W16-LD parsed zero dependency edges; GL closure census is vacuous");

    string[] importers;
    string[] callers;
    bool[string] actualSymbols;
    foreach (moduleName; graph.ours.byKey)
    {
        if (moduleName == "web_gl_loader"
                || !reaches(graph.edges, "app", moduleName))
            continue;
        const code = blankNonCode(readText(buildPath(repoRoot,
            graph.sourcePath[moduleName])));
        if (code.indexOf("bindbc.opengl") < 0) continue;
        importers ~= moduleName;
        const calls = glCalls(code);
        if (calls.length > 0) callers ~= moduleName;
        foreach (name; calls) actualSymbols[name] = true;
    }
    importers.sort;
    callers.sort;
    string[] actual;
    foreach (name; actualSymbols.byKey) actual ~= name;
    actual.sort;
    auto expected = webClosureGlSymbols.dup;
    expected.sort;
    assert(importers.length == 20 && callers.length == 19
            && importers.canFind("editor_app")
            && !callers.canFind("editor_app"),
        format("W16-LD web GL consumer population changed: importers=%d %s; "
             ~ "callers=%d %s", importers.length, importers,
               callers.length, callers));
    assert(actual == expected,
        format("W16-LD web GL call roster drifted: expected %s, got %s",
               expected, actual));
}
