#!/usr/bin/env rdmd
/**
 * vibe3d test runner.
 *
 *   ./run_test.d                     # all tests
 *   ./run_test.d bevel selection     # subset
 *   ./run_test.d -v test_bevel       # verbose output
 *   ./run_test.d --keep              # leave vibe3d running after the run
 *   ./run_test.d --no-build          # skip `dub build`
 */

module run_test;

import std.algorithm : canFind, sort;
import std.array     : array, appender;
import std.conv      : to;
import std.file      : exists, isFile, mkdirRecurse, rmdirRecurse,
                       dirEntries, SpanMode, tempDir, readText;
import std.format    : format;
import std.getopt    : getopt, config;
import std.path      : baseName, buildPath, stripExtension;
import std.process   : spawnProcess, spawnShell, wait, executeShell,
                       Config, Pid, ProcessException, environment;
import std.range     : empty;
import std.stdio     : writeln, writefln, write, stdin, stdout, stderr, File;
import std.string    : startsWith, endsWith, indexOf, splitLines, strip;

import core.thread        : Thread;
import core.time          : msecs, seconds, dur;
import core.stdc.stdlib   : exit;
import core.sys.posix.signal : signal, kill, SIGINT, SIGTERM, SIGKILL;
import core.sys.posix.unistd : isatty, STDOUT_FILENO;

// ---------------------------------------------------------------------------
// Lifecycle state — accessed by signal handler
// ---------------------------------------------------------------------------

__gshared int    vibePidId;     // 0 = nothing to kill
__gshared string scratchDir;
__gshared bool   keepVibe;
__gshared bool   useColor;

string col(string code, string s) {
    return useColor ? "\033[" ~ code ~ "m" ~ s ~ "\033[0m" : s;
}

string red   (string s) { return col("31", s); }
string green (string s) { return col("32", s); }
string yellow(string s) { return col("33", s); }
string dim   (string s) { return col("2",  s); }
string bold  (string s) { return col("1",  s); }

extern(C) void onSignal(int sig) nothrow @nogc @system {
    if (vibePidId != 0) kill(vibePidId, SIGKILL);
    import core.stdc.stdio : fputs, stderr;
    fputs("\ninterrupted\n", stderr);
    exit(130);
}

void cleanup() {
    if (vibePidId != 0 && !keepVibe) {
        try { kill(vibePidId, SIGTERM); } catch (Exception) {}
        // Give it ~500ms to exit cleanly, then SIGKILL.
        for (int i = 0; i < 10; ++i) {
            Thread.sleep(50.msecs);
            if (kill(vibePidId, 0) != 0) break;  // process gone
        }
        try { kill(vibePidId, SIGKILL); } catch (Exception) {}
        vibePidId = 0;
    }
    if (scratchDir.length && exists(scratchDir)) {
        try { rmdirRecurse(scratchDir); } catch (Exception) {}
    }
}

// ---------------------------------------------------------------------------
// Test discovery & name normalization
// ---------------------------------------------------------------------------

string normalize(string arg) {
    if (arg.startsWith("tests/") && arg.endsWith(".d")) return arg;
    if (arg.startsWith("test_"))                         return "tests/" ~ arg ~ ".d";
    return "tests/test_" ~ arg ~ ".d";
}

string[] resolveTests(string[] args) {
    string[] paths;
    if (args.empty) {
        foreach (e; dirEntries("tests", "test_*.d", SpanMode.shallow))
            paths ~= e.name;
        sort(paths);
        return paths;
    }
    foreach (a; args) {
        string p = normalize(a);
        if (!exists(p) || !isFile(p)) {
            stderr.writefln("no such test: %s (resolved %s)", a, p);
            exit(2);
        }
        paths ~= p;
    }
    return paths;
}

// ---------------------------------------------------------------------------
// Stale-process & port handling
// ---------------------------------------------------------------------------

void killStaleVibe(ushort port) {
    // pkill returns 1 if no matches — that's fine.
    executeShell("pkill -f 'vibe3d --test' 2>/dev/null");
    // Wait for the process to die.
    for (int i = 0; i < 20; ++i) {
        auto r = executeShell("pgrep -f 'vibe3d --test' >/dev/null");
        if (r.status != 0) break;
        Thread.sleep(100.msecs);
    }
    // Wait for the port itself to be free (TIME_WAIT can linger).
    string portCheck = format("ss -ltn 'sport = :%d' | tail -n +2 | grep -q .", port);
    for (int i = 0; i < 50; ++i) {
        auto r = executeShell(portCheck);
        if (r.status != 0) return;  // port free
        Thread.sleep(100.msecs);
    }
    stderr.writefln(red("warning: port %d still in use after 5s"), port);
}

// ---------------------------------------------------------------------------
// Build steps
// ---------------------------------------------------------------------------

bool dubBuild() {
    write("Building vibe3d... ");
    stdout.flush();
    auto r = executeShell("dub build 2>&1");
    if (r.status != 0) {
        writeln(red("FAIL"));
        writeln(r.output);
        return false;
    }
    writeln(green("OK"));
    return true;
}

string[] compileTests(string[] paths, string outDir) {
    writefln("Compiling %d test%s...", paths.length, paths.length == 1 ? "" : "s");
    string[] bins;
    foreach (p; paths) {
        string name = baseName(p).stripExtension;
        string of   = buildPath(outDir, name);
        auto cmd = format("dmd -unittest %s -w -of=%s 2>&1", p, of);
        auto r = executeShell(cmd);
        if (r.status != 0) {
            writeln("  ", red("FAIL  "), name);
            writeln(r.output);
            return null;
        }
        bins ~= of;
    }
    writeln("  ", green("OK"));
    return bins;
}

// ---------------------------------------------------------------------------
// vibe3d lifecycle
// ---------------------------------------------------------------------------

Pid startVibe(ushort port, string logPath) {
    auto logFile = File(logPath, "wb");
    string[] argv = ["./vibe3d", "--test", "--http-port", port.to!string];
    Pid pid;
    try {
        pid = spawnProcess(argv, stdin, logFile, logFile,
            null, Config.suppressConsole);
    } catch (ProcessException e) {
        stderr.writeln(red("failed to spawn vibe3d: "), e.msg);
        return null;
    }
    vibePidId = pid.processID;
    return pid;
}

bool waitForHttpReady(string logPath, ushort port) {
    // First wait for the bind to log "HTTP server started" (the listener is up).
    string needle = format("HTTP server started on port %d", port);
    bool listening;
    for (int i = 0; i < 100; ++i) {
        if (exists(logPath)) {
            try {
                auto f = File(logPath, "r");
                foreach (line; f.byLine())
                    if ((cast(string)line.idup).canFind(needle)) { listening = true; break; }
            } catch (Exception) {}
        }
        if (listening) break;
        Thread.sleep(100.msecs);
    }
    if (!listening) return false;
    // Listener is up, but the main thread may not have wired up the data
    // providers yet — poll /api/camera until it returns 200.
    string probe = format("curl -s -o /dev/null -w '%%{http_code}' " ~
                          "http://localhost:%d/api/camera", port);
    for (int i = 0; i < 100; ++i) {
        auto r = executeShell(probe);
        if (r.status == 0 && r.output.strip == "200") return true;
        Thread.sleep(100.msecs);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Test execution
// ---------------------------------------------------------------------------

struct TestResult {
    string name;
    bool   passed;
    string output;   // captured stdout+stderr (only kept on failure)
}

TestResult runOne(string bin, bool verbose) {
    TestResult r;
    r.name = baseName(bin);
    if (verbose) {
        auto pid = spawnProcess([bin]);
        r.passed = (wait(pid) == 0);
    } else {
        string outPath = bin ~ ".out";
        auto out_ = File(outPath, "wb");
        auto pid = spawnProcess([bin], stdin, out_, out_);
        int code = wait(pid);
        r.passed = (code == 0);
        out_.close();
        if (!r.passed) {
            try { r.output = readText(outPath); } catch (Exception) {}
        }
    }
    return r;
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

void printSummary(TestResult[] results) {
    int passed, failed;
    foreach (ref r; results) (r.passed ? passed : failed)++;

    writeln();
    writeln(dim("─────────────────────────────────────"));
    writefln("Total: %d  %s  %s",
        results.length,
        green(format("Passed: %d", passed)),
        failed == 0 ? dim("Failed: 0") : red(format("Failed: %d", failed)));

    if (failed > 0) {
        writeln();
        writeln(bold("Failed tests:"));
        foreach (ref r; results) {
            if (r.passed) continue;
            writeln("  - ", red(r.name));
            auto lines = r.output.splitLines;
            // Print only the assertion / exception preamble — usually the first
            // 4–6 lines hold the message and "----------------". The rest is
            // a stacktrace that adds noise.
            enum int budget = 8;
            foreach (i, line; lines) {
                if (i >= budget) {
                    writefln("      %s",
                        dim(format("… %d more line(s); rerun with -v for full output",
                            cast(int)(lines.length - budget))));
                    break;
                }
                writefln("      %s", line);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(string[] args) {
    bool verbose, noBuild, keep;
    ushort port = 8080;
    auto helpInfo = getopt(args,
        config.bundling,
        "v|verbose",  "stream test output instead of summarizing on failure", &verbose,
        "k|keep",     "leave vibe3d running after tests finish",              &keep,
        "no-build",   "skip `dub build`",                                     &noBuild,
        "p|port",     "HTTP port for vibe3d (default 8080)",                  &port);

    if (helpInfo.helpWanted) {
        writeln("usage: ./run_test.d [options] [test_name...]");
        writeln();
        writeln("Test names accept any of: bevel | test_bevel | tests/test_bevel.d");
        writeln();
        foreach (o; helpInfo.options)
            writefln("  %-20s %s", o.optShort ~ ", " ~ o.optLong, o.help);
        return 0;
    }

    keepVibe = keep;
    useColor = isatty(STDOUT_FILENO) != 0;

    signal(SIGINT,  &onSignal);
    signal(SIGTERM, &onSignal);
    scope(exit) cleanup();

    auto tests = resolveTests(args[1 .. $]);
    if (tests.empty) {
        writeln(yellow("no tests found"));
        return 0;
    }

    if (!noBuild && !dubBuild()) return 1;

    scratchDir = buildPath(tempDir(), "vibe3d-tests-" ~ environment.get("PPID", "0"));
    if (exists(scratchDir)) rmdirRecurse(scratchDir);
    mkdirRecurse(scratchDir);

    auto bins = compileTests(tests, scratchDir);
    if (bins is null) return 1;

    killStaleVibe(port);

    string logPath = buildPath(scratchDir, "vibe3d.log");
    writefln("Starting vibe3d on :%d ", port);
    auto pid = startVibe(port, logPath);
    if (pid is null) return 1;

    if (!waitForHttpReady(logPath, port)) {
        writeln(red("vibe3d failed to come up; tail of log:"));
        try { writeln(readText(logPath)); } catch (Exception) {}
        return 1;
    }

    writeln();
    TestResult[] results;
    foreach (b; bins) {
        auto r = runOne(b, verbose);
        writeln("  ", r.passed ? green("PASS") : red("FAIL"), "  ", r.name);
        stdout.flush();
        results ~= r;
    }

    printSummary(results);
    int failed = 0;
    foreach (ref r; results) if (!r.passed) failed++;
    return failed == 0 ? 0 : 1;
}
