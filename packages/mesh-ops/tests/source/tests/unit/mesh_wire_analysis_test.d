module tests.unit.mesh_wire_analysis_test;

import math : Vec3;
import mesh : Mesh;
import mesh_analysis : orphanVertexIndices;

unittest { // authored-wire endpoints are not reported as cleanup orphans
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0), Vec3(30, 0, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(4, 5);
    assert(orphanVertexIndices(m) == [6u],
           "orphan analysis: only the vertex held by neither face nor wire is orphaned");
}
