// Task 1054 review (SHOULD-FIX 3) -- the interactive arm gate must not
// demand a ring band mode does not need.
//
// Bug: `onMouseButtonDown`'s `anyValid` gate refused to arm unless SOME
// candidate seed yielded a `collectEdgeRing`-collectable ring, regardless
// of whether band mode was about to be entered. But band mode ignores
// `seeds`/`candSeeds` entirely once entered (`insertEdgeLoopsMulti`'s
// `bandFaces` walk never consults them), and `applyHeadless` has no such
// gate at all -- so a band selection whose every neighbour is a NON-QUAD
// (every candidate seed's `collectEdgeRing` therefore returns [], per the
// "both incident faces must be quads" guard) cut fine headlessly but
// refused to arm interactively: a new interactive/headless divergence the
// activation fallback (task 1054 §3.4) introduced.
//
// Fix: skip the ring-collectability requirement whenever the arm will
// enter band mode (`sliceSelected_ && editMode == Polygons && a face
// selection exists` -- the same condition `restrictFor` uses to decide
// `bandFaces != null`).
//
// Mesh (via /api/load-mesh, test-only raw injection): one quad (face 0, the
// flat base in the XZ plane) with a lone triangle "flap" hinged on EACH of
// its four edges -- so every one of face 0's own edges has {quad, triangle}
// as its two incident faces, and every candidate seed's `collectEdgeRing`
// returns [] (the kernel's "both seed-incident faces must be quads" guard,
// loop_slice.d). Selecting only face 0 with Slice Selected ON is exactly
// the "band selection whose neighbours are non-quads" case.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;

void resetScene() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void loadMesh(string body_) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/load-mesh", body_));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

void cmd(string s) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/command", s));
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = parseJSON(cast(string) post(BASE ~ "/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`)));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}


void playAndSettle(string log) {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "play-events replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, CLAUDE.md flake note)
}

// A fixed viewport, same idiom as tests/test_loop_slice_band_interactive.d.
// Loop Slice's Polygons-mode arm is SELECTION-seeded, so the click pixel
// doesn't need to hover any particular element.
enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

void clickArm() {
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

unittest {
    resetScene();
    loadMesh(`{"vertices":[
        [-1,0,-1],[1,0,-1],[1,0,1],[-1,0,1],
        [0,1,-2],[2,1,0],[0,1,2],[-2,1,0]
    ],"faces":[
        [0,1,2,3],
        [0,1,4],
        [1,2,5],
        [2,3,6],
        [3,0,7]
    ]}`);

    postSelect("polygons", [0]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");   // Slice Selected ON, before the arm click
    clickArm();

    auto st = getJson("/api/tool/state");
    assert(("tool" in st.object) !is null, "tool must still be active after the arm attempt");
    assert(st["armed"].type == JSONType.true_,
        "band-mode arm must succeed on a selection whose neighbours are all "
        ~ "non-quads: no candidate seed can collect a ring, but band mode "
        ~ "never consults collectEdgeRing at all");
    assert(st["built"].type == JSONType.true_,
        "arm click must materialize the standing band-mode preview");

    auto after = getJson("/api/model");
    // Band mode's single-cell (both-sides-derived) cut on a quad splits it
    // via its two OPPOSITE edges: +2 vertices, the quad -> 2 sub-quads, and
    // BOTH cut edges are shared with a triangle flap, so each of those two
    // triangles absorbs the new midpoint into its own boundary (3-gon ->
    // 4-gon); the other two triangle flaps are untouched.
    assert(after["vertexCount"].integer == 10,
        "expected 10 verts (8 + 2 new), got " ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 6,
        "expected 6 faces (1 quad -> 2 sub-quads + 4 original triangles, "
        ~ "2 of which absorb a midpoint), got "
        ~ after["faceCount"].integer.to!string);
    assert(after["edgeCount"].integer == 15,
        "expected 15 edges (12 base + 1 new interior chord + 2 cut edges "
        ~ "each split in two), got " ~ after["edgeCount"].integer.to!string);
}
