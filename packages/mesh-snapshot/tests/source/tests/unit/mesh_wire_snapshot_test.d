module tests.unit.mesh_wire_snapshot_test;

import math : Vec3;
import mesh : edgeKey, Mesh;
import snapshot : MeshSnapshot;

private Mesh stand() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addEdge(0, 1);
    return m;
}

unittest { // capture/matches/restore include and detach the authored-wire AA
    Mesh m = stand();
    auto snap = MeshSnapshot.capture(m);
    assert(snap.matches(m), "wire snapshot: capture initially matches");
    m.wireEdgeKeys.remove(edgeKey(0, 1));
    assert(!snap.matches(m), "wire snapshot: matches must see registry drift");
    snap.restore(m);
    assert(snap.matches(m), "wire snapshot: restore returns the registry");

    auto copy = snap.ownedDup();
    copy.wireEdgeKeys.remove(edgeKey(0, 1));
    assert(!copy.matches(snap), "wire snapshot: ownedDup AA is detached");
    assert((edgeKey(0, 1) in snap.wireEdgeKeys) !is null,
           "wire snapshot: mutating the duplicate did not alias the source");
}
