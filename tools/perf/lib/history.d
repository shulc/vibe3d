module lib.history;
// Per-host run history for `ops`/`frames` runs (task 0197 Phase 4): one
// JSON line per run appended to tools/perf/history/<host>.jsonl (gitignored
// — no tracked-file churn), plus a reader + `--trend` printer that reads it
// back with no vibe3d launch/build.

import std.algorithm : sort, max, min;
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
// `ops`, {scenarioName: p99Ms} for `frames` — the caller picks the metric,
// this module is metric-agnostic. `kind` ("ops" / "frames") tags the entry so
// readers can keep the two metric spaces apart; entries written before the
// tag existed are classified by entryKind()'s name-shape fallback.
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
    string kind;          // "ops" / "frames"; "" on pre-tag entries
    RunHeader header;
    double[string] medians;
}

// The entry's metric space. Pre-tag entries are classified by name shape:
// every ops case name carries a '/' (tool/axis or verb/type/extent); no
// frames scenario name does.
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
int checkVsLast(HistoryEntry[] entries, double threshold, double floorUs) {
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
    writefln("vs-last: comparing ts=%d against ts=%d (ops n=%d %s, threshold +%.0f%%, floor %.0f µs)",
             current.ts, prev.ts, current.header.n, current.header.meshType,
             threshold * 100.0, floorUs);

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
        if (cur > prv * (1.0 + threshold)) regressed ~= Row(name, prv, cur);
        else if (prv > cur * (1.0 + threshold)) improved ~= Row(name, prv, cur);
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
