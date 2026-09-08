// A pure Rotate idle re-grade must sample geometry-derived pipe state from the
// gesture baseline.  The stand is deliberately asymmetric: a centred cube
// cannot distinguish a live post-rotation ACEN sample from a baseline sample.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json : JSONType, JSONValue;
import std.math : PI, cos, fabs, sin;
import std.conv : to;

import drag_helpers;

void main() {}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "command failed: " ~ line ~ " => " ~ r.toString);
}

void settle() {
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(150.msecs);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

double[3][] vertices() {
    double number(JSONValue v) {
        switch (v.type) {
        case JSONType.float_: return v.floating;
        case JSONType.integer: return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        default: assert(false, "model coordinate is not numeric: " ~ v.toString);
        }
    }
    double[3][] result;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        result ~= [number(a[0]), number(a[1]), number(a[2])];
    }
    return result;
}

void establishAsymmetricMesh() {
    cmd("tool.set rotate off");
    auto r = postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,-0.7,-0.4],[1.6,-0.5,-0.2],[0.9,1.1,0.1],`
      ~ `[-0.8,0.6,0.35],[0.15,0.2,1.7]],`
      ~ `"faces":[[0,1,2,3],[0,4,1],[1,4,2],[2,4,3],[3,4,0]]}`));
    assert(r["status"].str == "ok", "asymmetric mesh load failed: " ~ r.toString);
    auto selected = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":[0,1,2,3,4]}`));
    assert(selected["status"].str == "ok",
        "asymmetric vertex selection failed: " ~ selected.toString);
    cmd("history.clear");
    cmd("tool.set rotate");
    cmd("tool.pipe.attr actionCenter mode local");
    settle();
}

void configureFalloff(string size) {
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "-1.2,-0.7,-0.4"`);
    cmd(`tool.pipe.attr falloff size "` ~ size ~ `"`);
    settle();
}

void rotateOnRing(long expectedUndo) {
    foreach (attempt; 0 .. 6) {
        auto cam = fetchCamera();
        auto vp = viewportFromCamera(cam);
        Vec3 pivot = evalPivot();
        float size = gizmoSize(pivot, vp);
        float a = 110.0f * cast(float)PI / 180.0f;
        Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size,
                      pivot.z + sin(a) * size);
        float sx, sy;
        assert(projectToWindow(p, vp, sx, sy), "rotate ring is off-camera");
        int x0 = cast(int)sx, y0 = cast(int)sy;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x0 + 34, y0 + 26, 12));
        settle();
        if (undoCount() == expectedUndo) return;
    }
    assert(false, "pure Rotate ring gesture did not land; undo="
        ~ undoCount().to!string ~ " expected=" ~ expectedUndo.to!string);
}

double[3][] run(bool regradeAtIdle) {
    establishAsymmetricMesh();
    configureFalloff(regradeAtIdle ? "12,12,12" : "3.2,3.2,3.2");
    long floor = undoCount();
    rotateOnRing(floor + 1);
    if (regradeAtIdle) {
        cmd(`tool.pipe.attr falloff size "3.2,3.2,3.2"`);
        settle();
    }
    auto result = vertices();
    cmd("tool.set rotate off");
    cmd("tool.pipe.attr falloff type none");
    return result;
}

unittest {
    auto duringDrag = run(false);
    auto idleRegrade = run(true);
    assert(duringDrag.length == idleRegrade.length && duringDrag.length == 5,
        "both paths must preserve the populated asymmetric stand");

    double worst = 0;
    size_t wi, wk;
    foreach (i; 0 .. duringDrag.length)
        foreach (k; 0 .. 3) {
            double d = fabs(duringDrag[i][k] - idleRegrade[i][k]);
            if (d > worst) { worst = d; wi = i; wk = k; }
        }
    assert(worst <= 1e-4,
        "pure Rotate must produce the same geometry when a falloff radius is "
      ~ "present during the gesture or reached by an idle re-grade; worst="
      ~ worst.to!string ~ " at v" ~ wi.to!string ~ "." ~ wk.to!string);
}
