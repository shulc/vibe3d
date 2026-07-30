module drag;

import std.math : sqrt, isNaN, abs;
import math;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import toolpipe.packets : GesturePacket, GestureTrack;

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
//   LAW B — anchored inverse screen Jacobian. `planeDragDelta`, over the
//     core `planeJacobian` / `PlaneJacobian.apply`. Resolve the drag on the
//     two in-plane world axes of the chosen plane: finite-difference the 2x2
//     screen Jacobian AT THE ANCHOR, invert it, and multiply the pixel
//     offset by the inverse. A pure function of (anchor, plane, viewport), so
//     a caller that holds its press anchor and press pixel fixed gets the
//     same matrix on every event of the gesture — "frozen at the press" is
//     the caller's freeze, not hidden state in here.
//
//   LAW C — anchored pixel scalar.  `haulWorldPerPixel`. One scalar, the
//     world length of a pixel at an anchor, frozen by the caller at the press.
//     For hauls that have no axis to project: the tool multiplies raw pixels
//     by it.
//
// LAW-CHANGE POINT — CONSUMED for LAW B (task 0520), still open for LAW A.
// The seam's original note named `screenAxisWorldDelta` as the one body a
// future task would rewrite. What the measurement actually describes is the
// FREE/plane conversion, and that is what LAW B now is. LAW A is deliberately
// NOT re-pointed at it: on the reference side the axis-handle drag runs the
// same free conversion and then applies its own post-projection arithmetic to
// restrict the result to the handle — and that post-projection step was
// located but never read. Porting LAW A would mean inventing it. LAW A
// therefore keeps its exact per-event axis projection until that term is
// measured, and this comment is the record of why.
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
// THE INPUT PAIR — which two pixels a per-event conversion is measured from
// ===========================================================================

// The previous event's pixel, taken from the cooked gesture rather than from
// the tool's own bookkeeping.
//
// Every incremental drag in this tree used to answer "what was the previous
// pixel?" out of a private `lastMX/lastMY` pair that the tool wrote at the end
// of each motion handler. That is one copy of the same law per tool, and a
// law that lives in fourteen places is a law that lands in one file and not
// its twin. The cooked event already states it once, at the one place a
// gesture's pixel state is known, so a tool reads it instead of keeping it.
//
// `g` is whatever the caller found in its vector stack, and may be null (any
// dispatch that is not a mouse event publishes nothing) or invalid (the
// caller-supplied default). `fallback*` is the tool's own pair, which stays
// alive for exactly those cases — and for the cross-check below.
//
// N3 — COMPUTE BOTH AND ASSERT THEY AGREE. The increment is the same integer
// subtraction either way, so an agreeing pair means the arithmetic downstream
// is byte-identical; the `debug` assert proves that case by case on the
// existing suite instead of asserting it in prose. A disagreement is a real
// finding: it means this tool saw a different sequence of events than the
// dispatcher cooked (an event consumed before it reached the tool, a gesture
// re-anchored mid-drag), and that is a behaviour question, not a hygiene one.
//
// The packet is honoured only when it describes THIS event (`curX/curY`
// match). A caller that hands a stale or foreign packet gets its own pair
// back rather than a silently wrong reference pixel.
void gesturePrevPixel(const(GesturePacket)* g,
                      int curX, int curY,
                      int fallbackX, int fallbackY,
                      out int prevX, out int prevY)
{
    prevX = fallbackX;
    prevY = fallbackY;
    if (g is null || !g.valid) return;
    if (g.curX != curX || g.curY != curY) return;
    debug assert(g.prevX == fallbackX && g.prevY == fallbackY,
        "gesturePrevPixel: the cooked gesture and the tool's own previous "
        ~ "pixel disagree — the tool did not see every event the dispatcher "
        ~ "cooked, which is a behaviour difference, not a conversion detail");
    prevX = g.prevX;
    prevY = g.prevY;
}

unittest {
    // No packet at all → the caller's own pair, untouched.
    int px, py;
    gesturePrevPixel(null, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);

    // Default-constructed (every non-mouse dispatch) → same.
    GesturePacket idle;
    gesturePrevPixel(&idle, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);

    // A valid packet for THIS event → the packet's previous pixel, which the
    // assert has just proven equal to the caller's.
    GestureTrack tr;
    tr.event(GesturePacket.Phase.Down, 12, 34);
    auto mv = tr.event(GesturePacket.Phase.Move, 40, 30);
    gesturePrevPixel(&mv, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);
    assert(40 - px == mv.incrementX() && 30 - py == mv.incrementY());

    // A packet for a DIFFERENT event is not this event's reference.
    gesturePrevPixel(&mv, 41, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);
}

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
// LAW B — anchored inverse screen Jacobian
// ===========================================================================

// The 2x2 linear map from screen pixels to the two in-plane world axes,
// finite-differenced at one anchor and inverted.
//
// `apply` is the whole conversion: `(u, v) = Minv * (dpx, dpy)` and then
// `axisU*u + axisV*v`. Nothing else multiplies it — in particular no
// "world units per pixel" scalar. The gain IS this matrix: local (it is
// evaluated at one anchor), anisotropic (a horizontal drag and a vertical
// drag of the same length are different world lengths) and plane-restricted.
// Any single number quoted as "the" pixel/world ratio for a plane drag is
// this matrix evaluated at one anchor in one direction.
struct PlaneJacobian {
    bool  valid = false;
    Vec3  axisU = Vec3(1, 0, 0);   // first in-plane world axis
    Vec3  axisV = Vec3(0, 1, 0);   // second in-plane world axis
    // Minv, row-major: u = i00*dpx + i01*dpy, v = i10*dpx + i11*dpy
    float i00 = 0, i01 = 0, i10 = 0, i11 = 0;

    Vec3 apply(float dpx, float dpy) const {
        float u = i00 * dpx + i01 * dpy;
        float v = i10 * dpx + i11 * dpy;
        return axisU * u + axisV * v;
    }
}

// The finite-difference step, in world units, for the Jacobian below.
//
// It is ONLY a step. The Jacobian divides the projected difference by the
// same value, so it cancels to first order and the conversion's gain does
// not depend on it (`unittest` below sweeps four decades and pins that).
// It is taken from the view so that it stays a sane fraction of the anchor's
// depth at any camera distance — too small and the projected difference is
// float noise, too large and the perspective curvature over the step leaks
// into the derivative.
private float jacobianStep(Vec3 anchor, const ref Viewport vp) {
    float k = 10.0f * haulWorldPerPixel(anchor, vp);
    if (!(k > 0.0f) || isNaN(k)) return 1e-3f;
    return k;
}

// `projectToWindowFull` in double precision, for the finite difference only.
//
// The difference of two projections a few pixels apart cancels most of the
// mantissa: in float the surviving digits are noise, and the Jacobian then
// depends on the step it is supposed to be independent of. The reference does
// this arithmetic in double, and so does this. Nothing else in the module
// changes precision — the result is handed back as float, exactly like every
// other law here.
private bool projectToWindowD(Vec3 world, const ref Viewport vp,
                              out double px, out double py)
{
    const double x = world.x, y = world.y, z = world.z;
    const double vx = vp.view[0]*x + vp.view[4]*y + vp.view[ 8]*z + vp.view[12];
    const double vy = vp.view[1]*x + vp.view[5]*y + vp.view[ 9]*z + vp.view[13];
    const double vz = vp.view[2]*x + vp.view[6]*y + vp.view[10]*z + vp.view[14];
    const double vw = vp.view[3]*x + vp.view[7]*y + vp.view[11]*z + vp.view[15];
    const double cx = vp.proj[0]*vx + vp.proj[4]*vy + vp.proj[ 8]*vz + vp.proj[12]*vw;
    const double cy = vp.proj[1]*vx + vp.proj[5]*vy + vp.proj[ 9]*vz + vp.proj[13]*vw;
    const double cw = vp.proj[3]*vx + vp.proj[7]*vy + vp.proj[11]*vz + vp.proj[15]*vw;
    if (!(cw > 0.0)) return false;   // rejects NaN and behind-camera, as the float twin does
    px = (cx / cw * 0.5 + 0.5)          * vp.width  + vp.x;
    py = (1.0 - (cy / cw * 0.5 + 0.5))  * vp.height + vp.y;
    return true;
}

// Two in-plane world axes spanning the plane with unit normal `n`.
//
// When `n` is one of the basis axes the pair is the other two, in the
// cyclic order (X,Y,Z) -> normal Z gives (X,Y), normal X gives (Y,Z),
// normal Y gives (Z,X). Otherwise the pair is an orthonormal completion of
// `n` built from the basis axis least aligned with it.
//
// The choice does not change the conversion's result — `Minv` is the matrix
// of one linear map expressed in whatever basis it is handed, so
// `axisU*u + axisV*v` is basis-independent for any two independent spanning
// vectors. It changes only the conditioning of the 2x2 inverse, which is why
// the completion is orthonormal.
private void inPlaneAxes(Vec3 n, Vec3 axisX, Vec3 axisY, Vec3 axisZ,
                         out Vec3 u, out Vec3 v)
{
    enum float PARALLEL = 0.999999f;
    float dx = dot(n, axisX), dy = dot(n, axisY), dz = dot(n, axisZ);
    if (dx * dx > PARALLEL) { u = axisY; v = axisZ; return; }
    if (dy * dy > PARALLEL) { u = axisZ; v = axisX; return; }
    if (dz * dz > PARALLEL) { u = axisX; v = axisY; return; }

    // Arbitrary normal (a caller-supplied plane that is not a basis axis):
    // complete an orthonormal in-plane pair from the least-aligned basis axis.
    Vec3 seed = (dx * dx <= dy * dy && dx * dx <= dz * dz) ? axisX
              : (dy * dy <= dz * dz)                       ? axisY
                                                           : axisZ;
    Vec3 uu = seed - n * dot(seed, n);
    float ul = sqrt(uu.x * uu.x + uu.y * uu.y + uu.z * uu.z);
    if (!(ul > 1e-9f)) { u = axisX; v = axisY; return; }
    u = uu / ul;
    v = cross(n, u);
}

// Finite-difference the screen Jacobian at `anchor` on the plane spanned by
// (`axisU`, `axisV`) and invert it.
//
// PURE — no cached state, no gesture identity. "Frozen at the press" is the
// caller holding `anchor` fixed for the gesture: same anchor and same view
// give a bit-identical matrix on every event, so the freeze is visible in the
// caller's own bookkeeping rather than hidden here.
// `step` overrides the finite-difference step; NaN (the default) derives it
// from the view. It exists so the cancellation can be tested rather than
// asserted — no shipping caller passes it.
PlaneJacobian planeJacobian(Vec3 anchor, Vec3 axisU, Vec3 axisV,
                            const ref Viewport vp, float step = float.nan)
{
    PlaneJacobian j;
    j.axisU = axisU;
    j.axisV = axisV;

    const double k = isNaN(step) ? jacobianStep(anchor, vp) : step;

    double sx, sy, ux, uy, vx, vy;
    if (!projectToWindowD(anchor,                          vp, sx, sy) ||
        !projectToWindowD(anchor + axisU * cast(float)k,   vp, ux, uy) ||
        !projectToWindowD(anchor + axisV * cast(float)k,   vp, vx, vy))
        return j;   // invalid: something is behind the camera

    // M = d(screen px) / d(world along the in-plane axes)
    const double m00 = (ux - sx) / k, m01 = (vx - sx) / k;
    const double m10 = (uy - sy) / k, m11 = (vy - sy) / k;

    const double det = m00 * m11 - m01 * m10;
    if (isNaN(det) || det * det < 1e-24)
        return j;   // invalid: the plane is edge-on, the map is not invertible

    const double inv = 1.0 / det;
    j.i00 = cast(float)( m11 * inv);  j.i01 = cast(float)(-m01 * inv);
    j.i10 = cast(float)(-m10 * inv);  j.i11 = cast(float)( m00 * inv);
    j.valid = true;
    return j;
}

// The direction the free plane pick differences.
//
// MEASURED CORRECTION (task 0518 §4.2): the reference differences the eye
// vector at the VIEW CENTRE — the direction from the eye to the point the view
// calls its centre — not the view matrix's forward row. On the reference's own
// state dumps for the main corpus camera the two are 15.92 degrees apart,
// which is enough to select a different axis whenever the two largest
// components sit inside that cone.
//
// In OUR camera model those two vectors are the same vector: every `Viewport`
// the editor produces has `view == lookAt(eye, focus, up)`, so the forward row
// IS `normalize(focus - eye)` (`view.d::viewportWith`). The correction is
// therefore measured-inert here rather than invisible — see the unittest that
// drives the corpus's own four cameras through both readings. It is written
// this way round so the rule the code states is the measured one, and so a
// viewport that ever stops being a plain look-at does not silently change
// which plane a drag runs in.
//
// Falls back to the forward row when the view carries no usable centre (a
// synthetic `Viewport` with `eye == focus`, which several unittests build).
private Vec3 planePickDirection(const ref Viewport vp) {
    Vec3 d = vp.focus - vp.eye;
    if (dot(d, d) > 1e-12f) return d;   // an argmax does not care about length
    const ref float[16] v2 = vp.view;
    return Vec3(v2[2], v2[6], v2[10]);
}

// Dominant-axis argmax for the free plane pick.
//
// MEASURED CORRECTION (task 0518 §4.3): the reference's tie-break falls to the
// LAST axis; `mostFacingAxis`, which this call site used to use, falls to the
// FIRST. Both tests below are strict, so an exact tie on the leading axis drops
// through to the trailing one. Worked case, a camera on the 45-degree azimuth
// with `dir = (0.707, 0, 0.707)`: `|x| > |z|` is false, so 0 is not returned;
// `|y| >= |x|` is false, so 1 is not returned; the answer is 2 (Z). The
// first-wins chain answers 0 (X) — a different plane on the same camera.
//
// Deliberately NOT applied to `mostFacingAxis` itself. That helper also picks
// the construction plane for every Create tool, and those call sites carry no
// reference measurement; moving their tie-break here would be extrapolation
// beyond what was read, and there would be no reference number to review the
// changed fixtures against.
private int dragPlaneAxis(Vec3 dir, Vec3 a, Vec3 b, Vec3 c) {
    float da = abs(dot(dir, a)), db = abs(dot(dir, b)), dc = abs(dot(dir, c));
    if (da > db && da > dc)  return 0;
    if (db >= da && db > dc) return 1;
    return 2;
}

// Plane drag (dragAxis 3/4/5/6).
//   3 = most-facing plane (normal derived from the view's line of sight)
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
// The conversion is `Minv * (pixel offset)` on the plane's two in-plane
// world axes, with `Minv` finite-differenced at `center` (task 0520). It
// replaced a pair of ray/plane intersections differenced per event.
//
// `(mx - lastMX, my - lastMY)` is the pixel offset the caller hands in. A
// caller that passes its PRESS pixel and its PRESS anchor gets the measured
// law exactly: one matrix for the whole gesture, applied to the cumulative
// offset. A caller that passes the previous event's pixel gets the same total
// for the same total displacement AS LONG AS its anchor is frozen too —
// `Minv` does not depend on the pixels, so summing increments through a fixed
// matrix equals one multiply of the sum. Only a caller whose anchor MOVES
// during the drag re-linearises per event, and that is a residual named in
// each such call site rather than a property of this function.
//
// Kept as its OWN law, not folded into LAW A: LAW A's reference-side
// counterpart adds a post-projection step that was located but never read.
// See the module header's law-change point.
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
        final switch (dragPlaneAxis(planePickDirection(vp), axisX, axisY, axisZ)) {
            case 0: n = axisX; break;
            case 1: n = axisY; break;
            case 2: n = axisZ; break;
        }
    }

    float nl = sqrt(n.x*n.x + n.y*n.y + n.z*n.z);
    if (!(nl > 1e-9f)) { skip = true; return Vec3(0,0,0); }
    n = n / nl;

    Vec3 axisU, axisV;
    inPlaneAxes(n, axisX, axisY, axisZ, axisU, axisV);

    auto j = planeJacobian(center, axisU, axisV, vp);
    if (!j.valid) { skip = true; return Vec3(0,0,0); }

    return j.apply(cast(float)(mx - lastMX), cast(float)(my - lastMY));
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

// ===========================================================================
// LAW B — the ported conversion, pinned (task 0520)
// ===========================================================================
//
// Every assert below is about the LAW, not about a magic number someone liked:
// the step cancels, the map is linear (so the same total displacement gives the
// same world result at any event count), it reduces to the pre-0520 exact
// solve wherever the projection is affine, and it is a stated distance from it
// where the projection is not.
version (unittest) {
    import std.math : PI, sin, cos, tan;

    // The cameras the cross-engine drag corpus actually runs, in our own
    // terms. `az`/`el`/`dist` came out of the corpus harness's own camera
    // conversion, applied to the reference's recorded state for the named
    // case; they are inputs here, not fits.
    private struct Cam { string name; float az, el, dist; int w, h; }

    private immutable Cam[] corpusCams = [
        Cam("real_perspective", -0.159244f, 0.265694f,  1.560178f, 1426, 966),
        Cam("reported_topview",  0.0f,      1.570796f,  0.5f,      1219, 966),
        Cam("far_perspective",  -0.159244f, 0.265694f, 12.559432f, 1426, 966),
        Cam("side_camera",       0.97397f,  0.359541f,  3.142141f, 1227, 966),
    ];

    private Viewport corpusViewport(Cam c, Vec3 focus = Vec3(0, 0, 0)) {
        Vec3 back = Vec3(cos(c.el) * sin(c.az), sin(c.el), cos(c.el) * cos(c.az));
        Vec3 eye  = focus + back * c.dist;
        Viewport vp;
        vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                      cast(float)c.w / c.h, 0.001f, 100.0f);
        vp.width  = c.w;
        vp.height = c.h;
        vp.eye    = eye;
        vp.focus  = focus;
        return vp;
    }

    // The pre-0520 body of `planeDragDelta`'s tail, verbatim: two ray/plane
    // intersections differenced. The oracle the port is measured AGAINST, kept
    // here rather than described.
    private Vec3 exactPlaneDelta(int mx, int my, int lastMX, int lastMY,
                                 Vec3 center, Vec3 n, const ref Viewport vp,
                                 out bool skip)
    {
        skip = false;
        Vec3 origCurr, dirCurr, origPrev, dirPrev;
        screenPointToRay(cast(float)mx,     cast(float)my,     vp, origCurr, dirCurr);
        screenPointToRay(cast(float)lastMX, cast(float)lastMY, vp, origPrev, dirPrev);
        Vec3 hitCurr, hitPrev;
        if (!rayPlaneIntersect(origCurr, dirCurr, center, n, hitCurr) ||
            !rayPlaneIntersect(origPrev, dirPrev, center, n, hitPrev))
        { skip = true; return Vec3(0, 0, 0); }
        return hitCurr - hitPrev;
    }

    private float vlen(Vec3 v) { return sqrt(v.x*v.x + v.y*v.y + v.z*v.z); }
}

unittest {  // LAW B: the finite-difference step is a STEP, not a gain.
    // The matrix divides by the same step it differenced with, so the step
    // cancels to first order and a four-decade sweep of it must move the answer
    // by percent, not by decades. This is the assert that catches a port which
    // has started treating a view pixel scale as the GAIN — the single most
    // likely way to mis-read this law, and the shape of every fitted "1.53x"
    // that circulated before it was read.
    //
    // What is left over is the forward difference's own O(step) bias, which the
    // reference carries too (it differences forward at ten pixels' worth of
    // world, and so do we).
    foreach (c; corpusCams[0 .. 1] ~ corpusCams[2 .. 4]) {
        auto vp = corpusViewport(c);
        Vec3 anchor = Vec3(0.1f, 0.5f, -0.2f);

        auto def = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp);
        assert(def.valid);
        Vec3 want = def.apply(100.0f, 40.0f);
        assert(vlen(want) > 1e-6f);

        foreach (step; [1e-5f, 1e-4f, 1e-3f, 1e-2f, 1e-1f]) {
            auto j = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, step);
            assert(j.valid);
            float err = vlen(j.apply(100.0f, 40.0f) - want) / vlen(want);
            assert(err < 2.5e-2f,
                   "a 10000x change of finite-difference step must not change "
                   ~ "the conversion by more than a couple of percent");
        }

        // …and as the step shrinks the difference quotient must SETTLE on the
        // derivative. It only settles if the projection difference is taken at
        // more than float precision: two pixel values that differ in their last
        // few bits carry no derivative at all, and the quotient then grows like
        // 1/step instead of converging. This is the assert that holds the
        // double-precision finite difference in place.
        auto tiny  = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, 1e-6f);
        auto small = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, 1e-5f);
        assert(tiny.valid && small.valid);
        Vec3 a = tiny.apply(100.0f, 40.0f), b = small.apply(100.0f, 40.0f);
        assert(vlen(a - b) <= 5e-3f * vlen(b),
               "the difference quotient must converge as the step shrinks");
    }
}

unittest {  // LAW B: linear in the pixel offset => invariant in the event count.
    // The harness asserts this across the process boundary (same total
    // displacement at N = 1, 5, 20 must give the same world result). It holds
    // here for the same reason it holds there: the matrix does not depend on
    // the pixels, so summing increments through a frozen matrix equals one
    // multiply of the summed offset.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 anchor = Vec3(0, 0.5f, 0);
    auto j = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp);
    assert(j.valid);

    Vec3 one = j.apply(100.0f, -60.0f);
    foreach (n; [1, 5, 20]) {
        Vec3 acc = Vec3(0, 0, 0);
        foreach (i; 0 .. n)
            acc = acc + j.apply(100.0f / n, -60.0f / n);
        assert(vlen(acc - one) <= 1e-5f * vlen(one),
               "N events of D/N must equal one event of D");
    }
}

unittest {  // LAW B: under an affine projection the port IS the exact solve.
    // Orthographic projection has no perspective divide, so the screen map is
    // affine and its first-order linearisation is exact. Agreement here is what
    // says the change is a LINEARISATION and not a change of gain: no scalar
    // was introduced anywhere.
    Viewport vp;
    Vec3 eye = Vec3(3, 4, 9), focus = Vec3(0, 0, 0);
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = orthographicMatrix(2.0f, 1426.0f / 966.0f, 0.001f, 100.0f);
    vp.width  = 1426; vp.height = 966;
    vp.eye    = eye;  vp.focus  = focus;

    Vec3 center = Vec3(0.1f, 0.2f, -0.3f);
    bool skipNew, skipOld;
    Vec3 got  = planeDragDelta(760, 500, 660, 560, 3, center, vp, skipNew);
    Vec3 want = exactPlaneDelta(760, 500, 660, 560, center,
                                Vec3(0, 0, 1), vp, skipOld);   // Z-dominant view
    assert(!skipNew && !skipOld);
    assert(vlen(got - want) <= 1e-4f * vlen(want),
           "under an affine projection the frozen linearisation must reproduce "
           ~ "the exact ray/plane difference");
}

unittest {  // LAW B: how far the frozen linearisation is from the exact solve.
    // The behaviour a user can feel, stated as a number rather than as "it
    // drifts". Same camera, same anchor, one press, drags of growing length:
    // the frozen matrix is exact at the press and falls behind the exact solve
    // as the cursor leaves the anchor's neighbourhood, because a perspective
    // screen map is not affine.
    auto vp = corpusViewport(corpusCams[2]);       // the corpus far camera
    Vec3 center = Vec3(0, 0.5f, 0);
    Vec3 n = Vec3(0, 0, 1);
    float ax, ay, az;
    assert(projectToWindowFull(center, vp, ax, ay, az));
    int px = cast(int)ax, py = cast(int)ay;        // press ON the anchor

    // Measured on this camera, frozen against exact, dragging horizontally
    // from the anchor's own pixel:
    //     10 px   0.007 %      100 px   1.27 %
    //     50 px   0.56  %      300 px   4.10 %      500 px  6.92 %
    // The frozen matrix is always the SHORTER of the two: the plane recedes as
    // the cursor leaves the anchor, so the exact solve keeps buying more world
    // per pixel while the linearisation keeps the press-time rate.
    struct Row { int dpx; float lo, hi; }
    immutable Row[] rows = [ Row( 10, 0.0f,    0.001f),
                             Row( 50, 0.002f,  0.010f),
                             Row(100, 0.006f,  0.020f),
                             Row(300, 0.025f,  0.060f) ];
    foreach (r; rows) {
        bool s1, s2;
        Vec3 frozen = planeDragDelta(px + r.dpx, py, px, py, 3, center, vp, s1);
        Vec3 exact  = exactPlaneDelta(px + r.dpx, py, px, py, center, n, vp, s2);
        assert(!s1 && !s2);
        float rel = vlen(frozen - exact) / vlen(exact);
        assert(rel >= r.lo && rel <= r.hi,
               "frozen-vs-exact divergence must stay first-order in drag length");
        assert(vlen(frozen) <= vlen(exact) * 1.0005f,
               "the frozen linearisation is the shorter of the two");
    }
}

unittest {  // LAW B: the tie-break falls to the LAST axis.
    // A camera on the 45-degree azimuth: |x| and |z| of the line of sight are
    // equal, |y| is zero. The reference's argmax is strict on both compares and
    // drops through to the trailing axis; the first-wins chain this call site
    // used to run answered X. Same camera, different plane.
    Viewport vp;
    Vec3 eye = Vec3(5, 0, 5), focus = Vec3(0, 0, 0);
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    vp.width  = 800; vp.height = 800;
    vp.eye    = eye; vp.focus = focus;

    assert(dragPlaneAxis(planePickDirection(vp),
                         Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)) == 2,
           "a 45-degree azimuth camera must fall to the last axis");

    // and the drag really does run in the Z-normal plane: no Z component.
    bool skip;
    Vec3 d = planeDragDelta(500, 400, 400, 400, 3, Vec3(0,0,0), vp, skip);
    assert(!skip);
    assert(abs(d.z) <= 1e-6f * (abs(d.x) + abs(d.y) + 1e-6f));
}

unittest {  // LAW B: the eye-vector-at-centre reading, and why it is inert here.
    // The reference reads the direction from the eye to the view's centre; we
    // used to read the view matrix's forward row. In our camera model those are
    // the same vector, and this is the assert that says so on the corpus's own
    // four cameras instead of on a camera chosen to make it true.
    foreach (c; corpusCams) {
        auto vp = corpusViewport(c);
        const ref float[16] v2 = vp.view;
        Vec3 row = Vec3(v2[2], v2[6], v2[10]);
        Vec3 eyeVec = planePickDirection(vp);
        assert(dragPlaneAxis(eyeVec, Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)) ==
               dragPlaneAxis(row,    Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)),
               "eye-vector-at-centre and the forward row must pick the same "
               ~ "plane for a look-at camera");
    }

    // …and the fallback fires for a synthetic viewport that has no centre.
    // Two shapes, because both occur in the tree: `Viewport.eye` has no
    // initialiser, so a hand-built viewport leaves it NaN; and a caller can
    // legitimately place the eye ON the focus.
    foreach (degenerate; 0 .. 2) {
        Viewport bare;
        bare.view   = lookAt(Vec3(0, 0, 5), Vec3(0, 0, 0), Vec3(0, 1, 0));
        bare.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
        bare.width  = 800; bare.height = 800;
        if (degenerate == 1) { bare.eye = Vec3(0, 0, 0); bare.focus = Vec3(0, 0, 0); }
        Vec3 fb = planePickDirection(bare);
        assert(abs(fb.z) > 0.9f, "must fall back to the view's forward row");
        assert(dragPlaneAxis(fb, Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)) == 2);
    }
}

unittest {  // LAW B: the result stays in the plane, whatever the in-plane basis.
    auto vp = corpusViewport(corpusCams[3]);   // side camera, X-dominant
    Vec3 center = Vec3(0.2f, -0.1f, 0.4f);
    bool skip;
    Vec3 d = planeDragDelta(700, 380, 600, 500, 3, center, vp, skip);
    assert(!skip);
    assert(abs(d.x) <= 1e-6f * (vlen(d) + 1e-6f),
           "an X-normal plane drag must have no X component");

    // An arbitrary (non-basis) plane normal handed in by a caller: the result
    // must still lie in that plane, which is what the orthonormal completion
    // in `inPlaneAxes` is for.
    Vec3 oblique = normalize(Vec3(0.3f, 0.6f, 0.74f));
    Vec3 od = planeDragDelta(700, 380, 600, 500, 3, center, vp, skip,
                             Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), oblique);
    assert(!skip);
    assert(abs(dot(od, oblique)) <= 1e-5f * (vlen(od) + 1e-6f),
           "an oblique plane drag must have no component along its normal");
}

unittest {  // LAW B: degenerate views skip instead of exploding.
    // Edge-on: the camera looks along the plane, the 2x2 collapses, and the
    // caller must be told to leave its bookkeeping alone rather than handed a
    // huge or NaN delta. The old law failed the same case on a parallel ray.
    Viewport vp;
    Vec3 eye = Vec3(0, 0, 6), focus = Vec3(0, 0, 0);
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    vp.width  = 800; vp.height = 800;
    vp.eye    = eye; vp.focus = focus;

    bool skip;
    // Force the XZ plane (normal Y) — the camera lies in it.
    Vec3 d = planeDragDelta(500, 400, 400, 400, 6, Vec3(0,0,0), vp, skip);
    assert(skip, "an edge-on plane must skip");
    assert(d == Vec3(0, 0, 0));

    // A zero normal is a caller bug, not a crash.
    Vec3 z = planeDragDelta(500, 400, 400, 400, 3, Vec3(0,0,0), vp, skip,
                            Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                            Vec3(0, 0, 0));
    assert(skip && z == Vec3(0, 0, 0));
}
