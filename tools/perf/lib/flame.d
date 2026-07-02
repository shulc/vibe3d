module lib.flame;
// perf(1) record/attach/report choreography for the `flame` subcommand
// (task 0197 Phase 3) — absorbed from tools/perf_subpatch/run.d's
// perf-record-attach sequence, generalized to any ops case / frames
// scenario. Policy (WHICH case/scenario to profile, how to configure/drive
// it) stays in run.d's runFlameSubcommand; this module owns only the
// perf(1) process mechanics + the profile-fp build.

import std.array    : join;
import std.conv     : to;
import std.format   : format;
import std.process  : execute, executeShell, spawnProcess, wait, kill, Config,
                      Pid, ProcessException;
import std.stdio    : writeln, writefln, stderr, stdout;

import core.thread            : Thread;
import core.time              : dur;
import core.sys.posix.signal  : SIGINT;

import lib.lifecycle : LDC2;

// The flamegraph build MUST be optimized + un-instrumented: dub.json's
// "profile-fp" buildType (optimize + debugInfo + `-gs` frame pointers, NO
// PerfProbe version) — NOT `dubBuildPerf` (lib.lifecycle; that's the
// PerfProbe-instrumented build the `ops`/`frames` subcommands use, wrong
// tool for a flamegraph: the counters it adds are exactly the noise a
// flamegraph should not attribute to) and NOT a plain `dub build` (that's
// the debug/unoptimized config — bounds-checks + asserts stay ON, so the
// flamegraph localizes to bounds-check / un-inlined-wrapper noise instead
// of the real hot line; perf_subpatch/run.d:79's plain `dub build` for this
// exact attach path was a latent flaw this module does not inherit — see
// doc/perf_tooling_consolidation_plan.md R3/Phase 3).
//
// The exact command is ECHOED to stdout (containing the literal substring
// "--build=profile-fp") so a caller/test can grep stdout and confirm the
// right buildType actually ran, rather than trusting a green exit code that
// could just as well have come from the wrong (plain/debug) build.
//
// Uses the SAME pinned ldc2 binary as lib.lifecycle.dubBuildPerf (the `ops`/
// `frames` perf buildType) rather than a bare `--compiler=ldc2` PATH lookup
// — a bare lookup resolves to whatever "ldc2" happens to be on $PATH, which
// on a host with an older system ldc2 (no `-gs` frame-pointer flag support)
// fails outright; the pinned binary is the one actually validated against
// this dub.json's buildTypes.
bool dubBuildProfileFp(string repoRoot) {
    string[] cmd = ["dub", "build", "--build=profile-fp", "--compiler=" ~ LDC2,
                    "--root", repoRoot];
    writeln("Building vibe3d (profile-fp buildType, for `flame`): ", cmd.join(" "));
    stdout.flush();
    auto r = execute(cmd);
    if (r.status != 0) {
        writeln("FAIL");
        writeln(r.output);
        return false;
    }
    writeln("OK");
    return true;
}

bool perfAvailable() { return execute(["which", "perf"]).status == 0; }
bool stackcollapseAvailable() {
    return execute(["which", "stackcollapse-perf.pl"]).status == 0;
}

// Attach `perf record` to a LIVE vibe3d pid — carries perf_subpatch's exact
// recipe (`--call-graph dwarf`, run.d:170-176). Frequency is caller-
// configurable (`--freq`, default 999 to match perf_subpatch's default).
// Sleeps ~500ms after spawn: perf record needs a beat before it's actually
// sampling (perf_subpatch:194-196), so the caller's drag/scenario shouldn't
// start immediately after this returns.
Pid startPerfRecord(string perfData, int pid, int freq, string repoRoot) {
    string[] perfArgs = [
        "perf", "record",
        "--call-graph", "dwarf",
        "-F",           freq.to!string,
        "-o",           perfData,
        "-p",           pid.to!string,
    ];
    writefln("[flame] attaching: %s", perfArgs.join(" "));
    auto perfPid = spawnProcess(perfArgs, null, Config.none, repoRoot);
    Thread.sleep(dur!"msecs"(500));
    return perfPid;
}

void stopPerfRecord(Pid perfPid) {
    try kill(perfPid, SIGINT); catch (Exception) {}
    try wait(perfPid);          catch (Exception) {}
}

// Best-effort `perf report` + folded stacks (R4: degrade gracefully without
// `perf`/`stackcollapse-perf.pl` — `stackcollapse-perf.pl` absent ⇒ a raw
// `perf script` dump for later collation instead of folded stacks). Carries
// perf_subpatch's exact fallback (run.d:251-276).
void generateReports(string perfData, string perfTxt, string foldTxt) {
    {
        auto r = executeShell(format(
            "perf report --stdio --no-children -i %s > %s",
            shQuote(perfData), shQuote(perfTxt)));
        if (r.status != 0)
            stderr.writeln("[flame] perf report failed:\n", r.output);
    }
    {
        string cmd;
        if (stackcollapseAvailable()) {
            cmd = format("perf script -i %s | stackcollapse-perf.pl > %s",
                         shQuote(perfData), shQuote(foldTxt));
        } else {
            writeln("[flame] stackcollapse-perf.pl not on PATH — writing a "
                    ~ "raw `perf script` dump instead of folded stacks "
                    ~ "(install FlameGraph's stackcollapse-perf.pl to get " ~
                    "folded output directly).");
            cmd = format("perf script -i %s > %s",
                         shQuote(perfData), shQuote(foldTxt));
        }
        auto r = executeShell(cmd);
        if (r.status != 0)
            stderr.writeln("[flame] folded/script dump failed:\n", r.output);
    }
}

string shQuote(string s) { return "'" ~ s ~ "'"; }
