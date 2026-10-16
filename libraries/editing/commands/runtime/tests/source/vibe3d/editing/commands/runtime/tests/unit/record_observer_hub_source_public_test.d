module vibe3d.editing.commands.runtime.tests.unit.record_observer_hub_source_public_test;

import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
import vibe3d.editing.commands.runtime.command_history : HistoryFlags;

unittest {
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true); hub.setTraceArmed(true);
    auto image = hub.prepareRecord("mesh.delete", 0, `{"seq":0}`);
    assert(hub.macroLength == 0 && hub.traceLength == 0);
    assert(hub.validates(image));
    hub.installPrepared(image);
    assert(hub.macroLength == 1 && hub.macroAt(0) == "mesh.delete");
    assert(hub.traceLength == 1 && hub.traceAt(0) == `{"seq":0}`);
    hub.installPrepared(image);
    assert(hub.macroLength == 1 && hub.traceLength == 1);

    auto inSession = hub.prepareRecord("tool.attr", HistoryFlags.InSession,
                                       `{"must":"not append"}`);
    hub.installPrepared(inSession);
    assert(hub.macroLength == 2 && hub.traceLength == 1);

    auto refire = hub.prepareRecord("refire", HistoryFlags.Refire, `{"must":"not append"}`);
    hub.installPrepared(refire);
    auto lifecycle = hub.prepareRecord("tool.set x off", HistoryFlags.ToolLifecycle,
                                       `{"must":"not append"}`);
    hub.installPrepared(lifecycle);
    auto emptyTrace = hub.prepareRecord("empty.trace", 0, null);
    hub.installPrepared(emptyTrace);
    assert(hub.macroLength == 5 && hub.traceLength == 1);

    hub.setMacroActive(false);
    foreach (i; 0 .. 501) {
        import std.conv : to;
        auto row = i.to!string;
        auto next = hub.prepareRecord("ignored", 0, row);
        hub.installPrepared(next);
    }
    assert(hub.traceLength == 500);
    assert(hub.traceAt(0) == "1");
    assert(hub.traceAt(499) == "500");

    auto other = new RecordObserverHub();
    auto wrong = hub.prepareRecord("wrong", 0);
    assert(!other.validates(wrong));
    other.installPrepared(wrong);
    assert(other.macroLength == 0);
}
