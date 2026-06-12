// test_falloff_combine.d — source-backed unit test for the multi-falloff
// WGHT combiner (Phase 2 of the multi-falloff plan).
//
// Two REAL FalloffStage instances are stacked into one Pipeline via
// `add` (primary) + `addStacked` (second). After `pipeline.evaluate`, the
// single published FalloffPacket must be a Composite carrying BOTH
// contributors in pipe order, and `evaluateFalloff` on that composite must
// equal the hand-computed Mix-Mode accumulation of the two sub-weights.
//
// Also pins the byte-stable single-falloff path: ONE active FalloffStage
// publishes its sub-packet DIRECTLY (no Composite), so existing
// single-falloff consumers see the verbatim packet.
//
// IMPORTANT: Pipeline.add / addStacked call plug() → Operator.reset(),
// which resets a FalloffStage's fields to defaults (type = None). So every
// stage is CONFIGURED AFTER it is registered, never before.
//
// Pure-D (no HTTP, no running vibe3d): compiled by run_test.d's
// `dmd -unittest` against the prebuilt project lib; the unittest blocks run
// before the empty main().

import std.math : isClose;

import math : Vec3, Viewport;
import toolpipe.pipeline : Pipeline;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, FalloffMix,
                          SubjectPacket;
import operator : VectorStack;
import falloff : evaluateFalloff;

void main() {}

// Configure a freshly-registered stage as a Linear-along-+Y falloff.
private void asLinearY(FalloffStage s) {
    s.type  = FalloffType.Linear;
    s.shape = FalloffShape.Linear;
    s.start = Vec3(0, 0, 0);
    s.end   = Vec3(0, 1, 0);
}

// Configure a freshly-registered stage as a Radial unit-sphere falloff.
private void asRadial(FalloffStage s, float sz) {
    s.type   = FalloffType.Radial;
    s.shape  = FalloffShape.Linear;
    s.center = Vec3(0, 0, 0);
    s.size   = Vec3(sz, sz, sz);
}

// ---------------------------------------------------------------------------
// Single active falloff → published packet is the lone sub-packet, NOT a
// Composite (byte-stable contract: one falloff behaves exactly as before).
// ---------------------------------------------------------------------------
unittest {
    Pipeline pipe;
    auto primary = new FalloffStage();          // id "falloff"
    pipe.add(primary);
    asLinearY(primary);                         // configure AFTER add()

    SubjectPacket subj;
    VectorStack vts;
    vts.put(&subj);
    pipe.evaluate(vts);

    auto pub = vts.get!FalloffPacket();
    assert(pub !is null, "a FalloffPacket must be published");
    assert(pub.type == FalloffType.Linear,
           "single falloff publishes its OWN type, not Composite");
    assert(pub.contributors.length == 0,
           "single falloff carries no contributors");

    Viewport vp;
    // Linear weight 0.75 at y=0.25 — same as the lone stage with no combiner.
    assert(isClose(evaluateFalloff(*pub, Vec3(0, 0.25f, 0), 0, vp), 0.75f));
}

// ---------------------------------------------------------------------------
// Two stacked falloffs → ONE Composite packet with both contributors in
// pipe order; evaluateFalloff on it equals the Mix-Mode accumulation.
// ---------------------------------------------------------------------------
unittest {
    Pipeline pipe;

    // Two radials along X give clean, distinct weights at x=0.5 with no
    // off-axis contamination: size-2 sphere → t=0.25 → 0.75 (primary),
    // size-1 sphere → t=0.5 → 0.5 (extra). (A Linear-along-Y + Radial mix
    // would couple x AND y into the radial distance, muddying the hand math.)
    auto primary = new FalloffStage();
    pipe.add(primary);
    asRadial(primary, 2.0f);                     // 0.75 at x=0.5
    primary.mix = FalloffMix.Multiply;           // first contributor's mix unused

    auto extra = new FalloffStage();
    pipe.addStacked(extra);
    asRadial(extra, 1.0f);                        // 0.5 at x=0.5
    extra.mix = FalloffMix.Subtract;

    SubjectPacket subj;
    VectorStack vts;
    vts.put(&subj);
    pipe.evaluate(vts);

    auto pub = vts.get!FalloffPacket();
    assert(pub !is null);
    assert(pub.type == FalloffType.Composite,
           "two stacked falloffs publish a Composite");
    assert(pub.contributors.length == 2,
           "composite carries both contributors");
    assert(pub.contributors[0].type == FalloffType.Radial,
           "primary is contributor[0] (pipe order)");
    assert(pub.contributors[1].type == FalloffType.Radial,
           "stacked extra is contributor[1]");
    assert(pub.contributors[1].mix == FalloffMix.Subtract,
           "each contributor carries its own mix");

    Viewport vp;
    // Sample x=0.5: primary→0.75, extra→0.5. Subtract: 0.75 - 0.5 = 0.25.
    Vec3 sample = Vec3(0.5f, 0, 0);
    assert(isClose(evaluateFalloff(*pub, sample, 0, vp), 0.25f),
           "composite weight = primary - extra = 0.25");

    // Flip the second contributor's mix to Multiply and re-evaluate —
    // 0.75 * 0.5 = 0.375. Proves the published mix drives the combine.
    extra.mix = FalloffMix.Multiply;
    VectorStack vts2;
    vts2.put(&subj);
    pipe.evaluate(vts2);
    auto pub2 = vts2.get!FalloffPacket();
    assert(pub2.type == FalloffType.Composite);
    assert(isClose(evaluateFalloff(*pub2, sample, 0, vp), 0.375f),
           "Multiply mix: 0.75 * 0.5 = 0.375");
}

// ---------------------------------------------------------------------------
// Three stacked falloffs → contributors FLAT (no nested Composite), in
// pipe order. Guards the flatten-on-build rule.
// ---------------------------------------------------------------------------
unittest {
    Pipeline pipe;

    auto a = new FalloffStage();
    pipe.add(a);
    asLinearY(a);

    auto b = new FalloffStage();
    pipe.addStacked(b);
    asRadial(b, 1.0f);
    b.mix = FalloffMix.Max;

    auto c = new FalloffStage();
    pipe.addStacked(c);
    asRadial(c, 2.0f);
    c.mix = FalloffMix.Min;

    SubjectPacket subj;
    VectorStack vts;
    vts.put(&subj);
    pipe.evaluate(vts);

    auto pub = vts.get!FalloffPacket();
    assert(pub.type == FalloffType.Composite);
    assert(pub.contributors.length == 3,
           "three stacked → three FLAT contributors (no nesting)");
    foreach (ct; pub.contributors)
        assert(ct.type != FalloffType.Composite,
               "contributors are never themselves Composite (flattened)");

    Viewport vp;
    // Sample x=0.5: Linear (y=0 → weight 1.0); Radial size1 → 0.5;
    // Radial size2 → 0.75. accum = 1.0; Max(1.0, 0.5)=1.0; Min(1.0, 0.75)=0.75.
    Vec3 sample = Vec3(0.5f, 0, 0);
    assert(isClose(evaluateFalloff(*pub, sample, 0, vp), 0.75f),
           "Max then Min fold: 0.75");
}
