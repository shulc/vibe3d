module handler;
import bindbc.sdl;
import bindbc.opengl;

import std.math : tan, sin, cos, sqrt, PI, abs;

import math;
import eventlog;

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
    void draw(GLuint program, GLint locColor, const ref Viewport vp) {}

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
}

// ---------------------------------------------------------------------------
// Arrow : Handler
// Unit shaft  — line  (0,0,0)→(0,0,1)  along +Z
// Unit cone   — tip at Z=1, base at Z=0, radius=1
// Both are created once; draw() transforms them via u_model.
// ---------------------------------------------------------------------------

class Arrow : Handler {
    Vec3  start;
    Vec3  end;
    Vec3  color;
    float lineWidth = 5.0f;

private:
    GLuint shaftVao, shaftVbo;
    GLuint headVao,  headVbo;
    int    headVertCount;

    enum CONE_SEGS = 16;

public:
    this(Vec3 start, Vec3 end, Vec3 color) {
        this.start = start;
        this.end   = end;
        this.color = color;

        // ---- Unit shaft: (0,0,0) → (0,0,1) ----
        float[6] shaftData = [0,0,0,  0,0,1];
        glGenVertexArrays(1, &shaftVao); glGenBuffers(1, &shaftVbo);
        glBindVertexArray(shaftVao);
        glBindBuffer(GL_ARRAY_BUFFER, shaftVbo);
        glBufferData(GL_ARRAY_BUFFER, shaftData.sizeof, shaftData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // ---- Unit cone: tip (0,0,1), base circle at Z=0, radius=1 ----
        float[] coneData;
        foreach (i; 0 .. CONE_SEGS) {
            float a0 = 2*PI *  i      / CONE_SEGS;
            float a1 = 2*PI * (i + 1) / CONE_SEGS;
            float c0 = cos(a0), s0 = sin(a0);
            float c1 = cos(a1), s1 = sin(a1);
            // Side face
            coneData ~= [0f,0f,1f,  c0,s0,0f,  c1,s1,0f];
            // Base cap (inward winding)
            coneData ~= [0f,0f,0f,  c1,s1,0f,  c0,s0,0f];
        }
        headVertCount = cast(int)(coneData.length / 3);

        glGenVertexArrays(1, &headVao); glGenBuffers(1, &headVbo);
        glBindVertexArray(headVao);
        glBindBuffer(GL_ARRAY_BUFFER, headVbo);
        glBufferData(GL_ARRAY_BUFFER, coneData.length * float.sizeof,
                     coneData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    void destroy() {
        glDeleteVertexArrays(1, &shaftVao); glDeleteBuffers(1, &shaftVbo);
        glDeleteVertexArrays(1, &headVao);  glDeleteBuffers(1, &headVbo);
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 dir = vec3Sub(end, start);
        float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
        if (len < 1e-6f) return;
        Vec3 fwd = Vec3(dir.x/len, dir.y/len, dir.z/len);

        // Local frame (right, up perpendicular to fwd)
        Vec3 tmp   = (abs(fwd.x) < 0.9f) ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);

        float coneLen    = len * 0.25f;
        float coneRadius = len * 0.05f;
        float shaftLen   = len - coneLen;
        Vec3  coneBase   = vec3Sub(end, vec3Scale(fwd, coneLen));

        updateHover(vp);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        // ---- Draw shaft (thick line) ----
        auto shaftModel = modelMatrix(right, up, fwd,
                                      Vec3(1, 1, shaftLen), start);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, program);
        glUniform3f(locColor, c.x, c.y, c.z);

        // ---- Draw cone head ----
        auto headModel = modelMatrix(right, up, fwd,
                                     Vec3(coneRadius, coneRadius, coneLen), coneBase);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        // Restore identity so subsequent draws are unaffected
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

private:
    void updateHover(const ref Viewport vp)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, vp, sax, say, ndcZa) ||
            !projectToWindowFull(end,   vp, sbx, sby, ndcZb))
        {
            hovered = false;
            return;
        }
        float t;
        hovered = closestOnSegment2D(cast(float)mx, cast(float)my,
                                     sax, say, sbx, sby, t) < 8.0f;
    }
}

// ---------------------------------------------------------------------------
// CubicArrow : Handler
// Like Arrow but with a small cube at the tip instead of a cone.
// Unit shaft  — line  (0,0,0)→(0,0,1)  along +Z
// Unit cube   — centred at origin, half-extent 1  (placed at tip via model matrix)
// ---------------------------------------------------------------------------

class CubicArrow : Handler {
    Vec3  start;
    Vec3  end;
    Vec3  color;
    float lineWidth = 5.0f;

private:
    GLuint shaftVao, shaftVbo;
    GLuint headVao,  headVbo;
    int    headVertCount;

public:
    this(Vec3 start, Vec3 end, Vec3 color) {
        this.start = start;
        this.end   = end;
        this.color = color;

        // ---- Unit shaft: (0,0,0) → (0,0,1) ----
        float[6] shaftData = [0,0,0,  0,0,1];
        glGenVertexArrays(1, &shaftVao); glGenBuffers(1, &shaftVbo);
        glBindVertexArray(shaftVao);
        glBindBuffer(GL_ARRAY_BUFFER, shaftVbo);
        glBufferData(GL_ARRAY_BUFFER, shaftData.sizeof, shaftData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // ---- Unit cube: centred at origin, half-extent 1 ----
        // 6 faces × 2 triangles × 3 vertices
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
        float[] cubeData;
        foreach (ref f; faces)
            foreach (idx; f)
                cubeData ~= v[idx];
        headVertCount = cast(int)(cubeData.length / 3);

        glGenVertexArrays(1, &headVao); glGenBuffers(1, &headVbo);
        glBindVertexArray(headVao);
        glBindBuffer(GL_ARRAY_BUFFER, headVbo);
        glBufferData(GL_ARRAY_BUFFER, cubeData.length * float.sizeof,
                     cubeData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    void destroy() {
        glDeleteVertexArrays(1, &shaftVao); glDeleteBuffers(1, &shaftVbo);
        glDeleteVertexArrays(1, &headVao);  glDeleteBuffers(1, &headVbo);
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        if (!visible) return;
        Vec3 dir = vec3Sub(end, start);
        float len = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);
        if (len < 1e-6f) return;
        Vec3 fwd = Vec3(dir.x/len, dir.y/len, dir.z/len);

        Vec3 tmp   = (abs(fwd.x) < 0.9f) ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);

        float cubeHalf  = len * 0.06f;       // half-extent of the cube
        float shaftLen  = len - cubeHalf * 2;
        Vec3  cubeCenter = vec3Sub(end, vec3Scale(fwd, cubeHalf));

        updateHover(vp);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        // ---- Draw shaft (thick line) ----
        auto shaftModel = modelMatrix(right, up, fwd,
                                      Vec3(1, 1, shaftLen), start);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, program);
        glUniform3f(locColor, c.x, c.y, c.z);

        // ---- Draw cube head ----
        // Scale unit cube (half-extent 1) to cubeHalf, translate to cubeCenter
        auto headModel = modelMatrix(right, up, fwd,
                                     Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

private:
    void updateHover(const ref Viewport vp)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, vp, sax, say, ndcZa) ||
            !projectToWindowFull(end,   vp, sbx, sby, ndcZb))
        {
            hovered = false;
            return;
        }
        float t;
        hovered = closestOnSegment2D(cast(float)mx, cast(float)my,
                                     sax, say, sbx, sby, t) < 8.0f;
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

        glGenVertexArrays(1, &arcVao); glGenBuffers(1, &arcVbo);
        glBindVertexArray(arcVao);
        glBindBuffer(GL_ARRAY_BUFFER, arcVbo);
        glBufferData(GL_ARRAY_BUFFER, arcData.length * float.sizeof,
                     arcData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    void destroy() {
        glDeleteVertexArrays(1, &arcVao);
        glDeleteBuffers(1, &arcVbo);
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        Vec3 fwd = normalize(normal);
        Vec3 tmp   = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);

        updateHover(vp, right, up);

        Vec3 c = hovered  ? Vec3(1.0f, 0.95f, 0.15f)   // yellow
               : selected ? Vec3(1.0f, 0.64f, 0.0f)    // orange
               :            color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        float ca = cos(startAngle), sa = sin(startAngle);
        Vec3 rr = Vec3(right.x*ca + up.x*sa, right.y*ca + up.y*sa, right.z*ca + up.z*sa);
        Vec3 ru = Vec3(-right.x*sa + up.x*ca, -right.y*sa + up.y*ca, -right.z*sa + up.z*ca);
        auto model = modelMatrix(rr, ru, fwd,
                                 Vec3(radius, radius, radius), center);
        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth, program);

        glEnable(GL_DEPTH_TEST);
        // Restore main program's u_model to identity
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
    }

    // Set startAngle so the arc begins at the direction of `dir` in the arc plane.
    // `dir` is projected onto the local right/up frame; its angle becomes startAngle.
    void setStartDirection(Vec3 dir) {
        Vec3 fwd = normalize(normal);
        Vec3 tmp   = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);
        float dx = dot(dir, right);
        float dy = dot(dir, up);
        import std.math : atan2;
        startAngle = atan2(dy, dx);
    }

    // Fresh hit test — does not rely on cached hover state.
    bool hitTest(int mx, int my, const ref Viewport vp)
    {
        Vec3 fwd = normalize(normal);
        Vec3 tmp   = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);
        return arcHitCheck(mx, my, vp, right, up);
    }

private:
    // Returns true if (mx,my) is within 8 px of the projected arc.
    bool arcHitCheck(int mx, int my, const ref Viewport vp, Vec3 right, Vec3 up)
    {
        float[2][SEGS + 1] pts;
        bool[SEGS + 1]     valid;
        foreach (i; 0 .. SEGS + 1) {
            float a = startAngle + cast(float)i * PI / SEGS;
            Vec3 w = vec3Add(center,
                        vec3Add(vec3Scale(right, cos(a) * radius),
                                vec3Scale(up,    sin(a) * radius)));
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

    void updateHover(const ref Viewport vp, Vec3 right, Vec3 up)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        hovered = arcHitCheck(mx, my, vp, right, up);
    }
}

// ---------------------------------------------------------------------------
// MoveHandler : Handler — three axis arrows (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class MoveHandler : Handler {
    Vec3  center;
    float screenFraction = 0.15f;  // gizmo size as fraction of eye-to-center distance
    Arrow         arrowX, arrowY, arrowZ;
    BoxHandler    centerBox;
    CircleHandler circleXY, circleYZ, circleXZ;
    Vec3 viewDir;

    this(Vec3 center) {
        this.center = center;
        arrowX    = new Arrow(vec3Add(center, Vec3(0.1f,0,0)), vec3Add(center, Vec3(1,0,0)), Vec3(0.9f, 0.2f, 0.2f));
        arrowY    = new Arrow(vec3Add(center, Vec3(0,0.1f,0)), vec3Add(center, Vec3(0,1,0)), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ    = new Arrow(vec3Add(center, Vec3(0,0,0.1f)), vec3Add(center, Vec3(0,0,1)), Vec3(0.2f, 0.2f, 0.9f));
        centerBox = new BoxHandler(center, Vec3(0.0f, 0.9f, 0.9f));
        // XY plane (Z normal) — blue tint
        circleXY  = new CircleHandler(vec3Add(center, Vec3(1, 1,0)), Vec3(0,0,1), 1.0f,
                        Vec3(0.2f, 0.2f, 0.9f), Vec3(0.1f, 0.1f, 0.4f));
        // YZ plane (X normal) — red tint
        circleYZ  = new CircleHandler(vec3Add(center, Vec3(0,1,1)), Vec3(1,0,0), 1.0f,
                        Vec3(0.9f, 0.2f, 0.2f), Vec3(0.4f, 0.1f, 0.1f));
        // XZ plane (Y normal) — green tint
        circleXZ  = new CircleHandler(vec3Add(center, Vec3(1,0,1)), Vec3(0,1,0), 1.0f,
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

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        // Extract eye position from view matrix (view = R*T, eye = -R^T * t).
        const ref float[16] view = vp.view;
        Vec3 eye = Vec3(
            -(view[0]*view[12] + view[4]*view[13] + view[8]*view[14]),
            -(view[1]*view[12] + view[5]*view[13] + view[9]*view[14]),
            -(view[2]*view[12] + view[6]*view[13] + view[10]*view[14]),
        );

        Vec3  d    = vec3Sub(eye, center);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        // Use view-space depth (projection onto camera axis) instead of Euclidean
        // distance. NDC size = world_size / depth * proj[5], so with
        // world_size = screenFraction * depth / proj[5] we get NDC = screenFraction —
        // constant regardless of camera angle, FOV, or viewport dimensions.
        float depth = -(vp.view[2]*center.x + vp.view[6]*center.y +
                        vp.view[10]*center.z + vp.view[14]);
        if (depth < 1e-4f) depth = 1e-4f;
        float size = screenFraction * depth / vp.proj[5];

        arrowX.start = vec3Add(center, Vec3(size/6, 0     , 0));;
        arrowX.end   = vec3Add(center, Vec3(size  , 0.    , 0));
        arrowY.start = vec3Add(center, Vec3(0     , size/6, 0));;
        arrowY.end   = vec3Add(center, Vec3(0     , size  , 0));
        arrowZ.start = vec3Add(center, Vec3(0     , 0     , size/6));
        arrowZ.end   = vec3Add(center, Vec3(0     , 0     , size));

        centerBox.pos  = center;
        centerBox.size = size * 0.04f;

        float circR = size * 0.07f;
        float cirOffset = size * 0.75;
        circleXY.center = vec3Add(center, Vec3(cirOffset, cirOffset, 0   )); circleXY.radius = circR;
        circleYZ.center = vec3Add(center, Vec3(0   , cirOffset, cirOffset)); circleYZ.radius = circR;
        circleXZ.center = vec3Add(center, Vec3(size, 0   , cirOffset)); circleXZ.radius = circR;

        // Hide arrows that point too directly toward/away from the camera.
        // viewDir is the normalised vector from eye to center.
        viewDir = dist > 1e-6f
            ? Vec3(d.x / dist, d.y / dist, d.z / dist)  // eye→center direction (d = eye-center, flip)
            : Vec3(0,0,1);
        // d = eye - center, so viewDir (center→eye) = d/dist; axis dot with that.
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(viewDir.x) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(viewDir.y) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(viewDir.z) < HIDE_THRESHOLD);

        circleXY.draw(program, locColor, vp);
        circleYZ.draw(program, locColor, vp);
        circleXZ.draw(program, locColor, vp);
        centerBox.draw(program, locColor, vp);
        arrowX.draw(program, locColor, vp);
        arrowY.draw(program, locColor, vp);
        arrowZ.draw(program, locColor, vp);
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
    float screenFraction = 0.15f;
    float size;              // world-space radius, updated each frame in draw()
    SemicircleHandler arcX, arcY, arcZ;

    this(Vec3 center) {
        this.center = center;
        arcX = new SemicircleHandler(center, Vec3(1,0,0), 1.0f, Vec3(0.9f, 0.2f, 0.2f));
        arcY = new SemicircleHandler(center, Vec3(0,1,0), 1.0f, Vec3(0.2f, 0.9f, 0.2f));
        arcZ = new SemicircleHandler(center, Vec3(0,0,1), 1.0f, Vec3(0.2f, 0.2f, 0.9f));
    }

    void destroy() { arcX.destroy(); arcY.destroy(); arcZ.destroy(); }
    void setPosition(Vec3 pos) { center = pos; }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        const ref float[16] view = vp.view;
        Vec3 eye = Vec3(
            -(view[0]*view[12] + view[4]*view[13] + view[8]*view[14]),
            -(view[1]*view[12] + view[5]*view[13] + view[9]*view[14]),
            -(view[2]*view[12] + view[6]*view[13] + view[10]*view[14]),
        );
        Vec3  d    = vec3Sub(eye, center);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        float depth = -(vp.view[2]*center.x + vp.view[6]*center.y +
                        vp.view[10]*center.z + vp.view[14]);
        if (depth < 1e-4f) depth = 1e-4f;
        size = screenFraction * depth / vp.proj[5];

        arcX.center = center; arcX.normal = Vec3(1,0,0); arcX.radius = size;
        arcY.center = center; arcY.normal = Vec3(0,1,0); arcY.radius = size;
        arcZ.center = center; arcZ.normal = Vec3(0,0,1); arcZ.radius = size;

        // Camera forward vector (world space): f = (-view[2], -view[6], -view[10])
        Vec3 camFwd = Vec3(-view[2], -view[6], -view[10]);

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

        arcX.draw(program, locColor, vp);
        arcY.draw(program, locColor, vp);
        arcZ.draw(program, locColor, vp);
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
        immutable float[3][8] cv = [
            [-1,-1,-1], [ 1,-1,-1], [ 1, 1,-1], [-1, 1,-1],
            [-1,-1, 1], [ 1,-1, 1], [ 1, 1, 1], [-1, 1, 1],
        ];
        immutable int[6][6] faces = [
            [0,1,2, 2,3,0],  // -Z
            [4,6,5, 6,4,7],  // +Z
            [0,4,5, 5,1,0],  // -Y
            [2,6,7, 7,3,2],  // +Y
            [0,3,7, 7,4,0],  // -X
            [1,5,6, 6,2,1],  // +X
        ];
        float[] data;
        foreach (ref f; faces)
            foreach (idx; f)
                data ~= cv[idx][];
        vertCount = cast(int)(data.length / 3);

        glGenVertexArrays(1, &vao); glGenBuffers(1, &vbo);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, data.length * float.sizeof, data.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    void destroy() {
        glDeleteVertexArrays(1, &vao);
        glDeleteBuffers(1, &vbo);
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        updateHover(vp);

        Vec3 c = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
               : selected ? Vec3(1.0f, 0.64f, 0.0f)
               :            color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                             Vec3(size, size, size), pos);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, vertCount);
        glBindVertexArray(0);

        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
    }

    // Fresh hit-test (does not rely on cached hover state).
    bool hitTest(int mx, int my, const ref Viewport vp)
    {
        return doHitTest(mx, my, vp);
    }

private:
    void updateHover(const ref Viewport vp)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        hovered = doHitTest(mx, my, vp);
    }

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
            Vec3 w = vec3Add(pos, Vec3(cv[i][0]*size, cv[i][1]*size, cv[i][2]*size));
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
        glGenVertexArrays(1, &outlineVao); glGenBuffers(1, &outlineVbo);
        glBindVertexArray(outlineVao);
        glBindBuffer(GL_ARRAY_BUFFER, outlineVbo);
        glBufferData(GL_ARRAY_BUFFER, outData.length * float.sizeof,
                     outData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

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

        glGenVertexArrays(1, &fillVao); glGenBuffers(1, &fillVbo);
        glBindVertexArray(fillVao);
        glBindBuffer(GL_ARRAY_BUFFER, fillVbo);
        glBufferData(GL_ARRAY_BUFFER, fillData.length * float.sizeof,
                     fillData.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    void destroy() {
        glDeleteVertexArrays(1, &outlineVao); glDeleteBuffers(1, &outlineVbo);
        glDeleteVertexArrays(1, &fillVao);    glDeleteBuffers(1, &fillVbo);
    }

    bool isSelected()        const { return selected; }
    void setSelected(bool v)       { selected = v; }

    bool hitTest(int mx, int my, const ref Viewport vp) {
        return doHitTest(mx, my, vp);
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        Vec3 fwd = normalize(normal);
        Vec3 tmp   = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);

        updateHover(vp, right, up);

        Vec3 oc = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
                : selected ? Vec3(1.0f, 0.64f, 0.0f)
                :            color;
        Vec3 fc = hovered  ? Vec3(1.0f, 0.95f, 0.15f)
                : selected ? Vec3(1.0f, 0.64f, 0.0f)
                :            fillColor;

        auto m = modelMatrix(right, up, fwd, Vec3(radius, radius, radius), center);

        GLint locModel = glGetUniformLocation(program, "u_model");
        glDisable(GL_DEPTH_TEST);

        // ---- Fill ----
        glUniform3f(locColor, fc.x, fc.y, fc.z);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(fillVao);
        glDrawArrays(GL_TRIANGLES, 0, fillVertCount);

        // ---- Outline ----
        drawThickLines(outlineVao, SEGS + 1, GL_LINE_STRIP, m, vp, oc, lineWidth, program);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !hovered) return false;
        selected = !selected;
        return true;
    }

private:
    void updateHover(const ref Viewport vp, Vec3 right, Vec3 up)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        hovered = doHitTest(mx, my, vp);
    }

    bool doHitTest(int mx, int my, const ref Viewport vp)
    {
        // Project SEGS circle points and check if mouse is inside the polygon.
        Vec3 fwd = normalize(normal);
        Vec3 tmp   = abs(fwd.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(fwd, tmp));
        Vec3 up    = cross(right, fwd);

        float[] xs, ys;
        foreach (i; 0 .. SEGS) {
            float a = 2.0f * PI * i / SEGS;
            Vec3 w = vec3Add(center,
                        vec3Add(vec3Scale(right, cos(a) * radius),
                                vec3Scale(up,    sin(a) * radius)));
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) return false;
            xs ~= sx;
            ys ~= sy;
        }
        return pointInPolygon2D(cast(float)mx, cast(float)my, xs, ys);
    }
}

// ---------------------------------------------------------------------------
// ScaleHandler : Handler — three axis CubicArrows (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class ScaleHandler : Handler {
    Vec3  center;
    float screenFraction = 0.15f;
    CubicArrow arrowX, arrowY, arrowZ;
    Vec3 viewDir;

    this(Vec3 center) {
        this.center = center;
        arrowX = new CubicArrow(vec3Add(center, Vec3(0.1f,0,0)), vec3Add(center, Vec3(1,0,0)), Vec3(0.9f, 0.2f, 0.2f));
        arrowY = new CubicArrow(vec3Add(center, Vec3(0,0.1f,0)), vec3Add(center, Vec3(0,1,0)), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ = new CubicArrow(vec3Add(center, Vec3(0,0,0.1f)), vec3Add(center, Vec3(0,0,1)), Vec3(0.2f, 0.2f, 0.9f));
    }

    void destroy() {
        arrowX.destroy();
        arrowY.destroy();
        arrowZ.destroy();
    }

    void setPosition(Vec3 pos) {
        center = pos;
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        const ref float[16] view = vp.view;
        Vec3 eye = Vec3(
            -(view[0]*view[12] + view[4]*view[13] + view[8]*view[14]),
            -(view[1]*view[12] + view[5]*view[13] + view[9]*view[14]),
            -(view[2]*view[12] + view[6]*view[13] + view[10]*view[14]),
        );

        Vec3  d    = vec3Sub(eye, center);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        float depth = -(vp.view[2]*center.x + vp.view[6]*center.y +
                        vp.view[10]*center.z + vp.view[14]);
        if (depth < 1e-4f) depth = 1e-4f;
        float size = screenFraction * depth / vp.proj[5];

        arrowX.start = vec3Add(center, Vec3(size/10, 0,      0     ));
        arrowX.end   = vec3Add(center, Vec3(size,    0,      0     ));
        arrowY.start = vec3Add(center, Vec3(0,       size/10, 0    ));
        arrowY.end   = vec3Add(center, Vec3(0,       size,    0    ));
        arrowZ.start = vec3Add(center, Vec3(0,       0,      size/10));
        arrowZ.end   = vec3Add(center, Vec3(0,       0,      size  ));

        viewDir = dist > 1e-6f
            ? Vec3(d.x / dist, d.y / dist, d.z / dist)
            : Vec3(0,0,1);
        enum float HIDE_THRESHOLD = 0.995f;
        arrowX.setVisible(abs(viewDir.x) < HIDE_THRESHOLD);
        arrowY.setVisible(abs(viewDir.y) < HIDE_THRESHOLD);
        arrowZ.setVisible(abs(viewDir.z) < HIDE_THRESHOLD);

        arrowX.draw(program, locColor, vp);
        arrowY.draw(program, locColor, vp);
        arrowZ.draw(program, locColor, vp);
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