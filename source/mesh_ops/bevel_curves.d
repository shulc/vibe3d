module mesh_ops.bevel_curves;

// ---------------------------------------------------------------------------
// Edge-bevel curve math: the boundary-Bezier / fillet-rail laws and the two
// junction Gregory-ring evaluators. Pure functions of their arguments — no
// Mesh, no topology, no selection, no allocation beyond the output arrays.
//
// Split out of source/mesh_ops/bevel.d (task 0717, audit 0678 §2B-M2 step A).
// Bodies are a verbatim cut/paste; the only edits are the dedent and dropping
// the `static` keyword, which a module-level function cannot carry. Three of
// these were nested inside `bevelEdgesByMask` and one was a `static` member of
// Mesh — an extraction cannot avoid making them module-visible, and that
// widening is the whole (and only) API consequence of this commit.
//
// Why they are worth their own module: they are the part of the bevel family
// that a reader can check against the derivation without holding a mesh in
// their head, and the part a future evaluator change has to touch first.
// ---------------------------------------------------------------------------

import math;


// ---------------------------------------------------------------------------
// boundaryBezier + the finding-(I) rail law (roundCenter/roundPos0/roundPos)
// ---------------------------------------------------------------------------
// finding (F) boundary-Bézier handles for one N-way hub side: the
// kappa-cubic-Bézier circular-arc approximation from corner `P0` to
// corner `P3`, pivoted around `jv` (the shared selected edge's slide
// point, NOT the junction vertex). Direct port of
// `nway_hub_ring_ref.py::boundary_bezier`. `ok=false` on any
// degeneracy (parallel radii, zero sweep) so the caller falls back to
// the slerp rail + flat cap (compute-then-commit, no partial mutation).
void boundaryBezier(Vec3 P0, Vec3 P3, Vec3 jv,
                           out Vec3 outP1, out Vec3 outP2, out bool ok) {
    import std.math : acos, tan, abs;
    ok = false;
    Vec3 uA = P0 - jv, uB = P3 - jv;
    immutable float lA0 = uA.length, lB0 = uB.length;
    if (lA0 < 1e-9f || lB0 < 1e-9f) return;
    uA = uA / lA0; uB = uB / lB0;
    Vec3 nrm = cross(uA, uB);
    immutable float nlen = nrm.length;
    if (nlen < 1e-9f) return;              // uA ∥ uB (collinear pivot)
    nrm = nrm / nlen;
    immutable Vec3 d1 = cross(uA, nrm);
    immutable Vec3 d2 = cross(nrm, uB);
    immutable float denom = dot(cross(d1, d2), nrm);
    if (abs(denom) < 1e-12f) return;
    immutable float t = dot(cross(P3 - P0, d2), nrm) / denom;
    immutable Vec3 C = P0 + d1 * t;
    immutable Vec3 rA = P0 - C, rB = P3 - C;
    immutable float lenA = rA.length, lenB = rB.length;
    if (lenA < 1e-9f || lenB < 1e-9f) return;
    float cosO = dot(rA, rB) / (lenA * lenB);
    if (cosO >  1.0f) cosO =  1.0f;
    if (cosO < -1.0f) cosO = -1.0f;
    immutable float Omega = acos(cosO);
    if (Omega < 1e-6f) return;
    immutable float kappa = (4.0f / 3.0f) * tan(Omega / 4.0f);
    immutable Vec3 uAc = rA / lenA, uBc = rB / lenB;
    Vec3 t0 = uBc - uAc * dot(uBc, uAc);
    immutable float t0l = t0.length;
    if (t0l < 1e-9f) return;
    t0 = t0 / t0l;
    Vec3 t3 = uAc - uBc * dot(uAc, uBc);
    immutable float t3l = t3.length;
    if (t3l < 1e-9f) return;
    t3 = t3 / t3l;
    outP1 = P0 + t0 * (kappa * lenA);
    outP2 = P3 + t3 * (kappa * lenB);
    ok = true;
}
// finding (I) emitted-rail law — the actual mesh rail vertex a Round
// Level≥1 N-way junction writes, distinct from the internal Gregory net's
// boundary Bézier above (which misses it by ~0.01–0.03). Direct port of
// `nway_hub_ring_ref.py::_round_center`/`_round_pos0`/`_round_pos`,
// recovered via rr/gdb tracing of the reference's own fillet-center /
// rail-position builders. `roundCenter` = the ALREADY-SHIPPED K1/K2 two-tangent-line
// fillet centre reused verbatim (valid because |jv−V|==width for both
// pivots).
Vec3 roundCenter(Vec3 p0, Vec3 p1, Vec3 V) {
    import std.math : abs;
    immutable Vec3 dA = V - p0, dB = V - p1;
    immutable float w2 = dot(dA, dA);
    immutable float denom = w2 + dot(dA, dB);
    immutable float k = (abs(denom) > 1e-12f) ? (w2 / denom) : 1.0f;
    return V - (dA + dB) * k;
}
// One-sided rail sample: forward from `a1` towards `a2` by `t`, with the
// `deltaA`/`deltaB` correction blended by sin(rotAngle) (NOT linear-t —
// the L1-only formula's coincidence at t=0.5 does not generalize, see
// finding (I) follow-up).
Vec3 roundPos0(Vec3 a1, Vec3 a2, Vec3 a3, Vec3 a4, Vec3 V, float t) {
    import std.math : acos, sin;
    immutable Vec3 axisR = cross(V - a2, V - a1);
    immutable float la1 = (V - a1).length, la2 = (V - a2).length;
    // Degenerate frame: the two neighbor pivots are (near-)collinear with
    // V — the arc plane is undefined (sin(angle) < 1e-3). This happens at
    // a hub with two antipodal rays (e.g. an interior cube edge running
    // straight through the junction): the two rails PERPENDICULAR to that
    // edge take the antipodal pivots. The reference falls back to LINEAR
    // interpolation between the corners here — the same degenerate
    // fallback the K1 free-end fillet takes at a planar valence-4 ring
    // (`mixed_junction_freeend_findings.md` §e) and the slerp path takes
    // at a 180° sweep. Endpoints stay bit-exact (t=0→a3, t=1→a4).
    if (la1 < 1e-12f || la2 < 1e-12f || axisR.length < 1e-3f * la1 * la2)
        return a3 * (1.0f - t) + a4 * t;
    immutable Vec3 C = roundCenter(a1, a2, V);
    immutable Vec3 axis = axisR;
    immutable Vec3 rA = a1 - C, rB = a2 - C;
    immutable float lA = rA.length, lB = rB.length;
    float cosO = (lA > 1e-12f && lB > 1e-12f) ? dot(rA, rB) / (lA * lB) : 1.0f;
    if (cosO >  1.0f) cosO =  1.0f;
    if (cosO < -1.0f) cosO = -1.0f;
    immutable float Omega = acos(cosO);
    immutable float rotAngle = t * Omega;
    // `axis` here is the raw cross product — `safeNormalize` at the call
    // boundary is what math.rotateAboutAxis's unit contract requires
    // (the guard at :611 already rejected the near-zero case).
    immutable Vec3 virtMid = C + rotateAboutAxis(rA, safeNormalize(axis), rotAngle);
    immutable Vec3 deltaA = a3 - a1, deltaB = a4 - a2;
    immutable float sinR = sin(rotAngle);
    return virtMid + deltaA * (1.0f - sinR) + deltaB * sinR;
}
// Full rail-interior sample at parameter `t` (t=j/(2L)): blends the
// forward call (from `jvPrev`/`cornerK` at t) with the backward call
// (from `jvNext`/`cornerK1` at 1−t, all four swapped) by (1−t, t).
// `roundPos` is symmetric under the full endpoint swap with t→1−t, so
// canonical a→b sampling is orientation-independent (matches the slerp
// path's a<b reversal contract in `railInterior`).
Vec3 roundPos(Vec3 jvPrev, Vec3 jvNext, Vec3 cornerK, Vec3 cornerK1,
                     Vec3 V, float t) {
    immutable Vec3 f1 = roundPos0(jvPrev, jvNext, cornerK, cornerK1, V, t);
    immutable Vec3 f2 = roundPos0(jvNext, jvPrev, cornerK1, cornerK, V, 1.0f - t);
    return f1 * (1.0f - t) + f2 * t;
}

// ---------------------------------------------------------------------------
// junctionRing  — N=3 Gregory ring
// ---------------------------------------------------------------------------
// Full N=3 junction Gregory ring, GENERAL Round Level (task 0435,
// gregory_evaluator_findings + twist_reduction_findings). Each side is a
// standard rational bicubic Gregory patch (Gregory 1974 / Chiyokura–
// Kimura) whose entire 20-cell control net — the 12 boundary/spoke cells
// AND the 4 rational twist cells — is closed-form in the boundary Béziers
// + the R/Q/newC/HUB laws (all from the 3 poles). Samples it on the
// level-L grid ((u,v) ∈ {0,1/L,…,1}², the ref subdivides an arc into 2·L
// equal segments so the sub-quad boundary reuses the true-arc rail
// interiors 1:1). Outputs:
//   spokePts[i*(L-1)+(k-1)]              = R_i→HUB spoke point at t=k/L
//     (patch boundary, plain cubic Bézier — shared with the neighbour);
//   interiorPts[i*(L-1)^2+(b-1)*(L-1)+(a-1)] = rational eval at (a/L,b/L).
// Validated bit-exact vs the reference from raw geometry
// (k3_ring_raw_geometry_ref.py). N=3 only.
bool junctionRing(const(Vec3)[] poles, const(Vec3)[] p1s,
                         const(Vec3)[] p2s, int L,
                         out Vec3 hub, out Vec3[] spokePts, out Vec3[] interiorPts) {
    if (poles.length != 3 || p1s.length != 3 || p2s.length != 3 || L < 1)
        return false;
    // TRUE boundary curve per side (finding F): the caller supplies each
    // side's boundary-Bézier control points P0/P1/P2 (P3_i == P0_{i+1}),
    // built in `registerRail` from the shared-edge slide-point pivot — the
    // SAME construction the general N≥4 builder (`junctionRingN`) consumes.
    // R_i is the boundary Bézier at t=0.5 = (P0+3P1+3P2+P3)/8. This
    // REPLACES the former circumcircle re-fit through pole_i/rail-mid/
    // pole_{i+1}, which matched the reference only at the 90° cube corner
    // (where the emitted rail-mid coincides with the true boundary mid) and
    // bulged the hub for any non-cube K3 hub — task 0435 follow-up. The
    // emitted mesh rail stays K3's own slerp arc (threaded by the caller,
    // sampled via `hasArcCenter`); R_i here feeds ONLY the hub + interior/
    // spoke solve below. Twist cells + evaluator are UNCHANGED (the N=3
    // fast path — no odd-N center-normal / corner-move corrections).
    Vec3[3] P1, P2, R, Q, newC;
    foreach (i; 0 .. 3) {
        P1[i] = p1s[i];
        P2[i] = p2s[i];
        R[i]  = (poles[i] + p1s[i] * 3.0f + p2s[i] * 3.0f + poles[(i + 1) % 3]) * 0.125f;
    }
    Vec3 hsum = Vec3(0, 0, 0);
    foreach (i; 0 .. 3) {
        Q[i] = R[i] + ((P2[(i + 2) % 3] - poles[i])
                     + (P1[(i + 1) % 3] - poles[(i + 1) % 3])) * 0.25f;
        hsum = hsum + (Q[i] * 1.5f - R[i] * 0.5f);
    }
    hub = hsum / 3.0f;
    foreach (i; 0 .. 3) newC[i] = (Q[i] * 1.5f - R[i] * 0.5f) * (2.0f / 3.0f) + hub / 3.0f;
    // Per-side twist cells (closed-form) + the 12 fixed cells.
    Vec3[3] p10, p20, p01, p02, F16, F17, F5, F9, F6, F18, F10;
    foreach (i; 0 .. 3) {
        immutable int pv = (i + 2) % 3, nx = (i + 1) % 3;
        immutable Vec3 P0i = poles[i];
        immutable Vec3 DA = P2[pv] - P0i,             DB  = P1[nx] - poles[nx];
        immutable Vec3 DAp = P2[(pv + 2) % 3] - poles[pv], DBp = P1[i] - P0i;
        immutable Vec3 DT  = DA * (2.0f / 3.0f) + DB * (1.0f / 3.0f);
        immutable Vec3 DU  = DA * (1.0f / 3.0f) + DB * (2.0f / 3.0f);
        immutable Vec3 DTp = DAp * (2.0f / 3.0f) + DBp * (1.0f / 3.0f);
        immutable Vec3 DUp = DAp * (1.0f / 3.0f) + DBp * (2.0f / 3.0f);
        p10[i] = (P0i + P1[i]) * 0.5f;
        p20[i] = (P0i + P1[i] * 2.0f + P2[i]) * 0.25f;
        p01[i] = (P2[pv] + P0i) * 0.5f;
        p02[i] = (P1[pv] + P2[pv] * 2.0f + P0i) * 0.25f;
        F16[i] = p10[i] + (DA + DT) * 0.25f;
        F17[i] = p20[i] + (DA + DU) * 0.125f + DT * 0.25f;
        F5[i]  = p01[i] + (DBp + DUp) * 0.25f;
        F9[i]  = p02[i] + (DTp + DBp) * 0.125f + DUp * 0.25f;
        F6[i]  = F17[i] + (Q[i]  - R[i])  * (1.0f / 6.0f);
        F18[i] = F9[i]  + (Q[pv] - R[pv]) * (1.0f / 6.0f);
        F10[i] = (newC[i] + newC[pv] - newC[nx]) * 4.0f / 3.0f
               + (Q[nx] - Q[i] - Q[pv]) / 3.0f;
    }
    static float[4] bern(float t) {
        immutable float s = 1.0f - t;
        return [s*s*s, 3.0f*t*s*s, 3.0f*t*t*s, t*t*t];
    }
    // Rational bicubic Gregory eval of sub-quad i at (u,v).
    Vec3 evalSub(int i, float u, float v) {
        immutable int pv = (i + 2) % 3;
        Vec3 blend(Vec3 a, Vec3 b, float wa, float wb) {
            immutable float den = wa + wb;
            return den > 1e-9f ? (a * wa + b * wb) / den : (a + b) * 0.5f;
        }
        immutable Vec3 p11 = blend(F16[i], F5[i],  u, v);
        immutable Vec3 p12 = blend(F18[i], F9[i],  u, 1.0f - v);
        immutable Vec3 p21 = blend(F17[i], F6[i],  1.0f - u, v);
        // g[a][b] = grid[(a,b)], a=u-index, b=v-index.  v=0 edge (b=0) is
        // pole→R_i; u=0 edge (a=0) is pole→R_prev; u=1 (a=3) is the
        // R_i→HUB spoke; v=1 (b=3) is the R_prev→HUB spoke.
        immutable Vec3[4][4] g = [
            [poles[i], p01[i],  p02[i],   R[pv]   ],
            [p10[i],   p11,     p12,      Q[pv]   ],
            [p20[i],   p21,     F10[i],   newC[pv]],
            [R[i],     Q[i],    newC[i],  hub     ],
        ];
        immutable float[4] Bu = bern(u), Bv = bern(v);
        Vec3 acc = Vec3(0, 0, 0);
        foreach (a; 0 .. 4) foreach (b; 0 .. 4) acc = acc + g[a][b] * (Bu[a] * Bv[b]);
        return acc;
    }
    immutable int m = L - 1;                    // interior samples per axis
    spokePts.length    = 3 * m;
    interiorPts.length = 3 * m * m;
    immutable float inv = 1.0f / cast(float) L;
    foreach (i; 0 .. 3) {
        foreach (k; 1 .. L)                     // R_i→HUB spoke at u=1
            spokePts[i * m + (k - 1)] = evalSub(i, 1.0f, k * inv);
        foreach (b; 1 .. L) foreach (a; 1 .. L)
            interiorPts[i * m * m + (b - 1) * m + (a - 1)] = evalSub(i, a * inv, b * inv);
    }
    return true;
}

// ---------------------------------------------------------------------------
// junctionRingN — general N-sided Gregory ring
// ---------------------------------------------------------------------------
// GENERAL N-sided junction Gregory ring (N≥4, task 0454). The N-sided
// reference path (the reference's N-sided patch solve) is a DIFFERENT
// evaluator than N=3's fast path, recovered capture-free
// (toolcards/edge.bevel/nway_hub_ring_ref.py, findings A/B/E/F/H). Unlike
// `junctionRing` (which re-fits each boundary Bézier from a circumcircle
// through pole_i/R_i/pole_{i+1} — the N=3 reconstruction), this builder
// takes the TRUE boundary-Bézier control points P0/P1/P2 per side
// (finding F, from `boundaryBezier`, the same curve the rail samples).
//   R_i    = boundary Bézier at t=0.5 = (P0+3P1+3P2+P0_next)/8
//   Q/C/HUB/newC + F16/F17/F5/F9      = SAME closed forms as N=3, mod N
//   F6/F10/F18/F19 (twist)            = closed-form affine for EVEN N;
//     for ODD N the finding-(H) closed-form recurrence W0=½·Σ(−1)^j·c_j
//     (exact decomposition of the reference's sparse (4N)×(4N) system —
//     NO dense solver, dodges the O(N³)/allocation DoS).
//   newC_i's TRUE final value (task 0453, finding J) = the plain hub-law
//     value above, THEN the center-normal planar projection (EVERY
//     N), THEN — odd N only — the odd-N corner-move sin-angle magnitude
//     recurrence. Both ported below; odd N is now reference-parity at
//     every Round Level, not just L1.
//   evaluator: identical to N=3 EXCEPT the p22 grid cell is
//     avg(F10_i, F19_i) (finding D — for N=3 F10==F19 so it was moot).
bool junctionRingN(const(Vec3)[] poles, const(Vec3)[] p1s,
                          const(Vec3)[] p2s, int N, int L,
                          out Vec3 hub, out Vec3[] spokePts, out Vec3[] interiorPts) {
    import std.math : abs, sqrt;
    if (cast(int)poles.length != N || cast(int)p1s.length != N ||
        cast(int)p2s.length != N || N < 4 || L < 1) return false;
    int nxt(int i) { return (i + 1) % N; }
    int prv(int i) { return (i + N - 1) % N; }

    Vec3[] R = new Vec3[](N);
    foreach (i; 0 .. N)
        R[i] = (poles[i] + p1s[i] * 3.0f + p2s[i] * 3.0f + poles[nxt(i)]) * 0.125f;
    Vec3 DA(int i) { return p2s[prv(i)] - poles[i]; }
    Vec3 DB(int i) { return p1s[nxt(i)] - poles[nxt(i)]; }
    Vec3[] Qv = new Vec3[](N);
    foreach (i; 0 .. N) Qv[i] = R[i] + (DA(i) + DB(i)) * 0.25f;
    Vec3 hsum = Vec3(0, 0, 0);
    Vec3[] Cv = new Vec3[](N);
    foreach (i; 0 .. N) { Cv[i] = Qv[i] * 1.5f - R[i] * 0.5f; hsum = hsum + Cv[i]; }
    hub = hsum / cast(float)N;
    Vec3[] newCv = new Vec3[](N);
    foreach (i; 0 .. N) newCv[i] = (Cv[i] * 2.0f + hub) / 3.0f;

    // --- task 0453, finding (J): newC_i's TRUE final value is a
    // TWO-STAGE correction of the plain hub-law value just computed,
    // ported bit-for-bit from `center_normal_project`/`move_points_odd_N`
    // in toolcards/edge.bevel/nway_hub_ring_ref.py (private reference,
    // recovered from the reference's center-normal + odd-N corner-move steps).
    //
    // Stage 1 — center-normal projection: planar-projects the WHOLE newC
    // ring onto ONE common plane through hub. Runs UNCONDITIONALLY for
    // every N (even AND odd) — NOT gated on parity, unlike Stage 2
    // below. A near-no-op (~1e-17) on the near-planar rings every
    // existing K4/K5/K6 fixture happens to have (so those stay
    // byte-identical); a REAL correction (0.0018-0.0072 absolute in the
    // reference's own units) once the ring is genuinely non-planar
    // (the K5-asymmetric parity fixtures below exercise this).
    // crossN_i must read every side's ORIGINAL (pre-projection) newC —
    // both at i and i-1 — so snapshot first: this pass's own writes
    // (below) must never be read back by a later i in the SAME pass.
    // Factored into the sibling `centerNormalProject` method (below
    // `bevelEdgesByMask`) so the geometric invariant it establishes —
    // every projected point satisfies dot(p-hub, Navg)~=0 — can be
    // unit-tested directly on a hand-built ring (see the property
    // unittest near the K5-asymmetric parity fixtures).
    centerNormalProject(N, hub, newCv);
    // Stage 2 — odd-N corner-move: ODD N ONLY. Takes Stage 1's OUTPUT
    // and replaces every newC_i's hub-relative MAGNITUDE (keeping its
    // DIRECTION exactly) via a multiplicative sin-of-turning-angle
    // recurrence around the full N-cycle: forward-ADJACENT (i,i+1)
    // pairing, stepping +2 mod N (visits every index exactly once
    // since gcd(2,N)=1 for odd N — this monodromy IS why the branch is
    // odd-N-only, the same structure as the twist-solve's own
    // W_{i+1}=-W_i+c_i recurrence above). The (i,i+1)-forward pairing
    // was PINNED — not just consistent — by a fresh K5-ASYMMETRIC
    // reference capture (gate A4): 4 wrong-pairing variants
    // (backward-neighbour, skip-one, reversed recurrence, combined)
    // all measured 1.4e-5-2.6e-5 off on that capture; this one hits
    // 1.4e-17-2.0e-17 (machine epsilon). See
    // toolcards/edge.bevel/nway_hub_law_findings.md finding (J).
    if (N % 2 != 0) {
        Vec3[] D = new Vec3[](N);
        float[] S = new float[](N);
        Vec3[] u = new Vec3[](N);
        foreach (i; 0 .. N) {
            D[i] = newCv[i] - hub;
            S[i] = sqrt(2.0f * (abs(D[i].x) + abs(D[i].y) + abs(D[i].z)));
            u[i] = (S[i] > 1e-9f) ? D[i] / S[i] : D[i];
        }
        float[] sinAdj = new float[](N);
        foreach (i; 0 .. N) {
            immutable float dp = dot(u[i], u[nxt(i)]);
            sinAdj[i] = sqrt(abs(1.0f - dp * dp));
        }
        float[] w = new float[](N);
        w[0] = 1.0f;
        {
            int idx = 0;
            foreach (k; 0 .. N) {
                immutable int p = nxt(idx);
                immutable int q = (idx + 2) % N;
                w[q] = w[idx] * sinAdj[idx] / sinAdj[p];
                idx = q;
            }
        }
        float meanW = 0.0f, meanS = 0.0f;
        foreach (i; 0 .. N) { meanW += w[i]; meanS += S[i]; }
        meanW /= cast(float)N;
        meanS /= cast(float)N;
        immutable float scale = (abs(meanW) > 1e-9f) ? meanS / meanW : 1.0f;
        foreach (i; 0 .. N) w[i] *= scale;
        foreach (i; 0 .. N) newCv[i] = hub + u[i] * w[i];
    }

    Vec3 DT(int i) { return DA(i) * (2.0f / 3.0f) + DB(i) * (1.0f / 3.0f); }
    Vec3 DU(int i) { return DA(i) * (1.0f / 3.0f) + DB(i) * (2.0f / 3.0f); }
    Vec3[] p10v = new Vec3[](N), p20v = new Vec3[](N),
           p01v = new Vec3[](N), p02v = new Vec3[](N);
    foreach (i; 0 .. N) {
        immutable int pv = prv(i);
        p10v[i] = (poles[i] + p1s[i]) * 0.5f;
        p20v[i] = (poles[i] + p1s[i] * 2.0f + p2s[i]) * 0.25f;
        p01v[i] = (p2s[pv] + poles[i]) * 0.5f;
        p02v[i] = (p1s[pv] + p2s[pv] * 2.0f + poles[i]) * 0.25f;
    }
    Vec3[] F16v = new Vec3[](N), F17v = new Vec3[](N),
           F5v = new Vec3[](N), F9v = new Vec3[](N);
    foreach (i; 0 .. N) {
        immutable int pv = prv(i);
        F16v[i] = p10v[i] + (DA(i) + DT(i)) * 0.25f;
        F17v[i] = p20v[i] + (DA(i) + DU(i)) * 0.125f + DT(i) * 0.25f;
        F5v[i]  = p01v[i] + (DB(pv) + DU(pv)) * 0.25f;
        F9v[i]  = p02v[i] + (DT(pv) + DB(pv)) * 0.125f + DU(pv) * 0.25f;
    }
    Vec3[] F13v = new Vec3[](N);
    foreach (i; 0 .. N) F13v[i] = Qv[prv(i)];

    Vec3[] F6v = new Vec3[](N), F10v = new Vec3[](N),
           F18v = new Vec3[](N), F19v = new Vec3[](N);
    if (N % 2 == 0) {
        // twist_fields_even_N — pure closed-form affine (the reference
        // statically branches AROUND the solve on `N&1`; there is no
        // linear system to reconstruct for even N).
        foreach (i; 0 .. N) {
            immutable int pv = prv(i);
            immutable Vec3 baseI = (newCv[i] - hub) * 0.5f + (Qv[i] - R[i]) * 0.5f;
            F10v[i] = baseI + newCv[pv] * (2.0f / 3.0f) + p20v[i] * (1.0f / 3.0f);
            F6v[i]  = baseI + newCv[pv] * (1.0f / 3.0f) + p20v[i] * (2.0f / 3.0f);
            immutable Vec3 baseP = (newCv[pv] - hub) * 0.5f + (Qv[pv] - R[pv]) * 0.5f;
            F18v[i] = baseP + p02v[i] * (2.0f / 3.0f) + newCv[i] * (1.0f / 3.0f);
            F19v[i] = baseP + p02v[i] * (1.0f / 3.0f) + newCv[i] * (2.0f / 3.0f);
        }
    } else {
        // twist_fields_odd_N via the finding-(H) closed-form recurrence
        // (D3). The reference's (4N)×(4N) system is 2 nonzeros/row (all
        // ±1): rows 4i+0/4i+2 solve LOCALLY (a 2×2 block per side); rows
        // 4i+1/4i+3 link all N sides in one circular chain
        // W_{i+1}=−W_i+c_i whose odd-N monodromy (−1)^N=−1 gives the
        // unique W_0=½·Σ(−1)^j·c_j. O(N), allocation-bounded, exact — no
        // np.linalg.solve, no math.d solver surface.
        Vec3[] rhs0 = new Vec3[](N), rhs1 = new Vec3[](N),
               rhs2 = new Vec3[](N), rhs3 = new Vec3[](N);
        foreach (i; 0 .. N) {
            immutable Vec3 a = newCv[i] - hub;
            immutable float numer = dot(a, (newCv[nxt(i)] - hub) + (newCv[prv(i)] - hub));
            immutable float den = 3.0f * dot(a, a);
            immutable float lam = (abs(den) > 1e-20f) ? numer / den : 0.0f;
            rhs0[i] = F9v[nxt(i)] - F17v[i];
            rhs1[i] = (Qv[i] - newCv[i]) * (2.0f * lam);
            rhs2[i] = (R[i] - Qv[i]) * lam;
            rhs3[i] = newCv[nxt(i)] - newCv[i];
        }
        Vec3[] X0 = new Vec3[](N), X1 = new Vec3[](N),
               X2 = new Vec3[](N), X3 = new Vec3[](N);
        foreach (i; 0 .. N) {
            X0[i] = (rhs0[i] - rhs2[i]) * 0.5f;
            X2[i] = (rhs0[i] + rhs2[i]) * 0.5f;
        }
        Vec3 wsum = Vec3(0, 0, 0);
        foreach (j; 0 .. N) {
            immutable Vec3 cj = rhs3[j] - rhs1[j];
            wsum = (j % 2 == 0) ? wsum + cj : wsum - cj;
        }
        X1[0] = wsum * 0.5f;
        foreach (i; 0 .. N - 1) X1[i + 1] = -X1[i] + (rhs3[i] - rhs1[i]);
        foreach (i; 0 .. N) X3[i] = X1[i] + rhs1[i];
        foreach (i; 0 .. N) {
            immutable int pv = prv(i);
            F6v[i]  = Qv[i]    - X0[i];
            F10v[i] = newCv[i] - X1[i];
            F18v[i] = X2[pv] + F13v[i];
            F19v[i] = X3[pv] + newCv[pv];
        }
    }

    static float[4] bern(float t) {
        immutable float s = 1.0f - t;
        return [s*s*s, 3.0f*t*s*s, 3.0f*t*t*s, t*t*t];
    }
    Vec3 evalSub(int i, float u, float v) {
        immutable int pv = prv(i);
        Vec3 blend(Vec3 a, Vec3 b, float wa, float wb) {
            immutable float den = wa + wb;
            return den > 1e-9f ? (a * wa + b * wb) / den : (a + b) * 0.5f;
        }
        immutable Vec3 p11 = blend(F16v[i], F5v[i], u, v);
        immutable Vec3 p12 = blend(F18v[i], F9v[i], u, 1.0f - v);
        immutable Vec3 p21 = blend(F17v[i], F6v[i], 1.0f - u, v);
        immutable Vec3 p22 = (F10v[i] + F19v[i]) * 0.5f;   // finding D
        immutable Vec3[4][4] g = [
            [poles[i], p01v[i], p02v[i], R[pv]  ],
            [p10v[i],  p11,     p12,     Qv[pv] ],
            [p20v[i],  p21,     p22,     newCv[pv]],
            [R[i],     Qv[i],   newCv[i], hub    ],
        ];
        immutable float[4] Bu = bern(u), Bv = bern(v);
        Vec3 acc = Vec3(0, 0, 0);
        foreach (a; 0 .. 4) foreach (b; 0 .. 4) acc = acc + g[a][b] * (Bu[a] * Bv[b]);
        return acc;
    }
    immutable int m = L - 1;
    spokePts.length    = N * m;
    interiorPts.length = N * m * m;
    immutable float inv = 1.0f / cast(float) L;
    foreach (i; 0 .. N) {
        foreach (k; 1 .. L)
            spokePts[i * m + (k - 1)] = evalSub(i, 1.0f, k * inv);
        foreach (b; 1 .. L) foreach (a; 1 .. L)
            interiorPts[i * m * m + (b - 1) * m + (a - 1)] = evalSub(i, a * inv, b * inv);
    }
    return true;
}

// ---------------------------------------------------------------------------
// centerNormalProject
// ---------------------------------------------------------------------------
/// The center-normal projection step (task 0453, finding J, Stage 1 of newC_i's
/// TRUE final value — see `junctionRingN`'s own call site for the full
/// derivation). Planar-projects the WHOLE `newCv` ring onto ONE common
/// plane through `hub`, mutating `newCv` in place. Runs UNCONDITIONALLY
/// for every N (even AND odd) — ported bit-for-bit from
/// `center_normal_project` in the private reference
/// (toolcards/edge.bevel/nway_hub_ring_ref.py), recovered from
/// full static disassembly of the reference's center-normal step. `crossN_i` must read
/// every side's ORIGINAL (pre-projection) `newCv` — both at `i` and
/// `i-1` — so this snapshots first: this pass's own writes must never be
/// read back by a later `i` in the SAME pass. Factored out of
/// `junctionRingN` (its sole caller) so the geometric invariant it
/// establishes — every projected point satisfies
/// `dot(p-hub, Navg)~=0` — can be unit-tested directly on a hand-built
/// ring (see the property unittest near the K5-asymmetric parity
/// fixtures) without needing a full bevel + reference dump.
void centerNormalProject(int N, Vec3 hub, Vec3[] newCv) {
    if (N < 1 || cast(int)newCv.length != N) return;
    int prv(int i) { return (i + N - 1) % N; }
    Vec3[] newCv0 = newCv.dup;
    Vec3 crossSum = Vec3(0, 0, 0);
    foreach (i; 0 .. N) {
        immutable Vec3 a = newCv0[prv(i)] - hub;
        immutable Vec3 b = newCv0[i] - hub;
        immutable Vec3 cr = cross(a, b);
        immutable float crLen = cr.length;
        if (crLen > 1e-12f) crossSum = crossSum + cr / crLen;
    }
    immutable float sumLen = crossSum.length;
    if (sumLen > 1e-12f) {
        immutable Vec3 Navg = crossSum / sumLen;
        foreach (j; 0 .. N) {
            immutable float t = dot(hub - newCv[j], Navg);
            newCv[j] = newCv[j] + Navg * t;
        }
    }
    // else: Navg degenerate (near-zero average ring normal) — leave
    // newCv unchanged, mirroring the reference's implicit non-degenerate
    // assumption (never hit on real, non-self-intersecting junction
    // geometry).
}
