module tools.transform.arcball;

import std.math : sqrt, atan2;
import math : Vec3, Viewport, cross, dot;

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

// ---------------------------------------------------------------------------
// Tests. Every number below is an observation, and every observation is stated
// in the geometry it was taken in: a press pixel and a cursor pixel measured
// from the ball's centre. Nothing here is fitted.
// ---------------------------------------------------------------------------

version (unittest) {
    import std.math : PI, abs, sin, cos;

    private float deg(float rad) { return rad * 180.0f / cast(float)PI; }

    // The reference signs a rotation about the camera's FORWARD axis — the one
    // pointing INTO the screen — while this module's frame carries the axis
    // pointing OUT of it. One negation, stated once, so every row below can be
    // written with the number that was observed.
    private float signedAboutForward(Vec3 axisCam, float angleRad) {
        return deg(angleRad) * (axisCam.z >= 0 ? -1.0f : 1.0f);
    }

    // A row of the reference measurement, restated as pure pixel geometry:
    // where the press sat relative to the ball's centre, how far the pointer
    // then moved, and the rotation that came out.
    private struct Row {
        string name;
        float pressDx, pressDy;   // press, relative to the centre, y DOWN
        float dragDx,  dragDy;    // pointer displacement, y DOWN
        float angleDeg;           // observed rotation
        float axR, axU, axF;      // observed axis in (right, up, out-of-screen)
    }
}

unittest {  // The TRACKBALL limit: press at the centre, four independent reads.
    // These are the four rows that put the radius at 200.011 / 200.024 /
    // 200.086 / 200.087 px. A click-relocated action centre puts the pivot
    // under the press, so the press offset is exactly zero and the drag alone
    // decides the rotation: `asin(|d| / R)` about the axis perpendicular to the
    // drag IN the screen plane. The fourth row is the one that makes it a
    // trackball rather than "a rotation about screen up": the same 200 px
    // dragged DOWNWARD turns by the same magnitude about screen RIGHT.
    immutable Row[] rows = [
        Row("+50 px x",  0, 0,   50,   0, 14.4767f,  0, +1, 0),
        Row("+100 px x", 0, 0,  100,   0, 29.9961f,  0, +1, 0),
        Row("+200 px x", 0, 0,  200,   0, 88.3195f,  0, +1, 0),
        Row("+200 px y", 0, 0,    0, 200, 88.3081f, +1,  0, 0),
    ];
    foreach (r; rows) {
        Vec3 ax; float ang;
        assert(arcballRotation(r.pressDx, r.pressDy,
                               r.pressDx + r.dragDx, r.pressDy + r.dragDy,
                               ARCBALL_RADIUS_PX, ax, ang),
               "a trackball drag must produce a rotation: " ~ r.name);
        // The observed angle is what a 200.0-px ball gives, to the 0.04 % the
        // four rows themselves spread over. At the rim (the two 200 px rows)
        // asin's derivative blows a 0.086 px radius difference up to 1.7 deg,
        // so the tolerance is stated per row rather than pooled.
        immutable float tolDeg = (r.dragDx * r.dragDx + r.dragDy * r.dragDy
                                  > 150.0f * 150.0f) ? 2.0f : 0.02f;
        assert(abs(deg(ang) - r.angleDeg) < tolDeg,
               "trackball angle off the measured row: " ~ r.name);
        assert(abs(ax.x - r.axR) < 1e-4f && abs(ax.y - r.axU) < 1e-4f
            && abs(ax.z - r.axF) < 1e-4f,
               "trackball axis must be perpendicular to the drag IN the screen "
               ~ "plane: " ~ r.name);
    }

    // …and the radius each of them implies, read back out of the law, is ONE
    // number. This is the assert that would fail if the trackball limit had
    // been given a constant of its own.
    foreach (r; rows) {
        Vec3 ax; float ang;
        assert(arcballRotation(0, 0, r.dragDx, r.dragDy,
                               ARCBALL_RADIUS_PX, ax, ang));
        immutable float d = sqrt(r.dragDx * r.dragDx + r.dragDy * r.dragDy);
        immutable float impliedR = d / sin(r.angleDeg * cast(float)PI / 180.0f);
        assert(abs(impliedR - ARCBALL_RADIUS_PX) < 0.15f,
               "every trackball row must imply the SAME radius");
    }
}

unittest {  // The RIM limit: press outside the ball, and the FIT rows.
    // Five reference rows, all with the press well outside the ball (243 to
    // 934 px from the centre), covering three press distances, four drag
    // lengths and both drag directions. Out there both lifted points sit on the
    // rim, so the axis is the VIEW axis and the angle is the polar angle the
    // pointer sweeps about the centre — which is what makes these rows a test
    // of the SAME function the trackball rows above exercise, at its other end.
    //
    // Press offsets are the reference's own press pixel minus the centre the
    // fit recovered, so these are observations, not derivations.
    immutable Row[] rows = [
        // press 500.3 px out, the corpus's own drag
        Row("out 500, +100 x", 363.05f, 344.34f,  100,    0,  -6.8492f, 0, 0, +1),
        Row("out 500, +200 x", 363.05f, 344.34f,  200,    0, -12.0366f, 0, 0, +1),
        Row("out 500, +50 x",  363.05f, 344.34f,   50,    0,  -3.6686f, 0, 0, +1),
        Row("out 500, +200 y", 363.05f, 344.34f,    0,  200, +12.8135f, 0, 0, +1),
        // press 242.7 px out and 934.4 px out, same drag: the angle a press
        // NEARER the centre buys is bigger, which is the pivot-dependence that
        // separates this law from a fixed rate on perpendicular pixels.
        Row("out 243, +100 x", 173.05f, 124.34f,  100,    0, -11.2149f, 0, 0, +1),
        Row("out 934, +100 x", 583.05f, 684.34f,  100,    0,  -4.5153f, 0, 0, +1),
    ];
    foreach (r; rows) {
        Vec3 ax; float ang;
        assert(arcballRotation(r.pressDx, r.pressDy,
                               r.pressDx + r.dragDx, r.pressDy + r.dragDy,
                               ARCBALL_RADIUS_PX, ax, ang));
        // A rim rotation's axis is the view axis, and its SIGN carries the
        // direction the model turns. Signing about FORWARD (into the screen)
        // is the reference's own convention, so a sign slip fails here rather
        // than showing up later as a model that turns the wrong way.
        immutable float signed = signedAboutForward(ax, ang);
        assert(abs(ax.x) < 1e-3f && abs(ax.y) < 1e-3f,
               "a press outside the ball must rotate about the VIEW axis: "
               ~ r.name);
        assert(abs(signed - r.angleDeg) < 0.02f,
               "rim angle off the measured row: " ~ r.name);
    }
}

unittest {  // The HOLD-OUT, and the rival it refutes.
    // The two rows below were never in the fit that placed the ball's centre:
    // that was done on eight rows at or under 200 px, and these are 400 px, in
    // both directions. The law predicts them to five decimals.
    //
    // The rival — a pivot-independent rate on the perpendicular pixel
    // component, which agrees with this law to 1.4 % at 100 px and is the
    // reason one drag length could not choose between them — predicts +27.396
    // and -25.486 on these two rows. It is refuted by a factor of two, and this
    // test is written at 400 px BECAUSE a test at 100 px cannot tell them
    // apart.
    static struct Held { string name; float dx, dy; float obs, rival; }
    immutable Held[] held = [
        Held("-400 px in x",  -400,    0, +52.6395f, +27.396f),
        Held("-400 px in y",     0, -400, -52.2009f, -25.486f),
    ];
    enum float pressDx = 363.05f, pressDy = 344.34f;   // the same 500.3 px press
    foreach (h; held) {
        Vec3 ax; float ang;
        assert(arcballRotation(pressDx, pressDy,
                               pressDx + h.dx, pressDy + h.dy,
                               ARCBALL_RADIUS_PX, ax, ang));
        immutable float signed = signedAboutForward(ax, ang);
        assert(abs(signed - h.obs) < 0.02f,
               "the held-out 400 px row must be PREDICTED, not fitted: " ~ h.name);
        assert(abs(signed - h.rival) > 20.0f,
               "…and it must be nowhere near the rival law, or the row is not "
               ~ "buying the separation it was taken for: " ~ h.name);
    }

    // The separation, said the other way round: at 100 px the two laws agree,
    // so a test written there proves nothing. Kept as an assert so nobody
    // "simplifies" the hold-out down to a short drag.
    {
        Vec3 ax; float ang;
        assert(arcballRotation(pressDx, pressDy, pressDx + 100, pressDy,
                               ARCBALL_RADIUS_PX, ax, ang));
        immutable float signed = signedAboutForward(ax, ang);
        assert(abs(abs(signed) - 6.8492f) < 0.02f);
        assert(abs(abs(signed) - 6.9447f) < 0.15f,
               "at 100 px the rival's own number is within 1.4 % — this is the "
               ~ "row that CANNOT discriminate, and it is here to say so");
    }
}

unittest {  // ONE law, not two branches: the rim is a limit, not a seam.
    // The two behaviours the reference shows — a view-axis sweep outside, a
    // trackball at the centre — are read here as two limits of one ball, and
    // the claim that carries weight is that NOTHING HAPPENS at the boundary
    // between them. A two-branch implementation with a constant per branch
    // would step there; this one does not.
    //
    // Approach the rim from inside and cross it. The angle rises monotonically
    // to a quarter turn and then stays there. Its DERIVATIVE does blow up at
    // the rim (a square-root cusp: `90 deg - asin(1-e)` goes like `sqrt(2e)`),
    // which is why this asserts continuity of the VALUE and a bound of that
    // shape, not a bound on the step.
    float prev = -1;
    foreach (i; 0 .. 41) {
        immutable float d = 199.0f + i * 0.05f;
        Vec3 ax; float ang;
        assert(arcballRotation(0, 0, d, 0, ARCBALL_RADIUS_PX, ax, ang));
        immutable float a = deg(ang);
        immutable float e = d >= ARCBALL_RADIUS_PX
                          ? 0.0f : 1.0f - d / ARCBALL_RADIUS_PX;
        // `acos(1-e)` is `sqrt(2e)` times `1 + e/12 + ...`; over this last
        // 1 px of approach that correction is under a tenth of a percent, so
        // one percent of headroom leaves the SHAPE of the bound doing the work.
        assert(90.0f - a <= deg(sqrt(2.0f * e)) * 1.01f + 1e-3f,
               "approaching the rim, the gap to a quarter turn must close like "
               ~ "sqrt of the gap to the rim — the ball's own shape");
        assert(a <= 90.0001f);
        if (prev >= 0) assert(a - prev > -1e-4f,
               "the gesture must never step BACK as the cursor crosses the rim");
        prev = a;
        assert(abs(ax.y - 1.0f) < 1e-5f,
               "and the axis must not jump at the crossing either");
    }
    // Past the rim a press-at-centre drag SATURATES at a quarter turn, whatever
    // its length: the second lifted point can only slide along the rim.
    foreach (d; [200.0f, 260.0f, 900.0f]) {
        Vec3 ax; float ang;
        assert(arcballRotation(0, 0, d, 0, ARCBALL_RADIUS_PX, ax, ang));
        assert(abs(deg(ang) - 90.0f) < 1e-3f);
        assert(abs(ax.y - 1.0f) < 1e-5f);
    }
}

unittest {  // The MIDDLE of the ball — neither limit, and not measured.
    // Between the two limits the law says something the reference was never
    // asked: a press outside the ball with the cursor dragged INSIDE it tilts
    // the axis out of the view plane, continuously. That is a consequence of
    // the one function, not an observation, and it is recorded here as such —
    // an assert that the middle is a genuine blend rather than a snap to one
    // limit or the other, so a future two-branch "simplification" fails here.
    Vec3 ax; float ang;
    assert(arcballRotation(300, 0, 0, 0, ARCBALL_RADIUS_PX, ax, ang));
    // press on the rim at 3 o'clock, cursor at the ball's centre: the lifted
    // points are (1,0,0) and (0,0,1) — a quarter turn about screen DOWN.
    assert(abs(deg(ang) - 90.0f) < 1e-3f);
    assert(abs(ax.x) < 1e-5f && abs(ax.y + 1.0f) < 1e-5f && abs(ax.z) < 1e-5f);

    // and off the drag's own line the axis genuinely TILTS: neither the view
    // axis (which is all a rim-only reading could ever give) nor in the screen
    // plane (which is all a trackball-only reading could ever give).
    assert(arcballRotation(300, 0, 100, 100, ARCBALL_RADIUS_PX, ax, ang));
    assert(abs(ax.y) > 0.5f && abs(ax.y) < 0.95f,
           "the middle of the ball must not collapse onto either limit");
    assert(abs(ax.z) > 0.3f && abs(ax.z) < 0.9f);
    assert(deg(ang) > 55.0f && deg(ang) < 65.0f);
}

unittest {  // The gesture is ABSOLUTE, and scale-free.
    // Absolute: the rotation at any cursor position depends only on the press
    // and that position, never on the path taken. Re-deriving from the press
    // every event is what makes a rotate drag reversible — drag out and back
    // and the model returns to where it started.
    Vec3 a1, a2, a3; float g1, g2, g3;
    assert(arcballRotation(120, -40, 320, -40, ARCBALL_RADIUS_PX, a1, g1));
    assert(arcballRotation(120, -40, 220,  60, ARCBALL_RADIUS_PX, a2, g2));
    assert(arcballRotation(120, -40, 320, -40, ARCBALL_RADIUS_PX, a3, g3));
    assert(g1 == g3 && a1.x == a3.x && a1.y == a3.y && a1.z == a3.z,
           "the same cursor pixel must give the same rotation regardless of "
           ~ "what the pointer did in between");
    // Back to the press = identity, exactly.
    Vec3 a0; float g0;
    assert(!arcballRotation(120, -40, 120, -40, ARCBALL_RADIUS_PX, a0, g0),
           "no displacement is no rotation, and the caller is told so");

    // Scale-free: the ball is drawn in pixels, so the same pixels give the same
    // angle at any camera distance — nothing in this module reads a world
    // length, a depth or a projection.
    Vec3 ax; float ang;
    assert(arcballRotation(0, 0, 100, 0, ARCBALL_RADIUS_PX, ax, ang));
    assert(abs(deg(ang) - 30.0f) < 0.01f);
}

unittest {  // The world mapping, and the direction the model turns.
    import math : lookAt, normalize;
    Viewport vp;
    Vec3 eye = Vec3(0, 0, 5), focus = Vec3(0, 0, 0);
    vp.view = lookAt(eye, focus, Vec3(0, 1, 0));
    // Camera on +Z looking at the origin: screen right = +X, screen up = +Y,
    // out of screen = +Z.
    assert(arcballAxisToWorld(Vec3(1, 0, 0), vp).x > 0.999f);
    assert(arcballAxisToWorld(Vec3(0, 1, 0), vp).y > 0.999f);
    assert(arcballAxisToWorld(Vec3(0, 0, 1), vp).z > 0.999f);

    // A press at the centre dragged RIGHT must turn the face the viewer is
    // looking at TOWARD the right — the model follows the pointer. Take the
    // point nearest the eye and check it moves +x.
    Vec3 ax; float ang;
    assert(arcballRotation(0, 0, 100, 0, ARCBALL_RADIUS_PX, ax, ang));
    Vec3 axisW = arcballAxisToWorld(ax, vp);
    Vec3 p = Vec3(0, 0, 1);                       // on the near face
    import std.math : sin, cos;
    immutable float c = cos(ang), s = sin(ang);
    Vec3 rotated = p * c + cross(axisW, p) * s + axisW * (dot(axisW, p) * (1 - c));
    assert(rotated.x > 0.4f, "a rightward drag must carry the near face right");

    // …and a press OUTSIDE the ball, swept clockwise on screen, must turn the
    // model clockwise on screen: about the axis pointing INTO the screen.
    assert(arcballRotation(300, 0, 300, 300, ARCBALL_RADIUS_PX, ax, ang));
    Vec3 clockwise = arcballAxisToWorld(ax, vp);
    assert(clockwise.z < -0.999f,
           "a clockwise screen sweep turns about the INTO-screen axis");
}
