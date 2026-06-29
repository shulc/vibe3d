// Tests for prim.ellipsoid headless command (globe-locked, per-axis radii).
//
// Exercises the HTTP API surface for the ellipsoid SphereTool preset:
//   - Default sides=24 segments=24 with non-equal radii → same 554v/576f as globe sphere
//   - Small sides=6 segments=4                           → 20v/24f (12 tris, 12 quads)
//   - Implicit-equation golden: (x/rx)²+(y/ry)²+(z/rz)²≈1 per vertex
//   - Bbox extents equal the radii under default axis=Y
//   - Off-center cenX/Y/Z shifts centroid
//   - Undo after prim.ellipsoid restores empty scene
//   - JSON path parity with argstring path
//   - axis=X permutation: world-X extent == sizeY

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;

void main() {}

string baseUrl = "http://localhost:8080";

string apiUrl(string path) { return baseUrl ~ path; }

JSONValue postJson(string path, string body_)
{
    return parseJSON(cast(string) post(apiUrl(path), body_));
}

JSONValue getModel()
{
    return parseJSON(cast(string) get(apiUrl("/api/model")));
}

void resetEmpty()
{
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

JSONValue primEllipsoidArg(string params)
{
    return postJson("/api/command", "prim.ellipsoid " ~ params);
}

JSONValue primEllipsoidJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.ellipsoid","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default sides=24 segments=24 → same 554v/576f as globe sphere
//    (radii don't affect topology)
// -------------------------------------------------------------------------

unittest { // non-equal radii → 554v/576f
    resetEmpty();
    auto resp = primEllipsoidArg("sides:24 segments:24 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    assert(resp["status"].str == "ok", "default ellipsoid failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 554,
        "default ellipsoid: expected 554 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 576,
        "default ellipsoid: expected 576 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Small sides=6 segments=4 → 20v/24f (12 tris, 12 quads)
// -------------------------------------------------------------------------

unittest { // small ellipsoid sides=6 segments=4 → 20v/24f
    resetEmpty();
    auto resp = primEllipsoidArg("sides:6 segments:4 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 20,
        "small ellipsoid: expected 20 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24,
        "small ellipsoid: expected 24 faces, got " ~ m["faces"].array.length.to!string);

    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        auto n = f.array.length;
        if      (n == 3) ++tris;
        else if (n == 4) ++quads;
    }
    assert(tris == 12, "expected 12 tris, got " ~ tris.to!string);
    assert(quads == 12, "expected 12 quads, got " ~ quads.to!string);
}

// -------------------------------------------------------------------------
// 3. Implicit-equation golden (axis=Y default, centered at origin):
//    every vertex satisfies (x/rx)²+(y/ry)²+(z/rz)²≈1
// -------------------------------------------------------------------------

unittest { // implicit ellipsoid equation holds for every vertex (axis=Y)
    immutable double rx = 1.0, ry = 2.0, rz = 0.5;
    resetEmpty();
    auto resp = primEllipsoidArg(
        "sides:24 segments:24 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();

    foreach (i, v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        double eq = (x / rx) * (x / rx)
                  + (y / ry) * (y / ry)
                  + (z / rz) * (z / rz);
        assert(fabs(eq - 1.0) < 1e-3,
            "vert " ~ i.to!string
            ~ " fails ellipsoid eq: got " ~ eq.to!string
            ~ " at (" ~ x.to!string ~ "," ~ y.to!string ~ "," ~ z.to!string ~ ")");
    }
}

// -------------------------------------------------------------------------
// 4. Bbox extents equal the radii under default axis=Y
// -------------------------------------------------------------------------

unittest { // bbox extents == sizeX/Y/Z for axis=Y
    immutable float rx = 1.5f, ry = 2.5f, rz = 0.75f;
    resetEmpty();
    auto resp = primEllipsoidArg(
        "sides:24 segments:24 sizeX:1.5 sizeY:2.5 sizeZ:0.75");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();

    double minX = double.max, maxX = -double.max;
    double minY = double.max, maxY = -double.max;
    double minZ = double.max, maxZ = -double.max;
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
        if (z < minZ) minZ = z; if (z > maxZ) maxZ = z;
    }
    assert(fabs(maxX - rx) < 1e-3 && fabs(minX + rx) < 1e-3,
        "X extent mismatch: [" ~ minX.to!string ~ ", " ~ maxX.to!string ~ "]");
    assert(fabs(maxY - ry) < 1e-3 && fabs(minY + ry) < 1e-3,
        "Y extent mismatch: [" ~ minY.to!string ~ ", " ~ maxY.to!string ~ "]");
    assert(fabs(maxZ - rz) < 1e-3 && fabs(minZ + rz) < 1e-3,
        "Z extent mismatch: [" ~ minZ.to!string ~ ", " ~ maxZ.to!string ~ "]");
}

// -------------------------------------------------------------------------
// 5. Off-center: centroid ≈ (cenX, cenY, cenZ)
// -------------------------------------------------------------------------

unittest { // off-center ellipsoid shifts centroid
    resetEmpty();
    auto resp = primEllipsoidArg(
        "sides:6 segments:4 cenX:3.0 cenY:-1.5 cenZ:2.0 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 20);

    double cx = 0, cy = 0, cz = 0;
    foreach (v; m["vertices"].array) {
        cx += v.array[0].floating;
        cy += v.array[1].floating;
        cz += v.array[2].floating;
    }
    auto n = m["vertices"].array.length;
    cx /= n; cy /= n; cz /= n;
    assert(fabs(cx - 3.0)  < 1e-4 &&
           fabs(cy + 1.5)  < 1e-4 &&
           fabs(cz - 2.0)  < 1e-4,
        "off-center: centroid expected (3,-1.5,2), got ("
        ~ cx.to!string ~ "," ~ cy.to!string ~ "," ~ cz.to!string ~ ")");
}

// -------------------------------------------------------------------------
// 6. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo after prim.ellipsoid restores empty mesh
    resetEmpty();
    auto r1 = primEllipsoidArg("sides:6 segments:4 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 20, "before undo: expected 20 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 7. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON path produces same geometry as argstring
    resetEmpty();
    primEllipsoidArg("sides:8 segments:6 sizeX:1.0 sizeY:2.0 sizeZ:0.5");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primEllipsoidJson(`"sides":8,"segments":6,"sizeX":1.0,"sizeY":2.0,"sizeZ":0.5`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ, "JSON vs argstring vert count mismatch: "
        ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ, "JSON vs argstring face count mismatch: "
        ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // sides=8 segments=6 → (6-1)*8+2 = 42 verts; 8*6 = 48 faces
    assert(vA == 42, "expected 42 verts, got " ~ vA.to!string);
    assert(fA == 48, "expected 48 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 8. axis=X permutation: world-X extent comes from sizeY (cyclic shift)
//    buildSphereGlobe axisX maps local-Y → world-X, so max|world-X|=sizeY.
// -------------------------------------------------------------------------

unittest { // axis=X: world extents follow the axisX cyclic permutation
    // axisX permutation: (localX,localY,localZ) → (localY,localZ,localX)
    // So world-X ∈ [-sizeY, +sizeY], world-Y ∈ [-sizeZ, +sizeZ],
    //    world-Z ∈ [-sizeX, +sizeX].
    immutable double sizeX = 0.5, sizeY = 1.5, sizeZ = 0.75;
    resetEmpty();
    auto resp = primEllipsoidArg(
        "sides:24 segments:24 axis:0 sizeX:0.5 sizeY:1.5 sizeZ:0.75");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();

    double maxWX = 0, maxWY = 0, maxWZ = 0;
    foreach (v; m["vertices"].array) {
        double ax = fabs(v.array[0].floating);
        double ay = fabs(v.array[1].floating);
        double az = fabs(v.array[2].floating);
        if (ax > maxWX) maxWX = ax;
        if (ay > maxWY) maxWY = ay;
        if (az > maxWZ) maxWZ = az;
    }
    assert(fabs(maxWX - sizeY) < 1e-3,
        "axisX: expected world-X extent=" ~ sizeY.to!string ~ ", got " ~ maxWX.to!string);
    assert(fabs(maxWY - sizeZ) < 1e-3,
        "axisX: expected world-Y extent=" ~ sizeZ.to!string ~ ", got " ~ maxWY.to!string);
    assert(fabs(maxWZ - sizeX) < 1e-3,
        "axisX: expected world-Z extent=" ~ sizeX.to!string ~ ", got " ~ maxWZ.to!string);
}
