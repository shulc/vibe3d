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

    // Cached `name()` per registered command id — populated once at app
    // startup alongside `commandModes`. Exposed on `GET /api/registry` so
    // the button-action resolver test can assert every command's `name()`
    // resolves back to a live registration key (the replay-string
    // invariant — see doc/registry_name_integrity_plan.md). Tools are
    // deliberately excluded: a tool's `name()` is a human display string
    // by design (e.g. `move` → "Transform"), not a key.
    string[string] commandNames;

    /// Walk every registered factory once and snapshot its
    /// `supportedModes()` into the cache. Call after all
    /// `commandFactories[*]` / `toolFactories[*]` assignments.
    void cacheSupportedModes() {
        foreach (id, factory; commandFactories) {
            auto cmd = factory();
            commandModes[id] = cmd.supportedModes().dup;
            commandNames[id] = cmd.name;
            // Fail fast on any command whose name() does not resolve back to
            // a registered command key — a dead replay string in the making
            // (history/scripting re-dispatch cmd.name through
            // commandFactories). This is "resolves-back", NOT "name()==id":
            // alias keys (file.open, file.import.*, file.export.*) legitimately
            // share one command class + name() with a DIFFERENT key, and that
            // is fine as long as the name() itself is some live key. Scoped to
            // commandFactories ONLY — tool name() is a display string by
            // design and is not part of this contract.
            if (cmd.name !in commandFactories)
                throw new Exception("registry: command '" ~ id ~ "' name() '"
                    ~ cmd.name ~ "' is not a registered command key");
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

// ---------------------------------------------------------------------------
// Unit tests: the resolves-back gate in cacheSupportedModes() (command-scoped
// only — see doc/registry_name_integrity_plan.md).
// ---------------------------------------------------------------------------
version (unittest) {
    private final class _RegTestCmd : Command {
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        private string _name;
        this(string name) {
            super(&_mesh, _view, EditMode.Vertices);
            _name = name;
        }
        override string name() const { return _name; }
    }
}

// (a) A consistent command key/alias pair — an alias key's factory name()
// resolves to the OTHER (primary) key, which is itself registered. No throw.
unittest {
    Registry reg;
    reg.commandFactories["thing.primary"] = () => cast(Command) new _RegTestCmd("thing.primary");
    reg.commandFactories["thing.alias"]   = () => cast(Command) new _RegTestCmd("thing.primary");
    reg.cacheSupportedModes();  // must not throw
    assert(reg.commandNames["thing.primary"] == "thing.primary");
    assert(reg.commandNames["thing.alias"]   == "thing.primary");
}

// (b) A drifting command entry — name() is not any registered key. Throws.
unittest {
    Registry reg;
    reg.commandFactories["thing.drifted"] = () => cast(Command) new _RegTestCmd("Thing Drifted");
    bool threw = false;
    try {
        reg.cacheSupportedModes();
    } catch (Exception e) {
        threw = true;
    }
    assert(threw, "expected cacheSupportedModes() to throw on a drifting command name()");
}
