module vibe3d.editing.commands.runtime.tests.unit.command_registry_test;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.commands.runtime.command_registry : CommandFactory, CommandRegistry;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.params.params : Param;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.viewport.camera.view : View;
import std.algorithm : sort;
import std.stdio : writeln;

private class ProbeCommand : Command {
    private Mesh mesh_;
    private View view_;
    private string id_;
    private int count_ = 5;
    this(string id) {
        view_ = new View(0, 0, 32, 32);
        super(&mesh_, view_, EditMode.Polygons);
        id_ = id;
    }
    override string name() const { return id_; }
    SelType observedType() { return currentType(); }
    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }
    override Param[] params() {
        return [Param.int_("count", "Count", &count_, 5)
            .min(1).max(64).enforceBounds()];
    }
    override bool needsEditTarget() const { return true; }
    override bool discardsUnsavedWork() const { return true; }
}

private void expectError(void delegate() operation, string message) {
    bool threw;
    try { operation(); }
    catch (Exception e) {
        threw = true;
        assert(e.msg == message, "command registry changed an error message: " ~ e.msg);
    }
    assert(threw, "command registry accepted a refused operation: " ~ message);
}

unittest {
    CommandRegistry reg;
    CommandFactory factory = () => new ProbeCommand("one");
    expectError(() => reg.registerCommand("one", null),
        "registry: command 'one' has a null factory");
    reg.registerCommand("one", factory);
    expectError(() => reg.registerCommand("one", factory),
        "registry: command 'one' is already registered");
    expectError(() => reg.replaceCommand("one", null),
        "registry: command 'one' has a null factory");
    expectError(() => reg.replaceCommand("missing", factory),
        "registry: command 'missing' is not registered");
    expectError(() => reg.aliasCommand("missing", "alias"),
        "registry: command 'missing' is not registered");
    expectError(() => reg.aliasCommand("one", "one"),
        "registry: command 'one' is already registered");
    assert(reg.makeCommand("missing") is null && !reg.hasCommand("missing"),
        "command registry unknown id must be absent");
    // An unknown-id lookup does not construct and cannot trip the late-bind latch.
    reg.bindSelTypeAuthority(() => SelType.Polygon);
    auto original = new ProbeCommand("one");
    auto replacement = new ProbeCommand("one");
    reg.replaceCommand("one", () => original);
    reg.aliasCommand("one", "alias");
    reg.replaceCommand("one", () => replacement);
    auto ids = reg.commandIds();
    ids.sort;
    assert(ids == ["alias", "one"] && reg.hasCommand("alias"),
        "command registry alias population");
    assert(reg.makeCommand("one") is replacement
        && reg.makeCommand("alias") is original,
        "command registry alias must retain the factory at alias time");
}

unittest {
    CommandRegistry late;
    late.registerCommand("early", () => new ProbeCommand("early"));
    assert(late.makeCommand("early") !is null, "late-authority population");
    expectError(() => late.bindSelTypeAuthority(() => SelType.Item),
        "registry: 1 command(s) were constructed before the selection-type authority "
        ~ "was bound — they carry currentType()'s fallback. Move the bind "
        ~ "above the first construction (task 6510).");
}

unittest {
    SelType live = SelType.Polygon;
    CommandRegistry reg;
    reg.bindSelTypeAuthority(() => live);
    size_t[string] constructions;
    reg.registerCommand("first", () {
        ++constructions["first"];
        return new ProbeCommand("first");
    });
    reg.registerCommand("second", () {
        ++constructions["second"];
        return new ProbeCommand("second");
    });
    auto command = cast(ProbeCommand)reg.makeCommand("first");
    assert(command !is null && command.observedType() == SelType.Polygon,
        "registry-authority: real makeCommand initially observes Polygon");
    constructions = null;
    reg.cacheSupportedModes();
    assert(constructions.length == 2 && constructions["first"] == 1
        && constructions["second"] == 1,
        "command metadata must construct each id exactly once");
    assert(reg.commandModes.length == 2 && reg.commandNames.length == 2
        && reg.commandParamsJson.length == 2 && reg.commandNeedsTarget.length == 2
        && reg.commandDiscardsWork.length == 2
        && reg.commandDropsToolBeforeApply.length == 2
        && reg.commandCommitsToolEditBeforeApply.length == 2,
        "command metadata population must include all seven maps");
    assert(reg.commandModes["first"] == [EditMode.Polygons]
        && reg.commandNames["first"] == "first"
        && reg.commandNeedsTarget["first"] && reg.commandDiscardsWork["first"],
        "command metadata must preserve declarations");
    import std.json : parseJSON;
    const schema = parseJSON(reg.commandParamsJson["first"]);
    assert(schema.array.length == 1 && schema[0]["name"].str == "count"
        && schema[0]["min"].integer == 1 && schema[0]["max"].integer == 64,
        "command metadata must preserve parameter schema");
    CommandRegistry unwired;
    unwired.registerCommand("control", () => new ProbeCommand("control"));
    auto control = cast(ProbeCommand)unwired.makeCommand("control");
    assert(control.observedType() == SelType.Polygon,
        "registry-authority: unwired control uses derived Polygon fallback");
    live = SelType.Item;
    assert(control.observedType() == SelType.Polygon,
        "registry-authority: Item differs from the unwired control");
    assert(command.editModeVal() == EditMode.Polygons,
        "registry-authority: live Item transition must leave derived EditMode.Polygons unchanged");
    assert(command.observedType() == SelType.Item,
        "registry-authority: constructed command must follow live Polygon to Item after cache");
    auto later = cast(ProbeCommand)reg.makeCommand("second");
    assert(later.observedType() == SelType.Item,
        "registry-authority: subsequent constructions share the live provider");
    writeln("CORE-CELL passed=registry-authority");
}

unittest {
    CommandRegistry reg;
    reg.registerCommand("drifted", () => new ProbeCommand("unregistered"));
    expectError(() => reg.cacheSupportedModes(),
        "registry: command 'drifted' name() 'unregistered' is not a registered command key");
}
