// Frozen reference behaviour — subdividing a cage with a hidden face keeps
// the hiding as exactly ONE hidden face, because the hidden face is EXCLUDED
// FROM THE OPERATION rather than merely preserved (21 polygons, not 24).
// Fixture: tests/fixtures/subdivide_hidden_face.json.
//
// MARKER RETIRED 2026-08-09 — the divergence closed and this file now demands
// parity. Task 0632 landed ("subdivide: hidden faces leave the operand, and
// the mark survives the rebuild"): hidden faces are excluded from the
// subdivision operand and the mark survives the rebuild, so the nothing-
// selected branch went from 24 polygons / 4 hidden to 21 / 1 at index 20.
// The marker fired exactly as it was built to — a disagreement was tolerated,
// the AGREEMENT was the failure, and it reported itself as `DIVERGENCE
// CLOSED` rather than as a breakage. `classification.expected_divergence` is
// now false and the row is a live parity assertion.
//
// The retirement is not a licence to stop checking. Flipping the flag back to
// true does NOT silence a regression: the marker branch then demands a
// disagreement we no longer have, and fails just as loudly as the parity
// branch would. Both branches are live and both are exercised by the flag.
//
// WHAT STILL LEGITIMATELY DIFFERS, AND WHY IT IS SAID RATHER THAN UPDATED
// -----------------------------------------------------------------------
//   * one-visible-face row: the surviving hidden face's INDEX is 4 here and 5
//     in the reference. Re-measured after 0632 and unchanged — output
//     ordering, not semantics. The REFERENCE's index is therefore not a
//     parity requirement; OURS is pinned at 4 as an ordering-regression
//     guard.
//   * "only the hidden face selected" is unrepresentable here: a hidden face
//     cannot be selected, so the attempt degenerates into the nothing-
//     selected branch (21 / 1) where the reference's own row is a 6 / 1
//     no-op. The SELECTION is inexpressible; the operand law is not.
//
// WHAT WRONG IMPLEMENTATION EACH ASSERTION DISCRIMINATES AGAINST
// ---------------------------------------------------------------
//   * all-selected row: an implementation that DROPS the mark across the
//     bake reads 0 hidden where this demands 1; one that splits it across
//     children reads 4. The fixture freezes all three numbers because a test
//     asserting only "hiding did not get lost" passes under two of them.
//   * one-visible-face row: same three-way split at a different polygon
//     count (9).
//   * nothing-selected row: THE row that tests the law. It is the only branch
//     where nothing but the exclusion rule can produce 21 — the all-selected
//     row reached 21 by the selection mask even before 0632. An
//     implementation that hands the operand to the kernel unmasked reads
//     24 / 4 (the pre-0632 reading); one that rebuilds the mesh and loses the
//     mark reads 21 / 0.
//   * undo row: an undo that restores the geometry but not the mark reads 6
//     polygons with 0 hidden.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv      : to;
import std.format    : format;
import std.algorithm : sort;
import std.array     : array;

import fixture_helpers : requireProvenance;

void main() {}

alias baseUrl = testBaseUrl;


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
    postOk("/api/command", commandBody("mesh.select", b ~ "]}"));
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
    postOk("/api/command", commandBody("scene.loadMesh", mesh.toString));

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

    // ---- the marker flag must be a BOOLEAN ----------------------------------
    // `expected_divergence` selects which contract the nothing-selected row
    // runs under, and it is read as `.type == JSONType.true_`. Anything that is
    // not a JSON boolean — `"false"`, `0`, a typo'd key left behind — reads as
    // "not true" and would silently select a branch nobody chose. Since the
    // marker is now RETIRED that branch is the parity one, so the failure mode
    // is quiet rather than loud: exactly the reason to check the type itself.
    {
        auto flag = cls["expected_divergence"];
        assert(flag.type == JSONType.true_ || flag.type == JSONType.false_,
               format("classification.expected_divergence must be a JSON boolean, got %s "
                      ~ "(%s) — a non-boolean reads as \"not true\" and silently selects "
                      ~ "the parity branch", flag.toString, flag.type));
    }

    // ---- the retirement is recorded in BOTH places, or in neither -----------
    // With the marker retired, `vibe3d_measured.nothing_selected` stops driving
    // any assertion below: the parity branch compares against the REFERENCE
    // row. That is precisely how frozen data rots. Tie the two together so the
    // recorded measurement has to keep saying what the live assertion demands.
    {
        auto refRow = rowById(fx, "nothing_selected");
        auto mine   = ours["nothing_selected"];
        immutable bool marked = cls["expected_divergence"].type == JSONType.true_;
        immutable bool same   = mine["polygons_after"].integer == refRow["polygons_after"].integer
                             && mine["hidden_after"].integer   == refRow["hidden_after"].integer;
        assert(marked != same,
               format("the marker flag and the recorded measurement disagree: "
                      ~ "expected_divergence is %s but vibe3d_measured.nothing_selected "
                      ~ "reads %d/%d against the reference's %d/%d. A marked divergence "
                      ~ "must record DIFFERENT numbers and a retired one must record the "
                      ~ "SAME ones — otherwise the fixture keeps a stale reading nothing "
                      ~ "checks.",
                      marked, mine["polygons_after"].integer, mine["hidden_after"].integer,
                      refRow["polygons_after"].integer, refRow["hidden_after"].integer));
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

    // ---- THE LAW ROW (marker retired): nothing selected ---------------------
    // The only branch where nothing but the exclusion rule can reach 21 — the
    // all-selected row reached it through the selection mask even before 0632.
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
            // RETIRED BRANCH, kept live. It is unreachable in a green tree —
            // re-arming the flag makes (a) and (b) mutually unsatisfiable, since
            // `vibe3d_measured.nothing_selected` now records the reference's own
            // numbers — so re-arming cannot be used to silence a regression. The
            // pre-0632 readings it used to pin live on in the fixture's
            // `was_while_open`.
            //
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
            // MARKER RETIRED — parity, and parity down to the surviving face's
            // INDEX. The counts alone do not separate "the hidden face was left
            // out of the operand" from "the hidden face was refined and three of
            // its four children lost the bit": both read 21 / 1. The index does
            // — an untouched face carried through last lands at 20.
            assert(s.polys == refPolys,
                   format("nothing-selected bake: %d polygons, want the reference's %d "
                          ~ "(expected_divergence is false, so parity is required). 24 "
                          ~ "would mean the hidden face was handed to the kernel as part "
                          ~ "of the operand again.", s.polys, refPolys));
            assert(s.hidden.length == refHidden,
                   format("nothing-selected bake: %d hidden, want the reference's %d. 0 "
                          ~ "would mean the rebuild dropped the mark, 4 that the hidden "
                          ~ "face was refined and every child inherited the bit.",
                          s.hidden.length, refHidden));
            assert(s.hidden == [cast(int) row["hidden_index_after"].integer],
                   format("nothing-selected bake: hidden %s, want the reference's [%d] — "
                          ~ "the excluded face is carried through after the refined ones, "
                          ~ "so it lands last. A matching COUNT at a different index would "
                          ~ "mean some other face ended up marked.",
                          sIdx(s.hidden), row["hidden_index_after"].integer));
        }

        // ---- UNDO: one entry, geometry AND mark restored together -----------
        // Asserted on whichever bake the branch above produced; the LAW is
        // what is frozen, the counts follow the branch.
        {
            auto u = fx["undo"];
            // What the undo is undoing. Frozen on OUR side because it follows
            // whichever bake the branch above produced (21 since 0632, 24 while
            // the marker stood) — asserted so that number cannot go stale
            // unnoticed the way it did when 0632 landed.
            assert(s.polys == cast(size_t) ours["undo"]["polygons_before_undo"].integer,
                   format("undo: the bake being undone left %d polygons, but the fixture "
                          ~ "freezes %d as vibe3d's pre-undo count",
                          s.polys, ours["undo"]["polygons_before_undo"].integer));
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
