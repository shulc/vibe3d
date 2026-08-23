// /api/frames/counts — the always-on per-frame WORK counters.
//
// This is the endpoint that is NOT a stub in the build these tests run
// against. Its two siblings return "{}" here (see test_frames_endpoint.d and
// its comment: `run_test.d` builds the default `modeling` config, which
// defines no `PerfProbe` version, so every timer compiles away). That is why
// there has never been a test in this suite that could assert anything about
// what a frame costs.
//
// WHAT THESE TESTS ARE FOR. Not "the numbers are plausible" — an oracle that
// only checks plausibility passes on a constant. Every assertion below either
//
//   (a) ties a counter to an INDEPENDENT reading of the same fact — the mesh
//       from /api/model, so the same number has to come out of two unrelated
//       code paths — and does it on at least TWO different meshes, so no fixed
//       value can satisfy it; or
//   (b) asserts a DIFFERENTIAL across a state change (a display style, a
//       layer, a selection), so the counter has to move in the right direction
//       by the right amount, which a constant cannot do either.
//
// NO TIMING IS ASSERTED ANYWHERE, and none is available to assert. See the
// FrameWorkProbe header in source/perf_probe.d: a wall-clock number taken on
// this host is not a fact about vibe3d, and every performance defect this
// project has actually fixed was a count regression, not a slow draw call.
//
// NO ALLOCATION THRESHOLD IS ASSERTED EITHER — `allocBytes` is a delta
// instrument with a nonzero ImGui floor. The one thing asserted about it is
// that it responds at all (in perf_probe.d's own unittest).

import std.net.curl;
import std.json;
import std.exception : enforce;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

JSONValue gj(string p) { return parseJSON(cast(string)get(baseUrl ~ p)); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void cmd(string line) {
    string resp = httpPost("/api/command", line);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command `" ~ line ~ "` failed: " ~ resp);
}

// A state change is visible to the counters only once a frame has RENDERED
// with it. `settle` is generous on purpose: at ~230 fps in --test this is
// dozens of frames, and the counters it reads are frame-exact, so a longer
// sleep cannot make a passing assertion pass "more".
void settle() { Thread.sleep(400.msecs); }

void resetApp() { httpPost("/api/reset", "{}"); settle(); }

/// The last frame that actually rendered a viewport cell. Always read this,
/// never `last` — see the endpoint comment in http_server.d.
JSONValue lastScene() { return gj("/api/frames/counts")["lastScene"]; }

long passCalls(JSONValue w, string p) { return w["pass"][p]["calls"].integer; }
long passVerts(JSONValue w, string p) { return w["pass"][p]["verts"].integer; }

/// Face-VBO vertex count the renderer MUST be submitting for this mesh,
/// derived from /api/model alone: every face is fan-triangulated into
/// (n - 2) triangles of 3 vertices, and degenerate faces are skipped. This is
/// an independent re-derivation of GpuMesh.faceVertCount from the public
/// model dump — that independence is what makes the equality an assertion
/// rather than a tautology.
long expectedFaceVerts(JSONValue model) {
    long n = 0;
    foreach (f; model["faces"].array) {
        immutable long c = cast(long)f.array.length;
        if (c >= 3) n += (c - 2) * 3;
    }
    return n;
}

long modelVertCount(JSONValue model) { return cast(long)model["vertices"].array.length; }
long modelEdgeCount(JSONValue model) { return cast(long)model["edges"].array.length; }

// --------------------------------------------------------------------------

unittest { // the endpoint is LIVE in this build — not a "{}" stub
    resetApp();
    auto j = gj("/api/frames/counts");

    assert(j.type == JSONType.object, "expected a JSON object");
    // The distinguishing claim. /api/frames and /api/perf are empty objects in
    // this binary; if this probe ever gets gated behind version(PerfProbe) the
    // way its two siblings are, `frames` disappears and this fails — which is
    // exactly the regression worth catching, since the entire point of the
    // probe is being present here.
    assert("frames" in j, "no `frames` key — probe compiled out of this build?");
    assert(j["frames"].integer > 0,
           "frames == 0: the main loop is not driving g_fc.beginFrame/endFrame");

    foreach (rec; ["lastScene", "last", "totals"])
        assert(rec in j, "missing record: " ~ rec);
}

unittest { // draw counts are DERIVED FROM THE MESH, on two different meshes
    // The core "these are real numbers" test. Three independent identities,
    // each checked against /api/model on a 6-face cube and again on its
    // 24-face subdivision. A hard-coded constant satisfies at most one of the
    // six checks; a counter wired to the wrong buffer satisfies none.
    resetApp();

    void checkAgainstModel(string what) {
        auto model = gj("/api/model");
        auto w = lastScene();

        immutable long wantFaceVerts = expectedFaceVerts(model);
        immutable long wantEdgeVerts = 2 * modelEdgeCount(model);   // GL_LINES
        immutable long wantVertDots  = modelVertCount(model);       // GL_POINTS

        assert(passVerts(w, "faces") == wantFaceVerts,
               format("%s: face pass submitted %d verts, mesh implies %d",
                      what, passVerts(w, "faces"), wantFaceVerts));
        assert(passVerts(w, "edges") == wantEdgeVerts,
               format("%s: edge pass submitted %d verts, mesh implies %d (2 x %d edges)",
                      what, passVerts(w, "edges"), wantEdgeVerts, modelEdgeCount(model)));
        assert(passVerts(w, "verts") == wantVertDots,
               format("%s: vertex-dot pass submitted %d verts, mesh has %d vertices",
                      what, passVerts(w, "verts"), wantVertDots));
    }

    checkAgainstModel("cube");
    immutable long cubeFaceVerts = passVerts(lastScene(), "faces");

    cmd("mesh.subdivide");
    settle();
    checkAgainstModel("subdivided");

    // ...and the two meshes must actually differ, or the pair of checks above
    // proves nothing beyond one arithmetic identity.
    assert(passVerts(lastScene(), "faces") != cubeFaceVerts,
           "subdivide did not change the face-vertex count — the two checks "
           ~ "above were the same check twice");
}

unittest { // a display style that drops the face pass is VISIBLE in the counts
    // This is the question that motivated the probe: under Wireframe the face
    // pass does not run, and until now there was no way to observe the
    // difference in cost — only in pixels, which cannot tell you WHAT stopped.
    resetApp();
    cmd(`{"id":"viewport.displayStyle","params":"shaded"}`);
    settle();

    auto shaded = lastScene();
    immutable long faceVerts  = passVerts(shaded, "faces");
    immutable long faceCalls  = passCalls(shaded, "faces");
    immutable long edgeVerts  = passVerts(shaded, "edges");
    immutable long totalVerts = shaded["drawVerts"].integer;
    immutable long totalCalls = shaded["drawCalls"].integer;
    assert(faceCalls > 0 && faceVerts > 0, "shaded must run a face pass");

    cmd(`{"id":"viewport.displayStyle","params":"wireframe"}`);
    settle();

    auto wire = lastScene();
    assert(passCalls(wire, "faces") == 0,
           format("wireframe still issued %d face draws", passCalls(wire, "faces")));
    assert(passVerts(wire, "faces") == 0);
    // The overlay is a SEPARATE axis and must survive — a display change that
    // took the wireframe with it would be a bug the pixel digest also cannot
    // name (fewer pixels either way).
    assert(passVerts(wire, "edges") == edgeVerts,
           "wireframe must not change the edge pass");
    // Exact bookkeeping: the frame got cheaper by precisely the face pass and
    // nothing else. `>=`/`<` here would pass on a counter that lost work
    // somewhere unrelated.
    assert(wire["drawVerts"].integer == totalVerts - faceVerts,
           format("expected drawVerts %d, got %d",
                  totalVerts - faceVerts, wire["drawVerts"].integer));
    assert(wire["drawCalls"].integer == totalCalls - faceCalls,
           format("expected drawCalls %d, got %d",
                  totalCalls - faceCalls, wire["drawCalls"].integer));

    // Reversible: switching back restores exactly what was there.
    cmd(`{"id":"viewport.displayStyle","params":"shaded"}`);
    settle();
    auto back = lastScene();
    assert(passVerts(back, "faces") == faceVerts);
    assert(back["drawVerts"].integer == totalVerts);
}

unittest { // background-layer draws are attributed to the BACKDROP slots
    // Without the redirect a scene with four background layers is
    // indistinguishable from one expensive model, and those two call for
    // different fixes.
    resetApp();
    auto solo = lastScene();
    immutable long soloFaceVerts = passVerts(solo, "faces");
    assert(soloFaceVerts > 0);
    assert(passVerts(solo, "bgFaces") == 0, "no background layer yet");
    assert(passVerts(solo, "bgEdges") == 0);

    // layer.add makes a new EMPTY primary; the cube becomes the backdrop.
    cmd("layer.add");
    settle();

    auto two = lastScene();
    assert(passVerts(two, "bgFaces") == soloFaceVerts,
           format("the cube's %d face verts should now be backdrop work, got %d",
                  soloFaceVerts, passVerts(two, "bgFaces")));
    assert(passVerts(two, "bgEdges") > 0, "backdrop wireframe should be drawn");
    // ...and must NOT be double-counted into the primary's slots: the new
    // primary layer is empty.
    assert(passVerts(two, "faces") == 0,
           format("primary is an empty layer but reported %d face verts",
                  passVerts(two, "faces")));
}

unittest { // draw-CALL count tracks selection fragmentation
    // The batching oracle. The selected-face overlay coalesces contiguous runs
    // of selected faces into one submission, so N scattered faces cost N draw
    // calls and N adjacent ones cost fewer. A regression that dropped the
    // batching would leave `verts` untouched and `calls` exploding — which is
    // precisely the shape no timing number on this host would resolve.
    resetApp();
    httpPost("/api/select", `{"mode":"polygons","indices":[0]}`);
    settle();

    auto one = lastScene();
    assert(passCalls(one, "faceOverlay") == 1,
           format("one selected face should be one overlay draw, got %d",
                  passCalls(one, "faceOverlay")));
    immutable long onePolyVerts = passVerts(one, "faceOverlay");
    assert(onePolyVerts > 0);

    // Faces 0, 2, 4 of the cube are non-adjacent IN VBO ORDER, so the run
    // batcher cannot coalesce them: three faces, three submissions.
    httpPost("/api/select", `{"mode":"polygons","indices":[0,2,4]}`);
    settle();

    auto three = lastScene();
    assert(passCalls(three, "faceOverlay") == 3,
           format("three non-contiguous faces should be three overlay draws, got %d",
                  passCalls(three, "faceOverlay")));
    assert(passVerts(three, "faceOverlay") == 3 * onePolyVerts,
           format("three faces should submit 3x the vertices of one (%d), got %d",
                  3 * onePolyVerts, passVerts(three, "faceOverlay")));

    // Deselect: the overlay pass disappears entirely, calls AND verts.
    httpPost("/api/select", `{"mode":"polygons","indices":[]}`);
    settle();
    assert(passCalls(lastScene(), "faceOverlay") == 0);
    assert(passVerts(lastScene(), "faceOverlay") == 0);
}

unittest { // arming a tool shows up as gizmo draws and pipeline evaluations
    // `stageEvals` is the counter that would have caught a stage evaluating
    // every frame to publish a packet with no consumer: the operator count
    // rises with no corresponding work anywhere downstream.
    resetApp();
    auto idle = lastScene();
    assert(passCalls(idle, "handles") == 0, "no tool armed, no handle draws");
    assert(idle["pipeEvals"].integer == 0, "no tool armed, no pipeline pass");

    cmd("tool.set move");
    settle();

    auto armed = lastScene();
    assert(passCalls(armed, "handles") > 0,
           "the Move gizmo must submit handle geometry");
    assert(passVerts(armed, "handles") > 0);
    assert(armed["pipeEvals"].integer > 0,
           "an armed tool must evaluate the pipeline each frame");
    assert(armed["stageEvals"].integer >= armed["pipeEvals"].integer,
           format("stageEvals (%d) counts operators and cannot be below "
                  ~ "pipeEvals (%d), which counts passes",
                  armed["stageEvals"].integer, armed["pipeEvals"].integer));

    // Dropping the tool takes both back to zero — a counter that only ever
    // goes up is not measuring the thing it is named after.
    cmd("tool.set move off");
    settle();
    auto dropped = lastScene();
    assert(passCalls(dropped, "handles") == 0,
           format("gizmo still drawing %d handle batches after tool drop",
                  passCalls(dropped, "handles")));
    assert(dropped["pipeEvals"].integer == 0);
}

unittest { // the per-frame record is a FRAME, and totals are the accumulation
    resetApp();
    httpPost("/api/frames/counts/reset", "");
    settle();

    auto j = gj("/api/frames/counts");
    immutable long frames = j["frames"].integer;
    assert(frames > 0, "frames must resume counting after a reset");

    auto one = j["lastScene"];
    auto tot = j["totals"];

    // The distinction the two records exist for: `lastScene.drawVerts` is one
    // frame's work and does not grow with elapsed time; `totals.drawVerts` is
    // every frame's and does. Confusing them is the easiest way to write a
    // perf assertion that passes for the wrong reason.
    assert(tot["drawVerts"].integer >= one["drawVerts"].integer);
    assert(tot["drawVerts"].integer > one["drawVerts"].integer,
           "totals should have accumulated over many frames by now");
    assert(tot["seq"].integer == frames,
           "totals.seq is the committed-frame count");

    settle();
    auto later = gj("/api/frames/counts");
    assert(later["frames"].integer > frames, "the frame counter must advance");
    assert(later["lastScene"]["drawVerts"].integer == one["drawVerts"].integer,
           "a per-frame count must not drift while the scene is quiescent");
    assert(later["totals"]["drawVerts"].integer > tot["drawVerts"].integer,
           "totals must keep accumulating");
}

unittest { // reset actually zeroes the published records
    resetApp();
    // Prove there is something to clear first.
    assert(gj("/api/frames/counts")["totals"]["drawVerts"].integer > 0);

    auto r = parseJSON(httpPost("/api/frames/counts/reset", ""));
    assert("status" in r && r["status"].str == "ok",
           "reset should acknowledge: " ~ r.toString);

    // Read immediately: the app keeps rendering, so this races the next
    // frame's commit by design. The claim is that the counter RESTARTED, not
    // that it is exactly zero — assert against a bound that the pre-reset
    // total (many thousands of frames' worth) blows through and one frame's
    // worth cannot.
    immutable long after = gj("/api/frames/counts")["frames"].integer;
    assert(after < 100,
           format("frames == %d right after reset — the counter did not restart",
                  after));
}

// ==========================================================================
// SELECTION-MASK WIRING (task 0585)
// ==========================================================================
//
// The draw path stopped materializing a `bool[]` snapshot of the selection on
// every frame and now hands `GpuMesh` a borrowed `MarkView` over the mesh's
// own marks array. These blocks are the OUTPUT tier of the proof that the
// change drew the same thing.
//
// WHAT THIS TIER PINS: that the mask is WIRED to the draw path at all, and the
// CARDINALITY and RUN STRUCTURE of what it produces — one point submission per
// selected vertex, one overlay submission per contiguous run of selected
// faces, the exact edge-pass call count for a given selected-edge mask.
//
// WHAT IT CANNOT PIN: IDENTITY. `drawVertices` gives `calls = 1 + #selected`,
// so a mask of {0,2,4} and one of {1,3,5} are indistinguishable here; the face
// overlay submits once per contiguous run, so {0,1,2} and {5,6,7} both give 1.
// Any error that preserves cardinality — most plausibly an index shift in the
// `uint[]` change-detector conversion — passes this tier clean. Identity is
// pinned element-by-element by `tests/unit/mark_view_test.d` against the
// materialized accessors as oracle. Neither tier substitutes for the other,
// and the third block below is the one place this file can see position at
// all: it uses faces of DIFFERENT DEGREE so `faceOverlay.verts` stops being
// `6 x #selected` and starts depending on WHICH faces are in the mask.
//
// A note on what the counters do NOT see: while a `BackdropScope` is open
// (`viewport_render.d`, the background-layer pass) face and edge submissions
// are re-attributed to `bgFaces`/`bgEdges`. Every block here runs on a
// single-layer scene straight out of `/api/reset`, so nothing is redirected —
// a stray background layer would silently zero the positive controls below.

/// Number of maximal contiguous runs of `want` in `m` — the batcher's own
/// rule, re-derived here from the mask rather than read off the counter.
long runsOf(const bool[] m, bool want) {
    long n = 0;
    bool inRun = false;
    foreach (v; m) {
        if (v == want) { if (!inRun) { n++; inRun = true; } }
        else inRun = false;
    }
    return n;
}

/// `pass.edges.calls` that `GpuMesh.drawEdges` MUST report for a cage-indexed
/// selected-edge mask, on a mesh whose VBO segments are 1:1 with cage edges,
/// with no hovered edge and the base wireframe overlay on.
///
/// Re-derived from drawEdges' three passes, not copied from a measurement:
///   base pass  — one submission per contiguous run of UNSELECTED segments,
///                except the whole-mesh fast path (mask length 0) and the
///                all-selected shortcut (skipped entirely);
///   highlight  — one submission for the whole mesh when everything is
///                selected, else one per contiguous run of SELECTED segments;
///   hover pass — none, `hoveredEdge < 0` and no loop mask.
long expectedEdgeCalls(const bool[] sel) {
    immutable bool haveMask = sel.length > 0;
    bool allSel = haveMask;
    foreach (s; sel) if (!s) { allSel = false; break; }

    long calls = 0;
    if (!haveMask)      calls += 1;              // gray fast path, whole mesh
    else if (!allSel)   calls += runsOf(sel, false);
    if (allSel)         calls += 1;              // orange, whole mesh
    else if (haveMask)  calls += runsOf(sel, true);
    return calls;
}

/// Cage-edge mask implied by a face selection: an edge is in it iff it is a
/// boundary of at least one selected face. Derived from /api/model's own face
/// and edge arrays — independent of the app-side cache it is checking.
bool[] edgeMaskForFaces(JSONValue model, const long[] selFaces) {
    ulong key(long a, long b) {
        return a < b ? (cast(ulong)a << 32) | cast(uint)b
                     : (cast(ulong)b << 32) | cast(uint)a;
    }
    bool[ulong] wanted;
    foreach (fi; selFaces) {
        auto f = model["faces"].array[cast(size_t)fi].array;
        foreach (k, _; f)
            wanted[key(f[k].integer, f[(k + 1) % f.length].integer)] = true;
    }
    auto edges = model["edges"].array;
    auto mask = new bool[](edges.length);
    foreach (ei, e; edges)
        mask[ei] = (key(e.array[0].integer, e.array[1].integer) in wanted) !is null;
    return mask;
}

/// Face-overlay vertices for a face selection: each face is fan-triangulated
/// into (n - 2) triangles of 3 vertices. On an all-quad mesh this collapses to
/// `6 * count` and stops depending on WHICH faces — see the mixed-degree block.
long overlayVertsFor(JSONValue model, const long[] selFaces) {
    long n = 0;
    foreach (fi; selFaces)
        n += (cast(long)model["faces"].array[cast(size_t)fi].array.length - 2) * 3;
    return n;
}

void selectPolys(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    httpPost("/api/select", `{"mode":"polygons","indices":` ~ s ~ `]}`);
}

void selectVerts(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    httpPost("/api/select", `{"mode":"vertices","indices":` ~ s ~ `]}`);
}

void selectEdgesBy(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    httpPost("/api/select", `{"mode":"edges","indices":` ~ s ~ `]}`);
}

/// The selection type the RENDERER is feeding back, straight from the app.
string selTypeNow() { return gj("/api/selection")["selType"].str; }

unittest { // the VERTEX mask reaches drawVertices, with the right run structure
    // `drawVertices` submits one GL_POINTS batch for the whole cloud and then
    // one MORE PER CONTIGUOUS RUN of selected vertices, so
    // `pass.verts.calls == 1 + runsOf(mask, true)`.
    //
    // TASK 1770 CHANGED THIS FORMULA, and what it changed is arithmetic, not
    // the contract. It used to read `1 + n`, one call per selected VERTEX,
    // because the pass issued a draw call each; at n=316 with the whole mesh
    // selected that measured 100 490 calls in a frame whose total was 100 495.
    // The pass now merges adjacent indices exactly as the EDGE pass beside it
    // already did — same VBO indices, same order, same colour, depth test off
    // — so this block now uses the same `runsOf` the edge block does, and the
    // two passes are finally described by one rule.
    //
    // WHAT DID NOT MOVE is the assertion that matters most: `passVerts` is
    // still exactly `nv + n`, because merging changes how many CALLS carry the
    // points, never how many points. That is the exactness guard, and it went
    // on passing across the change.
    //
    // The leading 1 is the trap this block is built around: it is submitted in
    // every mode whether or not the mask consumer ever ran, so `calls >= 1`
    // and `verts > 0` are both satisfied by a mask that silently reported
    // nothing. Only the strict `> 1` on a NON-EMPTY selection proves the
    // consumer executed — that is the positive control here, and it survives
    // the merge, since even a fully contiguous selection still costs a second
    // call. It is why every pattern below except the first selects something.
    resetApp();
    auto model = gj("/api/model");
    immutable long nv = modelVertCount(model);
    assert(nv == 8, format("fixture premise: a cube has 8 vertices, got %d", nv));

    // Patterns applied IN SEQUENCE on one instance, with no /api/reset between
    // them: a mask that latched on its first value is correct once and wrong
    // afterwards, and a per-pattern reset would hide exactly that.
    foreach (pattern; [cast(long[])[], [0L, 2L, 4L], [0L,1L,2L,3L,4L,5L,6L,7L],
                       [7L], cast(long[])[]]) {
        selectVerts(pattern);
        settle();
        assert(selTypeNow() == "vertex",
               "asked for a vertex selection and the app is feeding back "
               ~ selTypeNow() ~ " — the rest of this block would be measuring "
               ~ "a different mode's draw path");

        auto w = lastScene();
        immutable long n = cast(long)pattern.length;
        bool[] selMask = new bool[](cast(size_t)nv);
        foreach (vi; pattern) selMask[cast(size_t)vi] = true;
        immutable long runs = runsOf(selMask, true);
        assert(passCalls(w, "verts") == 1 + runs,
               format("%d selected vertices in %d run(s): expected %d point "
                      ~ "submissions (1 cloud + %d run(s)), got %d",
                      n, runs, 1 + runs, runs, passCalls(w, "verts")));
        assert(passVerts(w, "verts") == nv + n,
               format("%d selected vertices: expected %d submitted points, got %d",
                      n, nv + n, passVerts(w, "verts")));
        if (n > 0)
            assert(passCalls(w, "verts") > 1,
                   "CONSUMER LIVENESS: the bare cloud submission is exactly 1 "
                   ~ "and happens whatever the mask says; > 1 is the only "
                   ~ "reading that proves the selection mask was consulted");
    }
}

unittest { // the EDGE mask reaches drawEdges with the right run structure
    resetApp();
    auto model = gj("/api/model");
    immutable long ne = modelEdgeCount(model);
    assert(ne == 12, format("fixture premise: a cube has 12 edges, got %d", ne));
    // 1:1 VBO segments is the premise expectedEdgeCalls is derived under.
    assert(passVerts(lastScene(), "edges") == 2 * ne,
           "fixture premise: the edge VBO is 1:1 with the cage edges");

    foreach (pattern; [cast(long[])[0L], [0L, 1L], [0L, 6L],
                       [0L,1L,2L,3L,4L,5L,6L,7L,8L,9L,10L,11L],
                       [3L], cast(long[])[]]) {
        selectEdgesBy(pattern);
        settle();
        assert(selTypeNow() == "edge", "not in the edge feedback type");

        auto mask = new bool[](cast(size_t)ne);
        foreach (i; pattern) mask[cast(size_t)i] = true;

        auto w = lastScene();
        assert(passCalls(w, "edges") == expectedEdgeCalls(mask),
               format("edge selection %s: expected %d edge-pass submissions, "
                      ~ "got %d", pattern, expectedEdgeCalls(mask),
                      passCalls(w, "edges")));
        assert(passCalls(w, "edges") >= 1,
               "CONSUMER LIVENESS: the edge pass must run in Edges mode");
    }
}

unittest { // the FACE selection drives BOTH the overlay and the face->edge cache
    // This is the block that covers the face->edge mask cache and its change
    // detector. The patterns run IN SEQUENCE with NO /api/reset between them
    // on purpose: a detector stuck at "unchanged" produces the right answer
    // for whichever pattern it happened to build first, and a suite that reset
    // between patterns would let it be accidentally correct every time.
    resetApp();
    auto model = gj("/api/model");
    assert(model["faces"].array.length == 6, "fixture premise: 6 cube faces");

    foreach (pattern; [cast(long[])[0L], [0L, 1L], [0L, 2L, 4L],
                       [0L,1L,2L,3L,4L,5L], [5L], cast(long[])[]]) {
        selectPolys(pattern);
        settle();
        assert(selTypeNow() == "polygon", "not in the polygon feedback type");

        auto w = lastScene();
        auto mask = edgeMaskForFaces(model, pattern);

        // The face->edge highlight cache, read through its consumer.
        assert(passCalls(w, "edges") == expectedEdgeCalls(mask),
               format("face selection %s implies the edge mask %s and so %d "
                      ~ "edge-pass submissions, got %d",
                      pattern, mask, expectedEdgeCalls(mask),
                      passCalls(w, "edges")));
        assert(passCalls(w, "edges") >= 1,
               "CONSUMER LIVENESS: the edge pass must run in Polygons mode");

        // The checker overlay: one submission per contiguous run of selected
        // faces, and the fan-triangulated vertices of exactly those faces.
        auto faceMask = new bool[](model["faces"].array.length);
        foreach (fi; pattern) faceMask[cast(size_t)fi] = true;
        assert(passCalls(w, "faceOverlay") == runsOf(faceMask, true),
               format("face selection %s is %d contiguous run(s), got %d "
                      ~ "overlay submissions", pattern, runsOf(faceMask, true),
                      passCalls(w, "faceOverlay")));
        assert(passVerts(w, "faceOverlay") == overlayVertsFor(model, pattern),
               format("face selection %s implies %d overlay verts, got %d",
                      pattern, overlayVertsFor(model, pattern),
                      passVerts(w, "faceOverlay")));
        if (pattern.length > 0)
            assert(passCalls(w, "faceOverlay") >= 1,
                   "CONSUMER LIVENESS: a non-empty face selection must draw "
                   ~ "the checker overlay");
    }
}

unittest { // MIXED FACE DEGREES — the one reading here that can see POSITION
    // On an all-quad cube `faceOverlay.verts == 6 * count`, so a mask shifted
    // by one face gives a byte-identical reading and this whole file is blind
    // to it. This fixture is six DISJOINT polygons of degree 3/4/5/4/3/5, so
    // the overlay's vertex count depends on WHICH faces are selected, not just
    // how many — and the assertion at the end of the block states that
    // explicitly rather than trusting the fixture to be non-degenerate.
    resetApp();
    string verts = "[", faces = "[";
    long[] deg = [3, 4, 5, 4, 3, 5];
    long next = 0;
    foreach (fi, d; deg) {
        immutable double ox = fi * 3.0;
        if (fi) { verts ~= ","; faces ~= ","; }
        faces ~= "[";
        foreach (k; 0 .. d) {
            immutable double ang = 2.0 * 3.14159265358979 * k / d;
            import std.math : cos, sin;
            if (k) { verts ~= ","; faces ~= ","; }
            verts ~= format("[%.6f,0,%.6f]", ox + cos(ang), sin(ang));
            faces ~= format("%d", next + k);
        }
        faces ~= "]";
        next += d;
    }
    verts ~= "]"; faces ~= "]";
    auto lm = parseJSON(httpPost("/api/load-mesh",
                        format(`{"vertices":%s,"faces":%s}`, verts, faces)));
    assert(lm["status"].str == "ok", "load-mesh failed: " ~ lm.toString);
    settle();

    auto model = gj("/api/model");
    assert(model["faces"].array.length == 6, "fixture: six polygons");
    foreach (fi, d; deg)
        assert(cast(long)model["faces"].array[fi].array.length == d,
               format("fixture: face %d should have degree %d", fi, d));

    foreach (pattern; [cast(long[])[0L], [1L], [2L], [0L, 1L, 2L], [1L, 2L, 3L],
                       cast(long[])[]]) {
        selectPolys(pattern);
        settle();
        auto w = lastScene();
        assert(passVerts(w, "faceOverlay") == overlayVertsFor(model, pattern),
               format("mixed-degree selection %s implies %d overlay verts, got %d",
                      pattern, overlayVertsFor(model, pattern),
                      passVerts(w, "faceOverlay")));
    }

    // The fixture is only worth its cost if a SHIFTED mask of the same size
    // reads differently — that is the error class an all-quad mesh hides.
    assert(overlayVertsFor(model, [0L]) != overlayVertsFor(model, [1L]),
           "fixture is inert: one face and its neighbour submit the same "
           ~ "number of overlay vertices, so a shifted mask is invisible");
    assert(overlayVertsFor(model, [0L, 1L, 2L]) != overlayVertsFor(model, [1L, 2L, 3L]),
           "fixture is inert for a 3-wide window");
}

unittest { // PRIMARY-LAYER SWITCH — the cache is not a function of the selection alone
    // The face->edge highlight cache read by the Polygons-mode edge pass is
    // built from the face selection AND from `faces`/`edges`. Its rebuild
    // trigger, however, can only compare the SELECTION. So the state it is
    // blind to on its own is two layers whose face marks agree
    // element-for-element while their edge lists do not: switch the primary
    // between them and the previous layer's edge mask paints this one's edges.
    //
    //   layer A — the reset cube: 6 faces, 12 edges. Face 5 is [0,1,5,4] and
    //             its edges are the SCATTERED {3,4,8,11}.
    //   layer B — six DISJOINT quads: 6 faces, 24 edges. Face 5's edges are
    //             the CONTIGUOUS {20,21,22,23}.
    //
    // Both carry a 6-long `faceMarks` with exactly face 5 set, so the marks
    // compare is false across the switch and cannot be what saves this. The
    // scattered-vs-contiguous shape is deliberate: it makes the two layers
    // imply different edge-pass batch COUNTS, which is the only thing this
    // file can see (the assertion below states that requirement rather than
    // trusting the fixture).
    //
    // MEASURED against a binary with the mesh-identity term removed from the
    // rebuild trigger: this block reads 1 submission where layer A implies 6.
    // Not a crash and not a wrong-looking number — B's 24-entry mask over A's
    // 12 edges reports false at every one of A's indices (a `MarkView` answers
    // false past its end), so the highlight silently disappears.
    resetApp();

    auto modelA = gj("/api/model");
    assert(modelA["faces"].array.length == 6, "fixture premise: 6 cube faces");
    assert(modelEdgeCount(modelA) == 12, "fixture premise: 12 cube edges");
    selectPolys([5L]);
    settle();
    assert(selTypeNow() == "polygon", "layer A is not in the polygon feedback type");
    immutable long wantA = expectedEdgeCalls(edgeMaskForFaces(modelA, [5L]));
    immutable long gotA  = passCalls(lastScene(), "edges");
    assert(gotA == wantA,
           format("layer A, face 5 selected: expected %d edge-pass submissions, got %d",
                  wantA, gotA));

    // ---- Layer B: same face count, same selected face, twice the edges ----
    cmd("layer.add name:B");
    string bVerts = "[", bFaces = "[";
    foreach (f; 0 .. 6) {
        immutable double ox = f * 3.0;
        immutable long base = f * 4;
        if (f) { bVerts ~= ","; bFaces ~= ","; }
        bVerts ~= format("[%.1f,0,0],[%.1f,0,0],[%.1f,0,1],[%.1f,0,1]",
                         ox, ox + 1.0, ox + 1.0, ox);
        bFaces ~= format("[%d,%d,%d,%d]", base, base + 1, base + 2, base + 3);
    }
    bVerts ~= "]"; bFaces ~= "]";
    auto lm = parseJSON(httpPost("/api/load-mesh",
                        format(`{"vertices":%s,"faces":%s}`, bVerts, bFaces)));
    assert(lm["status"].str == "ok", "load-mesh into layer B failed: " ~ lm.toString);
    settle();

    auto modelB = gj("/api/model");
    assert(modelB["faces"].array.length == 6 && modelEdgeCount(modelB) == 24,
           format("fixture premise: layer B is 6 faces / 24 edges, got %d / %d",
                  modelB["faces"].array.length, modelEdgeCount(modelB)));

    selectPolys([5L]);
    settle();
    assert(selTypeNow() == "polygon", "layer B is not in the polygon feedback type");
    immutable long wantB = expectedEdgeCalls(edgeMaskForFaces(modelB, [5L]));
    immutable long gotB  = passCalls(lastScene(), "edges");
    assert(gotB == wantB,
           format("layer B, face 5 selected: expected %d edge-pass submissions, got %d",
                  wantB, gotB));

    // Non-vacuity: a stale cache is only observable if the two layers imply
    // different readings in the first place.
    assert(wantA != wantB,
           format("fixture is inert: both layers imply %d edge-pass submissions, "
                  ~ "so a stale mask reads exactly like a fresh one", wantA));

    // ---- The switch ----
    // `layer.select` is an ITEM selection, so it moves the front of the
    // SelType order to Item and the Polygons draw branch stops running
    // altogether. The re-select that follows restores the polygon feedback
    // type by asking for the SAME face that is already selected — not one mark
    // bit changes, in either layer. That is precisely what leaves a
    // selection-only rebuild trigger blind, and it is an ordinary thing for a
    // user to do (click another layer, press 3).
    cmd("layer.select index:0");
    settle();
    selectPolys([5L]);
    settle();
    assert(selTypeNow() == "polygon",
           "back on layer A but not in the polygon feedback type");

    auto modelBack = gj("/api/model");
    assert(modelEdgeCount(modelBack) == 12,
           format("the primary is not layer A again (it reports %d edges) — the "
                  ~ "assertion below would be measuring the wrong mesh",
                  modelEdgeCount(modelBack)));

    immutable long gotBack = passCalls(lastScene(), "edges");
    assert(gotBack == wantA,
           format("after switching the primary back to layer A the edge pass "
                  ~ "submitted %d batches; layer A's own face-5 mask implies %d "
                  ~ "(layer B's implies %d). The face->edge highlight cache is "
                  ~ "still the one built for layer B: its rebuild trigger is "
                  ~ "reading the face selection alone, and the two layers' face "
                  ~ "marks are identical.", gotBack, wantA, wantB));

    resetApp();   // back to one layer for whatever runs next in this process
}
