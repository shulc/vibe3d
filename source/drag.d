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
    Vec3 axis    = dragAxis == 0 ? Vec3(1,0,0)
                 : dragAxis == 1 ? Vec3(0,1,0)
                                 : Vec3(0,0,1);

    float cx, cy, cndcZ, ax_, ay_, andcZ;
    if (!projectToWindowFull(center,  vp, cx,  cy,  cndcZ) ||
        !projectToWindowFull(axisEnd, vp, ax_, ay_, andcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = ax_ - cx, sdy = ay_ - cy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    Vec3  ae      = axisEnd - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axis * d;
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
//   3 = most-facing plane (normal derived from view matrix)
//   4 = XY plane (normal Z)   5 = YZ plane (normal X)   6 = XZ plane (normal Y)
Vec3 planeDragDelta(int mx,     int my,
                    int lastMX, int lastMY,
                    int dragAxis,
                    Vec3 center,
                    const ref Viewport vp,
                    out bool skip)
{
    skip = false;
    Vec3 n;
    if      (dragAxis == 4) n = Vec3(0,0,1);
    else if (dragAxis == 5) n = Vec3(1,0,0);
    else if (dragAxis == 6) n = Vec3(0,1,0);
    else {
        const ref float[16] v2 = vp.view;
        float avx = abs(v2[2]), avy = abs(v2[6]), avz = abs(v2[10]);
        n = avx >= avy && avx >= avz ? Vec3(1,0,0)
          : avy >= avx && avy >= avz ? Vec3(0,1,0)
                                     : Vec3(0,0,1);
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
