#!/usr/bin/env rdmd
// MODO vs vibe3d geometry comparison orchestrator.
//
// Usage:
//   ./run.d                            # all cases under cases/
//   ./run.d poly_bevel_top_face_inset_extrude   # one case
//   ./run.d --keep                     # leave vibe3d running after
//   ./run.d --no-build                 # skip dub build
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
// Cases for this suite are in tools/modo_diff/cases/. Currently only
// `polygon_bevel` ops are supported on the MODO side; cases that use
// `bevel` (edge bevel) etc. will ERROR.
//
// Exit code: number of failing cases (FAIL + XPASS + ERROR).

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.file;
import std.json;
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
int    httpPort = 18081;     // distinct from blender_diff (18080) so both
                             // suites can co-exist on the same machine

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

CaseResult runCase(string casePath) {
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
        stderr.writeln("case JSON parse error: ", e.msg);
        return CaseResult(name, Status.ERROR);
    }

    log("=== " ~ name ~ (expectedFail ? " [expected_fail]" : "") ~ " ===");

    int mrc = runModoDump(casePath, modoOut, modoLog);
    if (mrc != 0) return CaseResult(name, Status.ERROR);

    auto vres = execute(["rdmd", blenderToolDir.buildPath("vibe3d_dump.d"),
                         casePath, vibe3dOut, "--port", httpPort.to!string]);
    if (vres.status != 0) {
        stderr.writeln(vres.output);
        return CaseResult(name, Status.ERROR);
    }
    foreach (line; vres.output.split("\n"))
        if (line.startsWith("[vibe3d_dump]")) writeln("  ", line);

    auto dres = execute(["python3", blenderToolDir.buildPath("diff.py"),
                         modoOut, vibe3dOut, "--case", casePath]);
    write(dres.output);

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
    string[] selected;
    foreach (i; 1 .. args.length) {
        if (args[i] == "--keep") keep = true;
        else if (args[i] == "--no-build") doBuild = false;
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

    // Kill any stale vibe3d --test on our port (don't conflict with
    // blender_diff which uses 18080).
    spawnShell("pkill -f 'vibe3d --test --http-port " ~ httpPort.to!string
               ~ "' >/dev/null 2>&1; true").wait();
    Thread.sleep(200.msecs);

    auto vibeLog = outDir.buildPath("vibe3d.log");
    log("starting vibe3d --test --http-port " ~ httpPort.to!string
        ~ " (log: " ~ vibeLog ~ ")");
    auto logFile = File(vibeLog, "w");
    auto vibePid = spawnProcess(
        [repoRoot.buildPath("vibe3d"), "--test",
         "--http-port", httpPort.to!string],
        std.stdio.stdin, logFile, logFile,
        null, Config.none, repoRoot);
    scope(exit) {
        if (!keep) {
            kill(vibePid);
            wait(vibePid);
        } else {
            log("--keep: vibe3d still running on :" ~ httpPort.to!string);
        }
    }

    if (!waitForServer("http://localhost:" ~ httpPort.to!string ~ "/api/model")) {
        stderr.writeln("vibe3d HTTP server didn't come up");
        return 1;
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

    CaseResult[] results;
    foreach (c; cases) {
        if (!c.exists) {
            stderr.writeln("case not found: ", c);
            results ~= CaseResult(c.baseName.stripExtension, Status.ERROR);
            continue;
        }
        results ~= runCase(c);
    }

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
