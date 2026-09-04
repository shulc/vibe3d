// The delta-backed destructive topology commands (mesh.delete / mesh.remove,
// dispatching dissolve for vert/edge modes), driven over HTTP.
//
// WHAT THIS FILE USED TO BE, AND WHY THAT HALF IS GONE (task 1903 stage L3-b).
// Until the fork deletion these commands had TWO undo paths — a whole-mesh
// `MeshSnapshot` under `VIBE3D_UNDO_TRACKER=off` and an operation-log
// `MeshEditDelta` by default — and `runScenario` below ran every op TWICE in
// one instance, once per path, then asserted
// `sameGeometry(undoneOn, undoneOff)` on a line labelled PARITY GATE.
//
// **That assertion had to go with the fork, not survive it.** With one path
// left, `[off]` and `[on]` are the same code, so the gate would have compared
// a path against itself: green before any regression, green after it, and
// green again when someone reverts the fix. Leaving it in would have
// MANUFACTURED a check that cannot come out differently — which is the exact
// defect class this repository pays for most.
//
// WHERE THE PARITY COMPARISON WENT. It was frozen, on a tree that still had
// both arms, as `tests/fixtures/undo_parity/delete_remove.json` — ten cells,
// two dumps each, read by `tests/unit/undo_parity_l3_test`. The frozen oracle
// is also STRICTLY WIDER than the assertion it replaces: `sameGeometry` here
// compares vertex/face counts and coincident positions and nothing else, while
// the fixture compares `faceMaterial`, `facePart`, every mark word,
// `*SelectionOrder`, the selection-set masks and `meshMaps` as well — the
// planes the task-0613 burn-in actually lost, none of which a geometry compare
// can see. It runs in the `dub test --config=tests` lane, not this one.
//
// WHAT REMAINS HERE, and each of these compares against the PRE-OP capture,
// not against a second run of the same code:
//   1. ROUND-TRIP: op → undo == pre-op exactly; redo == post-op.
//   2. SELECTION restored on undo (/api/selection), compared geometrically.
//   3. jumpTo: back past the op, then forward.
//   4. the mesh-edit seam counters, including
//      `emptyDeltaOverMutation` — see the last block.
//
// These commands are COMMAND-PATH (no gizmo drag): select via /api/select, run
// via /api/command, undo/redo via /api/undo /api/redo, history navigation via
// /api/history/jump.
//
// Coverage per op (delete-faces, remove, dissolve-verts, dissolve-edges) on a
// CUBE and a GRID (the grid selections orphan verts so compaction/Reindex
// actually fires — the cube top-face delete also orphans nothing for some
// selections, so the grid is the real Reindex witness).
//
// NO `undo.tracker.on` / `.off` APPEARS IN THIS FILE ANY MORE. The commands
// still exist (fifteen other files branch on the toggle), but they no longer
// select a path for these two, and a call left here would say they do.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.algorithm : sort, map;
import std.array : array;

void main() {}

alias BASE = testBaseUrl;

// --- HTTP helpers ----------------------------------------------------------

void resetCube() {
    auto resp = post(BASE ~ "/api/reset?type=cube", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset cube failed: " ~ cast(string)resp);
}

void resetGrid(int n) {
    auto resp = post(BASE ~ "/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset grid failed: " ~ cast(string)resp);
}

void cmd(string s) {
    auto resp = post(BASE ~ "/api/command", s);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string)resp);
}

void setMode(string mode) {
    // select.typeFrom takes the SINGULAR type name (vertex|edge|polygon).
    string t;
    final switch (mode) {
        case "vertices": t = "vertex";  break;
        case "edges":    t = "edge";    break;
        case "polygons": t = "polygon"; break;
    }
    cmd("select.typeFrom " ~ t);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(BASE ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string)resp);
}

JSONValue postUndo() { return parseJSON(cast(string)post(BASE ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(BASE ~ "/api/redo", "")); }
JSONValue getModel() { return parseJSON(cast(string)get(BASE ~ "/api/model")); }
JSONValue getSelection() { return parseJSON(cast(string)get(BASE ~ "/api/selection")); }

// How many entries the undo stack holds. `/api/history`'s arrays run OLDEST
// FIRST; only the LENGTH is read here.
size_t undoDepth() {
    return parseJSON(cast(string)get(BASE ~ "/api/history"))["undo"].array.length;
}

JSONValue jumpTo(int target) {
    return parseJSON(cast(string)post(BASE ~ "/api/history/jump",
        `{"target":` ~ target.to!string ~ `}`));
}

// --- geometry helpers ------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

// Order-independent BYTE-LEVEL geometry equality: equal counts AND every vertex
// of `a` has a coincident vertex in `b` and vice versa.
bool sameGeometry(JSONValue a, JSONValue b) {
    if (a["vertexCount"].integer != b["vertexCount"].integer) return false;
    if (a["faceCount"].integer   != b["faceCount"].integer)   return false;
    if (a["vertices"].array.length != b["vertices"].array.length) return false;
    foreach (i; 0 .. a["vertices"].array.length)
        if (vertAt(b, vert(a, i)) < 0) return false;
    foreach (i; 0 .. b["vertices"].array.length)
        if (vertAt(a, vert(b, i)) < 0) return false;
    return true;
}

string fmt3(V3 p) {
    import std.format : format;
    return format("%.4f,%.4f,%.4f", p.x, p.y, p.z);
}

// Geometric (index-independent) selection key for the given mode. Vertex/face
// indices ARE stable across the delta revert, but EDGE indices are not (edges
// are re-derived from faces, so their order can change). So selection equality
// is checked by POSITION: vertices/faces by their vertex positions, edges by
// their endpoint-position pair — this matches "the same elements are selected",
// which is the property undo must preserve.
string[] selGeomKeys(JSONValue model, JSONValue sel, string mode) {
    import std.algorithm : sort;
    string[] keys;
    final switch (mode) {
        case "vertices":
            foreach (v; sel["selectedVertices"].array)
                keys ~= fmt3(vert(model, cast(size_t)v.integer));
            break;
        case "edges":
            foreach (v; sel["selectedEdges"].array) {
                size_t ei = cast(size_t)v.integer;
                if (ei >= model["edges"].array.length) continue;
                auto e = model["edges"].array[ei];
                auto pa = vert(model, cast(size_t)e.array[0].integer);
                auto pb = vert(model, cast(size_t)e.array[1].integer);
                string ka = fmt3(pa), kb = fmt3(pb);
                keys ~= (ka < kb) ? (ka ~ "|" ~ kb) : (kb ~ "|" ~ ka);
            }
            break;
        case "polygons":
            foreach (v; sel["selectedFaces"].array) {
                size_t fi = cast(size_t)v.integer;
                if (fi >= model["faces"].array.length) continue;
                string[] vk;
                foreach (idx; model["faces"].array[fi].array)
                    vk ~= fmt3(vert(model, cast(size_t)idx.integer));
                vk.sort();
                string fk;
                foreach (k; vk) fk ~= k ~ ";";
                keys ~= fk;
            }
            break;
    }
    keys.sort();
    return keys;
}

bool sameKeys(string[] a, string[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) if (a[i] != b[i]) return false;
    return true;
}

// ===========================================================================
// Core scenario runner: select, op, undo, redo, jumpTo, parity. Selection is
// supplied as a closure that returns the indices to select given the fresh
// model; `op` is the /api/command string (mesh.delete or mesh.remove).
// ===========================================================================
void runScenario(string label, void delegate() reset, string mode,
                 int[] delegate(JSONValue) pick, string op) {
    reset();
    setMode(mode);
    auto preOn = getModel();
    postSelect(mode, pick(preOn));
    auto selPreKeys = selGeomKeys(preOn, getSelection(), mode);
    // Clear history AFTER selecting (select.typeFrom / /api/select are recorded
    // as history entries), so the op below is the only undo-stack entry and
    // jumpTo(0)/jumpTo(1) bracket exactly it.
    cmd("history.clear");
    // HOW MANY ENTRIES THE UNDO BELOW IS SUPPOSED TO MOVE, read rather than
    // assumed. A witness two stages ago was inert twice because its undo
    // named a command id that does not exist: /api/undo answered `ok`, the
    // stack never moved, and every later assertion compared the mesh against
    // itself. `history.clear` leaves an empty undo stack, so the op must take
    // it to exactly 1.
    immutable size_t depthAfterClear = undoDepth();
    assert(depthAfterClear == 0,
        label ~ ": history.clear left " ~ depthAfterClear.to!string
        ~ " undo entries — the jumpTo targets below name the wrong revisions");
    cmd(op);
    immutable size_t depthAfterOp = undoDepth();
    assert(depthAfterOp == 1,
        label ~ ": the op left " ~ depthAfterOp.to!string ~ " undo entries, "
        ~ "expected exactly 1 — a command that recorded nothing makes every "
        ~ "assertion below vacuous");
    auto postOn = getModel();
    assert(postOn["faceCount"].integer < preOn["faceCount"].integer
        || postOn["vertexCount"].integer < preOn["vertexCount"].integer,
        label ~ ": op changed nothing");

    // (1) round-trip: undo == pre-op exactly, and the undo ACTUALLY RAN —
    // the stack depth must come back down by one.
    auto uOn = postUndo();
    assert(uOn["status"].str == "ok", label ~ ": undo failed: " ~ uOn.toString);
    immutable size_t depthAfterUndo = undoDepth();
    assert(depthAfterUndo == depthAfterOp - 1,
        label ~ ": /api/undo answered ok but the undo stack went from "
        ~ depthAfterOp.to!string ~ " to " ~ depthAfterUndo.to!string
        ~ " — nothing was undone and the geometry compare below is a mesh "
        ~ "against itself");
    auto undoneOn = getModel();
    assert(sameGeometry(undoneOn, preOn),
        label ~ ": post-undo geometry != pre-op (delta revert wrong)");

    // (2) selection restored on undo (compared GEOMETRICALLY — see selGeomKeys:
    // edge indices are re-derived and not stable, but the SAME elements must be
    // selected after undo).
    auto selAfterUndo = selGeomKeys(undoneOn, getSelection(), mode);
    assert(sameKeys(selAfterUndo, selPreKeys),
        label ~ ": selection not restored on undo "
        ~ selAfterUndo.to!string ~ " != " ~ selPreKeys.to!string);

    // (3) redo == post-op, and the redo moved the stack back up.
    auto rOn = postRedo();
    assert(rOn["status"].str == "ok", label ~ ": redo failed: " ~ rOn.toString);
    assert(undoDepth() == depthAfterOp,
        label ~ ": /api/redo answered ok but the undo stack did not return to "
        ~ depthAfterOp.to!string);
    auto redoneOn = getModel();
    assert(sameGeometry(redoneOn, postOn),
        label ~ ": post-redo geometry != post-op (delta apply wrong)");

    // (4) jumpTo: back PAST the op (target 0 = empty history baseline), then
    // forward past it. After history.clear the op is the only entry, so
    // jumpTo(0) lands before it and jumpTo(1) lands after.
    auto j0 = jumpTo(0);
    assert(j0["status"].str == "ok", label ~ ": jumpTo(0) failed: " ~ j0.toString);
    assert(sameGeometry(getModel(), preOn),
        label ~ ": jumpTo(0) (before op) != pre-op");
    auto j1 = jumpTo(1);
    assert(j1["status"].str == "ok", label ~ ": jumpTo(1) failed: " ~ j1.toString);
    assert(sameGeometry(getModel(), postOn),
        label ~ ": jumpTo(1) (after op) != post-op");
}

// ===========================================================================
// CUBE — delete polygons (faces). Cube corner-incident face delete orphans no
// verts (every cube vert is shared by 3 faces), so deleting ONE face leaves all
// 8 verts referenced → identity Reindex. This is the RemoveFaces witness (the
// faces come back on undo); the grid cases below are the Reindex witnesses.
// ===========================================================================
unittest {
    runScenario("cube/delete/polygons", () => resetCube(), "polygons",
        (JSONValue m) {
            // Select the top face (4 top verts). Find any one face by picking
            // face index 0 — deterministic.
            return [0];
        },
        "mesh.delete");
}

// CUBE — remove polygons (geometrically identical to delete for poly mode).
unittest {
    runScenario("cube/remove/polygons", () => resetCube(), "polygons",
        (JSONValue m) { return [0]; },
        "mesh.remove");
}

// ===========================================================================
// GRID — delete polygons. Deleting the corner cell (face 0) orphans the corner
// vert (referenced by only that one face) → compactUnreferenced drops it →
// NON-identity Reindex. This is the Reindex⁻¹ witness for the delete path.
// ===========================================================================
unittest {
    runScenario("grid/delete/polygons", () => resetGrid(2), "polygons",
        (JSONValue m) { return [0]; },
        "mesh.delete");
}

// ===========================================================================
// GRID — dissolve vertices. Dissolving the centre vert (0,0,0) shrinks all 4
// quads to triangles and orphans the centre vert → Reindex fires. This is the
// ReshapeFaces + Reindex witness for the dissolve path (Vertices mode).
// ===========================================================================
unittest {
    runScenario("grid/dissolve/vertices", () => resetGrid(2), "vertices",
        (JSONValue m) {
            int c = vertAt(m, V3(0.0, 0.0, 0.0));
            assert(c >= 0, "grid centre vert not found");
            return [c];
        },
        "mesh.delete");
}

// GRID — remove vertices (same dissolve path as delete for vert mode).
unittest {
    runScenario("grid/remove/vertices", () => resetGrid(2), "vertices",
        (JSONValue m) {
            int c = vertAt(m, V3(0.0, 0.0, 0.0));
            assert(c >= 0, "grid centre vert not found");
            return [c];
        },
        "mesh.remove");
}

// ===========================================================================
// GRID — dissolve edges. Removing an interior edge merges its two adjacent
// quads into one hexagon; dissolveDegree2Verts then collapses any 2-valent
// endpoint. This exercises removeEdgesByMask's NEW Phase-3 RemoveFaces+AddFaces
// hooks plus the trailing dissolve + compaction. (Edges mode.)
// ===========================================================================
unittest {
    runScenario("grid/dissolve/edges", () => resetGrid(2), "edges",
        (JSONValue m) {
            // Interior vertical edge between centre (0,0,0) and bottom-centre
            // (0,0,1): shared by two cells → interior → dissolvable.
            int a = vertAt(m, V3(0.0, 0.0, 0.0));
            int b = vertAt(m, V3(0.0, 0.0, 1.0));
            assert(a >= 0 && b >= 0, "grid interior edge endpoints not found");
            int ei = edgeIndex(m, a, b);
            assert(ei >= 0, "grid interior edge not found");
            return [ei];
        },
        "mesh.delete");
}

// GRID — remove edges (`removeEdgesByMask`, same path as delete).
unittest {
    runScenario("grid/remove/edges", () => resetGrid(2), "edges",
        (JSONValue m) {
            int a = vertAt(m, V3(0.0, 0.0, 0.0));
            int b = vertAt(m, V3(0.0, 0.0, 1.0));
            assert(a >= 0 && b >= 0, "grid interior edge endpoints not found");
            int ei = edgeIndex(m, a, b);
            assert(ei >= 0, "grid interior edge not found");
            return [ei];
        },
        "mesh.remove");
}

// ===========================================================================
// M-EB (task 1903 §3.1 B4) — `mesh.delete` STILL PUBLISHES under the mesh-edit
// seam.
//
// This command holds ZERO `commitChange` of its own: `MeshDelete.evaluate`
// opens a `beginEditBatch`, its kernel (`deleteFacesByMask` /
// `dissolveVerticesByMask`) commits INSIDE the batch, and `endEditBatch()`
// closes it. Under the seam those commits DEFER into the batch frame, so an
// `endEditBatch()` that only popped the frame — which is what the plan's
// Revision 2 specified — would throw the whole edit's stamp away: no
// `mutationVersion` bump, no hide derive, and (after task 1906) no delivery.
// Nothing else in this file would notice: the geometry is still correct, the
// undo still round-trips, and only the version-keyed consumers go stale.
//
// The observable is the per-layer `mutationVersion` at `/api/layers` — the
// read-only diagnostic the cross-layer-undo test already reads.
//
// MUTATION: make `Mesh.endEditBatch()` pop without stamping →
//   "mutationVersion did not advance across mesh.delete".
// The cell no longer forces the tracker on: after task 1903 stage L3-b the
// command opens its batch unconditionally, so a toggle here would be inert —
// and worse, it would imply the class still has a second path.
// ===========================================================================

ulong primaryMutationVersion() {
    auto js = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    foreach (l; js["layers"].array) {
        if ("primary" in l && l["primary"].type == JSONType.true_) {
            assert(l["mutationVersion"].type != JSONType.null_,
                "the primary layer reports no mutationVersion — this cell "
              ~ "cannot see whether the edit published");
            return cast(ulong)l["mutationVersion"].integer;
        }
    }
    assert(false, "/api/layers reports no primary layer");
}

unittest {
    resetCube();
    setMode("polygons");
    postSelect("polygons", [0]);

    const ulong before = primaryMutationVersion();
    cmd("mesh.delete");
    const ulong after = primaryMutationVersion();

    assert(after > before,
        "mutationVersion did not advance across mesh.delete (" ~
        before.to!string ~ " -> " ~ after.to!string ~ ") — the command holds " ~
        "no commitChange of its own, so its kernel's commits defer into the " ~
        "edit batch and endEditBatch() is the only thing that can stamp them");

    // …and exactly once: the whole point of the seam is that N primitive
    // commits inside one batch produce ONE version bump, not N.
    assert(after == before + 1,
        "mesh.delete advanced mutationVersion by " ~ (after - before).to!string ~
        "; expected exactly 1 — one closed batch is one stamp");

    // The bus counters this task adds must all read 0 in a run that opened no
    // nested batch, refused no upgrade and leaked no handle.
    auto ch = parseJSON(cast(string)get(BASE ~ "/api/changes"));
    assert(ch["batchLeaks"].integer == 0,
        "changeBus.batchLeaks is non-zero — a MeshEditBatch was destroyed while "
      ~ "still open, so its frame came off the stack without stamping");
    assert(ch["batchUpgradeRefusals"].integer == 0,
        "changeBus.batchUpgradeRefusals is non-zero — a recording batch was "
      ~ "opened inside an unrecorded one");
    assert(ch["nestedBatchOpens"].integer == 0,
        "changeBus.nestedBatchOpens is non-zero — a kernel opened a batch of "
      ~ "its own; the command or the tool opens it, never the kernel");
    assert(ch["opLogEntriesRecorded"].integer > 0,
        "changeBus.opLogEntriesRecorded stayed 0 across a delta-path "
      ~ "mesh.delete — the batch recorded no op-log entry");

    // W-3-a3 (task 1903 stage L3-a) — the field-side zero for the fifth
    // invariant counter. THIS PROCESS's instance: each tests/test_*.d runs
    // against its own vibe3d, so "across a full ./run_test.d run" is not a
    // quantity that exists, and the message says which process it means.
    //
    // The counter is absolute here rather than a delta because a fresh
    // instance starts it at 0 and NOTHING in this file's traffic — eight
    // delete/remove scenarios in three modes on two stands, plus this cell —
    // should ever reach the branch: every kernel on these paths has an
    // explicit publisher. The key lookup is itself the check that the
    // endpoint still reports the field.
    assert("emptyDeltaOverMutation" in ch,
        "/api/changes no longer reports `emptyDeltaOverMutation` — the "
      ~ "counter has lost its only wire reader and its zero below would be "
      ~ "a lookup failure, not a measurement");
    assert(ch["emptyDeltaOverMutation"].integer == 0,
        "changeBus.emptyDeltaOverMutation is "
      ~ ch["emptyDeltaOverMutation"].integer.to!string
      ~ " in THIS test's vibe3d instance — a recording batch closed EMPTY "
      ~ "over a kernel that reported work done. The mesh was mutated, no "
      ~ "history entry was recorded and nothing rolled it back. MUTATION "
      ~ "that drives it: delete one `recordRemoveFaces` call in "
      ~ "deleteFacesByMask — a delta-length assertion stays green (the log "
      ~ "is still non-empty) and so does sameGeometry (the command errored)");

    postUndo();
}
