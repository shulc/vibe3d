// Behavioural witness for the runner-owned application environment (task
// 5010). Unlike run_test_display_environment_test.d, this does not inspect
// source text: the shipped runner calls its real startVibe spawn path, and the
// probe reads DISPLAY from /proc/<worker-pid>/environ after exec. A harmless
// fake ./vibe3d keeps the child alive without requiring any display server.
module tests.unit.run_test_worker_display_behavior_test;

version (linux)
{

import std.conv      : octal;
import std.exception : enforce;
import std.file      : exists, mkdirRecurse, rmdirRecurse,
                       setAttributes, tempDir, write;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : Config, environment, execute, thisProcessID;
import std.string    : indexOf, strip;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");
private enum optInEnv   = "VIBE3D_TEST_DISPLAY";

private struct Observation
{
    bool present;
    string value;
    string output;
}

private Observation observeWorkerDisplay(string label, string callerDisplay,
                                         bool optInPresent, string optInDisplay)
{
    const root = buildPath(tempDir(), format("vibe3d-worker-display-%d-%s",
                                             thisProcessID, label));
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    const fakeWorker = buildPath(root, "vibe3d");
    write(fakeWorker, "#!/usr/bin/python3\nimport time\ntime.sleep(10)\n");
    setAttributes(fakeWorker, octal!755);

    auto env = environment.toAA;
    env["DISPLAY"] = callerDisplay;
    if (optInPresent) env[optInEnv] = optInDisplay;
    else              env.remove(optInEnv);
    // A test-spawned runner never writes the host load log or takes the host's
    // production lock, even if this diagnostic is later moved below them.
    env["VIBE3D_HARNESS_LOG"] = "off";
    env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = buildPath(root, "run.lock");

    const result = execute([runnerPath, "--probe-worker-display", "--port", "8510"],
                           env, Config.none, size_t.max, root);
    enforce(result.status == 0, format(
        "%s: worker-display probe failed with rc=%d:\n%s",
        label, result.status, result.output));

    enum presentPrefix = "WORKER DISPLAY PRESENT=";
    const presentAt = result.output.indexOf(presentPrefix);
    if (presentAt >= 0) {
        const begin = cast(size_t)presentAt + presentPrefix.length;
        auto end = result.output[begin .. $].indexOf('\n');
        const value = end < 0
            ? result.output[begin .. $].strip
            : result.output[begin .. begin + cast(size_t)end];
        return Observation(true, value, result.output);
    }
    enforce(result.output.indexOf("WORKER DISPLAY ABSENT") >= 0, format(
        "%s: worker-display probe returned no observation:\n%s",
        label, result.output));
    return Observation(false, null, result.output);
}

unittest
{
    const observed = observeWorkerDisplay(
        "default", ":caller-default", false, null);
    assert(!observed.present, format(
        "default isolation leaked caller DISPLAY; expected ABSENT, got `%s`:\n%s",
        observed.value, observed.output));
}

unittest
{
    const observed = observeWorkerDisplay(
        "optin", ":caller-optin", true, ":chosen-optin");
    assert(observed.present && observed.value == ":chosen-optin", format(
        "non-empty VIBE3D_TEST_DISPLAY did not replace caller DISPLAY; "
      ~ "expected `:chosen-optin`, got %s`%s`:\n%s",
        observed.present ? "" : "ABSENT instead of ", observed.value,
        observed.output));
}

unittest
{
    const observed = observeWorkerDisplay(
        "empty", ":caller-empty", true, "");
    assert(!observed.present, format(
        "empty VIBE3D_TEST_DISPLAY must mean no opt-in; expected DISPLAY "
      ~ "ABSENT, got a present value `%s`:\n%s",
        observed.value, observed.output));
}
}
