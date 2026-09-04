// THE HOVERED EDGE IS DRAWN, AND THAT IS ASSERTED IN PIXELS.
//
// Written for task 0781 step 1b's finding, not for a bug. The hover triple
// (`hoveredVertex`/`hoveredEdge`/`hoveredFace`) reaches the renderer by TWO
// independent channels, and only one of them had a value oracle:
//
//   * `hover_state.g_hovered*` -- the __gshared PUBLISH channel, read by
//     `/api/toolpipe/eval["hover"]`. Every hover test in the suite asserts
//     THIS one, by value.
//   * `EditorApp.hoveredVertexPtr`/`hoveredEdgePtr`/`hoveredFacePtr` -- the
//     pointers `ui/viewport_render.d` reads BARE under `with (app)` to draw
//     the highlight. Nothing goes through the HTTP API at all.
//
// A probe that pointed the three pointers at `-1` decoys left the whole
// element-hover test family green: the highlight vanished from the screen and
// no assertion moved. `test_selection_occluded_pass.d` witnesses the VERTEX
// pointer (it draws a pre-highlighted vertex at the selected point size) and
// `test_weightmap_display.d` Flow G3 witnesses the FACE pointer (face hover
// recolours the weight block) -- the EDGE pointer had nothing. This file is
// that witness.
//
// THE MEASUREMENT IS THE WHOLE-BUFFER HASH, and it has to be: an edge
// highlight is a handful of pixels on a line whose position depends on the
// camera, so a single-pixel probe would be pinning a coordinate rather than
// the highlight. `/api/viewport/probe?cell=0&hash=1` digests the entire cell
// colour buffer, so "the frame changed" is a measurement and not a tolerance
// question.
//
// THE NEGATIVE CONTROL RUNS FIRST, and it is what makes the positive one mean
// anything. Two DIFFERENT empty-space pixels must produce the SAME hash: that
// says the frame is deterministic at rest and that merely moving the replayed
// pointer paints nothing. Without it, a hash that changed every frame for any
// reason (an animation, a blinking overlay, a nondeterministic clear) would
// satisfy the positive assertion on broken code too.
//
// THE RIG IS AN OPEN MESH -- the three quads of
// `tests/test_wireframe_select_through.d`, reused deliberately. A cube's edges
// are all silhouette-or-interior of one closed solid; the open rig gives a
// near quad whose edges sit on plain background, so the highlight lands on
// pixels nothing else writes.
//
// MUTATION THAT REDDENS IT (task 0781): point `app.hoveredEdgePtr` at a
// `static int` decoy that stays -1. `hover.edge` below stays correct (it comes
// from the publish channel, which the decoy does not touch), so the positive
// control passes and the HASH assertion is the one that fires.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs, lround, sqrt;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void settle() { Thread.sleep(300.msecs); }

// The three-quad open rig from test_wireframe_select_through.d: a near quad at
// z=+1, a small far quad at z=-1, and a side quad off to +X. No closed volume
// anywhere, so an edge highlight is drawn over background, not over a face the
// same colour as its neighbour.
enum string RIG = `{"vertices":[
    [-2,-2,1],[2,-2,1],[2,2,1],[-2,2,1],
    [-0.6,-0.6,-1],[0.6,-0.6,-1],[0.6,0.6,-1],[-0.6,0.6,-1],
    [3,-1,0],[4.5,-1,0],[4.5,1,0],[3,1,0]],
 "faces":[[0,1,2,3],[4,5,6,7],[8,11,10,9]]}`;

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

int hoverEdge() { return cast(int)getJson("/api/toolpipe/eval")["hover"]["edge"].integer; }

// The whole cell-0 colour buffer, digested. `renders` and a non-zero size are
// asserted here rather than at the call sites so a probe that never saw a
// framebuffer cannot be mistaken for a frame that happens to match.
string cellHash() {
    auto r = getJson("/api/viewport/probe?cell=0&hash=1");
    assert("error" !in r,
           "probe failed: " ~ r.toString);
    assert(r["renders"].boolean, "cell 0 does not render: " ~ r.toString);
    assert(r["w"].integer > 0 && r["h"].integer > 0,
           "cell 0 has no framebuffer: " ~ r.toString);
    return r["hash"].str;
}

unittest {
    postJson("/api/reset", "");
    settle();
    auto lm = postJson("/api/load-mesh", RIG);
    assert(lm["status"].str == "ok" || lm["status"].str == "success",
           "/api/load-mesh failed: " ~ lm.toString);
    // AFTER the load: /api/load-mesh re-frames the camera.
    postJson("/api/camera", `{"azimuth":0,"elevation":0,"distance":12}`);
    settle();

    auto model = getJson("/api/model");
    assert(model["vertices"].array.length == 12,
           format("rig did not load: %d vertices", model["vertices"].array.length));

    // Edges are the selection type, so the edge hover picker is the one that
    // runs and the edge highlight is the one that draws.
    auto sel = postJson("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[]}`));
    assert(sel["status"].str == "success" || sel["status"].str == "ok",
           "/api/select edges failed: " ~ sel.toString);
    settle();

    auto cam = fetchCamera();
    assert(cam.eye.z > 1.0f && fabs(cam.eye.x) < 0.1f && fabs(cam.eye.y) < 0.1f,
           format("camera is not on +Z looking at the origin: eye=(%s,%s,%s)",
                  cam.eye.x, cam.eye.y, cam.eye.z));
    auto vp = viewportFromCamera(cam);

    // ---- negative control, FIRST: two empty pixels, one hash -------------
    // Top-left of the viewport. The rig's nearest projected corner is ~137 px
    // from the centre and the side quad ~180 px to its right, so both of these
    // are background.
    immutable int emptyAx = cam.vpX + 30, emptyAy = cam.vpY + 30;
    immutable int emptyBx = cam.vpX + 70, emptyBy = cam.vpY + 45;

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, emptyAx, emptyAy));
    settle();
    assert(hoverEdge() == -1,
           format("empty pixel A (%d,%d) must hover nothing; got edge %d",
                  emptyAx, emptyAy, hoverEdge()));
    immutable string hEmptyA = cellHash();

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, emptyBx, emptyBy));
    settle();
    assert(hoverEdge() == -1,
           format("empty pixel B (%d,%d) must hover nothing; got edge %d",
                  emptyBx, emptyBy, hoverEdge()));
    immutable string hEmptyB = cellHash();

    assert(hEmptyA == hEmptyB,
           format("negative control: moving the pointer between two EMPTY pixels " ~
                  "must not change one pixel of cell 0, so the positive cell below " ~
                  "measures the highlight and not frame noise; got %s then %s",
                  hEmptyA, hEmptyB));

    // ---- the witness: hovering a real edge repaints the cell --------------
    // Discover a pickable edge rather than pinning one: the edge INDEX is not
    // the claim here, "an edge is hovered" is.
    auto edges = model["edges"].array;
    int  chosen = -1;
    int  ex, ey;
    foreach (ei, e; edges) {
        size_t a = cast(size_t)e.array[0].integer;
        size_t b = cast(size_t)e.array[1].integer;
        auto va = model["vertices"].array[a].array;
        auto vb = model["vertices"].array[b].array;
        Vec3 mid = Vec3(cast(float)((va[0].floating + vb[0].floating) * 0.5),
                        cast(float)((va[1].floating + vb[1].floating) * 0.5),
                        cast(float)((va[2].floating + vb[2].floating) * 0.5));
        float sx, sy;
        if (!projectToWindow(mid, vp, sx, sy)) continue;
        int px = cast(int)lround(sx), py = cast(int)lround(sy);
        playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, px, py));
        settle();
        if (hoverEdge() == cast(int)ei) { chosen = cast(int)ei; ex = px; ey = py; break; }
    }
    assert(chosen >= 0,
           "positive control: no edge midpoint pixel resolved a hover at all, " ~
           "so the harness is not picking and no hash difference below would mean " ~
           "anything");

    immutable string hHover = cellHash();
    assert(hHover != hEmptyA,
           format("hovering edge %d at (%d,%d) must repaint cell 0 -- the highlight " ~
                  "reaches the renderer through EditorApp.hoveredEdgePtr, which no " ~
                  "other test reads; the cell is byte-identical to the empty-space " ~
                  "frame (%s), so nothing was drawn",
                  chosen, ex, ey, hHover));

    // Park back on empty space so the next test in this worker starts with no
    // hover latched, and re-assert the resting hash: the highlight came and
    // went, which a one-way change (a mesh upload, a camera drift) would not do.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, emptyAx, emptyAy));
    settle();
    assert(hoverEdge() == -1, "the pointer did not park back on empty space");
    assert(cellHash() == hEmptyA,
           "leaving the edge must restore the resting frame exactly; it did not, " ~
           "so the difference above was not the hover highlight");
}
