module tests.unit.mesh_wire_oplog_gap_test;

import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope, MeshEditTracker;

private bool hasWireAt(in Mesh m, Vec3 a, Vec3 b) {
    foreach (ref e; m.edges) {
        if (e[0] >= m.vertices.length || e[1] >= m.vertices.length) continue;
        const x = m.vertices[e[0]], y = m.vertices[e[1]];
        if ((x == a && y == b) || (x == b && y == a)) return true;
    }
    return false;
}

unittest { // test 6: pin the known op-log gap for explicit endpoint removal
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(4, 5);
    const p4 = m.vertices[4], p5 = m.vertices[5];

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    bool[] mask = new bool[](m.vertices.length);
    mask[4] = true;
    assert(m.dissolveVerticesByMask(mask) == 1,
           "op-log gap fixture: endpoint removal executes");
    auto delta = m.endEditBatch();
    assert(!delta.isEmpty(), "op-log gap fixture: removal recorded a delta");
    assert(delta.revert(m), "op-log gap: reverse replay must answer true");
    assert(!hasWireAt(m, p4, p5),
           "registry gap row: undo unexpectedly restored the removed authored wire");
}
