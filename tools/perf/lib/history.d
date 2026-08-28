module lib.history;
// Per-host run history for `ops`/`frames` runs (task 0197 Phase 4): one
// JSON line per run appended to tools/perf/history/<host>.jsonl (gitignored
// — no tracked-file churn), plus a reader + `--trend` printer that reads it
// back with no vibe3d launch/build.

import std.algorithm : sort, endsWith;
import std.algorithm.mutation : reverse;
import std.array     : appender;
import std.conv      : to;
import std.datetime.systime : Clock;
import std.file       : exists, mkdirRecurse, append, readText;
static import std.file;
import std.format     : format;
import std.json        : parseJSON, JSONValue, JSONType;
import std.math        : isNaN;
import std.path         : buildPath;
import std.stdio        : writeln, writefln;
import std.string        : lineSplitter, strip;

import lib.baseline : RunHeader;
import lib.stats    : jsonNum;
import lib.vslast;

string historyDir(string repoRoot) {
    return buildPath(repoRoot, "tools", "perf", "history");
}

string historyPath(string repoRoot, string host) {
    return buildPath(historyDir(repoRoot), host ~ ".jsonl");
}

// Appends one line: the RunHeader fields + a unix timestamp + a per-case (or
// per-scenario) median map. `medians` is {caseName: kernelApplyMedianUs} for
// `ops`, {scenarioName: p99Ms} for `frames`, {caseName: one-rebuildPreview
// median µs} for `tools` — the caller picks the metric, this module is
// metric-agnostic. `kind` ("ops" / "frames" / "tools") tags the entry so
// readers can keep the metric spaces apart; entries written before the tag
// existed are classified by entryKind()'s name-shape fallback.
//
// `tools` MUST carry its explicit tag: its case names carry a '/' exactly
// like ops case names do, so the fallback would file them as `ops` and
// `--trend` would put one preview rebuild next to a kernelApply median in
// one drift table (task 1370).
//
// `contaminated` (task 1840) marks a run measured while a foreign vibe3d was
// alive on the host — see `lib.lifecycle.warnForeignVibe` for the incident and
// the numbers. The entry is still WRITTEN: it is a record of what the host did
// that night, and deleting measurements because they are inconvenient is how a
// history stops being evidence. It is the day-over-day GATE that must not
// touch it, in either direction, and `checkVsLast` is where that is enforced.
// The key is emitted only when true, so every pre-1840 line stays byte-exact
// and `loadHistory` reads a missing key as false.
void appendHistory(string repoRoot, RunHeader h, double[string] medians,
                   string kind = "", bool contaminated = false) {
    string dir = historyDir(repoRoot);
    if (!exists(dir)) mkdirRecurse(dir);
    string path = historyPath(repoRoot, h.host);

    auto a = appender!string();
    a.put("{");
    a.put(format(`"ts":%d,`, Clock.currTime.toUnixTime!long));
    if (kind.length) a.put(format(`"kind":"%s",`, kind));
    if (contaminated) a.put(`"contaminated":true,`);
    a.put(format(`"buildType":"%s","compiler":"%s","host":"%s","meshType":"%s",`,
                 h.buildType, h.compiler, h.host, h.meshType));
    a.put(format(`"n":%d,"faceCount":%d,"viewport":"%s","repeats":%d,`,
                 h.n, h.faceCount, h.viewport, h.repeats));
    a.put(`"medians":{`);
    bool first = true;
    auto names = medians.keys;
    names.sort();
    foreach (name; names) {
        if (!first) a.put(",");
        first = false;
        a.put(format(`"%s":%s`, name, jsonNum(medians[name])));
    }
    a.put("}}\n");
    std.file.append(path, a.data);
}

struct HistoryEntry {
    long   ts;
    string kind;          // "ops" / "frames" / "tools"; "" on pre-tag entries
    // A foreign vibe3d was alive on the host while this run measured, so its
    // medians describe the host's contention as much as the code's cost
    // (task 1840). False on every entry written before the flag existed —
    // which is a statement about the RECORD, not about those hosts.
    bool   contaminated;
    RunHeader header;
    double[string] medians;
}

// The entry's metric space. Pre-tag entries are classified by name shape:
// every ops case name carries a '/' (tool/axis or verb/type/extent); no
// frames scenario name does. The fallback CANNOT see `tools` entries — their
// names carry a '/' too — which is why every `tools` append passes the tag
// explicitly (task 1370). Only pre-tag entries reach the fallback at all.
string entryKind(const ref HistoryEntry e) {
    if (e.kind.length) return e.kind;
    import std.algorithm : canFind, all;
    if (e.medians.length == 0) return "";
    foreach (name; e.medians.byKey)
        if (!name.canFind('/')) return "frames";
    return "ops";
}

// Two entries are comparable when their runs measured the same thing: same
// metric space, build, mesh, and viewport. `compiler`/`repeats`/`host` are
// deliberately not compared (host is fixed per file; a repeats change moves
// noise, not the median).
bool comparableEntries(const ref HistoryEntry a, const ref HistoryEntry b) {
    return entryKind(a) == entryKind(b)
        && a.header.buildType == b.header.buildType
        && a.header.meshType  == b.header.meshType
        && a.header.n         == b.header.n
        && a.header.faceCount == b.header.faceCount
        && a.header.viewport  == b.header.viewport;
}

HistoryEntry[] loadHistory(string path) {
    HistoryEntry[] entries;
    if (!exists(path)) return entries;
    foreach (line; readText(path).lineSplitter) {
        auto trimmed = line.strip;
        if (trimmed.length == 0) continue;
        JSONValue j;
        try j = parseJSON(trimmed);
        catch (Exception) continue;   // skip a malformed/partial line
        HistoryEntry e;
        e.ts = ("ts" in j) ? j["ts"].integer : 0;
        e.kind = ("kind" in j) ? j["kind"].str : "";
        e.contaminated = ("contaminated" in j)
            && j["contaminated"].type == JSONType.true_;
        e.header.buildType = j["buildType"].str;
        e.header.compiler  = j["compiler"].str;
        e.header.host      = j["host"].str;
        e.header.meshType  = j["meshType"].str;
        e.header.n         = cast(int)j["n"].integer;
        e.header.faceCount = j["faceCount"].integer;
        e.header.viewport  = j["viewport"].str;
        e.header.repeats   = cast(int)j["repeats"].integer;
        if ("medians" in j)
            foreach (string k, v; j["medians"].object)
                e.medians[k] = (v.type == JSONType.null_) ? double.nan : v.floating;
        entries ~= e;
    }
    return entries;
}

// Coarse 8-level ASCII/Unicode sparkline over a series, min-max normalized.
string sparkline(double[] xs) {
    static immutable dstring bars = "▁▂▃▄▅▆▇█";
    if (xs.length == 0) return "";
    double lo = xs[0], hi = xs[0];
    foreach (x; xs) { if (x < lo) lo = x; if (x > hi) hi = x; }
    auto a = appender!string();
    foreach (x; xs) {
        double t = (hi > lo) ? (x - lo) / (hi - lo) : 0.5;
        size_t idx = cast(size_t)(t * (bars.length - 1) + 0.5);
        a.put(bars[idx]);
    }
    return a.data;
}

// Prints a per-case median-drift table over the last `last` runs. Pure file
// read — no vibe3d launch/build (`--trend` short-circuits before either in
// main()).
void printTrend(HistoryEntry[] entries, int last) {
    if (entries.length == 0) {
        writeln("no history yet — run `ops` or `frames` at least once first");
        return;
    }
    // Only runs comparable with the most recent one belong in one drift
    // table: an n=64 smoke run next to the n=316 matrix (or a `frames` ms
    // entry next to an `ops` µs entry) would fabricate thousand-percent
    // "drift" out of the config change alone.
    auto current = entries[$ - 1];
    HistoryEntry[] comparable;
    foreach (e; entries) if (comparableEntries(e, current)) comparable ~= e;
    auto window = comparable.length > last ? comparable[$ - last .. $] : comparable;
    writefln("history: %d run(s) total, %d comparable with the latest (%s n=%d %s), showing last %d",
             entries.length, comparable.length, entryKind(current),
             current.header.n, current.header.meshType, window.length);

    bool[string] namesSet;
    foreach (e; window) foreach (k; e.medians.byKey) namesSet[k] = true;
    auto names = namesSet.keys;
    names.sort();

    writeln();
    writefln("%-32s %12s %12s %9s  %s", "case", "first (us)", "last (us)", "drift", "trend");
    foreach (name; names) {
        double[] series;
        foreach (e; window) {
            if (auto p = name in e.medians) {
                if (!(*p).isNaN) series ~= *p;
            }
        }
        if (series.length == 0) continue;
        double first = series[0];
        double lastV = series[$ - 1];
        double driftPct = (first > 0) ? (lastV / first - 1.0) * 100.0 : 0.0;
        writefln("%-32s %12.2f %12.2f %+8.1f%%  %s",
                 name, first, lastV, driftPct, sparkline(series));
    }
}

// `--vs-last` — the day-over-day gate for a scheduled run. Compares the most
// recent entry against the latest EARLIER comparable entry (same kind /
// build / mesh / n / viewport) and fails on any per-case median that grew
// past `threshold` (a fraction: 0.20 = +20%). Cases where BOTH sides sit
// under `floorUs` are skipped — sub-100µs medians jitter multiplicatively
// and gate nothing real (the absolute lane excludes them for the same
// reason). Only `ops` entries gate: `frames` p99 is hitch-shaped and too
// flaky for a ±20% day-over-day assert (its counter invariants F-I* are the
// gate there). Returns the number of regressions (0 = pass), -1 when there
// is nothing to compare (first run / no comparable predecessor) — the
// caller treats -1 as pass.
// Task 1350 — `#snapQuery` medians gate at their OWN threshold.
//
// `appendHistory`'s map carries two kinds of number now: a case's
// `kernelApply` median (key = the case name) and, for snap cases, that case's
// `snapQuery` median (key = `<case>#snapQuery`). The +20% default was
// calibrated on the first kind, which is stable to about 1% run-to-run. The
// second kind is not.
//
// WHY IT IS NOT — measured, 2026-08-19, four consecutive runs in a quiet
// window (load 0.5-1.3 on 32 cores), by dumping the five per-repeat
// `snapQuery` totals a median is taken over. An earlier draft of this comment
// named two causes, host warm-up AND "a candidate-grid rebuild whose bucket
// occupancy shifts with where the drag left the cursor". The second one is
// NOT what moves the median, and the measurement says so plainly:
//
//   move/snap=edge, per-repeat µs
//     run A   18570  15184  11473  19137  11008     median 15184
//     run B   16750  14902  11455  10910  24314     median 14902
//     run C   16918  15213  11497  11041  11006     median 11497
//     run D   17317  15365  11566  10973  10996     median 11566
//
// The state-dependent part is the DECAY across the first three repeats
// (~17 ms → ~15 ms → ~11.5 ms; each drag deforms the mesh the next one is
// measured on, so the geometry and the grid really do differ). That part is
// DETERMINISTIC: at the same repeat index it reproduces run to run inside
// ~2%. Something deterministic cannot move a median BETWEEN runs, so
// resetting the cursor/grid between repeats would remove a component that is
// not contributing.
//
// What moves the median is a SPORADIC ~2x outlier (A's repeat 4, B's repeat
// 5) that lands at a random index. With five samples one such spike shifts
// the median by a whole rank — 11.5 ms to 15 ms, +30% — with no code change
// at all. It is a host/runtime event (scheduling, or a GC landing inside one
// drag: the whole-mesh keys' snapQuery is dominated by the ALLOCATING
// candidate-grid rebuild, which is why they are the noisy ones, while
// `snap=vertex+partial` — dominated by the mask's allocation-free O(V x
// |front|) pass — is flat to ±1% across all four runs). On top of that sits
// the session-long thermal drift the table below was taken through.
//
// So the threshold below is paid for by ONE cause, host variance, in two
// forms: a sporadic outlier through a 5-sample median, and warm-up drift
// across a day. Two cheaper fixes were considered and NOT taken here because
// each is a harness redesign rather than a review fix: more repeats (the
// outlier stops owning a rank), or a trimmed mean instead of a median.
//
// MEASURED on this host, nine to ten consecutive `snap=` runs, 2026-08-18
// (peak-to-peak over the run, and the worst step between two CONSECUTIVE runs
// — the second is what a day-over-day gate actually sees):
//
//   move/snap=vertex+partial#snapQuery    3.0%  /  +1.3%
//   move/snap=polyCenter#snapQuery        2.8%  /  +2.5%
//   move/snap=edgeCenter#snapQuery        4.2%  /  +3.2%
//   move/snap=polygon#snapQuery           6.4%  /  +3.5%
//   move/snap=vertex#snapQuery           13.4%  / +12.6%
//   move/snap=edge#snapQuery             32.0%  / +17.7%
//
// (`grid` and `workplane` swing 40%+ but sit at ~6 µs, so the `floorUs` skip
// below already excludes them from the comparison entirely.)
//
// Those figures span a whole session on a host that was warming up: `edge`
// drifted 15.1 → 11.3 ms across it. Re-measured over four consecutive runs in
// a SETTLED window the same keys are far tighter — worst consecutive step
// +2.9% (`edge`), +1.3% (`vertex+partial`), +0.9% (`vertex`). Both numbers
// matter and they answer different questions: the settled one describes runs
// minutes apart, and a day-over-day gate compares runs 24 HOURS apart, in
// different thermal and host states — much closer to the session-long sample.
//
// So the threshold is set at ~3x the WORST step ever observed (+17.7%),
// rounded: +60%. At the +20% default `edge` would have gone red on a quiet
// night with nothing changed and `vertex` would have had 7% of headroom — a
// gate that cries wolf gets disabled, and then the hole it was covering is
// open again. +60% is a factor of 33 below the regression this key exists to
// catch — the one that motivated it (task 1332, 2026-08-18) was 2.4 ms →
// 56 ms, i.e. +2000% — so about ONE AND A HALF orders of magnitude of margin.
// (An earlier draft of this comment said "three orders of magnitude"; it was
// wrong by a factor of ~30, review fix task 1358. The margin is still ample;
// the number just has to be the real one.)
//
// Stated rather than hidden: this threshold does NOT catch a modest snap
// regression under +60%. That is the price of the measured noise, and the
// alternative — recording the number and gating nothing — catches even less.
// An operator hunting a SMALLER snap regression lowers it explicitly with
// `--vs-last-snap-threshold`, or lowers `--vs-last-threshold` (which pulls
// this one down with it — see `checkVsLast`'s caller in run.d).
enum double kSnapQueryVsLastThreshold = 0.60;

// `checkVsLast`'s return for "this run cannot be judged" — distinct from 0
// (compared, clean) and from -1 (nothing to compare, which is a legitimate
// pass on a first run). The caller turns it into a FAILING exit code.
//
// Why it fails rather than passes, task 1840: a green that means "did not
// check" is the inert gate this project keeps paying for (CLAUDE.md: "the run
// never happened"). Nothing was measured tonight that a day-over-day gate may
// speak about, and the lane's job is to say so — with the pids, so the fix is
// one `kill` away — not to report health it did not establish.
enum int kVsLastNoVerdict = -2;

// The metric suffixes that are RECORDED into the history file but are not
// timing medians and must never reach the comparison. Two different reasons,
// kept apart deliberately (see the long note above `kSnapQueryVsLastThreshold`
// and tasks 2030 / 2070): `#rssDeltaKb` and the three `#gc*` keys are
// un-baselined side channels, while `#kernelP95Us` is not a measurement OF the
// case at all — it is the SPREAD of the case's own repeats, which task 2420's
// gate consumes as a band term. Comparing a spread day over day would gate the
// noise instead of the signal.
private bool isNonGatedMetric(string name) {
    return name.endsWith("#rssDeltaKb")
        || name.endsWith("#gcAllocBytes")
        || name.endsWith("#gcCollections")
        || name.endsWith("#gcMaxPauseNs")
        || name.endsWith("#kernelP95Us");
}

/// The suffix `run.d` writes this case's own p95-over-repeats under, and the
/// suffix the same-night band arm reads back. One spelling, one place.
enum string kP95Suffix = "#kernelP95Us";

// Builds the gate's view of one comparison: every gated key present in BOTH
// rows, carrying its p95 side channel and its own prior series.
//
// `prior` must be the comparable, uncontaminated entries STRICTLY EARLIER than
// `current`, oldest first — the judged run's own value must not appear in any
// case's `priorSeries`, or the band would widen by exactly the regression it is
// judging (CLAUDE.md's "the threshold is derived from the measurement it is
// meant to judge"; task 1840 paid for one of those already).
lib.vslast.CaseObservation[] buildObservations(
        const ref HistoryEntry current, const ref HistoryEntry prev,
        const(HistoryEntry)[] prior, double floorUs) {
    lib.vslast.CaseObservation[] obs;
    auto names = current.medians.keys;
    names.sort();
    foreach (name; names) {
        if (isNonGatedMetric(name)) continue;
        auto pp = name in prev.medians;
        if (pp is null) continue;                       // new case — no reference
        double cur = current.medians[name], prv = *pp;
        if (cur.isNaN || prv.isNaN) continue;
        if (cur < floorUs && prv < floorUs) continue;   // µs-jitter band
        lib.vslast.CaseObservation o;
        o.name   = name;
        o.prevUs = prv;
        o.curUs  = cur;
        double sideOf(const ref HistoryEntry e, string suffix) {
            if (auto v = (name ~ suffix) in e.medians) return *v;
            return double.nan;
        }
        o.curP95Us  = sideOf(current, kP95Suffix);
        o.prevP95Us = sideOf(prev,    kP95Suffix);
        double[] series;
        foreach (ref e; prior)
            if (auto v = name in e.medians)
                if (!(*v).isNaN) series ~= *v;
        o.priorSeries = series;
        obs ~= o;
    }
    return obs;
}

int checkVsLast(HistoryEntry[] entries, double threshold, double snapThreshold,
                double floorUs, lib.vslast.GateParams params) {
    params.defaultThreshold = threshold;
    params.snapThreshold    = snapThreshold;

    if (entries.length == 0) {
        writeln("vs-last: no history yet — nothing to compare (PASS)");
        return -1;
    }
    auto current = entries[$ - 1];
    if (entryKind(current) != "ops") {
        writeln("vs-last: latest entry is not an `ops` run — nothing to gate (PASS)");
        return -1;
    }
    if (current.contaminated) {
        writefln("vs-last: the latest `ops` run (ts=%d) is marked CONTAMINATED "
                 ~ "— a foreign vibe3d was alive on the host while it measured, "
                 ~ "so its medians are not comparable with anything. NO VERDICT "
                 ~ "(FAIL): nothing was measured that this gate may speak about. "
                 ~ "Clear the foreign instance and re-run the ops lane.",
                 current.ts);
        return kVsLastNoVerdict;
    }
    // Latest earlier comparable entry — skipping contaminated ones. A
    // contaminated reference is worse than no reference: its inflated medians
    // turn today's honest numbers into fake IMPROVEMENTS and give a real
    // regression the same amount of room to hide in (task 1840).
    HistoryEntry prev;
    bool found = false;
    int skippedContaminated = 0;
    HistoryEntry[] prior;                 // oldest → newest, current EXCLUDED
    foreach_reverse (e; entries[0 .. $ - 1]) {
        if (!comparableEntries(e, current)) continue;
        if (e.contaminated) { if (!found) skippedContaminated++; continue; }
        if (!found) { prev = e; found = true; }
        prior ~= e;
        if (prior.length >= params.priorWindow) break;
    }
    if (skippedContaminated > 0)
        writefln("vs-last: skipped %d contaminated entry/entries while looking "
                 ~ "for a reference", skippedContaminated);
    if (!found) {
        writeln("vs-last: no comparable previous run — nothing to compare (PASS)");
        return -1;
    }
    prior.reverse();                       // foreach_reverse gathered newest-first

    auto obs = buildObservations(current, prev, prior, floorUs);
    immutable double scale = lib.vslast.runScale(obs, params);

    if (params.flat)
        writefln("vs-last: comparing ts=%d against ts=%d (ops n=%d %s, FLAT mode:"
                 ~ " one threshold +%.0f%% [+%.0f%% for #snapQuery], floor %.0f µs)",
                 current.ts, prev.ts, current.header.n, current.header.meshType,
                 threshold * 100.0, snapThreshold * 100.0, floorUs);
    else
        writefln("vs-last: comparing ts=%d against ts=%d (ops n=%d %s, per-case band:"
                 ~ " max(floor %.0f%%, own p95/median, %.1f× own prior spread);"
                 ~ " %d earlier run(s) feed the band; run common-mode ×%.4f;"
                 ~ " no-history fallback +%.0f%% [+%.0f%% #snapQuery]; floor %.0f µs)",
                 current.ts, prev.ts, current.header.n, current.header.meshType,
                 params.bandFloor * 100.0, params.bandSigma, prior.length, scale,
                 threshold * 100.0, snapThreshold * 100.0, floorUs);

    struct Row { lib.vslast.CaseObservation o; lib.vslast.Verdict v; }
    Row[] regressed, improved;
    int compared = 0;
    foreach (ref o; obs) {
        auto v = lib.vslast.judge(o, scale, params);
        compared++;
        if (v.call == lib.vslast.Call.regressed) regressed ~= Row(o, v);
        else if (v.call == lib.vslast.Call.improved) improved ~= Row(o, v);
    }

    // The band's SOURCE is printed with every row, so a verdict a reader
    // disagrees with names the layer to argue with rather than a bare number.
    string why(const ref lib.vslast.Verdict v) {
        final switch (v.band.source) {
            case lib.vslast.BandSource.floor:     return format("floor %.0f%%", v.band.pct);
            case lib.vslast.BandSource.sameNight: return format("own p95/median %.0f%%", v.band.sameNightPct);
            case lib.vslast.BandSource.spread:    return format("%.1f× its own prior spread %.1f%%", params.bandSigma, v.band.spreadPct);
            case lib.vslast.BandSource.fallback:  return params.flat ? "flat threshold"
                                                                     : "no measured spread yet";
        }
    }
    foreach (ref r; improved)
        writefln("  [ok]   %-32s %12.1f -> %12.1f µs  (%+.0f%%, improved; band %.0f%% from %s)",
                 r.o.name, r.o.prevUs, r.o.curUs, r.v.movePct, r.v.band.pct, why(r.v));
    foreach (ref r; regressed)
        writefln("  [FAIL] %-32s %12.1f -> %12.1f µs  (%+.0f%%, %+.0f%% after common-mode;"
                 ~ " band %.0f%% from %s)",
                 r.o.name, r.o.prevUs, r.o.curUs, r.v.movePct, r.v.scaledMovePct,
                 r.v.band.pct, why(r.v));
    writefln("vs-last: %d case(s) compared, %d regressed, %d improved — %s",
             compared, cast(int)regressed.length, cast(int)improved.length,
             regressed.length ? "FAIL" : "PASS");
    return cast(int)regressed.length;
}
