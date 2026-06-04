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
