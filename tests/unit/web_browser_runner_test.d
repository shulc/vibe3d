module tests.unit.web_browser_runner_test;

import std.file : readText;
import std.string : count, indexOf;

private string repoFile(string path)
{
    return readText(path);
}

unittest
{
    const app = repoFile("source/app.d");
    const runner = repoFile("tools/test_web_browser_runner.sh");
    const reset = repoFile("tools/spreset.py");

    assert(app.count("args.map!(argument => argument.idup).array") == 1,
        "W16-R argv heap-copy owner changed");
    assert(app.count("private __gshared void delegate() g_webMainLoopFrame") == 1,
        "W16-R browser callback must have exactly one D-GC root");
    assert(app.count("static ulong webProbeInputFrame") == 1,
        "W16-R input receipt must be web-static, not main-stack state");
    assert(app.count("immutable bool eventAccepted = router.processEvent") == 1
        && app.indexOf("WEB-RUNNER-INPUT-ACK") >
           app.indexOf("immutable bool eventAccepted = router.processEvent"),
        "W16-R input receipt must follow the production router");
    assert(app.count("SDL_GL_GetCurrentContext()") >= 2,
        "W16-R live receipt must query the current production GL context");
    assert(app.count("consumedMouse.x == webProbeMouseX") == 1
        && app.indexOf("consumedMouse.x == webProbeMouseX") > app.indexOf("ImGui.NewFrame();"),
        "W16-R terminal receipt must read ImGui's consumed input after NewFrame");
    assert(app.count("source=imgui-io generation=new-frame") == 1,
        "W16-R live browser receipt must name its downstream consumer");

    assert(runner.count("for mode in normal spreset") == 1,
        "W16-R must run normal and stack-reset modes exactly once");
    assert(runner.count("check_web_frame_pixels.py") == 1,
        "W16-R must reuse the W16-L visual oracle");
    assert(runner.indexOf("--no-http") >= 0 && runner.indexOf("--http-port") < 0,
        "W16-R is portless and must not invent browser HTTP control");
    const cdp = repoFile("tools/web_cdp_capture.mjs");
    assert(runner.indexOf("MouseEvent('mousemove'") < 0
        && cdp.indexOf("Input.dispatchMouseEvent") >= 0,
        "W16-R must drive Chromium input through CDP, not a synthetic DOM event");
    assert(runner.indexOf("MutationObserver") < 0,
        "W16-R handshake must not depend on DOM observer scheduling");
    assert(runner.indexOf("web_cdp_capture.mjs") >= 0
        && runner.indexOf("--dump-dom") < 0
        && runner.indexOf("--virtual-time-budget") < 0,
        "W16-R capture must wait for its production receipt through CDP");
    assert(runner.indexOf("VIBE3D_WEB_OPTIMIZED=1") >= 0
        && runner.indexOf("build=O2") >= 0,
        "W16-R permanent runner must build and report optimized artifacts");
    assert(reset.count("js.count(anchor) != 1 or js.count(catch) != 1") == 1,
        "W16-R stack-reset injection must reject generator drift");
    assert(reset.count("stackRestore(__vibeMainStack)") == 1,
        "W16-R reset lane must restore the pre-main stack pointer");

    // W16-E extends the same live runner after W16-R's mouse-motion witness;
    // it must not replace that downstream test with a self-authored event.
    assert(cdp.indexOf("W16-E deliberately starts after W16-R") >= 0
        && cdp.count("Input.dispatchKeyEvent") == 2
        && cdp.count("type: 'mousePressed'") == 1
        && cdp.count("type: 'mouseReleased'") == 1
        && cdp.count("type: 'mouseWheel'") == 1,
        "W16-E browser input families escaped the native CDP lane");
    assert(runner.count("WEB-WINDOW-READY") == 1
        && runner.count("WEB-WINDOW-INPUT") == 1
        && runner.indexOf("window=640x480 framebuffer=640x480") >= 0,
        "W16-E runner must pin logical and drawable resize results");
    assert(app.count("WEB-WINDOW-INPUT source=sdl generation=router") == 1
        && app.count("completeWindowInputMask") == 2,
        "W16-E receipt must follow the production SDL/router seam");
    assert(app.indexOf("version (web) return;") >= 0
        && app.indexOf("version (web) return;") < app.indexOf("SDL_SetWindowIcon(window, surf)"),
        "W16-E web icon path must remain page-owned and skip SDL's no-op hook");
}
