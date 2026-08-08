// Frozen reference behaviour — subdividing a cage with a hidden face keeps
// the hiding as exactly ONE hidden face, because the hidden face is EXCLUDED
// FROM THE OPERATION rather than merely preserved (21 polygons, not 24).
// Fixture: tests/fixtures/subdivide_hidden_face.json.
//
// MIXED VERDICT. Two rows match live, one diverges, one is unrepresentable.
// vibe3d's subdivision has no hide awareness of its own: it carries the hide
// bit onto whatever it produces, so a hidden face that IS refined hands the
// bit to all four children. Task 0632 owns the gap. The divergence is marked
// with the same self-retiring contract as the reference-diff suites'
// `expected_fail`: a disagreement is tolerated, an AGREEMENT is a failure
// that says the marker should be removed. Flipping
// `classification.expected_divergence` to false in the fixture switches the
// diverging row over to demanding parity.
//
// WHAT WRONG IMPLEMENTATION EACH ASSERTION DISCRIMINATES AGAINST
// ---------------------------------------------------------------
//   * all-selected row: an implementation that DROPS the mark across the
//     bake reads 0 hidden where this demands 1; one that splits it across
//     children reads 4. The fixture freezes all three numbers because a test
//     asserting only "hiding did not get lost" passes under two of them.
//   * one-visible-face row: same three-way split at a different polygon
//     count (9). The surviving face's index is 4 here and 5 in the
//     reference — output ordering, not semantics — so the REFERENCE's index
//     is not a parity requirement, but OURS is pinned at 4 as an
//     ordering-regression guard.
//   * nothing-selected row: an implementation that excludes hidden faces
//     from the operand — i.e. the 0632 fix — reads 21 polygons / 1 hidden
//     where today's reads 24 / 4.
//   * undo row: an undo that restores the geometry but not the mark reads 6
//     polygons with 0 hidden.

import std.net.curl;
import std.json;
import std.conv      : to;
import std.format    : format;
import std.algorithm : sort;
import std.array     : array;

import fixture_helpers : requireProvenance;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void postOk(string path, string body_) {
    auto j = parseJSON(cast(string) post(baseUrl ~ path, body_));
    assert(j["status"].str == "ok", path ~ " failed: " ~ j.toString);
}

struct Snap { size_t polys; int[] hidden; }

Snap snap() {
    auto m = getJson("/api/model");
    Snap s;
    s.polys = m["faces"].array.length;
    foreach (i, b; m["faceHidden"].array)
        if (b.type == JSONType.true_) s.hidden ~= cast(int) i;
    return s;
}

string sIdx(int[] v) {
    string s = "[";
    foreach (i, x; v) { if (i) s ~= ","; s ~= x.to!string; }
    return s ~ "]";
}

void selectPolys(int[] idx) {
    string b = `{"mode":"polygons","indices":[`;
    foreach (i, x; idx) { if (i) b ~= ","; b ~= x.to!string; }
    postOk("/api/select", b ~ "]}");
}

size_t selectedFaceCount() {
    return getJson("/api/selection")["selectedFaces"].array.length;
}

/// Reset to the cage, hide the face the fixture names, and assert the mark
/// landed. Every branch re-runs this from scratch.
void buildRigAndHide(JSONValue rig) {
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    JSONValue mesh = JSONValue(["vertices": rig["vertices_list"], "faces": rig["faces"]]);
    postOk("/api/load-mesh", mesh.toString);

    immutable int hf = cast(int) rig["hidden_face"].integer;
    selectPolys([hf]);
    cmd(`{"id":"mesh.hide"}`);

    auto s = snap();
    assert(s.polys == cast(size_t) rig["polygons"].integer,
           format("cage has %d polygons, got %d", rig["polygons"].integer, s.polys));
    assert(s.hidden == [hf],
           format("control: the mark must be there before any bake — hidden %s, want [%d]",
                  sIdx(s.hidden), hf));
}

JSONValue rowById(JSONValue fx, string id) {
    foreach (r; fx["rows"].array) if (r["id"].str == id) return r;
    assert(false, "fixture has no row '" ~ id ~ "'");
}

unittest {
    enum string fixtureJson = import("fixtures/subdivide_hidden_face.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "subdivide_hidden_face");

    auto rig  = fx["rig"];
    auto cls  = fx["classification"];
    auto ours = cls["vibe3d_measured"];

    // ---- the fixture's own arithmetic must discriminate ---------------------
    // If "dropped", "preserved as one" and "preserved and subdivided" did not
    // read three different numbers, no assertion below would mean anything.
    {
        auto c = fx["counts_that_separate_the_readings"];
        immutable long dropped  = c["dropped"].integer;
        immutable long asOne    = c["preserved_as_one"].integer;
        immutable long asFour   = c["preserved_and_subdivided"].integer;
        assert(dropped != asOne && asOne != asFour && dropped != asFour,
               "the three readings must predict three different hidden counts");
    }

    // ---- AGREEMENT ROW 1: everything selected -------------------------------
    // Live parity, index included. Also pins the count-of-selected fact: the
    // hidden face cannot be selected, so "select everything" yields five.
    {
        auto row = rowById(fx, "all_selected");
        buildRigAndHide(rig);

        selectPolys([0, 1, 2, 3, 4, 5]);
        immutable size_t nSel = selectedFaceCount();
        assert(nSel == cast(size_t) row["select_all_yields"].integer,
               format("selecting every polygon must yield %d, not %d — %s",
                      row["select_all_yields"].integer, nSel, row["select_all_note"].str));

        cmd(`{"id":"mesh.subdivide"}`);
        auto s = snap();
        assert(s.polys == cast(size_t) row["polygons_after"].integer,
               format("all-selected bake: %d polygons, want %d",
                      s.polys, row["polygons_after"].integer));
        assert(s.hidden.length == cast(size_t) row["hidden_after"].integer,
               format("all-selected bake: %d hidden, want %d (0 would mean the mark was "
                      ~ "dropped, %d that it was split across children)",
                      s.hidden.length, row["hidden_after"].integer,
                      fx["counts_that_separate_the_readings"]["preserved_and_subdivided"].integer));
        assert(s.hidden == [cast(int) row["hidden_index_after"].integer],
               format("all-selected bake: hidden %s, want [%d]",
                      sIdx(s.hidden), row["hidden_index_after"].integer));
        assert(ours["all_selected"]["agrees_with_reference"].type == JSONType.true_,
               "fixture premise: this row is recorded as an agreement row");
    }

    // ---- AGREEMENT ROW 2: one visible face selected (counts only) -----------
    {
        auto row = rowById(fx, "one_visible_face_selected");
        buildRigAndHide(rig);

        selectPolys([1]);
        assert(selectedFaceCount() == 1, "exactly one visible face selected");

        cmd(`{"id":"mesh.subdivide"}`);
        auto s = snap();
        assert(s.polys == cast(size_t) row["polygons_after"].integer,
               format("one-visible-face bake: %d polygons, want %d",
                      s.polys, row["polygons_after"].integer));
        assert(s.hidden.length == cast(size_t) row["hidden_after"].integer,
               format("one-visible-face bake: %d hidden, want %d",
                      s.hidden.length, row["hidden_after"].integer));
        // The REFERENCE's index (row["hidden_index_after"], 5) is not asserted
        // — it is output ordering, not semantics. OURS is, so an ordering
        // change shows up as a change rather than sliding through. See the
        // fixture's why_one_visible_face_index_is_pinned_to_ours.
        assert(s.hidden == [cast(int) ours["one_visible_face_selected"]["hidden_index_after"].integer],
               format("one-visible-face bake: vibe3d's surviving hidden index is frozen as "
                      ~ "%d (the reference's is %d — ordering, not semantics); got %s",
                      ours["one_visible_face_selected"]["hidden_index_after"].integer,
                      row["hidden_index_after"].integer, sIdx(s.hidden)));
    }

    // ---- DIVERGING ROW: nothing selected ------------------------------------
    {
        auto row  = rowById(fx, "nothing_selected");
        auto mine = ours["nothing_selected"];
        buildRigAndHide(rig);

        selectPolys([]);
        assert(selectedFaceCount() == 0, "nothing selected at the bake");

        cmd(`{"id":"mesh.subdivide"}`);
        auto s = snap();

        immutable bool expectDivergence = cls["expected_divergence"].type == JSONType.true_;
        immutable size_t refPolys  = cast(size_t) row["polygons_after"].integer;
        immutable size_t refHidden = cast(size_t) row["hidden_after"].integer;

        if (expectDivergence) {
            // (a) the marker, checked FIRST — red when the gap CLOSES, so a
            // convergence reports as a convergence rather than as a regression.
            assert(!(s.polys == refPolys && s.hidden.length == refHidden),
                   format("DIVERGENCE CLOSED: nothing-selected bake now reads %d polygons / "
                          ~ "%d hidden, matching the reference. This is not a breakage — "
                          ~ "task %s has landed. %s",
                          s.polys, s.hidden.length, cls["divergence_owner"].str,
                          cls["retire_when"].str));

            // (b) pin today's behaviour — any OTHER deviation is a regression.
            assert(s.polys == cast(size_t) mine["polygons_after"].integer,
                   format("nothing-selected bake: %d polygons, want vibe3d's frozen %d "
                          ~ "(the hidden face is refined like any other)",
                          s.polys, mine["polygons_after"].integer));
            assert(s.hidden == { int[] r; foreach (e; mine["hidden_indices_after"].array)
                                   r ~= cast(int) e.integer; return r; }(),
                   format("nothing-selected bake: hidden %s, want vibe3d's frozen %s "
                          ~ "(the hidden parent's four children each inherit the bit)",
                          sIdx(s.hidden), mine["hidden_indices_after"].toString));
        } else {
            assert(s.polys == refPolys && s.hidden.length == refHidden,
                   format("nothing-selected bake: %d polygons / %d hidden, want the "
                          ~ "reference's %d / %d (expected_divergence is false, so parity "
                          ~ "is required)", s.polys, s.hidden.length, refPolys, refHidden));
        }

        // ---- UNDO: one entry, geometry AND mark restored together -----------
        // Asserted on whichever bake the branch above produced; the LAW is
        // what is frozen, the counts follow the branch.
        {
            auto u = fx["undo"];
            postOk("/api/undo", "");
            auto a = snap();
            assert(a.polys == cast(size_t) u["polygons_after_undo"].integer,
                   format("undo: %d polygons, want %d — one entry must take the whole bake",
                          a.polys, u["polygons_after_undo"].integer));
            assert(a.hidden.length == cast(size_t) u["hidden_after_undo"].integer,
                   format("undo: %d hidden, want %d — an undo that restored the geometry "
                          ~ "without the mark would read 0 here",
                          a.hidden.length, u["hidden_after_undo"].integer));
            assert(a.hidden == [cast(int) rig["hidden_face"].integer],
                   format("undo: the restored mark must be on the originally hidden face, "
                          ~ "got %s", sIdx(a.hidden)));
        }
    }
}
