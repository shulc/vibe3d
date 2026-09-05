// OUR SIDE of the open-fan bevel cap, against the frozen dumps in
// `tests/fixtures/edge_bevel_open_fan_cap.json` (task 4335, register row 21).
//
// WHAT THIS IS AND WHAT ITS SIBLING IS. `edge_bevel_open_fan_cap_test.d` reads
// that fixture and nothing else: it pins the LAW, and it stayed green through
// this whole task because it never touched vibe3d. This cell is the other
// half — it BUILDS each captured shape here and compares our result to the
// dump, so the fixture stops being target geometry and becomes the regression
// lock for the code that now meets it.
//
// THE ORDER TRAP, and it is why an implementation can look wrong while being
// right. The open fan's result carries the SAME sixteen points as the closed
// fan's in a DIFFERENT emission order (the sibling's own assert prints the
// permutation: indices 3,4,5 arrive as 5,3,4, index-wise 0.19 apart). Our
// emission order is a third order again, and no rule says it should match
// either dump's. So every comparison below is a SET comparison: a
// nearest-neighbour map plus a claim tally, which is a bijection when every
// vertex is claimed exactly once — never an index-wise diff.
//
// WHAT THE CAPTURE COVERS, stated as the boundary it actually has. The
// open/closed identity was measured for INTERIOR selected spokes. Three cells
// here match the reference vertex-for-vertex and face-for-face; the other two
// do NOT and are asserted to still diverge, with their counts, because they
// are shapes the capture does not settle:
//   * `open_fan_K2_boundary_L1` — a selected spoke ON the rim. Register row 21
//     names this as the part that stays open: there is no closed twin for it
//     and the reference's cap there is a different one.
//   * `open_fan_K3_L1` — three adjacent spokes, whose cap INTERIOR routes
//     through the builder register row 22 records as undecoded. Our K>=3 fan
//     keeps the flat cap by the deliberate rule at the notch-plan site.
// Those two asserts are closure assertions: if a later change makes either
// match, this cell reddens and says to re-measure and close the row rather
// than let a divergence close silently.
//
// THE THRESHOLD IS NOT READ OFF THE MEASUREMENT IT JUDGES. `kTol` is 1e-5,
// and both of its margins were measured before the number was written down:
// the three matching cells come in at 6.0e-8, 6.0e-8 and 7.0e-9 worst, which
// is float32 round-off on a coordinate of magnitude ~1, so 1e-5 sits two
// decades above the noise; and the smallest genuine divergence anywhere in
// this corpus is 0.0218 (the K=3 cell; the boundary cell is 0.0618), so it
// sits three decades below the nearest real difference.
//
// MUTATIONS (each seen red — the task card carries the verbatim lines):
//   * restore `!openFan &&` on the free-end cap guard in
//     `source/mesh_ops/edge_bevel.d` (i.e. half the fix) -> the two
//     `open_fan_K2_interior_*` cells redden on their face-set compare, while
//     `closed_fan_K2_interior_L1` ABOVE them stays green. One run buys both
//     halves, which is why the closed control is first in the table.
//   * delete one cell from the fixture -> the population floor reddens: five
//     driven cells is five, not "whatever the file happened to carry".
module tests.unit.edge_bevel_open_fan_cap_parity_test;

import std.file   : readText;
import std.format : format;
import std.json;
import std.math   : sqrt;

import mesh;
import math;

private enum string kFixture = "tests/fixtures/edge_bevel_open_fan_cap.json";

/// See the header: two decades above this corpus's float32 noise (6.0e-8) and
/// three below its smallest real divergence (0.0218), not read off the
/// numbers it grades.
private enum double kTol = 1e-5;

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private JSONValue caseNamed(JSONValue fx, string want) {
    foreach (c; fx["cases"].array)
        if (c["name"].str == want) return c;
    assert(false, "the fixture must keep the case " ~ want);
}

private alias V3 = double[3];

private V3[] verticesOf(JSONValue cell) {
    V3[] outv;
    foreach (p; cell["vertices"].array)
        outv ~= [num(p.array[0]), num(p.array[1]), num(p.array[2])];
    return outv;
}

private double dist(V3 a, V3 b) {
    const double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// The planar valence-5 fan the whole corpus is built on: a hub at the origin
// and five rim points on the unit circle. `closedFan` keeps the base polygon
// [0,5,1]; dropping it is what puts the hub on a BOUNDARY (5 spokes, 4 faces,
// so the fan walk sees nE == d + 1). Same numbers as the private
// reference-comparison cases that produced the dumps.
private Mesh valence5Fan(bool closedFan) {
    static immutable double[3][6] P = [
        [ 0.0,                 0.0,                 0.0],
        [ 1.0,                 0.0,                 0.0],
        [ 0.30901699437494745, 0.9510565162951535,  0.0],
        [-0.8090169943749473,  0.5877852522924732,  0.0],
        [-0.8090169943749476, -0.587785252292473,   0.0],
        [ 0.30901699437494723,-0.9510565162951536,  0.0],
    ];
    Mesh m;
    foreach (p; P)
        m.vertices ~= Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]);
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.addFace([0u, 3u, 4u]);
    m.addFace([0u, 4u, 5u]);
    if (closedFan) m.addFace([0u, 5u, 1u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private size_t bevelOnce(ref Mesh m, const bool[] mask, float width, int roundLevel) {
    auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
    immutable size_t n = ed.bevelEdgesByMask(mask, width, roundLevel, false);
    ed.close();
    return n;
}

private struct Agreement {
    double worst;       // worst distance from one of ours to its nearest reference point
    bool   bijection;   // ...and every reference point claimed exactly once
    bool   facesAgree;  // face sets equal once our vertices are read in reference indices
}

// Set comparison, never an index-wise one — see the header's order trap.
private Agreement compareToDump(ref Mesh m, JSONValue cell) {
    const V3[] rv = verticesOf(cell);
    V3[] ov;
    foreach (v; m.vertices) ov ~= [cast(double)v.x, cast(double)v.y, cast(double)v.z];

    Agreement a;
    a.worst = 0.0;
    if (ov.length != rv.length) { a.bijection = false; a.facesAgree = false; a.worst = double.max; return a; }

    auto image  = new size_t[](ov.length);
    auto claims = new int[](rv.length);
    foreach (i, p; ov) {
        size_t bestJ = 0;
        double best  = double.max;
        foreach (j, q; rv) {
            const double d = dist(p, q);
            if (d < best) { best = d; bestJ = j; }
        }
        image[i] = bestJ;
        ++claims[bestJ];
        if (best > a.worst) a.worst = best;
    }
    a.bijection = true;
    foreach (n; claims) if (n != 1) { a.bijection = false; break; }

    // Faces, translated into the reference's own vertex numbering through that
    // map and compared as unordered corner SETS: winding and start corner are
    // emission details, membership is not.
    string[] ourFaces, refFaces;
    static string keyOf(size_t[] ids) {
        import std.algorithm : sort;
        import std.conv : to;
        auto s = ids.dup;
        s.sort();
        string k;
        foreach (x; s) k ~= x.to!string ~ ",";
        return k;
    }
    foreach (f; m.faces) {
        size_t[] ids;
        foreach (vi; f) ids ~= image[vi];
        ourFaces ~= keyOf(ids);
    }
    foreach (f; cell["faces"].array) {
        size_t[] ids;
        foreach (vi; f.array) ids ~= cast(size_t) num(vi);
        refFaces ~= keyOf(ids);
    }
    import std.algorithm : sort;
    ourFaces.sort();
    refFaces.sort();
    a.facesAgree = a.bijection && (ourFaces == refFaces);
    return a;
}

unittest // our open-fan cap is the captured one, on every shape the capture settles
{
    auto fx = parseJSON(readText(kFixture));

    // Population floor FIRST: the corpus this cell drives is a fixed five, so
    // a fixture that lost a cell cannot pass by having nothing to disagree
    // with. (The sixth cell is the harness control, which the sibling reader
    // owns; it is not driven here.)
    assert(fx["cases"].array.length == 6,
        format("the fixture must carry its six captured cells, found %s",
               fx["cases"].array.length));

    struct Cell {
        string name;
        bool   closedFan;
        uint[] spokes;   // rim vertex ids whose hub spoke is selected
        int    level;
        bool   mustMatch;
    }
    // ORDER IS LOAD-BEARING. The closed control is first, so a mutation that
    // breaks only the open-fan path leaves a green assert above the red one
    // and a single run shows both halves.
    static immutable Cell[] cells = [
        Cell("closed_fan_K2_interior_L1", true,  [2u, 4u],     1, true),
        Cell("open_fan_K2_interior_L1",   false, [2u, 4u],     1, true),
        Cell("open_fan_K2_interior_L0",   false, [2u, 4u],     0, true),
        Cell("open_fan_K2_boundary_L1",   false, [1u, 3u],     1, false),
        Cell("open_fan_K3_L1",            false, [2u, 3u, 4u], 1, false),
    ];

    size_t matched = 0, diverged = 0;
    foreach (c; cells) {
        auto dump = caseNamed(fx, c.name);
        auto m = valence5Fan(c.closedFan);
        auto mask = new bool[](m.edges.length);
        size_t selected = 0;
        foreach (s; c.spokes) {
            bool found = false;
            foreach (i; 0 .. m.edges.length)
                if ((m.edges[i][0] == 0u && m.edges[i][1] == s) ||
                    (m.edges[i][1] == 0u && m.edges[i][0] == s)) {
                    mask[i] = true; found = true; ++selected; break;
                }
            assert(found, format("%s: the fan must carry the hub spoke 0-%s",
                                 c.name, s));
        }
        assert(selected == c.spokes.length,
            format("%s: every named spoke must be in the mask", c.name));

        immutable size_t processed = bevelOnce(m, mask, 0.1f, c.level);
        auto a = compareToDump(m, dump);

        if (c.mustMatch) {
            // The refusal is gone: the op must actually run. This is the
            // assert that was red for the three open cells before task 4335 —
            // `processed` was 0 and the mesh was untouched.
            assert(processed == c.spokes.length,
                format("%s: the bevel must process all %s selected spokes, "
                     ~ "processed %s -- an open fan is no longer refused "
                     ~ "(task 4335, register row 21)",
                       c.name, c.spokes.length, processed));
            assert(a.bijection && a.worst <= kTol,
                format("%s: our vertices must be the captured ones as a SET "
                     ~ "(never index-wise -- the emission orders differ) -- "
                     ~ "worst nearest-neighbour distance %s, bijection %s, "
                     ~ "%s of ours against %s captured",
                       c.name, a.worst, a.bijection,
                       m.vertices.length, dump["vertices"].array.length));
            assert(a.facesAgree,
                format("%s: the face sets must agree once our vertices are "
                     ~ "read in the capture's numbering -- %s of ours against "
                     ~ "%s captured", c.name,
                       m.faces.length, dump["faces"].array.length));
            ++matched;
        } else {
            // Closure assertion. These two shapes are OPEN rows, not silent
            // failures: if either starts matching, re-measure and close the
            // row instead of deleting this branch.
            assert(!a.facesAgree,
                format("%s: this shape now MATCHES the capture -- the capture "
                     ~ "does not settle it (a spoke on the rim has no closed "
                     ~ "twin; a K>=3 cap interior is register row 22's "
                     ~ "undecoded builder), so re-measure and close the row "
                     ~ "rather than let a divergence close unrecorded",
                       c.name));
            ++diverged;
        }

        // What we build for the two open rows, pinned so the divergence
        // cannot drift unnoticed. Measured 2026-09-05 at the same widths and
        // levels the capture used.
        if (c.name == "open_fan_K2_boundary_L1")
            assert(m.vertices.length == 12 && m.faces.length == 7,
                format("%s: we build 12v/7f against the capture's 15v/10f; "
                     ~ "got %sv/%sf -- the boundary-touching cap moved, so "
                     ~ "re-measure register row 21's open half",
                       c.name, m.vertices.length, m.faces.length));
        if (c.name == "open_fan_K3_L1")
            assert(m.vertices.length == 18 && m.faces.length == 11,
                format("%s: we build 18v/11f (one flat cap) against the "
                     ~ "capture's 20v/14f; got %sv/%sf -- the K>=3 cap "
                     ~ "interior moved, so re-measure register row 22",
                       c.name, m.vertices.length, m.faces.length));
    }

    // The tally, so "every cell agreed" cannot be read off a loop that ran
    // over fewer cells than the corpus has.
    assert(matched == 3 && diverged == 2 && matched + diverged == cells.length,
        format("five driven cells: three the capture settles and two it does "
             ~ "not -- counted %s matching and %s diverging", matched, diverged));
}
