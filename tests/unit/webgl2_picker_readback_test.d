module tests.unit.webgl2_picker_readback_test;

import std.algorithm : count;
import std.file : exists, readText, remove, tempDir, write;
import std.format : format;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : Config, execute, thisProcessID;
import std.string : indexOf, replace;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string browserBinary() {
    foreach (candidate; ["chromium-browser", "chromium", "google-chrome"])
        if (execute(["bash", "-c", "command -v \"$1\"", "which", candidate])
                .status == 0)
            return candidate;
    return null;
}

unittest { // real WebGL2 R32UI readback and production wiring
    const source = readText(buildPath(repoRoot, "source", "gpu_select.d"));
    assert(source.count("readIdPixels(") == 4,
        "W16-D production census: expected one helper plus all three picker callers");
    assert(source.count("glReadPixels(") == 1,
        "W16-D all picker readbacks must pass through the portable helper");
    assert(source.count("GL_RGBA_INTEGER, GL_UNSIGNED_INT, rgba.ptr") == 1,
        "W16-D portable WebGL2 integer readback pair drifted");
    assert(source.count("GL_RED_INTEGER, GL_UNSIGNED_INT, buf.ptr") == 0,
        "W16-D implementation-dependent RED_INTEGER picker readback returned");
    assert(source.count("new uint[](rw * rh * 4)") == 2
        && source.count("new uint[](fboW * fboH * 4)") == 1,
        "W16-D each picker readback buffer must carry four uint lanes per pixel");
    assert(source.count("i += 4") == 2
        && source.count("buf[(j * rw + i) * 4]") == 1,
        "W16-D all three picker consumers must read only the red lane");

    const path = buildPath(tempDir(),
        format("vibe3d-w16-d-picker-%d.html", thisProcessID()));
    scope (exit) if (exists(path)) remove(path);
    write(path, q"HTML
<!doctype html><meta charset=utf-8><pre id=result></pre><script>
const marker=0xdeadbeef, expected=0x13579bdf;
const gl=document.createElement('canvas').getContext('webgl2');
const out={};
function drain(){const a=[]; for(let e; (e=gl.getError())!==gl.NO_ERROR;) a.push(e); return a;}
function classify(a,err,want){
  const intact=a.every(x=>x===marker);
  if(intact && err!==gl.NO_ERROR) return 'unsupported';
  if(intact) return 'silent';
  if(err===gl.NO_ERROR && a[0]===want) return 'correct';
  return 'wrong';
}
if(!gl) out.fatal='no-webgl2';
else {
  const tex=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,tex);
  gl.texStorage2D(gl.TEXTURE_2D,1,gl.R32UI,1,1);
  const fbo=gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER,fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,tex,0);
  out.fbo=gl.checkFramebufferStatus(gl.FRAMEBUFFER);
  gl.drawBuffers([gl.COLOR_ATTACHMENT0]); gl.readBuffer(gl.COLOR_ATTACHMENT0);

  // Background is exactly zero, preserving the native picker's sentinel.
  gl.clearBufferuiv(gl.COLOR,0,new Uint32Array([0,0,0,0])); drain();
  const bg=new Uint32Array(4); bg.fill(marker); drain();
  gl.readPixels(0,0,1,1,gl.RGBA_INTEGER,gl.UNSIGNED_INT,bg);
  const bgErr=gl.getError(); out.background=[...bg]; out.backgroundError=bgErr;

  // One real draw writes a known non-zero selection ID.
  const vs=gl.createShader(gl.VERTEX_SHADER);
  gl.shaderSource(vs,'#version 300 es\nvoid main(){const vec2 p[3]=vec2[3](vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));gl_Position=vec4(p[gl_VertexID],0.,1.);}');
  gl.compileShader(vs);
  const fs=gl.createShader(gl.FRAGMENT_SHADER);
  gl.shaderSource(fs,'#version 300 es\nprecision highp int;layout(location=0) out uint id;void main(){id=uint('+expected+');}');
  gl.compileShader(fs); const program=gl.createProgram();
  gl.attachShader(program,vs); gl.attachShader(program,fs); gl.linkProgram(program);
  out.shader=!!gl.getShaderParameter(vs,gl.COMPILE_STATUS)&&!!gl.getShaderParameter(fs,gl.COMPILE_STATUS)&&!!gl.getProgramParameter(program,gl.LINK_STATUS);
  gl.useProgram(program); gl.viewport(0,0,1,1); gl.drawArrays(gl.TRIANGLES,0,3);

  const rgba=new Uint32Array(4); rgba.fill(marker); out.preRgba=drain();
  gl.readPixels(0,0,1,1,gl.RGBA_INTEGER,gl.UNSIGNED_INT,rgba);
  const rgbaErr=gl.getError(); out.rgba=[...rgba]; out.rgbaError=rgbaErr;
  out.rgbaOutcome=classify(rgba,rgbaErr,expected);

  out.implFormat=gl.getParameter(gl.IMPLEMENTATION_COLOR_READ_FORMAT);
  out.implType=gl.getParameter(gl.IMPLEMENTATION_COLOR_READ_TYPE);
  const impl=new Uint32Array(out.implFormat===gl.RGBA_INTEGER?4:1); impl.fill(marker);
  out.preImpl=drain(); gl.readPixels(0,0,1,1,out.implFormat,out.implType,impl);
  const implErr=gl.getError(); out.impl=[...impl]; out.implError=implErr;
  out.implOutcome=classify(impl,implErr,expected);
}
document.getElementById('result').textContent=JSON.stringify(out);
</script>
HTML");

    const browser = browserBinary();
    assert(browser !is null, "W16-D Chromium executable is required");
    const run = execute([browser, "--headless", "--no-sandbox",
        "--disable-dev-shm-usage", "--use-gl=angle",
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--dump-dom", "file://" ~ path], null, Config.none,
        size_t.max, repoRoot);
    assert(run.status == 0,
        format("W16-D Chromium witness failed (%d):\n%s", run.status, run.output));
    const begin = run.output.indexOf("<pre id=\"result\">");
    const end = run.output.indexOf("</pre>");
    assert(begin >= 0 && end > begin, "W16-D browser result block missing");
    auto text = run.output[cast(size_t)begin + `<pre id="result">`.length
                           .. cast(size_t)end]
        .replace("&quot;", "\"").replace("&amp;", "&");
    auto row = parseJSON(text);
    assert(!("fatal" in row), "W16-D requires a real WebGL2 context");
    assert(row["fbo"].integer == 0x8CD5, "W16-D R32UI framebuffer incomplete");
    assert(row["shader"].boolean, "W16-D known-ID draw shader failed");
    assert(row["backgroundError"].integer == 0
        && row["background"].array[0].integer == 0,
        "W16-D background sentinel must read as zero");
    assert(row["preRgba"].array.length == 0,
        "W16-D RGBA result is contaminated by an earlier GL error");
    assert(row["rgbaOutcome"].str == "correct",
        "W16-D RGBA_INTEGER/UNSIGNED_INT outcome: " ~ row["rgbaOutcome"].str);
    assert(row["preImpl"].array.length == 0,
        "W16-D implementation-pair result is contaminated by an earlier GL error");
    assert(row["implOutcome"].str == "correct",
        "W16-D advertised implementation pair outcome: " ~ row["implOutcome"].str);
}
