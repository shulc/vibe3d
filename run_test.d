#!/usr/bin/env rdmd
/**
 * vibe3d test runner.
 *
 *   ./run_test.d                     # all tests
 *   ./run_test.d bevel selection     # subset
 *   ./run_test.d -v test_bevel       # verbose output
 *   ./run_test.d --keep              # leave vibe3d running after the run
 *   ./run_test.d --no-build          # skip `dub build`
 *   ./run_test.d -j N                # override the worker count (each worker
 *                                      gets its own vibe3d on a private port)
 *
 * With no -j the worker count auto-scales: clamp(totalCPUs/4, 4, 12), or the
 * VIBE3D_TEST_JOBS env var when set. An explicit -j always wins.
 */

module run_test;

import std.algorithm : canFind, sort, each, map, sum, minIndex;
import std.array     : array, appender, replace, join;
import std.conv      : to, octal;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.json      : JSONValue, parseJSON, JSONType;
import std.math      : isNaN;
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
import core.sys.posix.unistd : isatty, STDOUT_FILENO, close, getpid, ftruncate;
import core.sys.posix.fcntl  : open, O_RDWR, O_CREAT;
import core.sys.posix.sys.types : ssize_t;

// flock(2) is not surfaced by this druntime's posix bindings; declare it.
extern(C) int flock(int fd, int operation) nothrow @nogc;
pragma(mangle, "write")
extern(C) ssize_t c_write(int fd, const(void)* buf, size_t count) nothrow @nogc;
enum LOCK_EX = 2;   // exclusive lock
enum LOCK_NB = 4;   // non-blocking
enum LOCK_UN = 8;   // unlock

// ---------------------------------------------------------------------------
// Lifecycle state — accessed by signal handler
// ---------------------------------------------------------------------------

__gshared int[]  vibePids;     // worker PIDs to kill on signal / cleanup
__gshared ushort g_attachPort; // --attach: drive an already-running endpoint
                               // (e.g. the visual_test_proxy) instead of
                               // spawning our own vibe3d. 0 = normal mode.
__gshared string scratchDir;
__gshared bool   keepVibe;
__gshared bool   useColor;
__gshared int    runLockFd = -1;  // held for the whole run; see acquireRunLock
__gshared string projLibPath;  // prebuilt project test-lib (see buildProjectLib); "" => -i fallback
__gshared string moldFlag;     // " -L-fuse-ld=mold" for the lib link path; "" when mold unusable

// Machine-aware default worker count. See the call site in main() for the
// rationale; kept as a free function so run_all.d can mirror the same formula.
// VIBE3D_TEST_JOBS pins it per host (e.g. export it in your shell rc) so you
// don't have to pass -j every time; an explicit -j still overrides.
int defaultJobs() {
    import std.algorithm : clamp;
    const env = environment.get("VIBE3D_TEST_JOBS", "");
    if (env.length) {
        try { const n = env.to!int; if (n >= 1) return n; } catch (Exception) {}
    }
    return clamp(cast(int)totalCPUs / 4, 4, 12);
}

string col(string code, string s) {
    return useColor ? "\033[" ~ code ~ "m" ~ s ~ "\033[0m" : s;
}

string red   (string s) { return col("31", s); }
string green (string s) { return col("32", s); }
string yellow(string s) { return col("33", s); }
string dim   (string s) { return col("2",  s); }
string bold  (string s) { return col("1",  s); }

// ---------------------------------------------------------------------------
// Cross-process run lock
// ---------------------------------------------------------------------------
//
// Two test runs MUST NOT overlap on one host: the runner boots `vibe3d --test`
// on ports `port + worker` and uses a shared `vibe3d-tests-<PPID>` scratch dir,
// and `killStaleVibe` clears stale instances by port — two concurrent runs
// (e.g. two agents) fight over the same ports + scratch and mutually kill each
// other's vibe3d, producing "No such file" / "Could not connect" flakes. A
// host-wide advisory flock serialises runs: the second runner blocks (printing
// a notice) until the first releases, or times out and bails without stomping.
//
// The lock is on a fixed file in tempDir so it is shared across worktrees /
// checkouts. flock is released automatically when the fd closes (process exit),
// so a crashed runner never leaks the lock.
string runLockPath() { return buildPath(tempDir(), "vibe3d-run-test.lock"); }

// Acquire the host-wide run lock, waiting up to `timeoutSec` for any other
// runner to finish. Returns true on success; false if the wait timed out.
bool acquireRunLock(int timeoutSec) {
    import std.string : toStringz;
    runLockFd = open(runLockPath().toStringz, O_RDWR | O_CREAT, octal!"644");
    if (runLockFd < 0) {
        // Can't create the lockfile — degrade to no-lock rather than block CI.
        stderr.writeln(yellow("warning: could not open run lock; "
            ~ "running without cross-run serialisation"));
        return true;
    }
    // Fast path: grab it immediately if free.
    if (flock(runLockFd, LOCK_EX | LOCK_NB) == 0) return recordLockHolder();

    writeln(yellow("another test run is in progress on this host — waiting "
        ~ "(another agent may be running ./run_test.d)..."));
    int waited = 0;
    while (waited < timeoutSec) {
        Thread.sleep(1.seconds);
        waited += 1;
        if (flock(runLockFd, LOCK_EX | LOCK_NB) == 0) {
            writeln(green(format("  acquired run lock after %ds", waited)));
            return recordLockHolder();
        }
        if (waited % 15 == 0)
            writefln(yellow("  still waiting for the other run (%ds)..."), waited);
    }
    stderr.writeln(red(format("timed out after %ds waiting for the in-progress "
        ~ "test run to finish; not starting (re-run later, or kill the stale "
        ~ "runner). Lock: %s", timeoutSec, runLockPath())));
    close(runLockFd);
    runLockFd = -1;
    return false;
}

// Stamp our PID into the lockfile for diagnostics ("who holds it?").
bool recordLockHolder() {
    import std.string : toStringz;
    ftruncate(runLockFd, 0);
    string stamp = format("pid %d\n", getpid());
    c_write(runLockFd, stamp.ptr, stamp.length);
    return true;
}

void releaseRunLock() {
    if (runLockFd >= 0) {
        flock(runLockFd, LOCK_UN);
        close(runLockFd);
        runLockFd = -1;
    }
}

extern(C) void onSignal(int sig) nothrow @nogc @system {
    foreach (p; vibePids) if (p != 0) kill(p, SIGKILL);
    if (runLockFd >= 0) { flock(runLockFd, LOCK_UN); close(runLockFd); }
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
    releaseRunLock();
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
// Per-test timing persistence (machine-specific; gitignored)
// ---------------------------------------------------------------------------
//
// We record each test's wall-clock duration after every run and persist it to
// `.test_timings.json` in the repo root. Durations are smoothed across runs
// with an exponential moving average (EMA, alpha = 0.3): a run's fresh sample
// counts 30%, the prior history 70%. EMA was chosen over "median of last 5"
// because it needs no per-test sample ring (one float per test), still damps
// one-off spikes (a loaded host on a single run barely moves the estimate),
// and adapts smoothly when a test's real cost shifts (e.g. a test grows). The
// estimates feed the LPT scheduler (longest-processing-time-first) so workers
// finish nearly together instead of one dragging the long tail.
//
// The file is keyed by the bare test name (e.g. "test_bevel") so it is stable
// across the per-worker scratch copies and across worktrees/checkouts.

enum double EMA_ALPHA = 0.3;

string timingsPath() { return ".test_timings.json"; }

// Load smoothed per-test durations (seconds), keyed by bare test name. Missing
// or malformed file → empty map (every test then falls back to a default).
double[string] loadTimings() {
    double[string] m;
    auto p = timingsPath();
    if (!exists(p)) return m;
    try {
        auto j = parseJSON(readText(p));
        if (j.type != JSONType.object) return m;
        foreach (k, v; j.object) {
            if (v.type == JSONType.float_)        m[k] = v.floating;
            else if (v.type == JSONType.integer)  m[k] = cast(double)v.integer;
        }
    } catch (Exception) { /* corrupt cache — ignore, rebuild from scratch */ }
    return m;
}

// Fold this run's fresh samples into the prior estimates (EMA) and write back.
// `samples` is keyed by bare test name → wall-clock seconds for THIS run.
void saveTimings(double[string] prior, double[string] samples) {
    double[string] merged;
    foreach (k, v; prior) merged[k] = v;
    foreach (k, v; samples) {
        if (auto old = k in merged) *old = EMA_ALPHA * v + (1 - EMA_ALPHA) * (*old);
        else                        merged[k] = v;  // first observation
    }
    JSONValue[string] obj;
    foreach (k, v; merged) obj[k] = JSONValue(v);
    JSONValue j = JSONValue(obj);
    try { std.file.write(timingsPath(), j.toPrettyString); }
    catch (Exception e) { stderr.writeln(yellow("warning: could not write "
        ~ timingsPath() ~ ": " ~ e.msg)); }
}

// Best estimate (seconds) for a test path, given the loaded timings. Unknown
// tests get the median of known timings (robust to outliers), or a constant
// when the cache is empty.
double estimateFor(string path, double[string] timings, double defaultEst) {
    auto name = baseName(path).stripExtension;
    if (auto t = name in timings) return *t;
    return defaultEst;
}

double medianOf(double[] xs, double fallback) {
    if (xs.empty) return fallback;
    auto s = xs.dup;
    s.sort();
    return s[s.length / 2];
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

// Pure-D unit tests that exercise project source modules in-process (e.g.
// test_xform_matrix_kernel imports `tools.xform_kernels` / `mesh` / `math`)
// cannot be compiled with the bare `-I=tests` line below — they pull the
// full dependency graph (bindbc-opengl, OpenSubdiv C libs, …). For those we
// harvest dmd flags from `dub describe` ONCE and append them. Other tests
// (HTTP drivers that only import std.* + helpers) are unaffected.
//
// `__gshared` + lazy init so the (slowish) `dub describe` runs at most once
// across all workers, and only if a source-backed test is present.
// Harvested once and split in two so the project test-lib can be linked in the
// right order: COMPILE flags (-I / -J / -version) are position-independent,
// while the LINK TAIL (lflags, -l libs, dep .a archives) is order-sensitive and
// must come AFTER the project lib on the command line so its undefined symbols
// resolve against the deps. The `-i` fallback path just concatenates the two.
__gshared string g_compileFlags;
__gshared string g_linkTail;
__gshared bool   g_sourceFlagsDone;

void harvestSourceFlags() {
    synchronized {
        if (g_sourceFlagsDone) return;
        g_sourceFlagsDone = true;
        // Each `--data=<x> --data-list` emits one item per line; dub prints a
        // few leading "Warning" lines to stderr which 2>/dev/null drops.
        string gather(string kind, string prefix) {
            auto rr = executeShell(format(
                "dub describe --config=modeling --data=%s --data-list 2>/dev/null", kind));
            if (rr.status != 0) return "";
            string acc;
            foreach (line; rr.output.splitLines) {
                auto s = line.strip;
                if (s.length == 0) continue;
                acc ~= " " ~ prefix ~ s;
            }
            return acc;
        }
        g_compileFlags ~= gather("import-paths",        "-I=");
        g_compileFlags ~= gather("string-import-paths", "-J=");
        g_compileFlags ~= gather("versions",            "-version=");
        g_linkTail     ~= gather("lflags",              "-L");
        g_linkTail     ~= gather("libs",                "-L-l");
        // linker-files (.a archives) are passed verbatim.
        {
            auto rr = executeShell(
                "dub describe --config=modeling --data=linker-files --data-list 2>/dev/null");
            if (rr.status == 0)
                foreach (line; rr.output.splitLines) {
                    auto s = line.strip;
                    if (s.length) g_linkTail ~= " " ~ s;
                }
        }
    }
}

string sourceCompileFlags() { harvestSourceFlags(); return g_compileFlags; }
string sourceLinkTail()     { harvestSourceFlags(); return g_linkTail; }
string sourceTestFlags()    { harvestSourceFlags(); return g_compileFlags ~ g_linkTail; }

// A test is "source-backed" if it imports any first-party project module.
// Heuristic: a top-level `import <mod>` / `import <mod> :` whose module is one
// of the known project roots. HTTP-driver tests only import std.* + helpers,
// so this stays false for them and the cheap compile path is used.
bool isSourceBackedTest(string path) {
    string txt;
    try { txt = readText(path); } catch (Exception) { return false; }
    static immutable string[] roots = [
        "math", "mesh", "tools.", "toolpipe.", "falloff", "symmetry",
        "view", "viewcache", "handler", "shader", "editmode", "command",
        "snapshot", "forms", "params", "argstring", "shortcuts", "ai.",
        "buttonset",
    ];
    foreach (line; txt.splitLines) {
        auto s = line.strip;
        // R1: anchor to column 0 — test the RAW line so only genuinely top-level
        // imports count (an indented function-local `import math:` must NOT
        // flip an HTTP test to the heavy source-backed compile line).
        if (!line.startsWith("import ")) continue;
        string mod = s["import ".length .. $].strip;
        foreach (root; roots) {
            if (mod == root || mod.startsWith(root ~ " ")
                || mod.startsWith(root ~ ":") || mod.startsWith(root ~ ";")
                || (root.endsWith(".") && mod.startsWith(root)))
                return true;
        }
    }
    return false;
}

/// Build all modeling project source (minus app.d's `main`) into a static lib
/// ONCE per run, so each source-backed test links it instead of recompiling the
/// whole project graph via `dmd -i` — ≈6× faster per test and ≈6× less peak RAM
/// (so far more workers fit in the same memory), and it removes the `-i` + dep
/// archive duplicate symbols that block mold. Returns the lib path, or "" on
/// failure (callers fall back to the -i compile). Built with -unittest to match
/// the test compile; as a static archive only referenced members are pulled, so
/// a test no longer re-runs its *imported* project modules' unittests — those
/// are covered by the separate `dub test` step, and the test's own asserts are
/// unchanged (verified: identical assertion output, just fewer module unittests).
string buildProjectLib(string scratch) {
    auto rr = executeShell(
        "dub describe --config=modeling --data=source-files --data-list 2>/dev/null");
    if (rr.status != 0) return "";
    string[] srcs;
    foreach (line; rr.output.splitLines) {
        auto s = line.strip;
        // Exclude app.d: it carries the real `main`, which would clash with the
        // test binary's own `main`. Every other modeling module compiles clean
        // without WithRender (render/* bodies are version-gated to empty).
        if (s.length && !s.endsWith("/app.d") && !s.endsWith("\\app.d"))
            srcs ~= s;
    }
    if (srcs.empty) return "";
    const lib = buildPath(scratch, "libvibe3d_test.a");
    auto r = executeShell(format("dmd -lib -unittest%s %s -of=%s 2>&1",
                                 sourceCompileFlags(), srcs.join(" "), lib));
    if (r.status != 0 || !exists(lib)) {
        stderr.writeln(yellow("project test-lib build failed; "
            ~ "falling back to per-test -i compile"));
        if (r.output.length) stderr.writeln(dim(r.output));
        return "";
    }
    return lib;
}

/// Probe ONCE whether dmd can link through mold (much faster than bfd/gold for
/// the lib-link path). Needs mold on PATH and a cc new enough for
/// `-fuse-ld=mold` (gcc>=12 / clang); otherwise returns "" and we keep the
/// default linker. Only used on the project-lib path — the `-i` path links the
/// project AND the dep archives, which double-defines symbols that mold (unlike
/// GNU ld) rejects; the prebuilt lib has no such duplication.
string probeMoldFlag() {
    if (executeShell("command -v mold").status != 0) return "";
    const probe = buildPath(tempDir(), format("vibe3d_mold_probe_%d", getpid()));
    void cleanup() {
        foreach (ext; ["", ".d", ".o"])
            try { if (exists(probe ~ ext)) std.file.remove(probe ~ ext); }
            catch (Exception) {}
    }
    scope(exit) cleanup();
    try {
        std.file.write(probe ~ ".d", "void main(){}\n");
        if (executeShell(format("dmd -L-fuse-ld=mold -of=%s %s.d 2>&1", probe, probe)).status == 0)
            return " -L-fuse-ld=mold";
    } catch (Exception) {}
    return "";
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
        // Pull every tests/*_helpers.d into the compilation so a test
        // can `import drag_helpers;` (or any future helpers module)
        // without each test duplicating shared code. Helpers also have
        // their literal "localhost:8080" rewritten to the per-worker
        // port — without this, parallel workers' tests all hit port 8080
        // through the helpers, corrupting each other's vibe3d state.
        string helpers;
        foreach (e; dirEntries("tests", "*_helpers.d", SpanMode.shallow)) {
            string hSrc = e.name;
            if (port != 8080) {
                string hTxt = readText(e.name)
                    .replace("localhost:8080", "localhost:" ~ port.to!string);
                hSrc = buildPath(outDir, baseName(e.name));
                std.file.write(hSrc, hTxt);
            }
            helpers ~= " " ~ hSrc;
        }
        // -I=<outDir> first so the rewritten helpers in the scratch dir
        // win over the unmodified originals in tests/. -J=tests lets a
        // test embed a golden fixture via `import("fixtures/<name>.json")`
        // (see tests/fixture_helpers.d) — the path is resolved against the
        // repo's tests/ dir regardless of the per-worker scratch copy.
        //
        // Source-backed tests (those importing project modules like
        // tools.xform_kernels / mesh / math) need the full dependency graph:
        // dmd's `-i` auto-includes the imported project source, and the
        // harvested `dub describe` flags supply the dep import paths + the
        // native link inputs (OpenSubdiv C libs, bindbc archives, …). We drop
        // `-w` for these because the third-party dep code carries warnings
        // that aren't ours to fix; the test's own warnings still surface via
        // the bare-path tests. HTTP-driver tests keep the original cheap line.
        string cmd;
        if (isSourceBackedTest(p)) {
            if (projLibPath.length) {
                // Link the prebuilt project lib instead of recompiling it via
                // `-i`. Order is load-bearing: test.o, then the project lib,
                // then the dep archives/link tail (mold is order-strict).
                cmd = format("dmd -unittest -J=tests -I=%s -I=tests%s%s %s %s%s%s -of=%s 2>&1",
                             outDir, helpers, sourceCompileFlags(), src,
                             projLibPath, sourceLinkTail(), moldFlag, of);
            } else {
                cmd = format("dmd -unittest -i -J=tests -I=%s -I=tests%s%s %s -of=%s 2>&1",
                             outDir, helpers, sourceTestFlags(), src, of);
            }
        } else {
            cmd = format("dmd -unittest -J=tests -I=%s -I=tests%s %s -w -of=%s 2>&1",
                         outDir, helpers, src, of);
        }
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
    return httpProbe(port);
}

// Poll /api/camera until it answers 200 (or we give up). Used both after we
// spawn vibe3d and, in --attach mode, to wait for the external endpoint.
bool httpProbe(ushort port, int tries = 100) {
    string probe = format("curl -s -o /dev/null -w '%%{http_code}' " ~
                          "http://localhost:%d/api/camera", port);
    for (int i = 0; i < tries; ++i) {
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
    string output;     // captured stdout+stderr (only kept on failure)
    double seconds;    // wall-clock duration of this test (for timing cache)
}

TestResult runOne(string bin, bool verbose) {
    TestResult r;
    r.name = baseName(bin);
    auto sw = StopWatch(AutoStart.yes);
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
    r.seconds = sw.peek.total!"msecs" / 1000.0;
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
    if (g_attachPort != 0) {
        // Attach mode: an external endpoint (the visual_test_proxy → a visible
        // vibe3d) already listens on w.port. Don't kill or spawn anything — just
        // wait for it to answer. It stays alive after the run (never in vibePids).
        if (!httpProbe(w.port)) {
            stderr.writefln(red("attach: nothing answering on http://localhost:%d"), w.port);
            return false;
        }
        return true;
    }
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

// Re-establish a known-clean baseline on a worker's shared vibe3d BEFORE each
// test binary runs. The runner reuses ONE `vibe3d --test` per worker across
// that worker's whole slice of tests, so a preceding test can leave global
// state dirty for the next one in four ways:
//   1. an event-log replay (/api/play-events) is still DRAINING on the
//      background event player when the test process exits — its queued
//      mouse-move events keep firing into the next test's freshly-reset mesh;
//   2. a tool was left active (a stray interactive session);
//   3. the undo stack carries the prior test's entries (command_history caps
//      at 50, which would pin any count-delta assertion).
//   4. selection/edit mode can leak when a reset is undone while draining
//      history.
// This is the documented cross-test state-bleed flake family (test_http_endpoint
// asserting the pristine startup cube, test_selection's "expected 2 got 0",
// etc.). Resetting at the RUNNER level — between every binary — kills the whole
// class at the source: each test now starts from a guaranteed-pristine cube,
// idle player, no active tool, empty undo stack. Tests that need a different
// baseline (empty mesh, a loaded LWO, a fixture, an empty-undo start) all
// establish it themselves at the top of their first unittest, so this reset is
// belt-and-suspenders for them and load-bearing for the state-asserting ones.
//
// Driven over HTTP with curl (already this runner's transport). Best-effort:
// any failure here is non-fatal (the per-test reset, if present, still runs).
void resetBetweenTests(ushort port) {
    string base = format("http://localhost:%d", port);
    string curl(string verb, string path, string data = "") {
        // -s silent, -m short timeout so a wedged server never stalls the run.
        string cmd = data.length
            ? format("curl -s -m 5 -X %s -d '%s' '%s%s'", verb, data, base, path)
            : format("curl -s -m 5 -X %s '%s%s'",          verb,       base, path);
        auto r = executeShell(cmd);
        return r.status == 0 ? r.output : "";
    }
    // Deactivate + drain-replay + reset + clear history, then VERIFY the cube
    // and selection/edit-mode baseline are actually pristine, retrying
    // the whole sequence a few times if not. A still-queued replay can briefly
    // report finished BETWEEN its events, so a single drain pass is not enough;
    // the verify-and-retry closes that window — a transient bleed clears on
    // re-reset while a genuine regression would persist (reset always restores
    // the cube), so this defends against the flake without masking real bugs.
    bool cubePristine() {
        // /api/model's v6 of the startup cube is (0.5, 0.5, 0.5).
        auto m = curl("GET", "/api/model");
        // Cheap structural check first: 8 verts. Then v6 ≈ (0.5,0.5,0.5).
        if (m.length == 0) return false;
        try {
            auto j = parseJSON(m);
            if (j["vertices"].array.length != 8) return false;
            auto v = j["vertices"].array[6].array;
            import std.math : fabs;
            return fabs(v[0].floating - 0.5) < 1e-4
                && fabs(v[1].floating - 0.5) < 1e-4
                && fabs(v[2].floating - 0.5) < 1e-4;
        } catch (Exception) { return false; }
    }
    bool selectionPristine() {
        auto s = curl("GET", "/api/selection");
        if (s.length == 0) return false;
        try {
            auto j = parseJSON(s);
            return j["mode"].str == "vertices"
                && j["selectedVertices"].array.length == 0
                && j["selectedEdges"].array.length == 0
                && j["selectedFaces"].array.length == 0;
        } catch (Exception) { return false; }
    }
    foreach (attempt; 0 .. 8) {
        // 1. Deactivate any tool the previous test left active (idempotent).
        curl("POST", "/api/command", "tool.set move off");
        // 2. Drain any in-flight event-log replay so its leftover mouse events
        //    cannot perturb the reset. /api/play-events/status reports
        //    {"finished":true} when idle (absent ⇒ never played ⇒ idle).
        foreach (_; 0 .. 200) {
            auto s = curl("GET", "/api/play-events/status");
            if (s.length == 0 || !s.canFind("\"finished\":false")) break;
            Thread.sleep(10.msecs);
        }
        // 2b. Settle. The event player reports "finished" once all its events
        //     are DISPATCHED, but /api/play-events pushes them onto the SDL
        //     queue (g_directDispatch is null) — the LAST few are still in the
        //     queue, unprocessed, when the player goes idle. They drain on the
        //     next 1–2 main-loop frames. If we reset before they drain, those
        //     queued mouse events (e.g. a drag's final mouse-up) fire AFTER the
        //     reset, landing on the next test's freshly-reset mesh + active
        //     tool — exactly the test_property_panel_drag "got (-1,0,1)" bleed.
        //     A short settle lets the queue drain onto the OLD mesh first; the
        //     reset below then wipes whatever they did.
        Thread.sleep(120.msecs);
        // 3. Reset to the pristine startup cube.
        curl("POST", "/api/reset");
        // 3b. Normalize the edit mode back to Vertices and keep all component
        //     selections empty. SceneReset already does this; the explicit
        //     select is a cheap guard for older/bisected app binaries.
        curl("POST", "/api/select", `{"mode":"vertices","indices":[]}`);
        // 4. Clear undo/redo without undoing the reset/select we just applied.
        //    Undo-draining here can restore the prior test's mesh/selection.
        curl("POST", "/api/command", "history.clear");
        if (cubePristine() && selectionPristine()) return;
        Thread.sleep(20.msecs);
    }
    // Last reset stands; the test's own preamble (if any) gets the final word.
    curl("POST", "/api/reset");
    curl("POST", "/api/select", `{"mode":"vertices","indices":[]}`);
    curl("POST", "/api/command", "history.clear");
}

TestResult[] runWorker(ref Worker w, bool verbose) {
    TestResult[] out_;
    foreach (b; w.bins) {
        // Re-baseline the shared instance before each test so a prior test's
        // leftover state (draining replay, active tool, undo entries, mutated
        // mesh) cannot bleed in. Kills the cross-test state-bleed flake family.
        resetBetweenTests(w.port);
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
    // Machine-aware default worker count: scale with the host but stay sane.
    // Each worker boots its OWN vibe3d (a GL app), so we don't go 1:1 with
    // cores — clamp(totalCPUs/4, 4, 12). On a 32-core host that's 8; small
    // hosts still get 4; huge hosts cap at 12 so we don't spawn a swarm of
    // GL instances. An explicit `-j N` always overrides this default.
    int j = defaultJobs();
    int attach = 0;
    string[] exclude;
    auto helpInfo = getopt(args,
        config.bundling,
        "v|verbose",  "stream test output instead of summarizing on failure", &verbose,
        "k|keep",     "leave vibe3d running after tests finish",              &keep,
        "no-build",   "skip `dub build`",                                     &noBuild,
        "p|port",     "HTTP port for vibe3d (default 8080)",                  &port,
        "j|jobs",     "parallel workers — each runs its own vibe3d on a "
                    ~ "private port (default = clamp(cpus/4, 4, 12))",        &j,
        "attach",     "drive an already-running endpoint on this port (e.g. "
                    ~ "tools/visual_test_proxy.py) instead of spawning vibe3d; "
                    ~ "forces -j1, leaves the endpoint running",              &attach,
        "exclude",    "skip a test by name (repeatable). Same name forms as "
                    ~ "the positional args: bevel | test_bevel | tests/test_bevel.d", &exclude);

    // --attach: target a pre-launched endpoint (visual proxy / external vibe3d).
    // Single worker on that one port; never kill or spawn an instance.
    if (attach != 0) {
        g_attachPort = cast(ushort)attach;
        port = cast(ushort)attach;
        j = 1;
    }

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

    // Serialise with any other runner on this host BEFORE we touch ports /
    // scratch / vibe3d — concurrent runs mutually kill each other's instances
    // (killStaleVibe by port) and share the scratch dir, causing spurious
    // "Could not connect" / "No such file" failures. Wait up to 10 min.
    if (!acquireRunLock(600)) return 1;

    scratchDir = buildPath(tempDir(), "vibe3d-tests-" ~ environment.get("PPID", "0"));
    if (exists(scratchDir)) rmdirRecurse(scratchDir);
    mkdirRecurse(scratchDir);

    // Cap workers at # of tests so we don't spin up empty vibe3d instances.
    if (j > cast(int)tests.length) j = cast(int)tests.length;

    // Build N workers and distribute tests by LONGEST-PROCESSING-TIME-FIRST:
    // sort tests by expected duration DESCENDING, then greedily assign each to
    // the currently least-loaded worker. This packs the long tests early and
    // backfills the short ones, so all workers finish at nearly the same time
    // instead of one worker dragging a long test at the very end. Expected
    // durations come from the smoothed timing cache (.test_timings.json);
    // unknown tests get the median of known timings (or a 2s constant when the
    // cache is empty / cold).
    auto timings   = loadTimings();
    double defaultEst = medianOf(timings.values, 2.0);

    Worker[] workers;
    workers.length = j;
    foreach (i, ref w; workers) {
        w.id      = cast(int)i;
        w.port    = cast(ushort)(port + i);
        w.scratch = buildPath(scratchDir, format("worker_%d", i));
    }

    // Sort a working copy of the test paths by descending estimate.
    auto ordered = tests.dup;
    ordered.sort!((a, b) =>
        estimateFor(a, timings, defaultEst) > estimateFor(b, timings, defaultEst));

    auto load = new double[j];   // expected accumulated load per worker
    load[] = 0;                  // double[].init is NaN in D — zero it first
    foreach (t; ordered) {
        size_t target = load[].minIndex;   // least-loaded worker
        workers[target].tests ~= t;
        load[target] += estimateFor(t, timings, defaultEst);
    }

    if (verbose && j > 1) {
        writeln(dim("LPT schedule (expected load per worker):"));
        foreach (i, ref w; workers)
            writefln(dim("  w%d: %5.1fs  (%d test%s)"),
                i, load[i], w.tests.length, w.tests.length == 1 ? "" : "s");
        writeln();
    }

    // Prepare workers in parallel — compile tests + boot vibe3d. Each
    // worker's compile/boot is independent.
    writefln("Compiling %d test%s and booting %d vibe3d instance%s...",
        tests.length, tests.length == 1 ? "" : "s",
        j, j == 1 ? "" : "s");
    // Source-backed tests: build the project once into a shared static lib and
    // link it (≈6× faster + ≈6× less RAM per test than recompiling via `dmd -i`,
    // and it unlocks mold). Done once here, single-threaded, before workers fan
    // out; the lib + flag are read-only thereafter. HTTP-driver tests are
    // unaffected. On lib-build failure projLibPath stays "" and we fall back.
    if (tests.canFind!isSourceBackedTest) {
        projLibPath = buildProjectLib(scratchDir);
        if (projLibPath.length) {
            moldFlag = probeMoldFlag();
            writeln(dim("Built project test-lib for source-backed tests"
                ~ (moldFlag.length ? " (linking with mold)." : ".")));
        }
    }
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

    // Fold this run's wall-clock durations into the smoothed timing cache so
    // the next run schedules better. Key by bare test name (drop ".out"/path).
    double[string] samples;
    foreach (ref r; results) {
        auto name = baseName(r.name).stripExtension;
        if (r.seconds > 0 && !r.seconds.isNaN) samples[name] = r.seconds;
    }
    if (samples.length) saveTimings(timings, samples);

    printSummary(results);
    int failed = 0;
    foreach (ref r; results) if (!r.passed) failed++;
    int rc = failed == 0 ? 0 : 1;

    return rc;
}
