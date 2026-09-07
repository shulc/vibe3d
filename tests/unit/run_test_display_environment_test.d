// Runner-owned application processes must not inherit the caller's DISPLAY
// (task 4660). A parallel suite owns ports and scratch per worker, but one
// inherited X socket would still be shared by every worker. `--attach` is the
// opposite ownership boundary: its endpoint was launched externally and the
// runner must neither spawn it nor rewrite its environment.
module tests.unit.run_test_display_environment_test;

import std.exception : enforce;
import std.file      : exists, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : sharedBlankNonCode = blankNonCode;

private alias blankNonCode = sharedBlankNonCode;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

private string functionBody(string code, string signature)
{
    const fn = code.indexOf(signature);
    enforce(fn >= 0, "run_test.d no longer defines `" ~ signature ~ "`");
    size_t i = cast(size_t) fn;
    while (i < code.length && code[i] != '{') i++;
    enforce(i < code.length, "no body for `" ~ signature ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; i++)
    {
        if (code[i] == '{') depth++;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    enforce(false, "unterminated body for `" ~ signature ~ "`");
    return null;
}

private bool startVibeDropsDisplay(string src)
{
    const rawBody = functionBody(src, "Pid startVibe(");
    const body_ = blankNonCode(rawBody);
    const copy = body_.indexOf("environment.toAA()") >= 0;
    const drop = body_.indexOf("childEnv.remove(") >= 0
              && rawBody.indexOf(`childEnv.remove("DISPLAY")`) >= 0;
    const spawnAt = body_.indexOf("spawnProcess(");
    const spawn = spawnAt >= 0
        && body_[cast(size_t) spawnAt .. $].indexOf(
            "childEnv, Config.suppressConsole | Config.newEnv") >= 0;
    return copy && drop && spawn;
}

unittest
{
    enforce(exists(runnerPath), "run_test.d not found at " ~ runnerPath);
    const src = readText(runnerPath);

    assert(startVibeDropsDisplay(src),
        "run_test.d startVibe still passes the inherited environment to its "
      ~ "runner-owned application process. Copy `environment`, remove exactly "
      ~ "DISPLAY, and pass that map with Config.newEnv to spawnProcess; a caller must not need "
      ~ "`env -u DISPLAY` to keep parallel workers off one X socket.");

    // The predicate has both signs in this run. A comment or an unused copy is
    // insufficient: the environment map must be the spawnProcess argument.
    enum live = q{
        Pid startVibe(ushort port, string logPath) {
            auto logFile = File(logPath, "wb");
            auto childEnv = environment.toAA();
            childEnv.remove("DISPLAY");
            return spawnProcess(argv, stdin, logFile, logFile,
                childEnv, Config.suppressConsole | Config.newEnv);
        }
    };
    enum dead = q{
        Pid startVibe(ushort port, string logPath) {
            auto childEnv = environment.toAA();
            childEnv.remove("DISPLAY");
            return spawnProcess(argv, stdin, logFile, logFile,
                null, Config.suppressConsole | Config.newEnv);
        }
    };
    assert(startVibeDropsDisplay(live),
        "display-isolation predicate rejected a live environment handoff");
    assert(!startVibeDropsDisplay(dead),
        "display-isolation predicate accepted an unused environment copy");

    // Attach must remain outside the owned-spawn path: the early return on an
    // external endpoint precedes the only startVibe call in prepareWorker.
    const prepare = functionBody(blankNonCode(src), "bool prepareWorker(");
    const attachAt = prepare.indexOf("g_attachPort != 0");
    const spawnAt  = prepare.indexOf("startVibe(");
    assert(attachAt >= 0 && spawnAt >= 0 && attachAt < spawnAt, format(
        "prepareWorker no longer handles --attach before startVibe "
      ~ "(attach offset %d, spawn offset %d); an external visual endpoint "
      ~ "must keep its caller-owned display environment", attachAt, spawnAt));
}
