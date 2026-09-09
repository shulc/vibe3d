// The real default-framebuffer tail on a real offscreen GL context (task 0782).
// Each table row calls FrameRunner.finishFrame itself. The trace is emitted by
// the same wrappers that perform the low-level calls; the foreground rectangle
// and its readback keep the ordering checks from passing over an empty draw.
module tests.unit.frame_runner_finish_test;

import bindbc.opengl;
import bindbc.sdl;
import core.time : MonoTime;
import d_imgui.imgui_h : ImVec2, IM_COL32;
import frame_runner : FrameFinishEvent, FramePresentMode, FrameRunner,
    g_frameFinishTrace, resolveFramePresentMode;
import imgui_impl_opengl3 : ImGui_ImplOpenGL3_Init,
    ImGui_ImplOpenGL3_NewFrame, ImGui_ImplOpenGL3_Shutdown;
import imgui_impl_sdl2 : ImGui_ImplSDL2_Init, ImGui_ImplSDL2_NewFrame,
    ImGui_ImplSDL2_Shutdown;
import input_frame_state : InputFrameState;
import ImGui = d_imgui;
import perf_probe : DrawPass, g_fc, g_frames;
import std.conv : to;
import std.format : format;
import std.process : environment;
import std.stdio : writefln;

private struct ModeCase {
    string name;
    bool testMode;
    bool perfMode;
    bool visibleTest;
    size_t swaps;
    size_t flushes;
    uint delayMs;
}

private ptrdiff_t eventIndex(const(FrameFinishEvent)[] events,
                             FrameFinishEvent sought) {
    foreach (i, event; events)
        if (event == sought) return cast(ptrdiff_t)i;
    return -1;
}

private int overlayPixelPopulation(int width, int height) {
    glReadBuffer(GL_BACK);
    int result;
    foreach (y; 12 .. 32) foreach (x; 12 .. 36) {
        ubyte[4] rgba;
        glReadPixels(x, height - 1 - y, 1, 1,
                     GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
        if (rgba[0] > 180 && rgba[2] > 180 && rgba[1] < 100) ++result;
    }
    return result;
}

void runFrameRunnerFinishWitness() {
    enum width = 96;
    enum height = 64;

    const hadDriver = "SDL_VIDEODRIVER" in environment;
    const oldDriver = environment.get("SDL_VIDEODRIVER", "");
    environment["SDL_VIDEODRIVER"] = "offscreen";
    scope(exit) {
        if (hadDriver) environment["SDL_VIDEODRIVER"] = oldDriver;
        else environment.remove("SDL_VIDEODRIVER");
    }

    assert(loadSDL() == sdlSupport, "frame finish rig could not load SDL");
    assert(SDL_Init(SDL_INIT_VIDEO) == 0,
        "frame finish rig could not initialize SDL: " ~ SDL_GetError().to!string);
    scope(exit) SDL_Quit();

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    auto window = SDL_CreateWindow("frame-finish-witness",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, width, height,
        SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    assert(window !is null,
        "frame finish rig could not create an offscreen window: "
        ~ SDL_GetError().to!string);
    scope(exit) SDL_DestroyWindow(window);

    auto context = SDL_GL_CreateContext(window);
    assert(context !is null,
        "frame finish rig could not create an OpenGL context: "
        ~ SDL_GetError().to!string);
    scope(exit) SDL_GL_DeleteContext(context);
    SDL_GL_SetSwapInterval(0);
    assert(loadOpenGL() >= glSupport,
        "frame finish rig could not load OpenGL 3.3");

    auto imguiContext = ImGui.CreateContext();
    assert(imguiContext !is null, "frame finish rig could not create ImGui");
    scope(exit) ImGui.DestroyContext(imguiContext);
    assert(ImGui_ImplSDL2_Init(window),
        "frame finish rig could not initialize the ImGui SDL backend");
    scope(exit) ImGui_ImplSDL2_Shutdown();
    assert(ImGui_ImplOpenGL3_Init("#version 330 core"),
        "frame finish rig could not initialize the ImGui GL backend");
    scope(exit) ImGui_ImplOpenGL3_Shutdown();

    auto runner = new FrameRunner(new InputFrameState);
    immutable ModeCase[] cases = [
        ModeCase("normal",       false, false, false, 1, 0, 0),
        ModeCase("hidden test",  true,  false, false, 0, 1, 4),
        ModeCase("test+perf",    true,  true,  false, 1, 0, 0),
        ModeCase("test+visible", true,  false, true,  1, 0, 0),
    ];

    foreach (row; cases) {
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();
        auto overlay = ImGui.GetForegroundDrawList();
        overlay.AddRectFilled(ImVec2(12, 12), ImVec2(36, 32),
                              IM_COL32(255, 0, 255, 255));

        // A cell-sized sentinel is what makes losing the explicit full-frame
        // viewport observable after the backend restores prior GL state.
        glViewport(3, 4, 17, 19);
        g_frames.beginFrame();
        g_fc.reset();
        g_fc.beginFrame();
        g_fc.draw(DrawPass.faces, 3);
        g_frameFinishTrace.reset();

        const mode = resolveFramePresentMode(
            row.testMode, row.perfMode, row.visibleTest);
        runner.finishFrame(window, width, height, mode);

        const events = g_frameFinishTrace.events;
        size_t lowLevelCalls;
        foreach (event; events) {
            if (event == FrameFinishEvent.clearColor
                || event == FrameFinishEvent.clear
                || event == FrameFinishEvent.render
                || event == FrameFinishEvent.viewport
                || event == FrameFinishEvent.submit
                || event == FrameFinishEvent.swap
                || event == FrameFinishEvent.flush
                || event == FrameFinishEvent.delay)
                ++lowLevelCalls;
        }
        assert(lowLevelCalls >= 6,
            format("FRAME FINISH CALL FLOOR [%s]: only %d low-level calls: %s",
                   row.name, lowLevelCalls, events));
        assert(g_frameFinishTrace.renderVertices >= 4,
            format("FRAME OVERLAY DRAW FLOOR [%s]: ImGui.Render produced only "
                   ~ "%d vertices after a real foreground overlay draw",
                   row.name, g_frameFinishTrace.renderVertices));

        const swaps = g_frameFinishTrace.count(FrameFinishEvent.swap);
        const flushes = g_frameFinishTrace.count(FrameFinishEvent.flush);
        const delays = g_frameFinishTrace.count(FrameFinishEvent.delay);
        assert(swaps == row.swaps && flushes == row.flushes
            && (delays == 0 ? 0 : g_frameFinishTrace.delayMs) == row.delayMs,
            format("PRESENT MODE [%s]: swap=%d flush=%d delayCalls=%d "
                   ~ "delayMs=%d; expected swap=%d flush=%d delayMs=%d",
                   row.name, swaps, flushes, delays,
                   g_frameFinishTrace.delayMs, row.swaps, row.flushes,
                   row.delayMs));
        assert(delays == (row.delayMs == 0 ? 0 : 1),
            format("PRESENT MODE [%s]: delay call count=%d, expected %d",
                   row.name, delays, row.delayMs == 0 ? 0 : 1));

        const presentEvent = row.swaps
            ? FrameFinishEvent.swap : FrameFinishEvent.flush;
        const presentAt = eventIndex(events, presentEvent);
        const timingAt = eventIndex(events, FrameFinishEvent.timingProbeEnd);
        const workAt = eventIndex(events, FrameFinishEvent.workProbeEnd);
        assert(presentAt >= 0 && timingAt >= 0 && workAt >= 0,
            format("FRAME FINISH ORDER FLOOR [%s]: missing probe/present event: %s",
                   row.name, events));
        assert(timingAt < presentAt && workAt < presentAt,
            format("CPU SUBMISSION BOUNDARY [%s]: both endFrame calls must "
                   ~ "precede present/flush so totalNs excludes present, "
                   ~ "vsync and delay; events=%s", row.name, events));
        if (row.delayMs) {
            const delayAt = eventIndex(events, FrameFinishEvent.delay);
            assert(presentAt < delayAt,
                format("HIDDEN TEST ORDER: flush must precede the 4 ms delay; "
                       ~ "events=%s", events));
        }

        int[4] viewport;
        glGetIntegerv(GL_VIEWPORT, viewport.ptr);
        assert(viewport == [0, 0, width, height],
            format("FULL-FRAME VIEWPORT [%s]: finish left (%d,%d %dx%d), "
                   ~ "expected (0,0 %dx%d) before/after real ImGui submit",
                   row.name, viewport[0], viewport[1], viewport[2], viewport[3],
                   width, height));
        assert(g_fc.totals.seq == 1 && g_fc.last.drawCalls == 1,
            format("WORK PROBE COMMIT [%s]: seq=%d drawCalls=%d; expected "
                   ~ "one populated frame before present", row.name,
                   g_fc.totals.seq, g_fc.last.drawCalls));

        if (mode == FramePresentMode.hiddenTest) {
            const overlayPixels = overlayPixelPopulation(width, height);
            assert(overlayPixels >= 200,
                format("FRAME OVERLAY PIXELS: only %d magenta pixels from "
                       ~ "the real foreground draw reached the default framebuffer",
                       overlayPixels));
        }

        writefln("[frame-finish] %s swap=%d flush=%d delay=%dms "
                 ~ "drawVerts=%d calls=%d", row.name, swaps, flushes,
                 row.delayMs, g_frameFinishTrace.renderVertices, lowLevelCalls);
    }
}

unittest {
    runFrameRunnerFinishWitness();
}
