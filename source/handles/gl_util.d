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
    GLint  locModel, locView, locProj, locColor, locWidth, locScreen;
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
/// Axis box distance from the centre, fraction of the arm. → 120 px, i.e.
/// the SAME point the move arrow's tip reaches.
///
/// Task 0553: was 1.18, which put the scale boxes 18 % beyond the move tips.
/// The reference ends both banks' arms at the same `screenLength`; the
/// stagger was ours. (Its scale CUBE is centred 5 px inside that end, on a
/// line that still runs the full length — a distinction our CubicArrow
/// cannot draw, since `end` is at once the stem's end and the head's centre.
/// Splitting those two would license the remaining 5 px; nothing else does.)
enum float GIZMO_SCALE_ARM            = 1.00f;
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

// -- Pick regions (window pixels; NOT derived from the drawn shape) ---------
/// Half-width of the capsule around an arrow's projected start→end segment
/// that counts as a hit. Wider than anything drawn: the move arrow's shaft is
/// 5 px thick and its cone 3.75 px in radius, so the grab band is ~2x the
/// visible arrow and extends 8 px PAST the drawn tip. Shared by the move
/// arrows, the scale stems and the falloff endpoint arrows.
enum float GIZMO_PICK_AXIS_PX         = 8.0f;
/// Same, for a rotate ring's projected polyline. The principal arcs are drawn
/// 6 px thick and the view ring 4 px, so this is again wider than the ink.
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

// Draw VAO with GL_LINES/GL_LINE_STRIP using the thick-line program,
// then restore the caller's program.
package void drawThickLines(GLuint vao, int vertCount, GLenum mode,
                             const ref float[16] model,
                             const ref Viewport vp,
                             Vec3 color, float lineWidth,
                             GLuint restoreProgram)
{
    glUseProgram(g_thickLine.prog);
    glUniformMatrix4fv(g_thickLine.locModel, 1, GL_FALSE, model.ptr);
    glUniformMatrix4fv(g_thickLine.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(g_thickLine.locProj,  1, GL_FALSE, vp.proj.ptr);
    glUniform3f(g_thickLine.locColor, color.x, color.y, color.z);
    glUniform1f(g_thickLine.locWidth, lineWidth);
    glUniform2f(g_thickLine.locScreen, g_thickLine.screenW, g_thickLine.screenH);
    glBindVertexArray(vao);
    glDrawArrays(mode, 0, vertCount);
    g_fc.draw(DrawPass.handles, vertCount);
    glUseProgram(restoreProgram);
}

// Public thin wrapper around drawThickLines for callers outside handler.d
// (e.g. MoveTool's constraint-line overlay).  Same semantics as the private
// version; the `restoreProgram` is typically shader.program.
void drawThickLinesExt(GLuint vao, int vertCount, GLenum mode,
                       const ref float[16] model,
                       const ref Viewport vp,
                       Vec3 color, float lineWidth,
                       GLuint restoreProgram)
{
    drawThickLines(vao, vertCount, mode, model, vp, color, lineWidth, restoreProgram);
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
                      Vec3 color, float width, GLuint restoreProgram)
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
    drawThickLines(g_segVao, 2, GL_LINES, model, vp, color, width, restoreProgram);
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
