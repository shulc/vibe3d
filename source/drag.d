module drag;

import std.math : sqrt, isNaN;
import math;
import handler : MoveHandler;
import tools.create.create_common : mostFacingAxis;

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

// Single-axis drag — input-basis OVERLOAD (dragAxis 0/1/2 = X/Y/Z).
//
// Same screen→world math as `axisDragDelta(handler)` above, but the drag
// AXIS DIRECTION is taken from the explicit `inputBasis{X,Y,Z}` triple (a
// frame the caller froze at drag start) instead of the live rendered arrow
// geometry (`handler.arrow*.end - handler.center`). This insulates the input
// projection from the rendered gizmo orientation, which a later phase moves
// during a drag. The pixel/world SCALE (`axisLen`) is still the gizmo's
// world-space arrow length — a render-size property, orientation-independent
// — read from the handler so the close-camera ratio stays exact.
//
// MoveTool calls this; the box/sphere/cone/cylinder/capsule/torus primitive
// movers keep the original `axisDragDelta(handler)` signature above.
//
// Byte-stable note: today `inputBasis{X,Y,Z}` equals the handler's frozen
// orientation triple, so `inputAxis == axisDir` and the result is identical
// to the handler-derived path.
Vec3 axisDragDelta(int mx,     int my,
                   int lastMX, int lastMY,
                   int dragAxis,
                   MoveHandler handler,
                   Vec3 inputBasisX, Vec3 inputBasisY, Vec3 inputBasisZ,
                   const ref Viewport vp,
                   out bool skip)
{
    skip = false;
    Vec3 center    = handler.center;
    Vec3 inputAxis = dragAxis == 0 ? inputBasisX
                   : dragAxis == 1 ? inputBasisY
                                   : inputBasisZ;

    // Gizmo arrow world length (= screen-relative gizmo size) for the
    // pixel/world ratio. Orientation-independent: all three arrows share the
    // same length, so reading arrowX's is correct for any dragAxis.
    Vec3  ae      = handler.arrowX.end - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }

    Vec3 axisEnd = center + inputAxis * axisLen;

    float cx, cy, cndcZ, ax_, ay_, andcZ;
    if (!projectToWindowFull(center,  vp, cx,  cy,  cndcZ) ||
        !projectToWindowFull(axisEnd, vp, ax_, ay_, andcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = ax_ - cx, sdy = ay_ - cy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return inputAxis * d;
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
//
// Optional trailing `planeNormal` lets a caller that already holds the
// active workplane normal (the one that produced axisX/axisY/axisZ) hand it
// straight to the most-facing (dragAxis == 3) branch instead of having it
// re-derived here. NaN (the default) means "no override — derive as
// before". Scoped to dragAxis == 3 ONLY: the explicit-axis branches
// (4/5/6) always keep their requested plane regardless of this argument,
// so a future explicit-plane caller that also happens to pass a normal
// can't silently lose its requested plane.
Vec3 planeDragDelta(int mx,     int my,
                    int lastMX, int lastMY,
                    int dragAxis,
                    Vec3 center,
                    const ref Viewport vp,
                    out bool skip,
                    Vec3 axisX = Vec3(1, 0, 0),
                    Vec3 axisY = Vec3(0, 1, 0),
                    Vec3 axisZ = Vec3(0, 0, 1),
                    Vec3 planeNormal = Vec3(float.nan, float.nan, float.nan))
{
    skip = false;
    Vec3 n;
    if      (dragAxis == 4) n = axisZ;
    else if (dragAxis == 5) n = axisX;
    else if (dragAxis == 6) n = axisY;
    else if (!isNaN(planeNormal.x)) n = planeNormal;
    else {
        // Most-facing plane: pick the basis axis most aligned with the
        // camera-back direction (view's third row in column-major).
        const ref float[16] v2 = vp.view;
        Vec3 camBack = Vec3(v2[2], v2[6], v2[10]);
        final switch (mostFacingAxis(camBack, axisX, axisY, axisZ)) {
            case 0: n = axisX; break;
            case 1: n = axisY; break;
            case 2: n = axisZ; break;
        }
    }

    Vec3 origCurr, dirCurr, origPrev, dirPrev;
    screenPointToRay(cast(float)mx,     cast(float)my,     vp, origCurr, dirCurr);
    screenPointToRay(cast(float)lastMX, cast(float)lastMY, vp, origPrev, dirPrev);

    Vec3 hitCurr, hitPrev;
    if (!rayPlaneIntersect(origCurr, dirCurr, center, n, hitCurr) ||
        !rayPlaneIntersect(origPrev, dirPrev, center, n, hitPrev))
    { skip = true; return Vec3(0,0,0); }

    return hitCurr - hitPrev;
}
