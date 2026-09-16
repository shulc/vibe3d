module ui.dock_drag;

private extern(C) @nogc nothrow {
    void* igGetDragDropPayload();
    bool ImGuiPayload_IsDataType(void* self, const(char)* type);
}

/// Whether Dear ImGui is currently carrying a dock-window payload.
bool windowDockDragActive() nothrow @nogc {
    void* payload = igGetDragDropPayload();
    return payload !is null
        && ImGuiPayload_IsDataType(payload, "_IMWINDOW".ptr);
}

/// Make a viewport overlay transparent to hover resolution during a dock drag.
int viewportOverlayWindowFlags(int base, bool dockDragActive) pure nothrow @nogc {
    enum int noMouseInputs = 1 << 9; // ImGuiWindowFlags_NoMouseInputs
    return dockDragActive ? base | noMouseInputs : base;
}
