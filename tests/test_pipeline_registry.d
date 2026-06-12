// test_pipeline_registry.d — registry-capability unit test for
// `Pipeline.addStacked` / `findAllByTask` (source/toolpipe/pipeline.d).
//
// Pure-D unit test (no HTTP, no running vibe3d): builds tiny mock Stages and
// asserts the registry can hold and iterate MULTIPLE same-task stage
// INSTANCES (distinct ids), while the single/primary path (`add`,
// `findByTask`) is unchanged. This is the registry capability a later phase
// uses to stack falloff contributors; production still registers exactly one
// per task, so nothing here changes runtime behavior.
//
// Compiled by run_test.d's `dmd -unittest` against the prebuilt project lib;
// runs standalone (the unittest block runs before the empty main()). It uses a
// MINIMAL mock Stage subclass — it does NOT pull in any concrete stage so the
// test exercises only the registry primitives.

import std.algorithm : map, equal;
import std.array     : array;

import toolpipe.pipeline : Pipeline;
import toolpipe.stage    : Stage, TaskCode, ordWght;
import operator          : Operator, Task, VectorStack, PacketKind;

void main() {}

// ---------------------------------------------------------------------------
// Minimal mock: a Stage that also implements Operator so plug/evaluate is
// exercised. Configurable taskCode/id/ordinal; `ran` records that the slot
// walk reached this instance during an evaluate() pass.
// ---------------------------------------------------------------------------
private final class MockStage : Stage, Operator {
    private TaskCode code_;
    private string   id_;
    private ubyte    ord_;
    private Task     opTask_;
    bool ran = false;        // set true when evaluate(vts) reaches this op
    int  resetCount = 0;     // plug() calls reset() once on each plug

    this(TaskCode code, string id, ubyte ord, Task opTask) {
        code_ = code; id_ = id; ord_ = ord; opTask_ = opTask;
    }

    // --- Stage ---
    override TaskCode taskCode() const pure nothrow @nogc @safe { return code_; }
    override string   id()       const                          { return id_; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ord_; }

    // --- Operator ---
    override Task task() const { return opTask_; }
    override PacketKind[] requiredPackets() const { return []; }
    override void reset() { ran = false; resetCount++; }
    override bool evaluate(ref VectorStack vts) { ran = true; return true; }
}

unittest {
    // Register a primary Wght stage via add(), then two MORE same-task
    // instances via addStacked() — three same-task instances, distinct ids,
    // two of which share the same ordinal (so stable order matters).
    Pipeline pipe;
    auto primary = new MockStage(TaskCode.Wght, "falloff",   ordWght, Task.Wght);
    auto extra1  = new MockStage(TaskCode.Wght, "falloff#1", ordWght, Task.Wght);
    auto extra2  = new MockStage(TaskCode.Wght, "falloff#2", ordWght, Task.Wght);

    pipe.add(primary);
    pipe.addStacked(extra1);
    pipe.addStacked(extra2);

    // findAllByTask returns ALL three in pipeline (insertion-stable) order.
    auto hits = pipe.findAllByTask(TaskCode.Wght);
    assert(hits.length == 3, "findAllByTask must yield all three instances");
    assert(hits[0] is primary, "primary stays first (added first, stable sort)");
    assert(hits[1] is extra1,  "extra1 second");
    assert(hits[2] is extra2,  "extra2 third");

    // findByTask returns the PRIMARY (first) for backward compat.
    assert(pipe.findByTask(TaskCode.Wght) is primary,
           "findByTask must return the primary (first) instance");

    // findById resolves each unique id.
    assert(pipe.findById("falloff")   is primary);
    assert(pipe.findById("falloff#1") is extra1);
    assert(pipe.findById("falloff#2") is extra2);
    assert(pipe.findById("nope")      is null);

    // all() / allMut() include all three, in pipeline order.
    assert(pipe.all().length == 3);
    assert(pipe.allMut().length == 3);
    assert(pipe.all()[0] is primary);
    assert(pipe.allMut()[2] is extra2);

    // The slot-list plugged ALL three operators (add+plug(replace) seeds the
    // slot with the primary, each addStacked appends one more). An evaluate
    // pass walks the whole slot, so every mock records it ran.
    assert(pipe.operatorsInSlot(Task.Wght).length == 3,
           "all three operators plugged into the Wght slot");
    VectorStack vts;
    pipe.evaluate(vts);
    assert(primary.ran && extra1.ran && extra2.ran,
           "evaluate() must walk every plugged same-task operator");

    // Sanity: a task with nothing registered yields an empty set / null.
    assert(pipe.findAllByTask(TaskCode.Acen).length == 0);
    assert(pipe.findByTask(TaskCode.Acen) is null);
}

unittest {
    // Backward-compat negative control: add() alone (no addStacked) keeps the
    // single-slot-per-task semantics — re-adding the same task REPLACES.
    Pipeline pipe;
    auto first  = new MockStage(TaskCode.Wght, "falloff", ordWght, Task.Wght);
    auto second = new MockStage(TaskCode.Wght, "falloff", ordWght, Task.Wght);

    pipe.add(first);
    pipe.add(second);   // same task → replaces `first`

    assert(pipe.all().length == 1, "add() must not stack same-task stages");
    assert(pipe.findByTask(TaskCode.Wght) is second, "second replaced first");
    assert(pipe.findAllByTask(TaskCode.Wght).length == 1);
    assert(pipe.operatorsInSlot(Task.Wght).length == 1,
           "replace truncated the slot to a single operator");
}
