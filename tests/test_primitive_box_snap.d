// Box-construction snap coverage for the announcement-QA "Snap" item.
//
// Each SnapType is verified through the LIVE BoxTool base-corner click:
// the first click in BoxState.Idle runs `snapLocalHit` against the
// toolpipe SNAP stage (`snapLocalHit` in source/tools/create/box.d), rewrites the base
// corner to the snapped target, and publishes the result to
// /api/snap/last via `publishLastSnap`. That published world-space
// SnapResult is our observable — `snapped==true` proves the box's base
// corner consumed that exact target (the same call rewrites startPoint).
//
// This is the gap the existing snap tests don't cover: test_toolpipe_snap
// only hits the /api/snap query endpoint, and test_snap_during_drag drives
// MoveTool — neither exercises snap during primitive construction.
//
// Reference geometry is the default unit cube (±0.5). Snap range is set
// effectively infinite so the nearest target of each type always fires
// regardless of camera; we assert the target TYPE and its coordinate
// pattern, both camera-independent.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time : dur;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// Reset to the default unit cube (the snap reference), park the camera,
// activate prim.cube, and arm SNAP with one type + effectively-infinite
// range so the nearest target always qualifies.
void resetBoxWithSnap(string types) {
    auto r = postJson("/api/command", commandBody("scene.reset"));          // default cube = 8 verts
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set prim.cube");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types " ~ types);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
}

// Replay a single base-corner click (no motion) at the window pixel under
// the world origin, then return the box tool's published snap result.
JSONValue clickBaseCornerAtOrigin() {
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float px, py;
    assert(projectToWindow(Vec3(0, 0, 0), vp, px, py), "origin projects behind camera");
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        cam.vpX, cam.vpY, cam.width, cam.height, cast(int)px, cast(int)py);
    playAndWait(log, BASE);
    Thread.sleep(dur!"msecs"(150));   // post-playback drain settle (see CLAUDE.md)
    return getJson("/api/snap/last");
}

// SnapType bitmask values (source/snap.d): Vertex=1.
unittest { // Vertex snap fires on a cube vert during box base-corner click
    resetBoxWithSnap("vertex");
    auto sr = clickBaseCornerAtOrigin();
    assert(sr["snapped"].type == JSONType.true_,
        "box base click should snap to a vertex, got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 1,
        "targetType expected 1 (Vertex), got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    foreach (i, c; wp) {
        double v = c.floating;
        assert(approx(v, -0.5) || approx(v, 0.5),
            "worldPos[" ~ i.to!string ~ "]=" ~ v.to!string
            ~ " is not a cube-vert coordinate; got " ~ sr.toString);
    }
}

// ---------------------------------------------------------------------------
// Handle drags under snap (task 9387 part G, D-FB). A handle drag's snap
// client point is the handle at the press plus the pointer travel since the
// press; a snapped value never becomes the next event's input. The size
// handle is captured (`cells_k_b9` K9b: grid-snaps from press + travel; K9c:
// after an element snap releases it rejoins the pointer); the mover and the
// height handle follow it as ours (gap row (viii)). Rig: top ortho at 440 px/m
// (our step 0.1); base typed centre (0, 0, 0), size 0.6 x 0.6, so the ±0.3
// faces sit on nodes. Each drag is 2 px per event (0.0045 m, far below the
// 0.05 m half step): its raw end is start + travel, which rounds to the next
// node; a client fed its own snapped position back never leaves the start.
// ---------------------------------------------------------------------------

import pen_rig_helpers : penCameraAt, penSceneEmpty, worldPixel;
import std.math : abs;
import std.string : indexOf;

private double qf(string attr) {
    auto r = postJson("/api/command", "tool.attr prim.cube " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    auto v = r["value"];   // a NaN is published as null: read it as NaN
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.float_ ? v.floating : double.nan;
}

private double gridStepNow() {
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"]["size"];
    return g.type == JSONType.integer ? cast(double)g.integer : g.floating;
}

/// Window pixel of a registered tool-handle part (asserted present).
private int[2] partPixel(int part) {
    double sx, sy; bool found;
    fetchHandlePart(part, sx, sy, found, BASE);
    assert(found, format("box handle part %d is not registered / on screen", part));
    return [cast(int)(sx + 0.5), cast(int)(sy + 0.5)];
}

/// `steps` events of `dx`, `dy` px each, from `p`.
private void dragSteps(int[2] p, int dx, int dy, int steps) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             p[0], p[1], p[0] + dx * steps, p[1] + dy * steps, steps), BASE);
}

/// Empty scene (+ `mesh`), top ortho at 440 px/m focused on the origin, a box
/// base drawn with snap off then typed to centre 0, size 0.6 x 0.6; snap on
/// with `types` and the shipped ranges.
private void boxBaseRig(string types, string mesh = "") {
    penSceneEmpty("Top");
    if (mesh.length) {
        auto r = postJson("/api/command", commandBody("scene.loadMesh", mesh));
        assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
        cmd("viewport.view Top");
    }
    penCameraAt(Vec3(0, 0, 0), 440);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig: top must be ortho");
    cmd("tool.set prim.cube");
    cmd("tool.pipe.attr snap enabled false");
    const a = worldPixel(Vec3(-0.2f, 0, -0.2f)), b = worldPixel(Vec3(0.2f, 0, 0.2f));
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             a[0], a[1], b[0], b[1], 16), BASE);
    foreach (kv; [["cenX", "0"], ["cenZ", "0"], ["sizeX", "0.6"], ["sizeZ", "0.6"]])
        cmd("tool.attr prim.cube " ~ kv[0] ~ " " ~ kv[1]);
    cmd("tool.pipe.attr snap enabled true");
    cmd(`tool.pipe.attr snap types "` ~ types ~ `"`);
    cmd("tool.pipe.attr snap fixedGrid false");
    cmd("tool.pipe.attr snap innerRange 24");
    cmd("tool.pipe.attr snap outerRange 40");
}

/// The +X face's edge handle: part 1 (`edgeDragIdx` 1 = +planeAxis1 = +X in
/// this frame), asserted at the pixel of the face midpoint (0.3, 0, 0).
private int[2] plusXEdgeHandle() {
    const p = partPixel(1), want = worldPixel(Vec3(0.3f, 0, 0));
    assert(abs(p[0] - want[0]) <= 1 && abs(p[1] - want[1]) <= 1,
        format("rig: edge part 1 must be the +X face handle at %s, found at %s", want, p));
    return p;
}

/// Cell 26's rig: the box built (perspective) with a Y height, typed y
/// 0..0.4, then the FRONT ortho preset at 440 px/m, grid snap; the premise
/// (Y in-plane) and the bottom height handle (part 20) asserted. Returns it.
private int[2] boxHeightRig() {
    penSceneEmpty("Top");
    auto r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set prim.cube");
    cmd("tool.pipe.attr snap enabled false");
    {
        auto cam = fetchCamera(BASE);
        auto vp = viewportFromCamera(cam);
        float ox, oy;
        assert(projectToWindow(Vec3(0, 0, 0), vp, ox, oy), "origin behind the camera");
        const int cx = cast(int)ox, cy = cast(int)oy;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 cx, cy, cx + 150, cy + 140, 16), BASE);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 cx, cy, cx, cy - 100, 16), BASE);
    }
    foreach (kv; [["cenX", "0"], ["cenY", "0.2"], ["cenZ", "0"], ["sizeX", "0.6"],
                  ["sizeY", "0.4"], ["sizeZ", "0.6"]])
        cmd("tool.attr prim.cube " ~ kv[0] ~ " " ~ kv[1]);
    cmd("viewport.view Front");
    penCameraAt(Vec3(0, 0.2f, 0), 440);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types grid");
    cmd("tool.pipe.attr snap fixedGrid false");
    cmd("tool.pipe.attr snap innerRange 24");
    cmd("tool.pipe.attr snap outerRange 40");
    const step = gridStepNow();
    const q = worldPixel(Vec3(0.123f, 0.456f, 0.789f));
    auto sr = postJson("/api/snap", format(
        `{"cursor":[0.123,0.456,0.789],"sx":%d,"sy":%d,"excludeVerts":[]}`, q[0], q[1]));
    assert(fabs(step - 0.1) < 1e-6 && sr["snapped"].type == JSONType.true_
        && fabs(sr["worldPos"].array[1].floating - 0.5) < 1e-4,
        format("rig: in the front view the work plane must hold Y in-plane "
            ~ "(step %s, a grid query at y 0.456 must land on y 0.5): %s", step, sr));
    const p = partPixel(20), want = worldPixel(Vec3(0, 0, 0));
    assert(abs(p[0] - want[0]) <= 1 && abs(p[1] - want[1]) <= 1,
        format("rig: height part 20 must be the bottom face at %s, found at %s", want, p));
    return p;
}

unittest { // handle drags under grid snap: not trapped; a released element snap rejoins
    int ran;
    string[] fails;

    // 24 box-edge-grid-slow (K9b): +X edge handle +40 px ⇒ the +X face at
    // 0.4, the -X face kept at -0.3.
    {
        boxBaseRig("grid");
        const step = gridStepNow();
        assert(fabs(step - 0.1) < 1e-6, format("rig: OUR step must be 0.1, got %s", step));
        dragSteps(plusXEdgeHandle(), 2, 0, 20);
        const face = qf("cenX") + qf("sizeX") * 0.5, opp = qf("cenX") - qf("sizeX") * 0.5;
        if (!(fabs(face - 0.4) < 1e-4 && fabs(opp + 0.3) < 1e-4))
            fails ~= format("box-edge-grid-slow: +X face expected 0.4 (opposite -0.3), "
                ~ "got %.6f (%.6f)", face, opp);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 24b box-edge-flip-grid (ours): the +X edge handle dragged 320 px left,
    // through the -X face: the dragged face (raw 0.3 - 0.727 = -0.427) is the
    // one that snaps, to -0.4; the face it crossed stays at -0.3. A drag that
    // kept the pre-flip edge would snap the held face and leave -0.427.
    {
        boxBaseRig("grid");
        dragSteps(plusXEdgeHandle(), -2, 0, 160);
        const lo = qf("cenX") - qf("sizeX") * 0.5, hi = qf("cenX") + qf("sizeX") * 0.5;
        if (!(fabs(lo + 0.4) < 1e-4 && fabs(hi + 0.3) < 1e-4))
            fails ~= format("box-edge-flip-grid: faces expected -0.4 .. -0.3, got %.6f .. %.6f",
                            lo, hi);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 25 box-mover-grid-slow: the mover's in-plane +X arrow (part 10) +40 px ⇒
    // the centre at x 0.1 (the pointer, 70 % along the arrow, has its own
    // node further out).
    {
        boxBaseRig("grid");
        const p = partPixel(10), c = worldPixel(Vec3(0, 0, 0));
        assert(p[0] - c[0] > 20 && abs(p[1] - c[1]) <= 1,
            format("rig: mover part 10 must be the +X arrow (centre %s, grab %s)", c, p));
        auto cam = fetchCamera(BASE);   // held, the drag publishes its snap (the overlay)
        playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1]), BASE);
        playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                       p[0], p[1], p[0] + 40, p[1], 20), BASE);
        if (fetchSnapLast(BASE)["snapped"].type != JSONType.true_)
            fails ~= "box-mover-grid-slow: the mover drag's snap is not published";
        playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0] + 40, p[1]), BASE);
        const cx = qf("cenX"), cz = qf("cenZ"), sx = qf("sizeX"), sz = qf("sizeZ");
        if (!(fabs(cx - 0.1) < 1e-4 && fabs(cz) < 1e-4 && fabs(sx - 0.6) < 1e-4
              && fabs(sz - 0.6) < 1e-4))
            fails ~= format("box-mover-grid-slow: centre expected (0.1, ·, 0) at size 0.6 x 0.6, "
                ~ "got (%.6f, ·, %.6f) at %.6f x %.6f", cx, cz, sx, sz);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 25b box-mover-arrow-vertex: the same +X arrow (part 10) dragged onto a
    // loose vertex V = (0.3, 0, 0.07) OFF the arrow's axis under vertex snap.
    // The arrow writes only its own axis: the centre takes V's x and keeps
    // z 0 and its y (an arrow writing all three would land z on 0.07).
    {
        boxBaseRig("vertex", `{"vertices":[[0.3,0,0.07]],"faces":[]}`);
        const p = partPixel(10), c = worldPixel(Vec3(0, 0, 0)), v = worldPixel(Vec3(0.3f, 0, 0.07f));
        assert(p[0] - c[0] > 20 && abs(p[1] - c[1]) <= 1 && abs(v[1] - c[1]) > 20,
            format("rig: part 10 must be the +X arrow (centre %s, grab %s), V off its axis at %s",
                   c, p, v));
        const cy0 = qf("cenY");
        auto cam = fetchCamera(BASE);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1], v[0], v[1], 22),
                    BASE);
        const cx = qf("cenX"), cy = qf("cenY"), cz = qf("cenZ");
        if (!(fabs(cx - 0.3) < 1e-4 && fabs(cz) < 1e-4 && fabs(cy - cy0) < 1e-6))
            fails ~= format("box-mover-arrow-vertex: centre expected (0.3, %.6f, 0), "
                ~ "got (%.6f, %.6f, %.6f)", cy0, cx, cy, cz);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 26 box-height-grid-slow: the box built (perspective, as the interactive
    // rig) with a Y height, typed y 0..0.4; then the FRONT ortho preset. The
    // premise first: the work plane turned with the view, so the height axis
    // Y is in-plane (a grid query's y lands on a node). Then the BOTTOM height
    // handle (part 20; the incremental one) dragged down 40 px ⇒ the bottom
    // face at y -0.1, the top kept at 0.4.
    {
        const p = boxHeightRig();
        dragSteps(p, 0, 2, 20);
        const bot = qf("cenY") - qf("sizeY") * 0.5, top = qf("cenY") + qf("sizeY") * 0.5;
        if (!(fabs(bot + 0.1) < 1e-4 && fabs(top - 0.4) < 1e-4))
            fails ~= format("box-height-grid-slow: bottom expected -0.1 (top 0.4), "
                ~ "got %.6f (%.6f)", bot, top);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 26b box-height-flip-grid (ours): cell 26's bottom handle dragged 240 px
    // up, through the top: the dragged face (raw 0.545) snaps to 0.5 and the
    // crossed top stays at 0.4.
    {
        dragSteps(boxHeightRig(), 0, -2, 120);
        const lo = qf("cenY") - qf("sizeY") * 0.5, hi = qf("cenY") + qf("sizeY") * 0.5;
        if (!(fabs(lo - 0.4) < 1e-4 && fabs(hi - 0.5) < 1e-4))
            fails ~= format("box-height-flip-grid: faces expected 0.4 .. 0.5, got %.6f .. %.6f",
                            lo, hi);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 27 box-edge-release (K9c): vertex bit only, the shipped 24 px range; a
    // loose vertex V 0.05 m beyond the +X face's start. The +X handle dragged
    // in 2 px events through V and 60 px past it ends on its own travel, the
    // line's quantum start + q(travel) = the captured 0.485 (K-G3 linear form,
    // task 9471; raw 0.4864), not raw minus the offset a retained snap would
    // leave (≤ 0.432).
    {
        boxBaseRig("vertex", `{"vertices":[[0.35,0,0]],"faces":[]}`);
        dragSteps(plusXEdgeHandle(), 2, 0, 41);
        const face = qf("cenX") + qf("sizeX") * 0.5;
        if (!(fabs(face - 0.485) <= 1e-4))
            fails ~= format("box-edge-release: +X face expected 0.485, got %.6f", face);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 27b box-size-offlattice (K-G2 Qb): the +X face typed OFF the lattice at
    // 0.3023, snapping off, dragged 40 px: start + q(travel) = 0.3923 (the
    // position form would give 0.395, the raw travel 0.3932).
    {
        boxBaseRig("vertex");
        cmd("tool.attr prim.cube sizeX 0.6046");
        cmd("tool.pipe.attr snap enabled false");
        const p = partPixel(1), want = worldPixel(Vec3(0.3023f, 0, 0));
        assert(abs(p[0] - want[0]) <= 1 && abs(p[1] - want[1]) <= 1,
            format("rig: edge part 1 must be the +X face handle at %s, found at %s", want, p));
        dragSteps(p, 2, 0, 20);
        const face = qf("cenX") + qf("sizeX") * 0.5;
        if (!(fabs(face - 0.3923) <= 1e-4))
            fails ~= format("box-size-offlattice: +X face expected 0.3923, got %.6f", face);
        cmd("tool.set prim.cube off");
        ++ran;
    }

    // 28 box-centre-vertex: the centre box (part 13) dragged onto a loose
    // vertex V = (0.103, 0.097, 0.25) under vertex snap, the identity work plane
    // PINNED, Front ortho. Premise: the box's plane normal is local Z (axis
    // attr z), so its mover arrows are not the local X, Y, Z order. The centre
    // box locks the view axis Z: the snap writes V's x and y and keeps z 0. V
    // is off the pixel lattice (440 px/m), so the raw drag end is not V.
    {
        penSceneEmpty("Front");
        auto r = postJson("/api/command", commandBody("scene.loadMesh",
                                                      `{"vertices":[[0.103,0.097,0.25]],"faces":[]}`));
        assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
        cmd("workplane.edit cenX:0 cenY:0 cenZ:0 rotX:0 rotY:0 rotZ:0");
        cmd("viewport.view Front");
        penCameraAt(Vec3(0, 0, 0), 440);
        cmd("tool.set prim.cube");
        cmd("tool.pipe.attr snap enabled false");
        const a = worldPixel(Vec3(-0.2f, -0.2f, 0)), b = worldPixel(Vec3(0.2f, 0.2f, 0));
        auto cam = fetchCamera(BASE);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 a[0], a[1], b[0], b[1], 16), BASE);
        foreach (kv; [["cenX", "0"], ["cenY", "0"], ["cenZ", "0"], ["sizeX", "0.6"], ["sizeY", "0.6"]])
            cmd("tool.attr prim.cube " ~ kv[0] ~ " " ~ kv[1]);
        const ax = postJson("/api/command", "tool.attr prim.cube axis ?")["value"];
        assert(ax.type == JSONType.string && ax.str == "z",
            format("rig: the box plane normal must be local Z, axis %s", ax));
        cmd("tool.pipe.attr snap enabled true");
        cmd("tool.pipe.attr snap types vertex");
        cmd("tool.pipe.attr snap innerRange 24");
        cmd("tool.pipe.attr snap outerRange 40");
        const p = partPixel(13), c = worldPixel(Vec3(0, 0, 0)), v = worldPixel(Vec3(0.103f, 0.097f, 0.25f));
        assert(abs(p[0] - c[0]) <= 1 && abs(p[1] - c[1]) <= 1 && v[0] - p[0] > 20 && p[1] - v[1] > 20,
            format("rig: centre part 13 at the origin %s (found %s), V up-right at %s", c, p, v));
        cam = fetchCamera(BASE);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1], v[0], v[1], 22),
                    BASE);
        const cx = qf("cenX"), cy = qf("cenY"), cz = qf("cenZ");
        if (!(fabs(cx - 0.103) < 1e-4 && fabs(cy - 0.097) < 1e-4 && fabs(cz) < 1e-4))
            fails ~= format("box-centre-vertex: centre expected (0.103, 0.097, 0), got (%.6f, %.6f, %.6f)",
                            cx, cy, cz);
        cmd("tool.set prim.cube off");
        cmd("workplane.reset");
        ++ran;
    }

    assert(ran == 9, format("population: %d box handle cells ran, expected 9", ran));
    string[] names;   // the red cells by name first: the runner shows 8 lines
    foreach (f; fails) names ~= f[0 .. f.indexOf(':')];
    assert(fails.length == 0, format("%d of 9 box handle cells red (%-(%s, %)):\n  %-(%s\n  %)",
                                     fails.length, names, fails));
}
