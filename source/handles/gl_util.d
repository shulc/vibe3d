module handles.gl_util;

import bindbc.opengl;
import std.math : sqrt, PI, abs;
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
/// Centre-box HALF-extent, fraction of the arm. → 4.8 px half / 9.6 px across.
enum float GIZMO_CENTER_BOX_HALF      = 0.04f;
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
/// View-plane ring radius, fraction of the arm. → 99 px.
enum float GIZMO_VIEW_RING_RADIUS     = 1.10f;

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
/// Half-extent of the LIVE (drag-feedback) scale box, fraction of the arm.
/// → 2.7 px. The STATIC axis box uses GIZMO_CUBE_HEAD_HALF_OF_LEN below,
/// which is relative to the stem length, and lands at 2.80 px — the two are
/// deliberately-looking but genuinely different quantities.
enum float GIZMO_SCALE_BOX_HALF       = 0.03f;
/// Centre-disc radius, fraction of the arm. → 7.2 px.
enum float GIZMO_DISC_RADIUS          = 0.08f;

// -- Arrow head proportions, relative to the ARROW's own length -------------
// NOTE these are shared with every other Arrow/CubicArrow user (primitive
// create-tool movers, falloff endpoint handles), not just the transform
// gizmo — changing them moves those handles too.
/// Cone head length as a fraction of the arrow's length. → 18.75 px on the
/// move arrow (whose shaft is 75 px long).
enum float GIZMO_CONE_LEN_OF_LEN      = 0.25f;
/// Cone head base radius as a fraction of the arrow's length. → 3.75 px.
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
    // fragment colour is `u_color * u_dim` (layers Stage 5 dim feature).
    // A GLSL uniform defaults to 0, so an unset `u_dim` renders every
    // gizmo shaft / rotate ring / scale axis BLACK. These lines are never
    // dimmed (the background-layer dim pass only touches the Shader /
    // LitShader programs, never this one), so seed `u_dim` to the neutral
    // 1.0 once here. Guarded for forward-compat in case the shared
    // fragment shader ever drops the uniform.
    GLint locDim = glGetUniformLocation(prog, "u_dim");
    if (locDim >= 0) {
        GLint prevProg;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
        glUseProgram(prog);
        glUniform1f(locDim, 1.0f);
        glUseProgram(prevProg);
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
        glBindVertexArray(0);
        glUseProgram(restoreProgram);
    }
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

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
