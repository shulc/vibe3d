// Reader for the three bevel-cap remainders read statically in task 4332,
// over `tests/fixtures/edge_bevel_miter_and_patch_law.json`.
//
// The three laws, in one line each:
//
//   row 17  A miter profile's INTERIOR is not drawn by the arc/rail routine at
//           all. Each interior sample is a componentwise linear blend of TWO
//           rail evaluations, taken at complementary parameters s and 1-s,
//           blended by that same s, on the uniform schedule s_i = i/(n+1).
//   row 20  The three-sided surface interpolator emits THREE four-sided patches
//           around ONE interior hub, from six interior control points (two per
//           side) -- not one triangular patch.
//   row 22  The cap router's marker exit builds NOTHING. It is a branch to the
//           routine's single common tail, i.e. a decline, not a third builder.
//
// WHAT MAKES THESE CHECKS ABLE TO FAIL, which is the only property that makes
// them worth running. Each law is written out here as a pure function and each
// REFUTED RIVAL is written out beside it; the test asserts not merely that the
// law reproduces the frozen numbers but that every rival PRODUCES SOMETHING
// ELSE on the frozen cells. A fixture that only ever confirms the law it was
// generated from is satisfied by the rival too whenever the corpus happens to
// sit inside the rival's own partition -- which is exactly how the rotation
// blend law went green under the model it had supposedly refuted. So the cells
// here are chosen to sit OUTSIDE each rival's agreement set, and the one cell
// that cannot (the blend at s = 1/2, where the lerp and the midpoint rival
// agree by construction) is carried explicitly labelled inert and is excluded
// from the separation assertion rather than quietly counted in it.
//
// ORDERING. druntime stops a module at its first failed assert, so the asserts
// below are ordered with the ones that must stay green ABOVE the ones a given
// mutation must redden. Everything above a red line is then known to have run
// and passed, and one run buys both halves.
module tests.unit.edge_bevel_miter_and_patch_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, fabs;
import std.format : format;

private enum string kFixture = "tests/fixtures/edge_bevel_miter_and_patch_law.json";

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

private V3 vec(JSONValue v) {
    assert(v.array.length == 3, "fixture: expected a 3-vector");
    return [num(v.array[0]), num(v.array[1]), num(v.array[2])];
}

private double maxAbsDiff(V3 a, V3 b) {
    double m = 0.0;
    foreach (k; 0 .. 3) { const double d = fabs(a[k] - b[k]); if (d > m) m = d; }
    return m;
}

// ---------------------------------------------------------------------------
// The read laws, written out. Nothing here consults the fixture; the fixture is
// the frozen OUTPUT these are checked against.
// ---------------------------------------------------------------------------

// Row 17, the schedule: s_i = i/(n+1), i = 1..n.
private double[] miterSchedule(int nSeg) {
    double[] s;
    foreach (i; 1 .. nSeg + 1) s ~= cast(double) i / cast(double)(nSeg + 1);
    return s;
}

// Row 17, the blend: interior = A + s*(B - A), componentwise.
private V3 miterInterior(V3 a, V3 b, double s) {
    return [a[0] + s * (b[0] - a[0]),
            a[1] + s * (b[1] - a[1]),
            a[2] + s * (b[2] - a[2])];
}

// Row 17, the second rail's parameter.
private double secondRailParameter(double s) { return 1.0 - s; }

// Row 17, the second rail's direction input: componentwise negation.
private V3 negated(V3 d) { return [-d[0], -d[1], -d[2]]; }

// Row 22, the router. Only the two gates this row is about, in the order the
// routine tests them: the ring SHAPE gate first, the marker gate second.
private string capRoute(int builtPolygons, int slotCount, int marker) {
    if (builtPolygons == 3 && slotCount == 5) return "tri_cap_family";
    if (marker != 0)                          return "common_tail_no_cap";
    if (builtPolygons == 0)                   return "common_tail_no_cap";
    return "corner_patch";
}

// ---------------------------------------------------------------------------
// The REFUTED RIVALS, written out so they can be shown to disagree.
// ---------------------------------------------------------------------------

private double[] rivalScheduleIOverN(int nSeg) {
    double[] s;
    foreach (i; 1 .. nSeg + 1) s ~= cast(double) i / cast(double) nSeg;
    return s;
}

private double[] rivalScheduleIMinusOneOverN(int nSeg) {
    double[] s;
    foreach (i; 1 .. nSeg + 1) s ~= cast(double)(i - 1) / cast(double) nSeg;
    return s;
}

// The model this read replaced: the rail alone places the interior sample.
private V3 rivalRailDrivesInterior(V3 a, V3 b, double s) { return a; }

// A blend at a fixed one half rather than at the insertion parameter.
private V3 rivalMidpoint(V3 a, V3 b, double s) {
    return [(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5];
}

private double rivalSecondRailAtOne(double s) { return 1.0; }

// Testing the marker before the ring shape.
private string rivalRouteMarkerFirst(int builtPolygons, int slotCount, int marker) {
    if (marker != 0)                          return "common_tail_no_cap";
    if (builtPolygons == 3 && slotCount == 5) return "tri_cap_family";
    if (builtPolygons == 0)                   return "common_tail_no_cap";
    return "corner_patch";
}

// Selecting on the slot count alone, ignoring the built-polygon count.
private string rivalRouteSlotCountAlone(int builtPolygons, int slotCount, int marker) {
    if (slotCount == 5)     return "tri_cap_family";
    if (marker != 0)        return "common_tail_no_cap";
    if (builtPolygons == 0) return "common_tail_no_cap";
    return "corner_patch";
}

// ===========================================================================
unittest {
    auto fx = fixture();

    // -- provenance, and the population floors -----------------------------
    // A population floor first: every assertion below iterates a cell array,
    // and "passed" also covers "iterated over nothing". Pin the counts before
    // trusting any loop under them.
    assert(fx["provenance"]["method"].str == "static-read",
        "every row here was READ at the reference's own compute sites, not "
      ~ "measured by driving it; the provenance must say so");
    assert(fx["provenance"]["symbols_read"].integer == 7,
        "the read covered seven routines; a fixture that lost some of them is "
      ~ "not the same read");

    auto miter    = fx["miter_interior"];
    auto threeSid = fx["three_sided_interior"];
    auto router   = fx["cap_router_marker_exit"];

    auto schedCells = miter["schedule"]["cells"].array;
    auto blendCells = miter["blend_cells"].array;
    auto routeCells = router["routing_cells"].array;
    assert(schedCells.length == 4,
        format("the schedule must carry its four frozen segment counts, got %s",
               schedCells.length));
    assert(blendCells.length == 4,
        format("the blend must carry its four frozen cells, got %s",
               blendCells.length));
    assert(routeCells.length == 6,
        format("the router must carry its six frozen rings, got %s",
               routeCells.length));

    // =====================================================================
    // Row 17 -- the miter interior.
    // =====================================================================

    // The law reproduces the frozen schedule.
    int schedChecked = 0;
    foreach (c; schedCells) {
        const int n = cast(int) c["round_segments"].integer;
        auto want = c["weights"].array;
        auto got = miterSchedule(n);
        assert(got.length == want.length,
            format("schedule n=%s: expected %s weights, law produced %s",
                   n, want.length, got.length));
        foreach (i, w; want)
            assert(fabs(got[i] - num(w)) < 1e-15,
                format("schedule n=%s sample %s: frozen %.17g, law %.17g",
                       n, i, num(w), got[i]));
        ++schedChecked;
    }
    assert(schedChecked == 4, "every frozen schedule cell must have been checked");

    // Neither end is ever reached. This is the property that makes the two
    // rival schedules wrong in KIND, not merely in value: they duplicate a
    // vertex the rail routine has already placed.
    foreach (c; schedCells) {
        const int n = cast(int) c["round_segments"].integer;
        foreach (s; miterSchedule(n)) {
            assert(s > 0.0 && s < 1.0,
                format("schedule n=%s produced %.17g, which lands ON an end; "
                     ~ "the interior schedule must never reach either", n, s));
        }
    }

    // The rival schedules must DISAGREE on every frozen cell.
    foreach (c; schedCells) {
        const int n = cast(int) c["round_segments"].integer;
        auto mine = miterSchedule(n);
        auto rivalA = rivalScheduleIOverN(n);
        auto rivalB = rivalScheduleIMinusOneOverN(n);
        bool differsA = false, differsB = false;
        foreach (i; 0 .. mine.length) {
            if (fabs(mine[i] - rivalA[i]) > 1e-15) differsA = true;
            if (fabs(mine[i] - rivalB[i]) > 1e-15) differsB = true;
        }
        assert(differsA,
            format("schedule n=%s does not separate the law from the i/n "
                 ~ "rival -- this cell proves nothing about the schedule", n));
        assert(differsB,
            format("schedule n=%s does not separate the law from the (i-1)/n "
                 ~ "rival -- this cell proves nothing about the schedule", n));
    }

    // The blend reproduces the frozen interior points.
    int blendChecked = 0, blendSeparating = 0;
    foreach (c; blendCells) {
        const V3 a = vec(c["first_rail_point"]);
        const V3 b = vec(c["second_rail_point"]);
        const double s = num(c["blend_weight"]);
        const V3 want = vec(c["interior_point"]);
        const V3 got = miterInterior(a, b, s);
        assert(maxAbsDiff(got, want) < 1e-15,
            format("blend cell '%s': frozen [%.17g %.17g %.17g], law "
                 ~ "[%.17g %.17g %.17g]", c["name"].str,
                   want[0], want[1], want[2], got[0], got[1], got[2]));
        ++blendChecked;

        // A and B must differ in EVERY component, or a componentwise
        // transposition of the blend survives the cell unseen.
        foreach (k; 0 .. 3)
            assert(fabs(a[k] - b[k]) > 1e-9,
                format("blend cell '%s' component %s: the two rail points "
                     ~ "coincide there, so this cell cannot see an error on "
                     ~ "that axis", c["name"].str, k));

        // Every rival must produce something else -- except on the cell that
        // declares itself inert, which is excluded rather than counted.
        const bool inert = ("inert_because" in c.object) !is null;
        if (!inert) {
            assert(maxAbsDiff(rivalRailDrivesInterior(a, b, s), want) > 1e-9,
                format("blend cell '%s': the 'rail alone drives the interior' "
                     ~ "rival reproduces the frozen point, so this cell does "
                     ~ "not refute it", c["name"].str));
            assert(maxAbsDiff(rivalMidpoint(a, b, s), want) > 1e-9,
                format("blend cell '%s': the midpoint rival reproduces the "
                     ~ "frozen point, so this cell does not refute it",
                       c["name"].str));
            ++blendSeparating;
        }
    }
    assert(blendChecked == 4, "every frozen blend cell must have been checked");
    assert(blendSeparating == 3,
        format("three of the four blend cells must separate the law from both "
             ~ "rivals; only %s did. The fourth is the s = 1/2 cell, which "
             ~ "cannot and says so.", blendSeparating));

    // The second rail's parameter is 1-s, and on this schedule it is NEVER 1.0
    // -- which is precisely the earlier reading this read corrects.
    foreach (c; schedCells) {
        const int n = cast(int) c["round_segments"].integer;
        foreach (s; miterSchedule(n)) {
            const double p = secondRailParameter(s);
            assert(fabs(p - rivalSecondRailAtOne(s)) > 1e-12,
                format("second rail parameter at s=%.17g is %.17g, which "
                     ~ "coincides with the refuted 'always 1.0' reading -- "
                     ~ "this schedule value cannot tell them apart", s, p));
            assert(p > 0.0 && p < 1.0,
                format("second rail parameter %.17g must also stay off both "
                     ~ "ends", p));
        }
    }

    // The negation of the direction handed to the second rail call. A direction
    // with a zero component would leave that axis untested, so require none.
    const V3 dir = [0.25, -0.5, 0.75];
    const V3 neg = negated(dir);
    foreach (k; 0 .. 3) {
        assert(fabs(dir[k]) > 1e-12,
            "the probe direction must have no zero component, or the negation "
          ~ "is untested on that axis");
        assert(neg[k] == -dir[k],
            format("component %s must be negated exactly", k));
        assert(neg[k] != dir[k],
            format("component %s is unchanged by the negation, so this probe "
                 ~ "cannot distinguish a negated direction from a copied one", k));
    }

    assert(miter["interior_is_a_linear_blend_of_two_rail_evaluations"].boolean,
        "the interior is a blend of TWO rail evaluations; a model in which the "
      ~ "rail draws the interior directly is a different construction");
    assert(miter["blend_weight_is_the_insertion_parameter"].boolean,
        "the blend weight and the mid-vertex insertion parameter are the same "
      ~ "value, not two independently computed ones");
    assert(miter["second_rail_parameter_is_one_minus_s"].boolean,
        "the second rail evaluation is taken at 1-s");
    assert(miter["second_rail_contexts_are_swapped"].boolean,
        "the two rail calls exchange their two context pointers");
    assert(miter["second_rail_direction_input_is_negated"].boolean,
        "the second call's direction input is the first call's output negated");

    // The correction this read carries must stay in the file with its reason.
    auto corr = miter["corrects_a_previously_recorded_reading"];
    assert(corr["why_it_was_wrong"].str.length > 40,
        "the reason the earlier reading was wrong is the part that stops it "
      ~ "being re-derived; it must stay");
    assert(corr["why_that_was_wrong"].str.length > 40,
        "the second correction needs its reason on file too");

    // =====================================================================
    // Row 20 -- the three-sided interior.
    // =====================================================================

    assert(threeSid["sides"].integer == 3, "the three-sided path has three sides");
    assert(threeSid["patches_emitted"].integer == 3,
        "the three-sided path emits THREE patches; a model that emits one "
      ~ "triangular patch is a different construction, not a simplification");
    assert(!threeSid["emits_one_triangular_patch"].boolean,
        "the one-triangular-patch rival must stay recorded as refuted");
    assert(threeSid["interior_hub_vertices"].integer == 1,
        "the three patches meet at exactly ONE interior hub");
    assert(threeSid["interior_control_points_per_side"].integer == 2,
        "two interior control points per side");
    assert(threeSid["interior_control_points_total"].integer
             == threeSid["interior_control_points_per_side"].integer
              * threeSid["sides"].integer,
        "the interior control point total must be the per-side count times the "
      ~ "side count -- if these drift apart the read has been edited, not "
      ~ "corrected");
    assert(threeSid["interior_control_points_are_contiguous"].boolean,
        "the six interior points are one contiguous array, which is what "
      ~ "identifies them as 2-per-side rather than three unrelated pairs");
    assert(threeSid["shared_internal_boundary"].boolean,
        "the three quads share their internal boundaries, which is what keeps "
      ~ "the split watertight");

    assert(threeSid["closure_precondition"]["endpoint_equality_tests"].integer == 3,
        "one endpoint equality test per side");
    assert(threeSid["closure_precondition"]["failure_is_silent"].boolean,
        "a closure failure returns no patch AT ALL, and silently -- a caller "
      ~ "that expects an error will not see one");
    assert(threeSid["dispatch"]["minimum_sides"].integer == 3,
        "fewer than three sides is refused outright");
    assert(threeSid["dispatch"]["three_is_a_separate_routine"].boolean,
        "three sides and four-or-more are different code, not one routine with "
      ~ "a parameter");

    // The dominant divisor must actually be among the divisors present.
    const long dom = threeSid["dominant_divisor"].integer;
    bool domPresent = false;
    foreach (d; threeSid["divisors_present"].array)
        if (d.integer == dom) domPresent = true;
    assert(domPresent,
        format("the dominant divisor %s must be one of the divisors present", dom));
    assert(dom == 3, "the split is built on a three-fold average");

    // =====================================================================
    // Row 22 -- the cap router's marker exit.
    // =====================================================================

    assert(!router["marker_exit_builds_a_cap"].boolean,
        "the marker exit builds NO cap");
    assert(router["marker_exit_additional_faces"].integer == 0,
        "the marker exit adds zero faces -- it is a branch to the common tail, "
      ~ "so whatever the earlier per-slot loop built is all there is");
    assert(router["marker_exit_is_a_decline_not_a_builder_family"].boolean,
        "the marker exit is a DECLINE; recording it as a third builder family "
      ~ "would send a port looking for geometry that is never constructed");
    assert(router["common_tail_is_unique"].boolean,
        "there is one common tail and every successful return passes it");

    auto tof = router["three_of_five_exit"];
    assert(tof["is_a_conjunction"].boolean,
        "the shape-selected exit needs BOTH fields");
    assert(!tof["goes_to_the_n_sided_patch_builder"].boolean,
        "that exit is served by a different builder family; the N-sided patch "
      ~ "construction is never reached on it");

    // The law reproduces every frozen ring's route.
    int routeChecked = 0;
    foreach (c; routeCells) {
        const int bp = cast(int) c["built_polygons"].integer;
        const int sc = cast(int) c["slot_count"].integer;
        const int mk = cast(int) c["marker"].integer;
        const string want = c["route"].str;
        const string got = capRoute(bp, sc, mk);
        assert(got == want,
            format("ring '%s' (built=%s slots=%s marker=%s): frozen route %s, "
                 ~ "law produced %s", c["name"].str, bp, sc, mk, want, got));
        ++routeChecked;
    }
    assert(routeChecked == 6, "every frozen ring must have been routed");

    // The ONE-FIELD pair: two rings identical but for the slot count must land
    // in two different routes. This is what refutes a uniform cap model.
    JSONValue five, six;
    int paired = 0;
    foreach (c; routeCells) {
        if (c["name"].str == "three_of_five")               { five = c; ++paired; }
        if (c["name"].str == "three_of_six_ONE_FIELD_APART") { six  = c; ++paired; }
    }
    assert(paired == 2, "the one-field pair must both survive in the fixture");
    assert(five["built_polygons"].integer == six["built_polygons"].integer
        && five["marker"].integer == six["marker"].integer,
        "the pair must agree in every field EXCEPT the slot count, or it is "
      ~ "not a one-field comparison");
    assert(five["slot_count"].integer != six["slot_count"].integer,
        "the pair must differ in the slot count");
    assert(capRoute(3, cast(int) five["slot_count"].integer, 0)
        != capRoute(3, cast(int) six["slot_count"].integer, 0),
        "two rings identical but for the vertex's slot count must leave by "
      ~ "different exits; a model that routes every cap ring uniformly is not "
      ~ "a simplification of this, it is a different construction");

    // The two gates' ORDER is load-bearing, and one cell exists to pin it.
    assert(capRoute(3, 5, 1) == "tri_cap_family",
        "the ring shape is tested BEFORE the marker, so a set marker does not "
      ~ "divert a three-of-five ring");
    assert(rivalRouteMarkerFirst(3, 5, 1) != capRoute(3, 5, 1),
        "the marker-first rival must disagree somewhere, or the gate ORDER is "
      ~ "unpinned and either order would pass");

    // And the slot-count-alone rival must disagree too.
    bool slotAloneDiffers = false;
    foreach (c; routeCells) {
        const int bp = cast(int) c["built_polygons"].integer;
        const int sc = cast(int) c["slot_count"].integer;
        const int mk = cast(int) c["marker"].integer;
        if (rivalRouteSlotCountAlone(bp, sc, mk) != capRoute(bp, sc, mk))
            slotAloneDiffers = true;
    }
    assert(slotAloneDiffers,
        "the 'slot count alone' rival agrees with the law on every frozen "
      ~ "ring, so the corpus does not pin the conjunction");

    // -- the read's own boundary stays on file -----------------------------
    assert(fx["what_this_read_did_not_settle"].array.length >= 4,
        "the read's boundary must stay in the file, so the next pass starts "
      ~ "from what is open rather than from a guess");
}
