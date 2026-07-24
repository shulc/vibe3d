// Topology Pen — Tier C: the packet crosses the toolpipe seam into
// TopologyPenTool.
//
// Recipe (P2 briefly recomputed this test's golden to a work-plane-cursor
// nearest-foot value; a live cross-engine differential against the reference editor
// (toolcards/topology_pen/cross_engine_differential.md) then PROVED
// that derivation wrong — Point mode's placement seed is the camera-ray
// hit, same as P0/P1 originally shipped — so this test reverts to its
// pre-P2 golden, unchanged from P0):
//   1. Reproduce the SAME two-layer scene + camera as
//      tests/fixtures/topo_pen_surface_raycast.json's "bg_cube_topface_center"
//      case (a background cube, camera focus'd exactly on the top-face
//      centre — see that fixture's provenance notes for the "focus-point
//      trick").
//   2. Activate mesh.topoPen (`tool.set mesh.topoPen on`) — its activate()
//      enables CONS+Point itself (no manual `tool.pipe.attr constrain ...`
//      needed here, unlike the Tier-B fixture, which probes CONS directly
//      without any tool — this IS the assertion that the tool's own
//      composition works).
//   3. Play a ONE-motion-event log at the viewport centre pixel through
//      /api/play-events (handleMouseMotion's buildToolVts call passes
//      cursorValid=true for this real mouse event — REV-1).
//   4. GET /api/tool/state and assert the cached hit matches the Tier-B
//      golden for the SAME pixel/camera (proves the packet crossed the
//      publish→consume seam: CONS published it, the tool's
//      onMouseMotion() read it via vts.get!ConstrainHitPacket()).
//   5. Deactivate (`tool.set mesh.topoPen off`) and assert the mesh
//      (foreground layer) is byte-identical before/after — the tool never
//      mutates the mesh.
//
// Run via: ./run_test.d topology_pen_tool

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

    // Same scene as the Tier-B "bg_cube_topface_center" fixture case.
    cmd("layer.add name:Bg");
    auto lr = postJson("/api/load-mesh", cubeMeshBody());
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");   // layer0 primary (foreground), layer1 background

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":0,"y":0.5,"z":0}}`,
        0.4, 0.6, 4.0));

    auto vertsBefore = readVertices();

    // Activate the thin tool — its activate() enables CONS+Point itself.
    cmd("tool.set mesh.topoPen on");

    // Drive ONE motion event at the viewport centre pixel — a real
    // mouse-event dispatch, so buildToolVts stamps cursorValid=true and
    // the CONS raycast branch fires (REV-1).
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

    // Tier-B golden for the SAME pixel/camera (bg_cube_topface_center):
    // point=(0,0.5,0), normal=(0,1,0), face=4, layer=1 (Document-layer
    // index — NIT-3: the background cube lives at Document layer 1).
    auto pt = st["point"].array;
    assert(approx(pt[0].floating, 0.0) && approx(pt[1].floating, 0.5) && approx(pt[2].floating, 0.0),
        "cached hit point should match the Tier-B golden (0,0.5,0); got " ~ st.toString);
    auto nrm = st["normal"].array;
    assert(approx(nrm[0].floating, 0.0) && approx(nrm[1].floating, 1.0) && approx(nrm[2].floating, 0.0),
        "cached hit normal should match the Tier-B golden (0,1,0); got " ~ st.toString);
    assert(st["face"].integer == 4,
        "cached hit face should match the Tier-B golden (4); got " ~ st.toString);
    assert(st["layer"].integer == 1,
        "cached hit layer should match the Tier-B golden (1); got " ~ st.toString);

    // Deactivate — no mesh mutation across activate/deactivate.
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
