module bvh_pick;

import bvh.c;
import math : Vec3, Viewport, screenRay, screenPointToRay, cross;
import mesh : Mesh, GpuMesh;
import perf_probe : g_perf, Cat, g_fc;

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

/// Result of a single-point BVH surface raycast — richer than pickFace's
/// bare face index: the world-space hit point + surface normal + BVH
/// triangle bookkeeping, for consumers that need the actual surface point
/// rather than just which face was hit (the CONS stage's background-mesh
/// raycast, source/toolpipe/stages/constrain.d; topology-pen P0). Every
/// field carries an explicit default — `Vec3.init`/`float.init` is NaN in
/// this codebase's convention, and a struct literal default must never be
/// mistaken for a real hit.
struct SurfaceHit {
    bool     hit;
    int      face   = -1;
    Vec3     point  = Vec3(0, 0, 0);
    Vec3     normal = Vec3(0, 1, 0);
    float[2] bary   = [0, 0];   // dbvh_hit_t (u, v) at the hit triangle
    int      tri    = -1;       // raw BVH triangle index (debugging only)
    float    t      = float.infinity;
}

/// Single-mesh BVH cache. App.d holds one instance for the active mesh.
///
/// Holds TWO independent BVH caches under one class:
///   * `_handle`/`_uploadVersion`/`_meshAddr`/`_triToFace` — the original
///     face-pick cache, keyed on `GpuMesh.uploadVersion`. Exercised ONLY by
///     `pickFace`. UNCHANGED by the P0 surface-pick addition below (a
///     pre-existing unit test asserts `_uploadVersion` by name — see
///     bottom of this file) — byte-identical path, byte-identical field.
///   * `_surfHandle`/`_surfVersionKey`/`_surfMeshAddr`/`_surfTriToFace` —
///     the NEW surface-pick cache (`pickSurface`/`pickSurfaceRay`), keyed
///     on a caller-supplied `ulong` version (a background mesh may never
///     be GPU-uploaded, so it can't key on `uploadVersion` — see
///     doc/cons_constraint_plan-adjacent topology-pen P0 plan, risk R3).
/// The two caches are deliberately NOT unified: a single BvhPick instance
/// that mixed both key domains could thrash (each call evicting the
/// other's build) if ever used for both purposes. In practice every call
/// site uses one instance for exactly one purpose (app.d's global
/// `bvhPick` only calls `pickFace`; the CONS stage's per-background-layer
/// instances only call `pickSurface`), so the split costs nothing today
/// and removes any risk of the two caches interacting.
class BvhPick {
private:
    dbvh_t* _handle;
    ulong   _uploadVersion;
    size_t  _meshAddr;
    uint[]  _triToFace;   // _triToFace[bvhTriIndex] = cage face index

    // --- Surface-pick cache (pickSurface/pickSurfaceRay) — see class doc.
    dbvh_t* _surfHandle;
    ulong   _surfVersionKey = ulong.max;
    size_t  _surfMeshAddr;
    uint[]  _surfTriToFace;

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

    /// Free the SURFACE-pick BVH handle and reset ITS cache key. Kept
    /// separate from `invalidate()` (which only ever touches the pickFace
    /// fields) so the two caches' lifetimes stay independently reviewable.
    private void invalidateSurface() @nogc nothrow {
        if (_surfHandle !is null) {
            dbvh_free(_surfHandle);
            _surfHandle = null;
        }
        _surfVersionKey = ulong.max;
        _surfMeshAddr   = 0;
    }

    ~this() { invalidate(); invalidateSurface(); }

    /// Single-point face pick via BVH ray-cast. Returns the cage face index
    /// (≥0) or -1 on miss / empty mesh.
    ///
    /// sourceMesh is the mesh the GPU rasterized (subpatch preview when
    /// active, cage otherwise). The BVH is rebuilt lazily when
    /// (gpu.uploadVersion, &sourceMesh) diverges from the cached key.
    int pickFace(int mx, int my, const ref Viewport vp,
                 const ref Mesh sourceMesh, const ref GpuMesh gpu)
    {
        auto z = g_perf.scope_(Cat.hoverPick);
        g_fc.bumpHoverPick();
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

    /// Single-point surface raycast given an EXPLICIT world-space ray — the
    /// world-space counterpart to `pickFace`'s screen-space pick, returning
    /// the hit point/normal rather than just the face index. Used by the
    /// CONS stage's background-mesh projection (topology-pen P0) — one
    /// `BvhPick` instance per background layer, keyed by mesh address.
    ///
    /// The surface BVH is rebuilt lazily when (`sourceMesh.mutationVersion`,
    /// `&sourceMesh`) diverges from the cached key — `mutationVersion` (not
    /// `GpuMesh.uploadVersion`, see `pickFace`) because a background layer's
    /// mesh may never be GPU-uploaded (headless tests, `/api/surface-raycast`
    /// fixtures). `gpu` is OPTIONAL: null (the common case for a raw
    /// background mesh) means "1:1 cage face map"; a non-null GpuMesh maps
    /// through `faceOriginGpu` exactly like `pickFace`'s subpatch-preview
    /// path, reserved for a future phase.
    ///
    /// Returns false (and leaves `result` at its default) on a miss, an
    /// empty mesh, or a degenerate ray.
    bool pickSurfaceRay(Vec3 org, Vec3 dir, const ref Mesh sourceMesh,
                        out SurfaceHit result, const(GpuMesh)* gpu = null)
    {
        auto z = g_perf.scope_(Cat.hoverPick);
        g_fc.bumpHoverPick();
        ulong  versionKey = sourceMesh.mutationVersion;
        size_t srcAddr    = cast(size_t)&sourceMesh;
        if (_surfHandle is null
            || _surfVersionKey != versionKey
            || _surfMeshAddr   != srcAddr)
        {
            rebuildSurface(sourceMesh, gpu, versionKey);
        }
        if (_surfHandle is null) return false;

        float[3] o = [org.x, org.y, org.z];
        float[3] d = [dir.x, dir.y, dir.z];
        dbvh_hit_t hit = dbvh_raycast(_surfHandle, o.ptr, d.ptr, 1e-4f, float.max);
        if (!hit.hit) return false;
        if (hit.tri >= _surfTriToFace.length) return false;

        result.hit  = true;
        result.face = cast(int)_surfTriToFace[hit.tri];
        result.tri  = cast(int)hit.tri;
        result.t    = hit.t;
        result.bary = [hit.u, hit.v];
        result.point = org + dir * hit.t;

        // Normal from the hit triangle's fan (face[0], face[i], face[i+1]) —
        // the SAME triangulation rebuildSurface used to build the BVH, so
        // this is exactly the geometric normal of the planar fan triangle
        // (equals the face normal for a planar polygon).
        if (result.face >= 0 && result.face < cast(int)sourceMesh.faces.length) {
            auto face = sourceMesh.faces[result.face];
            if (face.length >= 3) {
                Vec3 a = sourceMesh.vertices[face[0]];
                Vec3 b = sourceMesh.vertices[face[1]];
                Vec3 c = sourceMesh.vertices[face[2]];
                Vec3 n = cross(b - a, c - a);
                float len = n.length;
                result.normal = (len > 1e-12f) ? n * (1.0f / len) : Vec3(0, 1, 0);
            }
        }
        return true;
    }

    /// Screen-space convenience wrapper: builds the ray via
    /// `screenPointToRay` (pixel-center convention, matching `pickFace`)
    /// then delegates to `pickSurfaceRay`.
    bool pickSurface(int mx, int my, const ref Viewport vp,
                     const ref Mesh sourceMesh, out SurfaceHit result,
                     const(GpuMesh)* gpu = null)
    {
        Vec3 org, dir;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, org, dir);
        return pickSurfaceRay(org, dir, sourceMesh, result, gpu);
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

    // Surface-pick rebuild — mirrors `rebuild()` above exactly (same fan
    // triangulation, same faceOriginGpu indirection when `gpu` is supplied)
    // but writes the SEPARATE `_surf*` fields and accepts a caller-supplied
    // `versionKey` instead of hardcoding `gpu.uploadVersion` (a background
    // mesh may never be GPU-uploaded — see `pickSurfaceRay`'s doc comment).
    // Duplicated rather than shared with `rebuild()` so `pickFace`'s path
    // stays byte-identical with zero risk of the two caches interacting
    // (REV-3 of the topology-pen P0 plan).
    void rebuildSurface(const ref Mesh sourceMesh, const(GpuMesh)* gpu,
                        ulong versionKey)
    {
        invalidateSurface();

        uint triCount = 0;
        foreach (face; sourceMesh.faces) {
            if (face.length >= 3)
                triCount += cast(uint)(face.length - 2);
        }
        if (triCount == 0 || sourceMesh.vertices.length == 0) return;

        float[] verts = new float[](sourceMesh.vertices.length * 3);
        foreach (vi, v; sourceMesh.vertices) {
            verts[vi * 3 + 0] = v.x;
            verts[vi * 3 + 1] = v.y;
            verts[vi * 3 + 2] = v.z;
        }

        uint[] indices = new uint[](triCount * 3);
        _surfTriToFace  = new uint[](triCount);
        uint ti = 0;
        foreach (fi, face; sourceMesh.faces) {
            if (face.length < 3) continue;
            uint i0 = face[0];
            uint cageFace;
            if (gpu !is null && gpu.faceOriginGpu.length > 0 && fi < gpu.faceOriginGpu.length)
                cageFace = gpu.faceOriginGpu[fi];
            else
                cageFace = cast(uint)fi;

            for (uint i = 1; i + 1 < face.length; i++) {
                indices[ti * 3 + 0] = i0;
                indices[ti * 3 + 1] = face[i];
                indices[ti * 3 + 2] = face[i + 1];
                _surfTriToFace[ti]  = cageFace;
                ++ti;
            }
        }

        int nv = cast(int)sourceMesh.vertices.length;
        int nt = cast(int)ti;
        _surfHandle = dbvh_build(verts.ptr, nv, indices.ptr, nt);
        if (_surfHandle !is null) {
            _surfVersionKey = versionKey;
            _surfMeshAddr   = cast(size_t)&sourceMesh;
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

// ---------------------------------------------------------------------------
// P0 (topology-pen) unit tests: pickSurfaceRay / pickSurface.
// ---------------------------------------------------------------------------

unittest {
    // Down-ray onto a +Y-facing unit quad hits the centre: point ≈ (0,0,0),
    // normal ≈ (0,1,0), face == 0, t ≈ 5.
    import std.math : fabs;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    // Wound so the fan (face[0],face[1],face[2]) = (v0,v3,v2) gives +Y
    // (same winding convention as tests/test_constrain_projection.d's bg plane).
    src.faces = [ cast(uint[])[0, 3, 2, 1] ];

    auto pick = new BvhPick();
    SurfaceHit hit;
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, hit);
    assert(ok && hit.hit, "expected a surface hit");
    assert(hit.face == 0, "expected face 0");
    assert(fabs(hit.point.x) < 1e-4f, "point.x");
    assert(fabs(hit.point.y) < 1e-4f, "point.y");
    assert(fabs(hit.point.z) < 1e-4f, "point.z");
    assert(fabs(hit.normal.x) < 1e-4f,       "normal.x");
    assert(fabs(hit.normal.y - 1.0f) < 1e-4f, "normal.y");
    assert(fabs(hit.normal.z) < 1e-4f,       "normal.z");
    assert(fabs(hit.t - 5.0f) < 1e-4f, "t");
}

unittest {
    // pickSurface's screen-space convenience wrapper agrees with
    // pickSurfaceRay for the same camera/pixel (mirrors the pickFace
    // Phase-1 unit test's camera setup).
    import std.math : PI, fabs;
    import math : lookAt, perspectiveMatrix;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 3, 2, 1] ];

    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    auto pick = new BvhPick();
    SurfaceHit hit;
    bool ok = pick.pickSurface(100, 100, vp, src, hit);
    assert(ok && hit.hit, "expected a surface hit at screen centre");
    assert(hit.face == 0, "expected face 0");
    assert(fabs(hit.point.y) < 1e-3f, "expected the hit to land on the Y=0 plane");
}

unittest {
    // A version bump (mutationVersion) forces a rebuild — the surface-pick
    // cache's OWN key, independent of pickFace's uploadVersion (REV-3: the
    // two caches must never alias).
    import std.math : fabs;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 3, 2, 1] ];

    auto pick = new BvhPick();
    SurfaceHit hit1;
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, hit1));
    assert(hit1.face == 0);

    // Move the quad up to Y=2 and bump mutationVersion — a stale cache
    // would still report the OLD (Y=0) intersection point.
    foreach (ref v; src.vertices) v.y += 2.0f;
    src.mutationVersion++;

    SurfaceHit hit2;
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, hit2));
    assert(fabs(hit2.point.y - 2.0f) < 1e-4f,
        "surface-pick cache should have rebuilt after mutationVersion bump");
}

unittest {
    // A miss (ray pointed away from the surface) returns false and leaves
    // `hit` at its default (hit == false).
    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 3, 2, 1] ];

    auto pick = new BvhPick();
    SurfaceHit hit;
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, 1, 0), src, hit); // away from the quad
    assert(!ok, "expected a miss");
    assert(!hit.hit, "SurfaceHit.hit must stay false on a miss");
}

unittest {
    // REV-3 non-aliasing guarantee, exercised directly (not just by
    // reasoning about separate fields): using pickSurfaceRay on an
    // instance does not perturb that SAME instance's pickFace cache — the
    // pre-existing Phase-1 pickFace behaviour (including the
    // `_uploadVersion` field the original unit test asserts by name)
    // stays byte-identical.
    import std.conv : to;
    import std.math : PI;
    import math : lookAt, perspectiveMatrix;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 1, 2, 3] ];

    GpuMesh gpu;
    gpu.uploadVersion = 1;

    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    auto pick = new BvhPick();

    // Exercise the surface-pick cache FIRST, on the same instance...
    SurfaceHit hit;
    pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, hit);

    // ...then pickFace must still behave exactly as the pre-existing unit
    // test above: hits face 0, and _uploadVersion tracks gpu.uploadVersion.
    int face = pick.pickFace(100, 100, vp, src, gpu);
    assert(face == 0, "expected face 0, got " ~ face.to!string);
    gpu.uploadVersion = 2;
    int face2 = pick.pickFace(100, 100, vp, src, gpu);
    assert(face2 == 0,               "face after version bump");
    assert(pick._uploadVersion == 2, "BVH should have rebuilt on version bump");
}
