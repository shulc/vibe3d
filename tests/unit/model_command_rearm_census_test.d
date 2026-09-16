// Task 6250 source/data census for the bounded foreign-edit boundary protocol.
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
import tool_activation_ownership : ToolTransition;
import view : View;

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
    registry.commandFactories["mesh.subpatch_toggle"] = () => cast(Command)
        new PolicyCommand("mesh.subpatch_toggle", CmdFlags.Model);
    registry.commandFactories["mesh.bevel"] = () => cast(Command)
        new PolicyCommand("mesh.bevel", CmdFlags.Model);
    registry.commandFactories["tool.attr"] = () => cast(Command)
        new PolicyCommand("tool.attr", CmdFlags.SideEffect);
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

unittest { // Production ordering: commit before apply, resume from scope(exit).
    const source = readText(buildPath(repoRoot, "source", "command_executor.d"));
    const body = bodyAt(source,
        "bool applyOrRefire(Command cmd, RecordMode mode, string throwMsg)");
    const latch = body.indexOf("const bool reentrant = inPreApplyToolHandling_");
    const latchExit = body.indexOf("scope(exit) if (!reentrant)");
    const refire = body.indexOf("if (history.refireActive)");
    const commit = body.indexOf("commitPendingToolEdit()");
    const resumeScope = body.indexOf("scope(exit) if (resume");
    const resumeCall = body.indexOf("resumeActiveTool();");
    const apply = body.indexOf("if (cmd.apply()) {");
    assert(latch >= 0 && latchExit > latch && refire > latchExit && commit > refire,
        "6250 order census: invocation latch is absent or not function-scoped");
    assert(apply > commit,
        "6250 order census: pending tool edit is no longer committed before cmd.apply()");
    assert(resumeScope > commit && resumeCall > resumeScope,
        "6250 order census: post-command resume is no longer owned by scope(exit)");
}

unittest { // Re-entry suppresses resume only; the ordinary drop arm survives.
    auto history = new CommandHistory();
    bool armed = true;
    size_t drops, resumes;
    bool innerApplied, outerApplied;
    CommandExecutor executor;
    executor = new CommandExecutor(history,
        () => armed,
        (ToolTransition) { ++drops; armed = false; },
        () {
            auto inner = new PolicyCommand("layer.rename", CmdFlags.Model,
                () { innerApplied = true; return true; });
            assert(executor.applyOrRefire(inner, RecordMode.Record, null),
                "6250 re-entry control: nested Model command was refused");
            return true;
        },
        () { ++resumes; });
    auto outer = new PolicyCommand("mesh.subpatch_toggle", CmdFlags.Model,
        () { outerApplied = true; return true; });

    assert(executor.applyOrRefire(outer, RecordMode.Record, null),
        "6250 re-entry control: outer boundary command was refused");
    assert(innerApplied && outerApplied,
        "6250 re-entry control: both Model commands must apply");
    assert(drops == 1 && !armed,
        "6250 re-entry: nested ordinary Model command lost the drop arm");
    assert(resumes == 0,
        "6250 re-entry: dropped tool was spuriously resumed");
}

unittest { // A Model command inside refire never enters post-mode handling.
    auto history = new CommandHistory();
    bool armed = true;
    size_t drops, commits, resumes, applies;
    auto executor = new CommandExecutor(history,
        () => armed,
        (ToolTransition) { ++drops; armed = false; },
        () { ++commits; return true; },
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

unittest { // Capability methods cast narrowly and contain no generic fallback.
    const source = readText(buildPath(repoRoot, "source", "edit_session.d"));
    const commit = bodyAt(source, "bool commitPendingForForeignEdit() {");
    const resume = bodyAt(source, "void resumeAfterForeignEdit() {");
    foreach (name, body; ["commit": commit, "resume": resume]) {
        assert(body.count("cast(ForeignEditBoundary)") == 1,
            "6250 capability census: " ~ name ~ " body lost its exact cast gate");
        assert(body.indexOf("commitUncommittedEdit") < 0,
            "6250 capability census: " ~ name ~ " body gained generic commit fallback");
        assert(body.indexOf("resyncSession") < 0,
            "6250 capability census: " ~ name ~ " body gained generic resync fallback");
    }
}

unittest { // The optional capability has exactly one production implementor.
    size_t implementors;
    string[] owners;
    auto pattern = regex(r"class\s+\w+\s*:[^{]*\bForeignEditBoundary\b[^{]*\{");
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const source = readText(entry.name);
        foreach (_; source.matchAll(pattern)) {
            ++implementors;
            owners ~= entry.name;
        }
    }
    assert(implementors == 1 && owners[0].canFind("xfrm_transform.d"),
        "6250 capability implementor census changed: " ~ owners.to!string);
}
