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
// face[i+1]; see `GpuMesh.upload` / `refreshPositions` in mesh_gpu.d).
// Source mesh = subpatch preview mesh when
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
///
/// TASK 0833 — the two caches' ADDRESS terms are not equally load-bearing,
/// which is worth knowing before anyone "simplifies" either:
///   * `_meshAddr` (face pick) IS load-bearing. app.d holds ONE instance and
///     feeds it the cage, the subpatch preview mesh, or another layer's cage
///     after a primary switch — different objects that can share an
///     `uploadVersion`. Pinned by a stale-read block in
///     tests/unit/bvh_pick_test.d: delete the term and it goes red.
///   * `_surfMeshAddr` (surface pick) is redundant TODAY: its only caller,
///     `ConstrainStage`, already keys its `BvhPick[size_t]` map BY mesh
///     address (toolpipe/stages/constrain.d), so a given instance never sees
///     a second mesh. Kept, because the key belongs to the cache rather than
///     to one caller's bookkeeping — but a test for it would be asserting
///     `constrain.d`'s AA, not this cache, so none was written.
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
                import morph_target : displayPosition;
                Vec3 a = displayPosition(&sourceMesh, face[0]);
                Vec3 b = displayPosition(&sourceMesh, face[1]);
                Vec3 c = displayPosition(&sourceMesh, face[2]);
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
        g_perf.count(Cat.bvhRebuildEnter, 1);   // task 1720 — see the enum
        // Task 1540 — the construction, split out of `hoverPick`. Opened
        // BEFORE `invalidate()` so the handle teardown is inside the number
        // too: freeing the previous BVH is part of what a rebuild costs.
        auto zBvh = g_perf.scope_(Cat.bvhRebuild);
        invalidate();

        // Count triangles produced by fan triangulation.
        uint triCount = 0;
        foreach (fi, face; sourceMesh.faces) {
            if (face.length >= 3 && !hideSkipFace(sourceMesh, fi))
                triCount += cast(uint)(face.length - 2);
        }
        if (triCount == 0 || sourceMesh.vertices.length == 0) {
            // Task 1540 probe — a rebuild that WALKED the faces and then
            // built nothing. The walk is not free (measured ~383 ms at
            // n=316), so "how many faces did it walk to decide that" is the
            // whole question. Instrumented here only, not in the
            // `rebuildSurface` twin below, so the counter has one subject.
            g_perf.count(Cat.bvhAbortFaces, cast(long)sourceMesh.faces.length);
            g_perf.count(Cat.bvhAbortVerts, cast(long)sourceMesh.vertices.length);
            return;
        }

        // Flat vertex array (XYZ per vertex).
        float[] verts = new float[](sourceMesh.vertices.length * 3);
        // Task 1069 — the BVH is built from the DRAWN positions. Measured
        // (Phase 0): polygon picking follows the drawn surface, so a BVH built
        // from the base would pick a face where nothing is visible. `null`
        // when no morph target is bound, so an ordinary document builds
        // byte-identical geometry.
        const(Vec3)[] bvhSrc;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&sourceMesh);
            bvhSrc = (dv.length == sourceMesh.vertices.length)
                   ? dv : sourceMesh.vertices;
        }
        foreach (vi, v; bvhSrc) {
            verts[vi * 3 + 0] = v.x;
            verts[vi * 3 + 1] = v.y;
            verts[vi * 3 + 2] = v.z;
        }

        // Fan-triangulate each face from face[0] — identical to the fan
        // `GpuMesh.upload` rasterises (mesh_gpu.d).
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
        g_perf.count(Cat.bvhRebuildTris, nt);   // task 1540 — see the enum
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
        // Task 1069 — the BVH is built from the DRAWN positions. Measured
        // (Phase 0): polygon picking follows the drawn surface, so a BVH built
        // from the base would pick a face where nothing is visible. `null`
        // when no morph target is bound, so an ordinary document builds
        // byte-identical geometry.
        const(Vec3)[] bvhSrc;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&sourceMesh);
            bvhSrc = (dv.length == sourceMesh.vertices.length)
                   ? dv : sourceMesh.vertices;
        }
        foreach (vi, v; bvhSrc) {
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
// Unit tests (run via `dub test --config=tests`)
// ---------------------------------------------------------------------------


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
