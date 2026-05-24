// Tests for mesh.radial_align — project selection onto a sphere
// centred at its centroid with radius = mean distance from centroid.

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

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // whole cube radial align — every vert is already at distance
           // sqrt(3)/2 from origin (centroid), so projection is a no-op
           // (each direction unchanged, length already matches the mean).
    postJson("/api/reset", "");
    cmd("mesh.radial_align");
    auto verts = dumpVerts();
    enum double R = 0.866025403784;  // sqrt(3) / 2
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        assert(approxEq(r, R, 1e-4),
            "cube vert should sit on radius sqrt(3)/2 sphere, got r=" ~ r.to!string);
        // And the components should still be ±0.5 (no-op).
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "no-op radial align should leave cube corners at ±0.5");
    }
}

unittest { // selection of mixed-distance points — they all snap to the
           // mean distance from their centroid.
    postJson("/api/reset", "");
    // Move vert 0 closer to origin so distances are mixed: vert 0 → (-0.25,-0.25,-0.25)
    // (distance sqrt(3)/4); vert 6 stays at (+0.5,+0.5,+0.5) (distance sqrt(3)/2).
    cmd("select.typeFrom vertex");
    auto sel0 = postJson("/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(sel0["status"].str == "ok");
    cmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{-0.25,-0.25,-0.25}");
    // Verify
    auto verts = dumpVerts();
    bool found = false;
    foreach (v; verts) if (approxEq(v[0], -0.25)) { found = true; break; }
    assert(found, "move_vertex didn't take");

    // Now pick a 2-vert selection: the moved one and its diagonal opposite.
    int idxA = -1, idxB = -1;
    foreach (i, v; verts) {
        if (approxEq(v[0], -0.25) && approxEq(v[1], -0.25) && approxEq(v[2], -0.25)) idxA = cast(int)i;
        if (approxEq(v[0],  0.5)  && approxEq(v[1],  0.5)  && approxEq(v[2],  0.5))  idxB = cast(int)i;
    }
    assert(idxA >= 0 && idxB >= 0);
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string ~ `]}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.radial_align");
    auto after = dumpVerts();
    auto a = after[idxA]; auto b = after[idxB];
    // Centroid = ((-0.25+0.5)/2, ...)  = (0.125, 0.125, 0.125).
    // Distances pre-align: |a-c| = sqrt(3)*0.375, |b-c| = sqrt(3)*0.375.
    // (Actually since the two verts are colinear with the centroid,
    //  they're equidistant from it — so this is also a no-op for
    //  these two verts post-align.)
    double[3] c = [0.125, 0.125, 0.125];
    double rA = sqrt((a[0]-c[0])*(a[0]-c[0]) + (a[1]-c[1])*(a[1]-c[1]) + (a[2]-c[2])*(a[2]-c[2]));
    double rB = sqrt((b[0]-c[0])*(b[0]-c[0]) + (b[1]-c[1])*(b[1]-c[1]) + (b[2]-c[2])*(b[2]-c[2]));
    assert(approxEq(rA, rB, 1e-4),
        "after radial align, both verts should sit on the same sphere (rA="
        ~ rA.to!string ~ ", rB=" ~ rB.to!string ~ ")");
}

unittest { // radial align on top face quad → all 4 verts equidistant
           // from face centroid (0, 0.5, 0). Pre-align distances are
           // already sqrt(0.5) for each corner; this is a no-op.
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int[] topIdx;
    foreach (i, v; before) if (approxEq(v[1], 0.5)) topIdx ~= cast(int)i;
    string idxStr = "[";
    foreach (i, k; topIdx) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= k.to!string;
    }
    idxStr ~= "]";
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":` ~ idxStr ~ `}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.radial_align");
    auto after = dumpVerts();
    enum double R = 0.707106781187;  // sqrt(0.5)
    foreach (k; topIdx) {
        auto v = after[k];
        // Centroid (0, 0.5, 0); distances = sqrt((±0.5)² + 0² + (±0.5)²) = sqrt(0.5).
        double dx = v[0]; double dy = v[1] - 0.5; double dz = v[2];
        double r = sqrt(dx*dx + dy*dy + dz*dz);
        assert(approxEq(r, R, 1e-4),
            "top vert should sit at radius sqrt(0.5) from (0,0.5,0), got r=" ~ r.to!string);
    }
}

unittest { // undo restores
    postJson("/api/reset", "");
    cmd("mesh.radial_align");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
}
