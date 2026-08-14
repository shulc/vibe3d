module tools.transform.item_xform_kernels;

// Task 0614 Phase 3 (doc/item_mode_transform_plan.md section (c)) — the pure
// item-transform law: how ONE gesture (a translate local to a FROZEN input
// frame + a gesture rotation matrix + a per-frame-axis scale factor)
// rewrites an item's `ItemXform` (document.d), never touching
// `mesh.vertices`. No app/GL/mesh dependency beyond math + document, so this
// module is exercised entirely by `dub test --config=tests` — no HTTP, no
// GL, no live app.
//
// Every law here is per-bank ANALYTIC — never a general matrix decomposition
// — and every law is MEASURED, not designed:
//   L1 (centre = item world pivot)  — doc/tasks/0614-evidence/phase0_findings.md case A
//   L3 (default basis = WORLD)      — same file, case A'
//   L4 (scale = SAME INDEX, always) — doc/tasks/0614-evidence/phase0b_findings.md case D
//
// L4 in one sentence, because it is the one a careful re-derivation will
// "correct" back to the wrong answer: a gesture scale factor along frame
// axis j multiplies the item's own scl[j] UNCONDITIONALLY — no conjugation
// by the item's own rotation, no exception at the 90-degree control where an
// exactly-representable alternative exists. The reference does not take it.

import math : Vec3, matMul4, matrixFromEulerZYX, eulerZYXFromMatrix,
              applyAffine, scaleAlongBasis, identityMatrix;
import document : Layer, ItemXform;

/// Degenerate-scale floor + ceiling (two-layer guard, R7 — this module is the
/// KERNEL half; the authored-Param half is `layer_params.d`). A hard cap so a
/// headless caller cannot author a singular `ItemXform` through this kernel.
/// Sign is preserved deliberately — a negative scale is a legitimate mirror
/// (`XfrmTransformTool.negScale`), not a value to clamp to a positive floor.
///
/// Both bounds are DECLARED in `document.d` (next to `ItemXform` itself) and
/// re-exported here so the two enforcement layers cannot drift apart; see the
/// rationale on the declaration. The re-export keeps every existing reader of
/// `tools.transform.item_xform_kernels.MIN_ITEM_SCALE_MAG` resolving.
public import document : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;

/// `base * factor`, guarded: a non-finite FACTOR is rejected outright (the
/// baseline component is returned untouched — never propagate a NaN/Inf
/// gesture into the item), then the RESULT's magnitude is clamped into
/// `[MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG]`, sign preserved.
/// `Param.enforceBounds()` has a known NaN hole (doc/param_bounds_plan.md) —
/// this finite check is explicit here, not implied by a min/max pair.
///
/// The two ends are enforced together on purpose: a headless
/// `tool.attr scale SX 1e30; tool.doApply` is as reachable as a gesture, and a
/// finite-but-absurd scale overflows to infinity at the first matrix product,
/// which is the same non-finite state the floor exists to keep out.
private float clampedScaleComponent(float baseVal, float factor) pure nothrow @nogc @safe {
    import std.math : isFinite, fabs;
    if (!isFinite(factor)) return baseVal;
    immutable float v = baseVal * factor;
    if (!isFinite(v)) return baseVal;
    if (fabs(v) < MIN_ITEM_SCALE_MAG)
        return v < 0 ? -MIN_ITEM_SCALE_MAG : MIN_ITEM_SCALE_MAG;
    if (fabs(v) > MAX_ITEM_SCALE_MAG)
        return v < 0 ? -MAX_ITEM_SCALE_MAG : MAX_ITEM_SCALE_MAG;
    return v;
}

/// Apply ONE gesture to every target's `ItemXform`, in place, and report
/// whether anything changed.
///
///   `targets`     — the items to write (mutated in place via `.xform`).
///                    Phase 3 passes a one-element slice (the primary);
///                    Phase 6 widens this to the whole selected set — the
///                    signature is N-ready from day one.
///   `baselines`   — target `i`'s RUN-START xform (`itemDragBaseline`),
///                    restored into `targets[i].xform` by the caller BEFORE
///                    this call (mirrors the vertex path's
///                    `restoreBaseline()` — REVIEW-1 / Phase 2.5).
///   `centreWorld` — the FROZEN action-centre origin (`runFrameOrigin`,
///                    R15). NEVER the live per-frame ACEN pivot: on a
///                    composed T+R run the live pivot has already moved by
///                    the T term, and rotating a secondary item about a
///                    moving centre corrupts the R term. For Phase 3
///                    (primary-only) this is bit-identical to the primary's
///                    own world pivot (`P`, computed below) by construction
///                    — see the comment at the P computation.
///   `iX/iY/iZ`    — the FROZEN input frame (world axes by default, L3;
///                    never a live re-derived `currentBasis`, REVIEW-1).
///   `tLocal`      — the run-absolute translate, expressed IN THAT FRAME.
///   `rGesture`    — the run-absolute gesture rotation: a PURE linear
///                    rotation about the origin (zero translation column),
///                    matching how xfrm_transform.d builds `run.r`.
///   `sFactor`     — the run-absolute per-FROZEN-FRAME-axis scale factor
///                    (L4 — indexed by frame axis, not world axis; the two
///                    coincide under the default frame).
///
/// Returns `changed` — whether ANY target's xform differs from its baseline
/// — NOT `accepted`. There is no gesture this kernel declines: L4 retired
/// the representability predicate (and the exact/remainder phase split, and
/// the now-tombstoned R5) that used to live here. `changed` exists purely so
/// the caller (`XfrmTransformTool`'s item commit branch) can skip recording
/// a no-op gesture, mirroring `buildEditCmd`'s `if (!changed) return null`
/// (tools/transform/transform.d).
bool applyGestureToItems(Layer[] targets, const(ItemXform)[] baselines,
                          Vec3 centreWorld, Vec3 iX, Vec3 iY, Vec3 iZ,
                          Vec3 tLocal, const float[16] rGesture, Vec3 sFactor)
{
    assert(targets.length == baselines.length,
           "applyGestureToItems: targets/baselines length mismatch");

    // Whole-gesture identity fast path. Guarantees composedMatrix() stays
    // BIT-UNCHANGED for a genuinely no-op frame: a generic round-trip
    // through composedMatrix()/applyAffine is only ALGEBRAICALLY a no-op
    // (the same "1-ULP round-trip" hazard the pre-0061 vertex formula hit —
    // see xfrm_transform.d's own comment on that fix) — a literal field
    // copy sidesteps the question rather than trusting the float chain to
    // cancel exactly.
    immutable bool gestureIsIdentity =
        tLocal.x == 0 && tLocal.y == 0 && tLocal.z == 0
     && sFactor.x == 1 && sFactor.y == 1 && sFactor.z == 1
     && rGesture == identityMatrix;

    immutable bool rotIdentity   = rGesture == identityMatrix;
    immutable bool scaleIdentity = sFactor.x == 1 && sFactor.y == 1 && sFactor.z == 1;

    // The <<star>> de-rotation: the frozen frame expands tLocal into ONE
    // world-space delta, added AFTER the rotate term (never composed THROUGH
    // rGesture) — so a held rotation from THIS SAME gesture never re-rotates
    // a held translate (the reference bug this guards against on the vertex
    // side: [[project_rotate_then_move_frame_bug]]). A held SCALE, unlike
    // rotate, DOES reach this delta — see the position-law comment below,
    // where `worldDelta` is folded into `combined` before scale is applied.
    immutable Vec3 worldDelta = Vec3(
        iX.x*tLocal.x + iY.x*tLocal.y + iZ.x*tLocal.z,
        iX.y*tLocal.x + iY.y*tLocal.y + iZ.y*tLocal.z,
        iX.z*tLocal.x + iY.z*tLocal.y + iZ.z*tLocal.z);

    bool changed = false;
    foreach (i; 0 .. targets.length) {
        const ItemXform base = baselines[i];

        if (gestureIsIdentity) {
            targets[i].xform = base;
            continue;
        }

        // L1 — the item's WORLD PIVOT, computed via the SAME expression
        // (`composedMatrix()` then `applyAffine`) that
        // `ActionCenterStage.itemPivotWorld()` uses to produce
        // `centreWorld` in the first place. For Phase 3 (primary-only),
        // `centreWorld` was frozen from THIS SAME baseline on the run's
        // first apply, so `P` and `centreWorld` are the SAME function
        // applied to the SAME input — bit-identical, not merely close. That
        // is what makes `P - centreWorld` cancel to EXACT zero below rather
        // than an epsilon. Swapping in the algebraically-equal-but-
        // differently-rounded `base.pos + base.pivot` shortcut here would
        // reintroduce exactly the drift R15 exists to prevent.
        immutable Vec3 P = applyAffine(base.composedMatrix(), base.pivot);

        // Position law — mirrors the VERTEX fold's own composed chain
        // (xfrm_transform.d's `composeFor`: M = S.R.T, T RIGHTMOST i.e.
        // applied first) rather than three independent per-bank formulas,
        // because that chain has an observable cross-bank interaction this
        // kernel must reproduce for a composed run: a held SCALE multiplies
        // a held TRANSLATE too (S is the OUTERMOST operation). Concretely,
        // for a vertex v about pivot c: result = c + S.(R.(v-c) + worldDelta)
        // — the vertex path's own de-rotation (xfrm_transform.d's "TRANSLATE
        // TERM DE-ROTATION, invariant *") makes the T contribution equal
        // worldDelta UN-rotated before S is applied to the sum. Evaluated at
        // v == the item's own world pivot (rel == P-centreWorld, which is
        // exactly zero for Phase 3's primary-only case, L1): the ROTATE term
        // vanishes regardless of order (R.0 == 0), so the only run-visible
        // interaction is T-then-S — reproduced exactly here. R-then-S order
        // is UNMEASURED and unobservable at Phase 3 for the same reason
        // (rel == 0 either way) — see the R+S exclusion in
        // test_item_drag_law_parity.d.
        immutable Vec3 rel = P - centreWorld;
        Vec3 afterR = rel;
        if (!rotIdentity) afterR = applyAffine(rGesture, rel);   // rGesture: zero translation, so this is R.rel

        immutable Vec3 combined = Vec3(afterR.x + worldDelta.x,
                                        afterR.y + worldDelta.y,
                                        afterR.z + worldDelta.z);

        // A held rGesture==I (a pure translate/scale gesture) must leave rot
        // bit-identical to the baseline — NOT round-tripped through
        // matrixFromEulerZYX/eulerZYXFromMatrix, which is only an
        // ALGEBRAIC identity (sin/asin/atan2 do not round-trip bit-exact in
        // general, even away from the gimbal band). This mirrors the
        // scale-bank formula verbatim: "rot' = base.rot // never touched".
        immutable Vec3 rotNew = rotIdentity
            ? base.rot
            : eulerZYXFromMatrix(matMul4(rGesture, matrixFromEulerZYX(base.rot)));

        // Scale is the OUTERMOST operation (S.R.T): it scales the WHOLE
        // combined (rotated-offset + translate) vector, along the FROZEN
        // FRAME axes — the same axes the same-index rule (L4) keys off. The
        // pivot for this scale is the ORIGIN (not centreWorld): `combined`
        // is already expressed as an offset FROM centreWorld, so scaling it
        // about the origin and adding centreWorld back (below) is exactly
        // "scale about centreWorld", one fewer subtraction than passing
        // centreWorld into scaleAlongBasis a second time.
        immutable Vec3 scaledCombined = scaleIdentity
            ? combined
            : scaleAlongBasis(combined, Vec3(0, 0, 0), iX, iY, iZ,
                               sFactor.x, sFactor.y, sFactor.z);

        // L4 — the SAME-INDEX rule, capture-verified at 30/60/90 degrees
        // (phase0b_findings.md). The gesture factor along frame axis j
        // multiplies the item's own scl[j], unconditionally: no R_base
        // term, no matrix conjugation, no exception at the 90-degree
        // control where a geometrically exact alternative exists and is
        // deliberately NOT taken by the reference. A plain component-wise
        // multiply, clamped only against degeneracy (R7).
        immutable Vec3 sclNew = Vec3(
            clampedScaleComponent(base.scl.x, sFactor.x),
            clampedScaleComponent(base.scl.y, sFactor.y),
            clampedScaleComponent(base.scl.z, sFactor.z));

        immutable Vec3 Pfinal = Vec3(centreWorld.x + scaledCombined.x,
                                      centreWorld.y + scaledCombined.y,
                                      centreWorld.z + scaledCombined.z);

        ItemXform next;
        next.pivot = base.pivot;   // the pivot channel is never written by a gesture
        next.rot   = rotNew;
        next.scl   = sclNew;
        // pos' = P_final - pivot: the local pivot is a fixed point of R*S
        // for ANY rot/scl (see `ItemXform` in document.d), so the local
        // pivot channel never needs a compensating write, for any bank.
        next.pos   = Pfinal - next.pivot;

        if (next.pos.x != base.pos.x || next.pos.y != base.pos.y || next.pos.z != base.pos.z
         || next.rot.x != base.rot.x || next.rot.y != base.rot.y || next.rot.z != base.rot.z
         || next.scl.x != base.scl.x || next.scl.y != base.scl.y || next.scl.z != base.scl.z)
            changed = true;

        targets[i].xform = next;
    }
    return changed;
}

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

// Identity gesture leaves composedMatrix() bit-unchanged — asserted on the
// MATRIX, not the euler triple (REVIEW-3): eulerZYXFromMatrix canonicalises
// in the gimbal band, so a base rot that is already non-canonical can
// legitimately show a different (but matrix-equivalent) triple. Here the
// gesture is a hard no-op (the identity fast path), so even the triple is
// untouched — this is the strongest case, not merely the matrix-only one.
unittest {
    auto l = new Layer();
    l.xform.pos = Vec3(1, 2, 3);
    l.xform.rot = Vec3(10, 20, 30);
    l.xform.scl = Vec3(2, 3, 4);
    l.xform.pivot = Vec3(0.5f, -1, 2);
    ItemXform[] baselines = [l.xform];
    Vec3 centre = applyAffine(l.xform.composedMatrix(), l.xform.pivot);

    bool changed = applyGestureToItems([l], baselines, centre,
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
        Vec3(0,0,0), identityMatrix, Vec3(1,1,1));

    assert(!changed, "identity gesture must report changed=false");
    assert(l.xform.pos == baselines[0].pos);
    assert(l.xform.rot == baselines[0].rot);
    assert(l.xform.scl == baselines[0].scl);
    assert(l.xform.pivot == baselines[0].pivot);
}

// T+S composed in ONE gesture: SCALE is the OUTERMOST operation in the
// vertex fold's own chain (composeFor: M = S.R.T), so a held scale
// multiplies a held translate's world-space delta too. This test locks in
// that cross-bank interaction: Pfinal must equal centre + S.worldDelta, NOT
// centre + worldDelta (the simpler, WRONG law an earlier draft of this
// kernel shipped — see the position-law comment above `rel` in
// applyGestureToItems). Default pivot=(0,0,0) rig so P == centreWorld
// exactly (Phase 3, L1), which is what makes the rotate term vanish and
// isolates the T-then-S interaction cleanly.
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

    // worldDelta == tLocal under the world default frame; expected pos is
    // centre + sFactor (componentwise) * worldDelta, i.e. (8, 3, -1).
    Vec3 expected = Vec3(8, 3, -1);
    assert(vecClose(l.xform.pos, expected, 1e-5f),
           "a held scale must multiply a held translate's world delta (S.R.T chain)");
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

    import math : pivotRotationMatrix;
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

        import math : matrixFromEulerZYX, pivotRotationMatrix;
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

    import math : matrixFromEulerZYX;
    float[16] actualLinear = matMul4(matrixFromEulerZYX(l.xform.rot),
        [l.xform.scl.x,0,0,0, 0,l.xform.scl.y,0,0, 0,0,l.xform.scl.z,0, 0,0,0,1]);
    float[16] expectedLinear = matMul4(matrixFromEulerZYX(Vec3(0,30,0)),
        [3,0,0,0, 0,3,0,0, 0,0,3,0, 0,0,0,1]);
    assert(matClose(actualLinear, expectedLinear, 1e-5f));
}

// No gesture is refused: L4 deleted the decline path (the retired R5). Every
// combination below must leave `changed == true` (nothing silently no-ops).
unittest {
    auto mk = () {
        auto l = new Layer();
        l.xform.rot = Vec3(0, 47, 0);
        return l;
    };
    import math : pivotRotationMatrix;

    auto l1 = mk();
    auto b1 = [l1.xform];
    assert(applyGestureToItems([l1], b1, applyAffine(l1.xform.composedMatrix(), l1.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(1,0,0), identityMatrix, Vec3(1,1,1)));

    auto l2 = mk();
    auto b2 = [l2.xform];
    float[16] rg = pivotRotationMatrix(Vec3(0,0,0), Vec3(0,0,1), 0.3f);
    assert(applyGestureToItems([l2], b2, applyAffine(l2.xform.composedMatrix(), l2.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(0,0,0), rg, Vec3(1,1,1)));

    auto l3 = mk();
    auto b3 = [l3.xform];
    assert(applyGestureToItems([l3], b3, applyAffine(l3.xform.composedMatrix(), l3.xform.pivot),
        Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), Vec3(0,0,0), identityMatrix, Vec3(0.3f, 5, 1)));
}

// Rotate composes matrix-exactly, INCLUDING a base pitch of exactly +-90 deg
// and +-89.999 deg (the gimbal band eulerZYXFromMatrix canonicalises — REVIEW-3):
// matrixFromEulerZYX(rot') ~= rGesture * matrixFromEulerZYX(base.rot).
unittest {
    import math : pivotRotationMatrix;
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

        import math : matrixFromEulerZYX;
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
    import math : pivotRotationMatrix, matrixFromEulerZYX;
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

// Translate-after-rotate is UN-ROTATED (the <<star>> de-rotation): with a held
// rGesture, tLocal must move the item by the frame expansion of tLocal alone,
// NOT by rGesture applied to that delta.
unittest {
    import math : pivotRotationMatrix;
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

    // Un-rotated expectation: pos moves by exactly tLocal expanded through
    // the WORLD frame (5,0,0) — NOT rg*(5,0,0) == (0,5,0).
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
