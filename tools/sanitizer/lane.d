#!/usr/bin/env rdmd
/**
 * tools/sanitizer/lane.d — the instrumented nightly lane's build, staging and
 * preflight mechanics (task 1410). Run with `rdmd tools/sanitizer/lane.d <cmd>`.
 *
 * Everything here exists because one of the following would otherwise be true
 * silently, and each has already cost this project a run:
 *
 *   * the lane builds with a compiler that cannot build vibe3d, and the
 *     failure reads as "the instrumented build is broken";
 *   * the lane runs an UNINSTRUMENTED binary all night and reports health;
 *   * the lane leaves an instrumented binary at ./vibe3d and the 03:30 perf
 *     nightly measures it;
 *   * the lane runs against the real display and one editor boot costs 12.5 GiB;
 *   * the private fuzzer's symlink is dead and the fuzzing step is quietly a
 *     no-op;
 *   * "release is untouched" is asserted with a command that cannot fail.
 *
 * SUBCOMMANDS
 *   restore-dmd-archives    rebuild the worktree's nfde archive with dmd so
 *                           run_test.d's source-backed tests can LINK
 *   preflight               every check that needs no build (toolchain,
 *                           display, private symlink, release-untouched)
 *   build      <buildType>  build it with the right compiler and MOVE the
 *                           result to ./vibe3d-<buildType>
 *   stage      <buildType>  copy ./vibe3d-<buildType> to ./vibe3d (run_test.d
 *                           hardcodes that path) and write the build stamp
 *   verify     <buildType> [more...]
 *                           assert each named binary carries the
 *                           instrumentation its buildType promises
 *   boot       <buildType>  boot it under Xvfb and assert a clean startup plus
 *                           a registered selftest.fault
 *   teardown                delete ./vibe3d so no later --no-build run can
 *                           read an instrumented binary
 *
 * THE ThreadSanitizer LANE (task 1411) adds, on top of the same mechanics:
 *   preflight-tsan          the checks that are specific to the tsan workflow
 *                           (symbolize=0 nowhere, the expected-signature and
 *                           canary files parse, the window arithmetic closes)
 *   window-guard <event>    refuse a `schedule` start that would COLLIDE on
 *                           this single-job runner; pass loudly, not refuse,
 *                           for a late-but-safe start between the ideal
 *                           window's close and the hard ceiling, and for one
 *                           that has drifted clean OUT of the slot and
 *                           collides with nothing. All three boundaries are
 *                           COMPUTED, never stored as literals. Accepted set
 *                           measured by sweeping all 1440 minutes:
 *                           {00:00} u [04:30, 19:30) u [23:30, 24:00), i.e.
 *                           931/1440 minutes against the 150 the old
 *                           membership test allowed. UNCHANGED by the
 *                           2026-08-30 cron move to 04:30 — the guard never
 *                           reads the cron — but from that target the set
 *                           reads as 15 CONTIGUOUS hours of drift tolerance
 *                           instead of 2.5h plus two islands, and
 *                           [04:30, 17:00) is now a quiet `pass` rather than
 *                           a loud `passOffSlot`
 *   tsan-selfcheck          GATE: the synthetic race must be reported exactly
 *                           once, and the suppression canary must both silence
 *                           it and print its Matched block
 *   tsan-shutdown           the LIVE control on HttpServer's own fields, and
 *                           the A/B that measures whether the bridge's atomics
 *                           order it away
 *   tsan-sweep              every kRoutes row plus the connection path,
 *                           under concurrent document mutation, with an RSS
 *                           watchdog and a completion sentinel
 *   tsan-bridge             the main-thread bridge's timeout race
 *   tsan-verdict <scen...>  THE ONLY GATE ON FINDINGS: divergence from
 *                           tools/sanitizer/tsan_expected.txt, in BOTH
 *                           directions
 *   tsan-audit-suppressions expire a suppression that stopped matching
 *   rss-sample <tag>        sample an instance's VmRSS to CSV (the memory
 *                           measurement the lane's budget rests on)
 */
import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.conv;
import std.json;
import std.algorithm;
import std.array;
import std.format;
import core.thread : Thread;
import core.time   : msecs, seconds;

// ---------------------------------------------------------------------------
// The compiler. ABSOLUTE, and version-asserted.
//
// `--compiler=ldc2` resolves through PATH to /usr/bin/ldc2, which on the perf
// runner is LDC 1.40 — and 1.40 CANNOT BUILD VIBE3D AT ALL: it rejects `ref`
// locals in six pre-existing files. A lane that used the short name would die
// on an unrelated compile error in phase 0 and be read as "the ASan build does
// not compile". tools/perf/run.d already hardcodes this same absolute path for
// the same reason.
// ---------------------------------------------------------------------------
enum string kLdcRelPath = ".local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2";
enum int    kLdcMinMajor = 1;
enum int    kLdcMinMinor = 42;

string ldcPath() {
    return buildPath(environment.get("HOME", ""), kLdcRelPath);
}

// The instrumented buildTypes and what each one's binary must be able to prove
// about itself. `hasAsan` is the __asan_init dynamic symbol; `hasCheckAction`
// is the undefined `__assert_fail` that --checkaction=C emits and the default
// -D does not; `hasSelfTest` is the `selftest.fault` string literal, which is
// present iff version=SanitizerSelfTest was declared. All three were measured
// on real binaries, not assumed.
//
// `hasTsan` is __tsan_init AND a .preinit_array section: BOTH, because a tsan
// binary that has the symbol and not the section links, verifies under a
// symbol-only check, and then SIGSEGVs before main (see source/tsan_preinit.d).
//
// The last five fields exist because of a defect measured in the first draft
// of this lane: `cmdBoot` built its argv by hand, so `boot`, the selfcheck and
// the sweep each started the instance a different way — and the tsan instance
// MUST carry --DRT-gcopt=gc:manual (without it TSan deadlocks the process at
// >=2 allocating threads) and MUST carry a TSAN_OPTIONS with history_size=7
// (without it every report arrives with no stack frames). Anything the
// instance needs in order to be the instance the lane measures belongs in the
// SPEC, so the three entry points cannot drift apart.
struct BuildTypeSpec {
    string name;
    bool hasAsan, hasCheckAction, hasSelfTest;
    bool hasTsan;
    string[] runArgs;         // extra argv, BEFORE --test
    string portEnv;           // env var that overrides the port
    string defaultPort;
    string sanOptEnv;         // ASAN_OPTIONS / TSAN_OPTIONS / ""
    string sanOptTemplate;    // %LOG% is replaced with the report-file prefix
}
enum BuildTypeSpec[] kSpecs = [
    BuildTypeSpec("check",         false, true,  true,  false, null,
                  "VIBE3D_SAN_PORT", "8599", "", ""),
    BuildTypeSpec("check-unit",    false, false, true,  false, null,
                  "VIBE3D_SAN_PORT", "8599", "", ""),
    BuildTypeSpec("check-release", false, false, true,  false, null,
                  "VIBE3D_SAN_PORT", "8599", "", ""),
    BuildTypeSpec("sanitize",      true,  true,  true,  false, null,
                  "VIBE3D_SAN_PORT", "8599", "ASAN_OPTIONS",
                  "detect_leaks=0:detect_stack_use_after_return=0:"
                ~ "abort_on_error=1:log_path=%LOG%"),
    // TSAN_OPTIONS, term by term, each one measured rather than copied:
    //   halt_on_error=0     — the lane wants the WHOLE night's findings, not
    //                         the first one.
    //   history_size=7      — WITHOUT IT REPORTS HAVE NO STACKS. Measured: the
    //                         default history_size=2 evicts the stacks and the
    //                         reports arrive as a single top frame with empty
    //                         bodies, which reads like a broken symbolizer.
    //   print_suppressions=1— prints `Matched N suppressions`, which is the
    //                         only expiry mechanism a suppression list has.
    //   exitcode=0          — the exit code is NOT the verdict: TSan returns
    //                         66 whenever it has reported anything, and this
    //                         lane reports on a HEALTHY night by construction.
    //                         `tsan-verdict` decides, and only it.
    //   NO symbolize=0      — measured: it silently disables the suppression
    //                         file entirely (matching is by symbol NAME), so
    //                         the same run goes from 0 warnings + `Matched 6
    //                         suppressions` to 6 warnings and nothing matched.
    // hasCheckAction is FALSE for tsan, and that is not an omission: the
    // buildType cannot carry --checkaction=C because it cannot carry asserts
    // at all. gc:manual is mandatory (TSan deadlocks under the real
    // collector), ManualGC.reserveArrayCapacity() returns 0 unconditionally,
    // and druntime asserts on exactly that value inside _d_arraysetcapacity --
    // so one array.reserve() aborts the process before startup finishes.
    // Measured; see dub.json's comment on the buildType.
    BuildTypeSpec("tsan",          false, false, true,  true,
                  ["--DRT-gcopt=gc:manual"],
                  "VIBE3D_TSAN_PORT", "8630", "TSAN_OPTIONS",
                  "halt_on_error=0:history_size=7:print_suppressions=1:"
                ~ "exitcode=0:log_path=%LOG%"),
    // dub's own built-in `debug`, listed here for ONE reason: it is the A/B
    // baseline for the tsan multiplier, and the comparison is only honest if
    // the baseline runs through the same spawnInstance and the same sweep.
    // Phase 0's numbers compared an LDC tsan build against a DMD build and are
    // therefore not a TSan multiplier at all — they are a compiler
    // difference plus a TSan multiplier. Same compiler, same driver, or the
    // number means nothing. It declares no SanitizerSelfTest, so
    // selftest.fault is absent from it (that is the whole point of the version
    // gate) and only the route sweep is comparable.
    BuildTypeSpec("debug",         false, false, false, false, null,
                  "VIBE3D_TSAN_PORT", "8630", "", ""),
];

BuildTypeSpec specFor(string bt) {
    foreach (s; kSpecs) if (s.name == bt) return s;
    fail("unknown buildType '" ~ bt ~ "' — expected one of: "
         ~ kSpecs.map!(s => s.name).join(", "));
    assert(0);
}

// ---------------------------------------------------------------------------
void fail(string msg) {
    stderr.writeln("lane.d: FAIL: ", msg);
    import core.stdc.stdlib : exit;
    exit(1);
}
void ok(string msg) { writeln("lane.d: ok: ", msg); }

// ---------------------------------------------------------------------------
// Disk-space preflight (task 2080) — mirrors run_test.d's check of the same
// name; kept as a separate small copy here (this file is a standalone rdmd
// script like run_test.d, with no shared module between them, matching how
// every other helper in this file — fail/ok/run/runStdout — is its own copy
// rather than an import). See run_test.d's "Disk-space preflight" comment for
// the incident and why 256 MiB is a flat, run-independent floor rather than
// a threshold derived from anything this lane measures.
// ---------------------------------------------------------------------------
enum ulong kMinPreflightFreeBytes = 256UL * 1024 * 1024;

ulong freeBytes(string path) {
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    string p = path;
    while (p.length && !exists(p)) {
        const parent = dirName(p);
        if (parent == p) break;
        p = parent;
    }
    if (!p.length || !exists(p)) return ulong.max;
    statvfs_t st;
    if (statvfs(p.toStringz, &st) != 0) return ulong.max;
    return cast(ulong) st.f_bavail * cast(ulong) st.f_frsize;
}

string humanBytes(ulong b) {
    enum double Ki = 1024.0, Mi = Ki * 1024, Gi = Mi * 1024;
    if (b == ulong.max)     return "unknown";
    if (b >= cast(ulong)Gi) return format("%.1f GiB", b / Gi);
    if (b >= cast(ulong)Mi) return format("%.1f MiB", b / Mi);
    if (b >= cast(ulong)Ki) return format("%.1f KiB", b / Ki);
    return format("%d B", b);
}

/// `null` => proceed; else the refusal message, always containing "space".
string spacePreflightMessage(ulong free, ulong floor, string path) {
    if (free == ulong.max || free >= floor) return null;
    return format(
        "no space left: %s has %s free, below the %s floor -- refusing to "
        ~ "start rather than fail mid-run and disguise it as red tests "
        ~ "(task 2080)", path, humanBytes(free), humanBytes(floor));
}

/// `check-space <path> [floorMiB]` — the same real, un-mocked surface
/// run_test.d exposes, for a constrained-mount witness to drive against this
/// lane's own binary.
void cmdCheckSpace(string[] args) {
    if (args.length < 1) fail("check-space <path> [floor-mib]");
    const path  = args[0];
    const floor = args.length > 1
        ? cast(ulong) args[1].to!ulong * 1024 * 1024
        : kMinPreflightFreeBytes;
    const free = freeBytes(path);
    if (auto msg = spacePreflightMessage(free, floor, path)) fail(msg);
    ok(format("%s free at %s (floor %s)", humanBytes(free), path, humanBytes(floor)));
}

string run(string[] argv, string[string] env = null, bool mustSucceed = true) {
    auto r = execute(argv, env);
    if (mustSucceed && r.status != 0)
        fail(argv.join(" ") ~ " exited " ~ r.status.to!string ~ "\n" ~ r.output);
    return r.output;
}

// `execute` folds stderr into stdout, and `dub describe` writes progress
// chatter to stderr — which turns the JSON into unparsable text. Read the two
// streams apart, and read ONLY stdout.
string runStdout(string[] argv, string[string] env = null) {
    auto p = pipeProcess(argv, Redirect.stdout | Redirect.stderr, env);
    auto outBuf = appender!string;
    foreach (line; p.stdout.byLine) outBuf.put(line.idup ~ "\n");
    auto errBuf = appender!string;
    foreach (line; p.stderr.byLine) errBuf.put(line.idup ~ "\n");
    const st = wait(p.pid);
    if (st != 0)
        fail(argv.join(" ") ~ " exited " ~ st.to!string ~ "\n" ~ errBuf.data);
    return outBuf.data;
}

// The dub package cache MUST be the lane's own. The shared ~/.dub currently
// holds LDC-built archives for third-party packages that break the dmd test
// path with undefined-druntime-symbol errors; pointing DUB_HOME at the lane's
// scratch keeps the two apart in both directions.
string[string] laneEnv() {
    string[string] e;
    foreach (k, v; environment.toAA) e[k] = v;
    auto home = environment.get("VIBE3D_SAN_DUB_HOME", "");
    if (home.length == 0)
        fail("VIBE3D_SAN_DUB_HOME is unset — instrumented builds must not "
           ~ "write into the shared ~/.dub cache (it holds LDC-built archives "
           ~ "that break the dmd test path). Point it at this lane's scratch.");
    e["DUB_HOME"] = home;
    return e;
}

// ---------------------------------------------------------------------------
// preflight — everything that can be decided before a build exists.
// ---------------------------------------------------------------------------

/// The private fuzzer's location, resolved by SHAPE rather than spelled out.
///
/// `tools/local/` is a gitignored symlink into the private repo and holds one
/// directory per reference suite. Writing the matching directory's name here
/// would put a reference product's name into the PUBLIC tree, which is the one
/// thing the neutrality rule forbids outright — and allowlisting a new site is
/// a way of not obeying the rule, not a way of satisfying it. (`run_all.d`
/// predates the rule and is allowlisted wholesale; that is a debt, not a
/// licence to add more.)
///
/// So the directory is found by globbing for the shape the allowlist itself
/// uses, `*_diff`, and selecting whichever one actually carries the script.
/// The public tree then names only OUR OWN file. Ambiguity is not possible in
/// practice and not silent if it ever becomes so: the first match wins and the
/// resolved path is printed by `preflight`, so the log says which one ran.
enum kSuiteGlob  = "tools/local/*_diff";
enum kFuzzerLeaf = "atlas/fuzz_invariants_vibe.py";

string resolveFuzzer()
{
    if (!exists("tools/local")) return null;
    foreach (e; dirEntries("tools/local", "*_diff", SpanMode.shallow))
    {
        auto cand = buildPath(e.name, kFuzzerLeaf);
        if (exists(cand) && isFile(cand)) return cand;
    }
    return null;
}

void cmdPreflight(string[] args = null) {
    // `--no-fuzzer` is not a loosening, it is a scoping fix. Check (3) below
    // exists because the ASan lane RUNS the private fuzzer and a dead symlink
    // makes that step a silent no-op. The ThreadSanitizer lane does not fuzz
    // at all, so on this lane the same check turns a missing private repo into
    // a red night for a reason unrelated to anything it measures — the exact
    // poisoned-diagnostic shape the rest of this file is written to avoid. The
    // flag has to be passed EXPLICITLY by a caller that has no fuzz step; it
    // is not a default.
    const skipFuzzer = args.canFind("--no-fuzzer");
    // (0) Disk space, tempDir() (task 2080). This is `run_test.d`'s own
    // scratch tree — the incident this guards was a sanitizer night that
    // died mid-link writing INTO it (`worker_N/<test>.o`, ENOSPC), with six
    // unrelated fixture tests failing identically in the same run. Checked
    // first, before any LDC build, so a starved host says so in one line
    // instead of forty minutes into the "full test suite" step below.
    {
        const root = tempDir();
        if (auto msg = spacePreflightMessage(freeBytes(root), kMinPreflightFreeBytes, root))
            fail(msg);
        ok(format("%s free at %s (tempDir, floor %s)",
                  humanBytes(freeBytes(root)), root, humanBytes(kMinPreflightFreeBytes)));
    }
    // (1) The compiler exists and is new enough.
    auto ldc = ldcPath();
    if (!exists(ldc))
        fail("no ldc2 at " ~ ldc ~ " — the lane must not fall back to "
           ~ "PATH's ldc2 (1.40 on this host, and it cannot build vibe3d)");
    auto ver = run([ldc, "--version"]);
    import std.regex : matchFirst, regex;
    auto m = ver.matchFirst(regex(r"LDC.*\((\d+)\.(\d+)\.(\d+)\)"));
    if (m.empty) fail("could not parse an LDC version out of:\n" ~ ver);
    const maj = m[1].to!int, min = m[2].to!int;
    if (maj < kLdcMinMajor || (maj == kLdcMinMajor && min < kLdcMinMinor))
        fail(format("ldc2 at %s is %d.%d — need >= %d.%d (older LDC rejects "
                  ~ "`ref` locals in six pre-existing files and cannot build "
                  ~ "vibe3d at all)", ldc, maj, min, kLdcMinMajor, kLdcMinMinor));
    ok(format("ldc2 %d.%d at %s", maj, min, ldc));

    // (2) The display. This runner is a hardware-GL workstation and the perf
    // lane deliberately uses DISPLAY=:0. Measured on this project: an editor
    // boot costs ~12.5 GiB of RSS on hardware GL against 1.12 GiB under
    // software GL, and an eight-way run once took 44.7 of 62 GiB and was
    // OOM-killed. Under ASan that is unlandable at any parallelism, so every
    // step of this lane runs under `xvfb-run`, and a DISPLAY of :0 here means
    // some step forgot.
    auto disp = environment.get("DISPLAY", "");
    if (disp == ":0")
        fail("DISPLAY=:0 — this lane must run every step under "
           ~ "`env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 xvfb-run -a`. "
           ~ "A hardware-GL boot costs ~12.5 GiB against ~1.12 GiB on "
           ~ "software GL and will OOM under ASan.");
    ok("DISPLAY is not :0 (" ~ (disp.length ? disp : "<unset>") ~ ")");

    // (3) The private fuzzer. tools/local is a gitignored symlink into the
    // private repo and actions/checkout does not create it. A dead link here
    // means the fuzzing step runs nothing and the night reports health —
    // exactly how the perf lane once lost its whole run history.
    if (skipFuzzer) {
        writeln("lane.d: skip: private-fuzzer check (--no-fuzzer) — this "
              ~ "caller has no fuzzing step, so a dead symlink cannot make "
              ~ "one of its steps a silent no-op");
    } else {
        auto fuzzer = resolveFuzzer();
        if (fuzzer is null)
            fail("no " ~ kFuzzerLeaf ~ " under any " ~ kSuiteGlob ~ " — the "
               ~ "tools/local symlink into the private repo is missing or "
               ~ "dead; the fuzzing step would be a silent no-op");
        ok("private fuzzer readable: " ~ fuzzer);
    }

    // (4) RELEASE IS UNTOUCHED — and this is the check that decides whether
    // that claim is proven or merely asserted.
    //
    // `dub describe --build=release` with NO --compiler defaults to dmd and
    // DROPS every dflags-ldc entry, so the naive form of this check passes
    // vacuously: put `--fsanitize=address` into the release config and it
    // still comes back clean. Pass the real compiler and the shipped
    // configuration, and read the STRUCTURED buildSettings rather than
    // grepping the raw text.
    auto env = laneEnv();
    // Disk space, VIBE3D_SAN_DUB_HOME (task 2080) — every `dub build`/`dub
    // test` this lane runs below writes here (laneEnv() above already
    // refused to proceed if it were unset), so it is checked alongside
    // tempDir() rather than left to surface as a build failure later.
    {
        const dubHome = environment.get("VIBE3D_SAN_DUB_HOME", "");
        if (dubHome.length) {
            if (auto msg = spacePreflightMessage(freeBytes(dubHome), kMinPreflightFreeBytes, dubHome))
                fail(msg);
            ok(format("%s free at VIBE3D_SAN_DUB_HOME=%s (floor %s)",
                      humanBytes(freeBytes(dubHome)), dubHome, humanBytes(kMinPreflightFreeBytes)));
        }
    }
    auto desc = runStdout([ "dub", "describe", "--build=release",
                            "--compiler=" ~ ldc, "--config=modeling" ], env);
    auto j = parseJSON(desc);
    bool sawRoot = false;
    foreach (t; j["targets"].array) {
        if (t["rootPackage"].str != "vibe3d") continue;
        sawRoot = true;
        auto bs = t["buildSettings"];
        foreach (f; ("dflags" in bs) ? bs["dflags"].array : JSONValue[].init)
            if (f.str.canFind("fsanitize") || f.str.canFind("checkaction"))
                fail("release carries an instrumentation dflag: " ~ f.str);
        foreach (v; ("versions" in bs) ? bs["versions"].array : JSONValue[].init)
            if (v.str == "SanitizerSelfTest" || v.str == "SanitizerThreadPreinit")
                fail("release declares version " ~ v.str);
    }
    if (!sawRoot)
        fail("dub describe named no vibe3d target — the check inspected "
           ~ "nothing and would have passed on anything");
    ok("release buildSettings carry no --fsanitize / --checkaction / "
     ~ "SanitizerSelfTest / SanitizerThreadPreinit (read structurally, with "
     ~ "--compiler set)");
}

// ---------------------------------------------------------------------------
// preflight-release — the strictly stronger, BEHAVIOURAL half of check (4).
// Builds the real release binary and asserts the injector is not in it.
// Separate because it costs a full release build.
// ---------------------------------------------------------------------------
void cmdPreflightRelease() {
    auto env = laneEnv();
    auto ldc = ldcPath();
    run(["dub", "build", "--build=release", "--compiler=" ~ ldc,
         "--config=modeling"], env);
    if (!exists("./vibe3d")) fail("release build produced no ./vibe3d");
    std.file.rename("./vibe3d", "./vibe3d-release");
    auto s = execute(["strings", "-a", "./vibe3d-release"]);
    if (s.status != 0) fail("strings failed on ./vibe3d-release");
    foreach (line; s.output.lineSplitter)
        if (line.strip == "selftest.fault")
            fail("the RELEASE binary contains the literal `selftest.fault` — "
               ~ "the fault injector reached the shipped build");
    ok("release binary does not contain `selftest.fault`");
}

// ---------------------------------------------------------------------------
// build — and the rename that keeps ./vibe3d clean.
//
// A per-buildType `targetName` in dub.json would have been the automatic way
// to do this. It is INERT: measured on dub 1.41, `dub describe --build=check`
// reports `targetName: vibe3d` with the field set, and the build writes
// ./vibe3d anyway. So the rename is explicit, and it is checked.
// ---------------------------------------------------------------------------
void cmdBuild(string bt) {
    auto spec = specFor(bt);
    // check-unit carries the `unittests` build option (it must, or `dub test
    // --build=check-unit` compiles the test configuration WITHOUT -unittest
    // and dies on version(unittest)-only symbols). Building the EDITOR with it
    // would run module unittests at startup, so that combination is refused
    // rather than left as a foot-gun: it is a `dub test` buildType only.
    if (bt == "check-unit")
        fail("check-unit is a `dub test` buildType (it sets `unittests`) — "
           ~ "run `dub test --config=tests --build=check-unit --compiler=$LDC` "
           ~ "instead of building the editor with it");
    auto env = laneEnv();
    auto ldc = ldcPath();
    if (exists("./vibe3d")) std.file.remove("./vibe3d");
    run(["dub", "build", "--build=" ~ bt, "--compiler=" ~ ldc,
         "--config=modeling"], env);
    if (!exists("./vibe3d"))
        fail("--build=" ~ bt ~ " produced no ./vibe3d");
    const dst = "./vibe3d-" ~ bt;
    if (exists(dst)) std.file.remove(dst);
    std.file.rename("./vibe3d", dst);
    if (exists("./vibe3d"))
        fail("./vibe3d still exists after the rename — the perf nightly's "
           ~ "`frames --no-build` would read an instrumented binary");
    ok("built " ~ dst ~ ", ./vibe3d is absent");
    verifyOne(dst, spec);
}

// ---------------------------------------------------------------------------
// verify — every binary the night EXECUTES, not just ./vibe3d.
//
// The lane runs two different binaries: the staged ./vibe3d (from `check` or
// `sanitize`) and dub's own `vibe3d-test-tests` from the module-unittest gate.
// A preflight that inspects only the first is how a whole night runs the
// unittest lane uninstrumented and calls it healthy — `dub test` DEFAULTS to
// --build=unittest, so that is the failure waiting to happen.
// ---------------------------------------------------------------------------
void verifyOne(string path, BuildTypeSpec spec) {
    if (!exists(path)) fail("no such binary: " ~ path);
    auto nm = execute(["nm", "-C", path]);
    auto dyn = execute(["nm", "-D", "--undefined-only", path]);
    auto strs = execute(["strings", "-a", path]);

    const hasAsan  = nm.output.canFind("__asan_init");
    const hasTsanSym = nm.output.canFind("__tsan_init");
    const hasCA    = dyn.output.canFind("__assert_fail");
    bool hasST = false;
    foreach (line; strs.output.lineSplitter)
        if (line.strip == "selftest.fault") { hasST = true; break; }

    if (hasAsan != spec.hasAsan)
        fail(format("%s: __asan_init %s but buildType %s expects it %s — the "
                  ~ "lane would run an %sinstrumented binary and report health",
                    path, hasAsan ? "present" : "ABSENT", spec.name,
                    spec.hasAsan ? "present" : "absent",
                    spec.hasAsan ? "un" : ""));
    if (hasCA != spec.hasCheckAction)
        fail(format("%s: __assert_fail %s but buildType %s expects it %s "
                  ~ "(--checkaction=C emits it; the default -D does not)",
                    path, hasCA ? "present" : "ABSENT", spec.name,
                    spec.hasCheckAction ? "present" : "absent"));
    if (hasST != spec.hasSelfTest)
        fail(format("%s: `selftest.fault` %s but buildType %s expects it %s "
                  ~ "(version=SanitizerSelfTest)",
                    path, hasST ? "present" : "ABSENT", spec.name,
                    spec.hasSelfTest ? "present" : "absent"));
    if (hasTsanSym != spec.hasTsan)
        fail(format("%s: __tsan_init %s but buildType %s expects it %s — the "
                  ~ "lane would run an %sinstrumented binary and report health",
                    path, hasTsanSym ? "present" : "ABSENT", spec.name,
                    spec.hasTsan ? "present" : "absent",
                    spec.hasTsan ? "un" : ""));

    // The SECOND half of `hasTsan`, and it is not a formality. compiler-rt's
    // tsan_preinit.cpp.o is never pulled out of the archive (its only symbol
    // is local), so a --fsanitize=thread binary links fine, carries
    // __tsan_init, passes a symbol-only check — and SIGSEGVs inside
    // ___interceptor_prctl during _dl_init, before main, because libcap's ELF
    // constructor runs while REAL(prctl) is still null. Read out of a
    // coredump; see source/tsan_preinit.d. Without this line the lane's own
    // `boot` step would be the first thing to notice, after a full 90 s of
    // polling an empty log.
    if (spec.hasTsan) {
        auto sec = execute(["readelf", "-S", path]);
        if (sec.status != 0) fail("readelf -S failed on " ~ path);
        if (!sec.output.canFind("PREINIT_ARRAY"))
            fail(path ~ ": no .preinit_array section — source/tsan_preinit.d "
               ~ "did not reach the link. The binary WILL SIGSEGV before "
               ~ "main() in ___interceptor_prctl, from libcap's ELF "
               ~ "constructor, with an empty log");
    }

    ok(format("%s carries exactly the instrumentation %s promises "
            ~ "(asan=%s tsan=%s checkaction=%s selftest=%s)",
              path, spec.name, hasAsan, hasTsanSym, hasCA, hasST));
}

// ---------------------------------------------------------------------------
// restore-dmd-archives — the trap that DUB_HOME isolation does NOT cover.
//
// MEASURED, and it cost this lane a red run before it was found: `nfde` is a
// PATH dependency, so dub builds its D static library to a fixed path INSIDE
// THE WORKTREE — third_party/nfde/bin/libnfde.a — not into DUB_HOME. Switching
// compilers overwrites it in place. After `lane.d build sanitize`, that archive
// held 168 `__asan_*` symbols.
//
// That matters because run_test.d does NOT link its test binaries with the
// project's compiler: `buildProjectLib` (run_test.d:676) compiles the app
// sources with **dmd** into libvibe3d_test.a, and every SOURCE-BACKED test
// (the ones that import app modules — the LWO / OBJ / glTF / v3d family, i.e.
// exactly the FFI seam ASan exists for) links that archive against the same
// worktree libnfde.a. The result is a link failure reading
// `undefined reference to __asan_memcpy` and
// `undefined reference to _d_array_slice_copy`, reported as
// "worker 0 failed to prepare" — which looks nothing like its cause.
//
// PURE HTTP-driver tests never hit this, so a narrow subset can pass while a
// wider one cannot even link. Do not conclude from a green narrow run that
// this step is unnecessary.
//
// The repair is one ordinary dmd `dub build` (6.4 s measured, incremental),
// which rewrites libnfde.a with dmd objects. It also writes ./vibe3d, which
// `stage` then overwrites — run this BEFORE `stage`, never after.
// perf.yaml carries the mirror image of this step ("Drop cached nfde dep") for
// the same underlying reason.
// ---------------------------------------------------------------------------
void cmdRestoreDmdArchives() {
    // Deliberately NOT laneEnv(): this build must land in the shared cache the
    // dmd test path actually reads.
    run(["dub", "build", "--config=modeling"]);
    // The prefix list is NOT decoration. Until task 1411 this condition read
    // `canFind("__asan")` alone, which is VACUOUS for every sanitizer but one:
    // measured, after an LDC --fsanitize=thread build the same archive carried
    // __tsan_func_entry / __tsan_init / __tsan_read1..16 and the __asan check
    // passed in silence. Whatever the LDC step instrumented, THIS is the step
    // that has to notice it is still there.
    enum string[] kSanPrefixes = ["__asan", "__tsan", "__msan"];
    enum archive = "third_party/nfde/bin/libnfde.a";
    if (exists(archive)) {
        auto nm = execute(["nm", archive]);
        foreach (pfx; kSanPrefixes)
            if (nm.output.canFind(pfx))
                fail(archive ~ " still carries " ~ pfx ~ "_* symbols after a "
                   ~ "dmd build — run_test.d's source-backed tests will fail "
                   ~ "to LINK, and the failure reads as `worker N failed to "
                   ~ "prepare`. PURE HTTP tests stay green, so a narrow run "
                   ~ "cannot tell you this happened.");
        ok(archive ~ " is dmd-built again (no "
           ~ kSanPrefixes.join("_* / ") ~ "_* symbols)");
    }
    if (exists("./vibe3d")) std.file.remove("./vibe3d");
    ok("dmd-linkable archives restored; ./vibe3d removed");
}

// ---------------------------------------------------------------------------
// stage — put the instrumented binary where run_test.d looks for it.
// run_test.d spawns the literal "./vibe3d" (run_test.d:792) and refuses
// --no-build unless a build stamp matching the current sources exists, so the
// stamp is written here rather than left to chance.
// ---------------------------------------------------------------------------
void cmdStage(string bt) {
    const src = "./vibe3d-" ~ bt;
    if (!exists(src)) fail("no " ~ src ~ " — run `lane.d build " ~ bt ~ "` first");
    copy(src, "./vibe3d");
    setAttributes("./vibe3d", getAttributes(src));
    run(["./run_test.d", "--write-stamp"]);
    ok("staged " ~ src ~ " as ./vibe3d and wrote the build stamp");
    verifyOne("./vibe3d", specFor(bt));
}

// ---------------------------------------------------------------------------
// boot — the cheapest catastrophic-failure filter there is.
//
// Registry.cacheSupportedModes() constructs EVERY registered factory at
// startup and throws if a command's name() is not itself a registered key. So
// a typo in the fault injector does not break the injector — it stops the
// editor from starting, and EVERY HTTP test in the night then fails at once,
// which on an instrumented lane reads like a sanitizer catastrophe. Assert a
// clean boot, and the presence of selftest.fault in the live registry, before
// asserting anything else.
// ---------------------------------------------------------------------------
void cmdBoot(string bt) {
    auto spec = specFor(bt);
    // Through spawnInstance, NOT a hand-built argv. The first draft assembled
    // it here and read only VIBE3D_SAN_PORT, so `boot tsan` would have started
    // an instance WITHOUT --DRT-gcopt=gc:manual, on the wrong port, and hung
    // for the full poll — a failure with no relation to the build, which is
    // the exact diagnostic poisoning this function's own header warns about.
    auto ins = spawnInstance(spec, "boot-" ~ bt);
    scope(exit) killInstance(ins);

    // Redundant with spawnInstance's readiness condition (2) by construction,
    // and kept anyway: this is the assertion the step is NAMED for, and a
    // future change to the readiness rule must not silently delete it.
    auto r = httpGet(ins.port, "/api/registry", 20);
    if (!r.connected || !r.body_.canFind("selftest.fault"))
        fail(ins.bin ~ " booted but `selftest.fault` is not registered — the "
           ~ "SanitizerSelfTest version did not reach registration.d, and "
           ~ "every mutation in the table below would silently pass");

    // The instance the lane will MEASURE has to be the instance that just
    // booted, and for tsan the run flags are the difference between a working
    // lane and a deadlocked process. Prove they are on this one rather than
    // assume the spec was honoured.
    if (spec.runArgs.length) {
        auto ps = execute(["ps", "-o", "args=", "-p", ins.editorPid.to!string]);
        foreach (a; spec.runArgs)
            if (!ps.output.canFind(a))
                fail("the booted instance does not carry " ~ a
                   ~ " — its argv is: " ~ ps.output.strip);
        ok("booted argv carries " ~ spec.runArgs.join(" ") ~ " on port " ~ ins.port);
    }
    ok(ins.bin ~ " boots clean and registers selftest.fault");
}

// ---------------------------------------------------------------------------
// teardown — ./vibe3d must not survive this lane.
// ---------------------------------------------------------------------------
void cmdTeardown() {
    if (exists("./vibe3d")) std.file.remove("./vibe3d");
    if (exists("./vibe3d"))
        fail("could not remove ./vibe3d — the 03:30 perf nightly's "
           ~ "`frames --no-build` reads exactly this path");
    ok("./vibe3d removed; no --no-build run can pick up an instrumented binary");
}

// ===========================================================================
// THE ThreadSanitizer LANE (task 1411)
// ===========================================================================
//
// Everything below exists because of one asymmetry that does not apply to the
// ASan lane next door: THIS LANE IS QUIET WHEN IT IS HEALTHY AND QUIET WHEN IT
// IS DEAD. It has to run under --DRT-gcopt=gc:manual — with the ordinary
// conservative GC, TSan deadlocks the editor outright, and short of that it
// emits ~124 reports a minute that are all GC memory REUSE rather than races.
// Under gc:manual the same drive produced zero reports. Zero is also exactly
// what a binary built without --fsanitize=thread produces, what an instance
// that never started produces, and what a sweep killed a few routes in
// produces. So every check here is built around telling those apart.
// ---------------------------------------------------------------------------

import std.socket;
import std.regex : matchFirst, regex, ctRegex;
import core.atomic : atomicOp, atomicLoad, atomicStore;
// `kill` is imported UNDER A NAME: std.process.kill(Pid) and
// core.sys.posix.signal.kill(pid_t,int) otherwise shadow each other, and
// this lane needs both — the Pid for the xvfb-run wrapper, the raw pid for
// the editor found in /proc.
import core.sys.posix.signal : posixKill = kill, SIGINT, SIGKILL, SIGTERM;
import std.datetime : Clock, UTC;

// ---------------------------------------------------------------------------
// The window, COMPUTED from two constants and never stored as a literal.
//
// The first draft stored the interval directly, as [17:00, 18:40), and the
// arithmetic did not close: 18:40 is the worst-case END of a 100-minute run
// that started on time, and it had been written down as the latest allowed
// START. A schedule firing at 18:39 would have run until 20:19 UTC — 79
// minutes inside the sanitizer lane's own window. Computing the interval makes
// raising the timeout narrow the window by itself, which is the entire point.
//
// The runner is SINGLE (one Runner.Listener, agentName fedora-perf) and takes
// one job at a time, so the three lanes cannot overlap — they QUEUE. That is
// why there is no flock here: the scenario a lock would defend against cannot
// occur, and a lock only one of three sides takes protects nothing. The real
// hazard is the queue: a tsan run that overruns DELAYS the sanitizer lane, and
// that lane's own 270 minutes then start later.
//
//   (1) latest allowed start + kTsanTimeoutMin <= kNextLaneStartUtcMin
//       => with 30, the ideal start window closes at 18:30
//   (2) 04:30 + 30 (tsan) = 05:00; the sanitizer lane starts at its own cron
//       19:00 (not at 05:00 — see "cumulative occupancy" below) and runs
//       270 to 23:30 <= 00:30 (perf)
//
// WHY 30 AND NOT 100 (changed 2026-08-19, after the first scheduled run).
// 100 was a hang ceiling picked before this lane's cost was measured. It is
// not the workload: the sweep is bounded by MEMORY, not by time — 4674.6
// MB/min under `gc:manual` against an 8 GiB watchdog, i.e. about a hundred
// SECONDS of continuous sweeping, plus a ~2-minute cold build. Running the
// lane longer means restarting the instance, not widening the window.
//
// The first scheduled run made the cost of the old number concrete. GitHub
// fired the cron at 17:27 — 27 minutes late — and the guard REFUSED, exactly
// as designed, because 17:27 + 100 lands at 19:07, inside the sanitizer
// lane's window. The guard was right and the constant was wrong: a 20-minute
// start window cannot absorb this scheduler's drift, and this repository has
// measured worse (the perf lane once fired 93 minutes late). 30 gives a
// 90-minute window, which covers the observed drift with room, without
// trading away the hang ceiling that a much larger cron shift would cost.
enum int kTsanTimeoutMin       = 30;
// 04:30 UTC = 07:30 MSK. MOVED FROM 17:00 on 2026-08-30 by the owner; the
// cron in `.github/workflows/tsan.yaml` moved with it, and check (2) of
// `cmdPreflightTsan` fails if the two ever disagree again.
//
// THIS EDGE IS THE ONLY ONE OF THE THREE THAT MOVED, and the reason is what
// each edge is derived from:
//
//   * `tsanLatestStartUtcMin` = kNextLaneStartUtcMin - kTsanTimeoutMin = 18:30
//     — the SANITIZER lane's cron and our own timeout. No term of ours.
//   * `tsanHardLatestStartUtcMin` = kPerfStartUtcMin + 24h
//     - kSanitizerDurationMin - kTsanTimeoutMin = 19:30 — the PERF lane's
//     start against the sanitizer lane's budget. No term of ours.
//   * this one had no derivation at all: it WAS the cron target, written a
//     second time. So the interval does not translate as a block — its right
//     edges are pinned by other lanes' budgets and stayed exactly where they
//     were, and only the left edge follows the target.
//
// New nominal slot: [04:30, 19:30) — ideal [04:30, 18:30), drift tolerance
// [18:30, 19:30). Measured by sweeping all 1440 minutes through
// `cmdWindowGuard`, the ACCEPTED SET DID NOT CHANGE BY ONE MINUTE (the guard
// never read the cron): it is {00:00} u [04:30, 19:30) u [23:30, 24:00) = 931
// before and after. What changed is where the drift lands inside it — see the
// contiguity argument under `kTsanAcceptSafeOffSlotStarts` — and the LABEL on
// [04:30, 17:00), which was `passOffSlot` with a loud note and is now a quiet
// `pass`.
//
// It stays a LITERAL and is deliberately NOT written `= kPerfEndUtcMin`, even
// though it now lands exactly on perf's worst-case finish (measured: 04:29 is
// the last refused minute, on `collidesWithPerf` alone). Deriving it would let
// a change to the perf lane's timeout silently move the hour the owner's
// workstation is borrowed, which is a product decision this file has no
// standing to make. The coincidence is ASSERTED instead, by check (2c) of
// `cmdPreflightTsan`: the declared cron target must itself be accepted by
// `checkScheduleWindow`. Under the 17:00 target that was implied by the
// membership test; at 04:30 the open ABUTS perf's occupancy with zero margin,
// so it has to be checked outright.
enum int kTsanWindowOpenUtcMin = 4 * 60 + 30;    // 04:30 UTC
enum int kNextLaneStartUtcMin  = 19 * 60;        // sanitizer.yaml cron '0 19 * * *'
enum int kNextLaneEndUtcMin    = 19 * 60 + 270;  // + timeout-minutes: 270 = 23:30
enum int kPerfStartUtcMin      =  0 * 60 + 30;   // perf.yaml cron '30 0 * * *'
enum int kPerfEndUtcMin        =  4 * 60 + 30;   // + timeout-minutes: 240
enum int kSanitizerDurationMin = kNextLaneEndUtcMin - kNextLaneStartUtcMin;  // 270

// The MEASURED maximum GitHub schedule-delivery drift for this repository:
// 693.6 min = 11.56 h, rounded UP to the whole minute. Live run of
// `tools/ci/nightly_freshness.d`, 2026-08-30 (median 98.8 min). This is the
// number the 2026-08-30 cron move was argued against and the floor check (2d)
// of `cmdPreflightTsan` holds the schedule to; it is a MEASUREMENT, so raise
// it only from a newer run of that tool, never to make a check pass.
enum int kMeasuredMaxDriftMin  = 694;

int tsanLatestStartUtcMin() { return kNextLaneStartUtcMin - kTsanTimeoutMin; }

// A SECOND, LATER ceiling — the actual hazard, not the proxy for it (found
// 2026-08-26). `tsanLatestStartUtcMin` protects the sanitizer lane's own
// NOMINAL cron time (19:00): a run that releases the runner after that could
// delay a sanitizer job that was already waiting for it. But nothing this
// lane does is threatened by a LATE sanitizer start on its own — the thing
// that actually must not happen is the sanitizer lane's worst-case FINISH
// landing inside the perf lane's window. `kNextLaneEndUtcMin` (23:30) already
// carries 60 spare minutes against `kPerfStartUtcMin` (00:30) that
// `tsanLatestStartUtcMin` never spends, because it is computed against the
// sanitizer lane's start, not its finish.
//
// This run measured the gap between the two ceilings directly: the
// `nightly-tsan` cron (`0 17 * * *`) is fired by GitHub's OWN scheduler, not
// by this repository, and its delivery has now been measured late on two
// separate nights — 27 minutes on 2026-08-19 (refused THEN, but by the
// ceiling as it stood under the pre-2026-08-19 `kTsanTimeoutMin=100`; see
// the "WHY 30 AND NOT 100" comment above, a separate and already-fixed
// problem) and 122 minutes on 2026-08-26 (`run 33002973869`, created at
// 19:02:02Z per `gh run view`, cron target 17:00 — refused by TODAY's single
// ceiling of 18:30, `kTsanTimeoutMin=30`). The second is a false alarm: even
// starting this lane at 19:02 and running its full `kTsanTimeoutMin`, the
// sanitizer lane cannot be pushed past a finish of 19:32 + 270 = 00:02,
// which is still 28 minutes before perf opens. The window is split in two
// so that distinction has somewhere to live: PASS quietly inside the ideal
// window, PASS LOUDLY on drift tolerance between the two ceilings, FAIL only
// past the hard one.
//
// What this canNOT see: whether the SANITIZER lane's own cron also drifted
// tonight (its schedule is exactly as exposed to GitHub's load-time delay as
// this one's). This guard only bounds what THIS lane adds to the queue; nothing
// computed here, or anywhere else in this file, controls GitHub's delivery
// time for a different workflow's cron.
int tsanHardLatestStartUtcMin() {
    return kPerfStartUtcMin + 24 * 60 - kSanitizerDurationMin - kTsanTimeoutMin;
}

string hhmm(int m) { return format("%02d:%02d", m / 60, m % 60); }

// ---------------------------------------------------------------------------
// OFF-SLOT STARTS (2026-08-30). The lower bound was a PREFERENCE enforced as
// a hazard, and it is what has kept this lane silent since 2026-08-25.
//
// MEASURED, not argued. `tools/ci/nightly_freshness.d`, live run 2026-08-30
// against this repository's own history: schedule delivery drift is
// `median 98.8min (1.6h), max 693.6min (11.6h)`. Set that against the two
// moves that look obvious and are both wrong:
//
//   * MOVE THE CRON EARLIER — fixes the MEDIAN and nothing else. 11.6h of
//     drift lands 17:00 at 04:36 whatever the cron says; a translation of a
//     2.5h window cannot cover an 11.6h tail.
//   * WIDEN THE WINDOW — unavailable. `tsanHardLatestStartUtcMin` is not a
//     taste; it is 00:30 + 24h - 270 - 30 = 19:30, pinned by the sanitizer
//     lane's own budget against the perf lane's start, on a runner that takes
//     ONE job at a time. Widening it is exactly the collision the ceiling was
//     computed to prevent.
//
// The third form, and the one taken here: stop asking whether `now` is a
// MEMBER of a wall-clock interval and ask whether the run's own occupancy
// COLLIDES. The hazard this file's own comments state — "the sanitizer lane's
// worst-case FINISH landing inside the perf lane's window" — says nothing
// whatever about a start at 05:00: such a run holds the runner for 30 minutes
// and releases it thirteen and a half hours before the sanitizer lane's
// nominal start, and the induced chain is max(19:00, 05:30) + 270 = 23:30,
// an hour clear of perf. The guard refused it anyway, for being early.
//
// So the nominal slot keeps its exact meaning and its exact verdicts, and
// OUTSIDE it the decision moves to `occupancyHazard` below. Against the
// measured maximum: 17:00 + 693.6min = 04:36, whose run window [04:36, 05:06)
// clears perf's occupancy [00:30, 04:30) by six minutes and collides with
// nothing — under the old rule it was refused for being "before 17:00", under
// this one it RUNS. (04:29 still fails: perf may still be measuring.)
//
// That paragraph was written while the slot was [17:00, 19:30). Later the
// same day the cron target moved to 04:30 and the slot's left edge moved with
// it, so 04:36 is now INSIDE the slot and reaches this branch no longer — the
// argument stands as the reason the off-slot branch exists, not as a live
// worked example. See `kTsanWindowOpenUtcMin` for which edges moved and why.
//
// THE COST, AND IT IS THE OWNER'S TO ACCEPT OR REFUSE. This runner is a
// workstation inside the owner's graphical session. An off-slot acceptance
// means a 30-minute instrumented lane can now start at, say, 11:00 local
// working hours. Under `xvfb-run` that is ~1.12 GiB of RSS and no display
// contention (see the workflow's DISPLAY comment), so the cost is CPU during
// the owner's day — real, bounded, and traded against a lane that currently
// measures nothing at all. `kTsanAcceptSafeOffSlotStarts` is the one-line
// reversal, and it is a PARAMETER of `checkScheduleWindow`, not a global read
// inside it, so `cmdPreflightTsan`'s selfcheck exercises BOTH values and the
// refusing branch cannot rot into dead code.
//
// THE CRON TARGET — NAMED HERE ON 2026-08-30 AND TAKEN THE SAME DAY.
// Sweeping all 1440 minutes through `cmdWindowGuard` gives the accepted set
// {00:00} u [04:30, 19:30) u [23:30, 24:00) = 931 minutes, against the 150
// the membership test allowed. But that set was NOT CONTIGUOUS FROM 17:00:
// from a 17:00 cron the tolerated drift was [0, 2.5h) u [6.5h, 7h] u
// [11.5h, ...) — the measured median (1.6h) and the measured maximum (11.6h
// -> 04:33) both landed in it, but a nine-hour hole sat between them, and a
// delivery at, say, 21:00 was still refused because it genuinely collides.
// The lever that closes the hole is the cron target, not this file. From a
// 04:30 target the SAME accepted set reads as [0, 15h) contiguous, then a
// hole [15h, 19h), then [19h, 19.5h] — measured, not predicted: the sweep
// puts the last accepted minute of the contiguous run at 19:29, i.e. 900
// minutes = FIFTEEN HOURS from 04:30, covering the measured maximum drift
// (693.6min = 11.56h) with 206 minutes = 3.4h to spare.
//
// So the cron moved to `30 4 * * *` and `kTsanWindowOpenUtcMin` moved with
// it. WHAT THAT DID TO THIS FLAG, because its argument above is now stale in
// its central claim: with the open at 17:00 this switch governed 781 minutes,
// including the whole of [04:30, 17:00) — every working hour of the owner's
// day, which is what the cost paragraph is about. With the open at 04:30
// those minutes are INSIDE the nominal slot and are accepted whatever this
// flag says. Measured after the move, the flag governs 31 minutes and they
// are all nocturnal: {00:00} u [23:30, 24:00), the gap between the sanitizer
// lane's finish and the perf lane's start. Reaching them needs a delivery
// 19h to 19.5h late, against a measured maximum of 11.6h.
//
// It is therefore LEFT AT `true` and reported rather than decided: after the
// move it neither protects working hours (it no longer reaches them) nor
// plausibly fires (no recorded delivery is that late), so flipping it would
// be a change with no measured consequence, and that is not this file's call
// to make. The selfcheck in `cmdPreflightTsan` (2c) exercises the `false`
// branch at 23:30 — the cell it used to be exercised at, 04:36, is inside
// the slot now and cannot reach this switch at all.
enum bool kTsanAcceptSafeOffSlotStarts = true;

/// Smallest `x >= from` with `x ≡ tod (mod 24h)`. Minute-of-day arithmetic
/// with no wall-clock date: a lane's window is a daily recurrence, and every
/// comparison here has to be able to cross midnight.
int nextAtOrAfter(int tod, int from) pure {
    enum day = 24 * 60;
    int x = tod;
    while (x >= from + day) x -= day;
    while (x < from) x += day;
    return x;
}

/// Does `[aLo, aHi)` overlap ANY daily occurrence of `[bTod, bTod + bDur)`?
/// Four shifts, not one: `aLo` is a minute-of-day but `aHi` may be tomorrow,
/// and `bDur` (270 for the sanitizer lane) can itself run past midnight.
bool overlapsDaily(int aLo, int aHi, int bTod, int bDur) pure {
    enum day = 24 * 60;
    foreach (shift; [-day, 0, day, 2 * day]) {
        const bLo = bTod + shift, bHi = bLo + bDur;
        if (aLo < bHi && bLo < aHi) return true;
    }
    return false;
}

/// The three ways a tsan run beginning at `now` can hurt another lane on this
/// single, serialising runner. Three separate flags and not one boolean, so a
/// mutation of any one of them cannot be absorbed by another still firing —
/// `cmdPreflightTsan` pins a case in which each is the ONLY term that fires.
struct OccupancyHazard {
    bool collidesWithSanitizer;   // we would be queued behind / ahead of it at an unknown offset
    bool collidesWithPerf;        // we would contend with the measurement itself
    bool pushesSanitizerIntoPerf; // the induced chain finishes inside perf's window
    bool any() const pure {
        return collidesWithSanitizer || collidesWithPerf || pushesSanitizerIntoPerf;
    }
}

/// Pure, and every constant is an argument — no globals, no clock. The chain
/// modelled is the one the runner actually executes: this lane occupies
/// `[now, now + timeoutMin)`; the sanitizer lane then starts at
/// `max(its own unfinished occurrence, our release)` and runs its full
/// budget; that finish must land strictly before the next perf start.
///
/// `pushesSanitizerIntoPerf` uses `>=`, not `>`, deliberately: a chain
/// finishing at exactly 00:30 is the state the pre-existing hard ceiling
/// already refused (`now >= hardLatest`), and this function has to reproduce
/// that boundary rather than quietly move it by a minute.
OccupancyHazard occupancyHazard(int now, int timeoutMin, int nextLaneStart,
                                 int nextLaneEnd, int perfStart, int perfEnd) pure {
    const sanDur  = nextLaneEnd - nextLaneStart;
    const perfDur = perfEnd - perfStart;
    const tsanEnd = now + timeoutMin;

    OccupancyHazard h;
    h.collidesWithSanitizer = overlapsDaily(now, tsanEnd, nextLaneStart, sanDur);
    h.collidesWithPerf      = overlapsDaily(now, tsanEnd, perfStart, perfDur);

    // The sanitizer occurrence that has not FINISHED yet — the one this run
    // can still delay. `now - sanDur + 1` is what picks tonight's 19:00 while
    // it is still running and tomorrow's once it has finished.
    const sanStart  = nextAtOrAfter(nextLaneStart, now - sanDur + 1);
    const sanEff    = sanStart > tsanEnd ? sanStart : tsanEnd;
    const sanFinish = sanEff + sanDur;
    h.pushesSanitizerIntoPerf = sanFinish >= nextAtOrAfter(perfStart, sanEff);
    return h;
}

/// Current UTC minute-of-day, with a NAMED test hook. The hook exists because
/// the window guard's own mutation (run it at 19:35 and require a failure —
/// [18:30, 19:30) is the drift-tolerance zone and must PASS, not fail; see
/// `tsanHardLatestStartUtcMin`) cannot otherwise be executed at all outside a
/// narrow slot once a day, and an unexecutable mutation is not a mutation.
/// `cmdPreflightTsan`'s `(2b)` block below runs the same verdict function
/// against fixed inputs instead of the wall clock, so it is not limited to
/// that slot.
int nowUtcMin() {
    auto ovr = environment.get("VIBE3D_TSAN_NOW_UTC", "");
    if (ovr.length) {
        auto m = ovr.matchFirst(regex(r"^(\d{1,2}):(\d{2})$"));
        if (m.empty) fail("VIBE3D_TSAN_NOW_UTC must be HH:MM, got: " ~ ovr);
        writeln("lane.d: NOTE: VIBE3D_TSAN_NOW_UTC=", ovr,
                " — the clock is overridden (test hook)");
        return m[1].to!int * 60 + m[2].to!int;
    }
    auto n = Clock.currTime(UTC());
    return n.hour * 60 + n.minute;
}

// Verdict for a SCHEDULE-triggered guard check. Three outcomes, not two,
// because the incident that motivated this split (2026-08-26, see
// `tsanHardLatestStartUtcMin`) showed the old binary pass/fail collapsed two
// different situations into one message: a start that is genuinely unsafe
// (past the hard ceiling — would risk the sanitizer lane finishing inside
// perf's window) and a start that is merely later than ideal but still safe
// by the actual arithmetic (GitHub's own cron delivery drifted, not a real
// collision risk). Both used to say "outside the window" and both used to
// fail the job.
//
// FOUR outcomes since 2026-08-30 (see `kTsanAcceptSafeOffSlotStarts`): a
// start that has drifted clean OUT of the nominal slot and yet collides with
// nothing is a fourth state again, and collapsing it into `fail` is what kept
// this lane silent for five nights.
enum ScheduleVerdict { pass, passLate, passOffSlot, fail }

struct ScheduleCheck {
    ScheduleVerdict verdict;
    string message;  // ok text for the three passes, or the fail reason
    string note;      // set for passLate / passOffSlot — the loud NOTE
}

/// Pure: no clock read, no I/O, no process exit — so it can be driven with
/// synthetic `now` values by a self-check that runs any time of day, not
/// just inside whatever slot happens to be live right now. `cmdWindowGuard`
/// below is the one caller that feeds it `nowUtcMin()`.
ScheduleCheck checkScheduleWindow(int now, int openMin, int idealLatest,
                                   int hardLatest, int timeoutMin,
                                   int nextLaneStart, int nextLaneEnd,
                                   int perfStart, int perfEnd,
                                   bool acceptSafeOffSlot = kTsanAcceptSafeOffSlotStarts) {
    // OUTSIDE the nominal slot the decision is the HAZARD, not the interval
    // (2026-08-30). Inside it, every verdict below is bit-for-bit what it was
    // before that change — the slot's own arithmetic already reasons about
    // the queue, and rerouting it through `occupancyHazard` would refuse the
    // drift-tolerance zone (a start at 18:39 does overlap the sanitizer lane's
    // window, which is precisely the delay the passLate branch has always
    // accepted as safe).
    if (now < openMin || now >= hardLatest) {
        const h = occupancyHazard(now, timeoutMin, nextLaneStart, nextLaneEnd,
                                   perfStart, perfEnd);
        if (h.any) {
            string[] why;
            if (h.collidesWithSanitizer)
                why ~= format("its run window [%s, %s) overlaps the sanitizer "
                            ~ "lane's occupancy [%s, %s), so the two would "
                            ~ "queue at an offset nothing here can compute",
                              hhmm(now), hhmm((now + timeoutMin) % (24 * 60)),
                              hhmm(nextLaneStart), hhmm(nextLaneEnd % (24 * 60)));
            if (h.collidesWithPerf)
                why ~= format("its run window [%s, %s) overlaps the perf "
                            ~ "lane's occupancy [%s, %s), and a perf number "
                            ~ "measured beside this lane is contention noise",
                              hhmm(now), hhmm((now + timeoutMin) % (24 * 60)),
                              hhmm(perfStart), hhmm(perfEnd));
            if (h.pushesSanitizerIntoPerf)
                why ~= format("the induced chain (this lane releases the "
                            ~ "runner at %s, the sanitizer lane then runs its "
                            ~ "full %d minutes) finishes at or after the perf "
                            ~ "lane's start %s",
                              hhmm((now + timeoutMin) % (24 * 60)),
                              nextLaneEnd - nextLaneStart, hhmm(perfStart));
            return ScheduleCheck(ScheduleVerdict.fail, format(
                "scheduled start at %s UTC is outside the nominal slot [%s, %s) "
              ~ "AND collides: %s. This is the real hazard, not the slot — see "
              ~ "`occupancyHazard`. The ceiling is COMPUTED from "
              ~ "kTsanTimeoutMin=%d, the sanitizer lane's own %d-minute budget "
              ~ "and the perf lane's start %s; raise either and it narrows by "
              ~ "itself.",
                hhmm(now), hhmm(openMin), hhmm(hardLatest), why.join("; "),
                timeoutMin, nextLaneEnd - nextLaneStart, hhmm(perfStart)));
        }
        if (!acceptSafeOffSlot)
            return ScheduleCheck(ScheduleVerdict.fail, format(
                "scheduled start at %s UTC is outside the nominal slot [%s, %s). "
              ~ "It collides with NOTHING — run window [%s, %s), sanitizer "
              ~ "[%s, %s), perf [%s, %s) — but off-slot starts are refused by "
              ~ "policy (kTsanAcceptSafeOffSlotStarts = false). That policy "
              ~ "was written on 2026-08-30 to keep this lane out of the "
              ~ "owner's working day, when the nominal slot opened at 17:00 "
              ~ "and off-slot meant the whole of [04:30, 17:00). Since the "
              ~ "cron target moved to 04:30 the working day is INSIDE the "
              ~ "slot and this branch no longer reaches it: measured, the "
              ~ "region it now governs is {00:00} u [23:30, 24:00), 31 "
              ~ "nocturnal minutes needing a delivery 19h+ late against a "
              ~ "measured maximum of 11.6h.",
                hhmm(now), hhmm(openMin), hhmm(hardLatest),
                hhmm(now), hhmm((now + timeoutMin) % (24 * 60)),
                hhmm(nextLaneStart), hhmm(nextLaneEnd % (24 * 60)),
                hhmm(perfStart), hhmm(perfEnd)));
        return ScheduleCheck(ScheduleVerdict.passOffSlot, format(
            "scheduled start %s UTC accepted OFF-SLOT — run window [%s, %s) "
          ~ "collides with neither the sanitizer lane [%s, %s) nor perf "
          ~ "[%s, %s), and the induced chain clears perf's start %s",
            hhmm(now), hhmm(now), hhmm((now + timeoutMin) % (24 * 60)),
            hhmm(nextLaneStart), hhmm(nextLaneEnd % (24 * 60)),
            hhmm(perfStart), hhmm(perfEnd), hhmm(perfStart)),
            format(
            "scheduled start %s UTC is OUTSIDE the nominal slot [%s, %s) — "
          ~ "GitHub's own cron delivery has drifted that far (measured "
          ~ "2026-08-30: median 98.8min, MAX 693.6min = 11.6h against the "
          ~ "target). Accepted because the hazard this guard exists for is "
          ~ "runner OCCUPANCY, not membership of a wall-clock interval, and "
          ~ "this run collides with nothing. Refusing it is what kept this "
          ~ "lane silent from 2026-08-25: a refused window is a red job that "
          ~ "measured NOTHING, which is worse than a red finding. Note this "
          ~ "runner is the owner's workstation — set "
          ~ "kTsanAcceptSafeOffSlotStarts = false to go back to refusing.",
            hhmm(now), hhmm(openMin), hhmm(hardLatest)));
    }

    if (now < idealLatest)
        return ScheduleCheck(ScheduleVerdict.pass, format(
            "scheduled start %s UTC is inside the IDEAL window [%s, %s); "
          ~ "worst end %s, next lane starts on time %s",
            hhmm(now), hhmm(openMin), hhmm(idealLatest),
            hhmm(now + timeoutMin), hhmm(nextLaneStart)));

    return ScheduleCheck(ScheduleVerdict.passLate, format(
        "scheduled start %s UTC accepted on DRIFT TOLERANCE — inside the "
      ~ "hard ceiling [%s, %s); worst end %s",
        hhmm(now), hhmm(openMin), hhmm(hardLatest), hhmm(now + timeoutMin)),
        format(
        "scheduled start %s UTC is %d minute(s) past the IDEAL window's "
      ~ "close %s. Tolerated, not ideal: still inside the HARD ceiling %s, "
      ~ "computed from the sanitizer lane's own %d-minute budget against "
      ~ "the perf lane's start %s — even a full-length run from here "
      ~ "cannot push the sanitizer lane's worst-case finish past perf's "
      ~ "start. This guard cannot see whether the sanitizer lane's OWN "
      ~ "cron drifted too; it only bounds THIS lane's contribution.",
        hhmm(now), now - idealLatest, hhmm(idealLatest), hhmm(hardLatest),
        nextLaneEnd - nextLaneStart, hhmm(perfStart)));
}

void cmdWindowGuard(string[] args) {
    const ev    = args.length > 0 ? args[0] : "schedule";
    const force = args.length > 1 && args[1] == "force";
    const now   = nowUtcMin();
    const latest = tsanLatestStartUtcMin();
    const hardLatest = tsanHardLatestStartUtcMin();

    if (latest <= kTsanWindowOpenUtcMin)
        fail(format("the window has closed on itself: kTsanTimeoutMin=%d puts "
                  ~ "the latest allowed start at %s, which is not after the "
                  ~ "window open %s. Either shorten the run or move the "
                  ~ "window open earlier.",
                    kTsanTimeoutMin, hhmm(latest), hhmm(kTsanWindowOpenUtcMin)));
    if (hardLatest <= latest)
        fail(format("the drift-tolerance zone is empty or inverted: ideal "
                  ~ "latest start %s, hard ceiling %s. "
                  ~ "tsanHardLatestStartUtcMin must stay strictly after "
                  ~ "tsanLatestStartUtcMin, or a late schedule event has "
                  ~ "nowhere safe to land.", hhmm(latest), hhmm(hardLatest)));

    if (ev == "schedule") {
        auto chk = checkScheduleWindow(now, kTsanWindowOpenUtcMin, latest,
            hardLatest, kTsanTimeoutMin, kNextLaneStartUtcMin,
            kNextLaneEndUtcMin, kPerfStartUtcMin, kPerfEndUtcMin);
        final switch (chk.verdict) {
            case ScheduleVerdict.fail:
                fail(chk.message);
                break;
            case ScheduleVerdict.pass:
                ok(chk.message);
                break;
            case ScheduleVerdict.passLate:
            case ScheduleVerdict.passOffSlot:
                writeln("lane.d: NOTE: ", chk.note);
                ok(chk.message);
                break;
        }
        return;
    }

    // Manual dispatch. The danger here is the opposite of a collision: this
    // runner serialises, so a manual run started at 00:20 does not clash with
    // the perf nightly — it makes the perf nightly start an hour and a half
    // late, in a different thermal and desktop-activity regime, which poisons
    // exactly the day-over-day comparison the perf lane exists for.
    // The test that matters is OVERLAP of [now, now + timeout) with an
    // occupied window, not membership of `now` in one. Found by this
    // function's own mutation: at 00:20 a membership test says "not inside
    // perf's [00:30, 04:30)" and lets the job start — and the job then holds
    // the runner until 02:00 and delays perf by an hour and a half, which is
    // the exact hazard this guard was written for. Times are minute-of-day, so
    // a run that crosses midnight is unwrapped before comparing.
    const lo = now, hi = now + kTsanTimeoutMin;
    bool overlaps(int wLo, int wHi) {
        foreach (shift; [0, 24 * 60])   // the perf window is "tomorrow" for an evening start
            if (lo < wHi + shift && wLo + shift < hi) return true;
        return false;
    }
    const inSan  = overlaps(kNextLaneStartUtcMin, kNextLaneEndUtcMin);
    const inPerf = overlaps(kPerfStartUtcMin, kPerfEndUtcMin);
    if ((inSan || inPerf) && !force)
        fail(format("manual dispatch at %s UTC would occupy the runner until "
                  ~ "%s, overlapping %s%s%s. This runner takes ONE job at a "
                  ~ "time, so the effect is not a clash but a DELAY of the "
                  ~ "other lane by up to %d minutes, which moves it into a "
                  ~ "different thermal and desktop-activity regime. Pass the "
                  ~ "`force` input if that is what you mean.",
                    hhmm(lo), hhmm(hi % (24 * 60)),
                    inSan  ? format("sanitizer [%s, %s)",
                                    hhmm(kNextLaneStartUtcMin),
                                    hhmm(kNextLaneEndUtcMin % (24 * 60))) : "",
                    (inSan && inPerf) ? " and " : "",
                    inPerf ? format("perf [%s, %s)", hhmm(kPerfStartUtcMin),
                                    hhmm(kPerfEndUtcMin)) : "",
                    kTsanTimeoutMin));
    ok(format("manual dispatch at %s UTC accepted%s",
              hhmm(now), force ? " (force)" : ""));
}

// ---------------------------------------------------------------------------
// spawnInstance — the ONE place an instance is started.
//
// `boot`, `tsan-selfcheck`, `tsan-shutdown`, `tsan-sweep` and `tsan-bridge`
// all come through here, and that is the content of the change rather than its
// tidiness: the tsan instance must carry --DRT-gcopt=gc:manual and a
// TSAN_OPTIONS with history_size=7, and in the first draft both of those lived
// in the workflow while `cmdBoot` assembled its own argv. `boot` would have
// hung for its full 90 s and blamed the build.
// ---------------------------------------------------------------------------
struct Instance {
    Pid    pid;          // the `env`/xvfb-run wrapper
    int    editorPid;    // the actual editor, found in /proc
    string port;
    string logPath;
    string reportPrefix;
    string bin;
}

/// The editor runs under `xvfb-run`, so the Pid we hold is a shell, not the
/// process whose VmRSS the watchdog must read and whose exit the shutdown
/// controls need. Find it by scanning /proc for our own binary name AND our
/// own port — deliberately NOT by a `pkill -f`-shaped pattern, which on this
/// host has twice matched the harness's own command line.
int findEditorPid(string bin, string port) {
    const want = baseName(bin);
    foreach (e; dirEntries("/proc", SpanMode.shallow)) {
        const b = baseName(e.name);
        if (!b.length || !b.all!(c => c >= '0' && c <= '9')) continue;
        string cl;
        try { cl = cast(string) std.file.read(buildPath(e.name, "cmdline")); }
        catch (Exception) { continue; }
        if (!cl.length) continue;
        auto parts = cl.split("\0").filter!(a => a.length).array;
        if (parts.length < 2) continue;
        if (baseName(parts[0]) != want) continue;
        if (!parts.canFind(port)) continue;
        return b.to!int;
    }
    return 0;
}

/// How an instance is proven ready.
///   command    — a POST to /api/command that comes back anything but 503.
///   bridgeFree — /api/camera answering 200, which is an httpThread route and
///                therefore involves NO main-thread bridge traffic at all.
///
/// The second mode exists because the shutdown A/B needs an arm with ZERO
/// bridge round trips, and the `command` probe is itself one — so proving the
/// editor is up the ordinary way would destroy the very thing arm A measures.
///
/// TASK 1740 — BOTH MODES NOW READ A STATUS CODE. They used to read BODIES:
/// mode `command` matched the string `command handler not set`, and a second
/// string `timeout waiting for main thread` for the case where the wiring was
/// done but no frame had drained the bridges. That was three readiness
/// predicates in this file and a fourth in run_test.d, and it is exactly the
/// divergence the card warned about — this lane and the runner could disagree
/// about whether the same instance was ready. `http_server.d` now answers 503
/// on EVERY `/api/*` route until both halves hold (providers wired AND the
/// main loop has drained the bridges once), so 503 is the single "not yet"
/// and there is nothing left to match on. Note that `/api/registry` is gated
/// too — it is served from a static table and used to answer throughout the
/// whole startup window, which is what made "the registry answers" a false
/// readiness signal in the first place (the nightly it broke: task 1410).
enum ReadyMode { command, bridgeFree }

Instance spawnInstance(BuildTypeSpec spec, string tag,
                       string[] extraArgs = null, string suppressions = null,
                       ReadyMode ready = ReadyMode.command) {
    Instance ins;
    ins.bin = "./vibe3d-" ~ spec.name;
    if (!exists(ins.bin)) fail("no " ~ ins.bin ~ " — run `lane.d build " ~ spec.name ~ "` first");
    ins.port = environment.get(spec.portEnv, spec.defaultPort);
    ins.logPath = "tsan-instance-" ~ tag ~ ".log";
    ins.reportPrefix = buildPath(getcwd(), "tsan-report-" ~ tag);

    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;

    if (spec.sanOptEnv.length) {
        // (a) of the two-place symbolize=0 ban. The check has to live where
        // the string is BUILT: a check on lane.d's own environment inspects
        // lane.d's environment, not the instance's, and the instance is the
        // process whose suppression matching goes silently dead.
        auto inherited = environment.get(spec.sanOptEnv, "");
        if (inherited.canFind("symbolize=0"))
            fail(spec.sanOptEnv ~ " was inherited carrying symbolize=0: "
               ~ inherited ~ "\nMeasured: symbolize=0 does not merely drop "
               ~ "names, it SILENTLY DISABLES the suppression file (matching "
               ~ "is by symbol NAME). The same run goes from 0 warnings + "
               ~ "`Matched 6 suppressions` to 6 warnings with nothing "
               ~ "matched. This lane builds its own options and refuses to "
               ~ "inherit that one.");
        auto opts = spec.sanOptTemplate.replace("%LOG%", ins.reportPrefix);
        if (suppressions.length) {
            if (!exists(suppressions)) fail("no suppression file " ~ suppressions);
            opts ~= ":suppressions=" ~ buildPath(getcwd(), suppressions);
        }
        if (opts.canFind("symbolize=0"))
            fail("the lane's own " ~ spec.sanOptEnv ~ " contains symbolize=0");
        env[spec.sanOptEnv] = opts;
        writeln("lane.d: ", spec.sanOptEnv, "=", opts);
    }

    auto argv = ["env", "-u", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER=x11",
                 "xvfb-run", "-a", ins.bin]
              ~ spec.runArgs.dup
              ~ ["--test", "--http-port", ins.port]
              ~ extraArgs;
    writeln("lane.d: spawn: ", argv.join(" "));
    auto logFile = File(ins.logPath, "w");
    ins.pid = spawnProcess(argv, stdin, logFile, logFile, env);


    // READINESS IS A REAL COMMAND ROUND TRIP, NOT `/api/registry` ANSWERING.
    //
    // Measured on this lane, on the first instrumented boot it ever did:
    // ./vibe3d-tsan answered /api/registry with a body containing "commands"
    // and NOT containing `selftest.fault`, and the very next POST to
    // /api/command came back `{"status":"error","message":"command handler not
    // set"}`. It is not a TSan defect and not a build defect — app.d starts the
    // HTTP server at :1145 and does not call registerCommands() until :3680, so
    // there is a wide window in which routes serve and no command can run. TSan
    // roughly doubles boot time, which widens the window enough to hit every
    // time; an uninstrumented boot wins the race by luck. The neighbouring
    // ASan lane's fuzz-boot step already says this in prose ("Readiness is
    // proven by a real COMMAND, not by /api/registry answering") — this makes
    // it true of the one place that starts instances.
    //
    // Three conditions, each closing a different half-ready state:
    //   (1) the registry answers at all;
    //   (2) it contains selftest.fault, i.e. registerCommands() has RUN (only
    //       meaningful for a buildType that declares SanitizerSelfTest);
    //   (3) a mainThread route answers without the bridge timeout body, i.e.
    //       the main loop is draining bridges. A route can serve while the
    //       main thread is wedged, and every command goes through that bridge.
    bool up = false;
    string why = "never answered";
    foreach (i; 0 .. 180) {
        auto r = httpGet(ins.port, "/api/registry", 3);
        if (!r.connected) {
            why = "not listening on the port yet";
        } else if (r.status == 503) {
            // The one "keep waiting" answer (task 1740). Named separately from
            // "no /api/registry" because they want opposite investigations: a
            // 503 is a healthy instance mid-startup, an unparseable registry
            // body is a broken one.
            why = "listening, but still wiring its HTTP providers (503)";
        } else if (!r.body_.canFind("\"commands\"")) {
            why = "no /api/registry";
        } else if (spec.hasSelfTest && !r.body_.canFind("selftest.fault")) {
            why = "registry answers but registerCommands() has not run "
                ~ "(selftest.fault absent)";
        } else if (ready == ReadyMode.bridgeFree) {
            auto c = httpGet(ins.port, "/api/camera", 20);
            if (!c.connected || c.status != 200)
                why = format("registry ready but /api/camera answered %d "
                           ~ "(503 = still wiring providers)", c.status);
            else { up = true; break; }
        } else {
            // Post an id that cannot exist: nothing runs either way, and the
            // only thing being read is the STATUS. 503 is the server saying
            // it is not ready; anything else means the dispatcher took the
            // request, which is what this mode is here to establish. The two
            // body strings this used to match on are gone from the wire — see
            // the ReadyMode comment above.
            auto c = httpPost(ins.port, "/api/command",
                              `{"id":"lane.readiness.probe","params":{}}`, 20);
            if (!c.connected || c.status == 0)
                why = "registry ready but /api/command did not answer";
            else if (c.status == 503)
                why = "registry ready but the command path is not ready yet "
                    ~ "(503 — providers unwired, or no frame has drained the "
                    ~ "main-thread bridges)";
            else { up = true; break; }
        }
        Thread.sleep(1.seconds);
    }
    if (!up) {
        auto tail = exists(ins.logPath) ? readText(ins.logPath) : "";
        killInstance(ins);
        fail(ins.bin ~ " was not READY within 180 s: " ~ why ~ ".\n"
           ~ "--- " ~ ins.logPath ~ " ---\n" ~ tail);
    }
    ins.editorPid = findEditorPid(ins.bin, ins.port);
    if (ins.editorPid == 0)
        writeln("lane.d: WARNING: could not find the editor pid in /proc — "
              ~ "the RSS watchdog and the signal-driven shutdown are blind");
    ok(format("%s up on port %s (editor pid %d)", ins.bin, ins.port, ins.editorPid));
    return ins;
}

void killInstance(ref Instance ins) {
    if (ins.editorPid > 0) posixKill(ins.editorPid, SIGKILL);
    try { kill(ins.pid); } catch (Exception) {}
    try { wait(ins.pid); } catch (Exception) {}
}

/// Clean shutdown, which is a REQUIREMENT and not a courtesy for two separate
/// reasons: HttpServer.stop() is the only place isRunning is cleared and the
/// socket fields are read/closed/nulled (the live control), and TSan's
/// `Matched N suppressions` block is printed by the atexit hook, so a killed
/// process never prints it. Two drivers, deliberately different:
///   sig=true  — SIGINT. SDL turns it into SDL_QUIT, which reaches the
///               quit-guard WITHOUT any main-thread bridge traffic. That is
///               what the A-arm of the bridge-ordering measurement needs.
///   sig=false — the file.quit command, which is bridged and therefore is NOT
///               bridge-free.
bool shutdownInstance(ref Instance ins, bool viaSignal, int budgetSec = 60) {
    bool gone() {
        return ins.editorPid > 0 && !exists(format("/proc/%d", ins.editorPid));
    }
    bool waitGone(int secs, string what) {
        foreach (i; 0 .. secs) {
            if (gone()) {
                ok(format("instance exited cleanly after %s (%d s)", what, i));
                try { wait(ins.pid); } catch (Exception) {}
                return true;
            }
            Thread.sleep(1.seconds);
        }
        return false;
    }
    if (ins.editorPid <= 0) {
        writeln("lane.d: WARNING: no editor pid — cannot observe the exit");
        killInstance(ins);
        return false;
    }

    // ESCALATION, and it is not defensive padding. Which rung actually works
    // is itself the measurement the shutdown control rests on: the plan
    // recorded that SIGINT did not terminate a TSan instance within 40 s,
    // which is why file.quit exists as a driver at all — but file.quit is a
    // BRIDGED command, so it is not a bridge-free shutdown and cannot serve
    // the A arm. Each rung prints which one landed.
    if (viaSignal) {
        posixKill(ins.editorPid, SIGINT);
        if (waitGone(budgetSec, "SIGINT")) return true;
        writeln("lane.d: NOTE: SIGINT did not terminate the instance within ",
                budgetSec, " s. HttpServer.stop() therefore did not run.");
    } else {
        httpPost(ins.port, "/api/command",
                 `{"id":"file.quit","params":{}}`, 15);
        if (waitGone(budgetSec, "file.quit")) return true;
        writeln("lane.d: NOTE: file.quit did not terminate the instance within ",
                budgetSec, " s; escalating to SIGINT.");
        posixKill(ins.editorPid, SIGINT);
        if (waitGone(30, "file.quit then SIGINT")) return true;
        posixKill(ins.editorPid, SIGTERM);
        if (waitGone(15, "file.quit then SIGTERM")) return true;
    }
    writeln("lane.d: WARNING: instance would not exit — SIGKILLing it. A "
          ~ "killed process prints no `Matched N suppressions` block and runs "
          ~ "no shutdown path, so anything that depended on either is now "
          ~ "unmeasured rather than measured-absent.");
    killInstance(ins);
    return false;
}

// ---------------------------------------------------------------------------
// A minimal HTTP client. Not curl, for two reasons: a sweep of every route x N
// concurrent callers is 200+ processes, and curl's exit status cannot
// distinguish "the route answered 400 because we sent no body" from "the
// instance is gone" without parsing anyway. The sweep's completion invariant
// needs exactly that distinction.
// ---------------------------------------------------------------------------
struct HttpReply { bool connected; int status; string body_; }

HttpReply httpRequest(string port, string method, string path,
                      string body_ = null, int timeoutSec = 30) {
    HttpReply r;
    Socket sock;
    try {
        sock = new TcpSocket();
        sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeoutSec.seconds);
        sock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, timeoutSec.seconds);
        sock.connect(new InternetAddress("127.0.0.1", port.to!ushort));
    } catch (Exception) {
        if (sock !is null) try { sock.close(); } catch (Exception) {}
        return r;
    }
    void closeSock() { try { sock.close(); } catch (Exception) {} }
    scope(exit) closeSock();
    r.connected = true;

    string req = method ~ " " ~ path ~ " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
               ~ "Connection: close\r\n";
    if (body_ !is null)
        req ~= "Content-Type: application/json\r\nContent-Length: "
             ~ body_.length.to!string ~ "\r\n";
    req ~= "\r\n";
    if (body_ !is null) req ~= body_;

    try { sock.send(req); } catch (Exception) { return r; }

    auto buf = appender!string;
    ubyte[8192] tmp;
    while (true) {
        ptrdiff_t n;
        try { n = sock.receive(tmp[]); } catch (Exception) { break; }
        if (n <= 0) break;
        buf.put(cast(string) tmp[0 .. n].idup);
    }
    auto raw = buf.data;
    auto nl = raw.indexOf("\r\n");
    if (nl > 0) {
        auto sl = raw[0 .. nl].split(" ");
        if (sl.length >= 2) { try { r.status = sl[1].to!int; } catch (Exception) {} }
    }
    auto hb = raw.indexOf("\r\n\r\n");
    if (hb >= 0) r.body_ = raw[hb + 4 .. $];
    return r;
}

HttpReply httpGet(string port, string path, int t = 30) {
    return httpRequest(port, "GET", path, null, t);
}
HttpReply httpPost(string port, string path, string body_, int t = 30) {
    return httpRequest(port, "POST", path, body_, t);
}

// ---------------------------------------------------------------------------
// The report parser and the SIGNATURE.
//
// A signature is a pair of SYMBOLS, not a pair of lines, and that is measured
// rather than stylistic. For one racing field TSan reports ONE of several
// possible line pairs: after a report it resets that address's shadow state,
// so a second pair on the same byte gets no report of its own. A phase-0
// miniature of start()/stop() reported the :1478 <-> :1502 pair and NOT the
// :1507 <-> :1480 pair the task card named — an oracle keyed on the line
// number would have returned a false negative on a race it was looking
// straight at.
// ---------------------------------------------------------------------------
struct RaceReport {
    string signature;
    string[] frames;    // the two chosen frames, for the human reading the log
    string file;        // the file the report came from
}

// ---------------------------------------------------------------------------
// THE SOURCE-POSITION SUFFIX IN A MANGLED NAME, AND WHY ONLY HALF OF IT GOES.
//
// The compiler names a generated symbol after WHERE IT WAS WRITTEN:
// `__lambda_L1564_C35`, and the same shape for `__dgliteral_`, `__foreachbody_`
// and friends. So the LINE NUMBER is in the mangled name, therefore in the
// TSan frame, therefore in the signature — and an edit ANYWHERE ABOVE the
// lambda renames it without changing one instruction inside it.
//
// Measured, 2026-08-21 (task 1700, the first night this lane ever reached its
// reports): the verdict declared TEN new races. One was new. Four were the
// same long-tolerated `start().__lambda ^ stop()` pair whose baseline row said
// `_L1469_C35` while the tree had moved that lambda to `_L1564_C35`; three
// more were the same story in http_providers.d, `_L1632_C13` against
// `_L1807_C13`. The lane's ONLY gate therefore reddened on commits that
// introduced no race at all — the one failure mode a gate must not have,
// because a gate that cries wolf gets switched off rather than read.
//
// WHAT THIS FUNCTION DOES: DROP THE LINE, KEEP THE COLUMN. That is a choice
// between two live options and it is written here rather than left implicit in
// a pattern, because the two differ in what the verdict can still tell apart:
//
//   * The LINE moves under every edit above the symbol. http_server.d is
//     4000 lines long and the lambda sits at 1564; essentially any change to
//     the file invalidates the row. That is the defect.
//   * The COLUMN moves only when the lambda's own statement is re-indented, or
//     the text before it ON THAT LINE changes — i.e. when the lambda or its
//     immediately enclosing block was edited. That is exactly the occasion on
//     which re-reading the baseline row is the RIGHT thing to do, so the
//     column failing is a signal rather than noise.
//
// THE PRICE, SAID OUT LOUD RATHER THAN DISCOVERED LATER: two DIFFERENT lambdas
// declared in the SAME function at the SAME column collapse into ONE signature
// and the verdict can no longer separate them — a race in the second would be
// silently accepted by the first one's row. Keeping the column shrinks that
// set (two lambdas in one function usually sit at different nesting depths,
// hence different columns) but does NOT empty it: two `new Thread({` at the
// same indentation in one function is a perfectly ordinary thing to write.
// Dropping the column too would collapse EVERY lambda in a function, which is
// strictly worse; keeping the line makes the gate unusable, which is strictly
// worse the other way. This is the middle, and it is a trade.
//
// What survives either way: the enclosing function's FULL signature and the
// module basename stay in the key, so a collapsed pair is still pinned to one
// function in one file for whoever reads the log.
//
// The match is deliberately anchored on the PAIR `_L<digits>_C<digits>`, not
// on `_L<digits>` alone, so an ordinary identifier that happens to end in
// `_L12` is untouched. Written as an explicit scan rather than a regex so the
// rule is readable as a rule.
// ---------------------------------------------------------------------------
string dropSourceLine(string sym) {
    string outp;
    size_t i = 0;
    while (i < sym.length) {
        if (i + 1 < sym.length && sym[i] == '_' && sym[i + 1] == 'L') {
            size_t d = i + 2;
            while (d < sym.length && sym[d] >= '0' && sym[d] <= '9') ++d;
            const bool haveDigits = d > i + 2;
            const bool haveCol    = d + 2 < sym.length
                                 && sym[d] == '_' && sym[d + 1] == 'C'
                                 && sym[d + 2] >= '0' && sym[d + 2] <= '9';
            if (haveDigits && haveCol) { i = d; continue; }   // keep `_C<n>`
        }
        outp ~= sym[i];
        ++i;
    }
    return outp;
}

/// The same drop, applied to a whole `A ^ B` signature. Both sides of the
/// comparison go through THIS call — the parsed frame and the declared row —
/// because a normalisation applied to one side only is a silent mismatch.
string normaliseSignature(string sig) { return dropSourceLine(sig); }

/// `#0 some.symbol(args) /abs/path/file.d:123:4 (vibe3d-tsan+0x1234)`
/// -> `some.symbol(args)@file.d`, but only when the path is under source/.
/// The symbol may contain spaces (`std.functional.binaryFun!("a < b")`), so
/// the parse works from the RIGHT: strip the trailing `(module+off)`, then the
/// last remaining token is the location and everything before it is the name.
string frameKey(string line) {
    auto t = line.strip;
    if (!t.startsWith("#")) return null;
    auto sp = t.indexOf(' ');
    if (sp < 0) return null;
    t = t[sp + 1 .. $].strip;                 // drop "#N "
    // Strip EVERY trailing parenthesised group, not just the last one. A real
    // frame from this toolchain ends
    //     racer.raceWorker() /abs/source/racer.d:3 (racer+0x400b6e) (BuildId: 9ae1e7...)
    // and cutting only one leaves `(racer+0x400b6e)` sitting where the
    // location should be, so the key comes out as garbage and every signature
    // silently stops matching. Measured against a real report file, which is
    // the only reason it is written this way.
    while (t.endsWith(")")) {
        auto open = t.lastIndexOf(" (");
        if (open <= 0) break;
        t = t[0 .. open].strip;
    }
    auto lsp = t.lastIndexOf(' ');
    if (lsp <= 0) return null;
    auto sym = t[0 .. lsp].strip;
    auto loc = t[lsp + 1 .. $].strip;
    auto colon = loc.indexOf(':');
    auto path = colon > 0 ? loc[0 .. colon] : loc;
    if (!(path.canFind("/source/") || path.startsWith("source/"))) return null;
    if (!sym.length) return null;
    // The line number is dropped HERE, at the one place an observed frame
    // becomes a key, so no caller can forget to do it. See dropSourceLine.
    return dropSourceLine(sym) ~ "@" ~ baseName(path);
}

bool isAccessHeader(string line) {
    auto t = line.strip;
    static immutable string[] verbs = [
        "Write of size", "Read of size",
        "Atomic write of size", "Atomic read of size",
        "Previous write of size", "Previous read of size",
        "Previous atomic write of size", "Previous atomic read of size",
    ];
    foreach (v; verbs) if (t.startsWith(v)) return true;
    return false;
}

enum kNoSourceFrame = "<no-source-frame>";

RaceReport[] parseReportFile(string path) {
    RaceReport[] out_;
    if (!exists(path)) return out_;
    auto lines = readText(path).lineSplitter.array;
    size_t i = 0;
    while (i < lines.length) {
        if (!lines[i].canFind("WARNING: ThreadSanitizer: data race")) { ++i; continue; }
        // Collect this block until SUMMARY: or the next WARNING.
        string[] keys;
        string[] shown;
        size_t j = i + 1;
        while (j < lines.length
               && !lines[j].canFind("WARNING: ThreadSanitizer:")
               && !lines[j].strip.startsWith("SUMMARY:")) {
            if (isAccessHeader(lines[j]) && keys.length < 2) {
                size_t k = j + 1;
                string picked, pickedLine;
                while (k < lines.length && lines[k].strip.startsWith("#")) {
                    auto key = frameKey(lines[k]);
                    if (key !is null && picked is null) {
                        picked = key; pickedLine = lines[k].strip;
                    }
                    ++k;
                }
                keys ~= (picked is null ? kNoSourceFrame : picked);
                shown ~= (picked is null ? lines[j].strip : pickedLine);
                j = k;
                continue;
            }
            ++j;
        }
        RaceReport r;
        r.file = path;
        r.frames = shown;
        if (keys.length == 2) { keys.sort(); r.signature = keys[0] ~ " ^ " ~ keys[1]; }
        else if (keys.length == 1) r.signature = keys[0] ~ " ^ " ~ kNoSourceFrame;
        else r.signature = kNoSourceFrame ~ " ^ " ~ kNoSourceFrame;
        out_ ~= r;
        i = j;
    }
    return out_;
}

string[] reportFilesFor(string tagGlob) {
    string[] fs;
    foreach (e; dirEntries(getcwd(), "tsan-report-" ~ tagGlob ~ "*", SpanMode.shallow))
        if (isFile(e.name)) fs ~= e.name;
    fs.sort();
    return fs;
}

RaceReport[] reportsFor(string tagGlob) {
    RaceReport[] all;
    foreach (f; reportFilesFor(tagGlob)) all ~= parseReportFile(f);
    return all;
}

void removeReports(string tagGlob) {
    foreach (f; reportFilesFor(tagGlob)) std.file.remove(f);
}

/// `ThreadSanitizer: Matched N suppressions (pid=...):` followed by one
/// `  N <type>:<pattern>` line each. AT ZERO MATCHES THE BLOCK IS NOT PRINTED
/// AT ALL — not "Matched 0" — so a parser written against the block alone can
/// never have been tested, and "no block" has to be a distinguishable answer.
struct SuppMatches { bool blockPresent; int total; int[string] byPattern; }

SuppMatches parseSuppressionBlock(string[] files) {
    SuppMatches m;
    foreach (f; files) {
        if (!exists(f)) continue;
        auto lines = readText(f).lineSplitter.array;
        foreach (i, ln; lines) {
            auto hit = ln.matchFirst(regex(r"ThreadSanitizer: Matched (\d+) suppressions"));
            if (hit.empty) continue;
            m.blockPresent = true;
            m.total += hit[1].to!int;
            size_t k = i + 1;
            while (k < lines.length && lines[k].strip.length) {
                auto row = lines[k].strip.matchFirst(regex(r"^(\d+)\s+(\S+)"));
                if (row.empty) break;
                m.byPattern[row[2]] = m.byPattern.get(row[2], 0) + row[1].to!int;
                ++k;
            }
        }
    }
    return m;
}

// ---------------------------------------------------------------------------
// preflight-tsan — the checks that are specific to THIS lane and need no build.
// ---------------------------------------------------------------------------
enum kTsanWorkflow  = ".github/workflows/tsan.yaml";
enum kTsanSupp      = "tools/sanitizer/tsan.supp";
enum kTsanCanary    = "tools/sanitizer/tsan_canary.supp";
enum kTsanExpected  = "tools/sanitizer/tsan_expected.txt";

struct ExpectedRow {
    string klass;
    /// EVERY scenario this signature is expected in, not one of them. See the
    /// note above loadExpected for why this is a list and why it is not a
    /// wildcard.
    string[] scenarios;
    string signature, date, task, reason;
}

/// `class | scenario[,scenario...] | signature | date | task | reason`
///
/// THE SCENARIO FIELD IS A LIST, AND IT IS NOT ALLOWED TO BE A WILDCARD.
/// -------------------------------------------------------------------
/// It used to be a single name, and that was a recording error rather than a
/// property of any race. The `start().__lambda ^ stop()` row says so in its
/// own reason — "it fires on every clean shutdown, so every scenario that
/// shuts down cleanly carries it" — and it was nonetheless written out four
/// times, once per scenario, with the one reason copied and drifting. The
/// registry rows drifted the other way: declared for `bridge` and `sweep`,
/// they fired in `selfcheck` and `shutdown` on 2026-08-21 and reddened the
/// night as three separate NEW RACES that were nothing of the kind, while
/// their absence from `bridge` — the scenario they WERE declared for — went by
/// as a note (task 1700).
///
/// So a row now names every scenario it is expected in, in one place, with one
/// reason. A wildcard (`*`, `any`) is REFUSED rather than supported: the
/// verdict's second direction is "declared here and did NOT fire", and a row
/// that matches every scenario by construction can never fail that way. It
/// would turn the `required` class into a grep and quietly delete half the
/// gate. Naming the four costs four words and keeps absence-per-scenario a
/// visible outcome.
ExpectedRow[] loadExpected(string path = kTsanExpected) {
    if (!exists(path)) fail("no " ~ path ~ " — the lane has no verdict function");
    ExpectedRow[] rows;
    size_t lineNo;
    foreach (raw; readText(path).lineSplitter) {
        ++lineNo;
        auto ln = raw.strip;
        if (!ln.length || ln.startsWith("#")) continue;
        auto f = ln.split("|").map!(a => a.strip).array;
        if (f.length != 6)
            fail(format("%s:%d: expected 6 `|`-separated fields "
                      ~ "(class|scenario|signature|date|task|reason), got %d: %s",
                        path, lineNo, f.length, ln));
        if (f[0] != "required" && f[0] != "tolerated")
            fail(format("%s:%d: class must be required|tolerated, got `%s`",
                        path, lineNo, f[0]));
        static immutable string[] scen =
            ["selfcheck", "sweep", "shutdown", "bridge", "parallel"];
        if (f[1] == "*" || f[1] == "any" || f[1] == "all")
            fail(format("%s:%d: `%s` is refused as a scenario. A row that "
                      ~ "matches every scenario cannot fail the verdict's "
                      ~ "second direction (declared, did not fire), so it "
                      ~ "silently deletes half the gate. Name the scenarios: "
                      ~ "`%s`.", path, lineNo, f[1], scen.join(",")));
        auto scens = f[1].split(",").map!(a => a.strip)
                                    .filter!(a => a.length).array;
        if (!scens.length)
            fail(format("%s:%d: empty scenario field", path, lineNo));
        foreach (sc; scens) {
            if (!scen.canFind(sc))
                fail(format("%s:%d: scenario must be one of %s, got `%s`",
                            path, lineNo, scen, sc));
            if (scens.count(sc) > 1)
                fail(format("%s:%d: scenario `%s` listed twice", path, lineNo, sc));
        }
        if (!f[4].length)
            fail(format("%s:%d: a row with no owning task is not accepted",
                        path, lineNo));
        // The declared signature goes through the SAME normalisation as an
        // observed frame (dropSourceLine), and a row that CHANGES under it is
        // refused rather than quietly repaired: a pasted `_L1564_C35` would
        // otherwise keep working while the file stopped saying what the
        // verdict actually compares. The message names the text to write.
        const norm = normaliseSignature(f[2]);
        if (norm != f[2])
            fail(format("%s:%d: the signature carries a source LINE, which "
                      ~ "moves under any edit above the symbol and is dropped "
                      ~ "before comparison. Write it without the `_L<n>`:\n"
                      ~ "    %s", path, lineNo, norm));
        rows ~= ExpectedRow(f[0], scens, norm, f[3], f[4], f[5]);
    }
    return rows;
}

/// Rule lines of a suppression file (`type:pattern`), comments dropped.
string[] loadSuppressionRules(string path) {
    string[] rules;
    if (!exists(path)) return rules;
    static immutable string[] types = ["race", "race_top", "thread", "mutex",
                                       "signal", "called_from_lib", "deadlock"];
    size_t lineNo;
    foreach (raw; readText(path).lineSplitter) {
        ++lineNo;
        auto ln = raw.strip;
        if (!ln.length || ln.startsWith("#")) continue;
        const colon = ln.indexOf(':');
        if (colon <= 0 || !types.canFind(ln[0 .. colon]))
            fail(format("%s:%d: not a suppression rule (`type:pattern`, type "
                      ~ "one of %s): %s", path, lineNo, types, ln));
        if (ln.canFind('#'))
            fail(format("%s:%d: a trailing `#` comment becomes PART OF THE "
                      ~ "PATTERN in compiler-rt's parser and the rule then "
                      ~ "matches nothing. Put it on the line above: %s",
                        path, lineNo, ln));
        rules ~= ln;
    }
    return rules;
}

void cmdPreflightTsan() {
    // (1) symbolize=0 must appear nowhere in the workflow. This is half (b) of
    // the ban; half (a) lives in spawnInstance, where the option string is
    // actually built — a check on lane.d's own environment would inspect the
    // wrong process.
    if (!exists(kTsanWorkflow)) fail("no " ~ kTsanWorkflow);
    auto wf = readText(kTsanWorkflow);
    foreach (i, ln; wf.lineSplitter.array)
        if (ln.canFind("symbolize=0"))
            fail(format("%s:%d carries symbolize=0: %s\nMeasured: it silently "
                      ~ "disables the suppression file (matching is by symbol "
                      ~ "NAME), turning a 0-warning run into a 6-warning one "
                      ~ "with nothing matched.", kTsanWorkflow, i + 1, ln.strip));
    ok("no symbolize=0 in " ~ kTsanWorkflow);

    // (2) The workflow and the window constants must AGREE. Raising
    // kTsanTimeoutMin without touching the yaml would leave the guard
    // computing one window and the runner enforcing another.
    auto tm = wf.matchFirst(regex(r"timeout-minutes:\s*(\d+)"));
    if (tm.empty) fail(kTsanWorkflow ~ " declares no timeout-minutes");
    if (tm[1].to!int != kTsanTimeoutMin)
        fail(format("%s says timeout-minutes: %s but lane.d computes its "
                  ~ "window from kTsanTimeoutMin = %d. The guard and the "
                  ~ "runner would enforce different windows.",
                    kTsanWorkflow, tm[1], kTsanTimeoutMin));
    auto cr = wf.matchFirst(regex(r"cron:\s*'(\d+)\s+(\d+)\s"));
    if (cr.empty) fail(kTsanWorkflow ~ " declares no cron");
    const cronMin = cr[2].to!int * 60 + cr[1].to!int;
    if (cronMin < kTsanWindowOpenUtcMin || cronMin >= tsanLatestStartUtcMin())
        fail(format("%s crons at %s UTC, outside the computed start window "
                  ~ "[%s, %s)", kTsanWorkflow, hhmm(cronMin),
                    hhmm(kTsanWindowOpenUtcMin), hhmm(tsanLatestStartUtcMin())));
    // Cumulative occupancy, not a sum of durations. The next lane has its own
    // cron, so it starts at max(its cron, when we let go of the runner); the
    // plan's `17:00 + 100 + 270` treated it as starting the moment we finish,
    // which is only the worst case if we overrun past 19:00.
    const worstTsanEnd = cronMin + kTsanTimeoutMin;
    const nextStart    = worstTsanEnd > kNextLaneStartUtcMin
                       ? worstTsanEnd : kNextLaneStartUtcMin;
    const nextEnd      = nextStart + 270;
    if (nextEnd > kPerfStartUtcMin + 24 * 60)
        fail(format("cumulative occupancy overruns the perf nightly: tsan ends "
                  ~ "at worst %s, the sanitizer lane then runs to %s, and perf "
                  ~ "starts at 00:30", hhmm(worstTsanEnd), hhmm(nextEnd % (24*60))));
    ok(format("window closes: cron %s + %d min = worst end %s (< next lane %s); "
            ~ "cumulative: next lane runs %s..%s, perf starts 00:30",
              hhmm(cronMin), kTsanTimeoutMin, hhmm(worstTsanEnd),
              hhmm(kNextLaneStartUtcMin), hhmm(nextStart),
              hhmm(nextEnd % (24 * 60))));

    // (2a) AN ON-TIME NIGHT MUST COLLIDE WITH NOTHING. Added with the
    // 2026-08-30 move of the cron target to 04:30, because the membership
    // test above stopped being sufficient the moment the window's open left
    // the middle of the evening.
    //
    // The old open, 17:00, sat four hours clear of every other lane's
    // occupancy, so "the cron is inside [open, idealLatest)" implied "the cron
    // target collides with nothing". The new open ABUTS perf's worst-case
    // finish with ZERO margin: 04:30 is the first accepted minute of the day
    // and 04:29 is refused on `collidesWithPerf`. Raise `perf.yaml`'s
    // `timeout-minutes` from 240 by one minute and the target sits inside
    // perf's occupancy — the tsan job then queues behind a perf run that is
    // still measuring, and the perf number it queued behind was taken beside
    // whatever the runner was doing. `kPerfEndUtcMin` is not a term of the
    // membership test, so nothing above can see it.
    //
    // IT ASKS `occupancyHazard` DIRECTLY, AND THAT IS THE WHOLE POINT. The
    // first draft of this check ran the target through `checkScheduleWindow`
    // and required `pass` — and was INERT, measured: with `kPerfEndUtcMin`
    // mutated to 04:31 the whole preflight stayed green (rc=0). Inside
    // `[open, hardLatest)` that function returns pass/passLate
    // unconditionally and never consults the hazard, so asking it about a
    // target that check (2) has just confirmed is inside its own slot can
    // only ever answer yes. It was a second spelling of (2), wearing the
    // clothes of a collision check.
    {
        const h = occupancyHazard(cronMin, kTsanTimeoutMin,
            kNextLaneStartUtcMin, kNextLaneEndUtcMin,
            kPerfStartUtcMin, kPerfEndUtcMin);
        if (h.any) {
            string[] why;
            if (h.collidesWithSanitizer) why ~= "overlaps the sanitizer lane";
            if (h.collidesWithPerf)      why ~= "overlaps the perf lane";
            if (h.pushesSanitizerIntoPerf) why ~= "the induced chain reaches perf";
            fail(format("%s crons at %s UTC, and a delivery ON TIME at that "
                      ~ "target COLLIDES: %s. The run window is [%s, %s), "
                      ~ "the sanitizer lane occupies [%s, %s) and perf "
                      ~ "[%s, %s). This runner takes ONE job at a time, so a "
                      ~ "target inside another lane's occupancy is not a "
                      ~ "clash but a queue — and the guard will refuse every "
                      ~ "on-time night, which is a red job that measured "
                      ~ "NOTHING. Move the cron target (and "
                      ~ "kTsanWindowOpenUtcMin with it), or give the open "
                      ~ "back its margin.",
                        kTsanWorkflow, hhmm(cronMin), why.join("; "),
                        hhmm(cronMin), hhmm((cronMin + kTsanTimeoutMin) % (24 * 60)),
                        hhmm(kNextLaneStartUtcMin), hhmm(kNextLaneEndUtcMin % (24 * 60)),
                        hhmm(kPerfStartUtcMin), hhmm(kPerfEndUtcMin)));
        }
        ok(format("the declared cron target %s collides with nothing "
                ~ "(perf's occupancy ends %s, so the open has %d min of "
                ~ "margin)", hhmm(cronMin), hhmm(kPerfEndUtcMin),
                  kTsanWindowOpenUtcMin - kPerfEndUtcMin));
    }

    // (2d) THE DRIFT TOLERANCE MUST COVER THE MEASURED MAXIMUM. This is the
    // reason the cron target moved on 2026-08-30, kept as a check instead of
    // a paragraph.
    //
    // The tolerance is `hardLatest - open`, and it is CONTIGUOUS by
    // construction rather than by luck: inside `[open, hardLatest)`
    // `checkScheduleWindow` returns `pass` or `passLate` unconditionally —
    // that branch never consults `occupancyHazard`, deliberately (a start at
    // 18:39 does overlap the sanitizer lane and is accepted anyway, which is
    // what the drift-tolerance zone IS). So there are no holes to sweep for,
    // and this check does not pretend to sweep. It was verified out of band
    // all the same: all 1440 minute-of-day starts driven through
    // `cmdWindowGuard` give the accepted set
    // {00:00} u [04:30, 19:30) u [23:30, 24:00), whose run containing the
    // target is [04:30, 19:29] = 900 minutes = exactly 15 hours, with 04:29
    // refused below it (perf) and 19:30 refused above it (the chain).
    //
    // What this catches that (2a) cannot: (2a) asks whether an ON-TIME
    // delivery is accepted, and stays green while the tolerance behind it
    // collapses to a minute. This asks whether a delivery as late as any this
    // repository has recorded is still accepted — the failure mode that made
    // the lane silent from 2026-08-25, which was never a target that could
    // not run, but a target with nowhere to drift TO.
    {
        const tolerance = tsanHardLatestStartUtcMin() - kTsanWindowOpenUtcMin;
        if (tolerance < kMeasuredMaxDriftMin)
            fail(format("the drift tolerance from the cron target is %d min "
                      ~ "(%.1fh): the window opens %s and the hard ceiling is "
                      ~ "%s. The MEASURED maximum schedule-delivery drift for "
                      ~ "this repository is %d min (%.1fh, "
                      ~ "tools/ci/nightly_freshness.d live 2026-08-30), so a "
                      ~ "night that drifts as far as this project has already "
                      ~ "seen would be REFUSED — and a refused window is a red "
                      ~ "job that measured NOTHING, which is how this lane "
                      ~ "went silent for five nights from 2026-08-25. Move the "
                      ~ "cron target (and kTsanWindowOpenUtcMin with it) "
                      ~ "earlier, or shorten kTsanTimeoutMin / the sanitizer "
                      ~ "lane's budget to lift the ceiling.",
                        tolerance, tolerance / 60.0,
                        hhmm(kTsanWindowOpenUtcMin),
                        hhmm(tsanHardLatestStartUtcMin()),
                        kMeasuredMaxDriftMin, kMeasuredMaxDriftMin / 60.0));
        ok(format("drift tolerance from the target %s is %d min (%.1fh), "
                ~ "contiguous to the hard ceiling %s — covers the measured "
                ~ "maximum %d min (%.1fh) with %d min to spare",
                  hhmm(kTsanWindowOpenUtcMin), tolerance, tolerance / 60.0,
                  hhmm(tsanHardLatestStartUtcMin()), kMeasuredMaxDriftMin,
                  kMeasuredMaxDriftMin / 60.0,
                  tolerance - kMeasuredMaxDriftMin));
    }

    // (2b) The schedule-window verdict table (`checkScheduleWindow`),
    // exercised against FIXED inputs rather than the wall clock. The
    // mutation this catches — the drift-tolerance zone collapsing (SKIP
    // becomes FAIL) or disappearing (the hard ceiling collapsing onto the
    // ideal one, so FAIL becomes PASS everywhere) — is otherwise observable
    // for only a ~90-minute slot once a day (see `nowUtcMin`'s doc comment).
    // One point pins the actual measured incident this split was written
    // for: `nightly-tsan` run 33002973869 was created 19:02:02Z against a
    // 17:00 cron (122 minutes late) and must NOT fail here. (The prior
    // 27-minutes-late incident on 2026-08-19 is not a counter-example: it
    // was refused under the OLD kTsanTimeoutMin=100, and under today's 30 it
    // lands at 17:27 — inside the IDEAL window either way, not a drift-zone
    // case at all.)
    {
        const hardLatest = tsanHardLatestStartUtcMin();
        alias V = ScheduleVerdict;
        static struct Case { int now; V want; string label; }
        const idealLatest = tsanLatestStartUtcMin();
        auto cases = [
            Case(kTsanWindowOpenUtcMin, V.pass,
                 "the window's open edge — and since the 2026-08-30 move it is "
               ~ "also the FIRST minute after perf's worst-case finish, so the "
               ~ "open abuts the hazard with zero margin"),
            Case(idealLatest - 1, V.pass, "one minute inside the ideal window"),
            Case(idealLatest, V.passLate, "the ideal window's close edge"),
            Case(19 * 60 + 2, V.passLate,
                 "the measured 2026-08-26 incident (run 33002973869, "
               ~ "created 19:02:02Z)"),
            Case(hardLatest - 1, V.passLate,
                 "one minute inside the hard ceiling"),
            // THE CRON MOVE, 2026-08-30. These two used to be `passOffSlot`
            // for being outside [17:00, 19:30) and are the acceptance the
            // move buys: with the open back at 17:00 both go passOffSlot and
            // this table reddens, which is what stops the constant and the
            // workflow's cron from drifting apart in the quiet direction.
            Case(11 * 60, V.pass,
                 "11:00 — the middle of the owner's working day, now INSIDE "
               ~ "the ideal window. This is what the move traded for: the "
               ~ "runner is the owner's workstation, and a start here is "
               ~ "~1.12 GiB under xvfb-run plus CPU, accepted deliberately"),
            Case(16 * 60 + 4, V.pass,
                 "the NEW 04:30 target + the MEASURED MAXIMUM delivery drift "
               ~ "(693.6min / 11.6h, tools/ci/nightly_freshness.d live "
               ~ "2026-08-30) — the single cell the move is argued against; "
               ~ "146 min short of the ideal close, 206 min (3.4h) short of "
               ~ "the hard ceiling"),
            // OFF-SLOT, 2026-08-30. These used to be a flat FAIL for being
            // outside the slot; the verdict is now the OCCUPANCY, and each of
            // the three hazard terms gets a cell in which it is the term that
            // fires.
            Case(23 * 60 + 30, V.passOffSlot,
                 "the sanitizer lane has just finished and perf is an hour "
               ~ "away — after the cron move this is the ONLY region the "
               ~ "off-slot switch still governs"),
            Case(hardLatest, V.fail, "the hard ceiling itself"),
            // A LITERAL, deliberately, and NOT `kTsanWindowOpenUtcMin - 1`.
            // Written relative to the constant it is meant to police, this
            // cell moves with the mutation and can never come out
            // differently: at open=04:00 it would ask about 03:59, which is
            // outside the slot and refused, and the check would sail through
            // the exact defect it exists for. Pinned to the minute perf's
            // occupancy actually ends.
            Case(4 * 60 + 29, V.fail,
                 "04:29 — one minute before perf's occupancy ends AND, since "
               ~ "the 2026-08-30 move, one minute before the nominal open; "
               ~ "collidesWithPerf is the ONLY term that fires (decomposition "
               ~ "asserted in (2c)). This is the cell that refuses an open "
               ~ "moved EARLIER than 04:30: at open=04:00 it lands inside the "
               ~ "slot and returns `pass` while perf may still be measuring"),
            Case(0 * 60 + 52, V.fail,
                 "the real 2026-08-2x delivery at 00:52 UTC — still refused, "
               ~ "and for the right reason now"),
            Case(20 * 60, V.fail, "an hour into the sanitizer lane's window"),
        ];
        foreach (c; cases) {
            auto got = checkScheduleWindow(c.now, kTsanWindowOpenUtcMin,
                idealLatest, hardLatest, kTsanTimeoutMin, kNextLaneStartUtcMin,
                kNextLaneEndUtcMin, kPerfStartUtcMin, kPerfEndUtcMin);
            if (got.verdict != c.want)
                fail(format("schedule-window selfcheck: at %s (%s) expected "
                          ~ "%s, got %s — %s", hhmm(c.now), c.label, c.want,
                            got.verdict, got.message));
        }
        ok(format("schedule-window selfcheck: %d cases agree (ideal close "
                ~ "%s, hard ceiling %s)", cases.length, hhmm(idealLatest),
                  hhmm(hardLatest)));

        // (2c) The off-slot POLICY switch, and the two hazard terms that the
        // real constants cannot isolate. `checkScheduleWindow` takes every
        // constant as an argument precisely so these cells exist: with the
        // shipped numbers, any evening start that overlaps the sanitizer lane
        // ALSO pushes its chain into perf, so a mutation of one term would
        // hide behind the other. Synthetic lanes separate them.
        {
            // A hazard-free OFF-SLOT instant with off-slot acceptance TURNED
            // OFF: same instant, same hazard (none), opposite verdict. This
            // is what keeps `kTsanAcceptSafeOffSlotStarts = false` from
            // rotting into unexecuted dead code.
            //
            // 23:30 and not the 04:36 this block used to drive: after the
            // 2026-08-30 cron move 04:36 is INSIDE the nominal slot and never
            // reaches the policy branch at all, so the old cell would have
            // gone red for the right reason and been "fixed" by deleting the
            // only exercise of the refusing arm. Measured after the move, the
            // switch governs {00:00} u [23:30, 24:00) and nothing else.
            auto refused = checkScheduleWindow(23 * 60 + 30, kTsanWindowOpenUtcMin,
                idealLatest, hardLatest, kTsanTimeoutMin, kNextLaneStartUtcMin,
                kNextLaneEndUtcMin, kPerfStartUtcMin, kPerfEndUtcMin,
                /*acceptSafeOffSlot=*/false);
            if (refused.verdict != ScheduleVerdict.fail)
                fail("off-slot policy selfcheck: with kTsanAcceptSafeOffSlot"
                   ~ "Starts=false, 23:30 must be REFUSED, got "
                   ~ refused.verdict.to!string ~ " — " ~ refused.message);
            if (!refused.message.canFind("collides with NOTHING"))
                fail("off-slot policy selfcheck: the refusal must say it is a "
                   ~ "policy refusal, not a collision: " ~ refused.message);

            // ONLY collidesWithSanitizer: a 30-minute sanitizer lane at
            // 10:15 and a perf lane at 23:00, so nothing this run does can
            // reach perf, directly or through the chain.
            const hSan = occupancyHazard(10 * 60, 30, 10 * 60 + 15,
                                          10 * 60 + 45, 23 * 60, 23 * 60 + 30);
            if (!(hSan.collidesWithSanitizer && !hSan.collidesWithPerf
                  && !hSan.pushesSanitizerIntoPerf))
                fail(format("occupancyHazard selfcheck: the sanitizer-overlap "
                          ~ "cell must fire that term ALONE, got %s", hSan));

            // ONLY pushesSanitizerIntoPerf: this run ends at 10:30, clear of
            // a sanitizer lane at [11:00, 12:00) and of perf at [12:00,
            // 13:00) — but the chain lands exactly on perf's start.
            const hPush = occupancyHazard(10 * 60, 30, 11 * 60, 12 * 60,
                                           12 * 60, 13 * 60);
            if (!(hPush.pushesSanitizerIntoPerf && !hPush.collidesWithSanitizer
                  && !hPush.collidesWithPerf))
                fail(format("occupancyHazard selfcheck: the chain-push cell "
                          ~ "must fire that term ALONE, got %s", hPush));

            // ONLY collidesWithPerf is the 04:29 row in the table above; assert
            // the decomposition here too, so the table's `fail` cannot be
            // satisfied by the wrong term.
            const hPerf = occupancyHazard(4 * 60 + 29, kTsanTimeoutMin,
                kNextLaneStartUtcMin, kNextLaneEndUtcMin,
                kPerfStartUtcMin, kPerfEndUtcMin);
            if (!(hPerf.collidesWithPerf && !hPerf.collidesWithSanitizer
                  && !hPerf.pushesSanitizerIntoPerf))
                fail(format("occupancyHazard selfcheck: 04:29 must fire the "
                          ~ "perf-overlap term ALONE, got %s", hPerf));

            ok("off-slot policy + the three hazard terms each isolated");
        }
    }

    // (3) The verdict function and the canary must parse, and the canary must
    // actually carry a rule — an empty canary makes the selfcheck's B arm
    // pass for the wrong reason.
    auto rows = loadExpected();
    if (!rows.any!(r => r.klass == "required"))
        fail(kTsanExpected ~ " declares no `required` row — nothing would "
           ~ "witness that the instrument is armed, and the whole lane could "
           ~ "go green with TSan switched off");
    ok(format("%s parses: %d rows, %d required", kTsanExpected, rows.length,
              rows.count!(r => r.klass == "required")));

    auto canary = loadSuppressionRules(kTsanCanary);
    if (canary.length != 1)
        fail(format("%s must carry exactly one rule (it is the canary, not a "
                  ~ "working list); it has %d", kTsanCanary, canary.length));
    ok(kTsanCanary ~ " carries exactly one rule: " ~ canary[0]);

    auto working = loadSuppressionRules(kTsanSupp);
    if (working.length == 0)
        writeln("lane.d: NOTE: ", kTsanSupp, " is empty, so "
              ~ "`tsan-audit-suppressions` is VACUOUS by construction. That is "
              ~ "deliberate and recorded in the file: the witness for the "
              ~ "suppression machinery is the canary above, exercised twice "
              ~ "every night by tsan-selfcheck.");
    else
        ok(format("%s carries %d rule(s)", kTsanSupp, working.length));
}

// ---------------------------------------------------------------------------
// tsan-selfcheck — THE GATE. Two runs of the same binary and the same fault.
//
//   A: no suppression file  => EXACTLY ONE race naming our worker, and NO
//                              `Matched N suppressions` block.
//   B: the canary file      => ZERO races naming our worker, and the block
//                              present with a non-zero count. Measured: the
//                              count is 2 for one suppressed race, because
//                              BOTH access stacks match the rule — so the
//                              assertion is ">= 1", not "== 1".
//
// A alone proves the instrument is armed. B alone proves symbolisation
// produces names, that suppression matching works by name, and that the audit
// parser has seen its block — three things that otherwise fail silently and
// look exactly like a clean night.
// ---------------------------------------------------------------------------
enum kRaceSymbol = "selfTestRaceWorker";

int fireRaceAndCount(BuildTypeSpec spec, string tag, string suppressions,
                     out SuppMatches supp, out RaceReport[] all) {
    removeReports(tag);
    auto ins = spawnInstance(spec, tag, null, suppressions);
    scope(failure) killInstance(ins);
    auto r = httpPost(ins.port, "/api/command",
                      `{"id":"selftest.fault","params":{"kind":"race"}}`, 120);
    if (!r.connected)
        { killInstance(ins); fail("the instance did not answer the race command"); }
    writeln("lane.d: [", tag, "] reply: ", r.body_.length > 200 ? r.body_[0 .. 200] : r.body_);
    // A CLEAN exit is required, not polite: `Matched N suppressions` is
    // printed by the atexit hook and a killed process prints nothing.
    shutdownInstance(ins, /*viaSignal=*/false);
    auto files = reportFilesFor(tag);
    writeln("lane.d: [", tag, "] report files: ", files);
    all  = reportsFor(tag);
    supp = parseSuppressionBlock(files);
    return cast(int) all.count!(x => x.signature.canFind(kRaceSymbol));
}

void cmdTsanSelfcheck() {
    auto spec = specFor("tsan");

    SuppMatches suppA; RaceReport[] allA;
    const nA = fireRaceAndCount(spec, "selfcheckA", null, suppA, allA);
    writeln("lane.d: [A] ", allA.length, " race report(s) total, ", nA,
            " naming ", kRaceSymbol);
    foreach (r; allA) writeln("lane.d: [A]   ", r.signature);
    if (nA != 1)
        fail(format("run A reported %d races naming %s, expected exactly 1.\n"
                  ~ "THE INSTRUMENT IS NOT ARMED, AND NOTHING ELSE THIS LANE "
                  ~ "PRINTS TONIGHT MEANS ANYTHING. Under --DRT-gcopt=gc:manual "
                  ~ "a healthy run is silent, so silence here is "
                  ~ "indistinguishable from a build without --fsanitize=thread, "
                  ~ "an instance that never started, or a dead symbolizer.",
                    nA, kRaceSymbol));
    if (suppA.blockPresent)
        fail("run A used NO suppression file yet printed a `Matched "
           ~ suppA.total.to!string ~ " suppressions` block — something is "
           ~ "supplying suppressions behind the lane's back");
    ok("A: exactly one race naming " ~ kRaceSymbol ~ ", and no Matched block");

    SuppMatches suppB; RaceReport[] allB;
    const nB = fireRaceAndCount(spec, "selfcheckB", kTsanCanary, suppB, allB);
    writeln("lane.d: [B] ", allB.length, " race report(s) total, ", nB,
            " naming ", kRaceSymbol, "; Matched block=", suppB.blockPresent,
            " total=", suppB.total, " ", suppB.byPattern);
    if (nB != 0)
        fail(format("run B ran with %s yet still reported %d race(s) naming "
                  ~ "%s — the suppression did not match. Matching is by symbol "
                  ~ "NAME, so this is what a dead symbolizer or a stray "
                  ~ "symbolize=0 looks like.", kTsanCanary, nB, kRaceSymbol));
    if (!suppB.blockPresent)
        fail("run B printed NO `Matched N suppressions` block. At zero matches "
           ~ "the runtime prints no block AT ALL, so this is the same answer "
           ~ "as `the suppression never matched` — and it also means the "
           ~ "audit parser has never been exercised");
    if (suppB.total < 1)
        fail("run B's Matched block totals " ~ suppB.total.to!string);
    ok(format("B: 0 races naming %s, and `Matched %d suppressions` printed",
              kRaceSymbol, suppB.total));
    ok("tsan-selfcheck: the instrument is armed and the suppression machinery "
     ~ "is alive");
}

// ---------------------------------------------------------------------------
// tsan-shutdown — the LIVE control, plus the A/B that measures whether the
// main-thread bridge's atomics order it away.
//
// RECORDED, NOT GATING, and that is a decision with a reason. The bridge's
// seq-cst submitted/completed are core.atomic TEMPLATES instantiated in our
// own modules, so LLVM's TSan pass lowers them to __tsan_atomic* and they
// establish happens-before in both directions. handleClient runs INLINE on the
// accept thread, so the very thread that wrote `isRunning = true` later does a
// release the main thread acquires. TSan's io_sync=1 (on by default) adds a
// second such edge over the socket. A gate on a signal that two independent
// orderings can erase is a flapping lane, and a flapping lane gets switched
// off rather than read.
//
//   arm A: boot, then SIGINT. SDL turns SIGINT into SDL_QUIT, which the
//          quit-guard drains — no bridge traffic at all.
//   arm B: boot, ONE GET /api/layers (a mainThread route, i.e. one full
//          bridge round trip), then SIGINT.
//
// Their predictions DIFFER, which is the point: if the bridge model is right,
// the isRunning pair can appear in A and must not in B. If it appears in both
// or in neither, the model is wrong and that is the finding.
// ---------------------------------------------------------------------------
void cmdTsanShutdown() {
    auto spec = specFor("tsan");
    foreach (arm; ["shutdownA", "shutdownB"]) {
        removeReports(arm);
        // BOTH arms boot bridge-free, so the only difference between them is
        // the one deliberate /api/layers call in B. Booting A the ordinary way
        // would have put a bridged round trip into it and destroyed the
        // contrast before the measurement started — the readiness probe would
        // have supplied exactly the happens-before edge whose absence arm A is
        // supposed to represent.
        auto ins = spawnInstance(spec, arm, null, null, ReadyMode.bridgeFree);
        if (arm == "shutdownB") {
            auto r = httpGet(ins.port, "/api/layers", 30);
            writeln("lane.d: [", arm, "] /api/layers connected=", r.connected,
                    " status=", r.status);
        }
        const clean = shutdownInstance(ins, /*viaSignal=*/true);
        writeln("lane.d: [", arm, "] clean exit via SIGINT: ", clean);
        if (!clean)
            writeln("lane.d: [", arm, "] NOTE: SIGINT did not terminate the "
                  ~ "instance, so HttpServer.stop() never ran and the live "
                  ~ "control could not occur. That is a measurement, not a "
                  ~ "failure of the lane.");
        auto reps = reportsFor(arm);
        writeln("lane.d: [", arm, "] ", reps.length, " race report(s):");
        foreach (x; reps) writeln("lane.d: [", arm, "]   ", x.signature);
    }
    ok("tsan-shutdown: both arms recorded (see the signatures above and "
     ~ "tsan_expected.txt)");
}

// ---------------------------------------------------------------------------
// tsan-sweep — the lane's subject: kRoutes UNION the connection path.
//
// NOT the test suite: ~400 tests exercise the SAME main-thread/HTTP-thread
// pair over and over and pay the TSan multiplier on every instance. And NOT
// the 27 `httpThread` rows either, which is what the first draft proposed:
// the route table says in its own comment that the `Answered` column is DATA,
// not an assertion — "a row that says mainThread is a claim by the author" —
// and a row mislabelled that way is precisely the defect a race detector
// exists to find. Excluding them bought nothing: a request costs one HTTP
// call.
//
// The connection path (handleClient, parseRequest, the accept loop, and the 41
// provider-delegate fields a provider closes over) has no row of its own and
// is covered by the sweep going over HTTP at all — phase 0 already produced a
// report inside parseRequest.
// ---------------------------------------------------------------------------
struct SweepRoute { string path; string method; string body_; }

// The literal table. It is DELIBERATELY a separate literal from kRoutes rather
// than derived from it: a table generated from the source could not detect a
// row that the source grew and the sweep did not, which is the entire content
// of the completeness check below.
enum SweepRoute[] kSweepRoutes = [
    SweepRoute("/", "GET", null),
    SweepRoute("/status", "GET", null),
    SweepRoute("/info", "GET", null),
    SweepRoute("/api/ping", "GET", null),
    SweepRoute("/api/version", "GET", null),
    SweepRoute("/api/model", "GET", null),
    SweepRoute("/api/selection", "GET", null),
    SweepRoute("/api/tool/handles", "GET", null),
    SweepRoute("/api/tool/state", "GET", null),
    SweepRoute("/api/toolprops/ids", "GET", null),
    SweepRoute("/api/buttons/availability", "GET", null),
    SweepRoute("/api/stats", "GET", null),
    SweepRoute("/api/layers", "GET", null),
    SweepRoute("/api/perf/reset", "POST", `{}`),
    SweepRoute("/api/perf", "GET", null),
    SweepRoute("/api/frames/counts/reset", "POST", `{}`),
    SweepRoute("/api/frames/counts", "GET", null),
    SweepRoute("/api/frames/reset", "POST", `{}`),
    SweepRoute("/api/frames", "GET", null),
    SweepRoute("/api/changes", "GET", null),
    SweepRoute("/api/toolpipe/eval", "GET", null),
    SweepRoute("/api/path", "GET", null),
    SweepRoute("/api/toolpipe", "GET", null),
    SweepRoute("/api/ai/analyze", "GET", null),
    SweepRoute("/api/registry", "GET", null),
    SweepRoute("/api/snap/last", "GET", null),
    SweepRoute("/api/snap", "POST", `{}`),
    SweepRoute("/api/constrain", "POST", `{}`),
    SweepRoute("/api/camera", "POST", `{}`),
    SweepRoute("/api/gpu/face-vbo", "GET", null),
    SweepRoute("/api/viewport/display", "GET", null),
    SweepRoute("/api/images", "GET", null),
    SweepRoute("/api/imageplane", "GET", null),
    SweepRoute("/api/viewport/probe", "GET", null),
    SweepRoute("/api/subpatch/preview",    "GET",  null),
    SweepRoute("/api/subpatch/hold",       "POST", `{}`),
    SweepRoute("/api/ui/policy",           "GET",  null),
    SweepRoute("/api/pick", "GET", null),
    SweepRoute("/api/surface-raycast", "GET", null),
    SweepRoute("/api/camera", "GET", null),
    SweepRoute("/api/recorded-events", "GET", null),
    SweepRoute("/api/play-events/status", "GET", null),
    SweepRoute("/api/test/layer", "POST", `{}`),
    SweepRoute("/api/command", "POST", `{}`),
    SweepRoute("/api/script", "POST", `{}`),
    SweepRoute("/api/redo", "POST", `{}`),
    SweepRoute("/api/refire", "POST", `{}`),
    SweepRoute("/api/history/block", "POST", `{}`),
    SweepRoute("/api/undo/status", "GET", null),
    SweepRoute("/api/history", "GET", null),
    SweepRoute("/api/trace", "GET", null),
    SweepRoute("/api/trace/reset", "POST", `{}`),
    SweepRoute("/api/history/jump", "POST", `{}`),
    SweepRoute("/api/history/replay", "POST", `{}`),
    SweepRoute("/api/play-events", "POST", `{}`),
];

/// The declared set, parsed out of the source. Compared with kSweepRoutes as a
/// SET and as a COUNT — by count too, because a new row that merely REPLACES
/// a removed one would keep the set sizes matching by accident.
string[] parseDeclaredRoutes(string src = "source/http_server.d") {
    auto text = readText(src);
    const anchor = "private enum RouteSpec[] kRoutes = [";
    const a = text.indexOf(anchor);
    if (a < 0) fail("could not find kRoutes in " ~ src);
    const b = text.indexOf("\n];", a);
    if (b < 0) fail("could not find the end of kRoutes in " ~ src);
    auto blk = text[a .. b];
    string[] keys;
    auto re = regex(`RouteSpec\("([^"]*)",\s*"([^"]*)",`);
    foreach (m; blk.lineSplitter) {
        auto hit = m.matchFirst(re);
        if (hit.empty) continue;
        keys ~= (hit[2].length ? hit[2] : "GET") ~ " " ~ hit[1];
    }
    return keys;
}

void checkSweepCompleteness() {
    auto declared = parseDeclaredRoutes();
    auto swept = kSweepRoutes.map!(r => r.method ~ " " ~ r.path).array;
    auto dset = declared.dup; dset.sort();
    auto sset = swept.dup;    sset.sort();
    auto missing = dset.filter!(k => !sset.canFind(k)).array;
    auto extra   = sset.filter!(k => !dset.canFind(k)).array;
    if (declared.length != swept.length || missing.length || extra.length)
        fail(format("the sweep does not cover kRoutes.\n"
                  ~ "  declared %d, swept %d\n"
                  ~ "  in kRoutes but not swept: %s\n"
                  ~ "  swept but not in kRoutes: %s\n"
                  ~ "A route the sweep never calls is a race surface nobody "
                  ~ "looks at, and the `Answered` column cannot tell you it is "
                  ~ "safe — the table says so itself.",
                    declared.length, swept.length, missing, extra));
    ok(format("sweep covers all %d kRoutes rows, by set AND by count",
              declared.length));
}

// --- the sweep's shared state (lane.d is uninstrumented; these are ours) ---
shared int  g_sweepAnswered;
shared int  g_sweepAttempted;
shared int  g_sweepMutations;
shared int  g_sweepRouteIdx;
shared bool g_sweepStop;
shared bool g_sweepRssBlown;
shared long g_sweepPeakRssKb;

long readVmRssKb(int pid) {
    if (pid <= 0) return -1;
    const p = format("/proc/%d/status", pid);
    if (!exists(p)) return -1;
    try {
        foreach (ln; readText(p).lineSplitter)
            if (ln.startsWith("VmRSS:")) {
                auto f = ln.split();
                if (f.length >= 2) return f[1].to!long;
            }
    } catch (Exception) {}
    return -1;
}

void cmdTsanSweep(string[] args) {
    // Cheapest first: the completeness test needs no instance.
    checkSweepCompleteness();

    const bt = args.length > 0 ? args[0] : "tsan";
    auto spec = specFor(bt);
    const rssCapMb = environment.get("VIBE3D_TSAN_RSS_CAP_MB", "8192").to!long;
    const csvPath  = bt == "tsan" ? "tsan-rss-sweep.csv"
                                  : "tsan-rss-sweep-" ~ bt ~ ".csv";

    const tag = bt == "tsan" ? "sweep" : "sweep-" ~ bt;
    const sentinel = bt == "tsan" ? "tsan-sweep.done" : "tsan-sweep-" ~ bt ~ ".done";
    removeReports(tag);
    if (exists(sentinel)) std.file.remove(sentinel);
    auto ins = spawnInstance(spec, tag);
    scope(failure) killInstance(ins);

    atomicStore(g_sweepStop, false);
    atomicStore(g_sweepRssBlown, false);
    atomicStore(g_sweepAnswered, 0);
    atomicStore(g_sweepAttempted, 0);
    atomicStore(g_sweepMutations, 0);
    atomicStore(g_sweepPeakRssKb, 0L);

    const editorPid = ins.editorPid;
    const port      = ins.port;
    const t0        = Clock.currTime(UTC());

    // --- the RSS watchdog -------------------------------------------------
    // Under gc:manual growth is MONOTONE for the process lifetime: the
    // collector body is empty, and worse, gc_expandArrayUsed returns false
    // ALWAYS, so every `arr ~= x` reallocates and abandons the old block —
    // an append loop of length n costs O(n^2) bytes. Running out of memory
    // here ends in onOutOfMemoryError or the kernel OOM killer, and in BOTH
    // cases the report file exists, contains no new signature, and is
    // indistinguishable by grep from a clean run. So the stop is NAMED.
    auto watchdog = new Thread({
        auto csv = File(csvPath, "w");
        csv.writeln("elapsed_s,vm_rss_kb,route_idx");
        while (!atomicLoad(g_sweepStop)) {
            const rss = readVmRssKb(editorPid);
            const el  = (Clock.currTime(UTC()) - t0).total!"seconds";
            if (rss > 0) {
                csv.writefln("%d,%d,%d", el, rss, atomicLoad(g_sweepRouteIdx));
                csv.flush();
                if (rss > atomicLoad(g_sweepPeakRssKb))
                    atomicStore(g_sweepPeakRssKb, rss);
                if (rss / 1024 > rssCapMb) {
                    atomicStore(g_sweepRssBlown, true);
                    atomicStore(g_sweepStop, true);
                }
            }
            foreach (_; 0 .. 10) {
                if (atomicLoad(g_sweepStop)) break;
                Thread.sleep(1.seconds);
            }
        }
    });
    watchdog.start();

    // --- the document mutator, on the MAIN thread ------------------------
    // These three splices of document.layers are the ones the source names in
    // its own deferred-race comment above route_apiSelection. The sweep's
    // whole point is that they run WHILE the routes are being read.
    auto mutator = new Thread({
        static immutable string[] cmds = [
            `{"id":"layer.add","params":{}}`,
            `{"id":"layer.reorder","params":{}}`,
            `{"id":"layer.delete","params":{}}`,
        ];
        size_t i;
        while (!atomicLoad(g_sweepStop)) {
            httpPost(port, "/api/command", cmds[i++ % cmds.length], 30);
            atomicOp!"+="(g_sweepMutations, 1);
            Thread.sleep(25.msecs);
        }
    });
    mutator.start();

    // --- the route walk, N callers in parallel ---------------------------
    // Passes: one is enough for coverage, and coverage is what the sentinel
    // counts. More than one exists for the MEMORY measurement — under
    // gc:manual growth is monotone for the process lifetime, so the slope in
    // MB/minute can only be read off a run long enough to have a slope. Only
    // the FIRST pass counts toward attempted/answered; a repeat must not be
    // able to inflate the completion invariant.
    enum int kSweepCallers = 4;
    const passes = environment.get("VIBE3D_TSAN_SWEEP_PASSES", "1").to!int;
    auto routes = kSweepRoutes.dup;
    foreach (pass; 0 .. passes) {
        if (atomicLoad(g_sweepStop)) break;
        if (pass > 0) writeln("lane.d: sweep pass ", pass + 1, " of ", passes);
        foreach (idx, r; routes) {
            if (atomicLoad(g_sweepStop)) break;
            atomicStore(g_sweepRouteIdx, cast(int) idx);
            if (pass == 0) atomicOp!"+="(g_sweepAttempted, 1);
            shared int localAnswered = 0;
            Thread[] callers;
            foreach (c; 0 .. kSweepCallers) {
                auto rr = r;
                callers ~= new Thread({
                    // 30 s, not 60: the worst case is every route x this, and
                    // a route that needs longer than 30 s under TSan is a
                    // finding to record, not a budget to widen.
                    auto rep = httpRequest(port, rr.method, rr.path, rr.body_, 30);
                    if (rep.connected && rep.status > 0)
                        atomicOp!"+="(localAnswered, 1);
                });
            }
            foreach (t; callers) t.start();
            foreach (t; callers) t.join();
            // "Answered" = a connection AND a status line. A 4xx on a route
            // that wants a body is an ANSWER; only silence is a failure.
            if (pass == 0) {
                if (atomicLoad(localAnswered) > 0) atomicOp!"+="(g_sweepAnswered, 1);
                else writeln("lane.d: sweep: NO ANSWER from ", r.method, " ", r.path);
            }
        }
    }

    const stoppedByRss = atomicLoad(g_sweepRssBlown);
    const routeAtStop  = atomicLoad(g_sweepRouteIdx);

    // --- the parallel() surface (Ф3.5) ------------------------------------
    // mesh.d takes the std.parallelism path only at >= 4096 faces
    // (PARALLEL_BUILD_MIN), so the mesh has to be grown before the range can
    // even be split. A cube is 6 faces; five subdivisions is 6144.
    int subdivOk = 0;
    string loopReply;
    if (!stoppedByRss) {
        httpPost(port, "/api/command", `{"id":"scene.reset"}`, 60);
        // Five, because mesh.d takes the std.parallelism path only at >= 4096
        // faces (PARALLEL_BUILD_MIN) and a cube reaches 6144 exactly at the
        // fifth subdivision — four would leave 1536 and the parallel branch
        // would never be entered, which is the one thing this phase is for.
        // 240 s each, not 600: under gc:manual every `arr ~= x` reallocates,
        // so this is the most memory-hungry thing the lane does, and a
        // subdivision that needs longer than 240 s is a finding to record
        // rather than a budget to widen.
        foreach (i; 0 .. 5) {
            auto sr = httpPost(port, "/api/command",
                               `{"id":"mesh.subdivide","params":{}}`, 240);
            if (sr.connected && sr.body_.canFind("\"ok\"")) ++subdivOk;
            else { writeln("lane.d: subdivide ", i, " -> ", sr.status, " ",
                           sr.body_.length > 160 ? sr.body_[0 .. 160] : sr.body_); break; }
        }
        auto lr = httpPost(port, "/api/command",
                           `{"id":"select.loop","params":{}}`, 240);
        loopReply = lr.body_.length > 160 ? lr.body_[0 .. 160] : lr.body_;
        writeln("lane.d: select.loop after ", subdivOk, " subdivisions -> ", loopReply);
    }

    atomicStore(g_sweepStop, true);
    mutator.join();
    watchdog.join();

    // --- the completion invariant ----------------------------------------
    // Under gc:manual an allocation failure ends in onOutOfMemoryError
    // (noreturn) or the OOM killer, and TSan can die on an internal CHECK. In
    // every one of those cases the report file EXISTS and holds no new
    // signature, so a grep-based verdict cannot tell a corpse from a clean
    // night. The sentinel is what tells them apart, and tsan-verdict REQUIRES
    // it. Note what cannot be used here: the allocation counters. Under
    // gc:manual GC.allocatedInCurrentThread() is identically 0, so
    // /api/frames/counts reports allocBytes = gcAllocBytes = 0 no matter how
    // much work ran. The evidence of work is the frame counter and the number
    // of routes that answered.
    auto counts = httpGet(port, "/api/frames/counts", 30);
    long framesSeq = -1;
    try {
        auto j = parseJSON(counts.body_);
        if ("totals" in j && "seq" in j["totals"]) framesSeq = j["totals"]["seq"].integer;
    } catch (Exception) {}
    auto ping = httpGet(port, "/api/ping", 15);

    JSONValue done;
    done["attempted"]        = atomicLoad(g_sweepAttempted);
    done["declared"]         = cast(int) kSweepRoutes.length;
    done["answered"]         = atomicLoad(g_sweepAnswered);
    done["mutations"]        = atomicLoad(g_sweepMutations);
    done["callersPerRoute"]  = kSweepCallers;
    done["passes"]           = passes;
    done["pingConnected"]    = ping.connected;
    done["pingStatus"]       = ping.status;
    done["framesSeq"]        = framesSeq;
    done["peakRssKb"]        = atomicLoad(g_sweepPeakRssKb);
    done["rssCapMb"]         = rssCapMb;
    done["stoppedByRss"]     = stoppedByRss;
    done["stoppedAtRoute"]   = routeAtStop;
    done["subdivisions"]     = subdivOk;
    done["elapsedSec"]       = (Clock.currTime(UTC()) - t0).total!"seconds";
    std.file.write(sentinel, done.toPrettyString());
    writeln("lane.d: sentinel ", sentinel, ":\n", done.toPrettyString());

    shutdownInstance(ins, /*viaSignal=*/false);

    auto reps = reportsFor(tag);
    writeln("lane.d: sweep produced ", reps.length, " race report(s):");
    string[int] tally;
    int[string] byS;
    foreach (x; reps) byS[x.signature] = byS.get(x.signature, 0) + 1;
    foreach (k, v; byS) writeln("lane.d:   ", v, "x ", k);

    if (stoppedByRss)
        fail(format("sweep STOPPED BY RSS at route %d of %d (%s %s): peak "
                  ~ "%d MB over the %d MB cap. This is a NAMED stop, not an "
                  ~ "OOM kill — an OOM kill leaves a report file that greps "
                  ~ "identically to a clean run.",
                    routeAtStop, kSweepRoutes.length,
                    kSweepRoutes[routeAtStop].method,
                    kSweepRoutes[routeAtStop].path,
                    atomicLoad(g_sweepPeakRssKb) / 1024, rssCapMb));
    ok(format("sweep: %d/%d routes attempted, %d answered, %d mutations, "
            ~ "peak RSS %d MB",
              atomicLoad(g_sweepAttempted), kSweepRoutes.length,
              atomicLoad(g_sweepAnswered), atomicLoad(g_sweepMutations),
              atomicLoad(g_sweepPeakRssKb) / 1024));
}

// ---------------------------------------------------------------------------
// tsan-bridge — the race the first draft of this plan did not look at.
//
// MainThreadBridge.submitAndWait bumps the submitted epoch and then may TIME
// OUT; on timeout it returns false and the CALLER writes into the bridge's
// `resp` from the HTTP THREAD (route_apiLayers does exactly this). The main
// thread drains the same bridge later and writes the same `resp` inside
// service(req, resp). Both fields are ordinary, non-shared, non-atomic.
//
// The default budget is 2500 iters x 2 ms = 5 s. Making the main thread busy
// for longer than that is the whole driver: the command bridge has its own,
// far longer leash (60 000 iters), so a slow command occupies the main thread
// while the layers bridge times out underneath it.
// ---------------------------------------------------------------------------
void cmdTsanBridge() {
    auto spec = specFor("tsan");
    removeReports("bridge");
    auto ins = spawnInstance(spec, "bridge");
    scope(failure) killInstance(ins);
    const port = ins.port;

    shared bool busyDone = false;
    auto busy = new Thread({
        auto r = httpPost(port, "/api/command",
                          `{"id":"selftest.fault","params":{"kind":"slow"}}`, 600);
        writeln("lane.d: bridge: slow command -> ", r.status, " ",
                r.body_.length > 120 ? r.body_[0 .. 120] : r.body_);
        atomicStore(busyDone, true);
    });
    busy.start();
    Thread.sleep(1.seconds);   // let the main thread actually enter the command

    int timeouts, calls;
    while (!atomicLoad(busyDone) && calls < 40) {
        auto r = httpGet(port, "/api/layers", 60);
        ++calls;
        if (r.body_.canFind("timeout waiting for main thread")) ++timeouts;
    }
    busy.join();
    writeln("lane.d: bridge: ", calls, " /api/layers calls, ", timeouts,
            " of them timed out (a timeout is the precondition for the race, "
          ~ "not the race itself)");

    shutdownInstance(ins, /*viaSignal=*/false);
    auto reps = reportsFor("bridge");
    writeln("lane.d: bridge produced ", reps.length, " race report(s):");
    foreach (x; reps) writeln("lane.d:   ", x.signature);
    if (timeouts == 0)
        writeln("lane.d: NOTE: no /api/layers call timed out, so the driver "
              ~ "never created the precondition. The absence of a bridge race "
              ~ "here says nothing.");
    ok("tsan-bridge: recorded");
}

// ---------------------------------------------------------------------------
// tsan-verdict — THE ONLY GATE ON FINDINGS.
// ---------------------------------------------------------------------------
void cmdTsanVerdict(string[] scenarios) {
    if (scenarios.length == 0)
        fail("tsan-verdict needs the scenarios that RAN, e.g. "
           ~ "`tsan-verdict selfcheck sweep shutdown bridge`. Without them it "
           ~ "cannot tell a required signature that did not fire from one "
           ~ "whose scenario was never run.");
    auto expected = loadExpected();
    string[] red;
    string[] notes;

    bool[string] firedKey;      // "scenario|signature"
    foreach (scen; scenarios) {
        auto files = reportFilesFor(scen);
        auto reps  = reportsFor(scen);
        writeln("lane.d: scenario ", scen, ": ", files.length,
                " report file(s), ", reps.length, " race report(s)");
        int[string] tally;
        foreach (r; reps) tally[r.signature] = tally.get(r.signature, 0) + 1;
        foreach (sig, n; tally) {
            firedKey[scen ~ "|" ~ sig] = true;
            const declared = expected.any!(e => e.scenarios.canFind(scen)
                                              && e.signature == sig);
            writeln(format("lane.d:   %-9s %4dx  %s", declared ? "declared" : "NEW", n, sig));
            if (!declared)
                red ~= format("NEW RACE in scenario `%s` (%dx): %s\n"
                            ~ "        first frames: %s",
                              scen, n, sig,
                              reps.find!(r => r.signature == sig).front.frames);
        }
        if (files.length == 0
            && expected.any!(e => e.scenarios.canFind(scen)
                               && e.klass == "required"))
            red ~= format("scenario `%s` ran and declares a `required` "
                        ~ "signature, but NO REPORT FILE EXISTS AT ALL. Either "
                        ~ "the instance never started, or log_path never "
                        ~ "reached it.", scen);
    }

    // Per (row, scenario) PAIR, not per row: a row now names every scenario it
    // is expected in, so "declared for four, fired in three" has to name the
    // fourth. Collapsing this to one check per row would hide exactly that.
    foreach (e; expected) {
        foreach (es; e.scenarios) {
            if (!scenarios.canFind(es)) continue;
            if ((es ~ "|" ~ e.signature) in firedKey) continue;
            if (e.klass == "required")
                red ~= format("REQUIRED signature declared for scenario `%s` did "
                            ~ "NOT fire: %s\n"
                            ~ "        (task %s, %s: %s)\n"
                            ~ "        Either it was fixed — delete the row — or "
                            ~ "the instrument went blind. Those two look "
                            ~ "identical from here, which is why this is red.",
                              es, e.signature, e.task, e.date, e.reason);
            else
                notes ~= format("tolerated signature did not fire in `%s`: %s",
                                es, e.signature);
        }
    }

    if (scenarios.canFind("sweep")) {
        if (!exists("tsan-sweep.done"))
            red ~= "THE SWEEP DID NOT FINISH: no tsan-sweep.done. A sweep "
                 ~ "killed a few routes in leaves a report file that greps "
                 ~ "exactly like a clean night; this sentinel is the only "
                 ~ "thing that separates them.";
        else {
            auto j = parseJSON(readText("tsan-sweep.done"));
            const att = j["attempted"].integer, ans = j["answered"].integer,
                  dec = j["declared"].integer;
            if (att != dec || ans != dec)
                red ~= format("THE SWEEP DID NOT FINISH: attempted %d, "
                            ~ "answered %d, of %d declared routes.",
                              att, ans, dec);
            else
                notes ~= format("sweep sentinel: %d/%d routes answered, %d "
                              ~ "mutations, peak RSS %d MB, %d s",
                                ans, dec, j["mutations"].integer,
                                j["peakRssKb"].integer / 1024,
                                j["elapsedSec"].integer);
        }
    }

    writeln();
    foreach (n; notes) writeln("lane.d: note: ", n);
    if (red.length) {
        stderr.writeln();
        foreach (r; red) stderr.writeln("lane.d: FAIL: ", r);
        stderr.writeln("lane.d: FAIL: tsan-verdict RED — ", red.length,
                       " divergence(s) from ", kTsanExpected);
        import core.stdc.stdlib : exit;
        exit(1);
    }
    ok(format("tsan-verdict GREEN over scenarios %s: every report matches a "
            ~ "declared signature, and every `required` signature fired",
              scenarios));
}

// ---------------------------------------------------------------------------
// tsan-audit-suppressions — a suppression that stopped matching is either
// fixed upstream or dead weight, and either way it must not sit there
// implying it is still load-bearing.
// ---------------------------------------------------------------------------
void cmdTsanAuditSuppressions(string[] scenarios) {
    auto rules = loadSuppressionRules(kTsanSupp);
    if (rules.length == 0) {
        writeln("lane.d: NOTE: ", kTsanSupp, " is EMPTY, so this audit is "
              ~ "VACUOUS — it is reporting on nothing and cannot fail. That "
              ~ "is deliberate: the only candidate (the stop-the-world signal "
              ~ "handler) is unreachable under gc:manual, and adding a "
              ~ "suppression to make a check non-vacuous is exactly the "
              ~ "defect this campaign exists to find. The witness for the "
              ~ "machinery is tsan-selfcheck's canary arm.");
        ok("nothing to audit");
        return;
    }
    string[] files;
    foreach (s; scenarios) files ~= reportFilesFor(s);
    auto m = parseSuppressionBlock(files);
    if (!m.blockPresent)
        fail(format("%s declares %d rule(s) but no `Matched N suppressions` "
                  ~ "block was printed at all. At ZERO matches the runtime "
                  ~ "prints no block — so this is not `zero matches`, it is "
                  ~ "indistinguishable from a run in which suppressions never "
                  ~ "loaded (a stray symbolize=0 does exactly that).",
                    kTsanSupp, rules.length));
    foreach (r; rules) {
        const pat = r[r.indexOf(':') + 1 .. $];
        int hits;
        foreach (k, v; m.byPattern) if (k.canFind(pat)) hits += v;
        if (hits == 0)
            fail(format("suppression `%s` matched 0 times tonight — it is "
                      ~ "EXPIRED. Delete it, or prove it is still needed.", r));
        ok(format("suppression `%s` matched %d time(s)", r, hits));
    }
}

// ---------------------------------------------------------------------------
// rss-sample — the memory measurement the lane's budget rests on, usable
// against any running instance.
// ---------------------------------------------------------------------------
void cmdRssSample(string[] args) {
    if (args.length < 2) fail("rss-sample <pid> <seconds> [csv]");
    const pid  = args[0].to!int;
    const secs = args[1].to!int;
    const csvP = args.length > 2 ? args[2] : "tsan-rss.csv";
    auto csv = File(csvP, "w");
    csv.writeln("elapsed_s,vm_rss_kb");
    foreach (i; 0 .. secs / 10 + 1) {
        const rss = readVmRssKb(pid);
        if (rss < 0) break;
        csv.writefln("%d,%d", i * 10, rss);
        csv.flush();
        Thread.sleep(10.seconds);
    }
    ok("wrote " ~ csvP);
}

int main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: rdmd tools/sanitizer/lane.d <cmd> [args]\n"
                     ~ "  1410: preflight | preflight-release | build | stage |\n"
                     ~ "        verify | boot | restore-dmd-archives | teardown |\n"
                     ~ "        fuzzer-path\n"
                     ~ "  2080: check-space <path> [floor-mib]\n"
                     ~ "  1411: preflight-tsan | window-guard <event> [force] |\n"
                     ~ "        tsan-selfcheck | tsan-shutdown | tsan-sweep |\n"
                     ~ "        tsan-bridge | tsan-verdict <scenario...> |\n"
                     ~ "        tsan-audit-suppressions <scenario...> |\n"
                     ~ "        rss-sample <pid> <seconds> [csv]");
        return 2;
    }
    switch (args[1]) {
        case "fuzzer-path":
            {
                auto f = resolveFuzzer();
                if (f is null) { stderr.writeln("lane: no fuzzer found under " ~ kSuiteGlob); return 1; }
                writeln(f);
            }                                                        break;
        case "preflight":         cmdPreflight(args[2 .. $]);        break;
        case "check-space":       cmdCheckSpace(args[2 .. $]);       break;
        case "preflight-release": cmdPreflightRelease();             break;
        case "build":             cmdBuild(args[2]);                 break;
        case "stage":             cmdStage(args[2]);                 break;
        case "boot":              cmdBoot(args[2]);                  break;
        case "restore-dmd-archives": cmdRestoreDmdArchives();        break;
        case "teardown":          cmdTeardown();                     break;
        // ---- the ThreadSanitizer lane (task 1411) ----
        case "preflight-tsan":    cmdPreflightTsan();                break;
        case "window-guard":      cmdWindowGuard(args[2 .. $]);      break;
        case "tsan-selfcheck":    cmdTsanSelfcheck();                break;
        case "tsan-shutdown":     cmdTsanShutdown();                 break;
        case "tsan-sweep":        cmdTsanSweep(args[2 .. $]);        break;
        case "tsan-bridge":       cmdTsanBridge();                   break;
        case "tsan-verdict":      cmdTsanVerdict(args[2 .. $]);      break;
        case "tsan-audit-suppressions":
                                  cmdTsanAuditSuppressions(args[2 .. $]); break;
        case "rss-sample":        cmdRssSample(args[2 .. $]);        break;
        case "verify":
            // `verify <buildType> <path>...` — name the buildType whose
            // promises each path must keep. The nightly passes ./vibe3d AND
            // vibe3d-test-tests, because both are executed.
            if (args.length < 4) fail("verify needs <buildType> <path>...");
            foreach (p; args[3 .. $]) verifyOne(p, specFor(args[2]));
            break;
        default:
            fail("unknown subcommand '" ~ args[1] ~ "'");
    }
    return 0;
}
