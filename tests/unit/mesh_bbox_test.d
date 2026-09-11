module tests.unit.mesh_bbox_test;

import math : Vec3;
import mesh : Mesh;
import mesh_bbox;
import tests.unit.mesh_by_value_gate;

mixin MeshByValueGate!(mesh_bbox);

unittest { // whole-layer bounds ignore selection and report empty geometry
    Mesh mesh;
    Vec3 mn, mx;
    bool seen;
    mesh.layerBBoxMinMax(mn, mx, seen);
    assert(!seen, "an empty layer must not report a bounding box");

    mesh.vertices = [
        Vec3(1.0f, 1.5f, -1.25f),
        Vec3(5.0f, 2.5f, -0.75f),
        Vec3(4.0f, 2.0f, -1.0f),
    ];
    mesh.resetSelection();
    mesh.selectVertex(2);
    mesh.layerBBoxMinMax(mn, mx, seen);
    assert(seen && mn == Vec3(1.0f, 1.5f, -1.25f) &&
           mx == Vec3(5.0f, 2.5f, -0.75f),
        "layerBBoxMinMax used the selected vertex instead of all layer vertices");
}
