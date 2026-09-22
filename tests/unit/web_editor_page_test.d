module tests.unit.web_editor_page_test;

import std.file : readText;
import std.string : count, indexOf;

unittest
{
    const page = readText("web/editor/index.html");
    const serve = readText("tools/serve_web_editor.sh");
    const gate = readText("tools/web_editor_liveness.mjs");
    const gateRunner = readText("tools/test_web_editor.sh");
    const app = readText("source/app.d");

    assert(page.count("<script src=\"vibe3d.js\"></script>") == 1,
        "the interactive editor must load staged assets, not inline a capture bundle");
    assert(page.indexOf("--web-first-frame-probe") >= 0
        && page.indexOf("query.get('probe')") >= 0,
        "automation probes must be opt-in on the same interactive entry point");
    assert(page.indexOf("canvas.focus") >= 0 && page.indexOf("tabindex=\"0\"") >= 0,
        "the editor canvas must take keyboard focus after runtime startup");
    assert(page.indexOf("unhandledrejection") >= 0 && page.indexOf("className = 'error'") >= 0,
        "a stopped frame loop must be visible instead of looking like ignored input");
    assert(page.count("glGetVertexAttrib*v on client-side array: not supported, bad data returned") == 1
        && page.count("glGetVertexAttribPointer on client-side array: not supported, bad data returned") == 1,
        "both actual per-frame WebGL diagnostics must be pinned exactly");
    assert(page.indexOf("if (!noisyWebGlQueries.has(value))") >= 0,
        "the two pinned diagnostics must be filtered from the console");
    assert(page.indexOf("textContent +=") < 0,
        "the interactive page must never restore the review harness's growing DOM log");
    assert(serve.indexOf("http.server") >= 0 && serve.indexOf(".build/web-editor") >= 0,
        "the permanent entry point must have one local serve command");

    assert(gate.indexOf("delayedInputMs") >= 0
        && gate.indexOf("Input.dispatchKeyEvent") >= 0
        && gate.indexOf("Input.dispatchMouseEvent") >= 0,
        "the liveness witness must inject both native key and mouse input after delay");
    assert(gateRunner.count("for mode in normal spreset") == 1
        && gateRunner.indexOf("tools/spreset.py") >= 0,
        "delayed liveness must cover normal and reset-stack artifacts");
    assert(app.count("WEB-EDITOR-DELAYED-LIVE") == 1
        && app.indexOf("WEB-EDITOR-DELAYED-LIVE") > app.indexOf("ImGui.NewFrame();"),
        "the terminal delayed receipt must come from the later ImGui frame");
    assert(app.count("igIsKeyDown_Nil(webProbeKeyA)") == 1
        && app.indexOf("consumedDelayedKey") > app.indexOf("ImGui.NewFrame();")
        && app.indexOf("&& consumedDelayedKey") < app.indexOf("WEB-EDITOR-DELAYED-LIVE"),
        "the terminal receipt must depend on ImGui's post-NewFrame key consumer");
}
