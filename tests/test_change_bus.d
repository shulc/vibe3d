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
// Change-class bit values mirror MeshEditScope (source/mesh_edit_delta.d):
//   Position=1, Points=2, Polygons=4, Marks=8, Material=16, Geometry=Points|Polygons=6.

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

void playAndWait(string log) {
    auto r = postJson("/api/play-events", log);
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

    string log = readText("tests/events/acen_local_translate_drag.log");
    playAndWait(log);

    auto after = readChanges();
    assert(after.totalPosition > before.totalPosition,
        "drag must publish Position on the frames geometry moved");
    assert(after.totalPoints == before.totalPoints
        && after.totalPolygons == before.totalPolygons,
        "a transform drag must NEVER publish Geometry (it moves positions in "
        ~ "place, no topology change)");
}
