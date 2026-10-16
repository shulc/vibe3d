module tests.unit.mesh_ops.cut_gap_regression_test;

import vibe3d.mesh.core.mesh;
import math;
import vibe3d.mesh.ops.mesh_ops.cut;
import subpatch_factories : subdivideCube;
import std.math : abs;

// ---------------------------------------------------------------------------
// cutByPlaneSplitGap unittests (task 0291) — shared predicates + the two
// kernel regression gates (Phase 1 axis-cube composition, Phase 3 CC×2
// oblique sliver). See doc/slice_gap_two_cut_plan.md.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.math : abs;

    // Component count via the same DSU-over-shared-vertices idiom as the
    // `boundaryEdgeCount`/`componentCount` locals in the cutByPlaneEx `split`
    // unittest above — walks every face (not just one island).
    private size_t sliceCapComponentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    // A "cap" face (for these tests) is one whose EVERY corner lies on ONE of
    // the two offset planes (`p + n*loAmt` or `p - n*hiAmt`), within `tol`. By
    // construction (capShellCycles seals exactly the loSet/hiSet crossing
    // verts) this is precise for both an axis-aligned cap (a quad, same
    // corner count as a side face — so a degree heuristic would not
    // discriminate it) and a curved oblique cap (a big N-gon).
    private uint[] sliceCapFaces(ref Mesh m, Vec3 p, Vec3 n, float loAmt, float hiAmt,
                                 float tol) {
        uint[] caps;
        foreach (fi, ref f; m.faces) {
            if (f.length == 0) continue;
            bool onLo = true, onHi = true;
            foreach (vi; f) {
                float dv = dot(n, m.vertices[vi] - p);
                if (abs(dv - loAmt) >= tol) onLo = false;
                if (abs(dv - (-hiAmt)) >= tol) onHi = false;
            }
            if (onLo || onHi) caps ~= cast(uint)fi;
        }
        return caps;
    }

    // Newell's method: a robust normal for a (possibly non-planar) polygon.
    private Vec3 sliceCapNewellNormal(ref Mesh m, uint fi) {
        Vec3 n = Vec3(0, 0, 0);
        const uint[] f = m.faces[fi];
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i + 1) % f.length]];
            n.x += (a.y - b.y) * (a.z + b.z);
            n.y += (a.z - b.z) * (a.x + b.x);
            n.z += (a.x - b.x) * (a.y + b.y);
        }
        return normalize(n);
    }

    private Vec3 sliceCapCentroid(ref Mesh m, uint fi) {
        Vec3 c = Vec3(0, 0, 0);
        const uint[] f = m.faces[fi];
        foreach (vi; f) c = c + m.vertices[vi];
        return c * (1.0f / cast(float) f.length);
    }

    // Max distance of any corner to the face's own best-fit plane (Newell
    // normal through the centroid). ~0 for a truly planar polygon — every
    // corner of a two-cut cap sits on a REAL edge∩plane intersection, so this
    // should be near machine precision on the fixed model.
    private float sliceCapPlanarityDev(ref Mesh m, uint fi) {
        Vec3 n = sliceCapNewellNormal(m, fi);
        Vec3 c = sliceCapCentroid(m, fi);
        float dev = 0.0f;
        foreach (vi; m.faces[fi]) {
            float d = abs(dot(n, m.vertices[vi] - c));
            if (d > dev) dev = d;
        }
        return dev;
    }

    // O(k^2) count of non-adjacent edge-pair crossings of the polygon
    // projected onto its own best-fit plane (an arbitrary in-plane basis ⟂ the
    // Newell normal) — a self-intersecting ("bowtie") n-gon has >=1. This is
    // exactly the sliver-cap symptom the task fixes (task file: 6
    // self-intersections per cap on the pre-fix single-cut+slide).
    private size_t sliceCapSelfX(ref Mesh m, uint fi) {
        const uint[] f = m.faces[fi];
        size_t k = f.length;
        if (k < 4) return 0;
        Vec3 n = sliceCapNewellNormal(m, fi);
        Vec3 arbitrary = (abs(n.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3 u = normalize(cross(n, arbitrary));
        Vec3 v = cross(n, u);
        auto pts = new double[2][](k);
        foreach (i; 0 .. k) {
            Vec3 p = m.vertices[f[i]];
            pts[i] = [cast(double) dot(p, u), cast(double) dot(p, v)];
        }
        static bool segCross(double[2] a, double[2] b, double[2] c, double[2] d) {
            double d1 = (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0]);
            double d2 = (b[0]-a[0])*(d[1]-a[1]) - (b[1]-a[1])*(d[0]-a[0]);
            double d3 = (d[0]-c[0])*(a[1]-c[1]) - (d[1]-c[1])*(a[0]-c[0]);
            double d4 = (d[0]-c[0])*(b[1]-c[1]) - (d[1]-c[1])*(b[0]-c[0]);
            return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
        }
        size_t crossings = 0;
        foreach (i; 0 .. k) {
            size_t i2 = (i + 1) % k;
            foreach (j; i + 1 .. k) {
                size_t j2 = (j + 1) % k;
                // Skip adjacent (and identical) edges — they legitimately
                // share an endpoint, which is not a crossing.
                if (j == i || j2 == i || j == i2) continue;
                if (segCross(pts[i], pts[i2], pts[j], pts[j2])) ++crossings;
            }
        }
        return crossings;
    }
}

unittest { // cutByPlaneSplitGap: axis-cube two-cut COMPOSITION gate (task 0291,
    // Phase 1) — proves cut 2 correctly re-splits cut 1's shell BEFORE trusting
    // the model on curved geometry (the crux, risk 1). Mid-plane cut (n=+X
    // through x=0) of a plain cube, gap 0.2 center (offset ±0.1).
    //
    // PRIMARY (structural): the two cuts fully SEPARATE the mesh (separated
    // == true, a band component was found and removed), leaving exactly 2
    // disconnected capped shells — componentCount==2, 12 faces / 16 verts
    // total (2 shells × [4 side quads + 1 original end face + 1 new cap]),
    // exactly 2 cap faces, and every surviving vertex is either an untouched
    // original corner (|dv| ≈ 0.5) or a seam vert exactly on ±0.1.
    //
    // SECONDARY (slab, with an eps margin so seam verts sitting exactly on
    // ±0.1 don't trip it): no vertex remains strictly INSIDE the removed
    // [-0.1,+0.1] band.
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    enum float G   = 0.2f;
    enum float OFF = G * 0.5f;   // 0.1

    bool separated;
    size_t n;
    {
        auto ed = MeshEditBatch.unrecorded(m, kCutEditScope);
        n = ed.cutByPlaneSplitGap(P, N, /*clipped*/false, P, P,
                                  /*caps*/true, G, /*gapSide*/0, separated);
        ed.close();
    }
    assert(n > 0, "the mid-plane must cut the 4 side faces (both cuts)");
    assert(separated, "a full mid-plane cut must fully separate the mesh");

    assert(sliceCapComponentCount(m) == 2, "band removed: exactly 2 shells left");
    assert(m.faces.length    == 12, "2 shells x (4 side + 1 original + 1 cap)");
    assert(m.vertices.length == 16, "2 shells x 8 verts (4 original + 4 cap-ring)");

    auto caps = sliceCapFaces(m, P, N, OFF, OFF, 1e-4f);
    assert(caps.length == 2, "exactly 2 cap faces (one per shell)");

    // Every surviving vertex is either an untouched original corner (dv≈±0.5)
    // or a seam vert exactly on one of the two offset planes (dv≈±0.1) — no
    // vertex should exist at any OTHER distance.
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        bool isOriginalCorner = abs(abs(dv) - 0.5f) < 1e-4f;
        bool isSeam           = abs(abs(dv) - OFF)  < 1e-4f;
        assert(isOriginalCorner || isSeam,
               "every surviving vertex must be an untouched original corner "
               ~ "or a seam vert exactly on ±offset");
    }

    enum float EPS_S = 1e-4f;
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        assert(!(dv > -OFF + EPS_S && dv < OFF - EPS_S),
               "band must be fully removed — no vertex left strictly inside the slab");
    }
}

unittest { // cutByPlaneSplitGap: CC×2 OBLIQUE sliver regression (task 0291,
    // Phase 3) — the reported bug: a single-cut + fixed along-edge slide grazes
    // existing verts on dense/curved geometry (a sliver), scattering the seam
    // off the cut plane and producing a self-intersecting cap (reference
    // captured owner case: the subdivided-edge gap is 0.415
    // center, TWO clean planar/simple caps). The two-cut model is
    // overshoot-immune (every seam sits on a REAL edge∩plane intersection), so
    // this is GREEN where the equivalent direct single-cut+slide call (the
    // characterization proven at Phase 0) is RED.
    //
    // PRIMARY (structural, robust to vibe3d's OSD connectivity not being
    // byte-identical to the reference's CC base — risk 5, so this does NOT
    // assert the reference's exact 40-seam/2-cap COUNTS): separated==true;
    // exactly 2 cap faces; each cap planarityDev≈0 AND selfX==0 (simple); the
    // band component is gone (componentCount==2).
    //
    // SECONDARY (with an eps margin so seam/graze verts sitting exactly on
    // ±offset don't trip it): no vertex remains strictly INSIDE the removed
    // slab.
    Mesh m = subdivideCube(2);
    m.resetSelection();

    Vec3 P = Vec3(0.0f, 0.4f, 0.61f);
    Vec3 N = normalize(Vec3(0.0f, -0.85142f, 0.52448f));
    enum float G   = 0.415f;
    enum float OFF = G * 0.5f;   // 0.2075

    bool separated;
    size_t n;
    {
        auto ed = MeshEditBatch.unrecorded(m, kCutEditScope);
        n = ed.cutByPlaneSplitGap(P, N, /*clipped*/false, P, P,
                                  /*caps*/true, G, /*gapSide*/0, separated);
        ed.close();
    }
    assert(n > 0, "the oblique plane must cut faces");
    assert(separated, "a full-span oblique cut must fully separate the mesh");
    assert(sliceCapComponentCount(m) == 2, "band removed: exactly 2 shells left");

    auto caps = sliceCapFaces(m, P, N, OFF, OFF, 1e-3f);
    assert(caps.length == 2, "exactly 2 cap faces (one per shell)");
    foreach (fi; caps) {
        assert(sliceCapPlanarityDev(m, fi) < 1e-3f,
               "two-cut cap must be planar (every corner is a real edge∩plane point)");
        assert(sliceCapSelfX(m, fi) == 0,
               "two-cut cap must be simple (no self-intersections) — the bug this fixes");
    }

    enum float EPS_S = 1e-4f;
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        assert(!(dv > -OFF + EPS_S && dv < OFF - EPS_S),
               "band must be fully removed — no vertex left strictly inside the slab");
    }
}

