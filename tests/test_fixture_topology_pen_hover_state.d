// Topology Pen P1/P2 (doc/topopen_p1_plan.md, doc/topopen_p2_plan.md) —
// Tier C: the resolved hover target crosses the toolpipe seam into
// TopologyPenTool.
//
// Recipe (P2-recomputed — TopologyPenTool.activate() composes Point mode,
// so the golden hit here must be a NEAREST-FOOT value; reuses the SAME
// scene/camera as test_fixture_topology_pen_tool.d's P2 recompute, so both
// Tier-C tests agree on what the tool actually resolves for this
// pixel/camera):
//   1. Background cube, Y-dominant (near-top-down) camera, `focus=(2,0,0)`
//      -- work-plane-cursor seed = focus (Y=0, the plane's own axis);
//      nearest-foot on the unit cube is (0.5,0,0), the +X face (face 3,
//      normal (1,0,0)) -- see test_fixture_topology_pen_tool.d's header
//      for the full derivation.
//   2. (0.5,0,0) is the face's CENTRE -- independently, its distance (in
//      world units) to the nearest corner/edge of that face is 0.5 world
//      units in both Y and Z, which at any reasonable camera distance
//      projects to comfortably more than the default 12px snap radius, so
//      the hover resolution must be `face` (no vert/edge candidate wins).
//   3. Activate mesh.topoPen (`tool.set mesh.topoPen on`) — its activate()
//      enables CONS+Point itself, mirroring test_fixture_topology_pen_tool.d
//      (P0's Tier-C test).
//   4. Play a ONE-motion-event log at the viewport centre pixel through
//      /api/play-events (handleMouseMotion's buildToolVts call passes
//      cursorValid=true for this real mouse event).
//   5. GET /api/tool/state and assert the cached `hover.targetKind` /
//      `hover.targetVert` match the Tier-B golden for the SAME pixel/
//      camera (proves TopologyPenTool's `resolveHoverTarget` call — reading
//      the packet's viewport from the SAME vts CONS published into —
//      agrees with /api/surface-raycast's own `resolveHoverTarget` call,
//      i.e. both sides of the CONS→ACTR seam share one pure function).
//   6. Deactivate (`tool.set mesh.topoPen off`) and assert the mesh
//      (foreground layer) is byte-identical before/after — the tool never
//      mutates the mesh, hover preview included.
//
// Run via: ./run_test.d topology_pen_hover_state

import std.net.curl;
import std.json;
import std.math    : fabs;
import std.format  : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

string cubeMeshBody() {
    return `{
        "vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
                    [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],
        "faces":[[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]
    }`;
}

bool approx(double a, double b, double eps = 0.02) { return fabs(a - b) < eps; }

enum int VP_X = 150, VP_Y = 28, VP_W = 650, VP_H = 544;
enum int CX = VP_X + VP_W / 2, CY = VP_Y + VP_H / 2;   // 475, 300

void waitPlayerIdle() {
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(cast(string) get(baseUrl ~ "/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));   // post-playback settle (see CLAUDE.md flake note #3)
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}

double[3][] readVertices() {
    auto m = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    auto arr = m["vertices"].array;
    auto outv = new double[3][](arr.length);
    foreach (i, v; arr) {
        auto c = v.array;
        outv[i] = [c[0].floating, c[1].floating, c[2].floating];
    }
    return outv;
}

unittest {
    postJson("/api/reset", "");

    // Same scene/camera as test_fixture_topology_pen_tool.d's P2 recompute
    // (Y-dominant near-top-down camera, focus=(2,0,0) -> nearest-foot
    // (0.5,0,0), the +X face's centre — see that file's header comment
    // for the derivation).
    cmd("layer.add name:Bg");
    auto lr = postJson("/api/load-mesh", cubeMeshBody());
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");   // layer0 primary (foreground), layer1 background

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 1.4, 5.0, 2.0, 0.0, 0.0));

    auto vertsBefore = readVertices();

    // Activate the thin tool — its activate() enables CONS+Point itself.
    cmd("tool.set mesh.topoPen on");

    // Drive ONE motion event at the viewport centre pixel — a real
    // mouse-event dispatch, so buildToolVts stamps cursorValid=true and
    // the CONS raycast branch fires.
    string log =
        format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
               VP_X, VP_Y, VP_W, VP_H) ~ "\n"
      ~ format(`{"t":10.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
               CX, CY) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    auto st = getJson("/api/tool/state");
    assert(st["tool"].str == "mesh.topoPen", "unexpected active tool: " ~ st.toString);
    assert(st["hit"].type == JSONType.true_,
        "expected a cached hit after the motion event; got " ~ st.toString);

    assert("hover" in st, "toolStateJson must nest a hover{} object: " ~ st.toString);
    auto hover = st["hover"];
    assert(hover["hit"].type == JSONType.true_,
        "hover.hit should mirror the cached raycast hit; got " ~ st.toString);
    // (0.5,0,0) is the +X face's CENTRE — 0.5 world units from its nearest
    // corner/edge in both Y and Z, comfortably outside the default 12px
    // snap radius at this camera distance, so the hover must resolve to a
    // free face-point (no vert/edge candidate wins).
    assert(hover["targetKind"].str == "face",
        "hover.targetKind should match the P2 golden (face); got " ~ st.toString);
    assert(hover["targetVert"].integer == -1 && hover["targetEdge"].integer == -1,
        "a 'face' target must carry no vert/edge index; got " ~ st.toString);

    // Deactivate — no mesh mutation across activate/deactivate, hover
    // preview included (the tool renders from cached state, never mutates).
    cmd("tool.set mesh.topoPen off");

    auto vertsAfter = readVertices();
    assert(vertsAfter.length == vertsBefore.length,
        "activate/deactivate must not change vertex count");
    foreach (i; 0 .. vertsBefore.length) {
        foreach (c; 0 .. 3)
            assert(approx(vertsAfter[i][c], vertsBefore[i][c], 1e-6),
                format("vertex %d[%d] changed across activate/deactivate: %s -> %s",
                       i, c, vertsBefore[i], vertsAfter[i]));
    }
}
