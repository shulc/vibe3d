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
// independent of viewport height — the transform gizmos stay ~90 px tall
// regardless of window size. The previous semantic was "fraction of
// viewport height", which made the gizmo grow with the window.
// ---------------------------------------------------------------------------

private float g_gizmoPixels = 90.0f;  // ~90px gizmo arm at any vp height

void  setGizmoPixels(float px)  { g_gizmoPixels = px; }
float getGizmoPixels()          { return g_gizmoPixels; }

// World-space size for a gizmo element at `pos` so that it occupies a
// constant pixel size on screen, regardless of FOV, camera distance, or
// window size. `scale` lets callers produce smaller/larger variants
// (e.g. 0.04 for box handles → ~3.6 px at the default 90-px target).
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
