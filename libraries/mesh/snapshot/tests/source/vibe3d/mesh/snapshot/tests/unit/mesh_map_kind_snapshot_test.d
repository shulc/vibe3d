module vibe3d.mesh.snapshot.tests.unit.mesh_map_kind_snapshot_test;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math : Vec3;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;

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

// MUTATION 1a: make `dup()` shallow on `present` -> this reddens.
// MeshSnapshot deep-dups the presence channel, not just `data`. Under the
// ABSOLUTE kind a lost presence bit is a moved vertex, so this is asserted
// through `morphEvaluate` (a position) as well as through `morphValue`.
unittest {
    import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
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

