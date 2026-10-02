module shader;

import bindbc.opengl;
import std.string : toStringz;


import view;
import math;
import mesh : Surface, MarkView;
import mesh_gpu : GpuMesh;
version (web) {
} else {
    import gl_thread_guard : glThreadGuard;
}
import display_state : DrawPlan, kSchemeSolidFill, SurfaceShading;
import weightmap_view : kWeightRamp;   // task 1090: the parked neutral
import light_rig : kKeyLightEye, kFillLightEye, kKeyIntensity, kFillIntensity,
    kLightAmbient, specPowerForRoughness, kGoochLightEye, kGoochCool,
    kGoochWarm, kGoochCoolKd, kGoochWarmKd;
// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

version (web) {
    private enum shaderPreamble =
        "#version 300 es\nprecision highp float;\nprecision highp int;\n";
} else {
    private enum shaderPreamble = "#version 330 core\n";
}

private string withShaderPreamble(string body) pure @safe {
    return shaderPreamble ~ body;
}

immutable string vertexShaderSrc = withShaderPreamble(q{
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    uniform float u_pointSize;
    void main() {
        gl_Position = u_proj * u_view * u_model * vec4(aPos, 1.0);
        gl_PointSize = u_pointSize;
    }
});

immutable string fragmentShaderSrc = withShaderPreamble(q{
    uniform vec3  u_color;
    uniform float u_dim;        // brightness multiplier; 1.0 = neutral (layers Stage 5)
    uniform float u_alpha;      // fragment opacity; 1.0 = opaque (task 0559)
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color * u_dim, u_alpha);
    }
});

// Every uniform of `fragmentShaderSrc` that is NOT written on the draw path,
// paired with the value that means "do nothing". A program built from that
// source must be seeded with all of them before its first draw, because GL
// initialises an unset uniform to 0 and 0 is the DESTRUCTIVE value for both:
// `u_dim = 0` renders black, `u_alpha = 0` renders nothing.
//
// "That source" is now TWO sources sharing one CONTRACT: `fragmentShaderSrc`
// and `thickLineFragSrc` (which consumes the vertex-expanded line's coverage
// varying — see its own comment). They declare the same
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
immutable string fillFragSrc = withShaderPreamble(q{
    uniform vec3  u_color;
    uniform float u_alpha;
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color, u_alpha);
    }
});

// ---------------------------------------------------------------------------
// Reference-image plane (task 0612) — THE FIRST `sampler2D` IN THIS CODEBASE.
//
// Nothing in `source/` sampled a 2D texture before this pair; the only other
// samplers are the `samplerBuffer` family in `subpatch_osd.d`, which read a
// buffer object rather than an image.
//
// Its OWN vertex source rather than `vertexShaderSrc` because it needs a
// second attribute (the texture coordinate) that no other pass has, and its
// OWN fragment source rather than `fragmentShaderSrc` because it samples
// instead of taking a flat colour. Consequently it is NOT part of the shared
// `fragmentShaderSrc` uniform contract and must NOT be seeded through
// `seedSharedFragUniforms` — every uniform below is written on every draw,
// which is the property that makes the seeding obligation not apply. (See
// `kSharedFragNeutrals` for the bug that obligation exists to prevent: a
// uniform added to the SHARED source that only one of its programs seeded.)
//
// Corners arrive in WORLD space, exactly like `drawWorldQuad`'s — the
// placement law has already applied the item transform, so there is no model
// matrix here and no second place for a transform to be applied twice.
immutable string imagePlaneVertSrc = withShaderPreamble(q{
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec2 aUV;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec2 vUV;
    void main() {
        vUV = aUV;
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
});

// The three look channels, applied in a FIXED order: invert, then contrast,
// then brightness.
//
// The order is not arbitrary and must not be shuffled: contrast pivots about
// mid-grey, so applying brightness first would move the pivot and make the
// two channels interact — a brightened image would also lose contrast. Invert
// comes first because it is a property of the SOURCE ("this is a pencil
// drawing on white paper"), not a grade.
//
// `u_transparency` is the channel's own sense — 0 = opaque — so the alpha
// written is `1 - u_transparency`. Naming it the other way round in the
// shader would put a silent negation between the channel and its only
// consumer.
immutable string imagePlaneFragSrc = withShaderPreamble(q{
    in  vec2 vUV;
    out vec4 fragColor;
    uniform sampler2D u_tex;
    uniform float u_brightness;    // -1 .. +1, 0 = unchanged
    uniform float u_contrast;      // -1 .. +1, 0 = unchanged
    uniform float u_transparency;  //  0 .. 1,  0 = opaque
    uniform float u_invert;        // 0 or 1
    void main() {
        vec3 c = texture(u_tex, vUV).rgb;
        c = mix(c, vec3(1.0) - c, u_invert);
        c = (c - vec3(0.5)) * (1.0 + u_contrast) + vec3(0.5);
        c = c + vec3(u_brightness);
        fragColor = vec4(clamp(c, 0.0, 1.0), 1.0 - u_transparency);
    }
});

// Lit shaders — the two-light eye-space rig of `light_rig` (diffuse + Blinn
// from the material), on the flat or the smooth normal stream.
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
private immutable string litVertSrc = withShaderPreamble(q{
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec3 aNormal;
    layout(location = 2) in uint aMatId;
    // Task 1090: the per-corner weight COLOUR, already evaluated on the CPU
    // (weightmap_view.weightSurfaceColor). Not the weight — the colour: the
    // measurement says the reference evaluates the law per vertex and lets
    // the rasteriser interpolate the RESULT, and computing it here as well
    // would put a second implementation of one measured law on the far side
    // of the unit test.
    //
    // When the array is DISABLED, GL supplies the current generic vertex
    // attribute for location 3, whose default is (0,0,0,1) — BLACK. That is
    // why `LitShader.useProgram` parks the ramp's neutral there; see it.
    layout(location = 3) in vec3 aWeightColor;
    // The smooth normal stream of the face VBO; `u_smoothNormals`
    // (the plan's `smoothNormals`) picks it over the flat `aNormal`.
    layout(location = 4) in vec3 aSmoothNormal;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    uniform mat3 u_normalMatrix;   // math.normalMatrix(u_view * u_model): to EYE space
    uniform bool u_smoothNormals;
    out vec3      vNormal;          // eye space: the rig's lights are eye-space constants
    flat out uint vMatId;
    // Smooth-interpolated, deliberately: that IS the measured interpolation
    // order. Do not make it `flat`.
    out vec3      vWeightColor;
    void main() {
        vec4 worldPos = u_model * vec4(aPos, 1.0);
        vNormal       = u_normalMatrix * (u_smoothNormals ? aSmoothNormal : aNormal);
        vMatId        = aMatId;
        vWeightColor  = aWeightColor;
        gl_Position   = u_proj * u_view * worldPos;
    }
});

private immutable string litFragSrc = withShaderPreamble(q{
    in       vec3 vNormal;
    flat in  uint vMatId;
    in       vec3 vWeightColor;     // task 1090; see the vertex shader
    uniform vec3  u_color;          // override colour for hover/highlight paths
    uniform float u_overrideMix;    // 0 = use material UBO, 1 = use u_color
    uniform vec3  u_keyDir;         // light_rig: eye space, toward the light
    uniform vec3  u_fillDir;
    uniform float u_keyI;
    uniform float u_fillI;
    uniform float u_ambient;        // global ambient, times Kd
    uniform float u_dim;            // brightness multiplier; 1.0 = neutral (layers Stage 5)
    uniform float u_lightGain;      // multiplier on the lit term ABOVE ambient; 1.0 = neutral
    uniform int   u_shading;        // display_state.SurfaceShading: 0 Material, 1 Fill, 2 Weight, 3 Retopology, 4 Gooch
    uniform vec3  u_goochDir;       // light_rig.kGoochLightEye: eye space, toward the light
    uniform vec3  u_goochCool;      // light_rig.kGoochCool: the cool tone at N·L = 0
    uniform vec3  u_goochWarm;      // light_rig.kGoochWarm: the warm tone at |N·L| = 1
    uniform float u_goochCoolKd;    // Kd's weight in each tone
    uniform float u_goochWarmKd;
    uniform vec3  u_fillColor;      // the unlit fill's base; NOT the material (task 0592)
    uniform float u_faceAlpha;      // output alpha of every arm; 1.0 = opaque (FacePass)
    uniform int   u_surfaceId;      // G-buffer surface id: layer index + 1, 0 = none
    uniform int   u_effectFlags;    // DrawPlan.effectFlags (bit 0 = cavity-eligible)
    layout(std140) uniform Materials {
        vec4 mat_base[64];     // .rgb = baseColor, .a = opacity
        vec4 mat_params[64];   // .x = diffuse amount, .y = specular amount,
                               // .z = glossiness, .w = its Blinn exponent
    };
    // Explicit locations: GLSL ES 3.00 requires them once there are two
    // outputs. Location 1 is the integer G-buffer (model M4): written on
    // every draw, kept only while the draw buffers are {C0, C1} (the surface
    // passes of a cell whose composite plan is non-empty); never blended.
    layout(location = 0) out vec4  fragColor;
    layout(location = 1) out uvec4 gbuf;
    // Octahedral normal encoding (Cigolle et al. 2014, "A Survey of
    // Efficient Representations for Independent Unit Vectors"): the unit
    // sphere folded onto the [-1,1] square, lower hemisphere mirrored over
    // the diagonals. Returned as two unorm16 values.
    uvec2 octEncode16(vec3 n) {
        vec3  a = abs(n);
        vec2  e = n.xy / max(a.x + a.y + a.z, 1e-20);
        if (n.z < 0.0)
            e = (vec2(1.0) - abs(e.yx))
              * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
        return uvec2(round(clamp(e * 0.5 + 0.5, 0.0, 1.0) * 65535.0));
    }
    // The ONE light function of the lit arms (`light_rig`'s header has the
    // law and its capture): `kd` = base colour × diffuse amount; ambient
    // `u_ambient·kd` is left unscaled and `u_lightGain` multiplies everything
    // above it, specular included. Specular is Blinn with the viewer at
    // infinity (eye space +Z), per light, gated by N·L > 0. Material and
    // Retopology both call it, so "lit by the same function as the backdrop"
    // is structural, not a copy; `retopology_line_shade.lineShade` mirrors it.
    float blinn(vec3 N, vec3 L, float nl, float power) {
        return nl > 0.0
            ? pow(max(dot(N, normalize(L + vec3(0.0, 0.0, 1.0))), 0.0), power)
            : 0.0;
    }
    vec3 litTerm(vec3 kd, vec3 N, float spec, float power) {
        float nk  = dot(N, u_keyDir);
        float nf  = dot(N, u_fillDir);
        float dif = u_keyI * max(nk, 0.0) + u_fillI * max(nf, 0.0);
        float spc = u_keyI * blinn(N, u_keyDir, nk, power)
                  + u_fillI * blinn(N, u_fillDir, nf, power);
        return kd * (u_ambient + u_lightGain * dif)
             + vec3(u_lightGain * spec * spc);
    }
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
        //
        // TASK 1090 added a THIRD arm, and it was a `bool u_lit` until then.
        // The weight arm keeps both of those properties for the same reasons:
        // the override mix, because `display_state.d`'s load-bearing invariant
        // is that no selection or hover term ever reaches the draw plan, so
        // hover has to survive every style; and `u_dim`, because the backdrop
        // pass dims whatever the active style resolved to.
        vec3 col;
        if (u_shading == 0) {
            uint  mi  = (vMatId < uint(64)) ? vMatId : uint(0);
            vec4  mp  = mat_params[mi];
            vec3  kd  = mix(mat_base[mi].rgb * mp.x, u_color, u_overrideMix);
            col = litTerm(kd, normalize(vNormal), mp.y, mp.w);
        } else if (u_shading == 1) {
            col = mix(u_fillColor, u_color, u_overrideMix);
        } else if (u_shading == 3) {
            // Retopology: the scheme's fill colour, LIT (not the material, not
            // the unlit fill); the hover override survives as in every arm.
            // Diffuse amount 1, no specular.
            col = litTerm(mix(u_fillColor, u_color, u_overrideMix),
                          normalize(vNormal), 0.0, 1.0);
        } else if (u_shading == 4) {
            // Gooch (task 9150; law in `light_rig`): Kd = base × diffuse
            // amount (the hover override replaces it, as in Material), the
            // two-sided cool→warm mix by |N·L|, no specular.
            uint  mi = (vMatId < uint(64)) ? vMatId : uint(0);
            vec3  kd = mix(mat_base[mi].rgb * mat_params[mi].x, u_color, u_overrideMix);
            float t  = abs(dot(normalize(vNormal), u_goochDir));
            col = min(mix(u_goochCool + u_goochCoolKd * kd,
                          u_goochWarm + u_goochWarmKd * kd, t), vec3(1.0));
        } else {
            // Weight (task 1090). UNLIT in the strong sense: no light term, no
            // material lookup, no gamma — the interpolated per-vertex colour
            // IS the output. Nothing may be added here without a measurement
            // saying so; the REFERENCE's control frames read (59,59,59) in its
            // shaded style and (153,153,153) in its unshaded fill on the same
            // quad where its weight style read the exact neutral (127,140,127)
            // — readings of the reference, not values our arms are tuned to.
            col = mix(vWeightColor, u_color, u_overrideMix);
        }
        fragColor = vec4(col * u_dim, u_faceAlpha);
        float nl = length(vNormal);
        gbuf = uvec4(octEncode16(nl > 0.0 ? vNormal / nl : vec3(0.0, 0.0, 1.0)),
                     uint(u_surfaceId), uint(u_effectFlags));
    }
});

// ---- The composite stage (model M4) -----------------------------
// Fullscreen triangle with no attributes (an empty VAO is bound): vertex ids
// 0,1,2 -> (-1,-1), (3,-1), (-1,3), counter-clockwise.
immutable string compositeVertSrc = withShaderPreamble(q{
    void main() {
        vec2 p = vec2(float((gl_VertexID & 1) << 2) - 1.0,
                      float((gl_VertexID & 2) << 1) - 1.0);
        gl_Position = vec4(p, 0.0, 1.0);
    }
});

// The resolve: the copied colour times the cavity factor on pixels whose
// G-buffer flags carry bit 0, the copy itself elsewhere (overlays are drawn
// after the stage, so they are never scaled). Factor
// `clamp((1 - cav) * (1 + edges) * (1 + curv), 0, 4)`; `cav`/`edges` are the
// world kernel (absent until S3b), `curv` the SCREEN CURVATURE (wave plan
// S3a): four G-buffer taps `u_curvPx` pixels up/down/right/left of
// the pixel; none where the up/down or right/left ids differ (a silhouette
// between two surfaces or against the background) or where the taps are
// background; else the divergence of the eye normal `(Nup.y - Ndown.y) +
// (Nright.x - Nleft.x)`, positive on a ridge, negative in a valley, through a
// soft limiter whose controls are `0.5 / max(ridge^2, 1e-4)` and
// `0.7 / max(valley^2, 1e-4)` (`curvatureControls`). `u_curvPx == 0` = the
// term is off (World only). The background test, `on` and `u_curvPx > 0`
// in the curvature guard are early-outs that change no pixel (background
// texels decode to one fixed normal, `k` is gated by `on` again, zero taps
// give d = 0). Samplers: unit 0 the copy, 1 the G-buffer, 2 the
// world-cavity buffer. `u_testGain` scales EVERY pixel the resolve writes; it
// is 1 except under the test-only `viewport.compositeTestGain`, whose cell
// proves the draw covers the cell.
immutable string compositeResolveFragSrc = withShaderPreamble(q{
    uniform sampler2D  u_src;
    uniform highp usampler2D u_gbuf;
    uniform sampler2D  u_ao;
    uniform float      u_testGain;
    uniform int        u_curvPx;
    uniform float      u_ridgeCtl;
    uniform float      u_valleyCtl;
    layout(location = 0) out vec4 fragColor;
    // Inverse of the lit pass octahedral encoding (two unorm16 values).
    vec3 octDecode16(uvec2 q) {
        vec2  e = vec2(q) / 65535.0 * 2.0 - 1.0;
        vec3  n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
        if (n.z < 0.0)
            n.xy = (vec2(1.0) - abs(e.yx))
                 * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
        return normalize(n);
    }
    // Rises as x, flattens to 0.25 / ctl at x = 0.5 / ctl and stays there.
    float softLimit(float x, float ctl) {
        return x < 0.5 / ctl ? x * (1.0 - x * ctl) : 0.25 / ctl;
    }
    float screenCurvature(ivec2 p) {
        ivec2 hi = textureSize(u_gbuf, 0) - ivec2(1);
        ivec2 dx = ivec2(u_curvPx, 0), dy = ivec2(0, u_curvPx);
        uvec4 tU = texelFetch(u_gbuf, min(p + dy, hi), 0);
        uvec4 tD = texelFetch(u_gbuf, max(p - dy, ivec2(0)), 0);
        uvec4 tR = texelFetch(u_gbuf, min(p + dx, hi), 0);
        uvec4 tL = texelFetch(u_gbuf, max(p - dx, ivec2(0)), 0);
        if (tU.b != tD.b || tR.b != tL.b) return 0.0;
        if (tU.b == 0u && tR.b == 0u) return 0.0;
        float d = (octDecode16(tU.rg).y - octDecode16(tD.rg).y)
                + (octDecode16(tR.rg).x - octDecode16(tL.rg).x);
        return d < 0.0 ? -2.0 * softLimit(-d, u_valleyCtl)
                       :  2.0 * softLimit( d, u_ridgeCtl);
    }
    void main() {
        ivec2 p   = ivec2(gl_FragCoord.xy);
        vec4  src = texelFetch(u_src, p, 0);
        uvec4 g   = texelFetch(u_gbuf, p, 0);
        bool  on  = (g.a & 1u) != 0u;
        float cav = 0.0, edges = 0.0;
        float curv = (on && u_curvPx > 0) ? screenCurvature(p) : 0.0;
        float k   = on ? clamp((1.0 - cav) * (1.0 + edges) * (1.0 + curv), 0.0, 4.0)
                       : 1.0;
        fragColor = vec4(src.rgb * (k * u_testGain), src.a);
    }
});

// Checkerboard overlay shader — every other screen pixel is discarded,
// the rest are filled with u_color at u_alpha.  Used to highlight selected
// faces.
//
// `u_alpha` IS THIS PROGRAM'S OWN, AND IT IS NOT ON THE SHARED CONTRACT
// (task 1862). `kSharedFragNeutrals` / `seedSharedFragUniforms` describe the
// programs built from `fragmentShaderSrc` and its thick-line counterpart
// `thickLineFragSrc`; the helper resolves BY NAME, over programs whose
// builders call it. `CheckerShader` is built from `checkerFragSrc`, so adding
// a uniform on either side does NOT enlist the other.
//
// Which puts this source under the rule `fillFragSrc` and `imagePlaneFragSrc`
// already state, not under an exception to it: a program whose `u_alpha` is
// WRITTEN on every draw is never a seeding obligation and must NOT be seeded
// through `seedSharedFragUniforms`. `CheckerShader.useProgram` writes the
// neutral on every bind, so the obligation is discharged there — see the ctor
// for why calling the helper as well would be worse than redundant.
//
// Why it exists at all: the OCCLUDED half of the selected-face fill (the part
// behind other geometry) is submitted a second time at
// `kOccludedSelectionAlpha` — see `OccludedPass` in `mesh_gpu.d`. Without a
// per-draw alpha that second pass would paint at full strength, which is the
// pre-1862 rendering it exists to replace.
private immutable string checkerFragSrc = withShaderPreamble(q{
    uniform vec3  u_color;
    uniform float u_alpha;
    out vec4 fragColor;
    void main() {
        if ((int(gl_FragCoord.x)/2 + int(gl_FragCoord.y)) % 2 == 0 || int(gl_FragCoord.x) % 2 == 0) discard;
        fragColor = vec4(u_color, u_alpha);
    }
});

// Grid shaders — vertex passes world pos, fragment computes fade alpha.
private immutable string gridVertSrc = withShaderPreamble(q{
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vWorldPos;
    void main() {
        vWorldPos   = (u_model * vec4(aPos, 1.0)).xyz;
        gl_Position = u_proj * u_view * vec4(vWorldPos, 1.0);
    }
});

private immutable string gridFragSrc = withShaderPreamble(q{
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
});

// ---------------------------------------------------------------------------
// Shader helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, string src) {
    // Funnel 2 of 2. The lowest point of every program build — `createProgram`,
    // and gpu_select's own builder both route through here — so guarding it
    // covers every `*Shader` ctor. See gl_thread_guard.d.
    version (web) {
    } else {
        glThreadGuard("compileShader");
    }
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

// Vertex shader that expands instanced line segments into screen-aligned quads.
// The draw funnel supplies both endpoints as per-instance attributes and emits
// four vertices per instance, so the same body works on desktop GL 3.3 and
// WebGL2 / ES 3.0 without a geometry stage.
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
private enum string thickLineVertexBody = q{
    layout(location = 0) in vec3 a_p0;
    layout(location = 1) in vec3 a_p1;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    uniform float u_lineWidth;   // stroke width, WINDOW PIXELS
    uniform vec2  u_screenSize;  // framebuffer size in pixels

    // Signed perpendicular distance from the line's centreline, WINDOW PIXELS.
    // ES 3.0 has no `noperspective`, so emit d*w and let the fragment stage
    // multiply the perspective-correct interpolation by gl_FragCoord.w. That
    // restores screen-linear d and preserves the smoothing law below.
    out highp float vEdgeDist;

    // The coverage ramp needs somewhere to live: a stroke edge is soft for half
    // a pixel on each side, and a fragment outside the quad is never shaded at
    // all. So the quad is grown past the stroke's own half-width by this much.
    // At the grown edge the fragment's coverage is exactly 0, so the padding
    // costs nothing visible — it only enlarges the rasterised area slightly.
    const float kAaPadPx = 1.0;

    void main() {
        vec4 p0 = u_proj * u_view * u_model * vec4(a_p0, 1.0);
        vec4 p1 = u_proj * u_view * u_model * vec4(a_p1, 1.0);
        // Clip -> WINDOW PIXELS. NDC spans [-1,1] over `u_screenSize` pixels,
        // so the scale is HALF the framebuffer size, not the whole of it.
        vec2 halfScreen = u_screenSize * 0.5;
        vec2 s0 = p0.xy / p0.w * halfScreen;
        vec2 s1 = p1.xy / p1.w * halfScreen;
        vec2 dir = s1 - s0;
        float len = length(dir);
        if (len < 0.001) {
            gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
            vEdgeDist = 0.0;
            return;
        }
        // Perpendicular in window pixels, half-width plus the fringe's room.
        float halfE = u_lineWidth * 0.5 + kAaPadPx;
        vec2 perp = vec2(-dir.y, dir.x) / len * halfE;
        // Back to clip-space offsets (un-divide by w).
        vec2 off0 = perp / halfScreen * p0.w;
        vec2 off1 = perp / halfScreen * p1.w;
        bool atEnd = gl_VertexID >= 2;
        bool positive = (gl_VertexID & 1) == 0;
        vec4 p = atEnd ? p1 : p0;
        vec2 off = atEnd ? off1 : off0;
        float edgeDist = positive ? halfE : -halfE;
        gl_Position = vec4(p.xy + (positive ? off : -off), p.zw);
        vEdgeDist = edgeDist * gl_Position.w;
    }
};

version (web) {
    immutable string thickLineVertexSrc =
        withShaderPreamble(thickLineVertexBody);
} else {
    immutable string thickLineVertexSrc =
        "#version 330 core\n" ~ thickLineVertexBody;
}

// The thick-line program's OWN fragment stage — ANALYTIC line antialiasing.
//
// WHY THIS IS NOT `fragmentShaderSrc`. It cannot be: it consumes a varying
// (`vEdgeDist`) that only the instanced vertex stage above produces, and a
// fragment input with no matching upstream output is a link error. The regular
// program does not produce it, so the two sources stay split.
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
// that into a soft edge. We cannot use it: our "line" is already a vertex-
// expanded quad (Core Profile has no portable `glLineWidth > 1`), so there is
// no GL line for the driver to smooth. The port is therefore analytic — carry the
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
// at any pixel. The vertex stage still pads the quad by `kAaPadPx`, and those
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
private enum string thickLineFragmentBody = q{
    uniform vec3  u_color;
    uniform float u_dim;        // brightness multiplier; 1.0 = neutral
    uniform float u_alpha;      // fragment opacity; 1.0 = opaque
    uniform float u_lineWidth;  // stroke width, WINDOW PIXELS (shared with the vertex stage)
    uniform float u_smooth;     // 1 = analytic coverage AA, 0 = hard-edged; 1.0 = neutral
    in highp float vEdgeDist;
    out vec4 fragColor;
    void main() {
        float halfW = u_lineWidth * 0.5;
        float d     = abs(vEdgeDist * gl_FragCoord.w);
        float cov   = (u_smooth > 0.5)
                    ? 1.0 - smoothstep(halfW - 0.5, halfW + 0.5, d)
                    : (d <= halfW ? 1.0 : 0.0);
        fragColor = vec4(u_color * u_dim, u_alpha * cov);
    }
};

version (web) {
    immutable string thickLineFragSrc =
        withShaderPreamble(thickLineFragmentBody);
} else {
    immutable string thickLineFragSrc =
        "#version 330 core\n" ~ thickLineFragmentBody;
}

// Compile-time inspection seam for the permanent WebGL2 validator.  It
// returns the actual constants consumed by the program builders; the browser
// gate therefore cannot accidentally validate a second, test-owned rewrite.
string shaderSourceForValidation(string name) pure @safe {
    switch (name) {
    case "vertexShaderSrc": return vertexShaderSrc;
    case "fragmentShaderSrc": return fragmentShaderSrc;
    case "fillFragSrc": return fillFragSrc;
    case "imagePlaneVertSrc": return imagePlaneVertSrc;
    case "imagePlaneFragSrc": return imagePlaneFragSrc;
    case "litVertSrc": return litVertSrc;
    case "litFragSrc": return litFragSrc;
    case "checkerFragSrc": return checkerFragSrc;
    case "gridVertSrc": return gridVertSrc;
    case "gridFragSrc": return gridFragSrc;
    case "thickLineVertexSrc": return thickLineVertexSrc;
    case "thickLineFragSrc": return thickLineFragSrc;
    case "compositeVertSrc": return compositeVertSrc;
    case "compositeResolveFragSrc": return compositeResolveFragSrc;
    default: assert(false, "unknown shader source: " ~ name);
    }
}

class Shader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;
    GLint locDim;
    GLint locAlpha;
    GLint locPointSize;

    this() {
        program  = createProgram();
        locModel  = glGetUniformLocation(program, "u_model");
        locView   = glGetUniformLocation(program, "u_view");
        locProj   = glGetUniformLocation(program, "u_proj");
        locColor  = glGetUniformLocation(program, "u_color");
        locDim    = glGetUniformLocation(program, "u_dim");
        locAlpha  = glGetUniformLocation(program, "u_alpha");
        locPointSize = glGetUniformLocation(program, "u_pointSize");
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
    /// `checkerFragSrc`'s OWN `u_alpha` — see that source's comment for why it
    /// is not the shared contract's. Handed to `GpuMesh.drawSelectedFacesOverlay`
    /// inside an `OccludedPass` so the occluded half of the fill can be blended.
    GLint locAlpha;

    this() {
        program  = createProgram(vertexShaderSrc, checkerFragSrc);
        locModel = glGetUniformLocation(program, "u_model");
        locView  = glGetUniformLocation(program, "u_view");
        locProj  = glGetUniformLocation(program, "u_proj");
        locColor = glGetUniformLocation(program, "u_color");
        locAlpha = glGetUniformLocation(program, "u_alpha");
        // NO `seedSharedFragUniforms(program)` HERE, deliberately, and this is
        // the file's one rule rather than an exception to it: GL initialises
        // an unset uniform to 0 and 0 is the DESTRUCTIVE value for an alpha,
        // but this program's alpha is WRITTEN on every bind by `useProgram`
        // below — which is its ONLY bind site — so nothing can reach a draw
        // through an unwritten `u_alpha`. That is exactly the property
        // `fillFragSrc` and `imagePlaneFragSrc` name as "never a seeding
        // obligation".
        //
        // Calling the helper anyway would not be merely redundant. It resolves
        // BY NAME over the programs whose builders call it, so calling it here
        // is what would ENLIST this program in `kSharedFragNeutrals` — and a
        // later edit to a neutral there, or a third entry whose name
        // `checkerFragSrc` happens to also use, would then reach a program the
        // shared contract does not describe.
        //
        // The obligation travels with the bind: a new site that binds
        // `program` raw instead of through `useProgram` takes it on, and
        // writing `u_alpha` is that site's job.
    }

    ~this() { glDeleteProgram(program); }

    void useProgram(const ref float[16] meshModel, const ref Viewport vp, float r, float g, float b) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(locColor, r, g, b);
        // THE NEUTRAL'S ONLY DISCHARGE — the ctor deliberately does not seed
        // it (see there). Every bind starts fully opaque, so the very first
        // frame's visible pass is opaque too. The one pass that lowers it (the
        // occluded half of the fill) restores 1.0 through `endHighlightPasses`
        // — but a bind that inherited 0.30 from a previous frame would paint a
        // ghost fill, so the neutral is written here rather than assumed.
        glUniform1f(locAlpha, 1.0f);
    }
}

class LitShader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;
    GLint locOverrideMix;
    // The rig's locations are module-private: `useProgram` is their one
    // writer (census: cell 5 of tests/unit/retopology_line_shade_test.d).
    private GLint locKeyDir;
    private GLint locFillDir;
    private GLint locKeyI;
    private GLint locFillI;
    private GLint locAmbient;
    private GLint locGoochDir;
    private GLint locGoochCool;
    private GLint locGoochWarm;
    private GLint locGoochCoolKd;
    private GLint locGoochWarmKd;
    // The per-plan uniform locations are module-private like their setters:
    // outside this module nothing can name them, so `applyPlan` stays their
    // one writer (the fence is pinned by tests/unit/lit_plan_seam_test.d).
    private GLint locDim;
    private GLint locLightGain;
    private GLint locShading;
    private GLint locFillColor;
    private GLint locSmoothNormals;
    private GLint locSurfaceId;
    private GLint locEffectFlags;
    // Not a plan uniform: written with `u_model` by `useProgram` and the
    // preview helper, both in this module.
    private GLint locNormalMatrix;
    GLint locFaceAlpha;
    GLuint matsUbo;            // Material Groups (MG3) — Materials UBO
    enum  MATS_BINDING = 0;    // binding point index, matches std140 layout

    this() {
        program        = createProgram(litVertSrc, litFragSrc);
        locModel       = glGetUniformLocation(program, "u_model");
        locView        = glGetUniformLocation(program, "u_view");
        locProj        = glGetUniformLocation(program, "u_proj");
        locColor       = glGetUniformLocation(program, "u_color");
        locOverrideMix = glGetUniformLocation(program, "u_overrideMix");
        locKeyDir      = glGetUniformLocation(program, "u_keyDir");
        locFillDir     = glGetUniformLocation(program, "u_fillDir");
        locKeyI        = glGetUniformLocation(program, "u_keyI");
        locFillI       = glGetUniformLocation(program, "u_fillI");
        locAmbient     = glGetUniformLocation(program, "u_ambient");
        locGoochDir    = glGetUniformLocation(program, "u_goochDir");
        locGoochCool   = glGetUniformLocation(program, "u_goochCool");
        locGoochWarm   = glGetUniformLocation(program, "u_goochWarm");
        locGoochCoolKd = glGetUniformLocation(program, "u_goochCoolKd");
        locGoochWarmKd = glGetUniformLocation(program, "u_goochWarmKd");
        locDim         = glGetUniformLocation(program, "u_dim");
        locLightGain   = glGetUniformLocation(program, "u_lightGain");
        locShading     = glGetUniformLocation(program, "u_shading");
        locFillColor   = glGetUniformLocation(program, "u_fillColor");
        locFaceAlpha   = glGetUniformLocation(program, "u_faceAlpha");
        locSmoothNormals = glGetUniformLocation(program, "u_smoothNormals");
        locNormalMatrix  = glGetUniformLocation(program, "u_normalMatrix");
        locSurfaceId     = glGetUniformLocation(program, "u_surfaceId");
        locEffectFlags   = glGetUniformLocation(program, "u_effectFlags");
        // Every draw binds through `useProgram`, which seeds every uniform
        // below; nothing is parked here.

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
            // The exponent, derived here once per upload rather than per
            // fragment; captured: roughness = 1 − glossiness, exact.
            params[i * 4 + 3] = specPowerForRoughness(1.0f - s.glossiness);
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

    /// Bind the program for `meshModel` under `vp`: the ONE upload site of
    /// the light rig (and of the matrices and every neutral below). Every lit
    /// draw — scene passes, `drawLitPreview`, the pen preview — binds here.
    void useProgram(const ref float[16] meshModel, const ref Viewport vp) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, vp.proj.ptr);
        uploadNormalMatrix(matMul4(vp.view, meshModel));
        glUniform3f(locKeyDir,  kKeyLightEye.x,  kKeyLightEye.y,  kKeyLightEye.z);
        glUniform3f(locFillDir, kFillLightEye.x, kFillLightEye.y, kFillLightEye.z);
        glUniform1f(locKeyI,    kKeyIntensity);
        glUniform1f(locFillI,   kFillIntensity);
        glUniform1f(locAmbient, kLightAmbient);
        glUniform3f(locGoochDir, kGoochLightEye.x, kGoochLightEye.y, kGoochLightEye.z);
        glUniform3f(locGoochCool, kGoochCool.x, kGoochCool.y, kGoochCool.z);
        glUniform3f(locGoochWarm, kGoochWarm.x, kGoochWarm.y, kGoochWarm.z);
        glUniform1f(locGoochCoolKd, kGoochCoolKd);
        glUniform1f(locGoochWarmKd, kGoochWarmKd);
        // Default to material-lookup mode. drawFacesHighlighted flips
        // this to 1.0 for hover draws that need to override the
        // surface colour with u_color.
        glUniform1f(locOverrideMix, 0.0f);
        // Default to neutral brightness. Only a plan-driven face pass writes
        // the plan's dim (`applyPlan`) and parks 1.0 after its draws
        // (`restorePlanDefaults`).
        glUniform1f(locDim, 1.0f);
        // Same neutrality contract as u_dim: only a plan-driven face pass sets
        // a gain (`DrawPlan.lightGain`) and restores 1.0 after its draws.
        glUniform1f(locLightGain, 1.0f);
        // Opaque unless a translucent face pass (`FacePass.alpha`) says
        // otherwise; that pass writes and restores it itself.
        glUniform1f(locFaceAlpha, 1.0f);
        // Default to the MATERIAL (lit) arm, for exactly the reason u_dim
        // defaults to neutral: every caller that does not care about the
        // display style gets the behaviour that predates it. The face passes
        // flip this with `applyPlan` before their draws and restore Material
        // with `restorePlanDefaults` afterwards.
        glUniform1i(locShading, cast(int)SurfaceShading.Material);
        // Seed the unlit fill to the colour-scheme value. A GLSL uniform
        // defaults to 0, so an unseeded `u_fillColor` would render the Solid
        // style BLACK for any caller that draws without going through the
        // display plan (the create-tool previews below, for one). Not
        // observable at all under the Material arm, which is the default.
        glUniform3f(locFillColor,
            kSchemeSolidFill, kSchemeSolidFill, kSchemeSolidFill);
        // The plan default normal source (smooth), like the uniforms above.
        glUniform1i(locSmoothNormals, DrawPlan.init.smoothNormals ? 1 : 0);
        // ---- PARK THE NEUTRAL IN GENERIC VERTEX ATTRIBUTE 3 (task 1090) ----
        //
        // THIS IS LOAD-BEARING AND IT IS THE ONE REAL GL TRAP IN THE WEIGHT
        // STYLE. When the loc-3 array is DISABLED — which is every draw except
        // a weight draw with a resolved map, i.e. every create-tool preview,
        // every gizmo draw, every shaded and solid frame, and every weight
        // frame with no map selected — GL 3.3 core supplies the CURRENT
        // GENERIC VERTEX ATTRIBUTE for that location. Its default is
        // (0,0,0,1): BLACK, not the ramp's neutral. Without this call the
        // weight style renders a black surface the moment no map resolves,
        // which is precisely the state the measurement says must be neutral.
        //
        // WHY HERE, and not paired with each `glDisableVertexAttribArray(3)`.
        // The generic attribute value is CONTEXT state, not VAO state, so a
        // single park at init would in principle be enough — but only until
        // something resets the context, and nothing in this file would notice
        // if it did. Parking inside `useProgram` is self-healing, costs one
        // call per program bind, and cannot be lost. When the array IS
        // enabled the generic value is ignored, so this is inert on the
        // paying path.
        glVertexAttrib3f(3, kWeightRamp.neutral.x,
                            kWeightRamp.neutral.y,
                            kWeightRamp.neutral.z);
    }

    /// The plan-uniform seam (model M1): the ONE writer of every per-plan
    /// uniform of this program, fed by the resolved `DrawPlan` the dirty key
    /// already stamps. Contract: called AFTER `useProgram` (which re-seeds the
    /// park) and before the face draw; paired with `restorePlanDefaults` after
    /// it. A slice that adds a plan uniform adds one line here and one in
    /// `restorePlanDefaults`, never a line at a face-pass site (task 9040).
    /// Shading and fill are written together because they are one decision
    /// (task 0592): a pass cannot set the fill and forget the lighting.
    /// `surfaceId` is the pass's G-buffer surface id (layer index + 1),
    /// written with the plan's `effectFlags`.
    void applyPlan(const ref DrawPlan plan, uint surfaceId) {
        setDim(plan.dim);
        setShading(plan.shading);
        setFillColor(plan.fillColor);
        setLightGain(plan.lightGain);
        setSmoothNormals(plan.smoothNormals);
        setSurfaceTag(surfaceId, plan.effectFlags);
    }

    /// Park every per-plan uniform at its neutral: the values a
    /// default-constructed `DrawPlan` carries, so "restore" and "the default
    /// plan" have one source and cannot drift. The program is shared with every
    /// preview and gizmo draw downstream of a face pass.
    void restorePlanDefaults() {
        immutable DrawPlan park = DrawPlan.init;
        setDim(park.dim);
        setShading(park.shading);
        setFillColor(park.fillColor);
        setLightGain(park.lightGain);
        setSmoothNormals(park.smoothNormals);
        setSurfaceTag(0, park.effectFlags);
    }

    /// The subset of `plan` a create-tool preview honours: the cell's normal
    /// source, over the park. For a preview the plan is otherwise
    /// a pass gate, not a material source (task 5260), so a preview drawn
    /// after an unlit scene pass is still lit.
    void applyPreviewPlan(const ref DrawPlan plan) {
        restorePlanDefaults();
        setSmoothNormals(plan.smoothNormals);
    }

    // The setters are module-private: outside this module a face pass cannot
    // hand-set a plan uniform (the compiler is the fence). Each
    // binds the program because uniforms are program state.
    private void setDim(float dim) {
        glUseProgram(program);
        glUniform1f(locDim, dim);
    }

    private void setLightGain(float gain) {
        glUseProgram(program);
        glUniform1f(locLightGain, gain);
    }

    /// How the next draws shade the surface (`DrawPlan.shading`).
    private void setShading(SurfaceShading s) {
        glUseProgram(program);
        glUniform1i(locShading, cast(int)s);
    }

    /// The unshaded fill's base colour (`DrawPlan.fillColor`).
    private void setFillColor(in float[3] c) {
        glUseProgram(program);
        glUniform3f(locFillColor, c[0], c[1], c[2]);
    }

    /// Which face-VBO normal stream the next draws read (`DrawPlan.smoothNormals`).
    private void setSmoothNormals(bool smooth) {
        glUseProgram(program);
        glUniform1i(locSmoothNormals, smooth ? 1 : 0);
    }

    /// The G-buffer tag of the next draws: surface id and effect flags.
    private void setSurfaceTag(uint surfaceId, ubyte effectFlags) {
        glUseProgram(program);
        glUniform1i(locSurfaceId, cast(int)surfaceId);
        glUniform1i(locEffectFlags, cast(int)effectFlags);
    }

    /// `u_normalMatrix = normalMatrix(modelView)` for the bound program.
    private void uploadNormalMatrix(const float[16] modelView) {
        immutable float[9] n = normalMatrix(modelView);
        glUniformMatrix3fv(locNormalMatrix, 1, GL_FALSE, n.ptr);
    }
}

// Shared "lit preview" draw: solid shaded faces (LitShader — identity
// model, the viewport's light rig through `useProgram`) followed by wireframe edges
// (plain Shader). Used by every primitive/incremental create-tool (box,
// bridge, capsule, cone, cylinder, mirror, radial-sweep, sphere, tack,
// torus, tube) to render its in-progress preview mesh — lifted verbatim
// from the `draw()` GL block every one of them repeated (task 0410, dedup
// 0407 §A.D6). `previewGpu` is `ref` (not `const`) because
// GpuMesh.drawFaces/drawEdges are not const-qualified.
void drawLitPreview(LitShader litShader, const ref Shader shader,
                     const ref Viewport vp, ref GpuMesh previewGpu,
                     const ref DrawPlan plan) {
    immutable float[16] identity = identityMatrix;

    // The preview's surface pass obeys the cell plan. Its shading remains the
    // existing material preview whenever the plan permits faces; the plan is
    // a pass gate here, not a source of preview material state (task 5260).
    if (plan.drawFaces) {
        // `useProgram` seeds the rig and every neutral; the plan seam's preview
        // subset then re-parks the plan uniforms a scene pass may have switched
        // off, so a preview drawn after an unlit scene pass is still lit (0589).
        litShader.useProgram(identity, vp);
        litShader.applyPreviewPlan(plan);
        previewGpu.drawFaces(litShader);
    }

    // Wireframe edges.
    glUseProgram(shader.program);
    glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
    glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
    glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
    previewGpu.drawEdges(shader.locColor, -1, MarkView.init);
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
