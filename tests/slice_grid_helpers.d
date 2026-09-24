module slice_grid_helpers;

// Shared rig for the Edge Slice interaction witnesses on the flat grid
// (tests/test_edge_slice_symmetry.d, tests/test_edge_slice_third_point_drag.d):
// a 4x4 quad grid on y = 0 spanning x, z in [-2, 2] (25 v / 16 f / 40 e),
// built by the box primitive with a zero Y size, seen almost straight down so
// every grid edge projects to a clean screen segment. Input is real SDL events
// through /api/play-events (tests/slice_leak_helpers.d); every pixel is a
// projection through the live camera, and a click is sent only at a pixel
// that hovered the named edge.

import slice_leak_helpers;
import http_client : getJson, postRaw;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.format : format;
import std.json;
import std.math : abs, round, sqrt;
import core.thread : Thread;
import core.time : msecs;

enum long GRID_VERTS = 25, GRID_FACES = 16;

/// Empty scene, the 4x4 grid, history cleared, top-down camera, edge mode.
/// `subpatchOn` adds Tab (a real key event) and waits for the preview.
void gridRig(bool subpatchOn) {
    auto r = slPost("/api/command", `{"id":"scene.reset","params":{"empty":true}}`);
    assert(r["status"].str == "ok", "grid rig: scene.reset failed: " ~ r.toString);
    slLine("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:4 sizeY:0 sizeZ:4 "
           ~ "segmentsX:4 segmentsY:1 segmentsZ:4");
    slCmd("history.clear");
    postRaw("/api/camera?viewport=0", `{"azimuth":0.0,"elevation":1.5,"distance":7.5}`);
    Thread.sleep(300.msecs);
    slCmd("mesh.select", `{"mode":"edges","indices":[]}`);
    const g = slMesh();
    assert(g.verts == GRID_VERTS && g.faces == GRID_FACES,
           "grid rig: the primitive is not the 25v/16f grid: " ~ g.toString);
    if (subpatchOn) {
        const b0 = getJson("/api/subpatch/preview")["builds"].integer;
        slKey(SL_SDLK_TAB, 0, "Tab (subpatch ON)");
        slWaitSubpatchSettled(b0);
        foreach (f; getJson("/api/model")["isSubpatch"].array)
            assert(f.type == JSONType.true_, "grid rig: Tab left a face without subpatch");
    }
    assert(slHistoryLen() == (subpatchOn ? 2 : 1),
           format("grid rig: history is not the selection row%s: %s",
                  subpatchOn ? " plus the subpatch toggle" : "", slHistoryLabels()));
}

/// The vertex at (x, 0, z), by position.
int gridVert(JSONValue m, double x, double z) {
    foreach (i, v; m["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - x) < 1e-4 && abs(a[1].floating) < 1e-4
                && abs(a[2].floating - z) < 1e-4)
            return cast(int)i;
    }
    return -1;
}

/// The grid edge from (x0, 0, z0) to (x1, 0, z1) as a vertex pair (min, max).
long[2] gridPair(double x0, double z0, double x1, double z1) {
    auto m = getJson("/api/model");
    const a = gridVert(m, x0, z0), b = gridVert(m, x1, z1);
    assert(a >= 0 && b >= 0 && slEdgeOf(m, a, b) >= 0,
           format("grid rig: no edge (%s,%s)-(%s,%s)", x0, z0, x1, z1));
    return a < b ? [cast(long)a, cast(long)b] : [cast(long)b, cast(long)a];
}

/// Window pixel of a model point through the live camera.
int[2] pixelOf(double x, double y, double z) {
    auto vp = viewportFromCamera(fetchCamera());
    float px, py;
    assert(projectToWindow(Vec3(x, y, z), vp, px, py), "grid rig: point behind the camera");
    return [cast(int)round(px), cast(int)round(py)];
}

/// Hover `p` and require the picker to resolve edge (a, b) there.
void hoverFloor(int[2] p, long a, long b, string what) {
    const e = slEdgeOf(getJson("/api/model"), a, b);
    slHover(p[0], p[1]);
    const h = getJson("/api/tool/state")["hoveredEdge"].integer;
    assert(e >= 0 && h == e,
           format("grid pick floor: %s: pixel (%d,%d) hovers edge %d, expected (%d,%d) = %d",
                  what, p[0], p[1], h, a, b, e));
}

/// Each latched point's model position: its stored vertex pair lerped by its t.
double[3][] latchedPositions() {
    auto m = getJson("/api/model");
    auto s = getJson("/api/tool/state");
    double[3][] r;
    auto ts = s["latchedT"].array;
    foreach (i, p; s["latchedPairs"].array) {
        auto a = m["vertices"].array[cast(size_t)p.array[0].integer].array;
        auto b = m["vertices"].array[cast(size_t)p.array[1].integer].array;
        const t = ts[i].type == JSONType.integer ? cast(double)ts[i].integer : ts[i].floating;
        double[3] q;
        foreach (k; 0 .. 3) q[k] = a[k].floating + (b[k].floating - a[k].floating) * t;
        r ~= q;
    }
    return r;
}

/// Model positions of every vertex whose index is at or past `from`.
double[3][] verticesFrom(long from) {
    double[3][] r;
    foreach (i, v; getJson("/api/model")["vertices"].array) {
        if (cast(long)i < from) continue;
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}

double dist3(double[3] a, double[3] b) {
    double s = 0;
    foreach (k; 0 .. 3) s += (a[k] - b[k]) * (a[k] - b[k]);
    return sqrt(s);
}

string p3(double[3] p) { return format("(%.4f,%.4f,%.4f)", p[0], p[1], p[2]); }

string p3s(const double[3][] ps) {
    string s = "[";
    foreach (i, p; ps) { if (i) s ~= ","; s ~= p3(p); }
    return s ~ "]";
}

long bakedSegments() {
    auto s = getJson("/api/tool/state");
    return ("bakedSegments" in s.object) ? s["bakedSegments"].integer : -1;
}
