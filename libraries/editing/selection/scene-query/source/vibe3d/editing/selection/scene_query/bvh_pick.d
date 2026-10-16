module vibe3d.editing.selection.scene_query.bvh_pick;

import bvh.c;
import vibe3d.util.math.math : Vec3, cross;
import vibe3d.util.spatial.spatial : Viewport, screenRay, screenPointToRay, ModelSpace;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.util.profiling.perf_probe : g_perf, Cat, g_fc;
// Task 1906 stage 2b — the SURFACE tree's freshness key. See `pickSurfaceRay`.
public import vibe3d.editing.selection.query.surface_pick : SurfaceHit, BackgroundRayPicker;
import vibe3d.editing.selection.query.surface_pick : SurfacePicker, hideSkipFace;



/// Single-mesh BVH cache. App.d holds one instance for the active mesh.
///
/// Holds TWO independent BVH caches under one class:
///   * `_handle`/`_uploadVersion`/`_meshAddr`/`_triToFace` — the original
///     face-pick cache, keyed on `GpuMesh.uploadVersion`. Exercised ONLY by
///     `pickFace`. UNCHANGED by the P0 surface-pick addition below (a
///     pre-existing unit test asserts `_uploadVersion` by name — see
///     bottom of this file) — byte-identical path, byte-identical field.
///   * `_surfHandle`/`_surfKey`/`_surfTriToFace` — the surface-pick cache
///     (`pickSurface`/`pickSurfaceRay`), keyed on (mesh address, CHANGE-BUS
///     epoch) since task 1906 stage 2b. It cannot key on `uploadVersion`
///     (a background mesh may never be GPU-uploaded — topology-pen P0 plan,
///     risk R3) and it MUST NOT key on `mutationVersion` — see
///     `pickSurfaceRay`.
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
///     packages/scene-query/tests/source/tests/unit/bvh_pick_test.d: delete the term and it goes red.
///   * `_surfKey.addr` (surface pick) is redundant TODAY: its only caller,
///     `ConstrainStage`, already keys its `BvhPick[size_t]` map BY mesh
///     address (toolpipe/stages/constrain.d), so a given instance never sees
///     a second mesh. Kept, because the key belongs to the cache rather than
///     to one caller's bookkeeping — but a test for it would be asserting
///     `constrain.d`'s AA, not this cache, so none was written. It is load-
///     bearing in a second way since 1906: an epoch is per ADDRESS, and two
///     meshes can sit at the same epoch.
class BvhPick {
private:
    dbvh_t* _handle;
    ulong   _uploadVersion;
    size_t  _meshAddr;
    uint[]  _triToFace;   // _triToFace[bvhTriIndex] = cage face index
    SurfacePicker _surfacePicker;


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


    ~this() {
        import core.memory : GC;
        invalidate();
        // GC may have finalized the surface owner already; immediate destroy
        // still invalidates its live native tree (task 20262020, Wave5 §5C).
        if (!GC.inFinalizer && _surfacePicker !is null)
            _surfacePicker.invalidateSurface();
        _surfacePicker = null;
    }

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
        // recorded remainder (1906 §3.6): `GpuMesh.uploadVersion` owns this
        // compare and stays (plan §3.2 row 6). The FACE tree is built to agree
        // with what the GPU rasterised, so the artifact it keys on is the VBO,
        // not the mesh. Its sibling `pickSurfaceRay` is the opposite case and
        // was the 2b bug fix: that one reads the MESH, so it keys on
        // `mesh_dirty.g_geomEpochs` — see `_surfKey` below.
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

    // Task 20262040: preserve the GPU facade while the CPU owner receives only
    // face-origin values; explicit teardown preserves native handle lifetime.
    // See doc/application_layers_wave5_plan_2026-10-09.md, Slice5A.
    bool pickSurfaceRay(Vec3 org, Vec3 dir, const ref Mesh sourceMesh,
                        const ModelSpace ms,
                        out SurfaceHit result, const(GpuMesh)* gpu = null, bool productPoint = false)
    {
        if (_surfacePicker is null) _surfacePicker = new SurfacePicker();
        return _surfacePicker.pickSurfaceRay(org, dir, sourceMesh, ms, result, gpu is null ? null : gpu.faceOriginGpu, productPoint);
    }

    bool pickSurface(int mx, int my, const ref Viewport vp,
                     const ref Mesh sourceMesh, const ModelSpace ms,
                     out SurfaceHit result, const(GpuMesh)* gpu = null)
    {
        if (_surfacePicker is null) _surfacePicker = new SurfacePicker();
        return _surfacePicker.pickSurface(mx, my, vp, sourceMesh, ms, result, gpu is null ? null : gpu.faceOriginGpu);
    }

private:


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
            import vibe3d.mesh.preview.morph_preview : displayVertices;
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
    import vibe3d.util.math.math : lookAt, perspectiveMatrix;

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
    import vibe3d.util.math.math : lookAt, perspectiveMatrix;

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
// no-GL_CULL_FACE pick pass — the DISPLAY pass culls since S1d, the picker
// does not) is already covered WITHOUT a mirror: the
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

// Task 20262020: private _surfacePicker ownership is lazy, shared, and torn down immediately.
unittest {
    import std.math : fabs;
    import core.memory : GC;
    import core.thread : Thread;
    import core.stdc.stdlib : calloc, free;
    Mesh src;
    src.vertices = [Vec3(-1,0,-1), Vec3(1,0,-1), Vec3(1,0,1), Vec3(-1,0,1)];
    src.faces = [cast(uint[])[0,3,2,1]];
    auto pick = new BvhPick;
    assert(pick._surfacePicker is null, "surface owner starts lazy");
    SurfaceHit hit;
    assert(pick.pickSurfaceRay(Vec3(0,5,0), Vec3(0,-1,0), src, ModelSpace.world(), hit));
    auto owner = pick._surfacePicker;
    assert(owner !is null && fabs(hit.point.y) < 1e-4f, "surface owner materializes on actual query");
    assert(pick.pickSurfaceRay(Vec3(0,5,0), Vec3(0,-1,0), src, ModelSpace.world(), hit));
    assert(pick._surfacePicker is owner, "facade reuses one surface owner");
    foreach (ref v; src.vertices) v.y = 2;
    assert(owner.pickSurfaceRay(Vec3(0,5,0), Vec3(0,-1,0), src, ModelSpace.world(), hit));
    assert(fabs(hit.point.y) < 1e-4f, "unpublished geometry remains cached before destructor");
    destroy(pick);
    assert(owner.pickSurfaceRay(Vec3(0,5,0), Vec3(0,-1,0), src, ModelSpace.world(), hit));
    assert(fabs(hit.point.y - 2) < 1e-4f, "facade destructor invalidates native surface tree immediately");

    struct Finalization {
        uint queries, sequence, child, parent;
        bool childFromGC, parentFromGC;
    }
    static class Child : SurfacePicker {
        Finalization* witness;
        this(Finalization* witness) { this.witness = witness; }
        ~this() {
            witness.childFromGC = GC.inFinalizer;
            witness.child = ++witness.sequence;
        }
    }
    static class Parent : BvhPick {
        Finalization* witness;
        this(Finalization* witness) { this.witness = witness; }
        ~this() {
            witness.parentFromGC = GC.inFinalizer;
            witness.parent = ++witness.sequence;
        }
    }
    auto witness = cast(Finalization*)calloc(1, Finalization.sizeof);
    auto root = cast(BvhPick*)calloc(1, BvhPick.sizeof);
    assert(witness !is null && root !is null);
    GC.addRange(root, BvhPick.sizeof);
    scope(exit) { GC.removeRange(root); free(root); free(witness); }
    // A departed allocator thread leaves no conservative stack roots. NO_SCAN
    // on this test parent makes the permitted child-first GC order deterministic.
    auto allocator = new Thread({
        auto parent = new Parent(witness);
        parent._surfacePicker = new Child(witness);
        SurfaceHit populated;
        assert(parent.pickSurfaceRay(Vec3(0,5,0), Vec3(0,-1,0), src,
            ModelSpace.world(), populated), "GC fixture has a native surface tree");
        ++witness.queries;
        GC.setAttr(cast(void*)parent, GC.BlkAttr.NO_SCAN);
        *root = parent;
    });
    allocator.start();
    allocator.join();
    GC.collect();
    assert(witness.queries == 1, "GC finalization query population");
    assert(witness.childFromGC && witness.child == 1 && witness.parent == 0,
        "child must actually finalize from GC before the rooted parent");
    *root = null;
    GC.collect();
    assert(witness.parentFromGC && witness.parent == 2 && witness.sequence == 2,
        "parent must actually finalize from GC after its child");
}
