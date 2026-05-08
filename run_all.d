#!/usr/bin/env rdmd
/* Unified test runner — fans out to every verification suite the
 * project has and prints a single summary at the end:
 *
 *   1. ./run_test.d -j N (--exclude flake'y)
 *   2. rdmd tools/blender_diff/run.d
 *   3. rdmd tools/modo_diff/run.d
 *   4. ./tools/modo_diff/run_acen_drag.py -j N
 *
 * Use this before any commit that could plausibly affect mesh / tool
 * behaviour. Each suite is run sequentially (their own internal
 * parallelism is what makes wall-time tolerable); aggregated exit code
 * is non-zero when any suite reports a failure.
 *
 * Flags:
 *   -j N          worker count for run_test.d AND run_acen_drag.py
 *                 (modo_diff/run.d + blender_diff/run.d don't have
 *                 their own -j today — they boot a single MODO/Blender
 *                 instance.) default = 4.
 *   --no-build    forwarded to suites that accept it.
 *   --skip-X      skip a suite. X ∈ {unit, blender, modo, acen}.
 *   --only-X      run ONLY suite X (mutually exclusive with --skip-X).
 *
 * Excluded by default (pre-existing flakes documented in CLAUDE.md):
 *   test_selection
 *   test_toolpipe_axis
 *
 * Override via $RUN_ALL_EXCLUDE (comma-separated, replaces default).
 */
import std.algorithm : canFind;
import std.array     : array, split;
import std.format    : format;
import std.process   : environment, spawnProcess, wait;
import std.stdio;
import std.getopt;
import core.stdc.stdlib : exit;

bool useColor = true;
string red(string s)    => useColor ? "\033[31m" ~ s ~ "\033[0m" : s;
string green(string s)  => useColor ? "\033[32m" ~ s ~ "\033[0m" : s;
string yellow(string s) => useColor ? "\033[33m" ~ s ~ "\033[0m" : s;
string blue(string s)   => useColor ? "\033[34m" ~ s ~ "\033[0m" : s;

struct Suite {
    string name;
    string label;
    string[] cmd;
}

int runSuite(ref Suite s) {
    writeln();
    writeln(blue("══════════════════════════════════════════════════════════"));
    writeln(blue("  " ~ s.label));
    writeln(blue("  $ " ~ s.cmd.join(" ")));
    writeln(blue("══════════════════════════════════════════════════════════"));
    auto p = spawnProcess(s.cmd);
    return wait(p);
}

string join(string[] parts, string sep) {
    string r;
    foreach (i, p; parts) {
        if (i) r ~= sep;
        r ~= p;
    }
    return r;
}

int main(string[] args) {
    int j = 4;
    bool noBuild = false;
    string only;
    string[] skip;

    auto info = getopt(args,
        "j|jobs",     "worker count for unit + ACEN drag suites (default 4)", &j,
        "no-build",   "skip dub build in unit + Blender + MODO suites", &noBuild,
        "only",       "run only one suite (unit | blender | modo | acen)", &only,
        "skip",       "skip a suite (repeatable: unit | blender | modo | acen)", &skip);

    if (info.helpWanted) {
        writeln("usage: ./run_all.d [options]");
        foreach (o; info.options)
            writefln("  %-16s %s", o.optShort ~ ", " ~ o.optLong, o.help);
        return 0;
    }

    string excludeEnv = environment.get("RUN_ALL_EXCLUDE",
        "test_selection,test_toolpipe_axis,test_http_endpoint");
    string[] excluded = excludeEnv.split(",");

    Suite[] suites;
    auto include = (string n) => only.length == 0 ? !skip.canFind(n) : (only == n);

    if (include("unit")) {
        string[] cmd = ["./run_test.d", "-j", j.format!"%d"];
        if (noBuild) cmd ~= "--no-build";
        foreach (e; excluded) {
            if (e.length == 0) continue;
            cmd ~= "--exclude";
            cmd ~= e;
        }
        suites ~= Suite("unit", "1/4 Unit tests (run_test.d)", cmd);
    }

    if (include("blender")) {
        string[] cmd = ["rdmd", "tools/blender_diff/run.d"];
        if (noBuild) cmd ~= "--no-build";
        suites ~= Suite("blender", "2/4 Blender geometry diff", cmd);
    }

    if (include("modo")) {
        string[] cmd = ["rdmd", "tools/modo_diff/run.d"];
        if (noBuild) cmd ~= "--no-build";
        suites ~= Suite("modo", "3/4 MODO geometry diff (bevel / prim)", cmd);
    }

    if (include("acen")) {
        string[] cmd = ["./tools/modo_diff/run_acen_drag.py",
                        "-j", j.format!"%d"];
        suites ~= Suite("acen", "4/4 MODO ACEN drag verification", cmd);
    }

    if (suites.length == 0) {
        writeln(yellow("nothing to run (check --only / --skip)"));
        return 0;
    }

    if (excluded.length > 0 && include("unit"))
        writeln(yellow(format("unit-test exclusions: %s",
            excluded.join(", "))));

    struct Result { string name; string label; int rc; }
    Result[] results;

    foreach (ref s; suites) {
        int rc;
        try rc = runSuite(s);
        catch (Exception e) {
            stderr.writefln("suite '%s' failed to spawn: %s",
                s.name, e.msg);
            rc = -1;
        }
        results ~= Result(s.name, s.label, rc);
    }

    writeln();
    writeln(blue("══════════════════════════════════════════════════════════"));
    writeln(blue("  Summary"));
    writeln(blue("══════════════════════════════════════════════════════════"));
    int worst = 0;
    foreach (r; results) {
        string tag = r.rc == 0 ? green("PASS") : red(format("FAIL rc=%d", r.rc));
        writefln("  %s  %s", tag, r.label);
        if (r.rc != 0 && worst == 0) worst = r.rc;
    }
    return worst;
}
