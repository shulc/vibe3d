// Off-handle PLANE scale — the election, driven through the REAL TOOL.
//
// `pickScalePlaneAxes`'s own unittest proves the kernel against five presses
// read out of the reference. It cannot prove the PORT: the kernel takes its
// inputs as parameters, and the question that matters is what
// `ScaleTool.pickPlaneAxes` hands it. The previous version of this port shipped
// for two commits with a kernel test that fed the reference's own recorded
// matrices — input the product never constructs — and it stayed green while the
// product computed something else. This file closes that hole from the outside:
// a real press, a real camera, a real drag, and an assertion about which axis of
// the mesh did not move.
//
// ── WHAT IT PINS ──────────────────────────────────────────────────────────
//
// The reference elects one basis axis to LEAVE ALONE — the one most nearly
// along the EYE RAY at the action centre — and gives the two survivors to the
// drag's horizontal and vertical components. So under a DIAGONAL drag exactly
// one axis of the mesh stays put, and WHICH one is the whole finding.
//
// The eye ray runs from the eye THROUGH the action centre, and in every mode
// that arms this drag the action centre is the click projected onto a plane —
// so it lies on the press ray, and the election is a function of WHERE YOU
// PRESS, not of the camera alone.
//
// That is what these two cases exist to show. They share ONE camera, set
// explicitly, and press at two points on it:
//
//   LEFT  press -> the eye ray's argmax is world Z -> Z is left alone,
//                  the horizontal drives X and the vertical drives Y
//   RIGHT press -> the eye ray's argmax is world X -> X is left alone,
//                  the horizontal drives Z and the vertical drives Y
//
// **No rule that reads only the camera can produce both rows.** The rule this
// port shipped until now was exactly such a rule — it asked which world axis
// was the most screen-horizontal — and on this camera it answers X for both
// presses, so it agrees with the LEFT row and contradicts the RIGHT one. The
// RIGHT case is therefore the discriminating one: it fails on the retracted
// rule and passes on the read.
//
// ── THE THIRD BRANCH IS THE COMMON ONE, AND IT IS EXERCISED BELOW ─────────
//
// The election's third branch — index 1 elected out, the only one that compares
// a screen projection — was described in an earlier version of this file as
// never executed and unconfirmed, so no case asserted it. Two traces had put 11
// presses through the election and the branch fired 0 times.
//
// A third read ran the reference-comparison corpus's OWN rig at its own camera
// and the branch fired 15 times: it is the branch three of the shipped
// action-centre modes take there, because their frame puts the selected face's
// normal in slot 2 and the eye ray's argmax lands on index 1. The clause was
// read at its own site on all 15 hits and is identical every time. So there IS
// a reference answer now, the branch is the majority path rather than an
// exotic one, and the last case in this file drives it through the real tool.
//
// WHAT IS STILL NOT PINNED: the bank. That comparison is against the view's
// screen-right, and the reference's view carries a roll (11.778 deg at the
// corpus camera) while ours is built `lookAt(…, +Y)` and cannot. Our exposure
// is therefore on a LIVE path, not a dead one. The case below is built where
// the two projections differ decisively, which is where a roll of that size
// cannot change the answer; a near-tie in this clause remains unproven for us
// and no case here should pretend otherwise.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.math : fabs, sqrt, abs;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

// The reference-comparison camera, in the spherical terms `/api/camera` takes
// (it accepts azimuth/elevation/distance/focus and IGNORES an `eye` field —
// posting eye/focus here would silently leave the default camera in place and
// this whole file would be measuring a different view).
//
// Its view direction is (0.4423, -0.4023, -0.8016): the dominant world axis is
// Z, by a clear 0.36. That is what every camera-only reading of this camera
// latches onto, and it is NOT what decides either case below.
enum double CAM_AZ = -0.504239, CAM_EL = 0.414005, CAM_DIST = 5.0;

struct Outcome {
    double[3][8] pre, post;
    double centerX, centerY, centerZ;   // action centre after the relocate
    double pressX, pressY;
    double gizmoDistPx;
    Vec3[3] axis;                       // the AXIS stage's frame: right/up/fwd
    Vec3    eye;                        // camera origin at the press
}

// Largest per-vertex displacement resolved along one AXIS-STAGE frame vector.
//
// The elected-out axis is elected in the FRAME, not in world coordinates, so
// "which axis stayed at 1" is only a world question while the frame happens to
// be the world axes. A rank-2 scale in the frame writes
// `post = C + sum_k f_k ((pre-C).A_k) A_k`, so the displacement's component
// along the excluded axis is `(f_e - 1) * (...) == 0`. That is the frame-aware
// reading, and it is what distinguishes an election that read the frame from
// one that read the world axes and merely APPLIED in the frame.
double maxDeltaAlong(ref Outcome o, Vec3 a) {
    double m = 0;
    foreach (i; 0 .. 8) {
        immutable double d = fabs((o.post[i][0] - o.pre[i][0]) * a.x
                                + (o.post[i][1] - o.pre[i][1]) * a.y
                                + (o.post[i][2] - o.pre[i][2]) * a.z);
        if (d > m) m = d;
    }
    return m;
}

// One off-handle press + diagonal drag. `fx`/`fy` are viewport fractions, so
// the case does not depend on the harness's window size. `actr` names an
// action-centre preset to install before the press ("" leaves the default);
// it is the ONE knob that changes both of the election's inputs, so the
// auto/origin cases below drive it and nothing else.
Outcome runOffHandlePlaneDrag(double fx, double fy, double az = CAM_AZ,
                              string actr = "", double el = CAM_EL,
                              string sel = "", double dist = CAM_DIST,
                              Vec3 guardPivot = Vec3(0, 0, 0)) {
    post(BASE ~ "/api/reset", "");
    // Default subject: the whole cube in vertex mode. The corpus's own rig
    // selects ONE POLYGON instead, which is what puts a face normal in the
    // AXIS stage's frame — pass it explicitly rather than defaulting to it,
    // so the cases that do not care keep the simpler subject.
    auto selResp = post(BASE ~ "/api/select",
                        sel.length ? sel
                                   : `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
           "select failed: " ~ cast(string)selResp);

    auto camResp = post(BASE ~ "/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,`
               ~ `"focus":{"x":0,"y":0,"z":0}}`, az, el, dist));
    assert(parseJSON(cast(string)camResp)["status"].str == "ok",
           "camera set failed: " ~ cast(string)camResp);

    auto setResp = post(BASE ~ "/api/script", "tool.set scale");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
           "tool.set scale failed: " ~ cast(string)setResp);

    if (actr.length) {
        auto acResp = post(BASE ~ "/api/script", "actr." ~ actr);
        assert(parseJSON(cast(string)acResp)["status"].str == "ok",
               "actr." ~ actr ~ " failed: " ~ cast(string)acResp);
    }

    Outcome o;
    foreach (i; 0 .. 8) o.pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    o.pressX = cam.vpX + fx * cam.width;
    o.pressY = cam.vpY + fy * cam.height;

    // Off-handle is a PRECONDITION, not an assumption: the press has to miss
    // every handle or the tool takes the axis-drag branch and this file is
    // measuring something else. Our gizmo's reach is ~106 px from the pivot,
    // which starts at the selection centroid.
    float gx, gy;
    assert(projectToWindow(guardPivot, vp, gx, gy),
           "the pivot must project on-screen for the off-handle check");
    o.gizmoDistPx = sqrt((o.pressX - gx) * (o.pressX - gx)
                       + (o.pressY - gy) * (o.pressY - gy));
    assert(o.gizmoDistPx > 150.0,
           "the press is only " ~ o.gizmoDistPx.to!string ~ " px from the "
           ~ "gizmo — that is not far enough to be off-handle, and this case "
           ~ "would be measuring an axis drag instead");

    // A DIAGONAL drag, so both screen components are non-zero and exactly one
    // axis can stay at 1. A purely horizontal drag would leave TWO axes alone
    // and discriminate nothing.
    string log = buildPinnedRelativeDragLog(cam.vpX, cam.vpY, cam.width,
                                            cam.height,
                                            cast(int)o.pressX,
                                            cast(int)o.pressY,
                                            120, -80, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) o.post[i] = vertexPos(i);
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    auto c = ev["actionCenter"]["center"].array;
    o.centerX = c[0].floating; o.centerY = c[1].floating; o.centerZ = c[2].floating;
    // The frame the election ran in, straight off the AXIS stage's packet —
    // the same one `ScaleTool.pickPlaneAxes` reads through `currentBasis`.
    static immutable string[3] SLOT = ["right", "up", "fwd"];
    foreach (k; 0 .. 3) {
        auto v = ev["axis"][SLOT[k]].array;
        o.axis[k] = Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                         cast(float)v[2].floating);
    }
    o.eye = cam.eye;
    return o;
}

string buildPinnedRelativeDragLog(int vpX, int vpY, int vpW, int vpH,
                                  int x0, int y0, int totalDx, int totalDy,
                                  int steps)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0, y0);
    int lastRx, lastRy;
    foreach (i; 1 .. steps + 1) {
        int rx = cast(int)((cast(double)totalDx * i) / steps);
        int ry = cast(int)((cast(double)totalDy * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            50.0 + i * 50.0, x0, y0, rx - lastRx, ry - lastRy);
        lastRx = rx; lastRy = ry;
    }
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        50.0 + (steps + 1) * 50.0, x0, y0);
    return log;
}

// Largest per-vertex movement along one world axis over the whole cube.
double maxDelta(ref Outcome o, int axis) {
    double m = 0;
    foreach (i; 0 .. 8) {
        immutable double d = fabs(o.post[i][axis] - o.pre[i][axis]);
        if (d > m) m = d;
    }
    return m;
}

// The cube's extent along one axis, before / after. The RATIO is the applied
// gain, independent of where the pivot landed — which is what makes it a clean
// read of the SIGN the drag applied.
double extentRatio(ref Outcome o, int axis) {
    double loA = o.pre[0][axis], hiA = o.pre[0][axis];
    double loB = o.post[0][axis], hiB = o.post[0][axis];
    foreach (i; 1 .. 8) {
        if (o.pre[i][axis]  < loA) loA = o.pre[i][axis];
        if (o.pre[i][axis]  > hiA) hiA = o.pre[i][axis];
        if (o.post[i][axis] < loB) loB = o.post[i][axis];
        if (o.post[i][axis] > hiB) hiB = o.post[i][axis];
    }
    return (hiB - loB) / (hiA - loA);
}

// Assert `left` is exactly untouched and the other two both moved. The second
// half is the null control: without it, a port that armed no drag at all would
// pass the interesting half of every case here.
void assertPlane(ref Outcome o, int left, string caseName) {
    static immutable string[3] AX = ["X", "Y", "Z"];
    assert(maxDelta(o, left) < 1e-4,
           caseName ~ ": world " ~ AX[left] ~ " had to be the ELECTED-OUT axis "
           ~ "and stay at scale 1, but it moved by "
           ~ maxDelta(o, left).to!string);
    foreach (a; 0 .. 3) {
        if (a == left) continue;
        assert(maxDelta(o, a) > 0.02,
               caseName ~ ": world " ~ AX[a] ~ " should have been driven by a "
               ~ "screen component but did not move ("
               ~ maxDelta(o, a).to!string ~ ") — the drag may not have armed "
               ~ "at all, which would make the other half of this case vacuous");
    }
}

unittest { // LEFT press: the eye ray points down world Z, so Z is left alone
    auto o = runOffHandlePlaneDrag(0.20, 0.35);
    // The action centre is the click projected onto the auto work plane, whose
    // normal on this camera is world Z through the focus — so a relocate that
    // did not happen, or happened somewhere else, shows up here first.
    assert(fabs(o.centerZ) < 1e-3,
           "the press must have RELOCATED the action centre onto the work "
           ~ "plane (z == 0); got z = " ~ o.centerZ.to!string);
    assert(o.centerX < 0.0,
           "a press left of centre must relocate to negative world X; got "
           ~ o.centerX.to!string);
    assertPlane(o, 2, "LEFT press");
}

unittest { // RIGHT press: SAME camera, and now the eye ray points down world X
    auto o = runOffHandlePlaneDrag(0.90, 0.35);
    assert(fabs(o.centerZ) < 1e-3,
           "the press must have RELOCATED the action centre onto the work "
           ~ "plane (z == 0); got z = " ~ o.centerZ.to!string);
    assert(o.centerX > 1.0,
           "a press well right of centre must relocate to a clearly positive "
           ~ "world X; got " ~ o.centerX.to!string);
    // THE DISCRIMINATING ASSERTION. On this camera the retracted rule — "the
    // most screen-horizontal axis takes the horizontal component" — answers X
    // for every press, which would leave Z alone here exactly as it does in the
    // LEFT case. The reference leaves X alone, because the election reads the
    // eye ray through THIS press and not the camera. If this line ever fails
    // while the LEFT case passes, the election has been reverted to a
    // camera-only rule.
    assertPlane(o, 0, "RIGHT press");
}

unittest { // the drag carries NO per-axis sign — only the screen convention
    // The reference writes its two accumulated screen components straight into
    // the elected attributes: `cur.x - last.x` into the horizontal one and
    // `last.y - cur.y` into the vertical one, with no factor derived from where
    // the elected axis points on screen. The rule this port shipped until now
    // multiplied by `sign(axis . screenRight)`, so the two disagree exactly
    // when the elected horizontal axis projects screen-LEFT.
    //
    // This camera is the LEFT case's, orbited 180 degrees, which negates
    // `camRight` to (-0.8755, 0, -0.4831). A press left of centre still elects
    // world Z out and gives the horizontal to X — but now `camRight.x` is
    // NEGATIVE, so the retracted per-axis sign would SHRINK X on a rightward
    // drag (gain 1 - 120/312.5 = 0.616) where the read GROWS it (1.384).
    //
    // NOTE ON STANDING: the absence of a per-axis sign is a STATIC decode. Every
    // recorded press had its elected axis projecting screen-right, so the live
    // recording cannot separate the two readings; this case pins our port to the
    // decode, not to a measurement.
    import std.math : PI;
    auto o = runOffHandlePlaneDrag(0.15, 0.35, CAM_AZ + PI);
    assertPlane(o, 2, "MIRRORED camera, left press");
    immutable double rx = extentRatio(o, 0);
    assert(rx > 1.30 && rx < 1.45,
           "a rightward drag must GROW the elected horizontal axis even when "
           ~ "that axis projects screen-LEFT: expected the measured 1 + 120/312.5 "
           ~ "= 1.384, got " ~ rx.to!string ~ ". A value near 0.616 means a "
           ~ "per-axis sign has come back");
}

unittest { // the two cases must actually disagree — the property, stated once
    auto left  = runOffHandlePlaneDrag(0.20, 0.35);
    auto right = runOffHandlePlaneDrag(0.90, 0.35);
    // Same camera by construction (both set the same eye/focus), so any
    // difference in outcome is press-dependence and nothing else.
    immutable bool leftKeptZ  = maxDelta(left,  2) < 1e-4;
    immutable bool rightKeptX = maxDelta(right, 0) < 1e-4;
    assert(leftKeptZ && rightKeptX,
           "two presses on ONE camera must elect DIFFERENT axes. This is the "
           ~ "property no camera-only rule can express, and it is why the "
           ~ "scored election was replaced by a read one");
    // And neither press may leave the SAME axis alone as the other, which is
    // the shape every rejected candidate had.
    assert(!(maxDelta(left, 2) < 1e-4 && maxDelta(right, 2) < 1e-4),
           "both presses left world Z alone — the election has collapsed back "
           ~ "to a function of the camera");
}

// ── THE PINNED ACTION-CENTRE FAMILY ───────────────────────────────────────
//
// A second read of the reference put six presses through FIVE action-centre
// modes in ONE execution and settled the structure: there is exactly one
// election, in one function, and it contains no test of the action-centre mode
// at all. The haul fetches the action centre once, as a packet whose whole
// payload is a single position, and elects from it. A mode reaches the
// election only by changing what the two INPUTS are — the centre `C`, and the
// tool axis frame `A_k`.
//
// Our port had that coupling backwards. The haul was armed inside the
// RELOCATE branch, after two early returns whose only job was to decide
// whether the pivot may move, so a mode that pins its pivot never reached the
// election: an off-handle drag in `origin` / `select` / `local` / `border`
// moved nothing at all, on every axis, measurably. The relocate now keeps its
// own gate and the haul gets none.
//
// The cases below pin the half of that which is EXPLAINED at the instruction
// level on this very camera — `auto` against `origin` — and pin that the two
// differ.
//
// WHAT THEY DELIBERATELY DO NOT PIN: `select` / `local` / `border`. The read
// refuses on those three — its rig displaced the subject and put them in a
// different cell than a cube-at-the-origin rig does — so there is no reference
// answer to asserts against. They arm, because the structure says every mode
// arms; the FRAME they elect in is our own AXIS stage's, and nothing about its
// content is transcribed from the reference. Do not add an assertion for them
// without a recording of the corpus's own rig in those modes.

unittest { // `origin`: the centre is PINNED, so the eye ray is the view forward
    // With the action centre at the world origin and the camera focused on the
    // world origin, `E = normalize(C - eye)` IS the view direction — the read
    // measured the two agreeing to all nine printed digits. This camera's view
    // direction has argmax |z| by a margin of 0.359, so the election drops Z
    // and the horizontal drives X.
    auto o = runOffHandlePlaneDrag(0.90, 0.35, CAM_AZ, "origin");
    // No relocate happened: a pinned mode must leave the centre exactly where
    // the pipeline put it. This is the load-bearing precondition — if the
    // press relocated after all, the case degenerates into the `auto` one.
    assert(fabs(o.centerX) < 1e-6 && fabs(o.centerY) < 1e-6
           && fabs(o.centerZ) < 1e-6,
           "actr.origin must NOT relocate the action centre; got ("
           ~ o.centerX.to!string ~ ", " ~ o.centerY.to!string ~ ", "
           ~ o.centerZ.to!string ~ ")");
    // And it must haul anyway. Before the fix this drag moved nothing on any
    // axis, so assertPlane's second half is the whole point of the case.
    assertPlane(o, 2, "actr.origin, right press");
}

unittest { // the auto/origin SPLIT — one camera, one press, two centres
    // The discriminator the corpus recorded, and the one the read explains at
    // the instruction level: at this camera `single_top_auto` scales z while
    // `single_top_origin` scales x, from the SAME press.
    //
    //   origin  C = (0,0,0)          -> E == view forward, argmax z by 0.359
    //                                -> elect 2 -> horizontal drives X
    //   auto    C = the relocated press point (well out along +X)
    //                                -> E tilts, argmax moves to x
    //                                -> elect 0 -> horizontal drives Z
    //
    // Neither the frame nor the camera differs between these two runs. ONLY
    // the centre does, which is exactly the claim: the mode enters the
    // election through its inputs, not through a branch.
    auto a = runOffHandlePlaneDrag(0.90, 0.35, CAM_AZ, "auto");
    auto g = runOffHandlePlaneDrag(0.90, 0.35, CAM_AZ, "origin");
    assert(g.centerX == 0.0 && a.centerX > 1.0,
           "the two modes must differ in the CENTRE and only the centre: "
           ~ "origin at " ~ g.centerX.to!string ~ ", auto at "
           ~ a.centerX.to!string);
    assertPlane(a, 0, "auto, right press");
    assertPlane(g, 2, "origin, right press");
    assert(maxDelta(a, 0) < 1e-4 && maxDelta(g, 0) > 0.02,
           "auto must leave world X alone and origin must SCALE it — that is "
           ~ "the recorded split. If both modes now agree, the election has "
           ~ "stopped reading the action centre and gone back to reading the "
           ~ "camera");
}

unittest { // a pinned mode's election is camera-only; a relocating one is not
    // The same two presses that make `auto` elect DIFFERENT axes leave
    // `origin` electing the SAME one, because a pinned centre does not move
    // with the press. This is the shape of the whole finding stated once: the
    // press-dependence lives in the CENTRE, not in the rule.
    auto originLeft  = runOffHandlePlaneDrag(0.20, 0.35, CAM_AZ, "origin");
    auto originRight = runOffHandlePlaneDrag(0.90, 0.35, CAM_AZ, "origin");
    assert(maxDelta(originLeft,  2) < 1e-4 && maxDelta(originRight, 2) < 1e-4,
           "a PINNED centre cannot move with the press, so both presses must "
           ~ "elect the same axis out; got left leaving "
           ~ maxDelta(originLeft, 2).to!string ~ " and right "
           ~ maxDelta(originRight, 2).to!string ~ " on Z");
    auto autoLeft  = runOffHandlePlaneDrag(0.20, 0.35, CAM_AZ, "auto");
    auto autoRight = runOffHandlePlaneDrag(0.90, 0.35, CAM_AZ, "auto");
    assert(maxDelta(autoLeft, 2) < 1e-4 && maxDelta(autoRight, 0) < 1e-4,
           "and a RELOCATING centre must still move with it — the two presses "
           ~ "have to elect different axes, or this contrast is vacuous");
}

// ── THE ELECTION RUNS IN THE AXIS STAGE'S FRAME, NOT IN WORLD COORDINATES ──
//
// `excluded = argmax_k |A_k . E|`, and `A_k` is the k-th column of the TOOL
// AXIS FRAME. The first read of the reference recorded that matrix as exactly
// the identity on all five presses it captured — but those were five presses
// of ONE action-centre mode, and a later read that covered five modes found
// three of them installing a rotated frame. So `A_k` is per-mode and must be
// read; ours is the AXIS stage's packet, which the `actr.*` presets flip in
// lockstep with ACEN.
//
// EVERY OTHER CASE IN THIS FILE IS BLIND TO THAT. They all run on a cube at the
// origin, where our selection-derived and workplane-derived frames are the
// world axes to the digit — so an election that ignored the frame entirely and
// used world XYZ would pass all of them. This case is the one that separates
// the two, and it is the case that fails if the call site is ever "simplified"
// to pass world axes.
//
// It is NOT enough to change the frame and observe that the result changed:
// the frame also drives the APPLY, so a mutant that elected on world axes and
// applied in the frame would still move differently. The discriminator has to
// be a cell where the two argmaxes land on DIFFERENT INDICES, because the
// permutation table is indexed by that number.
unittest {
    // Measured cell. `actr.screen` installs the camera-derived frame
    // (right = camera up, up = camera right, fwd = the view direction), and at
    // this camera and press:
    //
    //     |A_k . E| = (0.155, 0.324, 0.933)  -> argmax 2   <- the frame
    //     |E_k|     = (0.997, 0.061, 0.040)  -> argmax 0   <- world XYZ
    //
    // Two decisive readings — not a tie on either side — that disagree about
    // WHICH INDEX. The engine must drop index 2.
    auto o = runOffHandlePlaneDrag(0.15, 0.30, 1.20, "screen", 0.10);

    // The frame must actually be non-world here, or the case is vacuous:
    // slot 2 carries the view direction, which at this camera points nowhere
    // near world Z.
    assert(fabs(o.axis[2].z) < 0.9,
           "actr.screen must install a frame whose third slot is NOT world Z, "
           ~ "or this case cannot tell a frame election from a world one; got "
           ~ "axis[2].z = " ~ o.axis[2].z.to!string);

    // Self-contained proof that the cell discriminates: recompute both
    // argmaxes from the recorded action centre and eye, and refuse to assert
    // anything if they happen to agree (a camera change upstream could make
    // this cell stop discriminating, and silence would be worse than a fail).
    Vec3 E = normalize(Vec3(cast(float)(o.centerX - o.eye.x),
                            cast(float)(o.centerY - o.eye.y),
                            cast(float)(o.centerZ - o.eye.z)));
    int argmaxOf(double[3] v) {
        int b = 0;
        foreach (i; 1 .. 3) if (v[i] > v[b]) b = cast(int)i;
        return b;
    }
    double[3] frameDots = [abs(dot(o.axis[0], E)), abs(dot(o.axis[1], E)),
                           abs(dot(o.axis[2], E))];
    double[3] worldDots = [abs(E.x), abs(E.y), abs(E.z)];
    immutable int exFrame = argmaxOf(frameDots);
    immutable int exWorld = argmaxOf(worldDots);
    assert(exFrame != exWorld,
           "this cell no longer discriminates: the frame and world argmaxes "
           ~ "both say " ~ exFrame.to!string ~ ", so it cannot prove which one "
           ~ "the election read. Re-derive a cell where they differ rather "
           ~ "than deleting this case");

    // THE ASSERTION. The excluded axis is the one the displacement has no
    // component along.
    immutable double alongFrame = maxDeltaAlong(o, o.axis[exFrame]);
    immutable double alongWorld = maxDeltaAlong(o, o.axis[exWorld]);
    assert(alongFrame < 1e-4,
           "the election must drop the frame's argmax (index "
           ~ exFrame.to!string ~ "), so the drag must have NO component along "
           ~ "it; got " ~ alongFrame.to!string ~ ". A non-zero here means the "
           ~ "election stopped reading the AXIS stage's frame");
    assert(alongWorld > 0.02,
           "and it must NOT drop the WORLD argmax (index " ~ exWorld.to!string
           ~ "): that axis has to be driven. Got " ~ alongWorld.to!string
           ~ " — which is what a call site passing world XYZ instead of "
           ~ "`currentBasis` produces");
}

// ── THE `excluded == 1` BRANCH — THE ONE WITH THE COMPARISON ───────────────
//
// Reachability first, because this is what changed. Two traces put 11 presses
// through the election without this branch firing once, and the port shipped it
// marked unconfirmed and untested. Then the reference-comparison corpus's own
// rig was recorded — a unit cube with its +Y FACE selected — and the branch
// fired 15 times, on three of the five action-centre modes, at the corpus's own
// base camera. It is the common path, not the exotic one.
//
// It is the common path FOR US TOO, and by the same mechanism: our AXIS stage
// gives a polygon selection a frame built from the face normal, which for the
// +Y face is `right = +X, up = -Z, fwd = +Y` — the same signed permutation the
// reference installs there. That puts the eye ray's largest component on
// index 1 and routes the election into the comparison. The dot products agree
// with the reference's recorded ones to four decimals:
//
//     reference   A_k . E = (+0.481707, +0.873399, -0.071640)   elects 1
//     ours        A_k . E = (+0.4817,   +0.8734,   -0.0716)     elects 1
//
// The three cases below drive the branch and both of its arms.

enum string SEL_TOP_FACE = `{"mode":"polygons","indices":[4]}`;

// The corpus camera in the spherical terms /api/camera takes, and its own
// distance. Its view direction is the corpus's recorded
// (0.442173, -0.402161, -0.801717).
enum double CORPUS_DIST = 1.486323332;

unittest { // the CORPUS'S OWN RIG reaches the branch, and its frame is the read one
    auto o = runOffHandlePlaneDrag(0.80, 0.42, CAM_AZ, "select", CAM_EL,
                                   SEL_TOP_FACE, CORPUS_DIST, Vec3(0, 0.5, 0));
    // The centre and the frame are the two inputs, and both match the
    // reference's read of this rig exactly.
    assert(fabs(o.centerX) < 1e-6 && fabs(o.centerY - 0.5) < 1e-6
           && fabs(o.centerZ) < 1e-6,
           "actr.select on this rig must put the action centre on the selected "
           ~ "face at (0, 0.5, 0); got (" ~ o.centerX.to!string ~ ", "
           ~ o.centerY.to!string ~ ", " ~ o.centerZ.to!string ~ ")");
    assert(fabs(o.axis[0].x - 1) < 1e-5 && fabs(o.axis[1].z + 1) < 1e-5
           && fabs(o.axis[2].y - 1) < 1e-5,
           "the AXIS stage must give a face-normal frame (+X, -Z, +Y) here — "
           ~ "that is what elects index 1 — got right=" ~ o.axis[0].x.to!string
           ~ " up.z=" ~ o.axis[1].z.to!string ~ " fwd.y=" ~ o.axis[2].y.to!string);

    // THE DISCRIMINATOR, and it needs saying why it is one. The moving set is
    // one flat face, so it is PLANAR in the frame's `fwd` (+Y) — a scale along
    // that axis moves nothing, which is why world Y stays put here whichever
    // axis was elected. World Z is the test. Index 1 elected means `-Z` is the
    // axis left alone; had the election picked index 2 instead (which is what
    // it does when the frame is the world axes), the VERTICAL component would
    // have driven `-Z` and the face's z = +/-0.5 corners would have moved.
    assert(maxDelta(o, 2) < 1e-4,
           "world Z must be untouched: index 1 is the elected-out axis and the "
           ~ "frame's slot 1 IS -Z. Z moving by " ~ maxDelta(o, 2).to!string
           ~ " means the election picked a different index — most likely 2, "
           ~ "which is what a world-axis frame would give");
    assert(maxDelta(o, 0) > 0.10,
           "and world X must be driven by the horizontal — the corpus records "
           ~ "0.16 of x on this cell; got " ~ maxDelta(o, 0).to!string);
}

unittest { // the branch's FIRST arm, where the two survivors are observable
    // A near-top view puts the eye ray's largest component on world Y with the
    // identity frame, so index 1 is elected on a subject that is NOT planar in
    // either survivor — which is what the corpus rig cannot show. At this
    // azimuth the view's right is (cos 0.20, 0, -sin 0.20), so
    // |A0 . right| = 0.980 against |A2 . right| = 0.199: the FIRST arm, giving
    // the horizontal to X and the vertical to Z.
    auto o = runOffHandlePlaneDrag(0.25, 0.25, 0.20, "auto", 1.35);
    assertPlane(o, 1, "near-top, first arm");
    // Which survivor took WHICH component — the arm itself, not just the
    // elected axis. The drag is +120 horizontal and 80 vertical, so the two
    // gains are 1 + 120/312.5 = 1.384 and 1 + 80/312.5 = 1.256. Swapping the
    // arm swaps them.
    immutable double rx = extentRatio(o, 0), rz = extentRatio(o, 2);
    assert(rx > 1.37 && rx < 1.40,
           "the FIRST arm gives the horizontal to world X (gain 1.384); got "
           ~ rx.to!string ~ ". A value near 1.256 means the arms are swapped");
    assert(rz > 1.24 && rz < 1.27,
           "and the vertical to world Z (gain 1.256); got " ~ rz.to!string);
}

unittest { // the branch's SECOND arm — the same clause, the other way
    // Same near-top geometry, azimuth rotated so the comparison reverses:
    // the view's right is (cos 1.37, 0, -sin 1.37), so |A0 . right| = 0.199
    // against |A2 . right| = 0.980 and the strict `>` now FAILS, taking the
    // second arm. World Y is still the axis left alone; the two survivors swap
    // which drag component drives them.
    auto o = runOffHandlePlaneDrag(0.25, 0.25, 1.37, "auto", 1.40);
    assertPlane(o, 1, "near-top, second arm");
    immutable double rx = extentRatio(o, 0), rz = extentRatio(o, 2);
    assert(rz > 1.37 && rz < 1.40,
           "the SECOND arm gives the horizontal to world Z (gain 1.384); got "
           ~ rz.to!string ~ ". If this reads 1.256 the clause has stopped "
           ~ "reversing and both arms have collapsed into one");
    assert(rx > 1.24 && rx < 1.27,
           "and the vertical to world X (gain 1.256); got " ~ rx.to!string);
}
