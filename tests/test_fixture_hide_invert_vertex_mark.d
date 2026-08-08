// Frozen reference behaviour — the vertex hide plane is derived
// INCREMENTALLY, over the elements a hide operation touches, so a hide-invert
// leaves exactly the contradicted entries stale.
// Fixture: tests/fixtures/hide_invert_vertex_mark.json.
//
// THIS IS A KNOWN DIVERGENCE. vibe3d's invert is a plain polygon flip that
// ignores the selection type, and its vertex plane is re-derived TOTALLY
// after every mutation — so it has no stale window at all. Task 0628 owns
// the gap.
//
// HOW A DIVERGENCE IS MARKED HERE. This project's marker for a documented
// gap is the reference-diff suites' `expected_fail`, whose contract is: a
// disagreement is tolerated (XFAIL), and an AGREEMENT is a real failure
// (XPASS — "the gap is closed and the marker should be removed"). This test
// ports that contract into the ordinary gate lane rather than skipping:
//   * it pins what vibe3d does TODAY, so a regression is red;
//   * it asserts the result still DIFFERS from the reference's frozen set,
//     so the day 0628 lands the test goes red saying the gap CLOSED and this
//     fixture must be converted to a live parity assertion.
// Flipping `classification.expected_divergence` to false in the fixture
// switches this test over to demanding parity — retiring the marker is a
// one-line edit, and nothing here has to be rewritten to notice.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
//   * The two agreement rows (prefix, and clear-then-re-hide) discriminate
//     against a broken hide/read path outright: an engine that dropped the
//     mark reads an empty hidden set where they demand [0,9] and [0]. They
//     are here so "everything differs" cannot be why the divergence
//     assertions pass — the channel is shown able to AGREE.
//   * The divergence assertion discriminates against a component-typed
//     invert, which reads the nine grid polygons [0..8] where the flat
//     polygon flip reads eight [1..8].
//   * The total-derivation assertion discriminates against a stored vertex
//     bit: after the invert, a stored plane would leave the probe vertex
//     reading 1 (its value from before the invert) where a derived plane
//     reads 0.

import std.net.curl;
import std.json;
import std.conv      : to;
import std.format    : format;
import std.algorithm : sort, canFind, equal;
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

int[] jIntArray(JSONValue v) {
    int[] r;
    foreach (e; v.array) r ~= cast(int) e.integer;
    return r;
}

int[] hiddenFaces() {
    int[] r;
    foreach (i, b; getJson("/api/model")["faceHidden"].array)
        if (b.type == JSONType.true_) r ~= cast(int) i;
    return r;
}

bool[] vertexHidden() {
    bool[] r;
    foreach (b; getJson("/api/model")["vertexHidden"].array) r ~= b.type == JSONType.true_;
    return r;
}

int probeVertexHidden(int probe) { return vertexHidden()[probe] ? 1 : 0; }

string sIdx(int[] v) {
    string s = "[";
    foreach (i, x; v) { if (i) s ~= ","; s ~= x.to!string; }
    return s ~ "]";
}

void selectPolys(int[] idx) {
    string body_ = `{"mode":"polygons","indices":[`;
    foreach (i, x; idx) { if (i) body_ ~= ","; body_ ~= x.to!string; }
    postOk("/api/select", body_ ~ "]}");
}

unittest {
    enum string fixtureJson = import("fixtures/hide_invert_vertex_mark.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "hide_invert_vertex_mark");

    auto rig  = fx["rig"];
    auto cls  = fx["classification"];
    auto ours = cls["vibe3d_measured"];
    immutable int probe = cast(int) rig["probe_vertex"].integer;

    // ---- fixture self-consistency: the non-discriminating row is not evidence
    {
        immutable string nonDisc = fx["non_discriminating"]["id"].str;
        foreach (r; fx["conclusion"]["refuted"].array)
            foreach (by; r["refuted_by"].array)
                assert(by.str != nonDisc,
                       "the trigger that did not discriminate must never be cited as "
                       ~ "refuting a reading: " ~ nonDisc);
        bool found = false;
        foreach (row; fx["rows"].array) if (row["id"].str == nonDisc) found = true;
        assert(!found, "the non-discriminating trigger must be recorded apart from the "
                       ~ "evidence rows, not among them");
    }

    // ---- build the rig ------------------------------------------------------
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    {
        JSONValue mesh = JSONValue(["vertices": rig["vertices"], "faces": rig["faces"]]);
        postOk("/api/load-mesh", mesh.toString);
    }

    // ---- the rig's premise, asserted, not assumed ---------------------------
    // A probe vertex with more than one incident polygon still has a visible
    // polygon and is hidden under NEITHER reading, which would make the whole
    // fixture vacuous.
    {
        auto model = getJson("/api/model");
        auto faces = model["faces"].array;
        assert(model["vertices"].array.length == rig["vertices"].array.length,
               "rig vertex count");
        assert(faces.length == rig["faces"].array.length, "rig face count");

        int valence = 0;
        foreach (f; faces)
            foreach (vi; f.array) if (cast(int) vi.integer == probe) { ++valence; break; }
        assert(valence == cast(int) rig["probe_vertex_valence"].integer,
               format("probe vertex %d must have valence %d, got %d — %s",
                      probe, rig["probe_vertex_valence"].integer, valence,
                      rig["probe_vertex_valence_is_load_bearing"].str));

        assert(jIntArray(faces[0]) == jIntArray(rig["grid_polygon_0_vertices"]),
               "the probe vertex's polygon must be the one the fixture names");
    }

    // ---- AGREEMENT ROW 1: the prefix's hide ---------------------------------
    // Both engines agree here. This is what stops the divergence assertions
    // below from passing merely because the channel is broken.
    {
        selectPolys([0, 9]);
        assert(jIntArray(getJson("/api/selection")["selectedFaces"]).sort.array == [0, 9],
               "both polygons must actually be selected before the hide");
        cmd(`{"id":"mesh.hide"}`);

        auto wantF = jIntArray(fx["prefix"]["after_hide"]["hidden_polygons"]);
        auto gotF  = hiddenFaces();
        assert(gotF == wantF,
               format("prefix hide: hidden polygons %s, want %s (reference AND vibe3d agree "
                      ~ "on this row — a mismatch means the hide path itself is broken, "
                      ~ "not that the divergence moved)", sIdx(gotF), sIdx(wantF)));

        immutable int wantV = cast(int) fx["prefix"]["after_hide"]["probe_vertex_hidden"].integer;
        immutable int gotV  = probeVertexHidden(probe);
        assert(gotV == wantV,
               format("prefix hide: probe vertex reads %d, want %d", gotV, wantV));
        assert(cast(int) ours["after_hide"]["probe_vertex_hidden"].integer == wantV
               && ours["after_hide"]["agrees_with_reference"].type == JSONType.true_,
               "fixture premise: this row is recorded as an agreement row");
    }

    // ---- the invert ---------------------------------------------------------
    cmd(`{"id":"mesh.hideInvert"}`);

    immutable bool expectDivergence = cls["expected_divergence"].type == JSONType.true_;
    auto refAfterInvert  = jIntArray(fx["prefix"]["after_invert"]["hidden_polygons"]);
    auto oursAfterInvert = jIntArray(ours["after_invert"]["hidden_polygons"]);
    auto gotAfterInvert  = hiddenFaces();

    if (expectDivergence) {
        // (a) the marker itself, checked FIRST — red when the gap CLOSES, so a
        // convergence reports as a convergence rather than as a regression.
        assert(gotAfterInvert != refAfterInvert,
               format("DIVERGENCE CLOSED: post-invert hidden polygons %s now equal the "
                      ~ "reference's frozen %s. This is not a breakage — task %s has "
                      ~ "landed. %s",
                      sIdx(gotAfterInvert), sIdx(refAfterInvert),
                      cls["divergence_owner"].str, cls["retire_when"].str));

        // (b) pin what we do today — any OTHER deviation is a regression.
        assert(gotAfterInvert == oursAfterInvert,
               format("post-invert hidden polygons %s, want vibe3d's frozen %s. The invert "
                      ~ "here is a flat polygon flip: the two originally-hidden polygons "
                      ~ "become visible and the other eight become hidden.",
                      sIdx(gotAfterInvert), sIdx(oursAfterInvert)));
    } else {
        // The marker was retired: demand parity outright.
        assert(gotAfterInvert == refAfterInvert,
               format("post-invert hidden polygons %s, want the reference's %s "
                      ~ "(expected_divergence is false, so parity is required)",
                      sIdx(gotAfterInvert), sIdx(refAfterInvert)));
    }

    // ---- our positive statement: the vertex plane is TOTALLY derived --------
    // The reference leaves stale entries; we never do. Asserting the derived
    // predicate over every vertex that has an incident face states our law
    // directly instead of only noting the absence of theirs. A stored vertex
    // bit would leave the probe vertex reading 1 here (its pre-invert value).
    {
        auto model  = getJson("/api/model");
        auto faces  = model["faces"].array;
        auto fHid   = model["faceHidden"].array;
        auto vHid   = vertexHidden();

        bool[] hasFace = new bool[](vHid.length);
        bool[] allHid  = new bool[](vHid.length);
        allHid[] = true;
        foreach (fi, f; faces) {
            immutable bool fh = fHid[fi].type == JSONType.true_;
            foreach (vi; f.array) {
                auto v = cast(size_t) vi.integer;
                hasFace[v] = true;
                if (!fh) allHid[v] = false;
            }
        }
        foreach (v; 0 .. vHid.length) {
            if (!hasFace[v]) continue;   // a loose point keeps its own bit
            assert(vHid[v] == allHid[v],
                   format("vertex %d reads %s but every-incident-polygon-hidden is %s — "
                          ~ "vibe3d's vertex plane is derived TOTALLY after every mutation, "
                          ~ "so it must never be stale. A stale entry here would mean we "
                          ~ "had acquired the reference's incremental behaviour by accident "
                          ~ "rather than by task %s.",
                          v, vHid[v], allHid[v], cls["divergence_owner"].str));
        }
        assert(probeVertexHidden(probe)
               == cast(int) ours["after_invert"]["probe_vertex_hidden"].integer,
               "post-invert probe vertex must read what vibe3d's frozen row says");
    }

    // ---- AGREEMENT ROW 2: clear, then re-hide the probe's polygon -----------
    // The one trigger row whose end state the two engines reach identically.
    {
        cmd(`{"id":"mesh.unhideAll"}`);
        assert(hiddenFaces().length == 0, "unhide-all must clear the hidden set");

        selectPolys([0]);
        cmd(`{"id":"mesh.hide"}`);

        auto wantF = jIntArray(ours["clear_then_rehide"]["hidden_polygons"]);
        auto gotF  = hiddenFaces();
        assert(gotF == wantF,
               format("clear-then-re-hide: hidden polygons %s, want %s", sIdx(gotF), sIdx(wantF)));
        assert(probeVertexHidden(probe)
               == cast(int) ours["clear_then_rehide"]["probe_vertex_hidden"].integer,
               "clear-then-re-hide: probe vertex must read 1 again");

        // and it agrees with the reference's own row of the same name
        foreach (row; fx["rows"].array)
            if (row["id"].str == "clear_then_rehide") {
                assert(jIntArray(row["hidden_polygons_after"]) == gotF,
                       format("clear-then-re-hide is an agreement row: reference %s vs "
                              ~ "vibe3d %s", sIdx(jIntArray(row["hidden_polygons_after"])),
                              sIdx(gotF)));
                assert(cast(int) row["probe_vertex_after"].integer == probeVertexHidden(probe),
                       "clear-then-re-hide: probe vertex agrees with the reference too");
            }
    }
}
