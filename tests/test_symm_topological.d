// Topological-symmetry end-to-end tests.
//
// Three discriminators:
//
// Test 1 — topology=true, deformed base: select the PAIR A (index 2) and D
//   (index 4, NOT at A's spatial mirror) and translate by delta=(0.5,0.3,0.1)
//   through `mesh.transform` in a fresh session (authoring side A = −X, task
//   7144). The +X member A is off the authoring side, so it takes the
//   conjugate delta M·delta = (−0.5,0.3,0.1): A → (1.5,0.8,0.1). D is the
//   pair's −X member and takes mirrorDirection(A's edit) relative to its OWN
//   base: D → (−0.8+0.5, −0.3+0.3, 0.1) = (−0.3,0.0,0.1) — NOT the spatial
//   mirror of A's final position. A lone A (the second row) writes nothing
//   else: a transform writes only its operand (gap 316).
//
// Test 2 — topology=false, same deformed mesh: the spatial builder finds no
//   pair for A (deformed away from its mirror locus), so D stays put.
//
// Test 3 — topology=true, disconnected quads (no seam): no on-plane seam
//   vertex → BFS seeds are empty → pairOf = -1 for all → D stays put.
//
// Mesh: two quads sharing the seam edge c0(0)–c1(1) on X=0.
//   0: c0 = (0, 0, 0)       seam
//   1: c1 = (0, 1, 0)       seam
//   2: A  = (2.0, 0.5, 0)   +X, deformed off its spatial-mirror locus
//   3: B  = (1.5, 1.2, 0)   +X
//   4: D  = (−0.8,−0.3, 0)  −X partner of A (independently deformed)
//   5: C  = (−1.1, 1.3, 0)  −X partner of B
//   Face 0 (+X quad): [c0, A, B, c1] = [0, 2, 3, 1]
//   Face 1 (−X quad): [c0, c1, C, D] = [0, 1, 5, 4]
//
// The shared HTTP client resolves the port assigned by run_test.d.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;

void main() {}

alias BASE = testBaseUrl;
enum string DEFORMED_MESH =
    `{"vertices":[[0,0,0],[0,1,0],[2.0,0.5,0],[1.5,1.2,0],[-0.8,-0.3,0],[-1.1,1.3,0]],`
    ~ `"faces":[[0,2,3,1],[0,1,5,4]]}`;
enum string DISCONNECTED_MESH =
    `{"vertices":[[-0.5,-0.5,0],[-0.5,0.5,0],[-0.5,-0.5,1],[-0.5,0.5,1],`
    ~             `[0.5,-0.5,0],[0.5,0.5,0],[0.5,-0.5,1],[0.5,0.5,1]],`
    ~ `"faces":[[0,1,3,2],[4,6,7,5]]}`;


double[3] vertexPos(JSONValue model, int idx) {
    auto v = model["vertices"].array[idx].array;
    double[3] r;
    foreach (k; 0 .. 3)
        r[k] = v[k].type == JSONType.float_ ? v[k].floating : cast(double)v[k].integer;
    return r;
}

void reset()        { postJson("/api/command", commandBody("scene.reset")); }
void loadMesh(string j) {
    auto resp = postJson("/api/command", commandBody("scene.loadMesh", j));
    assert(resp["status"].str == "ok", "load-mesh failed: " ~ resp.toString);
}
void setSymmetry(bool enabled, bool topology) {
    postJson("/api/command", `tool.pipe.attr symmetry enabled ` ~ (enabled ? "true" : "false"));
    postJson("/api/command", `tool.pipe.attr symmetry axis x`);
    postJson("/api/command", `tool.pipe.attr symmetry offset 0`);
    postJson("/api/command", `tool.pipe.attr symmetry topology ` ~ (topology ? "true" : "false"));
}
void selectVertices(int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":` ~ idxJson ~ `}`));
    assert(resp["status"].str == "ok", "select failed: " ~ resp.toString);
}
JSONValue translate(double dx, double dy, double dz) {
    return postJson("/api/command", commandBody("mesh.transform", format(`{"kind":"translate","delta":[%.6g,%.6g,%.6g]}`, dx, dy, dz)));
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// ---------------------------------------------------------------------------
// Test 1: topology=true, deformed base — D moves by mirrorDirection(delta)
// ---------------------------------------------------------------------------
unittest { // topology ON: D gets delta-mirror, NOT absolute-mirror of A_final
    reset();
    loadMesh(DEFORMED_MESH);
    setSymmetry(true, true);
    selectVertices([2, 4]);   // the pair A, D

    auto pre = getJson("/api/model");
    auto preD = vertexPos(pre, 4);  // D's baseline position
    auto side = postJson("/api/toolpipe/eval", "")["symmetry"]["authoringSide"].integer;
    assert(side == -1, "rig: authoringSide " ~ side.to!string ~ " before the numeric step, expected -1");

    auto tr = translate(0.5, 0.3, 0.1);
    assert(tr["status"].str == "ok", "translate failed: " ~ tr.toString);

    auto post_ = getJson("/api/model");
    auto postA = vertexPos(post_, 2);
    auto postD = vertexPos(post_, 4);

    // A is off the authoring side: the conjugate delta (−0.5,0.3,0.1).
    assert(approx(postA[0], 1.5) && approx(postA[1], 0.8) && approx(postA[2], 0.1),
        format("A expected (1.5,0.8,0.1) after translate (off A: conjugate delta), got %s", postA));

    // D = D_base + mirrorDirection(A's edit (−0.5,0.3,0.1)) = D_base + (0.5,0.3,0.1)
    double expectedDx = preD[0] + 0.5;      // −0.3
    double expectedDy = preD[1] + 0.3;      //  0.0
    double expectedDz = preD[2] + 0.1;      //  0.1
    assert(approx(postD[0], expectedDx, 1e-3),
        "topology=true: D.x expected " ~ expectedDx.to!string ~ " got " ~ postD[0].to!string);
    assert(approx(postD[1], expectedDy, 1e-3),
        "topology=true: D.y expected " ~ expectedDy.to!string ~ " got " ~ postD[1].to!string);
    assert(approx(postD[2], expectedDz, 1e-3),
        "topology=true: D.z expected " ~ expectedDz.to!string ~ " got " ~ postD[2].to!string);

    // Discriminator: D must NOT be at the absolute spatial mirror of A's final position.
    double wrongDx = -postA[0];  // −1.5
    assert(!approx(postD[0], wrongDx, 0.1),
        "topology=true: D.x should NOT be the absolute spatial mirror of A_final ("
        ~ wrongDx.to!string ~ "); got " ~ postD[0].to!string);
}

unittest { // topology ON, lone A: its unselected partner D is never written
    reset();
    loadMesh(DEFORMED_MESH);
    setSymmetry(true, true);
    selectVertices([2]);
    auto preD = vertexPos(getJson("/api/model"), 4);
    auto tr = translate(0.5, 0.3, 0.1);
    assert(tr["status"].str == "ok", "translate failed: " ~ tr.toString);
    auto post_ = getJson("/api/model");
    assert(approx(vertexPos(post_, 2)[0], 1.5), "lone A: expected x 1.5 (conjugate delta)");
    auto postD = vertexPos(post_, 4);
    assert(approx(postD[0], preD[0]) && approx(postD[1], preD[1]) && approx(postD[2], preD[2]),
        format("lone A wrote its unselected partner D: %s, expected %s", postD, preD));
}

// ---------------------------------------------------------------------------
// Test 2: topology=false, deformed base — spatial builder finds no pair for A
// ---------------------------------------------------------------------------
unittest { // topology OFF: spatial builder fails on deformed mesh, D stays put
    reset();
    loadMesh(DEFORMED_MESH);
    setSymmetry(true, false);  // spatial mode
    selectVertices([2]);

    auto pre  = getJson("/api/model");
    auto preD = vertexPos(pre, 4);

    auto tr = translate(0.5, 0.3, 0.1);
    assert(tr["status"].str == "ok", "translate failed: " ~ tr.toString);

    auto post_ = getJson("/api/model");
    auto postD = vertexPos(post_, 4);

    // Spatial mirror of A=(2.0,0.5,0) is (−2.0,0.5,0) — no vertex near that.
    // The spatial builder assigns pairOf[A]=−1 → D is untouched.
    assert(approx(postD[0], preD[0], 1e-3),
        "topology=false: D.x should be unchanged (spatial builder: no pair); got "
        ~ postD[0].to!string);
    assert(approx(postD[1], preD[1], 1e-3),
        "topology=false: D.y should be unchanged; got " ~ postD[1].to!string);
    assert(approx(postD[2], preD[2], 1e-3),
        "topology=false: D.z should be unchanged; got " ~ postD[2].to!string);
}

// ---------------------------------------------------------------------------
// Test 3: topology=true, disconnected quads — no seam, no BFS seeds, D stays put
// ---------------------------------------------------------------------------
unittest { // topology ON, no seam vertex: BFS has no seeds, all pairOf = -1
    reset();
    loadMesh(DISCONNECTED_MESH);
    setSymmetry(true, true);
    selectVertices([4]);  // +X quad bottom-left

    auto pre  = getJson("/api/model");
    auto pre4 = vertexPos(pre, 4);
    auto pre0 = vertexPos(pre, 0);  // symmetric -X counterpart

    auto tr = translate(0.5, 0.0, 0.0);
    assert(tr["status"].str == "ok", "translate failed: " ~ tr.toString);

    auto post_ = getJson("/api/model");
    auto post0 = vertexPos(post_, 0);   // -X counterpart should NOT move

    // No seam vertex on X=0 → topological BFS has no seeds → pairOf[4] = -1 → v0 untouched.
    assert(approx(post0[0], pre0[0], 1e-3),
        "disconnected: no seam → v0 should be untouched; got " ~ post0[0].to!string);
    assert(approx(post0[1], pre0[1], 1e-3),
        "disconnected: v0.y should be unchanged; got " ~ post0[1].to!string);
}
