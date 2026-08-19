module lib.history;
// Per-host run history for `ops`/`frames` runs (task 0197 Phase 4): one
// JSON line per run appended to tools/perf/history/<host>.jsonl (gitignored
// — no tracked-file churn), plus a reader + `--trend` printer that reads it
// back with no vibe3d launch/build.

import std.algorithm : sort, endsWith;
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
void appendHistory(string repoRoot, RunHeader h, double[string] medians,
                   string kind = "") {
    string dir = historyDir(repoRoot);
    if (!exists(dir)) mkdirRecurse(dir);
    string path = historyPath(repoRoot, h.host);

    auto a = appender!string();
    a.put("{");
    a.put(format(`"ts":%d,`, Clock.currTime.toUnixTime!long));
    if (kind.length) a.put(format(`"kind":"%s",`, kind));
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

int checkVsLast(HistoryEntry[] entries, double threshold, double snapThreshold,
                double floorUs) {
    if (entries.length == 0) {
        writeln("vs-last: no history yet — nothing to compare (PASS)");
        return -1;
    }
    auto current = entries[$ - 1];
    if (entryKind(current) != "ops") {
        writeln("vs-last: latest entry is not an `ops` run — nothing to gate (PASS)");
        return -1;
    }
    // Latest earlier comparable entry.
    HistoryEntry prev;
    bool found = false;
    foreach_reverse (e; entries[0 .. $ - 1]) {
        if (comparableEntries(e, current)) { prev = e; found = true; break; }
    }
    if (!found) {
        writeln("vs-last: no comparable previous run — nothing to compare (PASS)");
        return -1;
    }

    import std.datetime.systime : SysTime;
    writefln("vs-last: comparing ts=%d against ts=%d (ops n=%d %s, threshold +%.0f%%" ~
             " [+%.0f%% for #snapQuery], floor %.0f µs)",
             current.ts, prev.ts, current.header.n, current.header.meshType,
             threshold * 100.0, snapThreshold * 100.0, floorUs);

    struct Row { string name; double prevUs, curUs; }
    Row[] regressed;
    Row[] improved;
    int compared = 0;
    auto names = current.medians.keys;
    names.sort();
    foreach (name; names) {
        auto pp = name in prev.medians;
        if (pp is null) continue;                       // new case — no reference
        double cur = current.medians[name], prv = *pp;
        if (cur.isNaN || prv.isNaN) continue;
        if (cur < floorUs && prv < floorUs) continue;   // µs-jitter band
        compared++;
        // The `#snapQuery` keys get their OWN threshold, resolved by the
        // caller — NOT `max(threshold, kSnapQueryVsLastThreshold)` (review
        // fix, task 1358). `max` made +60% a FLOOR: an operator hunting a
        // small snap regression with `--vs-last-threshold 0.05` got 5% on
        // every key EXCEPT the ones they were hunting, which is the exact
        // inverse of what they asked for. It is a separate parameter now, and
        // run.d pulls it down when the operator tightens the general one.
        immutable double thr = name.endsWith("#snapQuery")
            ? snapThreshold : threshold;
        if (cur > prv * (1.0 + thr)) regressed ~= Row(name, prv, cur);
        else if (prv > cur * (1.0 + thr)) improved ~= Row(name, prv, cur);
    }

    foreach (r; improved)
        writefln("  [ok]   %-32s %12.1f -> %12.1f µs  (%+.0f%%, improved)",
                 r.name, r.prevUs, r.curUs, (r.curUs / r.prevUs - 1.0) * 100.0);
    foreach (r; regressed)
        writefln("  [FAIL] %-32s %12.1f -> %12.1f µs  (%+.0f%%)",
                 r.name, r.prevUs, r.curUs, (r.curUs / r.prevUs - 1.0) * 100.0);
    writefln("vs-last: %d case(s) compared, %d regressed, %d improved — %s",
             compared, cast(int)regressed.length, cast(int)improved.length,
             regressed.length ? "FAIL" : "PASS");
    return cast(int)regressed.length;
}
