#!/usr/bin/env rdmd
// MODO vs vibe3d geometry comparison orchestrator.
//
// Usage:
//   ./run.d                            # all cases under cases/
//   ./run.d poly_bevel_top_face_inset_extrude   # one case
//   ./run.d --keep                     # leave vibe3d running after
//   ./run.d --no-build                 # skip dub build
//   ./run.d -j N                       # accepted for run_all.d compat but
//                                      # capped at 1 — concurrent modo_cl
//                                      # processes share a single Nexus
//                                      # cache and only one of N produces
//                                      # output. The 30s suite is short
//                                      # enough that serial is fine; for
//                                      # long-lived MODO parallelism use
//                                      # tools/modo_diff/run_acen_drag.py
//                                      # which keeps one MODO per worker
//                                      # alive across cases.
//
// For each case <name>.json:
//   1. dub build (once, unless --no-build)
//   2. Start vibe3d --test --http-port 18081 in background
//   3. Run modo_cl with modo_dump.py → /tmp/modo_diff/<name>.modo.json
//   4. Run vibe3d_dump.d (shared with blender_diff) → /tmp/modo_diff/<name>.vibe3d.json
//   5. Run diff.py (shared with blender_diff) and report
//
// Required env (defaults if unset):
//   MODO_BIN              = /home/ashagarov/Program/Modo902/modo_cl
//   MODO_LD_LIBRARY_PATH  = /home/ashagarov/.local/lib
//   MODO_NEXUS_CONTENT    = /home/ashagarov/.luxology/Content
// (Override via the environment if your install lives elsewhere.)
//
// Cases for this suite are in tools/modo_diff/cases/. Supported ops on
// the MODO side: polygon_bevel, move_vertex, delete, remove. Cases that
// use unsupported ops (e.g. `bevel` for edge bevel) will ERROR.
//
// Exit code: number of failing cases (FAIL + XPASS + ERROR).

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
string blenderToolDir;       // for shared vibe3d_dump.d + diff.py
string casesDir;
string outDir;
int    basePort = 18081;     // distinct from blender_diff (18080) so both
                             // suites can co-exist on the same machine.
                             // Worker N uses port basePort + N.

string modoBin;
string modoLd;
string modoContent;

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

enum Status { PASS, FAIL, XFAIL, XPASS, ERROR }

struct CaseResult { string name; Status status; }

// Runs modo_cl with the dump script via a shell pipe. modo_cl reads its
// command list from stdin; we feed `@<script>` (loads the Python file)
// then `app.quit`.
//
// modo_cl forks a `foundrycrashhandler` daemon that inherits the parent's
// stdout/stderr fds and stays alive after modo_cl exits. If we let
// executeShell capture stdout via a pipe, that pipe remains open as long
// as the crash handler holds it — leading to a deadlock where the parent
// reads forever waiting for EOF. The fix: redirect modo_cl's output to a
// regular file so the inherited fd is non-blocking. Detached handlers
// just keep the file fd; the shell exits cleanly.
int runModoDump(string casePath, string outPath, string logPath) {
    import std.format : format;
    string scriptPath = toolDir.buildPath("modo_dump.py");
    string clOutPath  = logPath ~ ".stdout";
    string cmd = format!("LD_LIBRARY_PATH=%s NEXUS_CONTENT=%s "
                       ~ "MODO_CASE_PATH=%s MODO_OUT_PATH=%s MODO_LOG_PATH=%s "
                       ~ "%s")(
        modoLd, modoContent, casePath, outPath, logPath, modoBin);
    string fullCmd = format!"printf '@%s\\napp.quit\\n' | %s > %s 2>&1"(
        scriptPath, cmd, clOutPath);
    auto r = executeShell(fullCmd);
    // The Python script's success is determined by whether out.json exists
    // and is non-empty. modo_cl always exits 0 even on Python errors.
    if (!outPath.exists || getSize(outPath) == 0) {
        stderr.writeln("modo_dump produced no output. modo_cl stdout:");
        if (clOutPath.exists) stderr.writeln(readText(clOutPath));
        if (logPath.exists) {
            stderr.writeln("dump.log:");
            stderr.writeln(readText(logPath));
        }
        return 1;
    }
    return 0;
}

// Per-case work — runs MODO dump + vibe3d dump and diffs them.
// Concurrency: each parallel worker calls this with its own `port` and
// `dumpBin`. modoBin is invoked via shell — modo_cl is a fresh process
// per case so no shared state across cases. Output goes to
// /tmp/modo_diff/<case>.{modo,vibe3d}.json — case names are unique.
// Stdout is buffered into `outBuf` and printed atomically post-join.
CaseResult runCase(string casePath, int port, string dumpBin,
                   string diffScript, ref string outBuf) {
    auto name = casePath.baseName.stripExtension;
    auto modoOut    = outDir.buildPath(name ~ ".modo.json");
    auto vibe3dOut  = outDir.buildPath(name ~ ".vibe3d.json");
    auto modoLog    = outDir.buildPath(name ~ ".modo.log");

    // Wipe any prior output so a failed dump doesn't pass a stale file.
    if (modoOut.exists) remove(modoOut);

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

    int mrc = runModoDump(casePath, modoOut, modoLog);
    if (mrc != 0) return CaseResult(name, Status.ERROR);

    auto vres = execute([dumpBin,
                         casePath, vibe3dOut, "--port", port.to!string]);
    if (vres.status != 0) {
        outBuf ~= vres.output ~ "\n";
        return CaseResult(name, Status.ERROR);
    }
    foreach (line; vres.output.split("\n"))
        if (line.startsWith("[vibe3d_dump]")) outBuf ~= "  " ~ line ~ "\n";

    auto dres = execute(["python3", diffScript,
                         modoOut, vibe3dOut, "--case", casePath]);
    outBuf ~= dres.output;

    bool diffOk = (dres.status == 0);
    Status s;
    if (expectedFail) s = diffOk ? Status.XPASS : Status.XFAIL;
    else              s = diffOk ? Status.PASS  : Status.FAIL;
    return CaseResult(name, s);
}

int main(string[] args) {
    auto thisFile = __FILE__;
    toolDir        = thisFile.dirName.absolutePath;
    repoRoot       = toolDir.dirName.dirName;
    blenderToolDir = repoRoot.buildPath("tools", "blender_diff");
    casesDir       = toolDir.buildPath("cases");
    outDir         = "/tmp/modo_diff";
    if (!outDir.exists) mkdirRecurse(outDir);

    modoBin     = environment.get("MODO_BIN",
                                   "/home/ashagarov/Program/Modo902/modo_cl");
    modoLd      = environment.get("MODO_LD_LIBRARY_PATH",
                                   "/home/ashagarov/.local/lib");
    modoContent = environment.get("MODO_NEXUS_CONTENT",
                                   "/home/ashagarov/.luxology/Content");

    if (!modoBin.exists) {
        stderr.writeln("MODO_BIN not found: ", modoBin);
        stderr.writeln("Set MODO_BIN env var to your modo_cl path.");
        return 1;
    }

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
            int requested = args[++i].to!int;
            if (requested < 1) { stderr.writeln("-j must be >= 1"); return 2; }
            // Concurrent modo_cl invocations race on the shared Nexus
            // cache and most fail with empty output. Until/unless we
            // run each worker against a per-worker NEXUS_CONTENT, cap
            // -j at 1. Accepting the flag keeps run_all.d's interface
            // simple (it passes -j N to every suite uniformly).
            j = 1;
            if (requested > 1)
                log(format!"-j %d requested but capped at 1 (modo_cl race; see header comment)"(requested));
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

    // Pre-compile vibe3d_dump.d (shared with blender_diff) — same race
    // hazard as in tools/blender_diff/run.d when -j > 1 hits rdmd's
    // shared cache.
    string dumpBin = outDir.buildPath("vibe3d_dump");
    if (j > 1 || !dumpBin.exists) {
        log("compiling vibe3d_dump…");
        auto cr = execute(["rdmd", "--build-only", "-of=" ~ dumpBin,
                           blenderToolDir.buildPath("vibe3d_dump.d")]);
        if (cr.status != 0) { stderr.writeln(cr.output); return cr.status; }
    }

    // Kill any stale vibe3d --test on our port range.
    foreach (i; 0 .. j) {
        spawnShell(format!"pkill -f 'vibe3d --test --http-port %d' >/dev/null 2>&1; true"
                   (basePort + i)).wait();
    }
    Thread.sleep(200.msecs);

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

    string[][] perWorker;
    perWorker.length = j;
    foreach (i, c; cases) perWorker[i % j] ~= c;

    CaseResult[][] perWorkerResults;
    perWorkerResults.length = j;
    string[] perWorkerOutput;
    perWorkerOutput.length = j;

    string diffScript = blenderToolDir.buildPath("diff.py");

    foreach (wi, ref slice; parallel(perWorker, 1)) {
        int port = basePort + cast(int)wi;
        foreach (c; slice) {
            if (!c.exists) {
                perWorkerOutput[wi] ~= "case not found: " ~ c ~ "\n";
                perWorkerResults[wi] ~= CaseResult(c.baseName.stripExtension, Status.ERROR);
                continue;
            }
            string buf;
            auto r = runCase(c, port, dumpBin, diffScript, buf);
            perWorkerOutput[wi] ~= buf;
            perWorkerResults[wi] ~= r;
        }
    }
    foreach (wi; 0 .. j) write(perWorkerOutput[wi]);

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
    return fail + xpass + err;
}
