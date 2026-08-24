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
//   I2 pipeSymmetry sum when symmetry OFF:     ≤ ~7.5µs ⇒ K2 = 200µs (abs)
//   I3 symmetry=X / baseline kernelApply:      ~1.86×   ⇒ K3 = 4.0
//   I4 baseline pipeTotal / kernelApply:       ~1.19×   ⇒ K4 = 4.0
enum double K2_SYM_OFF_US     = 200.0;   // absolute µs ceiling, per case
enum double K3_SYMMETRY       = 4.0;
enum double K4_PIPE_OVERHEAD  = 4.0;

// --- I1: the falloff loop, in two clauses (task 1840) ----------------------
//
// WHAT REPLACED WHAT, because the old form failed in a way worth keeping on
// the record. I1 used to read `falloff=radial kernelApply ≤ 6.0 × baseline
// kernelApply`, per tool. On 2026-08-24 it went red at 6.72-6.85× — and the
// falloff arm had not moved. Its DENOMINATOR had: two commits (e25530a4,
// 6bfb65a7) hoisted per-vertex-invariant work out of the no-falloff arm and
// `move/baseline` went 18 367 → 4 529 µs overnight, while
// `move/falloff=radial` went 29 858 → 30 455 (+2%, inside this lane's noise).
//
//     ratio = (base + falloff) / base = 1 + falloff/base
//
// so the gate's reading is proportional to the SPEED OF SOMETHING IT IS NOT
// ABOUT, and it moves the wrong way: an improvement to the uniform arm is
// reported as a falloff regression. The threshold 6.0 was itself calibrated
// (n=64, observed ~1.95×) while the baseline still carried the very defect
// those commits removed — a threshold set by a number the fix later changed.
// The same arithmetic is what makes the old form DEFEATABLE: a falloff
// regression arriving together with a baseline regression leaves the ratio
// where it was, and the gate stays green through both.
//
// Both clauses below are therefore free of that denominator. They were
// derived from the run history — `tools/perf/history/<host>.jsonl`, 14
// comparable ops runs between 2026-08-13 and 2026-08-24, 3 tools × 4
// whole-mesh falloff shapes = 168 measurements — NOT from the run that
// reddened, and both are computed only from the falloff cases themselves.
//
// I1a — SHAPE SPREAD, per tool: the dearest whole-mesh falloff shape costs no
// more than K1A × the cheapest. Scale-free: no host speed, no mesh size, no
// uniform-arm cost in it. The measured population, per tool over those 15
// runs (max/min of {linear, radial, screen, cylinder}):
//
//     move    1.60 - 1.71      rotate  1.53 - 1.63      scale  1.89 - 1.93
//
// The spread is also blind to host contention, which is the property that
// makes it a gate rather than a thermometer: on the contaminated 2026-08-24
// run, where every case read 2-4% high, move's spread moved 1.64 → 1.63.
// K1A = 3.0 leaves 1.55× over the worst value ever recorded.
//
// I1b — ABSOLUTE per-vertex-visit ceiling: no falloff case may spend more
// than K1B nanoseconds of kernelApply per vertex it visited. This is the
// clause I1a cannot be: a regression that lands on EVERY falloff shape at
// once (the shared per-vertex body, `blendToIdentity`, the double-precision
// re-centre block) moves numerator and denominator of any in-family ratio
// together and hides there. Measured ns/vertex-visit over the same 168
// samples: radial 14.67-15.44, linear 15.87-16.69, cylinder 22.42-24.30,
// screen 20.36-29.02 (scale/screen is the dearest shape in the matrix);
// `falloff=selection`, which moves half the mesh and is normalised by the
// verts IT visited, 9.53-10.17.
// K1B = 90 leaves 3.1× over the worst — the same order of margin I7e's
// absolute budget carries, and for the same reason: this catches the GROSS
// class (a per-vertex allocation, an O(V) search inside the weight function,
// a lost early-out), while a modest drift is `--vs-last`'s +20% job.
//
// Grid-only, like I7e: an absolute per-vertex number is a statement about a
// fixture, and `--subdivcube` is a different one.
enum double K1A_FALLOFF_SPREAD    = 3.0;
enum double K1B_FALLOFF_NS_PER_VERT = 90.0;

// Below this baseline median (µs), a metric is in the timing noise floor and a
// percentage-growth comparison is meaningless (e.g. selection=single touches
// ~20 verts ⇒ kernelApply 0.1µs, where +0.2µs reads as +200%). Real
// regressions land on the heavy cases (kernelApply ~550µs+), far above this.
enum double ABS_NOISE_FLOOR_US = 50.0;

// Absolute p99/hitch budgets for `frames` (task 0195 Phase 6) — generous
// FIXED ceilings (not baseline-relative growth, unlike the ops lane).
enum double K_FRAMES_P99_MS = 33.0;   // generous per-scenario p99 ceiling
enum long   K_FRAMES_HITCH33 = 2;     // generous >33ms-hitch allowance
