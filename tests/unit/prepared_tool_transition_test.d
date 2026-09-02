module unit.prepared_tool_transition_test;

import prepared_tool_effect;
import prepared_tool_transition;
import change_bus : ChangeBus, PreparedDeliveryJournal, PreparedDeliverySpec,
                    PreparedMeshSubjectOwner;
import command_history : CommandHistory, HistoryEntry, HistoryFlags;
import tool : Tool;
import registry : ToolFactory;

unittest {
    static assert(isPreparedField!PreparedToolEffect);
    static assert(!isPreparedField!(ubyte[]));
    static assert(!isPreparedField!(int*));
    static assert(!isPreparedField!(void delegate()));
    static assert(!isPreparedField!Object);
}

private class CountingPreparedTool : Tool {
    static int destroyed;
    ~this() { ++destroyed; }
}

unittest {
    CountingPreparedTool.destroyed = 0;
    PreparedCandidateOwner owner;
    auto first = new CountingPreparedTool;
    auto second = new CountingPreparedTool;
    owner.prepare(first, null);
    owner.prepare(second, null);
    assert(CountingPreparedTool.destroyed == 1,
           "repeated candidate prepare leaked its replaced candidate");
    ToolFactory failing = () { throw new Exception("prepare failed"); };
    try owner.prepareFrom(failing, null);
    catch (Exception) {}
    assert(owner.preparedCandidate() is second,
           "failed replacement discarded the previously prepared candidate");
    owner.discardCandidate();
    assert(CountingPreparedTool.destroyed == 2,
           "candidate discard did not run the terminal disposer exactly once");
}

unittest {
    auto history = new CommandHistory;
    HistoryEntry lifecycle = { label: "prepared", flags:
        HistoryFlags.Undoable | HistoryFlags.ToolLifecycle };
    auto image = history.prepareLifecycleAppend(lifecycle);
    history.installPreparedImage(image);
    assert(history.toolLifecycleCount() == 1,
           "prepared history install did not append its lifecycle row");
    assert(!history.canRedo(),
           "prepared lifecycle append did not invalidate redo");
}

unittest {
    auto anchor1 = new Object(), anchor2 = new Object();
    auto owner1 = new PreparedMeshSubjectOwner(anchor1, 11, 101);
    auto owner2 = new PreparedMeshSubjectOwner(anchor2, 22, 202);
    auto rows = [PreparedDeliverySpec(owner1, owner1.issue(), 3, 1),
                 PreparedDeliverySpec(owner2, owner2.issue(), 8, 4)];
    auto journal = PreparedDeliveryJournal.prepare(rows);
    rows[0].flags = 99; // post-prepare alias mutation cannot affect owner copy
    ChangeBus bus;
    size_t[] subjects; uint[] flags; uint[] domains;
    bus.onMeshChanged((size_t s, uint f) nothrow { subjects ~= s; flags ~= f; });
    bus.onSelectionChanged((uint d) nothrow { domains ~= d; });
    journal.replay(bus);
    assert(subjects.length == 2,
           "prepared journal lost/coalesced a delivery");
    assert(subjects == [11, 22] && flags == [3, 8] && domains == [1, 4],
           "prepared journal changed subject/flags/domain order");

    bool refused;
    try PreparedDeliveryJournal.prepare([
        PreparedDeliverySpec(owner1, owner2.issue(), 1, 0)]);
    catch (Exception) refused = true;
    assert(refused, "a token issued by another owner was accepted");
    auto generationOwner = new PreparedMeshSubjectOwner(new Object(), 33, 303);
    auto stale = PreparedDeliveryJournal.prepare([
        PreparedDeliverySpec(generationOwner, generationOwner.issue(), 1, 0)]);
    assert(stale.validate());
    generationOwner.issue();
    assert(!stale.validate(), "a superseded subject generation stayed valid");
}
