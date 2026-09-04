// test_falloff_derived_buffers_refire.d — task 0791 (audit-4 P9 siblings).
//
// P9 (task 0724) added `FalloffPacket.pickedCenter` to `falloffPacketsEqual`
// because it is an INPUT to `elementWeight` that lives outside
// `FalloffConfig` and so was invisible to the idle re-grade trigger
// (xfrm_transform.d's ARM 1 / ARM 2 "mid-tool falloff re-apply"). The same
// struct doc (source/toolpipe/packets.d) lists FIVE further fields in the
// same "outside config, rebuilt every evaluate()" bucket: `connectMask`,
// `anchorPos`, `selectionWeights`, `vertexMapWeights`, `compoundPasses`.
// Follow-up 0791 asks whether any of them has the same hole pickedCenter
// had — reproduce per-field, or show why not, per the task's own warning
// not to repeat the assumption that sank P9 the first time ("anchorPos is
// derived from anchorRing, which is in config" is true only if vertex
// POSITIONS are held fixed, which a transform tool's whole job is not to
// do).
//
// MEASURED per field (full trace in the task report):
//
//   * `compoundPasses` — always published 1.0f (source/toolpipe/stages/
//     falloff.d, `pkt.compoundPasses = 1.0f;` unconditional; the
//     `steps*0.955` Scale-pow path xfrm_apply.d's comments describe is
//     dormant/unwired in the current tree). A constant cannot diverge from
//     itself — no case to construct.
//   * `anchorPos` / `connectMask` — both derived from `anchorRing`/
//     `connect` (IN config, already compared) plus live mesh state. The
//     one route that changes their CONTENT without an `anchorRing`/
//     `connect` edit is the SAME gesture moving its own picked anchor
//     vertex (it is weight-1 by the ring short-circuit, so it moves with
//     everything else) — but that staleness is inert: the next reader of
//     `dragFalloff` is always a fresh `captureFalloffForDrag` /
//     `recaptureLivePipePackets` call that overwrites the WHOLE struct
//     before any weight math consumes it. Any OTHER route is an external
//     mesh mutation, which is a foreign undoable command — see below.
//   * `vertexMapWeights` — the active map SWITCH is covered (`mapName` is a
//     config field; see test_falloff_idle_refire.d's (MAP) case). Editing
//     the DATA of the currently-active map is only reachable through
//     `mesh.weightmap.set`, a foreign command (see below).
//
// `selectionWeights` looked like the odd one out — no config field
// mirrors "which vertices are selected", and source/mesh.d documents
// selection changes as deliberately NOT bumping `mutationVersion` (a
// Marks-class change), so ARM 2's OWN staleness gate
// (`mesh.mutationVersion == lastAppliedGestureMutationVersion`) does not
// stop it either. That reads exactly like P9's shape. It measures
// DIFFERENTLY: `mesh.select` (the only selection-changing command; no
// `tool.pipe.attr`-reachable in-session equivalent exists) is a FOREIGN
// undoable command from the transform tool's held-run's point of view, and
// `CommandHistory.record`/`recordCoalescing` unconditionally call
// `consolidateOpenRunIfForeign()` before appending it — closing the run
// (`inSession:true` -> consolidated) BEFORE `falloffPacketsEqual` is ever
// consulted. Confirmed by direct inspection of `/api/history`'s
// `mesh.vertex_edit` entry across the select call in case (SELECTION-
// CHANGE) below: `runId:1,inSession:true` before, `runId:0,inSession:false`
// (folded, closed) after — with the mesh untouched by the closure. The
// SAME mechanism protects `vertexMapWeights`'s remaining route
// (`mesh.weightmap.set` is equally a foreign command) — case
// (WEIGHTMAP-EDIT) shows it.
//
// So: no reachable hole. Every derived buffer is either constant, inert
// (fresh-recaptured before any consumer reads it), or gated by the SAME
// pre-existing "foreign command closes the held run" mechanism that has
// nothing to do with `falloffPacketsEqual` — a stronger, more general
// guard than the field-by-field config comparison it was tempting to
// extend. Both cases below are a proof of that closure, not a repro of a
// bug: they assert the run visibly closes AND the already-landed geometry
// does not drift, i.e. there is no window in which a stale derived buffer
// could feed a re-apply.
//
// See drag_helpers for the shared HTTP/event-log plumbing; helpers below
// mirror test_falloff_idle_refire.d's local pattern (each idle-refire test
// file is self-contained).

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv    : to;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

double[3][] dumpVerts() {
    double[3][] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return vs;
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Land ONE committed +X move-arrow gesture against the CURRENT gizmo pivot —
// same idiom as test_falloff_idle_refire.d's moveGestureOnArrow.
void moveGestureOnArrow(long wantCount, double dragPx = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        axisGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(dragPx * ux);
        int yb = ya + cast(int)(dragPx * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "move gesture did not land (undo count never reached "
        ~ wantCount.to!string ~ ")");
}

// The most recent undo entry's (inSession, runId) — used to observe
// CommandHistory's run-consolidation directly rather than inferring it
// from geometry alone.
void mostRecentRunState(out bool inSession, out long runId) {
    auto arr = getJson("/api/history")["undo"].array;
    assert(arr.length > 0, "expected at least one undo entry");
    auto top = arr[$ - 1];
    inSession = ("inSession" in top.object) !is null && top["inSession"].boolean;
    runId     = top["runId"].integer;
}

// ===========================================================================
// (SELECTION-CHANGE) Selection falloff's `selectionWeights` — audit-4 P9
// sibling, task 0791.
//
// A 4-segment cube, Selection falloff (steps=1, shape=smooth — same fixture
// as test_falloff_idle_refire.d's (STEPS) case): select the top 4x4 face
// grid (faces 48..63), land ONE committed Move gesture. Vertex 72 (the
// selected patch's centre) gets a PARTIAL weight from the steps=1 ring-seed
// diffusion (interior, one hop from the boundary) — neither 0 nor 1 — so it
// moves SOME but not all of the gesture's translation, and the landed
// `mesh.vertex_edit` entry is `inSession:true` (an open run).
//
// Idle-clearing the selection changes `FalloffStage.selWeights_` content
// (empty selection -> `selectionWeight()` degenerates to 1.0, the
// "no constraint" contract) without touching a single `FalloffConfig`
// field and without bumping `mesh.mutationVersion` (selection is
// deliberately version-stable — source/mesh.d `noteSelectionChange`). If
// that were the whole story it would reproduce P9's hole. It measures
// otherwise: `/api/select` dispatches `mesh.select`, a FOREIGN undoable
// command from the open run's point of view, and
// `CommandHistory.record`/`recordCoalescing` call
// `consolidateOpenRunIfForeign()` before appending it — closing the run.
// This case shows BOTH halves: the run visibly closes (inSession flips to
// false on the SAME entry) and the already-landed geometry does not drift
// (v72 stays exactly where the gesture put it) — there is no window in
// which a stale `selectionWeights` could feed a re-apply.
// ===========================================================================
unittest {
    postJson("/api/reset?empty=true", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:4 segmentsY:4 segmentsZ:4 radius:0");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63]}`));
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type selection");
    cmd("tool.pipe.attr falloff steps 1");
    cmd("tool.pipe.attr falloff shape smooth");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    // vertex 72 is the exact centre of the selected top face (0,0.5,0)
    // before the gesture (test_falloff_idle_refire.d's (STEPS) case uses
    // the same fixture and vertex).
    auto centreAfterG = dumpVerts()[72];
    assert(!approxEq(centreAfterG[0], 0.0, 1e-3),
        "setup: v72 must take a nonzero PARTIAL move under steps=1 "
        ~ "(diffused, not saturated); got v72.x=" ~ centreAfterG[0].to!string);

    bool sessionBefore; long runBefore;
    mostRecentRunState(sessionBefore, runBefore);
    assert(sessionBefore,
        "setup: the landed move gesture must leave an OPEN in-session run "
        ~ "(inSession:true) for this case to test anything");

    // Idle-clear the selection — the route that changes `selectionWeights`
    // without touching FalloffConfig or mutationVersion.
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
    settle();

    bool sessionAfter; long runAfter;
    mostRecentRunState(sessionAfter, runAfter);
    assert(!sessionAfter,
        "the foreign `mesh.select` append must close the held run "
        ~ "(consolidateOpenRunIfForeign) — got inSession:"
        ~ sessionAfter.to!string ~ " on the entry `mesh.select` was "
        ~ "appended after");

    auto centreAfterSelect = dumpVerts()[72];
    assert(approxEq(centreAfterSelect[0], centreAfterG[0], 1e-4),
        "with the run closed before falloffPacketsEqual is ever consulted, "
        ~ "the already-landed geometry must NOT drift from an idle "
        ~ "selection change: v72.x was " ~ centreAfterG[0].to!string
        ~ ", now " ~ centreAfterSelect[0].to!string);

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (WEIGHTMAP-EDIT) VertexMap falloff's `vertexMapWeights` — same mechanism
// as (SELECTION-CHANGE) above, for the other derived buffer whose only
// non-config route is a real mesh command.
//
// wmA starts zero-filled (mesh.weightmap.create); v0 set to weight 1.0.
// VertexMap falloff with map=wmA moves v0 fully, leaves v1 (weight 0)
// unmoved. Editing wmA's DATA (v1 -> 1.0) via `mesh.weightmap.set`
// WITHOUT touching the `map` attr is the route that changes
// `vertexMapWeights` content outside `FalloffConfig`
// (`mapName` stays "wmA" throughout — contrast test_falloff_idle_refire.d's
// (MAP) case, which switches `mapName` itself and is already covered by
// the config compare). `mesh.weightmap.set` is `commitChange`-backed
// (Material scope) — a real, undoable, foreign command — so it closes the
// held run the same way `mesh.select` does.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    postJson("/api/command", `{"id":"mesh.weightmap.create","params":{"name":"wmA"}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.set","params":{"name":"wmA","vert":0,"weight":1.0}}`);
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map wmA");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto verts = dumpVerts();
    auto v0AfterG = verts[0];   // weight 1.0 under wmA -> moved
    auto v1AfterG = verts[1];   // weight 0.0 under wmA -> unmoved
    assert(!approxEq(v0AfterG[0], -0.5, 1e-3), "v0 (wmA weight=1.0) should have moved");
    assert(approxEq(v1AfterG[0], 0.5, 1e-3),   "v1 (wmA weight=0.0) should not have moved");

    bool sessionBefore; long runBefore;
    mostRecentRunState(sessionBefore, runBefore);
    assert(sessionBefore,
        "setup: the landed move gesture must leave an OPEN in-session run");

    // Idle-edit wmA's DATA (not its name) — v1 -> full weight.
    postJson("/api/command",
        `{"id":"mesh.weightmap.set","params":{"name":"wmA","vert":1,"weight":1.0}}`);
    settle();

    bool sessionAfter; long runAfter;
    mostRecentRunState(sessionAfter, runAfter);
    assert(!sessionAfter,
        "the foreign `mesh.weightmap.set` append must close the held run "
        ~ "(consolidateOpenRunIfForeign) — got inSession:"
        ~ sessionAfter.to!string);

    auto v0AfterEdit = dumpVerts()[0];
    auto v1AfterEdit = dumpVerts()[1];
    assert(approxEq(v0AfterEdit[0], v0AfterG[0], 1e-4)
        && approxEq(v1AfterEdit[0], v1AfterG[0], 1e-4),
        "with the run closed before falloffPacketsEqual is ever consulted, "
        ~ "landed geometry must NOT drift from an idle weight-map data edit; "
        ~ "v0.x " ~ v0AfterG[0].to!string ~ " -> " ~ v0AfterEdit[0].to!string
        ~ ", v1.x " ~ v1AfterG[0].to!string ~ " -> " ~ v1AfterEdit[0].to!string);

    cmd("tool.set move off");
    postJson("/api/reset", "");
}
