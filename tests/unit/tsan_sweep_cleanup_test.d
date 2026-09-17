// A sweep that refuses its route table must invalidate every artifact before
// exiting. Drive the real lane entry point in an isolated cwd: a source table
// with one route forces the completeness refusal before any editor can spawn.
module tests.unit.tsan_sweep_cleanup_test;

import std.algorithm : canFind;
import std.conv      : to;
import std.file      : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path      : buildPath, dirName;
import std.process   : Config, execute, thisProcessID;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum lanePath = buildPath(repoRoot, "tools", "sanitizer", "lane.d");

unittest
{
    const root = buildPath(tempDir(), "vibe3d-tsan-sweep-cleanup-"
        ~ thisProcessID.to!string);
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "source"));
    scope(exit) if (exists(root)) rmdirRecurse(root);

    write(buildPath(root, "source", "http_server.d"),
        "private enum RouteSpec[] kRoutes = [\n"
      ~ "    RouteSpec(\"/fixture-only\", \"GET\", Match.exact, "
      ~ "Answered.httpThread, \"fixture\"),\n"
      ~ "];\n");

    const report = buildPath(root, "tsan-report-sweep.2179414");
    const sentinel = buildPath(root, "tsan-sweep.done");
    write(report, "stale report\n");
    write(sentinel, "{\"stale\":true}\n");

    auto run = execute(["rdmd", "--force", "-I" ~ repoRoot, lanePath,
                        "tsan-sweep"], null, Config.none, size_t.max, root);

    assert(run.status != 0,
        "the deliberately incomplete route table must refuse the sweep:\n"
        ~ run.output);
    assert(run.output.canFind("lane.d: FAIL: the sweep does not cover kRoutes."),
        "the fixture must fail specifically at the completeness gate:\n"
        ~ run.output);
    assert(!exists(report),
        "stale TSan report survived a sweep completeness refusal");
    assert(!exists(sentinel),
        "stale TSan sentinel survived a sweep completeness refusal");
}
