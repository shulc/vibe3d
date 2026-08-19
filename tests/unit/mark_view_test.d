// MarkView — the borrowed, non-allocating carrier of the selection predicate
// (task 0585 phase 1).
//
// WHAT THIS TEST IS FOR. `MarkView` exists so the per-frame draw path can ask
// "is element i selected?" without the `bool[]` snapshot that
// `Mesh.selectedVertices/Edges/Faces` allocate on every read (measured: one
// `bool[F]` per accessor call per frame per viewport cell — 102 400 B at the
// perf harness's default grid). The whole change is only safe if the carrier
// answers IDENTICALLY to what it replaces, at every index, including the
// indices nobody looks at on a well-formed mesh.
//
// WHY THE OLD ACCESSORS KEEP THEIR OWN LOOP. `selectedVertices` & co. are
// deliberately NOT reimplemented on top of `MarkView`. They are this test's
// ORACLE. Folding them into one implementation ("there should only be one")
// would turn every assertion below into a comparison of an expression with
// itself and the mutations recorded in the task file would all stay green.
// If a future cleanup unifies them, this file stops testing anything — that
// is the risk the duplication is buying off, and it is intentional.
//
// WHAT IT PINS, AND WHAT IT DOES NOT. This is the IDENTITY tier: which
// elements the mask reports, index by index. It is the only tier that can see
// an index-shifting or bit-swapping error. The frame-counter assertions in
// `tests/test_frame_counts.d` are the OUTPUT tier — they pin that the mask is
// WIRED to the draw path and how many submissions it produces, and they are
// blind to identity (a mask of {0,2,4} and one of {1,3,5} give the same
// `pass.verts.calls`). Neither tier substitutes for the other.
module tests.unit.mark_view_test;

import std.format : format;
import mesh;

// ---------------------------------------------------------------------------
// Per-domain equivalence: view[i] == old[i] for every i, plus the length and
// emptiness terms, plus agreement with the scalar accessor INCLUDING out of
// range (where the `bool[]` oracle cannot be asked, so `is*Selected` is).
// ---------------------------------------------------------------------------

private void checkVertexDomain(ref Mesh m, string fixture) {
    const bool[] oracle = m.selectedVertices;
    auto view = m.selectedVertexView();

    assert(view.length == oracle.length,
        format("%s: MarkView.length %d != selectedVertices.length %d",
               fixture, view.length, oracle.length));
    assert(view.empty == (oracle.length == 0),
        format("%s: MarkView.empty disagrees with an empty oracle", fixture));

    foreach (i; 0 .. oracle.length)
        assert(view[i] == oracle[i],
            format("%s: vertex %d — view says %s, selectedVertices says %s",
                   fixture, i, view[i], oracle[i]));

    // The carrier and the scalar accessor must not be able to drift apart:
    // they are supposed to BE the same predicate.
    foreach (i; 0 .. oracle.length)
        assert(view[i] == m.isVertexSelected(i),
            format("%s: vertex %d — view disagrees with isVertexSelected",
                   fixture, i));

    // Past the end. `isVertexSelected` answers false there by contract, and so
    // must the view: call sites inherited that tolerance from the `bool[]`
    // guards they used to write by hand.
    foreach (over; [oracle.length, oracle.length + 1, oracle.length + 1000]) {
        assert(!view[over],
            format("%s: view[%d] must be false past the end (length %d)",
                   fixture, over, view.length));
        assert(view[over] == m.isVertexSelected(over),
            format("%s: view[%d] disagrees with isVertexSelected past the end",
                   fixture, over));
    }
}

private void checkEdgeDomain(ref Mesh m, string fixture) {
    const bool[] oracle = m.selectedEdges;
    auto view = m.selectedEdgeView();

    assert(view.length == oracle.length,
        format("%s: MarkView.length %d != selectedEdges.length %d",
               fixture, view.length, oracle.length));
    assert(view.empty == (oracle.length == 0),
        format("%s: MarkView.empty disagrees with an empty oracle", fixture));

    foreach (i; 0 .. oracle.length)
        assert(view[i] == oracle[i],
            format("%s: edge %d — view says %s, selectedEdges says %s",
                   fixture, i, view[i], oracle[i]));
    foreach (i; 0 .. oracle.length)
        assert(view[i] == m.isEdgeSelected(i),
            format("%s: edge %d — view disagrees with isEdgeSelected",
                   fixture, i));
    foreach (over; [oracle.length, oracle.length + 1, oracle.length + 1000]) {
        assert(!view[over],
            format("%s: view[%d] must be false past the end (length %d)",
                   fixture, over, view.length));
        assert(view[over] == m.isEdgeSelected(over),
            format("%s: view[%d] disagrees with isEdgeSelected past the end",
                   fixture, over));
    }
}

private void checkFaceDomain(ref Mesh m, string fixture) {
    const bool[] oracle = m.selectedFaces;
    auto view = m.selectedFaceView();

    assert(view.length == oracle.length,
        format("%s: MarkView.length %d != selectedFaces.length %d",
               fixture, view.length, oracle.length));
    assert(view.empty == (oracle.length == 0),
        format("%s: MarkView.empty disagrees with an empty oracle", fixture));

    foreach (i; 0 .. oracle.length)
        assert(view[i] == oracle[i],
            format("%s: face %d — view says %s, selectedFaces says %s",
                   fixture, i, view[i], oracle[i]));
    foreach (i; 0 .. oracle.length)
        assert(view[i] == m.isFaceSelected(i),
            format("%s: face %d — view disagrees with isFaceSelected",
                   fixture, i));
    foreach (over; [oracle.length, oracle.length + 1, oracle.length + 1000]) {
        assert(!view[over],
            format("%s: view[%d] must be false past the end (length %d)",
                   fixture, over, view.length));
        assert(view[over] == m.isFaceSelected(over),
            format("%s: view[%d] disagrees with isFaceSelected past the end",
                   fixture, over));
    }
}

private void checkAllDomains(ref Mesh m, string fixture) {
    checkVertexDomain(m, fixture);
    checkEdgeDomain  (m, fixture);
    checkFaceDomain  (m, fixture);
}

// ---------------------------------------------------------------------------
// Fixture: nothing selected.
//
// Recorded deliberately: this fixture ALONE is not coverage. Every mutation
// that swaps the mark BIT or shifts the index leaves an all-false mesh
// all-false, so an empty selection is green under a broken carrier. It is here
// to pin the boundary (length is the marks length even when no bit is set),
// not to catch a wrong bit.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.clearVertexSelection();
    m.clearEdgeSelection();
    m.clearFaceSelection();
    checkAllDomains(m, "empty selection");

    assert(m.selectedVertexView().length == m.vertices.length);
    assert(m.selectedEdgeView().length   == m.edges.length);
    assert(m.selectedFaceView().length   == m.faces.length);
}

// ---------------------------------------------------------------------------
// Fixture: marks SHORTER than the geometry -- specifically, a mesh whose marks
// have not been sized at all.
//
// MEASURED, and it is why every other fixture here calls `syncSelection()`
// first: a freshly built cube has 8 vertices, 12 edges and 6 faces but ALL
// THREE marks arrays are length 0 (`makeCube` assigns `vertices` directly and
// the marks are sized lazily by `syncSelection`). So the mask a draw path
// would get on such a mesh is EMPTY while the geometry is not, and every
// consumer's `i < mask.length` guard is what keeps that safe.
//
// The view must reproduce that exactly -- its length is the MARKS length, the
// same quantity the materialized accessor reports, never the geometry length.
// A carrier that "helpfully" sized itself from `vertices.length` would report
// a longer mask than the accessor it replaces and read uninitialised marks.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    assert(m.vertices.length == 8 && m.edges.length == 12 && m.faces.length == 6,
        "fixture premise: makeCube builds real geometry");
    assert(m.vertexMarks.length == 0 && m.edgeMarks.length == 0
        && m.faceMarks.length == 0,
        "fixture premise: a fresh cube's marks are NOT yet sized -- if this "
        ~ "ever becomes false the lazy-sizing state below stops being tested "
        ~ "and needs building by hand instead");

    checkAllDomains(m, "marks not yet sized");

    assert(m.selectedFaceView().empty);
    assert(m.selectedFaceView().length == 0);
    foreach (i; 0 .. m.faces.length)
        assert(!m.selectedFaceView()[i],
            "no marks means nothing is selected, at every real face index");
}

// ---------------------------------------------------------------------------
// Fixture: everything selected.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    foreach (i; 0 .. cast(int)m.vertices.length) m.selectVertex(i);
    foreach (i; 0 .. cast(int)m.edges.length)    m.selectEdge(i);
    foreach (i; 0 .. cast(int)m.faces.length)    m.selectFace(i);
    checkAllDomains(m, "everything selected");

    // A carrier that answered `true` unconditionally would pass every
    // assertion above on this fixture, so state the complement here: past the
    // end must STILL be false even when every real element is set.
    assert(!m.selectedFaceView()[m.faces.length]);
}

// ---------------------------------------------------------------------------
// Fixture: alternating 0,2,4,… — the one that separates "reads the right bit
// at the right index" from every plausible near-miss.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.clearVertexSelection();
    m.clearEdgeSelection();
    m.clearFaceSelection();
    for (int i = 0; i < cast(int)m.vertices.length; i += 2) m.selectVertex(i);
    for (int i = 0; i < cast(int)m.edges.length;    i += 2) m.selectEdge(i);
    for (int i = 0; i < cast(int)m.faces.length;    i += 2) m.selectFace(i);
    checkAllDomains(m, "alternating");

    // Spelled out rather than left to the loop: an off-by-one in the carrier
    // turns this fixture's answer into its own complement, and a reader should
    // be able to see WHICH indices are asserted without re-deriving them.
    auto fv = m.selectedFaceView();
    assert(fv[0] && !fv[1] && fv[2] && !fv[3] && fv[4] && !fv[5]);
}

// ---------------------------------------------------------------------------
// Fixture: exactly one element, in each domain.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.clearVertexSelection();
    m.clearEdgeSelection();
    m.clearFaceSelection();
    m.selectVertex(3);
    m.selectEdge(5);
    m.selectFace(4);
    checkAllDomains(m, "single element");

    assert(m.selectedVertexView()[3] && !m.selectedVertexView()[2]);
    assert(m.selectedEdgeView()[5]   && !m.selectedEdgeView()[4]);
    assert(m.selectedFaceView()[4]   && !m.selectedFaceView()[3]);
}

// ---------------------------------------------------------------------------
// Fixture: the SUBPATCH bit set on the same faces the Select bit is NOT set
// on. This is what makes "reads Marks.Select" a measured claim rather than an
// assumption — a carrier built on the wrong bit reports the complement here
// and every other fixture in this file stays green, because on all of them
// the two bits agree by accident (both clear, or Subpatch never touched).
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.clearFaceSelection();
    // Select faces 0 and 2; mark the OTHER faces subpatch.
    m.selectFace(0);
    m.selectFace(2);
    foreach (i; 0 .. m.faces.length)
        if (i != 0 && i != 2) m.faceMarks[i] |= Mesh.Marks.Subpatch;

    checkFaceDomain(m, "select vs subpatch bit");

    auto fv = m.selectedFaceView();
    assert(fv[0] && !fv[1] && fv[2] && !fv[3] && !fv[4] && !fv[5],
        "the face view must read Marks.Select, not whatever bit happens to "
        ~ "be set on those faces");
    // And the complement is genuinely different, so the fixture can separate:
    assert(m.isFaceSubpatch(1) && m.isFaceSubpatch(3),
        "fixture is inert unless the subpatch bit really is set where select "
        ~ "is not");
}

// ---------------------------------------------------------------------------
// Fixture: marks LONGER than the geometry.
//
// This is the state the scalar accessors' bounds check exists for, and the
// reason `MarkView.length` is the MARKS length and not the geometry length:
// the materialized `bool[]` views are sized from `faceMarks`, so every call
// site that compares against `.length` is already comparing against the marks
// length. A carrier that sized itself from `faces.length` would silently
// disagree with its oracle exactly here.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.clearFaceSelection();
    m.clearVertexSelection();
    m.clearEdgeSelection();

    immutable size_t faceCount = m.faces.length;
    // Tail marks with no corresponding face, one of them SET.
    m.faceMarks   ~= [0u, cast(uint)Mesh.Marks.Select, 0u];
    m.vertexMarks ~= [cast(uint)Mesh.Marks.Select];
    m.edgeMarks   ~= [0u, cast(uint)Mesh.Marks.Select];

    checkAllDomains(m, "marks longer than geometry");

    auto fv = m.selectedFaceView();
    assert(fv.length == faceCount + 3,
        "the view's length is the MARKS length — that is what the accessor "
        ~ "it replaces reports");
    assert(!fv[faceCount] && fv[faceCount + 1] && !fv[faceCount + 2],
        "a set bit in the tail must be readable at its own index");
    assert(!fv[faceCount + 3], "one past the marks array is still false");
}

// ---------------------------------------------------------------------------
// Fixture: an empty mesh — no geometry, no marks at all. `MarkView.init` must
// behave exactly like this, because that is the value the draw path passes
// where it used to pass `(bool[]).init`.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    checkAllDomains(m, "empty mesh");

    assert(m.selectedFaceView().empty);
    assert(m.selectedFaceView().length == 0);
    assert(!m.selectedFaceView()[0]);

    MarkView blank;
    assert(blank.empty);
    assert(blank.length == 0);
    assert(!blank[0] && !blank[1] && !blank[1000],
        "MarkView.init is the empty mask the no-selection draw call sites "
        ~ "pass — it must read false everywhere, not fault");
}

// ===========================================================================
// marksBitDiffer — the face->edge highlight cache's CHANGE DETECTOR, at the
// identity tier (task 0585 review NIT-7).
// ===========================================================================
//
// WHY THIS EXISTS SEPARATELY FROM THE FRAME COUNTERS. `tests/test_frame_counts.d`
// covers the detector only through its OUTPUT — how many edge-pass batches the
// rebuilt mask produces. That tier is declared blind to identity in its own
// header, and the blindness is not theoretical here: an index shift inside
// `(mk ^ snapshot[i]) & Select` that happens to preserve the number of
// contiguous runs is byte-identical at the counter. This block is the only
// place that can see WHICH index the detector compared.
//
// THE ORACLE is the relation the detector replaced, spelled out verbatim:
// `prevSelectionBools != currentSelectionBools`. That is what
// `ui/viewport_render.d` wrote before task 0585 (`faceSelEdgesPrevSel !=
// mesh.selectedFaces`), it materializes both sides, and it shares no code with
// `marksBitDiffer` — so the equality below is an assertion, not an expression
// compared with itself.

/// The pre-0585 detector, materialized: one `bool` per element, then `!=`.
private bool[] boolsOf(const(uint)[] marks, uint bit) {
    auto r = new bool[](marks.length);
    foreach (i, m; marks) r[i] = (m & bit) != 0;
    return r;
}

private void checkDetector(const(uint)[] prev, const(uint)[] cur, uint bit,
                           string fixture) {
    immutable bool want = boolsOf(prev, bit) != boolsOf(cur, bit);
    immutable bool got  = marksBitDiffer(prev, cur, bit);
    assert(got == want,
        format("%s: marksBitDiffer says %s, the materialized `!=` oracle says %s",
               fixture, got, want));
}

unittest {
    enum uint S = Mesh.Marks.Select;
    enum uint P = Mesh.Marks.Subpatch;

    // ALTERNATING, and compared with ITSELF. This is the fixture that
    // separates "reads snapshot[i]" from "reads snapshot[i +/- 1]": a shifted
    // compare of an alternating array against itself reports a change at every
    // index. A uniform array (all clear, all set) is green under the shift, so
    // it would not be coverage.
    const uint[] alt = [S, 0, S, 0, S, 0, S, 0];
    checkDetector(alt, alt, S, "alternating vs itself");
    assert(!marksBitDiffer(alt, alt, S),
        "an array compared with itself has not changed — a detector that says "
        ~ "otherwise rebuilds the cache every frame and reads the wrong index");

    // Exactly ONE element differs, at EVERY index in turn. Catches a detector
    // that skips the first or the last element (`1 .. length`, `0 .. $-1`).
    foreach (i; 0 .. alt.length) {
        auto cur = alt.dup;
        cur[i] ^= S;
        checkDetector(alt, cur, S, format("one element flipped at index %d", i));
        assert(marksBitDiffer(alt, cur, S),
            format("index %d differs in the Select bit and the detector missed it", i));
    }

    // A change in a DIFFERENT bit is not a change in this one. Without this
    // the detector could be reading `mk != snapshot[i]` outright and every
    // fixture above would still be green.
    auto noise = alt.dup;
    foreach (ref m; noise) m |= P;
    checkDetector(alt, noise, S, "Subpatch bit toggled everywhere");
    assert(!marksBitDiffer(alt, noise, S),
        "only the Subpatch bit moved — the Select-bit detector must not fire");
    // ... and the fixture is only able to say that because the two arrays
    // really are different as raw words:
    assert(alt != noise, "fixture is inert: the noise array is not different");

    // Length. A snapshot cannot describe a marks array of another size, so a
    // length difference IS a change even when every shared element agrees.
    const uint[] shorter = [S, 0, S, 0];
    checkDetector(alt, shorter, S, "shorter snapshot, matching prefix");
    assert(marksBitDiffer(alt, shorter, S),
        "a marks array that changed length has changed");
    assert(marksBitDiffer(shorter, alt, S), "and the relation is symmetric");

    // Empty. `MarkView.init` / an unsized marks array is the state the draw
    // path starts in, and the detector must not fire on it forever.
    const uint[] none = [];
    checkDetector(none, none, S, "empty vs empty");
    assert(!marksBitDiffer(none, none, S), "nothing to nothing is not a change");
    assert(marksBitDiffer(none, alt, S), "nothing to something IS a change");
}
