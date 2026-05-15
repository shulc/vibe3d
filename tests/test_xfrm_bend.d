// Tests for xfrm.bend — rotate verts around an axis perpendicular to
// the user's spine direction, by angle scaled by spine-distance.
//
// Note: this is a SIMPLIFIED bend (rotation-by-spine-distance), not the
// canonical "rod-into-arc" geometry MODO ships. Verifies the simplified
// behaviour against an analytical reference; cross-engine MODO compare
// would need MODO's xfrm.bend to deform via doApply (untested) and an
// arc-shaped reference.

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

unittest { // angle=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.bend on");
    cmd("tool.attr xfrm.bend angle 0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "angle=0 bend shouldn't move verts");
    }
}

unittest { // bend cube around X-spine: each vert at signed X distance
           // s rotates around the bend axis (X × Y = Z) by angle·(s/L).
           // Cube: X spans [-0.5, +0.5], so half-extent = 0.5. Bend
           // angle 90° → verts at x=+0.5 rotate +90° around Z; verts at
           // x=-0.5 rotate -90°. Pivot = origin (cube centroid).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    auto before = dumpVerts();

    cmd("tool.set xfrm.bend on");
    cmd("tool.attr xfrm.bend spineX 1");
    cmd("tool.attr xfrm.bend spineY 0");
    cmd("tool.attr xfrm.bend spineZ 0");
    cmd("tool.attr xfrm.bend angle 90");
    cmd("tool.doApply");

    auto after = dumpVerts();
    enum double HALF_EXT = 0.5;
    enum double TOTAL    = 90.0 * (PI / 180.0);
    foreach (i, v; after) {
        double ox = before[i][0], oy = before[i][1], oz = before[i][2];
        double s   = ox;                    // dot((ox,oy,oz)-origin, (1,0,0)) = ox
        double phi = TOTAL * (s / HALF_EXT);
        // Rotate (ox, oy, oz) by phi around Z axis through origin.
        // Z-axis rotation: x' = ox·cos - oy·sin, y' = ox·sin + oy·cos, z' = oz.
        double c = cos(phi), sn = sin(phi);
        double xExp = ox * c - oy * sn;
        double yExp = ox * sn + oy * c;
        assert(approxEq(v[0], xExp),
            "vert " ~ i.to!string ~ " X mismatch: got " ~ v[0].to!string
            ~ ", expected " ~ xExp.to!string);
        assert(approxEq(v[1], yExp),
            "vert " ~ i.to!string ~ " Y mismatch: got " ~ v[1].to!string
            ~ ", expected " ~ yExp.to!string);
        assert(approxEq(v[2], oz),
            "vert " ~ i.to!string ~ " Z should stay (Z is bend axis), got "
            ~ v[2].to!string);
    }
}

unittest { // spine = +Y direction → bend axis = Y × Y = degenerate;
           // falls back to Y × Z = +X. Verts above the centroid rotate
           // +angle around X; verts below rotate -angle around X.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    auto before = dumpVerts();

    cmd("tool.set xfrm.bend on");
    cmd("tool.attr xfrm.bend spineX 0");
    cmd("tool.attr xfrm.bend spineY 1");
    cmd("tool.attr xfrm.bend spineZ 0");
    cmd("tool.attr xfrm.bend angle 60");
    cmd("tool.doApply");

    auto after = dumpVerts();
    enum double HALF_EXT = 0.5;
    enum double TOTAL    = 60.0 * (PI / 180.0);
    foreach (i, v; after) {
        double ox = before[i][0], oy = before[i][1], oz = before[i][2];
        double s   = oy;
        double phi = TOTAL * (s / HALF_EXT);
        double c = cos(phi), sn = sin(phi);
        // Rotate around X axis through origin: y' = oy·cos - oz·sin,
        // z' = oy·sin + oz·cos.
        double yExp = oy * c - oz * sn;
        double zExp = oy * sn + oz * c;
        assert(approxEq(v[0], ox),
            "vert " ~ i.to!string ~ " X should stay (X is bend axis), got "
            ~ v[0].to!string);
        assert(approxEq(v[1], yExp),
            "vert " ~ i.to!string ~ " Y mismatch: got " ~ v[1].to!string
            ~ ", expected " ~ yExp.to!string);
        assert(approxEq(v[2], zExp),
            "vert " ~ i.to!string ~ " Z mismatch: got " ~ v[2].to!string
            ~ ", expected " ~ zExp.to!string);
    }
}
