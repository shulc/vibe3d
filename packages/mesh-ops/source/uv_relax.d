module uv_relax;

/// Pure Jacobi uniform-Laplacian UV relax kernel.
///
/// Welds per-corner UV values into UV vertices (union-find over interior twin
/// pairs that agree in UV within epsUV), then runs N Jacobi passes: interior
/// UV vertices move toward the mean of their UV neighbours by `strength` per
/// pass; boundary / seam UV vertices are pinned.  An optional `cornerPinned`
/// mask adds caller-supplied pins (used by the command for selected-faces scope
/// restriction).
///
/// No mesh-level side-effects — the owning command calls
/// `commitChange(MeshEditScope.Material)`.
///
/// Mirrors the Jacobi-from-snapshot approach of mesh.smooth (smooth.d:261-283)
/// and `Mesh.smoothSubdivide`, lifted into UV space.  The exact
/// smoothing law is a vibe3d-divergence; capture-gated parity deferred.

import mesh     : Mesh, MeshMap, edgeKey;
import uv_weld  : buildUvClasses, uvEq;

// ---------------------------------------------------------------------------
// Public kernel.
// ---------------------------------------------------------------------------

/// Apply `iterations` Jacobi uniform-Laplacian passes over the per-corner UV
/// map `uv`.
///
/// Interior UV vertices (welded-corner clusters whose incident edges are all
/// interior and UV-continuous) move toward the mean of their UV neighbours by
/// `strength` per pass.  Boundary / seam UV vertices are pinned.
/// `cornerPinned[L]` force-pins the UV vertex at loop L regardless of topology
/// (used by UvRelax for selected-faces scope: unselected-face corners are
/// pinned so only the selected region's interior relaxes).
///
/// Returns `true` if any UV vertex moved; `false` for a true no-op (all verts
/// pinned, `iterations < 1`, or `strength == 0`).  The caller records undo
/// only on `true`.
bool uvRelax(const ref Mesh m, MeshMap* uv,
             int iterations, float strength,
             const bool[] cornerPinned = null)
{
    if (iterations < 1 || strength == 0.0f) return false;

    // DoS backstop (task 0365 P1): `iterations` scales the Jacobi pass
    // count below; Param `.min()` hints are UI-only and do not clamp a
    // direct/scripted caller.
    enum int MAX_UV_RELAX_ITER = 256;
    if (iterations > MAX_UV_RELAX_ITER) iterations = MAX_UV_RELAX_ITER;

    const size_t nL = m.loops.length;
    if (nL == 0) return false;

    float[] data = uv.data;   // alias — mutations write through to the map

    // -----------------------------------------------------------------------
    // 1+2.  Build UV-vertex weld + compact class IDs (delegated to uv_weld).
    // -----------------------------------------------------------------------
    auto cls      = buildUvClasses(m, data, null);
    uint[] rep     = cls.rep;
    uint[] classId = cls.classId;
    uint   nClasses = cls.nClasses;

    // -----------------------------------------------------------------------
    // 3.  Pin classification.
    //
    // A UV class is pinned if ANY member loop's outgoing edge is:
    //   (a) a mesh boundary (L.twin == ~0u), or
    //   (b) a UV seam (twin exists but UV disagrees on the a or b side), or
    //   (c) force-pinned via cornerPinned[].
    //
    // Iterating over all loops and pinning both endpoints of each bad edge
    // (class(L) and class(next(L)) for boundary; class(L)+class(next(T)) for
    // an a-side seam; class(next(L))+class(T) for a b-side seam) covers every
    // endpoint of every pin edge, possibly redundantly.
    // -----------------------------------------------------------------------
    bool[] pinned = new bool[](nClasses);

    foreach (L; 0 .. nL) {
        if (cornerPinned.length > L && cornerPinned[L])
            pinned[classId[rep[L]]] = true;

        const uint T = m.loops[L].twin;
        if (T == uint.max) {
            // Mesh-boundary edge L→next(L): pin both endpoint classes.
            pinned[classId[rep[L]]]              = true;
            pinned[classId[rep[m.loops[L].next]]] = true;
        } else {
            const uint nL_ = m.loops[L].next;
            const uint nT  = m.loops[T].next;
            if (!uvEq(data, L, nT)) {
                // a-side UV seam.
                pinned[classId[rep[L]]]  = true;
                pinned[classId[rep[nT]]] = true;
            }
            if (!uvEq(data, nL_, T)) {
                // b-side UV seam.
                pinned[classId[rep[nL_]]] = true;
                pinned[classId[rep[T]]]   = true;
            }
        }
    }

    // -----------------------------------------------------------------------
    // 4.  Class UV positions (UV of any member — equal by the weld criterion)
    //     and dedup-undirected UV-edge adjacency.
    //
    // For each loop L the pair {class(L), class(next(L))} is a UV edge.
    // A bool AA keyed on (min,max) deduplicates directed/duplicate occurrences
    // so each shared edge is counted exactly once (true uniform Laplacian).
    // -----------------------------------------------------------------------
    float[] upos = new float[](nClasses * 2);
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        upos[c * 2]     = data[L * 2];
        upos[c * 2 + 1] = data[L * 2 + 1];
    }

    uint[][] neighbors = new uint[][](nClasses);
    bool[ulong] edgeSeen;

    foreach (L; 0 .. nL) {
        const uint cA = classId[rep[L]];
        const uint cB = classId[rep[m.loops[L].next]];
        if (cA == cB) continue;
        const ulong key = edgeKey(cA, cB);
        if (key in edgeSeen) continue;
        edgeSeen[key] = true;
        neighbors[cA] ~= cB;
        neighbors[cB] ~= cA;
    }

    // Early-out when nothing can relax.
    {
        bool any = false;
        foreach (c; 0 .. nClasses)
            if (!pinned[c] && neighbors[c].length > 0) { any = true; break; }
        if (!any) return false;
    }

    // -----------------------------------------------------------------------
    // 5.  Jacobi passes — read from `prev`, write to `cur`, swap each pass.
    //     After N passes `prev` holds the final state (last swap).
    // -----------------------------------------------------------------------
    float[] prev = upos.dup;
    float[] cur  = upos.dup;

    foreach (_; 0 .. iterations) {
        foreach (c; 0 .. nClasses) {
            if (pinned[c]) continue;
            auto nbrs = neighbors[c];
            if (nbrs.length == 0) continue;
            float su = 0.0f, sv = 0.0f;
            foreach (nb; nbrs) {
                su += prev[nb * 2];
                sv += prev[nb * 2 + 1];
            }
            const float invN = 1.0f / cast(float)nbrs.length;
            cur[c * 2]     = prev[c * 2]     + strength * (su * invN - prev[c * 2]);
            cur[c * 2 + 1] = prev[c * 2 + 1] + strength * (sv * invN - prev[c * 2 + 1]);
        }
        // Swap buffers — no alloc per pass.
        auto tmp = prev; prev = cur; cur = tmp;
    }

    // -----------------------------------------------------------------------
    // 6.  Scatter back: write final UV to every member loop of each NON-PINNED
    //     class only.  Pinned class bytes in uv.data are never written, so
    //     they are provably byte-unchanged on any input.
    // -----------------------------------------------------------------------
    bool anyMoved = false;
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        if (pinned[c]) continue;
        const float uFinal = prev[c * 2];
        const float vFinal = prev[c * 2 + 1];
        if (data[L * 2] != uFinal || data[L * 2 + 1] != vFinal) {
            data[L * 2]     = uFinal;
            data[L * 2 + 1] = vFinal;
            anyMoved = true;
        }
    }
    return anyMoved;
}

// ---------------------------------------------------------------------------
// Module-level unit tests — run by `dub test --config=tests`.
// ---------------------------------------------------------------------------
