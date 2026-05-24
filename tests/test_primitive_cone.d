// Tests for subphase 6.6: prim.cone headless command.
//
// Exercises the HTTP API surface for ConeTool / buildCone:
//   - Default sides=24 segments=1 axis=Y    → 25 verts / 25 faces (1 cap + 24 tris)
//   - Segmented sides=4 segments=2          → 9 verts / 9 faces (cap + 4 quads + 4 tris)
//   - axis=X / axis=Z                       → topology invariant
//   - Off-center                            → centroid-of-base shifts, count unchanged
//   - Undo after prim.cone                  → restores empty scene
//   - JSON path parity                      → same result as argstring path
//   - Topology formula                      → V = N·S + 1, F = 1 + N·S

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

JSONValue primConeArg(string params)
{
    return postJson("/api/command", "prim.cone " ~ params);
}

JSONValue primConeJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.cone","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default sides=24 segments=1 axis=Y → 25 verts / 25 faces
// -------------------------------------------------------------------------

unittest { // default cone
    resetEmpty();
    auto resp = primConeArg("sides:24 segments:1 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "default cone failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 25,
        "default: expected 25 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 25,
        "default: expected 25 faces, got " ~ m["faces"].array.length.to!string);
    // 1 24-gon cap + 24 triangles.
    int caps = 0, tris = 0;
    foreach (f; m["faces"].array) {
        auto n = f.array.length;
        if      (n == 24) ++caps;
        else if (n == 3)  ++tris;
    }
    assert(caps == 1, "expected 1 cap n-gon, got " ~ caps.to!string);
    assert(tris == 24, "expected 24 apex triangles, got " ~ tris.to!string);
}

// -------------------------------------------------------------------------
// 2. Segmented sides=4 segments=2 → 9 verts / 9 faces (cap + 4 quads + 4 tris)
// -------------------------------------------------------------------------

unittest { // segmented cone
    resetEmpty();
    auto resp = primConeArg("sides:4 segments:2 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 9,
        "segmented: expected 9 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 9,
        "segmented: expected 9 faces, got " ~ m["faces"].array.length.to!string);

    int quads = 0, tris = 0;
    foreach (f; m["faces"].array) {
        auto n = f.array.length;
        if      (n == 4) ++quads;
        else if (n == 3) ++tris;
    }
    // 4 cap (sides=4 → cap is a quad) + 4 quad strips + 4 apex tris = 5 quads + 4 tris.
    // (sides==4 happens to make the cap and the strip quads indistinguishable.)
    assert(quads == 5, "expected 5 quads, got " ~ quads.to!string);
    assert(tris == 4,  "expected 4 apex triangles, got " ~ tris.to!string);
}

// -------------------------------------------------------------------------
// 3. axis=X / axis=Y / axis=Z keep the same topology
// -------------------------------------------------------------------------

unittest { // axis variations preserve counts
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primConeArg(
            "sides:8 segments:1 axis:" ~ ax.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        // 8·1 + 1 = 9 verts; 1 + 1·8 = 9 faces.
        assert(m["vertices"].array.length == 9,
            "axis=" ~ ax.to!string ~ ": expected 9 verts");
        assert(m["faces"].array.length == 9,
            "axis=" ~ ax.to!string ~ ": expected 9 faces");

        // Apex sits at +size on the active axis; base ring at -size.
        // Other coords on the apex are exactly cen (which we set to 0).
        int apexCount = 0;
        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating, v.array[1].floating, v.array[2].floating];
            int b = (ax + 1) % 3;
            int c = (ax + 2) % 3;
            if (fabs(p[ax] - 1.0) < 1e-4 && fabs(p[b]) < 1e-4 && fabs(p[c]) < 1e-4)
                ++apexCount;
        }
        assert(apexCount == 1,
            "axis=" ~ ax.to!string ~ ": expected exactly one apex on +axis");
    }
}

// -------------------------------------------------------------------------
// 4. Off-center: base centroid is at (cenX, cenY-size, cenZ) for axis=Y
// -------------------------------------------------------------------------

unittest { // off-center cone preserves base / apex world positions
    resetEmpty();
    auto resp = primConeArg(
        "sides:8 segments:1 axis:1 cenX:2.0 cenY:3.0 cenZ:-1.0 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 9);

    // The apex of the cone should be at (2, 3+1, -1) = (2, 4, -1) for axis=Y.
    bool foundApex = false;
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        if (fabs(x - 2.0) < 1e-4 && fabs(y - 4.0) < 1e-4 && fabs(z - (-1.0)) < 1e-4) {
            foundApex = true;
            break;
        }
    }
    assert(foundApex, "off-center: apex expected at (2, 4, -1)");
}

// -------------------------------------------------------------------------
// 5. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo restores empty
    resetEmpty();
    auto r1 = primConeArg("sides:8 segments:1 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 9, "before undo: expected 9 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 6. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON ↔ argstring parity
    resetEmpty();
    primConeArg("sides:12 segments:3 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primConeJson(`"sides":12,"segments":3,"axis":1,"sizeX":1.0,"sizeY":1.0,"sizeZ":1.0`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ, "JSON vs argstring vert count: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ, "JSON vs argstring face count: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // sides=12 segments=3 → V = 3·12 + 1 = 37; F = 1 + 3·12 = 37.
    assert(vA == 37, "expected 37 verts, got " ~ vA.to!string);
    assert(fA == 37, "expected 37 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 7. Topology formula: V = N·S + 1, F = 1 + N·S
// -------------------------------------------------------------------------

unittest { // topology grid
    static struct Case { int sides; int segments; }
    Case[] cases = [
        Case(3, 1), Case(5, 1), Case(8, 1),
        Case(4, 2), Case(8, 3), Case(16, 4),
    ];
    foreach (c; cases) {
        resetEmpty();
        auto resp = primConeArg(
            "sides:" ~ c.sides.to!string ~ " segments:" ~ c.segments.to!string
            ~ " axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok",
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        size_t expectedV = c.segments * c.sides + 1;
        size_t expectedF = 1 + c.segments * c.sides;
        assert(m["vertices"].array.length == expectedV,
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string
            ~ ": expected " ~ expectedV.to!string ~ " verts");
        assert(m["faces"].array.length == expectedF,
            "sides=" ~ c.sides.to!string ~ " segments=" ~ c.segments.to!string
            ~ ": expected " ~ expectedF.to!string ~ " faces");
    }
}

// -------------------------------------------------------------------------
// 8. Apex sits on the cone's main axis at +size
// -------------------------------------------------------------------------

unittest { // apex on axis
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        primConeArg(
            "sides:8 segments:1 axis:" ~ ax.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        auto m = getModel();
        // Find the unique vertex with the largest coord along the axis;
        // it's the apex. Its perpendicular coords must be 0.
        double bestA = -double.max;
        int    bestI = -1;
        foreach (i, v; m["vertices"].array) {
            double a = v.array[ax].floating;
            if (a > bestA) { bestA = a; bestI = cast(int)i; }
        }
        assert(bestI >= 0);
        auto v = m["vertices"].array[bestI];
        double pa = v.array[ax].floating;
        double pb = v.array[(ax + 1) % 3].floating;
        double pc = v.array[(ax + 2) % 3].floating;
        assert(fabs(pa - 1.0) < 1e-4,
            "axis=" ~ ax.to!string ~ ": apex coord on axis expected 1.0, got " ~ pa.to!string);
        assert(fabs(pb) < 1e-4 && fabs(pc) < 1e-4,
            "axis=" ~ ax.to!string ~ ": apex must lie on the axis line");
    }
}
