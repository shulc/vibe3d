module tests.unit.command_invocation_test;

import command : Command, CommandOrigin, CmdFlags, g_editTargetResolver;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import command_invocation;
import command_registry : CommandRegistry;
import vibe3d.editing.contracts.editmode : EditMode;
import falloff : IFalloffAware;
import toolpipe.packets : FalloffPacket;
import mesh : Mesh, makeCube, g_isDocumentMesh;
import vibe3d.editing.params.params : Param;
import pilot_command_registration;
import vibe3d.editing.contracts.seltype : SelType;
import view : View;
import math : Vec3;
import vibe3d.util.spatial.spatial : Viewport;
import vibe3d.mesh.change.change_bus : changeBus, ChangeBus;
import std.stdio : writeln;

private final class InvocationProbe : Command, IFalloffAware {
    int value;
    bool configured, expectsInteractive, succeeds = true, falloffSeen;
    size_t applies;
    this(Mesh* m, ref View v, bool query = false) {
        super(m, v, EditMode.Vertices);
        if (query) markQuery();
    }
    override string name() const { return "probe"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override bool acceptsQuery() const { return true; }
    override string queryResultJson() const { return `{"value":17}`; }
    override Param[] params() {
        assert(!expectsInteractive || configured,
            "invocation interactive hook must run before bindArgs");
        return [Param.int_("value", "Value", &value, 0)];
    }
    void setFalloff(FalloffPacket packet) { falloffSeen = true; }
    protected override bool applyImpl() {
        ++applies;
        if (succeeds) noteUndoRecorded();
        return succeeds;
    }
}

private CommandExecutor executor(CommandHistory h) {
    return new CommandExecutor(h, () => false,
        (transition) { assert(false, "invocation fixture cannot drop an armed tool"); });
}

unittest {
    const savedResolver = g_editTargetResolver;
    auto savedBus = changeBus;
    const savedFilter = g_isDocumentMesh;
    scope(exit) { g_editTargetResolver = savedResolver; changeBus = savedBus; g_isDocumentMesh = savedFilter; }
    g_editTargetResolver = null; changeBus = ChangeBus.init; g_isDocumentMesh = null;
    auto m = makeCube(); auto v = new View(0,0,1,1);
    auto h = new CommandHistory; h.clear();
    CommandRegistry registry;
    bool succeeds = true, query;
    InvocationProbe last;
    registry.registerCommand("probe", () {
        last = new InvocationProbe(&m, v, query); last.succeeds = succeeds; return cast(Command) last;
    });
    auto service = new CommandInvocationService(registry, executor(h), h);
    auto context = CommandInvocationContext(CommandOrigin.script, false);
    auto applied = service.invokeLine("probe", `{"value":23,"falloff":{"type":"none"}}`, context);
    assert(applied.outcome == CommandInvocationOutcome.applied && applied.command is last
        && last.origin == CommandOrigin.script && last.value == 23 && last.falloffSeen
        && last.applies == 1 && h.undoEntries().length == 1,
        "invocation applied must bind args/falloff and record exact one row");
    succeeds = false;
    auto refused = service.invokeLine("probe", "", context);
    assert(refused.outcome == CommandInvocationOutcome.refused && !refused.applied
        && last.applies == 1 && h.undoEntries().length == 1,
        "invocation script refusal must stay refused with unchanged history");
    query = true; succeeds = true;
    auto queried = service.invokeLine("probe", "", context);
    assert(queried.outcome == CommandInvocationOutcome.query && queried.applied
        && queried.queryJson == `{"value":17}` && last.applies == 1
        && h.undoEntries().length == 1, "invocation query must bypass history");
    bool missing;
    try service.invokeLine("missing", "", context);
    catch (Exception error) missing = error.msg == "unknown command id 'missing'";
    assert(missing, "invocation unknown id must preserve refusal text");
    writeln("CORE-CELL passed=invocation-outcomes");
}

unittest {
    auto m = makeCube(); auto v = new View(0,0,1,1);
    auto h = new CommandHistory; h.clear();
    CommandRegistry registry;
    bool query, succeeds = true, refires = true;
    size_t uiCalls, refireCalls, notices, interactiveCalls;
    InvocationProbe last;
    registry.registerCommand("probe", () {
        last = new InvocationProbe(&m, v, query);
        last.expectsInteractive = true; last.succeeds = succeeds; return cast(Command)last;
    });
    auto service = new CommandInvocationService(registry, executor(h), h,
        (Command c, string id) { ++refireCalls; assert(c is last && id == "probe"); return refires; },
        (Command c, RecordMode mode, string id) {
            ++uiCalls;
            assert(refireCalls == 2 && c is last && id == "probe" && mode == RecordMode.Coalescing,
                "invocation refire must precede UI policy");
            return CommandInvocationOutcome.deferred;
        },
        (Command c, bool interactive) {
            ++interactiveCalls;
            assert(c is last && interactive && c.origin == CommandOrigin.ui,
                "invocation origin must precede interactive configuration");
            last.configured = true;
        }, (Command c) { ++notices; assert(c is last); });
    auto context = CommandInvocationContext(CommandOrigin.ui, true);
    auto refired = service.invokeLine("probe", `{"value":9}`, context);
    assert(refired.outcome == CommandInvocationOutcome.applied && last.applies == 0
        && uiCalls == 0 && refireCalls == 1 && last.value == 9 && h.undoEntries().length == 0,
        "invocation refire must bypass UI and executor");
    refires = false;
    auto deferred = service.invokeLine("probe", `{"value":11}`, context);
    assert(deferred.outcome == CommandInvocationOutcome.deferred && !deferred.applied
        && uiCalls == 1 && refireCalls == 2 && last.applies == 0
        && last.value == 11 && h.undoEntries().length == 0,
        "invocation UI deferred must survive unchanged");
    query = true; succeeds = false;
    auto refusal = service.invokeLine("probe", "", context);
    assert(refusal.outcome == CommandInvocationOutcome.refused && notices == 1
        && last.applies == 1 && refireCalls == 2 && uiCalls == 1 && interactiveCalls == 3,
        "invocation UI query refusal must notice without dispatching");
    context.interactive = false;
    auto discreteQueryRefusal = service.invokeLine("probe", "", context);
    assert(discreteQueryRefusal.outcome == CommandInvocationOutcome.refused
        && !last.configured && interactiveCalls == 3 && notices == 2,
        "invocation noninteractive context must not configure interactive policy");
    auto scriptQueryRefusal = service.invokeLine("probe", "",
        CommandInvocationContext(CommandOrigin.script, false));
    assert(scriptQueryRefusal.outcome == CommandInvocationOutcome.refused
        && notices == 2 && interactiveCalls == 3 && refireCalls == 2 && uiCalls == 1,
        "invocation script query refusal must not invoke UI notice");
    auto noUi = new CommandInvocationService(registry, executor(h), h);
    bool required;
    try noUi.invokeLine("probe", "", context);
    catch (Exception error) required = error.msg == "UI invocation requires UI policy";
    assert(required, "invocation UI origin requires UI hook");
    writeln("CORE-CELL passed=invocation-order");
}

unittest {
    auto m = makeCube(); auto v = new View(0,0,1,1);
    auto h = new CommandHistory;
    CommandRegistry registry;
    bool query;
    registry.registerCommand("tool.pipe.attr", () => cast(Command)new InvocationProbe(&m, v, query));
    auto service = new CommandInvocationService(registry, executor(h), h,
        (Command c, string id) => true);
    auto context = CommandInvocationContext(CommandOrigin.script, false);
    const before = h.currentTweakGeneration();
    service.invokeLine("tool.pipe.attr", "", context);
    assert(h.currentTweakGeneration() == before + 1,
        "invocation discrete pipe tweak must advance generation");
    context.interactive = true;
    service.invokeLine("tool.pipe.attr", "", context);
    assert(h.currentTweakGeneration() == before + 1,
        "invocation continuous pipe tweak must retain generation");
    query = true; context.interactive = false;
    service.invokeLine("tool.pipe.attr", "", context);
    assert(h.currentTweakGeneration() == before + 1,
        "invocation query must return before tweak tail");
    writeln("CORE-CELL passed=invocation-tweak");
}

unittest {
    const savedResolver = g_editTargetResolver; auto savedBus = changeBus;
    const savedFilter = g_isDocumentMesh;
    scope(exit) { g_editTargetResolver = savedResolver; changeBus = savedBus; g_isDocumentMesh = savedFilter; }
    g_editTargetResolver = null; changeBus = ChangeBus.init; g_isDocumentMesh = null;
    auto a = makeCube(), b = makeCube(); Mesh* active = &a;
    auto firstView = new View(0,0,1,1), secondView = new View(0,0,2,2);
    View currentView = firstView;
    EditMode mode = EditMode.Vertices;
    SelType authority = SelType.Vertex;
    size_t promotions, topologyCalls;
    Viewport viewport; viewport.focus = Vec3(31,0,0);
    ref Mesh liveMesh() { return *active; }
    ref View liveView() { return currentView; }
    auto deps = PilotCommandDeps(cast(PilotMesh)&liveMesh, cast(PilotView)&liveView, &mode, () => viewport,
        (EditMode next) { ++promotions; mode = next; authority = SelType.Polygon; },
        () { ++topologyCalls; });
    auto h = new CommandHistory; h.clear(); CommandRegistry registry;
    registry.bindSelTypeAuthority(() => authority);
    registerTripleCommand(registry, deps);
    registerMeshSelectionCommand(registry, deps);
    registerHistoryNavigationCommands(registry, deps, h);
    assert(registry.commandIds().length == 4, "pilot registrar exact four-ID population");
    foreach (id; registry.commandIds()) {
        auto c = registry.makeCommand(id);
        assert(c.meshPtr() is &a && c.viewRef is firstView && c.editModeVal == EditMode.Vertices,
            "pilot registrar must resolve initial live data");
    }
    active = &b; currentView = secondView; mode = EditMode.Edges;
    foreach (id; registry.commandIds()) {
        auto c = registry.makeCommand(id);
        assert(c.meshPtr() is &b && c.viewRef is secondView && c.editModeVal == EditMode.Edges,
            "pilot registrar must resolve changed live data");
    }
    auto service = new CommandInvocationService(registry, executor(h), h);
    auto context = CommandInvocationContext(CommandOrigin.script, false);
    assert(service.invokeLine("mesh.select", `{"mode":"polygons","indices":[0]}`, context).applied,
        "pilot selection must apply");
    assert(promotions == 1 && mode == EditMode.Polygons && authority == SelType.Polygon
        && b.selectedFaces[0], "pilot selection must promote geometry type and select");
    assert(service.invokeLine("mesh.triple", "", context).applied
        && b.faces.length == 7 && a.faces.length == 6 && topologyCalls == 1,
        "pilot triple must use live target and topology capability");
    assert(service.invokeLine("history.undo", "", context).applied && b.faces.length == 6,
        "pilot undo must navigate same history");
    assert(service.invokeLine("history.redo", "", context).applied && b.faces.length == 7,
        "pilot redo must navigate same history");
    writeln("CORE-CELL passed=pilot-live");
}


unittest { // Required collaborators are rejected at lower service construction.
    import core.exception : AssertError;
    CommandRegistry registry;
    auto history = new CommandHistory;
    bool executorRequired, historyRequired;
    try new CommandInvocationService(registry, null, history);
    catch (AssertError error) executorRequired = true;
    assert(executorRequired, "invocation lower constructor requires executor");
    try new CommandInvocationService(registry, executor(history), null);
    catch (AssertError error) historyRequired = true;
    assert(historyRequired, "invocation lower constructor requires history");
}
