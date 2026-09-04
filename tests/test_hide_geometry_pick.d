// Hide Geometry — Stage 4 (doc/hide_geometry_plan.md §6 S4): the pick and snap
// paths that do NOT go through the GPU buffers, plus the affordance that keeps
// the hidden state from being invisible (R9).
//
// Stage 3 took hidden geometry out of the VBOs, which took it out of the
// viewport AND out of the ID-buffer picker in one edit. What that did NOT
// reach is everything that reads the MESH instead of the buffers:
//
//   * the BVH face picker (`bvh_pick.d`) — it fan-triangulates `mesh.faces`;
//   * the snap service (`snap.d` + `Mesh.visibleVertices`) — it walks
//     `mesh.vertices` / `mesh.edges` / `mesh.faces`;
//   * the CPU lasso (`app.d`) — six branches that project raw mesh positions.
//
// Every assertion below reads through `/api/pick`, `/api/snap`,
// `/api/selection` and `/api/gpu/face-vbo`. Fixtures are built with
// `/api/load-mesh` rather than the default cube wherever the cube cannot
// express the discriminator — a closed cube has no face that is BOTH hidden
// and in front of another front-facing face, which is the only arrangement
// that tells "excluded because hidden" apart from "excluded because
// back-facing".
//
// ---------------------------------------------------------------------------
// WHAT IS DELIBERATELY NOT ASSERTED, and why (so nobody adds it back)
// ---------------------------------------------------------------------------
//
// 1. "A hidden face is not lasso-selected in Polygons mode" is INERT at this
//    HEAD — measured, not reasoned: with the `isFaceHidden` guard deleted from
//    BOTH polygon branches the lasso still selects exactly {1,3,5} on the
//    strip fixture below. TWO independent mechanisms already reject it and
//    either alone is enough: a hidden face contributes no pixels to the face
//    ID buffer after S3, so the pre-existing occlusion gate
//    (`!gpuVisible[fi] -> continue`) drops it; and §3.1's `Select ∧ Hide = ∅`
//    makes selecting one a no-op in the mark writer regardless. The guards are
//    kept — the plan is explicit that the occlusion gate is skipped whenever
//    `gpuVisible is null`, so relying on it would be a filter that works in
//    the common case and silently fails in the other — but they are recorded
//    here as REVIEWED AND UNCOVERED rather than dressed up in a test that
//    reads the same number either way. See section C.
//
// 1b. The same is true of the FILTER half of the vertex and edge cage
//    branches, and it is worth separating from the KEY half because only one
//    of the two is covered. Reverting branch 4/6 to its exact pre-S4 shape (no
//    hidden guard AND a cage-keyed mask) reads `[2..11, 15, 16]` — the same
//    wrong answer as reverting the key alone, because §3.1 silently swallows
//    the attempt to select the two hidden vertices. So what the vertex/edge
//    rows below actually pin is the VBO-slot translation, which nothing else
//    in the program provides. The `isXHidden` guard on those branches earns
//    its place by keeping the slot counter in lockstep with `upload`, not by
//    filtering.
//
// 2. The "N hidden" readout is an ImGui label, and no endpoint in this
//    codebase reads ImGui label text (`/api/viewport/probe` reads a viewport
//    cell's FBO; the panels draw to the default framebuffer). Section D
//    proves the chain that IS reachable and says how the last link was
//    checked instead.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.algorithm : sort;
import core.thread : Thread;
import core.time : msecs;

void main() {}

alias BASE = testBaseUrl;


void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok", "/api/command " ~ script ~ " failed: " ~ r.toString);
}
void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }

void resetApp() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

/// Select `indices` in `mode` ("polygons"/"vertices"/"edges"), switching the
/// geometry type first — the sequence every other hide test in this family
/// uses.
void selectMode(string mode, int[] indices) {
    immutable string tok = mode == "polygons" ? "polygon"
                         : mode == "edges"    ? "edge" : "vertex";
    cmd("select.typeFrom " ~ tok);
    string idx = "[";
    foreach (i, v; indices) { if (i) idx ~= ","; idx ~= v.to!string; }
    idx ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idx ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

/// Hide the given polygons. Returns with the selection dropped (the hide
/// clears Select on what it hides — §3.1).
void hidePolygons(int[] faces) {
    selectMode("polygons", faces);
    cmdId("mesh.hide");
}

void loadMesh(string json) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", json));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

/// Camera FIRST-CLASS ORDERING NOTE: `/api/load-mesh` resets the camera, so
/// every fixture below sets the camera AFTER loading, never before.
void lookDownZ(double distance) {
    auto r = postJson("/api/camera", format(
        `{"azimuth":0.0,"elevation":0.0,"distance":%.3f,"focus":{"x":0,"y":0,"z":0}}`,
        distance));
    assert(r["status"].str == "ok", "/api/camera failed: " ~ r.toString);
}

int[] hiddenFaceList() {
    int[] r;
    foreach (i, b; getJson("/api/model")["faceHidden"].array)
        if (b.type == JSONType.true_) r ~= cast(int)i;
    return r;
}
int countHidden(string key) {
    int n = 0;
    foreach (b; getJson("/api/model")[key].array) if (b.type == JSONType.true_) ++n;
    return n;
}

int pickFaceAt(int x, int y, string engine) {
    auto j = getJson(format("/api/pick?x=%d&y=%d&engine=%s", x, y, engine));
    return cast(int)j["faceIndex"].integer;
}

struct Vp { int x, y, w, h; }
Vp viewport() {
    auto c = getJson("/api/camera");
    return Vp(cast(int)c["vpX"].integer, cast(int)c["vpY"].integer,
              cast(int)c["width"].integer, cast(int)c["height"].integer);
}

int[] selected(string key) {
    int[] r;
    foreach (v; getJson("/api/selection")[key].array) r ~= cast(int)v.integer;
    r.sort();
    return r;
}

// ---------------------------------------------------------------------------
// Section A — T-S4: hidden geometry is unpickable, in BOTH face-pick engines
// ---------------------------------------------------------------------------
//
// The discriminator is what the pick RETURNS, not that it misses. Asserting
// "the pick misses" would pass an implementation that merely nulls the hit;
// asserting it returns THE FACE BEHIND only passes if the hidden face left the
// depth pre-pass (GPU) / the BVH (CPU) as well as the colour pass.
//
// `engine=gpu` is the CONTROL here: it reads the ID buffer, which S3 already
// emptied of hidden faces, so it is green before this stage. `engine=bvh` is
// the row this stage exists for — the BVH is built from `mesh.faces`, which
// S3 never touched. Running only the gpu row would look like a pass.

unittest { // T-S4 — hide the front face of a cube, pick its screen centre.
    resetApp();
    lookDownZ(3.0);
    auto vp = viewport();
    immutable int cx = vp.x + vp.w / 2;
    immutable int cy = vp.y + vp.h / 2;

    // Control: with nothing hidden BOTH engines report the +Z face (1).
    assert(pickFaceAt(cx, cy, "gpu") == 1, "control gpu pick must be face 1");
    assert(pickFaceAt(cx, cy, "bvh") == 1, "control bvh pick must be face 1");

    hidePolygons([1]);
    assert(hiddenFaceList() == [1], "setup: exactly face 1 hidden");

    // The answer is 0 — the −Z face, which is the one BEHIND the hidden one.
    // A pick that merely refused to return a hidden face would report −1 here,
    // and −1 is what a hidden face still sitting in the depth pre-pass would
    // also produce, so 0 separates three implementations, not two.
    assert(pickFaceAt(cx, cy, "gpu") == 0,
        "gpu pick through a hidden front face must return the face BEHIND it (0), got "
        ~ pickFaceAt(cx, cy, "gpu").to!string);
    assert(pickFaceAt(cx, cy, "bvh") == 0,
        "bvh pick through a hidden front face must return the face BEHIND it (0), got "
        ~ pickFaceAt(cx, cy, "bvh").to!string);

    // And it comes back. `mesh.unhideAll` re-uploads (S3) and bumps the keys
    // both engines cache on, so a stale BVH would keep answering 0 here.
    cmdId("mesh.unhideAll");
    assert(hiddenFaceList().length == 0, "unhideAll must clear the hide");
    assert(pickFaceAt(cx, cy, "gpu") == 1, "gpu pick must return to face 1 after unhide");
    assert(pickFaceAt(cx, cy, "bvh") == 1, "bvh pick must return to face 1 after unhide");
}

unittest { // T-S4 — a fully hidden mesh is not pickable at all.
    // The isolate trap's end state (R9), reached the way a user reaches it —
    // see section D, which asserts the affordance for exactly this state.
    resetApp();
    lookDownZ(3.0);
    auto vp = viewport();
    immutable int cx = vp.x + vp.w / 2;
    immutable int cy = vp.y + vp.h / 2;

    hidePolygons([0]);
    // The hide DROPPED the selection, and §3.1 refuses to put it back on a
    // hidden face — so "isolate onto face 0" isolates onto nothing and hides
    // the whole mesh. That is the reference's behaviour and is not guarded.
    selectMode("polygons", [0]);
    assert(selected("selectedFaces").length == 0,
        "§3.1: a hidden face cannot be selected, so the isolate has no target");
    cmdId("mesh.hideUnselected");
    assert(hiddenFaceList() == [0, 1, 2, 3, 4, 5], "the whole cube must be hidden now");

    assert(pickFaceAt(cx, cy, "gpu") == -1, "nothing visible ⇒ no gpu pick");
    assert(pickFaceAt(cx, cy, "bvh") == -1, "nothing visible ⇒ no bvh pick");
}

// ---------------------------------------------------------------------------
// Section B — snap does not cement to hidden geometry
// ---------------------------------------------------------------------------
//
// TWO fixtures, because the two edits this section covers need DIFFERENT
// geometry to be told apart, and the first fixture written here could not tell
// them apart at all (measured — see the note on B2).
//
// B1 — two parallel quads, both wound to face +Z, at z=+0.5 (face 0) and
// z=−0.5 (face 1), camera straight down −Z. The back quad is the same size, so
// perspective projects it strictly INSIDE the front one's screen polygon: it
// is fully occluded while the front quad is visible.
//
// This is the arrangement a cube cannot provide. On a cube the face behind the
// front one is BACK-facing, so "the snap stopped landing there" is explained by
// the pre-existing back-face cull and proves nothing about hiding. Here both
// candidates are front-facing and the ONLY thing that moves the answer from
// z=+0.5 to z=−0.5 is the hide.
//
// What B1 covers: `Mesh.visibleVertices` dropping hidden faces from its
// seed-and-occlude pass. Leave that out and the hidden quad both keeps seeding
// its own corners AND keeps occluding the back quad's.
//
// B2 — a 3×3 grid of quads plus one quad behind the CENTRE cell. B1 cannot
// cover `snap.d`'s `faceVisible` index guard and it is worth saying why,
// because the obvious reading is that it should: each of B1's quads owns its
// four corners outright, so hiding one derives all four of its corners hidden,
// and `faceVisible`'s pre-existing all-corners test then rejects the face
// whether or not the index guard is there. Deleting the guard leaves B1 green
// — measured, not reasoned.
//
// The grid is the fixture where the two answers differ: the centre cell's four
// corners each touch four quads, so hiding ONLY the centre cell derives NOT
// ONE hidden vertex (the fixture asserts that), and the all-corners test says
// "visible". The index guard is then the only thing standing between the snap
// and a face that is not on screen.

enum string TWO_QUADS = `{"vertices":[
  [-0.5,-0.5, 0.5],[0.5,-0.5, 0.5],[0.5,0.5, 0.5],[-0.5,0.5, 0.5],
  [-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5]],
  "faces":[[0,1,2,3],[4,5,6,7]]}`;

JSONValue snapAtCentre(string types, bool hideFront) {
    resetApp();
    loadMesh(TWO_QUADS);
    lookDownZ(3.0);
    if (hideFront) {
        hidePolygons([0]);
        assert(hiddenFaceList() == [0], "setup: exactly the FRONT quad hidden");
    }
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types " ~ types);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto vp = viewport();
    return postJson("/api/snap", format(
        `{"cursor":[0.0,0.0,0.0],"sx":%d,"sy":%d,"excludeVerts":[]}`,
        vp.x + vp.w / 2, vp.y + vp.h / 2));
}

double snapZ(JSONValue sr) { return sr["worldPos"].array[2].floating; }
bool snapped(JSONValue sr) { return sr["snapped"].type == JSONType.true_; }

unittest { // snap: every geometric type moves from the hidden quad to the one behind
    foreach (types; ["vertex", "edge", "polygon", "polyCenter"]) {
        auto visible = snapAtCentre(types, false);
        assert(snapped(visible), types ~ ": control must snap, got " ~ visible.toString);
        assert(snapZ(visible) > 0.4,
            types ~ ": control must land on the FRONT quad (z=+0.5), got "
            ~ visible.toString);

        auto hidden = snapAtCentre(types, true);
        assert(snapped(hidden),
            types ~ ": hiding the front quad must leave the BACK quad snappable, got "
            ~ hidden.toString);
        assert(snapZ(hidden) < -0.4,
            types ~ ": snap must land on the quad BEHIND the hidden one (z=-0.5), got "
            ~ hidden.toString);
    }
}

unittest { // snap: the target INDEX moves too, not just the depth
    // z alone could in principle be reached by snapping to the right plane for
    // the wrong reason; the element identity cannot.
    auto sr = snapAtCentre("polygon", true);
    assert(cast(int)sr["targetIndex"].integer == 1,
        "polygon snap must elect face 1 (the visible quad), got " ~ sr.toString);
    auto ctl = snapAtCentre("polygon", false);
    assert(cast(int)ctl["targetIndex"].integer == 0,
        "control: polygon snap must elect face 0, got " ~ ctl.toString);
}

// --- B2: the fixture that reaches `faceVisible`'s index guard ---------------
//
// 3×3 grid of 0.4-wide quads in z=0 (faces 0..8, centre = 4) plus a 0.4-wide
// quad at z=−0.5 behind the centre cell (face 9), which perspective projects
// strictly inside face 4 — occluded exactly while face 4 is drawn.

enum string GRID_HOLE = `{"vertices":[
  [-0.6,-0.6,0.0],[-0.2,-0.6,0.0],[0.2,-0.6,0.0],[0.6,-0.6,0.0],
  [-0.6,-0.2,0.0],[-0.2,-0.2,0.0],[0.2,-0.2,0.0],[0.6,-0.2,0.0],
  [-0.6, 0.2,0.0],[-0.2, 0.2,0.0],[0.2, 0.2,0.0],[0.6, 0.2,0.0],
  [-0.6, 0.6,0.0],[-0.2, 0.6,0.0],[0.2, 0.6,0.0],[0.6, 0.6,0.0],
  [-0.2,-0.2,-0.5],[0.2,-0.2,-0.5],[0.2,0.2,-0.5],[-0.2,0.2,-0.5]],
  "faces":[[0,1,5,4],[1,2,6,5],[2,3,7,6],[4,5,9,8],[5,6,10,9],[6,7,11,10],
           [8,9,13,12],[9,10,14,13],[10,11,15,14],[16,17,18,19]]}`;

JSONValue snapGridHole(string types, bool hideCentre) {
    resetApp();
    loadMesh(GRID_HOLE);
    lookDownZ(3.0);
    if (hideCentre) {
        hidePolygons([4]);
        assert(hiddenFaceList() == [4], "setup: exactly the centre cell hidden");
        // THE PROPERTY THAT MAKES THIS FIXTURE WORK, asserted rather than
        // assumed: not one vertex derives hidden, because every corner of the
        // centre cell still touches three visible cells. So `faceVisible`'s
        // all-corners test cannot reject face 4 — only the index guard can.
        assert(countHidden("vertexHidden") == 0,
            "fixture broken: hiding the centre cell must derive NO hidden vertex");
        assert(countHidden("edgeHidden") == 0,
            "fixture broken: hiding the centre cell must derive NO hidden edge");
    }
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types " ~ types);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto vp = viewport();
    return postJson("/api/snap", format(
        `{"cursor":[0.0,0.0,0.0],"sx":%d,"sy":%d,"excludeVerts":[]}`,
        vp.x + vp.w / 2, vp.y + vp.h / 2));
}

unittest { // snap: a hidden face whose corners are ALL still visible
    foreach (types; ["polygon", "polyCenter"]) {
        auto ctl = snapGridHole(types, false);
        assert(snapped(ctl) && cast(int)ctl["targetIndex"].integer == 4,
            types ~ ": control must elect the centre cell (face 4), got " ~ ctl.toString);

        auto sr = snapGridHole(types, true);
        assert(snapped(sr),
            types ~ ": the quad behind the hole must still be snappable, got "
            ~ sr.toString);
        assert(cast(int)sr["targetIndex"].integer == 9,
            types ~ ": snap must elect the quad BEHIND the hidden cell (face 9), "
            ~ "not the hidden cell itself; got " ~ sr.toString);
        assert(snapZ(sr) < -0.4,
            types ~ ": and it must land at z=-0.5, got " ~ sr.toString);
    }
}

// ---------------------------------------------------------------------------
// Section C — T-S4b: the CPU lasso, all six branches
// ---------------------------------------------------------------------------
//
// FIXTURE — a 6-quad strip in the z=0 plane (7 vertex columns, 14 verts,
// 22 edges) plus one triangle at z=−1 sitting in the strip's shadow. Camera
// straight down −Z.
//
// Three properties, each carrying its own weight:
//
//   * ALTERNATING hidden faces {0,2,4}. A branch that forgot the filter
//     selects a strictly larger, enumerable set — not merely "more".
//   * The hide lands at INDEX 0. Column 0's two vertices belong to face 0 and
//     to nothing else, so hiding {0,2,4} derives vertices {0,1} hidden and
//     edges {0,2,3} hidden — all at the low end. This is the trap R11 names:
//     `elementVisibility` returns a mask indexed by VBO SLOT, and once
//     `upload` skips hidden vertices/edges the slot number stops being the
//     cage number. A branch that kept the cage key reads its NEIGHBOUR's
//     visibility.
//   * The TRIANGLE is occluded but NOT hidden. Without it the slot shift
//     would be unobservable: if every element is gpu-visible the mask is all
//     true and reading the wrong entry gives the right answer. The triangle
//     puts three `false` entries at the top of the mask, so a cage-keyed
//     lookup rejects three elements that ARE visible and accepts elements
//     past the end of the mask — a set of the SAME SIZE and different
//     members, which is precisely what a count-only assertion would pass.

string stripScene() {
    string v = "[";
    foreach (i; 0 .. 7) {
        immutable double x = -1.5 + 0.5 * i;
        if (i) v ~= ",";
        v ~= format("[%.4f,-0.25,0.0],[%.4f,0.25,0.0]", x, x);
    }
    // The occluded triangle — inside face 3's screen footprint at z=−1.
    v ~= ",[0.10,-0.15,-1.0],[0.50,-0.15,-1.0],[0.30,0.15,-1.0]]";
    string f = "[";
    foreach (i; 0 .. 6) {
        if (i) f ~= ",";
        f ~= format("[%d,%d,%d,%d]", 2*i, 2*i + 2, 2*i + 3, 2*i + 1);
    }
    f ~= ",[14,15,16]]";
    return `{"vertices":` ~ v ~ `,"faces":` ~ f ~ `}`;
}

/// A right-mouse rectangle over the whole viewport interior, as an event log.
/// The VIEWPORT meta line is stamped from the LIVE layout so `EventPlayer`'s
/// replay remap is an identity pass-through whatever the window size is.
string lassoLog(Vp vp) {
    immutable int x0 = vp.x + 8,      y0 = vp.y + 8;
    immutable int x1 = vp.x + vp.w - 8, y1 = vp.y + vp.h - 8;
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":150.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":200.0,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":250.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":300.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":1,"state":4,"mod":0}` ~ "\n" ~
        `{"t":350.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":-1,"yrel":0,"state":4,"mod":0}` ~ "\n" ~
        `{"t":400.0,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        vp.x, vp.y, vp.w, vp.h,
        x0, y0, x0, y0, x1, y0, x1, y1, x0, y1, x0, y1);
}

void playAndWait(string log) {
    auto resp = post(BASE ~ "/api/play-events", log);
    assert(parseJSON(cast(string)resp)["status"].str == "success",
        "play-events failed: " ~ cast(string)resp);
    foreach (_; 0 .. 100) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(50.msecs);
    }
    Thread.sleep(250.msecs);   // post-playback drain settle
}

/// Build the strip, optionally turn every face into a subpatch (which puts the
/// lasso on its PREVIEW branches), hide {0,2,4}, then lasso everything in
/// `mode`. Returns the resulting selection.
int[] lassoStrip(string mode, bool preview) {
    resetApp();
    loadMesh(stripScene());
    lookDownZ(5.0);
    if (preview) {
        selectMode("polygons", [0, 1, 2, 3, 4, 5, 6]);
        cmdId("mesh.subpatch_toggle");
        selectMode("polygons", []);
    }
    hidePolygons([0, 2, 4]);
    assert(hiddenFaceList() == [0, 2, 4], "setup: faces {0,2,4} hidden");
    assert(countHidden("vertexHidden") == 2,
        "setup: exactly the two column-0 vertices derive hidden");
    assert(countHidden("edgeHidden") == 3,
        "setup: exactly the three edges touching column 0 derive hidden");

    selectMode(mode, []);
    playAndWait(lassoLog(viewport()));
    immutable string key = mode == "polygons" ? "selectedFaces"
                         : mode == "edges"    ? "selectedEdges" : "selectedVertices";
    return selected(key);
}

unittest { // branch 2/6 — Polygons, cage
    // REVIEWED AND UNCOVERED (see the file header, item 1): deleting the
    // `isFaceHidden` guard from this branch AND from branch 1/6 leaves this
    // assertion GREEN — measured, not assumed. Two other mechanisms already
    // reject a hidden face here. The row is still worth its runtime as a
    // whole-path smoke: it is the only place that proves hidden faces do not
    // come out of a lasso at all.
    assert(lassoStrip("polygons", false) == [1, 3, 5],
        "cage polygon lasso must select exactly the visible strip quads");
}

unittest { // branch 1/6 — Polygons, subpatch preview. Same uncovered caveat.
    assert(lassoStrip("polygons", true) == [1, 3, 5],
        "preview polygon lasso must select exactly the visible cage quads");
}

unittest { // branch 4/6 — Vertices, cage. THE R11 ROW.
    // Correct answer: columns 1..6, i.e. cage vertices 2..13. Vertices {0,1}
    // are hidden; {14,15,16} are the occluded triangle's.
    //
    // The wrong implementation and what it READS here, both measured:
    //   (a) cage-keyed `gpuVisible`, hidden guard kept  ⇒ [2..11, 15, 16]
    //   (b) the exact pre-S4 shape (no guard, cage key) ⇒ [2..11, 15, 16]
    // Twelve vertices either way — the same COUNT as the right answer, two of
    // them wrong. Reading gpuVisible[12..14] (the occluded triangle's slots)
    // rejects cage 12,13,14, and cage 15,16 fall past the end of the 15-entry
    // mask so the gate is skipped for them entirely. (a) and (b) agreeing is
    // the file header's item 1b: §3.1 already refuses to select a hidden
    // vertex, so the guard's observable job here is the slot counter.
    auto got = lassoStrip("vertices", false);
    assert(got == [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
        "cage vertex lasso must select the visible columns and translate the "
        ~ "visibility mask through the VBO slot map; got " ~ got.to!string);
}

unittest { // branch 6/6 — Edges, cage. The edge twin of the R11 row.
    // Hidden edges {0,2,3}; the triangle's edges {19,20,21} are occluded.
    // Measured with the cage key restored: [1, 4..15] — thirteen instead of
    // sixteen. Edges 16,17,18 are rejected because the cage key lands on the
    // triangle's three `false` slots, and 19,20,21 escape the range guard only
    // to fail the strict endpoint probe.
    auto got = lassoStrip("edges", false);
    assert(got == [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18],
        "cage edge lasso must select the visible strip edges and translate the "
        ~ "visibility mask through the VBO segment map; got " ~ got.to!string);
}

unittest { // branch 3/6 — Vertices, subpatch preview
    // Same cage answer through a completely different branch: the preview
    // walks `pv.vertices` and translates through the trace, and its own slot
    // counter has to skip hidden PREVIEW vertices in the same order `upload`
    // did, or every lookup past the first hidden one shifts. Measured with
    // that guard deleted: [2..11, 15, 16] — the shifted set again.
    auto got = lassoStrip("vertices", true);
    assert(got == [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
        "preview vertex lasso must agree with the cage branch; got " ~ got.to!string);
}

unittest { // branch 5/6 — Edges, subpatch preview
    // NOT the same answer as the cage branch, and that is correct rather than
    // suspicious: the preview branch requires BOTH endpoints of every kept
    // preview SEGMENT to survive the edge ID-FBO probe, and the limit surface
    // pulls the boundary segments away from the cage edge, so the strict test
    // rejects more. What matters for this stage is that nothing hidden
    // ({0,2,3}) and nothing occluded ({19,20,21}) is in the set. Measured with
    // the preview branch's hidden guard deleted (which drifts its slot
    // counter): [1, 4, 5, 6, 8, 10, 11, 16, 17, 18] — ten instead of twelve.
    auto got = lassoStrip("edges", true);
    assert(got == [1, 4, 5, 6, 8, 10, 11, 12, 14, 16, 17, 18],
        "preview edge lasso set changed: " ~ got.to!string);
    foreach (e; [0, 2, 3, 19, 20, 21])
        foreach (g; got)
            assert(g != e, "preview edge lasso selected hidden/occluded edge "
                           ~ e.to!string);
}

// ---------------------------------------------------------------------------
// Section D — the affordance (R9)
// ---------------------------------------------------------------------------
//
// The isolate trap is not a bug to guard against — isolate only ever SETS
// hide bits (measured in S2), so isolating onto an already-hidden target
// genuinely empties the viewport, and that is the reference's behaviour. The
// readout IS the mitigation, so it has to actually work in exactly that state.
//
// THE CHAIN, and which links are proved where:
//   1. the trap state is reachable, and the viewport really is empty   → HERE
//   2. in that state the three hidden COUNTS are non-zero              → HERE
//   3. non-zero counts ⇒ the readouts return a non-empty line with the right
//      numbers in the right order, and the two spellings agree on WHEN to
//      draw                                   → `source/ui/panels.d` unittest
//   3b. those counts are three separate per-plane popcounts, not one number
//      read three times                       → `source/mesh.d` unittest, on
//      a cube with one corner's three faces hidden (3 faces / 1 vertex /
//      3 edges — three different numbers)
//   4. the line actually reaches the screen   → NOT AUTOMATED, and it cannot
//      be from here: no endpoint in this codebase reads ImGui label text
//      (`/api/viewport/probe` reads a viewport CELL's FBO; the panels draw to
//      the default framebuffer). Checked by running `./vibe3d --test
//      --visible` on an Xvfb display, driving this exact sequence, and
//      photographing the window: the side panel reads "8/12/6 hidden" under
//      its V/E/F rows and the status bar reads "Hidden: 8 vert, 12 edge,
//      6 poly", with both absent on the same build before the hide. Recorded
//      here rather than dressed up in an assertion that would read the same
//      number with the draw call deleted.

unittest { // the trap state: everything hidden, buffers empty, counts non-zero
    resetApp();
    hidePolygons([0]);
    selectMode("polygons", [0]);            // refused — the face is hidden
    cmdId("mesh.hideUnselected");           // ⇒ isolates onto nothing

    // 1. The viewport is genuinely blank: not one face, edge or vertex left in
    //    any buffer. This is what makes the readout load-bearing — there is
    //    nothing else on screen to explain where the mesh went.
    auto g = getJson("/api/gpu/face-vbo");
    assert(cast(int)g["faceVertCount"].integer == 0, "face VBO must be empty");
    assert(cast(int)g["edgeVertCount"].integer == 0, "edge VBO must be empty");
    assert(cast(int)g["vertCount"].integer     == 0, "vertex VBO must be empty");

    // 2. And every plane reports a non-zero count, which is the readout's
    //    precondition. The three numbers are DIFFERENT (8 / 12 / 6), so this
    //    also pins that the panel is fed three separate popcounts rather than
    //    the face count three times.
    assert(countHidden("vertexHidden") == 8, "8 hidden vertices");
    assert(countHidden("edgeHidden")   == 12, "12 hidden edges");
    assert(countHidden("faceHidden")   == 6, "6 hidden faces");

    // 3. The way back out exists and is unconditional.
    cmdId("mesh.unhideAll");
    assert(countHidden("faceHidden") == 0, "unhideAll must restore everything");
    g = getJson("/api/gpu/face-vbo");
    assert(cast(int)g["faceVertCount"].integer == 36,
        "the cube must be back in the face VBO");
}
