// mesh_winding_writer_test — task 1903 Stage L2-P1.
//
// ===========================================================================
// WHAT IS UNDER TEST, AND WHAT IS DELIBERATELY NOT
// ===========================================================================
// `Mesh.setFaceWinding` / `Mesh.setFaceWindings` — the door an in-place
// winding rewrite goes through so that it reaches the op-log. NO KERNEL IS
// MIGRATED IN THIS COMMIT and no production caller exists yet, exactly as
// `Kind.MapValueDelta` (Stage L1-P1) and the `finalize` carve-out (L0-P1)
// shipped with none. Every cell below therefore drives the writer directly.
// That is a real limit and it is stated rather than papered over: what these
// cells pin is that the door RECORDS what it writes and that the record
// inverts; whether `flipFacesByMask` and the other four sites actually walk
// through it is L2-a … L2-f's claim, pinned by their own cells (and by
// `tests/unit/mesh_ops/cleanup_test.d`'s pre-placed "STAGE L2 FLIPS THIS"
// block, which is still green here and MUST be — a P1 that flipped it would
// have migrated a kernel).
//
// WHY THE CHECKS ARE ALL PER-WINDING COMPARES AFTER A REVERT. An in-place
// reshape adds, removes and reorders no slot: face count, vertex count, edge
// count, every mark word and every material/part value are byte-identical
// whether the entry is right, transposed, or absent altogether. A count
// assertion here cannot come out differently. The only channels that can are
// the winding itself and the per-corner plane.
//
// SEEN RED — every cell, by its own mutation, in lane U
// (`dub test --config=tests`; `tests/unit/**` blocks never run in
// `./run_test.d`, which links a prebuilt library). Verbatim messages are in
// the task card (2260).
// ===========================================================================
module tests.unit.mesh_winding_writer_test;

import std.algorithm.mutation : reverse;
import std.exception : assertThrown;
import std.format    : format;
import core.exception : AssertError;

import mesh;
import math : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, MeshEditScope;

private enum uint kTestScope = MeshEditScope.Geometry;

// ---------------------------------------------------------------------------
// The stand: two quads sharing edge (1,2), carrying a per-corner map whose
// value KEYS the corner's own slot (u = 1 + loop, v = 100 + loop). Three
// outcomes are therefore tellable apart: kept, moved to a foreign corner, and
// zeroed. A cube would carry no per-corner plane at all and half this file
// would be vacuous on it.
// ---------------------------------------------------------------------------
private Mesh standMesh() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addVertex(Vec3(2, 0, 0));
    m.addVertex(Vec3(2, 1, 0));
    m.addFace([0, 1, 2, 3]);
    m.addFace([1, 4, 5, 2]);
    m.buildLoops();
    m.syncSelection();

    MeshMap uv;
    uv.name   = "uv";
    uv.dim    = 2;
    uv.domain = MapDomain.PolyVertex;
    uv.data.length = m.loops.length * 2;
    foreach (li; 0 .. m.loops.length) {
        uv.data[li * 2]     = 1.0f   + li;
        uv.data[li * 2 + 1] = 100.0f + li;
    }
    m.meshMaps ~= uv;
    return m;
}

private float[] uvOf(ref Mesh m) {
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.PolyVertex) return mm.data;
    return null;
}

private MeshOpEntry.Kind[] kindsOf(ref MeshEditDelta d) {
    MeshOpEntry.Kind[] ks;
    foreach (ref e; d.log) ks ~= e.kind;
    return ks;
}

private FaceIdx fx(ref Mesh m, size_t i) {
    foreach (fi; m.faceIndices) if (fi.raw == i) return fi;
    assert(false, "no such face");
}

private uint[] reversedWinding(ref Mesh m, size_t fi) {
    auto w = m.faces[fi].dup;
    reverse(w);
    return w;
}

// ---------------------------------------------------------------------------
// W-P1-0 — NON-VACUITY, asserted first and in this module.
//
// Every cell below is a statement about a recording batch over a mesh whose
// windings really change and whose per-corner plane really exists. If the
// stand's map were absent, `recordPolyVertexPayload` would decline and the
// payload rows would be green under any design; if the reversed winding
// equalled the original (a 2-gon, a symmetric list), the writer's identity
// filter would drop the write and the revert rows would be green under any
// design too.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    assert(m.hasPolyVertexMap(),
        "W-P1-0: the stand must carry a PolyVertex map — every payload row "
      ~ "below is vacuous without one");
    assert(uvOf(m).length == m.loops.length * 2,
        "W-P1-0: the map must be in step with the corner space, or "
      ~ "recordPolyVertexPayload declines");
    foreach (fi; 0 .. m.faces.length)
        assert(reversedWinding(m, fi) != m.faces[fi],
            format("W-P1-0: face %s reads the same reversed — the writer's "
                 ~ "identity filter would drop it and every revert row would "
                 ~ "be vacuous", fi));
    // And the writer is genuinely INERT with no batch open: no recorder, no
    // entry, but the write still lands. (This is the state every legacy
    // caller and every interactive preview is in.)
    auto w = reversedWinding(m, 0);
    assert(m.setFaceWinding(fx(m, 0), w),
        "W-P1-0: the write must land with no batch open");
    assert(m.faces[0] == w, "W-P1-0: … and it must be the winding handed in");
}

// ---------------------------------------------------------------------------
// W-P1-a — the SINGLE form: the op-log shape, and the inverse.
//
// KIND SEQUENCE, never length: a length assertion is satisfied by a log with
// something interposed between the payload and the entry it belongs to, and
// that adjacency is contractual (`CornerCarry.payloadForCount`) — an unpaired
// payload silently zeroes a per-corner map while the geometry round-trips.
//
// Mutation: swap the `before`/`after` arguments at the `recordReshapeFaces`
// call inside `setFaceWinding`. Face, vertex and edge COUNTS are unchanged
// either way; only the per-winding compare below reddens, and it names the
// face and prints both windings.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    const uint[] pre = m.faces[0].dup;
    auto want = reversedWinding(m, 0);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kTestScope);
        assert(m.setFaceWinding(fx(m, 0), want), "W-P1-a: the write must land");
        d = ed.close();
    }

    assert(m.faces[0] == want,
        format("W-P1-a: the forward did not install the winding: %s", m.faces[0]));
    assert(kindsOf(d) == [MeshOpEntry.Kind.MeshMapDelta,
                          MeshOpEntry.Kind.ReshapeFaces],
        format("W-P1-a: op-log kinds are %s, expected "
             ~ "[MeshMapDelta, ReshapeFaces] — the payload must be adjacent "
             ~ "and IMMEDIATELY BEFORE its entry", kindsOf(d)));

    assert(d.revert(m), "W-P1-a: revert must answer true");
    assert(m.faces[0] == pre,
        format("W-P1-a: revert installed %s, expected the PRE-op winding %s — "
             ~ "a transposed before/after lands exactly here and nowhere else",
               m.faces[0], pre));
}

// ---------------------------------------------------------------------------
// W-P1-b — the CORNER PERMUTATION survives the round trip.
//
// THIS IS THE CELL THE WRITER EXISTS FOR, and it is the one that a geometry
// assertion cannot reach. `mesh_edit_delta.d`'s comment on `renumbersCorners`
// states the residual in as many words: an equal-arity reshape that PERMUTES
// a face's corner order keeps the slots and changes what sits under them, and
// neither that predicate nor `CornerCarry.reshapeSrc`'s slot-for-slot run
// notices — so a revert that restores the winding and not the corner order
// leaves `vertices`, `faces`, every mark word and every count BYTE-IDENTICAL
// and corrupts only `meshMaps`.
//
// The forward here MODELS `Mesh.flipFacesByMask`: that kernel reverses the
// winding and declares `rw.relocated(...)` so the per-corner values follow it
// (mesh.d, `needUV` arm). The model permutes the plane by hand instead of
// going through the obligation machinery, because P1 migrates no kernel and
// there is nothing yet that does both through this door. What is being pinned
// is the DELTA's half: that the entry the writer recorded can put the plane
// back.
//
// Mutation: delete the `recordPolyVertexPayload(idx[])` line in
// `setFaceWinding`. `faces`, the counts and every mark word still round-trip;
// only the map compare below reddens, naming the corner.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    const uint[] preFace = m.faces[0].dup;
    const float[] preUv  = uvOf(m).dup;

    auto want = reversedWinding(m, 0);
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kTestScope);
        assert(m.setFaceWinding(fx(m, 0), want), "W-P1-b: the write must land");
        // The relocation `flipFacesByMask` declares, spelled out: face 0 owns
        // corners [0 .. n), and corner j now takes what corner (n-1-j) held.
        auto uv = uvOf(m);
        const size_t n = m.faces[0].length;
        float[] rot;
        rot.length = n * 2;
        foreach (j; 0 .. n) {
            rot[j * 2]     = uv[(n - 1 - j) * 2];
            rot[j * 2 + 1] = uv[(n - 1 - j) * 2 + 1];
        }
        uv[0 .. n * 2] = rot[];
        d = ed.close();
    }

    assert(uvOf(m) != preUv,
        "W-P1-b: the forward did not move the per-corner plane — the revert "
      ~ "claim below would be trivially satisfied");

    assert(d.revert(m), "W-P1-b: revert must answer true");
    assert(m.faces[0] == preFace, "W-P1-b: the winding half must round-trip");
    auto post = uvOf(m);
    assert(post.length == preUv.length,
        format("W-P1-b: the map changed length across the round trip: %s vs %s",
               post.length, preUv.length));
    foreach (i, v; preUv)
        assert(post[i] == v,
            format("W-P1-b: corner value %s came back as %s, expected %s — the "
                 ~ "winding round-tripped and the PLANE did not, which is the "
                 ~ "one failure mode that leaves every count byte-identical",
                   i, post[i], v));
}

// ---------------------------------------------------------------------------
// W-P1-c — an identity write records nothing, and an out-of-range index is a
// guard rather than a crash.
//
// Both arms matter to the entry's integrity: an identity reshape in the log
// is an entry whose inverse is a no-op, which is harmless but makes a kind
// sequence unreadable; and the out-of-range `continue` is a BEHAVIOUR CHANGE
// from the raw `faces[fi] = …` it replaces (that raised `ArrayIndexError`),
// so it is asserted here on purpose rather than discovered later.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kTestScope);
        assert(!m.setFaceWinding(fx(m, 1), m.faces[1].dup),
            "W-P1-c: an identity winding must not be installed");
        assert(!m.setFaceWinding(FaceIdx.assumeFaceSpace(99), [0u, 1u, 2u]),
            "W-P1-c: an out-of-range face index must be refused, not written");
        d = ed.close();
    }
    assert(d.log.length == 0,
        format("W-P1-c: op-log carries %s entr(ies) for two refused writes",
               d.log.length));
}

// ---------------------------------------------------------------------------
// W-P1-d — the ALIASING GUARD.
//
// `reverse(faces[fi])` is the exact spelling `flipFacesByMask` uses today, and
// a kernel migrated by reflex would reverse in place and then hand `faces[fi]`
// to the writer. The before-image would then already BE the after-image: the
// entry records an identity, the mesh changes, and the undo silently does
// nothing. An in-place reverse keeps the array's pointer, which is what the
// guard compares.
//
// This cell is `-debug`-only by construction (an `assert` is what fires), and
// the unit lane is a `-debug` build.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    auto ed = MeshEditBatch(m, kTestScope);
    reverse(m.faces[0]);                        // the reflex migration
    assertThrown!AssertError(m.setFaceWinding(fx(m, 0), m.faces[0]),
        "W-P1-d: handing the writer the live, already-mutated winding must "
      ~ "trip the aliasing guard");
    ed.close();
}

// ---------------------------------------------------------------------------
// W-P1-e — the BULK form: one entry pair for the whole set, and it inverts.
//
// The entry-count claim is the structural half of the reason the bulk form
// exists at all: `recordPolyVertexPayload` resolves each face's corner base by
// one ordered sweep over `faces`, so N single calls cost N sweeps — O(N·F) —
// and append 2N `MeshOpEntry` where the bulk form appends 2. The timing half
// is in the card; this is the half a test can hold.
//
// Mutation: make the bulk form loop over `setFaceWinding`. The windings still
// round-trip; only the entry-count assertion reddens.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    const uint[] pre0 = m.faces[0].dup;
    const uint[] pre1 = m.faces[1].dup;
    auto w0 = reversedWinding(m, 0);
    auto w1 = reversedWinding(m, 1);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kTestScope);
        const size_t n = m.setFaceWindings([fx(m, 0), fx(m, 1)], [w0, w1]);
        assert(n == 2, format("W-P1-e: %s of 2 windings installed", n));
        d = ed.close();
    }

    assert(kindsOf(d) == [MeshOpEntry.Kind.MeshMapDelta,
                          MeshOpEntry.Kind.ReshapeFaces],
        format("W-P1-e: op-log kinds are %s — the bulk form must record ONE "
             ~ "payload and ONE entry for the whole set, not one pair per "
             ~ "face", kindsOf(d)));

    assert(d.revert(m), "W-P1-e: revert must answer true");
    assert(m.faces[0] == pre0 && m.faces[1] == pre1,
        format("W-P1-e: revert restored %s / %s, expected %s / %s",
               m.faces[0], m.faces[1], pre0, pre1));
}

// ---------------------------------------------------------------------------
// W-P1-f — the bulk form's FILTER, and that the two forms agree.
//
// A set holding one identity write and one out-of-range index must record the
// hits ONLY: an entry whose `fIdx` and `faceLists*` are out of step with each
// other is the shape that makes a revert write one face's winding onto
// another. The N-single-call comparison is what makes the entry-count row
// above a measurement of the bulk form rather than of the stand.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = standMesh();
    const uint[] pre0 = m.faces[0].dup;
    auto w0 = reversedWinding(m, 0);

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kTestScope);
        const size_t n = m.setFaceWindings(
            [fx(m, 0), fx(m, 1)],
            [w0, m.faces[1].dup]);          // second is an identity write
        assert(n == 1, format("W-P1-f: %s of 1 real write installed", n));
        d = ed.close();
    }
    assert(kindsOf(d) == [MeshOpEntry.Kind.MeshMapDelta,
                          MeshOpEntry.Kind.ReshapeFaces],
        format("W-P1-f: op-log kinds are %s", kindsOf(d)));
    assert(d.log[1].fIdx.length == 1,
        format("W-P1-f: the entry names %s faces, expected the 1 that was "
             ~ "actually written", d.log[1].fIdx.length));
    assert(d.revert(m), "W-P1-f: revert must answer true");
    assert(m.faces[0] == pre0, "W-P1-f: the one real write must invert");

    // And the per-element path over the same two writes records TWICE as many
    // entries — the structural cost the bulk form removes.
    Mesh m2 = standMesh();
    MeshEditDelta d2;
    {
        auto ed = MeshEditBatch(m2, kTestScope);
        m2.setFaceWinding(fx(m2, 0), reversedWinding(m2, 0));
        m2.setFaceWinding(fx(m2, 1), reversedWinding(m2, 1));
        d2 = ed.close();
    }
    assert(d2.log.length == 4,
        format("W-P1-f: two single writes recorded %s entries, expected 4 "
             ~ "(a payload and an entry each) — the number the bulk form "
             ~ "collapses to 2", d2.log.length));
}
