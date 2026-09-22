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
    const router = repoFile("source/input_router.d");
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
    // Two downstream ImGui owners are intentional: W16-R's startup receipt
    // and task 7080's delayed liveness receipt.  Both sit after NewFrame.
    assert(app.count("consumedMouse.x == webProbeMouseX") == 2
        && app.indexOf("consumedMouse.x == webProbeMouseX") > app.indexOf("ImGui.NewFrame();"),
        "W16-R terminal receipt must read ImGui's consumed input after NewFrame");
    assert(app.count("source=imgui-io generation=new-frame") == 2,
        "both startup and delayed live receipts must name their downstream consumer");

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
        // W16-E owns the 10,10 window-family pair; W16-F adds one pair at
        // the measured production panel rect and waits between its halves.
        && cdp.count("type: 'mousePressed'") == 2
        && cdp.count("type: 'mouseReleased'") == 2
        && cdp.count("type: 'mouseWheel'") == 1,
        "W16-E browser input families escaped the native CDP lane");
    assert(runner.count("WEB-WINDOW-READY") == 1
        && runner.count("WEB-WINDOW-INPUT") == 1
        && runner.indexOf("window=640x480 framebuffer=640x480") >= 0,
        "W16-E runner must pin logical and drawable resize results");
    assert(app.count("WEB-WINDOW-INPUT source=router-consumers generation=production") == 1
        && app.count("router.webConsumedInputMask") == 4
        && app.count("router.winW, router.winH") == 1
        && app.count("router.fbW, router.fbH,\n"
                     ~ "                                layout.vpW, layout.vpH") == 1,
        "W16-E terminal receipt must read router-owned resize state");
    assert(router.count("webConsumedInputMask |= webKeyDownBit") == 1
        && router.count("webConsumedInputMask |= webKeyUpBit") == 1
        && router.count("webConsumedInputMask |= webTextBit") == 1
        && router.count("webConsumedInputMask |= webButtonDownBit") == 1
        && router.count("webConsumedInputMask |= webButtonUpBit") == 1
        && router.count("webConsumedInputMask |= webWheelBit") == 1
        && router.count("webConsumedInputMask |= webResizeBit") == 1,
        "W16-E each browser family needs one production-owned consumer witness");
    assert(router.count("case SDL_KEYDOWN:         handleKeyDown(ev.key);") == 1
        && router.count("case SDL_KEYUP:           handleKeyUp(ev.key);") == 1
        && router.count("handleMouseButtonDown(ev.button);") == 1
        && router.count("handleMouseButtonUp(ev.button);") == 1
        && router.count("case SDL_MOUSEWHEEL:      handleMouseWheel(ev.wheel);") == 1
        && router.count("immutable bool imguiAccepted = feedImGui(ev);") == 1
        && router.count("case SDL_WINDOWEVENT:     handleWindowEvent(ev.window);") == 1,
        "W16-E dispatch census must redden if a production consumer is bypassed");
    assert(router.count("applyWindowMetrics(layout, vpm, winW, winH);") == 1
        && runner.indexOf("layout=490x424") >= 0,
        "W16-E resize must reach layout and pin its downstream dimensions");
    assert(app.indexOf("version (web) return;") >= 0
        && app.indexOf("version (web) return;") < app.indexOf("SDL_SetWindowIcon(window, surf)"),
        "W16-E web icon path must remain page-owned and skip SDL's no-op hook");
}
