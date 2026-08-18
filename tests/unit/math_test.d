// Module unittests for `math`, moved verbatim out of source/math.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.math_test;

import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
import math;
import std.math : isClose;

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


unittest { // The two Rodrigues forms ARE `pivotRotationMatrix` — one law, three
    // spellings, and the matrix is the one with an independent derivation
    // (it builds R entry-by-entry from the outer product, the vector forms
    // build it from cross/dot). A future edit to either vector form that the
    // matrix does not agree with is the drift this pins.
    immutable Vec3 axis = normalize(Vec3(0.3f, -0.8f, 0.5f));
    immutable Vec3 pivot = Vec3(1.5f, -2.0f, 0.25f);
    immutable Vec3 v = Vec3(-0.7f, 2.4f, 3.1f);
    foreach (ang; [0.0f, 0.3f, cast(float) PI / 2, -1.9f, cast(float) PI]) {
        immutable Vec3 byMatrix = applyAffine(pivotRotationMatrix(pivot, axis, ang), v);
        immutable Vec3 byPivot  = rotateAboutPivot(v, pivot, axis, ang);
        assert(isClose(byPivot.x, byMatrix.x, 1e-5f, 1e-5f), "rotateAboutPivot.x");
        assert(isClose(byPivot.y, byMatrix.y, 1e-5f, 1e-5f), "rotateAboutPivot.y");
        assert(isClose(byPivot.z, byMatrix.z, 1e-5f, 1e-5f), "rotateAboutPivot.z");
        // Direction form = pivot form at the origin (that IS its contract).
        immutable Vec3 byAxis = rotateAboutAxis(v, axis, ang);
        immutable Vec3 atOrig = rotateAboutPivot(v, Vec3(0, 0, 0), axis, ang);
        assert(isClose(byAxis.x, atOrig.x, 1e-6f, 1e-6f), "rotateAboutAxis.x");
        assert(isClose(byAxis.y, atOrig.y, 1e-6f, 1e-6f), "rotateAboutAxis.y");
        assert(isClose(byAxis.z, atOrig.z, 1e-6f, 1e-6f), "rotateAboutAxis.z");
        // A rotation is an isometry: |v| about the origin is preserved.
        assert(isClose(byAxis.length, v.length, 1e-5f, 1e-5f), "rotateAboutAxis norm");
    }
}

unittest { // transformPoint matches a hand-computed T·R·S applied to a point.
    // S = diag(2,3,4); R = 90deg about +Y; T = (10,20,30). Column-major
    // M = T * R * S. Compose via the existing matrix builders, then check.
    auto S = pivotScaleMatrix(Vec3(0, 0, 0), 2, 3, 4);
    auto R = pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 1, 0), cast(float) PI / 2);
    auto T = translationMatrix(Vec3(10, 20, 30));
    auto M = matMul4(T, matMul4(R, S));
    // Expected by composing the identical sub-steps separately.
    auto pScaled  = applyAffine(S, Vec3(1, 1, 1));
    auto pRotated = applyAffine(R, pScaled);
    auto expected = applyAffine(T, pRotated);
    auto got = transformPoint(M, Vec3(1, 1, 1));
    assert(isClose(got.x, expected.x, 1e-5f, 1e-5f)
        && isClose(got.y, expected.y, 1e-5f, 1e-5f)
        && isClose(got.z, expected.z, 1e-5f, 1e-5f));
    // Independent hard number: 90deg-about-+Y of (2,3,4) is (4,3,-2) in this
    // column-major builder, + T -> (14,23,28).
    assert(isClose(got.x, 14.0f, 1e-4f, 1e-4f)
        && isClose(got.y, 23.0f, 1e-4f, 1e-4f)
        && isClose(got.z, 28.0f, 1e-4f, 1e-4f));
}

unittest { // toLocalPoint / toWorldPoint round-trip through a non-trivial M/mInv pair.
    // Pure translation is enough to exercise the full-affine (translation-
    // including) path independently of the rotation/scale helpers below.
    ModelSpace ms;
    ms.m    = translationMatrix(Vec3(3, -2, 5));
    ms.mInv = translationMatrix(Vec3(-3, 2, -5));
    ms.isIdentity = false;

    Vec3 localP = Vec3(1, 1, 1);
    Vec3 worldP = ms.toWorldPoint(localP);
    assert(isClose(worldP.x, 4.0f, 1e-5f, 1e-5f)
        && isClose(worldP.y, -1.0f, 1e-5f, 1e-5f)
        && isClose(worldP.z, 6.0f, 1e-5f, 1e-5f));
    Vec3 backToLocal = ms.toLocalPoint(worldP);
    assert(isClose(backToLocal.x, localP.x, 1e-5f, 1e-5f)
        && isClose(backToLocal.y, localP.y, 1e-5f, 1e-5f)
        && isClose(backToLocal.z, localP.z, 1e-5f, 1e-5f));
}

unittest { // toLocalDir preserves a ray's `t`: mInv*(org + t*dir) == toLocalPoint(org) + t*toLocalDir(dir).
    // §3.4 — the identity this un-normalized transform exists to guarantee.
    ModelSpace ms;
    ms.m    = pivotScaleMatrix(Vec3(0,0,0), 2, 1, 1);
    ms.mInv = pivotScaleMatrix(Vec3(0,0,0), 0.5f, 1, 1);
    ms.isIdentity = false;

    Vec3 org = Vec3(5, 5, 5);
    Vec3 dir = Vec3(1, -2, 0.5f); // deliberately not axis-aligned, not unit length
    float t = 3.7f;
    Vec3 worldHit  = org + dir * t;
    Vec3 localHit  = ms.toLocalPoint(worldHit);
    Vec3 orgLocal  = ms.toLocalPoint(org);
    Vec3 dirLocal  = ms.toLocalDir(dir); // must stay UN-normalized
    Vec3 predicted = orgLocal + dirLocal * t;
    assert(isClose(localHit.x, predicted.x, 1e-4f, 1e-4f)
        && isClose(localHit.y, predicted.y, 1e-4f, 1e-4f)
        && isClose(localHit.z, predicted.z, 1e-4f, 1e-4f),
        "toLocalDir must stay un-normalized for `t` to keep meaning a world distance");
}

unittest { // frameMatrix columns hold right/up/fwd; identity basis → identity
    auto m = frameMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1));
    foreach (i, v; identityMatrix) assert(isClose(m[i], v));
}

unittest { // frameMatrix * frameMatrixInverse ≈ identity for a rotated frame
    // 30° about Y → non-axis-aligned orthonormal basis.
    float a = cast(float) PI / 6;
    Vec3 r = Vec3(cos(a), 0, -sin(a));
    Vec3 u = Vec3(0, 1, 0);
    Vec3 f = Vec3(sin(a), 0, cos(a));
    auto m    = frameMatrix(r, u, f);
    auto mInv = frameMatrixInverse(r, u, f);
    auto prod = matMul4(m, mInv);
    foreach (i; 0 .. 16) assert(isClose(prod[i], identityMatrix[i], 1e-5f, 1e-5f));
    // m·(unit x) == right (multiply convention is not transposed).
    auto mx = applyAffine(m, Vec3(1, 0, 0));
    assert(isClose(mx.x, r.x, 1e-5f, 1e-5f)
        && isClose(mx.y, r.y, 1e-5f, 1e-5f)
        && isClose(mx.z, r.z, 1e-5f, 1e-5f));
}

unittest { // wrapAboutPivot of an origin-fixing rotation == the about-pivot one
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.7f);
    auto W = wrapAboutPivot(Morigin, Vec3(0.3f, -0.4f, 0.9f));
    auto direct = pivotRotationMatrix(Vec3(0.3f, -0.4f, 0.9f), Vec3(0,1,0), 0.7f);
    foreach (i; 0 .. 16) assert(isClose(W[i], direct[i], 1e-5f, 1e-5f));
}

unittest { // wrapAboutPivot of an origin-fixing scale == the about-pivot one
    auto Morigin = pivotScaleMatrixBasis(Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),
                                         Vec3(0,0,1), 2.0f, 0.5f, 1.5f);
    Vec3 piv = Vec3(-0.2f, 0.6f, 0.1f);
    auto W = wrapAboutPivot(Morigin, piv);
    auto direct = pivotScaleMatrixBasis(piv, Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                        2.0f, 0.5f, 1.5f);
    foreach (i; 0 .. 16) assert(isClose(W[i], direct[i], 1e-5f, 1e-5f));
}

unittest { // wrapAboutPivotStable matches wrapAboutPivot for small pivots (bit-equal after double→float round-trip)
    import std.conv : to;
    auto Morigin = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.7f);
    Vec3 piv = Vec3(0.3f, -0.4f, 0.9f);
    auto Wold = wrapAboutPivot(Morigin, piv);
    auto Wnew = wrapAboutPivotStable(Morigin, piv);
    foreach (i; 0 .. 16) assert(isClose(Wnew[i], Wold[i], 1e-5f, 1e-5f),
        "wrapAboutPivotStable small-pivot mismatch at element " ~ i.to!string);
}

unittest { // projectionSpace: forward projection agrees with pre-transforming the point —
    // projectToWindow(pLocal, projectionSpace(vp, ms)) == projectToWindow(ms.toWorldPoint(pLocal), vp).
    import std.math : PI;

    Vec3 eye = Vec3(0, 0, 8);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(60.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 400; vp.height = 400; vp.eye = eye;

    ModelSpace ms;
    ms.m    = matMul4(translationMatrix(Vec3(1, -0.5f, 0)),
                       pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.4f));
    // mInv unused by projectionSpace's forward path except via toLocalPoint(eye);
    // give it the analytic inverse of the same T*R so that leg is exact too.
    ms.mInv = matMul4(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), -0.4f),
                       translationMatrix(Vec3(-1, 0.5f, 0)));
    ms.isIdentity = false;

    Vec3 pLocal = Vec3(0.3f, 0.2f, -0.1f);

    Viewport vpLocal = projectionSpace(vp, ms);
    float px1, py1, z1;
    bool ok1 = projectToWindow(pLocal, vpLocal, px1, py1, z1);

    Vec3 pWorld = ms.toWorldPoint(pLocal);
    float px2, py2, z2;
    bool ok2 = projectToWindow(pWorld, vp, px2, py2, z2);

    assert(ok1 == ok2, "projectionSpace must agree with pre-transforming the point on visibility");
    assert(ok1);
    assert(isClose(px1, px2, 1e-3f, 1e-3f) && isClose(py1, py2, 1e-3f, 1e-3f)
        && isClose(z1, z2, 1e-3f, 1e-3f),
        "projectionSpace(vp,ms) projection must match projecting the pre-transformed world point");
}

unittest { // planeForSlice: Free (mode 0) == planeFromLineAndWorkplane
    Vec3 p0, n0, p1, n1;
    bool okFree = planeForSlice(Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(0, 1, 0),
                                0, Vec3(0, 1, 0), p0, n0);
    bool okRef  = planeFromLineAndWorkplane(Vec3(0, 0, -1), Vec3(0, 0, 1),
                                            Vec3(0, 1, 0), p1, n1);
    assert(okFree && okRef);
    assert(isClose(n0.x, n1.x) && isClose(n0.y, n1.y) && isClose(n0.z, n1.z),
           "Free mode must reproduce the drawn-line ⟂ work-plane normal");
}

unittest { // planeForSlice: X/Y/Z extrude the line along the axis ⇒ plane CONTAINS both endpoints
    Vec3 p, n;
    // axis=X: the plane is the drawn line extruded along world-X. It need NOT be
    // X-normal; the invariant is that BOTH endpoints lie in it (n ⟂ line).
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1);
    assert(planeForSlice(s, e, Vec3(0, 1, 0), 1, Vec3(0, 0, 0), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f), "unit normal");
    assert(p.x == 0 && p.z == -1, "plane through Start");
    assert(isClose(dot(s - p, n), 0, 1e-5f, 1e-5f), "Start lies in the plane");
    assert(isClose(dot(e - p, n), 0, 1e-5f, 1e-5f), "End lies in the plane");
    assert(isClose(dot(n, Vec3(1, 0, 0)), 0, 1e-5f, 1e-5f), "n ⟂ the extrusion axis X");
    // axis=Z on a slanted line: plane still contains both endpoints.
    Vec3 s2 = Vec3(0, 0, 0), e2 = Vec3(1, 0.4f, 0);
    assert(planeForSlice(s2, e2, Vec3(0, 1, 0), 3, Vec3(0, 0, 0), p, n));
    assert(isClose(dot(s2 - p, n), 0, 1e-5f, 1e-5f), "Start in plane");
    assert(isClose(dot(e2 - p, n), 0, 1e-5f, 1e-5f), "End in plane");
    assert(isClose(dot(n, Vec3(0, 0, 1)), 0, 1e-5f, 1e-5f), "n ⟂ the extrusion axis Z");
}

unittest { // planeForSlice: Custom extrudes along normalize(vector); zero vector / degenerate → false
    Vec3 p, n;
    // Custom vector (2,0,0): extrude a Z-line along X. Plane contains both ends.
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1);
    assert(planeForSlice(s, e, Vec3(0, 1, 0), 4, Vec3(2, 0, 0), p, n));
    assert(isClose(n.length, 1.0f, 1e-4f), "unit normal");
    assert(isClose(dot(s - p, n), 0, 1e-5f, 1e-5f), "Start in plane");
    assert(isClose(dot(e - p, n), 0, 1e-5f, 1e-5f), "End in plane");
    assert(isClose(dot(n, Vec3(1, 0, 0)), 0, 1e-5f, 1e-5f), "n ⟂ the custom axis (2,0,0)");
    // Zero custom vector ⇒ no plane.
    assert(!planeForSlice(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                          4, Vec3(0, 0, 0), p, n),
           "zero custom vector must be degenerate");
    // DEGENERATE GUARD: a line PARALLEL to the extrusion axis ⇒ cross ≈ 0 ⇒ false.
    assert(!planeForSlice(Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                          1, Vec3(0, 0, 0), p, n),
           "line ∥ axis X (extrusion axis) has no unique plane");
    assert(!planeForSlice(Vec3(0, 0, 0), Vec3(0, 0, 2), Vec3(0, 1, 0),
                          4, Vec3(0, 0, 5), p, n),
           "line ∥ custom axis has no unique plane");
}

unittest { // planeFromLineAndWorkplane: horizontal front-view drag → axis-aligned (Y-normal) cut
    Vec3 p, n;
    // Front view: work plane = XY, normal = +Z. A horizontal line (dir = +X)
    // must produce a horizontal cut plane (normal ∥ Y), independent of pitch.
    bool ok = planeFromLineAndWorkplane(Vec3(-1, 0, 0), Vec3(1, 0, 0),
                                        Vec3(0, 0, 1), p, n);
    assert(ok, "expected a valid plane for a horizontal line");
    assert(isClose(n.length, 1.0f, 1e-4f), "normal must be unit length");
    assert(isClose(n.y * n.y, 1.0f, 1e-4f), "normal must be parallel to world Y");
    assert(isClose(n.x, 0, 1e-4f, 1e-4f), "normal X must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f), "normal Z must be zero");
    // Plane contains the line: n ⟂ (end-start) and n ⟂ workplane normal.
    assert(isClose(dot(n, Vec3(1, 0, 0) - Vec3(-1, 0, 0)), 0, 1e-4f, 1e-4f),
           "normal must be perpendicular to the line direction");
    assert(isClose(dot(n, Vec3(0, 0, 1)), 0, 1e-4f, 1e-4f),
           "normal must be perpendicular to the work-plane normal");
}

unittest { // planeFromLineAndWorkplane: default XZ work plane (normal +Y) → line along Z gives X=0 plane
    Vec3 p, n;
    // Default construction plane (world XZ, normal +Y). A line drawn along Z
    // through the origin yields a plane with normal ∥ X passing through start —
    // exactly the mid-cube cut the S0 golden fixture drives.
    bool ok = planeFromLineAndWorkplane(Vec3(0, 0, -1), Vec3(0, 0, 1),
                                        Vec3(0, 1, 0), p, n);
    assert(ok, "expected a valid plane");
    assert(isClose(n.x * n.x, 1.0f, 1e-4f), "normal must be parallel to world X");
    assert(isClose(n.y, 0, 1e-4f, 1e-4f), "normal Y must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f), "normal Z must be zero");
    assert(p.x == 0 && p.z == -1, "plane point must equal start");
}

unittest { // snapAngleToMultiple: nearest 45° multiple + tie / negative / step-guard
    assert(isClose(snapAngleToMultiple(30, 45), 45, 1e-4f), "30 → 45");
    assert(isClose(snapAngleToMultiple(20, 45),  0, 1e-4f), "20 → 0");
    assert(isClose(snapAngleToMultiple(22.4f, 45),  0, 1e-4f), "22.4 → 0");
    assert(isClose(snapAngleToMultiple(22.6f, 45), 45, 1e-4f), "22.6 → 45");
    assert(isClose(snapAngleToMultiple(60, 45), 45, 1e-4f), "60 → 45");
    assert(isClose(snapAngleToMultiple(70, 45), 90, 1e-4f), "70 → 90");
    assert(isClose(snapAngleToMultiple(-30, 45), -45, 1e-4f), "-30 → -45");
    // A 90° step keeps only axis-aligned angles.
    assert(isClose(snapAngleToMultiple(50, 90), 90, 1e-4f), "50 → 90 (step 90)");
    assert(isClose(snapAngleToMultiple(40, 90),  0, 1e-4f), "40 → 0 (step 90)");
    // step <= 0 is the disabled guard: angle passes through untouched.
    assert(isClose(snapAngleToMultiple(37.5f, 0), 37.5f, 1e-4f), "step 0 → identity");
}

unittest { // snapLineEndpointToAngle: rotates the line to the snapped angle, keeps length
    // Work plane = world XZ: axis1 = +X, axis2 = +Z (angle measured from +X).
    Vec3 a1 = Vec3(1, 0, 0), a2 = Vec3(0, 0, 1);
    // A line at 30° in XZ, length 2. Snap to 45° → direction (cos45, 0, sin45),
    // same length. anchor at origin.
    Vec3 anchor = Vec3(0, 0, 0);
    float c30 = cos(30.0f * cast(float)PI / 180.0f);
    float s30 = sin(30.0f * cast(float)PI / 180.0f);
    Vec3 moving = anchor + Vec3(c30, 0, s30) * 2.0f;
    Vec3 snapped = snapLineEndpointToAngle(anchor, moving, a1, a2, 45);
    float inv = 1.0f / sqrt(2.0f);
    assert(isClose(snapped.x, 2.0f * inv, 1e-4f), "snapped X = 2·cos45");
    assert(isClose(snapped.y, 0, 1e-4f, 1e-4f),   "stays in plane");
    assert(isClose(snapped.z, 2.0f * inv, 1e-4f), "snapped Z = 2·sin45");
    // Length preserved.
    assert(isClose((snapped - anchor).length, 2.0f, 1e-4f), "length preserved");
    // A ~19° line snaps to 0° → pure +X direction (the clean axis-aligned case
    // the S5 golden fixture drives). anchor at (-1,0,0), raw end (1,0,0.7).
    Vec3 an2 = Vec3(-1, 0, 0), mv2 = Vec3(1, 0, 0.7f);
    Vec3 sn2 = snapLineEndpointToAngle(an2, mv2, a1, a2, 45);
    float len2 = (mv2 - an2).length;
    assert(isClose(sn2.z, 0, 1e-4f, 1e-4f), "19° → 0° snaps to Z of anchor (z=0)");
    assert(isClose(sn2.x, -1.0f + len2, 1e-4f), "moves purely along +X");
    // snap off (step 0): endpoint unchanged.
    Vec3 off = snapLineEndpointToAngle(an2, mv2, a1, a2, 0);
    assert(isClose(off.x, 1, 1e-5f) && isClose(off.z, 0.7f, 1e-5f), "step 0 → raw");
    // Degenerate: zero-length line returns moving unchanged.
    assert(snapLineEndpointToAngle(anchor, anchor, a1, a2, 45) == anchor);
}

unittest { // offsetMeet: 90° corner, one bev one non-bev — slides on non-bev edge
    Vec3 jv     = Vec3(0, 0, 0);
    Vec3 ePrev  = Vec3(1, 0, 0);   // non-bev edge along +X
    Vec3 eNext  = Vec3(0, 1, 0);   // bev edge along +Y
    Vec3 faceN  = Vec3(0, 0, -1);  // face normal in -Z
    Vec3 r = offsetMeet(jv, ePrev, eNext, faceN, 0.0f, 0.1f);
    assert(isClose(r.x, 0.1f, 1e-5));
    assert(isClose(r.y, 0.0f, 1e-5));
    assert(isClose(r.z, 0.0f, 1e-5));
}

unittest { // offsetMeet: 90° corner, both bev — meets at the diagonal
    Vec3 jv     = Vec3(0, 0, 0);
    Vec3 ePrev  = Vec3(1, 0, 0);
    Vec3 eNext  = Vec3(0, 1, 0);
    Vec3 faceN  = Vec3(0, 0, -1);
    Vec3 r = offsetMeet(jv, ePrev, eNext, faceN, 0.1f, 0.1f);
    assert(isClose(r.x, 0.1f, 1e-5));
    assert(isClose(r.y, 0.1f, 1e-5));
    assert(isClose(r.z, 0.0f, 1e-5));
}

unittest { // bevelMiterPoint — THE PLANE IS THE TWO EDGES (task 1170).
    // The measured law: the mitre is the point in span{ePrev, eNext} at
    // perpendicular distance wPrev from the ePrev line and wNext from the
    // eNext line. This block asserts exactly that, on a corner whose ring
    // normal is deliberately NOT the two-edge plane's normal — and asserts in
    // the same breath that `offsetMeet` (the pre-1170 kernel) answers
    // differently there, so the block cannot pass with the old function
    // substituted back in. A planar corner would make both claims vacuous.
    static float distToLine(Vec3 p, Vec3 d) {   // line through the origin
        return (p - d * dot(p, d)).length;
    }
    immutable Vec3 jv    = Vec3(0, 0, 0);
    immutable Vec3 ePrev = Vec3(1, 0, 0);
    immutable Vec3 eNext = Vec3(0, 1, 0);
    immutable Vec3 planeN = Vec3(0, 0, 1);          // normal OF THE TWO EDGES
    // A whole-ring Newell normal off that plane by ~17° — what a bent quad
    // actually hands the kernel. Its -Z component makes this corner convex.
    immutable Vec3 ringN = safeNormalize(Vec3(0, 0.3f, -1));
    immutable float w = 0.1f;

    Vec3 m = bevelMiterPoint(jv, ePrev, eNext, ringN, w, w);
    assert(isClose(dot(m, planeN), 0.0f, 1e-5f, 1e-6f),
        "the mitre lies IN the plane of the two edges");
    assert(isClose(distToLine(m, ePrev), w, 1e-5f),
        "perpendicular distance w from the ePrev line");
    assert(isClose(distToLine(m, eNext), w, 1e-5f),
        "perpendicular distance w from the eNext line");
    assert(isClose(m.x, w, 1e-5f) && isClose(m.y, w, 1e-5f),
        "and for a 90° corner that point is (w, w)");

    // The rejected kernel, same inputs: it intersects the two OFFSET LINES by
    // projecting along the ring normal, so it is off both distances here.
    Vec3 old = offsetMeet(jv, ePrev, eNext, ringN, w, w);
    assert((old - m).length > 0.03f * w,
        "offsetMeet must disagree here — otherwise this corner is not bent "
        ~ "enough to discriminate and the block above proves nothing");
    assert(!isClose(distToLine(old, ePrev), w, 1e-3f)
        || !isClose(distToLine(old, eNext), w, 1e-3f)
        || !isClose(dot(old, planeN), 0.0f, 1e-3f, 1e-4f),
        "offsetMeet fails at least one of the three measured properties");
}

unittest { // bevelMiterPoint — THE BRANCH, and only the branch, reads the ring.
    // (a + b) and -(a + b) both sit at distance w from both lines; the engine
    // takes the one pointing INTO the face, and a whole-ring normal is what
    // says which. Measured 117/117, and 16/16 on the corners built reflex.
    //
    // The operand order in `cross(eNext, ePrev)` is load-bearing and was
    // pinned by data (117/117 vs 0/117), so it is pinned here too: this is a
    // CCW square in XY whose Newell normal is +Z, with the corner at the
    // origin, its ring predecessor at (0,1,0) and its successor at (1,0,0).
    // The square's interior is the +X+Y quadrant. Swap the two operands and
    // the answer flips to (-w,-w) — outside the square.
    immutable Vec3 jv    = Vec3(0, 0, 0);
    immutable Vec3 ePrev = Vec3(0, 1, 0);           // toward ring predecessor
    immutable Vec3 eNext = Vec3(1, 0, 0);           // toward ring successor
    immutable float w = 0.1f;

    Vec3 conv = bevelMiterPoint(jv, ePrev, eNext, Vec3(0, 0, 1), w, w);
    assert(isClose(conv.x, w, 1e-5f) && isClose(conv.y, w, 1e-5f)
        && isClose(conv.z, 0.0f, 1e-5f, 1e-6f),
        "convex corner: the mitre goes INTO the ring, (+w, +w)");

    // The same two edges inside a ring wound the other way — the corner is now
    // reflex with respect to its own ring, and the branch must flip.
    Vec3 reflex = bevelMiterPoint(jv, ePrev, eNext, Vec3(0, 0, -1), w, w);
    assert(isClose(reflex.x, -w, 1e-5f) && isClose(reflex.y, -w, 1e-5f),
        "reflex corner: the branch flips to (-w, -w)");
    assert((conv + reflex).length < 1e-6f,
        "the two branches are exact opposites about the corner");
}

unittest { // bevelMiterPoint — a PLANAR corner does not move (task 1170).
    // Why the 22 slide-only cells and the planar mitres inside the other 31
    // are untouched by the port: where the ring normal IS the two-edge plane's
    // normal, the closed form and the old line intersection are the same
    // point, at equal AND unequal per-edge widths, convex AND reflex.
    immutable Vec3 jv    = Vec3(0, 0, 0);
    immutable Vec3 ePrev = Vec3(1, 0, 0);
    immutable Vec3 eNext = Vec3(0, 1, 0);
    foreach (n; [Vec3(0, 0, -1), Vec3(0, 0, 1)])
        foreach (ws; [[0.1f, 0.1f], [0.1f, 0.03f], [0.02f, 0.15f]]) {
            Vec3 a = bevelMiterPoint(jv, ePrev, eNext, n, ws[0], ws[1]);
            Vec3 b = offsetMeet     (jv, ePrev, eNext, n, ws[0], ws[1]);
            assert((a - b).length < 1e-6f,
                "planar corner: the ported mitre is the old point exactly");
        }
    // A non-90° planar corner too, so the agreement is not an artefact of the
    // right angle: 60° between the edges, unequal widths.
    immutable Vec3 e60 = safeNormalize(Vec3(0.5f, 0.8660254f, 0));
    Vec3 p = bevelMiterPoint(jv, ePrev, e60, Vec3(0, 0, -1), 0.07f, 0.02f);
    Vec3 q = offsetMeet     (jv, ePrev, e60, Vec3(0, 0, -1), 0.07f, 0.02f);
    assert((p - q).length < 1e-6f, "60° planar corner agrees too");
}

unittest { // bevelMiterPoint — unequal per-edge widths keep BOTH distances.
    // Inset mode always hands this kernel wPrev == wNext, so this is the width
    // -mode generalisation and it is NOT part of what was measured. It is
    // pinned as what it is: the same closed form, whose coefficient on eNext
    // is wPrev and on ePrev is wNext, and which is provably the old point on a
    // planar face (block above). It is asserted here so the generalisation is
    // at least self-consistent, not so it can be mistaken for measured parity.
    static float distToLine(Vec3 p, Vec3 d) {
        return (p - d * dot(p, d)).length;
    }
    immutable Vec3 jv    = Vec3(0, 0, 0);
    immutable Vec3 ePrev = Vec3(1, 0, 0);
    immutable Vec3 eNext = safeNormalize(Vec3(0.4f, 1, 0));   // ~68°
    immutable Vec3 ringN = safeNormalize(Vec3(0.25f, 0, -1)); // bent ~14°
    immutable float wP = 0.07f, wN = 0.02f;
    Vec3 m = bevelMiterPoint(jv, ePrev, eNext, ringN, wP, wN);
    assert(isClose(distToLine(m, ePrev), wP, 1e-4f),
        "wPrev is the distance from the ePrev line");
    assert(isClose(distToLine(m, eNext), wN, 1e-4f),
        "wNext is the distance from the eNext line");
    assert(isClose(dot(m, safeNormalize(cross(ePrev, eNext))), 0.0f, 1e-5f, 1e-6f),
        "still in the plane of the two edges");
}

unittest { // bevelMiterPoint — the collinear corner delegates, unchanged.
    // Two bevelled edges that run straight through the vertex ("pipe"): there
    // is no unique point at distance w from both lines, and the reference was
    // never measured there. The kernel hands that case back to `offsetMeet`
    // so its behaviour is exactly today's, and this block is what says the
    // delegation is real rather than intended.
    immutable Vec3 jv    = Vec3(0, 0, 0);
    immutable Vec3 ePrev = Vec3(1, 0, 0);
    immutable Vec3 eNext = Vec3(-1, 0, 0);          // antiparallel: sin θ = 0
    immutable Vec3 faceN = Vec3(0, 0, -1);
    Vec3 m = bevelMiterPoint(jv, ePrev, eNext, faceN, 0.1f, 0.1f);
    Vec3 o = offsetMeet     (jv, ePrev, eNext, faceN, 0.1f, 0.1f);
    assert((m - o).length < 1e-9f, "collinear corner: byte-identical to offsetMeet");
    assert(isClose(m.y, 0.1f, 1e-5f), "and that is the in-face perpendicular offset");
}

unittest { // bevelArcPoints: level=0 returns exactly the 2 flat endpoints
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.1f, 0);
    assert(pts.length == 2);
    assert(isClose(pts[0].x, 0.1f, 1e-5, 1e-5) && isClose(pts[0].y, 0.0f, 1e-5, 1e-5));
    assert(isClose(pts[1].x, 0.0f, 1e-5, 1e-5) && isClose(pts[1].y, 0.1f, 1e-5, 1e-5));
}

unittest { // bevelArcPoints: level=1, 90° sweep — midpoint lands EXACTLY at
           // the 45° bisector, at radius=width from center (capture-verified law).
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.1f, 1);
    assert(pts.length == 3);
    import std.math : SQRT1_2;
    immutable float s = 0.1f * SQRT1_2;
    assert(isClose(pts[1].x, s, 1e-5, 1e-5) && isClose(pts[1].y, s, 1e-5, 1e-5),
        "level=1 midpoint should sit at the 45° bisector, radius 0.1");
    // Every point must sit at exactly `radius` from `center`.
    foreach (p; pts) assert(isClose(p.length, 0.1f, 1e-5, 1e-5));
}

unittest { // bevelArcPoints: level=2, 90° sweep — 5 points at 0/22.5/45/67.5/90°
    import std.math : PI, cos, sin;
    Vec3 c = Vec3(0, 0, 0);
    auto pts = bevelArcPoints(c, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.2f, 2);
    assert(pts.length == 5);
    foreach (i, p; pts) {
        immutable float ang = (PI / 2.0f) * (cast(float)i / 4.0f);
        assert(isClose(p.x, 0.2f * cos(ang), 1e-4, 1e-5));
        assert(isClose(p.y, 0.2f * sin(ang), 1e-4, 1e-5));
    }
}

unittest { // Quat.normalize yields unit length
    auto q = Quat(2, 0, 0, 0).normalize();
    assert(isClose(q.w, 1.0f) && isClose(q.x, 0) && isClose(q.y, 0) && isClose(q.z, 0));
    auto q2 = Quat(1, 1, 1, 1).normalize();
    assert(isClose(sqrt(q2.w*q2.w + q2.x*q2.x + q2.y*q2.y + q2.z*q2.z), 1.0f));
}

unittest { // slerp endpoints: t=0 → a, t=1 → b
    auto a = Quat.identity();
    auto b = quatFromMatrix(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), PI/2));
    auto r0 = slerp(a, b, 0.0f);
    assert(isClose(r0.w, a.w, 1e-5f) && isClose(r0.x, a.x, 1e-5f)
        && isClose(r0.y, a.y, 1e-5f) && isClose(r0.z, a.z, 1e-5f));
    auto r1 = slerp(a, b, 1.0f);
    // Sign-insensitive compare (q and -q are the same rotation).
    float d = r1.w*b.w + r1.x*b.x + r1.y*b.y + r1.z*b.z;
    assert(isClose(abs(d), 1.0f, 1e-5f));
}

unittest { // quatFromMatrix(pivotRotationMatrix(...)) recovers the angle
    // Rotation of PI/3 about Z (pivot irrelevant for the rotation part).
    float ang = PI / 3;
    auto m = pivotRotationMatrix(Vec3(2, -1, 0.5f), Vec3(0, 0, 1), ang);
    auto q = quatFromMatrix(m);
    // For a unit-axis rotation, w = cos(ang/2), |z| = sin(ang/2).
    assert(isClose(abs(q.w), cos(ang/2), 1e-4f));
    assert(isClose(abs(q.z), sin(ang/2), 1e-4f));
    assert(isClose(q.x, 0, 1e-4f, 1e-4f) && isClose(q.y, 0, 1e-4f, 1e-4f));
}

unittest { // quatFromMatrix divides out per-axis scale → pure rotation
    // Rotation·scale: rotate PI/4 about Y, then scale (2, 3, 4) along the
    // rotated axes. quatFromMatrix must recover ONLY the rotation.
    float ang = PI / 4;
    Vec3 ax = Vec3(cos(ang), 0, -sin(ang)); // R(Y, ang) applied to X
    Vec3 ay = Vec3(0, 1, 0);
    Vec3 az = Vec3(sin(ang), 0, cos(ang));  // R(Y, ang) applied to Z
    auto rs = pivotScaleMatrixBasis(Vec3(0,0,0), ax, ay, az, 2, 3, 4);
    auto qpure = quatFromMatrix(pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), ang));
    auto qrs   = quatFromMatrix(rs);
    // pivotScaleMatrixBasis builds R·diag(s)·R^T (a symmetric stretch, NOT a
    // rotation·scale), so this case just asserts scale is removed: the result
    // is a unit quaternion and (here) the identity rotation.
    assert(isClose(sqrt(qrs.w*qrs.w+qrs.x*qrs.x+qrs.y*qrs.y+qrs.z*qrs.z), 1.0f, 1e-4f));
}

unittest { // matrixFromQuat ∘ quatFromMatrix round-trips a rotation matrix
    auto m = pivotRotationMatrix(Vec3(0,0,0), normalize(Vec3(1, 2, 3)), 0.7f);
    auto m2 = matrixFromQuat(quatFromMatrix(m));
    // Compare the 3×3 rotation block (translation is zero for pivot at origin).
    foreach (i; [0,1,2, 4,5,6, 8,9,10])
        assert(isClose(m[i], m2[i], 1e-4f), "rotation block mismatch");
}

unittest { // matrixFromQuat(identity) == identity matrix
    auto m = matrixFromQuat(Quat.identity());
    foreach (i, v; identityMatrix)
        assert(isClose(m[i], v, 1e-6f));
}

unittest { // SINGLE-AXIS + known multi-axis round-trips
    auto rx = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(30, 0, 0)));
    assert(isClose(rx.x, 30, 1e-4f, 1e-4f) && isClose(rx.y, 0, 1e-4f, 1e-4f)
        && isClose(rx.z, 0, 1e-4f, 1e-4f));
    auto ry = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(0, 30, 0)));
    assert(isClose(ry.x, 0, 1e-4f, 1e-4f) && isClose(ry.y, 30, 1e-4f, 1e-4f)
        && isClose(ry.z, 0, 1e-4f, 1e-4f));
    auto rz = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(0, 0, 30)));
    assert(isClose(rz.x, 0, 1e-4f, 1e-4f) && isClose(rz.y, 0, 1e-4f, 1e-4f)
        && isClose(rz.z, 30, 1e-4f, 1e-4f));
    // Known multi-axis (well away from gimbal): angles recover directly.
    auto m = eulerZYXFromMatrix(matrixFromEulerZYX(Vec3(20, -35, 50)));
    assert(isClose(m.x, 20, 1e-3f, 1e-3f) && isClose(m.y, -35, 1e-3f, 1e-3f)
        && isClose(m.z, 50, 1e-3f, 1e-3f));
}

unittest { // applyAffine: translation matrix moves a point by t
    auto m = translationMatrix(Vec3(1, -2, 3));
    auto p = applyAffine(m, Vec3(5, 5, 5));
    assert(isClose(p.x, 6) && isClose(p.y, 3) && isClose(p.z, 8));
}

unittest { // applyAffine: pivotRotationMatrix matches a hand-rotated point
    // 90° about Z around origin sends (1,0,0) → (0,1,0).
    auto m = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), PI/2);
    auto p = applyAffine(m, Vec3(1, 0, 0));
    assert(isClose(p.x, 0, 1e-5f, 1e-5f) && isClose(p.y, 1.0f, 1e-5f)
        && isClose(p.z, 0, 1e-5f, 1e-5f));
}

unittest { // normalize axis-aligned
    auto n = normalize(Vec3(3,0,0));
    assert(isClose(n.x, 1.0f) && isClose(n.y, 0.0f) && isClose(n.z, 0.0f));
}

unittest { // normalize length == 1
    auto n = normalize(Vec3(1,2,3));
    assert(isClose(n.length, 1.0f));
}

unittest { // dot
    assert(isClose(dot(Vec3(1,0,0), Vec3(1,0,0)),  1.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(0,1,0)),  0.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(-1,0,0)), -1.0f));
}

unittest { // cross X×Y = Z
    auto r = cross(Vec3(1,0,0), Vec3(0,1,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 1));
}

unittest { // cross anti-commutative
    auto a = Vec3(1,2,3), b = Vec3(4,5,6);
    auto ab = cross(a, b), ba = cross(b, a);
    assert(isClose(ab.x, -ba.x) && isClose(ab.y, -ba.y) && isClose(ab.z, -ba.z));
}

unittest { // cross of parallel vectors is zero
    auto r = cross(Vec3(1,0,0), Vec3(2,0,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 0));
}

unittest { // mulMV with identity
    auto r = mulMV(identityMatrix, Vec4(1,2,3,1));
    assert(isClose(r.x,1) && isClose(r.y,2) && isClose(r.z,3) && isClose(r.w,1));
}

unittest { // modelMatrix identity frame → identity matrix
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(0,0,0));
    foreach (i, v; identityMatrix)
        assert(isClose(m[i], v));
}

unittest { // modelMatrix translation stored in last column
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(5,-3,7));
    assert(isClose(m[12], 5) && isClose(m[13], -3) && isClose(m[14], 7));
}

unittest { // modelMatrix non-uniform scale
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(2,3,4), Vec3(0,0,0));
    assert(isClose(m[0], 2) && isClose(m[5], 3) && isClose(m[10], 4));
}

unittest { // lookAt — origin is in front of camera
    auto m = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    Vec4 o = mulMV(m, Vec4(0,0,0,1));
    assert(isClose(o.x, 0, 1e-4f) && isClose(o.y, 0, 1e-4f));
    assert(o.z < 0);
}

unittest { // sphericalToCartesian az=0 el=0 → +Z
    auto v = sphericalToCartesian(0.0f, 0.0f, 1.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 1));
}

unittest { // sphericalToCartesian el=PI/2 → straight up
    auto v = sphericalToCartesian(0.0f, PI/2, 1.0f);
    assert(isClose(v.y, 1.0f, 1e-5f));
    assert(isClose(v.x, 0, 1e-5f, 1e-5f) && isClose(v.z, 0, 1e-5f, 1e-5f));
}

unittest { // sphericalToCartesian dist=0 → zero vector
    auto v = sphericalToCartesian(1.23f, 0.45f, 0.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 0));
}

unittest { // the bank law: right.y == -sin(roll) * cos(elevation)
    // The identity that makes this `roll` the same quantity a reference
    // viewport reports as its bank, rather than merely some rotation about
    // the view axis. It is what lets a captured bank transfer as a number.
    foreach (a; [-1.1f, 0.0f, 0.9f])
    foreach (e; [-0.9f, 0.0f, 0.4138754f, 1.0f])
    foreach (r; [-1.2f, -0.2055634f, 0.0f, 0.2055634f, 1.2f]) {
        Orientation o = Orientation.fromAngles(a, e, r);
        assert(isClose(o.right().y, -sin(r) * cos(e), 2e-5f, 2e-5f),
               "screen-right.y must equal -sin(roll)*cos(elevation)");
    }
}

unittest { // orthonormalized REPAIRS a drifted matrix, and keeps the view axis
    Orientation o = Orientation.fromAngles(0.5f, 0.4f, 0.2f);
    Orientation drift = o;
    drift.m[0] += 0.02f; drift.m[4] -= 0.03f; drift.m[8] += 0.015f;
    drift.m[3] += 0.01f;
    assert(drift.orthonormalityDefect() > 1e-3f, "the drifted input must be measurably bad");
    Orientation fixed = drift.orthonormalized();
    assert(fixed.orthonormalityDefect() < 1e-6f, "orthonormalized must repair the drift");
    // Anchored on `back`: the direction the camera looks survives the repair.
    assert(isClose(dot(fixed.back(), normalize(drift.back())), 1.0f, 1e-6f),
           "the repair must not swing the view direction");
}

unittest { // closestOnSegment2D — point above midpoint
    float t;
    float d = closestOnSegment2D(2, 1, 0, 0, 4, 0, t);
    assert(isClose(d, 1.0f) && isClose(t, 0.5f));
}

unittest { // closestOnSegment2D — clamp to t=1
    float t;
    float d = closestOnSegment2D(6, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 1.0f) && isClose(d, 2.0f));
}

unittest { // closestOnSegment2D — clamp to t=0
    float t;
    float d = closestOnSegment2D(-1, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 1.0f));
}

unittest { // closestOnSegment2D — degenerate segment
    float t;
    float d = closestOnSegment2D(3, 4, 0, 0, 0, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 5.0f));
}

unittest { // orthographicMatrix: check diagonal entries and m[15] discriminator
    import std.math : isClose;
    float halfH = 2.0f, aspect = 16.0f / 9.0f, near = 0.001f, far = 100.0f;
    auto m = orthographicMatrix(halfH, aspect, near, far);
    // Diagonal entries.
    assert(isClose(m[0],  1.0f / (halfH * aspect), 1e-5f), "m[0] wrong");
    assert(isClose(m[5],  1.0f / halfH,             1e-5f), "m[5] wrong");
    assert(isClose(m[10], -2.0f / (far - near),     1e-5f), "m[10] wrong");
    assert(isClose(m[14], -(far + near) / (far - near), 1e-5f), "m[14] wrong");
    assert(m[15] == 1.0f, "m[15] must be 1 (ortho discriminator)");
    // Off-diagonal entries must be zero.
    foreach (i; 0 .. 16) {
        if (i != 0 && i != 5 && i != 10 && i != 14 && i != 15)
            assert(m[i] == 0.0f, "off-diagonal must be 0");
    }
}

unittest { // isOrtho: perspective → false, ortho → true
    import std.math : isClose, PI;
    Viewport vp;
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    assert(!isOrtho(vp), "perspective matrix must not be ortho");
    assert(vp.proj[15] == 0.0f, "perspective m[15] must be 0");
    vp.proj = orthographicMatrix(2.0f, 1.0f, 0.001f, 100.0f);
    assert(isOrtho(vp), "ortho matrix must be ortho");
    assert(vp.proj[15] == 1.0f, "ortho m[15] must be 1");
}

unittest { // screenPointToRay: ortho — parallel dirs, per-pixel origins
    import std.math : isClose, PI;
    // Build an ortho Front viewport: eye at Z=3, looking -Z.
    Viewport vp;
    vp.view   = lookAt(Vec3(0,0,3), Vec3(0,0,0), Vec3(0,1,0));
    float halfH = 2.0f;
    vp.proj   = orthographicMatrix(halfH, 1.0f, 0.001f, 100.0f);
    vp.width  = 800; vp.height = 800;
    vp.x = 0; vp.y = 0;
    vp.eye    = Vec3(0, 0, 3);
    // Two pixels at different positions.
    Vec3 o1, d1, o2, d2;
    screenPointToRay(200.0f, 400.0f, vp, o1, d1);
    screenPointToRay(600.0f, 400.0f, vp, o2, d2);
    // Directions must be parallel (same vector, forward = -Z).
    assert(isClose(d1.x, d2.x, 1e-5f) && isClose(d1.y, d2.y, 1e-5f)
           && isClose(d1.z, d2.z, 1e-5f), "ortho rays must be parallel");
    assert(isClose(d1.z, -1.0f, 1e-4f), "ortho forward must be -Z for front view");
    // Origins must differ (the two X pixels land at different world X).
    assert(!isClose(o1.x, o2.x, 1e-3f), "ortho origins must differ in X");
    assert(isClose(o1.y, o2.y, 1e-5f), "ortho origins Y must match (same row)");
}

unittest { // rayPlaneIntersect: ray from above hits XZ plane at origin
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,5,0), Vec3(0,-1,0),
                                Vec3(0,0,0), Vec3(0,1,0), hit);
    assert(ok);
    assert(isClose(hit.x, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.y, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // rayPlaneIntersect: angled ray hits offset plane at correct point
    // Ray from origin along (1,1,0)/√2, plane at x=3 with normal (1,0,0)
    // t = 3/s where s=1/√2, hit = (3, 3, 0)
    float s = 1.0f / sqrt(2.0f);
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,0,0), Vec3(s,s,0),
                                Vec3(3,0,0), Vec3(1,0,0), hit);
    assert(ok);
    assert(isClose(hit.x, 3.0f, 1e-4f));
    assert(isClose(hit.y, 3.0f, 1e-4f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // vec3Length
    assert(isClose(Vec3(3,4,0).length, 5.0f));
    assert(isClose(Vec3(0,0,0).length, 0.0f));
    assert(isClose(Vec3(1,0,0).length, 1.0f));
}

unittest { // vec3Lerp
    auto r = vec3Lerp(Vec3(0,0,0), Vec3(4,4,4), 0.25f);
    assert(isClose(r.x, 1.0f) && isClose(r.y, 1.0f) && isClose(r.z, 1.0f));
    auto a = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 0.0f);
    assert(isClose(a.x, 1.0f) && isClose(a.y, 2.0f) && isClose(a.z, 3.0f));
    auto b = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 1.0f);
    assert(isClose(b.x, 5.0f) && isClose(b.y, 6.0f) && isClose(b.z, 7.0f));
}

// ===========================================================================
// ringStartCornerSign — task 1230, the reference's ring-start rule for the
// OFFSET family (divergence-ledger rows 41 / 42 / 47 / 49).
// ===========================================================================
//
// The three classes are pinned on the exact rings the reference was measured
// on (`tests/fixtures/ring_order_orbit_divergence.json`) so that a change to
// the predicate is caught HERE, in one place with no HTTP and no mesh, and not
// only as a pattern shift six kernels downstream. Every ring below is planar
// and rotated by hand — the vertex SET never changes, only where the ring
// starts, which is the whole subject.
unittest { // the three classes, on the measured rings
    // The dart of `inset_dart` / `outset_dart`: (2,0,1.2) is its reflex corner.
    static Vec3[] dartFrom(int start) {
        Vec3[4] r = [Vec3(0,0,0), Vec3(2,0,1.2f), Vec3(4,0,0), Vec3(2,0,3)];
        Vec3[] outp;
        foreach (i; 0 .. 4) outp ~= r[(start + i) % 4];
        return outp;
    }
    assert(ringStartCornerSign(dartFrom(0)) ==  1, "convex start (0,0,0)");
    assert(ringStartCornerSign(dartFrom(1)) == -1, "REFLEX start (2,0,1.2)");
    assert(ringStartCornerSign(dartFrom(2)) ==  1, "convex start (4,0,0)");
    assert(ringStartCornerSign(dartFrom(3)) ==  1, "convex start (2,0,3)");

    // The pentagon of `inset_flat_corner_pentagon`: (1.5,0,0) sits exactly on
    // the segment (0,0,0)-(3,0,0), so its corner triangle is EXACTLY zero and
    // the class is the third one, not a small +1 or a small -1. That is the
    // rotation the reference's inset refuses on.
    static Vec3[] pentFrom(int start) {
        Vec3[5] r = [Vec3(0,0,0), Vec3(1.5f,0,0), Vec3(3,0,0),
                     Vec3(3,0,2), Vec3(0,0,2)];
        Vec3[] outp;
        foreach (i; 0 .. 5) outp ~= r[(start + i) % 5];
        return outp;
    }
    assert(ringStartCornerSign(pentFrom(1)) == 0, "COLLINEAR start (1.5,0,0)");
    foreach (s; [0, 2, 3, 4])
        assert(ringStartCornerSign(pentFrom(s)) == 1,
               "every other start of the flat-corner pentagon is convex");

    // The hexagon of `*_reflex_and_flat_hex` carries BOTH a collinear corner
    // (2,0,0) and a reflex one (2,0,1.4) — the only ring in the corpus that
    // can show all three classes at once, and the reason the zero is kept
    // apart from +1 instead of folded into it.
    static Vec3[] hexFrom(int start) {
        Vec3[6] r = [Vec3(0,0,0), Vec3(2,0,0), Vec3(4,0,0),
                     Vec3(4,0,4), Vec3(2,0,1.4f), Vec3(0,0,4)];
        Vec3[] outp;
        foreach (i; 0 .. 6) outp ~= r[(start + i) % 6];
        return outp;
    }
    int[6] want = [1, 0, 1, 1, -1, 1];
    foreach (s; 0 .. 6)
        assert(ringStartCornerSign(hexFrom(s)) == want[s],
               "hexagon rotation " ~ s.stringof ~ ": all three classes appear");
}

unittest { // REVERSING the ring does not change the answer; ROTATING it does
    // This asymmetry is the content of the `· Newell(ring)` term, and it is
    // why the rival predicate — the corner triangle at vertex 0 read ALONE —
    // scored 76/81 instead of 81/81 in the measurement: on a reversed ring the
    // corner triangle flips, but so does the ring's own normal, and their
    // product does not. Nothing else in the corpus separates the two.
    Vec3[] dart = [Vec3(0,0,0), Vec3(2,0,1.2f), Vec3(4,0,0), Vec3(2,0,3)];
    Vec3[] rev;
    foreach_reverse (v; dart) rev ~= v;
    // `rev` starts at (2,0,3) — rotate it back so BOTH rings start at the same
    // corner and the only difference is which way round they go.
    Vec3[] revSameStart;
    foreach (i; 0 .. 4) revSameStart ~= rev[(3 + i) % 4];
    assert(revSameStart[0] == dart[0], "same starting corner, opposite winding");
    assert(ringStartCornerSign(dart) == ringStartCornerSign(revSameStart),
           "reversal must not change the class");

    // The index-addressed overload is the same rule, not a second one.
    uint[] ringIdx = [0, 1, 2, 3];
    assert(ringStartCornerSign(dart, ringIdx) == ringStartCornerSign(dart));
    uint[] fromReflex = [1, 2, 3, 0];
    assert(ringStartCornerSign(dart, fromReflex) == -1);

    // Degenerate inputs answer 0 rather than guessing.
    assert(ringStartCornerSign(dart[0 .. 2]) == 0, "an edge is not a polygon");
    Vec3[] collapsed = [Vec3(1,1,1), Vec3(1,1,1), Vec3(1,1,1)];
    assert(ringStartCornerSign(collapsed) == 0, "a collapsed ring has no class");
}

unittest { // SCALE INVARIANCE — a small polygon is not a degenerate one
    // The regression this pins is a real one, caught by a frozen agreement and
    // not by anything written for the port: `dot(cross, Newell)` grows as the
    // FOURTH power of the ring's size, so the first version of this predicate
    // tested it against an ABSOLUTE 1e-9 floor and classified an ordinary
    // right angle on a 0.002-unit square as COLLINEAR. `poly.inset` then
    // refused a face it had to inset, and
    // `tests/fixtures/poly_inset_dirty_parity.json`'s `inset_tiny_next_big`
    // came back with 11 vertices where it froze 15. The degeneracy test is
    // made on the corner triangle relative to its own two edges instead, so
    // the class cannot depend on the units the model is drawn in.
    static Vec3[] square(float s) {
        return [Vec3(0,0,0), Vec3(s,0,0), Vec3(s,0,s), Vec3(0,0,s)];
    }
    // Six orders of magnitude, one answer. The 0.002 case IS the fixture's.
    foreach (s; [1000.0f, 1.0f, 0.002f, 1e-3f, 1e-5f])
        assert(ringStartCornerSign(square(s)) == ringStartCornerSign(square(1.0f)),
               "the class must not move with the polygon's size");
    // And the collinear class survives the same shrink: the corner triangle is
    // exactly zero at every scale, so it is zero here too.
    static Vec3[] flatFirst(float s) {
        return [Vec3(s/2,0,0), Vec3(s,0,0), Vec3(s,0,s), Vec3(0,0,s), Vec3(0,0,0)];
    }
    foreach (s; [1000.0f, 1.0f, 0.002f, 1e-5f])
        assert(ringStartCornerSign(flatFirst(s)) == 0,
               "a collinear ring start is collinear at every scale");
}
