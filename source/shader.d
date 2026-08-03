module shader;

import bindbc.opengl;
import std.string : toStringz;


import view;
import math;
import mesh : Surface, GpuMesh;
import gl_thread_guard : glThreadGuard;
import display_state : kSchemeSolidFill;
// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

immutable string vertexShaderSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * u_model * vec4(aPos, 1.0);
    }
};

immutable string fragmentShaderSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_dim;        // brightness multiplier; 1.0 = neutral (layers Stage 5)
    uniform float u_alpha;      // fragment opacity; 1.0 = opaque (task 0559)
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color * u_dim, u_alpha);
    }
};

// Every uniform of `fragmentShaderSrc` that is NOT written on the draw path,
// paired with the value that means "do nothing". A program built from that
// source must be seeded with all of them before its first draw, because GL
// initialises an unset uniform to 0 and 0 is the DESTRUCTIVE value for both:
// `u_dim = 0` renders black, `u_alpha = 0` renders nothing.
//
// "That source" is now TWO sources sharing one CONTRACT: `fragmentShaderSrc`
// and `thickLineFragSrc` (which had to split off to consume the geometry
// stage's coverage varying — see its own comment). They declare the same
// uniform names with the same meanings, and `seedSharedFragUniforms` resolves
// by name, so the obligation below still reaches both. A new entry here is
// still a single edit; a new uniform in only ONE of the two sources is the
// thing to avoid.
//
// The list lives here, next to the shader source it describes, because of the
// bug that produced it: `u_alpha` was added to the shared source by task 0559
// and only ONE of the two programs built from it was taught to seed the new
// uniform, so every gizmo shaft and rotate ring reached the framebuffer with
// the right colour and zero coverage and was composited away as the panel grey
// behind it. That is not a typo at a call site, it is a hazard of the shared
// source itself — adding a uniform to `fragmentShaderSrc` silently adds an
// obligation to every program built from it, past and future. Adding the
// entry here, and calling `seedSharedFragUniforms` from every builder,
// discharges that obligation in one place instead of N.
private immutable struct SharedFragUniform { string name; float neutral; }
private immutable SharedFragUniform[] kSharedFragNeutrals = [
    SharedFragUniform("u_dim",   1.0f),   // brightness multiplier (layers Stage 5)
    SharedFragUniform("u_alpha", 1.0f),   // fragment opacity (task 0559)
];

/// Seed every non-draw-path uniform of the shared `fragmentShaderSrc` on
/// `prog` to its neutral value, then restore the previously-bound program.
///
/// Call this from EVERY builder of a `fragmentShaderSrc` program, right after
/// linking. Locations are looked up here rather than taken from the caller so
/// a builder cannot seed a uniform it forgot to cache; a `< 0` location (the
/// uniform absent, or optimised out because the source dropped it) is skipped,
/// which keeps this forward-compatible with the shader changing again.
///
/// Restoring the previous program matters: builders run during init, where
/// some other program may already be bound and the caller does not expect its
/// binding to move under it.
void seedSharedFragUniforms(GLuint prog) {
    GLint prevProg;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
    glUseProgram(prog);
    foreach (u; kSharedFragNeutrals) {
        GLint loc = glGetUniformLocation(prog, u.name.toStringz());
        if (loc >= 0) glUniform1f(loc, u.neutral);
    }
    glUseProgram(cast(GLuint)prevProg);
}

// Flat translucent-fill fragment shader — a solid `u_color` at a per-draw
// `u_alpha`. Its OWN program, and its own `u_alpha` distinct from the shared
// source's: this one is WRITTEN on every draw (drawWorldQuad takes the alpha
// as a parameter), so it is never a seeding obligation.
//
// The comment that used to sit here claimed `fragmentShaderSrc` had "no
// shared `u_alpha` uniform to seed". That stopped being true when task 0559
// added exactly such a uniform to it, and the stale claim is part of why the
// gap survived: it read as a standing guarantee that the shared program had
// nothing to seed. See `kSharedFragNeutrals` above for what it actually owes.
immutable string fillFragSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_alpha;
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color, u_alpha);
    }
};

// Lit shaders — Blinn-Phong with flat per-face normals.
//
// Material Groups (MG3): a 64-slot std140 UBO carries per-mesh surface
// data. Each face-VBO vertex tags its triangle with an `aMatId` (flat-
// interpolated uint); the fragment shader looks up base[aMatId].rgb as
// the diffuse tint. `u_color` keeps its existing role as a per-draw
// multiplier — set to (1,1,1) for the natural material colour, or a
// tint (e.g. hover-blue) by drawFaces / drawFacesHighlighted. Meshes
// with no surfaces seed slot 0 to a neutral grey so the look pre-MG3
// is preserved.
enum LIT_MAX_MATS = 64;
private immutable string litVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec3 aNormal;
    layout(location = 2) in uint aMatId;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3      vNormal;
    out vec3      vWorldPos;
    flat out uint vMatId;
    void main() {
        vec4 worldPos = u_model * vec4(aPos, 1.0);
        vWorldPos     = worldPos.xyz;
        vNormal       = mat3(u_model) * aNormal;
        vMatId        = aMatId;
        gl_Position   = u_proj * u_view * worldPos;
    }
};

private immutable string litFragSrc = q{
    #version 330 core
    in       vec3 vNormal;
    in       vec3 vWorldPos;
    flat in  uint vMatId;
    uniform vec3  u_color;          // override colour for hover/highlight paths
    uniform float u_overrideMix;    // 0 = use material UBO, 1 = use u_color
    uniform vec3  u_lightDir;
    uniform vec3  u_eyePos;
    uniform float u_ambient;
    uniform float u_specStr;
    uniform float u_specPow;
    uniform float u_dim;            // brightness multiplier; 1.0 = neutral (layers Stage 5)
    uniform bool  u_lit;            // false = flat unshaded fill (Solid style, task 0589)
    uniform vec3  u_fillColor;      // the unlit fill's base; NOT the material (task 0592)
    layout(std140) uniform Materials {
        vec4 mat_base[64];     // .rgb = baseColor, .a = opacity
        vec4 mat_params[64];   // .x = diffuse, .y = specular, .z = glossiness
    };
    out vec4 fragColor;
    void main() {
        // TWO BASE COLOURS, NOT ONE SCALED. The lit path's base is the
        // MATERIAL; the unlit path's base is `u_fillColor`, the viewport
        // colour scheme's fill entry. That split is task 0592's correction:
        // the reference's unshaded style never consults a surface at all, so
        // "Solid is Shaded minus the lighting term" was wrong about where the
        // colour comes from, not only about how it is shaded.
        //
        // Still a real branch rather than a mix()/multiply by zero, for the
        // reasons task 0589 recorded:
        //   * a zero-length vNormal makes `normalize` produce NaN, and NaN * 0
        //     is NaN, so a multiplicative "off" would leak a degenerate face
        //     into the fill;
        //   * a branch on a UNIFORM is uniform across the whole draw, so it
        //     costs nothing to diverge on.
        // What unlit deliberately KEEPS: the `u_color`/`u_overrideMix` mix (so
        // the hover/highlight override colour still reaches the fill —
        // selection and rollover are their own display axes and must survive
        // every surface style) and `u_dim`.
        vec3 col;
        if (u_lit) {
            uint  mi  = (vMatId < uint(64)) ? vMatId : uint(0);
            vec3  bc  = mix(mat_base[mi].rgb, u_color, u_overrideMix);
            vec3 N    = normalize(vNormal);
            vec3 L    = u_lightDir;
            vec3 V    = normalize(u_eyePos - vWorldPos);
            vec3 H    = normalize(L + V);
            float dif = max(dot(N, L), 0.0);
            float spc = pow(max(dot(N, H), 0.0), u_specPow);
            col = bc * (u_ambient + dif * (1.0 - u_ambient))
                + vec3(1.0) * spc * u_specStr;
        } else {
            col = mix(u_fillColor, u_color, u_overrideMix);
        }
        fragColor = vec4(col * u_dim, 1.0);
    }
};

// Checkerboard overlay shader — every other screen pixel is discarded,
// the rest are filled with u_color.  Used to highlight selected faces.
private immutable string checkerFragSrc = q{
    #version 330 core
    uniform vec3 u_color;
    out vec4 fragColor;
    void main() {
        if ((int(gl_FragCoord.x)/2 + int(gl_FragCoord.y)) % 2 == 0 || int(gl_FragCoord.x) % 2 == 0) discard;
        fragColor = vec4(u_color, 1.0);
    }
};

// Grid shaders — vertex passes world pos, fragment computes fade alpha.
private immutable string gridVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vWorldPos;
    void main() {
        vWorldPos   = (u_model * vec4(aPos, 1.0)).xyz;
        gl_Position = u_proj * u_view * vec4(vWorldPos, 1.0);
    }
};

private immutable string gridFragSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_maxDist;     // world-space fade radius
    uniform vec2  u_screenSize;  // 3D viewport size in fb pixels
    uniform float u_vpOriginX;   // 3D viewport left edge in fb pixels
    uniform float u_vpOriginY;   // 3D viewport bottom edge in fb pixels
    in  vec3 vWorldPos;
    out vec4 fragColor;
    void main() {
        // Distance fade: full opacity at origin, zero at u_maxDist
        float dist      = length(vWorldPos.xz);
        float distAlpha = 1.0 - smoothstep(0.0, u_maxDist, dist);

        // Screen-edge fade (all four edges): min 20%
        float sx       = (gl_FragCoord.x - u_vpOriginX) / u_screenSize.x;
        float sy       = (gl_FragCoord.y - u_vpOriginY) / u_screenSize.y;
        float edgeFade = smoothstep(0.0, 0.15, sx) * smoothstep(1.0, 0.85, sx)
                       * smoothstep(0.0, 0.15, sy) * smoothstep(1.0, 0.85, sy);
        float edgeAlpha = mix(0.2, 1.0, edgeFade);

        fragColor = vec4(u_color, distAlpha * edgeAlpha);
    }
};

// ---------------------------------------------------------------------------
// Shader helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, string src) {
    // Funnel 2 of 2. The lowest point of every program build — `createProgram`,
    // `createProgramWithGeom` and gpu_select's own builder all route through
    // here — so guarding it covers every `*Shader` ctor. See gl_thread_guard.d.
    glThreadGuard("compileShader");
    GLuint shader = glCreateShader(type);
    const(char)* p = src.toStringz();
    glShaderSource(shader, 1, &p, null);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetShaderInfoLog(shader, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Shader error: " ~ log[].to!string);
    }
    return shader;
}

GLuint createProgram(string vertSrc = vertexShaderSrc,
                     string fragSrc = fragmentShaderSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(frag);
    return prog;
}

// Geometry shader that expands GL_LINES into screen-aligned quads
// to produce thick lines on macOS Core Profile (where glLineWidth > 1 is unsupported).
//
// UNITS — `u_lineWidth` is the stroke width in WINDOW PIXELS.
//
// It did not use to be. The old conversion was `s = ndc * u_screenSize`, but
// NDC spans [-1, 1] across the framebuffer, so one pixel is TWO units of that
// `s` — every line came out at exactly HALF its nominal width. Measured on
// pixels through /api/viewport/probe before the fix, on three independent
// nominal widths at once: the move shaft's 5.0 rendered 2.5 px of ink, the
// rotate arcs' 6.0 rendered 3 px, and the view ring's 4.0 rendered 2 px. One
// factor, three readings, so the scale below is `u_screenSize * 0.5`.
//
// Fixing it was not cosmetic. `handles/gl_util.gizmoHeadHalfPx` multiplies the
// arrowhead's half-width by `0.5 * max(2.0, lineWidth)` — a law measured
// against a stroke in real pixels — and the coverage ramp in the fragment
// stage below is a HALF-PIXEL band, which is only half a pixel if the varying
// it thresholds is in pixels too. Both were quietly reading a doubled number.
// Every call site was rescaled with this change so that no line's RENDERED
// width moved except the transform gizmo's, which is the point of the task.
immutable string thickLineGeomSrc = q{
    #version 330 core
    layout(lines) in;
    layout(triangle_strip, max_vertices = 4) out;
    uniform float u_lineWidth;   // stroke width, WINDOW PIXELS
    uniform vec2  u_screenSize;  // framebuffer size in pixels

    // Signed perpendicular distance from the line's centreline, WINDOW PIXELS.
    // `noperspective` is load-bearing, not decoration: the quad's two ends can
    // sit at very different depths, and the default perspective-correct
    // interpolation would make this vary non-linearly ACROSS THE SCREEN — the
    // antialiasing fringe would widen at the far end and pinch at the near one.
    // Screen-space coverage needs a screen-linear varying.
    noperspective out float vEdgeDist;

    // The coverage ramp needs somewhere to live: a stroke edge is soft for half
    // a pixel on each side, and a fragment outside the quad is never shaded at
    // all. So the quad is grown past the stroke's own half-width by this much.
    // At the grown edge the fragment's coverage is exactly 0, so the padding
    // costs nothing visible — it only enlarges the rasterised area slightly.
    const float kAaPadPx = 1.0;

    void main() {
        vec4 p0 = gl_in[0].gl_Position;
        vec4 p1 = gl_in[1].gl_Position;
        // Clip -> WINDOW PIXELS. NDC spans [-1,1] over `u_screenSize` pixels,
        // so the scale is HALF the framebuffer size, not the whole of it.
        vec2 halfScreen = u_screenSize * 0.5;
        vec2 s0 = p0.xy / p0.w * halfScreen;
        vec2 s1 = p1.xy / p1.w * halfScreen;
        vec2 dir = s1 - s0;
        float len = length(dir);
        if (len < 0.001) return;
        // Perpendicular in window pixels, half-width plus the fringe's room.
        float halfE = u_lineWidth * 0.5 + kAaPadPx;
        vec2 perp = vec2(-dir.y, dir.x) / len * halfE;
        // Back to clip-space offsets (un-divide by w).
        vec2 off0 = perp / halfScreen * p0.w;
        vec2 off1 = perp / halfScreen * p1.w;
        gl_Position = vec4(p0.xy + off0, p0.zw); vEdgeDist =  halfE; EmitVertex();
        gl_Position = vec4(p0.xy - off0, p0.zw); vEdgeDist = -halfE; EmitVertex();
        gl_Position = vec4(p1.xy + off1, p1.zw); vEdgeDist =  halfE; EmitVertex();
        gl_Position = vec4(p1.xy - off1, p1.zw); vEdgeDist = -halfE; EmitVertex();
        EndPrimitive();
    }
};

// The thick-line program's OWN fragment stage — ANALYTIC line antialiasing.
//
// WHY THIS IS NOT `fragmentShaderSrc`. It cannot be: it consumes a varying
// (`vEdgeDist`) that only the geometry stage above produces, and a fragment
// input with no matching upstream output is a link error. The regular program
// has no geometry stage, so the two sources had to split.
//
// WHAT IT KEEPS. The uniform CONTRACT is deliberately identical — `u_color`,
// `u_dim`, `u_alpha`, same names, same meanings — so `seedSharedFragUniforms`
// (which looks its list up by NAME and skips what is absent) still discharges
// this program's seeding obligation exactly as it does the regular one. Adding
// a uniform to `kSharedFragNeutrals` still reaches both. Splitting the SOURCE
// without splitting the CONTRACT is what keeps the task-0559 greyed-lines
// hazard closed rather than re-opening it under a new name.
//
// THE COVERAGE FUNCTION, and why this shape. The reference antialiases lines
// the fixed-function way — `GL_LINE_SMOOTH`, where the driver multiplies the
// fragment's alpha by its pixel coverage and an ordinary SRC_ALPHA blend turns
// that into a soft edge. We cannot use it: our "line" is already a geometry-
// shader quad (Core Profile has no `glLineWidth > 1`), so there is no GL line
// for the driver to smooth. The port is therefore analytic — carry the
// perpendicular distance, convert it to coverage here, multiply it into alpha.
// Same coverage-to-alpha result, different route.
//
// The ramp is a one-pixel `smoothstep` centred ON the stroke's own edge: full
// coverage half a pixel inside it, zero half a pixel outside. That width is
// the only choice that leaves the stroke's 50 %-coverage contour exactly where
// an unantialiased stroke's hard edge was, so switching this on changes the
// EDGES and not the WEIGHT. `smoothstep` rather than a linear ramp because the
// measuring lane could not fit the reference's own falloff — the fixed-function
// coverage function belongs to the driver, not to the engine, so there is no
// engine-side shape to match — and named it the conventional first choice.
//
// Note what this deliberately does NOT do: nothing here touches the SOLID
// handle geometry. The reference never enables `GL_POLYGON_SMOOTH` and
// explicitly disables `GL_MULTISAMPLE`, and its arrowheads and centre cube
// were measured stepping from background straight to full colour with no
// intermediate value. Hard-edged solids are what matching looks like.
//
// SMOOTHING IS PER SHAPE, NOT PER RENDERER (task 0610). Coverage-into-alpha
// above is what a smoothed stroke wants, and it used to be the ONLY thing this
// stage could do — every line drawn through this program was antialiased,
// whether or not the shape it came from asked to be. That is not the reference's
// model: it requests smoothing per BATCH, and several of its gizmo strokes do
// not request it. The rotate bank's backing disc is the first of ours to be
// measured as one of them (its ink is a single exact value with no fringe, next
// to a screen-plane ring in the same frame that is graded on both edges), so
// this stage now takes the request as a uniform.
//
// `u_smooth = 0` is a HARD edge in the strict sense: coverage is 1 inside the
// stroke's own half-width and 0 outside it, with no intermediate value possible
// at any pixel. The geometry stage still pads the quad by `kAaPadPx`, and those
// padding fragments are exactly the ones this zeroes — the padding costs a
// little rasterised area and changes nothing that reaches the framebuffer.
//
// It is a UNIFORM branch, so it is coherent across every fragment of a batch and
// costs nothing measurable; written that way rather than as a `mix` because
// "which of two coverage laws" is what it is, and a reader should not have to
// work out that one side of the interpolation is dead.
//
// DEFAULT IS SMOOTHED. Every existing caller keeps analytic AA without saying
// anything; only a shape that opts out changes. Two other strokes are known not
// to request smoothing in the reference — the scale shaft and the guide lines —
// and they are deliberately NOT switched here: neither has been measured on our
// own pixels, and this task's evidence covers the disc alone. The mechanism is
// what makes them a one-line change when someone measures them.
immutable string thickLineFragSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_dim;        // brightness multiplier; 1.0 = neutral
    uniform float u_alpha;      // fragment opacity; 1.0 = opaque
    uniform float u_lineWidth;  // stroke width, WINDOW PIXELS (shared with the geometry stage)
    uniform float u_smooth;     // 1 = analytic coverage AA, 0 = hard-edged; 1.0 = neutral
    noperspective in float vEdgeDist;
    out vec4 fragColor;
    void main() {
        float halfW = u_lineWidth * 0.5;
        float d     = abs(vEdgeDist);
        float cov   = (u_smooth > 0.5)
                    ? 1.0 - smoothstep(halfW - 0.5, halfW + 0.5, d)
                    : (d <= halfW ? 1.0 : 0.0);
        fragColor = vec4(u_color * u_dim, u_alpha * cov);
    }
};

GLuint createProgramWithGeom(string vertSrc, string geomSrc, string fragSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint geom = compileShader(GL_GEOMETRY_SHADER, geomSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, geom);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(geom);
    glDeleteShader(frag);
    return prog;
}

class Shader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;
    GLint locDim;
    GLint locAlpha;

    this() {
        program  = createProgram();
        locModel  = glGetUniformLocation(program, "u_model");
        locView   = glGetUniformLocation(program, "u_view");
        locProj   = glGetUniformLocation(program, "u_proj");
        locColor  = glGetUniformLocation(program, "u_color");
        locDim    = glGetUniformLocation(program, "u_dim");
        locAlpha  = glGetUniformLocation(program, "u_alpha");
        // Seed the shared source's neutral uniforms ONCE, here, and not only
        // in useProgram(). GL initialises an unset uniform to 0, and this
        // program is also driven by a handful of call sites that bind it with
        // a bare glUseProgram(shader.program) instead of going through
        // useProgram() (gizmo shapes, the pen preview, the slice overlay).
        // Seeding in the constructor means both uniforms are neutral from the
        // very first frame no matter which site binds the program first, so no
        // draw ordering can ever expose the 0 default.
        //
        // Through the shared helper rather than a hand-written glUniform1f per
        // uniform: this class is one of TWO builders on the shared uniform
        // CONTRACT (the other is app.d's thick-line program, now built from
        // `thickLineFragSrc`), and the one that seeded by hand is the one that
        // fell behind when a uniform was added.
        seedSharedFragUniforms(program);
    }
    ~this() {  glDeleteProgram(program); }

    void useProgram(const ref float[16] meshModel, const ref Viewport vp) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        // Default to neutral brightness. The active-layer / single-layer
        // pass never touches u_dim ⇒ byte-identical to pre-Stage-5. The
        // dimmed background pass sets it explicitly with setDim() before
        // its draws and is responsible for restoring 1.0 afterwards.
        glUniform1f(locDim, 1.0f);
        // Same neutrality contract as u_dim: every pass starts fully opaque.
        // The one pass that lowers it (the base wireframe overlay, task 0559)
        // restores 1.0 immediately after its own draws.
        glUniform1f(locAlpha, 1.0f);
    }

    /// Override the brightness multiplier for the next draws on this
    /// program. Used only by the dimmed background-layer pass (layers
    /// Stage 5); pass 1.0 to restore the neutral default.
    void setDim(float dim) {
        glUseProgram(program);
        glUniform1f(locDim, dim);
    }

    /// Override fragment opacity for the next draws on this program; pass
    /// 1.0 to restore the neutral default.
    ///
    /// NOT the same knob as setDim, and the difference is the whole point:
    /// `u_dim` multiplies the colour, so it fades a line toward BLACK, while
    /// `u_alpha` is a real coverage value, so a blended line fades toward
    /// WHATEVER IS BEHIND IT. A faint wireframe over a lit surface needs the
    /// second one — dimming it would just draw dark lines.
    ///
    /// Writing this alone changes nothing: the fragment alpha is only
    /// observable with GL_BLEND enabled, which the caller owns.
    void setAlpha(float a) {
        glUseProgram(program);
        glUniform1f(locAlpha, a);
    }
};

class CheckerShader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;

    this() {
        program  = createProgram(vertexShaderSrc, checkerFragSrc);
        locModel = glGetUniformLocation(program, "u_model");
        locView  = glGetUniformLocation(program, "u_view");
        locProj  = glGetUniformLocation(program, "u_proj");
        locColor = glGetUniformLocation(program, "u_color");
    }

    ~this() { glDeleteProgram(program); }

    void useProgram(const ref float[16] meshModel, const ref Viewport vp, float r, float g, float b) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(locColor, r, g, b);
    }
}

class LitShader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;
    GLint locOverrideMix;
    GLint locLightDir;
    GLint locEyePos;
    GLint locAmbient;
    GLint locSpecStr;
    GLint locSpecPow;
    GLint locDim;
    GLint locLit;
    GLint locFillColor;
    GLuint matsUbo;            // Material Groups (MG3) — Materials UBO
    enum  MATS_BINDING = 0;    // binding point index, matches std140 layout

    this() {
        program        = createProgram(litVertSrc, litFragSrc);
        locModel       = glGetUniformLocation(program, "u_model");
        locView        = glGetUniformLocation(program, "u_view");
        locProj        = glGetUniformLocation(program, "u_proj");
        locColor       = glGetUniformLocation(program, "u_color");
        locOverrideMix = glGetUniformLocation(program, "u_overrideMix");
        locLightDir    = glGetUniformLocation(program, "u_lightDir");
        locEyePos      = glGetUniformLocation(program, "u_eyePos");
        locAmbient     = glGetUniformLocation(program, "u_ambient");
        locSpecStr     = glGetUniformLocation(program, "u_specStr");
        locSpecPow     = glGetUniformLocation(program, "u_specPow");
        locDim         = glGetUniformLocation(program, "u_dim");
        locLit         = glGetUniformLocation(program, "u_lit");
        locFillColor   = glGetUniformLocation(program, "u_fillColor");

        // Materials UBO — std140-sized for two arrays of 64 × vec4.
        glGenBuffers(1, &matsUbo);
        glBindBuffer(GL_UNIFORM_BUFFER, matsUbo);
        glBufferData(GL_UNIFORM_BUFFER,
            cast(GLsizeiptr)(2 * LIT_MAX_MATS * 4 * float.sizeof),
            null, GL_DYNAMIC_DRAW);
        glBindBuffer(GL_UNIFORM_BUFFER, 0);
        glBindBufferBase(GL_UNIFORM_BUFFER, MATS_BINDING, matsUbo);

        // Bind shader's `Materials` block to our binding point. Layout
        // is std140 so the binary layout is independent of driver
        // quirks — we just need the program → binding-point hookup.
        GLuint blockIdx = glGetUniformBlockIndex(program, "Materials");
        if (blockIdx != GL_INVALID_INDEX)
            glUniformBlockBinding(program, blockIdx, MATS_BINDING);

        // Seed slot 0 to a neutral grey so meshes that have no
        // surfaces — every procedural primitive — render the same
        // 0.8-grey they did pre-MG3.
        Surface defaultSurf;
        defaultSurf.baseColor = Vec3(0.8f, 0.8f, 0.8f);
        setSurfaces([defaultSurf]);
    }

    ~this() {
        glDeleteProgram(program);
        glDeleteBuffers(1, &matsUbo);
    }

    /// Upload a Surface[] into the Materials UBO. Pads the unused tail
    /// with a neutral grey so out-of-range matId reads land on
    /// something sensible. Caller invokes this whenever
    /// `mesh.surfaces` changes (cheap — only a 4 KB transfer at
    /// MAX_MATS = 64).
    void setSurfaces(in Surface[] surfaces) {
        float[4 * LIT_MAX_MATS] base   = 0;
        float[4 * LIT_MAX_MATS] params = 0;
        foreach (i; 0 .. LIT_MAX_MATS) {
            Surface s;
            if (i < surfaces.length) {
                s = surfaces[i];
            } else if (i == 0) {
                // Slot 0 is the always-default. When the caller passes
                // an empty array, this is the fallback for every face.
                s.baseColor = Vec3(0.8f, 0.8f, 0.8f);
            } else {
                // Padding slots stay neutral so a stale matId read
                // doesn't produce a black face.
                s.baseColor = Vec3(0.8f, 0.8f, 0.8f);
            }
            base[i * 4 + 0] = s.baseColor.x;
            base[i * 4 + 1] = s.baseColor.y;
            base[i * 4 + 2] = s.baseColor.z;
            base[i * 4 + 3] = s.opacity;
            params[i * 4 + 0] = s.diffuseAmount;
            params[i * 4 + 1] = s.specularAmount;
            params[i * 4 + 2] = s.glossiness;
            params[i * 4 + 3] = 0;
        }
        glBindBuffer(GL_UNIFORM_BUFFER, matsUbo);
        glBufferSubData(GL_UNIFORM_BUFFER, 0,
            cast(GLsizeiptr)(LIT_MAX_MATS * 4 * float.sizeof),
            base.ptr);
        glBufferSubData(GL_UNIFORM_BUFFER,
            cast(GLintptr)(LIT_MAX_MATS * 4 * float.sizeof),
            cast(GLsizeiptr)(LIT_MAX_MATS * 4 * float.sizeof),
            params.ptr);
        glBindBuffer(GL_UNIFORM_BUFFER, 0);
    }

    void useProgram(const ref float[16] meshModel, const ref Viewport vp) {
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
        // Default to material-lookup mode. drawFacesHighlighted flips
        // this to 1.0 for hover draws that need to override the
        // surface colour with u_color.
        glUniform1f(locOverrideMix, 0.0f);
        glUniform1f(locAmbient,  0.20f);
        glUniform1f(locSpecStr,  0.25f);
        glUniform1f(locSpecPow,  32.0f);
        // Default to neutral brightness. The active-layer / single-layer
        // pass never touches u_dim ⇒ byte-identical to pre-Stage-5. The
        // dimmed background pass sets it explicitly with setDim() before
        // its draws and restores 1.0 afterwards.
        glUniform1f(locDim, 1.0f);
        // Default to LIT, for exactly the reason u_dim defaults to neutral:
        // every caller that does not care about the display style gets the
        // behaviour that predates it. The Solid pass flips this with setLit()
        // before its draws and restores true afterwards.
        glUniform1i(locLit, 1);
        // Seed the unlit fill to the colour-scheme value. A GLSL uniform
        // defaults to 0, so an unseeded `u_fillColor` would render the Solid
        // style BLACK for any caller that draws without going through the
        // display plan (the create-tool previews below, for one). Not
        // observable at all while `u_lit` is true, which is the default.
        glUniform3f(locFillColor,
            kSchemeSolidFill, kSchemeSolidFill, kSchemeSolidFill);
    }

    /// Override the brightness multiplier for the next draws on this
    /// program. Used only by the dimmed background-layer pass (layers
    /// Stage 5); pass 1.0 to restore the neutral default.
    void setDim(float dim) {
        glUseProgram(program);
        glUniform1f(locDim, dim);
    }

    /// Light the surface, or fill it flat (task 0589, `DrawPlan.facesLit`).
    ///
    /// Same restore discipline as `setDim`: the caller that switches it off
    /// switches it back on, because uniforms are program state and the next
    /// draw on this program may be someone else's.
    void setLit(bool lit) {
        glUseProgram(program);
        glUniform1i(locLit, lit ? 1 : 0);
    }

    /// The unshaded fill's base colour (task 0592, `DrawPlan.fillColor`).
    ///
    /// Same restore discipline as `setDim`/`setLit`. Paired with `setLit` at
    /// every call site rather than set only on the unlit path: the pair is one
    /// decision ("draw the Solid style"), and splitting them is how the fill
    /// would later be set by a pass that forgot to unset the lighting.
    void setFillColor(in float[3] c) {
        glUseProgram(program);
        glUniform3f(locFillColor, c[0], c[1], c[2]);
    }
}

// Shared "lit preview" draw: solid shaded faces (LitShader — identity
// model, fixed key light, flat ambient/spec) followed by wireframe edges
// (plain Shader). Used by every primitive/incremental create-tool (box,
// bridge, capsule, cone, cylinder, mirror, radial-sweep, sphere, tack,
// torus, tube) to render its in-progress preview mesh — lifted verbatim
// from the `draw()` GL block every one of them repeated (task 0410, dedup
// 0407 §A.D6). `previewGpu` is `ref` (not `const`) because
// GpuMesh.drawFaces/drawEdges are not const-qualified.
void drawLitPreview(const ref LitShader litShader, const ref Shader shader,
                     const ref Viewport vp, ref GpuMesh previewGpu) {
    immutable float[16] identity = identityMatrix;
    Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

    // Solid faces.
    glUseProgram(litShader.program);
    glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
    glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
    glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
    glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
    glUniform1f(litShader.locAmbient,  0.20f);
    glUniform1f(litShader.locSpecStr,  0.25f);
    glUniform1f(litShader.locSpecPow,  32.0f);
    // Task 0589: this site seeds every uniform it depends on BY HAND rather
    // than going through `LitShader.useProgram`, so a uniform that the scene
    // pass may have switched off has to be seeded here too — otherwise a
    // create-tool preview drawn after an unlit scene pass would inherit the
    // flat fill. The scene pass does restore it, so this is belt-and-braces;
    // the alternative is a cross-file invariant nobody can see from here.
    // (`u_dim` has the same shape and the same restore discipline.)
    glUniform1i(litShader.locLit, 1);
    previewGpu.drawFaces(litShader);

    // Wireframe edges.
    glUseProgram(shader.program);
    glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
    glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
    previewGpu.drawEdges(shader.locColor, -1, []);
}

class GridShader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;
    GLint locMaxDist;
    GLint locScreenSize;
    GLint locVpOriginX;
    GLint locVpOriginY;

    this() {
        program       = createProgram(gridVertSrc, gridFragSrc);
        locModel      = glGetUniformLocation(program, "u_model");
        locView       = glGetUniformLocation(program, "u_view");
        locProj       = glGetUniformLocation(program, "u_proj");
        locColor      = glGetUniformLocation(program, "u_color");
        locMaxDist    = glGetUniformLocation(program, "u_maxDist");
        locScreenSize = glGetUniformLocation(program, "u_screenSize");
        locVpOriginX  = glGetUniformLocation(program, "u_vpOriginX");
        locVpOriginY  = glGetUniformLocation(program, "u_vpOriginY");
    }

    ~this() { glDeleteProgram(program); }

    void useProgram(const ref float[16] model, const ref Viewport vp,
                    float maxDist, float screenW, float screenH,
                    float vpOriginX, float vpOriginY) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, model.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform1f(locMaxDist,    maxDist);
        glUniform2f(locScreenSize, screenW, screenH);
        glUniform1f(locVpOriginX,  vpOriginX);
        glUniform1f(locVpOriginY,  vpOriginY);
    }
}
