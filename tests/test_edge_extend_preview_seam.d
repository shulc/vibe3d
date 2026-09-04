// test_edge_extend_preview_seam.d — task 1903 Stage M, the preview PIN (M-P).
//
// THE THIRD ROW, and the only one that was missing. Three tools go through
// `source/tools/edit/preview_rebuild.d` — Poly Bevel (Stage F2), Edge Bevel
// (Stage G) and Edge Extend (Stage H). The first two already carry the §9 pin
// in `tests/test_poly_bevel_seam_counters.d` (block 5) and
// `tests/test_edge_bevel_seam_counters.d` (block 4). Edge Extend carried none:
// `tests/test_edge_extend_tool.d` never reads `/api/changes` at all, so the
// last family on the shared seam was the one family whose preview batch
// nothing watched. This file is that row.
//
// WHY THE COUNTER IS `opLogEntriesRecorded` AND NOT `unbatchedGeometryCommits`
// (plan §9, and it is the correction the whole stage turns on).
// `unbatchedGeometryCommits` is DOCUMENT-MESH FILTERED by `g_isDocumentMesh`,
// and on a `PreviewRebuild` tool most frames run the kernel on the PRIVATE
// CAGE, which that counter cannot see — so a zero on it witnesses the
// FULL-REBUILD frames only. `opLogEntriesRecorded` has no such filter: it is
// incremented at `MeshEditBatch.close()` at the outermost depth by
// `delta.log.length`, so an `unrecorded` batch contributes 0 by construction
// and a recording one contributes per frame, cage frames included.
//
// HOW THE PREVIEW IS DRIVEN, and why not a gizmo drag. Edge Extend embeds an
// XfrmTransformTool Move bank; a real viewport drag needs a camera + screen
// projection, which is why `tests/test_edge_extend_tool.d` says it is out of
// scope. The path taken here is the OTHER production entry into the same
// `rebuildPreview()`: `Tool.notifyInteractiveParamChanged`, which
// `source/property_panel.d:151` fires on a panel scrub and
// `source/commands/tool/attr.d:122` fires for a `tool.attr` dispatched with
// `req.interactive` set. `/api/command` hard-codes that flag to FALSE (a raw
// command is discrete, `http_server.d:3494`), so the wire spelling that
// reaches the preview is `/api/script?interactive=true` — anything posted to
// `/api/command` would move `offsetY` and rebuild NOTHING, which is a green
// for free.
//
// THE ANTI-VACUITY TERM FOLLOWS THE OPERAND, it is not a `> 0`. Each preview
// rebuild that keeps the topology key ends in
// `PreviewRebuild.run`'s `live.adoptVertexPositions(cage_.vertices)` — one
// Position delivery on the LIVE mesh — and the first one, which has no
// standing key, takes `fullRebuild` and delivers Polygons|Points|Position
// instead. So N writes deliver exactly N times, of which exactly one is a full
// rebuild. Measured on this stand at three different N (8 → 8, 12 → 12,
// 20 → 20, `totalPolygons` == 1 throughout). A drag that never entered
// `onParamChanged` reads 0 there and the op-log zero below would be free.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;

/// How many interactive parameter writes one preview cell drives. Named once:
/// every exact term below is stated against it, so the cell scales with the
/// operand rather than against a constant somebody has to keep in step.
enum int kWrites = 12;

/// What `EdgeExtendTool.commitEdit` records for this stand. EXACT, not `> 0`:
/// `AddVerts`, `MeshMapDelta`, `FaceReindex` — the shape stage H gave it. A
/// `> 0` would be green if the commit lost two of its three entries.
enum long kCommitEntries = 3;

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
JSONValue changes() { return getJson("/api/changes"); }
JSONValue model()   { return getJson("/api/model"); }
JSONValue state()   { return getJson("/api/tool/state"); }
void settle() { Thread.sleep(140.msecs); }

long counter(JSONValue a, JSONValue b, string key) {
    return b[key].integer - a[key].integer;
}

/// ONE interactive parameter write. `/api/script?interactive=true` is the ONLY
/// wire spelling that sets `req.interactive`, and `req.interactive` is the ONLY
/// thing that makes `tool.attr` call `notifyInteractiveParamChanged` instead of
/// the bare `onParamChanged` — which is what `rebuildPreview()` is gated on
/// (`source/tools/edit/edge_extend.d:424`). Post the same line to
/// `/api/command` and the value lands, the preview does not rebuild, and every
/// counter below reads zero for the wrong reason.
void interactiveAttr(string line) {
    auto r = postTo("/api/script?interactive=true", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "interactive script line `" ~ line ~ "` failed: " ~ r.toString);
}

/// Arm the tool on one cube edge and leave it built-less: `activate` applies
/// the defaults, so the ridge is standing but no parameter has been scrubbed.
void armOnEdgeZero() {
    resetCube();
    auto s = postTo("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[0]}`));
    assert(s["status"].str == "ok", "edge select failed: " ~ s.toString);
    cmd("tool.set edge.extend on");
    settle();
}

// ---------------------------------------------------------------------------
// 1. THE PREVIEW — plan §9's pin, on the third and last `PreviewRebuild` tool.
// ---------------------------------------------------------------------------
unittest {
    armOnEdgeZero();

    auto b = changes();
    foreach (i; 1 .. kWrites + 1)
        interactiveAttr(format("tool.attr edge.extend offsetY %.4f", 0.02 * i));
    auto a = changes();

    // ANTI-VACUITY FIRST, and it is the load-bearing half. Asserted BEFORE the
    // op-log row deliberately: a zero measured across a scrub that never
    // rebuilt anything is the vacuous green this whole file exists to refuse
    // (the project's `killStaleVibe` shape).
    auto st = state();
    immutable double offsetNow = st["offsetY"].floating;
    immutable double offsetWant = 0.02 * kWrites;
    assert(offsetNow > offsetWant - 1e-3,
        format("the %d interactive writes left `offsetY` at %.6f, expected "
             ~ "~%.4f. The value is injected by `injectParamsInto` before the "
             ~ "notification, so an offsetY that did not arrive means the "
             ~ "writes did not land at all and every counter below is a free "
             ~ "zero (task 1903 Stage M, M-P/H).",
               kWrites, offsetNow, offsetWant));
    assert(st["built"].type == JSONType.true_,
        "the tool reports no live preview after " ~ kWrites.to!string
      ~ " interactive parameter writes — `rebuildPreview` never produced a "
      ~ "ridge, so there was no preview path to measure "
      ~ "(task 1903 Stage M, M-P/H).");
    assert(model()["vertexCount"].integer == 10,
        format("the stand should stand at V=10 (a cube's 8 plus the extend "
             ~ "ridge's 2); it reads V=%d. Without the ridge the kernel took "
             ~ "its `exEdges.length == 0` early return and built nothing.",
               model()["vertexCount"].integer));

    // THE OPERAND-FOLLOWING TERM, which is what makes the zero below a scale
    // claim rather than a constant. Every placement frame ends in
    // `live.adoptVertexPositions(cage_.vertices)` — one Position delivery on
    // the LIVE mesh — and the first write takes `fullRebuild` instead, which
    // delivers Polygons|Points|Position as ONE delivery. So the count is
    // exactly `kWrites`, at every `kWrites`: measured 8/12/20 at N=8/12/20 on
    // this stand.
    immutable long deliveries = counter(b, a, "deliveryCount");
    assert(deliveries == kWrites,
        format("the %d interactive preview rebuilds delivered %d change(s), "
             ~ "expected exactly %d — one per rebuild. This is the term that "
             ~ "says the preview ACTUALLY RAN %d times rather than once or "
             ~ "not at all, and it is stated as an equality against the "
             ~ "operand for the reason the whole track carries: a `> 0` here "
             ~ "is satisfied by a single rebuild and would leave the op-log "
             ~ "row below measuring one frame (task 1903 Stage M).",
               kWrites, deliveries, kWrites, kWrites));
    immutable long fullRebuilds = counter(b, a, "totalPolygons");
    assert(fullRebuilds == 1,
        format("the scrub took %d full rebuild(s), expected exactly 1. Only "
             ~ "the FIRST write has no standing topology key; the remaining "
             ~ "%d keep it and take the placement path onto the private cage. "
             ~ "More than one means the declared key is missing a parameter "
             ~ "(`PreviewRebuild.keyMisses`' subject) and the cage frames this "
             ~ "cell is built to cover were never entered.",
               fullRebuilds, kWrites - 1));

    // THE PIN.
    immutable long opLog = counter(b, a, "opLogEntriesRecorded");
    assert(opLog == 0,
        format("the Edge Extend preview recorded %d op-log entr(ies) across "
             ~ "%d interactive rebuilds. Plan §9 is explicit that the "
             ~ "interactive preview path must stay UNRECORDED: a recording "
             ~ "batch opened per rebuild builds and throws away a full op-log "
             ~ "at scrub rate.\n"
             ~ "  THIS IS `opLogEntriesRecorded`, WHICH IS NOT DOCUMENT-MESH "
             ~ "FILTERED, and that is why it is the pin on a `PreviewRebuild` "
             ~ "tool: `unbatchedGeometryCommits` is filtered by "
             ~ "`g_isDocumentMesh`, so on this tool it would witness only the "
             ~ "ONE full-rebuild frame and say nothing about the %d placement "
             ~ "frames that run on the private cage.\n"
             ~ "  MUTATION M-P/H: switch the batch at "
             ~ "`source/tools/edit/edge_extend.d`'s preview kernel lambda from "
             ~ "`MeshEditBatch.unrecorded(target, kExtrudeEditScope)` to "
             ~ "`MeshEditBatch(target, kExtrudeEditScope)` and this row "
             ~ "reddens (task 1903 Stage M, M-P/H).",
               opLog, kWrites, kWrites - 1));

    assert(counter(b, a, "unbatchedGeometryCommits") == 0,
        format("the Edge Extend preview made %d UNBATCHED geometry commit(s). "
             ~ "Stage H opens the batch INSIDE the kernel lambda so it lands "
             ~ "on whichever mesh the kernel actually got — the cage on a "
             ~ "placement frame, the live mesh on a full rebuild. READ THIS "
             ~ "ZERO NARROWLY: it is document-mesh filtered, so it covers the "
             ~ "one full-rebuild frame and nothing else (plan §3.2 L2, §9.1).",
               counter(b, a, "unbatchedGeometryCommits")));
    assert(counter(b, a, "nestedBatchOpens") == 0,
        "the Edge Extend preview opened a NESTED batch — the per-rebuild "
      ~ "batch must be the outermost open on its frame. NOTE THE SHAPE THIS "
      ~ "GUARDS: the batch is opened inside the kernel lambda, so a second one "
      ~ "opened around `preview_.run` would nest rather than replace it "
      ~ "(task 1903 §2.3 rule 2, Stage M).");
    assert(counter(b, a, "batchLeaks") == 0,
        "a MeshEditBatch leaked its frame during the Edge Extend preview. On "
      ~ "a per-rebuild batch a leak is not a one-off: the frame stack is "
      ~ "module-level, so every later commit in the process would defer into a "
      ~ "dead batch (task 1903 §2.2c).");
    assert(counter(b, a, "batchUpgradeRefusals") == 0,
        "the Edge Extend preview refused a batch upgrade — a RECORDING batch "
      ~ "was opened inside an unrecorded one, which §2.3 rule 3 refuses "
      ~ "outright (task 1903 Stage M).");

    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 2. THE COMMIT — the positive control for the counter above, and the ONE row
//    of the three converted tools where "the commit records" is true.
//
//    A `== 0` assertion is satisfied for free by a dead counter, so the pin in
//    block 1 is worth nothing until the SAME counter is seen to move in the
//    SAME binary. On this tool the control is not a borrowed `mesh.delete`: it
//    is the tool's own commit door, which stage H (L8) gave a RECORDING
//    `MeshEditBatch` (`edge_extend.d` `commitEdit`), so the drop records a
//    delta the command keeps.
//
//    AND THIS IS WHERE THE PLAN'S OWN STEP 4 IS WRONG, recorded so nobody
//    re-derives it. §M.1a asks each of the three converted tools to "commit
//    (drop), assert it is > 0". MEASURED on this tree: Poly Bevel and Edge
//    Bevel record ZERO at the commit and are CORRECT to — their commit paths
//    capture a whole-mesh `MeshSnapshot` and do not re-run the kernel at all
//    (the live mesh already holds the previewed geometry). Asserting `> 0` on
//    those two would be a check that reddens on correct code. Only Edge Extend
//    has a recording commit, which is why the positive control lives here and
//    the other two files borrow theirs from a recorded COMMAND instead.
// ---------------------------------------------------------------------------
unittest {
    armOnEdgeZero();
    foreach (i; 1 .. kWrites + 1)
        interactiveAttr(format("tool.attr edge.extend offsetY %.4f", 0.02 * i));
    assert(state()["built"].type == JSONType.true_,
        "no preview was built, so the drop below has nothing to commit and "
      ~ "the control would read zero for the wrong reason");

    auto b = changes();
    cmd("tool.set edge.extend off");
    settle();
    auto a = changes();

    immutable long opLog = counter(b, a, "opLogEntriesRecorded");
    assert(opLog == kCommitEntries,
        format("the Edge Extend COMMIT recorded %d op-log entr(ies), expected "
             ~ "exactly %d.\n"
             ~ "  A ZERO here is the one that matters most: it means the "
             ~ "commit door opened the UNRECORDED constructor, its undo would "
             ~ "be the whole-mesh `MeshSnapshot` stage H deleted, and — "
             ~ "because every other assertion in this file is `== 0` — a dead "
             ~ "`opLogEntriesRecorded` would satisfy all of them for free. "
             ~ "This row is what says the counter is alive in this binary.\n"
             ~ "  A DIFFERENT non-zero means the recorded shape moved: the "
             ~ "expected three are `AddVerts`, `MeshMapDelta` and "
             ~ "`FaceReindex`, and stage J made that pair's ADJACENCY "
             ~ "contractual (task 1903 Stage M / Stage H).",
               opLog, kCommitEntries));

    assert(model()["vertexCount"].integer == 10,
        "the committed mesh lost the ridge — the commit re-runs the kernel "
      ~ "from the restored cage, and a V != 10 here means the re-run "
      ~ "disagreed with the preview the user saw.");
    assert(counter(b, a, "batchLeaks") == 0,
        "a MeshEditBatch leaked its frame during the Edge Extend commit "
      ~ "(task 1903 §2.2c).");
}
