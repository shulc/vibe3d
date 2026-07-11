// Tests for mesh.vertexExtrude — Vertex Extrude kernel + command (task 0360
// rewrite: the old "duplicate vertex + wire edge" kernel was replaced by a
// cone/ring kernel matching the captured reference laws — see
// Mesh.extrudeVerticesByMask's doc-comment in source/mesh.d for the full
// writeup).
//
// Geometry model (captured, task 0360): `width` alone builds an N-gon ring
// of new vertices around a STATIONARY apex; `shift` alone (width=0) is a
// confirmed byte-exact no-op. `shift` only has an effect once `width` is
// also nonzero (single-sample TENTATIVE law — see kernel doc-comment).
//
// Cube vertex layout (makeCube):
//   0=(-0.5,-0.5,-0.5)  1=(0.5,-0.5,-0.5)  2=(0.5,0.5,-0.5)  3=(-0.5,0.5,-0.5)
//   4=(-0.5,-0.5, 0.5)  5=(0.5,-0.5, 0.5)  6=(0.5,0.5, 0.5)  7=(-0.5,0.5, 0.5)
// Cube has 8 verts, 12 edges, 6 quad faces. Every corner has valence 3.
//
// Per accepted (valence-3, manifold) vertex, width!=0 adds exactly 6 new
// vertices (2 per incident edge: a "rim" + a "fan" copy) and 6 new faces
// (a bridge quad + a fan triangle per incident face).

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, sqrt;
import std.format : format;
import std.string : split;

void main() {}

// --- HTTP helpers -----------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ resp ~ "\nbody: " ~ body);
}

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue getUndoStatus() {
    return parseJSON(get("http://localhost:8080/api/undo/status"));
}

// --- geometry helpers -------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a)    { return sqrt(a.x*a.x + a.y*a.y + a.z*a.z); }

// Index of the first vertex in `m` closest to `p` (within tol), or -1.
int vertAt(JSONValue m, V3 p, double tol = 1e-4) {
    foreach (i; 0 .. m["vertices"].array.length) {
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    }
    return -1;
}

// True iff index `vi` appears in the selectedVertices array from /api/selection.
bool isVertexSelected(JSONValue sel, int vi) {
    foreach (jv; sel["selectedVertices"].array)
        if (cast(int)jv.integer == vi) return true;
    return false;
}

// Every DIRECTED face edge (a->b) must appear exactly once, and its reverse
// (b->a) must also appear exactly once elsewhere — a generic 2-manifold,
// consistent-winding check (task 0360 deliverable: fixtures must assert
// manifold validity, not just vertex/face counts — a wave-1 fuzz precedent
// found count-only fixtures miss non-manifold results).
void assertManifold(JSONValue m) {
    int[string] count;
    foreach (f; m["faces"].array) {
        auto vs = f.array;
        size_t n = vs.length;
        foreach (k; 0 .. n) {
            long a = vs[k].integer;
            long b = vs[(k + 1) % n].integer;
            string key = a.to!string ~ "_" ~ b.to!string;
            count[key] = (key in count ? count[key] : 0) + 1;
        }
    }
    foreach (key, c; count) {
        assert(c == 1,
               "non-manifold: directed edge " ~ key ~ " used " ~ c.to!string ~ " times");
        auto parts = key.split("_");
        string revKey = parts[1] ~ "_" ~ parts[0];
        assert((revKey in count) !is null && count[revKey] == 1,
               "non-manifold: edge " ~ key ~ " has no single matching reverse");
    }
}

// ---------------------------------------------------------------------------
// 1. shift alone (width=0) is a complete no-op, either sign.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before     = getModel();
    auto undoBefore = getUndoStatus();

    auto raw = postCommandRaw(`{"id":"mesh.vertexExtrude","params":{"shift":0.2,"width":0.0}}`);
    assert(parseJSON(raw)["status"].str != "ok", "shift-alone must not return ok");

    auto after     = getModel();
    auto undoAfter = getUndoStatus();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "shift-alone changed vertex count");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "shift-alone changed face count");
    assert(undoAfter["modelDepth"].integer == undoBefore["modelDepth"].integer,
           "shift-alone pushed an undo entry");
}

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before = getModel();

    postCommandRaw(`{"id":"mesh.vertexExtrude","params":{"shift":-0.2,"width":0.0}}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "negative shift-alone changed vertex count");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "negative shift-alone changed face count");
}

// ---------------------------------------------------------------------------
// 2. width alone: N-gon ring around a stationary apex. Corner 0 (valence 3)
//    -> +6 verts / +6 faces. Apex stays put; selection stays on vertex 0.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before = getModel();
    V3 corner   = vert(before, 0);

    postCommand(`{"id":"mesh.vertexExtrude","params":{"shift":0.0,"width":0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == before["vertexCount"].integer + 6,
           format("width-alone: expected +6 verts, got %d -> %d",
                  before["vertexCount"].integer, m["vertexCount"].integer));
    assert(m["faceCount"].integer == before["faceCount"].integer + 6,
           format("width-alone: expected +6 faces, got %d -> %d",
                  before["faceCount"].integer, m["faceCount"].integer));

    // Apex unmoved.
    assert(vertAt(m, corner) >= 0, "width-alone: apex must remain at its original position");

    // Three ring points at exactly `width` distance along each incident edge.
    // Corner 0 = (-0.5,-0.5,-0.5); neighbours at (0.5,-0.5,-0.5),
    // (-0.5,0.5,-0.5), (-0.5,-0.5,0.5).
    assert(vertAt(m, V3(-0.3, -0.5, -0.5)) >= 0, "width-alone: ring point (-0.3,-0.5,-0.5) missing");
    assert(vertAt(m, V3(-0.5, -0.3, -0.5)) >= 0, "width-alone: ring point (-0.5,-0.3,-0.5) missing");
    assert(vertAt(m, V3(-0.5, -0.5, -0.3)) >= 0, "width-alone: ring point (-0.5,-0.5,-0.3) missing");

    // Selection stays on the (unmoved) apex vertex 0 -- NOT the new ring.
    auto sel = getSelection();
    assert(isVertexSelected(sel, 0), "width-alone: apex vertex 0 must remain selected");

    assertManifold(m);
}

// ---------------------------------------------------------------------------
// 3. Undo restores the original cube exactly.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before = getModel();

    postCommand(`{"id":"mesh.vertexExtrude","params":{"shift":0.0,"width":0.3}}`);
    auto ur = postUndo();
    assert(ur["status"].str == "ok", "undo failed: " ~ ur.toString);

    auto undone = getModel();
    assert(undone["vertexCount"].integer == before["vertexCount"].integer,
           "undo: vertex count not restored");
    assert(undone["faceCount"].integer   == before["faceCount"].integer,
           "undo: face count not restored");
}

// ---------------------------------------------------------------------------
// 4. width=0 no-op regardless of shift: postCommandRaw + unchanged counts +
//    undo stack untouched (pattern from test_edge_extrude.d).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before     = getModel();
    auto undoBefore = getUndoStatus();

    postCommandRaw(`{"id":"mesh.vertexExtrude","params":{"shift":0.5,"width":0.0}}`);

    auto after     = getModel();
    auto undoAfter = getUndoStatus();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "no-op changed vertex count");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "no-op changed face count");
    assert(undoAfter["modelDepth"].integer == undoBefore["modelDepth"].integer,
           "no-op pushed an undo entry (modelDepth changed)");
}

// ---------------------------------------------------------------------------
// 5. shift+width together (TENTATIVE, single captured data point): apex
//    moves by (shift+width) along the averaged incident-face normal. This
//    pins vibe3d's OWN documented approximation as a regression lock, not
//    an independently-verified reference match (see kernel doc-comment).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before = getModel();
    V3 corner   = vert(before, 0);

    postCommand(`{"id":"mesh.vertexExtrude","params":{"shift":0.2,"width":0.2}}`);
    auto m = getModel();

    // Corner 0's incident faces have Newell normal (0,0,-1)+(-1,0,0)+(0,-1,0)
    // = (-1,-1,-1), normalized = (-1,-1,-1)/sqrt(3) (same as the legacy
    // kernel's own test derivation).
    double inv3 = 1.0 / sqrt(3.0);
    double mag  = 0.2 + 0.2; // shift + width
    V3 expectedApex = V3(corner.x - inv3 * mag,
                         corner.y - inv3 * mag,
                         corner.z - inv3 * mag);
    int apexIdx = vertAt(m, expectedApex, 1e-4);
    assert(apexIdx >= 0,
           format("shift+width: apex not found near (%.4f,%.4f,%.4f)",
                  expectedApex.x, expectedApex.y, expectedApex.z));

    // Original corner position must be gone (apex moved).
    assert(vertAt(m, corner) < 0, "shift+width: apex must have moved off the original corner");
}

// ---------------------------------------------------------------------------
// 6. GOLDEN FIXTURE (task 0360 parity_case corners4_width02_stationary_apex):
//    4 mutually-adjacent corners (x>0.4 quartet, indices 1,2,5,6), width=0.2,
//    shift=0 -> 8v/6f => 32v/30f (exact byte match to the captured reference
//    dump). Apex vertices remain selected and unmoved; sample ring points at
//    corner (0.5,0.5,0.5) [vertex 6] land at exactly width=0.2 distance.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [1, 2, 5, 6]);
    auto before = getModel();
    assert(before["vertexCount"].integer == 8 && before["faceCount"].integer == 6,
           "golden fixture: base cube must be 8v/6f");

    postCommand(`{"id":"mesh.vertexExtrude","params":{"shift":0.0,"width":0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 32,
           format("golden fixture: expected 32 verts, got %d", m["vertexCount"].integer));
    assert(m["faceCount"].integer == 30,
           format("golden fixture: expected 30 faces, got %d", m["faceCount"].integer));

    // Apex vertices unmoved (still at their original corner positions) and
    // still selected -- matches the captured post-apply selection.
    auto sel = getSelection();
    foreach (vi; [1, 2, 5, 6]) {
        assert(vertAt(m, vert(before, vi)) >= 0,
               format("golden fixture: apex %d must remain at its original position", vi));
        assert(isVertexSelected(sel, vi),
               format("golden fixture: apex %d must remain selected", vi));
    }

    // Ring points around corner 6 = (0.5,0.5,0.5), matching the toolcard's
    // captured sample_apex_and_ring_near_original_corner_0.5_0.5_0.5.
    assert(vertAt(m, V3(0.5, 0.5, 0.3)) >= 0, "golden fixture: ring point (0.5,0.5,0.3) missing");
    assert(vertAt(m, V3(0.3, 0.5, 0.5)) >= 0, "golden fixture: ring point (0.3,0.5,0.5) missing");
    assert(vertAt(m, V3(0.5, 0.3, 0.5)) >= 0, "golden fixture: ring point (0.5,0.3,0.5) missing");

    assertManifold(m);
}
