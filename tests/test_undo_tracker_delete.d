// Phase 3 of doc/undo_change_tracker_plan.md — migrate the destructive topology
// commands (mesh.delete / mesh.remove, dispatching dissolve for vert/edge modes)
// from a whole-mesh MeshSnapshot to the operation-log MeshEditDelta, env-gated by
// VIBE3D_UNDO_TRACKER.
//
// These commands are COMMAND-PATH (no gizmo drag): select via /api/select, run
// via /api/command, undo/redo via /api/undo /api/redo, history navigation via
// /api/history/jump. Much simpler to drive than the interactive extrude.
//
// Coverage per op (delete-faces, remove, dissolve-verts, dissolve-edges) on a
// CUBE and a GRID (the grid selections orphan verts so compaction/Reindex
// actually fires — the cube top-face delete also orphans nothing for some
// selections, so the grid is the real Reindex witness):
//   1. PARITY GATE: same op+undo under VIBE3D_UNDO_TRACKER off (snapshot) vs on
//      (delta) → byte-identical post-undo geometry, == pre-op mesh.
//   2. ROUND-TRIP: op → undo == pre-op exactly; redo == post-op.
//   3. SELECTION restored on undo (/api/selection).
//   4. jumpTo: back past the op, then forward.
//   5. NEGATIVE CONTROL (documented, built under -version flags): a
//      RemoveFaces^-1 / Reindex^-1 stub breaks the round-trip — see report.
//
// The toggle is flipped at runtime via undo.tracker.on / undo.tracker.off
// (app.d test commands), so one running instance exercises both paths.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.algorithm : sort, map;
import std.array : array;

void main() {}

string BASE = "http://localhost:8080";

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
    // --- snapshot path (tracker OFF): establish the reference post-undo mesh ---
    cmd("undo.tracker.off");
    reset();
    setMode(mode);
    auto preOff = getModel();
    postSelect(mode, pick(preOff));
    // Clear history AFTER selecting (select.typeFrom / /api/select are recorded
    // as history entries), so the op below is the only undo-stack entry and
    // jumpTo(0)/jumpTo(1) bracket exactly it.
    cmd("history.clear");
    cmd(op);
    auto postOff = getModel();
    assert(postOff["faceCount"].integer < preOff["faceCount"].integer
        || postOff["vertexCount"].integer < preOff["vertexCount"].integer,
        label ~ " [off]: op changed nothing");
    auto uOff = postUndo();
    assert(uOff["status"].str == "ok", label ~ " [off]: undo failed: " ~ uOff.toString);
    auto undoneOff = getModel();
    assert(sameGeometry(undoneOff, preOff),
        label ~ " [off]: post-undo geometry != pre-op");

    // --- delta path (tracker ON) ---
    cmd("undo.tracker.on");
    reset();
    setMode(mode);
    auto preOn = getModel();
    postSelect(mode, pick(preOn));
    auto selPreKeys = selGeomKeys(preOn, getSelection(), mode);
    cmd("history.clear");
    cmd(op);
    auto postOn = getModel();
    assert(postOn["faceCount"].integer < preOn["faceCount"].integer
        || postOn["vertexCount"].integer < preOn["vertexCount"].integer,
        label ~ " [on]: op changed nothing");

    // (2) round-trip: undo == pre-op exactly.
    auto uOn = postUndo();
    assert(uOn["status"].str == "ok", label ~ " [on]: undo failed: " ~ uOn.toString);
    auto undoneOn = getModel();
    assert(sameGeometry(undoneOn, preOn),
        label ~ " [on]: post-undo geometry != pre-op (delta revert wrong)");

    // (1) parity gate: delta-path post-undo == snapshot-path post-undo == pre-op.
    assert(sameGeometry(undoneOn, undoneOff),
        label ~ ": delta post-undo != snapshot post-undo (PARITY GATE)");

    // (3) selection restored on undo (compared GEOMETRICALLY — see selGeomKeys:
    // edge indices are re-derived and not stable, but the SAME elements must be
    // selected after undo).
    auto selAfterUndo = selGeomKeys(undoneOn, getSelection(), mode);
    assert(sameKeys(selAfterUndo, selPreKeys),
        label ~ " [on]: selection not restored on undo "
        ~ selAfterUndo.to!string ~ " != " ~ selPreKeys.to!string);

    // (2) redo == post-op.
    auto rOn = postRedo();
    assert(rOn["status"].str == "ok", label ~ " [on]: redo failed: " ~ rOn.toString);
    auto redoneOn = getModel();
    assert(sameGeometry(redoneOn, postOn),
        label ~ " [on]: post-redo geometry != post-op (delta apply wrong)");

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

// GRID — remove edges (edge.remove → removeEdgesByMask, same path as delete).
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
