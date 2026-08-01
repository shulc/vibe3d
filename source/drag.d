module drag;

import std.math : sqrt, isNaN, abs;
import math;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import toolpipe.packets : GesturePacket, GestureTrack;
import coord_rounding : CoordinateRounding, kFixedIncrementDefault;

// ---------------------------------------------------------------------------
// THE DRAG CONVERSION SEAM
//
// "Where does a screen pixel become a world offset?" has exactly one answer:
// this module. Every interactive drag in the editor — transform gizmos,
// primitive movers, the alignment tools, every parameter haul — routes its
// pixels through one of the three laws below. Nothing outside this module may
// grow a fourth.
//
//   LAW A — axis projection, and it is TWO conversions, because the reference
//     has two. `axisArmDelta` is the ported one (task 0562); it runs for the
//     transform gizmo's three axis arms and nothing else. The editor's own
//     `screenAxisWorldDelta` (the core) and its three entry points
//     `axisDragDelta` (handler), `axisDragDelta` (input-basis) and
//     `screenAxisDelta` keep every OTHER axis handle in the editor. See the
//     LAW-CHANGE POINT below for what separates them and why the boundary is
//     drawn exactly there.
//
//     The editor's own conversion: project the drag axis to screen, dot the
//     pixel delta onto that screen segment, normalise by its SQUARED length,
//     scale by the axis's WORLD length. The gain is `axisLen/|s|` — the arrow
//     tip tracks the cursor at any foreshortening. Recomputed per motion event
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
// LAW-CHANGE POINT — CONSUMED for LAW B (task 0520) and now for LAW A (0562).
//
// RETRACTION, IN PLACE. What stood here said: "on the reference side the
// axis-handle drag runs the same free conversion and then applies its own
// post-projection arithmetic to restrict the result to the handle — and that
// post-projection step was located but never read. Porting LAW A would mean
// inventing it."
//
// **That is wrong, and it is wrong about the mechanism, not about a
// coefficient.** There is no post-projection step. Grabbing an axis arm puts
// the reference's shared drag translator into a different MODE at the press —
// a linear constraint — and the axis conversion is a body of its own that the
// free conversion never enters. The free path was read first, saw that mode
// never engaged in the one recording available, and the note above inferred a
// missing step rather than a missing branch. It is the reason this law read as
// unportable for months, so it is retracted here rather than deleted.
//
// The read (0562, static, `objdump` only — see `axisArmDelta`) is:
//
//     t = round( pixelScale * (Δpx · ŝ) / step ) * step
//
// with `Δpx` the pixel offset FROM THE PRESS, `ŝ` the UNIT screen direction of
// the drag axis taken at the handle base frozen at the press, and `pixelScale`
// the view's ONE scalar pixel size. The whole matrix sandwich around it
// collapses to `newT = T + t·eᵢ`: exactly one position attribute changes, by
// exactly `t`.
//
// Four ways that is not the editor's own conversion, all four ported:
//   1. GAIN. A flat `pixelScale` per projected pixel, with NO foreshortening
//      compensation. `axisLen/|s|` and `pixelScale` agree only when the axis
//      is broadside; ours also blows up as the axis goes edge-on (the gain is
//      `axisLen` per pixel at the 1-px cutoff) where the ported one does not.
//   2. REFERENCE PIXEL. Cumulative from the press, not incremental from the
//      previous event.
//   3. ANCHOR. Against a base frozen at the press, not the live gizmo centre.
//   4. ROUNDING. The reference rounds the SCALAR `t` to a step before it ever
//      becomes a world delta — on the axis coordinate, not on the resulting
//      position. The step is NOT a constant: it is the world length of one
//      screen pixel rounded up onto a 1-2-5 ladder, so it is a staircase in
//      the zoom (`axisDragRoundingStep`), and the whole term sits behind the user
//      setting that selects it (`coord_rounding.d`), whose `None` value makes
//      it the exact identity. Our own element snap is NOT the counterpart and
//      stays where it is: it answers to a different reference service (the
//      guide path) from the one that acts on `t` (the view's own rounding).
//
// SCOPE, and it is narrow on purpose:
//   * ONLY the transform gizmo's three axis arms. That is the one dispatch
//     that was read. Every other axis handle in the editor (primitive movers,
//     bevel/inset/extrude/shift hauls, the falloff and radial rigs) keeps
//     `screenAxisWorldDelta`, because whether the reference's counterpart
//     enters the constrained mode is a per-tool question and none of those
//     tools' handle dispatches has been read.
//   * NOT under the `Screen` action centre — and that is a HOLD, not a match.
//     `actr.screen` publishes a SECOND object over the translator slot,
//     but that object's `GetNewPosition` is a DECORATOR, not a replacement
//     conversion: it forwards to the inner translator — this same law — and
//     then adds a file-scope hit-handle triple to every component, re-latched
//     whenever the part number changes. So under `Screen` the reference is
//     neither this law nor the editor's own compensated one; it is this law
//     plus a term nobody has read. Rather than ship half of it, the `Screen`
//     path is HELD at its pre-port behaviour. That is a known divergence
//     parked at a known value, not a specification of what `Screen` should do.
//     Scoped out at the call site, not here.
//
// CONFIRMED BY EXECUTION, and the counts are what makes it a confirmation.
// The read was static when it shipped; a recording made for it since has
// pressed the arms — parts 100 / 101 / 102, six presses in leg order, 30
// conversion evaluations, plus a free-centre press on the same recording as
// the negative control.
//   * `t / (Δpx · ŝ)` is BIT-CONSTANT across all 30 and equals the view's own
//     reported pixel size to the last printed digit, over a 1.368x
//     foreshortening range. The gain is flat, measured. The competing model —
//     a 3D ray intersected against the axis line — mispredicts the worst arm
//     by 36.8 % and is refuted.
//   * `newT − T` has exactly one non-zero component on 12 of 12 axis-arm
//     hits, and it equals `t`. The free control, same recording, same pixel
//     delta, has two. The matrix sandwich really does collapse.
//   * the reference's view rounding is NOT the identity: 30 of 30 evaluations
//     rounded `t` to a step. That is the one prediction the read got wrong,
//     and the term is ported below rather than dropped.
//   * and the step is NOT the 0.002 that first shipped here. A second read
//     took the law itself off the same trace and off a second one already on
//     disk: it is the world length of one screen pixel rounded up onto a
//     1-2-5 ladder, scored on 29 rows across 18 zoom levels spanning 1024x,
//     29 match. 0.002 is its value at ONE of those eighteen. The staircase is
//     the refutation of the constant: two view scales 1.414x apart share a
//     step, which no scaling law can produce.
// Still NOT settled by those recordings, so still decoded rather than
// observed: whether the arming base is the action centre alone or the action
// centre plus the tool's own position triple (the rig carried a zero triple),
// and whether the axis is a column of the tool axis matrix or the world basis
// (the rig's tool axis was the identity).
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

// ---------------------------------------------------------------------------
// LAW A, the PORTED body — the transform gizmo's axis arm (task 0562)
// ---------------------------------------------------------------------------

// The view's ONE scalar pixel size — the whole gain of the ported conversion.
//
// NAMED `viewWorldPerPixel`, not `viewPixelScale`, on purpose. `constraint.d`
// already exports a `viewPixelScale`, it is documented there as explicitly NOT
// a port, it returns a dimensionless 1.0, and it means the OPPOSITE thing: a
// device-pixel ratio between two PIXEL spaces. This one is a world length per
// pixel and it is the gain of a drag. Two functions with one name and opposite
// meanings in one build is a trap for whoever imports both next.
//
// Distinct also from LAW C's `haulWorldPerPixel` below, which is likewise a
// world length per pixel but is ANCHORED — it varies with the depth of the
// point being hauled. This one carries no anchor at all; it is a property of
// the view and nothing else, which is exactly the property the measurement
// below confirms.
//
// The reference reads this off the view as a single number that does not
// depend on the anchor, on the axis, or on the drag. It is a stored view state
// variable there (the reciprocal of the view's "scale"), which our camera has
// no field for; what it can be expressed in is the two quantities the
// reference's own perspective initialiser derives FROM it, and that is what
// this computes.
//
// The relation, read (not fitted) from two literals eleven instructions apart
// in that initialiser: the eye distance is `500·Z / scale` and the focal
// length in pixels is `400·Z`, for the same `Z`. Eliminating `Z` and `scale`:
//
//     pixelScale = (400/500) · eyeDistance / focalPx        [perspective]
//     pixelScale =             1           / focalPx        [orthographic]
//
// The 4/5 is not a correction of ours and not a fit. It is the reference's own
// ratio between the pixel size it reports and the pixel size its perspective
// projection actually uses, and it is exactly 1 in an orthographic view
// because there the same field IS the projection's scale. Consequence, and it
// is the user-visible half: a perspective axis drag moves 0.8x as far as a
// cursor-locked one would at the pivot's depth.
//
// CONFIRMED ON REFERENCE DATA, offline. Two captured cameras report
// `distance / pixelSize` = 1255.9432 to ten digits — a constant, because it is
// `500·Z` with the default zoom decade and carries no camera at all. The
// unittest below drives one of those two camera rows through this function and
// scores the answer against the pixel size the reference itself reported. That
// is the only term of the ported law with a reference number behind it.
//
// `focalPx` is the VERTICAL focal length, which is also the convention the
// cross-engine pane pin uses to make one of our pixels subtend one of theirs.
float viewWorldPerPixel(const ref Viewport vp) {
    // Pixels per world unit at unit depth: proj[5] is 1/tan(fovY/2) for a
    // perspective projection and 2/(top-bottom) for an orthographic one, and
    // half the pane height converts the NDC half-extent into pixels.
    const float focalPx = 0.5f * vp.height * vp.proj[5];
    if (!(focalPx > 1e-9f) || isNaN(focalPx)) return 0.0f;

    // proj[15] is the projection discriminator: 0 = perspective, 1 = ortho.
    if (vp.proj[15] != 0.0f) return 1.0f / focalPx;

    Vec3 d = vp.eye - vp.focus;
    float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    if (!(dist > 1e-9f) || isNaN(dist)) return 0.0f;
    return 0.8f * dist / focalPx;
}

// ---------------------------------------------------------------------------
// The rounding step — a LADDER, not a constant
// ---------------------------------------------------------------------------

// The mantissa ladder the reference rounds its view steps onto: 1, 2, 5, 10,
// scaled by a power of ten. `10` is in the list on purpose and is not
// redundant with `1` of the next decade — it is what makes the ladder closed
// under x10, which in turn is what makes the `log10 / floor` split below
// insensitive to whether an exact power of ten lands just under or just over
// its own decade boundary. Both spellings give the same answer.
//
// (The reference reaches this list through a 3-bit mask over a wider table —
// bit 0 admits 2, bit 1 admits 2.5, bit 2 admits 5 — whose shipped value
// selects exactly {1, 2, 5, 10}. Nothing in this campaign has run under any
// other mask, so the mask is NOT a setting here; it is this list.)
private static immutable double[4] kStepLadder = [1.0, 2.0, 5.0, 10.0];

// `x` rounded UP onto the ladder: the smallest `m * 10^n` with `m` in the
// ladder that is at or above `|x|`, signed like `x`.
//
// The reference does this in LOG space — `e = floor(log10|x|)`, then pick the
// first ladder entry whose own log10 is at or above the fraction — and the
// spelling is preserved because the comparison it makes is between logs, not
// between values. Comparing values directly is the same answer everywhere the
// two agree and a different one where floating-point splits them.
double stepLadderCeil(double x) {
    return stepLadder(x, /*roundUp=*/true);
}

// `x` rounded to the NEAREST ladder entry, the nearness measured in log space
// (so 3 sits nearer 2 than 5, which is not what a linear comparison says).
// Only the `Normal` arm uses this; `Fine`, the default, rounds up.
double stepLadderNearest(double x) {
    return stepLadder(x, /*roundUp=*/false);
}

private double stepLadder(double x, bool roundUp) {
    import std.math : log10, floor, isNaN, isInfinity, abs;

    if (isNaN(x) || isInfinity(x)) return 0.0;
    if (x == 0.0) return 0.0;

    const double sign = x < 0 ? -1.0 : 1.0;
    const double ax   = abs(x);

    const double L    = log10(ax);
    const double e    = floor(L);
    const double frac = L - e;

    // The ladder's logs. `1` gives 0 and `10` gives 1, so with `frac` in
    // [0, 1) BOTH candidates always exist and neither search can come up
    // empty — the reference's own -1 sentinels are unreachable on this
    // ladder, and this loop reproduces that rather than relying on it.
    size_t down = 0, up = kStepLadder.length - 1;
    bool haveDown = false, haveUp = false;
    foreach (i, m; kStepLadder) {
        const double ml = log10(m);
        if (ml <= frac) { down = i; haveDown = true; }
        if (!haveUp && ml >= frac) { up = i; haveUp = true; }
    }
    if (!haveDown) down = up;
    if (!haveUp)   up   = down;

    size_t j = up;
    if (!roundUp) {
        const double dl = frac - log10(kStepLadder[down]);
        const double ul = log10(kStepLadder[up]) - frac;
        j = (dl <= ul) ? down : up;
    }

    return sign * (10.0 ^^ e) * kStepLadder[j];
}

// The view's GRID SIZE — the world length of the drawn grid's major cell.
//
// DERIVED LOCALLY, ON PURPOSE, and this is the note whoever merges the grid
// lane should read first. The reference computes this once per view and caches
// it beside the sub-step; we have no such cache, and a sibling lane is
// building the drawn grid off the same law. Rather than reach into that lane's
// state (or pre-empt where it decides to keep it), this recomputes it here
// from `viewWorldPerPixel` — the one quantity both derivations share. The two
// are the SAME formula and are meant to be reconciled into one owner at merge;
// until then this is three lines of arithmetic with no state, so a divergence
// between them is a code difference and not a stale-cache bug.
//
// `25 * pixelSize` is the reference's own constant: the major cell is the
// nice-number ceiling of 25 screen pixels' worth of world.
double majorGridStep(double pixelSize) {
    if (!(pixelSize > 0)) return 0.0;
    return stepLadderCeil(25.0 * pixelSize);
}

// THE ROUNDING STEP, per arm. This is the whole of what "Coordinate Rounding"
// selects; `snapAxisScalar` below is the one line that applies it.
//
// Measured for the default arm — `Fine` — over a 1024x zoom range: the step is
// `stepLadderCeil(1 * pixelSize)`, the world length of ONE screen pixel rounded
// up onto the ladder, and it reproduced 29 of 29 rows with no free parameter.
// It is a STAIRCASE, not a scaling: two view scales 1.414x apart share one
// step (0.005 spans a whole band), and the value jumps between bands. A
// measurement taken at one zoom cannot tell that from a constant, which is
// exactly how a constant got shipped here in the first place.
//
// The arms, and what each rests on:
//   None         0 -> the identity, exactly. Not a small step: `snapAxisScalar`
//                gates on `step > 0` and returns its input untouched.
//   Normal       decoded, and confirmed by one live row (a view carrying
//                scale 100 / grid 0.5 / step 0.05, and
//                `stepLadderNearest(0.5/10) = 0.05`).
//   Fine         MEASURED, 29/29 over 1024x. The shipped default.
//   Fixed        THE ONE INFERRED ARM. Two independent decodes summarise it
//                differently — "as Normal, floored by the increment" and a
//                longer form with a `< 12` multiple test — and no capture has
//                ever run under it. What is implemented is the reading both
//                summaries AND the shipped help text agree on: the increment
//                is a LOWER LIMIT on the step, and where the step is a small
//                number of increments across it is aligned to a whole
//                multiple of one. Flagged here rather than presented as
//                measured; it is a non-default arm and it is the first thing
//                to re-read if it ever matters.
//   ForcedFixed  decoded, and the two decodes agree exactly: the increment,
//                and nothing else, at any zoom.
//
// Returns 0 (i.e. the identity) for a non-positive or non-finite pixel size,
// so a degenerate view rounds nothing rather than rounding to garbage.
double axisDragRoundingStep(CoordinateRounding mode, double pixelSize,
                       double fixedIncrement)
{
    import std.math : isNaN, isInfinity, round, abs;

    if (isNaN(pixelSize) || isInfinity(pixelSize) || !(pixelSize > 0))
        return 0.0;

    final switch (mode) {
        case CoordinateRounding.None:
            return 0.0;

        case CoordinateRounding.Normal:
            return stepLadderNearest(majorGridStep(pixelSize) / 10.0);

        case CoordinateRounding.Fine:
            return stepLadderCeil(pixelSize);

        case CoordinateRounding.Fixed: {
            double s = stepLadderNearest(majorGridStep(pixelSize) / 10.0);
            const double d = fixedIncrement;
            if (!(d > 0) || isNaN(d) || isInfinity(d)) return s;
            if (d > s) return d;                       // the increment is a FLOOR
            const double n = round(s / d);
            if (n < 12.0) s = (n < 1.0 ? 1.0 : n) * d; // align to a whole multiple
            return s;
        }

        case CoordinateRounding.ForcedFixed:
            return (fixedIncrement > 0 && !isNaN(fixedIncrement)
                    && !isInfinity(fixedIncrement)) ? fixedIncrement : 0.0;
    }
}

// The rounding, applied where the reference applies it: to the SCALAR `t`,
// before it is multiplied by the axis direction. Quantising the resulting
// world POSITION instead would put the steps on the wrong three numbers — the
// staircase lands on the axis coordinate, and on nothing else.
//
// `step <= 0` IS THE ONLY GATE ON THIS PATH. There is no second condition
// anywhere between the pixel delta and the mesh write, and no fallback
// constant: an unset, zero or negative step means the identity. That is what
// makes `Coordinate Rounding = None` an exact no-op rather than a fine grid.
//
// The tie rule is ROUND HALF AWAY FROM ZERO, and it is not a free choice.
// `t` is routinely negative on an axis drag — every arm dragged backwards
// produces one — and `floor(x + 0.5)` rounds -33.5 to -33 where the reference
// rounds it to -34. The reference's own six (before, after) pairs pin the
// positive half (two of them round in OPPOSITE directions from nearly the same
// step count, which rules out floor, ceiling and truncation); the negative
// half follows from the rule being odd, which the unittest below pins
// separately because a gesture dragged out and back must cancel exactly.
//
// Separated from the conversion so a test can pin the rounding against those
// six pairs without going anywhere near a camera.
float snapAxisScalar(float t, float step) pure nothrow @nogc @safe {
    import std.math : round;
    if (isNaN(t)) return t;
    if (!(step > 0.0f) || isNaN(step)) return t;
    const double q = cast(double)step;
    return cast(float)(q * round(cast(double)t / q));
}

// The ported conversion BEFORE the quantum — the gain, and nothing else.
//
// This is the body every measurement of the law is made against, and it is
// public for exactly that reason. The reference's three legs delivered
// GEOMETRY that differed by ~3 % between axes while the underlying `t` was
// bit-constant: the difference was entirely the snap landing on a different
// step. Anyone testing the gain from a moved vertex is measuring the grid.
// Test the pre-snap scalar; that is what this entry point is for.
//
// See `axisArmDelta` for the arguments and the arithmetic — this is that
// function with the last line removed.
float axisArmDeltaUnsnapped(int mx,     int my,
                            int pressMX, int pressMY,
                            Vec3 base, Vec3 axisDir,
                            const ref Viewport vp,
                            out bool skip)
{
    skip = false;

    const float ps = viewWorldPerPixel(vp);
    if (!(ps > 0.0f)) { skip = true; return 0.0f; }

    const double k = 10.0 * ps;
    double bx, by, tx, ty;
    if (!projectToWindowD(base,                                vp, bx, by) ||
        !projectToWindowD(base + axisDir * cast(float)k,       vp, tx, ty))
    { skip = true; return 0.0f; }

    const double dsx = tx - bx, dsy = ty - by;
    const double slen = sqrt(dsx*dsx + dsy*dsy);
    const double r    = slen > 0.0 ? 1.0 / slen : 1.0;

    const double dpx = cast(double)(mx - pressMX);
    const double dpy = cast(double)(my - pressMY);
    return cast(float)(ps * (dpx*dsx + dpy*dsy) * r);
}

// The ported conversion, returning `t` — the SCALAR, because that is what the
// reference's arithmetic collapses to.
//
// The reference's axis arm arms a linear constraint at the press (point =
// the handle's world origin, vector = the drag axis) and then, per motion
// event, runs:
//
//     k  = 10 · pixelScale                       ; a finite-difference STEP
//     dS = toScreen(base + axis·k) − toScreen(base)
//     r  = |dS| > 0 ? 1/|dS| : 1
//     t  = 0.1 · k · (Δpx · dS) · r              ; and 0.1·k ≡ pixelScale
//     t  = viewSnap(t)                           ; round to the nearest 0.002
//
// so `k` cancels out of the gain exactly as it does on the free/plane path,
// and what is left is `pixelScale · (Δpx · ŝ)`. `k` survives only as the step
// the screen direction is differenced over, which is why it is kept at the
// reference's own `10 · pixelScale` rather than replaced by something tidier:
// at a big enough step the perspective curvature over it would tilt `ŝ`.
//
// `Δpx` is measured from the PRESS and `base` is the handle origin AT the
// press, both the caller's business — this function is pure, exactly like
// `planeJacobian`, so the freeze is visible in the caller's own bookkeeping
// instead of hidden here. A caller that hands it the previous event's pixel
// and a live centre gets the old incremental behaviour back under a new name.
//
// Returns 0 with `skip = true` only when the base or the stepped point will
// not project. A degenerate `|dS|` is NOT a skip: the reference's `r = 1`
// fallback is reproduced verbatim, and it yields `t = 0` for an axis pointing
// straight down the view ray.
//
// The ROUNDING is applied here, on the cumulative `t`, which is the only place
// it can go without drifting. Because `Δpx` is measured from the press, the
// snapped total is a pure function of the current pixel: a caller delivering
// `total − alreadyApplied` emits increments that are exact multiples of the
// step and that telescope back to zero at the press pixel, however the
// gesture was cut into events. Snapping a per-event increment instead would
// round the same drag differently depending on the event rate, and snapping
// the resulting POSITION would put the steps on the wrong numbers.
//
// `rounding` and `fixedIncrement` are the live user setting, passed in rather
// than read from a global so this stays pure — the same stance as the frozen
// base and the press pixel. They are LIVE, not frozen at the press: the
// reference re-derives its step on every zoom, so a drag that zooms changes
// step mid-gesture, and a drag under `None` rounds nothing at all.
float axisArmDelta(int mx,     int my,
                   int pressMX, int pressMY,
                   Vec3 base, Vec3 axisDir,
                   const ref Viewport vp,
                   out bool skip,
                   CoordinateRounding rounding,
                   float fixedIncrement)
{
    const float raw = axisArmDeltaUnsnapped(mx, my, pressMX, pressMY,
                                            base, axisDir, vp, skip);
    if (skip) return 0.0f;
    const float step = cast(float)axisDragRoundingStep(rounding,
                                                  viewWorldPerPixel(vp),
                                                  fixedIncrement);
    return snapAxisScalar(raw, step);
}

// ---------------------------------------------------------------------------
// LAW A, ported — the pins
// ---------------------------------------------------------------------------

version (unittest) {
    // The two reference cameras of the pixel-size read, verbatim: each row is
    // the eye distance and the pixel size the REFERENCE ITSELF reported for
    // that view. They come from two different lanes, two panes and two camera
    // orientations, and neither was taken for this port.
    private struct RefCam { string name; double distance, pixelSize; }
    private immutable RefCam[] refPixelCams = [
        RefCam("corpus drag camera",  1.4863233322541896, 0.001183431952662722),
        RefCam("ray lane camera",     1.6598368490151412, 0.0013215859030837  ),
    ];

    // The cross-engine pane pin, and the real number it rounds. The pin exists
    // so one of our pixels subtends one of the reference's; it is
    // `2·tan(fovY/2)·f_ref` with `f_ref = 400·10^0.4`, which is 832.36598 and
    // ships as the integer 832. Everything downstream of the pin scales with
    // 1/height, so that rounding is the ONLY residual the test below tolerates.
    private enum int    PINNED_PANE_W = 1098;
    private enum int    PINNED_PANE_H = 832;

    // The reference's OWN snap rows, verbatim: `t` read immediately before its
    // view rounding and immediately after, on the recording that first
    // executed the axis arms. Six distinct pre-snap values — three axes x two
    // drag lengths — and the six answers the engine gave.
    //
    // These are not derived from our step; the step was derived from THEM.
    // Row 2 and row 4 are the pair that matters most: 33.61 steps and
    // 33.40 steps, which round in opposite directions, so a floor or a ceiling
    // or a truncation reproduces at most one of the two.
    private struct RefSnap { double before, after; }
    private immutable RefSnap[] refSnapRows = [
        RefSnap(0.033611330530568473, 0.034),   // 16.8057 steps -> 17
        RefSnap(0.067222661061136946, 0.068),   // 33.6113 steps -> 34
        RefSnap(0.033404502316750892, 0.034),   // 16.7023 steps -> 17
        RefSnap(0.066809004633501784, 0.066),   // 33.4045 steps -> 33
        RefSnap(0.032694010160137447, 0.032),   // 16.3470 steps -> 16
        RefSnap(0.065655147863375493, 0.066),   // 32.8276 steps -> 33
    ];

    // The view scale that recording ran at, read off the view as a field on
    // all thirty evaluations, bit-identical every time. The step the six rows
    // above were rounded to is NOT written down here — it is DERIVED from
    // this number by the law under test, which is what turns those six rows
    // from a pin on a constant into a pin on the formula.
    private enum double REF_SNAP_SCALE = 601.66119999999989;

    // THE STAIRCASE, verbatim: 18 distinct zoom levels off a trace recorded
    // for an unrelated purpose, spanning 26.4 to 27040 pixels per world unit —
    // a factor of 1024. Each row is the view's scale and the rounding step the
    // view carried at that scale. `pixelSize` is `1 / scale`.
    //
    // These rows are the whole reason the step cannot be a constant, and they
    // are also why it cannot be a scaling: 298.75 and 422.50 differ by 1.414x
    // and share 0.005; 105.63 and 149.38 share 0.01; 2390, 3380 and 4780 all
    // share 0.0005. A law continuous in the zoom cannot produce a plateau.
    private struct RefStep { double scale, step; }
    private immutable RefStep[] refStepRows = [
        RefStep(   26.41, 0.05   ),
        RefStep(   52.81, 0.02   ),
        RefStep(  105.63, 0.01   ),
        RefStep(  149.38, 0.01   ),
        RefStep(  211.25, 0.005  ),
        RefStep(  298.75, 0.005  ),
        RefStep(  422.50, 0.005  ),
        RefStep(  597.51, 0.002  ),
        RefStep(  845.00, 0.002  ),
        RefStep( 1195.01, 0.001  ),
        RefStep( 1690.00, 0.001  ),
        RefStep( 2390.02, 0.0005 ),
        RefStep( 3380.00, 0.0005 ),
        RefStep( 4780.04, 0.0005 ),
        RefStep( 6760.00, 0.0002 ),
        RefStep( 9560.08, 0.0002 ),
        RefStep(13520.00, 0.0001 ),
        RefStep(19120.20, 0.0001 ),
        RefStep(27040.00, 0.00005),
    ];
}

unittest {  // LAW A ported: the gain IS the reference's own reported pixel size.
    import std.math : PI, tan, abs;

    // Our pinned pane, our hard-coded 45-degree vertical fov.
    Viewport vp;
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                  cast(float)PINNED_PANE_W / PINNED_PANE_H,
                                  0.001f, 100.0f);
    vp.width  = PINNED_PANE_W;
    vp.height = PINNED_PANE_H;

    const double exactPin = 2.0 * tan(22.5 * PI / 180.0) * 400.0 * (10.0 ^^ 0.4);
    const double pinRound = exactPin / PINNED_PANE_H;   // 1.000439833...

    double[] ratios;
    foreach (c; refPixelCams) {
        // Only the eye DISTANCE goes in; the reference's pixel size is what
        // comes out and is never handed to the function.
        vp.eye   = Vec3(0, 0, cast(float)c.distance);
        vp.focus = Vec3(0, 0, 0);
        const double got = viewWorldPerPixel(vp);
        assert(got > 0);
        ratios ~= got / c.pixelSize;
    }

    // Each camera on its own: the port reproduces the number the reference
    // reported, up to the integer pane pin and nothing else.
    foreach (i, r; ratios)
        assert(abs(r - pinRound) < 1e-5 * pinRound,
               "viewWorldPerPixel must reproduce the reference's OWN reported "
               ~ "pixel size for " ~ refPixelCams[i].name
               ~ " up to the pane pin's integer rounding — the 4/5 is the "
               ~ "engine's ratio between the pixel size it reports and the "
               ~ "one its perspective projection uses, not a fitted constant");

    // And the two cameras agree with each other. Two distances, two panes,
    // two lanes, one ratio: the quantity carries no camera, which is exactly
    // why it can be expressed as `(4/5)·distance/focal` at all.
    // (1e-6 is float32's own headroom on a single multiply-divide, not slack:
    // the two ratios agree to 15 digits when the arithmetic is done in double.)
    assert(abs(ratios[0] - ratios[1]) < 1e-6 * ratios[0],
           "two independent reference cameras must give the SAME ratio — a "
           ~ "difference means the gain has picked up a camera term it does "
           ~ "not have");
}

unittest {  // LAW A ported: NO foreshortening compensation. The headline.
    import std.math : PI, cos, abs;

    auto vp = corpusViewport(corpusCams[0]);
    // Base at the view focus, so it projects to the pane centre and a world
    // step along the view's own `right` projects to EXACTLY +screen-x — which
    // makes the screen direction of every axis below the same direction, and
    // the only thing that varies the axis's foreshortening.
    Vec3 base = vp.focus;
    const ref float[16] v = vp.view;
    Vec3 right = Vec3(v[0], v[4], v[8]);
    Vec3 back  = Vec3(v[2], v[6], v[10]);

    const float ps    = viewWorldPerPixel(vp);
    const int   pxRun = 100;
    const float wantT = ps * pxRun;

    float flat0 = 0, flatDeep = 0;
    foreach (deg; [0.0f, 30.0f, 60.0f, 75.0f]) {
        const float phi = deg * PI / 180.0f;
        Vec3 axis = right * cos(phi) + back * sin(phi);   // unit, tilts into depth

        // The PRE-SNAP scalar, deliberately. The quantum is 0.002 and this
        // run delivers ~0.24, so a half-quantum is 0.4 % — four times the
        // tolerance the gain is worth pinning to, and it varies per axis
        // because it depends on where each `t` falls between steps. Reading
        // the snapped value here would measure the grid and call it the gain,
        // which is exactly the mistake the reference's own three legs invite:
        // their GEOMETRY differed by 3 % between axes while `t` was
        // bit-constant. `axisArmDelta` is pinned against this body separately.
        bool skip;
        float t = axisArmDeltaUnsnapped(600 + pxRun, 400, 600, 400,
                                        base, axis, vp, skip);
        assert(!skip);
        assert(abs(t - wantT) < 1e-3f * wantT,
               "the ported gain is a FLAT pixel scale: the same pixel run "
               ~ "along an axis's screen direction must give the same world "
               ~ "length however foreshortened that axis is. A 1/cos here "
               ~ "means the foreshortening compensation crept back in.");

        // The editor's own conversion on the same input, for contrast: its
        // gain is `axisLen/|s|`, and `|s|` shrinks with the foreshortening.
        // Straight into the core, in the handler entry's shape (unit
        // direction + an arrow length), so the comparison is against the law
        // and not against one entry point's non-unit-axis convention.
        const float armLen = 0.01f * corpusCams[0].dist;
        bool skipB;
        Vec3 d = screenAxisWorldDelta(600 + pxRun, 400, 600, 400,
                                      base, base + axis * armLen,
                                      axis, armLen, vp, skipB);
        assert(!skipB);
        float dl = vlen(d);
        if (deg == 0.0f)  flat0    = dl;
        if (deg == 75.0f) flatDeep = dl;
    }

    // The two laws are not the same law, and the amount they differ by is the
    // foreshortening. 1/cos(75deg) = 3.86.
    assert(flatDeep > 3.5f * flat0,
           "the editor's own axis conversion must still be the compensated "
           ~ "one — if it stopped growing with the foreshortening, the port "
           ~ "has leaked out of its scope into every other axis handle");

    // Broadside, at the pivot's own depth, the two differ by exactly the 5/4
    // the pixel-size read names: a perspective axis drag moves 0.8x as far as
    // a cursor-locked one. This is the user-visible half of the port.
    assert(abs(flat0 / wantT - 1.25f) < 0.01f * 1.25f,
           "broadside, the ported conversion must be exactly 4/5 of the "
           ~ "cursor-locked one");
}

unittest {  // LAW A ported: orthographic views carry NO 4/5.
    import std.math : PI, tan, abs;

    // The editor's own axis-view preset recipe (view.d): halfH = d*tan(PI/8).
    const float d = 3.0f, halfH = d * tan(cast(float)(PI / 8.0));
    Viewport vp;
    vp.view   = lookAt(Vec3(0, d, 0), Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = orthographicMatrix(halfH, 1098.0f / 832.0f, 0.001f, 100.0f);
    vp.width  = 1098; vp.height = 832;
    vp.eye    = Vec3(0, d, 0); vp.focus = Vec3(0, 0, 0);

    const float want = 2.0f * halfH / 832.0f;    // world units per pixel, exactly
    assert(abs(viewWorldPerPixel(vp) - want) < 1e-6f * want,
           "in an orthographic view the reference's reported pixel size IS "
           ~ "the projection's scale — the 4/5 is a perspective-only ratio "
           ~ "and applying it here would slow every axis-view drag by 20%");
}

unittest {  // LAW A ported: measured from the press, and linear in the offset.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    bool skip;

    // At the press pixel the conversion is exactly zero, so a gesture that
    // returns to where it started has delivered nothing. That is what the
    // cumulative form buys over the incremental one, and it holds for any
    // path in between because the answer depends only on the current pixel.
    // True of the SHIPPED (rounded) entry point as well as the raw one — the
    // rounding must not turn "back where I pressed" into half a step of
    // drift — and true under EVERY arm of the setting, because zero rounds to
    // zero on any step and `None` does not round at all.
    assert(axisArmDeltaUnsnapped(731, 402, 731, 402, base, axis, vp, skip) == 0.0f);
    assert(!skip);
    foreach (m; [CoordinateRounding.None,  CoordinateRounding.Normal,
                 CoordinateRounding.Fine,  CoordinateRounding.Fixed,
                 CoordinateRounding.ForcedFixed]) {
        assert(axisArmDelta(731, 402, 731, 402, base, axis, vp, skip,
                            m, kFixedIncrementDefault) == 0.0f);
        assert(!skip);
    }

    // Linearity is a property of the GAIN, so it is measured pre-snap. The
    // shipped scalar is a staircase on top of this line and cannot be linear
    // by construction; asserting linearity on it would only be asserting that
    // the rounding is absent.
    const float one = axisArmDeltaUnsnapped(731 + 120, 402 - 60, 731, 402,
                                            base, axis, vp, skip);
    assert(!skip && one != 0.0f);

    // LINEAR in the pixel offset, in BOTH components. That is what makes the
    // cumulative form safe to deliver as a difference of running totals: the
    // increments a call site emits sum to the one-shot total whatever the
    // event count, because there is no per-event term to accumulate.
    import std.math : abs;
    foreach (f; [0.5f, 2.0f, -1.0f]) {
        const float scaled = axisArmDeltaUnsnapped(731 + cast(int)(120 * f),
                                                   402 + cast(int)(-60 * f),
                                                   731, 402, base, axis, vp, skip);
        assert(!skip);
        assert(abs(scaled - f * one) <= 1e-4f * abs(one),
               "the conversion must be linear in the pixel offset from the "
               ~ "press — a non-linear term makes a delivered increment "
               ~ "depend on how the drag was cut into events");
    }

    // Separately in y, which the flat-gain test above cannot see: it drives a
    // purely horizontal run.
    const float vert  = axisArmDeltaUnsnapped(731, 402 - 60,  731, 402,
                                              base, axis, vp, skip);
    const float vert2 = axisArmDeltaUnsnapped(731, 402 - 120, 731, 402,
                                              base, axis, vp, skip);
    assert(!skip);
    assert(abs(vert2 - 2.0f * vert) <= 1e-4f * abs(vert2),
           "the vertical pixel component must enter linearly too");
}

unittest {  // LAW A ported: THE STAIRCASE, scored on 19 reference rows.
    import std.math : abs;
    import std.conv : to;
    import std.format : format;

    // 1. The law, row by row, over a 1024x zoom range, with no free
    //    parameter: the step is the nice-number ceiling of ONE pixel's worth
    //    of world. `scale` is the reference's own, `step` is what its view
    //    carried at that scale, and only `1/scale` is handed to the function.
    foreach (i, row; refStepRows) {
        const double got = axisDragRoundingStep(CoordinateRounding.Fine,
                                           1.0 / row.scale,
                                           kFixedIncrementDefault);
        assert(abs(got - row.step) <= 1e-12 * row.step,
               format("the rounding step must be stepLadderCeil(pixelSize) at "
                    ~ "every zoom: row %d, scale %.2f (pixelSize %.9g) wants "
                    ~ "%.9g, got %.9g. A constant reproduces at most one of "
                    ~ "these nineteen rows.",
                    i, row.scale, 1.0 / row.scale, row.step, got));
    }

    // 2. It is a STAIRCASE — flat over a band, then a jump. This is the
    //    property a test that samples ONE zoom cannot see, and the reason a
    //    constant survived here as long as it did. Both halves are asserted
    //    because either alone is satisfiable by the wrong law: a constant
    //    passes "flat" and a scaling passes "jumps".
    size_t plateaus = 0, jumps = 0;
    foreach (i; 1 .. refStepRows.length) {
        const double a = axisDragRoundingStep(CoordinateRounding.Fine,
                                         1.0 / refStepRows[i - 1].scale,
                                         kFixedIncrementDefault);
        const double b = axisDragRoundingStep(CoordinateRounding.Fine,
                                         1.0 / refStepRows[i].scale,
                                         kFixedIncrementDefault);
        if (a == b) plateaus++; else jumps++;
    }
    assert(plateaus >= 6,
           "the law must be FLAT over bands — adjacent zoom levels sharing a "
           ~ "step. Got only " ~ plateaus.to!string ~ " plateaus across these "
           ~ "19 rows, which is what a law continuous in the zoom looks like");
    assert(jumps >= 8,
           "and it must JUMP between bands. Got only " ~ jumps.to!string
           ~ " jumps, which is what a constant looks like");

    // 3. Every value the law can produce is on the ladder, over a zoom range
    //    far wider than the rows — a mantissa of 1, 2 or 5 times a power of
    //    ten, and nothing else.
    import std.math : log10, floor, pow;
    for (double px = 1e-7; px < 1e2; px *= 1.07) {
        const double s = axisDragRoundingStep(CoordinateRounding.Fine, px,
                                         kFixedIncrementDefault);
        assert(s >= px && s < 10.0 * px,
               "the step is a CEILING of one pixel, within one decade of it");
        const double e = floor(log10(s) + 1e-9);
        const double m = s / (10.0 ^^ e);
        assert(abs(m - 1) < 1e-6 || abs(m - 2) < 1e-6 || abs(m - 5) < 1e-6
            || abs(m - 10) < 1e-6,
               format("every step must sit on the 1-2-5 ladder; pixelSize "
                    ~ "%.9g gave %.12g (mantissa %.9g)", px, s, m));
    }
}

unittest {  // LAW A ported: the ROUNDING, against the reference's own six rows.
    import std.math : abs, floor;
    import std.conv : to;
    import std.format : format;

    // The step those six rows were rounded to is DERIVED from the scale the
    // recording carried, not written down. If the law is wrong this is the
    // wrong step and every one of the six rows fails — which is what makes
    // this a pin on the formula rather than on a number.
    const double step = axisDragRoundingStep(CoordinateRounding.Fine,
                                        1.0 / REF_SNAP_SCALE,
                                        kFixedIncrementDefault);
    assert(abs(step - 0.002) < 1e-12,
           format("the law must derive that recording's own step from its own "
                ~ "scale: %.9g -> %.12g, wanted 0.002", REF_SNAP_SCALE, step));

    // 1. The rounding law itself, scored on reference data and nothing else.
    //    Six pre-snap scalars in, six post-snap scalars out, the engine's own.
    foreach (i, row; refSnapRows) {
        const float got = snapAxisScalar(cast(float)row.before,
                                         cast(float)step);
        assert(abs(got - row.after) < 1e-6,
               "snapAxisScalar must reproduce the engine's own rounding on row "
               ~ i.to!string
               ~ " — round to the NEAREST step. Rows 2 and 4 round in "
               ~ "opposite directions from nearly the same step count, so a "
               ~ "floor, a ceiling or a truncation fails one of them");
    }

    // 2. It is a step, not a coincidence that fits six numbers: every answer
    //    is an exact multiple, over a range far wider than the rows.
    foreach (n; -500 .. 501) {
        const float t   = 0.0001f * n;            // -0.05 .. +0.05
        const float got = snapAxisScalar(t, cast(float)step);
        const double steps = cast(double)got / step;
        assert(abs(steps - floor(steps + 0.5)) < 1e-3,
               "every rounded scalar must land exactly on a multiple of the "
               ~ "step — a residual here means the rounding is being done "
               ~ "against something other than the step");
        assert(abs(cast(double)got - t) <= 0.5 * step + 1e-6,
               "and it must be the NEAREST multiple: no answer may be more "
               ~ "than half a step from its input");
    }

    // 3. ROUND HALF AWAY FROM ZERO, and the negative half is the point. `t`
    //    is negative on every arm dragged backwards, and `floor(x + 0.5)` —
    //    the spelling a port reaches for first — disagrees there and only
    //    there. Exact half-steps are precisely the inputs on which the two
    //    differ, so those are what this drives.
    //
    //    The step here is a NEGATIVE POWER OF TWO, not the view's own 0.002,
    //    and that is deliberate: `(n + 0.5) * 0.002` is not representable in
    //    float32 and lands on either side of the tie depending on `n`, so
    //    driving the tie rule with it measures the float format instead of
    //    the rule. With a dyadic step every value below is exact and the
    //    assertion is about the rounding and nothing else. The rule is a
    //    property of `snapAxisScalar`, independent of where the step
    //    came from.
    foreach (dyadic; [0.25f, 0.5f, 0.03125f]) {
        foreach (n; 0 .. 9) {
            const float halfUp = (cast(float)n + 0.5f) * dyadic;
            const float wantAway = (cast(float)n + 1.0f) * dyadic;
            assert(snapAxisScalar(halfUp, dyadic) == wantAway,
                   format("a positive half-step must round AWAY from zero: "
                        ~ "%.9g at step %.9g wanted %.9g, got %.9g",
                        halfUp, dyadic, wantAway,
                        snapAxisScalar(halfUp, dyadic)));
            assert(snapAxisScalar(-halfUp, dyadic) == -wantAway,
                   format("a NEGATIVE half-step must round away from zero "
                        ~ "too: %.9g at step %.9g wanted %.9g, got %.9g. "
                        ~ "`floor(x + 0.5)` gives %.9g here — that is the "
                        ~ "whole difference between the two spellings, and an "
                        ~ "axis drag produces a negative `t` every time an "
                        ~ "arm is dragged backwards.",
                        -halfUp, dyadic, -wantAway,
                        snapAxisScalar(-halfUp, dyadic),
                        -(cast(float)n * dyadic)));
        }
    }

    // 4. Symmetric about zero, which is what stops a drag and its reverse
    //    from delivering different lengths — an out-and-back gesture that
    //    ratchets is what an even rounding rule feels like.
    foreach (n; 1 .. 200) {
        const float t = 0.00013f * n;
        assert(snapAxisScalar(-t, cast(float)step)
               == -snapAxisScalar(t, cast(float)step),
               "the rounding must be odd: a gesture dragged out and back must "
               ~ "cancel exactly, and it cannot if +t and -t round differently");
    }

    // 5. The shipped entry point IS the gain with this rounding on top — the
    //    two halves are pinned separately above and composed here, so neither
    //    can drift away from the other unnoticed.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    const float vpStep = cast(float)axisDragRoundingStep(
        CoordinateRounding.Fine, viewWorldPerPixel(vp), kFixedIncrementDefault);
    assert(vpStep > 0);
    bool skipRaw, skipSnapped;
    bool sawAnySnap = false;
    foreach (px; [3, 17, 40, 91, 137, -22, -75, -160]) {
        const float raw  = axisArmDeltaUnsnapped(731 + px, 402, 731, 402,
                                                 base, axis, vp, skipRaw);
        const float snap = axisArmDelta(731 + px, 402, 731, 402,
                                        base, axis, vp, skipSnapped,
                                        CoordinateRounding.Fine,
                                        kFixedIncrementDefault);
        assert(!skipRaw && !skipSnapped);
        assert(snap == snapAxisScalar(raw, vpStep),
               "axisArmDelta must be exactly snapAxisScalar(axisArmDeltaUnsnapped) "
               ~ "at the view's own step — if the shipped path stops going "
               ~ "through the rounding, the half-step staircase offset is back "
               ~ "on every axis drag");
        if (snap != raw) sawAnySnap = true;
    }
    assert(sawAnySnap,
           "at least one of these runs must actually be moved by the rounding, "
           ~ "or this test is passing on a step of zero and pins nothing");
}

unittest {  // LAW A ported: the GATE — `None` is the exact identity.
    import std.math : abs;
    import std.format : format;

    // The whole path has one gate and it is `step > 0`. There is no fallback
    // constant behind it: with the setting off, `axisArmDelta` returns the
    // gain untouched, bit for bit.
    assert(axisDragRoundingStep(CoordinateRounding.None, 0.0017,
                           kFixedIncrementDefault) == 0.0,
           "the `None` arm must return a step of exactly zero — anything "
           ~ "positive, however small, is still a grid and still lands the "
           ~ "drag on it");

    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    bool skipRaw, skipOff, skipOn;
    bool sawDifference = false;
    foreach (px; [3, 17, 40, 91, 137, -22, -75, -160]) {
        const float raw = axisArmDeltaUnsnapped(731 + px, 402, 731, 402,
                                                base, axis, vp, skipRaw);
        const float off = axisArmDelta(731 + px, 402, 731, 402,
                                       base, axis, vp, skipOff,
                                       CoordinateRounding.None,
                                       kFixedIncrementDefault);
        const float on  = axisArmDelta(731 + px, 402, 731, 402,
                                       base, axis, vp, skipOn,
                                       CoordinateRounding.Fine,
                                       kFixedIncrementDefault);
        assert(!skipRaw && !skipOff && !skipOn);
        assert(off == raw,
               format("`None` must be the EXACT identity, not a fine step: "
                    ~ "%d px gave %.9g against a raw %.9g", px, off, raw));
        if (on != off) sawDifference = true;
    }
    assert(sawDifference,
           "and `Fine` must actually differ from `None` on this camera — "
           ~ "otherwise this test would pass with the whole term deleted");

    // A non-positive or non-finite step is the identity too, by the same
    // gate: no arm may fall back to a constant when its own step is unset.
    foreach (bad; [0.0f, -0.002f, float.nan]) {
        assert(snapAxisScalar(0.0331f, bad) == 0.0331f,
               "a non-positive or NaN step must leave the scalar alone");
    }
    assert(axisDragRoundingStep(CoordinateRounding.Fine, 0.0, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, -1.0, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, double.nan, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, double.infinity, 0.01) == 0.0);
}

unittest {  // LAW A ported: the OTHER arms of the setting.
    import std.math : abs;
    import std.format : format;

    // `Normal` — the grid's own tenth, nice-rounded. Confirmed live by one
    // row: a view carrying scale 100 with grid 0.5 and step 0.05, and
    // stepLadderNearest(0.5 / 10) is 0.05.
    assert(abs(majorGridStep(1.0 / 100.0) - 0.5) < 1e-12,
           "the grid size at scale 100 must be 0.5 — stepLadderCeil(25/100)");
    assert(abs(axisDragRoundingStep(CoordinateRounding.Normal, 1.0 / 100.0,
                               kFixedIncrementDefault) - 0.05) < 1e-12,
           "the Normal arm must reproduce the one live row it has");

    // `ForcedFixed` — the increment, and nothing else, at ANY zoom. That is
    // the arm's whole content, so the test is that it does not move.
    foreach (px; [1e-5, 1e-3, 1e-1, 1.0]) {
        assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, px, 0.01) == 0.01,
               "ForcedFixed must ignore the zoom entirely");
        assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, px, 0.25) == 0.25);
    }
    // ...and a non-positive increment leaves nothing to round to, which the
    // one gate turns into the identity rather than into a default.
    assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, 1e-3, 0.0)  == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, 1e-3, -1.0) == 0.0);

    // `Fixed` — the INFERRED arm. What is asserted is only the property all
    // three prose sources agree on and that the arm exists to provide: the
    // increment is a LOWER LIMIT. Deliberately not asserted to any particular
    // value at a particular zoom, because no capture has ever run under it
    // and a value assertion here would freeze an inference as a measurement.
    foreach (px; [1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]) {
        const double d = 0.01;
        const double s = axisDragRoundingStep(CoordinateRounding.Fixed, px, d);
        assert(s >= d - 1e-12,
               format("the Fixed arm's whole purpose is that the increment is "
                    ~ "a floor: pixelSize %.9g with increment %.9g gave %.9g",
                    px, d, s));
    }
    // With no increment set it degrades to Normal rather than to nothing —
    // there is still a view-derived step to round to.
    assert(axisDragRoundingStep(CoordinateRounding.Fixed, 1e-3, 0.0)
        == axisDragRoundingStep(CoordinateRounding.Normal, 1e-3, 0.0));
}

unittest {  // LAW A ported: the ladder helper, including the negative half.
    import std.math : abs;

    // Exact powers of ten are the inputs where `log10` can land on either
    // side of a decade boundary. The ladder contains both 1 and 10 precisely
    // so both spellings agree; this is that property, asserted.
    foreach (n; -8 .. 4) {
        const double p = 10.0 ^^ cast(double)n;
        assert(abs(stepLadderCeil(p) - p) <= 1e-12 * p,
               "an exact power of ten must be its own ceiling on the ladder");
    }
    assert(abs(stepLadderCeil(0.0011) - 0.002) < 1e-15);
    assert(abs(stepLadderCeil(0.0021) - 0.005) < 1e-15);
    assert(abs(stepLadderCeil(0.0051) - 0.01 ) < 1e-15);

    // Nearest is measured in LOG space: 3 is nearer 2 than 5 there
    // (log10 3 = 0.477, which is 0.176 above log10 2 and 0.222 below log10 5)
    // even though 3 is equidistant from 2 and 5 linearly.
    assert(abs(stepLadderNearest(3.0) - 2.0) < 1e-12,
           "nearest must be measured in log space, not linearly");
    assert(abs(stepLadderNearest(4.0) - 5.0) < 1e-12);

    // Odd in the sign, like the rounding it feeds.
    assert(stepLadderCeil(-0.0011) == -stepLadderCeil(0.0011));
    assert(stepLadderCeil(0.0) == 0.0);
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
