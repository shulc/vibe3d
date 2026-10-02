// `run.d viewport` — the frame-cost table per scene x style x smooth x cavity x
// idle/orbit (model M7, wave plan SP). NOT A GATE and makes NO time comparison
// of any kind: budgets (fps, ms per style) are an owner decision these numbers
// only inform. The exit code is lane health only — a refused command, a failed
// premise, fewer than 8 harvested GPU frames in a window, or the timer
// unavailable on a desktop host.
//
// "idle" here is `--test`'s steady re-render of an unchanged scene (every cell
// renders every frame), i.e. the per-frame cost of the style — NOT production
// idle, where the per-cell dirty key renders nothing.
module lib.viewport_lane;

import std.algorithm : sort, canFind, min, max;
import std.array     : appender, join;
import std.conv      : to;
import std.format    : format;
import std.json      : parseJSON, JSONValue, JSONType;
import std.net.curl  : get, post;
import std.stdio     : write, writeln, writefln, stdout, stderr;
import std.string    : toLower;
import core.thread   : Thread;
import core.time     : msecs;

import lib.http;
import lib.drag      : fetchCamera, buildOrbitLog;
import lib.lifecycle : killStaleVibe, launchVibe;
import lib.baseline  : currentHeader;
import lib.history   : appendHistory;

enum int kIdleFrames = 120;
enum int kOrbitSteps = 60;
enum long kMinHarvested = 8;
static immutable string[4] kUploadCats =
    ["uploadFull", "uploadPositions", "uploadSelectedVerts", "uploadNonFace"];

struct ViewportRow {
    string scene, style, smooth, cavity, mode;
    bool ok;
    string detail;
    long faces;
    long cpuP50, cpuP95, drawP95;     // ns
    double gpuMean = 0, gpuP95 = 0;   // ns, summed over rendered cells
    string[3] topSeg;
    double[3] topNs = [0, 0, 0];
    long drawCalls, drawVerts;
    double[4] uploadMs = [0, 0, 0, 0];
    long harvested, dropped, cells;
}

private JSONValue getJ(string path) {
    return parseJSON(cast(string) get(g_baseUrl ~ path));
}

/// POST a command; "" on ok, else the refusal text.
private string command(string id, string params = null) {
    string body_ = params.length ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
                                 : `{"id":"` ~ id ~ `"}`;
    try {
        auto j = parseJSON(cast(string) post(g_baseUrl ~ "/api/command", body_));
        if ("status" in j && j["status"].str == "ok") return "";
        return j.toString;
    } catch (Exception e) {
        return e.msg;
    }
}

private long mainFrame() { return getJ("/api/play-events/status")["frame"].integer; }

private void waitFrames(long n) {
    immutable long start = mainFrame();
    foreach (i; 0 .. 6000) {
        if (mainFrame() >= start + n) return;
        Thread.sleep(2.msecs);
    }
    throw new Exception(format("the main loop did not advance %d frames", n));
}

/// Past the GPU ring and past a transient: a heavy upload can put the GPU more
/// frames behind than the ring holds, and those frames are DROPPED (counted).
/// Wait (up to kSettleSeconds of wall clock) until a 30-frame span adds no drop
/// to any cell, so a window opens on steady state. `--perf` runs the loop with
/// vsync off and nothing else throttles it, so where the GPU is slower than the
/// CPU loop the lag grows without bound and no span is drop-free: the row is
/// then an ERROR naming that, not a number.
enum int kSettleSeconds = 10;

private bool settleGpu() {
    import core.time : MonoTime, seconds;
    long drops() {
        long d;
        foreach (c; getJ("/api/viewport/display")["cells"].array)
            d += c["gpuTiming"]["framesDropped"].integer;
        return d;
    }
    waitFrames(getJ("/api/viewport/display")["cells"].array[0]["gpuTiming"]["ringFrames"].integer + 4);
    immutable deadline = MonoTime.currTime + kSettleSeconds.seconds;
    while (MonoTime.currTime < deadline) {
        immutable long d0 = drops();
        waitFrames(30);
        if (drops() == d0) return true;
    }
    return false;
}

private struct Scene { string name; string[] setup; }

private Scene[] scenes() {
    return [
        Scene("grid1m",   [`scene.reset|{"type":"grid","n":708}`, `viewport.layout|"Single"`]),
        Scene("subpatch", [`scene.reset|{"type":"subdivcube","levels":3}`,
                           `viewport.layout|"Single"`, `mesh.subpatch_toggle|`]),
        Scene("quad",     [`scene.reset|{"type":"grid","n":316}`, `viewport.layout|"Quad"`]),
    ];
}

private struct Snap {
    JSONValue[] gpu;   // per cell gpuTiming
    bool[] renders;
}

private Snap snap() {
    Snap s;
    foreach (c; getJ("/api/viewport/display")["cells"].array) {
        s.gpu ~= c["gpuTiming"];
        s.renders ~= c["renders"].type == JSONType.TRUE;
    }
    return s;
}

private double pct(double[] xs, int p) {
    if (xs.length == 0) return 0;
    auto c = xs.dup;
    c.sort();
    return c[(c.length - 1) * p / 100];
}

/// Fill the GPU columns of `r` from two display reads around the window.
private void gpuColumns(ref ViewportRow r, Snap a, Snap b) {
    double[string] segNs;
    double[][] series;
    foreach (i; 0 .. b.gpu.length) {
        if (!b.renders[i]) continue;
        ++r.cells;
        auto ga = a.gpu[i], gb = b.gpu[i];
        if (gb["available"].type != JSONType.TRUE)
            throw new Exception("GPU timer unavailable: " ~ gb["reason"].str);
        immutable long h = gb["framesHarvested"].integer - ga["framesHarvested"].integer;
        r.dropped += gb["framesDropped"].integer - ga["framesDropped"].integer;
        r.harvested = r.cells == 1 ? h : min(r.harvested, h);
        long lastSeq = 0;
        foreach (e; ga["recent"].array) lastSeq = max(lastSeq, e.array[0].integer);
        double[] cellSeries;
        foreach (e; gb["recent"].array)
            if (e.array[0].integer > lastSeq) cellSeries ~= cast(double) e.array[1].integer;
        series ~= cellSeries;
        foreach (k, v; gb["segments"].object) {
            immutable double d = v["sumNs"].integer - ga["segments"][k]["sumNs"].integer;
            segNs[k] = (k in segNs ? segNs[k] : 0) + (h > 0 ? d / h : 0);
        }
    }
    // Per-frame totals summed over cells, aligned from the newest frame.
    size_t n = size_t.max;
    foreach (s; series) n = min(n, s.length);
    if (series.length == 0 || n == 0) return;
    double[] summed = new double[n];
    summed[] = 0;
    foreach (s; series) foreach (k; 0 .. n) summed[k] += s[$ - n + k];
    double sum = 0;
    foreach (x; summed) sum += x;
    r.gpuMean = sum / n;
    r.gpuP95 = pct(summed, 95);
    auto keys = segNs.keys;
    keys.sort!((x, y) => segNs[x] > segNs[y]);
    foreach (k; 0 .. min(3, keys.length)) { r.topSeg[k] = keys[k]; r.topNs[k] = segNs[keys[k]]; }
}

private ViewportRow measure(Scene sc, string style, string smooth, string cavity,
                            string mode, long faces) {
    ViewportRow r = ViewportRow(sc.name, style, smooth, cavity, mode);
    r.faces = faces;
    try {
        // Every RENDERING cell gets the row's state (a Quad row sums them).
        foreach (k, c; getJ("/api/viewport/display")["cells"].array) {
            if (c["renders"].type != JSONType.TRUE) continue;
            immutable string vk = format(`,"viewport":%d`, k);
            string why = command("viewport.displayStyle", `{"value":"` ~ style ~ `"` ~ vk ~ `}`);
            if (why.length) throw new Exception("viewport.displayStyle refused: " ~ why);
            if (smooth != "n/a") {
                why = command("viewport.smooth", `{"value":"` ~ smooth ~ `"` ~ vk ~ `}`);
                if (why.length) throw new Exception("viewport.smooth refused: " ~ why);
            }
            if (cavity != "n/a") {
                why = command("viewport.cavity", `{"value":"` ~ cavity ~ `"` ~ vk ~ `}`);
                if (why.length) throw new Exception("viewport.cavity refused: " ~ why);
            }
        }
        if (!settleGpu())
            throw new Exception(format("GPU never settled: frames still dropped after %ds — "
                ~ "the unthrottled --perf loop outruns the GPU by more than the ring", kSettleSeconds));
        // Premise FIRST: every rendering cell's active plan is the requested style.
        foreach (k, c; getJ("/api/viewport/display")["cells"].array) {
            if (c["renders"].type != JSONType.TRUE) continue;
            if (c["state"]["active"]["style"].str.toLower != style)
                throw new Exception(format("premise: cell %d style is %s", k,
                                           c["state"]["active"]["style"].str));
            if ((style == "wireframe") == (c["plan"]["active"]["drawFaces"].type == JSONType.TRUE))
                throw new Exception(format("premise: cell %d drawFaces disagrees with %s", k, style));
            if (smooth != "n/a" && "smooth" in c["state"]["active"].object
                && (c["state"]["active"]["smooth"].type == JSONType.TRUE) != (smooth == "on"))
                throw new Exception(format("premise: cell %d smooth state is not %s", k, smooth));
        }

        auto a = snap();
        perfReset();
        framesReset();
        if (mode == "idle") {
            waitFrames(kIdleFrames);
        } else {
            auto cam = fetchCamera();
            string log = buildOrbitLog(cam.vpX, cam.vpY, cam.width, cam.height,
                cam.vpX + cast(int)(cam.width * 0.20), cam.vpY + cast(int)(cam.height * 0.55),
                cam.vpX + cast(int)(cam.width * 0.80), cam.vpY + cast(int)(cam.height * 0.20),
                kOrbitSteps);
            playAndWait(log);
        }
        auto fr = getJ("/api/frames");
        auto perf = perfRead();
        auto counts = getJ("/api/frames/counts")["lastScene"];
        auto b = snap();
        if ("frameCount" !in fr) throw new Exception("/api/frames is empty: not a --build=perf binary");
        r.cpuP50 = fr["total"]["p50_ns"].integer;
        r.cpuP95 = fr["total"]["p95_ns"].integer;
        r.drawP95 = fr["phases"]["drawNs"]["p95_ns"].integer;
        r.drawCalls = counts["drawCalls"].integer;
        r.drawVerts = counts["drawVerts"].integer;
        foreach (i, cat; kUploadCats)
            r.uploadMs[i] = (cat in perf ? perf[cat]["sum_ns"].integer : 0) / 1e6;
        gpuColumns(r, a, b);
        if (r.harvested < kMinHarvested)
            throw new Exception(format("only %d GPU frames harvested in the window", r.harvested));
        r.ok = true;
    } catch (Exception e) {
        r.ok = false;
        r.detail = e.msg;
    }
    return r;
}

private string rowKey(const ref ViewportRow r) {
    return format("%s/%s/%s/%s/%s", r.scene, r.style, r.smooth, r.cavity, r.mode);
}

void printViewportTable(ViewportRow[] rows) {
    writeln();
    writeln("viewport frame cost — NOT a gate; no time comparison (owner budgets).");
    writeln("idle = --test steady re-render of an unchanged scene (every frame renders), not production idle.");
    writeln("GPU = GL_TIME_ELAPSED per frame summed over rendered cells; CPU = /api/frames total; draw = drawNs p95.");
    writefln("%-9s %-9s %-4s %-6s %-5s %8s %8s %8s %9s %9s  %-34s %7s %9s %8s %8s",
             "scene", "style", "smth", "cavity", "mode", "cpu p50", "cpu p95", "draw p95",
             "gpu mean", "gpu p95", "top segments (mean us)", "calls", "verts",
             "upl ms", "harv/dr");
    foreach (r; rows) {
        if (!r.ok) {
            writefln("%-9s %-9s %-4s %-6s %-5s  ERROR: %s", r.scene, r.style, r.smooth,
                     r.cavity, r.mode, r.detail);
            continue;
        }
        string top;
        foreach (k; 0 .. 3) if (r.topSeg[k].length)
            top ~= format("%s%s %.0f", k ? ", " : "", r.topSeg[k], r.topNs[k] / 1e3);
        double upl = 0;
        foreach (u; r.uploadMs) upl += u;
        writefln("%-9s %-9s %-4s %-6s %-5s %6.2fms %6.2fms %6.2fms %7.3fms %7.3fms  %-34s %7d %9d %8.2f %4d/%d",
                 r.scene, r.style, r.smooth, r.cavity, r.mode,
                 r.cpuP50 / 1e6, r.cpuP95 / 1e6, r.drawP95 / 1e6,
                 r.gpuMean / 1e6, r.gpuP95 / 1e6, top, r.drawCalls, r.drawVerts,
                 upl, r.harvested, r.dropped);
    }
}

void writeViewportJson(string path, ViewportRow[] rows) {
    static import std.file;
    auto a = appender!string();
    a.put(`{"rows":[`);
    foreach (i, r; rows) {
        if (i) a.put(",");
        a.put(format(`{"key":"%s","ok":%s,"detail":%s,"faces":%d,"cpuP50Ns":%d,"cpuP95Ns":%d,`
            ~ `"drawP95Ns":%d,"gpuMeanNs":%.0f,"gpuP95Ns":%.0f,"top":[`,
            rowKey(r), r.ok, JSONValue(r.detail).toString, r.faces, r.cpuP50, r.cpuP95,
            r.drawP95, r.gpuMean, r.gpuP95));
        foreach (k; 0 .. 3)
            a.put(format(`%s["%s",%.0f]`, k ? "," : "", r.topSeg[k], r.topNs[k]));
        a.put(format(`],"drawCalls":%d,"drawVerts":%d,"uploadMs":[%.3f,%.3f,%.3f,%.3f],`
            ~ `"harvested":%d,"dropped":%d,"cells":%d}`, r.drawCalls, r.drawVerts,
            r.uploadMs[0], r.uploadMs[1], r.uploadMs[2], r.uploadMs[3],
            r.harvested, r.dropped, r.cells));
    }
    a.put("]}\n");
    std.file.write(path, a.data);
}

int runViewportSubcommand(string repoRoot, string viewport, ushort port, string[] requested) {
    import std.path : buildPath;
    killStaleVibe(port);
    string logPath = "/var/tmp/vibe3d_perf_viewport.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...", port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    const ids = registryCommands();
    immutable bool hasSmooth = ids.canFind("viewport.smooth");
    immutable bool hasCavity = ids.canFind("viewport.cavity");
    string[] smooths = hasSmooth ? ["on", "off"] : ["n/a"];
    string[] cavities = hasCavity ? ["off", "screen", "world"] : ["n/a"];
    if (!hasCavity) writeln("  cavity: n/a (command absent)");
    if (!hasSmooth) writeln("  smooth: n/a (command absent)");
    static immutable string[4] styles = ["wireframe", "solid", "shaded", "weight"];

    ViewportRow[] rows;
    int unhealthy;
    foreach (sc; scenes()) {
        if (requested.length && !requested.canFind!((q) => sc.name.canFind(q))) continue;
        string why;
        foreach (step; sc.setup) {
            import std.string : indexOf;
            immutable p = step.indexOf('|');
            why = command(step[0 .. p], step[p + 1 .. $]);
            if (why.length) { why = step[0 .. p] ~ " refused: " ~ why; break; }
        }
        if (!why.length && sc.name == "subpatch") {
            Thread.sleep(3000.msecs);   // OSD preview live before the window opens
        }
        immutable long faces = why.length ? 0 : modelInfo().faceCount;
        writefln("scene %s: %d faces%s", sc.name, faces, why.length ? " — " ~ why : "");
        foreach (style; styles) foreach (sm; smooths) foreach (cv; cavities)
        foreach (mode; ["idle", "orbit"]) {
            ViewportRow r;
            if (why.length) {
                r = ViewportRow(sc.name, style, sm, cv, mode);
                r.detail = why;
            } else {
                write("  ", sc.name, " ", style, " ", sm, " ", cv, " ", mode, " ... ");
                stdout.flush();
                r = measure(sc, style, sm, cv, mode, faces);
                writeln(r.ok ? "OK" : "ERROR (" ~ r.detail ~ ")");
            }
            if (!r.ok) ++unhealthy;
            rows ~= r;
        }
    }
    if (rows.length == 0) {
        stderr.writefln("no viewport scenes matched %s — nothing was measured", requested);
        return 1;
    }
    printViewportTable(rows);
    string outPath = buildPath(repoRoot, "tools", "perf", "viewport_results.json");
    writeViewportJson(outPath, rows);
    writeln("\nWrote ", outPath);

    double[string] medians;
    foreach (r; rows) if (r.ok) {
        medians[rowKey(r) ~ "#gpuMeanUs"] = r.gpuMean / 1e3;
        medians[rowKey(r) ~ "#cpuP50Us"] = r.cpuP50 / 1e3;
    }
    appendHistory(repoRoot, currentHeader("viewport", 0, 0, viewport, 1), medians, "viewport");
    writefln("lane health: %d of %d rows OK", rows.length - unhealthy, rows.length);
    return unhealthy == 0 ? 0 : 1;
}
