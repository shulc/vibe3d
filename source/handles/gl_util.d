module handles.gl_util;

import bindbc.opengl;
import std.math : sqrt, PI, abs;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import gl_thread_guard : glThreadGuard;
import shader : seedSharedFragUniforms;
import math;

// ---------------------------------------------------------------------------
// Thick-line shader state — set once from app.d via initThickLineProgram().
// All handlers use this program to draw line geometry.
// ---------------------------------------------------------------------------

private struct ThickLineState {
    GLuint prog;
    GLint  locModel, locView, locProj, locColor, locWidth, locScreen, locAlpha;
    GLint  locSmooth;
    float  screenW, screenH;
}
private ThickLineState g_thickLine;

// ---------------------------------------------------------------------------
// Translucent-fill shader state — set once from app.d via initFillProgram()
// (mirrors initThickLineProgram). Backs drawWorldQuad, which alpha-blends a
// solid overlay polygon (the Slice tool's cut-plane preview). Its own program
// so the opaque gizmo/mesh draws stay untouched.
// ---------------------------------------------------------------------------
private struct FillState {
    GLuint prog;
    GLint  locModel, locView, locProj, locColor, locAlpha;
}
private FillState g_fill;

// ---------------------------------------------------------------------------
// Reference-image plane shader state (task 0612) — set once from app.d via
// initImagePlaneProgram(). Its own program: the first `sampler2D` in the
// build, with a second vertex attribute (the texture coordinate) no other
// pass has.
// ---------------------------------------------------------------------------
private struct ImagePlaneState {
    GLuint prog;
    GLint  locView, locProj, locTex;
    GLint  locBrightness, locContrast, locTransparency, locInvert;
}
private ImagePlaneState g_imagePlane;

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

unittest {
    // ONE literal on every gizmo line batch — and after task 0604 this identity
    // is what keeps `GIZMO_ALPHA_ARM` pinned at all.
    //
    // The arm now reaches the framebuffer through TWO emissions (see
    // ShaftedArrow.doubledShaft), so its observed opacity is `1-(1-a)^2`. That
    // curve is nearly flat at the top: its slope is `2(1-a)`, i.e. 0.1 at
    // a = 0.95, so moving the arm's alpha by 0.05 moves the composite by 0.005
    // — well under one 8-bit level over any background contrast the viewport
    // offers. A pixel test therefore CANNOT bracket the arm's own literal any
    // more; the best it can do is exclude a single emission, which is a
    // statement about the doubling and not about the value.
    //
    // The rotate ring is emitted ONCE at the same measured literal, so its
    // composite still moves 1:1 with it and tests/test_gizmo_handle_alpha.d
    // Flow B brackets it from both sides at the pixel. This assertion is the
    // link that carries that bracket back to the arm: drift either constant on
    // its own and the chain breaks here, loudly, with the reason attached.
    assert(GIZMO_ALPHA_ARM == GIZMO_ALPHA_ROTATE_RING,
           "the arm and the rotate ring are the same measured line alpha. If "
           ~ "one really has to change, the other's pixel bracket stops "
           ~ "standing in for it — give the arm its own measurable pin first");
}

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
    // The threshold is a CONE, and it is bracketed from both sides here so
    // that moving the constant in either direction fails a case.
    import std.math : cos, sin, PI;

    static Viewport perspAt(Vec3 eye) {
        Viewport vp;
        vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
        vp.eye  = eye;
        vp.width = 800; vp.height = 600;
        return vp;
    }

    // A camera 5.5 deg off the X axis: X is INSIDE the 5.126 deg cone at 4.5
    // and OUTSIDE it at 5.5, and the arm must follow.
    foreach (degOff; [0.0f, 2.0f, 4.5f, 5.0f, 5.5f, 10.0f, 45.0f]) {
        immutable float r = degOff * cast(float)PI / 180.0f;
        auto vp = perspAt(Vec3(10.0f * cos(r), 0, 10.0f * sin(r)));
        immutable bool hidden = axisFacesViewer(Vec3(1, 0, 0), Vec3(0, 0, 0), vp);
        immutable bool expect = degOff < 5.126f;
        assert(hidden == expect,
               "the X arm's cull must switch exactly at 5.126 deg");
    }

    // PERSPECTIVE IS NOT EXEMPT. This is the half our old rule could not do:
    // the camera above is perspective throughout, and the 0-deg case must hide.
    {
        auto vp = perspAt(Vec3(10, 0, 0));
        assert(axisFacesViewer(Vec3(1, 0, 0), Vec3(0, 0, 0), vp),
               "an axis pointing straight at a PERSPECTIVE camera is culled too");
    }

    // The eye vector is per-point, so a gizmo away from the focus is judged by
    // the ray through ITSELF. Camera on +Z looking at the origin: the Z axis
    // faces it at the origin, and a gizmo pushed far along +X does not.
    {
        auto vp = perspAt(Vec3(0, 0, 10));
        assert(axisFacesViewer(Vec3(0, 0, 1), Vec3(0, 0, 0), vp));
        assert(!axisFacesViewer(Vec3(0, 0, 1), Vec3(8, 0, 0), vp));
    }

    // The plane handle takes its two SPANNED axes. With X pointing at the
    // camera, the two handles whose planes CONTAIN X go, and the one normal to
    // X — the only one seen face-on — stays. That is the reference's own
    // per-projection table for an axis view, restated as a predicate.
    {
        auto vp = perspAt(Vec3(10, 0, 0));
        immutable Vec3 X = Vec3(1, 0, 0), Y = Vec3(0, 1, 0), Z = Vec3(0, 0, 1);
        assert( planeHandleHidden(X, Y, Vec3(0, 0, 0), vp), "XY spans X");
        assert( planeHandleHidden(X, Z, Vec3(0, 0, 0), vp), "XZ spans X");
        assert(!planeHandleHidden(Y, Z, Vec3(0, 0, 0), vp), "YZ does not span X");
    }

    // THE DISCRIMINATOR between the two candidate plane rules, as the reference
    // measured it: hold a plane exactly edge-on and sweep. The XY plane's
    // normal is Z; with the camera in the XY plane the normal is perpendicular
    // to the view ray at EVERY elevation, so a normal-based rule would hide
    // this handle throughout. The spanned-axes rule keeps it except in the two
    // narrow cones, and the spanned-axes rule is the measured one.
    foreach (elDeg; [10.0f, 30.0f, 45.0f, 60.0f, 80.0f]) {
        immutable float e = elDeg * cast(float)PI / 180.0f;
        auto vp = perspAt(Vec3(10.0f * cos(e), 10.0f * sin(e), 0));
        assert(!planeHandleHidden(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 0), vp),
               "an edge-on plane handle stays drawn away from its axes' cones");
    }

    // Rotate: the gate is the viewport TYPE, so a perspective cell keeps every
    // ring however it is aimed — including the two that are exactly edge-on.
    {
        auto vp = perspAt(Vec3(0, 0, 10));
        assert(!rotateRingHidden(Vec3(1, 0, 0), Vec3(0, 0, 0), vp));
        assert(!rotateRingHidden(Vec3(0, 1, 0), Vec3(0, 0, 0), vp));
        assert(!rotateRingHidden(Vec3(0, 0, 1), Vec3(0, 0, 0), vp));
    }

    // ...and an ortho axis view drops exactly the edge-on ones. With the world
    // basis that leaves one ring, which is what the reference shows in each of
    // its axis views; with a basis rotated 45 deg about Y it leaves TWO, where
    // "keep only the face-on ring" would have left none.
    {
        Viewport vp;
        vp.view = lookAt(Vec3(0, 0, 10), Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = orthographicMatrix(2.0f, 1.0f, 0.001f, 100.0f);
        vp.eye  = Vec3(0, 0, 10);
        vp.width = 800; vp.height = 600;
        assert(lockedViewAxis(vp) == 2, "fixture premise: this is a Z axis view");

        assert( rotateRingHidden(Vec3(1, 0, 0), Vec3(0, 0, 0), vp), "X ring edge-on");
        assert( rotateRingHidden(Vec3(0, 1, 0), Vec3(0, 0, 0), vp), "Y ring edge-on");
        assert(!rotateRingHidden(Vec3(0, 0, 1), Vec3(0, 0, 0), vp), "Z ring face-on");

        immutable float s = cast(float)(1.0 / 1.4142135623730951);
        immutable Vec3 rx = Vec3( s, 0, -s), ry = Vec3(0, 1, 0), rz = Vec3(s, 0, s);
        assert(!rotateRingHidden(rx, Vec3(0, 0, 0), vp), "a 45 deg ring is usable");
        assert( rotateRingHidden(ry, Vec3(0, 0, 0), vp), "...its Y sibling is not");
        assert(!rotateRingHidden(rz, Vec3(0, 0, 0), vp), "...and so is its partner");
    }
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

void initThickLineProgram(GLuint prog, int screenW, int screenH) {
    g_thickLine.prog      = prog;
    g_thickLine.locModel  = glGetUniformLocation(prog, "u_model");
    g_thickLine.locView   = glGetUniformLocation(prog, "u_view");
    g_thickLine.locProj   = glGetUniformLocation(prog, "u_proj");
    g_thickLine.locColor  = glGetUniformLocation(prog, "u_color");
    g_thickLine.locWidth  = glGetUniformLocation(prog, "u_lineWidth");
    g_thickLine.locScreen = glGetUniformLocation(prog, "u_screenSize");
    // Now WRITTEN per draw (the per-part alphas), not merely seeded — but the
    // seeding below stays, because a program whose very first draw forgot to
    // pass one would still be reaching for a 0.
    g_thickLine.locAlpha  = glGetUniformLocation(prog, "u_alpha");
    // The per-shape smoothing request (task 0610). WRITTEN on every draw, like
    // `u_lineWidth` and unlike `u_alpha` was — `drawThickLines` is the single
    // funnel every line batch in the app passes through, so this uniform is
    // never read stale and is NOT a `kSharedFragNeutrals` obligation. It is
    // seeded below anyway, for the one case the funnel does not cover: a future
    // path that binds this program and draws without going through that
    // function would otherwise get GL's default 0 and render EVERY line
    // hard-edged, which is a silent whole-app regression rather than a crash.
    g_thickLine.locSmooth = glGetUniformLocation(prog, "u_smooth");
    g_thickLine.screenW   = cast(float)screenW;
    g_thickLine.screenH   = cast(float)screenH;

    // The thick-line program reuses the basic `fragmentShaderSrc`, whose
    // fragment colour is `vec4(u_color * u_dim, u_alpha)`. A GLSL uniform
    // defaults to 0, and 0 is the destructive value for BOTH of those: an
    // unset `u_dim` renders every gizmo shaft / rotate ring / scale axis
    // BLACK, and an unset `u_alpha` writes them into the cell's FBO with zero
    // coverage — which the ImGui composite of that colour texture then blends
    // away, so the lines read as the panel grey behind them. Neither uniform
    // is ever written on this program's draw path, so both are seeded to
    // neutral once, here.
    //
    // This used to seed `u_dim` alone, by hand. `u_alpha` was added
    // to the shared fragment source later (task 0559) and this builder was not
    // updated, which is exactly the greyed-lines bug. Seeding now goes through
    // `shader.seedSharedFragUniforms`, which owns the full neutral list, so a
    // future uniform on the shared source cannot reach only one of its two
    // programs again.
    seedSharedFragUniforms(prog);

    // ...and `u_smooth`'s own neutral. Not part of that list on purpose: the
    // list is the contract of the SHARED fragment source, and this uniform
    // exists on the thick-line source alone. Same bind-and-restore discipline,
    // for the same reason (a builder runs during init, with some other program
    // possibly bound).
    if (g_thickLine.locSmooth >= 0) {
        GLint prevProg;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
        glUseProgram(prog);
        glUniform1f(g_thickLine.locSmooth, 1.0f);
        glUseProgram(cast(GLuint)prevProg);
    }
}

/// Update the cached screen dimensions used by drawThickLines for the current
/// FBO cell.  Call at the top of renderViewportSceneToFbo (after glViewport)
/// so each cell supplies its own (w, h) before its overlay gizmos draw.
/// Does NOT re-query uniform locations — cheap enough to call once per cell.
/// Note: g_thickLine.screenW/H is now a per-cell scratch value, not a static
/// config; initThickLineProgram sets the initial value but this overrides it
/// per cell before every real draw.
void setThickLineScreenSize(int w, int h) {
    g_thickLine.screenW = cast(float)w;
    g_thickLine.screenH = cast(float)h;
}

// Upload a float[] (XYZ triples) to a fresh VAO with a single vec3 attribute at location 0.
// Fills *vbo with the created buffer object and returns the VAO.
package GLuint buildVao3f(float[] data, out GLuint vbo) {
    // Funnel 1 of 2. Every Handler shape's geometry lands here, and because a
    // Tool builds its gizmo banks in its own ctor, so does every Tool — which
    // is why "call a registry factory off the main thread" and "call GL off
    // the main thread" are the same act. See gl_thread_guard.d.
    glThreadGuard("buildVao3f");
    version(unittest) {
        vbo = 0;
        return 0;
    } else {
        GLuint vao;
        glGenVertexArrays(1, &vao);
        glGenBuffers(1, &vbo);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, data.length * float.sizeof, data.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
        return vao;
    }
}

// Compute a right-handed local frame from a normal/forward vector.
// right and up are perpendicular to normal and to each other.
package void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp  = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}

// Build unit-cube triangle data (half-extent 1, 6 faces × 2 tris × 3 verts)
// into an existing float array.  CubicArrow and BoxHandler share this geometry.
package void buildUnitCubeData(ref float[] data) {
    immutable float[3][8] v = [
        [-1,-1,-1], [ 1,-1,-1], [ 1, 1,-1], [-1, 1,-1],  // back
        [-1,-1, 1], [ 1,-1, 1], [ 1, 1, 1], [-1, 1, 1],  // front
    ];
    immutable int[6][6] faces = [
        [0,1,2, 2,3,0], // -Z
        [4,6,5, 6,4,7], // +Z
        [0,4,5, 5,1,0], // -Y
        [2,6,7, 7,3,2], // +Y
        [0,3,7, 7,4,0], // -X
        [1,5,6, 6,2,1], // +X
    ];
    foreach (ref f; faces)
        foreach (idx; f)
            data ~= v[idx][];
}

// ---------------------------------------------------------------------------
// The transform gizmo's ARROWHEAD — a closed tetrahedron, not a cone.
//
// Unit space, exactly the space `Arrow.draw` scales it through:
//   X = the first lateral direction, Y = the second, Z = the arm's own axis.
//
//     T = (0,0,1)   the apex, ON the axis, at the arm's outer end
//     C = (0,0,0)   a base corner, also ON the axis
//     A = (1,0,0)   a base corner, one lateral out
//     B = (0,1,0)   a base corner, the other lateral out
//
// SHAPE, NOT SIZE — this is the whole finding. The measured half-width
// (`gizmoHeadHalfPx`) is the OFFSET of two base corners from the axis, and the
// third corner sits on the axis. So the base is a right isoceles triangle with
// its right angle on the arm's line: the head reaches its full half-width on
// ONE side and exactly ZERO on the other, and what the camera changes is which
// way it leans. Its drawn width therefore breathes between H and H*sqrt(2) as
// the view rolls about the arm, instead of standing at 2H from every angle.
// A cone of revolution cannot express that at any radius, which is why fixing
// this by re-tuning `gizmoHeadHalfPx` is not available — the constant is
// confirmed against drawn pixels and it is the mesh that was wrong.
//
// WINDING, and why it is stated here rather than assumed. `HandleFacing` above
// records that our two existing solids disagree about winding, so a third one
// may not simply inherit either. The reference emits these four faces in a
// MIXED winding — three one way, one the other — because it never culls, so
// its vertex order carries no information beyond WHICH four faces. We do cull
// (a translucent closed solid under a depth-off pass would otherwise composite
// itself three deep and lose its alpha), so all four are emitted here
// consistently OUTWARD-CCW. That puts this shape on `HandleFacing.outwardCCW`,
// the same value the cone it replaces already used. The unittest below
// re-derives every face normal from the emitted floats and checks it points
// away from the solid's own centroid, so the claim is proved from the data
// rather than asserted in prose.
// ---------------------------------------------------------------------------
package void buildWedgeHeadData(ref float[] data) {
    static immutable float[3][4] pt = [
        [0, 0, 1],   // 0 = T, the apex
        [0, 0, 0],   // 1 = C, the on-axis base corner
        [1, 0, 0],   // 2 = A, one lateral out
        [0, 1, 0],   // 3 = B, the other lateral out
    ];
    static immutable int[3][4] face = [
        [0, 1, 2],   // T C A — the Y=0 side,     outward -Y
        [1, 0, 3],   // C T B — the X=0 side,     outward -X
        [0, 2, 3],   // T A B — the slanted side, outward +(1,1,1)
        [3, 2, 1],   // B A C — the base CAP,     outward -Z
    ];
    foreach (ref f; face)
        foreach (idx; f)
            data ~= pt[idx][];
}

unittest {
    // The arrowhead is a CLOSED, CAPPED tetrahedron wound uniformly outward,
    // and its body sits in one quadrant. Every claim below is re-derived from
    // the emitted floats; none of it reads a constant back to itself.
    import std.algorithm : canFind, map, sort;
    import std.array     : array;
    import std.math      : abs;

    float[] d;
    buildWedgeHeadData(d);
    assert(d.length == 4 * 3 * 3,
           "the head must be 4 triangles / 12 vertices / 36 floats");

    static Vec3 vert(const float[] d, size_t i) {
        return Vec3(d[i*3], d[i*3 + 1], d[i*3 + 2]);
    }
    static bool same(Vec3 a, Vec3 b) {
        return abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f;
    }

    // 1. Exactly FOUR distinct points, and they are the four the card names.
    Vec3[] uniq;
    foreach (i; 0 .. 12) {
        auto v = vert(d, i);
        bool seen = false;
        foreach (u; uniq) if (same(u, v)) { seen = true; break; }
        if (!seen) uniq ~= v;
    }
    assert(uniq.length == 4,
           "twelve vertices must close on four points — the head is a tetrahedron");
    foreach (want; [Vec3(0,0,1), Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)]) {
        bool found = false;
        foreach (u; uniq) if (same(u, want)) { found = true; break; }
        assert(found, "a base/apex point of the arrowhead is missing");
    }

    // 2. The ONE-QUADRANT claim, restated as REACH rather than as coordinates:
    //    the head extends a full unit along each lateral on the POSITIVE side
    //    and nothing at all on the negative one — which is why the drawn head
    //    is H across and not 2H. Check 1 already pins the four points, so this
    //    cannot fail on its own; it is kept because it says in one line what
    //    the shape is FOR, and it is the line that would have to be deleted,
    //    not merely edited, to put a symmetric head back.
    float minX = 0, maxX = 0, minY = 0, maxY = 0;
    foreach (u; uniq) {
        if (u.x < minX) minX = u.x;  if (u.x > maxX) maxX = u.x;
        if (u.y < minY) minY = u.y;  if (u.y > maxY) maxY = u.y;
    }
    assert(maxX == 1.0f && minX == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");
    assert(maxY == 1.0f && minY == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");

    // 3. CLOSED and CAPPED: the four triangles are the four distinct 3-subsets
    //    of the four points, each appearing exactly once. A missing base cap
    //    (three faces) or a doubled face both fail here.
    int[][] faceKeys;
    foreach (f; 0 .. 4) {
        int[] key;
        foreach (k; 0 .. 3) {
            auto v = vert(d, f*3 + k);
            foreach (idx, u; uniq) if (same(u, v)) { key ~= cast(int)idx; break; }
        }
        assert(key.length == 3, "a face names a point that is not one of the four");
        assert(key[0] != key[1] && key[1] != key[2] && key[0] != key[2],
               "a face repeats a vertex — that triangle has no area");
        key.sort();
        assert(!faceKeys.canFind(key), "a face of the head is emitted twice");
        faceKeys ~= key;
    }
    assert(faceKeys.length == 4, "the head must have all four faces, cap included");

    // 4. WINDING: every face's CCW normal points AWAY from the solid's own
    //    centroid, i.e. the whole shape is outward-CCW and `outwardCCW` is the
    //    correct HandleFacing for it. This is the assertion that catches a
    //    face copied over with the reference's own (mixed) vertex order.
    Vec3 cen = Vec3(0,0,0);
    foreach (u; uniq) cen = cen + u;
    cen = cen / 4.0f;
    foreach (f; 0 .. 4) {
        auto p0 = vert(d, f*3), p1 = vert(d, f*3 + 1), p2 = vert(d, f*3 + 2);
        auto n  = cross(p1 - p0, p2 - p0);
        assert(dot(n, p0 - cen) > 1e-6f,
               "an arrowhead face is wound INWARD; culling GL_BACK would open "
               ~ "a hole in the solid and its alpha would stack twice there");
    }
}

// ---------------------------------------------------------------------------
// The handle pass's BLEND BRACKET.
//
// The reference requests blending PER PRIMITIVE BATCH, from a tag on the
// batch's begin call, and turns it back off for the next batch that does not
// ask. Our closest analogue to "a batch" is one of these draw helpers, so the
// bracket lives here rather than around the whole pass — the same granularity,
// and no call site can forget it.
//
// The equation is the reference's for COLOUR and deliberately not for ALPHA.
// Colour is plain `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`, which is the one blend
// function the reference sets (once, per viewport resize) and therefore the one
// every translucent handle of its own composites through. The alpha channel
// takes `ZERO / ONE` — destination alpha is left exactly as it was.
//
// That asymmetry is not a liberty; it is what porting to our target requires.
// The reference blends into a window whose alpha nobody reads afterwards. We
// blend into a CELL FBO whose colour texture ImGui then composites using that
// very alpha channel, so a translucent stroke that let its own 0.95 through to
// the destination would punch a 5 %-transparent hole in the cell and the panel
// behind would show through the gizmo. `mesh_gpu.d`'s wireframe pass already
// took this exact decision for this exact reason; this follows it.
// ---------------------------------------------------------------------------

/// Enable the handle pass's blend equation, returning the previous GL_BLEND
/// enable so the caller can restore it. See the block comment above.
private bool beginHandleBlend() {
    immutable bool had = glIsEnabled(GL_BLEND) == GL_TRUE;
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
    return had;
}

/// Undo `beginHandleBlend`. Restores the ENABLE bit to what it was and the
/// blend function to the app-wide default that every other bracket in the
/// codebase (`mesh_gpu.d`, `slice_tool.d`, `ui/panels.d`) also restores to.
private void endHandleBlend(bool hadBlend) {
    if (!hadBlend) glDisable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

/// The winding convention of a solid handle shape, i.e. which face has to be
/// culled to leave its OUTWARD surface. See `beginHandleFill` for why a
/// translucent solid must be culled at all.
///
/// The two shapes disagree, and the values below are derived rather than
/// guessed. For the cone (`buildConeData` in shapes.d) a side triangle
/// apex→P0→P1 at the base point (1,0,0) has normal ∝ (1,0,1) — radially out
/// and toward the apex, i.e. OUTWARD — so its front faces (default `GL_CCW`)
/// face out and the BACK ones are the far side. For the unit cube
/// (`buildUnitCubeData`) the -Z face 0→1→2 has normal ∝ +Z while its outward
/// normal is -Z, so that shape is wound the other way and its FRONT faces are
/// the far side.
///
/// The cube's winding is left alone deliberately. Nothing culls it today, so
/// the inversion is invisible and "fixing" it would be an unmeasured change to
/// geometry six other handle types share.
/// The transform gizmo's tetrahedral arrowhead (`buildWedgeHeadData` above) is
/// a THIRD solid and it does not inherit either convention by assumption: its
/// four faces are emitted outward-CCW on purpose, proved by the unittest beside
/// the builder. It nonetheless draws `twoLayer` — see that value.
enum HandleFacing {
    outwardCCW,   /// front faces point out — cull GL_BACK  (the cone head)
    outwardCW,    /// front faces point in  — cull GL_FRONT (the unit cube)
    flat,         /// not a solid: ONE layer already, so cull nothing
    /// A closed CONVEX solid drawn deliberately UNCULLED, so every pixel inside
    /// its silhouette composites exactly TWICE — once through the near face,
    /// once through the far one. Not an oversight and not the absence of a
    /// decision: it is the measured behaviour of the reference's arrowhead,
    /// which never culls, and the two layers are what put that head at
    /// `1-(1-a)^2` rather than at `a`. Legal only where the solid is convex
    /// AND closed (a concave one could stack three or more layers on one ray,
    /// which is the runaway `beginHandleFill` culls to prevent); the tetrahedron
    /// qualifies, and the unittest beside `buildWedgeHeadData` is what keeps it
    /// qualifying.
    twoLayer,
}

/// Bracket a translucent SOLID (triangle) handle batch drawn on the SHARED
/// program — the arrowhead cone, the scale boxes, the plane fill disc.
/// `locAlpha` is `Shader.locAlpha`; pass the part's alpha.
///
/// Returns an opaque token for `endHandleFill`. At `alpha >= 1` this issues NO
/// GL calls at all and the draw stays byte-identical to the unblended path it
/// replaced — which is what keeps the opaque parts (the centre box) off this
/// change's blast radius entirely.
///
/// WHY IT CULLS. The handle pass runs with DEPTH TESTING OFF, because handles
/// are overlays. A closed solid then rasterises every one of its faces onto the
/// same pixels — for the cone, the near side, the far side and the base cap.
/// While it was opaque that was invisible: three writes of one colour. Blended,
/// it is three composites, and 0.95 stacked three deep is 0.999875 — i.e. the
/// part renders effectively OPAQUE and the alpha silently does nothing.
/// Measured exactly that way before this cull existed: the shaft came back at
/// the predicted `0.95*axis + 0.05*bg` while the cone beside it came back at
/// the raw axis colour. Culling leaves one layer per pixel, so the alpha means
/// what it says. The silhouette is unchanged — these are convex solids.
///
/// AND WHY THE ARROWHEAD IS NOW EXEMPT (task 0604). That reasoning was right in
/// kind and overshot by one shape. The reference does NOT cull, and its head is
/// a tetrahedron: convex and closed, so a ray through it crosses exactly TWO
/// faces, not three. Two layers at 0.95 is 0.9975, and 0.9975 is what the
/// reference's arm was measured at, photometrically, across a 74-level
/// background change (its observed colour did not move, excluding a single
/// 0.95 emission by 6.4 levels). Culling the head to one layer is therefore not
/// "the alpha meaning what it says" — it is our head landing 10 levels lighter
/// than the one it is a port of. So the head passes `HandleFacing.twoLayer` and
/// keeps both layers, while every other translucent solid here — the scale
/// boxes, and any concave or many-layered shape a later part brings — keeps the
/// cull. The exemption is per shape, decided at the call site, never global.
///
/// Solid geometry is NOT antialiased here and must not be: the reference never
/// enables polygon smoothing and explicitly disables multisampling, and its
/// arrowhead was measured stepping background-to-full with no intermediate
/// value. This bracket buys TRANSPARENCY, not soft edges.
int beginHandleFill(GLint locAlpha, float alpha,
                    HandleFacing facing = HandleFacing.outwardCCW) {
    if (!(alpha < 1.0f) || locAlpha < 0) return -1;   // NaN-safe: !(nan < 1) is true
    glUniform1f(locAlpha, alpha);
    immutable bool hadBlend = beginHandleBlend();
    // Two shapes cull NOTHING, for opposite reasons, and bit 2 of the token
    // records that so `endHandleFill` restores no cull state either.
    //   `flat`     — the plane handle's fill disc is a triangle FAN whose
    //                triangles tile the disc without overlapping, so it already
    //                composites exactly once. It must not GET a cull: a flat fan
    //                seen from its other side is entirely back-facing, and
    //                culling would make the plane handle vanish depending on
    //                which way the camera is.
    //   `twoLayer` — the arrowhead, which is SUPPOSED to composite twice
    //                because the shape it ports does. See the enum.
    if (facing == HandleFacing.flat || facing == HandleFacing.twoLayer)
        return (hadBlend ? 1 : 0) | 4;
    immutable bool hadCull = glIsEnabled(GL_CULL_FACE) == GL_TRUE;
    glEnable(GL_CULL_FACE);
    glCullFace(facing == HandleFacing.outwardCCW ? GL_BACK : GL_FRONT);
    return (hadBlend ? 1 : 0) | (hadCull ? 2 : 0);
}

/// Close `beginHandleFill`, restoring the blend and cull state AND the shared
/// program's `u_alpha` to opaque. Restoring the uniform is not optional: the
/// same program draws the mesh, and a leaked 0.95 would quietly make the whole
/// model translucent on the next frame.
void endHandleFill(GLint locAlpha, int token) {
    if (token < 0) return;
    if ((token & 4) == 0) {                 // bit 2 set == `flat`, nothing culled
        if ((token & 2) == 0) glDisable(GL_CULL_FACE);
        glCullFace(GL_BACK);                // the GL default, and the app's
    }
    endHandleBlend((token & 1) != 0);
    if (locAlpha >= 0) glUniform1f(locAlpha, 1.0f);
}

// Draw VAO with GL_LINES/GL_LINE_STRIP using the thick-line program,
// then restore the caller's program.
//
// Blending is enabled UNCONDITIONALLY here, even at `alpha == 1`, because the
// analytic antialiasing works through the alpha channel: the fragment stage
// multiplies coverage into alpha, and with blending off a half-covered fringe
// pixel would simply be written at full colour and the smoothing would vanish.
// A line batch is exactly the case the reference also always blends, since
// every gizmo stroke it emits carries an alpha below 1.
//
// That last clause is no longer true of every stroke (task 0610: the rotate
// bank's backing disc carries no alpha at all and is not smoothed), and the
// unconditional blend stays right for it anyway. At `smooth = false, alpha = 1`
// every fragment this stage emits is either fully opaque or exactly zero, so a
// `SRC_ALPHA` blend is an identity on both — and the alpha channel is written
// `GL_ZERO / GL_ONE` (see `beginHandleBlend`), so the zero-coverage fragments
// outside the stroke cannot punch a hole in the cell FBO's own alpha either.
// Keeping ONE blend bracket for all line batches is worth more than saving the
// two GL calls a special case would.
package void drawThickLines(GLuint vao, int vertCount, GLenum mode,
                             const ref float[16] model,
                             const ref Viewport vp,
                             Vec3 color, float lineWidth,
                             GLuint restoreProgram,
                             float alpha = 1.0f,
                             bool smooth = true)
{
    glUseProgram(g_thickLine.prog);
    glUniformMatrix4fv(g_thickLine.locModel, 1, GL_FALSE, model.ptr);
    glUniformMatrix4fv(g_thickLine.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(g_thickLine.locProj,  1, GL_FALSE, vp.proj.ptr);
    glUniform3f(g_thickLine.locColor, color.x, color.y, color.z);
    glUniform1f(g_thickLine.locWidth, lineWidth);
    glUniform2f(g_thickLine.locScreen, g_thickLine.screenW, g_thickLine.screenH);
    if (g_thickLine.locAlpha >= 0) glUniform1f(g_thickLine.locAlpha, alpha);
    if (g_thickLine.locSmooth >= 0)
        glUniform1f(g_thickLine.locSmooth, smooth ? 1.0f : 0.0f);

    immutable bool hadBlend = beginHandleBlend();
    glBindVertexArray(vao);
    glDrawArrays(mode, 0, vertCount);
    g_fc.draw(DrawPass.handles, vertCount);
    endHandleBlend(hadBlend);

    glUseProgram(restoreProgram);
}

// Public thin wrapper around drawThickLines for callers outside handler.d
// (e.g. MoveTool's constraint-line overlay).  Same semantics as the private
// version; the `restoreProgram` is typically shader.program.
void drawThickLinesExt(GLuint vao, int vertCount, GLenum mode,
                       const ref float[16] model,
                       const ref Viewport vp,
                       Vec3 color, float lineWidth,
                       GLuint restoreProgram,
                       float alpha = 1.0f,
                       bool smooth = true)
{
    drawThickLines(vao, vertCount, mode, model, vp, color, lineWidth,
                   restoreProgram, alpha, smooth);
}

// Lazily-built unit-segment VAO ([0,0,0]→[0,0,1]) shared by tools that draw a
// single world-space line via the thick-line program (e.g. the Slice tool's
// Start→End line). Built on first use inside a live GL context (skipped under
// -unittest, where buildVao3f returns 0 and glDrawArrays is a no-op).
private GLuint g_segVao, g_segVbo;
private bool   g_segReady;

/// Draw a thick world-space line from `a` to `b` using the shared thick-line
/// program (screen-constant pixel `width`), then restore `restoreProgram`.
/// Maps the unit segment onto a→b with the same model-matrix trick Arrow's
/// shaft uses, so no per-frame VBO churn is needed.
void drawWorldSegment(Vec3 a, Vec3 b, const ref Viewport vp,
                      Vec3 color, float width, GLuint restoreProgram,
                      float alpha = 1.0f)
{
    if (!g_segReady) {
        g_segVao = buildVao3f([0f,0f,0f,  0f,0f,1f], g_segVbo);
        g_segReady = true;
    }
    Vec3 dir = b - a;
    float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
    if (len < 1e-6f) return;
    Vec3 fwd = dir / len;
    Vec3 right, up;
    localFrame(fwd, right, up);
    auto model = modelMatrix(right, up, fwd, Vec3(1, 1, len), a);
    drawThickLines(g_segVao, 2, GL_LINES, model, vp, color, width,
                   restoreProgram, alpha);
}

// Register the translucent-fill program (compiled in app.d from
// shader.fillFragSrc), mirroring initThickLineProgram. Backs drawWorldQuad.
void initFillProgram(GLuint prog) {
    g_fill.prog     = prog;
    g_fill.locModel = glGetUniformLocation(prog, "u_model");
    g_fill.locView  = glGetUniformLocation(prog, "u_view");
    g_fill.locProj  = glGetUniformLocation(prog, "u_proj");
    g_fill.locColor = glGetUniformLocation(prog, "u_color");
    g_fill.locAlpha = glGetUniformLocation(prog, "u_alpha");
}

// Lazily-built dynamic VAO for drawWorldQuad's 4 world-space corners.
private GLuint g_quadVao, g_quadVbo;
private bool   g_quadReady;

/// Draw a solid, alpha-blended quad through the four world-space `corners`
/// (CCW, as a triangle fan) using the fill program, then restore
/// `restoreProgram`. The CALLER owns the GL_BLEND / depth-test state (this
/// only swaps the program + VAO), matching how drawWorldSegment leaves blend
/// to its caller. Corners are uploaded to a small dynamic VBO each call (12
/// floats) so a live-updating overlay needs no per-frame VAO rebuild.
void drawWorldQuad(Vec3[4] corners, const ref Viewport vp,
                   Vec3 color, float alpha, GLuint restoreProgram)
{
    version(unittest) {
        // No GL context under -unittest; the corner geometry is exercised by
        // the pure sliceOverlay* helpers instead.
    } else {
        if (!g_quadReady) {
            glGenVertexArrays(1, &g_quadVao);
            glGenBuffers(1, &g_quadVbo);
            glBindVertexArray(g_quadVao);
            glBindBuffer(GL_ARRAY_BUFFER, g_quadVbo);
            glBufferData(GL_ARRAY_BUFFER, 12 * float.sizeof, null, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
            g_quadReady = true;
        }
        float[12] data = [
            corners[0].x, corners[0].y, corners[0].z,
            corners[1].x, corners[1].y, corners[1].z,
            corners[2].x, corners[2].y, corners[2].z,
            corners[3].x, corners[3].y, corners[3].z,
        ];
        glBindBuffer(GL_ARRAY_BUFFER, g_quadVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0, data.sizeof, data.ptr);

        glUseProgram(g_fill.prog);
        glUniformMatrix4fv(g_fill.locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(g_fill.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(g_fill.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(g_fill.locColor, color.x, color.y, color.z);
        glUniform1f(g_fill.locAlpha, alpha);
        glBindVertexArray(g_quadVao);
        glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
        g_fc.draw(DrawPass.handles, 4);
        glBindVertexArray(0);
        glUseProgram(restoreProgram);
    }
}

// Register the reference-image-plane program (compiled in app.d from
// shader.imagePlaneVertSrc / imagePlaneFragSrc), mirroring initFillProgram.
// Backs drawImagePlane.
//
// `u_tex` is bound to texture unit 0 ONCE, here, rather than on every draw:
// a sampler uniform is program state, the draw always binds its texture to
// unit 0, and re-writing it per frame would be a uniform whose value can
// never differ between calls.
void initImagePlaneProgram(GLuint prog) {
    g_imagePlane.prog            = prog;
    g_imagePlane.locView         = glGetUniformLocation(prog, "u_view");
    g_imagePlane.locProj         = glGetUniformLocation(prog, "u_proj");
    g_imagePlane.locTex          = glGetUniformLocation(prog, "u_tex");
    g_imagePlane.locBrightness   = glGetUniformLocation(prog, "u_brightness");
    g_imagePlane.locContrast     = glGetUniformLocation(prog, "u_contrast");
    g_imagePlane.locTransparency = glGetUniformLocation(prog, "u_transparency");
    g_imagePlane.locInvert       = glGetUniformLocation(prog, "u_invert");
    GLint prevProg;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
    glUseProgram(prog);
    if (g_imagePlane.locTex >= 0) glUniform1i(g_imagePlane.locTex, 0);
    glUseProgram(cast(GLuint) prevProg);
}

// Lazily-built dynamic VAO for drawImagePlane's 4 textured world corners.
private GLuint g_planeVao, g_planeVbo;
private bool   g_planeReady;

/// Draw one reference-image plane: the quad `center ± halfU ± halfV`, textured
/// with `tex`, graded by the three look scalars, as a `GL_TRIANGLE_FAN`.
///
/// STATE DISCIPLINE, and each line of it is load-bearing:
///
/// * **`glDisable(GL_DEPTH_TEST)`**, restored after. Disabling the test also
///   suppresses depth WRITES, so this pass leaves the depth buffer exactly as
///   the FBO clear left it and every later pass wins regardless of world
///   position. That is the point: the walkthrough puts the reference image on
///   the mid-line at X=0 and models symmetric geometry straddling it — under
///   ordinary depth testing half the model would be swallowed by the picture
///   behind it. `glDepthMask(GL_FALSE)` — the other house idiom, used by the
///   slice preview — keeps the depth TEST on, which is right for a translucent
///   plane that must be occluded by the geometry it cuts and exactly wrong
///   for a backdrop.
/// * **`glBlendFuncSeparate(..., GL_ZERO, GL_ONE)`**, not `glBlendFunc`. The
///   cell renders into an FBO whose alpha is a real attachment that ImGui
///   composites; a naive `glBlendFunc` with `transparency > 0` eats the
///   cell's alpha and makes the whole viewport translucent. Same reasoning,
///   same fix as `mesh_gpu.d`'s translucent passes.
/// * **culling off**, restored. The plane is two-sided: a `front` reference
///   seen from behind in a perspective cell still draws. (Whether the
///   reference editor culls it is unmeasured — the capture's perspective
///   camera was in front of the plane — so this is our choice, stated.)
/// * **the filter comes from the plane's `smooth` channel**, set on the bound
///   texture per draw. The texture object is shared by every plane on the
///   same file, so two planes disagreeing about `smooth` would each set it
///   before their own draw; the redundancy is deliberate and cheap, and the
///   alternative (baking the filter at upload time) would make the channel
///   silently ignored for the second consumer of a shared file.
void drawImagePlane(Vec3 center, Vec3 halfU, Vec3 halfV,
                    bool flipU, bool invert, bool smooth,
                    float brightness, float contrast, float transparency,
                    GLuint tex, const ref Viewport vp, GLuint restoreProgram)
{
    version(unittest) {
        // No GL context under -unittest. The corner geometry this would upload
        // is `image_plane.resolvePlacement`'s output, which is asserted there
        // as numbers — deliberately, because a pixel is the END of this
        // pipeline and a mismatch in it localises nothing.
    } else {
        if (tex == 0) return;   // not resident: skip. NEVER decode from a draw.
        if (!g_planeReady) {
            glGenVertexArrays(1, &g_planeVao);
            glGenBuffers(1, &g_planeVbo);
            glBindVertexArray(g_planeVao);
            glBindBuffer(GL_ARRAY_BUFFER, g_planeVbo);
            glBufferData(GL_ARRAY_BUFFER, 20 * float.sizeof, null, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * float.sizeof,
                                  cast(void*)(3 * float.sizeof));
            glEnableVertexAttribArray(1);
            glBindVertexArray(0);
            g_planeReady = true;
        }

        // Fan order: -U-V, +U-V, +U+V, -U+V. The texture's row 0 is the
        // image's TOP row (that is how the decoder hands it over and how it is
        // uploaded), so v = 0 is the top and the -V corners take v = 1.
        //
        // `flipU` swaps the u coordinates and leaves the CORNERS alone. Doing
        // it the other way — negating `halfU` — would mirror the plane's
        // PLACEMENT as well as its pixels, moving the image to the other side
        // of the item's centre instead of mirroring it in place.
        immutable float u0 = flipU ? 1.0f : 0.0f;
        immutable float u1 = flipU ? 0.0f : 1.0f;
        Vec3 c0 = center - halfU - halfV;
        Vec3 c1 = center + halfU - halfV;
        Vec3 c2 = center + halfU + halfV;
        Vec3 c3 = center - halfU + halfV;
        float[20] data = [
            c0.x, c0.y, c0.z, u0, 1.0f,
            c1.x, c1.y, c1.z, u1, 1.0f,
            c2.x, c2.y, c2.z, u1, 0.0f,
            c3.x, c3.y, c3.z, u0, 0.0f,
        ];
        glBindBuffer(GL_ARRAY_BUFFER, g_planeVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0, data.sizeof, data.ptr);

        immutable bool hadCull  = glIsEnabled(GL_CULL_FACE) == GL_TRUE;
        immutable bool hadDepth = glIsEnabled(GL_DEPTH_TEST) == GL_TRUE;
        immutable bool hadBlend = glIsEnabled(GL_BLEND) == GL_TRUE;
        if (hadCull) glDisable(GL_CULL_FACE);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);

        glUseProgram(g_imagePlane.prog);
        glUniformMatrix4fv(g_imagePlane.locView, 1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(g_imagePlane.locProj, 1, GL_FALSE, vp.proj.ptr);
        glUniform1f(g_imagePlane.locBrightness,   brightness);
        glUniform1f(g_imagePlane.locContrast,     contrast);
        glUniform1f(g_imagePlane.locTransparency, transparency);
        glUniform1f(g_imagePlane.locInvert,       invert ? 1.0f : 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex);
        immutable GLint filt = smooth ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);

        glBindVertexArray(g_planeVao);
        glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
        g_fc.draw(DrawPass.imagePlane, 4);
        glBindVertexArray(0);
        glBindTexture(GL_TEXTURE_2D, 0);

        // Restore: the blend func back to the house default, then the three
        // enables to whatever the caller had.
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        if (!hadBlend) glDisable(GL_BLEND);
        if (hadDepth)  glEnable(GL_DEPTH_TEST);
        if (hadCull)   glEnable(GL_CULL_FACE);
        glUseProgram(restoreProgram);
    }
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

// Task 0597 — the four CLAMPED ornaments, sampled ACROSS their knees.
//
// This is the coverage the bug got past. Every one of these sizes used to be a
// flat fraction of the arm, which is correct at the shipped default and wrong
// everywhere else — so a test that only checked the default would have passed
// on the broken code. Each assertion below therefore samples BELOW the floor,
// AT the default and ABOVE the ceiling, and the ceiling rows are the load-
// bearing ones: they are what a fraction-of-the-arm implementation fails.
//
// The values are restated here as literals rather than recomputed from the
// enums, so that moving an enum has to fail here. They come from a live sweep
// of the reference over the full handle-scale range, both ends of every clamp.
unittest {
    import std.math : abs;

    immutable float saved = getGizmoPixels();
    scope(exit) setGizmoPixels(saved);

    static bool near(float a, float b) { return abs(a - b) < 1e-4f; }

    // handle scale -> (head length px, head half-width px, box half px).
    // 0.5  : the reachable floor. The two box clamps are ON their floor here
    //        (0.75 * 5 = 3.75, not 0.5 * 5 = 2.5) and the head half-width is
    //        on its floor too (4, not 60/16 = 3.75) — the floors are what stop
    //        the ornaments shrinking away on `-`.
    // 1.0  : the shipped default. Every value sits strictly inside its band
    //        except the boxes, which sit at the band's centre. A broken
    //        implementation agrees with all of these, which is the point.
    // 1.25 : the knee. Head length reaches its ceiling exactly here; the head
    //        half-width (knee 1.2) and the boxes (knee 1.25) are already at
    //        theirs.
    // 5.0  : the reachable ceiling — a 4x longer arm than 1.25 and a 10x
    //        longer arm than 0.5, with all three ornaments bit-identical to
    //        their 1.25 row. This row alone refutes "a fraction of the arm".
    static immutable float[4][6] rows = [
        // ts     headLen  headHalf  boxHalf
        [0.5f,    12.0f,    4.0f,    3.75f],
        [0.75f,   18.0f,    5.625f,  3.75f],   // still on the box floor
        [1.0f,    24.0f,    7.5f,    5.00f],
        [1.2f,    28.8f,    9.0f,    6.00f],   // half-width knee, boxes still rising
        [1.25f,   30.0f,    9.0f,    6.25f],   // length + box knees
        [5.0f,    30.0f,    9.0f,    6.25f],   // 4x the arm, identical ornaments
    ];

    foreach (r; rows) {
        setGizmoHandleScale(r[0]);
        assert(near(gizmoHandleScale(), r[0]), "the preference did not round-trip");
        assert(near(gizmoHeadLenPx(),  r[1]), "arrowhead length off its clamped law");
        assert(near(gizmoHeadHalfPx(), r[2]), "arrowhead half-width off its clamped law");
        assert(near(gizmoBoxHalfPx(),  r[3]), "box half-extent off its clamped law");
    }

    // The ceiling rows must be EXACT, not merely close: the reference's own
    // sharpest reading is that two very different arms give a bit-identical
    // box, and that is the property a ratio can never have.
    setGizmoHandleScale(1.25f);
    immutable float lenAtKnee = gizmoHeadLenPx();
    immutable float halfAtKnee = gizmoHeadHalfPx();
    immutable float boxAtKnee = gizmoBoxHalfPx();
    setGizmoHandleScale(5.0f);
    assert(gizmoHeadLenPx()  == lenAtKnee,  "arrowhead length still grows past its knee");
    assert(gizmoHeadHalfPx() == halfAtKnee, "arrowhead width still grows past its knee");
    assert(gizmoBoxHalfPx()  == boxAtKnee,  "box still grows past its knee");

    // ... and the floor rows likewise, against the OTHER failure mode: an
    // implementation with only the ceiling ported shrinks these on `-`.
    setGizmoHandleScale(0.5f);
    immutable float boxAtFloor = gizmoBoxHalfPx();
    setGizmoHandleScale(0.75f);
    assert(gizmoBoxHalfPx() == boxAtFloor, "box shrinks below its floor on `-`");

    // The line-draw coupling: the arrowhead's half-width is GEOMETRY, and the
    // stroke width multiplies it. Measured on the reference at the default
    // handle size: 1.0 -> 8.0 takes the half-width 7.5 px -> 30 px. At or
    // below the 2.0 floor the factor is exactly 1.0, so our default is inert.
    setGizmoHandleScale(1.0f);
    assert(gizmoHeadHalfPx(8.0f) == 30.0f, "line width must scale the arrowhead");
    assert(gizmoHeadHalfPx(1.0f) == gizmoHeadHalfPx(2.0f),
           "line widths under the 2.0 floor must be indistinguishable");
    assert(gizmoHeadHalfPx(float.nan) == gizmoHeadHalfPx(2.0f),
           "a NaN line width must take the floor, not poison the geometry");
}

// Task 0597 — the `-` / `+` ladder: ten LINEAR steps, saturating at both ends.
unittest {
    import std.math : abs;

    immutable float saved = getGizmoPixels();
    scope(exit) setGizmoPixels(saved);

    // Walk up from the shipped default and collect every arm length the user
    // can reach. The reference's reachable set is exactly {0.5, 1.0 ... 5.0},
    // i.e. 60, 120 ... 600 px — a linear ladder, where ours was nine geometric
    // steps 50..480. Sizes are exact in binary floating point at every rung,
    // so these are `==`, not tolerance compares.
    setGizmoHandleScale(1.0f);
    assert(getGizmoPixels() == 120.0f, "the default arm must stay 120 px");

    float[] up;
    foreach (_; 0 .. 12) { stepGizmoHandleScale(+1); up ~= getGizmoPixels(); }
    assert(up[0] == 180.0f && up[1] == 240.0f && up[2] == 300.0f);
    assert(up[7] == 600.0f, "eight presses from the default must reach 600 px");
    assert(up[$ - 1] == 600.0f, "`+` past the ceiling must saturate, not wrap");

    float[] down;
    setGizmoHandleScale(1.0f);
    foreach (_; 0 .. 4) { stepGizmoHandleScale(-1); down ~= getGizmoPixels(); }
    assert(down[0] == 60.0f, "one `-` from the default must reach the floor");
    assert(down[$ - 1] == 60.0f, "`-` past the floor must saturate");

    // The step is a CONSTANT 60 px of arm, not a ratio — the property that
    // decides whether a clamped ornament is ever seen changing.
    setGizmoHandleScale(1.0f);
    float prev = getGizmoPixels();
    foreach (_; 0 .. 8) {
        stepGizmoHandleScale(+1);
        assert(abs((getGizmoPixels() - prev) - 60.0f) < 1e-4f,
               "the ladder must be linear in the arm, not geometric");
        prev = getGizmoPixels();
    }

    // Clamp-on-write, independent of the stepping path — the reference clamps
    // in its setter so its keyboard and preference paths cannot disagree.
    setGizmoHandleScale(0.2f);   assert(getGizmoPixels() == 60.0f);
    setGizmoHandleScale(99.0f);  assert(getGizmoPixels() == 600.0f);
    setGizmoHandleScale(float.nan);
    assert(getGizmoPixels() == 60.0f, "a NaN preference must land on the floor");
}

// setThickLineScreenSize writes both cached dimensions without touching GL.
// Guards against regressing to the global-init-only path (single cell).
unittest {
    float oldW = g_thickLine.screenW, oldH = g_thickLine.screenH;
    scope(exit) { g_thickLine.screenW = oldW; g_thickLine.screenH = oldH; }
    setThickLineScreenSize(320, 240);
    assert(g_thickLine.screenW == 320.0f);
    assert(g_thickLine.screenH == 240.0f);
    setThickLineScreenSize(1920, 1080);
    assert(g_thickLine.screenW == 1920.0f);
    assert(g_thickLine.screenH == 1080.0f);
}
