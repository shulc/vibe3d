// Tests for mesh.smooth — Laplacian smoothing of selected vertices.
//
// Cube smoke-tests:
//   * strn=0 ⇒ no-op
//   * iter=0 ⇒ no-op
//   * Each iteration moves every vert toward the centroid of its 3
//     edge-adjacent corners. With strn=1 the cube collapses partway
//     toward origin; with strn=0.5 partway less.
//   * High iter count ⇒ all verts converge near origin (uniform
//     averaging on a closed regular mesh is contractive).
//   * Selection-aware: only selected verts move; unselected stay put
//     even though they're neighbours of moving ones (the snapshot
//     pattern reads the previous-iteration positions of unselected
//     verts as their original ones).
//   * Undo restores.

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

unittest { // strn=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0 iter:5");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "strn=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // iter=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:0");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "iter=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // strn=1, iter=1 on cube — each vert averages with its 3
           // edge-adjacent corners, all of which differ by ±1 in
           // exactly two of XYZ. The signed component along each axis
           // averages: (0.5 + 0.5 + 0.5 + (-0.5)) / 4 = 0.25 for the
           // three "same-sign" corner & one diagonal opposite. Wait —
           // actually each cube corner has 3 edge-neighbours; each
           // neighbour differs in exactly ONE axis. So for vert
           // (-0.5, -0.5, -0.5):
           //   nbr1 = (+0.5, -0.5, -0.5)  // X-edge
           //   nbr2 = (-0.5, +0.5, -0.5)  // Y-edge
           //   nbr3 = (-0.5, -0.5, +0.5)  // Z-edge
           // avg = (-0.5+0.5-0.5-0.5)/3, (...) ... = (-0.5/3, -0.5/3, -0.5/3)
           //     = (-1/6, -1/6, -1/6).
           // strn=1: new = old + 1*(avg-old) = avg.
           // So every cube vert moves to its (avg of 3 nbrs).
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // Each cube corner had components ±0.5; after one strn=1 smooth,
        // each component magnitude should be 1/6 (since two of the three
        // neighbours share that component value, the third flips).
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 1.0/6.0, 1e-4),
                "strn=1 iter=1 cube smooth: expected |c|=1/6, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // strn=0.5, iter=1 on cube — half the displacement of strn=1
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // new = old + 0.5*(avg-old) = (old + avg)/2
        // old = ±0.5; avg = ±1/6; (0.5 + 1/6)/2 = 1/3 (for positive-sign
        // axis); (-0.5 + -1/6)/2 = -1/3.
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 1.0/3.0, 1e-4),
                "strn=0.5 iter=1 cube smooth: expected |c|=1/3, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // many iterations converge toward origin
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:100");
    auto verts = dumpVerts();
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        assert(r < 0.05,
            "after 100 iter strn=1 smooth, vert should be near origin, got r="
            ~ r.to!string);
    }
}

unittest { // selection-aware: vertex mode + 1 selected vert ⇒ only it moves
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.smooth strn:1 iter:1");
    auto verts = dumpVerts();
    // Vert 0 = (-0.5, -0.5, -0.5) → moved to (-1/6, -1/6, -1/6).
    auto v0 = verts[0];
    assert(approxEq(v0[0], -1.0/6.0, 1e-4),
        "vert 0 should move to -1/6, got " ~ v0[0].to!string);
    assert(approxEq(v0[1], -1.0/6.0, 1e-4));
    assert(approxEq(v0[2], -1.0/6.0, 1e-4));
    // Vert 1 = (+0.5, -0.5, -0.5), unselected → stays.
    auto v1 = verts[1];
    assert(approxEq(v1[0],  0.5, 1e-4),
        "vert 1 should stay at +0.5, got " ~ v1[0].to!string);
    assert(approxEq(v1[1], -0.5, 1e-4));
    assert(approxEq(v1[2], -0.5, 1e-4));
}

unittest { // undo restores
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:3");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
}
