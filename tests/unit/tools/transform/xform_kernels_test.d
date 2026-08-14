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
