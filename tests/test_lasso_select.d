// Tests for lasso (right-mouse drag) selection.
//
// Lasso flow in app.d:
//   • RIGHT mouse down → rmbPath = [(x,y)], rmbDragging = true
//   • MOUSEMOTION while dragging → rmbPath ~= (x,y)
//   • RIGHT mouse up → if rmbPath.length >= 3, select all visible elements
//     whose screen-projected position lies inside the polygon
//
// Event logs are calibrated to the recorded VIEWPORT (150,28 650x544) and
// auto-rescaled by EventPlayer if the live layout differs (see eventlog.d).
//
// Occluded-endpoint tests (see lasso_edge_*_endpoint.log / lasso_edge_both_visible.log):
//   These use a custom injected scene with a quad occluder at z=0 and a
//   triangle behind it at z=-1. The camera is set via /api/camera so that
//   the scene + lasso coordinates are deterministic in a fixed 800×600 viewport
//   (VIEWPORT line in those logs matches: vpX=0,vpY=0,vpW=800,vpH=600).
//   The strict both-endpoints rule: lasso selects an edge only if BOTH
//   projected endpoints are inside the lasso polygon AND BOTH endpoint windows
//   contain a surviving pixel in the Edge ID-FBO (depth-pre-pass baked).

import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;
import std.algorithm : canFind;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue getJson(string p) {
    return parseJSON(cast(string)get(BASE ~ p));
}
JSONValue postJson(string p, string b) {
    return parseJSON(cast(string)post(BASE ~ p, b));
}

void resetCube() {
    post(BASE ~ "/api/reset", "");
}

void waitForPlaybackFinish() {
    import core.thread : Thread;
    import core.time : msecs;
    for (int i = 0; i < 100; ++i) {
        auto j = parseJSON(cast(string)get(BASE ~ "/api/play-events/status"));
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(100.msecs);
    }
}

// Play an event log file and wait for it to finish (with post-playback settle).
void playAndWait(string logPath) {
    import core.thread : Thread;
    import core.time : msecs;
    auto events = cast(const(void)[])read(logPath);
    auto resp = post(BASE ~ "/api/play-events", events);
    assert(parseJSON(resp)["status"].str == "success",
        "play-events failed: " ~ cast(string)resp);
    waitForPlaybackFinish();
    Thread.sleep(150.msecs);  // post-playback drain settle
}

// Load the occluder+triangle scene and fix the camera to 800×600 looking
// straight down −Z from distance 5 (az=0, el=0). Returns the edge index
// of the edge connecting vertex 4 and vertex 5, resolved dynamically from
// /api/model (the load-mesh endpoint rebuilds deduped edges from faces, so
// we never hardcode the index).
//
// Scene geometry:
//   Vertices 0-3: occluder quad at z=0, corners (±1.2, ±1.2, 0).
//   Vertex 4: (1.8, 0, -1)   — triangle vert visible, pokes past occluder.
//   Vertex 5: (0,   0, -1)   — triangle vert occluded (dead-center behind quad).
//   Vertex 6: (1.8, -0.1, -1)— triangle vert visible, pokes past occluder.
//   Faces: [0,1,2,3] and [4,5,6].
//   Edge (4,5): ONE endpoint visible, ONE occluded — the bug target.
//   Edge (4,6): BOTH endpoints visible — positive control.
int setupOccluderScene() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);

    r = postJson("/api/load-mesh",
        `{"vertices":[` ~
            `[-1.2,-1.2,0],[1.2,-1.2,0],[1.2,1.2,0],[-1.2,1.2,0],` ~
            `[1.8,0,-1],[0,0,-1],[1.8,-0.1,-1]` ~
        `],"faces":[[0,1,2,3],[4,5,6]]}`);
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);

    r = postJson("/api/camera",
        `{"azimuth":0,"elevation":0,"distance":5,` ~
        `"focus":{"x":0,"y":0,"z":0},"width":800,"height":600}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    // Resolve the edge index for vertex pair (4,5) dynamically.
    auto m = getJson("/api/model");
    auto edges = m["edges"].array;
    foreach (int i, e; edges) {
        auto ep = e.array;
        int ea = cast(int)ep[0].integer;
        int eb = cast(int)ep[1].integer;
        if ((ea == 4 && eb == 5) || (ea == 5 && eb == 4))
            return i;
    }
    assert(false, "edge (4,5) not found in /api/model — check load-mesh response");
}

unittest { // lasso a tight triangle around v6 → only v6 selected
    resetCube();
    playAndWait("tests/events/lasso_vertex_v6.log");

    auto sel = getJson("/api/selection");
    assert(sel["mode"].str == "vertices",
        "expected vertices mode, got " ~ sel["mode"].str);

    auto verts = sel["selectedVertices"].array;
    assert(verts.length == 1,
        "expected 1 lasso-selected vert, got " ~ verts.length.to!string);
    assert(verts[0].integer == 6,
        "expected v6 inside lasso triangle, got " ~ verts[0].integer.to!string);
}

unittest { // lasso a wide rect over the whole front face in polygon mode
    resetCube();
    // Log starts with key '3' to switch to Polygons mode, then drags a wide
    // right-mouse rectangle around face 1's four verts (v4, v5, v6, v7).
    playAndWait("tests/events/lasso_polygon_front.log");

    auto sel = getJson("/api/selection");
    assert(sel["mode"].str == "polygons",
        "expected polygons mode, got " ~ sel["mode"].str);

    auto faces = sel["selectedFaces"].array;
    assert(faces.length == 1,
        "expected 1 lasso-selected face, got " ~ faces.length.to!string);
    assert(faces[0].integer == 1,
        "expected face 1 (front) inside lasso, got " ~ faces[0].integer.to!string);
}

// ---------------------------------------------------------------------------
// Occluded-endpoint edge lasso tests (STRICT both-endpoints rule)
//
// Scene: occluder quad at z=0 (verts 0-3), behind triangle at z=-1 (verts 4-6).
// Camera: az=0, el=0, dist=5, viewport 800×600, looking straight down −Z.
// Edge (4,5): v4=(1.8,0,-1) is visible (x>1.2 past occluder),
//             v5=(0,0,-1) is occluded (dead-center behind quad).
// Edge (4,6): v4=(1.8,0,-1) and v6=(1.8,-0.1,-1) — BOTH visible.
//
// Projected pixel positions (800×600 fovY=π/4):
//   v4 → (~617, 300),  v5 → (~400, 300),  v6 → (~617, 312)
// ---------------------------------------------------------------------------

unittest { // Case A (RED before fix, GREEN after): edge with one occluded endpoint
           // must NOT be selected by lasso even though both endpoints project inside
    int edge45 = setupOccluderScene();

    // Log: Edges mode (key '2'), lasso box (390,286)→(627,314) enclosing BOTH
    // v4(617,300) and v5(400,300). Without the fix this edge IS selected.
    // With the STRICT fix, v5's endpoint window has no surviving edge pixel →
    // the edge is rejected.
    playAndWait("tests/events/lasso_edge_occluded_endpoint.log");

    auto sel = getJson("/api/selection");
    assert(sel["mode"].str == "edges",
        "expected edges mode, got " ~ sel["mode"].str);

    auto selEdges = sel["selectedEdges"].array;
    long[] selIds;
    foreach (e; selEdges) selIds ~= e.integer;
    assert(!selIds.canFind(cast(long)edge45),
        "edge (" ~ edge45.to!string ~ ") with occluded endpoint must NOT be "
        ~ "lasso-selected; selectedEdges=" ~ selIds.to!string);
}

unittest { // Positive control: edge with BOTH endpoints visible MUST be selected
    setupOccluderScene();

    // Resolve edge (4,6): both endpoints at x=1.8 are past the occluder (x=1.2)
    // and both survive the depth pre-pass.
    auto m = getJson("/api/model");
    int edge46 = -1;
    foreach (int i, e; m["edges"].array) {
        auto ep = e.array;
        int ea = cast(int)ep[0].integer;
        int eb = cast(int)ep[1].integer;
        if ((ea == 4 && eb == 6) || (ea == 6 && eb == 4)) { edge46 = i; break; }
    }
    assert(edge46 >= 0, "edge (4,6) not found in /api/model");

    // Log: Edges mode (key '2'), lasso box (598,286)→(632,325) enclosing
    // v4(617,300) and v6(617,312). Both endpoints are visible → edge selected.
    playAndWait("tests/events/lasso_edge_both_visible.log");

    auto sel = getJson("/api/selection");
    assert(sel["mode"].str == "edges",
        "expected edges mode, got " ~ sel["mode"].str);

    auto selEdges = sel["selectedEdges"].array;
    long[] selIds;
    foreach (e; selEdges) selIds ~= e.integer;
    assert(selIds.canFind(cast(long)edge46),
        "edge (" ~ edge46.to!string ~ ") with both-visible endpoints must be "
        ~ "lasso-selected; selectedEdges=" ~ selIds.to!string);
}
