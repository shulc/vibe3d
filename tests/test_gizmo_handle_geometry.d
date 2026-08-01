// Task 0553 — the transform gizmo's ported handle geometry, pinned.
//
// Pure unittest (no HTTP, no GL): constructs the handler banks directly,
// calls `syncGeometry(vp)` to derive their camera-dependent geometry, and
// asks the handles themselves where they are. Model:
// tests/test_gizmo_hover_multicell.d, which does the same for the
// hover-flicker fix.
//
// WHY A NEW FILE, given ~40 drag tests already press gizmo handles. Because
// none of them pins where a handle IS:
//
//   * The anchor-driven family reads its press point from
//     `/api/tool/handles` -> `screenAnchor`, so it MOVES WITH the geometry
//     and cannot see a relocated handle at all.
//   * The hard-coded family recomputes the press point from a duplicated
//     constant — but a drag test only reports whether SOMETHING was grabbed,
//     so it fails only when the press misses by enough to land on a
//     neighbour, and it says nothing about by how much. Of the three files
//     carrying a copy of the plane offset, two caught the 0.75 -> 0.80 move
//     and one (`test_move_tool_chained_drag`) did not.
//
// So the pins here are geometric, not gestural: exact positions, and one
// projected LENGTH. They cover, in order:
//
//   1. the plane handle sits at 0.80 of the arm, identically on both banks;
//   2. the arm spans 120 screen pixels, and keeps spanning 120 as the camera
//      dollies — the size law itself, not just its constant;
//   3. both banks start their shaft at arm/5 and end it at the arm — one
//      inset, no stagger;
//   4. the plane ring's radius is a fixed 8 px while its offset scales.
//
// Every one hard-codes its constant rather than importing the GIZMO_* enum —
// an independent restatement is the point, exactly as tests/drag_helpers.d
// keeps its own copy of the arm geometry. Moving a value in gl_util.d must
// fail here, and each of the six (plane offset, arm length, the two shaft
// insets, the scale arm end, the ring radius) was mutation-checked to confirm
// it does.

import std.conv : to;
import std.math : PI, abs, cos, sin, sqrt;

import handler : MoveHandler, ScaleHandler, gizmoSize, setGizmoPixels,
                 getGizmoPixels, Handler;
import math : Vec3, Viewport, cross, normalize, projectToWindowFull, Orientation;
import view : View;

void main() {}

// Same local right/up frame construction as handles/shapes.d's PRIVATE
// `localFrame` (deliberately duplicated — not importable across modules):
// given a plane `normal`, pick the right/up basis that `CircleHandler` and
// `CenterDiskGizmo` parametrize their rims with.
private void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp = abs(fwd.x) < 0.9f ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}

private bool vec3Close(Vec3 a, Vec3 b, float eps) {
    return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps;
}

// Project a world point to the pixel a user would be over, and ask the
// handle whether that pixel grabs it — the same int-pixel path the real
// mouse takes.
private bool hitAtWorld(Handler h, Vec3 world, const ref Viewport vp) {
    float sx, sy, z;
    assert(projectToWindowFull(world, vp, sx, sy, z),
           "probe point failed to project — pick a camera that frames it");
    return h.hitTest(cast(int)sx, cast(int)sy, vp);
}

// An oblique camera: no gizmo axis is edge-on, so every plane circle
// projects to a proper ellipse and every face of the centre box is a
// proper quad. An axis-aligned camera would make some of them degenerate
// and the probes below meaningless.
private Viewport obliqueVp(View v) {
    return v.viewportWith(Vec3(0, 0, 0), 3.0f, Orientation.fromAngles(0.6f, 0.4f, v.roll));
}

unittest { // Plane handles sit at 0.80 of the arm, on BOTH banks
    auto v  = new View(0, 0, 800, 600);
    auto vp = obliqueVp(v);
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);

    // The ported ratio, restated independently of GIZMO_PLANE_OFFSET.
    // 0.80, not our historical 0.75: the reference ships this proportion as
    // a preference governing the handles that constrain an action to two
    // axes at once, its value there is 0.80, and its three plane rings were
    // measured sitting at ≈0.8 of an arm along each of their two axes.
    enum float PLANE_RATIO = 0.80f;

    immutable Vec3 ax = Vec3(1, 0, 0), ay = Vec3(0, 1, 0), az = Vec3(0, 0, 1);
    immutable float off = size * PLANE_RATIO;
    // A world-space tolerance worth ~0.05 px on screen: the 0.75 -> 0.80
    // move is 0.05 * size per axis, i.e. 1000x this. Nothing subtle here.
    immutable float eps = size * 5e-5f;

    auto mv = new MoveHandler(pivot);
    mv.syncGeometry(vp);
    assert(vec3Close(mv.circleXY.center, pivot + ax*off + ay*off, eps),
           "move XY plane handle is not at 0.80 of the arm on both axes");
    assert(vec3Close(mv.circleYZ.center, pivot + ay*off + az*off, eps),
           "move YZ plane handle is not at 0.80 of the arm on both axes");
    assert(vec3Close(mv.circleXZ.center, pivot + ax*off + az*off, eps),
           "move XZ plane handle is not at 0.80 of the arm on both axes");

    // One ratio, not one per bank — the reference publishes a single plane
    // handle ratio, so scale must agree with move to the last bit.
    auto sc = new ScaleHandler(pivot);
    sc.syncGeometry(vp);
    assert(vec3Close(sc.circleXY.center, mv.circleXY.center, eps),
           "scale XY plane handle disagrees with move's");
    assert(vec3Close(sc.circleYZ.center, mv.circleYZ.center, eps),
           "scale YZ plane handle disagrees with move's");
    assert(vec3Close(sc.circleXZ.center, mv.circleXZ.center, eps),
           "scale XZ plane handle disagrees with move's");
}

unittest { // The arm is 120 SCREEN pixels, and stays 120 as the camera dollies
    // The size law, read out of the reference rather than measured off a
    // screenshot: the arm is `handleScale * 6.0` SCREEN units converted at
    // 20 pixels per screen unit, i.e. 120 px at its shipped handle scale, and
    // the conversion divides by the view's own scale — so the WORLD length
    // moves with the camera and the SCREEN length does not. On one recorded
    // execution the world arm spanned exactly 1024x across four cameras while
    // the screen length stayed bit-identical.
    //
    // The pin measures the projected arm rather than reading the constant, so
    // it covers `gizmoSize` as well as the number: a camera looking straight
    // down -Z puts +X in the screen plane, where there is no foreshortening
    // and the projected length IS the nominal one.
    enum float ARM_PX = 120.0f;

    auto v = new View(0, 0, 800, 600);
    Vec3 pivot = Vec3(0, 0, 0);

    foreach (dist; [2.0f, 10.0f, 50.0f]) {
        Viewport vp = v.viewportWith(pivot, dist, Orientation.fromAngles(0.0f, 0.0f, v.roll));
        auto mv = new MoveHandler(pivot);
        mv.syncGeometry(vp);

        float ox, oy, oz, ex, ey, ez;
        assert(projectToWindowFull(pivot, vp, ox, oy, oz), "pivot off-camera");
        assert(projectToWindowFull(mv.arrowX.end, vp, ex, ey, ez),
               "arm end off-camera");
        float px = abs(ex - ox);
        assert(abs(px - ARM_PX) < 0.5f,
               "the move arm should span 120 screen px in the screen plane; "
               ~ "at camera distance " ~ dist.to!string ~ " it spans "
               ~ px.to!string);
    }
}

unittest { // One shaft inset, one arm end — the two banks agree
    // Measured: the reference starts BOTH banks' shafts at screenLength/5
    // (24 px) and ends BOTH banks' arms at screenLength (120 px). We had two
    // insets (/6 move, /7 scale) and an 18 % stagger between the arm ends;
    // neither exists over there.
    enum float INSET_DIV = 5.0f;
    enum float ARM_RATIO = 1.00f;

    auto v  = new View(0, 0, 800, 600);
    auto vp = obliqueVp(v);
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    immutable Vec3 ax = Vec3(1, 0, 0);
    immutable float eps = size * 5e-5f;

    auto mv = new MoveHandler(pivot);  mv.syncGeometry(vp);
    auto sc = new ScaleHandler(pivot); sc.syncGeometry(vp);

    assert(vec3Close(mv.arrowX.start, pivot + ax * (size / INSET_DIV), eps),
           "move shaft does not start at arm/5");
    assert(vec3Close(sc.arrowX.start, pivot + ax * (size / INSET_DIV), eps),
           "scale stem does not start at arm/5");
    assert(vec3Close(mv.arrowX.end, pivot + ax * (size * ARM_RATIO), eps),
           "move arm does not end at the arm length");
    assert(vec3Close(sc.arrowX.end, pivot + ax * (size * ARM_RATIO), eps),
           "scale arm does not end at the arm length — a stagger is back");
    assert(vec3Close(mv.arrowX.start, sc.arrowX.start, eps),
           "the two banks disagree about where the shaft starts");
    assert(vec3Close(mv.arrowX.end, sc.arrowX.end, eps),
           "the two banks disagree about where the arm ends");
}

unittest { // The plane ring's RADIUS is a pixel count; its OFFSET is not
    // The reference sets this ring's radius to a plain 8 pixels while
    // computing its offset from the arm, in the same function. So growing the
    // gizmo moves the rings outward WITHOUT growing them — which is the
    // asymmetry this pin exists to hold, since our previous 0.07-of-the-arm
    // radius grew with everything else.
    enum float RING_R_PX = 8.0f;

    immutable float savedPx = getGizmoPixels();
    scope(exit) setGizmoPixels(savedPx);

    auto v  = new View(0, 0, 800, 600);
    Vec3 pivot = Vec3(0, 0, 0);

    float[2] ringPx, offsetPx;
    foreach (i, armPx; [120.0f, 480.0f]) {
        setGizmoPixels(armPx);
        Viewport vp = v.viewportWith(pivot, 10.0f, Orientation.fromAngles(0.0f, 0.0f, v.roll));
        auto mv = new MoveHandler(pivot);
        mv.syncGeometry(vp);

        // The XY ring's normal is +Z, i.e. straight at this camera, so its
        // projected rim distance is its true screen radius.
        Vec3 right, up;
        localFrame(mv.circleXY.normal, right, up);
        float cx, cy, cz, rx, ry, rz, ox, oy, oz;
        assert(projectToWindowFull(mv.circleXY.center, vp, cx, cy, cz),
               "ring centre off-camera");
        assert(projectToWindowFull(mv.circleXY.center + right * mv.circleXY.radius,
                                   vp, rx, ry, rz), "ring rim off-camera");
        assert(projectToWindowFull(pivot, vp, ox, oy, oz), "pivot off-camera");
        ringPx[i]   = sqrt((rx - cx) * (rx - cx) + (ry - cy) * (ry - cy));
        offsetPx[i] = sqrt((cx - ox) * (cx - ox) + (cy - oy) * (cy - oy));
    }

    assert(abs(ringPx[0] - RING_R_PX) < 0.5f && abs(ringPx[1] - RING_R_PX) < 0.5f,
           "the plane ring's radius should be a fixed 8 px at every gizmo size");
    assert(abs(offsetPx[1] / offsetPx[0] - 4.0f) < 0.05f,
           "the plane ring's OFFSET should scale with the arm (4x here) even "
           ~ "though its radius does not");
}
