// Tests for prim.tube — hollow cylinder primitive.
//
// Exercises the HTTP API surface for TubeTool / buildTube:
//   - Default segments=24 axis=Y, cap=true   → 96 verts / 96 faces
//   - Small  segments=6                       → 24 verts / 24 faces
//   - Watertight + directed-half-edge consistency (capped)
//   - Per-family normal SIGN (the inside-out guard)
//   - cap:false → 2*S faces, boundary edges present (NOT watertight)
//   - axis 0/1/2 invariance (counts + per-vert positions)
//   - Off-center centroid
//   - Degenerate-radii contract (inner=0 clamped, inner>outer clamped)
//   - Undo restores empty scene
//   - JSON path parity with argstring path

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;
import std.format : format;

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

JSONValue primTubeArg(string params_)
{
    return postJson("/api/command", "prim.tube " ~ params_);
}

JSONValue primTubeJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.tube","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default axis=Y segments=24 → 96 verts / 96 faces (4*S each, capped)
// -------------------------------------------------------------------------

unittest { // default tube counts
    resetEmpty();
    auto resp = primTubeArg(
        "segments:24 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(resp["status"].str == "ok", "default tube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 96,
        "default tube: expected 96 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 96,
        "default tube: expected 96 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Small segments=6 → 24 verts / 24 faces
// -------------------------------------------------------------------------

unittest { // small segments=6
    resetEmpty();
    auto resp = primTubeArg(
        "segments:6 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 24,
        "S=6: expected 24 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24,
        "S=6: expected 24 faces, got " ~ m["faces"].array.length.to!string);
    // All faces must be quads.
    foreach (f; m["faces"].array)
        assert(f.array.length == 4,
            "S=6: all faces must be quads, got " ~ f.array.length.to!string ~ "-gon");
}

// -------------------------------------------------------------------------
// 3. Watertight + directed-half-edge consistency (capped, S=8)
// -------------------------------------------------------------------------

unittest { // watertight + directed half-edge consistency
    resetEmpty();
    auto resp = primTubeArg(
        "segments:8 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 32);
    assert(m["faces"].array.length == 32);

    // Build undirected edge → count and directed half-edge → count maps.
    int[ulong] undirected;
    int[ulong] directed;

    ulong encDir(uint a, uint b) { return (cast(ulong)a << 32) | b; }
    ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }

    foreach (f; m["faces"].array) {
        int n = cast(int)f.array.length;
        foreach (i; 0 .. n) {
            uint a = cast(uint)f.array[i].integer;
            uint b = cast(uint)f.array[(i + 1) % n].integer;
            directed[encDir(a, b)] += 1;
            undirected[encUnd(a, b)] += 1;
        }
    }

    // Every undirected edge must appear in exactly 2 faces (watertight).
    foreach (k, cnt; undirected)
        assert(cnt == 2, format("watertight: undirected edge count %d (expected 2)", cnt));

    // Every directed half-edge must appear exactly once (consistent orientation).
    foreach (k, cnt; directed)
        assert(cnt == 1, format("consistency: directed half-edge count %d (expected 1)", cnt));
}

// -------------------------------------------------------------------------
// 4. Per-family normal SIGN — the inside-out guard (S=8, axis=Y)
// -------------------------------------------------------------------------

unittest { // per-family normal sign
    resetEmpty();
    auto resp = primTubeArg(
        "segments:8 axis:1 cenX:0 cenY:0 cenZ:0 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();

    // Collect vertex positions.
    double[][] verts;
    foreach (v; m["vertices"].array)
        verts ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];

    // Face geometric normal via cross product of diagonals: n = (v2-v0) × (v3-v1).
    double[3] faceNormal(size_t fi) {
        auto f = m["faces"].array[fi].array;
        auto v0 = verts[cast(size_t)f[0].integer];
        auto v1 = verts[cast(size_t)f[1].integer];
        auto v2 = verts[cast(size_t)f[2].integer];
        auto v3 = verts[cast(size_t)f[3].integer];
        double[3] d0 = [v2[0]-v0[0], v2[1]-v0[1], v2[2]-v0[2]];
        double[3] d1 = [v3[0]-v1[0], v3[1]-v1[1], v3[2]-v1[2]];
        return [d0[1]*d1[2] - d0[2]*d1[1],
                d0[2]*d1[0] - d0[0]*d1[2],
                d0[0]*d1[1] - d0[1]*d1[0]];
    }

    // Face centroid.
    double[3] faceCentroid(size_t fi) {
        auto f = m["faces"].array[fi].array;
        double[3] c = [0.0, 0.0, 0.0];
        foreach (vi; f) {
            auto v = verts[cast(size_t)vi.integer];
            c[0] += v[0]; c[1] += v[1]; c[2] += v[2];
        }
        double n = cast(double)f.length;
        return [c[0]/n, c[1]/n, c[2]/n];
    }

    // Radial direction in XZ plane from axis (cenX=0, cenZ=0).
    double[3] radialDir(double[3] cen) {
        double rx = cen[0];   // cenX = 0
        double rz = cen[2];   // cenZ = 0
        double len = sqrt(rx*rx + rz*rz);
        if (len < 1e-9) return [1.0, 0.0, 0.0];
        return [rx/len, 0.0, rz/len];
    }

    int S = 8;

    // Outer wall [0..S): normal dot radialDir > 0 (outward).
    foreach (fi; 0 .. S) {
        auto n   = faceNormal(fi);
        auto cen = faceCentroid(fi);
        auto rd  = radialDir(cen);
        double d = n[0]*rd[0] + n[1]*rd[1] + n[2]*rd[2];
        assert(d > 0.0, format("outer wall face %d: normal not outward (dot=%f)", fi, d));
    }

    // Inner wall [S..2S): normal dot radialDir < 0 (inward).
    foreach (fi; S .. 2*S) {
        auto n   = faceNormal(fi);
        auto cen = faceCentroid(fi);
        auto rd  = radialDir(cen);
        double d = n[0]*rd[0] + n[1]*rd[1] + n[2]*rd[2];
        assert(d < 0.0, format("inner wall face %d: normal not inward (dot=%f)", fi, d));
    }

    // Top cap [2S..3S): normal Y > 0 (+axis).
    foreach (fi; 2*S .. 3*S) {
        auto n = faceNormal(fi);
        assert(n[1] > 0.0,
            format("top cap face %d: normal not +axis (ny=%f)", fi, n[1]));
    }

    // Bottom cap [3S..4S): normal Y < 0 (-axis).
    foreach (fi; 3*S .. 4*S) {
        auto n = faceNormal(fi);
        assert(n[1] < 0.0,
            format("bottom cap face %d: normal not -axis (ny=%f)", fi, n[1]));
    }
}

// -------------------------------------------------------------------------
// 5. cap:false → 2*S faces, at least one boundary edge (NOT watertight)
// -------------------------------------------------------------------------

unittest { // cap=false: open tube with boundary edges
    resetEmpty();
    auto resp = primTubeArg(
        "segments:8 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:false");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    int S = 8;
    assert(m["vertices"].array.length == cast(size_t)(4 * S),
        "cap=false: expected 32 verts");
    assert(m["faces"].array.length == cast(size_t)(2 * S),
        "cap=false: expected 16 faces");

    // Find boundary edges (undirected count == 1).
    int[ulong] undirected;
    ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }
    foreach (f; m["faces"].array) {
        int n = cast(int)f.array.length;
        foreach (i; 0 .. n) {
            uint a = cast(uint)f.array[i].integer;
            uint b = cast(uint)f.array[(i + 1) % n].integer;
            undirected[encUnd(a, b)] += 1;
        }
    }
    bool hasBoundary = false;
    foreach (k, cnt; undirected)
        if (cnt == 1) { hasBoundary = true; break; }
    assert(hasBoundary, "cap=false: expected boundary edges");

    // Also confirm the tube is NOT watertight (boundary exists).
    bool allTwo = true;
    foreach (k, cnt; undirected)
        if (cnt != 2) { allTwo = false; break; }
    assert(!allTwo, "cap=false: should NOT be watertight");
}

// -------------------------------------------------------------------------
// 6. axis 0/1/2 — counts identical, vertex positions rotate accordingly
// -------------------------------------------------------------------------

unittest { // axis variations: 4*S verts / 4*S faces for all axes
    int S = 6;
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primTubeArg(
            "segments:" ~ S.to!string ~ " axis:" ~ ax.to!string
            ~ " outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
        assert(resp["status"].str == "ok",
            "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == cast(size_t)(4 * S),
            "axis=" ~ ax.to!string ~ ": expected " ~ (4*S).to!string ~ " verts");
        assert(m["faces"].array.length == cast(size_t)(4 * S),
            "axis=" ~ ax.to!string ~ ": expected " ~ (4*S).to!string ~ " faces");

        // All vertices must have axis-coord in {-1, +1} (outer/inner rings at
        // ±height/2 = ±1) and perp radius either ~1 (outer) or ~0.5 (inner).
        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating, v.array[1].floating, v.array[2].floating];
            double ac = p[ax];
            assert(fabs(fabs(ac) - 1.0) < 1e-4,
                format("axis=%d: vert axis coord not ±1, got %f", ax, ac));
            double bp = p[(ax + 1) % 3];
            double cp = p[(ax + 2) % 3];
            double r  = sqrt(bp*bp + cp*cp);
            // radius must be either outerRadius (~1) or innerRadius (~0.5).
            bool isOuter = fabs(r - 1.0) < 1e-3;
            bool isInner = fabs(r - 0.5) < 1e-3;
            assert(isOuter || isInner,
                format("axis=%d: vert perp radius %f not 1.0 or 0.5", ax, r));
        }
    }
}

// -------------------------------------------------------------------------
// 7. Off-center: centroid of all verts equals (cenX, cenY, cenZ)
// -------------------------------------------------------------------------

unittest { // off-center centroid
    resetEmpty();
    auto resp = primTubeArg(
        "segments:8 axis:1 cenX:2.0 cenY:3.0 cenZ:-1.0 "
        ~ "outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 32);

    double cx = 0, cy = 0, cz = 0;
    foreach (v; m["vertices"].array) {
        cx += v.array[0].floating;
        cy += v.array[1].floating;
        cz += v.array[2].floating;
    }
    auto n = cast(double)m["vertices"].array.length;
    cx /= n; cy /= n; cz /= n;
    assert(fabs(cx -  2.0) < 1e-4 &&
           fabs(cy -  3.0) < 1e-4 &&
           fabs(cz - (-1.0)) < 1e-4,
        format("off-center: centroid expected (2,3,-1), got (%f,%f,%f)", cx, cy, cz));
}

// -------------------------------------------------------------------------
// 8. Degenerate-radii contract: innerRadius=0 → clamped to outerRadius*1e-4
// -------------------------------------------------------------------------

unittest { // degenerate inner=0 → clamped
    resetEmpty();
    // innerRadius:0 should be clamped to outerRadius*1e-4 = 1e-4.
    auto resp = primTubeArg(
        "segments:6 axis:1 outerRadius:1.0 innerRadius:0.0 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 24, "degenerate inner=0: 24 verts");
    assert(m["faces"].array.length == 24,    "degenerate inner=0: 24 faces");
    // Inner ring verts (indices 12..23): perp radius should be ~1e-4.
    foreach (vi; 12 .. 24) {
        auto v = m["vertices"].array[vi];
        double x = v.array[0].floating;
        double z = v.array[2].floating;
        double r = sqrt(x*x + z*z);
        assert(r > 0.0,        "clamped inner must be non-zero");
        assert(fabs(r - 1e-4) < 1e-5,
            format("inner=0 clamped: r=%f expected ~1e-4", r));
    }
}

// -------------------------------------------------------------------------
// 9. Degenerate-radii contract: innerRadius > outerRadius → clamped
// -------------------------------------------------------------------------

unittest { // degenerate inner>outer → clamped to outerRadius*(1-1e-4)
    resetEmpty();
    auto resp = primTubeArg(
        "segments:6 axis:1 outerRadius:1.0 innerRadius:5.0 height:2.0 cap:true");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    double expectedInner = 1.0 * (1.0 - 1e-4);
    foreach (vi; 12 .. 24) {
        auto v = m["vertices"].array[vi];
        double x = v.array[0].floating;
        double z = v.array[2].floating;
        double r = sqrt(x*x + z*z);
        assert(fabs(r - expectedInner) < 1e-4,
            format("inner>outer clamped: r=%f expected ~%f", r, expectedInner));
    }
}

// -------------------------------------------------------------------------
// 10. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo restores empty
    resetEmpty();
    auto r1 = primTubeArg(
        "segments:6 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 24, "before undo: expected 24 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 11. JSON path parity with argstring path
// -------------------------------------------------------------------------

unittest { // JSON vs argstring give identical geometry
    resetEmpty();
    primTubeArg(
        "segments:12 axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primTubeJson(
        `"segments":12,"axis":1,"outerRadius":1.0,"innerRadius":0.5,"height":2.0,"cap":true`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ,
        "JSON vs argstring vert count: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ,
        "JSON vs argstring face count: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // segments=12 → 4*12 = 48 verts, 4*12 = 48 faces.
    assert(vA == 48, "expected 48 verts, got " ~ vA.to!string);
    assert(fA == 48, "expected 48 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 12. Topology formula across (segments) values
// -------------------------------------------------------------------------

unittest { // topology formula 4*S verts / 4*S faces for range of S
    foreach (S; [3, 4, 5, 8, 12, 16, 24]) {
        resetEmpty();
        auto resp = primTubeArg(
            "segments:" ~ S.to!string
            ~ " axis:1 outerRadius:1.0 innerRadius:0.5 height:2.0 cap:true");
        assert(resp["status"].str == "ok",
            "S=" ~ S.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == cast(size_t)(4 * S),
            "S=" ~ S.to!string ~ ": expected " ~ (4*S).to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["faces"].array.length == cast(size_t)(4 * S),
            "S=" ~ S.to!string ~ ": expected " ~ (4*S).to!string ~ " faces, got "
            ~ m["faces"].array.length.to!string);
    }
}
