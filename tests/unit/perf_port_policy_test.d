// Witness for the perf harness port policy (task 9220): the harness clears
// any vibe3d on its port before launching, so its default must sit outside
// every run_test.d worker window, an explicit worker-window port is refused
// unless overridden, and the refusal stands before every kill. The windows are
// derived from tools.harness.runslots; the literals below are the measured
// values of that derivation on 2026-10-02 (kMaxRunSlots 6, stride 36,
// kPrivateFamilies 173), so a slot-layout change reddens here and is re-read.
module tests.unit.perf_port_policy_test;

import std.algorithm : canFind;
import std.exception : collectException;
import std.format : format;
import std.traits : Parameters;

import lib.lifecycle : killStaleVibe, launchVibe;
import lib.portpolicy;

// Floor: the derivation yields exactly the two worker families, at the
// measured bounds. Everything below reads these windows.
unittest {
    const rs = gateWorkerPortRanges();
    assert(rs.length == 2, format("expected 2 gate worker windows, got %d", rs.length));
    assert(rs[0].lo == 8080 && rs[0].hiExclusive == 8296,
        format("canonical worker window moved: [%d, %d)", rs[0].lo, rs[0].hiExclusive));
    assert(rs[1].lo == 28080 && rs[1].hiExclusive == 65448,
        format("private worker blocks moved: [%d, %d)", rs[1].lo, rs[1].hiExclusive));
}

// The default port is outside every worker window and every lane block, and
// the policy admits it without the override.
unittest {
    PortRange w;
    assert(!inGateWorkerWindow(kPerfDefaultPort, w), format(
        "default perf port %d is inside %s [%d, %d): a default perf run would "
        ~ "kill a gate worker", kPerfDefaultPort, w.owner, w.lo, w.hiExclusive));
    assert(!kLanePortBlocks.contains(kPerfDefaultPort), format(
        "default perf port %d is inside the task-lane blocks [%d, %d)",
        kPerfDefaultPort, kLanePortBlocks.lo, kLanePortBlocks.hiExclusive));
    assert(admitPerfPort(kPerfDefaultPort, false).value == kPerfDefaultPort);
}

// Refusal: every port at or inside a window edge is refused without the
// override; just outside, and a lane port, are admitted.
unittest {
    // Must stay green: admitted ports, including the override.
    foreach (ushort p; [cast(ushort) 8079, 8296, 8520, 28079, 65448]) {
        auto e = collectException!PerfPortRefused(admitPerfPort(p, false));
        assert(e is null, format(
            "port %d is outside every worker window and must be admitted: %s", p, e.msg));
        assert(admitPerfPort(p, false).value == p);
    }
    auto o = collectException!PerfPortRefused(admitPerfPort(8088, true));
    assert(o is null, "the override flag must admit a worker-window port: " ~ o.msg);
    assert(admitPerfPort(8088, true).value == 8088);

    // Must redden if the refusal is struck.
    const ushort[] refused = [8080, 8088, 8295, 28080, 65447];
    int n;
    foreach (p; refused) {
        auto e = collectException!PerfPortRefused(admitPerfPort(p, false));
        assert(e !is null, format(
            "port %d is a gate worker port and was ADMITTED without --%s",
            p, kAllowWorkerPortFlag));
        assert(e.msg.canFind(format("--http-port %d", p)) && e.msg.canFind(kAllowWorkerPortFlag),
            "refusal must name the port and the override flag: " ~ e.msg);
        ++n;
    }
    assert(n == 5, format("expected 5 refusal probes, ran %d", n));
}

// Production wiring census: the types below prove no kill without a PerfPort,
// but only run.d's main decides WHAT it passes to admitPerfPort and what it
// does on a refusal. run.d is an rdmd script outside this configuration, so
// its call text is read (code view: comments and literals blanked).
unittest {
    import std.array : join, split;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, dirName;
    import std.string : count;
    import tests.unit.census_symbols : blankNonCode;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    string norm(string s) { return s.split.join(" "); }
    const run = norm(blankNonCode(readText(buildPath(root, "tools", "perf", "run.d"))));

    assert(run.count("admitPerfPort(") == 1, format(
        "run.d must admit its port exactly once, found %d calls", run.count("admitPerfPort(")));
    assert(run.canFind("ushort portArg = kPerfDefaultPort;"),
        "run.d's --http-port default must be kPerfDefaultPort");
    assert(run.canFind("bool allowWorkerPort = false;") && run.count("&allowWorkerPort") == 1,
        "the override must default to false and be set only by its getopt flag");
    assert(run.canFind("try return admitPerfPort(portArg, allowWorkerPort);"),
        "run.d must admit the parsed port under the parsed override");
    assert(run.canFind("catch (PerfPortRefused e) { stderr.writeln( , e.msg); exit(2);"),
        "run.d must EXIT on a refusal, not continue to a kill");

    // No caller mints a PerfPort through its .init (port 0) behind the policy.
    int files;
    foreach (e; dirEntries(buildPath(root, "tools", "perf"), "*.d", SpanMode.depth)) {
        ++files;
        assert(!blankNonCode(readText(e.name)).canFind("PerfPort.init"),
            e.name ~ " mints a PerfPort through .init, bypassing admitPerfPort");
    }
    assert(files >= 12, format("tools/perf census read only %d .d files", files));
}

// Pin: the kill and launch seams take an admitted PerfPort, and a PerfPort
// cannot be made from a bare number outside lib.portpolicy -- so no port
// reaches killStaleVibe without passing admitPerfPort's refusal first.
unittest {
    static assert(is(Parameters!killStaleVibe[0] == PerfPort),
        "killStaleVibe must take a PerfPort, not a raw port");
    static assert(is(Parameters!launchVibe[0] == PerfPort),
        "launchVibe must take a PerfPort, not a raw port");
    static assert(!__traits(compiles, killStaleVibe(cast(ushort) 8088)));
    static assert(!__traits(compiles, PerfPort(cast(ushort) 8088)),
        "PerfPort must not be constructible outside lib.portpolicy");
    static assert(!__traits(compiles, cast(PerfPort) cast(ushort) 8088));
    static assert(!__traits(compiles, { PerfPort p; }),
        "PerfPort must not be default-constructible");
    // Positive control: an admitted port is accepted by both seams.
    static assert(__traits(compiles, killStaleVibe(admitPerfPort(kPerfDefaultPort, false))));
    static assert(__traits(compiles, launchVibe(admitPerfPort(kPerfDefaultPort, false), "", "")));
}
