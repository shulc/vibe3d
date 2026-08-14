// Module unittests for `tools.transform.xform_kernels`, moved verbatim out of source/tools/transform/xform_kernels.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.xform_kernels_test;

import math    : Vec3, Viewport, dot, cross, AimViewport, rotateAboutPivot;
import math    : Quat, slerp, quatFromMatrix, matrixFromQuat, applyAffine,
                 matMul4, identityMatrix;
import mesh    : Mesh;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform.transform : TransformTool;
import perf_probe : g_perf, Cat;
import tools.transform.xform_kernels;
// Task 0719 (T5) — the matrix builder the kernel tests below drive the fold
// with; the rest of what they need is already in this module's import list.
import math : pivotRotationMatrix;

unittest {
    import std.math : abs, sqrt;

    // ── THE FIVE RECORDED PRESSES ─────────────────────────────────────────
    //
    // `eye` and `screenRight` are the reference's OWN values at the instant of
    // the press, read off a recorded execution — not reconstructed from a
    // camera, not fitted. `excluded` / `h` / `v` are what the reference then
    // did, read at its write sites. Press 0 and 1 are two presses that landed
    // on identical inputs and are kept as two rows because that is what was
    // recorded.
    //
    // Press 0/1 sit on the reference-comparison camera — the one the corpus
    // uses and the one where every miss of the retracted rule lives. There the
    // view direction's argmax is z and the EYE RAY's is x; the reference
    // elected x, gave the horizontal to Z, and the corpus recorded z scaling.
    //
    // If a row here has to change, the recording is what says so. Re-read it;
    // do not edit a row to make a rule pass.
    static struct Press {
        string name;
        Vec3   eye;           // E,  the unit eye ray at the action centre
        Vec3   screenRight;   // N0, the view's own right (banked)
        Vec3   screenDown;    // N1, the view's own down  (banked)
        int    excluded;      // what the reference left alone
        int    h, v;          // which axis each screen component drove
    }
    immutable Press[5] presses = [
        Press("press 0 (corpus camera)",
              Vec3(+0.632126f, -0.466933f, -0.618377f),
              Vec3(+0.817569f, -0.186885f, +0.544661f),
              Vec3(-0.368870f, -0.896293f, +0.246158f), 0, 2, 1),
        Press("press 1 (corpus camera)",
              Vec3(+0.632126f, -0.466933f, -0.618377f),
              Vec3(+0.817569f, -0.186885f, +0.544661f),
              Vec3(-0.368870f, -0.896293f, +0.246158f), 0, 2, 1),
        Press("press 2",
              Vec3(+0.912497f, -0.401305f, +0.079394f),
              Vec3(+0.269283f, +0.148164f, +0.951596f),
              Vec3(-0.371322f, -0.895723f, +0.244541f), 0, 2, 1),
        Press("press 3",
              Vec3(+0.656215f, -0.116679f, +0.745499f),
              Vec3(-0.434452f, +0.398292f, +0.807846f),
              Vec3(-0.372142f, -0.896155f, +0.241696f), 2, 0, 1),
        Press("press 4",
              Vec3(+0.748319f, +0.330960f, +0.574877f),
              Vec3(-0.435557f, +0.395600f, +0.808573f),
              Vec3(+0.086892f, -0.875582f, +0.475191f), 0, 2, 1),
    ];

    // The retracted rule, kept executable so its retraction is a MEASUREMENT
    // rather than a sentence: "the axis whose unit screen projection is the
    // most horizontal takes the horizontal component". This is what shipped
    // for two commits, scored 6 of 7 cameras on a camera-only corpus, and is
    // what the read replaced. It runs here on the reference's OWN recorded
    // basis — the most favourable input it could be given — and it is the
    // per-axis NORMALISATION that decides three of its four misses, so the
    // body is reproduced faithfully rather than shortened to an argmax.
    static int retractedHorizontalAxis(Vec3 camRight, Vec3 camUp,
                                       out float nearTieMargin) {
        Vec3[3] ax = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
        float[3] sx;
        foreach (i, a; ax) {
            immutable float px =  dot(camRight, a);
            immutable float py = -dot(camUp,    a);
            immutable float m  = sqrt(px * px + py * py);
            sx[i] = px / m;
        }
        int best = 0;
        foreach (i; 1 .. 3) if (abs(sx[i]) > abs(sx[best])) best = cast(int)i;
        float top = -1.0f, second = -1.0f;
        foreach (i; 0 .. 3) {
            immutable float v = abs(sx[i]);
            if (v > top) { second = top; top = v; }
            else if (v > second) second = v;
        }
        nearTieMargin = top - second;
        return best;
    }

    int reproduced, retractedHits;
    foreach (p; presses) {
        int h, v, ex; float margin;
        assert(pickScalePlaneAxes(p.eye, p.screenRight,
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, margin),
               "the election must resolve on " ~ p.name);
        assert(ex == p.excluded,
               "the excluded axis on " ~ p.name ~ " does not match the "
               ~ "recording — re-read the trace, do not edit this row");
        assert(h == p.h && v == p.v,
               "the screen-component assignment on " ~ p.name ~ " does not "
               ~ "match the recording");
        reproduced++;
        // The reference never dropped world Y on any recorded press, so the
        // one branch that reads a basis never ran. That is the unconfirmed leg.
        assert(ex != 1, "no recorded press elected Y — see the unconfirmed leg");

        // Score the retracted rule on the same press, in the reference's own
        // basis (both rows recorded, so nothing here is reconstructed).
        float unused;
        if (retractedHorizontalAxis(p.screenRight, p.screenDown, unused) == p.h)
            retractedHits++;
    }
    assert(reproduced == 5,
           "the read rule reproduces the reference on 5 of 5 recorded presses");
    assert(retractedHits == 1,
           "the retracted screen-horizontal rule reproduces 1 of the 5 recorded "
           ~ "presses, in the reference's OWN basis. That number replaces "
           ~ "'6 of 7 cameras', which was a per-CAMERA score of a camera-only "
           ~ "rule against a reference whose election is per-PRESS");

    // The 0.00026 the campaign spent three phases on, located exactly: it is
    // the retracted rule's own margin at the corpus camera. The reference does
    // not make that comparison there, so the near-tie was never a tie in
    // anything the reference computes.
    {
        float m; retractedHorizontalAxis(presses[0].screenRight,
                                         presses[0].screenDown, m);
        assert(m < 0.0003f,
               "the retracted rule reads the corpus camera as a 0.00026 "
               ~ "near-tie — that is where the campaign's famous number "
               ~ "lived, and it belongs to a comparison the reference skips");
    }

    // The margin at the corpus camera, on the quantity the reference compares.
    // 0.013749, against the 0.00026 the campaign spent three phases on — which
    // was the margin of a comparison the reference does not make there.
    {
        int h, v, ex; float margin;
        pickScalePlaneAxes(presses[0].eye, presses[0].screenRight,
                           Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                           h, v, ex, margin);
        assert(abs(margin - 0.013749f) < 1e-5f,
               "the corpus camera's election margin is 0.013749 on the eye "
               ~ "ray — 53x the 0.00026 near-tie it was mistaken for");
    }

    // ── ROLL-INVARIANCE ───────────────────────────────────────────────────
    //
    // The reason the basis refusal does NOT carry over to this rule. Roll the
    // screen-right arbitrarily about the eye ray: the two branches that make no
    // comparison must not move. This is what makes our unbanked viewport
    // irrelevant to them.
    foreach (p; presses) {
        Vec3 rolled = cross(p.eye, p.screenRight);   // 90 deg of roll
        immutable float rl = sqrt(dot(rolled, rolled));
        rolled = Vec3(rolled.x / rl, rolled.y / rl, rolled.z / rl);
        int h0, v0, e0, h1, v1, e1; float m0, m1;
        pickScalePlaneAxes(p.eye, p.screenRight, Vec3(1,0,0), Vec3(0,1,0),
                           Vec3(0,0,1), h0, v0, e0, m0);
        pickScalePlaneAxes(p.eye, rolled, Vec3(1,0,0), Vec3(0,1,0),
                           Vec3(0,0,1), h1, v1, e1, m1);
        assert(e0 == e1 && h0 == h1 && v0 == v1 && m0 == m1,
               "a roll must not move the election on " ~ p.name);
    }

    // ── THE TIE RULE ──────────────────────────────────────────────────────
    //
    // Strict `>` at index 0 and at index 1's second test, no epsilon: an exact
    // tie goes to the HIGHER index. Read off 22 instructions; never reached on
    // the recorded corpus, so this is the decode's own claim and nothing else.
    {
        static int electedFor(Vec3 e) {
            int h, v, ex; float m;
            pickScalePlaneAxes(e, Vec3(1,0,0), Vec3(1,0,0), Vec3(0,1,0),
                               Vec3(0,0,1), h, v, ex, m);
            return ex;
        }
        assert(electedFor(Vec3(1, 1, 0)) == 1, "x==y ties to y");
        assert(electedFor(Vec3(0, 1, 1)) == 2, "y==z ties to z");
        assert(electedFor(Vec3(1, 0, 1)) == 2, "x==z ties to z");
        assert(electedFor(Vec3(1, 1, 1)) == 2, "a three-way tie goes to z");
        // Signs are irrelevant — the elector compares magnitudes.
        assert(electedFor(Vec3(-1, 1, 0)) == 1, "the elector is sign-blind");
        assert(electedFor(Vec3(0.9f, 0, -1)) == 2, "the largest magnitude wins");
    }

    // ── THE UNCONFIRMED LEG (excluded == 1) ───────────────────────────────
    //
    // Decoded statically, executed zero times on the recording. Both arms are
    // asserted so a rule change is visible, but neither is confirmed against
    // the reference and neither should be cited as measured.
    {
        immutable Vec3 nearTop = Vec3(0.1f, 0.99f, 0.05f);   // |E_y| dominates
        int h, v, ex; float m;
        // Arm 1: X projects more strongly onto screen-right than Z does.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.9f, 0.0f, 0.1f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1, "a near-top eye ray must drop world Y");
        assert(h == 0 && v == 2, "|X.R| > |Z.R| gives h=X, v=Z");
        // Arm 2: Z wins the same comparison.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.1f, 0.0f, 0.9f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1 && h == 2 && v == 0, "|Z.R| > |X.R| gives h=Z, v=X");
        // Arm 2 again by the tie: the comparison is strict, so an exact tie
        // takes the second arm.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.5f, 0.0f, -0.5f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1 && h == 2 && v == 0,
               "an exact tie in the Y-out comparison takes the second arm");
    }

    // ── DEGENERACY ────────────────────────────────────────────────────────
    {
        int h, v, ex; float m;
        assert(!pickScalePlaneAxes(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                   Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                   h, v, ex, m),
               "an action centre sitting on the eye has no eye ray");
    }

    // ── THE FACTOR LAW — unchanged, and measured ──────────────────────────
    //
    // 200 px on a component gives 1.64 / 0.36; the recording's own writes were
    // 1.10 1.14 1.20 1.28 1.32 on +100 px horizontal and 0.90 0.86 0.80 0.72
    // 0.68 on +100 px down, i.e. 1 +/- px/312.5 exactly.
    assert(abs(screenPlaneScaleGain( 200.0f,  1.0f, 312.5f) - 1.64f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 200.0f, -1.0f, 312.5f) - 0.36f) < 1e-6f);
    assert(abs(screenPlaneScaleGain(-200.0f, -1.0f, 312.5f) - 1.64f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 100.0f,  1.0f, 312.5f) - 1.32f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 100.0f, -1.0f, 312.5f) - 0.68f) < 1e-6f);
    // It passes through zero and goes negative rather than clamping.
    assert(screenPlaneScaleGain(-400.0f, 1.0f, 312.5f) < 0.0f);
}

// ═════════════════════════════════════════════════════════════════════════
// Task 0719 (audit 4, finding T5) — kernel-level tests.
//
// The finding: `move` / `rotate` / `scale` / `transform` carried 5 unittest
// blocks between them across ~6.5k lines, and the transform invariants lived
// in comments instead. The blocks below are the first instalment for the
// kernel module — the pure per-vertex math the tool's fold calls, which needs
// no GL, no tool instance and no HTTP to exercise.
//
// EVERY block below was confirmed to FAIL on a deliberate break of the kernel
// it covers before being kept; the break is named in each block's header. An
// assertion nobody has ever seen fail is the defect this codebase keeps
// finding in itself, so a test that passed on the first run is not evidence.
// ═════════════════════════════════════════════════════════════════════════

private AimViewport kernelAim() {
    import math : lookAt, perspectiveMatrix, aimSpace, ModelSpace;
    import std.math : PI;
    Viewport vp;
    vp.view   = lookAt(Vec3(0, 0, 5), Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    return aimSpace(vp, ModelSpace.world());
}

// Explicit per-vertex weights via the Selection type: `evaluateFalloff` looks
// them up by vertex index, so a block can name the weight it wants instead of
// arranging a camera and a distance field to produce it.
private FalloffPacket weightsFalloff(float[] w) {
    import toolpipe.packets : FalloffType;
    FalloffPacket f;
    f.enabled = true;
    f.type    = FalloffType.Selection;
    f.selectionWeights = w.dup;
    return f;
}

private FalloffPacket plainFalloff() { FalloffPacket f; f.enabled = false; return f; }
private SymmetryPacket noMirror()    { SymmetryPacket s; s.enabled = false; return s; }
private TransformTool.ClusterPivots noPivots() { TransformTool.ClusterPivots c; return c; }
private TransformTool.ClusterAxes   noAxes()   { TransformTool.ClusterAxes   a; return a; }

unittest { // T5/1 — soft rotate is the MATRIX lerp (1-w)I + w·R, NOT the arc R(w·θ)
    //
    // The distinction is the module's own doc claim ("It is NOT the 'arc'
    // R(angle·w) (radius-preserving)") and it was measured against the
    // reference, but nothing in the module-unittest gate asserted it: the
    // matrix-kernel test in the runner lane checks the matrix kernel and this
    // kernel AGREE, which stays true if BOTH are changed to the arc.
    //
    // The angle alone cannot tell the two laws apart — at w=1/2 both put the
    // point at 45 degrees. The RADIUS can: the matrix lerp pinches it to
    // 1/sqrt(2), the arc keeps it at 1. So the radius is what this asserts.
    //
    // BREAK THAT MADE IT FAIL: `rotateVecLerp`'s body replaced by the arc,
    // `return rotateAboutPivot(v, pivot, axis, angle * w);` — radius came back
    // 1.0 against the expected 0.7071 and the block went red.
    import std.math : PI, fabs, sqrt;

    auto m = new Mesh();
    m.vertices = [Vec3(1, 0, 0)];
    auto fal  = weightsFalloff([0.5f]);
    auto sym  = noMirror();
    bool[] proc = [true];

    applyRotateIncremental(m, [0], Vec3(0, 0, 0), Vec3(0, 0, 1), -1,
                           cast(float)(PI / 2), fal, kernelAim(),
                           noPivots(), noAxes(), sym, proc);

    const Vec3 got = m.vertices[0];
    const float radius = sqrt(got.x * got.x + got.y * got.y + got.z * got.z);
    assert(fabs(radius - 0.70710678f) < 1e-5f,
           "half-weight rotation must PINCH the radius to 1/sqrt(2); a radius "
           ~ "of 1 means the kernel became the arc rule R(w*theta)");
    assert(fabs(fabs(got.x) - 0.5f) < 1e-5f && fabs(fabs(got.y) - 0.5f) < 1e-5f,
           "(1-w)*(1,0,0) + w*R(1,0,0) is (0.5, +/-0.5, 0)");
    assert(fabs(got.z) < 1e-6f, "a rotation about +Z cannot move Z");

    // The law stated as a law, not as one sample: for ANY weight the result is
    // the straight-line blend between the unrotated and the fully rotated
    // point. (`rotateAboutPivot` is math.d's, pinned there.)
    foreach (wi; 0 .. 5) {
        const float w = wi * 0.25f;
        auto m2 = new Mesh();
        m2.vertices = [Vec3(1, 0, 0)];
        auto f2 = weightsFalloff([w]);
        bool[] p2 = [true];
        applyRotateIncremental(m2, [0], Vec3(0, 0, 0), Vec3(0, 0, 1), -1,
                               cast(float)(PI / 2), f2, kernelAim(),
                               noPivots(), noAxes(), sym, p2);
        const Vec3 full = rotateAboutPivot(Vec3(1, 0, 0), Vec3(0, 0, 0),
                                           Vec3(0, 0, 1), cast(float)(PI / 2));
        const Vec3 want = Vec3(1, 0, 0) * (1.0f - w) + full * w;
        // w == 0 is the kernel's `continue` fast path: the vertex is left
        // untouched, which for this rig IS the w == 0 blend.
        assert(fabs(m2.vertices[0].x - want.x) < 1e-5f
            && fabs(m2.vertices[0].y - want.y) < 1e-5f
            && fabs(m2.vertices[0].z - want.z) < 1e-5f,
               "the weighted rotate is a LINE between v and R*v, at every w");
    }
}

unittest { // T5/2 — blendToIdentity's w>=1 endpoint returns M exactly, in EVERY mode
    //
    // The docstring promises "`w == 1` returns `M` exactly (all modes)". For
    // MatrixLerp that is arithmetically automatic. For Decompose / PolarQuat
    // it is true ONLY because of the early return: those modes rebuild M from
    // a column-norm + quaternion decomposition, and the module's own C2 caveat
    // says that decomposition mis-reads a negative-determinant M. So a
    // REFLECTION is the matrix that tells the guarantee apart from the
    // arithmetic — on a plain rotation the decomposition would round-trip and
    // the endpoint would look safe whether or not it was.
    //
    // BREAK THAT MADE IT FAIL: `if (w >= 1.0f) return M;` weakened to
    // `if (w > 1.0f) return M;`. MatrixLerp stayed exact; Decompose and
    // PolarQuat came back with M[0] = +1 instead of -1 (the reflection read as
    // a rotation) and both assertions went red.
    float[16] refl;
    foreach (i; 0 .. 16) refl[i] = 0.0f;
    refl[0] = -1.0f; refl[5] = 1.0f; refl[10] = 1.0f; refl[15] = 1.0f;
    refl[12] = 0.3f; refl[13] = -0.2f; refl[14] = 0.7f;

    foreach (mode; [BlendMode.MatrixLerp, BlendMode.Decompose, BlendMode.PolarQuat]) {
        const float[16] at1 = blendToIdentity(refl, 1.0f, mode);
        foreach (i; 0 .. 16)
            assert(at1[i] == refl[i],
                   "w>=1 must return M ITSELF, not a decomposition of it — a "
                   ~ "reflection does not survive the round trip");
        const float[16] over = blendToIdentity(refl, 1.5f, mode);
        foreach (i; 0 .. 16)
            assert(over[i] == refl[i], "w>1 saturates at M, it does not extrapolate");

        const float[16] at0 = blendToIdentity(refl, 0.0f, mode);
        foreach (i; 0 .. 16)
            assert(at0[i] == identityMatrix[i],
                   "w<=0 must return the identity exactly, in every mode");
    }
}

unittest { // T5/3 — MatrixLerp blends toward the IDENTITY, entrywise, and only that
    //
    // BREAK THAT MADE IT FAIL: `(1.0f - w) * identityMatrix[i]` changed to
    // `(1.0f - w) * 0.0f` — i.e. blending toward the zero matrix instead of
    // the identity, the shape of typo this line invites. The diagonal came
    // back 0.5 instead of 1.0 and the block went red. (Swapping the two
    // weights, `w * identityMatrix[i] + (1-w) * M[i]`, reddens it too.)
    float[16] M;
    foreach (i; 0 .. 16) M[i] = 0.0f;
    M[0] = 3.0f; M[5] = -2.0f; M[10] = 0.5f; M[15] = 1.0f;
    M[12] = 4.0f; M[13] = 8.0f; M[14] = -6.0f;
    M[1] = 0.25f;   // an off-diagonal term, so "entrywise" means something

    const float w = 0.25f;
    const float[16] got = blendToIdentity(M, w, BlendMode.MatrixLerp);
    foreach (i; 0 .. 16) {
        const float want = (1.0f - w) * identityMatrix[i] + w * M[i];
        assert(got[i] == want,
               "MatrixLerp is (1-w)*I + w*M entrywise — no re-orthogonalisation, "
               ~ "no separate treatment of the translation column");
    }
    // Spelled out where the identity actually shows up, so the intent survives
    // a rewrite of the loop above.
    assert(got[0]  == 0.75f * 1.0f + 0.25f * 3.0f);   // diagonal blends toward 1
    assert(got[1]  == 0.25f * 0.25f);                 // off-diagonal toward 0
    assert(got[12] == 0.25f * 4.0f);                  // translation toward 0
    assert(got[15] == 1.0f);
}

unittest { // T5/4 — the three modes are three DIFFERENT laws, and a/c coincide on a pure rotation
    //
    // The docstring's central claim about the fractional range: Decompose (a)
    // and PolarQuat (c) "for a SINGLE pure rotation ... trace the same great
    // circle and coincide", while MatrixLerp (b) "never re-orthogonalizes".
    // Measured here as a radius: a and c keep it, b pinches it — the same
    // pinch T5/1 pins on the live rotate kernel, which is what makes b the
    // production default rather than an approximation of a.
    //
    // BREAK THAT MADE IT FAIL: `slerp(Quat.identity(), R, w)` reversed to
    // `slerp(R, Quat.identity(), w)`, so PolarQuat interpolates from the
    // rotation BACK to the identity instead of forward from it.
    //
    // THE FIRST VERSION OF THIS BLOCK DID NOT CATCH THAT, and the reason is
    // worth keeping: it sampled w = 1/2 only, and 1/2 is the MIDPOINT of the
    // great circle — the one weight at which the reversed slerp lands on the
    // same quaternion. The block was green on a genuinely broken kernel. It
    // now sweeps asymmetric weights as well, and at w = 1/4 the reversal moves
    // the point from 22.5 to 67.5 degrees, which the a-vs-c assertion catches.
    // (Every radius assertion stays green under that break — a reversed slerp
    // is still a rotation — which is why the agreement is asserted separately
    // from the radius, and why the ANGLE is pinned below at an asymmetric w.)
    import std.math : PI, fabs, sqrt, cos, sin;
    const float[16] rot90 =
        pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 0, 1), cast(float)(PI / 2));
    const Vec3 p = Vec3(1, 0, 0);

    static float radius(Vec3 v) { return sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }

    foreach (wi; 1 .. 4) {
        const float w = wi * 0.25f;                       // 0.25, 0.5, 0.75
        const Vec3 a = applyAffine(blendToIdentity(rot90, w, BlendMode.Decompose), p);
        const Vec3 c = applyAffine(blendToIdentity(rot90, w, BlendMode.PolarQuat), p);
        const Vec3 b = applyAffine(blendToIdentity(rot90, w, BlendMode.MatrixLerp), p);

        assert(fabs(a.x - c.x) < 1e-6f && fabs(a.y - c.y) < 1e-6f
            && fabs(a.z - c.z) < 1e-6f,
               "on a single pure rotation the axis-angle blend and the slerp "
               ~ "are the same great circle — a and c must coincide at EVERY "
               ~ "weight, not only at the symmetric midpoint");
        assert(fabs(radius(a) - 1.0f) < 1e-5f, "a re-orthogonalises: radius is kept");
        assert(fabs(radius(c) - 1.0f) < 1e-5f, "c re-orthogonalises: radius is kept");
        assert(radius(b) < 1.0f - 1e-4f,
               "b does NOT re-orthogonalise: a partial blend of I and R(90) "
               ~ "shears, and that pinch is the production behaviour");

        // Both re-orthogonalising modes take the rotation FORWARD from the
        // identity: at weight w the angle is w*90 degrees, not (1-w)*90.
        const float ang = cast(float)(PI / 2) * w;
        assert(fabs(a.x - cos(ang)) < 1e-5f && fabs(a.y - sin(ang)) < 1e-5f,
               "the fractional rotation is w*theta measured FROM the identity");
        assert(fabs(c.x - cos(ang)) < 1e-5f && fabs(c.y - sin(ang)) < 1e-5f,
               "the slerp runs identity -> R, not R -> identity");
    }

    // At w = 1/2 the two laws' outputs, spelled out: the angle is where all
    // three AGREE (45 degrees), the radius is where b leaves.
    const Vec3 aHalf = applyAffine(blendToIdentity(rot90, 0.5f, BlendMode.Decompose), p);
    const Vec3 bHalf = applyAffine(blendToIdentity(rot90, 0.5f, BlendMode.MatrixLerp), p);
    assert(fabs(aHalf.x - 0.70710678f) < 1e-5f && fabs(aHalf.y - 0.70710678f) < 1e-5f);
    assert(fabs(bHalf.x - 0.5f) < 1e-5f && fabs(bHalf.y - 0.5f) < 1e-5f);
    assert(fabs(radius(bHalf) - 0.70710678f) < 1e-5f);
}

unittest { // T5/5 — scale: s_eff = 1 + (s-1)*w, raised to compoundPasses, and the negative-base clamp
    //
    // `compoundPasses` appears in exactly one test in the tree and only ever
    // at 1.0, so the pow() branch and its guard were both unexercised. The
    // guard is not cosmetic: Selection falloff publishes a FRACTIONAL exponent
    // (~1.91 for two steps), and pow(negative, fractional) is NaN. A negative
    // effective factor is reachable — that is what a mirroring scale IS — so
    // without the guard a mirrored soft scale writes NaN into the mesh.
    //
    // BREAK THAT MADE IT FAIL: the three `if (sx > 0)` / `if (sy > 0)` /
    // `if (sz > 0)` guards dropped, leaving the bare `sx = pow(sx, passes);`.
    // The mirrored vertex came back NaN and the third assertion went red (the
    // first two stayed green — they never reach a negative base).
    import std.math : fabs, pow, isNaN;

    // (1) the blend law itself, at a fractional weight, exponent 1.
    {
        auto m = new Mesh();
        m.vertices = [Vec3(2, 0, 0)];
        auto fal = weightsFalloff([0.5f]);
        auto sym = noMirror();
        bool[] proc = [true];
        applyScaleFromActivation(m, [0], [Vec3(2, 0, 0)], Vec3(0, 0, 0),
                                 Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
                                 Vec3(3, 1, 1), fal, kernelAim(),
                                 noPivots(), noAxes(), sym, proc);
        // s_eff = 1 + (3-1)*0.5 = 2  ⇒  x: 2 -> 4. Half the weight is HALF the
        // excess over 1, not half the factor (which would give 1.5 -> 3).
        assert(fabs(m.vertices[0].x - 4.0f) < 1e-5f,
               "s_eff must be 1 + (s-1)*w");
    }

    // (2) the compound exponent, applied to the ALREADY-BLENDED factor.
    {
        auto m = new Mesh();
        m.vertices = [Vec3(1, 0, 0)];
        auto fal = plainFalloff();          // w == 1
        fal.compoundPasses = 1.91f;         // read regardless of `enabled`
        auto sym = noMirror();
        bool[] proc = [true];
        applyScaleFromActivation(m, [0], [Vec3(1, 0, 0)], Vec3(0, 0, 0),
                                 Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
                                 Vec3(2, 1, 1), fal, kernelAim(),
                                 noPivots(), noAxes(), sym, proc);
        assert(fabs(m.vertices[0].x - cast(float)pow(2.0f, 1.91f)) < 1e-5f,
               "the compound pass raises the per-axis factor to compoundPasses");
        // The untouched axes carry factor 1, and 1^1.91 is still 1 — the
        // exponent must not leak into them as a translation or a zero.
        assert(m.vertices[0].y == 0.0f && m.vertices[0].z == 0.0f);
    }

    // (3) a NEGATIVE effective factor with a fractional exponent: the pow is
    //     skipped, the mirror survives, and nothing becomes NaN.
    {
        auto m = new Mesh();
        m.vertices = [Vec3(2, 0, 0)];
        auto fal = plainFalloff();
        fal.compoundPasses = 1.91f;
        auto sym = noMirror();
        bool[] proc = [true];
        applyScaleFromActivation(m, [0], [Vec3(2, 0, 0)], Vec3(0, 0, 0),
                                 Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
                                 Vec3(-1, 1, 1), fal, kernelAim(),
                                 noPivots(), noAxes(), sym, proc);
        assert(!isNaN(m.vertices[0].x),
               "pow(negative, fractional) is NaN — the sx>0 guard is what keeps "
               ~ "a mirroring scale out of the mesh as NaN");
        assert(fabs(m.vertices[0].x - (-2.0f)) < 1e-5f,
               "a negative factor mirrors ONCE: the compound pass is skipped, "
               ~ "not applied and not squared");
    }
}

unittest { // T5/6 — two kernels, two OPPOSITE conventions for a vertex they decline
    //
    // `applyRotateFromOrig` RESETS a vertex outside its mask to the original
    // snapshot; `applyXformMatrix` LEAVES a zero-weight vertex exactly where
    // it found it. Both are deliberate and they are opposites, so each one
    // reads like the other's bug until they are asserted side by side. Both
    // rigs below put a value in `mesh.vertices` that is NOT the baseline
    // before calling, which is the only setup that can tell "reset" from
    // "left alone" apart.
    //
    // BREAKS THAT MADE IT FAIL, one per half:
    //  - `applyRotateFromOrig`: the mask-miss branch reduced to a bare
    //    `continue;` (dropping `mesh.vertices[i] = origVerts[i];`). The vertex
    //    kept the dirty value and the first assertion went red.
    //  - `applyXformMatrix`: `if (w == 0.0f) continue;` changed to
    //    `if (w == 0.0f) { mesh.vertices[vi] = base; continue; }`. The vertex
    //    snapped back to the baseline and the second assertion went red.
    import std.math : PI, fabs;

    const Vec3 orig  = Vec3(1, 0, 0);
    const Vec3 dirty = Vec3(9, 9, 9);   // neither the baseline nor any result

    // (a) rotate-from-orig RESETS what its mask declines.
    {
        auto m = new Mesh();
        m.vertices = [orig, dirty];
        auto fal = plainFalloff();
        auto sym = noMirror();
        bool[] symMask = [true, false];
        applyRotateFromOrig(m, [orig, orig], [true, false],
                            Vec3(0, 0, 0),
                            Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
                            Vec3(0, 0, cast(float)(PI / 2)),
                            fal, kernelAim(), noPivots(), noAxes(), sym, symMask);
        assert(m.vertices[1] == orig,
               "a vertex outside toProcessMask is RESET to the snapshot — this "
               ~ "kernel rebuilds the whole array from origVerts every call");
        assert(fabs(m.vertices[0].y - 1.0f) < 1e-5f,
               "the in-mask vertex still rotated (the rig is not vacuous)");
    }

    // (b) the matrix kernel LEAVES a zero-weight vertex alone.
    {
        auto m = new Mesh();
        m.vertices = [orig, dirty];
        auto fal = weightsFalloff([1.0f, 0.0f]);
        auto sym = noMirror();
        bool[] proc = [true, true];
        const float[16] rot90 =
            pivotRotationMatrix(Vec3(0, 0, 0), Vec3(0, 0, 1), cast(float)(PI / 2));
        applyXformMatrix(m, [0, 1], [orig, orig], Vec3(0, 0, 0), rot90,
                         Vec3(0, 0, 0), BlendMode.MatrixLerp,
                         fal, kernelAim(), noPivots(), noAxes(), null,
                         sym, proc);
        assert(m.vertices[1] == dirty,
               "a zero-weight vertex is SKIPPED, not restored — the fold's "
               ~ "prologue already restored the baseline, so writing it again "
               ~ "here would undo a prior pass in the same chain");
        assert(fabs(m.vertices[0].y - 1.0f) < 1e-5f,
               "the weighted vertex still rotated (the rig is not vacuous)");
    }
}

unittest { // T5/7 — an out-of-range cluster id falls back; it does not index the array
    //
    // `pivotFor` / `axisFor` guard `cid` against BOTH ends of the cluster
    // arrays. The packet they read is assembled by the action-centre and axis
    // stages from separate arrays whose lengths are not tied together by any
    // type, so a `clusterOf` naming a cluster the centre array does not have is
    // a representable state, and the guard is what stands between it and an
    // out-of-bounds read on the live drag path.
    //
    // BREAK THAT MADE IT FAIL: `if (cid < 0 || cid >= cast(int)cp.centers.length)`
    // narrowed to `if (cid < 0)` in `pivotFor`. The block died on the read
    // rather than on an assertion — `core.exception.ArrayIndexError@
    // xform_kernels.d(153): index [7] is out of bounds for array of length 2`,
    // through `pivotFor` <- `applyRotateIncremental` <- this block. A red gate
    // either way, and exactly the crash the guard prevents on the live path.
    import std.math : PI, fabs;

    auto m = new Mesh();
    m.vertices = [Vec3(1, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 0)];

    TransformTool.ClusterPivots cp;
    cp.centers   = [Vec3(50, 0, 0), Vec3(-50, 0, 0)];   // >= 2 ⇒ active
    cp.clusterOf = [0, 7];   // vertex 1 names a cluster that does not exist,
                             // vertex 2 is past the end of clusterOf entirely
    auto fal = plainFalloff();
    auto sym = noMirror();
    bool[] proc = [true, true, true];

    applyRotateIncremental(m, [0, 1, 2], Vec3(0, 0, 0), Vec3(0, 0, 1), -1,
                           cast(float)(PI / 2), fal, kernelAim(),
                           cp, noAxes(), sym, proc);

    // Vertex 0 has a valid cluster: it turns about (50,0,0).
    assert(fabs(m.vertices[0].x - 50.0f) < 1e-4f
        && fabs(m.vertices[0].y - (-49.0f)) < 1e-4f,
           "a vertex with a valid cluster id rotates about ITS cluster centre");
    // Vertices 1 and 2 fall back to the global pivot at the origin.
    foreach (vi; 1 .. 3)
        assert(fabs(m.vertices[vi].x) < 1e-5f && fabs(m.vertices[vi].y - 1.0f) < 1e-5f,
               "an out-of-range or absent cluster id falls back to the GLOBAL "
               ~ "pivot — it is not clamped to cluster 0 and it is not skipped");
}
