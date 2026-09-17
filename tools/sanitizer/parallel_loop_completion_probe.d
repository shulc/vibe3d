/**
 * Reproducer for the std.parallelism completion edge used by Mesh.buildLoops.
 *
 * A single parallel-write/serial-read round is quiet and therefore cannot
 * witness task 6340. Repeating the shape over explicitly freed GC blocks makes
 * the allocator reuse addresses and exposes the missing TSan edge. The lane
 * runs `plain` and `annotated` in separate processes so one arm cannot poison
 * the other's shadow state.
 */
module tools.sanitizer.parallel_loop_completion_probe;

import core.memory : GC;
import std.parallelism : parallel;
import std.range : iota;
import std.stdio : writeln;

import tsan_annotate : parallelForWithCompletion;

enum size_t kRounds = 300;
enum size_t kItems = 4096;

__gshared ulong g_probeChecksum;

void runRound(size_t round, bool annotated) {
    auto raw = cast(uint*)GC.malloc(kItems * uint.sizeof, GC.BlkAttr.NO_SCAN);
    if (raw is null) throw new Exception("GC.malloc failed");
    auto words = raw[0 .. kItems];

    void writeOne(size_t idx) {
        words[idx] = cast(uint)(round * kItems + idx + 1);
    }

    if (annotated)
        parallelForWithCompletion!writeOne(words.length);
    else
        foreach (idx; parallel(iota(words.length))) writeOne(idx);

    ulong sum;
    foreach (word; words) sum += word;
    g_probeChecksum += sum;
    GC.free(raw);
}

int main(string[] args) {
    if (args.length != 2 || (args[1] != "plain" && args[1] != "annotated")) {
        writeln("usage: parallel_loop_completion_probe plain|annotated");
        return 2;
    }
    const annotated = args[1] == "annotated";
    foreach (round; 0 .. kRounds) runRound(round, annotated);
    writeln(args[1], ": rounds=", kRounds, " items=", kItems,
            " checksum=", g_probeChecksum);
    return 0;
}
