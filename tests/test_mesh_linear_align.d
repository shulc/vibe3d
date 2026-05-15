// Tests for mesh.linear_align — project selected verts onto a line
// through their centroid along the bbox's longest axis. Mirrors the
// `mode=line, flatten=true` branch of MODO's xfrm.linearAlign tool.

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

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // 4 cube verts on the +Y face → line along longest axis
    // Top face quad: vert indices vary by mesh setup. Select the four
    // y=+0.5 corners explicitly. Their bbox is a flat 1x0x1 quad so
    // the longest axis is X (or Z, tied — X wins lexicographically).
    // After alignment, all four collapse onto the X axis through
    // the centroid (which is the origin of the top face = (0, 0.5, 0)).
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    // Find the four y=+0.5 verts.
    auto before = dumpVerts();
    int[] topIdx;
    foreach (i, v; before) if (approxEq(v[1], 0.5)) topIdx ~= cast(int)i;
    assert(topIdx.length == 4, "expected 4 verts at y=+0.5");
    string idxStr = "[";
    foreach (i, k; topIdx) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= k.to!string;
    }
    idxStr ~= "]";
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":` ~ idxStr ~ `}`);
    assert(sel["status"].str == "ok", sel.toString);
    cmd("mesh.linear_align");
    auto after = dumpVerts();
    foreach (k; topIdx) {
        auto v = after[k];
        // After projection onto the X-axis line through (0, 0.5, 0):
        // y stays 0.5 (centroid Y), z snaps to 0 (centroid Z),
        // x retains its sign-magnitude.
        assert(approxEq(v[1], 0.5),
            "y should stay at centroid 0.5, got " ~ v[1].to!string);
        assert(approxEq(v[2], 0.0),
            "z should collapse to centroid 0, got " ~ v[2].to!string);
        assert(approxEq(fabs(v[0]), 0.5),
            "x should retain ±0.5 magnitude, got " ~ v[0].to!string);
    }
    // Unselected verts (y=-0.5 row) untouched.
    foreach (i, v; after) {
        if (approxEq(v[1], -0.5)) {
            // Still on ±0.5 cube boundary in all axes.
            foreach (c; 0 .. 3)
                assert(approxEq(fabs(v[c]), 0.5),
                    "unselected vert " ~ i.to!string ~ " should stay on cube");
        }
    }
}

unittest { // 2 verts ⇒ already-collinear, should not move (each is on
           // the line through the centroid in the "longest axis" direction
           // of the 2-vert bbox)
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    // Verts 0 (-0.5,-0.5,-0.5) and 6 (+0.5,+0.5,+0.5) — body diagonal.
    auto before = dumpVerts();
    int idx0 = -1, idx6 = -1;
    foreach (i, v; before) {
        if (approxEq(v[0], -0.5) && approxEq(v[1], -0.5) && approxEq(v[2], -0.5))
            idx0 = cast(int)i;
        if (approxEq(v[0],  0.5) && approxEq(v[1],  0.5) && approxEq(v[2],  0.5))
            idx6 = cast(int)i;
    }
    assert(idx0 >= 0 && idx6 >= 0);
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idx0.to!string ~ `,` ~ idx6.to!string ~ `]}`);
    assert(sel["status"].str == "ok", sel.toString);
    cmd("mesh.linear_align");
    auto after = dumpVerts();
    // Both verts had bbox = unit cube (longest axis = X). Centroid = (0,0,0).
    // Projection onto X axis: y → 0, z → 0, x retains sign.
    auto v0 = after[idx0]; auto v6 = after[idx6];
    assert(approxEq(v0[0], -0.5));
    assert(approxEq(v0[1],  0.0));
    assert(approxEq(v0[2],  0.0));
    assert(approxEq(v6[0],  0.5));
    assert(approxEq(v6[1],  0.0));
    assert(approxEq(v6[2],  0.0));
}

unittest { // undo restores
    postJson("/api/reset", "");
    cmd("mesh.linear_align");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
}
