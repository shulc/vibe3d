// Tests for the interactive EdgeExtendTool (factory id `edge.extend`),
// Phase 4a of doc/edge_extend_plan.md.
//
// The interactive surface EMBEDS an XfrmTransformTool (Move bank) and routes the
// drag gesture into the Extend op's `offset` param, RE-EVALUATING the kernel from
// the pre-extend cage each tick (it does NOT vertex-transform the post-extend
// ridge). A real viewport gizmo drag needs a camera + screen projection that is
// out of scope for an HTTP test; the SAME "write params + re-run the kernel"
// mechanism the drag uses is exercised deterministically through the headless
// tool path (tool.set / tool.attr / tool.doApply), which is exactly what the
// drag's drain→param→rebuildPreview loop drives.
//
// Asserts:
//   1. activate() applies the defaults — selecting one interior cube edge and
//      turning the tool on builds the 10v/7f identity ridge.
//   2. The headless re-evaluate is FAITHFUL: with segments=3 + an Offset, the
//      three rings sit at k/3 fractions of the offset (the kernel re-ran and
//      distributed fractionally — NOT an outer-ring-only transform).
//   3. deactivate (tool.set off) after a doApply leaves EXACTLY ONE undo entry.
//   4. Undo restores the pre-activation mesh.
//   5. tool ↔ command parity — same params via the tool vs mesh.edge_extend give
//      identical geometry.
//
// The kernel + one-shot command are covered by tests/test_edge_extend.d.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.algorithm : sort;

void main() {}

// --- HTTP helpers (same shapes as tests/test_edge_extend.d) ----------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset grid failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post("http://localhost:8080/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

string cmdRaw(string s) { return cast(string)post("http://localhost:8080/api/command", s); }

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
}

// Load a unit cube centred at (cx,0,0) using the SAME vertex order + face winding
// as the built-in makeCube() (so face normals — and thus the inset perpendicular
// drop — point the captured-number way). The off-origin centre proves the
// interactive R/S pivot (sel-center) is distinct from the command pivot (origin).
void loadCubeAt(double cx) {
    string v(double x, double y, double z) {
        return "[" ~ x.to!string ~ "," ~ y.to!string ~ "," ~ z.to!string ~ "]";
    }
    string verts =
        "[" ~ v(cx-0.5,-0.5,-0.5) ~ "," ~ v(cx+0.5,-0.5,-0.5) ~ ","
            ~ v(cx+0.5, 0.5,-0.5) ~ "," ~ v(cx-0.5, 0.5,-0.5) ~ ","
            ~ v(cx-0.5,-0.5, 0.5) ~ "," ~ v(cx+0.5,-0.5, 0.5) ~ ","
            ~ v(cx+0.5, 0.5, 0.5) ~ "," ~ v(cx-0.5, 0.5, 0.5) ~ "]";
    // makeCube() winding: [0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4].
    string faces =
        "[[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]";
    postLoadMesh(`{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`);
}

// Arm the hidden one-shot drag-pivot override on the active EdgeExtendTool, so the
// next tool.doApply runs the kernel about `p` (the sel-center the interactive R/S
// drag would freeze) instead of the world origin. JSON-array form (no argstring
// vec quoting). Consumed by applyHeadless; clears itself after one apply.
void setDragPivot(V3 p) {
    auto body = `{"id":"tool.attr","params":{"_positional":["edge.extend","_dragPivot",`
        ~ `[` ~ p.x.to!string ~ `,` ~ p.y.to!string ~ `,` ~ p.z.to!string ~ `]]}}`;
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "_dragPivot set failed: " ~ resp);
}

// Find the top-front edge (cx-0.5,.5,.5)-(cx+0.5,.5,.5) of a cube centred at cx
// and select it (edge mode).
void selectTopFrontAt(JSONValue m, double cx) {
    int va = vertAt(m, V3(cx-0.5, 0.5, 0.5));
    int vb = vertAt(m, V3(cx+0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "off-origin top-front endpoints not found");
    int ei = edgeIndex(m, va, vb);
    assert(ei >= 0, "off-origin top-front edge not found");
    postSelect("edges", [ei]);
}

JSONValue postUndo()    { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()    { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getHistory()  { return parseJSON(get("http://localhost:8080/api/history")); }

// --- geometry helpers ------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
double dot3(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a) { return sqrt(dot3(a, a)); }

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p, double tol = 1e-4) {
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    return -1;
}

int countAt(JSONValue m, V3 p, double tol = 1e-4) {
    int n = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) ++n;
    return n;
}

bool sameVertexSet(JSONValue a, JSONValue b) {
    if (a["vertices"].array.length != b["vertices"].array.length) return false;
    foreach (i; 0 .. a["vertices"].array.length)
        if (vertAt(b, vert(a, i)) < 0) return false;
    return true;
}

// Select the cube top-front interior edge (-0.5,.5,.5)-(.5,.5,.5).
void selectCubeTopFront(JSONValue before) {
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube top-front edge not found");
    postSelect("edges", [ei]);
}

// ---------------------------------------------------------------------------
// 1. Defaults apply: one interior edge + tool on + doApply (no param change)
//    builds the 10v/7f identity ridge (inset=0.1, shift=0, identity TRS). Like
//    the extrude template, activate() leaves the mesh clean (so the headless
//    pre-snapshot stays clean); the kernel runs on doApply.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    cmd("tool.set edge.extend on");
    cmd("tool.doApply");               // applies the defaults
    auto m = getModel();
    assert(m["vertexCount"].integer == 10, "default apply: expected 10 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7, "default apply: expected 7 faces, got "
        ~ m["faceCount"].integer.to!string);
    // Identity ridge verts at (±0.4, 0.4, 0.4).
    assert(vertAt(m, V3( 0.4, 0.4, 0.4)) >= 0, "ridge vert (0.4,0.4,0.4) missing");
    assert(vertAt(m, V3(-0.4, 0.4, 0.4)) >= 0, "ridge vert (-0.4,0.4,0.4) missing");
    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 2. Re-evaluate FAITHFULNESS: segments=3 + an Offset distributes across rings
//    at k/3 fractions — proving the tool RE-RUNS the kernel from the cage (not a
//    vertex-transform of the outer ring). This is the regression guard for the
//    "write params + re-run" law (§4.2). Driven through the headless apply, the
//    same kernel the drag's rebuildPreview re-runs.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend segments 3");   // set segments FIRST
    cmd("tool.attr edge.extend offsetY 0.3");
    cmd("tool.doApply");
    auto m = getModel();

    // 3 ring levels per endpoint × 2 endpoints = 6 new verts + 8 cube = 14 verts;
    // 3 bridge quads per edge.
    assert(m["vertexCount"].integer == 14, "segs3: expected 14 verts, got "
        ~ m["vertexCount"].integer.to!string);

    // For the (0.4,_,0.4) column (endpoint 6 side), inset holds X,Z at full ±0.4
    // on every ring; ring k Y = 0.4 + (k/3)·0.3, k=1..3 → 0.5, 0.6, 0.7.
    // Likewise the (-0.4,_,0.4) column.
    foreach (xs; [0.4, -0.4]) {
        foreach (k; 1 .. 4) {
            double y = 0.4 + (cast(double)k / 3.0) * 0.3;
            assert(vertAt(m, V3(xs, y, 0.4)) >= 0,
                "segs3 faithful: ring k=" ~ k.to!string ~ " vert ("
                ~ xs.to!string ~ "," ~ y.to!string ~ ",0.4) missing — re-eval failed");
        }
    }
    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 3. deactivate (tool.set off) after a doApply leaves EXACTLY ONE undo entry.
//    The headless doApply commits via ToolDoApplyCommand (one entry); turning
//    the tool off must NOT add a second "Edge Extend" entry (built was reset).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    cmd("history.clear");                 // drop the /api/select entry from the count
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend offsetY 0.3");
    cmd("tool.doApply");
    auto afterApply = getHistory();
    assert(afterApply["undo"].array.length == 1,
        "expected ONE undo entry after doApply, got "
        ~ afterApply["undo"].array.length.to!string);
    // Turning the tool OFF (deactivate) must NOT add a second extend entry — the
    // headless ToolDoApplyCommand already owns the single commit, and `built` was
    // reset by applyHeadless so deactivate's commitEdit() is a no-op.
    cmd("tool.set edge.extend off");
    auto afterOff = getHistory();
    assert(afterOff["undo"].array.length == 1,
        "tool.set off double-committed: expected ONE undo entry, got "
        ~ afterOff["undo"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// 4. Undo after a tool apply restores the pre-activation mesh exactly.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend offsetY 0.3");
    cmd("tool.doApply");
    cmd("tool.set edge.extend off");
    auto after = getModel();
    assert(after["vertexCount"].integer == 10, "tool apply: expected 10 verts");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "verts not restored on undo: " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "faces not restored on undo");
    assert(m["edgeCount"].integer == before["edgeCount"].integer,
        "edges not restored on undo");
    assert(sameVertexSet(before, m) && sameVertexSet(m, before),
        "undo: vertex positions differ from pre-activation mesh");
}

// ---------------------------------------------------------------------------
// 5. tool ↔ command parity (cube interior edge, full TRS): same params via the
//    tool path vs the one-shot mesh.edge_extend command → identical geometry.
// ---------------------------------------------------------------------------
unittest {
    // Reference: the one-shot command (offsetY + rotateZ + scaleX, inset/shift).
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":` ~
        `{"inset":0.1,"shift":0.2,"offsetY":0.3,"rotateZ":30,"scaleX":2}}`);
    auto cmdModel = getModel();

    // Tool path: same selection + same params via tool.attr + doApply.
    resetCube();
    auto before2 = getModel();
    selectCubeTopFront(before2);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend inset 0.1");
    cmd("tool.attr edge.extend shift 0.2");
    cmd("tool.attr edge.extend offsetY 0.3");
    cmd("tool.attr edge.extend rotateZ 30");
    cmd("tool.attr edge.extend scaleX 2");
    cmd("tool.doApply");
    cmd("tool.set edge.extend off");
    auto toolModel = getModel();

    assert(toolModel["vertexCount"].integer == cmdModel["vertexCount"].integer,
        "parity: vertex counts differ (tool " ~ toolModel["vertexCount"].integer.to!string ~
        " vs cmd " ~ cmdModel["vertexCount"].integer.to!string ~ ")");
    assert(toolModel["faceCount"].integer == cmdModel["faceCount"].integer,
        "parity: face counts differ");
    assert(toolModel["edgeCount"].integer == cmdModel["edgeCount"].integer,
        "parity: edge counts differ");
    assert(sameVertexSet(cmdModel, toolModel) && sameVertexSet(toolModel, cmdModel),
        "parity: tool vertex positions differ from the command's");
}

// ===========================================================================
// Phase 4b — interactive Rotate / Scale banks drive rotateDeg / scale about the
// FROZEN selection-center pivot. A real viewport gizmo drag needs a camera +
// screen projection out of scope for an HTTP test, so — exactly like the 4a
// move-drag test above — these drive the SAME effect deterministically through
// the headless path (tool.attr writes rotateZ/scaleX; the hidden `_dragPivot`
// param arms the one-shot sel-center pivot the drag would freeze; tool.doApply
// re-runs the kernel). The frozen numbers are captured reference values.
// ===========================================================================

// 6. Rotate-bank drag (off-origin cube): rotateZ≈55.4° about the sel-center
//    (2,0.5,0.5) → the two new verts at the captured positions.
unittest {
    loadCubeAt(2.0);
    auto m0 = getModel();
    selectTopFrontAt(m0, 2.0);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend rotateZ 55.4");
    setDragPivot(V3(2.0, 0.5, 0.5));   // sel-center the drag freezes
    cmd("tool.doApply");
    auto m = getModel();
    assert(m["vertexCount"].integer == 10, "rotate 4b: expected 10 verts");
    // Captured ridge verts for rotZ=55.4°, inset=0.1, sel-center pivot.
    assert(vertAt(m, V3( 2.18392,  0.81157, 0.4)) >= 0,
        "rotate 4b: ridge vert (2.18392,0.81157,0.4) missing");
    assert(vertAt(m, V3( 1.81608, -0.01157, 0.4)) >= 0,
        "rotate 4b: ridge vert (1.81608,-0.01157,0.4) missing");
    cmd("tool.set edge.extend off");
}

// 7. Scale-bank drag (off-origin cube): scaleX≈6.434 about the sel-center
//    (2,0.5,0.5) → the two new verts at the captured positions.
unittest {
    loadCubeAt(2.0);
    auto m0 = getModel();
    selectTopFrontAt(m0, 2.0);
    cmd("tool.set edge.extend on");
    // sclX=6.43376 reproduces the captured ridge X = 1.9 + 0.5·s = 5.11688.
    cmd("tool.attr edge.extend scaleX 6.43376");
    setDragPivot(V3(2.0, 0.5, 0.5));
    cmd("tool.doApply");
    auto m = getModel();
    assert(m["vertexCount"].integer == 10, "scale 4b: expected 10 verts");
    // Captured ridge verts for sclX≈6.434, inset=0.1, sel-center pivot.
    assert(vertAt(m, V3( 5.11688, 0.4, 0.4)) >= 0,
        "scale 4b: ridge vert (5.11688,0.4,0.4) missing");
    assert(vertAt(m, V3(-1.11688, 0.4, 0.4)) >= 0,
        "scale 4b: ridge vert (-1.11688,0.4,0.4) missing");
    cmd("tool.set edge.extend off");
}

// 8. PIVOT DISTINCTION: the SAME rotateZ via the tool (sel-center pivot) vs via
//    the one-shot mesh.edge_extend command (world origin) produce DIFFERENT
//    geometry on an off-origin cube — proving the tool's interactive R/S pivots
//    at the sel-center while the command pivots at the origin.
unittest {
    // Tool path (sel-center pivot (2,0.5,0.5)).
    loadCubeAt(2.0);
    auto mt0 = getModel();
    selectTopFrontAt(mt0, 2.0);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend rotateZ 55.4");
    setDragPivot(V3(2.0, 0.5, 0.5));
    cmd("tool.doApply");
    cmd("tool.set edge.extend off");
    auto toolM = getModel();

    // Command path (world-origin pivot), same selection + same rotateZ + inset.
    loadCubeAt(2.0);
    auto mc0 = getModel();
    selectTopFrontAt(mc0, 2.0);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"rotateZ":55.4}}`);
    auto cmdM = getModel();

    // Same topology (10v/7f), DIFFERENT positions: the sel-center ridge verts
    // (captured above) must be ABSENT from the origin-pivot command result.
    assert(toolM["vertexCount"].integer == cmdM["vertexCount"].integer,
        "pivot distinction: counts should still match (only positions differ)");
    assert(vertAt(cmdM, V3(2.18392,  0.81157, 0.4)) < 0
        && vertAt(cmdM, V3(1.81608, -0.01157, 0.4)) < 0,
        "pivot distinction: command (origin pivot) produced the tool's sel-center "
        ~ "ridge verts — the tool is NOT using the sel-center pivot");
    assert(!sameVertexSet(toolM, cmdM),
        "pivot distinction: tool (sel-center) and command (origin) geometry are "
        ~ "identical — the pivot distinction collapsed");
}

// 9. segments>1 with a rotate drag: each ring rotates fractionally (k/N angle)
//    about the FROZEN pivot. segs=2, rotZ=30 about the origin-cube sel-center
//    (0,0.5,0.5) → ring 1 at 15°, ring 2 at 30°, both at the captured positions.
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend segments 2");
    cmd("tool.attr edge.extend rotateZ 30");
    setDragPivot(V3(0.0, 0.5, 0.5));   // origin-cube top-front sel-center
    cmd("tool.doApply");
    auto m = getModel();
    // 2 rings × 2 endpoints = 4 new verts + 8 cube = 12.
    assert(m["vertexCount"].integer == 12, "seg2 rotate 4b: expected 12 verts, got "
        ~ m["vertexCount"].integer.to!string);
    // Ring 1 (k=1, 15° about (0,0.5,0.5)).
    assert(vertAt(m, V3( 0.38296, 0.52941, 0.4)) >= 0,
        "seg2 rotate: ring1 vert (0.38296,0.52941,0.4) missing");
    assert(vertAt(m, V3(-0.38296, 0.27059, 0.4)) >= 0,
        "seg2 rotate: ring1 vert (-0.38296,0.27059,0.4) missing");
    // Ring 2 (k=2, full 30°).
    assert(vertAt(m, V3( 0.33301, 0.65, 0.4)) >= 0,
        "seg2 rotate: ring2 vert (0.33301,0.65,0.4) missing");
    assert(vertAt(m, V3(-0.33301, 0.15, 0.4)) >= 0,
        "seg2 rotate: ring2 vert (-0.33301,0.15,0.4) missing");
    cmd("tool.set edge.extend off");
}

// 10. ONE undo entry per session for an R/S tool apply; undo restores the
//     pre-activation mesh exactly (off-origin cube, rotate path).
unittest {
    loadCubeAt(2.0);
    auto before = getModel();
    selectTopFrontAt(before, 2.0);
    cmd("history.clear");                 // drop the /api/select + load-mesh entries
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend rotateZ 55.4");
    setDragPivot(V3(2.0, 0.5, 0.5));
    cmd("tool.doApply");
    auto afterApply = getHistory();
    assert(afterApply["undo"].array.length == 1,
        "rotate 4b undo: expected ONE undo entry after doApply, got "
        ~ afterApply["undo"].array.length.to!string);
    cmd("tool.set edge.extend off");
    auto afterOff = getHistory();
    assert(afterOff["undo"].array.length == 1,
        "rotate 4b undo: tool.set off double-committed");

    auto u = postUndo();
    assert(u["status"].str == "ok", "rotate 4b undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "rotate 4b undo: verts not restored");
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "rotate 4b undo: faces not restored");
    assert(sameVertexSet(before, m) && sameVertexSet(m, before),
        "rotate 4b undo: positions differ from pre-activation mesh");
}
