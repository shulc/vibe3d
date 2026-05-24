// Tests for subphase 6.5: prim.cylinder headless command.
//
// Exercises the HTTP API surface for CylinderTool / buildCylinder:
//   - Default sides=24 segments=1 axis=Y    → 48 verts / 26 faces
//   - Segmented sides=8 segments=2          → 24 verts / 18 faces
//   - Disk sizeY=0 axis=Y                   → S verts / 1 face (single n-gon)
//   - axis=X / axis=Z                       → topology invariant, positions rotated
//   - Off-center                            → centroid shifts, count unchanged
//   - Undo after prim.cylinder              → restores empty scene
//   - JSON path parity                      → same result as argstring path
//   - Topology invariants                   → all side faces quads, ring sizes correct

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

JSONValue primCylinderArg(string params)
{
    return postJson("/api/command", "prim.cylinder " ~ params);
}

JSONValue primCylinderJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.cylinder","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default sides=24 segments=1 axis=Y → 48 verts / 26 faces
//    (24 side quads + 2 cap n-gons; 2*24 = 48 ring verts)
// -------------------------------------------------------------------------

unittest { // default cylinder counts
    resetEmpty();
    auto resp = primCylinderArg("sides:24 segments:1 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "default cylinder failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 48,
        "default cylinder: expected 48 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 26,
        "default cylinder: expected 26 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Segmented sides=8 segments=2 → 24 verts / 18 faces (16 side quads + 2 caps)
// -------------------------------------------------------------------------

unittest { // segmented topology
    resetEmpty();
    auto resp = primCylinderArg("sides:8 segments:2 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 24,
        "segmented: expected 24 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 18,
        "segmented: expected 18 faces, got " ~ m["faces"].array.length.to!string);

    // 16 quads (side strips) + 2 8-gon caps.
    int quads = 0, ngons = 0;
    foreach (f; m["faces"].array) {
        auto n = f.array.length;
        if      (n == 4) ++quads;
        else if (n == 8) ++ngons;
    }
    assert(quads == 16, "expected 16 quads, got " ~ quads.to!string);
    assert(ngons == 2,  "expected 2 octagonal caps, got " ~ ngons.to!string);
}

// -------------------------------------------------------------------------
// 3. Disk degenerate (sizeY=0, axis=Y) — single S-gon, no quads.
// -------------------------------------------------------------------------

unittest { // disk degenerate
    resetEmpty();
    auto resp = primCylinderArg("sides:8 segments:1 axis:1 sizeX:1.0 sizeY:0.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 8,
        "disk: expected 8 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "disk: expected 1 face, got " ~ m["faces"].array.length.to!string);
    assert(m["faces"].array[0].array.length == 8,
        "disk: face must be 8-gon");

    // All verts at y = 0 (in the disk's own plane) and on a unit circle in XZ.
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        assert(fabs(y) < 1e-4, "disk vert off plane: y=" ~ y.to!string);
        double r = sqrt(x * x + z * z);
        assert(fabs(r - 1.0) < 1e-3, "disk vert off unit circle: r=" ~ r.to!string);
    }
}

// -------------------------------------------------------------------------
// 4. axis=X / axis=Y / axis=Z keep the same topology
// -------------------------------------------------------------------------

unittest { // axis variations preserve counts; cap orientation rotates
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primCylinderArg(
            "sides:8 segments:1 axis:" ~ ax.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == 16,
            "axis=" ~ ax.to!string ~ ": expected 16 verts");
        assert(m["faces"].array.length == 10,
            "axis=" ~ ax.to!string ~ ": expected 10 faces (8 quads + 2 caps)");

        // Verify cap orientation: every vert's coord along the axis must be ±1
        // (caps sit at ±sizeAxis), perp coords lie on a unit circle.
        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating, v.array[1].floating, v.array[2].floating];
            assert(fabs(fabs(p[ax]) - 1.0) < 1e-4,
                "axis=" ~ ax.to!string ~ ": cap coord not ±1, got " ~ p[ax].to!string);
            double bp = p[(ax + 1) % 3];
            double cp = p[(ax + 2) % 3];
            double r  = sqrt(bp * bp + cp * cp);
            assert(fabs(r - 1.0) < 1e-3,
                "axis=" ~ ax.to!string ~ ": perp radius not 1, got " ~ r.to!string);
        }
    }
}

// -------------------------------------------------------------------------
// 5. Off-center: centroid of all verts equals (cenX, cenY, cenZ)
// -------------------------------------------------------------------------

unittest { // off-center centroid
    resetEmpty();
    auto resp = primCylinderArg(
        "sides:8 segments:1 axis:1 cenX:2.0 cenY:3.0 cenZ:-1.0 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 16);

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
// 6. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo restores empty
    resetEmpty();
    auto r1 = primCylinderArg("sides:8 segments:1 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 16, "before undo: expected 16 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 7. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON vs argstring give identical geometry
    resetEmpty();
    primCylinderArg("sides:12 segments:3 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primCylinderJson(`"sides":12,"segments":3,"axis":1,"sizeX":1.0,"sizeY":1.0,"sizeZ":1.0`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ, "JSON vs argstring vert count: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ, "JSON vs argstring face count: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // sides=12 segments=3 → (segments+1)*sides = 48 verts;
    //                       2 + segments*sides = 38 faces.
    assert(vA == 48, "expected 48 verts, got " ~ vA.to!string);
    assert(fA == 38, "expected 38 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 8. Topology invariant: total face count = 2 + segments * sides;
//    cap face counts always equal 'sides'.
// -------------------------------------------------------------------------

unittest { // topology formula across (sides, segments) grid
    static struct Case { int sides; int segments; }
    Case[] cases = [
        Case(3, 1), Case(4, 1), Case(5, 2), Case(8, 4), Case(16, 1), Case(24, 2),
    ];
    foreach (c; cases) {
        resetEmpty();
        auto resp = primCylinderArg(
            "sides:" ~ c.sides.to!string ~ " segments:" ~ c.segments.to!string
            ~ " axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok",
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        size_t expectedV = (c.segments + 1) * c.sides;
        size_t expectedF = 2 + c.segments * c.sides;
        assert(m["vertices"].array.length == expectedV,
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string
            ~ ": expected " ~ expectedV.to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["faces"].array.length == expectedF,
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string
            ~ ": expected " ~ expectedF.to!string ~ " faces");

        // For sides != 4 the side strips are quads and the caps are unique
        // n-gons, so face-vertex distribution is diagnostic. (At sides == 4
        // the caps and side strips are both 4-gons — the total count check
        // above is the only invariant.)
        if (c.sides != 4) {
            int caps = 0, quads = 0;
            foreach (f; m["faces"].array) {
                auto n = f.array.length;
                if      (n == c.sides) ++caps;
                else if (n == 4)       ++quads;
            }
            assert(caps == 2,
                "sides=" ~ c.sides.to!string ~ ": expected 2 cap "
                ~ c.sides.to!string ~ "-gons, got " ~ caps.to!string);
            assert(quads == c.segments * c.sides,
                "sides=" ~ c.sides.to!string ~ ": expected "
                ~ (c.segments * c.sides).to!string ~ " side quads, got "
                ~ quads.to!string);
        }
    }
}

// -------------------------------------------------------------------------
// 9. Ellipsoidal radii: per-axis sizes are honoured (verts span [-sizeX, sizeX]
//    in X, similarly for Z; for axis=Y, Y spans [-sizeY, sizeY]).
// -------------------------------------------------------------------------

unittest { // ellipsoidal axis=Y
    resetEmpty();
    auto resp = primCylinderArg(
        "sides:8 segments:1 axis:1 cenX:0.0 cenY:0.0 cenZ:0.0 sizeX:0.5 sizeY:2.0 sizeZ:1.5");
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
    assert(fabs(minX - (-0.5)) < 1e-4 && fabs(maxX - 0.5) < 1e-4,
        "ellipsoidal X bounds: [" ~ minX.to!string ~ "," ~ maxX.to!string ~ "]");
    assert(fabs(minY - (-2.0)) < 1e-4 && fabs(maxY - 2.0) < 1e-4,
        "ellipsoidal Y bounds: [" ~ minY.to!string ~ "," ~ maxY.to!string ~ "]");
    assert(fabs(minZ - (-1.5)) < 1e-4 && fabs(maxZ - 1.5) < 1e-4,
        "ellipsoidal Z bounds: [" ~ minZ.to!string ~ "," ~ maxZ.to!string ~ "]");
}
