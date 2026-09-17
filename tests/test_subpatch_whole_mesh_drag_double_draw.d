// Task 6450: a live subpatch preview and the whole-mesh transform fast path
// must not apply the same gesture twice to the displayed surface.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round, sqrt;
import std.stdio : writefln;

void main() {}

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

void waitPreviewSettled(int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        auto p = getJson("/api/subpatch/preview");
        if (p["active"].type == JSONType.true_
            && p["pending"].type != JSONType.true_)
        {
            Thread.sleep(80.msecs);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "6450: subpatch preview did not settle");
}

void playSettled(string log) {
    playAndWait(log);
    Thread.sleep(250.msecs);
}

string hoverLog(CameraState c, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
    foreach (i; 0 .. 5) {
        log ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            30 + i * 20, x, y);
    }
    return log;
}

double[16] jsonMatrix(JSONValue j, string key) {
    double[16] result;
    auto a = j[key].array;
    assert(a.length == 16, "6450: " ~ key ~ " matrix must have 16 values");
    foreach (i; 0 .. 16) result[i] = a[i].floating;
    return result;
}

double[3] applyModel(const ref double[16] m, JSONValue p) {
    auto a = p.array;
    return [m[0]*a[0].floating + m[4]*a[1].floating
                + m[8]*a[2].floating + m[12],
            m[1]*a[0].floating + m[5]*a[1].floating
                + m[9]*a[2].floating + m[13],
            m[2]*a[0].floating + m[6]*a[1].floating
                + m[10]*a[2].floating + m[14]];
}

struct SurfaceSample {
    double[3][] raw;
    double[3][] rendered;
    double[16] model;
}

SurfaceSample surfaceSample() {
    auto j = getJson("/api/gpu/face-vbo");
    SurfaceSample s;
    s.model = jsonMatrix(j, "model");
    foreach (p; j["positions"].array) {
        auto a = p.array;
        s.raw ~= [a[0].floating, a[1].floating, a[2].floating];
        s.rendered ~= applyModel(s.model, p);
    }
    assert(s.raw.length > 0, "6450: face VBO population must be non-zero");
    return s;
}

double maxPointDiff(const double[3][] a, const double[3][] b) {
    assert(a.length == b.length && a.length > 0,
           "6450: compared VBO populations must be equal and non-zero");
    double d = 0;
    foreach (i; 0 .. a.length) {
        double dx = a[i][0] - b[i][0];
        double dy = a[i][1] - b[i][1];
        double dz = a[i][2] - b[i][2];
        d = max(d, sqrt(dx*dx + dy*dy + dz*dz));
    }
    return d;
}

bool matrixIsIdentity(const ref double[16] m, double eps = 1e-6) {
    immutable double[16] ident =
        [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    foreach (i; 0 .. 16) if (abs(m[i] - ident[i]) > eps) return false;
    return true;
}

struct DragResult {
    double dragMoved;
    double releaseShift;
    double vboLive;
    double matrixExtra;
    double gizmoShift;
    double[16] midModel;
}

void prepareScene(bool subpatch, int[] selectedVerts = null,
                  bool hideOne = false)
{
    cmd(commandBody("scene.reset"));
    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr symmetry enabled false");
    if (subpatch) {
        cmd("select.typeFrom polygon");
        cmdId("mesh.subpatch_toggle");
        waitPreviewSettled();
        select("polygons", []);
    }
    cmd("select.typeFrom vertex");
    if (hideOne) {
        select("vertices", [0]);
        cmdId("mesh.hide");
        select("vertices", []);
    } else {
        select("vertices", selectedVerts);
    }
    Thread.sleep(150.msecs);
}

DragResult runDrag(string toolId, bool subpatch, int[] selectedVerts = null,
                   bool hideOne = false, int centrePart = 3,
                   int grabPart = 0, bool offsetGrab = false,
                   double offsetX = 0, double offsetY = 0,
                   int dragPx = 120, int steps = 16)
{
    prepareScene(subpatch, selectedVerts, hideOne);
    cmd("tool.set " ~ toolId ~ " on");
    Thread.sleep(300.msecs);
    auto c = fetchCamera();

    double cx, cy;
    bool found;
    fetchHandlePart(centrePart, cx, cy, found);
    assert(found, "6450: centre handle " ~ centrePart.to!string ~ " missing for " ~ toolId);
    double gx, gy;
    if (offsetGrab) {
        gx = cx + offsetX;
        gy = cy + offsetY;
    } else {
        fetchHandlePart(grabPart, gx, gy, found);
        assert(found, "6450: grab handle " ~ grabPart.to!string ~ " missing for " ~ toolId);
    }
    double vx = gx - cx, vy = gy - cy;
    double length = sqrt(vx*vx + vy*vy);
    assert(length > 1.0, "6450: drag direction collapsed for " ~ toolId);
    double ux = offsetGrab ? -vy / length : vx / length;
    double uy = offsetGrab ?  vx / length : vy / length;
    int x0 = cast(int)(gx + 0.5), y0 = cast(int)(gy + 0.5);
    int x1 = x0 + cast(int)(dragPx * ux + 0.5);
    int y1 = y0 + cast(int)(dragPx * uy + 0.5);

    auto rest = surfaceSample();
    playSettled(hoverLog(c, x0, y0));
    playSettled(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playSettled(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height,
                                   x0, y0, x1, y1, steps));
    auto mid = surfaceSample();
    double midCx, midCy;
    fetchHandlePart(centrePart, midCx, midCy, found);
    assert(found, "6450: centre handle disappeared mid-drag for " ~ toolId);
    playSettled(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x1, y1));
    if (subpatch) waitPreviewSettled();
    auto released = surfaceSample();
    double endCx, endCy;
    fetchHandlePart(centrePart, endCx, endCy, found);
    assert(found, "6450: centre handle disappeared after release for " ~ toolId);

    DragResult r;
    r.dragMoved = maxPointDiff(mid.rendered, rest.rendered);
    r.releaseShift = maxPointDiff(mid.rendered, released.rendered);
    r.vboLive = maxPointDiff(mid.raw, rest.raw);
    r.matrixExtra = maxPointDiff(mid.rendered, mid.raw);
    r.gizmoShift = sqrt((endCx-midCx)*(endCx-midCx) +
                        (endCy-midCy)*(endCy-midCy));
    r.midModel = mid.model;
    return r;
}

struct Rgb { long r, g, b; }

Rgb[] probeRow(int y, int width) {
    Rgb[] result;
    for (int start = 2; start < width - 2; start += 60) {
        immutable int stop = (start + 60 < width - 2) ? start + 60 : width - 2;
        string points;
        foreach (x; start .. stop) {
            if (points.length) points ~= ";";
            points ~= format("%d,%d", x, y);
        }
        auto j = getJson("/api/viewport/probe?cell=0&points=" ~ points);
        foreach (p; j["points"].array)
            result ~= Rgb(p["r"].integer, p["g"].integer, p["b"].integer);
    }
    assert(result.length == cast(size_t)(width - 4),
           "6450: pixel row population changed");
    return result;
}

int rightChangedEdge(const Rgb[] rest, const Rgb[] current) {
    assert(rest.length == current.length && rest.length > 0,
           "6450: pixel rows must be equally populated");
    int edge = -1;
    foreach (i; 0 .. rest.length) {
        if (rest[i] != current[i]) edge = cast(int)i + 2;
    }
    return edge;
}

struct PixelResult { int restEdge, midEdge, settledEdge; }

PixelResult runPixelMove() {
    prepareScene(true);
    cmd("tool.set move on");
    Thread.sleep(300.msecs);
    auto c = fetchCamera();
    double cx, cy, gx, gy;
    bool found;
    fetchHandlePart(3, cx, cy, found);
    assert(found, "6450: pixel centre handle missing");
    fetchHandlePart(0, gx, gy, found);
    assert(found, "6450: pixel grab handle missing");
    double vx = gx - cx, vy = gy - cy;
    double length = sqrt(vx*vx + vy*vy);
    int x0 = cast(int)(gx + 0.5), y0 = cast(int)(gy + 0.5);
    int x1 = x0 + cast(int)(120 * vx / length + 0.5);
    int y1 = y0 + cast(int)(120 * vy / length + 0.5);
    int row = cast(int)(cy + 0.5) - c.vpY;

    auto restSurface = surfaceSample();
    auto vp = viewportFromCamera(c);
    int restEdge = -1;
    foreach (p; restSurface.rendered) {
        float px, py;
        if (projectToWindow(Vec3(cast(float)p[0], cast(float)p[1],
                                 cast(float)p[2]), vp, px, py))
            restEdge = max(restEdge, cast(int)round(px) - c.vpX);
    }
    assert(restEdge >= 0, "6450 pixels: rest surface did not project");
    auto rest = probeRow(row, c.width);
    playSettled(hoverLog(c, x0, y0));
    playSettled(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playSettled(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height,
                                   x0, y0, x1, y1, 16));
    auto mid0 = probeRow(row, c.width);
    Thread.sleep(100.msecs);
    auto mid1 = probeRow(row, c.width);
    playSettled(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x1, y1));
    waitPreviewSettled();
    auto settled0 = probeRow(row, c.width);
    Thread.sleep(100.msecs);
    auto settled1 = probeRow(row, c.width);

    int midEdge0 = rightChangedEdge(rest, mid0);
    int settledEdge0 = rightChangedEdge(rest, settled0);
    PixelResult r;
    r.restEdge = restEdge;
    r.midEdge = rightChangedEdge(rest, mid1);
    r.settledEdge = rightChangedEdge(rest, settled1);
    assert(abs(r.midEdge - midEdge0) <= 1,
           "6450: mid-drag pixel edge was not stable across two frames");
    assert(abs(r.settledEdge - settledEdge0) <= 1,
           "6450: settled pixel edge was not stable across two frames");
    return r;
}

unittest {
    auto poly = runDrag("move", false);
    writefln("[6450] control poly drag/release = %.6f / %.6f",
             poly.dragMoved, poly.releaseShift);
    assert(poly.dragMoved > 0.1,
           "6450 polygon control: drag population floor failed");
    assert(poly.releaseShift <= 1e-4,
           "6450 polygon control: release moved the picture");

    auto partial = runDrag("move", true, [0, 1, 2, 3]);
    writefln("[6450] control partial drag/release = %.6f / %.6f",
             partial.dragMoved, partial.releaseShift);
    assert(partial.dragMoved > 0.1,
           "6450 partial-selection control: drag population floor failed");
    assert(partial.releaseShift <= 1e-4,
           "6450 partial-selection control: release moved the picture");
    assert(matrixIsIdentity(partial.midModel),
           "6450 partial-selection control: the tool matrix must already be identity");

    auto falloff = runDrag("xfrm.elementMove", true);
    writefln("[6450] control falloff drag/release = %.6f / %.6f",
             falloff.dragMoved, falloff.releaseShift);
    assert(falloff.dragMoved > 0.02,
           "6450 element-falloff control: drag population floor failed");
    assert(falloff.releaseShift <= 1e-4,
           "6450 element-falloff control: release moved the picture");

    auto hidden = runDrag("move", true, null, true);
    writefln("[6450] control hidden drag/release = %.6f / %.6f",
             hidden.dragMoved, hidden.releaseShift);
    assert(hidden.dragMoved > 0.1,
           "6450 hidden-vertex control: drag population floor failed");
    assert(hidden.releaseShift <= 1e-4,
           "6450 hidden-vertex control: release moved the picture");

    auto move = runDrag("move", true);
    auto element = runDrag("move.element", true);
    auto rotate = runDrag("rotate", true, null, false,
                          10, 0, true, 90, 0);
    auto scale = runDrag("scale", true, null, false, 23, 20);
    writefln("[6450] releaseShift move/move.element/rotate/scale = "
           ~ "%.6f / %.6f / %.6f / %.6f",
             move.releaseShift, element.releaseShift,
             rotate.releaseShift, scale.releaseShift);

    auto px = runPixelMove();
    assert(px.midEdge >= 0 && px.settledEdge >= 0,
           "6450 pixels: moving surface produced no changed-pixel population");
    assert(px.midEdge - px.restEdge >= 50,
           "6450 pixels: mid-drag silhouette population floor failed");
    assert(abs(px.midEdge - px.settledEdge) <= 1,
        format("6450 pixels: release moved the raster edge from %d to %d",
               px.midEdge, px.settledEdge));

    assert(move.dragMoved > 0.1,
           "6450 move: drag population floor failed");
    assert(move.releaseShift <= 1e-4,
        format("6450: release must not move the picture — subpatch with empty "
             ~ "selection snaps by %.6f (VBO already carries %.6f while the "
             ~ "model matrix adds %.6f), gizmo shift %.2f px; "
             ~ "move/move.element/rotate/scale = %.6f / %.6f / %.6f / %.6f",
               move.releaseShift, move.vboLive, move.matrixExtra,
               move.gizmoShift, move.releaseShift, element.releaseShift,
               rotate.releaseShift, scale.releaseShift));
    assert(element.dragMoved > 0.1,
           "6450 move.element: drag population floor failed");
    assert(element.releaseShift <= 1e-4,
           "6450 move.element: release moved the picture");
    assert(rotate.dragMoved > 0.1,
           "6450 rotate: drag population floor failed");
    assert(rotate.releaseShift <= 1e-4,
           "6450 rotate: release moved the picture");
    assert(scale.dragMoved > 0.1,
           "6450 scale: drag population floor failed");
    assert(scale.releaseShift <= 1e-4,
           "6450 scale: release moved the picture");
}
