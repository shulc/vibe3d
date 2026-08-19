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
struct BuildTypeSpec { string name; bool hasAsan, hasCheckAction, hasSelfTest; }
enum BuildTypeSpec[] kSpecs = [
    BuildTypeSpec("check",         false, true,  true),
    BuildTypeSpec("check-unit",    false, false, true),
    BuildTypeSpec("check-release", false, false, true),
    BuildTypeSpec("sanitize",      true,  true,  true),
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

void cmdPreflight() {
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
    auto fuzzer = resolveFuzzer();
    if (fuzzer is null)
        fail("no " ~ kFuzzerLeaf ~ " under any " ~ kSuiteGlob ~ " — the "
           ~ "tools/local symlink into the private repo is missing or dead; "
           ~ "the fuzzing step would be a silent no-op");
    ok("private fuzzer readable: " ~ fuzzer);

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
            if (v.str == "SanitizerSelfTest")
                fail("release declares version SanitizerSelfTest");
    }
    if (!sawRoot)
        fail("dub describe named no vibe3d target — the check inspected "
           ~ "nothing and would have passed on anything");
    ok("release buildSettings carry no --fsanitize / --checkaction / "
     ~ "SanitizerSelfTest (read structurally, with --compiler set)");
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
    ok(format("%s carries exactly the instrumentation %s promises "
            ~ "(asan=%s checkaction=%s selftest=%s)",
              path, spec.name, hasAsan, hasCA, hasST));
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
    enum archive = "third_party/nfde/bin/libnfde.a";
    if (exists(archive)) {
        auto nm = execute(["nm", archive]);
        if (nm.output.canFind("__asan"))
            fail(archive ~ " still carries __asan_* symbols after a dmd build "
               ~ "— run_test.d's source-backed tests will fail to LINK, and "
               ~ "the failure reads as `worker N failed to prepare`");
        ok(archive ~ " is dmd-built again (no __asan_* symbols)");
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
    const bin = "./vibe3d-" ~ bt;
    if (!exists(bin)) fail("no " ~ bin);
    const port = environment.get("VIBE3D_SAN_PORT", "8599");
    auto logPath = "sanitizer-boot-" ~ bt ~ ".log";
    auto logFile = File(logPath, "w");
    auto pid = spawnProcess(
        ["env", "-u", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER=x11",
         "xvfb-run", "-a", bin, "--test", "--http-port", port],
        stdin, logFile, logFile);
    void reap() { try { kill(pid); wait(pid); } catch (Exception) {} }
    scope(exit) reap();

    string body_;
    bool up = false;
    foreach (i; 0 .. 90) {
        auto r = execute(["curl", "-s", "-m", "2",
                          "http://localhost:" ~ port ~ "/api/registry"]);
        if (r.status == 0 && r.output.canFind("\"commands\"")) {
            body_ = r.output; up = true; break;
        }
        Thread.sleep(1.seconds);
    }
    if (!up)
        fail(bin ~ " did not answer /api/registry within 90 s — read "
           ~ logPath ~ "; a registry name() mismatch aborts startup and makes "
           ~ "every HTTP test fail at once");
    if (!body_.canFind("selftest.fault"))
        fail(bin ~ " booted but `selftest.fault` is not registered — the "
           ~ "SanitizerSelfTest version did not reach registration.d, and "
           ~ "every mutation in the table below would silently pass");
    ok(bin ~ " boots clean and registers selftest.fault");
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

int main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: rdmd tools/sanitizer/lane.d "
                     ~ "<preflight|preflight-release|build|stage|verify|boot|teardown> [args]");
        return 2;
    }
    switch (args[1]) {
        case "fuzzer-path":
            {
                auto f = resolveFuzzer();
                if (f is null) { stderr.writeln("lane: no fuzzer found under " ~ kSuiteGlob); return 1; }
                writeln(f);
            }                                                        break;
        case "preflight":         cmdPreflight();                    break;
        case "preflight-release": cmdPreflightRelease();             break;
        case "build":             cmdBuild(args[2]);                 break;
        case "stage":             cmdStage(args[2]);                 break;
        case "boot":              cmdBoot(args[2]);                  break;
        case "restore-dmd-archives": cmdRestoreDmdArchives();        break;
        case "teardown":          cmdTeardown();                     break;
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
