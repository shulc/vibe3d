// Array / radial array: the hidden-face law and the degenerate scripted apply
// (capture K-AR, toolcards/shared_layer2/findings_K-AR.md + fixtures/K-AR.json).
//
// Rig: the unit cube; A = the top face (y +0.5), B = the bottom face (y -0.5).
//   * Hide deselects (H_UNHIDE, AR_H): hiding B drops it from the selection,
//     unhide does not restore it, and an array of {A} after hiding B copies A
//     alone.
//   * A degenerate scripted tool.doApply answers ok and records exactly ONE
//     undo entry that changes nothing (AR_E replace on, AR_E_NR replace off,
//     AR_1 radial count 1). The empty operand hides ALL faces: a mesh of loose
//     points is not empty (AR_E0 copies them).
// The undo-depth delta is read across the doApply alone; history is cleared
// after each rig so the 50-entry cap never clips the count.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

JSONValue cmdJ(string s) {
    return parseJSON(post(testBaseUrl() ~ "/api/command", s));
}

void cmd(string s) {
    auto r = cmdJ(s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void selectFaces(int[] idx, string action = "") {
    string list = idx.to!string;
    string extra = action.length ? `,"action":"` ~ action ~ `"` : "";
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":` ~ list ~ extra ~ `}`));
}

JSONValue getJ(string path) { return parseJSON(cast(string) get(testBaseUrl() ~ path)); }
size_t undoDepth() { return getJ("/api/history")["undo"].array.length; }
long[] selectedFaces() {
    long[] r;
    foreach (v; getJ("/api/selection")["selectedFaces"].array) r ~= v.integer;
    return r;
}
JSONValue model() { return getJ("/api/model"); }

void resetCube() {
    cmd(commandBody("scene.reset"));
    cmd("history.clear");
    auto m = model();
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
           "rig floor: the reset cube is 8 v / 6 f: " ~ m["vertexCount"].toString);
}

// Face indices of A (top) and B (bottom), read from the model, not assumed.
void topBottom(out int a, out int b) {
    auto m = model();
    auto verts = m["vertices"].array;
    int nA, nB;
    foreach (fi, f; m["faces"].array) {
        double y = 0;
        foreach (vi; f.array) y += verts[cast(size_t) vi.integer].array[1].floating;
        y /= f.array.length;
        if (y > 0.4)  { a = cast(int) fi; ++nA; }
        if (y < -0.4) { b = cast(int) fi; ++nB; }
    }
    assert(nA == 1 && nB == 1, "rig floor: one top and one bottom face");
}

// The subject: one scripted doApply. ok, one record, mesh unchanged.
void assertOneRecordNoEdit(string cell) {
    const d0 = undoDepth();
    assert(d0 < 40, cell ~ ": history headroom under the 50-entry cap");
    auto r = cmdJ("tool.doApply");
    assert(r["status"].str == "ok",
           cell ~ ": a degenerate scripted apply answers ok, got " ~ r.toString);
    const d1 = undoDepth();
    assert(d1 == d0 + 1, cell ~ ": exactly ONE undo record, got "
           ~ (cast(long) d1 - cast(long) d0).to!string);
    auto m = model();
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
           cell ~ ": the mesh is unchanged");
}

void hideAllFaces() {
    selectFaces([0, 1, 2, 3, 4, 5]);
    cmd("mesh.hide");
    assert(selectedFaces().length == 0, "rig: hide drops the selection");
}

unittest { // AR_E: replace on, every face hidden
    resetCube();
    hideAllFaces();
    cmd("tool.set mesh.arrayTool on");
    cmd("tool.attr mesh.arrayTool replace true");
    cmd("tool.attr mesh.arrayTool numZ 1");
    assertOneRecordNoEdit("AR_E");
    cmd("tool.set mesh.arrayTool off");
}

unittest { // AR_E_NR: replace off, every face hidden
    resetCube();
    hideAllFaces();
    cmd("tool.set mesh.arrayTool on");
    cmd("tool.attr mesh.arrayTool replace false");
    cmd("tool.attr mesh.arrayTool numZ 1");
    assertOneRecordNoEdit("AR_E_NR");
    cmd("tool.set mesh.arrayTool off");
}

unittest { // AR_1: radial count 1, whole cube
    resetCube();
    cmd("tool.set mesh.radialArrayTool on");
    cmd("tool.attr mesh.radialArrayTool count 1");
    assertOneRecordNoEdit("AR_1");
    cmd("tool.set mesh.radialArrayTool off");
}

unittest { // radial, count 2, every face hidden: the shared empty operand
    resetCube();
    hideAllFaces();
    cmd("tool.set mesh.radialArrayTool on");
    cmd("tool.attr mesh.radialArrayTool count 2");
    assertOneRecordNoEdit("RAD_E");
    cmd("tool.set mesh.radialArrayTool off");
}

unittest { // H_UNHIDE: unhide does not restore the dropped selection
    resetCube();
    int a, b;
    topBottom(a, b);
    selectFaces([b]);
    assert(selectedFaces() == [cast(long) b], "rig: B selected");
    cmd("mesh.hide");
    assert(selectedFaces().length == 0, "H_UNHIDE: hide drops B from the selection");
    cmd("mesh.unhideAll");
    assert(selectedFaces().length == 0,
           "H_UNHIDE: unhide must not restore the selection, got "
           ~ selectedFaces().to!string);
}

unittest { // AR_H: hide B, add A, array -> one copy of A only
    resetCube();
    int a, b;
    topBottom(a, b);
    selectFaces([b]);
    cmd("mesh.hide");
    selectFaces([a], "add");
    assert(selectedFaces() == [cast(long) a], "AR_H: the selection is A alone, got "
           ~ selectedFaces().to!string);
    cmd("tool.set mesh.arrayTool on");
    cmd("tool.attr mesh.arrayTool numX 2");
    cmd("tool.attr mesh.arrayTool numY 1");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool offX 2");
    const d0 = undoDepth();
    cmd("tool.doApply");
    assert(undoDepth() == d0 + 1, "AR_H: one record");
    auto m = model();
    assert(m["vertexCount"].integer == 12 && m["faceCount"].integer == 7,
           "AR_H: one copy of A (12 v / 7 f), got " ~ m["vertexCount"].toString
           ~ " v / " ~ m["faceCount"].toString ~ " f");
    auto verts = m["vertices"].array;
    auto copy = m["faces"].array[6].array;
    double cx = 0, cy = 0;
    foreach (vi; copy) {
        cx += verts[cast(size_t) vi.integer].array[0].floating;
        cy += verts[cast(size_t) vi.integer].array[1].floating;
    }
    cx /= copy.length; cy /= copy.length;
    assert(abs(cx - 2) < 1e-4 && abs(cy - 0.5) < 1e-4,
           "AR_H: the copy is A at +2 X (centroid (2,0.5)), got ("
           ~ cx.to!string ~ "," ~ cy.to!string ~ ")");
    cmd("tool.set mesh.arrayTool off");
}
