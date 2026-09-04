module commands.viewport.master;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;
import params : Param, wireArgs;

/// `viewport.master <id>` — set the ACTIVE cell's per-cell master override,
/// camera-only, no undo (task 0761; previously intercepted ahead of the
/// registry). Out-of-range clamps to -1 (self via group master at resolve
/// time) — unlike displayStyle/wireOverlay/wireAlpha/gridSteps, which
/// reject out-of-range input outright. Preserved as-is: this is an existing
/// behavioural asymmetry across the ten `viewport.*` commands, not
/// something this migration is authorised to resolve.
final class ViewportMaster : ViewportCommand {
    private int mid_ = -1;
    private int idArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.master"; }

    /// The declared argument. It was the dispatcher's "Law 3" — an
    /// int-or-string scan written for this one command; a numeric string is
    /// now coerced to the declared Int kind by `command_args.bindArgs`, under
    /// the same law every other numeric slot gets. A value that is not a
    /// number at all is REFUSED now instead of silently becoming -1.
    override Param[] params() {
        return wireArgs(
            Param.int_("id", "Master", &idArg_, -1)
        );
    }

    /// `mid` as extracted by the Law-3 (int-or-string) scan in
    /// `http_providers.d`. Clamps out-of-range to -1, verbatim.
    void setRaw(int mid) {
        if (mid < -1 || mid >= vpm.cellCount) mid = -1;
        mid_ = mid;
    }

    protected override bool applyImpl() {
        // The clamp reads `vpm.cellCount`, so it runs at apply rather than at
        // bind — the same frame, the same count, and now the same place every
        // other command validates.
        setRaw(idArg_);
        vpm.views[vpm.activeId].masterId = mid_;
        vpm.views[vpm.activeId].dirty = true;
        return true;
    }
}
