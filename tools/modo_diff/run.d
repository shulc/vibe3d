#!/usr/bin/env rdmd
// MODO vs vibe3d geometry comparison orchestrator.
//
// Usage:
//   ./run.d                            # all cases under cases/, single worker
//   ./run.d -j 4                       # 4 parallel workers (4 modo_cl + 4 vibe3d)
//   ./run.d poly_bevel_top_face_inset_extrude   # one case
//   ./run.d --keep                     # leave vibe3d / MODO running after
//   ./run.d --no-build                 # skip dub build
//
// Architecture:
//   - One long-lived modo_cl driven via its own stdin pipe. Spawning a
//     fresh modo_cl per case spent ~2-3s on startup; keeping it alive
//     moves that cost out of the inner loop. Net win: ~3 s → ~0.5 s per
//     case in our test runs, even at -j 1.
//   - For each case we pipe `@modo_dump.py <case> <out> <log>\n` into
//     the worker's stdin and wait for <out> to appear. modo_dump.py
//     reads positionals via lx.args() so each invocation gets its own
//     fresh paths (older env-var path retained for one-shot use).
//
// `-j N` is accepted for `run_all.d` interface compatibility but capped
// at 1. Despite per-worker $HOME isolation (Content split out of
// .luxology, see boot()), parallel modo_cl instances still hang on
// some MODO-internal lock (license / X11 / inter-process state we
// haven't pinned down). For long-lived parallel MODO use
// tools/modo_diff/run_acen_drag.py — its Xvfb-per-worker approach
// works because each modo_cl thinks it's in a different X session.
//
// For each case <name>.json:
//   1. Worker pipes @modo_dump.py into its modo_cl
//   2. Worker waits for /tmp/modo_diff/<name>.modo.json
//   3. Worker calls vibe3d_dump (precompiled) → /tmp/modo_diff/<name>.vibe3d.json
//   4. Worker calls diff.py and records the verdict
//
// Required env (defaults if unset):
//   MODO_BIN              = /home/ashagarov/Program/Modo902/modo_cl
//   MODO_LD_LIBRARY_PATH  = /home/ashagarov/.local/lib
//   MODO_NEXUS_CONTENT    = /home/ashagarov/.luxology/Content
// (Override via the environment if your install lives elsewhere.)
//
// Cases live in tools/modo_diff/cases/. Supported ops on the MODO side:
// polygon_bevel, move_vertex, delete, remove. Cases that use unsupported
// ops will ERROR.
//
// Exit code: number of failing cases (FAIL + XPASS + ERROR).

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
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

// ---- ModoWorker: long-lived modo_cl driven via its stdin pipe -------
//
// Boots once, processes many cases via repeated @modo_dump.py invocations,
// then exits via `app.quit` on shutdown. mirrors tools/modo_diff/
// run_acen_drag.py's Worker class — two key differences:
//   - We don't need Xvfb (modo_dump runs entirely headless).
//   - We don't need xdotool (we feed Python scripts via stdin, no GUI
//     interaction).
struct ModoWorker {
    int id;
    int port;                       // vibe3d HTTP port
    Pid procId;
    Pipe stdinPipe;
    File modoLog;
    string clOutPath;               // modo_cl combined stdout/stderr log

    void boot() {
        clOutPath = outDir.buildPath(format!"modo_cl_%d.log"(id));
        modoLog = File(clOutPath, "w");

        // Per-worker private $HOME — concurrent modo_cl instances
        // sharing $HOME/.luxology/{Configs,Cache,...} race on the
        // Configs/{tool,view}.cfg locks at boot and on per-script
        // bytecode cache writes during execution. The fix:
        //   1. .luxology has been split — Content (~4 GB of read-only
        //      assets) lives at /home/$USER/luxology_content, with a
        //      symlink at $REAL_HOME/.luxology/Content pointing at it.
        //      The "small" $REAL_HOME/.luxology is now ~700 KB.
        //   2. Each worker gets a fresh $HOME=/tmp/modo_worker_<id>
        //      and we cp -a $REAL_HOME/.luxology into it. cp -a
        //      preserves the Content symlink, so all workers share the
        //      bulk content read-only while keeping their own
        //      Configs/Scripts/Kits dirs.
        // No unshare / overlayfs / chroot needed — pure $HOME redirect.
        string realHome = environment.get("HOME", "");
        if (realHome.length == 0)
            throw new Exception("HOME env var is required");
        string workerHome = format!"/tmp/modo_worker_%d"(id);
        string workerLux  = workerHome ~ "/.luxology";
        if (workerHome.exists) rmdirRecurse(workerHome);
        mkdirRecurse(workerHome);
        // Use cp -a (recursive, preserves perms+symlinks). Fast since
        // .luxology is small after the Content split.
        auto cp = execute(["cp", "-a", realHome ~ "/.luxology", workerLux]);
        if (cp.status != 0)
            throw new Exception("worker " ~ id.to!string ~
                " .luxology copy failed: " ~ cp.output);

        string[string] env;
        env["LD_LIBRARY_PATH"] = modoLd;
        env["NEXUS_CONTENT"]   = modoContent;
        env["HOME"]            = workerHome;
        // Carry over PATH + USER so modo_cl finds python and reports
        // the right uid in any user-facing strings.
        foreach (k; ["PATH", "USER"]) {
            string v = environment.get(k, "");
            if (v.length) env[k] = v;
        }

        stdinPipe = pipe();
        procId = spawnProcess(
            [modoBin],
            stdinPipe.readEnd, modoLog, modoLog,
            env, Config.none);

        // Give modo_cl a moment to come up before we start firing
        // commands — without this the first @script can race the
        // interpreter's startup.
        Thread.sleep(500.msecs);
    }

    // Fire one case at the worker's modo_cl. Blocks until <outPath>
    // appears and is non-empty (modo_dump.py is the only writer of that
    // file, so a non-zero size means the script ran to completion).
    int runCase(string casePath, string outPath, string logPath,
                int timeoutMs = 30_000)
    {
        // Wipe any prior output so a stale file from a previous run
        // doesn't masquerade as success.
        if (outPath.exists) remove(outPath);

        // Fire the @ load. lx.args() picks up the three positionals.
        string scriptPath = toolDir.buildPath("modo_dump.py");
        string cmd = format!"@%s %s %s %s\n"(
            scriptPath, casePath, outPath, logPath);
        stdinPipe.writeEnd.write(cmd);
        stdinPipe.writeEnd.flush();

        // Poll for the out file. modo_dump.py writes it via a single
        // open(...).write(...) at the end, so any non-zero size is the
        // final result — no half-written file race.
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < timeoutMs) {
            // Detect modo_cl crash early.
            auto pres = tryWait(procId);
            if (pres.terminated) {
                stderr.writeln("[w", id, "] modo_cl exited unexpectedly (status ",
                    pres.status, "). Last 20 lines of ", clOutPath, ":");
                if (clOutPath.exists) {
                    auto lines = readText(clOutPath).split("\n");
                    foreach (line; lines[$ > 20 ? $ - 20 : 0 .. $])
                        stderr.writeln("  ", line);
                }
                return 1;
            }
            if (outPath.exists && getSize(outPath) > 0) return 0;
            Thread.sleep(50.msecs);
        }
        stderr.writeln("[w", id, "] timeout waiting for ", outPath);
        return 1;
    }

    void shutdown() {
        if (procId is null) return;
        try {
            stdinPipe.writeEnd.write("app.quit\n");
            stdinPipe.writeEnd.flush();
            stdinPipe.writeEnd.close();
        } catch (Exception) {}
        // Give modo_cl a brief grace period; if it doesn't quit cleanly
        // we kill it.
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < 3000) {
            auto pres = tryWait(procId);
            if (pres.terminated) return;
            Thread.sleep(50.msecs);
        }
        try { kill(procId); wait(procId); }
        catch (Exception) {}
    }
}

// Per-case work — runs MODO dump (via worker) + vibe3d dump + diff.
// Concurrency: each parallel worker calls this with its own ModoWorker
// and `port`. Output goes to /tmp/modo_diff/<case>.{modo,vibe3d}.json
// (case names are unique). Stdout buffered into `outBuf` and printed
// atomically post-join so logs don't interleave.
CaseResult runCase(ref ModoWorker w, string casePath, int port,
                   string dumpBin, string diffScript, ref string outBuf)
{
    auto name = casePath.baseName.stripExtension;
    auto modoOut    = outDir.buildPath(name ~ ".modo.json");
    auto vibe3dOut  = outDir.buildPath(name ~ ".vibe3d.json");
    auto modoLog    = outDir.buildPath(name ~ ".modo.log");

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

    int mrc = w.runCase(casePath, modoOut, modoLog);
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
            // See header comment — concurrent modo_cl deadlocks on
            // something internal even with per-worker $HOME isolation.
            // Cap at 1 and warn so run_all.d's uniform `-j N` plumbing
            // still works.
            j = 1;
            if (requested > 1)
                log(format!"-j %d requested but capped at 1 (modo_cl parallel hang; see header)"(requested));
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

    // Pre-compile vibe3d_dump.d to a single binary — same race fix as
    // tools/blender_diff/run.d (concurrent rdmd hits a shared cache).
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

    // Boot N modo_cl workers. Boot is sequential — concurrent first-run
    // initialisation of `~/.luxology/Cache/` was the root cause of the
    // earlier short-lived parallel attempt's race; staggering the boots
    // 0.5s apart is enough to let each finish its cache warm-up before
    // the next one touches the directory.
    auto workers = new ModoWorker[j];
    foreach (i; 0 .. j) {
        workers[i].id   = cast(int)i;
        workers[i].port = basePort + cast(int)i;
        log(format!"booting modo_cl worker %d…"(i));
        workers[i].boot();
    }
    scope(exit) {
        if (!keep) {
            foreach (i; 0 .. j) workers[i].shutdown();
        } else {
            log(format!"--keep: %d modo_cl instances still running"(j));
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
            auto r = runCase(workers[wi], c, port, dumpBin, diffScript, buf);
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
