#!/usr/bin/env rdmd
/* Unified test runner — fans out to every verification suite the
 * project has and prints a single summary at the end:
 *
 *   1. ./run_test.d -j N (no default excludes — see flake note below)
 *   2. rdmd tools/local/blender_diff/run.d
 *   3. rdmd tools/local/modo_diff/run.d
 *   4. ./tools/local/modo_diff/run_acen_drag.py -j N
 *   5. snapshot: the key undo tests forced onto the legacy MeshSnapshot
 *      path (VIBE3D_UNDO_TRACKER=off) — anti-rot coverage for the escape
 *      hatch now that the change-tracker is default-on (Phase 4).
 *   6. dub test --config=modeling — runs ALL module-level unittests in the
 *      project source, including modules not directly imported by any test
 *      binary (math.d, command_history.d, …). The HTTP-suite (run_test.d)
 *      links a static lib and only pulls referenced members, so unittests
 *      in imported modules are SILENT there. This lane catches what the
 *      static-lib path misses.  See run_test.d:425-434 for the documented
 *      limitation that motivated this lane.
 *   7. rdmd tools/perf/run.d --n 64 --no-absolute (relative invariants)
 *
 * Opt-in (NOT in the default set, runs only via --only perf-abs):
 *   perf-abs: rdmd tools/perf/run.d --n 316 — the FULL ~100K-face matrix
 *             with the ABSOLUTE comparison against the committed
 *             tools/perf/baseline.json (plus invariants). ~5 min; the
 *             baseline header's host field lets it auto-skip the absolute
 *             leg on a different machine (falls back to invariants).
 *
 * Suites 2-4 are reference-comparison harnesses that drive external
 * engines; they live under tools/local/ (gitignored, local-only) and
 * are skipped automatically when that directory is absent.
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
 *   --no-build    forwarded to suites that accept it. NOTE: the dubtest lane
 *                 always compiles (dub test has no --no-build equivalent);
 *                 --no-build is accepted but ignored for that lane.
 *   --skip-X      skip a suite. X ∈ {unit, blender, modo, acen, perf, snapshot,
 *                 dubtest}.
 *   --only-X      run ONLY suite X (mutually exclusive with --skip-X).
 *                 X ∈ {unit, blender, modo, acen, perf, snapshot, dubtest,
 *                 perf-abs}; perf-abs is opt-in (n=316, ~5 min, absolute vs the
 *                 committed baseline) and runs ONLY via --only perf-abs.
 *
 * Flake note (NO default exclusions as of the -j8 hardening pass). The
 * historical -j8 flakes had two distinct root causes, both now fixed:
 *
 *   (a) cross-test state bleed — a worker reuses ONE shared `vibe3d --test`
 *       across its whole slice of tests, so a preceding test could leave the
 *       mesh / selection / undo stack / a draining event-replay dirty for the
 *       next one (test_http_endpoint "Expected 8 vertices for a cube",
 *       test_selection "expected 2 ... got 0", test_property_panel_drag "got
 *       (-1,0,1)"). FIXED by a runner-level reset between every test binary
 *       (run_test.d resetBetweenTests) plus per-test reset preambles and a
 *       post-play-events settle that lets the SDL queue drain before the read.
 *
 *   (b) post-playback drain race — a test polled /api/play-events/status
 *       for "finished" then read the selection IMMEDIATELY, but "finished"
 *       fires once events are DISPATCHED onto the SDL queue, not processed;
 *       the last gesture's click drained a frame or two later, so the read
 *       saw a stale selection (test_selection / test_interactive_select_undo
 *       "expected 3 ... got 2" on selection_add.log). FIXED by a settle after
 *       the finished-poll, before the read.
 *
 *   (c) compositor swap-park — in --test the app used to create a VISIBLE
 *       vsynced GL window; 8 of them on one compositor contended on Mesa/EGL
 *       locks and ~1-in-6 runs parked a worker's main thread forever in the
 *       GL swap path (HTTP thread alive, main loop dead ⇒ the race-free
 *       /api/model read spins on a completedEpoch the dead loop never bumps).
 *       HIDDEN + vsync-off only REDUCED the rate (a hidden Wayland surface
 *       still drives the driver's swap/buffer locks). FIXED by skipping
 *       SDL_GL_SwapWindow entirely in --test (nothing reads back a presented
 *       frame; a local glFlush keeps the command buffer bounded). --perf still
 *       presents. A 4ms per-frame floor keeps 8 uncapped workers civil on CPU.
 *
 * Evidence for dropping the excludes: 10 consecutive full
 * `./run_test.d --no-build -j 8` runs with NO excludes ran 10/10 green
 * (130/130 each, ~66-84s/run, zero hangs, zero failures) — including the four
 * formerly-excluded tests (test_selection, test_toolpipe_axis,
 * test_http_endpoint, test_property_panel_drag) and the two formerly-watched
 * ones (test_reevaluate, test_primitive_pen).
 *
 * Override via $RUN_ALL_EXCLUDE (comma-separated) to re-quarantine a test if a
 * new flake ever surfaces.
 */
import std.algorithm : canFind, clamp;
import std.array     : array, split;
import std.format    : format;
import std.parallelism : totalCPUs;
import std.process   : environment, spawnProcess, wait;
import std.file      : exists;
import std.stdio;
import std.getopt;
import core.stdc.stdlib : exit;

// Machine-aware default worker count, mirroring run_test.d's defaultJobs():
// clamp(totalCPUs/4, 4, 12). Each worker boots its own engine instance, so we
// scale with the host without going 1:1 with cores. VIBE3D_TEST_JOBS pins it
// per host (export it in your shell rc); an explicit -j still overrides. CI
// passes -j$(nproc) — the prebuilt-lib test path keeps per-worker RAM low.
int defaultJobs() {
    import std.conv : to;
    const env = environment.get("VIBE3D_TEST_JOBS", "");
    if (env.length) {
        try { const n = env.to!int; if (n >= 1) return n; } catch (Exception) {}
    }
    return clamp(cast(int)totalCPUs / 4, 4, 12);
}

bool useColor = true;
string red(string s)    => useColor ? "\033[31m" ~ s ~ "\033[0m" : s;
string green(string s)  => useColor ? "\033[32m" ~ s ~ "\033[0m" : s;
string yellow(string s) => useColor ? "\033[33m" ~ s ~ "\033[0m" : s;
string blue(string s)   => useColor ? "\033[34m" ~ s ~ "\033[0m" : s;

struct Suite {
    string name;
    string label;
    string[] cmd;
    string[string] env;   // extra env vars layered over the parent env (empty = inherit)
}

int runSuite(ref Suite s) {
    writeln();
    writeln(blue("══════════════════════════════════════════════════════════"));
    writeln(blue("  " ~ s.label));
    string envPrefix;
    foreach (k, v; s.env) envPrefix ~= k ~ "=" ~ v ~ " ";
    writeln(blue("  $ " ~ envPrefix ~ s.cmd.join(" ")));
    writeln(blue("══════════════════════════════════════════════════════════"));
    if (s.env.length == 0) {
        auto p = spawnProcess(s.cmd);
        return wait(p);
    }
    // Layer the suite's env over the inherited environment.
    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    foreach (k, v; s.env) env[k] = v;
    auto p = spawnProcess(s.cmd, std.stdio.stdin, std.stdio.stdout,
                          std.stdio.stderr, env);
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
    int j = defaultJobs();
    bool noBuild = false;
    string only;
    string[] skip;

    auto info = getopt(args,
        "j|jobs",     "worker count for unit + ACEN drag suites "
                    ~ "(default = clamp(cpus/4, 4, 12))", &j,
        "no-build",   "skip dub build in unit + Blender + MODO suites", &noBuild,
        "only",       "run only one suite (unit | blender | modo | acen | perf | snapshot | dubtest | perf-abs)", &only,
        "skip",       "skip a suite (repeatable: unit | blender | modo | acen | perf | snapshot | dubtest)", &skip);

    if (info.helpWanted) {
        writeln("usage: ./run_all.d [options]");
        foreach (o; info.options)
            writefln("  %-16s %s", o.optShort ~ ", " ~ o.optLong, o.help);
        return 0;
    }

    // No default exclusions: the cross-test state-bleed flake family is fixed
    // (between-test reset + per-test reset preambles + post-playback settle) and
    // the -j8 compositor swap-park hang is gone (hidden window + vsync-off in
    // --test). A 10× consecutive full `./run_test.d --no-build -j 8` matrix with
    // NO excludes ran 10/10 green (129/129 each, 51-73s, zero hangs). Override
    // via $RUN_ALL_EXCLUDE if a new flake ever needs quarantining.
    string excludeEnv = environment.get("RUN_ALL_EXCLUDE", "");
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
        suites ~= Suite("unit", "1/7 Unit tests (run_test.d)", cmd);
    }

    // (MS-3.6) The MS-2 shadow lane was retired with the shadow itself: it gated
    // the live apply against a reconstruction of the LEGACY decomposed chain, but
    // MS-4.3/4.4 replaced that chain with the canonical-matrix fold (validated
    // against the reference-parity fixtures instead). The fold's parity is now
    // covered by the unit lane (test_fixture_falloff_{multi,multi_http,local}).

    if (include("blender")) {
        if (exists("tools/local/blender_diff/run.d")) {
            string[] cmd = ["rdmd", "tools/local/blender_diff/run.d"];
            if (noBuild) cmd ~= "--no-build";
            suites ~= Suite("blender", "2/7 reference geometry diff (blender)", cmd);
        } else {
            writeln(yellow("- skipped blender suite (tools/local/blender_diff not present)"));
        }
    }

    if (include("modo")) {
        if (exists("tools/local/modo_diff/run.d")) {
            string[] cmd = ["rdmd", "tools/local/modo_diff/run.d"];
            if (noBuild) cmd ~= "--no-build";
            suites ~= Suite("modo", "3/7 reference geometry diff (bevel / prim)", cmd);
        } else {
            writeln(yellow("- skipped modo suite (tools/local/modo_diff not present)"));
        }
    }

    if (include("acen")) {
        if (exists("tools/local/modo_diff/run_acen_drag.py")) {
            string[] cmd = ["./tools/local/modo_diff/run_acen_drag.py",
                            "-j", j.format!"%d"];
            suites ~= Suite("acen", "4/7 ACEN drag verification", cmd);
        } else {
            writeln(yellow("- skipped acen suite (tools/local/modo_diff not present)"));
        }
    }

    // Snapshot-fallback lane (anti-rot). As of Phase 4 the undo change-tracker
    // (doc/undo_change_tracker_plan.md) is DEFAULT-ON, so the whole unit suite now
    // exercises the operation-log delta path for every extrude/delete/remove/
    // dissolve. The legacy whole-mesh MeshSnapshot path is RETAINED as the escape
    // hatch (VIBE3D_UNDO_TRACKER=off) but would otherwise stop being tested. This
    // lane re-runs the key undo tests with the env var forced OFF so the snapshot
    // path keeps regression coverage. Cheap (six small tests, -j 1 for the drag-
    // sensitive ones), included in the DEFAULT set; --skip snapshot / --only
    // snapshot both work. Runs BEFORE the perf lane: the perf runner rebuilds
    // ./vibe3d as the ldc-release perf buildType, and any run_test lane placed
    // after it would silently reuse that binary instead of the modeling one.
    if (include("snapshot")) {
        string[] cmd = ["./run_test.d", "-j", "1",
                        "test_undo_redo", "test_delete", "test_edge_extrude_tool",
                        "test_undo_tracker_extrude", "test_undo_tracker_delete",
                        "test_history_jump"];
        if (noBuild) cmd ~= "--no-build";
        suites ~= Suite("snapshot",
                        "5/7 snapshot-fallback undo tests (VIBE3D_UNDO_TRACKER=off)",
                        cmd, ["VIBE3D_UNDO_TRACKER": "off"]);
    }

    // dub-test lane — runs `dub test --config=modeling` to execute ALL module-level
    // unittests in the project source tree.  The HTTP-suite (run_test.d) builds a
    // static lib and only pulls referenced members, so any unittest that lives in a
    // module that a given test binary does not import is SILENTLY SKIPPED there
    // (documented at run_test.d:425-434).  This lane has no such blind spot: dub's
    // test runner compiles everything and runs every `unittest { }` block.
    //
    // `--no-build` is accepted but does NOT suppress this lane: dub test always
    // recompiles before running unittests; there is no stable artifact to skip.
    // When --no-build is set we emit a note so the caller is not surprised by the
    // extra compile.
    //
    // The lane must run BEFORE perf: the perf runner replaces ./vibe3d with the
    // ldc-release perf binary.  dub test operates on its own configuration and
    // doesn't touch ./vibe3d, so ordering here is merely defensive.
    if (include("dubtest")) {
        if (noBuild)
            writeln(yellow("- note: dubtest lane always compiles (dub test has "
                ~ "no --no-build equivalent)"));
        string[] cmd = ["dub", "test", "--config=modeling"];
        suites ~= Suite("dubtest",
                        "6/7 module unittests (dub test --config=modeling)", cmd);
    }

    // Perf lane — RELATIVE INVARIANTS ONLY on a small (n=64) mesh. A full
    // 100K × 36 × R run is slow and absolute timing is machine-bound, so the
    // run_all lane skips the absolute baseline comparison (--no-absolute) and
    // relies on the hardware-stable ratio invariants (I1–I4), which are
    // designed to tolerate the noise of a loaded parallel suite. Included in
    // the DEFAULT set: the invariants are cheap (~25s at n=64) and noise-robust;
    // --skip perf / --only perf both work.
    //
    // --no-build SKIPS this lane entirely: the invariants are only meaningful
    // on the perf buildType (versions=["PerfProbe"] — every other build
    // compiles the probes to no-ops and the counters stay 0), and ./vibe3d on
    // disk after a normal build is the modeling debug binary. Forwarding
    // --no-build used to fail the lane with meaningless zero-count invariant
    // errors. The lane is LAST in the default set because its build replaces
    // ./vibe3d with the perf binary.
    // (An explicit `--only perf` still runs it — building the perf binary —
    // since the user asked for exactly this lane; --no-build is never
    // forwarded to the perf runner, whose own dub build is incremental.)
    if (include("perf")) {
        if (noBuild && only != "perf") {
            writeln(yellow("- skipped perf lane (--no-build: invariants need "
                ~ "the perf buildType; run `./run_all.d --only perf` or "
                ~ "`rdmd tools/perf/run.d --n 64 --no-absolute`)"));
        } else {
            string[] cmd = ["rdmd", "tools/perf/run.d", "--n", "64",
                            "--no-absolute"];
            suites ~= Suite("perf", "7/7 perf relative invariants (n=64)", cmd);
        }
    }

    // perf-abs lane — OPT-IN, NEVER in the default set. Runs the full n=316
    // (~100K-face) matrix WITHOUT --no-absolute, i.e. it performs the absolute
    // comparison against the committed tools/perf/baseline.json (plus the
    // relative invariants). Slow (~5 min) and machine-bound, so it is gated on
    // an explicit `--only perf-abs`: an empty `only` (the default run) never
    // includes it, and `--skip` is irrelevant to it. The host field in the
    // baseline header lets run.d auto-skip the absolute leg on a different
    // machine (falling back to invariants). Uses the perf buildType (ldc2),
    // built by the runner itself unless --no-build is forwarded.
    if (only == "perf-abs") {
        string[] cmd = ["rdmd", "tools/perf/run.d", "--n", "316"];
        if (noBuild) cmd ~= "--no-build";
        suites ~= Suite("perf-abs",
                        "perf absolute vs 100K baseline (n=316)", cmd);
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
