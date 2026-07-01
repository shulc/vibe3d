module bvh_pick;

import bvh.c;
import math : Vec3, Viewport, screenRay, screenPointToRay;
import mesh : Mesh, GpuMesh;

// ---------------------------------------------------------------------------
// bvh_pick — CPU face picking via a nanort BVH ray-cast.
//
// Replaces the GPU face ID-buffer re-render (gpu_select.d) for single-point
// face picks. The BVH is built once per (uploadVersion, source-mesh-address)
// pair — the same key the GPU picker's face slot uses (gpu_select.d:31) —
// and shared across all viewports; only the ray is per-viewport.
//
// Build geometry: the identical v0 fan the GPU rasterizes (face[0], face[i],
// face[i+1]; mesh.d:11893-11897). Source mesh = subpatch preview mesh when
// a preview is active; cage mesh otherwise.
//
// Pick invariant: equivalent to GPU face pick for any (mesh, camera, pixel)
// where the nearest visible face is unambiguous (no coincident/coplanar tie).
// ---------------------------------------------------------------------------

/// Single-mesh BVH cache. App.d holds one instance for the active mesh.
class BvhPick {
private:
    dbvh_t* _handle;
    ulong   _uploadVersion;
    size_t  _meshAddr;
    uint[]  _triToFace;   // _triToFace[bvhTriIndex] = cage face index

public:
    /// Free the BVH handle and reset the cache key. Called automatically on
    /// rebuild (key mismatch) and in the destructor.
    void invalidate() @nogc nothrow {
        if (_handle !is null) {
            dbvh_free(_handle);
            _handle = null;
        }
        _uploadVersion = ulong.max;
        _meshAddr      = 0;
    }

    ~this() { invalidate(); }

    /// Single-point face pick via BVH ray-cast. Returns the cage face index
    /// (≥0) or -1 on miss / empty mesh.
    ///
    /// sourceMesh is the mesh the GPU rasterized (subpatch preview when
    /// active, cage otherwise). The BVH is rebuilt lazily when
    /// (gpu.uploadVersion, &sourceMesh) diverges from the cached key.
    int pickFace(int mx, int my, const ref Viewport vp,
                 const ref Mesh sourceMesh, const ref GpuMesh gpu)
    {
        size_t srcAddr = cast(size_t)&sourceMesh;
        if (_handle is null
            || _uploadVersion != gpu.uploadVersion
            || _meshAddr      != srcAddr)
        {
            rebuild(sourceMesh, gpu);
        }
        if (_handle is null) return -1;

        Vec3 bvhOrig, d;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, bvhOrig, d);
        float[3] org = [bvhOrig.x, bvhOrig.y, bvhOrig.z];
        float[3] dir = [d.x, d.y, d.z];

        dbvh_hit_t hit = dbvh_raycast(_handle, org.ptr, dir.ptr, 1e-4f, float.max);
        if (!hit.hit) return -1;
        if (hit.tri >= _triToFace.length) return -1;
        return cast(int)_triToFace[hit.tri];
    }

private:
    void rebuild(const ref Mesh sourceMesh, const ref GpuMesh gpu) {
        invalidate();

        // Count triangles produced by fan triangulation.
        uint triCount = 0;
        foreach (face; sourceMesh.faces) {
            if (face.length >= 3)
                triCount += cast(uint)(face.length - 2);
        }
        if (triCount == 0 || sourceMesh.vertices.length == 0) return;

        // Flat vertex array (XYZ per vertex).
        float[] verts = new float[](sourceMesh.vertices.length * 3);
        foreach (vi, v; sourceMesh.vertices) {
            verts[vi * 3 + 0] = v.x;
            verts[vi * 3 + 1] = v.y;
            verts[vi * 3 + 2] = v.z;
        }

        // Fan-triangulate each face from face[0] — identical to mesh.d:11893-11897.
        // _triToFace[t] maps BVH triangle t to cage face index.
        uint[] indices = new uint[](triCount * 3);
        _triToFace     = new uint[](triCount);
        uint ti = 0;
        foreach (fi, face; sourceMesh.faces) {
            if (face.length < 3) continue;
            uint i0 = face[0];
            // Cage face index: preview mode uses faceOriginGpu; cage mode is 1:1.
            uint cageFace;
            if (gpu.faceOriginGpu.length > 0 && fi < gpu.faceOriginGpu.length)
                cageFace = gpu.faceOriginGpu[fi];
            else
                cageFace = cast(uint)fi;

            for (uint i = 1; i + 1 < face.length; i++) {
                indices[ti * 3 + 0] = i0;
                indices[ti * 3 + 1] = face[i];
                indices[ti * 3 + 2] = face[i + 1];
                _triToFace[ti]      = cageFace;
                ++ti;
            }
        }

        int nv = cast(int)sourceMesh.vertices.length;
        int nt = cast(int)ti;
        _handle = dbvh_build(verts.ptr, nv, indices.ptr, nt);
        if (_handle !is null) {
            _uploadVersion = gpu.uploadVersion;
            _meshAddr      = cast(size_t)&sourceMesh;
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests (run via `dub test --config=modeling`)
// ---------------------------------------------------------------------------

unittest {
    // Phase 0 link smoke: raw dbvh_build + raycast with no Mesh/Viewport.
    float[9] v  = [0f, 0f, 0f,  1f, 0f, 0f,  0f, 1f, 0f];
    uint[3]  ix = [0, 1, 2];
    dbvh_t* bvh = dbvh_build(v.ptr, 3, ix.ptr, 1);
    assert(bvh !is null, "dbvh_build returned null");

    float[3] org     = [0.25f, 0.25f, 1.0f];
    float[3] hitDir  = [0f, 0f, -1f];
    float[3] missDir = [0f, 0f,  1f];   // away from the triangle

    dbvh_hit_t h = dbvh_raycast(bvh, org.ptr, hitDir.ptr, 0f, float.max);
    assert(h.hit == 1,  "expected a hit");
    assert(h.tri == 0,  "expected tri 0");

    dbvh_hit_t m = dbvh_raycast(bvh, org.ptr, missDir.ptr, 0f, float.max);
    assert(m.hit == 0,  "expected a miss");

    dbvh_free(bvh);
}

unittest {
    // Phase 1 unit: BvhPick on a single-quad mesh, hitting the face and
    // verifying the cage index.  Also tests that a version bump triggers a
    // rebuild.
    import std.conv : to;
    import std.math : PI;
    import math : lookAt, perspectiveMatrix;

    // One quad face: vertices in the XZ plane, fan = 2 triangles.
    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 1, 2, 3] ];

    // GPU metadata: cage mode (faceOriginGpu empty), uploadVersion = 1.
    GpuMesh gpu;
    gpu.uploadVersion = 1;

    // Camera looking straight down at the quad from Y = 5.
    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(
        45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    auto pick = new BvhPick();

    // Pick the screen centre — should hit face 0.
    int face = pick.pickFace(100, 100, vp, src, gpu);
    assert(face == 0, "expected face 0, got " ~ face.to!string);

    // Rebuild-on-version: bump uploadVersion — cache should rebuild.
    gpu.uploadVersion = 2;
    int face2 = pick.pickFace(100, 100, vp, src, gpu);
    assert(face2 == 0,               "face after version bump");
    assert(pick._uploadVersion == 2, "BVH should have rebuilt on version bump");
}
