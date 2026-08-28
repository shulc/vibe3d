// Frozen-fixture cell for four reference laws read STATICALLY off the
// reference editor's own unstripped libraries (task 2680, capture campaign
// batch A): the Edge Statistics "Coplanar" predicate, the Vertex Statistics
// "Colinear" predicate, the selection-rollover pick-flag word, and the
// topological-symmetry seam selection-set name.
//
// WHY IT EXISTS, and it is the same reason twice. Two of these four rows
// already had behavioural evidence, and in both cases the evidence COULD NOT
// HAVE COME OUT DIFFERENTLY:
//
//   * Coplanar was measured on one cell only, a straight box split. Its two
//     faces are EXACTLY coplanar, so the routine's max plane distance is 0
//     and it returns early -- the tolerance comparison is never executed at
//     all. That cell passes under every tolerance, under a relative rule and
//     under an absolute one, and under any normal convention.
//   * Colinear was run against a mesh with no 2-valent vertex anywhere,
//     because three attempts to insert one were refused by the command lane.
//     The predicate carries a second, structural conjunct -- exactly two
//     neighbouring vertices -- so on that mesh it is false everywhere for
//     reasons that have nothing to do with geometry. Its empty answer was
//     equally consistent with "the predicate is right" and "the predicate
//     never fires".
//
// Reading each routine at its own compute site needs neither a coplanar
// tolerance sweep nor a 2-valent vertex.
//
// WHAT IT PINS. The laws, and the arithmetic. The geometric predicates below
// are implemented from the DECODED ROUTINES and share no code with the
// generator that wrote the fixture, so a cell reddens from both sides: change
// a frozen row and the row check fails; change the law and every row of that
// block fails.
//
// WHAT IT DOES NOT PIN. Nothing in vibe3d. We ship neither predicate --
// `source/mesh_stats.d`'s EdgeStat/VertexStat carry no coplanar, colinear or
// uv-boundary member -- and we ship no rollover mode and no symmetry seam
// name. This cell exists so that whoever implements one of them starts from
// the measured law instead of re-deriving it from a stand that cannot fail.
module tests.unit.stat_predicate_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, sqrt, fmin, fmax;
import std.format : format;

private enum string kFixture = "tests/fixtures/stat_predicates_read.json";

private double asDouble(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private double[3] asVec(JSONValue v) {
    assert(v.type == JSONType.array && v.array.length == 3, "fixture: want a 3-vector");
    return [asDouble(v.array[0]), asDouble(v.array[1]), asDouble(v.array[2])];
}

private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(readText(kFixture)); loaded = true; }
    return cached;
}

private double[3] sub(double[3] a, double[3] b) {
    return [a[0]-b[0], a[1]-b[1], a[2]-b[2]];
}
private double[3] cross(double[3] a, double[3] b) {
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
}
private double dot(double[3] a, double[3] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
private double[3] unit(double[3] a) {
    const double n = sqrt(dot(a, a));
    return [a[0]/n, a[1]/n, a[2]/n];
}

/// The reference's polygon normal: the RING-INDEX-0 corner triangle,
/// cross(ring[1] - ring[0], ring[$-1] - ring[0]). NOT Newell.
private double[3] cornerTriangleNormal(double[3][] ring) {
    return unit(cross(sub(ring[1], ring[0]), sub(ring[$-1], ring[0])));
}

/// The decoded coplanar predicate. Returns the ratio it compares, plus the
/// verdict; a negative ratio means it returned before comparing anything.
private struct CoplanarResult { bool coplanar; double ratio; string path; }

private CoplanarResult coplanarEdge(double[3][] ring0, double[3][] ring1,
                                    double[3][2] edge, int polyCount, double tol) {
    if (polyCount != 2)
        return CoplanarResult(false, -1.0, "polygon_count_gate");
    const double[3] n = cornerTriangleNormal(ring0);
    const double[3] a = edge[0];
    double dmax = 0.0;
    double[3] lo = a, hi = a;
    foreach (ring; [ring0, ring1]) {
        foreach (p; ring) {
            foreach (k; 0 .. 3) {
                lo[k] = fmin(lo[k], p[k]);
                hi[k] = fmax(hi[k], p[k]);
            }
            if (p == edge[0] || p == edge[1]) continue;
            dmax = fmax(dmax, abs(dot(sub(p, a), n)));
        }
    }
    if (dmax == 0.0) return CoplanarResult(true, -1.0, "early_out_zero_distance");
    double s = 0.0;
    foreach (k; 0 .. 3) s = fmax(s, hi[k] - lo[k]);
    if (s == 0.0) return CoplanarResult(true, -1.0, "early_out_zero_extent");
    const double ratio = dmax / s;
    return CoplanarResult(ratio <= tol, ratio, "ratio_compare");
}

/// Distance to the SEGMENT, clamped -- not to the infinite line.
private double pointSegmentDistance(double[3] p, double[3] a, double[3] b) {
    const double[3] ab = sub(b, a);
    const double denom = dot(ab, ab);
    double t = denom == 0.0 ? 0.0 : dot(sub(p, a), ab) / denom;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const double[3] q = [a[0] + t*ab[0], a[1] + t*ab[1], a[2] + t*ab[2]];
    return sqrt(dot(sub(p, q), sub(p, q)));
}

private double[3][] ringOf(JSONValue v) {
    double[3][] r;
    foreach (p; v.array) r ~= asVec(p);
    return r;
}

// ---------------------------------------------------------------------------
// The Coplanar predicate.
//   MUTATION 1 (the tolerance): change `tol` in the fixture's
//   coplanar_edge.tolerance_default by one ULP and the block reddens on
//   `tilt_exactly_at_tolerance` with "coplanar tolerance".
//   MUTATION 2 (relative -> absolute): drop the `/ s` in coplanarEdge and
//   `scaled_up_100x_RELATIVE_DISCRIMINATOR` reddens while
//   `flat_box_split_THE_INERT_CELL` stays green -- which is the proof that
//   the discriminating cell was chosen rather than fitted.
//   MUTATION 3 (the normal): swap cornerTriangleNormal for a Newell normal
//   and `nonplanar_first_polygon_NORMAL_CONVENTION` reddens on its distance.
unittest {
    auto fx = fixture();
    auto blk = fx["coplanar_edge"];
    const double tol = asDouble(blk["tolerance_default"]);
    assert(blk["tolerance_is_relative"].boolean,
           "coplanar: the fixture must record that the tolerance is RELATIVE");
    assert(blk["requires_exactly_two_incident_polygons"].boolean);

    size_t ratioCells = 0;
    foreach (cell; blk["cells"].array) {
        const string name = cell["name"].str;
        auto ring0 = ringOf(cell["ring0"]);
        auto ring1 = cell["ring1"].array.length ? ringOf(cell["ring1"]) : null;
        auto ev = cell["edge"].array;
        double[3][2] edge = [asVec(ev[0]), asVec(ev[1])];
        const int pc = cast(int) cell["incident_polygon_count"].integer;

        auto got = coplanarEdge(ring0, ring1, edge, pc, tol);
        assert(got.coplanar == cell["expected"].boolean,
               format("coplanar %s: expected %s, got %s (ratio %.17g)",
                      name, cell["expected"].boolean, got.coplanar, got.ratio));
        assert(got.path == cell["path"].str,
               format("coplanar %s: took path %s, fixture froze %s",
                      name, got.path, cell["path"].str));
        if (got.path == "ratio_compare") {
            ratioCells++;
            const double want = asDouble(cell["ratio"]);
            assert(abs(got.ratio - want) <= 1e-12,
                   format("coplanar %s: ratio expected %.17g, got %.17g",
                          name, want, got.ratio));
            const double[3] n = cornerTriangleNormal(ring0);
            const double[3] wn = asVec(cell["normal"]);
            foreach (k; 0 .. 3)
                assert(abs(n[k] - wn[k]) <= 1e-12,
                       format("coplanar %s: normal component %d expected %.17g, got %.17g",
                              name, k, wn[k], n[k]));
        }
    }
    // The inert cell is the point of the block; assert it is actually inert,
    // i.e. that the tolerance comparison is never reached on it.
    bool sawInert = false;
    foreach (cell; blk["cells"].array)
        if (cell["name"].str == "flat_box_split_THE_INERT_CELL") {
            sawInert = true;
            assert(cell["path"].str == "early_out_zero_distance",
                   "the box split must NOT reach the tolerance comparison -- " ~
                   "that is the whole reason this fixture exists");
        }
    assert(sawInert, "the inert cell must stay in the fixture as the control");
    assert(ratioCells >= 4, "too few cells actually exercise the comparison");
}

// ---------------------------------------------------------------------------
// The Colinear predicate.
//   MUTATION 1 (drop the valence conjunct): make expectedSelected depend on
//   the geometric half alone and `valence_three_THE_UNFALSIFIABLE_CELL`
//   reddens -- and nothing else does, which is exactly the shape of the
//   defect the old behavioural stand had.
//   MUTATION 2 (segment -> infinite line): use the unclamped line distance
//   and `beyond_the_chord_SEGMENT_NOT_LINE` reddens.
//   MUTATION 3 (the tolerance): move it one ULP and
//   `offset_exactly_at_tolerance` reddens.
unittest {
    auto fx = fixture();
    auto blk = fx["colinear_vertex"];
    const double tol = asDouble(blk["tolerance_default"]);
    assert(!blk["tolerance_is_relative"].boolean,
           "colinear: this tolerance is ABSOLUTE -- the two Statistics " ~
           "predicates deliberately do not share a convention");
    assert(blk["second_conjunct"].str == "neighbour_vertex_count == 2");

    bool sawValenceVeto = false;
    bool sawSegmentCell = false;
    foreach (cell; blk["cells"].array) {
        const string name = cell["name"].str;
        auto ch = cell["chord"].array;
        const double[3] a = asVec(ch[0]);
        const double[3] b = asVec(ch[1]);
        const double[3] p = asVec(cell["point"]);
        const long nb = cell["neighbour_vertex_count"].integer;

        const double d = pointSegmentDistance(p, a, b);
        const double want = asDouble(cell["distance_to_segment"]);
        assert(abs(d - want) <= 1e-12,
               format("colinear %s: distance to segment expected %.17g, got %.17g",
                      name, want, d));

        const bool geometric = (tol >= d);
        assert(geometric == cell["geometric_half"].boolean,
               format("colinear %s: geometric half expected %s, got %s (d = %.17g)",
                      name, cell["geometric_half"].boolean, geometric, d));

        const bool selected = geometric && (nb == 2);
        assert(selected == cell["expected_selected"].boolean,
               format("colinear %s: selected expected %s, got %s",
                      name, cell["expected_selected"].boolean, selected));

        if (name == "valence_three_THE_UNFALSIFIABLE_CELL") {
            sawValenceVeto = true;
            assert(geometric && !selected,
                   "the control cell must be geometrically colinear AND still " ~
                   "unselected -- otherwise it is not the control");
        }
        if (name == "beyond_the_chord_SEGMENT_NOT_LINE") {
            sawSegmentCell = true;
            const double lineD = asDouble(cell["distance_to_infinite_line"]);
            assert(lineD < d,
                   "the segment cell must have a SMALLER distance to the " ~
                   "infinite line than to the segment, or it separates nothing");
            assert(tol >= lineD,
                   "under an infinite-line port this cell would be colinear -- " ~
                   "that is what makes it discriminating");
        }
    }
    assert(sawValenceVeto, "the valence-3 control must stay in the fixture");
    assert(sawSegmentCell, "the segment-vs-line cell must stay in the fixture");
}

// ---------------------------------------------------------------------------
// The rollover pick-flag word.
//   MUTATION: change `closest` to "0x8001" in the fixture and the
//   decomposition check reddens with the missing component-type bits.
unittest {
    auto fx = fixture();
    auto blk = fx["pick_flags"];

    static uint hex(string s) {
        assert(s.length > 2 && s[0 .. 2] == "0x", "want a 0x-prefixed word: " ~ s);
        uint v = 0;
        foreach (c; s[2 .. $]) {
            v <<= 4;
            if (c >= '0' && c <= '9')      v |= cast(uint)(c - '0');
            else if (c >= 'a' && c <= 'f') v |= cast(uint)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= cast(uint)(c - 'A' + 10);
            else assert(false, "bad hex digit in " ~ s);
        }
        return v;
    }

    const uint manual  = hex(blk["manual_or_none"].str);
    const uint closest = hex(blk["closest"].str);
    const uint extra   = hex(blk["extra_bits"].str);

    assert((closest ^ manual) == extra,
           format("pick flags: closest ^ manual must be the extra bits " ~
                  "(expected %#x, got %#x)", extra, closest ^ manual));

    // The extra bits are exactly the three component-type bits, and NOT a
    // radius, a count, or a search mode. This is the claim the register got
    // wrong, so it is asserted term by term.
    uint componentBits = 0;
    uint allBits = 0;
    foreach (string k, v; blk["decomposition"].object) {
        const uint bit = hex(k);
        allBits |= bit;
        const string nm = v.str;
        if (nm.length > 16 && nm[0 .. 16] == "component type: ") componentBits |= bit;
    }
    assert(componentBits == extra,
           format("pick flags: the extra bits must be exactly the three component " ~
                  "type bits (vertex, edge, polygon) " ~
                  "(expected %#x, got %#x)", extra, componentBits));
    assert(allBits == closest,
           format("pick flags: the decomposition must account for every bit of " ~
                  "the closest word (expected %#x, got %#x)", closest, allBits));

    assert(blk["mode_enum"]["manual"].integer == blk["preference_default"].integer,
           "the shipped default is `manual`");
    assert(blk["hit_test_sites"].integer == 3);
}

// ---------------------------------------------------------------------------
// The topological-symmetry seam selection-set name.
//   MUTATION: change any one of the three frozen names and the
//   letter-arithmetic check reddens on that axis.
unittest {
    auto fx = fixture();
    auto blk = fx["symmetry_seam_set_name"];
    const string prefix = blk["prefix"].str;

    foreach (string axisName, axisIdx; blk["axis_enum"].object) {
        const long i = axisIdx.integer;
        if (i > 2) continue;                 // `arbitrary` was deliberately not read
        const string key = format("%d", i);
        assert(key in blk["names"].object,
               format("no frozen seam name for axis %d", i));
        const string got = blk["names"][key].str;
        const string want = prefix ~ " " ~ cast(char)('x' + i);
        assert(got == want,
               format("symmetry seam name for axis %d: expected %s, got %s",
                      i, want, got));
        assert(want[$-1] == axisName[0],
               format("axis %s must carry its own letter, got %c",
                      axisName, want[$-1]));
    }
    assert(blk["names"].object.length == 3,
           "three axes carry a seam name; `arbitrary` was not read and must " ~
           "not be invented");
}
