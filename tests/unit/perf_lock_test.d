// The perf measuring window's host-wide locks (task 2030, extended
// 2026-08-30 to also take the test runner's lock — see
// tools/perf/lib/with_perf_lock.sh's own header for the three measurements
// that made "a perf run and a test run may legitimately overlap" false).
//
// WHY THIS FILE EXISTS AT ALL. The failure mode of a lock that stops
// excluding what it was meant to exclude is SILENT and produces plausible
// numbers: the perf lane measures beside a test run, every case comes back
// 20-60% slow, `--vs-last` reddens, and nothing anywhere says "the host was
// busy". That is the shape CLAUDE.md names — a green (or a red) that cannot
// tell you which of two very different worlds it came from. The specific
// ways it can go silently wrong, one block each:
//
//   1. THE TWO PATHS DRIFT. `with_perf_lock.sh` DEFAULTS to
//      /tmp/vibe3d-run-test.lock; `run_test.d` computes its own from
//      `tempDir()`. Nothing links them but this assertion. If run_test.d's
//      path ever moves — or a workflow sets the test seam, or the skip flag —
//      the perf lane keeps taking a lock NOBODY ELSE TAKES and every night
//      stays green about it.
//   2. THE SECOND ACQUISITION IS NOT ACTUALLY THERE. A `flock` that is
//      written but never reached (an early `exec`, a misplaced `fi`) leaves
//      the script running exactly as before.
//   3. THE REFUSAL DEGRADES. On a timeout this must exit non-zero WITHOUT
//      running the command. "Run anyway" measures under contention; "skip
//      quietly and exit 0" reports a green that means "did not measure".
//      Both are worse than a red.
//
// Blocks 2 and 3 are BEHAVIOURAL: this process takes a REAL `flock(2)` on a
// real file and then drives the REAL script against it. No mock — the thing
// under test is a kernel advisory lock, and a mocked one proves nothing about
// it. The lock files are private to the test (via the script's own env seam)
// because the real /tmp/vibe3d-run-test.lock is routinely held by a live test
// lane on this host, which would make the "free host" arm a coin flip.
module tests.unit.perf_lock_test;

import std.algorithm : canFind;
import std.conv      : to, octal;
import std.exception : enforce;
import std.file      : exists, readText, tempDir, remove;
import std.path      : buildPath, dirName;
import std.process   : execute, thisProcessID;
import std.string    : indexOf;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum scriptPath = buildPath(repoRoot, "tools", "perf", "lib", "with_perf_lock.sh");
private enum runTestPath = buildPath(repoRoot, "run_test.d");

// ---------------------------------------------------------------------------
// 1. The two lock paths agree — read out of BOTH sources, never asserted
//    against a literal typed twice.
// ---------------------------------------------------------------------------
unittest
{
    enforce(exists(scriptPath),  scriptPath  ~ " not found — repo root misderived");
    enforce(exists(runTestPath), runTestPath ~ " not found — repo root misderived");

    // run_test.d builds it as `buildPath(tempDir(), "vibe3d-run-test.lock")`.
    // Read the BASENAME out of that file rather than hard-coding it here, so
    // a rename in run_test.d moves this assertion instead of hiding from it.
    const runTestSrc = readText(runTestPath);
    const marker = `buildPath(tempDir(), "`;
    const i = runTestSrc.indexOf(marker);
    enforce(i >= 0, "run_test.d no longer builds its run-lock path with "
        ~ "buildPath(tempDir(), \"...\") — this test can no longer read the "
        ~ "name it must agree with, and MUST be updated rather than deleted");
    const rest = runTestSrc[i + marker.length .. $];
    const j = rest.indexOf('"');
    enforce(j > 0, "unterminated lock-file name in run_test.d");
    const lockBaseName = rest[0 .. j];
    assert(lockBaseName == "vibe3d-run-test.lock", lockBaseName);

    const expected = buildPath(tempDir(), lockBaseName);
    const script = readText(scriptPath);
    // The script reads the path through a test seam with a DEFAULT; the
    // default is what production uses and is therefore what this pins.
    assert(script.canFind("runtest_lock_path=\"${VIBE3D_PERF_RUNTEST_LOCK_PATH:-"
                          ~ expected ~ "}\""),
        "with_perf_lock.sh does not DEFAULT to the same lock run_test.d takes.\n"
        ~ "  run_test.d computes: " ~ expected ~ "\n"
        ~ "  with_perf_lock.sh must contain: "
        ~ "runtest_lock_path=\"${VIBE3D_PERF_RUNTEST_LOCK_PATH:-" ~ expected ~ "}\"\n"
        ~ "If these drift, the perf lane takes a lock nobody else takes, keeps "
        ~ "measuring beside live test runs, and every night stays green about it.");
    // ...and the seam must never be set by a workflow: a lane pointed at a
    // private lock file excludes nothing and says nothing.
    foreach (wf; ["perf.yaml", "ci.yaml", "tsan.yaml", "sanitizer.yaml"]) {
        const p = buildPath(repoRoot, ".github", "workflows", wf);
        if (!exists(p)) continue;
        assert(!readText(p).canFind("VIBE3D_PERF_RUNTEST_LOCK_PATH"),
            wf ~ " sets the lock-path TEST SEAM. That redirects the perf lane "
            ~ "onto a lock nothing else takes, which is exactly the silent "
            ~ "failure this file exists to prevent.");
        assert(!readText(p).canFind("VIBE3D_PERF_SKIP_RUNTEST_LOCK"),
            wf ~ " sets VIBE3D_PERF_SKIP_RUNTEST_LOCK — the perf lane would "
            ~ "measure beside live test runs again.");
    }
}

// ---------------------------------------------------------------------------
// 2 + 3. The real lock, the real script: held => REFUSED, non-zero, and the
//    wrapped command never ran. Free => runs, and the command's own exit code
//    survives the wrapper.
// ---------------------------------------------------------------------------
private extern(C) int flock(int fd, int operation) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_UN = 8, LOCK_NB = 4;

unittest
{
    import core.sys.posix.fcntl : open, O_RDWR, O_CREAT;
    import core.sys.posix.unistd : close;
    import std.string : toStringz;

    const tag      = thisProcessID.to!string;
    const lock     = buildPath(tempDir(), "vibe3d-perf-lock-test-runtest-" ~ tag);
    const perfLock = buildPath(tempDir(), "vibe3d-perf-lock-test-perf-" ~ tag);
    const witness  = buildPath(tempDir(), "vibe3d-perf-lock-witness-" ~ tag);
    string[string] seam = [
        "VIBE3D_PERF_LOCK_PATH":         perfLock,
        "VIBE3D_PERF_RUNTEST_LOCK_PATH": lock,
    ];
    scope(exit) foreach (f; [lock, perfLock, witness]) if (exists(f)) remove(f);
    if (exists(witness)) remove(witness);

    // Take the run-test lock the way run_test.d takes it: flock(2) LOCK_EX on
    // an fd this process keeps open. Advisory locks are per open-file-
    // description, so the child script's own fd genuinely blocks on it.
    const fd = open(lock.toStringz, O_RDWR | O_CREAT, octal!"644");
    enforce(fd >= 0, "could not open the test lock file " ~ lock);
    bool released;
    void release() { if (!released) { released = true; flock(fd, LOCK_UN); close(fd); } }
    scope(exit) release();
    enforce(flock(fd, LOCK_EX | LOCK_NB) == 0,
        "could not establish the precondition: this process could not take "
        ~ lock ~ ", so the refusal below would prove nothing");

    // 3. HELD => refuse, non-zero, and the wrapped command must NOT have run.
    {
        auto r = execute(["bash", scriptPath, "1", "--",
                          "bash", "-c", "touch " ~ witness], seam);
        assert(r.status != 0,
            "with_perf_lock.sh returned 0 while a test run held " ~ lock
            ~ " — a green that means 'measured under contention':\n" ~ r.output);
        assert(!exists(witness),
            "with_perf_lock.sh RAN the wrapped command while " ~ lock
            ~ " was held. The refusal must happen BEFORE the command, never "
            ~ "degrade to 'run anyway'.");
        assert(r.output.canFind("REFUSED") && r.output.canFind(lock),
            "the refusal does not name the lock it could not take:\n" ~ r.output);
    }

    // The skip flag is the documented one-line reversal and must actually
    // reverse it — otherwise the escape hatch is a lie and nobody can measure
    // on a host where no test lane exists.
    {
        auto env2 = seam.dup;
        env2["VIBE3D_PERF_SKIP_RUNTEST_LOCK"] = "1";
        auto r = execute(["bash", scriptPath, "1", "--",
                          "bash", "-c", "touch " ~ witness ~ "; exit 0"], env2);
        scope(exit) if (exists(witness)) remove(witness);
        assert(r.status == 0, "VIBE3D_PERF_SKIP_RUNTEST_LOCK=1 did not skip "
            ~ "the run-test lock:\n" ~ r.output);
        assert(r.output.canFind("WITHOUT excluding a concurrent test run"),
            "the skip path must say loudly what it gave up:\n" ~ r.output);
    }

    release();

    // 2 (reverse direction). FREE => the command runs and its own exit code
    // survives. Without this cell the assertions above are satisfied by a
    // script that refuses unconditionally.
    {
        auto r = execute(["bash", scriptPath, "5", "--",
                          "bash", "-c", "touch " ~ witness ~ "; exit 0"], seam);
        scope(exit) if (exists(witness)) remove(witness);
        assert(r.status == 0, "with_perf_lock.sh refused on a free host:\n" ~ r.output);
        assert(exists(witness), "the wrapped command did not run:\n" ~ r.output);
        assert(r.output.canFind("acquired " ~ lock),
            "the run-test lock was never acquired on a free host — the second "
            ~ "flock is not on the executed path at all:\n" ~ r.output);
        assert(r.output.canFind("loadavg BEFORE the measuring window"),
            "the load sample (card 3430's residual, made visible) is missing:\n" ~ r.output);
    }
    {
        // The wrapper `exec`s, so a non-zero command code must come back
        // unchanged — not swallowed into a success, not remapped onto the
        // wrapper's own "refused" code 1.
        auto r = execute(["bash", scriptPath, "5", "--", "bash", "-c", "exit 7"], seam);
        assert(r.status == 7, "the wrapped command's exit code did not survive "
            ~ "the wrapper (got " ~ r.status.to!string ~ "):\n" ~ r.output);
    }
}
