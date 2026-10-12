// Frozen-fixture cell for the reference's SELECTION-falloff bake (task 0378,
// promoted to a fixture 2026-08-20 as task 1631).
//
// WHAT THIS PINS, AND WHAT IT DOES NOT.  This is the REFERENCE editor's law,
// read instruction by instruction out of its own named bake symbols.  It is
// NOT a parity assertion against vibe3d: our selection falloff is a different
// law on three separate counts (it expands the moving set, its smoothing pass
// count varies with `steps`, and it seeds hot instead of on the ring ramp).
// A green here therefore means "the frozen reference law is intact", never
// "we match it".  The fixture says so in `our_side_diverges`; closing that gap
// is a port task.
//
// WHY IT EXISTS.  Until 2026-08-20 this law lived only as prose in one agent's
// memory.  Its raw evidence -- the 5x5 and 7x7 lookup tables and the simulator
// that checked them -- was written to a scratch directory and is gone.  Four
// numbers from that capture survived in the prose, and all four are reproduced
// here by an independent implementation of the law; those four are what make
// the regenerated tables evidence rather than a self-consistent invention.
//
// HOW IT CAN GO RED.  `bakeSelection` below is written from the fixture's own
// `law` block and shares no code with the generator that produced the tables.
// So the cell reddens from BOTH sides: perturb a tabulated weight and the
// table check fails; change a law constant (the fixed 4 blur passes, the
// min(ring,S) seed cap, the self-excluded neighbour mean) and every case fails
// at once.  The `anchors` block is asserted separately so that a table edit
// which stays internally consistent still cannot pass.
module tests.unit.falloff_selection_bake_test;

import std.json;
import std.file   : readText;
import std.math   : abs, fmax;
import std.format : format;
import std.algorithm : min, max;

private enum string kFixture = "tests/fixtures/falloff_selection_bake.json";

// Every tabulated value is a dyadic rational with a small denominator, so it
// is exact in both float64 and float32.  The tolerance is a guard against a
// stray text round-trip, not a modelling allowance.
private enum double kEps = 1e-12;

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
//   domain    the selected n x n block only; it never expands
//   ring      4-connected graph distance from the selection border
//   seed      min(ring, S) / S,  S = max(steps, 1)
//   boundary  Dirichlet-0: a border vertex (ring 0) is pinned and never blurred
//   blur      exactly 4 Jacobi passes, independent of `steps`
//   stencil   uniform 1/valence mean of the 4 in-block neighbours, self excluded
// ---------------------------------------------------------------------------
private double[][] bakeSelection(int n, int steps,
                                 int blurPasses = 4,
                                 bool capSeed = true,
                                 bool unsetDeep = false)
{
    immutable int S = max(steps, 1);

    int ringOf(int i, int j) { return min(min(i, j), min(n - 1 - i, n - 1 - j)); }

    auto w = new double[][](n, n);
    foreach (i; 0 .. n) foreach (j; 0 .. n) {
        immutable int r = ringOf(i, j);
        if (r == 0)            w[i][j] = 0.0;                 // pinned border
        else if (unsetDeep)    w[i][j] = r <= S ? cast(double) r / S : 0.0;
        else if (capSeed)      w[i][j] = cast(double) min(r, S) / S;
        else                   w[i][j] = cast(double) r / S;
    }

    foreach (_; 0 .. blurPasses) {
        auto nw = new double[][](n, n);              // snapshot => Jacobi
        foreach (i; 0 .. n) foreach (j; 0 .. n) nw[i][j] = w[i][j];
        foreach (i; 0 .. n) foreach (j; 0 .. n) {
            if (ringOf(i, j) == 0) continue;         // pinned, never blurred
            nw[i][j] = (w[i-1][j] + w[i+1][j] + w[i][j-1] + w[i][j+1]) / 4.0;
        }
        w = nw;
    }
    return w;
}

private double maxDeviationOverBlock(int n, int steps,
                                     int blurPasses, bool capSeed, bool unsetDeep)
{
    auto a = bakeSelection(n, steps);
    auto b = bakeSelection(n, steps, blurPasses, capSeed, unsetDeep);
    double m = 0.0;
    foreach (i; 0 .. n) foreach (j; 0 .. n) m = fmax(m, abs(a[i][j] - b[i][j]));
    return m;
}

// ---------------------------------------------------------------------------
// 1. Provenance is present and honest.  This fixture is ANALYTIC by
//    construction -- the tables are computed from a statically read law -- and
//    must never be relabelled as reference parity.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    assert("provenance" in fx, kFixture ~ ": no provenance block");
    auto p = fx["provenance"];
    assert("source" in p && p["source"].str == "analytic",
        kFixture ~ ": provenance.source must stay 'analytic' -- the tables are "
                   ~ "computed from the law, not captured, and counting them as "
                   ~ "reference parity would be a lie about what was measured");
    assert("method" in p && p["method"].str == "closed-form",
        kFixture ~ ": provenance.method must stay 'closed-form'");
    assert("our_side_diverges" in fx,
        kFixture ~ ": the note that this is NOT a vibe3d parity assertion is "
                   ~ "load-bearing; do not drop it");
}

// ---------------------------------------------------------------------------
// 2. Every tabulated weight is what the law produces.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    size_t checked = 0;
    foreach (c; fx["cases"].array) {
        immutable int n     = cast(int) c["n"].integer;
        immutable int steps = cast(int) c["steps"].integer;
        assert(cast(int) c["S"].integer == max(steps, 1),
            format("%s: case n=%d steps=%d records S=%d, law says max(steps,1)=%d",
                   kFixture, n, steps, c["S"].integer, max(steps, 1)));

        auto want = c["weights"].array;
        assert(want.length == n, format("%s: n=%d steps=%d has %d rows",
                                        kFixture, n, steps, want.length));
        auto got = bakeSelection(n, steps);

        foreach (i; 0 .. n) {
            auto row = want[i].array;
            assert(row.length == n, format("%s: n=%d steps=%d row %d has %d entries",
                                           kFixture, n, steps, i, row.length));
            foreach (j; 0 .. n) {
                immutable double e = asDouble(row[j]);
                assert(abs(e - got[i][j]) <= kEps,
                    format("%s: n=%d steps=%d weights[%d][%d] = %.17g, "
                           ~ "the law gives %.17g", kFixture, n, steps, i, j, e, got[i][j]));
                ++checked;
            }
        }
        assert(abs(asDouble(c["centre"]) - got[n/2][n/2]) <= kEps,
            format("%s: n=%d steps=%d centre = %.17g, law gives %.17g",
                   kFixture, n, steps, asDouble(c["centre"]), got[n/2][n/2]));
    }
    assert(checked == 5*5*5 + 7*7*5,
        format("%s: expected 370 tabulated weights, checked %d -- a case was "
               ~ "dropped from the fixture", kFixture, checked));
}

// ---------------------------------------------------------------------------
// 3. Border vertices are pinned at exactly 0, and steps 0 and 1 coincide.
//    These are the two structural claims a numeric table alone would not make
//    obvious, and each has its own falsifier in the fixture.
// ---------------------------------------------------------------------------
unittest {
    foreach (n; [5, 7]) {
        auto w = bakeSelection(n, 2);
        foreach (k; 0 .. n) {
            assert(w[0][k]     == 0.0 && w[n-1][k] == 0.0, "border row not pinned to 0");
            assert(w[k][0]     == 0.0 && w[k][n-1] == 0.0, "border column not pinned to 0");
        }
        auto a = bakeSelection(n, 0), b = bakeSelection(n, 1);
        foreach (i; 0 .. n) foreach (j; 0 .. n)
            assert(abs(a[i][j] - b[i][j]) <= kEps,
                "S = max(steps,1) makes steps 0 and 1 identical; they differ");
    }
}

// ---------------------------------------------------------------------------
// 4. The four numbers recovered from the original capture.  These are the only
//    MEASURED values that survived, and they are what anchor the regenerated
//    tables to a real reading of the reference.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    auto anchors = fx["anchors_recovered_from_the_original_capture"].array;
    assert(anchors.length == 4, kFixture ~ ": expected 4 recovered anchors");

    immutable double lawCentre   = bakeSelection(7, 2)[3][3];
    immutable double uncapped    = bakeSelection(7, 2, 4, /*capSeed*/false)[3][3];
    immutable double unsetDeep   = bakeSelection(7, 2, 4, true, /*unsetDeep*/true)[3][3];
    immutable double devAt3      = maxDeviationOverBlock(7, 2, 3, true, false);
    immutable double devAt5      = maxDeviationOverBlock(7, 2, 5, true, false);

    assert(abs(asDouble(anchors[0]["value"]) - lawCentre) <= kEps,
        format("anchor 0: fixture %.17g vs law %.17g",
               asDouble(anchors[0]["value"]), lawCentre));
    assert(abs(lawCentre - 0.6796875) <= kEps,
        format("the surviving measured LUT centre is 0.6796875; law gives %.17g", lawCentre));
    assert(abs(asDouble(anchors[1]["value"]) - uncapped)  <= kEps, "anchor 1: uncapped seed");
    assert(abs(asDouble(anchors[2]["value"]) - unsetDeep) <= kEps, "anchor 2: unset-deep seed");
    assert(abs(devAt3 - devAt5) <= kEps && abs(asDouble(anchors[3]["value"]) - devAt3) <= kEps,
        format("anchor 3: 3 and 5 blur passes both deviate by %.17g / %.17g", devAt3, devAt5));
}

// ---------------------------------------------------------------------------
// 5. Each rejected candidate really is separated by this rig.  A candidate the
//    rig cannot tell apart from the law is not evidence, and recording one as
//    REFUTED would be exactly the mistake the edge.bevel 2^L reading made.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    immutable double lawCentre = bakeSelection(7, 2)[3][3];
    size_t withNumbers = 0;
    foreach (rc; fx["rejected_candidates"].array) {
        if ("7x7_steps2_centre" !in rc) continue;
        ++withNumbers;
        immutable double v = asDouble(rc["7x7_steps2_centre"]);
        assert(abs(v - lawCentre) > 1e-6,
            format("%s: rejected candidate '%s' predicts %.17g, the law predicts "
                   ~ "%.17g -- this rig cannot separate them, so it is not refuted here",
                   kFixture, rc["candidate"].str, v, lawCentre));
        assert(asDouble(rc["max_deviation_over_block"]) > 1e-6,
            format("%s: rejected candidate '%s' deviates by less than 1e-6 over the "
                   ~ "whole block", kFixture, rc["candidate"].str));
    }
    assert(withNumbers == 4,
        format("%s: expected 4 numerically separated rejected candidates, found %d",
               kFixture, withNumbers));
}
