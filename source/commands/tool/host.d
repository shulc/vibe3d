module commands.tool.host;

import tool : Tool;

// ---------------------------------------------------------------------------
// ToolHost — delegate-based bridge between tool.* commands and the App's
// activeTool state.
//
// Constructed in app.d setup with closures over activeTool/activeToolId/
// setActiveTool. The four delegates mirror the four operations the tool.*
// command family needs without creating a circular import between app.d and
// the command modules.
// ---------------------------------------------------------------------------
struct ToolHost {
    /// Returns the currently active tool (may be null).
    Tool   delegate()       getActiveTool;

    /// Returns the string id of the currently active tool (e.g. "bevel").
    string delegate()       getActiveToolId;

    /// Look up toolId in the registry, create via factory, and call
    /// setActiveTool(). Throws Exception if toolId is unknown.
    void   delegate(string) activate;

    /// Deactivate the current tool (setActiveTool(null)).
    void   delegate()       deactivate;
}
