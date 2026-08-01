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
// ── WHAT IT DOES NOT PIN ──────────────────────────────────────────────────
//
// The third branch of the election (world Y elected out, the only one that
// compares a screen projection) is NOT exercised here. It never executed on the
// recording either — it is decoded statically and unconfirmed — so there is no
// reference answer to assert against. Do not add a case for it without one.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, abs;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

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
}

// One off-handle press + diagonal drag. `fx`/`fy` are viewport fractions, so
// the case does not depend on the harness's window size.
Outcome runOffHandlePlaneDrag(double fx, double fy, double az = CAM_AZ) {
    post(BASE ~ "/api/reset", "");
    auto selResp = post(BASE ~ "/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
           "select failed: " ~ cast(string)selResp);

    auto camResp = post(BASE ~ "/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,`
               ~ `"focus":{"x":0,"y":0,"z":0}}`, az, CAM_EL, CAM_DIST));
    assert(parseJSON(cast(string)camResp)["status"].str == "ok",
           "camera set failed: " ~ cast(string)camResp);

    auto setResp = post(BASE ~ "/api/script", "tool.set scale");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
           "tool.set scale failed: " ~ cast(string)setResp);

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
    assert(projectToWindow(Vec3(0, 0, 0), vp, gx, gy),
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
    auto c = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"))
             ["actionCenter"]["center"].array;
    o.centerX = c[0].floating; o.centerY = c[1].floating; o.centerZ = c[2].floating;
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
