// test_poly_bevel_seam_counters.d — task 1903 Stage F2.
//
// The POLYGON bevel family (`insetFacesByMask`, `bevelFacesByMask`,
// `spikeFacesByMask`) became free functions over `ref MeshEditBatch`, and
// every one of its SEVEN production call sites now opens that batch at its own
// boundary: three commands (`mesh.poly_inset`, `mesh.bevel`'s POLYGON arm,
// `mesh.spikey`), the two tools' commit paths (`applyHeadless`) and their two
// PER-FRAME previews. This file is the wire-level half of that: `/api/changes`
// DELTAS around each caller.
//
// WHY DELTAS AND NOT ABSOLUTES (E2 memo 7). Every counter here is
// process-cumulative and this binary runs many tests; a `== 0` on the absolute
// would be measuring whatever ran before us. Every assertion below reads
// /api/changes twice and subtracts.
//
// WHAT EACH COUNTER CAN AND CANNOT SEE — name the caller KIND before quoting
// one (E2 memo m6):
//
//   * `unbatchedGeometryCommits` ticks only OUTSIDE any batch, so it is the
//     one counter that says "the caller's batch is there at all". It cannot
//     tell one batch over a whole mask from a batch per face — measured at
//     Stage E3 on axis_slice, where moving the open inside the loop left every
//     wire counter byte-identical. That discrimination lives in the unit lane,
//     on `mutationVersion` (tests/unit/mesh_ops/poly_bevel_test.d), where the
//     unbatched ladder measures 10 / 34 / 66 for inset and bevel and
//     6 / 18 / 34 for spike over 1 / 4 / 8 processed faces.
//   * `nestedBatchOpens` says the caller's open is the OUTERMOST one. F2 has
//     no §4.4a transitional debt — nothing inside `Mesh` and no still-mixin
//     sibling calls this family (verified comment-stripped; `extrude.d`'s
//     `cornerNormalAt` is its OWN nested function with a different signature,
//     not a call into this file) — so the delta is the pin that KEEPS it that
//     way.
//   * `opLogEntriesRecorded` is the §9 pin. It is the only counter that
//     separates an `unrecorded` batch from a recording one, and on the two
//     drag paths it is the whole point.
//   * `deliveryCount` is NOT a batch counter and is deliberately only
//     RECORDED here, never asserted at zero. The edit batch defers the STAMP,
//     not the DELIVERY: `g_editBatchStack` and `g_deliveryDepth` are different
//     mechanisms, `Mesh.deliverPending()` consults only the second, and
//     `MeshSnapshot.restore` -> `commitRestored` consults neither. Commands sit
//     inside `Command.apply`'s `beginDeliveryBatchGlobal()`, so they measure 1
//     either way; a drag frame does not.
//
// Each block asserts the geometry first — a refusal makes every zero below it
// vacuous.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, buildDragLog, playAndWait;

void main() {}

alias BASE = testBaseUrl;

JSONValue postTo(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}


void resetCube() {
    auto r = postTo("/api/reset?type=cube", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}
void cmd(string s) {
    auto r = postTo("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}
JSONValue model()   { return getJson("/api/model"); }
JSONValue changes() { return getJson("/api/changes"); }
long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faceCount"].integer; }

void selectFaceZero() {
    auto r = postTo("/api/select", `{"mode":"polygons","indices":[0]}`);
    assert(r["status"].str == "ok", "face select failed: " ~ r.toString);
}
void selectEdgeZero() {
    auto r = postTo("/api/select", `{"mode":"edges","indices":[0]}`);
    assert(r["status"].str == "ok", "edge select failed: " ~ r.toString);
}

void settle() { Thread.sleep(140.msecs); }

/// The Poly Inset tool publishes no `/api/tool/state`, so its live value is
/// read the way `tests/test_poly_inset_drag.d` reads it.
double insetAttr() {
    auto r = postTo("/api/command", "tool.attr mesh.polyInsetTool inset ?");
    assert(r["status"].str == "ok", "inset query failed: " ~ r.toString);
    return r["value"].floating;
}

void play(string log) {
    auto r = postTo("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) break;
        Thread.sleep(50.msecs);
    }
    settle();   // EventPlayer reports POSTED, not processed — let the queue drain.
}
string motion(int x, int y, int state = 0) {
    return format(`{"t":0.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  x, y, state);
}
string button(string kind, int x, int y) {
    return format(`{"t":0.0,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, kind, x, y);
}

/// Every seam counter this stage cares about, asserted as a DELTA around one
/// caller. `what` names the caller in the message; `unbatchedNote` is the
/// measured figure the same caller produces with the deferral disabled, so the
/// reader knows the zero is a scale claim and not a constant.
void assertSeamClean(JSONValue before, JSONValue after, string what,
                     string unbatchedNote) {
    immutable long nested = after["nestedBatchOpens"].integer
                          - before["nestedBatchOpens"].integer;
    assert(nested == 0,
        what ~ " opened " ~ nested.to!string ~ " NESTED batch(es). Stage F2 "
      ~ "gives this family NO §4.4a transitional debt — every caller opens at "
      ~ "its own boundary and nothing inside `Mesh`, and no still-mixin "
      ~ "sibling, reaches these kernels. A non-zero delta means somebody above "
      ~ "this caller now holds a batch too; collapse the two rather than "
      ~ "nesting (task 1903 Stage F2, plan §2.3 rule 2).");

    immutable long unbatched = after["unbatchedGeometryCommits"].integer
                             - before["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        what ~ " made " ~ unbatched.to!string ~ " UNBATCHED geometry commit(s). "
      ~ "The kernels' receiver is `ref MeshEditBatch`, so their internal "
      ~ "commits must defer into the frame and stamp once at close(). "
      ~ unbatchedNote ~ " (task 1903 Stage F2, plan §3.2 L2).");

    immutable long leaks = after["batchLeaks"].integer - before["batchLeaks"].integer;
    assert(leaks == 0,
        what ~ " leaked " ~ leaks.to!string ~ " MeshEditBatch frame(s). The "
      ~ "frame stack is module-level: a leaked frame is not a one-off, it "
      ~ "makes every later commit in the process defer into a dead batch "
      ~ "(task 1903 §2.2c).");

    immutable long refusals = after["batchUpgradeRefusals"].integer
                            - before["batchUpgradeRefusals"].integer;
    assert(refusals == 0,
        what ~ " hit " ~ refusals.to!string ~ " batch upgrade refusal(s) — a "
      ~ "RECORDING batch was opened inside an unrecorded one, which §2.3 rule "
      ~ "3 refuses outright (task 1903 Stage F2).");
}

void assertUnrecorded(JSONValue before, JSONValue after, string what, string who) {
    immutable long opLog = after["opLogEntriesRecorded"].integer
                         - before["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        what ~ " recorded " ~ opLog.to!string ~ " op-log entr(ies). It still "
      ~ "undoes through a whole-mesh MeshSnapshot, so Stage F2 gave it the "
      ~ "UNRECORDED constructor: a recording batch would build an op-log "
      ~ "nothing reads and close() would drop it. " ~ who ~ " is what flips "
      ~ "this to a recording batch, and it flips this assertion with it "
      ~ "(task 1903 Stage F2).");
}

/// The other half of `assertUnrecorded`, for a command whose L stage has
/// LANDED: its batch is RECORDING and its `close()` hands back a delta the
/// command keeps.
///
/// WHY THE EXACT COUNT AND NOT `> 0`. A `> 0` is satisfied by any one of the
/// three entries a migrated spike records, and the entry this stage ADDED is
/// the third — `AddVerts` and `AddFaces` were already hooked before it and
/// would have made a `> 0` green on the broken code. The number is what makes
/// the row discriminate.
///
/// AND THIS ROW IS THE ONLY THING IN EITHER LANE THAT SEES THE COMMAND'S OWN
/// CONSTRUCTOR. `tests/unit/mesh_ops/poly_bevel_test.d`'s spike cell drives
/// the KERNEL under a recording batch it opens itself, so it is green with
/// `commands/mesh/spikey.d` still `unrecorded`; only a run of the real command
/// can tell those apart, and it is in the OTHER lane.
void assertRecorded(JSONValue before, JSONValue after, string what,
                    long want, string shape) {
    immutable long opLog = after["opLogEntriesRecorded"].integer
                         - before["opLogEntriesRecorded"].integer;
    assert(opLog == want,
        what ~ " recorded " ~ opLog.to!string ~ " op-log entr(ies), expected "
      ~ want.to!string ~ ". ZERO means the command still opens the UNRECORDED "
      ~ "constructor — its undo would be the whole-mesh MeshSnapshot the "
      ~ "migration deleted, i.e. no undo at all. " ~ shape);
}

// ---------------------------------------------------------------------------
// 1. `mesh.poly_inset` — the simplest caller.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectFaceZero();

    auto b = changes();
    cmd("mesh.poly_inset");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 12 && faceCount(m) == 10,
        format("mesh.poly_inset left V=%d F=%d, expected 12/10 (one inset ring "
             ~ "on a cube face: +4 verts, +4 ring quads) — on a refusal every "
             ~ "counter delta below is vacuous", vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.poly_inset",
        "Measured with the deferral disabled: +10 for ONE face and +34 for "
      ~ "four (tests/unit/mesh_ops/poly_bevel_test.d records the same ladder "
      ~ "as a mutationVersion delta), i.e. 8n+2 — the zero is a SCALE claim.");
    // TASK 1903 STAGE L7-a FLIPPED THIS ROW. `mesh.poly_inset` opens a
    // RECORDING batch and undoes from the op-log; the whole-mesh
    // `MeshSnapshot` is gone. THREE entries on this CUBE stand —
    // `[AddVerts, AddFaces, ReshapeFaces]`, the last of them the winding
    // publisher Stage L7-P2 added. There is no `MeshMapDelta`: a cube carries
    // no PolyVertex map, so the payload has nothing to record. The
    // four-entry form is on the UV-carrying stand in
    // `tests/unit/l7_bevel_inset_delta_test.d`, which is where the SEQUENCE
    // is asserted; this row is the only one in EITHER lane that sees the
    // COMMAND's own constructor.
    assertRecorded(b, a, "mesh.poly_inset", 3,
        "ONE `ReshapeFaces` closes the whole processed set, however many "
      ~ "faces were inset: the bulk `Mesh.setFaceWindings` call is what makes "
      ~ "it one, and a per-face loop — the O(N*F) shape card 2260 measured at "
      ~ "31x/66x — still round-trips, so nothing but a COUNT can see it.");
    // …and the undo has to actually work, through the real history stack.
    // Neither lane's other cells drive `/api/undo`: the unit cells call
    // `revert()` directly, which cannot see the funnel at all.
    assertUndoRestoresCube("mesh.poly_inset");
}

/// Drive ONE `/api/undo` and assert it took effect: the undo stack moves by
/// EXACTLY ONE and the mesh is back to the cube's 8 / 6.
///
/// MUTATION: stub `/api/undo` to a literal `{"status":"ok"}`. The depth does
/// not move and this reddens naming the count. A `status:ok` on its own proves
/// nothing — an endpoint returns it whatever it did.
void assertUndoRestoresCube(string what) {
    immutable long d1 = getJson("/api/history")["undo"].array.length;
    auto u = postTo("/api/undo", "");
    assert(u["status"].str == "ok", what ~ ": /api/undo failed: " ~ u.toString);
    immutable long d2 = getJson("/api/history")["undo"].array.length;
    assert(d1 - d2 == 1,
        format("%s: the undo moved the stack from %d to %d, expected exactly "
             ~ "one entry — a stack that does not move means the endpoint "
             ~ "answered ok without undoing anything", what, d1, d2));
    auto m = model();
    assert(vertCount(m) == 8 && faceCount(m) == 6,
        format("%s: undo left V=%d F=%d, expected the cube's 8/6. This command "
             ~ "undoes from its OP-LOG since stage L7; the whole-mesh "
             ~ "MeshSnapshot is gone, so a wrong count here is the delta "
             ~ "replay and not a snapshot restore", what,
               vertCount(m), faceCount(m)));
}

// ---------------------------------------------------------------------------
// 2. `mesh.bevel` — the POLYGON arm only. The command's EDGE arm calls
//    `bevelEdgesByMask`, a different family with its own batch since Stage G,
//    and Stage F2's batch is deliberately scoped to the polygon arm alone; the
//    edge cell below is what says the narrowing did not accidentally wrap it —
//    on `nestedBatchOpens` since Stage G gave that arm a batch of its own.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectFaceZero();

    auto b = changes();
    cmd("mesh.bevel");
    auto a = changes();

    auto m = model();
    assert(faceCount(m) > 6 && vertCount(m) > 8,
        format("mesh.bevel in POLYGON mode left V=%d F=%d — it did not bevel, "
             ~ "so every counter delta below is vacuous",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.bevel (polygon mode)",
        "Measured with the deferral disabled: +10 for ONE face and +66 for "
      ~ "eight, i.e. 8n+2.");
    // TASK 1903 STAGE L7-b FLIPPED THIS ROW — see `mesh.poly_inset` above.
    // Three entries on the cube: `[AddVerts, AddFaces, ReshapeFaces]`. The
    // command's `group` default is TRUE, and on a cube the grouped path's
    // shared-corner memo serves every face from one appended apex, so no
    // compaction fires here and there is no `[RemoveVerts, Reindex]` tail —
    // the grid stand in `tests/unit/mesh_ops/poly_bevel_test.d` is where that
    // shape is pinned.
    assertRecorded(b, a, "mesh.bevel (polygon mode)", 3,
        "The EDGE arm of this same command is DECLINED and still records "
      ~ "NOTHING (see the cell below and `commands/mesh/bevel.d`'s class doc) "
      ~ "— one class, two arms, two undo paths.");
    assertUndoRestoresCube("mesh.bevel (polygon mode)");
}

unittest {   // the EDGE arm — FLIPPED BY STAGE G
    // WHAT THIS CELL WAS, AND WHY IT CHANGED. Stage F2's batch wraps the
    // POLYGON arm ONLY, and this cell was the NEGATIVE CONTROL for that
    // narrowing: `bevelEdgesByMask` was still a mixin member with no
    // caller-held batch, so it measured `unbatched > 0` (+8), and a ZERO here
    // would have meant F2's batch had been widened to cover `evaluate` and had
    // silently changed the publish shape of a path F2 did not convert — the
    // regression Stage D3's review (MAJOR-3) had to undo after the fact. The
    // assertion said, in its own message, that Stage G would flip it.
    //
    // Stage G landed: the edge arm opens its OWN narrow batch, and the same
    // measurement reads +0. The flip is not a loss of the control, because the
    // control moved rather than vanished — a batch spanning `evaluate` would
    // now NEST around each arm's own open, so `nestedBatchOpens` is what
    // refuses it, and that is asserted below on the same call.
    resetCube();
    selectEdgeZero();

    auto b = changes();
    cmd("mesh.bevel");
    auto a = changes();

    auto m = model();
    assert(faceCount(m) > 6,
        format("mesh.bevel in EDGE mode left F=%d — it did not bevel, so the "
             ~ "delta below is vacuous", faceCount(m)));

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        format("mesh.bevel in EDGE mode made %d unbatched geometry commit(s); "
             ~ "since Stage G this must be ZERO — `bevelEdgesByMask` is a free "
             ~ "function over `ref MeshEditBatch` and `commands/mesh/bevel.d`'s "
             ~ "edge arm opens that batch at its own boundary, scoped to the "
             ~ "kernel call alone exactly as the polygon arm is. Measured "
             ~ "BEFORE Stage G on this same cell: +8. A positive number here "
             ~ "means the edge arm lost its batch "
             ~ "(task 1903 Stage F2 -> Stage G, §4.4a).",
               unbatched));
    immutable long nested = a["nestedBatchOpens"].integer
                          - b["nestedBatchOpens"].integer;
    assert(nested == 0,
        format("mesh.bevel in EDGE mode opened %d NESTED batch(es). This is "
             ~ "what INHERITED the narrowing control from the `unbatched > 0` "
             ~ "assertion Stage G flipped: with both arms holding their own "
             ~ "narrow batch, a batch spanning `evaluate` no longer shows up as "
             ~ "unbatched commits — it shows up as a nested open "
             ~ "(task 1903 Stage G, plan §2.3 rule 2).", nested));
}

// ---------------------------------------------------------------------------
// 3. `mesh.spikey` — a DIFFERENT L stage (L2, not L7) with the same seam.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectFaceZero();

    auto b = changes();
    cmd("mesh.spikey");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 9 && faceCount(m) == 9,
        format("mesh.spikey left V=%d F=%d, expected 9/9 (one apex, one quad "
             ~ "becomes four fan triangles) — on a refusal every counter delta "
             ~ "below is vacuous", vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.spikey",
        "Measured with the deferral disabled: +6 for ONE face and +34 for "
      ~ "eight, i.e. 4n+2 — a DIFFERENT slope from inset and bevel, which is "
      ~ "why the unit lane runs all three entries as separate cells.");
    // STAGE L2-f FLIPPED THIS (2026-08-28). It read `assertUnrecorded` until
    // then, with Stage L2 named in its own message as what would flip it —
    // `mesh.spikey` is an L2 command (the L table is keyed by COMMAND, and
    // this kernel merely ships in the bevel family's FILE), while
    // `mesh.poly_inset` and `mesh.bevel` above are L7's and still read
    // `assertUnrecorded`.
    assertRecorded(b, a, "mesh.spikey", 3,
        "The three are [AddVerts] for the apex, [AddFaces] for the three "
      ~ "appended fan triangles (the tracker coalesces a contiguous run into "
      ~ "ONE entry) and [ReshapeFaces] for the parent slot the fan replaced — "
      ~ "the third being the one publisher P7 added at Stage L2-f. There is no "
      ~ "[MeshMapDelta] beside it here because this stand is a bare cube with "
      ~ "no per-corner map, so the payload declines; the unit lane's stand "
      ~ "carries one and sees four.");
}

// ---------------------------------------------------------------------------
// 4. The two TOOLS' commit paths (`applyHeadless`), which are different call
//    sites from the commands and pass options the commands do not.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectFaceZero();
    cmd("tool.set mesh.polyInsetTool on");
    cmd("tool.attr mesh.polyInsetTool inset 0.2");

    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 12 && faceCount(m) == 10,
        format("the Poly Inset tool's doApply left V=%d F=%d, expected 12/10 — "
             ~ "on a refusal every counter delta below is vacuous",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "the Poly Inset tool's doApply",
        "Measured with the deferral disabled: +10 for one face.");
    assertUnrecorded(b, a, "the Poly Inset tool's doApply",
        "Stage M (the tool pair-holders), with Stage L7 for the family's delta");
    cmd("tool.set mesh.polyInsetTool off");
}

unittest {
    resetCube();
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    cmd("tool.attr poly.bevel inset 0.2");
    cmd("tool.attr poly.bevel shift 0.1");

    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();

    auto m = model();
    assert(faceCount(m) > 6 && vertCount(m) > 8,
        format("the Poly Bevel tool's doApply left V=%d F=%d — it did not "
             ~ "bevel, so every counter delta below is vacuous",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "the Poly Bevel tool's doApply",
        "Measured with the deferral disabled: +10 for one face.");
    assertUnrecorded(b, a, "the Poly Bevel tool's doApply",
        "Stage M (the tool pair-holders), with Stage L7 for the family's delta");
    cmd("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// 5. THE TWO PER-FRAME PREVIEWS (plan §9) — the callers a command cannot
//    reach, and this family has TWO OF DIFFERENT SHAPE:
//
//      * the Poly INSET tool keeps the plain `before.restore(*mesh); kernel();`
//        drag-frame shape, so its batch is opened on the LIVE mesh;
//      * the Poly BEVEL tool goes through `tools/edit/preview_rebuild.d`
//        (task 1620), so the kernel runs on a PRIVATE CLEAN CAGE on the
//        placement path and on the live mesh only when the topology key
//        changes. Stage F2 opens the batch INSIDE the tool's own kernel
//        lambda, which lands it on whichever mesh the kernel actually got —
//        both of plan §9.1's stated consequences, with no edit to the shared
//        seam (`preview_rebuild.d` still serves two unconverted families).
//
//    A drag test that exercised only one of the two would say nothing about
//    the other, which is why there are two blocks.
// ---------------------------------------------------------------------------
// POLLS. The handle bank is published by `draw()`, not by `tool.set`, so a
// fixed `settle()` is a race: a slow frame leaves `/api/tool/handles` as `{}`
// and the JSON index throws instead of asserting. Waiting for the bank is also
// the anti-vacuity guard for the two drag blocks — a drag aimed at a handle
// that was never published cannot capture, and an uncaptured drag moves no
// counter at all.
void handleScreen(int part, out int x, out int y) {
    foreach (_; 0 .. 60) {
        try {
            auto h = getJson("/api/tool/handles");
            foreach (p; h["handles"]["parts"].array)
                if (p["part"].integer == part) {
                    x = cast(int)(p["screen"].array[0].floating + 0.5);
                    y = cast(int)(p["screen"].array[1].floating + 0.5);
                    return;
                }
        } catch (Exception) { /* `{}` until draw() publishes the bank */ }
        Thread.sleep(50.msecs);
    }
    assert(false, "handle part " ~ part.to!string ~ " was never published to "
                ~ "/api/tool/handles within 3s — the tool did not arm, and a "
                ~ "drag aimed at an unpublished handle would move no counter "
                ~ "and read as three free zeroes (task 1903 Stage F2).");
}

unittest {   // the Poly BEVEL tool's drag — the PreviewRebuild shape
    enum int kFrames = 12;
    resetCube();
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();   // draw() must publish the handle bank + the gizmo frame.

    int sx, sy;
    handleScreen(0, sx, sy);          // part 0 = Shift
    play(button("SDL_MOUSEBUTTONDOWN", sx, sy));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "the Shift handle did not capture on mouse-down — every counter delta "
      ~ "below would be measuring a drag that never began");

    enum int DX = -60, DY = -105;     // up-left along the shift screen axis
    auto b = changes();
    foreach (i; 1 .. kFrames + 1)
        play(motion(sx + DX * i / kFrames, sy + DY * i / kFrames, 1));
    auto a = changes();

    // ANTI-VACUITY, and it is the load-bearing half: a drag that never entered
    // `onMouseMotion` moves no counter, so three zeroes would be free.
    immutable double shiftNow = getJson("/api/tool/state")["shift"].floating;
    assert(shiftNow > 1e-4,
        format("the drag left `shift` at %.6f; the press leaves it at 0 and "
             ~ "this drag runs %d motions up-left along the shift axis, so it "
             ~ "must be clearly positive. A shift still at 0 means "
             ~ "`onMouseMotion` never ran — no preview frame was rebuilt and "
             ~ "every counter delta below would be free zeroes "
             ~ "(task 1903 Stage F2, plan §9).", shiftNow, kFrames));
    assert(getJson("/api/tool/state")["built"].type == JSONType.true_,
        "the drag did not build a live preview");

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "the Poly Bevel drag made " ~ unbatched.to!string ~ " UNBATCHED "
      ~ "geometry commit(s) across " ~ kFrames.to!string ~ " preview frames. "
      ~ "Stage F2 gave the tool's `preview_.run` kernel lambda an UNRECORDED "
      ~ "MeshEditBatch per frame, opened INSIDE the lambda so it lands on the "
      ~ "clean cage on the placement path and on the live mesh on a full "
      ~ "rebuild. AND READ THIS ZERO NARROWLY (E2 memo m6 — name the caller "
      ~ "KIND before quoting a counter): `unbatchedGeometryCommits` is "
      ~ "DOCUMENT-MESH FILTERED by `g_isDocumentMesh` (plan §3.2 L2), and on "
      ~ "this tool most frames run the kernel on `PreviewRebuild`'s PRIVATE "
      ~ "CAGE, which the counter cannot see. Measured with the deferral "
      ~ "disabled, this exact drag reads +10 TOTAL — one full rebuild on the "
      ~ "live mesh at 10 commits, and eleven placement frames invisible to "
      ~ "this counter. So this cell witnesses the full-rebuild frames only; "
      ~ "the cell that witnesses EVERY frame is the Poly Inset drag below, "
      ~ "whose tool writes the live mesh every frame and reads +120 unbatched "
      ~ "(10 per frame) under the same mutation (plan §3.2 L2, §9, §9.1).");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the Poly Bevel drag recorded " ~ opLog.to!string ~ " op-log entr(ies) "
      ~ "across its preview frames. Plan §9 is explicit that the interactive "
      ~ "preview path must stay UNRECORDED: a recording batch opened per drag "
      ~ "frame builds and throws away a full op-log at 60 Hz. Switching the "
      ~ "lambda's constructor from `MeshEditBatch.unrecorded` to "
      ~ "`MeshEditBatch` is the mutation this reddens under "
      ~ "(task 1903 Stage F2, M-P/F2).");

    immutable long leaks = a["batchLeaks"].integer - b["batchLeaks"].integer;
    assert(leaks == 0,
        "a MeshEditBatch leaked its frame during the Poly Bevel drag. On a "
      ~ "per-frame batch a leak is not a one-off: the module-level frame stack "
      ~ "would make every later commit in the process defer into a dead batch "
      ~ "(task 1903 §2.2c).");
    assert(a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer == 0,
        "the Poly Bevel drag opened a NESTED batch — the per-frame preview "
      ~ "batch must be the outermost open on its frame. NOTE THE SHAPE THIS "
      ~ "CELL GUARDS: the batch is opened inside the kernel lambda, so a "
      ~ "second one opened around `preview_.run` would nest rather than "
      ~ "replace it (task 1903 §2.3 rule 2, Stage F2).");

    play(button("SDL_MOUSEBUTTONUP", sx + DX, sy + DY));
    cmd("tool.set poly.bevel off");
}

unittest {   // the Poly INSET tool's drag — the plain restore-and-rerun shape
    // NO HANDLE HERE, and that is why this block does not reuse
    // `handleScreen`: the inset tool draws none — any qualifying click in
    // polygon mode begins the haul, anchored at the selected faces' centroid
    // (the shape `tests/test_poly_inset_drag.d` already drives). So the press
    // point is arbitrary and only the VERTICAL travel carries meaning.
    enum int kFrames = 12;
    auto rr = postTo("/api/reset", "");
    assert(rr["status"].str == "ok", "reset failed: " ~ rr.toString);
    auto sel = postTo("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(sel["status"].str == "ok", "face select failed: " ~ sel.toString);
    cmd("tool.set mesh.polyInsetTool on");
    settle();
    assert(insetAttr() < 1e-6 && insetAttr() > -1e-6,
        "a freshly armed inset tool should start at 0 — otherwise the "
      ~ "anti-vacuity check below cannot tell a drag from a leftover value");

    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width  / 2;
    immutable int cy = cam.vpY + cam.height / 2;

    auto b = changes();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy - 60, kFrames), BASE);
    settle();
    auto a = changes();

    // ANTI-VACUITY: a drag that never entered `onMouseMotion` moves no counter,
    // so three zeroes would be free.
    immutable double insetNow = insetAttr();
    assert(insetNow > 1e-4,
        format("the drag left `inset` at %.6f; the arm leaves it at 0 and a "
             ~ "60 px UPWARD haul over %d motions drives it positive. An "
             ~ "inset still at 0 means `onMouseMotion` never ran — no preview "
             ~ "frame was rebuilt and every counter delta below would be free "
             ~ "zeroes (task 1903 Stage F2, plan §9).", insetNow, kFrames));

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "the Poly Inset drag made " ~ unbatched.to!string ~ " UNBATCHED "
      ~ "geometry commit(s) across " ~ kFrames.to!string ~ " preview frames. "
      ~ "This tool keeps the PLAIN `before.restore(*mesh); kernel();` "
      ~ "drag-frame shape — it is NOT one of preview_rebuild.d's three — so "
      ~ "Stage F2's batch is on the LIVE mesh here, unlike the Poly Bevel cell "
      ~ "above. Two preview shapes in one family, and a cell that drove only "
      ~ "one of them would say nothing about the other. Measured with the "
      ~ "deferral disabled: +120 across these 12 frames, i.e. +10 PER FRAME — "
      ~ "twelve times the amplitude the Poly Bevel cell can show, because "
      ~ "every frame here is a document-mesh frame (plan §3.2 L2, §9, §9.1).");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the Poly Inset drag recorded " ~ opLog.to!string ~ " op-log entr(ies) "
      ~ "across its preview frames — plan §9 requires the interactive preview "
      ~ "path to stay UNRECORDED: a recording batch opened per drag frame "
      ~ "builds and throws away a full op-log at 60 Hz "
      ~ "(task 1903 Stage F2, M-P/F2).");
    assert(a["batchLeaks"].integer - b["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked its frame during the Poly Inset drag "
      ~ "(task 1903 §2.2c).");
    assert(a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer == 0,
        "the Poly Inset drag opened a NESTED batch (task 1903 §2.3 rule 2).");

    cmd("tool.set mesh.polyInsetTool off");
}
