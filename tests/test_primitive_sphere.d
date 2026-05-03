// Tests for subphase 6.2: prim.sphere headless command (Globe mode).
//
// Exercises the HTTP API surface for SphereTool / buildSphereGlobe:
//   - Default sides=24 segments=24       → 554 verts / 576 faces
//   - Small sides=6 segments=4           → 20 verts / 24 faces
//   - Off-center cenX=2 cenY=3 cenZ=-1   → all verts shifted, count unchanged
//   - axis=X / axis=Z                    → topology invariant, positions rotated
//   - Undo after prim.sphere             → restores empty scene
//   - JSON path parity                   → same result as argstring path

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

JSONValue primSphereArg(string params)
{
    return postJson("/api/command", "prim.sphere " ~ params);
}

JSONValue primSphereJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.sphere","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default sides=24 segments=24 → 554 verts / 576 faces
// -------------------------------------------------------------------------

unittest { // default Globe → 554v/576f
    resetEmpty();
    auto resp = primSphereArg("method:globe sides:24 segments:24 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "default sphere failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 554,
        "default sphere: expected 554 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 576,
        "default sphere: expected 576 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Small sides=6 segments=4 → 20 verts / 24 faces (12 tris, 12 quads)
// -------------------------------------------------------------------------

unittest { // small Globe sides=6 segments=4 → 20v/24f
    resetEmpty();
    auto resp = primSphereArg("method:globe sides:6 segments:4 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 20,
        "small sphere: expected 20 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24,
        "small sphere: expected 24 faces, got " ~ m["faces"].array.length.to!string);

    // 12 triangles (6 south fan + 6 north fan), 12 quads in the middle.
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
// 3. Off-center: all verts shifted by (cenX, cenY, cenZ)
// -------------------------------------------------------------------------

unittest { // off-center Globe shifts every vertex
    resetEmpty();
    auto resp = primSphereArg(
        "method:globe sides:6 segments:4 cenX:2.0 cenY:3.0 cenZ:-1.0 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 20);

    // Centroid of all verts equals (cenX, cenY, cenZ) — sphere is centrally symmetric.
    double cx = 0, cy = 0, cz = 0;
    foreach (v; m["vertices"].array) {
        cx += v.array[0].floating;
        cy += v.array[1].floating;
        cz += v.array[2].floating;
    }
    auto n = m["vertices"].array.length;
    cx /= n; cy /= n; cz /= n;
    assert(fabs(cx - 2.0) < 1e-4 && fabs(cy - 3.0) < 1e-4 && fabs(cz - (-1.0)) < 1e-4,
        "off-center: centroid expected (2,3,-1), got ("
        ~ cx.to!string ~ "," ~ cy.to!string ~ "," ~ cz.to!string ~ ")");
}

// -------------------------------------------------------------------------
// 4. axis=X and axis=Z keep the same topology as axis=Y
// -------------------------------------------------------------------------

unittest { // axis variations preserve vertex/face counts and tri/quad ratio
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primSphereArg(
            "method:globe sides:6 segments:4 axis:" ~ ax.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == 20,
            "axis=" ~ ax.to!string ~ ": expected 20 verts");
        assert(m["faces"].array.length == 24,
            "axis=" ~ ax.to!string ~ ": expected 24 faces");

        // All verts within unit-radius shell of origin.
        foreach (v; m["vertices"].array) {
            double x = v.array[0].floating;
            double y = v.array[1].floating;
            double z = v.array[2].floating;
            double r = sqrt(x * x + y * y + z * z);
            assert(fabs(r - 1.0) < 1e-3,
                "axis=" ~ ax.to!string ~ ": vert off unit shell, r=" ~ r.to!string);
        }
    }
}

// -------------------------------------------------------------------------
// 5. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo after prim.sphere restores empty mesh
    resetEmpty();
    auto r1 = primSphereArg("method:globe sides:6 segments:4 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
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
// 6. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON path produces same geometry as argstring
    resetEmpty();
    primSphereArg("method:globe sides:8 segments:6 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primSphereJson(`"method":"globe","sides":8,"segments":6,"sizeX":1.0,"sizeY":1.0,"sizeZ":1.0`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ, "JSON vs argstring vert count mismatch: "
        ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ, "JSON vs argstring face count mismatch: "
        ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // sides=8 segments=6 → 1 + 5*8 + 1 = 42 verts; 8 + 4*8 + 8 = 48 faces
    assert(vA == 42, "expected 42 verts, got " ~ vA.to!string);
    assert(fA == 48, "expected 48 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 7. QuadBall counts at order 0..3
//    Topology formula: 8 + 12*n + 6*n² verts, 6*(n+1)² faces.
// -------------------------------------------------------------------------

unittest { // QuadBall vertex/face counts across orders 0..3
    static struct OrderCase { int order; size_t verts; size_t faces; }
    OrderCase[] cases = [
        OrderCase(0,  8,  6),
        OrderCase(1, 26, 24),
        OrderCase(2, 56, 54),
        OrderCase(3, 98, 96),
    ];
    foreach (oc; cases) {
        resetEmpty();
        auto resp = primSphereArg("method:qball order:" ~ oc.order.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok",
            "qball order=" ~ oc.order.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == oc.verts,
            "qball order=" ~ oc.order.to!string ~ ": expected "
            ~ oc.verts.to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["faces"].array.length == oc.faces,
            "qball order=" ~ oc.order.to!string ~ ": expected "
            ~ oc.faces.to!string ~ " faces");
    }
}

// -------------------------------------------------------------------------
// 8. Tesselation (icosphere) counts at order 0..3
//    verts = 10n² + 20n + 12, faces = 20(n+1)², all triangles.
// -------------------------------------------------------------------------

unittest { // Tess vertex/face counts and all-triangle invariant
    static struct TessCase { int order; size_t verts; size_t faces; }
    TessCase[] cases = [
        TessCase(0,  12,  20),
        TessCase(1,  42,  80),
        TessCase(2,  92, 180),
        TessCase(3, 162, 320),
    ];
    foreach (tc; cases) {
        resetEmpty();
        auto resp = primSphereArg("method:tess order:" ~ tc.order.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok",
            "tess order=" ~ tc.order.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == tc.verts,
            "tess order=" ~ tc.order.to!string ~ ": expected "
            ~ tc.verts.to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["faces"].array.length == tc.faces,
            "tess order=" ~ tc.order.to!string ~ ": expected "
            ~ tc.faces.to!string ~ " faces");
        // All faces are triangles.
        foreach (f; m["faces"].array)
            assert(f.array.length == 3,
                "tess order=" ~ tc.order.to!string ~ ": non-tri face");
        // All verts on unit sphere.
        foreach (v; m["vertices"].array) {
            double x = v.array[0].floating;
            double y = v.array[1].floating;
            double z = v.array[2].floating;
            double r = sqrt(x * x + y * y + z * z);
            assert(fabs(r - 1.0) < 1e-3,
                "tess order=" ~ tc.order.to!string ~ ": vert off unit shell, r="
                ~ r.to!string);
        }
    }
}
