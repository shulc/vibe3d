// Tests for subphase 6.7: prim.capsule headless command.
//
// Exercises the HTTP API surface for CapsuleTool / buildCapsule:
//   - Default (cylA=0, sphere-equivalent)   → 110 verts / 120 faces (sides=24, ends=6)
//   - endsize=0.5 (cylinder visible)        → 18 verts / 20 faces (sides=4, seg=1, ends=2)
//   - segments>1 + endsize<1                → cylinder intermediate rings present
//   - segments>1 + endsize=1                → cylinder rings collapse, output equals seg=1
//   - axis variants                         → topology invariant
//   - Off-center                            → all verts shift uniformly
//   - Undo / JSON parity / endsize clamp

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

JSONValue primCapsuleArg(string params)
{
    return postJson("/api/command", "prim.capsule " ~ params);
}

JSONValue primCapsuleJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.capsule","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default sides=24 ends=6 endsize=1 → 110 verts / 120 faces
//    cylA=0 collapses cylinder rings to one shared equator.
//    Verts: 2 + (2*ends - 1)·sides = 2 + 11·24 = 110.
//    Faces: (n_rings + 1)·sides = 12·24 = wait that's 288, but actual is 120…
//    Recount: south_pole_tris (S) + ring_strips (n_rings - 1)·S + north_pole_tris (S).
//    n_rings = 2*ends - 1 = 11. Strips = 10. Faces = 1·24 + 10·24 + 1·24 = 12·24 = 288.
//    Hmm — but capsule probe gave 120. Let me recompute: probe used ends=2, not 6.
//    Default is ends=6. With sides=24 ends=6, faces = (2·6 - 1 + 1)·24 = 11·24… wait my formula said
//    (n_rings + 1)·sides for total faces; n_rings = 2·ends - 1 = 11; faces = 12·24 = 288.
//    But the count below is wrong then. Let me skip this assertion and check it dynamically.
// -------------------------------------------------------------------------

unittest { // default capsule counts (cylA=0)
    resetEmpty();
    auto resp = primCapsuleArg("sides:24 segments:1 endsegments:6 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "default capsule failed: " ~ resp.toString);
    auto m = getModel();
    // n_rings = 2·ends - 1 = 11 (cylA=0 collapses).
    // verts = 2 + 11·24 = 266.
    // faces = (n_rings + 1) · sides = 12 · 24 = 288.
    assert(m["vertices"].array.length == 266,
        "default: expected 266 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 288,
        "default: expected 288 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Tiny endsize=1: 14 verts / 16 faces (sides=4, ends=2, cylA=0).
// -------------------------------------------------------------------------

unittest { // tiny capsule sphere-mode
    resetEmpty();
    auto resp = primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // n_rings = 3 (1 lower hemi inter + 1 shared equator + 1 upper hemi inter).
    // verts = 2 + 3·4 = 14. faces = 4·4 = 16.
    assert(m["vertices"].array.length == 14, "expected 14 verts");
    assert(m["faces"].array.length == 16, "expected 16 faces");

    // 8 triangles (pole fans) + 8 quads.
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        auto n = f.array.length;
        if      (n == 3) ++tris;
        else if (n == 4) ++quads;
    }
    assert(tris == 8, "expected 8 pole triangles, got " ~ tris.to!string);
    assert(quads == 8, "expected 8 ring-strip quads, got " ~ quads.to!string);
}

// -------------------------------------------------------------------------
// 3. endsize=0.5 cylinder visible: 18v / 20f (sides=4, seg=1, ends=2).
// -------------------------------------------------------------------------

unittest { // cylinder section appears
    resetEmpty();
    auto resp = primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:0.5 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // n_rings = 2*(ends-1) + 2 + (seg-1) = 2 + 2 + 0 = 4.
    // verts = 2 + 4·4 = 18. faces = 5·4 = 20.
    assert(m["vertices"].array.length == 18, "expected 18 verts");
    assert(m["faces"].array.length == 20, "expected 20 faces");

    // Verify lower equator at y=-0.5 and upper at y=+0.5 (cylA = 1 - 0.5 = 0.5).
    int loEqCount = 0, upEqCount = 0;
    foreach (v; m["vertices"].array) {
        double y = v.array[1].floating;
        double r = sqrt(v.array[0].floating * v.array[0].floating
                      + v.array[2].floating * v.array[2].floating);
        if (fabs(y - (-0.5)) < 1e-4 && fabs(r - 1.0) < 1e-4) ++loEqCount;
        if (fabs(y -   0.5)  < 1e-4 && fabs(r - 1.0) < 1e-4) ++upEqCount;
    }
    assert(loEqCount == 4, "expected 4 lower-equator verts at y=-0.5, got " ~ loEqCount.to!string);
    assert(upEqCount == 4, "expected 4 upper-equator verts at y=+0.5, got " ~ upEqCount.to!string);
}

// -------------------------------------------------------------------------
// 4. segments>1 with cylinder visible adds intermediate cylinder rings.
// -------------------------------------------------------------------------

unittest { // cylinder segments
    resetEmpty();
    auto resp = primCapsuleArg("sides:4 segments:3 endsegments:2 endsize:0.5 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // n_rings = 2*(ends-1) + 2 + (seg-1) = 2 + 2 + 2 = 6.
    // verts = 2 + 6·4 = 26. faces = 7·4 = 28.
    assert(m["vertices"].array.length == 26, "expected 26 verts");
    assert(m["faces"].array.length == 28, "expected 28 faces");
}

// -------------------------------------------------------------------------
// 5. segments doesn't matter when endsize≥1 (cylA=0 collapses).
// -------------------------------------------------------------------------

unittest { // segments collapse when cylA=0
    resetEmpty();
    primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto m1 = getModel();

    resetEmpty();
    primCapsuleArg("sides:4 segments:5 endsegments:2 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto m5 = getModel();

    assert(m1["vertices"].array.length == m5["vertices"].array.length,
        "segments should not affect vertex count when cylA=0");
    assert(m1["faces"].array.length == m5["faces"].array.length,
        "segments should not affect face count when cylA=0");
}

// -------------------------------------------------------------------------
// 6. axis variants preserve topology
// -------------------------------------------------------------------------

unittest { // axis = X / Y / Z
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primCapsuleArg(
            "sides:4 segments:1 endsegments:2 endsize:1.0 axis:" ~ ax.to!string
            ~ " sizeX:1.0 sizeY:1.0 sizeZ:1.0");
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == 14,
            "axis=" ~ ax.to!string ~ ": expected 14 verts");
        assert(m["faces"].array.length == 16,
            "axis=" ~ ax.to!string ~ ": expected 16 faces");

        // Pole on +axis side at +size, opposite pole at -size.
        int polePosCount = 0, poleNegCount = 0;
        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating, v.array[1].floating, v.array[2].floating];
            int b = (ax + 1) % 3;
            int c = (ax + 2) % 3;
            if (fabs(p[b]) < 1e-4 && fabs(p[c]) < 1e-4) {
                if (fabs(p[ax] - 1.0)  < 1e-4) ++polePosCount;
                if (fabs(p[ax] + 1.0)  < 1e-4) ++poleNegCount;
            }
        }
        assert(polePosCount == 1,
            "axis=" ~ ax.to!string ~ ": expected one pole at +size on axis");
        assert(poleNegCount == 1,
            "axis=" ~ ax.to!string ~ ": expected one pole at -size on axis");
    }
}

// -------------------------------------------------------------------------
// 7. Off-center: poles at (cen ± sizeY) for axis=Y.
// -------------------------------------------------------------------------

unittest { // off-center
    resetEmpty();
    auto resp = primCapsuleArg(
        "sides:4 segments:1 endsegments:2 endsize:1.0 axis:1 cenX:2.0 cenY:3.0 cenZ:-1.0 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    bool foundN = false, foundS = false;
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        if (fabs(x - 2.0) < 1e-4 && fabs(y - 4.0) < 1e-4 && fabs(z - (-1.0)) < 1e-4) foundN = true;
        if (fabs(x - 2.0) < 1e-4 && fabs(y - 2.0) < 1e-4 && fabs(z - (-1.0)) < 1e-4) foundS = true;
    }
    assert(foundN && foundS, "off-center poles expected at (2,4,-1) and (2,2,-1)");
}

// -------------------------------------------------------------------------
// 8. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo
    resetEmpty();
    auto r1 = primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 14);

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 9. JSON path parity with argstring
// -------------------------------------------------------------------------

unittest { // JSON ↔ argstring
    resetEmpty();
    primCapsuleArg("sides:8 segments:2 endsegments:3 endsize:0.5 axis:1 sizeX:1.0 sizeY:1.5 sizeZ:1.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primCapsuleJson(`"sides":8,"segments":2,"endsegments":3,"endsize":0.5,"axis":1,"sizeX":1.0,"sizeY":1.5,"sizeZ":1.0`);
    auto mj = getModel();
    assert(vA == mj["vertices"].array.length, "JSON ↔ arg vert mismatch");
    assert(fA == mj["faces"].array.length, "JSON ↔ arg face mismatch");
}

// -------------------------------------------------------------------------
// 10. endsize > sizeAxis/avgPerp clamps cylA at 0 (no negative cylinder).
// -------------------------------------------------------------------------

unittest { // endsize clamping
    resetEmpty();
    primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:1.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto m1 = getModel();

    resetEmpty();
    primCapsuleArg("sides:4 segments:1 endsegments:2 endsize:5.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    auto mClamp = getModel();

    assert(m1["vertices"].array.length == mClamp["vertices"].array.length,
        "endsize > 1 with sizeY = avgPerp should produce same vert count as endsize = 1");
    assert(m1["faces"].array.length == mClamp["faces"].array.length,
        "endsize > 1 with sizeY = avgPerp should produce same face count as endsize = 1");
}

// -------------------------------------------------------------------------
// Task 0315: degenerate perpendicular radius (sizeX=0 or sizeZ=0 — the two
// radii perpendicular to the default Y axis) used to zero one ring
// coordinate for every side vertex, so side j and (S-j) landed on
// identical positions (coincident verts / zero-area degenerate faces).
// buildCapsule now floors that radius to a small epsilon so every ring
// vertex stays distinct. Topology (vertex count) is pinned via `endsize:0`
// (hemH = |endsize|*avgPerp = 0 for any avgPerp), which decouples the
// hemisphere-height heuristic from radB/radC so the level count is
// identical regardless of which radius is degenerate — otherwise
// avgPerp = (radB+radC)/2 legitimately shrinks when one radius floors to
// ~0, which changes cylA and therefore the level count on its own (not a
// bug; a real shape difference this test must not confuse with one).
// -------------------------------------------------------------------------

bool hasCoincidentVerts(JSONValue verts, double eps = 1e-7)
{
    auto arr = verts.array;
    foreach (i; 0 .. arr.length)
        foreach (j; i + 1 .. arr.length) {
            double dx = arr[i].array[0].floating - arr[j].array[0].floating;
            double dy = arr[i].array[1].floating - arr[j].array[1].floating;
            double dz = arr[i].array[2].floating - arr[j].array[2].floating;
            if (dx * dx + dy * dy + dz * dz < eps * eps) return true;
        }
    return false;
}

unittest { // sizeX=0 (radC, axis=Y default) no longer collapses ring verts
    resetEmpty();
    auto resp = primCapsuleArg(
        "sides:8 segments:1 endsegments:2 endsize:0.0 axis:1 sizeX:0.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // levels = lowerHemi(1) + lowerEquator(1) + upperEquator(1) + upperHemi(1) = 4
    // (endsize=0 ⇒ cylA=halfA always, independent of radB/radC)
    // V = 1(south pole) + levels*S + 1(north pole) = 1 + 4*8 + 1 = 34
    assert(m["vertices"].array.length == 34,
        "V=1+4*S+1=34 expected, got " ~ m["vertices"].array.length.to!string);
    assert(!hasCoincidentVerts(m["vertices"]),
        "sizeX=0: expected no coincident vertices after degenerate-radius guard");
}

unittest { // sizeZ=0 (radB, axis=Y default) no longer collapses ring verts
    resetEmpty();
    auto resp = primCapsuleArg(
        "sides:8 segments:1 endsegments:2 endsize:0.0 axis:1 sizeX:1.0 sizeY:1.0 sizeZ:0.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 34,
        "V=1+4*S+1=34 expected, got " ~ m["vertices"].array.length.to!string);
    assert(!hasCoincidentVerts(m["vertices"]),
        "sizeZ=0: expected no coincident vertices after degenerate-radius guard");
}
