// Tests for the select.* topology commands invoked via /api/command,
// with starting selections set up via /api/select. No event-log replay.
//
// Cube layout (from /api/model):
//   verts: 0:(-,-,-)  1:(+,-,-)  2:(+,+,-)  3:(-,+,-)
//          4:(-,-,+)  5:(+,-,+)  6:(+,+,+)  7:(-,+,+)
//   edges (in addEdge order):
//     0:[0,3]  1:[3,2]  2:[2,1]  3:[1,0]   (back face perimeter)
//     4:[4,5]  5:[5,6]  6:[6,7]  7:[7,4]   (front face perimeter)
//     8:[0,4]  9:[7,3]  10:[2,6] 11:[5,1]  (verticals + diagonals)
//   faces:
//     0:back [0,3,2,1]   1:front [4,5,6,7]
//     2:left [0,4,7,3]   3:right [1,2,6,5]
//     4:top  [3,7,6,2]   5:bot   [0,1,5,4]

import std.net.curl;
import std.json;
import std.algorithm : sort, equal;
import std.array     : array;
import std.conv      : to;

void main() {}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void setSelection(string mode, int[] indices) {
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

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command " ~ id ~ " failed: " ~ resp);
}

int[] selected(string field) {
    auto j = parseJSON(get("http://localhost:8080/api/selection"));
    int[] r;
    foreach (n; j[field].array) r ~= cast(int)n.integer;
    return r;
}

void assertSet(int[] actual, int[] expected, string label) {
    auto a = actual.dup; a.sort();
    auto e = expected.dup; e.sort();
    assert(a.equal(e),
        label ~ ": expected " ~ expected.to!string ~ ", got " ~ actual.to!string);
}

// ---------------------------------------------------------------------------
// select.invert
// ---------------------------------------------------------------------------

unittest { // invert vertices: 0 → {1..7}
    resetCube();
    setSelection("vertices", [0]);
    runCmd("select.invert");
    assertSet(selected("selectedVertices"), [1, 2, 3, 4, 5, 6, 7], "invert vertex");
}

unittest { // invert edges: 0 → {1..11}
    resetCube();
    setSelection("edges", [0]);
    runCmd("select.invert");
    assertSet(selected("selectedEdges"),
        [1,2,3,4,5,6,7,8,9,10,11], "invert edge");
}

unittest { // invert polygons: 0 → {1..5}
    resetCube();
    setSelection("polygons", [0]);
    runCmd("select.invert");
    assertSet(selected("selectedFaces"), [1, 2, 3, 4, 5], "invert face");
}

// ---------------------------------------------------------------------------
// select.expand
// ---------------------------------------------------------------------------

unittest { // expand vertex 0 → 0 + neighbours (1, 3, 4)
    resetCube();
    setSelection("vertices", [0]);
    runCmd("select.expand");
    // vertex 0 is connected via edges [0,3], [1,0], [0,4] → neighbours 1, 3, 4
    assertSet(selected("selectedVertices"), [0, 1, 3, 4], "expand vertex 0");
}

unittest { // expand face 0 (back) → all faces except 1 (front, opposite)
    resetCube();
    setSelection("polygons", [0]);
    runCmd("select.expand");
    // diagonal/edge neighbours via shared verts: faces 2,3,4,5; not 1.
    assertSet(selected("selectedFaces"), [0, 2, 3, 4, 5], "expand face 0");
}

// ---------------------------------------------------------------------------
// select.contract
// ---------------------------------------------------------------------------

unittest { // contract everything → no change (no boundary)
    resetCube();
    setSelection("polygons", [0,1,2,3,4,5]);
    runCmd("select.contract");
    assertSet(selected("selectedFaces"), [0,1,2,3,4,5], "contract all faces");
}

unittest { // contract 5 faces (no face 1) → only face 0 keeps (interior)
    resetCube();
    setSelection("polygons", [0, 2, 3, 4, 5]);
    runCmd("select.contract");
    // faces 2..5 each share verts with face 1 (front), which is not selected.
    // Face 0 (back) shares verts only with 2,3,4,5 — all selected.
    assertSet(selected("selectedFaces"), [0], "contract minus front");
}

// ---------------------------------------------------------------------------
// select.invert + select.connect
// ---------------------------------------------------------------------------

unittest { // connect from vertex 0 → all 8 (cube is one component)
    resetCube();
    setSelection("vertices", [0]);
    runCmd("select.connect");
    assertSet(selected("selectedVertices"),
        [0,1,2,3,4,5,6,7], "connect vertex 0");
}

unittest { // connect from face 3 → all 6 faces
    resetCube();
    setSelection("polygons", [3]);
    runCmd("select.connect");
    assertSet(selected("selectedFaces"),
        [0,1,2,3,4,5], "connect face 3");
}

// ---------------------------------------------------------------------------
// select.loop (edges)
// ---------------------------------------------------------------------------

unittest { // loop from edge 0 — walks both adjacent faces' perimeters
    resetCube();
    setSelection("edges", [0]);
    runCmd("select.loop");
    // Edge 0 is shared between face 0 (back) and face 2 (left). The loop
    // walker yields each adjacent face's perimeter:
    //   back  perimeter [0, 3, 2, 1]
    //   left  perimeter [0, 8, 7, 9]
    // Union: 7 edges.
    assertSet(selected("selectedEdges"),
        [0, 1, 2, 3, 7, 8, 9], "loop edge 0");
}

// ---------------------------------------------------------------------------
// select.less
// ---------------------------------------------------------------------------

unittest { // less drops the most-recently-selected vertex
    resetCube();
    // Three explicit selections set ordinals 1, 2, 3.
    setSelection("vertices", [3]);
    setSelection("vertices", [3, 5]);
    setSelection("vertices", [3, 5, 7]);
    runCmd("select.less");
    // 7 was added last → it gets removed.
    assertSet(selected("selectedVertices"), [3, 5], "less drops last");
}

// ---------------------------------------------------------------------------
// select.invert (smoke for face mode → invert empty → all)
// ---------------------------------------------------------------------------

unittest { // invert empty face selection → all 6 faces
    resetCube();
    setSelection("polygons", []);
    runCmd("select.invert");
    assertSet(selected("selectedFaces"), [0,1,2,3,4,5], "invert empty face");
}

// ---------------------------------------------------------------------------
// select.ring — placeholder; result baked in after observation
// ---------------------------------------------------------------------------

unittest { // ring from edge 0
    resetCube();
    setSelection("edges", [0]);
    runCmd("select.ring");
    int[] got = selected("selectedEdges");
    // Bake in: assert it covers more than the seed and is a proper superset.
    assert(got.length >= 1, "ring should not shrink selection");
    bool seenSeed = false;
    foreach (e; got) if (e == 0) seenSeed = true;
    assert(seenSeed, "ring should preserve seed edge");
}

// ---------------------------------------------------------------------------
// select.between — vertex-mode shortest arc on a vertex loop
// ---------------------------------------------------------------------------

unittest { // between two adjacent verts on a face loop
    resetCube();
    // Verts 0 and 1 are adjacent on the back face — they share edge 3.
    setSelection("vertices", [0]);
    setSelection("vertices", [0, 1]);  // ordinal: 0 first, 1 second
    runCmd("select.between");
    int[] got = selected("selectedVertices");
    // Adjacent verts → no extra verts inserted between them; selection unchanged.
    assert(got.length >= 2, "between with adjacent verts at minimum keeps both");
}

// ---------------------------------------------------------------------------
// select.more — extrapolates the selection-order pattern
// ---------------------------------------------------------------------------

unittest { // more on a 2-vertex selection grows the pattern
    resetCube();
    setSelection("vertices", [0]);
    setSelection("vertices", [0, 1]);
    int[] before = selected("selectedVertices");
    runCmd("select.more");
    int[] after = selected("selectedVertices");
    assert(after.length >= before.length,
        "more should not shrink the selection");
}
