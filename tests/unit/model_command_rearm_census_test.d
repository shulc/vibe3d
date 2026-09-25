// Task 6250 source/data census for the bounded pre-apply close, rewritten by
// slice M2 of the tool session model (doc/tool_session_model_plan_2026-09-24.md
// R3.7, R4.2 witness 4): the capability `ForeignEditBoundary` and its two
// session wrappers are gone; the property they carried — one close routine,
// reached from the command funnel through the session, with the resume after
// the command — is now read off `EditSession.closeOperation` / `finishClose`,
// the tools' `commitOperation` overrides and the production wiring in app.d.
module tests.unit.model_command_rearm_census_test;

import command : CmdFlags, Command;
import command_history : CommandHistory, RecordMode;
import command_executor : CommandExecutor;
import editmode : EditMode;
import registry : Registry;
import std.algorithm : canFind, count;
import std.conv : to;
import std.file : dirEntries, readText, SpanMode;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.regex : matchAll, regex;
import std.string : indexOf;
import tool_activation_ownership : CloseOutcome, CommandDoor, ToolTransition;
import view : View;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6250 census: missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6250 census: no body after `" ~ marker ~ "`");
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6250 census: unterminated body after `" ~ marker ~ "`");
}

private final class PolicyCommand : Command {
    private string id_;
    private CmdFlags flags_;
    private View view_;
    private bool delegate() apply_;
    this(string id, CmdFlags flags, bool delegate() apply = null) {
        view_ = new View(0, 0, 1, 1);
        super(null, view_, EditMode.Vertices);
        id_ = id;
        flags_ = flags;
        apply_ = apply;
    }
    override string name() const { return id_; }
    override CmdFlags cmdFlags() const { return flags_; }
    protected override bool applyImpl() { return apply_ is null || apply_(); }
}

unittest { // Published sets are populated, exact and disjoint by observed data.
    Registry registry;
    registry.registerCommand("mesh.subpatch_toggle", () => cast(Command)
        new PolicyCommand("mesh.subpatch_toggle", CmdFlags.Model));
    registry.registerCommand("mesh.bevel", () => cast(Command)
        new PolicyCommand("mesh.bevel", CmdFlags.Model));
    registry.registerCommand("tool.attr", () => cast(Command)
        new PolicyCommand("tool.attr", CmdFlags.SideEffect));
    registry.cacheSupportedModes();

    auto wire = parseJSON(registry.registryJson(false));
    auto commits = wire["commandsCommittingToolEditBeforeApply"].array;
    auto drops = wire["commandsDroppingToolBeforeApply"].array;
    assert(commits.length == 1 && commits[0].str == "mesh.subpatch_toggle",
        "6250 set census: pre-apply commit registry must equal [mesh.subpatch_toggle]: "
        ~ wire["commandsCommittingToolEditBeforeApply"].toString);
    assert(drops.length == 1 && drops[0].str == "mesh.bevel",
        "6250 set census: drop controls changed: "
        ~ wire["commandsDroppingToolBeforeApply"].toString);
    foreach (entry; commits)
        assert(!drops.canFind(entry),
            "6250 set census: command is published in both commit and drop sets: "
            ~ entry.toString);

    const commandSource = readText(buildPath(repoRoot, "source", "command.d"));
    const policy = bodyAt(commandSource,
        "bool commitsActiveToolEditBeforeApply(const Command cmd)");
    assert(policy.count(`return cmd.name() == "mesh.subpatch_toggle";`) == 1,
        "6250 set census: pre-apply commit policy changed captured id: " ~ policy);
}

unittest { // Production ordering: close before apply, finish from scope(exit).
    const source = readText(buildPath(repoRoot, "source", "command_executor.d"));
    const body = bodyAt(source,
        "bool applyOrRefire(Command cmd, RecordMode mode, string throwMsg)");
    const latch = body.indexOf("const bool reentrant = inPreApplyToolHandling_");
    const latchExit = body.indexOf("scope(exit) if (!reentrant) inPreApplyToolHandling_");
    const refire = body.indexOf("if (history.refireActive)");
    const uiTerm = body.indexOf("(uiOrigin_ && endsLiveEditBeforeUiCommand(cmd))");
    const close = body.indexOf("closeForCommand(uiOrigin_ ? CommandDoor.ui : CommandDoor.script)");
    const finishScope = body.indexOf("scope(exit) if (!reentrant && finishClose !is null) finishClose();");
    const apply = body.indexOf("if (cmd.apply()) {");
    assert(latch >= 0 && latchExit > latch && refire > latchExit && close > refire,
        "6250 order census: invocation latch is absent or not function-scoped");
    assert(uiTerm > refire && uiTerm < close,
        "M2 order census: the UI-door term no longer guards the close");
    assert(apply > close,
        "6250 order census: the live operation is no longer closed before cmd.apply()");
    assert(finishScope > close && apply > finishScope,
        "M2 order census: the close's finish is no longer owned by a non-reentrant scope(exit)");
    assert(body.count("closeForCommand(") == 1 && body.count("finishClose()") == 1,
        "M2 order census: the funnel calls the close or its finish more than once");
}

unittest { // Re-entry suppresses the finish only; the ordinary drop arm survives.
    auto history = new CommandHistory();
    bool armed = true;
    size_t drops, finishes, closes;
    bool innerApplied, outerApplied;
    CommandExecutor executor;
    executor = new CommandExecutor(history,
        () => armed,
        (ToolTransition) { ++drops; armed = false; },
        (CommandDoor) {
            ++closes;
            auto inner = new PolicyCommand("layer.rename", CmdFlags.Model,
                () { innerApplied = true; return true; });
            assert(executor.applyOrRefire(inner, RecordMode.Record, null),
                "6250 re-entry control: nested Model command was refused");
            return CloseOutcome(true, true);
        },
        () { ++finishes; });
    auto outer = new PolicyCommand("mesh.subpatch_toggle", CmdFlags.Model,
        () { outerApplied = true; return true; });

    assert(executor.applyOrRefire(outer, RecordMode.Record, null),
        "6250 re-entry control: outer boundary command was refused");
    assert(innerApplied && outerApplied,
        "6250 re-entry control: both Model commands must apply");
    assert(closes == 1, "M2 re-entry: the nested command reached the close a second time");
    assert(drops == 1 && !armed,
        "6250 re-entry: nested ordinary Model command lost the drop arm");
    assert(finishes == 1,
        "M2 re-entry: the finish ran from the nested frame as well as the outer one");
}

unittest { // A Model command inside refire never enters post-mode handling.
    auto history = new CommandHistory();
    bool armed = true;
    size_t drops, commits, resumes, applies;
    auto executor = new CommandExecutor(history,
        () => armed,
        (ToolTransition) { ++drops; armed = false; },
        (CommandDoor) { ++commits; return CloseOutcome(true, true); },
        () { ++resumes; });
    history.refireBegin();
    auto cmd = new PolicyCommand("layer.rename", CmdFlags.Model,
        () { ++applies; return true; });

    assert(executor.applyOrRefire(cmd, RecordMode.Record, null) && applies == 1,
        "6250 refire control: Model command did not fire inside the bracket");
    assert(armed,
        "6250 refire: Model command crossed the armed-tool policy");
    assert(drops == 0 && commits == 0 && resumes == 0,
        "6250 refire: lifecycle callbacks ran inside the bracket");
    history.refireEnd();
}

unittest { // One close routine: the session decides by policy, the tool by its body.
    const source = readText(buildPath(repoRoot, "source", "edit_session.d"));
    assert(source.indexOf("ForeignEditBoundary") < 0
        && source.indexOf("commitPendingForForeignEdit") < 0
        && source.indexOf("resumeAfterForeignEdit") < 0,
        "M2 close census: the deleted boundary capability is back in edit_session.d");
    const entry = bodyAt(source, "CloseOutcome closeOperation(CloseReason r, CommandDoor door");
    assert(entry.count("tools_.close(r, door)") == 1,
        "M2 close census: EditSession.closeOperation no longer delegates to the tool session");
    const close = bodyAt(source, "CloseOutcome close(CloseReason r, CommandDoor door)");
    assert(close.count("sessionPolicy().commandClose") == 1
        && close.count("commitOperation()") == 1
        && close.count("hasUncommittedEdit()") == 1,
        "M2 close census: the routine lost its policy read, its one commit or its idle test");
    foreach (generic; ["commitUncommittedEdit", "resyncSession", "cast("])
        assert(close.indexOf(generic) < 0,
            "M2 close census: the routine gained a per-tool branch: " ~ generic);
    const finish = bodyAt(source, "void finishClose() {\n        if (pendingMark_)");
    assert(finish.count("resumeAfterClose()") == 1 && finish.count("pendingResume_ = false") == 1,
        "M2 close census: finishClose no longer resumes exactly once");
}

unittest { // The tools that close their operation their own way, exactly.
    size_t commits, resumes;
    string[] owners;
    auto commitRx = regex(r"override bool commitOperation\(\)");
    auto resumeRx = regex(r"override void resumeAfterClose\(\)");
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const source = readText(entry.name);
        foreach (_; source.matchAll(commitRx)) { ++commits; owners ~= entry.name; }
        foreach (_; source.matchAll(resumeRx)) ++resumes;
    }
    // Measured on the M2 tree: the transform family and the three cutting
    // tools; every other closing tool uses the base's in-place default.
    assert(commits == 4, "M2 override census: commitOperation overriders changed: " ~ owners.to!string);
    foreach (want; ["xfrm_transform.d", "edge_slice_tool.d", "loop_slice_tool.d", "slice_tool.d"])
        assert(owners.canFind!(o => o.canFind(want)),
            "M2 override census: " ~ want ~ " no longer overrides commitOperation");
    assert(resumes == 1, "M2 override census: resumeAfterClose overriders changed");
}

unittest { // The production wiring names the close and its finish, once each.
    const app = readText(buildPath(repoRoot, "source", "app.d"));
    const binding = readText(buildPath(repoRoot, "source", "application_command_binding.d"));
    size_t commandCloses;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        commandCloses += blankNonCode(readText(entry.name)).count("closeOperation(CloseReason.command");
    assert(commandCloses == 1 && app.count("closeOperation(CloseReason.command, door)") == 1,
        "M2 wiring census: the command close is not reached from exactly one site (app.d's executor)");
    assert(blankNonCode(binding).count("closeOperation") == 0
        && blankNonCode(binding).count("applyOrRefireFromUi") == 0,
        "M2 wiring census: the application binding calls the close itself");
    assert(blankNonCode(app).count("applyOrRefireFromUi") == 1,
        "M2 wiring census: the UI apply port is not the UI door of the funnel");
    const ctorAt = app.indexOf("auto executor = new CommandExecutor(history,");
    assert(ctorAt >= 0, "M2 wiring census: the executor construction moved");
    const ctor = app[ctorAt .. $];
    const ctorText = ctor[0 .. ctor.indexOf(");\n") + 2];
    assert(ctorText.indexOf("session.closeOperation(CloseReason.command, door)") >= 0
        && ctorText.indexOf("session.finishClose()") >= 0,
        "M2 wiring census: the executor's delegates no longer name closeOperation / finishClose: "
        ~ ctorText);
    const drop = bodyAt(app, "void dropActiveTool(ToolTransition why)");
    const dClose = drop.indexOf("closeOperation(closeReasonFor(why))");
    const dDoor = drop.indexOf("final switch (activationDoorFor(why))");
    const dFinish = drop.indexOf("session.finishClose()");
    assert(dClose >= 0 && dDoor > dClose && dFinish > dDoor,
        "M2 wiring census: dropActiveTool must account the close, then run the door, then finish it");
    const arm = bodyAt(app, "void armPreparedTool(ToolTransition why, string id, ref JSONValue namedArgs,");
    const aClose = arm.indexOf("closeOperation(closeReasonFor(why))");
    const aFinish = arm.indexOf("scope(exit) if (session !is null) session.finishClose()");
    const aPrepare = arm.indexOf("prepareArm(factory");
    assert(aClose >= 0 && aFinish > aClose && aPrepare > aFinish,
        "M2 wiring census: armPreparedTool must account the predecessor's close before its door");
}
