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
// this module is metric-agnostic.
void appendHistory(string repoRoot, RunHeader h, double[string] medians) {
    string dir = historyDir(repoRoot);
    if (!exists(dir)) mkdirRecurse(dir);
    string path = historyPath(repoRoot, h.host);

    auto a = appender!string();
    a.put("{");
    a.put(format(`"ts":%d,`, Clock.currTime.toUnixTime!long));
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
    RunHeader header;
    double[string] medians;
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
    auto window = entries.length > last ? entries[$ - last .. $] : entries;
    writefln("history: %d run(s) total, showing last %d", entries.length, window.length);

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
