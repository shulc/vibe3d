module tools.harness.hostspace;

import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
import std.conv    : to;
import std.file    : exists;
import std.format  : format;
import std.path    : dirName;
import std.process : execute, environment;
import std.range   : empty;
import std.regex   : matchFirst, regex;
import std.string  : toStringz;

// The fixed 256 MiB refusal floor is task 2080's invariant; evidence: doc/tasks/done/2080-scratch-in-ram-starves-the-host.md.
enum ulong kMinPreflightFreeBytes = 256UL * 1024 * 1024;
// /var/tmp keeps the measured 9.59 GB -j 6 scratch off quota-limited /tmp (tasks 5502/5520); evidence: doc/tasks/done/5520-scratch-root-and-quota.md.
enum kDefaultScratchRoot = "/var/tmp";
enum kScratchRootTestEnv = "VIBE3D_TEST_DEFAULT_SCRATCH_ROOT";
enum kQuotaAvailableTestEnv = "VIBE3D_TEST_QUOTA_AVAILABLE_BYTES";

/// TMPDIR is the caller's explicit isolation contract. The test seam replaces
/// only the default arm; production callers fall back to the root filesystem.
string scratchRoot()
{
    const configured = environment.get("TMPDIR", "");
    if (configured.length) return configured;
    const testDefault = environment.get(kScratchRootTestEnv, "");
    return testDefault.length ? testDefault : kDefaultScratchRoot;
}

private string existingAncestor(string path)
{
    string p = path;
    while (p.length && !exists(p))
    {
        const parent = dirName(p);
        if (parent == p) break;
        p = parent;
    }
    return p.length && exists(p) ? p : null;
}

/// Free blocks on the filesystem containing `path`. A cold path is queried at
/// its nearest existing ancestor. Query failures fail open as `ulong.max`.
ulong freeBytes(string path)
{
    const p = existingAncestor(path);
    if (!p.length) return ulong.max;

    statvfs_t st;
    if (statvfs(p.toStringz, &st) != 0) return ulong.max;
    return cast(ulong) st.f_bavail * cast(ulong) st.f_frsize;
}

/// Parse the first quota data row. Quota block columns are KiB. A zero limit,
/// malformed output, or overflow is an unknown/unlimited answer and fails open.
ulong parseQuotaAvailableBytes(string output)
{
    try
    {
        auto row = output.matchFirst(regex(
            r"(?m)^\s*(.*?)\s+([0-9]+)\*?\s+([0-9]+)\s+([0-9]+)(?:\s|$)"));
        if (row.empty) return ulong.max;

        const used = row[2].to!ulong;
        const soft = row[3].to!ulong;
        const hard = row[4].to!ulong;
        ulong limit;
        if (soft && hard) limit = soft < hard ? soft : hard;
        else              limit = soft ? soft : hard;
        if (!limit) return ulong.max;

        const remainingKiB = used < limit ? limit - used : 0;
        if (remainingKiB > ulong.max / 1024) return ulong.max;
        return remainingKiB * 1024;
    }
    catch (Exception)
    {
        return ulong.max;
    }
}

/// Remaining user block quota for the filesystem containing `path`. Missing
/// quota support and failed queries fail open as `ulong.max`.
ulong quotaAvailableBytes(string path)
{
    const injected = environment.get(kQuotaAvailableTestEnv, "");
    if (injected.length) return injected.to!ulong;

    const p = existingAncestor(path);
    if (!p.length) return ulong.max;

    try
    {
        string[string] env;
        foreach (k, v; environment.toAA) env[k] = v;
        env["LC_ALL"] = "C";
        const result = execute(["quota", "-w", "-v", "-p",
            "--show-mntpoint", "--hide-device", "-f", p], env);
        if (result.status != 0) return ulong.max;
        return parseQuotaAvailableBytes(result.output);
    }
    catch (Exception)
    {
        return ulong.max;
    }
}

struct SpaceAvailability
{
    ulong filesystemFree;
    ulong quotaRemaining;

    @property ulong available() const
    {
        return filesystemFree < quotaRemaining ? filesystemFree : quotaRemaining;
    }
}

SpaceAvailability spaceAvailability(string path)
{
    return SpaceAvailability(freeBytes(path), quotaAvailableBytes(path));
}

string humanBytes(ulong b)
{
    enum double Ki = 1024.0, Mi = Ki * 1024, Gi = Mi * 1024;
    if (b == ulong.max)       return "unknown";
    if (b >= cast(ulong) Gi) return format("%.1f GiB", b / Gi);
    if (b >= cast(ulong) Mi) return format("%.1f MiB", b / Mi);
    if (b >= cast(ulong) Ki) return format("%.1f KiB", b / Ki);
    return format("%d B", b);
}

string availabilityDetails(SpaceAvailability space)
{
    if (space.quotaRemaining == ulong.max)
        return format("%s filesystem free, quota unlimited or unavailable",
                      humanBytes(space.filesystemFree));
    return format("%s filesystem free, %s quota remaining",
                  humanBytes(space.filesystemFree),
                  humanBytes(space.quotaRemaining));
}

/// The one refusal decision shared by the test runner and sanitizer lane.
/// Unknown availability never refuses; known availability refuses only below
/// the fixed floor.
string spacePreflightMessage(SpaceAvailability space, ulong floor, string path)
{
    if (space.available == ulong.max || space.available >= floor) return null;
    return format(
        "no space left: %s has %s available (%s), below the %s floor -- refusing to "
        ~ "start rather than fail mid-run and disguise it as red tests "
        ~ "(tasks 2080/5502)", path, humanBytes(space.available),
        availabilityDetails(space), humanBytes(floor));
}

unittest
{
    enum KiB = 1024UL;

    assert(parseQuotaAvailableBytes("/mnt 100 250 0\n") == 150 * KiB,
        "soft-only quota must subtract used KiB from the soft limit");
    assert(parseQuotaAvailableBytes("/mnt 100 0 400\n") == 300 * KiB,
        "hard-only quota must subtract used KiB from the hard limit");
    assert(parseQuotaAvailableBytes("/mnt 100 500 300\n") == 200 * KiB,
        "asymmetric soft/hard quota must choose the smaller non-zero limit");
    assert(parseQuotaAvailableBytes("/mnt 350 500 300\n") == 0,
        "quota used past the chosen limit must report zero remaining");
    assert(parseQuotaAvailableBytes("/mnt 100 0 0\n") == ulong.max,
        "zero soft and hard limits must mean unlimited/unknown quota");
    assert(parseQuotaAvailableBytes("quota: unavailable\n") == ulong.max,
        "malformed or unavailable quota output must fail open");
}

unittest
{
    enum floor = kMinPreflightFreeBytes;

    assert(spacePreflightMessage(SpaceAvailability(floor, ulong.max),
                                 floor, "/scratch") is null,
        "availability exactly at the floor must pass");
    assert(spacePreflightMessage(SpaceAvailability(floor - 1, ulong.max),
                                 floor, "/scratch") !is null,
        "known availability below the floor must refuse");
    assert(spacePreflightMessage(SpaceAvailability(ulong.max, ulong.max),
                                 floor, "/scratch") is null,
        "unknown filesystem and quota availability must fail open");
}
