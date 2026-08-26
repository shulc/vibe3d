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

import mesh : Mesh, MeshMap, MapDomain, kUvMapName, MeshEditBatch;
// Named from `mesh_ops.loop_slice` DIRECTLY, and the reason is a choice, not a
// compiler constraint — the earlier note here ("a `public import` in mesh.d is
// INVISIBLE through a SELECTIVE `import mesh : …`") was measurably WRONG and
// was corrected at the F1 review. Probed with `dmd -o- -c`:
//
//   import mesh : Mesh, MeshEditBatch, insertEdgeLoops, insertEdgeLoopsMulti,
//                 kLoopSliceEditScope, collectEdgeRing, loopSliceRingEdges;
//                                                            // COMPILES
//   import mesh;                     // plain, unqualified   // COMPILES
//   import mesh : Mesh;              // then m.collectEdgeRing(…)  // REFUSED
//
// So the real rule is narrower: a selective import binds ONLY the names in its
// list, and a re-exported name has to be listed like any other — what it will
// not do is come along for free beside a sibling name. `topology_pen/tool.d`
// takes exactly that route in this same diff. This file names the ops module
// instead because the DECLARING module is the honest source for a free
// function, and it keeps the import from going stale if mesh.d ever stops
// being the door for the ops namespace (audit 0678 M9). (task 1903 Stage F1)
import mesh_ops.loop_slice : insertEdgeLoops, insertEdgeLoopsMulti,
                             kLoopSliceEditScope;
import math : Vec3;

// Task 1903 Stage F1: `insertEdgeLoops` / `insertEdgeLoopsMulti` are free
// functions over `ref MeshEditBatch` now, so a bare `Mesh` receiver is a
// COMPILE error. One UNRECORDED batch per call, which is what the production
// callers open too — nothing in this file reads an op-log. `auto ref` is
// load-bearing: both entries take `out uint[] newFaceIndices`, so the argument
// has to reach the kernel as an lvalue.
private bool sliceOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kLoopSliceEditScope);
    const ok = kernel(ed, args);
    ed.close();
    return ok;
}

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
    const bool ok = sliceOnce!insertEdgeLoopsMulti(m, seedEdges(m, op), positions, newFaceIndices);
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
        assert(sliceOnce!insertEdgeLoopsMulti(m, seedEdges(m, c["op"]), [0.25f], nfi));
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
    assert(sliceOnce!insertEdgeLoopsMulti(m, seeds, [0.25f], nfi),
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

unittest { // the per-CORNER entry (task 0697) IS the per-face one, generalised
    // `carryPolyVertexMaps` now expands its per-FACE source array and delegates
    // to `carryPolyVertexMapsByCorner`, which is what keeps Loop Slice's frozen
    // result safe from the extension the bevel family needed. The fixture cases
    // above already run the real kernel through that path; this pins the
    // equivalence directly, so a future re-implementation of the per-face entry
    // as its own copy of the walk cannot silently diverge.
    //
    // The rewrite below is a hand-built one-edge split of two quads sharing an
    // edge, with the two faces disagreeing at the shared vertices (a seam) — so
    // the comparison covers a copy, a blend, and a corner with no source at all.
    import mesh : PolyVertexBlend;

    Mesh build() {
        Mesh m;
        m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
        m.addVertex(Vec3(1, 1, 0)); m.addVertex(Vec3(0, 1, 0));
        m.addVertex(Vec3(2, 0, 0)); m.addVertex(Vec3(2, 1, 0));
        m.addFace([0u, 1u, 2u, 3u]);
        m.addFace([1u, 4u, 5u, 2u]);
        m.rebuildEdges();
        m.buildLoops();
        auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        foreach (i; 0 .. uv.data.length) uv.data[i] = 0.25f + 0.5f * i;  // all distinct
        return m;
    }

    // A new vertex at the middle of edge 1→2, spliced into both faces.
    Mesh a = build(), b = build();
    const uint mid = a.addVertex(Vec3(1, 0.5f, 0));
    assert(b.addVertex(Vec3(1, 0.5f, 0)) == mid);
    const uint[] oldFaceLoop = a.captureFaceLoop();
    uint[][] oldFaces = [[0u, 1u, 2u, 3u], [1u, 4u, 5u, 2u]];
    uint[][] newFaces = [[0u, 1u, mid, 2u, 3u], [1u, 4u, 5u, 2u, mid]];
    uint[]   srcFace  = [0u, 1u];
    PolyVertexBlend[uint] blend;
    PolyVertexBlend pb;
    pb.add(1u, 0.5f); pb.add(2u, 0.5f);
    blend[mid] = pb;

    a.carryPolyVertexMaps(newFaces, srcFace, oldFaces, oldFaceLoop, blend);

    uint[] perCorner;
    foreach (nfi, nf; newFaces) foreach (_; nf) perCorner ~= srcFace[nfi];
    b.carryPolyVertexMapsByCorner(newFaces, perCorner, oldFaces, oldFaceLoop, blend);

    auto ua = a.meshMap(kUvMapName), ub = b.meshMap(kUvMapName);
    assert(ua.data.length == ub.data.length && ua.data.length == 10 * 2,
           "the two entries produced different lengths");
    size_t nonZero = 0;
    foreach (i; 0 .. ua.data.length) {
        assert(ua.data[i] == ub.data[i],
               "per-face and per-corner entries disagree at float " ~ i.to!string
             ~ ": " ~ ua.data[i].to!string ~ " != " ~ ub.data[i].to!string);
        if (ua.data[i] != 0.0f) ++nonZero;
    }
    assert(nonZero >= 16, "the comparison is vacuous — the relocation produced "
                        ~ "almost nothing but zeros");
}

unittest { // a mesh with NO per-corner map must be unaffected (and not crash)
    import mesh : makeCube;
    Mesh m = makeCube();
    m.buildLoops();
    assert(m.meshMap(kUvMapName) is null, "makeCube should register no UV map");
    const uint seed = 0;
    uint[] nfi;
    const bool ok = sliceOnce!insertEdgeLoops(m, seed, [0.5f], nfi);
    assert(ok, "cube loop slice should succeed");
    assert(m.meshMap(kUvMapName) is null, "no UV map should have appeared");
}
