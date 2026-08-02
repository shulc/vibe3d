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
