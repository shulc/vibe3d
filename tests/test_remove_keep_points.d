// Tests for mesh.remove (Tier 1.1) Polygons-mode "keep orphaned points"
// semantic — the Remove-vs-Delete distinction (task 0465).
//
// Reference behaviour (captured from the reference editor, doc/tasks 0465):
//   Delete (mesh.delete) drops the selected faces AND their now-unreferenced
//   points; Remove (mesh.remove) drops ONLY the faces and leaves the orphaned
//   points floating in place.
//
// Setup: a Catmull-Clark-subdivided cube (26 verts / 24 faces). The 4
// sub-faces of one original face share a valence-4 face-point; removing those
// 4 sub-faces orphans exactly that one point.
//   - mesh.remove -> 26 verts (orphan KEPT), 20 faces
//   - mesh.delete -> 25 verts (orphan removed), 20 faces
//
// Faces are picked by centroid (not hardcoded indices) so the test is robust
// to subdivide face-ordering changes. The literal localhost:8080 is rewritten
// per-worker by run_test.d.

import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : sort;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel()  { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue postUndo()  { return parseJSON(post("http://localhost:8080/api/undo", "")); }

private double jnum(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}

// Pick `count` face indices with the smallest key(centroid) value.
private int[] pickFaces(JSONValue m, double function(double[3]) key, int count) {
    auto verts = m["vertices"].array;
    auto faces = m["faces"].array;
    struct FK { int idx; double k; }
    FK[] fks;
    foreach (fi, f; faces) {
        auto ids = f.array;
        double[3] c = [0.0, 0.0, 0.0];
        foreach (vid; ids) {
            auto v = verts[cast(size_t)vid.integer].array;
            c[0] += jnum(v[0]); c[1] += jnum(v[1]); c[2] += jnum(v[2]);
        }
        double n = cast(double) ids.length;
        c[0] /= n; c[1] /= n; c[2] /= n;
        fks ~= FK(cast(int) fi, key(c));
    }
    fks.sort!((a, b) => a.k < b.k);
    int[] outIdx;
    foreach (i; 0 .. count) outIdx ~= fks[i].idx;
    return outIdx;
}

// Centroid keys: back face (min Z); back+top (min of Z and -Y).
private static double keyBackZ(double[3] c)   { return c[2]; }
private static double keyBackTop(double[3] c) { import std.algorithm : min; return min(c[2], -c[1]); }

// --- The 26v/24f subdivided cube baseline ----------------------------------
unittest {
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 26,
        "subdiv cube should be 26 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "subdiv cube should be 24 faces, got " ~ m["faceCount"].integer.to!string);
}

// --- Remove KEEPS the orphaned face-point (one face) ------------------------
unittest {
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m = getModel();
    postSelect("polygons", pickFaces(m, &keyBackZ, 4));
    postCommand(`{"id":"mesh.remove"}`);
    auto after = getModel();
    assert(after["vertexCount"].integer == 26,
        "Remove-Polygons must KEEP the orphaned point (expected 26 verts), got "
        ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 20,
        "expected 20 faces after removing 4, got " ~ after["faceCount"].integer.to!string);
}

// --- Delete REMOVES the orphaned face-point (one face) — the control --------
unittest {
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m = getModel();
    postSelect("polygons", pickFaces(m, &keyBackZ, 4));
    postCommand(`{"id":"mesh.delete"}`);
    auto after = getModel();
    assert(after["vertexCount"].integer == 25,
        "Delete-Polygons must COMPACT the orphaned point (expected 25 verts), got "
        ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 20,
        "expected 20 faces after deleting 4, got " ~ after["faceCount"].integer.to!string);
}

// --- Remove keeps ALL orphans (two faces -> 3 orphans, no exceptions) -------
unittest {
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m = getModel();
    postSelect("polygons", pickFaces(m, &keyBackTop, 8));
    postCommand(`{"id":"mesh.remove"}`);
    auto rem = getModel();
    assert(rem["vertexCount"].integer == 26,
        "Remove must keep all 3 orphans (expected 26 verts), got "
        ~ rem["vertexCount"].integer.to!string);
    assert(rem["faceCount"].integer == 16, "expected 16 faces, got "
        ~ rem["faceCount"].integer.to!string);

    // Same selection through Delete drops all 3 orphans (diverges from Remove).
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m2 = getModel();
    postSelect("polygons", pickFaces(m2, &keyBackTop, 8));
    postCommand(`{"id":"mesh.delete"}`);
    auto del = getModel();
    assert(del["vertexCount"].integer == 23,
        "Delete must drop all 3 orphans (expected 23 verts), got "
        ~ del["vertexCount"].integer.to!string);
    assert(del["faceCount"].integer == 16, "expected 16 faces, got "
        ~ del["faceCount"].integer.to!string);
}

// --- Undo of a keep-orphans Remove restores the full cage -------------------
unittest {
    resetCube();
    postCommand(`{"id":"mesh.subdivide"}`);
    auto m = getModel();
    postSelect("polygons", pickFaces(m, &keyBackZ, 4));
    postCommand(`{"id":"mesh.remove"}`);
    assert(getModel()["vertexCount"].integer == 26);
    postUndo();
    auto back = getModel();
    assert(back["vertexCount"].integer == 26,
        "undo should restore 26 verts, got " ~ back["vertexCount"].integer.to!string);
    assert(back["faceCount"].integer == 24,
        "undo should restore 24 faces, got " ~ back["faceCount"].integer.to!string);
}
