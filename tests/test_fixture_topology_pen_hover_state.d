// Topology Pen P1 (doc/topopen_p1_plan.md) — Tier C: the resolved hover
// target crosses the toolpipe seam into TopologyPenTool.
//
// Recipe:
//   1. Reproduce the SAME scene + camera as
//      tests/fixtures/topo_pen_hover_target.json's "vertex_snap_corner"
//      case (a background cube, camera focus'd just short of the top-face
//      corner (0.5,0.5,0.5) -- see that fixture's provenance notes for the
//      "focus-point trick" and the independently-derived pixel distance).
//   2. Activate mesh.topoPen (`tool.set mesh.topoPen on`) — its activate()
//      enables CONS+Point itself, mirroring test_fixture_topology_pen_tool.d
//      (P0's Tier-C test).
//   3. Play a ONE-motion-event log at the viewport centre pixel through
//      /api/play-events (handleMouseMotion's buildToolVts call passes
//      cursorValid=true for this real mouse event).
//   4. GET /api/tool/state and assert the cached `hover.targetKind` /
//      `hover.targetVert` match the Tier-B golden for the SAME pixel/
//      camera (proves TopologyPenTool's `resolveHoverTarget` call — reading
//      the packet's viewport from the SAME vts CONS published into —
//      agrees with /api/surface-raycast's own `resolveHoverTarget` call,
//      i.e. both sides of the CONS→ACTR seam share one pure function).
//   5. Deactivate (`tool.set mesh.topoPen off`) and assert the mesh
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

// Resolve a world-space vertex coordinate to its index within `layer`'s
// own mesh (mirrors fixture_helpers.resolveVertexInLayer — duplicated here
// since this test does not import fixture_helpers, matching P0's Tier-C
// test's self-contained style).
int resolveVertexInLayer(int layer, double[3] coord) {
    auto m = parseJSON(cast(string) get(baseUrl ~ format("/api/model?layer=%d", layer)));
    foreach (i, v; m["vertices"].array) {
        auto c = v.array;
        double[3] got = [c[0].floating, c[1].floating, c[2].floating];
        bool same = true;
        foreach (k; 0 .. 3) if (fabs(got[k] - coord[k]) > 1e-4) same = false;
        if (same) return cast(int) i;
    }
    assert(false, format("no vertex at %s in layer %d", coord, layer));
}

unittest {
    postJson("/api/reset", "");

    // Same scene as the Tier-B "vertex_snap_corner" fixture case.
    cmd("layer.add name:Bg");
    auto lr = postJson("/api/load-mesh", cubeMeshBody());
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");   // layer0 primary (foreground), layer1 background

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.4, 0.6, 4.0, 0.46, 0.5, 0.46));

    int wantVertIdx = resolveVertexInLayer(1, [0.5, 0.5, 0.5]);

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
    assert(hover["targetKind"].str == "vertex",
        "hover.targetKind should match the Tier-B golden (vertex); got " ~ st.toString);
    assert(hover["targetVert"].integer == wantVertIdx,
        format("hover.targetVert should match the Tier-B golden (idx %d); got %s",
               wantVertIdx, st.toString));

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
