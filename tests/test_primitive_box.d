// Tests for subphase 6.1a: prim.cube headless command.
//
// Exercises the HTTP API surface for BoxTool / buildCuboidParametric:
//   - Default 1x1x1 cube       → 8 verts / 6 faces
//   - Segmented 2/2/2 cube     → 26 verts / 24 faces
//   - sizeY=0 plane            → 4 verts / 1 face
//   - Undo after prim.cube     → restores empty scene
//   - JSON path parity         → same result as argstring path

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

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

// Post a prim.cube command via the argstring path and return the response.
JSONValue primCubeArgstring(string params)
{
    return postJson("/api/command", "prim.cube " ~ params);
}

// Post a prim.cube command via the JSON path and return the response.
JSONValue primCubeJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.cube","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default 1x1x1 cube → 8 verts / 6 faces
// -------------------------------------------------------------------------

unittest { // prim.cube argstring default → 8v/6f
    resetEmpty();
    auto resp = primCubeArgstring("sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "argstring prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 8,
        "default cube: expected 8 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 6,
        "default cube: expected 6 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Segmented 2/2/2 → 26 verts / 24 faces
// -------------------------------------------------------------------------

unittest { // prim.cube segments 2/2/2 → 26v/24f
    resetEmpty();
    auto resp = primCubeArgstring(
        "sizeX:1.0 sizeY:1.0 sizeZ:1.0 segmentsX:2 segmentsY:2 segmentsZ:2");
    assert(resp["status"].str == "ok", "segmented prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 26,
        "2/2/2 cube: expected 26 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24,
        "2/2/2 cube: expected 24 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 3. sizeY=0 → XZ plane: 4 verts / 1 face
// -------------------------------------------------------------------------

unittest { // prim.cube sizeY=0 → 4v/1f XZ plane
    resetEmpty();
    auto resp = primCubeArgstring("sizeX:1.0 sizeY:0.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "plane prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 4,
        "plane: expected 4 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "plane: expected 1 face, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 4. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo after prim.cube restores empty mesh
    resetEmpty();
    auto r1 = primCubeArgstring("sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 8, "before undo: expected 8 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 5. JSON path parity: same geometry as argstring path
// -------------------------------------------------------------------------

unittest { // JSON path produces same vertex/face count as argstring
    // Argstring path
    resetEmpty();
    primCubeArgstring("sizeX:2.0 sizeY:3.0 sizeZ:4.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    // JSON path
    resetEmpty();
    primCubeJson(`"sizeX":2.0,"sizeY":3.0,"sizeZ":4.0`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ,
        "JSON vs argstring vert count mismatch: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ,
        "JSON vs argstring face count mismatch: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    assert(vA == 8, "cuboid: expected 8 verts, got " ~ vA.to!string);
    assert(fA == 6, "cuboid: expected 6 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 6. Non-default position: cenY=1.5 shifts mesh up
// -------------------------------------------------------------------------

unittest { // cenY=1.5 centers cube at y=1.5
    resetEmpty();
    auto resp = primCubeArgstring("cenY:1.5 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // All verts should have y in [1.0, 2.0].
    foreach (v; m["vertices"].array) {
        double y = v.array[1].floating;
        assert(y >= 0.99 && y <= 2.01,
            "cenY=1.5: vert y out of [1,2]: " ~ y.to!string);
    }
}

// -------------------------------------------------------------------------
// 7. Task 0314 (CRITICAL DoS/OOM): segmentsR is declared .min(1).max(64) in
// BoxTool.params() but /api/command bypassed that bound entirely, and the
// rounded-box corner builder is O(segmentsR^2) (~8n^2 verts). segmentsR:1000
// used to allocate 8M+ verts and hang the main thread for 50+s. The generic
// fix (params.d injectParamsInto now clamps Int/Float writes to the
// declared min/max hints) must clamp this to 64 — fast, bounded output,
// identical to requesting segmentsR:64 directly.
// -------------------------------------------------------------------------

unittest { // prim.cube segmentsR:1000 clamps to 64 — fast + bounded
    import std.datetime.stopwatch : StopWatch, AutoStart;

    resetEmpty();
    auto sw = StopWatch(AutoStart.yes);
    auto resp = primCubeJson(
        `"sizeX":1,"sizeY":1,"sizeZ":1,"radius":0.2,"segmentsR":1000`);
    sw.stop();
    assert(resp["status"].str == "ok", "segmentsR:1000 command failed: " ~ resp.toString);

    // Regression guard: an unclamped segmentsR:1000 allocates ~8M verts and
    // was observed to hang 50+s. Clamped to 64, this completes in well under
    // a second; assert generously (5s) to absorb CI/build-machine variance
    // while still catching a reintroduced O(n^2) blowup.
    assert(sw.peek.total!"msecs" < 5000,
        "prim.cube segmentsR:1000 took " ~ sw.peek.total!"msecs".to!string
        ~ "ms — clamp to max(64) appears not to be enforced");

    auto m = getModel();
    // n=64 rounded-cube (segmentsX=Y=Z=1 default): verts = 8*(n^2+n+1),
    // faces = 8*n^2 + 12*n + 6 (formula verified in box.d's own unittest
    // for n=1..4; the DoS repro is exactly this formula evaluated at the
    // clamped bound instead of the requested 1000).
    enum size_t expectedVerts = 8 * (64 * 64 + 64 + 1);   // 33288
    enum size_t expectedFaces = 8 * 64 * 64 + 12 * 64 + 6; // 33542
    assert(m["vertices"].array.length == expectedVerts,
        "segmentsR:1000 (clamped to 64): expected " ~ expectedVerts.to!string
        ~ " verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == expectedFaces,
        "segmentsR:1000 (clamped to 64): expected " ~ expectedFaces.to!string
        ~ " faces, got " ~ m["faces"].array.length.to!string);
}

unittest { // prim.cube segmentsR:1000 == segmentsR:64 (proves the clamp value)
    resetEmpty();
    auto r1000 = primCubeJson(`"sizeX":1,"sizeY":1,"sizeZ":1,"radius":0.2,"segmentsR":1000`);
    assert(r1000["status"].str == "ok", r1000.toString);
    auto m1000 = getModel();

    resetEmpty();
    auto r64 = primCubeJson(`"sizeX":1,"sizeY":1,"sizeZ":1,"radius":0.2,"segmentsR":64`);
    assert(r64["status"].str == "ok", r64.toString);
    auto m64 = getModel();

    assert(m1000["vertices"].array.length == m64["vertices"].array.length,
        "segmentsR:1000 should clamp to the same result as segmentsR:64");
    assert(m1000["faces"].array.length == m64["faces"].array.length,
        "segmentsR:1000 should clamp to the same result as segmentsR:64");
}

// -------------------------------------------------------------------------
// 8. Task 0315: box radius has no clamp vs size. radius >= min(size)/2
// corrupts the rounded-cube topology (unit cube: 0.4999 → clean 24v/26f,
// 0.5 → non-manifold/degenerate/duplicate-edge 6v/26f, since the inner
// face-panel extents collapse to exactly zero at the boundary). Fixed by
// insetting the existing maxR clamp by a small epsilon (buildCuboidParametric
// in box.d), mirroring buildTube's strict-interval contract.
// -------------------------------------------------------------------------

unittest { // prim.cube radius:0.5 on a unit cube clamps below the boundary → clean 24v/26f
    resetEmpty();
    auto resp = primCubeJson(`"sizeX":1,"sizeY":1,"sizeZ":1,"radius":0.5,"segmentsR":1`);
    assert(resp["status"].str == "ok", "radius:0.5 command failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 24,
        "radius:0.5 (clamped below size/2): expected clean 24 verts, got "
        ~ m["vertices"].array.length.to!string ~ " (non-manifold/degenerate if != 24)");
    assert(m["faces"].array.length == 26,
        "radius:0.5 (clamped below size/2): expected clean 26 faces, got "
        ~ m["faces"].array.length.to!string);
}
