module bvh_pick;

import bvh.c;
import math : Vec3, Viewport, screenRay, screenPointToRay, cross, ModelSpace;
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
//
// Task 0617: the BVH is built from `sourceMesh` verbatim — i.e. it stays in
// LOCAL space and is NEVER invalidated by a layer's item transform. Every
// entry point below takes a REQUIRED `ModelSpace` and transforms the RAY
// into local space at cast time instead (doc/picking_item_transform_plan.md
// §1.2: rebuilding the BVH on every transform change would cost a fresh
// O(V+T) allocation per edit — transforming a 2-vector ray costs neither).
// This module must NOT import `document.d` (it would be the only reason to)
// — `ModelSpace` lives in `math.d`, which both this module and `document.d`
// already import, so no new dependency is needed. Cache keys
// (`_uploadVersion`/`_meshAddr`, `_surfVersionKey`/`_surfMeshAddr`) are
// UNCHANGED by this — that is the point of transforming the query instead of
// the cache.
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
                 const ref Mesh sourceMesh, const ref GpuMesh gpu,
                 const ModelSpace ms)
    {
        auto z = g_perf.scope_(Cat.hoverPick);
        g_fc.bumpHoverPick();
        // R2, checked BEFORE the rebuild below (matching `pickSurfaceRay`'s
        // ordering) — a singular M has no local ray, so there is no point
        // paying for a BVH rebuild just to discard its result two lines
        // later.
        if (!ms.invertible) return -1;

        size_t srcAddr = cast(size_t)&sourceMesh;
        if (_handle is null
            || _uploadVersion != gpu.uploadVersion
            || _meshAddr      != srcAddr)
        {
            rebuild(sourceMesh, gpu);
        }
        if (_handle is null) return -1;

        // Task 0617 §3.3 — build the ray in WORLD space from the real `vp`
        // BEFORE any transform. `screenPointToRay`/`screenRay` derive the
        // world ray direction by treating the view matrix's upper-left 3x3
        // as its OWN inverse (transpose-as-inverse), which is only valid for
        // an orthonormal rotation — a `view*M` with scale/shear breaks that
        // silently. So the ray is built here, against the un-composed `vp`,
        // and only THEN moved into the BVH's local space.
        Vec3 bvhOrig, d;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, bvhOrig, d);

        // §3.4 — `dirLocal` is deliberately left UN-NORMALIZED: normalizing
        // would corrupt the ray parameter as a world distance (irrelevant to
        // `pickFace`'s return value, but this mirrors `pickSurfaceRay` below
        // where it matters, and keeps the two paths symmetric).
        Vec3 orgLocal = ms.isIdentity ? bvhOrig : ms.toLocalPoint(bvhOrig);
        Vec3 dirLocal = ms.isIdentity ? d       : ms.toLocalDir(d);
        float[3] org = [orgLocal.x, orgLocal.y, orgLocal.z];
        float[3] dir = [dirLocal.x, dirLocal.y, dirLocal.z];

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
                        const ModelSpace ms,
                        out SurfaceHit result, const(GpuMesh)* gpu = null)
    {
        auto z = g_perf.scope_(Cat.hoverPick);
        g_fc.bumpHoverPick();
        if (!ms.invertible) return false; // R2 — a singular M has no local ray

        ulong  versionKey = sourceMesh.mutationVersion;
        size_t srcAddr    = cast(size_t)&sourceMesh;
        if (_surfHandle is null
            || _surfVersionKey != versionKey
            || _surfMeshAddr   != srcAddr)
        {
            rebuildSurface(sourceMesh, gpu, versionKey);
        }
        if (_surfHandle is null) return false;

        // §3.4 — cast in LOCAL space; `dirLocal` stays UN-NORMALIZED so
        // `hit.t` keeps meaning a WORLD distance. `constrain.d`'s CONS stage
        // picks the globally nearest hit across background layers by
        // comparing `t` (constrain.d:146) — renormalizing here would
        // silently bias that compare toward whichever layer has the
        // smaller scale.
        Vec3 orgLocal = ms.isIdentity ? org : ms.toLocalPoint(org);
        Vec3 dirLocal = ms.isIdentity ? dir : ms.toLocalDir(dir);
        float[3] o = [orgLocal.x, orgLocal.y, orgLocal.z];
        float[3] d = [dirLocal.x, dirLocal.y, dirLocal.z];
        dbvh_hit_t hit = dbvh_raycast(_surfHandle, o.ptr, d.ptr, 1e-4f, float.max);
        if (!hit.hit) return false;
        if (hit.tri >= _surfTriToFace.length) return false;

        result.hit  = true;
        result.face = cast(int)_surfTriToFace[hit.tri];
        result.tri  = cast(int)hit.tri;
        result.t    = hit.t;   // preserved EXACTLY — see §3.4 above.
        result.bary = [hit.u, hit.v];
        // World hit point: since `t` is preserved exactly, the ORIGINAL
        // world `org`/`dir` (untouched above) give the exact world point
        // directly — no local->world remap (and its extra rounding) needed.
        result.point = org + dir * hit.t;

        // Normal from the hit triangle's fan (face[0], face[i], face[i+1]) —
        // the SAME triangulation rebuildSurface used to build the BVH.
        //
        // Computed by cross-producting the LOCAL vertices, then mapping the
        // result through `ms.toWorldNormal` (the inverse-transpose rule) —
        // NOT by transforming the vertices to world first and cross-
        // producting there. A previous version of this code did the latter,
        // reasoning it was "the normal of the triangle that is actually
        // drawn" and therefore det(M)-sign-safe by construction. That is
        // backwards: cross-producting WORLD vertices computes the WINDING
        // normal, and `cross(Ma,Mb) == det(M)*(M^-1)^T*cross(a,b)` means
        // that normal carries `det(M)`'s sign — under a mirrored M it points
        // INTO the solid. `toWorldNormal` is exactly the inverse-transpose
        // rule that strips that sign back out: `dot((M^-1)^T n, M v) ==
        // dot(n, v)` holds for ANY invertible M, so this is the one
        // construction that is correct regardless of mirroring. See
        // `ModelSpace.toWorldNormal`'s doc comment in math.d.
        if (result.face >= 0 && result.face < cast(int)sourceMesh.faces.length) {
            auto face = sourceMesh.faces[result.face];
            if (face.length >= 3) {
                Vec3 a = sourceMesh.vertices[face[0]];
                Vec3 b = sourceMesh.vertices[face[1]];
                Vec3 c = sourceMesh.vertices[face[2]];
                Vec3 nLocal = cross(b - a, c - a);
                Vec3 n = ms.isIdentity ? nLocal : ms.toWorldNormal(nLocal);
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
                     const ref Mesh sourceMesh, const ModelSpace ms,
                     out SurfaceHit result, const(GpuMesh)* gpu = null)
    {
        // §3.3 — ray built in WORLD space from the real `vp`; pickSurfaceRay
        // does the local-space transform.
        Vec3 org, dir;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, org, dir);
        return pickSurfaceRay(org, dir, sourceMesh, ms, result, gpu);
    }

private:
    // Hide (task 0613 S4, doc/hide_geometry_plan.md §6 S4.1) — a hidden face
    // contributes no triangles to EITHER BVH. Named rather than inlined for
    // the same reason mesh_gpu.d names its skip predicates: the count pass and
    // the fill pass must agree in all FOUR loops below (two per BVH), and a
    // pair that disagrees allocates one array size and writes another.
    //
    // `sourceMesh` is the subpatch preview when one is active, and the preview
    // mesh carries Hide bits stamped from the cage (subpatch_osd.d, S3) — so
    // this reads the right plane on both paths with no extra parameter, the
    // same property `GpuMesh.upload` relies on.
    //
    // No cache-key change is needed: `pickFace` keys on `gpu.uploadVersion`
    // (bumped by the re-upload a hide forces) and `pickSurfaceRay` on
    // `sourceMesh.mutationVersion` (bumped by `commitChange` inside every Hide
    // writer). Both move on a hide, so both rebuild.
    static bool hideSkipFace(const ref Mesh m, size_t fi) {
        return m.isFaceHidden(fi);
    }

    void rebuild(const ref Mesh sourceMesh, const ref GpuMesh gpu) {
        invalidate();

        // Count triangles produced by fan triangulation.
        uint triCount = 0;
        foreach (fi, face; sourceMesh.faces) {
            if (face.length >= 3 && !hideSkipFace(sourceMesh, fi))
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
            if (face.length < 3 || hideSkipFace(sourceMesh, fi)) continue;
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
        foreach (fi, face; sourceMesh.faces) {
            if (face.length >= 3 && !hideSkipFace(sourceMesh, fi))
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
            if (face.length < 3 || hideSkipFace(sourceMesh, fi)) continue;
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
    int face = pick.pickFace(100, 100, vp, src, gpu, ModelSpace.world());
    assert(face == 0, "expected face 0, got " ~ face.to!string);

    // Rebuild-on-version: bump uploadVersion — cache should rebuild.
    gpu.uploadVersion = 2;
    int face2 = pick.pickFace(100, 100, vp, src, gpu, ModelSpace.world());
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
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hit);
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
    bool ok = pick.pickSurface(100, 100, vp, src, ModelSpace.world(), hit);
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
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hit1));
    assert(hit1.face == 0);

    // Move the quad up to Y=2 and bump mutationVersion — a stale cache
    // would still report the OLD (Y=0) intersection point.
    foreach (ref v; src.vertices) v.y += 2.0f;
    src.mutationVersion++;

    SurfaceHit hit2;
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hit2));
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
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, 1, 0), src, ModelSpace.world(), hit); // away from the quad
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
    pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hit);

    // ...then pickFace must still behave exactly as the pre-existing unit
    // test above: hits face 0, and _uploadVersion tracks gpu.uploadVersion.
    int face = pick.pickFace(100, 100, vp, src, gpu, ModelSpace.world());
    assert(face == 0, "expected face 0, got " ~ face.to!string);
    gpu.uploadVersion = 2;
    int face2 = pick.pickFace(100, 100, vp, src, gpu, ModelSpace.world());
    assert(face2 == 0,               "face after version bump");
    assert(pick._uploadVersion == 2, "BVH should have rebuilt on version bump");
}

// ---------------------------------------------------------------------------
// Task 0617 unit tests (doc/picking_item_transform_plan.md, Stage 2 step 6).
// ---------------------------------------------------------------------------

unittest {
    // A translated+rotated model: the ray hits the DRAWN quad (through `ms`)
    // and misses the SAME quad's identity-pose pixel. Hand-built ModelSpace,
    // independent of `document.ItemXform.modelSpace()` (this module must not
    // import document.d — see the module header note).
    import std.math : PI;
    import math : lookAt, perspectiveMatrix, translationMatrix,
                  pivotRotationMatrix, matMul4, projectToWindow;

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

    // M = T(1.5,0,0) * Ry(25deg): |T| = 1.5 exceeds the quad's circumscribed
    // radius (sqrt(2) ~= 1.414 for a local half-diagonal of (1,0,1)), so the
    // drawn quad's footprint cannot cover the world origin under ANY
    // rotation about Y -- guaranteeing the identity-pose pixel (world
    // origin, which is where screen centre (100,100) points for this
    // straight-down camera -- see the Phase-1 unit test above) misses.
    immutable float angle = 25.0f * PI / 180.0f;
    float[16] T    = translationMatrix(Vec3(1.5f, 0, 0));
    float[16] R    = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), angle);
    float[16] M    = matMul4(T, R);
    float[16] Rinv = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), -angle);
    float[16] Tinv = translationMatrix(Vec3(-1.5f, 0, 0));
    float[16] Minv = matMul4(Rinv, Tinv);

    ModelSpace ms;
    ms.m = M; ms.mInv = Minv; ms.isIdentity = false; ms.invertible = true;

    auto pick = new BvhPick();

    float px, py, pz;
    bool projOk = projectToWindow(Vec3(1.5f, 0, 0), vp, px, py, pz);
    assert(projOk, "the drawn quad's centre must be on-screen for this camera");

    import std.math : lround;
    int faceAtDrawn = pick.pickFace(cast(int)lround(px), cast(int)lround(py), vp, src, gpu, ms);
    assert(faceAtDrawn == 0, "a click on the DRAWN (moved) quad must hit it");

    int faceAtIdentityPixel = pick.pickFace(100, 100, vp, src, gpu, ms);
    assert(faceAtIdentityPixel == -1,
        "a click at the identity-pose pixel must NOT hit the drawn (moved) quad");
}

unittest {
    // §3.4 t-preservation: a non-uniform scale must not corrupt `hit.t`. A
    // renormalized local ray direction is exactly the bug this pins against
    // -- it would still report a hit, just with the WRONG `t`.
    //
    // The scaled axis MUST be the one the ray travels along. The ray here
    // travels along Y (org=(0,5,0), dir=(0,-1,0)); scaling X or Z leaves
    // `toLocalDir`'s output exactly (0,-1,0) either way -- un-normalized and
    // normalized agree because the ray's X/Z components are already zero,
    // so such a test cannot fail even with a normalize() bug inserted into
    // the code under test (verified by hand: inserting one leaves this
    // assertion green). Scaling Y instead makes `dirLocal` (0,-0.5,0) --
    // length 0.5, not unit -- so a normalize() bug measurably changes `t`.
    import std.math : fabs;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];
    src.faces = [ cast(uint[])[0, 3, 2, 1] ]; // +Y-facing fan (matches the P0 tests above)

    // scl=(1,2,1) about the origin pivot: the quad lies flat in the y=0
    // plane, so scaling Y leaves every vertex fixed (geometry unchanged) --
    // only the ray's local-space parameterization is affected.
    import math : pivotScaleMatrix;
    ModelSpace ms;
    ms.m    = pivotScaleMatrix(Vec3(0,0,0), 1, 2, 1);
    ms.mInv = pivotScaleMatrix(Vec3(0,0,0), 1, 0.5f, 1);
    ms.isIdentity = false;
    ms.invertible = true;

    auto pick = new BvhPick();
    SurfaceHit hit;
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ms, hit);
    assert(ok && hit.hit, "expected a surface hit through a non-uniform scale");
    // Correct: t stays the WORLD distance, 5.0 (org.y=5, dir=(0,-1,0), plane
    // at y=0). A renormalized dirLocal would instead solve
    // 2.5 + t*(-1) == 0 in local space and report t == 2.5 -- see the
    // deliberate-break note above.
    assert(fabs(hit.t - 5.0f) < 1e-4f,
        "t must stay a WORLD distance under a non-uniform scale -- a "
        ~ "renormalized local ray direction would corrupt it (would read "
        ~ "~2.5 instead of 5.0 for this fixture)");
    assert(fabs(hit.point.y) < 1e-4f, "world hit point must stay on the Y=0 plane");
}

unittest {
    // R2: a non-invertible ModelSpace (any scl component == 0) must report a
    // miss on BOTH pickFace and pickSurfaceRay rather than dividing by zero
    // or casting against a garbage local ray.
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

    ModelSpace ms;   // m/mInv are irrelevant -- `invertible` alone gates.
    ms.isIdentity = false;
    ms.invertible = false;

    auto pick = new BvhPick();
    int face = pick.pickFace(100, 100, vp, src, gpu, ms);
    assert(face == -1, "a non-invertible ModelSpace must report a pickFace miss");

    SurfaceHit hit;
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ms, hit);
    assert(!ok && !hit.hit, "a non-invertible ModelSpace must report a pickSurfaceRay miss");
}

unittest {
    // pickSurfaceRay's normal must point the true outward direction under a
    // MIRRORED ModelSpace, not the winding direction. Fixture: a horizontal
    // quad at local y=0, wound so `cross(v1-v0, v2-v0)` points -Y (straight
    // down) -- verified below at identity first. Mirroring across X alone
    // does not touch Y at all, so the physically correct answer after the
    // mirror is UNCHANGED: still -Y (mirroring a horizontal plane about a
    // vertical axis through it doesn't turn it over).
    //
    // A cross-product-of-WORLD-vertices implementation (the bug this pins)
    // gets this backwards: mirroring flips the vertices' winding as seen
    // from a fixed viewpoint even though the surface's physical facing did
    // not change, so it reports +Y instead -- exactly the "points into the
    // solid" defect. Confirmed by hand: reintroducing that computation here
    // flips this assertion to `hit.normal.y > 0.9`.
    import std.math : fabs;
    import math : pivotScaleMatrix;

    Mesh src;
    src.vertices = [
        Vec3(-1f, 0f, -1f), // 0
        Vec3( 1f, 0f, -1f), // 1
        Vec3( 1f, 0f,  1f), // 2
        Vec3(-1f, 0f,  1f), // 3
    ];
    src.faces = [ cast(uint[])[0, 1, 2, 3] ]; // local normal cross(v1-v0,v2-v0) == -Y

    // Sanity: confirm the -Y premise at identity before trusting the
    // mirrored case below.
    {
        auto pickId = new BvhPick();
        SurfaceHit hitId;
        bool okId = pickId.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src,
                                          ModelSpace.world(), hitId);
        assert(okId && hitId.hit, "fixture: identity ray must hit the quad");
        assert(hitId.normal.y < -0.9f,
            "fixture premise: this quad's normal must point -Y at identity");
    }

    // Mirror across X: m = diag(-1,1,1), self-inverse, det < 0.
    ModelSpace ms;
    ms.m          = pivotScaleMatrix(Vec3(0,0,0), -1, 1, 1);
    ms.mInv       = ms.m;
    ms.isIdentity = false;
    ms.invertible = true;
    ms.mirrored   = true;

    auto pick = new BvhPick();
    SurfaceHit hit;
    bool ok = pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ms, hit);
    assert(ok && hit.hit, "expected a surface hit through the mirrored quad");
    assert(hit.normal.y < -0.9f,
        "a mirrored ModelSpace must not flip this quad's normal: an X-only "
        ~ "mirror does not touch Y, so the true outward normal stays -Y -- "
        ~ "a world-cross-product implementation would report +Y instead");
    assert(fabs(hit.normal.x) < 1e-4f && fabs(hit.normal.z) < 1e-4f,
        "normal must stay axis-aligned on -Y for this fixture");
}

// R5 (nanort must not back-face-cull, matching gpu_select's two-sided,
// no-GL_CULL_FACE face pass) is already covered WITHOUT a mirror: the
// pre-existing Phase-1 unittest above (`src.faces = [0,1,2,3]`, camera
// straight down at eye=(0,5,0)) casts through a `-Y`-facing fan with a ray
// travelling `-Y` -- a back-face hit by construction (`dot(rayDir, normal)
// > 0`) -- and asserts `face == 0`. A dedicated "mirrored ModelSpace"
// version of this check was tried and removed: `scl.x = -1` is self-inverse
// AND the probe ray (org=(0,5,0), dir=(0,-1,0)) has zero X-component, so
// `toLocalDir`/`toLocalPoint` return it bit-identical to the un-mirrored
// case -- the local ray never sees the mirror, making that test a byte-for-
// byte duplicate of the Phase-1 case above, not an independent check. (For
// the same reason, that removed test did NOT establish that a mirrored `M`
// flips triangle winding in local space -- the local ray/geometry pairing
// mirroring would need to move is untouched by an X-only scale applied to a
// ray lying exactly on the mirror plane. `ms.mirrored` itself is not read
// anywhere on the `pickFace`/`pickSurfaceRay` path -- see §3.7/§3.8, which
// gate on it only in the LOCAL front-facing culls outside this module.)

// ---------------------------------------------------------------------------
// Task 0576 — CHARACTERISATION of the face picker's visibility rule.
//
// These two tests add no behaviour. They exist because the rule was being
// described wrongly in prose — CLAUDE.md's "Picking Strategy" section claimed
// a screen-space bounding box plus a face-normal-versus-view-direction cull,
// a path `pickFace` has not taken since the BVH picker landed. That section
// has since been rewritten off these measurements; this block is what keeps
// it honest. Any lane that wants to change what
// is selectable needs the CURRENT rule pinned as an executable fact first,
// because the two candidate rules differ in exactly the case that matters:
//
//   * a FACING term (cull by normal vs. view direction) would make a
//     back-facing face unpickable even with nothing in front of it;
//   * a DEPTH term (nearest hit along the ray) makes it unpickable only
//     while something nearer is in the way.
//
// `pickFace` has the second and not the first. That is what these pin.
// ---------------------------------------------------------------------------

unittest {
    // NO FACING TERM: winding does not affect pickability.
    //
    // One quad, one camera, two windings. The fan triangle the BVH is built
    // from is (face[0], face[1], face[2]), so reversing the index order
    // reverses the geometric normal — the fixture asserts that inversion
    // rather than assuming it. Both windings must pick.
    import std.conv : to;
    import std.math : PI;
    import math : lookAt, perspectiveMatrix, dot;

    Vec3[] quad = [
        Vec3(-1f, 0f, -1f),
        Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f),
        Vec3(-1f, 0f,  1f),
    ];

    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    static Vec3 fanNormal(in Vec3[] v, in uint[] f) {
        return cross(v[f[1]] - v[f[0]], v[f[2]] - v[f[0]]);
    }

    uint[] toEye   = [0, 3, 2, 1];   // fan normal +Y — towards an eye at +Y
    uint[] fromEye = [0, 1, 2, 3];   // fan normal -Y — away from that eye

    // Fixture self-check: the two windings really are front- and back-facing
    // with respect to THIS camera, or the test below proves nothing.
    Vec3 toEyeDir  = eye - quad[0];
    assert(dot(fanNormal(quad, toEye),   toEyeDir) > 0f,
        "fixture: the `toEye` winding must face the camera");
    assert(dot(fanNormal(quad, fromEye), toEyeDir) < 0f,
        "fixture: the `fromEye` winding must face AWAY from the camera");

    foreach (i, w; [toEye, fromEye]) {
        Mesh src;
        src.vertices = quad.dup;
        src.faces    = [w.dup];

        GpuMesh gpu;
        gpu.uploadVersion = 1;

        auto pick = new BvhPick();
        int face = pick.pickFace(100, 100, vp, src, gpu, ModelSpace.world());
        assert(face == 0,
            "pickFace has NO facing term: a face must pick from either side "
            ~ "with nothing in front of it. Winding #" ~ i.to!string
            ~ " returned " ~ face.to!string
            ~ ". If this now fails, a facing cull was introduced — and that "
            ~ "is a change to what a click selects, not a rendering change.");
    }
}

unittest {
    // THE ONLY OCCLUSION TERM IS NEAREST-HIT.
    //
    // Two quads with the SAME winding — so the facing relation to the camera
    // is identical for both and cannot explain any difference — stacked along
    // the view ray. The near one wins. Remove it and the far one becomes
    // pickable at the very same pixel: it was hidden by depth, by nothing
    // else.
    import std.conv : to;
    import std.math : PI;
    import math : lookAt, perspectiveMatrix;

    static Mesh stack(bool withNear) {
        Mesh m;
        // Far quad at y = 0 -> face index 0 in both meshes, so the assertions
        // below compare like with like.
        m.vertices = [
            Vec3(-1f, 0f, -1f), Vec3( 1f, 0f, -1f),
            Vec3( 1f, 0f,  1f), Vec3(-1f, 0f,  1f),
        ];
        m.faces = [ cast(uint[])[0, 3, 2, 1] ];
        if (withNear) {
            // Near quad at y = 2, same winding.
            m.vertices ~= [
                Vec3(-1f, 2f, -1f), Vec3( 1f, 2f, -1f),
                Vec3( 1f, 2f,  1f), Vec3(-1f, 2f,  1f),
            ];
            m.faces ~= cast(uint[])[4, 7, 6, 5];
        }
        return m;
    }

    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    GpuMesh gpu;
    gpu.uploadVersion = 1;

    Mesh both = stack(true);
    int hitBoth = (new BvhPick()).pickFace(100, 100, vp, both, gpu, ModelSpace.world());
    assert(hitBoth == 1,
        "with two same-winding quads stacked along the ray the NEAR one "
        ~ "(face 1, y=2) must win; got " ~ hitBoth.to!string);

    Mesh farOnly = stack(false);
    int hitFar = (new BvhPick()).pickFace(100, 100, vp, farOnly, gpu, ModelSpace.world());
    assert(hitFar == 0,
        "and the far quad must be pickable at the SAME pixel once nothing "
        ~ "is in front of it — proving it was hidden by DEPTH, not by its "
        ~ "orientation; got " ~ hitFar.to!string);
}
