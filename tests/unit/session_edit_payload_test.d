// THE PAYLOAD PREDICATE — what a session-record command does when it carries
// no session (task 1552).
//
// `MeshSessionEdit` is the RECORD of an interactive tool gesture: the tool
// installs (before, after) snapshots — or an operation-log delta — when it
// commits, and only REDO re-enters `evaluate()` with that payload present.
// Built fresh from the command registry it is BLANK, and `after.restore()`
// on a blank `MeshSnapshot` assigns empty arrays over the live mesh. That is
// the measured defect: `POST /api/command mesh.bevel_edit` wiped an 8-vertex
// cube to 0v/0f.
//
// THE PREDICATE IS `filled`, NOT "the snapshot is empty", and the difference
// is the whole reason this file exists. `filled` is written by exactly one
// place, `MeshSnapshot.capture()`, and its default is false — so it means
// "a snapshot was taken", never "the snapshot's mesh had geometry". A
// session may LEGITIMATELY end on an empty mesh (delete the last face with
// the pen, reduce to nothing); `capture(emptyMesh)` is `filled` and its redo
// must still run. `emptyRedoIsStillHonoured` below is the ONLY case here that
// separates the two predicates — `payloadlessCarrierRefuses` answers the same
// under both.
//
// CPU-only, and that is checked rather than assumed: `MeshSnapshot.restore`
// touches no GL (array assignment plus `buildLoops` / `resizeAllMeshMaps` /
// `commitChange`), and `MeshEditDelta.apply` iterates its log. The banner on
// `session_edit.d`'s own unittest used to claim the opposite and steered the
// next reader away from writing this file; it has been corrected.
module tests.unit.session_edit_payload_test;

import mesh      : Mesh, makeCube;
import view      : View;
import editmode  : EditMode;
import snapshot  : MeshSnapshot;
import operator  : VectorStack;
import toolpipe.packets : SubjectPacket;
import mesh_edit_delta  : MeshEditDelta, MeshEditScope, MeshEditTracker;
import commands.mesh.session_edit : MeshSessionEdit, kNoSessionReason;

import std.algorithm : canFind;
import std.conv      : to;

// The packet a `Command.apply()` would have built (source/command.d) — this
// file drives `evaluate()` directly, so it builds the same one by hand.
private void withSubject(ref Mesh m, ref VectorStack vts, ref SubjectPacket subj) {
    subj.mesh     = &m;
    subj.editMode = EditMode.Vertices;
    vts.put(&subj);
}

private MeshSessionEdit freshCarrier(ref Mesh m, View v) {
    return new MeshSessionEdit(&m, v, EditMode.Vertices,
                               "mesh.bevel_edit", "Bevel");
}

unittest { // U-1 — a payload-less carrier REFUSES, and leaves the mesh alone
    Mesh m = makeCube();
    View v = new View(0, 0, 1, 1);
    auto cmd = freshCarrier(m, v);

    VectorStack vts;
    SubjectPacket subj;
    withSubject(m, vts, subj);

    assert(!cmd.evaluate(vts),
        "a carrier with no recorded session must refuse, not restore a blank "
        ~ "snapshot");
    // The load-bearing half: the refusal happened BEFORE any mutation.
    assert(m.vertices.length == 8,
        "the cube lost vertices to a payload-less carrier: "
        ~ m.vertices.length.to!string);
    assert(m.faces.length == 6,
        "the cube lost faces to a payload-less carrier: "
        ~ m.faces.length.to!string);
    assert(cmd.refusalReason().canFind("no recorded edit session"),
        "the refusal must name its reason so the dispatch funnel and the UI "
        ~ "notice can read it: '" ~ cmd.refusalReason() ~ "'");
    assert(cmd.refusalReason() == kNoSessionReason);
}

unittest { // U-2 — a carrier WITH a payload still runs (anti-"always refuses")
    Mesh m = makeCube();
    View v = new View(0, 0, 1, 1);
    auto cmd = freshCarrier(m, v);

    auto before = MeshSnapshot.capture(m);
    // A real session's worth of change: move one vertex.
    m.vertices[0].x += 2.5f;
    auto after = MeshSnapshot.capture(m);
    const float movedX = m.vertices[0].x;

    // Rewind the live mesh to `before`, the way an undo would have, so the
    // redo below has something to do.
    before.restore(m);
    assert(m.vertices[0].x != movedX);

    cmd.setSnapshots(before, after, "Bevel");

    VectorStack vts;
    SubjectPacket subj;
    withSubject(m, vts, subj);

    assert(cmd.evaluate(vts),
        "a carrier holding a captured session must execute — the gate is on "
        ~ "the ABSENCE of a session, not on the command");
    assert(m.vertices[0].x == movedX,
        "redo did not restore the session's `after` state");
    assert(m.vertices.length == 8 && m.faces.length == 6);
}

unittest { // U-3 — THE DISCRIMINATOR: a session that legitimately ended EMPTY
    // `filled` says "a snapshot was taken". A session is allowed to end on an
    // empty mesh, and its redo must still reproduce that. A predicate written
    // as "the snapshot has no vertices" would answer identically on U-1 and
    // wrongly HERE — which is why U-1 alone cannot pin the rule.
    Mesh m = makeCube();
    View v = new View(0, 0, 1, 1);
    auto cmd = freshCarrier(m, v);

    auto before = MeshSnapshot.capture(m);

    Mesh emptied;                       // the state the session ended in
    auto after = MeshSnapshot.capture(emptied);
    assert(after.filled,
        "capture() of an empty mesh is still a CAPTURE — `filled` must be "
        ~ "true, or the predicate under test is testing nothing");
    assert(after.vertices.length == 0);

    cmd.setSnapshots(before, after, "Reduce to nothing");

    VectorStack vts;
    SubjectPacket subj;
    withSubject(m, vts, subj);

    assert(cmd.evaluate(vts),
        "a session that legitimately ended with an empty mesh must still "
        ~ "redo — the predicate is `filled`, not `the snapshot is empty`");
    assert(m.vertices.length == 0 && m.faces.length == 0,
        "…and the redo must actually reproduce that empty state");
}

unittest { // U-5 — the DELTA path is not touched by the snapshot gate
    // `setDelta` never writes `after`, so a gate without the `useDelta_` term
    // would refuse every delta-backed redo (edge_extrude / edge_extend).
    Mesh m = makeCube();
    View v = new View(0, 0, 1, 1);
    auto cmd = freshCarrier(m, v);

    MeshEditDelta delta;
    delta.scope_ = MeshEditScope.Position;
    cmd.setDelta(delta, "Extrude");

    VectorStack vts;
    SubjectPacket subj;
    withSubject(m, vts, subj);

    assert(cmd.evaluate(vts),
        "the delta path must not be gated on `after.filled` — setDelta never "
        ~ "sets `after`");
    assert(m.vertices.length == 8 && m.faces.length == 6,
        "an empty delta replay must leave the mesh as it found it");
}

private void checkpointMap(ref MeshEditTracker t) {
    import mesh : MapDomain, MapKind;
    import mesh_edit_delta : MeshOpEntry;
    t.recordMapValuesOwned("checkpoint-map", 1, MapDomain.Point,
        MapKind.unclassified, MeshOpEntry.MapAddressing.Listed,
        [0u], [1.0f], [2.0f], null, null);
}

unittest { // Declaration, preference and owned noncoalescing prefix survive.
    import mesh_edit_delta : MeshEditTracker;
    import math : Vec3;
    import std.math : isIdentical;
    MeshEditTracker t;
    t.declare(MeshEditScope.Position);
    t.wantsFaceReindex = true;
    t.recordSetPosOwned([0u], [Vec3(-0.0f, 1, 2)], [Vec3(0.0f, 3, 4)]);
    checkpointMap(t);
    auto c = t.checkpoint();
    t.declare(MeshEditScope.Geometry);
    t.wantsFaceReindex = false;
    t.recordAddVert(8, Vec3(7, 8, 9));
    t.restore(c);
    assert(t.wantsFaceReindex, "checkpoint must restore face-reindex preference");
    auto d = t.finish();
    assert(d.scope_ == MeshEditScope.Position, "checkpoint must restore declaration");
    assert(d.log.length == 2 && isIdentical(d.log[0].posBefore[0].x, -0.0f)
        && isIdentical(d.log[0].posAfter[0].x, 0.0f)
        && d.log[1].mapValsBefore == [1.0f] && d.log[1].mapValsAfter == [2.0f],
        "checkpoint must preserve signed-zero and owned map prefix");
}

unittest { // Rolled-back MAP latch must not poison a subsequent index write.
    import mesh_edit_delta : MeshEditTracker;
    import math : Vec3;
    import change_bus : changeBus;
    MeshEditTracker t;
    auto c = t.checkpoint();
    checkpointMap(t);
    t.restore(c);
    const before = changeBus.mapDeltaMixRecorded;
    t.recordAddVert(8, Vec3(1, 2, 3));
    assert(changeBus.mapDeltaMixRecorded == before,
        "checkpoint must restore absent map adjacency latch");
    auto d = t.finish();
    assert(d.log.length == 1, "empty-before failure must remain empty");
}

unittest { // Rolled-back INDEX latch must not poison a subsequent map write.
    import mesh_edit_delta : MeshEditTracker;
    import math : Vec3;
    import change_bus : changeBus;
    MeshEditTracker t;
    auto c = t.checkpoint();
    t.recordAddVert(8, Vec3(1, 2, 3));
    t.restore(c);
    const before = changeBus.mapDeltaMixRecorded;
    checkpointMap(t);
    assert(changeBus.mapDeltaMixRecorded == before,
        "checkpoint must restore absent index adjacency latch");
    auto d = t.finish();
    assert(d.log.length == 1);
}

unittest { // Both preexisting latches remain effective after rollback.
    import mesh_edit_delta : MeshEditTracker;
    import math : Vec3;
    import change_bus : changeBus;
    foreach (mapFirst; [true, false]) {
        MeshEditTracker t;
        if (mapFirst) checkpointMap(t); else t.recordAddVert(8, Vec3(1, 2, 3));
        auto c = t.checkpoint();
        t.recordSetPosOwned([0u], [Vec3(1, 2, 3)], [Vec3(4, 5, 6)]);
        t.restore(c);
        const before = changeBus.mapDeltaMixRecorded;
        if (mapFirst) t.recordAddVert(8, Vec3(1, 2, 3)); else checkpointMap(t);
        assert(changeBus.mapDeltaMixRecorded == before + 1,
            "checkpoint must preserve preexisting adjacency latch");
        t.finish();
    }
}
