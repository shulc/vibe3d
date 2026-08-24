// Task 1904 Stage 6 (doc/subject_stage_plan.md §7) — a witness for
// `Pipeline.checkRequiredPackets` (source/toolpipe/pipeline.d). The
// enforcement itself landed earlier, in `246720c4` (2026-05-31, an
// earlier task); only this witness is Stage 6 (2026-08-25). The
// enforcement already fires `logWarnOnce("toolpipe", ...)` before every
// `op.evaluate`, in BOTH branches of `Pipeline.evaluate` (the timed
// branch, for a Task slot `perfCatFor` maps to a real perf category, and
// the untimed branch, for one it maps to -1) — but nothing observed it:
// `grep -rn 'requires packet\|checkRequiredPackets' tests/ source/
// --include=*.d | grep -v 'pipeline.d:'` returned nothing before this file.
//
// `Pipeline`'s own `TestOpStage` double (toolpipe/pipeline.d,
// `version (unittest)`) is `private` to that module and hardcodes
// `requiredPackets() -> []`, so it cannot stand in for this test — each
// case below carries its OWN local double with a real `requiredPackets()`.
//
// THREE DISTINCT OPERATOR TYPES, not three instances of one class. The
// de-spam gate in `checkRequiredPackets` is keyed by
// `typeid(op).name ~ "|" ~ kind.to!string` in a PROCESS-WIDE `bool[string]`
// (`log.g_seenOnce`), reset only by the test-only `resetLogForTest()`
// (source/log.d — made non-private for this Stage, still compiled only
// under `version (unittest)`). Reusing one class across cases would let a
// later case silently ride an earlier case's already-consumed key and pass
// for the wrong reason — the shape CLAUDE.md's "a check that cannot come
// out differently" section warns about. `resetLogForTest()` still runs at
// the top of every case for hygiene; the real guarantee against key
// collision is the distinct class per case.
module tests.unit.toolpipe.required_packets_witness_test;

import toolpipe.pipeline : Pipeline;
import toolpipe.stage    : Stage, TaskCode, ordAcen, ordWork;
import operator            : Operator, Task, VectorStack, PacketKind;
import toolpipe.packets    : FalloffPacket;
import log                  : snapshot, resetLogForTest, g_stderrMinLevel, LogLevel;

import std.algorithm : canFind, filter;
import std.array     : array;
import std.format    : format;

// ---------------------------------------------------------------------------
// Case A — Task.Acen, a slot `Pipeline.perfCatFor` maps to a REAL perf
// category (Cat.pipeAcen) — the TIMED branch of `Pipeline.evaluate`.
// ---------------------------------------------------------------------------
private final class WitnessCatBranch : Stage, Operator {
    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "witnessCatBranch"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }
    override void     reset() {}

    Task         task()            const { return Task.Acen; }
    PacketKind[] requiredPackets() const { return [PacketKind.Falloff]; }
    bool         evaluate(ref VectorStack vts) { return true; }
}

unittest {
    resetLogForTest();
    // This case deliberately provokes the WARNING `checkRequiredPackets`
    // logs — expected, asserted on below via `snapshot()`. Raise the
    // stderr floor so it doesn't also echo to the test-run console
    // (precedent: source/log.d's own unittests, e.g. around line 228).
    auto savedLevel = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error;
    scope(exit) g_stderrMinLevel = savedLevel;

    Pipeline p;
    auto op = new WitnessCatBranch();
    p.add(op);

    VectorStack vts; // no FalloffPacket published — the gap this warns about
    p.evaluate(vts);

    immutable opName = typeid(op).name;
    auto hits = snapshot().filter!(e => e.subsystem == "toolpipe"
        && e.msg.canFind(opName) && e.msg.canFind("Falloff")).array;
    assert(hits.length == 1, format(
        "§7 case A (Task.Acen, timed branch): expected exactly one "
        ~ "checkRequiredPackets warning naming %s and Falloff, got %d: %s",
        opName, hits.length, hits));
}

// ---------------------------------------------------------------------------
// Case B — Task.Work, a slot `Pipeline.perfCatFor` maps to -1 — the
// UNTIMED branch of `Pipeline.evaluate`. A distinct class from case A so
// the de-spam key cannot collide with it.
// ---------------------------------------------------------------------------
private final class WitnessNoCatBranch : Stage, Operator {
    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Work; }
    override string   id()       const                          { return "witnessNoCatBranch"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWork; }
    override void     reset() {}

    Task         task()            const { return Task.Work; }
    PacketKind[] requiredPackets() const { return [PacketKind.Falloff]; }
    bool         evaluate(ref VectorStack vts) { return true; }
}

unittest {
    resetLogForTest();
    // Same silencing as case A above — this case also provokes the
    // expected WARNING, asserted on below via `snapshot()`.
    auto savedLevel = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error;
    scope(exit) g_stderrMinLevel = savedLevel;

    Pipeline p;
    auto op = new WitnessNoCatBranch();
    p.add(op);

    VectorStack vts;
    p.evaluate(vts);

    immutable opName = typeid(op).name;
    auto hits = snapshot().filter!(e => e.subsystem == "toolpipe"
        && e.msg.canFind(opName) && e.msg.canFind("Falloff")).array;
    assert(hits.length == 1, format(
        "§7 case B (Task.Work, untimed branch): expected exactly one "
        ~ "checkRequiredPackets warning naming %s and Falloff, got %d: %s",
        opName, hits.length, hits));
}

// ---------------------------------------------------------------------------
// Case C — the required packet IS present. Proves the check reads the
// stack rather than warning unconditionally (§7 item 4's failure mode: an
// implementation that always warns would pass cases A/B for the right
// reason and this one for the wrong one). A third distinct class, again to
// keep the de-spam key isolated from A and B.
// ---------------------------------------------------------------------------
private final class WitnessPacketPresent : Stage, Operator {
    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "witnessPacketPresent"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }
    override void     reset() {}

    Task         task()            const { return Task.Acen; }
    PacketKind[] requiredPackets() const { return [PacketKind.Falloff]; }
    bool         evaluate(ref VectorStack vts) { return true; }
}

unittest {
    resetLogForTest();
    Pipeline p;
    auto op = new WitnessPacketPresent();
    p.add(op);

    FalloffPacket fp;
    VectorStack   vts;
    vts.put(&fp); // the packet requiredPackets() names IS on the stack

    p.evaluate(vts);

    immutable opName = typeid(op).name;
    auto hits = snapshot().filter!(e => e.subsystem == "toolpipe"
        && e.msg.canFind(opName)).array;
    assert(hits.length == 0, format(
        "§7 case C: packet present — checkRequiredPackets must NOT warn "
        ~ "for %s; an implementation that warns unconditionally would still "
        ~ "pass cases A/B (for the right reason) and only this case (for "
        ~ "the wrong one). got %d entries: %s", opName, hits.length, hits));
}
