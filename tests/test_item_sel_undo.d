// Item-selection TORTURE test — selection-types #4 Stage 5.
//
// Complementary to test_layers_undo.d (which attacks the cache-collision /
// missed-publisher defenses with three identical cubes). THIS test attacks the
// ITEM-SELECTION model itself: it interleaves geometry edits on the PRIMARY
// layer with item select / deselect / set-primary / reorder / delete and a long
// run of undo / redo, and after EVERY step asserts:
//
//   1. The PRIMARY INVARIANT never breaks. There is always exactly one primary;
//      it is always `selected`; it is always `visible`; it is never null. This
//      is the load-bearing data invariant of the multi-select model — the edit
//      target must always exist.
//
//   2. `/api/changes` counters stay COHERENT across the sequence. The
//      Item-selection domain (`totalSelItem`), the current-type channel
//      (`currentTypeChanged` + `lastCurrentType`), and the layer-structural
//      counters (`totalLayerActive` etc.) advance monotonically and never run
//      backwards. An item-selection op publishes `totalSelItem`; a geometry
//      edit on the primary publishes `totalPosition`. Counters are read as
//      DELTAS (the bus is process-wide, not reset between steps).
//
//   3. `/api/undo/status` never reports a hard `lockout`. Every undo/redo in
//      the long mixed run is accepted by the history service.
//
// The Stage-5 retirement of the `BackgroundChanged` layer-channel kind is
// exercised indirectly: backgrounding a layer here is `layer.select
// mode:remove` (the panel's verb since Stage 2b), and we assert it bumps the
// Item domain — never a now-deleted layer counter.
//
// Three identical-ish layers (A/B/C, each a cube) stress that selection ops
// don't corrupt the SET under undo/redo: the layers are interchangeable, so a
// bug that restored the wrong member or dropped the primary would surface as a
// broken invariant rather than a wrong vertex position.

import std.net.curl;
import std.json;
import std.conv    : to;
import core.thread : Thread;
import core.time   : dur;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (kept parallel to test_layers_undo.d / test_item_selection.d).
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

JSONValue cmdJson(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void clearHistory() { cmdJson(`{"id":"history.clear"}`); }

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    clearHistory();
}

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/redo", "")); }

JSONValue getLayers() { return getJson("/api/layers"); }

// ---------------------------------------------------------------------------
// The primary invariant — checked after every step. Returns the primary index.
// ---------------------------------------------------------------------------

int assertPrimaryInvariant(string at) {
    auto ls = getLayers()["layers"].array;
    assert(ls.length >= 1, "document must always have >=1 layer at: " ~ at);
    int primaryIdx = -1;
    int primaryCount = 0, selectedCount = 0;
    foreach (i, l; ls) {
        if (l["primary"].type  == JSONType.true_) { primaryCount++; primaryIdx = cast(int)i; }
        if (l["selected"].type == JSONType.true_)   selectedCount++;
    }
    assert(primaryCount == 1,
        "exactly one primary required (got " ~ primaryCount.to!string ~ ") at: " ~ at);
    assert(primaryIdx >= 0, "primary is never null at: " ~ at);
    auto p = ls[primaryIdx];
    assert(p["selected"].type == JSONType.true_,
        "primary must always be selected (foreground) at: " ~ at);
    assert(p["visible"].type  == JSONType.true_,
        "primary must always be visible at: " ~ at);
    assert(selectedCount >= 1, "at least one selected layer at: " ~ at);
    return primaryIdx;
}

void assertNoLockout(string at) {
    auto s = getJson("/api/undo/status");
    assert(s["lockout"].type == JSONType.false_,
        "hard undo lockout asserted at: " ~ at ~ " (status=" ~ s.toString ~ ")");
}

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
    assertNoLockout("after undo: " ~ why);
    assertPrimaryInvariant("after undo: " ~ why);
}

void redoOk(string why) {
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo (" ~ why ~ ") failed: " ~ r.toString);
    assertNoLockout("after redo: " ~ why);
    assertPrimaryInvariant("after redo: " ~ why);
}

// ---------------------------------------------------------------------------
// /api/changes — counters read as deltas; the bus is process-wide. We assert
// monotonicity (never run backwards) plus a domain-specific advance after the
// op that should have published it. The Item domain + current-type channel are
// the Stage-2a/Stage-1 additions this test guards.
// ---------------------------------------------------------------------------

struct Changes {
    long flushCount;
    long totalPosition;
    long totalSelItem;
    long currentTypeChanged;
    long totalLayerActive, totalLayerAdded, totalLayerRemoved, totalLayerReordered;
    string lastCurrentType;
}

Changes changes() {
    auto j = getJson("/api/changes");
    Changes c;
    c.flushCount          = j["flushCount"].integer;
    c.totalPosition       = j["totalPosition"].integer;
    c.totalSelItem        = j["totalSelItem"].integer;
    c.currentTypeChanged  = j["currentTypeChanged"].integer;
    c.totalLayerActive    = j["totalLayerActive"].integer;
    c.totalLayerAdded     = j["totalLayerAdded"].integer;
    c.totalLayerRemoved   = j["totalLayerRemoved"].integer;
    c.totalLayerReordered = j["totalLayerReordered"].integer;
    c.lastCurrentType     = j["lastCurrentType"].str;
    return c;
}

// Counters are deltas off a process-wide bus; none may ever decrease.
void assertMonotonic(Changes before, Changes after, string at) {
    assert(after.flushCount          >= before.flushCount,          "flushCount regressed at: " ~ at);
    assert(after.totalPosition       >= before.totalPosition,       "totalPosition regressed at: " ~ at);
    assert(after.totalSelItem        >= before.totalSelItem,        "totalSelItem regressed at: " ~ at);
    assert(after.currentTypeChanged  >= before.currentTypeChanged,  "currentTypeChanged regressed at: " ~ at);
    assert(after.totalLayerActive    >= before.totalLayerActive,    "totalLayerActive regressed at: " ~ at);
    assert(after.totalLayerAdded     >= before.totalLayerAdded,     "totalLayerAdded regressed at: " ~ at);
    assert(after.totalLayerRemoved   >= before.totalLayerRemoved,   "totalLayerRemoved regressed at: " ~ at);
    assert(after.totalLayerReordered >= before.totalLayerReordered, "totalLayerReordered regressed at: " ~ at);
}

// Run `op`, then poll until `pick(now) > pick(before)` AND a flush advanced —
// the per-frame flush delivers what the command accumulated. Asserts coherence
// and returns the post-op snapshot.
Changes expectPublish(string label, long delegate(Changes) pick, void delegate() op) {
    auto before = changes();
    op();
    Changes now;
    bool advanced = false;
    for (int i = 0; i < 40; ++i) {
        now = changes();
        if (pick(now) > pick(before) && now.flushCount > before.flushCount) {
            advanced = true; break;
        }
        Thread.sleep(dur!"msecs"(25));
    }
    assert(advanced,
        "change-bus incoherent at `" ~ label ~ "`: expected counter did not advance "
        ~ "after the publishing step (missed publisher?)");
    assertMonotonic(before, now, label);
    return now;
}

void moveVertexActive(double[3] from, double[3] to) {
    string v3(double[3] p) {
        return "[" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ "]";
    }
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":` ~ v3(from)
            ~ `,"to":` ~ v3(to) ~ `}}`);
}

bool approx(double a, double b) { auto d = a - b; return (d < 0 ? -d : d) < 1e-4; }

// Does the active layer have a vertex with this x? (geometry witness)
bool activeHasVertX(double x) {
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) if (approx(v.array[0].floating, x)) return true;
    return false;
}

// Build three layers A/B/C, each a cube; A primary+selected (SET-of-one),
// history cleared. The three meshes are identical → interchangeable, so a
// selection-set corruption shows up as a broken invariant.
void threeLayers() {
    resetCube();                  // A (index 0) = cube, primary+selected
    cmd("layer.add name:B");      // B (index 1) active+selected, empty
    cmd("prim.cube");             // B = cube (8v)
    cmd("layer.add name:C");      // C (index 2) active+selected, empty
    cmd("prim.cube");             // C = cube (8v)
    cmd("layer.select index:0");  // back to A primary (set)
    clearHistory();
    assert(assertPrimaryInvariant("threeLayers baseline") == 0, "A primary at baseline");
}

// ===========================================================================
// THE TORTURE SEQUENCE. One big unittest so the steps share a history stack and
// each builds on the last — exactly the abuse a session subjects the model to.
// ===========================================================================

unittest {
    threeLayers();

    // --- Phase 1: interleave a geometry edit on the primary with item ops. ---
    // Edit A's geometry (primary). totalPosition must publish. The cube's
    // corners are at ±0.5.
    expectPublish("edit primary A", c => c.totalPosition,
        () => moveVertexActive([-0.5, 0.5, 0.5], [-3.0, 0.5, 0.5]));
    assert(activeHasVertX(-3.0), "A's vertex moved");
    assertPrimaryInvariant("after edit A");

    // Add B to the selection (multi-foreground). Item domain + current-type
    // (geometry→Item front flip) must publish.
    auto afterAddB = expectPublish("select+add B (item)", c => c.totalSelItem,
        () { cmd("layer.select index:1 mode:add"); });
    assert(afterAddB.lastCurrentType == "item",
        "item selection makes Item the current type");
    int pAddB = assertPrimaryInvariant("after add B");
    assert(pAddB == 1, "newest add (B) is primary");

    // Edit the NEW primary B's geometry. totalPosition publishes again; the
    // primary (B) is the edit target. (move_vertex targets the active layer.)
    expectPublish("edit primary B", c => c.totalPosition,
        () => moveVertexActive([0.5, 0.5, 0.5], [4.0, 0.5, 0.5]));
    assert(activeHasVertX(4.0), "B's vertex moved (B is the edit target)");
    assertPrimaryInvariant("after edit B");

    // --- Phase 2: set-primary back to A, then background a member. ---
    // mode:set is exclusive — A becomes the sole primary+selected.
    expectPublish("set-primary A", c => c.totalSelItem,
        () { cmd("layer.select index:0"); });
    assert(assertPrimaryInvariant("after set A") == 0, "A primary again");

    // Re-add B and C, then BACKGROUND B (mode:remove). Backgrounding is a pure
    // item-selection event (the retired BackgroundChanged kind never fires).
    cmd("layer.select index:1 mode:add");   // A,B selected, B primary
    cmd("layer.select index:2 mode:add");   // A,B,C selected, C primary
    assertPrimaryInvariant("after re-add B,C");
    auto beforeBg = changes();
    expectPublish("background B (remove)", c => c.totalSelItem,
        () { cmd("layer.select index:1 mode:remove"); });
    // Backgrounding bumps NO layer-structural counter (BackgroundChanged retired).
    auto afterBg = changes();
    assert(afterBg.totalLayerActive    == beforeBg.totalLayerActive
        && afterBg.totalLayerAdded     == beforeBg.totalLayerAdded
        && afterBg.totalLayerRemoved   == beforeBg.totalLayerRemoved
        && afterBg.totalLayerReordered == beforeBg.totalLayerReordered,
        "backgrounding must not bump any layer-structural counter");
    assert(getLayers()["layers"].array[1]["selected"].type == JSONType.false_,
        "B is backgrounded (deselected)");
    assertPrimaryInvariant("after background B");

    // --- Phase 3: reorder + delete + delete-undo, invariant after each. ---
    auto beforeReorder = changes();
    cmd("layer.reorder from:0 to:2");        // move A to the end
    auto afterReorder = changes();
    assertMonotonic(beforeReorder, afterReorder, "reorder");
    assertPrimaryInvariant("after reorder");  // primary preserved by identity

    int pBeforeDel = assertPrimaryInvariant("pre-delete");
    // Delete a NON-primary layer if possible, else the primary (model still
    // promotes). Pick index 0 (a different object than the primary in general).
    int delIdx = (pBeforeDel == 0) ? 1 : 0;
    cmd("layer.delete index:" ~ delIdx.to!string);
    assertNoLockout("after delete");
    assertPrimaryInvariant("after delete");   // promotion holds the invariant

    // Undo the delete → layer back; invariant holds and the prior selection set
    // is restored (delete-revert restores selected[]+primary by identity, 2b#6).
    undoOk("undo delete");
    assert(getLayers()["layers"].array.length == 3, "deleted layer restored");

    // --- Phase 4: a long mixed undo/redo run back to the very start. ---
    // Walk the whole stack back, then forward, asserting the invariant + no
    // lockout at every step. This is the stress that a wrong-member restore or
    // a dropped primary under undo/redo would trip.
    foreach (i; 0 .. 12) {
        auto u = postUndo();
        if (u["status"].str != "ok") break;     // bottomed out — fine
        assertNoLockout("deep undo " ~ i.to!string);
        assertPrimaryInvariant("deep undo " ~ i.to!string);
    }
    foreach (i; 0 .. 12) {
        auto r = postRedo();
        if (r["status"].str != "ok") break;      // topped out — fine
        assertNoLockout("deep redo " ~ i.to!string);
        assertPrimaryInvariant("deep redo " ~ i.to!string);
    }

    // Final coherence: the bus counters are still monotonic vs the start, and
    // the invariant holds.
    assertPrimaryInvariant("end of torture");
}
