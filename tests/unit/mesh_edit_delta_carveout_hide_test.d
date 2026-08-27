// ===========================================================================
// Task 1903 L0.P1 — witness W5: `HideDelta` needs `refreshHiddenDerived`, and
// the FACE plane cannot see it.
//
// `refreshHiddenDerived` is one of the five steps the carve-out KEEPS, and it
// is kept unconditionally rather than "only for HideDelta" — the ruling is at
// plan §P1.2 row 7. This cell is what makes the ruling checkable.
//
// WHY THE OBVIOUS ASSERTION IS GREEN UNDER THE BUG. `patchHide` restores the
// AUTHORITATIVE face bits regardless of whether the derive runs, so
// "no face is hidden after the undo" — which is what
// `tests/test_hide_geometry_undo.d` asserts today — passes with the derive
// deleted. Only the DERIVED vertex/edge planes redden, and only on a stand
// where hiding one face actually makes a vertex fully hidden: a vertex is
// hidden iff it has >= 1 incident face and EVERY one of them is hidden, so a
// CORNER of an open grid (valence 1) is the cell, and a cube is vacuous.
//
// THE POTENCY CONTROL IS MANDATORY AND IS THE SECOND BLOCK. Step 7 is shared
// by both paths, so the mutation that kills it kills it for the slow path too.
// A foreign, index-space-UNSTABLE kind driving the same restore through the
// same harness must therefore redden under the same mutation — that is what
// says this cell measures the DERIVE and not the branch.
// ===========================================================================
module tests.unit.mesh_edit_delta_carveout_hide_test;

import std.algorithm.searching : canFind;
import std.format : format;

import mesh;
import math : Vec3;
import mesh_edit_delta;

/// The DERIVED hidden planes, as one exact list per domain. This is the plane
/// dump the plan asks for, taken straight off the marks words rather than
/// through `meshPlanesJson`: the JSON is a transport, the claim is the list.
private string derivedHidden(ref Mesh m) {
    string v = "hiddenVerts:";
    foreach (i, w; m.vertexMarks) if (w & Mesh.Marks.Hide) v ~= format(" %d", i);
    string e = "\nhiddenEdges:";
    foreach (i, w; m.edgeMarks) if (w & Mesh.Marks.Hide) e ~= format(" %d", i);
    string f = "\nhiddenFaces:";
    foreach (i, w; m.faceMarks) if (w & Mesh.Marks.Hide) f ~= format(" %d", i);
    return v ~ e ~ f;
}

/// The stand: an open grid, one face hidden, that face carrying a CORNER
/// vertex of valence 1 so the derive has something to say. Returns the mesh
/// with face `fi` hidden and the "nothing hidden" dump of the same mesh.
private Mesh hideStand(out string cleanDump, out uint fi) {
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    cleanDump = derivedHidden(m);
    assert(cleanDump.length > 0);

    // Face 0 of a grid owns grid corner vertex 0, which has exactly one
    // incident face.
    fi = 0;
    size_t incident = 0;
    foreach (ref f; m.faces)
        foreach (vi; f) if (vi == 0) { ++incident; break; }
    assert(incident == 1, format(
        "stand: vertex 0 must have exactly ONE incident face (got %d), or "
      ~ "hiding face 0 does not make it fully hidden and the derived plane "
      ~ "never moves — the fixture would not be able to exhibit the failure",
        incident));

    m.setFaceHidden(fi, true);
    assert(m.isVertexHidden(0), format(
        "stand: with face %d hidden, vertex 0 must be DERIVED hidden — "
      ~ "otherwise the assertion below compares two identical states", fi));
    return m;
}

private MeshOpEntry hideEntry(uint fi) {
    MeshOpEntry e;
    e.kind       = MeshOpEntry.Kind.HideDelta;
    e.markIdx    = [fi];
    e.markBefore = [0u];        // it was NOT hidden before the op
    e.markAfter  = [1u];        // the op hid it
    return e;
}

unittest // W5 — a fast-path HideDelta revert re-derives the vertex/edge planes
{
    string clean;
    uint fi;
    Mesh m = hideStand(clean, fi);

    MeshEditDelta d;
    d.scope_ = cast(MeshEditScope)(MeshEditScope.Marks | MeshEditScope.Visibility);
    d.log = [hideEntry(fi)];

    const rebBefore = g_rebuildEdgesRuns;
    d.revert(m);
    assert(g_rebuildEdgesRuns == rebBefore, format(
        "stand: an all-stable HideDelta log must take the FAST path — "
      ~ "rebuildEdges ran %d time(s). Without that this cell says nothing "
      ~ "about the carve-out.", g_rebuildEdgesRuns - rebBefore));

    assert(derivedHidden(m) == clean, format(
        "W5: a HideDelta revert restored the authoritative FACE bits but left "
      ~ "the DERIVED vertex/edge planes describing the hidden state. "
      ~ "`refreshHiddenDerived` is what re-derives them and the carve-out "
      ~ "keeps it for exactly this reason. Note what is GREEN under this bug: "
      ~ "the face list below matches, which is all that "
      ~ "tests/test_hide_geometry_undo.d asserts.\n--- expected ---\n%s\n"
      ~ "--- measured ---\n%s", clean, derivedHidden(m)));
}

unittest // W5-instrument — the dump can SEE the derived planes, and the slow path is NOT the control
{
    // POTENCY OF THE INSTRUMENT. `derivedHidden` reads three mark planes; if it
    // read nothing, or read only the FACE plane, the block above would compare
    // two identical strings and pass under any bug. This says the dump moves,
    // and moves on the DERIVED half.
    string clean;
    uint fi;
    Mesh m = hideStand(clean, fi);
    const hidden = derivedHidden(m);
    assert(hidden != clean,
        "instrument: with a face hidden the dump must differ from the clean "
      ~ "one — otherwise the assertion in the block above is between two "
      ~ "identical strings");
    assert(hidden.canFind("hiddenVerts: 0"), format(
        "instrument: the dump must show the DERIVED vertex plane carrying "
      ~ "vertex 0, not just the face bit — a face-only dump is green under the "
      ~ "very bug W5 exists for. Got:\n%s", hidden));
    assert(clean.canFind("hiddenVerts:\n"), format(
        "instrument: the clean dump must show an EMPTY derived vertex plane, "
      ~ "so the two are distinguishable in both directions. Got:\n%s", clean));
}

// ---------------------------------------------------------------------------
// WHAT THE SLOW PATH IS NOT — a finding, recorded because the obvious control
// was tried and was INERT (measured 2026-08-27).
//
// The plan asks for a potency control of the shape "a foreign, index-space-
// UNSTABLE kind driving the same restore must redden under the same mutation",
// on the reasoning that step 7 is shared by both paths. It does not redden:
// with `finalize`'s explicit `refreshHiddenDerived()` deleted, a SLOW-path
// HideDelta revert still comes back with correct derived planes, because
// `rebuildEdges()` ends in its own `commitChange(MeshEditScope.Polygons)` and
// `commitStamps` runs the derive for a Geometry publish. That second derive is
// the `hideDerive 2` the pre-carve-out counter rows show.
//
// So the slow path has a BACKSTOP the fast path does not, and that is the
// sharpest available statement of why step 7 is KEPT rather than made
// conditional: on the fast path there is no rebuild, so there is no second
// derive, and `finalize`'s explicit call is the only one there is.
// ---------------------------------------------------------------------------
