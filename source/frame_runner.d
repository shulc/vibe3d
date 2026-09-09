module frame_runner;

import ai.element_candidates : publishElementCandidates;
import bg_gpu_cache : BgGpuCache;
import bindbc.opengl : GL_COLOR_BUFFER_BIT, GL_DEPTH_BUFFER_BIT,
    glClear, glClearColor, glFlush, glViewport;
import bindbc.sdl : SDL_Delay, SDL_GL_SwapWindow, SDL_Window;
import document : Document;
import edit_session : EditSession;
import editmode : EditMode;
import editor_app : OverlayMode;
import eventlog : queryMouse;
import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
import input_frame_state : InputFrameState;
import ImGui = d_imgui;
import imgui_impl_opengl3 : ImGui_ImplOpenGL3_RenderDrawData;
import math : Viewport;
import perf_probe : g_fc, g_frames, Phase;
import tool : Tool;
import ui.viewport_render : ViewportSceneRenderer, SceneInputs,
    SceneViewInputs, SceneDisplayInputs, SceneGpuInputs, ToolOverlayInputs;

/// The already-resolved platform action at the end of a frame.
enum FramePresentMode {
    present,
    hiddenTest,
}

/// Resolve process flags before entering the frame-tail boundary.
FramePresentMode resolveFramePresentMode(bool testMode, bool perfMode,
                                         bool visibleTest)
    pure nothrow @nogc @safe
{
    return testMode && !perfMode && !visibleTest
        ? FramePresentMode.hiddenTest
        : FramePresentMode.present;
}

/// Test-visible names for events emitted by the exact low-level wrappers used
/// by finishFrame. The trace is absent from non-unittest builds.
enum FrameFinishEvent {
    clearColor,
    clear,
    render,
    viewport,
    submit,
    timingProbeEnd,
    workProbeEnd,
    swap,
    flush,
    delay,
}

version (unittest) version = FrameFinishTraceEnabled;
version (FrameFinishWitness) version = FrameFinishTraceEnabled;

version (FrameFinishTraceEnabled) {
    struct FrameFinishTrace {
        FrameFinishEvent[] events;
        int renderVertices;
        uint delayMs;

        void reset() {
            events.length = 0;
            renderVertices = 0;
            delayMs = 0;
        }

        size_t count(FrameFinishEvent event) const {
            size_t result;
            foreach (seen; events) if (seen == event) ++result;
            return result;
        }
    }

    __gshared FrameFinishTrace g_frameFinishTrace;
}

private pragma(inline, true) void noteFinishEvent(FrameFinishEvent event,
                                                  int renderVertices = 0,
                                                  uint delayMs = 0)
{
    version (FrameFinishTraceEnabled) {
        g_frameFinishTrace.events ~= event;
        if (event == FrameFinishEvent.render)
            g_frameFinishTrace.renderVertices = renderVertices;
        if (event == FrameFinishEvent.delay)
            g_frameFinishTrace.delayMs = delayMs;
    }
}

private void clearDefaultFramebuffer() {
    glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
    noteFinishEvent(FrameFinishEvent.clearColor);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    noteFinishEvent(FrameFinishEvent.clear);
}

private void finishRenderImGui() {
    ImGui.Render();
    int renderVertices;
    version (FrameFinishTraceEnabled) {
        // cimgui keeps ImDrawData opaque on the D side. These are its first
        // four fields in the pinned ABI; only the unittest trace reads them.
        struct ImDrawDataPrefix {
            bool valid;
            int commandLists;
            int totalIndices;
            int totalVertices;
        }
        auto drawData = ImGui.GetDrawData();
        if (drawData !is null)
            renderVertices = (cast(ImDrawDataPrefix*)drawData).totalVertices;
    }
    noteFinishEvent(FrameFinishEvent.render, renderVertices);
}

private void finishFullViewport(int framebufferWidth, int framebufferHeight) {
    glViewport(0, 0, framebufferWidth, framebufferHeight);
    noteFinishEvent(FrameFinishEvent.viewport);
}

private void finishSubmitImGui() {
    ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());
    noteFinishEvent(FrameFinishEvent.submit);
}

private void finishTimingProbe() {
    g_frames.endFrame();
    noteFinishEvent(FrameFinishEvent.timingProbeEnd);
}

private void finishWorkProbe() {
    g_fc.endFrame();
    noteFinishEvent(FrameFinishEvent.workProbeEnd);
}

private void finishSwap(SDL_Window* window) {
    SDL_GL_SwapWindow(window);
    noteFinishEvent(FrameFinishEvent.swap);
}

private void finishFlush() {
    glFlush();
    noteFinishEvent(FrameFinishEvent.flush);
}

private void finishDelay(uint milliseconds) {
    SDL_Delay(milliseconds);
    noteFinishEvent(FrameFinishEvent.delay, 0, milliseconds);
}

/// Hover gates consumed by the later scene phase of the same frame.
struct HoverDrawState {
    bool vertex;
    bool edge;
    bool face;
}

/// Owns the covered frame phases extracted from main() (task 4630).
/// The outer loop remains the ordering root until events and present have
/// witnesses; tick therefore starts at the first covered seam, picking/hover.
final class FrameRunner {
    private InputFrameState ifs_;
    private BgGpuCache bgGpuCache_;
    private ViewportSceneRenderer sceneRenderer_;

    this(InputFrameState ifs) {
        assert(ifs !is null);
        ifs_ = ifs;
        bgGpuCache_ = new BgGpuCache;
        sceneRenderer_ = new ViewportSceneRenderer;
    }

    /// Reconcile frame-owned GL residency before any dirty-gated cell draw.
    void reconcileBackgroundGpu(ref Document document) {
        bgGpuCache_.reconcile(document);
    }

    /// Tear down frame-owned GL resources while the context is still live.
    void shutdown() {
        bgGpuCache_.shutdown();
    }

    /// Task 4720: tick explicit observers at the pre-side-panel boundary.
    /// This preserves frame order while removing panel ownership; the closed
    /// properties witness is tests/test_tool_sticky.d.
    void tickParameterEvaluation(EditSession session) {
        session.tickParameterEvaluation();
    }

    void tick(ref Viewport vp, bool doingCameraDrag) {
        ifs_.pickVertices(vp, doingCameraDrag);
        ifs_.pickEdges(vp, doingCameraDrag);
        ifs_.pickFaces(vp, doingCameraDrag);

        // Item hover is last and independent of the remembered geometry mode.
        ifs_.pickItems(vp, doingCameraDrag);
    }

    HoverDrawState resolveHover(Tool activeTool, EditMode editMode) {
        const int pickedVertex = ifs_.hoveredVertex;
        const int pickedEdge = ifs_.hoveredEdge;
        const int pickedFace = ifs_.hoveredFace;

        // A multi-type tool publishes exactly one highlighted candidate.
        if (activeTool !is null) {
            if (ifs_.hoveredVertex >= 0) {
                ifs_.hoveredEdge = -1;
                ifs_.hoveredFace = -1;
            } else if (ifs_.hoveredEdge >= 0) {
                ifs_.hoveredFace = -1;
            }
        }

        int mouseX, mouseY;
        queryMouse(mouseX, mouseY);
        publishElementCandidates(mouseX, mouseY,
                                 pickedVertex, pickedEdge, pickedFace);

        // Publish the resolved source-of-truth hover for tool consumers.
        g_hoveredVertex = ifs_.hoveredVertex;
        g_hoveredEdge = ifs_.hoveredEdge;
        g_hoveredFace = ifs_.hoveredFace;

        HoverDrawState result;
        result.vertex = editMode == EditMode.Vertices
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Vertices));
        result.edge = editMode == EditMode.Edges
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Edges));
        result.face = editMode == EditMode.Polygons
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Polygons));
        return result;
    }

    void drawScene(SceneInputs scene, SceneViewInputs view,
                   SceneDisplayInputs display, SceneGpuInputs gpu,
                   ToolOverlayInputs overlays, OverlayMode overlayMode) {
        sceneRenderer_.draw(scene, view, display, gpu,
                            bgGpuCache_.drawCache(), overlays, overlayMode);
    }

    /// Complete the default-framebuffer tail after all overlays were authored.
    /// ImGui snapshot/submission and both probe ends precede the resolved
    /// present action; the hidden-test delay stays outside totalNs.
    void finishFrame(SDL_Window* window, int framebufferWidth,
                     int framebufferHeight, FramePresentMode presentMode) {
        clearDefaultFramebuffer();
        {
            auto zFramesUi = g_frames.phase(Phase.ui);
            finishRenderImGui();
            finishFullViewport(framebufferWidth, framebufferHeight);
            finishSubmitImGui();
        }

        finishTimingProbe();
        finishWorkProbe();

        final switch (presentMode) {
            case FramePresentMode.present:
                finishSwap(window);
                break;
            case FramePresentMode.hiddenTest:
                finishFlush();
                finishDelay(4);
                break;
        }
    }

}
