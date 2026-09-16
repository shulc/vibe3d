module ui.imgui_window_class;

/// D mirror of imgui 1.92.8's `ImGuiWindowClass`.
struct ImGuiWindowClassMirror {
    uint ClassId;
    uint ParentViewportId;
    uint FocusRouteParentWindowId;
    int ViewportFlagsOverrideSet;
    int ViewportFlagsOverrideClear;
    int TabItemFlagsOverrideSet;
    int DockNodeFlagsOverrideSet;
    bool DockingAlwaysTabBar;
    bool DockingAllowUnclassed;
    void* PlatformIconData;
}
