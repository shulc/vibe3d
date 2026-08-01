module tools.transform.relocate_plane;

// ---------------------------------------------------------------------------
// Where a click-relocate lands in world.
//
// The reference implementation is four nested functions; this module is a
// 1:1 restatement of them as pure functions, so each can be tested on its
// own and the composition tested against the one rig that measured it.
//
//   principalPlaneCenter(...)          the whole chain, entry to answer
//     +- workPlanePoint(...)           the plane point Q and the axis k
//     |    +- niceOrigin(...)          Q = focus, snapped, then QUANTISED on k
//     |    |    +- vectorSnap(...)     component-wise round to a step
//     |    +- biasedAxis(...)          the preferred-work-plane bias
//     +- posToPrincipalPlane(...)      the ray, or the locked-axis shortcut
//          +- vectorSnap(...)          the final snap of the ANSWER
//
// Two things in this file are the whole point, and both were missing:
//
// 1. `niceOrigin` QUANTISES the plane point's out-of-plane coordinate. The
//    plane through the camera focus is not the plane through the focus — it
//    is the plane through the focus ROUNDED. On a camera whose focus sits at
//    the world origin this is the identity, which is why every fixture we own
//    is blind to it.
//
// 2. `posToPrincipalPlane` does not always cast a ray. In an axis-locked
//    orthographic view (top/bottom/front/back/left/right) it replaces one
//    coordinate of the unprojected click and stops.
//
// WHAT IS MEASURED AND WHAT IS CHOSEN. The structure below is read out of the
// reference instruction by instruction and is not fitted. Its INPUTS are a
// different matter: vibe3d has no counterpart for any of them, and every one
// is defaulted to the value at which the reference itself skips the feature.
// See `RelocatePlanePrefs`, and in particular `quantumStep` — the rounding in
// (1) is implemented and tested but NOT switched on, because the number it
// rounds to is contradicted between the two rigs that measured it. That is
// written up at the field.
//
// WHAT THIS CHANGES IN THE PRODUCT TODAY: NOTHING. That is a claim about the
// wiring, and it is checked in both directions:
//
//   * with every optional term at its default the ray arm is
//     `t = (Q[k] - P0[k]) / D[k]` with `Q = focus`, which is a plane
//     intersection against `x[k] = focus[k]` — the plane the relocate call
//     site already built from `pickMostFacingPlane`, term for term;
//   * the no-ray arm (2) fires only in an axis-locked orthographic view,
//     where the ray is parallel to `e_k`, so replacing coordinate `k` is
//     exactly what intersecting the camera-perpendicular plane through the
//     focus already did.
//
// The port's gain is therefore structural, not numerical: the law is stated
// where it was read, every term it has is named and testable, and the
// parallel-ray degeneracy the old code dodged with a plane swap cannot arise
// in an arm that never intersects anything. Nothing here is a licence to
// change a landing; a term that would change one is dormant until a
// measurement turns it on.
//
// THE LOCK ARM IS PORTED BUT NOT WIRED, and that is deliberate. See
// `RelocatePlanePrefs.lock`.
// ---------------------------------------------------------------------------

import math : Vec3, Viewport, isOrtho, normalize, dot;
import std.math : abs, floor, ceil;

/// Round half AWAY FROM ZERO — the reference's `Dnint`, which is Fortran's
/// rounding and NOT C's `rint` (half-to-even).
///
/// The tie rule is NOT pinned by any measurement we hold: none of the 18
/// components in the rig that fixed this law lands on an exact half. It is
/// written half-away-from-zero because that is what `Dnint` means, not
/// because a capture chose it.
float dnint(float x) @safe pure nothrow @nogc {
    return x >= 0 ? floor(x + 0.5f) : ceil(x - 0.5f);
}

/// Component-wise `Dnint(v/step)*step`. A step of zero or less is the
/// reference's "disabled" value and returns `v` untouched — the function
/// returns immediately in that case, it does not round by 0.
Vec3 vectorSnap(Vec3 v, float step) @safe pure nothrow @nogc {
    if (step <= 0) return v;
    return Vec3(dnint(v.x / step) * step,
                dnint(v.y / step) * step,
                dnint(v.z / step) * step);
}

/// One component of a Vec3 by index (0=x, 1=y, 2=z).
float axisComp(Vec3 v, int i) @safe pure nothrow @nogc {
    return i == 0 ? v.x : (i == 1 ? v.y : v.z);
}

/// `v` with component `i` replaced.
Vec3 withAxisComp(Vec3 v, int i, float c) @safe pure nothrow @nogc {
    if (i == 0) return Vec3(c, v.y, v.z);
    if (i == 1) return Vec3(v.x, c, v.z);
    return Vec3(v.x, v.y, c);
}

/// The world axis a view is locked to, or -1 when it has none.
///
/// The reference reads a view TYPE field and decodes it to an axis; we have
/// no such field on `Viewport`, so the same class of view is recognised
/// GEOMETRICALLY: an orthographic projection whose forward vector is a world
/// axis. In vibe3d that is exactly `ProjKind.Ortho` with one of the six
/// `ViewPreset` axis presets, because `View.viewportWith` builds those six
/// from a hard-coded axis eye and ignores azimuth/elevation.
///
/// The two ways to be ortho WITHOUT a locked axis — `ViewPreset.Perspective`
/// or `.Camera` under `ProjKind.Ortho`, which keep the free spherical basis —
/// return -1 here unless the free camera happens to be exactly axis-aligned.
/// That coincidence is measure-zero and costs nothing when it happens: with
/// the rays parallel to `e_k` the ray arm and the locked arm agree on every
/// component except the quantum on the plane point.
int lockedViewAxis(const ref Viewport vp) @safe pure nothrow @nogc {
    if (!isOrtho(vp)) return -1;
    // Column-major view matrix: forward = (-m[2], -m[6], -m[10]).
    Vec3 f = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    enum float axisEps = 1e-4f;
    if (abs(abs(f.x) - 1.0f) < axisEps && abs(f.y) < axisEps && abs(f.z) < axisEps) return 0;
    if (abs(abs(f.y) - 1.0f) < axisEps && abs(f.x) < axisEps && abs(f.z) < axisEps) return 1;
    if (abs(abs(f.z) - 1.0f) < axisEps && abs(f.x) < axisEps && abs(f.y) < axisEps) return 2;
    return -1;
}

/// The eye vector at a world point: the direction the view looks ALONG as it
/// passes through `p`. Perspective diverges from the eye, orthographic is
/// constant.
Vec3 eyeVectorAt(const ref Viewport vp, Vec3 p) @safe pure nothrow @nogc {
    if (isOrtho(vp)) return normalize(Vec3(-vp.view[2], -vp.view[6], -vp.view[10]));
    return normalize(p - vp.eye);
}

/// The four shipped work-plane preferences, the view's own snap step, and the
/// out-of-plane quantum.
///
/// EVERY DEFAULT HERE IS "OFF", AND THAT IS DELIBERATE. No capture in this
/// campaign recorded any of them, so a default that changed behaviour would
/// be inventing a measurement. Each default below is also the value at which
/// the reference's own gate skips the feature, so "off" is a faithful port of
/// the disabled state rather than a stub.
struct RelocatePlanePrefs {
    /// The bias toward `preferredAxis`. The reference gates the whole swap on
    /// `strength > 0`, so zero disables it exactly.
    float strength = 0.0f;
    /// The preferred work-plane axis (0=X, 1=Y, 2=Z), or -1 for none. The
    /// reference falls through to the argmax for any value outside {0,1,2}.
    int   preferredAxis = -1;
    /// Lock the work plane instead of letting it follow the view rotation.
    ///
    /// PORTED, TESTED, AND DELIBERATELY NOT WIRED TO ANYTHING. vibe3d's
    /// pinned work plane is strictly MORE expressive than the state this arm
    /// represents, so there is no lossless way to feed it:
    ///
    ///   * this arm's entire pinned state is one axis INDEX (`preferredAxis`)
    ///     plus one SCALAR (`lockVal`) along it — in the reference those are
    ///     two free user preferences, and the structure has no rotation and no
    ///     other origin component anywhere;
    ///   * ours is a full frame — `WorkplaneStage` carries `rotation` as
    ///     extrinsic-XYZ Euler degrees and `center` as a full `Vec3`, both
    ///     reachable from shipped commands.
    ///
    /// Mapping the frame onto the pair would discard the rotation and two
    /// thirds of the origin without telling anyone: a user who tilted the
    /// plane would silently get the pivot of an axis-aligned one. The relocate
    /// call site therefore keeps a pinned plane on a full-frame plane
    /// intersection and leaves `lock` false.
    ///
    /// It is kept here because it is a faithful restatement of a real arm and
    /// a reader deserves to see what the reference's lock actually is before
    /// concluding ours is the same thing.
    bool  lock = false;
    /// The position along the locked plane's axis. Read only when `lock`.
    ///
    /// NOTE THE ASYMMETRY, IT IS THE REFERENCE'S AND IT IS VERIFIED. When the
    /// lock arm runs, the axis assignment `k := preferredAxis` is CONDITIONAL
    /// (it is skipped when the view has a locked axis of its own) but the
    /// write `Q[k] = lockVal` is UNCONDITIONAL — it lands on whatever `k` is,
    /// which in that case is still the argmax. Disassembly of the arm, with
    /// `k` in `r12d` and `&Q` in `r14`:
    ///
    ///     cmp    ebx, -1              ; preferredAxis == -1?
    ///     je     .write               ;   -> skip the assignment, STILL write
    ///     call   <view locked axis>
    ///     test   eax, eax
    ///     cmovl  r12d, ebx            ; k := preferredAxis IFF no locked axis
    ///   .write:
    ///     movsxd r12, r12d
    ///     mov    r13, [r13+<lockVal>]
    ///     mov    [r14 + r12*8], r13   ; Q[k] = lockVal  -- unconditional
    ///
    /// So both of the "obvious fixes" — assigning `k` first, or skipping the
    /// write with it — would be a DEVIATION from the read, not a correction of
    /// it. This module keeps the read. The place that was wrong was the caller
    /// that manufactured a `lockVal` by reading one component of a work-plane
    /// origin along a DIFFERENT axis than the one it would be written to; that
    /// caller no longer exists (see `lock`).
    float lockVal = 0.0f;
    /// The view's own vector-snap step. Zero or less disables it, which is
    /// the reference's disabled value AND the state vibe3d is permanently in
    /// — we have no per-view snap step to read. Kept as an input rather than
    /// dropped because the law's shape depends on it and it is testable.
    float viewSnapStep = 0.0f;
    /// The out-of-plane quantum: the plane point's coordinate along the
    /// principal axis is rounded to a multiple of this. Zero disables it.
    ///
    /// STILL DEFAULTED OFF HERE, but no longer because the step is unknown:
    /// this module is pure and has no view to derive it from. The CALL SITE
    /// supplies it (`XfrmTransformTool.computeClickRelocateHitRaw`, task
    /// 0570) as `10 * viewgrid.viewGridSize(pixelSize)` — ten grid steps,
    /// where the grid step is itself the world length of 25 screen pixels
    /// rounded up onto a mantissa ladder. It is a pure function of the view's
    /// pixel size and needs no state.
    ///
    /// THE "CONTRADICTION" THIS FIELD USED TO DOCUMENT WAS AN ARTEFACT, and
    /// it is worth keeping the correction visible because the wrong version
    /// was persuasive. Two rigs appeared to demand incompatible constants:
    ///
    ///   * the plane-offset sweep — a focus of 1.8255 came back as 2.0 and
    ///     one of -0.3551 as 0.0, which admit a step of 1.0 or 2.0 and
    ///     nothing else between 0.05 and 20;
    ///   * the big-pan probe — a focus component of -1.0291 came back as
    ///     -1.03, which admits only steps at or below ~0.26.
    ///
    /// The intersection is empty only if both rows are the QUANTISED axis. On
    /// the second rig it is not: its out-of-plane axis is Y, not X. The
    /// -1.0291 -> -1.03 row is the in-plane component-wise snap (see
    /// `viewSnapStep`), and the row that IS the quantum on that rig is
    /// 0.3437 -> 0.5, i.e. a step of 0.5. With the step derived from zoom
    /// rather than fixed, 1.0/2.0 and 0.5 are two ordinary modelling zooms
    /// about a factor of two apart, and both rigs reproduce exactly.
    ///
    /// The lesson, since it cost two rounds: an "empty intersection" argument
    /// is only as good as the axis index under each row.
    float quantumStep = 0.0f;
}

/// The plane point: the camera focus, snapped, with its OUT-OF-PLANE
/// coordinate quantised to one grid division.
///
/// The reference also pushes `Q` along the eye vector by the view's target
/// distance for one further view type, and that branch is NOT ported. The
/// type is the view looked THROUGH A SCENE ITEM — a camera or a light — and
/// is distinct from both the axis-locked orthographic class and the ordinary
/// perspective view, which is its own type and takes the plain path. So this
/// is a gap only for a view vibe3d's relocate does not offer, not for the
/// default viewport; an earlier note here left the type unidentified and
/// overstated it as an open hole. (The identification is handed down rather
/// than re-derived here; what is checked in this tree is that the six
/// axis-preset direction names sit in one ordered table immediately ahead of
/// the perspective and camera entries, which is consistent with it.)
Vec3 niceOrigin(Vec3 focus, int k, float quantumStep, float viewSnapStep)
        @safe pure nothrow @nogc {
    Vec3 q = vectorSnap(focus, viewSnapStep);
    if (quantumStep > 0)
        q = withAxisComp(q, k, dnint(axisComp(q, k) / quantumStep) * quantumStep);
    return q;
}

/// The preferred-work-plane bias: `if (strength > 1 - |D[j]|) k := j`.
///
/// `1 - |D[j]|` is near zero exactly when the view looks nearly straight down
/// axis `j`, so this adopts the user's preferred plane when that plane is
/// within `strength` of being perfectly face-on — a hysteresis in favour of
/// the preference, biting only in the narrow band where `j` is nearly as
/// face-on as the argmax winner.
///
/// The comparison is STRICT and the `k == j` early-out precedes it, so at
/// exactly `strength == 1 - |D[j]|` the argmax wins.
int biasedAxis(int k, Vec3 eyeDir, const ref RelocatePlanePrefs p)
        @safe pure nothrow @nogc {
    if (p.strength <= 0) return k;
    if (p.lock) return k;
    int j = p.preferredAxis;
    if (j < 0 || j > 2) return k;
    if (k == j) return k;
    if (p.strength > 1.0f - abs(axisComp(eyeDir, j))) return j;
    return k;
}

/// The plane point and the principal axis together.
///
/// `argmaxAxis` is the camera-most-facing world axis, supplied by the caller
/// so this module does not duplicate the argmax (and so the caller's existing
/// tie-break stays the one authority on it).
struct PlanePoint {
    Vec3 q;
    int  k;
}

PlanePoint workPlanePoint(const ref Viewport vp, int argmaxAxis,
                          const ref RelocatePlanePrefs p)
        @safe pure nothrow @nogc {
    PlanePoint r;
    r.k = argmaxAxis;
    immutable int locked = lockedViewAxis(vp);

    // An axis-locked orthographic view takes the RAW focus — no quantum at
    // all — and is excluded from the bias. Both are the same condition in the
    // reference and both are read at their own site.
    if (locked >= 0) {
        r.q = vp.focus;
    } else {
        r.q = niceOrigin(vp.focus, r.k, p.quantumStep, p.viewSnapStep);
        // The eye vector is computed even when the bias is dormant, and is
        // then discarded by `biasedAxis`'s first early-out. Left that way on
        // purpose: it mirrors the reference, which also computes it before the
        // gate, and it is one normalize per relocate CLICK. If you hoist it
        // behind the gate, hoist the whole predicate — `biasedAxis` has four
        // early-outs and duplicating three of them here is how they drift.
        immutable int bk = biasedAxis(r.k, eyeVectorAt(vp, r.q), p);
        if (bk != r.k) {
            r.k = bk;
            // The reference recomputes the plane point for the new axis, and
            // it must: the quantum is applied to the OUT-OF-PLANE coordinate,
            // so changing which one that is changes Q.
            r.q = niceOrigin(vp.focus, r.k, p.quantumStep, p.viewSnapStep);
        }
    }

    // The lock arm. The axis assignment is conditional, the value write is
    // not — see `RelocatePlanePrefs.lockVal` for the instructions and for why
    // that asymmetry is kept rather than "fixed". The reference skips the
    // assignment only on the sentinel -1 and would happily index off the end
    // of Q for any other out-of-range value; the `<= 2` here is a bounds guard
    // on our side, not a difference in the rule.
    if (p.lock) {
        if (p.preferredAxis >= 0 && p.preferredAxis <= 2 && locked < 0)
            r.k = p.preferredAxis;
        r.q = withAxisComp(r.q, r.k, p.lockVal);
    }
    return r;
}

/// Put the click on the principal plane.
///
/// Two arms, and the first one casts NO RAY: in an axis-locked orthographic
/// view the answer is the click with one coordinate replaced. The second is
/// the ray, `C = P0 + [(Q[k] - P0[k]) / D[k]]*D`.
///
/// THE CLICK ARRIVES AS A RAY, NOT AS A POINT, AND THAT IS NOT A DEVIATION.
/// The reference unprojects the click to a world point `P0` and then recovers
/// `D` as the eye vector AT `P0`; vibe3d's `screenPointToRay` hands back the
/// same line already parameterised, so `D` is read rather than recovered.
/// Both arms are invariant to which point of the line is passed:
///
///   * the ray arm returns the unique point of the line whose `k` component
///     is `Q[k]`, and that point does not depend on the parameterisation;
///   * the locked arm only ever runs under an orthographic projection, where
///     `screenPointToRay`'s origin IS the unprojected click, and the one
///     component it does not preserve — the depth along the view axis — is
///     exactly the component the locked arm overwrites.
///
/// Reading `D` instead of recovering it also removes a degeneracy: under a
/// perspective projection the ray origin is the eye itself, and the eye
/// vector AT the eye is not defined.
///
/// Returns false only when the ray arm degenerates (the view direction lies
/// in the plane). The locked arm cannot fail.
bool posToPrincipalPlane(const ref Viewport vp, Vec3 rayOrigin, Vec3 rayDir,
                         int k, Vec3 q, bool doSnap, float snapStep, out Vec3 c)
        @safe pure nothrow @nogc {
    immutable int locked = lockedViewAxis(vp);
    if (locked >= 0) {
        c = withAxisComp(rayOrigin, locked, axisComp(q, locked));
    } else {
        immutable float dk = axisComp(rayDir, k);
        if (abs(dk) < 1e-9f) return false;
        immutable float t = (axisComp(q, k) - axisComp(rayOrigin, k)) / dk;
        c = rayOrigin + rayDir * t;
    }
    if (doSnap) c = vectorSnap(c, snapStep);
    return true;
}

/// The whole chain: the click's ray in, the relocated centre out.
///
/// `argmaxAxis` is the caller's camera-most-facing axis. `axisOut` receives
/// the principal axis actually used, which is NOT always `argmaxAxis` — the
/// bias and the lock can both move it.
bool principalPlaneCenter(const ref Viewport vp, Vec3 rayOrigin, Vec3 rayDir,
                          int argmaxAxis, const ref RelocatePlanePrefs p,
                          out Vec3 c, out int axisOut)
        @safe pure nothrow @nogc {
    immutable pp = workPlanePoint(vp, argmaxAxis, p);
    axisOut = pp.k;
    return posToPrincipalPlane(vp, rayOrigin, rayDir, pp.k, pp.q,
                               true, p.viewSnapStep, c);
}
