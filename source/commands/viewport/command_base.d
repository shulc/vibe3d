module commands.viewport.command_base;

import command;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;

/// Shared base for the ten `viewport.*` commands moved out of the HTTP
/// delegate's own interception and into the registry (task 0761 — see
/// `doc/tasks/done/0761-*` for why the move was three decisions, not a
/// mechanical relocation). Every one of these commands is camera/UI state
/// only — none ever touches the mesh.
///
/// `CmdFlags.UI` (no undo entry) mirrors the precedent already shipped for
/// `commands.viewport.fit`/`fit_selected`: those two are the SAME class of
/// camera-only command, registered the same way, and both use `CmdFlags.UI`
/// already. The ten commands here carried "camera-only ... no undo entry" as
/// a comment at their old interception site; `CmdFlags.UI` is that same
/// decision, now load-bearing instead of prose.
abstract class ViewportCommand : Command {
    protected ViewportManager vpm;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode);
        this.vpm = vpm;
    }

    override CmdFlags cmdFlags() const { return CmdFlags.UI; }

    /// Resolve `cellArg` (-1 = "use the active cell") and throw if the
    /// result names a cell the current layout doesn't have. Shared by the
    /// three per-cell display commands (displayStyle/wireOverlay/wireAlpha)
    /// — verbatim behaviour from the original interception's shared range
    /// check, byte-identical message (`idForMsg` is each command's own
    /// `name()`).
    protected final int resolveCellOrThrow(int cellArg, string idForMsg) const {
        import std.format : format;
        int cell = (cellArg == -1) ? vpm.activeId : cellArg;
        if (cell < 0 || cell >= vpm.cellCount)
            throw new Exception(format(
                "%s: viewport %d is out of range — the current layout "
                ~ "has %d cell(s)", idForMsg, cell, vpm.cellCount));
        return cell;
    }

    /// Shared tail for the three per-cell display commands: mark the cell as
    /// user-chosen (not template-inherited), mark it dirty so the next frame
    /// re-renders it, and mirror the resolved display state into the
    /// in-memory prefs (flushed once at clean shutdown, harmless no-op under
    /// `--test`). Verbatim from the original interception's shared tail,
    /// which ran identically after all three id-specific switches.
    protected final void commitCellDisplay(int cell) {
        import viewport : Viewport3D;
        import prefs     : g_prefs;
        Viewport3D tv = vpm.views[cell];
        tv.displayUserSet = true;
        tv.dirty = true;
        if (cell < g_prefs.viewportDisplay.length) {
            g_prefs.viewportDisplay[cell].style        = tv.display.active.style;
            g_prefs.viewportDisplay[cell].wire         = tv.display.active.wire;
            g_prefs.viewportDisplay[cell].wireAlpha    = tv.display.active.wireAlpha;
            g_prefs.viewportDisplay[cell].styleUserSet = true;
        }
    }
}
