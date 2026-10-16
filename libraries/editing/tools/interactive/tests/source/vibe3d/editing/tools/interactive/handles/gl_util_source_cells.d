module vibe3d.editing.tools.interactive.handles.gl_util_source_cells;

import bindbc.opengl;
import std.math : sqrt, PI, abs;
import vibe3d.util.profiling.perf_probe : g_fc, DrawPass;
version (web) {
} else {
    import vibe3d.viewport.gpu.gl_thread_guard : glThreadGuard;
}
import vibe3d.viewport.gpu.shader : seedSharedFragUniforms;
import vibe3d.util.math.math;
import vibe3d.util.spatial.spatial : Viewport;
import vibe3d.editing.tools.interactive.handles.gl_util;

unittest {
    // The arrowhead is a CLOSED, CAPPED tetrahedron wound uniformly outward,
    // and its body sits in one quadrant. Every claim below is re-derived from
    // the emitted floats; none of it reads a constant back to itself.
    import std.algorithm : canFind, map, sort;
    import std.array     : array;
    import std.math      : abs;

    float[] d;
    buildWedgeHeadData(d);
    assert(d.length == 4 * 3 * 3,
           "the head must be 4 triangles / 12 vertices / 36 floats");

    static Vec3 vert(const float[] d, size_t i) {
        return Vec3(d[i*3], d[i*3 + 1], d[i*3 + 2]);
    }
    static bool same(Vec3 a, Vec3 b) {
        return abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f;
    }

    // 1. Exactly FOUR distinct points, and they are the four the card names.
    Vec3[] uniq;
    foreach (i; 0 .. 12) {
        auto v = vert(d, i);
        bool seen = false;
        foreach (u; uniq) if (same(u, v)) { seen = true; break; }
        if (!seen) uniq ~= v;
    }
    assert(uniq.length == 4,
           "twelve vertices must close on four points — the head is a tetrahedron");
    foreach (want; [Vec3(0,0,1), Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)]) {
        bool found = false;
        foreach (u; uniq) if (same(u, want)) { found = true; break; }
        assert(found, "a base/apex point of the arrowhead is missing");
    }

    // 2. The ONE-QUADRANT claim, restated as REACH rather than as coordinates:
    //    the head extends a full unit along each lateral on the POSITIVE side
    //    and nothing at all on the negative one — which is why the drawn head
    //    is H across and not 2H. Check 1 already pins the four points, so this
    //    cannot fail on its own; it is kept because it says in one line what
    //    the shape is FOR, and it is the line that would have to be deleted,
    //    not merely edited, to put a symmetric head back.
    float minX = 0, maxX = 0, minY = 0, maxY = 0;
    foreach (u; uniq) {
        if (u.x < minX) minX = u.x;  if (u.x > maxX) maxX = u.x;
        if (u.y < minY) minY = u.y;  if (u.y > maxY) maxY = u.y;
    }
    assert(maxX == 1.0f && minX == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");
    assert(maxY == 1.0f && minY == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");

    // 3. CLOSED and CAPPED: the four triangles are the four distinct 3-subsets
    //    of the four points, each appearing exactly once. A missing base cap
    //    (three faces) or a doubled face both fail here.
    int[][] faceKeys;
    foreach (f; 0 .. 4) {
        int[] key;
        foreach (k; 0 .. 3) {
            auto v = vert(d, f*3 + k);
            foreach (idx, u; uniq) if (same(u, v)) { key ~= cast(int)idx; break; }
        }
        assert(key.length == 3, "a face names a point that is not one of the four");
        assert(key[0] != key[1] && key[1] != key[2] && key[0] != key[2],
               "a face repeats a vertex — that triangle has no area");
        key.sort();
        assert(!faceKeys.canFind(key), "a face of the head is emitted twice");
        faceKeys ~= key;
    }
    assert(faceKeys.length == 4, "the head must have all four faces, cap included");

    // 4. WINDING: every face's CCW normal points AWAY from the solid's own
    //    centroid, i.e. the whole shape is outward-CCW and `outwardCCW` is the
    //    correct HandleFacing for it. This is the assertion that catches a
    //    face copied over with the reference's own (mixed) vertex order.
    Vec3 cen = Vec3(0,0,0);
    foreach (u; uniq) cen = cen + u;
    cen = cen / 4.0f;
    foreach (f; 0 .. 4) {
        auto p0 = vert(d, f*3), p1 = vert(d, f*3 + 1), p2 = vert(d, f*3 + 2);
        auto n  = cross(p1 - p0, p2 - p0);
        assert(dot(n, p0 - cen) > 1e-6f,
               "an arrowhead face is wound INWARD; culling GL_BACK would open "
               ~ "a hole in the solid and its alpha would stack twice there");
    }
}
