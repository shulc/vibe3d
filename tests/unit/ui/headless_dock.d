module tests.unit.ui.headless_dock;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import ui.dock_drag : viewportOverlayWindowFlags;
import ui.imgui_window_class : ImGuiWindowClassStorage;

private extern(C) nothrow @nogc {
    void ImGuiIO_AddMousePosEvent(void* self, float x, float y);
    void ImGuiIO_AddMouseButtonEvent(void* self, int button, bool down);
    void ImGuiIO_AddFocusEvent(void* self, bool focused);
    ImGuiID igGetWindowDockID();
    ImVec2 igGetWindowPos();
    ImVec2 igGetWindowSize();
    void igSetNextWindowClass(const(void)* self);
}

private struct IoHeader {
    int configFlags;
    int backendFlags;
    float displayW;
    float displayH;
}

private enum int backendRendererHasTextures = 1 << 4;
private enum int dockingEnable = 1 << 7;

struct DockRect {
    ImVec2 min;
    ImVec2 max;

    ImVec2 center() const {
        return ImVec2((min.x + max.x) * 0.5f,
                      (min.y + max.y) * 0.5f);
    }
}

/// Headless multi-window scene for driving real ImGui docking gestures.
struct HeadlessDockScene {
    private ImGuiContext* ctx;
    private void* io;
    private bool seeded;
    private bool extraTop;
    private int viewportClassBit;
    private ImGuiID dockspaceId;

    ImGuiID tabDockId;
    ImGuiID mateDockId;
    ImGuiID viewportHostDockId;
    DockRect rightRect;
    DockRect viewportRect;
    DockRect tabRect;
    int frames;

    @disable this(this);

    private void submitWindow(string name, ref DockRect rect, int flags = 0) {
        ImGui.Begin(name, null, flags);
        rect.min = igGetWindowPos();
        const size = igGetWindowSize();
        rect.max = ImVec2(rect.min.x + size.x, rect.min.y + size.y);
        if (name == "Tab bar") tabDockId = igGetWindowDockID();
        if (name == "Top mate") mateDockId = igGetWindowDockID();
        if (name == "ViewportHost") viewportHostDockId = igGetWindowDockID();
        ImGui.End();
    }

    void frame() {
        ImGui.NewFrame();
        const display = ImGui.GetIO().DisplaySize;
        ImGui.SetNextWindowPos(ImVec2(0, 0));
        ImGui.SetNextWindowSize(display);
        immutable int rootFlags = ImGuiWindowFlags.NoDocking
            | ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoCollapse
            | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove
            | ImGuiWindowFlags.NoBringToFrontOnFocus
            | ImGuiWindowFlags.NoNavFocus | ImGuiWindowFlags.NoBackground;
        ImGui.Begin("##DockSpaceHost", null, rootFlags);
        dockspaceId = ImGui.GetID("MainDockSpace");
        ImGui.DockSpace(dockspaceId, ImVec2(0, 0),
            ImGuiDockNodeFlags.PassthruCentralNode
            | ImGuiDockNodeFlags.AutoHideTabBar);

        if (!seeded) {
            seeded = true;
            ImGui.DockBuilderRemoveNode(dockspaceId);
            ImGui.DockBuilderAddNode(dockspaceId, 0);
            ImGui.DockBuilderSetNodeSize(dockspaceId, display);
            ImGuiID leftId, rest, rightId, centerCol, topId, midCol;
            ImGuiID bottomId, viewportId;
            ImGui.DockBuilderSplitNode(dockspaceId, ImGuiDir.Left, 0.12f,
                                       &leftId, &rest);
            ImGui.DockBuilderSplitNode(rest, ImGuiDir.Right, 0.22f,
                                       &rightId, &centerCol);
            ImGui.DockBuilderSplitNode(centerCol, ImGuiDir.Up, 0.04f,
                                       &topId, &midCol);
            ImGui.DockBuilderSplitNode(midCol, ImGuiDir.Down, 0.05f,
                                       &bottomId, &viewportId);
            ImGui.DockBuilderDockWindow("Mesh Info", leftId);
            ImGui.DockBuilderDockWindow("Right panel", rightId);
            ImGui.DockBuilderDockWindow("Tab bar", topId);
            ImGui.DockBuilderDockWindow("Top mate", topId);
            if (extraTop) ImGui.DockBuilderDockWindow("Top mate2", topId);
            ImGui.DockBuilderDockWindow("Status line", bottomId);
            ImGui.DockBuilderDockWindow("ViewportHost", viewportId);
            ImGui.DockBuilderFinish(dockspaceId);
        }
        ImGui.End();

        DockRect ignored;
        submitWindow("Mesh Info", ignored);
        submitWindow("Right panel", rightRect);
        submitWindow("Tab bar", tabRect);
        submitWindow("Top mate", ignored);
        if (extraTop) submitWindow("Top mate2", ignored);
        submitWindow("Status line", ignored);

        ImGuiWindowClassStorage wc = void;
        wc.bytes[] = 0;
        wc.fields.ParentViewportId = 0xFFFF_FFFFu;
        wc.fields.DockingAllowUnclassed = true;
        wc.fields.DockNodeFlagsOverrideSet = viewportClassBit;
        igSetNextWindowClass(&wc);
        immutable int hostFlags = ImGuiWindowFlags.NoScrollbar
            | ImGuiWindowFlags.NoScrollWithMouse
            | ImGuiWindowFlags.NoBackground
            | ImGuiWindowFlags.NoMouseInputs;
        submitWindow("ViewportHost", viewportRect, hostFlags);

        immutable int overlayBase = ImGuiWindowFlags.NoScrollbar
            | ImGuiWindowFlags.NoScrollWithMouse | ImGuiWindowFlags.NoTitleBar
            | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove
            | ImGuiWindowFlags.NoCollapse | ImGuiWindowFlags.NoDocking
            | ImGuiWindowFlags.NoSavedSettings;
        ImGui.SetNextWindowPos(viewportRect.min);
        ImGui.SetNextWindowSize(ImVec2(viewportRect.max.x - viewportRect.min.x,
                                      viewportRect.max.y - viewportRect.min.y));
        ImGui.Begin("Viewport##0", null,
            viewportOverlayWindowFlags(overlayBase, windowDockDragActive()));
        ImGui.End();
        ImGui.Render();
        ++frames;
    }

    bool windowDockDragActive() const {
        import ui.dock_drag : windowDockDragActive;
        return windowDockDragActive();
    }

    void moveTo(ImVec2 p, int settle = 2) {
        ImGuiIO_AddMousePosEvent(io, p.x, p.y);
        foreach (_; 0 .. settle) frame();
    }

    void pressAt(ImVec2 p) {
        moveTo(p);
        ImGuiIO_AddMouseButtonEvent(io, 0, true);
        frame();
        frame();
    }

    void release() {
        ImGuiIO_AddMouseButtonEvent(io, 0, false);
        foreach (_; 0 .. 4) frame();
    }

    void dragTo(ImVec2 from, ImVec2 to, int steps = 12) {
        pressAt(from);
        foreach (i; 1 .. steps + 1) {
            moveTo(ImVec2(from.x + (to.x - from.x) * i / steps,
                          from.y + (to.y - from.y) * i / steps));
        }
        release();
    }

    void close() {
        if (ctx !is null) {
            ImGui.DestroyContext(ctx);
            ctx = null;
        }
    }
}

HeadlessDockScene openScene(int viewportClassBit, bool extraTop = false) {
    HeadlessDockScene scene;
    scene.viewportClassBit = viewportClassBit;
    scene.extraTop = extraTop;
    scene.ctx = ImGui.CreateContext();
    scene.io = cast(void*)&ImGui.GetIO();
    auto header = cast(IoHeader*)scene.io;
    header.displayW = 1280;
    header.displayH = 720;
    header.backendFlags |= backendRendererHasTextures;
    header.configFlags |= dockingEnable;
    enum int layoutProbeBit = 1 << 30;
    header.configFlags |= layoutProbeBit;
    assert((ImGui.GetIO().ConfigFlags & layoutProbeBit) != 0,
        "6245 headless dock: ImGuiIO ConfigFlags prefix moved");
    header.configFlags &= ~layoutProbeBit;
    assert(ImGui.GetIO().DisplaySize.x == 1280
        && ImGui.GetIO().DisplaySize.y == 720,
        "6245 headless dock: ImGuiIO DisplaySize prefix moved");
    ImGui.GetIO().IniFilename = null;
    ImGui.StyleColorsDark();
    ImGuiIO_AddFocusEvent(scene.io, true);
    foreach (_; 0 .. 5) scene.frame();
    return scene;
}
