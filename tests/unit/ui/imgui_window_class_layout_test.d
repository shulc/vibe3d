module tests.unit.ui.imgui_window_class_layout_test;

import ui.imgui_window_class : ImGuiWindowClassMirror;

private extern(C) nothrow @nogc {
    ImGuiWindowClassMirror* ImGuiWindowClass_ImGuiWindowClass();
    void ImGuiWindowClass_destroy(ImGuiWindowClassMirror* self);
}

unittest {
    auto value = ImGuiWindowClass_ImGuiWindowClass();
    assert(value !is null,
        "6245 F4j population: cimgui returned no ImGuiWindowClass");
    scope(exit) ImGuiWindowClass_destroy(value);
    assert(value.ParentViewportId == 0xFFFF_FFFFu
        && value.DockingAllowUnclassed,
        "6245 F4j constructor defaults moved at offsets 4 or 29");
    assert(value.ClassId == 0 && value.FocusRouteParentWindowId == 0
        && value.ViewportFlagsOverrideSet == 0
        && value.ViewportFlagsOverrideClear == 0
        && value.TabItemFlagsOverrideSet == 0
        && value.DockNodeFlagsOverrideSet == 0
        && !value.DockingAlwaysTabBar && value.PlatformIconData is null,
        "6245 F4j zero-default fields moved, including offset 24");
}
