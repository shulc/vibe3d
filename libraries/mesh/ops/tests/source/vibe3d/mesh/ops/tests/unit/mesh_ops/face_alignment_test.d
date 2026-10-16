module vibe3d.mesh.ops.tests.unit.mesh_ops.face_alignment_test;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math;
import vibe3d.mesh.contracts.mesh_scope : MeshEditScope;
import vibe3d.mesh.ops.mesh_ops.face_alignment;

// Public legacy cells moved from tests/unit/mesh_test.d (task 20262350).
// The caller batch replaces the original core chooser receiver; its scope
// matches the operation and closes before any existing assertion reads state.
private auto faceOpOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Position);
    const result = kernel(ed, args);
    ed.close();
    return result;
}

unittest {
        import std.math : abs, sqrt;
        import std.conv : to;

        // (a) Warped quad: the two z=+1 corners are pushed opposite in y,
        //     making the face genuinely non-planar.  After alignFacesByMask
        //     all 4 verts must be coplanar to within 1e-5.
        {
            Mesh m;
            m.vertices = [
                Vec3(-1.0f,  0.0f, -1.0f),   // v0
                Vec3( 1.0f,  0.0f, -1.0f),   // v1
                Vec3( 1.0f,  0.5f,  1.0f),   // v2 — pushed +y
                Vec3(-1.0f, -0.5f,  1.0f),   // v3 — pushed −y
            ];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = faceOpOnce!alignFacesByMask(m, mask);
            assert(n > 0, "alignFacesByMask warped: expected moves");

            // Recompute plane from 3 post-align verts; check the 4th.
            Vec3 a = m.vertices[0], b = m.vertices[1], c = m.vertices[2];
            Vec3 ab = b - a, ac = c - a;
            Vec3 pn = Vec3(ab.y*ac.z - ab.z*ac.y,
                           ab.z*ac.x - ab.x*ac.z,
                           ab.x*ac.y - ab.y*ac.x);
            float pnlen = sqrt(pn.x*pn.x + pn.y*pn.y + pn.z*pn.z);
            assert(pnlen > 1e-6f, "alignFacesByMask warped: degenerate post-align plane");
            pn = Vec3(pn.x / pnlen, pn.y / pnlen, pn.z / pnlen);
            Vec3 d3 = m.vertices[3] - a;
            float dist = abs(d3.x * pn.x + d3.y * pn.y + d3.z * pn.z);
            assert(dist < 1e-5f,
                "alignFacesByMask warped: 4th vert not coplanar, dist=" ~ dist.to!string);
        }

        // (b) Already-planar but TILTED quad: z = 0.3*x + 0.2*y.
        //     Kernel must return 0 and leave every vertex byte-for-byte
        //     unchanged, proving the coordinate-scaled eps absorbs the ~1e-7
        //     float residual that a naive 1e-9 threshold would mis-read as motion.
        {
            Mesh m;
            m.vertices = [
                Vec3(0.0f, 0.0f, 0.0f),    // z = 0.0
                Vec3(1.0f, 0.0f, 0.3f),    // z = 0.3
                Vec3(1.0f, 1.0f, 0.5f),    // z = 0.5
                Vec3(0.0f, 1.0f, 0.2f),    // z = 0.2
            ];
            Vec3[4] orig;
            foreach (i; 0 .. 4) orig[i] = m.vertices[i];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = faceOpOnce!alignFacesByMask(m, mask);
            assert(n == 0,
                "alignFacesByMask planar-tilted: expected no-op, got " ~ n.to!string);
            foreach (i; 0 .. 4)
                assert(m.vertices[i].x == orig[i].x
                    && m.vertices[i].y == orig[i].y
                    && m.vertices[i].z == orig[i].z,
                    "alignFacesByMask planar-tilted: vert " ~ i.to!string ~ " changed");
        }
    }
