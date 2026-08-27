// flip_and_spin_delta_test — task 1903 Stage L2-a / L2-b.
//
// The three commands migrated here — `mesh.flip`, `mesh.fixOrientation`,
// `mesh.spinEdge` — share one property that nothing else in stage L2 has:
// their edit is an EQUAL-ARITY winding rewrite. No face slot is added, removed
// or reordered, so face, vertex and edge COUNTS are identical before and after,
// and identical again after a revert that did nothing at all. That is why the
// pre-migration op-log was EMPTY and `MeshEditDelta.revert` answered `true`
// while leaving the edit in place: the shape §5.3 rates worse than a throw,
// because a throw is caught on the first run.
//
// SO EVERY CELL BELOW COMPARES A WINDING OR A MAP PLANE, never a count.
//
// AND FOR `mesh.flip` THE MAP PLANE IS THE ONLY CHANNEL THERE IS. A flip is a
// corner PERMUTATION: a revert that installs the right winding but leaves the
// per-corner values on their old slots produces `vertices`, `faces`, every mark
// word, every material/part value and every count BYTE-IDENTICAL to a correct
// undo, and differs only in `meshMaps`. Cell C asserts the geometry FIRST and
// the map plane SECOND in one block, so the mutation that drops the corner
// payload shows the geometry asserts passing and the map assert firing — which
// is the finding, not an accident of ordering.
//
// LANE: `dub test --config=tests` (lane U). `./run_test.d` links the prebuilt
// library and never executes a `tests/unit/**` unittest block.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — when scoring a
// mutation that should redden two cells for two reasons, stub the earlier one.
module tests.unit.flip_and_spin_delta_test;

import std.conv   : to;
import std.format : format;

import mesh;
import mesh_edit_delta;
import view;
import editmode;
import command;
import command_history : CommandHistory;
import change_bus      : changeBus;

import commands.mesh.flip            : MeshFlip;
import commands.mesh.fix_orientation : MeshFixOrientation;
import commands.mesh.spin_edge       : MeshSpinEdge;

import tests.unit.fixtures : makeTaggedGridBent, findEdge;

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

private Mesh stand()
{
    auto m = makeTaggedGridBent(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private float[] uvOf(ref Mesh m)
{
    auto u = m.meshMap(kUvMapName);
    assert(u !is null, "the stand lost its PolyVertex map");
    return u.data.dup;
}

private uint[][] windingsOf(ref Mesh m)
{
    auto r = new uint[][](m.faces.length);
    foreach (fi; 0 .. m.faces.length) r[fi] = m.faces[fi].dup;
    return r;
}

/// The op-log's KIND SEQUENCE, as text. The sequence and never the LENGTH:
/// a length assertion is satisfied by a log with an entry interposed, and
/// since Stage J the `[MeshMapDelta, <face entry>]` ADJACENCY is contractual
/// (`CornerCarry.payloadForCount` pairs by it), so an unpaired payload zeroes
/// a per-corner map silently while the geometry round-trips.
private string kindsOf(in MeshEditDelta d)
{
    string s;
    foreach (i, ref e; d.log) s ~= (i ? " " : "") ~ e.kind.to!string;
    return s;
}

private size_t facesNamedByReshape(in MeshEditDelta d)
{
    foreach (ref e; d.log)
        if (e.kind == MeshOpEntry.Kind.ReshapeFaces) return e.fIdx.length;
    return 0;
}

// ---------------------------------------------------------------------------
// A — the stand. FIRST, because every cell below is vacuous without it.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();

    // A live per-corner map with a DISTINCT value per corner. Without it the
    // corner carry declines, `recordPolyVertexPayload` records nothing, and
    // cell C — the only cell in the file that can see the flip residual —
    // passes under every implementation.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "A: the stand must carry a PolyVertex map — without one the corner "
      ~ "payload is never recorded and cell C is vacuous");
    assert(uv.data.length == m.cornerCount() * 2, "A: the UV map is in step");
    bool distinct = true;
    foreach (i; 1 .. uv.data.length) if (uv.data[i] == uv.data[0]) distinct = false;
    assert(distinct,
        "A: the UV values must be distinct per corner — on a uniform map a "
      ~ "permutation of the corners is the IDENTITY and cell C cannot fail");

    // An interior edge with exactly two incident faces, or every spin cell
    // freezes a refusal (`spinEdgeRings_`'s `nFaces != 2`).
    immutable int ei = findEdge(m, 5, 6);
    assert(ei >= 0, "A: the stand has no edge 5-6");
    size_t inc = 0;
    foreach (f; m.facesAroundEdge(cast(uint) ei)) ++inc;
    assert(inc == 2,
        format("A: edge 5-6 has %d incident face(s), expected 2 — a spin "
             ~ "REFUSES anything else and every spin cell below would freeze "
             ~ "a refusal", inc));
}

// ---------------------------------------------------------------------------
// B — flip, at the kernel: the op-log SHAPE and the winding round-trip.
//
// MUTATION: in `Mesh.flipFacesByMask`, make the recorded arm take the
// unrecorded one (`if (editRecorder_ is null)` -> `if (true)`).
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const pre = windingsOf(m);

    bool[] one = new bool[](m.faces.length);
    one[7] = true;                  // ONE face, and face 5 is hidden — not it

    MeshEditDelta d;
    size_t flipped;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);   // RECORDING
        flipped = ed.mesh.flipFacesByMask(one);
        d = ed.close();
    }

    // Anti-vacuity: the forward must have moved the one channel this cell
    // reads. A kernel that stopped flipping makes every claim below true.
    assert(flipped == 1,
        format("B: the kernel flipped %d face(s), expected 1 — every "
             ~ "assertion below is vacuous on a kernel that did nothing",
               flipped));
    assert(m.faces[7] != pre[7],
        "B: face 7's winding was not actually reversed, so the restore claim "
      ~ "below would be trivially satisfied");

    assert(kindsOf(d) == "MeshMapDelta ReshapeFaces",
        format("B: op-log kinds are [%s], expected [MeshMapDelta "
             ~ "ReshapeFaces]. An EMPTY log is the pre-L2 state, in which "
             ~ "`revert()` answers true and changes nothing", kindsOf(d)));
    assert(facesNamedByReshape(d) == 1,
        format("B: the ReshapeFaces entry names %d face(s), expected the 1 "
             ~ "that was written", facesNamedByReshape(d)));

    assert(d.revert(m), "B: revert() refused the delta outright");
    assert(m.faces[7] == pre[7],
        format("B: face 7 came back as %s, expected its pre-op winding %s",
               m.faces[7].to!string, pre[7].to!string));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("B: the revert disturbed face %d, which the flip never "
                 ~ "touched", fi));
}

// ---------------------------------------------------------------------------
// C — THE DISCRIMINATING CELL. Geometry first, then the per-corner plane.
//
// MUTATION: delete `recordPolyVertexPayload(idx);` from the full-hit branch of
// `Mesh.setFaceWindings`. Everything above the last assert stays GREEN and the
// map assert fires, naming the corner and the value — which is the whole
// finding: a `ReshapeFaces` revert that restores the winding restores the
// per-corner values only because the payload carries them verbatim. Without
// it, `CornerCarry.reshapeSrc` keeps the slots at equal arity (its own
// documented convention) and the UV comes back REVERSED.
//
// MEASURED, 2026-08-27, this lane: with the payload the whole plane is
// byte-identical; without it face 7's four UV corners come back as
// `62,63,60,61,58,59,56,57` where they were `56,57,58,59,60,61,62,63` — the
// same finding the frozen fixture reports as `[mesh.flip/postUndo]: plane
// 'meshMaps' differs`, both dumps 447 bytes long.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const preUv    = uvOf(m);
    const preFaces = windingsOf(m);
    const preMarks = m.faceMarks.dup;
    const preMat   = m.faceMaterial.dup;
    const preVerts = m.vertices.dup;

    bool[] one = new bool[](m.faces.length);
    one[7] = true;

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        assert(ed.mesh.flipFacesByMask(one) == 1, "C: the flip must apply");
        d = ed.close();
    }
    // Anti-vacuity for the MAP half specifically: the forward has to move the
    // plane this cell is about, or "it came back" is a statement about a plane
    // nothing touched.
    assert(uvOf(m) != preUv,
        "C: the forward left the per-corner plane where it was, so the "
      ~ "restore claim below is satisfied by an undo that does nothing to it");

    assert(d.revert(m), "C: revert() refused the delta outright");

    // ---- the channels a broken corner carry leaves PERFECT --------------
    assert(m.vertices    == preVerts, "C: vertices");
    assert(m.faceMarks   == preMarks, "C: faceMarks");
    assert(m.faceMaterial== preMat,   "C: faceMaterial");
    assert(m.faces.length == preFaces.length, "C: face count");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == preFaces[fi], format("C: winding of face %d", fi));

    // ---- …and the ONE channel it does not -------------------------------
    const backUv = uvOf(m);
    size_t bad = size_t.max;
    foreach (i; 0 .. preUv.length) if (preUv[i] != backUv[i]) { bad = i; break; }
    assert(bad == size_t.max,
        format("C: corner value %d came back as %s, expected its pre-op value "
             ~ "%s. Every geometry channel above this line is byte-identical — "
             ~ "vertices, windings, marks, material and every count — so THIS "
             ~ "assert is the only thing in the tree that can see a "
             ~ "ReshapeFaces revert which restored the winding and not the "
             ~ "corner PERMUTATION. The mechanism that closes it is the "
             ~ "`[MeshMapDelta, ReshapeFaces]` payload pair recorded inside "
             ~ "Mesh.setFaceWindings", bad,
               bad == size_t.max ? "-" : backUv[bad].to!string,
               bad == size_t.max ? "-" : preUv[bad].to!string));
}

// ---------------------------------------------------------------------------
// D — the two arms of `flipFacesByMask` agree.
//
// `flipFacesByMask` writes its windings two ways — in place on an unrecorded
// batch, through `Mesh.setFaceWindings` on a recording one — and a two-armed
// kernel's standing hazard is that the arms drift about WHICH faces they touch
// or WHAT they write. Nothing else in this file would notice: every other cell
// drives the recording arm only.
//
// MUTATION: change either arm's face predicate (e.g. drop the `>= 3` guard
// from the hoisted `isTarget`, or write `dst[j]` instead of `dst[$ - 1 - j]`).
// ---------------------------------------------------------------------------
unittest
{
    bool[] mask(ref Mesh m) {
        bool[] b = new bool[](m.faces.length);
        b[0] = b[3] = b[7] = true;
        return b;
    }

    auto rec = stand();
    size_t nRec;
    {
        auto ed = MeshEditBatch(rec, MeshEditScope.Geometry);      // recording
        nRec = ed.mesh.flipFacesByMask(mask(ed.mesh));
        ed.close();
    }

    auto unrec = stand();
    size_t nUn;
    {
        auto ed = MeshEditBatch.unrecorded(unrec, MeshEditScope.Geometry);
        nUn = ed.mesh.flipFacesByMask(mask(ed.mesh));
        ed.close();
    }

    assert(nRec > 0, format("D: the recorded arm flipped %d faces — with 0 "
                          ~ "the comparison below is between two untouched "
                          ~ "meshes", nRec));
    assert(nRec == nUn,
        format("D: the recorded arm flipped %d faces and the unrecorded arm "
             ~ "%d — the two arms disagree about the OPERAND", nRec, nUn));
    foreach (fi; 0 .. rec.faces.length)
        assert(rec.faces[fi] == unrec.faces[fi],
            format("D: face %d is %s on the recorded arm and %s on the "
                 ~ "unrecorded one — the two arms disagree about what they "
                 ~ "WRITE", fi, rec.faces[fi].to!string,
                   unrec.faces[fi].to!string));
    assert(uvOf(rec) == uvOf(unrec),
        "D: the two arms left the per-corner plane in different states — the "
      ~ "corner RELOCATION is shared code and must not depend on the arm");
}

// ---------------------------------------------------------------------------
// E — `mesh.flip` through the real undo stack, and HOW MANY STEPS took effect.
//
// The step count is asserted because a witness in an earlier group of this
// task was inert twice: its undo went through a command id that does not
// exist, ten "undos" were ten silent no-ops, and every assertion after them
// was about a mesh nobody had reverted. `CommandHistory.undoEpoch` is bumped
// exactly once per SUCCESSFUL undo and by nothing else — not by redo, record,
// consolidate or coalesce — so it counts steps that actually took effect
// rather than calls that were made.
//
// MUTATION: `MeshFlip.revert` -> `return false;` (the entry and its whole
// trailing suffix are then discarded and the mesh is left flipped).
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    const pre = windingsOf(m);
    const preUv = uvOf(m);

    auto hist = new CommandHistory();
    auto c = new MeshFlip(&m, v, EditMode.Polygons);
    assert(c.apply(), "E: the flip must apply on this stand");
    assert(m.faces[7] != pre[7], "E: the forward must have moved face 7");
    assert(c.isOperationInverse(),
        "E: the command reports a snapshot undo — it is meant to be on the "
      ~ "delta path here (the tracker hatch is off by default)");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.canUndo(), "E: the flip left no undo entry");
    assert(hist.undo(), "E: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("E: %d undo step(s) actually took effect, expected exactly 1 — "
             ~ "a call that returns without reverting is the shape this "
             ~ "assertion exists for", hist.undoEpoch() - epoch0));

    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("E: face %d did not come back through the history undo", fi));
    assert(uvOf(m) == preUv, "E: the per-corner plane did not come back");
}

// ---------------------------------------------------------------------------
// F — `mesh.fixOrientation` through the real undo stack.
//
// A SEPARATE cell from E and not a parameter of it: the two commands reach the
// same primitive by different routes (`fixFaceOrientation` computes its own
// flip mask from the winding consistency of the whole component), and E's
// operand is a face SELECTION while this one's is a corrupted winding. The
// stand's addition 1 is what makes it applicable at all — on the shipped
// `makeTaggedGridFull` this command REFUSES.
//
// MUTATION: `MeshFixOrientation.revert` -> `return false;`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    const pre = windingsOf(m);
    const preUv = uvOf(m);

    auto hist = new CommandHistory();
    auto c = new MeshFixOrientation(&m, v, EditMode.Polygons);
    assert(c.apply(),
        "F: mesh.fixOrientation must apply on this stand — it REFUSES a "
      ~ "uniformly wound sheet, which is the whole reason makeTaggedGridBent "
      ~ "exists");
    assert(m.faces[2] != pre[2],
        "F: the corrupted face was not healed, so every claim below is "
      ~ "satisfied by an undo that does nothing");
    assert(c.isOperationInverse(), "F: the command is meant to be on the delta path");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "F: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("F: %d undo step(s) took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("F: face %d did not come back — face 2 is the corrupted "
                 ~ "one and must be corrupted again after the undo", fi));
    assert(uvOf(m) == preUv, "F: the per-corner plane did not come back");
}

// ---------------------------------------------------------------------------
// G — spin, at the kernel: ONE pair for the whole spin, both windings back.
//
// MUTATION (a): write only one of the two rings through the door.
// MUTATION (b): route neither (restore `faces[f1i] = ring1; faces[f2i] =
//               ring2;`) — the log reads EMPTY and both faces stay spun.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    immutable int eiRaw = findEdge(m, 5, 6);
    immutable ulong key = edgeKey(5, 6);
    const pre = windingsOf(m);

    MeshEditDelta d;
    size_t spun;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        ulong[] product;
        spun = ed.mesh.spinEdgesByKeys([key], product);
        d = ed.close();
    }
    assert(spun == 1,
        format("G: %d spin(s) happened, expected 1 — a refusing kernel makes "
             ~ "every assertion below vacuous", spun));
    assert(m.faces[1] != pre[1] && m.faces[4] != pre[4],
        "G: a spin must rewrite BOTH incident faces; one of them is unchanged");

    assert(kindsOf(d) == "MeshMapDelta ReshapeFaces",
        format("G: op-log kinds are [%s], expected [MeshMapDelta "
             ~ "ReshapeFaces] — ONE pair for the whole spin, not one per face "
             ~ "(the per-element door is quadratic) and not an EMPTY log "
             ~ "(the pre-L2 state, whose revert answered true and left both "
             ~ "faces spun)", kindsOf(d)));
    assert(facesNamedByReshape(d) == 2,
        format("G: the ReshapeFaces entry names %d face(s), expected the 2 "
             ~ "the spin rewrote", facesNamedByReshape(d)));

    assert(d.revert(m), "G: revert() refused the delta outright");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("G: face %d came back as %s, expected %s. A spin is "
                 ~ "arity-preserving on both faces, so the face, vertex and "
                 ~ "edge COUNTS are identical whether or not this worked — "
                 ~ "only a per-winding compare can see it", fi,
                   m.faces[fi].to!string, pre[fi].to!string));
}

// ---------------------------------------------------------------------------
// H — THE SPIN'S PER-CORNER VERDICT, and it is written down because half of it
//     is a DIVERGENCE and the other half is INERT. Neither is a witness.
//
// MEASURED on this stand, 2026-08-27, this lane:
//
//  * FORWARD — the UV plane comes out BYTE-IDENTICAL. `spinEdgeRings_` opens no
//    corner rewrite and the corner COUNT does not change, so
//    `resizePolyVertexMaps` takes its keep branch and every value stays on the
//    slot it was on while the VERTEX under that slot changes. Face 1 goes
//    `[1,2,6,5]` -> `[1,2,6,10]`: slot 3 moves from vertex 5 to vertex 10 and
//    keeps vertex 5's UV. Face 4 goes `[5,6,10,9]` -> `[10,9,5,1]` — a rotation
//    AND a substitution, every slot holding a foreign vertex's UV.
//    Whether that is what a spin SHOULD do to a UV is a question no measurement
//    in this stage answers; it is PRE-EXISTING, the winding writer does not
//    change it, and it is recorded as a divergence rather than papered over.
//
//  * REVERSE — byte-identical, and it would be byte-identical WITHOUT the
//    corner payload too. Measured by deleting `recordPolyVertexPayload` from
//    `Mesh.setFaceWindings` and re-running: log `[ReshapeFaces]`, UV still
//    restored. So for a SPIN the payload is INERT on the map plane, because the
//    forward never moved it and `CornerCarry.reshapeSrc` keeps the slots at
//    equal arity anyway. It is NOT inert for a FLIP — cell C — where the
//    forward relocates.
//
// This cell therefore asserts the two FACTS and says in its own message that
// neither can fail under the mutation that matters. The discriminating cell
// for the payload is C, and the discriminating cell for the pair's SHAPE is G.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    immutable ulong key = edgeKey(5, 6);
    const preUv = uvOf(m);
    const pre   = windingsOf(m);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        ulong[] product;
        assert(ed.mesh.spinEdgesByKeys([key], product) == 1, "H: the spin must apply");
        d = ed.close();
    }

    // The DIVERGENCE, stated as an executable fact so that a future change to
    // it is loud rather than silent.
    assert(uvOf(m) == preUv,
        "H: the spin FORWARD moved the per-corner plane. It did not on "
      ~ "2026-08-27 — the values stay on their slots while the vertices under "
      ~ "them change, which is this command's recorded divergence. If this is "
      ~ "red because someone taught spinEdgeRings_ a corner rewrite, that is a "
      ~ "behaviour change and it needs its own reference measurement, not a "
      ~ "fixed test");
    assert(m.faces[1] != pre[1], "H: anti-vacuity — the forward must have spun");

    assert(d.revert(m), "H: revert() refused");
    assert(uvOf(m) == preUv,
        "H: the per-corner plane did not survive the round trip. NOTE: this "
      ~ "assert is INERT with respect to the corner payload — measured, it is "
      ~ "green with `recordPolyVertexPayload` deleted, because the forward "
      ~ "never moved the plane. Cell C is the payload's witness");
}

// ---------------------------------------------------------------------------
// I — the spin's TRANSACTION gate refuses, and refuses having written nothing.
//
// Two overlapping selected edges (they share a face) are refused before
// anything is written.
//
// MUTATION: neutralise the gate (`if (fA in faceSeen || fB in faceSeen)` ->
// `if (false)`) — the command applies over the overlapping pair and the first
// assert fires.
//
// WHAT THIS CELL DOES *NOT* PROVE, MEASURED RATHER THAN ASSUMED. The stage
// plan specified the mutation "move the overlap gate after the batch opens"
// and predicted `changeBus.batchLeaks` would redden. It does NOT, and the
// prediction died on this tree: `map_edit_undo.runMapEdit` calls `ed.close()`
// on ALL THREE of its arms BEFORE it reads the kernel's answer, so a `return
// false` from inside the batch closes cleanly and ticks nothing. Measured by
// putting `if (true) return false;` at the top of `runKernel` — this cell went
// GREEN. The leak counter's assertion is kept as a REGRESSION GUARD against a
// future hand-opened batch in this file (the shape the command had before
// L2-b, and the shape `delete.d` still has), and it is honestly labelled as
// one rather than counted as a witness.
//
// The gate's PRE-FLIGHT position is still the right one and still argued in
// `spin_edge.d`, on the ground its own note always gave: neither of two
// overlapping spins FAILS, so there is no failure for any undo image to react
// to, and the conflict is visible only in the incidence of the ORIGINAL mesh.
// That claim is about correctness, not about a counter, and the cell that
// carries it is the frozen parity fixture, not this one.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);

    // Edges 5-6 and 6-10 share face 4 — two spins of one face, which is what
    // the gate refuses.
    immutable int e1 = findEdge(m, 5, 6);
    immutable int e2 = findEdge(m, 6, 10);
    assert(e1 >= 0 && e2 >= 0, "I: the stand has no 5-6 / 6-10 pair");
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(e1);
    m.selectEdge(e2);

    // The overlap is a PROPERTY OF THE STAND and is asserted, not assumed: if
    // the two edges stopped sharing a face the gate would not fire and this
    // cell would pass on a command that never refused anything.
    {
        auto ef = m.buildEdgeFaces();
        auto p1 = edgeKey(5, 6)  in ef;
        auto p2 = edgeKey(6, 10) in ef;
        assert(p1 !is null && p2 !is null, "I: both edges must be interior");
        bool shares = false;
        foreach (a; (*p1)[0 .. 2]) foreach (b; (*p2)[0 .. 2])
            if (a >= 0 && a == b) shares = true;
        assert(shares,
            "I: the two selected edges no longer share a face, so the "
          ~ "transaction gate has nothing to refuse and this cell is vacuous");
    }

    const pre = windingsOf(m);
    immutable size_t leaks0 = changeBus.batchLeaks;

    auto c = new MeshSpinEdge(&m, v, EditMode.Edges);
    assert(!c.apply(),
        "I: the command applied over two overlapping edges — the transaction "
      ~ "gate is gone");
    // REGRESSION GUARD, not a witness — see the block comment above for the
    // measurement that says so.
    assert(changeBus.batchLeaks == leaks0,
        format("I: batchLeaks moved by %d — some path in this command opened a "
             ~ "batch it did not close. `runMapEdit` closes on every arm, so "
             ~ "this can only be a hand-opened one",
               changeBus.batchLeaks - leaks0));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("I: face %d was mutated by a command that refused", fi));
}

// ---------------------------------------------------------------------------
// J — `mesh.spinEdge` through the real undo stack, INCLUDING the selection.
//
// The selection half is the finding the frozen parity fixture produced and a
// review would not have: `repointToEdgeKeys` opens with `repointToNothing`,
// which clears ALL THREE domains, and the op-log carries no selection kind, so
// the migration restored strictly less than `MeshSnapshot.restore` did — first
// the edge order STAMP (1 where the snapshot had 3), then the FACE Select bit,
// then two decorative face order stamps. All three are asserted here.
//
// MUTATION: delete the `if (undo_.armed()) restoreSelection();` line in
// `MeshSpinEdge.revert`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);

    immutable int ei = findEdge(m, 5, 6);
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(ei);

    const pre        = windingsOf(m);
    const preFaceSel = m.selectedFaces.dup;
    const preFaceOrd = m.faceSelectionOrder.dup;
    immutable uint selA = m.edges[ei][0], selB = m.edges[ei][1];
    immutable int  selOrd = m.edgeSelectionOrder[ei];
    assert(selOrd != 0, "J: the selected edge must carry an order stamp, or "
                      ~ "the stamp assertion below cannot fail");
    bool anyFaceSel = false;
    foreach (b; preFaceSel) if (b) anyFaceSel = true;
    assert(anyFaceSel, "J: the stand must have a selected FACE — the spin "
                     ~ "clears all three domains and this is the plane that "
                     ~ "showed the loss");

    auto hist = new CommandHistory();
    auto c = new MeshSpinEdge(&m, v, EditMode.Edges);
    assert(c.apply(), "J: the spin must apply");
    assert(m.faces[1] != pre[1], "J: anti-vacuity — the forward must have spun");
    assert(c.isOperationInverse(), "J: the command is meant to be on the delta path");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "J: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("J: %d undo step(s) took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));

    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("J: face %d did not come back", fi));

    immutable int back = m.edgeIndex(selA, selB);
    assert(back != ~0u, "J: the pre-op edge is not in the reverted mesh");
    assert(m.isEdgeSelected(back),
        "J: the pre-op EDGE SELECTION did not come back — the spin repointed "
      ~ "it at the product and nothing put it back");
    assert(m.edgeSelectionOrder[back] == selOrd,
        format("J: the edge came back selected with order stamp %d, expected "
             ~ "%d. `MeshSnapshot.restore` put the rank back and a re-select "
             ~ "through `selectEdge` mints a FRESH one — this is the exact "
             ~ "difference the frozen parity fixture reported",
               m.edgeSelectionOrder[back], selOrd));
    assert(m.selectedFaces == preFaceSel,
        "J: the FACE selection did not come back — `repointToNothing` clears "
      ~ "all three domains, not just the edges");
    assert(m.faceSelectionOrder == preFaceOrd,
        format("J: faceSelectionOrder came back as %s, expected %s — "
             ~ "`SelectionSnapshot.restore` re-zeroes the stamp of every "
             ~ "UNSELECTED element while `MeshSnapshot.restore` copied the "
             ~ "array whole", m.faceSelectionOrder.to!string,
               preFaceOrd.to!string));
}

// ---------------------------------------------------------------------------
// K — a MULTI-SPIN round records ONE pair for the WHOLE ROUND, ascending.
//
// This is the cell that pins the round-level bulk install, and it exists
// because of a 38x measurement rather than for tidiness: `setFaceWindings`
// resolves its per-corner payload by ONE ORDERED SWEEP over `faces`, so a
// caller that takes the door once per spin pays O(S x F). Measured on this
// lane at 99 856 faces / 99 540 spin keys: 179.77 ms unrecorded against
// 6 843.65 ms recorded — 38.07x. Collecting the round and installing it once
// brought that to 222.27 ms against 203.16 ms, 1.09x.
//
// AND IT IS THE ONLY CELL THAT EXERCISES THE SORT. The collector appends each
// spin's pair in caller order — here `(0,1)`, `(4,5)`, `(3,6)` — so the raw
// list is `0 1 4 5 3 6`, which `setFaceWindings` REFUSES (its ascending
// assert). Every SINGLE spin on this stand happens to collect ascending
// already, measured over all twelve interior edges, so cell G cannot reach the
// sort at all: defeating it left G green.
//
// MUTATION: `makeIndex` -> hand `setFaceWindings` the unsorted arrays.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const pre = windingsOf(m);
    const preUv = uvOf(m);

    // Three PAIRWISE-DISJOINT interior edges, so all three spin in ONE round:
    // 1-5 (faces 0,1), 6-10 (faces 4,5), 8-9 (faces 3,6).
    immutable ulong[] keys = [edgeKey(1, 5), edgeKey(6, 10), edgeKey(8, 9)];

    MeshEditDelta d;
    size_t spun;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        ulong[] product;
        spun = ed.mesh.spinEdgesByKeys(keys, product);
        d = ed.close();
    }
    assert(spun == 3,
        format("K: %d spin(s) happened, expected 3 — if the three edges stopped "
             ~ "being pairwise disjoint they no longer share a round and this "
             ~ "cell measures something else entirely", spun));

    assert(kindsOf(d) == "MeshMapDelta ReshapeFaces",
        format("K: op-log kinds are [%s], expected ONE [MeshMapDelta "
             ~ "ReshapeFaces] pair for the whole round. One pair PER SPIN is "
             ~ "the quadratic shape this cell exists to refuse", kindsOf(d)));
    assert(facesNamedByReshape(d) == 6,
        format("K: the entry names %d face(s), expected the 6 that three spins "
             ~ "rewrote", facesNamedByReshape(d)));

    // The ORDER, which is what the sort buys and what the door requires.
    foreach (ref e; d.log) {
        if (e.kind != MeshOpEntry.Kind.ReshapeFaces) continue;
        foreach (i; 1 .. e.fIdx.length)
            assert(e.fIdx[i - 1].raw < e.fIdx[i].raw,
                format("K: the recorded face list is not strictly ascending at "
                     ~ "%d (%d then %d). `Mesh.setFaceWindings` pairs its "
                     ~ "corner payload by a single ordered sweep and DECLINES "
                     ~ "on an unordered list, which would leave the entry "
                     ~ "unpaired and the per-corner plane re-derived instead of "
                     ~ "restored", i, e.fIdx[i - 1].raw, e.fIdx[i].raw));
    }

    assert(d.revert(m), "K: revert() refused the delta outright");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("K: face %d came back as %s, expected %s", fi,
                   m.faces[fi].to!string, pre[fi].to!string));
    assert(uvOf(m) == preUv, "K: the per-corner plane did not come back");
}
