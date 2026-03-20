module handler;

import bindbc.sdl;
import bindbc.opengl;

import std.math : tan, sin, cos, sqrt, PI, abs;

import math;
import eventlog;

// ---------------------------------------------------------------------------
// Handler — base class for interactive 3-D overlays (gizmos, manipulators…)
// ---------------------------------------------------------------------------

class Handler {
    // Called once per frame to render the overlay into the 3-D view.
    // view / proj are the current camera matrices; winW/winH are window dims.
    void draw(GLuint program, GLint locColor,
              const ref float[16] view, const ref float[16] proj,
              int winW, int winH) {}

    // Mouse events — return true to consume (stops further processing).
    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseButtonUp  (ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseMotion    (ref const SDL_MouseMotionEvent  e) { return false; }

    // Keyboard events — return true to consume.
    bool onKeyDown(ref const SDL_KeyboardEvent e) { return false; }
    bool onKeyUp  (ref const SDL_KeyboardEvent e) { return false; }
}

// ---------------------------------------------------------------------------
// Arrow : Handler
// Unit shaft  — line  (0,0,0)→(0,0,1)  along +Z
// Unit cone   — tip at Z=1, base at Z=0, radius=1
// Both are created once; draw() transforms them via u_model.
// ---------------------------------------------------------------------------

class Arrow : Handler {
    Vec3 start;
    Vec3 end;
    Vec3 color;

private:
    GLuint shaftVao, shaftVbo;
    GLuint headVao,  headVbo;
    int    headVertCount;
    bool   hovered;
    bool   forceHovered;
    bool   hoverBlocked;
    bool   visible = true;

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

    bool isHovered()    const { return hovered; }
    void setForceHovered(bool v) { forceHovered  = v; }
    void setHoverBlocked(bool v) { hoverBlocked  = v; }
    void setVisible(bool v)      { visible = v; if (!v) hovered = false; }
    bool isVisible() const       { return visible; }

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
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

        updateHover(view, proj, winW, winH);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        // ---- Draw shaft ----
        auto shaftModel = modelMatrix(right, up, fwd,
                                      Vec3(1, 1, shaftLen), start);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, shaftModel.ptr);
        glBindVertexArray(shaftVao);
        glDrawArrays(GL_LINES, 0, 2);

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
    void updateHover(const ref float[16] view, const ref float[16] proj,
                     int winW, int winH)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, view, proj, winW, winH, sax, say, ndcZa) ||
            !projectToWindowFull(end,   view, proj, winW, winH, sbx, sby, ndcZb))
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
    Vec3 start;
    Vec3 end;
    Vec3 color;

private:
    GLuint shaftVao, shaftVbo;
    GLuint headVao,  headVbo;
    int    headVertCount;
    bool   hovered;
    bool   forceHovered;
    bool   hoverBlocked;
    bool   visible = true;

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

    bool isHovered()         const { return hovered; }
    void setForceHovered(bool v)   { forceHovered = v; }
    void setHoverBlocked(bool v)   { hoverBlocked = v; }
    void setVisible(bool v)        { visible = v; if (!v) hovered = false; }
    bool isVisible()         const { return visible; }

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
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

        updateHover(view, proj, winW, winH);
        Vec3 c = hovered ? Vec3(1.0f, 0.95f, 0.15f) : color;

        GLint locModel = glGetUniformLocation(program, "u_model");
        glUniform3f(locColor, c.x, c.y, c.z);

        glDisable(GL_DEPTH_TEST);

        // ---- Draw shaft ----
        auto shaftModel = modelMatrix(right, up, fwd,
                                      Vec3(1, 1, shaftLen), start);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, shaftModel.ptr);
        glBindVertexArray(shaftVao);
        glDrawArrays(GL_LINES, 0, 2);

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
    void updateHover(const ref float[16] view, const ref float[16] proj,
                     int winW, int winH)
    {
        if (hoverBlocked) { hovered = false; return; }
        if (forceHovered) { hovered = true;  return; }
        int mx, my;
        queryMouse(mx, my);
        float sax, say, ndcZa, sbx, sby, ndcZb;
        if (!projectToWindowFull(start, view, proj, winW, winH, sax, say, ndcZa) ||
            !projectToWindowFull(end,   view, proj, winW, winH, sbx, sby, ndcZb))
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
// MoveHandler : Handler — three axis arrows (X=red, Y=green, Z=blue)
// ---------------------------------------------------------------------------

class MoveHandler : Handler {
    Vec3  center;
    float screenFraction = 0.15f;  // gizmo size as fraction of eye-to-center distance
    Arrow arrowX, arrowY, arrowZ;
    Vec3 viewDir;

    this(Vec3 center) {
        this.center = center;
        arrowX = new Arrow(vec3Add(center, Vec3(0.1f,0,0)), vec3Add(center, Vec3(1,0,0)), Vec3(0.9f, 0.2f, 0.2f));
        arrowY = new Arrow(vec3Add(center, Vec3(0,0.1f,0)), vec3Add(center, Vec3(0,1,0)), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ = new Arrow(vec3Add(center, Vec3(0,0,0.1f)), vec3Add(center, Vec3(0,0,1)), Vec3(0.2f, 0.2f, 0.9f));
    }

    void destroy() {
        arrowX.destroy();
        arrowY.destroy();
        arrowZ.destroy();
    }

    void setPosition(Vec3 pos) {
        center = pos;
    }

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
    {
        // Extract eye position from view matrix (view = R*T, eye = -R^T * t).
        Vec3 eye = Vec3(
            -(view[0]*view[12] + view[4]*view[13] + view[8]*view[14]),
            -(view[1]*view[12] + view[5]*view[13] + view[9]*view[14]),
            -(view[2]*view[12] + view[6]*view[13] + view[10]*view[14]),
        );

        Vec3  d    = vec3Sub(eye, center);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        float size = dist * screenFraction;

        arrowX.start = vec3Add(center, Vec3(size/10, 0,    0   ));;
        arrowX.end = vec3Add(center, Vec3(size, 0,    0   ));
        arrowY.start = vec3Add(center, Vec3(0,    size/10, 0   ));;
        arrowY.end = vec3Add(center, Vec3(0,    size, 0   ));
        arrowZ.start = vec3Add(center, Vec3(0,    0,    size/10));
        arrowZ.end = vec3Add(center, Vec3(0,    0,    size));

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

        arrowX.draw(program, locColor, view, proj, winW, winH);
        arrowY.draw(program, locColor, view, proj, winW, winH);
        arrowZ.draw(program, locColor, view, proj, winW, winH);
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

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
    {
        Vec3 eye = Vec3(
            -(view[0]*view[12] + view[4]*view[13] + view[8]*view[14]),
            -(view[1]*view[12] + view[5]*view[13] + view[9]*view[14]),
            -(view[2]*view[12] + view[6]*view[13] + view[10]*view[14]),
        );

        Vec3  d    = vec3Sub(eye, center);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        float size = dist * screenFraction;

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

        arrowX.draw(program, locColor, view, proj, winW, winH);
        arrowY.draw(program, locColor, view, proj, winW, winH);
        arrowZ.draw(program, locColor, view, proj, winW, winH);
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