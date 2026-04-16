module handler;
import bindbc.sdl;
import bindbc.opengl;

import std.math : tan, sin, cos, sqrt, PI, abs;

import math;
import eventlog;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

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
// Change via setGizmoScreenFraction() at runtime.
// ---------------------------------------------------------------------------

private float g_gizmoScreenFraction = 0.55f;  // index 4 of 9 levels [0.1..1.0]

void setGizmoScreenFraction(float f) { g_gizmoScreenFraction = f; }
float getGizmoScreenFraction()       { return g_gizmoScreenFraction; }

// World-space size for a gizmo element at `pos` so that it occupies a constant
// fraction of the screen height regardless of FOV or camera distance.
// `scale` lets callers produce smaller/larger variants (e.g. 0.04 for box handles).
float gizmoSize(Vec3 pos, const ref Viewport vp, float scale = 1.0f) {
    float depth = -(vp.view[2]*pos.x + vp.view[6]*pos.y + vp.view[10]*pos.z + vp.view[14]);
    if (depth < 1e-4f) depth = 1e-4f;
    return g_gizmoScreenFraction * scale * depth / vp.proj[5];
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
}

// Upload a float[] (XYZ triples) to a fresh VAO with a single vec3 attribute at location 0.
// Fills *vbo with the created buffer object and returns the VAO.
private GLuint buildVao3f(float[] data, out GLuint vbo) {
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
    bool   hovered;
    bool   forceHovered;
    bool   hoverBlocked;
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
    bool isHovered()    const { return hovered; }
    void setForceHovered(bool v) { forceHovered  = v; }
    void setHoverBlocked(bool v) { hoverBlocked  = v; }
    void setVisible(bool v)      { visible = v; if (!v) hovered = false; }
    bool isVisible() const       { return visible; }

    // Override in subclasses to define the hover hit area.
    protected bool hitTest(int mx, int my, const ref Viewport vp) { return false; }

    // Updates `hovered` from the current mouse position; respects blocked/forced flags.
    protected void updateHover(const ref Viewport vp) {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        hovered = hitTest(mx, my, vp);
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
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, vp, sax, say, ndcZa) ||
            !projectToWindowFull(end,   vp, sbx, sby, ndcZb))
            return false;
        float t;
        return closestOnSegment2D(cast(float)mx, cast(float)my,
                                  sax, say, sbx, sby, t) < 8.0f;
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
        Vec3 fwd = Vec3(dir.x/len, dir.y/len, dir.z/len);
        Vec3 right, up;
        localFrame(fwd, right, up);

        float coneLen    = len * 0.25f;
        float coneRadius = len * 0.05f;
        float shaftLen   = len - coneLen;
        Vec3  coneBase   = end - fwd * coneLen;

        updateHover(vp);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

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
            : Vec3(dir.x/len, dir.y/len, dir.z/len);
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

        updateHover(vp);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

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
    bool  selected;
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

        updateHover(vp);

        Vec3 c = hovered  ? Vec3(1.0f, 0.95f, 0.15f)   // yellow
               : selected ? Vec3(1.0f, 0.64f, 0.0f)    // orange
               :            color;

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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
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

    // Fresh hit test — does not rely on cached hover state; also used by Handler.updateHover.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        Vec3 right, up;
        localFrame(normal, right, up);
        float[2][SEGS + 1] pts;
        bool[SEGS + 1]     valid;
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
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   pts[i][0], pts[i][1],
                                   pts[i+1][0], pts[i+1][1], t) < 8.0f)
                return true;
        }
        return false;
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

        updateHover(vp);

        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto model = modelMatrix(right, up, fwd,
                                 Vec3(radius, radius, radius), center);
        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth, shader.program);

        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    // Fresh hit test — does not rely on cached hover state; also used by Handler.updateHover.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        Vec3 right, up;
        localFrame(normal, right, up);
        float[2][SEGS + 1] pts;
        bool[SEGS + 1]     valid;
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
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   pts[i][0], pts[i][1],
                                   pts[i+1][0], pts[i+1][1], t) < 8.0f)
                return true;
        }
        return false;
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

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        float size = gizmoSize(center, vp);

        arrowX.start = center + Vec3(size/6, 0     , 0);
        arrowX.end   = center + Vec3(size  , 0.    , 0);
        arrowY.start = center + Vec3(0     , size/6, 0);
        arrowY.end   = center + Vec3(0     , size  , 0);
        arrowZ.start = center + Vec3(0     , 0     , size/6);
        arrowZ.end   = center + Vec3(0     , 0     , size);

        centerBox.pos  = center;
        centerBox.size = size * 0.04f;

        float circR = size * 0.07f;
        float cirOffset = size * 0.75;
        circleXY.center = center + Vec3(cirOffset, cirOffset, 0   ); circleXY.radius = circR;
        circleYZ.center = center + Vec3(0   , cirOffset, cirOffset); circleYZ.radius = circR;
        circleXZ.center = center + Vec3(size, 0   , cirOffset); circleXZ.radius = circR;

        // Hide arrows that point too directly toward/away from the camera.
        // viewDir is the normalised vector from eye to center.
        Vec3  d    = vp.eye - center;
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        viewDir = dist > 1e-6f
            ? Vec3(d.x / dist, d.y / dist, d.z / dist)  // eye→center direction (d = eye-center, flip)
            : Vec3(0,0,1);
        // d = eye - center, so viewDir (center→eye) = d/dist; axis dot with that.
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(viewDir.x) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(viewDir.y) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(viewDir.z) < HIDE_THRESHOLD);

        circleXY.draw(shader, vp);
        circleYZ.draw(shader, vp);
        circleXZ.draw(shader, vp);
        centerBox.draw(shader, vp);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        return arrowX.onMouseButtonDown(e) ||
               arrowY.onMouseButtonDown(e) ||
               arrowZ.onMouseButtonDown(e);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        return arrowX.onMouseButtonUp(e) ||
               arrowY.onMouseButtonUp(e) ||
               arrowZ.onMouseButtonUp(e);
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        return arrowX.onMouseMotion(e) ||
               arrowY.onMouseMotion(e) ||
               arrowZ.onMouseMotion(e);
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
        bgCircle.setHoverBlocked(true);
    }

    void destroy() { arcX.destroy(); arcY.destroy(); arcZ.destroy(); arcView.destroy(); bgCircle.destroy(); }
    void setPosition(Vec3 pos) { center = pos; }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        size = gizmoSize(center, vp);

        arcX.center = center; arcX.normal = Vec3(1,0,0); arcX.radius = size;
        arcY.center = center; arcY.normal = Vec3(0,1,0); arcY.radius = size;
        arcZ.center = center; arcZ.normal = Vec3(0,0,1); arcZ.radius = size;

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
            dir = Vec3(dir.x/len, dir.y/len, dir.z/len);
            // Midpoint of arc is at 90° CCW from dir around n: cross(n, dir).
            // If it faces away from camera (dot > 0 with camFwd), flip dir.
            Vec3 mid = cross(n, dir);
            if (dot(mid, camFwd) < 0.0f)
                dir = Vec3(-dir.x, -dir.y, -dir.z);

            // Arrow a = new Arrow(center, vec3Add(center, dir), Vec3(0.2f, 0.2f, 0.9f));
            // a.draw(program, locColor, vp);
            // a.destroy();

            arc.setStartDirection(dir);
        }
        applyStart(arcX, Vec3(1,0,0));
        applyStart(arcY, Vec3(0,1,0));
        applyStart(arcZ, Vec3(0,0,1));

        bgCircle.draw(shader, vp);
        arcX.draw(shader, vp);
        arcY.draw(shader, vp);
        arcZ.draw(shader, vp);
        arcView.draw(shader, vp);
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
        updateHover(vp);  // defined in Handler base class

        Vec3 c = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
               : selected ? Vec3(1.0f, 0.64f, 0.0f)
               :            color;

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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
    }

public:
    // Fresh hit-test (does not rely on cached hover state); also satisfies Handler.hitTest.
    override bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return doHitTest(mx, my, vp);
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
    bool  selected;

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

    bool isSelected()        const { return selected; }
    void setSelected(bool v)       { selected = v; }

    override bool hitTest(int mx, int my, const ref Viewport vp) {
        return doHitTest(mx, my, vp);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 fwd = normalize(normal);
        Vec3 right, up;
        localFrame(normal, right, up);

        updateHover(vp);

        Vec3 oc = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
                : selected ? Vec3(1.0f, 0.64f, 0.0f)
                :            color;
        Vec3 fc = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
                : selected ? Vec3(1.0f, 0.64f, 0.0f)
                :            fillColor;

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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
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
        updateHover(vp);

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

        uint fillCol    = hovered ? IM_COL32(255, 242,  38, 120) : IM_COL32(  0, 220, 220,  80);
        uint outlineCol = hovered ? IM_COL32(255, 242,  38, 230) : IM_COL32(  0, 220, 220, 200);

        ImDrawList* dl = ImGui.GetForegroundDrawList();
        dl.AddConvexPolyFilled(pts.ptr, SEGS, fillCol);
        dl.AddPolyline(pts.ptr, SEGS, outlineCol, ImDrawFlags.Closed, 1.5f);
    }

    override bool hitTest(int mx, int my, const ref Viewport vp) {
        return diskHitCheck(mx, my, vp);
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
    Vec3  center;
    float size;   // world-space gizmo length, updated each frame in draw()
    CubicArrow      arrowX, arrowY, arrowZ;
    CubicArrow      scaleArrowX, scaleArrowY, scaleArrowZ;
    CenterDiskGizmo centerDisk;
    CircleHandler   circleXY, circleYZ, circleXZ;
    Vec3 viewDir;
    private Vec3 scaleAccum = Vec3(1, 1, 1);

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

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        size = gizmoSize(center, vp);

        arrowX.start = center + Vec3(size/7, 0,      0     );
        arrowX.end   = center + Vec3(size,   0,      0     );
        arrowY.start = center + Vec3(0,      size/7, 0     );
        arrowY.end   = center + Vec3(0,      size,   0     );
        arrowZ.start = center + Vec3(0,      0,      size/7);
        arrowZ.end   = center + Vec3(0,      0,      size  );

        float cubeFixed = size * 0.03f;
        // Start matches the regular arrows (size/8 offset); frozen during drag.
        if (activeDragAxis < 0) {
            scaleArrowX.start = arrowX.start;
            scaleArrowY.start = arrowY.start;
            scaleArrowZ.start = arrowZ.start;
        }
        scaleArrowX.end           = center + Vec3(size * scaleAccum.x, 0, 0);
        scaleArrowX.fixedCubeHalf = cubeFixed;
        scaleArrowY.end           = center + Vec3(0, size * scaleAccum.y, 0);
        scaleArrowY.fixedCubeHalf = cubeFixed;
        scaleArrowZ.end           = center + Vec3(0, 0, size * scaleAccum.z);
        scaleArrowZ.fixedCubeHalf = cubeFixed;

        Vec3  d    = vp.eye - center;
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        viewDir = dist > 1e-6f
            ? Vec3(d.x / dist, d.y / dist, d.z / dist)
            : Vec3(0,0,1);
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(viewDir.x) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(viewDir.y) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(viewDir.z) < HIDE_THRESHOLD);

        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        centerDisk.center = center;
        centerDisk.normal = camFwd;
        centerDisk.radius = size * 0.08f;

        float circR      = size * 0.07f;
        float cirOffset  = size * 0.75f;
        circleXY.center = center + Vec3(cirOffset, cirOffset, 0);         circleXY.radius = circR;
        circleYZ.center = center + Vec3(0,         cirOffset, cirOffset); circleYZ.radius = circR;
        circleXZ.center = center + Vec3(cirOffset, 0,         cirOffset); circleXZ.radius = circR;

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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        return arrowX.onMouseButtonDown(e) ||
               arrowY.onMouseButtonDown(e) ||
               arrowZ.onMouseButtonDown(e);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        return arrowX.onMouseButtonUp(e) ||
               arrowY.onMouseButtonUp(e) ||
               arrowZ.onMouseButtonUp(e);
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        return arrowX.onMouseMotion(e) ||
               arrowY.onMouseMotion(e) ||
               arrowZ.onMouseMotion(e);
    }
}