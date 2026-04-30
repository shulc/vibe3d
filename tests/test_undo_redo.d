// Tests for Phase A undo/redo over the HTTP API. Covers:
//   • /api/undo, /api/redo, /api/history endpoints
//   • mesh.select revert (via /api/select)
//   • mesh.transform revert (via /api/transform)
//   • mesh.* commands via /api/command (subdivide, etc.)
//   • redo timeline cleared by new action
//   • noop on empty stacks
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
//
// Note on /api/reset and history: every /api/reset call lands as a
// "Reset to " entry on the undo stack. The tests don't depend on the
// stack being empty — they only undo as many operations as they did
// after the reset, so the reset entry stays put underneath.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.algorithm : canFind;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postTransform(string body) {
    auto resp = post("http://localhost:8080/api/transform", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/transform failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(post("http://localhost:8080/api/redo", ""));
}

JSONValue getHistory() {
    return parseJSON(get("http://localhost:8080/api/history"));
}

JSONValue getSelection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

double[3] vertexAt(int idx) {
    auto m = getModel();
    auto v = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x),
        label ~ ": v" ~ idx.to!string ~ ".x expected " ~ x.to!string
        ~ ", got " ~ v[0].to!string);
    assert(approxEqual(v[1], y),
        label ~ ": v" ~ idx.to!string ~ ".y expected " ~ y.to!string
        ~ ", got " ~ v[1].to!string);
    assert(approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ ".z expected " ~ z.to!string
        ~ ", got " ~ v[2].to!string);
}

// Drains undo stack by repeatedly calling /api/undo; useful for putting the
// history into a known empty-ish state where canUndo()=false. Returns count.
int drainUndo() {
    int n = 0;
    while (true) {
        auto j = postUndo();
        if (j["status"].str != "ok") break;
        ++n;
        if (n > 100) break;  // safety
    }
    return n;
}

int undoStackSize() {
    return cast(int)getHistory()["undo"].array.length;
}

int redoStackSize() {
    return cast(int)getHistory()["redo"].array.length;
}

// ---------------------------------------------------------------------------
// Selection undo/redo (/api/select goes through MeshSelect command)
// ---------------------------------------------------------------------------

unittest { // /api/select on a fresh cube — undo restores prior empty selection
    resetCube();

    // Select two verts.
    postSelect("vertices", [2, 5]);
    auto sel = getSelection();
    assert(sel["selectedVertices"].array.length == 2,
        "expected 2 verts before undo");

    // Undo → selection cleared. record() clears redoStack on every push,
    // so after this undo redoStack must hold exactly 1 entry regardless of
    // any prior test state.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo of select should succeed");
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 0,
        "expected empty selection after undo, got "
        ~ sel["selectedVertices"].array.length.to!string);
    assert(redoStackSize() == 1, "undo should push to redo");

    // Redo → selection [2,5] back.
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo should succeed");
    sel = getSelection();
    auto verts = sel["selectedVertices"].array;
    assert(verts.length == 2 && verts[0].integer == 2 && verts[1].integer == 5,
        "expected [2,5] after redo");
}

unittest { // chained /api/select: undo unwinds in LIFO order
    resetCube();

    postSelect("vertices", [0]);
    postSelect("vertices", [1, 2, 3]);
    postSelect("edges",    [4, 5]);

    // After last select: edges mode, 2 edges selected.
    auto sel = getSelection();
    assert(sel["mode"].str == "edges");
    assert(sel["selectedEdges"].array.length == 2);

    // Undo 1 → back to vertices [1,2,3] (mode also restored).
    assert(postUndo()["status"].str == "ok");
    sel = getSelection();
    assert(sel["mode"].str == "vertices",
        "expected vertices mode restored, got " ~ sel["mode"].str);
    assert(sel["selectedVertices"].array.length == 3);

    // Undo 2 → back to vertices [0].
    assert(postUndo()["status"].str == "ok");
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 1);
    assert(sel["selectedVertices"].array[0].integer == 0);

    // Undo 3 → back to empty selection (the post-reset state).
    assert(postUndo()["status"].str == "ok");
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 0);
}

// ---------------------------------------------------------------------------
// Transform undo/redo (/api/transform goes through MeshTransform command)
// ---------------------------------------------------------------------------

unittest { // translate one vertex, then undo → original position
    resetCube();
    postSelect("vertices", [0]);          // (-0.5, -0.5, -0.5)

    postTransform(`{"kind":"translate","delta":[1.0,0.5,-0.25]}`);
    assertVertex(0, 0.5, 0.0, -0.75, "v0 after translate");

    // Undo → v0 back to corner.
    assert(postUndo()["status"].str == "ok");
    assertVertex(0, -0.5, -0.5, -0.5, "v0 restored after undo");
    // Other verts still at their cube positions.
    assertVertex(6,  0.5,  0.5,  0.5, "v6 untouched");

    // Redo → moved again.
    assert(postRedo()["status"].str == "ok");
    assertVertex(0, 0.5, 0.0, -0.75, "v0 after redo");
}

unittest { // multiple transforms: undo unwinds them in LIFO order
    resetCube();
    postSelect("vertices", [6]);          // (+0.5, +0.5, +0.5)

    postTransform(`{"kind":"translate","delta":[1,0,0]}`);   // → ( 1.5, 0.5, 0.5)
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);   // → ( 1.5, 1.5, 0.5)
    postTransform(`{"kind":"translate","delta":[0,0,1]}`);   // → ( 1.5, 1.5, 1.5)
    assertVertex(6, 1.5, 1.5, 1.5, "v6 after 3 translates");

    assert(postUndo()["status"].str == "ok");
    assertVertex(6, 1.5, 1.5, 0.5, "after 1st undo");
    assert(postUndo()["status"].str == "ok");
    assertVertex(6, 1.5, 0.5, 0.5, "after 2nd undo");
    assert(postUndo()["status"].str == "ok");
    assertVertex(6, 0.5, 0.5, 0.5, "v6 fully restored after 3rd undo");

    // Two redos → halfway forward again.
    assert(postRedo()["status"].str == "ok");
    assertVertex(6, 1.5, 0.5, 0.5, "after 1st redo");
    assert(postRedo()["status"].str == "ok");
    assertVertex(6, 1.5, 1.5, 0.5, "after 2nd redo");
}

unittest { // rotate then undo
    import std.math : PI;
    import std.format : format;
    resetCube();
    postSelect("vertices", [1]);  // (0.5, -0.5, -0.5)

    postTransform(format(
        `{"kind":"rotate","axis":[0,1,0],"angle":%.10f,"pivot":[0,0,0]}`,
        PI / 2));
    assertVertex(1, -0.5, -0.5, -0.5, "v1 after Y-rotate 90deg");

    assert(postUndo()["status"].str == "ok");
    assertVertex(1, 0.5, -0.5, -0.5, "v1 restored after undo of rotate");
}

// ---------------------------------------------------------------------------
// Mesh commands via /api/command
// ---------------------------------------------------------------------------

unittest { // mesh.subdivide: subdivides cube to 26 verts; undo → back to 8
    resetCube();
    auto m = getModel();
    int origVertCount = cast(int)m["vertices"].array.length;
    int origFaceCount = cast(int)m["faces"].array.length;
    assert(origVertCount == 8, "fresh cube should have 8 verts");
    assert(origFaceCount == 6, "fresh cube should have 6 faces");

    postCommand(`{"id":"mesh.subdivide"}`);
    m = getModel();
    int subdVertCount = cast(int)m["vertices"].array.length;
    int subdFaceCount = cast(int)m["faces"].array.length;
    assert(subdVertCount > origVertCount,
        "subdivide should grow verts, got " ~ subdVertCount.to!string);
    assert(subdFaceCount > origFaceCount,
        "subdivide should grow faces, got " ~ subdFaceCount.to!string);

    assert(postUndo()["status"].str == "ok");
    m = getModel();
    assert(cast(int)m["vertices"].array.length == origVertCount,
        "verts not restored after undo");
    assert(cast(int)m["faces"].array.length == origFaceCount,
        "faces not restored after undo");

    assert(postRedo()["status"].str == "ok");
    m = getModel();
    assert(cast(int)m["vertices"].array.length == subdVertCount,
        "verts not re-subdivided after redo");
}

unittest { // mesh.poly_bevel: select a face, bevel it, undo → cube restored
    resetCube();
    postSelect("polygons", [0]);  // back face
    auto preBevel = getModel();
    int preVerts = cast(int)preBevel["vertices"].array.length;
    int preFaces = cast(int)preBevel["faces"].array.length;

    postCommand(`{"id":"mesh.poly_bevel","params":{"shift":0.1,"inset":0.1}}`);
    auto post1 = getModel();
    assert(cast(int)post1["vertices"].array.length > preVerts,
        "poly_bevel should add verts");

    // Undo → back to plain cube.
    assert(postUndo()["status"].str == "ok");
    auto restored = getModel();
    assert(cast(int)restored["vertices"].array.length == preVerts,
        "vert count not restored after poly_bevel undo");
    assert(cast(int)restored["faces"].array.length == preFaces,
        "face count not restored after poly_bevel undo");
}

// ---------------------------------------------------------------------------
// Redo timeline & noop semantics
// ---------------------------------------------------------------------------

unittest { // new action clears the redo timeline
    resetCube();
    postSelect("vertices", [0]);
    assert(postUndo()["status"].str == "ok");
    assert(redoStackSize() == 1, "redo stack should have 1 entry after undo");

    // A new action wipes redo.
    postSelect("vertices", [1]);
    assert(redoStackSize() == 0,
        "new action should clear redo, got " ~ redoStackSize().to!string);

    // Redo is now noop.
    auto r = postRedo();
    assert(r["status"].str == "noop",
        "redo on cleared timeline should be noop, got: " ~ r.toString);
}

unittest { // /api/undo on empty stack returns noop
    resetCube();
    drainUndo();   // pop everything (including the reset entry)

    auto u = postUndo();
    assert(u["status"].str == "noop",
        "undo on empty stack should be noop, got: " ~ u.toString);
}

unittest { // /api/redo on empty stack returns noop
    resetCube();
    // Fresh state has no redoable history (reset just landed on undo).
    auto r = postRedo();
    assert(r["status"].str == "noop",
        "redo on empty stack should be noop, got: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// /api/history shape & labels
// ---------------------------------------------------------------------------

unittest { // /api/history returns {undo:[...], redo:[...]} with labels
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.subdivide"}`);

    auto h = getHistory();
    assert(h.type == JSONType.object);
    assert("undo" in h && "redo" in h);
    assert(h["undo"].type == JSONType.array);
    assert(h["redo"].type == JSONType.array);

    // Top of stack should be subdivide (most recent), then select.
    auto labels = h["undo"].array;
    assert(labels.length >= 2, "expected at least 2 entries");
    string topLabel = labels[$ - 1].str;
    string mid      = labels[$ - 2].str;
    assert(topLabel.canFind("Subdiv") || topLabel.canFind("subdiv"),
        "top label should mention subdivide, got: " ~ topLabel);
    assert(mid == "Select",
        "second-from-top label should be 'Select', got: " ~ mid);

    // After one undo, that entry shifts to redo.
    assert(postUndo()["status"].str == "ok");
    auto h2 = getHistory();
    assert(h2["redo"].array.length == 1,
        "redo should have 1 entry after one undo");
    assert(h2["redo"].array[0].str == topLabel,
        "redo label should match the undone command's label");
}

// ---------------------------------------------------------------------------
// Mixed sequence: select → transform → command → multiple undo/redo
// ---------------------------------------------------------------------------

unittest { // mixed: select v0, translate, subdivide, undo×3, redo×3
    resetCube();
    postSelect("vertices", [0]);
    postTransform(`{"kind":"translate","delta":[1,0,0]}`);
    postCommand(`{"id":"mesh.subdivide"}`);

    // Snapshot post-subdivide vert count for later redo verification.
    auto postAll = getModel();
    int postAllVerts = cast(int)postAll["vertices"].array.length;
    assert(postAllVerts > 8, "subdivide should grow past 8 verts");

    // Undo subdivide → 8 verts, v0 still translated.
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(cast(int)m["vertices"].array.length == 8,
        "after undo of subdivide, expect 8 verts, got "
        ~ m["vertices"].array.length.to!string);
    assertVertex(0, 0.5, -0.5, -0.5, "v0 still translated after undo subdivide");

    // Undo translate → v0 back to corner.
    assert(postUndo()["status"].str == "ok");
    assertVertex(0, -0.5, -0.5, -0.5, "v0 restored");

    // Undo select → empty selection.
    assert(postUndo()["status"].str == "ok");
    auto sel = getSelection();
    assert(sel["selectedVertices"].array.length == 0,
        "selection should be empty after undo of select");

    // Redo all three.
    assert(postRedo()["status"].str == "ok");
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 1
        && sel["selectedVertices"].array[0].integer == 0,
        "redo of select should bring back [0]");

    assert(postRedo()["status"].str == "ok");
    assertVertex(0, 0.5, -0.5, -0.5, "v0 retranslated after redo");

    assert(postRedo()["status"].str == "ok");
    m = getModel();
    assert(cast(int)m["vertices"].array.length == postAllVerts,
        "vert count back to subdivided after final redo");
}
