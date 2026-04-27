#!/usr/bin/env rdmd
// Blender vs vibe3d geometry comparison orchestrator.
//
// Usage:
//   ./run.d                            # all cases under cases/
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
int    httpPort = 18080;

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

struct CaseResult { string name; bool ok; int exitCode; }

CaseResult runCase(string casePath) {
    auto name = casePath.baseName.stripExtension;
    auto blenderOut = outDir.buildPath(name ~ ".blender.json");
    auto vibe3dOut  = outDir.buildPath(name ~ ".vibe3d.json");

    log("=== " ~ name ~ " ===");

    auto bres = execute(["blender", "--background", "--python",
                         toolDir.buildPath("blender_dump.py"),
                         "--", casePath, blenderOut]);
    if (bres.status != 0) {
        stderr.writeln(bres.output);
        return CaseResult(name, false, bres.status);
    }

    auto vres = execute(["rdmd", toolDir.buildPath("vibe3d_dump.d"),
                         casePath, vibe3dOut, "--port", httpPort.to!string]);
    if (vres.status != 0) {
        stderr.writeln(vres.output);
        return CaseResult(name, false, vres.status);
    }
    // vibe3d_dump prints a one-line summary; surface it.
    foreach (line; vres.output.split("\n"))
        if (line.startsWith("[vibe3d_dump]")) writeln("  ", line);

    auto dres = execute(["python3", toolDir.buildPath("diff.py"),
                         blenderOut, vibe3dOut, "--case", casePath]);
    write(dres.output);
    return CaseResult(name, dres.status == 0, dres.status);
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

    // Kill any stale vibe3d --test on our port.
    spawnShell("pkill -f 'vibe3d --test' >/dev/null 2>&1; true").wait();
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
            results ~= CaseResult(c.baseName.stripExtension, false, 2);
            continue;
        }
        results ~= runCase(c);
    }

    writeln("\n─────────────────────────────────────");
    int fails = 0;
    foreach (r; results) {
        writefln("  %s  %s", r.ok ? "OK  " : "FAIL", r.name);
        if (!r.ok) fails++;
    }
    writefln("Total: %d  Passed: %d  Failed: %d",
        results.length, results.length - fails, fails);
    return fails;
}
