// Frozen reference behaviour — the vertex hide plane is derived
// INCREMENTALLY, over the elements a hide operation touches, so a hide-invert
// leaves exactly the contradicted entries stale.
// Fixture: tests/fixtures/hide_invert_vertex_mark.json.
//
// THE SEQUENCE IS PART OF THE MEASUREMENT. The fixture's prefix is three
// steps, not two: hide two polygons WITH THE SELECTION TYPE SET TO POLYGONS,
// then SWITCH THE SELECTION TYPE TO VERTICES, then invert. The reference's
// invert is component-typed, so the middle step is what selects the law being
// frozen — an invert issued in polygon mode is a different measurement.
//
// This test therefore takes both types from the fixture
// (`prefix.selection_type_before_hide` / `..._before_invert`), drives them,
// and READS THEM BACK off /api/selection before continuing. That is not
// belt-and-braces: on the pre-0628 engine the invert ignores the selection
// type, so the polygon set and the probe value are BYTE-IDENTICAL in both
// modes. Measured on this branch, hidden polygons after the invert are
// [1..8] and the probe reads 0 whether the invert runs in polygon mode or in
// vertex mode. No numeric assertion in this file can tell the two apart —
// only the type read-back can, which is why it is an assertion of its own and
// why every assertion below reports the observed type in its message.
//
// TWO DIVERGENCES, SEPARATE STATUSES, AND THEY HAVE NOW MOVED IN OPPOSITE
// DIRECTIONS EXACTLY AS PREDICTED (fixture: `classification.divergences`).
//   * `invert_face_set` — status "closed" since 2026-08-09, owner 0628. The
//     reference hid the nine grid polygons and we hid eight; 0628 made the
//     invert component-typed and the sets converged. A GAP, closed.
//   * `vertex_plane_derivation` — status "permanent". We derive the vertex
//     plane totally after every mutation; the reference derives it
//     incrementally and leaves stale entries. A DELIBERATE decision, never to
//     be closed. Its two frozen numbers used to agree (both 0) for unrelated
//     reasons; closing the first divergence made polygon 0 hidden here too,
//     and the totally-derived probe went to 1 while the reference stays 0.
// They are separate because they move in opposite directions. A single
// expected/not-expected flag over both would, on the day the gap closed, have
// either retired the permanent one with it or refused to retire either.
//
// HOW A DIVERGENCE WAS MARKED HERE. This project's marker for a documented
// gap is the reference-diff suites' `expected_fail`, whose contract is: a
// disagreement is tolerated (XFAIL), and an AGREEMENT is a real failure
// (XPASS — "the gap is closed and the marker should be removed"). This test
// ported that contract into the ordinary gate lane rather than skipping, for
// the face-set divergence only. It fired, and the branch it selects is now
// the parity one. The permanent divergence never had such a branch: the probe
// is only ever compared against vibe3d's own frozen value, never against the
// reference's.
//
// RETIRING WAS A TWO-LINE EDIT AND THE TEST ENFORCED BOTH. Setting
// `invert_face_set.status` to "closed" also required re-freezing
// `vertex_plane_derivation.vibe3d_probe_after_invert` to 1 — the probe read 0
// only while polygon 0 was left visible. The fixture-consistency check below
// derives the probe the frozen face set implies under our OWN total-derivation
// law and fails if the two rows contradict each other, so a half-done
// retirement could not freeze a contradiction. It did not misfire: with the
// status flipped it demanded exactly the 0 → 1 re-freeze, naming it.
//
// A THIRD CONSEQUENCE, RECORDED ONE-SIDED. The same total-derivation decision
// costs us the involution: pressed twice in vertex mode the invert does not
// return ([0,9] → [0..8] → [9]), while in polygon mode it still does. That is
// NOT filed as a third divergence, because a divergence row here carries a
// frozen reference number and no capture ever pressed the reference's invert
// twice — writing one would be inferring a measurement and filing it as
// observed. It is asserted below as a vibe3d-only pair of rows, which is what
// gives `never_close` teeth: an implementation that acquired the reference's
// stale window to chase its 0 would likely restore the involution and go red.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
//   * A DRIVER THAT SKIPS THE TYPE SWITCH — the defect this file was written
//     to close. Deleting the `select.typeFrom` call leaves every number in
//     this test unchanged; the type read-back is the only thing that goes red,
//     and it goes red naming `polygon` where the fixture demands `vertex`.
//   * The two agreement rows (prefix, and clear-then-re-hide) discriminate
//     against a broken hide/read path outright: an engine that dropped the
//     mark reads an empty hidden set where they demand [0,9] and [0]. They
//     are here so "everything differs" cannot be why the divergence
//     assertions pass — the channel is shown able to AGREE.
//   * The face-set marker discriminates against a component-typed invert,
//     which reads the nine grid polygons [0..8] where the flat polygon flip
//     reads eight [1..8].
//   * The total-derivation assertion discriminates against a stored vertex
//     bit: a stored plane would leave some vertex reading its pre-invert
//     value where the derived plane re-reads it from its incident polygons.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv      : to;
import std.format    : format;
import std.algorithm : sort, canFind, equal;
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

// The CURRENT selection type as the singular token the fixture speaks
// (vertex / edge / polygon / item). This is the channel — and on this branch
// the ONLY channel — that separates an invert issued in vertex mode from one
// issued in polygon mode.
string selType() { return getJson("/api/selection")["selType"].str; }

string sIdx(int[] v) {
    string s = "[";
    foreach (i, x; v) { if (i) s ~= ","; s ~= x.to!string; }
    return s ~ "]";
}

void selectPolys(int[] idx) {
    string body_ = `{"mode":"polygons","indices":[`;
    foreach (i, x; idx) { if (i) body_ ~= ","; body_ ~= x.to!string; }
    postOk("/api/command", commandBody("mesh.select", body_ ~ "]}"));
}

unittest {
    enum string fixtureJson = import("fixtures/hide_invert_vertex_mark.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "hide_invert_vertex_mark");

    auto rig  = fx["rig"];
    auto cls  = fx["classification"];
    auto ours = cls["vibe3d_measured"];
    auto div  = cls["divergences"];
    auto dFace = div["invert_face_set"];            // the gap 0628 closes
    auto dVert = div["vertex_plane_derivation"];    // the permanent decision
    immutable int probe = cast(int) rig["probe_vertex"].integer;

    // The two types the prefix names, read as DATA rather than parsed out of
    // its prose, so the driver below cannot describe one sequence and perform
    // another.
    immutable string typeAtHide   = fx["prefix"]["selection_type_before_hide"].str;
    immutable string typeAtInvert = fx["prefix"]["selection_type_before_invert"].str;

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

    // ---- fixture self-consistency: the prefix's type switch is a real switch
    // If the two types were equal the middle step would be a no-op, the
    // read-back below would pass without it having been performed, and this
    // fixture would be unable to say which law it froze — exactly the state
    // this file was rewritten to make impossible.
    assert(typeAtInvert != typeAtHide,
           format("the prefix's step 2 must actually CHANGE the selection type, but it "
                  ~ "names %s before the hide and %s before the invert. With those equal "
                  ~ "the step is vacuous and nothing here distinguishes a typed invert "
                  ~ "from an untyped one.", typeAtHide, typeAtInvert));

    // ---- fixture self-consistency: the two divergences carry usable statuses
    immutable string faceStatus = dFace["status"].str;
    assert(faceStatus == "open" || faceStatus == "closed",
           format("invert_face_set.status must be exactly \"open\" or \"closed\", got "
                  ~ "\"%s\" — a typo must not silently select the parity branch",
                  faceStatus));
    immutable bool faceGapOpen = faceStatus == "open";
    assert(dVert["status"].str == "permanent",
           format("vertex_plane_derivation.status reads \"%s\". That divergence is a "
                  ~ "deliberate design decision and has NO retirement branch here by "
                  ~ "construction: vibe3d's vertex plane is derived totally and the "
                  ~ "reference's incrementally, and we do not intend to acquire its "
                  ~ "stale window. Changing this status does not make the test demand "
                  ~ "parity — it just breaks the guard that says so.",
                  dVert["status"].str));

    // ---- fixture self-consistency: the divergence rows and the narrative rows
    // record the SAME measurement (two copies exist; they must not drift)
    assert(jIntArray(dFace["reference_after_invert"])
           == jIntArray(fx["prefix"]["after_invert"]["hidden_polygons"]),
           "invert_face_set.reference_after_invert must be the same measurement the "
           ~ "prefix's after_invert row records");
    assert(cast(int) dVert["reference_probe_after_invert"].integer
           == cast(int) fx["prefix"]["after_invert"]["probe_vertex_hidden"].integer,
           "vertex_plane_derivation.reference_probe_after_invert must be the same "
           ~ "measurement the prefix's after_invert row records");

    // ---- build the rig ------------------------------------------------------
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    {
        JSONValue mesh = JSONValue(["vertices": rig["vertices"], "faces": rig["faces"]]);
        postOk("/api/command", commandBody("scene.loadMesh", mesh.toString));
    }

    // ---- the rig's premise, asserted, not assumed ---------------------------
    // A probe vertex with more than one incident polygon still has a visible
    // polygon and is hidden under NEITHER reading, which would make the whole
    // fixture vacuous.
    int probeFace = -1;      // the probe's ONE incident polygon
    {
        auto model = getJson("/api/model");
        auto faces = model["faces"].array;
        assert(model["vertices"].array.length == rig["vertices"].array.length,
               "rig vertex count");
        assert(faces.length == rig["faces"].array.length, "rig face count");

        int valence = 0;
        foreach (fi, f; faces)
            foreach (vi; f.array)
                if (cast(int) vi.integer == probe) {
                    ++valence;
                    if (probeFace < 0) probeFace = cast(int) fi;
                    break;
                }
        assert(valence == cast(int) rig["probe_vertex_valence"].integer,
               format("probe vertex %d must have valence %d, got %d — %s",
                      probe, rig["probe_vertex_valence"].integer, valence,
                      rig["probe_vertex_valence_is_load_bearing"].str));

        assert(jIntArray(faces[0]) == jIntArray(rig["grid_polygon_0_vertices"]),
               "the probe vertex's polygon must be the one the fixture names");
    }

    // ---- fixture self-consistency: the two frozen divergence rows agree with
    // each other under vibe3d's OWN law -------------------------------------
    // The probe's only polygon is `probeFace`, so under total derivation the
    // probe reads 1 exactly when that polygon is in our post-invert hidden set.
    // This is what makes retiring the face-set marker a TWO-line edit: flip
    // `invert_face_set.status` and the operative frozen face set becomes the
    // reference's, which contains polygon 0 — and the frozen probe of 0 stops
    // being derivable. Leaving it at 0 freezes a contradiction, and fails here.
    {
        // `vibe3d_after_invert` is what WE do, in either status — so the
        // coupling reads it directly rather than swapping to the reference's
        // row when the status is "closed". That keeps the field live in both
        // states: while the gap was open it had to DIFFER from the reference's,
        // and now that it is closed it has to MATCH. The cross-check just below
        // enforces exactly that, so `vibe3d_after_invert` cannot rot into a
        // stale reading nothing compares against.
        auto oursFrozenFaces = jIntArray(dFace["vibe3d_after_invert"]);
        {
            immutable bool frozenAgree =
                oursFrozenFaces == jIntArray(dFace["reference_after_invert"]);
            assert(frozenAgree == !faceGapOpen,
                   format("invert_face_set.status is \"%s\" but its two frozen face sets "
                          ~ "%s: vibe3d %s vs reference %s. \"open\" must record a "
                          ~ "DISAGREEMENT and \"closed\" an AGREEMENT — otherwise the "
                          ~ "status and the numbers under it are telling different stories.",
                          faceStatus, frozenAgree ? "agree" : "disagree",
                          sIdx(oursFrozenFaces),
                          sIdx(jIntArray(dFace["reference_after_invert"]))));
        }
        immutable int frozenProbe  = cast(int) dVert["vibe3d_probe_after_invert"].integer;
        immutable int impliedProbe = oursFrozenFaces.canFind(probeFace) ? 1 : 0;
        assert(frozenProbe == impliedProbe,
               format("the fixture's two frozen rows contradict each other under vibe3d's "
                      ~ "own total-derivation law: with invert_face_set \"%s\" our "
                      ~ "post-invert hidden set is %s, which %s the probe's only polygon "
                      ~ "%d, so the probe must be frozen as %d — but "
                      ~ "vertex_plane_derivation.vibe3d_probe_after_invert reads %d. If "
                      ~ "you have just retired the face-set marker, this is the second "
                      ~ "half of that edit: re-freeze the probe to %d and LEAVE the "
                      ~ "status \"permanent\" — the reference still reads %d there and "
                      ~ "always will.",
                      faceStatus, sIdx(oursFrozenFaces),
                      impliedProbe ? "contains" : "does not contain",
                      probeFace, impliedProbe, frozenProbe, impliedProbe,
                      cast(int) dVert["reference_probe_after_invert"].integer));
    }

    // ---- AGREEMENT ROW 1: the prefix's hide ---------------------------------
    // Both engines agree here. This is what stops the divergence assertions
    // below from passing merely because the channel is broken.
    {
        selectPolys([0, 9]);
        assert(jIntArray(getJson("/api/selection")["selectedFaces"]).sort.array == [0, 9],
               "both polygons must actually be selected before the hide");

        // Prefix step 1 names the type the hide is issued under. /api/select
        // promotes it as a side effect, so this asserts that side effect landed
        // where the fixture says rather than assuming it.
        assert(selType() == typeAtHide,
               format("prefix step 1 issues the hide with the selection type set to %s, "
                      ~ "but /api/selection reads %s. The polygon select was supposed to "
                      ~ "promote the type; it did not.", typeAtHide, selType()));

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

    // ---- PREFIX STEP 2: switch the selection type ---------------------------
    // The step the first driver of this fixture omitted. It changes no
    // geometry and no number in this file — on this branch the invert ignores
    // the selection type entirely — so it is asserted by READING THE TYPE
    // BACK. That read is the whole discriminator: without it, an invert issued
    // in polygon mode is indistinguishable from the vertex-mode invert the
    // fixture froze, and this test would once again be green about a
    // measurement it never took.
    cmd("select.typeFrom " ~ typeAtInvert);
    immutable string typeBeforeInvert = selType();
    assert(typeBeforeInvert == typeAtInvert,
           format("prefix step 2 switches the selection type to %s before the invert, but "
                  ~ "/api/selection reads %s. The reference's invert is COMPONENT-TYPED: "
                  ~ "an invert issued in %s mode freezes a different law from the one this "
                  ~ "fixture measured, and every number below would be attributed to the "
                  ~ "wrong mode.",
                  typeAtInvert, typeBeforeInvert, typeBeforeInvert));

    // ---- PREFIX STEP 3: the invert ------------------------------------------
    cmd(`{"id":"mesh.hideInvert"}`);

    // The invert READS the selection type; it must not write it. If it did,
    // the mode this fixture's numbers are attributed to would be one the
    // engine had silently left behind.
    assert(selType() == typeAtInvert,
           format("the invert ran with the selection type %s and left it %s — the invert "
                  ~ "must not change the selection type", typeAtInvert, selType()));

    auto refAfterInvert  = jIntArray(dFace["reference_after_invert"]);
    auto oursAfterInvert = jIntArray(dFace["vibe3d_after_invert"]);
    auto gotAfterInvert  = hiddenFaces();

    if (faceGapOpen) {
        // (a) the marker itself, checked FIRST — red when the gap CLOSES, so a
        // convergence reports as a convergence rather than as a regression.
        assert(gotAfterInvert != refAfterInvert,
               format("DIVERGENCE CLOSED: with the selection type %s at the invert, "
                      ~ "post-invert hidden polygons %s now equal the reference's frozen "
                      ~ "%s. This is not a breakage — task %s has landed. %s",
                      typeAtInvert, sIdx(gotAfterInvert), sIdx(refAfterInvert),
                      dFace["owner"].str, dFace["retire_by"].str));

        // (b) pin what we do today — any OTHER deviation is a regression.
        assert(gotAfterInvert == oursAfterInvert,
               format("post-invert hidden polygons %s, want vibe3d's frozen %s (selection "
                      ~ "type at the invert: %s). The invert here is a flat polygon flip "
                      ~ "that ignores that type: the two originally-hidden polygons become "
                      ~ "visible and the other eight become hidden.",
                      sIdx(gotAfterInvert), sIdx(oursAfterInvert), typeAtInvert));
    } else {
        // The face-set marker was retired: demand parity outright. Note this
        // says nothing about the probe — that divergence is permanent and is
        // checked against vibe3d's own frozen value below, never against the
        // reference's.
        assert(gotAfterInvert == refAfterInvert,
               format("post-invert hidden polygons %s, want the reference's %s (selection "
                      ~ "type at the invert: %s; invert_face_set.status is \"closed\", so "
                      ~ "parity is required)",
                      sIdx(gotAfterInvert), sIdx(refAfterInvert), typeAtInvert));
    }

    // ---- our positive statement: the vertex plane is TOTALLY derived --------
    // The reference leaves stale entries; we never do. Asserting the derived
    // predicate over every vertex that has an incident face states our law
    // directly instead of only noting the absence of theirs. This is also what
    // makes the permanent divergence self-enforcing: once the face-set gap
    // closes and the probe's polygon is hidden, this loop alone forces the
    // probe to 1 while the reference stays 0.
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
                   format("vertex %d reads %s but every-incident-polygon-hidden is %s "
                          ~ "(selection type at the invert: %s) — vibe3d's vertex plane is "
                          ~ "derived TOTALLY after every mutation, so it must never be "
                          ~ "stale. A stale entry here would mean we had acquired the "
                          ~ "reference's incremental behaviour by accident rather than "
                          ~ "keeping the derivation task %s left in place.",
                          v, vHid[v], allHid[v], typeAtInvert, dFace["owner"].str));
        }

        immutable int gotProbe    = probeVertexHidden(probe);
        immutable int frozenProbe = cast(int) dVert["vibe3d_probe_after_invert"].integer;
        assert(gotProbe == frozenProbe,
               format("post-invert probe vertex reads %d, fixture freezes %d (selection "
                      ~ "type at the invert: %s). Task %s has LANDED and this number was "
                      ~ "already re-frozen 0 → 1 when it did, so this is a regression, not "
                      ~ "the divergence surfacing: under our total derivation the probe "
                      ~ "must read 1 while polygon %d is hidden. The reference reads %d "
                      ~ "here off a stale entry and always will — do NOT change the "
                      ~ "derivation to chase it (see vertex_plane_derivation.never_close).",
                      gotProbe, frozenProbe, typeAtInvert, dFace["owner"].str, probeFace,
                      cast(int) dVert["reference_probe_after_invert"].integer));
    }

    // ---- THE INVOLUTION CONSEQUENCE — vibe3d-only, ONE-SIDED ----------------
    // The price of the permanent divergence, one press later: re-deriving the
    // vertex plane destroys the distinction the flipped plane carried, so a
    // second vertex-mode invert does not return. Recorded here rather than as a
    // third divergence because the reference half was never captured (see the
    // fixture's why_it_is_NOT_a_third_divergence) — so nothing below is ever
    // compared against a reference number.
    //
    // The POLYGON-mode leg is not decoration: it is what makes the vertex-mode
    // leg a statement about the derivation rather than about a broken invert.
    // An engine whose invert was simply wrong would fail to return in BOTH
    // modes.
    {
        auto inv = dVert["consequence_involution"];
        auto vm  = inv["vibe3d_vertex_mode"];
        auto pm  = inv["vibe3d_polygon_mode"];

        // -- fixture self-consistency ------------------------------------------
        // (1) the reference side must be recorded as ABSENT, never inferred.
        assert(inv["reference_side"].str == "not captured",
               format("consequence_involution.reference_side reads \"%s\". The reference's "
                      ~ "double invert was never captured; the only honest value here is "
                      ~ "\"not captured\". Do not derive one from the frozen incremental "
                      ~ "law and file it as measured.", inv["reference_side"].str));
        foreach (k; ["reference_after_invert_2", "reference_is_involution"])
            assert(k !in inv,
                   "consequence_involution must carry no reference_* measurement: `"
                   ~ k ~ "` would be an inference filed as an observation");

        // (2) each mode's `is_involution` flag must follow from its OWN numbers,
        // so the flag cannot drift away from the rows it summarises.
        foreach (mode; [vm, pm]) {
            immutable bool returned =
                jIntArray(mode["after_invert_2"]) == jIntArray(mode["after_hide"]);
            assert(returned == (mode["is_involution"].type == JSONType.true_),
                   format("a recorded mode claims is_involution=%s but its own numbers say "
                          ~ "%s: after_hide %s, after_invert_2 %s",
                          mode["is_involution"].type == JSONType.true_, returned,
                          sIdx(jIntArray(mode["after_hide"])),
                          sIdx(jIntArray(mode["after_invert_2"]))));
        }

        // (3) the two modes must claim OPPOSITE things, or the pair carries no
        // contrast and the vertex-mode row proves nothing about the derivation.
        assert(vm["is_involution"].type == JSONType.false_
               && pm["is_involution"].type == JSONType.true_,
               "the two legs must disagree: vertex mode is not an involution and polygon "
               ~ "mode is. With both the same this pair cannot separate 'the derivation "
               ~ "costs us the round trip' from 'the invert is broken'");

        // -- VERTEX MODE: we are standing on after_invert_1. Press again. ------
        assert(selType() == typeAtInvert,
               "the involution leg must run with the type the prefix left");
        assert(hiddenFaces() == jIntArray(vm["after_invert_1"]),
               "control: the vertex-mode leg starts from the recorded post-invert set");

        cmd(`{"id":"mesh.hideInvert"}`);
        auto second = hiddenFaces();
        assert(second == jIntArray(vm["after_invert_2"]),
               format("second vertex-mode invert: hidden polygons %s, want vibe3d's frozen "
                      ~ "%s", sIdx(second), sIdx(jIntArray(vm["after_invert_2"]))));
        assert(second != jIntArray(vm["after_hide"]),
               format("the vertex-mode invert came back to its starting set %s after two "
                      ~ "presses — it is an INVOLUTION again. That is not an improvement "
                      ~ "to accept quietly: the round trip works in the reference only "
                      ~ "BECAUSE its vertex plane goes stale, so recovering it here most "
                      ~ "likely means the total derivation was traded for the reference's "
                      ~ "stale window, which vertex_plane_derivation.never_close forbids. "
                      ~ "If it was recovered some other way, re-measure and re-freeze "
                      ~ "these rows deliberately.", sIdx(second)));

        // -- POLYGON MODE: same prefix, the other type at the invert -----------
        cmd(`{"id":"mesh.unhideAll"}`);
        assert(hiddenFaces().length == 0, "unhide-all must clear before the polygon leg");
        selectPolys([0, 9]);
        assert(selType() == typeAtHide,
               format("the polygon leg must run in %s mode; /api/selection reads %s",
                      typeAtHide, selType()));
        cmd(`{"id":"mesh.hide"}`);
        assert(hiddenFaces() == jIntArray(pm["after_hide"]),
               "polygon leg: the same prefix hide as the fixture's agreement row");
        cmd(`{"id":"mesh.hideInvert"}`);
        assert(hiddenFaces() == jIntArray(pm["after_invert_1"]),
               format("polygon-mode invert: hidden polygons %s, want %s — the face plane "
                      ~ "flips, so the two hidden polygons become visible and the other "
                      ~ "eight hidden", sIdx(hiddenFaces()),
                      sIdx(jIntArray(pm["after_invert_1"]))));
        cmd(`{"id":"mesh.hideInvert"}`);
        assert(hiddenFaces() == jIntArray(pm["after_invert_2"]),
               format("second polygon-mode invert: hidden polygons %s, want the starting "
                      ~ "set %s. Polygon mode IS an involution — losing that would be a "
                      ~ "regression in the mode 0628 did not change, not a consequence of "
                      ~ "the derivation.", sIdx(hiddenFaces()),
                      sIdx(jIntArray(pm["after_invert_2"]))));

        // Leave the selection type where the prefix left it, so the row below
        // still tests that a polygon select PROMOTES the type back.
        cmd("select.typeFrom " ~ typeAtInvert);
        assert(selType() == typeAtInvert, "the involution leg must restore the prefix type");
    }

    // ---- AGREEMENT ROW 2: clear, then re-hide the probe's polygon -----------
    // The one trigger row whose end state the two engines reach identically.
    {
        cmd(`{"id":"mesh.unhideAll"}`);
        assert(hiddenFaces().length == 0, "unhide-all must clear the hidden set");

        selectPolys([0]);
        // "the ordinary way" in the fixture's row means the polygon-mode
        // re-hide, and the prefix has left the type on the invert's type — so
        // the select must promote it back. Asserted, because if it stopped
        // promoting, this row would silently become a vertex-mode hide of a
        // polygon selection.
        assert(selType() == typeAtHide,
               format("clear-then-re-hide is the ordinary polygon-mode hide, so the "
                      ~ "selection type must read %s here; the prefix left it %s and "
                      ~ "/api/selection now reads %s", typeAtHide, typeAtInvert, selType()));
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
