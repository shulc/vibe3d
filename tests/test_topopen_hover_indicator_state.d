// Topology Pen — Generic Hover-Highlight (Tier-C: /api/tool/state
// introspection, doc/topopen_hover_highlight_plan.md Phase 5 point 2).
//
// A lone quad primary (every one of its 4 edges is, by construction, a
// genuine BOUNDARY edge — a single face means every edge has exactly one
// incident face) with NO background layer at all: a motion event over one
// of its boundary edges must resolve `hoverIndicator.overMesh==true`,
// `nearestVert>=0`, `nearestEdge>=0`, `isBoundary==true` — and a second
// motion event over empty space (far outside the quad's screen footprint)
// must clear `overMesh` back to false. This also smoke-tests `draw()`
// itself: the running `--test` app renders the hover block every frame, so
// a null-deref there would crash the whole harness, not just this test.
//
// Run via: ./run_test.d topopen_hover_indicator_state

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

string quadMeshBody() {
    return `{
        "vertices":[[-1,-1,0],[1,-1,0],[1,1,0],[-1,1,0]],
        "faces":[[0,1,2,3]]
    }`;
}

/// A single stationary MOUSEMOTION event, NO button held ("state":0) — pure
/// hover, never arming a gesture (a held-button motion would arm Move/Place
/// and — correctly, per `anyGestureArmed()` — suppress the generic
/// indicator).
string hoverMotionLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n"
        ~ format(`{"t":10.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                 px, py) ~ "\n";
}

unittest {
    postJson("/api/reset", "");
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", quadMeshBody()));
    assert(lr["status"].str == "ok", "load-mesh (quad) failed: " ~ lr.toString);
    // No `layer.add` — the loaded quad STAYS primary (layer 0), unlike the
    // sphere-bg fixtures elsewhere in this suite (which deliberately demote
    // the loaded mesh to background). This feature is scoped to the
    // PRIMARY mesh, so the quad itself must remain primary.
    assert(vertexCountLayer(0) == 4 && edgeCountLayer(0) == 4 && faceCountLayer(0) == 1,
        "setup: pre-state must be the untouched lone quad (every edge a boundary edge)");

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.0, 0.0, 4.0, 0.0, 0.0, 0.0));
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    cmd("tool.set mesh.topoPen on");

    // Baseline: no motion yet this session -> the indicator starts clear.
    auto s0 = getJson("/api/tool/state");
    auto hi0 = s0["hoverIndicator"];
    assert(hi0["overMesh"].type == JSONType.false_, "must start with no hover indicator");

    // --- 1) Motion over the midpoint of edge 0-1 (a genuine boundary edge)
    // must light up the indicator -------------------------------------------
    float ex, ey;
    assert(projectToWindow(Vec3(0.0f, -1.0f, 0.0f), vp, ex, ey),
        "edge 0-1's midpoint must project on-screen at this framing");

    postJson("/api/play-events",
        hoverMotionLog(c.vpX, c.vpY, c.width, c.height, cast(int)ex, cast(int)ey));
    waitPlayerIdle();

    // Independently compute the expected boundary edge index from
    // /api/model — never compared against the tool's own prior output.
    auto edges = readEdgesLayer(0);
    int expectEdge = -1;
    foreach (i, e; edges)
        if ((e[0] == 0 && e[1] == 1) || (e[0] == 1 && e[1] == 0)) { expectEdge = cast(int)i; break; }
    assert(expectEdge >= 0, "setup: edge 0-1 must exist in the loaded quad");

    auto s1 = getJson("/api/tool/state");
    auto hi1 = s1["hoverIndicator"];
    assert(hi1["overMesh"].type == JSONType.true_,
        "hovering a boundary edge of the lone-quad primary must gate 'over the mesh'");
    assert(cast(int)hi1["nearestVert"].integer >= 0,
        "the nearest vertex must resolve to a real index");
    assert(cast(int)hi1["nearestEdge"].integer == expectEdge,
        format("the nearest edge must resolve to edge 0-1 (index %d); got %s",
               expectEdge, hi1["nearestEdge"].toString));
    assert(hi1["isBoundary"].type == JSONType.true_,
        "edge 0-1 (the lone quad's only incident face) must be classified as a boundary edge");
    assert(cast(int)hi1["boundaryFace"].integer == 0,
        "the lone quad's single face (index 0) must be the reported hatch face");

    // --- 2) Motion far OFF the mesh (viewport corner, well outside the
    // quad's screen footprint) must clear the indicator ---------------------
    int offX = c.vpX + 5, offY = c.vpY + 5;
    postJson("/api/play-events",
        hoverMotionLog(c.vpX, c.vpY, c.width, c.height, offX, offY));
    waitPlayerIdle();

    auto s2 = getJson("/api/tool/state");
    auto hi2 = s2["hoverIndicator"];
    assert(hi2["overMesh"].type == JSONType.false_,
        "a cursor far from all primary geometry must clear the over-mesh gate");
}
