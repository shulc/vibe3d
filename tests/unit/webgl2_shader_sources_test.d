module tests.unit.webgl2_shader_sources_test;

import std.algorithm : canFind, count, startsWith;
import std.array : join;
import std.file : exists, readText, remove, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, replace, splitLines, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum beginMarker = "W16_SHADER_BEGIN:";
private enum endMarker = "W16_SHADER_END:";

private struct ShaderCase {
    string name;
    string stage;
    string source;
}

private string browserBinary() {
    foreach (candidate; ["chromium-browser", "chromium", "google-chrome"])
        if (execute(["bash", "-c", "command -v \"$1\"", "which", candidate])
                .status == 0)
            return candidate;
    return null;
}

unittest {
    const stem = format("vibe3d-w16-b-shaders-%d", thisProcessID());
    const extractorPath = buildPath(tempDir(), stem ~ "-extract.d");
    const htmlPath = buildPath(tempDir(), stem ~ ".html");
    const describeErrors = buildPath(tempDir(), stem ~ ".describe-errors");
    scope (exit) {
        foreach (path; [extractorPath, htmlPath, describeErrors])
            if (exists(path)) remove(path);
    }

    // The names and stages are pinned here so a disappearing source cannot
    // turn the browser pass into a smaller, vacuously green set.
    immutable string[2][] expected = [
        ["shader.vertexShaderSrc", "vertex"],
        ["shader.fragmentShaderSrc", "fragment"],
        ["shader.fillFragSrc", "fragment"],
        ["shader.imagePlaneVertSrc", "vertex"],
        ["shader.imagePlaneFragSrc", "fragment"],
        ["shader.litVertSrc", "vertex"],
        ["shader.litFragSrc", "fragment"],
        ["shader.checkerFragSrc", "fragment"],
        ["shader.gridVertSrc", "vertex"],
        ["shader.gridFragSrc", "fragment"],
        ["shader.thickLineVertexSrc", "vertex"],
        ["shader.thickLineFragSrc", "fragment"],
        ["gpu_select.vertVertSrc", "vertex"],
        ["gpu_select.edgeVertSrc", "vertex"],
        ["gpu_select.faceVertSrc", "vertex"],
        ["gpu_select.depthVertSrc", "vertex"],
        ["gpu_select.commonFragSrc", "fragment"],
        ["gpu_select.zeroFragSrc", "fragment"],
    ];
    assert(expected.length == 18, "W16-B named shader population floor moved");

    string extractor = "module w16_b_shader_extract;\n"
        ~ "import shader; import gpu_select;\n";
    foreach (entry; expected) {
        const dot = entry[0].indexOf('.');
        const moduleName = entry[0][0 .. cast(size_t) dot];
        const sourceName = entry[0][cast(size_t) dot + 1 .. $];
        const expression = moduleName == "shader"
            ? "shaderSourceForValidation(\"" ~ sourceName ~ "\")"
            : "gpuSelectShaderSourceForValidation(\"" ~ sourceName ~ "\")";
        extractor ~= "pragma(msg, \"" ~ beginMarker ~ entry[0] ~ "\");\n"
                  ~ "pragma(msg, " ~ expression ~ ");\n"
                  ~ "pragma(msg, \"" ~ endMarker ~ entry[0] ~ "\");\n";
    }
    write(extractorPath, extractor);

    enum extractCommand = q"SH
set -euo pipefail
cd "$1"
flags=$(dub describe --config=web \
  --data=import-paths,string-import-paths,versions,debug-versions,dflags \
  2>"$2") || { cat "$2"; exit 1; }
case " $flags " in *" -version=web "*) ;; *)
  echo "FATAL: web shader extraction has no -version=web" >&2; exit 2;;
esac
dmd -o- -c $flags "$3" 2>&1
SH";
    const extracted = execute(["bash", "-c", extractCommand,
        "w16-b-extract", repoRoot, describeErrors, extractorPath],
        null, Config.none, size_t.max, repoRoot);
    assert(extracted.status == 0,
        format("W16-B D constant extraction failed (%d):\n%s",
               extracted.status, extracted.output));

    ShaderCase[] cases;
    foreach (entry; expected) {
        const begin = beginMarker ~ entry[0] ~ "\n";
        const end = endMarker ~ entry[0];
        const beginAt = extracted.output.indexOf(begin);
        assert(beginAt >= 0, "missing extraction marker for " ~ entry[0]);
        const sourceAt = cast(size_t) beginAt + begin.length;
        const endRel = extracted.output[sourceAt .. $].indexOf(end);
        assert(endRel >= 0, "missing extraction end marker for " ~ entry[0]);
        auto source = extracted.output[sourceAt .. sourceAt + cast(size_t) endRel];
        if (source.length && source[$ - 1] == '\n') source = source[0 .. $ - 1];
        assert(source.startsWith("#version 300 es\n" ~
                                 "precision highp float;\n" ~
                                 "precision highp int;\n"),
            entry[0] ~ " must have the complete WebGL2 preamble at byte zero");
        cases ~= ShaderCase(entry[0], entry[1], source.idup);
    }
    assert(cases.length == 18,
        format("W16-B extracted %d named sources instead of 18", cases.length));

    JSONValue[] jsonCases;
    foreach (c; cases) {
        JSONValue[string] object;
        object["name"] = JSONValue(c.name);
        object["stage"] = JSONValue(c.stage);
        object["source"] = JSONValue(c.source);
        jsonCases ~= JSONValue(object);
    }
    JSONValue payload = JSONValue(jsonCases);
    const controls = `[
      {name:"control.noperspective",stage:"fragment",source:"#version 300 es\nprecision highp float;\nnoperspective in float x; out vec4 c; void main(){c=vec4(x);}"},
      {name:"control.samplerBuffer",stage:"fragment",source:"#version 300 es\nprecision highp float;\nuniform samplerBuffer b; out vec4 c; void main(){c=texelFetch(b,0);}"},
      {name:"control.leading-newline",stage:"vertex",source:"\n#version 300 es\nvoid main(){gl_Position=vec4(0.0);}"}
    ]`;
    const html = "<!doctype html><meta charset=utf-8><pre id=result></pre><script>\n"
        ~ "const cases=" ~ payload.toString() ~ "; const controls=" ~ controls ~ ";\n"
        ~ q"JS
const gl=document.createElement('canvas').getContext('webgl2');
const out=[]; let lost=false;
if (!gl) out.push('FATAL no-webgl2');
else {
  gl.canvas.addEventListener('webglcontextlost',e=>{lost=true;e.preventDefault();});
  function compile(c) {
    const sh=gl.createShader(c.stage==='vertex'?gl.VERTEX_SHADER:gl.FRAGMENT_SHADER);
    gl.shaderSource(sh,c.source); gl.compileShader(sh);
    const compiled=!!gl.getShaderParameter(sh,gl.COMPILE_STATUS);
    const log=gl.getShaderInfoLog(sh)||'';
    out.push(JSON.stringify({name:c.name,compiled,log,lost}));
    gl.deleteShader(sh);
  }
  cases.forEach(compile); controls.forEach(compile);
}
document.getElementById('result').textContent=out.join('\n');
JS" ~ "</script>";
    write(htmlPath, html);

    const browser = browserBinary();
    assert(browser !is null, "W16-B Chromium executable is required");
    const browsed = execute([browser, "--headless", "--no-sandbox",
        "--disable-dev-shm-usage", "--use-gl=angle",
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--dump-dom", "file://" ~ htmlPath], null, Config.none,
        size_t.max, repoRoot);
    assert(browsed.status == 0,
        format("W16-B Chromium validator failed (%d):\n%s",
               browsed.status, browsed.output));
    const preStart = browsed.output.indexOf("<pre id=\"result\">");
    const preEnd = browsed.output.indexOf("</pre>");
    assert(preStart >= 0 && preEnd > preStart,
        "W16-B Chromium output has no synchronous result block");
    auto resultText = browsed.output[cast(size_t) preStart
        + `<pre id="result">`.length .. cast(size_t) preEnd];
    resultText = resultText.replace("&quot;", "\"")
                           .replace("&amp;", "&")
                           .replace("&lt;", "<")
                           .replace("&gt;", ">");
    auto lines = resultText.splitLines;
    assert(lines.length == 21,
        format("W16-B browser population floor: expected 18+3, got %d:\n%s",
               lines.length, resultText));
    size_t positives, negatives;
    foreach (line; lines) {
        auto row = parseJSON(line);
        const name = row["name"].str;
        const compiled = row["compiled"].boolean;
        const log = row["log"].str;
        assert(!row["lost"].boolean, name ~ " ran after WebGL context loss");
        if (name.startsWith("control.")) {
            ++negatives;
            assert(!compiled && log.strip.length != 0,
                format("%s negative control must be rejected with a log; compiled=%s log=%s",
                       name, compiled, log));
        } else {
            ++positives;
            assert(compiled, format("%s rejected by WebGL2:\n%s", name, log));
        }
    }
    assert(positives == 18 && negatives == 3,
        format("W16-B floors moved: positives=%d negatives=%d",
               positives, negatives));

    const app = readText(buildPath(repoRoot, "source", "app.d"));
    assert(app.count(`ImGui_ImplOpenGL3_Init("#version 300 es")`) == 1
        && app.count(`ImGui_ImplOpenGL3_Init("#version 330 core")`) == 1,
        "W16-B ImGui version seam must contain one web and one desktop arm");
    const shaderCode = readText(buildPath(repoRoot, "source", "shader.d"));
    assert(!shaderCode.canFind("createProgramWithGeom")
        && !shaderCode.canFind("GL_GEOMETRY_SHADER"),
        "W16-B12 geometry-shader residue returned");
}
