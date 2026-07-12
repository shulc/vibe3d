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
// Task 0295 (Edge Slice v2 — F1 0%/100% endpoint cuts + F2 N-cut chain):
//   9. F1 endpoint topology (splitPolygons ON): tA=0/tB=1 on the diagonal
//      corners of the shared bottom face -> vertexCount UNCHANGED (8), the
//      discriminator that endpoint-reuse (not a coincident insert) happened;
//      faceCount 7, edgeCount 13, no duplicate-position verts, no orphans.
//   10. F1 mixed endpoint + interior: tA=0 (reuse) / tB=0.5 (new mid vert) ->
//      vertexCount +1 only, the new vert lands at edgeB's midpoint.
//   11. F2 headless chain golden (geometry authority): a 3-edge linear chain
//      {e0,e1,e2} across 3 faces via tool.doApply -> a cut vertex on each of
//      e0/e1/e2, no duplicate-position verts (the shared-vertex-reuse proof —
//      a re-cut would duplicate), ONE model-undo entry, undo restores 8v/6f.
//   12. F2 `chainArm` + synthetic Enter (picker-free): arms the SAME 3-edge
//      chain via the deterministic trigger param, asserts chainSegments==2,
//      then drives a lone synthetic SDL_KEYDOWN RETURN -> exercises the REAL
//      commitChain() -> ONE model-undo entry, phase idle, armed false, undo
//      restores the base.
//   13. F2 deactivate-commit (picker-free, objection 5): `chainArm` arms a
//      chain without committing; `tool.set ... off` (deactivate) must commit
//      the baked chain as ONE undo entry rather than discarding it.
//   14. F2 mid-chain cancel (picker-free): `chainArm` arms a chain; a
//      synthetic SDL_KEYDOWN ESCAPE must unwind the WHOLE chain back to the
//      base mesh with NO undo entry recorded.
//
// Task 0303 (fuzz-found — doApply/commitChain corrupt the mesh on a failed
// chain that reuses a shared corner) — RE-DERIVED by the mesh-robustness
// batch (task 0349): edge(0,1)@0.5 (interior) + edge(1,5)@endpoint-reuse of
// the SHARED corner (vertex 1) lands the two cut positions ADJACENT in the
// shared face's winding, so rebuildFacesWithChordSplits' adjacent-hit guard
// correctly refuses to CHORD-SPLIT that face (facesSplit stays 0) — but Pass
// 1 already spliced a REAL new vertex into edge(0,1), which is a legitimate
// degenerate-chain edge-split (matches the frozen reference: cube V8/E12/F6
// -> V9/E13/F6, chi stays 2) and is now KEPT, not force-reverted. Tests
// 15/16 previously asserted the OLD over-rollback ("did not apply" / no
// leaked vertex) as correct — that encoded the exact bug this batch fixes.
// This is an INTENTIONAL REVERSAL, mirroring the mesh.d kernel unittest's own
// re-derivation, not a silently regenerated test.
//   15. doApply (headless): the chain above now reports SUCCESS and keeps
//      the split — vertCount +1, edgeCount +1, faceCount unchanged, Euler
//      stays 2, no duplicate-position verts, exactly ONE undo entry recorded.
//   16. Same chain via the interactive commitChain path (`chainArm` +
//      synthetic Enter): `chainArm`'s eager bake already shows `built=true`
//      and the kept vertex live; the synthetic Enter COMMITS it (one undo
//      entry, armed_ clears) rather than cancelling.
//
// Task 0321 (mid-chain per-click undo peel + editable earlier chain points):
//   17. Mid-chain undo peel: `chainArm` a 3-point chain (chainSegments==2), a
//      synthetic Ctrl+Z (the real navHistory -> tryUndoStepInSession hook,
//      NOT `cmd("history.undo")` — that bypasses navHistory entirely) peels
//      exactly the LAST latched point, keeping the first point byte-identical
//      and re-baking the shorter chain; a SECOND Ctrl+Z peels to an empty
//      chain -> base mesh, tool stays active. Neither peel touches the
//      committed undo ledger.
//   18. Edit-earlier re-bake (picker-free via `activePoint`/`pointT`): select
//      the chain's INTERIOR point and drag its `t` -> both adjacent segments
//      re-bake (the neighbor cuts stay byte-identical, the edited point's cut
//      moves), chain length is unaffected, and a subsequent commit + undo
//      still reverts the WHOLE chain in ONE step (the post-commit invariant).
//
// tests/test_edge_slice.d (the one-shot mesh.edgeSlice command) is untouched
// and stays green independently — this file only exercises the tool path.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : abs;
import std.algorithm : canFind;
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

// Pick t (0.0 or 1.0) so a t=0/1 cut on edge `e` lands on `wantVert` — the
// kernel's endpoint reuse is keyed off edges[e][0]/[1], whose direction is an
// opaque (dedup-order) implementation detail, so read it back from the model
// rather than assuming it (mirrors the identical technique in the mesh.d
// kernel unittest, source/mesh.d "endpoint cut reuses the corner").
double endpointT(JSONValue m, uint e, int wantVert) {
    int v0 = cast(int)m["edges"].array[e].array[0].integer;
    return (v0 == wantVert) ? 0.0 : 1.0;
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

// ---------------------------------------------------------------------------
// 9. F1 endpoint topology (splitPolygons ON): tA=0 / tB=1 on the diagonal
//    corners of the shared bottom face -> vertexCount UNCHANGED (8) — the
//    discriminator that endpoint-reuse (not a coincident insert) happened.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);
    assert(eA != uint.max, "edge(0,1) must exist on cube");
    assert(eB != uint.max, "edge(4,5) must exist on cube");

    // Land on the diagonal {0,5} of face [0,1,5,4] (the other combination,
    // {0,4}/{1,5}, is an EXISTING edge and would hit the adjacent-hit guard).
    double tA = endpointT(m0, eA, 0);
    double tB = endpointT(m0, eB, 5);

    activateTool();
    setEdges(eA, eB);
    cmd(format("tool.attr mesh.edgeSliceTool tA %.3f", tA));
    cmd(format("tool.attr mesh.edgeSliceTool tB %.3f", tB));
    cmd("tool.attr mesh.edgeSliceTool split true");
    cmd("tool.doApply");

    auto m1 = model();
    assert(vertCount(m1) == 8,
        "endpoint cut on BOTH edges must not add a vertex (corners reused), got " ~
        vertCount(m1).to!string);
    assert(faceCount(m1) == 7,
        "6 -> 7 faces (one chord split), got " ~ faceCount(m1).to!string);
    assert(edgeCount(m1) == 13,
        "12 -> 13 edges (only the new chord), got " ~ edgeCount(m1).to!string);
    assert(duplicatePositionVerts(m1) == 0,
        "endpoint reuse must not create a coincident duplicate vertex");
    assert(orphanVerts(m1).length == 0, "no orphan vertices after endpoint cut");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after endpoint cut");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 10. F1 mixed endpoint + interior: tA=0 (reuse the corner) / tB=0.5 (new mid
//     vertex on edgeB) -> vertexCount +1 only.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    double tA = endpointT(m0, eA, 0);

    activateTool();
    setEdges(eA, eB);
    cmd(format("tool.attr mesh.edgeSliceTool tA %.3f", tA));
    cmd("tool.attr mesh.edgeSliceTool tB 0.5");
    cmd("tool.doApply");

    auto m1 = model();
    assert(vertCount(m1) == 9,
        "one endpoint (reused) + one interior (new) => +1 vertex only, got " ~
        vertCount(m1).to!string);
    auto b0 = edgeEndpoint(m0, eB, 0), b1 = edgeEndpoint(m0, eB, 1);
    auto midB = lerp3(b0, b1, 0.5);
    assert(hasNewVertNear(m1, midB, 8),
        "interior cut must land at edgeB's midpoint " ~ midB.to!string);
    assert(duplicatePositionVerts(m1) == 0, "no duplicate vertex positions");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 11. F2 headless chain golden (geometry authority): a 3-edge linear chain
//     spanning 3 faces (edge(0,1) -> edge(1,2) -> edge(5,6), each face-pair
//     sharing a face directly) via tool.doApply -> a cut vertex on each
//     named edge, NO duplicate-position verts (the shared cut-vertex-reuse
//     proof — a re-cut from a position scan would duplicate), ONE
//     model-undo entry, undo restores 8v/6f.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);
    assert(e0 != uint.max); assert(e1 != uint.max); assert(e2 != uint.max);
    long depthBefore = undoModelDepth();

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool tA 0.5");
    cmd("tool.attr mesh.edgeSliceTool tB 0.5");
    cmd("tool.doApply");

    auto m1 = model();
    assert(vertCount(m1) == 11,
        "3-edge chain: 8 base + 3 cut verts = 11, got " ~ vertCount(m1).to!string);
    assert(faceCount(m1) == 8,
        "6 base + 2 chord splits = 8, got " ~ faceCount(m1).to!string);
    assert(duplicatePositionVerts(m1) == 0,
        "shared cut-vertex reuse must not duplicate a vertex");
    assert(orphanVerts(m1).length == 0, "no orphan vertices after chain cut");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after chain cut");

    auto e0a = edgeEndpoint(m0, e0, 0), e0b = edgeEndpoint(m0, e0, 1);
    auto e1a = edgeEndpoint(m0, e1, 0), e1b = edgeEndpoint(m0, e1, 1);
    auto e2a = edgeEndpoint(m0, e2, 0), e2b = edgeEndpoint(m0, e2, 1);
    assert(hasNewVertNear(m1, lerp3(e0a, e0b, 0.5), 8), "no cut vertex on e0's midpoint");
    assert(hasNewVertNear(m1, lerp3(e1a, e1b, 0.5), 8), "no cut vertex on e1's midpoint");
    assert(hasNewVertNear(m1, lerp3(e2a, e2b, 0.5), 8), "no cut vertex on e2's midpoint");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "3-edge chain doApply must add exactly ONE model-undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    cmd("history.undo");
    auto m2 = model();
    assert(vertCount(m2) == 8, "undo must restore 8 verts");
    assert(faceCount(m2) == 6, "undo must restore 6 faces");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 12. F2 `chainArm` + synthetic Enter (picker-free, objection 2): arms the
//     SAME 3-edge chain as test 11 via the deterministic trigger param
//     (chainSegments == 2 before any commit), then a lone synthetic
//     SDL_KEYDOWN RETURN (a key event needs no hover) drives the REAL
//     commitChain() -> ONE model-undo entry, phase idle, armed false, undo
//     restores the base. Exercises the interactive commit path that
//     tool.doApply (test 11) does NOT cover.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    auto st0 = getJson("/api/tool/state");
    assert(st0["chainSegments"].integer == 2,
        "chainArm must arm a 2-segment (3-point) chain, got " ~
        st0["chainSegments"].integer.to!string);
    assert(st0["armed"].type == JSONType.true_, "chainArm must set armed_");

    long depthBefore = undoModelDepth();

    auto r = postCmd("/api/play-events",
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":13,"scan":0,"mod":0,"repeat":0}`);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "synthetic Enter replay did not finish within 10s");
    Thread.sleep(150.msecs);

    auto st1 = getJson("/api/tool/state");
    assert(st1["phase"].str == "idle",
        "commitChain must re-arm to idle phase, got " ~ st1["phase"].str);
    assert(st1["armed"].type == JSONType.false_, "commitChain must clear armed_");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "commitChain must add exactly ONE model-undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    cmd("history.undo");
    auto m1 = model();
    assert(vertCount(m1) == 8, "undo must restore 8 verts");
    assert(faceCount(m1) == 6, "undo must restore 6 faces");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 13. F2 deactivate-commit (picker-free, objection 5): `chainArm` arms a
//     chain WITHOUT committing; `tool.set ... off` (deactivate()) must commit
//     the baked chain as ONE undo entry rather than discarding it — a >=2
//     point chain commits on tool-drop regardless of any pending tip.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    long depthBefore = undoModelDepth();
    deactivateTool();   // tool.set off -> deactivate() -> commitChain()

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "deactivate must commit the armed chain as exactly ONE undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    cmd("history.undo");
    auto m1 = model();
    assert(vertCount(m1) == 8, "undo must restore 8 verts");
    assert(faceCount(m1) == 6, "undo must restore 6 faces");
}

// ---------------------------------------------------------------------------
// 14. F2 mid-chain cancel (picker-free): `chainArm` arms a chain (baking it
//     onto the live mesh, per the mutate/revert preview model); a synthetic
//     SDL_KEYDOWN ESCAPE must unwind the WHOLE chain back to the base mesh
//     with NO undo entry recorded.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    long depthBefore = undoModelDepth();
    // Sanity: the chain IS baked (mutate/revert preview) on the live mesh.
    assert(vertCount(model()) == 11,
        "chainArm must bake the chain onto the live mesh before cancel");

    auto r = postCmd("/api/play-events",
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":27,"scan":0,"mod":0,"repeat":0}`);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "synthetic Escape replay did not finish within 10s");
    Thread.sleep(150.msecs);

    auto m1 = model();
    assert(vertCount(m1) == 8, "Escape mid-chain must unwind the whole chain back to base");
    assert(faceCount(m1) == 6, "Escape mid-chain must unwind the whole chain back to base");

    auto st = getJson("/api/tool/state");
    assert(st["armed"].type == JSONType.false_, "cancel must clear armed_");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore,
        "cancel must NOT record any undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 15. Task 0303 (fuzz-found, definitive minimal repro), RE-DERIVED by the
//     mesh-robustness batch (task 0349) — an INTENTIONAL REVERSAL, not a
//     silently regenerated test. A chain reusing a shared corner —
//     edge(0,1)@0.5 (genuine interior insert) chained to edge(1,5)@endpoint-
//     reuse of the SHARED corner (vertex 1, common to both edges). Both
//     edges border face 5 ([0,1,5,4]); the interior cut vertex is spliced in
//     immediately next to the reused corner in that face's winding, so the
//     two cut positions are ADJACENT there — rebuildFacesWithChordSplits'
//     adjacent-hit guard correctly refuses to CHORD-SPLIT that face
//     (facesSplit stays 0). But the interior insert on edge(0,1) is a REAL,
//     legitimate degenerate-chain edge-split (matches the frozen reference:
//     cube V8/E12/F6 -> V9/E13/F6, chi stays 2) — doApply must now report
//     SUCCESS and KEEP it, with exactly one undo entry recorded.
//
//     Before this reversal (the 0303 fix, too broad): Pass 1 (insertEdgePoint)
//     spliced the new vertex into BOTH faces incident to edge(0,1) (faces 0
//     and 5), and the kernel unconditionally rolled that back on the Pass-2
//     no-op — discarding a legitimate mutation, not just a corrupt one.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 1, 5);
    assert(eA != uint.max, "edge(0,1) must exist on cube");
    assert(eB != uint.max, "edge(1,5) must exist on cube");
    long depthBefore = undoModelDepth();

    double tB = endpointT(m0, eB, 1);   // land on the shared corner, vertex 1

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.5");
    cmd(format("tool.attr mesh.edgeSliceTool tB %.3f", tB));

    auto r = postCmd("/api/command", "tool.doApply");
    assert(r["status"].str == "ok",
        "kept degenerate-chain insert must report success, got " ~ r.toString);

    auto m1 = model();
    assert(vertCount(m1) == vertCount(m0) + 1,
        "kept insert: expected exactly one new vertex, got " ~ vertCount(m1).to!string
        ~ " (was " ~ vertCount(m0).to!string ~ ")");
    assert(faceCount(m1) == faceCount(m0),
        "kept insert: face count must be unchanged, got " ~ faceCount(m1).to!string);
    assert(edgeCount(m1) == edgeCount(m0) + 1,
        "kept insert: edge(0,1) splits into two edges — net +1, got " ~ edgeCount(m1).to!string
        ~ " (was " ~ edgeCount(m0).to!string ~ ")");
    assert(vertCount(m1) - edgeCount(m1) + cast(long)faceCount(m1) == 2,
        "Euler characteristic must stay 2 after a kept degenerate-chain insert");
    assert(duplicatePositionVerts(m1) == 0, "no duplicate vertex positions after a kept insert");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "a kept degenerate-chain insert must record exactly one undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    deactivateTool();
}

// ---------------------------------------------------------------------------
// 16. Task 0303, interactive commitChain path, RE-DERIVED by the mesh-
//     robustness batch (task 0349) — `chainArm` arms the SAME kept-insert
//     2-edge chain as test 15. `bakeChainFrom` now COUNTS the kept segment
//     (gated on `!meshChanged`, not `facesSplit==0`), so armChain's eager
//     bake already shows `built=true` and the kept vertex live on the mesh.
//     A synthetic Enter drives the REAL commitChain(), which now records ONE
//     undo entry (a genuine mutation) instead of cancelling.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 1, 5);
    double tB = endpointT(m0, eB, 1);

    activateTool();
    setEdges(eA, eB);
    cmd("tool.attr mesh.edgeSliceTool tA 0.5");
    cmd(format("tool.attr mesh.edgeSliceTool tB %.3f", tB));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    // Sanity: armChain bakes eagerly (mutate/revert preview) and this chain's
    // single segment is now a KEPT insert — `built_` must reflect that, and
    // the live mesh must already show the kept vertex.
    auto st0 = getJson("/api/tool/state");
    assert(st0["built"].type == JSONType.true_,
        "armChain must report built=true for a kept degenerate-chain insert");
    assert(vertCount(model()) == vertCount(m0) + 1,
        "armChain must show the kept vertex live on the mesh");

    long depthBefore = undoModelDepth();

    auto r = postCmd("/api/play-events",
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":13,"scan":0,"mod":0,"repeat":0}`);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "synthetic Enter replay did not finish within 10s");
    Thread.sleep(150.msecs);

    auto m1 = model();
    assert(vertCount(m1) == vertCount(m0) + 1, "committed kept insert must keep the new vertex");
    assert(faceCount(m1) == faceCount(m0), "committed kept insert must not touch face count");
    assert(edgeCount(m1) == edgeCount(m0) + 1, "committed kept insert: edge(0,1) split, net +1 edge");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "a chain that bakes a kept segment must record exactly one undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    auto st1 = getJson("/api/tool/state");
    assert(st1["armed"].type == JSONType.false_, "commitChain must clear armed_ on commit");

    deactivateTool();
}

// ---------------------------------------------------------------------------
// Play a synthetic key event and wait for it to finish + settle (mirrors the
// Enter/Escape play-events idiom already used by tests 12/14/16 above).
// ---------------------------------------------------------------------------
void playKey(int sym, int mod = 0) {
    auto r = postCmd("/api/play-events",
        format(`{"t":0.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
               sym, mod));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "synthetic key replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, per CLAUDE.md flake note)
}

// ---------------------------------------------------------------------------
// 17. Task 0321, mid-chain undo peel: `chainArm` the SAME 3-edge chain as
//     test 12 (chainSegments==2); a synthetic Ctrl+Z is the ONLY way to reach
//     the real navHistory -> tryUndoStepInSession hook (`cmd("history.undo")`
//     drives the raw HistoryUndo command and bypasses navHistory entirely —
//     see the plan's Risk #2), so this test replays sym=122 (SDLK_z),
//     mod=64 (KMOD_LCTRL). The chain latches 3 points (A, B, C); each Ctrl+Z
//     peels exactly the LAST one, so the progression is 3 -> 2 -> 1 -> 0
//     points over THREE Ctrl+Z's:
//       1st: peels C -> a 1-segment (2-point) chain, still armed, A untouched.
//       2nd: peels B -> a LONE latched point (A). `chainSegments` reports 0
//            here too (it derives from length-1, clamped at 0), so it alone
//            cannot tell "1 point left" from "0 points left" — `activePoint`
//            disambiguates: peelLastPoint's length==1 branch sets
//            activePoint_=0, the length==0 branch sets it to -1.
//       3rd: peels A -> the chain is FINALLY empty (peelLastPoint's
//            length==0 branch, previously uncovered), tool STILL active.
//     None of the three peels records anything to the committed undo ledger.
// ---------------------------------------------------------------------------
unittest {
    enum SDLK_z    = 122;
    enum KMOD_LCTRL = 64;

    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    auto st0 = getJson("/api/tool/state");
    assert(st0["chainSegments"].integer == 2,
        "chainArm must arm a 2-segment (3-point) chain, got " ~
        st0["chainSegments"].integer.to!string);
    int    edgeA0 = cast(int)st0["edgeA"].integer;
    double tA0    = st0["tA"].floating;

    long depthBefore = undoModelDepth();

    // First Ctrl+Z: peel the last latched point (C) -> a 1-segment (2-point)
    // chain; A must be untouched.
    playKey(SDLK_z, KMOD_LCTRL);
    auto st1 = getJson("/api/tool/state");
    assert(st1["chainSegments"].integer == 1,
        "first Ctrl+Z must peel to a 1-segment chain, got " ~
        st1["chainSegments"].integer.to!string);
    assert(cast(int)st1["edgeA"].integer == edgeA0,
        "peel must leave the first latched point's edge unchanged");
    assert(abs(st1["tA"].floating - tA0) < 1e-9,
        "peel must leave the first latched point's t byte-identical");
    assert(st1["armed"].type == JSONType.true_,
        "a 2-point chain after peel is still a real armed preview");

    long depthMid = undoModelDepth();
    assert(depthMid == depthBefore,
        "peel must NOT touch the committed undo ledger, went " ~
        depthBefore.to!string ~ " -> " ~ depthMid.to!string);

    // Second Ctrl+Z: peel B -> a LONE latched point (A) remains — NOT an
    // empty chain. `chainSegments` is 0 either way (length-1 clamped at 0),
    // so `activePoint` is what disambiguates it from the truly-empty state
    // checked after the third Ctrl+Z below.
    playKey(SDLK_z, KMOD_LCTRL);
    auto st2 = getJson("/api/tool/state");
    assert(st2["chainSegments"].integer == 0,
        "second Ctrl+Z must peel to a (still non-empty) 1-point chain, got " ~
        st2["chainSegments"].integer.to!string ~ " segments");
    assert(st2["armed"].type == JSONType.false_, "a lone latched point is not armed");
    assert(cast(int)st2["activePoint"].integer == 0,
        "a lone latched point must report activePoint==0, distinguishing it from an empty chain's -1");

    auto m1 = model();
    assert(vertCount(m1) == 8, "a lone latched point cuts nothing -> base mesh (8v)");
    assert(faceCount(m1) == 6, "a lone latched point cuts nothing -> base mesh (6f)");

    long depthMid2 = undoModelDepth();
    assert(depthMid2 == depthBefore,
        "peel must NOT touch the committed undo ledger, went " ~
        depthBefore.to!string ~ " -> " ~ depthMid2.to!string);

    // Third Ctrl+Z: peel A -> the chain is now genuinely empty
    // (peelLastPoint's length==0 branch, previously uncovered), tool STILL
    // active.
    playKey(SDLK_z, KMOD_LCTRL);
    auto st3 = getJson("/api/tool/state");
    assert(st3["chainSegments"].integer == 0,
        "third Ctrl+Z must peel to an empty chain, got " ~
        st3["chainSegments"].integer.to!string ~ " segments");
    assert(st3["armed"].type == JSONType.false_, "an empty chain is not armed");
    assert(cast(int)st3["activePoint"].integer == -1,
        "an empty chain must report activePoint==-1, distinguishing it from the lone-point state");

    auto m2 = model();
    assert(vertCount(m2) == 8, "peel to an empty chain must restore the base mesh (8v)");
    assert(faceCount(m2) == 6, "peel to an empty chain must restore the base mesh (6f)");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore,
        "peel must never record an undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    // The tool is still active-idle after peeling everything (not dropped) —
    // a further command against it must still succeed.
    deactivateTool();
}

// ---------------------------------------------------------------------------
// 18. Task 0321, edit-earlier re-bake (Stage 2, picker-free via numeric):
//     arm the same 3-point chain as test 17; `chainArm` sets `activePoint_`
//     to the LAST latched point (index 2) — asserted directly, since this is
//     the opponent-folded requirement that ALL THREE latch producers
//     (latchFirstPoint/appendPoint/armChain) set it. Select the INTERIOR
//     point (B, index 1) via `activePoint` and drag its `t` via `pointT` ->
//     BOTH adjacent segments re-bake: A's and C's cut vertices stay
//     byte-identical, B's cut vertex moves. Chain length is unaffected.
//     Committing afterwards (tool-drop) still records exactly ONE undo
//     entry, and one undo still reverts the WHOLE chain — the post-commit
//     invariant is untouched by editing an interior point.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m0 = model();
    uint e0 = edgeIndexByVerts(m0, 0, 1);
    uint e1 = edgeIndexByVerts(m0, 1, 2);
    uint e2 = edgeIndexByVerts(m0, 5, 6);

    activateTool();
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", e0, e1, e2));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");

    auto st0 = getJson("/api/tool/state");
    assert(st0["chainSegments"].integer == 2, "chainArm must arm a 2-segment chain");
    assert(cast(int)st0["activePoint"].integer == 2,
        "chainArm must set activePoint_ to the LAST latched point (index 2), got " ~
        st0["activePoint"].integer.to!string);

    // A-cut / C-cut land at e0's / e2's midpoints (interior default + the
    // explicit tA/tB==0.5, same golden as test 11/12's 3-point chain).
    auto e0a = edgeEndpoint(m0, e0, 0), e0b = edgeEndpoint(m0, e0, 1);
    auto e2a = edgeEndpoint(m0, e2, 0), e2b = edgeEndpoint(m0, e2, 1);
    auto cutA = lerp3(e0a, e0b, 0.5);
    auto cutC = lerp3(e2a, e2b, 0.5);
    auto mBefore = model();
    assert(hasNewVertNear(mBefore, cutA, 8), "A-cut must sit at e0's midpoint before the edit");
    assert(hasNewVertNear(mBefore, cutC, 8), "C-cut must sit at e2's midpoint before the edit");

    // Select the INTERIOR point (B, index 1); its t must read back its
    // current value (0.5, the pointsFromEdgesParam interior default) before
    // any edit.
    cmd("tool.attr mesh.edgeSliceTool activePoint 1");
    auto st1 = getJson("/api/tool/state");
    assert(cast(int)st1["activePoint"].integer == 1, "activePoint must select index 1");
    assert(abs(st1["pointT"].floating - 0.5) < 1e-9,
        "selecting activePoint=1 must sync pointT to B's current t (0.5), got " ~
        st1["pointT"].floating.to!string);

    // Drag B's t to 0.75 -> re-bakes both adjacent segments.
    cmd("tool.attr mesh.edgeSliceTool pointT 0.75");

    auto mAfter = model();
    assert(hasNewVertNear(mAfter, cutA, 8), "A-cut must stay byte-identical after editing B");
    assert(hasNewVertNear(mAfter, cutC, 8), "C-cut must stay byte-identical after editing B");

    auto e1a = edgeEndpoint(m0, e1, 0), e1b = edgeEndpoint(m0, e1, 1);
    auto oldB = lerp3(e1a, e1b, 0.5);
    auto newB = lerp3(e1a, e1b, 0.75);
    assert(!hasNewVertNear(mAfter, oldB, 8, 1e-3),
        "B's cut vertex must have MOVED off its original midpoint after the edit");
    assert(hasNewVertNear(mAfter, newB, 8),
        "B's cut vertex must land at the edited t=0.75, expected near " ~ newB.to!string);

    auto st2 = getJson("/api/tool/state");
    assert(st2["chainSegments"].integer == 2,
        "editing an interior point must not change chain length, got " ~
        st2["chainSegments"].integer.to!string);

    // Commit (tool-drop) + one undo -> the WHOLE chain reverts in ONE step.
    long depthBefore = undoModelDepth();
    deactivateTool();   // tool.set off -> deactivate() -> commitChain()
    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore + 1,
        "commit after an interior-point edit must still add exactly ONE undo entry, went " ~
        depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    cmd("history.undo");
    auto m1 = model();
    assert(vertCount(m1) == 8,
        "post-commit undo must revert the WHOLE edited chain in ONE step (8v)");
    assert(faceCount(m1) == 6,
        "post-commit undo must revert the WHOLE edited chain in ONE step (6f)");
}
