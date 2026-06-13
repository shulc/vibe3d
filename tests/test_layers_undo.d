// Stage 6 — cross-layer undo TORTURE test.
//
// This test exists to prove, under deliberate abuse, the two structural
// defenses the layer/document model relies on:
//
//   1. Cache-key IDENTITY (Stage 2): every version-keyed cache (snap grids,
//      visibility, symmetry pair table, subpatch preview) carries a
//      mesh-ADDRESS term in its key, not just `mutationVersion`. Without that
//      term, two layers that happen to share the same `mutationVersion` AND
//      the same vertex count would alias each other's cache entries — a switch
//      could then read a STALE colliding cache and pick / snap / mirror against
//      the wrong layer's geometry.
//
//   2. Gated display refresh (Stage 0a): a mutating command refreshes the GPU
//      buffer + global pick caches through `refreshDisplay`, which NO-OPs when
//      the command's target mesh is not the active layer. Cross-layer undo of a
//      background layer must never resize the global caches against a
//      foreign-sized mesh, nor upload a background layer's geometry into the
//      active display buffer.
//
// THE COLLISION THIS TEST ATTACKS. We build THREE identical cubes in three
// separate layers. Three identical cubes is the worst case for the OLD,
// address-free keys: a fresh `prim.cube` into an empty layer yields a mesh with
// the SAME vertex count (8) and — because each is built by the same command
// sequence into a freshly reset version counter — potentially the SAME
// `mutationVersion`. We assert below that the three layers really do share an
// equal `mutationVersion` and equal vertex counts, so the collision precondition
// is genuinely present; then we interleave edits + undo/redo + delete across all
// three and prove no stale colliding cache is ever read (the interactive pick on
// the active layer always lands on the correct geometry).
//
// TORTURE SEQUENCE. Edits are interleaved across the three layers via
// `layer.select`, then a mix of undo / redo / delete-a-layer / undo-the-delete /
// redo. After each step we assert:
//   - the geometry of every layer via `?layer=N` is exactly what it should be;
//   - the `/api/changes` counters stay COHERENT (a layer mutated by undo on a
//     background layer still publishes — `totalPosition` advances, never stalls);
//   - `/api/undo/status` never reports a hard `lockout`.
//
// The MISSED-PUBLISHER shadow (a debug-build check that every layer that bumped
// its `mutationVersion` actually published to the change bus) is driven by this
// sequence; the runner greps the vibe3d stderr after the suite to confirm it
// stayed silent throughout.

import std.net.curl;
import std.json;
import std.conv    : to;
import std.file    : read;
import core.thread : Thread;
import core.time   : dur;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (kept parallel to test_layers.d so the two read the same)
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

JSONValue cmdMayFail(string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    clearHistory();
}

void clearHistory() { cmdJson(`{"id":"history.clear"}`); }

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/redo", "")); }

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
    assertNoLockout("after undo: " ~ why);
}

void redoOk(string why) {
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo (" ~ why ~ ") failed: " ~ r.toString);
    assertNoLockout("after redo: " ~ why);
}

JSONValue getLayers() { return getJson("/api/layers"); }
JSONValue getSelection() { return getJson("/api/selection"); }
JSONValue getModelLayer(int layer) { return getJson("/api/model?layer=" ~ layer.to!string); }

size_t layerCount() { return getLayers()["layers"].array.length; }
size_t activeLayer() { return cast(size_t)getLayers()["active"].integer; }
size_t vertCount(int layer) { return getModelLayer(layer)["vertices"].array.length; }

double[3] vertexAt(int layer, int idx) {
    auto v = getModelLayer(layer)["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

bool approx(double a, double b) {
    auto d = a - b;
    return (d < 0 ? -d : d) < 1e-4;
}

int vIndexNear(int layer, double x) {
    auto verts = getModelLayer(layer)["vertices"].array;
    foreach (i, v; verts)
        if (approx(v.array[0].floating, x)) return cast(int)i;
    return -1;
}

bool anyVertNear(int layer, double x) { return vIndexNear(layer, x) >= 0; }

void moveVertexActive(double[3] from, double[3] to) {
    string v3(double[3] p) {
        return "[" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ "]";
    }
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":` ~ v3(from)
            ~ `,"to":` ~ v3(to) ~ `}}`);
}

void playEvents(string logPath) {
    auto events = cast(const(void)[])read(logPath);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/play-events", events));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    for (int i = 0; i < 150; ++i) {
        auto s = parseJSON(cast(string)get(baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    Thread.sleep(dur!"msecs"(150));
}

// ---------------------------------------------------------------------------
// /api/undo/status — assert the hard lockout never fires.
// ---------------------------------------------------------------------------

void assertNoLockout(string at) {
    auto s = getJson("/api/undo/status");
    assert(s["lockout"].type == JSONType.false_,
        "hard undo lockout asserted at: " ~ at ~ " (status=" ~ s.toString ~ ")");
}

// ---------------------------------------------------------------------------
// /api/changes — read counters as deltas across a step. The bus is process-wide
// and NOT reset between steps, so we snapshot and diff. A model mutation that
// touched a layer's positions must advance totalPosition (a missed publisher
// would leave it stalled). flushCount must advance every step (the per-frame
// flush keeps running). These prove the change-bus stays coherent through the
// cross-layer churn.
// ---------------------------------------------------------------------------

struct Changes {
    long flushCount, totalPosition, totalPoints, totalPolygons;
}

Changes changes() {
    auto j = getJson("/api/changes");
    Changes c;
    c.flushCount    = j["flushCount"].integer;
    c.totalPosition = j["totalPosition"].integer;
    c.totalPoints   = j["totalPoints"].integer;
    c.totalPolygons = j["totalPolygons"].integer;
    return c;
}

// A model edit (move_vertex / undo / redo of one) must, by the next flush,
// publish a Position change to the bus. Snapshot before, run `op`, then poll
// until totalPosition advances (give the per-frame flush a few frames). This is
// the per-step coherence assertion the torture sequence repeats.
void expectPositionPublish(string label, void delegate() op) {
    auto before = changes();
    op();
    bool advanced = false;
    for (int i = 0; i < 30; ++i) {
        auto now = changes();
        if (now.totalPosition > before.totalPosition
            && now.flushCount > before.flushCount) { advanced = true; break; }
        Thread.sleep(dur!"msecs"(20));
    }
    assert(advanced,
        "change-bus incoherent at `" ~ label ~ "`: totalPosition did not advance "
        ~ "after a position-mutating step (missed publisher?)");
}

// ---------------------------------------------------------------------------
// Build THREE identical cubes, one per layer (A=0, B=1, C=2). Returns with A
// active and history cleared. This is the collision substrate: three meshes
// with equal vertex counts and (asserted below) equal mutationVersion.
// ---------------------------------------------------------------------------

void threeCubeDoc() {
    resetCube();                 // layer 0 = cube A (8v)
    cmd("layer.add name:B");     // layer 1 active, empty
    cmd("prim.cube");            // B = cube (8v)
    cmd("layer.add name:C");     // layer 2 active, empty
    cmd("prim.cube");            // C = cube (8v)
    cmd("layer.select index:0"); // A active again
    clearHistory();
}

// ===========================================================================
// 1. Collision precondition — prove the three layers really do collide on the
//    OLD, address-free key space (equal vertCount AND equal mutationVersion).
// ===========================================================================

unittest {
    threeCubeDoc();
    auto layers = getLayers()["layers"].array;
    assert(layers.length == 3, "threeCubeDoc builds 3 layers");

    // Equal vertex counts (8 each).
    assert(vertCount(0) == 8 && vertCount(1) == 8 && vertCount(2) == 8,
        "all three layers are 8-vertex cubes");

    // The address-free collision precondition: at least two layers share a
    // mutationVersion AND an equal vertex count, so a cache keyed only on
    // (mutationVersion, vertCount) would alias them. /api/layers surfaces the
    // per-layer mutationVersion. In practice the two layers built identically by
    // a fresh `prim.cube` (B and C here) land on the SAME version — A, the
    // reset cube, takes a different mutation path and need not match. We assert
    // the identical-build pair collides; that is the hostile pair the
    // address-augmented keys must distinguish.
    long mv(int i) { return layers[i]["mutationVersion"].integer; }
    assert(mv(1) == mv(2),
        "the two identically-built cubes (B, C) must share a mutationVersion to "
        ~ "constitute the address-free cache collision this test attacks (got "
        ~ "A=" ~ mv(0).to!string ~ ", B=" ~ mv(1).to!string
        ~ ", C=" ~ mv(2).to!string ~ ")");
    // And they have equal vertex counts (asserted above) → without the address
    // term, B and C alias one another in every version-keyed cache.
}

// ===========================================================================
// 2. The torture sequence. Interleave edits across all three layers, then a
//    mix of undo / redo / delete / undo-delete / redo. After each model step,
//    assert per-layer geometry, change-bus coherence, and no hard lockout.
//    Because all three meshes collide on the old key space, every correct read
//    here proves the address-augmented keys (and the gated refresh) hold.
// ===========================================================================

unittest {
    threeCubeDoc();              // A active, B, C — three identical cubes
    clearHistory();

    // --- Interleaved edits, each on a DIFFERENT layer, each a unique marker.
    // A: push +X corner to 3.0
    expectPositionPublish("edit A", {
        moveVertexActive([0.5, -0.5, -0.5], [3.0, -0.5, -0.5]);
    });
    assert(anyVertNear(0, 3.0), "A edit landed on layer 0");

    cmd("layer.select index:1");          // B active (UI-undo entry)
    // B: push -X corner to -4.0
    expectPositionPublish("edit B", {
        moveVertexActive([-0.5, 0.5, 0.5], [-4.0, 0.5, 0.5]);
    });
    assert(anyVertNear(1, -4.0), "B edit landed on layer 1");

    cmd("layer.select index:2");          // C active (UI-undo entry)
    // C: push +X corner to 5.0
    expectPositionPublish("edit C", {
        moveVertexActive([0.5, 0.5, -0.5], [5.0, 0.5, -0.5]);
    });
    assert(anyVertNear(2, 5.0), "C edit landed on layer 2");

    // All three markers coexist on their own layers, none bled across the
    // colliding caches.
    assert(anyVertNear(0, 3.0) && anyVertNear(1, -4.0) && anyVertNear(2, 5.0),
        "three interleaved edits each stayed on their own layer");
    assert(!anyVertNear(0, -4.0) && !anyVertNear(0, 5.0), "A carries only A's edit");
    assert(!anyVertNear(1, 3.0)  && !anyVertNear(1, 5.0), "B carries only B's edit");
    assert(!anyVertNear(2, 3.0)  && !anyVertNear(2, -4.0), "C carries only C's edit");

    // --- Undo chain. C active. The history (top → bottom):
    //   C edit | select C | B edit | select B | A edit
    // Undo 1: C's edit reverts (C active, foreground).
    expectPositionPublish("undo C edit", { undoOk("revert C edit"); });
    assert(!anyVertNear(2, 5.0), "C edit reverted");
    assert(anyVertNear(0, 3.0) && anyVertNear(1, -4.0),
        "A and B edits untouched by C's undo");

    // Undo 2: the select C reverts → B active. (UI undo, no position publish.)
    undoOk("revert select C");
    assert(activeLayer() == 1, "undo of select C returns active to B");

    // Undo 3: B's edit reverts (B active).
    expectPositionPublish("undo B edit", { undoOk("revert B edit"); });
    assert(!anyVertNear(1, -4.0), "B edit reverted");
    assert(anyVertNear(0, 3.0), "A edit still present after B's undo");

    // --- Redo B's edit straight back (proves redo targets B, not a colliding
    // layer). Redo 1: select B's edit redo path — first the B edit returns.
    expectPositionPublish("redo B edit", { redoOk("redo B edit"); });
    assert(anyVertNear(1, -4.0), "B edit restored by redo");
    assert(activeLayer() == 1, "still on B after redoing its edit");

    // Redo 2: select C (UI). Redo 3: C edit returns.
    redoOk("redo select C");
    assert(activeLayer() == 2, "redo of select C returns to C");
    expectPositionPublish("redo C edit", { redoOk("redo C edit"); });
    assert(anyVertNear(2, 5.0), "C edit restored by redo");

    // Full state restored: all three markers present, each on its own layer.
    assert(anyVertNear(0, 3.0) && anyVertNear(1, -4.0) && anyVertNear(2, 5.0),
        "redo chain restored all three interleaved edits to their own layers");

    // --- Delete a layer with live history, then undo the delete, then redo.
    // Delete B (the middle layer). B is not active (C is) → active stays valid.
    cmd("layer.select index:2");          // ensure C active (it already is)
    auto preDelCount = layerCount();
    cmd("layer.delete index:1");          // delete B
    assert(layerCount() == preDelCount - 1, "delete drops a layer");
    assertNoLockout("after layer.delete");
    // C survives with its 5.0 marker; A survives with its 3.0 marker. (B is gone,
    // so its index slot now holds what was C — assert by marker, not index.)
    bool foundA = false, foundC = false;
    foreach (li; 0 .. cast(int)layerCount()) {
        if (anyVertNear(li, 3.0)) foundA = true;
        if (anyVertNear(li, 5.0)) foundC = true;
    }
    assert(foundA && foundC, "A and C survive B's delete with their markers");

    // Undo the delete → B comes back, with its -4.0 marker intact.
    undoOk("undo layer.delete (restore B)");
    assert(layerCount() == preDelCount, "undo of delete restores the layer");
    bool foundB = false;
    foreach (li; 0 .. cast(int)layerCount())
        if (anyVertNear(li, -4.0)) foundB = true;
    assert(foundB, "undo of delete restores B's edited geometry (-4.0 marker)");

    // Redo the delete → B gone again. Coherent, no lockout.
    redoOk("redo layer.delete");
    assert(layerCount() == preDelCount - 1, "redo of delete drops the layer again");
    foundB = false;
    foreach (li; 0 .. cast(int)layerCount())
        if (anyVertNear(li, -4.0)) foundB = true;
    assert(!foundB, "redo of delete removes B again");
    assertNoLockout("after redo layer.delete");
}

// ===========================================================================
// 3. Stale-colliding-cache PROOF via interactive picking. After all the
//    cross-layer churn above, the active layer's pick caches must be clean —
//    a stale colliding snap/visibility/pick cache from another (equal-version,
//    equal-count) layer would make an interactive pick land on the wrong
//    geometry or miss. We drive a real event-log vertex pick on the active
//    cube and assert it selects exactly the recorded vertices.
// ===========================================================================

unittest {
    threeCubeDoc();              // A, B, C — three identical cubes, A active
    clearHistory();

    // Churn: edit each layer, switch among them, undo some — exactly the kind
    // of cross-layer traffic that would re-populate a colliding cache key.
    moveVertexActive([0.5, -0.5, -0.5], [3.0, -0.5, -0.5]);   // A
    cmd("layer.select index:1");
    moveVertexActive([-0.5, 0.5, 0.5], [-4.0, 0.5, 0.5]);     // B
    cmd("layer.select index:2");
    moveVertexActive([0.5, 0.5, -0.5], [5.0, 0.5, -0.5]);     // C
    undoOk("revert C edit");                                  // C reverts
    cmd("layer.select index:1");                              // B active
    cmd("layer.select index:0");                              // A active (cube)
    clearHistory();

    // Interactive vertex pick on the now-active layer. The recorded log selects
    // two cube vertices. A clean result proves the global pick caches resized /
    // refreshed against the ACTIVE mesh, never reading a colliding background
    // layer's stale entry.
    playEvents("tests/events/selection_points.log");
    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "pick mode on the active layer");
    assert(sel["selectedVertices"].array.length == 2,
        "interactive pick on the active layer still works after cross-layer "
        ~ "undo + switches across three colliding-version layers (got "
        ~ sel["selectedVertices"].array.length.to!string ~ ")");
    assertNoLockout("after interactive pick");
}

// ===========================================================================
// 4. Background-layer survival across delete-undo + change-bus coherence with a
//    background layer present. layer.delete / undo-of-delete is a pure layers-
//    ARRAY operation: it detaches and re-attaches the SAME Layer object (its
//    mesh is GC-kept and untouched), so the restored layer's geometry is exactly
//    what it was — no spurious geometry mutation. We delete a BACKGROUND layer
//    while a different layer is active, undo the delete, and assert: the layer
//    comes back with intact geometry without stealing focus; the per-frame flush
//    keeps draining with the (now restored) background layer present; the
//    counters stay monotonic; no hard lockout. This guards the all-layer drain
//    loop and the delete's GC-liveness contract.
// ===========================================================================

unittest {
    threeCubeDoc();              // A active, B, C — three identical cubes
    // Give B a distinctive marker so its restore-by-undo is observable.
    cmd("layer.select index:1");
    moveVertexActive([-0.5, 0.5, 0.5], [-4.0, 0.5, 0.5]);     // edit B
    assert(anyVertNear(1, -4.0), "B edit present");
    cmd("layer.select index:0");          // A active — B is now a background layer
    clearHistory();
    assert(activeLayer() == 0, "A active, B backgrounded");

    // Delete B (background) while A is active. A stays active; B is dropped.
    cmd("layer.delete index:1");
    assert(activeLayer() == 0, "A stays active after deleting background B");
    bool bGone = true;
    foreach (li; 0 .. cast(int)layerCount())
        if (anyVertNear(li, -4.0)) bGone = false;
    assert(bGone, "B (and its -4.0 marker) dropped by the delete");

    // Undo the delete: B's Layer object is re-inserted as a NON-active
    // (background, A still active) layer, with its mesh intact. This is an array
    // operation — no geometry re-publish is expected — so we assert state, not a
    // bus delta.
    undoOk("undo layer.delete (restore background B)");
    assert(activeLayer() == 0, "A still active after undoing the background delete");
    bool bBack = false;
    foreach (li; 0 .. cast(int)layerCount())
        if (anyVertNear(li, -4.0)) bBack = true;
    assert(bBack, "undo of delete restored B's geometry while A stayed active");

    // Change-bus health with the restored background layer present. The bus
    // counts only DELIVERED flushes (a quiescent frame is a no-op that does not
    // bump flushCount), so we prove liveness with a real mutation on the active
    // layer A and confirm it is delivered while B sits in the background — i.e.
    // the all-layer drain didn't wedge on the background layer. Counters stay
    // monotonic throughout.
    auto a = changes();
    expectPositionPublish("active-layer edit with a background layer present", {
        moveVertexActive([0.5, -0.5, -0.5], [2.0, -0.5, -0.5]);   // edit active A
    });
    auto b = changes();
    assert(b.flushCount > a.flushCount,
        "an active-layer mutation is delivered by the flush with a background "
        ~ "layer present");
    assert(b.totalPosition > a.totalPosition,
        "the active-layer position change reached the bus");
    assert(b.totalPoints >= a.totalPoints && b.totalPolygons >= a.totalPolygons,
        "change-bus point/polygon counters are monotonic across the drain");
    assert(anyVertNear(0, 2.0), "the active-layer edit landed on A");
    // B's geometry was untouched by the active-layer edit (no cross-layer bleed).
    bool bStill = false;
    foreach (li; 0 .. cast(int)layerCount())
        if (anyVertNear(li, -4.0)) bStill = true;
    assert(bStill, "B's restored geometry is intact after the active-layer edit");
    assertNoLockout("background-layer drain");
}
