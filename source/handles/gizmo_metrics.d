module handles.gizmo_metrics;

// The gizmo's METRICS: the global arm size in screen pixels, every GIZMO_*
// constant the three banks are drawn and hit-tested from, the two size
// conversions (`gizmoSize` / `gizmoPixelSize`), and the three view-dependent
// visibility predicates. No OpenGL: nothing in this file makes a gl* call, and
// nothing in it needs a live context, which is why its laws are unit-testable
// and are pinned below.
//
// ── WHY THIS FILE EXISTS, AND WHY IT IS NOT A RENAME (task 0719, finding T9) ─
//
// Audit 4 filed `handles/gl_util.d` as a search-name trap -- "not GL utilities
// but gizmo metrics/constants" -- and prescribed renaming the file to
// `gizmo_metrics.d`. Measured before doing it, that premise is half right and
// the prescription would have made the trap WORSE. The file was 1469 lines and
// genuinely BOTH things: lines 48-729 were metrics with ZERO gl* calls, and the
// remaining ~740 lines are real GL plumbing -- three shader-program state
// blocks, VAO builders, the blend/alpha stack and four world-space draw
// primitives, 126 gl* calls among them. Renaming the whole file would have
// filed all of that under a name that says "metrics", i.e. the same trap
// pointing the other way.
//
// So the file was SPLIT instead. Each half now earns its name, and the public
// surface is unchanged: `gl_util.d` carries a `public import` of this module,
// and `handler.d` already re-exported `gl_util` publicly, so every existing
// consumer keeps resolving these symbols exactly where it did before. Nothing
// was made public to allow the split, and no import list outside the two files
// changed.
//
// The other half of the finding -- that a rename is cheap -- did not survive
// the census either: `gl_util` is named as TEXT in 27 source and test files
// (all of them comments, all of which a rename compiles straight past) and in
// 20+ design documents. That count is the argument for splitting rather than
// renaming, not against doing anything.

import std.math : sqrt, PI, abs;
import math;

// ---------------------------------------------------------------------------
// Global gizmo scale — shared by MoveHandler, RotateHandler, ScaleHandler.
// Change via setGizmoPixels() at runtime. The unit is screen pixels (the
// target on-screen length of the main gizmo arm) and the result is
// independent of viewport height — the transform gizmos stay a fixed pixel
// height regardless of window size. The previous semantic was "fraction of
// viewport height", which made the gizmo grow with the window.
//
// Task 0553: 120, was 90. The reference computes its arm as
// `handleScale * 6.0` SCREEN units, converts at 20 pixels per screen unit,
// and ships `handleScale = 1.0` — so 120 px, read out of the two length
// functions rather than measured off a screenshot. The same read settles the
// units question this file's header asserts: the conversion divides by the
// view's own scale, and on one recorded execution the world arm moved by
// exactly 1024x across four cameras while the SCREEN length stayed
// bit-identical. Screen-constant, confirmed; world-constant, clamped and
// viewport-relative models all refuted.
// ---------------------------------------------------------------------------

private float g_gizmoPixels = 120.0f;  // 120px gizmo arm at any vp height

void  setGizmoPixels(float px)  { g_gizmoPixels = px; }
float getGizmoPixels()          { return g_gizmoPixels; }

// ---------------------------------------------------------------------------
// The handle-size PREFERENCE, and the ten values the `-` / `+` keys reach.
//
// Task 0597. The arm above is `handleScale * 120 px`, and the handle scale is
// what the user actually moves: the reference steps it by exactly +-0.5 and
// clamps it to [0.5, 5.0] — TEN LINEAR values giving 60..600 px of arm,
// shipping at 1.0.
//
// Our previous ladder was nine GEOMETRIC steps of our own invention
// (50/70/90/120/160/220/290/380/480). That is wrong in kind and not merely in
// its endpoints, because four of the ornament sizes below stop growing at a
// knee near a handle scale of 1.2-1.25 — so WHERE the steps land decides
// whether the user ever sees an ornament change size at all.
//
// `g_gizmoPixels` stays the stored state: a great many call sites (drag.d,
// drag_identity.d, the slice tools, ~45 test files) read the arm in pixels, and
// deriving the scale from it rather than storing both means the two can never
// disagree. `setGizmoPixels` remains the RAW setter and deliberately does not
// clamp — tests drive it directly to pin the size law. The PREFERENCE path is
// `setGizmoHandleScale` / `stepGizmoHandleScale`, which clamp on write; the
// reference clamps in the same place (its setter), so that its keyboard path
// and its preference path cannot disagree.
// ---------------------------------------------------------------------------

/// Arm length in pixels at a handle scale of 1.0 — the shipped default.
enum float GIZMO_ARM_PX_AT_UNIT_SCALE = 120.0f;
/// Preference floor / ceiling / per-press step. From the 1.0 default these
/// give exactly {0.5, 1.0, 1.5, ... 5.0} — 60 px to 600 px of arm.
enum float GIZMO_HANDLE_SCALE_MIN  = 0.5f;
enum float GIZMO_HANDLE_SCALE_MAX  = 5.0f;
enum float GIZMO_HANDLE_SCALE_STEP = 0.5f;

/// Clamp that sends NaN to the FLOOR instead of propagating it. Every size
/// below is a drawn extent, and a NaN extent silently deletes the geometry it
/// sizes (the model matrix goes NaN and every vertex is culled), which is a far
/// worse failure than a handle drawn at its minimum. `!(v > lo)` is true for
/// NaN, which is the whole trick — `v < lo` would not be.
private float clampSizeF(float v, float lo, float hi) {
    if (!(v > lo)) return lo;
    return v < hi ? v : hi;
}

/// The handle-size preference itself: the arm in units of its default length.
float gizmoHandleScale() { return g_gizmoPixels / GIZMO_ARM_PX_AT_UNIT_SCALE; }

/// Set the preference, clamped to the reachable band. NaN lands on the floor.
void setGizmoHandleScale(float scale) {
    setGizmoPixels(clampSizeF(scale, GIZMO_HANDLE_SCALE_MIN, GIZMO_HANDLE_SCALE_MAX)
                   * GIZMO_ARM_PX_AT_UNIT_SCALE);
}

/// One press of `-` (`dir < 0`) or `+` (`dir >= 0`). Returns the new scale.
/// Saturating rather than wrapping, and idempotent at either end.
float stepGizmoHandleScale(int dir) {
    immutable float step = dir < 0 ? -GIZMO_HANDLE_SCALE_STEP : GIZMO_HANDLE_SCALE_STEP;
    setGizmoHandleScale(gizmoHandleScale() + step);
    return gizmoHandleScale();
}

// ---------------------------------------------------------------------------
// Transform-gizmo handle geometry — one named place per quantity.
//
// `g_gizmoPixels` above already centralises the OVERALL gizmo scale; what it
// did not centralise is the proportions. Every handle's length / radius /
// offset used to be an inline literal at its own use site, and four of them
// were duplicated across files that MUST agree (the arbiter's hit-test in
// handles/shapes.d and the standalone `hitTestAxes` in tools/transform/*.d
// resolve the same press, so a tolerance changed in one but not the other
// makes the highlighted handle differ from the grabbed one — the exact class
// of bug the ToolHandles arbiter exists to prevent).
//
// UNITS. `gizmoSize(pos, vp)` returns the world length of `getGizmoPixels()`
// screen pixels at `pos` — i.e. the gizmo is SCREEN-constant, not
// world-constant: its apparent size does not change with camera distance or
// ortho zoom. So each RATIO below, multiplied by `getGizmoPixels()`, is that
// quantity in screen pixels (the px figures in the comments assume the 90-px
// default arm). The PICK_*_PX values are already window pixels.
//
// The two _DIV constants are divisors rather than ratios on purpose: the code
// they replace divides (`size / 6`), and `size * (1.0f/6.0f)` is not
// bit-identical to it. Naming them without changing a single resulting float
// was worth the slightly awkward form.
//
// Values here are the pre-port defaults, restated verbatim from the literals
// they replaced. Changing one is a deliberate geometry change and should be
// backed by a measurement, not by making a test pass.
// ---------------------------------------------------------------------------

// -- The CLAMPED ornaments (task 0597) --------------------------------------
//
// Four sizes on the transform gizmo are NOT a fixed fraction of the arm. They
// grow with the arm only inside a narrow band and then stop, and two of them
// stop at the bottom as well. The bands were measured live off the reference
// over the whole reachable handle-scale range (0.5 -> 5.0, a 10x span), both
// ends of every clamp; the sharpest single reading is that a handle scale of
// 1.25 and one of 5.0 — a 4x difference in the arm — give a bit-identical box.
//
// WHY THIS MATTERS MORE THAN THE CONSTANTS. Every knee sits at 1.2-1.25 and
// every press moves the handle scale by 0.5, so the FIRST `+` from the shipped
// 1.0 saturates all four and the remaining nine steps grow nothing but the arm.
// A port that carried only the ratios would look right in a screenshot at the
// default and diverge the moment anyone touched the keys — which is exactly
// the bug this block exists to fix. The falsifiable half, confirmed by hand
// after the measurement: `-` from the default DOES shrink the arrowhead,
// because 0.5 is below both knees. Fixed pixels would have shrunk neither.
//
// These are PIXEL counts, consumed through `gizmoPixelSize` (below) rather
// than multiplied into `gizmoSize`, because that is what they are.

/// Arrowhead axial length: `arm / 5`, clamped. 24 px at the default, frozen at
/// 30 px for every handle scale of 1.25 or more. The floor sits below the
/// reachable range (it would engage at 0.4167) but is real and is ported as read.
enum float GIZMO_HEAD_LEN_ARM_DIV   = 5.0f;
enum float GIZMO_HEAD_LEN_MIN_PX    = 10.0f;
enum float GIZMO_HEAD_LEN_MAX_PX    = 30.0f;

/// Arrowhead HALF-WIDTH: `arm / 16`, clamped at BOTH ends, then scaled by the
/// stroke width. 7.5 px at the default; pinned to 4 px at or below a handle
/// scale of 0.533 and to 9 px at or above 1.2.
///
/// The line width is a GEOMETRY input here, not only a stroke weight — raising
/// it 1.0 -> 8.0 was measured taking the half-width 7.5 px -> 30 px, i.e. the
/// factor is `0.5 * max(2.0, lineWidth)` and nothing else in the gizmo moved.
/// We expose no such user preference (our handle stroke widths are per-shape
/// constants in handles/shapes.d, not a setting), so the parameter defaults to
/// the value that reproduces our effective behaviour — and at
/// `lineWidth <= 2.0` the factor is exactly 1.0, so the default costs nothing.
/// It is a parameter rather than a global so the coupling is stated and
/// testable without introducing mutable state nothing writes.
enum float GIZMO_HEAD_HALF_ARM_DIV  = 16.0f;
enum float GIZMO_HEAD_HALF_MIN_PX   = 4.0f;
enum float GIZMO_HEAD_HALF_MAX_PX   = 9.0f;
enum float GIZMO_HEAD_LINE_FLOOR    = 2.0f;
enum float GIZMO_LINE_WIDTH_DEFAULT = 1.0f;

/// Centre-handle and scale-box HALF-extent: `clamp(handleScale, 0.75, 1.25) * 5`
/// px. ONE constant for both boxes, which is also what the reference does —
/// the same three-constant clamp idiom appears at both of its sites. Over the
/// ten reachable handle-scale values it takes exactly THREE values: 3.75 px at
/// 0.5, 5.00 px at 1.0, 6.25 px from 1.5 up. Three steps, not a constant: the
/// centre handle looks unchanging next to a 10x arm, but it is not fixed, and
/// a test asserting invariance would freeze the wrong law.
enum float GIZMO_BOX_HALF_PX        = 5.0f;
enum float GIZMO_BOX_SCALE_MIN      = 0.75f;
enum float GIZMO_BOX_SCALE_MAX      = 1.25f;

/// Arrowhead axial length in window pixels at the current handle size.
float gizmoHeadLenPx() {
    return clampSizeF(g_gizmoPixels / GIZMO_HEAD_LEN_ARM_DIV,
                      GIZMO_HEAD_LEN_MIN_PX, GIZMO_HEAD_LEN_MAX_PX);
}

/// Arrowhead half-width (cone base RADIUS) in window pixels.
float gizmoHeadHalfPx(float lineWidth = GIZMO_LINE_WIDTH_DEFAULT) {
    // `max(GIZMO_HEAD_LINE_FLOOR, lineWidth)`, written so NaN takes the floor.
    immutable float w = lineWidth > GIZMO_HEAD_LINE_FLOOR ? lineWidth
                                                         : GIZMO_HEAD_LINE_FLOOR;
    return clampSizeF(g_gizmoPixels / GIZMO_HEAD_HALF_ARM_DIV,
                      GIZMO_HEAD_HALF_MIN_PX, GIZMO_HEAD_HALF_MAX_PX) * 0.5f * w;
}

/// Centre-box / scale-box half-extent in window pixels.
float gizmoBoxHalfPx() {
    return clampSizeF(gizmoHandleScale(), GIZMO_BOX_SCALE_MIN, GIZMO_BOX_SCALE_MAX)
           * GIZMO_BOX_HALF_PX;
}

// -- Move bank: three axis arrows, centre box, three plane circles ----------
/// Arrow tip, as a fraction of the arm. 1.0 = the arm itself → 120 px.
enum float GIZMO_MOVE_ARM             = 1.00f;
/// Arrow shaft start = arm / this. → 24 px out from the centre.
///
/// Task 0553: was 6 (15 px). The reference starts BOTH banks' shafts at
/// `screenLength / 5` = 24 px, leaving the inner 24 px to the centre handle.
/// We had two different divisors, /6 here and /7 for scale; there is one
/// inset, and this is it. See GIZMO_SCALE_SHAFT_INSET_DIV.
enum float GIZMO_MOVE_SHAFT_INSET_DIV = 5.0f;
// The centre box's half-extent used to live here as `GIZMO_CENTER_BOX_HALF`,
// a flat 0.04 of the arm (4.8 px at the default, and 2..19 px across the old
// ladder). Task 0597 replaced it with `gizmoBoxHalfPx()` above: 5.00 px at the
// default and three distinct sizes over the whole reachable range. The
// measured centre handle is a clamped extent, not a share of the arm.
/// Plane-circle centre offset along EACH of its two axes. → 72 px per axis.
///
/// Task 0553: was 0.75. The reference publishes this exact proportion as a
/// shipped preference — a "plane handle ratio" governing the handles that
/// constrain an action to two axes at once — and its value there is 0.80.
/// Independently, three plane rings were measured sitting at ≈0.8 of an arm
/// along each of their two axes, so the shipped number and the observation
/// agree. Shared by the move bank and the scale bank, which is also what the
/// reference does: one ratio, not one per bank.
enum float GIZMO_PLANE_OFFSET         = 0.80f;
/// Plane-circle radius, in WINDOW PIXELS — not a fraction of the arm.
///
/// Task 0553: was 0.07 of the arm (6.3 px at the old 90-px arm, 8.4 at the
/// new 120). The reference sets this ring's radius to a plain 8 pixels, next
/// to an OFFSET it computes from the arm length — the two sit in the same
/// function and only one of them scales. So the ring keeps its size when the
/// user grows the gizmo; only its distance from the centre grows. Consumed
/// through `gizmoPixelSize` below, which is our name for the reference's
/// "model units per pixel" conversion.
enum float GIZMO_PLANE_RADIUS_PX      = 8.0f;
/// The plane handle's inner FILL disc, as a fraction of its outline ring.
///
/// Task 0602: was implicitly 1.0 — our disc was drawn at the ring's own radius,
/// so it filled the ring edge to edge and the two elements read as one blob.
/// The reference draws the fill at `0.8 x` the ring, i.e. 6.4 px inside an 8 px
/// outline, and the gap between them is the whole reason the handle reads as a
/// ring around a hole rather than as a dot. Measured two ways: read off the
/// instruction stream as one shared 0.8 constant (the same literal that is also
/// the ring's alpha), and corroborated on a face-on handle whose fill covered
/// 112 px — against the 129 px a 6.4 px disc predicts and the 201 px a full
/// 8 px disc would have given.
enum float GIZMO_PLANE_FILL_RATIO     = 0.80f;

// -- Rotate bank: three principal semicircles + the view-plane ring ---------
/// Principal (X/Y/Z) ring radius, fraction of the arm. → 90 px.
enum float GIZMO_RING_RADIUS          = 1.00f;
/// View-plane ring radius, fraction of the arm. → 130 px.
///
/// Task 0597: was 1.10 (132 px). The reference builds this ring as
/// `SL + SL/12`, i.e. 13/12 of the arm — read from its instruction stream
/// rather than measured, and the 2 px it moves is well inside the ring's own
/// grab band, so nothing that presses the view ring notices.
enum float GIZMO_VIEW_RING_RADIUS     = 13.0f / 12.0f;

// -- Scale bank: three axis boxes on stems, centre disc, plane circles ------
/// Axis box distance from the centre when this bank is drawn ALONE, as a
/// fraction of the arm. → 120 px, i.e. the SAME point the move arrow's tip
/// reaches. Add GIZMO_SCALE_ARM_CROSS_BANK_SHIFT when it is not alone.
///
/// Task 0553: was 1.18, which put the scale boxes 18 % beyond the move tips.
/// The reference ends both banks' arms at the same screen length, so 1.00 is
/// right — for a bank on its own, which is the only frame the measurement
/// behind that number ever contained. It did NOT say the stagger was ours;
/// see the constant below for the frame it never covered.
///
/// (The reference's scale CUBE is centred half a box inside that end, on a
/// line that still runs the full length — a distinction our CubicArrow cannot
/// draw, since `end` is at once the stem's end and the head's centre. Moot in
/// the combined presentation, which draws no scale stem at all.)
enum float GIZMO_SCALE_ARM            = 1.00f;
/// ADDED to GIZMO_SCALE_ARM whenever another bank shares the gizmo — the move
/// bank, the rotate bank, or both. → the box spans 122 → 132 px instead of
/// 110 → 120, clearing the 96 → 120 arrowhead with 2 px to spare.
///
/// Task 0606, and it is the only quantity in this gizmo that depends on what
/// ELSE is on screen. The reference's combined transform tool does not route
/// its scale bank through the framework handle-draw call its standalone scale
/// tool is a thin caller of: the combined tool emits the boxes itself, and
/// that call cannot express this offset. Which is exactly why comparing our
/// combined path against our own standalone one — as two lanes did — finds
/// them in agreement and settles nothing.
///
/// THE GATE IS A DISJUNCTION, and one all-on cell against one all-off cell
/// cannot say so: that pair fits "when translate is on", "when rotate is on"
/// and "when either is on" equally. Two more cells broke it — one read
/// translate OFF with the box shifted anyway, another read rotate OFF and
/// shifted. Neither flag alone is the gate.
///
/// A tenth of the ARM, not a fitted pixel count, so it tracks the handle-size
/// preference across its whole [0.5, 5.0] band (60..600 px of arm).
///
/// Ours was 1.00 in both presentations, which drew a 10 px box entirely
/// inside a 24 px arrowhead. That is the visible defect this retires, and it
/// was reported twice before it was measured in the frame that shows it.
enum float GIZMO_SCALE_ARM_CROSS_BANK_SHIFT = 1.0f / 10.0f;
/// Scale stem start = arm / this. → 24 px out from the centre — the same
/// inset as the move bank (task 0553; see GIZMO_MOVE_SHAFT_INSET_DIV). Was
/// 7, which made it 12.9 px against move's 15.
enum float GIZMO_SCALE_SHAFT_INSET_DIV = 5.0f;
// The scale box's half-extent used to live here as `GIZMO_SCALE_BOX_HALF`
// (0.03 of the arm = 3.6 px) for the LIVE drag-feedback box, while the STATIC
// axis box fell through to GIZMO_CUBE_HEAD_HALF_OF_LEN below and landed at
// 2.88 px. The reference has ONE box per axis at ONE size, so task 0597 gave
// both `gizmoBoxHalfPx()` — 5.00 px at the default, the same clamped extent as
// the centre handle. GIZMO_CUBE_HEAD_HALF_OF_LEN stays as the fallback for
// every OTHER CubicArrow user, which this port does not touch.
/// Centre-disc radius, fraction of the arm. → 7.2 px.
enum float GIZMO_DISC_RADIUS          = 0.08f;

// -- Arrow head proportions, relative to the ARROW's own length -------------
// NOTE these are shared with every other Arrow/CubicArrow user (primitive
// create-tool movers, falloff endpoint handles), not just the transform
// gizmo — changing them moves those handles too.
//
// Task 0597: the TRANSFORM gizmo no longer reaches these. MoveHandler and
// ScaleHandler now push explicit pixel sizes (`gizmoHeadLenPx`,
// `gizmoHeadHalfPx`, `gizmoBoxHalfPx`) into `Arrow.fixedConeLen` /
// `.fixedConeHalf` / `CubicArrow.fixedCubeHalf`, because the reference clamps
// those three and a flat fraction cannot clamp. The ratios below remain the
// FALLBACK for every arrow that sets no override — deliberately left alone,
// since nothing has measured the handles that use them.
/// Cone head length as a fraction of the arrow's length. → 24 px on the move
/// arrow (whose shaft spans 96 px) before the transform gizmo's override.
enum float GIZMO_CONE_LEN_OF_LEN      = 0.25f;
/// Cone head base radius as a fraction of the arrow's length. → 4.8 px.
enum float GIZMO_CONE_RADIUS_OF_LEN   = 0.05f;
/// Default cube-head HALF-extent as a fraction of the arrow's length, used
/// when `CubicArrow.fixedCubeHalf` is unset. → 2.80 px on the scale stem.
enum float GIZMO_CUBE_HEAD_HALF_OF_LEN = 0.03f;

// -- Stroke widths, in WINDOW PIXELS (task 0600) ----------------------------
//
// The reference's four gizmo stroke widths, each read out of the draw code and
// then confirmed on its own pixels. Three of them are a FLOOR under a
// user-settable line-width preference we do not expose; with no preference the
// floor IS the value, so these are the floors. If such a preference is ever
// added, it belongs here as `max(FLOOR, pref)` — and note it would not be only
// a stroke weight, it also multiplies `gizmoHeadHalfPx` above.
//
// WHAT THESE REPLACED, AND WHY THE NUMBERS LOOK SMALLER THAN THEY ARE. The old
// literals were 5.0 (move shaft), 6.0 (rotate arc), 4.0 (view ring), 1.5
// (plane ring). They were NOT 5 / 6 / 4 / 1.5 pixels: the geometry shader's
// clip-to-screen conversion was off by exactly 2 (see `thickLineGeomSrc`), so
// they rendered 2.5 / 3.0 / 2.0 / 0.75 px. Measured through
// /api/viewport/probe, on the ink itself, before anything here changed.
//
// So the real gaps against the reference were 2.5 -> 2.0 and 3.0 -> 2.5 (a
// quarter too heavy, not "roughly twice"), while the view ring at 2.0 and the
// plane ring at 0.75 were too THIN. Every direction was wrong, which is why
// the unit was fixed rather than the literals rescaled: with the shader
// honest, the number written here is the number of pixels drawn.
/// Move-bank axis shaft. A 2 px floor under the width preference.
enum float GIZMO_STROKE_MOVE_SHAFT_PX  = 2.0f;
/// Scale-bank axis stem. A literal in the reference — it ignores the
/// preference the other three consult.
enum float GIZMO_STROKE_SCALE_SHAFT_PX = 2.0f;
/// Rotate rings — the three axis arcs AND the screen-plane ring, which are one
/// shape in the reference and take one width: a 2.5 px floor.
enum float GIZMO_STROKE_ROTATE_RING_PX = 2.5f;
/// Plane-handle outline ring. The width preference with NO floor under it —
/// the one stroke that can go below 2 px.
enum float GIZMO_STROKE_PLANE_RING_PX  = 1.0f;
/// The disc drawn behind the rotate rings: a HAIRLINE, and the one stroke on
/// this gizmo with no floor under it at all — the same law as the plane ring
/// above, and unlike the move shaft's 2 and the rotate rings' 2.5.
///
/// Task 0610: was 2.0. That number came from the arm of a two-arm draw function
/// that the reference application never enters — both of its call sites select
/// the other arm — so it was never a measurement of anything drawn. What is
/// drawn integrates to 1.006-1.046 px over a 2.9x change of radius, and steps
/// to exactly 8 px when the width preference is set to 8. A LAW, not a
/// constant: it tracks the preference verbatim and does not track the handle
/// scale. We do not expose that preference, so 1.0 is what ships; if one is
/// ever added, this becomes the preference itself and NOT `max(floor, pref)`.
///
/// This is the width the disc is measured at, so the number here has to stay
/// tied to a measurement rather than to what looks right: at 1 px against a
/// backdrop it sits 0.15 below, the shape is close to subliminal, and every
/// wrong value for it also looks approximately fine.
enum float GIZMO_STROKE_ROTATE_DISC_PX = 1.0f;

// -- Per-part ALPHA (task 0600) ---------------------------------------------
//
// Measured per part. These could not be ported when they were first read,
// because no handle draw wrote the fragment alpha at all — every gizmo line
// reached the framebuffer at alpha 0 and was composited away. That is fixed;
// these are the values it was fixed FOR.
//
// The 0.95 is not a rounding of 1.0. It is a literal the reference passes on
// every gizmo line batch, and it is load-bearing for the look it was measured
// with: its own antialiasing only engages because alpha < 1 puts the batch on
// the blending path in the first place.
/// Move/scale arms — shaft, arrowhead and box alike. One value for the whole arm.
enum float GIZMO_ALPHA_ARM              = 0.95f;
/// Rotate rings, axis and screen-plane alike.
enum float GIZMO_ALPHA_ROTATE_RING      = 0.95f;
/// The centre handle. The one gizmo part that is fully opaque.
enum float GIZMO_ALPHA_CENTRE_BOX       = 1.00f;
/// Plane handle: a nearly-solid axis-coloured ring around a barely-there disc.
enum float GIZMO_ALPHA_PLANE_RING       = 0.80f;
enum float GIZMO_ALPHA_PLANE_FILL       = 0.20f;
/// ...and the ONE state in which that disc goes fully opaque. A grabbed plane
/// handle is the only opaque thing the plane handle ever draws, and it is what
/// separates a grab from a hover on this shape: hover recolours BOTH elements
/// and leaves both alphas alone, a grab raises only the disc's alpha and hands
/// the ring its axis colour back. Exactly 1.0, not "nearly" — at 1.0 the batch
/// leaves the blending path entirely, which is the reference's own behaviour
/// (its stroke selects an opaque blend word at exactly this value).
enum float GIZMO_ALPHA_PLANE_FILL_GRABBED = 1.00f;
/// The screen/eye-aligned disc — the faintest fill on the gizmo, ringed solid.
enum float GIZMO_ALPHA_SCREEN_DISC_FILL = 0.10f;
enum float GIZMO_ALPHA_SCREEN_DISC_RING = 1.00f;
/// The backing disc behind the rotate rings. ONE part — a line loop — and it
/// is OPAQUE, which on this gizmo makes it the exception rather than the rule:
/// every other stroke here carries an alpha below 1.
///
/// Task 0610 retired both of the values that used to stand here, a fill at 0.20
/// under an outline at 0.75. There is no fill (see `FullCircleHandler`, which
/// no longer has one to give) and there is no partial opacity: the reference
/// emits this batch with no alpha attached at all, which on its own path means
/// blending is switched OFF for it rather than "blended at 1.0". Ours reaches
/// the same pixels by staying on the one blend bracket every line batch uses,
/// where an alpha of exactly 1 is an identity.
///
/// Measured, not read: the disc's ink is the SAME 8-bit triple over two
/// viewport backdrops 38 levels apart. A stroke at 0.75 would have landed on
/// two different values there, and that is the whole test.
enum float GIZMO_ALPHA_ROTATE_DISC      = 1.00f;


// -- Pick regions (window pixels; NOT derived from the drawn shape) ---------
/// Half-width of the capsule around an arrow's projected start→end segment
/// that counts as a hit. Wider than anything drawn: the move arrow's shaft is
/// 2 px thick and its cone 7.5 px in radius, so the grab band comfortably
/// contains the visible arrow and extends 8 px PAST the drawn tip. Shared by
/// the move arrows, the scale stems and the falloff endpoint arrows.
///
/// Task 0600 narrowed the strokes and deliberately did NOT touch this. The
/// pick regions are not derived from the drawn shape (see the note below), and
/// a grab band that tracked the ink would have shrunk the gizmo's usable target
/// along with its stroke — the reference's own hit width is likewise
/// independent of, and for this gizmo NARROWER than, what it draws.
enum float GIZMO_PICK_AXIS_PX         = 8.0f;
/// Same, for a rotate ring's projected polyline. The arcs are drawn 2.5 px
/// thick, so this is again wider than the ink.
enum float GIZMO_PICK_RING_PX         = 8.0f;
/// Radius of the disc around a scale axis box's projected tip that counts as
/// a hit, in the `compact` (bare Transform) presentation only. 4.4x the drawn
/// 2.7 px box half-extent.
enum float GIZMO_PICK_SCALE_HEAD_PX   = 12.0f;

// The remaining pick regions are the DRAWN shape exactly, with no tolerance
// term to name: the centre box (point-in-projected-cube-silhouette), the
// plane circles (point-in-projected-32-gon) and the scale centre disc
// (point-within-projected-rim-radius).
//
// Task 0553 deliberately left that alone. The reference does carry a separate,
// larger HIT size beside each DRAW size — six independent globals, selected by
// a flag on the same draw call — but the mechanism is "re-emit the SAME
// geometry with the width constant swapped", not "inflate the drawn shape by a
// factor": nothing derives one from the other, the arm's LENGTH is identical
// in both passes (which is why the grab region ends exactly at the drawn arm),
// and for the transform gizmo specifically the draw stroke is a hardcoded 2.0
// while the hit stroke is the 1.25 preference — i.e. NARROWER, not wider. So
// "hit = 1.2x draw" is not a law the reference contains, and porting it would
// have been fitting. The 6-12 px hot half-width measured by hovering is still
// unexplained by any constant that has been read; our 8 px above sits inside
// that band and stays until it is.

// World-space size for a gizmo element at `pos` so that it occupies a
// constant pixel size on screen, regardless of FOV, camera distance, or
// window size. `scale` lets callers produce smaller/larger variants
// (e.g. 0.04 for box handles → ~4.8 px at the default 120-px target).
//
// Derivation: in column-major perspective, an NDC delta `dy_ndc` covers
// `dy_ndc * vp.height / 2` pixels, and a world-space length `L` at
// view-space depth `Z` produces `dy_ndc = L * proj[5] / Z`. Solving for L
// given a target pixel count:
//     L = 2 * px * Z / (proj[5] * vp.height)
float gizmoSize(Vec3 pos, const ref Viewport vp, float scale = 1.0f) {
    float depth = -(vp.view[2]*pos.x + vp.view[6]*pos.y + vp.view[10]*pos.z + vp.view[14]);
    if (depth < 1e-4f) depth = 1e-4f;
    // Defensive: a zero-height viewport (pre-init / off-screen) would
    // divide by zero. Fall back to a 1-px-equivalent so the gizmo is
    // visible but tiny rather than NaN.
    float vh = vp.height > 0 ? cast(float)vp.height : 1.0f;
    // Orthographic projections map world size to screen size independently
    // of view-space depth (no perspective divide) — the `depth` factor below
    // is only correct for perspective, where NDC size ~ 1/Z and `depth`
    // cancels distance to give a constant screen size. Dropping it here
    // keeps handles a constant pixel size at any ortho zoom (zoom changes
    // proj[5] via the ortho half-height, not depth).
    if (isOrtho(vp))
        return 2.0f * g_gizmoPixels * scale / (vp.proj[5] * vh);
    return 2.0f * g_gizmoPixels * scale * depth / (vp.proj[5] * vh);
}

// World-space length of `px` WINDOW PIXELS at `pos` — i.e. "model units per
// pixel", the same quantity the reference multiplies a plain pixel count by
// when a handle's size is specified in pixels rather than as a share of the
// arm (its plane ring's 8-px radius is the case that forced this seam; its
// ring OFFSET, in the same function, scales with the arm instead).
//
// Expressed through `gizmoSize` rather than repeating its derivation, so the
// two can never drift and `gizmoSize`'s bit-identity regression below keeps
// covering both. Independent of `g_gizmoPixels` by construction: the division
// here cancels the multiplication inside.
float gizmoPixelSize(Vec3 pos, const ref Viewport vp, float px) {
    return gizmoSize(pos, vp, px / g_gizmoPixels);
}

// ---------------------------------------------------------------------------
// WHICH HANDLES THIS VIEW CAN STILL USE — one predicate, four applications
// ---------------------------------------------------------------------------
//
// Task 0602. A handle whose screen offset has collapsed is not a small handle,
// it is a LIE: it sits on top of a sibling or on the gizmo centre, it cannot be
// dragged in any meaningful direction, and while it is still registered it goes
// on swallowing the clicks meant for whatever it is sitting on. The reference
// removes it — an early return before any stroke is emitted and before the part
// is published to the hit test, so a culled handle is invisible AND unclickable
// by construction, with no second geometry to keep in sync. Ours does the same
// with `Handler.setVisible(false)`, which both `draw()` and `ToolHandles.test()`
// already honour.
//
// WHAT THIS REPLACED, AND WHY IT WAS A GAP RATHER THAN A REGRESSION.
// Three copies of one idiom lived in `handles/shapes.d`, all gated on the cell
// being ORTHOGRAPHIC and all comparing against 0.999 (2.56 deg). The gate was
// backwards on two banks out of three and the threshold was too tight:
//
//   * MEASURED, the arm and plane-handle cull fires in EVERY projection. Ours
//     fired in none but ortho, so a perspective camera aimed down an axis left
//     a zero-length arm registered and grabbable, in front of whatever it had
//     collapsed onto.
//   * MEASURED to four decimals, four independent brackets in two runs across
//     three banks agree on 0.996 (5.126 deg) — a cone twice as wide as ours.
//   * The RING cull is the one that IS gated on the viewport, and by a viewport
//     TYPE lookup rather than any camera test (see `lockedViewAxis`).
//
// All three are stated once here and applied at their call sites, so the
// threshold and the eye-vector convention cannot drift between banks again.

/// How nearly a gizmo axis must point along the view ray before the handles
/// built on it are dropped. `acos(0.996) = 5.126 deg`.
///
/// MEASURED, not derived: the reference authors this as a plain decimal, not as
/// the cosine of a round angle, and four independent live brackets — the move
/// arm on two different sweeps, a scale shaft, and a plane handle appearing
/// rather than vanishing — all put the knee inside a 0.0004-wide window that
/// contains it.
enum float GIZMO_FACING_COS = 0.996f;

/// How nearly a rotate ring's normal must lie perpendicular to the view ray —
/// i.e. how nearly edge-on the ring must be — before it is dropped.
/// `asin(0.087) = 4.991 deg`. Read as the same "about five degrees" as
/// `GIZMO_FACING_COS`, measured from the other end.
enum float GIZMO_RING_EDGE_SIN = 0.087f;

/// True when `axis` points within `GIZMO_FACING_COS` of the ray this view looks
/// along through `gizmoCenter` — in either direction, towards the camera or
/// away from it.
///
/// `axis` need not be unit length; `gizmoCenter` is the GIZMO's origin, not the
/// individual handle's, and that is deliberate. The reference evaluates the eye
/// vector once at the position it pushes its handle transform with, so an arm
/// and the two plane handles that span it cross the threshold in the SAME frame
/// — which is a measured property of the reference, not an implementation
/// detail (an arm at 0.99581 and its plane handle both drew; at 0.99620 both
/// were gone). Using each part's own offset centre would stagger them.
bool axisFacesViewer(Vec3 axis, Vec3 gizmoCenter, const ref Viewport vp)
    @safe pure nothrow @nogc
{
    immutable Vec3 eye = eyeVectorAt(vp, gizmoCenter);
    return abs(dot(normalize(axis), eye)) >= GIZMO_FACING_COS;
}

/// True when the plane handle spanning `u` and `v` must be dropped.
///
/// THE RULE IS ABOUT THE TWO AXES THE PLANE SPANS, NOT ABOUT ITS NORMAL, and
/// that distinction is measured rather than assumed. A neighbouring helper in
/// the reference's own framework does test the normal — "hide the handle when
/// its plane is edge-on" — and it is the answer this would have got by
/// reasoning from what the handle is for. It is wrong for this gizmo: held
/// exactly edge-on through a 90-degree sweep, the reference's plane handle
/// stayed DRAWN at every elevation, a 16 px line, and vanished only where one
/// of its two in-plane axes crossed 0.996.
///
/// The rule that survives is not "hide it when you cannot see the plane" but
/// "hide it when its own offset collapses": the handle sits on the diagonal of
/// its two axes, so when either of them points at the camera the handle lands
/// on the other axis's arm or on the gizmo centre with nothing to say.
bool planeHandleHidden(Vec3 u, Vec3 v, Vec3 gizmoCenter, const ref Viewport vp)
    @safe pure nothrow @nogc
{
    return axisFacesViewer(u, gizmoCenter, vp)
        || axisFacesViewer(v, gizmoCenter, vp);
}

/// True when the rotate ring about `normal` must be dropped.
///
/// The only cull of the four that is GATED ON THE VIEWPORT, and the gate is a
/// viewport-type question — "is this one of the axis views?" — that never asks
/// where the camera is pointing. `lockedViewAxis` is how we ask it (an ortho
/// projection whose forward is a world axis); in a perspective cell it answers
/// -1 and no ring is ever culled, however the camera is aimed.
///
/// Inside an axis view, a ring goes when it is within ~5 degrees of EDGE-ON.
/// Note the polarity: this drops the unusable rings and keeps everything else,
/// which is not the same rule as keeping only the face-on one. The two agree
/// exactly when the gizmo's basis is the world basis — one axis at the eye, two
/// perpendicular, so "keep the face-on one" and "drop the edge-on ones" select
/// the same single ring — and they diverge the moment the gizmo carries a
/// rotated basis (a work plane, a local cluster, an element frame). At 45
/// degrees "keep only the face-on one" keeps NOTHING, and the gizmo loses all
/// three of its axis rings while both of them are perfectly grabbable. That
/// case is reachable here and is the reason this is the ported rule.
bool rotateRingHidden(Vec3 normal, Vec3 gizmoCenter, const ref Viewport vp)
    @safe pure nothrow @nogc
{
    if (lockedViewAxis(vp) < 0) return false;
    immutable Vec3 eye = eyeVectorAt(vp, gizmoCenter);
    return abs(dot(normalize(normal), eye)) < GIZMO_RING_EDGE_SIN;
}


unittest {
    import std.math : abs;

    // Build a simple lookAt view (camera at +Z looking at origin, +Y up).
    float[16] view = lookAt(Vec3(0, 0, 10), Vec3(0, 0, 0), Vec3(0, 1, 0));

    // --- Perspective regression: gizmoSize must equal the ORIGINAL
    // expression byte-for-byte (the perspective return is verbatim-unchanged,
    // so this is an exact `==`, not a tolerance compare).
    {
        Viewport vp;
        vp.view   = view;
        vp.proj   = perspectiveMatrix(PI / 4, 1.0f, 0.1f, 100.0f);
        vp.height = 600;
        Vec3 pos = Vec3(1, 2, 3);
        float scale = 1.5f;

        float depth = -(vp.view[2]*pos.x + vp.view[6]*pos.y + vp.view[10]*pos.z + vp.view[14]);
        if (depth < 1e-4f) depth = 1e-4f;
        float vh = vp.height > 0 ? cast(float)vp.height : 1.0f;
        float expected = 2.0f * g_gizmoPixels * scale * depth / (vp.proj[5] * vh);

        assert(gizmoSize(pos, vp, scale) == expected,
               "perspective gizmoSize must be bit-identical to the original expression");
    }

    // --- Ortho depth-independence: two positions at different view-space
    // depths must yield the SAME screen size (this fails before the fix,
    // since the old formula scaled linearly with depth even in ortho).
    {
        Viewport vp;
        vp.view   = view;
        vp.proj   = orthographicMatrix(5.0f, 1.0f, 0.1f, 100.0f);
        vp.height = 600;
        Vec3 posNear = Vec3(0, 0, 8);  // close to the camera (view-space Z small)
        Vec3 posFar  = Vec3(0, 0, -8); // far from the camera (view-space Z large)

        float sNear = gizmoSize(posNear, vp);
        float sFar  = gizmoSize(posFar, vp);
        assert(abs(sNear - sFar) < 1e-6f,
               "ortho gizmoSize must be depth-independent");
    }

    // --- Ortho zoom-linearity: halving halfH (zooming in) must halve the
    // world-space gizmo size (constant screen size ⇒ world size ∝ extent).
    {
        Viewport vpWide, vpNarrow;
        vpWide.view   = view;
        vpWide.proj   = orthographicMatrix(10.0f, 1.0f, 0.1f, 100.0f);
        vpWide.height = 600;
        vpNarrow.view   = view;
        vpNarrow.proj   = orthographicMatrix(5.0f, 1.0f, 0.1f, 100.0f);
        vpNarrow.height = 600;

        Vec3 pos = Vec3(0, 0, 0);
        float sWide   = gizmoSize(pos, vpWide);
        float sNarrow = gizmoSize(pos, vpNarrow);
        assert(abs(sNarrow - sWide * 0.5f) < 1e-6f,
               "halving ortho halfH must halve gizmoSize");
    }
}
