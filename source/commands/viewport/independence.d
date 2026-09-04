module commands.viewport.independence;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;
import params : Param, wireArgs;

/// Which of a cell's three independence flags this instance backs. One
/// class, three registrations (`viewport.indCenter`/`indScale`/`indRotate`)
/// — the original interception's three branches differed only in WHICH
/// `Viewport3D` field they wrote, not in how the argument was read.
enum ViewportIndepAxis { Center, Scale, Rotate }

/// `viewport.indCenter|indScale|indRotate <yes|no>` — per-cell independence
/// flags, camera-only, no undo entry (task 0761; previously intercepted
/// ahead of the registry). Hardwired to the ACTIVE cell, like `viewport.view`
/// above it.
final class ViewportIndependence : ViewportCommand {
    private ViewportIndepAxis axis_;
    private bool val_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm,
         ViewportIndepAxis axis) {
        super(mesh, view, editMode, vpm);
        axis_ = axis;
    }

    override string name() const {
        final switch (axis_) {
            case ViewportIndepAxis.Center: return "viewport.indCenter";
            case ViewportIndepAxis.Scale:  return "viewport.indScale";
            case ViewportIndepAxis.Rotate: return "viewport.indRotate";
        }
    }

    /// The tolerant parse — "no"/"false"/"0" -> false, anything else -> true —
    /// is `command_args.coerceToSlot`'s rule for a Bool slot now, stated once
    /// for every command instead of once here. An absent argument leaves the
    /// field at its `true` default, exactly as before.
    override Param[] params() {
        return wireArgs(
            Param.bool_("value", "Value", &val_, true)
        );
    }

    void setValue(bool val) { val_ = val; }

    protected override bool applyImpl() {
        final switch (axis_) {
            case ViewportIndepAxis.Center: vpm.views[vpm.activeId].indCenter = val_; break;
            case ViewportIndepAxis.Scale:  vpm.views[vpm.activeId].indScale  = val_; break;
            case ViewportIndepAxis.Rotate: vpm.views[vpm.activeId].indRotate = val_; break;
        }
        vpm.views[vpm.activeId].dirty = true;
        return true;
    }
}
