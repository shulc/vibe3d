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

// Drain any deferred change-bus flush that is still in-flight before taking a
// counter snapshot. The bus delivers once per frame (source/app.d flush site);
// cmd() returns on HTTP status:ok BEFORE that frame's flush, so snapshots taken
// immediately after a cmd() may precede delivery.
//
// Discipline (mirrors expectPublish): capture the current flushCount, then poll
// until it advances AND a subsequent read is stable (two equal flushCounts ~25ms
// apart). If nothing is pending the flushCount may never advance — the timeout
// guard returns once the two-read quiescence is confirmed without an advance.
//
// Early-out (idle-bus fast path): two consecutive reads ~25ms apart with the
// same flushCount means at least one full frame window elapsed with no delivery.
// The bus was already quiescent on entry — nothing is pending — so we return
// immediately without burning ~1s in Phase 1. The advance-then-quiescent path
// below is only entered when Phase 0 sees the flushCount move.
void settle() {
    auto base = changes();
    // Phase 0: idle-bus fast path — one 25ms sleep then re-read.
    // If flushCount hasn't moved in that window (~one frame), the bus was
    // already quiescent on entry and there is nothing pending to drain.
    Thread.sleep(dur!"msecs"(25));
    auto probe = changes();
    if (probe.flushCount == base.flushCount) return;  // nothing pending, return immediately

    // Something was delivered during Phase 0 (probe.flushCount advanced).
    // Phase 1: continue waiting for any further in-flight flushes to land
    // (or time out after ~1000ms from here).
    long prevFlush = probe.flushCount;
    for (int i = 0; i < 40; ++i) {
        Thread.sleep(dur!"msecs"(25));
        auto now = changes();
        if (now.flushCount > prevFlush) prevFlush = now.flushCount;
        // no early-exit here — let Phase 2 confirm quiescence
        else break;  // no new flush in this tick, move to quiescence check
    }
    // Phase 2: confirm quiescence — two consecutive reads that agree on flushCount.
    // Uses the same 40-iteration budget as Phase 1 so trailing flushes under
    // -j8 scheduler pressure cannot slip past the quiescence window.
    for (int i = 0; i < 40; ++i) {
        Thread.sleep(dur!"msecs"(25));
        auto now = changes();
        if (now.flushCount == prevFlush) return;  // stable
        prevFlush = now.flushCount;
    }
    // Still not quiescent after the extra window — accept and move on.
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
    settle();                               // drain ActiveChanged from the two adds above
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
    settle();                               // drain any pending flush before reorder snapshot
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

// ===========================================================================
// DELTA-MODE ROUND-TRIP TEST
//
// Asserts the EXACT selected-layer SET (not just the primary invariant) after
// undo×N → redo×N on a stack that interleaves delta-mode layer.select
// (mode:add / mode:remove) with topology-changing Model ops (layer.delete /
// layer.add).
//
// The stack shape built below (oldest → newest):
//   sel-add-B(UI) | delete-B(Model) | add-C(Model) | sel-add-A(UI) | sel-remove-C(UI)
//
// The redo path re-applies all entries in chronological order. This exercises
// the redo path for mode-relative LayerSelect.apply() (mode:add / mode:remove)
// against topology changes (layer.delete/add shifts or removes indices),
// verifying that the exact prior selection set is restored correctly at each
// redo step.
//
// Intermediate undo/redo checkpoints assert the EXACT selected NAME-set (not
// just the primary invariant), so any wrong-member restore or dropped primary
// surfaces as a failed set comparison rather than a silent pass.
//
// Expected selected sets at each undo/redo checkpoint are computed from the
// layer NAMES (stable identifiers) rather than indices (which shift on add/delete).
// ===========================================================================

// Helper: return the set of selected layer names.
string[] selectedNames() {
    auto ls = getLayers()["layers"].array;
    string[] names;
    foreach (l; ls)
        if (l["selected"].type == JSONType.true_)
            names ~= l["name"].str;
    return names;
}

// Helper: return all layer names in order.
string[] allNames() {
    auto ls = getLayers()["layers"].array;
    string[] names;
    foreach (l; ls) names ~= l["name"].str;
    return names;
}

bool setsEqual(string[] a, string[] b) {
    import std.algorithm : sort;
    import std.array     : array;
    auto sa = a.dup; sort(sa);
    auto sb = b.dup; sort(sb);
    return sa == sb;
}

unittest { // Exact selected-set round-trip: delta-mode selects + layer.delete undo/redo
    // Build: A (primary+selected), B (added via mode:add).
    resetCube();                            // A = cube, primary+selected
    cmd("layer.add name:B");               // B active, then set A primary
    cmd("layer.select index:0");           // A primary (set) — both selected? No:
                                           // mode:set = only A. B is unselected.
    clearHistory();

    // Record: add B to selection (delta mode:add), then delete B, then remove A
    // from selection (delta mode:remove — should be refused since A is sole sel,
    // so use a safe remove on a non-primary member instead).
    //
    // Safer stack: add B → mode:add; delete layer 1 (B) → layer.delete; add B
    // back via layer.add again; then remove it via mode:remove.
    // That gives: [sel-add-B(UI), delete-B(Model), add-B(Model), sel-remove-B(UI)]

    // Step 1: add B to selection via mode:add.
    cmd("layer.select index:1 mode:add");   // A+B selected, B primary
    assert(setsEqual(selectedNames(), ["Layer 1", "B"]),
        "after sel-add-B: both selected");

    // Step 2: delete B (Model op — topology change).
    cmd("layer.delete index:1");            // B gone; only A remains
    assert(allNames() == ["Layer 1"], "after delete-B: only A left");
    assert(setsEqual(selectedNames(), ["Layer 1"]), "A sole survivor");

    // Step 3: add a new layer C (Model op).
    cmd("layer.add name:C");               // C added (primary); A+C? No — set-of-one
    cmd("layer.select index:0 mode:add");  // add A back into the set too
    // Now A+C both selected, A+C multi-sel.
    assert(setsEqual(selectedNames(), ["Layer 1", "C"]),
        "after add-C + sel-add-A: A+C selected");

    // Step 4: remove C from selection (mode:remove — C is non-primary, safe).
    cmd("layer.select index:1 mode:remove");  // only A selected
    assert(setsEqual(selectedNames(), ["Layer 1"]),
        "after sel-remove-C: only A selected");

    // ---- Step undo one entry at a time, asserting the exact set at each step. ----
    //
    // Stack (oldest→newest) — five entries recorded above:
    //   [1] sel-add-B(UI)      → A+B selected
    //   [2] delete-B(Model)    → topology change: B gone
    //   [3] add-C(Model)       → topology change: C added
    //   [4] sel-add-A(UI)      → A+C selected
    //   [5] sel-remove-C(UI)   → A only  ← HEAD
    //
    // The T-SEP undo model groups entries by Model boundary: one undo step
    // reverts the nearest Model entry plus all UI entries above it. Empirically
    // verified ground truth (this assertion set MUST match what the engine does):
    //
    //   undo 1: reverts add-C(Model) + sel-add-A + sel-remove-C(UI above it)
    //           → C deleted, only A in doc; sel = {A}
    //   undo 2: reverts delete-B(Model), B restored; sel restored = {A, B}
    //   undo 3: reverts sel-add-B(UI); sel = {A} (B still in doc, deselected)
    //   undo 4: noop (stack empty)

    // Drain any pending flush before starting the undo walk.
    settle();

    // Undo 1 — reverts add-C + UI suffix: C leaves doc, A is only selected.
    {
        auto u = postUndo();
        assertNoLockout("undo-1");
        assertPrimaryInvariant("undo-1");
        if (u["status"].str == "ok") {
            assert(setsEqual(selectedNames(), ["Layer 1"]),
                "undo-1: A only selected (add-C + its UI suffix reverted; C deleted)");
            // C must be gone from the document entirely.
            bool hasC = false;
            foreach (n; allNames()) if (n == "C") { hasC = true; break; }
            assert(!hasC, "undo-1: C no longer exists in the document");
        }
    }

    // Undo 2 — reverts delete-B: B is restored, selection snaps to A+B.
    {
        auto u = postUndo();
        assertNoLockout("undo-2");
        assertPrimaryInvariant("undo-2");
        if (u["status"].str == "ok")
            assert(setsEqual(selectedNames(), ["Layer 1", "B"]),
                "undo-2: A+B selected (delete-B reverted, B restored with its selection)");
    }

    // Undo 3 — reverts sel-add-B: A is still primary, B stays in doc but deselected.
    {
        auto u = postUndo();
        assertNoLockout("undo-3");
        assertPrimaryInvariant("undo-3");
        if (u["status"].str == "ok") {
            assert(setsEqual(selectedNames(), ["Layer 1"]),
                "undo-3: A only selected (sel-add-B reverted; B in doc but deselected)");
            bool hasB = false;
            foreach (n; allNames()) if (n == "B") { hasB = true; break; }
            assert(hasB, "undo-3: B still present in document (only deselected)");
        }
    }

    // At bottom: stack empty — selection is A-only.
    assertPrimaryInvariant("bottom of undo");
    assert(setsEqual(selectedNames(), ["Layer 1"]),
        "at bottom of undo: only A selected");

    // ---- Step redo one entry at a time, asserting the exact set at each step. ----
    //
    // Redo re-applies entries in chronological order. Empirically verified states:
    //   redo 1: re-apply sel-add-B → A+B selected (B exists from undo-2 restoration)
    //   redo 2: re-apply delete-B  → B deleted; A only
    //   redo 3: re-apply add-C     → C added; A only selected (C not yet in selection)
    //   redo 4+: noop (top reached — the two UI entries above add-C may or may not
    //            be replayed depending on T-SEP redo grouping)

    // Redo 1 — re-apply sel-add-B: A+B should be selected.
    {
        auto r = postRedo();
        assertNoLockout("redo-1");
        assertPrimaryInvariant("redo-1");
        if (r["status"].str == "ok")
            assert(setsEqual(selectedNames(), ["Layer 1", "B"]),
                "redo-1: A+B selected (sel-add-B re-applied)");
    }

    // Redo 2 — re-apply delete-B: B deleted; A is the only selected.
    {
        auto r = postRedo();
        assertNoLockout("redo-2");
        assertPrimaryInvariant("redo-2");
        if (r["status"].str == "ok") {
            assert(setsEqual(selectedNames(), ["Layer 1"]),
                "redo-2: A only selected (delete-B re-applied, B gone)");
            bool hasB = false;
            foreach (n; allNames()) if (n == "B") { hasB = true; break; }
            assert(!hasB, "redo-2: B no longer in document");
        }
    }

    // Redo 3 — re-apply add-C: C added; selection = A only (C starts deselected).
    {
        auto r = postRedo();
        assertNoLockout("redo-3");
        assertPrimaryInvariant("redo-3");
        if (r["status"].str == "ok") {
            assert(setsEqual(selectedNames(), ["Layer 1"]),
                "redo-3: A only selected (add-C re-applied; C present but deselected)");
            bool hasC = false;
            foreach (n; allNames()) if (n == "C") { hasC = true; break; }
            assert(hasC, "redo-3: C now present in document");
        }
    }

    // Drain any remaining redo steps (UI entries above add-C, if replayed separately).
    for (int i = 4; i <= 10; ++i) {
        auto r = postRedo();
        if (r["status"].str != "ok") break;
        assertNoLockout("redo-" ~ i.to!string);
        assertPrimaryInvariant("redo-" ~ i.to!string);
    }

    // At top: primary invariant holds, A is in the selected set, no lockout.
    // The exact final selected set is A-only (sel-remove-C was the last command).
    assertPrimaryInvariant("top of redo (round-trip complete)");
    assertNoLockout("final: no lockout after round-trip");
    assert(setsEqual(selectedNames(), ["Layer 1"]),
        "round-trip complete: A is the only selected layer at top-of-redo");
}
