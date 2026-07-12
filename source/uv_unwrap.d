module uv_unwrap;

/// Pure cotangent-weighted harmonic UV relaxation kernel — discrete-conformal
/// Gauss-Seidel unwrap seeded from an existing UV map.
///
/// Algorithm (vibe3d-divergence; reference solver is closed-source / different):
///   1. Weld per-corner UVs into UV-vertex classes, cutting at seam edges and
///      mesh boundary.
///   2. Compute cotangent-weighted edge weights from 3D fan-triangulated faces.
///      Negative cotangents are clamped to 0 → convex-combination guarantee.
///   3. Pin classes that touch a mesh-boundary or seam edge (Dirichlet BCs).
///      Guard: zero pinned classes → return false (harmonic system singular).
///   4. Run N in-place Gauss-Seidel passes: each interior class moves to the
///      weight-normalised average of its cotan-weighted UV neighbours.
///   5. Scatter final UV back to every member loop of each non-pinned class.
///
/// Monotone quantity: the discrete Dirichlet / conformal energy decreases
/// on every pass (SPD system + Dirichlet BCs + non-negative cotan weights);
/// that is what `uvDirichletEnergy` measures and what the test asserts.
///
/// Angular distortion (`uvAngularDistortion`) is reduced by the solver on
/// well-shaped inputs but is not provably monotone per-pass.

import mesh    : Mesh, MeshMap;
import math    : Vec3, dot, cross;
import std.math : fabs, sqrt, acos;
import uv_weld : buildUvClasses;

// ---------------------------------------------------------------------------
// Cotan helper — cot(angle between e1 and e2) clamped to [0, ∞).
// ---------------------------------------------------------------------------

private float cotClamp(Vec3 e1, Vec3 e2) pure nothrow @nogc {
    const float d   = dot(e1, e2);
    const Vec3  cr  = cross(e1, e2);
    const float mag = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
    const float eps = 1e-10f;
    const float cot = d / (mag < eps ? eps : mag);
    return cot < 0.0f ? 0.0f : cot;
}

// ---------------------------------------------------------------------------
// Edge accumulator keyed on (min, max) class-id pair.
// ---------------------------------------------------------------------------

private ulong edgeKey(uint a, uint b) pure nothrow @nogc {
    uint lo = a < b ? a : b;
    uint hi = a < b ? b : a;
    return (cast(ulong)lo << 32) | hi;
}

// ---------------------------------------------------------------------------
// Public kernel.
// ---------------------------------------------------------------------------

/// Apply `iterations` cotangent-weighted harmonic Gauss-Seidel passes over
/// the per-corner UV map `uv`, using 3D geometry for cotan weights.
///
/// `seamLoop[L]` marks loop L as lying on a seam edge (explicit cut in
/// addition to mesh boundary).  `cornerPinned[L]` force-pins loop L's UV
/// class (used for selected-face scope restriction, same as `uvRelax`).
///
/// Returns `true` iff at least one UV value changed.  Returns `false` for:
///   - `iterations < 1` or no loops
///   - zero pinned classes (closed mesh + no seams → singular system guard)
///   - nothing relaxable (all classes pinned)
///   - no UV value actually moved
bool uvUnwrap(const ref Mesh m, MeshMap* uv, int iterations,
              const bool[] seamLoop    = null,
              const bool[] cornerPinned = null)
{
    if (iterations < 1) return false;

    // DoS backstop (task 0365 P1): `iterations` scales the Gauss-Seidel
    // pass count below; Param `.min()` hints are UI-only and do not clamp a
    // direct/scripted caller.
    enum int MAX_UV_UNWRAP_ITER = 256;
    if (iterations > MAX_UV_UNWRAP_ITER) iterations = MAX_UV_UNWRAP_ITER;

    const size_t nL = m.loops.length;
    if (nL == 0) return false;

    float[] data = uv.data;   // alias — mutations write through to the map

    // -----------------------------------------------------------------------
    // 1.  Weld UV classes, cutting at mesh boundary + explicit seams.
    // -----------------------------------------------------------------------
    bool delegate(uint) cutPred = null;
    if (seamLoop.length >= nL)
        cutPred = (uint L) => seamLoop[L];

    auto cls      = buildUvClasses(m, data, cutPred);
    uint[] rep     = cls.rep;
    uint[] classId = cls.classId;
    uint   nClasses = cls.nClasses;

    // -----------------------------------------------------------------------
    // 2.  Cotan adjacency — fan-triangulate each face, accumulate per class-pair.
    // -----------------------------------------------------------------------
    float[ulong] edgeW;   // accumulated cotan weight per unique class pair

    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        const size_t nc   = m.faces[fi].length;
        if (nc < 3) continue;
        const size_t base = m.faceLoop[fi];

        foreach (t; 0 .. nc - 2) {
            const size_t la = base;
            const size_t lb = base + t + 1;
            const size_t lc = base + t + 2;

            Vec3 pa = m.vertices[m.loops[la].vert];
            Vec3 pb = m.vertices[m.loops[lb].vert];
            Vec3 pc = m.vertices[m.loops[lc].vert];

            const float cot_a = cotClamp(pb - pa, pc - pa);  // angle at a → edge (b,c)
            const float cot_b = cotClamp(pa - pb, pc - pb);  // angle at b → edge (a,c)
            const float cot_c = cotClamp(pa - pc, pb - pc);  // angle at c → edge (a,b)

            const uint ca = classId[rep[la]];
            const uint cb = classId[rep[lb]];
            const uint cc = classId[rep[lc]];

            // Add 0.5*cot_opposite onto each class-pair edge.
            if (ca != cb) {
                auto k = edgeKey(ca, cb);
                if (auto p = k in edgeW) *p += 0.5f * cot_c;
                else                      edgeW[k] = 0.5f * cot_c;
            }
            if (ca != cc) {
                auto k = edgeKey(ca, cc);
                if (auto p = k in edgeW) *p += 0.5f * cot_b;
                else                      edgeW[k] = 0.5f * cot_b;
            }
            if (cb != cc) {
                auto k = edgeKey(cb, cc);
                if (auto p = k in edgeW) *p += 0.5f * cot_a;
                else                      edgeW[k] = 0.5f * cot_a;
            }
        }
    }

    // Build per-class neighbor lists from edgeW.
    uint[][]  nbr = new uint[][](nClasses);
    float[][] wt  = new float[][](nClasses);
    foreach (key, w; edgeW) {
        if (w <= 0.0f) continue;
        const uint lo = cast(uint)(key >> 32);
        const uint hi = cast(uint)(key & 0xFFFF_FFFFu);
        nbr[lo] ~= hi;  wt[lo] ~= w;
        nbr[hi] ~= lo;  wt[hi] ~= w;
    }

    // -----------------------------------------------------------------------
    // 3.  Pin classification.
    //     Pin any class touching a mesh-boundary or seam edge.
    //     Also honour caller cornerPinned[].
    // -----------------------------------------------------------------------
    bool[] pinned = new bool[](nClasses);

    foreach (L; 0 .. nL) {
        if (cornerPinned.length > L && cornerPinned[L])
            pinned[classId[rep[L]]] = true;

        const uint T = m.loops[L].twin;
        if (T == uint.max) {
            // Mesh-boundary edge: pin both endpoint classes.
            pinned[classId[rep[L]]]               = true;
            pinned[classId[rep[m.loops[L].next]]] = true;
        } else if (seamLoop.length >= nL && seamLoop[L]) {
            // Seam edge: pin both sides' endpoints.
            pinned[classId[rep[L]]]               = true;
            pinned[classId[rep[m.loops[L].next]]] = true;
            pinned[classId[rep[T]]]               = true;
            pinned[classId[rep[m.loops[T].next]]] = true;
        }
    }

    // -----------------------------------------------------------------------
    // 4.  No-pin guard — singular harmonic system without a fixed boundary.
    // -----------------------------------------------------------------------
    uint pinnedCount = 0;
    foreach (c; 0 .. nClasses) if (pinned[c]) pinnedCount++;
    if (pinnedCount == 0) return false;

    // Early-out: nothing left to relax.
    {
        bool any = false;
        foreach (c; 0 .. nClasses)
            if (!pinned[c] && nbr[c].length > 0) { any = true; break; }
        if (!any) return false;
    }

    // -----------------------------------------------------------------------
    // 5.  Initialise class UV positions from the current UV data.
    // -----------------------------------------------------------------------
    float[] upos = new float[](nClasses * 2);
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        upos[c * 2]     = data[L * 2];
        upos[c * 2 + 1] = data[L * 2 + 1];
    }

    // -----------------------------------------------------------------------
    // 6.  Gauss-Seidel passes (in-place — uses updated values immediately).
    // -----------------------------------------------------------------------
    foreach (_; 0 .. iterations) {
        foreach (c; 0 .. nClasses) {
            if (pinned[c]) continue;
            auto nbrc = nbr[c];
            auto wtc  = wt[c];
            if (nbrc.length == 0) continue;

            float totalW = 0.0f;
            float su = 0.0f, sv = 0.0f;
            foreach (i; 0 .. nbrc.length) {
                const uint nb = nbrc[i];
                const float w = wtc[i];
                su     += w * upos[nb * 2];
                sv     += w * upos[nb * 2 + 1];
                totalW += w;
            }
            if (totalW <= 0.0f) continue;  // zero-weight class → leave at seed
            upos[c * 2]     = su / totalW;
            upos[c * 2 + 1] = sv / totalW;
        }
    }

    // -----------------------------------------------------------------------
    // 7.  Scatter back — write only non-pinned classes; pinned bytes untouched.
    // -----------------------------------------------------------------------
    bool anyMoved = false;
    foreach (L; 0 .. nL) {
        const uint c = classId[rep[L]];
        if (pinned[c]) continue;
        const float uF = upos[c * 2];
        const float vF = upos[c * 2 + 1];
        if (data[L * 2] != uF || data[L * 2 + 1] != vF) {
            data[L * 2]     = uF;
            data[L * 2 + 1] = vF;
            anyMoved = true;
        }
    }
    return anyMoved;
}

// ---------------------------------------------------------------------------
// Distortion metrics (analytic, no side-effects).
// ---------------------------------------------------------------------------

/// Sum of per-corner |θ_uv − θ_3d| over all fan-triangulated faces.
/// NaN-safe: degenerate corners (zero-length edge in 3D or UV) contribute 0.
double uvAngularDistortion(const ref Mesh m, const float[] uvData)
{
    double total = 0.0;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        const size_t nc   = m.faces[fi].length;
        if (nc < 3) continue;
        const size_t base = m.faceLoop[fi];

        foreach (t; 0 .. nc - 2) {
            const size_t[3] ls = [base, base + t + 1, base + t + 2];

            foreach (ci; 0 .. 3) {
                const size_t la = ls[ci];
                const size_t lb = ls[(ci + 1) % 3];
                const size_t lc = ls[(ci + 2) % 3];

                // 3D angle at la.
                Vec3 pa = m.vertices[m.loops[la].vert];
                Vec3 pb = m.vertices[m.loops[lb].vert];
                Vec3 pc = m.vertices[m.loops[lc].vert];
                Vec3 e1 = pb - pa, e2 = pc - pa;
                const float l1 = sqrt(e1.x*e1.x + e1.y*e1.y + e1.z*e1.z);
                const float l2 = sqrt(e2.x*e2.x + e2.y*e2.y + e2.z*e2.z);
                if (l1 < 1e-10f || l2 < 1e-10f) continue;
                float cos3d = dot(e1, e2) / (l1 * l2);
                if (cos3d < -1.0f) cos3d = -1.0f;
                if (cos3d >  1.0f) cos3d =  1.0f;
                const double theta3d = acos(cos3d);

                // UV angle at la.
                const float ua = uvData[la * 2], va_ = uvData[la * 2 + 1];
                const float ub = uvData[lb * 2], vb  = uvData[lb * 2 + 1];
                const float uc = uvData[lc * 2], vc  = uvData[lc * 2 + 1];
                const float uv_e1x = ub - ua, uv_e1y = vb - va_;
                const float uv_e2x = uc - ua, uv_e2y = vc - va_;
                const float uv_l1 = sqrt(uv_e1x*uv_e1x + uv_e1y*uv_e1y);
                const float uv_l2 = sqrt(uv_e2x*uv_e2x + uv_e2y*uv_e2y);
                if (uv_l1 < 1e-10f || uv_l2 < 1e-10f) continue;
                float cosUV = (uv_e1x*uv_e2x + uv_e1y*uv_e2y) / (uv_l1 * uv_l2);
                if (cosUV < -1.0f) cosUV = -1.0f;
                if (cosUV >  1.0f) cosUV =  1.0f;
                const double thetaUV = acos(cosUV);

                total += fabs(thetaUV - theta3d);
            }
        }
    }
    return total;
}

/// Cotan-weighted discrete Dirichlet (conformal) energy: Σ w_ij · |uv_i − uv_j|²
/// over all unique edge pairs from fan triangulation.  This is the quantity
/// `uvUnwrap`'s Gauss-Seidel minimizes monotonically (SPD system + Dirichlet BCs).
double uvDirichletEnergy(const ref Mesh m, const float[] uvData)
{
    double E = 0.0;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        const size_t nc   = m.faces[fi].length;
        if (nc < 3) continue;
        const size_t base = m.faceLoop[fi];

        foreach (t; 0 .. nc - 2) {
            const size_t la = base;
            const size_t lb = base + t + 1;
            const size_t lc = base + t + 2;

            Vec3 pa = m.vertices[m.loops[la].vert];
            Vec3 pb = m.vertices[m.loops[lb].vert];
            Vec3 pc = m.vertices[m.loops[lc].vert];

            const float cot_a = cotClamp(pb - pa, pc - pa);
            const float cot_b = cotClamp(pa - pb, pc - pb);
            const float cot_c = cotClamp(pa - pc, pb - pc);

            const float ua = uvData[la * 2], va_ = uvData[la * 2 + 1];
            const float ub = uvData[lb * 2], vb  = uvData[lb * 2 + 1];
            const float uc = uvData[lc * 2], vc  = uvData[lc * 2 + 1];

            const float dab_u = ua - ub, dab_v = va_ - vb;
            const float dac_u = ua - uc, dac_v = va_ - vc;
            const float dbc_u = ub - uc, dbc_v = vb  - vc;

            // Each cot weights its opposite edge.
            E += 0.5 * cot_c * (dab_u*dab_u + dab_v*dab_v);  // cot_c → edge (a,b)
            E += 0.5 * cot_b * (dac_u*dac_u + dac_v*dac_v);  // cot_b → edge (a,c)
            E += 0.5 * cot_a * (dbc_u*dbc_u + dbc_v*dbc_v);  // cot_a → edge (b,c)
        }
    }
    return E;
}

// ---------------------------------------------------------------------------
// Module unittests — run by `dub test --config=modeling`.
// ---------------------------------------------------------------------------

unittest {
    // "Tent" fixture: 3×3 quad grid with center vertex v4 lifted in Z.
    // Seed UV: planar axis=Z (u=x, v=y for each vertex).
    // Perturbation: v4's 4 corner loops moved to (0.2, 0.8) — away from
    //   the energy minimum.
    // After 30 GS passes:
    //   - Dirichlet energy drops (primary, provable contract).
    //   - Angular distortion drops (correlated on this fixture).
    //   - No NaN/Inf.
    //   - Consistent signed-area sign (no foldover).
    //   - Interior UV within boundary bbox.
    //   - Boundary loops byte-unchanged.

    import mesh        : Mesh, MeshMap, MapDomain, kUvMapName;
    import math        : Vec3;
    import std.math    : isNaN, isInfinity, fabs;
    import std.format  : format;
    import std.algorithm : canFind;

    enum float h = 1.5f;   // lift height for v4 — large enough to create distortion

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,h), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    // Seed: planar axis=Z → u=x, v=y
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // v4 appears at: corner 2 of face 0, corner 3 of face 1,
    //                corner 1 of face 2, corner 0 of face 3.
    const size_t cL0 = m.faceCornerLoop(0, 2);
    const size_t cL1 = m.faceCornerLoop(1, 3);
    const size_t cL2 = m.faceCornerLoop(2, 1);
    const size_t cL3 = m.faceCornerLoop(3, 0);
    assert(cL0 != size_t.max && cL1 != size_t.max
        && cL2 != size_t.max && cL3 != size_t.max,
        "center-vertex corner loops must be valid");

    // Perturb all four center corners far from the minimum.
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        uvMap.data[cl * 2]     = 0.2f;
        uvMap.data[cl * 2 + 1] = 0.8f;
    }

    // Snapshot boundary UVs before relax.
    const float[] savedData = uvMap.data.dup;

    // Measure pre-relax distortion.
    const double E0   = uvDirichletEnergy(m, uvMap.data);
    const double ang0 = uvAngularDistortion(m, uvMap.data);

    // Run kernel (seams=boundary only → null seamLoop).
    const bool moved = uvUnwrap(m, uvMap, 30, null, null);
    assert(moved, "tent with perturbed center: uvUnwrap must return true");

    const double E1   = uvDirichletEnergy(m, uvMap.data);
    const double ang1 = uvAngularDistortion(m, uvMap.data);

    // Primary: Dirichlet energy drops (provable per-pass monotone contract).
    assert(E1 < E0,
           format("Dirichlet energy must decrease: E0=%g E1=%g", E0, E1));

    // Correlated: angular distortion drops on this fixture.
    assert(ang1 < ang0,
           format("angular distortion must decrease: ang0=%g ang1=%g", ang0, ang1));

    // No NaN / Inf in any UV component.
    foreach (L; 0 .. m.loops.length) {
        const float u = uvMap.data[L * 2];
        const float v = uvMap.data[L * 2 + 1];
        assert(!isNaN(u) && !isInfinity(u),
               format("loop %d u is NaN/Inf: %g", L, u));
        assert(!isNaN(v) && !isInfinity(v),
               format("loop %d v is NaN/Inf: %g", L, v));
    }

    // Consistent signed-area sign (no foldover) — check all UV triangles.
    // Fan-triangulate each face in UV.
    {
        int signFirst = 0;
        bool ok = true;
        outer: foreach (uint fi; 0 .. cast(uint) m.faces.length) {
            const size_t nc   = m.faces[fi].length;
            const size_t base = m.faceLoop[fi];
            foreach (t; 0 .. nc - 2) {
                size_t la = base, lb = base+t+1, lc = base+t+2;
                float ua = uvMap.data[la*2], va_ = uvMap.data[la*2+1];
                float ub = uvMap.data[lb*2], vb  = uvMap.data[lb*2+1];
                float uc = uvMap.data[lc*2], vc  = uvMap.data[lc*2+1];
                float area2 = (ub-ua)*(vc-va_) - (uc-ua)*(vb-va_);
                int sgn = area2 > 1e-9f ? 1 : (area2 < -1e-9f ? -1 : 0);
                if (sgn == 0) continue;
                if (signFirst == 0) { signFirst = sgn; }
                else if (sgn != signFirst) { ok = false; break outer; }
            }
        }
        assert(ok, "UV triangles must have consistent orientation (no foldover)");
    }

    // Interior UVs within boundary bbox: u ∈ [0,2], v ∈ [0,2].
    const size_t[] centerLoops = [cL0, cL1, cL2, cL3];
    foreach (L; 0 .. m.loops.length) {
        if (!centerLoops.canFind(L)) continue;   // skip boundary
        const float u = uvMap.data[L * 2];
        const float v = uvMap.data[L * 2 + 1];
        assert(u >= -1e-6f && u <= 2.0f + 1e-6f,
               format("interior u out of boundary bbox: %g", u));
        assert(v >= -1e-6f && v <= 2.0f + 1e-6f,
               format("interior v out of boundary bbox: %g", v));
    }

    // Boundary loops must be byte-unchanged (pinned → never written).
    foreach (L; 0 .. m.loops.length) {
        if (centerLoops.canFind(L)) continue;
        assert(uvMap.data[L * 2]     == savedData[L * 2],
               format("boundary u changed at loop %d", L));
        assert(uvMap.data[L * 2 + 1] == savedData[L * 2 + 1],
               format("boundary v changed at loop %d", L));
    }
}

unittest {
    // No-pin guard: closed mesh (cube) + continuous seed → zero pinned classes
    // → uvUnwrap must return false (no collapse).
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName, makeCube;
    import math : Vec3;

    auto m = makeCube();
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);

    // Seed: planar axis=Z, continuous (no UV seams → no pinned classes).
    // Assign u=x, v=y for every loop vertex.
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    const float[] before = uvMap.data.dup;
    const bool moved = uvUnwrap(m, uvMap, 30, null, null);
    assert(!moved,
           "closed mesh + continuous seed: uvUnwrap must return false (no-pin guard)");
    assert(uvMap.data == before,
           "no-pin guard: UV data must be byte-unchanged");
}

unittest {
    // Seam cut: mark one interior edge as a seam → those corners get pinned.
    // With the entire grid's interior pinned via seam, nothing relaxes → false.
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
    import math : Vec3;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // Mark ALL interior loops as seams → every class is pinned.
    bool[] seams = new bool[](m.loops.length);
    foreach (L; 0 .. m.loops.length)
        if (m.loops[L].twin != uint.max) seams[L] = true;

    // Perturb center to ensure relax would fire if not all-pinned.
    const size_t cl0 = m.faceCornerLoop(0, 2);
    uvMap.data[cl0 * 2] = 0.3f;

    const float[] before = uvMap.data.dup;
    const bool moved = uvUnwrap(m, uvMap, 10, seams, null);
    assert(!moved,
           "all-seam interior: uvUnwrap must return false when nothing can relax");
    assert(uvMap.data == before, "all-seam: UV data must be byte-unchanged");
}
