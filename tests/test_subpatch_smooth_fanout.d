// The GPU subpatch fan-out writes the face VBO's smooth stream (viewport
// shading S1c, task 9090; model M3, second producer): a subpatch preview
// dragged through the transform-feedback fan-out must draw the SAME smooth
// normals the CPU writers give the same surface. Cross-path cells: mid-drag
// (written by `gpuFanOut`, the positive control) vs the same geometry after a
// CPU rebake (`fullUpload`) — per face corner from `/api/gpu/face-vbo` and per
// pixel. The creased cage puts a hard rim on a curved surface, so the
// smoothing-angle test decides corners there.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max, min;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round;
import http_client : frameFence;
import std.stdio : writefln;

void main() {}

/// `VIBE3D_CELL=<id>` runs one cell (druntime stops a module at its first
/// failed assert, so a mutation that must redden two cells runs them apart).
bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok",
           "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }

void select(string mode, int[] indices) {
    string body = `{"mode":"` ~ mode ~ `","indices":[`;
    foreach (i, idx; indices) {
        if (i) body ~= ",";
        body ~= idx.to!string;
    }
    body ~= "]}";
    cmd(commandBody("mesh.select", body));
}

void waitPreviewSettled(bool wantActive = true, int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        auto p = getJson("/api/subpatch/preview");
        if ((p["active"].type == JSONType.true_) == wantActive
            && p["pending"].type != JSONType.true_)
        {
            frameFence(null, 2);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview did not settle");
}

double[3] triple(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double maxAbs3(double[3] a, double[3] b) {
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]));
}

/// Cube cage with a subpatch preview over every face; `crease` sets weight 1
/// on the four rim edges of the top face (3,7,6,2) — a hard rim on a
/// curved surface. Vertex mode, the back face's four corners selected.
void prepareScene(bool crease) {
    cmd(commandBody("scene.reset"));
    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr symmetry enabled false");
    if (crease) {
        immutable uint[4] top = [3, 7, 6, 2];
        bool onTop(long v) { foreach (t; top) if (t == v) return true; return false; }
        int[] rim;
        foreach (i, e; getJson("/api/model")["edges"].array)
            if (onTop(e.array[0].integer) && onTop(e.array[1].integer)) rim ~= cast(int)i;
        assert(rim.length == 4, format("creased cage: %d rim edges on the top face, expected 4", rim.length));
        cmd("select.typeFrom edge");
        select("edges", rim);
        cmd(`{"id":"mesh.edgeCrease.set","params":{"weight":1.0}}`);
    }
    cmd("select.typeFrom polygon");
    select("polygons", []);
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled();
    cmd("select.typeFrom vertex");
    select("vertices", [0, 1, 2, 3]);
    // Close in: the surface spans a few hundred px, the gizmo stays 120.
    auto r = postJson("/api/camera", `{"distance":1.5,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera write failed: " ~ r.toString);
    frameFence(null, 2);
}

struct PreviewState { string writer; bool fannedOut; }

PreviewState previewState() {
    auto j = getJson("/api/subpatch/preview");
    return PreviewState(j["displayWriter"].str,
                        j["lastRefreshFannedOut"].type == JSONType.true_);
}

int[3][] probe(int[2][] pts) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
    assert(j["renders"].type == JSONType.true_, "cell 0 must be rendering");
    int[3][] r;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        r ~= [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
    }
    return r;
}

/// Twelve viewport pixels on the surface: the first twelve of a 6 x 5 grid
/// over the middle 60 % of the projected bounding box of the face-VBO
/// corners that lie farther than `kGizmoClearPx` from the gizmo centre
/// (`hx`, `hy`, window px) — the held move gizmo draws over the surface.
enum double kGizmoClearPx = 140;
int[2][] surfacePixels(JSONValue vbo, CameraState c, double hx, double hy) {
    import std.math : hypot;
    auto vp = viewportFromCamera(c);
    double x0 = double.max, y0 = double.max, x1 = -double.max, y1 = -double.max;
    foreach (p; vbo["positions"].array) {
        auto a = triple(p);
        float px, py;
        if (!projectToWindow(Vec3(cast(float)a[0], cast(float)a[1], cast(float)a[2]), vp, px, py))
            continue;
        x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py);
    }
    assert(x1 > x0 + 100 && y1 > y0 + 100,
        format("the preview projects to a %.0f x %.0f px box: too small to probe", x1 - x0, y1 - y0));
    int[2][] pts;
    foreach (j; 0 .. 5)
        foreach (i; 0 .. 6) {
            immutable double wx = x0 + (x1 - x0) * (0.2 + 0.6 * i / 5.0);
            immutable double wy = y0 + (y1 - y0) * (0.2 + 0.6 * j / 4.0);
            if (hypot(wx - hx, wy - hy) < kGizmoClearPx || pts.length == 12) continue;
            pts ~= [cast(int)round(wx) - c.vpX, cast(int)round(wy) - c.vpY];
        }
    return pts;
}

struct Capture { JSONValue vbo; int[3][] px; }

/// Drag the selection along the gizmo's first arm, hold, read the face VBO
/// and the pixels written by the fan-out; release without further motion
/// and rebake on the CPU (subpatch off and on: a full upload of the same
/// surface); read again.
void runCell(string label, bool crease) {
    prepareScene(crease);
    cmd("tool.set move on");
    frameFence(null, 2);
    auto c = fetchCamera();
    double cx, cy, gx, gy;
    bool found;
    fetchHandlePart(3, cx, cy, found);
    assert(found, label ~ ": centre handle missing");
    fetchHandlePart(0, gx, gy, found);
    assert(found, label ~ ": grab handle missing");
    immutable int x0 = cast(int)(gx + 0.5), y0 = cast(int)(gy + 0.5);
    immutable int x1 = x0 + 50, y1 = y0 - 40;
    playAndWait(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playAndWait(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x1, y1, 8));
    frameFence(null, 2);
    // Positive control FIRST [E10]: the payload on screen was written by the
    // GPU fan-out, else nothing below witnesses it.
    auto mid = previewState();
    if (mid.writer != "gpuFanOut")
        assert(false, format("%s: fan-out never ran: cell cannot witness (mid-drag writer %s, fannedOut %s)",
                             label, mid.writer, mid.fannedOut));
    double hx, hy;
    fetchHandlePart(3, hx, hy, found);
    assert(found, label ~ ": centre handle missing mid-drag");
    Capture gpu;
    gpu.vbo = getJson("/api/gpu/face-vbo?normals=1");
    auto pts = surfacePixels(gpu.vbo, c, hx, hy);
    gpu.px = probe(pts);
    playAndWait(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x1, y1));
    cmd("tool.set move off");
    waitPreviewSettled();
    writefln("[%s] after release: writer %s", label, previewState().writer);
    // CPU rebake: subpatch off, then on again over every face.
    cmd("select.typeFrom polygon");
    select("polygons", []);
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled(false);
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled();
    auto after = previewState();
    assert(after.writer == "fullUpload",
        format("%s: the rebake was not a CPU full upload (writer %s)", label, after.writer));
    Capture cpu;
    cpu.vbo = getJson("/api/gpu/face-vbo?normals=1");
    cpu.px = probe(pts);

    // Face corners: population floor first [E4], positions (premise: the
    // same surface), then the pixels (the cross-path witness), then both
    // normal streams per corner.
    immutable size_t n = cast(size_t)gpu.vbo["faceVertCount"].integer;
    assert(n == kPreviewCorners && cast(size_t)cpu.vbo["faceVertCount"].integer == n
        && gpu.vbo["smoothNormals"].array.length == n && cpu.vbo["smoothNormals"].array.length == n,
        format("%s floor: faceVertCount %d / %d, smoothNormals %d / %d (expected %d corners)", label, n,
               cpu.vbo["faceVertCount"].integer, gpu.vbo["smoothNormals"].array.length,
               cpu.vbo["smoothNormals"].array.length, kPreviewCorners));
    double dPos = 0, dFlat = 0, dSmooth = 0;
    size_t worst, smoothNotFlat;
    foreach (i; 0 .. n) {
        dPos = max(dPos, maxAbs3(triple(gpu.vbo["positions"].array[i]), triple(cpu.vbo["positions"].array[i])));
        dFlat = max(dFlat, maxAbs3(triple(gpu.vbo["flatNormals"].array[i]), triple(cpu.vbo["flatNormals"].array[i])));
        immutable double d = maxAbs3(triple(gpu.vbo["smoothNormals"].array[i]),
                                     triple(cpu.vbo["smoothNormals"].array[i]));
        if (d > dSmooth) { dSmooth = d; worst = i; }
        if (maxAbs3(triple(cpu.vbo["smoothNormals"].array[i]), triple(cpu.vbo["flatNormals"].array[i])) > 1e-3)
            ++smoothNotFlat;
    }
    writefln("[%s] %d corners: max |gpu-cpu| position %.2e, flat %.2e, smooth %.2e (corner %d); %d smooth != flat",
             label, n, dPos, dFlat, dSmooth, worst, smoothNotFlat);
    assert(dPos <= 1e-4, format("%s premise: mid-drag and rebaked surfaces differ by %.2e", label, dPos));
    assert(smoothNotFlat > n / 2,
        format("%s floor: only %d of %d corners have smooth != flat — the cell cannot see the stream", label,
               smoothNotFlat, n));
    // Pixels: population floor [E4], then every probe within +-1 level.
    assert(pts.length == 12 && gpu.px.length == 12 && cpu.px.length == 12,
        format("%s floor: %d probe points", label, pts.length));
    int worstPx;
    foreach (k; 0 .. 12) foreach (ch; 0 .. 3) worstPx = max(worstPx, abs(gpu.px[k][ch] - cpu.px[k][ch]));
    writefln("[%s] 12 pixels: max |gpu-cpu| %d levels; gpu %s cpu %s", label, worstPx, gpu.px, cpu.px);
    foreach (k; 0 .. 12)
        foreach (ch; 0 .. 3)
            assert(abs(gpu.px[k][ch] - cpu.px[k][ch]) <= 1,
                format("%s: pixel %s channel %d reads %d mid-drag (GPU fan-out), %d after the CPU rebake",
                       label, pts[k], ch, gpu.px[k][ch], cpu.px[k][ch]));

    // Then the streams themselves, per corner (a GPU/CPU difference too small
    // to move a probed pixel by a level still reddens here).
    assert(dFlat <= 1e-4, format("%s: the fan-out's flat normals differ from the CPU writer's by %.2e", label, dFlat));
    assert(dSmooth <= 1e-4,
        format("%s: corner %d smooth normal %s from the GPU fan-out, %s from the CPU writer (|d| %.2e)", label,
               worst, triple(gpu.vbo["smoothNormals"].array[worst]), triple(cpu.vbo["smoothNormals"].array[worst]),
               dSmooth));
}

/// Face corners of the cube cage's preview at the shipped depth: measured.
enum size_t kPreviewCorners = 2304;   // 6 faces x 8 x 8 quads x 6 fan corners (depth 3)

unittest {
    if (cellOn("smooth")) runCell("smooth", false);
}

unittest {
    if (cellOn("crease")) runCell("crease", true);
}
