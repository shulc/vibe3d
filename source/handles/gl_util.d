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
    GLint  locModel, locView, locProj, locColor, locWidth, locScreen, locAlpha;
    GLint  locSmooth;
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
// Reference-image plane shader state (task 0612) — set once from app.d via
// initImagePlaneProgram(). Its own program: the first `sampler2D` in the
// build, with a second vertex attribute (the texture coordinate) no other
// pass has.
// ---------------------------------------------------------------------------
private struct ImagePlaneState {
    GLuint prog;
    GLint  locView, locProj, locTex;
    GLint  locBrightness, locContrast, locTransparency, locInvert;
}
private ImagePlaneState g_imagePlane;

// Task 0719 (T9) — the metrics half of this file (the gizmo arm size, every
// GIZMO_* constant, the two size conversions and the three visibility
// predicates) moved to `handles/gizmo_metrics.d`; it made no gl* call and
// never did. Re-exported so every consumer -- most of them through
// `handler.d`'s `public import handles.gl_util;` -- resolves them unchanged.
public import handles.gizmo_metrics;


void initThickLineProgram(GLuint prog, int screenW, int screenH) {
    g_thickLine.prog      = prog;
    g_thickLine.locModel  = glGetUniformLocation(prog, "u_model");
    g_thickLine.locView   = glGetUniformLocation(prog, "u_view");
    g_thickLine.locProj   = glGetUniformLocation(prog, "u_proj");
    g_thickLine.locColor  = glGetUniformLocation(prog, "u_color");
    g_thickLine.locWidth  = glGetUniformLocation(prog, "u_lineWidth");
    g_thickLine.locScreen = glGetUniformLocation(prog, "u_screenSize");
    // Now WRITTEN per draw (the per-part alphas), not merely seeded — but the
    // seeding below stays, because a program whose very first draw forgot to
    // pass one would still be reaching for a 0.
    g_thickLine.locAlpha  = glGetUniformLocation(prog, "u_alpha");
    // The per-shape smoothing request (task 0610). WRITTEN on every draw, like
    // `u_lineWidth` and unlike `u_alpha` was — `drawThickLines` is the single
    // funnel every line batch in the app passes through, so this uniform is
    // never read stale and is NOT a `kSharedFragNeutrals` obligation. It is
    // seeded below anyway, for the one case the funnel does not cover: a future
    // path that binds this program and draws without going through that
    // function would otherwise get GL's default 0 and render EVERY line
    // hard-edged, which is a silent whole-app regression rather than a crash.
    g_thickLine.locSmooth = glGetUniformLocation(prog, "u_smooth");
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

    // ...and `u_smooth`'s own neutral. Not part of that list on purpose: the
    // list is the contract of the SHARED fragment source, and this uniform
    // exists on the thick-line source alone. Same bind-and-restore discipline,
    // for the same reason (a builder runs during init, with some other program
    // possibly bound).
    if (g_thickLine.locSmooth >= 0) {
        GLint prevProg;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
        glUseProgram(prog);
        glUniform1f(g_thickLine.locSmooth, 1.0f);
        glUseProgram(cast(GLuint)prevProg);
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

// ---------------------------------------------------------------------------
// The transform gizmo's ARROWHEAD — a closed tetrahedron, not a cone.
//
// Unit space, exactly the space `Arrow.draw` scales it through:
//   X = the first lateral direction, Y = the second, Z = the arm's own axis.
//
//     T = (0,0,1)   the apex, ON the axis, at the arm's outer end
//     C = (0,0,0)   a base corner, also ON the axis
//     A = (1,0,0)   a base corner, one lateral out
//     B = (0,1,0)   a base corner, the other lateral out
//
// SHAPE, NOT SIZE — this is the whole finding. The measured half-width
// (`gizmoHeadHalfPx`) is the OFFSET of two base corners from the axis, and the
// third corner sits on the axis. So the base is a right isoceles triangle with
// its right angle on the arm's line: the head reaches its full half-width on
// ONE side and exactly ZERO on the other, and what the camera changes is which
// way it leans. Its drawn width therefore breathes between H and H*sqrt(2) as
// the view rolls about the arm, instead of standing at 2H from every angle.
// A cone of revolution cannot express that at any radius, which is why fixing
// this by re-tuning `gizmoHeadHalfPx` is not available — the constant is
// confirmed against drawn pixels and it is the mesh that was wrong.
//
// WINDING, and why it is stated here rather than assumed. `HandleFacing` above
// records that our two existing solids disagree about winding, so a third one
// may not simply inherit either. The reference emits these four faces in a
// MIXED winding — three one way, one the other — because it never culls, so
// its vertex order carries no information beyond WHICH four faces. We do cull
// (a translucent closed solid under a depth-off pass would otherwise composite
// itself three deep and lose its alpha), so all four are emitted here
// consistently OUTWARD-CCW. That puts this shape on `HandleFacing.outwardCCW`,
// the same value the cone it replaces already used. The unittest below
// re-derives every face normal from the emitted floats and checks it points
// away from the solid's own centroid, so the claim is proved from the data
// rather than asserted in prose.
// ---------------------------------------------------------------------------
package void buildWedgeHeadData(ref float[] data) {
    static immutable float[3][4] pt = [
        [0, 0, 1],   // 0 = T, the apex
        [0, 0, 0],   // 1 = C, the on-axis base corner
        [1, 0, 0],   // 2 = A, one lateral out
        [0, 1, 0],   // 3 = B, the other lateral out
    ];
    static immutable int[3][4] face = [
        [0, 1, 2],   // T C A — the Y=0 side,     outward -Y
        [1, 0, 3],   // C T B — the X=0 side,     outward -X
        [0, 2, 3],   // T A B — the slanted side, outward +(1,1,1)
        [3, 2, 1],   // B A C — the base CAP,     outward -Z
    ];
    foreach (ref f; face)
        foreach (idx; f)
            data ~= pt[idx][];
}

unittest {
    // The arrowhead is a CLOSED, CAPPED tetrahedron wound uniformly outward,
    // and its body sits in one quadrant. Every claim below is re-derived from
    // the emitted floats; none of it reads a constant back to itself.
    import std.algorithm : canFind, map, sort;
    import std.array     : array;
    import std.math      : abs;

    float[] d;
    buildWedgeHeadData(d);
    assert(d.length == 4 * 3 * 3,
           "the head must be 4 triangles / 12 vertices / 36 floats");

    static Vec3 vert(const float[] d, size_t i) {
        return Vec3(d[i*3], d[i*3 + 1], d[i*3 + 2]);
    }
    static bool same(Vec3 a, Vec3 b) {
        return abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f;
    }

    // 1. Exactly FOUR distinct points, and they are the four the card names.
    Vec3[] uniq;
    foreach (i; 0 .. 12) {
        auto v = vert(d, i);
        bool seen = false;
        foreach (u; uniq) if (same(u, v)) { seen = true; break; }
        if (!seen) uniq ~= v;
    }
    assert(uniq.length == 4,
           "twelve vertices must close on four points — the head is a tetrahedron");
    foreach (want; [Vec3(0,0,1), Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)]) {
        bool found = false;
        foreach (u; uniq) if (same(u, want)) { found = true; break; }
        assert(found, "a base/apex point of the arrowhead is missing");
    }

    // 2. The ONE-QUADRANT claim, restated as REACH rather than as coordinates:
    //    the head extends a full unit along each lateral on the POSITIVE side
    //    and nothing at all on the negative one — which is why the drawn head
    //    is H across and not 2H. Check 1 already pins the four points, so this
    //    cannot fail on its own; it is kept because it says in one line what
    //    the shape is FOR, and it is the line that would have to be deleted,
    //    not merely edited, to put a symmetric head back.
    float minX = 0, maxX = 0, minY = 0, maxY = 0;
    foreach (u; uniq) {
        if (u.x < minX) minX = u.x;  if (u.x > maxX) maxX = u.x;
        if (u.y < minY) minY = u.y;  if (u.y > maxY) maxY = u.y;
    }
    assert(maxX == 1.0f && minX == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");
    assert(maxY == 1.0f && minY == 0.0f,
           "the head must reach 1 lateral unit on one side and 0 on the other");

    // 3. CLOSED and CAPPED: the four triangles are the four distinct 3-subsets
    //    of the four points, each appearing exactly once. A missing base cap
    //    (three faces) or a doubled face both fail here.
    int[][] faceKeys;
    foreach (f; 0 .. 4) {
        int[] key;
        foreach (k; 0 .. 3) {
            auto v = vert(d, f*3 + k);
            foreach (idx, u; uniq) if (same(u, v)) { key ~= cast(int)idx; break; }
        }
        assert(key.length == 3, "a face names a point that is not one of the four");
        assert(key[0] != key[1] && key[1] != key[2] && key[0] != key[2],
               "a face repeats a vertex — that triangle has no area");
        key.sort();
        assert(!faceKeys.canFind(key), "a face of the head is emitted twice");
        faceKeys ~= key;
    }
    assert(faceKeys.length == 4, "the head must have all four faces, cap included");

    // 4. WINDING: every face's CCW normal points AWAY from the solid's own
    //    centroid, i.e. the whole shape is outward-CCW and `outwardCCW` is the
    //    correct HandleFacing for it. This is the assertion that catches a
    //    face copied over with the reference's own (mixed) vertex order.
    Vec3 cen = Vec3(0,0,0);
    foreach (u; uniq) cen = cen + u;
    cen = cen / 4.0f;
    foreach (f; 0 .. 4) {
        auto p0 = vert(d, f*3), p1 = vert(d, f*3 + 1), p2 = vert(d, f*3 + 2);
        auto n  = cross(p1 - p0, p2 - p0);
        assert(dot(n, p0 - cen) > 1e-6f,
               "an arrowhead face is wound INWARD; culling GL_BACK would open "
               ~ "a hole in the solid and its alpha would stack twice there");
    }
}

// ---------------------------------------------------------------------------
// The handle pass's BLEND BRACKET.
//
// The reference requests blending PER PRIMITIVE BATCH, from a tag on the
// batch's begin call, and turns it back off for the next batch that does not
// ask. Our closest analogue to "a batch" is one of these draw helpers, so the
// bracket lives here rather than around the whole pass — the same granularity,
// and no call site can forget it.
//
// The equation is the reference's for COLOUR and deliberately not for ALPHA.
// Colour is plain `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`, which is the one blend
// function the reference sets (once, per viewport resize) and therefore the one
// every translucent handle of its own composites through. The alpha channel
// takes `ZERO / ONE` — destination alpha is left exactly as it was.
//
// That asymmetry is not a liberty; it is what porting to our target requires.
// The reference blends into a window whose alpha nobody reads afterwards. We
// blend into a CELL FBO whose colour texture ImGui then composites using that
// very alpha channel, so a translucent stroke that let its own 0.95 through to
// the destination would punch a 5 %-transparent hole in the cell and the panel
// behind would show through the gizmo. `mesh_gpu.d`'s wireframe pass already
// took this exact decision for this exact reason; this follows it.
// ---------------------------------------------------------------------------

/// Enable the handle pass's blend equation, returning the previous GL_BLEND
/// enable so the caller can restore it. See the block comment above.
private bool beginHandleBlend() {
    immutable bool had = glIsEnabled(GL_BLEND) == GL_TRUE;
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
    return had;
}

/// Undo `beginHandleBlend`. Restores the ENABLE bit to what it was and the
/// blend function to the app-wide default that every other bracket in the
/// codebase (`mesh_gpu.d`, `slice_tool.d`, `ui/panels.d`) also restores to.
private void endHandleBlend(bool hadBlend) {
    if (!hadBlend) glDisable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

/// The winding convention of a solid handle shape, i.e. which face has to be
/// culled to leave its OUTWARD surface. See `beginHandleFill` for why a
/// translucent solid must be culled at all.
///
/// The two shapes disagree, and the values below are derived rather than
/// guessed. For the cone (`buildConeData` in shapes.d) a side triangle
/// apex→P0→P1 at the base point (1,0,0) has normal ∝ (1,0,1) — radially out
/// and toward the apex, i.e. OUTWARD — so its front faces (default `GL_CCW`)
/// face out and the BACK ones are the far side. For the unit cube
/// (`buildUnitCubeData`) the -Z face 0→1→2 has normal ∝ +Z while its outward
/// normal is -Z, so that shape is wound the other way and its FRONT faces are
/// the far side.
///
/// The cube's winding is left alone deliberately. Nothing culls it today, so
/// the inversion is invisible and "fixing" it would be an unmeasured change to
/// geometry six other handle types share.
/// The transform gizmo's tetrahedral arrowhead (`buildWedgeHeadData` above) is
/// a THIRD solid and it does not inherit either convention by assumption: its
/// four faces are emitted outward-CCW on purpose, proved by the unittest beside
/// the builder. It nonetheless draws `twoLayer` — see that value.
enum HandleFacing {
    outwardCCW,   /// front faces point out — cull GL_BACK  (the cone head)
    outwardCW,    /// front faces point in  — cull GL_FRONT (the unit cube)
    flat,         /// not a solid: ONE layer already, so cull nothing
    /// A closed CONVEX solid drawn deliberately UNCULLED, so every pixel inside
    /// its silhouette composites exactly TWICE — once through the near face,
    /// once through the far one. Not an oversight and not the absence of a
    /// decision: it is the measured behaviour of the reference's arrowhead,
    /// which never culls, and the two layers are what put that head at
    /// `1-(1-a)^2` rather than at `a`. Legal only where the solid is convex
    /// AND closed (a concave one could stack three or more layers on one ray,
    /// which is the runaway `beginHandleFill` culls to prevent); the tetrahedron
    /// qualifies, and the unittest beside `buildWedgeHeadData` is what keeps it
    /// qualifying.
    twoLayer,
}

/// Bracket a translucent SOLID (triangle) handle batch drawn on the SHARED
/// program — the arrowhead cone, the scale boxes, the plane fill disc.
/// `locAlpha` is `Shader.locAlpha`; pass the part's alpha.
///
/// Returns an opaque token for `endHandleFill`. At `alpha >= 1` this issues NO
/// GL calls at all and the draw stays byte-identical to the unblended path it
/// replaced — which is what keeps the opaque parts (the centre box) off this
/// change's blast radius entirely.
///
/// WHY IT CULLS. The handle pass runs with DEPTH TESTING OFF, because handles
/// are overlays. A closed solid then rasterises every one of its faces onto the
/// same pixels — for the cone, the near side, the far side and the base cap.
/// While it was opaque that was invisible: three writes of one colour. Blended,
/// it is three composites, and 0.95 stacked three deep is 0.999875 — i.e. the
/// part renders effectively OPAQUE and the alpha silently does nothing.
/// Measured exactly that way before this cull existed: the shaft came back at
/// the predicted `0.95*axis + 0.05*bg` while the cone beside it came back at
/// the raw axis colour. Culling leaves one layer per pixel, so the alpha means
/// what it says. The silhouette is unchanged — these are convex solids.
///
/// AND WHY THE ARROWHEAD IS NOW EXEMPT (task 0604). That reasoning was right in
/// kind and overshot by one shape. The reference does NOT cull, and its head is
/// a tetrahedron: convex and closed, so a ray through it crosses exactly TWO
/// faces, not three. Two layers at 0.95 is 0.9975, and 0.9975 is what the
/// reference's arm was measured at, photometrically, across a 74-level
/// background change (its observed colour did not move, excluding a single
/// 0.95 emission by 6.4 levels). Culling the head to one layer is therefore not
/// "the alpha meaning what it says" — it is our head landing 10 levels lighter
/// than the one it is a port of. So the head passes `HandleFacing.twoLayer` and
/// keeps both layers, while every other translucent solid here — the scale
/// boxes, and any concave or many-layered shape a later part brings — keeps the
/// cull. The exemption is per shape, decided at the call site, never global.
///
/// Solid geometry is NOT antialiased here and must not be: the reference never
/// enables polygon smoothing and explicitly disables multisampling, and its
/// arrowhead was measured stepping background-to-full with no intermediate
/// value. This bracket buys TRANSPARENCY, not soft edges.
int beginHandleFill(GLint locAlpha, float alpha,
                    HandleFacing facing = HandleFacing.outwardCCW) {
    if (!(alpha < 1.0f) || locAlpha < 0) return -1;   // NaN-safe: !(nan < 1) is true
    glUniform1f(locAlpha, alpha);
    immutable bool hadBlend = beginHandleBlend();
    // Two shapes cull NOTHING, for opposite reasons, and bit 2 of the token
    // records that so `endHandleFill` restores no cull state either.
    //   `flat`     — the plane handle's fill disc is a triangle FAN whose
    //                triangles tile the disc without overlapping, so it already
    //                composites exactly once. It must not GET a cull: a flat fan
    //                seen from its other side is entirely back-facing, and
    //                culling would make the plane handle vanish depending on
    //                which way the camera is.
    //   `twoLayer` — the arrowhead, which is SUPPOSED to composite twice
    //                because the shape it ports does. See the enum.
    if (facing == HandleFacing.flat || facing == HandleFacing.twoLayer)
        return (hadBlend ? 1 : 0) | 4;
    immutable bool hadCull = glIsEnabled(GL_CULL_FACE) == GL_TRUE;
    glEnable(GL_CULL_FACE);
    glCullFace(facing == HandleFacing.outwardCCW ? GL_BACK : GL_FRONT);
    return (hadBlend ? 1 : 0) | (hadCull ? 2 : 0);
}

/// Close `beginHandleFill`, restoring the blend and cull state AND the shared
/// program's `u_alpha` to opaque. Restoring the uniform is not optional: the
/// same program draws the mesh, and a leaked 0.95 would quietly make the whole
/// model translucent on the next frame.
void endHandleFill(GLint locAlpha, int token) {
    if (token < 0) return;
    if ((token & 4) == 0) {                 // bit 2 set == `flat`, nothing culled
        if ((token & 2) == 0) glDisable(GL_CULL_FACE);
        glCullFace(GL_BACK);                // the GL default, and the app's
    }
    endHandleBlend((token & 1) != 0);
    if (locAlpha >= 0) glUniform1f(locAlpha, 1.0f);
}

// Draw VAO with GL_LINES/GL_LINE_STRIP using the thick-line program,
// then restore the caller's program.
//
// Blending is enabled UNCONDITIONALLY here, even at `alpha == 1`, because the
// analytic antialiasing works through the alpha channel: the fragment stage
// multiplies coverage into alpha, and with blending off a half-covered fringe
// pixel would simply be written at full colour and the smoothing would vanish.
// A line batch is exactly the case the reference also always blends, since
// every gizmo stroke it emits carries an alpha below 1.
//
// That last clause is no longer true of every stroke (task 0610: the rotate
// bank's backing disc carries no alpha at all and is not smoothed), and the
// unconditional blend stays right for it anyway. At `smooth = false, alpha = 1`
// every fragment this stage emits is either fully opaque or exactly zero, so a
// `SRC_ALPHA` blend is an identity on both — and the alpha channel is written
// `GL_ZERO / GL_ONE` (see `beginHandleBlend`), so the zero-coverage fragments
// outside the stroke cannot punch a hole in the cell FBO's own alpha either.
// Keeping ONE blend bracket for all line batches is worth more than saving the
// two GL calls a special case would.
package void drawThickLines(GLuint vao, int vertCount, GLenum mode,
                             const ref float[16] model,
                             const ref Viewport vp,
                             Vec3 color, float lineWidth,
                             GLuint restoreProgram,
                             float alpha = 1.0f,
                             bool smooth = true)
{
    glUseProgram(g_thickLine.prog);
    glUniformMatrix4fv(g_thickLine.locModel, 1, GL_FALSE, model.ptr);
    glUniformMatrix4fv(g_thickLine.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(g_thickLine.locProj,  1, GL_FALSE, vp.proj.ptr);
    glUniform3f(g_thickLine.locColor, color.x, color.y, color.z);
    glUniform1f(g_thickLine.locWidth, lineWidth);
    glUniform2f(g_thickLine.locScreen, g_thickLine.screenW, g_thickLine.screenH);
    if (g_thickLine.locAlpha >= 0) glUniform1f(g_thickLine.locAlpha, alpha);
    if (g_thickLine.locSmooth >= 0)
        glUniform1f(g_thickLine.locSmooth, smooth ? 1.0f : 0.0f);

    immutable bool hadBlend = beginHandleBlend();
    glBindVertexArray(vao);
    glDrawArrays(mode, 0, vertCount);
    g_fc.draw(DrawPass.handles, vertCount);
    endHandleBlend(hadBlend);

    glUseProgram(restoreProgram);
}

// Public thin wrapper around drawThickLines for callers outside handler.d
// (e.g. MoveTool's constraint-line overlay).  Same semantics as the private
// version; the `restoreProgram` is typically shader.program.
void drawThickLinesExt(GLuint vao, int vertCount, GLenum mode,
                       const ref float[16] model,
                       const ref Viewport vp,
                       Vec3 color, float lineWidth,
                       GLuint restoreProgram,
                       float alpha = 1.0f,
                       bool smooth = true)
{
    drawThickLines(vao, vertCount, mode, model, vp, color, lineWidth,
                   restoreProgram, alpha, smooth);
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
///
/// `smooth` is forwarded to the thick-line program and defaults to TRUE, which
/// is what every pre-existing caller got: a gizmo line is anti-aliased. A
/// caller that draws a line whose exact pixel VALUE is meaningful — the item
/// highlight, which paints a measured colour and is read back as one — passes
/// false, because an anti-aliased edge blends the colour with whatever is
/// behind it and there is then no pixel that carries the uniform.
void drawWorldSegment(Vec3 a, Vec3 b, const ref Viewport vp,
                      Vec3 color, float width, GLuint restoreProgram,
                      float alpha = 1.0f, bool smooth = true)
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
    drawThickLines(g_segVao, 2, GL_LINES, model, vp, color, width,
                   restoreProgram, alpha, smooth);
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

// Register the reference-image-plane program (compiled in app.d from
// shader.imagePlaneVertSrc / imagePlaneFragSrc), mirroring initFillProgram.
// Backs drawImagePlane.
//
// `u_tex` is bound to texture unit 0 ONCE, here, rather than on every draw:
// a sampler uniform is program state, the draw always binds its texture to
// unit 0, and re-writing it per frame would be a uniform whose value can
// never differ between calls.
void initImagePlaneProgram(GLuint prog) {
    g_imagePlane.prog            = prog;
    g_imagePlane.locView         = glGetUniformLocation(prog, "u_view");
    g_imagePlane.locProj         = glGetUniformLocation(prog, "u_proj");
    g_imagePlane.locTex          = glGetUniformLocation(prog, "u_tex");
    g_imagePlane.locBrightness   = glGetUniformLocation(prog, "u_brightness");
    g_imagePlane.locContrast     = glGetUniformLocation(prog, "u_contrast");
    g_imagePlane.locTransparency = glGetUniformLocation(prog, "u_transparency");
    g_imagePlane.locInvert       = glGetUniformLocation(prog, "u_invert");
    GLint prevProg;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
    glUseProgram(prog);
    if (g_imagePlane.locTex >= 0) glUniform1i(g_imagePlane.locTex, 0);
    glUseProgram(cast(GLuint) prevProg);
}

// Lazily-built dynamic VAO for drawImagePlane's 4 textured world corners.
private GLuint g_planeVao, g_planeVbo;
private bool   g_planeReady;

/// Draw one reference-image plane: the quad `center ± halfU ± halfV`, textured
/// with `tex`, graded by the three look scalars, as a `GL_TRIANGLE_FAN`.
///
/// STATE DISCIPLINE, and each line of it is load-bearing:
///
/// * **`glDisable(GL_DEPTH_TEST)`**, restored after. Disabling the test also
///   suppresses depth WRITES, so this pass leaves the depth buffer exactly as
///   the FBO clear left it and every later pass wins regardless of world
///   position. That is the point: the walkthrough puts the reference image on
///   the mid-line at X=0 and models symmetric geometry straddling it — under
///   ordinary depth testing half the model would be swallowed by the picture
///   behind it. `glDepthMask(GL_FALSE)` — the other house idiom, used by the
///   slice preview — keeps the depth TEST on, which is right for a translucent
///   plane that must be occluded by the geometry it cuts and exactly wrong
///   for a backdrop.
/// * **`glBlendFuncSeparate(..., GL_ZERO, GL_ONE)`**, not `glBlendFunc`. The
///   cell renders into an FBO whose alpha is a real attachment that ImGui
///   composites; a naive `glBlendFunc` with `transparency > 0` eats the
///   cell's alpha and makes the whole viewport translucent. Same reasoning,
///   same fix as `mesh_gpu.d`'s translucent passes.
/// * **culling off**, restored. The plane is two-sided: a `front` reference
///   seen from behind in a perspective cell still draws. (Whether the
///   reference editor culls it is unmeasured — the capture's perspective
///   camera was in front of the plane — so this is our choice, stated.)
/// * **the filter comes from the plane's `smooth` channel**, set on the bound
///   texture per draw. The texture object is shared by every plane on the
///   same file, so two planes disagreeing about `smooth` would each set it
///   before their own draw; the redundancy is deliberate and cheap, and the
///   alternative (baking the filter at upload time) would make the channel
///   silently ignored for the second consumer of a shared file.
void drawImagePlane(Vec3 center, Vec3 halfU, Vec3 halfV,
                    bool flipU, bool invert, bool smooth,
                    float brightness, float contrast, float transparency,
                    GLuint tex, const ref Viewport vp, GLuint restoreProgram)
{
    version(unittest) {
        // No GL context under -unittest. The corner geometry this would upload
        // is `image_plane.resolvePlacement`'s output, which is asserted there
        // as numbers — deliberately, because a pixel is the END of this
        // pipeline and a mismatch in it localises nothing.
    } else {
        if (tex == 0) return;   // not resident: skip. NEVER decode from a draw.
        if (!g_planeReady) {
            glGenVertexArrays(1, &g_planeVao);
            glGenBuffers(1, &g_planeVbo);
            glBindVertexArray(g_planeVao);
            glBindBuffer(GL_ARRAY_BUFFER, g_planeVbo);
            glBufferData(GL_ARRAY_BUFFER, 20 * float.sizeof, null, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * float.sizeof,
                                  cast(void*)(3 * float.sizeof));
            glEnableVertexAttribArray(1);
            glBindVertexArray(0);
            g_planeReady = true;
        }

        // Fan order: -U-V, +U-V, +U+V, -U+V. The texture's row 0 is the
        // image's TOP row (that is how the decoder hands it over and how it is
        // uploaded), so v = 0 is the top and the -V corners take v = 1.
        //
        // `flipU` swaps the u coordinates and leaves the CORNERS alone. Doing
        // it the other way — negating `halfU` — would mirror the plane's
        // PLACEMENT as well as its pixels, moving the image to the other side
        // of the item's centre instead of mirroring it in place.
        immutable float u0 = flipU ? 1.0f : 0.0f;
        immutable float u1 = flipU ? 0.0f : 1.0f;
        Vec3 c0 = center - halfU - halfV;
        Vec3 c1 = center + halfU - halfV;
        Vec3 c2 = center + halfU + halfV;
        Vec3 c3 = center - halfU + halfV;
        float[20] data = [
            c0.x, c0.y, c0.z, u0, 1.0f,
            c1.x, c1.y, c1.z, u1, 1.0f,
            c2.x, c2.y, c2.z, u1, 0.0f,
            c3.x, c3.y, c3.z, u0, 0.0f,
        ];
        glBindBuffer(GL_ARRAY_BUFFER, g_planeVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0, data.sizeof, data.ptr);

        immutable bool hadCull  = glIsEnabled(GL_CULL_FACE) == GL_TRUE;
        immutable bool hadDepth = glIsEnabled(GL_DEPTH_TEST) == GL_TRUE;
        immutable bool hadBlend = glIsEnabled(GL_BLEND) == GL_TRUE;
        if (hadCull) glDisable(GL_CULL_FACE);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);

        glUseProgram(g_imagePlane.prog);
        glUniformMatrix4fv(g_imagePlane.locView, 1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(g_imagePlane.locProj, 1, GL_FALSE, vp.proj.ptr);
        glUniform1f(g_imagePlane.locBrightness,   brightness);
        glUniform1f(g_imagePlane.locContrast,     contrast);
        glUniform1f(g_imagePlane.locTransparency, transparency);
        glUniform1f(g_imagePlane.locInvert,       invert ? 1.0f : 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex);
        immutable GLint filt = smooth ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);

        glBindVertexArray(g_planeVao);
        glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
        g_fc.draw(DrawPass.imagePlane, 4);
        glBindVertexArray(0);
        glBindTexture(GL_TEXTURE_2D, 0);

        // Restore: the blend func back to the house default, then the three
        // enables to whatever the caller had.
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        if (!hadBlend) glDisable(GL_BLEND);
        if (hadDepth)  glEnable(GL_DEPTH_TEST);
        if (hadCull)   glEnable(GL_CULL_FACE);
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
