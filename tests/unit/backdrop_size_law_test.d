// Frozen-fixture cell for the reference's BACKDROP / reference-image item size
// law (task 0612 Phase 0, promoted to a fixture 2026-08-20 as task 1631).
//
// WHY IT EXISTS. Until 2026-08-20 this law had no toolcard, no fixture and no
// test. It lived in one evidence .txt and a paragraph of an agent's memory --
// for an item type we ship, and after it had already overturned THREE separate
// candidates in the design plan that produced it. Re-deriving it needs a live
// GUI, a calibrated ortho viewport and 28 screenshot measurements.
//
// WHAT IT PINS. The reference law and the 28 measured rows behind it. The law
// is implemented below from the fixture's own `law` block and shares no code
// with the generator that wrote the fixture, so the cell reddens from both
// sides: edit a row and the row check fails; edit the law and every row fails.
//
// WHAT IT DOES NOT PIN. It does not call `computeImagePlane`. Our own
// `source/image_plane.d` implements this same formula -- `min(su, sv)` under
// keep-aspect, the image HEIGHT on both axes with it off -- and NO test
// anywhere asserts its extent numbers. Wiring that function to these 28 rows
// is the obvious next cell and is written up in the backlog card; it needs the
// full test binary because `image_plane` transitively needs the GL binding,
// which is why it is not done here.
module tests.unit.backdrop_size_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, fmin;
import std.format : format;

private enum string kFixture = "tests/fixtures/backdrop_size_law.json";

private double asDouble(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(readText(kFixture)); loaded = true; }
    return cached;
}

// ---------------------------------------------------------------------------
// The law, implemented from the fixture's `law` block and nothing else.
//
//   base, uniform=0, aspect=1 (DEFAULT) : (W*p, H*p)
//   base, uniform=0, aspect=0           : (H*p, H*p)   -- HEIGHT on BOTH axes
//   base, uniform=1, aspect=1           : (W/H, 1.0)
//   base, uniform=1, aspect=0           : (1.0, 1.0)
//   aspect=1 : extent = base * min(sx, sy)             -- ONE scalar
//   aspect=0 : extent = (base_u*sx, base_v*sy)
//   sz never enters.
// ---------------------------------------------------------------------------
private struct Extent { double u, v; }

private Extent backdropExtent(int W, int H, double p,
                              double sx, double sy,
                              int aspect, int uniform)
{
    double bu, bv;
    if (uniform == 0) {
        bu = (aspect == 1) ? W * p : H * p;
        bv = H * p;
    } else {
        bu = (aspect == 1) ? cast(double) W / cast(double) H : 1.0;
        bv = 1.0;
    }
    if (aspect == 1) {
        immutable double m = fmin(sx, sy);
        return Extent(bu * m, bv * m);
    }
    return Extent(bu * sx, bv * sy);
}

// ---------------------------------------------------------------------------
// 1. Provenance. This one IS a live reference capture and must stay labelled
//    as such -- unlike the analytic falloff-bake fixture next door.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    assert("provenance" in fx, kFixture ~ ": no provenance block");
    auto p = fx["provenance"];
    assert(p["source"].str == "live-capture",
        kFixture ~ ": provenance.source must stay 'live-capture' -- these are "
        ~ "measured screenshot rows, not a computed table");
    assert(p["method"].str == "self-drive", kFixture ~ ": provenance.method");
    assert("px_per_metre" in fx["instrument"]
        && asDouble(fx["instrument"]["px_per_metre"]) == 32.0,
        kFixture ~ ": the instrument calibration is what turns pixels into metres; "
        ~ "it was MEASURED (a 1 m quad moved 10 m -> 320.00 px), not assumed");
}

// ---------------------------------------------------------------------------
// 2. Every row: the law reproduces the recorded prediction exactly, and the
//    MEASURED pixels are within the stated rasterisation tolerance of it.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    immutable double tolPx  = asDouble(fx["tolerance"]["residual_px"]);
    immutable double pxPerM = asDouble(fx["instrument"]["px_per_metre"]);
    auto cases = fx["cases"].array;
    assert(cases.length == 28,
        format("%s: expected 28 measured rows, found %d -- a row was dropped",
               kFixture, cases.length));

    double worst = 0.0;
    foreach (c; cases) {
        immutable string nm = c["case"].str;
        immutable int W = cast(int) c["clip_px"].array[0].integer;
        immutable int H = cast(int) c["clip_px"].array[1].integer;
        immutable double p  = asDouble(c["pixel_size"]);
        immutable double sx = asDouble(c["scale"].array[0]);
        immutable double sy = asDouble(c["scale"].array[1]);
        immutable int asp = cast(int) c["aspect"].integer;
        immutable int uni = cast(int) c["uniform"].integer;

        auto got = backdropExtent(W, H, p, sx, sy, asp, uni);
        immutable double wantU = asDouble(c["law_m"].array[0]);
        immutable double wantV = asDouble(c["law_m"].array[1]);
        assert(abs(got.u - wantU) < 1e-9 && abs(got.v - wantV) < 1e-9,
            format("%s: case %s law_m = (%.10g, %.10g), the law gives (%.10g, %.10g)",
                   kFixture, nm, wantU, wantV, got.u, got.v));

        immutable double du = abs(got.u - asDouble(c["measured_m"].array[0])) * pxPerM;
        immutable double dv = abs(got.v - asDouble(c["measured_m"].array[1])) * pxPerM;
        assert(du <= tolPx + 1e-9 && dv <= tolPx + 1e-9,
            format("%s: case %s measures %.4f/%.4f px from the law, tolerance is %.2f px",
                   kFixture, nm, du, dv, tolPx));
        if (du > worst) worst = du;
        if (dv > worst) worst = dv;
    }
    assert(abs(worst - tolPx) < 1e-6,
        format("%s: the recorded tolerance %.4f px should be the worst residual "
               ~ "actually present (%.4f px) -- a looser number would hide drift",
               kFixture, tolPx, worst));
}

// ---------------------------------------------------------------------------
// 3. The cells that SEPARATE the law from the candidates it beat. A fixture
//    whose rows all agree with every candidate would prove nothing; each of
//    these pairs is a place where the rejected form predicts something else.
// ---------------------------------------------------------------------------
unittest {
    // Keep-aspect scale is ONE scalar, not per-axis: (3,1) and (1,3) both
    // collapse to min = 1 and reproduce the unscaled quad exactly.
    auto w1 = backdropExtent(512, 256, 0.01, 1, 1, 1, 0);
    auto w2 = backdropExtent(512, 256, 0.01, 3, 1, 1, 0);
    auto w3 = backdropExtent(512, 256, 0.01, 1, 3, 1, 0);
    assert(w1.u == w2.u && w1.v == w2.v && w1.u == w3.u && w1.v == w3.v,
        "keep-aspect must take min(sx,sy); a per-axis form would separate W1/W2/W3");
    assert(abs(w1.u - 5.12) < 1e-9 && abs(w1.v - 2.56) < 1e-9,
        "the reference's own documented worked example: 512 px at 10 mm -> 5.12 m");

    // min is symmetric in its two arguments.
    auto x1 = backdropExtent(512, 256, 0.01, 0.5, 4, 1, 0);
    auto x2 = backdropExtent(512, 256, 0.01, 4, 0.5, 1, 0);
    assert(x1.u == x2.u && x1.v == x2.v, "min(sx,sy) is symmetric; X1 and X2 must agree");

    // sz never enters.
    assert(backdropExtent(512, 256, 0.01, 1, 1, 1, 0).u == w1.u,
        "sz has no effect on the extent");

    // Keep-aspect OFF is square at the image HEIGHT, not the raw pixel dims.
    auto t2 = backdropExtent(256, 512, 0.01, 1, 1, 0, 0);
    assert(t2.u == t2.v && abs(t2.u - 5.12) < 1e-9,
        "aspect=0 makes the quad SQUARE at the image height (tall clip: 512*0.01)");
    auto w8 = backdropExtent(512, 256, 0.01, 1, 1, 0, 0);
    assert(w8.u == w8.v && abs(w8.u - 2.56) < 1e-9,
        "aspect=0 on a WIDE clip is also square, at the height -- not at the width");

    // The uniform metre mode.
    auto r0 = backdropExtent(512, 256, 0.01, 1, 1, 0, 1);
    assert(r0.u == 1.0 && r0.v == 1.0, "uniform=1, aspect=0 is a unit metre quad");
    auto w6 = backdropExtent(512, 256, 0.01, 3, 2, 1, 1);
    assert(abs(w6.u - 4.0) < 1e-9 && abs(w6.v - 2.0) < 1e-9,
        "uniform=1, aspect=1 is (W/H, 1) scaled by min(sx,sy)");
}

// ---------------------------------------------------------------------------
// 4. The rejected candidates are recorded with the cell that killed each one,
//    and the dead instrument is recorded so it is not retried.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    auto rej = fx["rejected_candidates"].array;
    assert(rej.length == 3, kFixture ~ ": three candidates were refuted by this capture");
    foreach (r; rej) {
        assert("cell" in r && r["cell"].str.length > 20,
            format("%s: rejected candidate '%s' has no cell recorded -- a refutation "
                   ~ "without the cell that produced it is not evidence",
                   kFixture, r["candidate"].str));
        assert(r["verdict"].str == "REFUTED", kFixture ~ ": verdict");
    }
    assert("dead_instrument_do_not_retry" in fx,
        kFixture ~ ": the dead accessor note is load-bearing -- it is 40+ reads' worth "
        ~ "of a channel that silently returns a constant");
}
