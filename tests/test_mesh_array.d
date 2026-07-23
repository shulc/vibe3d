// Tests for mesh.array (PR-3 of doc/duplicate_plan.md). Linear array:
// for a WHOLE-MESH array (empty selection) insert count-1 shifted copies
// keeping the source. For a PARTIAL (sub-face) selection, full reference
// parity REPLACES the source poly with `count` fresh copies — the copy at
// the source position owns duplicated seam verts instead of sharing them —
// so the total is `count` independent instances. `count` includes the
// original; weld>0 folds coincident verts but KEEPS the doubled coincident
// seam face (full reference parity — the line-array path does not dedup faces).
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

// Helpers ------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(post("http://localhost:8080/api/command", body));
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue postUndo()     { return parseJSON(post("http://localhost:8080/api/undo", "")); }

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// Whole-mesh array — empty selection ⇒ act on all faces
// ---------------------------------------------------------------------------

unittest { // count=4 along +X with offset 2 ⇒ 4 cubes spaced 2 apart.
           // 8 + 3*8 = 32 verts, 6 + 3*6 = 24 faces, 4 disjoint cubes
           // × 12 edges each = 48 edges (no shared edges with no weld).
    resetCube();

    postCommand(`{"id":"mesh.array","params":{
        "count":4,"offset":[2,0,0],"weld":0
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 32,
        "verts: expected 32, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "faces: expected 24, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 48,
        "edges: expected 48, got "  ~ m["edgeCount"].integer.to!string);

    // Verify copy 3 (last) has verts at x ∈ {5.5, 6.5}.
    auto verts = m["vertices"].array;
    int seen55 = 0, seen65 = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (approxEq(x, 5.5)) ++seen55;
        if (approxEq(x, 6.5)) ++seen65;
    }
    assert(seen55 == 4, "expected 4 verts at x=5.5, got " ~ seen55.to!string);
    assert(seen65 == 4, "expected 4 verts at x=6.5, got " ~ seen65.to!string);
}

// ---------------------------------------------------------------------------
// Selected-face-only array
// ---------------------------------------------------------------------------

unittest { // Array top face count=3 along +Y. FULL-PARITY sub-face copy
           // model: the reference's poly.array REPLACES the source poly with
           // `count` fresh copies (the copy at the source position owns its
           // OWN duplicated seam verts instead of sharing the cube's shared
           // top verts). So the 8 cube verts stay (top 4 still referenced by
           // the side faces) and the array adds 3×4 = 12 fresh verts ⇒ 20
           // verts total (NOT the 16 a shared seam produced), 6 - 1 + 3 = 8
           // faces. Scoped to a PARTIAL selection — whole-mesh arrays share
           // no seam and keep the old keep+count-1 shape (see cases above).
    resetCube();
    postSelect("polygons", [4]);   // top face

    postCommand(`{"id":"mesh.array","params":{
        "count":3,"offset":[0,1,0],"weld":0
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 20,
        "verts: expected 20 (8 cube + 3×4 detached copies), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "faces: expected 8, got "  ~ m["faceCount"].integer.to!string);

    // Selection ends on all 3 array instances: the detached (repointed)
    // source at its original slot (4) plus the 2 marched copies (6, 7).
    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 3,
        "expected 3 selected instances, got " ~ sel["selectedFaces"].toString);
    assert(selFaces[0].integer == 4 && selFaces[1].integer == 6
           && selFaces[2].integer == 7,
        "expected instance face indices [4,6,7], got " ~ sel["selectedFaces"].toString);
}

// ---------------------------------------------------------------------------
// count <= 1 is a no-op
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto resp = postCommandRaw(`{"id":"mesh.array","params":{
        "count":1,"offset":[1,0,0]
    }}`);
    auto m = getModel();
    // Command returns error or status=ok with unchanged mesh — either way
    // the cube stays at 8/12/6.
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// Weld cap-to-cap — whole cube arrayed with step = cube extent KEEPS the
// doubled coincident seam face (full reference parity)
// ---------------------------------------------------------------------------

unittest { // Array the whole cube count=2 along +X with offset equal to its
           // X extent (1.0): the copy lands cap-to-cap so the source's +X
           // face and the copy's -X face coincide (4 verts weld together).
           // The reference editor KEEPS that doubled coincident seam face,
           // so the line-array path does NOT fingerprint-dedup faces.
           // After weld: 8+8-4 = 12 verts, 6+6 = 12 faces (the doubled seam
           // face IS kept — it is not dropped), 20 unique edges.
    resetCube();

    auto pre = getModel();
    assert(pre["vertexCount"].integer == 8,
        "setup: expected 8 verts, got " ~ pre["vertexCount"].integer.to!string);
    assert(pre["faceCount"].integer == 6);

    // Cube spans X ∈ [-0.5, +0.5]. Offset by 1.0 ⇒ copy verts at
    // X ∈ [+0.5, +1.5]; the seam (X=+0.5) verts coincide and weld.
    postCommand(`{"id":"mesh.array","params":{
        "count":2,"offset":[1,0,0],"weld":0.001
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12 (8+8-4 welded), got " ~ m["vertexCount"].integer.to!string);
    // 12, NOT 11: the doubled coincident +X/-X seam face is intentionally
    // KEPT for parity (the old behavior fingerprint-dedup'd it down to 11).
    assert(m["faceCount"].integer == 12,
        "faces: expected 12 (doubled seam face kept), got " ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 20,
        "edges: expected 20 (shared seam edges deduped), got " ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Undo restores the original cage
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postCommand(`{"id":"mesh.array","params":{
        "count":4,"offset":[2,0,0],"weld":0
    }}`);
    auto pre = getModel();
    assert(pre["faceCount"].integer == 24);

    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// Negative offset — array in -X direction
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postCommand(`{"id":"mesh.array","params":{
        "count":2,"offset":[-3,0,0],"weld":0
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16);
    assert(m["faceCount"].integer == 12);
    // Copy verts at X ∈ {-3.5, -2.5}.
    auto verts = m["vertices"].array;
    int seenN35 = 0, seenN25 = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (approxEq(x, -3.5)) ++seenN35;
        if (approxEq(x, -2.5)) ++seenN25;
    }
    assert(seenN35 == 4 && seenN25 == 4,
        "negative-offset copy positions wrong; got "
        ~ seenN35.to!string ~ "@-3.5, " ~ seenN25.to!string ~ "@-2.5");
}

// ---------------------------------------------------------------------------
// Vertices-mode whole-mesh fallback (mesh.array is edit-mode-orthogonal)
// ---------------------------------------------------------------------------

unittest { // In Vertices mode, mesh.array with no face selection arrays
           // the whole mesh — same fallback as mesh.mirror.
    resetCube();
    postSelect("vertices", [0, 1]);

    postCommand(`{"id":"mesh.array","params":{
        "count":2,"offset":[3,0,0],"weld":0
    }}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16 (whole-mesh fallback), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// count=2 large offset — no weld even with weld>0 default
// ---------------------------------------------------------------------------

unittest { // Default weld=0.001 is too small to merge anything when copies
           // are 5 units apart. Verify we still get 16/12/24.
    resetCube();
    postCommand(`{"id":"mesh.array","params":{
        "count":2,"offset":[5,0,0]
    }}`);  // default weld = 0.001

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16 (no weld at distance 5), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12);
}
