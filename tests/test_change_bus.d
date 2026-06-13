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

// Layer-change kind bits (change_bus.LayerChange).
enum uint LAYER_ADDED       = 1 << 0;
enum uint LAYER_REMOVED     = 1 << 1;
enum uint LAYER_REORDERED   = 1 << 2;
enum uint LAYER_RENAMED     = 1 << 3;
enum uint LAYER_VISIBILITY  = 1 << 4;
enum uint LAYER_BACKGROUND  = 1 << 5;
enum uint LAYER_ACTIVE      = 1 << 6;

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
    uint  lastLayerKinds;
    ulong totalPosition, totalPoints, totalPolygons, totalMarks, totalMaterial;
    ulong totalSelVertex, totalSelEdge, totalSelFace;
    ulong totalLayerAdded, totalLayerRemoved, totalLayerReordered,
          totalLayerRenamed, totalLayerVisible,
          totalLayerActive;
    ulong currentTypeChanged;            // selection-types Stage 1
    string lastCurrentType;
}

Changes readChanges() {
    auto j = getJson("/api/changes");
    Changes c;
    c.flushCount     = j["flushCount"].integer;
    c.lastFlushFlags = cast(uint)j["lastFlushFlags"].integer;
    c.lastSelDomains = cast(uint)j["lastSelDomains"].integer;
    c.lastLayerKinds = cast(uint)j["lastLayerKinds"].integer;
    c.totalPosition  = j["totalPosition"].integer;
    c.totalPoints    = j["totalPoints"].integer;
    c.totalPolygons  = j["totalPolygons"].integer;
    c.totalMarks     = j["totalMarks"].integer;
    c.totalMaterial  = j["totalMaterial"].integer;
    c.totalSelVertex = j["totalSelVertex"].integer;
    c.totalSelEdge   = j["totalSelEdge"].integer;
    c.totalSelFace   = j["totalSelFace"].integer;
    c.totalLayerAdded      = j["totalLayerAdded"].integer;
    c.totalLayerRemoved    = j["totalLayerRemoved"].integer;
    c.totalLayerReordered  = j["totalLayerReordered"].integer;
    c.totalLayerRenamed    = j["totalLayerRenamed"].integer;
    c.totalLayerVisible    = j["totalLayerVisible"].integer;
    c.totalLayerActive     = j["totalLayerActive"].integer;
    c.currentTypeChanged   = j["currentTypeChanged"].integer;
    c.lastCurrentType      = j["lastCurrentType"].str;
    return c;
}

// True iff none of the mesh-change per-class counters moved between two reads —
// the anti-spurious-mesh-fire assertion for pure document-state layer ops.
bool meshCountersUnchanged(Changes before, Changes after) {
    return after.totalPosition == before.totalPosition
        && after.totalPoints   == before.totalPoints
        && after.totalPolygons == before.totalPolygons
        && after.totalMarks    == before.totalMarks
        && after.totalMaterial == before.totalMaterial;
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

// A selection-TYPE switch (select.typeFrom — the mode-only command) publishes
// NO selection domain and NO mesh change: a type switch is not selection
// CONTENT. Selection-types Stage 1: it DOES now publish the `currentTypeChanged`
// signal (the `Current(type)` analog deferred from the change-bus Stage-5 work).
// So the refined contract is: type switches that FLIP the current type tick
// currentTypeChanged, while mesh + selection counters stay frozen.
unittest {
    post(baseUrl ~ "/api/reset", "");
    // Seed a selection so there IS something whose "mode" could be (wrongly)
    // construed as changing — then prove the mode switch alone publishes only
    // the current-type signal.
    selectVia("polygons", [0]);
    auto before = settleAfter(readChanges());

    // Three switches; each lands on a type different from the prior current, so
    // each FLIPS the front and ticks currentTypeChanged exactly once.
    cmd("select.typeFrom edge");
    cmd("select.typeFrom vertex");
    cmd("select.typeFrom polygon");
    // A type flip now accumulates a current-type change, so the per-frame flush
    // DOES advance (unlike the pre-Stage-1 inert no-op). settleAfter is valid.
    auto after = settleAfter(before);

    // (1) UNCHANGED contract: no selection domain, no mesh change.
    assert(after.totalSelVertex == before.totalSelVertex
        && after.totalSelEdge  == before.totalSelEdge
        && after.totalSelFace  == before.totalSelFace,
        "a type switch must publish NO selection domain; got "
        ~ "V+" ~ to!string(after.totalSelVertex - before.totalSelVertex)
        ~ " E+" ~ to!string(after.totalSelEdge - before.totalSelEdge)
        ~ " F+" ~ to!string(after.totalSelFace - before.totalSelFace));
    assert(meshCountersUnchanged(before, after),
        "a type switch must publish NO mesh change");

    // (2) NEW contract: the current-type signal ticks on the flips, and the last
    // current type reported is the final switch target (polygon).
    assert(after.currentTypeChanged > before.currentTypeChanged,
        "a front-flipping type switch must tick currentTypeChanged");
    assert(after.lastCurrentType == "polygon",
        "lastCurrentType reflects the final switch target; got "
        ~ after.lastCurrentType);
}

// A redundant type switch (to the type already current) does NOT flip the front,
// so it ticks NOTHING — proves the same-type no-op contract (keys 1/2/3 pressed
// for the mode you are already in do not drop the tool or note a change).
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("select.typeFrom polygon");            // make polygon current
    auto before = settleAfter(readChanges());

    cmd("select.typeFrom polygon");            // already current → no flip
    cmd("select.typeFrom polygon");
    Thread.sleep(dur!"msecs"(300));            // nothing accumulates → no new flush
    auto after = readChanges();

    assert(after.currentTypeChanged == before.currentTypeChanged,
        "a switch to the already-current type must NOT tick currentTypeChanged");
    assert(meshCountersUnchanged(before, after),
        "a redundant type switch must publish nothing");
}

// ===========================================================================
// Layer channel — layerChanged(uint kinds).
// ===========================================================================

// layer.add bumps Added AND Active (add makes the new layer active), once each,
// both bits carried in ONE delivery (coalesce: the command emits Added, the
// switch hook emits ActiveChanged in the same frame).
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());

    cmd("layer.add name:B");
    auto after = settleAfter(before);

    assert(after.totalLayerAdded == before.totalLayerAdded + 1,
        "layer.add must bump Added exactly once");
    assert(after.totalLayerActive == before.totalLayerActive + 1,
        "layer.add makes the new layer active → bump Active once");
    // Both bits coalesce into the same delivery.
    assert((after.lastLayerKinds & (LAYER_ADDED | LAYER_ACTIVE))
        == (LAYER_ADDED | LAYER_ACTIVE),
        "add must deliver Added|Active in one flush; got "
        ~ to!string(after.lastLayerKinds));
}

// layer.delete of the ACTIVE layer bumps Removed AND Active (the active object
// changed). Set up: add B (active), then delete B → active falls back to A.
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("layer.add name:B");                 // B (index 1) is now active
    auto before = settleAfter(readChanges());

    cmd("layer.delete");                      // delete the active layer (B)
    auto after = settleAfter(before);

    assert(after.totalLayerRemoved == before.totalLayerRemoved + 1,
        "delete of active layer must bump Removed");
    assert(after.totalLayerActive == before.totalLayerActive + 1,
        "delete of the ACTIVE layer changes the active object → bump Active");
}

// layer.delete of a NON-active layer bumps Removed but NOT Active (the active
// Layer object is unchanged — only its index may shift). Set up: A,B,C with C
// active; delete B (index 1) — C stays active (same object).
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("layer.add name:B");                 // index 1, active
    cmd("layer.add name:C");                 // index 2, active
    auto before = settleAfter(readChanges());

    cmd("layer.delete index:1");              // delete B (non-active)
    auto after = settleAfter(before);

    assert(after.totalLayerRemoved == before.totalLayerRemoved + 1,
        "delete of non-active layer must bump Removed");
    assert(after.totalLayerActive == before.totalLayerActive,
        "deleting a non-active layer must NOT bump Active (same active object)");
}

// layer.reorder bumps Reordered and does NOT bump Active (identity-preserving:
// the active Layer object is unchanged, only re-pointed by index).
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("layer.add name:B");                 // index 1
    cmd("layer.add name:C");                 // index 2, active
    cmd("layer.select index:0");             // A active again
    auto before = settleAfter(readChanges());

    cmd("layer.reorder from:2 to:0");         // move C to front; A stays active
    auto after = settleAfter(before);

    assert(after.totalLayerReordered == before.totalLayerReordered + 1,
        "reorder must bump Reordered");
    assert(after.totalLayerActive == before.totalLayerActive,
        "a pure reorder is identity-preserving → must NOT bump Active");
}

// layer.select (to a DIFFERENT layer) bumps Active only. It still also refreshes
// the active mesh (MeshChangeAll) — that mesh-counter movement is unchanged
// behaviour and not asserted-against here (the select switches the mesh).
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("layer.add name:B");                 // B active
    cmd("layer.select index:0");             // A active
    auto before = settleAfter(readChanges());

    cmd("layer.select index:1");             // switch to B
    auto after = settleAfter(before);

    assert(after.totalLayerActive == before.totalLayerActive + 1,
        "select to a different layer must bump Active");
    assert(after.totalLayerAdded == before.totalLayerAdded
        && after.totalLayerRemoved == before.totalLayerRemoved
        && after.totalLayerReordered == before.totalLayerReordered,
        "a pure select must bump NO structural layer kind");
    assert((after.lastLayerKinds & LAYER_ACTIVE) != 0,
        "select must deliver ActiveChanged; got " ~ to!string(after.lastLayerKinds));
}

// layer.rename bumps Renamed and does NOT bump ANY mesh-change counter (it is a
// pure document-state change touching no mesh-pending state).
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());

    cmd("layer.rename name:Renamed");         // rename the active layer
    auto after = settleAfter(before);

    assert(after.totalLayerRenamed == before.totalLayerRenamed + 1,
        "rename must bump Renamed");
    assert(meshCountersUnchanged(before, after),
        "rename must NOT bump any mesh-change counter (pure document state)");
    assert(after.totalLayerActive == before.totalLayerActive,
        "rename must NOT bump Active (no active-layer switch)");
}

// layer.setVisible bumps VisibilityChanged, no mesh counters.
unittest {
    post(baseUrl ~ "/api/reset", "");
    auto before = settleAfter(readChanges());

    cmd("layer.setVisible value:false");
    auto after = settleAfter(before);

    assert(after.totalLayerVisible == before.totalLayerVisible + 1,
        "setVisible must bump VisibilityChanged");
    assert(meshCountersUnchanged(before, after),
        "setVisible must NOT bump any mesh-change counter (pure document state)");
}

// Stage 5: the `BackgroundChanged` layer-channel kind is RETIRED. Backgrounding
// a layer is now a pure item-selection event (`layer.select mode:remove`):
// it rides the SEL channel (SelDomain.Item), bumps NO layer-channel counter and
// NO mesh-change counter. This guards that retiring the kind didn't smuggle the
// event onto another channel.
unittest {
    post(baseUrl ~ "/api/reset", "");
    cmd("layer.add name:B");                 // need >1 layer (B active + selected)
    cmd("layer.select index:0 mode:add");    // A added ⇒ both selected, A primary
    auto before = settleAfter(readChanges());

    cmd("layer.select index:1 mode:remove"); // deselect B ⇒ background
    auto after = settleAfter(before);

    // No LAYER-channel counter moves — backgrounding is not a layer-structural
    // change. (Renamed/Visible/Active/Added/Removed/Reordered all flat.)
    assert(after.totalLayerAdded      == before.totalLayerAdded
        && after.totalLayerRemoved    == before.totalLayerRemoved
        && after.totalLayerReordered  == before.totalLayerReordered
        && after.totalLayerRenamed    == before.totalLayerRenamed
        && after.totalLayerVisible    == before.totalLayerVisible
        && after.totalLayerActive     == before.totalLayerActive,
        "backgrounding must NOT bump any LAYER-channel counter (BackgroundChanged retired)");
    assert(meshCountersUnchanged(before, after),
        "backgrounding must NOT bump any mesh-change counter (pure document state)");
}
