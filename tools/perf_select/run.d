#!/usr/bin/env rdmd
/**
 * perf_select — deterministic micro-benchmark for the selection + viewport-fit
 * command family on a DENSE quad mesh (task 0388).
 *
 * Reproduces the owner's "select more / fit selection are VERY slow on a dense
 * ai3d mesh" report with a synthetic N×N quad grid, and guards against the
 * O(n²) regression that motivated the task: several selection commands used to
 * index the `mesh.selectedX` @property (which materializes a fresh `bool[]` per
 * read) INSIDE a `0 .. length` loop, making a single command O(faces²) — ~6 s
 * on a 100 K-face grid for `viewport.fit_selected` with a region selected.
 *
 * It drives a real `vibe3d --test` over HTTP (same transport the other perf
 * tools use): load a fixed grid via /api/load-mesh, seed a deterministic
 * selection, then wall-clock each command via curl's %{time_total}. The HTTP
 * bridge signals completion right after the command's apply(), so the timing is
 * the command-apply cost (plus a ~1-frame floor, reported via a no-op baseline).
 *
 *   rdmd tools/perf_select/run.d              # N=316 (~100K faces), reuse ./vibe3d
 *   rdmd tools/perf_select/run.d --n 200      # smaller grid
 *   rdmd tools/perf_select/run.d --build      # `dub build` first (modeling)
 *   rdmd tools/perf_select/run.d --port 8397  # custom port
 *   rdmd tools/perf_select/run.d --reps 9     # more repetitions per command
 *
 * Requires `curl` on PATH. Not a gating suite — a human reads the numbers.
 */
import std.stdio;
import std.process;
import std.conv       : to;
import std.string     : strip, startsWith;
import std.algorithm  : sort, map, filter;
import std.array      : appender, array, join;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.thread    : Thread;
import core.time      : msecs, seconds;
import std.file       : write, tempDir, remove, exists;
import std.path       : buildPath;
import std.format     : format;

int gPort = 8396;
int gN    = 316;
int gReps = 7;
bool gBuild = false;
string gBin = "./vibe3d";

string url(string path) { return format("http://127.0.0.1:%d%s", gPort, path); }

// curl a POST /api/command with an optional _positional array; returns time in ms.
double postCmd(string id, string[] positional = null)
{
    auto app = appender!string();
    app.put(`{"id":"`); app.put(id); app.put(`"`);
    if (positional.length) {
        app.put(`,"_positional":[`);
        foreach (i, p; positional) {
            if (i) app.put(",");
            // numbers passed as-is; anything non-numeric quoted
            bool numeric = p.length && (p[0] == '-' || (p[0] >= '0' && p[0] <= '9'));
            if (numeric) app.put(p);
            else { app.put(`"`); app.put(p); app.put(`"`); }
        }
        app.put(`]`);
    }
    app.put(`}`);
    auto r = execute(["curl","-s","-o","/dev/null","-w","%{time_total}",
                      "-H","Content-Type: application/json",
                      "--data-binary", app.data, url("/api/command")]);
    if (r.status != 0) throw new Exception("curl failed: " ~ r.output);
    return r.output.strip.to!double * 1000.0;
}

string getSelection()
{
    auto r = execute(["curl","-s", url("/api/selection")]);
    return r.output;
}

// Build the N×N grid mesh JSON and POST it to /api/load-mesh from a temp file.
void loadGrid(int n)
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

    string tmp = buildPath(tempDir(), format("perf_select_grid_%d.json", n));
    write(tmp, v.data);
    scope(exit) if (exists(tmp)) remove(tmp);
    auto sw = StopWatch(AutoStart.yes);
    auto rr = execute(["curl","-s","-o","/dev/null","--max-time","300",
                       "-H","Content-Type: application/json",
                       "--data-binary","@" ~ tmp, url("/api/load-mesh")]);
    if (rr.status != 0) throw new Exception("load-mesh curl failed: " ~ rr.output);
    writefln("  load-mesh: %.0f ms", sw.peek.total!"msecs".to!double);
}

double median(double[] xs)
{
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    return s[$/2];
}

// Time `body` `gReps` times, print label + median + raw. `seed` runs before
// each rep (untimed) to restore preconditions.
void bench(string label, void delegate() seed, void delegate() body_)
{
    double[] xs;
    foreach (_; 0 .. gReps) {
        if (seed !is null) seed();
        auto sw = StopWatch(AutoStart.yes);
        body_();
        xs ~= sw.peek.total!"usecs".to!double / 1000.0;
    }
    writefln("  %-34s median %8.2f ms   raw %s",
             label, median(xs),
             xs.map!(x => format("%.1f", x)).array.join(" "));
}

int main(string[] args)
{
    for (size_t i = 1; i < args.length; ++i) {
        switch (args[i]) {
            case "--n":     gN = args[++i].to!int; break;
            case "--port":  gPort = args[++i].to!int; break;
            case "--reps":  gReps = args[++i].to!int; break;
            case "--build": gBuild = true; break;
            case "--bin":   gBin = args[++i]; break;
            default: stderr.writefln("unknown arg: %s", args[i]); return 2;
        }
    }

    if (gBuild) {
        writeln("building (dub build, modeling)...");
        auto b = execute(["dub","build","--config=modeling"]);
        if (b.status != 0) { stderr.writeln(b.output); return 1; }
    }

    // Kill any stale test instance on our port pattern, then launch.
    execute(["pkill","-x","vibe3d"]);
    Thread.sleep(500.msecs);
    auto pid = spawnProcess([gBin, "--test", "--http-port", gPort.to!string],
                            std.stdio.stdin,
                            File("/dev/null","w"), File("/dev/null","w"));
    void teardown() { try { kill(pid); wait(pid); } catch (Exception) {} }
    scope(exit) teardown();

    // Wait for HTTP.
    bool up = false;
    foreach (_; 0 .. 100) {
        auto r = execute(["curl","-s","-o","/dev/null","-w","%{http_code}", url("/api/camera")]);
        if (r.status == 0 && r.output.strip == "200") { up = true; break; }
        Thread.sleep(150.msecs);
    }
    if (!up) { stderr.writeln("vibe3d did not come up"); return 1; }

    writefln("perf_select: N=%d grid (%d faces), reps=%d, port=%d",
             gN, gN*gN, gReps, gPort);
    loadGrid(gN);

    // Polygon mode; seed two adjacent faces (0,1) with a selection order.
    postCmd("select.polygon");
    postCmd("select.element", ["polygon","set","0","1"]);

    // A ~no-op selection write: exposes the HTTP+frame floor to subtract.
    bench("baseline (select.element set 0,1)",
          null, () { postCmd("select.element", ["polygon","set","0","1"]); });

    // select.more — re-seed the 2-face ordered selection before each rep.
    bench("select.more",
          () { postCmd("select.element", ["polygon","set","0","1"]); },
          () { postCmd("select.more"); });

    // fit_selected with a small region selected (the O(n²) trigger).
    postCmd("select.element", ["polygon","set","0","1"]);
    bench("viewport.fit_selected (region)",
          () { postCmd("select.element", ["polygon","set","0","1"]); },
          () { postCmd("viewport.fit_selected"); });

    // fit_selected with nothing selected (whole-mesh frame).
    bench("viewport.fit_selected (whole mesh)",
          () { postCmd("select.drop"); },
          () { postCmd("viewport.fit_selected"); });

    // Sibling selection-family ops that shared the same O(n²) pattern.
    bench("select.expand (from region)",
          () { postCmd("select.element", ["polygon","set","0","1"]); },
          () { postCmd("select.expand"); });
    bench("select.contract (from expanded)",
          () { postCmd("select.element", ["polygon","set","0","1"]);
               foreach (_; 0 .. 3) postCmd("select.expand"); },
          () { postCmd("select.contract"); });
    bench("select.invert",
          () { postCmd("select.element", ["polygon","set","0","1"]); },
          () { postCmd("select.invert"); });

    return 0;
}
