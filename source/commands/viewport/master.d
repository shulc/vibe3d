module commands.viewport.master;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;

/// `viewport.master <id>` — set the ACTIVE cell's per-cell master override,
/// camera-only, no undo (task 0761; previously intercepted ahead of the
/// registry). Out-of-range clamps to -1 (self via group master at resolve
/// time) — unlike displayStyle/wireOverlay/wireAlpha/gridSteps, which
/// reject out-of-range input outright. Preserved as-is: this is an existing
/// behavioural asymmetry across the ten `viewport.*` commands, not
/// something this migration is authorised to resolve.
final class ViewportMaster : ViewportCommand {
    private int mid_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.master"; }

    /// `mid` as extracted by the Law-3 (int-or-string) scan in
    /// `http_providers.d`. Clamps out-of-range to -1, verbatim.
    void setRaw(int mid) {
        if (mid < -1 || mid >= vpm.cellCount) mid = -1;
        mid_ = mid;
    }

    override bool apply() {
        vpm.views[vpm.activeId].masterId = mid_;
        vpm.views[vpm.activeId].dirty = true;
        return true;
    }
}
