module handler;
import bindbc.sdl;
import bindbc.opengl;

import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv : to;

import ai.advisor : AiAdvisor;
import ai.debug_trace : publishHandleDebugTrace;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import math;
import eventlog;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// HandleState — the handle selection model
// (unselected / rollover / selected / secondary default hint).
// One enum replaces the old hovered/selected bool soup at the colour-pick site.
// ---------------------------------------------------------------------------

enum HandleState { Normal, Rollover, Selected, SecondaryDefault }

private Vec3 handleStateColor(HandleState state, Vec3 base) {
    final switch (state) {
        case HandleState.Normal:           return base;
        case HandleState.Rollover:         return Vec3(1.0f, 0.95f, 0.15f);
        case HandleState.Selected:         return Vec3(1.0f, 0.64f, 0.0f);
        case HandleState.SecondaryDefault: return Vec3(0.55f, 0.75f, 1.0f);
    }
}

private AiAdvisor g_handleAiAdvisor;

void setHandleAiAdvisor(AiAdvisor advisor) {
    g_handleAiAdvisor = advisor;
}

private AiAdvisor handleAiAdvisor() {
    if (g_handleAiAdvisor is null)
        g_handleAiAdvisor = new AiAdvisor();
    return g_handleAiAdvisor;
}

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
    return 2.0f * g_gizmoPixels * scale * depth / (vp.proj[5] * vh);
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

// Upload a float[] (XYZ triples) to a fresh VAO with a single vec3 attribute at location 0.
// Fills *vbo with the created buffer object and returns the VAO.
private GLuint buildVao3f(float[] data, out GLuint vbo) {
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
private void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp  = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}

// Build unit-cube triangle data (half-extent 1, 6 faces × 2 tris × 3 verts)
// into an existing float array.  CubicArrow and BoxHandler share this geometry.
private void buildUnitCubeData(ref float[] data) {
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
private void drawThickLines(GLuint vao, int vertCount, GLenum mode,
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

// ---------------------------------------------------------------------------
// Handler — base class for interactive 3-D overlays (gizmos, manipulators…)
// ---------------------------------------------------------------------------

class Handler {
private:
    // Single source of truth for hover/selected/secondary-preview state.
    // Set by the central ToolHandles Test pass for registered handles; left at
    // the default Normal for draw-only (unregistered) handles, which therefore
    // never highlight — exactly as a handle absent from the
    // hit-test pass is treated.
    HandleState state = HandleState.Normal;
    bool   visible = true;

public:
    // Called once per frame to render the overlay into the 3-D view.
    void draw(const ref Shader shader, const ref Viewport vp) {}

    // Mouse events — return true to consume (stops further processing).
    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseButtonUp  (ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseMotion    (ref const SDL_MouseMotionEvent  e) { return false; }

    // Keyboard events — return true to consume.
    bool onKeyDown(ref const SDL_KeyboardEvent e) { return false; }
    bool onKeyUp  (ref const SDL_KeyboardEvent e) { return false; }

    // Hover/visible functions
    bool isHovered()    const { return state == HandleState.Rollover; }
    void setVisible(bool v)      { visible = v; if (!v) state = HandleState.Normal; }
    bool isVisible() const       { return visible; }

    // HandleState accessors — used by the ToolHandles arbiter.
    void setState(HandleState s) { state = s; }
    HandleState getState() const { return state; }

    // Override in subclasses to define the hover hit area.
    protected bool hitTest(int mx, int my, const ref Viewport vp) { return false; }
    protected float aiScreenDistance(int mx, int my, const ref Viewport vp) {
        return float.infinity;
    }
    protected AiIntent aiIntentForPart(int part) const {
        return AiIntent.handle;
    }
}

// ---------------------------------------------------------------------------
// ShaftedArrow : Handler — common base for Arrow and CubicArrow.
// Holds start/end/color, the shared shaft VAO, head VAO, destroy(), hitTest().
// ---------------------------------------------------------------------------

class ShaftedArrow : Handler {
    Vec3  start;
    Vec3  end;
    Vec3  color;
    float lineWidth = 5.0f;

protected:
    GLuint shaftVao, shaftVbo;
    GLuint headVao,  headVbo;
    int    headVertCount;

public:
    void destroy() {
        glDeleteVertexArrays(1, &shaftVao); glDeleteBuffers(1, &shaftVbo);
        glDeleteVertexArrays(1, &headVao);  glDeleteBuffers(1, &headVbo);
    }

    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return aiScreenDistance(mx, my, vp) < 8.0f;
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp)
    {
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, vp, sax, say, ndcZa) ||
            !projectToWindowFull(end,   vp, sbx, sby, ndcZb))
            return float.infinity;
        float t;
        return closestOnSegment2D(cast(float)mx, cast(float)my,
                                  sax, say, sbx, sby, t);
    }
}

// ---------------------------------------------------------------------------
// Arrow : ShaftedArrow — cone head.
// Unit shaft (0,0,0)→(0,0,1); unit cone tip at Z=1, base at Z=0 radius=1.
// ---------------------------------------------------------------------------

class Arrow : ShaftedArrow {
    enum CONE_SEGS = 16;

    this(Vec3 start, Vec3 end, Vec3 color) {
        this.start = start;
        this.end   = end;
        this.color = color;

        shaftVao = buildVao3f([0f,0f,0f,  0f,0f,1f], shaftVbo);

        float[] coneData;
        foreach (i; 0 .. CONE_SEGS) {
            float a0 = 2*PI *  i      / CONE_SEGS;
            float a1 = 2*PI * (i + 1) / CONE_SEGS;
            float c0 = cos(a0), s0 = sin(a0);
            float c1 = cos(a1), s1 = sin(a1);
            coneData ~= [0f,0f,1f,  c0,s0,0f,  c1,s1,0f];  // side face
            coneData ~= [0f,0f,0f,  c1,s1,0f,  c0,s0,0f];  // base cap (inward)
        }
        headVertCount = cast(int)(coneData.length / 3);
        headVao = buildVao3f(coneData, headVbo);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 dir = end - start;
        float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
        if (len < 1e-6f) return;
        Vec3 fwd = dir / len;
        Vec3 right, up;
        localFrame(fwd, right, up);

        float coneLen    = len * 0.25f;
        float coneRadius = len * 0.05f;
        float shaftLen   = len - coneLen;
        Vec3  coneBase   = end - fwd * coneLen;

        Vec3 c = handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto shaftModel = modelMatrix(right, up, fwd, Vec3(1, 1, shaftLen), start);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, shader.program);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        auto headModel = modelMatrix(right, up, fwd, Vec3(coneRadius, coneRadius, coneLen), coneBase);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }
}

// ---------------------------------------------------------------------------
// CubicArrow : ShaftedArrow — cube head.
// Like Arrow but with a small cube at the tip instead of a cone.
// ---------------------------------------------------------------------------

class CubicArrow : ShaftedArrow {
    float fixedCubeHalf = 0.0f;  // if > 0, overrides len*0.03 for the cube head
    Vec3  fixedDir      = Vec3(0,0,0);  // if non-zero, use this direction instead of end-start

    this(Vec3 start, Vec3 end, Vec3 color) {
        this.start = start;
        this.end   = end;
        this.color = color;

        shaftVao = buildVao3f([0f,0f,0f,  0f,0f,1f], shaftVbo);

        float[] cubeData;
        buildUnitCubeData(cubeData);
        headVertCount = cast(int)(cubeData.length / 3);
        headVao = buildVao3f(cubeData, headVbo);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 dir = end - start;
        float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
        if (len < 1e-6f) return;
        Vec3 fwd = (fixedDir.x != 0.0f || fixedDir.y != 0.0f || fixedDir.z != 0.0f)
            ? fixedDir
            : dir / len;
        Vec3 right, up;
        localFrame(fwd, right, up);

        float cubeHalf   = fixedCubeHalf > 0.0f ? fixedCubeHalf : len * 0.03f;
        Vec3  cubeCenter = end - fwd * cubeHalf;

        // When end is behind start (dot < 0), shaft goes from cube's back face to start.
        float dotFwd = dir.x*fwd.x + dir.y*fwd.y + dir.z*fwd.z;
        Vec3  shaftOrigin;
        float shaftLen;
        if (dotFwd >= 0.0f) {
            shaftOrigin = start;
            shaftLen    = len - cubeHalf * 2;
        } else {
            shaftOrigin = end + fwd * cubeHalf;
            shaftLen    = len - cubeHalf;
        }
        if (shaftLen < 0.0f) shaftLen = 0.0f;

        Vec3 c = handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto shaftModel = modelMatrix(right, up, fwd, Vec3(1, 1, shaftLen), shaftOrigin);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, shader.program);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    void drawHeadOnly(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 dir = end - start;
        float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
        if (len < 1e-6f) return;
        Vec3 fwd = (fixedDir.x != 0.0f || fixedDir.y != 0.0f || fixedDir.z != 0.0f)
            ? fixedDir
            : dir / len;
        Vec3 right, up;
        localFrame(fwd, right, up);

        float cubeHalf   = fixedCubeHalf > 0.0f ? fixedCubeHalf : len * 0.03f;
        Vec3  cubeCenter = end - fwd * cubeHalf;
        Vec3 c = handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }
}

// ---------------------------------------------------------------------------
// SemicircleHandler : Handler
// Draws a half-circle arc (0..π) with a given color.
// Highlights on hover (yellow); toggles selected state on click (orange).
// ---------------------------------------------------------------------------

class SemicircleHandler : Handler {
    Vec3  center;
    Vec3  normal;   // axis perpendicular to the plane of the arc
    float radius;
    Vec3  color;
    float lineWidth  = 5.0f;
    float startAngle = 0.0f;  // arc begins at this angle (radians) in the local XY plane

private:
    GLuint arcVao, arcVbo;

    enum SEGS = 32;

public:
    this(Vec3 center, Vec3 normal, float radius, Vec3 color) {
        this.center = center;
        this.normal = normal;
        this.radius = radius;
        this.color  = color;

        // Unit semicircle in XY plane: (cos a, sin a, 0) for a ∈ [0, π].
        float[] arcData;
        foreach (i; 0 .. SEGS + 1) {
            float a = cast(float)i * PI / SEGS;
            arcData ~= [cos(a), sin(a), 0.0f];
        }
        arcVao = buildVao3f(arcData, arcVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &arcVao);
        glDeleteBuffers(1, &arcVbo);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 fwd = normalize(normal);
        Vec3 right, up;
        localFrame(normal, right, up);

        Vec3 c = handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        float ca = cos(startAngle), sa = sin(startAngle);
        Vec3 rr = right * ca + up * sa;
        Vec3 ru = up * ca - right * sa;
        auto model = modelMatrix(rr, ru, fwd,
                                 Vec3(radius, radius, radius), center);
        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth, shader.program);

        glEnable(GL_DEPTH_TEST);
        // Restore main program's u_model to identity
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    // Set startAngle so the arc begins at the direction of `dir` in the arc plane.
    // `dir` is projected onto the local right/up frame; its angle becomes startAngle.
    void setStartDirection(Vec3 dir) {
        Vec3 right, up;
        localFrame(normal, right, up);
        float dx = dot(dir, right);
        float dy = dot(dir, up);
        import std.math : atan2;
        startAngle = atan2(dy, dx);
    }

    // Fresh hit test — does not rely on cached hover state; used by ToolHandles.test.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return aiScreenDistance(mx, my, vp) < 8.0f;
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp)
    {
        Vec3 right, up;
        localFrame(normal, right, up);
        float[2][SEGS + 1] pts;
        bool[SEGS + 1]     valid;
        float best = float.infinity;
        foreach (i; 0 .. SEGS + 1) {
            float a = startAngle + cast(float)i * PI / SEGS;
            Vec3 w = center + right * (cos(a) * radius) + up * (sin(a) * radius);
            float sx, sy, ndcZ;
            valid[i] = projectToWindowFull(w, vp, sx, sy, ndcZ);
            pts[i]   = [sx, sy];
        }
        foreach (i; 0 .. SEGS) {
            if (!valid[i] || !valid[i + 1]) continue;
            float t;
            float d = closestOnSegment2D(cast(float)mx, cast(float)my,
                                         pts[i][0], pts[i][1],
                                         pts[i+1][0], pts[i+1][1], t);
            if (d < best) best = d;
        }
        return best;
    }
}

// ---------------------------------------------------------------------------
// FullCircleHandler : Handler — full 360° circle in an arbitrary plane.
// Used for the camera-view-plane rotation ring on the RotateHandler.
// ---------------------------------------------------------------------------

class FullCircleHandler : Handler {
    Vec3  center;
    Vec3  normal;   // axis perpendicular to the circle plane (camera forward)
    float radius;
    Vec3  color;
    float lineWidth = 3.0f;

private:
    GLuint arcVao, arcVbo;
    enum SEGS = 64;

public:
    this(Vec3 center, Vec3 normal, float radius, Vec3 color) {
        this.center = center;
        this.normal = normal;
        this.radius = radius;
        this.color  = color;

        // Unit full circle in XY plane: (cos a, sin a, 0) for a ∈ [0, 2π]
        float[] arcData;
        foreach (i; 0 .. SEGS + 1) {
            float a = cast(float)i * 2.0f * PI / SEGS;
            arcData ~= [cos(a), sin(a), 0.0f];
        }
        arcVao = buildVao3f(arcData, arcVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &arcVao);
        glDeleteBuffers(1, &arcVbo);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 fwd = normalize(normal);
        Vec3 right, up;
        localFrame(normal, right, up);

        Vec3 c = handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto model = modelMatrix(right, up, fwd,
                                 Vec3(radius, radius, radius), center);
        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth, shader.program);

        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    // Fresh hit test — does not rely on cached hover state; used by ToolHandles.test.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return aiScreenDistance(mx, my, vp) < 8.0f;
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp)
    {
        Vec3 right, up;
        localFrame(normal, right, up);
        float[2][SEGS + 1] pts;
        bool[SEGS + 1]     valid;
        float best = float.infinity;
        foreach (i; 0 .. SEGS + 1) {
            float a = cast(float)i * 2.0f * PI / SEGS;
            Vec3 w = center + right * (cos(a) * radius) + up * (sin(a) * radius);
            float sx, sy, ndcZ;
            valid[i] = projectToWindowFull(w, vp, sx, sy, ndcZ);
            pts[i]   = [sx, sy];
        }
        foreach (i; 0 .. SEGS) {
            if (!valid[i] || !valid[i + 1]) continue;
            float t;
            float d = closestOnSegment2D(cast(float)mx, cast(float)my,
                                         pts[i][0], pts[i][1],
                                         pts[i+1][0], pts[i+1][1], t);
            if (d < best) best = d;
        }
        return best;
    }
}

// ---------------------------------------------------------------------------
// MoveHandler : Handler — three axis arrows (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class MoveHandler : Handler {
    Vec3  center;
    Arrow         arrowX, arrowY, arrowZ;
    BoxHandler    centerBox;
    CircleHandler circleXY, circleYZ, circleXZ;
    Vec3 viewDir;
    // World-space orientation triple. Defaults to identity (world XYZ);
    // setOrientation rotates the gizmo into an arbitrary basis (e.g. the
    // active workplane). Used by draw() for arrow tip / circle normal
    // directions and by drag.d for axis-aligned plane normals.
    Vec3 axisX = Vec3(1, 0, 0);
    Vec3 axisY = Vec3(0, 1, 0);
    Vec3 axisZ = Vec3(0, 0, 1);
    void setOrientation(Vec3 ax, Vec3 ay, Vec3 az) {
        axisX = ax; axisY = ay; axisZ = az;
    }

    this(Vec3 center) {
        this.center = center;
        arrowX    = new Arrow(center + Vec3(0.1f,0,0), center + Vec3(1,0,0), Vec3(0.9f, 0.2f, 0.2f));
        arrowY    = new Arrow(center + Vec3(0,0.1f,0), center + Vec3(0,1,0), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ    = new Arrow(center + Vec3(0,0,0.1f), center + Vec3(0,0,1), Vec3(0.2f, 0.2f, 0.9f));
        centerBox = new BoxHandler(center, Vec3(0.0f, 0.9f, 0.9f));
        // XY plane (Z normal) — blue tint
        circleXY  = new CircleHandler(center + Vec3(1, 1,0), Vec3(0,0,1), 1.0f,
                        Vec3(0.2f, 0.2f, 0.9f), Vec3(0.1f, 0.1f, 0.4f));
        // YZ plane (X normal) — red tint
        circleYZ  = new CircleHandler(center + Vec3(0,1,1), Vec3(1,0,0), 1.0f,
                        Vec3(0.9f, 0.2f, 0.2f), Vec3(0.4f, 0.1f, 0.1f));
        // XZ plane (Y normal) — green tint
        circleXZ  = new CircleHandler(center + Vec3(1,0,1), Vec3(0,1,0), 1.0f,
                        Vec3(0.2f, 0.9f, 0.2f), Vec3(0.1f, 0.4f, 0.1f));
    }

    void destroy() {
        arrowX.destroy();
        arrowY.destroy();
        arrowZ.destroy();
        centerBox.destroy();
        circleXY.destroy();
        circleYZ.destroy();
        circleXZ.destroy();
    }

    void setPosition(Vec3 pos) {
        center = pos;
    }

    private void updateGeometry(const ref Viewport vp)
    {
        float size = gizmoSize(center, vp);

        // Each axis is the world-space image of local X/Y/Z under the
        // gizmo orientation. arrowX always represents axisX, irrespective
        // of whether axisX = world-X (auto workplane) or workplane.axis1.
        arrowX.start = center + axisX * (size/6);
        arrowX.end   = center + axisX * size;
        arrowY.start = center + axisY * (size/6);
        arrowY.end   = center + axisY * size;
        arrowZ.start = center + axisZ * (size/6);
        arrowZ.end   = center + axisZ * size;

        centerBox.pos  = center;
        centerBox.size = size * 0.04f;

        float circR = size * 0.07f;
        float cirOffset = size * 0.75f;
        // Plane handles sit at the corners of the basis quads; their
        // normals are the basis axis perpendicular to the plane.
        circleXY.center = center + axisX * cirOffset + axisY * cirOffset;
        circleXY.normal = axisZ; circleXY.radius = circR;
        circleYZ.center = center + axisY * cirOffset + axisZ * cirOffset;
        circleYZ.normal = axisX; circleYZ.radius = circR;
        circleXZ.center = center + axisX * cirOffset + axisZ * cirOffset;
        circleXZ.normal = axisY; circleXZ.radius = circR;

        // Hide arrows that point too directly toward/away from the camera.
        // viewDir is the normalised eye→center vector.
        Vec3  d    = vp.eye - center;
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        viewDir = dist > 1e-6f
            ? d / dist
            : Vec3(0,0,1);
        // Hide each axis when its world direction aligns with the camera
        // ray (parallel ⇒ zero on-screen length). Use the dot of viewDir
        // with the axis (works for non-canonical orientations).
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(dot(viewDir, axisX)) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(dot(viewDir, axisY)) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(dot(viewDir, axisZ)) < HIDE_THRESHOLD);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        circleXY.draw(shader, vp);
        circleYZ.draw(shader, vp);
        circleXZ.draw(shader, vp);
        centerBox.draw(shader, vp);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
    }

    void drawAxesOnly(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
    }

    void drawAxesAndCenter(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        centerBox.draw(shader, vp);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
    }
}

// ---------------------------------------------------------------------------
// RotateHandler : Handler — three semicircle arcs (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class RotateHandler : Handler {
    Vec3  center;
    float size;              // world-space radius, updated each frame in draw()
    SemicircleHandler arcX, arcY, arcZ;
    FullCircleHandler arcView;   // camera-view-plane ring (gray, interactive)
    FullCircleHandler bgCircle;  // camera-view-plane ring (black 1px, decorative)
    // World-space orientation triple — see MoveHandler.axisX/Y/Z. Each arc
    // rotates around the corresponding basis axis (arcX = around axisX).
    Vec3 axisX = Vec3(1, 0, 0);
    Vec3 axisY = Vec3(0, 1, 0);
    Vec3 axisZ = Vec3(0, 0, 1);
    void setOrientation(Vec3 ax, Vec3 ay, Vec3 az) {
        axisX = ax; axisY = ay; axisZ = az;
    }

    this(Vec3 center) {
        this.center = center;
        arcX     = new SemicircleHandler(center, Vec3(1,0,0), 1.0f, Vec3(0.9f, 0.2f, 0.2f));
        arcY     = new SemicircleHandler(center, Vec3(0,1,0), 1.0f, Vec3(0.2f, 0.9f, 0.2f));
        arcZ     = new SemicircleHandler(center, Vec3(0,0,1), 1.0f, Vec3(0.2f, 0.2f, 0.9f));
        arcView  = new FullCircleHandler(center, Vec3(0,0,1), 1.0f, Vec3(0.6f, 0.6f, 0.6f));
        arcX.lineWidth    += 1.0f;
        arcY.lineWidth    += 1.0f;
        arcZ.lineWidth    += 1.0f;
        arcView.lineWidth += 1.0f;
        bgCircle = new FullCircleHandler(center, Vec3(0,0,1), 1.0f, Vec3(0.0f, 0.0f, 0.0f));
        bgCircle.lineWidth = 2.0f;
        // bgCircle is decorative: drawn but never registered in the Test pass
        // (ToolHandles), so it stays at HandleState.Normal and never highlights.
    }

    void destroy() { arcX.destroy(); arcY.destroy(); arcZ.destroy(); arcView.destroy(); bgCircle.destroy(); }
    void setPosition(Vec3 pos) { center = pos; }

    private void updateGeometry(const ref Viewport vp)
    {
        size = gizmoSize(center, vp);

        arcX.center = center; arcX.normal = axisX; arcX.radius = size;
        arcY.center = center; arcY.normal = axisY; arcY.radius = size;
        arcZ.center = center; arcZ.normal = axisZ; arcZ.radius = size;

        // Camera forward vector (world space): f = (-view[2], -view[6], -view[10])
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

        // Decorative black ring: same plane and radius as X/Y/Z arcs, drawn first (behind)
        bgCircle.center = center;
        bgCircle.normal = camFwd;
        bgCircle.radius = size;

        // View-plane ring: normal = camera forward, radius slightly larger than axis arcs
        arcView.center = center;
        arcView.normal = camFwd;
        arcView.radius = size * 1.1f;

        // For each arc, the start direction is the intersection of the arc plane
        // and the viewport plane: cross(arcNormal, camFwd).
        // Falls back to the arc's own "right" if the vectors are nearly parallel.
        void applyStart(SemicircleHandler arc, Vec3 n) {
            Vec3 dir = cross(n, camFwd);
            float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
            if (len <= 1e-4f) return;
            dir = dir / len;
            // Midpoint of arc is at 90° CCW from dir around n: cross(n, dir).
            // If it faces away from camera (dot > 0 with camFwd), flip dir.
            Vec3 mid = cross(n, dir);
            if (dot(mid, camFwd) < 0.0f)
                dir = -dir;
            arc.setStartDirection(dir);
        }
        applyStart(arcX, axisX);
        applyStart(arcY, axisY);
        applyStart(arcZ, axisZ);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        bgCircle.draw(shader, vp);
        arcX.draw(shader, vp);
        arcY.draw(shader, vp);
        arcZ.draw(shader, vp);
        arcView.draw(shader, vp);
    }

    void drawPrincipalOnly(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        bgCircle.draw(shader, vp);
        arcX.draw(shader, vp);
        arcY.draw(shader, vp);
        arcZ.draw(shader, vp);
    }
}

// ---------------------------------------------------------------------------
// BoxHandler : Handler — solid-colour axis-aligned box at a given position.
// Highlights on hover (yellow); toggles selected state on click (orange).
// ---------------------------------------------------------------------------

class BoxHandler : Handler {
    Vec3  pos;
    Vec3  color;
    float size = 0.5f;   // half-extent
    bool  selected;

private:
    GLuint vao, vbo;
    int    vertCount;

public:
    this(Vec3 pos, Vec3 color) {
        this.pos   = pos;
        this.color = color;

        // Unit cube (half-extent 1), 6 faces × 2 triangles × 3 vertices
        float[] data;
        buildUnitCubeData(data);
        vertCount = cast(int)(data.length / 3);
        vao = buildVao3f(data, vbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &vao);
        glDeleteBuffers(1, &vbo);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 c = selected && state == HandleState.Normal
            ? handleStateColor(HandleState.Selected, color)
            : handleStateColor(state, color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                             Vec3(size, size, size), pos);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, vertCount);
        glBindVertexArray(0);

        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

public:
    // Fresh hit-test (does not rely on cached hover state); also satisfies Handler.hitTest.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return doHitTest(mx, my, vp);
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp)
    {
        return doHitTest(mx, my, vp) ? 0.0f : float.infinity;
    }

private:
    bool doHitTest(int mx, int my, const ref Viewport vp)
    {
        // Project all 8 corners and check if mouse is inside any projected face.
        immutable float[3][8] cv = [
            [-1,-1,-1], [ 1,-1,-1], [ 1, 1,-1], [-1, 1,-1],
            [-1,-1, 1], [ 1,-1, 1], [ 1, 1, 1], [-1, 1, 1],
        ];
        float[8] sx, sy; bool[8] valid;
        foreach (i; 0 .. 8) {
            float ndcZ;
            Vec3 w = pos + Vec3(cv[i][0]*size, cv[i][1]*size, cv[i][2]*size);
            valid[i] = projectToWindowFull(w, vp, sx[i], sy[i], ndcZ);
        }

        immutable int[4][6] faceQuads = [
            [0,1,2,3], [4,7,6,5],  // -Z, +Z
            [0,4,5,1], [3,2,6,7],  // -Y, +Y
            [0,3,7,4], [1,5,6,2],  // -X, +X
        ];
        foreach (ref q; faceQuads) {
            if (!valid[q[0]] || !valid[q[1]] || !valid[q[2]] || !valid[q[3]]) continue;
            float[4] xs = [sx[q[0]], sx[q[1]], sx[q[2]], sx[q[3]]];
            float[4] ys = [sy[q[0]], sy[q[1]], sy[q[2]], sy[q[3]]];
            if (pointInPolygon2D(cast(float)mx, cast(float)my, xs[], ys[]))
                return true;
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// CircleHandler : Handler
// Filled disc + outline ring at a given position in a given plane.
// Outline color = color; fill color = fillColor.
// Highlights on hover (yellow); toggles selected on click (orange).
// ---------------------------------------------------------------------------

class CircleHandler : Handler {
    Vec3  center;
    Vec3  normal;
    float radius    = 1.0f;
    Vec3  color;        // outline
    Vec3  fillColor;    // disc fill
    float lineWidth = 1.5f;

private:
    GLuint outlineVao, outlineVbo;
    GLuint fillVao,    fillVbo;
    int    fillVertCount;
    enum   SEGS = 32;

public:
    this(Vec3 center, Vec3 normal, float radius, Vec3 color, Vec3 fillColor) {
        this.center    = center;
        this.normal    = normal;
        this.radius    = radius;
        this.color     = color;
        this.fillColor = fillColor;

        // ---- Outline: unit circle in XY plane, SEGS+1 pts (last = first) ----
        float[] outData;
        foreach (i; 0 .. SEGS + 1) {
            float a = 2.0f * PI * i / SEGS;
            outData ~= [cos(a), sin(a), 0.0f];
        }
        outlineVao = buildVao3f(outData, outlineVbo);

        // ---- Fill: triangle fan (SEGS triangles × 3 verts) ----
        float[] fillData;
        foreach (i; 0 .. SEGS) {
            float a0 = 2.0f * PI *  i      / SEGS;
            float a1 = 2.0f * PI * (i + 1) / SEGS;
            fillData ~= [0.0f, 0.0f, 0.0f];
            fillData ~= [cos(a0), sin(a0), 0.0f];
            fillData ~= [cos(a1), sin(a1), 0.0f];
        }
        fillVertCount = cast(int)(fillData.length / 3);
        fillVao = buildVao3f(fillData, fillVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &outlineVao); glDeleteBuffers(1, &outlineVbo);
        glDeleteVertexArrays(1, &fillVao);    glDeleteBuffers(1, &fillVbo);
    }

    override bool hitTest(int mx, int my, const ref Viewport vp) {
        return doHitTest(mx, my, vp);
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp) {
        return doHitTest(mx, my, vp) ? 0.0f : float.infinity;
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 fwd = normalize(normal);
        Vec3 right, up;
        localFrame(normal, right, up);

        Vec3 oc = handleStateColor(state, color);
        Vec3 fc = handleStateColor(state, fillColor);

        auto m = modelMatrix(right, up, fwd, Vec3(radius, radius, radius), center);

        glDisable(GL_DEPTH_TEST);

        // ---- Fill ----
        glUniform3f(shader.locColor, fc.x, fc.y, fc.z);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(fillVao);
        glDrawArrays(GL_TRIANGLES, 0, fillVertCount);

        // ---- Outline ----
        drawThickLines(outlineVao, SEGS + 1, GL_LINE_STRIP, m, vp, oc, lineWidth, shader.program);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

private:
    bool doHitTest(int mx, int my, const ref Viewport vp)
    {
        // Project SEGS circle points and check if mouse is inside the polygon.
        Vec3 right, up;
        localFrame(normal, right, up);

        float[] xs, ys;
        foreach (i; 0 .. SEGS) {
            float a = 2.0f * PI * i / SEGS;
            Vec3 w = center + right * (cos(a) * radius) + up * (sin(a) * radius);
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) return false;
            xs ~= sx;
            ys ~= sy;
        }
        return pointInPolygon2D(cast(float)mx, cast(float)my, xs, ys);
    }
}

// ---------------------------------------------------------------------------
// CenterDiskGizmo : Handler — filled disc in the camera plane.
// No OpenGL draw — rendered via ImGui overlay in ScaleTool.
// Tracks hover (point-inside-disc hit test) and hover-blocked/forced state.
// ---------------------------------------------------------------------------

class CenterDiskGizmo : Handler {
    Vec3  center;
    Vec3  normal;  // camera forward, updated each frame
    float radius;

    override void draw(const ref Shader shader, const ref Viewport vp) {
        if (!visible) return;

        enum SEGS = 32;
        Vec3 right, up;
        localFrame(normal, right, up);

        ImVec2[SEGS] pts;
        bool allValid = true;
        foreach (i; 0 .. SEGS) {
            float a = 2.0f * PI * i / SEGS;
            Vec3 w = center + right * (cos(a) * radius) + up * (sin(a) * radius);
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { allValid = false; break; }
            pts[i] = ImVec2(sx, sy);
        }
        if (!allValid) return;

        uint fillCol;
        uint outlineCol;
        final switch (state) {
            case HandleState.Rollover:
                fillCol    = IM_COL32(255, 242,  38, 120);
                outlineCol = IM_COL32(255, 242,  38, 230);
                break;
            case HandleState.SecondaryDefault:
                fillCol    = IM_COL32(140, 190, 255,  90);
                outlineCol = IM_COL32(140, 190, 255, 190);
                break;
            case HandleState.Selected:
                fillCol    = IM_COL32(255, 163,   0, 120);
                outlineCol = IM_COL32(255, 163,   0, 230);
                break;
            case HandleState.Normal:
                fillCol    = IM_COL32(  0, 220, 220,  80);
                outlineCol = IM_COL32(  0, 220, 220, 200);
                break;
        }

        ImDrawList* dl = ImGui.GetForegroundDrawList();
        dl.AddConvexPolyFilled(pts.ptr, SEGS, fillCol);
        dl.AddPolyline(pts.ptr, SEGS, outlineCol, ImDrawFlags.Closed, 1.5f);
    }

    override bool hitTest(int mx, int my, const ref Viewport vp) {
        return diskHitCheck(mx, my, vp);
    }

    override float aiScreenDistance(int mx, int my, const ref Viewport vp) {
        return diskHitCheck(mx, my, vp) ? 0.0f : float.infinity;
    }

private:
    bool diskHitCheck(int mx, int my, const ref Viewport vp) {
        float cx, cy, ndcZ;
        if (!projectToWindowFull(center, vp, cx, cy, ndcZ)) return false;
        // Project one rim point to get screen-space radius.
        Vec3 right, up;
        localFrame(normal, right, up);
        Vec3 rim = center + right * radius;
        float rx, ry, rndcZ;
        if (!projectToWindowFull(rim, vp, rx, ry, rndcZ)) return false;
        float screenR = sqrt((rx - cx)*(rx - cx) + (ry - cy)*(ry - cy));
        float dx = mx - cx, dy = my - cy;
        return sqrt(dx*dx + dy*dy) <= screenR;
    }

}

// ---------------------------------------------------------------------------
// ScaleHandler : Handler — three axis CubicArrows (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class ScaleHandler : Handler {
    enum float AXIS_BOX_DISTANCE = 1.18f;

    Vec3  center;
    float size;   // world-space gizmo length, updated each frame in draw()
    CubicArrow      arrowX, arrowY, arrowZ;
    CubicArrow      scaleArrowX, scaleArrowY, scaleArrowZ;
    CenterDiskGizmo centerDisk;
    CircleHandler   circleXY, circleYZ, circleXZ;
    Vec3 viewDir;
    private Vec3 scaleAccum = Vec3(1, 1, 1);
    // World-space orientation triple — see MoveHandler.axisX/Y/Z.
    Vec3 axisX = Vec3(1, 0, 0);
    Vec3 axisY = Vec3(0, 1, 0);
    Vec3 axisZ = Vec3(0, 0, 1);
    void setOrientation(Vec3 ax, Vec3 ay, Vec3 az) {
        axisX = ax; axisY = ay; axisZ = az;
        scaleArrowX.fixedDir = ax;
        scaleArrowY.fixedDir = ay;
        scaleArrowZ.fixedDir = az;
    }

    this(Vec3 center) {
        this.center = center;
        arrowX      = new CubicArrow(center + Vec3(0.1f,0,0), center + Vec3(1,0,0), Vec3(0.9f, 0.2f, 0.2f));
        arrowY      = new CubicArrow(center + Vec3(0,0.1f,0), center + Vec3(0,1,0), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ      = new CubicArrow(center + Vec3(0,0,0.1f), center + Vec3(0,0,1), Vec3(0.2f, 0.2f, 0.9f));
        scaleArrowX = new CubicArrow(center, center + Vec3(1,0,0), Vec3(1.0f, 1.0f, 0.0f));
        scaleArrowY = new CubicArrow(center, center + Vec3(0,1,0), Vec3(1.0f, 1.0f, 0.0f));
        scaleArrowZ = new CubicArrow(center, center + Vec3(0,0,1), Vec3(1.0f, 1.0f, 0.0f));
        scaleArrowX.fixedDir = Vec3(1, 0, 0);
        scaleArrowY.fixedDir = Vec3(0, 1, 0);
        scaleArrowZ.fixedDir = Vec3(0, 0, 1);
        centerDisk  = new CenterDiskGizmo();
        // XY plane (Z normal) — blue tint
        circleXY = new CircleHandler(center, Vec3(0,0,1), 1.0f,
                        Vec3(0.2f, 0.2f, 0.9f), Vec3(0.1f, 0.1f, 0.4f));
        // YZ plane (X normal) — red tint
        circleYZ = new CircleHandler(center, Vec3(1,0,0), 1.0f,
                        Vec3(0.9f, 0.2f, 0.2f), Vec3(0.4f, 0.1f, 0.1f));
        // XZ plane (Y normal) — green tint
        circleXZ = new CircleHandler(center, Vec3(0,1,0), 1.0f,
                        Vec3(0.2f, 0.9f, 0.2f), Vec3(0.1f, 0.4f, 0.1f));
    }

    void setScaleAccum(Vec3 s) { scaleAccum = s; }

    int activeDragAxis = -1;  // -1 = none, 0/1/2 = axis, 3 = uniform

    void destroy() {
        arrowX.destroy();
        arrowY.destroy();
        arrowZ.destroy();
        scaleArrowX.destroy();
        scaleArrowY.destroy();
        scaleArrowZ.destroy();
        circleXY.destroy();
        circleYZ.destroy();
        circleXZ.destroy();
    }

    void setPosition(Vec3 pos) {
        center = pos;
    }

    private void updateGeometry(const ref Viewport vp, float axisBoxDistance = AXIS_BOX_DISTANCE)
    {
        size = gizmoSize(center, vp);

        arrowX.start = center + axisX * (size/7);
        arrowX.end   = center + axisX * (size * axisBoxDistance);
        arrowY.start = center + axisY * (size/7);
        arrowY.end   = center + axisY * (size * axisBoxDistance);
        arrowZ.start = center + axisZ * (size/7);
        arrowZ.end   = center + axisZ * (size * axisBoxDistance);

        float cubeFixed = size * 0.03f;
        scaleArrowX.start         = arrowX.end;
        scaleArrowY.start         = arrowY.end;
        scaleArrowZ.start         = arrowZ.end;
        scaleArrowX.end           = center + axisX * (size * axisBoxDistance * scaleAccum.x);
        scaleArrowX.fixedCubeHalf = cubeFixed;
        scaleArrowY.end           = center + axisY * (size * axisBoxDistance * scaleAccum.y);
        scaleArrowY.fixedCubeHalf = cubeFixed;
        scaleArrowZ.end           = center + axisZ * (size * axisBoxDistance * scaleAccum.z);
        scaleArrowZ.fixedCubeHalf = cubeFixed;

        Vec3  d    = vp.eye - center;
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        viewDir = dist > 1e-6f
            ? d / dist
            : Vec3(0,0,1);
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(dot(viewDir, axisX)) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(dot(viewDir, axisY)) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(dot(viewDir, axisZ)) < HIDE_THRESHOLD);

        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        centerDisk.center = center;
        centerDisk.normal = camFwd;
        centerDisk.radius = size * 0.08f;

        float circR      = size * 0.07f;
        float cirOffset  = size * 0.75f;
        circleXY.center = center + axisX * cirOffset + axisY * cirOffset;
        circleXY.normal = axisZ; circleXY.radius = circR;
        circleYZ.center = center + axisY * cirOffset + axisZ * cirOffset;
        circleYZ.normal = axisX; circleYZ.radius = circR;
        circleXZ.center = center + axisX * cirOffset + axisZ * cirOffset;
        circleXZ.normal = axisY; circleXZ.radius = circR;
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        circleXY.draw(shader, vp);
        circleYZ.draw(shader, vp);
        circleXZ.draw(shader, vp);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
        centerDisk.draw(shader, vp);
        if (activeDragAxis == 0 && scaleAccum.x != 0.0f) scaleArrowX.draw(shader, vp);
        if (activeDragAxis == 1 && scaleAccum.y != 0.0f) scaleArrowY.draw(shader, vp);
        if (activeDragAxis == 2 && scaleAccum.z != 0.0f) scaleArrowZ.draw(shader, vp);
    }

    void drawAxisBoxesOnly(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        arrowX.drawHeadOnly(shader, vp);
        arrowY.drawHeadOnly(shader, vp);
        arrowZ.drawHeadOnly(shader, vp);
        if (activeDragAxis == 0 && scaleAccum.x != 0.0f) scaleArrowX.drawHeadOnly(shader, vp);
        if (activeDragAxis == 1 && scaleAccum.y != 0.0f) scaleArrowY.drawHeadOnly(shader, vp);
        if (activeDragAxis == 2 && scaleAccum.z != 0.0f) scaleArrowZ.drawHeadOnly(shader, vp);
    }
}

// ---------------------------------------------------------------------------
// ClickPointHandler — gizmo at a world position made of 3 axis lines plus
// 3 unit circles in the XY / YZ / XZ planes.
//
// A pink "sphere with rings" handle drawn at the
// click point while a Convolve-family tool (xfrm.smooth / xfrm.jitter /
// xfrm.quantize) is active. CommandWrapperTool sets `worldSize` per
// frame to the current effect magnitude (Jitter Range, Smooth strength,
// Quantize step) so the handle visually scales with the parameter the
// drag is hauling.
//
// Non-interactive: no hover, no hit-test. Use `setPos` / `setWorldSize`
// to update each frame. VAO is lazily built on first draw and released
// by `destroy()`.
// ---------------------------------------------------------------------------
class ClickPointHandler : Handler {
private:
    Vec3   pos;
    Vec3   color;
    float  worldSize;       // half-extent / circle radius in world units
    GLuint vao, vbo;
    int    vertCount;
    bool   built;

    // Circle tessellation. 48 segments × 2 verts per ring give a smooth
    // outline at most reasonable camera distances; cheap.
    enum int CIRCLE_SEGMENTS = 48;

public:
    this(Vec3 color = Vec3(1.0f, 0.4f, 0.85f), float worldSize = 0.1f) {
        this.color     = color;
        this.worldSize = worldSize;
    }

    void destroy() {
        if (built) {
            glDeleteVertexArrays(1, &vao);
            glDeleteBuffers     (1, &vbo);
            built = false;
        }
    }

    void setPos(Vec3 p)        { pos = p; }
    void setColor(Vec3 c)      { color = c; }
    void setWorldSize(float s) { worldSize = s; }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!built) buildVao();

        immutable float r = worldSize;
        float[16] model = identityMatrix;
        model[0]  = r;
        model[5]  = r;
        model[10] = r;
        model[12] = pos.x;
        model[13] = pos.y;
        model[14] = pos.z;

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, model.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(shader.locColor, color.x, color.y, color.z);
        glDisable(GL_DEPTH_TEST);
        glBindVertexArray(vao);
        glDrawArrays(GL_LINES, 0, vertCount);
        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

private:
    void buildVao() {
        // 3 axis lines = 6 verts + 3 rings × CIRCLE_SEGMENTS segments
        // × 2 verts = 6 + 6*CIRCLE_SEGMENTS. Each ring lives in one of
        // the three principal planes (XY, YZ, XZ) at unit radius.
        float[] data;
        data.reserve(6 * 3 + 6 * CIRCLE_SEGMENTS * 3);

        // Axis cross.
        data ~= [-1f, 0f, 0f,   1f, 0f, 0f,
                  0f,-1f, 0f,   0f, 1f, 0f,
                  0f, 0f,-1f,   0f, 0f, 1f];

        // Three rings, line-segment pairs around each.
        foreach (i; 0 .. CIRCLE_SEGMENTS) {
            float t1 = 2.0f * PI * cast(float)i       / CIRCLE_SEGMENTS;
            float t2 = 2.0f * PI * cast(float)(i + 1) / CIRCLE_SEGMENTS;
            float c1 = cos(t1), s1 = sin(t1);
            float c2 = cos(t2), s2 = sin(t2);
            // XY plane (Z = 0)
            data ~= [c1, s1, 0f,   c2, s2, 0f];
            // YZ plane (X = 0)
            data ~= [0f, c1, s1,   0f, c2, s2];
            // XZ plane (Y = 0)
            data ~= [c1, 0f, s1,   c2, 0f, s2];
        }

        vertCount = cast(int)(data.length / 3);
        vao = buildVao3f(data, vbo);
        built = true;
    }
}

// ---------------------------------------------------------------------------
// ToolHandles — central hover/capture arbiter, one per active tool. Mirrors
// the tool-model test/draw pass: a single hot (ROLLOVER) part and a single
// captured (hauled) part across ALL registered handles, so highlight and
// click can never disagree. ToolHandles drives each registered handle's
// `state` every frame via setState; handles never self-compute hover.
// Unregistered handles are draw-only and stay at HandleState.Normal.
//
// ToolHandles.test / update call Handler.hitTest / setState — legal from the
// same module regardless of `protected`.
// ---------------------------------------------------------------------------

class ToolHandles {
    private struct Entry { Handler h; int part; }
    alias AiHoverPreviewPredicate = bool delegate(int part) const;
    private Entry[] entries;     // registration order = test priority
    private AiCandidate[] aiCandidates; // last observational hit-candidate pass
    private int[] aiCandidateParts;      // candidate index -> registered part id
    int hot      = -1;           // ROLLOVER part, -1 = none
    int secondaryDefault = -1;   // deterministic default hint when AI changes hover
    int captured = -1;           // hauled part during a drag, -1 = none
    private bool suppressed;     // when set, update() forces every handle Normal
    private int lastDefaultPart = -1;
    private bool aiHoverPreviewEnabled;
    private AiHoverPreviewPredicate aiHoverPreviewPredicate;

    // Clear the per-frame registration list. Call at the start of each draw.
    void begin() {
        entries.length = 0;
        aiCandidates.length = 0;
        aiCandidateParts.length = 0;
        secondaryDefault = -1;
        lastDefaultPart = -1;
        suppressed = false;
    }

    // Force every registered handle to Normal for this frame, ignoring hover
    // and capture. Used by ScaleTool, whose drag feedback is the animated
    // scale arrow — no gizmo handle should highlight while a scale drag runs.
    void suppress() { suppressed = true; }

    void setAiHoverPreviewEnabled(bool enabled) {
        aiHoverPreviewEnabled = enabled;
    }

    void setAiHoverPreviewPredicate(AiHoverPreviewPredicate predicate) {
        aiHoverPreviewPredicate = predicate;
    }

    // Register a handle with a stable part id, in priority order (first wins
    // on overlap).
    void add(Handler h, int part) {
        entries ~= Entry(h, part);
    }

    // Hit-test pass: first registered handle (by priority) whose hitTest passes.
    // Skips invisible handles. Returns its part id, or -1 on miss. Also records
    // the full ordered list of hit handle candidates for future advisory/debug
    // paths; this cache is observational and does not drive the winner.
    int test(int mx, int my, const ref Viewport vp,
             AiInteractionPhase phase = AiInteractionPhase.unknown) {
        aiCandidates.length = 0;
        aiCandidateParts.length = 0;
        int firstPart = -1;
        size_t defaultCandidate = size_t.max;

        foreach (priority, ref e; entries) {
            if (!e.h.isVisible()) continue;
            if (!e.h.hitTest(mx, my, vp)) continue;

            AiCandidate c;
            c.id = "handle:" ~ e.part.to!string;
            c.kind = AiCandidateKind.handle;
            c.intent = e.h.aiIntentForPart(e.part);
            c.screenDist = e.h.aiScreenDistance(mx, my, vp);
            c.priorityFromCurrentRules = cast(float)priority;
            c.hasScreenPosition = true;
            c.screenPosition = [cast(float)mx, cast(float)my];
            if (firstPart < 0) {
                firstPart = e.part;
                defaultCandidate = aiCandidates.length;
            }
            aiCandidates ~= c;
            aiCandidateParts ~= e.part;
        }
        if (defaultCandidate != size_t.max)
            aiCandidates[defaultCandidate].isDefaultWinner = true;
        return publishHandleTrace(mx, my, phase, firstPart, defaultCandidate);
    }

    const(AiCandidate)[] handleCandidates() const {
        return aiCandidates;
    }

    // Resolve the hot part (captured sticks; else test) and hand each
    // registered handle its HandleState for this frame.
    void update(int mx, int my, const ref Viewport vp) {
        if (suppressed) {
            hot = -1;
            secondaryDefault = -1;
            lastDefaultPart = -1;
            aiCandidates.length = 0;
            aiCandidateParts.length = 0;
            publishHandleDebugTrace(aiCandidates);
            foreach (ref e; entries) e.h.setState(HandleState.Normal);
            return;
        }
        if (captured >= 0) {
            hot = captured;
            secondaryDefault = -1;
        } else {
            hot = test(mx, my, vp,
                       aiHoverPreviewEnabled
                           ? AiInteractionPhase.hover
                           : AiInteractionPhase.unknown);
            secondaryDefault = lastDefaultPart >= 0 && lastDefaultPart != hot
                ? lastDefaultPart
                : -1;
        }
        foreach (ref e; entries) {
            auto nextState = HandleState.Normal;
            if (e.part == hot)
                nextState = HandleState.Rollover;
            else if (e.part == secondaryDefault)
                nextState = HandleState.SecondaryDefault;
            e.h.setState(nextState);
        }
    }

    void setHaul(int part) { captured = part; }
    void clearHaul()       { captured = -1;  }

    private int publishHandleTrace(int mx, int my, AiInteractionPhase phase,
                                   int defaultPart,
                                   size_t defaultCandidate) {
        auto context = AiInteractionContext();
        context.phase = phase;
        context.defaultIntent = AiIntent.keepDefault;
        context.mouseX = mx;
        context.mouseY = my;
        context.isDragging = captured >= 0;

        AiAdvisorDecision decision;
        try {
            decision = handleAiAdvisor().advise(context, aiCandidates);
        } catch (Exception) {
            decision = AiAdvisorDecision();
        }

        auto appliedCandidate = defaultCandidate;
        int appliedPart = defaultPart;
        if (canApplyAdvisorDecision(phase, decision, defaultCandidate)) {
            appliedCandidate = cast(size_t)decision.candidateIndex;
            appliedPart = aiCandidateParts[appliedCandidate];
        }
        lastDefaultPart = defaultPart;
        publishHandleDebugTrace(
            aiCandidates,
            decision,
            appliedCandidate == size_t.max ? -1 : cast(int)appliedCandidate);
        return appliedPart;
    }

    private bool canApplyAdvisorDecision(AiInteractionPhase phase,
                                         const ref AiAdvisorDecision decision,
                                         size_t defaultCandidate) const {
        enum float minConfidence = 0.75f;
        if (phase != AiInteractionPhase.mouseDown &&
            phase != AiInteractionPhase.hover)
            return false;
        if (captured >= 0)
            return false;
        if (decision.keepDefault || decision.confidence < minConfidence)
            return false;
        if (decision.candidateIndex < 0)
            return false;
        auto index = cast(size_t)decision.candidateIndex;
        if (index >= aiCandidates.length || index >= aiCandidateParts.length)
            return false;
        if (index == defaultCandidate)
            return false;
        if (aiCandidates[index].kind != AiCandidateKind.handle)
            return false;
        if (phase == AiInteractionPhase.hover) {
            if (!aiHoverPreviewEnabled)
                return false;
            if (defaultCandidate >= aiCandidateParts.length)
                return false;
            if (aiHoverPreviewPredicate !is null &&
                (!aiHoverPreviewPredicate(aiCandidateParts[defaultCandidate]) ||
                 !aiHoverPreviewPredicate(aiCandidateParts[index])))
                return false;
        }
        if (decision.candidateId.length == 0 ||
            decision.candidateId != aiCandidates[index].id)
            return false;
        return true;
    }
}
