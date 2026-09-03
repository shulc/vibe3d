module tests.unit.mesh_wire_weld_undo_test;

import math : Vec3;
import mesh : CleanupResult, Mesh, MeshEditBatch;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;
import mesh_ops.cleanup : cleanupMesh, kCleanupEditScope;

private bool hasWire(in Mesh m, uint a, uint b) {
    foreach (ref e; m.edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return true;
    return false;
}

private Mesh stand() {
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0),
                 Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(1, 0, 0), Vec3(20, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(5, 4);
    assert(m.edges.length == 5, "weld fixture: 4 face edges + wire");
    assert(hasWire(m, 5, 4), "weld fixture: authored wire exists");
    assert(!hasWire(m, 5, 1),
           "weld fixture: the future phantom pair must not pre-exist");
    return m;
}

private void assertUndoResult(ref Mesh m, ref MeshEditDelta delta,
                              size_t vertsBefore, Vec3 p1, Vec3 p4, Vec3 p5,
                              string hand) {
    assert(m.vertices.length != vertsBefore,
           hand ~ ": weld must change vertex population before undo");
    assert(delta.revert(m), hand ~ ": reverse replay must answer true");
    assert(m.vertices.length == vertsBefore,
           hand ~ ": undo restored the vertex count");
    assert(m.vertices[1] == p1 && m.vertices[4] == p4 && m.vertices[5] == p5,
           hand ~ ": undo restored vertices at their original indices");
    assert(!hasWire(m, 5, 1),
           hand ~ ": PHANTOM pair (5,1) appeared after weld undo");
    assert(!hasWire(m, 5, 4),
           hand ~ ": current op-log parity says removed authored wire stays absent");
}

unittest { // test 7 hand A: cleanup -> weldCoincidentVertices -> applyVertexRemap
    Mesh m = stand();
    const size_t vertsBefore = m.vertices.length;
    const p1 = m.vertices[1], p4 = m.vertices[4], p5 = m.vertices[5];
    MeshEditDelta delta;
    CleanupResult result;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);
        result = cleanupMesh(ed);
        delta = ed.close();
    }
    assert(result.welded == 1, "hand A fixture: exactly v4 welds into v1");
    assert(!delta.isEmpty(), "hand A fixture: cleanup recorded an op-log");
    assertUndoResult(m, delta, vertsBefore, p1, p4, p5, "hand A");
}

unittest { // test 7 hand B: weldVertexPairs -> applyVertexRemapAndRebuild
    Mesh m = stand();
    const size_t vertsBefore = m.vertices.length;
    const p1 = m.vertices[1], p4 = m.vertices[4], p5 = m.vertices[5];
    MeshEditDelta delta;
    size_t welded;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        welded = ed.weldVertexPairs([[1u, 4u]]);
        delta = ed.close();
    }
    assert(welded == 1, "hand B fixture: explicit [keep,drop] pair must weld");
    assert(!delta.isEmpty(), "hand B fixture: weld recorded an op-log");
    assertUndoResult(m, delta, vertsBefore, p1, p4, p5, "hand B");
}
