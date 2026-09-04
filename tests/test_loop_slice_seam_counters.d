// test_loop_slice_seam_counters.d — task 1903 Stage F1.
//
// The Loop Slice family became free functions over `ref MeshEditBatch`, and
// every one of its FIVE production callers now opens that batch at its own
// boundary: `mesh.addLoop` and `mesh.loopSlice` (source/commands/mesh/
// loop_slice.d), the tool's commit (`applyHeadless`) and its PER-FRAME preview
// (`rebuildCut`, source/tools/slice/loop_slice_tool.d), and the topology pen's
// Add Loop (source/tools/edit/topology_pen/tool.d). This file is the wire-level
// half of that: `/api/changes` DELTAS around each caller.
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
//     tell one batch over a ladder from a batch per rung — measured at Stage
//     E3 on axis_slice, where moving the open inside the loop left every wire
//     counter byte-identical. That discrimination lives in the unit lane, on
//     `mutationVersion` (tests/unit/mesh_ops/loop_slice_test.d).
//   * `nestedBatchOpens` says the caller's open is the OUTERMOST one. F1 has
//     no §4.4a transitional debt — no intra-mesh or still-mixin caller reaches
//     this family — so the delta is the pin that KEEPS it that way: a future
//     stage that adds an inner open would move it.
//   * `opLogEntriesRecorded` is the §9 pin. It is the only counter that
//     separates an `unrecorded` batch from a recording one, and on the drag
//     path it is the whole point.
//
// The counters are read around a command that must have DONE something, and
// each block asserts the geometry first — a refusal makes every zero below it
// vacuous.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : sqrt;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;

JSONValue postCmd(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}


void resetCube() {
    auto r = postCmd("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}
void cmd(string s) {
    auto r = postCmd("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}
JSONValue model()   { return getJson("/api/model"); }
JSONValue changes() { return getJson("/api/changes"); }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faceCount"].integer; }

struct V3 { double x, y, z; }
V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int) i;
    }
    return -1;
}
int edgeIndexOf(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int) e.array[0].integer, y = cast(int) e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int) i;
    }
    return -1;
}
// The cube belt seed edge (-0.5,-0.5,-0.5)-(0.5,-0.5,-0.5), the same one
// tests/test_loop_slice_tool.d T1 and test_loop_slice_v2.d use.
int seedEdgeIndex() {
    auto m  = model();
    int va = vertAt(m, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(m, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube belt verts not found");
    int ei = edgeIndexOf(m, va, vb);
    assert(ei >= 0, "cube belt edge not found");
    return ei;
}
void selectEdge(int ei) {
    auto r = postCmd("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
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
        what ~ " opened " ~ nested.to!string ~ " NESTED batch(es). Stage F1 "
      ~ "gives this family NO §4.4a transitional debt — every caller opens at "
      ~ "its own boundary and there is no intra-mesh or still-mixin caller "
      ~ "underneath it. A non-zero delta means somebody above this caller now "
      ~ "holds a batch too; collapse the two rather than nesting "
      ~ "(task 1903 Stage F1, plan §2.3 rule 2).");

    immutable long unbatched = after["unbatchedGeometryCommits"].integer
                             - before["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        what ~ " made " ~ unbatched.to!string ~ " UNBATCHED geometry commit(s). "
      ~ "The kernels' receiver is `ref MeshEditBatch`, so their internal "
      ~ "commits must defer into the frame and stamp once at close(). "
      ~ unbatchedNote ~ " (task 1903 Stage F1, plan §3.2 L2).");

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
      ~ "3 refuses outright (task 1903 Stage F1).");
}

// ---------------------------------------------------------------------------
// 1. `mesh.addLoop` — one loop, the simplest caller.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectEdge(seedEdgeIndex());

    auto b = changes();
    cmd("mesh.addLoop");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 12 && faceCount(m) == 10,
        format("mesh.addLoop left V=%d F=%d, expected 12/10 (one belt loop: "
             ~ "+4 verts, +4 faces) — on a refusal every counter delta below "
             ~ "is vacuous", vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "mesh.addLoop",
        "Measured with the deferral disabled: +6 on this cube belt "
      ~ "(tests/unit/mesh_ops/loop_slice_test.d records the same figure as a "
      ~ "mutationVersion delta), and it GROWS with the position count.");

    // TASK 1903 STAGE L9-b FLIPPED THIS ROW. `mesh.addLoop` now opens a
    // RECORDING batch and undoes from the op-log; the whole-mesh
    // `MeshSnapshot` is gone. The count is EXACT rather than `> 0`, because
    // the KIND SEQUENCE is what the corner carry binds on and a growing log
    // would mean an extra publisher landed between the payload and its face
    // entry. On this CUBE stand there is no PolyVertex map, so no
    // `MeshMapDelta` is recorded and the log is `[AddVerts, FaceReindex]` —
    // two entries. The three-entry form is on the UV-carrying stand in
    // `tests/unit/l9_loop_slice_delta_test.d`, which is where the sequence
    // itself is asserted; this row is the only one in EITHER lane that sees
    // the COMMAND's own constructor.
    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 2,
        "mesh.addLoop recorded " ~ opLog.to!string ~ " op-log entr(ies), "
      ~ "expected 2 ([AddVerts, FaceReindex] on a cube, which carries no "
      ~ "per-corner map). ZERO means the batch went back to the `unrecorded` "
      ~ "constructor and this command has no undo image at all — the unit "
      ~ "lane cannot see that, because its cells drive the KERNEL under their "
      ~ "own recording batch (task 1903 Stage L9-b).");
}

// ---------------------------------------------------------------------------
// 2. `mesh.loopSlice` — and it is a SCALE check, run at two ladder lengths.
//    The zero has to hold as the work grows, which is what separates "the
//    batch spans the cut" from "the batch happens to cover a one-rung ladder".
// ---------------------------------------------------------------------------
unittest {
    foreach (count; [3, 8]) {
        resetCube();
        selectEdge(seedEdgeIndex());

        auto b = changes();
        auto rc = postCmd("/api/command",
            `{"id":"mesh.loopSlice","params":{"count":` ~ count.to!string ~ `}}`);
        assert(rc["status"].str == "ok",
            format("mesh.loopSlice count=%d failed: %s", count, rc.toString));
        auto a = changes();

        auto m = model();
        immutable long wantV = 8 + 4 * count, wantF = 6 + 4 * count;
        assert(vertCount(m) == wantV && faceCount(m) == wantF,
            format("mesh.loopSlice count=%d left V=%d F=%d, expected %d/%d — "
                 ~ "on a refusal every counter delta below is vacuous",
                   count, vertCount(m), faceCount(m), wantV, wantF));

        assertSeamClean(b, a, format("mesh.loopSlice count=%d", count),
            "Measured with the deferral disabled: +6 for one position and +14 "
          ~ "for three on this belt, i.e. the amplitude grows with the ladder "
          ~ "— which is why this block runs count=3 AND count=8.");

        // TASK 1903 STAGE L9-a FLIPPED THIS ROW — see the note on
        // `mesh.addLoop` above. The count does NOT grow with the ladder: the
        // whole ladder is ONE `insertEdgeLoops` call, so it is one `AddVerts`
        // and one `FaceReindex` at count=3 and at count=8 alike. That
        // invariance is the point of running both.
        immutable long opLog = a["opLogEntriesRecorded"].integer
                             - b["opLogEntriesRecorded"].integer;
        assert(opLog == 2,
            format("mesh.loopSlice count=%d recorded %d op-log entr(ies), "
                 ~ "expected 2 ([AddVerts, FaceReindex] on a cube). ZERO means "
                 ~ "the batch went back to the `unrecorded` constructor; a "
                 ~ "count that GROWS with the ladder means the batch stopped "
                 ~ "spanning the cut (task 1903 Stage L9-a).", count, opLog));
    }
}

// ---------------------------------------------------------------------------
// 2b. W-9-UNDO — the delta undo through the REAL history stack, with the
//     stack depth asserted.
//
//     Neither lane's other cells drive `/api/undo`: the unit cells call
//     `revert()` directly, which cannot see the funnel at all. A witness has
//     been inert twice in this task for exactly that — "undo ran" was asserted
//     by a `status:ok` an endpoint returns whatever it did. So this cell
//     asserts a stack-depth delta of EXACTLY ONE, in both directions, and that
//     the mesh moved.
//
//     MUTATION: stub `/api/undo` to a literal `{"status":"ok"}`. The depth
//     does not move and the cell reddens naming the count.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectEdge(seedEdgeIndex());

    immutable long d0 = undoDepth();
    auto rc = postCmd("/api/command", `{"id":"mesh.loopSlice","params":{"count":3}}`);
    assert(rc["status"].str == "ok", "mesh.loopSlice failed: " ~ rc.toString);
    immutable long d1 = undoDepth();
    assert(d1 - d0 == 1,
        format("mesh.loopSlice moved the undo stack by %d entr(ies), expected "
             ~ "exactly 1 — with no entry recorded, the undo below is undoing "
             ~ "somebody else's command and every assertion after it is about "
             ~ "the wrong operation", d1 - d0));

    auto m1 = model();
    assert(vertCount(m1) == 20 && faceCount(m1) == 18,
        format("the cut left V=%d F=%d, expected 20/18 — on a refusal the "
             ~ "round trip below is satisfied by an undo that does nothing",
               vertCount(m1), faceCount(m1)));

    auto u = postCmd("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);
    immutable long d2 = undoDepth();
    assert(d0 - d2 == 0 && d1 - d2 == 1,
        format("the undo moved the stack from %d to %d (it was %d before the "
             ~ "cut) — a stack that does not move by exactly one means the "
             ~ "endpoint answered ok without undoing anything", d1, d2, d0));

    auto m2 = model();
    assert(vertCount(m2) == 8 && faceCount(m2) == 6,
        format("undo left V=%d F=%d, expected the cube's 8/6. This command "
             ~ "undoes from its OP-LOG since Stage L9-a; the whole-mesh "
             ~ "MeshSnapshot is gone, so a wrong count here is the delta "
             ~ "replay and not a snapshot restore", vertCount(m2), faceCount(m2)));
}

/// Depth of the undo stack, for the cell above.
long undoDepth() { return getJson("/api/history")["undo"].array.length; }

// ---------------------------------------------------------------------------
// 3. The TOOL's commit path (`applyHeadless`), which is a different call site
//    from the two commands and passes every Slice option the commands do not.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    selectEdge(seedEdgeIndex());
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 2");

    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 16 && faceCount(m) == 14,
        format("the Loop Slice tool's doApply left V=%d F=%d, expected 16/14 "
             ~ "(two belt loops) — on a refusal every counter delta below is "
             ~ "vacuous", vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "the Loop Slice tool's doApply",
        "Measured with the deferral disabled: +10 for a two-position cut on "
      ~ "this belt.");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the Loop Slice tool's doApply recorded " ~ opLog.to!string
      ~ " op-log entr(ies). The tool commits through a whole-mesh MeshSnapshot "
      ~ "pair, so its batch is UNRECORDED; Stage M owns the tool pair-holders "
      ~ "(task 1903 Stage F1, plan §9).");

    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// 4. The TOPOLOGY PEN's Add Loop — the fifth caller, and the only one reached
//    by a real gesture rather than a command. Shift+MMB on the seed edge's own
//    midpoint runs `commitAddLoop`, which opens the batch around its single
//    `insertEdgeLoops` call.
// ---------------------------------------------------------------------------
unittest {
    import topopen_place_helpers : fetchCamera, viewportFromCamera,
                                   projectToWindow, waitPlayerIdle, viewportLog,
                                   Vec3;
    enum uint LSHIFT = 0x0001;

    resetCube();
    postCmd("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera(BASE);
    auto vp = viewportFromCamera(c);
    float sx, sy;
    assert(projectToWindow(Vec3(0.0f, -0.5f, -0.5f), vp, sx, sy),
        "the belt edge's midpoint must project on-screen at this framing");

    cmd("tool.set mesh.topoPen on");

    auto b = changes();
    auto pr = postCmd("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
      ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
               cast(int) sx, cast(int) sy, LSHIFT) ~ "\n"
      ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
               cast(int) sx, cast(int) sy, LSHIFT) ~ "\n");
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    auto a = changes();

    auto m = model();
    assert(vertCount(m) == 12 && faceCount(m) == 10,
        format("the pen's Add Loop left V=%d F=%d, expected 12/10 — on a "
             ~ "gesture that missed the edge every counter delta below is "
             ~ "vacuous", vertCount(m), faceCount(m)));

    assertSeamClean(b, a, "the topology pen's Add Loop",
        "Measured with the deferral disabled: +6 for the one-position cut this "
      ~ "gesture performs.");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the topology pen's Add Loop recorded " ~ opLog.to!string
      ~ " op-log entr(ies). It records its undo as a whole-mesh MeshSnapshot "
      ~ "pair through `addLoopEditFactory_`, so its batch is UNRECORDED; Stage "
      ~ "M owns the topology pen as its own family "
      ~ "(task 1903 Stage F1, plan §12 M).");

    cmd("tool.set mesh.topoPen off");
}

// ---------------------------------------------------------------------------
// 5. THE PER-FRAME PREVIEW (plan §9) — the one caller a command cannot reach.
//
// `rebuildCut()` re-runs the WHOLE cut on every scrub motion while the tool is
// armed, so a drag of N motion events is N complete kernel runs on the live
// mesh. Stage F1 gave that path an UNRECORDED batch per frame, and unrecorded
// is not a convenience: a recording batch here builds and throws away a full
// op-log at 60 Hz.
//
// The arm is SELECTION-seeded (`activationSeeds()`), so the click pixel only
// has to land inside a registered viewport cell — this cell does not depend on
// GPU picking resolving a particular edge.
// ---------------------------------------------------------------------------
enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

void playAndSettle(string log) {
    auto r = postCmd("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "play-events replay did not finish within 10s");
    Thread.sleep(150.msecs);
}

unittest {
    enum int kFrames = 12;

    resetCube();
    selectEdge(seedEdgeIndex());
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");

    // Arm + hold: LMB down with NO up, so `scrubbing_` stays true and every
    // motion below re-enters `rebuildCut()`.
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                        VPX, VPY, VPW, VPH) ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);

    auto armed = model();
    assert(vertCount(armed) == 12,
        format("the arming click did not build a standing preview (V=%d, "
             ~ "expected 12) — every counter delta below would be measuring a "
             ~ "drag that never began", vertCount(armed)));

    // NOW the drag. `state:1` = LMB held, which is what the replay needs for
    // the motion to reach a scrubbing tool.
    auto b = changes();
    // The scrub runs from the LEFT edge of the viewport rightwards in 25 px
    // steps. Deliberately a long span: the elected point is the closest point
    // on the seed rail to the cursor ray and it CLAMPS, so a long drag drives
    // `position` almost the whole way to 1 — a ~0.49 signal instead of the
    // ~0.03 a short drag around the centre produces, which is what makes the
    // anti-vacuity assertion below robust rather than marginal.
    string drag;
    foreach (i; 0 .. kFrames) {
        immutable int x = 175 + cast(int)(i * 25);
        drag ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":25,"yrel":0,"state":1,"mod":0}`,
                       100.0 + i * 10.0, x, CY);
        if (i + 1 < kFrames) drag ~= "\n";
    }
    playAndSettle(drag ~ "\n");
    auto a = changes();

    // ANTI-VACUITY, and it is the load-bearing half: a drag that never entered
    // `onMouseMotion` moves no counter, so three zeroes would be free. The
    // preview mesh is REBUILT from the restored baseline every frame, so the
    // vertex count stays at the armed value — what proves the frames ran is
    // that the tool's own `position` attribute moved off the value the arm
    // left it at.
    auto pos = postCmd("/api/command", "tool.attr mesh.loopSliceTool position ?");
    assert(pos["status"].str == "ok", "position query failed: " ~ pos.toString);
    immutable double posAfter = pos["value"].floating;
    assert(posAfter > 0.9,
        format("the scrub left `position` at %.6f; the arm leaves it at 0.5 "
             ~ "and this drag runs the cursor from the viewport's left edge "
             ~ "rightwards past the rail's far end, so it must clamp near 1. "
             ~ "A position still at 0.5 means `onMouseMotion` never ran — no "
             ~ "preview frame was rebuilt and every counter delta below would "
             ~ "be three free zeroes (task 1903 Stage F1, plan §9).", posAfter));
    assert(vertCount(model()) == 12,
        format("the drag left V=%d, expected the preview to stay at 12 — the "
             ~ "scrub relocates the loop, it does not add another",
               vertCount(model())));

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "the Loop Slice scrub made " ~ unbatched.to!string ~ " UNBATCHED "
      ~ "geometry commit(s) across " ~ kFrames.to!string ~ " preview frames. "
      ~ "Stage F1 gave `rebuildCut` an UNRECORDED MeshEditBatch per frame, so "
      ~ "each frame's internal commits defer and stamp once at close(). "
      ~ "Measured with the deferral disabled: +6 PER FRAME on this belt — the "
      ~ "per-frame figure is what makes this cell different in kind from the "
      ~ "headless one (plan §3.2 L2, §9).");

    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "the Loop Slice scrub recorded " ~ opLog.to!string ~ " op-log entr(ies) "
      ~ "across its preview frames. Plan §9 is explicit that the interactive "
      ~ "preview path must stay UNRECORDED: a recording batch opened per drag "
      ~ "frame builds and throws away a full op-log at 60 Hz. Switching "
      ~ "`rebuildCut`'s constructor from `MeshEditBatch.unrecorded` to "
      ~ "`MeshEditBatch` is the mutation this reddens under "
      ~ "(task 1903 Stage F1).");

    immutable long leaks = a["batchLeaks"].integer - b["batchLeaks"].integer;
    assert(leaks == 0,
        "a MeshEditBatch leaked its frame during the Loop Slice scrub. On a "
      ~ "per-frame batch a leak is not a one-off: the module-level frame stack "
      ~ "would make every later commit in the process defer into a dead batch "
      ~ "(task 1903 §2.2c).");

    assert(a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer == 0,
        "the Loop Slice scrub opened a NESTED batch — the per-frame preview "
      ~ "batch must be the outermost open on its frame (task 1903 §2.3 rule 2).");

    // Leave the tool in a clean state for whatever runs next.
    playAndSettle(format(`{"t":0.000,"type":"SDL_KEYDOWN","sym":27,"scan":0,"mod":0,"repeat":0}`));
    cmd("tool.set mesh.loopSliceTool off");
}
