// Module unittests for the `MapKind` registry (task 1062 / 1060 §1
// amendment 1) — a lookup table over the existing `MeshMap` (name, dim,
// domain, data) shape, not a data-layout change. Covers: kind -> declared
// (domain, dim); length tracks `edges.length` across a topology edit via the
// existing `resizeEdgeSelection` hook; `MeshSnapshot` round-trips an Edge
// map (deep-dup, not aliased).
module tests.unit.mesh_map_kind_test;

import mesh;
import math : Vec3;
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

// ---------------------------------------------------------------------------
// Task 1069 — the presence channel and the stored kind.
// ---------------------------------------------------------------------------

// The registry declares `tracksPresence` / `absentIsZero` for every kind, and
// the two morph kinds DIFFER on the second — which is the whole reason they
// are two members and not one member with a flag. `unclassified` is declared
// un-constructible (dim 0) rather than aliased onto some other kind's shape.
unittest {
    foreach (k; [MapKind.uv, MapKind.vertexWeight, MapKind.creaseWeight]) {
        assert(!kindInfo(k).tracksPresence,
            "a pre-1069 kind must allocate no presence channel");
    }
    assert(kindInfo(MapKind.unclassified).dim == 0,
        "unclassified declares no shape, so addMeshMapOfKind cannot register it");

    const rel = kindInfo(MapKind.morphRelative);
    const abs = kindInfo(MapKind.morphAbsolute);
    assert(rel.domain == MapDomain.Point && rel.dim == 3);
    assert(abs.domain == MapDomain.Point && abs.dim == 3);
    assert(rel.tracksPresence && abs.tracksPresence);
    assert(rel.absentIsZero, "relative: an absent entry means zero displacement");
    assert(!abs.absentIsZero, "absolute: an absent entry means STAY AT THE BASE");
    assert(rel.reservedName.length == 0 && abs.reservedName.length == 0,
        "both morph kinds are many-named -- neither reserves a name, which is "
      ~ "exactly why the kind has to be STORED rather than inferred");

    assert(isMorphKind(MapKind.morphRelative) && isMorphKind(MapKind.morphAbsolute));
    assert(!isMorphKind(MapKind.unclassified) && !isMorphKind(MapKind.vertexWeight));

    // addMeshMapOfKind(unclassified) must refuse rather than register a
    // shapeless map (addMeshMap rejects dim == 0).
    Mesh m = makeCube();
    assert(m.addMeshMapOfKind(MapKind.unclassified, "nope") is null);
}

// Creation defaults: relative is created EMPTY (no vertex has an entry) and
// absolute is created by the COMMAND as a dense snapshot -- at the mesh layer
// both start absent, and the dense fill is the command's job (Stage 3). What
// the mesh layer owns is that `present` exists, is per ELEMENT (no `* dim`),
// and starts all-absent.
unittest {
    Mesh m = makeCube();
    auto rel = m.addMeshMapOfKind(MapKind.morphRelative, "blink");
    assert(rel !is null);
    assert(rel.kind == MapKind.morphRelative, "the kind is STORED on the map");
    assert(rel.data.length == m.vertices.length * 3);
    assert(rel.present.length == m.vertices.length,
        "presence is per ELEMENT -- `* dim` here would be the classic bug");
    foreach (p; rel.present) assert(p == 0, "a new morph map is created ABSENT");
    assert(m.morphEntryCount("blink") == 0);

    // A map that does NOT track presence allocates nothing, and its
    // `isPresent` still answers true for every in-range element -- which is
    // what keeps every pre-1069 map byte-identical.
    auto w = m.addWeightMap("w");
    assert(w !is null);
    assert(w.present.length == 0, "a weight map pays nothing for presence");
    assert(w.isPresent(0) && w.isPresent(m.vertices.length - 1));
    assert(!w.isPresent(m.vertices.length), "out of range is not present");

    // addWeightMap now CLASSIFIES (the other half of the negative-filter fix).
    assert(w.kind == MapKind.vertexWeight);
}

// The presence read and the evaluate read are DIFFERENT reads. `morphValue`
// reports absence and refuses to invent a value; `morphEvaluate` substitutes
// the kind's declared default and therefore cannot report absence at all.
// For the ABSOLUTE kind that default is the vertex's own base position, so
// absence is a POSITION -- the property that makes presence bugs visible in
// geometry (mutation 1b's oracle).
unittest {
    Mesh m = makeCube();
    m.addMeshMapOfKind(MapKind.morphRelative, "rel");
    m.addMeshMapOfKind(MapKind.morphAbsolute, "abs");

    Vec3 v;
    assert(!m.morphValue("rel", 0, v), "created empty -- vertex 0 has no entry");
    assert(v.x == 0 && v.y == 0 && v.z == 0);
    assert(!m.morphValue("abs", 0, v));

    // evaluate substitutes per kind
    assert(m.morphEvaluate("rel", 0) == Vec3(0, 0, 0));
    assert(m.morphEvaluate("abs", 0) == m.vertices[0],
        "absolute + absent == stay at the base position");

    assert(m.setMorphValue("rel", 0, Vec3(1, 2, 3)));
    assert(m.morphValue("rel", 0, v) && v == Vec3(1, 2, 3));
    assert(m.morphEntryCount("rel") == 1);

    // A stored ZERO is present, and is NOT the same state as absent.
    assert(m.setMorphValue("rel", 1, Vec3(0, 0, 0)));
    assert(m.morphValue("rel", 1, v), "a zero entry is still an ENTRY");
    assert(m.morphEntryCount("rel") == 2);
    assert(m.clearMorphValue("rel", 1));
    assert(!m.morphValue("rel", 1, v), "clear removes the entry, not just its value");
    assert(m.morphEntryCount("rel") == 1);

    // Neither accessor touches a non-morph map.
    m.addWeightMap("w");
    assert(!m.setMorphValue("w", 0, Vec3(1, 1, 1)));
    assert(!m.morphValue("w", 0, v));
}

// MUTATION 1a: make `dup()` shallow on `present` -> this reddens.
// MeshSnapshot deep-dups the presence channel, not just `data`. Under the
// ABSOLUTE kind a lost presence bit is a moved vertex, so this is asserted
// through `morphEvaluate` (a position) as well as through `morphValue`.
unittest {
    import snapshot : MeshSnapshot;
    Mesh m = makeCube();
    m.addMeshMapOfKind(MapKind.morphAbsolute, "spot");
    assert(m.setMorphValue("spot", 2, Vec3(9, 9, 9)));

    auto snap = MeshSnapshot.capture(m);

    // Mutate the LIVE mesh's presence after the capture.
    assert(m.clearMorphValue("spot", 2));
    assert(m.morphEvaluate("spot", 2) == m.vertices[2]);

    bool found = false;
    foreach (ref mm; snap.meshMaps) {
        if (mm.name != "spot") continue;
        found = true;
        assert(mm.present.length == m.vertices.length,
            "the snapshot must carry its OWN presence array, not an alias");
        assert(mm.present[2] != 0,
            "MeshSnapshot.capture must deep-dup `present` -- a shallow dup "
          ~ "aliases the live array and the cleared bit leaks into the snapshot");
    }
    assert(found);

    snap.restore(m);
    Vec3 v;
    assert(m.morphValue("spot", 2, v) && v == Vec3(9, 9, 9),
        "restore brings the entry back, presence included");
    assert(m.morphEvaluate("spot", 2) == Vec3(9, 9, 9));
}

// Presence tracks the vertex count across a resize, per ELEMENT, and newly
// grown slots default to ABSENT (0) -- right for both kinds: a brand-new
// vertex has no delta and stays at its base.
unittest {
    Mesh m = makeCube();
    m.addMeshMapOfKind(MapKind.morphRelative, "rel");
    assert(m.setMorphValue("rel", 0, Vec3(1, 0, 0)));

    m.vertices ~= Vec3(5, 5, 5);
    m.resizeVertexSelection();

    auto mm = m.meshMap("rel");
    assert(mm.data.length == m.vertices.length * 3);
    assert(mm.present.length == m.vertices.length,
        "presence resizes per ELEMENT -- `elementCount * dim` here would "
      ~ "over-allocate by 3x and silently mis-index every later read");
    assert(mm.present[$ - 1] == 0, "a newly grown slot is ABSENT");
    Vec3 v;
    assert(m.morphValue("rel", 0, v) && v == Vec3(1, 0, 0), "existing entry survives");
}

// MUTATION 1b: in `compactUnreferenced`'s Point-domain gather, copy `data`
// but not `present` -> this reddens. Deliberately uses the ABSOLUTE kind:
// under the RELATIVE kind the same bug is geometrically INVISIBLE (absent and
// zero produce the same position), which is §3 of the plan in miniature.
unittest {
    Mesh m = makeCube();
    m.addMeshMapOfKind(MapKind.morphAbsolute, "spot");
    // Give ONLY the last vertex an entry. After a compaction that drops an
    // earlier vertex, that entry must move with ITS vertex -- a data-only
    // gather leaves the presence bit at the old slot, so some other vertex
    // wears it and the entry's own vertex loses it.
    const size_t last = m.vertices.length - 1;
    const Vec3 target = Vec3(7, 7, 7);
    assert(m.setMorphValue("spot", last, target));

    // Drop EVERY face incident to vertex 0, so vertex 0 becomes unreferenced
    // and the compaction renumbers every later vertex -- including the one
    // carrying the entry. One face is not enough on a cube (each vertex is
    // shared by three), and a fixture that drops nothing makes this test inert.
    const size_t before = m.vertices.length;
    bool[] fmask; fmask.length = m.faces.length; fmask[] = false;
    foreach (fi, f; m.faces.range) {
        foreach (vid; f) if (vid == 0) { fmask[fi] = true; break; }
    }
    m.deleteFacesByMask(fmask);
    if (m.vertices.length == before) m.compactUnreferenced();
    assert(m.vertices.length < before,
        "the fixture must actually drop a vertex, or the gather is never "
      ~ "exercised and this test is inert");

    // Find the vertex that carries the entry now: it must be the one sitting
    // at `target`'s own vertex, and no other vertex may claim an entry.
    size_t entries = 0;
    foreach (i; 0 .. m.vertices.length) {
        Vec3 v;
        if (m.morphValue("spot", i, v)) {
            ++entries;
            assert(v == target, "the surviving entry kept its value");
            assert(m.morphEvaluate("spot", i) == target);
        } else {
            assert(m.morphEvaluate("spot", i) == m.vertices[i],
                "a vertex with no entry must evaluate to its BASE position -- "
              ~ "a mis-gathered presence bit shows up here as a moved vertex");
        }
    }
    assert(entries == 1,
        "exactly one entry survives the compaction; a data-only gather "
      ~ "leaves the presence bit on the wrong vertex");
}

// MUTATION 1c: filter `weightMapNames()` POSITIVELY on `kind ==
// vertexWeight` -> this reddens. Every weight map created before task 1069,
// and every one a pre-1069 `.v3d` reader creates, is `unclassified`; a
// positive filter returns EMPTY for all of them, which empties the falloff
// weight-map dropdown and makes `select.byStat` reject a map that exists.
unittest {
    Mesh m = makeCube();

    // A legacy map: created through the RAW addMeshMap, so unclassified --
    // exactly what the `.v3d` reader produces for a pre-1069 file.
    auto legacy = m.addMeshMap("legacyWeights", 1, MapDomain.Point);
    assert(legacy !is null && legacy.kind == MapKind.unclassified);

    auto fresh = m.addWeightMap("freshWeights");
    assert(fresh !is null && fresh.kind == MapKind.vertexWeight);

    m.addMeshMapOfKind(MapKind.morphRelative, "blink");

    auto names = m.weightMapNames();
    assert(names.length == 2,
        "both the legacy UNCLASSIFIED map and the freshly classified one must "
      ~ "be listed -- a positive kind filter drops the legacy one");
    bool sawLegacy = false, sawFresh = false, sawMorph = false;
    foreach (n; names) {
        if (n == "legacyWeights") sawLegacy = true;
        if (n == "freshWeights")  sawFresh  = true;
        if (n == "blink")         sawMorph  = true;
    }
    assert(sawLegacy && sawFresh);
    assert(!sawMorph, "a morph map is never a weight map");

    assert(m.mapNamesOfKind(MapKind.morphRelative) == ["blink"]);
    assert(m.morphMapNames() == ["blink"]);
    assert(m.mapKind("blink") == MapKind.morphRelative);
    assert(m.mapKind("nosuch") == MapKind.unclassified);
}

// MAX_MESH_MAPS is a kernel-only backstop: the 257th map is refused. There is
// no Param layer to clamp -- a scripted `mesh.morph.create` loop is the
// allocation vector -- so the cap lives where every creation path funnels.
unittest {
    import std.format : format;
    Mesh m = makeCube();
    foreach (i; 0 .. MAX_MESH_MAPS) {
        auto mm = m.addWeightMap(format("w%d", i));
        assert(mm !is null, format("map %d must be accepted (cap is %d)",
                                   i, MAX_MESH_MAPS));
    }
    assert(m.meshMaps.length == MAX_MESH_MAPS);
    assert(m.addWeightMap("oneTooMany") is null,
        "the cap is enforced in addMeshMap, which every creation path uses");
    assert(m.addMeshMapOfKind(MapKind.morphRelative, "alsoTooMany") is null,
        "addMeshMapOfKind funnels through addMeshMap, so it is capped too");
    assert(m.meshMaps.length == MAX_MESH_MAPS, "nothing was appended past the cap");
}
