module vibe3d.editing.tools.transform.tools.transform.item_xform_kernels;

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

import vibe3d.util.math.math : Vec3, matMul4, matrixFromEulerZYX, eulerZYXFromMatrix,
              applyAffine, scaleAlongBasis, identityMatrix;
import vibe3d.documents.model.document : Layer, ItemXform;

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
public import vibe3d.documents.model.document : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;

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

    // The frozen frame expands tLocal into one world-space delta. It is added
    // after the complete linear fold, so neither rotation nor scale reaches it.
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

        // Position law mirrors the vertex fold: rotate and scale the offset
        // from the run centre, then add worldDelta. For the primary item the
        // offset is exactly zero, but keeping the full expression also covers
        // every other selected item in the same run.
        immutable Vec3 rel = P - centreWorld;
        Vec3 afterR = rel;
        if (!rotIdentity) afterR = applyAffine(rGesture, rel);   // rGesture: zero translation, so this is R.rel

        // A held rGesture==I (a pure translate/scale gesture) must leave rot
        // bit-identical to the baseline — NOT round-tripped through
        // matrixFromEulerZYX/eulerZYXFromMatrix, which is only an
        // ALGEBRAIC identity (sin/asin/atan2 do not round-trip bit-exact in
        // general, even away from the gimbal band). This mirrors the
        // scale-bank formula verbatim: "rot' = base.rot // never touched".
        immutable Vec3 rotNew = rotIdentity
            ? base.rot
            : eulerZYXFromMatrix(matMul4(rGesture, matrixFromEulerZYX(base.rot)));

        // Scale the rotated relative position, then add translation. Translation
        // is outside the linear fold and is therefore never scaled (task 6207).
        immutable Vec3 scaledRelative = scaleIdentity
            ? afterR
            : scaleAlongBasis(afterR, Vec3(0, 0, 0), iX, iY, iZ,
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

        immutable Vec3 Pfinal = Vec3(centreWorld.x + scaledRelative.x + worldDelta.x,
                                      centreWorld.y + scaledRelative.y + worldDelta.y,
                                      centreWorld.z + scaledRelative.z + worldDelta.z);

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
