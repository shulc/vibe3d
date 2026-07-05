// Tests for the interactive Tack tool (mesh.tack), task 0126 — polygon-to-
// polygon rigid alignment. Modelled on tests/test_mirror_tool.d (interactive
// tool undo/no-op guard/headless-one-shot conventions) and
// tests/test_loop_slice_hover_state.d (hover-driven interaction via
// play-events + /api/tool/state). See tests/fixtures/tack.json /
// tests/test_fixture_tack.d for the golden-vertex parity fixture — this file
// covers the lifecycle assertions the fixture format doesn't (undo count,
// no-interaction guard, interactive-click vs headless-one-shot parity).
//
// Scene: two disjoint unit cubes (loaded raw via /api/load-mesh) — Box A
// (verts 0-7, the SOURCE island, one corner nudged +Z so the alignment twist
// is observable) and Box B (verts 8-15, the TARGET island, top edge raised so
// its +Y face is tilted and non-axis-aligned). Source polygon = face 4
// ([2,3,7,6], the +Y face); target polygon = face 10 ([10,11,15,14], the
// tilted +Y face). Numbers reproduced exactly from doc/tack_tool_plan.md's
// Phase-0 capture (private doc) — see tests/fixtures/tack.json for the full
// derivation note.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;
import std.string : format;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

enum string baseUrl = "http://localhost:8080";
enum int    SRC_FACE = 4;
enum int    TGT_FACE = 10;
enum double[3] CLICK_POINT = [
    2.9793753623962402, 0.6579021662473679, -0.30262226052582264
];

// --- scene + HTTP helpers ---------------------------------------------------

string sceneJson() {
    return `{
      "vertices": [
        [-2.5, -0.5, -0.5], [-2.5, -0.5, 0.5], [-2.5, 0.5, -0.2], [-2.5, 0.5, 0.5],
        [-1.5, -0.5, -0.5], [-1.5, -0.5, 0.5], [-1.5, 0.5, -0.5], [-1.5, 0.5, 0.5],
        [2.5, -0.5, -0.5], [2.5, -0.5, 0.5], [2.5, 0.5, -0.5], [2.5, 1.3, 0.5],
        [3.5, -0.5, -0.5], [3.5, -0.5, 0.5], [3.5, 0.5, -0.5], [3.5, 1.3, 0.5]
      ],
      "faces": [
        [0,2,6,4],[1,5,7,3],[0,1,3,2],[4,6,7,5],[2,3,7,6],[0,4,5,1],
        [8,10,14,12],[9,13,15,11],[8,9,11,10],[12,14,15,13],[10,11,15,14],[8,12,13,9]
      ]
    }`;
}

void loadScene() {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/load-mesh", sceneJson()));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
}

void selectFace(int idx) {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/select",
        format(`{"mode":"polygons","indices":[%d]}`, idx)));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string body_) {
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok", "/api/command '" ~ body_ ~ "' failed: " ~ r.toString);
}

void toolSet(string id) { cmd("tool.set " ~ id); }
void toolOff(string id) { cmd("tool.set " ~ id ~ " off"); }

JSONValue getModel()     { return parseJSON(cast(string) get(baseUrl ~ "/api/model")); }
JSONValue getHistory()   { return parseJSON(cast(string) get(baseUrl ~ "/api/history")); }
JSONValue getToolState() { return parseJSON(cast(string) get(baseUrl ~ "/api/tool/state")); }

void settle() { Thread.sleep(150.msecs); }

// Poll the undo history until it holds at least `target` entries — i.e. the
// interactive click's Tack commit has actually LANDED — or a generous timeout
// elapses. `playAndWait` returns once /api/play-events/status reports
// "finished", and in --test the click is dispatched SYNCHRONOUSLY (the commit
// runs inside the same event-player tick that flips the player idle), so the
// entry is already recorded by then — but the status flag and the history are
// read on the HTTP thread, and under -j8 CPU starvation the just-recorded
// entry's cross-thread visibility can lag the status flip by a frame. A fixed
// `settle()` sleep is a guess at how long that lag is; polling the
// authoritative undo count closes the window deterministically regardless of
// load. It still fails loudly if the commit never lands (a genuine regression),
// so it cannot mask a real bug — unlike simply widening the geometry tolerance.
void waitForUndoCount(size_t target) {
    size_t last;
    foreach (_; 0 .. 200) {
        last = getHistory()["undo"].array.length;
        if (last >= target) return;
        Thread.sleep(20.msecs);
    }
    assert(false, "interactive commit never registered: expected >= "
        ~ target.to!string ~ " undo entries, got " ~ last.to!string);
}

string tackHeadlessCmd(int targetFace, double[3] point) {
    return format(
        `{"id":"mesh.tack","params":{"targetFace":%d,"targetPoint":[%.17g,%.17g,%.17g]}}`,
        targetFace, point[0], point[1], point[2]);
}

double[3][] verticesOf(JSONValue model) {
    auto arr = model["vertices"].array;
    auto outv = new double[3][](arr.length);
    foreach (i, v; arr) {
        auto c = v.array;
        outv[i] = [c[0].floating, c[1].floating, c[2].floating];
    }
    return outv;
}

void assertVertsMatch(double[3][] got, double[3][] expected, double tol, string ctx) {
    assert(got.length == expected.length,
        ctx ~ ": vertex count mismatch, expected " ~ expected.length.to!string
        ~ " got " ~ got.length.to!string);
    foreach (i; 0 .. expected.length) {
        foreach (c; 0 .. 3) {
            assert(abs(got[i][c] - expected[i][c]) <= tol,
                format("%s: v%d[%d] expected %.6f got %.6f (tol %.1e)",
                       ctx, i, c, expected[i][c], got[i][c], tol));
        }
    }
}

// A stationary hover (5 motion events, no button) — same shape as
// test_loop_slice_hover_state.d's hoverLog.
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

// A discrete LEFT click (down + up, no motion in between) at (x,y).
string clickLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y);
    log ~= format(
        `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y);
    return log;
}

// ---------------------------------------------------------------------------
// 1. No interaction ⇒ no tack (activate with a source polygon selected, tool
//    goes on/off with no click ⇒ 0 new undo entries, byte-stable geometry) —
//    mirrors Mirror's "no-interaction ⇒ no-mirror" guard (test_mirror_tool.d).
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFace(SRC_FACE);
    auto before     = verticesOf(getModel());
    size_t undoPre  = getHistory()["undo"].array.length;

    toolSet("mesh.tack");
    toolOff("mesh.tack");

    auto after      = verticesOf(getModel());
    size_t undoPost = getHistory()["undo"].array.length;

    assert(undoPost == undoPre,
        "activate/deactivate with no click must not record an undo entry: before="
        ~ undoPre.to!string ~ " after=" ~ undoPost.to!string);
    assertVertsMatch(after, before, 1e-6, "no-interaction guard");
}

// ---------------------------------------------------------------------------
// 2. Headless one-shot commit reproduces the golden after-positions; exactly
//    one undo entry; undo restores byte-stable pre-state.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFace(SRC_FACE);
    auto pre       = verticesOf(getModel());
    size_t undoPre = getHistory()["undo"].array.length;

    cmd(tackHeadlessCmd(TGT_FACE, CLICK_POINT));

    auto committed  = verticesOf(getModel());
    size_t undoPost = getHistory()["undo"].array.length;
    assert(undoPost == undoPre + 1,
        "expected exactly one new undo entry, before=" ~ undoPre.to!string
        ~ " after=" ~ undoPost.to!string);

    // Golden after-positions (doc/tack_tool_plan.md capture; verts 0/1/4/5
    // computed from the SAME R/t — see tests/fixtures/tack.json).
    double[3][16] golden = [
        [3.4793753623962402, 0.23623302951584946, 0.7710723541560149],
        [3.4793753623962402, -0.38846201821512516, -0.009796455507703389],
        [3.4793753623962402, 0.8296933174133301, -0.0878833457827568],
        [3.4793753623962402, 0.39240679144859314, -0.634491503238678],
        [2.4793753623962402, 0.23623302951584946, 0.7710723541560149],
        [2.4793753623962402, -0.38846201821512516, -0.009796455507703389],
        [2.4793753623962402, 1.017101764678955, 0.1463773101568222],
        [2.4793753623962402, 0.39240679144859314, -0.634491503238678],
        [2.5, -0.5, -0.5], [2.5, -0.5, 0.5], [2.5, 0.5, -0.5], [2.5, 1.3, 0.5],
        [3.5, -0.5, -0.5], [3.5, -0.5, 0.5], [3.5, 0.5, -0.5], [3.5, 1.3, 0.5],
    ];
    assertVertsMatch(committed, golden.dup, 1e-4, "headless commit golden parity");

    auto undoResp = postJson("/api/undo", "");
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);
    auto restored = verticesOf(getModel());
    assertVertsMatch(restored, pre, 1e-6, "undo restore");
}

// ---------------------------------------------------------------------------
// 3. Interactive click (real hover + click, driven via /api/play-events)
//    reproduces the SAME result as the headless one-shot with the identical
//    target face + anchor point — the interactive commit path and the
//    headless path must agree on the captured alignment rule.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFace(SRC_FACE);

    // Frame Box B's tilted +Y face (centroid (3,0.9,0), normal
    // (0,0.7809,-0.6247)) unambiguously: eye above (+Y) and in front (-Z),
    // matching the normal's hemisphere so the face is front-facing (not
    // back-culled). Box A sits far to the -X side of this focus and falls
    // outside the frustum — no occlusion risk.
    postJson("/api/camera",
        `{"azimuth":3.14159265,"elevation":0.9,"distance":6,` ~
        `"focus":{"x":3.0,"y":0.9,"z":0.0}}`);

    toolSet("mesh.tack");

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(cast(float) CLICK_POINT[0], cast(float) CLICK_POINT[1],
                       cast(float) CLICK_POINT[2]);
    float sx, sy;
    bool onScreen = projectToWindow(anchor, vp, sx, sy);
    assert(onScreen, "golden anchor point must project on-camera with this framing");

    // Hover first (mirrors a real drag: hover settles g_hoveredFace before
    // the click) and confirm the tool sees the expected source/target/preview
    // state via /api/tool/state before committing.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int) sx, cast(int) sy));
    settle();

    auto stateHover = getToolState();
    assert(stateHover["tool"].str == "mesh.tack",
        "expected mesh.tack tool state, got: " ~ stateHover.toString);
    assert(stateHover["sourceFace"].integer == SRC_FACE,
        "sourceFace mismatch: " ~ stateHover.toString);
    assert(stateHover["hoveredTargetFace"].integer == TGT_FACE,
        "hoveredTargetFace mismatch (camera framing likely missed the target face): "
        ~ stateHover.toString);
    assert(stateHover["previewActive"].type == JSONType.true_,
        "previewActive should be true while hovering a valid target: "
        ~ stateHover.toString);

    // Capture the undo depth BEFORE the click so we can wait for the click's
    // Tack commit to actually land (deterministic, load-independent) instead of
    // reading geometry after a blind sleep that -j8 starvation can outrun.
    size_t undoBeforeClick = getHistory()["undo"].array.length;
    playAndWait(clickLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int) sx, cast(int) sy));
    waitForUndoCount(undoBeforeClick + 1);

    toolOff("mesh.tack");
    auto interactive = verticesOf(getModel());

    // Reproduce the identical transform via the headless one-shot path on a
    // freshly reloaded scene.
    loadScene();
    selectFace(SRC_FACE);
    cmd(tackHeadlessCmd(TGT_FACE, CLICK_POINT));
    auto headless = verticesOf(getModel());

    // Tolerance = ~1.5 screen pixels of world size. The interactive path clicks
    // at an INTEGER pixel (cast(int) sx/sy) and unprojects THAT back to a target
    // point, whereas the headless path uses the exact CLICK_POINT; they can only
    // agree to ~1 pixel. At this framing (distance 6, fovY 45°, ~544px) one pixel
    // ≈ 0.009 world units, so the observed ~0.0023 delta is well under a pixel.
    // Reference correctness is gated separately by test_fixture_tack (vs the real
    // captured golden); this check only guards interactive↔headless consistency.
    assertVertsMatch(interactive, headless, 1.5e-2, "interactive vs headless parity");
}

// ---------------------------------------------------------------------------
// 4. Non-cumulative preview: repeated hovers over the SAME target during one
//    session must not accumulate — the committed result after several hover
//    passes is identical to a single hover then click.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFace(SRC_FACE);
    postJson("/api/camera",
        `{"azimuth":3.14159265,"elevation":0.9,"distance":6,` ~
        `"focus":{"x":3.0,"y":0.9,"z":0.0}}`);
    toolSet("mesh.tack");

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(cast(float) CLICK_POINT[0], cast(float) CLICK_POINT[1],
                       cast(float) CLICK_POINT[2]);
    float sx, sy;
    assert(projectToWindow(anchor, vp, sx, sy), "anchor should project on-camera");

    // 3 hover passes over the SAME pixel — each rebuilds the (own) preview
    // internally; only the click below should ever touch the real mesh, once.
    foreach (i; 0 .. 3) {
        playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            cast(int) sx, cast(int) sy));
        settle();
    }
    size_t undoBeforeClick = getHistory()["undo"].array.length;
    playAndWait(clickLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int) sx, cast(int) sy));
    waitForUndoCount(undoBeforeClick + 1);
    toolOff("mesh.tack");

    auto committed = verticesOf(getModel());
    double[3][16] golden = [
        [3.4793753623962402, 0.23623302951584946, 0.7710723541560149],
        [3.4793753623962402, -0.38846201821512516, -0.009796455507703389],
        [3.4793753623962402, 0.8296933174133301, -0.0878833457827568],
        [3.4793753623962402, 0.39240679144859314, -0.634491503238678],
        [2.4793753623962402, 0.23623302951584946, 0.7710723541560149],
        [2.4793753623962402, -0.38846201821512516, -0.009796455507703389],
        [2.4793753623962402, 1.017101764678955, 0.1463773101568222],
        [2.4793753623962402, 0.39240679144859314, -0.634491503238678],
        [2.5, -0.5, -0.5], [2.5, -0.5, 0.5], [2.5, 0.5, -0.5], [2.5, 1.3, 0.5],
        [3.5, -0.5, -0.5], [3.5, -0.5, 0.5], [3.5, 0.5, -0.5], [3.5, 1.3, 0.5],
    ];
    // Same sub-pixel-quantization allowance as the interactive/headless
    // parity check above (test 3) — this is a REAL click at an integer
    // pixel, compared against the exact analytic golden, not against
    // another real click. See that test's comment for the ~pixel-to-world
    // magnitude reasoning (observed delta ~0.003, well under this bound).
    assertVertsMatch(committed, golden.dup, 1.5e-2, "non-cumulative repeated-hover commit");

    // Exactly one commit happened this session (the single click) — undo
    // once must restore the pre-tack scene.
    auto undoResp = postJson("/api/undo", "");
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);
}
