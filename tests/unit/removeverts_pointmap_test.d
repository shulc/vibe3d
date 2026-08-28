/// Task 1903 Stage L7-P3 — the POINT-DOMAIN MAP-VALUE payload on
/// `MeshOpEntry.Kind.RemoveVerts`.
///
/// WHAT THIS MODULE IS FOR. When a kernel consumes a vertex — a weld that
/// merges two into one, a bevel whose endpoints are eaten, any of the thirteen
/// L10 commands — the tail `Mesh.compactUnreferenced` drops it and records a
/// `[RemoveVerts, Reindex]` pair. On the reverse, `removeVertsReverse`
/// re-inserts the dropped vertex and, until this stage, wrote **0** into every
/// Point-domain `MeshMap` value and its `present` byte on all three of its
/// arms. Its own comment called that "a documented limit".
///
/// THE FAILURE THIS SHAPE PRODUCES IS THE ONE NO COUNTER SEES. Vertices, edges,
/// faces, every mark word, both set masks and the whole PolyVertex corner plane
/// come back byte-identical; a single weight/morph value comes back ZERO. So a
/// count assertion, a geometry assertion and a `revert() == true` all answer
/// correctly over the loss — which is why the two consumers that measured it
/// (`bevelEdgesByMask`'s arming, task card 2320; the weld twin, Stage L10)
/// recorded it as a residual rather than tripping over it.
///
/// EVERY CELL HERE IS AN ARMED-REVERT PLANE MEASUREMENT, never a forward one:
/// build the stand, dump the plane, run the kernel inside a RECORDING batch,
/// `revert()`, dump again, and report the residual as an EXACT list BOTH WAYS
/// (what the pre-op mesh had and the revert did not bring back, and what the
/// revert put there instead). The forward carry says nothing about the reverse.
module tests.unit.removeverts_pointmap_test;

import std.format : format;
import std.math : isNaN;

import math : Vec3;
import mesh : Mesh, MeshMap, MapDomain, MapKind;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshOpEntry, MeshEditScope;

// ---------------------------------------------------------------------------
// The stand
// ---------------------------------------------------------------------------

/// A mesh whose weld CONSUMES a vertex that carries a distinct Point-map value.
///
/// WHY NOT `makeTaggedGridFull`: a grid has no coincident vertices, so nothing
/// on it welds, and the whole phenomenon needs a vertex that is REMOVED rather
/// than merely renumbered. This is `mesh_selsets_test.mergeWeldFixture`'s
/// geometry — the shape `mesh_ops/cleanup.cleanupMesh` actually drives — with a
/// Point-domain map added, one distinct value per vertex.
///
/// THE WINDING `5,0,8,9` ON THE THIRD FACE IS LOAD-BEARING, and inherited from
/// that fixture: post-weld it shares edge (0,5) with `[0,5,6,7]`, which
/// traverses 0->5, so this one must traverse 5->0 or `buildLoops` reports an
/// inconsistently-wound pair.
private Mesh pointMapWeldStand()
{
    Vec3[] verts = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),   // A: 0-3
        Vec3(0, 0, 0), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1),   // C: 4-7, v4 dupes v0
        Vec3(0, -1, 0), Vec3(1, -1, 1),                               // D: 8-9
    ];
    Mesh m;
    foreach (v; verts) m.addVertex(v);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([5u, 0u, 8u, 9u]);
    m.buildLoops();
    m.syncSelection();

    auto wm = m.addMeshMap("W", 1, MapDomain.Point);
    assert(wm !is null, "stand: the Point-domain map must register");
    foreach (i; 0 .. wm.data.length)
        wm.data[i] = 0.5f + cast(float) i;
    return m;
}

/// The one plane this module is about, read off a mesh as a plain array.
private float[] pointMapValues(ref Mesh m, string name)
{
    foreach (ref mm; m.meshMaps)
        if (mm.name == name && mm.domain == MapDomain.Point)
            return mm.data.dup;
    return null;
}

private ubyte[] pointMapPresent(ref Mesh m, string name)
{
    foreach (ref mm; m.meshMaps)
        if (mm.name == name && mm.domain == MapDomain.Point)
            return mm.present.dup;
    return null;
}

/// The residual, BOTH WAYS and per element — the report the brief for this
/// stage asks for and the one a bare `!=` cannot give: which vertex, what the
/// pre-op mesh held there, and what the revert put there instead.
///
/// Never a bare "arrays differ": the failure being measured is a VALUE
/// substitution at one index inside an array whose LENGTH is already correct,
/// so a length report reads green over it.
private string mapResidual(string plane, in float[] want, in float[] got,
                           size_t dim = 1)
{
    // `dim` is not decoration: a dim-3 map's flat index 13 is vertex 4's
    // SECOND component, and a report that calls it "v13" hands the next reader
    // a wrong model of the mechanism — the exact failure card 2320 recorded
    // when a comment rounded "71 of 72" up to "all 72".
    string label(size_t i) {
        return dim <= 1 ? format("v%d", i)
                        : format("v%d[%d]", i / dim, i % dim);
    }
    string s = format("plane `%s`: length pre-op %d, post-revert %d",
                      plane, want.length, got.length);
    size_t n = want.length < got.length ? want.length : got.length;
    string missing, extra;
    foreach (i; 0 .. n) {
        if (want[i] == got[i]) continue;
        missing ~= format(" %s=%s", label(i), want[i]);
        extra   ~= format(" %s=%s", label(i), got[i]);
    }
    foreach (i; n .. want.length) missing ~= format(" %s=%s", label(i), want[i]);
    foreach (i; n .. got.length)  extra   ~= format(" %s=%s", label(i), got[i]);
    if (missing.length == 0 && extra.length == 0)
        return s ~ ", residual EMPTY both ways";
    return s ~ format(", NOT RESTORED (pre-op had):%s | INSTEAD THE REVERT LEFT:%s",
                      missing.length ? missing : " -",
                      extra.length   ? extra   : " -");
}

private uint countKind(in MeshEditDelta d, MeshOpEntry.Kind k)
{
    uint n = 0;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

private string kindsOf(in MeshEditDelta d)
{
    string s = "[";
    foreach (i, ref e; d.log) { if (i) s ~= " "; s ~= format("%s", e.kind); }
    return s ~ "]";
}

// ---------------------------------------------------------------------------
// Cell 1 — the defect, on the shipped weld funnel
// ---------------------------------------------------------------------------

unittest // W-7-P3-a: the consumed vertex's Point-map VALUE must come back
{
    Mesh m = pointMapWeldStand();
    const preV = m.vertices.length;
    const preE = m.edges.length;
    const preF = m.faces.length;
    const float[] preW = pointMapValues(m, "W");
    assert(preW.length == preV && preW[4] == 4.5f,
        format("stand: the Point map must carry one distinct value per vertex "
             ~ "and v4 — the vertex this weld CONSUMES — must be the "
             ~ "identifiable one. Got length %d for V=%d, v4=%s",
               preW.length, preV, preW.length > 4 ? format("%s", preW[4]) : "<none>"));

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded  = m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();

    // The stand assertions are phrased over OBSERVABLE CONSEQUENCES — a weld
    // that merged, a compaction that dropped, and a log that actually names the
    // entry this payload rides on — never over an intermediate the pipeline may
    // legitimately consume.
    assert(welded == 1 && removed == 1 && m.vertices.length == preV - 1,
        format("stand: expected exactly one weld and one dropped vertex, "
             ~ "V %d -> %d; got welded=%d removed=%d V=%d — every assertion "
             ~ "below is vacuous on a no-op",
               preV, preV - 1, welded, removed, m.vertices.length));
    assert(countKind(delta, MeshOpEntry.Kind.RemoveVerts) == 1,
        format("stand: the log must carry exactly one RemoveVerts — the entry "
             ~ "this stage's payload rides on. Log %s", kindsOf(delta)));

    assert(delta.revert(m), "the reverse replay must succeed");
    assert(m.vertices.length == preV && m.edges.length == preE
        && m.faces.length == preF,
        format("the revert must restore V/E/F (%d/%d/%d), got %d/%d/%d — the "
             ~ "map residual below is only meaningful over a restored topology",
               preV, preE, preF, m.vertices.length, m.edges.length, m.faces.length));

    const float[] postW = pointMapValues(m, "W");
    assert(postW == preW,
        "undo lost the Point-domain map VALUE of the vertex the weld consumed: "
      ~ "`compactUnreferenced` dropped v4 and `removeVertsReverse` re-inserted "
      ~ "it with a ZEROED map value. Every count, every position, both set "
      ~ "masks and the whole corner plane are equal — only this differs. "
      ~ mapResidual("map:W", preW, postW));
}

// ---------------------------------------------------------------------------
// Cell 2 — TWO Point maps, different dims, one of them presence-tracking.
//
// THE DISCRIMINATOR CELL 1 CANNOT BE. With a single dim-1 map, a payload laid
// out map-major and one laid out vertex-major are the SAME bytes, and a
// presence channel nobody tracks is never written. This stand separates them:
// `Σ dims` is 4, the stride slicing is observable, and the morph map's
// `present` byte is a plane of its own. A transposed layout, an `off` that does
// not advance per map, or a presence byte read from the wrong pair all redden
// here and NONE of them reddens on cell 1.
// ---------------------------------------------------------------------------

/// TWO coincident pairs on FOUR disjoint quads, and a SECOND Point-domain map.
///
/// TWO DROPPED VERTICES IS THE POINT, not a bigger stand for its own sake.
/// With ONE dropped vertex a vertex-major payload and a map-major one are the
/// SAME BYTES, so cell 1's stand cannot tell a correct layout from a transposed
/// one. With two, `[W(a) MA(a)x3 W(b) MA(b)x3]` and `[W(a) W(b) MA(a)x3
/// MA(b)x3]` differ, and the transposition reddens here while cell 1 stays
/// green — which is what makes this a second cell rather than a bigger first.
///
/// `MapKind.morphAbsolute` is Point/dim 3 and `tracksPresence`, and its
/// `absentIsZero` is FALSE — so a zeroed entry there is not a blank, it is a
/// different legal answer. That is the channel this payload exists for.
///
/// THE FOUR QUADS SHARE NO EDGE, before or after the weld: quad B meets quad A
/// at vertex 0 only and quad D meets quad C at vertex 8 only, so `buildLoops`
/// has no inconsistently-wound pair to report and the stand needs no winding
/// choreography of its own.
private Mesh twoPointMapWeldStand()
{
    Vec3[] verts = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),   // A: 0-3
        Vec3(0, 0, 0), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1),   // B: 4-7, v4 dupes v0
        Vec3(5, 0, 0), Vec3(6, 0, 0), Vec3(6, 1, 0), Vec3(5, 1, 0),   // C: 8-11
        Vec3(5, 0, 0), Vec3(6, 0, 2), Vec3(6, 1, 2), Vec3(5, 1, 2),   // D: 12-15, v12 dupes v8
    ];
    Mesh m;
    foreach (v; verts) m.addVertex(v);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([8u, 9u, 10u, 11u]);
    m.addFace([12u, 13u, 14u, 15u]);
    m.buildLoops();
    m.syncSelection();

    auto wm = m.addMeshMap("W", 1, MapDomain.Point);
    assert(wm !is null, "stand: the dim-1 Point map must register");
    foreach (i; 0 .. wm.data.length) wm.data[i] = 0.5f + cast(float) i;

    auto mo = m.addMeshMapOfKind(MapKind.morphAbsolute, "MA");
    assert(mo !is null && mo.dim == 3,
        "stand: the morph map must register as Point/dim 3");
    foreach (i; 0 .. m.vertices.length) {
        mo.data[i * 3 + 0] = 100.0f + i;
        mo.data[i * 3 + 1] = 200.0f + i;
        mo.data[i * 3 + 2] = 300.0f + i;
    }
    // Presence is per element and DIFFERS BETWEEN THE TWO DOOMED VERTICES:
    // v4 is PRESENT, v12 is ABSENT. A channel that is uniformly present cannot
    // tell a restored byte from a hard-coded 1, and a presence byte read from
    // the wrong (vertex, map) pair reads correct when the two agree.
    assert(mo.present.length == m.vertices.length,
        "stand: a morphAbsolute map must track presence per element");
    foreach (i; 0 .. mo.present.length) mo.present[i] = 1;
    mo.present[12] = 0;
    return m;
}

unittest // W-7-P3-b: stride, registration order, layout and the presence byte
{
    Mesh m = twoPointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW  = pointMapValues(m, "W");
    const float[] preMA = pointMapValues(m, "MA");
    const ubyte[] preP  = pointMapPresent(m, "MA");
    assert(preMA.length == preV * 3 && preP.length == preV
        && preMA[4 * 3] == 104.0f && preMA[12 * 3] == 112.0f
        && preP[4] == 1 && preP[12] == 0,
        format("stand: the morph map must be dim 3 with a presence channel "
             ~ "that DIFFERS between the two doomed vertices — got data %d, "
             ~ "present %d, present v4=%s v12=%s",
               preMA.length, preP.length,
               preP.length > 4  ? format("%s", preP[4])  : "<none>",
               preP.length > 12 ? format("%s", preP[12]) : "<none>"));

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded  = m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(welded == 2 && removed == 2 && m.vertices.length == preV - 2,
        format("stand: TWO welds and TWO dropped vertices are what makes the "
             ~ "payload's LAYOUT observable at all; got welded=%d removed=%d "
             ~ "V=%d (expected 2, 2, %d)",
               welded, removed, m.vertices.length, preV - 2));

    assert(delta.revert(m), "the reverse replay must succeed");

    const float[] postMA = pointMapValues(m, "MA");
    assert(postMA == preMA,
        "undo lost the dim-3 Point map's values at a consumed vertex. Two "
      ~ "dropped vertices are what separate a vertex-major payload from a "
      ~ "map-major one — with one, the two layouts are the same bytes. "
      ~ mapResidual("map:MA", preMA, postMA, 3));
    assert(pointMapValues(m, "W") == preW,
        "the dim-1 map's values must survive the SECOND map's presence in the "
      ~ "payload — an offset that does not advance per map writes one "
      ~ "channel's floats into another. "
      ~ mapResidual("map:W", preW, pointMapValues(m, "W")));

    const ubyte[] postP = pointMapPresent(m, "MA");
    assert(postP == preP,
        format("undo lost the PRESENCE byte of a consumed vertex. `present` is "
             ~ "a plane of its own — for a `morphAbsolute` map `absentIsZero` "
             ~ "is FALSE, so \"absent\" and \"zero\" are DIFFERENT answers and "
             ~ "a value-only restore is still wrong. plane `map:MA.present`: "
             ~ "pre-op %s, post-revert %s", preP, postP));
}

// ---------------------------------------------------------------------------
// Cell 3 — the REFUSAL, and that it is WHOLE
// ---------------------------------------------------------------------------

unittest // W-7-P3-c: a map VANISHES between record and revert — count drift
{
    import change_bus : changeBus;

    Mesh m = twoPointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW = pointMapValues(m, "W");

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(removed == 2,
        format("stand: the compaction must drop exactly two vertices, got %d "
             ~ "— the refusal below is only meaningful over a payload that "
             ~ "exists", removed));

    // History drift: the dim-3 map is GONE by revert time, so the payload
    // describes two channels and the live registry presents one.
    //
    // THIS DIRECTION AND NOT "a third map appears", which would be a weaker
    // cell: an EXTRA map is already refused by the dims term (the walk marks
    // `dimsOk` false the moment `liveCount` runs past the recorded list), so a
    // cell built on it cannot show the COUNT term doing anything. A map that
    // VANISHES leaves the recorded dims a correct PREFIX of the live registry
    // — every per-channel test passes — and only the count says no.
    assert(m.removeMeshMap("MA"),
        "stand: the dim-3 map must be removable, or this cell drifts nothing");

    const ulong refusedBefore = changeBus.mapDeltaBindRefused;
    assert(delta.revert(m),
        "`revert` must still answer TRUE over a refused map payload — a "
      ~ "refusal is not a failure, and a `false` here would pop the entry off "
      ~ "BOTH history stacks and truncate the suffix after it");
    assert(changeBus.mapDeltaBindRefused == refusedBefore + 1,
        format("the drifted payload must be REFUSED and SAY SO: "
             ~ "`mapDeltaBindRefused` moved by %d, expected exactly 1. Without "
             ~ "the tick, \"refused\" and \"there was nothing to restore\" are "
             ~ "the same observation with opposite right answers",
               changeBus.mapDeltaBindRefused - refusedBefore));

    // The geometry half of the SAME entry still ran — the one thing this kind
    // may not refuse.
    assert(m.vertices.length == preV,
        format("the vertex re-insertion must run even when the map payload is "
             ~ "refused: V came back %d, expected %d. Refusing the whole ENTRY "
             ~ "would leave the mesh SHORT A VERTEX, which is corruption, not "
             ~ "a documented limit", m.vertices.length, preV));

    const float[] postW = pointMapValues(m, "W");
    assert(postW.length == preV && postW[4] == 0f && postW[12] == 0f,
        "the payload describes a registry that no longer exists, so it is "
      ~ "refused WHOLE and falls back to the pre-L7-P3 zero-fill — `W` is "
      ~ "slot 0 and its dim still lines up, so a bind that checked only the "
      ~ "per-channel shape would restore it and call the job done. Same "
      ~ "two-term identity `CornerCarry`'s restore uses on the PolyVertex "
      ~ "side (count AND dims AND order). " ~ mapResidual("map:W", preW, postW));
}

unittest // W-7-P3-c2: the same COUNT, a different DIM — the other drift
{
    import change_bus : changeBus;

    // SEPARATE FROM c AND NOT A PARAMETER OF IT. The bind has two terms, and
    // they fail on different histories: c removes neither map and adds one
    // (count drift, dims still a prefix match); this one keeps the count and
    // changes a shape. A mutation that drops either term reddens exactly one
    // of the two cells, which is what makes them separable evidence rather
    // than one cell run twice.
    Mesh m = twoPointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW = pointMapValues(m, "W");

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(removed == 2, format("stand: expected two dropped vertices, got %d",
                                removed));

    // `MA` (dim 3) goes; `MB` (dim 2) arrives in its place. Two Point maps
    // before and two after — only the SECOND slot's dim moved, and the FIRST
    // slot (`W`, dim 1) still lines up with what the payload recorded.
    assert(m.removeMeshMap("MA"), "stand: the dim-3 map must be removable");
    auto mb = m.addMeshMap("MB", 2, MapDomain.Point);
    assert(mb !is null, "stand: the replacement dim-2 map must register");

    const ulong refusedBefore = changeBus.mapDeltaBindRefused;
    assert(delta.revert(m), "`revert` must still answer TRUE over a refusal");
    assert(changeBus.mapDeltaBindRefused == refusedBefore + 1,
        format("a same-count/different-dim registry must REFUSE: "
             ~ "`mapDeltaBindRefused` moved by %d, expected exactly 1",
               changeBus.mapDeltaBindRefused - refusedBefore));

    const float[] postW = pointMapValues(m, "W");
    assert(postW.length == preV && postW[4] == 0f && postW[12] == 0f,
        "THE REFUSAL IS WHOLE, NOT PER CHANNEL. `W` is slot 0 and its dim "
      ~ "still matches the payload, so a per-channel accept restores it and "
      ~ "leaves the map beside it wrong — which is exactly the shape Stage L1 "
      ~ "measured: a revert that restored a plane's LENGTH, zeroed every "
      ~ "value, and answered success. " ~ mapResidual("map:W", preW, postW));
}

// ---------------------------------------------------------------------------
// Cell 4 — REDO. The forward owes nothing, and this is how that is known.
// ---------------------------------------------------------------------------

unittest // W-7-P3-d: a forward replay must DROP the values again
{
    Mesh m = pointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW = pointMapValues(m, "W");

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    m.weldCoincidentVertices(1e-12);
    m.compactUnreferenced();
    auto delta = m.endEditBatch();
    const float[] postOpW = pointMapValues(m, "W");
    assert(postOpW.length == preV - 1,
        format("stand: the forward must have shortened the map to %d, got %d",
               preV - 1, postOpW.length));

    assert(delta.revert(m), "the undo must succeed");
    assert(pointMapValues(m, "W") == preW, "the undo must restore the values");

    // The half card 2310 paid for on the edge-set plane: fixing the undo can
    // BUY A LOSS ON THE REDO if the forward arm does not invert the reverse.
    // The forward here needs no payload of its own, and the reason is
    // MEASURED rather than read off the nearest plausible function:
    //
    //   the carrier is `applyReindexForward`'s Point-map GATHER, not
    //   `removeVertsForward`'s drop-filter. On the compaction path the log is
    //   `[RemoveVerts, Reindex]`, and `Reindex` forward re-gathers every
    //   Point map through `perm` — so it re-drops the restored value whatever
    //   the entry before it did. Defeating `removeVertsForward`'s own map
    //   filter changes NOTHING here (mutation M7, run and seen GREEN);
    //   defeating the gather reddens this cell (M7b). A comment naming the
    //   wrong one would have made this green look like coverage it is not.
    assert(delta.apply(m), "the redo must succeed");
    assert(pointMapValues(m, "W") == postOpW,
        "the REDO did not reproduce the forward's own map state. The reverse "
      ~ "now restores values the forward must drop again; if it does not, this "
      ~ "stage bought an undo with a redo. "
      ~ mapResidual("map:W", postOpW, pointMapValues(m, "W")));
}

// ---------------------------------------------------------------------------
// Cell 5 — a kernel for which the payload is INERT, saying so itself
// ---------------------------------------------------------------------------

unittest // W-7-P3-INERT: no Point-domain map on the stand
{
    Mesh m = pointMapWeldStand();
    // Drop the Point map, keeping the identical geometry and the identical
    // weld: the entry's Point payload has nothing to carry.
    m.meshMaps.length = 0;

    const preV = m.vertices.length;
    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded = m.weldCoincidentVertices(1e-12);
    m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(welded == 1, "stand: the weld must still merge");

    size_t payloadBytes = 0;
    foreach (ref e; delta.log)
        if (e.kind == MeshOpEntry.Kind.RemoveVerts)
            payloadBytes += e.mapDims.length + e.mapVals.length
                          + e.presentBefore.length;
    assert(payloadBytes == 0,
        format("THIS KERNEL CARRIES NO POINT-DOMAIN MAP, so the map arm of the "
             ~ "`RemoveVerts` payload is INERT here and this cell's green must "
             ~ "NOT be read as coverage of Stage L7-P3 — what it measures is "
             ~ "that a mesh without such a map pays ZERO extra bytes and keeps "
             ~ "the previous behaviour bit-for-bit. It recorded %d payload "
             ~ "element(s) instead", payloadBytes));

    assert(delta.revert(m), "the reverse must still succeed");
    assert(m.vertices.length == preV,
        "…and the geometry half is what this cell actually covers");
}

// ---------------------------------------------------------------------------
// Cell 6 — the ALL-ZERO drop: a payload that would restore nothing is not paid for
// ---------------------------------------------------------------------------

unittest // W-7-P3-e: an all-zero block is dropped, not stored
{
    Mesh m = pointMapWeldStand();
    // Same map, same weld — but every value is 0, so the recorded block would
    // be byte-for-byte what the zero-fill already writes.
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.Point) mm.data[] = 0f;

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded = m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(welded == 1 && removed == 1,
        "stand: the weld and the drop must still happen — otherwise there is "
      ~ "no RemoveVerts entry and this cell measures nothing");

    foreach (ref e; delta.log) {
        if (e.kind != MeshOpEntry.Kind.RemoveVerts) continue;
        assert(e.mapDims.length == 0 && e.mapVals.length == 0
            && e.presentBefore.length == 0,
            format("a payload whose every value is 0 restores exactly what the "
                 ~ "zero-fill already writes, so it must not be stored: the "
                 ~ "entry carries %d dim(s)/%d float(s)/%d presence byte(s). "
                 ~ "This is what keeps `MeshEditDelta.byteSize` — and §8's "
                 ~ "delta-vs-snapshot ratio — unmoved on a mesh that has "
                 ~ "nothing to restore", e.mapDims.length, e.mapVals.length,
                   e.presentBefore.length));
    }
    assert(delta.revert(m), "the reverse must succeed over the absent payload");
}

// ---------------------------------------------------------------------------
// Cell 7 — the TAIL-APPEND arm, driven by a hand-built entry
//
// `removeVertsReverse` has three arms and the compaction path reaches exactly
// ONE of them (gap-fill: `Reindex^-1` has already re-opened the slot). Cells
// 1-6 therefore leave two thirds of this stage's code unexecuted, which is the
// same "the recorder has no caller, so the branch never runs" reading the
// `HideDelta` Kind doc corrects: a hand-built `MeshOpEntry` driven straight at
// `revert` exercises the dispatch without a producer, and three unit modules
// already do exactly that for `patchHide`.
//
// THE THIRD ARM (`insertInPlace`, `vi > vertices.length`) IS NOT DRIVEN HERE
// and that is a statement, not an omission: the arms are keyed on `vi` against
// the CURRENT length, so reaching it needs `vi` past the end, which
// `insertInPlace` itself would reject. Its own comment says no live producer
// reaches it; this cell does not invent one.
// ---------------------------------------------------------------------------

unittest // W-7-P3-f: the tail-append arm restores values and presence too
{
    Mesh m = twoPointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW  = pointMapValues(m, "W");
    const float[] preMA = pointMapValues(m, "MA");
    const ubyte[] preP  = pointMapPresent(m, "MA");

    // Chop the last vertex off every per-vertex plane by hand, exactly as a
    // tail drop leaves them, then ask a `RemoveVerts` entry to put it back at
    // index `preV - 1` — which is now `vertices.length`, i.e. the tail-append
    // arm and no other.
    const uint doomed = cast(uint)(preV - 1);
    const Vec3 doomedPos = m.vertices[doomed];
    m.vertices.length = doomed;
    m.vertexMarks.length = doomed;
    foreach (ref mm; m.meshMaps) {
        if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
        mm.data.length = doomed * mm.dim;
        if (mm.present.length != 0) mm.present.length = doomed;
    }

    MeshOpEntry e;
    e.kind = MeshOpEntry.Kind.RemoveVerts;
    e.vIdx = [doomed];
    e.pos  = [doomedPos];
    e.mapDims = [cast(ubyte)1, cast(ubyte)3];
    e.mapVals = [preW[doomed],
                 preMA[doomed * 3], preMA[doomed * 3 + 1], preMA[doomed * 3 + 2]];
    e.presentBefore = [cast(ubyte)1, preP[doomed]];
    MeshEditDelta d;
    d.log = [e];

    assert(m.vertices.length == doomed,
        "stand: the tail must actually be gone before the reverse runs, or "
      ~ "this cell drives the gap-fill arm and says nothing about the append");
    assert(d.revert(m), "the hand-built reverse must succeed");
    assert(m.vertices.length == preV,
        format("the append arm must re-grow `vertices` to %d, got %d",
               preV, m.vertices.length));

    assert(pointMapValues(m, "W") == preW,
        "the tail-append arm did not restore the dim-1 map. "
      ~ mapResidual("map:W", preW, pointMapValues(m, "W")));
    assert(pointMapValues(m, "MA") == preMA,
        "the tail-append arm did not restore the dim-3 map. "
      ~ mapResidual("map:MA", preMA, pointMapValues(m, "MA"), 3));
    assert(pointMapPresent(m, "MA") == preP,
        format("the tail-append arm did not restore the presence byte: "
             ~ "pre-op %s, post-revert %s", preP, pointMapPresent(m, "MA")));
}

// ---------------------------------------------------------------------------
// Cell 8 — the shipped command path, through the REAL undo stack
//
// WHAT THIS CELL IS AND IS NOT. `mesh.cleanup` is one of the three commands
// that carry a `preMaps_` BELT (`commands/mesh/cleanup.d`, beside `delete.d`
// and `remove.d`), captured pre-op and written back on revert. So on today's
// tree the Point-map plane comes back through TWO mechanisms, and this cell's
// green is NOT evidence for Stage L7-P3 — the delta-level cells above are.
// What it is: proof the payload does not BREAK the shipped path, and the
// anchor for the belt's RETIREMENT. All three of those are measured, not
// argued (each run in isolation, since druntime stops a module at its first
// failed assert):
//
//   * defeat the payload's capture, belt intact  -> this cell stays GREEN
//     while the delta-level cells go red. That is the doubling, demonstrated.
//   * retire the belt's restore, payload intact  -> this cell stays GREEN.
//     The payload alone covers what the belt covered, on the shipped
//     `mesh.cleanup` path.
//   * retire the belt AND defeat the payload     -> RED, `map:W` v4 and v12
//     back as 0 against 4.5 and 12.5. Without this third run the second one's
//     green would prove nothing.
//
// The payload's own consumers — `vertex_bevel`, all thirteen of L10, three of
// L6 — are UNMIGRATED today, so it has no command caller that depends on it
// yet. That is why every discriminating cell here is at the delta level, where
// the mutation can be seen.
// ---------------------------------------------------------------------------

unittest // W-7-P3-g: mesh.cleanup, one undo step, depth delta exactly one
{
    import view : View;
    import editmode : EditMode;
    import command_history : CommandHistory;
    import commands.mesh.cleanup : MeshCleanup;

    auto m = new Mesh;
    *m = twoPointMapWeldStand();
    const preV = m.vertices.length;
    const float[] preW  = pointMapValues(*m, "W");
    const float[] preMA = pointMapValues(*m, "MA");
    const ubyte[] preP  = pointMapPresent(*m, "MA");

    auto v = new View(0, 0, 800, 600);
    auto hist = new CommandHistory();
    auto c = new MeshCleanup(m, v, EditMode.Polygons);

    const size_t depth0 = hist.undoEntries().length;
    assert(c.apply(),
        "mesh.cleanup REFUSED this stand — a refusal records no history entry, "
      ~ "and every assertion below would then be about an undo that never ran");
    assert(m.vertices.length == preV - 2,
        format("the cleanup must have welded and compacted both coincident "
             ~ "pairs: V %d -> %d, expected %d",
               preV, m.vertices.length, preV - 2));
    hist.record(c);
    assert(hist.undoEntries().length == depth0 + 1,
        format("recording the command must add exactly ONE undo entry: depth "
             ~ "%d -> %d", depth0, hist.undoEntries().length));

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.canUndo(), "the cleanup left no undo entry");
    assert(hist.undo(), "undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("%d undo step(s) actually took effect, expected exactly 1 — "
             ~ "`undoEpoch` moves once per SUCCESSFUL undo and by nothing "
             ~ "else, so this counts steps rather than calls",
               hist.undoEpoch() - epoch0));
    assert(hist.undoEntries().length == depth0,
        format("one undo must move the stack depth by exactly one: %d -> %d, "
             ~ "expected %d", depth0 + 1, hist.undoEntries().length, depth0));

    assert(m.vertices.length == preV,
        format("the undo must restore the two consumed vertices: V=%d, "
               ~ "expected %d", m.vertices.length, preV));
    assert(pointMapValues(*m, "W") == preW,
        "the dim-1 Point map did not come back through the shipped undo path. "
      ~ mapResidual("map:W", preW, pointMapValues(*m, "W")));
    assert(pointMapValues(*m, "MA") == preMA,
        "the dim-3 Point map did not come back through the shipped undo path. "
      ~ mapResidual("map:MA", preMA, pointMapValues(*m, "MA"), 3));
    assert(pointMapPresent(*m, "MA") == preP,
        format("the presence plane did not come back through the shipped undo "
             ~ "path: pre-op %s, post-undo %s", preP, pointMapPresent(*m, "MA")));
}

// ---------------------------------------------------------------------------
// Cell 9 — the L10 weld TWIN: what this payload closes there, and what it does not
//
// `Mesh.applyVertexRemapAndRebuild` is the twin `applyVertexRemap` was armed
// without (Stage L5-a armed one and deliberately left the other to L10;
// `face_reindex_arming_test.d`'s `kArmedSites` comment says so at its own
// site). This cell measures the twin's revert on a Point-carrying stand so the
// hand-off to L10 is a NUMBER rather than a prediction: the Point-map plane
// comes back (this stage), and the edge count does NOT (the unarmed rewrite).
//
// The EDGE expectation is pinned at the MEASURED deficit with an instruction:
// when L10 arms the twin this cell reddens BY DESIGN, and in that commit its
// expectation becomes `preE`. Card 2310's cell A carries the same pin for the
// `edgeSetMask` plane on the same funnel, and for the same reason.
// ---------------------------------------------------------------------------

unittest // W-7-P3-h: the unarmed weld TWIN — what this closes, what L10 still owes
{
    // `Mesh.applyVertexRemapAndRebuild` is the twin `applyVertexRemap` was
    // armed WITHOUT: Stage L5-a armed one and deliberately left the other to
    // Stage L10, and `face_reindex_arming_test.d`'s `kArmedSites` says so at
    // its own site. `weldVerticesByMask` is the funnel that reaches it.
    //
    // TWO MEASURED FACTS, and the second is the hand-off:
    //   1. the twin's own compaction DOES emit `[RemoveVerts Reindex]`, so
    //      this stage's payload closes the Point-map plane there as well —
    //      L10 inherits the map half already done rather than owing it;
    //   2. the EDGE the weld collapses does NOT come back, because the
    //      rewrite is unarmed. That is what L10 still owes on this funnel.
    //
    // A PLAN PREMISE DIED HERE AND THE CELL RECORDS THE CORRECTION: the twin
    // was expected to bypass `compactUnreferenced` (its sibling
    // `weldCoincidentVertices` calls it separately, and the first draft of
    // this cell asserted a separate compaction step that returns 0). It does
    // not — the twin compacts inside itself, and the log proves it.
    //
    // THE STAND MUST SHARE AN EDGE ACROSS THE WELD or fact 2 is invisible: on
    // four disjoint quads nothing collapses and E comes back whole (measured,
    // 16 of 16). `pointMapWeldStand` shares edge (0,5) post-weld, which is the
    // same shape card 2310's cell A pins the `edgeSetMask` half on.
    Mesh m = pointMapWeldStand();
    const preV = m.vertices.length;
    const preE = m.edges.length;
    const float[] preW = pointMapValues(m, "W");

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true; mask[4] = true;

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded = m.weldVerticesByMask(mask, 1e-12);
    auto delta = m.endEditBatch();
    assert(welded == 1 && m.vertices.length == preV - 1,
        format("stand: this funnel must weld v4 into v0 and drop it; got "
             ~ "welded=%d V=%d, expected 1 and %d",
               welded, m.vertices.length, preV - 1));
    assert(countKind(delta, MeshOpEntry.Kind.RemoveVerts) == 1,
        format("stand: the twin's own compaction must have logged a "
             ~ "RemoveVerts — without it this stage's payload is INERT on this "
             ~ "funnel and the fact below would be someone else's. Log %s",
               kindsOf(delta)));

    assert(delta.revert(m), "the reverse replay must succeed");
    assert(m.vertices.length == preV,
        format("V must come back: %d, expected %d", m.vertices.length, preV));

    // FACT 1 — closed by this stage.
    assert(pointMapValues(m, "W") == preW,
        "the twin funnel's undo lost the Point-map value of the consumed "
      ~ "vertex. " ~ mapResidual("map:W", preW, pointMapValues(m, "W")));

    // FACT 2 — CLOSED BY STAGE L10, and the arithmetic of the flip is written
    // here rather than in a commit message. This line read `preE - 1` until
    // 2026-08-28: the twin's `rewriteFaces` was UNARMED, so `FaceReindex`
    // never entered the log, the pre-weld windings were never reinstalled, and
    // `rebuildEdges` re-derived the edge array from the POST-weld faces —
    // **11 edges against a pre-op 12**, a deficit of exactly the one edge the
    // weld collapsed. Stage L10 wrapped that rewrite in `faceReindexScope()`
    // (`source/mesh.d:applyVertexRemapAndRebuild`), the log became
    // `[FaceReindex RemoveVerts Reindex]`, and E came back **12 of 12**.
    // The pin reddened BY DESIGN in that commit, exactly as the sentence it
    // replaced predicted, and this is its armed expectation.
    //
    // THE ORDER IS WHY THERE IS NO DOUBLE REVERT, and it was MEASURED rather
    // than reasoned (the identical prediction died once at `arrayFacesGrid`,
    // plan §5.3 MAJOR-4, where arming landed E=48 against a pre-op E=24):
    // the LIFO replay runs `Reindex⁻¹` then `RemoveVerts⁻¹` — re-opening the
    // pre-compaction vertex space — BEFORE `FaceReindex⁻¹` installs windings
    // that name pre-compaction indices.
    assert(m.edges.length == preE,
        format("the weld twin's armed revert must restore the edge the weld "
             ~ "collapsed: E came back %d against a pre-op %d. This is stage "
             ~ "L10's `faceReindexScope()` at "
             ~ "`Mesh.applyVertexRemapAndRebuild`; deleting that arm returns "
             ~ "this to the pre-L10 deficit of exactly one edge (11 of 12) "
             ~ "while `revert()` still answers TRUE and V and F still "
             ~ "round-trip — which is why this line, and not a count of "
             ~ "vertices or faces, is the one that can see it",
               m.edges.length, preE));
}
