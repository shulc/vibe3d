// Module-unit-test runner for the `tests` configuration (task 4931).  Its
// execution loop mirrors druntime's runModuleUnitTests loop; the only work
// inside each module boundary is a MonoTime measurement.  The checked roster
// and exact population floor keep a missing registration from becoming a
// quiet successful run.
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

private enum expectedModuleCount = 525;
private enum timingEnvironment = "VIBE3D_UT_TIMINGS";

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

    assert(expected.length == expectedModuleCount,
        "unit-test roster must contain exactly "
        ~ expectedModuleCount.to!string ~ " modules; found "
        ~ expected.length.to!string);
    assert(isSorted(expected),
        "unit-test module roster must remain sorted");
    assert(executed == expectedModuleCount,
        "unit-test module population changed: executed "
        ~ executed.to!string ~ ", expected "
        ~ expectedModuleCount.to!string);
    assert(actual == expected,
        "unit-test module roster changed; update only after reviewing the full diff");
}

private UnitTestResult runModuleUnitTestsWithTimings()
{
    UnitTestResult results;
    string[] actualRoster;

    const timingPath = environment.get(timingEnvironment, "");
    File timingOutput;
    const timingEnabled = timingPath.length != 0;
    if (timingEnabled)
        timingOutput = File(timingPath, "w");

    foreach (m; ModuleInfo)
    {
        if (!m)
            continue;
        auto fp = m.unitTest;
        if (!fp)
            continue;

        actualRoster ~= m.name;
        ++results.executed;
        const started = MonoTime.currTime;
        MonoTime stopped;
        try
        {
            fp();
            stopped = MonoTime.currTime;
            ++results.passed;
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
        if (timingEnabled)
        {
            const elapsedMs = (stopped - started).total!"usecs" / 1000.0;
            timingOutput.writefln("UT %.3f %s", elapsedMs, m.name);
        }
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
