module lib.vslast;
// The day-over-day gate's DECISION, separated from the history plumbing that
// feeds it (task 2420 / card 2200).
//
// WHY THIS MODULE EXISTS AT ALL. `--vs-last` used to be one number for every
// case: +20% (+60% for `#snapQuery`). Measured over this host's whole recorded
// history — 21 comparable `n=316` `ops` runs, 1299 consecutive-run comparisons
// of gated keys — that number sits ON the noise:
//
//     p50 |delta|  1.9%   p75  4.9%   p90 14.4%   p95 41.3%   p99 98.8%
//
// so it is simultaneously
//
//   * TOO LOOSE for the quiet majority — 73 of the 90 cases with >= 8
//     comparisons have a median |delta| under 5%, and `rotate/falloff=radial`
//     moved between 29642 and 30756 us across TWENTY runs (+-2%). A real +15%
//     regression there is twenty times its noise and the old gate says nothing;
//   * TOO TIGHT for a noisy handful — `smooth/polygons/whole` alternates
//     between ~4.6 ms and ~7.8 ms with nothing touching it, and five cases
//     crossed +20% on 2026-08-27 and came back.
//
// One global number cannot serve both, and RAISING it only widens the hole
// under the 73 quiet cases. So the gate stops asking "did this case move more
// than N percent" and asks "did this case move more than THIS CASE moves".
//
// THREE LAYERS, and the first two are TERMS rather than thresholds — they are
// computed from numbers the history already records, and they are identically
// 1.0 / 0.0 on a case-run that does not exhibit them:
//
//  1. `runScale` — the run-level common mode. The median of every compared
//     case's cur/prev ratio in this one pair. On 19 of 20 recorded pairs it is
//     0.98-1.01 and changes nothing. On the 08-14 -> 08-18 pair it is 1.061:
//     the whole host got 6% slower over four days, and a per-case band without
//     this term reds TWENTY-ONE cases on that pair for a fact about the
//     machine. Dividing by it makes the comparison dimensionless in host speed,
//     which is exactly the reformulation task 1840 chose for invariant I1a.
//     NAMED BLIND SPOT: a regression that slows EVERY case by the same factor
//     is divided out. That is the absolute lane's job (`baseline.json`, and
//     I1a/I1b), not this one's, and it was already so before this change.
//
//  2. the per-case BAND — how wide this case's own noise is. Two sources,
//     both measurements of the same quantity, and the band takes the WIDEST
//     because each is a lower bound on the noise the gate must not charge for:
//       (a) the SAME-NIGHT sample spread, `p95 / median` over that run's own
//           repeats (`#kernelP95Us`). This is the honest one: it is the case
//           telling you, on the night in question, how far its own samples
//           move when nothing changes. Measured 2026-08-28, four consecutive
//           runs at ONE HEAD on a quiet host, repeats=9 —
//             remove/vertices/whole      17382/17611/20637/22512  spread 29.5%
//                                        p95/median 1.09-1.43
//             vertexExtrude/vertices/half 416367..428993          spread  3.0%
//                                        p95/median 1.06-1.17
//           The case with the widest p95/median is the case with the widest
//           between-run spread, and the case with the tightest has the
//           tightest. THIS is what makes `remove/vertices/whole` explicable:
//           its 2026-08-27 "+42% regression" (15769 -> 22322) is smaller than
//           the swing it produces here with nothing changed at all.
//       (b) `bandSigma` x the case's own PRIOR between-run spread, for rows
//           that predate the p95 column (every row recorded before task 2420).
//     This is the only layer carrying a threshold, and each of its constants
//     is stated with the gap it sits in, below.
//
// A THIRD TERM WAS BUILT AND THEN DELETED, and the deletion is the honest
// half of this note. `#gcMaxPauseNs` (task 2070) records the GC pause that
// landed inside a case's timed region, and it looked like the exact term this
// problem wants: `edgeExtend/edges/whole` moved 237 -> 301 ms on 2026-08-27
// 11:14 with 58.1 ms of recorded pause in it, 92% of the move. Widening each
// case's band by its own recorded pause was implemented, and then ABLATED over
// the whole recorded history: 23 reds with the term, 23 reds without it, and
// the set is identical — it silences NOTHING, because on every case where a
// pause was recorded the band was already wider than the move for another
// reason. A term that cannot be shown changing a verdict is the "mutation
// deletes dead code" entry in CLAUDE.md's list, so it is not here. It can be
// asked again once rows carrying `#kernelP95Us` accumulate and the bands
// narrow; the ablation, not an opinion, is what should answer it.
//
// THE BAND IS BUILT FROM RUNS STRICTLY EARLIER THAN THE ONE BEING JUDGED, and
// that is load-bearing rather than tidy. CLAUDE.md's list of dead checks names
// "the threshold is derived from the measurement it is meant to judge"; task
// 1840 already paid for one (K1_FALLOFF, calibrated on a baseline the same
// defect had inflated). A band that included tonight's number would widen
// itself by exactly the regression it is looking at. `priorSeries` therefore
// carries the case's medians over EARLIER runs only, and this module has no
// way to see the judged value except as `curUs`.
//
// WHAT WAS REJECTED, with the measurement that killed it:
//
//   * CONFIRMATION ACROSS TWO CONSECUTIVE RUNS. The 2200 card proposed it for
//     a third shape — "a quiet case with a rare spike" — and cited
//     `scale/symmetry=X` (median 0.7%, max 54%) and `move/acen=selection`
//     (0.7%, 76%). Reading the series shows both are LEVEL SHIFTS, not
//     spikes: 25961 -> 11980 and 9192 -> 2222, once, on 2026-08-24, and flat
//     on either side. They step and stay, which is what a per-case band
//     handles. The shape confirmation exists for is not evidenced by the two
//     cases offered for it. It also costs a day of detection latency and needs
//     a verdict that is neither red nor green, which is the "green that means
//     did not check" this project keeps paying for.
//   * MORE REPEATS ON THE NOISY CASES. More samples do not remove a 58 ms GC
//     pause from a timed region; they average it over more of them. And the
//     spike runs are the runs where the case ALLOCATED more (Pearson r = 0.908
//     between a case-run's timing ratio and its `#gcAllocBytes` ratio over the
//     four runs carrying both columns), which more repeats also measure. It is
//     a harness change, not a gate change, and it remains a live follow-up.
//   * A COMMITTED PER-CASE THRESHOLD TABLE. It would go stale silently, it
//     would need regenerating by hand, and a regenerate is the same "derived
//     from the measurement it judges" hazard on a slower clock. The band is
//     recomputed at gate time from the same history file the gate already
//     reads, so it cannot disagree with the data.

import std.algorithm : sort, map, endsWith;
import std.array     : array;
import std.math      : log, log1p, exp, isNaN, isFinite, fabs;

// ---------------------------------------------------------------------------

/// The constants, in one place, each with the gap it sits in.
struct GateParams {
    /// Fallback threshold for a case with too little history to have a band
    /// of its own. Deliberately the OLD default: a case gains a band once it
    /// has run enough times, and until then it is gated exactly as before, so
    /// nothing is less gated than it was.
    double defaultThreshold = 0.20;

    /// Same, for the `#snapQuery` keys (task 1350's measured +60%).
    double snapThreshold = 0.60;

    /// The smallest move the gate will EVER call a regression, however quiet
    /// the case. THE GAP IT SITS IN, measured on this host's history: the p75
    /// of all 1299 consecutive-run comparisons is 4.9% and the p50 is 1.9%, so
    /// a 5% floor is above three quarters of the recorded noise; and the card's
    /// required witness is a +10% plant in a case whose noise is under 1%,
    /// which clears it with room. Measured both ways: a +10% plant on each of
    /// the four `falloff=radial|cylinder|linear` cases REDS, a +5% plant on the
    /// same cases is SILENT. Below ~5% the harness cannot tell a regression
    /// from a warm host and the gate would cry wolf; above ~10% the quiet
    /// majority starts hiding real work again.
    double bandFloor = 0.05;

    /// How many of a case's OWN noise widths a move must exceed. THE GAP:
    /// swept over the recorded history with the common-mode term on, K = 3 / 4
    /// / 5 / 6 / 8 gives 31 / 29 / 23 / 20 / 20 reds over the 20 judged runs,
    /// against the old flat gate's 29. So K = 3 is WORSE than the gate it
    /// replaces and K = 4 is exactly as good, i.e. no better; K = 5 is the
    /// first value that buys anything, and K = 6 and 8 return the same 20, so
    /// the curve is saturated past the knee rather than being ridden down to a
    /// number that pleases. 5 is the knee. Above it nothing more is bought and
    /// `triple/polygons/whole` (own median move 9.6%) would carry a band past
    /// 100%, which is a case gated by nothing at all.
    double bandSigma = 5.0;

    /// Below this many prior consecutive moves a case has no band of its own
    /// and falls back to `defaultThreshold`. Four is the smallest count whose
    /// median is not a single sample's opinion.
    size_t minPriorMoves = 4;

    /// The common-mode term is only taken when this many keys were compared.
    /// A median over a handful of keys is not a run-level fact; the history
    /// holds real 13-key partial runs (2026-08-26 20:46) that would otherwise
    /// donate a fabricated scale to a 90-key one.
    size_t commonModeMinKeys = 20;

    /// How many earlier comparable runs feed the prior-spread arm. Twelve is
    /// the whole useful depth of this host's history and is deliberately not
    /// unbounded: a case that stepped to a new level months ago must not carry
    /// that step in its noise estimate forever.
    size_t priorWindow = 12;

    /// The same-night arm's multiplier on `p95/median`. ONE, and that is not a
    /// missing knob: `p95/median` is already a spread, not a deviation to be
    /// scaled. A move smaller than the span this run's OWN repeats produced is
    /// inside the measurement, full stop.
    double sameNightSigma = 1.0;

    /// Escape hatch: reproduce the old single-threshold verdict. Exists so an
    /// operator can A/B the two gates over one history file, and so the change
    /// itself is falsifiable on real data rather than only on a plant.
    bool flat = false;
}

/// One case's side of one comparison. `priorSeries` is that case's medians on
/// runs STRICTLY EARLIER than the judged one, oldest first; the judged run's
/// own value is `curUs` and appears nowhere in it.
struct CaseObservation {
    string   name;
    double   prevUs = double.nan;
    double   curUs  = double.nan;
    /// That case's own `p95` over the repeats of each run, `#kernelP95Us`.
    /// NaN on every row recorded before task 2420 added the column — which is
    /// the whole recorded history as of 2026-08-28, so the same-night arm is
    /// SILENT on it by construction and the prior-spread arm carries those
    /// comparisons alone. Stated rather than left to be discovered: the first
    /// night this arm can act is the first `ops` run after that task lands.
    double   curP95Us  = double.nan;
    double   prevP95Us = double.nan;
    const(double)[] priorSeries;
}

/// Why a band came out the width it did — printed with every verdict, so a red
/// says which layer decided it and a reader can disagree with the right one.
enum BandSource { floor, spread, sameNight, fallback }

struct Band {
    double      widthLog = 0.0;   // in log space; the whole comparison is multiplicative
    BandSource  source;
    double      spreadPct = 0.0;    // the case's own median between-run |move|, percent
    double      sameNightPct = 0.0; // this run's own p95/median spread, percent
    size_t      priorMoves = 0;

    /// The band as a percentage move, for printing.
    double pct() const { return (exp(widthLog) - 1.0) * 100.0; }
}

// ---------------------------------------------------------------------------

/// The run-level common mode: the median of every compared case's cur/prev
/// ratio. Returns exactly 1.0 — the identity, so the caller need not branch —
/// when there are too few keys for the median to mean anything, or when
/// `params.flat` disables the whole per-case machinery.
///
/// NOT a mean: one case going 10x (the 2026-08-26 `#snapQuery` event) would
/// drag a mean far enough to hide its own neighbours.
double runScale(const CaseObservation[] obs, const ref GateParams params) {
    if (params.flat) return 1.0;
    double[] ratios;
    foreach (ref o; obs) {
        if (!isFinite(o.prevUs) || !isFinite(o.curUs)) continue;
        if (o.prevUs <= 0.0 || o.curUs <= 0.0) continue;
        ratios ~= o.curUs / o.prevUs;
    }
    if (ratios.length < params.commonModeMinKeys) return 1.0;
    ratios.sort();
    immutable size_t m = ratios.length / 2;
    return (ratios.length % 2) ? ratios[m] : 0.5 * (ratios[m - 1] + ratios[m]);
}

/// The median of a case's own consecutive |log move| over its prior series.
/// Returns NaN when the series is too short to have `minPriorMoves` of them.
double priorSpreadLog(const(double)[] series, size_t minPriorMoves) {
    double[] moves;
    foreach (i; 1 .. series.length) {
        immutable double a = series[i - 1], b = series[i];
        if (!isFinite(a) || !isFinite(b) || a <= 0.0 || b <= 0.0) continue;
        moves ~= fabs(log(b / a));
    }
    if (moves.length < minPriorMoves) return double.nan;
    moves.sort();
    immutable size_t m = moves.length / 2;
    return (moves.length % 2) ? moves[m] : 0.5 * (moves[m - 1] + moves[m]);
}

/// A run's own sample spread for one case, as a log width: how far its p95
/// sits above its median, taken from whichever of the two rows recorded it,
/// widest first. NaN when neither row carries the column — which is every row
/// written before task 2420.
double sameNightSpreadLog(const ref CaseObservation o) {
    double w = double.nan;
    static double one(double p95, double med) {
        if (!isFinite(p95) || !isFinite(med) || med <= 0.0 || p95 <= med) return double.nan;
        return log(p95 / med);
    }
    immutable double a = one(o.curP95Us, o.curUs);
    immutable double b = one(o.prevP95Us, o.prevUs);
    if (!a.isNaN) w = a;
    if (!b.isNaN && (w.isNaN || b > w)) w = b;
    return w;
}

/// The band for one case: the WIDEST of the floor, the run's own sample
/// spread, and `bandSigma` x its historical between-run spread. Widest and not
/// a sum, because all three are estimates of ONE quantity — how far this case
/// moves when nothing changes — and the band must cover it, not stack it.
Band caseBand(const ref CaseObservation o, const ref GateParams params) {
    Band b;
    if (params.flat) {
        b.source = BandSource.fallback;
        b.widthLog = log1p(o.name.endsWith("#snapQuery")
                           ? params.snapThreshold : params.defaultThreshold);
        return b;
    }

    foreach (i; 1 .. o.priorSeries.length) {
        immutable double a = o.priorSeries[i - 1], c = o.priorSeries[i];
        if (isFinite(a) && isFinite(c) && a > 0.0 && c > 0.0) b.priorMoves++;
    }

    immutable double prior = priorSpreadLog(o.priorSeries, params.minPriorMoves);
    immutable double night = sameNightSpreadLog(o);

    if (prior.isNaN && night.isNaN) {
        // Nothing measured this case's noise yet — gated exactly as it was
        // before this change, so nothing is LESS gated for lack of history.
        b.source = BandSource.fallback;
        b.widthLog = log1p(o.name.endsWith("#snapQuery")
                           ? params.snapThreshold : params.defaultThreshold);
    } else {
        b.widthLog = log1p(params.bandFloor);
        b.source   = BandSource.floor;
        if (!night.isNaN) {
            b.sameNightPct = (exp(night) - 1.0) * 100.0;
            immutable double w = params.sameNightSigma * night;
            if (w > b.widthLog) { b.widthLog = w; b.source = BandSource.sameNight; }
        }
        if (!prior.isNaN) {
            b.spreadPct = (exp(prior) - 1.0) * 100.0;
            immutable double w = params.bandSigma * prior;
            if (w > b.widthLog) { b.widthLog = w; b.source = BandSource.spread; }
        }
    }
    return b;
}

/// What the gate decided about one case.
enum Call { clean, regressed, improved }

struct Verdict {
    Call   call;
    Band   band;
    double movePct = 0.0;        // the RAW cur/prev move, for printing — not
                                 // scaled, so the report shows the measurement
    double scaledMovePct = 0.0;  // after `runScale`; this is what was judged
}

/// The whole decision for one case. `scale` comes from `runScale` over the
/// same comparison.
Verdict judge(const ref CaseObservation o, double scale, const ref GateParams params) {
    Verdict v;
    if (!isFinite(o.prevUs) || !isFinite(o.curUs)
        || o.prevUs <= 0.0 || o.curUs <= 0.0 || !isFinite(scale) || scale <= 0.0)
        return v;                                   // uncomparable ⇒ clean
    v.band = caseBand(o, params);
    v.movePct = (o.curUs / o.prevUs - 1.0) * 100.0;
    immutable double moveLog = log(o.curUs / (o.prevUs * scale));
    v.scaledMovePct = (exp(moveLog) - 1.0) * 100.0;
    if (moveLog >  v.band.widthLog) v.call = Call.regressed;
    else if (-moveLog > v.band.widthLog) v.call = Call.improved;
    return v;
}
