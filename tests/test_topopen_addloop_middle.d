// Topology Pen — Add Loop "at the Middle" option, end-to-end over HTTP
// (doc/tasks/work/0480-topopen-addloop-middle.md).
//
// The option lives on ADD LOOP (Shift+MMB), not on Split. Its law is
//
//     frac = middle ? 0.5 : clamp(cursorRatio, 0, 1)
//
// applied as ONE UNIFORM SCALAR to every crossed edge — the reference was
// measured cutting every crossed edge of a single gesture at the same
// fraction (spread exactly 0), never re-deriving a fraction per edge.
//
// This test drives the REAL gesture (recorded Shift+MMB drag through
// /api/play-events) twice against the default cube, with `middle` off then
// on, over the SAME pixels:
//
//   * middle OFF -> the four belt cuts land at the release cursor's own
//     off-center ratio, all four at the same x (uniform), NOT at x=0;
//   * middle ON  -> the four belt cuts land at exactly x=0 (the midpoint of
//     every crossed belt edge), the release cursor ignored entirely.
//
// The uniform-scalar half is asserted as a SPREAD over the four new
// vertices' x, which is the direct form of the measured claim and is immune
// to the ring's global orientation sign-flip.
//
// Run via: ./run_test.d topopen_addloop_middle

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.algorithm : max, min;
import std.math   : abs;
import std.format : format;

void main() {}

enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's own modifier

// The four x coordinates of the vertices the belt cut ADDED (the cube's own
// 8 corners all sit at |x| = 0.5, so the new belt verts are exactly those
// with |x| < 0.5 - margin). Returned sorted-agnostic; the caller reads the
// spread and the magnitude.
double[] beltCutXs(int layer) {
    double[] xs;
    foreach (v; readVerticesLayer(layer))
        if (abs(v[0]) < 0.45) xs ~= v[0];
    return xs;
}

unittest {
    postJson("/api/command", commandBody("scene.reset"));   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Seed edge 0-1: v0=(-0.5,-0.5,-0.5), v1=(0.5,-0.5,-0.5). Press near the
    // v0 end, release well off-center toward v1 — the same rig shape as
    // test_topopen_addloop_drag.d, so the two tests' "follows the cursor"
    // claims are directly comparable.
    enum float rPress   = 0.1f;
    enum float rRelease = 0.8f;

    float pxF, pyF, rxF, ryF;
    assert(projectToWindow(Vec3(-0.5f + rPress,   -0.5f, -0.5f), vp, pxF, pyF),
        "the press-end point must project on-screen");
    assert(projectToWindow(Vec3(-0.5f + rRelease, -0.5f, -0.5f), vp, rxF, ryF),
        "the release point must project on-screen");
    int px = cast(int)pxF, py = cast(int)pyF;
    int rx = cast(int)rxF, ry = cast(int)ryF;

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "setup: pre-state must be the untouched cube");

    cmd("tool.set mesh.topoPen on");

    // -----------------------------------------------------------------
    // (1) middle OFF (the default) — the cut follows the release cursor,
    //     uniformly on every crossed edge.
    // -----------------------------------------------------------------
    cmd("tool.attr mesh.topoPen middle false");

    auto pr1 = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, px, py, rx, ry, 16, LSHIFT, 2));
    assert("error" !in pr1, "/api/play-events failed: " ~ pr1.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 12 && edgeCountLayer(0) == 20 && faceCountLayer(0) == 10,
        format("middle=false must still be a clean closed-ring belt cut; got %d/%d/%d",
               vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));

    auto xsOff = beltCutXs(0);
    assert(xsOff.length == 4,
        format("expected exactly 4 new belt vertices; got %d", xsOff.length));

    double loOff = xsOff[0], hiOff = xsOff[0];
    foreach (x; xsOff) { loOff = min(loOff, x); hiOff = max(hiOff, x); }
    assert(hiOff - loOff < 1e-4,
        format("middle=false: ONE uniform scalar must cut every crossed edge at the same "
             ~ "fraction — x spread was %.6f (expected ~0)", hiOff - loOff));
    // rRelease=0.8 along a 1.0-wide edge => |x| = 0.3 (or its sign-flip).
    assert(abs(abs(loOff) - 0.3) < 3e-2,
        format("middle=false: the shared fraction must be the release cursor's own ~0.8 "
             ~ "(|x| ~= 0.3); got |x| = %.6f", abs(loOff)));
    assert(abs(loOff) > 0.05,
        "middle=false: an off-center release must NOT land on the midpoint");

    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "undo must restore the exact pre-cut cube before the second half");

    // -----------------------------------------------------------------
    // (2) middle ON — the SAME pixels, but the cursor is ignored and every
    //     crossed edge is cut at exactly 0.5.
    // -----------------------------------------------------------------
    cmd("tool.attr mesh.topoPen middle true");

    auto pr2 = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, px, py, rx, ry, 16, LSHIFT, 2));
    assert("error" !in pr2, "/api/play-events failed: " ~ pr2.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 12 && edgeCountLayer(0) == 20 && faceCountLayer(0) == 10,
        format("middle=true must still be a clean closed-ring belt cut; got %d/%d/%d",
               vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));

    auto xsOn = beltCutXs(0);
    assert(xsOn.length == 4,
        format("expected exactly 4 new belt vertices; got %d", xsOn.length));

    double loOn = xsOn[0], hiOn = xsOn[0];
    foreach (x; xsOn) { loOn = min(loOn, x); hiOn = max(hiOn, x); }
    assert(hiOn - loOn < 1e-4,
        format("middle=true: the forced 0.5 must be the SAME scalar on every crossed edge — "
             ~ "x spread was %.6f (expected ~0)", hiOn - loOn));
    // The forced fraction is exact — it never passes through the pixel/ray
    // round-trip that loosens the middle=false tolerance above.
    assert(abs(loOn) < 1e-5,
        format("middle=true: every crossed belt edge must be cut at its EXACT midpoint "
             ~ "(x = 0), ignoring the release's own ~0.8 fraction; got x = %.6f", loOn));

    // The four exact belt midpoints, from the cube's OWN hand-known coords.
    assert(hasVertexNear(0, Vec3(0.0f, -0.5f, -0.5f), 1e-5), "midpoint of edge 0-1 must exist");
    assert(hasVertexNear(0, Vec3(0.0f,  0.5f, -0.5f), 1e-5), "midpoint of edge 2-3 must exist");
    assert(hasVertexNear(0, Vec3(0.0f,  0.5f,  0.5f), 1e-5), "midpoint of edge 6-7 must exist");
    assert(hasVertexNear(0, Vec3(0.0f, -0.5f,  0.5f), 1e-5), "midpoint of edge 4-5 must exist");

    // One atomic undo entry, exactly like the option-off path.
    auto u2 = postJson("/api/command", commandBody("history.undo"));
    assert(u2["status"].str == "ok", "undo must succeed: " ~ u2.toString);
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "middle=true's cut must be one atomic undo step");

    // Leave the sticky option off for whichever test shares this worker.
    cmd("tool.attr mesh.topoPen middle false");
}
