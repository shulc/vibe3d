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
    import std.file : readText;
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

    // The admission stands in main BEFORE the first build, kill or launch:
    // a refusal must cost nothing. Floor: main and every seam are found.
    {
        import std.string : indexOf;
        const mainAt = run.indexOf("int main(string[] args) {");
        assert(mainAt >= 0, "run.d main not found");
        const body_ = run[mainAt .. $];
        const admitAt = body_.indexOf("admitPerfPort(");
        assert(admitAt >= 0, "admitPerfPort( not found in run.d main");
        int seams;
        foreach (seam; ["dubBuildPerf(", "runFlameSubcommand(", "killStaleVibe(", "launchVibe("]) {
            const at = body_.indexOf(seam);
            assert(at >= 0, "run.d main no longer calls " ~ seam ~ " -- re-read this census");
            ++seams;
            assert(admitAt < at, "run.d main reaches " ~ seam
                ~ " before admitPerfPort(: a refused port would build/kill first");
        }
        assert(seams == 4, format("expected 4 seams after the admission, checked %d", seams));
    }

    // rdmd's only import root for run.d is tools/perf: lib.portpolicy reaches
    // tools.harness.runslots through this tracked symlink, or run.d stops compiling.
    {
        import std.file : exists, isSymlink, readLink;
        const link = buildPath(root, "tools", "perf", "tools", "harness", "runslots.d");
        assert(exists(link) && isSymlink(link) && readLink(link) == "../../../harness/runslots.d",
            "tools/perf/tools/harness/runslots.d must be the symlink to tools/harness/runslots.d");
    }

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
    static assert(!__traits(compiles, { auto p = admitPerfPort(kPerfDefaultPort, false); p.tupleof[0] = 8088; }),
        "an admitted PerfPort's value must not be writable through .tupleof");
    static assert(!__traits(compiles, { auto p = admitPerfPort(kPerfDefaultPort, false);
                                        __traits(getMember, p, "value_") = 8088; }),
        "an admitted PerfPort's value must not be writable through getMember");
    static assert(!__traits(compiles, { auto p = admitPerfPort(kPerfDefaultPort, false);
                                        p = admitPerfPort(8088, true); }),
        "a held PerfPort must not be reassignable");
    // Positive control: an admitted port is accepted by both seams.
    static assert(__traits(compiles, killStaleVibe(admitPerfPort(kPerfDefaultPort, false))));
    static assert(__traits(compiles, launchVibe(admitPerfPort(kPerfDefaultPort, false), "", "")));
}

// The spellings that make or rewrite a PerfPort behind admitPerfPort and that
// the type itself cannot refuse (`immutable value_` refuses .tupleof and
// getMember WRITES; `@disable this()` refuses arrays and unions). Read over the
// RAW text: blankNonCode blanks the string a mixin compiles. Each hit is the
// spelling found; `.init` is admitted only on the named non-PerfPort types.
private string[] perfPortForgeries(string src) {
    import std.ascii : isAlphaNum, isWhite;
    import std.string : strip;
    static immutable string[] initAllowed = ["LayerInfo", "RunSlot"];
    bool idc(char c) { return c == '_' || isAlphaNum(c); }
    ptrdiff_t prevNonWhite(ptrdiff_t k) {
        while (k >= 0 && isWhite(src[k])) --k;
        return k;
    }
    string[] hits;
    size_t i;
    while (i < src.length) {
        if (!idc(src[i]) || (i > 0 && idc(src[i - 1]))) { ++i; continue; }
        size_t e = i;
        while (e < src.length && idc(src[e])) ++e;
        const id = src[i .. e];
        const p = prevNonWhite(cast(ptrdiff_t) i - 1);
        if (id == "tupleof" || id == "getMember" || id == "mixin")
            hits ~= id;
        else if (id == "void" && p >= 0 && src[p] == '='
                 && !(p > 0 && "=!<>".canFind(src[p - 1])))
            hits ~= "= void";
        else if (id == "init" && p >= 0 && src[p] == '.') {
            ptrdiff_t q = prevNonWhite(p - 1), qs = q;
            while (qs >= 0 && idc(src[qs])) --qs;
            const owner = q >= 0 ? src[qs + 1 .. q + 1] : "";
            if (!initAllowed.canFind(owner))
                hits ~= (owner.length ? owner : src[q .. q + 1]) ~ ".init";
        } else if (id == "cast") {
            size_t o = e;
            while (o < src.length && isWhite(src[o])) ++o;
            if (o < src.length && src[o] == '(') {
                size_t c = o;
                while (c < src.length && src[c] != ')') ++c;
                const t = src[o + 1 .. c].strip;
                if (t.canFind("PerfPort")) hits ~= "cast(PerfPort";
                else if (t.length && t[$ - 1] == '*') hits ~= "pointer cast";
            }
        }
        i = e;
    }
    return hits;
}

// Census: no tools/perf source forges a PerfPort. Order: the probe's positive
// control (each forgery the type cannot refuse is SEEN, and the admitted
// spellings are not), then the census over every file, then its floors.
unittest {
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, dirName;

    // Must stay green: each spelling below is found by the probe. These are
    // the forgeries that compile against PerfPort (reviewer probes 2026-10-02).
    static immutable string[2][] forged = [
        ["auto p = cast(PerfPort) admitPerfPort(1,false);", "cast(PerfPort"],
        ["auto q = PerfPort.init;", "PerfPort.init"],
        ["auto p = typeof(admitPerfPort(1,false)).init;", ").init"],
        [`PerfPort p = mixin("PerfPort.init");`, "mixin"],
        ["ushort x = 8088; PerfPort p = *cast(PerfPort*)&x;", "cast(PerfPort"],
        ["PerfPort p = void;", "= void"],
        ["*cast(ushort*)&p = 8088;", "pointer cast"],
        ["p.tupleof[0] = 8088;", "tupleof"],
        [`__traits(getMember, p, "value_") = 8088;`, "getMember"],
    ];
    foreach (f; forged) {
        const h = perfPortForgeries(f[0]);
        assert(h.canFind(f[1]), format(
            "census probe is blind to `%s`: expected spelling %s, saw %s", f[0], f[1], h));
    }
    // Complement: admitted spellings are not hits (a probe that flags
    // everything would make the census below red on correct code).
    foreach (ok; ["PerfPort port = admitPerfPort(p, false);", "return LayerInfo.init;",
                  "s = RunSlot.init;", "if (a == void)", "cast(ushort) 8079", "mixing"])
        assert(perfPortForgeries(ok).length == 0, format(
            "census probe flags the admitted spelling `%s`: %s", ok, perfPortForgeries(ok)));

    // Must redden on any forgery spelled into tools/perf.
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    int files, allowedInits;
    foreach (e; dirEntries(buildPath(root, "tools", "perf"), "*.d", SpanMode.depth)) {
        ++files;
        const src = readText(e.name);
        const h = perfPortForgeries(src);
        assert(h.length == 0, format(
            "%s forges a PerfPort behind admitPerfPort: %s", e.name, h));
        import std.string : count;
        allowedInits += cast(int) (src.count("LayerInfo.init") + src.count("RunSlot.init"));
    }
    // Floors, measured 2026-10-03: `find -L tools/perf -name '*.d' | wc -l`
    // -> 12; the admitted `.init` spellings occur 3 times (run.d 2, runslots 1).
    assert(files >= 12, format("tools/perf census read only %d .d files", files));
    assert(allowedInits == 3, format(
        "admitted .init spellings: expected 3, found %d -- re-read initAllowed", allowedInits));
}
