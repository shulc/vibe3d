// Change-notification bus — Stage 1 publisher coverage (end-to-end, via HTTP).
//
// Drives the live app through /api/command, /api/play-events and /api/reset and
// reads the bus debug counters at /api/changes (test-only endpoint) to assert
// that each mutation publishes the CORRECT change classes. Counters are read as
// DELTAS across a step (the runner resets app STATE — not the bus — between test
// binaries, so absolute totals are meaningless across tests; within this file we
// snapshot-before / read-after and diff).
//
// Cases (per doc/change_notification_bus_plan.md Stage 1):
//   - mesh.move_vertex          → Position published
//   - mesh.subdivide            → Points|Polygons (Geometry) published
//   - undo of the subdivide     → same class re-published (tracker / op replay)
//   - redo of the subdivide     → same class re-published
//   - /api/reset                → All bits (Position|Points|Polygons|Marks|Material)
//   - a recorded transform drag → Position flushes > 0 with NO Geometry bits
//
// Stage 5 (selection publisher) cases appended below:
//   - interactive vertex-select event log → Vertex domain ticks
//   - /api/select polygons / edges        → Face / Edge domain ticks
//   - select.more on an edge loop         → Edge domain ticks
//   - undo of an interactive selection    → domain re-published (UI-undo class)
//   - select.typeFrom (EditMode switch)   → publishes NO selection domain
//
// Change-class bit values mirror MeshEditScope (source/mesh_edit_delta.d):
//   Position=1, Points=2, Polygons=4, Marks=8, Material=16, Geometry=Points|Polygons=6.
// Selection-domain bit values mirror change_bus.SelDomain:
//   Vertex=1, Edge=2, Face=4.

import std.net.curl;
import std.json;
import std.conv    : to;
import std.string  : strip;
import std.file    : readText;
import core.thread : Thread;
import core.time   : dur;

void main() {}

string baseUrl = "http://localhost:8080";

enum uint POSITION = 1;
enum uint POINTS   = 2;
enum uint POLYGONS = 4;
enum uint MARKS    = 8;
enum uint MATERIAL = 16;
enum uint GEOMETRY = POINTS | POLYGONS;
enum uint ALLBITS  = POSITION | POINTS | POLYGONS | MARKS | MATERIAL;

// Selection-domain bits (change_bus.SelDomain).
enum uint SEL_VERTEX = 1;
enum uint SEL_EDGE   = 2;
enum uint SEL_FACE   = 4;

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

// Snapshot of the bus counters at one instant.
struct Changes {
    ulong flushCount;
    uint  lastFlushFlags;
    uint  lastSelDomains;
    ulong totalPosition, totalPoints, totalPolygons, totalMarks, totalMaterial;
    ulong totalSelVertex, totalSelEdge, totalSelFace;
}

Changes readChanges() {
    auto j = getJson("/api/changes");
    Changes c;
    c.flushCount     = j["flushCount"].integer;
    c.lastFlushFlags = cast(uint)j["lastFlushFlags"].integer;
    c.lastSelDomains = cast(uint)j["lastSelDomains"].integer;
    c.totalPosition  = j["totalPosition"].integer;
    c.totalPoints    = j["totalPoints"].integer;
    c.totalPolygons  = j["totalPolygons"].integer;
    c.totalMarks     = j["totalMarks"].integer;
    c.totalMaterial  = j["totalMaterial"].integer;
    c.totalSelVertex = j["totalSelVertex"].integer;
    c.totalSelEdge   = j["totalSelEdge"].integer;
    c.totalSelFace   = j["totalSelFace"].integer;
    return c;
}

// Wait until at least one more flush has been delivered since `before`, so the
// per-frame flush has drained whatever the just-issued command accumulated.
// (Commands accumulate on the mesh; the main-loop flush delivers next frame.)
Changes settleAfter(Changes before) {
    foreach (i; 0 .. 60) {                 // up to ~3s
        Thread.sleep(dur!"msecs"(50));
        auto now = readChanges();
        if (now.flushCount > before.flushCount) return now;
    }
    return readChanges();
}

// Replay an event log given its FILE PATH (reads the contents and posts them).
void playAndWait(string logPath) {
    auto r = postJson("/api/play-events", readText(logPath));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 400) {                // up to 40s headroom
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // Post-playback settle: /api/play-events/status flips to finished once events
    // are POSTED to the SDL queue, not processed; give the main loop a few frames
    // to dispatch + flush the drag's accumulated Position notes.
    Thread.sleep(dur!"msecs"(200));
}

// mesh.move_vertex → Position published, no Geometry, no Marks.
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());   // drain the reset's own flush

    cmd("mesh.move_vertex from:{0.5,0.5,0.5} to:{0.75,0.6,0.55}");
    auto after = settleAfter(before);

    assert(after.totalPosition > before.totalPosition,
        "move_vertex must publish Position");
    assert(after.totalPoints == before.totalPoints
        && after.totalPolygons == before.totalPolygons,
        "move_vertex must NOT publish Geometry");
    assert((after.lastFlushFlags & POSITION) != 0,
        "last flush should carry Position; got " ~ to!string(after.lastFlushFlags));
    assert((after.lastFlushFlags & GEOMETRY) == 0,
        "last flush must not carry Geometry; got " ~ to!string(after.lastFlushFlags));
}

// mesh.subdivide → Points|Polygons (Geometry); undo + redo re-publish the class.
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("history.clear");
    auto before = settleAfter(readChanges());

    cmd("mesh.subdivide");
    auto afterSub = settleAfter(before);
    assert(afterSub.totalPoints   > before.totalPoints,
        "subdivide must publish Points");
    assert(afterSub.totalPolygons > before.totalPolygons,
        "subdivide must publish Polygons");

    // Undo → the class is re-published (snapshot restore emits All ⊇ Geometry).
    postJson("/api/undo", "");
    auto afterUndo = settleAfter(afterSub);
    assert(afterUndo.totalPoints   > afterSub.totalPoints
        && afterUndo.totalPolygons > afterSub.totalPolygons,
        "undo of subdivide must re-publish Points|Polygons");

    // Redo → same.
    postJson("/api/redo", "");
    auto afterRedo = settleAfter(afterUndo);
    assert(afterRedo.totalPoints   > afterUndo.totalPoints
        && afterRedo.totalPolygons > afterUndo.totalPolygons,
        "redo of subdivide must re-publish Points|Polygons");
}

// /api/reset → All bits (Position|Points|Polygons|Marks|Material).
unittest {
    post(baseUrl ~ "/api/reset", "");          // get into a known state
    auto before = settleAfter(readChanges());

    post(baseUrl ~ "/api/reset", "");          // the reset under test
    auto after = settleAfter(before);

    assert((after.lastFlushFlags & ALLBITS) == ALLBITS,
        "reset must publish the All mask; got " ~ to!string(after.lastFlushFlags));
    assert(after.totalPosition > before.totalPosition
        && after.totalPoints   > before.totalPoints
        && after.totalPolygons > before.totalPolygons
        && after.totalMarks    > before.totalMarks
        && after.totalMaterial > before.totalMaterial,
        "reset must tick every per-class total");
}

// A recorded interactive transform drag (replayed through the full SDL/tool
// dispatch) → Position flushes > 0, NO Geometry bits ever delivered.
unittest {
    // Reproduce the capture's scene: empty → segments-2 cube → asymmetric 3-poly
    // selection → move tool → ACEN.Local (matches the captured drag's pipe state).
    postJson("/api/reset?empty=true", "");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[11,12,13]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set move on");
    cmd("actr.local");

    auto before = settleAfter(readChanges());

    playAndWait("tests/events/acen_local_translate_drag.log");

    auto after = readChanges();
    assert(after.totalPosition > before.totalPosition,
        "drag must publish Position on the frames geometry moved");
    assert(after.totalPoints == before.totalPoints
        && after.totalPolygons == before.totalPolygons,
        "a transform drag must NEVER publish Geometry (it moves positions in "
        ~ "place, no topology change)");
}

// ===========================================================================
// Stage 5 — selection publisher (selectionChanged(domain)).
// ===========================================================================

// Drive a synchronous /api/select and assert success.
void selectVia(string mode, int[] indices) {
    import std.algorithm : map;
    import std.array      : join;
    import std.conv       : text;
    string idxs = indices.length
        ? indices.map!(i => text(i)).join(",")
        : "";
    auto j = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":[` ~ idxs ~ `]}`);
    assert(j["status"].str == "ok", "select failed: " ~ j.toString);
}

// An interactive vertex-select event log publishes the Vertex domain (and ONLY
// Vertex — the recorded log is a points-mode click drag that touches no edge or
// face selection).
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());

    playAndWait("tests/events/selection_points.log");
    auto after = settleAfter(before);

    assert(after.totalSelVertex > before.totalSelVertex,
        "interactive points-mode select must publish the Vertex domain");
    assert(after.totalSelEdge == before.totalSelEdge,
        "a points-mode select must NOT publish the Edge domain");
    assert((after.lastSelDomains & SEL_VERTEX) != 0
        || after.totalSelVertex > before.totalSelVertex,
        "Vertex domain delivered");
}

// /api/select polygons → Face domain; /api/select edges → Edge domain. Each
// mode routes through its own setXSelectedFrom, which publishes only its bit.
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());

    selectVia("polygons", [0, 1, 2]);
    auto afterFace = settleAfter(before);
    assert(afterFace.totalSelFace > before.totalSelFace,
        "polygon select must publish the Face domain");
    assert(afterFace.totalSelVertex == before.totalSelVertex,
        "polygon select must NOT publish the Vertex domain");

    selectVia("edges", [0, 1]);
    auto afterEdge = settleAfter(afterFace);
    assert(afterEdge.totalSelEdge > afterFace.totalSelEdge,
        "edge select must publish the Edge domain");
}

// A topology-select alias (select.loop) that GROWS the selection publishes the
// correct domain. Edge mode + a single seed edge → select.loop adds the rest of
// the loop → the Edge domain ticks.
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("history.clear");
    cmd("select.typeFrom edge");
    selectVia("edges", [0]);                // seed one edge
    auto before = settleAfter(readChanges());

    cmd("select.loop");                     // grow the seed into a full loop
    auto after = settleAfter(before);
    assert(after.totalSelEdge > before.totalSelEdge,
        "select.loop in edge mode must publish the Edge domain");
}

// Undo of an interactive selection (UI-undo class: MeshSelectionEdit) re-applies
// the prior selection through setXSelectedFrom → the domain is re-published.
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("history.clear");

    // First interactive selection lands a MeshSelectionEdit on the undo stack.
    playAndWait("tests/events/selection_points.log");
    // A second, ADDING selection so the undo actually changes the marks back
    // (a no-op restore would be compare-before-set away to nothing).
    auto mid = settleAfter(readChanges());
    playAndWait("tests/events/selection_add.log");
    auto before = settleAfter(mid);

    postJson("/api/undo", "");
    auto after = settleAfter(before);
    assert(after.totalSelVertex > before.totalSelVertex,
        "undo of a vertex selection must re-publish the Vertex domain");
}

// An EditMode switch (select.typeFrom — the mode-only command) publishes NO
// selection domain: mode is not selection content. (The type-current analog is
// deferred to a later selection-type generalization survey item.)
unittest {
    post(baseUrl ~ "/api/reset", "");
    // Seed a selection so there IS something whose "mode" could be (wrongly)
    // construed as changing — then prove the mode switch alone is inert.
    selectVia("polygons", [0]);
    auto before = settleAfter(readChanges());

    cmd("select.typeFrom edge");
    cmd("select.typeFrom vertex");
    cmd("select.typeFrom polygon");
    // A mode switch accumulates nothing, so the per-frame flush stays a no-op
    // (flushCount won't advance) — settleAfter would just spin to its timeout.
    // A short fixed settle is enough to prove the counters did NOT move.
    Thread.sleep(dur!"msecs"(300));
    auto after = readChanges();

    assert(after.totalSelVertex == before.totalSelVertex
        && after.totalSelEdge  == before.totalSelEdge
        && after.totalSelFace  == before.totalSelFace,
        "an EditMode switch must publish NO selection domain; got "
        ~ "V+" ~ to!string(after.totalSelVertex - before.totalSelVertex)
        ~ " E+" ~ to!string(after.totalSelEdge - before.totalSelEdge)
        ~ " F+" ~ to!string(after.totalSelFace - before.totalSelFace));
}
