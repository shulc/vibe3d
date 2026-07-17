module commands.tool.host;

import tool         : Tool;
import edit_session : EditSession;

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

    /// Reset the named tool (empty string = the active tool) to its
    /// DECLARED defaults (constructor + preset-YAML, empty sticky) and clear
    /// its sticky entry. Discards any in-progress preview first (does not
    /// commit it) and rebuilds under a history suspend, so reset emits no
    /// undo entry. Returns whether a reset actually happened (false if the
    /// tool id is unknown / nothing to reset).
    bool   delegate(string) resetActiveTool;

    /// The session-protocol driver (task 0428) — commands route live-eval /
    /// session decisions through it instead of calling Tool hooks directly.
    /// Null (ToolHost.init) in bare-struct unit-test contexts, so callers
    /// keep the same defensive shape as the getActiveTool guards:
    /// `if (host.session !is null) host.session().…`.
    EditSession delegate() session;
}
