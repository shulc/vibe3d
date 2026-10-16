module drag;

version (unittest) import drag_source_helpers : corpusCams, corpusViewport, vlen, exactPlaneDelta;

version (unittest) {
    import std.math : PI, sin, cos, tan;
}

import std.math : sqrt, isNaN, abs;
import math;
import vibe3d.util.spatial.spatial : Orientation, Viewport, eyeVectorAt, lockedViewAxis, projectToWindowFull, screenPointToRay, viewPixelScale;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import toolpipe.packets : GesturePacket, GestureTrack;
public import toolpipe.packets : ComponentGuide;
import coord_rounding : CoordinateRounding, kFixedIncrementDefault, coordRounding,
                       coordRoundingFixedIncrement;

// ---------------------------------------------------------------------------
// THE DRAG CONVERSION SEAM
//
// "Where does a screen pixel become a world offset?" has exactly one answer:
// this module. Every interactive drag in the editor — transform gizmos,
// primitive movers, the alignment tools, every parameter haul — routes its
// pixels through one of the laws below. Nothing outside this module may grow
// another.
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
//   (LAW D, the primitive centre's ray/plane intersection, is gone: the
//     centre box runs LAW B on its principal plane, task 9502, capture K-CM.)
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
    float d = screenAxisFraction(mx - lastMX, my - lastMY, origin, axisEnd, vp, skip);
    return skip ? Vec3(0,0,0) : axisDir * (d * axisLen);
}

// The core's unitless half: the pixel drag (dx, dy) dotted onto the projected
// segment origin→axisEnd, over its squared screen length (1 = one segment).
// `skip` when either end does not project or the segment is under a pixel.
float screenAxisFraction(int dx, int dy, Vec3 origin, Vec3 axisEnd,
                         const ref Viewport vp, out bool skip)
{
    float ox, oy, ondcZ, tx, ty, tndcZ;
    skip = !projectToWindowFull(origin,  vp, ox, oy, ondcZ) ||
           !projectToWindowFull(axisEnd, vp, tx, ty, tndcZ);
    if (skip) return 0;
    float sdx = tx - ox, sdy = ty - oy;
    float slen2 = sdx*sdx + sdy*sdy;
    skip = slen2 < 1.0f;
    return skip ? 0 : (dx * sdx + dy * sdy) / slen2;
}

// The Ctrl axis-lock wait: a Ctrl drag resolves its locked axis only once the
// pointer has left a kCtrlLockWaitPx disc around the press (Move, Slice).
enum int kCtrlLockWaitPx = 5;
bool ctrlLockPending(int dx, int dy) {
    return dx * dx + dy * dy < kCtrlLockWaitPx * kCtrlLockWaitPx;
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
//   Fixed        READ at instruction level (task 0580), which is what this
//                entry used to be waiting for. It is `Normal` with the
//                early-out not taken, and then: the increment wins outright
//                if it exceeds the GRID SIZE; otherwise the sub-step is
//                aligned to a whole multiple of the increment, unless that
//                would take twelve or more of them, in which case the
//                sub-step stands. The two prose summaries this entry used to
//                hedge between are BOTH wrong — one drops the multiple
//                clause entirely, the other takes the ratio against the grid
//                size where the code takes it against the sub-step, a factor
//                of ten — so hedging between them was never going to land on
//                the law. Still never observed in a RUNNING view; the read is
//                of the code. What is unmeasured is the value, not the law.
//   ForcedFixed  decoded, and the two decodes agree exactly: the increment,
//                and nothing else, at any zoom.
//
// Returns 0 (i.e. the identity) for a non-positive or non-finite pixel size,
// so a degenerate view rounds nothing rather than rounding to garbage.

// The reference's double-to-int rounder, ported whole: round half away from
// zero, then TRUNCATE TO int32.
//
// The int32 is not incidental packaging, and this is why it is spelled out
// rather than folded into a `round()` call. The hardware truncation yields the
// x86 "integer indefinite" value INT_MIN for any operand that is NaN, infinite,
// or outside int32 — so a ratio of ±inf, which is exactly what `subStep / 0`
// is, comes back as INT_MIN and therefore takes the `< 12` branch. Spelling it
// as a double-returning `round()` gives `inf`, which fails `< 12` and takes the
// OTHER branch: the sign of the whole non-positive-increment case (task 0586)
// hangs on this one detail.
private int roundToInt32(double x) pure nothrow @safe @nogc
{
    import std.math : isNaN;
    const double r = x + (x > 0 ? 0.5 : -0.5);
    // Truncation toward zero fits in int32 iff -2^31-1 < r < 2^31. NaN fails
    // both comparisons and so lands on INT_MIN too, which is what the hardware
    // does.
    if (!(r > -2147483649.0 && r < 2147483648.0)) return int.min;
    return cast(int) r;
}

double axisDragRoundingStep(CoordinateRounding mode, double pixelSize,
                       double fixedIncrement)
{
    // `round` used to be here for the Fixed arm's ratio; that arm now uses
    // `roundToInt32`, whose int32 truncation is load-bearing (see above).
    import std.math : isNaN, isInfinity;

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
            const double g = majorGridStep(pixelSize);
            double s = stepLadderNearest(g / 10.0);
            const double d = fixedIncrement;
            // NaN / infinite increments are OURS, not the reference's — it has
            // no such guard and would carry them through the arithmetic. Kept
            // because neither has ever been measured and widening the fix to
            // cover them would be inventing behaviour, not porting it.
            if (isNaN(d) || isInfinity(d)) return s;
            // The increment is a FLOOR, and the thing it is compared against is
            // the GRID SIZE `g` — not the sub-step `s`, which is what this line
            // used to say (task 0580 read the comparison off the instruction
            // that makes it; task 0586 corrected the operand).
            //
            // The correction is VALUE-NEUTRAL for every positive increment, and
            // that is a property of the ladder rather than luck. The ladder is
            // closed under x10 and `g` is always on it, so `s` is the grid's
            // tenth — to within an ulp, not bit-for-bit; the log-space
            // reconstruction lands one low at some scales, which the unittest
            // measures and pins. In the band `g/10 < d <= g` the old early
            // return fired and gave `d`; the code below now reaches the
            // multiple clause instead, where `s/d` is at most about 1, so the
            // rounded ratio is 0 or 1, the `max(n,1)` lifts it to 1, and the
            // result is `1*d = d`. Same number, by the arm's own arithmetic.
            //
            // So NO test can tell the two spellings apart — reverting this one
            // operand leaves the suite green, and that was checked rather than
            // assumed. It is corrected anyway, and this paragraph is the reason
            // why: the old line was right only because two further errors in
            // the summaries it came from happened to cancel, and an expression
            // that survives on a cancellation is a trap for whoever edits the
            // arm next. Silently relying on it would have been the one outcome
            // worse than either fixing it or arguing against fixing it.
            if (d > g) return d;
            const int n = roundToInt32(s / d);
            if (n < 12) s = (n < 1 ? 1 : n) * d;   // align to a whole multiple
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

/// A plane-drag Jacobian prepared at one caller-owned press anchor.
///
/// The viewport, basis and anchor are inputs rather than hidden state. A tool
/// that stores this image at Down therefore gets the reference translator's
/// cumulative, press-frozen conversion without re-reading a live viewport.
struct PreparedPlaneDrag {
    bool valid;
    PlaneJacobian jacobian;

    Vec3 apply(int mx, int my, int pressX, int pressY) const {
        if (!valid) return Vec3(0, 0, 0);
        return jacobian.apply(cast(float)(mx - pressX),
                              cast(float)(my - pressY));
    }
}

// The finite-difference step, in world units, for the Jacobian below: ten
// of the view's NOMINAL pixels (`viewWorldPerPixel`, not the pixel at the
// anchor's depth). The first-order argument bounds the SIZE of the shift
// only, not its sign or direction: the forward bias is part of the captured map (findings K-C3: 1e-6 at the read targets with
// this step, 9e-4..1.2e-2 with the anchored pixel, 1.3e-2+ with k -> 0).
private float jacobianStep(const ref Viewport vp) {
    float k = 10.0f * viewWorldPerPixel(vp);
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

    const double k = isNaN(step) ? jacobianStep(vp) : step;

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

private bool planeDragNormal(int dragAxis, const ref Viewport vp,
                             Vec3 axisX, Vec3 axisY, Vec3 axisZ,
                             Vec3 planeNormal, out Vec3 n)
{
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
    if (!(nl > 1e-9f)) return false;
    n = n / nl;
    return true;
}

/// Raw automatic principal-plane hit at the press pixel.
///
/// This is the press half of LAW B and shares its plane election verbatim.
/// The plane passes through the frozen view focus; construction-workplane
/// state is deliberately not an input. The captured Polygon law snaps
/// this raw H before preparing the translator Jacobian.
bool automaticPlanePressHit(int mx, int my, const ref Viewport vp,
                            out Vec3 hit,
                            Vec3 axisX = Vec3(1, 0, 0),
                            Vec3 axisY = Vec3(0, 1, 0),
                            Vec3 axisZ = Vec3(0, 0, 1))
{
    Vec3 n;
    if (!planeDragNormal(3, vp, axisX, axisY, axisZ,
                         Vec3(float.nan, float.nan, float.nan), n))
        return false;
    Vec3 rayO, rayD;
    screenPointToRay(cast(float)mx, cast(float)my, vp, rayO, rayD);
    return rayPlaneIntersect(rayO, rayD, vp.focus, n, hit);
}

/// Prepare LAW B's inverse screen Jacobian at an already chosen press anchor.
PreparedPlaneDrag preparePlaneDrag(Vec3 anchor, int dragAxis,
                                   const ref Viewport vp,
                                   Vec3 axisX = Vec3(1, 0, 0),
                                   Vec3 axisY = Vec3(0, 1, 0),
                                   Vec3 axisZ = Vec3(0, 0, 1),
                                   Vec3 planeNormal = Vec3(float.nan,
                                                           float.nan,
                                                           float.nan))
{
    PreparedPlaneDrag prepared;
    Vec3 n;
    if (!planeDragNormal(dragAxis, vp, axisX, axisY, axisZ, planeNormal, n))
        return prepared;
    Vec3 axisU, axisV;
    inPlaneAxes(n, axisX, axisY, axisZ, axisU, axisV);
    prepared.jacobian = planeJacobian(anchor, axisU, axisV, vp);
    prepared.valid = prepared.jacobian.valid;
    return prepared;
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
    if (!planeDragNormal(dragAxis, vp, axisX, axisY, axisZ, planeNormal, n))
    { skip = true; return Vec3(0,0,0); }

    Vec3 axisU, axisV;
    inPlaneAxes(n, axisX, axisY, axisZ, axisU, axisV);

    auto j = planeJacobian(center, axisU, axisV, vp);
    if (!j.valid) { skip = true; return Vec3(0,0,0); }

    return j.apply(cast(float)(mx - lastMX), cast(float)(my - lastMY));
}

// ===========================================================================
// The primitive centre box's plane
// ===========================================================================

/// The normal axis of the primitive centre box's plane (`DragKind.handlePlane`):
/// a locked orthographic view's axis, else the dominant component of the eye
/// vector at the centre (the perspective pick is unwitnessed: gap 585).
int primitiveCenterPlaneAxis(Vec3 reference, const ref Viewport vp) {
    int axis = lockedViewAxis(vp);
    if (axis >= 0) return axis;

    Vec3 eye = eyeVectorAt(vp, reference);
    float ax = abs(eye.x), ay = abs(eye.y), az = abs(eye.z);
    return ax >= ay && ax >= az ? 0 : ay >= az ? 1 : 2;
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
// M-HANDLE — press + travel
// ===========================================================================

// Which of the laws above turns the pointer travel into handle travel. The
// frame is GEOMETRY the handle supplies, never a tool policy.
enum DragKind : ubyte {
    axisArm,        // LAW A ported: `axisArmDelta` along `axis` (unit)
    screenAxis,     // LAW A own: the segment point → point + axis, gain |axis|
    viewPlane,      // LAW B: `planeDragDelta` on `plane` (3..6) of the basis
    handlePlane,    // LAW B on the handle's `plane` (4..6), the planar form `q(p + T)`
    planeHit,       // the pointer's hit on the plane (point, `normal`)
}

struct DragFrame {
    DragKind kind;
    Vec3 axis   = Vec3(1, 0, 0);
    Vec3 normal = Vec3(0, 0, 1);
    int  plane  = 3;
    Vec3 basisX = Vec3(1, 0, 0), basisY = Vec3(0, 1, 0), basisZ = Vec3(0, 0, 1);
}

alias ComponentGuideResolver = ComponentGuide delegate(Vec3);

/// A handle drag's client point: the handle at the press plus the pointer
/// travel since the press, through the frame the handle supplies per event.
/// It holds no snap and is never written after the press, so a snapped
/// answer cannot feed the next event and a released snap rejoins the pointer
/// (captured K-B9: Move and Box, one release law). Positions live in whatever
/// space `vp` projects (a create tool passes its plane-local view).
/// The travel is rounded to the view quantum q by the frame KIND, the
/// translator's mode (K-G3 / K-H2 / K-C3 / K-H3): a free plane keeps the
/// point's residual, `p + q(p + T) - q(p)`; a planar one (a Move ring, a
/// primitive centre box: K-H3, K-CM) rounds the position, `q(p + T)`; a line
/// rounds its travel, `p + q(t)`.
/// The axis arm rounds `t` itself (LAW A, the coordinate-rounding step).
struct HandleDrag {
    Vec3 point;
    int  pressX, pressY;

    void press(Vec3 handle, int px, int py) {
        point = handle; pressX = px; pressY = py;
    }

    Vec3 client(int px, int py, DragFrame f, const ref Viewport vp,
                out bool skip, scope ComponentGuideResolver guide = null) const
    {
        import viewgrid : vectorSnap, viewVectorQuantum;
        immutable Vec3 t = travel(px, py, f, vp, skip);
        immutable float q = viewVectorQuantum(vp);
        final switch (f.kind) {
        case DragKind.axisArm:        return point + t;
        case DragKind.viewPlane: {
            Vec3 u = vectorSnap(point + t, q);
            const accepted = guide is null ? ComponentGuide.init : guide(u);
            if (accepted.acceptedMask != 0) {
                if (accepted.acceptedMask & 1) u.x = accepted.valuesWorld.x;
                if (accepted.acceptedMask & 2) u.y = accepted.valuesWorld.y;
                if (accepted.acceptedMask & 4) u.z = accepted.valuesWorld.z;
                return u;
            }
            return point + (u - vectorSnap(point, q));
        }
        // A plane handle presses at its centre (K-H3 H3_RING, K-CM).
        case DragKind.handlePlane:    return vectorSnap(point + t, q);
        case DragKind.screenAxis:
        case DragKind.planeHit:
            immutable Vec3 u = normalize(f.axis);
            return point + u * snapAxisScalar(dot(t, u), q);
        }
    }

    private Vec3 travel(int px, int py, DragFrame f, const ref Viewport vp,
                        out bool skip) const
    {
        final switch (f.kind) {
        case DragKind.axisArm:
            return f.axis * axisArmDelta(px, py, pressX, pressY, point, f.axis,
                vp, skip, coordRounding(), coordRoundingFixedIncrement());
        case DragKind.screenAxis:
            return f.axis * screenAxisFraction(px - pressX, py - pressY,
                point, point + f.axis, vp, skip);
        case DragKind.viewPlane:
        case DragKind.handlePlane:
            return planeDragDelta(px, py, pressX, pressY, f.plane, point, vp,
                skip, f.basisX, f.basisY, f.basisZ);
        case DragKind.planeHit:
            Vec3 o, d, h0, h1;
            screenPointToRay(cast(float)pressX, cast(float)pressY, vp, o, d);
            skip = !rayPlaneIntersect(o, d, point, f.normal, h0);
            screenPointToRay(cast(float)px, cast(float)py, vp, o, d);
            skip = skip || !rayPlaneIntersect(o, d, point, f.normal, h1);
            return h1 - h0;
        }
    }
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


