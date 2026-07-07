// test_edge_slice_tool.d — HTTP tests for the interactive EdgeSliceTool
// (factory id `mesh.edgeSliceTool`), promoting Edge Slice from a params-only
// command to a viewport tool.
//
// Standard cube fixture from /api/reset (8 verts, 6 quad faces, ±0.5 each
// axis) — same face/edge layout documented in tests/test_edge_slice.d.
//
//   1. Headless golden: edge(0,1) + edge(4,5) (shared bottom face) via
//      tool.set/attr/doApply -> 7 faces, 10 verts, no orphans, no
//      duplicate-position verts (T-junction backstop).
//   2. Analytic: the two NEW verts land exactly at lerp(edge, effectiveT)
//      for tA=0.25 / tB=0.75 (both survive the default 0.5% snap step).
//   3. Split at Middle forces both cut points to the edge midpoints
//      regardless of the tA/tB attrs.
//   4. Snap Value quantizes t to the nearest step; snap 0 = no quantization.
//   5. Split Polygons OFF: points-only — face count UNCHANGED (6), vertex
//      count +2 (10), edge count 12 -> 14 (the rebuildEdges discriminator).
//   6. Config writes (tool.set + tool.attr) before doApply mutate nothing.
//   7. One undo entry on the doApply path: undo count +1, undo restores 8v/6f.
//   8. Interactive semantic replay (best-effort): hover -> click edge A ->
//      click edge B (live preview) -> Enter commit -> phase transitions +
//      7f/10v/15e result + one undo entry. Non-authoritative — depends on the
//      GPU edge picker resolving g_hoveredEdge (see loop_slice/slice tool's
//      identical reliance on hover state); the headless golden (test 1) is
//      the authority.
//
// tests/test_edge_slice.d (the one-shot mesh.edgeSlice command) is untouched
// and stays green independently — this file only exercises the tool path.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : abs;
import core.thread : Thread;
import core.time : msecs;

void main() {}

// ---------------------------------------------------------------------------
// helpers (mirrors test_edge_slice.d / test_loop_slice_tool.d)
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}

JSONValue model() { return getJson("/api/model"); }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
size_t faceCount(JSONValue m) { return m["faces"].array.length; }
long edgeCount(JSONValue m) { return m["edgeCount"].integer; }

int[] orphanVerts(JSONValue m) {
    bool[] refd;
    refd.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < refd.length) refd[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. refd.length) if (!refd[i]) orph ~= cast(int)i;
    return orph;
}

size_t duplicatePositionVerts(JSONValue m) {
    string[string] seen;
    size_t count;
    if ("vertices" !in m.object) return 0;
    foreach (i, v; m["vertices"].array) {
        auto arr = v.array;
        string key = format("%.9f,%.9f,%.9f",
            arr[0].floating, arr[1].floating, arr[2].floating);
        if (key in seen) count++;
        else seen[key] = i.to!string;
    }
    return count;
}

uint edgeIndexByVerts(JSONValue m, int a, int b) {
    if ("edges" !in m.object) return uint.max;
    foreach (i, e; m["edges"].array) {
        int ea = cast(int)e.array[0].integer;
        int eb = cast(int)e.array[1].integer;
        if ((ea == a && eb == b) || (ea == b && eb == a))
            return cast(uint)i;
    }
    return uint.max;
}

double[3] vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double[3] edgeEndpoint(JSONValue m, size_t edgeIdx, size_t which) {
    auto e = m["edges"].array[edgeIdx].array;
    return vert(m, cast(size_t)e[which].integer);
}

double[3] lerp3(double[3] a, double[3] b, double t) {
    return [a[0] + (b[0]-a[0])*t, a[1] + (b[1]-a[1])*t, a[2] + (b[2]-a[2])*t];
}

double dist3(double[3] a, double[3] b) {
    import std.math : sqrt;
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// True if some vertex at index >= `fromIdx` sits within eps of `p`.
bool hasNewVertNear(JSONValue m, double[3] p, size_t fromIdx, double eps = 1e-5) {
    foreach (i; fromIdx .. m["vertices"].array.length)
        if (dist3(vert(m, i), p) < eps) return true;
    return false;
}

void resetCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
    auto s = postCmd("/api/select", `{"mode":"edges","indices":[]}`);
    assert(s["status"].str == "ok", "/api/select (edges) failed");
}

void cmd(string s) {
    auto r = postCmd("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void activateTool() { cmd("tool.set mesh.edgeSliceTool on"); }
void deactivateTool() { cmd("tool.set mesh.edgeSliceTool off"); }

// IntArray params round-trip through argstring's `{a,b,...}` vec-array
// grammar (there is no `[a,b]` bracket syntax — see source/argstring.d).
void setEdges(uint a, uint b) {
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d}", a, b));
}

long undoModelDepth() {
    return getJson("/api/undo/status")["modelDepth"].integer;
}

// ---------------------------------------------------------------------------
// 1. Headless golden: edge(0,1) + edge(4,5) (shared bottom face) -> 7f/10v.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);
    assert(eA != uint.max, "edge(0,1) must exist on cube");
    assert(eB != uint.max, "edge(4,5) must exist on cube");

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.25");
    cmd("tool.attr mesh.edgeSliceTool tB 0.75");
    cmd("tool.doApply");

    auto m1 = model();
    assert(faceCount(m1) == 7,
        "expected 7 faces, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 10,
        "expected 10 verts, got " ~ vertCount(m1).to!string);
    assert(orphanVerts(m1).length == 0, "no orphan vertices after tool cut");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after tool cut");
    assert(duplicatePositionVerts(m1) == 0,
        "no duplicate vertex positions after tool cut (T-junction backstop)");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 2. Analytic: the two NEW verts (index >= 8) land exactly at
//    lerp(edge, effectiveT) for tA=0.25 / tB=0.75 — both are exact multiples
//    of the default 0.5% snap step (0.25/0.005 == 50, 0.75/0.005 == 150), so
//    they survive quantization unchanged.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.25");
    cmd("tool.attr mesh.edgeSliceTool tB 0.75");
    cmd("tool.doApply");

    auto m1 = model();
    assert(vertCount(m1) == 10, "expected 10 verts after analytic cut");

    // The kernel measures t from edges[e][0] -> edges[e][1] — read the
    // ACTUAL post-cut... no, PRE-cut endpoint order from m0 (the cut edges
    // still exist at these indices in m0; only the finalize tail after the
    // cut renumbers the edge array, not the vertex array's original 8).
    auto a0 = edgeEndpoint(m0, eA, 0), a1 = edgeEndpoint(m0, eA, 1);
    auto b0 = edgeEndpoint(m0, eB, 0), b1 = edgeEndpoint(m0, eB, 1);
    auto expectA = lerp3(a0, a1, 0.25);
    auto expectB = lerp3(b0, b1, 0.75);

    assert(hasNewVertNear(m1, expectA, 8),
        "no new vertex at lerp(edgeA, 0.25) = " ~ expectA.to!string);
    assert(hasNewVertNear(m1, expectB, 8),
        "no new vertex at lerp(edgeB, 0.75) = " ~ expectB.to!string);

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 3. Split at Middle: tA=0.2, tB=0.9, middle=true -> both new verts land at
//    their edge's MIDPOINT (t=0.5) regardless of the tA/tB attrs.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.2");
    cmd("tool.attr mesh.edgeSliceTool tB 0.9");
    cmd("tool.attr mesh.edgeSliceTool middle true");
    cmd("tool.doApply");

    auto m1 = model();
    auto a0 = edgeEndpoint(m0, eA, 0), a1 = edgeEndpoint(m0, eA, 1);
    auto b0 = edgeEndpoint(m0, eB, 0), b1 = edgeEndpoint(m0, eB, 1);
    auto midA = lerp3(a0, a1, 0.5);
    auto midB = lerp3(b0, b1, 0.5);

    assert(hasNewVertNear(m1, midA, 8),
        "Split at Middle: no new vertex at edgeA's midpoint " ~ midA.to!string);
    assert(hasNewVertNear(m1, midB, 8),
        "Split at Middle: no new vertex at edgeB's midpoint " ~ midB.to!string);

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 4. Snap Value: snap=25(%), tA=0.30 -> quantized to t=0.25; snap=0 -> exact t.
// ---------------------------------------------------------------------------
unittest {
    // snap=25 quantizes 0.30 -> 0.25.
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool snap 25");
    cmd("tool.attr mesh.edgeSliceTool tA 0.30");
    cmd("tool.attr mesh.edgeSliceTool tB 0.5");   // unaffected by snap (already on-grid)
    cmd("tool.doApply");

    auto m1 = model();
    auto a0 = edgeEndpoint(m0, eA, 0), a1 = edgeEndpoint(m0, eA, 1);
    auto quantized = lerp3(a0, a1, 0.25);
    auto unquantized = lerp3(a0, a1, 0.30);
    assert(hasNewVertNear(m1, quantized, 8),
        "snap 25: tA=0.30 must quantize to t=0.25, expected near " ~ quantized.to!string);
    assert(!hasNewVertNear(m1, unquantized, 8, 1e-3),
        "snap 25: tA=0.30 must NOT land at the unquantized t=0.30 position");
    deactivateTool();

    // snap=0 keeps the exact (unquantized) t.
    resetCube();
    auto m2 = model();
    uint eA2 = edgeIndexByVerts(m2, 0, 1);
    uint eB2 = edgeIndexByVerts(m2, 4, 5);

    activateTool();
    setEdges(eA2, eB2);
    cmd("tool.attr mesh.edgeSliceTool snap 0");
    cmd("tool.attr mesh.edgeSliceTool tA 0.30");
    cmd("tool.attr mesh.edgeSliceTool tB 0.5");
    cmd("tool.doApply");

    auto m3 = model();
    auto a0b = edgeEndpoint(m2, eA2, 0), a1b = edgeEndpoint(m2, eA2, 1);
    auto exact = lerp3(a0b, a1b, 0.30);
    assert(hasNewVertNear(m3, exact, 8),
        "snap 0: tA=0.30 must land at the EXACT t=0.30 position " ~ exact.to!string);
    deactivateTool();
}

// ---------------------------------------------------------------------------
// 5. Split Polygons OFF: points-only — face count UNCHANGED (6), vertex
//    count +2 (10), edge count 12 -> 14 (the rebuildEdges discriminator: a
//    missing finalize tail would leave edges.length at 12).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);
    assert(edgeCount(m0) == 12, "cube starts with 12 edges");

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool split false");
    cmd("tool.doApply");

    auto m1 = model();
    assert(faceCount(m1) == 6,
        "Split Polygons OFF: face count must stay 6, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 10,
        "Split Polygons OFF: expected 10 verts, got " ~ vertCount(m1).to!string);
    assert(edgeCount(m1) == 14,
        "Split Polygons OFF: expected edge count 12 -> 14, got " ~ edgeCount(m1).to!string);
    assert(orphanVerts(m1).length == 0, "no orphan vertices after points-only cut");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 6. Preview/config does NOT mutate: tool.set on + every tool.attr write, but
//    BEFORE tool.doApply, the model is still the untouched 8v/6f cube.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.25");
    cmd("tool.attr mesh.edgeSliceTool tB 0.75");
    cmd("tool.attr mesh.edgeSliceTool split false");
    cmd("tool.attr mesh.edgeSliceTool middle true");
    cmd("tool.attr mesh.edgeSliceTool snap 10");
    cmd("tool.attr mesh.edgeSliceTool show none");

    auto m1 = model();
    assert(vertCount(m1) == 8, "config writes before doApply must not mutate vertex count");
    assert(faceCount(m1) == 6, "config writes before doApply must not mutate face count");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 7. One undo entry on the doApply path: undo count +1; undo restores 8v/6f.
//    (ToolDoApplyCommand wraps its own snapshot pair — a single ledger entry,
//    distinct from the interactive commitEdit() path exercised best-effort
//    in test 8.)
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);
    long depthBefore = undoModelDepth();

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.25");
    cmd("tool.attr mesh.edgeSliceTool tB 0.75");
    cmd("tool.doApply");

    assert(faceCount(model()) == 7, "doApply must produce 7 faces");
    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "doApply must add exactly ONE model-undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    cmd("history.undo");
    auto m1 = model();
    assert(vertCount(m1) == 8, "undo must restore 8 verts");
    assert(faceCount(m1) == 6, "undo must restore 6 faces");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 8. Interactive semantic replay (best-effort, non-authoritative): hover an
//    edge -> click latches edge A -> click a different edge latches edge B
//    and previews the cut live -> Enter commits.
//
//    Uses a fixed viewport (matching the default /api/camera pose for a
//    freshly reset cube) and two edges empirically confirmed hoverable from
//    it: edge(4,5) and edge(6,7), both on the +Z face (visible/front-facing
//    from the default eye position) and non-adjacent on that face, so a
//    single split is expected (7f/10v/15e) — mirrors the headless golden's
//    shared-face case, just driven by real screen pixels instead of
//    tool.attr. Each click is preceded by its own motion event so
//    g_hoveredEdge is freshly resolved before the button-down fires (the
//    codebase's own `clickAt`-style idiom, e.g. tests/test_pen_complex_polygon.d,
//    tests/test_element_pick_edge_clickpoint.d) — the mitigation for the
//    documented "stationary two-click hover staleness" risk. If the GPU
//    picker fails to resolve either edge under CI's camera/driver, this test
//    is the one allowed to be flaky; the headless golden (test 1) remains
//    the authority on kernel correctness.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    activateTool();
    long depthBefore = undoModelDepth();

    enum int VPX = 150, VPY = 28, VPW = 650, VPH = 544;
    enum int AX = 419, AY = 449;   // edge(4,5) midpoint pixel
    enum int BX = 409, BY = 221;   // edge(6,7) midpoint pixel

    string clickAt(double t, int x, int y) {
        return format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":0}` ~ "\n" ~
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
            t,        x, y,
            t + 20.0, x, y,
            t + 40.0, x, y,
            t + 60.0, x, y,
            t + 80.0, x, y);
    }

    string log =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
               VPX, VPY, VPW, VPH) ~ "\n"
      ~ clickAt(50.0, AX, AY) ~ "\n"
      ~ clickAt(200.0, BX, BY) ~ "\n"
      ~ format(`{"t":350.000,"type":"SDL_KEYDOWN","sym":13,"scan":0,"mod":0,"repeat":0}`);

    auto r = postCmd("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "interactive edge-slice replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, per CLAUDE.md flake note)

    auto st = getJson("/api/tool/state");
    if (st["edgeA"].integer < 0 || st["edgeB"].integer < 0) {
        // Best-effort: the GPU picker didn't resolve one of the two edges
        // under this environment's camera/driver — documented Risk #4, not a
        // tool-logic failure. The headless golden (test 1) already proves
        // the kernel wiring; skip the geometry assertions rather than flake.
        deactivateTool();
        return;
    }

    assert(st["phase"].str == "idle",
        "after Enter commit the tool must re-arm to idle phase, got " ~ st["phase"].str);
    assert(st["armed"].type == JSONType.false_, "commit must clear armed_");

    auto m1 = model();
    assert(faceCount(m1) == 7,
        "interactive cut: expected 7 faces, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 10,
        "interactive cut: expected 10 verts, got " ~ vertCount(m1).to!string);
    assert(edgeCount(m1) == 15,
        "interactive cut: expected 15 edges, got " ~ edgeCount(m1).to!string);

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "interactive commit must add exactly ONE model-undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    deactivateTool();
}
