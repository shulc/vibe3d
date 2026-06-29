// Tests for mesh.symmetrize — snap a drifted-symmetric mesh back to exact
// symmetry by ABSOLUTE-reflecting the driver side onto the partner side.
//
// Stage 1: spatial pairing, small drift, explicit epsilon.
// Stage 2: topological pairing, large drift (capture-verified numbers), plus a
//          spatial-fails discriminator proving the branch matters.
// Stage 3: on-plane projection, unpaired safe-skip, both driver sides, undo.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;
import std.stdio : writefln;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

void resetCube() {
    auto resp = post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

JSONValue postCommandJ(string body) {
    return parseJSON(post(BASE ~ "/api/command", body));
}

void postCommand(string body) {
    auto r = postCommandJ(body);
    assert(r["status"].str == "ok",
        "/api/command failed: " ~ r.toString);
}

JSONValue getModel() { return parseJSON(get(BASE ~ "/api/model")); }

JSONValue postUndo() {
    return parseJSON(post(BASE ~ "/api/undo", ""));
}

// Inject a raw mesh.  `verts` is a JSON array-of-array-of-doubles string;
// `faces` is a JSON array-of-array-of-ints string.
void loadMesh(string verts, string faces) {
    string body = `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`;
    auto resp = post(BASE ~ "/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/load-mesh failed: " ~ resp);
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

double[3] vToArr(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double[3] vertAt(JSONValue model, size_t idx) {
    return vToArr(model["vertices"].array[idx]);
}

// ---------------------------------------------------------------------------
// Stage 1 — spatial pairing, small drift, epsilon explicitly widened
// ---------------------------------------------------------------------------

unittest {
    // Mesh: 4 vertices forming two triangles sharing the X=0 seam.
    //   v0=(0, 1, 0)   seam
    //   v1=(0,-1, 0)   seam
    //   v2=(1, 0, 0)   +X driver
    //   v3=(-1, 0, 0)  -X spatial partner (exact mirror of v2)
    // Faces: [0,1,2], [0,3,1]
    //
    // We drift v2 to (1.1, 0, 0) via load-mesh, then symmetrize with
    // side:positive, epsilon:0.2 (large enough to pair v3 with the
    // mirror of drifted v2 at (-1.1,0,0); v3 is 0.1 away — within 0.2).
    //
    // Expected: v2 unchanged at (1.1,0,0); v3 snapped to (-1.1,0,0).

    resetCube();
    loadMesh(
        `[[0,1,0],[0,-1,0],[1.1,0,0],[-1,0,0]]`,
        `[[0,1,2],[0,3,1]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false,"epsilon":0.2
    }}`);

    auto m = getModel();
    auto v2 = vertAt(m, 2);
    auto v3 = vertAt(m, 3);

    // Driver (v2) must be unchanged.
    assert(approxEq(v2[0], 1.1) && approxEq(v2[1], 0.0) && approxEq(v2[2], 0.0),
        "Stage 1: driver v2 must be unchanged, got " ~ v2.to!string);

    // Partner (v3) must equal mirror of driver: (-1.1, 0, 0).
    assert(approxEq(v3[0], -1.1),
        "Stage 1: partner v3.x must be -1.1, got " ~ v3[0].to!string);
    assert(approxEq(v3[1], 0.0),
        "Stage 1: partner v3.y must be 0, got " ~ v3[1].to!string);
    assert(approxEq(v3[2], 0.0),
        "Stage 1: partner v3.z must be 0, got " ~ v3[2].to!string);
}

// ---------------------------------------------------------------------------
// Stage 1b — undo restores original positions
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    loadMesh(
        `[[0,1,0],[0,-1,0],[1.1,0,0],[-1,0,0]]`,
        `[[0,1,2],[0,3,1]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false,"epsilon":0.2
    }}`);

    // Verify symmetrize moved something.
    auto after = getModel();
    assert(approxEq(vertAt(after, 3)[0], -1.1),
        "Stage 1b: pre-undo partner should be -1.1");

    // Undo.
    auto undoR = postUndo();
    assert(undoR["status"].str == "ok", "Stage 1b: undo failed: " ~ undoR.toString);

    auto restored = getModel();
    // v3 should be back at -1.0.
    assert(approxEq(vertAt(restored, 3)[0], -1.0),
        "Stage 1b: after undo v3.x should be -1.0, got "
        ~ vertAt(restored, 3)[0].to!string);
    // v2 should still be 1.1 (untouched by symmetrize, unchanged by undo).
    assert(approxEq(vertAt(restored, 2)[0], 1.1),
        "Stage 1b: after undo v2.x should still be 1.1, got "
        ~ vertAt(restored, 2)[0].to!string);
}

// ---------------------------------------------------------------------------
// Stage 1c — side:negative: the -X side drives, +X snaps to its mirror
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // v3 at (-1.1, 0, 0) is the driver (-X side); v2 at (1.0, 0, 0).
    loadMesh(
        `[[0,1,0],[0,-1,0],[1,0,0],[-1.1,0,0]]`,
        `[[0,1,2],[0,3,1]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"negative","topology":false,"epsilon":0.2
    }}`);

    auto m = getModel();
    auto v2 = vertAt(m, 2);
    auto v3 = vertAt(m, 3);

    // Driver v3 (negative side) unchanged.
    assert(approxEq(v3[0], -1.1),
        "Stage 1c: driver v3.x must stay -1.1, got " ~ v3[0].to!string);

    // Partner v2 snapped to mirror of v3: (1.1, 0, 0).
    assert(approxEq(v2[0], 1.1),
        "Stage 1c: partner v2.x should be 1.1, got " ~ v2[0].to!string);
}

// ---------------------------------------------------------------------------
// Stage 2 — topological pairing, capture-verified large-drift fixture
//
// Two quads sharing X=0 seam verts (v0, v1).
//   v0=( 0, 1, 0)  seam
//   v1=( 0,-1, 0)  seam
//   v2=( 1.0, 0.7, 0)  +X driver
//   v3=( 1.0,-0.7, 0)  +X driver
//   v4=(-1.3, 0.2, 0)  -X drifted partner of v2  (NOT spatial mirror — too far)
//   v5=(-1.3,-0.2, 0)  -X drifted partner of v3  (NOT spatial mirror — too far)
//
// Face layout (share seam verts 0 and 1):
//   f0: [0, 2, 3, 1]  (+X quad)
//   f1: [0, 1, 5, 4]  (-X quad)
//
// Drift size: spatial mirror of v2=(1,0.7,0) lands at (-1,0.7,0); v4 is at
// (-1.3,0.2,0) — distance ≈ 0.56, far outside the default epsilon=1e-4.
// Only topological pairing (via shared seam v0,v1) can match v4↔v2.
//
// After mesh.symmetrize {side:positive, topology:true}:
//   v2 unchanged at (1.0, 0.7, 0).
//   v4 snapped to (-1.0, 0.7, 0) — capture-verified.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    loadMesh(
        `[[0,1,0],[0,-1,0],[1,0.7,0],[1,-0.7,0],[-1.3,0.2,0],[-1.3,-0.2,0]]`,
        `[[0,2,3,1],[0,1,5,4]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":true
    }}`);

    auto m = getModel();
    auto v2 = vertAt(m, 2);
    auto v4 = vertAt(m, 4);

    // Driver v2 unchanged.
    assert(approxEq(v2[0], 1.0) && approxEq(v2[1], 0.7),
        "Stage 2: driver v2 must be unchanged (1.0,0.7), got " ~ v2.to!string);

    // Partner v4 snapped to exact mirror of v2: (-1.0, 0.7, 0).
    assert(approxEq(v4[0], -1.0),
        "Stage 2: v4.x should be -1.0 (mirror of v2.x=1.0), got " ~ v4[0].to!string);
    assert(approxEq(v4[1], 0.7),
        "Stage 2: v4.y should be 0.7 (mirror of v2.y=0.7), got " ~ v4[1].to!string);
    assert(approxEq(v4[2], 0.0),
        "Stage 2: v4.z should be 0.0, got " ~ v4[2].to!string);
}

// ---------------------------------------------------------------------------
// Stage 2 discriminator — spatial:false on the SAME large-drift fixture
// must leave v4 un-snapped (proves the topology branch matters).
// Because no pairs are found, the command is a no-op and returns status=error.
// We verify by reading the model after the (failed-to-apply) attempt.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    loadMesh(
        `[[0,1,0],[0,-1,0],[1,0.7,0],[1,-0.7,0],[-1.3,0.2,0],[-1.3,-0.2,0]]`,
        `[[0,2,3,1],[0,1,5,4]]`
    );

    // topology:false — spatial pairing, default epsilon (1e-4).
    // Mirror of v2=(1,0.7,0) lands at (-1,0.7,0); v4=(-1.3,0.2,0) is 0.56
    // away — WAY outside 1e-4 → no spatial pairs found → command is a no-op.
    auto r = postCommandJ(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false
    }}`);
    // The command is expected to return "error" (no-op: nothing moved).
    // Either way, v4 must be unchanged.

    auto m = getModel();
    auto v4 = vertAt(m, 4);

    assert(approxEq(v4[0], -1.3),
        "Stage 2 discriminator: spatial should leave large-drift v4 at -1.3, "
        ~ "got " ~ v4[0].to!string);
}

// ---------------------------------------------------------------------------
// Stage 2 undo — topological symmetrize is undoable
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    loadMesh(
        `[[0,1,0],[0,-1,0],[1,0.7,0],[1,-0.7,0],[-1.3,0.2,0],[-1.3,-0.2,0]]`,
        `[[0,2,3,1],[0,1,5,4]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":true
    }}`);

    // Confirm move happened.
    auto after = getModel();
    assert(approxEq(vertAt(after, 4)[0], -1.0),
        "Stage 2 undo: pre-undo v4.x should be -1.0");

    // Undo.
    auto undoR = postUndo();
    assert(undoR["status"].str == "ok",
        "Stage 2 undo: undo failed: " ~ undoR.toString);

    auto restored = getModel();
    assert(approxEq(vertAt(restored, 4)[0], -1.3),
        "Stage 2 undo: v4.x should restore to -1.3, got "
        ~ vertAt(restored, 4)[0].to!string);
}

// ---------------------------------------------------------------------------
// Stage 3a — on-plane projection
// A seam vert drifted slightly off the symmetry plane must be snapped
// back to X=0 after symmetrize.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // v0 at (0.04, 1, 0) — drifted off X=0 by 0.04, within epsilon=0.1.
    // v1 at (0.5, 0, 0), v2 at (-0.5, 0, 0) — a symmetric pair.
    loadMesh(
        `[[0.04,1,0],[0.5,0,0],[-0.5,0,0]]`,
        `[[0,1,2]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false,"epsilon":0.1
    }}`);

    auto m = getModel();
    auto v0 = vertAt(m, 0);

    assert(abs(v0[0]) < 1e-5,
        "Stage 3a: drifted seam vert should snap to X=0, got x=" ~ v0[0].to!string);
    // Y and Z should be unchanged.
    assert(approxEq(v0[1], 1.0),
        "Stage 3a: seam vert Y should be preserved");
}

// ---------------------------------------------------------------------------
// Stage 3b — unpaired vert safe degradation
// A mesh with a lone +X vert that has no topological or spatial partner
// (and no seam for topology seeding) must be left untouched.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // Single triangle with no X=0 seam and no -X partner for v2.
    //   v0=(0.1, 0, 0)  near-seam but within epsilon — on-plane
    //   v1=(1.0, 1, 0)  +X, no partner
    //   v2=(0.8, -1, 0) +X, no partner
    loadMesh(
        `[[0.1,0,0],[1,1,0],[0.8,-1,0]]`,
        `[[0,1,2]]`
    );

    postCommand(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false,"epsilon":0.15
    }}`);

    auto m = getModel();
    // v1 and v2 have no partners — they must be unchanged.
    assert(approxEq(vertAt(m, 1)[0], 1.0),
        "Stage 3b: unpaired v1.x must be unchanged");
    assert(approxEq(vertAt(m, 2)[0], 0.8),
        "Stage 3b: unpaired v2.x must be unchanged");
}

// ---------------------------------------------------------------------------
// Stage 3c — no-op does not pollute the undo stack
// Symmetrizing an already-symmetric mesh returns false (no history entry).
// The command reports status="error" (nothing applied) — verify the mesh
// is undamaged and count stays the same.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // The default cube IS already symmetric across X=0 (verts at ±0.5).
    // mesh.symmetrize should detect that nothing moved, push no history
    // entry, and return status="error".
    auto r = postCommandJ(`{"id":"mesh.symmetrize","params":{
        "axis":"X","side":"positive","topology":false,"epsilon":0.01
    }}`);
    assert(r["status"].str == "error",
        "Stage 3c: no-op on symmetric cube should return error, got "
        ~ r["status"].str);

    // Mesh must still be an intact 8-vert cube.
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "Stage 3c: already-symmetric cube must remain 8 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "Stage 3c: already-symmetric cube must remain 6 faces, got "
        ~ m["faceCount"].integer.to!string);
}
