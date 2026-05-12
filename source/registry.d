module registry;

import mesh;
import view;
import editmode;
import shader;
import tool;
import command;

// ---------------------------------------------------------------------------
// AppContext — raw references to per-app state shared by tools and commands
// ---------------------------------------------------------------------------

struct AppContext {
    Mesh*      mesh;
    GpuMesh*   gpu;
    EditMode*  editMode;
    View       view;       // class — reference semantics
    LitShader  litShader;  // class — reference semantics
}

// ---------------------------------------------------------------------------
// Registry — factory dictionaries for tools and commands
// ---------------------------------------------------------------------------

alias ToolFactory    = Tool    delegate();
alias CommandFactory = Command delegate();

alias PreActivate = void delegate();

struct Registry {
    ToolFactory[string]    toolFactories;
    CommandFactory[string] commandFactories;

    // Per-tool side-effect hook run RIGHT BEFORE the factory in the
    // user-driven activation path (NOT in `cacheSupportedModes`, so
    // enumerating every factory at startup doesn't mutate global
    // state). Populated for tool presets in `registerToolPresets`,
    // which want to push pipe-stage attrs (e.g. `actionCenter.mode =
    // element` for `move.element`) when the preset is actually
    // selected.
    PreActivate[string] preActivate;

    // Cached `supportedModes()` per command/tool id — populated once
    // at app startup via `cacheSupportedModes()` after all factory
    // assignments. The button-rendering side reads this to auto-
    // disable rows whose target action doesn't accept the current
    // edit mode (e.g. `mesh.subdivide` greyed out in Vertices/Edges).
    //
    // Missing-key lookup ⇒ "all modes supported" (no restriction).
    EditMode[][string] commandModes;
    EditMode[][string] toolModes;

    /// Walk every registered factory once and snapshot its
    /// `supportedModes()` into the cache. Call after all
    /// `commandFactories[*]` / `toolFactories[*]` assignments.
    void cacheSupportedModes() {
        foreach (id, factory; commandFactories) {
            auto cmd = factory();
            commandModes[id] = cmd.supportedModes().dup;
        }
        foreach (id, factory; toolFactories) {
            auto tool = factory();
            toolModes[id] = tool.supportedModes().dup;
        }
    }

    /// True when `actionId` is registered AND its `supportedModes()`
    /// excludes `currentMode`. Used by the side-panel button render
    /// to auto-grey out rows for the current edit mode. Returns
    /// false for unknown ids (no restriction) and for "all modes"
    /// commands.
    bool isModeBlocked(string kind, string actionId, EditMode currentMode) const {
        const(EditMode)[] modes;
        if (kind == "command") {
            if (auto m = actionId in commandModes) modes = *m;
            else return false;
        } else if (kind == "tool") {
            if (auto m = actionId in toolModes) modes = *m;
            else return false;
        } else {
            return false;
        }
        foreach (m; modes) if (m == currentMode) return false;
        return true;
    }
}
