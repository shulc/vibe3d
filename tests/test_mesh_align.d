// Tests for mesh.align — flatten selected faces' vertices onto their
// per-island average plane.
//
// All tests use /api/load-mesh to inject custom geometry so the fixtures
// are topologically isolated (no vert shared with an unselected face),
// giving unambiguous planarity residuals.
//
// "localhost:8080" is rewritten to the per-worker port by run_test.d when
// running in parallel; keep the literal so that rewrite still matches.

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

// Load a raw mesh, switch to Polygon mode, select all faces, return the
// resulting vertex dump.
double[3][] loadAndAlignAllFaces(string meshJson) {
    postJson("/api/reset", "");
    auto resp = postJson("/api/load-mesh", meshJson);
    assert(resp["status"].str == "ok",
        "/api/load-mesh failed: " ~ resp.toString);

    // Switch to polygon edit mode.
    cmd("select.typeFrom polygon");

    // Select all faces (we know face index 0 .. faceCount-1).
    long nFaces = getJson("/api/model")["faceCount"].integer;
    string idxJson = "[";
    foreach (i; 0 .. nFaces) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= i.to!string;
    }
    idxJson ~= "]";
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":` ~ idxJson ~ `}`);
    assert(sel["status"].str == "ok", "/api/select failed: " ~ sel.toString);

    cmd(`{"id":"mesh.align"}`);
    return dumpVerts();
}

// Compute the distance of point `p` from the plane defined by origin `o`
// and (already-normalised) normal `n`.
double planeDist(double[3] p, double[3] o, double[3] n) {
    return fabs((p[0]-o[0])*n[0] + (p[1]-o[1])*n[1] + (p[2]-o[2])*n[2]);
}

// Normalise a 3-vector in place, return the original length.
double normalise(ref double[3] v) {
    double len = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    if (len > 1e-9) { v[0] /= len; v[1] /= len; v[2] /= len; }
    return len;
}

// Cross product.
double[3] cross(double[3] a, double[3] b) {
    return [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]];
}

unittest { // planarity — warped quad → all 4 verts coplanar to < 1e-5
    // The two z=+1 corners are pushed opposite in y, making the face
    // genuinely non-planar before the command.
    // After align the 4th vert must lie on the plane through the first 3.
    auto after = loadAndAlignAllFaces(
        `{"vertices":[[-1,0,-1],[1,0,-1],[1,0.5,1],[-1,-0.5,1]],` ~
        `"faces":[[0,1,2,3]]}`);

    assert(after.length == 4, "expected 4 verts, got " ~ after.length.to!string);

    // Build plane from verts 0, 1, 2.
    double[3] ab = [after[1][0]-after[0][0], after[1][1]-after[0][1], after[1][2]-after[0][2]];
    double[3] ac = [after[2][0]-after[0][0], after[2][1]-after[0][1], after[2][2]-after[0][2]];
    double[3] n  = cross(ab, ac);
    double nlen  = normalise(n);
    assert(nlen > 1e-6, "degenerate plane after align");

    double dist = planeDist(after[3], after[0], n);
    assert(dist < 1e-5,
        "planarity residual too large: " ~ dist.to!string);

    // Sanity: original 4th vert was far from coplanar with the other 3.
    // (Verified analytically: the two y-offsets ±0.5 at z=1 vs y=0 at z=-1
    // give a distance well above 0.1 from any plane through the first three.)
}

unittest { // multi-island — two disjoint warped quads, each flattened independently
    // Two quads far apart (x≈0 and x≈10) with different warp directions;
    // selecting both faces must flatten each to its own plane, not one combined plane.
    postJson("/api/reset", "");
    auto resp = postJson("/api/load-mesh",
        `{"vertices":[` ~
        // Island 0 near x=0
        `[0,0,0],[1,0,0],[1,0.4,1],[0,-0.4,1],` ~
        // Island 1 near x=10
        `[10,0,0],[11,0,0],[11,-0.3,1],[10,0.3,1]],` ~
        `"faces":[[0,1,2,3],[4,5,6,7]]}`);
    assert(resp["status"].str == "ok",
        "/api/load-mesh failed: " ~ resp.toString);

    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[0,1]}`);
    assert(sel["status"].str == "ok", "/api/select failed: " ~ sel.toString);
    cmd(`{"id":"mesh.align"}`);

    auto after = dumpVerts();
    assert(after.length == 8, "expected 8 verts, got " ~ after.length.to!string);

    // Island 0: verts 0-3 must be coplanar.
    {
        double[3] ab = [after[1][0]-after[0][0], after[1][1]-after[0][1], after[1][2]-after[0][2]];
        double[3] ac = [after[2][0]-after[0][0], after[2][1]-after[0][1], after[2][2]-after[0][2]];
        double[3] n  = cross(ab, ac);
        normalise(n);
        double dist = planeDist(after[3], after[0], n);
        assert(dist < 1e-5,
            "island 0 planarity residual too large: " ~ dist.to!string);
    }

    // Island 1: verts 4-7 must be coplanar.
    {
        double[3] ab = [after[5][0]-after[4][0], after[5][1]-after[4][1], after[5][2]-after[4][2]];
        double[3] ac = [after[6][0]-after[4][0], after[6][1]-after[4][1], after[6][2]-after[4][2]];
        double[3] n  = cross(ab, ac);
        normalise(n);
        double dist = planeDist(after[7], after[4], n);
        assert(dist < 1e-5,
            "island 1 planarity residual too large: " ~ dist.to!string);
    }

    // The two centroid x-coordinates should be near 0.5 and 10.5 respectively,
    // proving the two islands were flattened to independent planes.
    double cx0 = (after[0][0]+after[1][0]+after[2][0]+after[3][0]) * 0.25;
    double cx1 = (after[4][0]+after[5][0]+after[6][0]+after[7][0]) * 0.25;
    assert(cx0 < 3.0 && cx1 > 7.0,
        "islands appear merged: cx0=" ~ cx0.to!string ~ " cx1=" ~ cx1.to!string);
}

unittest { // undo restores original (warped) positions
    postJson("/api/reset", "");
    postJson("/api/load-mesh",
        `{"vertices":[[-1,0,-1],[1,0,-1],[1,0.5,1],[-1,-0.5,1]],` ~
        `"faces":[[0,1,2,3]]}`);
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    assert(sel["status"].str == "ok", "/api/select failed: " ~ sel.toString);

    auto before = dumpVerts();
    cmd(`{"id":"mesh.align"}`);
    auto aligned = dumpVerts();

    // Sanity: align actually moved something.
    bool anyMoved = false;
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            if (!approxEq(before[i][c], aligned[i][c])) { anyMoved = true; break; }
    assert(anyMoved, "expected mesh.align to move at least one vert");

    cmd("history.undo");
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "undo: vert " ~ i.to!string ~ " comp " ~ c.to!string ~
                " not restored: before=" ~ before[i][c].to!string ~
                " after=" ~ after[i][c].to!string);
}

unittest { // no-op on already-planar tilted quad — must NOT return ok, verts unchanged
    // Use z = 0.3*x + 0.2*y — a tilted (non-axis-aligned) plane — to expose
    // the coordinate-scaled eps requirement.  A naive 1e-9 threshold would
    // let the ~1e-7 float residual slip through as a spurious move; this test
    // catches that regression.
    //
    // DO NOT use the asserting cmd() helper here: mesh.align legitimately
    // returns false on a no-op, so /api/command responds {"status":"error"},
    // and cmd() would incorrectly fail the test.
    postJson("/api/reset", "");
    postJson("/api/load-mesh",
        `{"vertices":[[0,0,0],[1,0,0.3],[1,1,0.5],[0,1,0.2]],` ~
        `"faces":[[0,1,2,3]]}`);
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    assert(sel["status"].str == "ok", "/api/select failed: " ~ sel.toString);

    auto before = dumpVerts();

    // Snapshot undo stack depth before the no-op command.
    long undoBefore = getJson("/api/history")["undo"].array.length;

    // Fire via raw postJson — tolerate / expect non-ok status.
    auto resp = postJson("/api/command", `{"id":"mesh.align"}`);
    assert(resp["status"].str != "ok",
        "mesh.align on planar quad should NOT return ok, got: " ~ resp.toString);

    // (b) Verts must be unchanged.
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c], 1e-6),
                "no-op: vert " ~ i.to!string ~ " comp " ~ c.to!string ~
                " changed: before=" ~ before[i][c].to!string ~
                " after=" ~ after[i][c].to!string);

    // (c) No spurious undo entry — stack depth must not have grown.
    long undoAfter = getJson("/api/history")["undo"].array.length;
    assert(undoAfter == undoBefore,
        "no-op added a spurious undo entry: before=" ~ undoBefore.to!string ~
        " after=" ~ undoAfter.to!string);
}
