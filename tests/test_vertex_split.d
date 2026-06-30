// Tests for mesh.vertexSplit (unweld: per-face copy of a shared vertex).
//
// Cube layout (makeCube):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
//
// makeCube faces (0-indexed):
//   fi=0: [0,3,2,1]   fi=1: [4,5,6,7]   fi=2: [0,4,7,3]
//   fi=3: [1,2,6,5]   fi=4: [3,7,6,2]   fi=5: [0,1,5,4]
//
// v6=(+0.5,+0.5,+0.5) is incident to fi=1,3,4 (3 faces).
// After splitting v6: fi=1 keeps v6, fi=3→v8, fi=4→v9.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.algorithm : sort, uniq;
import std.array : array;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok");
}

void postCommand(string body_) {
    auto resp = post("http://localhost:8080/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

string postCommandRaw(string body_) {
    return cast(string)post("http://localhost:8080/api/command", body_);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok");
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// ---------------------------------------------------------------------------
// Core golden: split corner v6 (+,+,+) which is shared by 3 faces
// ---------------------------------------------------------------------------

unittest { // cube corner v6 split → 10 verts, 6 faces, 3 distinct copies at (0.5,0.5,0.5)
    resetCube();
    postSelect("vertices", [6]);
    postCommand(`{"id":"mesh.vertexSplit"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 10,
        "expected 10 verts after split, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "expected 6 faces after split (faces unchanged), got " ~ m["faceCount"].integer.to!string);

    // Collect all indices whose position is at (0.5, 0.5, 0.5).
    int[] splitIndices;
    auto verts = m["vertices"].array;
    foreach (i, v; verts) {
        auto a = v.array;
        if (approxEqual(a[0].floating, 0.5)
         && approxEqual(a[1].floating, 0.5)
         && approxEqual(a[2].floating, 0.5))
            splitIndices ~= cast(int)i;
    }
    assert(splitIndices.length == 3,
        "expected 3 verts at (0.5,0.5,0.5), got " ~ splitIndices.length.to!string);

    // All 3 must be distinct indices.
    auto distinct = splitIndices.dup.sort.array;
    assert(distinct.length == 3 && distinct[0] != distinct[1] && distinct[1] != distinct[2],
        "the 3 coincident copies must be distinct indices");

    // All remaining non-copy vertices must not be at (0.5, 0.5, 0.5).
    // i.e. exactly 3 total verts at that position.
    assert(splitIndices.length == 3, "exactly 3 coincident copies");

    // The 3 faces that originally contained v6 must each hold a different
    // one of the split indices — no two split-corner faces share an index.
    auto faces = m["faces"].array;
    // Collect which split index each face at fi=1,3,4 uses.
    int[3] faceSplitIdx;
    foreach (fi, face; faces) {
        foreach (vid; face.array) {
            foreach (si; splitIndices) {
                if (vid.integer == si) {
                    // fi=1,3,4 should hit one of these; fi=0,2,5 should not.
                    // Just record — assertion below checks uniqueness.
                    faceSplitIdx[fi == 1 ? 0 : fi == 3 ? 1 : fi == 4 ? 2 : -1] = si;
                    break;
                }
            }
        }
    }
    // Check that fi=0, fi=2, fi=5 contain none of the split indices.
    foreach (fi; [0, 2, 5]) {
        foreach (vid; faces[fi].array) {
            foreach (si; splitIndices)
                assert(vid.integer != si,
                    "fi=" ~ fi.to!string ~ " must not contain a split index");
        }
    }
    // Check that fi=1, fi=3, fi=4 each contain exactly one split index
    // and all three are different from each other.
    int[] usedInOrigFaces;
    foreach (fi; [1, 3, 4]) {
        int found = -1;
        foreach (vid; faces[fi].array) {
            foreach (si; splitIndices) {
                if (vid.integer == si) { found = si; break; }
            }
        }
        assert(found >= 0, "fi=" ~ fi.to!string ~ " must contain one split index");
        usedInOrigFaces ~= found;
    }
    auto sortedUsed = usedInOrigFaces.dup.sort.array;
    assert(sortedUsed[0] != sortedUsed[1] && sortedUsed[1] != sortedUsed[2],
        "fi=1,3,4 must each hold a DISTINCT split index");
}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

unittest { // undo restores 8 verts and 6 quad faces
    resetCube();
    postSelect("vertices", [6]);
    postCommand(`{"id":"mesh.vertexSplit"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "undo: expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "undo: expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "undo: all faces must be quads");
}

// ---------------------------------------------------------------------------
// No-op errors
// ---------------------------------------------------------------------------

unittest { // nothing selected → error
    resetCube();
    // No postSelect — nothing is selected after reset.
    auto resp = postCommandRaw(`{"id":"mesh.vertexSplit"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error with nothing selected, got: " ~ resp);
    // Mesh unchanged.
    auto m = getModel();
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
        "no-op must not change mesh");
}

unittest { // already-split vertex (1 incident face) → no-op error
    resetCube();
    postSelect("vertices", [6]);
    postCommand(`{"id":"mesh.vertexSplit"}`);  // first split: v6 now in 1 face only
    // v6 is still selected (unchanged). Run split again — v6 is incident to
    // only 1 face now, so splitVerticesByMask returns 0 → error.
    auto resp = postCommandRaw(`{"id":"mesh.vertexSplit"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error on already-split vertex, got: " ~ resp);
    // Mesh unchanged at 10 verts.
    auto m = getModel();
    assert(m["vertexCount"].integer == 10,
        "second split must be no-op, expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Round-trip: split then weld restores position set of original cube
// ---------------------------------------------------------------------------

unittest { // split v6, weld the 3 copies back → 8 verts, 6 quads, same corner set
    resetCube();

    // Capture the original 8 corner positions for comparison.
    auto orig = getModel();
    double[3][] origPositions;
    foreach (v; orig["vertices"].array)
        origPositions ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];

    postSelect("vertices", [6]);
    postCommand(`{"id":"mesh.vertexSplit"}`);

    // Find the 3 coincident copies at (0.5, 0.5, 0.5).
    auto m = getModel();
    int[] splitIndices;
    foreach (i, v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, 0.5)
         && approxEqual(a[1].floating, 0.5)
         && approxEqual(a[2].floating, 0.5))
            splitIndices ~= cast(int)i;
    }
    assert(splitIndices.length == 3, "round-trip: expected 3 coincident copies");

    // Select all 3 copies and weld them back.
    postSelect("vertices", splitIndices);
    postCommand(`{"id":"vert.merge","params":{"range":"auto"}}`);

    auto result = getModel();
    assert(result["vertexCount"].integer == 8,
        "round-trip: expected 8 verts after weld, got " ~ result["vertexCount"].integer.to!string);
    assert(result["faceCount"].integer == 6,
        "round-trip: expected 6 faces, got " ~ result["faceCount"].integer.to!string);
    foreach (f; result["faces"].array)
        assert(f.array.length == 4, "round-trip: all faces must be quads");

    // Position set must match original cube (order-independent).
    double[3][] resultPositions;
    foreach (v; result["vertices"].array)
        resultPositions ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];
    assert(resultPositions.length == 8);

    // Check every original position appears in the result set.
    foreach (op; origPositions) {
        bool found = false;
        foreach (rp; resultPositions) {
            if (approxEqual(op[0], rp[0]) && approxEqual(op[1], rp[1]) && approxEqual(op[2], rp[2])) {
                found = true;
                break;
            }
        }
        assert(found, "round-trip: original corner ("
            ~ op[0].to!string ~ "," ~ op[1].to!string ~ "," ~ op[2].to!string
            ~ ") missing from result");
    }
}
