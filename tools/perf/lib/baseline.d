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

import std.algorithm : sort;
import std.array   : appender;
static import std.file;
import std.format  : format;
import std.json    : parseJSON, JSONType, JSONValue;
import std.math    : fabs, isNaN;
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
// THE DEBT LEDGER (task 1460) — tools/perf/baseline_debt.json
//
// WHY IT EXISTS. `baseline.json` was recorded 2026-06-07 and the 2026-08-19
// tree was measurably slower than it on ~30 cases. Task 1460 Phase 0 checked out the
// commit that WROTE the baseline, built it the same way, and ran its own
// harness on this host: the old code reproduced its own baseline at median
// ratio 1.02 with 1 absolute regression against 19 on today's main. So the
// baseline is HONEST and the loss is in our code — which means the two
// obvious repairs are both wrong. Re-recording the baseline would freeze the
// loss as the new normal and make it invisible for good; leaving the `ops`
// step out of the nightly gate (what the lane did until now) means a NEW
// regression on top of the old one reddens nothing either.
//
// The ledger is the third option: every unresolved, gate-worthy debt is pinned
// at its measured value, with an owner and a date, and the gate compares
// against that pin. New loss on a ledgered case is red immediately; the old
// loss stays written down instead of forgotten. Paid rows are removed rather
// than carried forward as a new baseline.
//
// A ledger's own failure mode is ROT — an entry outliving the regression it
// records re-admits the loss for free — so the comparison runs in BOTH
// directions, and `reconcileDebt` refuses to let an entry outlive its case.
// ---------------------------------------------------------------------------

// The low edge ("this debt looks paid") is measured from the DEBT, never from
// the baseline. That is not a taste call, it is arithmetic: with a single
// shared tolerance the two edges would be `cur > base*(1+tol)` and
// `cur > debt*(1+tol)`, whose green band is the open interval
// `(base*(1+tol), debt*(1+tol)]` — of ratio width exactly `debt/base`. Every
// entry with `debt/base <= 1+tol` would then be RED ON BOTH CLAUSES at the
// very value it was pinned at. Computed over the ledger as actually seeded
// (2026-08-19) that is **11 of its 37 ledgered entries**: `*/symmetry=X`,
// `*/falloff=linear`, `*/falloff=radial`, `*/falloff=cylinder` and
// `scale/falloff=screen` all sit at ratios 1.18-1.30. Debt-relative, the green
// band is `[debt*(1-k), debt*(1+tol)]` — 1.4444x wide for every entry whatever
// its ratio, and the pinned value sits inside it by construction.
enum double DEBT_IMPROVED_K = 0.10;

// ...and one night under the line is not payment. A `debtPaid` verdict
// DELETES an entry, so it legalises everything below it permanently; it takes
// this many CONSECUTIVE comparable runs (the current one counts as the first)
// before the notice becomes red. Measured reason, not caution:
// `scale/falloff=cylinder` has nine recorded n=316 history rows and six of
// them sit below a baseline-relative paid-line, so a one-shot rule would have
// deleted that entry on most nights of the week for an improvement nobody
// made.
enum int DEBT_IMPROVED_STREAK_N = 3;

// One ledgered case.
struct DebtEntry {
    // Keyed on `CaseResult.historyKey`, NEVER on the bare case name:
    // `checkAbsolute` looks the baseline up by `historyKey` (task 1373 F1.7),
    // which is `name@n<meshN>` for any case that pins a mesh size. A ledger
    // keyed on the bare name would silently stop matching the moment a case
    // acquired a pin — the exact way a case "vanishes" that this task exists
    // to close.
    string key;
    // NaN = this case has no comparable row in baseline.json at all (it was
    // added after the baseline was recorded). Such an entry carries the HIGH
    // edge only: with no baseline there is no "paid" to detect.
    double baselineUs = double.nan;
    double debtUs;
    double ratio;              // debtUs / baselineUs, or NaN
    int    samples;            // how many runs the median was taken over
    double spreadLoUs = double.nan, spreadHiUs = double.nan;  // observed min/max
    // Per-entry override of the run's global tolerance, for a case whose own
    // reproduction spread is wider than it. NaN = use the global one.
    double tol = double.nan;
    string owner;
    // `false` = recorded but NOT suppressed: the case still compares against
    // baseline.json as if the entry were absent. This is how a case whose own
    // noise exceeds its regression gets WRITTEN DOWN rather than silently
    // pinned at a number that would flap.
    bool   ledgered = true;
    string note;
}

struct Debt {
    int       schema;
    string    recordedAt, recordedCommit, note;
    RunHeader header;
    DebtEntry[string] byKey;
}

Debt loadDebt(string path) {
    Debt d;
    auto j = parseJSON(cast(string)std.file.read(path));
    d.schema         = ("schema" in j) ? cast(int)j["schema"].integer : 0;
    d.recordedAt     = ("recordedAt" in j) ? j["recordedAt"].str : "";
    d.recordedCommit = ("recordedCommit" in j) ? j["recordedCommit"].str : "";
    d.note           = ("note" in j) ? j["note"].str : "";
    if ("header" in j) {
        auto h = j["header"];
        d.header.buildType = ("buildType" in h) ? h["buildType"].str : "";
        d.header.compiler  = ("compiler"  in h) ? h["compiler"].str  : "";
        d.header.host      = ("host"      in h) ? h["host"].str      : "";
        d.header.meshType  = ("meshType"  in h) ? h["meshType"].str  : "";
        d.header.viewport  = ("viewport"  in h) ? h["viewport"].str  : "";
        d.header.n         = ("n" in h) ? cast(int)h["n"].integer : 0;
        d.header.faceCount = ("faceCount" in h) ? h["faceCount"].integer : 0;
        d.header.repeats   = ("repeats" in h) ? cast(int)h["repeats"].integer : 0;
    }
    foreach (ev; j["entries"].array) {
        DebtEntry e;
        e.key        = ev["key"].str;
        e.baselineUs = jsonNumOrNan(ev, "baselineUs");
        e.debtUs     = jsonNumOrNan(ev, "debtUs");
        e.ratio      = jsonNumOrNan(ev, "ratio");
        e.samples    = ("samples" in ev) ? cast(int)ev["samples"].integer : 0;
        e.spreadLoUs = jsonNumOrNan(ev, "spreadLoUs");
        e.spreadHiUs = jsonNumOrNan(ev, "spreadHiUs");
        e.tol        = jsonNumOrNan(ev, "tol");
        e.owner      = ("owner" in ev) ? ev["owner"].str : "";
        e.ledgered   = ("ledgered" in ev) ? ev["ledgered"].boolean : true;
        e.note       = ("note" in ev) ? ev["note"].str : "";
        d.byKey[e.key] = e;
    }
    return d;
}

// `null` and a missing field both mean "not recorded" ⇒ NaN. An integral
// literal in the JSON is not an error either (std.json types 3.0 as INTEGER).
private double jsonNumOrNan(ref JSONValue obj, string field) {
    if (field !in obj) return double.nan;
    auto v = obj[field];
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        default:                return double.nan;   // null / anything else
    }
}

// The verdict for ONE case against the ledger. Exactly one of the four flags
// is set when `ok` is false; `improvedNotice` is the one non-failing finding
// (it is printed, it does not redden the run).
struct DebtVerdict {
    bool   ok = true;
    bool   regressedVsBaseline;   // no entry (or not ledgered) and over baseline
    bool   regressedVsDebt;       // ledgered and over the pinned value
    bool   improvedNotice;        // under the pin, but not for long enough yet
    bool   improvedRed;           // under the pin for N consecutive runs ⇒ delete
    double refUs   = double.nan;  // the value the limit was computed from
    double limitUs = double.nan;  // the line `curUs` was compared against
    int    streak;                // consecutive runs in the improved region
    string detail;
}

double debtTolFor(const(DebtEntry)* e, double globalTol) {
    return (e !is null && !isNaN(e.tol)) ? e.tol : globalTol;
}

// Is `us` inside this entry's "improved" region? BOTH halves are required,
// and each rejects a different real scenario:
//
//   `us < debt*(1-k)` rejects PARTIAL payment. 1460's own first attribution
//   target is worth -8..-9% on `move/baseline`, landing at ~17000 µs against
//   a 13791.2 baseline and an 18458.7 pin. The REJECTED baseline-relative low
//   edge calls that paid on the spot (17000 <= 13791.2*1.30 = 17928.6) and
//   deletes the entry with most of the loss still outstanding; this half does
//   not, because 17000 is above 18458.7*0.9 = 16612.8.
//
//   `us <= baseline*(1+tol)` rejects an improvement that is real but not
//   ENOUGH. `delete/edges/whole` (base 63035.7, pin ~117712) at 90000 µs is
//   well under debt*0.9 = 105941 — a 24% improvement — and still +43% over
//   the baseline. Deleting its entry there would make the case RED the next
//   night, so the entry has to stay.
//
// "Paid" means "this entry is no longer suppressing anything", not "back to
// June": once an entry is deleted its case compares against baseline*(1+tol),
// which is always TIGHTER than debt*(1+tol). Deletion can only ever tighten
// the gate, which is why the bar for it is a streak and not a single night.
bool debtImproved(const ref DebtEntry e, double us, double tol) {
    if (isNaN(e.baselineUs)) return false;   // no baseline term ⇒ low edge off
    return us < e.debtUs * (1.0 - DEBT_IMPROVED_K)
        && us <= e.baselineUs * (1.0 + tol);
}

// The ledger's law, pure. `base` is null when the run's case has no row in
// baseline.json; `debt` is null when it has no ledger entry. `recentUs` is
// this key's medians from the previous comparable runs, NEWEST FIRST — passed
// in rather than read here so the law stays testable without a history file.
DebtVerdict judge(const(BaselineCase)* base, const(DebtEntry)* debt,
                  double curUs, double tol, const(double)[] recentUs) {
    DebtVerdict v;

    // No entry — or an entry deliberately NOT ledgered — is today's rule,
    // unchanged: compare to the baseline, skip the noise floor.
    if (debt is null || !debt.ledgered) {
        if (base is null) return v;                       // nothing to compare
        if (base.kernelMedianUs < ABS_NOISE_FLOOR_US) return v;
        v.refUs   = base.kernelMedianUs;
        v.limitUs = base.kernelMedianUs * (1.0 + tol);
        if (curUs > v.limitUs) {
            v.ok = false;
            v.regressedVsBaseline = true;
            v.detail = format("+%.0f%% over baseline (%.1f → %.1f µs)",
                              (curUs / base.kernelMedianUs - 1.0) * 100,
                              base.kernelMedianUs, curUs);
        }
        return v;
    }

    // Ledgered. The noise floor does NOT apply: a pin is an explicit operator
    // decision that this case's number means something.
    immutable double t = debtTolFor(debt, tol);
    v.refUs   = debt.debtUs;
    v.limitUs = debt.debtUs * (1.0 + t);

    if (curUs > v.limitUs) {
        v.ok = false;
        v.regressedVsDebt = true;
        v.detail = format("+%.0f%% over the ledgered debt (%.1f → %.1f µs, "
                          ~ "owner %s)",
                          (curUs / debt.debtUs - 1.0) * 100,
                          debt.debtUs, curUs, debt.owner);
        return v;
    }

    if (!debtImproved(*debt, curUs, tol)) return v;

    // In the improved region. Count how far back that has been true — the
    // current run is the first of the streak, and a run whose row does not
    // carry this key at all is not evidence and ends it (that is what
    // `recentUs` stopping short means; the caller does not pad).
    v.streak = 1;
    foreach (u; recentUs) {
        if (!debtImproved(*debt, u, tol)) break;
        v.streak++;
    }
    if (v.streak >= DEBT_IMPROVED_STREAK_N) {
        v.ok = false;
        v.improvedRed = true;
        v.detail = format("debt paid on %d consecutive runs (%.1f µs vs "
                          ~ "debt %.1f, baseline %.1f) — DELETE this entry "
                          ~ "from baseline_debt.json",
                          v.streak, curUs, debt.debtUs, debt.baselineUs);
    } else {
        v.improvedNotice = true;
        v.detail = format("under the debt on %d/%d consecutive runs (%.1f µs "
                          ~ "vs debt %.1f) — not deleted yet",
                          v.streak, DEBT_IMPROVED_STREAK_N, curUs, debt.debtUs);
    }
    return v;
}

// A ledger row that no longer describes anything.
struct DebtOrphan {
    string key;
    string reason;
}

// The ORPHAN GUARD, and it is a separate pass on purpose.
//
// `judge` is called from inside the loop over RESULTS, after the
// `if (p is null) continue;` that skips cases absent from the baseline — so a
// ledger entry whose case does not exist is a state `judge`'s signature can
// never see. A unit assertion written through `judge` for this would pass
// forever whatever the code did. This walks the LEDGER's keys instead.
//
// Without it, an entry that is renamed away, that stops producing a row, or
// that acquires an `@nNN` pin goes on suppressing a case that is no longer
// there — task 1460's own Hole 2, one level up.
DebtOrphan[] reconcileDebt(Debt d, Baseline base, const(string)[] runKeys) {
    bool[string] present;
    foreach (k; runKeys) present[k] = true;

    DebtOrphan[] orphans;
    string[] keys;
    foreach (k, _; d.byKey) keys ~= k;
    keys.sort();
    foreach (key; keys) {
        auto e = d.byKey[key];

        if (key !in present)
            orphans ~= DebtOrphan(key,
                "no case in this run produced this key — renamed, removed, or "
                ~ "newly pinned to a mesh size (the key is a historyKey: "
                ~ "`name@nNN` once a case pins one)");

        if (isNaN(e.baselineUs)) {
            if (key in base.byName)
                orphans ~= DebtOrphan(key,
                    "entry declares no baseline (baselineUs: null) but "
                    ~ "baseline.json now HAS a row for it — re-seed the entry");
        } else if (key !in base.byName) {
            orphans ~= DebtOrphan(key,
                "entry carries a baselineUs but baseline.json has no row "
                ~ "under this key");
        } else {
            immutable double b = base.byName[key].kernelMedianUs;
            if (fabs(b - e.baselineUs) > 1e-6 * (fabs(b) + 1.0))
                orphans ~= DebtOrphan(key,
                    format("entry's baselineUs %.4f disagrees with "
                           ~ "baseline.json's %.4f — one of the two moved",
                           e.baselineUs, b));
        }
    }
    return orphans;
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
