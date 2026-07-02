module lib.baseline;
// Baseline/header shapes shared by the `ops` and `frames` subcommands: the
// RunHeader build/mesh/viewport/host fingerprint used for the build-mismatch
// guard, the ops baseline.json reader/writer, the frames_baseline.json
// reader/writer, and the relative/absolute regression-threshold constants.
//
// The invariant CHECKERS (checkInvariants/checkFramesInvariants/
// checkAbsolute/checkFramesAbsolute) and the case tables stay in run.d —
// they are the harness's policy, not shared plumbing (see Phase 2 note in
// doc/perf_tooling_consolidation_plan.md). This module owns only the
// data shapes + thresholds those checkers read.
//
// Extracted from tools/perf/run.d as part of task 0197 (perf tooling
// consolidation) — pure code-motion, no behavior change.

import std.array   : appender;
static import std.file;
import std.format  : format;
import std.json    : parseJSON, JSONType;
import std.socket  : Socket;

import lib.stats : jsonNum;

// ---------------------------------------------------------------------------
// Header — shared by both baseline.json and frames_baseline.json. The
// build-mismatch guard (headerMismatch) refuses an absolute comparison when
// any of these fields differ from the run that captured the baseline.
// ---------------------------------------------------------------------------

struct RunHeader {
    string buildType, compiler, host, meshType, viewport;
    int    n;
    long   faceCount;
    int    repeats;
}

RunHeader currentHeader(string meshType, int n, long faceCount,
                        string viewport, int repeats) {
    return RunHeader("perf", "ldc2 1.42.0", Socket.hostName, meshType, viewport,
                     n, faceCount, repeats);
}

// The build-mismatch guard. Absolute comparison is only meaningful when the
// baseline was captured on the SAME build + mesh + viewport. Returns a
// non-empty reason string if the configs differ (⇒ skip absolute).
string headerMismatch(RunHeader baseH, RunHeader curH) {
    if (baseH.buildType != curH.buildType)
        return format("buildType %s vs %s", baseH.buildType, curH.buildType);
    if (baseH.compiler != curH.compiler)
        return format("compiler %s vs %s", baseH.compiler, curH.compiler);
    // Host is only compared when the baseline actually recorded one — a
    // legacy host-less baseline (empty) still compares on the other fields.
    // Absolute timings are hardware-bound, so a different host with the same
    // toolchain would false-flag; this guard makes it auto-skip instead.
    if (baseH.host.length && baseH.host != curH.host)
        return format("host %s vs %s", baseH.host, curH.host);
    if (baseH.meshType != curH.meshType)
        return format("meshType %s vs %s", baseH.meshType, curH.meshType);
    if (baseH.n != curH.n)
        return format("n %d vs %d", baseH.n, curH.n);
    if (baseH.viewport != curH.viewport)
        return format("viewport %s vs %s", baseH.viewport, curH.viewport);
    return "";
}

// ---------------------------------------------------------------------------
// Ops matrix absolute baseline (tools/perf/baseline.json). writeBaselineJson/
// loadBaseline are generic over `CaseResult`-shaped inputs via a lightweight
// row struct (BaselineCase) so this module has no dependency on run.d's
// CaseResult/CaseStatus — the caller (run.d) maps its own results into
// BaselineCase rows before writing.
// ---------------------------------------------------------------------------

// One per-case row stored in baseline.json.
struct BaselineCase {
    string name;
    double kernelMedianUs, kernelP95Us, pipeMedianUs;
    string dominantStage;
    long   vertsTouched;
}

void writeBaselineJson(string path, RunHeader h, BaselineCase[] rows) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "%s",` ~ "\n", h.buildType));
    a.put(format(`  "compiler": "%s",` ~ "\n", h.compiler));
    a.put(format(`  "host": "%s",` ~ "\n", h.host));
    a.put(format(`  "meshType": "%s",` ~ "\n", h.meshType));
    a.put(format(`  "n": %d,` ~ "\n", h.n));
    a.put(format(`  "faceCount": %d,` ~ "\n", h.faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", h.viewport));
    a.put(format(`  "repeats": %d,` ~ "\n", h.repeats));
    a.put(`  "cases": [` ~ "\n");
    bool first = true;
    foreach (r; rows) {
        if (!first) a.put(",\n");
        first = false;
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "kernelMedianUs": %s,` ~ "\n", jsonNum(r.kernelMedianUs)));
        a.put(format(`      "kernelP95Us": %s,` ~ "\n", jsonNum(r.kernelP95Us)));
        a.put(format(`      "pipeMedianUs": %s,` ~ "\n", jsonNum(r.pipeMedianUs)));
        a.put(format(`      "dominantStage": "%s",` ~ "\n", r.dominantStage));
        a.put(format(`      "vertsTouched": %d` ~ "\n", r.vertsTouched));
        a.put("    }");
    }
    a.put("\n  ]\n}\n");
    std.file.write(path, a.data);
}

struct Baseline {
    RunHeader header;
    BaselineCase[string] byName;   // keyed by case name
}

Baseline loadBaseline(string path) {
    Baseline b;
    auto j = parseJSON(cast(string)std.file.read(path));
    b.header.buildType = j["buildType"].str;
    b.header.compiler  = j["compiler"].str;
    // host may be absent in a legacy (pre-host) baseline ⇒ empty string,
    // which headerMismatch treats as "no host recorded" and does not compare.
    b.header.host      = ("host" in j) ? j["host"].str : "";
    b.header.meshType  = j["meshType"].str;
    b.header.viewport  = j["viewport"].str;
    b.header.n         = cast(int)j["n"].integer;
    b.header.faceCount = j["faceCount"].integer;
    b.header.repeats   = cast(int)j["repeats"].integer;
    foreach (cv; j["cases"].array) {
        BaselineCase bc;
        bc.name           = cv["name"].str;
        bc.kernelMedianUs = cv["kernelMedianUs"].floating;
        bc.kernelP95Us    = cv["kernelP95Us"].floating;
        // `null` = NaN round-trip (command cases have no pipe stages).
        bc.pipeMedianUs   = (cv["pipeMedianUs"].type == JSONType.null_)
                            ? double.nan : cv["pipeMedianUs"].floating;
        bc.dominantStage  = cv["dominantStage"].str;
        bc.vertsTouched   = cv["vertsTouched"].integer;
        b.byName[bc.name] = bc;
    }
    return b;
}

// ---------------------------------------------------------------------------
// `frames` absolute p99/hitch baseline (tools/perf/frames_baseline.json) —
// same RunHeader shape, separate file so it never collides with the ops
// baseline.
// ---------------------------------------------------------------------------

struct FramesBaselineCase {
    string name;
    long   p99Ns;
    long   hitch16;
    long   hitch33;
}

void writeFramesBaselineJson(string path, RunHeader h, FramesBaselineCase[] rows) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "%s",` ~ "\n", h.buildType));
    a.put(format(`  "compiler": "%s",` ~ "\n", h.compiler));
    a.put(format(`  "host": "%s",` ~ "\n", h.host));
    a.put(format(`  "meshType": "%s",` ~ "\n", h.meshType));
    a.put(format(`  "n": %d,` ~ "\n", h.n));
    a.put(format(`  "faceCount": %d,` ~ "\n", h.faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", h.viewport));
    a.put(`  "scenarios": [` ~ "\n");
    bool first = true;
    foreach (r; rows) {
        if (!first) a.put(",\n");
        first = false;
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "p99Ns": %d,` ~ "\n", r.p99Ns));
        a.put(format(`      "hitch16": %d,` ~ "\n", r.hitch16));
        a.put(format(`      "hitch33": %d` ~ "\n", r.hitch33));
        a.put("    }");
    }
    a.put("\n  ]\n}\n");
    std.file.write(path, a.data);
}

struct FramesBaseline {
    RunHeader header;
    FramesBaselineCase[string] byName;
}

FramesBaseline loadFramesBaseline(string path) {
    FramesBaseline b;
    auto j = parseJSON(cast(string)std.file.read(path));
    b.header.buildType = j["buildType"].str;
    b.header.compiler  = j["compiler"].str;
    b.header.host      = ("host" in j) ? j["host"].str : "";
    b.header.meshType  = j["meshType"].str;
    b.header.viewport  = j["viewport"].str;
    b.header.n         = cast(int)j["n"].integer;
    b.header.faceCount = j["faceCount"].integer;
    foreach (sv; j["scenarios"].array) {
        FramesBaselineCase bc;
        bc.name    = sv["name"].str;
        bc.p99Ns   = sv["p99Ns"].integer;
        bc.hitch16 = sv["hitch16"].integer;
        bc.hitch33 = sv["hitch33"].integer;
        b.byName[bc.name] = bc;
    }
    return b;
}

// ---------------------------------------------------------------------------
// Relative-invariant + absolute-regression thresholds (checkers stay in
// run.d; this module owns the tuned constant values).
// ---------------------------------------------------------------------------

// Tuned from observed n=64 ratios with generous margin (gross-regression
// guards, not tight benchmarks). Observed (worst tool) ⇒ chosen K:
//   I1 falloff radial / baseline kernelApply:  ~1.95×   ⇒ K1 = 6.0
//   I2 pipeSymmetry sum when symmetry OFF:     ≤ ~7.5µs ⇒ K2 = 200µs (abs)
//   I3 symmetry=X / baseline kernelApply:      ~1.86×   ⇒ K3 = 4.0
//   I4 baseline pipeTotal / kernelApply:       ~1.19×   ⇒ K4 = 4.0
enum double K1_FALLOFF        = 6.0;
enum double K2_SYM_OFF_US     = 200.0;   // absolute µs ceiling, per case
enum double K3_SYMMETRY       = 4.0;
enum double K4_PIPE_OVERHEAD  = 4.0;

// Below this baseline median (µs), a metric is in the timing noise floor and a
// percentage-growth comparison is meaningless (e.g. selection=single touches
// ~20 verts ⇒ kernelApply 0.1µs, where +0.2µs reads as +200%). Real
// regressions land on the heavy cases (kernelApply ~550µs+), far above this.
enum double ABS_NOISE_FLOOR_US = 50.0;

// Absolute p99/hitch budgets for `frames` (task 0195 Phase 6) — generous
// FIXED ceilings (not baseline-relative growth, unlike the ops lane).
enum double K_FRAMES_P99_MS = 33.0;   // generous per-scenario p99 ceiling
enum long   K_FRAMES_HITCH33 = 2;     // generous >33ms-hitch allowance
