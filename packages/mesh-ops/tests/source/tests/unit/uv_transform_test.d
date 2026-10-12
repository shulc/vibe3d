// Module unittests for `uv_transform`, moved verbatim out of source/uv_transform.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_transform_test;

import mesh : Mesh, MeshMap, MapDomain;
import uv_transform;

unittest {
    import std.math : fabs;
    enum float eps = 1e-5f;
    bool feq(float a, float b) pure { return fabs(a - b) < eps; }

    auto eval(in UvAffine a, float u, float v) {
        import std.typecons : tuple;
        return tuple(
            a.lin[0][0] * u + a.lin[0][1] * v + a.trans[0],
            a.lin[1][0] * u + a.lin[1][1] * v + a.trans[1]);
    }

    // ----------------------------------------------------------------
    // flip-U about (0.5, 0.5): u' = 1 − u, v unchanged.
    {
        auto a = makeFlipU([0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.7f), "flip-U: u' = 1-u");
        assert(feq(r[1], 0.7f), "flip-U: v unchanged");
    }

    // flip-V about (0.5, 0.5): v' = 1 − v, u unchanged.
    {
        auto a = makeFlipV([0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "flip-V: u unchanged");
        assert(feq(r[1], 0.3f), "flip-V: v' = 1-v");
    }

    // ----------------------------------------------------------------
    // Rotate 90° CCW about (0.5, 0.5): cycles the unit-square corners.
    //   (0,0)→(1,0)→(1,1)→(0,1)→(0,0)  — so (1,0)↦(1,1)  [CCW].
    {
        auto a = makeRotate(90.0f, [0.5f, 0.5f]);
        // (1, 0) → (1, 1)
        auto r = eval(a, 1.0f, 0.0f);
        assert(feq(r[0], 1.0f), "rotate 90°: (1,0) u'=1");
        assert(feq(r[1], 1.0f), "rotate 90°: (1,0) v'=1");
        // (0, 0) → (1, 0)
        r = eval(a, 0.0f, 0.0f);
        assert(feq(r[0], 1.0f), "rotate 90°: (0,0) u'=1");
        assert(feq(r[1], 0.0f), "rotate 90°: (0,0) v'=0");
        // (1, 1) → (0, 1)
        r = eval(a, 1.0f, 1.0f);
        assert(feq(r[0], 0.0f), "rotate 90°: (1,1) u'=0");
        assert(feq(r[1], 1.0f), "rotate 90°: (1,1) v'=1");
        // (0, 1) → (0, 0)
        r = eval(a, 0.0f, 1.0f);
        assert(feq(r[0], 0.0f), "rotate 90°: (0,1) u'=0");
        assert(feq(r[1], 0.0f), "rotate 90°: (0,1) v'=0");
    }

    // rotate 0°: identity.
    {
        auto a = makeRotate(0.0f, [0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "rotate 0°: identity u");
        assert(feq(r[1], 0.7f), "rotate 0°: identity v");
    }

    // rotate 360°: ≈ identity within float tolerance.
    {
        auto a = makeRotate(360.0f, [0.5f, 0.5f]);
        auto r = eval(a, 0.3f, 0.7f);
        assert(feq(r[0], 0.3f), "rotate 360°: ≈identity u");
        assert(feq(r[1], 0.7f), "rotate 360°: ≈identity v");
    }

    // ----------------------------------------------------------------
    // computePivot: Centroid is bbox-centre, NOT the arithmetic mean.
    // Corners: (0,0), (6,0), (0,2) — bbox centre = (3,1), mean = (2,0.67).
    {
        MeshMap fakeMap;
        fakeMap.dim    = 2;
        fakeMap.domain = MapDomain.PolyVertex;
        fakeMap.data   = [0.0f, 0.0f,  6.0f, 0.0f,  0.0f, 2.0f];
        const size_t[] loops = [0, 1, 2];
        auto pivot = computePivot(&fakeMap, loops, UvPivot.Centroid);
        assert(feq(pivot[0], 3.0f), "bbox-centre u = 3 (mean would be 2)");
        assert(feq(pivot[1], 1.0f), "bbox-centre v = 1 (mean would be 0.67)");
        // Confirm it differs from the arithmetic mean.
        assert(!feq(pivot[0], 2.0f), "bbox-centre must differ from mean");
    }

    // ----------------------------------------------------------------
    // applyUvAffine: identity transform leaves data unchanged.
    {
        MeshMap m2;
        m2.dim    = 2;
        m2.domain = MapDomain.PolyVertex;
        m2.data   = [0.2f, 0.3f,  0.8f, 0.7f];
        const size_t[] loops = [0, 1];
        UvAffine id;   // default-init is identity
        applyUvAffine(&m2, loops, id);
        assert(feq(m2.data[0], 0.2f) && feq(m2.data[1], 0.3f), "identity: corner 0");
        assert(feq(m2.data[2], 0.8f) && feq(m2.data[3], 0.7f), "identity: corner 1");
    }
}
