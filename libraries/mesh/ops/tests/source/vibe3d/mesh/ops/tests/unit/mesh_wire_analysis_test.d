module vibe3d.mesh.ops.tests.unit.mesh_wire_analysis_test;

import vibe3d.util.math.math : Vec3;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.ops.mesh_analysis : orphanVertexIndices;

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
