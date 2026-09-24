// Task 7115 (S3-R, item 11) — a symmetric drag on a subpatch mesh shows the
// smoothed surface on BOTH sides in every held frame, with no cage fill.
//
// Law (frozen in tests/fixtures/editor_display_laws_w17.json,
// `symmetric_subpatch_drag`): a click on (0.5,0.5,0.5) with symmetry X on
// selects BOTH that vertex and its partner; a move-tool drag off the handle
// then deforms the smoothed surface on both sides in the same held frame; the
// cage is drawn only as wire and dots, never as a flat fill. The control cell
// (`control_selection_through_script`) is the other half: a SCRIPT selection
// of one vertex moves only that vertex — symmetry acts at selection time.
//
// Order (CLAUDE.md "ORDER the asserts"): rig premises and the selection floor,
// then the held-frame floor (preview live, the drag reached the VBO), then the
// two named asserts — cage fill first, one-side-stale second — and the
// release pair. The last block MEASURES the script-selection control for gap
// row 192 and prints it; it asserts nothing about the rule (plan S3).
//
// Moment: every held-frame read happens after the SECOND motion log and two
// completed frames, before the release log is played.
//
// NOT A WITNESS OF THE REPORTED BUG. The owner's item 11 was NOT reproduced
// (task 7115): this file is green on the pre-fix tree, also under an empty
// selection, a script selection and a per-poll read during the second log,
// and NONE of four display-path mutations reddens it (cage-upload
// suppression off in `uploadSelectedVertices` and in `upload`, the display
// matrix fold off, the symmetry partner dropped from the upload set — task
// 7116's table). It pins only the OUTCOME of the captured law (both sides
// smoothed, no cage fill, the pair symmetric after release); it says nothing
// about a cause.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, fetchHandlePart, CameraState, DHVec3 = Vec3;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, round;
import std.stdio : writefln;

void main() {}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok",
           "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }

void selectVerts(int[] indices) {
    string body = `{"mode":"vertices","indices":[`;
    foreach (i, idx; indices) {
        if (i) body ~= ",";
        body ~= idx.to!string;
    }
    body ~= "]}";
    cmd(commandBody("mesh.select", body));
}

void waitPreviewSettled() {
    foreach (_; 0 .. 1500) {
        auto p = getJson("/api/subpatch/preview");
        if (p["active"].type == JSONType.true_
            && p["pending"].type != JSONType.true_) {
            Thread.sleep(80.msecs);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "7115: subpatch preview did not settle");
}

long framesDone() { return getJson("/api/frames/counts")["frames"].integer; }

void waitFrames(long n) {
    postJson("/api/frames/counts/reset", "{}");
    foreach (_; 0 .. 500) {
        if (framesDone() >= n) return;
        Thread.sleep(10.msecs);
    }
    assert(false, "7115: fewer than " ~ n.to!string ~ " frames completed");
}

double[3][] modelVerts() {
    double[3][] r;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}

int vertexAt(double x, double y, double z) {
    foreach (i, p; modelVerts())
        if (abs(p[0]-x) < 1e-6 && abs(p[1]-y) < 1e-6 && abs(p[2]-z) < 1e-6)
            return cast(int)i;
    assert(false, format("7115 rig: no vertex at (%g,%g,%g)", x, y, z));
}

struct FaceVbo {
    long count;
    double[3][] drawn;   // positions after the display matrix the renderer applies
}

FaceVbo faceVbo() {
    auto j = getJson("/api/gpu/face-vbo");
    FaceVbo r;
    r.count = j["faceVertCount"].integer;
    double[16] m;
    foreach (i, v; j["model"].array) m[i] = v.floating;
    foreach (p; j["positions"].array) {
        auto a = p.array;
        double x = a[0].floating, y = a[1].floating, z = a[2].floating;
        r.drawn ~= [m[0]*x + m[4]*y + m[8]*z + m[12],
                    m[1]*x + m[5]*y + m[9]*z + m[13],
                    m[2]*x + m[6]*y + m[10]*z + m[14]];
    }
    return r;
}

double maxDiff(const double[3][] a, const double[3][] b) {
    assert(a.length == b.length && a.length > 0,
           "7115: compared VBO populations differ or are empty");
    double d = 0;
    foreach (i; 0 .. a.length)
        foreach (k; 0 .. 3) d = max(d, abs(a[i][k] - b[i][k]));
    return d;
}

/// Worst distance from a point to the nearest mirror (x -> -x) of any point.
double mirrorResidual(const double[3][] pts) {
    double worst = 0;
    foreach (p; pts) {
        double best = double.infinity;
        foreach (q; pts) {
            double d = max(abs(p[0] + q[0]), max(abs(p[1] - q[1]), abs(p[2] - q[2])));
            if (d < best) best = d;
        }
        worst = max(worst, best);
    }
    return worst;
}

string vpLine(CameraState c) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
}

string clickLog(CameraState c, int x, int y) {
    return vpLine(c) ~ format(
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":90.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y, x, y, x, y);
}

/// Hover at (x0,y0), then press there.
string pressLog(CameraState c, int x0, int y0) {
    return vpLine(c) ~ format(
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0, y0, x0, y0);
}

/// `n` motion steps of +8 px screen right, after `done` already played.
string stepLog(CameraState c, int x0, int y0, int done, int n) {
    string log = vpLine(c);
    foreach (i; 1 .. n + 1) {
        int x = x0 + 8 * (done + i);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":8,"yrel":0,"state":1,"mod":0}` ~ "\n",
            50.0 * i, x, y0);
    }
    return log;
}

string releaseLog(CameraState c, int x, int y) {
    return vpLine(c) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y);
}

void play(string log) {
    playAndWait(log);
    Thread.sleep(200.msecs);
}

void pixelOf(CameraState c, double x, double y, double z, out int px, out int py) {
    auto vp = viewportFromCamera(c);
    float fx, fy;
    assert(projectToWindow(DHVec3(cast(float)x, cast(float)y, cast(float)z), vp, fx, fy),
           "7115 rig: point did not project");
    px = cast(int)round(fx);
    py = cast(int)round(fy);
}

/// Subpatch cube, symmetry X, vertex mode, empty selection; answers the
/// resting face-VBO population (the SMOOTHED surface's face-vertex count).
long rig() {
    cmd(commandBody("scene.reset"));
    cmd("tool.pipe.attr snap enabled false");
    cmd("select.typeFrom polygon");
    cmdId("mesh.subpatch_toggle");
    waitPreviewSettled();
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
    cmd("select.typeFrom vertex");
    selectVerts([]);
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("symmetry.toggle");   // default axis; the selection floor checks it
    Thread.sleep(200.msecs);
    return faceVbo().count;
}

/// The drag: move tool, press below the gizmo centre (off every handle), ten
/// +8 px steps in three logs. `held` runs between the second log and the
/// release, after two completed frames.
void drag(void delegate() held) {
    cmd("tool.set move on");
    Thread.sleep(300.msecs);
    auto c = fetchCamera();
    double cx, cy;
    bool found;
    fetchHandlePart(3, cx, cy, found);
    assert(found, "7115 rig: move centre handle missing");
    int x0 = cast(int)round(cx) - 70, y0 = cast(int)round(cy) + 70;
    play(pressLog(c, x0, y0));
    play(stepLog(c, x0, y0, 0, 5));
    play(stepLog(c, x0, y0, 5, 5));
    waitFrames(2);
    held();
    play(releaseLog(c, x0 + 80, y0));
    waitPreviewSettled();
    cmd("tool.set move off");
}

unittest {
    immutable long restCount = rig();
    auto rest = faceVbo();
    assert(restCount > 36,
        format("7115 rig: the resting VBO holds %d face points, not the smoothed "
             ~ "surface (the cage is 36)", restCount));

    immutable int a = vertexAt(0.5, 0.5, 0.5);
    immutable int b = vertexAt(-0.5, 0.5, 0.5);
    {
        // The vertex is clicked where it is DRAWN. Under a live subpatch
        // preview our vertex VBO carries the dot at its limit position, not at
        // the cage corner (measured: a click on the projected cage corner
        // picks nothing), so aim at the drawn dot of the (+,+,+) corner.
        auto vbo = getJson("/api/gpu/face-vbo")["vertPositions"].array;
        assert(vbo.length > 0, "7115 rig: the vertex VBO is empty");
        double[3] dot = [0, 0, 0];
        double best = -double.infinity;
        foreach (p; vbo) {
            auto q = p.array;
            double x = q[0].floating, y = q[1].floating, z = q[2].floating;
            if (x + y + z > best) { best = x + y + z; dot = [x, y, z]; }
        }
        auto c = fetchCamera();
        int px, py;
        pixelOf(c, dot[0], dot[1], dot[2], px, py);
        writefln("[7115] clicking the drawn dot %s at (%d,%d)", dot, px, py);
        play(clickLog(c, px, py));
    }
    auto sel = getJson("/api/selection")["selectedVertices"].array;
    writefln("[7115] symmetric click selected %d vertices", sel.length);
    assert(sel.length == 2,
        format("7115 symmetric click selected %d vertices, reference 2", sel.length));

    FaceVbo held;
    bool live, pending;
    drag({
        auto p = getJson("/api/subpatch/preview");
        live = p["active"].type == JSONType.true_;
        pending = p["pending"].type == JSONType.true_;
        held = faceVbo();
    });

    assert(live && !pending,
           "7115 floor: the subpatch preview was not live and settled while held");
    assert(held.count > 0, "7115 floor: the held face VBO is empty");
    writefln("[7115] held faceVertCount = %d (rest %d)", held.count, restCount);
    assert(held.count == restCount,
        format("7115 cage fill drawn during symmetric subpatch drag: the held face "
             ~ "VBO holds %d points, the smoothed surface at rest %d", held.count,
               restCount));
    double moved = maxDiff(held.drawn, rest.drawn);
    writefln("[7115] held drag moved the drawn surface by %.6f", moved);
    assert(moved > 0.05, "7115 floor: the drag did not reach the drawn surface");
    double residual = mirrorResidual(held.drawn);
    writefln("[7115] held mirror residual = %.6f", residual);
    assert(residual <= 1e-4,
        format("7115 symmetric subpatch drag drew one side stale: the drawn surface "
             ~ "misses its x-mirror by %.6f", residual));

    auto after = modelVerts();
    writefln("[7115] released pair = %s / %s", after[a], after[b]);
    assert(abs(after[a][0] - 0.5) > 0.05, "7115 floor: the release moved nothing");
    assert(abs(after[a][0] + after[b][0]) <= 1e-4
            && abs(after[a][1] - after[b][1]) <= 1e-4
            && abs(after[a][2] - after[b][2]) <= 1e-4,
        format("7115 released pair is not x-symmetric: %s / %s", after[a], after[b]));

    // Gap row 192, OUR side — a measurement, not an assert.
    rig();
    selectVerts([a]);
    drag({});
    auto ctl = modelVerts();
    writefln("[7115] gap-192 measurement: script-selected (0.5,0.5,0.5) -> %s; "
           ~ "unselected partner (-0.5,0.5,0.5) -> %s (moved: %s)",
             ctl[a], ctl[b], abs(ctl[b][0] + 0.5) > 1e-4
                 || abs(ctl[b][1] - 0.5) > 1e-4);
    cmd("tool.pipe.attr symmetry enabled false");
}
