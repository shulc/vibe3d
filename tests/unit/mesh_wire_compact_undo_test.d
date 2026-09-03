module tests.unit.mesh_wire_compact_undo_test;

import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope, MeshEditTracker;

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

unittest { // test 9: live Reindex forward/reverse both carry authored keys
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(10, 0, 0), Vec3(20, 0, 0), Vec3(21, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(5, 6);
    const p4 = m.vertices[4], p5 = m.vertices[5], p6 = m.vertices[6];
    assert(m.edges.length == 5, "compact undo fixture: 4 face edges + wire");
    assert(hasWireAt(m, p5, p6), "compact undo fixture: wire exists");

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    assert(m.compactUnreferenced() == 1,
           "compact undo fixture: exactly one unpinned vertex must leave");
    auto delta = m.endEditBatch();
    assert(!delta.isEmpty(), "compact undo fixture: batch recorded an op-log");
    assert(!hasVertAt(m, p4), "compact undo forward: orphan left");
    assert(hasWireAt(m, p5, p6),
           "compact undo forward: live compact carry lost the wire");

    assert(delta.revert(m), "compact undo: reverse replay must answer true");
    assert(hasVertAt(m, p4), "compact undo reverse: orphan did not return");
    assert(hasWireAt(m, p5, p6),
           "compact undo reverse: Reindex carry lost the wire");

    assert(delta.apply(m), "compact undo: forward replay must answer true");
    assert(!hasVertAt(m, p4), "compact undo repeat: orphan did not leave again");
    assert(hasWireAt(m, p5, p6),
           "compact undo repeat: Reindex carry lost the wire");
}
