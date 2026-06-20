// Tests for xfrm.vortex preset — Rotate + Cylinder falloff.
//
// vibe3d's cylinder falloff is "radial perpendicular to axis": weight 1
// on the axis line, attenuating to 0 at radius `max(size.x, size.y, size.z)`.
// Combined with RotateTool's headless RY apply, the preset should
// twist a column of verts uniformly around the cylinder axis with
// distance-weighted attenuation.
//
// `xfrm.vortex` is a ToolPreset combining falloff.cylinder +
// xfrm.rotate. We verify against an analytical reference.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

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

// NB: the weighted-rotation parity (vibe3d vs the reference engine) is now
// covered by tests/test_fixture_vortex.d as a reference-parity golden — the
// reference applies R(w·θ) (angle-scaling, radius-preserving), NOT a matrix-lerp
// toward identity, so the analytical matrix-lerp self-test that used to live
// here was removed when the xfrm.vortex preset switched to angle-scaling. The
// activation test above (type=cylinder / shape=linear) and the RY=0 no-op below
// are unaffected by the blend mode and stay.

unittest { // RY=0 ⇒ no-op even with cylinder falloff active. Angle 0 under
           // angle-scaling is R(w·0)=identity for every weight, so nothing moves.
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
