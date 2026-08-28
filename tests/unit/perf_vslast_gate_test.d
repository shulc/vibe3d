// The witness for the nightly perf gate's per-case band (task 2420 / card 2200).
//
// EVERY NUMBER IN THIS FILE IS MEASURED. Two sources, never mixed silently:
//
//  * rows copied out of this host's recorded run history,
//    `~/perf-history/fedora.jsonl`, identified by their UTC run timestamp. The
//    file is an oracle: it is read, never rewritten, and a row that would have
//    to change for a gate to pass is a gate that must change instead.
//  * a measurement taken for this task on 2026-08-28 — four consecutive `ops`
//    runs at ONE HEAD on a quiet host (load 0.6-1.2, no compilers, the perf
//    host lock held), `--n 316 --repeats 9`. Every use of it says so.
//
// WHAT THIS FILE HAS TO PROVE, and why a weaker file would be worthless. The
// card's finding is that ONE threshold cannot serve 90 cases whose noise spans
// two orders of magnitude, so the gate has to move in BOTH directions at once:
// tighter on the quiet majority, looser on the noisy handful. A test that only
// showed the new gate silent would be passed by a gate that reds on nothing; a
// test that only showed it reddening would be passed by the old one. So every
// block below carries the OLD gate's verdict on the same data as its control
// (`GateParams.flat` reproduces it exactly), and the blocks disagree with each
// other by design: some demand a red where the old gate was silent, others
// demand silence where the old gate was red.
//
// Blocks are split one claim per `unittest` on purpose: druntime aborts a
// module at its first failed assert, so a single block would only ever report
// its first broken claim (see the per-block attribution note in the agent
// memory for the measurement behind that).
module tests.unit.perf_vslast_gate_test;

import std.math : abs, isNaN;
import lib.vslast;

// --------------------------------------------------------------------------
// Fixtures: the five cases the card names as false reds, exactly as recorded.
// `prior` is that case's medians on the comparable, uncontaminated runs
// STRICTLY EARLIER than the judged one, oldest first — the judged value is
// never in it.
// --------------------------------------------------------------------------

private struct Recorded {
    string name;
    double prevUs, curUs;
    double runScale;          // that run's own common mode, median over its 90 keys
    double[] prior;
}

// 2026-08-27, three `ops` runs at n=316. Card 2200: all five crossed the old
// +20% threshold and came back with nothing touching them.
private Recorded[] fiveFalseReds() {
    return [
        // 10:19 run, common mode x1.0116
        Recorded("triple/polygons/whole", 114334.5, 145785.8, 1.0116,
                 [6037863.9, 168897.1, 152626.3, 142335.4, 134812.6,
                  163347.0, 130307.4, 135070.3, 114334.5]),
        Recorded("vertexExtrude/vertices/half", 336519.8, 441425.5, 1.0116,
                 [53821953.2, 354099.3, 364535.5, 370879.4, 378446.8,
                  383038.1, 369321.4, 360650.5, 391364.2, 336519.8]),
        // 11:14 run, common mode x1.0002
        Recorded("edgeExtend/edges/whole", 237221.3, 300736.5, 1.0002,
                 [13640461.0, 248682.2, 264255.3, 237077.8, 262111.7,
                  227838.5, 226514.5, 256538.5, 261747.3, 237221.3]),
        // 13:12 run, common mode x0.9794
        Recorded("remove/vertices/whole", 15768.7, 22322.1, 0.9794,
                 [14455.2, 14692.4, 14781.3, 14252.9, 14793.8, 14346.7,
                  14279.1, 14694.6, 16006.1, 16118.1, 16024.2, 15768.7]),
        Recorded("thicken/polygons/whole", 100992.8, 121327.5, 0.9794,
                 [7049906.5, 99036.8, 98934.9, 115064.3, 98050.8, 101759.4,
                  102103.8, 113316.1, 99824.4, 103317.3, 100992.8]),
    ];
}

private CaseObservation obsOf(const ref Recorded r) {
    CaseObservation o;
    o.name = r.name;
    o.prevUs = r.prevUs;
    o.curUs = r.curUs;
    o.priorSeries = r.prior;
    return o;
}

private Call callOf(const ref Recorded r, GateParams p) {
    auto o = obsOf(r);
    return judge(o, p.flat ? 1.0 : r.runScale, p).call;
}

// --------------------------------------------------------------------------

unittest { // CONTROL: the old gate really does red on all five. If this block
           // ever goes quiet, the sample stopped being the thing the card
           // described and every "now silent" claim below is vacuous.
    GateParams flatP;
    flatP.flat = true;
    foreach (ref r; fiveFalseReds())
        assert(callOf(r, flatP) == Call.regressed,
               "the pre-2420 flat +20% gate must red on " ~ r.name
               ~ " — this is the sample the rest of this file argues about");
}

unittest { // Three of the five go silent on the RECORDED rows, because each
           // case's own prior spread already covers the move. These are the
           // ones the card is right about AND the recorded history can prove.
    GateParams p;
    foreach (name; ["triple/polygons/whole", "edgeExtend/edges/whole",
                    "thicken/polygons/whole"]) {
        bool seen = false;
        foreach (ref r; fiveFalseReds()) {
            if (r.name != name) continue;
            seen = true;
            assert(callOf(r, p) == Call.clean,
                   "the per-case band must be silent on " ~ name
                   ~ ": its own recorded spread is wider than this move");
        }
        assert(seen, "fixture lost a case: " ~ name);
    }
}

unittest { // The two RESIDUALS, pinned as residuals and not swept up. On the
           // rows as recorded, `vertexExtrude` and `remove` stay red — and the
           // reason is not a mis-set constant, it is that those rows predate
           // the `#kernelP95Us` column, so the only arm that can see this kind
           // of noise has nothing to read. The next block proves that IS the
           // reason by supplying the column and watching them go quiet.
           //
           // They are asserted red rather than quietly tolerated because a
           // band wide enough to cover `remove` (+42% on a case whose recorded
           // between-run moves are all under 9%) is a band that covers a real
           // +42% regression too — which is the "too loose" half of the very
           // defect this task exists to fix.
    GateParams p;
    foreach (ref r; fiveFalseReds()) {
        if (r.name != "remove/vertices/whole"
         && r.name != "vertexExtrude/vertices/half") continue;
        assert(callOf(r, p) == Call.regressed,
               "expected " ~ r.name ~ " to remain a residual on rows that carry "
               ~ "no #kernelP95Us column");
    }
}

unittest { // WHAT THE COLUMN DOES AND DOES NOT BUY, measured rather than
           // hoped for. `remove/vertices/whole` was re-measured for this task
           // on 2026-08-28: four consecutive runs at ONE HEAD on a quiet host,
           // medians 20636.7 / 22511.7 / 17381.9 / 17611.0 — a 29.5% span with
           // nothing changed at all — and p95/median 1.2728 / 1.0912 / 1.3597
           // / 1.4299. So the card is right that this case swings enormously
           // on its own, and the `#kernelP95Us` column is the only thing in the
           // row that knows it.
           //
           // Its OWN consecutive steps must be silent...
    GateParams p;
    GateParams flatP; flatP.flat = true;
    static struct Step { double prev, cur, prevRatio, curRatio; }
    immutable Step[] measured = [
        Step(20636.7, 22511.7, 1.2728, 1.0912),   // +9.1%
        Step(17381.9, 17611.0, 1.3597, 1.4299),   // +1.3%
    ];
    foreach (ref st; measured) {
        CaseObservation o;
        o.name = "remove/vertices/whole";
        o.prevUs = st.prev; o.curUs = st.cur;
        o.prevP95Us = st.prev * st.prevRatio;
        o.curP95Us  = st.cur  * st.curRatio;
        auto v = judge(o, 1.0, p);
        assert(v.call == Call.clean,
               "a step this case produced with nothing changed must not red");
        assert(v.band.source == BandSource.sameNight,
               "and the band must come FROM its own sample spread — if the "
               ~ "floor or the historical arm decided it, this block is green "
               ~ "for a reason unrelated to the column it exists to test");
    }

    // ...and the RECORDED 2026-08-27 move is NOT silenced, even when this
    // case's widest measured spread (1.4299) is handed to it. 15768.7 ->
    // 22322.1 is +41.6%, and +44.6% once that run's own common mode (x0.9794,
    // the run was 2% faster overall) is divided out — outside even the worst
    // span this case's own repeats have ever produced. It is pinned RED, and
    // the pin is the honest end of this task rather than a gap in it: a band
    // wide enough to swallow it is a band that swallows a real +45% regression
    // in a case whose ordinary step is 9%, which is the "too loose" half of
    // the defect the card was written about. What the measurement changed is
    // the REASON — this is now a case sitting at the edge of a spread we have
    // measured, not an unexplained red.
    CaseObservation rec;
    rec.name = "remove/vertices/whole";
    rec.prevUs = 15768.7; rec.curUs = 22322.1;
    rec.prevP95Us = 15768.7 * 1.4299;
    rec.curP95Us  = 22322.1 * 1.4299;
    rec.priorSeries = [14455.2, 14692.4, 14781.3, 14252.9, 14793.8, 14346.7,
                       14279.1, 14694.6, 16006.1, 16118.1, 16024.2, 15768.7];
    auto v = judge(rec, 0.9794, p);
    assert(v.call == Call.regressed,
           "the recorded 2026-08-27 move stays outside even this case's own "
           ~ "widest measured spread");
    assert(v.band.pct > 40.0,
           "and the band it cleared must be the wide one, not the floor — "
           ~ "otherwise this red says nothing about the column");
    assert(judge(rec, 0.9794, flatP).call == Call.regressed,
           "the old gate reds here too, so nothing regressed by keeping it");
}

unittest { // THE HEADLINE WITNESS, both directions. A planted +10% regression
           // in a case whose measured noise is under 1% must red — and the old
           // gate must be SILENT on the same plant, which is the card's finding
           // stated as an executable fact: a real regression twenty times the
           // noise sailed straight through +20%.
           //
           // rotate/falloff=radial, recorded 2026-08-27 13:12 and the twelve
           // runs before it: 29642..30756 µs across TWENTY runs.
    immutable double[] prior = [29990.6, 29857.6, 30049.8, 30023.7, 30480.2,
                                30002.8, 30150.2, 30755.5, 30266.6, 30120.0,
                                30510.0, 30482.2];
    immutable double prev = 30482.2, clean = 30187.2, scale = 0.9794;

    CaseObservation o;
    o.name = "rotate/falloff=radial";
    o.prevUs = prev;
    o.priorSeries = prior;

    GateParams p;
    GateParams flatP; flatP.flat = true;

    o.curUs = clean;
    assert(judge(o, scale, p).call == Call.clean,
           "the unplanted run must stay green — a gate that reds here reds "
           ~ "every night on correct code");

    o.curUs = clean * 1.10;
    auto planted = judge(o, scale, p);
    assert(planted.call == Call.regressed,
           "a +10% regression in a case whose noise is under 1% MUST red");
    assert(planted.band.source == BandSource.floor,
           "and it must be the floor that catches it: this case's own spread "
           ~ "is far narrower, so a band that came from anywhere else would "
           ~ "mean the floor is not doing the work it is here to do");
    assert(judge(o, 1.0, flatP).call == Call.clean,
           "the pre-2420 gate is SILENT on the same plant — this is the hole "
           ~ "the task exists to close, and it must be visible in the test");
}

unittest { // The widened band is not a blanket: the same noisy case still reds
           // on a move bigger than its own measured spread. Without this, the
           // silence blocks above are satisfied by a gate that never fires.
    GateParams p;
    CaseObservation o;
    o.name = "remove/vertices/whole";
    o.prevUs = 20636.7;                 // 2026-08-28 run 1 median
    o.prevP95Us = 20636.7 * 1.2728;     // ... and its own p95
    o.curP95Us  = 20636.7 * 1.2728;
    o.curUs = 20636.7 * 1.60;
    assert(judge(o, 1.0, p).call == Call.regressed,
           "a +60% move is outside even this case's 27% sample spread and "
           ~ "must still red");
    o.curUs = 20636.7 * 1.09;           // the largest real consecutive step
    assert(judge(o, 1.0, p).call == Call.clean,
           "and its own measured step must not");
}

unittest { // ANTI-INERT: the gate did not go quiet on the real regressions in
           // the same history. The snap-query blow-up of 2026-08-26 (task 2040
           // dates it to the pre-fix tree) must still red, and by a mile.
    GateParams p;
    CaseObservation o;
    o.name = "move/snap=edge#snapQuery";
    o.prevUs = 11935.3;
    o.curUs  = 152803.8;                // +1180%
    o.priorSeries = [11388.9, 12021.6, 12233.1, 12309.4, 12493.8, 11935.3];
    auto v = judge(o, 1.0128, p);
    assert(v.call == Call.regressed, "the +1180% #snapQuery regression must red");
    assert(v.band.pct < 100.0,
           "and its band must still be a band — a case whose own history is "
           ~ "flat to a few percent may not inherit a hundred-percent licence");
}

unittest { // The run-level common mode is a TERM, and it discriminates.
           // 2026-08-14 -> 2026-08-18: the whole host got ~6% slower over four
           // days (median of 47 compared ratios = 1.0606). A case that moved
           // WITH the host is not a regression; a case that moved materially
           // further than the host is.
    immutable double hostScale = 1.0606;
    GateParams p;

    CaseObservation withHost;                    // move/baseline, +9.0%
    withHost.name = "move/baseline";
    withHost.prevUs = 16768.0; withHost.curUs = 18275.7;
    withHost.priorSeries = [17140.4, 17139.8, 16826.1, 17090.5, 16768.0];
    assert(judge(withHost, hostScale, p).call == Call.clean,
           "a case that moved with the host is not this gate's business");
    assert(judge(withHost, 1.0, p).call == Call.regressed,
           "and without the term it reds — so the term is load-bearing, not "
           ~ "decoration");

    CaseObservation beyond = withHost;           // the same case, +25% instead
    beyond.curUs = 16768.0 * 1.25;
    assert(judge(beyond, hostScale, p).call == Call.regressed,
           "a move well past the host's own shift must still red");
}

unittest { // The band cannot be widened by the value it is judging — the
           // property CLAUDE.md names as "the threshold is derived from the
           // measurement it is meant to judge", and the one task 1840's
           // K1_FALLOFF violated.
           //
           // THE FIXTURE IS BUILT TO BE ABLE TO FAIL, which took a second
           // attempt: the first one used a flat prior series, and a flat
           // series' spread is so far under the floor that folding the judged
           // value into it changed nothing — the check was green on the broken
           // code too, and only an isolated mutation run showed it. The moves
           // here are 1%, 2%, 3%, 4%, deliberately spread and deliberately
           // above the floor, so a fifth move folded in MOVES the median (from
           // the 2nd/3rd average to the 3rd) and the band with it.
    GateParams p;
    CaseObservation o;
    o.name = "graded/case";
    o.priorSeries = [1000.0, 1010.0, 1030.2, 1061.106, 1103.55024];
    o.prevUs = 1103.55024;

    o.curUs = 1103.55024;
    auto quiet = caseBand(o, p);
    o.curUs = 110_355.024;                      // a hundredfold "regression"
    auto loud = caseBand(o, p);
    assert(quiet.source == BandSource.spread && loud.source == BandSource.spread,
           "both must be decided by the spread arm, or this block compares two "
           ~ "floors and proves nothing");
    assert(quiet.widthLog == loud.widthLog,
           "the judged value must not appear in its own band");
    assert(judge(o, 1.0, p).call == Call.regressed,
           "and the hundredfold move is still called what it is");

    // The same property from the other side: how many prior moves a case HAS
    // is counted from the prior series alone. Four values are three moves,
    // below `minPriorMoves`, so this case has no band of its own — and folding
    // the judged value in would silently give it one.
    CaseObservation few;
    few.name = "graded/case";
    few.priorSeries = [1000.0, 1010.0, 1030.2, 1061.106];
    few.prevUs = 1061.106;
    few.curUs  = 106_110.6;
    assert(caseBand(few, p).source == BandSource.fallback,
           "three prior moves is not a band, however large the judged value");
}

unittest { // A case with no measured noise yet is gated EXACTLY as before, so
           // nothing is less gated for lack of history. Three prior moves is
           // below `minPriorMoves`, and there is no p95 column.
    GateParams p;
    CaseObservation o;
    o.name = "brand/new/case";
    o.prevUs = 1000.0;
    o.priorSeries = [1000.0, 1000.0, 1000.0, 1000.0];   // three moves
    o.curUs = 1000.0 * 1.19;
    auto b = caseBand(o, p);
    assert(b.source == BandSource.fallback);
    assert(judge(o, 1.0, p).call == Call.clean,
           "+19% must clear the old +20% fallback");
    o.curUs = 1000.0 * 1.21;
    assert(judge(o, 1.0, p).call == Call.regressed,
           "the fallback must be the old +20%, to the percent");

    o.name = "brand/new/case#snapQuery";               // ... and +60% for snap
    o.curUs = 1000.0 * 1.55;
    assert(judge(o, 1.0, p).call == Call.clean,
           "+55% must clear the #snapQuery fallback");
    o.curUs = 1000.0 * 1.61;
    assert(judge(o, 1.0, p).call == Call.regressed,
           "and +61% must not");
}

unittest { // `runScale` is the identity — not merely "close to 1" — when there
           // are too few keys to take a run-level median from. The history
           // holds real 13-key partial runs; one of them must never donate a
           // fabricated scale to a 90-key comparison.
    GateParams p;
    CaseObservation[] few;
    foreach (i; 0 .. 5) {
        CaseObservation o;
        o.name = "c";
        o.prevUs = 100.0; o.curUs = 300.0;      // a 3x common move, ignored
        few ~= o;
    }
    assert(runScale(few, p) == 1.0,
           "under commonModeMinKeys the term must be the exact identity");

    CaseObservation[] many;
    foreach (i; 0 .. 25) {
        CaseObservation o;
        o.name = "c";
        o.prevUs = 100.0; o.curUs = 110.0;
        many ~= o;
    }
    assert(abs(runScale(many, p) - 1.10) < 1e-9,
           "with enough keys the term is the run's own median ratio");

    // ...and it is a MEDIAN, which is the whole reason it can be trusted: the
    // 2026-08-26 history holds a run where five `#snapQuery` keys went up
    // TENFOLD at once. A mean would let that single event donate a scale to
    // its own neighbours and hide them. Twenty-four flat keys and one 10x:
    // median 1.0, mean 1.375.
    CaseObservation[] withOutlier;
    foreach (i; 0 .. 24) {
        CaseObservation o;
        o.name = "c";
        o.prevUs = 100.0; o.curUs = 100.0;
        withOutlier ~= o;
    }
    {
        CaseObservation o;
        o.name = "blowup";
        o.prevUs = 100.0; o.curUs = 1000.0;
        withOutlier ~= o;
    }
    assert(abs(runScale(withOutlier, p) - 1.0) < 1e-9,
           "one tenfold regression must not move the run-level term — a mean "
           ~ "here reads 1.375 and would grant every quiet case a 37% licence "
           ~ "on the night a real blow-up landed");

    p.flat = true;
    assert(runScale(many, p) == 1.0,
           "flat mode must reproduce the OLD verdict exactly, which means no "
           ~ "common-mode term at all");
}

unittest { // The same-night arm reads a real pair of measured spreads and
           // separates quiet from noisy with no constant in between. Both
           // ratios are from 2026-08-28 on this host.
    GateParams p;
    CaseObservation quiet;
    quiet.name = "rotate/falloff=radial";
    quiet.prevUs = 30651.4; quiet.curUs = 30651.4;
    quiet.prevP95Us = 30718.5; quiet.curP95Us = 30718.5;      // p95/median 1.0022
    assert(caseBand(quiet, p).source == BandSource.floor,
           "a case whose own repeats span 0.2% must fall through to the floor");

    CaseObservation noisy;
    noisy.name = "move/falloff=screen";
    noisy.prevUs = 42274.9; noisy.curUs = 42274.9;
    noisy.prevP95Us = 52934.4; noisy.curP95Us = 52934.4;      // p95/median 1.2521
    auto b = caseBand(noisy, p);
    assert(b.source == BandSource.sameNight);
    assert(b.pct > 20.0 && b.pct < 30.0,
           "and one whose own repeats span 25% must carry that, not a "
           ~ "constant — the whole point of the column");
}
