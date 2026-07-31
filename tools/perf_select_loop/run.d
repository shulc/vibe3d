#!/usr/bin/env rdmd
/**
 * perf_select_loop — deterministic micro-benchmark for `select.loop` on the
 * shapes that expose the seed-scan cost of the recovered face/vertex walk.
 *
 * The recovered algorithms consume seeds group-by-group. Each pass used to
 * re-scan the selected-element list from the HEAD, so the total cost was
 * O(groups x selected). Group count equals the selected count whenever most
 * elements form their own group, which is EVERY TRIANGLE in polygon mode (the
 * band trace skips odd-sided neighbours, so a triangle never advances) and
 * every small component in vertex mode. Both scans are monotone — marks are
 * only ever set — so a forward-only cursor is semantically identical and makes
 * the pass sequence linear.
 *
 * Shapes:
 *   tri<N>  N x N quad grid, every cell split into 2 triangles (2*N^2 faces)
 *   dq<K>   K disjoint quads (4*K vertices, K faces, K components)
 *
 * Modes: `poly` selects all polygons then runs select.loop; `vert` selects all
 * vertices then runs select.loop.
 *
 *   rdmd tools/perf_select_loop/run.d                     # default sweep
 *   rdmd tools/perf_select_loop/run.d --bin /tmp/v3d_before
 *   rdmd tools/perf_select_loop/run.d --reps 5 --port 8399
 *
 * Requires `curl` on PATH. Not a gating suite — a human reads the numbers; the
 * gating counterpart is the operation-count unittest in source/mesh.d.
 * Launches exactly one vibe3d and kills it by the PID it spawned (never by
 * name or pattern — parallel suites share this checkout).
 */
import std.stdio;
import std.process;
import std.conv       : to;
import std.string     : strip;
import std.algorithm  : sort, map;
import std.array      : appender, array, join;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.thread    : Thread;
import core.time      : msecs;
import std.file       : write, tempDir, remove, exists;
import std.path       : buildPath;
import std.format     : format;

int gPort  = 8399;
int gReps  = 5;
string gBin = "./vibe3d";

string url(string path) { return format("http://127.0.0.1:%d%s", gPort, path); }

void postCmd(string id, string[] positional = null)
{
    auto app = appender!string();
    app.put(`{"id":"`); app.put(id); app.put(`"`);
    if (positional.length) {
        app.put(`,"_positional":[`);
        foreach (i, p; positional) {
            if (i) app.put(",");
            bool numeric = p.length && (p[0] == '-' || (p[0] >= '0' && p[0] <= '9'));
            if (numeric) app.put(p);
            else { app.put(`"`); app.put(p); app.put(`"`); }
        }
        app.put(`]`);
    }
    app.put(`}`);
    auto r = execute(["curl","-s","-o","/dev/null","--max-time","600",
                      "-H","Content-Type: application/json",
                      "--data-binary", app.data, url("/api/command")]);
    if (r.status != 0) throw new Exception("curl failed: " ~ r.output);
}

string getSelection()
{
    auto r = execute(["curl","-s","--max-time","120", url("/api/selection")]);
    return r.output.strip;
}

void loadMeshJson(string json, string tag)
{
    string tmp = buildPath(tempDir(), format("perf_select_loop_%s.json", tag));
    write(tmp, json);
    scope(exit) if (exists(tmp)) remove(tmp);
    auto rr = execute(["curl","-s","-o","/dev/null","--max-time","600",
                       "-H","Content-Type: application/json",
                       "--data-binary","@" ~ tmp, url("/api/load-mesh")]);
    if (rr.status != 0) throw new Exception("load-mesh curl failed: " ~ rr.output);
}

/// N x N quad grid, every cell split into two triangles.
string triGrid(int n)
{
    auto v = appender!string();
    v.put(`{"vertices":[`);
    bool first = true;
    foreach (r; 0 .. n + 1)
        foreach (c; 0 .. n + 1) {
            if (!first) v.put(",");
            first = false;
            v.put(format("[%d,0,%d]", c, r));
        }
    v.put(`],"faces":[`);
    first = true;
    int vid(int r, int c) { return r * (n + 1) + c; }
    foreach (r; 0 .. n)
        foreach (c; 0 .. n) {
            if (!first) v.put(",");
            first = false;
            v.put(format("[%d,%d,%d],[%d,%d,%d]",
                         vid(r,c),   vid(r,c+1), vid(r+1,c+1),
                         vid(r,c),   vid(r+1,c+1), vid(r+1,c)));
        }
    v.put(`]}`);
    return v.data;
}

/// N x N quad grid, cells left as quads.
string quadGrid(int n)
{
    auto v = appender!string();
    v.put(`{"vertices":[`);
    bool first = true;
    foreach (r; 0 .. n + 1)
        foreach (c; 0 .. n + 1) {
            if (!first) v.put(",");
            first = false;
            v.put(format("[%d,0,%d]", c, r));
        }
    v.put(`],"faces":[`);
    first = true;
    int vid(int r, int c) { return r * (n + 1) + c; }
    foreach (r; 0 .. n)
        foreach (c; 0 .. n) {
            if (!first) v.put(",");
            first = false;
            v.put(format("[%d,%d,%d,%d]", vid(r,c), vid(r,c+1), vid(r+1,c+1), vid(r+1,c)));
        }
    v.put(`]}`);
    return v.data;
}

/// K disjoint unit quads (no shared vertices) — K separate components.
string disjointQuads(int k)
{
    auto v = appender!string();
    v.put(`{"vertices":[`);
    bool first = true;
    foreach (i; 0 .. k) {
        int x = (i % 64) * 3, z = (i / 64) * 3;
        foreach (o; 0 .. 4) {
            if (!first) v.put(",");
            first = false;
            int dx = (o == 1 || o == 2) ? 1 : 0;
            int dz = (o >= 2) ? 1 : 0;
            v.put(format("[%d,0,%d]", x + dx, z + dz));
        }
    }
    v.put(`],"faces":[`);
    first = true;
    foreach (i; 0 .. k) {
        if (!first) v.put(",");
        first = false;
        v.put(format("[%d,%d,%d,%d]", 4*i, 4*i+1, 4*i+2, 4*i+3));
    }
    v.put(`]}`);
    return v.data;
}

double median(double[] xs)
{
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    return s[$/2];
}

struct Row { string shape; string mode; size_t elems; double ms; }
Row[] gRows;

void benchCase(string shape, string mode, string json, size_t elems)
{
    loadMeshJson(json, shape);
    const modeCmd  = mode == "poly" ? "select.polygon" : "select.vertex";

    void seed() { postCmd(modeCmd); postCmd("select.drop"); postCmd("select.invert"); }

    double[] xs;
    foreach (_; 0 .. gReps) {
        seed();
        auto sw = StopWatch(AutoStart.yes);
        postCmd("select.loop");
        xs ~= sw.peek.total!"usecs".to!double / 1000.0;
    }
    const m = median(xs);
    gRows ~= Row(shape, mode, elems, m);
    writefln("  %-10s %-5s %7d elems   median %9.1f ms   raw %s",
             shape, mode, elems, m, xs.map!(x => format("%.0f", x)).array.join(" "));
}

int main(string[] args)
{
    string[] only;
    for (size_t i = 1; i < args.length; ++i) {
        switch (args[i]) {
            case "--port":  gPort = args[++i].to!int; break;
            case "--reps":  gReps = args[++i].to!int; break;
            case "--bin":   gBin  = args[++i]; break;
            case "--only":  only ~= args[++i]; break;
            default: stderr.writefln("unknown arg: %s", args[i]); return 2;
        }
    }

    auto pid = spawnProcess([gBin, "--test", "--http-port", gPort.to!string],
                            std.stdio.stdin,
                            File("/dev/null","w"), File("/dev/null","w"));
    // Kill ONLY the child we spawned, by PID. (D forbids try/catch directly
    // inside scope(exit) — hence the nested function.)
    void teardown() { try { kill(pid); wait(pid); } catch (Exception) {} }
    scope(exit) teardown();

    bool up = false;
    foreach (_; 0 .. 200) {
        auto r = execute(["curl","-s","-o","/dev/null","-w","%{http_code}", url("/api/camera")]);
        if (r.status == 0 && r.output.strip == "200") { up = true; break; }
        Thread.sleep(150.msecs);
    }
    if (!up) { stderr.writeln("vibe3d did not come up"); return 1; }

    writefln("perf_select_loop: bin=%s reps=%d port=%d", gBin, gReps, gPort);

    bool want(string s) { if (!only.length) return true;
                          foreach (o; only) if (o == s) return true; return false; }

    // Polygon mode on triangulated grids: every triangle is its own seed group.
    foreach (n; [30, 60, 90, 120]) {
        const tag = format("tri%d", n);
        if (!want(tag)) continue;
        benchCase(tag, "poly", triGrid(n), 2UL * n * n);
    }
    // Vertex mode on many small components.
    foreach (k; [1000, 8000]) {
        const tag = format("dq%d", k);
        if (!want(tag)) continue;
        benchCase(tag, "vert", disjointQuads(k), 4UL * k);
    }
    // Vertex mode on the connected grid (the case the rewrite made 13x faster —
    // must not regress) and polygon mode on disjoint quads.
    foreach (n; [100, 200]) {
        const tag = format("grid%d", n);
        if (!want(tag)) continue;
        benchCase(tag, "vert", triGrid(n), cast(size_t)((n+1)*(n+1)));
    }
    // The connected QUAD grid: the shape the recovered walk made much faster
    // than the walk it replaced. It must stay that way.
    foreach (n; [100, 200]) {
        const tag = format("qgrid%d", n);
        if (!want(tag)) continue;
        benchCase(tag, "vert", quadGrid(n), cast(size_t)((n+1)*(n+1)));
    }
    foreach (k; [1000, 8000]) {
        const tag = format("dqp%d", k);
        if (!want(tag)) continue;
        benchCase(tag, "poly", disjointQuads(k), cast(size_t)k);
    }

    writeln("\n--- summary (median ms) ---");
    foreach (r; gRows)
        writefln("%-10s %-5s %7d  %9.1f", r.shape, r.mode, r.elems, r.ms);
    return 0;
}
