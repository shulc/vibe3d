// THE SECOND WITNESS for the two laws task 4360 corrected, and the coverage
// the one captured cell does not give them.
//
// WHY THIS FILE EXISTS. `tests/unit/edge_bevel_open_fan_cap_parity_test.d`
// builds the six frozen cells and compares them to their dumps, and it is the
// ONLY place either 4360 law is exercised: both of that task's mutations
// reddened the same cell, `open_fan_K2_boundary_L1`. Everything outside that
// one cell's configuration was unguarded, and the review of 4360 was right
// that "unobservable anywhere else" was an assertion nobody had run. It is
// false, and the numbers below are what refutes it. This file has no dump and
// claims none: every cell here checks a LAW that the capture settled, on a
// shape the capture never drove, so it is evidence about our own code meeting
// a measured rule -- not new reference geometry.
//
// THE SHAPES, and why each one is the discriminating one.
//   * R0 -- the REGULAR unit valence-5 fan the whole frozen corpus is built
//     on. Its two arc-radius pairs are EQUAL, which is exactly why the corpus
//     could not tell the pre-4360 raw-spoke blend from the linear-radius law:
//     they are the same point there (measured 1.9e-9 apart over the whole
//     mesh). R0's cell asserts that equality, so the population floors of the
//     three cells after it mean something instead of being decoration. It is
//     FIRST on purpose -- it stays green under every mutation below, so a
//     single run always shows a green assert above the red one.
//   * R1 -- the same CLOSED fan with irregular spoke ANGLES (0/50/144/250/300
//     degrees) and every spoke still unit length. Nothing clamps, so the
//     base-gap arc's two radii are both exactly the width and that site is
//     still degenerate; only the cap's interior fillet sees unequal radii
//     (0.098857 against 0.085890). No boundary, no rim spoke, nothing open.
//   * R2 -- the REGULAR closed fan with ONE gap-end spoke shortened to 0.06,
//     under a width of 0.10. `getSlide`'s per-neighbour overshoot clamp pins
//     that slide at the spoke's own length, so the base-gap arc spans 0.10
//     against 0.06. This is the reachability the review named.
//   * R3 -- the OPEN boundary layout with the same short spoke, which is what
//     puts unequal radii under the PLAIN hub arc as well: a third call site,
//     found while checking the two the review named.
//
// THE LAW EACH CELL CHECKS. A cap arc sweeps circularly about a centre: the
// DIRECTION is the slerp of the two unit spokes, and the RADIUS is
// interpolated LINEARLY. At Round Level 1 every such arc carries exactly one
// interior point, at the half parameter, where the unit slerp is just the
// normalized sum -- so the predicted point is
//
//     centre + normalize(uA + uB) * (|A - centre| + |B - centre|) / 2
//
// and it is computed here from OBSERVABLE positions (the input fan for the two
// hub-centred sites, the arc's own emitted samples for the apex-centred one),
// never from a stored expectation.
//
// THE FIFTH CELL is not about radii at all. It closes the coverage gap the
// review's first finding names: the `openFan` arm of the notch-cap plan
// re-assigns apex and base-gap roles over its WHOLE guarded region, and the
// guard fixes the shape completely -- K == 2 with gaps {1,2} forces
// nE == 5, so a valence-5 open fan is the only thing that reaches it and the
// ten spoke pairs enumerate below with no sampling. Five of them qualify; the
// frozen corpus drives two. What the cell asserts on all five is the
// STRUCTURAL half of the captured law: on an open fan the cap's base is the
// ring edge that spans the hole, and the captured result's two base sub-edges
// are genuine BOUNDARY edges of the mesh. Measured against the old
// wrap-arithmetic rule that fact holds on 1 layout of the 5; under the arm
// shipped by 4360 it holds on 5 of 5.
//
// MUTATIONS (each seen red under `dub test --config=tests`; the task card
// carries the verbatim lines and the module counts):
//   * disable the `openFan` arm of the notch-cap plan -> the layout cell
//     reddens, naming EVERY layout whose base left the boundary -- four of
//     the five, the fifth being the interior one the two rules agree on;
//   * restore the raw-spoke blend in `slerpAbout` -> the :2083 cell reddens at
//     7.100335e-04, with R0 and the layout cell green above it;
//   * restore it at the base-gap arc call ALONE -> the :1672 cell reddens at
//     1.453085e-02, with the :2083 cell green above it, which is what says the
//     two sites have separate witnesses rather than one shared one;
//   * restore it at the plain-hub-arc call ALONE -> the :1656 cell reddens at
//     the same 1.453085e-02, with all four cells above it green.
module tests.unit.edge_bevel_notch_cap_law_test;

import std.format : format;
import std.math   : cos, sin, sqrt, abs, PI;

import mesh;
import mesh_ops.edge_bevel;
import math;

private enum float  kWidth   = 0.1f;
private enum int    kLevel   = 1;
// Three decades above the float32 round-off these rigs actually show — the
// four predictions this file asserts land 3.7e-9, 7.6e-9, 4.4e-9 and 4.4e-9
// from their measured points — and two decades below the SMALLEST divergence
// any mutation here produces (7.1e-4; the other two are 1.45e-2). Both margins
// were measured before the number was written down.
private enum double kTol     = 1e-5;

private alias V3 = double[3];

private V3 v3(Vec3 v) { return [cast(double)v.x, cast(double)v.y, cast(double)v.z]; }
private double len(V3 a) { return sqrt(a[0]*a[0] + a[1]*a[1] + a[2]*a[2]); }
private double dist(V3 a, V3 b) {
    const double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}
private V3 sub(V3 a, V3 b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
private V3 addv(V3 a, V3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
private V3 scale(V3 a, double s) { return [a[0]*s, a[1]*s, a[2]*s]; }
private V3 unit(V3 a) { immutable double L = len(a); assert(L > 1e-12); return scale(a, 1.0 / L); }

/// The measured arc law at the half parameter: direction = slerp of the two
/// UNIT spokes (which at f = 1/2 is their normalized sum), radius = the mean.
private V3 arcMidpoint(V3 centre, V3 A, V3 B) {
    immutable V3 rA = sub(A, centre), rB = sub(B, centre);
    return addv(centre, scale(unit(addv(unit(rA), unit(rB))), (len(rA) + len(rB)) * 0.5));
}

/// A valence-5 fan: hub at the origin, five rim points at the given angles
/// (degrees) and radii. `closed` adds the base polygon [0,5,1]; dropping it is
/// what puts the hub on a boundary (5 spokes, 4 faces).
private Mesh fan(const double[5] angDeg, const double[5] radius, bool closed) {
    Mesh m;
    m.vertices ~= Vec3(0, 0, 0);
    foreach (i; 0 .. 5) {
        immutable double a = angDeg[i] * PI / 180.0;
        m.vertices ~= Vec3(cast(float)(cos(a) * radius[i]),
                           cast(float)(sin(a) * radius[i]), 0.0f);
    }
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.addFace([0u, 3u, 4u]);
    m.addFace([0u, 4u, 5u]);
    if (closed) m.addFace([0u, 5u, 1u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private size_t bevelSpokes(ref Mesh m, const uint[] spokes) {
    auto mask = new bool[](m.edges.length);
    size_t selected = 0;
    foreach (s; spokes)
        foreach (i; 0 .. m.edges.length)
            if ((m.edges[i][0] == 0u && m.edges[i][1] == s) ||
                (m.edges[i][1] == 0u && m.edges[i][0] == s)) {
                mask[i] = true; ++selected; break;
            }
    assert(selected == spokes.length, "every named hub spoke must be in the mask");
    auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
    immutable size_t n = ed.bevelEdgesByMask(mask, kWidth, kLevel, false);
    ed.close();
    return n;
}

/// Where `getSlide` puts the corner on hub spoke `s` of this fan: `width`
/// along it, or the spoke's own length when the per-neighbour overshoot clamp
/// fires (`effW >= farLen`). This is the ONE place either radius comes from at
/// a hub-centred arc, which is why a short spoke is what makes them unequal.
private V3 slideOn(const double[5] angDeg, const double[5] radius, int s) {
    immutable double a = angDeg[s - 1] * PI / 180.0;
    immutable double L = radius[s - 1];
    immutable double w = (kWidth < L) ? kWidth : L;
    return [cos(a) * w, sin(a) * w, 0.0];
}

/// Vertices of `m` within `kTol` of `p`. A COUNT, not a nearest-neighbour
/// pick: a prediction the build no longer meets gives 0 here, and the message
/// carries the nearest distance so the red line says how far it moved.
private size_t[] hitsNear(ref Mesh m, V3 p, out double nearest) {
    size_t[] hits;
    nearest = double.max;
    foreach (i, v; m.vertices) {
        immutable double d = dist(v3(v), p);
        if (d < nearest) nearest = d;
        if (d <= kTol) hits ~= i;
    }
    return hits;
}

/// Undirected edge -> how many polygons of `m` carry it. Counted straight off
/// `faces[]` so it cannot go stale against the post-edit edge array.
private int[ulong] edgeUseCounts(ref Mesh m) {
    int[ulong] c;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length)
            c[edgeKeyOf(f[k], f[(k + 1) % f.length])] += 1;
    return c;
}

/// The DISTINCT vertices joined to `v` by an edge of some polygon.
private size_t[] neighboursOf(ref Mesh m, size_t v) {
    bool[size_t] seen;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length)
            if (cast(size_t)f[k] == v) {
                seen[cast(size_t)f[(k + 1) % f.length]] = true;
                seen[cast(size_t)f[(k + f.length - 1) % f.length]] = true;
            }
    size_t[] n;
    foreach (x; seen.byKey) n ~= x;
    return n;
}

private ulong edgeKeyOf(size_t a, size_t b) {
    return (a < b) ? (cast(ulong)a << 32) | cast(ulong)b
                   : (cast(ulong)b << 32) | cast(ulong)a;
}

/// The vertices joined to BOTH `a` and `b`, each once.
private size_t[] commonNeighbours(ref Mesh m, size_t a, size_t b) {
    size_t[] outv;
    foreach (x; neighboursOf(m, a)) {
        if (x == a || x == b) continue;
        foreach (y; neighboursOf(m, b)) if (y == x) { outv ~= x; break; }
    }
    return outv;
}

// The regular unit fan the whole frozen corpus is built on, and the two rigs
// that leave its degeneracy.
private static immutable double[5] kRegularAng = [0, 72, 144, 216, 288];
private static immutable double[5] kUnitRad    = [1, 1, 1, 1, 1];
private static immutable double[5] kSkewAng    = [0, 50, 144, 250, 300];
private static immutable double[5] kShortRad   = [1, 1, 1, 1, 0.06];
// Both rigs bevel the same narrow notch: spokes 1 and 3, leaving gaps of one
// slot (spoke 2, the apex) and two (spokes 4 and 5, the base).
private static immutable uint[2] kNotchSpokes = [1u, 3u];

unittest // R0: the frozen corpus's own fan cannot tell the two arc laws apart
{
    auto m = fan(kRegularAng, kUnitRad, true);
    assert(bevelSpokes(m, kNotchSpokes[]) == 2,
        "R0: the notch bevel must process both selected spokes");

    // The base-gap arc's centre is the hub and its ends are the two gap-end
    // slides. On this fan nothing clamps, so both radii are the width.
    immutable V3 hub = [0.0, 0.0, 0.0];
    immutable V3 gL = slideOn(kRegularAng, kUnitRad, 5);
    immutable V3 gR = slideOn(kRegularAng, kUnitRad, 4);
    assert(abs(len(sub(gL, hub)) - len(sub(gR, hub))) < 1e-6,
        format("R0: the base-gap arc's radii must be EQUAL on the corpus's own "
             ~ "fan -- that degeneracy is why the corpus cannot witness the "
             ~ "radius law; got %s against %s",
               len(sub(gL, hub)), len(sub(gR, hub))));

    // ...and the point the two laws would disagree about is on the mesh, at
    // the SAME place under either of them.
    double nearest;
    auto hits = hitsNear(m, arcMidpoint(hub, gL, gR), nearest);
    assert(hits.length == 1,
        format("R0: exactly one vertex must sit at the base-gap arc's midpoint "
             ~ "-- found %s, nearest %s", hits.length, nearest));
}

unittest // the `openFan` plan arm over EVERY layout it can reach, not the two the corpus drives
{
    // The guard is `K == 2` with unselected gaps {1,2}, so nE == 2+1+2 == 5:
    // a valence-5 open fan is the only shape that reaches this arm and the ten
    // spoke pairs below are the whole population, enumerated rather than
    // sampled.
    struct Layout { uint a, b; bool qualifies; }
    Layout[] all;
    foreach (a; 1 .. 6) foreach (b; a + 1 .. 6) {
        immutable int gapFwd = cast(int)(b - a - 1);
        immutable int gapBwd = 3 - gapFwd;          // 5 slots - 2 selected - gapFwd
        all ~= Layout(cast(uint)a, cast(uint)b,
                      (gapFwd == 1 && gapBwd == 2) || (gapFwd == 2 && gapBwd == 1));
    }
    assert(all.length == 10,
        format("the five hub spokes make ten pairs, enumerated %s", all.length));
    size_t qualifying = 0;
    foreach (l; all) if (l.qualifies) ++qualifying;
    assert(qualifying == 5,
        format("exactly five spoke pairs leave gaps of {1,2} and so reach the "
             ~ "openFan plan arm -- counted %s", qualifying));

    size_t checked = 0;
    string[] held, left;
    foreach (l; all) {
        if (!l.qualifies) continue;
        auto m = fan(kRegularAng, kUnitRad, false);   // OPEN
        assert(bevelSpokes(m, [l.a, l.b]) == 2,
            format("open fan, spokes %s and %s: both must be processed", l.a, l.b));

        // The three unselected spokes, in slot order (slot k is spoke k+1 on
        // this fan). The arm makes the middle one the apex and the outer two
        // the base-gap ends -- and the base then spans the HOLE.
        uint[] uns;
        foreach (s; 1 .. 6) if (s != l.a && s != l.b) uns ~= cast(uint)s;
        assert(uns.length == 3,
            format("K == 2 on a valence-5 fan leaves three unselected spokes, "
                 ~ "found %s", uns.length));

        double nL, nR;
        auto hL = hitsNear(m, slideOn(kRegularAng, kUnitRad, uns[0]), nL);
        auto hR = hitsNear(m, slideOn(kRegularAng, kUnitRad, uns[2]), nR);
        assert(hL.length == 1 && hR.length == 1,
            format("open fan, spokes %s and %s: the two base-gap slides must "
                 ~ "each be one vertex -- found %s and %s (nearest %s, %s)",
                   l.a, l.b, hL.length, hR.length, nL, nR));

        // THE CAPTURED STRUCTURAL FACT: the base is on the mesh boundary. Its
        // two sub-edges came out of the capture as genuine boundary edges, so
        // the midpoint between the two gap ends must be joined to both of them
        // by edges that carry exactly ONE polygon.
        auto uses = edgeUseCounts(m);
        immutable size_t gl = hL[0], gr = hR[0];
        bool onBoundary = false;
        foreach (n; commonNeighbours(m, gl, gr))
            if (uses.get(edgeKeyOf(gl, n), 0) == 1 &&
                uses.get(edgeKeyOf(gr, n), 0) == 1) onBoundary = true;
        // Collected, not asserted per layout: druntime stops a module at the
        // first failed assert, and the FIRST layout here is the one the frozen
        // corpus already drives. Reporting all five together is what shows the
        // three the corpus does NOT drive are covered.
        (onBoundary ? held : left) ~= format("{%s,%s}", l.a, l.b);
        ++checked;
    }
    assert(checked == 5,
        format("all five reachable layouts must be driven -- drove %s", checked));
    assert(left.length == 0,
        format("open fan: the notch cap's base must span the HOLE, its two "
             ~ "sub-edges being boundary edges of the result -- the structural "
             ~ "half of the captured law. Held on %s of 5 %s; left the boundary "
             ~ "on %s of 5 %s. The wrap-arithmetic rule this arm replaced holds "
             ~ "it on exactly one layout, {2,4}, which is the only one of the "
             ~ "five the frozen corpus drives as well as the boundary cell "
             ~ "{1,3} -- so a regression here can be invisible to that corpus.",
               held.length, held, left.length, left));
}

unittest // R1: the cap's interior fillet (edge_bevel.d :2083) at unequal radii
{
    auto m = fan(kSkewAng, kUnitRad, true);
    assert(bevelSpokes(m, kNotchSpokes[]) == 2,
        "R1: the notch bevel must process both selected spokes");

    // The fillet's centre is the APEX slide; its two ends are the round-level-1
    // interior samples of the two hub arcs. Those are found through the mesh,
    // because they come out of the chamfer-rail construction and are not
    // analytic in the input fan.
    immutable V3 apexP = slideOn(kSkewAng, kUnitRad, 2);
    double nApex, nL, nR;
    auto hApex = hitsNear(m, apexP, nApex);
    auto hL = hitsNear(m, slideOn(kSkewAng, kUnitRad, 5), nL);
    auto hR = hitsNear(m, slideOn(kSkewAng, kUnitRad, 4), nR);
    assert(hApex.length == 1 && hL.length == 1 && hR.length == 1,
        format("R1: apex and the two gap-end slides must each be one vertex -- "
             ~ "found %s, %s, %s", hApex.length, hL.length, hR.length));

    size_t sampleBetween(size_t gap) {
        auto c = commonNeighbours(m, gap, hApex[0]);
        assert(c.length == 1,
            format("R1: the hub arc from vertex %s to the apex must carry "
                 ~ "exactly one interior sample at Round Level 1, found %s",
                   gap, c.length));
        return c[0];
    }
    immutable size_t aL = sampleBetween(hL[0]), aR = sampleBetween(hR[0]);
    immutable V3 A = v3(m.vertices[aL]), B = v3(m.vertices[aR]);
    immutable double rA = dist(A, apexP), rB = dist(B, apexP);

    // POPULATION FLOOR. Without this the cell is satisfied by the raw-spoke
    // blend too: the two laws are the same point whenever the radii are equal,
    // which is what every frozen cell but one has.
    assert(abs(rA - rB) > 0.005,
        format("R1: this rig exists to make the fillet's two radii UNEQUAL -- "
             ~ "got %s and %s, difference %s, which no longer separates the "
             ~ "raw-spoke blend from the linear-radius law", rA, rB, abs(rA - rB)));

    double nearest;
    auto hits = hitsNear(m, arcMidpoint(apexP, A, B), nearest);
    assert(hits.length == 1,
        format("R1: the cap's interior fillet must sweep the apex at a LINEARLY "
             ~ "interpolated radius (edge_bevel.d slerpAbout, task 4360) -- "
             ~ "no vertex within %s of the predicted point, nearest %s; radii "
             ~ "%s and %s", kTol, nearest, rA, rB));
}

unittest // R2: the base-gap arc (edge_bevel.d :1672) at unequal radii
{
    auto m = fan(kRegularAng, kShortRad, true);
    assert(bevelSpokes(m, kNotchSpokes[]) == 2,
        "R2: the notch bevel must process both selected spokes");

    immutable V3 hub = [0.0, 0.0, 0.0];
    immutable V3 gL = slideOn(kRegularAng, kShortRad, 5);   // clamped to 0.06
    immutable V3 gR = slideOn(kRegularAng, kShortRad, 4);   // the full width
    immutable double rL = len(sub(gL, hub)), rR = len(sub(gR, hub));

    // POPULATION FLOOR, and it is also the reachability claim: `getSlide`'s
    // per-neighbour overshoot clamp is what puts these two arc ends at
    // different radii, on a CLOSED fan with no boundary spoke anywhere.
    assert(abs(rL - rR) > 0.005,
        format("R2: the overshoot clamp must leave the base-gap arc's two "
             ~ "radii UNEQUAL -- got %s and %s", rL, rR));

    double nearest;
    auto hits = hitsNear(m, arcMidpoint(hub, gL, gR), nearest);
    assert(hits.length == 1,
        format("R2: the base-gap arc must sweep the hub at a LINEARLY "
             ~ "interpolated radius (edge_bevel.d slerpAbout, task 4360) -- "
             ~ "no vertex within %s of the predicted point, nearest %s; radii "
             ~ "%s and %s", kTol, nearest, rL, rR));
}

unittest // R3: the plain hub arc (edge_bevel.d :1656) at unequal radii
{
    // OPEN fan, boundary layout, same short spoke. The arc with no chamfer
    // behind it runs from the apex slide (spoke 4) to the gap end on spoke 5,
    // and `plainHubArc` lays it down as a circular sweep about the hub.
    auto m = fan(kRegularAng, kShortRad, false);
    assert(bevelSpokes(m, kNotchSpokes[]) == 2,
        "R3: the notch bevel must process both selected spokes");

    immutable V3 hub = [0.0, 0.0, 0.0];
    immutable V3 a4 = slideOn(kRegularAng, kShortRad, 4);
    immutable V3 a5 = slideOn(kRegularAng, kShortRad, 5);
    assert(abs(len(sub(a4, hub)) - len(sub(a5, hub))) > 0.005,
        format("R3: the plain hub arc's two radii must be UNEQUAL -- got %s "
             ~ "and %s", len(sub(a4, hub)), len(sub(a5, hub))));

    double nearest;
    auto hits = hitsNear(m, arcMidpoint(hub, a4, a5), nearest);
    assert(hits.length == 1,
        format("R3: the PLAIN hub arc must sweep at a LINEARLY interpolated "
             ~ "radius too (edge_bevel.d plainHubArc, task 4360) -- no vertex "
             ~ "within %s of the predicted point, nearest %s", kTol, nearest));
}
