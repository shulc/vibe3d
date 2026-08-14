// Module unittests for `math`, moved verbatim out of source/math.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.math_test;

import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
import math;

unittest { // handedness: identity/rotation keep it; an odd count of negative
           // scale components reverses it, an even count does not.
    static immutable float[16] I = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    assert(!matrixMirrorsWinding(I), "identity preserves handedness");
    // A pure rotation is det=+1 however far it turns.
    auto R = pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 1, 0), cast(float) PI / 3);
    assert(!matrixMirrorsWinding(R), "a rotation preserves handedness");
    // Translation alone never mirrors (and the translation column is ignored).
    assert(!matrixMirrorsWinding(translationMatrix(Vec3(5, -6, 7))));
    // One negative component = mirror; two = not; three = mirror again.
    assert( matrixMirrorsWinding(pivotScaleMatrix(Vec3(0,0,0), -1,  1,  1)));
    assert(!matrixMirrorsWinding(pivotScaleMatrix(Vec3(0,0,0), -1, -1,  1)));
    assert( matrixMirrorsWinding(pivotScaleMatrix(Vec3(0,0,0), -1, -1, -1)));
    // The sign survives composition with a rotation and a translation — this is
    // the shape the export paths actually see (`ItemXform.composedMatrix()`).
    auto M = matMul4(translationMatrix(Vec3(1, 2, 3)),
             matMul4(R, pivotScaleMatrix(Vec3(0, 0, 0), -1, 1, 1)));
    assert(matrixMirrorsWinding(M), "a mirror survives R and T composition");
}

unittest { // ModelSpace.world() is the identity: m/mInv == identityMatrix, flags all default.
    auto ms = ModelSpace.world();
    foreach (i; 0 .. 16) {
        assert(ms.m[i]    == identityMatrix[i]);
        assert(ms.mInv[i] == identityMatrix[i]);
    }
    assert(ms.isIdentity && ms.invertible && !ms.mirrored);
}

unittest { // The LOCAL front-facing test agrees DIRECTLY (no XOR, no
    // `mirrored` correction of any kind) with the TRUE GEOMETRIC world
    // front-facing test, for any invertible ModelSpace including a mirror.
    // "True geometric" here means the world outward normal is derived via
    // `ms.toWorldNormal(nLocal)` (the inverse-transpose rule) rather than by
    // cross-producting the triangle's WORLD-transformed vertices — the
    // latter is the WINDING normal, and this is exactly the distinction the
    // previous version of this unittest got backwards: it computed
    // `nWorldTrue` via `cross(bw-aw, cw-aw)` and labelled that "what is
    // ACTUALLY drawn", then asserted `localFront XOR mirrored` agreed with
    // it. That labelled a winding artefact as ground truth, so the
    // assertion just restated the determinant identity
    // `cross(Ma,Mb) == det(M)*(M^-1)^T*cross(a,b)` — it could not have
    // caught the flip being wrong, because it was built from the same
    // premise as the flip.
    //
    // The real identity: `dot((M^-1)^T n, M v) == dot(n, v)` EXACTLY (not
    // just same sign) for ANY invertible M, mirrored or not. Since
    // `pWorld - eyeWorld == M * (pLocal - eyeLocal)` for the linear part of
    // M, this makes `dot(toWorldNormal(nLocal), pWorld - eyeWorld) ==
    // dot(nLocal, pLocal - eyeLocal)` — literally the same number, no sign
    // correction possible or needed. That is why the flip was wrong: there
    // is nothing here for `ms.mirrored` to correct.
    void checkCase(float[16] m, float[16] mInv, bool mirrored) {
        ModelSpace ms;
        ms.m = m; ms.mInv = mInv; ms.isIdentity = false; ms.mirrored = mirrored;

        Vec3 a = Vec3(0, 0, 0), b = Vec3(1, 0, 0), c = Vec3(0, 1, 0);
        Vec3 eyeLocal = Vec3(0, 0, 5); // above the local A,B,C plane (+Z)

        Vec3 nLocal = cross(b - a, c - a);
        bool localFront = dot(nLocal, a - eyeLocal) < 0;

        Vec3 nWorldGeometric = ms.toWorldNormal(nLocal); // NOT a world cross product
        Vec3 aw           = ms.toWorldPoint(a);
        Vec3 eyeWorld      = ms.toWorldPoint(eyeLocal);
        bool worldFrontGeometric = dot(nWorldGeometric, aw - eyeWorld) < 0;

        assert(localFront == worldFrontGeometric,
            "the local front-facing test must agree with the geometric world "
            ~ "test directly — no mirror correction needed or applied");
    }

    // Non-mirrored: scl=(2,1,1) (det > 0).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), 2, 1, 1),
              pivotScaleMatrix(Vec3(0,0,0), 0.5f, 1, 1), false);
    // Mirrored: scl=(-1,1,1) (det < 0) — a single negative axis.
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, 1, 1),
              pivotScaleMatrix(Vec3(0,0,0), -1, 1, 1), true);
    // Mirrored: scl=(-1,-1,-1) (det < 0) — three negative axes (odd count).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, -1, -1),
              pivotScaleMatrix(Vec3(0,0,0), -1, -1, -1), true);
    // Non-mirrored: scl=(-1,-1,1) (det > 0) — two negative axes (even count).
    checkCase(pivotScaleMatrix(Vec3(0,0,0), -1, -1, 1),
              pivotScaleMatrix(Vec3(0,0,0), -1, -1, 1), false);
}

unittest { // wrapAboutPivotStable beats wrapAboutPivot at far pivot for rotation
    // Oracle: pivot far at ~1e4, rotation ~0.5 rad about Y.
    // wrapAboutPivot(float) suffers ~|pivot|·2^-23 ≈ 1.2e-3 translate-column error;
    // wrapAboutPivotStable computes pivot − M_lin·pivot in double → error < 1e-4.
    Vec3 piv = Vec3(10000.0f, 9800.0f, 10200.0f);
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.5f);
    auto Wstable = wrapAboutPivotStable(Morigin, piv);
    auto Wold    = wrapAboutPivot(Morigin, piv);
    // Apply to a near-origin test vertex and compare to double oracle.
    double[3] v = [0.5, -0.5, 0.5];
    // Double oracle: piv + M_lin*(v-piv) for Y rotation by 0.5 rad.
    double ang = 0.5;
    double c = cos(ang), s = sin(ang);
    double ox = cast(double)piv.x + c*(v[0]-piv.x) + s*(v[2]-piv.z);
    double oy = cast(double)piv.y + (v[1]-piv.y);
    double oz = cast(double)piv.z - s*(v[0]-piv.x) + c*(v[2]-piv.z);
    // Stable version applied to v.
    double sx = Wstable[0]*v[0] + Wstable[4]*v[1] + Wstable[8]*v[2]  + Wstable[12];
    double sy = Wstable[1]*v[0] + Wstable[5]*v[1] + Wstable[9]*v[2]  + Wstable[13];
    double sz = Wstable[2]*v[0] + Wstable[6]*v[1] + Wstable[10]*v[2] + Wstable[14];
    double errStable = (sx-ox)*(sx-ox) + (sy-oy)*(sy-oy) + (sz-oz)*(sz-oz);
    // Old version applied to v.
    double ux = Wold[0]*v[0] + Wold[4]*v[1] + Wold[8]*v[2]  + Wold[12];
    double uy = Wold[1]*v[0] + Wold[5]*v[1] + Wold[9]*v[2]  + Wold[13];
    double uz = Wold[2]*v[0] + Wold[6]*v[1] + Wold[10]*v[2] + Wold[14];
    double errOld = (ux-ox)*(ux-ox) + (uy-oy)*(uy-oy) + (uz-oz)*(uz-oz);
    assert(errStable < errOld,
        "wrapAboutPivotStable should beat wrapAboutPivot at far pivot");
    // The translate column is computed in double then stored as float32.
    // For W_trans_x ≈ -3666 (pivot=(1e4,9800,1e4), Y-rot 0.5 rad), float32
    // storage introduces ~|W_trans|·2^-23 ≈ 4.4e-4 residual — better than
    // the old path's ~|pivot|·2^-23 ≈ 1.2e-3, but bounded by float32 ULP.
    assert(sqrt(errStable) < 5e-4,
        "wrapAboutPivotStable far-pivot error > 5e-4");
}

unittest { // projectionSpace: identity fast path returns `vp` unchanged (byte-identical).
    Viewport vp;
    vp.view = identityMatrix; vp.proj = identityMatrix;
    vp.width = 800; vp.height = 600; vp.eye = Vec3(1, 2, 3);
    auto vp2 = projectionSpace(vp, ModelSpace.world());
    foreach (i; 0 .. 16) { assert(vp2.view[i] == vp.view[i]); assert(vp2.proj[i] == vp.proj[i]); }
    assert(vp2.eye.x == vp.eye.x && vp2.eye.y == vp.eye.y && vp2.eye.z == vp.eye.z);
}

unittest { // AimViewport is the compile GATE, not a naming convention.
    // A wrong-but-plausible call site is "pass the world viewport where the
    // aim space belongs". These static asserts are what make that impossible;
    // if any of them ever starts compiling, the gate is gone and every
    // converted site silently reverts to being policed by review alone.

    // (1) No accessible default constructor — `AimViewport v;` must not compile.
    static assert(!__traits(compiles, { AimViewport v; }),
        "AimViewport must not be default-constructible");

    // (2) NOT assertable HERE, deliberately: `private` in D is module-scoped,
    //     so both `AimViewport(someViewport)` and `AimViewport a = someViewport;`
    //     (D's one-argument-constructor initialiser form) DO compile inside
    //     math.d. The "only `aimSpace` can produce one" half of the gate binds
    //     every OTHER module, so it is asserted from a consumer module
    //     instead — see the `version (unittest)` gate block at the bottom of
    //     source/tools/edit/drag_weld.d. Writing that assert here would have
    //     been the exact vacuous-test shape this task is held to.

    // (3) A function that wants an aim space must reject a world viewport.
    static void wantsAim(const ref AimViewport a) { cast(void)a.vp.width; }
    static assert(!__traits(compiles, { Viewport w; wantsAim(w); }),
        "a helper taking AimViewport must not accept a plain Viewport");
}

unittest { // closestOnSegmentToRay — the interior solution, on a rig where the
           // screen-nearest and the 3D-nearest points are NOT the same point.
    // Eye at the origin looking down -Z; the ray through a point that is off
    // the plane containing the segment, so coplanarity cannot hide a
    // difference. Segment spans a 5:1 depth ratio.
    Vec3 o = Vec3(0, 0, 0);
    Vec3 d = normalize(Vec3(0.2f, 0.1f, -1.0f));
    Vec3 a = Vec3(1.0f, 0.0f, -2.0f);
    Vec3 b = Vec3(0.0f, 1.0f, -10.0f);
    float t;
    assert(closestOnSegmentToRay(o, d, a, b, t), "a well-conditioned rig must solve");
    assert(t > 0.0f && t < 1.0f, "the closest approach is interior here");

    // The defining property, checked directly rather than against a second
    // implementation of the same formula: the elected point's perpendicular
    // distance to the ray line is a MINIMUM over the segment.
    float perp(float u) {
        Vec3 p = a + (b - a) * u;
        Vec3 w = p - o;
        Vec3 c = cross(w, d);
        return c.length / d.length;
    }
    immutable float best = perp(t);
    foreach (i; 0 .. 2001) {
        immutable float u = cast(float)i / 2000.0f;
        assert(perp(u) >= best - 1e-5f,
            "the elected parameter must minimise the distance to the ray line");
    }
}

unittest { // closestOnSegmentToRay — clamping, degeneracies, and dir-scale
           // invariance.
    Vec3 o = Vec3(0, 0, 0);
    Vec3 d = Vec3(0, 0, -1);
    float t;

    // Closest approach beyond b -> clamps to 1.
    assert(closestOnSegmentToRay(o, d, Vec3(1, 0, -5), Vec3(0.2f, 0, -5), t),
        "a segment across the ray must solve");
    assert(t == 1.0f, "a solution past the far endpoint must clamp to 1");

    // Closest approach before a -> clamps to 0.
    assert(closestOnSegmentToRay(o, d, Vec3(0.2f, 0, -5), Vec3(1, 0, -5), t),
        "the reversed segment must solve");
    assert(t == 0.0f, "a solution before the near endpoint must clamp to 0");

    // Zero-length segment -> degenerate.
    t = 0.5f;
    assert(!closestOnSegmentToRay(o, d, Vec3(1, 0, -5), Vec3(1, 0, -5), t),
        "a zero-length segment has no closest-approach parameter");
    assert(t == 0.0f, "a degenerate answer must be the documented t = 0");

    // Segment parallel to the ray -> degenerate (M vanishes).
    t = 0.5f;
    assert(!closestOnSegmentToRay(o, d, Vec3(1, 0, -2), Vec3(1, 0, -9), t),
        "a segment along the view ray has no distinguished parameter");
    assert(t == 0.0f, "a degenerate answer must be the documented t = 0");

    // Scaling `dir` must not move the answer — the normalise this function
    // omits is what would otherwise have to guarantee that.
    Vec3 dd = normalize(Vec3(0.3f, -0.2f, -1.0f));
    Vec3 a2 = Vec3(-1.0f, 0.5f, -3.0f), b2 = Vec3(2.0f, -0.5f, -12.0f);
    float t1, t2;
    assert(closestOnSegmentToRay(o, dd,        a2, b2, t1));
    assert(closestOnSegmentToRay(o, dd * 7.5f, a2, b2, t2));
    import std.math : abs;
    assert(abs(t1 - t2) < 1e-6f,
        "the elected parameter must be invariant under the ray direction's scale");
}

unittest { // perpendicularFrame — orthonormal, spans the perpendicular plane,
           // and reports a degenerate direction rather than returning NaNs.
    Vec3 u, v;
    foreach (d; [Vec3(0, 0, -1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                 Vec3(0.3f, -0.7f, 0.2f), Vec3(-5, 5, -5)]) {
        assert(perpendicularFrame(d, u, v), "a non-degenerate direction must solve");
        assert(abs(sqrt(dot(u, u)) - 1.0f) < 1e-5f, "u must be unit");
        assert(abs(sqrt(dot(v, v)) - 1.0f) < 1e-5f, "v must be unit");
        assert(abs(dot(u, v)) < 1e-5f, "u and v must be orthogonal");
        assert(abs(dot(u, d)) < 1e-5f * sqrt(dot(d, d)), "u must be perpendicular to d");
        assert(abs(dot(v, d)) < 1e-5f * sqrt(dot(d, d)), "v must be perpendicular to d");
    }
    assert(!perpendicularFrame(Vec3(0, 0, 0), u, v),
        "a zero direction spans no plane and must say so");

    // The property the caller actually buys: for a point off the line through
    // the origin along d, the length of its (u,v) coordinates IS its
    // perpendicular distance to that line.
    immutable Vec3 d = Vec3(0, 0, -1);
    assert(perpendicularFrame(d, u, v));
    immutable Vec3 p = Vec3(3, 4, -17);
    immutable float du = dot(p, u), dv = dot(p, v);
    assert(abs(sqrt(du*du + dv*dv) - 5.0f) < 1e-5f,
        "the frame's coordinates must measure the distance to the ray line");
}

unittest { // rayTriangleIntersect — hit, backface, miss, behind, and the
           // barycentric reconstruction agreeing with the parametric one.
    immutable Vec3 v0 = Vec3(0, 0, -5), v1 = Vec3(2, 0, -5), v2 = Vec3(0, 2, -5);
    float t, u, v;

    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, 0), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a ray through the interior must hit");
    assert(abs(t - 5.0f) < 1e-5f, "t is measured along dir, which is unit here");
    assert(abs(u - 0.25f) < 1e-5f && abs(v - 0.25f) < 1e-5f,
        "and the barycentrics must locate the hit inside the triangle");
    immutable Vec3 pPar = Vec3(0.5f, 0.5f, 0) + Vec3(0, 0, -1) * t;
    immutable Vec3 pBar = v0 + (v1 - v0) * u + (v2 - v0) * v;
    immutable Vec3 diff = pPar - pBar;
    assert(sqrt(dot(diff, diff)) < 1e-5f,
        "the two reconstructions of the hit must be the same point — the port "
        ~ "uses one on the hit arm and the other on the miss arm");

    // Back face: the same triangle from behind still hits. The reference's
    // polygon test has no front-face rule (the caller's `faceVisible` does).
    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, -10), Vec3(0, 0, 1), v0, v1, v2, t, u, v),
        "the test must be double-sided");
    assert(abs(t - 5.0f) < 1e-5f);

    // Outside the triangle, in the same plane.
    assert(!rayTriangleIntersect(Vec3(3, 3, 0), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a ray past the triangle must miss");

    // Behind the origin: still a HIT, with a negative t. Rejecting it is the
    // caller's rule, deliberately not this function's.
    assert(rayTriangleIntersect(Vec3(0.5f, 0.5f, -10), Vec3(0, 0, -1), v0, v1, v2, t, u, v),
        "a triangle behind the ray origin still intersects the ray LINE");
    assert(t < 0.0f, "and it must be reported by the sign of t, not by a false");

    // Degenerate triangle.
    assert(!rayTriangleIntersect(Vec3(0, 0, 0), Vec3(0, 0, -1),
                                 v0, v0, v0, t, u, v),
        "a zero-area triangle must not report a hit");
}

unittest { // closestPointOnTriangle2D — interior, each edge, each corner, and a
           // degenerate triangle, checked through the barycentrics rather than
           // through a second copy of the same arithmetic.
    immutable float ax = 0, ay = 0, bx = 4, by = 0, cx = 0, cy = 3;
    float u, v;

    float rebuiltDist2(float px, float py, float uu, float vv) {
        immutable float qx = ax + uu*(bx - ax) + vv*(cx - ax);
        immutable float qy = ay + uu*(by - ay) + vv*(cy - ay);
        return (px - qx)*(px - qx) + (py - qy)*(py - qy);
    }

    // Interior -> exactly zero, and the barycentrics locate the query point.
    assert(closestPointOnTriangle2D(1, 1, ax, ay, bx, by, cx, cy, u, v) == 0.0f,
        "a point inside must be at zero distance, exactly");
    assert(rebuiltDist2(1, 1, u, v) < 1e-8f,
        "and the barycentrics must rebuild the query point itself");

    // Beyond edge AB.
    float d2 = closestPointOnTriangle2D(2, -3, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(d2 - 9.0f) < 1e-4f, "the foot is on AB, three units below");
    assert(abs(v) < 1e-6f, "on AB the C coefficient must vanish");
    assert(abs(rebuiltDist2(2, -3, u, v) - d2) < 1e-4f,
        "the returned distance and the returned point must agree");

    // Beyond corner B.
    d2 = closestPointOnTriangle2D(9, -1, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(d2 - 26.0f) < 1e-3f, "the nearest point of the triangle is B");
    assert(abs(u - 1.0f) < 1e-5f && abs(v) < 1e-5f, "which is (u, v) = (1, 0)");

    // Beyond the hypotenuse BC.
    d2 = closestPointOnTriangle2D(4, 3, ax, ay, bx, by, cx, cy, u, v);
    assert(abs(rebuiltDist2(4, 3, u, v) - d2) < 1e-4f,
        "the hypotenuse case must be self-consistent too");
    assert(u > 0.0f && v > 0.0f && abs(u + v - 1.0f) < 1e-5f,
        "and its foot must lie ON BC, i.e. u + v == 1");

    // A degenerate (zero-area) triangle must still answer — this is the case
    // the Voronoi-region form needs a special guard for and this one does not.
    d2 = closestPointOnTriangle2D(0, 5, 0, 0, 4, 0, 2, 0, u, v);
    assert(abs(d2 - 25.0f) < 1e-4f,
        "a collapsed triangle is a segment, and the foot is still on it");
}

unittest { // triangulatePolygonEarClip — the small arities and a non-planar quad.
    assert(triangulatePolygonEarClip([]) is null, "no polygon, no triangles");
    assert(triangulatePolygonEarClip([Vec3(0,0,0), Vec3(1,0,0)]) is null,
        "two vertices are not a polygon");

    auto t3 = triangulatePolygonEarClip([Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)]);
    assert(t3.length == 1 && t3[0] == [0u, 1u, 2u],
        "a triangle is its own triangulation, in its own order");

    // A saddle quad: the two triangles must stay genuinely non-coplanar, which
    // is what lets a hit test find the FOLD rather than a best-fit plane.
    immutable Vec3[4] saddle = [Vec3(-1,-1,0), Vec3(1,-1,0), Vec3(1,1,0), Vec3(-1,1,2)];
    auto t4 = triangulatePolygonEarClip(saddle[]);
    assert(t4.length == 2, "a quad yields two triangles");
    Vec3 nrmOf(uint[3] t) {
        return cross(saddle[t[1]] - saddle[t[0]], saddle[t[2]] - saddle[t[0]]);
    }
    immutable Vec3 n0 = nrmOf(t4[0]), n1 = nrmOf(t4[1]);
    immutable Vec3 c = cross(n0, n1);
    assert(sqrt(dot(c, c)) > 1e-3f,
        "the saddle's two triangles must have DIFFERENT normals — a flattened "
        ~ "triangulation would put both on one plane and lose the fold");
}

unittest { // planeFromLineAndWorkplane: degenerate line / line ∥ workplane normal → false, no NaN
    Vec3 p, n;
    // Zero-length line.
    assert(!planeFromLineAndWorkplane(Vec3(1, 2, 3), Vec3(1, 2, 3),
                                      Vec3(0, 1, 0), p, n),
           "zero-length line must be degenerate");
    // Line parallel to the work-plane normal (cross ≈ 0): no unique plane.
    assert(!planeFromLineAndWorkplane(Vec3(0, -1, 0), Vec3(0, 1, 0),
                                      Vec3(0, 1, 0), p, n),
           "line parallel to workplane normal must be degenerate");
}

unittest {
    static bool eq(float x, float y) { return abs(x - y) < 1e-5f; }

    // Perpendicular ray crossing the segment interior.
    Vec3 a = Vec3(0, 0, 0), b = Vec3(1, 0, 0);
    Vec3 hit = closestPointOnSegmentToRay(a, b, Vec3(0.3f, 1, 0),
                                                Vec3(0, -1, 0));
    assert(eq(hit.x, 0.3f) && eq(hit.y, 0) && eq(hit.z, 0));

    // Ray past the b endpoint → clamp to b.
    hit = closestPointOnSegmentToRay(a, b, Vec3(1.5f, 1, 0),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 1) && eq(hit.y, 0));

    // Ray before the a endpoint → clamp to a.
    hit = closestPointOnSegmentToRay(a, b, Vec3(-0.4f, 1, 0),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 0) && eq(hit.y, 0));

    // Skew ray (off-axis along z) — closest point on segment along x.
    hit = closestPointOnSegmentToRay(a, b, Vec3(0.7f, 1, 0.5f),
                                            Vec3(0, -1, 0));
    assert(eq(hit.x, 0.7f));

    // Ray parallel to segment: t = -uw/uu = 0.2/1 = 0.2 → (0.2, 0, 0).
    hit = closestPointOnSegmentToRay(a, b, Vec3(0.2f, 0.5f, 0),
                                            Vec3(1, 0, 0));
    assert(eq(hit.x, 0.2f) && eq(hit.y, 0));
}

unittest {
    import std.math : abs;
    static bool eq(float x, float y) { return abs(x - y) < 1e-5f; }
    Vec3 c = Vec3(0, 0, 0);
    Vec3 d = Vec3(1, 0, 0);  // X axis

    // Perpendicular ray at x=0.3 — same result as the clamped version.
    Vec3 hit = closestPointOnLineToRay(c, d, Vec3(0.3f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, 0.3f) && eq(hit.y, 0) && eq(hit.z, 0));

    // Ray past t=1 — NOT clamped (unlike closestPointOnSegmentToRay).
    hit = closestPointOnLineToRay(c, d, Vec3(1.5f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, 1.5f) && eq(hit.y, 0));

    // Ray before t=0 — NOT clamped (negative t).
    hit = closestPointOnLineToRay(c, d, Vec3(-0.4f, 1, 0), Vec3(0, -1, 0));
    assert(eq(hit.x, -0.4f) && eq(hit.y, 0));

    // Parallel ray: t = -uw/uu = -dot(dir, center-O)/dot(dir,dir).
    // O=(0.2,0.5,0) D=(1,0,0): w=(-0.2,-0.5,0), uw=-0.2, t=0.2 → (0.2,0,0).
    hit = closestPointOnLineToRay(c, d, Vec3(0.2f, 0.5f, 0), Vec3(1, 0, 0));
    assert(eq(hit.x, 0.2f) && eq(hit.y, 0));
}

unittest { // matrixFromEulerZYX((0,0,0)) == identity (exact)
    auto m = matrixFromEulerZYX(Vec3(0, 0, 0));
    foreach (i, v; identityMatrix)
        assert(m[i] == v, "zero euler must be exact identity");
}

unittest { // CONVENTION MATCH: helper == explicit composeFor-order matMul4 chain
    enum float D2R = cast(float)(PI / 180.0);
    // A spread of angle triples, incl. some with zero components (skip path).
    Vec3[] cases = [
        Vec3(30, 0, 0), Vec3(0, 45, 0), Vec3(0, 0, 60),
        Vec3(17, -33, 52), Vec3(-80, 25, -10), Vec3(0, 89.9f, 0),
    ];
    foreach (deg; cases) {
        auto a = matrixFromEulerZYX(deg);
        // Mirror composeFor: identity, left-mul X, then Y, then Z (skip zero).
        float[16] b = identityMatrix;
        if (deg.x != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(1,0,0), deg.x*D2R), b);
        if (deg.y != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), deg.y*D2R), b);
        if (deg.z != 0)
            b = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), deg.z*D2R), b);
        foreach (i; 0 .. 16)
            assert(a[i] == b[i], "helper must be bit-equal to composeFor chain");
    }
}

unittest { // ROUNDTRIP: matrixFromEulerZYX∘eulerZYXFromMatrix ≈ id (incl. near-gimbal)
    Vec3[] cases = [
        Vec3(0, 0, 0), Vec3(13, 27, 41), Vec3(-66, 12, 88),
        Vec3(170, -150, 95), Vec3(45, 45, 45), Vec3(-12, 78, -34),
        // Near-gimbal pitch:
        Vec3(33, 89.9f, -21), Vec3(-50, -89.9f, 17),
        Vec3(33, 90.0f, -21), Vec3(-50, -90.0f, 17),
        Vec3(0, 90.0f, 0),    Vec3(60, 90.0f, 0),
    ];
    float maxErr = 0;
    foreach (deg; cases) {
        auto M = matrixFromEulerZYX(deg);
        auto M2 = matrixFromEulerZYX(eulerZYXFromMatrix(M));
        foreach (i; 0 .. 16) {
            float e = abs(M[i] - M2[i]);
            if (e > maxErr) maxErr = e;
            assert(e < 1e-4f, "euler ZYX roundtrip exceeded tolerance");
        }
    }
    assert(maxErr < 1e-4f);
}

unittest { // vec3Add
    auto r = Vec3(1,2,3) + Vec3(4,5,6);
    assert(r.x == 5 && r.y == 7 && r.z == 9);
}

unittest { // vec3Sub
    auto r = Vec3(4,5,6) - Vec3(1,2,3);
    assert(r.x == 3 && r.y == 3 && r.z == 3);
}

unittest { // vec3Scale
    auto r = Vec3(1,2,3) * 2.0f;
    assert(r.x == 2 && r.y == 4 && r.z == 6);
}

unittest { // vec3Scale by zero
    auto r = Vec3(5,-3,7) * 0.0f;
    assert(r.x == 0 && r.y == 0 && r.z == 0);
}

unittest { // fromAngles is a rotation everywhere INCLUDING the poles
    // The cross-product chain it replaced is 0/0 at |elevation| = 90 deg,
    // which is why the spherical camera had to clamp short of the pole. The
    // closed form is the analytic limit and stays a clean rotation there.
    foreach (a; [-2.7f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.5f, 0.0f, 0.4138754f, 1.5f, PI/2])
    foreach (r; [-1.2f, 0.0f, 2.5f]) {
        Orientation o = Orientation.fromAngles(cast(float)a, cast(float)e, cast(float)r);
        assert(o.orthonormalityDefect() < 1e-5f,
               "fromAngles must be an orthonormal right-handed rotation, poles included");
    }
    // ...and specifically NOT NaN at the pole, which is the failure the chain had.
    Orientation pole = Orientation.fromAngles(0.7f, cast(float)(PI / 2), 0.3f);
    foreach (i; 0 .. 9)
        assert(pole.m[i] == pole.m[i], "a pole orientation must not be NaN");
}

unittest { // toAngles is the inverse of fromAngles, poles included
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.4f, 0.0f, 0.4138754f, 1.4f, PI/2])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation o = Orientation.fromAngles(cast(float)a, cast(float)e, cast(float)r);
        float a2, e2, r2;
        o.toAngles(a2, e2, r2);
        Orientation back = Orientation.fromAngles(a2, e2, r2);
        foreach (i; 0 .. 9)
            assert(abs(o.m[i] - back.m[i]) < 4e-6f,
                   "matrix -> angles -> matrix must reproduce the orientation");
    }
}

unittest { // orthonormalized is IDEMPOTENT after doing REAL work — bit-exactly
    // This is what makes a serialisation round-trip bit-exact even though the
    // reader re-normalises everything it reads: the normalised form is a fixed
    // point, so writing it out and reading it back cannot move it.
    //
    // The samples below are DRIFTED on purpose, so the first call takes the
    // repair branch (the tolerance gate would otherwise return the input and
    // the fixed-point claim would be vacuous). Each is checked to be over the
    // gate going in and under it coming out.
    int repaired = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-PI/2, -1.4f, 0.0f, 0.4138754f, 1.4f, PI/2])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation drift = Orientation.fromAngles(cast(float)a, cast(float)e,
                                                   cast(float)r);
        drift.m[0] += 0.013f; drift.m[4] -= 0.021f;
        drift.m[7] += 0.009f; drift.m[5] += 0.004f;
        assert(drift.orthonormalityDefect() > kOrientationTolerance,
               "the sample must actually need repair");
        Orientation once  = drift.orthonormalized();
        assert(once.orthonormalityDefect() <= kOrientationTolerance,
               "one pass must land inside the tolerance band — the fixed point "
               ~ "depends on it");
        Orientation twice = once.orthonormalized();
        assert(once.m == twice.m,
               "orthonormalized must be a fixed point — a round trip through it "
               ~ "would otherwise move the orientation every time it is read");
        repaired++;
    }
    assert(repaired == 120, "every sample must have exercised the repair branch");

    // And a cleanly-constructed orientation is returned bit-untouched, so a
    // save/load cycle on a normal camera moves nothing at all.
    Orientation clean = Orientation.fromAngles(0.5f, 0.4f, 0.2055634f);
    assert(clean.orthonormalized().m == clean.m,
           "a clean orientation must pass through the normalisation unchanged");
    Orientation c = Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                        .rotatedAbout(Vec3(1, 0, 0), 0.3f)
                        .rotatedAbout(Vec3(0, 0, 1), -0.8f);
    assert(c.orthonormalized().m == c.m,
           "rotatedAbout already returns the normalised fixed point");
}

unittest { // degenerate columns produce a rotation, never NaN
    Orientation z; z.m = [0, 0, 0,  0, 0, 0,  0, 0, 0];
    assert(z.orthonormalized().orthonormalityDefect() < 1e-6f,
           "an all-zero matrix must normalise to some valid rotation");
    Orientation par; par.m = [1, 0, 0,  0, 0, 1,  0, 0, 1];  // up parallel to back
    assert(par.orthonormalized().orthonormalityDefect() < 1e-6f,
           "up parallel to back must fall back, not divide by zero");
}

unittest { // rotatedAbout carries a rotation the two-angle camera cannot hold
    // A pure spherical camera forces `right.y == 0` — screen-right can never
    // leave the world XZ plane. Composing an off-axis increment leaves it, and
    // that is the state the storage change exists to carry.
    Orientation level = Orientation.fromAngles(0.5f, 0.4f, 0.0f);
    assert(level.right().y == 0.0f, "an unbanked spherical camera has right.y exactly 0");
    Orientation tilted = level.rotatedAbout(normalize(Vec3(1, 0.3f, -0.7f)), 0.6f);
    assert(abs(tilted.right().y) > 1e-2f,
           "an off-axis composition must leave the level-horizon subspace");
    assert(tilted.orthonormalityDefect() < 1e-6f, "and stay a rotation");
    // Rotating back by the same axis/angle returns to the level camera.
    Orientation home = tilted.rotatedAbout(normalize(Vec3(1, 0.3f, -0.7f)), -0.6f);
    foreach (i; 0 .. 9)
        assert(abs(home.m[i] - level.m[i]) < 1e-5f,
               "rotatedAbout must be invertible by the negated angle");
}

unittest { // a stored orientation is the SAME camera lookAt built, to one ulp
    // Not bit-identical, and the gap is the point rather than a tolerance
    // granted to make this pass. `lookAt` derives its basis from
    // `normalize(center - eye)`, so the matrix it returns depends on the
    // DISTANCE (the offset it normalises is `distance` long, and normalising a
    // scaled vector rounds differently) and on the FOCUS (`center - eye`
    // re-rounds when the focus is far from the origin). Neither dependency is
    // real: a rotation has no distance and no position. Removing them costs
    // one ulp on the lanes, and the size is measured, not guessed: across a
    // 5x5x3 sweep of azimuth, elevation and distance the nine ROTATION lanes
    // differ by at most 1.2e-7 (one ulp at unit magnitude) and the three
    // TRANSLATION lanes, which carry the eye and therefore scale with the
    // distance, by at most 1.7e-7 of that distance.
    float worstRot = 0, worstTransRel = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.0f, 0.4138754f, 1.5f])
    foreach (d; [1.486323332f, 3.0f, 7.5f]) {
        immutable Vec3 focus = Vec3(0, 0, 0);
        Vec3 off = sphericalToCartesian(a, e, d);
        float[16] want = lookAt(focus + off, focus, Vec3(0, 1, 0));
        Orientation o = Orientation.fromAngles(a, e, 0.0f);
        float[16] got = viewMatrixFrom(o, focus + o.back() * d);
        foreach (i; [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
            immutable float dd = abs(got[i] - want[i]);
            if (dd > worstRot) worstRot = dd;
        }
        foreach (i; [12, 13, 14]) {
            immutable float rel = abs(got[i] - want[i]) / d;
            if (rel > worstTransRel) worstTransRel = rel;
        }
    }
    assert(worstRot <= 1.2e-7f,
           "the view basis must reproduce lookAt's to one ulp");
    assert(worstTransRel <= 1.7e-7f,
           "the view translation must reproduce lookAt's to one ulp of the distance");
}

unittest { // pointInPolygon2D square
    float[] xs = [0, 4, 4, 0];
    float[] ys = [0, 0, 4, 4];
    assert( pointInPolygon2D(2, 2, xs, ys));
    assert(!pointInPolygon2D(5, 2, xs, ys));
    assert(!pointInPolygon2D(2, 5, xs, ys));
}

unittest { // pointInPolygon2D triangle
    float[] xs = [0, 2, 4];
    float[] ys = [0, 4, 0];
    assert( pointInPolygon2D(2, 1.5f, xs, ys));
    assert(!pointInPolygon2D(-1, 2,   xs, ys));
}

unittest { // rayPlaneIntersect: ray parallel to plane returns false
    Vec3 hit;
    assert(!rayPlaneIntersect(Vec3(0,5,0), Vec3(1,0,0),
                              Vec3(0,0,0), Vec3(0,1,0), hit));
}

unittest { // rayPlaneIntersect: near-parallel ray below threshold returns false
    Vec3 hit;
    // dot((0,1,0), (1, 5e-7, 0)) = 5e-7 < 1e-6
    assert(!rayPlaneIntersect(Vec3(0,0,0), Vec3(1.0f, 5e-7f, 0),
                              Vec3(0,1,0), Vec3(0,1,0), hit));
}
