// Tests for mesh.vertexBevel — Vertex Bevel kernel + command.
//
// Geometry model: for each selected interior-manifold vertex v, every
// incident edge is split at v + amount*normalize(other−v); v is replaced in
// each incident face by its two split points, and an outward-wound cap N-gon
// is appended through the split points in rotational order.
//
// Cube vertex layout (makeCube):
//   0=(-0.5,-0.5,-0.5)  1=(0.5,-0.5,-0.5)  2=(0.5,0.5,-0.5)  3=(-0.5,0.5,-0.5)
//   4=(-0.5,-0.5, 0.5)  5=(0.5,-0.5, 0.5)  6=(0.5,0.5, 0.5)  7=(-0.5,0.5, 0.5)
//
// Corner 0 has 3 incident edges → 3 new verts (8→10) and 1 cap tri (6→7).
// With amount=0.2 the split points are (-0.3,-0.5,-0.5), (-0.5,-0.3,-0.5),
// (-0.5,-0.5,-0.3).

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, sqrt;
import std.format : format;

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

void cmdArg(string argstring) {
    auto resp = cast(string)post("http://localhost:8080/api/command", argstring);
    assert(parseJSON(resp)["status"].str == "ok",
           "cmdArg `" ~ argstring ~ "` failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo()     { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getUndoStatus(){ return parseJSON(get("http://localhost:8080/api/undo/status")); }

// --- geometry helpers -------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

double len3(V3 a) { return sqrt(a.x*a.x + a.y*a.y + a.z*a.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }

// Index of first vertex in `m` nearest to `p` within tol, or -1.
int vertAt(JSONValue m, V3 p, double tol = 1e-4) {
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    return -1;
}

// Face centroid (average of vertex positions).
V3 faceCentroid(JSONValue m, size_t fi) {
    auto fv = m["faces"].array[fi].array;
    V3 c;
    foreach (jv; fv) {
        V3 v = vert(m, cast(size_t)jv.integer);
        c.x += v.x; c.y += v.y; c.z += v.z;
    }
    double n = fv.length;
    return V3(c.x/n, c.y/n, c.z/n);
}

// Index of first face with centroid within tol of p, or -1.
int faceWithCentroid(JSONValue m, V3 p, double tol = 1e-3) {
    foreach (fi; 0 .. m["faces"].array.length) {
        V3 c = faceCentroid(m, fi);
        if (len3(sub3(c, p)) < tol) return cast(int)fi;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// 1. Counts: select corner 0, amount=0.2 → 8→10 verts, 6→7 faces.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);

    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 10,
           "counts: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
           "counts: expected 7 faces, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 2. Positions: split verts present; original corner 0 absent.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
    auto m = getModel();

    // Three split verts.
    int sp0 = vertAt(m, V3(-0.3, -0.5, -0.5));
    int sp1 = vertAt(m, V3(-0.5, -0.3, -0.5));
    int sp2 = vertAt(m, V3(-0.5, -0.5, -0.3));
    assert(sp0 >= 0, "positions: split vert (-0.3,-0.5,-0.5) not found");
    assert(sp1 >= 0, "positions: split vert (-0.5,-0.3,-0.5) not found");
    assert(sp2 >= 0, "positions: split vert (-0.5,-0.5,-0.3) not found");

    // Original corner must be absent.
    assert(vertAt(m, V3(-0.5, -0.5, -0.5)) < 0,
           "positions: original corner 0 must be absent after bevel");
}

// ---------------------------------------------------------------------------
// 3. Cap face: exactly one triangular face; 3 former-corner quads are pentagons.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
    auto m = getModel();

    int triCount = 0, pentCount = 0, quadCount = 0;
    foreach (fi; 0 .. m["faceCount"].integer) {
        int arity = cast(int)m["faces"].array[fi].array.length;
        if (arity == 3) ++triCount;
        else if (arity == 4) ++quadCount;
        else if (arity == 5) ++pentCount;
    }
    assert(triCount  == 1,
           "cap: expected 1 cap tri, got "    ~ triCount.to!string);
    assert(pentCount == 3,
           "cap: expected 3 pentagons, got " ~ pentCount.to!string);
    assert(quadCount == 3,
           "cap: expected 3 untouched quads, got " ~ quadCount.to!string);
}

// ---------------------------------------------------------------------------
// 4. Amount scaling: amount=0.4 moves split points to -0.1 offset.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.4}}`);
    auto m = getModel();

    assert(vertAt(m, V3(-0.1, -0.5, -0.5)) >= 0,
           "scaling: split vert (-0.1,-0.5,-0.5) not found at amount=0.4");
    assert(vertAt(m, V3(-0.5, -0.1, -0.5)) >= 0,
           "scaling: split vert (-0.5,-0.1,-0.5) not found at amount=0.4");
    assert(vertAt(m, V3(-0.5, -0.5, -0.1)) >= 0,
           "scaling: split vert (-0.5,-0.5,-0.1) not found at amount=0.4");
}

// ---------------------------------------------------------------------------
// 5. No-op: amount=0 → status:error, mesh unchanged, undo stack untouched.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before     = getModel();
    auto undoBefore = getUndoStatus();

    // amount=0 must return an error status — use postCommandRaw.
    auto raw = postCommandRaw(`{"id":"mesh.vertexBevel","params":{"amount":0.0}}`);
    auto j   = parseJSON(raw);
    assert(j["status"].str != "ok", "no-op: amount=0 must not return ok");

    auto after     = getModel();
    auto undoAfter = getUndoStatus();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "no-op: vertex count must not change");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "no-op: face count must not change");
    assert(undoAfter["modelDepth"].integer == undoBefore["modelDepth"].integer,
           "no-op: undo stack must not grow");
}

// ---------------------------------------------------------------------------
// 6. Undo: restores 8 verts / 6 faces exactly.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);

    auto ur = postUndo();
    assert(ur["status"].str == "ok", "undo: undo call failed: " ~ ur.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
           "undo: expected 8 verts after undo, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
           "undo: expected 6 faces after undo, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 7. Subpatch carry (HTTP): toggle subpatch on an incident face before bevel;
//    the cap tri must have isSubpatch=true.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto mPre = getModel();

    // Find a face incident to corner 0: any face whose vertex list contains
    // the vertex at position (-0.5,-0.5,-0.5), i.e., vertex index 0.
    int incFi = -1;
    // Collect ALL faces incident to vertex 0 (there are 3 for a cube corner).
    int[] incFaces;
    foreach (fi; 0 .. mPre["faceCount"].integer) {
        foreach (jv; mPre["faces"].array[fi].array)
            if (jv.integer == 0) { incFaces ~= cast(int)fi; break; }
    }
    assert(incFaces.length == 3, "subpatch: expected 3 faces incident to vertex 0");
    incFi = incFaces[0];

    // Toggle subpatch on ALL incident faces so capSrc will always pick one.
    cmdArg("select.typeFrom polygon");
    foreach (f; incFaces) {
        postSelect("polygons", [f]);
        postCommand(`{"id":"mesh.subpatch_toggle"}`);
    }

    // Verify all are subpatch before the bevel.
    auto mCheck = getModel();
    foreach (f; incFaces)
        assert(mCheck["isSubpatch"].array[f].type == JSONType.true_,
               "subpatch: incident face must be subpatch before bevel");

    // Switch to vertex mode, select corner 0, bevel.
    cmdArg("select.typeFrom vertex");
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
    auto m = getModel();

    assert(m["faceCount"].integer == 7, "subpatch: expected 7 faces after bevel");

    // The cap tri is the only tri-arity face; it must have isSubpatch=true.
    bool capFound = false, capIsSub = false;
    foreach (fi; 0 .. m["faceCount"].integer) {
        if (m["faces"].array[fi].array.length == 3) {
            capFound = true;
            capIsSub = (m["isSubpatch"].array[fi].type == JSONType.true_);
            break;
        }
    }
    assert(capFound,  "subpatch: cap tri not found in result");
    assert(capIsSub,  "subpatch: cap tri must inherit isSubpatch=true from incident face");
}

// ---------------------------------------------------------------------------
// Task 1903 Stage E4 — the seam cell.
// ---------------------------------------------------------------------------
unittest { // mesh.vertexBevel runs the whole chamfer inside ONE batch
    // POSITIVE CONTROL FIRST. Both assertions below are "this counter did not
    // move", and a dead counter satisfies that for free. mesh.triple is
    // deliberately still batchless, so it makes the SAME counter move.
    resetCube();
    cmdArg("select.typeFrom vertex");
    postSelect("vertices", []);
    auto c0 = parseJSON(get("http://localhost:8080/api/changes"));
    postCommand(`{"id":"mesh.triple"}`);
    auto c1 = parseJSON(get("http://localhost:8080/api/changes"));
    immutable long ctrl = c1["unbatchedGeometryCommits"].integer
                        - c0["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        "positive control: an UNBATCHED command must tick "
      ~ "unbatchedGeometryCommits, and mesh.triple ticked " ~ ctrl.to!string
      ~ " — a dead counter passes the assertions below for free "
      ~ "(task 1903 §3.2 L2).");

    // (1) ONE corner.
    resetCube();
    cmdArg("select.typeFrom vertex");
    postSelect("vertices", [0]);
    auto b1 = parseJSON(get("http://localhost:8080/api/changes"));
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
    auto a1 = parseJSON(get("http://localhost:8080/api/changes"));
    assert(getModel()["faceCount"].integer == 7,
        "the 1-corner chamfer did not apply — a refused command moves no "
      ~ "counter at all and makes the assertion below vacuous");
    immutable long u1 = a1["unbatchedGeometryCommits"].integer
                      - b1["unbatchedGeometryCommits"].integer;
    assert(u1 == 0,
        "mesh.vertexBevel (1 corner) made " ~ u1.to!string ~ " UNBATCHED "
      ~ "geometry commit(s). Task 1903 Stage E4 made `bevelVerticesByMask` a "
      ~ "free function over `ref MeshEditBatch`, and commands/mesh/vertex_bevel.d "
      ~ "opens that batch at the command boundary, so every internal commit "
      ~ "defers and stamps once at close(). Measured on THIS counter with the "
      ~ "deferral disabled: +7 (plan §3.2 L2).");

    // (2) THE WHOLE CUBE — a SCALE check. The zero has to hold as the operand
    // grows, not just on the single-corner path: pre-E4 the figure scaled with
    // the accepted vertex count (+8 for one corner, +12 for two), so what this
    // cell reddens under is "the chamfer is not batched at all", at several
    // times the amplitude of cell (1). An EMPTY selection is the whole mesh,
    // and the greedy vertex-disjoint pass accepts four of a cube's eight
    // corners.
    resetCube();
    cmdArg("select.typeFrom vertex");
    postSelect("vertices", []);
    auto b2 = parseJSON(get("http://localhost:8080/api/changes"));
    postCommand(`{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
    auto a2 = parseJSON(get("http://localhost:8080/api/changes"));
    auto m2 = getModel();
    assert(m2["faceCount"].integer > 7,
        "the whole-mesh chamfer left " ~ m2["faceCount"].integer.to!string
      ~ " faces, expected more than the single-corner 7 — otherwise this cell "
      ~ "is the same size as cell (1) and adds nothing");
    immutable long u2 = a2["unbatchedGeometryCommits"].integer
                      - b2["unbatchedGeometryCommits"].integer;
    assert(u2 == 0,
        "mesh.vertexBevel (whole mesh) made " ~ u2.to!string ~ " UNBATCHED "
      ~ "geometry commit(s) — the batch must cover the WHOLE operand, not one "
      ~ "vertex of it (task 1903 Stage E4).");
    assert(a2["batchLeaks"].integer - b2["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked its frame during mesh.vertexBevel — the "
      ~ "handle's destructor popped instead of close() (plan §2.2c)");
    assert(a2["nestedBatchOpens"].integer - b2["nestedBatchOpens"].integer == 0,
        "mesh.vertexBevel opened a NESTED batch. Unlike its fin-bundle sibling "
      ~ "this family has NO transitional debt — both its callers are outside "
      ~ "the mesh and open the batch at their own boundary, which is the "
      ~ "finished shape (task 1903 Stage E4, plan §4.4a).");
    assert(a2["opLogEntriesRecorded"].integer - b2["opLogEntriesRecorded"].integer == 0,
        "mesh.vertexBevel recorded op-log entries. The batch is `unrecorded` "
      ~ "deliberately: this command still undoes through a whole-mesh "
      ~ "MeshSnapshot, and Stage L7 is what flips it (task 1903 Stage E4).");
}
