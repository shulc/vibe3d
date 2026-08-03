module handles.shapes;

import handles.gl_util;
import math;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import shader;
import viewport_scheme;
import bindbc.sdl;
import bindbc.opengl;
import std.math : sin, cos, sqrt, PI, abs;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import ai.interaction : AiIntent;

// A scheme colour packed for the ImGui overlay draw lists, at an explicit
// alpha. Rounds rather than truncates, so 1.0 lands on 255 and not 254.
private uint packImCol(Vec3 c, ubyte alpha) {
    static int ch(float v) {
        const int i = cast(int)(v * 255.0f + 0.5f);
        return i < 0 ? 0 : (i > 255 ? 255 : i);
    }
    return IM_COL32(ch(c.x), ch(c.y), ch(c.z), cast(int)alpha);
}

// ---------------------------------------------------------------------------
// HandleState — the ARBITRATION state (which handle won the hit test, plus the
// advisory hints layered on top of it).
//
// NOTE what this enum is NOT, since it used to be both: it is no longer the
// handle's COLOUR state. Task 0596 split the two, because they answer
// different questions and only one of them drives pixels.
//
//   * HandleState answers "which handle would a press grab, and what does the
//     advisor think about that" — it is the hit-test result plus the AI
//     copilot's default hint. It is consumed by `handles/arbiter.d`, by the
//     copilot lane, and it is serialised over /api/tool/handles.
//   * `Handler.engaged` answers "is this handle being HAULED right now" — and
//     that, alone, is what recolours a handle. See `viewport_scheme.handleColor`.
//
// The enum kept all four members deliberately. `SecondaryDefault` carries the
// copilot's deterministic-default hint (arbiter.d) and is asserted across
// tests/test_ai_handle_candidates.d and tests/test_ai_model_live_wiring.d;
// `Rollover` is the arbiter's hot-part concept and part of the JSON contract
// below. Collapsing the enum would have broken three unrelated consumers to
// express a fact about drawing. Collapsing the COLOUR LAW — which is where the
// two-state model actually belongs — cost nothing and is done.
// ---------------------------------------------------------------------------

enum HandleState { Normal, Rollover, Selected, SecondaryDefault }

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

    // Is this handle being HAULED right now? The one bit that recolours a
    // handle (see viewport_scheme.handleColor). Driven by ToolHandles.update
    // from its CAPTURE, never from its hit test: the highlight marks the
    // grabbed handle, armed by the press that captured it and cleared on
    // release. A handle under the bare pointer stays its own colour.
    //
    // Scalar, so the class .init blob has nothing to alias — cf. the array
    // field that shipped one shared store to every instance in task 0590.
    bool   engaged = false;

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

    // Haul accessors — likewise driven by the arbiter, from its capture.
    void setEngaged(bool e) { engaged = e; }
    bool isEngaged() const  { return engaged; }

    // The colour to draw this handle in: its own `idle` colour, or the
    // scheme's active colour while hauled. Every shape's draw() goes through
    // here so the two-state law has exactly one implementation.
    //
    // INTERIM — a hover cue sits ON TOP of that law, deliberately not inside
    // it. The read that removed the pre-press hover highlight rests on
    // ABSENCE (no colour lookup found on any handle path) rather than on a
    // positive observation, and its own author flagged that only a live
    // capture could close it. Meanwhile a real affordance was gone: the
    // pointer over a handle said nothing. So hover paints the measured
    // ACTIVE colour — a value we have measured, not one invented to fill the
    // gap — until that capture lands.
    //
    // Kept out of `viewport_scheme.handleColor` on purpose: that function is
    // the measured law and its test pins it. When the capture answers, this
    // block is deleted (no cue) or given its own row (a distinct cue), and
    // the law underneath is untouched either way.
    protected Vec3 drawColor(Vec3 idle) const {
        if (engaged) return handleColor(idle, true);
        if (state == HandleState.Rollover)
            return schemeColor(SchemeColor.handleActive);
        return handleColor(idle, false);
    }

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
        return aiScreenDistance(mx, my, vp) < GIZMO_PICK_AXIS_PX;
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

    // Task 0597. If > 0, these override the flat fractions of the arrow's own
    // length. The transform gizmo needs them because its arrowhead is CLAMPED
    // in pixels — it grows with the arm only up to a knee — and a fraction
    // cannot clamp. Same shape as CubicArrow.fixedCubeHalf below, and the same
    // default: 0 means "keep the ratio", so every arrow that sets neither
    // (falloff endpoint handles, primitive create-tool movers) is untouched.
    float fixedConeLen  = 0.0f;  // world length of the head along the axis
    float fixedConeHalf = 0.0f;  // world radius of the head's base

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

        float coneLen    = fixedConeLen  > 0.0f ? fixedConeLen
                                                : len * GIZMO_CONE_LEN_OF_LEN;
        float coneRadius = fixedConeHalf > 0.0f ? fixedConeHalf
                                                : len * GIZMO_CONE_RADIUS_OF_LEN;
        float shaftLen   = len - coneLen;
        // An overridden head is a PIXEL size and the shaft is a world one, so
        // a short enough arrow can be all head. Mirrors CubicArrow's guard.
        if (shaftLen < 0.0f) shaftLen = 0.0f;
        Vec3  coneBase   = end - fwd * coneLen;

        Vec3 c = drawColor(color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto shaftModel = modelMatrix(right, up, fwd, Vec3(1, 1, shaftLen), start);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, shader.program);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        auto headModel = modelMatrix(right, up, fwd, Vec3(coneRadius, coneRadius, coneLen), coneBase);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);
        g_fc.draw(DrawPass.handles, headVertCount);

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

        float cubeHalf   = fixedCubeHalf > 0.0f ? fixedCubeHalf : len * GIZMO_CUBE_HEAD_HALF_OF_LEN;
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

        Vec3 c = drawColor(color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto shaftModel = modelMatrix(right, up, fwd, Vec3(1, 1, shaftLen), shaftOrigin);
        drawThickLines(shaftVao, 2, GL_LINES, shaftModel, vp, c, lineWidth, shader.program);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);
        g_fc.draw(DrawPass.handles, headVertCount);

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

        float cubeHalf   = fixedCubeHalf > 0.0f ? fixedCubeHalf : len * GIZMO_CUBE_HEAD_HALF_OF_LEN;
        Vec3  cubeCenter = end - fwd * cubeHalf;
        Vec3 c = drawColor(color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);
        g_fc.draw(DrawPass.handles, headVertCount);

        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
    }
}

// ---------------------------------------------------------------------------
// SemicircleHandler : Handler
// Draws a half-circle arc (0..π) with a given color.
// Takes the scheme's active colour while hauled; hover does not recolour it.
//
// ONE colour, and only ever one: a rotate ring's far half is CULLED, not
// dimmed. This class draws the camera-facing half only — `RotateHandler`
// re-derives `startAngle` every frame from the intersection of the ring plane
// with the view plane and flips it so the arc's midpoint faces the viewer, so
// the half pointing away is simply absent. `aiScreenDistance` walks the SAME
// arc span, which is what keeps the drawn ring and the grabbable ring the same
// object. A second, darker "back-half" colour would be modelling a thing that
// is not drawn — do not add one.
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

        Vec3 c = drawColor(color);

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
        return aiScreenDistance(mx, my, vp) < GIZMO_PICK_RING_PX;
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

        Vec3 c = drawColor(color);

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
        return aiScreenDistance(mx, my, vp) < GIZMO_PICK_RING_PX;
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
        arrowX    = new Arrow(center + Vec3(0.1f,0,0), center + Vec3(1,0,0), axisColor(0));
        arrowY    = new Arrow(center + Vec3(0,0.1f,0), center + Vec3(0,1,0), axisColor(1));
        arrowZ    = new Arrow(center + Vec3(0,0,0.1f), center + Vec3(0,0,1), axisColor(2));
        // The centre handle belongs to no axis, so it takes the scheme's
        // axis-less `handle` colour.
        centerBox = new BoxHandler(center, schemeColor(SchemeColor.handle));
        // Plane handles: outline in the colour of the axis NORMAL to the
        // plane, fill derived from it (see viewport_scheme.planeFillColor).
        circleXY  = new CircleHandler(center + Vec3(1, 1,0), Vec3(0,0,1), 1.0f,
                        axisColor(2), planeFillColor(axisColor(2)));
        circleYZ  = new CircleHandler(center + Vec3(0,1,1), Vec3(1,0,0), 1.0f,
                        axisColor(0), planeFillColor(axisColor(0)));
        circleXZ  = new CircleHandler(center + Vec3(1,0,1), Vec3(0,1,0), 1.0f,
                        axisColor(1), planeFillColor(axisColor(1)));
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
        arrowX.start = center + axisX * (size/GIZMO_MOVE_SHAFT_INSET_DIV);
        arrowX.end   = center + axisX * (size * GIZMO_MOVE_ARM);
        arrowY.start = center + axisY * (size/GIZMO_MOVE_SHAFT_INSET_DIV);
        arrowY.end   = center + axisY * (size * GIZMO_MOVE_ARM);
        arrowZ.start = center + axisZ * (size/GIZMO_MOVE_SHAFT_INSET_DIV);
        arrowZ.end   = center + axisZ * (size * GIZMO_MOVE_ARM);

        // Task 0597: the arrowhead is CLAMPED, not a fraction of the shaft. It
        // grows with the arm to a knee near handle-size 1.25 and then stops —
        // so at the largest handle size the arm is 5x its default while the
        // head is 1.25x. Pushed in as world lengths converted from the pixel
        // law; leaving these unset would put the head back on a flat ratio.
        immutable float headLen  = gizmoPixelSize(center, vp, gizmoHeadLenPx());
        immutable float headHalf = gizmoPixelSize(center, vp, gizmoHeadHalfPx());
        arrowX.fixedConeLen = headLen; arrowX.fixedConeHalf = headHalf;
        arrowY.fixedConeLen = headLen; arrowY.fixedConeHalf = headHalf;
        arrowZ.fixedConeLen = headLen; arrowZ.fixedConeHalf = headHalf;

        // Same law for the centre handle: 5 px at the default handle size, and
        // exactly three distinct sizes over the whole reachable range. The
        // grab region for this box is its drawn silhouette (see the pick-region
        // note in handles/gl_util.d), so it follows the drawn size as it always
        // has — no separate hit size is introduced here.
        centerBox.pos  = center;
        centerBox.size = gizmoPixelSize(center, vp, gizmoBoxHalfPx()) * centerBoxScale;

        // The ring's RADIUS is a plain pixel count; its OFFSET scales with the
        // arm. That asymmetry is the reference's (task 0553) — grow the gizmo
        // and the rings move outward without growing.
        float circR = gizmoPixelSize(center, vp, GIZMO_PLANE_RADIUS_PX);
        float cirOffset = size * GIZMO_PLANE_OFFSET;
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
                                   sax, say, sbx, sby, t) < GIZMO_PICK_AXIS_PX)
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
        arcX     = new SemicircleHandler(center, Vec3(1,0,0), 1.0f, axisColor(0));
        arcY     = new SemicircleHandler(center, Vec3(0,1,0), 1.0f, axisColor(1));
        arcZ     = new SemicircleHandler(center, Vec3(0,0,1), 1.0f, axisColor(2));
        // The screen-plane ring belongs to no axis — flat grey, by law, and
        // not a preference row (viewport_scheme.kViewRingGrey).
        arcView  = new FullCircleHandler(center, Vec3(0,0,1), 1.0f, kViewRingGrey);
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

        arcX.center = center; arcX.normal = axisX; arcX.radius = size * GIZMO_RING_RADIUS;
        arcY.center = center; arcY.normal = axisY; arcY.radius = size * GIZMO_RING_RADIUS;
        arcZ.center = center; arcZ.normal = axisZ; arcZ.radius = size * GIZMO_RING_RADIUS;

        // Camera forward vector (world space): f = (-view[2], -view[6], -view[10])
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

        // Decorative black ring: same plane and radius as X/Y/Z arcs, drawn first (behind)
        bgCircle.center = center;
        bgCircle.normal = camFwd;
        bgCircle.radius = size * GIZMO_RING_RADIUS;

        // View-plane ring: normal = camera forward, radius slightly larger than axis arcs
        arcView.center = center;
        arcView.normal = camFwd;
        arcView.radius = size * GIZMO_VIEW_RING_RADIUS;

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
// Takes the scheme's active colour while hauled, or when the owning tool has
// marked it current (`selected`). Hover does not recolour it.
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
        // `selected` marks a handle the owning tool has made CURRENT (the only
        // setter is the pen's current-point marker). It reads as engaged, and
        // takes the scheme's active colour — not the mesh-selection orange it
        // used to borrow. That orange belongs to selected geometry; a handle
        // wearing it says "you have selected some mesh", which is a lie.
        Vec3 c = handleColor(color, engaged || selected);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                             Vec3(size, size, size), pos);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, vertCount);
        g_fc.draw(DrawPass.handles, vertCount);
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
// While hauled the FILL takes the scheme's active colour; the outline keeps
// its axis colour, so which plane this is stays legible. Hover does not recolour.
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

        // A plane handle is TWO concentric parts, and they do not light up
        // together: the outline ring keeps its axis colour even while hauled
        // (the ring says WHICH plane this is, and grabbing it does not change
        // which plane it is), while the fill disc inside takes the active
        // colour. Highlighting the outline too would erase the only cue that
        // tells the three plane handles apart at the moment you most need it.
        Vec3 oc = color;
        Vec3 fc = handleColor(fillColor, engaged);

        auto m = modelMatrix(right, up, fwd, Vec3(radius, radius, radius), center);

        glDisable(GL_DEPTH_TEST);

        // ---- Fill ----
        glUniform3f(shader.locColor, fc.x, fc.y, fc.z);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, m.ptr);
        glBindVertexArray(fillVao);
        glDrawArrays(GL_TRIANGLES, 0, fillVertCount);
        g_fc.draw(DrawPass.handles, fillVertCount);

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

        // The screen-plane disc is an axis-less handle: the scheme's `handle`
        // colour idle, the active colour while hauled. Two states, one law —
        // the four-way switch that used to live here painted a hover yellow
        // and a selection orange for states this handle has no business
        // distinguishing. Alphas are ours and unchanged by task 0596.
        const Vec3 c = handleColor(schemeColor(SchemeColor.handle), engaged);
        const uint fillCol    = packImCol(c,  80);
        const uint outlineCol = packImCol(c, 200);

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
    enum float AXIS_BOX_DISTANCE = GIZMO_SCALE_ARM;

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
        arrowX      = new CubicArrow(center + Vec3(0.1f,0,0), center + Vec3(1,0,0), axisColor(0));
        arrowY      = new CubicArrow(center + Vec3(0,0.1f,0), center + Vec3(0,1,0), axisColor(1));
        arrowZ      = new CubicArrow(center + Vec3(0,0,0.1f), center + Vec3(0,0,1), axisColor(2));
        // The scale-feedback arrows wear their AXIS colour, not a hand-picked
        // yellow. A scale arrow is the same axis as the arm it grows out of,
        // and colouring all three identically threw that away — the one thing
        // the arrow has to communicate is WHICH axis is being scaled.
        scaleArrowX = new CubicArrow(center, center + Vec3(1,0,0), axisColor(0));
        scaleArrowY = new CubicArrow(center, center + Vec3(0,1,0), axisColor(1));
        scaleArrowZ = new CubicArrow(center, center + Vec3(0,0,1), axisColor(2));
        scaleArrowX.fixedDir = Vec3(1, 0, 0);
        scaleArrowY.fixedDir = Vec3(0, 1, 0);
        scaleArrowZ.fixedDir = Vec3(0, 0, 1);
        centerDisk  = new CenterDiskGizmo();
        // Plane handles: outline in the colour of the axis NORMAL to the plane.
        circleXY = new CircleHandler(center, Vec3(0,0,1), 1.0f,
                        axisColor(2), planeFillColor(axisColor(2)));
        circleYZ = new CircleHandler(center, Vec3(1,0,0), 1.0f,
                        axisColor(0), planeFillColor(axisColor(0)));
        circleXZ = new CircleHandler(center, Vec3(0,1,0), 1.0f,
                        axisColor(1), planeFillColor(axisColor(1)));
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

        arrowX.start = center + axisX * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowX.end   = center + axisX * (size * axisBoxDistance);
        arrowY.start = center + axisY * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowY.end   = center + axisY * (size * axisBoxDistance);
        arrowZ.start = center + axisZ * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowZ.end   = center + axisZ * (size * axisBoxDistance);

        // Task 0597: one clamped box size, shared by the STATIC axis box and
        // the LIVE drag-feedback box. Ours were two different quantities (2.88
        // px from the stem-length ratio, 3.6 px from the arm) where the
        // reference draws one box at one size; both are now the same 5 px at
        // the default, frozen above handle-size 1.25 and floored below 0.75.
        // Setting `fixedCubeHalf` on the stems keeps the change inside this
        // bank — GIZMO_CUBE_HEAD_HALF_OF_LEN still serves every other
        // CubicArrow user untouched. The box's outer face still lands exactly
        // on the arm end, since CubicArrow centres its head at `end - half`.
        float cubeFixed = gizmoPixelSize(center, vp, gizmoBoxHalfPx());
        arrowX.fixedCubeHalf      = cubeFixed;
        arrowY.fixedCubeHalf      = cubeFixed;
        arrowZ.fixedCubeHalf      = cubeFixed;
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
        centerDisk.radius = size * GIZMO_DISC_RADIUS;

        // Pixel radius, arm-scaled offset — see MoveHandler.updateGeometry.
        float circR      = gizmoPixelSize(center, vp, GIZMO_PLANE_RADIUS_PX);
        float cirOffset  = size * GIZMO_PLANE_OFFSET;
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
        g_fc.draw(DrawPass.handles, vertCount);
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
