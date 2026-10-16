// Public cells relocated from task 0706 math carrier; Wave8 task 20262320.
module vibe3d.util.spatial.tests.unit.spatial_test;

import vibe3d.util.math.math;
import vibe3d.util.spatial.spatial;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite, isClose;


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

    // (2) Only `aimSpace` produces one. `private` is module-scoped, so this
    //     half binds only modules OTHER than spatial.d — this one is (it moved
    //     here from drag_weld.d, task 9437, when that file stopped aiming).
    static assert(!__traits(compiles, { Viewport w; AimViewport a = AimViewport(w); }),
        "AimViewport's constructor must be unreachable outside spatial.d");
    static assert(!__traits(compiles, { Viewport w; AimViewport a = w; }),
        "a world Viewport must not become an AimViewport outside spatial.d");
    static assert(__traits(compiles, {
        Viewport w; ModelSpace ms; auto a = aimSpace(w, ms); cast(void)a.vp.width;
    }), "aimSpace(vp, ms) must be the way an AimViewport is produced");

    // (3) A function that wants an aim space must reject a world viewport.
    static void wantsAim(const ref AimViewport a) { cast(void)a.vp.width; }
    static assert(!__traits(compiles, { Viewport w; wantsAim(w); }),
        "a helper taking AimViewport must not accept a plain Viewport");
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
