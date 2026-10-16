module vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_regression_test;

import vibe3d.util.math.math : Vec3, matMul4, matrixFromEulerZYX, eulerZYXFromMatrix,
              applyAffine, scaleAlongBasis, identityMatrix;
import vibe3d.documents.model.document : Layer, ItemXform;

import vibe3d.documents.model.document : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;
import vibe3d.editing.tools.transform.tools.transform.item_xform_kernels;

// ---------------------------------------------------------------------------
// Unit tests — the whole item TRS law lives here precisely so it is covered
// by `dub test --config=tests` with no live app, no GL, no HTTP.
// ---------------------------------------------------------------------------
version (unittest) {
    private bool isClose(float a, float b, float eps = 1e-5f) {
        import std.math : fabs;
        return fabs(a - b) <= eps;
    }
    private bool vecClose(Vec3 a, Vec3 b, float eps = 1e-5f) {
        return isClose(a.x, b.x, eps) && isClose(a.y, b.y, eps) && isClose(a.z, b.z, eps);
    }
    private bool matClose(const float[16] a, const float[16] b, float eps = 1e-5f) {
        foreach (i; 0 .. 16) if (!isClose(a[i], b[i], eps)) return false;
        return true;
    }
}


// T+S composed in one gesture: translation is outside scale, so S does not
// multiply the world-space delta. The default pivot isolates that interaction.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(0, 0, 0);
    l.xform.rot = Vec3(0, 0, 0);
    l.xform.scl = Vec3(1, 1, 1);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    Vec3 tLocal = Vec3(2, 3, -1);
    Vec3 sFactor = Vec3(4, 1, 1);
    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        tLocal, identityMatrix, sFactor);

    // worldDelta == tLocal under the world default frame.
    Vec3 expected = Vec3(2, 3, -1);
    assert(vecClose(l.xform.pos, expected, 1e-5f),
           "6207 item law: scale must not multiply translation");
    assert(vecClose(l.xform.scl, sFactor, 1e-6f));
}

// Translate leaves rot/scl untouched; pos moves by exactly the world-space
// expansion of tLocal through the frozen frame. Default pivot=(0,0,0) rig so
// the P==centreWorld cancellation and the pos delta are both exact.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(1, 2, 3);
    l.xform.rot = Vec3(0, 0, 0);
    l.xform.scl = Vec3(1, 1, 1);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    Vec3 tLocal = Vec3(2, -3, 5);
    Vec3 iX = Vec3(1,0,0), iY = Vec3(0,1,0), iZ = Vec3(0,0,1);
    bool changed = applyGestureToItems([l], baselines, centre, iX, iY, iZ,
        tLocal, identityMatrix, Vec3(1,1,1));

    assert(changed);
    assert(l.xform.rot == baselines[0].rot, "translate must not touch rot");
    assert(l.xform.scl == baselines[0].scl, "translate must not touch scl");
    Vec3 expected = Vec3(baselines[0].pos.x + tLocal.x,
                          baselines[0].pos.y + tLocal.y,
                          baselines[0].pos.z + tLocal.z);
    assert(vecClose(l.xform.pos, expected, 1e-6f));
}

// Rotate about the pivot leaves pos untouched, for BOTH a world gesture axis
// and an item-anchored one — L1's consequence (P == c), not L3's, so it must
// hold under either frame.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(4, -1, 2);
    l.xform.rot = Vec3(0, 25, 0);
    l.xform.scl = Vec3(1, 1, 1);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    import vibe3d.util.math.math : pivotRotationMatrix;
    float[16] rg = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), 0.7f);

    bool changed = applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), rg, Vec3(1,1,1));

    assert(changed);
    assert(vecClose(l.xform.pos, baselines[0].pos, 1e-5f),
           "rotate about the pivot must leave pos untouched");
}

// Scale about the pivot leaves pos untouched — same P==c argument as rotate.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(-2, 3, 1);
    l.xform.rot = Vec3(0, 0, 0);
    l.xform.scl = Vec3(1, 1, 1);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    bool changed = applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(2, 1, 1));

    assert(changed);
    assert(vecClose(l.xform.pos, baselines[0].pos, 1e-5f),
           "scale about the pivot must leave pos untouched");
}

// THE SAME-INDEX RULE (L4) — a direct replay of phase0b_findings.md, the
// most important unittest in this module. Base scl=(1,1,1), rot=(0,theta,0)
// for theta in {30,60,90}, gesture sFactor=(2,1,1) in the WORLD frame.
// Expect scl'==(2,1,1) at ALL THREE angles, rot' bit-identical (matrix-
// exact) to the input, and the composed linear part equal to
// R_y(theta)*diag(2,1,1).
//
// The 90-degree case is the one that would have been written backwards, and
// it MUST carry this comment: at 90 degrees the item's local Z lies along
// world X, so the geometrically exact answer is (1,1,2) — and the reference
// writes (2,1,1) anyway (phase0b_findings.md, the "90-degree control"). Do
// NOT "fix" this back to (1,1,2); that is the refuted candidate D3/the
// refuted exact-conjugation formula, not this law.
unittest {
    import std.math : PI;
    import std.conv : to;
    foreach (thetaDeg; [30.0f, 60.0f, 90.0f]) {
        auto l = new Layer();
        l.xform.pos = Vec3(0, 0, 0);
        l.xform.rot = Vec3(0, thetaDeg, 0);
        l.xform.scl = Vec3(1, 1, 1);
        ItemXform[] baselines = [l.xform];
        Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

        bool changed = applyGestureToItems([l], baselines, centre,
            Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
            Vec3(0,0,0), identityMatrix, Vec3(2, 1, 1));

        assert(changed);
        assert(vecClose(l.xform.scl, Vec3(2, 1, 1), 1e-6f),
               "same-index rule must hold at theta=" ~ thetaDeg.to!string);
        assert(l.xform.rot == baselines[0].rot,
               "an identity-rGesture scale must leave rot bit-identical");

        import vibe3d.util.math.math : matrixFromEulerZYX, pivotRotationMatrix;
        float[16] expectedLinear = matMul4(
            pivotRotationMatrix(Vec3(0,0,0), Vec3(0,1,0), thetaDeg * cast(float)(PI/180.0)),
            [2,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]);
        float[16] actualLinear = matMul4(matrixFromEulerZYX(l.xform.rot),
            [l.xform.scl.x,0,0,0, 0,l.xform.scl.y,0,0, 0,0,l.xform.scl.z,0, 0,0,0,1]);
        assert(matClose(actualLinear, expectedLinear, 1e-5f),
               "composed linear part must equal R_y(theta)*diag(2,1,1) at theta="
             ~ thetaDeg.to!string);
    }
}

// Uniform scale is exact at any rotation — falls out of the one same-index
// formula, no branch needed: k*I commutes with any rotation.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(0, 0, 0);
    l.xform.rot = Vec3(0, 30, 0);
    l.xform.scl = Vec3(1, 1, 1);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(3, 3, 3));

    import vibe3d.util.math.math : matrixFromEulerZYX;
    float[16] actualLinear = matMul4(matrixFromEulerZYX(l.xform.rot),
        [l.xform.scl.x,0,0,0, 0,l.xform.scl.y,0,0, 0,0,l.xform.scl.z,0, 0,0,0,1]);
    float[16] expectedLinear = matMul4(matrixFromEulerZYX(Vec3(0,30,0)),
        [3,0,0,0, 0,3,0,0, 0,0,3,0, 0,0,0,1]);
    assert(matClose(actualLinear, expectedLinear, 1e-5f));
}


// Rotate composes matrix-exactly, INCLUDING a base pitch of exactly +-90 deg
// and +-89.999 deg (the gimbal band eulerZYXFromMatrix canonicalises — REVIEW-3):
// matrixFromEulerZYX(rot') ~= rGesture * matrixFromEulerZYX(base.rot).
unittest {
    import vibe3d.util.math.math : pivotRotationMatrix;
    import std.conv : to;
    foreach (ry; [90.0f, -90.0f, 89.999f, -89.999f]) {
        auto l = new Layer();
        l.xform.rot = Vec3(12, ry, -7);
        auto baselines = [l.xform];
        Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);
        float[16] rg = pivotRotationMatrix(Vec3(0,0,0), Vec3(1,0,0), 0.4f);

        applyGestureToItems([l], baselines, centre,
            Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
            Vec3(0,0,0), rg, Vec3(1,1,1));

        import vibe3d.util.math.math : matrixFromEulerZYX;
        float[16] expected = matMul4(rg, matrixFromEulerZYX(baselines[0].rot));
        float[16] actual   = matrixFromEulerZYX(l.xform.rot);
        assert(matClose(actual, expected, 1e-4f),
               "matrix-exact rotate composition failed at ry=" ~ ry.to!string);
    }
}

// NIT (0614 review) — the rotate composition ORDER (kernel: rGesture LEFT-
// multiplies the base, `matMul4(rGesture, matrixFromEulerZYX(base.rot))` —
// a world-space-gesture convention) was pinned only by tests that could
// never catch a wrong CHOICE of order: the unittest above computes its
// `expected` via the exact same expression the kernel uses (restates the
// implementation, doesn't independently verify it), the drag test
// (test_item_drag_rotate_scale.d) only asserts SOME rotation happened, and
// the cross-engine parity rig (test_item_drag_law_parity.d) starts from an
// IDENTITY base rotation, where left- and right-multiply coincide (I * X ==
// X * I) — none of the three can distinguish "correct order" from "any
// order that changes something".
//
// This fixture picks a base rotation and a gesture axis that do NOT
// commute, so the two candidate orders land at genuinely different
// matrices, and asserts the kernel matches the LEFT-multiply candidate
// while explicitly ruling out the RIGHT-multiply one.
unittest {
    import vibe3d.util.math.math : pivotRotationMatrix, matrixFromEulerZYX;
    auto l = new Layer();
    l.xform.rot = Vec3(15, 25, -10);   // non-identity, non-axis-aligned base
    auto baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    float[16] rg    = pivotRotationMatrix(Vec3(0,0,0), Vec3(1,0,0), 0.5f);
    float[16] baseM = matrixFromEulerZYX(baselines[0].rot);

    float[16] leftMul  = matMul4(rg, baseM);   // gesture applied in the WORLD frame
    float[16] rightMul = matMul4(baseM, rg);   // gesture applied in the ITEM's own frame

    // Sanity: the rig must actually discriminate the two candidate orders,
    // or a passing match below could be coincidence.
    assert(!matClose(leftMul, rightMul, 1e-4f),
           "test rig must discriminate left- from right-multiply — pick a "
         ~ "base rotation / gesture axis pair that does not commute");

    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), rg, Vec3(1,1,1));

    float[16] actual = matrixFromEulerZYX(l.xform.rot);
    assert(matClose(actual, leftMul, 1e-4f),
           "gesture rotation must LEFT-multiply the base (world-space "
         ~ "compose, matching the drag convention) — got a different order "
         ~ "than expected");
    assert(!matClose(actual, rightMul, 1e-4f),
           "the kernel must NOT right-multiply (item-local compose) — that "
         ~ "would be the WRONG order for a world-frame gesture");
}

// With a held rotation, translation remains outside the linear fold.
unittest {
    import vibe3d.util.math.math : pivotRotationMatrix;
    import std.math : PI;
    auto l = new Layer();
    l.xform.pos = Vec3(0, 0, 0);
    l.xform.rot = Vec3(0, 0, 0);
    auto baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    float[16] rg = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), cast(float)(PI / 2.0));
    Vec3 tLocal = Vec3(5, 0, 0);
    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        tLocal, rg, Vec3(1,1,1));

    // Formula expectation: pos moves by tLocal expanded through the world frame.
    assert(vecClose(l.xform.pos, Vec3(5, 0, 0), 1e-4f),
           "translate held with a gesture rotation must NOT be re-rotated");
}

// Degenerate scale (zero / NaN / inf) is clamped or rejected; sign preserved.
unittest {
    auto l = new Layer();
    l.xform.scl = Vec3(2, -3, 1);
    auto baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(0, float.nan, float.infinity));

    assert(isClose(l.xform.scl.x, MIN_ITEM_SCALE_MAG, 1e-6f),
           "a zero-factor scale must clamp to the positive floor, not sit at 0");
    assert(l.xform.scl.y == baselines[0].scl.y,
           "a NaN factor must leave the baseline component untouched");
    // baselines[0].scl.z * inf = inf -> rejected (non-finite result), so the
    // baseline component (1) is kept.
    assert(l.xform.scl.z == baselines[0].scl.z,
           "an infinite result must leave the baseline component untouched");

    // Negative baseline * positive factor -> negative result under the
    // floor: sign preserved, magnitude floored.
    auto l2 = new Layer();
    l2.xform.scl = Vec3(1, 1, 1);
    auto b2 = [l2.xform];
    Vec3 c2 = applyAffine(l2.xform.composedMatrix(), l2.xform.pivot);
    applyGestureToItems([l2], b2, c2, Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(-0.0000001f, 1, 1));
    assert(isClose(l2.xform.scl.x, -MIN_ITEM_SCALE_MAG, 1e-6f),
           "a tiny negative result must floor to the NEGATIVE magnitude, sign preserved");
}

// The CEILING, on the GESTURE path (task 0614 Phase 5 review, SF1).
//
// This case exists because the ceiling had no test at all that could see it.
// The floor/NaN/inf case above never reaches it, and the HTTP `scl.z 1e30`
// case is satisfied by `Param.max(MAX_ITEM_SCALE_MAG).enforceBounds()` at
// inject time — that write never enters `clampedScaleComponent`, so deleting
// the kernel's two ceiling lines left the whole suite green.
//
// ONE call discriminates BOTH wrong implementations, which is why the baseline
// is NEGATIVE and the factor is huge:
//   * ceiling omitted from the kernel      → scl.x lands at -3e9  (uncapped)
//   * ceiling clamps to +MAX ignoring sign → scl.x lands at +1e6  (un-mirrored)
// Only "cap the MAGNITUDE, keep the sign" produces -1e6. A positive baseline
// would make the second implementation indistinguishable from the correct one.
//
// -3e9 is finite in float (max ~3.4e38), so this is genuinely the ceiling's
// job — `clampedScaleComponent`'s non-finite rejection cannot cover for it.
unittest {
    import std.math : isFinite;
    import std.conv : to;
    auto l = new Layer();
    l.xform.scl = Vec3(-3, 1, 1);
    auto baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(1e9f, 1, 1));

    assert(isClose(l.xform.scl.x, -MAX_ITEM_SCALE_MAG, 1e-6f),
           "an absurd gesture factor on a NEGATIVE baseline must cap at the "
         ~ "negative ceiling -1e6 (magnitude capped, mirror preserved) — got "
         ~ l.xform.scl.x.to!string);
    assert(l.xform.scl.x < 0,
           "the cap must not un-mirror the item: a ceiling that clamps to "
         ~ "+MAX regardless of sign silently flips a mirrored item back");
    // The point of the ceiling: the capped value still composes finitely.
    foreach (v; l.xform.composedMatrix())
        assert(isFinite(v), "a capped scale composes to a finite matrix");
}
