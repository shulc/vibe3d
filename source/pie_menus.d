module pie_menus;

// ---------------------------------------------------------------------------
// The loaded set of pie menus (task 1800).
//
// Kept here rather than on `EditorApp` because its readers are not all on the
// UI-panel path: the `ui.pie` command resolves an id (and may `apply()` off a
// route), the event pump resolves the aimed wedge, and the drawer walks the
// items. One `__gshared` array written once during startup and read-only after
// — the same shape `config/tool_presets.yaml` and friends already have.
// ---------------------------------------------------------------------------

import buttonset : PieMenu;

private __gshared PieMenu[] g_menus;

/// Install the parsed menus. Called once from startup, after `loadPies`.
void setPieMenus(PieMenu[] menus) {
    g_menus = menus;
}

/// All loaded menus — for startup id validation and diagnostics.
PieMenu[] pieMenus() {
    return g_menus;
}

/// Look one up by id; `null` when there is no such menu.
PieMenu* findPieMenu(string id) {
    foreach (ref m; g_menus)
        if (m.id == id) return &m;
    return null;
}
