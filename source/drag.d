module drag;

import std.math : sqrt, abs;
import math;
import handler : MoveHandler;

// ---------------------------------------------------------------------------
// Shared drag-delta functions used by MoveTool and BoxTool (and any future
// tool that embeds a MoveHandler).
//
// Both functions return the world-space displacement for one mouse-motion
// event.  They return Vec3(0,0,0) and set `skip = true` when projection
// fails and the caller should just update lastMX/lastMY without moving.
// ---------------------------------------------------------------------------

// Single-axis drag (dragAxis 0/1/2 = X/Y/Z).
// Uses the actual arrow end from the handler so the pixel/world ratio is
// correct even when the camera is very close to the gizmo center.
Vec3 axisDragDelta(int mx,     int my,
                   int lastMX, int lastMY,
                   int dragAxis,
                   MoveHandler handler,
                   const ref Viewport vp,
                   out bool skip)
{
    skip = false;
    Vec3 center  = handler.center;
    Vec3 axisEnd = dragAxis == 0 ? handler.arrowX.end
                 : dragAxis == 1 ? handler.arrowY.end
                                 : handler.arrowZ.end;

    float cx, cy, cndcZ, ax_, ay_, andcZ;
    if (!projectToWindowFull(center,  vp, cx,  cy,  cndcZ) ||
        !projectToWindowFull(axisEnd, vp, ax_, ay_, andcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = ax_ - cx, sdy = ay_ - cy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    // Orientation-agnostic: the arrow's world-space direction *is* the
    // axis we drag along, regardless of whether it's world XYZ or the
    // active workplane basis. arrowEnd - center carries that direction
    // and its length; (axisDir * d) yields the world delta.
    Vec3  ae      = axisEnd - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }
    Vec3 axisDir = ae / axisLen;

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axisDir * d;
}

// Delta for dragging along an arbitrary world axis from a screen mouse delta.
// `axis` should be a unit vector; the result is scaled to world units.
Vec3 screenAxisDelta(int mx,     int my,
                     int lastMX, int lastMY,
                     Vec3 origin, Vec3 axis,
                     const ref Viewport vp,
                     out bool skip)
{
    skip = false;
    Vec3 tip = origin + axis;
    float ox, oy, ondcZ, tx, ty, tndcZ;
    if (!projectToWindowFull(origin, vp, ox, oy, ondcZ) ||
        !projectToWindowFull(tip,    vp, tx, ty, tndcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = tx - ox, sdy = ty - oy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    float axisLen = sqrt(axis.x*axis.x + axis.y*axis.y + axis.z*axis.z);
    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axis * d;
}

// Plane drag (dragAxis 3/4/5/6).
//   3 = most-facing plane (normal derived from view matrix vs basis)
//   4 = XY plane (normal Z)   5 = YZ plane (normal X)   6 = XZ plane (normal Y)
//
// Optional `axisX/axisY/axisZ` rotate the planes into the workplane basis —
// "XY" then means the axisX×axisY plane, the most-facing pick chooses among
// the basis axes. Default = world XYZ.
Vec3 planeDragDelta(int mx,     int my,
                    int lastMX, int lastMY,
                    int dragAxis,
                    Vec3 center,
                    const ref Viewport vp,
                    out bool skip,
                    Vec3 axisX = Vec3(1, 0, 0),
                    Vec3 axisY = Vec3(0, 1, 0),
                    Vec3 axisZ = Vec3(0, 0, 1))
{
    skip = false;
    Vec3 n;
    if      (dragAxis == 4) n = axisZ;
    else if (dragAxis == 5) n = axisX;
    else if (dragAxis == 6) n = axisY;
    else {
        // Most-facing plane: pick the basis axis most aligned with the
        // camera-back direction (view's third row in column-major).
        const ref float[16] v2 = vp.view;
        Vec3 camBack = Vec3(v2[2], v2[6], v2[10]);
        float aX = abs(camBack.x*axisX.x + camBack.y*axisX.y + camBack.z*axisX.z);
        float aY = abs(camBack.x*axisY.x + camBack.y*axisY.y + camBack.z*axisY.z);
        float aZ = abs(camBack.x*axisZ.x + camBack.y*axisZ.y + camBack.z*axisZ.z);
        n = aX >= aY && aX >= aZ ? axisX
          : aY >= aX && aY >= aZ ? axisY
                                 : axisZ;
    }

    const ref float[16] v = vp.view;
    Vec3 camOrigin = Vec3(
        -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
        -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
        -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
    );

    Vec3 hitCurr, hitPrev;
    if (!rayPlaneIntersect(camOrigin, screenRay(mx,     my,     vp), center, n, hitCurr) ||
        !rayPlaneIntersect(camOrigin, screenRay(lastMX, lastMY, vp), center, n, hitPrev))
    { skip = true; return Vec3(0,0,0); }

    return hitCurr - hitPrev;
}
