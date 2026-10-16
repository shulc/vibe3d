module tests.unit.web_gl_loader_test;

import tests.unit.census_symbols : blankNonCode, countOccurrences, isIdentChar,
    lineOf, wave15LogicalPath;

import bindbc.opengl;
import std.algorithm : canFind, sort, startsWith;
import std.array : join;
import std.conv : to;
import std.file : remove, tempDir;
import tests.unit.census_symbols : exists = wave15Exists, readText = wave15ReadText;
import std.format : format;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, splitLines;
import vibe3d.apps.desktop.web_gl_loader : WebGlProcLookup, loadWebOpenGL,
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
            const logicalPath = wave15LogicalPath(buildPath(repoRoot, sourcePath));
            const originalPath = logicalPath.startsWith(repoRoot ~ "/")
                ? logicalPath[repoRoot.length + 1 .. $] : sourcePath;
            if (originalPath.startsWith("source/", "packages/common/source/", "packages/mesh-ops/source/", "packages/interchange/source/", "packages/interaction-query/source/", "packages/pipe-evaluation/source/", "packages/tool-state/source/", "packages/transform-ops/source/", "packages/creation-ops/source/", "packages/alignment-ops/source/", "packages/input-events/source/", "packages/display-policy/source/", "packages/viewport-gpu/source/", "packages/subpatch-preview/source/", "packages/edit-contracts/source/", "packages/mesh-change/source/", "packages/mesh-contracts/source/", "packages/mesh-edit-log/source/", "packages/mesh-edit-replay/source/", "packages/mesh-snapshot/source/", "packages/mesh-topology/source/", "packages/mesh/source/", "packages/profiling/source/", "packages/spatial/source/", "util/log/source/", "util/math/source/", "util/parallel/source/", "util/plane-bytes/source/", "util/screen-buckets/source/"))
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
    string[] wasmDflags;
    string[] wasmLflags;
    foreach (configuration; manifest["configurations"].array)
    {
        if (configuration["name"].str != "web") continue;
        ++webConfigurations;
        sdlSubconfiguration = configuration["subConfigurations"]
            ["bindbc-sdl"].str.idup;
        foreach (flag; configuration["dflags-wasm"].array)
            wasmDflags ~= flag.str.idup;
        foreach (flag; configuration["lflags-wasm"].array)
            wasmLflags ~= flag.str.idup;
    }
    assert(webConfigurations == 1 && sdlSubconfiguration == "static",
        format("W16-LD web must select bindbc-sdl:static exactly once; "
             ~ "configs=%d selection=%s", webConfigurations,
               sdlSubconfiguration));
    const expectedDflags = [
        "-gcc=$PACKAGE_DIR/tools/emcc_web_driver.sh",
        "-defaultlib=phobos2-ldc,druntime-ldc",
        "-Xcc=-sDEFAULT_TO_CXX=1",
        "-Xcc=-sUSE_SDL=2",
        "-Xcc=-sMIN_WEBGL_VERSION=2",
        "-Xcc=-sMAX_WEBGL_VERSION=2",
        "-Xcc=-sFULL_ES3",
        "-Xcc=-sALLOW_MEMORY_GROWTH=1",
        "-Xcc=-sMAXIMUM_MEMORY=4GB",
        "-Xcc=-sINCOMING_MODULE_JS_API=arguments,canvas,wasmBinary,print,printErr,onRuntimeInitialized",
        "-Xcc=--preload-file=$PACKAGE_DIR/config@/config",
        "-Xcc=--js-library",
        "-Xcc=$PACKAGE_DIR/web/lib/file_bridge.js",
        "-Xcc=--js-library",
        "-Xcc=$PACKAGE_DIR/web/lib/assimp_bridge.js",
        "-Xcc=--js-library",
        "-Xcc=$PACKAGE_DIR/web/lib/remesh_bridge.js",
        "-Xcc=-sEXPORTED_FUNCTIONS=_main,_vibe3d_web_pick_done,_vibe3d_web_pick_failed",
    ];
    const expectedLflags = [
        "-L$PACKAGE_DIR/.build/web-deps/lib",
        "-L$PACKAGE_DIR/.build/web-runtime/lib",
        "$PACKAGE_DIR/.build/web-deps/lib/libcimgui_docking.a",
        "$PACKAGE_DIR/.build/web-runtime/lib/libphobos2-ldc.a",
        "$PACKAGE_DIR/.build/web-runtime/lib/libdruntime-ldc.a",
    ];
    assert(wasmDflags == expectedDflags,
        format("W16-L effective dflags-wasm changed: expected %s, got %s",
               expectedDflags, wasmDflags));
    assert(wasmLflags == expectedLflags,
        format("W16-L effective lflags-wasm changed: expected %s, got %s",
               expectedLflags, wasmLflags));

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

    enum swapIntervalSeam = q{    version (web) {
    } else SDL_GL_SetSwapInterval(
        (perfMode || (command.g_testMode && !visibleTest)) ? 0 : 1);
};
    assert(appRaw.canFind(swapIntervalSeam)
            && countOccurrences(appCode, "SDL_GL_SetSwapInterval(") == 1,
        "W16-L web must leave pre-main-loop SDL timing to Emscripten while "
        ~ "preserving the single native swap-interval call");

    const meshGpuRaw = readText(buildPath(repoRoot, "packages/viewport-gpu/source", "mesh_gpu.d"));
    enum pointResetSeam = q"D
        version (web) {
        } else glPointSize(1.0f);
        glUniform1f(locPointSize, 1.0f);
D";
    assert(meshGpuRaw.canFind(pointResetSeam),
        "W16-L must compile the legacy glPointSize reset out on web while "
        ~ "retaining the shader-uniform reset");

    const thickRaw = readText(buildPath(repoRoot, "source", "handles", "gl_util.d"));
    enum thickSubmissionSeam = q"D
    glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, segmentCount);
    version (web) if (segmentCount > 0) ++g_webThickLineInFlight;
D";
    assert(thickRaw.canFind(thickSubmissionSeam),
        "W16-L thick-line receipt must follow the real instanced draw");

    const buildWebRaw = readText(buildPath(repoRoot, "tools", "build_web.sh"));
    assert(buildWebRaw.canFind("tools/web_runtime_fingerprint.py") &&
           buildWebRaw.canFind(".build/web-artifacts") &&
           buildWebRaw.canFind(".build/web-dub-home") &&
           buildWebRaw.canFind(".build/web-link") &&
           buildWebRaw.canFind("--dest=\"$link_root\"") &&
           buildWebRaw.canFind("cmake -E touch \"$repo_root/source/app.d\"") &&
           buildWebRaw.canFind("shared_archives_before") &&
           buildWebRaw.canFind("shared_archives_after") &&
           buildWebRaw.canFind("WEB-DYNAMIC-LINKS rpath=0 runpath=0"),
        "W16-L build must fingerprint runtime sources, stale only the final "
        ~ "web target, and isolate Dub cache/artifacts from native archives");
    const abiPatchRaw = readText(buildPath(repoRoot, "tools",
                                            "patch_imgui_font_atlas_abi.py"));
    assert(abiPatchRaw.canFind("text.count(OLD) != 1") &&
           abiPatchRaw.canFind("text.count(NEW) != 0"),
        "W16-L ImFont ABI patch must reject preimage drift and repatching");

    assert(requiredWebGlSymbols.length == 88
            && optionalDesktopGlSymbols ==
               ["glBeginQuery", "glEndQuery", "glGenQueries",
                "glGetBufferSubData", "glGetQueryObjectiv",
                "glGetQueryObjectui64v", "glGetQueryiv", "glPointSize",
                "glTexBuffer"]
            && webClosureGlSymbols.length == 97,
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
mapped=()
if [[ ! -f source/ai/interaction.d && -f packages/interaction-data/source/ai/interaction.d ]]; then mapped+=(packages/interaction-data/source/ai/interaction.d); fi
if [[ ! -f source/bg_gpu_cache.d && -f packages/viewport-host/source/bg_gpu_cache.d ]]; then mapped+=(packages/viewport-host/source/bg_gpu_cache.d); fi
if [[ ! -f source/commands/tool/attr.d && -f packages/interactive-tools/source/commands/tool/attr.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/attr.d); fi
if [[ ! -f source/commands/tool/begin_session.d && -f packages/interactive-tools/source/commands/tool/begin_session.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/begin_session.d); fi
if [[ ! -f source/commands/tool/bridge_headless.d && -f packages/interactive-tools/source/commands/tool/bridge_headless.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/bridge_headless.d); fi
if [[ ! -f source/commands/tool/do_apply.d && -f packages/interactive-tools/source/commands/tool/do_apply.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/do_apply.d); fi
if [[ ! -f source/commands/tool/headless.d && -f packages/interactive-tools/source/commands/tool/headless.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/headless.d); fi
if [[ ! -f source/commands/tool/host.d && -f packages/interactive-tools/source/commands/tool/host.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/host.d); fi
if [[ ! -f source/commands/tool/lifecycle.d && -f packages/interactive-tools/source/commands/tool/lifecycle.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/lifecycle.d); fi
if [[ ! -f source/commands/tool/panel_edit.d && -f packages/interactive-tools/source/commands/tool/panel_edit.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/panel_edit.d); fi
if [[ ! -f source/commands/tool/pipe.d && -f packages/interactive-tools/source/commands/tool/pipe.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/pipe.d); fi
if [[ ! -f source/commands/tool/reset.d && -f packages/interactive-tools/source/commands/tool/reset.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/reset.d); fi
if [[ ! -f source/commands/tool/set.d && -f packages/interactive-tools/source/commands/tool/set.d ]]; then mapped+=(packages/interactive-tools/source/commands/tool/set.d); fi
if [[ ! -f source/deform_magnet.d && -f packages/interactive-tools/source/deform_magnet.d ]]; then mapped+=(packages/interactive-tools/source/deform_magnet.d); fi
if [[ ! -f source/drag.d && -f packages/interactive-tools/source/drag.d ]]; then mapped+=(packages/interactive-tools/source/drag.d); fi
if [[ ! -f source/edit_session.d && -f packages/interactive-tools/source/edit_session.d ]]; then mapped+=(packages/interactive-tools/source/edit_session.d); fi
if [[ ! -f source/evaluated_move_weld.d && -f packages/interactive-tools/source/evaluated_move_weld.d ]]; then mapped+=(packages/interactive-tools/source/evaluated_move_weld.d); fi
if [[ ! -f source/falloff_handles.d && -f packages/interactive-tools/source/falloff_handles.d ]]; then mapped+=(packages/interactive-tools/source/falloff_handles.d); fi
if [[ ! -f source/falloff_render.d && -f packages/interactive-tools/source/falloff_render.d ]]; then mapped+=(packages/interactive-tools/source/falloff_render.d); fi
if [[ ! -f source/gizmo.d && -f packages/interactive-tools/source/gizmo.d ]]; then mapped+=(packages/interactive-tools/source/gizmo.d); fi
if [[ ! -f source/handler.d && -f packages/interactive-tools/source/handler.d ]]; then mapped+=(packages/interactive-tools/source/handler.d); fi
if [[ ! -f source/handles/arbiter.d && -f packages/interactive-tools/source/handles/arbiter.d ]]; then mapped+=(packages/interactive-tools/source/handles/arbiter.d); fi
if [[ ! -f source/handles/gizmo_metrics.d && -f packages/interactive-tools/source/handles/gizmo_metrics.d ]]; then mapped+=(packages/interactive-tools/source/handles/gizmo_metrics.d); fi
if [[ ! -f source/handles/gl_util.d && -f packages/interactive-tools/source/handles/gl_util.d ]]; then mapped+=(packages/interactive-tools/source/handles/gl_util.d); fi
if [[ ! -f source/handles/shapes.d && -f packages/interactive-tools/source/handles/shapes.d ]]; then mapped+=(packages/interactive-tools/source/handles/shapes.d); fi
if [[ ! -f source/image_cache.d && -f packages/viewport-host/source/image_cache.d ]]; then mapped+=(packages/viewport-host/source/image_cache.d); fi
if [[ ! -f source/image_plane.d && -f packages/viewport-host/source/image_plane.d ]]; then mapped+=(packages/viewport-host/source/image_plane.d); fi
if [[ ! -f source/model_preview.d && -f packages/interactive-tools/source/model_preview.d ]]; then mapped+=(packages/interactive-tools/source/model_preview.d); fi
if [[ ! -f source/overlay_space.d && -f packages/interactive-tools/source/overlay_space.d ]]; then mapped+=(packages/interactive-tools/source/overlay_space.d); fi
if [[ ! -f source/pipe_gizmo_host.d && -f packages/interactive-tools/source/pipe_gizmo_host.d ]]; then mapped+=(packages/interactive-tools/source/pipe_gizmo_host.d); fi
if [[ ! -f source/prepared_box_param.d && -f packages/interactive-tools/source/prepared_box_param.d ]]; then mapped+=(packages/interactive-tools/source/prepared_box_param.d); fi
if [[ ! -f source/prepared_bridge_activation.d && -f packages/interactive-tools/source/prepared_bridge_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_bridge_activation.d); fi
if [[ ! -f source/prepared_command_wrapper_activation.d && -f packages/interactive-tools/source/prepared_command_wrapper_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_command_wrapper_activation.d); fi
if [[ ! -f source/prepared_edge_bevel_activation.d && -f packages/interactive-tools/source/prepared_edge_bevel_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_bevel_activation.d); fi
if [[ ! -f source/prepared_edge_extend_deactivate.d && -f packages/interactive-tools/source/prepared_edge_extend_deactivate.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_extend_deactivate.d); fi
if [[ ! -f source/prepared_edge_extend_tool_activation.d && -f packages/interactive-tools/source/prepared_edge_extend_tool_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_extend_tool_activation.d); fi
if [[ ! -f source/prepared_edge_extrude_activation.d && -f packages/interactive-tools/source/prepared_edge_extrude_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_extrude_activation.d); fi
if [[ ! -f source/prepared_edge_slice_activation.d && -f packages/interactive-tools/source/prepared_edge_slice_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_slice_activation.d); fi
if [[ ! -f source/prepared_edge_slice_deactivate.d && -f packages/interactive-tools/source/prepared_edge_slice_deactivate.d ]]; then mapped+=(packages/interactive-tools/source/prepared_edge_slice_deactivate.d); fi
if [[ ! -f source/prepared_inherited_noop.d && -f packages/interactive-tools/source/prepared_inherited_noop.d ]]; then mapped+=(packages/interactive-tools/source/prepared_inherited_noop.d); fi
if [[ ! -f source/prepared_loop_slice_activation.d && -f packages/interactive-tools/source/prepared_loop_slice_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_loop_slice_activation.d); fi
if [[ ! -f source/prepared_loop_slice_deactivate.d && -f packages/interactive-tools/source/prepared_loop_slice_deactivate.d ]]; then mapped+=(packages/interactive-tools/source/prepared_loop_slice_deactivate.d); fi
if [[ ! -f source/prepared_mirror_activation.d && -f packages/interactive-tools/source/prepared_mirror_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_mirror_activation.d); fi
if [[ ! -f source/prepared_move_update.d && -f packages/interactive-tools/source/prepared_move_update.d ]]; then mapped+=(packages/interactive-tools/source/prepared_move_update.d); fi
if [[ ! -f source/prepared_param_update.d && -f packages/interactive-tools/source/prepared_param_update.d ]]; then mapped+=(packages/interactive-tools/source/prepared_param_update.d); fi
if [[ ! -f source/prepared_pipe_activation.d && -f packages/interactive-tools/source/prepared_pipe_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_pipe_activation.d); fi
if [[ ! -f source/prepared_poly_bevel_activation.d && -f packages/interactive-tools/source/prepared_poly_bevel_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_poly_bevel_activation.d); fi
if [[ ! -f source/prepared_poly_extrude_activation.d && -f packages/interactive-tools/source/prepared_poly_extrude_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_poly_extrude_activation.d); fi
if [[ ! -f source/prepared_poly_inset_activation.d && -f packages/interactive-tools/source/prepared_poly_inset_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_poly_inset_activation.d); fi
if [[ ! -f source/prepared_private_state.d && -f packages/interactive-tools/source/prepared_private_state.d ]]; then mapped+=(packages/interactive-tools/source/prepared_private_state.d); fi
if [[ ! -f source/prepared_radial_array_transition.d && -f packages/interactive-tools/source/prepared_radial_array_transition.d ]]; then mapped+=(packages/interactive-tools/source/prepared_radial_array_transition.d); fi
if [[ ! -f source/prepared_radial_sweep_transition.d && -f packages/interactive-tools/source/prepared_radial_sweep_transition.d ]]; then mapped+=(packages/interactive-tools/source/prepared_radial_sweep_transition.d); fi
if [[ ! -f source/prepared_record_context.d && -f packages/interactive-tools/source/prepared_record_context.d ]]; then mapped+=(packages/interactive-tools/source/prepared_record_context.d); fi
if [[ ! -f source/prepared_rotate_update.d && -f packages/interactive-tools/source/prepared_rotate_update.d ]]; then mapped+=(packages/interactive-tools/source/prepared_rotate_update.d); fi
if [[ ! -f source/prepared_scale_update.d && -f packages/interactive-tools/source/prepared_scale_update.d ]]; then mapped+=(packages/interactive-tools/source/prepared_scale_update.d); fi
if [[ ! -f source/prepared_selection_profile.d && -f packages/interactive-tools/source/prepared_selection_profile.d ]]; then mapped+=(packages/interactive-tools/source/prepared_selection_profile.d); fi
if [[ ! -f source/prepared_selection_profile_image.d && -f packages/interactive-tools/source/prepared_selection_profile_image.d ]]; then mapped+=(packages/interactive-tools/source/prepared_selection_profile_image.d); fi
if [[ ! -f source/prepared_slice_activation.d && -f packages/interactive-tools/source/prepared_slice_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_slice_activation.d); fi
if [[ ! -f source/prepared_slice_deactivate.d && -f packages/interactive-tools/source/prepared_slice_deactivate.d ]]; then mapped+=(packages/interactive-tools/source/prepared_slice_deactivate.d); fi
if [[ ! -f source/prepared_smooth_shift_activation.d && -f packages/interactive-tools/source/prepared_smooth_shift_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_smooth_shift_activation.d); fi
if [[ ! -f source/prepared_stroke_extrude_activation.d && -f packages/interactive-tools/source/prepared_stroke_extrude_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_stroke_extrude_activation.d); fi
if [[ ! -f source/prepared_tack_activation.d && -f packages/interactive-tools/source/prepared_tack_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_tack_activation.d); fi
if [[ ! -f source/prepared_tool_transition.d && -f packages/interactive-tools/source/prepared_tool_transition.d ]]; then mapped+=(packages/interactive-tools/source/prepared_tool_transition.d); fi
if [[ ! -f source/prepared_topology_pen_activation.d && -f packages/interactive-tools/source/prepared_topology_pen_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_topology_pen_activation.d); fi
if [[ ! -f source/prepared_topology_pen_deactivate.d && -f packages/interactive-tools/source/prepared_topology_pen_deactivate.d ]]; then mapped+=(packages/interactive-tools/source/prepared_topology_pen_deactivate.d); fi
if [[ ! -f source/prepared_topology_pen_update.d && -f packages/interactive-tools/source/prepared_topology_pen_update.d ]]; then mapped+=(packages/interactive-tools/source/prepared_topology_pen_update.d); fi
if [[ ! -f source/prepared_transform_activation.d && -f packages/interactive-tools/source/prepared_transform_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_transform_activation.d); fi
if [[ ! -f source/prepared_transform_product_activation.d && -f packages/interactive-tools/source/prepared_transform_product_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_transform_product_activation.d); fi
if [[ ! -f source/prepared_vertex_bevel_activation.d && -f packages/interactive-tools/source/prepared_vertex_bevel_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_vertex_bevel_activation.d); fi
if [[ ! -f source/prepared_vertex_extrude_activation.d && -f packages/interactive-tools/source/prepared_vertex_extrude_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_vertex_extrude_activation.d); fi
if [[ ! -f source/prepared_vertex_merge_activation.d && -f packages/interactive-tools/source/prepared_vertex_merge_activation.d ]]; then mapped+=(packages/interactive-tools/source/prepared_vertex_merge_activation.d); fi
if [[ ! -f source/prepared_xfrm_activation_session.d && -f packages/interactive-tools/source/prepared_xfrm_activation_session.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_activation_session.d); fi
if [[ ! -f source/prepared_xfrm_refire_state.d && -f packages/interactive-tools/source/prepared_xfrm_refire_state.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_refire_state.d); fi
if [[ ! -f source/prepared_xfrm_replay.d && -f packages/interactive-tools/source/prepared_xfrm_replay.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_replay.d); fi
if [[ ! -f source/prepared_xfrm_slot_poll.d && -f packages/interactive-tools/source/prepared_xfrm_slot_poll.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_slot_poll.d); fi
if [[ ! -f source/prepared_xfrm_update_boundary.d && -f packages/interactive-tools/source/prepared_xfrm_update_boundary.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_update_boundary.d); fi
if [[ ! -f source/prepared_xfrm_update_edit_close.d && -f packages/interactive-tools/source/prepared_xfrm_update_edit_close.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_update_edit_close.d); fi
if [[ ! -f source/prepared_xfrm_update_tail.d && -f packages/interactive-tools/source/prepared_xfrm_update_tail.d ]]; then mapped+=(packages/interactive-tools/source/prepared_xfrm_update_tail.d); fi
if [[ ! -f source/property_panel.d && -f packages/interactive-tools/source/property_panel.d ]]; then mapped+=(packages/interactive-tools/source/property_panel.d); fi
if [[ ! -f source/registry.d && -f packages/interactive-tools/source/registry.d ]]; then mapped+=(packages/interactive-tools/source/registry.d); fi
if [[ ! -f source/snap_render.d && -f packages/interactive-tools/source/snap_render.d ]]; then mapped+=(packages/interactive-tools/source/snap_render.d); fi
if [[ ! -f source/tool.d && -f packages/interactive-tools/source/tool.d ]]; then mapped+=(packages/interactive-tools/source/tool.d); fi
if [[ ! -f source/tool_attr_bounds.d && -f packages/interactive-tools/source/tool_attr_bounds.d ]]; then mapped+=(packages/interactive-tools/source/tool_attr_bounds.d); fi
if [[ ! -f source/tool_disarm.d && -f packages/interactive-tools/source/tool_disarm.d ]]; then mapped+=(packages/interactive-tools/source/tool_disarm.d); fi
if [[ ! -f source/tool_presets.d && -f packages/interactive-tools/source/tool_presets.d ]]; then mapped+=(packages/interactive-tools/source/tool_presets.d); fi
if [[ ! -f source/tools/alignment/array_tool.d && -f packages/interactive-tools/source/tools/alignment/array_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/array_tool.d); fi
if [[ ! -f source/tools/alignment/clone_tool.d && -f packages/interactive-tools/source/tools/alignment/clone_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/clone_tool.d); fi
if [[ ! -f source/tools/alignment/linear_align_tool.d && -f packages/interactive-tools/source/tools/alignment/linear_align_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/linear_align_tool.d); fi
if [[ ! -f source/tools/alignment/mirror.d && -f packages/interactive-tools/source/tools/alignment/mirror.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/mirror.d); fi
if [[ ! -f source/tools/alignment/radial_align_tool.d && -f packages/interactive-tools/source/tools/alignment/radial_align_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/radial_align_tool.d); fi
if [[ ! -f source/tools/alignment/radial_array_tool.d && -f packages/interactive-tools/source/tools/alignment/radial_array_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/radial_array_tool.d); fi
if [[ ! -f source/tools/alignment/radial_sweep_tool.d && -f packages/interactive-tools/source/tools/alignment/radial_sweep_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/alignment/radial_sweep_tool.d); fi
if [[ ! -f source/tools/common/command_wrapper.d && -f packages/interactive-tools/source/tools/common/command_wrapper.d ]]; then mapped+=(packages/interactive-tools/source/tools/common/command_wrapper.d); fi
if [[ ! -f source/tools/create/arc.d && -f packages/interactive-tools/source/tools/create/arc.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/arc.d); fi
if [[ ! -f source/tools/create/box.d && -f packages/interactive-tools/source/tools/create/box.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/box.d); fi
if [[ ! -f source/tools/create/capsule.d && -f packages/interactive-tools/source/tools/create/capsule.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/capsule.d); fi
if [[ ! -f source/tools/create/cone.d && -f packages/interactive-tools/source/tools/create/cone.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/cone.d); fi
if [[ ! -f source/tools/create/create_common.d && -f packages/interactive-tools/source/tools/create/create_common.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/create_common.d); fi
if [[ ! -f source/tools/create/cylinder.d && -f packages/interactive-tools/source/tools/create/cylinder.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/cylinder.d); fi
if [[ ! -f source/tools/create/pen.d && -f packages/interactive-tools/source/tools/create/pen.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/pen.d); fi
if [[ ! -f source/tools/create/primitive_create_tool.d && -f packages/interactive-tools/source/tools/create/primitive_create_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/primitive_create_tool.d); fi
if [[ ! -f source/tools/create/sphere.d && -f packages/interactive-tools/source/tools/create/sphere.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/sphere.d); fi
if [[ ! -f source/tools/create/torus.d && -f packages/interactive-tools/source/tools/create/torus.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/torus.d); fi
if [[ ! -f source/tools/create/tube.d && -f packages/interactive-tools/source/tools/create/tube.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/tube.d); fi
if [[ ! -f source/tools/create/vertex_place.d && -f packages/interactive-tools/source/tools/create/vertex_place.d ]]; then mapped+=(packages/interactive-tools/source/tools/create/vertex_place.d); fi
if [[ ! -f source/tools/deform/bend.d && -f packages/interactive-tools/source/tools/deform/bend.d ]]; then mapped+=(packages/interactive-tools/source/tools/deform/bend.d); fi
if [[ ! -f source/tools/deform/magnet.d && -f packages/interactive-tools/source/tools/deform/magnet.d ]]; then mapped+=(packages/interactive-tools/source/tools/deform/magnet.d); fi
if [[ ! -f source/tools/deform/push.d && -f packages/interactive-tools/source/tools/deform/push.d ]]; then mapped+=(packages/interactive-tools/source/tools/deform/push.d); fi
if [[ ! -f source/tools/deform/smooth_shift_tool.d && -f packages/interactive-tools/source/tools/deform/smooth_shift_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/deform/smooth_shift_tool.d); fi
if [[ ! -f source/tools/deform/stroke_extrude_tool.d && -f packages/interactive-tools/source/tools/deform/stroke_extrude_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/deform/stroke_extrude_tool.d); fi
if [[ ! -f source/tools/edit/bridge_tool.d && -f packages/interactive-tools/source/tools/edit/bridge_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/bridge_tool.d); fi
if [[ ! -f source/tools/edit/edge_bevel.d && -f packages/interactive-tools/source/tools/edit/edge_bevel.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/edge_bevel.d); fi
if [[ ! -f source/tools/edit/edge_extend.d && -f packages/interactive-tools/source/tools/edit/edge_extend.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/edge_extend.d); fi
if [[ ! -f source/tools/edit/edge_extrude.d && -f packages/interactive-tools/source/tools/edit/edge_extrude.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/edge_extrude.d); fi
if [[ ! -f source/tools/edit/haul_axis_latch.d && -f packages/interactive-tools/source/tools/edit/haul_axis_latch.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/haul_axis_latch.d); fi
if [[ ! -f source/tools/edit/poly_bevel.d && -f packages/interactive-tools/source/tools/edit/poly_bevel.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/poly_bevel.d); fi
if [[ ! -f source/tools/edit/poly_extrude.d && -f packages/interactive-tools/source/tools/edit/poly_extrude.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/poly_extrude.d); fi
if [[ ! -f source/tools/edit/poly_inset_tool.d && -f packages/interactive-tools/source/tools/edit/poly_inset_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/poly_inset_tool.d); fi
if [[ ! -f source/tools/edit/reduce.d && -f packages/interactive-tools/source/tools/edit/reduce.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/reduce.d); fi
if [[ ! -f source/tools/edit/smooth_relax.d && -f packages/interactive-tools/source/tools/edit/smooth_relax.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/smooth_relax.d); fi
if [[ ! -f source/tools/edit/tack.d && -f packages/interactive-tools/source/tools/edit/tack.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/tack.d); fi
if [[ ! -f source/tools/edit/topology_pen/defs.d && -f packages/interactive-tools/source/tools/edit/topology_pen/defs.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/defs.d); fi
if [[ ! -f source/tools/edit/topology_pen/json.d && -f packages/interactive-tools/source/tools/edit/topology_pen/json.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/json.d); fi
if [[ ! -f source/tools/edit/topology_pen/package.d && -f packages/interactive-tools/source/tools/edit/topology_pen/package.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/package.d); fi
if [[ ! -f source/tools/edit/topology_pen/render.d && -f packages/interactive-tools/source/tools/edit/topology_pen/render.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/render.d); fi
if [[ ! -f source/tools/edit/topology_pen/snap_guide.d && -f packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/snap_guide.d); fi
if [[ ! -f source/tools/edit/topology_pen/tool.d && -f packages/interactive-tools/source/tools/edit/topology_pen/tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/topology_pen/tool.d); fi
if [[ ! -f source/tools/edit/vert_merge_tool.d && -f packages/interactive-tools/source/tools/edit/vert_merge_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/vert_merge_tool.d); fi
if [[ ! -f source/tools/edit/vertex_bevel_tool.d && -f packages/interactive-tools/source/tools/edit/vertex_bevel_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/vertex_bevel_tool.d); fi
if [[ ! -f source/tools/edit/vertex_extrude_tool.d && -f packages/interactive-tools/source/tools/edit/vertex_extrude_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/edit/vertex_extrude_tool.d); fi
if [[ ! -f source/tools/slice/edge_slice_tool.d && -f packages/interactive-tools/source/tools/slice/edge_slice_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/slice/edge_slice_tool.d); fi
if [[ ! -f source/tools/slice/edge_slide.d && -f packages/interactive-tools/source/tools/slice/edge_slide.d ]]; then mapped+=(packages/interactive-tools/source/tools/slice/edge_slide.d); fi
if [[ ! -f source/tools/slice/loop_slice_tool.d && -f packages/interactive-tools/source/tools/slice/loop_slice_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/slice/loop_slice_tool.d); fi
if [[ ! -f source/tools/slice/slice_tool.d && -f packages/interactive-tools/source/tools/slice/slice_tool.d ]]; then mapped+=(packages/interactive-tools/source/tools/slice/slice_tool.d); fi
if [[ ! -f source/tools/topology_step.d && -f packages/interactive-tools/source/tools/topology_step.d ]]; then mapped+=(packages/interactive-tools/source/tools/topology_step.d); fi
if [[ ! -f source/tools/transform/move.d && -f packages/interactive-tools/source/tools/transform/move.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/move.d); fi
if [[ ! -f source/tools/transform/rotate.d && -f packages/interactive-tools/source/tools/transform/rotate.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/rotate.d); fi
if [[ ! -f source/tools/transform/scale.d && -f packages/interactive-tools/source/tools/transform/scale.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/scale.d); fi
if [[ ! -f source/tools/transform/transform.d && -f packages/interactive-tools/source/tools/transform/transform.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/transform.d); fi
if [[ ! -f source/tools/transform/xfrm_apply.d && -f packages/interactive-tools/source/tools/transform/xfrm_apply.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/xfrm_apply.d); fi
if [[ ! -f source/tools/transform/xfrm_handles.d && -f packages/interactive-tools/source/tools/transform/xfrm_handles.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/xfrm_handles.d); fi
if [[ ! -f source/tools/transform/xfrm_item.d && -f packages/interactive-tools/source/tools/transform/xfrm_item.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/xfrm_item.d); fi
if [[ ! -f source/tools/transform/xfrm_transform.d && -f packages/interactive-tools/source/tools/transform/xfrm_transform.d ]]; then mapped+=(packages/interactive-tools/source/tools/transform/xfrm_transform.d); fi
if [[ ! -f source/viewport.d && -f packages/viewport-host/source/viewport.d ]]; then mapped+=(packages/viewport-host/source/viewport.d); fi
if [[ ! -f source/viewport_composite.d && -f packages/viewport-host/source/viewport_composite.d ]]; then mapped+=(packages/viewport-host/source/viewport_composite.d); fi
if [[ ! -f source/coord_rounding.d && -f packages/interactive-tools/source/coord_rounding.d ]]; then mapped+=(packages/interactive-tools/source/coord_rounding.d); fi
if [[ ! -f source/value_drag.d && -f packages/interactive-tools/source/value_drag.d ]]; then mapped+=(packages/interactive-tools/source/value_drag.d); fi
if [[ ! -f source/params_widgets.d && -f packages/interactive-tools/source/params_widgets.d ]]; then mapped+=(packages/interactive-tools/source/params_widgets.d); fi
if [[ ! -f source/commands/layer/xform_edit.d && -f packages/editor-commands/source/commands/layer/xform_edit.d ]]; then mapped+=(packages/editor-commands/source/commands/layer/xform_edit.d); fi
if [[ ! -f source/io/doc_state.d && -f packages/application-core/source/io/doc_state.d ]]; then mapped+=(packages/application-core/source/io/doc_state.d); fi
if [[ ! -f source/ai/advisor.d && -f packages/interaction-data/source/ai/advisor.d ]]; then mapped+=(packages/interaction-data/source/ai/advisor.d); fi
if [[ ! -f source/ai/debug_trace.d && -f packages/interaction-data/source/ai/debug_trace.d ]]; then mapped+=(packages/interaction-data/source/ai/debug_trace.d); fi
if [[ ! -f source/commands/mesh/smooth.d && -f packages/interactive-tools/source/commands/mesh/smooth.d ]]; then mapped+=(packages/interactive-tools/source/commands/mesh/smooth.d); fi
python3 tools/ci/dmd_with_dub_flags.py "$flags" -deps="$3" -o- -c $(find source packages/common/source packages/mesh-ops/source packages/interchange/source packages/interaction-query/source packages/pipe-evaluation/source packages/tool-state/source packages/transform-ops/source packages/creation-ops/source packages/alignment-ops/source packages/input-events/source packages/display-policy/source packages/viewport-gpu/source packages/subpatch-preview/source packages/edit-contracts/source packages/mesh-change/source packages/mesh-contracts/source packages/mesh-edit-log/source packages/mesh-edit-replay/source packages/mesh-snapshot/source packages/mesh-topology/source packages/mesh/source packages/profiling/source packages/spatial/source util/log/source libraries/util/math/source/vibe3d/util/math util/parallel/source util/plane-bytes/source util/screen-buckets/source -name '*.d' ! -path 'libraries/util/math/source/vibe3d/util/math/package.d' -print) "${mapped[@]}"
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
    assert(importers.length == 23 && callers.length == 22
            && importers.canFind("editor_app")
            && !callers.canFind("editor_app"),
        format("W16-LD web GL consumer population changed: importers=%d %s; "
             ~ "callers=%d %s", importers.length, importers,
               callers.length, callers));
    assert(actual == expected,
        format("W16-LD web GL call roster drifted: expected %s, got %s",
               expected, actual));
}
