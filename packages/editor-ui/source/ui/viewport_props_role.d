module ui.viewport_props_role;

import display_state : ViewportDisplay;
import viewport : LayoutPreset, ViewportManager;

alias ViewportCommandDispatch = void delegate(string, string);

/// The panel receives one value projection of the active viewport cell per
/// draw. The role retains only the ViewportManager reference and never exposes
/// it, so every projection resolves the current activeId live while mutations
/// remain available only through ViewportCommandDispatch (task 5850; evidence:
/// viewport_props_roles_test).
struct ViewportPropertiesReadRole {
private:
    ViewportManager manager_;

public:
    @disable this();

    this(ViewportManager manager) {
        assert(manager !is null,
            "viewport properties read role requires a ViewportManager");
        manager_ = manager;
    }

    ViewportPropertiesProjection project() {
        const activeId = manager_.activeId;
        assert(activeId >= 0 && activeId < manager_.cellCount,
            "viewport properties active cell is outside the live layout");
        auto cell = manager_.views[activeId];

        ViewportPropertiesProjection result;
        result.activeId = activeId;
        result.layout = manager_.layout;
        result.cellCount = manager_.cellCount;
        result.indCenter = cell.indCenter;
        result.indScale = cell.indScale;
        result.indRotate = cell.indRotate;
        result.display = cell.display;
        result.masterId = cell.masterId;
        return result;
    }

}

/// Copy-only read surface consumed by one panel draw. It carries no manager,
/// cell, camera, GL object or mutation method.
struct ViewportPropertiesProjection {
    int activeId;
    LayoutPreset layout;
    int cellCount;
    bool indCenter;
    bool indScale;
    bool indRotate;
    ViewportDisplay display;
    int masterId;
}
