// Topology Pen — the hover highlight names exactly what a press would grab
// (task 0484 follow-up).
//
// The indicator used to paint the nearest VERTEX and the nearest EDGE at the
// same time, plus a hatch on a boundary edge's face — three "what is near
// you" affordances. A press, meanwhile, grabs exactly ONE element, resolved by
// proximity: vertex within the snap radius, else edge within it, else the face
// under the cursor. A highlight that names a different element than the press
// takes is worse than no highlight, because the user aims by it.
//
// Both answers now come from one function (`resolveGrabTarget`), and
// `/api/tool/state`'s `hoverIndicator.grabElem` / `.grabIndex` is what makes
// that checkable from outside. This test walks a cursor to three pixels chosen
// to force each of the three outcomes, and asserts the reported target — then
// PRESSES at the same pixel and asserts the gesture grabbed that very element.
//
// The rig is the element-drag test's: a background sphere (so the tool has a
// surface to work against) plus a single quad in the primary layer. Every
// press pixel is derived from the quad's own projected corners, and every
// geometric precondition is asserted, so a camera change cannot silently turn
// one case into another.
//
// Run via: ./run_test.d topopen_hover_grab_target

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : sqrt;
import std.format : format;

void main() {}

enum float R         = 2.0f;
enum int   LON       = 96, LAT = 72;
enum float kSnapPx   = 8.0f;    // the tool's own PRESS-PICK reach
                                // (`topoPenPressPickPx`; task 0496 — the drag
                                // snap is a separate, wider query)
enum float kQuadHalf = 0.75f;

float distToSeg(float px, float py, float ax, float ay, float bx, float by) {
    float vx = bx - ax, vy = by - ay;
    float wx = px - ax, wy = py - ay;
    float len2 = vx * vx + vy * vy;
    float t = len2 > 1e-9f ? (wx * vx + wy * vy) / len2 : 0.0f;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    float dx = px - (ax + vx * t), dy = py - (ay + vy * t);
    return sqrt(dx * dx + dy * dy);
}

/// One stationary MOUSEMOTION, no button held — pure hover, arms nothing.
string hoverLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n"
         ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
                ~ `"state":0,"mod":0}`, px, py) ~ "\n";
}

/// Hover at (px,py) and return `hoverIndicator`.
JSONValue hoverAt(CameraState c, int px, int py) {
    auto pr = postJson("/api/play-events", hoverLog(c.vpX, c.vpY, c.width, c.height, px, py));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    return getJson("/api/tool/state")["hoverIndicator"];
}

/// Press at (px,py) WITHOUT releasing, and return the tool state — so the
/// armed grab can be compared against what the highlight promised.
JSONValue pressAt(CameraState c, int px, int py) {
    auto pr = postJson("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
      ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n");
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    return getJson("/api/tool/state");
}

/// Release at (px,py), leaving no armed gesture for the next case.
void releaseAt(CameraState c, int px, int py) {
    postJson("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
      ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n");
    waitPlayerIdle();
}

unittest {
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/command", commandBody("scene.loadMesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf)));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);

    // Camera LAST — `/api/load-mesh` restores the post-load camera.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");

    auto qv = readVerticesLayer(1);
    assert(qv.length == 4, "setup: the primary must be the 4-corner quad");
    float[4] qx, qy;
    float qcx = 0, qcy = 0;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)qv[i][0], cast(float)qv[i][1],
                                    cast(float)qv[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy; qcx += sx; qcy += sy;
    }
    qcx /= 4; qcy /= 4;

    // --- CASE 1: right on corner 0 -> VERTEX.
    {
        immutable int px = cast(int)qx[0], py = cast(int)qy[0];
        auto hi = hoverAt(c, px, py);
        assert(hi["overMesh"].type == JSONType.true_, "setup: the cursor must be over the mesh");
        assert(hi["grabElem"].str == "vertex",
            "a hover ON a corner must promise the VERTEX; got " ~ hi["grabElem"].str);
        assert(hi["grabIndex"].integer == 0,
            format("the promised vertex must be corner 0; got %d", hi["grabIndex"].integer));

        auto st = pressAt(c, px, py);
        assert(st["moveElem"].str == "vertex",
            "the press must grab what the highlight promised; got " ~ st["moveElem"].str);
        assert(st["moveVertCount"].integer == 1, "a vertex grab drags exactly one vertex");
        assert(st["grabbedVert"].integer == 0, "and it must be the highlighted corner");
        releaseAt(c, px, py);
    }

    // --- CASE 2: the corner-0..1 edge midpoint -> EDGE. Asserted to be
    // outside snap range of every corner, so the vertex term cannot fire.
    {
        immutable int px = cast(int)((qx[0] + qx[1]) * 0.5f);
        immutable int py = cast(int)((qy[0] + qy[1]) * 0.5f);
        foreach (i; 0 .. 4) {
            float d = sqrt((qx[i] - px) * (qx[i] - px) + (qy[i] - py) * (qy[i] - py));
            assert(d > kSnapPx,
                format("setup: the edge-midpoint pixel must clear corner %d by more than "
                     ~ "%.0fpx; got %.1fpx", i, kSnapPx, d));
        }

        auto hi = hoverAt(c, px, py);
        assert(hi["grabElem"].str == "edge",
            "a hover on an edge (clear of every corner) must promise the EDGE; got "
          ~ hi["grabElem"].str);

        auto st = pressAt(c, px, py);
        assert(st["moveElem"].str == "edge",
            "the press must grab the EDGE the highlight promised; got " ~ st["moveElem"].str);
        assert(st["moveVertCount"].integer == 2, "an edge grab drags its two endpoints");
        releaseAt(c, px, py);
    }

    // --- CASE 3: the quad's screen centroid -> FACE. Asserted clear of every
    // projected edge, so neither the vertex nor the edge term can fire. This
    // is the case the OLD indicator could not show at all: the hatch was
    // reachable only through a boundary EDGE hover.
    {
        immutable int px = cast(int)qcx, py = cast(int)qcy;
        foreach (i; 0 .. 4) {
            immutable size_t j = (i + 1) % 4;
            float d = distToSeg(px, py, qx[i], qy[i], qx[j], qy[j]);
            assert(d > kSnapPx,
                format("setup: the face-centre pixel must clear quad edge %d-%d by more than "
                     ~ "%.0fpx; got %.1fpx", i, j, kSnapPx, d));
        }

        auto hi = hoverAt(c, px, py);
        assert(hi["overMesh"].type == JSONType.true_,
            "setup: the face centre must count as over the mesh");
        assert(hi["grabElem"].str == "face",
            "a hover over a polygon's interior must promise the FACE; got " ~ hi["grabElem"].str);
        assert(hi["grabIndex"].integer == 0,
            format("the promised face must be the quad's only face; got %d",
                   hi["grabIndex"].integer));

        auto st = pressAt(c, px, py);
        assert(st["moveElem"].str == "face",
            "the press must grab the FACE the highlight promised; got " ~ st["moveElem"].str);
        assert(st["moveVertCount"].integer == 4, "a quad grab drags all four corners");
        releaseAt(c, px, py);
    }

    // --- CASE 4: off the mesh entirely -> nothing promised, nothing drawn.
    {
        immutable int px = c.vpX + 4, py = c.vpY + 4;
        auto hi = hoverAt(c, px, py);
        assert(hi["overMesh"].type == JSONType.false_,
            "setup: the corner pixel must be off the quad");
        assert(hi["grabElem"].str == "none",
            "a hover off the mesh must promise nothing; got " ~ hi["grabElem"].str);
        assert(hi["grabIndex"].integer == -1, "and must name no index");
    }
}
