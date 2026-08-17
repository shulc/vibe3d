// Module unittests for the `MapKind` registry (task 1062 / 1060 §1
// amendment 1) — a lookup table over the existing `MeshMap` (name, dim,
// domain, data) shape, not a data-layout change. Covers: kind -> declared
// (domain, dim); length tracks `edges.length` across a topology edit via the
// existing `resizeEdgeSelection` hook; `MeshSnapshot` round-trips an Edge
// map (deep-dup, not aliased).
module tests.unit.mesh_map_kind_test;

import mesh;
import snapshot : MeshSnapshot;

// kindInfo() declares the right (domain, dim, reservedName) for each kind.
unittest {
    auto uv = kindInfo(MapKind.uv);
    assert(uv.domain == MapDomain.PolyVertex);
    assert(uv.dim == 2);
    assert(uv.reservedName == kUvMapName);

    auto vw = kindInfo(MapKind.vertexWeight);
    assert(vw.domain == MapDomain.Point);
    assert(vw.dim == 1);
    assert(vw.reservedName.length == 0,
        "vertexWeight reserves no single name -- many named instances per mesh");

    auto cw = kindInfo(MapKind.creaseWeight);
    assert(cw.domain == MapDomain.Edge);
    assert(cw.dim == 1);
    assert(cw.reservedName == kCreaseWeightMapName);
    assert(cw.reservedName == "crease");
}

// addMeshMapOfKind derives domain+dim from the registry instead of the
// caller open-coding them, and defaults the name to the kind's reserved
// name when the caller doesn't supply one.
unittest {
    Mesh m = makeCube();

    auto crease = m.addMeshMapOfKind(MapKind.creaseWeight);
    assert(crease !is null);
    assert(crease.name == "crease");
    assert(crease.domain == MapDomain.Edge);
    assert(crease.dim == 1);
    assert(crease.data.length == m.edges.length);

    // vertexWeight has no reserved name -- must be supplied explicitly.
    auto vw = m.addMeshMapOfKind(MapKind.vertexWeight, "myWeights");
    assert(vw !is null);
    assert(vw.name == "myWeights");
    assert(vw.domain == MapDomain.Point);
    assert(vw.dim == 1);

    // A second call under the SAME reserved name fails (addMeshMap's
    // existing "names are unique per mesh" rule) -- addMeshMapOfKind does
    // not bypass it.
    assert(m.addMeshMapOfKind(MapKind.creaseWeight) is null);
}

// The crease map's length tracks `edges.length` across a topology edit —
// the SAME resize hook every other MeshMap already rides
// (`resizeEdgeSelection` -> `resizeMeshMaps(MapDomain.Edge)`), pinned here
// specifically for the new reserved kind so a future change to that wiring
// cannot silently exempt it. Mutation: skip `resizeMeshMaps` inside
// `resizeEdgeSelection` -> this reddens with an out-of-bounds `data.length`
// after `rebuildEdges` grows `edges`.
unittest {
    Mesh m = makeCube();
    auto crease = m.addMeshMapOfKind(MapKind.creaseWeight);
    assert(crease.data.length == 12, "cube cage has 12 edges");

    // Grow the edge table directly (the way any real topology mutator's
    // final rebuildEdges()/buildLoops() would leave it) and drive the SAME
    // resize hook every topology mutator ends in
    // (`resizeEdgeSelection` -> `resizeMeshMaps(MapDomain.Edge)`,
    // source/mesh.d). Not going through a specific command keeps this test
    // pinned to the hook itself rather than to any one mutator's call
    // sequence.
    m.edges ~= [cast(uint) 0, cast(uint) 100]; // a bogus extra edge for length only
    m.resizeEdgeSelection();

    assert(m.edges.length == 13, "edge table did not grow as expected");
    auto creaseAfter = m.creaseWeightMap();
    assert(creaseAfter !is null);
    assert(creaseAfter.data.length == m.edges.length,
        "crease map must track edges.length across a topology edit");
    // The newly-grown slot defaults to 0 (no crease), same zero-fill
    // discipline as every other MeshMap (resizeMeshMapData).
    assert(creaseAfter.data[12] == 0.0f);
}

// Re-applying the SAME crease weight must be a no-op: no version bump, no
// preview rebuild, no undo entry for nothing (task 1062 review, SHOULD-FIX
// 3 — the commonest UI gesture is "open the dialog, press OK" with the
// unchanged default, matching `setSubpatch`'s own no-op guard,
// source/mesh.d `:5591-5603`). A DIFFERENT value still bumps. NaN-to-NaN is
// ALSO a no-op (an identity comparison, not `==`, which is never true for
// NaN even against itself). Mutation: replace `isIdentical(m.data[ei], w)`
// with `m.data[ei] == w` -> the NaN-to-NaN leg reddens (verified
// 2026-08-17: `==` is false for NaN vs NaN, so the guard never fires and
// `topologyVersion` keeps climbing on every re-write).
unittest {
    Mesh m = makeCube();
    immutable uint ei = m.edgeIndex(0, 1);
    assert(ei != ~0u);

    assert(m.setCreaseWeight(ei, 0.4f));
    immutable ulong afterFirst = m.topologyVersion;

    // Same value again -> no bump.
    assert(m.setCreaseWeight(ei, 0.4f));
    assert(m.topologyVersion == afterFirst,
        "re-writing the SAME weight must not bump topologyVersion");

    // Different value -> bumps.
    assert(m.setCreaseWeight(ei, 0.6f));
    assert(m.topologyVersion > afterFirst,
        "writing a DIFFERENT weight must still bump topologyVersion");
    immutable ulong afterChange = m.topologyVersion;

    // NaN-to-NaN: `==` is never true for NaN, so a naive equality guard
    // would never short-circuit this and topologyVersion would keep
    // climbing forever on repeat NaN writes.
    assert(m.setCreaseWeight(ei, float.nan));
    immutable ulong afterNan = m.topologyVersion;
    assert(afterNan > afterChange, "the FIRST NaN write is a real change");
    assert(m.setCreaseWeight(ei, float.nan));
    assert(m.topologyVersion == afterNan,
        "re-writing NaN over an existing NaN must ALSO be a no-op "
      ~ "(isIdentical, not ==)");
}

// MeshSnapshot deep-dups the crease map: mutating the live mesh after a
// capture must not alter the captured snapshot's data (the same aliasing
// guarantee every other MeshMap already has, via snapshot.d's
// `.map!(mm => mm.dup).array`). Mutation: replace the `.dup` with a bare
// assignment in MeshSnapshot.capture/restore -> the "snapshot unchanged
// after live mutation" assertion below reddens.
unittest {
    Mesh m = makeCube();
    immutable uint e01 = m.edgeIndex(0, 1);
    m.setCreaseWeight(e01, 0.3f);

    auto snap = MeshSnapshot.capture(m);

    // Mutate the LIVE mesh's crease value after the snapshot was taken.
    m.setCreaseWeight(e01, 0.9f);
    assert(m.edgeCreaseWeight(e01) == 0.9f);

    // The snapshot's own copy must be untouched by that live mutation.
    bool foundInSnap = false;
    foreach (ref mm; snap.meshMaps) {
        if (mm.name != "crease") continue;
        foundInSnap = true;
        assert(mm.data[e01] == 0.3f,
            "MeshSnapshot.capture must deep-dup the crease map's data, not alias it");
    }
    assert(foundInSnap, "captured snapshot must carry the crease map");

    // Restore brings the live mesh back to the captured 0.3 value.
    snap.restore(m);
    assert(m.edgeCreaseWeight(e01) == 0.3f,
        "MeshSnapshot.restore must bring the crease map back to its captured state");
}
