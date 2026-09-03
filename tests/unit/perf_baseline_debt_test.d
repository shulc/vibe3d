// THE DEBT LEDGER'S LAW — the corpus that SEPARATES the law we adopted from
// the one we rejected (task 1460, Phase 2).
//
// The ledger (`tools/perf/baseline_debt.json`, read by `lib.baseline`) exists
// because `tools/perf/baseline.json` is honest and the tree is measurably
// slower than it. Phase 0 checked out the commit that wrote the baseline,
// built it identically and ran it on this host: the old code reproduced its
// own baseline at median ratio 1.02 with ONE absolute regression, against 19
// on today's main. So the loss is in our code, re-recording the baseline would
// freeze it as the new normal, and the ledger pins each known-red case at
// what it measures TODAY instead.
//
// A ledger rots. An entry that outlives its regression re-admits the loss for
// free, so the comparison runs in both directions — and the LOW edge is where
// the two candidate laws differ:
//
//   REJECTED  low edge: `cur <= baselineUs*(1+tol)`  ("back inside the budget")
//   ADOPTED   low edge: `cur <  debtUs*(1-k)` AND `cur <= baselineUs*(1+tol)`,
//                       and RED only after N consecutive runs
//
// With a single shared `tol` the rejected law's green band is the open
// interval `(base*(1+tol), debt*(1+tol)]`, of ratio width exactly `debt/base`.
// Every entry whose `debt/base <= 1+tol` is therefore RED ON BOTH CLAUSES at
// the very value it was pinned at. That is not a corner case — computed over
// the ledger as originally seeded (2026-08-19, 3-run medians), it was **11 of
// the 37 ledgered entries**. The adopted law's green band is 1.4444x wide for
// every one of them, and every pin sits inside its own band — the block below
// that walks a `Row[]` of real ledger rows computes both laws' edges and
// asserts exactly that difference.
//
// EVERY assertion here is mutation-checked — see the task file's Мутация
// section. The four that matter:
//   M-a   delete the low edge from `judge`             ⇒ (g) must redden
//   M-a2  delete the STREAK clause                     ⇒ (f) must redden
//   M-b   restore the rejected low edge                ⇒ (e) must redden
//   M-c1  gut `reconcileDebt`                          ⇒ (i) must redden
// (The plan's M-c — "delete the `reconcileDebt` CALL from run.d" — cannot
// redden anything here and is not a unit mutation at all: this file calls
// `reconcileDebt` directly and `dub test --config=tests` never compiles
// run.d. Deleting the call is a HARNESS mutation, witnessed by an `ops` run
// over a deliberately orphaned ledger.)
// A mutation that does not redden means the assertion is inert.
//
// WHY NOT A CASE WITH `debt/base > 1.30`. Such a case is green under BOTH
// laws, so a corpus made only of those separates nothing — the same shape as
// the cube in `facing_predicate_test.d`. `move/baseline` (1.3486) is here to
// have that uselessness ASSERTED rather than left as advice.
module tests.unit.perf_baseline_debt_test;

import std.algorithm : canFind;
import std.format : format;
import std.math   : isNaN;

import lib.baseline : BaselineCase, Baseline, DebtEntry, Debt, DebtVerdict,
                      judge, debtImproved, reconcileDebt, debtTolFor,
                      DEBT_IMPROVED_K, DEBT_IMPROVED_STREAK_N,
                      ABS_NOISE_FLOOR_US;

// The run's global tolerance (`double tolerance = 0.30` in run.d's main).
private enum double TOL = 0.30;

// ---------------------------------------------------------------------------
// Fixtures — REAL measured numbers, not invented ones. `baselineUs` is the
// case's row in the committed 2026-06-07 `tools/perf/baseline.json`; `debtUs`
// is what the same case measures on this tree.
// ---------------------------------------------------------------------------

private BaselineCase baseRow(string name, double us) {
    BaselineCase b;
    b.name = name;
    b.kernelMedianUs = us;
    b.kernelP95Us    = us * 1.1;
    b.pipeMedianUs   = us * 1.2;
    b.dominantStage  = "kernelApply";
    b.vertsTouched   = 2_009_780;
    return b;
}

private DebtEntry entry(string key, double baseUs, double debtUs) {
    DebtEntry e;
    e.key        = key;
    e.baselineUs = baseUs;
    e.debtUs     = debtUs;
    e.ratio      = isNaN(baseUs) ? double.nan : debtUs / baseUs;
    e.samples    = 3;
    e.spreadLoUs = debtUs * 0.99;
    e.spreadHiUs = debtUs * 1.01;
    e.owner      = "xform-drift";
    e.ledgered   = true;
    return e;
}

// Every pair below is a REAL row of the ledger's 2026-08-19 seed (median of
// three full-matrix runs at n=316), joined to its row in the committed
// 2026-06-07 tools/perf/baseline.json. Paid rows may leave the live JSON; their
// measured numbers stay here when they distinguish the law from its rival.

// `scale/symmetry=X` — ratio 1.2932. Under the REJECTED law its pin is 0.52%
// BELOW the `debtPaid` line, i.e. red at the value it was pinned at.
private enum double SYMX_BASE = 20303.1;
private enum double SYMX_DEBT = 26256.0;

// `scale/falloff=linear` — ratio 1.2616, off the 1.30 boundary by 2.9% so the
// discrimination is not a rounding argument.
private enum double FLIN_BASE = 26451.6;
private enum double FLIN_DEBT = 33371.4;

// `move/baseline` — ratio 1.3486, a case that is green under BOTH laws and
// therefore separates nothing. It is here to be asserted useless.
private enum double MOVE_BASE = 13791.2;
private enum double MOVE_DEBT = 18598.3;

// The rejected law, spelled out here in this file's own arithmetic so an
// assertion can name it instead of alluding to it.
private bool rejectedLawSaysPaid(double baseUs, double curUs) {
    return curUs <= baseUs * (1.0 + TOL);
}

// ---------------------------------------------------------------------------
// (a) + (b) — no ledger entry: today's rule, unchanged.
// ---------------------------------------------------------------------------
unittest {
    auto b = baseRow("move/baseline", MOVE_BASE);

    // (a) within tolerance ⇒ ok
    auto v = judge(&b, null, MOVE_BASE * 1.20, TOL, []);
    assert(v.ok, "a: +20% against a +30% tolerance must pass");
    assert(!v.regressedVsBaseline);

    // (b) over ⇒ red against the BASELINE (not against a debt: there is none)
    v = judge(&b, null, MOVE_BASE * 1.40, TOL, []);
    assert(!v.ok, "b: +40% against a +30% tolerance must fail");
    assert(v.regressedVsBaseline, "b: the finding names the baseline");
    assert(!v.regressedVsDebt);
    assert(v.detail.canFind("baseline"));

    // The noise floor still applies where there is no entry: a 0.3 µs case
    // growing 15x is timer granularity, not a regression.
    auto tiny = baseRow("move/selection=single", 0.3);
    assert(tiny.kernelMedianUs < ABS_NOISE_FLOOR_US);
    assert(judge(&tiny, null, 4.4, TOL, []).ok,
           "a case under the noise floor and with no entry is not compared");
}

// ---------------------------------------------------------------------------
// (c) — an entry at exactly its pinned value is GREEN. This is the property
// the whole ledger rests on, and the rejected law loses it for any entry whose
// ratio is under 1+tol.
// ---------------------------------------------------------------------------
unittest {
    auto b = baseRow("move/baseline", MOVE_BASE);
    auto e = entry("move/baseline", MOVE_BASE, MOVE_DEBT);
    auto v = judge(&b, &e, MOVE_DEBT, TOL, []);
    assert(v.ok, "c: an entry measured at its own pin must be green");
    assert(v.streak == 0, "c: at the pin, nothing is in the improved region");
}

// ---------------------------------------------------------------------------
// (d) — 20% over the pin ⇒ red, and the finding names the DEBT, not the
// baseline. This is the direction the ledger exists to keep gating: the old
// loss is written down, a NEW loss on top of it is still caught.
// ---------------------------------------------------------------------------
unittest {
    auto b = baseRow("move/baseline", MOVE_BASE);
    auto e = entry("move/baseline", MOVE_BASE, MOVE_DEBT);

    // +20% over the pin is inside the +30% tolerance ⇒ still green...
    assert(judge(&b, &e, MOVE_DEBT * 1.20, TOL, []).ok);
    // ...+40% is not.
    auto v = judge(&b, &e, MOVE_DEBT * 1.40, TOL, []);
    assert(!v.ok, "d: 40% over the pin must fail");
    assert(v.regressedVsDebt, "d: the finding names the debt");
    assert(!v.regressedVsBaseline);
    assert(v.detail.canFind("debt"));

    // A per-entry `tol` overrides the global one — that is how a case whose
    // own reproduction spread is wider than 30% could ever be gated at all.
    auto wide = e;
    wide.tol = 0.60;
    assert(debtTolFor(&wide, TOL) == 0.60);
    assert(judge(&b, &wide, MOVE_DEBT * 1.40, TOL, []).ok,
           "d: the per-entry tolerance is what the high edge uses");
}

// ---------------------------------------------------------------------------
// (e) THE DISCRIMINATOR. `move/symmetry=X`, ratio 1.292, measured at exactly
// its pin, asserted GREEN.
//
// Under the ADOPTED law: green (it is at the pin).
// Under the REJECTED law: RED — `26147.8 <= 20238.7*1.30 = 26310.3` is true,
// so it reads as "debt paid, delete this entry" at the value it was just
// pinned at, 0.62% below the line.
//
// This is the ONLY case in the corpus that separates the two laws by verdict.
// Mutation M-b (restore the rejected low edge) must turn exactly this
// assertion red.
// ---------------------------------------------------------------------------
unittest {
    // First: assert the rejected law really does fire here, in this file's own
    // arithmetic. Without this the case below is just another green row.
    assert(rejectedLawSaysPaid(SYMX_BASE, SYMX_DEBT),
           format("e: the rejected law must call %.1f 'paid' against a %.1f "
                  ~ "baseline (line = %.1f) — otherwise this case separates "
                  ~ "nothing", SYMX_DEBT, SYMX_BASE, SYMX_BASE * (1.0 + TOL)));

    auto b = baseRow("scale/symmetry=X", SYMX_BASE);
    auto e = entry("scale/symmetry=X", SYMX_BASE, SYMX_DEBT);
    auto v = judge(&b, &e, SYMX_DEBT, TOL, []);
    assert(v.ok, "e: ratio 1.2932 at its own pin must be GREEN");
    assert(!v.improvedNotice && !v.improvedRed,
           "e: the pinned value is not an improvement");

    // Second row, off the 1.30 boundary so the discrimination is not a
    // rounding argument: `move/falloff=linear`, ratio 1.241, 4.55% below the
    // rejected law's line.
    assert(rejectedLawSaysPaid(FLIN_BASE, FLIN_DEBT));
    auto b2 = baseRow("scale/falloff=linear", FLIN_BASE);
    auto e2 = entry("scale/falloff=linear", FLIN_BASE, FLIN_DEBT);
    assert(judge(&b2, &e2, FLIN_DEBT, TOL, []).ok,
           "e: ratio 1.2616 at its own pin must be GREEN");
}

// The corpus's own uselessness check: a case with ratio > 1+tol is green under
// BOTH laws, so a corpus made of those cannot tell them apart. Stated as an
// assertion rather than as prose, the way facing_predicate_test.d asserts that
// a cube proves nothing.
unittest {
    assert(!rejectedLawSaysPaid(MOVE_BASE, MOVE_DEBT),
           "move/baseline (ratio 1.3486) is green under the rejected law too — "
           ~ "it cannot be the discriminator, which is why (e) exists");
    auto b = baseRow("move/baseline", MOVE_BASE);
    auto e = entry("move/baseline", MOVE_BASE, MOVE_DEBT);
    assert(judge(&b, &e, MOVE_DEBT, TOL, []).ok);
}

// The band arithmetic, computed rather than asserted from memory: the adopted
// law's green band is 1.44x wide for EVERY entry, and the rejected law's
// EXCLUDES the pin for every entry with ratio <= 1.30.
unittest {
    static struct Row { string name; double base, debt; }
    immutable Row[] rows = [
        Row("scale/symmetry=X",       SYMX_BASE, SYMX_DEBT),   // 1.2932
        Row("scale/falloff=linear",   FLIN_BASE, FLIN_DEBT),   // 1.2616
        Row("scale/falloff=cylinder", 36454.8,   47212.9),     // 1.2951
        Row("move/baseline",          MOVE_BASE, MOVE_DEBT),   // 1.3486
        Row("delete/edges/whole",     63035.7,  112798.2),     // 1.7894
    ];
    foreach (r; rows) {
        // Adopted law. Green is `[lo, hi]` where the notice needs BOTH
        // `cur < debt*(1-k)` and `cur <= base*(1+tol)`, so the effective low
        // edge is the SMALLER of the two lines.
        immutable double hi = r.debt * (1.0 + TOL);
        immutable double loDebt = r.debt * (1.0 - DEBT_IMPROVED_K);
        immutable double loBase = r.base * (1.0 + TOL);
        immutable double lo = loDebt < loBase ? loDebt : loBase;
        assert(hi / lo >= 1.44,
               format("%s: adopted green band %.3fx is too narrow",
                      r.name, hi / lo));
        assert(r.debt >= lo && r.debt <= hi,
               format("%s: the pin must sit inside the adopted band", r.name));

        // Rejected law. Green is the open interval `(base*(1+tol), hi]`, of
        // ratio width exactly debt/base.
        immutable double ratio = r.debt / r.base;
        immutable bool pinIsGreenUnderRejected = r.debt > loBase;
        assert(pinIsGreenUnderRejected == (ratio > 1.0 + TOL),
               format("%s: the rejected law's band excludes the pin exactly "
                      ~ "when ratio %.3f <= %.2f", r.name, ratio, 1.0 + TOL));
    }
}

// ---------------------------------------------------------------------------
// (g) then (f) — the streak, asserted in THAT order on purpose. (g) is the
// clause that DELETES an entry, so it is the one a mutation has to be able to
// reach: an assertion order that guards (g) behind (f)'s preconditions would
// let M-a die on a fixture check instead of on the law.
//
//   M-a  delete the low edge entirely   ⇒ (g) must redden (nothing is ever
//                                          "paid", so an entry never expires)
//   M-a2 delete the STREAK clause       ⇒ (f) must redden (one lucky night
//                                          deletes the entry)
// ---------------------------------------------------------------------------
unittest {
    auto b = baseRow("scale/symmetry=X", SYMX_BASE);
    auto e = entry("scale/symmetry=X", SYMX_BASE, SYMX_DEBT);
    immutable double paid = SYMX_DEBT * 0.85;   // 15% under the pin
    assert(DEBT_IMPROVED_STREAK_N == 3);

    // (g) the current run plus two prior ones, all under the line ⇒ RED, with
    //     a message that says what to do about it.
    auto v = judge(&b, &e, paid, TOL, [paid, paid]);
    assert(!v.ok, "g: three consecutive runs under the line must be red");
    assert(v.improvedRed);
    assert(v.streak == 3);
    assert(v.detail.canFind("DELETE"), "g: the finding must say what to do");

    // (f) two of the three ⇒ a NOTICE, not red. A `debtPaid` verdict deletes
    //     an entry and therefore legalises everything under it; one night is
    //     not enough evidence for that.
    v = judge(&b, &e, paid, TOL, [paid]);
    assert(v.ok, "f: two consecutive runs under the line must not be red");
    assert(v.improvedNotice, "f: it must still be reported");
    assert(!v.improvedRed);
    assert(v.streak == 2, format("f: streak was %d", v.streak));

    // and with NO prior rows at all, one night is a bare notice.
    v = judge(&b, &e, paid, TOL, []);
    assert(v.ok && v.improvedNotice && v.streak == 1);

    // A run that was NOT under the line breaks the streak, wherever it sits.
    v = judge(&b, &e, paid, TOL, [SYMX_DEBT, paid]);
    assert(v.ok && v.improvedNotice && v.streak == 1,
           "the streak is CONSECUTIVE — an intervening normal run resets it");

    // The fixture itself, asserted LAST so a mutation to the law reddens the
    // law's own case above rather than dying here.
    assert(debtImproved(e, paid, TOL), "the fixture must be in the region");
}

// ---------------------------------------------------------------------------
// (h) — the two halves of the low edge, each shown rejecting a DIFFERENT real
// scenario. h1 separates the two candidate laws a second time; h2 is the only
// case in the corpus that exercises the baseline conjunct at all.
// ---------------------------------------------------------------------------
unittest {
    // h1 — PARTIAL PAYMENT. This task's own first attribution target is worth
    // -8..-9% on `move/baseline`: paying drift window 2 alone lands at
    // ~17110 µs against a 13791.2 baseline and an 18598.3 pin.
    auto b = baseRow("move/baseline", MOVE_BASE);
    auto e = entry("move/baseline", MOVE_BASE, MOVE_DEBT);
    immutable double partial = 17110.0;   // -8% from the 18598.3 pin

    // The REJECTED law calls that paid on the spot and deletes the entry with
    // most of the loss still outstanding.
    assert(rejectedLawSaysPaid(MOVE_BASE, partial),
           "h1: the rejected law must delete this entry — otherwise the case "
           ~ "separates nothing");
    // The ADOPTED law does not: 17000 is ABOVE debt*(1-k) = 16612.8, so it is
    // not even in the improved region. (Note which half rejects it — the
    // debt-relative one. The plan for this task attributed the rejection to
    // the baseline conjunct; that is arithmetically wrong, and h2 below is
    // where the baseline conjunct actually earns its place.)
    assert(partial > MOVE_DEBT * (1.0 - DEBT_IMPROVED_K),
           "h1: -8% does not reach the -10% line");
    assert(!debtImproved(e, partial, TOL));
    auto v = judge(&b, &e, partial, TOL, [partial, partial, partial]);
    assert(v.ok, "h1: partial payment is green");
    assert(!v.improvedNotice && !v.improvedRed,
           "h1: partial payment is not even a notice, however many nights it "
           ~ "repeats");
    assert(v.streak == 0);

    // h2 — REAL BUT NOT ENOUGH, and the only case that exercises the baseline
    // conjunct. `delete/edges/whole`: base 63035.7, pinned at ~117712. At
    // 90000 µs it is 20% under its pin — a genuine improvement, well past the
    // -10% line — and still +43% over the baseline.
    immutable double D_BASE = 63035.7, D_DEBT = 112798.2, D_CUR = 90000.0;
    auto db = baseRow("delete/edges/whole", D_BASE);
    auto de = entry("delete/edges/whole", D_BASE, D_DEBT);
    assert(D_CUR < D_DEBT * (1.0 - DEBT_IMPROVED_K),
           "h2: the debt-relative half is SATISFIED here");
    assert(D_CUR > D_BASE * (1.0 + TOL),
           "h2: ...and the baseline conjunct is what rejects it");
    assert(!debtImproved(de, D_CUR, TOL));
    v = judge(&db, &de, D_CUR, TOL, [D_CUR, D_CUR]);
    assert(v.ok && !v.improvedRed && !v.improvedNotice,
           "h2: three nights of a 24% improvement must NOT delete this entry");

    // ...and here is why, stated as a consequence rather than as an opinion:
    // delete the entry and the very same number is RED against the baseline.
    auto after = judge(&db, null, D_CUR, TOL, []);
    assert(!after.ok && after.regressedVsBaseline,
           "h2: deleting the entry at this value would redden the lane the "
           ~ "next night — which is exactly why the conjunct keeps it");
}

// An entry with NO baseline term (a case added after the baseline was
// recorded) carries the HIGH edge only: with no baseline there is no "paid"
// to detect, and inventing one would delete the entry the first quiet night.
unittest {
    DebtEntry e;
    e.key        = "move/snap=vertex+partial";
    e.baselineUs = double.nan;
    e.debtUs     = 1000.0;
    e.owner      = "1350";
    e.ledgered   = true;

    assert(judge(null, &e, 1000.0, TOL, []).ok);
    assert(judge(null, &e, 1400.0, TOL, []).regressedVsDebt,
           "the high edge still gates without a baseline term");
    // ...and no amount of improvement is a notice.
    auto v = judge(null, &e, 1.0, TOL, [1.0, 1.0, 1.0]);
    assert(v.ok && !v.improvedNotice && !v.improvedRed,
           "an entry with no baseline term can never be 'paid'");
}

// `ledgered: false` records a case WITHOUT suppressing it — it still compares
// against the baseline exactly as if the entry were absent. This synthetic
// row isolates that policy from the separate question of which measured case
// currently needs it.
unittest {
    auto b = baseRow("remove/edges/whole", 62890.8);
    auto e = entry("remove/edges/whole", 62890.8, 117806.1);
    e.ledgered = false;

    auto v = judge(&b, &e, 117806.1, TOL, []);
    assert(!v.ok, "a non-ledgered entry does not suppress anything");
    assert(v.regressedVsBaseline, "it is still red against the BASELINE");
    assert(!v.regressedVsDebt);
}

// ---------------------------------------------------------------------------
// (i) — THE ORPHAN GUARD, driven through `reconcileDebt` and NOT through
// `judge`.
//
// `judge` is called from inside `checkAbsolute`'s loop over RESULTS, after
// `if (p is null) continue;`, so it only ever sees cases that exist in both
// the run and the baseline. An assertion for "this entry names a case that is
// gone" written through `judge` would pass forever whatever the code did —
// it is unreachable, not merely untested. It lives on a separate pass over the
// LEDGER's keys instead.
//
// Mutation M-c (delete the `reconcileDebt` call from run.d) must redden this.
// ---------------------------------------------------------------------------
unittest {
    Baseline base;
    base.byName["move/baseline"]    = baseRow("move/baseline", MOVE_BASE);
    base.byName["scale/symmetry=X"] = baseRow("scale/symmetry=X", SYMX_BASE);
    base.byName["rotate/loop@n64"]  = baseRow("rotate/loop@n64", 500.0);

    string[] runKeys = ["move/baseline", "scale/symmetry=X", "rotate/loop@n64"];

    // A ledger that matches reality reconciles clean.
    Debt clean;
    clean.byKey["move/baseline"] = entry("move/baseline", MOVE_BASE, MOVE_DEBT);
    assert(reconcileDebt(clean, base, runKeys).length == 0);

    // i.1 — an entry naming a case that is in neither the baseline nor the run.
    Debt gone;
    gone.byKey["move/thereIsNoSuchCase"] =
        entry("move/thereIsNoSuchCase", 100.0, 200.0);
    auto o = reconcileDebt(gone, base, runKeys);
    assert(o.length >= 1, "i.1: a ledger entry must not outlive its case");
    assert(o[0].key == "move/thereIsNoSuchCase");

    // i.2 — THE historyKey TRAP. The entry is keyed on the bare name while the
    // run (and the baseline) produce `name@n64`. Nothing about this is visible
    // to a comparison that only ever walks the RUN's keys: the entry simply
    // stops matching and goes on suppressing.
    Debt mistyped;
    mistyped.byKey["rotate/loop"] = entry("rotate/loop", 500.0, 900.0);
    o = reconcileDebt(mistyped, base, runKeys);
    assert(o.length >= 1, "i.2: a bare-name key against a pinned case is an "
                          ~ "orphan, not a match");
    assert(o[0].key == "rotate/loop");

    // i.3 — the entry's recorded baseline no longer agrees with baseline.json.
    // Either the ledger or the baseline moved; a suppression built on a number
    // that is no longer there is not a suppression of anything.
    Debt drifted;
    drifted.byKey["move/baseline"] = entry("move/baseline", MOVE_BASE * 1.10,
                                           MOVE_DEBT);
    o = reconcileDebt(drifted, base, ["move/baseline"]);
    assert(o.length == 1, "i.3: a baselineUs that disagrees with baseline.json");
    assert(o[0].reason.canFind("disagrees"));

    // i.4 — an entry that declares NO baseline while baseline.json has a row
    // for it: the case became comparable and the entry must be re-seeded.
    Debt stale;
    auto noBase = entry("move/baseline", double.nan, MOVE_DEBT);
    noBase.baselineUs = double.nan;
    stale.byKey["move/baseline"] = noBase;
    o = reconcileDebt(stale, base, ["move/baseline"]);
    assert(o.length == 1);
    assert(o[0].reason.canFind("baselineUs: null"));

    // i.5 — present in the baseline but the RUN produced no row for it. This
    // is the card's Hole 2 one level up: the case stopped measuring, and the
    // entry would go on suppressing a case that is no longer there.
    o = reconcileDebt(clean, base, ["scale/symmetry=X"]);
    assert(o.length == 1, "i.5: an entry whose case produced no row this run");
    assert(o[0].key == "move/baseline");
    assert(o[0].reason.canFind("no case in this run"));
}
