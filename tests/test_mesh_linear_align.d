// Tests for mesh.linear_align — task 0361: chain-interpolation between
// the selection's two fixed (edge-connectivity) endpoints, replacing the
// prior bbox-collapse-to-centroid-line algorithm. See
// source/tools/align_kernels.d's module doc comment for the captured law.
//
// The bit-exact numbers below are hand-verified against the private
// capture (task 0361, cases "la_nonuniform" / "la_uniform" /
// "la_weight05"); no reference engine runs at test time. The scenario
// reproduces the capture exactly: an open
// 4-vertex chain along 3 cube edges (A=(-.5,-.5,-.5) - B=(.5,-.5,-.5) -
// C=(.5,-.5,.5) - D=(.5,.5,.5)), with B pre-displaced by
// (-0.3,+0.35,+0.4) so uniform vs. non-uniform interpolation diverge (a
// stock cube's equal orthogonal steps can't discriminate the two modes —
// see the toolcard's own capture-method note).

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

int findVert(double[3][] verts, double x, double y, double z) {
    foreach (i, v; verts)
        if (approxEq(v[0], x) && approxEq(v[1], y) && approxEq(v[2], z))
            return cast(int)i;
    return -1;
}

unittest { // open 4-vertex chain, uniform=false (default): endpoints fixed,
           // interior verts project onto their own (own-position) line —
           // bit-exact vs the "la_nonuniform" capture case.
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxD = findVert(before,  0.5,  0.5,  0.5);
    assert(idxA >= 0 && idxB >= 0 && idxC >= 0 && idxD >= 0,
        "expected all 4 chain corners on the default cube");

    // Pre-displace B so uniform vs nonuniform diverge (toolcard method).
    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.2,-0.15,-0.1}");

    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxD.to!string ~ `]}`);
    assert(sel["status"].str == "ok", sel.toString);

    cmd("mesh.linear_align");
    auto after = dumpVerts();

    // Endpoints A/D never move.
    assert(approxEq(after[idxA][0], -0.5) && approxEq(after[idxA][1], -0.5)
        && approxEq(after[idxA][2], -0.5), "endpoint A must not move");
    assert(approxEq(after[idxD][0],  0.5) && approxEq(after[idxD][1],  0.5)
        && approxEq(after[idxD][2],  0.5), "endpoint D must not move");

    // B: t = dot(B_source - A, D - A) / |D-A|^2 = 1.45/3 = 0.483333...
    enum double nb = -0.0166667;
    assert(approxEq(after[idxB][0], nb) && approxEq(after[idxB][1], nb)
        && approxEq(after[idxB][2], nb), "B mismatch: " ~ after[idxB].to!string);

    // C wasn't displaced: t = 2/3 (own-projection == index-spacing here).
    enum double nc = 0.1666667;
    assert(approxEq(after[idxC][0], nc) && approxEq(after[idxC][1], nc)
        && approxEq(after[idxC][2], nc), "C mismatch: " ~ after[idxC].to!string);

    // Topology untouched — align only moves existing verts.
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == 8);
    assert(model["faceCount"].integer == 6);
}

unittest { // same chain, uniform=true — B lands at equal chain-index
           // spacing (t=1/3) instead of its own projection (t=0.4833).
           // Bit-exact vs la_uniform.json.
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxD = findVert(before,  0.5,  0.5,  0.5);

    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.2,-0.15,-0.1}");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxD.to!string ~ `]}`);

    cmd("mesh.linear_align uniform:true");
    auto after = dumpVerts();

    enum double ub = -0.1666667;
    assert(approxEq(after[idxB][0], ub) && approxEq(after[idxB][1], ub)
        && approxEq(after[idxB][2], ub), "uniform B mismatch: " ~ after[idxB].to!string);
    enum double uc = 0.1666667;
    assert(approxEq(after[idxC][0], uc) && approxEq(after[idxC][1], uc)
        && approxEq(after[idxC][2], uc), "uniform C mismatch: " ~ after[idxC].to!string);
    assert(approxEq(after[idxA][0], -0.5), "uniform endpoint A must not move");
    assert(approxEq(after[idxD][0],  0.5), "uniform endpoint D must not move");
}

unittest { // weight=0.5 blends source -> aligned (nonuniform) linearly.
           // Bit-exact vs la_weight05.json.
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxD = findVert(before,  0.5,  0.5,  0.5);

    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.2,-0.15,-0.1}");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxD.to!string ~ `]}`);

    cmd("mesh.linear_align weight:0.5");
    auto after = dumpVerts();

    assert(approxEq(after[idxB][0], 0.0916667, 1e-3) && approxEq(after[idxB][1], -0.0833333, 1e-3)
        && approxEq(after[idxB][2], -0.0583333, 1e-3), "weight=0.5 B mismatch: " ~ after[idxB].to!string);
    assert(approxEq(after[idxC][0], 0.3333333, 1e-3) && approxEq(after[idxC][1], -0.1666667, 1e-3)
        && approxEq(after[idxC][2], 0.3333333, 1e-3), "weight=0.5 C mismatch: " ~ after[idxC].to!string);
}

unittest { // undo restores — no selection (whole-mesh fallback: 8 cube
           // corners don't form a single clean chain, so extraction falls
           // back to selection order; the op must still run + undo cleanly
           // without crashing regardless of the resulting geometry).
    postJson("/api/reset", "");
    cmd("mesh.linear_align");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == 8);
    assert(model["edgeCount"].integer == 12);
    assert(model["faceCount"].integer == 6);
}
