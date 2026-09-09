// Loop Slice hover-parity via /api/tool/state — task 0234 (M4), reproducing
// the task 0231 hover-highlight fix as a data assertion instead of a
// screenshot. See tests/test_loop_slice_tool.d for the headless
// tool.attr/doApply coverage this file does NOT duplicate; this test drives
// the tool through a real cursor HOVER (play-events motion, no click) and
// reads the resulting `sliceRing` off `/api/tool/state`.
//
// Ground truth (default cube fixture, edge index 5 = the [5,6] edge between
// (0.5,-0.5,0.5) and (0.5,0.5,0.5)): the perpendicular cut ring
// (Mesh.loopSliceRingEdges, LoopSliceTool.edgeLoopHoverSliceRing()==true) is
// the cube's belt {0,2,5,7} (a closed ring — the raw array repeats the seed
// edge at the wrap, [5,7,0,2,5] in registration order). The classic PARALLEL
// edge loop (edgeLoopRing, what LoopSliceTool would report if the task 0231
// gate were reverted to `false`) degenerates to just the seed edge itself
// ({5}, raw [5,5]) on this cube — captured by temporarily reverting the gate
// during test authoring. The two sets are disjoint in everything but the
// seed edge, which is exactly what task 0231 fixed (the hover highlight used
// to show the wrong — parallel — ring).

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.string : format;
import std.algorithm : sort, uniq, count;
import std.array : array;
import std.stdio : writefln;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;

void resetCube() {
    auto resp = post(baseUrl ~ "/api/command", commandBody("scene.reset"));
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset failed: " ~ cast(string)resp);
}

void cmd(string s) {
    auto resp = post(baseUrl ~ "/api/script", s);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string)resp);
}

JSONValue getModel()     { return parseJSON(cast(string)get(baseUrl ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string)get(baseUrl ~ "/api/tool/state")); }

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

JSONValue lastScene() {
    return parseJSON(cast(string)get(baseUrl ~ "/api/frames/counts"))["lastScene"];
}

long edgeCalls() { return lastScene()["pass"]["edges"]["calls"].integer; }

long faceVertsFor(JSONValue model) {
    long result;
    foreach (face; model["faces"].array)
        if (face.array.length >= 3)
            result += (cast(long)face.array.length - 2) * 3;
    return result;
}

string fboHash() {
    auto j = parseJSON(cast(string)get(
        baseUrl ~ "/api/viewport/probe?cell=0&hash=1"));
    assert(j["renders"].type == JSONType.true_,
        "preview pixel oracle has no rendered FBO");
    return j["hash"].str;
}

long expectedHoverCalls(const bool[] mask) {
    long baseRuns = 0;
    long hovered = 0;
    bool inBaseRun = false;
    foreach (v; mask) {
        if (v) {
            hovered++;
            inBaseRun = false;
        } else if (!inBaseRun) {
            baseRuns++;
            inBaseRun = true;
        }
    }
    // One gray submission per unhovered run, then one submission per hovered
    // edge in each of the visible + occluded highlight passes.
    return baseRuns + 2 * hovered;
}

void restoreSharedApp() {
    try cmd("tool.set move off"); catch (Exception) {}
    try cmd("tool.set mesh.loopSliceTool off"); catch (Exception) {}
    try cmd("tool.pipe.attr falloff type none"); catch (Exception) {}
    try cmd("tool.pipe.attr actionCenter mode auto"); catch (Exception) {}
    try cmd("viewport.layout Single"); catch (Exception) {}
    settle();
}

// --- geometry helpers (mirror tests/test_loop_slice_tool.d) ---------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

// 5 stationary motion events (no button) at (x,y) — the same hover-injection
// pattern as tests/test_element_pick_stays.d's `hoverLog`.
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

int[] dedupSorted(JSONValue arr) {
    int[] xs;
    foreach (v; arr.array) xs ~= cast(int)v.integer;
    return xs.sort().uniq().array;
}

unittest { // task 0782: separate classic-loop -> slice-ring REAL DRAW witness
    resetCube();
    scope(exit) restoreSharedApp();

    auto model = getModel();
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    int ei = edgeIndex(model, va, vb);
    assert(ei == 5, "fixture premise: the discriminating cube edge is 5");

    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    float sx, sy;
    assert(projectToWindow(Vec3(0.5f, 0.0f, 0.5f), vp, sx, sy),
        "edge midpoint should be on-camera");
    immutable string hover = hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      cast(int)sx, cast(int)sy);

    // Classic edge-loop mode: Move + Element falloff + edgeLoops. On this
    // cube the classic walk is the non-empty singleton {5}.
    cmd("select.typeFrom edge");
    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff connect edgeLoops");
    playAndWait(hover);
    settle();
    auto classicState = parseJSON(cast(string)get(baseUrl ~ "/api/toolpipe/eval"));
    assert(classicState["hover"]["edge"].integer == ei,
        "classic arm did not keep the requested hovered edge");
    bool[] classicMask = new bool[](model["edges"].array.length);
    classicMask[ei] = true;
    assert(classicMask.count!(v => v) == 1,
        "classic mask must be non-empty");
    immutable long classicCalls = edgeCalls();
    assert(classicCalls == expectedHoverCalls(classicMask),
        format("CLASSIC DRAW: expected %d edge submissions for non-empty mask "
             ~ "%s, got %d", expectedHoverCalls(classicMask), classicMask,
               classicCalls));

    // Same mesh/topology and same hovered edge; only the tool's ring kind
    // changes. The renderer scratch must rebuild to the perpendicular belt.
    cmd("tool.set mesh.loopSliceTool on");
    playAndWait(hover);
    settle();
    auto sliceState = getToolState();
    assert(sliceState["hoveredEdge"].integer == ei,
        "slice arm did not keep the same hovered edge");
    int[] sliceRing = dedupSorted(sliceState["sliceRing"]);
    assert(sliceRing == [0, 2, 5, 7],
        "slice fixture changed: expected non-empty {0,2,5,7}, got "
        ~ sliceRing.to!string);
    bool[] sliceMask = new bool[](model["edges"].array.length);
    foreach (edge; sliceRing) sliceMask[edge] = true;
    assert(sliceMask.count!(v => v) == 4,
        "slice-ring mask must be non-empty");
    assert(classicMask != sliceMask,
        "classic and slice masks must differ or the cache-key cell is inert");
    immutable long sliceCalls = edgeCalls();
    assert(sliceCalls == expectedHoverCalls(sliceMask),
        format("SLICE-RING DRAW: expected %d edge submissions after same-mesh "
             ~ "classic->slice switch (both masks non-empty), got %d; stale "
             ~ "classic draw was %d", expectedHoverCalls(sliceMask),
               sliceCalls, classicCalls));
    writefln("[scene-loop-hover] edge=%d classicMask={5} calls=%d "
           ~ "sliceMask={0,2,5,7} calls=%d (both non-empty)",
             ei, classicCalls, sliceCalls);
}

unittest { // hover parity: sliceRing == perpendicular cut ring, != parallel edgeLoopRing
    resetCube();
    auto model = getModel();
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube verts (0.5,-0.5,0.5)/(0.5,0.5,0.5) not found");
    int ei = edgeIndex(model, va, vb);
    assert(ei >= 0, "cube edge (0.5,-0.5,0.5)-(0.5,0.5,0.5) not found");

    cmd("tool.set mesh.loopSliceTool on");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 mid = Vec3(0.5f, 0.0f, 0.5f);   // edge midpoint
    float sx, sy;
    assert(projectToWindow(mid, vp, sx, sy), "edge midpoint should be on-camera");

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int)sx, cast(int)sy));
    settle();

    auto st = getToolState();
    assert(st["tool"].str == "loopSlice",
        "expected loopSlice tool state, got: " ~ st.toString);
    assert(st["hoveredEdge"].integer == ei,
        "hoveredEdge mismatch: expected " ~ ei.to!string ~
        " got " ~ st["hoveredEdge"].integer.to!string);
    // Hover-only: no click happened, so no seed is latched and the mesh is
    // untouched (this test never posts a mouse button event).
    assert(st["seedEdge"].integer == -1,
        "seedEdge should be -1 pre-click (hover-only)");
    assert(st["dragging"].type == JSONType.false_,
        "must not be dragging on hover-only");

    int[] ring = dedupSorted(st["sliceRing"]);
    int[] expectedSliceRing = [0, 2, 5, 7];
    assert(ring == expectedSliceRing,
        "sliceRing (dedup) mismatch: expected " ~ expectedSliceRing.to!string ~
        " got " ~ ring.to!string ~
        " (raw: " ~ st["sliceRing"].toString ~ ")");

    // The classic PARALLEL edge loop through this seed degenerates to just
    // the seed edge on this cube (captured ground truth, see file header) —
    // asserting the reported ring ISN'T that confirms `sliceRing` really is
    // gated on `edgeLoopHoverSliceRing()` (task 0231's fix) rather than some
    // other, coincidentally-matching computation. Reverting that gate to
    // `false` flips `ring` to `[5]` and fails this assertion.
    int[] classicParallelRing = [ei];
    assert(ring != classicParallelRing,
        "sliceRing must NOT equal the classic parallel edge-loop ring — " ~
        "the 0231 perpendicular-ring gate looks reverted");

    cmd("tool.set mesh.loopSliceTool off");
    settle();
}

unittest { // hover-vs-active-drag: the ring highlight is a PRE-ARM affordance
    // Task 0246 (live highlight parity). The reference app's live Loop Slice
    // feedback splits into two states: a pre-commit HOVER (the ring the cut
    // will cross) and an ARMED/active drag (the standing preview + the "Loop
    // Slice Slider" position marker, NOT a mesh ring overlay). vibe3d mirrors
    // this: `wantsEdgeLoopHover()` is `!armed_`, so app.d draws the perpendicular
    // ring ONLY before arming and suppresses it once armed (hasUncommittedEdit).
    // This test locks the observable state transition that drives that switch:
    // hover -> armed==false (ring shown); a click-drag on the seed edge ->
    // armed==true (ring suppressed, live cut + slider shown instead).
    resetCube();
    scope(exit) restoreSharedApp();
    auto model = getModel();
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube seed verts not found");
    int ei = edgeIndex(model, va, vb);
    assert(ei >= 0, "cube seed edge not found");

    // Edge component mode BEFORE the tool activates: onMouseButtonDown only
    // arms in Edges/Polygons mode (hover works in any mode via the tool's
    // HoverEdges flag, but arming is mode-gated), and a front-flipping mode
    // switch drops the active tool — so set the mode first.
    cmd("select.typeFrom edge");
    cmd("tool.set mesh.loopSliceTool on");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 mid = Vec3(0.5f, 0.0f, 0.5f);   // seed edge midpoint
    float sx, sy;
    assert(projectToWindow(mid, vp, sx, sy), "seed midpoint should be on-camera");

    // (1) HOVER state: ring shown, nothing armed.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int)sx, cast(int)sy));
    settle();
    auto hov = getToolState();
    assert(hov["armed"].type == JSONType.false_,
        "must NOT be armed on hover-only (ring is the pre-arm affordance)");
    int[] hoverRing = dedupSorted(hov["sliceRing"]);
    assert(hoverRing == [0, 2, 5, 7],
        "hover ring should be the perpendicular belt, got " ~ hoverRing.to!string);
    auto beforeModel = getModel();
    auto beforeDraw = lastScene();
    immutable string beforePixels = fboHash();

    // (2) ARMED state: a click-drag on the seed edge arms the standing preview.
    // Model B mouse-up keeps it armed (no commit), so armed stays true after.
    // A tiny drag near the midpoint (hover already latched hoveredEdge==seed).
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int)sx, cast(int)sy,
                             cast(int)sx + 8, cast(int)sy, 6));
    settle();
    auto arm = getToolState();
    assert(arm["armed"].type == JSONType.true_,
        "a click-drag on the seed edge should arm the standing preview, got: "
        ~ arm.toString);
    assert(arm["seedEdge"].integer == ei,
        "armed seed should be the hovered edge " ~ ei.to!string ~
        ", got " ~ arm["seedEdge"].integer.to!string);
    assert(arm["built"].type == JSONType.true_,
        "arming materialises the default-position cut (built==true)");

    // Preview and its following scene submission are observed together. The
    // model is the live standing preview; the draw oracle is the independently
    // triangulated face-vertex count plus the actual FBO digest. A copied
    // pre-preview mesh input can satisfy the tool-state assertions above and
    // cannot satisfy these two draw assertions.
    auto previewModel = getModel();
    auto previewDraw = lastScene();
    immutable string previewPixels = fboHash();
    assert(previewModel["vertices"].array.length
           > beforeModel["vertices"].array.length,
        "standing preview did not change the live mesh");
    assert(previewDraw["seq"].integer > beforeDraw["seq"].integer,
        "no following scene frame consumed the standing preview");
    assert(previewDraw["pass"]["faces"]["verts"].integer
           == faceVertsFor(previewModel),
        format("PREVIEW DRAW: following scene submission used %d face verts, "
             ~ "but the live preview independently implies %d",
               previewDraw["pass"]["faces"]["verts"].integer,
               faceVertsFor(previewModel)));
    assert(previewPixels != beforePixels,
        "PREVIEW PIXELS: the standing preview left the FBO byte-identical");
    writefln("[scene-preview] seq %d->%d, faceVerts=%d, FBO %s->%s",
             beforeDraw["seq"].integer, previewDraw["seq"].integer,
             faceVertsFor(previewModel), beforePixels, previewPixels);

    cmd("tool.set mesh.loopSliceTool off");
    settle();
}
