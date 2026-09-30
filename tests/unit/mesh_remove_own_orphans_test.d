module tests.unit.mesh_remove_own_orphans_test;

// `Mesh.removeFacesWithOwnOrphans` (task 8710): a face remove takes the
// vertices and edges THIS removal leaves with no face, and nothing else. The
// HTTP cells (`chord-remove` in tests/test_session_laws_topology_pen.d) cover
// the pen's rig, which has no wire; this stand carries the loose geometry the
// kernel must leave alone, one kind each, so every term of the kernel has a
// cell that sees it.
//
// Stand: two quads F0 (0, 1, 4, 3) and F1 (1, 2, 5, 4); a loose point 6; a
// registered wire (7, 8); an UNREGISTERED wire (9, 10); an unregistered wire
// (0, 11) hanging off F0's corner 0. Removing F0 orphans corner 3 and the
// edges (0, 1), (3, 0), (4, 3); corner 0 keeps its wire, so it stays.

import change_bus : changeBus;
import math : Vec3;
import mesh : Mesh;
import mesh_topo : edgeKey;
import std.format : format;

private immutable Vec3[] kPos = [
    Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0),     // 0 1 2
    Vec3(0, 1, 0), Vec3(1, 1, 0), Vec3(2, 1, 0),     // 3 4 5
    Vec3(5, 5, 0),                                   // 6 loose point
    Vec3(7, 0, 0), Vec3(8, 0, 0),                    // 7 8 registered wire
    Vec3(7, 2, 0), Vec3(8, 2, 0),                    // 9 10 unregistered wire
    Vec3(-1, -1, 0),                                 // 11 wire off corner 0
];

private Mesh stand() {
    Mesh m;
    foreach (p; kPos) m.addVertex(p);
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.addEdge(7, 8);
    m.addEdge(9, 10);
    m.addEdge(0, 11);
    m.wireEdgeKeys.remove(edgeKey(9, 10));
    m.wireEdgeKeys.remove(edgeKey(0, 11));
    m.buildLoops();
    m.syncSelection();
    return m;
}

private bool hasVert(in Mesh m, Vec3 p) {
    foreach (v; m.vertices) if (v == p) return true;
    return false;
}

private bool hasEdgeAt(in Mesh m, Vec3 a, Vec3 b) {
    foreach (ref e; m.edges) {
        const x = m.vertices[e[0]], y = m.vertices[e[1]];
        if ((x == a && y == b) || (x == b && y == a)) return true;
    }
    return false;
}

private bool registeredAt(in Mesh m, Vec3 a, Vec3 b) {
    foreach (key, _; m.wireEdgeKeys) {
        const uint i = cast(uint)(key >> 32), j = cast(uint)(key & 0xFFFF_FFFFUL);
        if (i >= m.vertices.length || j >= m.vertices.length) continue;
        const x = m.vertices[i], y = m.vertices[j];
        if ((x == a && y == b) || (x == b && y == a)) return true;
    }
    return false;
}

unittest {
    Mesh m = stand();
    // Floors: the stand is what the header says (12 v, 2 f, 7 + 3 edges; two
    // wires unregistered).
    assert(m.vertices.length == 12 && m.faces.length == 2 && m.edges.length == 10
           && m.wireEdgeKeys.length == 1,
           format("stand: %d v, %d f, %d e, %d registered wires", m.vertices.length,
                  m.faces.length, m.edges.length, m.wireEdgeKeys.length));

    const before = changeBus.deliveryCount;
    const removed = m.removeFacesWithOwnOrphans([true, false]);
    assert(removed == 1 && m.faces.length == 1, format("F0 not removed: %d, %d faces", removed, m.faces.length));
    assert(changeBus.deliveryCount == before + 1,
           format("one remove must be one delivery, got %d", changeBus.deliveryCount - before));

    // The survivors that predate the call (above the orphan asserts, so a red
    // below says these held).
    assert(hasVert(m, kPos[6]), "the loose point 6 was swept (whole-mesh orphan sweep)");
    assert(hasEdgeAt(m, kPos[7], kPos[8]), "the registered wire (7, 8) was lost");
    assert(hasEdgeAt(m, kPos[9], kPos[10]), "the unregistered wire (9, 10) was lost");
    assert(hasVert(m, kPos[0]) && hasEdgeAt(m, kPos[0], kPos[11]),
           "corner 0 or its wire (0, 11) was lost: a vertex still holding a wire is not an orphan");

    // What THIS removal orphaned.
    assert(!hasVert(m, kPos[3]), "corner 3 (F0's own orphan) survived");
    assert(!hasEdgeAt(m, kPos[0], kPos[1]), "edge (0, 1), faceless after the remove, survived");
    assert(!hasEdgeAt(m, kPos[3], kPos[0]) && !hasEdgeAt(m, kPos[4], kPos[3]),
           "an edge of the orphaned corner 3 survived");
    assert(!registeredAt(m, kPos[0], kPos[1]), "edge (0, 1) was left in the wire registry");

    // Exact population: 11 v, 1 f, F1's 4 edges + the three wires.
    assert(m.vertices.length == 11 && m.edges.length == 7,
           format("after: %d v (expected 11), %d e (expected 7)", m.vertices.length, m.edges.length));
}

unittest { // an empty mask removes nothing and changes nothing
    Mesh m = stand();
    const removed = m.removeFacesWithOwnOrphans([false, false]);
    assert(removed == 0 && m.vertices.length == 12 && m.edges.length == 10 && m.faces.length == 2,
           "an empty mask changed the mesh");
}
