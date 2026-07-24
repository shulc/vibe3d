// Topology Pen P0/P2 (doc/topopen_p0_plan.md, doc/topopen_p2_plan.md) —
// Tier C: the packet crosses the toolpipe seam into TopologyPenTool.
//
// Recipe (P2-recomputed — TopologyPenTool.activate() composes Point mode,
// so this test's golden must be a NEAREST-FOOT value, not the camera-ray
// hit P0 originally asserted here):
//   1. Two-layer scene (background cube, primary empty-of-geometry layer
//      swap as usual) with a Y-DOMINANT (near-top-down) camera: the auto
//      work-plane resolves to world XZ (normal +Y) through the origin
//      (`pickMostFacingPlane`'s abs-dot argmax over the camera back
//      vector). `focus=(2,0,0)` has Y=0 (the plane's own axis), so the
//      work-plane-cursor SEED equals `focus` exactly (the same lookAt
//      "focus-point trick" topo_pen_surface_raycast.json's Screen-mode
//      cases use, applied to the work-plane instead of the mesh — see that
//      fixture's `point_cube_posx_face` case, same camera/focus/expected
//      values, hand-verified there).
//   2. Nearest point on the unit cube (+-0.5 half-extent) to seed (2,0,0):
//      X clamps 2->0.5, Y/Z (already 0) pass through -> (0.5,0,0), the +X
//      face (face 3, normal (1,0,0)) — DISCRIMINATES from the old
//      camera-ray golden (which would have hit the +Y top face for a
//      straight-down camera): proves the tool is really using the
//      corrected Point-mode magnet, not still reading a camera-ray hit.
//   3. Activate mesh.topoPen (`tool.set mesh.topoPen on`) — its activate()
//      enables CONS+Point itself (no manual `tool.pipe.attr constrain ...`
//      needed here, unlike the Tier-B fixture, which probes CONS directly
//      without any tool — this IS the assertion that the tool's own
//      composition works).
//   4. Play a ONE-motion-event log at the viewport centre pixel through
//      /api/play-events (handleMouseMotion's buildToolVts call passes
//      cursorValid=true for this real mouse event — REV-1).
//   5. GET /api/tool/state and assert the cached hit matches the Tier-B
//      golden for the SAME pixel/camera (proves the packet crossed the
//      publish→consume seam: CONS published it, the tool's
//      onMouseMotion() read it via vts.get!ConstrainHitPacket()).
//   6. Deactivate (`tool.set mesh.topoPen off`) and assert the mesh
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
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":2,"y":0,"z":0}}`,
        0.3, 1.4, 5.0));

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

    // Tier-B golden for the SAME pixel/camera (topo_pen_surface_raycast.json's
    // "point_cube_posx_face" — P2 nearest-foot, not camera-ray):
    // point=(0.5,0,0), normal=(1,0,0), face=3, layer=1 (Document-layer
    // index — NIT-3: the background cube lives at Document layer 1).
    auto pt = st["point"].array;
    assert(approx(pt[0].floating, 0.5) && approx(pt[1].floating, 0.0) && approx(pt[2].floating, 0.0),
        "cached hit point should match the Tier-B golden (0.5,0,0); got " ~ st.toString);
    auto nrm = st["normal"].array;
    assert(approx(nrm[0].floating, 1.0) && approx(nrm[1].floating, 0.0) && approx(nrm[2].floating, 0.0),
        "cached hit normal should match the Tier-B golden (1,0,0); got " ~ st.toString);
    assert(st["face"].integer == 3,
        "cached hit face should match the Tier-B golden (3); got " ~ st.toString);
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
