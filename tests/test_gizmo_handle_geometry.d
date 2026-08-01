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
//     neighbour. Of the three that carry a copy of the plane offset, two
//     caught the 0.75 -> 0.80 move and one (`test_move_tool_chained_drag`)
//     did not.
//
// So the pin below is geometric, not gestural: an exact world-space position
// for the plane handle. It hard-codes the ratio rather than importing
// GIZMO_PLANE_OFFSET — an independent restatement is the point, exactly as
// tests/drag_helpers.d keeps its own copy of the arm geometry. Moving the
// value in gl_util.d must fail here.

import std.math : PI, abs, cos, sin;

import handler : MoveHandler, ScaleHandler, gizmoSize, setGizmoPixels,
                 getGizmoPixels, Handler;
import math : Vec3, Viewport, cross, normalize, projectToWindowFull;
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
    return v.viewportWith(Vec3(0, 0, 0), 3.0f, 0.6f, 0.4f);
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
