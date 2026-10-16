module vibe3d.util.spatial.spatial;

import vibe3d.util.math.math;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
version (unittest) import std.math : isClose;


// A frozen (placed, center) override — the value-type shape shared by every
// action-center pin lifetime (explicit-relocate, display-settle, in-session-
// cancel baseline) and, downstream, the transform tool's per-gesture pin
// snapshots. A single struct assignment (`a = b;`) copies both fields
// atomically, which is the point: field-by-field copies of a placed flag +
// a center vector are exactly how two "same" pins have historically drifted
// apart one field at a time.
struct Pin {
    bool placed = false;
    Vec3 center = Vec3(0, 0, 0);
}

struct Viewport {
    float[16] view;
    float[16] proj;
    int width;
    int height;
    int x = 0;   // window-space left edge
    int y = 0;   // window-space top edge
    Vec3 eye;
    // Camera look-at target. NOTE, and it used to read "default (0,0,0)":
    // `Vec3`'s own fields carry no initialiser, so `float.init` applies and a
    // default-constructed Viewport has focus == (NaN, NaN, NaN), not the
    // origin. Every real path sets it (`View.viewportWith`); hand-built
    // headless fixtures routinely do not. A consumer that must survive both
    // has to say so — see `viewPixelScale`.
    Vec3 focus;
    // Task 7139 (gap-row "ring cull gate"): the cell's view is on an AXIS
    // PRESET (Top/Bottom/Front/Back/Right/Left). A view TYPE, not a camera
    // direction: set by `View.viewportWith` only; hand-built fixtures leave it
    // false. Read through `isAxisView`, never raw.
    bool axisPreset;
}

// ---------------------------------------------------------------------------
// ModelSpace — the per-layer item transform, packaged for picking (task 0617,
// doc/picking_item_transform_plan.md).
//
// Geometry is DRAWN through a layer's item matrix (`ItemXform.composedMatrix`,
// document.d) but every picking path historically compared against raw LOCAL
// vertex coordinates — a layer with a non-identity transform was picked where
// it would sit at identity, not where it is actually drawn. `ModelSpace` is
// the value that closes that gap: every picking entry point takes one of
// these as a REQUIRED parameter (never defaulted — a call site that forgets
// it is a build error, not a silent wrong answer) and transforms the QUERY
// into the layer's local space, rather than baking world-space copies of the
// geometry into the picking caches (the GPU ID-buffer's VBOs, the BVH, the
// snap candidate grid). `document.ItemXform.modelSpace()` is the one
// production factory; `ModelSpace.world()` below is the identity constant
// used where there is no layer transform to apply (unit tests, and any path
// provably always identity).
//
// `mInv` is analytic (§3.1 of the plan), not a general 4x4 inverse — this
// module has none, and the composition order
// `M = T(pos)·T(pivot)·Rz·Ry·Rx·S·T(-pivot)` (document.d) never needs one.
// ---------------------------------------------------------------------------
struct ModelSpace {
    // Literal, not `= identityMatrix` (a static-array default field
    // initializer can't array-cast an `immutable` global at compile time) —
    // same nine 1s / zeros identityMatrix holds.
    float[16] m    = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; // local -> world
    float[16] mInv = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; // world -> local (analytic; see document.d)
    bool      isIdentity = true;
    bool      invertible = true;
    // det(m) < 0 — an odd number of negative scale components (for this
    // composition order det(M) == scl.x*scl.y*scl.z, no general 3x3
    // determinant helper needed).
    //
    // A mirrored M does flip apparent WINDING: cross(M*u, M*v) ==
    // det(M)*(M^-1)^T*cross(u,v), so a normal built by cross-producting two
    // (possibly already-world) edge vectors points the wrong way whenever
    // det(M) < 0. But a front-facing test done ENTIRELY in local space — a
    // local normal dotted against a local-space eye/point, i.e.
    // `dot(nLocal, pLocal - eyeLocal)` — needs NO correction for this,
    // mirrored or not. The reason: `eyeLocal == M^-1 * eyeWorld` and
    // `pLocal == M^-1 * pWorld` are already the exact local coordinates the
    // drawn geometry was built from, so `dot(nLocal, pLocal - eyeLocal)` IS
    // the local-space evaluation of "is the eye on the outward side" — no
    // world quantity is being approximated or reconstructed, so there is
    // nothing for `det(M)`'s sign to correct. (Equivalently: the true world
    // outward normal is `toWorldNormal(nLocal) == (M^-1)^T * nLocal`, and
    // `dot((M^-1)^T n, M v) == dot(n, v)` exactly, for ANY invertible M — the
    // local dot product already equals the correct world one, sign and all.)
    //
    // A previous version of this field's doc comment, and three call sites
    // (app.d's lasso `frontFacing`, snap.d's `faceVisible`, mesh.d's
    // `visibleVertices`), got this backwards: they XOR'd `mirrored` onto a
    // LOCAL-only front-facing test, which is the correction for the WINDING
    // normal case above, not this one. That flip has been removed from all
    // three; do not reintroduce it into a local-only cull. This field is not
    // read anywhere in the tree as of this fix — see `toWorldNormal`'s doc
    // comment below for the one construction (a normal built by
    // cross-producting WORLD points/vectors) where the mirror sign genuinely
    // does need correcting, and where `mirrored` itself still isn't the
    // mechanism (the inverse-transpose is applied directly instead).
    //
    // The identity quoted above is TRUE but it is not the whole reason, and
    // reading it as the whole reason is how this got re-opened in task 3110:
    // `(M^-1)^T * n` is the transported LOCAL normal, NOT the drawn ring's
    // winding normal, which carries an extra `det(M)`. See the NEGATIVE
    // DETERMINANT block on `frontFacingLocal` below for the bridge between the
    // two and for why the local form is the one that answers "what is on
    // screen".
    bool      mirrored   = false;

    /// The identity ModelSpace. Every field already defaults to it — this
    /// name exists so call sites can write `ModelSpace.world()` instead of
    /// the less self-explanatory `ModelSpace.init`.
    static ModelSpace world() @safe pure nothrow @nogc { return ModelSpace.init; }

    /// World point -> local point (full affine, via `mInv`).
    Vec3 toLocalPoint(Vec3 worldP) const @safe pure nothrow @nogc {
        return applyAffine(mInv, worldP);
    }
    /// Local point -> world point (full affine, via `m`).
    Vec3 toWorldPoint(Vec3 localP) const @safe pure nothrow @nogc {
        return applyAffine(m, localP);
    }
    /// World-space DIRECTION -> local-space direction: the LINEAR part of
    /// `mInv` only (no translation). Deliberately left UN-NORMALIZED — see
    /// doc/picking_item_transform_plan.md §3.4. Because
    /// `mInv·(org + t·dir) == mInv·org + t·(mInv·dir)`, leaving this
    /// un-normalized preserves a ray's hit parameter `t` exactly as a WORLD
    /// distance. Normalizing here (or at any caller) corrupts `t` — the
    /// nearest-hit comparison across layers of different scale would
    /// silently start favouring the smaller-scaled layer. Do not add a
    /// `normalize()` call to this function or its call sites.
    Vec3 toLocalDir(Vec3 worldDir) const @safe pure nothrow @nogc {
        return Vec3(
            mInv[0]*worldDir.x + mInv[4]*worldDir.y + mInv[ 8]*worldDir.z,
            mInv[1]*worldDir.x + mInv[5]*worldDir.y + mInv[ 9]*worldDir.z,
            mInv[2]*worldDir.x + mInv[6]*worldDir.y + mInv[10]*worldDir.z,
        );
    }
    /// Local-space DIRECTION -> world-space direction: the LINEAR part of
    /// `m` only (no translation), the exact dual of `toLocalDir`. Like it,
    /// deliberately NOT normalized — a caller that needs a unit direction
    /// normalizes it itself, and one that is carrying a length (an edge
    /// vector, a ray parameter) needs it left alone.
    ///
    /// This is for a DIRECTION — a difference of two points. A NORMAL is not
    /// a direction under a non-uniform scale: use `toWorldNormal`.
    Vec3 toWorldDir(Vec3 localDir) const @safe pure nothrow @nogc {
        return Vec3(
            m[0]*localDir.x + m[4]*localDir.y + m[ 8]*localDir.z,
            m[1]*localDir.x + m[5]*localDir.y + m[ 9]*localDir.z,
            m[2]*localDir.x + m[6]*localDir.y + m[10]*localDir.z,
        );
    }
    /// Local-space NORMAL -> world-space normal: `(M^-1)^T` applied to
    /// `nLocal` — the standard normal-transform rule (normals do NOT
    /// transform the same way points/directions do under a non-uniform
    /// scale or shear), expressed directly as the transpose of `mInv`'s
    /// linear 3x3 rather than `m`'s. Linear part only, no translation; the
    /// result is not renormalized — callers that need a unit normal
    /// normalize it themselves.
    ///
    /// This IS the sanctioned path for a normal built by cross-producting
    /// two LOCAL edge vectors too (`bvh_pick.d`'s `pickSurfaceRay` calls it
    /// on exactly such a normal): `cross(u,v)` computed in local space and
    /// then mapped through this inverse-transpose gives the true outward
    /// world normal for any invertible `M`, mirrored or not — the
    /// `dot((M^-1)^T n, M v) == dot(n, v)` identity holds unconditionally. A
    /// previous version of this comment claimed the opposite — that
    /// `pickSurfaceRay` needed to cross-product already-WORLD vertices
    /// instead — reasoning that `cross(Ma,Mb) ==
    /// det(M)*(M^-1)^T*cross(a,b)` made the two paths "a different, stronger
    /// claim". That is true as a statement about the WINDING normal (which
    /// is exactly why cross-producting world vertices is wrong under a
    /// mirror: it silently carries the `det(M)` sign, pointing the result
    /// into the solid), but it does not apply here — this function is never
    /// given a world cross product to begin with; it transforms the LOCAL
    /// one, and the identity above holds without any determinant factor.
    /// Do not "fix" a mirror-flipped normal by cross-producting world points
    /// instead of calling this — that reintroduces the same defect.
    Vec3 toWorldNormal(Vec3 nLocal) const @safe pure nothrow @nogc {
        return Vec3(
            mInv[0]*nLocal.x + mInv[1]*nLocal.y + mInv[ 2]*nLocal.z,
            mInv[4]*nLocal.x + mInv[5]*nLocal.y + mInv[ 6]*nLocal.z,
            mInv[8]*nLocal.x + mInv[9]*nLocal.y + mInv[10]*nLocal.z,
        );
    }
    /// World-space NORMAL -> local-space normal: `M^T` applied to `nWorld`
    /// — the exact dual of `toWorldNormal` above, expressed as the transpose
    /// of `m`'s linear 3x3 (as `toWorldNormal` is the transpose of `mInv`'s).
    /// Linear part only, no translation; the result is NOT renormalized.
    ///
    /// Why it exists (task 0619, doc/tool_aiming_item_transform_plan.md §2.1):
    /// a cursor ray tested against a plane ANCHORED ON MESH GEOMETRY has to
    /// be evaluated in the layer's local space, because the consumer writes
    /// local vertex coordinates. Moving that test into local space needs the
    /// ray direction through `toLocalDir` (`M^-1`) and the plane's world
    /// normal through THIS (`M^T`), because
    /// `dot(M^T n, M^-1 d) == n^T M M^-1 d == dot(n, d)` EXACTLY, for any
    /// invertible `M`, mirrored or not — so the plane equation's sign and
    /// magnitude survive the move unchanged.
    ///
    /// Do NOT reach for `toLocalDir` to carry a normal: `M^T` and `M^-1` are
    /// EQUAL for a pure rotation, so the two agree exactly on a
    /// rotation-only fixture and diverge under any non-uniform scale or
    /// shear. That is the classic wrong normal transform, and a
    /// rotation-only test cannot see it.
    Vec3 toLocalNormal(Vec3 nWorld) const @safe pure nothrow @nogc {
        return Vec3(
            m[0]*nWorld.x + m[1]*nWorld.y + m[ 2]*nWorld.z,
            m[4]*nWorld.x + m[5]*nWorld.y + m[ 6]*nWorld.z,
            m[8]*nWorld.x + m[9]*nWorld.y + m[10]*nWorld.z,
        );
    }

    /// Carry a WORLD-space affine map `F` into this space: the local map that
    /// does, to local coordinates, exactly what `F` does to the world ones.
    ///
    ///     conjugate(F) == L4^-1 . F . L4
    ///
    /// where `L4` is `m` with its TRANSLATION COLUMN ZEROED (the linear part
    /// alone) and `L4^-1` is `mInv` likewise. The zeroing is the whole trick,
    /// and it is not an approximation: for `A(x) = L x + p`, the composite
    /// `A^-1 . W . A` where `W(x) = c + F(x - c)` works out to
    ///
    ///     x |-> c' + (L^-1 F_lin L)(x - c') + L^-1 F_t,      c' = A^-1(c)
    ///
    /// i.e. the PIVOT takes the full affine inverse (`toLocalPoint`) while the
    /// map itself takes the linear one on both sides. Feeding the full `m` /
    /// `mInv` here instead would apply the item translation twice — once in
    /// the pivot and once inside the matrix — and a translate-only item
    /// transform would move the geometry by `2*pos` instead of leaving it
    /// where it was.
    ///
    /// The companion conversion is `toLocalPoint(centreWorld)`; the two are
    /// used together or not at all.
    ///
    /// Blend note: a per-vertex weight `w` applied as a LERP toward identity
    /// commutes with this conjugation exactly — `L4^-1 . ((1-w)I + wF) . L4
    /// == (1-w)I + w(L4^-1 F L4)` — so conjugating the composed matrix once,
    /// before the per-vertex blend, is equivalent to conjugating every
    /// blended result. That equivalence is what makes this a ONE-PLACE
    /// conversion. It does NOT hold for a non-linear blend (a slerp) under a
    /// non-similarity `L`; there the conjugated form stays exact at `w == 0`
    /// and `w == 1` and is a declared reading in between.
    float[16] conjugate(const float[16] f) const @safe pure nothrow @nogc {
        if (isIdentity || !invertible) return f;
        float[16] lin    = m;
        float[16] linInv = mInv;
        lin[12] = 0;    lin[13] = 0;    lin[14] = 0;
        linInv[12] = 0; linInv[13] = 0; linInv[14] = 0;
        return matMul4(linInv, matMul4(f, lin));
    }
}




// Rotation + NON-UNIFORM scale, with its exact analytic inverse. The two
// `toLocalNormal` unittests below both need it: under a pure rotation
// `M^T == M^-1`, so `toLocalNormal` and `toLocalDir` return the SAME vector
// and no rotation-only fixture can tell a correct implementation from the
// wrong one. `scl = (1.7, 1, 0.6)` is what makes them diverge.
version (unittest) private void rotNonUniformSpace(out ModelSpace ms) {
    Vec3 axis = normalize(Vec3(0.3f, 1.0f, -0.2f));
    auto R    = pivotRotationMatrix(Vec3(0,0,0), axis,  0.7f);
    auto Rinv = pivotRotationMatrix(Vec3(0,0,0), axis, -0.7f);
    auto S    = pivotScaleMatrix(Vec3(0,0,0), 1.7f, 1.0f, 0.6f);
    auto Sinv = pivotScaleMatrix(Vec3(0,0,0), 1.0f/1.7f, 1.0f, 1.0f/0.6f);
    ms.m    = matMul4(R, S);        // M    = R*S
    ms.mInv = matMul4(Sinv, Rinv);  // M^-1 = S^-1 * R^-1
    ms.isIdentity = false;
}

unittest { // toLocalNormal is the exact dual of toLocalDir:
    // `dot(M^T*n, M^-1*d) == dot(n, d)` for ANY invertible M (task 0619 §2.1).
    // This is the identity a RayPlane site relies on to move a plane test
    // anchored on mesh geometry into the layer's local space without
    // changing the number the test reads.
    ModelSpace ms;
    rotNonUniformSpace(ms);

    Vec3 nWorld = Vec3( 0.40f, -0.90f, 0.25f); // a world plane normal
    Vec3 dWorld = Vec3(-0.60f,  0.20f, 0.75f); // a world ray direction

    float truth = dot(nWorld, dWorld);
    float moved = dot(ms.toLocalNormal(nWorld), ms.toLocalDir(dWorld));
    assert(isClose(moved, truth, 1e-4f, 1e-4f),
        "dot(toLocalNormal(n), toLocalDir(d)) must equal dot(n, d) exactly");

    // ANTI-VACUITY. The plausible wrong implementation is "carry the normal
    // with toLocalDir as well" (the classic wrong normal transform). It must
    // read a DIFFERENT number on this same fixture, or the assertion above
    // would hold for both laws and would be measuring nothing.
    float wrong = dot(ms.toLocalDir(nWorld), ms.toLocalDir(dWorld));
    assert(!isClose(wrong, truth, 1e-2f, 1e-2f),
        "fixture is vacuous: the M^-1-on-the-normal law reads the same number here");
}

unittest { // toLocalNormal != toLocalDir under non-uniform scale (the negative
    // control), and they COINCIDE under a pure rotation — the second half is
    // why the fixture above is required to carry a non-uniform scale.
    ModelSpace ms;
    rotNonUniformSpace(ms);

    Vec3 n = Vec3(0.4f, -0.9f, 0.25f);
    Vec3 a = ms.toLocalNormal(n);
    Vec3 b = ms.toLocalDir(n);
    Vec3 d = a - b;
    assert(d.length > 1e-2f,
        "toLocalNormal must differ from toLocalDir under a non-uniform scale");

    // Pure rotation: M^T == M^-1, so the two are the same map. A test built
    // on a rotation-only ModelSpace would pass for either implementation.
    ModelSpace rot;
    Vec3 axis = normalize(Vec3(0.3f, 1.0f, -0.2f));
    rot.m    = pivotRotationMatrix(Vec3(0,0,0), axis,  0.7f);
    rot.mInv = pivotRotationMatrix(Vec3(0,0,0), axis, -0.7f);
    rot.isIdentity = false;
    Vec3 ra = rot.toLocalNormal(n);
    Vec3 rb = rot.toLocalDir(n);
    Vec3 rd = ra - rb;
    assert(rd.length < 1e-5f,
        "under a pure rotation toLocalNormal and toLocalDir must coincide — "
        ~ "this is why the discriminating fixture needs a non-uniform scale");
}

unittest { // conjugate() + toLocalPoint() reproduce "do it in world, write it
    // in local", to the last bit, for an arbitrary invertible space.
    //
    // The ONE claim: for any world-space map `W(x) = c + F(x - c)`, applying
    // W in world and converting back must equal applying the conjugated map
    // about the converted centre, in local. This is the identity the transform
    // apply path rests on, so it is asserted against an INDEPENDENT
    // construction (round-trip through world) rather than against itself.
    ModelSpace ms;
    rotNonUniformSpace(ms);
    ms.m[12] = 5.0f; ms.m[13] = -2.0f; ms.m[14] = 3.0f;    // + a translation
    // mInv's translation column = -L^-1 * p
    Vec3 lp = Vec3(
        ms.mInv[0]*5.0f + ms.mInv[4]*(-2.0f) + ms.mInv[ 8]*3.0f,
        ms.mInv[1]*5.0f + ms.mInv[5]*(-2.0f) + ms.mInv[ 9]*3.0f,
        ms.mInv[2]*5.0f + ms.mInv[6]*(-2.0f) + ms.mInv[10]*3.0f);
    ms.mInv[12] = -lp.x; ms.mInv[13] = -lp.y; ms.mInv[14] = -lp.z;

    // A world map with BOTH a linear part and a translation part, so a
    // conjugation that drops either term is caught.
    float[16] F = matMul4(pivotScaleMatrix(Vec3(0,0,0), 1.3f, 0.7f, 2.1f),
                          translationMatrix(Vec3(0.9f, -1.4f, 0.5f)));
    Vec3 cWorld = Vec3(-0.4f, 2.45f, -0.23f);

    Vec3 vLocal = Vec3(1.2f, 1.1f, -1.8f);
    // Truth: local -> world, apply about the world centre, world -> local.
    Vec3 truth = ms.toLocalPoint(
        cWorld + applyAffine(F, ms.toWorldPoint(vLocal) - cWorld));
    // Under test: the one-place conversion.
    Vec3 cLocal = ms.toLocalPoint(cWorld);
    Vec3 got    = cLocal + applyAffine(ms.conjugate(F), vLocal - cLocal);
    assert((got - truth).length < 1e-4f,
        "conjugate(F) about toLocalPoint(c) must equal the world-space map "
        ~ "carried back into local space");

    // ANTI-VACUITY, the exact mistake the doc comment names: conjugating with
    // the FULL m / mInv (translation column left in) instead of their linear
    // parts. It must read a DIFFERENT point here, or this fixture proves
    // nothing about which of the two matrices the conjugation uses.
    float[16] wrong = matMul4(ms.mInv, matMul4(F, ms.m));
    Vec3 gotWrong   = cLocal + applyAffine(wrong, vLocal - cLocal);
    assert((gotWrong - truth).length > 1e-2f,
        "fixture is vacuous: the full-affine conjugation lands on the same "
        ~ "point, so this cannot tell the two apart");

    // The identity space is a pass-through, bit for bit — the fast path every
    // existing rig takes.
    auto id = ModelSpace.world();
    auto passthrough = id.conjugate(F);
    foreach (i; 0 .. 16) assert(passthrough[i] == F[i],
        "an identity ModelSpace must return the matrix untouched");
}

unittest { // conjugate() commutes with the lerp-toward-identity blend — the
    // property that lets the apply path conjugate ONCE, before the per-vertex
    // falloff weight is applied, instead of per vertex.
    ModelSpace ms;
    rotNonUniformSpace(ms);
    float[16] F = matMul4(pivotScaleMatrix(Vec3(0,0,0), 1.3f, 0.7f, 2.1f),
                          translationMatrix(Vec3(0.9f, -1.4f, 0.5f)));
    enum float w = 0.375f;
    float[16] blendedThenConjugated;
    foreach (i; 0 .. 16)
        blendedThenConjugated[i] = (1.0f - w) * identityMatrix[i] + w * F[i];
    blendedThenConjugated = ms.conjugate(blendedThenConjugated);

    float[16] cj = ms.conjugate(F);
    float[16] conjugatedThenBlended;
    foreach (i; 0 .. 16)
        conjugatedThenBlended[i] = (1.0f - w) * identityMatrix[i] + w * cj[i];

    foreach (i; 0 .. 16)
        assert(isClose(blendedThenConjugated[i], conjugatedThenBlended[i],
                       1e-4f, 1e-5f),
            "conjugation must commute with the matrix lerp toward identity");
}

/// True when `vp` uses an orthographic projection.
/// Perspective has proj[15] == 0; ortho has proj[15] == 1.
bool isOrtho(const ref Viewport vp) @safe pure nothrow @nogc {
    return vp.proj[15] != 0.0f;
}

/// "Is this one of the axis views?" — orthographic AND on an axis preset. The
/// reference answers it from the view's projection flag and preset index
/// alone and never reads where the camera points, so a Front view turned by a
/// pinned plane is still an axis view (capture `gizmo_view_cull_plane`, verdict
/// V-none; task 7139). The ONE home of that question: `lockedViewAxis` below
/// answers a different one (which WORLD axis the view looks along) and must
/// not be used as a view-type test.
bool isAxisView(const ref Viewport vp) @safe pure nothrow @nogc {
    return isOrtho(vp) && vp.axisPreset;
}

/// The eye vector at a world point: the direction the view looks ALONG as it
/// passes through `p`. Perspective diverges from the eye, orthographic is
/// constant.
///
/// Lives here rather than in a tool module because it is plain view geometry
/// with no tool semantics. Being per-point rather than a single global
/// forward vector is the whole reason the gizmo's handle-facing cull
/// (`handles.gl_util.axisFacesViewer`) is correct for a gizmo
/// that sits away from the camera focus.
Vec3 eyeVectorAt(const ref Viewport vp, Vec3 p) @safe pure nothrow @nogc {
    if (isOrtho(vp)) return normalize(Vec3(-vp.view[2], -vp.view[6], -vp.view[10]));
    return normalize(p - vp.eye);
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
///
/// Second consumer, added later: the rotate-ring cull (`handles.gl_util`),
/// where this stands in for the reference's viewport-TYPE lookup — a lookup
/// that never inspects where the camera points, which is why modelling it as
/// "ortho AND axis-aligned" rather than "ortho" is the faithful reading.
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

Vec3 sphericalToCartesian(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// ---------------------------------------------------------------------------
// Orientation — a camera's rotational state as a 3x3, the STORED TRUTH.
// ---------------------------------------------------------------------------

/// An orthonormal, right-handed camera orientation held as nine floats whose
/// **columns** are the world-space camera basis:
///
///     m[0 .. 3]  screen-RIGHT
///     m[3 .. 6]  screen-UP
///     m[6 .. 9]  BACK  ( = -forward; focus -> eye, i.e. the orbit direction )
///
/// with `right x up == back`, matching the camera-looks-down-its-own-minus-Z
/// convention every consumer in the tree already reads off the view matrix
/// (`view[0]/[4]/[8]` = right, `[1]/[5]/[9]` = up, `-[2]/-[6]/-[10]` = forward).
///
/// **Why a matrix and not three angles.** Azimuth/elevation/roll is a CHART on
/// the rotation group, not the group: it is singular at the poles (which is
/// exactly why the spherical camera clamps elevation to 89 deg), and it cannot
/// express the composition of two rotations about different axes without going
/// back through the chart and losing the pole. A 3x3 has neither problem, and
/// it is the representation a reference viewport persists for itself — nine
/// floats per view, orthonormal to <= 1e-7, re-normalised on write.
///
/// The three angles remain available as DERIVED reads (`toAngles`), which is
/// the same relationship that reference publishes between its stored
/// orientation and the heading/pitch/bank triple it reports.
/// How far an orientation may sit from a perfect rotation before
/// `Orientation.orthonormalized` re-derives it. Two orders of magnitude above
/// the float dust a clean construction leaves (~3e-7 on the
/// `orthonormalityDefect` scale) and far below any drift that could matter, so
/// the normalisation is a repair and not a per-frame bit-churn. See
/// `orthonormalized` for why the gate is what makes that function idempotent.
enum float kOrientationTolerance = 1e-5f;

struct Orientation {
    /// Column-major, columns = basis vectors. Default = the identity camera
    /// (looking down -Z with +Y up), never a zero matrix: a default-init
    /// `Orientation` must be a usable rotation, because an aggregate that
    /// contains one is default-initialised before any constructor runs.
    float[9] m = [1, 0, 0,  0, 1, 0,  0, 0, 1];

    Vec3 right()   const @safe pure nothrow @nogc { return Vec3( m[0],  m[1],  m[2]); }
    Vec3 up()      const @safe pure nothrow @nogc { return Vec3( m[3],  m[4],  m[5]); }
    Vec3 back()    const @safe pure nothrow @nogc { return Vec3( m[6],  m[7],  m[8]); }
    Vec3 forward() const @safe pure nothrow @nogc { return Vec3(-m[6], -m[7], -m[8]); }

    /// Assemble from three basis vectors WITHOUT re-orthonormalising. Only for
    /// callers that built the triple orthonormal by construction; anything
    /// reading foreign data must go through `orthonormalized`.
    static Orientation fromBasis(Vec3 r, Vec3 u, Vec3 b) @safe pure nothrow @nogc {
        Orientation o;
        o.m = [r.x, r.y, r.z,  u.x, u.y, u.z,  b.x, b.y, b.z];
        return o;
    }

    /// The orientation of a spherical camera at (azimuth, elevation) banked by
    /// `roll`, in radians — the chart-to-group direction.
    ///
    /// Closed form rather than the cross-product chain the pre-matrix camera
    /// used, for one reason that matters: `normalize(cross(forward, +Y))` is
    /// 0/0 at the poles, so the chain produced NaN at |elevation| = 90 deg and
    /// the camera had to be clamped short of it. The closed form is the
    /// analytic limit and is finite everywhere, so a pole is a representable
    /// camera. The clamp stays where it is (in the ORBIT GESTURE, which is a
    /// separate question) but it is no longer load-bearing for the arithmetic.
    ///
    /// Derivation: the unbanked basis is
    ///     right  = ( cos az,            0,       -sin az           )
    ///     up     = (-sin az * sin el,   cos el,  -cos az * sin el  )
    ///     back   = ( cos el * sin az,   sin el,   cos el * cos az  )
    /// (`back` is `sphericalToCartesian(az, el, 1)`, i.e. the orbit offset
    /// direction), and a bank rotates the (right, up) pair about `back`.
    static Orientation fromAngles(float az, float el, float roll)
        @safe pure nothrow @nogc
    {
        immutable float ca = cos(az), sa = sin(az);
        immutable float ce = cos(el), se = sin(el);
        immutable Vec3 r0 = Vec3( ca,       0,   -sa);
        immutable Vec3 u0 = Vec3(-sa * se,  ce,  -ca * se);
        immutable Vec3 b  = Vec3( ce * sa,  se,   ce * ca);
        if (roll == 0.0f) return fromBasis(r0, u0, b);
        immutable float cr = cos(roll), sr = sin(roll);
        // The sign is pinned, not chosen: it is the one for which
        // `right.y == -sin(roll) * cos(elevation)`, the identity a reference
        // viewport's screen-right row obeys against its own reported bank.
        return fromBasis(r0 * cr - u0 * sr, u0 * cr + r0 * sr, b);
    }

    /// The (azimuth, elevation, roll) chart coordinates of this orientation —
    /// a DERIVED read, the inverse of `fromAngles`.
    ///
    /// At a pole (`|back.y| -> 1`) the chart degenerates: heading and bank
    /// describe the same rotation there and cannot be separated. The documented
    /// policy is to report `roll = 0` and fold the whole rotation into
    /// `azimuth`, which keeps `fromAngles(toAngles(o)) == o` (up to float dust)
    /// everywhere INCLUDING the pole rather than only away from it.
    void toAngles(out float az, out float el, out float roll)
        const @safe pure nothrow @nogc
    {
        immutable Vec3 b = back(), r = right(), u = up();
        float by = b.y;
        if (by >  1.0f) by =  1.0f;
        if (by < -1.0f) by = -1.0f;
        el = asin(by);
        immutable float ce = cos(el);
        if (ce > 1e-6f || ce < -1e-6f) {
            az   = atan2(b.x, b.z);
            // right.y == -sin(roll)*cos(el), up.y == cos(roll)*cos(el)
            roll = atan2(-r.y, u.y);
        } else {
            // Pole. `up` carries the heading: at el = +90 the unbanked up is
            // (-sin az, 0, -cos az), at el = -90 it is (sin az, 0, cos az).
            immutable float s = by > 0.0f ? -1.0f : 1.0f;
            az   = atan2(s * u.x, s * u.z);
            roll = 0.0f;
        }
    }

    @property float azimuth()   const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return a;
    }
    @property float elevation() const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return e;
    }
    @property float roll()      const @safe pure nothrow @nogc {
        float a, e, r; toAngles(a, e, r); return r;
    }

    /// How far this matrix has drifted from being an orthonormal right-handed
    /// rotation: the sum of the three unit-length defects, the three pairwise
    /// dot products, and the handedness residual `|right x up - back|`. Exactly
    /// 0 for a perfect rotation. Used by the write-time discipline and by tests
    /// (a reference viewport's shipped orientations score <= 1e-7 on this).
    float orthonormalityDefect() const @safe pure nothrow @nogc {
        immutable Vec3 r = right(), u = up(), b = back();
        immutable Vec3 h = cross(r, u) - b;
        return abs(r.length - 1.0f) + abs(u.length - 1.0f) + abs(b.length - 1.0f)
             + abs(dot(r, u)) + abs(dot(r, b)) + abs(dot(u, b))
             + abs(h.x) + abs(h.y) + abs(h.z);
    }

    /// Re-derive a clean orthonormal right-handed basis — the normalisation
    /// discipline. **Every write of an orientation that was not built
    /// orthonormal by construction goes through this**: deserialisation, the
    /// HTTP setter, and any incremental composition, so accumulated drift can
    /// never reach the view matrix.
    ///
    /// Anchored on `back`, because that is the direction the camera looks and
    /// the one a correction must not move: `back` is normalised, `right` is
    /// re-derived as `up x back`, and `up` as `back x right`. Degenerate inputs
    /// (zero columns, `up` parallel to `back`) fall back through the stored
    /// `right` column and then a world axis rather than producing NaN.
    ///
    /// **Idempotent, and that is a hard requirement rather than a nicety**:
    /// `o.orthonormalized().orthonormalized()` is bit-equal to
    /// `o.orthonormalized()`, which is what lets a serialisation round-trip be
    /// bit-exact even though the reader re-normalises everything it reads.
    ///
    /// A bare Gram-Schmidt pass is NOT idempotent — `normalize` does not return
    /// an exactly-unit vector, so a second pass moves the last bits again, and
    /// an orientation would drift by an ulp on every save/load cycle. The fixed
    /// point comes from the tolerance gate below: a matrix already within
    /// `kOrientationTolerance` of a rotation is returned UNTOUCHED, and one
    /// pass always lands inside that band, so the second call is a no-op. The
    /// gate is also the right policy on its own terms — float dust is not
    /// drift, and re-deriving nine floats to chase it would churn the camera
    /// every frame for no gain.
    Orientation orthonormalized() const @safe pure nothrow @nogc {
        if (orthonormalityDefect() <= kOrientationTolerance) return this;
        Vec3 b = back();
        float bl = b.length;
        if (!(bl > 1e-12f)) { b = Vec3(0, 0, 1); bl = 1.0f; }
        if (bl != 1.0f) b = b * (1.0f / bl);

        Vec3 r  = cross(up(), b);
        float rl = r.length;
        if (!(rl > 1e-6f)) {
            // `up` is parallel to `back` (or zero): recover the roll from the
            // stored right column instead.
            r  = right() - b * dot(right(), b);
            rl = r.length;
        }
        if (!(rl > 1e-6f)) {
            // Both transverse columns are unusable: any perpendicular will do.
            immutable Vec3 seed = (abs(b.y) < 0.9f) ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
            r  = cross(seed, b);
            rl = r.length;
        }
        if (rl != 1.0f) r = r * (1.0f / rl);
        return fromBasis(r, cross(b, r), b);
    }

    /// This orientation followed by a rotation of `angle` radians about the
    /// WORLD-space `axis` (Rodrigues), re-orthonormalised.
    ///
    /// The composition primitive a matrix truth exists for: an arbitrary-axis
    /// increment has no expression in the angle chart, which is the whole
    /// reason the storage changed. Used here to build test orientations no
    /// scalar bank can represent.
    Orientation rotatedAbout(Vec3 axis, float angle) const @safe pure nothrow @nogc {
        immutable float al = axis.length;
        if (!(al > 1e-12f)) return this;
        immutable Vec3 k = axis * (1.0f / al);
        return fromBasis(rotateAboutAxis(right(), k, angle),
                         rotateAboutAxis(up(),    k, angle),
                         rotateAboutAxis(back(),  k, angle)).orthonormalized();
    }
}

/// The view matrix for a camera with orientation `o` sitting at `eye` — the
/// world-to-camera transform `[R^T | -R^T * eye]`, column-major.
///
/// This is `lookAt`'s output for the same camera, but taken from a STORED
/// orientation rather than rebuilt from an eye/target/world-up triple. The two
/// agree exactly on the nine rotation lanes; they can differ by one ulp in the
/// translation lanes because `lookAt` re-derives its forward from
/// `center - eye`, whose rounding depends on where the focus happens to sit.
float[16] viewMatrixFrom(Orientation o, Vec3 eye) @safe pure nothrow @nogc {
    immutable Vec3 r = o.right(), u = o.up(), b = o.back();
    return [
         r.x,  u.x,  b.x, 0,
         r.y,  u.y,  b.y, 0,
         r.z,  u.z,  b.z, 0,
        -dot(r, eye), -dot(u, eye), -dot(b, eye), 1,
    ];
}

// Project world point to window pixel coords.
// Returns false if behind camera or outside frustum.
// px, py  — window-space pixels (Y down)
// ndcZ    — NDC depth in [-1, 1]
bool projectToWindow(Vec3 world, const ref Viewport vp,
                     out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ     = c.z / c.w;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1 || ndcZ < -1 || ndcZ > 1)
        return false;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// Like projectToWindow but does NOT reject points outside the screen boundary.
// Only rejects points behind the camera (w <= 0).
// Use this for hit-testing line segments that may extend off-screen.
// Forced inline (task 8170): the per-vertex screen and lasso falloff weights
// call it once per vertex per drag step, and out of line its three results went
// through memory and the `ndcZ` divide those callers never read was kept.
pragma(inline, true)
bool projectToWindowFull(Vec3 world, const ref Viewport vp,
                         out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ = c.z / c.w;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// Compose a layer's item transform into a Viewport for FORWARD PROJECTION
// only: `proj*(view*M)*v_local == proj*view*(M*v_local)`, so folding `M`
// into `vp.view` (and `vp.eye` into local space, per the plan) lets every
// existing `projectToWindow*` call site pick up the item transform with a
// one-line `vp` -> `projectionSpace(vp, ms)` swap. A stack copy of Viewport;
// no allocation. Exact identity fast path (§3.5): `ms.isIdentity` returns
// `vp` unchanged, byte-identical to every call site's pre-0617 behaviour.
//
// DO NOT use the result of this function to build a ray (`screenRay`,
// `screenPointToRay`). Both derive the world ray direction by treating the
// view matrix's upper-left 3x3 AS ITS OWN INVERSE (transpose-as-inverse —
// see `screenRay`'s comment), which is only valid for an orthonormal
// rotation. Composing a scale or shear into `view` breaks that assumption
// SILENTLY — the ray direction comes out wrong with no error raised. Rays
// must be built in WORLD space from the real (uncomposed) Viewport, and only
// then transformed into local space with `ModelSpace.toLocalDir` /
// `toLocalPoint`. See doc/picking_item_transform_plan.md §3.3 (task 0617).
// `ms` is BY VALUE, not `const ref`: call sites routinely pass an rvalue
// (`ModelSpace.world()`, `primaryModelSpace()`), which a `const ref`
// parameter cannot bind without a compiler preview flag this project does
// not use. `ModelSpace` is two `float[16]` + three `bool` (~132 bytes) — a
// cheap stack copy, not a reason to reach for `ref`.
//
// DO NOT feed the result of this function into `viewPixelScale` (or any
// other helper measuring `eye`-to-`focus` distance). This function is
// PROJECTION-ONLY and deliberately transforms `eye` alone — `out_.focus` is
// left as `vp.focus`, still in WORLD space, while `out_.eye` is now in the
// LAYER's local space. `viewPixelScale` would then subtract a local-space
// point from a world-space one and return a meaningless scale. Transforming
// `focus` too would NOT fix this — it would make it WRONG in a different,
// worse way: `viewPixelScale`'s own contract (see its doc comment) is that
// the returned scale depends on the CAMERA ALONE, so every layer under one
// camera shares one pixel size. Folding a per-layer `M` into the eye/focus
// distance would make the "world units per pixel" answer depend on which
// layer's `ModelSpace` happened to be composed in — a single scalar can't
// mean that. Worse, under a NON-UNIFORM scale the local-space distance is
// direction-dependent (an isotropic world sphere maps to an ellipsoid), so
// no single scalar distance is even the right SHAPE of answer once `M` is
// non-uniform. If a future stage needs a per-pixel measure in local space,
// it has to be derived some other way — not by handing `projectionSpace`'s
// output to `viewPixelScale`.
Viewport projectionSpace(const ref Viewport vp, const ModelSpace ms) @safe pure nothrow @nogc {
    if (ms.isIdentity) return vp; // exact fast path — no matMul4, byte-identical
    Viewport out_ = vp;
    out_.view = matMul4(vp.view, ms.m);
    out_.eye  = ms.toLocalPoint(vp.eye);
    return out_;
}



// ---------------------------------------------------------------------------
// AimViewport — a NOMINAL type for "the aiming space" (task 0619 §2.0).
//
// `projectionSpace` returns a plain `Viewport`, so nothing stops a call site
// from projecting a LAYER-LOCAL mesh coordinate through the WORLD viewport —
// which is precisely the defect this family of tasks exists to remove, and
// which a naming convention (`vpAim*`) policed by a grep cannot prevent.
// `AimViewport` turns that into a compile error instead: it wraps a Viewport
// that has ALREADY had a `ModelSpace` composed into it, and it cannot be
// produced without supplying one, because
//
//   * its default constructor is `@disable`d, so `AimViewport v;` is illegal;
//   * its only constructor is module-private, so outside `spatial.d` the only
//     way to obtain one is `aimSpace(vp, ms)`;
//   * it does not implicitly convert from `Viewport`, so a world viewport
//     cannot be passed where an aim space is expected (and vice versa).
//
// The intended shape of an aiming helper is therefore a pair:
//   `f(Vec3 pLocal, const ref AimViewport vpAim, ...)`  — local geometry
//   `g(Vec3 pWorld, const ref Viewport    vp,    ...)`  — already-world value
// so an "this value is already in world space" site keeps a typed home and
// nobody has to fabricate an aim space to express it.
//
// The one residue this type does NOT catch is `aimSpace(vp, ModelSpace.world())`
// — a real aim space built from an identity transform. §2.3 of the plan bans
// `ModelSpace.world()` outright in the files this task edits for that reason.
//
// Deliberately NOT accepted by `screenPointToRay`/`screenRay`: a composed
// view matrix breaks their transpose-as-inverse assumption (see
// `projectionSpace`'s doc comment above), so keeping those on the plain
// `Viewport` makes the double-apply a type error too.
// ---------------------------------------------------------------------------
struct AimViewport {
    @disable this();                 // no accessible default construction
    private Viewport vp_;            // module-private: only spatial.d can fill it
    private ModelSpace ms_;          // the space `vp_` was composed FROM
    private this(Viewport v, ModelSpace m) @safe pure nothrow @nogc {
        vp_ = v; ms_ = m;
    }
    /// The composed viewport, for handing to `projectToWindow*`.
    @property ref const(Viewport) vp() const return @safe pure nothrow @nogc {
        return vp_;
    }
    /// The `ModelSpace` this aim space was built from — i.e. the item
    /// transform of the geometry whose LOCAL coordinates are meant to be
    /// projected through `vp`.
    ///
    /// **Task 0659.** Kept alongside the composed viewport because the
    /// composition is lossy in the direction we need: `proj·view·M` cannot
    /// be taken apart again to recover `M`, yet a caller holding an aim
    /// space and a local vertex frequently needs that vertex's WORLD
    /// coordinate — falloff is the case that forced this (its weight is a
    /// world-space quantity, measured; see doc/tasks/…/0644-evidence).
    /// Carrying `ms` here means the caller states the layer ONCE, at the
    /// same `aimSpace(vp, ms)` call that already names it, and both the
    /// pixel-space and the world-space readings of the same vertex come
    /// out of one argument that cannot disagree with itself.
    @property ref const(ModelSpace) space() const return @safe pure nothrow @nogc {
        return ms_;
    }
    /// The world coordinate of a LOCAL point in this aim space's layer.
    /// Convenience for `space.toWorldPoint(p)`; identity-cheap.
    Vec3 toWorld(Vec3 localP) const @safe pure nothrow @nogc {
        return ms_.isIdentity ? localP : ms_.toWorldPoint(localP);
    }
}

/// Build the aiming space for `ms`: `projectionSpace(vp, ms)` in an
/// `AimViewport` wrapper. Adds a TYPE, not a behaviour — the composed
/// viewport is field-identical to `projectionSpace`'s, identity fast path
/// included. A stack copy plus (off the identity path) one `matMul4`: cheap
/// once per query, unacceptable per vertex — hoist it out of O(V) loops.
AimViewport aimSpace(const ref Viewport vp, const ModelSpace ms) @safe pure nothrow @nogc {
    return AimViewport(projectionSpace(vp, ms), ms);
}

unittest { // AimViewport.toWorld agrees with the ModelSpace it was built from,
           // and the identity fast path is not a different answer.
    import std.math : isClose;
    Viewport vp;
    ModelSpace ms;
    rotNonUniformSpace(ms);
    auto aim = aimSpace(vp, ms);
    Vec3 p = Vec3(0.3f, -1.25f, 2.0f);
    Vec3 a = aim.toWorld(p);
    Vec3 b = ms.toWorldPoint(p);
    assert(isClose(a.x, b.x) && isClose(a.y, b.y) && isClose(a.z, b.z),
           "AimViewport.toWorld must equal its ModelSpace's toWorldPoint");
    // Identity: toWorld is the identity map, not merely close to it.
    auto aimId = aimSpace(vp, ModelSpace.world());
    Vec3 c = aimId.toWorld(p);
    assert(c.x == p.x && c.y == p.y && c.z == p.z,
           "identity aim space must return the point unchanged");
}

unittest { // aimSpace adds a type, not a behaviour: field-identical to projectionSpace.
    import std.math : PI;
    Vec3 eye = Vec3(0, 0, 8);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 640; vp.height = 480; vp.x = 7; vp.y = 11;
    vp.eye = eye; vp.focus = Vec3(0, 0, 0);

    ModelSpace ms;
    rotNonUniformSpace(ms);

    Viewport ref_ = projectionSpace(vp, ms);
    auto     aim  = aimSpace(vp, ms);
    foreach (i; 0 .. 16) {
        assert(aim.vp.view[i] == ref_.view[i]);
        assert(aim.vp.proj[i] == ref_.proj[i]);
    }
    assert(aim.vp.width == ref_.width && aim.vp.height == ref_.height);
    assert(aim.vp.x == ref_.x && aim.vp.y == ref_.y);
    assert(aim.vp.eye.x == ref_.eye.x && aim.vp.eye.y == ref_.eye.y
        && aim.vp.eye.z == ref_.eye.z);
    assert(aim.vp.focus.x == ref_.focus.x && aim.vp.focus.y == ref_.focus.y
        && aim.vp.focus.z == ref_.focus.z);

    // Identity fast path: byte-identical to the world viewport handed in.
    auto id = aimSpace(vp, ModelSpace.world());
    foreach (i; 0 .. 16) {
        assert(id.vp.view[i] == vp.view[i]);
        assert(id.vp.proj[i] == vp.proj[i]);
    }
}

// ---------------------------------------------------------------------------
// Ray helpers used by plane drag
// ---------------------------------------------------------------------------

// World-space ray direction through screen pixel (sx, sy).
// Uses the view+proj stored in vp; accounts for viewport offset.
Vec3 screenRay(float sx, float sy, const ref Viewport vp)
{
    import std.math : sqrt;
    // NDC, Y-up
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;

    // View-space direction: invert perspective projection.
    // proj[0] = f/aspect, proj[5] = f  (diagonal of perspective matrix, row/col 0 and 1).
    // Using M[row][col] = m[row + col*4]: proj[0]=m[0], proj[5]=m[5].
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    // vz = -1 (camera looks along -Z in view space)

    // Rotate to world space: world = R^T * view_dir,
    // where R rows are view[0,4,8], view[1,5,9], view[2,6,10]  (M[row][col]=m[row+col*4]).
    // R^T col j = R row j, so world.x = R col0 · view_dir = view[0]*vx + view[1]*vy + view[2]*(-1)
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(
        v[0]*vx + v[1]*vy + v[2]*(-1.0f),
        v[4]*vx + v[5]*vy + v[6]*(-1.0f),
        v[8]*vx + v[9]*vy + v[10]*(-1.0f),
    );
    float len = d.length;
    return len > 1e-9f ? d / len : Vec3(0,0,-1);
}

/// Build a world-space ray through screen pixel (sx, sy).
/// Perspective: origin = vp.eye, dir = screenRay(sx, sy, vp) — byte-identical to the prior code.
/// Ortho: all rays share the view forward as direction; origin shifts per pixel on the near plane.
void screenPointToRay(float sx, float sy, const ref Viewport vp,
                      out Vec3 origin, out Vec3 dir)
{
    if (!isOrtho(vp)) {
        // Perspective path — byte-identical pass-through.
        origin = vp.eye;
        dir    = screenRay(sx, sy, vp);
        return;
    }
    // Ortho: proj[0] = 1/(halfH*aspect), proj[5] = 1/halfH.
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float worldX = nx / vp.proj[0];
    float worldY = ny / vp.proj[5];
    // View-matrix rows (column-major M[row][col] = m[row + col*4]):
    //   right   = (m[0], m[4], m[8])
    //   up      = (m[1], m[5], m[9])
    //   forward = (-m[2], -m[6], -m[10])
    const ref float[16] v = vp.view;
    Vec3 right   = Vec3(v[0], v[4], v[8]);
    Vec3 up      = Vec3(v[1], v[5], v[9]);
    Vec3 forward = Vec3(-v[2], -v[6], -v[10]);
    origin = vp.eye + right * worldX + up * worldY;
    dir    = normalize(forward);
}

/// The cursor ray of screen pixel (sx, sy), expressed in `ms`'s LOCAL space.
///
/// This is the **RayPlane** aiming law (task 0619,
/// doc/tool_aiming_item_transform_plan.md §1.2) as one call, so the three
/// steps that must not be reordered or skipped cannot be got wrong per site:
///
///  1. **Build the ray from the UN-composed, WORLD viewport.** An
///     `AimViewport` (a viewport with `M` folded into its view matrix) must
///     NOT be used here — `screenRay` treats the view 3x3's transpose as its
///     inverse, which is only valid for a rotation, and `M` generally carries
///     a scale. That is why this takes a plain `Viewport` and there is no
///     overload taking an `AimViewport`: the double-apply is a type error.
///  2. `toLocalPoint` the origin, `toLocalDir` the direction.
///  3. **Do NOT renormalize `dirLocal`.** `mInv*(o + t*d) == toLocalPoint(o)
///     + t*toLocalDir(d)`, so an un-normalized local direction keeps the ray
///     parameter `t` meaning a WORLD distance. Normalizing rescales `t` by
///     the layer's scale along the ray.
///
/// A plane test written against the result is EXACT, not approximate,
/// provided the plane is expressed in local space too — either because its
/// normal was built from local geometry already (a `mesh.faceNormal`), or by
/// carrying a world normal across with `ModelSpace.toLocalNormal` (`M^T`).
/// In both cases `dot(n_local, dirLocal) == dot(n_world, dirWorld)` exactly,
/// so `rayPlaneIntersect`'s parallel-ray guard fires on exactly the same
/// configurations it would have in world space.
///
/// Local is the destination (rather than lifting the geometry to world)
/// because the consumers of these hits WRITE LOCAL VERTEX COORDINATES.
/// Producing a world hit and handing it to such a consumer is the same
/// defect one call deeper.
void screenPointToLocalRay(float sx, float sy, const ref Viewport vpWorld,
                           const ModelSpace ms, out Vec3 orgLocal, out Vec3 dirLocal)
{
    Vec3 o, d;
    screenPointToRay(sx, sy, vpWorld, o, d);
    orgLocal = ms.toLocalPoint(o);
    dirLocal = ms.toLocalDir(d);   // deliberately NOT renormalized — see above
}

unittest { // screenPointToLocalRay + a local plane reads the SAME hit as the
    // world ray against the world plane — the identity every RayPlane site in
    // task 0619 relies on. Fixture: rotation + NON-UNIFORM scale, because
    // under a rotation alone every candidate law below collapses onto the
    // correct one.
    import std.math : PI, isClose;
    Vec3 eye = Vec3(2.5f, 1.8f, 7.0f);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 4.0f / 3.0f, 0.001f, 100.0f);
    vp.width = 800; vp.height = 600; vp.x = 0; vp.y = 0;
    vp.eye = eye; vp.focus = Vec3(0, 0, 0);

    ModelSpace ms;
    rotNonUniformSpace(ms);

    // A plane anchored on LOCAL geometry, with a LOCAL normal — the tack /
    // face-plane shape.
    Vec3 anchorL = Vec3(0.35f, -0.20f, 0.45f);
    Vec3 nLocal  = normalize(Vec3(0.2f, 0.9f, -0.35f));

    Vec3 oL, dL;
    screenPointToLocalRay(430.0f, 260.0f, vp, ms, oL, dL);
    Vec3 hitL;
    assert(rayPlaneIntersect(oL, dL, anchorL, nLocal, hitL), "local ray must meet the plane");

    // Ground truth, derived independently: the SAME plane in world space
    // (anchor through `m`, normal through the inverse-transpose) met by the
    // world ray, then carried back with `mInv`.
    Vec3 oW, dW;
    screenPointToRay(430.0f, 260.0f, vp, oW, dW);
    Vec3 hitW;
    assert(rayPlaneIntersect(oW, dW, ms.toWorldPoint(anchorL),
                             ms.toWorldNormal(nLocal), hitW));
    Vec3 truth = ms.toLocalPoint(hitW);
    assert((hitL - truth).length < 1e-3f,
        "the local-space ray/plane meet must be the world meet carried back");

    // ANTI-VACUITY (1): the pre-0619 law — world ray against the LOCAL plane,
    // i.e. no transform at all — must read a different point here, or this
    // fixture proves nothing.
    Vec3 hitWrong;
    assert(rayPlaneIntersect(oW, dW, anchorL, nLocal, hitWrong));
    assert((hitWrong - hitL).length > 1e-2f,
        "fixture is vacuous: the untransformed ray reads the same hit");

    // ANTI-VACUITY (2): renormalizing the local direction. The HIT point is
    // unchanged by that (a ray is a set of points), but `t` is not — and `t`
    // is a world distance every nearest-hit comparison ranks on. Pin the
    // scale factor so a future `normalize()` here is caught by a number.
    float tExact = dot(hitL - oL, dL) / dot(dL, dL);
    float tWorld = dot(hitW - oW, dW);   // dW is unit, so this IS world distance
    assert(tExact > 1e-4f && tWorld > 1e-4f);
    assert(isClose(tExact, tWorld, 1e-3f, 1e-3f),
        "the un-normalized local direction must keep `t` a WORLD distance");
    // ...and that is not automatic: had the direction been normalized, `t`
    // would read the LOCAL distance instead, a different number on this
    // fixture. (Asserted second so a broken implementation trips the
    // assertion above, which names the defect, rather than this one.)
    Vec3  dUnit = normalize(dL);
    float tUnit = dot(hitL - oL, dUnit);
    assert(!isClose(tExact, tUnit, 1e-2f, 1e-2f),
        "fixture is vacuous: normalizing the local direction leaves `t` unchanged");
}



// ---------------------------------------------------------------------------
// THE POLYGON-SURFACE ELECTION'S PRIMITIVES (task 0588).
//
// The five functions below exist for one caller — `snap.d`'s
// `closestOnPolygonSurface` — and they are here rather than there because
// `rayPlaneIntersect`, `closestOnSegmentToRay` and `pointInPolygon2D`, the
// primitives the same function used to be built from, are here.
//
// The law they compose is: triangulate the polygon, and per triangle either
// intersect the cursor's eye ray with it or take the closest point OF THE
// TRIANGLE measured in a frame perpendicular to that ray. Interior, edge and
// corner therefore fall out of ONE operation instead of an interior test plus
// a boundary ring. See `closestOnPolygonSurface` for the whole law and for
// what it replaced.
// ---------------------------------------------------------------------------

// The view's WORLD UNITS PER PIXEL at its own scale. Returns 0 when the view
// is degenerate (zero height, zero/negative projection scale, eye sitting on
// the focus); every caller must treat 0 as "no scale available" rather than
// dividing by it.
//
// ORTHO is exact: `proj[5] == 1/halfH`, so the viewport spans `2/proj[5]`
// world units of height at EVERY depth, and one pixel is that over `height`.
//
// PERSPECTIVE IS AN INFERENCE, and it is the one judgement call in this file's
// half of the port. There is no single world-per-pixel in a perspective view —
// it is a function of depth — so "the view's own scale" has to name a depth,
// and the depth named here is the eye-to-focus distance, i.e. the radius the
// camera orbits at. That is the depth the geometry a user is working on sits
// at, and it makes the returned scale depend on the CAMERA alone, which is
// what a per-view scalar has to be. It is NOT the depth of the point being
// ranked: a rank built on this divisor is deliberately not depth-correct, and
// that asymmetry is the whole observable content of the polygon leg's rank.
float viewPixelScale(const ref Viewport vp) @safe pure nothrow @nogc
{
    if (vp.height <= 0) return 0.0f;
    immutable float f = vp.proj[5];
    if (!(f > 1e-9f)) return 0.0f;          // also rejects NaN
    float dist = 1.0f;
    if (!isOrtho(vp)) {
        // A DEFAULT-CONSTRUCTED `focus` IS NaN, NOT THE ORIGIN (see the field's
        // own note). Every real viewport sets it; headless fixtures that build
        // a Viewport by hand overwhelmingly do not, and a NaN here would
        // propagate to a NaN distance, fail the test below, and switch the
        // whole polygon-surface leg off silently rather than loudly. Reading an
        // unset focus AS the origin is what the field always claimed to do, and
        // it is the reading under which such a fixture's camera distance is its
        // eye's distance from the origin — which is what those fixtures mean.
        Vec3 fo = vp.focus;
        if (!isFinite(fo.x) || !isFinite(fo.y) || !isFinite(fo.z))
            fo = Vec3(0, 0, 0);
        immutable Vec3 e = vp.eye - fo;
        dist = sqrt(dot(e, e));
        if (!(dist > 1e-9f)) return 0.0f;
    }
    return (2.0f * dist) / (f * cast(float)vp.height);
}

unittest { // viewPixelScale — the two projections, and the NaN focus a hand-built
           // fixture leaves behind.
    Viewport vp;
    vp.width = 800; vp.height = 800;
    vp.eye = Vec3(0, 0, 5);
    vp.proj = perspectiveMatrix(cast(float)(PI / 2), 1.0f, 0.1f, 100.0f);
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));

    // proj[5] = 1/tan(45deg) = 1, so the view spans 2*dist world units of
    // height; dist = |eye - focus| = 5; 10 world units over 800 pixels.
    assert(vp.focus.x != vp.focus.x,
        "fixture premise: an unassigned Vec3 is NaN, not the origin — the whole "
        ~ "point of the fallback below");
    assert(abs(viewPixelScale(vp) - 0.0125f) < 1e-7f,
        "an unset focus must be read as the origin, giving the eye's own "
        ~ "distance as the view's scale");

    vp.focus = Vec3(0, 0, 0);
    assert(abs(viewPixelScale(vp) - 0.0125f) < 1e-7f,
        "and setting it to the origin explicitly must not change the answer");

    // Twice as far from the focus -> twice the world per pixel.
    vp.eye = Vec3(0, 0, 10);
    assert(abs(viewPixelScale(vp) - 0.025f) < 1e-7f,
        "the perspective scale is proportional to the eye-to-focus distance");

    // Ortho carries no distance term at all: 2*halfH over the pixel height.
    Viewport o;
    o.width = 800; o.height = 800;
    o.eye = Vec3(0, 0, 10); o.focus = Vec3(0, 0, 0);
    o.proj = orthographicMatrix(4.0f, 1.0f, 0.1f, 100.0f);
    assert(isOrtho(o), "fixture premise: this must be the ortho branch");
    assert(abs(viewPixelScale(o) - 0.01f) < 1e-7f,
        "ortho spans 2*halfH world units of height at every depth");
    o.eye = Vec3(0, 0, 40);
    assert(abs(viewPixelScale(o) - 0.01f) < 1e-7f,
        "...and moving the ortho eye must not change it, which is what makes "
        ~ "the distance term perspective-only");

    Viewport bad;
    bad.width = 800; bad.height = 0;
    bad.proj = perspectiveMatrix(cast(float)(PI / 2), 1.0f, 0.1f, 100.0f);
    assert(viewPixelScale(bad) == 0.0f, "a zero-height view has no scale");
}


// Build the camera plane through the eye and the screen-space line (ax,ay)→(bx,by).
//
// For perspective: two rays from vp.eye span a unique plane through the eye.
// For ortho: rays are parallel with distinct origins; plane passes through originA,
// normal = cross(forward, originB - originA). Both branches are implemented below.
//
// Returns true when the plane is well-defined.
// Returns false (no-op; p and n are undefined) when:
//   - screen endpoints are too close  (Euclidean distance < pixelEps)
//   - cross-product is near-zero      (|cross(dA,dB)| < crossEps)
bool cameraPlaneFromScreenLine(const ref Viewport vp,
                               float ax, float ay, float bx, float by,
                               out Vec3 p, out Vec3 n,
                               float pixelEps = 1.0f, float crossEps = 1e-6f)
{
    // Cheap pre-check: reject a sub-pixel drag before computing any rays.
    float dx = bx - ax, dy = by - ay;
    if (dx*dx + dy*dy < pixelEps*pixelEps) return false;

    if (!isOrtho(vp)) {
        // Perspective: two rays through vp.eye span a unique plane.
        Vec3 dA = screenRay(ax, ay, vp);
        Vec3 dB = screenRay(bx, by, vp);
        Vec3 nRaw = cross(dA, dB);
        if (nRaw.length < crossEps) return false;
        p = vp.eye;
        n = normalize(nRaw);
        return true;
    }
    // Ortho: parallel rays with distinct origins.
    // Plane passes through originA; normal = cross(forward, originB - originA).
    Vec3 origA, dirA, origB, dirB;
    screenPointToRay(ax, ay, vp, origA, dirA);
    screenPointToRay(bx, by, vp, origB, dirB);
    Vec3 nRaw = cross(dirA, origB - origA);
    if (nRaw.length < crossEps) return false;
    p = origA;
    n = normalize(nRaw);
    return true;
}

unittest { // cameraPlaneFromScreenLine: vertical center line → normal parallel to world X
    auto vp = makeTestViewport();
    // makeTestViewport builds lookAt(Vec3(0,0,5), ...) but leaves vp.eye
    // zero-initialised; set it explicitly so the plane point assertion is meaningful.
    vp.eye = Vec3(0, 0, 5);

    Vec3 p, n;
    // A vertical center line (ax==bx==400): both rays have world-X component = 0
    // because nx = (400/800)*2 - 1 = 0.  cross(dA, dB) lies along world X.
    bool ok = cameraPlaneFromScreenLine(vp, 400, 100, 400, 700, p, n);
    assert(ok, "expected valid plane for vertical center line");

    // Normal must be unit length.
    assert(isClose(n.length, 1.0f, 1e-4f), "normal must be unit length");

    // Normal must be parallel to world X (Y and Z negligible).
    // Use abs(n.x) to tolerate either cross-product sign.
    assert(isClose(n.x * n.x, 1.0f, 1e-4f), "normal must be parallel to world X");
    assert(isClose(n.y, 0, 1e-4f, 1e-4f),    "normal Y must be zero");
    assert(isClose(n.z, 0, 1e-4f, 1e-4f),    "normal Z must be zero");

    // Plane point must equal the camera eye.
    assert(p.x == vp.eye.x && p.y == vp.eye.y && p.z == vp.eye.z,
           "plane point must equal vp.eye");
}

unittest { // cameraPlaneFromScreenLine: degenerate short line → false, no NaN
    auto vp = makeTestViewport();
    vp.eye = Vec3(0, 0, 5);
    Vec3 p, n;
    // Exactly coincident endpoints.
    assert(!cameraPlaneFromScreenLine(vp, 400, 400, 400, 400, p, n),
           "zero-length line must be degenerate");
    // Sub-pixel endpoints (distance ≈ 0.7 px < default pixelEps 1.0).
    assert(!cameraPlaneFromScreenLine(vp, 400, 400, 400.5f, 400.5f, p, n),
           "sub-pixel line must be degenerate");
}







// ---- Cumulative-euler ZYX helpers ----

























// ---------------------------------------------------------------------------
// Orientation — the camera's rotational truth.
// ---------------------------------------------------------------------------

version (unittest) {
    // The pre-matrix camera built its basis this way: a spherical offset
    // direction, the world +Y as the up hint, and a bank applied by rotating
    // the orthonormal (right, up) pair about the forward axis. Kept here as
    // the INDEPENDENT oracle `Orientation.fromAngles` (a closed form) is
    // checked against, so the closed form is pinned to the arithmetic it
    // replaced rather than only to itself.
    private Orientation chartBasisByCrossProducts(float az, float el, float roll) {
        Vec3 b   = normalize(sphericalToCartesian(az, el, 1.0f));
        Vec3 f   = -b;
        Vec3 up0 = Vec3(0, 1, 0);
        if (roll != 0.0f) {
            Vec3 r0 = normalize(cross(f, up0));
            Vec3 u0 = cross(r0, f);
            up0 = u0 * cos(roll) + r0 * sin(roll);
        }
        Vec3 r = normalize(cross(f, up0));
        return Orientation.fromBasis(r, cross(r, f), b);
    }
}

unittest { // fromAngles reproduces the cross-product chain it replaced
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.4f, -0.4f, 0.0f, 0.4138754f, 1.4f])
    foreach (r; [-1.2f, 0.0f, 0.2055634f, 2.5f]) {
        Orientation got  = Orientation.fromAngles(a, e, r);
        Orientation want = chartBasisByCrossProducts(a, e, r);
        foreach (i; 0 .. 9)
            assert(abs(got.m[i] - want.m[i]) < 2e-6f,
                   "fromAngles must agree with the spherical cross-product basis");
    }
}









unittest { // the orientation no longer depends on distance or focus
    // The property the previous model did NOT have, and the reason the ulp
    // above is a correction rather than a regression: with `lookAt` the same
    // azimuth/elevation produced a DIFFERENT basis at a different zoom or a
    // different look-at point. That is measured here on the old construction,
    // then shown absent from the new one.
    int lookAtVaried = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.4138754f, 1.5f]) {
        // OLD: same rotation, two zooms and two look-at points -> four bases.
        float[16] m1 = lookAt(sphericalToCartesian(a, e, 3.0f), Vec3(0, 0, 0), Vec3(0,1,0));
        float[16] m2 = lookAt(sphericalToCartesian(a, e, 7.5f), Vec3(0, 0, 0), Vec3(0,1,0));
        Vec3 fc = Vec3(0.25f, -0.5f, 2.0f);
        float[16] m3 = lookAt(fc + sphericalToCartesian(a, e, 3.0f), fc, Vec3(0,1,0));
        foreach (i; [0, 4, 8, 1, 5, 9, 2, 6, 10])
            if (m1[i] != m2[i] || m1[i] != m3[i]) { lookAtVaried++; break; }

        // NEW: one rotation, one matrix, whatever the zoom or the focus.
        Orientation o = Orientation.fromAngles(a, e, 0.0f);
        assert(o.m == Orientation.fromAngles(a, e, 0.0f).m);
    }
    assert(lookAtVaried >= 12,
           "the eye/target construction really did vary its basis with zoom and "
           ~ "focus — if this stops being true the ulp above needs re-explaining");
}







// Helper: viewport with lookAt camera at Z=5 and 90° symmetric perspective
version(unittest) private Viewport makeTestViewport() {
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0,0,0), Vec3(0,1,0));
    vp.proj   = perspectiveMatrix(PI/2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // screenRay: center pixel → along -Z
    auto vp = makeTestViewport();
    auto r = screenRay(400, 400, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}

unittest { // screenRay: result is always unit length
    auto vp = makeTestViewport();
    foreach (sx; [0.0f, 400.0f, 799.0f])
        foreach (sy; [0.0f, 400.0f, 799.0f]) {
            auto r = screenRay(sx, sy, vp);
            assert(isClose(r.length, 1.0f, 1e-4f));
        }
}

unittest { // screenRay: top-left pixel → (-1/√3, 1/√3, -1/√3) with 90° FOV aspect=1
    // proj[0]=proj[5]=1, so nx=-1,ny=1 → view-dir (-1,1,-1) → normalized
    auto vp = makeTestViewport();
    auto r = screenRay(0, 0, vp);
    float inv3 = 1.0f / sqrt(3.0f);
    assert(isClose(r.x, -inv3, 1e-4f));
    assert(isClose(r.y,  inv3, 1e-4f));
    assert(isClose(r.z, -inv3, 1e-4f));
}

unittest { // screenRay: viewport offset shifts pixel-to-NDC mapping
    auto vp = makeTestViewport();
    vp.x = 100;
    vp.y = 50;
    // Center of the offset viewport is now pixel (500, 450)
    auto r = screenRay(500, 450, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}



unittest { // screenPointToRay: perspective pass-through byte-identical
    import std.math : isClose;
    auto vp = makeTestViewport();
    Vec3 orig, dir;
    float sx = 300.0f, sy = 250.0f;
    screenPointToRay(sx, sy, vp, orig, dir);
    assert(orig.x == vp.eye.x && orig.y == vp.eye.y && orig.z == vp.eye.z,
           "perspective origin must equal vp.eye");
    Vec3 ref_ = screenRay(sx, sy, vp);
    assert(isClose(dir.x, ref_.x, 1e-5f) && isClose(dir.y, ref_.y, 1e-5f)
           && isClose(dir.z, ref_.z, 1e-5f),
           "perspective dir must match screenRay");
}
