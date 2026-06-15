module commands.falloff;

import command;
import mesh;
import view;
import editmode;
import commands.tool.host : ToolHost;

import toolpipe.pipeline         : g_pipeCtx;
import toolpipe.stages.falloff   : FalloffStage;
import toolpipe.stage            : TaskCode;

// ---------------------------------------------------------------------------
// `falloff.<type>` — bare named falloff sub-tools.
//
// Activating a falloff by name (`falloff.linear`, `falloff.radial`,
// `falloff.cylinder`, `falloff.screen`, `falloff.lasso`) just SETS the
// falloff (WGHT) stage's `type` and KEEPS the active transform tool. It is
// NOT a tool that replaces the active tool, and NOT a transform bundle — a
// falloff is a modifier the active transform consumes.
//
// This is the exact analog of the status-bar Falloff pulldown action
// (`tool.pipe.attr falloff type <type>`): it routes the type write through
// the SAME FalloffStage.setAttr path, so the on-switch auto-size and
// state-publish side-effects are identical, and it fires the SAME live
// re-evaluation when a session is already open.
//
// Argument shape: positional, none. Just `falloff.linear` etc. The two
// existing bundle presets (`falloff.element`, `falloff.selection`) live in
// config/tool_presets.yaml and are left unchanged.
// ---------------------------------------------------------------------------
class FalloffPresetCommand : Command {
    private ToolHost toolHost;
    private string   typeName_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         ToolHost host, string typeName)
    {
        super(mesh, view, editMode);
        this.toolHost  = host;
        this.typeName_ = typeName;
    }

    override string name()  const { return "falloff." ~ typeName_; }
    override string label() const {
        // Human label consistent with FalloffStage.displayName() output
        // ("Linear Falloff", "Radial Falloff", ...): capitalised type name
        // plus " Falloff".
        import std.ascii  : toUpper;
        import std.conv   : to;
        string cap = typeName_.length
            ? to!string(cast(char)toUpper(typeName_[0])) ~ typeName_[1 .. $]
            : typeName_;
        return cap ~ " Falloff";
    }

    // Pipe configuration is UI state, not a mesh edit — not undoable.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception(name() ~ ": pipeline not initialised");

        auto fo = cast(FalloffStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
        if (fo is null)
            throw new Exception(name() ~ ": no falloff (WGHT) stage registered");

        // Route through setAttr so the on-switch auto-size + state-publish
        // side-effects match the status-bar pulldown exactly. Fail loudly if
        // the stage rejects the type (catches a typo-ed registration).
        if (!fo.setAttr("type", typeName_))
            throw new Exception(
                name() ~ ": falloff stage rejected type '" ~ typeName_ ~ "'");

        // Mid-session immediacy: if a tool already has a live evaluation
        // session, re-run its apply now so the new falloff takes effect this
        // edit instead of on the next update() tick. Mirrors
        // ToolPipeAttrCommand.apply(). The active tool is NOT changed.
        if (toolHost.getActiveTool !is null) {
            auto t = toolHost.getActiveTool();
            if (t !is null && t.hasLiveEval()) t.reEvaluate();
        }
        return true;
    }

    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// Linear-endpoint action verbs — the falloff form's "Auto Size" X/Y/Z buttons
// and "Reverse" button (config/forms/falloff.yaml). Fire-only `cmd` rows can't
// use a `tool.pipe.attr falloff <attr>` line (the forms binding parser requires
// a `?` value slot on stage-namespace lines), so these are top-level commands.
// Both route through FalloffStage.setAttr (the `autosize` / `reverse` action
// pseudo-attrs) so the state-publish + live-eval side-effects match every other
// falloff edit. Linear-only at the stage level (no-op for other types).
// ---------------------------------------------------------------------------

/// Resolve the primary falloff (WGHT) stage, or throw with `who` as the prefix.
private FalloffStage requireFalloffStage(string who) {
    if (g_pipeCtx is null)
        throw new Exception(who ~ ": pipeline not initialised");
    auto fo = cast(FalloffStage)g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
    if (fo is null)
        throw new Exception(who ~ ": no falloff (WGHT) stage registered");
    return fo;
}

class FalloffAutoSizeCommand : Command {
    private ToolHost toolHost;
    private string   axis_;   // "x" / "y" / "z" (set by the app.d positional bridge)

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "falloff.autosize"; }
    override string label() const { return "Auto Size"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// Set by the app.d positional-arg bridge (falloff.autosize <axis>).
    void setAxis(string a) { axis_ = a; }

    override bool apply() {
        auto fo = requireFalloffStage(name());
        if (axis_.length == 0)
            throw new Exception("falloff.autosize: no axis specified (x/y/z)");
        if (!fo.setAttr("autosize", axis_))
            throw new Exception(
                "falloff.autosize: rejected axis '" ~ axis_ ~ "' (expected x/y/z)");
        kickLiveEval(toolHost);
        return true;
    }

    override bool revert() { return false; }
}

class FalloffReverseCommand : Command {
    private ToolHost toolHost;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "falloff.reverse"; }
    override string label() const { return "Reverse"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        auto fo = requireFalloffStage(name());
        fo.setAttr("reverse", "1");
        kickLiveEval(toolHost);
        return true;
    }

    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// Multi-falloff stacking verbs (Phase 4 of doc/falloff_multi_subtool_plan.md):
//
//   falloff.add <type>      — create a NEW stacked FalloffStage instance with
//                             the given type and a fresh unique id
//                             ("falloff#1", "falloff#2", …), registered via
//                             pipeline.addStacked. DUPLICATE types allowed
//                             (two radials coexist).
//   falloff.remove <id>     — remove the stacked instance with that id. The
//                             PRIMARY ("falloff") is the compat anchor and is
//                             NOT removable (rejected with a clear error).
//   falloff.clear           — remove ALL stacked extras, keep the primary.
//
// All three are pipe configuration = UI state, so CmdFlags.SideEffect (not
// undoable). The bare `falloff.<type>` set-primary commands stay unchanged.
//
// Set-aware undo/refire is a SEPARATE follow-up — these verbs deliberately do
// NOT touch the wrapper's falloff refire/undo hooks.
// ---------------------------------------------------------------------------

// Accepted `falloff.add <type>` type names — the same set FalloffStage's
// setAttr("type", …) recognises (minus "none", which would add an inert
// stage). Kept in lockstep with the applySetAttr "type" switch.
private bool validFalloffType(string t) {
    switch (t) {
        case "linear", "radial", "screen", "lasso", "cylinder",
             "element", "selection":
            return true;
        default:
            return false;
    }
}

// Lowest free "falloff#N" id (N≥1) not already taken by a registered WGHT
// stage. Scans every WGHT-task stage's id so two `add`s never collide and a
// removed slot is reused.
private string allocFalloffId() {
    import std.algorithm : canFind;
    import std.format    : format;
    import toolpipe.stage : TaskCode;
    string[] taken;
    foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
        taken ~= s.id();
    for (int n = 1; ; ++n) {
        string cand = format("falloff#%d", n);
        if (!taken.canFind(cand)) return cand;
    }
}

// Mid-session immediacy: re-run the active tool's apply so a freshly
// added/removed falloff takes effect this edit instead of next tick.
// Mirrors FalloffPresetCommand.apply()'s live-eval kick.
private void kickLiveEval(ToolHost host) {
    if (host.getActiveTool !is null) {
        auto t = host.getActiveTool();
        if (t !is null && t.hasLiveEval()) t.reEvaluate();
    }
}

class FalloffAddCommand : Command {
    private ToolHost toolHost;
    private string   typeName_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "falloff.add"; }
    override string label() const { return "Add Falloff"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// Set by the app.d positional-arg bridge (falloff.add <type>).
    void setTypeName(string t) { typeName_ = t; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("falloff.add: pipeline not initialised");
        if (typeName_.length == 0)
            throw new Exception("falloff.add: no falloff type specified");

        // Mirror the mesh/editMode pointers the primary FalloffStage holds so
        // the new instance auto-sizes + computes selection weights correctly.
        // Sourced from the primary so we don't need separate plumbing.
        import toolpipe.stage : TaskCode;
        auto primary = cast(FalloffStage)
                       g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
        if (primary is null)
            throw new Exception(
                "falloff.add: no primary falloff (WGHT) stage registered");

        string newId = allocFalloffId();
        auto fo = new FalloffStage(() => primary.meshPtr(), primary.editModePtr(),
                                   newId);
        // Register FIRST: addStacked → plug() → Operator.reset() restores the
        // stage's fields to defaults (type = None). So the type MUST be set
        // AFTER registration, never before (same gotcha test_falloff_combine.d
        // documents). Validate the type name up front so a typo fails loudly
        // without leaving a stray None instance plugged in.
        if (!validFalloffType(typeName_))
            throw new Exception(
                "falloff.add: rejected type '" ~ typeName_ ~ "'");
        g_pipeCtx.pipeline.addStacked(fo);
        // Route through setAttr so the on-switch auto-size + state-publish
        // (guarded primary-only) side-effects run identically to the primary
        // path. Cannot fail now (pre-validated above).
        fo.setAttr("type", typeName_);
        kickLiveEval(toolHost);
        return true;
    }

    override bool revert() { return false; }
}

class FalloffRemoveCommand : Command {
    private ToolHost toolHost;
    private string   targetId_;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "falloff.remove"; }
    override string label() const { return "Remove Falloff"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// Set by the app.d positional-arg bridge (falloff.remove <id>).
    void setTargetId(string id) { targetId_ = id; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("falloff.remove: pipeline not initialised");
        if (targetId_.length == 0)
            throw new Exception("falloff.remove: no falloff id specified");
        // The primary is the compat anchor — never removable.
        if (targetId_ == "falloff")
            throw new Exception(
                "falloff.remove: cannot remove the primary 'falloff' " ~
                "(it is the compat anchor); only 'falloff#N' extras are " ~
                "removable");

        auto fo = cast(FalloffStage)g_pipeCtx.pipeline.findById(targetId_);
        if (fo is null)
            throw new Exception(
                "falloff.remove: no falloff instance '" ~ targetId_ ~ "'");

        // Unplug the Operator side first, then drop the Stage. removeStage
        // matches by reference identity.
        import operator : Operator;
        g_pipeCtx.pipeline.unplug(cast(Operator)fo);
        g_pipeCtx.pipeline.removeStage(fo);
        kickLiveEval(toolHost);
        return true;
    }

    override bool revert() { return false; }
}

class FalloffClearCommand : Command {
    private ToolHost toolHost;

    this(Mesh* mesh, ref View view, EditMode editMode, ToolHost host) {
        super(mesh, view, editMode);
        this.toolHost = host;
    }

    override string name()  const { return "falloff.clear"; }
    override string label() const { return "Clear Stacked Falloffs"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override bool apply() {
        if (g_pipeCtx is null)
            throw new Exception("falloff.clear: pipeline not initialised");
        removeStackedFalloffs();
        kickLiveEval(toolHost);
        return true;
    }

    override bool revert() { return false; }
}

/// Remove every stacked extra FalloffStage (`falloff#N`), keeping the primary
/// (`id()=="falloff"`). Shared by `falloff.clear` and SceneReset so a reset
/// returns the pipe to exactly one falloff stage (byte-stable baseline).
void removeStackedFalloffs() {
    if (g_pipeCtx is null) return;
    import operator       : Operator;
    import toolpipe.stage : TaskCode;
    // Collect first (don't mutate while iterating findAllByTask's snapshot is
    // already a fresh slice, but be explicit about the two-phase removal).
    FalloffStage[] extras;
    foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght)) {
        auto fo = cast(FalloffStage)s;
        if (fo !is null && !fo.isPrimary())
            extras ~= fo;
    }
    foreach (fo; extras) {
        g_pipeCtx.pipeline.unplug(cast(Operator)fo);
        g_pipeCtx.pipeline.removeStage(fo);
    }
}
