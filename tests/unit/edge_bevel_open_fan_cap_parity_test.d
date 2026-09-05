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
// than let a divergence close silently. Note which of the two is about
// openness: only the first. The K>=3 cell is flat because the notch-plan site
// records a cap interior at `K == 2` and nothing wider, a gate with no
// `openFan` term in it at all -- so a CLOSED K>=3 fan gets the same flat cap.
// It is a divergence in its own right, not a shape this capture's boundary
// excludes.
//
// WHAT THE FIXTURE WITNESSES, AND WHAT IS TRANSCRIBED BY HAND. Every driven
// parameter comes OUT of the fixture: `parameters.cells[].drove` carries the
// op, mode, width and round level per cell, and this cell reads them rather
// than restating them. The cell NAME carries the rest of the setup -- open vs
// closed, K, the round level again, and (where it says so) whether the
// selected spokes are interior or on the rim -- and every one of those is
// checked against what is built here. What is NOT in the fixture is WHICH rim
// ids the spokes are, so that one list stays hand-written; it is checked
// structurally instead, by counting each selected spoke's incident polygons
// on the built fan (two = interior, one = rim). That check is what makes
// `open_fan_K3_L1`'s spokes demonstrably interior rather than merely asserted
// to be.
//
// THE THRESHOLD IS NOT READ OFF THE MEASUREMENT IT JUDGES. `kTol` is 1e-5,
// and both of its margins were measured before the number was written down:
// the three matching cells come in at 6.0e-8, 6.0e-8 and 7.0e-9 worst, which
// is float32 round-off on a coordinate of magnitude ~1, so 1e-5 sits two
// decades above the noise; and the smallest genuine divergence anywhere in
// this corpus is 0.0218 (the K=3 cell; the boundary cell is 0.0618), so it
// sits three decades below the nearest real difference.
//
// MUTATIONS (each seen red under `dub test --config=tests` — the task card
// carries the verbatim lines, the reddened line numbers and the module
// counts, all re-quoted from that gate and not from a hand-built harness):
//   * restore `!openFan &&` on the free-end cap guard in
//     `source/mesh_ops/edge_bevel.d` (i.e. half the fix) -> the first open
//     cell reddens on the VERTEX-SET compare, not the face one: with the
//     refusal back the mesh is untouched, so the arity check inside
//     `compareToDump` short-circuits and the bijection assert is the one that
//     speaks. `closed_fan_K2_interior_L1` ABOVE it stays green, which is why
//     the closed control is first in the table.
//   * delete one cell from the fixture -> the population floor reddens: five
//     driven cells is five, not "whatever the file happened to carry".
//   * permute two corners BETWEEN two faces of `open_fan_K2_interior_L1` in
//     the fixture, leaving its `vertices` alone -> the FACE-SET assert is the
//     one that reddens, with the vertex-set assert directly above it green.
//     Without this edit that assert has never been seen to fail, and a face
//     compare that silently agreed with everything would look identical.
//   * replace a diverging cell's dump with our own output -> the closure
//     assert reddens, so "these two still differ" is not vacuously true.
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

/// The op that PRODUCED a cell, read out of the fixture's own parameter block
/// instead of restated here — see the header on what is witnessed and what is
/// transcribed.
private JSONValue droveOf(JSONValue fx, string cell) {
    foreach (e; fx["parameters"]["cells"].array)
        if (e["cell"].str == cell) {
            assert(e["drove"].array.length == 1,
                format("%s: the parameter block must record exactly one driven "
                     ~ "op, found %s", cell, e["drove"].array.length));
            return e["drove"].array[0];
        }
    assert(false, "the fixture's parameter block must carry the cell " ~ cell);
}

/// What the cell NAME itself says about its setup. The name is fixture data,
/// so anything decoded here is a public witness for the transcription below.
private struct NameFacts {
    bool   closedFan;
    size_t k;
    int    level;
    bool   namesInterior;
    bool   namesBoundary;
}

private NameFacts factsFromName(string name) {
    import std.algorithm : canFind, startsWith;
    import std.conv      : to;
    import std.string    : indexOf;
    NameFacts f;
    f.closedFan = name.startsWith("closed_fan_");
    assert(f.closedFan || name.startsWith("open_fan_"),
        "a cell name must say which fan it is: " ~ name);
    immutable ptrdiff_t ki = name.indexOf("_K");
    assert(ki >= 0 && ki + 3 <= name.length,
        "a cell name must carry its K: " ~ name);
    f.k = name[ki + 2 .. ki + 3].to!size_t;
    immutable ptrdiff_t li = name.indexOf("_L");
    assert(li >= 0 && li + 3 <= name.length,
        "a cell name must carry its round level: " ~ name);
    f.level = name[li + 2 .. li + 3].to!int;
    f.namesInterior = name.canFind("_interior");
    f.namesBoundary = name.canFind("_boundary");
    return f;
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
        uint[] spokes;   // rim vertex ids whose hub spoke is selected
        bool   mustMatch;
    }
    // ORDER IS LOAD-BEARING. The closed control is first, so a mutation that
    // breaks only the open-fan path leaves a green assert above the red one
    // and a single run shows both halves.
    //
    // Only the spoke ids are transcribed; the fan's openness and the round
    // level come from the cell NAME and the width and mode from the fixture's
    // parameter block, all checked below.
    static immutable Cell[] cells = [
        Cell("closed_fan_K2_interior_L1", [2u, 4u],     true),
        Cell("open_fan_K2_interior_L1",   [2u, 4u],     true),
        Cell("open_fan_K2_interior_L0",   [2u, 4u],     true),
        Cell("open_fan_K2_boundary_L1",   [1u, 3u],     false),
        Cell("open_fan_K3_L1",            [2u, 3u, 4u], false),
    ];

    size_t matched = 0, diverged = 0, interiorOnlyCells = 0, rimCells = 0;
    foreach (c; cells) {
        auto dump = caseNamed(fx, c.name);

        // Setup and op, out of the fixture rather than restated.
        immutable NameFacts nf = factsFromName(c.name);
        assert(nf.k == c.spokes.length,
            format("%s: the cell name says K=%s but %s spokes are listed",
                   c.name, nf.k, c.spokes.length));
        auto drove = droveOf(fx, c.name);
        assert(drove["op"].str == "edge_bevel",
            format("%s: the parameter block must record an edge_bevel, got %s",
                   c.name, drove["op"].str));
        assert(drove["values"]["mode"].str == "inset",
            format("%s: this corpus is inset-mode throughout, got %s",
                   c.name, drove["values"]["mode"].str));
        immutable int   level = cast(int) num(drove["values"]["level"]);
        immutable float width = cast(float) num(drove["values"]["width"]);
        assert(level == nf.level,
            format("%s: the parameter block drove L%s but the name says L%s",
                   c.name, level, nf.level));

        auto m = valence5Fan(nf.closedFan);
        auto mask = new bool[](m.edges.length);
        size_t selected = 0;
        // Interior vs rim, DERIVED: an interior hub spoke borders two of this
        // fan's polygons, a rim spoke exactly one. `edgePolygonCounts` counts
        // straight off `faces[]`, so it cannot undercount the way a ring walk
        // can. This is what makes `open_fan_K3_L1`'s spokes demonstrably
        // interior instead of merely described as such.
        auto epc = m.edgePolygonCounts();
        size_t rimSpokes = 0;
        foreach (s; c.spokes) {
            bool found = false;
            foreach (i; 0 .. m.edges.length)
                if ((m.edges[i][0] == 0u && m.edges[i][1] == s) ||
                    (m.edges[i][1] == 0u && m.edges[i][0] == s)) {
                    mask[i] = true; found = true; ++selected;
                    assert(epc[i] == 1 || epc[i] == 2,
                        format("%s: hub spoke 0-%s borders %s polygons on this "
                             ~ "fan, which is neither a rim nor an interior "
                             ~ "spoke", c.name, s, epc[i]));
                    if (epc[i] == 1) ++rimSpokes;
                    break;
                }
            assert(found, format("%s: the fan must carry the hub spoke 0-%s",
                                 c.name, s));
        }
        assert(selected == c.spokes.length,
            format("%s: every named spoke must be in the mask", c.name));
        if (nf.namesInterior)
            assert(rimSpokes == 0,
                format("%s: the name says the selection is INTERIOR, but %s of "
                     ~ "its %s spokes border only one polygon",
                       c.name, rimSpokes, c.spokes.length));
        if (nf.namesBoundary)
            assert(rimSpokes >= 1,
                format("%s: the name says the selection touches the BOUNDARY, "
                     ~ "but every one of its %s spokes is interior",
                       c.name, c.spokes.length));
        if (rimSpokes == 0) ++interiorOnlyCells; else ++rimCells;

        immutable size_t processed = bevelOnce(m, mask, width, level);
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
            // row instead of deleting this branch. The two are open for
            // DIFFERENT reasons: the rim cell is outside what this capture
            // settles (no closed twin), while the K>=3 cell is a divergence of
            // its own that has nothing to do with openness -- see its pin
            // below.
            assert(!a.facesAgree,
                format("%s: this shape now MATCHES the capture -- so either "
                     ~ "re-measure and close its register row, or the cell is "
                     ~ "no longer driving what it names; a divergence must not "
                     ~ "close unrecorded", c.name));
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
        // NOT a consequence of the fan being open, and the tally below says
        // so: every spoke here is interior. The ground is the notch-plan gate
        // in `source/mesh_ops/edge_bevel.d`, which records a cap interior at
        // `K == 2` and at no wider K, and which carries no `openFan` term --
        // so a CLOSED K>=3 fan gets the same flat cap. Its own register row,
        // not row 21's remainder.
        if (c.name == "open_fan_K3_L1")
            assert(m.vertices.length == 18 && m.faces.length == 11,
                format("%s: we build 18v/11f (one flat cap) against the "
                     ~ "capture's 20v/14f; got %sv/%sf -- the K>=3 cap "
                     ~ "interior moved, so re-measure register row 22",
                       c.name, m.vertices.length, m.faces.length));
    }

    // TWO tallies, and this one is FIRST on purpose: a row dropped from the
    // table above reddens the partition, which says what the corpus is made
    // of, before it reddens the match count, which only says how it came out.
    //
    // Exactly one of the five driven cells selects a spoke on the rim; the
    // other four have every selected spoke interior -- `open_fan_K3_L1` among
    // them, counted from `edgePolygonCounts` on the built fan and not from its
    // name. That is the number behind the header's claim that the K>=3
    // divergence is not a boundary effect: there is no boundary spoke in it.
    assert(rimCells == 1 && interiorOnlyCells == 4,
        format("exactly one driven cell may select a rim spoke -- counted %s "
             ~ "rim-touching and %s all-interior", rimCells, interiorOnlyCells));

    // The match tally, so "every cell agreed" cannot be read off a loop that
    // ran over fewer cells than the corpus has.
    assert(matched == 3 && diverged == 2 && matched + diverged == cells.length,
        format("five driven cells: three that match the capture and two that "
             ~ "do not -- counted %s matching and %s diverging",
               matched, diverged));
}
