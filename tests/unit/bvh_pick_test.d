// Module unittests for `bvh_pick`, moved verbatim out of source/bvh_pick.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.bvh_pick_test;

import bvh.c;
import math : Vec3, Viewport, screenRay, screenPointToRay, cross, ModelSpace;
import mesh : Mesh, GpuMesh;
import perf_probe : g_perf, Cat, g_fc;
import bvh_pick;

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
    // A published POSITION change forces a rebuild — the surface-pick cache's
    // OWN key, independent of pickFace's uploadVersion (REV-3: the two caches
    // must never alias).
    //
    // TASK 1906 STAGE 2b — this block used to bump `src.mutationVersion` by
    // hand, because that WAS the key. It is not any more, and the reason is a
    // shipped defect rather than a refactor: an interactive gizmo drag is
    // version-silent on Position, so the version never moved and the surface
    // BVH served pre-drag geometry for the rest of the session
    // (`tests/test_bus_surface_raycast_after_drag.d` ARM A is that red).
    //
    // The change class is delivered here by calling the LISTENER BODY
    // directly, which is also the honest thing for a headless block: this
    // `Mesh` is a stack local owned by no `Layer`, so `Mesh.publishChange`
    // would be refused by `deliverPending`'s subject filter and reach no
    // listener at all. `mesh_dirty.noteMeshChange` is what `app.d`'s hub
    // calls with the delivered (address, flags), and it is public for exactly
    // this use — the same arrangement `snap.invalidateSnapGrids()` has.
    import std.math      : fabs;
    import mesh_dirty    : noteMeshChange;
    import mesh_edit_delta : MeshEditScope;

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

    // Move the quad up to Y=2 and bump `mutationVersion` WITHOUT publishing.
    //
    // THE CACHE MUST STILL ANSWER Y=0 HERE, AND THAT STALE READ IS THE POINT
    // — do not "fix" this assert. It is the half that says which counter the
    // key reads: if `mutationVersion` were still the key, this bump alone
    // would rebuild and the hit would already be at Y=2. Restoring
    // `_surfVersionKey = sourceMesh.mutationVersion` in `bvh_pick.d` reddens
    // exactly this line. (No production path bumps the version without
    // publishing: `commitChange` does both, which is why this is the honest
    // way to isolate the key.)
    foreach (ref v; src.vertices) v.y += 2.0f;
    src.mutationVersion++;
    SurfaceHit hitV;
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hitV));
    assert(fabs(hitV.point.y) < 1e-4f,
        "a bare mutationVersion bump must NOT rebuild the surface BVH — the "
      ~ "version is no longer this cache's key (task 1906 stage 2b)");

    // Now PUBLISH the class the bus carries for a moved vertex — a cache that
    // ignored it would still report the OLD (Y=0) intersection point.
    noteMeshChange(cast(size_t)&src, MeshEditScope.Position);

    SurfaceHit hit2;
    assert(pick.pickSurfaceRay(Vec3(0, 5, 0), Vec3(0, -1, 0), src, ModelSpace.world(), hit2));
    assert(fabs(hit2.point.y - 2.0f) < 1e-4f,
        "surface-pick cache should have rebuilt after a published Position "
      ~ "change (task 1906 stage 2b: the key is the change-bus epoch for this "
      ~ "mesh address, not mutationVersion)");
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

// ---------------------------------------------------------------------------
// Task 0833, cache half — the FACE-pick cache's key is (uploadVersion, source
// mesh ADDRESS), and the address term must be load-bearing.
//
// app.d holds ONE `BvhPick` (app.d:1650) and feeds it whichever mesh the GPU
// last rasterised: the cage, or the subpatch PREVIEW mesh when a preview is
// active, or — since layers — a different layer's cage after a primary switch.
// Those are different `Mesh` objects that can trivially share an
// `uploadVersion`, so without the address term the second pick answers out of
// the first mesh's BVH. That is the same aliasing class that already bit this
// tree in the version-keyed caches, which is why the term is there; this
// makes its removal observable instead of leaving it as a comment.
//
// Discriminator: the two meshes disagree about WHICH FACE INDEX sits under the
// cursor (0 vs 1), so an aliased answer is a wrong number, not a near-miss.
// Both are cast at the same pixel through the same viewport with the same
// GpuMesh, so the address is the only key term that differs.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    import std.math : PI;
    import math : lookAt, perspectiveMatrix;

    // Single quad at y = 0 — the face under the cursor is index 0.
    Mesh one;
    one.vertices = [
        Vec3(-1f, 0f, -1f), Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f), Vec3(-1f, 0f,  1f),
    ];
    one.faces = [ cast(uint[])[0, 3, 2, 1] ];

    // Two stacked quads — the face under the cursor is index 1 (the near one).
    Mesh two;
    two.vertices = [
        Vec3(-1f, 0f, -1f), Vec3( 1f, 0f, -1f),
        Vec3( 1f, 0f,  1f), Vec3(-1f, 0f,  1f),
        Vec3(-1f, 2f, -1f), Vec3( 1f, 2f, -1f),
        Vec3( 1f, 2f,  1f), Vec3(-1f, 2f,  1f),
    ];
    two.faces = [ cast(uint[])[0, 3, 2, 1], cast(uint[])[4, 7, 6, 5] ];

    assert(one.mutationVersion == two.mutationVersion,
        "setup: the two meshes must collide on version — the collision IS the "
        ~ "hazard");

    Vec3 eye  = Vec3(0f, 5f, 0f);
    float[16] view = lookAt(eye, Vec3(0f, 0f, 0f), Vec3(0f, 0f, -1f));
    float[16] proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    Viewport vp = Viewport(view, proj, 200, 200, 0, 0, eye);

    GpuMesh gpu;
    gpu.uploadVersion = 1;      // the SAME upload version for both picks

    auto pick = new BvhPick();  // ONE instance, exactly as app.d holds one
    assert(pick.pickFace(100, 100, vp, one, gpu, ModelSpace.world()) == 0,
        "setup: the lone quad is face 0");
    assert(pick.pickFace(100, 100, vp, two, gpu, ModelSpace.world()) == 1,
        "a second source mesh at the SAME uploadVersion must force a BVH "
        ~ "rebuild, not answer out of the first mesh's tree — got "
        ~ pick.pickFace(100, 100, vp, two, gpu, ModelSpace.world()).to!string
        ~ "; the (uploadVersion, mesh address) key has lost its address term");
}

