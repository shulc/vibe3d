// Tests for mesh.subdivide (Catmull-Clark) and mesh.subdivide_faceted.
//
// Catmull-Clark on a cube (8v / 12e / 6f), one step:
//   verts: 8 originals + 6 face points + 12 edge points = 26
//   faces: 6 × 4 = 24
//   edges: by Euler (V − E + F = 2 for a closed surface) = 48

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.array     : array;
import std.conv      : to;
import std.math      : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

// ---------------------------------------------------------------------------
// Catmull-Clark
// ---------------------------------------------------------------------------

unittest { // subdivide cube once → 26 / 48 / 24
    resetCube();
    runCmd("mesh.subdivide");
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "expected 26 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer == 48,
        "expected 48 edges, got " ~ m["edgeCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "expected 24 faces, got " ~ m["faceCount"].integer.to!string);
}

unittest { // every subdivided face is a quad
    resetCube();
    runCmd("mesh.subdivide");
    auto faces = model()["faces"].array;
    foreach (i, f; faces)
        assert(f.array.length == 4,
            "face " ~ i.to!string ~ " is not a quad");
}

unittest { // subdivide is volume-preserving on average — face points are
           // weighted averages, so they stay inside the original cube AABB.
    resetCube();
    runCmd("mesh.subdivide");
    auto verts = model()["vertices"].array;
    foreach (v; verts) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        assert(x >= -0.5 - 1e-6 && x <= 0.5 + 1e-6,
            "subdivided vertex x out of [-0.5, 0.5]: " ~ x.to!string);
        assert(y >= -0.5 - 1e-6 && y <= 0.5 + 1e-6, "y OOR");
        assert(z >= -0.5 - 1e-6 && z <= 0.5 + 1e-6, "z OOR");
    }
}

unittest { // double-subdivide: 26 → ?, then check Euler holds
    resetCube();
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");
    auto m = model();
    long V = m["vertexCount"].integer;
    long E = m["edgeCount"].integer;
    long F = m["faceCount"].integer;
    // Closed surface, genus 0: V - E + F = 2.
    assert(V - E + F == 2,
        "Euler violated after 2 subdivides: V=" ~ V.to!string
        ~ " E=" ~ E.to!string ~ " F=" ~ F.to!string);
    // Every face still a quad.
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 4,
            "face " ~ i.to!string ~ " is not a quad after second subdivide");
}

// ---------------------------------------------------------------------------
// Selection-aware subdivide
// ---------------------------------------------------------------------------

unittest { // subdivide only one selected face → topology grows by less than full
    resetCube();
    setSelection("polygons", [0]);  // back face only
    runCmd("mesh.subdivide");
    auto m = model();
    long V = m["vertexCount"].integer;
    long F = m["faceCount"].integer;
    // Full cube subdivide gives 26 / 24. Selecting one face gives strictly
    // fewer of each — the unselected faces stay intact (possibly merged into
    // n-gons at the boundary, but never expanded into 4 quads).
    assert(V < 26,
        "selected subdivide should add fewer verts than a full one (got V=" ~ V.to!string ~ ")");
    assert(F < 24,
        "selected subdivide should add fewer faces (got F=" ~ F.to!string ~ ")");
    assert(F > 6,
        "selected subdivide should still add some faces (got F=" ~ F.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Faceted subdivide
// ---------------------------------------------------------------------------

unittest { // faceted subdivide on cube — same topology as CC, but verts stay on
           // the original cube faces (no smoothing pull-in).
    resetCube();
    runCmd("mesh.subdivide_faceted");
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "expected 26 verts after faceted subdivide, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "expected 24 faces after faceted subdivide, got " ~ m["faceCount"].integer.to!string);

    // Faceted = no smoothing → every vert lies exactly on a cube face.
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        bool onSurface =
            approxEqual(fabs(x), 0.5) ||
            approxEqual(fabs(y), 0.5) ||
            approxEqual(fabs(z), 0.5);
        assert(onSurface,
            "faceted vertex should lie on a cube face: ("
            ~ x.to!string ~ ", " ~ y.to!string ~ ", " ~ z.to!string ~ ")");
    }
}
