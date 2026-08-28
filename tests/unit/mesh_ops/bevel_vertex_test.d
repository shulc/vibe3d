module tests.unit.mesh_ops.bevel_vertex_test;

import mesh;
import math;
import mesh_ops.bevel_vertex;

// Site 10 (task 1902 Stage E) — bevelVerticesByMask's single rebuild pass:
// identity range (every survived/substituted face keeps its OWN old index,
// so its own material/part/setmask/order/marks ride through unchanged) +
// capSrc-sourced cap range (the cap N-gon inherits material/part/setmask/
// marks from its ONE donor face, task 1240's `capSrc`, not the chamfer 0u
// literal). No existing test (`tests/test_vertex_bevel.d`'s Subpatch-carry
// HTTP check is the closest) asserts material/part by value.
//
// faceSelectionOrder gets a post-`rewriteFaces` override too (plan §2.7a:
// a cap face must start at rank 0, not inherit its donor's stamp), but —
// unlike extrude's sites — it is USUALLY not independently observable here
// (task 1902 Step 0 review correction: the claim below used to say the tail
// "unconditionally" re-selects the WHOLE `capStart .. faces.length` range
// "regardless" of the override — that overstates it). The kernel's own tail
// (`faceSelectionOrderCounter = 0; foreach (fi; capStart .. faces.length)
// selectFace(cast(int)fi);`) re-selects every CREATED face that is NOT
// hidden — `selectFace` early-returns on `Marks.Hide` — which overwrites
// `faceSelectionOrder` for each one it touches regardless of what the
// override left behind. So the override is invisible from outside this
// function ONLY when the cap's donor is not hidden; when it is, the whole
// `faceMarks` word — Hide included — rides onto the cap through the same
// `oldOfNew` carry that would otherwise let the cap inherit the donor's
// order too, and the tail reselect then skips it, leaving this override as
// the sole writer of the cap's order. See
// `tests/unit/mesh_ops/edge_bevel_test.d`'s hub-cap witness (task 1902 Step
// 0) for a driven mutation exercising exactly this at a sibling kernel; the
// same mechanism applies here but is not separately witnessed in this file.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);   // 3x3 grid, 9 quads; vertex 5 is interior (valence 4)
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }

    bool[] mask = new bool[](m.vertices.length);
    mask[5] = true;   // interior vertex shared by faces 0, 1, 3, 4

    size_t n;
    { auto ed = MeshEditBatch.unrecorded(m, kBevelVertexEditScope);
      n = ed.bevelVerticesByMask(mask, 0.1f); ed.close(); }
    assert(n == 1, "grid vertex-bevel: expected 1 accepted vertex, got " ~ n.to!string);
    // 9 survived/substituted originals + 1 cap N-gon (valence 4 -> quad cap).
    assert(m.faces.length == 9 + 1,
        "grid vertex-bevel: expected 9 substituted + 1 cap, got "
        ~ m.faces.length.to!string);

    // Survived/substituted range keeps its OWN material/part at its OWN old
    // index (the primitive's identity oldOfNew for this range).
    foreach (fi; 0 .. 9) {
        assert(m.faceMaterial[fi] == 1000 + fi,
            "grid vertex-bevel: original face " ~ fi.to!string ~ " lost its material");
        assert(m.facePart[fi] == 2000 + fi,
            "grid vertex-bevel: original face " ~ fi.to!string ~ " lost its part");
    }

    // The cap (position 9) inherits its ONE donor's material/part — the
    // kernel's own comment says the donor is "the first face of `vi`'s fan
    // walk" (`facesAroundVertex(vi)`, not the lowest-index incident face).
    // Measured directly (task 1902 Step 0), not guessed: a standalone probe
    // over this exact fixture prints `facesAroundVertex(5) == [3, 0, 1, 4]`,
    // so the donor is face 3 — deterministically, not "one of the 4".
    assert(m.faceMaterial[9] == 1003,
        "grid vertex-bevel: cap must inherit material from its ONE donor, "
        ~ "facesAroundVertex(5)'s first hit (face 3), got "
        ~ m.faceMaterial[9].to!string);
    assert(m.facePart[9] == 2003,
        "grid vertex-bevel: cap must inherit part from the SAME donor face "
        ~ "(face 3) as its material, got " ~ m.facePart[9].to!string);
}

// ===========================================================================
// Task 1903 Stage E4 — the batch, and what the op-log says.
// ===========================================================================

import std.format : format;
import mesh_edit_delta;
import mesh_selsets : selSetEditPolygon, selSetEditVertex, selSetEditEdge, SetEditMode;

/// A grid with every mark plane non-empty and non-uniform, and it SELECTS.
/// Load-bearing for the same reason `recCutStand` / `recFinStand` are: the
/// delta declares `MeshEditScope.Marks`, and on a stand where every mark word
/// is zero "the marks were carried" and "there were no marks" are the same
/// measurement (Stage E2 review, BLOCKER B1).
///
/// A GRID, not a cube. The chamfer must leave faces it never touches, so a
/// carried plane on a SURVIVING face is something the assertions below can
/// actually be wrong about — and a cube corner would additionally make every
/// candidate acceptance law agree.
private Mesh recVertStand() {
    Mesh m = makeGridPlane(3);
    m.buildLoops();
    m.syncSelection();
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(fi % 2);
        m.facePart[fi]     = cast(uint)(fi * 3);
    }
    m.setSubpatch(1, true);
    m.selectFace(4);
    m.selectVertex(1);
    m.selectEdge(3);
    m.faceSelectionOrder[2] = 11;
    bool[] ps = new bool[](m.faces.length);    ps[4] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, ps);
    bool[] vs = new bool[](m.vertices.length); vs[0] = true; vs[5] = true;
    selSetEditVertex(m, "V", SetEditMode.replace, vs);
    bool[] es = new bool[](m.edges.length);    es[1] = true; es[4] = true;
    selSetEditEdge(m, "E", SetEditMode.replace, es);
    return m;
}

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

private string kindsOf(ref MeshEditDelta d) {
    import std.conv : to;
    string s = "[";
    foreach (i, ref e; d.log) { if (i) s ~= " "; s ~= e.kind.to!string; }
    return s ~ "]";
}

unittest { // ONE stamp, however many vertices are chamfered — and it SCALES
    // The cell is a SCALE check, not a location check. Measured on this stand
    // with the deferral disabled (M-E4-BATCH: `if (false) if (auto f =
    // currentBatchFrame(&this))` in Mesh.commitChange): ONE accepted vertex
    // costs 8 stamps, TWO cost 12. The batch holds both at 1, and the
    // amplitude grows with the operand — which is the half a single-vertex
    // cell cannot see (E3 memo 11: a suite counter cannot separate "one batch
    // over the operand" from "a batch per element" at all, so the unit lane
    // owns this one).
    static immutable ulong[2] kUnbatched = [8, 12];
    foreach (i, verts; [[5], [5, 10]]) {
        Mesh m = recVertStand();
        bool[] mask = new bool[](m.vertices.length);
        foreach (v; verts) mask[v] = true;

        immutable ulong base = m.mutationVersion;
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(m, kBevelVertexEditScope);
            n = ed.bevelVerticesByMask(mask, 0.12f);
            ed.close();
        }
        immutable ulong d = m.mutationVersion - base;

        // ANTI-VACUITY: the kernel returns 0 on every refusal, and a refusal
        // makes no commits, so `d == 1` would fail — but pin the work anyway,
        // because a future refusal that stamped once would sail through.
        assert(n == verts.length,
            format("the stand chamfered %d of %d requested vertices — the "
                 ~ "assertions below would be measuring a refusal "
                 ~ "(task 1903 Stage E4)", n, verts.length));
        assert(d == 1,
            format("a %d-vertex chamfer bumped mutationVersion by %d, expected "
                 ~ "exactly 1. The `MeshEditBatch` its caller opens — the "
                 ~ "command in commands/mesh/vertex_bevel.d, the tool in "
                 ~ "tools/edit/vertex_bevel_tool.d — is what defers every "
                 ~ "internal commit to one close(). Without it this reads %d on "
                 ~ "this stand, and the figure grows with the operand (8 for "
                 ~ "one vertex, 12 for two) (task 1903 Stage E4).",
                   verts.length, d, kUnbatched[i]));
    }
}

/// The scope this family declares, written out from the enum INDEPENDENTLY of
/// `kBevelVertexEditScope` — `d.scope_` IS that constant fed through
/// `MeshEditTracker.declare`, so comparing them proves nothing on its own (a
/// draft of exactly that shape stayed green under `enum uint kReduceEditScope
/// = 0;` at Stage D2). Written from what the kernel DOES: it adds one split
/// vertex per incident edge and drops the chamfered ones (Points), rewrites
/// every incident face and appends a cap N-gon (Polygons), and re-does the
/// face selection, its order and the whole marks word (Marks). NOT `Position`:
/// no existing vertex moves.
private enum uint kExpectedVertScope = MeshEditScope.Points
                                     | MeshEditScope.Polygons
                                     | MeshEditScope.Marks;

unittest { // the vertex chamfer's op-log NAMES NO FACE CHANGE, and its revert FAULTS
    Mesh m = recVertStand();

    // STAND CANARY — asserts the stand, not the code under test.
    assert(m.isFaceSelected(4) && m.isVertexSelected(1) && m.isEdgeSelected(3)
           && m.isFaceSubpatch(1) && m.faceSelectionOrder[2] == 11,
        "recVertStand selected/tagged nothing — the Marks half of the law below "
      ~ "would be vacuous (task 1903 Stage E4, and Stage E2 review BLOCKER B1 "
      ~ "for the shape)");

    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    bool[] mask = new bool[](m.vertices.length);
    mask[5] = true;   // the interior valence-4 vertex

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kBevelVertexEditScope);   // RECORDING
        n = ed.bevelVerticesByMask(mask, 0.12f);
        d = ed.close();
    }

    assert(n == 1 && m.vertices.length == preV + 3 && m.faces.length == preF + 1,
        format("the stand chamfered %d vertex/vertices (V %d -> %d, F %d -> %d), "
             ~ "expected 1 (V +3: four split points in, one vertex out; F +1: "
             ~ "the quad cap) — every assertion below would be vacuous on a "
             ~ "refusal", n, preV, m.vertices.length, preF, m.faces.length));

    assert(cast(uint)d.scope_ == kExpectedVertScope,
        format("a recording vertex chamfer declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks). Missing: 0x%x. Unexpected: 0x%x. "
             ~ "`MeshEditDelta.finalize` reads scope_ back on a revert to decide "
             ~ "what to bump and rebuild (task 1903 Stage E4)",
               cast(uint)d.scope_, kExpectedVertScope,
               kExpectedVertScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedVertScope));
    assert(cast(uint)d.scope_ == kBevelVertexEditScope,
        format("the delta's scope_ (0x%x) is not the kBevelVertexEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               cast(uint)d.scope_, kBevelVertexEditScope));

    // THE FINDING, MEASURED — AND STAGE L7-d FLIPPED IT (2026-08-28).
    //
    // WHAT THIS BLOCK USED TO ASSERT, kept because it is the reason the flip
    // is a result rather than an edit. Unarmed, the log was three entries —
    // `[AddVerts RemoveVerts Reindex]`, the vertex side of the edit and
    // nothing else — and `d.revert(m)` THREW out of `finalize` -> `buildLoops`
    // ("index [16] is out of bounds for array of length 16"), leaving the mesh
    // HALF-REVERTED (V back to 16 with F still 10, twelve corners pointing at
    // split vertices that no longer existed). This kernel DOES hand its new
    // face array to `mesh_planes.rewriteFaces`; that primitive's
    // `Kind.FaceReindex` publisher was merely DISARMED, which is the shape
    // Stage K's per-rewrite arming scope reaches — told apart from the fin
    // family's ABSENT publisher by arming the flag and measuring, which is the
    // only way the two can be distinguished (E3 memo 12).
    //
    // STAGE K MEASURED THE ARMING AND REFUSED IT, under one rule: *do not arm
    // when a VALUE is lost*. Armed, the log became
    // `[AddVerts MeshMapDelta FaceReindex RemoveVerts Reindex]`, the throw went
    // away and `revert()` answered `true` — but SEVEN planes did not come
    // back:
    //
    //     faceMarks[4]   Select 1 -> 0        (the pre-op face selection)
    //     vertexMarks[1] Select 1 -> 0
    //     edgeMarks[3]   Select 1 -> 0
    //     vertexSelectionOrder[1]      1 -> 0
    //     vertexSelectionOrderCounter  1 -> 0
    //     vertexSetMask  — the "V" vertex set emptied
    //     edgeSetMask    — 2 entries -> 1 (key 4294967301 gone)
    //
    // …plus, on a Point-map-carrying stand, `meshMaps["W"]` ZEROED at the
    // consumed vertex. That last one is a lost VALUE, and it is what Stage K
    // drew the line on.
    //
    // WHAT CHANGED IS THE OTHER ENTRY, NOT THIS KERNEL. `Kind.RemoveVerts`
    // gained the set-mask payload at stage L5-b and the Point-domain
    // map-value payload at L7-P3 (task 2330). Re-measured before arming, three
    // operands, EXACT residual both ways on `makeTaggedGridFull(3)`: the armed
    // revert now loses FIVE planes and every one of them is Select-class
    // (`vertexMarks`, `vertexSelectionOrder`, `edgeMarks`, `faceMarks`,
    // `orderCounters`). `vertexSetMask`, `edgeSetMask`, `meshMaps["W"]`,
    // `meshMaps["uv"]`, every position, every winding and all three counts come
    // back BYTE-IDENTICAL. No value is lost, so Stage K's own rule now PERMITS
    // the arming instead of refusing it.
    //
    // The five Select-class planes are `DenseSelectionUndo`'s, taken by
    // `commands/mesh/vertex_bevel.d` — not a publisher (§0.1: this family
    // CONSUMES the dense image). The residual row lives in
    // `tests/unit/face_reindex_arming_test.d`'s `bevelVerticesByMask` cell,
    // and the plane-for-plane oracle in
    // `tests/unit/undo_parity_l7d_test.d`.
    //
    // THE E4-ERA UV WARNING THAT USED TO END THIS BLOCK IS STALE AND IS NOT
    // CARRIED FORWARD. It read: *"on a PolyVertex-carrying stand the FORWARD op
    // already zeroes the whole UV map … flipping this family off the snapshot
    // regresses UV undo unless 0830/0901 closes first"*. That text predates
    // stages J and K. The FORWARD still drops the per-corner map (a real,
    // pre-existing defect owned by 0830/0901 — this kernel states it with
    // `dropCornerProvenance(CornerDrop.VertexBevelNoCase)`), but the REVERSE
    // restores the pre-op values out of the payload the armed `rewriteFaces`
    // now records, so the migration does NOT regress UV undo. Measured, not
    // inherited.
    // The op-log, as a KIND SEQUENCE and never a length: stage J made the
    // `[MeshMapDelta, <face entry>]` adjacency contractual, and an interposed
    // entry unpairs the corner carry SILENTLY while the geometry still
    // round-trips.
    // FOUR ENTRIES ON THIS STAND, NOT FIVE, AND THE MISSING ONE IS MEASURED
    // RATHER THAN TOLERATED: `recVertStand` is a bare `makeGridPlane(3)` with
    // no PolyVertex map, so `Mesh.recordPolyVertexPayload` returns on its
    // `hasPolyVertexMap()` line and the `FaceReindex` here is UNPAIRED BY
    // CONSTRUCTION. On a map-carrying stand the log is five and the pair is
    // present — `tests/unit/undo_parity_l7d_test.d` and
    // `tests/unit/l7d_vertex_bevel_delta_test.d` both run on
    // `makeTaggedGridFull(3)` and assert it. So this row must NOT be read as
    // "the pairing is optional"; it is the map-less half of the same law.
    assert(d.log.length == 4,
        format("the vertex chamfer recorded %d op-log entr(ies) %s, expected "
             ~ "exactly 4 on this map-less stand — [AddVerts FaceReindex "
             ~ "RemoveVerts Reindex]. THREE means stage L7-d's "
             ~ "`faceReindexScope()` arm in mesh_ops/bevel_vertex.d is gone "
             ~ "and the face array has no restorer at all — the state this "
             ~ "block used to pin, where `revert()` THREW out of "
             ~ "finalize -> buildLoops and left the mesh HALF-REVERTED.",
               d.log.length, kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.AddVerts)    == 1
        && countKind(d, MeshOpEntry.Kind.RemoveVerts) == 1
        && countKind(d, MeshOpEntry.Kind.Reindex)     == 1,
        format("the vertex chamfer's op-log is %s, expected exactly one each of "
             ~ "AddVerts / RemoveVerts / Reindex (task 1903 Stage E4).",
               kindsOf(d)));
    // EXACTLY ONE face entry, and NO per-corner payload on a stand with no
    // per-corner map. Two `FaceReindex` against one payload is the shape that
    // keeps `bevelEdgesByMask` unarmed to this day; the 1:1 pairing itself is
    // asserted on the map-carrying stands named above.
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex)  == 1
        && countKind(d, MeshOpEntry.Kind.MeshMapDelta) == 0
        && countKind(d, MeshOpEntry.Kind.AddFaces)     == 0
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0,
        format("the vertex chamfer's op-log is %s. This kernel performs ONE "
             ~ "`rewriteFaces` under ONE corner-rewrite handle, so exactly one "
             ~ "`FaceReindex` is owed — and NO `MeshMapDelta`, because this "
             ~ "stand carries no PolyVertex map for one to describe. A payload "
             ~ "appearing here means the stand grew a map and this row's "
             ~ "reasoning about the unpaired entry no longer holds.",
               kindsOf(d)));

    // AND THE REVERT RUNS, which is the half this block could not assert
    // before stage L7-d. Unarmed it threw out of `finalize` -> `buildLoops`
    // and left the mesh HALF-REVERTED; armed it round-trips. The plane-level
    // oracle is `tests/unit/undo_parity_l7d_test.d`; what is asserted here is
    // the ABSENCE of the throw and the three counts, so the intent is readable
    // at the site the throw used to be documented at.
    assert(d.revert(m),
        "the armed vertex chamfer's revert() answered false");
    assert(m.vertices.length == preV && m.faces.length == preF,
        format("the revert landed on V=%d F=%d against a pre-op %d/%d",
               m.vertices.length, m.faces.length, preV, preF));
}
