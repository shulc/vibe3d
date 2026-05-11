module visibility_cache;

import math : Vec3, Viewport;
import mesh : Mesh;

// ---------------------------------------------------------------------------
// VisibilityCache — memoises `Mesh.visibleVertices(eye, vp)`.
//
// The picking code in `app.d` (`pickVertices` / `pickEdges` / lasso paths)
// queries this on every `SDL_MOUSEMOTION`. The underlying nested loop is
// O(V × F_front) — for an 8 K-vert mesh that means tens of millions of
// bbox checks per mouse-move event, which `perf` measured as 98.46 %
// of CPU. Result is fully deterministic given `(mutationVersion, eye,
// view-matrix)`, so caching by that triple turns 100 Hz mouse-move into
// constant-time lookups until the camera or mesh changes.
//
// One cache instance per source mesh — the main mesh and the subpatch
// preview live separately. Lifetime: held by app.d alongside the other
// per-frame caches (`VertexCache`, `EdgeCache`, `FaceBoundsCache`).
// ---------------------------------------------------------------------------

struct VisibilityCache {
    private bool[]    visible_;
    private ulong     mutVer_   = ulong.max;
    private size_t    vertCount_;
    private Vec3      eye_;
    private float[16] view_;
    private bool      valid_    = false;

    /// Return the cached visibility mask if the (mutationVersion, eye,
    /// view-matrix) triple matches the last call; otherwise rebuild
    /// via `m.visibleVertices(eye, vp)` and refresh the keys.
    bool[] get(const ref Mesh m, Vec3 eye, ref const Viewport vp) {
        if (matches(m, eye, vp)) return visible_;
        visible_  = m.visibleVertices(eye, vp).dup;
        mutVer_   = m.mutationVersion;
        vertCount_= m.vertices.length;
        eye_      = eye;
        view_     = vp.view;
        valid_    = true;
        return visible_;
    }

    /// Drop the cached result; next `get()` forces a recompute. Use
    /// when the source mesh is rebuilt and `mutationVersion` may have
    /// rolled back (e.g. `*mesh = makeCube()` resets the struct).
    void invalidate() {
        valid_ = false;
    }

private:
    bool matches(const ref Mesh m, Vec3 eye, ref const Viewport vp) const {
        if (!valid_) return false;
        if (mutVer_    != m.mutationVersion) return false;
        if (vertCount_ != m.vertices.length) return false;
        if (eye_.x != eye.x || eye_.y != eye.y || eye_.z != eye.z) return false;
        foreach (i; 0 .. 16) if (view_[i] != vp.view[i]) return false;
        return true;
    }
}
