#!/usr/bin/env rdmd
/**
 * vibe3d test runner.
 *
 *   ./run_test.d                     # all tests
 *   ./run_test.d bevel selection     # subset
 *   ./run_test.d -v test_bevel       # verbose output
 *   ./run_test.d --keep              # leave vibe3d running after the run
 *   ./run_test.d --no-build          # skip `dub build`
 *   ./run_test.d -j 4                # 4 parallel workers (each its own
 *                                      vibe3d instance on a private port)
 */

module run_test;

import std.algorithm : canFind, sort, each;
import std.array     : array, appender, replace, join;
import std.conv      : to;
// Import std.file fully so the per-worker scratch source-write can call
// `std.file.write` without colliding with the `write` from std.stdio.
static import std.file;
import std.file : exists, isFile, mkdirRecurse, rmdirRecurse,
                  dirEntries, SpanMode, tempDir, readText;
import std.format    : format;
import std.getopt    : getopt, config;
import std.parallelism : parallel, totalCPUs;
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

__gshared int[]  vibePids;     // worker PIDs to kill on signal / cleanup
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
    foreach (p; vibePids) if (p != 0) kill(p, SIGKILL);
    import core.stdc.stdio : fputs, stderr;
    fputs("\ninterrupted\n", stderr);
    exit(130);
}

void cleanup() {
    if (!keepVibe) {
        foreach (p; vibePids) {
            if (p == 0) continue;
            try { kill(p, SIGTERM); } catch (Exception) {}
        }
        // Give them ~500ms each to exit cleanly, then SIGKILL.
        for (int i = 0; i < 10; ++i) {
            Thread.sleep(50.msecs);
            bool anyAlive;
            foreach (p; vibePids) if (p != 0 && kill(p, 0) == 0) { anyAlive = true; break; }
            if (!anyAlive) break;
        }
        foreach (p; vibePids) {
            if (p == 0) continue;
            try { kill(p, SIGKILL); } catch (Exception) {}
        }
        vibePids = null;
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
    // pkill returns 1 if no matches — that's fine. We match by --http-port
    // arg so workers running on OTHER ports survive.
    auto pat = format("vibe3d --test --http-port %d", port);
    executeShell(format("pkill -f '%s' 2>/dev/null", pat));
    // Wait for the process to die.
    for (int i = 0; i < 20; ++i) {
        auto r = executeShell(format("pgrep -f '%s' >/dev/null", pat));
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

/// Compile each test in `paths` into `outDir`. Source is read AS-IS unless
/// `port` differs from 8080 — then literal "localhost:8080" is rewritten
/// to "localhost:<port>" in a per-test scratch copy. This keeps tests
/// portable to N parallel vibe3d instances without source changes.
string[] compileTests(string[] paths, string outDir, ushort port) {
    string[] bins;
    foreach (p; paths) {
        string name = baseName(p).stripExtension;
        string of   = buildPath(outDir, name);
        string src  = p;
        if (port != 8080) {
            string txt = readText(p)
                .replace("localhost:8080", "localhost:" ~ port.to!string);
            src = buildPath(outDir, name ~ ".d");
            std.file.write(src, txt);
        }
        auto cmd = format("dmd -unittest %s -w -of=%s 2>&1", src, of);
        auto r = executeShell(cmd);
        if (r.status != 0) {
            writeln("  ", red("FAIL  "), name);
            writeln(r.output);
            return null;
        }
        bins ~= of;
    }
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
    synchronized {
        vibePids ~= pid.processID;
    }
    return pid;
}

bool waitForHttpReady(string logPath, ushort port) {
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
// Worker: one vibe3d + a slice of tests
// ---------------------------------------------------------------------------

struct Worker {
    int      id;
    ushort   port;
    string[] tests;    // assigned source paths
    string[] bins;     // compiled binaries
    string   scratch;  // per-worker scratch dir
    string   logPath;
    Pid      vibePid;
}

bool prepareWorker(ref Worker w) {
    mkdirRecurse(w.scratch);
    w.bins = compileTests(w.tests, w.scratch, w.port);
    if (w.bins is null) return false;
    killStaleVibe(w.port);
    w.logPath = buildPath(w.scratch, "vibe3d.log");
    w.vibePid = startVibe(w.port, w.logPath);
    if (w.vibePid is null) return false;
    if (!waitForHttpReady(w.logPath, w.port)) {
        stderr.writefln(red("worker %d: vibe3d on :%d failed to come up"),
            w.id, w.port);
        try { stderr.writeln(readText(w.logPath)); } catch (Exception) {}
        return false;
    }
    return true;
}

TestResult[] runWorker(ref Worker w, bool verbose) {
    TestResult[] out_;
    foreach (b; w.bins) {
        auto r = runOne(b, verbose);
        synchronized {
            writeln("  ", r.passed ? green("PASS") : red("FAIL"),
                    "  ", dim(format("[w%d]", w.id)), "  ", r.name);
            stdout.flush();
        }
        out_ ~= r;
    }
    return out_;
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
    int j = 1;
    string[] exclude;
    auto helpInfo = getopt(args,
        config.bundling,
        "v|verbose",  "stream test output instead of summarizing on failure", &verbose,
        "k|keep",     "leave vibe3d running after tests finish",              &keep,
        "no-build",   "skip `dub build`",                                     &noBuild,
        "p|port",     "HTTP port for vibe3d (default 8080)",                  &port,
        "j|jobs",     "parallel workers — each runs its own vibe3d on a "
                    ~ "private port (default 1)",                             &j,
        "exclude",    "skip a test by name (repeatable). Same name forms as "
                    ~ "the positional args: bevel | test_bevel | tests/test_bevel.d", &exclude);

    if (helpInfo.helpWanted) {
        writeln("usage: ./run_test.d [options] [test_name...]");
        writeln();
        writeln("Test names accept any of: bevel | test_bevel | tests/test_bevel.d");
        writeln();
        foreach (o; helpInfo.options)
            writefln("  %-20s %s", o.optShort ~ ", " ~ o.optLong, o.help);
        return 0;
    }

    if (j < 1) {
        stderr.writeln(red("-j must be >= 1"));
        return 2;
    }
    keepVibe = keep;
    useColor = isatty(STDOUT_FILENO) != 0;

    signal(SIGINT,  &onSignal);
    signal(SIGTERM, &onSignal);
    scope(exit) cleanup();

    auto tests = resolveTests(args[1 .. $]);

    // --exclude removes any tests whose normalized path matches.
    if (!exclude.empty) {
        bool[string] excludeSet;
        foreach (e; exclude) excludeSet[normalize(e)] = true;
        string[] kept;
        foreach (t; tests) if (t !in excludeSet) kept ~= t;
        if (kept.length != tests.length) {
            writefln("excluding: %s", exclude.join(", "));
        }
        tests = kept;
    }

    if (tests.empty) {
        writeln(yellow("no tests found"));
        return 0;
    }

    if (!noBuild && !dubBuild()) return 1;

    scratchDir = buildPath(tempDir(), "vibe3d-tests-" ~ environment.get("PPID", "0"));
    if (exists(scratchDir)) rmdirRecurse(scratchDir);
    mkdirRecurse(scratchDir);

    // Cap workers at # of tests so we don't spin up empty vibe3d instances.
    if (j > cast(int)tests.length) j = cast(int)tests.length;

    // Build N workers, distribute tests round-robin.
    Worker[] workers;
    workers.length = j;
    foreach (i, ref w; workers) {
        w.id      = cast(int)i;
        w.port    = cast(ushort)(port + i);
        w.scratch = buildPath(scratchDir, format("worker_%d", i));
    }
    foreach (i, t; tests) workers[i % j].tests ~= t;

    // Prepare workers in parallel — compile tests + boot vibe3d. Each
    // worker's compile/boot is independent.
    writefln("Compiling %d test%s and booting %d vibe3d instance%s...",
        tests.length, tests.length == 1 ? "" : "s",
        j, j == 1 ? "" : "s");
    bool allUp = true;
    foreach (i, ref w; parallel(workers, 1)) {
        if (!prepareWorker(w)) {
            stderr.writefln(red("worker %d failed to prepare"), w.id);
            allUp = false;
        }
    }
    if (!allUp) return 1;
    writeln(green("  OK"));
    writeln();

    // Run each worker's slice in parallel (each on its own vibe3d).
    TestResult[][] perWorker;
    perWorker.length = workers.length;
    foreach (i, ref w; parallel(workers, 1)) {
        perWorker[i] = runWorker(w, verbose);
    }

    // Sort results by test name for deterministic summary output.
    TestResult[] results;
    foreach (slice; perWorker) results ~= slice;
    results.sort!((a, b) => a.name < b.name);

    printSummary(results);
    int failed = 0;
    foreach (ref r; results) if (!r.passed) failed++;
    return failed == 0 ? 0 : 1;
}
