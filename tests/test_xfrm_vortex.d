// Tests for xfrm.vortex preset — Rotate + Cylinder falloff.
//
// vibe3d's cylinder falloff is "radial perpendicular to axis": weight 1
// on the axis line, attenuating to 0 at radius `max(size.x, size.y, size.z)`.
// Combined with RotateTool's headless RY apply, the preset should
// twist a column of verts uniformly around the cylinder axis with
// distance-weighted attenuation.
//
// MODO 9 ships an `xfrm.vortex` ToolPreset with the same combination
// (falloff.cylinder + xfrm.rotate). Cross-engine bit-perfect compare
// would require MODO's xfrm.rotate doApply to honour the angle attr
// headlessly, which it doesn't (per modo_dump.py:run_xfrm_rotate).
// We verify against the analytical reference instead.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, cos, sin, PI;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

unittest { // vortex preset activation: type=cylinder, shape=linear
    postJson("/api/reset", "");
    cmd("tool.set xfrm.vortex on");
    auto j = getJson("/api/toolpipe");
    string ftype, fshape;
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT") {
            ftype  = st["attrs"]["type"].str;
            fshape = st["attrs"]["shape"].str;
        }
    }
    assert(ftype  == "cylinder",
        "vortex preset should set falloff.type=cylinder, got " ~ ftype);
    assert(fshape == "linear",
        "vortex preset should set falloff.shape=linear, got " ~ fshape);
}

unittest { // RY=30 around Y axis, cylinder radius 1.0 — verts at
           // perpendicular distance r get weight = 1 - r/1.0 (clamped)
           // and rotate by 30·weight degrees around Y.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    // Use a cube with vertical segmentation so the verts have a
    // perpendicular-to-Y component that varies. With segmentsX=1,
    // segmentsY=4, segmentsZ=1, the verts at y=±0.5/±0.25/0 all sit
    // at perpendicular distance sqrt((±0.5)² + (±0.5)²) = sqrt(0.5)
    // ≈ 0.707 from the Y axis. So weight = 1 - 0.707/1.0 ≈ 0.293
    // (linear shape) and rotation = 30 · 0.293 ≈ 8.79°.
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
    auto before = dumpVerts();

    cmd("tool.set xfrm.vortex on");
    // Pin cylinder handles explicitly: axis=+Y, center origin, size 1.0.
    cmd("tool.pipe.attr falloff center \"0,0,0\"");
    cmd("tool.pipe.attr falloff size \"1,1,1\"");
    cmd("tool.pipe.attr falloff axis \"0,1,0\"");
    cmd("tool.attr xfrm.vortex RY 30");
    cmd("tool.doApply");

    auto after = dumpVerts();
    assert(after.length == before.length);

    enum double R       = 1.0;
    enum double RY_DEG  = 30.0;
    foreach (i, v; after) {
        double ox = before[i][0], oy = before[i][1], oz = before[i][2];
        // Perpendicular distance from Y axis = sqrt(x² + z²).
        double perp = sqrt(ox*ox + oz*oz);
        double t    = perp / R;
        if (t > 1) t = 1;
        double w    = 1.0 - t;
        if (w < 0) w = 0;
        double th   = (RY_DEG * w) * (PI / 180.0);
        double c    = cos(th), s = sin(th);
        double xExp = ox * c + oz * s;
        double zExp = -ox * s + oz * c;
        // Y rotation preserves Y component.
        assert(approxEq(v[1], oy),
            "vert " ~ i.to!string ~ " Y should stay at " ~ oy.to!string
            ~ ", got " ~ v[1].to!string);
        assert(approxEq(v[0], xExp),
            "vert " ~ i.to!string ~ " X mismatch: got " ~ v[0].to!string
            ~ ", expected " ~ xExp.to!string ~ " (perp=" ~ perp.to!string
            ~ ", weight=" ~ w.to!string ~ ")");
        assert(approxEq(v[2], zExp),
            "vert " ~ i.to!string ~ " Z mismatch: got " ~ v[2].to!string
            ~ ", expected " ~ zExp.to!string);
    }
}

unittest { // RY=0 ⇒ no-op even with cylinder falloff active
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.vortex on");
    cmd("tool.pipe.attr falloff center \"0,0,0\"");
    cmd("tool.pipe.attr falloff size \"1,1,1\"");
    cmd("tool.pipe.attr falloff axis \"0,1,0\"");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "RY=0 vortex shouldn't move verts off ±0.5");
    }
}
