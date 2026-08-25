// plane_dump_test — `http_json.meshPlanesJson`, the plane-complete readback the
// per-family parity fixtures are frozen from (task 1903 Stage B, plan §6.3).
//
// The one design decision in that dump is that EDGE planes are keyed by
// ENDPOINT PAIR and never by edge index, because a delta replay rebuilds the
// edge array. This file is what makes that decision able to be wrong.
//
// THE TRAP THIS FILE WALKS AROUND, stated first because it caught this test
// during its own writing. "Dump → `rebuildEdges()` → dump → compare" does NOT
// discriminate the keying. `Mesh.rebuildEdges` re-derives `edges` from `faces`
// in a FIXED iteration order, so on an unchanged `faces` it reproduces the
// IDENTICAL index space — an index-keyed dump is byte-identical across it too.
// That cell is kept below as a CONTROL (it does prove the rebuild disturbs
// nothing), and it is labelled as one. The cell that discriminates is the
// second: the edge index space is PERMUTED with its per-edge data carried along,
// which is the shape a replay actually produces, and only an endpoint-keyed dump
// survives it. Its own positive control shows the index-keyed rendering of the
// same two states differing, so "they compared equal" cannot mean "nothing
// moved".
//
// THE SECOND FAMILY OF CELLS here is about the map registry, and it is a
// different failure in kind: `MeshMap.present` and `MeshMap.kind` are channels
// whose LOSS IS A LEGAL WRONG ANSWER — an empty presence channel MEANS "all
// present", and `kind` is stored rather than inferable — so every structural
// "the key is there" check in this file passes over a dump that carries
// neither. They need a differential cell of their own, with a control.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.plane_dump_test;

import std.format : format;

import mesh;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures : makeTaggedGridFull;

// ---------------------------------------------------------------------------
// Permute the edge index space, carrying every index-keyed edge plane with it.
//
// This is what `mesh_edit_delta.finalize` does in effect: the edge array comes
// back in a different order, and whatever is keyed to the OLD order has to be
// re-established from something index-free (`Kind.EdgeSelByEnds` does it from
// endpoints). Reversing is the cheapest permutation that moves every element
// off its old slot on an even-length array and is trivially its own inverse.
// ---------------------------------------------------------------------------
private void reverseEdgeIndexSpace(ref Mesh m)
{
    import std.algorithm.mutation : reverse;
    assert(m.edgeMarks.length == m.edges.length,
           "the permutation must carry a plane sized to the edge array");
    assert(m.edgeSelectionOrder.length == m.edges.length,
           "the permutation must carry a plane sized to the edge array");
    m.edges.reverse();
    m.edgeMarks.reverse();
    m.edgeSelectionOrder.reverse();
}

/// An INDEX-keyed rendering of the same two edge planes — the decoy. Nothing in
/// the product builds this; it exists so a cell can show what the dump would
/// have looked like had it kept the index space, and therefore that the
/// endpoint-keyed equality below is a result and not a tautology.
private string indexKeyedEdgeRendering(ref const(Mesh) m)
{
    import std.array : appender;
    auto s = appender!string();
    foreach (ei; 0 .. m.edges.length)
        s ~= format("%d:%d/%d;", ei,
                    ei < m.edgeMarks.length ? m.edgeMarks[ei] : 0u,
                    ei < m.edgeSelectionOrder.length ? m.edgeSelectionOrder[ei] : 0);
    return s.data;
}

// ===========================================================================
// CONTROL — `rebuildEdges()` on an unchanged `faces` disturbs nothing.
//
// This cell CANNOT fail under an index-keyed dump (see the header): the rebuild
// reproduces the same order. It is here because it does catch a different
// defect — a rebuild that reorders, resizes or clears a plane the dump reads.
// ===========================================================================

unittest // rebuildEdges over unchanged faces leaves the dump byte-identical
{
    auto m = makeTaggedGridFull();
    immutable string before = meshPlanesJson(m);

    m.rebuildEdges();

    immutable string after = meshPlanesJson(m);
    assert(before == after,
        "rebuildEdges over an unchanged `faces` changed the plane dump — the "
      ~ "re-derive is supposed to reproduce the same edge array, so something "
      ~ "the dump reads was resized or cleared by it");
}

// ===========================================================================
// THE DISCRIMINATOR — a PERMUTED edge index space dumps identically.
//
// Mutation: key `edgePlanes` by edge index (emit `"index": ei` and drop the
// `[lo, hi]` sort) → this cell reddens; the control above stays green.
// ===========================================================================

unittest // the edge planes survive a re-keying of the edge array
{
    auto m = makeTaggedGridFull();

    // NON-VACUITY, first: the stand must carry per-edge data that a permutation
    // can actually move. On a mesh with a uniform `edgeMarks` this whole cell
    // is a comparison of two identical arrays.
    size_t selEdges = 0;
    foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++selEdges;
    assert(selEdges >= 1 && selEdges < m.edges.length,
        format("the stand carries %s selected edges out of %s — a permutation "
             ~ "of a uniform plane moves nothing and this cell would be vacuous",
               selEdges, m.edges.length));

    immutable string before      = meshPlanesJson(m);
    immutable string beforeIndex = indexKeyedEdgeRendering(m);

    reverseEdgeIndexSpace(m);

    immutable string after      = meshPlanesJson(m);
    immutable string afterIndex = indexKeyedEdgeRendering(m);

    // The positive control: the index space DID move. Without this line an
    // endpoint-keyed dump and a no-op permutation are indistinguishable.
    assert(beforeIndex != afterIndex,
        "the permutation did not move the edge index space — the decoy "
      ~ "rendering is identical, so the equality below proves nothing");

    assert(before == after,
        "the plane dump changed across a pure RE-KEYING of the edge array. "
      ~ "Edge planes must be keyed by endpoint pair: a delta replay rebuilds "
      ~ "`edges` (mesh_edit_delta.finalize), so an index-keyed fixture compares "
      ~ "two different index spaces and reddens for a reason that has nothing "
      ~ "to do with the family under test");
}

// ===========================================================================
// The dump is plane-COMPLETE and non-vacuous.
// ===========================================================================

unittest // every plane the burn-in class covers appears, and carries content
{
    import std.algorithm.searching : canFind;

    auto m = makeTaggedGridFull();
    immutable string j = meshPlanesJson(m);

    // Structural: the key is present at all.
    foreach (key; ["\"vertices\"", "\"faces\"", "\"vertexMarks\"", "\"faceMarks\"",
                   "\"edgePlanes\"", "\"vertexSelectionOrder\"",
                   "\"faceSelectionOrder\"", "\"selectionOrderCounters\"",
                   "\"faceMaterial\"", "\"facePart\"", "\"surfaces\"",
                   "\"vertexSetNames\"", "\"vertexSetMask\"",
                   "\"edgeSetNames\"", "\"edgeSetMask\"",
                   "\"polygonSetNames\"", "\"faceSetMask\"", "\"meshMaps\""])
        assert(j.canFind(key),
            "meshPlanesJson omits " ~ key ~ " — a fixture cannot witness a "
          ~ "plane the dump does not carry");

    // Non-vacuity: an EMPTY plane reads the same as a plane a broken carry
    // zero-filled, so the keys above are worth nothing unless the stand fills
    // them. These are the four the fixture exists to add.
    assert(!j.canFind("\"edgeSetMask\": []"),
        "the edgeSetMask plane is empty in the dump — the AA plane is the one "
      ~ "whose re-key is the caller's obligation and the one most likely to be "
      ~ "forgotten");
    assert(!j.canFind("\"meshMaps\": []"), "the map registry is empty");
    assert(!j.canFind("\"surfaces\": []"), "the surface registry is empty");
    assert(!j.canFind("\"edgePlanes\": []"), "the edge planes are empty");

    // …and the dump must MOVE when the mesh does. A dump that emitted constant
    // keys with empty bodies would pass everything above.
    auto n = makeTaggedGridFull();
    n.selectFace(3);
    assert(meshPlanesJson(n) != j,
        "selecting one more face did not change the plane dump — it is not "
      ~ "reading the mesh");
}

// ===========================================================================
// THE MAP REGISTRY'S TWO SILENT CHANNELS — `present` and `kind`.
//
// These are the channels whose loss is a LEGAL WRONG ANSWER rather than a
// crash or a garbage value, which is the only reason they need a cell of their
// own: every structural check above passes over a dump that carries neither.
//
//   * `MeshMap.present` is documented "Empty ⇒ all present", so a carry that
//     drops it resurrects every absent entry and reads as a healthy dense map.
//     `mesh_edit_delta.d` carries it EXPLICITLY through renumber / reindex /
//     add / remove, and `MeshSnapshot.byteSize()` charges for it — so before
//     this cell the snapshot path paid for a plane the fixture could not see.
//   * `MeshMap.kind` is STORED and not inferable: the two morph kinds have
//     identical shape (Point, dim 3) and neither reserves a name.
//
// Each arm carries the SAME mutation shape the product would make (assign the
// field, dump, compare), and the last arm is the control that says the dump
// moves at all on this fixture.
//
// Mutation: delete the `"present"` emission from `http_json.meshPlanesJson` →
// the first arm reddens by name; delete `"kind"` → the second.
// ===========================================================================

unittest // the map registry carries `present` and `kind`, not only name/dim/data
{
    // ---- (1) the PRESENCE channel ----------------------------------------
    auto m  = makeTaggedGridFull();
    auto wm = m.meshMap("W");
    assert(wm !is null, "the stand must carry the Point-domain map");

    // Mark ONE element absent. Non-vacuity first: the channel has to be able
    // to say something the "empty ⇒ all present" convention does not.
    wm.present = new ubyte[](m.vertices.length);
    wm.present[] = 1;
    wm.present[3] = 0;
    assert(!wm.isPresent(3) && wm.isPresent(0),
        "the fixture did not actually make element 3 absent — with a uniform "
      ~ "presence channel this cell compares two identical states");

    immutable string withPresence = meshPlanesJson(m);

    // The exact loss a migrated kernel makes: the channel goes away, and by
    // the documented convention vertex 3 is present again. Byte-identical
    // `data`, byte-identical everything else.
    wm.present = null;
    immutable string withoutPresence = meshPlanesJson(m);

    assert(withPresence != withoutPresence,
        "dropping MeshMap.present left the plane dump BYTE-IDENTICAL. The "
      ~ "presence channel is documented `Empty => all present`, so a carry "
      ~ "that loses it silently resurrects every absent entry — a legal wrong "
      ~ "answer, and a fixture frozen from this dump would never witness it. "
      ~ "MeshSnapshot.byteSize() already charges for the plane; the dump must "
      ~ "read it");

    // ---- (2) MapKind ------------------------------------------------------
    auto n2 = makeTaggedGridFull();
    immutable string kindBefore = meshPlanesJson(n2);
    auto wm2 = n2.meshMap("W");
    assert(wm2 !is null && wm2.kind != MapKind.morphRelative,
        "the stand's Point map already reads as morphRelative — this cell "
      ~ "would change nothing");
    wm2.kind = MapKind.morphRelative;
    immutable string kindAfter = meshPlanesJson(n2);

    assert(kindBefore != kindAfter,
        "changing MeshMap.kind left the plane dump BYTE-IDENTICAL. `kind` is "
      ~ "STORED, never inferred — the two morph kinds have identical shape "
      ~ "(Point, dim 3) and neither reserves a name — so nothing else in the "
      ~ "dump can stand in for it, and a family that re-registers a map under "
      ~ "the wrong kind reads as parity");

    // ---- (3) the CONTROL: a plane the dump has always carried -------------
    // Without this the two arms above cannot be told apart from a dump that
    // stopped reading the map registry altogether.
    auto n3 = makeTaggedGridFull();
    immutable string ctlBefore = meshPlanesJson(n3);
    n3.meshMap("W").data[0] = 999.0f;
    assert(ctlBefore != meshPlanesJson(n3),
        "moving a map DATA value did not change the dump — the map registry "
      ~ "is not being read at all, and the two arms above are vacuous");
}

unittest // the provenance block is ALWAYS emitted, empty fields included
{
    import std.algorithm.searching : canFind;

    auto m = makeTaggedGridFull();

    // The healthy case: no metadata supplied, block still there. This is what
    // makes a change that drops the block redden here rather than only on a
    // fixture that happened to carry a SHA.
    assert(meshPlanesJson(m).canFind("\"provenance\""),
        "the provenance block must be emitted unconditionally — plan §6.3 "
      ~ "rule 2 makes `producedBy` the field a reviewer checks the ancestry of");

    PlaneDumpMeta meta;
    meta.producedBy = "1b5ba746deadbeef";
    meta.path       = "snapshot";
    meta.family     = "delete";
    meta.stand      = "makeTaggedGridFull";
    immutable string j = meshPlanesJson(m, meta);
    assert(j.canFind("\"producedBy\": \"1b5ba746deadbeef\""), "producedBy");
    assert(j.canFind("\"path\": \"snapshot\""), "path");
    assert(j.canFind("\"family\": \"delete\""), "family");
    assert(j.canFind("\"stand\": \"makeTaggedGridFull\""), "stand");
}

unittest // the dump parses as JSON — a fixture is read back, not just diffed
{
    import std.json : parseJSON, JSONType;

    auto m = makeTaggedGridFull();
    auto v = parseJSON(meshPlanesJson(m));
    assert(v.type == JSONType.object, "the dump must be a JSON object");
    assert(v["counts"]["faces"].integer == cast(long)m.faces.length);
    assert(v["edgePlanes"].array.length == m.edges.length,
        "one edgePlanes row per live edge");
    // The endpoint key is a PAIR, and it is ordered low-first — the property
    // the sort and the `edgeSetMask` decode both rely on.
    foreach (row; v["edgePlanes"].array) {
        auto ends = row["ends"].array;
        assert(ends.length == 2, "an edge key is a pair");
        assert(ends[0].integer < ends[1].integer,
            "the endpoint key must be ordered low-first, or two dumps of the "
          ~ "same edge can disagree on its key");
    }

    // `edgeSetMask` reaches the same [lo, hi] space by a DIFFERENT route: it
    // is not re-keyed from `m.edges` like the rows above, it is DECODED out of
    // the `ulong` key `mesh.edgeKey(a, b)` packs min-first
    // (`a < b ? a << 32 | b : b << 32 | a`). A swapped shift in that decode —
    // `lo = key & 0xFFFFFFFF`, `hi = key >>> 32` — still emits a well-formed
    // pair per entry, still sorts, still parses, and lands every AA row in the
    // MIRROR of the space `edgePlanes` uses. Nothing above can see it.
    assert(v["edgeSetMask"].array.length > 0,
        "the stand's edgeSetMask is empty in the parsed dump — the decode "
      ~ "below would be checking nothing");
    foreach (row; v["edgeSetMask"].array) {
        auto ends = row["ends"].array;
        assert(ends.length == 2, "an edgeSetMask key is a pair");
        assert(ends[0].integer < ends[1].integer,
            "an edgeSetMask row is keyed high-first. `edgeKey` packs the "
          ~ "SMALLER endpoint into the HIGH 32 bits, so the decode must read "
          ~ "`lo = key >>> 32`; swapped, every AA row lands in the mirror of "
          ~ "the space `edgePlanes` uses and the two edge planes stop being "
          ~ "comparable");
    }
}
