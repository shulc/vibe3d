module mesh_bbox;

import math : Vec3;
import mesh : Mesh;

/// Bounding box of the layer geometry in mesh-local coordinates. Selection
/// and edit mode deliberately do not participate. `seen` is false only when
/// the mesh has no vertices.
void layerBBoxMinMax(const ref Mesh mesh,
                     out Vec3 mn, out Vec3 mx, out bool seen) {
    mn = Vec3(float.infinity, float.infinity, float.infinity);
    mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
    seen = false;
    foreach (v; mesh.vertices) {
        if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
        if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
        if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
        seen = true;
    }
}

version (unittest) private void byValueGateAnchor() {}
