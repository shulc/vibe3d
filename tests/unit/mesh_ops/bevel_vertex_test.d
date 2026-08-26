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

    // THE FINDING, MEASURED.
    //
    // Nine faces became ten, every one of the four faces around vertex 5 was
    // re-ringed, and the op-log is three entries:
    //
    //     entries=3 kinds=[AddVerts RemoveVerts Reindex]
    //
    // — the vertex side of the edit and nothing else. Unlike its fin sibling
    // this kernel DOES hand its new face array to `mesh_planes.rewriteFaces`;
    // that primitive's `Kind.FaceReindex` publisher is merely DISARMED
    // (`MeshEditTracker.wantsFaceReindex` is false), which is the shape Stage
    // K's per-rewrite arming scope reaches. Told apart from the fin family's
    // ABSENT publisher by arming the flag and measuring, which is the only way
    // the two can be distinguished (E3 memo 12).
    //
    // ARMING IT IS NOT THE FIX, AND THAT IS MEASURED TOO. With
    // `MeshEditTracker.wantsFaceReindex = true` at its declaration the log
    // becomes `[AddVerts FaceReindex RemoveVerts Reindex]` and `revert()` stops
    // throwing — it answers **`true`** — but the mesh does NOT come back. On
    // this stand the revert loses, every one of them a plane the op-log never
    // enumerated:
    //
    //     faceMarks[4]   Select 1 -> 0        (the pre-op face selection)
    //     vertexMarks[1] Select 1 -> 0
    //     edgeMarks[3]   Select 1 -> 0
    //     vertexSelectionOrder[1]      1 -> 0
    //     vertexSelectionOrderCounter  1 -> 0
    //     vertexSetMask  — the "V" vertex set emptied and grown to stale slots
    //     edgeSetMask    — 2 entries -> 1 (key 4294967301 gone)
    //
    // SEVEN planes, and the E4 review attributed each on the armed build, by
    // variant: (B) moving `setFaceMarksFrom` in front of `rewriteFaces` loses
    // the SAME seven — the rewrite then carries the already-cleared word and
    // the `FaceReindex` reverse restores it faithfully; (C) DELETING that
    // clear recovers `faceMarks` alone; (D) dropping the tail
    // `clearVertexSelection()` recovers exactly `vertexMarks`,
    // `vertexSelectionOrder` and the counter. `edgeMarks` and both set masks
    // survive no variant — they are the edge-array rebuild and set resize in
    // `finalizeTopologyEdit`, not face planes, so no `FaceReindex` could
    // carry them. And `faceSelectionOrder[i] = 0` over the cap range is not a
    // cause at all: it writes only appended slots, and `faceSelectionOrder`
    // survives in every variant. So the remedy L7 owes is a MARKS publisher
    // (plan L0's first production publishers) for the face half, L0 again
    // for the vertex/edge half, or a stated `MeshSnapshot` refusal — a
    // reorder is measured to be a no-op. One more thing L7 must weigh: on a
    // PolyVertex-carrying stand the FORWARD op already zeroes the whole UV
    // map (identical OLD/NEW, recorded/unrecorded — pre-existing), and
    // today's `MeshSnapshot` undo restores `meshMaps` where a delta would
    // not; flipping this family off the snapshot regresses UV undo unless
    // 0830/0901 closes first.
    //
    // STAGE K/L7 FLIPS THIS.
    assert(d.log.length == 3,
        format("the vertex chamfer recorded %d op-log entr(ies) %s, expected "
             ~ "exactly 3. If a face entry has appeared, K/L7 has armed the "
             ~ "rewrite — good news, and this block's whole comment plus plan "
             ~ "§5.3's row move with it, including the seven planes the armed "
             ~ "revert was measured to lose (task 1903 Stage E4).",
               d.log.length, kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.AddVerts)    == 1
        && countKind(d, MeshOpEntry.Kind.RemoveVerts) == 1
        && countKind(d, MeshOpEntry.Kind.Reindex)     == 1,
        format("the vertex chamfer's op-log is %s, expected exactly one each of "
             ~ "AddVerts / RemoveVerts / Reindex (task 1903 Stage E4).",
               kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0
        && countKind(d, MeshOpEntry.Kind.AddFaces)     == 0
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0,
        format("the vertex chamfer's op-log now names a face change (%s) — see "
             ~ "the block comment: arming `wantsFaceReindex` produces exactly "
             ~ "that, and it makes `revert()` answer `true` while silently "
             ~ "dropping seven selection/set planes. If this is deliberate, L7 "
             ~ "owes the plane fix in the same change (task 1903 Stage E4).",
               kindsOf(d)));

    // `d.revert(m)` is NOT called here, and that is MEASURED rather than
    // cautious. Unarmed it THROWS out of `finalize` -> `buildLoops`
    // ("index [16] is out of bounds for array of length 16") and leaves the
    // mesh HALF-REVERTED: V back to the pre-op 16 with F still 10, and TWELVE
    // face corners pointing at split vertices up to index 19 that no longer
    // exist. Unreachable in production today — the command and both tool entry
    // points open UNRECORDED batches — which is why it is written down before
    // L7 walks into it.
}
