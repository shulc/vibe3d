// test_edge_bevel_seam_counters.d — task 1903 Stage G.
//
// The MANIFOLD EDGE BEVEL (`bevelEdgesByMask`) became a free function over
// `ref MeshEditBatch`, and its THREE production call sites now open that batch
// at their own boundary: `mesh.bevel`'s EDGE arm, the Edge Bevel tool's commit
// (`applyHeadless`) and the tool's PER-FRAME preview. This file is the
// wire-level half of that: `/api/changes` DELTAS around each caller.
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
//     tell one batch over a whole mask from a batch per edge — measured at
//     Stage E3 on axis_slice, where moving the open inside the loop left every
//     wire counter byte-identical. That discrimination lives in the unit lane,
//     on `mutationVersion` (tests/unit/mesh_ops/edge_bevel_test.d), where the
//     unbatched ladder measures 8 / 10 / 13 / 28 for one edge at L0, one edge
//     at L1, three edges and all twelve cube edges.
//   * `nestedBatchOpens` says the caller's open is the OUTERMOST one. Stage G
//     is the stage that REMOVED this family's §4.4a transitional debt — the
//     two `unrecorded` batches `bevelEdgesByMask` opened at its fin-bundle
//     early returns while it was still a mixin — so from here the family has
//     no debt at all and the delta is the pin that keeps it that way.
//   * `opLogEntriesRecorded` is the §9 pin. It is the only counter that
//     separates an `unrecorded` batch from a recording one, and on the drag
//     path it is the whole point.
//   * `deliveryCount` is NOT a batch counter and is deliberately only
//     RECORDED here, never asserted at zero. The edit batch defers the STAMP,
//     not the DELIVERY: `g_editBatchStack` and `g_deliveryDepth` are different
//     mechanisms, `Mesh.deliverPending()` consults only the second, and
//     `MeshSnapshot.restore` -> `commitRestored` consults neither. Commands sit
//     inside `Command.apply`'s `beginDeliveryBatchGlobal()`, so they measure 1
//     either way; a drag frame does not (measured: 14 deliveries over 12 drag
//     frames with the batch, 21 without — the residual §9.2 says an edit batch
//     cannot move).
//
// Each block asserts the geometry first — a refusal makes every zero below it
// vacuous, and `bevelEdgesByMask` refuses on a great many preconditions.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import batchless_control_helpers;
import std.format  : format;
import std.math    : cos, sin, PI, sqrt, fabs;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue postTo(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}


void resetCube() {
    auto r = postTo("/api/command", commandBody("scene.reset", `{"type":"cube"}`));
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
void settle() { Thread.sleep(140.msecs); }

int edgeIndexOf(int a, int b) {
    auto m = model();
    foreach (i, e; m["edges"].array) {
        immutable int u = cast(int)e.array[0].integer, v = cast(int)e.array[1].integer;
        if ((u == a && v == b) || (u == b && v == a)) return cast(int)i;
    }
    return -1;
}
void selectEdges(int[] idx) {
    string j = "[";
    foreach (i, v; idx) { if (i) j ~= ","; j ~= v.to!string; }
    j ~= "]";
    auto r = postTo("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":` ~ j ~ `}`));
    assert(r["status"].str == "ok", "edge select failed: " ~ r.toString);
}
void selectTopFrontEdge() {
    immutable int ei = edgeIndexOf(6, 7);
    assert(ei >= 0, "cube top-front edge (6,7) missing");
    selectEdges([ei]);
}

/// A fin bundle: one spine edge shared by N fins, loaded through
/// `/api/load-mesh` because a cube CANNOT exhibit this topology (памятка 22).
void loadFinBundle(int n) {
    string verts = `[[0,0,1],[0,0,-1]`;
    foreach (k; 0 .. n) {
        immutable double a = 2.0 * PI * k / n;
        verts ~= `,[` ~ cos(a).to!string ~ `,` ~ sin(a).to!string ~ `,1]`;
        verts ~= `,[` ~ cos(a).to!string ~ `,` ~ sin(a).to!string ~ `,-1]`;
    }
    verts ~= `]`;
    string faces = `[`;
    foreach (k; 0 .. n) {
        if (k) faces ~= `,`;
        faces ~= `[0,` ~ (2 + 2 * k).to!string ~ `,` ~ (3 + 2 * k).to!string ~ `,1]`;
    }
    faces ~= `]`;
    auto r = postTo("/api/command", commandBody("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`));
    assert(r["status"].str == "ok", "/api/load-mesh (fin bundle) failed: " ~ r.toString);
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
/// caller. `what` names the caller; `unbatchedNote` is the measured figure the
/// same caller produces with the deferral disabled (M-G-BATCH), so a reader can
/// see that the zero is a SCALE claim and not a constant.
void assertSeamClean(JSONValue before, JSONValue after, string what,
                     string unbatchedNote) {
    immutable long nested = after["nestedBatchOpens"].integer
                          - before["nestedBatchOpens"].integer;
    assert(nested == 0,
        what ~ " opened " ~ nested.to!string ~ " NESTED batch(es). Since Stage "
      ~ "G this family has NO §4.4a transitional debt at all — the two "
      ~ "`unrecorded` opens `bevelEdgesByMask` used to hold at its fin-bundle "
      ~ "early returns are gone, because the kernel now takes the CALLER's "
      ~ "batch and hands it straight on to `mesh_ops/bevel_fin.d`. A non-zero "
      ~ "delta means somebody above this caller now holds a batch too; "
      ~ "collapse the two rather than nesting "
      ~ "(task 1903 Stage G, plan §2.3 rule 2, §4.4a).");

    immutable long unbatched = after["unbatchedGeometryCommits"].integer
                             - before["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        what ~ " made " ~ unbatched.to!string ~ " UNBATCHED geometry commit(s). "
      ~ "The kernel's receiver is `ref MeshEditBatch`, so its internal commits "
      ~ "must defer into the frame and stamp once at close(). " ~ unbatchedNote
      ~ " (task 1903 Stage G, plan §3.2 L2).");

    immutable long leaks = after["batchLeaks"].integer - before["batchLeaks"].integer;
    assert(leaks == 0,
        what ~ " leaked " ~ leaks.to!string ~ " MeshEditBatch frame(s). The "
      ~ "frame stack is module-level: a leaked frame is not a one-off, it "
      ~ "makes every later commit in the process defer into a dead batch "
      ~ "(task 1903 §2.2c).");

    immutable long refusals = after["batchUpgradeRefusals"].integer
                            - before["batchUpgradeRefusals"].integer;
    assert(refusals == 0,
        what ~ " refused " ~ refusals.to!string ~ " batch upgrade(s) — a "
      ~ "RECORDING batch was opened inside an unrecorded one, which §2.3 rule "
      ~ "3 refuses outright (task 1903 Stage G).");
}

void assertUnrecorded(JSONValue before, JSONValue after, string what, string who) {
    immutable long opLog = after["opLogEntriesRecorded"].integer
                         - before["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        what ~ " recorded " ~ opLog.to!string ~ " op-log entr(ies). It still "
      ~ "undoes through a whole-mesh MeshSnapshot, so Stage G gave it the "
      ~ "UNRECORDED constructor: a recording batch would build an op-log "
      ~ "nothing reads and close() would drop it — and this family's op-log is "
      ~ "measured to be one nobody could use yet anyway (its `revert()` throws; "
      ~ "tests/unit/mesh_ops/edge_bevel_test.d has the rows). " ~ who ~ " is "
      ~ "what flips this to a recording batch, and it flips this assertion with "
      ~ "it (task 1903 Stage G).");
}

/// The other half of `assertUnrecorded`, for a command whose L stage has
/// LANDED: its batch is RECORDING and its `close()` hands back a delta the
/// command keeps. Same shape as `tests/test_poly_bevel_seam_counters.d`'s,
/// duplicated rather than shared because these two files are independent
/// suite binaries.
///
/// WHY THE EXACT COUNT AND NOT `> 0`. `AddVerts`, `RemoveVerts` and `Reindex`
/// were already hooked before this stage and were in the op-log while the
/// command was still unrecorded — a `> 0` would have been green on the broken
/// code. The entries stage L7 ADDED are the `[MeshMapDelta, FaceReindex]`
/// pairs, one per rewrite, and only the exact number sees them.
///
/// AND THIS ROW IS THE ONLY THING IN EITHER LANE THAT SEES THE COMMAND'S OWN
/// CONSTRUCTOR. `tests/unit/mesh_ops/edge_bevel_test.d` drives the KERNEL
/// under a recording batch it opens itself, so it is green with
/// `commands/mesh/bevel.d` still `unrecorded`; only a run of the real command
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
// 0. POSITIVE CONTROL FIRST, and it is not decoration. Every assertion in this
//    file is "this counter did not move", and a DEAD counter — the endpoint
//    reading a stale copy, `g_isDocumentMesh` uninstalled — satisfies all of
//    them for free. So make the SAME counter move first, with a command that
//    is deliberately still batchless.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto s = postTo("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    assert(s["status"].str == "ok", "clear select failed: " ~ s.toString);

    auto b = changes();
    foreach (c; kBatchlessControlSeq) cmd(c);
    auto a = changes();

    immutable long ctrl = a["unbatchedGeometryCommits"].integer
                        - b["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        kBatchlessControlWhy ~ ctrl.to!string ~ kBatchlessControlFix);
}

// ---------------------------------------------------------------------------
// 0b. THE SECOND POSITIVE CONTROL — task 1903 Stage M.
//
//     Block 0 above makes `unbatchedGeometryCommits` move. It says NOTHING
//     about `opLogEntriesRecorded`, and this file asserts THAT counter at zero
//     FIVE times: `assertUnrecorded` for the edge arm, the two fin-bundle
//     doors and the tool's `doApply`, plus the preview drag in block 4. Until
//     this block there was no cell in this binary that made it move, so a dead
//     `opLogEntriesRecorded` — a stale `/api/changes` copy, a bus field that
//     stopped being written — satisfied all five for free. The file even
//     carried the shape of the fix, `assertRecorded` at the top, DECLARED AND
//     NEVER CALLED: the edge bevel family is a Stage-A decline, so it has no
//     recording command of its own to point it at.
//
//     `mesh.delete` is one of the four ops that shipped on the per-mutation
//     tracker default-on, so it records into an op-log. The wording is the
//     twin of `tests/test_radial_sweep_handle_drag.d`'s control, deliberately:
//     a red should read the same in both files.
//
//     THE TERM IS EXACT (== 1), not `> 0`. `mesh.delete` on ONE cube face
//     records exactly one entry (measured), and a `> 0` would stay green if
//     the delete grew a second, unpaired entry — which is the same class of
//     drift `assertRecorded`'s own doc block was written about.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto s = postTo("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
    assert(s["status"].str == "ok", "control select failed: " ~ s.toString);

    auto b = changes();
    cmd("mesh.delete");
    auto a = changes();

    immutable long ctl = a["opLogEntriesRecorded"].integer
                       - b["opLogEntriesRecorded"].integer;
    assert(ctl == 1,
        "positive control: mesh.delete records into an op-log and must tick "
      ~ "changeBus.opLogEntriesRecorded exactly once on a single cube face, "
      ~ "and it ticked " ~ ctl.to!string ~ ". A dead counter passes every "
      ~ "`opLogEntriesRecorded == 0` assertion in this file for free — the "
      ~ "edge arm, both fin-bundle doors, the tool's doApply and the preview "
      ~ "drag in block 4 (task 1903 §5.8, Stage M).");

    assert(faceCount(model()) == 5,
        "the control's delete did not remove a face, so the tick above (or "
      ~ "its absence) says nothing about the counter");
}

// ---------------------------------------------------------------------------
// 1. `mesh.bevel` — the EDGE arm.
//
//    THIS CELL IS A FLIP, NOT A NEW ROW. Stage F2 scoped its polygon-arm batch
//    to the polygon arm alone and used the EDGE arm as the NEGATIVE CONTROL for
//    that narrowing: `tests/test_poly_bevel_seam_counters.d` asserted
//    `unbatched > 0` there and measured +8, because `bevelEdgesByMask` was a
//    mixin member with no caller-held batch. Stage G gives the edge arm its own
//    narrow batch and the same measurement reads +0; that assertion is flipped
//    to `== 0` in this commit, and this cell is its wire-level twin.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectTopFrontEdge();

    auto b = changes();
    cmd(`{"id":"mesh.bevel","params":{"width":0.1}}`);
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 10 && faceCount(m) == 7,
        format("mesh.bevel in EDGE mode left V=%d F=%d, expected 10/7 (two rail "
             ~ "vertices in, one chamfer strip) — `bevelEdgesByMask` refuses on "
             ~ "a great many preconditions and a refusal makes NO commits at "
             ~ "all, so every counter delta below would be vacuous",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.bevel (edge mode)",
        "Measured with the deferral disabled (M-G-BATCH): +8 for ONE cube edge "
      ~ "at round level 0. The same cell measured +8 BEFORE Stage G too, on the "
      ~ "shipped build, because the edge arm had no batch at all — that is the "
      ~ "number tests/test_poly_bevel_seam_counters.d asserted as `> 0` and "
      ~ "this stage flipped.");
    // STAGE L7 LOOKED AT THIS ROW AND DECLINED IT — the assertion is
    // UNCHANGED and that is now a positive statement rather than a pending
    // one. `mesh.bevel`'s POLYGON arm migrated (see
    // `tests/test_poly_bevel_seam_counters.d`, which now asserts THREE
    // entries); the EDGE arm keeps its `MeshSnapshot` because all three
    // candidate delta shapes were measured and refused — routing rewrite #1
    // through `Mesh.setFaceWindings` is inadmissible (it GROWS the face count,
    // 9 -> 11 for one interior edge), the two-handle `carriedPerFace` shape is
    // unsound (the merge pass can leave a corner on a vertex its source face
    // does not contain), and arming as-is loses a Point-domain map VALUE that
    // needs a `MeshOpEntry` payload FIELD. The full argument is at
    // `commands/mesh/bevel.d`'s class doc comment.
    assertUnrecorded(b, a, "mesh.bevel (edge mode)",
        "The point-domain payload on `Kind.RemoveVerts`");
}

// ---------------------------------------------------------------------------
// 2. THE FIN-BUNDLE PATH — the branch a cube cannot reach (памятка 22), and the
//    one Stage G changed most: until this stage it opened TWO transitional
//    `unrecorded` batches of its own.
// ---------------------------------------------------------------------------
unittest {   // the single-spine door
    loadFinBundle(3);
    immutable int spine = edgeIndexOf(0, 1);
    assert(spine >= 0, "the loaded fin bundle has no (0,1) spine edge");
    selectEdges([spine]);

    auto b = changes();
    cmd(`{"id":"mesh.bevel","params":{"width":0.4}}`);
    auto a = changes();

    auto m = model();
    // ANTI-VACUITY, AND IT IS WHAT PROVES THE BRANCH WAS TAKEN. The fin law's
    // fingerprint: the two spine vertices are consumed and replaced by 2N
    // rails (8 -> 12), and exactly TWO fan caps appear beside the three
    // still-quad fins. An ordinary manifold bevel produces neither.
    assert(vertCount(m) == 12 && faceCount(m) == 5,
        format("the 3-fin bundle bevel left V=%d F=%d, expected V=12 F=5 (six "
             ~ "rails in, the two spine verts out, two fan caps added). On a "
             ~ "REFUSAL the mesh is byte-identical and every counter delta "
             ~ "below is vacuous (task 1903 Stage G).",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.bevel (isolated fin bundle)",
        "Measured with the deferral disabled (M-G-BATCH): +12 on this "
      ~ "three-fin stand, and it grows with N. NOTE WHAT CHANGED HERE AT STAGE "
      ~ "G: this path used to read 0 for a DIFFERENT reason — edge_bevel.d's "
      ~ "own transitional `unrecorded` batch, opened at the early return "
      ~ "because the kernel was a mixin body with no caller batch to hand on. "
      ~ "The zero is the same and the reason is not, which is why the "
      ~ "nestedBatchOpens delta above is worth reading twice.");
    // Same decline as the interior-edge cell above: the fin bundles are early
    // returns from `bevelEdgesByMask`, so they ride the EDGE arm's undo. Note
    // the KERNELS did migrate — stage L7-P2 gave both `bevel_fin.d` kernels a
    // winding publisher and the multi-edge one its corner declaration — and
    // `tests/unit/mesh_ops/bevel_fin_test.d` measures that. This row is about
    // the COMMAND's constructor, which is a different question and has a
    // different answer.
    assertUnrecorded(b, a, "mesh.bevel (isolated fin bundle)",
        "The point-domain payload on `Kind.RemoveVerts`");
}

unittest {   // the MULTI-EDGE door — the second of the two arms
    loadFinBundle(3);
    immutable int spine = edgeIndexOf(0, 1);
    immutable int extra = edgeIndexOf(0, 2);     // fin 0's outer rim edge at +z
    assert(spine >= 0 && extra >= 0,
        "the loaded fin bundle lost its spine or its +z rim edge");
    selectEdges([spine, extra]);

    auto b = changes();
    cmd(`{"id":"mesh.bevel","params":{"width":0.4}}`);
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 13 && faceCount(m) == 5,
        format("the multi-edge fin bevel left V=%d F=%d, expected V=13 F=5 (the "
             ~ "plain 12, plus the extra edge's far vertex corner-cut into two "
             ~ "and the original dropped). On a REFUSAL every counter delta "
             ~ "below is vacuous (task 1903 Stage G).",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.bevel (multi-edge fin bundle)",
        "Measured with the deferral disabled (M-G-BATCH): +14 — a DIFFERENT "
      ~ "number from the single-spine cell's +12, which is why both arms have "
      ~ "their own cell: this one runs the corner-cut the other does not.");
    assertUnrecorded(b, a, "mesh.bevel (multi-edge fin bundle)",
        "The point-domain payload on `Kind.RemoveVerts`");
}

// ---------------------------------------------------------------------------
// 3. THE TOOL'S COMMIT DOOR (`applyHeadless`) — a different call site from the
//    command, reached through `tool.doApply`.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectTopFrontEdge();
    cmd("tool.set edge.bevel on");
    settle();
    cmd("tool.attr edge.bevel width 0.1");
    settle();

    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 10 && faceCount(m) == 7,
        format("the Edge Bevel tool's doApply left V=%d F=%d, expected 10/7 — "
             ~ "on a refusal every counter delta below is vacuous",
               vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "the Edge Bevel tool's doApply",
        "Measured with the deferral disabled (M-G-BATCH): +8 for one cube edge "
      ~ "— the same ladder the command's edge arm walks, because it is the same "
      ~ "kernel through a different door.");
    assertUnrecorded(b, a, "the Edge Bevel tool's doApply",
        "Stage M (the tool pair-holders), with Stage L7 for the family's delta");
    cmd("tool.set edge.bevel off");
}

// ---------------------------------------------------------------------------
// 4. THE PER-FRAME PREVIEW (plan §9) — the caller a command cannot reach.
//
//    The Edge Bevel tool goes through `tools/edit/preview_rebuild.d` (task
//    1620), so the kernel runs on a PRIVATE CLEAN CAGE on the placement path
//    and on the live mesh only when the topology key changes. Stage G opens the
//    batch INSIDE the tool's own kernel lambda, which lands it on whichever
//    mesh the kernel actually got — both of plan §9.1's stated consequences,
//    with no edit to the shared seam (`preview_rebuild.d` still serves
//    `mesh_ops/extrude.d`, Stage H's family). That is the decision Stage F2
//    took and памятка 41 records; Stage G inherits it rather than re-arguing it.
// ---------------------------------------------------------------------------
void handleScreen(int part, out int x, out int y) {
    // The handle bank is published by `draw()`, not by `tool.set`, so a fixed
    // settle() is a race: a slow frame leaves `/api/tool/handles` as `{}` and
    // the JSON index throws instead of asserting. Waiting for the bank is also
    // the anti-vacuity guard for the drag block — a drag aimed at a handle that
    // was never published cannot capture, and an uncaptured drag moves no
    // counter at all.
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
                ~ "and read as free zeroes (task 1903 Stage G).");
}

unittest {
    enum int kFrames = 12;
    resetCube();
    selectTopFrontEdge();
    cmd("tool.set edge.bevel on");
    settle();

    int sx, sy;
    handleScreen(0, sx, sy);          // part 0 = Width
    // Hover twice before down: `queryMouse` is the tool's hit-test source and
    // may otherwise still report the previous SDL position.
    play(motion(sx, sy, 0) ~ "\n" ~ motion(sx, sy, 0));
    play(button("SDL_MOUSEBUTTONDOWN", sx, sy));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "the Width handle did not capture on mouse-down — every counter delta "
      ~ "below would be measuring a drag that never began");

    enum int DX = -50, DY = -90;      // up-left, along the width screen axis
    auto b = changes();
    foreach (i; 1 .. kFrames + 1)
        play(motion(sx + DX * i / kFrames, sy + DY * i / kFrames, 1));
    auto a = changes();

    // ANTI-VACUITY, and it is the load-bearing half: a drag that never entered
    // `onMouseMotion` rebuilds no preview and moves no counter, so the zeroes
    // below would be free.
    immutable double widthNow = getJson("/api/tool/state")["width"].floating;
    assert(widthNow > 1e-4,
        format("the drag left `width` at %.6f; the press leaves it at 0 and "
             ~ "this drag runs %d motions along the width axis, so it must be "
             ~ "clearly positive. A width still at 0 means `onMouseMotion` "
             ~ "never ran — no preview frame was rebuilt and every counter "
             ~ "delta below would be free zeroes "
             ~ "(task 1903 Stage G, plan §9).", widthNow, kFrames));
    assert(getJson("/api/tool/state")["built"].type == JSONType.true_,
        "the drag did not build a live preview");

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "the Edge Bevel drag made " ~ unbatched.to!string ~ " UNBATCHED "
      ~ "geometry commit(s) across " ~ kFrames.to!string ~ " preview frames. "
      ~ "Stage G gave the tool's `preview_.run` kernel lambda an UNRECORDED "
      ~ "MeshEditBatch per frame, opened INSIDE the lambda so it lands on the "
      ~ "clean cage on the placement path and on the live mesh on a full "
      ~ "rebuild. AND READ THIS ZERO NARROWLY (памятка 40; E2 memo m6 — name "
      ~ "the caller KIND before quoting a counter): "
      ~ "`unbatchedGeometryCommits` is DOCUMENT-MESH FILTERED by "
      ~ "`g_isDocumentMesh` (plan §3.2 L2), and on a `PreviewRebuild` tool most "
      ~ "frames run the kernel on the PRIVATE CAGE, which the counter cannot "
      ~ "see. Measured with the deferral disabled, this exact drag reads +8 "
      ~ "TOTAL — one full rebuild on the live mesh at 8 commits, and eleven "
      ~ "placement frames invisible to this counter. So this cell witnesses the "
      ~ "FULL-REBUILD frames only; the row that covers EVERY frame is "
      ~ "`opLogEntriesRecorded` below (plan §3.2 L2, §9, §9.1).");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the Edge Bevel drag recorded " ~ opLog.to!string ~ " op-log entr(ies) "
      ~ "across its preview frames. Plan §9 is explicit that the interactive "
      ~ "preview path must stay UNRECORDED: a recording batch opened per drag "
      ~ "frame builds and throws away a full op-log at 60 Hz. THIS counter has "
      ~ "NO document-mesh filter, so unlike the unbatched row above it covers "
      ~ "every frame, cage frames included — which is what makes it the §9 pin "
      ~ "on a PreviewRebuild tool. Switching the lambda's constructor from "
      ~ "`MeshEditBatch.unrecorded` to `MeshEditBatch` is the mutation this "
      ~ "reddens under (task 1903 Stage G, M-P/G).");

    immutable long leaks = a["batchLeaks"].integer - b["batchLeaks"].integer;
    assert(leaks == 0,
        "a MeshEditBatch leaked its frame during the Edge Bevel drag. On a "
      ~ "per-frame batch a leak is not a one-off: the module-level frame stack "
      ~ "would make every later commit in the process defer into a dead batch "
      ~ "(task 1903 §2.2c).");
    assert(a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer == 0,
        "the Edge Bevel drag opened a NESTED batch — the per-frame preview "
      ~ "batch must be the outermost open on its frame. NOTE THE SHAPE THIS "
      ~ "CELL GUARDS: the batch is opened inside the kernel lambda, so a second "
      ~ "one opened around `preview_.run` would nest rather than replace it "
      ~ "(task 1903 §2.3 rule 2, Stage G).");

    play(button("SDL_MOUSEBUTTONUP", sx + DX, sy + DY));
    cmd("tool.set edge.bevel off");
}

// ---------------------------------------------------------------------------
// 5. UNDO STILL RESTORES — the snapshot path is untouched.
//
//    Stage G is a CONVERSION stage: the undo axis is L7's. This cell says so
//    out loud, on the path whose caller grew a batch.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectTopFrontEdge();
    cmd(`{"id":"mesh.bevel","params":{"width":0.1}}`);
    assert(vertCount(model()) == 10, "the bevel did not apply; undo proves nothing");
    auto u = postTo("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);
    auto m = model();
    assert(vertCount(m) == 8 && faceCount(m) == 6,
        format("undo left V=%d F=%d, expected the cube's 8/6. The caller's "
             ~ "batch is UNRECORDED and this command still undoes through a "
             ~ "whole-mesh MeshSnapshot; if that stopped working, the batch is "
             ~ "committing something it should not (task 1903 Stage G).",
               vertCount(m), faceCount(m)));
}
