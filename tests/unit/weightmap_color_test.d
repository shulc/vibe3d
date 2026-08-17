// Golden-fixture coverage for the weight-map display mode's colour law
// (task 1090). See doc/weightmap_display_plan.md §7.1.
//
// TIER 1 OF TWO. This file pins the LAW and cannot see whether the law reaches
// a pixel; `tests/test_weightmap_display.d` pins the plumbing and reads its
// expected bytes out of THIS SAME fixture, so the two tiers carry one set of
// measured numbers between them and cannot drift apart.
//
// WHAT IS ASSERTED, AND WHY IT IS NOT A TOLERANCE
// ----------------------------------------------
// The fixture's `rgb8` column is what a framebuffer held. Reproducing it needs
// the reference's float->byte conversion, which is `refQuantise` below and
// lives HERE, never in `source/` — the conversion is theirs; ours is GL's.
//
// Under that conversion 89 of the 93 measured channel-observations reproduce
// EXACTLY. The remaining ones are two named cells where the product lands
// within ~0.05 LSB ABOVE a rounding tie and the reference rounds down anyway.
// Those two are enumerated as a LIST, not swallowed by a +-1 band, and the
// list is asserted in BOTH directions: a third instance is a failure, and a
// listed instance that silently stops happening is a failure too. That is the
// entire difference between a registered divergence and a hidden one.
//
// THE PRECISION TRAP, WHICH IS NOT HYPOTHETICAL. The `* 255` must happen in
// float32. At w = +-0.3333333 the green product is EXACTLY 93.5 in float32
// (-> 93 under ties-toward-zero, which is what was measured) and 93.500005 in
// double (-> 94, a spurious failure). This cost the plan a whole review round:
// a double-precision derivation was read as evidence against the measured
// green constant. Every product below is bound to a `float` before it is
// compared, because D permits higher-precision intermediates and an unbound
// expression is not a guarantee.
module tests.unit.weightmap_color_test;

import std.json;
import std.file      : readText;
import std.math      : abs, floor, isNaN;
import std.format    : format;

import math            : Vec3;
import weightmap_view;

// ---------------------------------------------------------------------------
// Fixture plumbing
//
// `tests/fixture_helpers.d` is NOT importable from here — it lives outside
// `tests/unit`'s compiled source set (dub.json's `tests` configuration lists
// sourcePaths [source, tests/unit] only), the same constraint
// tests/unit/edge_crease_weight_test.d documents. So the provenance
// vocabulary check is repeated locally rather than dragging in the whole HTTP
// helper module.
// ---------------------------------------------------------------------------

private double asDouble(JSONValue v) {
    final switch (v.type) {
        case JSONType.float_:    return v.floating;
        case JSONType.integer:   return cast(double) v.integer;
        case JSONType.uinteger:  return cast(double) v.uinteger;
        case JSONType.string:    case JSONType.array:  case JSONType.object:
        case JSONType.true_:     case JSONType.false_: case JSONType.null_:
            assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private void checkProvenance(JSONValue fx) {
    assert("provenance" in fx,
        "weightmap_display fixture has no 'provenance' block");
    auto prov = fx["provenance"];
    static immutable string[] kSources = ["live-capture", "simulated",
                                          "analytic", "unknown"];
    static immutable string[] kMethods = ["capture-drag", "command", "from-trace",
                                          "rr-memory", "self-drive", "closed-form",
                                          "hand", "unknown"];
    bool oneOf(string v, const string[] allowed) {
        foreach (a; allowed) if (v == a) return true;
        return false;
    }
    assert("source" in prov && prov["source"].type == JSONType.string
        && oneOf(prov["source"].str, kSources),
        "weightmap_display fixture: provenance.source missing/invalid");
    assert("method" in prov && prov["method"].type == JSONType.string
        && oneOf(prov["method"].str, kMethods),
        "weightmap_display fixture: provenance.method missing/invalid");
}

// Hard assert on a missing file — no try/catch. A fixture test that quietly
// passes when its fixture is gone is the failure mode this rule exists for.
private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/weightmap_display/ramp.json"));
        checkProvenance(cached);
        loaded = true;
    }
    return cached;
}

// ---------------------------------------------------------------------------
// The reference's float -> byte conversion.
//
// NEAREST, with exact `.5` ties broken TOWARD ZERO. Pinned by the red channel
// of the frozen cells and by nothing else: w = 0 reads 127 from an exact
// 127.5, so ties go DOWN; w = 0.05 reads 134 from 133.875, so it is nearest
// and not truncation. Those two cells alone exclude truncation, half-up, and
// every x256 variant.
//
// It lives in this file on purpose. It describes what the REFERENCE's
// framebuffer did; our own conversion is the GL pipeline's and is not
// something `source/` gets to state. Putting it in `source/` would also be the
// first step toward "fixing" the two near-tie cells with a fitted constant.
// ---------------------------------------------------------------------------
private int refQuantise(float p) {
    assert(p >= 0.0f && p <= 255.0f,
        format("a colour channel left [0,255] before quantisation: %.6f", p));
    immutable float fl = floor(p);
    immutable float fr = p - fl;
    // `fr > 0.5f` strictly: an exact tie falls through to the floor, which IS
    // the measured behaviour. Writing `>=` here would silently reproduce
    // half-up and turn three measured cells red.
    return cast(int) fl + (fr > 0.5f ? 1 : 0);
}

private float channel(Vec3 v, int ch) {
    final switch (ch) {
        case 0: return v.x;
        case 1: return v.y;
        case 2: return v.z;
    }
}

private string channelName(int ch) {
    final switch (ch) {
        case 0: return "red";
        case 1: return "green";
        case 2: return "blue";
    }
}

// ---------------------------------------------------------------------------
// The registered divergence, as an ASSERTED LIST.
//
// Registry row R2. At products within ~0.05 LSB above a rounding tie the
// reference rounds DOWN where nearest-rounding goes up. Exactly two instances
// exist across all 93 measured channel-observations, and they are named here
// rather than covered by a blanket +-1:
//
//   * GREEN at w = 0.4257143 — predicted 80.5436 (-> 81), measured 80;
//   * BLUE  at w = 0.2114286 — predicted 100.5429 (-> 101), measured 100.
//
// The BLUE one is the control that decides the interpretation. Blue's neutral
// is 0.5, was never in dispute, and is exact on thirteen cells — yet it fails
// at its own thinnest margin (0.043 LSB) exactly as green does at its (0.044).
// Two channels, two DIFFERENT constants, one shared anomaly => the residual
// belongs to the float->byte conversion, not to the green constant.
//
// A single additive offset of about -0.05 LSB, shared by all three channels,
// admits all 93 observations. It is deliberately NOT in `source/`: the
// mechanism is unidentified, the offset is one fitted parameter, no single
// SCALE fits at all (red at w=0.2828571 needs S > 254.8998 while green at
// w=0.4257143 needs S <= 254.8621, so the residual is additive), and the
// sixteen ramp cells that would "confirm" it are a weak test because none of
// them sits near a tie. This list is what keeps the divergence visible instead
// of absorbed.
// ---------------------------------------------------------------------------
private struct NearTieMiss {
    double weight;
    int    channel;
    string note;
}

private immutable NearTieMiss[] kKnownNearTieMisses = [
    NearTieMiss(0.42571431398391724, 1,
        "green, product 80.5436, 0.0436 LSB above the tie"),
    NearTieMiss(0.21142859756946564, 2,
        "blue, product 100.5429, 0.0429 LSB above the tie — the CONTROL: "
        ~ "blue's neutral 0.5 was never in dispute"),
];

/// How close to a rounding tie a product must be for a 1-LSB miss to be
/// attributable to the conversion rather than to a wrong constant.
///
/// Both known instances sit at <= 0.0436. The CEILING on any discrimination in
/// this whole question is 0.125 LSB (the two candidate green neutrals differ
/// by 0.25*(1-t)), so 0.06 is comfortably above every real instance and
/// comfortably below anything that could hide a genuinely wrong constant.
///
/// WHAT THIS BAND DOES AND DOES NOT HOLD — measured, because the plan said
/// otherwise. The plan (§6, Stage 2, mutation 3) predicted that widening this
/// to 0.5 would "degenerate the rule into a blanket +-1" and stop the
/// wrong-constant mutation from reddening. It does NOT, and the reason is in
/// the plan's own §7.1 rule: the membership check against
/// `kKnownNearTieMisses` below is a SECOND, independent clause, and it catches
/// a wrong constant whatever this band is set to. Both were exercised:
///
///   * band widened to 0.5, law correct       -> GREEN (nothing to gate);
///   * band widened to 0.5, Ng = 140/255      -> RED, on the membership check;
///   * band tightened to 0.0, law correct     -> RED, on the two registered
///                                               instances (so it is live, not
///                                               an inert constant).
///
/// So the LOAD-BEARING guard is the named list; this band is what makes the
/// DIAGNOSIS right — with it, a wrong constant fails saying "a miss this far
/// from a tie is a wrong constant"; without it, the same wrong constant fails
/// saying "a NEW near-tie divergence", which is a true statement and a
/// misleading one. It is also the only clause that would catch a REGISTERED
/// cell whose miss stopped being a near-tie miss.
private enum float kNearTieLsb = 0.06f;

// ---------------------------------------------------------------------------
// The law against every frozen cell.
// ---------------------------------------------------------------------------

unittest {
    auto fx = fixture();
    auto cases = fx["cases"].array;
    assert(cases.length == 31,
        format("the fixture must carry BOTH frozen sets — 16 ramp cells and "
               ~ "15 uniform ones — got %d. The uniform cells are the only "
               ~ "ones that can see the green-neutral question; without them "
               ~ "the rejected constant passes every case in the file",
               cases.length));

    // Both sets must actually be present: a fixture rebuilt from the ramp
    // capture alone would have 31 cells only by coincidence, but this says so.
    size_t nRamp = 0, nUniform = 0, nDiscriminating = 0;
    foreach (c; cases) {
        immutable string set = c["set"].str;
        if (set == "ramp")    nRamp++;
        if (set == "uniform") nUniform++;
        if ("discriminating" in c && c["discriminating"].type == JSONType.true_)
            nDiscriminating++;
    }
    assert(nRamp == 16 && nUniform == 15,
        format("expected 16 ramp + 15 uniform cells, got %d + %d",
               nRamp, nUniform));
    assert(nDiscriminating == 12,
        format("the uniform set must still carry its twelve cells built to "
               ~ "separate the green neutral from its rival; got %d",
               nDiscriminating));

    bool[] sawMiss = new bool[](kKnownNearTieMisses.length);
    size_t exact = 0;

    foreach (ci, c; cases) {
        immutable double w   = asDouble(c["weight"]);
        auto            want = c["rgb8"].array;
        assert(want.length == 3, "a case's rgb8 must have three channels");

        immutable Vec3 rgb = weightSurfaceColor(cast(float) w);

        foreach (ch; 0 .. 3) {
            // BOUND TO A FLOAT. See this file's header: an unbound expression
            // may be evaluated in double and turns the exact-93.5 cells red.
            immutable float p = channel(rgb, ch) * 255.0f;
            immutable int   q = refQuantise(p);
            immutable int   m = cast(int) want[ch].integer;

            if (q == m) { exact++; continue; }

            // Everything below is the registered divergence, and every clause
            // has to hold — any one of them failing means this is a real
            // error wearing the divergence's clothes.
            assert(abs(q - m) == 1,
                format("case %d (w = %.10g), %s: computed %d, measured %d — "
                       ~ "off by %d. The registered divergence is ONE level; "
                       ~ "anything larger is a wrong law, not a rounding "
                       ~ "artefact", ci, w, channelName(ch), q, m, abs(q - m)));

            immutable float distToTie = abs((p - floor(p)) - 0.5f);
            assert(distToTie <= kNearTieLsb,
                format("case %d (w = %.10g), %s: computed %d, measured %d, "
                       ~ "product %.6f sits %.6f LSB from a rounding tie. The "
                       ~ "registered divergence only ever happens AT a tie; a "
                       ~ "miss this far from one is a wrong constant",
                       ci, w, channelName(ch), q, m, p, distToTie));

            bool known = false;
            foreach (ki, k; kKnownNearTieMisses) {
                if (k.channel != ch) continue;
                if (abs(k.weight - w) > 1e-9) continue;
                assert(!sawMiss[ki],
                    format("the same registered near-tie instance matched "
                           ~ "twice (%s) — the fixture has duplicate cells",
                           k.note));
                sawMiss[ki] = true;
                known = true;
                break;
            }
            assert(known,
                format("case %d (w = %.10g), %s: a NEW near-tie divergence "
                       ~ "(computed %d, measured %d, product %.6f). Two are "
                       ~ "registered and no more. A third means the law "
                       ~ "changed or the fixture grew a cell nobody looked "
                       ~ "at — do NOT add it to the list without deciding "
                       ~ "which", ci, w, channelName(ch), q, m, p));
        }
    }

    assert(exact == 93 - kKnownNearTieMisses.length,
        format("expected %d of 93 channel-observations to reproduce EXACTLY; "
               ~ "got %d. This is the number that makes the two registered "
               ~ "misses a divergence rather than a tolerance",
               93 - kKnownNearTieMisses.length, exact));

    foreach (ki, k; kKnownNearTieMisses)
        assert(sawMiss[ki],
            format("registered near-tie divergence no longer occurs: %s. That "
                   ~ "is not automatically good news — either the conversion "
                   ~ "was understood and the list should shrink, or a "
                   ~ "constant moved and the agreement is a coincidence. "
                   ~ "Decide, then edit the list", k.note));
}

// ---------------------------------------------------------------------------
// The fixture's `model` block and the module's constants must agree.
//
// Without this the fixture could state one neutral while `source/` shipped
// another, and every byte assertion above would still pass on whichever the
// code used. Mutation: edit `model.neutral_rgb` without editing
// `kWeightNeutralG`, or the reverse.
// ---------------------------------------------------------------------------

unittest {
    auto fx    = fixture();
    auto model = fx["model"];

    void agrees(string key, Vec3 got, string what) {
        auto want = model[key].array;
        assert(want.length == 3, "model." ~ key ~ " must have three channels");
        immutable float[3] g = [got.x, got.y, got.z];
        foreach (ch; 0 .. 3)
            assert(abs(g[ch] - asDouble(want[ch])) < 1e-6,
                format("model.%s channel %d says %.6f, the module computes "
                       ~ "%.6f for %s — the fixture and the shipped constant "
                       ~ "have drifted apart, and the byte assertions cannot "
                       ~ "see that because they only ever consult the module",
                       key, ch, asDouble(want[ch]), g[ch], what));
    }

    agrees("neutral_rgb",  weightSurfaceColor(0.0f),  "w = 0");
    agrees("positive_rgb", weightSurfaceColor(5.0f),  "a clamped positive weight");
    agrees("negative_rgb", weightSurfaceColor(-5.0f), "a clamped negative weight");

    // And the record itself, so a future edit that changes `kWeightRamp`
    // without changing `weightSurfaceColor` is caught too.
    agrees("neutral_rgb",  kWeightRamp.neutral,  "kWeightRamp.neutral");
    agrees("positive_rgb", kWeightRamp.positive, "kWeightRamp.positive");
    agrees("negative_rgb", kWeightRamp.negative, "kWeightRamp.negative");

    assert(kWeightRamp.neutral.y == kWeightNeutralG,
        "the ramp's green neutral must BE the named constant, not a copy of "
        ~ "its value");
}

// ---------------------------------------------------------------------------
// `rampT` — properties that survive a change to the blend factor's FORM.
// ---------------------------------------------------------------------------

unittest {
    // Monotone non-decreasing in |w|, and saturating at 1.
    float prev = -1.0f;
    foreach (i; 0 .. 401) {
        immutable float w = cast(float) i / 100.0f;   // 0 .. 4
        immutable float t = rampT(w);
        assert(t >= prev, format("rampT is not monotone at w = %.3f", w));
        assert(t <= 1.0f, format("rampT exceeded 1 at w = %.3f (%.6f)", w, t));
        assert(abs(rampT(-w) - t) < 1e-7f,
            format("rampT must depend on |w| only; disagrees at %.3f", w));
        prev = t;
    }
    assert(rampT(1.0f)  == 1.0f, "rampT saturates AT 1, not past it");
    assert(rampT(1.5f)  == 1.0f, "the clamp holds between the measured cells");
    assert(rampT(0.0f)  == 0.0f, "zero weight is the neutral");
    assert(rampT(1e30f) == 1.0f, "a huge weight is still clamped");

    // Non-finite lands on the NEUTRAL, which is a colour we have measured —
    // NOT on the magenta a static read reported and nobody has seen.
    assert(rampT(float.nan) == 0.0f, "NaN must land on the neutral");
    assert(weightSurfaceColor(float.nan) == kWeightRamp.neutral,
        "a non-finite weight renders the measured neutral");
    assert(!isNaN(weightSurfaceColor(float.nan).x),
        "a NaN must not survive into the vertex colour buffer");
    assert(weightSurfaceColor(float.infinity)  == kWeightRamp.positive,
        "+inf clamps to the positive extreme like any other large weight");
    assert(weightSurfaceColor(-float.infinity) == kWeightRamp.negative,
        "-inf clamps to the negative extreme");
}

// ---------------------------------------------------------------------------
// The clamp, stated as its own property.
//
// An implementation that interpolated the WEIGHT and let the framebuffer clip
// still reproduces every |w| >= 1 cell in the fixture, because the fixture's
// cells are all UNIFORM. What it does NOT reproduce is that the clamp happens
// before the colour exists — which is what makes 1.5 and 2.0 identical to 1.0
// as VALUES rather than as clipped outputs.
// ---------------------------------------------------------------------------

unittest {
    foreach (w; [1.0f, 1.5f, 2.0f, 17.0f])
        assert(weightSurfaceColor(w) == kWeightRamp.positive,
            format("w = %.1f must be exactly the positive extreme", w));
    foreach (w; [-1.0f, -1.5f, -2.0f, -17.0f])
        assert(weightSurfaceColor(w) == kWeightRamp.negative,
            format("w = %.1f must be exactly the negative extreme", w));

    // The sign boundary. Both branches meet at the neutral, so zero is not a
    // discontinuity — and -0.0f, which `w > 0` sends down the negative arm,
    // must land there too.
    assert(weightSurfaceColor(0.0f)  == kWeightRamp.neutral);
    assert(weightSurfaceColor(-0.0f) == kWeightRamp.neutral,
        "negative zero must render the neutral — the sign test is only "
        ~ "observable where t > 0");

    // Mirror symmetry: red and blue swap under a sign flip, green is shared.
    foreach (i; 1 .. 100) {
        immutable float w = cast(float) i / 100.0f;
        immutable Vec3 p = weightSurfaceColor(w);
        immutable Vec3 n = weightSurfaceColor(-w);
        assert(abs(p.x - n.z) < 1e-7f && abs(p.z - n.x) < 1e-7f
            && abs(p.y - n.y) < 1e-7f,
            format("the ramp must be an exact R<->B mirror at |w| = %.2f", w));
    }
}
