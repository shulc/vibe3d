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

struct Registry {
    ToolFactory[string]    toolFactories;
    CommandFactory[string] commandFactories;
}
