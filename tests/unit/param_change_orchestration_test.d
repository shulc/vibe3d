// Witness for task 4590: the value-write protocol has one lifecycle owner.
//
// The behavioural blocks below this seam are added only after this first
// source check has been observed red against the pre-R3 tree.  This block is
// intentionally about ownership: end-to-end geometry can stay correct while
// PropertyPanel and ToolAttrCommand each keep a private copy of the same
// notification/evaluate/session order.
module tests.unit.param_change_orchestration_test;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;

import command_history : CommandHistory;
import edit_session;
import tool : Tool;
import toolpipe.stage : Stage, TaskCode;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private final class Trace {
    string value;
    void add(string event) { value ~= event; }
    void clear() { value = ""; }
}

private final class ProbeTool : Tool, FrameParameterEvalClient, LiveEvalClient,
                                SlotActivationClient {
    Trace trace;
    bool liveValue;
    bool liveStage;
    bool consumeSlot;

    this(Trace trace) { this.trace = trace; }

    override void onParamChanged(string) {
        trace.add(interactiveParamEdit ? "I" : "S");
    }
    override void evaluate() { trace.add("E"); }
    override void evaluateParameterFrame() { trace.add("F"); }
    override bool hasLiveEval() const { return liveStage; }
    override bool hasLiveAttrEval() const { return liveValue; }
    override void reEvaluate() { trace.add("R"); }
    override bool endHeldRunIfSlotActivated() {
        trace.add("H");
        return consumeSlot;
    }
}

private final class ProbeStage : Stage {
    Trace trace;
    this(Trace trace) { this.trace = trace; }
    override TaskCode taskCode() const pure nothrow @nogc @safe {
        return TaskCode.Wght;
    }
    override string id() const { return "probe"; }
    override ubyte ordinal() const pure nothrow @nogc @safe { return 0; }
    override void onParamChanged(string) { trace.add("A"); }
}

private EditSession sessionFor(ProbeTool tool) {
    Tool active = tool;
    return new EditSession(() => active, new CommandHistory(), () {});
}

unittest { // source and phase determine the notification/evaluation order
    auto trace = new Trace();
    auto tool = new ProbeTool(trace);
    auto session = sessionFor(tool);

    session.orchestrateParameterChange(tool, "x",
        ParameterChangeSource.ScriptedValue, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(tool, "",
        ParameterChangeSource.ScriptedValue, ParameterChangePhase.BatchComplete);
    assert(trace.value == "SE",
        "fresh scripted value must notify, then evaluate, without opening live replay; got "
      ~ trace.value);

    trace.clear();
    tool.liveValue = true;
    session.orchestrateParameterChange(tool, "x",
        ParameterChangeSource.ScriptedValue, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(tool, "",
        ParameterChangeSource.ScriptedValue, ParameterChangePhase.BatchComplete);
    assert(trace.value == "SER",
        "live scripted value must notify, evaluate, then replay; got " ~ trace.value);

    trace.clear();
    tool.liveValue = false;
    session.orchestrateParameterChange(tool, "x",
        ParameterChangeSource.InteractiveValue, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(tool, "y",
        ParameterChangeSource.InteractiveValue, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(tool, "",
        ParameterChangeSource.InteractiveValue, ParameterChangePhase.BatchComplete);
    assert(trace.value == "IIER",
        "two writes in one interactive batch require two notifications, one evaluate, "
      ~ "then one opener replay; got " ~ trace.value);
}

unittest { // stage attributes re-grade; slot activation ends before re-grade
    auto trace = new Trace();
    auto tool = new ProbeTool(trace);
    auto stage = new ProbeStage(trace);
    auto session = sessionFor(tool);
    tool.liveStage = true;

    session.orchestrateParameterChange(stage, "size",
        ParameterChangeSource.StageAttribute, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(stage, "",
        ParameterChangeSource.StageAttribute, ParameterChangePhase.BatchComplete);
    assert(trace.value == "AR",
        "stage attribute must notify before its live re-grade; got " ~ trace.value);

    trace.clear();
    tool.consumeSlot = true;
    auto epochBefore = stage.slotEpoch;
    session.orchestrateParameterChange(stage, "type",
        ParameterChangeSource.SlotActivation, ParameterChangePhase.ValueWritten);
    session.orchestrateParameterChange(stage, "",
        ParameterChangeSource.SlotActivation, ParameterChangePhase.BatchComplete);
    assert(stage.slotEpoch == epochBefore + 1,
        "legacy slot widget must publish one slot epoch");
    assert(trace.value == "AH",
        "slot activation must notify and end the held run without re-grade; got "
      ~ trace.value);
}

unittest { // frame-driven consumers are explicit and panel-independent
    auto trace = new Trace();
    auto tool = new ProbeTool(trace);
    auto session = sessionFor(tool);
    session.tickParameterEvaluation();
    assert(trace.value == "F",
        "the opted-in frame parameter consumer must tick exactly once; got "
      ~ trace.value);
}

unittest {
    immutable panelPath = buildPath(repoRoot, "source", "property_panel.d");
    immutable attrPath = buildPath(repoRoot, "source", "commands", "tool", "attr.d");
    immutable wrapperPath = buildPath(repoRoot, "source", "tools", "common",
                                      "command_wrapper.d");
    immutable panelsPath = buildPath(repoRoot, "source", "ui", "panels.d");
    immutable panelCode = blankNonCode(readText(panelPath));
    immutable attrCode = blankNonCode(readText(attrPath));
    immutable wrapperCode = blankNonCode(readText(wrapperPath));
    immutable panelsCode = blankNonCode(readText(panelsPath));
    assert(panelCode.length > 1_000 && attrCode.length > 1_000
           && wrapperCode.length > 10_000 && panelsCode.length > 50_000,
        "parameter orchestration witness read too little production source");
    assert(panelCode.indexOf("t.evaluate();") < 0,
        "parameter orchestration witness: PropertyPanel still owns the "
      ~ "Tool evaluate step instead of dispatching the widget batch to "
      ~ "EditSession");
    assert(attrCode.indexOf("t.evaluate();") < 0,
        "parameter orchestration witness: ToolAttrCommand still owns the "
      ~ "Tool evaluate step instead of dispatching the command batch to "
      ~ "EditSession");
    assert(wrapperCode.indexOf(
           "abstract class CommandWrapperTool : Tool, FrameParameterEvalClient") >= 0
           && wrapperCode.indexOf("override void evaluateParameterFrame()") >= 0
           && panelsCode.indexOf("session.tickParameterEvaluation();") >= 0,
        "frame parameter witness: CommandWrapperTool and the UI-frame lifecycle "
      ~ "tick are no longer joined by the explicit frame capability");
}
