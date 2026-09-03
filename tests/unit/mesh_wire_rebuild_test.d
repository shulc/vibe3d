module tests.unit.mesh_wire_rebuild_test;

import math : Vec3;
import mesh : Mesh;

private bool hasWire(in Mesh m, uint a, uint b) {
    foreach (ref e; m.edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return true;
    return false;
}

private bool hasVertAt(in Mesh m, Vec3 p) {
    foreach (v; m.vertices) if (v == p) return true;
    return false;
}

private bool hasWireAt(in Mesh m, Vec3 a, Vec3 b) {
    foreach (ref e; m.edges) {
        if (e[0] >= m.vertices.length || e[1] >= m.vertices.length) continue;
        const x = m.vertices[e[0]], y = m.vertices[e[1]];
        if ((x == a && y == b) || (x == b && y == a)) return true;
    }
    return false;
}

private Mesh wireStand() {
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(4, 5);
    return m;
}

unittest { // mutation B: rebuildEdges preserves authored bare wires
    Mesh m = wireStand();
    assert(m.edges.length == 5, "B fixture: 4 face edges + wire");
    assert(hasWire(m, 4, 5), "B fixture: wire exists before rebuild");
    m.rebuildEdges();
    assert(m.edges.length == 5,
        "B loss: rebuildEdges derived edges from faces alone");
    assert(hasWire(m, 4, 5), "B loss: rebuildEdges dropped the bare wire");
}

unittest { // the independent rebuildEdgesFromFaces path preserves it too
    Mesh m = wireStand();
    m.rebuildEdgesFromFaces();
    assert(m.edges.length == 5,
        "B4 loss: rebuildEdgesFromFaces derived edges from faces alone");
    assert(hasWire(m, 4, 5),
        "B4 loss: rebuildEdgesFromFaces dropped the bare wire");
}

unittest { // pruning: deleting an authored covered edge must not resurrect it
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0),
                 Vec3(1, 1, 0), Vec3(0, 1, 0)])
        m.addVertex(p);
    m.addEdge(0, 2);
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    bool[] mask = new bool[](m.edges.length);
    const diagonal = m.edgeIndex(0, 2);
    assert(diagonal != uint.max, "remove pruning fixture: diagonal is live");
    mask[diagonal] = true;
    assert(m.removeEdgesByMask(mask) == 1,
           "remove pruning fixture: covered diagonal is a live dissolve target");
    assert(!hasWire(m, 0, 2),
           "remove pruning: explicitly removed authored pair resurrected");
}

unittest { // pruning: dissolving a wire endpoint removes the key and endpoint
    Mesh m = wireStand();
    const Vec3 endpoint = m.vertices[4];
    bool[] mask = new bool[](m.vertices.length);
    mask[4] = true;
    assert(m.dissolveVerticesByMask(mask) == 1,
           "dissolve pruning fixture: one endpoint is removed");
    assert(!hasVertAt(m, endpoint),
           "dissolve pruning: removed endpoint was retained by a stale key");
    assert(!hasWireAt(m, endpoint, Vec3(21, 0, 0)),
           "dissolve pruning: wire survived its endpoint destruction");
}

unittest { // phase 4: pin, carry, and rebuild all execute in one compaction
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(10, 0, 0), Vec3(20, 0, 0), Vec3(21, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(5, 6);
    const p4 = m.vertices[4], p5 = m.vertices[5], p6 = m.vertices[6];
    assert(m.edges.length == 5, "compact fixture: 4 face edges + wire");
    assert(m.compactUnreferenced() == 1,
           "compact fixture: exactly one unpinned vertex must leave");
    assert(hasWireAt(m, p5, p6),
           "compact carry: authored wire must survive its endpoint reindex");
    assert(!hasVertAt(m, p4),
           "compact control: a vertex held by neither face nor wire must leave");
    assert(m.canonicalEdgeOrder().length == m.edges.length,
           "canonical census: compacted live edges are all serializable");
}

unittest { // control W: every live edge remains representable after key operations
    Mesh kept;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0),
                 Vec3(1, 1, 0), Vec3(0, 1, 0)])
        kept.addVertex(p);
    kept.addFace([0u, 1u, 2u, 3u]);
    assert(kept.deleteFacesByMask([true], true, true) == 1,
           "W keep-floating fixture: face removed");
    assert(kept.edges.length == 4 && kept.wireEdgeKeys.length == 4,
           "W keep-floating: four newly orphaned face edges became authored");
    assert(kept.canonicalEdgeOrder().length == kept.edges.length,
           "W keep-floating: every live edge is serializable");

    Mesh dropped;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0),
                 Vec3(1, 1, 0), Vec3(0, 1, 0)])
        dropped.addVertex(p);
    dropped.addFace([0u, 1u, 2u, 3u]);
    assert(dropped.deleteFacesByMask([true], true, false) == 1,
           "W drop-floating fixture: face removed");
    assert(dropped.canonicalEdgeOrder().length == dropped.edges.length,
           "W drop-floating: canonical census matches the empty live table");

    Mesh dissolved = wireStand();
    bool[] vmask = new bool[](dissolved.vertices.length);
    vmask[4] = true;
    assert(dissolved.dissolveVerticesByMask(vmask) == 1,
           "W dissolve fixture: endpoint removed");
    assert(dissolved.canonicalEdgeOrder().length == dissolved.edges.length,
           "W dissolve: every remaining live edge is serializable");
}

unittest { // F1 gesture law: covered authorship outlives the covering face
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    const p0 = m.vertices[0], p2 = m.vertices[2];
    m.addEdge(0, 2);
    m.addFace([0u, 1u, 2u]);
    assert(m.edges.length == 3, "F1 fixture: covered pair is deduplicated");
    assert(m.deleteFacesByMask([true], false, false) == 1,
           "F1 fixture: covering face removed normally");
    assert(hasWireAt(m, p0, p2),
           "F1 gesture law: deleting the cover must leave the authored pair");
}
