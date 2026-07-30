module drag;

import std.math : sqrt, isNaN;
import math;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import tools.create.create_common : mostFacingAxis;

// ---------------------------------------------------------------------------
// THE DRAG CONVERSION SEAM
//
// "Where does a screen pixel become a world offset?" has exactly one answer:
// this module. Every interactive drag in the editor — transform gizmos,
// primitive movers, the alignment tools, every parameter haul — routes its
// pixels through one of the three laws below. Nothing outside this module may
// grow a fourth.
//
//   LAW A — axis projection.        `screenAxisWorldDelta` (the core) and its
//     three entry points `axisDragDelta` (handler), `axisDragDelta`
//     (input-basis) and `screenAxisDelta`. Project the drag axis to screen,
//     dot the pixel delta onto that screen segment, normalise by its squared
//     length, scale by the axis's WORLD length. Recomputed per motion event
//     from the caller's chosen reference pixel (some callers pass the press
//     pixel, some the previous event's).
//
//   LAW B — plane difference.       `planeDragDelta`. Two ray/plane
//     intersections per event, differenced. Exact per event rather than
//     linearised, and the plane is chosen by a camera-facing heuristic.
//
//   LAW C — anchored pixel scalar.  `haulWorldPerPixel`. One scalar, the
//     world length of a pixel at an anchor, frozen by the caller at the press.
//     For hauls that have no axis to project: the tool multiplies raw pixels
//     by it.
//
// LAW-CHANGE POINT: `screenAxisWorldDelta` below. It is the single body a
// future task rewrites to put us on a press-frozen conversion; LAW B and LAW C
// are then re-pointed at it from here, without any caller being touched.
//
// Deliberately NOT in this module, because they are a different quantity and a
// separate lane: the scale tool's screen projection
// (`tools/transform/scale.d`, same five lines but the result is a
// dimensionless scale factor — no world length multiplies it) and the radial
// array's ray/plane pair (`tools/alignment/radial_array_tool.d`, LAW B's shape
// but the result is an angle). Folding those in would change a law, not
// deduplicate one.
//
// All three laws return Vec3(0,0,0) / 0 and set `skip = true` when projection
// fails and the caller should just update lastMX/lastMY without moving.
// ---------------------------------------------------------------------------

// ===========================================================================
// LAW A — axis projection
// ===========================================================================

// The core. Every axis drag in the editor ends up here.
//
// `origin`/`axisEnd` are the world segment that gets PROJECTED; `axisDir` is
// the world direction the result travels along; `axisLen` is the world length
// one screen-segment-length of drag is worth.
//
// `axisEnd` is passed rather than derived from (`origin`, `axisDir`,
// `axisLen`) on purpose: each entry point projects a different tip (a rendered
// arrow's stored end, a basis axis scaled to the arrow length, or origin+axis
// with a non-unit axis), and `origin + axisDir*axisLen` is not bit-identical
// to any of them. Preserving each caller's exact tip is what makes this
// collapse a refactor instead of a behaviour change.
Vec3 screenAxisWorldDelta(int mx,     int my,
                          int lastMX, int lastMY,
                          Vec3 origin, Vec3 axisEnd,
                          Vec3 axisDir, float axisLen,
                          const ref Viewport vp,
                          out bool skip)
{
    skip = false;

    float ox, oy, ondcZ, tx, ty, tndcZ;
    if (!projectToWindowFull(origin,  vp, ox, oy, ondcZ) ||
        !projectToWindowFull(axisEnd, vp, tx, ty, tndcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = tx - ox, sdy = ty - oy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axisDir * d;
}

// Single-axis drag (dragAxis 0/1/2 = X/Y/Z).
// Uses the actual arrow end from the handler so the pixel/world ratio is
// correct even when the camera is very close to the gizmo center.
//
// Orientation-agnostic: the arrow's world-space direction *is* the axis we
// drag along, regardless of whether it's world XYZ or the active workplane
// basis. arrowEnd - center carries that direction and its length.
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

    Vec3  ae      = axisEnd - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }
    Vec3 axisDir = ae / axisLen;

    return screenAxisWorldDelta(mx, my, lastMX, lastMY,
                                center, axisEnd, axisDir, axisLen, vp, skip);
}

// Single-axis drag — input-basis OVERLOAD (dragAxis 0/1/2 = X/Y/Z).
//
// Same law as `axisDragDelta(handler)` above, but the drag AXIS DIRECTION is
// taken from the explicit `inputBasis{X,Y,Z}` triple (a frame the caller froze
// at drag start) instead of the live rendered arrow geometry
// (`handler.arrow*.end - handler.center`). This insulates the input projection
// from the rendered gizmo orientation, which a later phase moves during a
// drag. The pixel/world SCALE (`axisLen`) is still the gizmo's world-space
// arrow length — a render-size property, orientation-independent — read from
// the handler so the close-camera ratio stays exact.
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

    return screenAxisWorldDelta(mx, my, lastMX, lastMY,
                                center, axisEnd, inputAxis, axisLen, vp, skip);
}

// Delta for dragging along an arbitrary world axis from a screen mouse delta.
// `axis` should be a unit vector; the result is scaled to world units. The
// projected tip is `origin + axis` and the world scale is `|axis|`, so a
// non-unit axis scales the gain with its own length.
Vec3 screenAxisDelta(int mx,     int my,
                     int lastMX, int lastMY,
                     Vec3 origin, Vec3 axis,
                     const ref Viewport vp,
                     out bool skip)
{
    Vec3  tip     = origin + axis;
    float axisLen = sqrt(axis.x*axis.x + axis.y*axis.y + axis.z*axis.z);

    return screenAxisWorldDelta(mx, my, lastMX, lastMY,
                                origin, tip, axis, axisLen, vp, skip);
}

// ===========================================================================
// LAW B — plane difference
// ===========================================================================

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
//
// Kept as its OWN law, not folded into LAW A: per-event-exact versus
// linearised-at-the-press is exactly the difference a measurement is about,
// so unifying the two would be a behaviour change, not a deduplication. See
// the module header's law-change point.
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

// ===========================================================================
// LAW C — anchored pixel scalar
// ===========================================================================

// World units per screen pixel at `anchor` — the pixel→world gain for a haul
// that has no axis to project against (a parameter that is not a direction:
// an inset, a shift, a merge threshold). `gizmoSize(anchor, vp, 1.0f)` is the
// world length of a `getGizmoPixels()`-pixel span at `anchor`, so dividing by
// that pixel count gives one pixel's worth — perspective- and zoom-correct at
// the anchor, and constant for the drag because callers freeze it at the
// press.
//
// The anchor is the CALLER's business (selected-face centroid, selected-vertex
// centroid, gizmo anchor): that is the part that actually differs between the
// tools. Only this tail was ever shared, and it used to be copied verbatim
// into three of them.
float haulWorldPerPixel(Vec3 anchor, const ref Viewport vp) {
    float px = getGizmoPixels();
    if (px < 1e-6f) px = 90.0f;
    return gizmoSize(anchor, vp, 1.0f) / px;
}
