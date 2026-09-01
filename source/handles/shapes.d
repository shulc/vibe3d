module handles.shapes;

import handles.gl_util;
import math;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import shader;
import viewport_scheme;
import bindbc.sdl;
import bindbc.opengl;
import core.atomic : atomicOp;
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
// NOTE what this enum is NOT, since it used to be both: it is not the handle's
// COLOUR state. The two were split because they answer different questions and
// carry different consumers, and the split still holds now that hover paints.
//
//   * HandleState answers "which handle would a press grab, and what does the
//     advisor think about that" — it is the hit-test result plus the AI
//     copilot's default hint. It is consumed by `handles/arbiter.d`, by the
//     copilot lane, and it is serialised over /api/tool/handles.
//   * `viewport_scheme.HandlePaint` answers "what colour is this handle" —
//     three states, resolved by `Handler.paintState` from `Rollover` plus
//     `engaged`. HandleState feeds it; it is not it. Rollover carrying an
//     advisory hint (SecondaryDefault) alongside a paintable one is exactly why
//     the drawing code must not switch on this enum directly.
//
// The enum kept all four members deliberately. `SecondaryDefault` carries the
// copilot's deterministic-default hint (arbiter.d) and is asserted across
// tests/test_ai_handle_candidates.d and tests/test_ai_model_live_wiring.d;
// `Rollover` is the arbiter's hot-part concept and part of the JSON contract
// below. Collapsing the enum would have broken three unrelated consumers to
// express a fact about drawing.
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

    // Is this handle being HAULED right now? Driven by ToolHandles.update from
    // its CAPTURE, never from its hit test — the two coincide during a haul but
    // differ for every hovering pointer, and only this bit means "a press
    // grabbed it". Hover is the OTHER input to the colour law and arrives
    // through `state` (see paintState below); keeping the two apart is what
    // lets the plane ring tell them apart.
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

    // What this handle is doing, in the only terms the colour law cares about.
    // The two arbitration bits collapse to one of three paint states, and the
    // precedence is grab-over-hover: during a haul the arbiter pins `hot` to
    // the captured part, so the hauled handle is BOTH Rollover and engaged and
    // must read as grabbed. (That distinction is invisible on every handle but
    // the plane ring, which is precisely why it has to be got right here
    // rather than at each shape.)
    protected HandlePaint paintState() const {
        if (engaged)                          return HandlePaint.grabbed;
        if (state == HandleState.Rollover)    return HandlePaint.hover;
        return HandlePaint.idle;
    }

    // The colour to draw this handle in. Every shape whose parts all agree
    // goes through here, so the common law has exactly one implementation;
    // CircleHandler (the plane handle) is the sole shape that reads
    // `paintState` directly, because its ring and its disc disagree.
    protected Vec3 drawColor(Vec3 idle) const {
        return handleColor(idle, paintState());
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
    // WINDOW PIXELS. Was 5.0f, which rendered 2.5 px — the geometry shader's
    // clip-to-screen conversion was off by 2 (see shader.thickLineGeomSrc).
    // Task 0600 made the unit honest, so this literal was halved to keep every
    // arrow that does NOT set its own width rendering at exactly the width it
    // always did. The transform gizmo's arms set theirs explicitly.
    float lineWidth = 2.5f;
    /// Fragment opacity for the WHOLE arrow — shaft stroke and solid head
    /// alike, because they are one part and the reference gives them one alpha.
    /// Opaque by default; the transform gizmo's arms set the measured 0.95.
    float alpha     = 1.0f;

    /// Task 0604 — emit the shaft stroke TWICE, as the reference does.
    ///
    /// Its move-handle draw puts FOUR vertices in one `LINES` batch, the third
    /// resetting to the shaft's own start, so the same segment is rasterised
    /// twice; its scale-handle draw does the same for the stem. The effect was
    /// measured, not assumed: the reference's arm holds its colour across a
    /// 74-level background change, which puts it at ≥0.9865 effective — a single
    /// emission at its 0.95 is excluded by 6.4 levels, two emissions predict the
    /// observed value in all three channels, and a plane ring composited
    /// correctly at 0.80 in the very same frames rules out "the alpha is simply
    /// ignored".
    ///
    /// WHY THE DOUBLING AND NOT AN ALPHA OF 1.0. The two are the same to a
    /// quarter of a level in the stroke's CORE and are not the same at its
    /// EDGE, which is the half of the stroke that antialiasing exists for. Our
    /// line coverage multiplies into alpha (`thickLineFragSrc`: `u_alpha*cov`),
    /// so a fringe fragment at coverage c composites as `1-(1-0.95c)^2` drawn
    /// twice and as `c` drawn once at 1.0 — 0.72 against 0.50 at half coverage.
    /// The reference's own fringe was measured at an effective 0.975 where a
    /// single emission could not have exceeded 0.95 at any coverage, i.e. its
    /// edge is fattened by the doubling exactly as ours will be. Folding the
    /// alpha would have matched the middle of the stroke and thinned its edge,
    /// and it would also have retired `GIZMO_ALPHA_ARM` — the measured constant
    /// — into a number no longer written anywhere.
    ///
    /// Off by default and opted into per shape, like `Arrow.fixedConeLen`: this
    /// class also serves the falloff endpoint handles and the create-tool
    /// movers, which draw opaque and which nothing has measured.
    bool doubledShaft = false;

    /// The unit shaft segment (0,0,0)→(0,0,1), stored TWICE so `doubledShaft`
    /// is a vertex COUNT at the draw call rather than a second draw call — the
    /// same one-batch shape the reference emits. Subclasses build their shaft
    /// VAO from this; `shaftVertCount` says how much of it to draw.
    protected static float[] shaftSegmentData() {
        return [0f,0f,0f,  0f,0f,1f,   0f,0f,0f,  0f,0f,1f];
    }
    /// 2 or 4 — see `doubledShaft`.
    protected int shaftVertCount() const { return doubledShaft ? 4 : 2; }

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
    float fixedConeHalf = 0.0f;  // world OFFSET of the head's off-axis corners

    // Task 0603 — the two LATERAL directions the head's off-axis base corners
    // sit on, both on the POSITIVE side. Setting both (alongside the pixel
    // sizes above) selects the measured TETRAHEDRAL head; leaving either zero
    // keeps the cone of revolution. Same shape of escape hatch as the sizes,
    // and for the same reason: `Arrow` is shared with the falloff endpoint
    // handles and the primitive create-tool movers, and the tetrahedron is a
    // measurement of the TRANSFORM gizmo's head only. Nothing has measured
    // theirs, so nothing here changes them.
    //
    // These are directions, not offsets — the length comes from
    // `fixedConeHalf`. They need not be unit (draw normalises) but they must
    // not be parallel to each other or to the arm, or the head has no volume.
    Vec3 headLateralA = Vec3(0, 0, 0);
    Vec3 headLateralB = Vec3(0, 0, 0);

    private int headWedgeFirst, headWedgeCount;

    this(Vec3 start, Vec3 end, Vec3 color) {
        this.start = start;
        this.end   = end;
        this.color = color;

        shaftVao = buildVao3f(shaftSegmentData(), shaftVbo);

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
        // The tetrahedral head is APPENDED to the same buffer rather than given
        // its own VAO/VBO: it is twelve vertices, only one caller selects it,
        // and sharing the buffer means `destroy()` stays correct as written and
        // no arrow that never draws the shape pays a GL object for it.
        headWedgeFirst = headVertCount;
        buildWedgeHeadData(coneData);
        headWedgeCount = cast(int)(coneData.length / 3) - headWedgeFirst;
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

        // Task 0603 — SHAPE, not size. When the caller supplies both lateral
        // directions the head is the measured TETRAHEDRON: apex on the axis at
        // the arm's end, one base corner on the axis, and two base corners
        // `coneRadius` out along `latA` / `latB`. See `buildWedgeHeadData`.
        Vec3 latA = headLateralA, latB = headLateralB;
        immutable float aLen = sqrt(dot(latA, latA)), bLen = sqrt(dot(latB, latB));
        bool wedge = fixedConeHalf > 0.0f && aLen > 1e-6f && bLen > 1e-6f;
        if (wedge) {
            latA = latA / aLen;
            latB = latB / bLen;
            // The reference's lateral PAIR is written out per axis and its
            // handedness is not consistent: for the X arm the frame (Z, Y, X)
            // is left-handed while (Z, X, Y) and (X, Y, Z) are right-handed. It
            // never culls, so it never had to care. The normalisation to a
            // right-handed frame below was added when we DID cull this head; as
            // of task 0604 we no longer do (`HandleFacing.twoLayer`), so it is
            // now a shape invariant rather than a correctness requirement, and
            // it is kept for two reasons. Swapping A and B RELABELS two corners
            // of the same tetrahedron and leaves the drawn solid bit-identical,
            // so keeping it costs nothing; and it is what makes the emitted
            // winding uniformly outward for all three arms, which is the
            // premise the `buildWedgeHeadData` unittest asserts and the premise
            // a future culled user of this shape would need.
            //
            // The determinant test itself is NOT optional either way: a
            // coplanar pair gives the head no volume at all.
            immutable float det = dot(cross(latA, latB), fwd);
            if (abs(det) < 1e-6f) wedge = false;   // coplanar: no volume to draw
            else if (det < 0.0f) { Vec3 t = latA; latA = latB; latB = t; }
        }
        // An overridden head is a PIXEL size and the shaft is a world one, so
        // a short enough arrow can be all head. Mirrors CubicArrow's guard.
        if (shaftLen < 0.0f) shaftLen = 0.0f;
        Vec3  coneBase   = end - fwd * coneLen;

        Vec3 c = drawColor(color);

        glUniform3f(shader.locColor, c.x, c.y, c.z);
        glDisable(GL_DEPTH_TEST);

        auto shaftModel = modelMatrix(right, up, fwd, Vec3(1, 1, shaftLen), start);
        drawThickLines(shaftVao, shaftVertCount(), GL_LINES, shaftModel, vp, c,
                       lineWidth, shader.program, alpha);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        // The head is SOLID and stays hard-edged — it is translucent, not
        // smoothed. Its staircase edge beside the shaft's graded one is what
        // the reference was measured doing, and matching means keeping it.
        //
        // The TETRAHEDRON draws uncilled (`twoLayer`), because the head it ports
        // composites twice — see `HandleFacing.twoLayer`, which is also where
        // the convexity this relies on is stated. The cone fallback keeps the
        // cull: it is the shape the falloff handles and the create-tool movers
        // draw, nothing has measured its layer count, and at their opaque alpha
        // `beginHandleFill` is a no-op there anyway.
        immutable int fillTok = beginHandleFill(shader.locAlpha, alpha,
                                                wedge ? HandleFacing.twoLayer
                                                      : HandleFacing.outwardCCW);
        // The wedge's basis is the two lateral directions themselves, NOT the
        // `localFrame` pair the cone uses: localFrame is stable but arbitrary
        // about the axis, so a head built on it would lean somewhere unrelated
        // to the arm's neighbours and its width would not breathe with the roll
        // the way the measured one does.
        auto headModel = wedge
            ? modelMatrix(latA * coneRadius, latB * coneRadius, fwd * coneLen,
                          Vec3(1, 1, 1), coneBase)
            : modelMatrix(right, up, fwd,
                          Vec3(coneRadius, coneRadius, coneLen), coneBase);
        immutable int headFirst = wedge ? headWedgeFirst : 0;
        immutable int headCount = wedge ? headWedgeCount : headVertCount;
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, headFirst, headCount);
        g_fc.draw(DrawPass.handles, headCount);
        endHandleFill(shader.locAlpha, fillTok);

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

        shaftVao = buildVao3f(shaftSegmentData(), shaftVbo);

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
        drawThickLines(shaftVao, shaftVertCount(), GL_LINES, shaftModel, vp, c,
                       lineWidth, shader.program, alpha);
        glUniform3f(shader.locColor, c.x, c.y, c.z);

        immutable int fillTok = beginHandleFill(shader.locAlpha, alpha,
                                                HandleFacing.outwardCW);
        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);
        g_fc.draw(DrawPass.handles, headVertCount);
        endHandleFill(shader.locAlpha, fillTok);

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

        immutable int fillTok = beginHandleFill(shader.locAlpha, alpha,
                                                HandleFacing.outwardCW);
        auto headModel = modelMatrix(right, up, fwd, Vec3(cubeHalf, cubeHalf, cubeHalf), cubeCenter);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, headModel.ptr);
        glBindVertexArray(headVao);
        glDrawArrays(GL_TRIANGLES, 0, headVertCount);
        g_fc.draw(DrawPass.handles, headVertCount);
        endHandleFill(shader.locAlpha, fillTok);

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
    // WINDOW PIXELS; halved with the geometry shader's unit fix so an arc that
    // sets no width of its own renders exactly as it did (task 0600).
    float lineWidth  = 2.5f;
    float alpha      = 1.0f;  /// fragment opacity; the rotate bank sets 0.95
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
        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth,
                       shader.program, alpha);

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
    // WINDOW PIXELS; halved with the geometry shader's unit fix (task 0600) so
    // the one external user that leaves it alone renders unchanged.
    float lineWidth = 1.5f;
    float alpha     = 1.0f;  /// fragment opacity; the rotate bank sets its own
    /// Whether this shape's stroke asks for analytic antialiasing.
    ///
    /// True for every ring, which is what the reference does with the ones we
    /// have measured — and false for exactly one shape today, the rotate bank's
    /// backing disc (task 0610), whose ink was measured as a single exact value
    /// with no fringe while the screen-plane ring beside it in the same frame is
    /// graded on both edges.
    ///
    /// It lives on the SHAPE rather than on the renderer because that is the
    /// grain the request has: smoothing is per batch, one gizmo can hold both
    /// kinds at once, and a render-wide toggle could not express the frame this
    /// was measured in. `drawThickLines` takes it per call and defaults it to
    /// true, so a shape that says nothing is unaffected.
    bool  smoothStroke = true;

private:
    GLuint arcVao,  arcVbo;
    enum SEGS = 64;

public:
    // THIS SHAPE HAS NO FILL, and the absence is structural rather than a
    // default (task 0610). It briefly had one, built for the rotate bank's
    // backing disc on a reading that turned out to describe a branch the
    // reference application never takes; the disc is a bare line loop, and with
    // it went the only caller that ever asked for a fill. What is left is what
    // this class was for its whole life before that, and there is now no
    // parameter through which a fill can come back without someone adding one
    // deliberately — which is the point, because the shape that wanted it is
    // measured, on pixels, not to have it.
    this(Vec3 center, Vec3 normal, float radius, Vec3 color)
    {
        this.center    = center;
        this.normal    = normal;
        this.radius    = radius;
        this.color     = color;

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

        drawThickLines(arcVao, SEGS + 1, GL_LINE_STRIP, model, vp, c, lineWidth,
                       shader.program, alpha, smoothStroke);

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

        // Task 0600 — the MEASURED stroke widths and per-part alphas. Set here
        // rather than left to the class defaults because the class defaults
        // serve every OTHER user of these shapes (falloff endpoint arrows, the
        // per-tool parameter handles), none of which has been measured against
        // anything. The transform gizmo has.
        foreach (a; [arrowX, arrowY, arrowZ]) {
            a.lineWidth = GIZMO_STROKE_MOVE_SHAFT_PX;
            a.alpha     = GIZMO_ALPHA_ARM;
            // Task 0604 — the move handle's shaft is the batch the reference
            // was READ emitting twice and MEASURED compositing twice. See
            // ShaftedArrow.doubledShaft.
            a.doubledShaft = true;
        }
        foreach (c; [circleXY, circleYZ, circleXZ]) {
            c.lineWidth    = GIZMO_STROKE_PLANE_RING_PX;
            c.outlineAlpha = GIZMO_ALPHA_PLANE_RING;
            c.fillAlpha    = GIZMO_ALPHA_PLANE_FILL;
        }
        // The centre box keeps the class default and is deliberately NOT given
        // an alpha: it is the one gizmo part measured fully opaque, so it stays
        // on the unblended path it has always been on.
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

        // Task 0603: the head is a TETRAHEDRON leaning into one quadrant, not a
        // cone of revolution — `headHalf` is the offset of two base corners
        // from the axis, and the third corner sits ON it. The two corners lie
        // along the OTHER two gizmo axes, both POSITIVE, which is what makes
        // the head reach `headHalf` on one side of the arm and zero on the
        // other and makes its drawn width breathe as the view rolls.
        //
        // These are the gizmo's own axes, so under the default (auto) workplane
        // they ARE the world axes, which is what the head's lean was measured
        // against. Under a rotated workplane the arms are no longer world axes
        // and the head follows the arms — the alternative, world axes against a
        // rotated arm, would not even be perpendicular to it. The PAIRING per
        // arm is the reference's own and is deliberately not a cyclic rotation;
        // it fixes only which corner is labelled first, since the tetrahedron
        // is the same solid either way (draw() re-orders it for winding).
        arrowX.headLateralA = axisZ; arrowX.headLateralB = axisY;
        arrowY.headLateralA = axisZ; arrowY.headLateralB = axisX;
        arrowZ.headLateralA = axisX; arrowZ.headLateralB = axisY;

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

        // The view cull (task 0602; was task 0225's ortho-only rule). An axis
        // within 5.126 deg of the ray this view looks along through the gizmo
        // projects to nothing, so its arm is dropped from BOTH the draw and the
        // hit test — the shared arbiter's ToolHandles.test() skips invisible
        // handles, so an invisible arm cannot swallow a click meant for
        // whatever it collapsed onto. This fires in EVERY projection: the
        // predicate takes the eye vector at the gizmo's own position, which is
        // a fixed direction under ortho and the actual ray under perspective.
        //
        // Each plane handle then tests BOTH of the axes its plane SPANS — not
        // its normal. See handles/gl_util.planeHandleHidden for why that is the
        // measured rule and why the obvious one is wrong.
        viewDir = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        arrowX.setVisible(arrowsVisible && !axisFacesViewer(axisX, center, vp));
        arrowY.setVisible(arrowsVisible && !axisFacesViewer(axisY, center, vp));
        arrowZ.setVisible(arrowsVisible && !axisFacesViewer(axisZ, center, vp));
        circleXY.setVisible(!planeHandleHidden(axisX, axisY, center, vp));
        circleYZ.setVisible(!planeHandleHidden(axisY, axisZ, center, vp));
        circleXZ.setVisible(!planeHandleHidden(axisX, axisZ, center, vp));
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
    FullCircleHandler bgCircle;  // camera-view-plane backing disc (decorative)
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
        // Task 0600 — the measured ring stroke and alpha. The axis arcs and the
        // screen-plane ring are ONE shape in the reference and take ONE width,
        // so they are set together here; ours had them at two different values.
        //
        // This replaced four `lineWidth += 1.0f` lines. Those were an
        // unconditional CONSTRUCTOR bump, not a hot-state widening — worth
        // stating because they read like one and were reported as one. Nothing
        // in this codebase has ever widened a stroke on hover or on haul; the
        // two-state law recolours and only recolours (see Handler.drawColor),
        // which is already what the reference does.
        foreach (arc; [arcX, arcY, arcZ]) {
            arc.lineWidth = GIZMO_STROKE_ROTATE_RING_PX;
            arc.alpha     = GIZMO_ALPHA_ROTATE_RING;
        }
        arcView.lineWidth = GIZMO_STROKE_ROTATE_RING_PX;
        arcView.alpha     = GIZMO_ALPHA_ROTATE_RING;
        // The backing disc: ONE hairline loop, opaque, hard-edged, in a colour
        // DERIVED from the viewport backdrop rather than written down (see
        // `viewport_scheme.rotateBackingDiscColor`).
        //
        // All four of those words are a correction (task 0610). This shape was
        // ported from a row describing a filled plate at alpha 0.2 under a
        // smoothed 2 px outline at 0.75 — a row that had transcribed the arm of
        // a two-arm draw function that the reference application never enters,
        // both of its call sites selecting the other one. Only the colour and
        // the radius survived re-measurement, and both were confirmed exactly.
        //
        // So it is barely there, and that is correct: 0.15 below whatever is
        // behind it, one pixel wide. It reads as a seam the rings sit on, not
        // as a line. The temptation with a shape like this is to make it look
        // like something; the whole history of this part is what that costs.
        bgCircle = new FullCircleHandler(center, Vec3(0,0,1), 1.0f,
                                         rotateBackingDiscColor());
        bgCircle.lineWidth    = GIZMO_STROKE_ROTATE_DISC_PX;
        bgCircle.alpha        = GIZMO_ALPHA_ROTATE_DISC;
        // The only shape in the app that opts out of line smoothing. Its
        // measured ink is one exact value with no fringe, next to a
        // screen-plane ring — same frame, same instrument — that is graded on
        // both edges. See FullCircleHandler.smoothStroke.
        bgCircle.smoothStroke = false;
        // bgCircle stays decorative: drawn but never registered in the Test
        // pass (ToolHandles), so it holds HandleState.Normal, is never hit, and
        // never takes the active colour. That matches the reference exactly,
        // which hands this batch a no-part sentinel its own hover path then
        // skips — the disc there cannot go hot even in principle.
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

        // Decorative backing disc: same plane and radius as the X/Y/Z arcs
        // (the arm length), drawn first so everything else lands on top of it.
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

        // The ring cull (task 0602; was task 0225's rule, with the OPPOSITE
        // polarity). A ring seen edge-on is a line and near impossible to grab,
        // so in an axis-locked view it is dropped from the draw and the hit
        // test alike. The view-plane ring (arcView, normal = camFwd) is never
        // culled — it IS the screen-plane rotation.
        //
        // Two things changed and both matter. The GATE is a viewport-type
        // question, `lockedViewAxis`, not `isOrtho` plus a camera test; and the
        // rule now DROPS THE EDGE-ON rings rather than KEEPING ONLY the face-on
        // one. Those two phrasings pick the same single ring whenever the gizmo
        // carries the world basis — which is every case anyone had looked at —
        // and they part company as soon as it carries a rotated one. Measured
        // on our own build: an ortho Front cell with the axis stage on
        // `workplane` and the work plane turned 45 deg about Y reported all
        // three axis rings `visible:false` through /api/tool/handles, leaving a
        // rotate gizmo that could not rotate about any of its own axes. Under
        // this rule two of the three survive, which is also what the reference
        // does with those normals.
        arcX.setVisible(!rotateRingHidden(axisX, center, vp));
        arcY.setVisible(!rotateRingHidden(axisY, center, vp));
        arcZ.setVisible(!rotateRingHidden(axisZ, center, vp));
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
// Follows the common law (active under the pointer and while hauled alike),
// and additionally takes the active colour when the owning tool has marked it
// current (`selected`).
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
        // setter is the pen's current-point marker). It reads as grabbed, and
        // takes the scheme's active colour — not the mesh-selection orange it
        // used to borrow. That orange belongs to selected geometry; a handle
        // wearing it says "you have selected some mesh", which is a lie.
        // Being current outranks a passing pointer, hence the explicit
        // `grabbed` rather than a fall-through to paintState().
        Vec3 c = selected ? handleColor(color, HandlePaint.grabbed)
                          : drawColor(color);

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
// THE ONE SHAPE WHOSE TWO PARTS DISAGREE: under the pointer both take the
// scheme's active colour; while HAULED only the fill does, and the outline
// goes back to its axis colour so which plane this is stays legible. See
// draw() below and viewport_scheme.planeRingColor.
// ---------------------------------------------------------------------------

class CircleHandler : Handler {
    Vec3  center;
    Vec3  normal;
    float radius    = 1.0f;
    Vec3  color;        // outline
    Vec3  fillColor;    // disc fill
    // WINDOW PIXELS; halved with the geometry shader's unit fix (task 0600).
    float lineWidth = 0.75f;
    /// The plane handle is TWO parts with two DIFFERENT opacities — a nearly
    /// solid ring around a barely-there disc. One alpha for both would erase
    /// the construction, so they are separate fields, defaulting to opaque for
    /// any caller that does not set them.
    float outlineAlpha = 1.0f;
    float fillAlpha    = 1.0f;

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

        // A plane handle is TWO concentric parts, and it is the ONE shape in
        // the gizmo whose parts disagree — so it is the one shape that does
        // not go through `drawColor`. See viewport_scheme.planeRingColor for
        // the measured rows; in short:
        //
        //   disc  idle -> its own tint,  hover -> active,  grabbed -> active
        //   ring  idle -> its axis,      hover -> active,  grabbed -> its axis
        //
        // The ring lights under a passing pointer like anything else, but the
        // grab deliberately gives it back its axis colour: the ring is the only
        // thing that says WHICH plane this is, and the moment of the grab is
        // the worst moment to stop saying it.
        const paint = paintState();
        Vec3 oc = planeRingColor(color, paint);
        Vec3 fc = handleColor(fillColor, paint);

        // TWO radii, not one. The ring is the handle's stated size; the disc
        // sits INSIDE it at `GIZMO_PLANE_FILL_RATIO` of that, leaving a visible
        // gap that is what makes the shape read as a ring around a hole. Ours
        // used to draw both off the same matrix, so the disc filled the ring to
        // its edge and the two elements were indistinguishable except by alpha.
        // The HIT region deliberately stays the outer radius (see doHitTest) —
        // the grabbable target is the whole handle, not the disc.
        auto mRing = modelMatrix(right, up, fwd, Vec3(radius, radius, radius), center);
        immutable float fillR = radius * GIZMO_PLANE_FILL_RATIO;
        auto mFill = modelMatrix(right, up, fwd, Vec3(fillR, fillR, fillR), center);

        // A grab is the one state in which the disc goes fully opaque. Hover
        // does NOT — hover only recolours, which is the difference the plane
        // handle exists to show. Callers that never set `fillAlpha` are already
        // at 1.0, so this is inert for every non-gizmo user of the shape.
        immutable float fa = paint == HandlePaint.grabbed
            ? GIZMO_ALPHA_PLANE_FILL_GRABBED : fillAlpha;

        glDisable(GL_DEPTH_TEST);

        // ---- Fill ----
        // ORDER IS LOAD-BEARING now that both parts are translucent: the disc
        // is laid down FIRST and the ring composited over it, so the rim reads
        // as ring-over-disc rather than disc-over-ring. That is the order the
        // reference emits its two circles in, and with depth testing off for
        // the whole handle pass, emission order is the only thing deciding it.
        immutable int fillTok = beginHandleFill(shader.locAlpha, fa,
                                                HandleFacing.flat);
        glUniform3f(shader.locColor, fc.x, fc.y, fc.z);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, mFill.ptr);
        glBindVertexArray(fillVao);
        glDrawArrays(GL_TRIANGLES, 0, fillVertCount);
        g_fc.draw(DrawPass.handles, fillVertCount);
        endHandleFill(shader.locAlpha, fillTok);

        // ---- Outline ----
        drawThickLines(outlineVao, SEGS + 1, GL_LINE_STRIP, mRing, vp, oc, lineWidth,
                       shader.program, outlineAlpha);

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

        // The screen-plane disc is an axis-less handle and it follows the
        // COMMON law: the scheme's `handle` colour idle, the active colour
        // both under the pointer and while hauled. It belongs to no axis, so
        // it has nothing to protect the way the axis plane rings do, and none
        // of their exception applies.
        //
        // The two alphas are the MEASURED pair — a 10 % fill inside a solid
        // ring — replacing hand-picked values that had the fill three times
        // too strong and the ring short of solid.
        //
        // NOTE this handle alone does not go through the thick-line program: it
        // is drawn on the UI foreground draw list, which antialiases its own
        // polylines. So it is smoothed by a path we do not control here, and
        // its ring is a case where we are softer than measured. Left as is —
        // moving it onto the GL path is its own change.
        const Vec3 c = drawColor(schemeColor(SchemeColor.handle));
        static ubyte a8(float a) {
            const int i = cast(int)(a * 255.0f + 0.5f);
            return cast(ubyte)(i < 0 ? 0 : (i > 255 ? 255 : i));
        }
        const uint fillCol    = packImCol(c, a8(GIZMO_ALPHA_SCREEN_DISC_FILL));
        const uint outlineCol = packImCol(c, a8(GIZMO_ALPHA_SCREEN_DISC_RING));

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

    // Cross-bank stand-off, in arm fractions: 0 when this bank is the only
    // one on the gizmo, GIZMO_SCALE_ARM_CROSS_BANK_SHIFT when a move and/or
    // rotate bank is drawn beside it. Only the wrapper knows what else is
    // drawn, so only the wrapper writes it — see setCrossBankShift.
    private float crossBankShift_ = 0.0f;

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

        // Task 0600 — measured stroke widths and per-part alphas; see the same
        // block in MoveHandler's constructor. The scale stem is the one gizmo
        // stroke the reference does NOT run through its line-width preference:
        // it is a plain literal 2.0 there, which is why it has its own name.
        // The live drag-feedback arrows are the same part continued, so they
        // take the same values as the stems they grow out of.
        foreach (a; [arrowX, arrowY, arrowZ,
                     scaleArrowX, scaleArrowY, scaleArrowZ]) {
            a.lineWidth = GIZMO_STROKE_SCALE_SHAFT_PX;
            a.alpha     = GIZMO_ALPHA_ARM;
        }
        // Task 0604 — the doubled emission goes to the STEMS only. The
        // reference's scale-handle draw doubles its first `LINES` batch (the
        // stem) and emits its SECOND batch as a single segment; that second
        // batch is what an undoubled stroke looks like in the same function, so
        // "everything in this bank is doubled" is refuted by the binary itself.
        // Nothing identifies our live drag-feedback arrows with that batch, so
        // they are left single rather than doubled on a guess.
        foreach (a; [arrowX, arrowY, arrowZ])
            a.doubledShaft = true;
        foreach (c; [circleXY, circleYZ, circleXZ]) {
            c.lineWidth    = GIZMO_STROKE_PLANE_RING_PX;
            c.outlineAlpha = GIZMO_ALPHA_PLANE_RING;
            c.fillAlpha    = GIZMO_ALPHA_PLANE_FILL;
        }
    }

    void setScaleAccum(Vec3 s) { scaleAccum = s; }

    /// Declare whether another bank shares this gizmo. THE ONE PIECE OF BOX
    /// GEOMETRY THAT IS STATE RATHER THAN A DRAW ARGUMENT, deliberately.
    ///
    /// `updateGeometry` used to take the box distance as a defaulted
    /// parameter that no call site ever overrode. Handing the shifted value
    /// to the DRAW call would have moved the drawn box and left the pick
    /// region behind: `syncGeometry` re-derives the geometry the HIT test
    /// reads (`ScaleHeadHandle` measures its 12 px disc from `arrowN.end`,
    /// `hitTestAxes` walks the same segment) and it passes no arguments, so
    /// the handle would have moved and the place you must click would not.
    /// As state, draw and hit reach the same number through the same
    /// no-argument call, and the parameter that made the two expressible
    /// separately is gone.
    void setCrossBankShift(bool besideAnotherBank) {
        crossBankShift_ = besideAnotherBank ? GIZMO_SCALE_ARM_CROSS_BANK_SHIFT : 0.0f;
    }
    /// The live stand-off, in arm fractions (0 or the cross-bank shift).
    float crossBankShift() const { return crossBankShift_; }
    /// Where an axis box's OUTER FACE sits, in arm fractions — the arm plus
    /// whatever stand-off the bank currently carries.
    float axisBoxDistance() const { return AXIS_BOX_DISTANCE + crossBankShift_; }

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
    // re-layout forwarder. It takes no geometry arguments and `updateGeometry`
    // accepts none, which is the whole safety property: this call feeds the
    // HIT test and `draw()` / `drawAxisBoxesOnly()` feed the pixels, and there
    // is no longer any way to hand one of them a box distance the other does
    // not see (task 0606 — see setCrossBankShift).
    // Re-derives `centerDisk.normal`/`radius` (camFwd/gizmoSize-dependent —
    // the stale members `CenterDiskGizmo.diskHitCheck` reads) plus the plane
    // circles' gizmoSize-offset centers.
    void syncGeometry(const ref Viewport vp) { updateGeometry(vp); }

    private void updateGeometry(const ref Viewport vp)
    {
        size = gizmoSize(center, vp);

        // Arm + cross-bank stand-off. `crossBankShift_` is 0 unless the
        // wrapper has declared a companion bank, so a scale bank on its own
        // lands exactly where it always did.
        immutable float boxDist = AXIS_BOX_DISTANCE + crossBankShift_;

        arrowX.start = center + axisX * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowX.end   = center + axisX * (size * boxDist);
        arrowY.start = center + axisY * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowY.end   = center + axisY * (size * boxDist);
        arrowZ.start = center + axisZ * (size/GIZMO_SCALE_SHAFT_INSET_DIV);
        arrowZ.end   = center + axisZ * (size * boxDist);

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
        // The live drag box. The stand-off is ADDITIVE and applied AFTER the
        // drag factor, not folded into it: the reference computes the box at
        // `arm x factor` and then adds its tenth, so a 2x drag puts the box at
        // two arms plus a tenth — not at 2.2 arms. With no companion bank
        // `crossBankShift_` is 0 and this is the old expression exactly.
        scaleArrowX.start         = arrowX.end;
        scaleArrowY.start         = arrowY.end;
        scaleArrowZ.start         = arrowZ.end;
        scaleArrowX.end           = center + axisX * (size * (AXIS_BOX_DISTANCE * scaleAccum.x + crossBankShift_));
        scaleArrowX.fixedCubeHalf = cubeFixed;
        scaleArrowY.end           = center + axisY * (size * (AXIS_BOX_DISTANCE * scaleAccum.y + crossBankShift_));
        scaleArrowY.fixedCubeHalf = cubeFixed;
        scaleArrowZ.end           = center + axisZ * (size * (AXIS_BOX_DISTANCE * scaleAccum.z + crossBankShift_));
        scaleArrowZ.fixedCubeHalf = cubeFixed;

        // The view cull (task 0602) — the same predicate MoveHandler uses, and
        // deliberately the same one: the reference's move and scale banks are
        // separate code paths that were measured crossing at the identical
        // threshold. Drops the arm from the draw and the hit test alike (the
        // ScaleHeadHandle proxy also reports no-hit once its target arrow is
        // invisible), in EVERY projection rather than only in ortho.
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        viewDir = camFwd;
        arrowX.setVisible(!axisFacesViewer(axisX, center, vp));
        arrowY.setVisible(!axisFacesViewer(axisY, center, vp));
        arrowZ.setVisible(!axisFacesViewer(axisZ, center, vp));

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
        // Each plane handle tests BOTH axes its plane spans — see
        // MoveHandler.updateGeometry and handles/gl_util.planeHandleHidden.
        circleXY.setVisible(!planeHandleHidden(axisX, axisY, center, vp));
        circleYZ.setVisible(!planeHandleHidden(axisY, axisZ, center, vp));
        circleXZ.setVisible(!planeHandleHidden(axisX, axisZ, center, vp));
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

private shared ulong nextClickPointResourceOwnerId;

struct PreparedClickPointResourceToken { ulong ownerId, generation; }

/// Dormant owner for the ClickPointHandler-private VAO/VBO lifetime.
final class ClickPointResourceOwner {
private:
    ClickPointHandler target;
    immutable ulong ownerId;
    ulong generation, requiredThread, requiredContext;
    GLuint vao, vbo;
    bool built, pending, validated;
    PreparedClickPointResourceToken enlistedPrepared;
public:
    this(ClickPointHandler target, ulong threadIdentity, ulong contextIdentity)
         nothrow @nogc {
        this.target = target;
        requiredThread = threadIdentity;
        requiredContext = contextIdentity;
        ownerId = atomicOp!"+="(nextClickPointResourceOwnerId, 1UL);
    }
    bool owns(ClickPointHandler candidate) const nothrow @nogc {
        return target is candidate;
    }

    bool beginPreparedDestroy(out PreparedClickPointResourceToken token)
                              nothrow @nogc {
        if (pending || target is null) return false;
        ++generation;
        vao = target.vao; vbo = target.vbo; built = target.built;
        pending = true; validated = false;
        token = PreparedClickPointResourceToken(ownerId, generation);
        return true;
    }

    bool validateEnlisted(PreparedClickPointResourceToken token,
                          ulong threadIdentity, ulong contextIdentity)
                          nothrow @nogc {
        if (!pending || validated || token.ownerId != ownerId ||
            token.generation != generation ||
            threadIdentity != requiredThread ||
            contextIdentity != requiredContext || target is null ||
            target.vao != vao || target.vbo != vbo || target.built != built)
            return false;
        validated = true;
        return true;
    }

    bool beginEnlistedDestroy() nothrow @nogc {
        return beginPreparedDestroy(enlistedPrepared);
    }
    bool validateEnlisted(ulong threadIdentity, ulong contextIdentity)
                          nothrow @nogc {
        return validateEnlisted(enlistedPrepared, threadIdentity,
                                contextIdentity);
    }

    void installEnlisted() nothrow @nogc {
        if (!pending || !validated) return;
        if (built) {
            glDeleteVertexArrays(1, &vao);
            glDeleteBuffers(1, &vbo);
        }
        target.vao = 0; target.vbo = 0; target.built = false;
        pending = false; validated = false;
    }
    void abortEnlisted() nothrow @nogc {
        pending = false; validated = false;
    }
}

unittest {
    // Task 0604 — the shaft's batch really carries a SECOND, identical segment,
    // and `doubledShaft` really selects it.
    //
    // This is the pin the pixel tests cannot supply. Two emissions at 0.95
    // composite to 0.9975 and one emission at 1.0 composites to 1.0, and those
    // differ by less than a third of an 8-bit level over the widest background
    // contrast the viewport has — so no probe can tell the ported mechanism
    // from a folded alpha. They are NOT the same thing at the stroke's edge
    // (`u_alpha*cov` means a coverage-c fringe fragment lands at `1-(1-0.95c)^2`
    // one way and at `c` the other, 0.72 against 0.50 at half coverage), and
    // the edge is half of what antialiasing is for. So the mechanism is
    // asserted here, structurally, where it is unambiguous.
    import std.math : abs;

    auto d = ShaftedArrow.shaftSegmentData();
    assert(d.length == 12,
           "the shaft buffer must hold FOUR vertices — two copies of the unit "
           ~ "segment, which is what lets one draw call emit it twice");
    foreach (i; 0 .. 6)
        assert(abs(d[i] - d[i + 6]) < 1e-9f,
               "the shaft buffer's second segment is not identical to the "
               ~ "first; a doubled emission must retrace the SAME line, not "
               ~ "draw a second one somewhere near it");
    // ...and it is the unit segment along +Z, which is what `draw`'s model
    // matrix scales into the arm.
    assert(d[0] == 0f && d[1] == 0f && d[2] == 0f);
    assert(d[3] == 0f && d[4] == 0f && d[5] == 1f);

    // The selector. `Arrow`'s ctor only touches GL through `buildVao3f`, which
    // is a no-op under `version(unittest)`.
    auto arrow = new Arrow(Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,0));
    assert(arrow.shaftVertCount() == 2,
           "an arrow that has not opted in must draw ONE segment — this class "
           ~ "also serves the falloff endpoint handles and the create-tool "
           ~ "movers, whose stroke weight nothing has measured");
    arrow.doubledShaft = true;
    assert(arrow.shaftVertCount() == 4,
           "an opted-in arm must draw both copies of the segment");
}
