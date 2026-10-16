module vibe3d.editing.tools.transform.tools.transform.arcball;

import std.math : sqrt, atan2;
import vibe3d.util.math.math : Vec3, cross, dot;
import vibe3d.util.spatial.spatial : Viewport;

// ---------------------------------------------------------------------------
// THE OFF-GIZMO ROTATE GESTURE — a screen-space ball, and ONE law on it.
//
// A press that lands away from every rotate ring still rotates: the pointer
// drags a ball drawn in SCREEN PIXELS, centred on the action centre's screen
// projection, of radius `ARCBALL_RADIUS_PX`. The press pixel and the cursor
// pixel are each lifted onto that ball, and the gesture is the single rotation
// that carries the first lifted point to the second.
//
// THIS IS ONE GESTURE, NOT TWO. The two behaviours an off-gizmo drag shows —
//
//   * press FAR OUTSIDE the ball: a rotation about the VIEW axis by the angle
//     the pointer sweeps about the centre;
//   * press AT the centre (which is exactly what a click-relocated action
//     centre gives): a trackball, axis perpendicular to the drag IN the screen
//     plane, angle asin(|d| / radius);
//
// are the SAME arcball read at its two limits, and that is a measured claim,
// not a tidy way to describe two branches. Both limits agree on one radius —
// four independent reads at three drag lengths and two drag directions put it
// at 200.011 / 200.024 / 200.086 / 200.087 px, a 0.04 % spread — and one
// centre, fitted on eight rows at or under 200 px, predicts two 400 px rows in
// both directions that were never in the fit to five decimal places. Writing
// this as two branches with two constants would be a different thing that
// happens to agree wherever it was measured.
//
// So there is exactly one radius constant below, exactly one rotation solve,
// and the only conditional in the whole module is inside `arcballLift` — which
// is the definition of the BALL (a point beyond the rim lands ON the rim), not
// a fork in the gesture.
//
// Deliberately not in `drag.d`'s three-law seam: those laws answer "what world
// OFFSET is this pixel worth?" and are all anchored world-length conversions.
// This one answers "what ROTATION is this pixel worth?", carries no world
// length at all, and is scale-free — the same pixels give the same angle at
// any camera distance. Same reason the radial array's angle solve lives with
// the radial array.
// ---------------------------------------------------------------------------

/// Radius of the ball, in VIEWPORT PIXELS. Not a fraction of the viewport, not
/// an angle: a pixel count, and the one free constant of the whole gesture.
/// Measured at 200.011 / 200.024 / 200.086 / 200.087 px on four independent
/// rows; the 0.086 drift at the rim is the `asin` derivative there, not a
/// second constant.
enum float ARCBALL_RADIUS_PX = 200.0f;

/// Lift a screen-pixel offset from the ball's centre onto the ball.
///
/// The result lives in the ball's own right-handed frame:
///     x = screen RIGHT, y = screen UP, z = OUT of the screen (toward the eye).
/// `dyDown` is given in the pixel convention (y grows DOWNWARD), so the lift
/// flips it once, here, and nowhere else.
///
/// Inside the disc the point rises off the screen plane onto the near
/// hemisphere; at or beyond the rim it lands ON the rim (z = 0). Returns a UNIT
/// vector — the radius has divided out, which is why the caller never needs it
/// again.
Vec3 arcballLift(float dx, float dyDown, float radiusPx) @safe pure nothrow @nogc
{
    immutable float x  = dx;
    immutable float y  = -dyDown;              // pixels are y-down; the ball is y-up
    immutable float n2 = x * x + y * y;
    immutable float r2 = radiusPx * radiusPx;
    if (n2 >= r2) {
        immutable float n = sqrt(n2);
        if (!(n > 0.0f)) return Vec3(0, 0, 1);  // radius 0 and a zero offset
        return Vec3(x / n, y / n, 0.0f);        // on the rim
    }
    return Vec3(x / radiusPx, y / radiusPx, sqrt(r2 - n2) / radiusPx);
}

/// THE gesture. Both pixel offsets are measured from the ball's centre — i.e.
/// from the action centre's screen projection — in the pixel convention
/// (y down). Returns the rotation carrying the press's lifted point to the
/// cursor's: `axisCam` is a unit axis in the ball's frame (right, up, out of
/// screen), `angleRad` the angle between the two lifted points, right-handed
/// about that axis.
///
/// Returns false — and writes nothing usable — when the two lifted points are
/// parallel (no drag yet, or a drag straight through the ball's centre line).
/// A caller must hold its previous rotation on a false, not reset to identity.
///
/// ABSOLUTE, not incremental: the press offset is the gesture's fixed
/// reference, so every motion event re-derives the whole rotation since the
/// press and no error accumulates across a drag.
bool arcballRotation(float pressDx, float pressDyDown,
                     float curDx,   float curDyDown,
                     float radiusPx,
                     out Vec3 axisCam, out float angleRad) @safe pure nothrow @nogc
{
    immutable Vec3 v0 = arcballLift(pressDx, pressDyDown, radiusPx);
    immutable Vec3 v1 = arcballLift(curDx,   curDyDown,   radiusPx);
    immutable Vec3 c  = cross(v0, v1);
    immutable float s = sqrt(c.x * c.x + c.y * c.y + c.z * c.z);
    if (!(s > 1e-9f)) return false;
    axisCam  = c / s;
    angleRad = atan2(s, dot(v0, v1));
    return true;
}

/// Re-express an axis from the ball's frame in WORLD space, through the
/// viewport's own screen basis.
///
/// `lookAt` is column-major, so the view matrix's rows carry the camera axes:
/// (m0,m4,m8) = screen right, (m1,m5,m9) = screen up, (m2,m6,m10) = -forward,
/// i.e. OUT of the screen. Reading them here — rather than rebuilding a basis
/// from the eye and a world up — is what keeps the rotation aligned with what
/// the user sees under any camera roll.
Vec3 arcballAxisToWorld(Vec3 axisCam, const ref Viewport vp) @safe pure nothrow @nogc
{
    immutable Vec3 right = Vec3(vp.view[0], vp.view[4], vp.view[8]);
    immutable Vec3 up    = Vec3(vp.view[1], vp.view[5], vp.view[9]);
    immutable Vec3 outv  = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    return right * axisCam.x + up * axisCam.y + outv * axisCam.z;
}
