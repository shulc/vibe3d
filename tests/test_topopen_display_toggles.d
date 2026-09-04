// Topology Pen — the two DISPLAY toggles hide the hover marker and NOTHING
// else (task 0499).
//
// `showVertex` / `showEdge` are the reference tool's own two display
// attributes, both measured default ON. They are the only attributes of that
// set whose behavior is measured to be "drawing only", which is why they can be
// ported when the numeric ones cannot — and "drawing only" is a claim this test
// checks in both directions:
//
//   * turning a toggle OFF must stop the indicator painting that element
//     (`hoverIndicator.shownElem` -> "none"), and
//   * it must NOT change what the press grabs (`grabElem` unchanged, and the
//     press really does still grab it).
//
// The FACE hatch is deliberately ungated: the reference has two toggles, not
// three, so neither flag may hide it. That is asserted here too — a future
// "tidy-up" that folds the face case under one of the flags is a guessed knob,
// and this is where it fails.
//
// Rig, camera and pixel derivation are the grab-target test's, unchanged
// (background sphere + one primary quad, every pixel derived from the quad's
// own projected corners with the snap-radius clearance asserted), so a camera
// change cannot silently turn one case into another.
//
// Run via: ./run_test.d topopen_display_toggles

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : sqrt;
import std.format : format;

void main() {}

enum float R         = 2.0f;
enum int   LON       = 96, LAT = 72;
enum float kSnapPx   = 8.0f;    // the tool's own PRESS-PICK reach
                                // (`topoPenPressPickPx`, task 0496)
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

JSONValue hoverAt(CameraState c, int px, int py) {
    auto pr = postJson("/api/play-events", hoverLog(c.vpX, c.vpY, c.width, c.height, px, py));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    return getJson("/api/tool/state")["hoverIndicator"];
}

/// Press without releasing, so the armed grab can be read back.
JSONValue pressAt(CameraState c, int px, int py) {
    auto pr = postJson("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
      ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n");
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    return getJson("/api/tool/state");
}

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
    // Sticky attrs: leave the shared app clean whatever happens below.
    scope(exit) {
        cmd("tool.attr mesh.topoPen showVertex true");
        cmd("tool.attr mesh.topoPen showEdge true");
    }

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

    // The three pixels, each with its precondition asserted (same derivation as
    // the grab-target test).
    immutable int vX = cast(int)qx[0], vY = cast(int)qy[0];

    immutable int eX = cast(int)((qx[0] + qx[1]) * 0.5f);
    immutable int eY = cast(int)((qy[0] + qy[1]) * 0.5f);
    foreach (i; 0 .. 4) {
        float d = sqrt((qx[i] - eX) * (qx[i] - eX) + (qy[i] - eY) * (qy[i] - eY));
        assert(d > kSnapPx,
            format("setup: the edge-midpoint pixel must clear corner %d by more than %.0fpx; "
                 ~ "got %.1fpx", i, kSnapPx, d));
    }

    immutable int fX = cast(int)qcx, fY = cast(int)qcy;
    foreach (i; 0 .. 4) {
        immutable size_t j = (i + 1) % 4;
        float d = distToSeg(fX, fY, qx[i], qy[i], qx[j], qy[j]);
        assert(d > kSnapPx,
            format("setup: the face-centre pixel must clear quad edge %d-%d by more than %.0fpx; "
                 ~ "got %.1fpx", i, j, kSnapPx, d));
    }

    // --- 1) DEFAULTS: both toggles ON, and the drawn element is the grabbed
    // one for all three cases. This is the byte-identity baseline — publishing
    // the two rows must not change what an untouched panel draws.
    {
        auto hv = hoverAt(c, vX, vY);
        assert(hv["showVertex"].type == JSONType.true_, "showVertex must default ON");
        assert(hv["showEdge"].type   == JSONType.true_, "showEdge must default ON");
        assert(hv["grabElem"].str == "vertex" && hv["shownElem"].str == "vertex",
            "with the toggles ON the indicator draws exactly the grabbed element; got "
          ~ hv["grabElem"].str ~ "/" ~ hv["shownElem"].str);

        auto he = hoverAt(c, eX, eY);
        assert(he["grabElem"].str == "edge" && he["shownElem"].str == "edge",
            "edge case, toggles ON; got " ~ he["grabElem"].str ~ "/" ~ he["shownElem"].str);

        auto hf = hoverAt(c, fX, fY);
        assert(hf["grabElem"].str == "face" && hf["shownElem"].str == "face",
            "face case, toggles ON; got " ~ hf["grabElem"].str ~ "/" ~ hf["shownElem"].str);
    }

    // --- 2) showVertex OFF: the vertex marker stops being drawn, the vertex
    // is still what a press grabs, and the OTHER two cases are untouched.
    {
        cmd("tool.attr mesh.topoPen showVertex false");

        auto hv = hoverAt(c, vX, vY);
        assert(hv["showVertex"].type == JSONType.false_, "the write must take");
        assert(hv["grabElem"].str == "vertex",
            "the resolved grab target must be unchanged by a DISPLAY toggle; got "
          ~ hv["grabElem"].str);
        assert(hv["shownElem"].str == "none",
            "showVertex off must stop the vertex marker being drawn; got " ~ hv["shownElem"].str);

        // …and the press really does still grab that vertex.
        auto st = pressAt(c, vX, vY);
        assert(st["moveElem"].str == "vertex",
            "a hidden marker must not disable the grab; got " ~ st["moveElem"].str);
        assert(st["grabbedVert"].integer == 0, "and it is still corner 0");
        releaseAt(c, vX, vY);

        auto he = hoverAt(c, eX, eY);
        assert(he["shownElem"].str == "edge",
            "showVertex must not gate the EDGE line; got " ~ he["shownElem"].str);
        auto hf = hoverAt(c, fX, fY);
        assert(hf["shownElem"].str == "face",
            "showVertex must not gate the FACE hatch; got " ~ hf["shownElem"].str);
    }

    // --- 3) showEdge OFF (and showVertex back ON): the mirror case.
    {
        cmd("tool.attr mesh.topoPen showVertex true");
        cmd("tool.attr mesh.topoPen showEdge false");

        auto he = hoverAt(c, eX, eY);
        assert(he["showEdge"].type == JSONType.false_, "the write must take");
        assert(he["grabElem"].str == "edge",
            "the resolved grab target must be unchanged; got " ~ he["grabElem"].str);
        assert(he["shownElem"].str == "none",
            "showEdge off must stop the edge line being drawn; got " ~ he["shownElem"].str);

        auto st = pressAt(c, eX, eY);
        assert(st["moveElem"].str == "edge",
            "a hidden edge line must not disable the grab; got " ~ st["moveElem"].str);
        releaseAt(c, eX, eY);

        auto hv = hoverAt(c, vX, vY);
        assert(hv["shownElem"].str == "vertex",
            "showEdge must not gate the VERTEX marker; got " ~ hv["shownElem"].str);
    }

    // --- 4) BOTH off: the face hatch still draws. The reference has two
    // display toggles, not three — inventing a polygon toggle is the failure
    // this pins.
    {
        cmd("tool.attr mesh.topoPen showVertex false");
        cmd("tool.attr mesh.topoPen showEdge false");

        auto hf = hoverAt(c, fX, fY);
        assert(hf["grabElem"].str == "face" && hf["shownElem"].str == "face",
            "the face hatch is ungated by both toggles; got "
          ~ hf["grabElem"].str ~ "/" ~ hf["shownElem"].str);

        auto hv = hoverAt(c, vX, vY);
        assert(hv["shownElem"].str == "none", "both off: no vertex marker");
        auto he = hoverAt(c, eX, eY);
        assert(he["shownElem"].str == "none", "both off: no edge line");
    }
}
