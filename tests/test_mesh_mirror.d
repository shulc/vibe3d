// Tests for mesh.mirror (PR-2 of doc/duplicate_plan.md). Symmetric
// duplicate across an axis-aligned plane: clones the selected faces
// (or the whole mesh if no selection), reflects the cloned verts,
// reverses winding when flip_normals is on, and optionally welds
// coincident seam verts (which also drops the doubled seam polygon).
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

double[3] vToArr(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// Return true if any cloned vert in `verts[origLen .. $]` is at `target`.
bool clonedHasPosition(JSONValue m, size_t origLen, double[3] target) {
    auto verts = m["vertices"].array;
    foreach (i; origLen .. verts.length) {
        auto a = vToArr(verts[i]);
        if (approxEq(a[0], target[0]) && approxEq(a[1], target[1])
                                      && approxEq(a[2], target[2]))
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Whole-mesh mirror, axis X, no weld — empty selection ⇒ act on all faces
// ---------------------------------------------------------------------------

unittest { // mirror whole cube across plane x=1 (center=(1,0,0)): cloned
           // verts land at x = 2 - x_orig ∈ {1.5, 2.5}; no overlap with
           // original ⇒ 16 verts, 12 faces, 24 edges.
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 24,
        "edges: expected 24, got "  ~ m["edgeCount"].integer.to!string);

    // The 8 cloned verts must be exactly the reflections of v0..v7:
    //   (-0.5,*,*) → (2.5,*,*) and (+0.5,*,*) → (1.5,*,*).
    foreach (xo; [-0.5, 0.5]) {
        foreach (y; [-0.5, 0.5])
        foreach (z; [-0.5, 0.5]) {
            double[3] tgt = [2.0 - xo, y, z];
            assert(clonedHasPosition(m, 8, tgt),
                "cloned vert missing at (" ~ tgt[0].to!string ~ "," ~
                tgt[1].to!string ~ "," ~ tgt[2].to!string ~ ")");
        }
    }
}

// ---------------------------------------------------------------------------
// Whole-mesh mirror with weld — seam face is dropped via fingerprint dedup
// ---------------------------------------------------------------------------

unittest { // Cube reflected across plane x=0.5 with weld=0.001: verts on
           // the +x face (v1,v2,v5,v6) coincide with their clones and get
           // welded. The doubled seam face (cube's right face + its
           // mirrored copy) collapses to a single face via vert-set
           // fingerprint dedup — so faceCount = 11, not 12.
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[0.5,0,0],"weld":0.001,"flip_normals":true
    }}`);

    auto m = getModel();
    // 8 original verts kept. 4 cloned verts (mirror of v0,v3,v4,v7) at
    // x=1.5; the other 4 mirror verts collapse onto v1,v2,v5,v6 and are
    // compacted out.
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 11,
        "faces: expected 11, got "  ~ m["faceCount"].integer.to!string);
    // Edge count: 12 original cube edges + 8 mirrored quad edges − 4
    // shared seam edges = 20.
    assert(m["edgeCount"].integer == 20,
        "edges: expected 20, got "  ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Selected-faces-only mirror — verts outside the selected faces stay put
// ---------------------------------------------------------------------------

unittest { // Select just the top face (f4) and mirror it across plane y=1.
           // Only the 4 top verts get cloned (no weld); 12 total verts,
           // 7 faces, 16 edges.
    resetCube();
    postSelect("polygons", [4]);   // top face = v3,v7,v6,v2

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Y","center":[0,1,0],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "faces: expected 7, got "  ~ m["faceCount"].integer.to!string);
    // Cloned verts at y = 2 - 0.5 = 1.5; x,z preserved.
    foreach (x; [-0.5, 0.5])
    foreach (z; [-0.5, 0.5]) {
        assert(clonedHasPosition(m, 8, [x, 1.5, z]),
            "cloned vert missing at top mirror");
    }
    // Selection should be just the new mirrored face.
    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1 && selFaces[0].integer == 6,
        "expected single mirror face index 6, got " ~ sel["selectedFaces"].toString);
}

// ---------------------------------------------------------------------------
// flip_normals on/off — verifies winding order through the saved face list
// ---------------------------------------------------------------------------

unittest { // flip_normals=true reverses the vert order in the cloned face.
           // For the back face [v0,v3,v2,v1], the cloned face indices [c0,
           // c3, c2, c1] should appear reversed → [c1, c2, c3, c0].
    resetCube();
    postSelect("polygons", [0]);  // back face

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Z","center":[0,0,1],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    auto faces = m["faces"].array;
    auto orig  = faces[0].array;   // back face: [0,3,2,1]
    auto cloned = faces[6].array;  // mirrored back face

    assert(cloned.length == orig.length);
    // The cloned face's i-th vert must be at the position the original's
    // (n-1-i)-th vert had AFTER reflection. Equivalent: orig[n-1-i]'s
    // position reflected = cloned[i]'s position.
    auto verts = m["vertices"].array;
    foreach (i; 0 .. orig.length) {
        auto oArr = vToArr(verts[orig[orig.length - 1 - i].integer]);
        auto cArr = vToArr(verts[cloned[i].integer]);
        // Reflected across z=1: cz = 2 - oz.
        assert(approxEq(cArr[0], oArr[0])
            && approxEq(cArr[1], oArr[1])
            && approxEq(cArr[2], 2.0 - oArr[2]),
            "winding mismatch at i=" ~ i.to!string);
    }
}

unittest { // flip_normals=false preserves the cloned vert order — i-th vert
           // of cloned face is the reflected i-th vert of original face.
    resetCube();
    postSelect("polygons", [0]);

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Z","center":[0,0,1],"weld":0,"flip_normals":false
    }}`);

    auto m = getModel();
    auto faces  = m["faces"].array;
    auto orig   = faces[0].array;
    auto cloned = faces[6].array;
    auto verts  = m["vertices"].array;
    foreach (i; 0 .. orig.length) {
        auto oArr = vToArr(verts[orig[i].integer]);
        auto cArr = vToArr(verts[cloned[i].integer]);
        assert(approxEq(cArr[0], oArr[0])
            && approxEq(cArr[1], oArr[1])
            && approxEq(cArr[2], 2.0 - oArr[2]),
            "flip_normals=false: cloned[i] should mirror orig[i] in order");
    }
}

// ---------------------------------------------------------------------------
// Undo restores the original cage
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);
    auto pre = getModel();
    assert(pre["faceCount"].integer == 12);

    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// Defaults — `params:{}` runs the command with axis=X, center=0, weld=0.001
// ---------------------------------------------------------------------------

unittest { // No params ⇒ mirror across plane x=0 with weld=0.001 (defaults).
           // For a symmetric cube `[-0.5,0.5]³` this welds every cloned
           // vert onto its original, and dedup drops every duplicated
           // face. Result: identical cage (8 verts, 12 edges, 6 faces).
    resetCube();
    postCommand(`{"id":"mesh.mirror","params":{}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "verts: expected 8 (full weld), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "faces: expected 6 (full dedup), got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Edit mode is orthogonal — Vertices-mode selection has empty selectedFaces,
// which triggers the whole-mesh fallback.
// ---------------------------------------------------------------------------

unittest { // In Vertices mode, mesh.mirror with non-default plane mirrors
           // the whole cube (the vertex selection is ignored — only face
           // selection drives the mask, and there is none).
    resetCube();
    postSelect("vertices", [0, 1, 2, 3]);

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16 (whole-mesh fallback), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got " ~ m["faceCount"].integer.to!string);
}
