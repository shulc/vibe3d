// test_mesh_map.d — round-trip + lifecycle test for the generic mesh-map
// registry (named, typed per-element float attribute channels on Mesh).
//
// Pure-D unit test (no HTTP, no running vibe3d): builds in-process meshes and
// exercises the MeshMap registry API + lifecycle directly. There is no HTTP
// surface for mesh maps, so the source-backed unittest path (run_test.d's
// `dmd -unittest -i`) is the right home — the same pattern as
// tests/test_xform_matrix_kernel.d. Unittests run before the empty main().
//
// Coverage:
//   - add a Point map (dim 1, "weight") + an Edge map (dim 2, "edgeval")
//   - set + read back values (element-major layout round-trip)
//   - a topology edit that changes element count → map data.length stays
//     consistent (no crash, correct length, no out-of-bounds reads)
//   - snapshot capture → mutate → restore → values come back
//   - missing-map lookup returns null / empty safely
//   - removeMeshMap works
//   - PolyVertex (per-corner) domain: accept + size to loops.length*dim;
//     faceCornerLoop addressing; the two-mechanism remap lifecycle matrix
//     (delete/compact (a); dissolve/dissolve-edge/weld (b)); GAP-3 atomic
//     append; snapshot round-trip; the drop class (subdivide/primitive/extrude)

import std.math : fabs;

import mesh : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import snapshot : MeshSnapshot;

void main() {}

private bool feq(float a, float b, float eps = 1e-6f) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// add + element-major round-trip (Point dim-1 + Edge dim-2)
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    const nv = m.vertices.length; // 8
    const ne = m.edges.length;    // 12 (deduplicated cube edges)

    // Point map, dim 1 (vertex weight).
    auto wm = m.addMeshMap("weight", 1, MapDomain.Point);
    assert(wm !is null, "addMeshMap(Point) should succeed");
    assert(wm.dim == 1);
    assert(wm.domain == MapDomain.Point);
    assert(wm.data.length == nv * 1, "Point map data sized to vertices*dim");
    // zero-initialised
    foreach (f; wm.data) assert(feq(f, 0.0f));

    // Edge map, dim 2 (generic 2-D channel; name is incidental — kept distinct
    // from the reserved PolyVertex "uv" convention).
    auto uv = m.addMeshMap("edgeval", 2, MapDomain.Edge);
    assert(uv !is null, "addMeshMap(Edge) should succeed");
    assert(uv.dim == 2);
    assert(uv.data.length == ne * 2, "Edge map data sized to edges*dim");

    // Set + read back — element-major layout: element i at data[i*dim .. +dim].
    assert(m.setMeshMapValue("weight", 3, [0.75f]));
    auto w3 = m.meshMapValue("weight", 3);
    assert(w3.length == 1 && feq(w3[0], 0.75f), "Point round-trip");
    // underlying storage check: element 3 dim 1 → data[3]
    assert(feq(m.meshMap("weight").data[3], 0.75f), "element-major Point layout");

    assert(m.setMeshMapValue("edgeval", 5, [0.1f, 0.9f]));
    auto uv5 = m.meshMapValue("edgeval", 5);
    assert(uv5.length == 2 && feq(uv5[0], 0.1f) && feq(uv5[1], 0.9f), "Edge dim-2 round-trip");
    // element 5 dim 2 → data[10], data[11]
    assert(feq(m.meshMap("edgeval").data[10], 0.1f) && feq(m.meshMap("edgeval").data[11], 0.9f),
        "element-major Edge layout");
}

// ---------------------------------------------------------------------------
// lifecycle: a topology edit that changes element count keeps map data.length
// consistent (no crash, no out-of-bounds). Drives the resize through the same
// funnel the selection/marks arrays use.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap("weight", 1, MapDomain.Point);
    m.addMeshMap("edgeval", 2, MapDomain.Edge);

    // Grow vertices, then drive the documented resize funnel. The map must
    // follow vertex count in lock-step.
    import math : Vec3;
    m.vertices ~= Vec3(2, 2, 2);
    m.resizeVertexSelection(); // funnel that resizeMeshMaps(Point) hooks into
    assert(m.meshMap("weight").data.length == m.vertices.length * 1,
        "Point map follows vertex count after growth via resize funnel");

    // A genuine destructive topology op: collapse two cube verts onto one
    // point and weld. This shrinks vertices + edges; maps must stay
    // length-consistent (resized, not value-preserved) with no crash.
    auto m2 = makeCube();
    m2.addMeshMap("weight", 1, MapDomain.Point);
    m2.addMeshMap("edgeval", 2, MapDomain.Edge);
    // mark every vert so weldCoincidentVertices has nothing yet; instead move
    // vert 1 onto vert 0 then weld coincident.
    m2.vertices[1] = m2.vertices[0];
    m2.weldCoincidentVertices();
    // After weld + compact, lengths must agree with current geometry.
    assert(m2.meshMap("weight").data.length == m2.vertices.length * 1,
        "Point map length consistent after destructive weld");
    assert(m2.meshMap("edgeval").data.length == m2.edges.length * 2,
        "Edge map length consistent after destructive weld");
    // Reading any in-range element must not crash / must return dim-sized.
    if (m2.vertices.length > 0) {
        auto v0 = m2.meshMapValue("weight", m2.vertices.length - 1);
        assert(v0.length == 1);
    }
}

// ---------------------------------------------------------------------------
// snapshot capture → mutate → restore → values come back
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap("weight", 1, MapDomain.Point);
    m.addMeshMap("edgeval", 2, MapDomain.Edge);
    m.setMeshMapValue("weight", 2, [0.5f]);
    m.setMeshMapValue("edgeval", 0, [0.25f, 0.75f]);

    auto snap = MeshSnapshot.capture(m);
    assert(snap.filled);

    // Mutate the live maps after capture — snapshot must NOT alias.
    m.setMeshMapValue("weight", 2, [9.0f]);
    m.setMeshMapValue("edgeval", 0, [0.0f, 0.0f]);
    m.removeMeshMap("weight"); // also drop a whole map to prove restore re-adds
    assert(m.meshMap("weight") is null);

    snap.restore(m);

    // Values + registry come back.
    auto w2 = m.meshMapValue("weight", 2);
    assert(w2.length == 1 && feq(w2[0], 0.5f), "snapshot restored Point value");
    auto uv0 = m.meshMapValue("edgeval", 0);
    assert(uv0.length == 2 && feq(uv0[0], 0.25f) && feq(uv0[1], 0.75f),
        "snapshot restored Edge value");
    // lengths still consistent with restored geometry
    assert(m.meshMap("weight").data.length == m.vertices.length * 1);
    assert(m.meshMap("edgeval").data.length == m.edges.length * 2);
}

// ---------------------------------------------------------------------------
// missing-map lookup is safe; removeMeshMap works; defensive bounds checks
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();

    // Missing map: lookup → null, value-read → empty, value-write → false.
    assert(m.meshMap("nope") is null);
    assert(m.meshMapValue("nope", 0).length == 0);
    assert(!m.setMeshMapValue("nope", 0, [1.0f]));

    auto wm = m.addMeshMap("weight", 1, MapDomain.Point);
    assert(wm !is null);

    // Duplicate name rejected.
    assert(m.addMeshMap("weight", 1, MapDomain.Point) is null,
        "duplicate map name must be rejected");

    // dim mismatch on write rejected.
    assert(!m.setMeshMapValue("weight", 0, [1.0f, 2.0f]),
        "dim mismatch write must be rejected");

    // out-of-range element index → empty read / false write, no crash.
    assert(m.meshMapValue("weight", 9999).length == 0);
    assert(!m.setMeshMapValue("weight", 9999, [1.0f]));

    // zero-dim and empty-name rejected.
    assert(m.addMeshMap("zerodim", 0, MapDomain.Point) is null);
    assert(m.addMeshMap("", 1, MapDomain.Point) is null);

    // removeMeshMap works + is idempotent on the second call.
    assert(m.removeMeshMap("weight"));
    assert(m.meshMap("weight") is null);
    assert(!m.removeMeshMap("weight"), "removing an absent map returns false");
}

// ===========================================================================
// PolyVertex (per-corner) domain — Stage 1 matrix.
//
// Each test plants a DISTINCT uv per corner of the cube (uniquely identifiable
// as a function of (face, corner)), runs an op, and asserts the surviving
// corners carry their planted value and new/dropped corners behave per the D5
// classification.
// ===========================================================================

// Distinct, invertible per-corner uv: (face, corner) → (u, v). The encoding is
// unique across the whole cube so a surviving corner's value identifies exactly
// which (face, corner) it came from.
private float[2] plantedUv(uint fi, uint corner) {
    const float code = fi * 10.0f + corner;
    return [code, 100.0f + code];
}

// Plant the distinct uv on every corner of `m` via faceCornerLoop addressing.
private void plantAllCorners(ref Mesh m) {
    foreach (fi; 0 .. m.faces.length) {
        const uint arity = cast(uint)m.faces[fi].length;
        foreach (c; 0 .. arity) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            assert(li != size_t.max, "faceCornerLoop in range for planted corner");
            const float[2] uv = plantedUv(cast(uint)fi, cast(uint)c);
            assert(m.setMeshMapValue(kUvMapName, li, uv[]));
        }
    }
}

// ---------------------------------------------------------------------------
// addMeshMap(PolyVertex) is ACCEPTED, sized loops.length*dim, zero-init.
// (GAP-5: the reserved-rejection assert is FLIPPED to expect success.)
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "PolyVertex domain is accepted in v1");
    assert(uv.dim == 2);
    assert(uv.domain == MapDomain.PolyVertex);
    // cube: 6 quads → 24 loops (corners); dim 2 → 48 floats.
    assert(m.loops.length == 24, "cube has 24 corners");
    assert(uv.data.length == m.loops.length * 2, "PolyVertex map sized loops*dim");
    foreach (f; uv.data) assert(feq(f, 0.0f), "zero-init");
    assert(m.meshMap(kUvMapName) !is null);
}

// ---------------------------------------------------------------------------
// Addressing: faceCornerLoop ↔ meshMapValue agree for every (face,corner) of a
// cube; element-major dim-2 layout.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    // Round-trip every corner via faceCornerLoop addressing.
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = plantedUv(cast(uint)fi, cast(uint)c);
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "faceCornerLoop ↔ meshMapValue agree per corner");
            // element-major: element li dim 2 → data[li*2], data[li*2+1].
            assert(feq(m.meshMap(kUvMapName).data[li * 2], want[0]) &&
                   feq(m.meshMap(kUvMapName).data[li * 2 + 1], want[1]),
                "element-major dim-2 layout");
        }
    }

    // faceCornerLoop is bounds-guarded.
    assert(m.faceCornerLoop(9999, 0) == size_t.max, "out-of-range face → sentinel");
    assert(m.faceCornerLoop(0, 99) == size_t.max, "out-of-range corner → sentinel");
}

// ---------------------------------------------------------------------------
// (a) delete a face → remaining corners keep their planted uv; count shrinks.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    // Delete face 0. Remaining faces shift down by one index, but their corner
    // VALUES (planted against the OLD face index) must travel with the corners.
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    const auto removed = m.deleteFacesByMask(mask);
    assert(removed == 1);
    assert(m.faces.length == 5, "one face removed");
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2,
        "PolyVertex length correct after delete");

    // New face j was old face j+1. Its corners must carry plantedUv(j+1, c).
    foreach (newFi; 0 .. m.faces.length) {
        const uint oldFi = cast(uint)newFi + 1;
        foreach (c; 0 .. m.faces[newFi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)newFi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = plantedUv(oldFi, cast(uint)c);
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "(a) deleted-face: surviving corners keep planted uv");
        }
    }
}

// ---------------------------------------------------------------------------
// (a) compactUnreferenced → uv follows faces (order + arity preserved, so
// corner identity is unchanged; values must be untouched).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    // Add an unreferenced vertex so compactUnreferenced has work to do.
    import math : Vec3;
    m.vertices ~= Vec3(5, 5, 5);
    m.resizeVertexSelection();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    const auto compacted = m.compactUnreferenced();
    assert(compacted == 1, "the lone orphan vertex was removed");
    // compactUnreferenced does not rebuild loops; faces order/arity unchanged,
    // so faceLoop + per-corner values are still valid. Rebuild loops anyway to
    // mirror real callers, then assert nothing moved.
    m.buildLoops();
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2);
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = plantedUv(cast(uint)fi, cast(uint)c);
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "(a) compactUnreferenced: face order preserved, uv unchanged");
        }
    }
}

// ---------------------------------------------------------------------------
// (b) dissolve verts → surviving (re-arity'd) corners keep their planted uv.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    // Record, BEFORE the dissolve, for every face the planted uv of each corner
    // whose vertex is NOT vertex 0 (vertex 0 is the one we dissolve). After the
    // dissolve those corners survive (in the same relative order) on re-arity'd
    // faces, and must still carry their original planted value.
    float[2][][] expected; // expected[newFaceOrder][survivingCorner]
    foreach (fi; 0 .. m.faces.length) {
        float[2][] perFace;
        bool faceSurvives = false;
        size_t kept = 0;
        foreach (c; 0 .. m.faces[fi].length) {
            if (m.faces[fi][c] == 0) continue; // corner on the dissolved vertex
            perFace ~= plantedUv(cast(uint)fi, cast(uint)c);
            ++kept;
        }
        faceSurvives = kept >= 3;
        if (faceSurvives) expected ~= perFace;
    }

    auto vmask = new bool[](m.vertices.length);
    vmask[0] = true; // dissolve vertex 0 (shared by 3 faces)
    const auto dissolved = m.dissolveVerticesByMask(vmask);
    assert(dissolved == 1);
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2,
        "PolyVertex length correct after dissolve");

    // Faces that lost a corner became triangles; faces untouched stayed quads.
    // The mutator keeps surviving faces in their original relative order, so the
    // expected[] list lines up with the new face order.
    assert(m.faces.length == expected.length, "surviving face count matches");
    foreach (newFi; 0 .. m.faces.length) {
        assert(m.faces[newFi].length == expected[newFi].length,
            "(b) dissolve: surviving corner count per face");
        foreach (c; 0 .. m.faces[newFi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)newFi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = expected[newFi][c];
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "(b) dissolve verts: survivor corners keep planted uv");
        }
    }
}

// ---------------------------------------------------------------------------
// (b) dissolve edge / remove-edge merge → merged face's corners keep uv traced
// through the boundary walk.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    // Find the shared edge between face 0 ([0,3,2,1]) and face 4 ([3,7,6,2]):
    // the undirected edge (2,3). Select it and dissolve → those two faces merge.
    int sharedEdge = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 2 && b == 3) || (a == 3 && b == 2)) { sharedEdge = cast(int)i; break; }
    }
    assert(sharedEdge >= 0, "edge (2,3) exists");
    auto emask = new bool[](m.edges.length);
    emask[sharedEdge] = true;

    const auto merged = m.removeEdgesByMask(emask);
    assert(merged == 1, "one interior edge dissolved");
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2,
        "PolyVertex length correct after edge merge");

    // Every surviving corner's uv must be one of the originally-planted values
    // (the merge walk traces each merged corner to an old corner; kept faces are
    // arity-preserving). Build the planted set, then check each surviving corner
    // is in it (a corner with vertex still referenced and traced) — merged
    // corners that the walk could not trace are zero-filled (allowed). The key
    // assertion: NO surviving corner carries a WRONG non-zero planted value.
    bool isPlanted(float u, float v) {
        // planted values: u in [0..55] roughly, v == u + 100. Zero-fill = (0,0)
        // which collides with plantedUv(0,0) = (0,100); so treat (0,0) as the
        // zero-fill sentinel explicitly.
        if (feq(u, 0.0f) && feq(v, 0.0f)) return true; // zero-fill OK
        return feq(v, u + 100.0f);
    }
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            assert(got.length == 2, "dim-2 read");
            assert(isPlanted(got[0], got[1]),
                "(b) edge-merge: every surviving corner carries a planted or zero uv");
        }
    }
}

// ---------------------------------------------------------------------------
// (b) weld coincident (arity-shrinking, NO buildLoops) → survivor corners keep
// uv under corner-collapse. This is the import-weld primitive.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    // Move vertex 1 onto vertex 0 then weld. Faces containing BOTH 0 and 1
    // adjacent collapse that consecutive-dup corner (arity shrinks); faces with
    // only one of them re-point. Capture, before welding, the expected surviving
    // per-face corner uv stream by replaying the weld's corner-collapse logic.
    import math : Vec3;
    m.vertices[1] = m.vertices[0];

    // Replay the collapse on a copy of faces to compute the expected surviving
    // (face, corner) uv stream (vertex 1 → 0 remap, consecutive-dup drop,
    // wrap-around drop, sub-3 face drop).
    float[2][][] expected;
    foreach (fi; 0 .. m.faces.length) {
        uint[] mapped;
        float[2][] mappedUv;
        foreach (c; 0 .. m.faces[fi].length) {
            uint vid = m.faces[fi][c];
            uint rv = (vid == 1) ? 0u : vid;
            if (mapped.length == 0 || mapped[$ - 1] != rv) {
                mapped ~= rv;
                mappedUv ~= plantedUv(cast(uint)fi, cast(uint)c);
            }
        }
        if (mapped.length > 1 && mapped[$ - 1] == mapped[0]) {
            mapped = mapped[0 .. $ - 1];
            mappedUv = mappedUv[0 .. $ - 1];
        }
        if (mapped.length >= 3) expected ~= mappedUv;
    }

    const auto welded = m.weldCoincidentVertices();
    assert(welded == 1, "one vertex welded");
    // weld does NOT call buildLoops; mirror a real caller so faceCornerLoop is
    // valid for the asserts below.
    m.buildLoops();
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2,
        "PolyVertex length correct after weld");
    assert(m.faces.length == expected.length, "surviving face count matches replay");
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == expected[fi].length,
            "(b) weld: surviving corner count per face matches replay");
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = expected[fi][c];
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "(b) weld coincident: survivor corners keep planted uv under collapse");
        }
    }
}

// ---------------------------------------------------------------------------
// append addFace → old corners unchanged, new corners zero; AND the GAP-3
// no-window invariant: data.length == Σ face-arities * dim right after addFace.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    const size_t cornersBefore = m.loops.length; // 24
    // Append a triangle (3 new corners) WITHOUT calling buildLoops.
    m.addFace([0, 1, 2]);

    // GAP-3: the PolyVertex map must already reflect the appended corners — no
    // window where data.length lags the face-corner count. loops is STALE here
    // (addFace defers buildLoops), so verify against Σ face-arities directly.
    size_t sumArities = 0;
    foreach (fi; 0 .. m.faces.length) sumArities += m.faces[fi].length;
    assert(sumArities == cornersBefore + 3, "one triangle added 3 corners");
    assert(m.meshMap(kUvMapName).data.length == sumArities * 2,
        "GAP-3: data.length == Σ face-arities * dim immediately after addFace");

    // Now rebuild loops (a later op would) and assert old corners unchanged + new
    // corners zero.
    m.buildLoops();
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2);
    // Old cube faces 0..5 keep their planted uv.
    foreach (fi; 0 .. 6) {
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = plantedUv(cast(uint)fi, cast(uint)c);
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "append: pre-existing corners unchanged");
        }
    }
    // The appended face (index 6) has zero-filled corners.
    foreach (c; 0 .. m.faces[6].length) {
        const size_t li = m.faceCornerLoop(6, cast(uint)c);
        auto got = m.meshMapValue(kUvMapName, li);
        assert(got.length == 2 && feq(got[0], 0.0f) && feq(got[1], 0.0f),
            "append: new corners zero-filled");
    }
}

// ---------------------------------------------------------------------------
// snapshot capture → destructive edit → restore → per-corner uv back (R6).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    auto snap = MeshSnapshot.capture(m);
    assert(snap.filled);

    // Destructive edit: delete two faces (changes loop count + values).
    auto mask = new bool[](m.faces.length);
    mask[1] = true; mask[3] = true;
    m.deleteFacesByMask(mask);
    assert(m.faces.length == 4);

    snap.restore(m);

    // Geometry + per-corner uv must be back to the planted state.
    assert(m.faces.length == 6, "restore brings faces back");
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2);
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t li = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            auto got = m.meshMapValue(kUvMapName, li);
            const float[2] want = plantedUv(cast(uint)fi, cast(uint)c);
            assert(got.length == 2 && feq(got[0], want[0]) && feq(got[1], want[1]),
                "snapshot restore: per-corner uv back");
        }
    }
}

// ---------------------------------------------------------------------------
// DROP class — note on subdivide (D9): Catmull-Clark in this codebase
// (`subdivideCube` / the OSD path) builds a WHOLLY NEW Mesh rather than mutating
// the cage in place, so there is no incoming PolyVertex map to drop — the result
// mesh simply has no `"uv"` map (and a freshly-added one is zero/length-correct,
// covered by the primitive case below). UV interpolation through Catmull-Clark
// is an explicit non-goal. The in-place DROP behaviour (op rewrites faces +
// buildLoops → length-correct, values zeroed) is exercised by extrude below.

// ---------------------------------------------------------------------------
// DROP class: extrudeEdgesByMask → uv dropped (length-correct, zeroed), no
// crash. Additive side faces have no stable corner correspondence.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    plantAllCorners(m);

    auto emask = new bool[](m.edges.length);
    emask[0] = true; // extrude one edge
    m.extrudeEdgesByMask(emask, 0.2f, 0.1f);
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null);
    assert(uv.data.length == m.loops.length * 2, "drop: length-correct after extrude");
    foreach (f; uv.data) assert(feq(f, 0.0f), "drop: values zeroed after extrude");
}

// ---------------------------------------------------------------------------
// DROP class: a primitive factory rebuild has no incoming map (factories build
// from scratch). Assert a freshly-built primitive accepts a PolyVertex map at
// the right size with no crash — the "primitive rebuild drops UV" case is
// inherently covered because factories produce a brand-new mesh with no map.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    auto m = makeGridPlane(1); // single quad
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null);
    assert(uv.data.length == m.loops.length * 2,
        "drop/primitive: PolyVertex sized to the rebuilt loop count");
    foreach (f; uv.data) assert(feq(f, 0.0f));
}
