module retopology_dot_cull;

import math : Vec3, cross, dot, faceNormalFirst3, matrixMirrorsWinding;
import mesh : Mesh, MeshKey, MeshTermTopology;
import mesh_dirty : MeshDirtyKey, MeshTermGeomEpoch;
import camera_stamp : CameraStamp;

// The base-dot cull of the retopology display (task 8600, plan §10.5): a
// vertex dot is dropped when every visible polygon around it faces away from
// the eye (captured: facing is per eye, by screen winding). One pass over the
// faces in index order — the face upload's walk, its hidden-face skip and its
// degeneracy test on the LOCAL corners — each voting on its corners with the
// facing of its MODEL-TRANSFORMED first three corners, signed by the model's
// determinant so a mirrored item culls exactly the polygons the fill culls
// (`FacePass.mirrored` flips the GL front face). The answer is in compacted
// vertex-VBO SLOTS, walked with the upload's hidden-vertex skip.

/// Where the eye is, for the facing test: orthographic ⇒ the direction
/// toward the viewer; perspective ⇒ the eye point.
struct CullEye {
    bool ortho;
    Vec3 toViewer;
    Vec3 eye;
}

/// The eye of a camera given its column-major `view` / `proj` and eye point.
CullEye cullEyeOf(const ref float[16] view, const ref float[16] proj, Vec3 eye)
    @safe pure nothrow @nogc
{
    CullEye e;
    e.ortho    = proj[15] != 0.0f;
    e.toViewer = Vec3(view[2], view[6], view[10]);
    e.eye      = eye;
    return e;
}

/// The base dots to draw: VBO slots of the non-hidden vertices, in upload
/// order, minus those whose every voting polygon faces away. `slotCount` is
/// the number of slots the walk assigned (the vertex VBO's length when it was
/// uploaded from the same mesh).
struct DotList {
    uint[] slots;
    uint   slotCount;
}

/// See the module comment. `vpos` are the drawn positions (same length as
/// `mesh.vertices`), `model` the item's draw matrix.
DotList visibleDots(ref const Mesh mesh, const(Vec3)[] vpos,
                    const ref float[16] model, CullEye eye)
{
    immutable size_t n = mesh.vertices.length;
    assert(vpos.length == n, "visibleDots: positions do not match the mesh");
    auto voted = new bool[](n);
    auto front = new bool[](n);
    immutable float sign = matrixMirrorsWinding(model) ? -1.0f : 1.0f;

    Vec3 xf(Vec3 p) {
        return Vec3(model[0] * p.x + model[4] * p.y + model[8]  * p.z + model[12],
                    model[1] * p.x + model[5] * p.y + model[9]  * p.z + model[13],
                    model[2] * p.x + model[6] * p.y + model[10] * p.z + model[14]);
    }

    foreach (fi, face; mesh.faces) {
        if (face.length < 3 || mesh.isFaceHidden(fi)) continue;
        bool degenerate;
        faceNormalFirst3(vpos[face[0]], vpos[face[1]], vpos[face[2]], degenerate);
        if (degenerate) continue;
        immutable Vec3 p0 = xf(vpos[face[0]]);
        immutable Vec3 c = cross(xf(vpos[face[1]]) - p0, xf(vpos[face[2]]) - p0);
        immutable Vec3 toward = eye.ortho ? eye.toViewer : eye.eye - p0;
        immutable bool faces = sign * dot(c, toward) > 0.0f;
        foreach (v; face) {
            voted[v] = true;
            front[v] = front[v] || faces;
        }
    }

    DotList o;
    uint slot = 0;
    foreach (vi; 0 .. n) {
        if (mesh.isVertexHidden(vi)) continue;
        if (!voted[vi] || front[vi]) o.slots ~= slot;
        ++slot;
    }
    o.slotCount = slot;
    return o;
}

/// Freshness of one cached `DotList`: the face set and the positions (a
/// counter AND the bus epoch — `mesh_dirty`'s recipe), the hide state (the
/// display epoch, the only watcher carrying visibility), the camera and the
/// item's model matrix, compared element-wise.
struct DotCullKey {
    MeshKey!(MeshTermTopology, MeshTermGeomEpoch) mesh;
    MeshDirtyKey display;
    CameraStamp  camera;
    float[16]    model = 0;

    bool matches(ref const Mesh m, ulong displayEpoch,
                 const ref float[16] view, const ref float[16] proj,
                 const ref float[16] itemModel) const {
        return mesh.matches(m)
            && display.matches(cast(size_t)&m, displayEpoch)
            && !camera.changed(view, proj)
            && model == itemModel;
    }

    void stamp(ref const Mesh m, ulong displayEpoch,
               const ref float[16] view, const ref float[16] proj,
               const ref float[16] itemModel) {
        mesh.stamp(m);
        display.stamp(cast(size_t)&m, displayEpoch);
        camera.update(view, proj);
        model = itemModel;
    }
}
