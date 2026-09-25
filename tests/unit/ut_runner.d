// Module-unit-test runner for the `tests` configuration (task 4931).  Its
// execution loop mirrors druntime's runModuleUnitTests loop; the only work
// inside each module boundary is a MonoTime measurement.  The checked roster
// and exact population floor keep a missing registration from becoming a
// quiet successful run.
//
// PARALLEL (task 7900): with VIBE3D_UT_JOBS=N > 1 (the default is
// min(8, CPUs)) this process becomes a PARENT that runs no module itself. It
// packs the roster onto N worker processes of this same binary
// (tests/unit/ut_shard_plan.d), each running its disjoint shard serially and
// writing one result file, and merges them. A module counts as passed only
// when its shard reported it and then closed its file and exited
// consistently; anything missing is counted executed-and-failed, so a dead
// shard can never print a smaller green. VIBE3D_UT_JOBS=1 is the serial loop,
// unchanged. Card: doc/tasks/work/parallel-module-gate.md.
module tests.unit.ut_runner;

import core.exception : AssertError;
import core.runtime : Runtime, UnitTestResult;
import core.time : MonoTime;
import std.algorithm : isSorted, sort;
import std.conv : to;
import std.file : readText;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : File, stderr, writefln, writeln;
import std.string : splitLines, strip;

// The roster is an IDENTITY, not a ratchet: `actual == expected` already
// implies equal cardinality, so a separate count literal buys nothing and
// costs a hand edit in a SECOND file on every lane that adds a module. Five
// lanes in one day were forced into that edit; git merged the sorted set
// correctly each time and took one lane's number for the literal, leaving the
// file right and the number false. The floor below does not drift (task 5220).
private enum minimumModuleCount = 500;
private enum timingEnvironment = "VIBE3D_UT_TIMINGS";

// A SLICE of the roster, for instrumented lanes only: "i/n" runs the modules
// whose position is congruent to i modulo n. It exists because AddressSanitizer
// cannot carry this gate in one process -- measured 2026-09-10, the run aborts
// in compiler-rt itself with `sanitizer_allocator_secondary.h:42 "((n)) <
// ((kMaxNumChunks))" (0x100000, 0x100000)`, an internal ceiling of one million
// live large mappings, not a finding about our code.
//
// The roster IDENTITY asserts are skipped while a slice is active, and that is
// the dangerous half of this switch: a run that checks nothing must not be able
// to look like a run that checked everything. So the slice announces itself on
// stderr on EVERY run, the skip is announced too, and both carry the word
// PARTIAL. Never read a sliced run as a gate. A slice always runs serially.
private enum sliceEnvironment = "VIBE3D_UT_SLICE";

// Worker-process count for the parallel gate; "1" is the serial loop.
private enum jobsEnvironment = "VIBE3D_UT_JOBS";
private enum defaultJobs = 8;
// Set by the parent on each worker: "<shard>:<parent pid>:<spec dir>".
// Internal; a worker removes it from its own environment before any test runs.
private enum shardEnvironment = "VIBE3D_UT_SHARD";
private enum leasePidEnvironment = "VIBE3D_INHERITED_RUN_LOCK_PID";
private enum leaseFdEnvironment = "VIBE3D_INHERITED_RUN_LOCK_FD";

extern (C) void _d_print_throwable(Throwable throwable);

shared static this()
{
    Runtime.extendedModuleUnitTester = &runModuleUnitTestsWithTimings;
}

private string[] loadExpectedRoster()
{
    const path = buildPath(dirName(__FILE_FULL_PATH__),
                           "unittest_module_roster.txt");
    string[] result;
    foreach (line; readText(path).splitLines)
    {
        const name = line.strip;
        if (name.length)
            result ~= name;
    }
    return result;
}

private void verifyPopulationAndRoster(string[] actual, size_t executed)
{
    const expected = loadExpectedRoster();
    actual.sort;
    if (actual != expected)
    {
        stderr.writeln("unit-test module roster changed; actual roster follows:");
        foreach (name; actual)
            stderr.writefln("UT-ROSTER-ACTUAL %s", name);
    }

    if (environment.get(sliceEnvironment, "").length)
    {
        stderr.writeln("UT-PARTIAL roster identity NOT checked: a slice was "
                     ~ "requested via " ~ sliceEnvironment
                     ~ ". This run is not a gate.");
        return;
    }

    assert(expected.length >= minimumModuleCount,
        "unit-test roster collapsed: lists only "
        ~ expected.length.to!string ~ " modules, floor is "
        ~ minimumModuleCount.to!string
        ~ " -- the roster file is truncated or was not read");
    assert(isSorted(expected),
        "unit-test module roster must remain sorted");
    assert(executed == expected.length,
        "unit-test module population changed: executed "
        ~ executed.to!string ~ ", roster lists "
        ~ expected.length.to!string);
    assert(actual == expected,
        "unit-test module roster changed; update only after reviewing the full diff");
}

// Run one module's unittests the way druntime does. Returns whether it passed
// and writes the elapsed time; the failure output is druntime's own.
private bool runOneModule(ModuleInfo* m, void function() fp, out double elapsedMs)
{
    bool passed;
    const started = MonoTime.currTime;
    MonoTime stopped;
    try
    {
        fp();
        stopped = MonoTime.currTime;
        passed = true;
    }
    catch (Throwable e)
    {
        stopped = MonoTime.currTime;
        if (typeid(e) == typeid(AssertError))
        {
            // Keep druntime's same-module AssertError formatting exactly:
            // it intentionally omits a redundant stack trace.
            auto moduleName = m.name;
            if (moduleName.length && e.file.length > moduleName.length
                && e.file[0 .. moduleName.length] == moduleName)
            {
                import core.stdc.stdio : printf;
                printf("%.*s(%llu): [unittest] %.*s\n",
                    cast(int) e.file.length, e.file.ptr, cast(ulong) e.line,
                    cast(int) e.message.length, e.message.ptr);
                goto moduleFinished;
            }
        }
        _d_print_throwable(e);
    }

moduleFinished:
    elapsedMs = (stopped - started).total!"usecs" / 1000.0;
    return passed;
}

private UnitTestResult runModuleUnitTestsWithTimings()
{
    const shardSpec = environment.get(shardEnvironment, "");
    if (shardSpec.length)
        return runShardWorker(shardSpec);

    if (!environment.get(sliceEnvironment, "").length)
    {
        const jobs = requestedJobs();
        if (jobs > 1)
            return runParallelParent(jobs);
    }
    return runSerial();
}

private size_t requestedJobs()
{
    const raw = environment.get(jobsEnvironment, "");
    // Workers borrow the parent's run slot through /proc (runslots.d) and
    // re-exec /proc/self/exe, so the parallel gate is Linux-only.
    version (linux)
    {
        import std.parallelism : totalCPUs;
        const fallback = totalCPUs < defaultJobs ? totalCPUs : defaultJobs;
    }
    else
        enum size_t fallback = 1;
    if (!raw.length)
        return fallback;
    // Strict, like the slice: a typo must not silently pick a mode.
    size_t jobs;
    try
        jobs = raw.strip.to!size_t;
    catch (Exception)
        assert(false, jobsEnvironment ~ " must be a positive integer, got: " ~ raw);
    if (jobs == 0)
        assert(false, jobsEnvironment ~ " must be a positive integer, got: " ~ raw);
    version (linux) {} else
        if (jobs > 1)
            assert(false, jobsEnvironment ~ " > 1 needs Linux, got: " ~ raw);
    return jobs;
}

private UnitTestResult runSerial()
{
    UnitTestResult results;
    string[] actualRoster;

    const timingPath = environment.get(timingEnvironment, "");
    File timingOutput;
    const timingEnabled = timingPath.length != 0;
    if (timingEnabled)
        timingOutput = File(timingPath, "w");

    // Slice parsing is deliberately strict: a malformed value is a hard error,
    // not a silent full run. A typo that quietly ran everything would defeat
    // the only reason the switch exists.
    size_t sliceIndex, sliceCount;
    const sliceSpec = environment.get(sliceEnvironment, "");
    if (sliceSpec.length)
    {
        import std.string : indexOf;
        const sep = sliceSpec.indexOf('/');
        if (sep <= 0 || sep + 1 >= sliceSpec.length)
            assert(false, sliceEnvironment ~ " must read i/n, got: " ~ sliceSpec);
        sliceIndex = to!size_t(sliceSpec[0 .. sep]);
        sliceCount = to!size_t(sliceSpec[sep + 1 .. $]);
        if (sliceCount == 0 || sliceIndex >= sliceCount)
            assert(false, sliceEnvironment ~ " needs 0 <= i < n, got: " ~ sliceSpec);
        stderr.writefln("UT-PARTIAL slice %d of %d -- this run is NOT a gate",
                        sliceIndex, sliceCount);
    }

    size_t seen;
    foreach (m; ModuleInfo)
    {
        if (!m)
            continue;
        auto fp = m.unitTest;
        if (!fp)
            continue;

        if (sliceCount != 0 && (seen++ % sliceCount) != sliceIndex)
            continue;

        actualRoster ~= m.name;
        ++results.executed;
        double elapsedMs;
        if (runOneModule(m, fp, elapsedMs))
            ++results.passed;
        if (timingEnabled)
            timingOutput.writefln("UT %.3f %s", elapsedMs, m.name);
    }

    if (timingEnabled)
        timingOutput.flush();

    // The custom handler owns these fields.  `runMain` deliberately remains
    // false even on success: dub's injected main is not a test witness.
    results.runMain = false;
    results.summarize = true;
    stderr.writefln("UT-TOTAL executed=%s passed=%s",
                    results.executed, results.passed);
    verifyPopulationAndRoster(actualRoster, results.executed);
    return results;
}

// ---------------------------------------------------------------------------
// Worker side.

private UnitTestResult runShardWorker(string spec)
{
    import core.stdc.stdio : setvbuf, stdout, _IOLBF;
    import core.stdc.stdlib : exit;
    import std.format : format;
    import std.string : indexOf, startsWith;

    // Line-buffer stdout: a worker that dies mid-module must not take the
    // failure text it already printed with it.
    setvbuf(stdout, null, _IOLBF, 0);

    const c1 = spec.indexOf(':');
    const c2 = c1 < 0 ? -1 : spec[c1 + 1 .. $].indexOf(':');
    if (c1 <= 0 || c2 <= 0)
        assert(false, shardEnvironment ~ " is malformed: " ~ spec);
    const shard = spec[0 .. c1].to!size_t;
    const parentPid = spec[c1 + 1 .. c1 + 1 + c2].to!int;
    const dir = spec[c1 + 1 + c2 + 1 .. $];

    version (linux)
    {
        // A worker must not outlive its parent: the parent's slot is what
        // this worker borrowed, and it is released when the parent dies.
        import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
        import core.sys.posix.signal : SIGKILL;
        import core.sys.posix.unistd : getppid;
        prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
        if (getppid() != parentPid)
            exit(3);
    }

    auto result = File(buildPath(dir, format("shard-%d.result", shard)), "w");
    void emit(string line)
    {
        result.writeln(line);
        result.flush();
    }

    // The assignment, plus the environment the tests must see: exactly the
    // parent's, so the lease this worker borrowed through is put back.
    bool[string] assigned;
    foreach (line; readText(buildPath(dir, format("shard-%d.assign", shard))).splitLines)
    {
        if (line.startsWith("module "))
            assigned[line["module ".length .. $]] = false;
        else if (line.startsWith("env-set "))
        {
            const kv = line["env-set ".length .. $];
            const eq = kv.indexOf('=');
            environment[kv[0 .. eq]] = kv[eq + 1 .. $];
        }
        else if (line.startsWith("env-unset "))
            environment.remove(line["env-unset ".length .. $]);
    }
    environment.remove(shardEnvironment);

    emit(format("UT-SHARD-BEGIN %d", shard));
    {
        // Every worker runs under its parent's ONE slot. A worker that had to
        // take a slot of its own would turn one gate into N host lanes.
        import tests.unit.module_gate_lock_test : moduleGateSlot;
        if (!moduleGateSlot().borrowed)
        {
            emit("UT-SHARD-REFUSED this worker holds a run slot of its own "
               ~ "instead of borrowing its parent's");
            exit(2);
        }
    }
    size_t found;
    foreach (m; ModuleInfo)
        if (m && m.unitTest && m.name in assigned)
            ++found;
    if (found != assigned.length || !assigned.length)
    {
        emit(format("UT-SHARD-REFUSED assigned %d modules, this binary has %d "
                  ~ "of them with unittests", assigned.length, found));
        exit(2);
    }

    UnitTestResult results;
    foreach (m; ModuleInfo)
    {
        if (!m)
            continue;
        auto fp = m.unitTest;
        if (!fp || m.name !in assigned)
            continue;
        emit("UT-MOD-START " ~ m.name);
        ++results.executed;
        double elapsedMs;
        const passed = runOneModule(m, fp, elapsedMs);
        if (passed)
            ++results.passed;
        emit(format("UT-MOD %s %.3f %s", passed ? "PASS" : "FAIL", elapsedMs, m.name));
    }
    emit(format("UT-SHARD-END executed=%d passed=%d", results.executed, results.passed));
    result.close();

    // The parent prints the verdict; a worker's own summary would be a second
    // `N modules passed` line in the gate log.
    results.runMain = false;
    results.summarize = false;
    return results;
}

// ---------------------------------------------------------------------------
// Parent side.

private UnitTestResult runParallelParent(size_t jobs)
{
    import core.sys.posix.unistd : getpid;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.process : Config, Pid, spawnProcess, tryWait;
    import std.stdio : stdout;
    import tests.unit.module_gate_lock_test : moduleGateSlot;
    import tests.unit.ut_shard_plan : kPinnedGroups, mergeShards, packShards,
        parseTimings, ShardOutcome, validatePlan;

    // Discover the roster exactly as the serial loop would reach it.
    string[] roster;
    foreach (m; ModuleInfo)
        if (m && m.unitTest)
            roster ~= m.name;

    const timingsFile = buildPath(dirName(__FILE_FULL_PATH__),
                                  "unittest_module_timings.txt");
    double[string] weights;
    if (exists(timingsFile))
        weights = parseTimings(readText(timingsFile));
    const shards = packShards(roster, weights, jobs, kPinnedGroups);
    const planProblems = validatePlan(roster, shards, kPinnedGroups);
    assert(planProblems.length == 0,
        format("parallel module gate: the shard plan is invalid: %s", planProblems));

    // The lease: a slot this gate OWNS is handed down by its descriptor; a
    // borrowed one is already described by the inherited environment, which
    // names an ancestor of every worker too.
    const slot = moduleGateSlot();
    assert(slot.held, "parallel module gate: no run slot is held");
    const origPid = environment.get(leasePidEnvironment, null);
    const origFd = environment.get(leaseFdEnvironment, null);

    const pid = getpid();
    const dir = buildPath(tempDir(), format("vibe3d-ut-par-%d", pid));
    mkdirRecurse(dir);

    stderr.writefln("UT-PARALLEL jobs=%d shards=%d modules=%d plan=%s dir=%s",
                    jobs, shards.length, roster.length,
                    weights.length ? "lpt" : "round-robin", dir);

    auto baseEnv = environment.toAA;
    if (!slot.borrowed)
    {
        baseEnv[leasePidEnvironment] = pid.to!string;
        baseEnv[leaseFdEnvironment] = slot.fd.to!string;
    }

    string restoreLine(string name, string value)
    {
        return value is null ? "env-unset " ~ name : "env-set " ~ name ~ "=" ~ value;
    }

    Pid[] pids;
    string[][] assignedNames;
    string[] logs;
    const self = "/proc/self/exe";
    foreach (s, shard; shards)
    {
        string[] names;
        string assign = restoreLine(leasePidEnvironment, origPid) ~ "\n"
                      ~ restoreLine(leaseFdEnvironment, origFd) ~ "\n";
        double planned = 0;
        foreach (idx; shard)
        {
            names ~= roster[idx];
            assign ~= "module " ~ roster[idx] ~ "\n";
            planned += weights.get(roster[idx], 0);
        }
        write(buildPath(dir, format("shard-%d.assign", s)), assign);
        assignedNames ~= names;

        auto env = baseEnv.dup;
        env[shardEnvironment] = format("%d:%d:%s", s, pid, dir);
        const log = buildPath(dir, format("shard-%d.log", s));
        logs ~= log;
        // spawnProcess closes the File objects it is handed, so both are
        // opened afresh for every worker.
        auto logFile = File(log, "w");
        auto devnull = File("/dev/null", "r");
        // /proc/self/exe is resolved in the forked child before exec, so every
        // worker runs THIS binary's inode even if a rebuild replaced the path.
        pids ~= spawnProcess([self] ~ Runtime.args[1 .. $], devnull, logFile,
                             logFile, env, Config.newEnv);
        stderr.writefln("UT-PARALLEL shard %d: pid %d, %d modules, planned %.1f s",
                        s, pids[$ - 1].processID, names.length, planned / 1000.0);
    }

    const started = MonoTime.currTime;
    // Reap in completion order, so each shard's wall time is its own.
    auto statuses = new int[](pids.length);
    auto done = new bool[](pids.length);
    size_t remaining = pids.length;
    while (remaining)
    {
        bool reaped;
        foreach (s, p; pids)
        {
            if (done[s])
                continue;
            const r = tryWait(p);
            if (!r.terminated)
                continue;
            done[s] = true;
            statuses[s] = r.status;
            --remaining;
            reaped = true;
            // std.process reports a signal as a negative status.
            stderr.writefln("UT-PARALLEL shard %d finished: %s %d at %.1f s", s,
                            r.status >= 0 ? "exit" : "signal",
                            r.status >= 0 ? r.status : -r.status,
                            (MonoTime.currTime - started).total!"msecs" / 1000.0);
        }
        if (!reaped)
        {
            import core.thread : Thread;
            import core.time : msecs;
            Thread.sleep(20.msecs);
        }
    }

    ShardOutcome[] outcomes;
    foreach (s, status; statuses)
    {
        const resultPath = buildPath(dir, format("shard-%d.result", s));
        const text = exists(resultPath) ? readText(resultPath) : "";
        outcomes ~= ShardOutcome(s, assignedNames[s], text, status >= 0,
                                 status >= 0 ? status : -status);
        // Busy time inside modules, beside the wall above: the difference is
        // the worker's startup/teardown plus host contention.
        double busyMs = 0;
        foreach (line; text.splitLines)
        {
            import std.array : split;
            const f = line.split;
            if (f.length == 4 && f[0] == "UT-MOD")
                try busyMs += f[2].to!double; catch (Exception) {}
        }
        stderr.writefln("UT-PARALLEL shard %d: %d modules, %.1f s inside modules",
                        s, assignedNames[s].length, busyMs / 1000.0);
    }

    // Each worker's own output, whole and in shard order.
    foreach (s, log; logs)
    {
        stdout.flush();
        stderr.writefln("---- UT-PARALLEL shard %d output ----", s);
        stderr.write(readText(log));
    }
    stderr.writefln("---- UT-PARALLEL end of shard output ----");

    auto verdict = mergeShards(roster, outcomes);

    const timingPath = environment.get(timingEnvironment, "");
    if (timingPath.length)
    {
        // Roster order, the serial file's order.
        double[string] ms;
        foreach (r; verdict.reports)
            ms[r.name] = r.ms;
        auto timingOutput = File(timingPath, "w");
        foreach (name; roster)
            if (auto t = name in ms)
                timingOutput.writefln("UT %.3f %s", *t, name);
        timingOutput.flush();
    }

    foreach (problem; verdict.problems)
        stderr.writefln("UT-PARALLEL-INCOMPLETE %s", problem);
    if (verdict.problems.length)
        stderr.writefln("UT-PARALLEL-INCOMPLETE shard files kept in %s", dir);
    else
        rmdirRecurse(dir);
    assert(!verdict.problems.length || verdict.passed < verdict.executed,
        "parallel module gate: an incomplete run merged to a clean total");

    UnitTestResult results;
    results.executed = verdict.executed;
    results.passed = verdict.passed;
    results.runMain = false;
    results.summarize = true;
    stderr.writefln("UT-TOTAL executed=%s passed=%s",
                    results.executed, results.passed);
    verifyPopulationAndRoster(roster, results.executed);
    return results;
}
