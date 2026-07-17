module handles.shapes;

import handles.gl_util;
import math;
import shader;
import bindbc.sdl;
import bindbc.opengl;
import std.math : sin, cos, sqrt, PI, abs;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import ai.interaction : AiIntent;

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

// HandleState → lowercase string, for JSON serialization (task 0234,
// /api/tool/handles). Deliberately a string, not the raw enum int: a future
// reordering of HandleState's declaration can't silently shift a test's
// meaning the way an int would.
string handleStateToString(HandleState state) {
    final switch (state) {
        case HandleState.Normal:           return "normal";
        case HandleState.Rollover:         return "rollover";
        case HandleState.Selected:         return "selected";
        case HandleState.SecondaryDefault: return "secondaryDefault";
    }
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

    // A representative screen-space pixel for this handle, for test
    // introspection (task 0234, /api/tool/handles) — "press here to grab this
    // handle". Returns false when the handle has no stable world position to
    // project (e.g. it's off-camera) or the base class default (no geometry).
    // Override per handle-geometry family; see ShaftedArrow / the disc-family
    // handlers below. Center-based overrides are serialization-only — a
    // rim/tangent point (needed for a semantically correct rotate/scale
    // drag-by-part press) is a follow-up, out of scope here.
    bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const {
        return false;
    }

    // Override in subclasses to define the hover hit area.
    public bool hitTest(int mx, int my, const ref Viewport vp) { return false; }
    public float aiScreenDistance(int mx, int my, const ref Viewport vp) {
        return float.infinity;
    }
    public AiIntent aiIntentForPart(int part) const {
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

    // Grab point at 70% along the shaft from start toward end — matches the
    // press convention drag tests use against the real gizmo geometry (well
    // clear of the centerBox at `start`'s end and any plane handle beyond
    // `end`). See tests/drag_helpers.d's axisGrabPx for the prior duplicated
    // approximation this replaces at the call site.
    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        Vec3 grab = start + (end - start) * 0.7f;
        float ndcZ;
        return projectToWindowFull(grab, vp, sx, sy, ndcZ);
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

    // Center-based anchor — serialization-only. A rotate ring's semantically
    // "correct" grab point is a point ON the arc, not its center; that needs a
    // reference direction the JSON caller doesn't have (out of scope here —
    // see doc/tool_handles_state_plan.md risk 2 / the base class doc comment).
    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        float ndcZ;
        return projectToWindowFull(center, vp, sx, sy, ndcZ);
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

    // Center-based anchor — serialization-only (same caveat as
    // SemicircleHandler.screenAnchor above).
    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        float ndcZ;
        return projectToWindowFull(center, vp, sx, sy, ndcZ);
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

    // Multiplier applied on top of the default `size*0.04` centerBox
    // half-extent. Default 1.0 leaves every existing MoveHandler user
    // (MoveTool, primitive movers) byte-identical; MirrorTool (task 0230)
    // sets this > 1 so its "large box" click-to-place/move handle reads
    // distinctly bigger than the small rotate box beside it.
    float centerBoxScale = 1.0f;

    // Master gate for the three axis arrows. Default true leaves every
    // existing MoveHandler user byte-identical; MirrorTool (task 0233) sets
    // this false so its gizmo shows ONLY the center box (+ its own rotate box
    // + plane viz) — no axis arrows. Applied inside updateGeometry so it wins
    // over the per-frame ortho-cull re-enable below (a plain setVisible(false)
    // in the ctor would be overwritten every frame); a false arrow is then
    // skipped by Arrow.draw (visible guard), by ToolHandles.test (invisible
    // handles skipped), and by MirrorTool.moverHitTest (isVisible guard) — so
    // it drops from BOTH draw and hit-test.
    bool arrowsVisible = true;

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

    // Task 0212 (rotate/scale hover-highlight flicker): CPU-only, idempotent
    // re-layout of this handler's hit geometry under `vp`, with NO GL side
    // effects. Public forwarder to the private `updateGeometry` so the
    // shared cross-bank arbiter (XfrmTransformTool) can refresh the OWNER
    // cell's hit geometry immediately before `ToolHandles.test()` resolves —
    // closing the window where a foreign (non-owner) cell's last `draw()`
    // left camera-dependent members (e.g. RotateHandler.startAngle,
    // ScaleHandler's centerDisk normal/radius) stale for the Test pass. See
    // doc/rotate_scale_hover_flicker_plan.md.
    void syncGeometry(const ref Viewport vp) { updateGeometry(vp); }

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
        centerBox.size = size * 0.04f * centerBoxScale;

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

        // Orthographic cull (task 0225): in an ORTHO cell the axis arrow
        // parallel to the (parallel) view direction is edge-on — zero on-screen
        // length, useless to drag — so hide it AND drop it from the hit-test
        // (the shared arbiter's ToolHandles.test() skips invisible handles).
        // PERSPECTIVE keeps all three arrows. The view direction is the camera
        // forward derived from the view matrix — correct for ortho's parallel
        // projection (the eye→center ray is only right when the gizmo sits at
        // the focus), so the cull is right for a gizmo offset from the focus and
        // for a non-world (workplane/flex) basis.
        viewDir = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        enum float VIEW_ALIGN = 0.999f;
        bool ortho = isOrtho(vp);
        arrowX.setVisible(arrowsVisible && (!ortho || abs(dot(viewDir, axisX)) < VIEW_ALIGN));
        arrowY.setVisible(arrowsVisible && (!ortho || abs(dot(viewDir, axisY)) < VIEW_ALIGN));
        arrowZ.setVisible(arrowsVisible && (!ortho || abs(dot(viewDir, axisZ)) < VIEW_ALIGN));
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

    // Hit-test the mover rig (centerBox + 3 axis arrows): 3=centerBox,
    // 0/1/2=arrowX/Y/Z, -1=miss. Lifted verbatim (task 0410, dedup 0407
    // §A.D5) from the private `moverHitTest` idiom every primitive
    // create-tool (cylinder.d, capsule.d, cone.d, torus.d, tube.d, sphere.d,
    // box.d) repeated — diff-confirmed byte-identical bodies.
    //
    // `alias hitTest = Handler.hitTest;` is required: this overload has the
    // same name+params as the inherited `protected bool hitTest(int, int,
    // const ref Viewport)` but a different (non-covariant) return type,
    // which D treats as hiding the base method — a hard compile error
    // ("is hidden by ...") unless the base overload is explicitly
    // re-introduced. Harmless here: MoveHandler is never registered whole
    // into ToolHandles (only its sub-handles are), so the base bool
    // hitTest is never reached polymorphically through a MoveHandler.
    alias hitTest = Handler.hitTest;
    int hitTest(int mx, int my, const ref Viewport vp) {
        if (centerBox.hitTest(mx, my, vp)) return 3;
        Arrow[3] arrows = [arrowX, arrowY, arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, vp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   vp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
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

    // Task 0212: see MoveHandler.syncGeometry — same idempotent CPU-only
    // re-layout forwarder. Re-derives `startAngle` (arcX/Y/Z) from the
    // passed `vp`'s `camFwd`, which is the exact stale member the flicker's
    // root cause reads through a Test-before-Draw ordering hole.
    void syncGeometry(const ref Viewport vp) { updateGeometry(vp); }

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

        // Orthographic cull (task 0225): in an ORTHO cell a principal ring is
        // face-on (useful — its rotation axis points at the camera, i.e. screen
        // rotation) only when its axis is PARALLEL to the view direction; the
        // other two rings are edge-on (their planes are seen as a line — near
        // impossible to grab), so hide them and drop them from the hit-test.
        // The view-plane ring (arcView, normal = camFwd) always stays — it is
        // the screen-plane rotation. PERSPECTIVE keeps all three arcs. This is
        // the INVERSE of the Move/Scale rule (which hides the axis PARALLEL to
        // the view): an arrow is useful when in-plane, a ring when face-on.
        enum float VIEW_ALIGN = 0.999f;
        bool ortho = isOrtho(vp);
        arcX.setVisible(!ortho || abs(dot(camFwd, axisX)) >= VIEW_ALIGN);
        arcY.setVisible(!ortho || abs(dot(camFwd, axisY)) >= VIEW_ALIGN);
        arcZ.setVisible(!ortho || abs(dot(camFwd, axisZ)) >= VIEW_ALIGN);
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

    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        float ndcZ;
        return projectToWindowFull(pos, vp, sx, sy, ndcZ);
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

    // Center-based anchor — serialization-only (same caveat as
    // SemicircleHandler.screenAnchor above).
    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        float ndcZ;
        return projectToWindowFull(center, vp, sx, sy, ndcZ);
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

    // Center-based anchor — serialization-only (same caveat as
    // SemicircleHandler.screenAnchor above).
    override bool screenAnchor(const ref Viewport vp, out float sx, out float sy) const
    {
        float ndcZ;
        return projectToWindowFull(center, vp, sx, sy, ndcZ);
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
    // When true (uniform-scale preset), only the centre disc is drawn and
    // registered for hover/click; per-axis arrows and plane circles are
    // suppressed. Set each frame from XfrmTransformTool.registerGizmoHandles.
    public bool uniformMode = false;
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

    // Task 0212: see MoveHandler.syncGeometry — same idempotent CPU-only
    // re-layout forwarder. Keeps the default `axisBoxDistance` (the ONLY
    // value any draw call site uses — verified: `draw()` and
    // `drawAxisBoxesOnly()` both call `updateGeometry(vp)` with no override),
    // so the synced geometry matches whichever bank draw runs afterward.
    // Re-derives `centerDisk.normal`/`radius` (camFwd/gizmoSize-dependent —
    // the stale members `CenterDiskGizmo.diskHitCheck` reads) plus the plane
    // circles' gizmoSize-offset centers.
    void syncGeometry(const ref Viewport vp) { updateGeometry(vp); }

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

        // Orthographic cull (task 0225) — mirror of MoveHandler: hide the axis
        // box/arrow parallel to the view direction (edge-on) in an ORTHO cell
        // and drop it from the hit-test (the ScaleHeadHandle proxy also reports
        // no-hit once its target arrow is invisible). PERSPECTIVE keeps all
        // three. Uses the camera forward (ortho's parallel projection dir).
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        viewDir = camFwd;
        enum float VIEW_ALIGN = 0.999f;
        bool ortho = isOrtho(vp);
        arrowX.setVisible(!ortho || abs(dot(camFwd, axisX)) < VIEW_ALIGN);
        arrowY.setVisible(!ortho || abs(dot(camFwd, axisY)) < VIEW_ALIGN);
        arrowZ.setVisible(!ortho || abs(dot(camFwd, axisZ)) < VIEW_ALIGN);

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
        if (!uniformMode) {
            circleXY.draw(shader, vp);
            circleYZ.draw(shader, vp);
            circleXZ.draw(shader, vp);
            arrowX.draw(shader, vp);
            arrowY.draw(shader, vp);
            arrowZ.draw(shader, vp);
        }
        centerDisk.draw(shader, vp);
        if (!uniformMode) {
            if (activeDragAxis == 0 && scaleAccum.x != 0.0f) scaleArrowX.draw(shader, vp);
            if (activeDragAxis == 1 && scaleAccum.y != 0.0f) scaleArrowY.draw(shader, vp);
            if (activeDragAxis == 2 && scaleAccum.z != 0.0f) scaleArrowZ.draw(shader, vp);
        }
    }

    void drawAxisBoxesOnly(const ref Shader shader, const ref Viewport vp)
    {
        updateGeometry(vp);
        if (!uniformMode) {
            arrowX.drawHeadOnly(shader, vp);
            arrowY.drawHeadOnly(shader, vp);
            arrowZ.drawHeadOnly(shader, vp);
            if (activeDragAxis == 0 && scaleAccum.x != 0.0f) scaleArrowX.drawHeadOnly(shader, vp);
            if (activeDragAxis == 1 && scaleAccum.y != 0.0f) scaleArrowY.drawHeadOnly(shader, vp);
            if (activeDragAxis == 2 && scaleAccum.z != 0.0f) scaleArrowZ.drawHeadOnly(shader, vp);
        }
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
