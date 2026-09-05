// Frozen-fixture cell for the bevel cap on an OPEN (boundary) fan
// (task 4331, capture campaign batch C'), reading
// `tests/fixtures/edge_bevel_open_fan_cap.json`.
//
// WHY IT EXISTS. The behaviour-gap register recorded, in its own words, that
// "no reference dump exists for a free-end / partial-fan cap anchored on a
// BOUNDARY (open) fan at any Round Level", and on that basis registered our
// outright refusal of the shape as the safe, asserted behaviour. Five dumps
// exist now and the reference does NOT refuse: it builds the cap.
//
// AND IT BUILDS THE SAME ONE. With the selected spokes interior, every vertex
// of the open-fan result coincides with the closed fan's at distance 0.0, and
// the only face that differs is the one base polygon that was deleted to open
// the fan in the first place. So the cap construction does not consult the
// fan's openness at all -- which makes our refusal a DIVERGENCE, not a
// simplification, and makes this fixture target geometry rather than a
// regression lock. Nothing in vibe3d is pinned by it.
//
// WHY A BOOT WAS SPENT HERE, when the rest of this batch spent none. The
// static read located the branch -- two vertex flags decline outright and a
// third adjusts the ring tally -- and could not decode WHICH bit marks a fan
// as open, because the bit is written elsewhere. The read was exhausted; that
// is what justifies a behavioural channel, and the channel used is the
// cheapest one: headless, no display, no pointer, six cases in one session.
//
// THE CONTROL, and it is the reason a zero difference below means something.
// The same session re-ran an already-committed capture and reproduced it at
// distance 0.0 with identical faces. A session that cannot reproduce a known
// dump cannot be trusted about a new one, and "0.0" from a harness that
// silently did nothing looks exactly like "0.0" from one that measured.
//
// MUTATIONS (each seen red, in isolation -- see the task card):
//   * perturb one open-fan vertex in the fixture by 1e-6 -> `the open fan's
//     cap must coincide with the closed fan's` reddens.
//   * delete the boundary-selection case -> `the corpus must contain a cap
//     that DIFFERS` reddens, which is the guard against a corpus that is one
//     shape repeated.
//   * set every case's cap_face_count to 0 -> `every case must actually
//     build a cap` reddens, which is the population floor under the identity
//     claim.
module tests.unit.edge_bevel_open_fan_cap_test;

import std.json;
import std.file   : readText;
import std.math   : sqrt;
import std.format : format;

private enum string kFixture = "tests/fixtures/edge_bevel_open_fan_cap.json";

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private JSONValue fixture() { return parseJSON(readText(kFixture)); }

private alias V3 = double[3];

private V3[] verticesOf(JSONValue cell) {
    V3[] outv;
    foreach (p; cell["vertices"].array) {
        assert(p.array.length == 3, "fixture: a vertex must be a 3-vector");
        outv ~= [num(p.array[0]), num(p.array[1]), num(p.array[2])];
    }
    return outv;
}

private double dist(V3 a, V3 b) {
    const double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

private JSONValue caseNamed(JSONValue fx, string want) {
    foreach (c; fx["cases"].array)
        if (c["name"].str == want) return c;
    assert(false, "the fixture must keep the case " ~ want);
}

unittest // the reference builds a cap on an open fan, and it is the closed one
{
    auto fx = fixture();
    const double tol = num(fx["tolerance"]);

    // ORDER: the population floor and the control come FIRST, so a run that
    // reddens the identity claim below has already shown the corpus is not
    // empty and the session was driving the reference correctly.
    assert(fx["cases"].array.length >= 5,
        "all five captured shapes plus the control must survive");

    foreach (c; fx["cases"].array)
        assert(cast(int) num(c["cap_face_count"]) >= 1
            && cast(int) num(c["cap_ring_vertex_count"]) >= 3,
            format("%s: every case must actually build a cap -- a corpus of "
                 ~ "empty results would satisfy an identity claim vacuously",
                   c["name"].str));

    auto control = caseNamed(fx, "control_narrow_notch_closed_L1");
    assert(cast(int) num(control["vertex_count"]) == 16
        && cast(int) num(control["face_count"]) == 13,
        "the control must reproduce the already-committed capture's own "
      ~ "counts; if it does not, this session was not driving the reference "
      ~ "and nothing else in the file can be believed");

    // THE FINDING. Every open-fan vertex coincides with a closed-fan vertex.
    auto openC   = caseNamed(fx, "open_fan_K2_interior_L1");
    auto closedC = caseNamed(fx, "closed_fan_K2_interior_L1");
    const V3[] vo = verticesOf(openC);
    const V3[] vc = verticesOf(closedC);
    assert(vo.length == vc.length && vo.length == 16,
        format("both must carry sixteen vertices, got %s and %s",
               vo.length, vc.length));

    double worst = 0.0;
    foreach (p; vo) {
        double best = double.max;
        foreach (q; vc) {
            const double d = dist(p, q);
            if (d < best) best = d;
        }
        if (best > worst) worst = best;
    }
    assert(worst <= tol,
        format("the open fan's cap must coincide with the closed fan's -- "
             ~ "worst nearest-neighbour distance was %s, so the cap "
             ~ "construction DOES consult the fan's openness and the law is "
             ~ "wrong", worst));
    assert(worst == num(fx["open_equals_closed_worst_vertex_distance"]),
        "the frozen distance must be the one recomputed here");

    // ...and exactly one face differs, the base polygon that was removed.
    assert(cast(int) num(fx["faces_only_in_closed"]) == 1
        && cast(int) num(fx["faces_only_in_open"]) == 0,
        "the only face difference must be the single base polygon deleted to "
      ~ "open the fan -- an open result carrying an EXTRA face would mean the "
      ~ "builder added something for the boundary, which is the rival claim");
    assert(cast(int) num(openC["face_count"])
         + 1 == cast(int) num(closedC["face_count"]),
        "and the counts must agree with that: one fewer face, no more");

    // The corpus must not be one shape repeated. The boundary-touching
    // selection builds a cap too, and a DIFFERENT one.
    auto bnd = caseNamed(fx, "open_fan_K2_boundary_L1");
    const V3[] vb = verticesOf(bnd);
    double far = 0.0;
    foreach (p; vb) {
        double best = double.max;
        foreach (q; vo) {
            const double d = dist(p, q);
            if (d < best) best = d;
        }
        if (best > far) far = best;
    }
    assert(far > 1e-3,
        format("the corpus must contain a cap that DIFFERS, or 'the open fan "
             ~ "gets the closed fan's cap' is being read off a corpus that "
             ~ "could not show otherwise -- the boundary-selection case was "
             ~ "only %s away", far));

    // The round level governs the cap's SHAPE, not whether one exists.
    auto flat = caseNamed(fx, "open_fan_K2_interior_L0");
    assert(cast(int) num(flat["cap_face_count"]) >= 1
        && cast(int) num(flat["cap_ring_vertex_count"])
           < cast(int) num(openC["cap_ring_vertex_count"]),
        "at round level zero the open fan must still get a cap, and a simpler "
      ~ "one -- if it got none, the level would be gating the cap's existence "
      ~ "and the law would be about the level, not the boundary");

    assert(fx["provenance"]["method"].str == "command",
        "this one was MEASURED on the headless command lane, not read; the "
      ~ "provenance must say which, because the two carry different caveats");
    assert(fx["our_divergence"].str.length > 0
        && fx["what_this_does_not_settle"].array.length >= 2,
        "the file must state that our refusal is a divergence, and name what "
      ~ "the capture still does not answer");
}
