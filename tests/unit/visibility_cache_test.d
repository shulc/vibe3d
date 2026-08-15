// Task 0833, cache half — module unittests for `visibility_cache`.
//
// This module had NONE before: `VisibilityCache` is the one member of the
// version-keyed cache family (snap grids / visibility / subpatch preview /
// BVH) whose per-mesh-address key term was completely unexercised. It also has
// no production caller today (the lasso path that used it moved to
// `gpuSelect.elementVisibility`), which is exactly why the term needed pinning
// rather than trusting: a cache with no caller has nothing keeping its key
// honest until a caller comes back.
module tests.unit.visibility_cache_test;

import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix;
import mesh : Mesh;
import visibility_cache : VisibilityCache;

// ---------------------------------------------------------------------------
// Two DIFFERENT meshes at an equal mutationVersion and an equal vertex count
// must not alias in the (meshAddr, mutationVersion, vertCount, eye, view, ms)
// key. That aliasing is the class which already bit this tree once — two
// same-version layers served each other's cached result — and the address term
// is what closed it. With one layer the address is constant, so the term is
// invisible and nothing but a block like this can tell it is still there.
//
// Discriminator: the two meshes are the same cube with OPPOSITE winding, so
// every face that faces the eye in one faces away in the other. A cache hit
// across them therefore reports a visible corner as visible when it must read
// hidden — a wrong answer, not a rounding difference.
//
// Not `debug`-wrapped: a cache key is live in every build, unlike the
// `debug assert` guards this task's other half exercises.
// ---------------------------------------------------------------------------
unittest {
    import std.math : PI;

    // The cube from mesh_test's `visibleVertices` fixture: spans
    // x in [1.5, 2.5], y and z in [-0.5, 0.5]. Corner 6 (2.5, 0.5, 0.5) is
    // nearest the eye at (5,5,5) and reads visible; corner 0 is farthest and
    // reads hidden.
    static Mesh cube(bool flipWinding) {
        Mesh m;
        m.vertices = [
            Vec3( 1.5f, -0.5f, -0.5f), // 0
            Vec3( 2.5f, -0.5f, -0.5f), // 1
            Vec3( 2.5f,  0.5f, -0.5f), // 2
            Vec3( 1.5f,  0.5f, -0.5f), // 3
            Vec3( 1.5f, -0.5f,  0.5f), // 4
            Vec3( 2.5f, -0.5f,  0.5f), // 5
            Vec3( 2.5f,  0.5f,  0.5f), // 6
            Vec3( 1.5f,  0.5f,  0.5f), // 7
        ];
        m.faces = [
            [0u, 3u, 2u, 1u], [4u, 5u, 6u, 7u],
            [0u, 4u, 7u, 3u], [1u, 2u, 6u, 5u],
            [3u, 7u, 6u, 2u], [0u, 1u, 5u, 4u],
        ];
        if (flipWinding) {
            // Same vertices, same vertex COUNT, same version — every face
            // wound the other way, so the whole cube is inside-out and no
            // corner survives the front-facing test.
            foreach (ref f; m.faces) {
                uint[] r = new uint[](f.length);
                foreach (i, vi; f) r[f.length - 1 - i] = vi;
                f = r;
            }
        }
        return m;
    }

    Mesh outward = cube(false);
    Mesh inward  = cube(true);
    assert(outward.mutationVersion == inward.mutationVersion,
        "setup: the two meshes must collide on mutationVersion — that "
        ~ "collision IS the hazard");
    assert(outward.vertices.length == inward.vertices.length,
        "setup: equal vertex counts, so `vertCount_` cannot separate them "
        ~ "either");

    Viewport vp;
    vp.eye   = Vec3(5, 5, 5);
    vp.view  = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj  = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width = 400; vp.height = 400;

    VisibilityCache cache;

    bool[] visOut = cache.get(outward, vp.eye, vp, ModelSpace.world());
    assert(visOut[6],
        "fixture: the corner nearest the eye must read visible on the "
        ~ "outward-wound cube");
    assert(!visOut[0],
        "fixture: the farthest corner must read hidden");

    // Second mesh, everything else about the query identical. Only the source
    // ADDRESS differs.
    bool[] visIn = cache.get(inward, vp.eye, vp, ModelSpace.world());
    assert(!visIn[6],
        "a second mesh at the SAME mutationVersion and vertex count must force "
        ~ "a recompute, not serve the first mesh's mask — corner 6 belongs to "
        ~ "no front-facing face on the inside-out cube, so reading it visible "
        ~ "means the key has lost its address term and two same-version layers "
        ~ "are aliasing again");

    // ...and re-querying the first mesh comes back to its own answer, so the
    // address term discriminates in both directions rather than just defeating
    // the cache.
    bool[] visOut2 = cache.get(outward, vp.eye, vp, ModelSpace.world());
    assert(visOut2[6] && !visOut2[0],
        "the original mesh must still get its own mask back");

    // A repeat query on the SAME mesh with the SAME camera is what the cache
    // exists for: the key must MATCH here, or the address term has been turned
    // into a blanket "always rebuild".
    assert(cache.get(outward, vp.eye, vp, ModelSpace.world()).ptr is visOut2.ptr,
        "a repeat query against the same mesh must hit the cache (same backing "
        ~ "store), not recompute — a key that never matches is not a fix");
}
