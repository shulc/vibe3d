// Tests for xfrm.push — push verts along their normals weighted by
// the active falloff stage. An `xfrm.push` (Distance attr).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;

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

unittest { // dist=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    cmd("tool.attr xfrm.push dist 0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "dist=0 push shouldn't move verts");
    }
}

unittest { // push cube without falloff: each vert moves along its
           // smooth normal by `dist`. Cube corners have a smooth
           // normal pointing diagonally outward (avg of the 3
           // incident face normals = (sign·1/sqrt(3), ..., ...) ).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    // Disable any auto-attached falloff (preset doesn't add one but
    // be defensive).
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.attr xfrm.push dist 0.1");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // After push, distance from origin should be ~ sqrt(3)/2 + 0.1
        // (original radius + push distance — every cube corner pushes
        // outward along (sign·1/sqrt(3))).
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        double expected = 0.866025403784 + 0.1;
        assert(approxEq(r, expected, 1e-3),
            "expected r=" ~ expected.to!string ~ ", got " ~ r.to!string);
    }
}

unittest { // push with linear falloff: top row pushes full dist,
           // bottom row stays. Verifies falloff plumbing (same as
           // shear/twist/taper integration).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
    cmd("tool.set xfrm.push on");
    cmd("tool.pipe.attr falloff type linear");
    cmd("tool.pipe.attr falloff start \"0,0.5,0\"");
    cmd("tool.pipe.attr falloff end \"0,-0.5,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr xfrm.push dist 0.3");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // Bottom row (y=-0.5) weight=0 → should still be on |x|=|z|=0.5.
    foreach (v; verts) {
        if (approxEq(v[1], -0.5)) {
            assert(approxEq(fabs(v[0]), 0.5),
                "y=-0.5 vert should keep |x|=0.5 (push weight 0), got "
                ~ v[0].to!string);
            assert(approxEq(fabs(v[2]), 0.5));
        }
    }
    // Top row (y=+0.5) weight=1 → corners shifted along their smooth
    // normal (top corners: (sign·1/sqrt(3), 1/sqrt(3), sign·1/sqrt(3))).
    foreach (v; verts) {
        if (v[1] > 0.5) {
            // y was 0.5, push moved it in +Y direction by dist*1/sqrt(3) ≈ 0.173.
            // Expected new y = 0.5 + 0.3/sqrt(3) ≈ 0.5 + 0.1732 ≈ 0.673.
            double expectedY = 0.5 + 0.3 / sqrt(3.0);
            assert(approxEq(v[1], expectedY, 1e-3),
                "top vert Y after push: expected " ~ expectedY.to!string
                ~ ", got " ~ v[1].to!string);
        }
    }
}

unittest { // negative dist ⇒ inward push (collapse direction)
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.attr xfrm.push dist -0.1");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        double expected = 0.866025403784 - 0.1;
        assert(approxEq(r, expected, 1e-3),
            "negative push: expected r=" ~ expected.to!string ~ ", got " ~ r.to!string);
    }
}

bool noCoincidentVerts(double[3][] verts, double eps = 1e-6) {
    foreach (i; 0 .. verts.length)
        foreach (j; i + 1 .. verts.length) {
            double dx = verts[i][0] - verts[j][0];
            double dy = verts[i][1] - verts[j][1];
            double dz = verts[i][2] - verts[j][2];
            if (sqrt(dx*dx + dy*dy + dz*dz) < eps) return false;
        }
    return true;
}

double faceArea(double[3][] p) {
    // Cross product magnitude / 2 for a triangle p[0],p[1],p[2].
    double ux = p[1][0]-p[0][0], uy = p[1][1]-p[0][1], uz = p[1][2]-p[0][2];
    double vx = p[2][0]-p[0][0], vy = p[2][1]-p[0][1], vz = p[2][2]-p[0][2];
    double cx = uy*vz - uz*vy, cy = uz*vx - ux*vz, cz = ux*vy - uy*vx;
    return 0.5 * sqrt(cx*cx + cy*cy + cz*cz);
}

unittest { // task 0319 — overshoot guard: a large negative dist used to
           // collapse every vertex of an octahedron onto (0,0,0) (fuzz-
           // found, status still "ok"). The push must now stop short of
           // the collapse point instead of landing on/through it.
    postJson("/api/reset?type=octahedron", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.attr xfrm.push dist -1");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    assert(noCoincidentVerts(verts),
        "octahedron overshoot push produced coincident vertices");
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        assert(r > 1e-6,
            "octahedron overshoot push collapsed a vertex onto the origin, r=" ~ r.to!string);
    }
    auto faces = getJson("/api/model")["faces"].array;
    foreach (f; faces) {
        auto idx = f.array;
        assert(idx.length >= 3, "degenerate face after overshoot push");
        double[3][] p;
        foreach (i; idx) p ~= verts[cast(size_t) i.integer];
        assert(faceArea(p[0 .. 3]) > 1e-9,
            "zero-area face after overshoot push");
    }
}

unittest { // task 0319 — same overshoot guard on a plain cube, whose
           // collapse point is the well-known half-space-diagonal
           // (dist == -sqrt(3)/2 ≈ -0.866).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.attr xfrm.push dist -1");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    assert(noCoincidentVerts(verts),
        "cube overshoot push produced coincident vertices");
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        assert(r > 1e-6,
            "cube overshoot push collapsed a vertex onto the origin, r=" ~ r.to!string);
        // Should land just short of the analytic collapse point, not past it.
        assert(r < 0.001,
            "cube overshoot push didn't clamp close to the collapse point, r=" ~ r.to!string);
    }
}

unittest { // task 0319 — the guard must not clip ordinary (non-overshoot)
           // pushes: a moderate negative dist, well inside the safe
           // range, should move verts by exactly `dist` (unclamped).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.push on");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.attr xfrm.push dist -0.3");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        double expected = 0.866025403784 - 0.3;
        assert(approxEq(r, expected, 1e-3),
            "moderate negative push should be unclamped: expected r="
            ~ expected.to!string ~ ", got " ~ r.to!string);
    }
}
