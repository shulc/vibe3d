#!/usr/bin/env rdmd
// Blender vs vibe3d geometry comparison orchestrator.
//
// Usage:
//   ./run.d                            # all cases under cases/, single worker
//   ./run.d -j 4                       # 4 parallel workers (4 vibe3d on 18080..18083)
//   ./run.d cube_corner_w02_s4         # one case
//   ./run.d --keep                     # leave vibe3d running after
//   ./run.d --no-build                 # skip dub build
//
// For each case <name>.json:
//   1. dub build (once, unless --no-build)
//   2. Start vibe3d --test --http-port 18080 in background
//   3. Run blender_dump.py → /tmp/vibe3d_diff/<name>.blender.json
//   4. Run vibe3d_dump.d  → /tmp/vibe3d_diff/<name>.vibe3d.json
//   5. Run diff.py and report
//
// Exit code: number of failing cases.

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.file;
import std.format : format;
import std.json;
import std.parallelism : parallel;
import std.path : absolutePath, baseName, buildPath, dirName, stripExtension;
import std.process;
import std.stdio;
import std.string : split, startsWith;
import core.thread : Thread;
import core.time : msecs, seconds;

string repoRoot;
string toolDir;
string casesDir;
string outDir;
int    basePort = 18080;

void log(string msg) { writeln("[run] ", msg); }

bool waitForServer(string url, int maxMs = 5000) {
    foreach (_; 0 .. maxMs / 100) {
        try {
            auto r = execute(["curl", "-sf", "-o", "/dev/null", url]);
            if (r.status == 0) return true;
        } catch (Exception) {}
        Thread.sleep(100.msecs);
    }
    return false;
}

// PASS  — diff agreed (within tolerance), case is not expected_fail.
// FAIL  — diff disagreed; this is a real regression.
// XFAIL — diff disagreed AND the case is marked expected_fail. Documents a
//         known feature gap; doesn't count toward the failure tally.
// XPASS — diff agreed but the case is marked expected_fail. Means the gap
//         is closed and the marker should be removed; counted as failure.
// ERROR — blender_dump or vibe3d_dump crashed before diff could run.
enum Status { PASS, FAIL, XFAIL, XPASS, ERROR }

struct CaseResult { string name; Status status; }

// Per-case work — runs one Blender + one vibe3d dump and diffs them.
// Concurrency: each parallel worker calls this with its own `port`, so
// concurrent runCase calls on different ports talk to disjoint vibe3d
// instances. Output (blender.json / vibe3d.json) goes under
// /tmp/vibe3d_diff/ keyed by case name — which is unique, so no
// per-worker tmpdir is needed. Stdout is buffered into `outBuf` and
// printed atomically at the end so logs don't interleave.
//
// `dumpBin` is the pre-compiled vibe3d_dump executable — see main()
// for why we don't `rdmd` it directly under -j > 1.
CaseResult runCase(string casePath, int port, string dumpBin,
                   string blenderDumpScript, string diffScript, ref string outBuf) {
    auto name = casePath.baseName.stripExtension;
    auto blenderOut = outDir.buildPath(name ~ ".blender.json");
    auto vibe3dOut  = outDir.buildPath(name ~ ".vibe3d.json");

    bool expectedFail = false;
    try {
        auto cj = parseJSON(readText(casePath));
        if ("expected_fail" in cj && cj["expected_fail"].type == JSONType.true_)
            expectedFail = true;
    } catch (Exception e) {
        outBuf ~= "case JSON parse error: " ~ e.msg ~ "\n";
        return CaseResult(name, Status.ERROR);
    }

    outBuf ~= "[run] === " ~ name ~ (expectedFail ? " [expected_fail]" : "") ~ " ===\n";

    auto bres = execute(["blender", "--background", "--python",
                         blenderDumpScript,
                         "--", casePath, blenderOut]);
    if (bres.status != 0) {
        outBuf ~= bres.output ~ "\n";
        return CaseResult(name, Status.ERROR);
    }

    auto vres = execute([dumpBin,
                         casePath, vibe3dOut, "--port", port.to!string]);
    if (vres.status != 0) {
        outBuf ~= vres.output ~ "\n";
        return CaseResult(name, Status.ERROR);
    }
    foreach (line; vres.output.split("\n"))
        if (line.startsWith("[vibe3d_dump]")) outBuf ~= "  " ~ line ~ "\n";

    auto dres = execute(["python3", diffScript,
                         blenderOut, vibe3dOut, "--case", casePath]);
    outBuf ~= dres.output;

    bool diffOk = (dres.status == 0);
    Status s;
    if (expectedFail) s = diffOk ? Status.XPASS : Status.XFAIL;
    else              s = diffOk ? Status.PASS  : Status.FAIL;
    return CaseResult(name, s);
}

int main(string[] args) {
    auto thisFile = __FILE__;
    toolDir  = thisFile.dirName.absolutePath;
    repoRoot = toolDir.dirName.dirName;
    casesDir = toolDir.buildPath("cases");
    outDir   = "/tmp/vibe3d_diff";
    if (!outDir.exists) mkdirRecurse(outDir);

    bool keep = false;
    bool doBuild = true;
    int  j = 1;
    string[] selected;
    for (size_t i = 1; i < args.length; ++i) {
        if (args[i] == "--keep") keep = true;
        else if (args[i] == "--no-build") doBuild = false;
        else if (args[i] == "-j" || args[i] == "--jobs") {
            if (i + 1 >= args.length) {
                stderr.writeln(args[i], " requires an integer argument");
                return 2;
            }
            j = args[++i].to!int;
            if (j < 1) { stderr.writeln("-j must be >= 1"); return 2; }
        }
        else if (args[i].startsWith("-")) {
            stderr.writeln("unknown flag: ", args[i]);
            return 2;
        } else selected ~= args[i];
    }

    if (doBuild) {
        log("dub build…");
        auto br = execute(["dub", "build"], null, Config.none, size_t.max, repoRoot);
        if (br.status != 0) { stderr.writeln(br.output); return br.status; }
    }

    // Pre-compile vibe3d_dump.d to a single binary. Using rdmd from
    // multiple parallel workers races the per-user rdmd cache (~/.dub
    // /cache and /tmp/.rdmd-*) and we get spurious "cannot find input
    // file" failures. One compile, N concurrent invocations of the
    // resulting binary — no shared mutable state.
    string dumpBin = outDir.buildPath("vibe3d_dump");
    if (j > 1 || !dumpBin.exists) {
        log("compiling vibe3d_dump…");
        auto cr = execute(["rdmd", "--build-only", "-of=" ~ dumpBin,
                           toolDir.buildPath("vibe3d_dump.d")]);
        if (cr.status != 0) {
            stderr.writeln(cr.output);
            return cr.status;
        }
    }

    string[] cases;
    if (selected.length) {
        foreach (s; selected)
            cases ~= casesDir.buildPath(s ~ ".json");
    } else {
        foreach (string p; dirEntries(casesDir, "*.json", SpanMode.shallow))
            cases ~= p;
        cases.sort();
    }
    if (j > cast(int)cases.length) j = cast(int)cases.length;
    if (j < 1) j = 1;

    // Kill any stale vibe3d --test on our port range.
    foreach (i; 0 .. j) {
        spawnShell(format!"pkill -f 'vibe3d --test --http-port %d' >/dev/null 2>&1; true"
                   (basePort + i)).wait();
    }
    Thread.sleep(200.msecs);

    // Boot N vibe3d instances on disjoint ports (basePort..basePort+j-1).
    Pid[] vibePids;
    foreach (i; 0 .. j) {
        int port = basePort + i;
        auto vibeLog = outDir.buildPath(format!"vibe3d_%d.log"(i));
        log(format!"starting vibe3d --test --http-port %d (log: %s)"(port, vibeLog));
        auto logFile = File(vibeLog, "w");
        vibePids ~= spawnProcess(
            [repoRoot.buildPath("vibe3d"), "--test",
             "--http-port", port.to!string],
            std.stdio.stdin, logFile, logFile,
            null, Config.none, repoRoot);
    }
    scope(exit) {
        if (!keep) {
            foreach (p; vibePids) { kill(p); wait(p); }
        } else {
            log(format!"--keep: %d vibe3d instances still running on :%d..%d"
                (j, basePort, basePort + j - 1));
        }
    }
    foreach (i; 0 .. j) {
        int port = basePort + i;
        if (!waitForServer(format!"http://localhost:%d/api/model"(port))) {
            stderr.writeln("vibe3d :", port, " didn't come up");
            return 1;
        }
    }

    // Distribute cases round-robin across workers; each worker's slice
    // runs serially on its own port. parallel() iterates worker slices
    // concurrently.
    string[][] perWorker;
    perWorker.length = j;
    foreach (i, c; cases) perWorker[i % j] ~= c;

    CaseResult[][] perWorkerResults;
    perWorkerResults.length = j;
    string[] perWorkerOutput;
    perWorkerOutput.length = j;

    // Snapshot tool paths into stack-locals — don't reach for the
    // module globals from within parallel iterations (D's `parallel`
    // doesn't isolate global state, and any subprocess that mutates
    // CWD could in principle race other workers' relative-path reads).
    string blenderDumpScript = toolDir.buildPath("blender_dump.py");
    string diffScript        = toolDir.buildPath("diff.py");

    foreach (wi, ref slice; parallel(perWorker, 1)) {
        int port = basePort + cast(int)wi;
        foreach (c; slice) {
            if (!c.exists) {
                perWorkerOutput[wi] ~= "case not found: " ~ c ~ "\n";
                perWorkerResults[wi] ~= CaseResult(c.baseName.stripExtension, Status.ERROR);
                continue;
            }
            string buf;
            auto r = runCase(c, port, dumpBin, blenderDumpScript, diffScript, buf);
            perWorkerOutput[wi] ~= buf;
            perWorkerResults[wi] ~= r;
        }
    }

    // Print per-worker output blocks atomically (worker order is stable).
    foreach (wi; 0 .. j) write(perWorkerOutput[wi]);

    // Flatten + sort results for deterministic summary regardless of j.
    CaseResult[] results;
    foreach (slice; perWorkerResults) results ~= slice;
    results.sort!((a, b) => a.name < b.name);

    writeln("\n─────────────────────────────────────");
    int[Status] tally;
    foreach (r; results) {
        string tag;
        final switch (r.status) {
            case Status.PASS:  tag = "PASS "; break;
            case Status.FAIL:  tag = "FAIL "; break;
            case Status.XFAIL: tag = "XFAIL"; break;
            case Status.XPASS: tag = "XPASS"; break;
            case Status.ERROR: tag = "ERROR"; break;
        }
        writefln("  %s  %s", tag, r.name);
        tally[r.status] = tally.get(r.status, 0) + 1;
    }
    int pass  = tally.get(Status.PASS,  0);
    int fail  = tally.get(Status.FAIL,  0);
    int xfail = tally.get(Status.XFAIL, 0);
    int xpass = tally.get(Status.XPASS, 0);
    int err   = tally.get(Status.ERROR, 0);
    writefln("Total: %d  Pass: %d  Fail: %d  XFail: %d  XPass: %d  Error: %d",
        results.length, pass, fail, xfail, xpass, err);
    // XPASS is a real failure (an expected_fail marker that needs removal).
    return fail + xpass + err;
}
