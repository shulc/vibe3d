module surface_pick;

import bvh.c;
import math : Vec3, cross;
import vibe3d.util.spatial.spatial : Viewport, screenPointToRay, ModelSpace;
import mesh : Mesh;
import vibe3d.util.profiling.perf_probe : g_perf, Cat, g_fc;
import vibe3d.mesh.change.mesh_dirty : MeshDirtyKey, g_geomEpochs;


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
// (`_uploadVersion`/`_meshAddr`, `_surfKey`) are
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
    double   preciseT = double.infinity;
    Vec3     productRoundedPoint = Vec3(0, 0, 0);
    int      source = -1;       // `BackgroundRayPicker.nearest`: the answering source's index
}


private double triangleRayParameter(Vec3 origin, Vec3 dir, Vec3 a, Vec3 b, Vec3 c)
    pure nothrow @nogc @safe {
    double[3] e = [cast(double)b.x - a.x, cast(double)b.y - a.y, cast(double)b.z - a.z];
    double[3] f = [cast(double)c.x - a.x, cast(double)c.y - a.y, cast(double)c.z - a.z];
    double[3] n = [e[1] * f[2] - e[2] * f[1], e[2] * f[0] - e[0] * f[2], e[0] * f[1] - e[1] * f[0]];
    return ((cast(double)a.x - origin.x) * n[0] + (cast(double)a.y - origin.y) * n[1]
            + (cast(double)a.z - origin.z) * n[2]) / (dir.x * n[0] + dir.y * n[1] + dir.z * n[2]);
}

class SurfacePicker {
private:
    // --- Surface-pick cache (pickSurface/pickSurfaceRay) — see class doc.
    dbvh_t* _surfHandle;
    // TASK 1906 STAGE 2b — was `ulong _surfVersionKey = ulong.max` holding
    // `sourceMesh.mutationVersion`, plus a separate `size_t _surfMeshAddr`.
    // Both terms survive inside `MeshDirtyKey`; what changed is WHICH counter
    // the freshness half reads. See `pickSurfaceRay` for why the version was
    // the wrong one.
    MeshDirtyKey _surfKey;
    uint[]  _surfTriToFace;
    uint[3][] _surfTriVertices;

public:

    /// Free the SURFACE-pick BVH handle and reset ITS cache key. Kept
    /// separate from `invalidate()` (which only ever touches the pickFace
    /// fields) so the two caches' lifetimes stay independently reviewable.
    void invalidateSurface() @nogc nothrow {
        if (_surfHandle !is null) {
            dbvh_free(_surfHandle);
            _surfHandle = null;
        }
        _surfKey.clear();
    }

    ~this() { invalidateSurface(); }


    /// Single-point surface raycast given an EXPLICIT world-space ray — the
    /// world-space counterpart to `pickFace`'s screen-space pick, returning
    /// the hit point/normal rather than just the face index. Used by the
    /// CONS stage's background-mesh projection (topology-pen P0) — one
    /// `BvhPick` instance per background layer, keyed by mesh address.
    ///
    /// The surface BVH is rebuilt lazily when (`&sourceMesh`, its CHANGE-BUS
    /// geometry epoch) diverges from the cached key.
    ///
    /// TASK 1906 STAGE 2b — THIS KEY WAS `sourceMesh.mutationVersion`, AND
    /// THAT WAS A LIVE BUG, not a stylistic choice. An interactive gizmo
    /// Move/Rotate/Scale is version-silent on Position — `mutationVersion`
    /// does not move at the drag steps NOR at the commit (CLAUDE.md, "The
    /// exception that breaks version-keying") — and `invalidateSurface()` has
    /// no caller outside this module, so every surface consumer read the
    /// PRE-DRAG tree for the rest of the session. `mesh_dirty.g_geomEpochs` is
    /// fed by the change bus, whose `Position` class IS published on that
    /// path. It cannot key on `GpuMesh.uploadVersion` either (see `pickFace`):
    /// a background layer's mesh may never be GPU-uploaded at all (headless
    /// tests, `/api/surface-raycast` fixtures).
    /// Pinned by `tests/test_bus_surface_raycast_after_drag.d` (ARM A red on
    /// `main`, ARM B — the same displacement through `/api/transform`, which
    /// bumps the version — green on both).
    /// `gpu` is OPTIONAL: null (the common case for a raw
    /// background mesh) means "1:1 cage face map"; a non-null GpuMesh maps
    /// through `faceOriginGpu` exactly like `pickFace`'s subpatch-preview
    /// path, reserved for a future phase.
    ///
    /// Returns false (and leaves `result` at its default) on a miss, an
    /// empty mesh, or a degenerate ray.
    bool pickSurfaceRay(Vec3 org, Vec3 dir, const ref Mesh sourceMesh,
                        const ModelSpace ms,
                        out SurfaceHit result, const(uint)[] faceOrigin = null, bool productPoint = false)
    {
        auto z = g_perf.scope_(Cat.hoverPick);
        g_fc.bumpHoverPick();
        if (!ms.invertible) return false; // R2 — a singular M has no local ray

        size_t srcAddr = cast(size_t)&sourceMesh;
        ulong  epoch   = g_geomEpochs.epochFor(srcAddr);
        if (_surfHandle is null || !_surfKey.matches(srcAddr, epoch))
            rebuildSurface(sourceMesh, faceOrigin, epoch);
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
        if (productPoint) {
            import morph_preview : displayPosition;
            const corners = _surfTriVertices[hit.tri];
            result.preciseT = triangleRayParameter(orgLocal, dirLocal,
                displayPosition(&sourceMesh, corners[0]), displayPosition(&sourceMesh, corners[1]),
                displayPosition(&sourceMesh, corners[2]));
            const localProductPoint = Vec3(
                cast(float)(cast(double)orgLocal.x + cast(float)(cast(double)dirLocal.x * result.preciseT)),
                cast(float)(cast(double)orgLocal.y + cast(float)(cast(double)dirLocal.y * result.preciseT)),
                cast(float)(cast(double)orgLocal.z + cast(float)(cast(double)dirLocal.z * result.preciseT)));
            result.productRoundedPoint = ms.isIdentity ? localProductPoint : ms.toWorldPoint(localProductPoint);
        }

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
                import morph_preview : displayPosition;
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
                     out SurfaceHit result, const(uint)[] faceOrigin = null)
    {
        // §3.3 — ray built in WORLD space from the real `vp`; pickSurfaceRay
        // does the local-space transform.
        Vec3 org, dir;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, org, dir);
        return pickSurfaceRay(org, dir, sourceMesh, ms, result, faceOrigin);
    }

private:

    // Surface-pick rebuild — mirrors `rebuild()` above exactly (same fan
    // triangulation, same faceOriginGpu indirection when `gpu` is supplied)
    // but writes the SEPARATE `_surf*` fields and accepts a caller-supplied
    // freshness value instead of hardcoding `gpu.uploadVersion` (a background
    // mesh may never be GPU-uploaded — see `pickSurfaceRay`'s doc comment).
    // Since task 1906 stage 2b that value is the caller's `g_geomEpochs`
    // reading for this mesh address, not a mesh version counter.
    // Duplicated rather than shared with `rebuild()` so `pickFace`'s path
    // stays byte-identical with zero risk of the two caches interacting
    // (REV-3 of the topology-pen P0 plan).
    void rebuildSurface(const ref Mesh sourceMesh, const(uint)[] faceOrigin,
                        ulong epoch)
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
            import morph_preview : displayVertices;
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
        _surfTriVertices = new uint[3][](triCount);
        uint ti = 0;
        foreach (fi, face; sourceMesh.faces) {
            if (face.length < 3 || hideSkipFace(sourceMesh, fi)) continue;
            uint i0 = face[0];
            uint cageFace;
            if (faceOrigin.length > 0 && fi < faceOrigin.length)
                cageFace = faceOrigin[fi];
            else
                cageFace = cast(uint)fi;

            for (uint i = 1; i + 1 < face.length; i++) {
                indices[ti * 3 + 0] = i0;
                indices[ti * 3 + 1] = face[i];
                indices[ti * 3 + 2] = face[i + 1];
                _surfTriToFace[ti]  = cageFace;
                _surfTriVertices[ti] = [i0, face[i], face[i + 1]];
                ++ti;
            }
        }

        int nv = cast(int)sourceMesh.vertices.length;
        int nt = cast(int)ti;
        _surfHandle = dbvh_build(verts.ptr, nv, indices.ptr, nt);
        if (_surfHandle !is null)
            _surfKey.stamp(cast(size_t)&sourceMesh, epoch);
    }
}

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
bool hideSkipFace(const ref Mesh m, size_t fi) {
        return m.isFaceHidden(fi);
    }


/// The nearest hit of one WORLD ray across several background sources, each
/// cast through its OWN `ModelSpace` against a per-mesh surface BVH
/// (`SurfacePicker.pickSurfaceRay`), nearest by `t`. One query shared by the CONS
/// stage's ray forms (`ConstrainStage.rayHit`), so every pointer client reads
/// the same surface the same way. `S` is any source with `.mesh` (a
/// `const(Mesh)*`) and `.space` (a `ModelSpace`) — `constraint.BackgroundSource`
/// in the tree; a template so this module needs no import of it. Entries are
/// keyed by mesh ADDRESS and pruned of every address absent from the call's
/// `sources`, so a removed or hidden layer's BVH is freed.
struct BackgroundRayPicker {
    private SurfacePicker[size_t] _bvh;

    void clear() nothrow { _bvh.clear(); }

    /// False on a miss across every source (or no source); `outHit.source` is
    /// the index into `sources` of the source that answered.
    bool nearest(S)(Vec3 org, Vec3 dir, const(S)[] sources, out SurfaceHit outHit, bool productPoint = false) {
        bool[size_t] live;
        foreach (bg; sources)
            if (bg.mesh !is null) live[cast(size_t)bg.mesh] = true;
        size_t[] stale;
        foreach (addr, bp; _bvh)
            if ((addr in live) is null) stale ~= addr;
        foreach (addr; stale) _bvh.remove(addr);

        float bestT = float.infinity;
        bool  found = false;
        foreach (i, bg; sources) {
            if (bg.mesh is null) continue;
            immutable addr = cast(size_t)bg.mesh;
            auto pp = addr in _bvh;
            SurfacePicker bp;
            if (pp is null) {
                bp = new SurfacePicker();
                _bvh[addr] = bp;
            } else {
                bp = *pp;
            }
            SurfaceHit sh;
            if (!bp.pickSurfaceRay(org, dir, *bg.mesh, bg.space, sh, null, productPoint)) continue;
            if (sh.t >= bestT) continue;
            bestT  = sh.t;
            outHit = sh;
            outHit.source = cast(int)i;
            found  = true;
        }
        return found;
    }
}
