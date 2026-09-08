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
import std.string : count, indexOf, strip;

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
    ParameterChangeSource replaySource;
    string[] replayNames;

    this(Trace trace) { this.trace = trace; }

    override void onParamChanged(string) {
        trace.add(interactiveParamEdit ? "I" : "S");
    }
    override void evaluate() { trace.add("E"); }
    override void evaluateParameterFrame() { trace.add("F"); }
    override bool hasLiveEval() const { return liveStage; }
    override bool hasLiveAttrEval() const { return liveValue; }
    override void reEvaluate(ParameterChangeBatch batch) {
        replaySource = batch.source;
        replayNames = batch.names.dup;
        trace.add("R");
    }
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

private EditSession sessionFor(Tool tool) {
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
    assert(tool.replaySource == ParameterChangeSource.ScriptedValue &&
           tool.replayNames == ["x"],
        "scripted replay must receive its exact source/write-set");

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
    assert(tool.replaySource == ParameterChangeSource.InteractiveValue &&
           tool.replayNames == ["x", "y"],
        "interactive replay must receive all actually-written channels once");
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
    assert(trace.value == "AHR",
        "stage attribute must notify, ask for slot activation, then re-grade; got " ~ trace.value);

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
    immutable runnerPath = buildPath(repoRoot, "source", "frame_runner.d");
    immutable appPath = buildPath(repoRoot, "source", "app.d");
    immutable panelCode = blankNonCode(readText(panelPath));
    immutable attrCode = blankNonCode(readText(attrPath));
    immutable wrapperCode = blankNonCode(readText(wrapperPath));
    immutable panelsCode = blankNonCode(readText(panelsPath));
    immutable runnerCode = blankNonCode(readText(runnerPath));
    immutable appCode = blankNonCode(readText(appPath));
    assert(panelCode.length > 1_000 && attrCode.length > 1_000
           && wrapperCode.length > 10_000 && panelsCode.length > 50_000
           && runnerCode.length > 2_000 && appCode.length > 100_000,
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
           && wrapperCode.indexOf("override void evaluateParameterFrame()") >= 0,
        "frame parameter witness: CommandWrapperTool lost the explicit frame capability");

    enum sessionTick = "session.tickParameterEvaluation();";
    enum runnerPhase = "void tickParameterEvaluation(EditSession session) {\n"
                     ~ "        session.tickParameterEvaluation();\n"
                     ~ "    }";
    enum phaseCall = "frameRunner.tickParameterEvaluation(session);";
    enum sidePanelCall = "drawSidePanel(app);";
    assert(runnerCode.count(runnerPhase) == 1,
        "frame parameter owner: FrameRunner must own exactly one named "
      ~ "EditSession tick phase");
    assert(panelsCode.count(sessionTick) == 0,
        "frame parameter owner: drawSidePanel must not own the EditSession tick");
    assert(appCode.count(phaseCall) == 1 && appCode.count(sidePanelCall) == 1,
        "frame parameter wiring: expected one phase call and one side-panel draw");
    const phasePos = appCode.indexOf(phaseCall);
    const panelPos = appCode.indexOf(sidePanelCall);
    assert(phasePos >= 0 && panelPos >= 0 && phasePos < panelPos
           && appCode[phasePos + phaseCall.length .. panelPos].strip.length == 0,
        "frame parameter timing: the named phase must remain immediately before "
      ~ "drawSidePanel");
}

// The source census above constrains ownership, but it cannot see what
// arguments the panel actually sends.  These stands submit the shipped
// PropertyPanel body inside a real ImGui frame and drive its widgets through
// the same input queue a platform backend fills.
import params : Param;
import std.conv : to;

private final class PanelProbeTool : Tool, LiveEvalClient,
                                     SlotActivationClient {
    Trace trace;
    float amount;
    bool liveStage;
    bool consumeSlot;

    this(Trace trace) { this.trace = trace; }

    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount, 0.0f).step(0.01f)];
    }
    override void onParamChanged(string) {
        trace.add(interactiveParamEdit ? "I" : "S");
    }
    override void evaluate() { trace.add("E"); }
    override bool hasLiveEval() const { return liveStage; }
    override bool hasLiveAttrEval() const { return false; }
    override void reEvaluate(ParameterChangeBatch batch) { trace.add("R"); }
    override bool endHeldRunIfSlotActivated() {
        trace.add("H");
        if (!consumeSlot) return false;
        consumeSlot = false;
        liveStage = false;
        return true;
    }
}

private final class PanelProbeStage : Stage {
    Trace trace;
    float axis;
    float slot;

    this(Trace trace) { this.trace = trace; }

    override TaskCode taskCode() const pure nothrow @nogc @safe {
        return TaskCode.Wght;
    }
    override string id() const { return "panel-probe"; }
    override ubyte ordinal() const pure nothrow @nogc @safe { return 0; }
    override Param[] params() {
        return [
            Param.float_("axis", "Axis", &axis, 0.0f).step(0.01f),
            Param.float_("slot", "Slot", &slot, 0.0f).step(0.01f),
        ];
    }
    override void onParamChanged(string) { trace.add("A"); }
    override bool attrArmsSlot(string name) const { return name == "slot"; }
}

unittest { // an idle legacy panel is inert, then one real write evaluates and replays
    import property_panel : PropertyPanel;
    import tests.unit.ui.headless_panel : openPanel;

    auto trace = new Trace();
    auto tool = new PanelProbeTool(trace);
    auto session = sessionFor(tool);
    auto panel = new PropertyPanel();
    auto ui = openPanel(() { panel.draw(tool, session); });
    scope (exit) ui.close();

    ui.frame();
    assert(trace.value == "",
        "legacy tool panel idle draw must not complete a parameter batch; got "
      ~ trace.value);

    ui.editRow(0, "2.0");
    assert(tool.amount == 2.0f,
        "legacy tool panel fixture did not write the real Tool field");
    assert(trace.value == "IER",
        "legacy tool panel write must be interactive, evaluate once, then replay; got "
      ~ trace.value);
}

unittest { // real stage rows reach completion for both re-grade and slot ask
    import property_panel : PropertyPanel;
    import tests.unit.ui.headless_panel : openPanel;

    auto attrTrace = new Trace();
    auto attrTool = new PanelProbeTool(attrTrace);
    attrTool.liveStage = true;
    auto attrStage = new PanelProbeStage(attrTrace);
    auto attrSession = sessionFor(attrTool);
    auto attrPanel = new PropertyPanel();
    auto attrUi = openPanel(() { attrPanel.drawProvider(attrStage, attrSession); });
    attrUi.frame();
    attrUi.editRow(0, "2.0");
    attrUi.close();

    auto slotTrace = new Trace();
    auto slotTool = new PanelProbeTool(slotTrace);
    slotTool.liveStage = true;
    slotTool.consumeSlot = true;
    auto slotStage = new PanelProbeStage(slotTrace);
    auto slotSession = sessionFor(slotTool);
    auto slotPanel = new PropertyPanel();
    auto slotUi = openPanel(() { slotPanel.drawProvider(slotStage, slotSession); });
    scope (exit) slotUi.close();
    auto epochBefore = slotStage.slotEpoch;
    slotUi.frame();
    slotUi.editRow(1, "2.0");

    assert(attrTrace.value == "AHR" && slotTrace.value == "AH",
        "legacy stage panel must complete both attribute re-grade and slot ask; "
      ~ "attribute got " ~ attrTrace.value ~ ", slot got " ~ slotTrace.value);
    assert(slotStage.slotEpoch == epochBefore + 1,
        "one discrete legacy slot edit must publish one slot epoch");
}

unittest { // one continuous slot drag is one activation, not one per motion frame
    import property_panel : PropertyPanel;
    import tests.unit.ui.headless_panel : openPanel;

    auto trace = new Trace();
    auto tool = new PanelProbeTool(trace);
    tool.liveStage = true;
    tool.consumeSlot = true;
    auto stage = new PanelProbeStage(trace);
    auto session = sessionFor(tool);
    auto panel = new PropertyPanel();
    auto ui = openPanel(() { panel.drawProvider(stage, session); });
    scope (exit) ui.close();

    auto epochBefore = stage.slotEpoch;
    ui.frame();
    ui.dragRow(1, 90.0f, 3);
    assert(stage.slotEpoch == epochBefore + 1,
        "one three-motion legacy slot drag must publish one slot epoch; got "
      ~ to!string(stage.slotEpoch - epochBefore));
}
