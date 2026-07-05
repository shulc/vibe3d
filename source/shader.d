module shader;

import bindbc.opengl;
import std.string : toStringz;


import view;
import math;
import mesh : Surface;
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
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color * u_dim, 1.0);
    }
};

// Flat translucent-fill fragment shader — a solid `u_color` at a per-draw
// `u_alpha`. Used by handler.drawWorldQuad for alpha-blended overlay polygons
// (the Slice tool's cut-plane preview). Kept as its OWN program so the opaque
// `fragmentShaderSrc` gizmo/mesh draws are untouched (no shared `u_alpha`
// uniform to seed, no risk of an unset uniform blanking other draws).
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
    layout(std140) uniform Materials {
        vec4 mat_base[64];     // .rgb = baseColor, .a = opacity
        vec4 mat_params[64];   // .x = diffuse, .y = specular, .z = glossiness
    };
    out vec4 fragColor;
    void main() {
        vec3 N    = normalize(vNormal);
        vec3 L    = u_lightDir;
        vec3 V    = normalize(u_eyePos - vWorldPos);
        vec3 H    = normalize(L + V);
        float dif = max(dot(N, L), 0.0);
        float spc = pow(max(dot(N, H), 0.0), u_specPow);
        uint  mi  = (vMatId < uint(64)) ? vMatId : uint(0);
        vec3  bc  = mix(mat_base[mi].rgb, u_color, u_overrideMix);
        vec3  col = bc * (u_ambient + dif * (1.0 - u_ambient))
                  + vec3(1.0) * spc * u_specStr;
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
immutable string thickLineGeomSrc = q{
    #version 330 core
    layout(lines) in;
    layout(triangle_strip, max_vertices = 4) out;
    uniform float u_lineWidth;   // desired line width in pixels
    uniform vec2  u_screenSize;  // framebuffer size in pixels
    void main() {
        vec4 p0 = gl_in[0].gl_Position;
        vec4 p1 = gl_in[1].gl_Position;
        // Convert to screen space
        vec2 s0 = p0.xy / p0.w * u_screenSize;
        vec2 s1 = p1.xy / p1.w * u_screenSize;
        vec2 dir = s1 - s0;
        float len = length(dir);
        if (len < 0.001) return;
        // Perpendicular in screen space, half-width
        vec2 perp = vec2(-dir.y, dir.x) / len * (u_lineWidth * 0.5);
        // Back to NDC offsets (un-divide by w)
        vec2 off0 = perp / u_screenSize * p0.w;
        vec2 off1 = perp / u_screenSize * p1.w;
        gl_Position = vec4(p0.xy + off0, p0.zw); EmitVertex();
        gl_Position = vec4(p0.xy - off0, p0.zw); EmitVertex();
        gl_Position = vec4(p1.xy + off1, p1.zw); EmitVertex();
        gl_Position = vec4(p1.xy - off1, p1.zw); EmitVertex();
        EndPrimitive();
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

    this() {
        program  = createProgram();
        locModel  = glGetUniformLocation(program, "u_model");
        locView   = glGetUniformLocation(program, "u_view");
        locProj   = glGetUniformLocation(program, "u_proj");
        locColor  = glGetUniformLocation(program, "u_color");
        locDim    = glGetUniformLocation(program, "u_dim");
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
    }

    /// Override the brightness multiplier for the next draws on this
    /// program. Used only by the dimmed background-layer pass (layers
    /// Stage 5); pass 1.0 to restore the neutral default.
    void setDim(float dim) {
        glUseProgram(program);
        glUniform1f(locDim, dim);
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
    }

    /// Override the brightness multiplier for the next draws on this
    /// program. Used only by the dimmed background-layer pass (layers
    /// Stage 5); pass 1.0 to restore the neutral default.
    void setDim(float dim) {
        glUseProgram(program);
        glUniform1f(locDim, dim);
    }
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
