module ui.imgui_window_class;

/// Known prefix of imgui 1.92.8's `ImGuiWindowClass`.
/// The constructor-backed unit bracket verifies these field offsets against
/// the linked library; it does not claim that the C struct ends here.
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

/// Oversized storage passed to cimgui so an appended upstream field is read
/// from explicit zeroes instead of beyond a 40-byte D stack object.
enum size_t imGuiWindowClassStorageBytes = 256;

union ImGuiWindowClassStorage {
    ImGuiWindowClassMirror fields;
    ubyte[imGuiWindowClassStorageBytes] bytes;
}

/// Private imgui dock-node bit from imgui_internal.h:2006. Keeping the
/// production value public here makes the headless rule cell test that exact
/// value instead of a second literal.
enum int kDockFlagNoDockingOverMe = 1 << 20;
