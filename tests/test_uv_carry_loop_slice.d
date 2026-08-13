// test_uv_carry_loop_slice.d — Loop Slice carries the per-corner UV map
// (task 0682), asserted against the frozen reference capture in
// tests/fixtures/uv_corner_transfer.json.
//
// Pure-D unit test (no HTTP, no running vibe3d): the fixture's `before` mesh is
// rebuilt in process — geometry AND per-corner UV authored corner by corner —
// `insertEdgeLoopsMulti` is run on it, and every corner of the result is
// compared with the fixture's `after`.
//
// The measured law: an inserted vertex takes `lerp(uv(A), uv(B), s)` of the
// endpoints of the edge it split, at its own GEOMETRIC fraction s on that edge.
// The fixture's UV is deliberately QUADRATIC in position, so a kernel that
// re-projected position→UV instead of interpolating along the edge would read
// 0.48125 where the frozen value is 0.575 — the two candidates are 0.09 apart,
// far outside the 1e-6 tolerance. On a UV seam the law is PER CORNER: each side
// of the split edge interpolates inside its own island, and the seam survives.
//
// Matching is by vertex POSITION, never by index: the operation renumbers both
// faces and corners, and our face ORDER legitimately differs from the
// reference's (we emit split faces before untouched ones). Faces are paired by
// their set of corner positions, corners inside a paired face by position.
//
// Before this task Loop Slice sat in mesh.d's documented "v1 DROP set": the
// tail `buildLoops` → `resizePolyVertexMaps` made the map length-correct and
// ZERO. Every expectation here therefore reads 0 on the pre-fix kernel.

import std.json;
import std.math : fabs;
import std.conv : to;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import math : Vec3;

void main() {}

private string posKey(Vec3 p) {
    return p.x.to!string ~ "/" ~ p.y.to!string ~ "/" ~ p.z.to!string;
}

private enum float kPosEps = 1e-5f;   // position identity between the two meshes

// Fixture tolerance (its own "tolerance" field) — 1e-6.
private float g_tol = 1e-6f;

private bool samePos(Vec3 a, const JSONValue p) {
    return fabs(a.x - jnum(p[0])) < kPosEps
        && fabs(a.y - jnum(p[1])) < kPosEps
        && fabs(a.z - jnum(p[2])) < kPosEps;
}

private float jnum(const JSONValue v) {
    if (v.type == JSONType.integer)  return cast(float)v.integer;
    if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
    return cast(float)v.floating;
}

// Build the fixture's `before` state: geometry + a per-corner UV map authored
// straight from `corner_uv` (so a seam — two faces disagreeing at a shared
// vertex — is authored as such, not derived).
private Mesh buildBefore(const JSONValue before) {
    Mesh m;
    foreach (v; before["vertices"].array)
        m.addVertex(Vec3(jnum(v[0]), jnum(v[1]), jnum(v[2])));
    foreach (f; before["faces"].array) {
        uint[] face;
        foreach (c; f.array) face ~= cast(uint)c.integer;
        m.addFace(face);
    }
    m.rebuildEdges();
    m.buildLoops();
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null, "UV map registration failed");
    const auto cuv = before["corner_uv"].array;
    assert(cuv.length == m.faces.length, "fixture corner_uv/faces length mismatch");
    foreach (fi; 0 .. m.faces.length) {
        const auto fc = cuv[fi].array;
        assert(fc.length == m.faces[fi].length, "fixture corner_uv arity mismatch");
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            map.data[slot]     = jnum(fc[c][0]);
            map.data[slot + 1] = jnum(fc[c][1]);
        }
    }
    return m;
}

// The seed edges named by position in the fixture's op, resolved against `m`.
private uint[] seedEdges(ref Mesh m, const JSONValue op) {
    uint[] seeds;
    foreach (pair; op["seed_edges"].array) {
        uint a = ~0u, b = ~0u;
        foreach (vi, v; m.vertices) {
            if (samePos(v, pair[0])) a = cast(uint)vi;
            if (samePos(v, pair[1])) b = cast(uint)vi;
        }
        assert(a != ~0u && b != ~0u, "seed edge endpoint not found by position");
        const uint ei = m.edgeIndex(a, b);
        assert(ei != ~0u, "seed edge not present in the mesh");
        seeds ~= ei;
    }
    return seeds;
}

// Index of the fixture `after` face whose corner POSITIONS are the same set as
// our face `fi`'s. `~0u` when there is no such face.
private uint matchFace(ref Mesh m, uint fi, const JSONValue afterVerts,
                       const JSONValue afterFaces) {
    foreach (afi, af; afterFaces.array) {
        const auto ac = af.array;
        if (ac.length != m.faces[fi].length) continue;
        bool[size_t] used;
        bool all = true;
        foreach (c; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][c]];
            bool hit = false;
            foreach (k, av; ac) {
                if (k in used) continue;
                if (samePos(p, afterVerts[cast(size_t)av.integer])) {
                    used[k] = true; hit = true; break;
                }
            }
            if (!hit) { all = false; break; }
        }
        if (all) return cast(uint)afi;
    }
    return ~0u;
}

// Corner index inside fixture face `afi` sitting at position `p`.
private uint matchCorner(const JSONValue afterVerts, const JSONValue afterFace,
                         Vec3 p) {
    foreach (k, av; afterFace.array)
        if (samePos(p, afterVerts[cast(size_t)av.integer])) return cast(uint)k;
    return ~0u;
}

// One fixture case, end to end.
private void runCase(const JSONValue c) {
    const string name = c["name"].str;
    const auto op = c["op"];
    Mesh m = buildBefore(c["before"]);

    // Cut fractions. `position` is a single explicit fraction; a bare `count`
    // means evenly spaced loops (count=3 ⇒ 1/4, 2/4, 3/4) — the same reading
    // the tool's own Count/Position attributes take.
    float[] positions;
    const size_t count = ("count" in op) ? cast(size_t)op["count"].integer : 1;
    if ("position" in op) {
        positions ~= jnum(op["position"]);
        assert(count == 1, name ~ ": explicit position with count > 1");
    } else {
        foreach (i; 1 .. count + 1) positions ~= cast(float)i / cast(float)(count + 1);
    }

    uint[] newFaceIndices;
    const bool ok = m.insertEdgeLoopsMulti(seedEdges(m, op), positions, newFaceIndices);
    assert(ok, name ~ ": insertEdgeLoopsMulti reported no-op");

    const auto after      = c["after"];
    const auto afterVerts = after["vertices"];
    const auto afterFaces = after["faces"];
    const auto afterUv    = after["corner_uv"];

    // Geometry first — if the cut landed somewhere else, a UV comparison would
    // be meaningless (and a green run would prove nothing).
    assert(m.vertices.length == afterVerts.array.length,
           name ~ ": vertex count " ~ m.vertices.length.to!string ~ " != frozen "
                ~ afterVerts.array.length.to!string);
    assert(m.faces.length == afterFaces.array.length,
           name ~ ": face count " ~ m.faces.length.to!string ~ " != frozen "
                ~ afterFaces.array.length.to!string);

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, name ~ ": UV map lost by the slice");
    assert(map.data.length == m.loops.length * 2,
           name ~ ": UV map length " ~ map.data.length.to!string
                ~ " != loops*2 " ~ (m.loops.length * 2).to!string);

    size_t comparedCorners = 0;
    size_t movedCorners    = 0;   // corners whose frozen value is NOT 0 — the
                                  // ones the pre-fix (drop) kernel got wrong
    foreach (fi; 0 .. cast(uint)m.faces.length) {
        const uint afi = matchFace(m, fi, afterVerts, afterFaces);
        assert(afi != ~0u,
               name ~ ": our face " ~ fi.to!string
                    ~ " has no frozen counterpart (geometry diverged)");
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            const uint ac = matchCorner(afterVerts, afterFaces[afi], p);
            assert(ac != ~0u, name ~ ": corner position not found in frozen face");
            const float wantU = jnum(afterUv[afi][ac][0]);
            const float wantV = jnum(afterUv[afi][ac][1]);
            const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
            const float gotU = map.data[slot];
            const float gotV = map.data[slot + 1];
            assert(fabs(gotU - wantU) < g_tol && fabs(gotV - wantV) < g_tol,
                   name ~ ": face " ~ fi.to!string ~ " corner " ~ cIdx.to!string
                        ~ " uv (" ~ gotU.to!string ~ ", " ~ gotV.to!string
                        ~ ") != frozen (" ~ wantU.to!string ~ ", "
                        ~ wantV.to!string ~ ")");
            ++comparedCorners;
            if (fabs(wantU) > g_tol || fabs(wantV) > g_tol) ++movedCorners;
        }
    }
    assert(comparedCorners == m.loops.length,
           name ~ ": compared " ~ comparedCorners.to!string
                ~ " corners of " ~ m.loops.length.to!string);
    // Guard against a vacuous pass: the frozen state must actually carry
    // non-zero UV, otherwise "we match the fixture" would also hold for the
    // drop behaviour this task exists to replace.
    assert(movedCorners == comparedCorners,
           name ~ ": frozen state has zero-valued corners — the comparison "
                ~ "cannot distinguish carry from drop");
}

unittest { // every loop_slice case in the frozen capture
    enum string json = import("fixtures/uv_corner_transfer.json");
    auto fx = parseJSON(json);
    if ("tolerance" in fx) g_tol = jnum(fx["tolerance"]);
    size_t ran = 0;
    foreach (c; fx["cases"].array) {
        if (c["op"]["kind"].str != "loop_slice") continue;
        runCase(c);
        ++ran;
    }
    assert(ran == 5, "expected 5 frozen loop_slice cases, ran " ~ ran.to!string);
}

unittest { // untouched faces keep their corner values BIT-identically
    // The frozen law says the corners of faces the cut never entered, and the
    // original corners of the faces it did, come back byte for byte. A
    // tolerance comparison against the fixture cannot see a 1-ulp drift, so
    // assert exact equality against what we ourselves authored.
    enum string json = import("fixtures/uv_corner_transfer.json");
    auto fx = parseJSON(json);
    foreach (c; fx["cases"].array) {
        if (c["op"]["kind"].str != "loop_slice") continue;
        if (c["name"].str != "loop_slice_pos025") continue;

        Mesh m = buildBefore(c["before"]);
        // Remember every ORIGINAL corner value, keyed by position, for the
        // faces the cut never enters (all corners at y >= 1 in this layout —
        // the cut lands at y = 0.75, so a split sub-face always has a corner
        // below that line and is excluded).
        float[2][string] want;
        auto pre = m.meshMap(kUvMapName);
        bool[uint] untouched;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            bool low = false;
            foreach (v; m.faces[fi]) if (m.vertices[v].y < 0.99f) low = true;
            if (!low) untouched[fi] = true;
        }
        assert(untouched.length == 2, "expected 2 untouched faces in this layout");
        foreach (fi, _; untouched)
            foreach (cIdx; 0 .. m.faces[fi].length) {
                const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
                want[posKey(m.vertices[m.faces[fi][cIdx]])] =
                    [pre.data[slot], pre.data[slot + 1]];
            }

        uint[] nfi;
        assert(m.insertEdgeLoopsMulti(seedEdges(m, c["op"]), [0.25f], nfi));
        auto post = m.meshMap(kUvMapName);
        size_t checked = 0;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            bool low = false;
            foreach (v; m.faces[fi]) if (m.vertices[v].y < 0.99f) low = true;
            if (low) continue;
            foreach (cIdx; 0 .. m.faces[fi].length) {
                const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
                const string k = posKey(m.vertices[m.faces[fi][cIdx]]);
                auto w = k in want;
                if (w is null) continue;   // a corner the cut introduced
                assert(post.data[slot]     == (*w)[0]
                    && post.data[slot + 1] == (*w)[1],
                       "untouched corner at " ~ k ~ " changed: ("
                     ~ post.data[slot].to!string ~ ", "
                     ~ post.data[slot + 1].to!string ~ ") != ("
                     ~ (*w)[0].to!string ~ ", " ~ (*w)[1].to!string ~ ")");
                ++checked;
            }
        }
        assert(checked >= 8, "expected at least 8 untouched corners, saw "
                           ~ checked.to!string);
    }
}

unittest { // TWO crossing rings — the grid-split path, which the frozen capture
           // does not reach (the reference cuts one ring per gesture).
    //
    // A face crossed by two distinct rings is split into a grid, and its
    // INTERIOR vertices are bilerps of the four original corners. Those corners
    // take the same four weights, which is the only reading consistent with the
    // measured edge law (it degenerates to that lerp on the grid's boundary
    // rails). NOTE what this can and cannot pin: the UV here is AFFINE in
    // position, so "bilerp of the corners" and "re-project the position" agree —
    // this test pins the WEIGHTS (a midpoint-instead-of-bilerp bug is caught),
    // not the choice between those two laws, which nobody has measured for a
    // two-ring crossing.
    enum string json = import("fixtures/uv_corner_transfer.json");
    auto fx = parseJSON(json);
    JSONValue before;
    foreach (c; fx["cases"].array)
        if (c["name"].str == "loop_slice_pos025") before = c["before"];

    Mesh m = buildBefore(before);
    // Author an AFFINE uv: u = x, v = y.
    auto map = m.meshMap(kUvMapName);
    foreach (fi; 0 .. m.faces.length)
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            map.data[slot]     = p.x;
            map.data[slot + 1] = p.y;
        }

    // One seed per direction, both incident to vertex (0,0,0): their rings
    // cross in the bottom-left face.
    uint vA = ~0u, vB = ~0u, vC = ~0u;
    foreach (vi, v; m.vertices) {
        if (v.x == 0 && v.y == 0) vA = cast(uint)vi;
        if (v.x == 0 && v.y == 1) vB = cast(uint)vi;
        if (v.x == 1 && v.y == 0) vC = cast(uint)vi;
    }
    const uint[] seeds = [m.edgeIndex(vA, vB), m.edgeIndex(vA, vC)];
    uint[] nfi;
    assert(m.insertEdgeLoopsMulti(seeds, [0.25f], nfi),
           "two-seed slice should apply");

    auto post = m.meshMap(kUvMapName);
    assert(post.data.length == m.loops.length * 2, "grid split: UV length wrong");
    size_t interiorCorners = 0;
    foreach (fi; 0 .. cast(uint)m.faces.length)
        foreach (cIdx; 0 .. m.faces[fi].length) {
            const Vec3 p = m.vertices[m.faces[fi][cIdx]];
            const size_t slot = (m.faceLoop[fi] + cIdx) * 2;
            assert(fabs(post.data[slot] - p.x) < 1e-5f
                && fabs(post.data[slot + 1] - p.y) < 1e-5f,
                   "grid split: corner at (" ~ p.x.to!string ~ ", " ~ p.y.to!string
                 ~ ") got uv (" ~ post.data[slot].to!string ~ ", "
                 ~ post.data[slot + 1].to!string ~ ")");
            // A vertex off both original grid lines can only be a bilerp'd
            // interior one.
            if (p.x != 0 && p.x != 1 && p.x != 2 && p.y != 0 && p.y != 1 && p.y != 2)
                ++interiorCorners;
        }
    assert(interiorCorners > 0,
           "grid split produced no interior vertex — the bilerp path never ran");
}

unittest { // a mesh with NO per-corner map must be unaffected (and not crash)
    import mesh : makeCube;
    Mesh m = makeCube();
    m.buildLoops();
    assert(m.meshMap(kUvMapName) is null, "makeCube should register no UV map");
    const uint seed = 0;
    uint[] nfi;
    const bool ok = m.insertEdgeLoops(seed, [0.5f], nfi);
    assert(ok, "cube loop slice should succeed");
    assert(m.meshMap(kUvMapName) is null, "no UV map should have appeared");
}
