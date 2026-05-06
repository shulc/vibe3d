module commands.actr;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline           : g_pipeCtx;
import toolpipe.stages.actcenter   : ActionCenterStage;
import toolpipe.stages.axis        : AxisStage;
import toolpipe.stage              : TaskCode;

// ---------------------------------------------------------------------------
// `actr.<mode>` — MODO-aligned combined presets that flip both ACEN and
// AXIS stages atomically (matches `cmdhelptools.cfg` `actr.auto`,
// `actr.select`, `actr.selectauto`, ..., `actr.border` shape — see
// phase7_2_plan.md §"Canonical user commands").
//
// Granular `tool.pipe.attr actionCenter mode <X>` / `axis mode <Y>` is
// still available for mix-and-match (ACEN=Selection + AXIS=Workplane,
// etc.); these presets are the common-case shorthand.
//
// Argument shape: positional, none. Just `actr.element` etc.
// ---------------------------------------------------------------------------
class ActrPresetCommand : Command {
    private string acenMode_;
    private string axisMode_;
    private string presetName_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string presetName, string acenMode, string axisMode)
    {
        super(mesh, view, editMode);
        this.presetName_ = presetName;
        this.acenMode_   = acenMode;
        this.axisMode_   = axisMode;
    }

    override string name()  const { return "actr." ~ presetName_; }
    override string label() const { return "Action Center: " ~ presetName_; }

    // Pipe configuration is UI state, not a mesh edit — not undoable.
    override bool isUndoable() const { return false; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception(name() ~ ": pipeline not initialised");

        auto ac = cast(ActionCenterStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Acen);
        auto ax = cast(AxisStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Axis);
        if (ac is null && ax is null)
            throw new Exception(name() ~ ": no ACEN or AXIS stage registered");

        // Apply both — fail loudly if either rejects (catches typo-ed
        // mode names in registration).
        if (ac !is null && !ac.setAttr("mode", acenMode_))
            throw new Exception(
                name() ~ ": ACEN stage rejected mode '" ~ acenMode_ ~ "'");
        if (ax !is null && !ax.setAttr("mode", axisMode_))
            throw new Exception(
                name() ~ ": AXIS stage rejected mode '" ~ axisMode_ ~ "'");
        return true;
    }

    override bool revert() { return false; }
}
